#requires -Version 5.1
# S14 (PLAN 17.125): the HTML console classifies errors by exception TYPE, not by words in the message.
#   - a request body that is not one JSON object, a body with unknown/missing fields, a wrong content type and every request-shape refusal throw
#     New-WsmContractError (System.IO.InvalidDataException) and answer 400 invalid_request;
#   - an internal exception whose message happens to contain "parameter", "Malformed", "Unknown view" ... stays operation_failed;
#   - the message-coded protocol tokens that are thrown from many files as plain strings (Rejected*, stale/changed review, UnknownJob, ReportUnavailable ...) keep
#     their message match because they carry no type; they are listed in the PLAN and asserted here so nobody widens them silently.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$script:checks=0
$script:EnvRetries=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message}}
function Get-Code([string]$Message,[string]$Type=''){& $module {param($m,$t) (Get-WsmHtmlSafeError $m $t).code} $Message $Type}

# ---------------------------------------------------------------------------------------------------------------- 1. classification by type
$contract='System.IO.InvalidDataException'
foreach($message in @('Missing contract field: action','Unknown contract field: surprise','Malformed JSON body.','Anything at all, even without a keyword')){
    Check ((Get-Code $message $contract) -ceq 'invalid_request') ('A contract error must classify as invalid_request regardless of its words: '+$message)
}
$internalMessages=@(
    "Cannot bind argument to parameter 'Path' because it is null.",
    'The parameter is incorrect.',
    'Malformed record found in the internal cache',
    'Unknown view cache entry',
    'Unknown action table is corrupt',
    'Duplicate query plan node',
    'JSON body of the stored job could not be read',
    'Unsupported operation of the storage driver',
    'Invalid role ACE on the folder',
    'Unknown route table'
)
foreach($type in @('System.InvalidOperationException','System.ArgumentException','System.NullReferenceException','System.Management.Automation.ParameterBindingException','System.Management.Automation.RuntimeException','System.IO.IOException','')){
    foreach($message in $internalMessages){
        Check ((Get-Code $message $type) -ceq 'operation_failed') ('An internal exception ('+$type+') with the words "'+$message+'" must stay operation_failed.')
    }
}
# the message-coded protocol tokens keep their own codes (thrown as plain strings from many files, so the message is the only carrier)
Check ((Get-Code 'Review changed: context changed.' 'System.Management.Automation.RuntimeException') -ceq 'stale_context') 'A changed review stays stale_context.'
Check ((Get-Code 'Review changed: context changed.' $contract) -ceq 'stale_context') 'A coded token on a contract error keeps its specific code (message-coded tokens win).'
Check ((Get-Code 'RejectedToken') -ceq 'invalid_token' -and (Get-Code 'RejectedOrigin') -ceq 'rejected_origin' -and (Get-Code 'RejectedHost') -ceq 'rejected_host') 'Rejected* tokens keep their codes.'
Check ((Get-Code 'UnknownJob') -ceq 'operation_unavailable' -and (Get-Code 'ReportUnavailable: x') -ceq 'report_unavailable') 'UnknownJob / ReportUnavailable keep their codes.'
Check ((Get-Code 'x' 'System.UnauthorizedAccessException') -ceq 'permission_denied') 'The permission type keeps its code.'
Check ((Get-Code 'PreparationFieldValidation|/Fields/Owner|required') -ceq 'field_validation') 'The field validation token keeps its code.'
Check ((Get-Code 'WorkerReportedFailure') -ceq 'operation_failed') 'A worker-reported failure stays operation_failed.'

# ---------------------------------------------------------------------------------------------------------------- 2. the body helper and the exception unwrapping
function Invoke-Body([string]$Text){& $module {param($t) try{$null=ConvertFrom-WsmHtmlBody $t;'parsed'}catch{$_.Exception.GetType().FullName}} $Text}
foreach($bad in @('{ not json','[1,2]','"text"','123','true','null','','   ','{"a":')){
    Check ((Invoke-Body $bad) -ceq $contract) ('A body that is not one JSON object must be a contract error: <'+$bad+'>')
}
foreach($good in @('{}','{"action":"x","args":{}}','{"a":[1,2,3]}')){Check ((Invoke-Body $good) -ceq 'parsed') ('A JSON object must still parse: '+$good)}
$wrapped=& $module {
    $ps=[powershell]::Create()
    [void]$ps.AddScript('$ErrorActionPreference="Stop"; throw (New-Object IO.InvalidDataException("inside a worker"))')
    $handle=$ps.BeginInvoke()
    try{$null=$ps.EndInvoke($handle);''}catch{Get-WsmHtmlExceptionTypeName $_.Exception}finally{$ps.Dispose()}
}
Check ($wrapped -ceq $contract) ('The type behind the worker EndInvoke wrappers must be found; got '+$wrapped)
$stringThrow=& $module {
    $ps=[powershell]::Create();[void]$ps.AddScript('$ErrorActionPreference="Stop"; throw "plain text"');$handle=$ps.BeginInvoke()
    try{$null=$ps.EndInvoke($handle);''}catch{Get-WsmHtmlExceptionTypeName $_.Exception}finally{$ps.Dispose()}
}
Check ($stringThrow -ceq 'System.Management.Automation.RuntimeException') ('A plain string throw has no type of its own; got '+$stringThrow)

