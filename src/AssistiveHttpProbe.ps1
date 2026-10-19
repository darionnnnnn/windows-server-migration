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

function Get-WsmProbeExceptionFailure($Exception,[string]$Stage) {
    $maxDepth=8
    $maxNodes=32
    $pending=New-Object 'System.Collections.Generic.Queue[object]'
    if($null -ne $Exception){$pending.Enqueue([pscustomobject]@{Exception=$Exception;Depth=0})}
    $discovered=if($null -ne $Exception){1}else{0}
    while($pending.Count -gt 0 -and $discovered -le $maxNodes){
        $node=$pending.Dequeue()
        $current=$node.Exception
        $depth=[int]$node.Depth
        if($current -is [System.Net.Sockets.SocketException]){
            switch([string]$current.SocketErrorCode){
                'ConnectionRefused' {return [pscustomobject]@{FailureCode='ListenerUnavailable';Stage=$Stage;NextAction='確認本機管理介面仍在執行，並核對目前的連接埠。'} }
                'ConnectionReset' {return [pscustomobject]@{FailureCode='ConnectionResetObserved';Stage=$Stage;NextAction='連線遭對端重設；確認本機服務狀態後重新執行唯讀檢查。'} }
                'ConnectionAborted' {return [pscustomobject]@{FailureCode='ConnectionAbortedObserved';Stage=$Stage;NextAction='連線遭中止；確認本機服務狀態後重新執行唯讀檢查。'} }
                'TimedOut' {return [pscustomobject]@{FailureCode='RequestTimedOut';Stage=$Stage;NextAction='本機請求逾時；確認服務可回應後重新執行唯讀檢查。'} }
            }
        }
        if($current -is [System.TimeoutException] -or $current -is [System.Threading.Tasks.TaskCanceledException]){
            return [pscustomobject]@{FailureCode='RequestTimedOut';Stage=$Stage;NextAction='本機請求逾時；確認服務可回應後重新執行唯讀檢查。'}
        }
        if($depth -lt $maxDepth){
            if($current -is [System.AggregateException]){
                foreach($inner in $current.InnerExceptions){
                    if($discovered -ge $maxNodes){break}
                    if($null -ne $inner){$pending.Enqueue([pscustomobject]@{Exception=$inner;Depth=$depth+1});$discovered++}
                }
            }elseif($null -ne $current.InnerException -and $discovered -lt $maxNodes){
                $pending.Enqueue([pscustomobject]@{Exception=$current.InnerException;Depth=$depth+1})
                $discovered++
            }
        }
    }
    return [pscustomobject]@{FailureCode='UnknownTransportFailure';Stage=$Stage;NextAction='無法判定連線失敗原因；檢查本機服務與連線狀態，再重新執行唯讀檢查。'}
}

function Get-WsmProbeHttpFailure([int]$StatusCode,[string]$Stage) {
    if($StatusCode -eq 401){return [pscustomobject]@{FailureCode='SessionExpired';Stage=$Stage;NextAction='本機工作階段已失效；重新開啟管理介面後再檢查。'}}
    if($StatusCode -eq 403){return [pscustomobject]@{FailureCode='SessionAccessDenied';Stage=$Stage;NextAction='本機端點拒絕讀取；確認目前帳戶與管理介面存取設定。'}}
    if($Stage -ceq 'Session') {return [pscustomobject]@{FailureCode='SessionHttpFailure';Stage=$Stage;NextAction='工作階段端點未成功回應；確認管理介面狀態後重新檢查。'}}
    return [pscustomobject]@{FailureCode='AssetHttpFailure';Stage=$Stage;NextAction='靜態頁面端點未成功回應；確認管理介面檔案與服務狀態。'}
}

