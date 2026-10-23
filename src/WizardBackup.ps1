function Get-WsmWizardBackupRoot([string]$Workspace,[string]$PairId) {
    Assert-WsmId $PairId
    $root=Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-backups') $PairId
    [void](New-WsmOutputOwnedDirectory $root)
    $root
}

function Get-WsmWizardBackupDirectoryMemberNames($Plan) {
    $names=@('manifest.json','plan.json','artifacts.jsonl','freeze.json')
    foreach($item in @($Plan.Items)){
        if($item.Decision -cne 'Include' -or -not $item.MigrationSpec){continue}
        $spec=$item.MigrationSpec
        if($spec.Adapter -ceq 'Certificate' -or ($spec.Adapter -ceq 'FileScope' -and (-not $spec.PSObject.Properties['TransferChannel'] -or $spec.TransferChannel -ceq 'C'))){$names+=('payload/'+('f'*64)+'.blob');break}
    }
    $names
}

function Assert-WsmWizardBackupAttempt($Attempt,[string]$Workspace,[string]$PairId,$Profile) {
    Assert-WsmEnvelope $Attempt 'WizardBackupAttempt'
    if($Attempt.SchemaVersion -ne 1 -or $Attempt.ToolVersion -cne $script:ToolVersion -or $Attempt.PairId -cne $PairId -or $Attempt.ProfileId -cne [string]$Profile.ProfileId -or $Attempt.HostId -cne [string]$Profile.HostId -or [IO.Path]::GetFullPath([string]$Attempt.Workspace) -ine [IO.Path]::GetFullPath($Workspace)){throw 'Backup attempt belongs to another workspace, host, pair or tool version.'}
    foreach($field in @('AttemptId','StartedByOperationId')){Assert-WsmId ([string]$Attempt.$field)}
    if($Attempt.PSObject.Properties['OperationIds']){$seen=@{};foreach($operationId in @($Attempt.OperationIds)){Assert-WsmId ([string]$operationId);if($seen.ContainsKey([string]$operationId)){throw 'Backup attempt repeats an operation identity.'};$seen[[string]$operationId]=$true};if(-not $seen.ContainsKey([string]$Attempt.StartedByOperationId)){throw 'Backup attempt operation history lost its original operation identity.'};if($Attempt.PSObject.Properties['LastOperationId'] -and -not $seen.ContainsKey([string]$Attempt.LastOperationId)){throw 'Backup attempt last operation identity is not in its operation history.'}}
    if([string]$Attempt.PlanHash -notmatch '^[a-f0-9]{64}$' -or [string]$Attempt.InventoryHash -notmatch '^[a-f0-9]{64}$' -or [int]$Attempt.InventoryRevision -lt 0){throw 'Backup attempt lacks a valid sealed-plan and inventory binding.'}
    if([string]$Attempt.Stage -cnotin @('Authorized','CoreExported','PackageVerified','Delivered','ReviewRequired','Failed','Cancelled')){throw 'Backup attempt has an unknown durable stage.'}
    if($Attempt.PSObject.Properties['DeliveryMode']){if([string]$Attempt.DeliveryMode -cnotin @('Directory','Zip')){throw 'Backup attempt has an unknown delivery mode.'};if(-not $Attempt.PSObject.Properties['VolumeBytes'] -or [long]$Attempt.VolumeBytes -lt 0){throw 'Backup attempt has an invalid delivery volume limit.'};Assert-WsmOutputProfileValues ([pscustomobject]@{Mode=[string]$Attempt.DeliveryMode;VolumeBytes=[long]$Attempt.VolumeBytes})}
    foreach($field in @('CoreExport','PackageTest','Delivery','ChannelSummary')){if(-not $Attempt.PSObject.Properties[$field]){throw 'Backup attempt is missing a stage result.'}}
    $true
}

function Write-WsmWizardBackupAttempt([string]$Path,$Attempt,[string]$Workspace) {
    Invoke-WsmLocked $Workspace {
        if([IO.File]::Exists($Path)){Assert-WsmNoReparse $Path;$current=Read-WsmJson $Path;if([string]$current.AttemptId -cne [string]$Attempt.AttemptId -or [string]$current.PlanHash -ine [string]$Attempt.PlanHash){throw 'Backup attempt identity changed while saving progress.'}}
        Write-WsmJson $Path $Attempt
    }
}

# F1-P producer: the running one-click backup publishes a bounded progress record.
# Progress is a read-only projection of the running operation, not a state transition:
#   * it is never written to the journal and never changes an attempt record;
#   * it lives at <wizard-backups>\<PairId>\progress\<OperationId>.json (the attempt scan only reads *.json
#     directly under the pair root, so this sub-directory is invisible to attempt recovery);
#   * every write is an atomic Write-WsmJson replace, at most one per interval (default 1000 ms) except forced
#     writes at stage changes and at the end, so a flood of small files cannot inflate disk or fsync traffic;
#   * the record is capped at 4 KiB; Recent keeps the newest 20 completed items (FIFO) with only ItemId and Result;
#   * unknown totals are stored as null (never 0) so the UI can say "unknown".
#   * N2: the current item is published as independent fields (CurrentItemId, CurrentItemType = adapter code,
#     CurrentItemTypeLabel from Get-WsmWizardItemTypeLabel, CurrentChannel = C | NonC | Unknown) plus the file sequence
#     (FilesDone = files the exporter already finished, FilesTotal = null until the package is sealed). The channel is
#     derived from the approved item spec, not parsed from display text. When a record would pass 4 KiB the stored item
#     names shrink first (the UI falls back to the ItemId), never the new fields; Recent rows are the last resort.
# Stage codes follow the real sub-stages of Invoke-WsmWizardStartBackup: Capture (source freeze + core export, which
# also seals the package), Verify (Test-WsmMigrationPackage), Deliver (enrolled delivery + item results + report).
function Get-WsmWizardBackupProgressStageCodes { @('Capture','Verify','Deliver') }

function Get-WsmWizardBackupProgressPath([string]$Workspace,[string]$PairId,[string]$OperationId) {
    Assert-WsmId $PairId;Assert-WsmId $OperationId
    Join-Path (Join-Path (Join-Path (Join-Path (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'workspace-control') 'wizard-backups') $PairId) 'progress') ($OperationId+'.json')
}

function Get-WsmWizardBackupProgressRelativePath([string]$Root,[string]$Path) {
    if([string]::IsNullOrEmpty($Path)){return ''}
    if($Root){
        $prefix=$Root.TrimEnd('\','/')+'\'
        if($Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return $Path.Substring($prefix.Length)}
    }
    [IO.Path]::GetFileName($Path)
}

function New-WsmWizardBackupProgress([string]$Workspace,[string]$PairId,[string]$OperationId,[string]$AttemptId,[object[]]$ProgressItems=@(),$ItemsTotal=$null) {
    $interval=1000
    if(Get-Variable -Name WsmWizardBackupProgressIntervalMs -Scope Script -ErrorAction SilentlyContinue){$interval=[int]$script:WsmWizardBackupProgressIntervalMs}
    $ids=New-Object 'System.Collections.Generic.List[string]';$names=New-Object 'System.Collections.Generic.List[string]';$roots=New-Object 'System.Collections.Generic.List[string]'
    $types=New-Object 'System.Collections.Generic.List[string]';$typeLabels=New-Object 'System.Collections.Generic.List[string]';$channels=New-Object 'System.Collections.Generic.List[string]'
    foreach($progressItem in @($ProgressItems)){
        $ids.Add([string]$progressItem.ItemId)
        $name=if($progressItem.PSObject.Properties['NaturalKey'] -and [string]$progressItem.NaturalKey){[string]$progressItem.NaturalKey}else{[string]$progressItem.Kind}
        $names.Add((ConvertTo-WsmProgressText $name))
        $root='';if($progressItem.MigrationSpec -and $progressItem.MigrationSpec.PSObject.Properties['SourcePath'] -and $progressItem.MigrationSpec.Adapter -ceq 'FileScope'){$root=[string]$progressItem.MigrationSpec.SourcePath}
        $roots.Add($root)
        $adapter='';if($progressItem.MigrationSpec -and $progressItem.MigrationSpec.PSObject.Properties['Adapter']){$adapter=[string]$progressItem.MigrationSpec.Adapter}
        $types.Add((ConvertTo-WsmProgressText $adapter))
        $typeLabel=$adapter;if(Get-Command Get-WsmWizardItemTypeLabel -CommandType Function -ErrorAction SilentlyContinue){$typeLabel=Get-WsmWizardItemTypeLabel $adapter ([string]$progressItem.Kind)}
        $typeLabels.Add((ConvertTo-WsmProgressText $typeLabel))
        $channel='Unknown'
        if($adapter -ceq 'FileScope'){
            $transfer='C';if($progressItem.MigrationSpec.PSObject.Properties['TransferChannel']){$transfer=[string]$progressItem.MigrationSpec.TransferChannel}
            if($transfer -ceq 'NonC'){$channel='NonC'}elseif($transfer -ceq 'C'){$channel='C'}
        }
        $channels.Add($channel)
    }
    $total=$null;if($null -ne $ItemsTotal){$total=[int]$ItemsTotal}elseif($ids.Count){$total=$ids.Count}
    @{
        Path=(Get-WsmWizardBackupProgressPath $Workspace $PairId $OperationId);IntervalMs=$interval;LastWriteTicks=[long]0;Writes=0;LastError=''
        Ids=$ids;Names=$names;Roots=$roots;Types=$types;TypeLabels=$typeLabels;Channels=$channels;CurrentIndex=0;DoneCount=0;NameMap=@{}
        Record=[ordered]@{SchemaVersion=1;Kind='WizardBackupProgress';PairId=$PairId;OperationId=$OperationId;AttemptId=$AttemptId;Stage='Capture';StageIndex=1;StageCount=(Get-WsmWizardBackupProgressStageCodes).Count;Workload='';CurrentFile='';CurrentItemId='';CurrentItemType='';CurrentItemTypeLabel='';CurrentChannel='Unknown';FilesDone=[long]0;FilesTotal=$null;ItemsDone=0;ItemsTotal=$total;BytesDone=[long]0;BytesTotal=$null;FailedCount=0;Terminal=$false;Outcome='';StartedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc);Recent=@();ItemNames=[ordered]@{}}
    }
}

