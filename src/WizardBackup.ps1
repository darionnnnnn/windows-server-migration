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

# R4：「這次備份已交付」只認交付證據，不比對 Stage 字串是否剛好是 Delivered。結果頁、檔案明細、獨立副本、離線還原就緒、
# 進度卡全部呼叫這一個判定，不得各自寫死 'Delivered'。
#   Stage Delivered      producer 只在交付、逐項結果與報告都處理完才寫入這個值，本身就是證據。
#   Stage ReviewRequired 計畫含人工（ManualWorkflow）、外部（External）或不支援的項目時，producer 也會寫成這個值，但交付其實
#                        已驗證、結果集與離線報告都已產生。此時要同時有：PackageTest.Valid、Delivery.SHA256 為 64 位十六進位、
#                        ItemResults.Status 為 Generated。來源停寫中斷（source_freeze_interrupted）同樣是 ReviewRequired，
#                        但沒有 PackageTest／Delivery，不會通過。
#   其他 Stage           一律不是已交付（Failed／Cancelled 即使留有部分 Delivery 欄位也不算）。
# $Attempt 可為 $null（只有 Stage 的投影物件）：此時只有 Delivered 成立。
function Test-WsmWizardBackupStageDelivered([string]$Stage,$Attempt=$null) {
    if($Stage -ceq 'Delivered'){return $true}
    if($Stage -cne 'ReviewRequired' -or $null -eq $Attempt){return $false}
    foreach($name in @('PackageTest','Delivery','ItemResults')){if(-not $Attempt.PSObject.Properties[$name] -or $null -eq $Attempt.$name){return $false}}
    if(-not $Attempt.PackageTest.PSObject.Properties['Valid'] -or -not [bool]$Attempt.PackageTest.Valid){return $false}
    if(-not $Attempt.Delivery.PSObject.Properties['SHA256'] -or [string]$Attempt.Delivery.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){return $false}
    if(-not $Attempt.ItemResults.PSObject.Properties['Status'] -or [string]$Attempt.ItemResults.Status -cne 'Generated'){return $false}
    # 既有契約（Test-G3NonCFailureFreeze s1/s2）：舊格式非 C 直傳尚未完成的備份，不得被當成完整備份，
    # 工作台結果頁與獨立副本都不能放行。所以只有「待處理的全是人工／外部／不支援項目」才算已交付；
    # ChannelSummary 缺漏或非 C 通道還沒完成時，無法證明這一點，一律不算。
    if(-not $Attempt.PSObject.Properties['ChannelSummary'] -or $null -eq $Attempt.ChannelSummary -or -not $Attempt.ChannelSummary.PSObject.Properties['NonC'] -or $null -eq $Attempt.ChannelSummary.NonC){return $false}
    if([string]$Attempt.ChannelSummary.NonC.Status -cin @('RequiresTargetTransferAndManagerResultImport','RequiresFinalSourceFreeze','Pending','Failed','VerifiedNotDelivered')){return $false}
    $true
}

function Test-WsmWizardBackupAttemptDelivered($Attempt) {
    if($null -eq $Attempt -or -not $Attempt.PSObject.Properties['Stage']){return $false}
    Test-WsmWizardBackupStageDelivered ([string]$Attempt.Stage) $Attempt
}

# R4 附註：交付已驗證，但計畫含需人工或外部處理的項目。數字取自 attempt 的 ChannelSummary（與決定 ReviewRequired 的同一份資料）：
# 人工（ManualWorkflow）與不支援／外部項目。舊格式非 C 直傳尚未完成的備份不算已交付（見上方判定），所以不在這個數字內。沒有 ChannelSummary 的舊紀錄回 0。
function Get-WsmWizardBackupReviewItemCount($ChannelSummary) {
    if($null -eq $ChannelSummary){return 0}
    $count=0
    try{
        if($ChannelSummary.PSObject.Properties['ManualArtifactsNotSupported'] -and $ChannelSummary.ManualArtifactsNotSupported){$count+=@($ChannelSummary.ManualArtifactsNotSupported.IncludedItemIds).Count}
        if($ChannelSummary.PSObject.Properties['UnsupportedIncludedItemIds']){$count+=@($ChannelSummary.UnsupportedIncludedItemIds).Count}
    }catch{return 0}
    [int]$count
}

