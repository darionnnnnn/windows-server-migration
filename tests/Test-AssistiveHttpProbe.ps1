$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-http-probe-test-'+[Guid]::NewGuid().ToString('N'))
$repoRoot=Split-Path -Parent $PSScriptRoot
$probePath=Join-Path $repoRoot 'src\AssistiveHttpProbe.ps1'
$fixtureUi=Join-Path $repoRoot 'src\ui'
$script:requestLog=New-Object 'System.Collections.Generic.List[string]'
$script:fixtureMode='Match'
$script:fixtureUi=$fixtureUi
$checkCount=0
Add-Type -AssemblyName System.Net.Http

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
        if($script:fixtureMode -ceq 'SessionExpired'){$bytes=[Text.Encoding]::UTF8.GetBytes('session body secret');return [pscustomobject]@{StatusCode=401;Body=$bytes;Headers=(Get-FixtureHeaders 'text/plain' $bytes.Length)}}
        if($script:fixtureMode -ceq 'SessionForbidden'){$bytes=[Text.Encoding]::UTF8.GetBytes('forbidden body secret');return [pscustomobject]@{StatusCode=403;Body=$bytes;Headers=(Get-FixtureHeaders 'text/plain' $bytes.Length)}}
        if($script:fixtureMode -ceq 'InvalidSession'){$bytes=[Text.Encoding]::UTF8.GetBytes('<html>body-secret token=canary-token</html>');return [pscustomobject]@{StatusCode=200;Body=$bytes;Headers=(Get-FixtureHeaders 'text/html' $bytes.Length)}}
        $hashes=@{}
        foreach($name in @('index.html','console.js','console.css','guide.html')){$bytes=[IO.File]::ReadAllBytes((Join-Path $script:fixtureUi $name));$hashes['/ui/'+$name]=Get-FixtureHash $bytes}
        if($script:fixtureMode -ceq 'SessionHashMissing'){$hashes.Remove('/ui/guide.html')}
        if($script:fixtureMode -ceq 'SessionHashInvalid'){$hashes['/ui/guide.html']='https://session-hash-canary.invalid/?token=secret-canary'}
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
        $csp="default-src 'self'; script-src 'self' https://header-canary.invalid/x?token=header-secret-canary; <script>alert(1)</script>"
    }
    if($script:fixtureMode -ceq 'HttpError' -and $assetName -ceq 'console.css'){$status=503}
    if($script:fixtureMode -ceq 'TransportError' -and $assetName -ceq 'console.js'){throw [IO.IOException]::new('fixture transport failure')}
    if($script:fixtureMode -ceq 'NestedReset' -and $assetName -ceq 'console.js'){$socket=[Net.Sockets.SocketException]::new([int][Net.Sockets.SocketError]::ConnectionReset);throw [Net.Http.HttpRequestException]::new('exception-message-canary https://127.0.0.1:49231/path?token=url-canary',([IO.IOException]::new('body-canary',$socket)))}
    if($script:fixtureMode -ceq 'NestedAggregateReset' -and $assetName -ceq 'console.js'){$socket=[Net.Sockets.SocketException]::new([int][Net.Sockets.SocketError]::ConnectionReset);$deep=[Exception]::new('deep exception canary',$socket);for($i=0;$i -lt 10;$i++){$deep=[AggregateException]::new('aggregate exception canary',[Exception[]]@($deep))};throw $deep}
    if($script:fixtureMode -ceq 'MixedAggregateReset' -and $assetName -ceq 'console.js'){$unknown=[IO.IOException]::new('unknown exception canary');$socket=[Net.Sockets.SocketException]::new([int][Net.Sockets.SocketError]::ConnectionReset);$known=[AggregateException]::new('known aggregate canary',[Exception[]]@($socket));throw [AggregateException]::new('mixed aggregate canary',[Exception[]]@($unknown,$known))}
    if($script:fixtureMode -ceq 'Aborted' -and $assetName -ceq 'console.js'){$socket=[Net.Sockets.SocketException]::new([int][Net.Sockets.SocketError]::ConnectionAborted);throw $socket}
    if($script:fixtureMode -ceq 'Timeout' -and $assetName -ceq 'console.js'){throw [Threading.Tasks.TaskCanceledException]::new('timeout-message-canary token=exception-canary')}
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
    Assert-Probe ($matching.FailureCode -ceq 'None' -and $matching.Stage -ceq 'Completed' -and $matching.NextAction) 'successful probe has stable typed diagnostic fields'
    Assert-Probe ($matching.OriginKind -ceq 'LocalLoopback' -and $matching.OriginPort -eq 49231 -and -not $matching.PSObject.Properties['Origin']) 'saved output records only validated local origin facts'
    Assert-Probe ($script:requestLog.Count -eq 5) 'the probe requests only session and four assets'
    Assert-Probe (@($script:requestLog|Where-Object {$_ -notmatch '^GET '}).Count -eq 0) 'all probe requests are GET'
    $matchingJson=Get-Content -LiteralPath $matching.JsonPath -Raw
    $matchingHtml=Get-Content -LiteralPath $matching.HtmlPath -Raw
    Assert-Probe ($matchingJson -notmatch 'fixture-secret-token-must-not-leak' -and $matchingHtml -notmatch 'fixture-secret-token-must-not-leak') 'session token is excluded from JSON and HTML'
    $module=Import-Module (Join-Path $repoRoot 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
    $projected=& $module {param($row) @(Get-WsmHtmlResultProjection @($row))} $matching
    Assert-Probe ($projected.FailureCode -ceq 'None' -and $projected.Stage -ceq 'Completed' -and $projected.NextAction -ceq $matching.NextAction) 'the real CLI and saved-job safe projection retains diagnostic fields'

    $output=Join-Path $testRoot 'changed-probe'
    $script:requestLog.Clear();$script:fixtureMode='BodyAndHeaderChanged'
    $changed=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    $indexResult=@($changed.Assets|Where-Object Route -CEQ '/ui/index.html')[0]
    $changedHtml=Get-Content -LiteralPath $changed.HtmlPath -Raw;$changedJson=Get-Content -LiteralPath $changed.JsonPath -Raw
    Assert-Probe ($changed.Status -ceq 'ModifiedTransport' -and $changed.FailureCode -ceq 'AssetIntegrityMismatch' -and $changed.Stage -ceq 'AssetIntegrity') 'changed body or CSP is reported as modified transport with a stable category'
    Assert-Probe (-not $indexResult.BodyMatchesDisk -and -not $indexResult.HeadersMatchExpected) 'the changed body and security headers are both detected'
    Assert-Probe ($changedHtml -match '\[unrecognized header value omitted\]' -and $changedHtml -notmatch '<script>alert\(1\)</script>') 'unexpected header values are withheld and cannot inject markup'
    Assert-Probe (($changedJson+$changedHtml) -notmatch 'header-canary|https://|token=') 'observed header URLs and query secrets are absent from saved artifacts'
    Assert-Probe ($changedJson -notmatch 'fixture-secret-token-must-not-leak') 'mutated probe JSON still excludes the session token'

    $output=Join-Path $testRoot 'transport-error-probe'
    $script:requestLog.Clear();$script:fixtureMode='TransportError'
    $transportError=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($transportError.Status -ceq 'NotTested' -and (@($transportError.Assets|Where-Object {$_.Route -ceq '/ui/console.js' -and $_.Status -ceq 'NotTested'}).Count -eq 1)) 'transport failures are NotTested'
    Assert-Probe ($transportError.FailureCode -ceq 'UnknownTransportFailure' -and $transportError.Stage -ceq 'AssetRequest') 'unclassified wrapped/network details remain unknown'

    $output=Join-Path $testRoot 'nested-reset-probe'
    $script:fixtureMode='NestedReset'
    $nestedReset=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    $nestedJson=Get-Content -LiteralPath $nestedReset.JsonPath -Raw;$nestedHtml=Get-Content -LiteralPath $nestedReset.HtmlPath -Raw
    Assert-Probe ($nestedReset.FailureCode -ceq 'ConnectionResetObserved' -and $nestedReset.Stage -ceq 'AssetRequest') 'nested allowlisted socket reset is classified deterministically'
    Assert-Probe (($nestedJson+$nestedHtml) -notmatch 'exception-message-canary|body-canary|url-canary|exception-canary') 'nested error messages, bodies and URLs are absent from saved diagnostics'

    $output=Join-Path $testRoot 'deep-aggregate-probe'
    $script:fixtureMode='NestedAggregateReset'
    $deepAggregate=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($deepAggregate.FailureCode -ceq 'UnknownTransportFailure' -and $deepAggregate.Stage -ceq 'AssetRequest') 'a recognized socket error beyond the global nested-exception depth limit remains unknown'

    $output=Join-Path $testRoot 'mixed-aggregate-probe'
    $script:fixtureMode='MixedAggregateReset'
    $mixedAggregate=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($mixedAggregate.FailureCode -ceq 'ConnectionResetObserved' -and $mixedAggregate.Stage -ceq 'AssetRequest') 'bounded traversal checks later aggregate branches after an unknown branch and finds allowlisted evidence'

    $output=Join-Path $testRoot 'aborted-probe'
    $script:fixtureMode='Aborted'
    $aborted=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($aborted.FailureCode -ceq 'ConnectionAbortedObserved' -and $aborted.Stage -ceq 'AssetRequest') 'connection aborted is kept distinct from an observed peer reset'

    $output=Join-Path $testRoot 'timeout-probe'
    $script:fixtureMode='Timeout'
    $timeoutResult=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($timeoutResult.FailureCode -ceq 'RequestTimedOut' -and $timeoutResult.Stage -ceq 'AssetRequest') 'allowlisted request timeout has a stable category'
    Assert-Probe ((Get-Content -LiteralPath $timeoutResult.JsonPath -Raw) -notmatch 'timeout-message-canary|exception-canary') 'timeout exception text is not saved'

    $output=Join-Path $testRoot 'http-error-probe'
    $script:requestLog.Clear();$script:fixtureMode='HttpError'
    $httpError=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    $httpAsset=@($httpError.Assets|Where-Object Route -CEQ '/ui/console.css')[0]
    Assert-Probe ($httpError.Status -ceq 'NotTested' -and $httpAsset.Status -ceq 'NotTested' -and $httpAsset.FailureCode -ceq 'AssetHttpFailure' -and $httpAsset.Stage -ceq 'Asset') 'non-200 asset responses are NotTested and safely classified'

    $fixtureSrc=Join-Path $testRoot 'missing-src'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixtureSrc 'ui'))
    Copy-Item -LiteralPath $probePath -Destination (Join-Path $fixtureSrc 'AssistiveHttpProbe.ps1')
    foreach($name in @('index.html','console.js','console.css')){Copy-Item -LiteralPath (Join-Path $fixtureUi $name) -Destination (Join-Path (Join-Path $fixtureSrc 'ui') $name)}
    $output=Join-Path $testRoot 'missing-asset-probe'
    $script:fixtureMode='Match'
    . (Join-Path $fixtureSrc 'AssistiveHttpProbe.ps1')
    $missing=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    $missingSaved=Get-Content -LiteralPath $missing.JsonPath -Raw;$missingHtml=Get-Content -LiteralPath $missing.HtmlPath -Raw
    $missingGuide=@($missing.Assets|Where-Object Route -CEQ '/ui/guide.html')[0]
    Assert-Probe ($missing.Status -ceq 'NotTested' -and $missingGuide.Status -ceq 'NotTested' -and $missingGuide.FailureCode -ceq 'LocalAssetMissing' -and $missingGuide.Stage -ceq 'LocalAsset' -and $missingGuide.NextAction) 'a missing local asset is classified with a recovery step'
    Assert-Probe (($missingSaved+$missingHtml) -notmatch 'fixture-secret-token-must-not-leak|Exception|System\.IO') 'missing asset artifacts omit tokens and raw exception details'

    . $probePath
    $output=Join-Path $testRoot 'session-error-probe'
    $script:fixtureMode='SessionError'
    $sessionError=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($sessionError.Status -ceq 'NotTested' -and $sessionError.Error) 'session endpoint errors are NotTested without throwing or exposing data'
    Assert-Probe ($sessionError.FailureCode -ceq 'SessionHttpFailure' -and $sessionError.Stage -ceq 'Session' -and $sessionError.NextAction) 'session HTTP failure provides safe actionable classification'
    $failureProjection=& $module {param($row) @(Get-WsmHtmlResultProjection @($row))} $sessionError
    Assert-Probe ($failureProjection.FailureCode -ceq 'SessionHttpFailure' -and $failureProjection.Stage -ceq 'Session' -and $failureProjection.NextAction -ceq $sessionError.NextAction) 'the existing durable-job safe projection retains a real probe failure category and next step'
    $sessionErrorHtml=[IO.File]::ReadAllText($sessionError.HtmlPath,[Text.Encoding]::UTF8)
    Assert-Probe ($sessionErrorHtml.Contains('SessionHttpFailure') -and $sessionErrorHtml.Contains($sessionError.NextAction)) 'saved HTML renders the same safe category and action'

    $output=Join-Path $testRoot 'session-expired-probe';$script:fixtureMode='SessionExpired'
    $expired=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($expired.FailureCode -ceq 'SessionExpired' -and $expired.Stage -ceq 'Session') '401 session response is classified as an expired session'
    $output=Join-Path $testRoot 'session-forbidden-probe';$script:fixtureMode='SessionForbidden'
    $forbidden=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ($forbidden.FailureCode -ceq 'SessionAccessDenied' -and $forbidden.Stage -ceq 'Session') '403 is access denied, not inferred to mean an expired session'
    $output=Join-Path $testRoot 'invalid-session-probe';$script:fixtureMode='InvalidSession'
    $invalidSession=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    $invalidSaved=Get-Content -LiteralPath $invalidSession.JsonPath -Raw;$invalidHtml=Get-Content -LiteralPath $invalidSession.HtmlPath -Raw
    Assert-Probe ($invalidSession.FailureCode -ceq 'InvalidSessionResponse' -and $invalidSession.Stage -ceq 'Session') 'non-JSON session body is classified without parsing details'
    Assert-Probe (($invalidSaved+$invalidHtml) -notmatch 'body-secret|canary-token|<html>') 'session response body is omitted from JSON and HTML'

    $output=Join-Path $testRoot 'session-hash-missing-probe';$script:fixtureMode='SessionHashMissing'
    $missingSessionHash=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    $hashMissingAsset=@($missingSessionHash.Assets|Where-Object Route -CEQ '/ui/guide.html')[0]
    Assert-Probe ($hashMissingAsset.FailureCode -ceq 'SessionAssetHashMissing' -and $hashMissingAsset.Stage -ceq 'Session' -and $missingSessionHash.FailureCode -ceq 'SessionAssetHashMissing') 'missing per-asset session hash is distinct from a modified transport'
    $output=Join-Path $testRoot 'session-hash-invalid-probe';$script:fixtureMode='SessionHashInvalid'
    $invalidSessionHash=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter
    Assert-Probe ((@($invalidSessionHash.Assets|Where-Object Route -CEQ '/ui/guide.html')[0]).FailureCode -ceq 'SessionAssetHashInvalid') 'malformed per-asset session hash is rejected safely'
    $invalidHashSaved=Get-Content -LiteralPath $invalidSessionHash.JsonPath -Raw;Assert-Probe ($invalidHashSaved -notmatch 'session-hash-canary|https://|token=secret-canary') 'untrusted malformed session hash value is omitted from saved output'

    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$closedPort=[int]([Net.IPEndPoint]$listener.LocalEndpoint).Port;$listener.Stop()
    $output=Join-Path $testRoot 'closed-listener-probe'
    $closedListener=Export-WsmAssistiveHttpProbe -Origin ([uri]('http://127.0.0.1:'+$closedPort+'/')) -OutputPath $output
    Assert-Probe ($closedListener.FailureCode -ceq 'ListenerUnavailable' -and $closedListener.Stage -ceq 'Session') 'a real closed loopback port is identified as listener unavailable'
    $closedJson=Get-Content -LiteralPath $closedListener.JsonPath -Raw;$closedHtml=Get-Content -LiteralPath $closedListener.HtmlPath -Raw
    Assert-Probe (($closedJson+$closedHtml) -notmatch '127\.0\.0\.1|http://|https://') 'saved probe artifacts contain no origin URL'

    $savedHash=(Get-FileHash -LiteralPath $sessionError.JsonPath -Algorithm SHA256).Hash;$rejected=$false;try{Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath $output -RequestAdapter $script:requestAdapter|Out-Null}catch{$rejected=$true};Assert-Probe ($rejected -and (Get-FileHash -LiteralPath $sessionError.JsonPath -Algorithm SHA256).Hash -ceq $savedHash) 'an existing probe document cannot be overwritten'

    $module=Import-Module (Join-Path $repoRoot 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
    $baselineFailure=& $module {Set-StrictMode -Version Latest;$localBytes=$null;try{$entry=[ordered]@{ExpectedBytes=$localBytes.Length};'NoFailure'}catch{$_.Exception.GetType().Name}}
    Assert-Probe ($baselineFailure -ceq 'PropertyNotFoundException') 'the original null .Length initializer is a reproducible strict-mode regression'
    $capturedUi=$fixtureUi;$capturedCalls=New-Object 'System.Collections.Generic.List[string]';$moduleHashes=@{}
    foreach($name in @('index.html','console.js','console.css','guide.html')){$moduleHashes['/ui/'+$name]=Get-FixtureHash ([IO.File]::ReadAllBytes((Join-Path $capturedUi $name)))}
    $moduleAdapter={
        param($Method,$Uri)
        [void]$capturedCalls.Add($Method+' '+$Uri.AbsolutePath)
        if($Uri.AbsolutePath -ceq '/api/session'){$body=[Text.Encoding]::UTF8.GetBytes((@{assetHashes=$moduleHashes}|ConvertTo-Json -Compress));return [pscustomobject]@{StatusCode=200;Body=$body;Headers=@{'Content-Type'='application/json; charset=utf-8';'Content-Length'=[string]$body.Length}}}
        $file=Join-Path $capturedUi (Split-Path $Uri.AbsolutePath -Leaf);$body=[IO.File]::ReadAllBytes($file);$contentType=switch([IO.Path]::GetExtension($file)){'.html'{'text/html; charset=utf-8'}'.js'{'application/javascript; charset=utf-8'}'.css'{'text/css; charset=utf-8'}}
        return [pscustomobject]@{StatusCode=200;Body=$body;Headers=@{'Content-Type'=$contentType;'Content-Length'=[string]$body.Length;'Connection'='close';'X-Content-Type-Options'='nosniff';'Referrer-Policy'='no-referrer';'Content-Security-Policy'="default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"}}
    }.GetNewClosure()
    $moduleOutput=Join-Path $testRoot 'strict-module-probe'
    $moduleResult=& $module {param($ProbeOrigin,$ProbeOutput,$ProbeAdapter) Export-WsmAssistiveHttpProbe -Origin $ProbeOrigin -OutputPath $ProbeOutput -RequestAdapter $ProbeAdapter} $origin $moduleOutput $moduleAdapter
    Assert-Probe ($moduleResult.Status -ceq 'ObservedMatches' -and $moduleResult.Assets.Count -eq 4 -and @($moduleResult.Assets|Where-Object Status -NE 'ObservedMatches').Count -eq 0 -and $moduleResult.Error -eq $null -and $moduleResult.FailureCode -ceq 'None') 'the exported function in the real imported module works under strict mode with all four verified assets'
    Assert-Probe ($capturedCalls.Count -eq 5 -and @($capturedCalls|Where-Object {$_ -notmatch '^GET '}).Count -eq 0) 'the strict-mode imported-module consumer remains read-only and requests only session plus four assets'
    Write-Host ('PASS: '+$checkCount+' HTTP probe fixture checks on '+$PSVersionTable.PSEdition+' '+$PSVersionTable.PSVersion)
} finally {
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