# Atomic replace of the compact progress JSON (temporary file in the same directory, flush to disk, replace/move),
# the same pattern as Write-WsmJson but without its indentation so the 4 KiB bound holds 20 recent rows.
function Write-WsmWizardBackupProgressFile([string]$Path,[string]$Json) {
    $directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory)}
    $temporary=Join-Path $directory ([Guid]::NewGuid().ToString('N')+'.tmp')
    try{
        $stream=[IO.File]::Open($temporary,'CreateNew','Write','None');try{$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($Json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if([IO.File]::Exists($Path)){$backup=Join-Path $directory ([Guid]::NewGuid().ToString('N')+'.bak');[IO.File]::Replace($temporary,$Path,$backup);[IO.File]::Delete($backup)}
        else{[IO.File]::Move($temporary,$Path)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function ConvertTo-WsmWizardBackupProgressJson($Progress,$Recent,[int]$NameCap=256) {
    $record=$Progress.Record;$record.Recent=@($Recent);$names=[ordered]@{}
    foreach($entry in @($Recent)){if($NameCap -gt 0 -and $Progress.NameMap.ContainsKey([string]$entry.ItemId)){$name=[string]$Progress.NameMap[[string]$entry.ItemId];if($name.Length -gt $NameCap){$name=$name.Substring(0,$NameCap)};$names[[string]$entry.ItemId]=$name}}
    $record.ItemNames=$names
    $record|ConvertTo-Json -Depth 6 -Compress
}

function Write-WsmWizardBackupProgressRecord($Progress,[switch]$Force) {
    if(-not $Progress){return $false}
    try{
        $nowTicks=[DateTime]::UtcNow.Ticks
        if(-not $Force -and $Progress.LastWriteTicks -gt 0 -and (($nowTicks-$Progress.LastWriteTicks)/10000) -lt $Progress.IntervalMs){return $false}
        $record=$Progress.Record;$record.UpdatedUtc=Get-WsmUtc
        $recent=@($record.Recent);$json=ConvertTo-WsmWizardBackupProgressJson $Progress $recent
        # Fixed upper bound: shorten free text first, then drop the oldest recent rows until the record fits.
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 4096){
            $record.CurrentFile=[string]$record.CurrentFile;if($record.CurrentFile.Length -gt 80){$record.CurrentFile='…'+$record.CurrentFile.Substring($record.CurrentFile.Length-79)}
            if(([string]$record.Workload).Length -gt 80){$record.Workload=([string]$record.Workload).Substring(0,80)}
            $json=ConvertTo-WsmWizardBackupProgressJson $Progress $recent
        }
        # Keep all 20 Recent rows: shrink the remembered display names first (the UI falls back to the ItemId), then the
        # free text, and only as the very last resort drop the oldest rows. The new item/channel/file fields are never cut.
        foreach($nameCap in 40,24,12,0){
            if([Text.Encoding]::UTF8.GetByteCount($json) -le 4096){break}
            $json=ConvertTo-WsmWizardBackupProgressJson $Progress $recent $nameCap
        }
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 4096){
            if($record.CurrentFile.Length -gt 32){$record.CurrentFile='…'+$record.CurrentFile.Substring($record.CurrentFile.Length-31)}
            if(([string]$record.Workload).Length -gt 32){$record.Workload=([string]$record.Workload).Substring(0,32)}
            $json=ConvertTo-WsmWizardBackupProgressJson $Progress $recent 0
        }
        while([Text.Encoding]::UTF8.GetByteCount($json) -gt 4096 -and $recent.Count -gt 0){
            $recent=@($recent|Select-Object -Skip 1);$json=ConvertTo-WsmWizardBackupProgressJson $Progress $recent 0
        }
        Write-WsmWizardBackupProgressFile $Progress.Path $json
        $Progress.LastWriteTicks=$nowTicks;$Progress.Writes=[int]$Progress.Writes+1
        $true
    }catch{$Progress.LastError=[string]$_.Exception.Message;$false}
}

function Add-WsmWizardBackupProgressRecent($Progress,[string]$ItemId,[string]$Result) {
    $record=$Progress.Record
    $entries=New-Object 'System.Collections.Generic.List[object]'
    foreach($entry in @($record.Recent)){$entries.Add($entry)}
    $entries.Add([pscustomobject][ordered]@{ItemId=$ItemId;Result=$Result})
    # FIFO: the newest 20 stay, the oldest fall off.
    while($entries.Count -gt 20){$entries.RemoveAt(0)}
    $record.Recent=@($entries.ToArray())
    if($Result -ceq 'Failed'){$record.FailedCount=[int]$record.FailedCount+1}
}

# Mark items 1..UpTo as completed (in order). Each completion is one Recent row; the item name is remembered so the
# UI can show it next to the stored ItemId.
function Complete-WsmWizardBackupProgressItems($Progress,[int]$UpTo) {
    $record=$Progress.Record
    for($index=[int]$Progress.DoneCount+1;$index -le $UpTo;$index++){
        if($index -le $Progress.Ids.Count){$id=$Progress.Ids[$index-1];$Progress.NameMap[$id]=$Progress.Names[$index-1];Add-WsmWizardBackupProgressRecent $Progress $id 'Succeeded'}
    }
    if($UpTo -gt [int]$Progress.DoneCount){$Progress.DoneCount=$UpTo}
    $record.ItemsDone=[int]$Progress.DoneCount
}

# Called for every file the core export starts. ItemIndex is 1-based and identifies the item in the same ordered
# list the exporter uses, so a new index means every earlier item has completed.
function Update-WsmWizardBackupProgressItem($Progress,[int]$ItemIndex,[int]$ItemCount,[string]$ItemName,[string]$FilePath,[long]$BytesDone,[long]$FilesDone=0) {
    if(-not $Progress){return}
    try{
        $record=$Progress.Record
        if($ItemIndex -gt 1){Complete-WsmWizardBackupProgressItems $Progress ($ItemIndex-1)}
        $Progress.CurrentIndex=$ItemIndex
        if($null -eq $record.ItemsTotal -and $ItemCount -gt 0){$record.ItemsTotal=$ItemCount}
        $record.Workload=ConvertTo-WsmProgressText $ItemName
        $root='';if($ItemIndex -ge 1 -and $ItemIndex -le $Progress.Roots.Count){$root=$Progress.Roots[$ItemIndex-1]}
        $record.CurrentFile=ConvertTo-WsmProgressText (Get-WsmWizardBackupProgressRelativePath $root $FilePath)
        $record.BytesDone=[Math]::Max([long]0,$BytesDone)
        $itemId='';$itemType='';$itemTypeLabel='';$channel='Unknown'
        if($ItemIndex -ge 1 -and $ItemIndex -le $Progress.Ids.Count){$itemId=[string]$Progress.Ids[$ItemIndex-1];$itemType=[string]$Progress.Types[$ItemIndex-1];$itemTypeLabel=[string]$Progress.TypeLabels[$ItemIndex-1];$channel=[string]$Progress.Channels[$ItemIndex-1]}
        $record.CurrentItemId=$itemId;$record.CurrentItemType=$itemType;$record.CurrentItemTypeLabel=$itemTypeLabel;$record.CurrentChannel=$channel
        $record.FilesDone=[Math]::Max([long]0,$FilesDone)
        [void](Write-WsmWizardBackupProgressRecord $Progress)
    }catch{$Progress.LastError=[string]$_.Exception.Message}
}

# Enter a sub-stage. Stage changes are always written. Leaving Capture means every item has completed.
function Set-WsmWizardBackupProgressStage($Progress,[string]$Stage,[long]$Bytes=-1,[long]$Files=-1) {
    if(-not $Progress){return}
    try{
        $codes=@(Get-WsmWizardBackupProgressStageCodes);$index=[Array]::IndexOf($codes,$Stage)
        if($index -lt 0){throw 'Unknown backup progress stage.'}
        $record=$Progress.Record
        if($index -ge 1){
            $all=$Progress.Ids.Count;if($null -ne $record.ItemsTotal){$all=[Math]::Max($all,[int]$record.ItemsTotal)}
            Complete-WsmWizardBackupProgressItems $Progress $all
            $record.Workload='';$record.CurrentFile='';$record.CurrentItemId='';$record.CurrentItemType='';$record.CurrentItemTypeLabel='';$record.CurrentChannel='Unknown'
        }
        $record.Stage=$Stage;$record.StageIndex=$index+1
        if($Bytes -ge 0){$record.BytesDone=$Bytes;$record.BytesTotal=$Bytes}
        if($Files -ge 0){$record.FilesDone=$Files;$record.FilesTotal=$Files}
        [void](Write-WsmWizardBackupProgressRecord $Progress -Force)
    }catch{$Progress.LastError=[string]$_.Exception.Message}
}

# Final forced write. Outcome is Succeeded, Failed or Cancelled. A failure marks the item that was in flight.
function Complete-WsmWizardBackupProgress($Progress,[string]$Outcome) {
    if(-not $Progress){return}
    try{
        $record=$Progress.Record
        if($Outcome -cne 'Succeeded' -and [string]$record.Stage -ceq 'Capture' -and [int]$Progress.CurrentIndex -gt [int]$Progress.DoneCount -and [int]$Progress.CurrentIndex -le $Progress.Ids.Count){
            $id=$Progress.Ids[[int]$Progress.CurrentIndex-1];$Progress.NameMap[$id]=$Progress.Names[[int]$Progress.CurrentIndex-1];Add-WsmWizardBackupProgressRecent $Progress $id 'Failed'
        }
        $record.Terminal=$true;$record.Outcome=$Outcome
        [void](Write-WsmWizardBackupProgressRecord $Progress -Force)
    }catch{$Progress.LastError=[string]$_.Exception.Message}
}

# Readback by parent operation id. Returns $null when absent or unreadable; never throws. Used after a console
# restart or browser reopen; an Interrupted job keeps this last record (its UpdatedUtc is the "last update").
function Read-WsmWizardBackupProgress([string]$Workspace,[string]$PairId,[string]$OperationId) {
    try{
        $path=Get-WsmWizardBackupProgressPath $Workspace $PairId $OperationId
        if(-not [IO.File]::Exists($path)){return $null}
        Assert-WsmNoReparse $path
        $record=$null;for($attempt=0;$attempt -lt 3 -and -not $record;$attempt++){try{$record=Read-WsmJson $path}catch{Start-Sleep -Milliseconds 20}}
        if(-not $record -or [string]$record.Kind -cne 'WizardBackupProgress' -or [string]$record.OperationId -cne $OperationId -or [string]$record.PairId -cne $PairId){return $null}
        $record
    }catch{$null}
}

function Get-WsmWizardBackupAttempt([string]$Workspace,[string]$PairId,$Profile,[string]$PlanHash) {
    $root=Get-WsmWizardBackupRoot $Workspace $PairId
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)){Assert-WsmNoReparse $file.FullName;$row=Read-WsmJson $file.FullName;Assert-WsmWizardBackupAttempt $row $Workspace $PairId $Profile|Out-Null;$resumeStage='';if($row.PSObject.Properties['ResumeStage']){$resumeStage=[string]$row.ResumeStage};$sourceResumeFreshPending=[bool]($row.PSObject.Properties['SourceResumeFreshFreezePending'] -and $row.SourceResumeFreshFreezePending);$sourceRecoveryPending=[bool](($row.PSObject.Properties['SourceResumeRequired'] -and $row.SourceResumeRequired) -or $sourceResumeFreshPending);$sourceHandoffComplete=[bool]($row.PSObject.Properties['SourceResumed'] -and $row.SourceResumed -and -not $sourceResumeFreshPending);$resumable=(-not $sourceHandoffComplete) -and ($row.Stage -in @('Authorized','CoreExported','PackageVerified') -or ($row.Stage -in @('Failed','Cancelled') -and $resumeStage -in @('Authorized','CoreExported','PackageVerified')) -or ($row.Stage -eq 'ReviewRequired' -and $sourceRecoveryPending));if($row.PlanHash -ieq $PlanHash -and $resumable){$rows.Add([pscustomobject]@{Path=$file.FullName;Attempt=$row})}}
    # A crash after the fresh backup attempt is durable but before the previous
    # SourceResumed record is marked handed off leaves two visible records.
    # The child's exact parent id and source attempt reference prove the durable
    # handoff; without them the ambiguity remains a hard stop.
    $linkedParentIds=@{};foreach($candidate in $rows){$child=$candidate.Attempt;if($child.PSObject.Properties['ResumedFromBackupAttemptId'] -and $child.ResumedFromBackupAttemptId -and $child.PSObject.Properties['ResumedFromSourceAttemptPath'] -and $child.PSObject.Properties['ResumedFromSourceAttemptHash']){$linkedParentIds[[string]$child.ResumedFromBackupAttemptId]=[pscustomobject]@{Path=[string]$child.ResumedFromSourceAttemptPath;Hash=[string]$child.ResumedFromSourceAttemptHash}}}
    if($linkedParentIds.Count){$kept=New-Object 'System.Collections.Generic.List[object]';foreach($candidate in $rows){$row=$candidate.Attempt;if($linkedParentIds.ContainsKey([string]$row.AttemptId) -and $row.PSObject.Properties['SourceResumed'] -and $row.SourceResumed -and $row.PSObject.Properties['SourceAttemptPath'] -and $row.PSObject.Properties['SourceAttemptHash']){$link=$linkedParentIds[[string]$row.AttemptId];if([string]$row.SourceAttemptPath -ieq $link.Path -and [string]$row.SourceAttemptHash -ieq $link.Hash){continue}};$kept.Add($candidate)};$rows=$kept}
    if($rows.Count -gt 1){throw 'More than one unfinished backup attempt is bound to this plan; inspect existing operation records before continuing.'}
    if($rows.Count){return $rows[0]}
    $null
}

function Get-WsmWizardBackupAttemptForOperation([string]$Workspace,[string]$PairId,$Profile,[string]$OperationId) {
    $root=Get-WsmWizardBackupRoot $Workspace $PairId
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)){
        Assert-WsmNoReparse $file.FullName;$row=Read-WsmJson $file.FullName;Assert-WsmWizardBackupAttempt $row $Workspace $PairId $Profile|Out-Null
        $operationIds=@();if($row.PSObject.Properties['OperationIds']){$operationIds=@($row.OperationIds)}else{$operationIds=@([string]$row.StartedByOperationId)}
        if($operationIds -ccontains $OperationId){return [pscustomobject]@{Path=$file.FullName;Attempt=$row}}
    }
    $null
}