# R5：「目前這一代 attempt」全站只有這一個判定。排序鍵是 attempt 建立時寫下、之後不再改動的 StartedUtc，
# 依序比 StartedUtc、CoreExport.Generation、AttemptId（只為結果穩定）。不用 UpdatedUtc：對舊 attempt 做獨立副本、續作或補寫
# 都會刷新 UpdatedUtc，用它挑選會讓結果頁翻回舊世代。沒有新增欄位：每份 attempt 都有 StartedUtc；少了或無法解析時視為最舊（Ticks=0），
# 不會排到新的前面，也不會丟例外。
function Get-WsmWizardBackupAttemptOrderKey($Attempt) {
    $ticks=[long]0;$generation=[int]0
    try{if($Attempt.PSObject.Properties['StartedUtc'] -and [string]$Attempt.StartedUtc){$ticks=[DateTimeOffset]::Parse([string]$Attempt.StartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).UtcTicks}}catch{$ticks=[long]0}
    try{if($Attempt.PSObject.Properties['CoreExport'] -and $Attempt.CoreExport -and $Attempt.CoreExport.PSObject.Properties['Generation']){$generation=[int]$Attempt.CoreExport.Generation}}catch{$generation=[int]0}
    [pscustomobject]@{Ticks=$ticks;Generation=$generation;Id=[string]$Attempt.AttemptId}
}

function Get-WsmWizardCurrentBackupAttempt([object[]]$Attempts) {
    $best=$null;$bestKey=$null
    foreach($candidate in @($Attempts)){
        if($null -eq $candidate){continue}
        $key=Get-WsmWizardBackupAttemptOrderKey $candidate
        $newer=($null -eq $best)
        if(-not $newer){
            if($key.Ticks -ne $bestKey.Ticks){$newer=($key.Ticks -gt $bestKey.Ticks)}
            elseif($key.Generation -ne $bestKey.Generation){$newer=($key.Generation -gt $bestKey.Generation)}
            else{$newer=([string]::CompareOrdinal($key.Id,$bestKey.Id) -gt 0)}
        }
        if($newer){$best=$candidate;$bestKey=$key}
    }
    $best
}

# R5：「可續作」全站只有這一個判定（續作入口 Get-WsmWizardBackupAttempt 與結果物件的 ResumeRequired／CanResumeAfterReview 都呼叫它）。
# 已交接的 attempt（SourceResumed 且沒有等待新凍結）一律不可續作，不論 Stage。
function Test-WsmWizardBackupAttemptResumable($Attempt) {
    if($null -eq $Attempt){return $false}
    $stage=[string]$Attempt.Stage
    $resumeStage='';if($Attempt.PSObject.Properties['ResumeStage']){$resumeStage=[string]$Attempt.ResumeStage}
    $freshPending=[bool]($Attempt.PSObject.Properties['SourceResumeFreshFreezePending'] -and $Attempt.SourceResumeFreshFreezePending)
    $recoveryPending=[bool](($Attempt.PSObject.Properties['SourceResumeRequired'] -and $Attempt.SourceResumeRequired) -or $freshPending)
    $handoffComplete=[bool]($Attempt.PSObject.Properties['SourceResumed'] -and $Attempt.SourceResumed -and -not $freshPending)
    if($handoffComplete){return $false}
    if($stage -cin @('Authorized','CoreExported','PackageVerified')){return $true}
    if($stage -cin @('Failed','Cancelled') -and $resumeStage -cin @('Authorized','CoreExported','PackageVerified')){return $true}
    if($stage -ceq 'ReviewRequired' -and $recoveryPending){return $true}
    $false
}

# R10：備份 attempt 檔的「可辨識」全站只有這一個判定（啟動端、續作入口、結果頁、可用性列都走這裡）。
# 壞 JSON、舊 ToolVersion、缺欄位、屬於別的工作區／主機／配對，一律是「無法讀取的備份紀錄」：不丟例外、不擋新備份、
# 不會被當成任何一個 attempt（因此也不可能被選成目前 attempt）；只回報檔名與粗分類，絕不帶路徑或檔案內容。
# 例外：reparse point 仍照原樣 fail-closed（那是安全問題，不是壞檔）。
function Get-WsmWizardBackupAttemptScan([string]$Root,[string]$Workspace,[string]$PairId,$Profile) {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $unreadable=New-Object 'System.Collections.Generic.List[object]'
    if($Root -and [IO.Directory]::Exists($Root)){
        foreach($file in @(Get-ChildItem -LiteralPath $Root -Filter '*.json' -File)){
            Assert-WsmNoReparse $file.FullName
            $row=$null;$reason=''
            try{$row=Read-WsmJson $file.FullName}catch{$reason='InvalidJson'}
            if(-not $reason){try{[void](Assert-WsmWizardBackupAttempt $row $Workspace $PairId $Profile)}catch{$reason='NotRecognized'}}
            if($reason){$unreadable.Add([pscustomobject][ordered]@{FileName=[string]$file.Name;Reason=$reason});continue}
            $rows.Add([pscustomobject]@{Path=$file.FullName;Attempt=$row})
        }
    }
    [pscustomobject][ordered]@{Rows=@($rows.ToArray());Unreadable=@($unreadable.ToArray())}
}