# ---------------------------------------------------------------------------------------------------------------- 3. static: request-shape throws in HtmlConsole are typed
$htmlPath=Join-Path $repo 'src\HtmlConsole.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($htmlPath,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'HtmlConsole.ps1 must parse.'
$shapeWords='Unknown route|Unknown view|Unknown action|Invalid role|Unsupported operation|parameter|JSON body|Malformed|Duplicate query|must be a JSON|must be boolean|must be an object|must be an empty JSON object|AdditionalShares|secret reference|secret kind|Credential entry'
$stringThrows=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.ThrowStatementAst]},$true)|Where-Object{$_.Extent.Text -match $shapeWords -and $_.Extent.Text -notmatch 'New-WsmContractError'})
Check ($stringThrows.Count -eq 0) ('Request-shape refusals must throw New-WsmContractError; still plain strings: '+((@($stringThrows|ForEach-Object{[string]$_.Extent.StartLineNumber+': '+$_.Extent.Text})) -join ' | '))
$bodyParsers=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'ConvertFrom-WsmJson'},$true))
Check ($bodyParsers.Count -eq 2) ('Request bodies must be parsed by ConvertFrom-WsmHtmlBody; only the helper itself and the best-effort rejected-body lookup may call ConvertFrom-WsmJson (found '+$bodyParsers.Count+').')
$classifier=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-WsmHtmlSafeError'},$true))
Check ($classifier.Count -eq 1 -and $classifier[0].Extent.Text -notmatch 'Unknown route\|Unknown view' -and $classifier[0].Extent.Text -match 'System\.IO\.InvalidDataException') 'The classifier must decide invalid_request by type, not by the old keyword list.'
# the message matches that remain in the classifier (no type available) are exactly these
$kept=@([regex]::Matches($classifier[0].Extent.Text,"ExceptionMessage -match '([^']+)'")|ForEach-Object{$_.Groups[1].Value})
$expectedKept=@('PreparationFieldValidation\|(/[A-Za-z0-9~/_-]+)\|(required|type|option|format|length)','WorkRoot initialization exceeds supported Windows PowerShell 5.1 path limits','Review changed|Context changed|bound to another (source inventory|candidate confirmation)','Interrupted workspace transaction|workspace.*requires? repair|Repair-WsmWorkspace','RejectedToken','RejectedOrigin','RejectedHost','UnauthorizedAccess|access.*denied|administrator privilege','worker limit|active jobs|Wait for active jobs|still has a running worker','^ReportUnavailable','JobContextMismatch|UnknownJob|Unknown report|hash changed|trusted file','NoSafeCancellationBoundary|already stopped|requires a hash-bound safe cancellation')
Check (($kept -join "`n") -ceq ($expectedKept -join "`n")) ('The classifier keeps exactly the documented message matches; found: '+($kept -join ' ;; '))