# N3: capture is all-or-nothing. When the exporter throws, no manifest exists and no result set is produced, so a
# "capture failed" row can never appear in the result set. The only reliable record is the exception tag that
# Payload.ps1 sets on the item being captured (Data['WsmCaptureFailedItemId']). It is stored in the attempt Error as
# FailedItem: the plan item identity plus an error class/kind taken from the exception TYPE. The exception message
# is never copied (it can carry paths or other free text). Returns $null when the failure was not inside an item.
function New-WsmWizardBackupCaptureFailure($Plan,$Exception) {
    try{
        if($null -eq $Exception -or $null -eq $Exception.Data -or -not $Exception.Data.Contains('WsmCaptureFailedItemId')){return $null}
        $failedId=[string]$Exception.Data['WsmCaptureFailedItemId']
        if(-not $failedId){return $null}
        $found=@($Plan.Items|Where-Object {[string]$_.ItemId -ceq $failedId})
        if($found.Count -ne 1){return $null}
        $planItem=$found[0]
        $inner=$Exception;$depth=0
        while($inner.InnerException -and $depth -lt 8){$inner=$inner.InnerException;$depth++}
        $typeName=[string]$inner.GetType().FullName
        $errorClass='Failed'
        if($inner -is [UnauthorizedAccessException]){$errorClass='PermissionDenied'}
        elseif($inner -is [IO.FileNotFoundException] -or $inner -is [IO.DirectoryNotFoundException]){$errorClass='NotFound'}
        elseif($inner -is [IO.IOException]){$errorClass='IOError'}
        $channel='';if($planItem.PSObject.Properties['MigrationSpec'] -and $planItem.MigrationSpec){$spec=$planItem.MigrationSpec;if([string]$spec.Adapter -ceq 'Certificate'){$channel='Certificate'}elseif([string]$spec.Adapter -ceq 'FileScope'){$channel=$(if($spec.PSObject.Properties['TransferChannel'] -and [string]$spec.TransferChannel){[string]$spec.TransferChannel}else{'C'})}}
        [pscustomobject][ordered]@{ItemId=$failedId;Name=[string]$planItem.Name;Kind=[string]$planItem.Kind;Channel=$channel;ErrorClass=$errorClass;ErrorKind=$typeName}
    }catch{$null}
}

function ConvertTo-WsmWizardBackupResult($Attempt,[string]$OperationId) {
    $independentCopy=$(if($Attempt.PSObject.Properties['IndependentCopy']){$Attempt.IndependentCopy}else{$null})
    $itemResults=$(if($Attempt.PSObject.Properties['ItemResults']){$Attempt.ItemResults}else{$null})
    $offlineReport=$(if($Attempt.PSObject.Properties['OfflineReport']){$Attempt.OfflineReport}else{$null})
    $offlineReadiness=$(if($Attempt.Stage -cne 'Delivered'){'NotDelivered'}elseif($independentCopy -and $independentCopy.PSObject.Properties['Status'] -and $independentCopy.Status -ceq 'Verified'){[string]$independentCopy.Availability}else{'AwaitingIndependentCopy'})
    [pscustomobject][ordered]@{Kind='WizardBackupResult';Status=[string]$Attempt.Stage;PairId=[string]$Attempt.PairId;AttemptId=[string]$Attempt.AttemptId;OperationId=$OperationId;StartedByOperationId=[string]$Attempt.StartedByOperationId;Stage=[string]$Attempt.Stage;DeliveryMode=$(if($Attempt.PSObject.Properties['DeliveryMode']){[string]$Attempt.DeliveryMode}else{''});VolumeBytes=$(if($Attempt.PSObject.Properties['VolumeBytes']){[long]$Attempt.VolumeBytes}else{0});Freeze=$Attempt.Freeze;CoreExport=$Attempt.CoreExport;PackageTest=$Attempt.PackageTest;Delivery=$Attempt.Delivery;ChannelSummary=$Attempt.ChannelSummary;NonCStatus=$(if($Attempt.ChannelSummary){[string]$Attempt.ChannelSummary.NonC.Status}else{'Pending'});ResumeStage=$(if($Attempt.PSObject.Properties['ResumeStage']){[string]$Attempt.ResumeStage}else{''});CanResumeAfterReview=($Attempt.Stage -in @('Failed','Cancelled') -and $Attempt.ResumeStage -in @('Authorized','CoreExported','PackageVerified'));SourceResumeRequired=([bool]($Attempt.PSObject.Properties['SourceResumeRequired'] -and $Attempt.SourceResumeRequired));AuthoritativeApproval=$true;ProductionVerified=$false;ResumeRequired=($Attempt.Stage -in @('Authorized','CoreExported','PackageVerified') -or ($Attempt.Stage -in @('Failed','Cancelled') -and $Attempt.ResumeStage -in @('Authorized','CoreExported','PackageVerified')) -or [bool](($Attempt.PSObject.Properties['SourceResumeRequired'] -and $Attempt.SourceResumeRequired) -or ($Attempt.PSObject.Properties['SourceResumeFreshFreezePending'] -and $Attempt.SourceResumeFreshFreezePending)));IndependentCopy=$independentCopy;OfflineReadiness=$offlineReadiness;ItemResults=$itemResults;OfflineReport=$offlineReport}
}

function Get-WsmWizardBackupDeliverySettings([string]$Workspace,[string]$PairId,$Profile,$Existing,[bool]$ModeSpecified,[string]$RequestedMode,[bool]$VolumeSpecified,$RequestedVolume) {
    $normalizedRequestedVolume=[long]0
    if($VolumeSpecified){
        try{$decimalVolume=[decimal]::Parse([string]$RequestedVolume,[Globalization.NumberStyles]::Number,[Globalization.CultureInfo]::InvariantCulture)}catch{throw 'VolumeBytes must be a whole-number byte count.'}
        if($decimalVolume -ne [decimal]::Truncate($decimalVolume) -or $decimalVolume -lt 0 -or $decimalVolume -gt [long]::MaxValue){throw 'VolumeBytes must be a whole-number byte count in the supported range.'}
        $normalizedRequestedVolume=[long]$decimalVolume
    }
    if($Existing){
        $record=$Existing.Attempt
        $output=Resolve-WsmOutputWorkspace -WorkRoot $Workspace -Role Source -PairId $PairId -PlanHash ([string]$record.PlanHash) -AttemptId ([string]$record.AttemptId)
        $mode=[string]$output.AttemptProfile.Mode;$volume=[long]$output.AttemptProfile.VolumeBytes
        if($ModeSpecified -and $RequestedMode -cne $mode){throw 'Delivery mode is frozen for this backup attempt; start a fresh attempt to choose another format.'}
        if($VolumeSpecified -and $normalizedRequestedVolume -ne $volume){throw 'Delivery volume limit is frozen for this backup attempt; start a fresh attempt to choose another size.'}
    } else {
        $mode='';$state=$null
        try{$state=Get-WsmWizardState $Workspace $PairId Source}catch{}
        if($state -and $state.PSObject.Properties['Mode']){
            switch([string]$state.Mode){'ItemByItem'{$mode='Directory'};'Automatic'{$mode='Zip'};default{throw 'Unknown wizard source delivery mode.'}}
        }else{$mode=[string]$Profile.Mode}
        if($ModeSpecified){$mode=$RequestedMode}
        if($mode -cnotin @('Directory','Zip')){throw 'Unknown source delivery mode.'}
        if($VolumeSpecified){$volume=$normalizedRequestedVolume}
        elseif($mode -ceq 'Directory'){$volume=[long]0}
        elseif($mode -ceq [string]$Profile.Mode){$volume=[long]$Profile.VolumeBytes}
        else{$volume=[long](Get-WsmOutputProfileDefaults).VolumeBytes}
        if($mode -ceq 'Directory' -and $VolumeSpecified -and $volume -ne 0){throw 'Directory delivery requires VolumeBytes=0.'}
        if($mode -ceq 'Directory'){$volume=0}
        Assert-WsmOutputProfileValues ([pscustomobject]@{Mode=$mode;VolumeBytes=$volume})
    }
    [pscustomobject]@{Mode=$mode;VolumeBytes=[long]$volume}
}

function Get-WsmWizardPlanInventoryBinding($Plan) {
    $inventoryHash=[string]$Plan.InventoryHash
    $inventoryRevision=[int]$Plan.InventoryRevision
    if($inventoryHash -notmatch '^[a-f0-9]{64}$' -or $inventoryRevision -lt 0){throw 'The approved plan does not contain a verifiable source inventory binding.'}
    [pscustomobject]@{Hash=$inventoryHash;Revision=$inventoryRevision}
}

function Get-WsmWizardChannelSummary($Plan,$PackageTest,$Delivery) {
    $items=@($Plan.Items|Where-Object Decision -CEQ 'Include');$cItems=New-Object 'System.Collections.Generic.List[string]';$nonCItems=New-Object 'System.Collections.Generic.List[string]';$manualItems=New-Object 'System.Collections.Generic.List[string]';$unknownItems=New-Object 'System.Collections.Generic.List[string]';$configItems=New-Object 'System.Collections.Generic.List[string]';$certificateItems=New-Object 'System.Collections.Generic.List[string]'
    $matrix=@{};foreach($adapter in @(Get-WsmAdapterMatrix)){$matrix[[string]$adapter.Adapter]=$adapter}
    foreach($item in $items){$spec=$item.MigrationSpec;if(-not $spec){$unknownItems.Add([string]$item.ItemId);continue};if($spec.Adapter -ceq 'ManualWorkflow'){$manualItems.Add([string]$item.ItemId);continue};if($spec.Adapter -ceq 'FileScope'){$channel='C';if($spec.PSObject.Properties['TransferChannel']){$channel=[string]$spec.TransferChannel};if($channel -ceq 'C'){$cItems.Add([string]$item.ItemId)}elseif($channel -ceq 'NonC'){$nonCItems.Add([string]$item.ItemId)}else{$unknownItems.Add([string]$item.ItemId)};continue};if($spec.Adapter -ceq 'Certificate'){$certificateItems.Add([string]$item.ItemId);continue};if($matrix.ContainsKey([string]$spec.Adapter) -and [bool]$matrix[[string]$spec.Adapter].ExportImplemented){$configItems.Add([string]$item.ItemId)}else{$unknownItems.Add([string]$item.ItemId)}}
    $isOfflineFullSet=Test-WsmWizardOfflineFullSetPlan $Plan
    $packageValid=[bool]($PackageTest -and $PackageTest.Valid);$deliveryValid=[bool]($Delivery -and [string]$Delivery.SHA256 -match '^[a-fA-F0-9]{64}$')
    $cStatus=if($cItems.Count){if($packageValid -and $deliveryValid){'VerifiedDelivered'}elseif($packageValid){'VerifiedNotDelivered'}elseif($PackageTest){'Failed'}else{'Pending'}}elseif($PackageTest -and $packageValid){'NoIncludedCFileScope'}elseif($PackageTest){'Failed'}else{'NoIncludedCFileScope'}
    $nonCStatus=if(-not $nonCItems.Count){'NoIncludedNonCFileScope'}elseif($isOfflineFullSet){if($packageValid -and $deliveryValid){'VerifiedDelivered'}elseif($packageValid){'VerifiedNotDelivered'}elseif($PackageTest){'Failed'}else{'Pending'}}elseif($PackageTest -and $PackageTest.Final){'RequiresTargetTransferAndManagerResultImport'}else{'RequiresFinalSourceFreeze'}
    $configStatus=if(-not $configItems.Count){'NoIncludedSupportedConfiguration'}elseif($packageValid -and $deliveryValid){'VerifiedInSealedPlanAndDelivered'}elseif($packageValid){'VerifiedInSealedPlanNotDelivered'}elseif($PackageTest){'Failed'}else{'Pending'}
    # A valid Test-WsmMigrationPackage result has already checked every selected
    # Certificate artifact row and every blob hash. Keep this projection cheap:
    # it runs during result reads, so it must not re-run the deep package scan.
    $certificateStatus=if(-not $certificateItems.Count){'NoIncludedCertificate'}elseif($packageValid -and $deliveryValid){'VerifiedPayloadDelivered'}elseif($packageValid){'VerifiedPayloadNotDelivered'}elseif($PackageTest){'Failed'}else{'Pending'}
    $nonCUnresolved=if($isOfflineFullSet){$nonCItems.Count -and -not ($packageValid -and $deliveryValid)}else{$nonCItems.Count}
    $unresolved=$nonCUnresolved -or $manualItems.Count -or $unknownItems.Count -or ($cItems.Count -and -not ($packageValid -and $deliveryValid)) -or ($configItems.Count -and -not ($packageValid -and $deliveryValid)) -or ($certificateItems.Count -and -not ($packageValid -and $deliveryValid))
    $overall=if($unresolved){'ReviewRequired'}elseif(-not ($cItems.Count -or $nonCItems.Count -or $configItems.Count -or $certificateItems.Count)){'NoSupportedSelectedEvidence'}else{'Succeeded'}
    [pscustomobject][ordered]@{C=[pscustomobject]@{IncludedItemIds=@($cItems.ToArray());Status=$cStatus};NonC=[pscustomobject]@{IncludedItemIds=@($nonCItems.ToArray());Status=$nonCStatus};ConfigurationEvidence=[pscustomobject]@{IncludedItemIds=@($configItems.ToArray());Status=$configStatus};Certificate=[pscustomobject]@{IncludedItemIds=@($certificateItems.ToArray());Status=$certificateStatus};ManualArtifactsNotSupported=[pscustomobject]@{IncludedItemIds=@($manualItems.ToArray());Status=$(if($manualItems.Count){'ManualArtifactsNotSupported'}else{'NoIncludedManualWorkflow'})};UnsupportedIncludedItemIds=@($unknownItems.ToArray());OverallStatus=$overall;ProductionVerified=$false}
}