# 結果頁與啟動結果共用的「無法讀取紀錄」報告：只有數量與檔名（上限 20 個，超過只計數）。
function ConvertTo-WsmWizardUnreadableAttemptReport($Unreadable) {
    $names=@(@($Unreadable)|Where-Object {$_}|ForEach-Object {[string]$_.FileName}|Select-Object -First 20)
    [pscustomobject][ordered]@{count=[int]@($Unreadable|Where-Object {$_}).Count;files=@($names)}
}

function Get-WsmWizardBackupAttempt([string]$Workspace,[string]$PairId,$Profile,[string]$PlanHash) {
    $root=Get-WsmWizardBackupRoot $Workspace $PairId
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($candidate in @((Get-WsmWizardBackupAttemptScan $root $Workspace $PairId $Profile).Rows)){$row=$candidate.Attempt;if($row.PlanHash -ieq $PlanHash -and (Test-WsmWizardBackupAttemptResumable $row)){$rows.Add($candidate)}}
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
    foreach($candidate in @((Get-WsmWizardBackupAttemptScan $root $Workspace $PairId $Profile).Rows)){
        $row=$candidate.Attempt
        $operationIds=@();if($row.PSObject.Properties['OperationIds']){$operationIds=@($row.OperationIds)}else{$operationIds=@([string]$row.StartedByOperationId)}
        if($operationIds -ccontains $OperationId){return $candidate}
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
        # R11：穩定原因碼只看例外型別與 HResult（共用違規 0x20／0x21），絕不比對訊息文字；無法辨識沿用 Failed。
        $reasonCode='Failed'
        if($inner -is [IO.PathTooLongException]){$reasonCode='PathTooLong'}
        elseif($inner -is [UnauthorizedAccessException]){$reasonCode='AccessDenied'}
        elseif($inner -is [IO.FileNotFoundException] -or $inner -is [IO.DirectoryNotFoundException]){$reasonCode='Missing'}
        elseif($inner -is [IO.IOException] -and (([int]$inner.HResult -band 0xFFFF) -in @(32,33))){$reasonCode='Locked'}
        $relativeDepth=$null;$leafName='';if($Exception.Data.Contains('WsmCaptureFailedDepth')){$relativeDepth=[int]$Exception.Data['WsmCaptureFailedDepth'];$leafName=[string]$Exception.Data['WsmCaptureFailedLeaf']}
        $channel='';if($planItem.PSObject.Properties['MigrationSpec'] -and $planItem.MigrationSpec){$spec=$planItem.MigrationSpec;if([string]$spec.Adapter -ceq 'Certificate'){$channel='Certificate'}elseif([string]$spec.Adapter -ceq 'FileScope'){$channel=$(if($spec.PSObject.Properties['TransferChannel'] -and [string]$spec.TransferChannel){[string]$spec.TransferChannel}else{'C'})}}
        [pscustomobject][ordered]@{ItemId=$failedId;Name=[string]$planItem.Name;Kind=[string]$planItem.Kind;Channel=$channel;ErrorClass=$errorClass;ErrorKind=$typeName;ReasonCode=$reasonCode;RelativeDepth=$relativeDepth;LeafName=$leafName}
    }catch{$null}
}

