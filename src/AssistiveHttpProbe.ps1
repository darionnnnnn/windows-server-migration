function Export-WsmAssistiveHttpProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Origin,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(DontShow)][scriptblock]$RequestAdapter
    )

    $ErrorActionPreference = 'Stop'

function Get-WsmProbeHeaderValue($Response,[string]$Name) {
    if($Response.Headers.ContainsKey($Name)){return [string]$Response.Headers[$Name]}
    return $null
}

function Invoke-WsmProbeGet($Client,[uri]$Uri,[scriptblock]$Adapter) {
    if($Adapter){return & $Adapter 'GET' $Uri}
    $response=$Client.GetAsync($Uri).GetAwaiter().GetResult()
    try{
        $headers=@{}
        $values=$null
        foreach($name in @('Content-Type','Content-Length','Connection','X-Content-Type-Options','Referrer-Policy','Content-Security-Policy')){
            if($response.Headers.TryGetValues($name,[ref]$values) -or $response.Content.Headers.TryGetValues($name,[ref]$values)){$headers[$name]=@($values) -join ', '}
            else{$headers[$name]=$null}
            $values=$null
        }
        [pscustomobject]@{StatusCode=[int]$response.StatusCode;Body=([byte[]]$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult());Headers=$headers}
    }finally{$response.Dispose()}
}

