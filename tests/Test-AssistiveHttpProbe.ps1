$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-http-probe-test-'+[Guid]::NewGuid().ToString('N'))
$repoRoot=Split-Path -Parent $PSScriptRoot
$probePath=Join-Path $repoRoot 'src\AssistiveHttpProbe.ps1'
$fixtureUi=Join-Path $repoRoot 'src\ui'
$script:requestLog=New-Object 'System.Collections.Generic.List[string]'
$script:fixtureMode='Match'
$script:fixtureUi=$fixtureUi
$checkCount=0

function Assert-Probe([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw ('Assertion failed: '+$Message)}
    $script:checkCount++
}

function Get-FixtureHash([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Get-FixtureHeaders([string]$ContentType,[int]$Length,[string]$Csp="default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'") {
    return @{
        'Content-Type'=$ContentType
        'Content-Length'=[string]$Length
        'Connection'='close'
        'X-Content-Type-Options'='nosniff'
        'Referrer-Policy'='no-referrer'
        'Content-Security-Policy'=$Csp
    }
}

$script:requestAdapter={
    param($Method,$Uri)
    if($Method -cne 'GET'){throw ('Unexpected method '+$Method)}
    [void]$script:requestLog.Add($Method+' '+$Uri.AbsolutePath)
    if($Uri.AbsolutePath -ceq '/api/session'){
        if($script:fixtureMode -ceq 'SessionError'){
            $bytes=[Text.Encoding]::UTF8.GetBytes('{}')
            return [pscustomobject]@{StatusCode=503;Body=$bytes;Headers=(Get-FixtureHeaders 'application/json; charset=utf-8' $bytes.Length)}
        }
        $hashes=@{}
        foreach($name in @('index.html','console.js','console.css','guide.html')){$bytes=[IO.File]::ReadAllBytes((Join-Path $script:fixtureUi $name));$hashes['/ui/'+$name]=Get-FixtureHash $bytes}
        $body=[Text.Encoding]::UTF8.GetBytes((@{token='fixture-secret-token-must-not-leak';assetHashes=$hashes}|ConvertTo-Json -Compress))
        return [pscustomobject]@{StatusCode=200;Body=$body;Headers=(Get-FixtureHeaders 'application/json; charset=utf-8' $body.Length)}
    }
    $assetName=Split-Path $Uri.AbsolutePath -Leaf
    $file=Join-Path $script:fixtureUi $assetName
    $body=[IO.File]::ReadAllBytes($file)
    $contentType=switch([IO.Path]::GetExtension($file)){'.html'{'text/html; charset=utf-8'}'.js'{'application/javascript; charset=utf-8'}'.css'{'text/css; charset=utf-8'}}
    $csp="default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    $status=200
    if($script:fixtureMode -ceq 'BodyAndHeaderChanged' -and $assetName -ceq 'index.html'){
        $suffix=[Text.Encoding]::UTF8.GetBytes('<script>alert(1)</script>')
        $body=@($body)+@($suffix)
        $csp="default-src 'self'; script-src 'self' local.adguard.org; <script>alert(1)</script>"
    }
    if($script:fixtureMode -ceq 'HttpError' -and $assetName -ceq 'console.css'){$status=503}
    if($script:fixtureMode -ceq 'TransportError' -and $assetName -ceq 'console.js'){throw [IO.IOException]::new('fixture transport failure')}
    [pscustomobject]@{StatusCode=$status;Body=([byte[]]$body);Headers=(Get-FixtureHeaders $contentType $body.Length $csp)}
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $loadOutput=@(. $probePath)
    Assert-Probe ($loadOutput.Count -eq 0) 'dot-sourcing only defines the public function'
    Assert-Probe ([bool](Get-Command Export-WsmAssistiveHttpProbe -ErrorAction SilentlyContinue)) 'the public function is defined'
    Assert-Probe ((Get-ChildItem -LiteralPath $testRoot -Force).Count -eq 0) 'dot-sourcing has no file side effects'

    $origin=[uri]'http://127.0.0.1:49231/'
    $output=Join-Path $testRoot 'matching-probe'
    $script:requestLog.Clear();$script:fixtureMode='Match'
    $matching=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($matching.Status -ceq 'ObservedMatches') 'identical disk, session, body and headers are observed matches'
    Assert-Probe ($script:requestLog.Count -eq 5) 'the probe requests only session and four assets'
    Assert-Probe (@($script:requestLog|Where-Object {$_ -notmatch '^GET '}).Count -eq 0) 'all probe requests are GET'
    $matchingJson=Get-Content -LiteralPath $matching.JsonPath -Raw
    $matchingHtml=Get-Content -LiteralPath $matching.HtmlPath -Raw
    Assert-Probe ($matchingJson -notmatch 'fixture-secret-token-must-not-leak' -and $matchingHtml -notmatch 'fixture-secret-token-must-not-leak') 'session token is excluded from JSON and HTML'

    $output=Join-Path $testRoot 'changed-probe'
    $script:requestLog.Clear();$script:fixtureMode='BodyAndHeaderChanged'
    $changed=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    $indexResult=@($changed.Assets|Where-Object Route -CEQ '/ui/index.html')[0]
    $changedHtml=Get-Content -LiteralPath $changed.HtmlPath -Raw
    Assert-Probe ($changed.Status -ceq 'ModifiedTransport') 'changed body or CSP is reported as modified transport'
    Assert-Probe (-not $indexResult.BodyMatchesDisk -and -not $indexResult.HeadersMatchExpected) 'the changed body and security headers are both detected'
    Assert-Probe (($changedHtml -match '(\\u003c|&lt;)script' -or $changedHtml -match 'u003cscript') -and $changedHtml -notmatch '<script>alert\(1\)</script>') 'HTML-escaped observed headers cannot inject markup'
    Assert-Probe ((Get-Content -LiteralPath $changed.JsonPath -Raw) -notmatch 'fixture-secret-token-must-not-leak') 'mutated probe JSON still excludes the session token'

    $output=Join-Path $testRoot 'transport-error-probe'
    $script:requestLog.Clear();$script:fixtureMode='TransportError'
    $transportError=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($transportError.Status -ceq 'NotTested' -and (@($transportError.Assets|Where-Object {$_.Route -ceq '/ui/console.js' -and $_.Status -ceq 'NotTested'}).Count -eq 1)) 'transport failures are NotTested'

    $output=Join-Path $testRoot 'http-error-probe'
    $script:requestLog.Clear();$script:fixtureMode='HttpError'
    $httpError=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($httpError.Status -ceq 'NotTested' -and (@($httpError.Assets|Where-Object {$_.Route -ceq '/ui/console.css' -and $_.Status -ceq 'NotTested'}).Count -eq 1)) 'non-200 asset responses are NotTested'

    $fixtureSrc=Join-Path $testRoot 'missing-src'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixtureSrc 'ui'))
    Copy-Item -LiteralPath $probePath -Destination (Join-Path $fixtureSrc 'AssistiveHttpProbe.ps1')
    foreach($name in @('index.html','console.js','console.css')){Copy-Item -LiteralPath (Join-Path $fixtureUi $name) -Destination (Join-Path (Join-Path $fixtureSrc 'ui') $name)}
    $output=Join-Path $testRoot 'missing-asset-probe'
    $script:fixtureMode='Match'
    . (Join-Path $fixtureSrc 'AssistiveHttpProbe.ps1')
    $missing=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($missing.Status -ceq 'NotTested' -and (@($missing.Assets|Where-Object {$_.Route -ceq '/ui/guide.html' -and $_.Status -ceq 'NotTested' -and $_.AssetError}).Count -eq 1)) 'a missing local asset is NotTested'

    . $probePath
    $output=Join-Path $testRoot 'session-error-probe'
    $script:fixtureMode='SessionError'
    $sessionError=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($sessionError.Status -ceq 'NotTested' -and $sessionError.Error) 'session endpoint errors are NotTested without throwing or exposing data'

    $savedHash=(Get-FileHash -LiteralPath $sessionError.JsonPath -Algorithm SHA256).Hash;$rejected=$false;try{Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter|Out-Null}catch{$rejected=$true};Assert-Probe ($rejected -and (Get-FileHash -LiteralPath $sessionError.JsonPath -Algorithm SHA256).Hash -ceq $savedHash) 'an existing probe document cannot be overwritten'
    Write-Host ('PASS: '+$checkCount+' HTTP probe fixture checks on '+$PSVersionTable.PSEdition+' '+$PSVersionTable.PSVersion)
} finally {
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