function ConvertTo-WsmWizardBackupResult($Attempt,[string]$OperationId,$Unreadable=@()) {
    $independentCopy=$(if($Attempt.PSObject.Properties['IndependentCopy']){$Attempt.IndependentCopy}else{$null})
    $itemResults=$(if($Attempt.PSObject.Properties['ItemResults']){$Attempt.ItemResults}else{$null})
    $offlineReport=$(if($Attempt.PSObject.Properties['OfflineReport']){$Attempt.OfflineReport}else{$null})
    $offlineReadiness=$(if(-not (Test-WsmWizardBackupAttemptDelivered $Attempt)){'NotDelivered'}elseif($independentCopy -and $independentCopy.PSObject.Properties['Status'] -and $independentCopy.Status -ceq 'Verified'){[string]$independentCopy.Availability}else{'AwaitingIndependentCopy'})
    # A8：收據完整不等於媒體還在。副本資料夾或交付描述檔已不存在時，不再回報「已驗證」（進度卡與結果頁都吃這個值）。
    if($offlineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed') -and $Attempt.PSObject.Properties['Delivery'] -and $Attempt.Delivery){
        $copyRootText=$(if($independentCopy.PSObject.Properties['CopyRoot']){[string]$independentCopy.CopyRoot}else{''});$copyMedia=$(if($independentCopy.PSObject.Properties['MediaClass']){[string]$independentCopy.MediaClass}else{''})
        if((Test-WsmIndependentCopyReceiptInvalidated $Attempt) -or (Test-WsmIndependentCopyMediaPresent $copyRootText $copyMedia $Attempt.Delivery) -ceq 'Missing'){$offlineReadiness='MediaNeedsReverification'}
    }
    $lastCopyAttempt=$(if($Attempt.PSObject.Properties['IndependentCopyLastAttempt']){$Attempt.IndependentCopyLastAttempt}else{$null})
    $unreadableReport=ConvertTo-WsmWizardUnreadableAttemptReport $Unreadable
    [pscustomobject][ordered]@{Kind='WizardBackupResult';Status=[string]$Attempt.Stage;PairId=[string]$Attempt.PairId;AttemptId=[string]$Attempt.AttemptId;OperationId=$OperationId;StartedByOperationId=[string]$Attempt.StartedByOperationId;Stage=[string]$Attempt.Stage;DeliveryMode=$(if($Attempt.PSObject.Properties['DeliveryMode']){[string]$Attempt.DeliveryMode}else{''});VolumeBytes=$(if($Attempt.PSObject.Properties['VolumeBytes']){[long]$Attempt.VolumeBytes}else{0});Freeze=$Attempt.Freeze;CoreExport=$Attempt.CoreExport;PackageTest=$Attempt.PackageTest;Delivery=$Attempt.Delivery;ChannelSummary=$Attempt.ChannelSummary;NonCStatus=$(if($Attempt.ChannelSummary){[string]$Attempt.ChannelSummary.NonC.Status}else{'Pending'});ResumeStage=$(if($Attempt.PSObject.Properties['ResumeStage']){[string]$Attempt.ResumeStage}else{''});CanResumeAfterReview=((Test-WsmWizardBackupAttemptResumable $Attempt) -and [string]$Attempt.Stage -cin @('Failed','Cancelled'));SourceResumeRequired=([bool]($Attempt.PSObject.Properties['SourceResumeRequired'] -and $Attempt.SourceResumeRequired));AuthoritativeApproval=$true;ProductionVerified=$false;ResumeRequired=[bool](Test-WsmWizardBackupAttemptResumable $Attempt);IndependentCopy=$independentCopy;IndependentCopyLastAttempt=$lastCopyAttempt;OfflineReadiness=$offlineReadiness;ItemResults=$itemResults;OfflineReport=$offlineReport;UnreadableAttemptCount=$unreadableReport.count;UnreadableAttemptFiles=@($unreadableReport.files)}
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
    # R10：無法辨識的紀錄不擋新備份；啟動前掃描一次，結果物件回報檔名清單。
    $startUnreadable=@((Get-WsmWizardBackupAttemptScan (Get-WsmWizardBackupRoot $Workspace $PairId) $Workspace $PairId $profile).Unreadable)
    $operationAttempt=Get-WsmWizardBackupAttemptForOperation $Workspace $PairId $profile $OperationId
    if($operationAttempt){$replaySettings=Get-WsmWizardBackupDeliverySettings $Workspace $PairId $profile $operationAttempt ($PSBoundParameters.ContainsKey('DeliveryMode')) $DeliveryMode ($PSBoundParameters.ContainsKey('VolumeBytes')) $VolumeBytes;return (ConvertTo-WsmWizardBackupResult $operationAttempt.Attempt $OperationId $startUnreadable)}
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
    if($operationAttempt){return (ConvertTo-WsmWizardBackupResult $operationAttempt.Attempt $OperationId $startUnreadable)}
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
            $exportArgs=@{PlanPath=$planRef.Path;ExpectedHash=$planRef.SHA256;SourceStateDirectory=(Join-Path $Workspace 'pairs');MaterialWorkspace=$Workspace;OutputDirectory=$output.PackagesDirectory;CancellationToken=$CancellationToken;AttemptId=$attemptId}
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
    ConvertTo-WsmWizardBackupResult $record $OperationId $startUnreadable
}

function Test-WsmWizardOfflineFullSetPlan($Plan) {
    [bool]($Plan.PSObject.Properties['Assistive'] -and $Plan.Assistive -and $Plan.Assistive.ContractVersion -eq 2)
}

function Get-WsmDriveTypeName([string]$Root) {
    # 觀測縫：只回報磁碟型別名稱，媒體分級的路徑處理才能在不依賴實體磁碟的情況下測試。
    [string](New-Object IO.DriveInfo($Root)).DriveType
}