function Get-WsmProbeSha256([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Assert-WsmProbeNoReparse([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetPathRoot($full)
    $current=$root
    $remainder=$full.Substring($root.Length)
    foreach($part in @($remainder -split '[\\/]+' | Where-Object {$_})){
        $current=Join-Path $current $part
        if([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)){
            if(([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Probe paths cannot traverse reparse points.'}
        }
    }
}

function ConvertTo-WsmProbeHtml([string]$Value) {
    if($null -eq $Value){return ''}
    [Net.WebUtility]::HtmlEncode($Value)
}

    if($Origin.Scheme -cne 'http' -or $Origin.Host -cne '127.0.0.1' -or $Origin.Port -lt 1 -or $Origin.UserInfo -or $Origin.Query -or $Origin.Fragment -or $Origin.AbsolutePath -ne '/') {
        throw 'Origin must be the local console origin, for example http://127.0.0.1:12345.'
    }

    $fullOutput=[IO.Path]::GetFullPath($OutputPath)
$outputDirectory=[IO.Path]::GetDirectoryName($fullOutput)
if(-not [IO.Directory]::Exists($outputDirectory)){throw 'Output directory does not exist.'}
$jsonPath=[IO.Path]::ChangeExtension($fullOutput,'.json')
$htmlPath=[IO.Path]::ChangeExtension($fullOutput,'.html')
Assert-WsmProbeNoReparse $outputDirectory
foreach($candidate in @($jsonPath,$htmlPath)){Assert-WsmProbeNoReparse $candidate;if([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)){throw 'Probe output exists; choose a new revisioned filename.'}}

$assets=@(
    @{Route='/ui/index.html';File=(Join-Path $PSScriptRoot 'ui/index.html');ContentType='text/html; charset=utf-8'},
    @{Route='/ui/console.js';File=(Join-Path $PSScriptRoot 'ui/console.js');ContentType='application/javascript; charset=utf-8'},
    @{Route='/ui/console.css';File=(Join-Path $PSScriptRoot 'ui/console.css');ContentType='text/css; charset=utf-8'},
    @{Route='/ui/guide.html';File=(Join-Path $PSScriptRoot 'ui/guide.html');ContentType='text/html; charset=utf-8'}
)
    # Continue below inside this exported function; dot-sourcing this file only defines it.
$expectedHeaders=@{
    'X-Content-Type-Options'='nosniff'
    'Referrer-Policy'='no-referrer'
    'Connection'='close'
    'Content-Security-Policy'="default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
}
    $records=@()
    $handler=$null;$client=$null
    if(-not $RequestAdapter){
        Add-Type -AssemblyName System.Net.Http
        $handler=[System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy=$false
        $handler.AllowAutoRedirect=$false
        $client=[System.Net.Http.HttpClient]::new($handler)
        $client.Timeout=[TimeSpan]::FromSeconds(8)
    }
    $state='NotTested'
    $errorSummary=$null
    $sessionResponse=$null
try {
    $sessionResponse=Invoke-WsmProbeGet $client ([uri]::new($Origin,'/api/session')) $RequestAdapter
    if([int]$sessionResponse.StatusCode -lt 200 -or [int]$sessionResponse.StatusCode -ge 300){throw ('Session endpoint returned HTTP '+[int]$sessionResponse.StatusCode)}
    $sessionText=(New-Object Text.UTF8Encoding($false,$true)).GetString([byte[]]$sessionResponse.Body)
    $session=$sessionText | ConvertFrom-Json
    $serverHashes=$session.assetHashes
    if(-not $serverHashes){throw 'Session response did not include static asset hashes.'}
    $sessionText=$null;$session=$null
    foreach($asset in $assets){
        $serverHashProperty=$serverHashes.PSObject.Properties[$asset.Route]
        $serverHash=if($serverHashProperty){[string]$serverHashProperty.Value}else{$null}
        $localBytes=$null
        $localHash=$null
        $entry=[ordered]@{
            Route=$asset.Route
            LocalSHA256=$localHash
            SessionSHA256=$serverHash
            ExpectedBytes=$localBytes.Length
            ObservedBytes=$null
            ObservedSHA256=$null
            HTTPStatus=$null
            ObservedContentType=$null
            ObservedContentLength=$null
            ObservedSecurityHeaders=@{}
            BodyMatchesDisk=$false
            HeadersMatchExpected=$false
            Status='NotTested'
        }
        try{
            Assert-WsmProbeNoReparse $asset.File
            $localBytes=[IO.File]::ReadAllBytes($asset.File)
            $localHash=Get-WsmProbeSha256 $localBytes
            $entry.LocalSHA256=$localHash
            $entry.ExpectedBytes=$localBytes.Length
        }catch{
            $entry.AssetError=$_.Exception.GetType().Name
            $records+=,[pscustomobject]$entry
            continue
        }
        try {
            $response=Invoke-WsmProbeGet $client ([uri]::new($Origin,$asset.Route)) $RequestAdapter
            $body=[byte[]]$response.Body
            $entry.HTTPStatus=[int]$response.StatusCode
            $entry.ObservedBytes=$body.Length
            $entry.ObservedSHA256=Get-WsmProbeSha256 $body
            $entry.ObservedContentType=Get-WsmProbeHeaderValue $response 'Content-Type'
            $entry.ObservedContentLength=$response.Headers['Content-Length']
            foreach($name in $expectedHeaders.Keys){$entry.ObservedSecurityHeaders[$name]=Get-WsmProbeHeaderValue $response $name}
            if($entry.HTTPStatus -ne 200){$entry.Status='NotTested';$entry.TransportError='UnexpectedHttpStatus'}
            else {
            $entry.BodyMatchesDisk=($entry.HTTPStatus -eq 200 -and $entry.ObservedBytes -eq $localBytes.Length -and $entry.ObservedSHA256 -ceq $localHash -and $serverHash -ceq $localHash)
            $headersMatch=($entry.ObservedContentType -ceq $asset.ContentType -and [string]$entry.ObservedContentLength -ceq [string]$localBytes.Length)
            foreach($name in $expectedHeaders.Keys){if($entry.ObservedSecurityHeaders[$name] -cne $expectedHeaders[$name]){$headersMatch=$false}}
            $entry.HeadersMatchExpected=$headersMatch
            $entry.Status=if($entry.BodyMatchesDisk -and $headersMatch){'ObservedMatches'}else{'ModifiedTransport'}
            }
        } catch {
            $entry.Status='NotTested'
            $entry.TransportError=$_.Exception.GetType().Name
        }
        $records+=,[pscustomobject]$entry
        $localBytes=$null;$body=$null
    }
    if(@($records|Where-Object Status -eq 'NotTested').Count){$state='NotTested'}
    elseif(@($records|Where-Object Status -eq 'ModifiedTransport').Count){$state='ModifiedTransport'}
    else{$state='ObservedMatches'}
} catch {
    $errorSummary=$_.Exception.GetType().Name
    $state='NotTested'
} finally {
    if($sessionResponse){$sessionResponse=$null}
    if($client){$client.Dispose()};if($handler){$handler.Dispose()}
}

$result=[pscustomobject]@{
    Status=$state
    ProbedUtc=[DateTime]::UtcNow.ToString('o')
    Origin=$Origin.GetLeftPart([UriPartial]::Authority)
    Scope='Read-only GET checks of four local console assets; no operation/job/report endpoints are called.'
    Error=$errorSummary
    Assets=@($records)
}
    $json=$result|ConvertTo-Json -Depth 8
    $stream=[IO.File]::Open($jsonPath,'CreateNew','Write','None');try{$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
$tableRows=foreach($assetResult in @($records)){
    '<tr><td>'+ (ConvertTo-WsmProbeHtml $assetResult.Route) +'</td><td>'+ (ConvertTo-WsmProbeHtml $assetResult.Status) +'</td><td>'+ (ConvertTo-WsmProbeHtml ([string]$assetResult.LocalSHA256)) +'</td><td>'+ (ConvertTo-WsmProbeHtml ([string]$assetResult.ObservedSHA256)) +'</td><td>'+ (ConvertTo-WsmProbeHtml ([string]$assetResult.ExpectedBytes)) +'</td><td>'+ (ConvertTo-WsmProbeHtml ([string]$assetResult.ObservedBytes)) +'</td><td><pre>'+ (ConvertTo-WsmProbeHtml (($assetResult.ObservedSecurityHeaders|ConvertTo-Json -Compress -Depth 3))) +'</pre></td></tr>'
}
$page='<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Local HTTP integrity probe</title><style>body{font:16px/1.5 system-ui,sans-serif;margin:2rem;max-width:100rem}table{border-collapse:collapse;width:100%}th,td{border:1px solid #bbc4ce;padding:.5rem;text-align:left;overflow-wrap:anywhere}pre{white-space:pre-wrap;margin:0}.status{font-weight:700}</style><h1>Local HTTP integrity probe</h1><p class="status">Status: '+(ConvertTo-WsmProbeHtml $state)+'</p><p>This probe only reads session metadata and four static assets. It does not call operation, job, or report endpoints. Results describe this environment at this time.</p><p>Time (UTC): '+(ConvertTo-WsmProbeHtml $result.ProbedUtc)+'</p><table><thead><tr><th>Asset</th><th>Status</th><th>Disk SHA-256</th><th>Received SHA-256</th><th>Expected bytes</th><th>Received bytes</th><th>Observed security headers</th></tr></thead><tbody>'+($tableRows -join '')+'</tbody></table><p>JSON: '+(ConvertTo-WsmProbeHtml $jsonPath)+'</p></html>'
    $stream=[IO.File]::Open($htmlPath,'CreateNew','Write','None');try{$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($page);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    $result|Add-Member NoteProperty JsonPath $jsonPath -Force
    $result|Add-Member NoteProperty HtmlPath $htmlPath -Force
    return $result
}