# ---------------------------------------------------------------------------------------------------------------- 4. real console: bad bodies are 400 invalid_request, normal requests are unaffected
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-htmlerr-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$consoleProcess=$null
try{
    $workspace=Join-Path $root 'ws'
    & $module {param($w) Initialize-WsmWorkspace $w | Out-Null} $workspace
    $ready=Join-Path $root 'ready.json';$stop=Join-Path $root 'stop.flag'
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Start-C2D2TestServer.ps1'),'-Workspace',$workspace,'-Role','Manager','-ReadyPath',$ready,'-StopFile',$stop)
    $consoleProcess=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $root 'err.log') -RedirectStandardOutput (Join-Path $root 'out.log')
    $deadline=[DateTime]::UtcNow.AddSeconds(90)
    while(-not [IO.File]::Exists($ready)){
        if($consoleProcess.HasExited){throw ('The console process exited early: '+[IO.File]::ReadAllText((Join-Path $root 'err.log')))}
        if([DateTime]::UtcNow -gt $deadline){throw 'The console did not become ready.'}
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Milliseconds 300
    $url=[string]((Get-Content -LiteralPath $ready -Raw|ConvertFrom-Json).Url)
    function Send-Http([string]$Method,[string]$Path,[string]$Token,[string]$Text,[string]$ContentType='application/json'){
        # Loopback resets of FRESH connections are environmental on this machine (AdGuard); a reset with no HTTP answer is retried (max 6) and counted, an HTTP status is never retried.
        for($attempt=1;$attempt -le 6;$attempt++){
            $request=[Net.HttpWebRequest]::Create($url+$Path);$request.Method=$Method;$request.Accept='application/json';$request.Timeout=60000;$request.Proxy=$null
            if($Token){$request.Headers['X-Wsm-Token']=$Token}
            if($Method -ceq 'POST'){
                $request.Headers['Origin']=$url
                if($ContentType){$request.ContentType=$ContentType}
                $bytes=[Text.Encoding]::UTF8.GetBytes($Text);$request.ContentLength=$bytes.Length
            }
            try{
                if($Method -ceq 'POST'){$stream=$request.GetRequestStream();$stream.Write($bytes,0,$bytes.Length);$stream.Close()}
                $response=$request.GetResponse()
            }catch [Net.WebException]{
                if(-not $_.Exception.Response){$script:EnvRetries++;if($attempt -ge 6){throw};continue}
                $response=$_.Exception.Response
            }
            $reader=New-Object IO.StreamReader($response.GetResponseStream(),[Text.Encoding]::UTF8);$content=$reader.ReadToEnd();$reader.Dispose()
            $status=[int]$response.StatusCode;$response.Close()
            $parsed=$null;try{$parsed=$content|ConvertFrom-Json}catch{}
            return [pscustomobject]@{Status=$status;Body=$parsed;Text=$content}
        }
    }
    $session=Send-Http GET '/api/session' '' ''
    Check ($session.Status -eq 200 -and $session.Body.token) 'The console must answer a normal session request (unaffected).'
    $token=[string]$session.Body.token
    $contextOk=Send-Http GET '/api/context' $token ''
    Check ($contextOk.Status -eq 200) 'A normal context read must stay 200.'
    $validShape=@{action='NoSuchAction';args=@{};expectedRevision=[int]$session.Body.revision;contextId=[string]$session.Body.contextId}|ConvertTo-Json -Compress
    foreach($route in @('/api/operations','/api/view','/api/context','/api/wizard')){
        foreach($bad in @(@{Name='damaged JSON';Text='{ "action": '},@{Name='JSON array';Text='[1,2,3]'},@{Name='JSON string';Text='"hello"'},@{Name='JSON number';Text='42'},@{Name='JSON null';Text='null'},@{Name='empty body';Text=''})){
            $reply=Send-Http POST $route $token $bad.Text
            Check ($reply.Status -eq 400 -and $reply.Body -and $reply.Body.code -ceq 'invalid_request') ($route+' with a '+$bad.Name+' body must answer 400 invalid_request, got '+$reply.Status+' '+$reply.Text)
            Check ($reply.Text -notmatch 'Conversion from JSON|Invalid JSON|System\.|at <ScriptBlock>') ($route+' must not leak exception text for a '+$bad.Name+'.')
        }
    }
    foreach($route in @('/api/operations','/api/view')){
        $unknownField=Send-Http POST $route $token '{"action":"NoSuchAction","args":{},"expectedRevision":0,"contextId":"x","surprise":1}'
        Check ($unknownField.Status -eq 400 -and $unknownField.Body.code -ceq 'invalid_request') ($route+' with an unknown field must be 400 invalid_request.')
        $missingFields=Send-Http POST $route $token '{"action":"NoSuchAction"}'
        Check ($missingFields.Status -eq 400 -and $missingFields.Body.code -ceq 'invalid_request') ($route+' with missing required fields must be 400 invalid_request.')
        $wrongType=Send-Http POST $route $token $validShape 'text/plain'
        Check ($wrongType.Status -eq 400 -and $wrongType.Body.code -ceq 'invalid_request') ($route+' with a wrong content type must be 400 invalid_request.')
        $unknownAction=Send-Http POST $route $token $validShape
        Check ($unknownAction.Status -eq 400 -and $unknownAction.Body.code -ceq 'invalid_request') ($route+' with an unknown action must be 400 invalid_request, got '+$unknownAction.Status+' '+$unknownAction.Text)
    }
    # a rejected request never changes the console: the same session still works.
    $again=Send-Http GET '/api/session' '' ''
    Check ($again.Status -eq 200) 'The console must keep serving after the rejected bodies.'
    Check ($script:EnvRetries -le 6) 'Environmental loopback retries stay bounded.'
}finally{
    if($consoleProcess){try{[IO.File]::WriteAllText($stop,'stop')}catch{};if(-not $consoleProcess.WaitForExit(20000)){try{$consoleProcess.Kill()}catch{}}}
    try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('cleanup: '+$_.Exception.Message)}
    Remove-Module WindowsServerMigration -Force -ErrorAction SilentlyContinue
}
Write-Host ('PASS: HTML errors are classified by exception type (contract errors -> 400 invalid_request, internal "parameter" messages -> operation_failed), bodies are parsed by one typed helper, and the real console rejects damaged and wrongly typed bodies on 4 routes ('+$script:checks+' checks, '+$script:EnvRetries+' environmental retries).')