# R6：判斷 UNC 主機是不是這台機器自己（localhost、本機名稱、環回 IP、本機網卡 IP、ipv6-literal）。
# 只比對名稱與位址，不做 DNS 解析（遠端主機名稱不會在這裡卡住）。
function Test-WsmLocalMachineHostName([string]$HostName) {
    if([string]::IsNullOrWhiteSpace($HostName)){return $false}
    $name=$HostName.Trim().TrimEnd('.')
    if($name -match '^(.+)\.ipv6-literal\.net$'){$name=(($Matches[1] -replace 's.*$','').Replace('-',':'))}
    if($name -ieq 'localhost'){return $true}
    $address=$null
    if([Net.IPAddress]::TryParse($name,[ref]$address)){
        if([Net.IPAddress]::IsLoopback($address)){return $true}
        try{foreach($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()){foreach($unicast in $nic.GetIPProperties().UnicastAddresses){if($unicast.Address.Equals($address)){return $true}}}}catch{}
        return $false
    }
    $short=$name.Split('.')[0]
    if($short -ieq $env:COMPUTERNAME){return $true}
    try{$machine=[Net.Dns]::GetHostName();if($name -ieq $machine -or $short -ieq $machine.Split('.')[0]){return $true}}catch{}
    $false
}

# R6：獨立副本目的地的唯一正規化入口。先走既有的 ConvertTo-WsmCanonicalPath（拒絕裝置路徑 \\?\ \\.\、ADS、..、萬用字元、相對路徑），
# 再判斷 UNC 主機是不是本機：本機別名（\\localhost\C$、\\127.0.0.1\C$、\\本機名稱\C$）折回實體磁碟路徑，依實體磁碟分級；
# 本機的非管理共用無法折回磁碟，LocalPath 為 $null（分級為 Unknown，直接拒絕）。外部主機維持 Network。
function Resolve-WsmIndependentCopyDestination([string]$DestinationRoot) {
    if([string]::IsNullOrWhiteSpace($DestinationRoot)){throw 'Independent copy destination is empty.'}
    $canonical=ConvertTo-WsmCanonicalPath ($DestinationRoot.Trim().Replace('/','\'))
    $isUnc=$canonical.StartsWith('\\');$hostName='';$isLocalAlias=$false;$localPath=$canonical
    if($isUnc){
        $segments=$canonical.Substring(2).Split('\')
        $hostName=[string]$segments[0];$localPath=$null
        if(Test-WsmLocalMachineHostName $hostName){
            $isLocalAlias=$true
            if($segments.Count -ge 2 -and $segments[1] -match '^([A-Za-z])\$$'){$localPath=$Matches[1].ToUpperInvariant()+':\'+((@($segments | Select-Object -Skip 2)) -join '\')}
        }
    }
    [pscustomobject]@{Canonical=$canonical;IsUnc=$isUnc;HostName=$hostName;IsLocalAlias=$isLocalAlias;LocalPath=$localPath}
}

function Get-WsmIndependentCopyMediaClass([string]$DestinationRoot) {
    if([string]::IsNullOrWhiteSpace($DestinationRoot)){return 'Unknown'}
    try{$resolved=Resolve-WsmIndependentCopyDestination $DestinationRoot}catch{return 'Unknown'}
    if($resolved.IsUnc -and -not $resolved.IsLocalAlias){return 'Network'}
    if(-not $resolved.LocalPath){return 'Unknown'}
    try {
        $root=[IO.Path]::GetPathRoot($resolved.LocalPath)
        if([string]::IsNullOrWhiteSpace($root)){return 'Unknown'}
        $dt=Get-WsmDriveTypeName $root
        if($dt -ceq 'Removable'){return 'Removable'}
        if($dt -ceq 'Network'){return 'Network'}
        if($dt -ceq 'Fixed'){return 'LocalFixed'}
        return 'Unknown'
    }catch{
        return 'Unknown'
    }
}

# R6：實體路徑（\Device\HarddiskVolumeN\...，subst／junction／符號連結都已解開）。路徑尚不存在時，解析最近的既有祖先再接回尚未存在的名稱。
function Get-WsmIndependentCopyPhysicalKey([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path).TrimEnd('\');if($cursor.Length -eq 2){$cursor+='\'}
    $tail=New-Object 'System.Collections.Generic.Stack[string]'
    while(-not [IO.Directory]::Exists($cursor) -and -not [IO.File]::Exists($cursor)){
        $trimmed=$cursor.TrimEnd('\');$leaf=[IO.Path]::GetFileName($trimmed);$parent=[IO.Path]::GetDirectoryName($trimmed)
        if(-not $parent -or $parent -ceq $cursor){throw 'Physical location of the independent copy destination cannot be established.'}
        $tail.Push($leaf);$cursor=$parent
    }
    Initialize-WsmPhysicalPathApi
    $physical=([WsmPhysicalPath]::Resolve($cursor)).TrimEnd('\')
    while($tail.Count){$physical+='\'+$tail.Pop()}
    $physical
}

function Test-WsmIndependentCopyInsideWorkspace([string]$LocalPath,[string]$Workspace) {
    $workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')
    $candidate=[IO.Path]::GetFullPath($LocalPath).TrimEnd('\')
    if($candidate -ieq $workspaceFull -or $candidate.StartsWith($workspaceFull+'\',[StringComparison]::OrdinalIgnoreCase)){return $true}
    try{
        $left=(Get-WsmIndependentCopyPhysicalKey $LocalPath).TrimEnd('\');$right=(Get-WsmIndependentCopyPhysicalKey $Workspace).TrimEnd('\')
        return ($left -ieq $right -or $left.StartsWith($right+'\',[StringComparison]::OrdinalIgnoreCase))
    }catch{
        # 安全檢查不可在出錯時放行：實體位置無法確立就拒絕，而不是當成「在工作區外」。
        throw ('Independent copy destination physical location cannot be compared with the source workspace: '+[string]$_.Exception.Message)
    }
}

# R7 收尾：已驗證收據對應的媒體是否已被證明不可信。對「收據的同一個 CopyRoot」做的驗證或複製失敗（不含取消、不含寫入前就拒絕的空間不足）
# 代表那份媒體已和收據不符；收據保留作歷史，但不得再當成已驗證。結果與投影都只看這個判定。
function Test-WsmIndependentCopyReceiptInvalidated($Attempt) {
    if(-not $Attempt -or -not $Attempt.PSObject.Properties['IndependentCopy'] -or -not $Attempt.IndependentCopy){return $false}
    $receipt=$Attempt.IndependentCopy
    return [bool]($receipt.PSObject.Properties['MediaIntegrity'] -and $receipt.MediaIntegrity -and [string]$receipt.MediaIntegrity.Status -ceq 'NeedsReverification')
}

# A8：副本媒體是否還在。Quick 只看副本資料夾與交付描述檔（進度卡每次輪詢都會用）；Full 另讀描述檔（核對雜湊）並逐一確認成員或分卷存在且大小相符（不雜湊內容）。
# 網路位置不在讀取時探測（離線或逾時會卡住畫面），回 NotChecked。回傳 Present／Missing／NotChecked。
function Test-WsmIndependentCopyMediaPresent([string]$CopyRoot,[string]$MediaClass,$Delivery,[switch]$Full) {
    if([string]$MediaClass -ceq 'Network'){return 'NotChecked'}
    try{
        if([string]::IsNullOrWhiteSpace($CopyRoot) -or -not [IO.Directory]::Exists($CopyRoot)){return 'Missing'}
        $mode=[string]$Delivery.Mode
        if($mode -ceq 'Directory'){$descriptorPath=Join-Path $CopyRoot ('transport\'+[IO.Path]::GetFileName([string]$Delivery.Path))}
        elseif($mode -ceq 'Zip'){$descriptorPath=Join-Path $CopyRoot 'transport\transport.json'}
        else{return 'Missing'}
        if(-not [IO.File]::Exists($descriptorPath)){return 'Missing'}
        if(-not $Full){return 'Present'}
        $descriptor=Read-WsmTrustedJson $descriptorPath ([string]$Delivery.SHA256)
        if($mode -ceq 'Directory'){
            foreach($member in @($descriptor.Members)){
                $memberPath=Join-Path $CopyRoot ('transport\delivery\'+([string]$member.Name).Replace('/','\'))
                if(-not [IO.File]::Exists($memberPath) -or (New-Object IO.FileInfo($memberPath)).Length -ne [long]$member.Bytes){return 'Missing'}
            }
        }else{
            foreach($volume in @($descriptor.Volumes)){
                $volumePath=Join-Path $CopyRoot ('transport\'+[string]$volume.Name)
                if(-not [IO.File]::Exists($volumePath) -or (New-Object IO.FileInfo($volumePath)).Length -ne [long]$volume.Bytes){return 'Missing'}
            }
        }
        'Present'
    }catch{'Missing'}
}

# 容量預檢用的可用空間：本機路徑沿用 Get-WsmAvailableBytes（測試替身的觀測縫）；外部 UNC 以最近的既有祖先呼叫 GetDiskFreeSpaceEx。
function Get-WsmIndependentCopyAvailableBytes($Resolved) {
    if($Resolved.LocalPath){return [long](Get-WsmAvailableBytes ([string]$Resolved.LocalPath))}
    $cursor=([string]$Resolved.Canonical).TrimEnd('\')
    while(-not [IO.Directory]::Exists($cursor)){$parent=[IO.Path]::GetDirectoryName($cursor);if(-not $parent -or $parent -ceq $cursor){throw 'Capacity directory is unavailable.'};$cursor=$parent}
    Initialize-WsmAssistiveCapacityApi
    [long][WsmAssistiveCapacity]::Available($cursor.TrimEnd('\')+'\')
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
    $availabilityAttempt=$null;if($Availability -and $Availability.PSObject.Properties['attempt']){$availabilityAttempt=$Availability.attempt}
    if((Test-WsmWizardBackupStageDelivered $stage $availabilityAttempt) -and $hasPackage){
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
    if(-not (Test-WsmWizardBackupAttemptDelivered $attempt) -or -not ($attempt.PSObject.Properties['Delivery'] -and $attempt.Delivery -and $attempt.Delivery.PSObject.Properties['SHA256'] -and $attempt.Delivery.SHA256)){
        throw 'Independent copy requires a delivered backup attempt for this operation.'
    }
    # R6：目的地先走正規化（拒絕裝置路徑、ADS、..、相對路徑）；本機別名 UNC 折回實體磁碟；工作區包含檢查比對實體路徑（subst／junction 換拼法也擋得住）。
    try{$resolved=Resolve-WsmIndependentCopyDestination $DestinationRoot}catch{throw ('Independent copy destination is not an allowed path: '+$_.Exception.Message)}
    $destination=[string]$resolved.Canonical
    if($resolved.LocalPath -and (Test-WsmIndependentCopyInsideWorkspace ([string]$resolved.LocalPath) $Workspace)){
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
    $capacity=[pscustomobject][ordered]@{Status='NotApplicable';RequiredBytes=[long]0;AvailableBytes=[long]0;Warning=''}
    try {
        if($Mode -ceq 'Copy'){
            # 容量預檢：寫入任何檔案之前先比較目的地可用空間與還沒複製到位的位元組數（算式沿用 Get-WsmAssistiveCapacityRequiredBytes，含 256 MiB 緩衝）。
            # 空間不足就以穩定原因碼 InsufficientSpace 拒絕，不留半寫的副本、不動先前的收據；取不到可用空間（例如 UNC 查詢失敗）則警告後允許，並寫進收據。
            $neededBytes=[long]0
            foreach($file in $filesToCopy){if([IO.File]::Exists($file.Dest) -and (New-Object IO.FileInfo($file.Dest)).Length -eq [long]$file.Bytes){continue};$neededBytes+=[long]$file.Bytes}
            $requiredBytes=[long](Get-WsmAssistiveCapacityRequiredBytes $neededBytes)
            $availableBytes=$null;$capacityWarning=''
            try{$availableBytes=[long](Get-WsmIndependentCopyAvailableBytes $resolved)}catch{$capacityWarning=('無法讀取目的地的可用空間（'+[string]$_.Exception.Message+'）；已繼續複製，空間不足時會在複製中途失敗，先前的收據不受影響。');if($capacityWarning.Length -gt 300){$capacityWarning=$capacityWarning.Substring(0,300)}}
            if($null -ne $availableBytes -and $availableBytes -lt $requiredBytes){
                $spaceError=New-Object InvalidOperationException ('InsufficientSpace: the destination has '+$availableBytes+' bytes free but the independent copy needs '+$requiredBytes+' bytes (including a 256 MiB reserve). Free space on the destination or choose another location, then copy again.')
                $spaceError.Data['WsmErrorCode']='InsufficientSpace';$spaceError.Data['RequiredBytes']=$requiredBytes;$spaceError.Data['AvailableBytes']=$availableBytes
                throw $spaceError
            }
            $capacity=[pscustomobject][ordered]@{Status=$(if($null -ne $availableBytes){'Sufficient'}else{'Unknown'});RequiredBytes=$requiredBytes;AvailableBytes=$(if($null -ne $availableBytes){[long]$availableBytes}else{[long]0});Warning=$capacityWarning}
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
            CapacityCheck=$capacity
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
            CapacityCheck=$capacity
        }
        if($attempt.PSObject.Properties['IndependentCopy']){$attempt.IndependentCopy=$indObj}else{Add-Member -InputObject $attempt -NotePropertyName IndependentCopy -NotePropertyValue $indObj}
        # 成功就清掉先前失敗／取消的 LastAttempt，避免結果頁一直顯示過期的「較新的嘗試」。
        if($attempt.PSObject.Properties['IndependentCopyLastAttempt']){$attempt.PSObject.Properties.Remove('IndependentCopyLastAttempt')}
        $attempt.UpdatedUtc=Get-WsmUtc
        Write-WsmWizardBackupAttempt $attemptPath $attempt $Workspace
    } catch {
        $errText=[string]$_.Exception.Message
        if($errText.Length -gt 300){$errText=$errText.Substring(0,300)}
        # R7：失敗或取消不抹掉先前已驗證的收據。本次結果另存成 LastAttempt（Failed 與 Cancelled 分開，含時間、原因碼與下一步）；
        # 只有先前沒有 Verified 收據時，才維持舊行為把 IndependentCopy 記成 Failed／Cancelled。
        $wasCancelled=[bool]$_.Exception.Data['CancellationRequested']
        $failureCode=$(if($wasCancelled){'Cancelled'}elseif($_.Exception.Data['WsmErrorCode']){[string]$_.Exception.Data['WsmErrorCode']}elseif($Mode -ceq 'VerifyExisting'){'VerifyFailed'}else{'CopyFailed'})
        $nextStepText=switch -CaseSensitive ($failureCode) {
            'Cancelled' {'複製已依要求停止；先前已驗證的收據仍有效。要重新複製請再執行一次獨立副本，已複製且相符的檔案會直接沿用。'}
            'InsufficientSpace' {'目的地空間不足，沒有寫入任何檔案。請釋出空間或換一個目的地後再執行；先前已驗證的收據不受影響。'}
            'VerifyFailed' {'副本媒體上的檔案缺少或與收據不符。請確認媒體已接上並完整，或改用「由工具複製並驗證」重新建立副本。'}
            default {'複製沒有完成，先前已驗證的收據不受影響。請檢查目的地與原因後再執行一次獨立副本。'}
        }
        $lastAttempt=[ordered]@{Status=$(if($wasCancelled){'Cancelled'}else{'Failed'});Code=$failureCode;Reason=$errText;NextStep=$nextStepText;AttemptedUtc=(Get-WsmUtc);Mode=$Mode;MediaClass=$mediaClass;CopyRoot=[IO.Path]::GetFullPath($copyRoot)}
        if($failureCode -ceq 'InsufficientSpace'){$lastAttempt['RequiredBytes']=[long]$_.Exception.Data['RequiredBytes'];$lastAttempt['AvailableBytes']=[long]$_.Exception.Data['AvailableBytes']}
        $lastAttemptObj=[pscustomobject]$lastAttempt
        if($attempt.PSObject.Properties['IndependentCopyLastAttempt']){$attempt.IndependentCopyLastAttempt=$lastAttemptObj}else{Add-Member -InputObject $attempt -NotePropertyName IndependentCopyLastAttempt -NotePropertyValue $lastAttemptObj}
        $hasVerifiedReceipt=($attempt.PSObject.Properties['IndependentCopy'] -and $attempt.IndependentCopy -and $attempt.IndependentCopy.PSObject.Properties['Status'] -and [string]$attempt.IndependentCopy.Status -ceq 'Verified')
        if($hasVerifiedReceipt -and -not $wasCancelled -and $failureCode -cne 'InsufficientSpace'){
            $receiptRoot=$(if($attempt.IndependentCopy.PSObject.Properties['CopyRoot']){[string]$attempt.IndependentCopy.CopyRoot}else{''})
            $sameMedia=$false;try{$sameMedia=[bool]$receiptRoot -and [string]::Equals([IO.Path]::GetFullPath($receiptRoot).TrimEnd('\'),[IO.Path]::GetFullPath($copyRoot).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)}catch{$sameMedia=$true}
            if($sameMedia){
                # 失敗發生在收據自己的媒體上：重新驗證不符、目的地內容與收據不同或複製後驗證失敗，都證明這份媒體已不可信。
                $integrity=[pscustomobject][ordered]@{Status='NeedsReverification';Code=$failureCode;DetectedUtc=(Get-WsmUtc)}
                if($attempt.IndependentCopy.PSObject.Properties['MediaIntegrity']){$attempt.IndependentCopy.MediaIntegrity=$integrity}else{Add-Member -InputObject $attempt.IndependentCopy -NotePropertyName MediaIntegrity -NotePropertyValue $integrity}
                $lastAttemptObj.NextStep='這份獨立副本的媒體與收據不符，已不能當成已驗證的離線還原材料。請改用一個空的目的地重新建立副本，確認媒體後再按「重新驗證」。'
            }
        }
        if(-not $hasVerifiedReceipt){
            $failedObj=[pscustomobject]@{
                Status=$(if($wasCancelled){'Cancelled'}else{'Failed'})
                Availability='NotVerified'
                MediaClass=$mediaClass
                CopyRoot=[IO.Path]::GetFullPath($copyRoot)
                Error=$errText
                UpdatedUtc=Get-WsmUtc
            }
            if($attempt.PSObject.Properties['IndependentCopy']){$attempt.IndependentCopy=$failedObj}else{Add-Member -InputObject $attempt -NotePropertyName IndependentCopy -NotePropertyValue $failedObj}
        }
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