function Get-WsmProbeLocalAssetFailure($Exception,[string]$Stage) {
    $current=$Exception
    for($depth=0;$null -ne $current -and $depth -lt 8;$depth++){
        if($current -is [System.IO.FileNotFoundException] -or $current -is [System.IO.DirectoryNotFoundException] -or $current -is [System.Management.Automation.ItemNotFoundException]){
            return [pscustomobject]@{FailureCode='LocalAssetMissing';Stage=$Stage;NextAction='本機頁面檔案缺失；從可信的專案發行內容還原該檔案。'}
        }
        $current=$current.InnerException
    }
    return [pscustomobject]@{FailureCode='LocalAssetReadFailure';Stage=$Stage;NextAction='無法讀取本機頁面檔案；檢查檔案權限與完整性。'}
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
    $failureDetails=$null
    $sessionResponse=$null
try {
    try{$sessionResponse=Invoke-WsmProbeGet $client ([uri]::new($Origin,'/api/session')) $RequestAdapter}
    catch{$failureDetails=Get-WsmProbeExceptionFailure $_.Exception 'Session'}
    if(-not $failureDetails -and ([int]$sessionResponse.StatusCode -lt 200 -or [int]$sessionResponse.StatusCode -ge 300)){
        $failureDetails=Get-WsmProbeHttpFailure ([int]$sessionResponse.StatusCode) 'Session'
    }
    if(-not $failureDetails){
        try{
            $sessionText=(New-Object Text.UTF8Encoding($false,$true)).GetString([byte[]]$sessionResponse.Body)
            $session=$sessionText | ConvertFrom-Json -ErrorAction Stop
            $hashesProperty=$session.PSObject.Properties['assetHashes']
            $serverHashes=if($hashesProperty){$hashesProperty.Value}else{$null}
            if(-not $serverHashes){$failureDetails=[pscustomobject]@{FailureCode='SessionAssetHashesMissing';Stage='Session';NextAction='工作階段回應未提供頁面完整性資料；確認管理介面版本與服務狀態。'}}
            $sessionText=$null;$session=$null
        }catch{$failureDetails=[pscustomobject]@{FailureCode='InvalidSessionResponse';Stage='Session';NextAction='工作階段回應格式無法驗證；確認管理介面版本與服務狀態。'}}
    }
    if(-not $failureDetails){foreach($asset in $assets){
        $serverHashProperty=$serverHashes.PSObject.Properties[$asset.Route]
        $serverHashRaw=if($serverHashProperty){[string]$serverHashProperty.Value}else{$null}
        $serverHashValid=($serverHashRaw -match '^[a-fA-F0-9]{64}$')
        $serverHash=if($serverHashValid){$serverHashRaw.ToLowerInvariant()}else{$null}
        $localBytes=$null
        $localHash=$null
        $entry=[ordered]@{
            Route=$asset.Route
            LocalSHA256=$localHash
            SessionSHA256=$serverHash
            ExpectedBytes=$null
            ObservedBytes=$null
            ObservedSHA256=$null
            HTTPStatus=$null
            ObservedContentType=$null
            ObservedContentLength=$null
            ObservedSecurityHeaders=@{}
            BodyMatchesDisk=$false
            HeadersMatchExpected=$false
            Status='NotTested'
            FailureCode='Unknown'
            Stage='LocalAsset'
            NextAction='檢查本機頁面檔案與權限。'
        }
        if(-not $serverHashValid){
            $entry.Status='NotTested';$entry.FailureCode=if([string]::IsNullOrWhiteSpace($serverHashRaw)){'SessionAssetHashMissing'}else{'SessionAssetHashInvalid'};$entry.Stage='Session';$entry.NextAction='工作階段未提供有效的頁面指紋；確認管理介面版本與服務狀態。';$records+=,[pscustomobject]$entry;continue
        }
        try{
            Assert-WsmProbeNoReparse $asset.File
            $localBytes=[IO.File]::ReadAllBytes($asset.File)
            $localHash=Get-WsmProbeSha256 $localBytes
            $entry.LocalSHA256=$localHash
            $entry.ExpectedBytes=$localBytes.Length
        }catch{
            $localFailure=Get-WsmProbeLocalAssetFailure $_.Exception 'LocalAsset'
            $entry.AssetError=$localFailure.FailureCode
            $entry.FailureCode=$localFailure.FailureCode
            $entry.Stage=$localFailure.Stage
            $entry.NextAction=$localFailure.NextAction
            $records+=,[pscustomobject]$entry
            continue
        }
        try {
            $response=Invoke-WsmProbeGet $client ([uri]::new($Origin,$asset.Route)) $RequestAdapter
            $body=[byte[]]$response.Body
            $entry.HTTPStatus=[int]$response.StatusCode
            $entry.ObservedBytes=$body.Length
            $entry.ObservedSHA256=Get-WsmProbeSha256 $body
            $observedContentType=Get-WsmProbeHeaderValue $response 'Content-Type'
            $observedContentLength=$response.Headers['Content-Length']
            $entry.ObservedContentType=if($observedContentType -ceq $asset.ContentType){$observedContentType}else{'[unrecognized header value omitted]'}
            $entry.ObservedContentLength=if([string]$observedContentLength -ceq [string]$localBytes.Length){[string]$observedContentLength}else{'[unrecognized header value omitted]'}
            $observedHeaders=@{}
            foreach($name in $expectedHeaders.Keys){$value=Get-WsmProbeHeaderValue $response $name;$observedHeaders[$name]=$value;$entry.ObservedSecurityHeaders[$name]=if($value -ceq $expectedHeaders[$name]){$value}else{'[unrecognized header value omitted]'}}
            if($entry.HTTPStatus -ne 200){$entry.Status='NotTested';$assetFailure=Get-WsmProbeHttpFailure $entry.HTTPStatus 'Asset';$entry.TransportError=$assetFailure.FailureCode;$entry.FailureCode=$assetFailure.FailureCode;$entry.Stage=$assetFailure.Stage;$entry.NextAction=$assetFailure.NextAction}
            else {
            $entry.BodyMatchesDisk=($entry.HTTPStatus -eq 200 -and $entry.ObservedBytes -eq $localBytes.Length -and $entry.ObservedSHA256 -ceq $localHash -and $serverHash -ceq $localHash)
            $headersMatch=($observedContentType -ceq $asset.ContentType -and [string]$observedContentLength -ceq [string]$localBytes.Length)
            foreach($name in $expectedHeaders.Keys){if($observedHeaders[$name] -cne $expectedHeaders[$name]){$headersMatch=$false}}
            $entry.HeadersMatchExpected=$headersMatch
            $entry.Status=if($entry.BodyMatchesDisk -and $headersMatch){'ObservedMatches'}else{'ModifiedTransport'}
            if($entry.Status -ceq 'ObservedMatches'){$entry.FailureCode='None';$entry.Stage='Completed';$entry.NextAction='無需採取動作。'}
            else{$entry.FailureCode='AssetIntegrityMismatch';$entry.Stage='AssetIntegrity';$entry.NextAction='本機、工作階段與傳輸頁面不一致；檢查發行檔與本機管理服務是否來自同一版本。'}
            }
        } catch {
            $entry.Status='NotTested'
            $transportFailure=Get-WsmProbeExceptionFailure $_.Exception 'AssetRequest'
            $entry.TransportError=$transportFailure.FailureCode
            $entry.FailureCode=$transportFailure.FailureCode
            $entry.Stage=$transportFailure.Stage
            $entry.NextAction=$transportFailure.NextAction
        }
        $records+=,[pscustomobject]$entry
        $localBytes=$null;$body=$null
    }}
    if($failureDetails){$state='NotTested'}
    elseif(@($records|Where-Object Status -eq 'NotTested').Count){$state='NotTested'}
    elseif(@($records|Where-Object Status -eq 'ModifiedTransport').Count){$state='ModifiedTransport'}
    else{$state='ObservedMatches'}
} catch {
    if(-not $failureDetails){$failureDetails=Get-WsmProbeExceptionFailure $_.Exception 'Probe'}
    $state='NotTested'
} finally {
    if($sessionResponse){$sessionResponse=$null}
    if($client){$client.Dispose()};if($handler){$handler.Dispose()}
}

$assetFailures=@($records|Where-Object {$_.FailureCode -and $_.FailureCode -cne 'None'})
if(-not $failureDetails -and $assetFailures.Count){$failureDetails=$assetFailures[0]}
if(-not $failureDetails){$failureDetails=[pscustomobject]@{FailureCode='None';Stage='Completed';NextAction='無需採取動作。'}}
$result=[pscustomobject]@{
    Status=$state
    FailureCode=[string]$failureDetails.FailureCode
    Stage=[string]$failureDetails.Stage
    NextAction=[string]$failureDetails.NextAction
    ProbedUtc=[DateTime]::UtcNow.ToString('o')
    OriginKind='LocalLoopback'
    OriginPort=[int]$Origin.Port
    Scope='Read-only GET checks of four local console assets; no operation/job/report endpoints are called.'
    Error=$(if($failureDetails.FailureCode -ceq 'None'){$null}else{[string]$failureDetails.FailureCode})
    Assets=@($records)
}
    $json=$result|ConvertTo-Json -Depth 8
    $stream=[IO.File]::Open($jsonPath,'CreateNew','Write','None');try{$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
$tableRows=foreach($assetResult in @($records)){
    '<tr><td>'+ (ConvertTo-WsmProbeHtml $assetResult.Route) +'</td><td>'+ (ConvertTo-WsmProbeHtml $assetResult.Status) +'</td><td>'+ (ConvertTo-WsmProbeHtml $assetResult.FailureCode) +'</td><td>'+ (ConvertTo-WsmProbeHtml $assetResult.Stage) +'</td><td>'+ (ConvertTo-WsmProbeHtml $assetResult.NextAction) +'</td><td>'+ (ConvertTo-WsmProbeHtml ([string]$assetResult.LocalSHA256)) +'</td><td>'+ (ConvertTo-WsmProbeHtml ([string]$assetResult.ObservedSHA256)) +'</td><td>'+ (ConvertTo-WsmProbeHtml ([string]$assetResult.ExpectedBytes)) +'</td><td>'+ (ConvertTo-WsmProbeHtml ([string]$assetResult.ObservedBytes)) +'</td><td><pre>'+ (ConvertTo-WsmProbeHtml (($assetResult.ObservedSecurityHeaders|ConvertTo-Json -Compress -Depth 3))) +'</pre></td></tr>'
}
$page='<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>本機頁面傳輸完整性檢查</title><style>body{font:16px/1.5 system-ui,sans-serif;margin:2rem;max-width:100rem}table{border-collapse:collapse;width:100%}th,td{border:1px solid #bbc4ce;padding:.5rem;text-align:left;overflow-wrap:anywhere}pre{white-space:pre-wrap;margin:0}.status{font-weight:700}</style><h1>本機頁面傳輸完整性檢查</h1><p class="status">狀態：'+(ConvertTo-WsmProbeHtml $state)+'</p><p>失敗分類：'+(ConvertTo-WsmProbeHtml $result.FailureCode)+'；階段：'+(ConvertTo-WsmProbeHtml $result.Stage)+'</p><p>建議動作：'+(ConvertTo-WsmProbeHtml $result.NextAction)+'</p><p>此檢查只讀取工作階段中繼資料與四個靜態頁面，不呼叫操作、工作或報告端點。結果只描述本次環境觀察。</p><p>時間（UTC）：'+(ConvertTo-WsmProbeHtml $result.ProbedUtc)+'</p><table><thead><tr><th>頁面</th><th>狀態</th><th>失敗分類</th><th>階段</th><th>建議動作</th><th>本機 SHA-256</th><th>傳輸 SHA-256</th><th>預期位元組</th><th>收到位元組</th><th>觀察到的安全標頭</th></tr></thead><tbody>'+($tableRows -join '')+'</tbody></table><p>JSON：'+(ConvertTo-WsmProbeHtml $jsonPath)+'</p></html>'
    $stream=[IO.File]::Open($htmlPath,'CreateNew','Write','None');try{$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($page);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    $result|Add-Member NoteProperty JsonPath $jsonPath -Force
    $result|Add-Member NoteProperty HtmlPath $htmlPath -Force
    return $result
}
