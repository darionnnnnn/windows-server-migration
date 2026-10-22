#requires -Version 5.1
# Offline restore journey (G): one immutable snapshot, Source -> independent copy ->
# Source/Manager cut off -> Target HTML console over HTTP -> credential wait ->
# crash -> explicit resume -> verdict. See work/r7/specs/G-offline-journey.md.
param(
    [ValidateRange(1,7)][int]$StopAfterStage=7,
    [switch]$KeepArtifacts,
    [switch]$MutationResumeAsNewRestore,
    [switch]$MutationSecretInWorkspace,
    [string]$RunId=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(-not $RunId){$RunId=(Get-Date -Format 'MMddHHmmss')+[Guid]::NewGuid().ToString('N').Substring(0,4)}
if($RunId -notmatch '^[A-Za-z0-9]{6,16}$'){throw 'RunId must be 6-16 alphanumeric characters.'}
$testRoot='C:\Users\Public\wsm-g-'+$RunId
$runDir=Join-Path (Join-Path $repo 'work\r7\g-journey') $RunId
$canary='G-SYNTHETIC-CANARY'
$secretRef='GJourneyServiceCredential'
$serviceAccount='GWSM\svc-gjourney'
$script:Verdict=[ordered]@{RunId=$RunId;StartedUtc=[DateTime]::UtcNow.ToString('o');Stages=@();Checks=[ordered]@{};Notes=@();Overall='Failed'}
$script:Pids=New-Object 'System.Collections.Generic.List[int]'
$script:DeniedPaths=New-Object 'System.Collections.Generic.List[string]'
$script:DenyOriginals=@{}
$script:Snapshot=$null
$script:Failed=$false
$script:DenyWasActiveDuringTarget=$false
$script:ServicePassword=$canary+'-'+$RunId
$script:CrashEnabled=$true
$script:ForbiddenRoots=@()
$script:TargetInventoryPath=''

function Write-Stage([int]$Number,[string]$Text){
    $line='STAGE '+$Number+': '+$Text
    Write-Host $line
    $script:Verdict.Stages+=@([ordered]@{Stage=$Number;Text=$Text;Utc=[DateTime]::UtcNow.ToString('o')})
}
function Set-Check([string]$Name,[bool]$Value,[string]$Detail=''){
    $script:Verdict.Checks[$Name]=[ordered]@{Passed=$Value;Detail=$Detail}
    Write-Host ('  check '+$Name+' = '+$Value+$(if($Detail){' ('+$Detail+')'}else{''}))
}
function Get-FileSha256([string]$Path){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $stream=[IO.File]::Open($Path,'Open','Read','ReadWrite')
        try{[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose()}
    }finally{$sha.Dispose()}
}
function Get-BytesSha256([byte[]]$Bytes){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-TextSha256([string]$Text){Get-BytesSha256 ([Text.Encoding]::UTF8.GetBytes($Text))}
function Get-SrcDigest([string]$SrcRoot){
    $rows=@(Get-ChildItem -LiteralPath $SrcRoot -Recurse -File -Force | ForEach-Object {$_.FullName.Substring($SrcRoot.TrimEnd('\').Length+1).Replace('\','/')+'|'+(Get-FileSha256 $_.FullName)} | Sort-Object {$_} -CaseSensitive)
    [pscustomobject]@{Digest=(Get-TextSha256 ($rows -join "`n"));Rows=$rows}
}
function Get-CommittedSrcDigest {
    # Tracked src/ bytes: working tree first, git show HEAD:<path> when line-ending
    # conversion makes the working tree differ from the committed blob.
    $listed=@(& git -C $repo ls-files -- src)
    if($LASTEXITCODE -ne 0 -or -not $listed.Count){throw 'git ls-files src failed.'}
    $rows=New-Object 'System.Collections.Generic.List[string]';$usedHead=0;$workingTreeRows=New-Object 'System.Collections.Generic.List[string]'
    foreach($relative in $listed){
        $workingHash=Get-FileSha256 (Join-Path $repo $relative)
        $key=$relative.Substring(4)
        $workingTreeRows.Add($key+'|'+$workingHash)
    }
    $workingDigest=Get-TextSha256 ((@($workingTreeRows.ToArray() | Sort-Object {$_} -CaseSensitive)) -join "`n")
    $headRows=New-Object 'System.Collections.Generic.List[string]'
    foreach($relative in $listed){
        $tmp=[IO.Path]::GetTempFileName()
        try{
            $psi=New-Object Diagnostics.ProcessStartInfo 'git',('-C "'+$repo+'" show HEAD:'+$relative)
            $psi.RedirectStandardOutput=$true;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
            $process=[Diagnostics.Process]::Start($psi)
            $output=New-Object IO.MemoryStream
            $process.StandardOutput.BaseStream.CopyTo($output);$process.WaitForExit()
            if($process.ExitCode -ne 0){throw ('git show failed for '+$relative)}
            $headRows.Add($relative.Substring(4)+'|'+(Get-BytesSha256 $output.ToArray()))
        }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
    }
    $headDigest=Get-TextSha256 ((@($headRows.ToArray() | Sort-Object {$_} -CaseSensitive)) -join "`n")
    [pscustomobject]@{WorkingTreeDigest=$workingDigest;HeadDigest=$headDigest;FileCount=$listed.Count}
}
function Invoke-GPhase([string]$Phase,[switch]$Overlay,[string]$ExtraArgs=''){
    $saved=@{};if($Overlay){$overlayEnv=Get-OverlayEnvironment;$overlayEnv['WSM_G_FORBIDDEN_ROOTS']='';foreach($key in $overlayEnv.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,[string]$overlayEnv[$key],'Process')}}
    try{Invoke-GPhaseCore $Phase $ExtraArgs}finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key],'Process')}}
}
function Invoke-GPhaseCore([string]$Phase,[string]$ExtraArgs=''){
    $out=Join-Path $runDir ('log-'+$Phase+'.out.txt');$err=Join-Path $runDir ('log-'+$Phase+'.err.txt')
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$script:HostScript+'" -Phase '+$Phase+' -Config "'+$script:ConfigPath+'" '+$ExtraArgs
    $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    $script:Pids.Add($process.Id);$null=$process.Handle
    if(-not $process.WaitForExit(600000)){try{$process.Kill()}catch{};throw ('Phase '+$Phase+' timed out.')}
    $process.WaitForExit()
    if($process.ExitCode -ne 0){
        $tail=if([IO.File]::Exists($err)){(Get-Content -LiteralPath $err -Tail 25 -ErrorAction SilentlyContinue) -join [Environment]::NewLine}else{''}
        throw ('Phase '+$Phase+' failed with exit code '+$process.ExitCode+[Environment]::NewLine+$tail)
    }
    $resultPath=Join-Path $runDir ('phase-'+$script:PhaseResultNames[$Phase]+'.json')
    if([IO.File]::Exists($resultPath)){Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json}
}
$script:PhaseResultNames=@{SourceInventory='source-inventory';ManagerApprove='manager-approve';SourceBackup='source-backup';TargetSeedInventory='target-seed'}
function Add-DenyAcl([string]$Path){
    # icacls /deny replaces the owner's own allow ACE, so the exact original DACL is kept for the restore.
    $script:DenyOriginals[$Path]=(Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm('Access')
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /deny ($user+':(OI)(CI)F') | Out-Null
    if($LASTEXITCODE -ne 0){throw ('icacls deny failed for '+$Path)}
    $script:DeniedPaths.Add($Path)
}
function Remove-DenyAcl([string]$Path){
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /remove:d $user | Out-Null
    if($script:DenyOriginals.ContainsKey($Path)){
        $restored=New-Object Security.AccessControl.DirectorySecurity
        $restored.SetSecurityDescriptorSddlForm($script:DenyOriginals[$Path],[Security.AccessControl.AccessControlSections]::Access)
        [IO.Directory]::SetAccessControl($Path,$restored)
    }
}
function Test-PathAccessDenied([string]$Path){
    try{[void][IO.Directory]::GetFileSystemEntries($Path);return $false}catch [UnauthorizedAccessException]{return $true}catch{return $false}
}
function Assert-OwnedPath([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    $ok=($full.StartsWith($testRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $full -ieq $testRoot) -and $full.IndexOf($RunId,[StringComparison]::OrdinalIgnoreCase) -ge 0
    if(-not $ok){throw ('Refusing to touch a path that is not owned by this run: '+$full)}
}


Add-Type -AssemblyName System.Net.Http
$script:ConsoleInfo=$null
function Get-OverlayEnvironment {
    [ordered]@{
        WSM_G_OVERLAY='1'
        WSM_G_TRACE=(Join-Path $runDir 'target-trace.jsonl')
        WSM_G_SERVICE_FIXTURE=(Join-Path $runDir 'service-fixture.json')
        WSM_G_EXPECTED_PASSWORD=$script:ServicePassword
        WSM_G_CRASH_MARKER=(Join-Path $runDir 'crash-marker.json')
        WSM_G_CRASH_NTH='2'
        WSM_G_CRASH_ON_COMPLETED=$(if($script:CrashEnabled){'1'}else{'0'})
        WSM_G_FORBIDDEN_ROOTS=($script:ForbiddenRoots -join ';')
        WSM_G_TARGET_INVENTORY=$script:TargetInventoryPath
        WSM_G_EXTRA_CATALOG=(Join-Path $runDir 'g-extra-software.marker')
    }
}
function Start-GConsole([string]$Tag,[string]$Workspace='',[hashtable]$ExtraEnv=@{}){
    $ready=Join-Path $runDir ('console-'+$Tag+'-ready.json');$stop=Join-Path $runDir ('console-'+$Tag+'-stop');$out=Join-Path $runDir ('log-console-'+$Tag+'.out.txt');$err=Join-Path $runDir ('log-console-'+$Tag+'.err.txt')
    $saved=@{};$overlay=Get-OverlayEnvironment
    foreach($key in $ExtraEnv.Keys){$overlay[$key]=[string]$ExtraEnv[$key]}
    foreach($key in $overlay.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process');[Environment]::SetEnvironmentVariable($key,[string]$overlay[$key],'Process')}
    try{
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$script:HostScript+'" -Phase TargetConsole -Config "'+$script:ConfigPath+'" -ReadyPath "'+$ready+'" -StopFile "'+$stop+'"'+$(if($Workspace){' -Workspace "'+$Workspace+'"'}else{''})
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
        $null=$process.Handle;$script:Pids.Add($process.Id)
    }finally{foreach($key in $overlay.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key],'Process')}}
    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    while(-not [IO.File]::Exists($ready)){
        if($process.HasExited){throw ('Target console exited early with code '+$process.ExitCode+': '+((Get-Content -LiteralPath $err -Tail 15 -ErrorAction SilentlyContinue) -join ' | '))}
        if([DateTime]::UtcNow -gt $deadline){throw 'Target console did not become ready.'}
        Start-Sleep -Milliseconds 200
    }
    $info=Get-Content -LiteralPath $ready -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:ConsoleInfo=[pscustomobject]@{Tag=$Tag;Process=$process;Origin=[string]$info.Url;Stop=$stop;Ready=$ready;Token='';ContextId='';Session=$null}
    Update-GSession | Out-Null
    $script:ConsoleInfo
}
function Stop-GConsole([int]$WaitSeconds=20){
    $info=$script:ConsoleInfo;if(-not $info){return}
    [IO.File]::WriteAllText($info.Stop,'stop')
    if(-not $info.Process.WaitForExit($WaitSeconds*1000)){try{$info.Process.Kill()}catch{}}
    $script:ConsoleInfo=$null
}
$script:HttpRetries=0
$script:Workarounds=[ordered]@{}
function Invoke-GApi([string]$Method,[string]$Route,$Body=$null,[switch]$NoLog,[int]$TimeoutSeconds=60,[switch]$Retry){
    # This runner's loopback occasionally resets a connection before any response (it also happens with a raw
    # TcpClient, so it is environmental). Reads and replay-safe writes are retried; other writes are not.
    $canRetry=($Method -ceq 'GET') -or $Retry
    for($attempt=1;;$attempt++){
        try{return (Invoke-GApiOnce $Method $Route $Body ([bool]$NoLog) $TimeoutSeconds)}
        catch{
            if(-not $canRetry -or $attempt -ge 10){throw}
            $script:HttpRetries++;Start-Sleep -Milliseconds 300
        }
    }
}
function Invoke-GApiOnce([string]$Method,[string]$Route,$Body,[bool]$NoLog,[int]$TimeoutSeconds){
    $info=$script:ConsoleInfo
    $client=New-Object System.Net.Http.HttpClient;$client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
    try{
        $request=New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method)),($info.Origin+$Route)
        $request.Headers.ConnectionClose=$true
        [void]$request.Headers.TryAddWithoutValidation('Origin',$info.Origin)
        if($info.Token){[void]$request.Headers.TryAddWithoutValidation('X-Wsm-Token',$info.Token)}
        if($null -ne $Body){$request.Content=New-Object System.Net.Http.StringContent((ConvertTo-Json -InputObject $Body -Depth 30 -Compress),[Text.Encoding]::UTF8,'application/json')}
        $response=$client.SendAsync($request).GetAwaiter().GetResult()
        $text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $data=$null;if($text){try{$data=$text | ConvertFrom-Json}catch{$data=$text}}
        $result=[pscustomobject]@{Status=[int]$response.StatusCode;Data=$data;Text=$text}
        if(-not $NoLog){
            $logLine=ConvertTo-Json -InputObject ([ordered]@{Utc=[DateTime]::UtcNow.ToString('o');Method=$Method;Route=$Route;Status=$result.Status;BodyKeys=$(if($null -ne $Body){@($Body.Keys)}else{@()});Response=$(if($text.Length -gt 6000){$text.Substring(0,6000)}else{$text})}) -Compress -Depth 5
            [IO.File]::AppendAllText((Join-Path $runDir 'http-log.jsonl'),$logLine+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
        }
        $result
    }finally{$client.Dispose()}
}
function Update-GSession {
    $info=$script:ConsoleInfo
    $info.Token=''
    $session=Invoke-GApi 'GET' '/api/session' -NoLog
    if($session.Status -ne 200){throw ('Session request failed: '+$session.Status)}
    $info.Token=[string]$session.Data.token;$info.ContextId=[string]$session.Data.contextId;$info.Session=$session.Data
    $info
}
function New-GOperationBody([string]$Action,$Arguments,$Revision=$null){
    $session=$script:ConsoleInfo.Session
    [ordered]@{action=$Action;args=$Arguments;operationId=[Guid]::NewGuid().ToString('D');idempotencyKey=[Guid]::NewGuid().ToString('D');expectedRevision=[int]$(if($null -ne $Revision){$Revision}else{$session.revision});expectedDecisionRevision=$session.decisionRevision;expectedSelectionRevision=$session.selectionRevision;expectedDataVersion=$session.dataVersion;contextId=[string]$script:ConsoleInfo.ContextId}
}
$script:DoneStatuses=@('Succeeded','Failed','Cancelled','Interrupted','ReviewRequired','Deferred','Blocked','WaitingForInput','Partial')
function Wait-GJob([string]$JobId,[string[]]$Until=$script:DoneStatuses,[int]$TimeoutSeconds=900){
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do{
        $job=Invoke-GApi 'GET' ('/api/jobs/'+$JobId) -NoLog
        if($job.Status -ne 200){throw ('Job read failed: '+$job.Status+' '+$job.Text)}
        if($Until -contains [string]$job.Data.status){
            [IO.File]::AppendAllText((Join-Path $runDir 'http-log.jsonl'),((ConvertTo-Json -InputObject ([ordered]@{Utc=[DateTime]::UtcNow.ToString('o');Method='GET';Route=('/api/jobs/'+$JobId);Status=200;Response=$(if($job.Text.Length -gt 6000){$job.Text.Substring(0,6000)}else{$job.Text})}) -Compress -Depth 5)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
            return $job.Data
        }
        Start-Sleep -Milliseconds 300
    }while([DateTime]::UtcNow -lt $deadline)
    throw ('Job '+$JobId+' did not reach one of '+($Until -join ',')+' in time.')
}
function Submit-GOperation([string]$Action,$Arguments,$Revision=$null,[string[]]$Until=$script:DoneStatuses){
    $body=New-GOperationBody $Action $Arguments $Revision
    $accepted=Invoke-GApi 'POST' '/api/operations' $body -Retry
    if($accepted.Status -notin @(200,202)){throw ($Action+' submission was rejected: '+$accepted.Status+' '+$accepted.Text)}
    $initial=if($accepted.Data.PSObject.Properties['job']){$accepted.Data.job}else{$accepted.Data}
    if([string]$initial.jobId -cne [string]$body.operationId){throw ($Action+' did not retain its operation id.')}
    $record=Wait-GJob ([string]$body.operationId) $Until
    Update-GSession | Out-Null
    [pscustomobject]@{Request=$body;Record=$record}
}
function Switch-GContext([string]$PairId){
    for($attempt=1;$attempt -le 6;$attempt++){
        $current=$script:ConsoleInfo.Session
        $body=[ordered]@{pairId=$PairId;role='Target';expectedRevision=$current.revision;expectedDecisionRevision=$current.decisionRevision;expectedSelectionRevision=$current.selectionRevision;expectedDataVersion=$current.dataVersion;contextId=[string]$script:ConsoleInfo.ContextId}
        try{$response=Invoke-GApi 'POST' '/api/context' $body}catch{$response=$null;$script:HttpRetries++}
        Update-GSession | Out-Null
        if([string]$script:ConsoleInfo.Session.pairId -ceq $PairId){return}
        if($response -and $response.Status -ne 200){throw ('Context switch failed: '+$response.Status+' '+$response.Text)}
    }
    throw 'Context switch did not take effect.'
}
function Get-GWizardQuery([string]$PairId=''){
    'role=Target&pairId='+[Uri]::EscapeDataString($PairId)+'&contextId='+[Uri]::EscapeDataString([string]$script:ConsoleInfo.ContextId)
}
function Get-GRuntime([string]$PairId){
    $result=Invoke-GApi 'GET' ('/api/wizard/runtime?'+(Get-GWizardQuery $PairId)) -NoLog
    if($result.Status -ne 200){throw ('Runtime projection failed: '+$result.Status+' '+$result.Text)}
    $result.Data
}
function Get-GActionDefaults([string]$Action,[string]$PairId){
    $result=Invoke-GApi 'GET' ('/api/wizard/defaults?action='+[Uri]::EscapeDataString($Action)+'&'+(Get-GWizardQuery $PairId)) -NoLog
    if($result.Status -ne 200){throw ('Action defaults failed for '+$Action+': '+$result.Status+' '+$result.Text)}
    $result.Data
}
function ConvertTo-GHashtable($Object){
    $table=[ordered]@{};if($null -ne $Object){foreach($property in $Object.PSObject.Properties){$table[$property.Name]=$property.Value}};$table
}
function Submit-GRuntimeAction([string]$Action,$Fields,[string]$PairId,[string[]]$Until=$script:DoneStatuses){
    $projection=Get-GRuntime $PairId
    $entry=@($projection.actions | Where-Object {[string]$_.id -ceq $Action}) | Select-Object -First 1
    if(-not $entry -or $entry.available -eq $false){throw ('Runtime action '+$Action+' is not available: '+$(if($entry){[string]$entry.reason}else{'unknown'}))}
    $arguments=ConvertTo-GHashtable $entry.defaults
    foreach($key in @($Fields.Keys)){$arguments[$key]=$Fields[$key]}
    if($Action -ceq 'TargetRestore'){$arguments.Remove('RestoreConfirmation')}
    $revision=$null;if($projection.PSObject.Properties['viewContext'] -and $projection.viewContext){$revision=$projection.viewContext.revision}
    Submit-GOperation $Action $arguments $revision $Until
}

function Get-TreeHashMap([string]$Root){
    $map=@{}
    foreach($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue){
        if($file.FullName -like '*.lock*' -or $file.FullName -like '*.tmp'){continue}
        try{$map[$file.FullName.Substring($Root.TrimEnd([char]92).Length+1)]=Get-FileSha256 $file.FullName}catch{$map[$file.FullName.Substring($Root.TrimEnd([char]92).Length+1)]='unreadable'}
    }
    $map
}
function Compare-HashMaps($Before,$After){
    $changes=@()
    foreach($key in $Before.Keys){if(-not $After.ContainsKey($key)){$changes+=@('removed:'+$key)}elseif($After[$key] -cne $Before[$key]){$changes+=@('changed:'+$key)}}
    foreach($key in $After.Keys){if(-not $Before.ContainsKey($key)){$changes+=@('added:'+$key)}}
    $changes
}
function Restore-DenyAcls {
    foreach($path in @($script:DeniedPaths)){Remove-DenyAcl $path}
    $script:DeniedPaths.Clear()
}
function ConvertTo-Latin1String([byte[]]$Bytes){[Text.Encoding]::GetEncoding(28591).GetString($Bytes)}
function Get-CanaryNeedles {
    $utf8=[Text.Encoding]::UTF8.GetBytes($canary)
    $needles=[ordered]@{'utf8'=(ConvertTo-Latin1String $utf8);'utf16le'=(ConvertTo-Latin1String ([Text.Encoding]::Unicode.GetBytes($canary)))}
    for($pad=0;$pad -lt 3;$pad++){
        $bytes=New-Object byte[] ($pad+$utf8.Length);[Array]::Copy($utf8,0,$bytes,$pad,$utf8.Length)
        $encoded=[Convert]::ToBase64String($bytes).TrimEnd('=')
        # Characters that mix the padding or the following byte are dropped; the middle is stable.
        $needles['base64+'+$pad]=$encoded.Substring(4,$encoded.Length-8)
    }
    $needles
}
function Find-CanaryHits([string[]]$Roots,[string[]]$ExtraTexts=@()){
    $needles=Get-CanaryNeedles;$hits=New-Object 'System.Collections.Generic.List[string]';$scanned=0
    foreach($root in $Roots){
        if(-not [IO.Directory]::Exists($root)){continue}
        foreach($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue){
            if($file.Length -gt 64MB){continue}
            try{$text=ConvertTo-Latin1String ([IO.File]::ReadAllBytes($file.FullName))}catch{continue}
            $scanned++
            foreach($name in $needles.Keys){if($text.IndexOf([string]$needles[$name],[StringComparison]::Ordinal) -ge 0){$hits.Add($name+' in '+$file.FullName)}}
        }
    }
    foreach($extra in $ExtraTexts){$text=ConvertTo-Latin1String ([Text.Encoding]::UTF8.GetBytes($extra));foreach($name in $needles.Keys){if($text.IndexOf([string]$needles[$name],[StringComparison]::Ordinal) -ge 0){$hits.Add($name+' in <in-memory verdict>')}}}
    [pscustomobject]@{Hits=@($hits.ToArray());FilesScanned=$scanned}
}
function Invoke-Judgement($SourceInventory,$ManagerApprove,[string]$PairId,[string]$MovedData,[string]$SrcData,[string]$SrcNeighbor,[string]$WsTarget,[string]$SnapshotRoot,[string]$ExecRoot,$DigestBefore){
    $final=$script:FinalJob
    Set-Check 'parent_job_id_unchanged_and_terminal_succeeded' (([string]$final.jobId -ceq $script:ParentJobId) -and ([string]$final.status -ceq 'Succeeded')) ([string]$final.status)
    # bytes at the original location
    $badFiles=@();$expectedRelatives=@{}
    foreach($row in @($SourceInventory.SourceFiles)){
        $expectedRelatives[[string]$row.Relative]=$true
        $path=Join-Path $SrcData ([string]$row.Relative)
        if(-not [IO.File]::Exists($path) -or (Get-FileSha256 $path) -cne [string]$row.SHA256){$badFiles+=@([string]$row.Relative)}
    }
    $extraFiles=@(Get-ChildItem -LiteralPath $SrcData -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {-not $expectedRelatives.ContainsKey($_.FullName.Substring($SrcData.TrimEnd([char]92).Length+1))} | ForEach-Object {$_.FullName})
    Set-Check 'restored_file_bytes_equal_source_sha256' ($badFiles.Count -eq 0 -and $extraFiles.Count -eq 0) ('bad='+($badFiles -join ',')+' extra='+($extraFiles -join ','))
    $missingDirs=@($SourceInventory.SourceDirectories | Where-Object {-not [IO.Directory]::Exists((Join-Path $SrcData ([string]$_)))})
    Set-Check 'empty_directory_and_nested_directories_exist' ($missingDirs.Count -eq 0 -and @($SourceInventory.SourceDirectories).Count -ge 2) ($missingDirs -join ',')
    $movedStillIntact=$true;foreach($row in @($SourceInventory.SourceFiles)){$moved=Join-Path $MovedData ([string]$row.Relative);if(-not [IO.File]::Exists($moved) -or (Get-FileSha256 $moved) -cne [string]$row.SHA256){$movedStillIntact=$false}}
    Set-Check 'moved_aside_originals_untouched' $movedStillIntact
    Set-Check 'unselected_neighbor_target_absent' (-not [IO.Directory]::Exists($SrcNeighbor) -and -not [IO.File]::Exists($SourceInventory.NeighborFile))
    # journal / trace based proofs
    $traceRows=@(Get-Content -LiteralPath (Join-Path $runDir 'target-trace.jsonl') -Encoding UTF8 | ForEach-Object {$_ | ConvertFrom-Json})
    $journalRows=@($traceRows | Where-Object Kind -ceq 'Journal')
    $perFile=@{}
    foreach($row in $journalRows){
        $target=[string]$row.Data.Target;if(-not $target -or -not $target.StartsWith($SrcData,[StringComparison]::OrdinalIgnoreCase)){continue}
        if(-not $perFile.ContainsKey($target)){$perFile[$target]=[ordered]@{Intent=0;Completed=0;Pids=@()}}
        if([string]$row.Data.Action -ceq 'AssistiveFileIntent'){$perFile[$target].Intent++}
        if([string]$row.Data.Action -ceq 'AssistiveFileCompleted'){$perFile[$target].Completed++}
        $perFile[$target].Pids+=@($row.Pid)
    }
    $crashTarget=[string]$script:Verdict.Crash.Marker.Target
    $others=@($perFile.Keys | Where-Object {$_ -ine $crashTarget -and ($perFile[$_].Intent+$perFile[$_].Completed) -gt 0})
    $othersOnce=@($others | Where-Object {$perFile[$_].Intent -ne 1 -or $perFile[$_].Completed -ne 1}).Count -eq 0
    Set-Check 'completed_files_not_rewritten_after_resume' ($othersOnce -and $others.Count -ge 1) ('files with exactly one intent and one completed: '+$others.Count)
    $crashStats=$perFile[$crashTarget]
    $crashRecovered=([IO.File]::Exists($crashTarget)) -and ((Get-FileSha256 $crashTarget) -ceq [string]$script:Verdict.Crash.Marker.ExpectedSHA256)
    $recoveredRows=@($journalRows | Where-Object {[string]$_.Data.Action -ceq 'AssistiveFileRecovered' -and [string]$_.Data.Target -ieq $crashTarget}).Count
    Set-Check 'interrupted_file_reconciled_without_second_native_write' ($crashRecovered -and $crashStats.Intent -eq 1 -and $recoveredRows -ge 1) ('intent='+$crashStats.Intent+' recovered='+$recoveredRows)
    $reprompt=@($journalRows | Where-Object {[string]$_.Data.Action -ceq 'AssistiveServiceCredentialReprompt'}).Count
    Set-Check 'journal_has_preview_rebound' (@($journalRows | Where-Object {[string]$_.Data.Action -ceq 'AssistiveRestorePreviewRebound'}).Count -ge 1) 'AssistiveRestorePreviewRebound'
    Set-Check 'resume_reprompted_credentials_through_journal' ($reprompt -ge 1) ([string]$reprompt)
    $script:Verdict.JournalPerFile=[ordered]@{};foreach($key in $perFile.Keys){$script:Verdict.JournalPerFile[$key]=$perFile[$key]}
    $statePath=@(Get-ChildItem -LiteralPath (Join-Path $WsTarget 'pairs') -Recurse -Filter 'state.json' -File | Where-Object {$_.FullName -like ('*'+$PairId+'*')})[0].FullName
    $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Verdict.RestoreAttempt=[ordered]@{Stage=[string]$state.Stage;AttemptStatus=[string]$state.RestoreAttempt.Status;ItemResultStatuses=@($state.RestoreAttempt.ItemResults | ForEach-Object {[string]$_.ItemId+'='+[string]$_.Status});Continuations=@($state.RestoreAttempt.Continuations).Count;PendingOperations=@($state.PendingOperations).Count}
    Set-Check 'state_has_no_pending_operations_and_succeeded' ((@($state.PendingOperations).Count -eq 0) -and ([string]$state.Stage -ceq 'Succeeded'))
    # Service double
    $serviceRows=@($traceRows | Where-Object Kind -ceq 'ServiceApply')
    Set-Check 'service_double_received_approved_account_exactly_once' ($serviceRows.Count -eq 1 -and [bool]$serviceRows[0].Data.AccountMatches -and [bool]$serviceRows[0].Data.SecretMatchesExpected -and [string]$serviceRows[0].Data.ReceivedAccount -ceq $serviceAccount) ('applications='+$serviceRows.Count)
    $script:Verdict.ServiceAppliedBeforeCrash=$script:ServiceAppliedBeforeCrash
    # Source / Manager access
    $forbidden=@($traceRows | Where-Object Kind -ceq 'ForbiddenAccess').Count
    $unauthorized=0;foreach($file in @(Get-ChildItem -LiteralPath $runDir -Filter 'log-console-*.txt' -File)+@(Get-ChildItem -LiteralPath (Join-Path $WsTarget 'console-errors') -File -ErrorAction SilentlyContinue)){if((Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue) -match 'UnauthorizedAccess'){$unauthorized++}}
    $unauthorized+=@($traceRows | Where-Object {$_.Kind -ceq 'SafeErrorSource' -and ([string]$_.Data.Message -match 'UnauthorizedAccess|\u62D2\u7D55\u5B58\u53D6')}).Count
    $script:Verdict.SourceManagerAccess=[ordered]@{ForbiddenAccessAttempts=$forbidden;UnauthorizedAccessSignals=$unauthorized}
    Set-Check 'source_manager_access_count_zero' ($forbidden -eq 0 -and $unauthorized -eq 0 -and $script:DenyWasActiveDuringTarget)
    # product flags
    $rt=$script:RuntimeFinal
    Set-Check 'production_verified_false_and_no_auto_activation' (($rt.ProductionVerified -eq $false) -and ($rt.AuthoritativeApproval -eq $false) -and ($rt.runtime.noAutoActivation -eq $true) -and ($rt.runtime.noAutoResume -eq $true) -and -not (Get-Service -Name 'GJourneyService' -ErrorAction SilentlyContinue)) 'no real service, no activation'
    $jobFlags=0;foreach($file in Get-ChildItem -LiteralPath (Join-Path $WsTarget 'console-jobs') -Filter '*.json' -File){if((Get-Content -LiteralPath $file.FullName -Raw) -match '"ProductionVerified"\s*:\s*true'){$jobFlags++}}
    Set-Check 'no_job_record_claims_production_verified' ($jobFlags -eq 0)
    # snapshot digest
    $digestAfter=Get-SrcDigest (Join-Path $SnapshotRoot 'src')
    $script:Verdict.Snapshot.SrcDigestAfter=$digestAfter.Digest
    Set-Check 'snapshot_src_digest_unchanged_and_equals_committed' (($digestAfter.Digest -ceq $DigestBefore.Digest) -and ($digestAfter.Digest -ceq $script:Verdict.Snapshot.CommittedWorkingTreeDigest -or $digestAfter.Digest -ceq $script:Verdict.Snapshot.CommittedHeadDigest))
    $script:Verdict.ExecutionBytes='execution bytes = committed product bytes + test overlay appended to WindowsServerMigration.psm1'
    # secret canary
    if($MutationSecretInWorkspace){[IO.File]::WriteAllText((Join-Path $WsTarget 'g-mutation-secret.txt'),('leak '+$script:ServicePassword),(New-Object Text.UTF8Encoding($false)))}
    $inMemory=ConvertTo-Json -InputObject $script:Verdict -Depth 12
    $scan=Find-CanaryHits @($testRoot,$runDir) @($inMemory)
    $script:Verdict.CanaryScan=[ordered]@{FilesScanned=$scan.FilesScanned;Encodings=@('utf8','utf16le','base64 (3 alignments)');Hits=@($scan.Hits)}
    Set-Check 'secret_canary_absent_in_all_encodings' ($scan.Hits.Count -eq 0 -and $scan.FilesScanned -gt 50) ('hits='+$scan.Hits.Count+' scanned='+$scan.FilesScanned)
    Set-Check 'http_retry_count_recorded' $true ([string]$script:HttpRetries)
}

function Get-TraceLineCount {
    $path=Join-Path $runDir 'target-trace.jsonl'
    if([IO.File]::Exists($path)){@(Get-Content -LiteralPath $path -Encoding UTF8).Count}else{0}
}
function Get-SafeErrorsSince([int]$FromLine){
    $path=Join-Path $runDir 'target-trace.jsonl'
    if(-not [IO.File]::Exists($path)){return @()}
    @(Get-Content -LiteralPath $path -Encoding UTF8 | Select-Object -Skip $FromLine | ForEach-Object {$_ | ConvertFrom-Json} | Where-Object Kind -ceq 'SafeErrorSource' | ForEach-Object {[string]$_.Data.Message})
}
function Add-R8Result([string]$Case,[bool]$Rejected,[string]$Message,[bool]$NoWrites,[string]$Expected){
    $matches=($Message -match $Expected)
    $script:R8[$Case]=[ordered]@{Rejected=$Rejected;Reason=$Message;ReasonMatchesExpectation=$matches;ExpectedPattern=$Expected;NoTargetWrites=$NoWrites}
    Set-Check ('r8_'+$Case) ($Rejected -and $matches -and $NoWrites) $(if($Message.Length -gt 160){$Message.Substring(0,160)}else{$Message})
}
function Test-NoWritesSince($Baseline,[string]$SrcData,[string]$SrcNeighbor,[string]$NegWorkspace=''){
    $after=Get-TreeHashMap $SrcData
    $unchanged=(@(Compare-HashMaps $Baseline $after).Count -eq 0) -and -not [IO.Directory]::Exists($SrcNeighbor)
    if($NegWorkspace){$unchanged=$unchanged -and -not @(Get-ChildItem -LiteralPath $NegWorkspace -Recurse -Filter 'state.json' -File -ErrorAction SilentlyContinue).Count}
    $unchanged
}
function Invoke-R8($ManagerApprove,$TargetEnroll,$SourceInventory,[string]$PairId,[string]$SrcData,[string]$SrcNeighbor,[string]$WsTarget,$SelectedIds){
    $script:R8=[ordered]@{}
    $planPath=[string]$ManagerApprove.PlanPath;$planHash=[string]$ManagerApprove.PlanHash
    $baseline=Get-TreeHashMap $SrcData
    # 0. controls inventory is the comparison source (the plan has no GeneralHost software list)
    $planText=[IO.File]::ReadAllText($planPath,[Text.Encoding]::UTF8)
    $materialRoot=Join-Path $WsTarget ('workspace-control\wizard-materials\target-'+$PairId)
    $comparisonFile=@(Get-ChildItem -LiteralPath $materialRoot -Filter 'comparison-*.json' -File | Sort-Object LastWriteTime)[0]
    $comparisonText=[IO.File]::ReadAllText($comparisonFile.FullName,[Text.Encoding]::UTF8)
    Set-Check 'r8_comparison_source_list_comes_from_package_controls' (($planText -notmatch '"GeneralHost"') -and ($comparisonText -match 'G Controls Only Product') -and ($comparisonText -match '"Provenance":\s*"TargetLocal"')) 'plan has no GeneralHost list; comparison row exists only in controls/source-inventory.json'
    $script:R8['ControlsOnlyRowPresent']=($comparisonText -match 'G Controls Only Product')
    # identity cases on separate enrolled workspaces
    foreach($case in @(@('wrong_target',('e'*64),'G-OTHER-HOST'),@('same_name_different_machine',('f'*64),[string]$env:COMPUTERNAME))){
        $tag=[string]$case[0];$ws=Join-Path $testRoot ('ws-neg-'+$tag)
        Start-GConsole ('neg-'+$tag) $ws @{WSM_G_FAKE_FINGERPRINT=[string]$case[1];WSM_G_FAKE_NAME=[string]$case[2]} | Out-Null
        $enrol=Invoke-GApi 'POST' '/api/wizard' ([ordered]@{operation='chooseIntent';role='Target';expectedWizardRevision=0;contextId=[string]$script:ConsoleInfo.ContextId}) -Retry
        Update-GSession | Out-Null
        $from=Get-TraceLineCount
        $result=Submit-GOperation 'ImportApprovedPlan' ([ordered]@{Path=$planPath;ExpectedHash=$planHash})
        $messages=@(Get-SafeErrorsSince $from)
        $msg=if($messages.Count){$messages[-1]}else{''}
        Add-R8Result $tag ([string]$result.Record.status -ceq 'Failed') $msg (Test-NoWritesSince $baseline $SrcData $SrcNeighbor $ws) 'different local host identity'
        if($tag -ceq 'same_name_different_machine'){Set-Check 'r8_same_name_case_really_shares_the_name' ($planText -match [regex]::Escape([string]$env:COMPUTERNAME)) 'plan Target.Name equals this machine name while the fingerprint differs'}
        if($tag -ceq 'wrong_target'){
            # forged approval 1: bytes changed, the original (separately trusted) hash kept
            $forgedDir=Join-Path $runDir 'forged';[void][IO.Directory]::CreateDirectory($forgedDir)
            $bytesPath=Join-Path $forgedDir 'bytes-approved-plan.json'
            [IO.File]::WriteAllText($bytesPath,$planText.Replace('G journey owner','G journey ownex'),(New-Object Text.UTF8Encoding($false)))
            $from=Get-TraceLineCount
            $forged1=Submit-GOperation 'ImportApprovedPlan' ([ordered]@{Path=$bytesPath;ExpectedHash=$planHash})
            $m1=@(Get-SafeErrorsSince $from);$m1=if($m1.Count){$m1[-1]}else{''}
            Add-R8Result 'forged_approval_bytes_changed' ([string]$forged1.Record.status -ceq 'Failed') $m1 (Test-NoWritesSince $baseline $SrcData $SrcNeighbor $ws) 'could not be verified'
            # forged approval 2: target retargeted to this fake machine and the hash recomputed
            $reboundPath=Join-Path $forgedDir 'rehashed-approved-plan.json'
            [IO.File]::WriteAllText($reboundPath,$planText.Replace([string]$TargetEnroll.Fingerprint,([string]$case[1])),(New-Object Text.UTF8Encoding($false)))
            $reboundHash=Get-FileSha256 $reboundPath
            $from=Get-TraceLineCount
            $forged2=Submit-GOperation 'ImportApprovedPlan' ([ordered]@{Path=$reboundPath;ExpectedHash=$reboundHash})
            $m2=@(Get-SafeErrorsSince $from);$m2=if($m2.Count){$m2[-1]}else{''}
            Add-R8Result 'forged_approval_retargeted_and_rehashed' ([string]$forged2.Record.status -ceq 'Failed') $m2 (Test-NoWritesSince $baseline $SrcData $SrcNeighbor $ws) '.'
            $script:R8['forged_approval_retargeted_and_rehashed'].RejectedBy=$(if($m2 -match 'different local host identity'){'HostIdentity'}else{'SealOrHash'})
            $script:R8['forged_approval_retargeted_and_rehashed'].Note='ExpectedHash must come from a trusted channel chosen by the operator; a hash computed from the same untrusted file is not an authorization, so the host identity check is the accepted barrier.'
        }
        Stop-GConsole
    }
    # software installed after the comparison: gates on the real Target workspace
    $marker=Join-Path $runDir 'g-extra-software.marker'
    Start-GConsole 'r8a' | Out-Null
    Switch-GContext $PairId
    [IO.File]::WriteAllText($marker,'simulated post-comparison install')
    $receiptArgs=[ordered]@{Decision='RestoreNow';Owner='G journey owner';Reason='R8 receipt after an unrecorded install';SelectedItemIds=[string[]]$SelectedIds}
    $from=Get-TraceLineCount
    $lateReceipt=Submit-GOperation 'CreateTargetDecisionReceipt' $receiptArgs
    $m=@(Get-SafeErrorsSince $from);$m=if($m.Count){$m[-1]}else{''}
    Add-R8Result 'receipt_after_software_install_without_reinventory' ([string]$lateReceipt.Record.status -ceq 'Failed') $m (Test-NoWritesSince $baseline $SrcData $SrcNeighbor) 'Target software changed'
    $from=Get-TraceLineCount
    $latePreview=Submit-GOperation 'TargetRestorePreview' ([ordered]@{})
    $m=@(Get-SafeErrorsSince $from);$m=if($m.Count){$m[-1]}else{''}
    Add-R8Result 'preview_after_software_install_without_reinventory' ([string]$latePreview.Record.status -ceq 'Failed') $m (Test-NoWritesSince $baseline $SrcData $SrcNeighbor) 'Target software changed'
    Stop-GConsole
    # re-inventory (seeded, now containing the product) -> new comparison -> old receipt refused -> new receipt works
    Invoke-GPhase 'TargetSeedInventory' -Overlay -ExtraArgs '-SeedRevision 2 -SeedExtra' | Out-Null
    Start-GConsole 'r8b' | Out-Null
    Switch-GContext $PairId
    $from=Get-TraceLineCount
    $recompare=Submit-GOperation 'TargetLocalComparison' ([ordered]@{})
    $m=@(Get-SafeErrorsSince $from);$m=if($m.Count){$m[-1]}else{''}
    $script:R8['recompare_after_install']=[ordered]@{Status=[string]$recompare.Record.status;Reason=$m}
    if([string]$recompare.Record.status -cne 'Succeeded'){
        Set-Check 'r8_recompare_after_install_succeeds' $false ($m)
        Stop-GConsole
        return
    }
    $from=Get-TraceLineCount
    $oldReceiptPreview=Submit-GOperation 'TargetRestorePreview' ([ordered]@{})
    $m=@(Get-SafeErrorsSince $from);$m=if($m.Count){$m[-1]}else{''}
    Add-R8Result 'old_receipt_refused_after_recompare' ([string]$oldReceiptPreview.Record.status -ceq 'Failed') $m (Test-NoWritesSince $baseline $SrcData $SrcNeighbor) 'stale'
    $newReceipt=Submit-GOperation 'CreateTargetDecisionReceipt' $receiptArgs
    Set-Check 'r8_new_receipt_after_recompare_succeeds' ([string]$newReceipt.Record.status -ceq 'Succeeded') ([string]$newReceipt.Record.status)
    Stop-GConsole
    # Target inventory older than the 24 hour gate
    Invoke-GPhase 'TargetSeedInventory' -Overlay -ExtraArgs '-SeedRevision 3 -SeedExtra -SeedAgeHours 26' | Out-Null
    Start-GConsole 'r8c' | Out-Null
    Switch-GContext $PairId
    $from=Get-TraceLineCount
    $stale=Submit-GOperation 'TargetLocalComparison' ([ordered]@{})
    $m=@(Get-SafeErrorsSince $from);$m=if($m.Count){$m[-1]}else{''}
    Add-R8Result 'stale_target_inventory' ([string]$stale.Record.status -ceq 'Failed') $m (Test-NoWritesSince $baseline $SrcData $SrcNeighbor) 'stale or from the future'
    Stop-GConsole
    # source material age: no gate exists in the product, record what the code actually has
    $ageGates=@(Get-ChildItem -LiteralPath (Join-Path $script:ExecRootForR8 'src') -Filter '*.ps1' -File | Select-String -Pattern 'MaximumAgeHours' -SimpleMatch | ForEach-Object {$_.Path.Substring($_.Path.LastIndexOf([char]92)+1)+':'+$_.LineNumber} | Select-Object -Unique)
    $script:R8['source_material_expiry']=[ordered]@{Semantics='The product has no source-material age gate. Source facts are bound by hash (plan, controls inventory, package). The only age gate is the 24 hour Target snapshot freshness (Assert-WsmAssistiveSnapshotFresh), exercised by stale_target_inventory.';AgeGateLocations=$ageGates;SourceInventoryCreatedMinutesBeforeRestore='not aged: no age gate exists to exercise'}
    $traceRows=@(Get-Content -LiteralPath (Join-Path $runDir 'target-trace.jsonl') -Encoding UTF8 | ForEach-Object {$_ | ConvertFrom-Json})
    Set-Check 'r8_no_further_service_apply_or_file_write' ((@($traceRows | Where-Object Kind -ceq 'ServiceApply').Count -eq 1) -and (Test-NoWritesSince $baseline $SrcData $SrcNeighbor)) 'service applied once overall; original data tree unchanged'
    $script:R8['Simulations']=[ordered]@{LaterSoftwareInstall='marker file g-extra-software.marker makes the overlay add one product to the live software observation; HKCU was not touched';TargetInventory='pre-seeded fixture inventories (revisions 1,2,3); not full real captures';ControlsSource='the approved plan carries no GeneralHost software list, so the comparison list can only come from controls/source-inventory.json'}
    $script:Verdict.R8=$script:R8
}

function Invoke-Journey {
    [void][IO.Directory]::CreateDirectory($runDir)
    if([IO.Directory]::Exists($testRoot)){throw 'Refusing to reuse an existing test root.'}
    [void][IO.Directory]::CreateDirectory($testRoot)

    # ---- Stage 1: immutable snapshot, execution copy, host scripts, workspaces ----
    Write-Stage 1 'snapshot, wrapper hashes, execution copy and three workspace paths'
    $hostSource=Join-Path $PSScriptRoot 'G-JourneyHost.ps1';$overrideSource=Join-Path $PSScriptRoot 'G-JourneyOverrides.ps1';$overlaySource=Join-Path $PSScriptRoot 'G-RuntimeOverlay.ps1'
    foreach($required in @($hostSource,$overrideSource,$overlaySource)){if(-not [IO.File]::Exists($required)){throw ('G test script is missing: '+$required)}}
    $snapshotOutput=& (Join-Path $repo 'work\r7\New-StageSnapshot.ps1') -Name ('g-journey-'+$RunId) -AdditionalPaths @('tests/G-JourneyHost.ps1','tests/G-JourneyOverrides.ps1','tests/G-RuntimeOverlay.ps1')
    $snapshotRoot=[IO.Path]::GetFullPath(@($snapshotOutput)[-1])
    if(-not [IO.Directory]::Exists((Join-Path $snapshotRoot 'src')) -or $snapshotRoot.IndexOf($RunId) -lt 0){throw 'Snapshot was not created for this run.'}
    $script:Snapshot=$snapshotRoot
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $snapshotRoot 'src') -Recurse -File -Force){$file.Attributes=$file.Attributes -bor [IO.FileAttributes]::ReadOnly}
    $digestBefore=Get-SrcDigest (Join-Path $snapshotRoot 'src')
    $committed=Get-CommittedSrcDigest
    $script:HostScript=Join-Path $snapshotRoot 'tests\G-JourneyHost.ps1'
    $testBytes=[ordered]@{
        'tests/G-JourneyHost.ps1'=(Get-FileSha256 $script:HostScript)
        'tests/G-JourneyOverrides.ps1'=(Get-FileSha256 (Join-Path $snapshotRoot 'tests\G-JourneyOverrides.ps1'))
        'tests/G-RuntimeOverlay.ps1'=(Get-FileSha256 (Join-Path $snapshotRoot 'tests\G-RuntimeOverlay.ps1'))
        'tests/Test-OfflineRestoreJourney.ps1'=(Get-FileSha256 $PSCommandPath)
    }
    if($testBytes['tests/G-JourneyHost.ps1'] -cne (Get-FileSha256 $hostSource) -or $testBytes['tests/G-RuntimeOverlay.ps1'] -cne (Get-FileSha256 $overlaySource)){throw 'Snapshot wrapper differs from the repository wrapper.'}
    # Execution copy for the Target console only: identical src bytes plus the overlay appended to the psm1.
    $execRoot=Join-Path $testRoot 'exec'
    Copy-Item -LiteralPath (Join-Path $snapshotRoot 'src') -Destination (Join-Path $execRoot 'src') -Recurse
    Copy-Item -LiteralPath (Join-Path $snapshotRoot 'docs') -Destination (Join-Path $execRoot 'docs') -Recurse
    foreach($entryFile in @('Start-ServerMigration.ps1','Start-ServerMigration.cmd')){Copy-Item -LiteralPath (Join-Path $snapshotRoot $entryFile) -Destination (Join-Path $execRoot $entryFile)}
    $execPsm1=Join-Path $execRoot 'src\WindowsServerMigration.psm1'
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $execRoot 'src') -Recurse -File -Force){if($file.Attributes -band [IO.FileAttributes]::ReadOnly){$file.Attributes=$file.Attributes -bxor [IO.FileAttributes]::ReadOnly}}
    $overlayBytes=[IO.File]::ReadAllBytes($overlaySource)
    $separator=[Text.Encoding]::ASCII.GetBytes("`r`n# ---- G journey runtime overlay (test only) ----`r`n")
    $psm1Bytes=[IO.File]::ReadAllBytes($execPsm1)
    $stream=[IO.File]::Open($execPsm1,'Append','Write','None');try{$stream.Write($separator,0,$separator.Length);$stream.Write($overlayBytes,0,$overlayBytes.Length)}finally{$stream.Dispose()}
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $execRoot 'src') -Recurse -File -Force){$file.Attributes=$file.Attributes -bor [IO.FileAttributes]::ReadOnly}
    $snapshotSrcRows=@{};foreach($row in $digestBefore.Rows){$parts=$row.Split('|');$snapshotSrcRows[$parts[0]]=$parts[1]}
    $execDigest=Get-SrcDigest (Join-Path $execRoot 'src');$execDiffers=@()
    foreach($row in $execDigest.Rows){$parts=$row.Split('|');if($snapshotSrcRows[$parts[0]] -cne $parts[1]){$execDiffers+=@($parts[0])}}
    $execPrefixIntact=((Get-BytesSha256 $psm1Bytes) -ceq (Get-BytesSha256 ([IO.File]::ReadAllBytes($execPsm1))[0..($psm1Bytes.Length-1)]))
    $wsSource=Join-Path $testRoot 'ws-source';$wsManager=Join-Path $testRoot 'ws-manager';$wsTarget=Join-Path $testRoot 'ws-target'
    $srcData=Join-Path $testRoot 'src-data';$srcNeighbor=Join-Path $testRoot 'src-neighbor';$media=Join-Path $testRoot 'media'
    $script:ForbiddenRoots=@($wsSource,$wsManager)
    $config=[ordered]@{RunId=$RunId;SnapshotRoot=$snapshotRoot;ExecRoot=$execRoot;TestRoot=$testRoot;RunDir=$runDir;WsSource=$wsSource;WsManager=$wsManager;WsTarget=$wsTarget;SrcData=$srcData;SrcNeighbor=$srcNeighbor;Media=$media;SecretRef=$secretRef;ServiceAccount=$serviceAccount}
    $script:ConfigPath=Join-Path $runDir 'config.json'
    $script:ExecRootForR8=$execRoot
    [IO.File]::WriteAllText($script:ConfigPath,($config|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    $script:Verdict.Snapshot=[ordered]@{Root=$snapshotRoot;SrcDigestBefore=$digestBefore.Digest;SrcFileCount=$digestBefore.Rows.Count;CommittedWorkingTreeDigest=$committed.WorkingTreeDigest;CommittedHeadDigest=$committed.HeadDigest;CommittedFileCount=$committed.FileCount}
    $script:Verdict.ExecutionCopy=[ordered]@{Purpose='Target console only: worker runspaces re-import the module from disk, so overlay must be in the module file';DifferingSrcFiles=$execDiffers;PsmPrefixIdenticalToSnapshot=$execPrefixIntact;OverlaySHA256=$testBytes['tests/G-RuntimeOverlay.ps1']}
    $script:Verdict.TestBytes=$testBytes
    Set-Check 'snapshot_src_equals_committed_bytes' ($digestBefore.Digest -ceq $committed.WorkingTreeDigest) 'working tree digest'
    if($digestBefore.Digest -cne $committed.WorkingTreeDigest){
        Set-Check 'snapshot_src_equals_head_blobs' ($digestBefore.Digest -ceq $committed.HeadDigest) 'line-ending conversion fallback'
    }
    Set-Check 'execution_copy_differs_only_by_appended_psm1_overlay' (($execDiffers.Count -eq 1) -and ($execDiffers[0] -ceq 'WindowsServerMigration.psm1') -and $execPrefixIntact) ($execDiffers -join ',')
    if($StopAfterStage -le 1){return}

    # ---- Stage 2: Target enrollment over HTTP, then the Source side to the independent copy ----
    Write-Stage 2 'Target HTTP enrollment, Source inventory, Manager CV2 approval, one-click backup, independent copy'
    Start-GConsole 'enroll' | Out-Null
    $before=Invoke-GApi 'GET' ('/api/wizard?'+(Get-GWizardQuery ''))
    $enrolledNow=Invoke-GApi 'POST' '/api/wizard' ([ordered]@{operation='chooseIntent';role='Target';expectedWizardRevision=0;contextId=[string]$script:ConsoleInfo.ContextId}) -Retry
    if($enrolledNow.Status -ne 200){
        # A lost response followed by the replay-safe retry can only meet a changed context once the enrollment already exists.
        $savedProfile=Join-Path $wsTarget 'workspace-control\output-profile.json'
        if(-not ($enrolledNow.Status -eq 409 -and $script:HttpRetries -gt 0 -and [IO.File]::Exists($savedProfile))){throw ('HTTP Target enrollment failed: '+$enrolledNow.Status+' '+$enrolledNow.Text)}
    }
    Update-GSession | Out-Null
    $profile=Get-Content -LiteralPath (Join-Path $wsTarget 'workspace-control\output-profile.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $identityPath=Join-Path (Join-Path $wsTarget ('targets\'+[string]$profile.HostId)) 'target-identity.json'
    if(-not [IO.File]::Exists($identityPath)){throw 'HTTP enrollment did not produce the target identity file.'}
    $targetEnroll=[pscustomobject]@{HostId=[string]$profile.HostId;Fingerprint=[string]$profile.Fingerprint;IdentityPath=$identityPath;IdentityHash=(Get-FileSha256 $identityPath)}
    [IO.File]::WriteAllText((Join-Path $runDir 'phase-target-enroll.json'),($targetEnroll|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
    Stop-GConsole
    Set-Check 'target_enrolled_over_http' (([string]$profile.Role -ceq 'Target') -and ([string]$profile.Fingerprint -match '^[a-f0-9]{64}$')) ([string]$profile.Role)
    $sourceInventory=Invoke-GPhase 'SourceInventory'
    $managerApprove=Invoke-GPhase 'ManagerApprove'
    $sourceBackup=Invoke-GPhase 'SourceBackup'
    $script:Verdict.Source=[ordered]@{PairId=[string]$managerApprove.PairId;PlanHash=[string]$managerApprove.PlanHash;BackupStatus=[string]$sourceBackup.BackupStatus;MediaClass=[string]$sourceBackup.MediaClass;OfflineReadiness=[string]$sourceBackup.OfflineReadiness;CopyRoot=[string]$sourceBackup.CopyRoot}
    Set-Check 'backup_delivered_directory' (([string]$sourceBackup.BackupStatus -ceq 'Delivered') -and ([string]$sourceBackup.DeliveryMode -ceq 'Directory')) ([string]$sourceBackup.BackupStatus)
    Set-Check 'independent_copy_removable_verified' (([string]$sourceBackup.MediaClass -ceq 'Removable') -and ([string]$sourceBackup.OfflineReadiness -ceq 'Verified')) ([string]$sourceBackup.MediaClass)
    Set-Check 'plan_includes_file_scope_and_service_only' (@($managerApprove.IncludedItemIds).Count -eq 2 -and (@($managerApprove.IncludedItemIds) -contains [string]$managerApprove.SelectedItemId) -and (@($managerApprove.IncludedItemIds) -contains [string]$managerApprove.ServiceItemId) -and -not (@($managerApprove.IncludedItemIds) -contains [string]$managerApprove.NeighborItemId))
    $attachment=[string]$managerApprove.PlanPath+'.source-snapshot.json'
    $seededSnapshot=Join-Path $wsSource ('pairs\assistive\snapshots\'+([string]$sourceInventory.InventoryHash)+'.json')
    Set-Check 'source_snapshot_attachment_imported' ([IO.File]::Exists($attachment) -and [IO.File]::Exists($seededSnapshot) -and ((Get-FileSha256 $attachment) -ceq (Get-FileSha256 $seededSnapshot))) 'plan attachment delivered beside the plan and placed in Source pairs'
    if($StopAfterStage -le 2){return}

    # ---- Stage 3: cut off the Source and Manager --------------------------------
    Write-Stage 3 'deny Source/Manager workspaces and move the original data aside'
    Add-DenyAcl $wsSource
    Add-DenyAcl $wsManager
    $movedData=$srcData+'.moved-away';$movedNeighbor=$srcNeighbor+'.moved-away'
    [IO.Directory]::Move($srcData,$movedData);[IO.Directory]::Move($srcNeighbor,$movedNeighbor)
    Set-Check 'source_workspace_denied' (Test-PathAccessDenied $wsSource)
    Set-Check 'manager_workspace_denied' (Test-PathAccessDenied $wsManager)
    Set-Check 'original_paths_free_for_restore' (-not [IO.Directory]::Exists($srcData) -and -not [IO.Directory]::Exists($srcNeighbor))
    if($StopAfterStage -le 3){return}

    # ---- Stage 4: Target console over HTTP up to WaitingForInput ------------------
    Write-Stage 4 'Target console: enrollment check, plan, package from media, inventory, local comparison, receipt, preview, restore'
    $script:TargetInventoryPath=Join-Path (Join-Path (Join-Path $wsTarget ('hosts'+[char]92+[string]$targetEnroll.Fingerprint)) 'inventory') 'inventory-1.json'
    $seed=Invoke-GPhase 'TargetSeedInventory' -Overlay
    $script:Verdict.TargetInventory=[ordered]@{Fixture='PreSeededTargetInventory (not a full real capture)';Path=[string]$seed.InventoryPath;SHA256=[string]$seed.InventoryHash}
    Start-GConsole 'main' | Out-Null
    $pairId=[string]$managerApprove.PairId
    $wizard=Invoke-GApi 'GET' ('/api/wizard?'+(Get-GWizardQuery ''))
    Write-Host ('  wizard projection keys: '+(($wizard.Data.PSObject.Properties.Name) -join ','))
    $defaults=Get-GActionDefaults 'ImportApprovedPlan' ''
    $import=Submit-GOperation 'ImportApprovedPlan' ([ordered]@{Path=[string]$managerApprove.PlanPath;ExpectedHash=[string]$managerApprove.PlanHash})
    Write-Host ('  ImportApprovedPlan: '+[string]$import.Record.status)
    if([string]$import.Record.status -cne 'Succeeded'){throw ('ImportApprovedPlan did not succeed: '+(ConvertTo-Json -InputObject $import.Record -Depth 6 -Compress))}
    Switch-GContext $pairId
    $runtime=Get-GRuntime $pairId
    Write-Host ('  runtime actions: '+((@($runtime.actions) | ForEach-Object {[string]$_.id+'='+[string]$_.available}) -join ', '))
    function Show-GActions([string]$Label){
        $runtime=Get-GRuntime $pairId
        Write-Host ('  actions after '+$Label+': '+((@($runtime.actions) | ForEach-Object {[string]$_.id+'='+[string]$_.available+$(if(-not $_.available){'('+[string]$_.reason+')'}else{''})}) -join ', '))
        $runtime
    }
    $directory=Submit-GRuntimeAction 'TargetDirectoryImport' ([ordered]@{SummaryPath=[string]$sourceBackup.CopySummaryPath;ExpectedSummaryHash=[string]$sourceBackup.CopySummaryHash;SourceDirectory=[string]$sourceBackup.CopyDeliveryDirectory}) $pairId
    Write-Host ('  TargetDirectoryImport: '+[string]$directory.Record.status)
    if([string]$directory.Record.status -cne 'Succeeded'){throw ('TargetDirectoryImport did not succeed: '+(ConvertTo-Json -InputObject $directory.Record -Depth 6 -Compress))}
    $runtime=Show-GActions 'package import'
    $runtime=Show-GActions 'seeded inventory binding'
    $comparison=Submit-GRuntimeAction 'TargetLocalComparison' ([ordered]@{}) $pairId
    Write-Host ('  TargetLocalComparison: '+[string]$comparison.Record.status)
    if([string]$comparison.Record.status -cne 'Succeeded'){throw ('TargetLocalComparison did not succeed: '+(ConvertTo-Json -InputObject $comparison.Record -Depth 6 -Compress))}
    $runtime=Show-GActions 'local comparison'
    Write-Host ('  runtime keys: '+(($runtime.PSObject.Properties.Name) -join ','))
    Write-Host ('  runtime.runtime keys: '+$(if($runtime.runtime){($runtime.runtime.PSObject.Properties.Name) -join ','}else{'(null)'}))
    $options=@($runtime.runtime.itemOptions)
    $defaultSelection=@($options | Where-Object {$_.restorable -eq $true -and -not $_.restored} | ForEach-Object {[string]$_.value})
    $script:DefaultSelection=$defaultSelection
    Set-Check 'itemoptions_default_selects_all_approved_items' ($defaultSelection.Count -eq 2 -and ($defaultSelection -contains [string]$managerApprove.SelectedItemId) -and ($defaultSelection -contains [string]$managerApprove.ServiceItemId)) ($defaultSelection.Count.ToString()+' selected')
    $receipt=Submit-GRuntimeAction 'CreateTargetDecisionReceipt' ([ordered]@{Decision='RestoreNow';Owner='G journey owner';Reason='Reviewed the local comparison and the default selection';SelectedItemIds=[string[]]$defaultSelection}) $pairId
    if([string]$receipt.Record.status -cne 'Succeeded'){throw ('Receipt failed: '+(ConvertTo-Json -InputObject $receipt.Record -Depth 6 -Compress))}
    $preview=Submit-GRuntimeAction 'TargetRestorePreview' ([ordered]@{}) $pairId
    if([string]$preview.Record.status -cne 'Succeeded'){throw ('Preview failed: '+(ConvertTo-Json -InputObject $preview.Record -Depth 6 -Compress))}
    $runtime=Get-GRuntime $pairId
    $previewHash=[string]$runtime.runtime.restorePreview.PreviewHash
    if($previewHash -notmatch '^[a-f0-9]{64}$'){throw ('No preview hash in the runtime projection: '+(ConvertTo-Json -InputObject $runtime.runtime.restorePreview -Depth 4 -Compress))}
    Set-Check 'preview_has_no_blockers' (-not [bool]$runtime.runtime.restorePreview.Blocked) ('PreviewHash '+$previewHash.Substring(0,12))
    $script:JournalMarkBefore=0
    $restore=Submit-GRuntimeAction 'TargetRestore' ([ordered]@{PreviewHash=$previewHash}) $pairId
    $parentJob=$restore.Record
    $script:ParentJobId=[string]$parentJob.jobId
    Set-Check 'target_restore_waiting_for_input' (([string]$parentJob.status -ceq 'WaitingForInput') -and ([string]$parentJob.outputs[0].Status -ceq 'WaitingForInput')) ([string]$parentJob.status)
    $requirements=@($parentJob.credentialRequirements)
    Set-Check 'credential_requirement_is_approved_account' ($requirements.Count -eq 1 -and ([string]$requirements[0].ApprovedAccount -ceq $serviceAccount) -and ([string]$requirements[0].SecretRef -ceq $secretRef)) (($requirements | ForEach-Object {[string]$_.ApprovedAccount}) -join ',')
    $script:Verdict.Target=[ordered]@{ParentJobId=$script:ParentJobId;PreviewHash=$previewHash}
    if($StopAfterStage -le 4){return}

    # ---- Stage 5: credentials and a hard process death --------------------------
    Write-Stage 5 'send credentials over HTTP; the console process dies after the second file is written'
    $body=[ordered]@{credentials=[ordered]@{$secretRef=[ordered]@{username=$serviceAccount;password=$script:ServicePassword}}}
    $crashedProcess=$script:ConsoleInfo.Process
    try{$credentialResponse=Invoke-GApi 'POST' ('/api/jobs/'+$script:ParentJobId+'/service-credentials') $body -NoLog}catch{$credentialResponse=$null}
    $body=$null
    if(-not $crashedProcess.WaitForExit(180000)){throw 'The Target console did not die at the injected crash point.'}
    $script:Pids.Remove($crashedProcess.Id) | Out-Null
    $markerPath=Join-Path $runDir 'crash-marker.json'
    $marker=if([IO.File]::Exists($markerPath)){Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json}else{$null}
    $script:Verdict.Crash=[ordered]@{ExitCode=$crashedProcess.ExitCode;Marker=$marker}
    Set-Check 'console_process_died_137' ($crashedProcess.ExitCode -eq 137)
    Set-Check 'crash_point_file_was_written_before_completed_journal' ($marker -and [bool]$marker.TargetExists -and ([string]$marker.TargetSHA256 -ceq [string]$marker.ExpectedSHA256)) ([string]$marker.Target)
    $script:ConsoleInfo=$null
    $traceRows=@(Get-Content -LiteralPath (Join-Path $runDir 'target-trace.jsonl') -Encoding UTF8 | ForEach-Object {$_ | ConvertFrom-Json})
    $script:ServiceAppliedBeforeCrash=@($traceRows | Where-Object Kind -ceq 'ServiceApply').Count
    $script:FilesCompletedBeforeCrash=@($traceRows | Where-Object {$_.Kind -ceq 'Journal' -and $_.Data.Action -ceq 'AssistiveFileCompleted'}).Count
    Set-Check 'a_file_was_completed_before_the_crash_point_file' (($script:FilesCompletedBeforeCrash - 1) -ge 1) ('completed journal rows before the crash, excluding the crash point: '+($script:FilesCompletedBeforeCrash-1))
    if($StopAfterStage -le 5){return}

    # ---- Stage 6: new process, same workspace, explicit resume -------------------
    Write-Stage 6 'restart the console, check Interrupted/resumable, resume-preview, resume'
    Start-GConsole 'resume' | Out-Null
    Switch-GContext $pairId
    $jobsNow=Invoke-GApi 'GET' '/api/jobs'
    $interrupted=@($jobsNow.Data.items | Where-Object {[string]$_.jobId -ceq $script:ParentJobId})
    Set-Check 'parent_interrupted_and_resumable_after_restart' ($interrupted.Count -eq 1 -and [string]$interrupted[0].status -ceq 'Interrupted' -and $interrupted[0].resumable -eq $true) $(if($interrupted.Count){[string]$interrupted[0].status}else{'missing'})
    $beforeMap=Get-TreeHashMap $wsTarget
    $resumePreview=Invoke-GApi 'GET' ('/api/jobs/'+$script:ParentJobId+'/resume-preview')
    $afterMap=Get-TreeHashMap $wsTarget
    $changedByPreview=@(Compare-HashMaps $beforeMap $afterMap)
    Set-Check 'resume_preview_is_read_only' ($resumePreview.Status -eq 200 -and $resumePreview.Data.resumable -eq $true -and $changedByPreview.Count -eq 0) ($changedByPreview -join ',')
    $continuationId=[Guid]::NewGuid().ToString('D')
    $resumeBody=[ordered]@{continuationId=$continuationId;confirm=$true}
    if($MutationResumeAsNewRestore){
        $mutated=Submit-GOperation 'TargetRestore' ([ordered]@{PreviewHash=$previewHash})
        $finalJob=$mutated.Record
    }else{
        $resume=Invoke-GApi 'POST' ('/api/jobs/'+$script:ParentJobId+'/resume') $resumeBody -Retry
        if($resume.Status -notin @(200,202)){throw ('Resume was rejected: '+$resume.Status+' '+$resume.Text)}
        $finalJob=Wait-GJob $script:ParentJobId @('Succeeded','Failed','Cancelled','Interrupted','ReviewRequired','WaitingForInput','Partial')
        $script:Verdict.Resume=[ordered]@{ContinuationId=$continuationId;FirstStatus=[string]$finalJob.status}
        if([string]$finalJob.status -ceq 'WaitingForInput'){
            $requirements2=@($finalJob.credentialRequirements)
            $body=[ordered]@{credentials=[ordered]@{$secretRef=[ordered]@{username=$serviceAccount;password=$script:ServicePassword}}}
            $reply=$null;try{$reply=Invoke-GApi 'POST' ('/api/jobs/'+$script:ParentJobId+'/service-credentials') $body -NoLog}catch{}
            if($reply -and $reply.Status -notin @(200,202)){throw ('Credential reply after resume was rejected: '+$reply.Status+' '+$reply.Text)}
            $body=$null
            $finalJob=Wait-GJob $script:ParentJobId @('Succeeded','Failed','Cancelled','Interrupted','ReviewRequired','Partial')
        }
    }
    $script:FinalJob=$finalJob
    $script:Verdict.Resume=[ordered]@{ContinuationId=$continuationId;FinalStatus=[string]$finalJob.status;FinalJobId=[string]$finalJob.jobId}
    Update-GSession | Out-Null
    $script:Verdict.HttpRetries=$script:HttpRetries
    if($StopAfterStage -le 6){return}

    # ---- Stage 7: verdict ------------------------------------------------------
    Write-Stage 7 'judge bytes, journal, Service double, access counters, secret canary, product flags'
    $script:RuntimeFinal=Get-GRuntime $pairId
    $script:DenyWasActiveDuringTarget=(Test-PathAccessDenied $wsSource) -and (Test-PathAccessDenied $wsManager)
    Stop-GConsole
    Restore-DenyAcls
    Invoke-R8 $managerApprove $targetEnroll $sourceInventory $pairId $srcData $srcNeighbor $wsTarget $script:DefaultSelection
    Invoke-Judgement $sourceInventory $managerApprove $pairId $movedData $srcData $srcNeighbor $wsTarget $snapshotRoot $execRoot $digestBefore
}

try{
    Invoke-Journey
}
catch{
    $script:Verdict.Error=[string]$_.Exception.Message
    $script:Verdict.ErrorPosition=[string]$_.InvocationInfo.PositionMessage
    Write-Host ('FAILED: '+$_.Exception.Message)
    $script:Failed=$true
}
finally{
    # Deny entries must always come off before anything else touches those paths.
    foreach($path in @($script:DeniedPaths)){try{Remove-DenyAcl $path}catch{Write-Host ('Could not remove deny from '+$path)}}
    foreach($processId in @($script:Pids)){
        try{$running=Get-Process -Id $processId -ErrorAction SilentlyContinue;if($running){$running.Kill()}}catch{}
    }
    $allPassed=$true;foreach($key in $script:Verdict.Checks.Keys){if(-not $script:Verdict.Checks[$key].Passed){$allPassed=$false}}
    $script:Verdict.Overall=if(-not $script:Failed -and $allPassed -and $StopAfterStage -ge 7){'Passed'}elseif(-not $script:Failed -and $allPassed){'PartialRun'}else{'Failed'}
    $script:Verdict.HttpRetries=$script:HttpRetries
    $script:Verdict.CompletedUtc=[DateTime]::UtcNow.ToString('o')
    if([IO.Directory]::Exists($runDir)){[IO.File]::WriteAllText((Join-Path $runDir 'verdict.json'),($script:Verdict|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))}
    if(-not $KeepArtifacts){
        foreach($path in @($testRoot,$script:Snapshot)){
            if($path -and [IO.Directory]::Exists($path)){
                try{
                    if($path -eq $testRoot){Assert-OwnedPath $path}elseif($path.IndexOf($RunId) -lt 0){throw 'Snapshot path does not carry this run id.'}
                    foreach($file in Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue){if($file.Attributes -band [IO.FileAttributes]::ReadOnly){$file.Attributes=$file.Attributes -bxor [IO.FileAttributes]::ReadOnly}}
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                }catch{Write-Host ('Cleanup left '+$path+': '+$_.Exception.Message)}
            }
        }
    }
}
Write-Host ('Overall: '+$script:Verdict.Overall+' (verdict: '+(Join-Path $runDir 'verdict.json')+')')
if($script:Verdict.Overall -ceq 'Passed'){Write-Host ('PASS: offline restore journey (run '+$RunId+', '+$script:Verdict.Checks.Count+' checks, http retries '+$script:HttpRetries+')')}
if($script:Verdict.Overall -ceq 'Failed'){exit 1}
