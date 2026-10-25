#requires -Version 5.1
# N9a / F2: CLI-side failure location (FailureCode, Stage, NextAction, screen-aligned class), redaction,
# no-HTTP-write proof for the CLI, and external-acceptance material alignment.
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$module=Import-Module (Join-Path $repoRoot 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-cli-failure-location-'+[Guid]::NewGuid().ToString('N'))
$fixtureUi=Join-Path $repoRoot 'src\ui'
$script:checkCount=0
$script:mode='Match'
Add-Type -AssemblyName System.Net.Http

function Assert-Cli([bool]$Condition,[string]$Message){if(-not $Condition){throw ('Assertion failed: '+$Message)};$script:checkCount++}
function Get-FixtureHash([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Get-FixtureHeaders([string]$ContentType,[int]$Length,[string]$Csp="default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"){
    @{'Content-Type'=$ContentType;'Content-Length'=[string]$Length;'Connection'='close';'X-Content-Type-Options'='nosniff';'Referrer-Policy'='no-referrer';'Content-Security-Policy'=$Csp}
}
$script:adapter={
    param($Method,$Uri)
    if($Uri.AbsolutePath -ceq '/api/session'){
        if($script:mode -ceq 'SessionReset'){throw [Net.Sockets.SocketException]::new([int][Net.Sockets.SocketError]::ConnectionReset)}
        if($script:mode -ceq 'Expired'){$b=[Text.Encoding]::UTF8.GetBytes('session body token=SENTINEL_SESSION_BODY');return [pscustomobject]@{StatusCode=401;Body=$b;Headers=(Get-FixtureHeaders 'text/plain' $b.Length)}}
        if($script:mode -ceq 'NotJson'){$b=[Text.Encoding]::UTF8.GetBytes('<html>not json token=SENTINEL_NOT_JSON</html>');return [pscustomobject]@{StatusCode=200;Body=$b;Headers=(Get-FixtureHeaders 'text/html' $b.Length)}}
        $hashes=@{}
        foreach($name in @('index.html','console.js','console.css','guide.html')){$hashes['/ui/'+$name]=Get-FixtureHash ([IO.File]::ReadAllBytes((Join-Path $fixtureUi $name)))}
        $b=[Text.Encoding]::UTF8.GetBytes((@{token='SENTINEL_SESSION_TOKEN';assetHashes=$hashes}|ConvertTo-Json -Compress))
        return [pscustomobject]@{StatusCode=200;Body=$b;Headers=(Get-FixtureHeaders 'application/json; charset=utf-8' $b.Length)}
    }
    $assetName=Split-Path $Uri.AbsolutePath -Leaf
    $file=Join-Path $fixtureUi $assetName
    $body=[IO.File]::ReadAllBytes($file)
    $contentType=switch([IO.Path]::GetExtension($file)){'.html'{'text/html; charset=utf-8'}'.js'{'application/javascript; charset=utf-8'}'.css'{'text/css; charset=utf-8'}}
    if($script:mode -ceq 'Reset' -and $assetName -ceq 'console.js'){throw [Net.Http.HttpRequestException]::new('message token=SENTINEL_RESET_MESSAGE',([Net.Sockets.SocketException]::new([int][Net.Sockets.SocketError]::ConnectionReset)))}
    if($script:mode -ceq 'Timeout' -and $assetName -ceq 'console.js'){throw [Threading.Tasks.TaskCanceledException]::new('timeout token=SENTINEL_TIMEOUT_MESSAGE')}
    if($script:mode -ceq 'HashMismatch' -and $assetName -ceq 'index.html'){$body=@($body)+@([Text.Encoding]::UTF8.GetBytes('<!-- changed -->'))}
    [pscustomobject]@{StatusCode=200;Body=([byte[]]$body);Headers=(Get-FixtureHeaders $contentType $body.Length)}
}
$origin=[uri]'http://127.0.0.1:49231/'
function Invoke-Scenario([string]$Mode,[string]$Name){
    $script:mode=$Mode
    $raw=Export-WsmAssistiveHttpProbe -Origin $origin -OutputPath (Join-Path $testRoot $Name) -RequestAdapter $script:adapter
    $projection=& $module {param($Result,$Salt) ConvertTo-WsmDeveloperProbeHttpProjection $Result $Salt} $raw 'cli-location-test'
    $collector=[pscustomobject]@{Id='HttpProbe';Status='Completed';ReasonCode=$null;Data=$projection}
    $lines=@(& $module {param($Rows) Get-WsmDeveloperProbeFailureLocationLines $Rows} @($collector))
    [pscustomobject]@{Raw=$raw;Projection=$projection;Lines=$lines;Text=((@($projection|ConvertTo-Json -Depth 8))+$lines) -join "`n"}
}
function Get-Class([string]$Code,[string]$Stage='',[switch]$Write){& $module {param($C,$S,$W) Get-WsmCliFailureClass -FailureCode $C -Stage $S -IsWrite:$W} $Code $Stage ([bool]$Write)}

try{
    [void][IO.Directory]::CreateDirectory($testRoot)

    # ---- screen names: the CLI names must equal the browser banner titles (console.js connectionCopy) -------------------
    $consoleJs=[IO.File]::ReadAllText((Join-Path $fixtureUi 'console.js'),[Text.Encoding]::UTF8)
    $names=& $module {Get-WsmCliFailureClassNames}
    foreach($id in @('listener-unreachable','resource-incomplete','session-expired','reset-timeout','unknown-write')){
        $m=[regex]::Match($consoleJs,"'"+[regex]::Escape($id)+"':\s*\{\s*title:\s*'([^']+)'")
        Assert-Cli ($m.Success -and $m.Groups[1].Value -ceq [string]$names[$id]) ('CLI name for '+$id+' equals the screen title')
    }
    Assert-Cli ($names['other'] -ceq '其他' -and $names['unknown-root'] -ceq '未知根因') 'other and unknown-root have fixed Chinese names'

    # ---- mapping table: every class at least one example ---------------------------------------------------------------
    $expected=[ordered]@{
        ListenerUnavailable=@('listener-unreachable','AssetRequest')
        ConnectionResetObserved=@('reset-timeout','AssetRequest')
        ConnectionAbortedObserved=@('reset-timeout','AssetRequest')
        RequestTimedOut=@('reset-timeout','AssetRequest')
        SessionExpired=@('session-expired','Session')
        AssetIntegrityMismatch=@('resource-incomplete','AssetIntegrity')
        AssetHttpFailure=@('resource-incomplete','Asset')
        LocalAssetMissing=@('resource-incomplete','LocalAsset')
        LocalAssetReadFailure=@('resource-incomplete','LocalAsset')
        SessionAssetHashesMissing=@('resource-incomplete','Session')
        SessionAssetHashMissing=@('resource-incomplete','Session')
        SessionAssetHashInvalid=@('resource-incomplete','Session')
        SessionAccessDenied=@('other','Session')
        SessionHttpFailure=@('other','Session')
        InvalidSessionResponse=@('other','Session')
        UnknownTransportFailure=@('unknown-root','AssetRequest')
        None=@('none','Completed')
    }
    foreach($code in $expected.Keys){
        $class=Get-Class $code $expected[$code][1]
        Assert-Cli ($class.Category -ceq $expected[$code][0] -and $class.Name -ceq [string]$names[$expected[$code][0]]) ('FailureCode '+$code+' maps to '+$expected[$code][0])
    }
    Assert-Cli ((Get-Class 'SomethingNew' 'Probe').Category -ceq 'unknown-root' -and (Get-Class '' '').Category -ceq 'unknown-root') 'an unrecognised or empty code is an unknown root cause, not guessed'
    Assert-Cli ((Get-Class 'ConnectionResetObserved' 'Session').Category -ceq 'listener-unreachable') 'a reset before any session exists follows the screen rule: listener unreachable'
    foreach($code in @('ListenerUnavailable','ConnectionResetObserved','ConnectionAbortedObserved','RequestTimedOut','UnknownTransportFailure')){Assert-Cli ((Get-Class $code 'AssetRequest' -Write).Category -ceq 'unknown-write') ('a write that loses its answer ('+$code+') is unknown-write')}
    Assert-Cli ((Get-Class 'SessionExpired' 'Session' -Write).Category -ceq 'session-expired') 'a 401 on a write stays session-expired, as on the screen'
    $source=[IO.File]::ReadAllText((Join-Path $repoRoot 'src\AssistiveHttpProbe.ps1'),[Text.Encoding]::UTF8)
    $emitted=@([regex]::Matches($source,"FailureCode='([A-Za-z]+)'")|ForEach-Object {$_.Groups[1].Value})+@([regex]::Matches($source,"\{'(Session[A-Za-z]+)'\}")|ForEach-Object {$_.Groups[1].Value})
    $emitted=@($emitted|Where-Object {$_ -cne 'Unknown'}|Sort-Object -Unique)
    Assert-Cli ($emitted.Count -ge 14) ('the probe emits at least the 14 documented codes (found '+$emitted.Count+')')
    foreach($code in $emitted){Assert-Cli ($expected.Contains($code)) ('probe code '+$code+' is covered by the mapping table test')}

    # ---- controlled scenarios -----------------------------------------------------------------------------------------
    $normal=Invoke-Scenario 'Match' 'normal'
    Assert-Cli ($normal.Projection.FailureCode -ceq 'None' -and $normal.Projection.Stage -ceq 'Completed' -and $normal.Projection.NextAction -and $normal.Projection.FailureClass -ceq 'none') 'normal run projects None/Completed with a next action'
    Assert-Cli ($normal.Lines.Count -eq 0) 'a normal run prints no location line'
    Assert-Cli ($normal.Projection.ErrorType -eq $null -and $normal.Projection.Status -ceq 'ObservedMatches' -and $normal.Projection.AssetCount -eq 4) 'legacy Status/AssetCount/ErrorType are preserved'

    $reset=Invoke-Scenario 'Reset' 'reset'
    Assert-Cli ($reset.Projection.FailureCode -ceq 'ConnectionResetObserved' -and $reset.Projection.Stage -ceq 'AssetRequest' -and $reset.Projection.NextAction -and $reset.Projection.ErrorType -ceq 'ConnectionResetObserved') 'reset keeps FailureCode, Stage, NextAction and legacy ErrorType'
    Assert-Cli ($reset.Projection.FailureClass -ceq 'reset-timeout' -and $reset.Projection.FailureClassName -ceq $names['reset-timeout']) 'reset is the screen reset/timeout class'
    $resetAsset=@($reset.Projection.Assets|Where-Object {$_.FailureCode -ceq 'ConnectionResetObserved'})[0]
    Assert-Cli ($resetAsset.Stage -ceq 'AssetRequest' -and $resetAsset.NextAction -and $resetAsset.TransportErrorType -ceq 'ConnectionResetObserved') 'the failing asset row carries the same three fields'
    $wantReset='定位：'+$names['reset-timeout']+'（ConnectionResetObserved）／階段：AssetRequest／下一步：'+$reset.Projection.NextAction
    Assert-Cli ($reset.Lines.Count -eq 1 -and $reset.Lines[0] -ceq $wantReset) 'one exact location line is printed for a reset'

    $timeout=Invoke-Scenario 'Timeout' 'timeout'
    Assert-Cli ($timeout.Projection.FailureCode -ceq 'RequestTimedOut' -and $timeout.Projection.FailureClass -ceq 'reset-timeout' -and $timeout.Lines.Count -eq 1 -and $timeout.Lines[0].StartsWith('定位：'+$names['reset-timeout']+'（RequestTimedOut）／階段：AssetRequest／下一步：')) 'timeout is located with its own code in the reset/timeout class'

    $notJson=Invoke-Scenario 'NotJson' 'notjson'
    Assert-Cli ($notJson.Projection.FailureCode -ceq 'InvalidSessionResponse' -and $notJson.Projection.Stage -ceq 'Session' -and $notJson.Projection.FailureClass -ceq 'other' -and $notJson.Lines[0].StartsWith('定位：其他（InvalidSessionResponse）／階段：Session／下一步：')) 'non-JSON session body is located as other, without echoing the body'

    $expired=Invoke-Scenario 'Expired' 'expired'
    Assert-Cli ($expired.Projection.FailureCode -ceq 'SessionExpired' -and $expired.Projection.FailureClass -ceq 'session-expired' -and $expired.Lines[0].StartsWith('定位：'+$names['session-expired']+'（SessionExpired）／階段：Session／下一步：')) '401 is located as session expired'

    $mismatch=Invoke-Scenario 'HashMismatch' 'mismatch'
    Assert-Cli ($mismatch.Projection.FailureCode -ceq 'AssetIntegrityMismatch' -and $mismatch.Projection.Stage -ceq 'AssetIntegrity' -and $mismatch.Projection.FailureClass -ceq 'resource-incomplete' -and $mismatch.Lines[0].StartsWith('定位：'+$names['resource-incomplete']+'（AssetIntegrityMismatch）／階段：AssetIntegrity／下一步：')) 'an asset hash mismatch is located as resource incomplete'

    $sessionReset=Invoke-Scenario 'SessionReset' 'sessionreset'
    Assert-Cli ($sessionReset.Projection.FailureClass -ceq 'listener-unreachable' -and $sessionReset.Projection.Stage -ceq 'Session') 'a reset while fetching the session (no session yet) is listener unreachable'

    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$closedPort=[int]([Net.IPEndPoint]$listener.LocalEndpoint).Port;$listener.Stop()
    $refused=Export-WsmAssistiveHttpProbe -Origin ([uri]('http://127.0.0.1:'+$closedPort+'/')) -OutputPath (Join-Path $testRoot 'refused')
    $refusedProjection=& $module {param($Result,$Salt) ConvertTo-WsmDeveloperProbeHttpProjection $Result $Salt} $refused 'cli-location-test'
    $refusedLines=@(& $module {param($Rows) Get-WsmDeveloperProbeFailureLocationLines $Rows} @([pscustomobject]@{Id='HttpProbe';Status='Completed';Data=$refusedProjection}))
    Assert-Cli ($refusedProjection.FailureCode -ceq 'ListenerUnavailable' -and $refusedProjection.Stage -ceq 'Session' -and $refusedProjection.FailureClass -ceq 'listener-unreachable' -and $refusedLines.Count -eq 1 -and $refusedLines[0].StartsWith('定位：'+$names['listener-unreachable']+'（ListenerUnavailable）／階段：Session／下一步：')) 'a real refused connection is located as listener unreachable'
    Assert-Cli ((@($refusedProjection|ConvertTo-Json -Depth 8) -join '') -notmatch '127\.0\.0\.1|http://') 'the projection holds no origin URL'

    foreach($scenario in @($reset,$timeout,$notJson,$expired,$mismatch,$sessionReset)){
        Assert-Cli ($scenario.Text -notmatch 'SENTINEL_|session body|not json|<html>') 'scenario output carries no session token, response body or exception message'
    }

    # ---- redaction of hostile text (also the target of the redaction mutation) ----------------------------------------------
    $hostile=[pscustomobject]@{
        Status='NotTested';Error='Authorization: Bearer SENTINEL_HOSTILE';FailureCode='UnknownTransportFailure';Stage='C:\Users\private user\SENTINEL_HOSTILE';
        NextAction='retry with Authorization: Bearer SENTINEL_HOSTILE and token=SENTINEL_HOSTILE password="two words SENTINEL_HOSTILE" at C:\Users\private user\SENTINEL_HOSTILE.xml';
        Assets=@([pscustomobject]@{Route='/ui/console.js?token=SENTINEL_HOSTILE';Status='NotTested';FailureCode='RequestTimedOut';Stage='AssetRequest';NextAction='session id=abc secret=SENTINEL_HOSTILE';TransportError='token=SENTINEL_HOSTILE'})
    }
    $hostileProjection=& $module {param($Result,$Salt) ConvertTo-WsmDeveloperProbeHttpProjection $Result $Salt} $hostile 'cli-location-test'
    $hostileLines=@(& $module {param($Rows) Get-WsmDeveloperProbeFailureLocationLines $Rows} @([pscustomobject]@{Id='HttpProbe';Status='Completed';Data=$hostileProjection}))
    $hostileText=(($hostileProjection|ConvertTo-Json -Depth 8)+($hostileLines -join "`n"))
    Assert-Cli ($hostileText -notmatch 'SENTINEL_HOSTILE|private user') 'tokens, secrets, bearer values and absolute paths never reach the projection or the text lines'
    Assert-Cli ($hostileProjection.Stage -ceq 'Unknown' -and $hostileProjection.FailureClass -ceq 'unknown-root' -and $hostileLines.Count -ge 1) 'a non-identifier stage is replaced and the failure stays an unknown root cause'

    # ---- end to end through Export-WsmDeveloperProbe: real worker, real closed port -----------------------------------------
    $stub={param($CollectorId,$Context) if($CollectorId -ceq 'NativeInventory'){[pscustomobject]@{Status='NotApplicable';ReasonCode='WindowsServerRequired'}}else{[pscustomobject]@{Status='Completed';Rows=@()}}}
    $workspace=Join-Path $testRoot 'workspace';[void][IO.Directory]::CreateDirectory($workspace)
    $probe=Export-WsmDeveloperProbe -Workspace $workspace -Role Manager -Origin ('http://127.0.0.1:'+$closedPort) -CollectorAdapter @{PlatformIdentity=$stub;CommandsModules=$stub;LocalVolumes=$stub;NativeInventory=$stub}
    $httpRow=@($probe.CollectorResults|Where-Object Id -CEQ 'HttpProbe')[0]
    Assert-Cli ($httpRow.Status -ceq 'Completed' -and $httpRow.Data.FailureCode -ceq 'ListenerUnavailable' -and $httpRow.Data.Stage -ceq 'Session' -and $httpRow.Data.NextAction -and $httpRow.Data.ErrorType -ceq 'ListenerUnavailable' -and $httpRow.Data.FailureClass -ceq 'listener-unreachable') 'the real HttpProbe worker returns the new projection fields'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($probe.Path)
    try{$reader=New-Object IO.StreamReader($zip.GetEntry('probe.json').Open());try{$savedProbe=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}}finally{$zip.Dispose()}
    $savedHttp=@($savedProbe.Collectors|Where-Object Id -CEQ 'HttpProbe')[0]
    Assert-Cli ($savedHttp.Data.FailureCode -ceq 'ListenerUnavailable' -and $savedHttp.Data.Stage -ceq 'Session' -and $savedHttp.Data.NextAction -ceq $httpRow.Data.NextAction -and $savedHttp.Data.FailureClassName -ceq $names['listener-unreachable']) 'probe.json inside the ZIP carries FailureCode, Stage, NextAction and the class name'
    $html=[IO.File]::ReadAllText($probe.HtmlPath,[Text.Encoding]::UTF8)
    $wantLine='定位：'+$names['listener-unreachable']+'（ListenerUnavailable）／階段：Session／下一步：'+$httpRow.Data.NextAction
    Assert-Cli ($html.Contains([Net.WebUtility]::HtmlEncode($wantLine))) 'the saved HTML summary prints the location line'
    Assert-Cli ((@(& $module {param($Rows) Get-WsmDeveloperProbeFailureLocationLines $Rows} @($probe.CollectorResults))) -ccontains $wantLine) 'the CLI text helper prints the same line for the real run'
    Assert-Cli (-not ($html -match '127\.0\.0\.1|http://')) 'the HTML summary holds no origin URL'
    $failedCollector=@(& $module {Get-WsmDeveloperProbeFailureLocationLines @([pscustomobject]@{Id='HttpProbe';Status='TimedOut';ReasonCode='CollectorTimeout';Data=$null})})
    Assert-Cli ($failedCollector.Count -eq 1 -and $failedCollector[0].StartsWith('定位：未知根因（CollectorTimeout）／階段：HttpProbe／下一步：')) 'a collector that timed out is an unknown root cause, never guessed'

    # ---- contract 3: the CLI never sends writes over HTTP ----------------------------------------------------------------------
    $httpTypePattern='(?i)(^|\.)(HttpClient|HttpClientHandler|WebClient|HttpWebRequest|WebRequest|ServicePointManager)$'
    $httpCommands=@('invoke-webrequest','invoke-restmethod','start-bitstransfer','curl','wget','iwr','irm')
    $usingHttpClient=@();$writeVerbs=@()
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -File -Filter '*.ps1')+@(Get-Item -LiteralPath (Join-Path $repoRoot 'Start-ServerMigration.ps1'))){
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        $commands=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Where-Object {$_})
        Assert-Cli (@($commands|Where-Object {$httpCommands -contains $_.ToLowerInvariant()}).Count -eq 0) ($file.Name+' calls no web cmdlet')
        $typeNames=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.TypeExpressionAst] -or $n -is [Management.Automation.Language.TypeConstraintAst]},$true)|ForEach-Object {$_.TypeName.FullName})
        $stringTypes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'System\.Net\.Http\.Http|System\.Net\.WebClient|System\.Net\.WebRequest'},$true))
        if(@($typeNames|Where-Object {$_ -match $httpTypePattern}).Count -or $stringTypes.Count){$usingHttpClient+=$file.Name}
        $members=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst]},$true)|ForEach-Object {[string]$_.Member.Value}|Where-Object {$_ -match '^(Post|Put|Delete|Patch|Send)Async$|^(Upload|Post)'})
        if($members.Count){$writeVerbs+=$file.Name}
    }
    Assert-Cli (($usingHttpClient|Sort-Object -Unique) -join ',' -ceq 'AssistiveHttpProbe.ps1') ('only AssistiveHttpProbe.ps1 holds an HTTP client (found: '+(($usingHttpClient|Sort-Object -Unique) -join ',')+')')
    Assert-Cli ($writeVerbs.Count -eq 0) 'no source script calls a POST/PUT/DELETE/PATCH/SEND client method'
    Assert-Cli ($source -match 'GetAsync' -and $source -notmatch '(?i)PostAsync|PutAsync|SendAsync|DeleteAsync|PatchAsync') 'the only HTTP client is read-only (GET)'
    $typed=& $module {(Get-Command Invoke-WsmTypedTextOperation).ScriptBlock.Ast.Extent.Text+"`n"+(Get-Command Invoke-WsmTypedTextOperationCore).ScriptBlock.Ast.Extent.Text}
    Assert-Cli ($typed -match '&\s*\$command\s+@arguments') 'Invoke-WsmTypedTextOperation(Core) runs the core command in this process (& $command @arguments)'
    Assert-Cli ($typed -notmatch '(?i)HttpClient|Invoke-WebRequest|Invoke-RestMethod|WebClient|127\.0\.0\.1') 'Invoke-WsmTypedTextOperation(Core) never builds an HTTP request or a loopback URL'

    # ---- the interactive CLI (typed text operation) prints the location line for a real failing probe ------------------------------
    $cliRoot=Join-Path $testRoot 'cli-workspace';[void][IO.Directory]::CreateDirectory($cliRoot)
    $cliLines=& $module {
        param($Root,$Port)
        $script:cliOriginal=(Get-Command Export-WsmDeveloperProbe -CommandType Function).ScriptBlock
        $script:cliPort=$Port
        $script:cliStub={param($CollectorId,$Context) if($CollectorId -ceq 'NativeInventory'){[pscustomobject]@{Status='NotApplicable';ReasonCode='WindowsServerRequired'}}else{[pscustomobject]@{Status='Completed';Rows=@()}}}
        function script:Export-WsmDeveloperProbe {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Workspace,[ValidateSet('Source','Target','Manager')][string]$Role='Manager',[string]$Origin,[string]$PairId,[ValidateRange(1,300)][int]$CollectorTimeoutSeconds=30,[ValidateRange(16384,67108864)][long]$MaximumOutputBytes=4194304,[psobject]$CancellationToken,[Parameter(DontShow)][hashtable]$CollectorAdapter)
            & $script:cliOriginal -Workspace $Workspace -Role $Role -Origin ('http://127.0.0.1:'+$script:cliPort) -PairId $PairId -CollectorTimeoutSeconds $CollectorTimeoutSeconds -MaximumOutputBytes $MaximumOutputBytes -CancellationToken $CancellationToken -CollectorAdapter @{PlatformIdentity=$script:cliStub;CommandsModules=$script:cliStub;LocalVolumes=$script:cliStub;NativeInventory=$script:cliStub}
        }
        $answers=New-Object 'System.Collections.Queue';foreach($answer in @('1','DeveloperProbe','','','','APPLY')){$answers.Enqueue($answer)}
        $reader={param($prompt) if($answers.Count -eq 0){throw ('Unexpected prompt: '+$prompt)};[string]$answers.Dequeue()}.GetNewClosure()
        $captured=@(Invoke-WsmTypedTextOperation -Workspace $Root -PromptReader $reader 6>&1 | Where-Object {$_ -is [Management.Automation.InformationRecord]} | ForEach-Object {[string]$_.MessageData})
        $captured
    } $cliRoot $closedPort
    $cliWant='定位：'+$names['listener-unreachable']+'（ListenerUnavailable）／階段：Session／下一步：'
    Assert-Cli (@($cliLines|Where-Object {$_.StartsWith($cliWant)}).Count -eq 1) ('the typed CLI prints one location line after a failing probe (captured '+@($cliLines).Count+' host lines)')

    # ---- contract 4: external acceptance alignment in the real lab report ----------------------------------------------------
    $labDir=Join-Path $testRoot 'lab';$lab=Export-WsmLabValidationReport -OutputDirectory $labDir -Role Target
    $labJson=[IO.File]::ReadAllText($lab.JSONPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
    $labText=[IO.File]::ReadAllText($lab.TextPath,[Text.Encoding]::UTF8)
    Assert-Cli (@($labJson.ExternalAcceptance).Count -eq 7 -and @($labJson.ExternalAcceptance|Where-Object Status -CNE 'NotTested').Count -eq 0) 'the report lists seven external categories, all NotTested'
    Assert-Cli ($labJson.ProductionVerified -eq $false -and $lab.ProductionVerified -eq $false -and $labText -match 'ProductionVerified: false') 'missing external material never makes the report production verified'
    foreach($material in @('owner 與負責人','真實瀏覽器完整備份、交接與目標還原旅程證據','企業有效信任鏈與撤銷材料')){Assert-Cli ($labText.Contains('缺少：'+$material)) ('the lab text prints 缺少：'+$material)}
    Assert-Cli (@($labJson.ExternalAcceptance|Where-Object Id -CEQ 'EX2')[0].CoveredMaterials -contains '語系') 'fields an existing collector already supplies (locale) are counted as covered, not missing'
    Assert-Cli (-not $labText.Contains('缺少：語系')) 'a covered material is not reported missing'
    $baseline=[pscustomobject]@{OS='x';OSVersion='1';WindowsInstallationType='Server';UICulture='zh-TW';Culture='zh-TW';PowerShellVersion='5.1';PowerShellEdition='Desktop';LanguageMode='FullLanguage';ObservedMachineFingerprint='f';Checks=@([pscustomobject]@{Code='ProcessArchitecture'},[pscustomobject]@{Code='Administrator'})}
    $full=@(& $module {param($Report) Get-WsmExternalAcceptanceCoverage $Report} $baseline)
    Assert-Cli (@($full|Where-Object Status -CNE 'NotTested').Count -eq 0 -and @($full[1].MissingMaterials) -contains '產品原生錯誤分類正反例') 'even with every collector field present, each category stays NotTested and unsupplied material is still missing'
    $noCulture=$baseline.PSObject.Copy();$noCulture.PSObject.Properties.Remove('Culture')
    $reduced=@(& $module {param($Report) Get-WsmExternalAcceptanceCoverage $Report} $noCulture)
    Assert-Cli (@($reduced[1].MissingMaterials) -contains '語系' -and @($full[1].MissingMaterials) -notcontains '語系') 'removing a collector field turns that material into a reported gap'

    # Q5(b): the Start-ServerMigration.ps1 -Action DeveloperProbe entry prints the same failure-location lines (AST: the DeveloperProbe branch calls the shared formatter on CollectorResults).
    $entryAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Start-ServerMigration.ps1'),[ref]$null,[ref]$null)
    $probeBranch=@($entryAst.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match "Action -ceq 'DeveloperProbe'"},$true))
    Assert-Cli ($probeBranch.Count -ge 1 -and $probeBranch[0].Clauses[0].Item2.Extent.Text.Contains('Get-WsmDeveloperProbeFailureLocationLines') -and $probeBranch[0].Clauses[0].Item2.Extent.Text.Contains('CollectorResults')) 'the -Action DeveloperProbe entry prints the failure-location lines'
    Write-Host ('PASS: '+$script:checkCount+' CLI failure-location checks (mapping table, 7 scenarios, redaction, real worker end to end, no HTTP writes from the CLI, external material alignment) on '+$PSVersionTable.PSEdition+' '+$PSVersionTable.PSVersion)
}finally{
    if(Test-Path -LiteralPath $testRoot){Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