function Get-WsmWizardBackupTrustedInventory([string]$Workspace,$Profile,$Plan,[object[]]$Jobs) {
    try{
        $binding=Get-WsmWizardInventoryFromJobs $Workspace $Profile $Jobs ([string]$Plan.InventoryHash) ''
        if(-not $binding -or $binding.Ambiguous -or [string]$binding.SHA256 -ine [string]$Plan.InventoryHash -or [int]$binding.Inventory.Revision -ne [int]$Plan.InventoryRevision -or [string]$binding.Inventory.Source.HostId -cne [string]$Profile.HostId -or [string]$binding.Inventory.Source.Fingerprint -ine [string]$Profile.Fingerprint){return $null}
        $binding.Inventory
    }catch{$null}
}

function Get-WsmWizardBackupSharedImpactRows([string]$ProducerItemId,[string]$ProducerName,$Impact,$Inventory,$Plan) {
    if(-not $Inventory){[pscustomobject]@{ItemId=$ProducerItemId;Producer=$ProducerName;ConsumerItemIds=@($(if($Impact.PSObject.Properties['ConsumerItemIds']){@($Impact.ConsumerItemIds)}else{@()}));Impact=('共享影響集合未能核對，需重新盤點／人工核對。資源識別：'+[string]$Impact.ResourceKind+'/'+[string]$Impact.ResourceItemId);Source=''};return}
    $items=@($Inventory.Items);$itemById=@{};foreach($item in $items){$itemById[[string]$item.ItemId]=$item};$decisionById=@{};foreach($item in @($Plan.Items)){$decisionById[[string]$item.ItemId]=[string]$item.Decision}
    $discovery=Get-WsmWorkloadDiscovery $Inventory;$resource=@($discovery.SharedResources|Where-Object ResourceItemId -CEQ ([string]$Impact.ResourceItemId)|Select-Object -First 1)
    $consumerIds=@();if($Impact.PSObject.Properties['ConsumerItemIds']){$consumerIds=@($Impact.ConsumerItemIds)};if($resource.Count){$consumerIds=@($resource[0].ConsumerItemIds)}
    $resourceItem=$null;if($itemById.ContainsKey([string]$Impact.ResourceItemId)){$resourceItem=$itemById[[string]$Impact.ResourceItemId]};$resourceName=[string]$Impact.ResourceItemId;if($resourceItem){$resourceName=[string]$resourceItem.NaturalKey};if($resourceName.Length -gt 800){$resourceName=$resourceName.Substring(0,700)+' [resource name truncated; verify full inventory.]'}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($id in @($consumerIds|Select-Object -Unique)){
        $item=$null;if($itemById.ContainsKey([string]$id)){$item=$itemById[[string]$id]}
        if(-not $item){[void]$rows.Add([pscustomobject]@{ItemId=$ProducerItemId;Producer=$ProducerName;ConsumerItemIds=@([string]$id);Impact=('來源盤點與核准計畫綁定一致，但 consumer '+[string]$id+' 沒有可核對名稱；需人工核對。');Source=''});continue}
        $label=([string]$item.Kind+' '+[string]$item.NaturalKey);$labelTruncated=$false;if($label.Length -gt 4200){$label=$label.Substring(0,4000)+' [consumer name truncated; verify full inventory.]';$labelTruncated=$true};$state='未納入核准計畫';if($decisionById.ContainsKey([string]$id)){if($decisionById[[string]$id] -ceq 'Include'){$state='本次已選'}else{$state='本次未選'}}
        $review='';if($Impact.PSObject.Properties['RequiresSharedReview'] -and $Impact.RequiresSharedReview){$review='；需要負責人審查'};if($Impact.PSObject.Properties['OwnerReviewReason'] -and [string]$Impact.OwnerReviewReason){$reason=[string]$Impact.OwnerReviewReason;if($reason.Length -gt 1000){$reason=$reason.Substring(0,900)+' [review reason truncated; verify full inventory.]'};$review+='：'+$reason}
        $impactText=('共享資源 '+[string]$Impact.ResourceKind+' '+$resourceName+' 影響 '+$label+'（'+$state+'；ItemId '+[string]$id+'）'+$review)
        if($labelTruncated){$impactText+='；顯示名稱已截短，需在完整盤點中人工核對。'}
        [void]$rows.Add([pscustomobject]@{ItemId=$ProducerItemId;Producer=$ProducerName;ConsumerItemIds=@([string]$id);Impact=$impactText;Source=''})
    }
    if(-not $rows.Count){[void]$rows.Add([pscustomobject]@{ItemId=$ProducerItemId;Producer=$ProducerName;ConsumerItemIds=@();Impact=('共享資源 '+[string]$Impact.ResourceKind+' '+$resourceName+'；一致盤點中未解析到 consumer，需人工核對。');Source=''})}
    $rows.ToArray()
}

function Get-WsmWizardBackupImpactPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[object[]]$Jobs=@(),[string]$FreezeExternalEvidencePath,[string]$FreezeExternalEvidenceHash,[ValidateSet('Directory','Zip')][string]$DeliveryMode,$VolumeBytes)
    Assert-WsmId $PairId
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Source'){throw 'Backup impact preview requires this enrolled Source workspace.'}
    $planRef=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $null $Jobs
    if(-not $planRef){$machine=Get-WsmMachineIdentity;return [pscustomobject][ordered]@{Kind='WizardBackupImpactPreview';Status='Blocked';PairId=$PairId;SourceHost=[pscustomobject]@{HostId=[string]$profile.HostId;Name=[string]$machine.Name;Fingerprint=[string]$profile.Fingerprint};Reason='No current target-bound approved plan is valid for this source host.';Producers=@();SharedImpact=@();PriorState=[pscustomobject]@{Location=(Join-Path $Workspace ('pairs\freeze-'+$PairId+'-*'));Description='Existing source freeze attempts and recovery baselines, if any; retain them for owner review.'};EvidenceRequirements=@('Import and verify the current target-bound approved plan before backup.');FreezeRequired=$false;FreezeAuthorized=$false;SourceChanged=$false;ProductionVerified=$false}}
    $plan=Read-WsmMigrationPlan $planRef.Path $planRef.SHA256
    if($plan.PairId -cne $PairId -or $plan.Source.HostId -cne $profile.HostId -or $plan.Source.Fingerprint -cne $profile.Fingerprint){throw 'The approved plan is not bound to this current source workspace and selected migration.'}
    Assert-WsmWizardBackupPlanSupported $plan
    $trustedInventory=Get-WsmWizardBackupTrustedInventory $Workspace $profile $plan $Jobs
    $rows=New-Object 'System.Collections.Generic.List[object]';$shared=New-Object 'System.Collections.Generic.List[object]';$mutable=$false;$nonC=$false
    foreach($item in @($plan.Items | Where-Object Decision -CEQ 'Include')){
        $spec=$item.MigrationSpec;$adapter=if($spec){[string]$spec.Adapter}else{'Unknown'};$channel='Configuration';$requiresFreeze=$false;$quiescedByFreeze=$false;$identity=[ordered]@{ItemId=[string]$item.ItemId;Kind=[string]$item.Kind;Name=[string]$item.NaturalKey;Adapter=$adapter}
        if($adapter -ceq 'FileScope'){$channel=if($spec.PSObject.Properties['TransferChannel']){[string]$spec.TransferChannel}else{'C'};$identity.SourcePath=[string]$spec.SourcePath;$requiresFreeze=($spec.Consistency -cne 'Immutable');if($channel -ceq 'NonC'){$nonC=$true};if($requiresFreeze){$mutable=$true}}
        elseif($adapter -in @('Service','ScheduledTask','IISPool','IISSite','SmbShare')){$quiescedByFreeze=$true;if($adapter -ceq 'SmbShare'){$channel='SharedFileScope';$shared.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Producer=[string]$item.NaturalKey;Impact='If this plan requires source freeze, the selected share may be made unavailable to writers; existing open handles require owner review.'})}else{$channel='ProducerConfiguration';$impactText='If another selected scope requires source freeze, this producer may be disabled or stopped until an owner separately completes the existing SourceResume/recovery process.';if($adapter -ceq 'IISPool'){$poolImpact=[pscustomobject]@{ResourceKind='IISPool';ResourceItemId=[string]$item.ItemId};foreach($impactRow in (Get-WsmWizardBackupSharedImpactRows ([string]$item.ItemId) ([string]$item.NaturalKey) $poolImpact $trustedInventory $plan)){$impactRow.Impact=$impactText+' '+$impactRow.Impact;$shared.Add($impactRow)}}else{$shared.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Producer=[string]$item.NaturalKey;Impact=$impactText})}}}
        if($spec -and $spec.PSObject.Properties['SharedResourceImpacts']){foreach($impact in @($spec.SharedResourceImpacts)){foreach($impactRow in (Get-WsmWizardBackupSharedImpactRows ([string]$item.ItemId) ([string]$item.NaturalKey) $impact $trustedInventory $plan)){$impactRow.Source='Approved plan SharedResourceImpacts';$shared.Add($impactRow)}}}
        $rows.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Name=[string]$item.NaturalKey;Kind=[string]$item.Kind;Adapter=$adapter;Channel=$channel;Selected=$true;SourcePath=$(if($spec -and $spec.PSObject.Properties['SourcePath']){[string]$spec.SourcePath}else{''});ProducerIdentity=$identity;RequiresSourceFreeze=$requiresFreeze;ProducerQuiescedIfFreezeRuns=$quiescedByFreeze;PriorStateLocation=(Join-Path $Workspace ('pairs\freeze-'+$PairId+'-*'))})
    }
    $freezeRequired=($mutable -or $nonC)
    $evidence=@();if($freezeRequired){$evidence+=@('Independent hash-trusted ExternalReadinessEvidence with Phase=SourceFreezeReady, matching this approved plan, selected producers, current host, owner, and non-empty FreezeEpoch.','Named responsible owner and explicit quiescence evidence for each selected producer.','Separate explicit freeze authorization; the ordinary StartBackup confirmation does not authorize source changes.','After quiescence, inspect the durable source attempt and retain the exact prior runtime/ACL state for the existing SourceResume/recovery path.')}
    if($nonC){if(Test-WsmWizardOfflineFullSetPlan $plan){$evidence+=@('Non-C scopes are captured into the same offline full-set package as C scopes and verified with it.')}else{$evidence+=@('Non-C scopes are excluded from the C package and require the separate target transfer and manager result import before they are reported complete.')}}
    $readinessStatus='NotProvided';if($FreezeExternalEvidencePath -or $FreezeExternalEvidenceHash){$readinessStatus='Invalid';$reason='';try{if(-not $FreezeExternalEvidencePath -or $FreezeExternalEvidenceHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Both readiness evidence path and hash are required.'};$external=Read-WsmTrustedJson $FreezeExternalEvidencePath $FreezeExternalEvidenceHash;[void](Assert-WsmSourceFreezeEvidence $FreezeExternalEvidencePath $FreezeExternalEvidenceHash $plan $planRef.SHA256 ([string]$external.FreezeEpoch));$readinessStatus='Verified'}catch{$reason=$_.Exception.Message};if($readinessStatus -ne 'Verified'){$evidence+=@('Current SourceFreezeReady evidence is invalid: '+$reason)}}
    $backupAttemptRoot=Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-backups') $PairId
    $quiescenceDisclosure=if($freezeRequired){'If the separately authorized source freeze runs, every selected producer listed here is in its quiescence scope; no automatic SourceResume is performed.'}else{'No source freeze is required for this selected set; configuration-only selections do not cause producer shutdown.'}
    $settings=Get-WsmWizardBackupDeliverySettings $Workspace $PairId $profile (Get-WsmWizardBackupAttempt $Workspace $PairId $profile $planRef.SHA256) ($PSBoundParameters.ContainsKey('DeliveryMode')) $DeliveryMode ($PSBoundParameters.ContainsKey('VolumeBytes')) $VolumeBytes
    if($settings.Mode -ceq 'Directory'){
        $plannedAttempt=Join-Path (Join-Path (Join-Path (Join-Path $profile.WorkRoot 'pairs') $PairId) 'attempts') ('0'*36)
        Assert-WsmDirectoryDeliveryPathBudget (Join-Path (Join-Path $plannedAttempt 'transport') 'delivery') @(Get-WsmWizardBackupDirectoryMemberNames $plan)
    }
    [pscustomobject][ordered]@{Kind='WizardBackupImpactPreview';Status='Previewed';PairId=$PairId;PlanHash=[string]$planRef.SHA256;InventoryHash=[string]$plan.InventoryHash;InventoryRevision=[int]$plan.InventoryRevision;SourceHost=[pscustomobject]@{HostId=[string]$profile.HostId;Name=[string]$plan.Source.Name;Fingerprint=[string]$profile.Fingerprint};DeliveryMode=$settings.Mode;VolumeBytes=$settings.VolumeBytes;Producers=@($rows.ToArray());SharedImpact=@($shared.ToArray());QuiescenceDisclosure=$quiescenceDisclosure;PriorState=[pscustomobject]@{Location=(Join-Path $Workspace ('pairs\freeze-'+$PairId+'-*'));BackupAttemptRoot=$backupAttemptRoot;Description='Original service/task/IIS runtime and share ACL baselines are retained under each durable source freeze attempt; interrupted or failed attempts require owner inspection and the existing SourceResume/recovery flow.'};EvidenceRequirements=@($evidence);SourceFreezeReadiness=$readinessStatus;FreezeRequired=$freezeRequired;FreezeAuthorized=$false;SourceChanged=$false;PackageScope='Only included, approved and supported C-channel content is sealed into the C package; no OS or installed software image is created.';ProductionVerified=$false}
}

function Invoke-WsmWizardStartBackup {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$OperationId,[string]$Owner,[string]$Evidence,[string]$FreezeExternalEvidencePath,[string]$FreezeExternalEvidenceHash,[switch]$FreezeAuthorization,[object[]]$Jobs=@(),$CancellationToken=$null,[ValidateSet('Directory','Zip')][string]$DeliveryMode,$VolumeBytes)
    Assert-WsmId $PairId;Assert-WsmId $OperationId
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'Start backup requires this enrolled Source workspace.'}
    $planRef=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $null $Jobs;if(-not $planRef){throw 'No current target-bound approved plan is valid for this enrolled source host; continue management preparation before backup.'}
    $plan=Read-WsmMigrationPlan $planRef.Path $planRef.SHA256
    if($plan.PairId -cne $PairId -or $plan.Source.HostId -cne $profile.HostId -or $plan.Source.Fingerprint -cne $profile.Fingerprint){throw 'The approved plan is not bound to this current source workspace and selected migration.'}
    Assert-WsmWizardBackupPlanSupported $plan
    $inventory=Get-WsmWizardPlanInventoryBinding $plan
    $included=@($plan.Items|Where-Object Decision -CEQ 'Include')
    $nonCIncluded=@($included|Where-Object {$_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'}).Count -gt 0
    $mutableIncluded=@($included|Where-Object {$_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.Consistency -cne 'Immutable'}).Count -gt 0
    $freezeRequired=($nonCIncluded -or $mutableIncluded)
    $operationAttempt=Get-WsmWizardBackupAttemptForOperation $Workspace $PairId $profile $OperationId
    if($operationAttempt){$replaySettings=Get-WsmWizardBackupDeliverySettings $Workspace $PairId $profile $operationAttempt ($PSBoundParameters.ContainsKey('DeliveryMode')) $DeliveryMode ($PSBoundParameters.ContainsKey('VolumeBytes')) $VolumeBytes;return (ConvertTo-WsmWizardBackupResult $operationAttempt.Attempt $OperationId)}
    $authorizedFreezeEpoch=''
    if($freezeRequired){if(-not $FreezeAuthorization -or [string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Evidence) -or -not $FreezeExternalEvidencePath -or $FreezeExternalEvidenceHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'A final backup for mutable or NonC data requires a separate explicit freeze authorization, a human owner, quiescence evidence, and independently verified SourceFreezeReady file/hash.'};$externalRecord=Read-WsmTrustedJson $FreezeExternalEvidencePath $FreezeExternalEvidenceHash;$authorizedFreezeEpoch=[string]$externalRecord.FreezeEpoch;$external=Assert-WsmSourceFreezeEvidence $FreezeExternalEvidencePath $FreezeExternalEvidenceHash $plan $planRef.SHA256 $authorizedFreezeEpoch;if($external.Owner -cne $Owner){throw 'Source freeze evidence owner does not match the named responsible owner.'}}
    $root=Get-WsmWizardBackupRoot $Workspace $PairId
    $existing=Get-WsmWizardBackupAttempt $Workspace $PairId $profile $planRef.SHA256
    $resumedPreviousSourceAttempt=$null;$previousBackupAttempt=$null;$previousSourceAttemptPath='';$previousSourceAttemptHash='';$resumeObservation=$null;$freezeMayContinue=$false
    if($existing -and $existing.Attempt -and (($existing.Attempt.PSObject.Properties['SourceResumeRequired'] -and $existing.Attempt.SourceResumeRequired) -or ($existing.Attempt.PSObject.Properties['FreezeAttemptStarted'] -and $existing.Attempt.FreezeAttemptStarted))){
        $resumeObservation=Get-WsmWizardSourceResumeEvidence $Workspace $PairId $profile $planRef $existing.Attempt $Jobs
        if($resumeObservation.Attempt -and $resumeObservation.Attempt.State.Status -ceq 'SourceResumed' -and $resumeObservation.ResumeJobVerified){$resumedPreviousSourceAttempt=$resumeObservation.Attempt;$previousSourceAttemptPath=[string]$resumeObservation.Path;$previousSourceAttemptHash=[string]$resumeObservation.Hash;$previousBackupAttempt=$existing.Attempt;$previousBackupPath=$existing.Path;$existing=$null}
        elseif($resumeObservation.Attempt -and $resumeObservation.Attempt.State.Status -ceq 'Frozen' -and $resumeObservation.FreezeRecordVerified -and $resumeObservation.FreezeRecordFresh){$freezeMayContinue=$true}
        elseif($resumeObservation.Attempt -and $resumeObservation.Attempt.State.Status -ceq 'Frozen' -and $resumeObservation.FreezeRecordVerified -and -not $resumeObservation.FreezeRecordFresh){throw 'The source freeze receipt is expired; SourceResume remains available, but continuing this backup requires a fresh SourceFreezeReady observation and explicit freeze authorization.'}
        elseif(-not $operationAttempt){throw ('Source freeze outcome is uncertain; StartBackup is blocked until the exact SourceResume route or manual recovery review is completed. '+[string]$resumeObservation.MissingReason)}
    }
    if($resumedPreviousSourceAttempt -and $freezeRequired){$resumedUtc=[DateTimeOffset]::Parse([string]$resumedPreviousSourceAttempt.State.Utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind);$observedUtc=[DateTimeOffset]::Parse([string]$external.ObservedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind);if($observedUtc -le $resumedUtc -or [string]$FreezeExternalEvidenceHash -ieq [string]$previousBackupAttempt.FreezeEvidenceHash -or $authorizedFreezeEpoch -ceq [string]$previousBackupAttempt.FreezeEpoch){throw 'A resumed source requires newly observed SourceFreezeReady evidence, a new FreezeEpoch, and a separate freeze authorization before creating another backup attempt.'}}
    if($resumedPreviousSourceAttempt -and -not $operationAttempt){$previousBackupAttempt.SourceResumeRequired=$false;$previousBackupAttempt | Add-Member NoteProperty SourceResumed $true -Force;$previousBackupAttempt | Add-Member NoteProperty SourceResumeFreshFreezePending $true -Force;$previousBackupAttempt | Add-Member NoteProperty SourceAttemptPath $previousSourceAttemptPath -Force;$previousBackupAttempt | Add-Member NoteProperty SourceAttemptHash $previousSourceAttemptHash -Force;$previousBackupAttempt.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $previousBackupPath $previousBackupAttempt $Workspace}
    $settingsAttempt=$existing;if($operationAttempt){$settingsAttempt=$operationAttempt}
    $deliverySettings=Get-WsmWizardBackupDeliverySettings $Workspace $PairId $profile $settingsAttempt ($PSBoundParameters.ContainsKey('DeliveryMode')) $DeliveryMode ($PSBoundParameters.ContainsKey('VolumeBytes')) $VolumeBytes
    if($operationAttempt){return (ConvertTo-WsmWizardBackupResult $operationAttempt.Attempt $OperationId)}
    if($deliverySettings.Mode -ceq 'Directory'){
        $plannedAttempt=if($existing){[string]$existing.Attempt.OutputRoot}else{Join-Path (Join-Path (Join-Path (Join-Path $profile.WorkRoot 'pairs') $PairId) 'attempts') $OperationId}
        Assert-WsmDirectoryDeliveryPathBudget (Join-Path (Join-Path $plannedAttempt 'transport') 'delivery') @(Get-WsmWizardBackupDirectoryMemberNames $plan)
    }
    if($existing){$record=$existing.Attempt;$path=$existing.Path;$attemptId=[string]$record.AttemptId;if($freezeMayContinue){$record.SourceResumeRequired=$false;if($record.Stage -ceq 'ReviewRequired'){$record.Stage='Authorized';$record.ResumeStage='';$record.Error=$null}};if($record.Stage -in @('Failed','Cancelled')){$record.Stage=[string]$record.ResumeStage;$record.ResumeStage='';$record.Error=$null};$operationIds=@();if($record.PSObject.Properties['OperationIds']){$operationIds=@($record.OperationIds)}else{$operationIds=@([string]$record.StartedByOperationId)};$record.OperationIds=@($operationIds)+@($OperationId);$record.LastOperationId=$OperationId;$resumeCount=0;if($record.PSObject.Properties['ResumeCount']){$resumeCount=[int]$record.ResumeCount};$record.ResumeCount=$resumeCount+1;$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace}
    else{
        $attemptId=$OperationId;$output=Resolve-WsmOutputWorkspace -WorkRoot $Workspace -Role Source -PairId $PairId -PlanHash $planRef.SHA256 -AttemptId $attemptId -AttemptMode $deliverySettings.Mode -AttemptVolumeBytes $deliverySettings.VolumeBytes
        $record=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WizardBackupAttempt';Workspace=[IO.Path]::GetFullPath($Workspace);ProfileId=[string]$profile.ProfileId;HostId=[string]$profile.HostId;PairId=$PairId;PlanPath=[IO.Path]::GetFullPath($planRef.Path);PlanHash=$planRef.SHA256;InventoryHash=$inventory.Hash;InventoryRevision=$inventory.Revision;AttemptId=$attemptId;StartedByOperationId=$OperationId;OperationIds=@($OperationId);LastOperationId=$OperationId;ResumeCount=0;DeliveryMode=$deliverySettings.Mode;VolumeBytes=[long]$deliverySettings.VolumeBytes;FreezeRequired=$freezeRequired;FreezeEvidencePath=$(if($freezeRequired){[IO.Path]::GetFullPath($FreezeExternalEvidencePath)}else{''});FreezeEvidenceHash=$(if($freezeRequired){$FreezeExternalEvidenceHash.ToLowerInvariant()}else{''});FreezeEpoch=$authorizedFreezeEpoch;FreezeOwner=$(if($freezeRequired){$Owner}else{''});FreezeEvidence=$(if($freezeRequired){$Evidence}else{''});Freeze=$null;FreezeAttemptStarted=$false;SourceResumeRequired=$false;SourceResumed=$false;SourceResumeFreshFreezePending=$false;ResumedFromBackupAttemptId=$(if($previousBackupAttempt){[string]$previousBackupAttempt.AttemptId}else{''});ResumedFromSourceAttemptPath=$previousSourceAttemptPath;ResumedFromSourceAttemptHash=$previousSourceAttemptHash;Stage='Authorized';ResumeStage='';OutputRoot=[IO.Path]::GetFullPath($output.AttemptRoot);CoreExport=$null;PackageTest=$null;Delivery=$null;ChannelSummary=$null;Error=$null;StartedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc);ProductionVerified=$false}
        $path=Join-Path $root ($attemptId+'.json');Assert-WsmNoReparse $path;if([IO.File]::Exists($path)){throw 'An operation record already exists for this identifier; read the existing result instead of sending the operation again.'};Write-WsmWizardBackupAttempt $path $record $Workspace
        if($previousBackupAttempt){$previousBackupAttempt.SourceResumeFreshFreezePending=$false;$previousBackupAttempt.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $previousBackupPath $previousBackupAttempt $Workspace}
    }
    if($record.PlanHash -ine $planRef.SHA256 -or $record.InventoryHash -ine $inventory.Hash -or [int]$record.InventoryRevision -ne $inventory.Revision){throw 'The approved plan or source inventory changed; start a fresh reviewed attempt.'}
    if([bool]$record.FreezeRequired -ne $freezeRequired -or ($freezeRequired -and ([string]$record.FreezeEvidenceHash -ine $FreezeExternalEvidenceHash -or [string]$record.FreezeOwner -cne $Owner -or [string]$record.FreezeEvidence -cne $Evidence -or ($record.PSObject.Properties['FreezeEpoch'] -and [string]$record.FreezeEpoch -cne $authorizedFreezeEpoch)))){throw 'This durable backup attempt was authorized against different source-freeze evidence; inspect the existing attempt before continuing.'}
    if($freezeRequired -and -not $record.PSObject.Properties['FreezeEpoch']){$record | Add-Member NoteProperty FreezeEpoch $authorizedFreezeEpoch;Write-WsmWizardBackupAttempt $path $record $Workspace}
    $output=Resolve-WsmOutputWorkspace -WorkRoot $Workspace -Role Source -PairId $PairId -PlanHash $planRef.SHA256 -AttemptId $attemptId
    if($record.PSObject.Properties['DeliveryMode'] -and ([string]$record.DeliveryMode -cne [string]$output.AttemptProfile.Mode -or [long]$record.VolumeBytes -ne [long]$output.AttemptProfile.VolumeBytes)){throw 'Backup attempt delivery format differs from its immutable output-attempt record.'}
    if(-not $record.PSObject.Properties['DeliveryMode']){$record | Add-Member NoteProperty DeliveryMode ([string]$output.AttemptProfile.Mode);$record | Add-Member NoteProperty VolumeBytes ([long]$output.AttemptProfile.VolumeBytes);Write-WsmWizardBackupAttempt $path $record $Workspace}
    # F1-P: a projection of this run only. It never throws into the backup and is not part of any attempt record.
    $progress=$null
    if($record.Stage -cin @('Authorized','CoreExported','PackageVerified')){
        try{
            $progressItems=@($plan.Items|Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec -and (($_.MigrationSpec.Adapter -ceq 'FileScope' -and (Test-WsmAssistivePackageScope $plan $_)) -or $_.MigrationSpec.Adapter -ceq 'Certificate')})
            $progress=New-WsmWizardBackupProgress $Workspace $PairId $OperationId $attemptId $progressItems
        }catch{$progress=$null}
    }
    if($record.Stage -eq 'Authorized'){
        try{
            Set-WsmWizardBackupProgressStage $progress 'Capture'
            Assert-WsmCancellationBoundary $CancellationToken 'BeforeSourceFreeze'
            if($freezeRequired -and -not $record.Freeze){
                $freezePath=Join-Path $record.OutputRoot 'source-freeze.json'
                if([IO.File]::Exists($freezePath)){$freezeHash=(Get-WsmAssistiveNonCHash $freezePath);$freeze=Read-WsmFreezeRecord $freezePath $freezeHash $plan $planRef.SHA256;$attestation=Assert-WsmSourceFreezeEvidence $record.FreezeEvidencePath $record.FreezeEvidenceHash $plan $planRef.SHA256 $freeze.FreezeEpoch;Assert-WsmSourceFreezeEvidenceMatchesAttestation $attestation $freeze;$frozen=[pscustomobject]@{Path=$freezePath;SHA256=$freezeHash;FreezeId=[string]$freeze.FreezeId;ExpiresUtc=[string]$freeze.ExpiresUtc}}
                else{$record.FreezeAttemptStarted=$true;$record | Add-Member NoteProperty FreezeAttemptStartedUtc (Get-WsmUtc) -Force;$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace;$frozen=Export-WsmFreezeRecord -PlanPath $planRef.Path -ExpectedHash $planRef.SHA256 -Path $freezePath -Owner $record.FreezeOwner -Evidence $record.FreezeEvidence -Acknowledgement 'OWNER-CONFIRMED-QUIESCENCE' -SourceStateDirectory (Join-Path $Workspace 'pairs') -FreezeExternalEvidencePath $record.FreezeEvidencePath -FreezeExternalEvidenceHash $record.FreezeEvidenceHash -FreezeEpoch $record.FreezeEpoch -Confirm:$false}
                if(-not $frozen -or -not $frozen.Path -or -not $frozen.SHA256){throw 'Source freeze did not return a verifiable durable record.'}
                $record.Freeze=[pscustomobject]@{Status='Succeeded';Path=[IO.Path]::GetFullPath([string]$frozen.Path);SHA256=[string]$frozen.SHA256;FreezeId=[string]$frozen.FreezeId;ExpiresUtc=[string]$frozen.ExpiresUtc;Owner=[string]$record.FreezeOwner;EvidenceHash=[string]$record.FreezeEvidenceHash;ProductionVerified=$false};$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace
            }
            Assert-WsmCancellationBoundary $CancellationToken 'BeforeCoreExport'
            $exportArgs=@{PlanPath=$planRef.Path;ExpectedHash=$planRef.SHA256;SourceStateDirectory=(Join-Path $Workspace 'pairs');OutputDirectory=$output.PackagesDirectory;CancellationToken=$CancellationToken}
            if($freezeRequired){$exportArgs.FreezePath=[string]$record.Freeze.Path;$exportArgs.FreezeHash=[string]$record.Freeze.SHA256;$exportArgs.FreezeExternalEvidencePath=[string]$record.FreezeEvidencePath;$exportArgs.FreezeExternalEvidenceHash=[string]$record.FreezeEvidenceHash}
            # The exporter reports every file through Write-WsmBackupItemProgress. A function defined in this scope is
            # visible only to the commands called from here, so the exporter code itself stays unchanged and the original
            # console progress (Write-Progress id 32) is still emitted.
            $progressItemHook=$progress
            if($progressItemHook){
                $originalItemProgress=Get-Command Write-WsmBackupItemProgress -CommandType Function
                function Write-WsmBackupItemProgress {param([int]$ItemIndex,[int]$ItemCount,[string]$ItemName,[string]$Channel,[string]$FilePath,[long]$FilesDone,[long]$BytesDone);& $originalItemProgress @PSBoundParameters;Update-WsmWizardBackupProgressItem $progressItemHook $ItemIndex $ItemCount $ItemName $FilePath $BytesDone $FilesDone}
            }
            $core=Export-WsmMigrationPackage @exportArgs
            $record.CoreExport=[pscustomobject]@{Status='Succeeded';ManifestPath=[IO.Path]::GetFullPath($core.ManifestPath);SHA256=[string]$core.SHA256;Generation=[int]$core.Generation;Files=[long]$core.Files;Bytes=[long]$core.Bytes;Final=[bool]$core.Final;Sealed=[bool]$core.Sealed;SoftwareScopeCoverage=@($(if($core.PSObject.Properties['SoftwareScopeCoverage']){@($core.SoftwareScopeCoverage)}else{@()}));ProductionVerified=$false};$record.Stage='CoreExported';$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace
        }
        catch{
            if($freezeRequired -and -not $record.Freeze -and $record.FreezeAttemptStarted){$record.ResumeStage='';$record.SourceResumeRequired=$true;$record.Stage='ReviewRequired';$record.Error=[pscustomobject]@{Code='source_freeze_interrupted';Message='來源停止寫入流程可能已部分執行；請先檢查來源恢復紀錄，勿直接重送。'}}
            else{$record.ResumeStage='Authorized';$record.Stage=if($_.Exception.Data['CancellationRequested']){'Cancelled'}else{'Failed'};if($freezeRequired -and $record.Freeze){$record.SourceResumeRequired=$true};$record.Error=[pscustomobject]@{Code=$(if($record.Stage -eq 'Cancelled'){'cancelled'}else{'core_export_failed'});Message=('封裝未完成；已保留目前可核對的資料，請查看作業紀錄後再續作。'+$(if([string]$_.Exception.Message -like 'OfflineFullSet source snapshot is missing*'){' 缺少核准時的來源盤點快照：請把 Manager 交付的 <計畫檔名>.source-snapshot.json 附件放在計畫檔旁，重新匯入核准計畫後再試。'}else{''}))};if($record.Stage -ceq 'Failed'){$captureFailure=New-WsmWizardBackupCaptureFailure $plan $_.Exception;if($captureFailure){$record.Error | Add-Member NoteProperty FailedItem $captureFailure -Force}}}
            $record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace;Complete-WsmWizardBackupProgress $progress $(if($record.Stage -ceq 'Cancelled'){'Cancelled'}else{'Failed'});throw
        }
    }
    if($record.Stage -eq 'CoreExported'){
        try{Set-WsmWizardBackupProgressStage $progress 'Verify' ([long]$record.CoreExport.Bytes) ([long]$record.CoreExport.Files);Assert-WsmCancellationBoundary $CancellationToken 'BeforePackageTest';$test=Test-WsmMigrationPackage -ManifestPath $record.CoreExport.ManifestPath -ExpectedHash $record.CoreExport.SHA256 -CancellationToken $CancellationToken;$record.PackageTest=[pscustomobject]@{Status='Succeeded';Valid=[bool]$test.Valid;ManifestPath=[IO.Path]::GetFullPath($record.CoreExport.ManifestPath);SHA256=[string]$record.CoreExport.SHA256;PlanHash=[string]$test.Manifest.PlanHash;Generation=[int]$test.Manifest.Generation;Files=[long]$test.Manifest.Files;Bytes=[long]$test.Manifest.Bytes;Final=[bool]$test.Manifest.Final;ProductionVerified=$false};$record.Stage='PackageVerified';$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace}
        catch{$resumeStage='CoreExported';$record.ResumeStage=$resumeStage;$record.Stage=if($_.Exception.Data['CancellationRequested']){'Cancelled'}else{'Failed'};if($freezeRequired -and $record.Freeze){$record.SourceResumeRequired=$true};$record.Error=[pscustomobject]@{Code=$(if($record.Stage -eq 'Cancelled'){'cancelled'}else{'package_test_failed'});Message='封裝核驗未完成；檔案保留，請先檢查作業紀錄。'};$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace;Complete-WsmWizardBackupProgress $progress $(if($record.Stage -ceq 'Cancelled'){'Cancelled'}else{'Failed'});throw}
    }
    if($record.Stage -eq 'PackageVerified'){
        try{
            Set-WsmWizardBackupProgressStage $progress 'Deliver' ([long]$record.CoreExport.Bytes) ([long]$record.CoreExport.Files)
            Assert-WsmCancellationBoundary $CancellationToken 'BeforeDelivery'
            # The delivery API re-verifies the sealed package and uses the same immutable OutputAttemptId.
            # Cancellation is checked at this stage boundary; the package's own resumable transport checkpoints prevent rebuilding prior work.
            $delivery=Export-WsmEnrolledPackageDelivery -WorkRoot $Workspace -ManifestPath $record.PackageTest.ManifestPath -ExpectedHash $record.PackageTest.SHA256 -AttemptId $attemptId -AttemptMode $record.DeliveryMode -AttemptVolumeBytes $record.VolumeBytes
            $deliveryPath='';$deliveryHash='';$deliveryDirectory=''
            if($delivery.Delivery.PSObject.Properties['Path'] -and $delivery.Delivery.PSObject.Properties['SHA256']){$deliveryPath=[string]$delivery.Delivery.Path;$deliveryHash=[string]$delivery.Delivery.SHA256}
            elseif($delivery.Delivery.PSObject.Properties['SummaryPath'] -and $delivery.Delivery.PSObject.Properties['SummarySHA256']){$deliveryPath=[string]$delivery.Delivery.SummaryPath;$deliveryHash=[string]$delivery.Delivery.SummarySHA256;if($delivery.Delivery.PSObject.Properties['Directory']){$deliveryDirectory=[string]$delivery.Delivery.Directory}}
            if(-not $deliveryPath -or $deliveryHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'The enrolled delivery returned no verifiable C-channel result.'}
            $record.Delivery=[pscustomobject]@{Status='Succeeded';AttemptId=[string]$delivery.AttemptId;IndexPath=[IO.Path]::GetFullPath($delivery.IndexPath);IndexSHA256=[string]$delivery.IndexSHA256;Mode=[string]$output.AttemptProfile.Mode;Path=[IO.Path]::GetFullPath($deliveryPath);SHA256=$deliveryHash.ToLowerInvariant();Directory=$(if($deliveryDirectory){[IO.Path]::GetFullPath($deliveryDirectory)}else{''});PackageManifestHash=[string]$record.PackageTest.SHA256;ProductionVerified=$false}
            $record.ChannelSummary=Get-WsmWizardChannelSummary $plan $record.PackageTest $record.Delivery
            try{
                $resultsPackage=Test-WsmMigrationPackage $record.PackageTest.ManifestPath $record.PackageTest.SHA256
                $resultsRoot=Split-Path -Parent ([string]$record.PackageTest.ManifestPath)
                $resultsOfflineFullSet=[bool](Test-WsmWizardOfflineFullSetPlan $plan)
                $resultsInventory=$null;$resultsInventorySource='Unavailable'
                if($resultsOfflineFullSet){
                    $controlsInventoryPath=Join-Path $resultsRoot 'controls\source-inventory.json'
                    if([IO.File]::Exists($controlsInventoryPath)){$resultsInventory=Read-WsmJson $controlsInventoryPath;if([string]$resultsInventory.Kind -cne 'Inventory'){throw 'The package source inventory control file is not an inventory record.'};$resultsInventorySource='PackageControls'}
                }else{
                    $resultsInventory=Get-WsmWizardBackupTrustedInventory $Workspace $profile $plan $Jobs
                    if($resultsInventory){$resultsInventorySource='TrustedInventory'}
                }
                $resultsArtifacts=@(Read-WsmArtifactLines (Join-Path $resultsRoot 'artifacts.jsonl') $resultsPackage.Manifest.ArtifactsHash)
                $resultsRows=@(Get-WsmBackupItemResultRows $plan $resultsInventory $resultsArtifacts $resultsOfflineFullSet)
                $resultsSoftware=Get-WsmBackupSoftwareRows $plan $resultsInventory
                # N3: policy exclusions of the scan the approved plan is bound to; $null Regions means the binding could not be verified (shown as not recorded).
                $resultsExclusions=Get-WsmBackupBoundScanExclusions $plan $Workspace $profile
                $resultsFile=Join-Path (Split-Path -Parent ([string]$record.Delivery.Path)) 'backup-item-results.json'
                $resultsExport=Export-WsmBackupItemResults $resultsFile $resultsRows ([pscustomobject]@{PairId=$PairId;AttemptId=$attemptId;PlanHash=[string]$planRef.SHA256;ManifestHash=[string]$record.PackageTest.SHA256;InventorySource=$resultsInventorySource;Software=$resultsSoftware;ExcludedRegions=$resultsExclusions.Regions;ExcludedRegionsBinding=$resultsExclusions.Binding})
                $record | Add-Member NoteProperty ItemResults ([pscustomobject]@{Status='Generated';Path=[string]$resultsExport.Path;SHA256=[string]$resultsExport.SHA256;Counts=$resultsExport.Counts;InventorySource=[string]$resultsExport.InventorySource}) -Force
            }catch{
                $resultsError=[string]$_.Exception.Message;if($resultsError.Length -gt 300){$resultsError=$resultsError.Substring(0,300)}
                $record | Add-Member NoteProperty ItemResults ([pscustomobject]@{Status='Failed';Error=$resultsError}) -Force
            }
            if($record.ItemResults.Status -ceq 'Generated'){
                try{
                    $reportExport=Export-WsmBackupOfflineReport ([string]$record.ItemResults.Path) ([string]$record.ItemResults.SHA256) (Join-Path (Split-Path -Parent ([string]$record.Delivery.Path)) 'backup-report.html')
                    $record | Add-Member NoteProperty OfflineReport ([pscustomobject]@{Status='Generated';Path=[string]$reportExport.Path;SHA256=[string]$reportExport.SHA256}) -Force
                }catch{
                    $reportError=[string]$_.Exception.Message;if($reportError.Length -gt 300){$reportError=$reportError.Substring(0,300)}
                    $record | Add-Member NoteProperty OfflineReport ([pscustomobject]@{Status='Failed';Error=$reportError}) -Force
                }
            }else{
                $record | Add-Member NoteProperty OfflineReport ([pscustomobject]@{Status='Skipped'}) -Force
            }
            # N6：離線使用說明（HTML＋文字備援）放在交付描述檔旁；雜湊只記在 attempt 與獨立副本收據，不進封裝本體。失敗不擋交付，只記錄原因。
            try{
                $guideDirectory=Split-Path -Parent ([string]$record.Delivery.Path)
                $guideFingerprint='';try{$guideFingerprint=[string](Get-WsmToolFingerprint)}catch{}
                $guideFacts=[pscustomobject][ordered]@{ToolVersion=[string]$script:ToolVersion;ToolFingerprint=$guideFingerprint;PairId=$PairId;AttemptId=$attemptId;Mode=[string]$record.Delivery.Mode;GeneratedUtc=(Get-WsmUtc);ManifestHash=[string]$record.PackageTest.SHA256;PlanHash=[string]$planRef.SHA256;DeliveryName=[IO.Path]::GetFileName([string]$record.Delivery.Path);DeliverySHA256=[string]$record.Delivery.SHA256;ItemResultsSHA256=$(if($record.ItemResults.Status -ceq 'Generated'){[string]$record.ItemResults.SHA256}else{''});OfflineReportSHA256=$(if($record.OfflineReport.Status -ceq 'Generated'){[string]$record.OfflineReport.SHA256}else{''})}
                $guideExport=Export-WsmBackupOfflineGuide (Join-Path $guideDirectory 'offline-guide.html') (Join-Path $guideDirectory 'offline-guide.txt') $guideFacts
                $record | Add-Member NoteProperty OfflineGuide ([pscustomobject]@{Status='Generated';Path=[string]$guideExport.Path;SHA256=[string]$guideExport.SHA256;TextPath=[string]$guideExport.TextPath;TextSHA256=[string]$guideExport.TextSHA256}) -Force
            }catch{
                $guideError=[string]$_.Exception.Message;if($guideError.Length -gt 300){$guideError=$guideError.Substring(0,300)}
                $record | Add-Member NoteProperty OfflineGuide ([pscustomobject]@{Status='Failed';Error=$guideError}) -Force
            }
            $record.Stage=if($record.ChannelSummary.OverallStatus -eq 'ReviewRequired'){'ReviewRequired'}else{'Delivered'};$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace
        }catch{$resumeStage='PackageVerified';$record.ResumeStage=$resumeStage;$record.Stage=if($_.Exception.Data['CancellationRequested']){'Cancelled'}else{'Failed'};if($freezeRequired -and $record.Freeze){$record.SourceResumeRequired=$true};$record.Error=[pscustomobject]@{Code=$(if($record.Stage -eq 'Cancelled'){'cancelled'}else{'delivery_failed'});Message='搬移封裝已核驗，但交接材料未完整產生；可從同一作業嘗試續作。'};$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace;Complete-WsmWizardBackupProgress $progress $(if($record.Stage -ceq 'Cancelled'){'Cancelled'}else{'Failed'});throw}
    }
    Complete-WsmWizardBackupProgress $progress 'Succeeded'
    ConvertTo-WsmWizardBackupResult $record $OperationId
}

function Test-WsmWizardOfflineFullSetPlan($Plan) {
    [bool]($Plan.PSObject.Properties['Assistive'] -and $Plan.Assistive -and $Plan.Assistive.ContractVersion -eq 2)
}

function Get-WsmIndependentCopyMediaClass([string]$DestinationRoot) {
    if([string]::IsNullOrWhiteSpace($DestinationRoot)){return 'Unknown'}
    if($DestinationRoot.StartsWith('\\')){return 'Network'}
    try {
        $full=[IO.Path]::GetFullPath($DestinationRoot)
        if($full.StartsWith('\\')){return 'Network'}
        $root=[IO.Path]::GetPathRoot($full)
        if([string]::IsNullOrWhiteSpace($root)){return 'Unknown'}
        $drive=New-Object IO.DriveInfo($root)
        $dt=[string]$drive.DriveType
        if($dt -ceq 'Removable'){return 'Removable'}
        if($dt -ceq 'Network'){return 'Network'}
        if($dt -ceq 'Fixed'){return 'LocalFixed'}
        return 'Unknown'
    }catch{
        return 'Unknown'
    }
}

function Test-WsmIndependentCopyFiles([string]$CopyRoot,$Delivery,[string]$ItemResultsSHA256,[string]$OfflineReportSHA256,$CancellationToken=$null,[string]$OfflineGuideSHA256='',[string]$OfflineGuideTextSHA256='') {
    $mode=[string]$Delivery.Mode
    foreach($sidecar in @(@{Name='backup-item-results.json';Label='item results';Hash=$ItemResultsSHA256},@{Name='backup-report.html';Label='offline report';Hash=$OfflineReportSHA256},@{Name='offline-guide.html';Label='offline guide';Hash=$OfflineGuideSHA256},@{Name='offline-guide.txt';Label='offline guide text';Hash=$OfflineGuideTextSHA256})){
        if(-not $sidecar.Hash){continue}
        $destSidecarPath=Join-Path $CopyRoot ('transport\'+$sidecar.Name)
        Assert-WsmNoReparse $destSidecarPath
        if(-not [IO.File]::Exists($destSidecarPath)){throw ('Missing independent copy '+$sidecar.Label+' file: '+$destSidecarPath)}
        if((Get-FileHash -LiteralPath $destSidecarPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sidecar.Hash.ToLowerInvariant()){throw ('Independent copy '+$sidecar.Label+' file hash mismatch: '+$destSidecarPath)}
    }
    if($mode -ceq 'Directory'){
        $summaryName=[IO.Path]::GetFileName([string]$Delivery.Path)
        $destSummaryPath=Join-Path $CopyRoot ('transport\'+$summaryName)
        Assert-WsmNoReparse $destSummaryPath
        if(-not [IO.File]::Exists($destSummaryPath)){throw ('Missing independent copy summary file: '+$destSummaryPath)}
        $summary=Read-WsmTrustedJson $destSummaryPath ([string]$Delivery.SHA256)
        Assert-WsmEnvelope $summary 'DirectoryDelivery'
        $summaryLen=(New-Object IO.FileInfo($destSummaryPath)).Length
        $totalBytes=[long]$summaryLen;$fileCount=1
        $deliveryDir=Join-Path $CopyRoot 'transport\delivery'
        Assert-WsmNoReparse $deliveryDir
        if(-not [IO.Directory]::Exists($deliveryDir)){throw ('Missing independent copy delivery directory: '+$deliveryDir)}
        $expectedMembers=@{}
        foreach($m in @($summary.Members)){
            $rel=[string]$m.Name.Replace('/','\')
            $expectedMembers[$rel]=$m
            $memberPath=Join-Path $deliveryDir $rel
            Assert-WsmNoReparse $memberPath
            if(-not [IO.File]::Exists($memberPath)){throw ('Missing independent copy member file: '+$memberPath)}
            $fi=New-Object IO.FileInfo($memberPath)
            if($fi.Length -ne [long]$m.Bytes){throw ('Independent copy member file size mismatch: '+$memberPath)}
            $h=(Get-FileHash -LiteralPath $memberPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if($h -cne ([string]$m.SHA256).ToLowerInvariant()){throw ('Independent copy member file hash mismatch: '+$memberPath)}
            $fileCount++;$totalBytes+=[long]$m.Bytes
        }
        $delivFull=([IO.Path]::GetFullPath($deliveryDir)).TrimEnd('\')+'\'
        $actualFiles=@(Get-ChildItem -LiteralPath $deliveryDir -Recurse -File)
        foreach($f in $actualFiles){
            Assert-WsmNoReparse $f.FullName
            $relPath=([IO.Path]::GetFullPath($f.FullName)).Substring($delivFull.Length)
            if(-not $expectedMembers.ContainsKey($relPath)){throw ('Unexpected extra file in independent copy delivery: '+$f.FullName)}
        }
        return [pscustomobject]@{FileCount=[int]$fileCount;TotalBytes=[long]$totalBytes}
    }elseif($mode -ceq 'Zip'){
        $destTransportPath=Join-Path $CopyRoot 'transport\transport.json'
        Assert-WsmNoReparse $destTransportPath
        if(-not [IO.File]::Exists($destTransportPath)){throw ('Missing independent copy transport file: '+$destTransportPath)}
        $transport=Read-WsmTrustedJson $destTransportPath ([string]$Delivery.SHA256)
        Assert-WsmEnvelope $transport 'PackageTransport'
        $transLen=(New-Object IO.FileInfo($destTransportPath)).Length
        $totalBytes=[long]$transLen;$fileCount=1
        $transDir=Join-Path $CopyRoot 'transport'
        $volNum=0
        foreach($v in @($transport.Volumes)){
            $volNum++
            $volumePath=Join-Path $transDir ([string]$v.Name)
            Assert-WsmNoReparse $volumePath
            if(-not [IO.File]::Exists($volumePath)){throw ('Missing independent copy ZIP volume file: '+$volumePath)}
            $expected=@($transport.Entries | Where-Object Volume -EQ $volNum)
            try{$check=Test-WsmZipVolume $volumePath $expected ([string]$v.Hash) $CancellationToken}catch{throw ('Independent copy ZIP volume verification failed for '+$volumePath+': '+$_.Exception.Message)}
            if($check.Bytes -ne [long]$v.Bytes){throw ('Independent copy ZIP volume length mismatch: '+$volumePath)}
            $fileCount++;$totalBytes+=[long]$v.Bytes
        }
        return [pscustomobject]@{FileCount=[int]$fileCount;TotalBytes=[long]$totalBytes}
    }else{
        throw 'Unknown delivery mode for independent copy.'
    }
}

function Get-WsmWizardIndependentCopyAction($Availability) {
    $stage='';$hasPackage=$false;$runId=''
    if($Availability){
        if($Availability.PSObject.Properties['stage']){$stage=[string]$Availability.stage}
        if($Availability.PSObject.Properties['hasPackage']){$hasPackage=[bool]$Availability.hasPackage}
        if($Availability.PSObject.Properties['runId']){$runId=[string]$Availability.runId}
    }
    if($stage -ceq 'Delivered' -and $hasPackage){
        return New-WsmWizardRuntimeAction 'IndependentCopy' $true '把已封存的交付複製到可移除磁碟或網路位置並逐檔驗證；舊機本機固定磁碟不算獨立副本。' @{BackupOperationId=$runId;Mode='Copy'} @('DestinationRoot')
    }
    return New-WsmWizardRuntimeAction 'IndependentCopy' $false '需先完成一次已交付的備份，才能建立獨立副本。' @{} @('DestinationRoot')
}

function Get-WsmWizardOfflineReadiness($Availability) {
    if(-not $Availability -or -not ($Availability.PSObject.Properties['attempt'] -and $Availability.attempt)){
        return 'NotDelivered'
    }
    $runId=if($Availability.PSObject.Properties['runId']){[string]$Availability.runId}else{''}
    return (ConvertTo-WsmWizardBackupResult $Availability.attempt $runId).OfflineReadiness
}

function Invoke-WsmWizardIndependentCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$BackupOperationId,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [ValidateSet('Copy','VerifyExisting')][string]$Mode='Copy',
        $CancellationToken=$null
    )
    Assert-WsmId $PairId;Assert-WsmId $OperationId;Assert-WsmId $BackupOperationId
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Source'){throw 'Independent copy requires this enrolled Source workspace.'}
    $operationAttempt=Get-WsmWizardBackupAttemptForOperation $Workspace $PairId $profile $BackupOperationId
    if(-not $operationAttempt -or -not $operationAttempt.Attempt){throw 'Independent copy requires a delivered backup attempt for this operation.'}
    $attempt=$operationAttempt.Attempt;$attemptPath=$operationAttempt.Path
    if($attempt.Stage -cne 'Delivered' -or -not ($attempt.PSObject.Properties['Delivery'] -and $attempt.Delivery -and $attempt.Delivery.PSObject.Properties['SHA256'] -and $attempt.Delivery.SHA256)){
        throw 'Independent copy requires a delivered backup attempt for this operation.'
    }
    $destination=[IO.Path]::GetFullPath($DestinationRoot)
    $workspaceFull=[IO.Path]::GetFullPath($Workspace)
    $workspacePrefix=$workspaceFull.TrimEnd('\')+'\'
    if($destination.TrimEnd('\') -ieq $workspaceFull.TrimEnd('\') -or $destination.TrimEnd('\').StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)){
        throw 'Independent copy destination must be outside the source workspace.'
    }
    $mediaClass=Get-WsmIndependentCopyMediaClass $destination
    if($mediaClass -ceq 'LocalFixed'){throw 'Independent copy destination is a local fixed disk of the source host and is not independent.'}
    if($mediaClass -ceq 'Unknown'){throw 'Independent copy destination media type cannot be classified.'}
    $attemptId=[string]$attempt.AttemptId
    $copyRoot=Join-Path $destination ('wsm-offline-'+$PairId+'-'+$attemptId)
    $deliveryMode=[string]$attempt.Delivery.Mode
    $deliveryPath=[string]$attempt.Delivery.Path
    $deliverySHA256=[string]$attempt.Delivery.SHA256
    $sourceDescriptor=Read-WsmTrustedJson $deliveryPath $deliverySHA256
    if($deliveryMode -ceq 'Directory'){
        Assert-WsmEnvelope $sourceDescriptor 'DirectoryDelivery'
    }elseif($deliveryMode -ceq 'Zip'){
        Assert-WsmEnvelope $sourceDescriptor 'PackageTransport'
    }else{
        throw 'Unknown delivery mode for independent copy.'
    }
    $filesToCopy=@()
    if($deliveryMode -ceq 'Directory'){
        $summaryName=[IO.Path]::GetFileName($deliveryPath)
        $filesToCopy+=@([pscustomobject]@{Source=$deliveryPath;Dest=(Join-Path $copyRoot ('transport\'+$summaryName));Bytes=((New-Object IO.FileInfo($deliveryPath)).Length);SHA256=$deliverySHA256})
        $sourceDeliveryDir=if($attempt.Delivery.PSObject.Properties['Directory'] -and $attempt.Delivery.Directory){[string]$attempt.Delivery.Directory}else{Join-Path (Split-Path -Parent $deliveryPath) 'delivery'}
        foreach($m in @($sourceDescriptor.Members)){
            $rel=[string]$m.Name.Replace('/','\')
            $filesToCopy+=@([pscustomobject]@{Source=(Join-Path $sourceDeliveryDir $rel);Dest=(Join-Path $copyRoot ('transport\delivery\'+$rel));Bytes=[long]$m.Bytes;SHA256=[string]$m.SHA256})
        }
    }else{
        $filesToCopy+=@([pscustomobject]@{Source=$deliveryPath;Dest=(Join-Path $copyRoot 'transport\transport.json');Bytes=((New-Object IO.FileInfo($deliveryPath)).Length);SHA256=$deliverySHA256})
        $sourceZipDir=Split-Path -Parent $deliveryPath
        foreach($v in @($sourceDescriptor.Volumes)){
            $filesToCopy+=@([pscustomobject]@{Source=(Join-Path $sourceZipDir ([string]$v.Name));Dest=(Join-Path $copyRoot ('transport\'+[string]$v.Name));Bytes=[long]$v.Bytes;SHA256=[string]$v.Hash})
        }
    }
    $itemResultsExpectedHash=''
    if($attempt.PSObject.Properties['ItemResults'] -and $attempt.ItemResults -and $attempt.ItemResults.PSObject.Properties['Status'] -and $attempt.ItemResults.Status -ceq 'Generated'){
        $itemResultsExpectedHash=[string]$attempt.ItemResults.SHA256
        $itemResultsSource=Join-Path (Split-Path -Parent $deliveryPath) 'backup-item-results.json'
        $filesToCopy+=@([pscustomobject]@{Source=$itemResultsSource;Dest=(Join-Path $copyRoot 'transport\backup-item-results.json');Bytes=((New-Object IO.FileInfo($itemResultsSource)).Length);SHA256=$itemResultsExpectedHash})
    }
    $offlineReportExpectedHash=''
    if($attempt.PSObject.Properties['OfflineReport'] -and $attempt.OfflineReport -and $attempt.OfflineReport.PSObject.Properties['Status'] -and $attempt.OfflineReport.Status -ceq 'Generated'){
        $offlineReportExpectedHash=[string]$attempt.OfflineReport.SHA256
        $offlineReportSource=Join-Path (Split-Path -Parent $deliveryPath) 'backup-report.html'
        $filesToCopy+=@([pscustomobject]@{Source=$offlineReportSource;Dest=(Join-Path $copyRoot 'transport\backup-report.html');Bytes=((New-Object IO.FileInfo($offlineReportSource)).Length);SHA256=$offlineReportExpectedHash})
    }
    $offlineGuideExpectedHash='';$offlineGuideTextExpectedHash=''
    if($attempt.PSObject.Properties['OfflineGuide'] -and $attempt.OfflineGuide -and $attempt.OfflineGuide.PSObject.Properties['Status'] -and $attempt.OfflineGuide.Status -ceq 'Generated'){
        $offlineGuideExpectedHash=[string]$attempt.OfflineGuide.SHA256;$offlineGuideTextExpectedHash=[string]$attempt.OfflineGuide.TextSHA256
        $guideSourceDirectory=Split-Path -Parent $deliveryPath
        $guideSourceHtml=Join-Path $guideSourceDirectory 'offline-guide.html';$guideSourceText=Join-Path $guideSourceDirectory 'offline-guide.txt'
        $filesToCopy+=@([pscustomobject]@{Source=$guideSourceHtml;Dest=(Join-Path $copyRoot 'transport\offline-guide.html');Bytes=((New-Object IO.FileInfo($guideSourceHtml)).Length);SHA256=$offlineGuideExpectedHash})
        $filesToCopy+=@([pscustomobject]@{Source=$guideSourceText;Dest=(Join-Path $copyRoot 'transport\offline-guide.txt');Bytes=((New-Object IO.FileInfo($guideSourceText)).Length);SHA256=$offlineGuideTextExpectedHash})
    }
    try {
        if($Mode -ceq 'Copy'){
            foreach($file in $filesToCopy){
                Assert-WsmCancellationBoundary $CancellationToken 'IndependentCopyFile'
                if([IO.File]::Exists($file.Dest)){
                    $existingLen=(New-Object IO.FileInfo($file.Dest)).Length
                    $existingHash=(Get-FileHash -LiteralPath $file.Dest -Algorithm SHA256).Hash
                    if($existingLen -eq [long]$file.Bytes -and $existingHash -ieq [string]$file.SHA256){continue}
                    throw 'Independent copy destination already holds different content; choose an empty location.'
                }
                $destDir=[IO.Path]::GetDirectoryName($file.Dest)
                if(-not [IO.Directory]::Exists($destDir)){[void][IO.Directory]::CreateDirectory($destDir)}
                $partial=$file.Dest+'.partial'
                if([IO.File]::Exists($partial)){[IO.File]::Delete($partial)}
                try {
                    [IO.File]::Copy($file.Source,$partial,$true)
                    [IO.File]::Move($partial,$file.Dest)
                } catch {
                    if([IO.File]::Exists($partial)){try{[IO.File]::Delete($partial)}catch{}}
                    throw
                }
            }
        }
        $verified=Test-WsmIndependentCopyFiles $copyRoot $attempt.Delivery $itemResultsExpectedHash $offlineReportExpectedHash $CancellationToken $offlineGuideExpectedHash $offlineGuideTextExpectedHash
        $availability=if($mediaClass -ceq 'Removable'){'Verified'}else{'VerifiedNetworkAvailabilityUnconfirmed'}
        $backupRoot=Get-WsmWizardBackupRoot $Workspace $PairId
        $receiptDir=Join-Path $backupRoot 'independent-copies'
        if(-not [IO.Directory]::Exists($receiptDir)){[void](New-WsmOutputOwnedDirectory $receiptDir)}
        $receiptId=[Guid]::NewGuid().ToString('D')
        $receiptPath=Join-Path $receiptDir ($BackupOperationId+'-'+$receiptId+'.json')
        $verifiedUtc=Get-WsmUtc
        $receipt=[pscustomobject][ordered]@{
            SchemaVersion=1
            ToolVersion=$script:ToolVersion
            Kind='IndependentCopyReceipt'
            PairId=$PairId
            AttemptId=$attemptId
            BackupOperationId=$BackupOperationId
            RequestOperationId=$OperationId
            DeliveryMode=$deliveryMode
            DeliverySHA256=$deliverySHA256
            ItemResultsSHA256=$itemResultsExpectedHash
            OfflineGuideSHA256=$offlineGuideExpectedHash
            OfflineGuideTextSHA256=$offlineGuideTextExpectedHash
            CopyRoot=[IO.Path]::GetFullPath($copyRoot)
            MediaClass=$mediaClass
            Availability=$availability
            Mode=$Mode
            FileCount=[int]$verified.FileCount
            TotalBytes=[long]$verified.TotalBytes
            VerifiedUtc=$verifiedUtc
            ProductionVerified=$false
        }
        Write-WsmJson $receiptPath $receipt
        $receiptHash=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $indObj=[pscustomobject]@{
            Status='Verified'
            Availability=$availability
            MediaClass=$mediaClass
            CopyRoot=[IO.Path]::GetFullPath($copyRoot)
            ReceiptPath=[IO.Path]::GetFullPath($receiptPath)
            ReceiptSHA256=$receiptHash
            VerifiedUtc=$verifiedUtc
        }
        if($attempt.PSObject.Properties['IndependentCopy']){$attempt.IndependentCopy=$indObj}else{Add-Member -InputObject $attempt -NotePropertyName IndependentCopy -NotePropertyValue $indObj}
        $attempt.UpdatedUtc=Get-WsmUtc
        Write-WsmWizardBackupAttempt $attemptPath $attempt $Workspace
    } catch {
        $errText=[string]$_.Exception.Message
        if($errText.Length -gt 300){$errText=$errText.Substring(0,300)}
        $failedObj=[pscustomobject]@{
            Status='Failed'
            Availability='NotVerified'
            MediaClass=$mediaClass
            CopyRoot=[IO.Path]::GetFullPath($copyRoot)
            Error=$errText
            UpdatedUtc=Get-WsmUtc
        }
        if($attempt.PSObject.Properties['IndependentCopy']){$attempt.IndependentCopy=$failedObj}else{Add-Member -InputObject $attempt -NotePropertyName IndependentCopy -NotePropertyValue $failedObj}
        $attempt.UpdatedUtc=Get-WsmUtc
        try{Write-WsmWizardBackupAttempt $attemptPath $attempt $Workspace}catch{}
        throw
    }
    ConvertTo-WsmWizardBackupResult $attempt $BackupOperationId
}

function Assert-WsmWizardBackupPlanSupported($Plan) {
    if($Plan.PSObject.Properties['Assistive'] -and $Plan.Assistive -and $Plan.Assistive.ContractVersion -gt 2){throw 'Wizard backup does not support Assistive contract versions newer than 2.'}
    if(Test-WsmWizardOfflineFullSetPlan $Plan){if($Plan.Assistive.SourcePolicy -cne 'ApprovedLocalVolumes'){throw 'Wizard backup supports Assistive ContractVersion 2 only with SourcePolicy ApprovedLocalVolumes.'}}
}
