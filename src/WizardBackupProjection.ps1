function Get-WsmWizardBackupAvailability([string]$Workspace,[string]$PairId,$Profile=$null,[object[]]$Jobs=@()) {
    if(-not $Workspace -or -not $PairId){return $null}
    $workspacePath=[IO.Path]::GetFullPath($Workspace)
    if(-not $Profile){try{$Profile=Read-WsmOutputProfile $workspacePath}catch{return $null}}
    if(-not $Profile -or [string]$Profile.Role -cne 'Source'){return $null}
    $planRef=Get-WsmWizardReceivedApprovedPlan $workspacePath $PairId $Profile
    if(-not $planRef){return $null}
    $plan=$planRef.Plan
    $root=Join-Path (Join-Path (Join-Path $workspacePath 'workspace-control') 'wizard-backups') $PairId
    if(-not [IO.Directory]::Exists($root)){return $null}
    Assert-WsmNoReparse $root

    $acceptedJobs=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($Jobs)){
        if(-not $job){continue}
        $wellFormed=$true;foreach($name in @('jobId','action','status','role','workspace','pairId','outputs')){if(-not $job.PSObject.Properties[$name]){$wellFormed=$false;break}};if(-not $wellFormed){continue}
        if([string]$job.action -cne 'StartBackup' -or [string]$job.role -cne 'Source' -or [string]$job.pairId -cne $PairId){continue}
        try{if([IO.Path]::GetFullPath([string]$job.workspace) -ine $workspacePath){continue};Assert-WsmId ([string]$job.jobId)}catch{continue}
        if([string]$job.status -cnotin @('Succeeded','Failed','Cancelled','Interrupted','ReviewRequired')){continue}
        $acceptedJobs.Add($job)
    }

    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)){
        Assert-WsmNoReparse $file.FullName
        try{$attempt=Read-WsmJson $file.FullName;Assert-WsmWizardBackupAttempt $attempt $workspacePath $PairId $Profile|Out-Null}catch{continue}
        if([string]$attempt.PlanHash -ine [string]$planRef.SHA256 -or [string]$attempt.InventoryHash -ine [string]$plan.InventoryHash -or [int]$attempt.InventoryRevision -ne [int]$plan.InventoryRevision){continue}
        if([string]$attempt.HostId -cne [string]$Profile.HostId -or [string]$plan.Source.HostId -cne [string]$Profile.HostId -or [string]$plan.Source.Fingerprint -ine [string]$Profile.Fingerprint){continue}
        $operationIds=@([string]$attempt.StartedByOperationId)
        if($attempt.PSObject.Properties['OperationIds']){$operationIds=@($attempt.OperationIds|ForEach-Object {[string]$_})}
        foreach($job in $acceptedJobs){
            if($operationIds -cnotcontains [string]$job.jobId){continue}
            $bound=$false
            foreach($output in @($job.outputs)){
                if($output -and $output.PSObject.Properties['AttemptId'] -and [string]$output.AttemptId -ceq [string]$attempt.AttemptId){$bound=$true;break}
            }
            if(-not $bound){continue}
            $stage=[string]$attempt.Stage;$jobStatus=[string]$job.status;$sourceRecoveryPending=[bool](($attempt.PSObject.Properties['SourceResumeRequired'] -and $attempt.SourceResumeRequired) -or ($attempt.PSObject.Properties['SourceResumeFreshFreezePending'] -and $attempt.SourceResumeFreshFreezePending))
            $stageMatches=switch($jobStatus){
                'Succeeded' { $stage -in @('Delivered','ReviewRequired') }
                'Failed' { $stage -ceq 'Failed' -or ($stage -ceq 'ReviewRequired' -and $sourceRecoveryPending) }
                'Cancelled' { $stage -ceq 'Cancelled' -or ($stage -ceq 'ReviewRequired' -and $sourceRecoveryPending) }
                'Interrupted' { $stage -in @('Authorized','CoreExported','PackageVerified','ReviewRequired') }
                'ReviewRequired' { $stage -ceq 'ReviewRequired' }
                default { $false }
            }
            if(-not $stageMatches){continue}

            $generation=$null;$packageValid=$false;$deliveryValid=$false
            if($attempt.CoreExport -and $attempt.CoreExport.PSObject.Properties['Generation']){
                try{$g=[int]$attempt.CoreExport.Generation;if($g -ge 1){$generation=$g}}catch{}
            }
            if($attempt.PackageTest -and $attempt.CoreExport -and $attempt.PackageTest.PSObject.Properties['Valid'] -and [bool]$attempt.PackageTest.Valid -and $generation -and $attempt.PackageTest.PSObject.Properties['Generation'] -and [int]$attempt.PackageTest.Generation -eq $generation -and [string]$attempt.PackageTest.PlanHash -ieq [string]$planRef.SHA256 -and [string]$attempt.PackageTest.SHA256 -match '^[a-fA-F0-9]{64}$' -and [string]$attempt.PackageTest.SHA256 -ieq [string]$attempt.CoreExport.SHA256){$packageValid=$true}
            if($packageValid){
                try{
                    $manifestPath=[IO.Path]::GetFullPath([string]$attempt.PackageTest.ManifestPath);Assert-WsmNoReparse $manifestPath
                    if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine [string]$attempt.PackageTest.SHA256){throw 'Package manifest bytes changed.'}
                    $manifest=Read-WsmJson $manifestPath;Assert-WsmEnvelope $manifest 'MigrationPackage';Assert-WsmPackageHeaderContract $manifest
                    if($manifest.PairId -cne $PairId -or $manifest.PlanHash -ine $planRef.SHA256 -or [int]$manifest.Generation -ne $generation){throw 'Package manifest binding changed.'}
                }catch{$packageValid=$false}
            }
            if($packageValid -and $attempt.Delivery -and $attempt.Delivery.PSObject.Properties['Path'] -and $attempt.Delivery.PSObject.Properties['SHA256'] -and [string]$attempt.Delivery.SHA256 -match '^[a-fA-F0-9]{64}$'){
                try{$deliveryPath=[IO.Path]::GetFullPath([string]$attempt.Delivery.Path);Assert-WsmNoReparse $deliveryPath;if([IO.File]::Exists($deliveryPath) -and (Get-FileHash -LiteralPath $deliveryPath -Algorithm SHA256).Hash -ieq [string]$attempt.Delivery.SHA256){$deliveryValid=$true}}catch{}
            }
            # Keep a bound but damaged newest generation visible. Discarding it
            # here would let an older successful generation become current.
            $damagedMaterial=($stage -in @('Delivered','ReviewRequired') -and (-not $packageValid -or -not $deliveryValid))
            if($stage -eq 'ReviewRequired' -and $packageValid -and $attempt.Delivery -and [string]$attempt.Delivery.SHA256 -match '^[a-fA-F0-9]{64}$'){$deliveryValid=([bool]$deliveryValid)}

            $status=switch($jobStatus){'Succeeded'{if($stage -eq 'Delivered'){'Completed'}else{'ReviewRequired'}}'Failed'{'Failed'}'Cancelled'{'Cancelled'}'Interrupted'{'Prepared'}'ReviewRequired'{'ReviewRequired'}}
            if($damagedMaterial){$status='MaterialUnavailable'}
            $time='';if($job.PSObject.Properties['CompletedUtc']){try{$time=[DateTimeOffset]::Parse([string]$job.CompletedUtc).ToUniversalTime().ToString('o')}catch{}}
            if(-not $time -and $attempt.PSObject.Properties['UpdatedUtc']){try{$time=[DateTimeOffset]::Parse([string]$attempt.UpdatedUtc).ToUniversalTime().ToString('o')}catch{}}
            $rows.Add([pscustomobject][ordered]@{status=$status;stage=$stage;jobStatus=$jobStatus;attemptId=[string]$attempt.AttemptId;runId=[string]$job.jobId;generation=$generation;producedUtc=$time;current=$false;hasDurableRecord=$true;hasPackage=($packageValid -and $deliveryValid);attempt=$attempt;planHash=[string]$attempt.PlanHash;inventoryHash=[string]$attempt.InventoryHash;inventoryRevision=[int]$attempt.InventoryRevision;coreExport=$(if($packageValid){$attempt.CoreExport}else{$null});packageTest=$(if($packageValid){$attempt.PackageTest}else{$null});delivery=$(if($deliveryValid){$attempt.Delivery}else{$null});channelSummary=$attempt.ChannelSummary;operationId=[string]$job.jobId})
        }
    }
    if(-not $rows.Count){return $null}
    $known=@($rows|Where-Object {$null -ne $_.generation})
    $latestGeneration=0
    if($known.Count){$latestGeneration=[int](($known|Measure-Object -Property generation -Maximum).Maximum)}
    $latestGenerationTime=[DateTimeOffset]::MinValue
    foreach($knownRow in @($known|Where-Object {[int]$_.generation -eq $latestGeneration})){
        try{$candidateTime=[DateTimeOffset]::Parse([string]$knownRow.producedUtc);if($candidateTime -gt $latestGenerationTime){$latestGenerationTime=$candidateTime}}catch{}
    }
    foreach($row in $rows){
        if($null -ne $row.generation){$row.current=([int]$row.generation -eq $latestGeneration)}
        elseif(-not $known.Count){$row.current=$true}
        else{try{$row.current=([DateTimeOffset]::Parse([string]$row.producedUtc) -ge $latestGenerationTime)}catch{$row.current=$false}}
    }
    $currentRows=@($rows|Where-Object current|Sort-Object @{Expression={try{[DateTimeOffset]::Parse([string]$_.producedUtc)}catch{[DateTimeOffset]::MinValue}};Descending=$true},@{Expression='runId';Descending=$true})
    if($currentRows.Count){return $currentRows[0]}
    $null
}

function ConvertTo-WsmProgressText([object]$Value) {
    if($null -eq $Value){return ''}
    $text=[string]$Value -replace '[\x00-\x1f\x7f]+',' '
    $text=[regex]::Replace($text,'(?i)(password|passwd|pwd|token|secret|credential|api[-_]?key)\s*[:=]\s*[^\s;,]+','$1=[redacted]')
    $text=$text.Trim()
    if($text.Length -gt 256){$text=$text.Substring(0,256)}
    $text
}

function Get-WsmHtmlLegacyProgressProjection($Job) {
    $worker=Get-WsmTextMetadataValue $Job 'PowerShell';$jobRecord=Get-WsmTextMetadataValue $Job 'Record'
    if(-not $worker -or -not $worker.Streams -or -not $worker.Streams.Progress.Count){return $null}
    $streamCount=$worker.Streams.Progress.Count;$record=$worker.Streams.Progress[$streamCount-1]
    for($progressIndex=$streamCount-1;$progressIndex -ge 0;$progressIndex--){$candidateRecord=$worker.Streams.Progress[$progressIndex];if($candidateRecord.ActivityId -eq 32 -and $candidateRecord.RecordType -ne 'Completed'){$record=$candidateRecord;break}}
    $percent=$null;try{$candidate=[int]$record.PercentComplete;if($candidate -ge 0 -and $candidate -le 100){$percent=$candidate}}catch{}
    $processedCount=$null
    foreach($source in @($Job,$jobRecord)){$value=Get-WsmTextMetadataValue $source 'processedCount';if($null -ne $value){try{$count=[long]$value;if($count -ge 0){$processedCount=$count;break}}catch{}}}
    $activity=ConvertTo-WsmProgressText $record.Activity;$status=ConvertTo-WsmProgressText $record.StatusDescription;$operation=ConvertTo-WsmProgressText $record.CurrentOperation
    $previous=Get-WsmTextMetadataValue $jobRecord 'progress';$observedCount=Get-WsmTextMetadataValue $Job 'ObservedProgressCount';$updated=Get-WsmUtc
    if($previous -and $null -ne $observedCount -and [int]$observedCount -eq $streamCount -and [string]$previous.activity -ceq $activity -and [string]$previous.statusDescription -ceq $status -and [string]$previous.currentOperation -ceq $operation -and $previous.percent -eq $percent -and $previous.processedCount -eq $processedCount){$updated=[string]$previous.updatedUtc}
    if($Job -is [Collections.IDictionary]){$Job['ObservedProgressCount']=$streamCount}else{$Job|Add-Member NoteProperty ObservedProgressCount $streamCount -Force}
    [pscustomobject][ordered]@{activity=$activity;statusDescription=$status;currentOperation=$operation;percent=$percent;processedCount=$processedCount;updatedUtc=$updated}
}

# F1-P seven-state mapping (pure; every row has a test in tests/Test-WizardBackupProgress.ps1).
# Inputs are existing facts only: the console job status, the durable attempt Stage, the OfflineReadiness that
# ConvertTo-WsmWizardBackupResult derives, and the number of items the producer recorded as Failed.
#   job.status          other facts                                              -> State           (label)
#   Queued / WaitingForInput / anything unknown / empty                          -> Waiting         等待中
#   Running                                                                      -> Running         執行中
#   CancelRequested                                                              -> CancelRequested 取消要求中
#   Succeeded           FailedCount > 0                                          -> PartialFailure  部分失敗
#   Succeeded           attempt Stage Delivered and a verified independent copy
#                       (OfflineReadiness Verified / VerifiedNetworkAvailabilityUnconfirmed)
#                                                                                -> Completed       完成
#   Succeeded           otherwise (OfflineReadiness AwaitingIndependentCopy,
#                       NotDelivered or unreadable)                              -> AwaitingDelivery 等待交付 (never success)
#   ReviewRequired      unresolved items or recovery pending                     -> PartialFailure  部分失敗
#   Failed                                                                       -> Failed          失敗
#   Cancelled                                                                    -> Failed          失敗 (EndReason Cancelled)
#   Interrupted                                                                  -> Failed          失敗 (EndReason Interrupted)
# The seven states have no separate "cancelled" or "interrupted" state, so those two end as Failed and keep the
# real reason in EndReason for the UI to show next to the label.
function Get-WsmBackupProgressState([string]$JobStatus,[string]$AttemptStage='',[string]$OfflineReadiness='',[int]$FailedCount=0) {
    $state='Waiting';$endReason=''
    switch -CaseSensitive ($JobStatus) {
        'Running' {$state='Running'}
        'CancelRequested' {$state='CancelRequested'}
        'Succeeded' {
            if($FailedCount -gt 0){$state='PartialFailure'}
            elseif($AttemptStage -ceq 'Delivered' -and $OfflineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed')){$state='Completed'}
            else{$state='AwaitingDelivery'}
        }
        'ReviewRequired' {$state='PartialFailure'}
        'Failed' {$state='Failed'}
        'Cancelled' {$state='Failed';$endReason='Cancelled'}
        'Interrupted' {$state='Failed';$endReason='Interrupted'}
        default {$state='Waiting'}
    }
    [pscustomobject][ordered]@{State=$state;EndReason=$endReason}
}

function Get-WsmBackupProgressStageLabel([string]$Stage) {
    switch -CaseSensitive ($Stage) {'Capture'{'擷取與封存'}'Verify'{'驗證封裝'}'Deliver'{'交付'}default{''}}
}

# Closed projection of one durable progress record for the HTML job card. The producer file is the only source of
# progress facts; the job status (and, once finished, the attempt) decides the state. Every string and number
# crosses ConvertTo-WsmWizardHtmlValue so unknown fields, secrets patterns and oversized text cannot pass.
function ConvertTo-WsmWizardBackupProgressView($Raw,[string]$JobStatus,[string]$AttemptStage='',[string]$OfflineReadiness='') {
    if(-not $Raw){return $null}
    $failed=0;if($Raw.PSObject.Properties['FailedCount']){try{$failed=[int]$Raw.FailedCount}catch{}}
    $stateRow=Get-WsmBackupProgressState $JobStatus $AttemptStage $OfflineReadiness $failed
    $names=$null;if($Raw.PSObject.Properties['ItemNames']){$names=$Raw.ItemNames}
    $recent=@(foreach($entry in @($Raw.Recent|Select-Object -Last 20)){
        if(-not $entry){continue}
        $id=[string]$entry.ItemId;$name='';if($names -and $names.PSObject.Properties[$id]){$name=ConvertTo-WsmProgressText $names.PSObject.Properties[$id].Value}
        [pscustomobject][ordered]@{ItemId=(ConvertTo-WsmProgressText $id);ItemName=$name;Result=(ConvertTo-WsmProgressText $entry.Result)}
    })
    $itemsDone=$null;if($null -ne $Raw.ItemsDone){$itemsDone=[long]$Raw.ItemsDone}
    $itemsTotal=$null;if($null -ne $Raw.ItemsTotal){$itemsTotal=[long]$Raw.ItemsTotal}
    $bytesTotal=$null;if($null -ne $Raw.BytesTotal){$bytesTotal=[long]$Raw.BytesTotal}
    $percent=$null
    if([string]$Raw.Stage -ceq 'Capture' -and $null -ne $itemsTotal -and $itemsTotal -gt 0 -and $null -ne $itemsDone){$percent=[int][Math]::Min(99,[Math]::Floor(100*[double]$itemsDone/[double]$itemsTotal))}
    elseif([bool]$Raw.Terminal -and [string]$Raw.Outcome -ceq 'Succeeded'){$percent=100}
    # N2: records written before the item fields existed are shown as unrecorded, never as an empty or zero value.
    $itemRecorded=[bool]($Raw.PSObject.Properties['CurrentItemId'] -and $Raw.PSObject.Properties['CurrentChannel'] -and $Raw.PSObject.Properties['FilesDone'])
    $channelCode='Unknown';$channelLabel='未記錄';$itemId='';$itemType='';$itemTypeLabel='未記錄';$filesDone=$null;$filesTotal=$null
    if($itemRecorded){
        $channelCode=[string]$Raw.CurrentChannel;$channelLabel=switch -CaseSensitive ($channelCode){'C'{'C 槽'}'NonC'{'非 C 槽'}default{'未知'}}
        if($channelLabel -ceq '未知'){$channelCode='Unknown'}
        $itemId=ConvertTo-WsmProgressText $Raw.CurrentItemId;$itemType=ConvertTo-WsmProgressText $Raw.CurrentItemType;$itemTypeLabel=ConvertTo-WsmProgressText $Raw.CurrentItemTypeLabel
        if($null -ne $Raw.FilesDone){$filesDone=[long]$Raw.FilesDone}
        if($Raw.PSObject.Properties['FilesTotal'] -and $null -ne $Raw.FilesTotal){$filesTotal=[long]$Raw.FilesTotal}
    }
    $view=[ordered]@{
        Stage=[string]$Raw.Stage;StageLabel=(Get-WsmBackupProgressStageLabel ([string]$Raw.Stage));StageIndex=[int]$Raw.StageIndex;StageCount=[int]$Raw.StageCount
        Workload=(ConvertTo-WsmProgressText $Raw.Workload);CurrentFile=(ConvertTo-WsmProgressText $Raw.CurrentFile)
        ItemFieldsRecorded=$itemRecorded;CurrentItemId=$itemId;CurrentItemType=$itemType;CurrentItemTypeLabel=$itemTypeLabel;CurrentChannel=$channelCode;CurrentChannelLabel=$channelLabel;FilesDone=$filesDone;FilesTotal=$filesTotal
        ItemsDone=$itemsDone;ItemsTotal=$itemsTotal;BytesDone=$(if($null -ne $Raw.BytesDone){[long]$Raw.BytesDone}else{$null});BytesTotal=$bytesTotal;Percent=$percent
        StartedUtc=[string]$Raw.StartedUtc;UpdatedUtc=[string]$Raw.UpdatedUtc;Recent=$recent;FailedCount=$failed;Terminal=[bool]$Raw.Terminal;Outcome=[string]$Raw.Outcome
        State=[string]$stateRow.State;EndReason=[string]$stateRow.EndReason
    }
    ConvertTo-WsmWizardHtmlValue ([pscustomobject]$view)
}

# Read back the progress of one StartBackup console job by its parent job id (== the backup OperationId). Works for a
# running job, for a finished job and after a console restart, because it only reads the durable progress file. A short
# per-job cache keeps the console loop (which calls this for every job on every pass) from re-reading the disk.
function Get-WsmHtmlBackupProgress($Job) {
    $jobRecord=Get-WsmTextMetadataValue $Job 'Record'
    if(-not $jobRecord -or [string](Get-WsmTextMetadataValue $jobRecord 'action' '') -cne 'StartBackup'){return $null}
    $jobStatus=[string](Get-WsmTextMetadataValue $jobRecord 'status' '');$workspace=[string](Get-WsmTextMetadataValue $jobRecord 'workspace' '');$pair=[string](Get-WsmTextMetadataValue $jobRecord 'pairId' '');$operation=[string](Get-WsmTextMetadataValue $jobRecord 'jobId' '')
    if(-not $workspace -or -not $pair -or -not $operation){return $null}
    $nowTicks=[DateTime]::UtcNow.Ticks;$cache=Get-WsmTextMetadataValue $Job 'BackupProgressCache'
    if($cache -and [string]$cache.Status -ceq $jobStatus){
        $ageMs=($nowTicks-[long]$cache.Ticks)/10000
        $ttl=if($jobStatus -cin @('Running','CancelRequested','Queued','WaitingForInput')){1000}elseif($jobStatus -ceq 'Succeeded'){10000}elseif($null -eq $cache.Value){5000}else{[double]::MaxValue}
        if($ageMs -lt $ttl){return $cache.Value}
    }
    $view=$null
    try{
        $raw=Read-WsmWizardBackupProgress $workspace $pair $operation
        if($raw){
            $attemptStage='';$offline=''
            if($jobStatus -cin @('Succeeded','ReviewRequired')){
                try{$profile=Read-WsmOutputProfile $workspace;$bound=Get-WsmWizardBackupAttemptForOperation $workspace $pair $profile $operation;if($bound){$result=ConvertTo-WsmWizardBackupResult $bound.Attempt $operation;$attemptStage=[string]$result.Stage;$offline=[string]$result.OfflineReadiness}}catch{}
            }
            $view=ConvertTo-WsmWizardBackupProgressView $raw $jobStatus $attemptStage $offline
        }
    }catch{$view=$null}
    $entry=[pscustomobject]@{Status=$jobStatus;Ticks=$nowTicks;Value=$view}
    if($Job -is [Collections.IDictionary]){$Job['BackupProgressCache']=$entry}else{$Job|Add-Member NoteProperty BackupProgressCache $entry -Force}
    $view
}

function Get-WsmHtmlProgressProjection($Job) {
    $legacy=Get-WsmHtmlLegacyProgressProjection $Job
    $backup=Get-WsmHtmlBackupProgress $Job
    if(-not $backup){return $legacy}
    if(-not $legacy){$legacy=[pscustomobject][ordered]@{activity='';statusDescription='';currentOperation='';percent=$null;processedCount=$null;updatedUtc=[string]$backup.UpdatedUtc}}
    $legacy|Add-Member NoteProperty backup $backup -Force
    $legacy
}

# RestoreCondition decision table (first match wins). Inputs are facts already in
# the plan or inventory item; nothing is inferred from names or paths.
#   Status is not BackedUp                                   -> NotApplicable
#   Classification.Disposition SpecialProduct / Preparation  -> ManualOnly
#   Channel Certificate, or Kind IISSite / IISPool / IIS*Config / ScheduledTask / Service / TaskFolder
#     (needs IIS role, service binaries, account or key password first) -> RequiresPrerequisite
#     IIS configuration is only BackedUp when an owner supplied a typed section spec; the default
#     ManualWorkflow draft is NotBackedUp (ManualHandling) and therefore NotApplicable above.
#   anything else that was backed up                          -> Restorable
function Get-WsmBackupRestoreCondition([string]$Status,[string]$Kind,[string]$Channel,[string]$ClassificationDisposition) {
    $text=@{
        Restorable='可由本工具還原'
        RequiresPrerequisite='可還原，但需先安裝軟體、角色或補齊帳密等前置條件'
        ManualOnly='只能人工處理，工具不會自動還原'
        NotApplicable='未備份，沒有可還原的內容'
    }
    $code='Restorable'
    if($Status -cne 'BackedUp'){$code='NotApplicable'}
    elseif($ClassificationDisposition -cin @('SpecialProduct','Preparation')){$code='ManualOnly'}
    elseif($Channel -ceq 'Certificate' -or $Kind -cin @('IISSite','IISPool','IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig','ScheduledTask','Service','TaskFolder')){$code='RequiresPrerequisite'}
    [pscustomobject][ordered]@{Code=$code;Text=$text[$code]}
}

function Get-WsmBackupCoverageRegions([string]$InventorySource,[object[]]$SoftwareCoverageGaps) {
    # Regions, not items: scopes the discovery could not fully cover.
    $statusText=@{Partial='只取得部分資料';Failed='取得失敗';PermissionDenied='權限不足';Unsupported='此環境不支援';NotInstalled='未安裝'}
    $regions=New-Object 'System.Collections.Generic.List[object]'
    if($InventorySource -ceq 'Unavailable'){
        $regions.Add([pscustomobject][ordered]@{Region='來源盤點整體';Status='Unavailable';Reason='無法取得來源盤點，探索範圍未知';NextStep='重新執行來源盤點後再備份'})
    }
    foreach($gap in @($SoftwareCoverageGaps)){
        if($null -eq $gap){continue}
        $parts=New-Object 'System.Collections.Generic.List[string]'
        foreach($field in @('Probe','Scope','SID','View')){if($gap.PSObject.Properties[$field] -and [string]$gap.$field){$parts.Add([string]$gap.$field)}}
        $status=[string]$gap.Status
        $reason=$(if($statusText.ContainsKey($status)){$statusText[$status]}else{'未完整取得（'+$status+'）'})
        if($gap.PSObject.Properties['ErrorKind'] -and [string]$gap.ErrorKind){$reason+='：'+[string]$gap.ErrorKind}
        $regions.Add([pscustomobject][ordered]@{Region=('已安裝軟體盤點'+$(if($parts.Count){'：'+($parts -join ' / ')}else{''}));Status=$status;Reason=$reason;NextStep='以具備權限的帳號重新盤點此範圍，或人工確認該範圍的軟體'})
    }
    @($regions.ToArray())
}

# N3: policy exclusions (套裝本體 / 受保護區域) of the candidate scan the approved plan is bound to.
# These are REGIONS, not items, so they live in their own ExcludedRegions list (CoverageRegions means "the discovery could
# not see this"; ExcludedRegions means "the policy deliberately skipped this"). Keeping them apart also lets the result set
# say "not recorded" (null) without disturbing the existing coverage states.
#   BundleExcluded  an installed-software root or Program Files location excluded by the scan policy
#   ProtectedArea   Windows directory, the tool workspace, Config.Msi or a FileScope-guard protected path
# The class comes from the recorded policy reason text of the scan row, never from a guess about names.
function Get-WsmBackupExcludedRegionClass([string]$SourceReason,[string]$Workspace) {
    $prefix='Protected or package area excluded by policy: '
    $tail=[string]$SourceReason
    if($tail.StartsWith($prefix,[StringComparison]::Ordinal)){$tail=$tail.Substring($prefix.Length)}
    if($tail -like 'FileScope guard: *' -or $tail -notmatch '^[A-Za-z]:\\'){return 'ProtectedArea'}
    if($tail -imatch '^[A-Za-z]:\\Windows\\?$'){return 'ProtectedArea'}
    $workspaceFull='';try{if($Workspace){$workspaceFull=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')}}catch{}
    if($workspaceFull -and $tail.TrimEnd('\') -ieq $workspaceFull){return 'ProtectedArea'}
    'BundleExcluded'
}

# N9d：安裝根內容分類的顯示用文字。結果集只存代碼與計數，文字在這裡統一產生，讓工作台與離線報告用同一份。
function Get-WsmBackupBundleClassText([string]$Class) {
    switch($Class){
        'Bundle'{'本體（可執行檔或安裝程式登記）'}
        'SuspectedBusinessData'{'疑似業務資料（需人工處置）'}
        'Unknown'{'未知'}
        default{$Class}
    }
}

function Get-WsmBackupBundleWhyText([string]$Why) {
    if($Why -like 'DataDirectory:*'){return ('位於資料／報表類子目錄「'+$Why.Substring('DataDirectory:'.Length)+'」')}
    switch($Why){
        'PEHeader'{'檔頭為可執行檔（PE）'}
        'RegisteredByInstaller'{'安裝程式登記的檔案'}
        'UninstallMetadata'{'反安裝中繼資料'}
        'ModifiedAfterInstall'{'修改時間晚於安裝時間'}
        'NoSignal'{'沒有可辨識的訊號'}
        default{$Why}
    }
}

# 掃描列的 Contents 重新整形：只留已知欄位、數值與長度設上限；格式不對就當作「未記錄」（回傳 $null），不做部分採信。
function ConvertTo-WsmBackupExcludedContents($Contents) {
    if($null -eq $Contents -or $Contents -is [string] -or $Contents -is [ValueType] -or $Contents -is [array]){return $null}
    try{
        if(-not $Contents.PSObject.Properties['Counts'] -or $null -eq $Contents.Counts){return $null}
        $counts=[ordered]@{}
        foreach($name in @('Bundle','SuspectedBusinessData','Unknown')){
            if(-not $Contents.Counts.PSObject.Properties[$name]){return $null}
            $value=[long]$Contents.Counts.$name;if($value -lt 0){return $null};$counts[$name]=$value
        }
        $samples=New-Object 'System.Collections.Generic.List[object]';$perClass=@{Bundle=0;SuspectedBusinessData=0;Unknown=0}
        foreach($sample in @($Contents.Samples)){
            if($null -eq $sample){continue}
            $class=[string]$sample.Class;if(-not $perClass.ContainsKey($class) -or $perClass[$class] -ge 10){continue}
            $relative=[string]$sample.RelativePath;if($relative.Length -gt 400){$relative=$relative.Substring(0,400)}
            $why=[string]$sample.Why;if($why.Length -gt 120){$why=$why.Substring(0,120)}
            $bytes=[long]$sample.Bytes;if($bytes -lt 0){$bytes=0}
            $perClass[$class]++
            $samples.Add([pscustomobject][ordered]@{RelativePath=$relative;Bytes=$bytes;Class=$class;Why=$why;WhyText=(Get-WsmBackupBundleWhyText $why)})
        }
        $reason=[string]$Contents.IncompleteReason;if($reason.Length -gt 60){$reason=$reason.Substring(0,60)}
        $installTime=$(if($Contents.PSObject.Properties['InstallTimeUtc']){[string]$Contents.InstallTimeUtc}else{''})
        [pscustomobject][ordered]@{
            Listed=[long]$Contents.Listed;Directories=[long]$Contents.Directories;Complete=[bool]$Contents.Complete;IncompleteReason=$reason
            SkippedReparse=[long]$Contents.SkippedReparse;Unreadable=[long]$Contents.Unreadable
            Counts=[pscustomobject]$counts;SamplesPerClass=10;Samples=@($samples.ToArray())
            InstallTimeUtc=$installTime;InstallTimeTrusted=[bool]$Contents.InstallTimeTrusted
        }
    }catch{return $null}
}

function Get-WsmBackupExcludedRegionRows([object[]]$ExcludedAreas,[string]$Workspace,[object[]]$SameNameLinks=@()) {
    $text=@{
        BundleExcluded=@('套裝軟體本體（安裝目錄），依政策不納入備份','在新機重新安裝該軟體；需要保留的資料或設定，請另外選入備份項目')
        ProtectedArea=@('系統、工具或受保護區域，依政策不納入備份','通常不需處理；若其中確有需要搬移的資料，請人工評估後另行處理')
    }
    $manualNextStep='工具不會備份這些檔案；請人工另外複製到新機的對應位置（例如手動複製資料夾或請業務負責人提供），並在新機確認內容。'
    $seen=@{};$rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($area in @($ExcludedAreas)){
        if($null -eq $area){continue}
        $path=[string]$area.Path;if(-not $path){continue}
        $key=$path.ToLowerInvariant();if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        $policyReason=[string]$area.Reason;if($policyReason.Length -gt 300){$policyReason=$policyReason.Substring(0,300)}
        # N9d：掃描直接寫入結構化類別；只接受兩個已知值，其餘（含舊掃描沒有欄位）回退到原因文字推斷。
        $structured=$(if($area.PSObject.Properties['Category']){[string]$area.Category}else{''})
        $categorySource='Inferred';$code=''
        if($structured -ceq 'BundleExcluded' -or $structured -ceq 'ProtectedArea'){$code=$structured;$categorySource='Structured'}else{$code=Get-WsmBackupExcludedRegionClass $policyReason $Workspace}
        $row=[ordered]@{Path=$path;ReasonCode=$code;Reason=$text[$code][0];NextStep=$text[$code][1];PolicyReason=$policyReason;CategorySource=$categorySource}
        $contents=$null;if($area.PSObject.Properties['Contents']){$contents=ConvertTo-WsmBackupExcludedContents $area.Contents}
        if($contents -and $code -ceq 'BundleExcluded'){
            $row.Contents=$contents
            $suspected=[long]$contents.Counts.SuspectedBusinessData
            if($suspected -gt 0){
                $row.NextStep=('安裝目錄內有 '+$suspected+' 個疑似業務資料檔，工具不會備份（人工處置）；請展開查看清單並另外人工複製。軟體本體請在新機重新安裝。')
                $row.ManualHandling=[pscustomobject][ordered]@{Required=$true;FileCount=$suspected;OriginalLocation=$path;Reason='安裝目錄整塊不備份；其中非可執行檔且位於資料或報表類子目錄、或修改時間晚於安裝時間的檔案，可能是業務資料。';NextStep=$manualNextStep}
            }
            $mine=@($SameNameLinks|Where-Object {$null -ne $_ -and [string]$_.BundleRoot -ieq $path})
            if($mine.Count){
                $row.SameName=@(foreach($link in $mine){[pscustomobject][ordered]@{Name=[string]$link.Name;BundlePath=[string]$link.BundlePath;BundleClass=[string]$link.BundleClass;BundleClassText=(Get-WsmBackupBundleClassText ([string]$link.BundleClass));BundleReason=[string]$link.BundleReason;OtherPath=[string]$link.OtherPath;OtherClass=[string]$link.OtherClass;OtherClassText='候選範圍內的檔案（未讀內容）';OtherReason=[string]$link.OtherReason;Note=[string]$link.Note;OtherItem='';OtherApproved=$false}})
            }
        }
        $rows.Add([pscustomobject]$row)
    }
    @($rows.ToArray() | Sort-Object -Property @{Expression={([string]$_.Path).ToLowerInvariant()}})
}

# N9d：把同名追溯的「另一處」對回已備份項目（原位置涵蓋該路徑者）；只加註記，不改任何備份決定。
function Add-WsmBackupSameNameItems([object[]]$Regions,[object[]]$Rows) {
    $backed=@($Rows|Where-Object {$null -ne $_ -and [string]$_.Status -ceq 'BackedUp' -and [string]$_.Location -match '^[A-Za-z]:\\'})
    foreach($region in @($Regions)){
        if($null -eq $region -or -not $region.PSObject.Properties['SameName']){continue}
        foreach($link in @($region.SameName)){
            $other=[string]$link.OtherPath
            foreach($row in $backed){
                $location=([string]$row.Location).TrimEnd('\')
                if($other -ieq $location -or $other.StartsWith($location+'\',[StringComparison]::OrdinalIgnoreCase)){$link.OtherItem=[string]$row.Name;$link.OtherApproved=$true;$link.OtherClassText='已備份項目範圍內的檔案';$link.OtherReason=('位於已備份項目「'+[string]$row.Name+'」的範圍內，依核准計畫備份；工具沒有比對兩份檔案的內容。');break}
            }
        }
    }
    @($Regions)
}

# N9d：整體完整度。區域內有疑似業務資料就是「有人工處置項」；安裝目錄沒列完或舊掃描沒分類時是「無法確認」。永遠不宣稱完整。
function Get-WsmBackupExcludedCompleteness($Regions) {
    if($null -eq $Regions){return [pscustomobject][ordered]@{Status='NotRecorded';Text='未記錄';ManualRegionCount=0;SuspectedFileCount=0;IncompleteRegionCount=0;UnclassifiedRegionCount=0;Claim='此結果集未記錄排除區域，不能視為完整。'}}
    $manual=0;$suspected=[long]0;$incomplete=0;$unclassified=0
    foreach($region in @($Regions)){
        if($null -eq $region -or [string]$region.ReasonCode -cne 'BundleExcluded'){continue}
        $hasContents=($region.PSObject.Properties['Contents'] -and $null -ne $region.Contents)
        $source=$(if($region.PSObject.Properties['CategorySource']){[string]$region.CategorySource}else{'Inferred'})
        if($hasContents){
            $count=[long]$region.Contents.Counts.SuspectedBusinessData
            if($count -gt 0){$manual++;$suspected+=$count}
            if(-not [bool]$region.Contents.Complete){$incomplete++}
        }elseif($source -ceq 'Inferred'){$unclassified++}
    }
    $status='NoManualItems';$text='安裝目錄內容已分類，未發現疑似業務資料'
    if($manual -gt 0){$status='ManualItems';$text='有人工處置項'}
    elseif($incomplete -gt 0 -or $unclassified -gt 0){$status='Unconfirmed';$text='無法確認（有安裝目錄內容未分類或未列完）'}
    [pscustomobject][ordered]@{Status=$status;Text=$text;ManualRegionCount=$manual;SuspectedFileCount=$suspected;IncompleteRegionCount=$incomplete;UnclassifiedRegionCount=$unclassified;Claim='此清單只涵蓋工具看得到的範圍，不代表搬移已完整。'}
}

# Returns Regions=$null (not recorded) unless the whole chain verifies:
#   sealed plan MaterialReferences (hash-bound) -> confirmation.json bytes -> ScanId + CandidateArtifactHash
#   -> candidates.json bytes of that scan in the Source workspace -> ExcludedAreas
# Any link that is missing, altered, or belongs to another host/inventory gives NotRecorded; nothing is partially shown.
function Get-WsmBackupBoundScanExclusions($Plan,[string]$Workspace,$Profile) {
    $notRecorded={param([string]$Why)[pscustomobject]@{Regions=$null;Binding=[pscustomobject][ordered]@{Status='NotRecorded';Reason=$Why;Scans=@()}}}
    try{
        if(-not $Plan -or -not $Plan.PSObject.Properties['Assistive'] -or -not $Plan.Assistive -or -not $Plan.Assistive.PSObject.Properties['MaterialReferences']){return (& $notRecorded '核准計畫沒有引用候選探索的確認材料。')}
        $references=@($Plan.Assistive.MaterialReferences | Where-Object {[string]$_.Reference -cmatch '^assistive/materials/source-candidate/[a-f0-9]{64}/confirmation\.json$'})
        if(-not $references.Count){return (& $notRecorded '核准計畫沒有引用候選探索的確認材料。')}
        if(-not $Profile -or [string]$Profile.Role -cne 'Source'){return (& $notRecorded '只有已註冊的 Source 工作區能核對候選掃描。')}
        $materialPrefix=[IO.Path]::GetFullPath((Join-Path $Workspace 'assistive/materials')).TrimEnd('\')+'\'
        $scans=[ordered]@{};$areas=New-Object 'System.Collections.Generic.List[object]';$links=New-Object 'System.Collections.Generic.List[object]'
        foreach($reference in $references){
            $expected=([string]$reference.SHA256).ToLowerInvariant()
            if($expected -notmatch '^[a-f0-9]{64}$' -or ([string]$reference.Reference) -cne ('assistive/materials/source-candidate/'+$expected+'/confirmation.json')){return (& $notRecorded '計畫中的確認材料參考與雜湊不一致。')}
            $materialPath=[IO.Path]::GetFullPath((Join-Path $Workspace ([string]$reference.Reference).Replace('/','\')))
            if(-not $materialPath.StartsWith($materialPrefix,[StringComparison]::OrdinalIgnoreCase)){return (& $notRecorded '確認材料不在來源工作區內。')}
            Assert-WsmNoReparse $materialPath
            if(-not [IO.File]::Exists($materialPath) -or (Get-FileHash -LiteralPath $materialPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected){return (& $notRecorded '確認材料遺失或內容與計畫記錄的雜湊不同。')}
            $confirmation=Read-WsmJson $materialPath
            if([string]$confirmation.Kind -cne 'SourceCandidateConfirmation'){return (& $notRecorded '確認材料不是候選確認紀錄。')}
            if([string]$confirmation.SourceFingerprint -ine [string]$Plan.Source.Fingerprint -or [string]$confirmation.InventoryHash -ine [string]$Plan.InventoryHash){return (& $notRecorded '確認材料屬於其他主機或其他盤點。')}
            $scanId=[string]$confirmation.ScanId;$artifactHash=([string]$confirmation.CandidateArtifactHash).ToLowerInvariant()
            if($artifactHash -notmatch '^[a-f0-9]{64}$'){return (& $notRecorded '確認材料沒有可用的候選掃描雜湊。')}
            if($scans.Contains($scanId)){continue}
            $scanDirectory=Get-WsmSourceCandidateScanDirectory $Workspace $Profile $scanId
            $candidatePath=Join-Path $scanDirectory 'candidates.json'
            Assert-WsmNoReparse $candidatePath
            if(-not [IO.File]::Exists($candidatePath)){return (& $notRecorded '找不到計畫所綁定的候選掃描結果。')}
            if((Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifactHash){return (& $notRecorded '候選掃描結果已變更，與計畫綁定的雜湊不符。')}
            $artifact=Read-WsmJson $candidatePath
            if([string]$artifact.Kind -cne 'SourceCandidateDiscovery' -or [string]$artifact.ScanId -cne $scanId -or [string]$artifact.SourceFingerprint -ine [string]$Plan.Source.Fingerprint -or -not $artifact.PSObject.Properties['ExcludedAreas'] -or $artifact.ExcludedAreas -isnot [array]){return (& $notRecorded '候選掃描結果的身分或格式與計畫不符。')}
            $scans[$scanId]=[pscustomobject][ordered]@{ScanId=$scanId;CandidateArtifactHash=$artifactHash;ScanStatus=[string]$artifact.Status}
            foreach($area in @($artifact.ExcludedAreas)){$areas.Add($area)}
            if($artifact.PSObject.Properties['SameNameLinks']){foreach($link in @($artifact.SameNameLinks)){$links.Add($link)}}
        }
        [pscustomobject]@{Regions=@(Get-WsmBackupExcludedRegionRows @($areas.ToArray()) $Workspace @($links.ToArray()));Binding=[pscustomobject][ordered]@{Status='Bound';Reason='';Scans=@($scans.Values)}}
    }catch{
        & $notRecorded '候選掃描與計畫的綁定無法核對。'
    }
}

function Get-WsmBackupItemResultRows($Plan,$Inventory,[object[]]$ArtifactRows,[bool]$OfflineFullSet,$WorkloadDiscovery=$null) {
    $reasonText=@{
        PermissionDenied=@('盤點時權限不足，工具無法讀取此項目','以具備權限的帳號重新盤點並備份，或人工處理')
        PayloadCaptured=@('資料已封存並驗證','無')
        ConfigurationCaptured=@('設定定義已封存在核准計畫中','無')
        ExternalHandling=@('此範圍標示為外部處理，未包含在備份中','依外部處理程序另行搬移')
        SeparateNonCTransfer=@('非 C 範圍使用舊格式的另行直傳，未包含在此備份中','完成非 C 直傳與結果匯入')
        NoCapturedContent=@('已選取但沒有擷取到任何內容','確認來源路徑仍存在後重新備份')
        ManualHandling=@('此項目需要人工處理，工具不會備份','依人工程序處理')
        Excluded=@('已明確排除','若需要搬移，回到審閱重新納入並重新核准')
        NotIncluded=@('審閱決策不是納入','完成審閱決策後重新核准')
        NotSelected=@('已發現但未選入本次搬移','若需要搬移，回到審閱選入並重新核准')
    }
    $get={param($o,$n) if($null -eq $o){return $null};if($o -is [Collections.IDictionary]){if($o.Contains($n)){return $o[$n]};return $null};if($o.PSObject.Properties[$n]){return $o.$n};return $null}
    $stats=@{}
    foreach($artifact in @($ArtifactRows)){
        if($null -eq $artifact){continue}
        $artifactItemId=[string]$artifact.ItemId
        if(-not $stats.ContainsKey($artifactItemId)){$stats[$artifactItemId]=@{Records=0;Files=0;Bytes=[long]0}}
        $stat=$stats[$artifactItemId];$stat.Records++
        if(-not $artifact.Directory){$stat.Files++;if($artifact.Data){$stat.Bytes+=[long]$artifact.Data.Bytes}}
    }
    $planById=[ordered]@{};foreach($planItem in @($Plan.Items)){$planById[[string]$planItem.ItemId]=$planItem}
    $inventoryById=@{};if($Inventory){foreach($inventoryItem in @($Inventory.Items)){$inventoryById[[string]$inventoryItem.ItemId]=$inventoryItem}}
    $ids=New-Object 'System.Collections.Generic.List[string]'
    foreach($id in $planById.Keys){$ids.Add([string]$id)}
    foreach($id in $inventoryById.Keys){if(-not $planById.Contains($id)){$ids.Add([string]$id)}}
    # Workload association comes only from recorded relations: item Dependencies
    # (same edges WizardGrouping uses) and optional WorkloadDiscovery.References.
    # A business item (site, task, service) is its own workload. Never inferred from names or paths.
    $consumersOf=@{}
    $addEdge={param([string]$Consumer,[string]$Target)if($Consumer -and $Target -and $Consumer -cne $Target){if(-not $consumersOf.ContainsKey($Target)){$consumersOf[$Target]=New-Object 'System.Collections.Generic.List[string]'};if(-not $consumersOf[$Target].Contains($Consumer)){$consumersOf[$Target].Add($Consumer)}}}
    foreach($edgeSource in @(@($planById.Values),@($inventoryById.Values))){foreach($edgeItem in $edgeSource){
        $dependencies=& $get $edgeItem 'Dependencies'
        if($null -ne $dependencies){foreach($dependency in @($dependencies)){& $addEdge ([string]$edgeItem.ItemId) ([string](& $get $dependency 'ItemId'))}}
    }}
    if($WorkloadDiscovery -and $WorkloadDiscovery.PSObject.Properties['References']){foreach($reference in @($WorkloadDiscovery.References)){& $addEdge ([string](& $get $reference 'ConsumerItemId')) ([string](& $get $reference 'ResourceItemId'))}}
    $workloadKinds=@('IISSite','ScheduledTask','Service')
    $nameOf={param([string]$Id)$o=$null;if($planById.Contains($Id)){$o=$planById[$Id]}elseif($inventoryById.ContainsKey($Id)){$o=$inventoryById[$Id]};$o}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($id in $ids){
        $planItem=$null;if($planById.Contains($id)){$planItem=$planById[$id]}
        $inventoryItem=$null;if($inventoryById.ContainsKey($id)){$inventoryItem=$inventoryById[$id]}
        $base=$(if($planItem){$planItem}else{$inventoryItem})
        $decision=$(if($planItem){[string](& $get $planItem 'Decision')}else{''})
        $included=($decision -ceq 'Include')
        $spec=$(if($planItem){& $get $planItem 'MigrationSpec'}else{$null})
        $adapter=[string](& $get $spec 'Adapter')
        $isFileScope=($adapter -ceq 'FileScope')
        $transferChannel=$(if($isFileScope){[string](& $get $spec 'TransferChannel')}else{''})
        if($isFileScope -and -not $transferChannel){$transferChannel='C'}
        $stat=$(if($stats.ContainsKey($id)){$stats[$id]}else{@{Records=0;Files=0;Bytes=[long]0}})
        $status='NotBackedUp';$code='NotSelected';$files=0;$bytes=[long]0
        if($included -and $isFileScope -and $transferChannel -ceq 'External'){$code='ExternalHandling'}
        elseif($included -and $isFileScope -and $transferChannel -ceq 'NonC' -and -not $OfflineFullSet){$code='SeparateNonCTransfer'}
        elseif($included -and $stat.Records -gt 0){$status='BackedUp';$code='PayloadCaptured';$files=[long]$stat.Files;$bytes=[long]$stat.Bytes}
        elseif($included -and $isFileScope){$code='NoCapturedContent'}
        elseif($included -and (-not $spec -or $adapter -ceq 'ManualWorkflow')){$code='ManualHandling'}
        elseif($included){$status='BackedUp';$code='ConfigurationCaptured'}
        elseif($planItem -and $decision -ceq 'Exclude'){$code='Excluded'}
        elseif($planItem){$code='NotIncluded'}
        $discoveryStatus=$(if($inventoryItem){[string](& $get $inventoryItem 'Status')}else{''})
        # Only when the item was not captured and no explicit user/tool decision already explains it.
        if($status -ceq 'NotBackedUp' -and $discoveryStatus -ceq 'PermissionDenied' -and $code -cin @('NotSelected','NotIncluded','NoCapturedContent')){$code='PermissionDenied'}
        $workloadNames=New-Object 'System.Collections.Generic.List[string]'
        $visited=@{};$pending=New-Object 'System.Collections.Generic.Queue[string]';$pending.Enqueue($id);$visited[$id]=$true
        while($pending.Count){
            $current=$pending.Dequeue();$currentItem=& $nameOf $current
            if($currentItem -and [string](& $get $currentItem 'Kind') -cin $workloadKinds){$workloadName=[string](& $get $currentItem 'Name');if($workloadName -and -not $workloadNames.Contains($workloadName)){$workloadNames.Add($workloadName)}}
            if($consumersOf.ContainsKey($current)){foreach($consumer in $consumersOf[$current]){if(-not $visited.ContainsKey($consumer)){$visited[$consumer]=$true;$pending.Enqueue($consumer)}}}
        }
        $settings=& $get $base 'Settings'
        $location=''
        if($isFileScope){$location=[string](& $get $spec 'SourcePath')}
        else{foreach($settingName in @('Path','PhysicalPath')){$settingValue=& $get $settings $settingName;if($null -ne $settingValue -and [string]$settingValue){$location=[string]$settingValue;break}}}
        if(-not $location){$location=[string](& $get $base 'NaturalKey')}
        $channel=''
        if($planItem){
            if($isFileScope){$channel=$transferChannel}
            elseif($adapter -ceq 'Certificate' -or [string](& $get $planItem 'Kind') -ceq 'Certificate'){$channel='Certificate'}
            else{$channel='Configuration'}
        }
        $classification=& $get $base 'Classification';$classificationDisposition=[string](& $get $classification 'Disposition')
        $restoreCondition=Get-WsmBackupRestoreCondition $status ([string](& $get $base 'Kind')) $channel $classificationDisposition
        $rows.Add([pscustomobject][ordered]@{ItemId=$id;Name=[string](& $get $base 'Name');Kind=[string](& $get $base 'Kind');Category=[string](& $get $base 'Category');Location=$location;Channel=$channel;Status=$status;ReasonCode=$code;Reason=$reasonText[$code][0];NextStep=$reasonText[$code][1];Files=$files;Bytes=$bytes;Decision=$decision;DiscoveryStatus=$discoveryStatus;Workloads=@($workloadNames.ToArray() | Sort-Object);RestoreCondition=$restoreCondition})
    }
    @($rows.ToArray() | Sort-Object -Property @{Expression={if($_.Status -ceq 'BackedUp'){0}else{1}}},@{Expression={([string]$_.Name).ToLowerInvariant()}})
}

# Software tab rows (B4). Grouping and association use only recorded relations, never names or paths.
#   linked ItemIds             Entry.ItemIds plus the ConsumerItemIds of every GeneralHost Requirement whose ProviderSoftwareId
#                              is this entry (a Requirement still a Candidate and decided NotNeeded is not evidence of need)
#   HasLinkEvidence            at least one linked ItemId exists; an empty list means "no evidence", never "not needed"
#   RequiredBySelectedWorkload at least one linked ItemId is a Plan item whose Decision is Include
#   Workloads                  workload names of the linked Include items, taken from the rows of Get-WsmBackupItemResultRows
#                              (same Dependencies/References walk and $workloadKinds as the item tabs; nothing is walked here)
#   ChosenVersion              the saved choice when it still matches the source version; otherwise the source version
#                              labelled as such (no choice, or a stale choice whose SourceVersion no longer matches)
#   ManualNote                 decision Reason/Evidence and the choice Reason, redacted; empty when none was recorded
#   DecisionState              Unreviewed (no decision) / Reviewed / Stale (the recorded SoftwareHash no longer matches the entry)
# Rows are ordered required-first, then by name and version. FeatureRows carry the workloads of their inventory item.
# CatalogState says whether a software catalog existed at all, so an empty list can be told from a missing one.
function Get-WsmBackupSoftwareRows($Plan,$Inventory,[object[]]$SoftwareChoices=@(),[object[]]$ItemRows=$null) {
    $get={param($o,$n) if($null -eq $o){return $null};if($o -is [Collections.IDictionary]){if($o.Contains($n)){return $o[$n]};return $null};if($o.PSObject.Properties[$n]){return $o.$n};return $null}
    $dispositionText=@{Reinstall='新機重新安裝';Portable='可攜版，隨資料搬移';KeepCompatible='保留相容版本';External='由外部處理';NotNeeded='新機不需要';SpecialProduct='特殊產品，人工處理';Unknown='尚未決定';Undecided='尚未決定'}
    $general=$(if($Plan.PSObject.Properties['GeneralHost']){$Plan.GeneralHost}else{$null})
    $catalog=$null
    if($general -and $general.PSObject.Properties['SoftwareCatalog'] -and $general.SoftwareCatalog -and $general.SoftwareCatalog.PSObject.Properties['Entries']){$catalog=$general.SoftwareCatalog}
    elseif($Inventory -and $Inventory.PSObject.Properties['SoftwareCatalog'] -and $Inventory.SoftwareCatalog -and $Inventory.SoftwareCatalog.PSObject.Properties['Entries']){$catalog=$Inventory.SoftwareCatalog}
    $decisionById=@{}
    if($general -and $general.PSObject.Properties['SoftwareDecisions']){foreach($decision in @($general.SoftwareDecisions)){if($decision){$decisionById[[string]$decision.SoftwareId]=$decision}}}
    $includedIds=@{}
    foreach($planItem in @(& $get $Plan 'Items')){if($planItem -and [string](& $get $planItem 'Decision') -ceq 'Include'){$includedIds[[string](& $get $planItem 'ItemId')]=$true}}
    if($null -eq $ItemRows){$ItemRows=@();try{$ItemRows=@(Get-WsmBackupItemResultRows $Plan $Inventory @() $false)}catch{$ItemRows=@()}}
    $workloadsById=@{}
    foreach($itemRow in @($ItemRows)){if($itemRow -and $itemRow.PSObject.Properties['Workloads']){$workloadsById[[string]$itemRow.ItemId]=@($itemRow.Workloads)}}
    $choiceById=@{}
    foreach($choice in @(@($SoftwareChoices)+@(& $get (& $get $Plan 'Assistive') 'SoftwareChoices'))){if($choice){$choiceId=[string](& $get $choice 'SoftwareId');if($choiceId -and -not $choiceById.ContainsKey($choiceId)){$choiceById[$choiceId]=$choice}}}
    $requirementConsumers=@{}
    foreach($requirement in @(& $get $general 'Requirements')){
        if(-not $requirement){continue}
        $provider=[string](& $get $requirement 'ProviderSoftwareId');if(-not $provider){continue}
        if([string](& $get $requirement 'Certainty') -ceq 'Candidate' -and [string](& $get $requirement 'Decision') -ceq 'NotNeeded'){continue}
        if(-not $requirementConsumers.ContainsKey($provider)){$requirementConsumers[$provider]=New-Object 'System.Collections.Generic.List[string]'}
        foreach($consumerId in @(& $get $requirement 'ConsumerItemIds')){if($consumerId){$requirementConsumers[$provider].Add([string]$consumerId)}}
    }
    $softwareRows=New-Object 'System.Collections.Generic.List[object]'
    if($catalog){
        foreach($entry in @($catalog.Entries)){
            $softwareId=[string]$entry.SoftwareId
            $decision=$null;if($decisionById.ContainsKey($softwareId)){$decision=$decisionById[$softwareId]}
            $disposition=$(if($decision){[string]$decision.Disposition}else{'Undecided'})
            if(-not $dispositionText.ContainsKey($disposition)){$disposition='Unknown'}
            $rawVersion=[string]$entry.Version
            $version=$rawVersion;if([string]::IsNullOrWhiteSpace($version)){$version='未知'}
            $linkedIds=New-Object 'System.Collections.Generic.List[string]'
            $requirementIds=@();if($requirementConsumers.ContainsKey($softwareId)){$requirementIds=$requirementConsumers[$softwareId].ToArray()}
            foreach($linkedId in @(@(& $get $entry 'ItemIds')+@($requirementIds))){if($linkedId -and -not $linkedIds.Contains([string]$linkedId)){$linkedIds.Add([string]$linkedId)}}
            $selectedLinks=@($linkedIds.ToArray() | Where-Object {$includedIds.ContainsKey($_)})
            $workloadNames=New-Object 'System.Collections.Generic.List[string]'
            foreach($selectedId in $selectedLinks){if($workloadsById.ContainsKey($selectedId)){foreach($workloadName in $workloadsById[$selectedId]){if($workloadName -and -not $workloadNames.Contains([string]$workloadName)){$workloadNames.Add([string]$workloadName)}}}}
            $decisionState='Unreviewed'
            if($decision){
                $decisionState='Reviewed'
                $recordedHash=[string](& $get $decision 'SoftwareHash')
                if($recordedHash){$currentHash='';try{$currentHash=[string](Get-WsmGeneralHostSoftwareFactsHash $entry)}catch{$currentHash=''};if(-not $currentHash -or $recordedHash -cne $currentHash){$decisionState='Stale'}}
            }
            $choiceRecord=$null;if($choiceById.ContainsKey($softwareId)){$choiceRecord=$choiceById[$softwareId]}
            $chosenBasis='SameAsSource';$chosenVersion=$version+'（同來源）'
            if($choiceRecord){
                $choiceSource=[string](& $get $choiceRecord 'SourceVersion');$choiceVersion=[string](& $get $choiceRecord 'ChosenVersion')
                if($choiceSource -cne $rawVersion){$chosenBasis='StaleChoice';$chosenVersion=$version+'（同來源；原選用版本已過期，需重新選擇）'}
                elseif($choiceVersion -and $choiceVersion -cne $rawVersion){$chosenBasis='Choice';$chosenVersion=$choiceVersion}
            }
            $noteParts=New-Object 'System.Collections.Generic.List[string]'
            if($decision){
                $decisionReason=ConvertTo-WsmProgressText (& $get $decision 'Reason');if($decisionReason){$noteParts.Add('決策理由：'+$decisionReason)}
                $decisionEvidence=ConvertTo-WsmProgressText (& $get $decision 'Evidence');if($decisionEvidence){$noteParts.Add('證據：'+$decisionEvidence)}
            }
            if($chosenBasis -ceq 'Choice'){$choiceReason=ConvertTo-WsmProgressText (& $get $choiceRecord 'Reason');if($choiceReason){$noteParts.Add('選用版本理由：'+$choiceReason)}}
            $softwareRows.Add([pscustomobject][ordered]@{SoftwareId=$softwareId;Name=[string]$entry.Name;Version=$version;Publisher=[string]$entry.Publisher;Architecture=[string]$entry.Architecture;Scope=[string]$entry.Scope;Location=[string]$entry.Location;SourceKind=[string]$entry.SourceKind;Disposition=$disposition;DispositionText=$dispositionText[$disposition];AccountContext=[string](& $get $entry 'AccountContext');Workloads=@($workloadNames.ToArray() | Sort-Object);RequiredBySelectedWorkload=[bool]($selectedLinks.Count -gt 0);HasLinkEvidence=[bool]($linkedIds.Count -gt 0);DecisionState=$decisionState;ChosenVersion=$chosenVersion;ChosenVersionBasis=$chosenBasis;ManualNote=($noteParts.ToArray() -join '；')})
        }
    }
    $featureRows=New-Object 'System.Collections.Generic.List[object]'
    if($Inventory){foreach($inventoryItem in @($Inventory.Items)){if($inventoryItem.Category -ceq 'Roles' -and $inventoryItem.Kind -ceq 'WindowsFeature'){$featureId=[string](& $get $inventoryItem 'ItemId');$featureWorkloads=@();if($featureId -and $workloadsById.ContainsKey($featureId)){$featureWorkloads=@($workloadsById[$featureId])};$featureRows.Add([pscustomobject][ordered]@{Name=[string]$inventoryItem.Name;FeatureName=[string]$inventoryItem.NaturalKey;ItemId=$featureId;Workloads=@($featureWorkloads | Sort-Object)})}}}
    $coverageGaps=New-Object 'System.Collections.Generic.List[object]'
    if($catalog -and $catalog.PSObject.Properties['Coverage']){
        foreach($coverage in @($catalog.Coverage)){
            if($coverage -and [string]$coverage.Status -cne 'Success'){
                $gap=[ordered]@{Status=[string]$coverage.Status}
                foreach($field in @('Probe','Scope','SID','View','EvidenceKind','ErrorKind','ItemId')){if($coverage.PSObject.Properties[$field] -and $null -ne $coverage.$field -and $coverage.$field -is [string]){$gap[$field]=[string]$coverage.$field}}
                $coverageGaps.Add([pscustomobject]$gap)
            }
        }
    }
    [pscustomobject]@{
        SoftwareRows=@($softwareRows.ToArray() | Sort-Object -Property @{Expression={if($_.RequiredBySelectedWorkload){0}else{1}}},@{Expression={([string]$_.Name).ToLowerInvariant()}},@{Expression={([string]$_.Version).ToLowerInvariant()}})
        FeatureRows=@($featureRows.ToArray())
        CoverageGaps=@($coverageGaps.ToArray())
        CatalogState=$(if($catalog){'Present'}else{'Unavailable'})
    }
}

function Export-WsmBackupItemResults([string]$Path,[object[]]$Rows,$Meta) {
    $allRows=@($Rows)
    $backedUp=@($allRows | Where-Object Status -CEQ 'BackedUp').Count
    $counts=[ordered]@{Total=$allRows.Count;BackedUp=$backedUp;NotBackedUp=($allRows.Count-$backedUp);Software=@($Meta.Software.SoftwareRows).Count;Features=@($Meta.Software.FeatureRows).Count}
    $coverageRegions=$(if($Meta.PSObject.Properties['CoverageRegions'] -and $null -ne $Meta.CoverageRegions){@($Meta.CoverageRegions)}else{@(Get-WsmBackupCoverageRegions ([string]$Meta.InventorySource) @($Meta.Software.CoverageGaps))})
    # CatalogState (Present / Unavailable) is only written when the caller knows it; older callers leave it out and the views say "not recorded".
    $softwareDocument=[ordered]@{SoftwareRows=@($Meta.Software.SoftwareRows);FeatureRows=@($Meta.Software.FeatureRows);CoverageGaps=@($Meta.Software.CoverageGaps)}
    if($Meta.Software.PSObject.Properties['CatalogState'] -and [string]$Meta.Software.CatalogState){$softwareDocument['CatalogState']=[string]$Meta.Software.CatalogState}
    $softwareDocument=[pscustomobject]$softwareDocument
    $document=[pscustomobject][ordered]@{SchemaVersion=2;ToolVersion=$script:ToolVersion;Kind='BackupItemResults';PairId=[string]$Meta.PairId;AttemptId=[string]$Meta.AttemptId;PlanHash=[string]$Meta.PlanHash;ManifestHash=[string]$Meta.ManifestHash;InventorySource=[string]$Meta.InventorySource;GeneratedUtc=(Get-WsmUtc);Counts=[pscustomobject]$counts;Software=$softwareDocument;CoverageRegions=@($coverageRegions);Rows=$allRows}
    # N3: ExcludedRegions is written only by callers that checked the scan binding. ExcludedRegions=null with a NotRecorded binding means "could not be verified"; a missing field means an older writer. Both read as not recorded.
    if($Meta.PSObject.Properties['ExcludedRegionsBinding'] -and $null -ne $Meta.ExcludedRegionsBinding){
        $excludedRegions=$null;if($Meta.PSObject.Properties['ExcludedRegions'] -and $null -ne $Meta.ExcludedRegions){$excludedRegions=@(Add-WsmBackupSameNameItems @($Meta.ExcludedRegions) $allRows)}
        $document | Add-Member NoteProperty ExcludedRegions $excludedRegions
        $document | Add-Member NoteProperty ExcludedCompleteness (Get-WsmBackupExcludedCompleteness $excludedRegions)
        $document | Add-Member NoteProperty ExcludedRegionsBinding $Meta.ExcludedRegionsBinding
    }
    Write-WsmJson $Path $document
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);SHA256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant();Counts=[pscustomobject]$counts;InventorySource=[string]$Meta.InventorySource}
}

function ConvertTo-WsmHtmlText($Value) {
    if($null -eq $Value){return ''}
    [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Export-WsmBackupOfflineReport([string]$ResultsPath,[string]$ExpectedSha256,[string]$OutputPath) {
    Assert-WsmNoReparse $ResultsPath
    Assert-WsmNoReparse $OutputPath
    if(-not $ExpectedSha256 -or (Get-FileHash -LiteralPath $ResultsPath -Algorithm SHA256).Hash -ine $ExpectedSha256){throw ('Backup item results hash mismatch: '+$ResultsPath)}
    $document=Read-WsmJson $ResultsPath
    if([string]$document.Kind -cne 'BackupItemResults'){throw 'The file is not a backup item results document.'}
    $encode={param($Value)ConvertTo-WsmHtmlText $Value}
    $channelText=@{C='C 槽';NonC='非 C 槽';Configuration='設定';Certificate='憑證'}
    $sizeText={param($Value)$n=[double]$Value;if($n -lt 0){return '—'};$units=@('B','KiB','MiB','GiB');$i=0;while($n -ge 1024 -and $i -lt 3){$n=$n/1024;$i++};if($i -eq 0){([string][long]$n)+' B'}else{($n.ToString($(if($n -ge 100){'0'}else{'0.0'}),[Globalization.CultureInfo]::InvariantCulture))+' '+$units[$i]}}
    $schemaVersion=0;if($document.PSObject.Properties['SchemaVersion']){try{$schemaVersion=[int]$document.SchemaVersion}catch{}}
    $isV2=($schemaVersion -ge 2)
    # A cell is plain text, or a hashtable @{Text;Icon;Class} rendered as a text badge (status never relies on colour alone).
    $buildTable={
        param([string]$Id,[string]$Caption,[string]$SearchColumns,[string[]]$Headers,[object[]]$RowCells,[string]$Filters='',[string]$CsvName='',[string[]]$RowAttrs=@(),[string]$CsvMeta='1',[string]$EmptyText='沒有項目',[string]$SearchLabel='',[string[]]$RowDetails=@())
        if(@($RowCells).Count -eq 0){return '<p class="empty">'+(& $encode $EmptyText)+'</p>'}
        $sb=New-Object Text.StringBuilder
        $tableAttrs=' id="'+$Id+'"';if($SearchColumns){$tableAttrs+=' data-search="'+$SearchColumns+'"'};if($Filters){$tableAttrs+=' data-filters="'+(& $encode $Filters)+'"'};if($CsvName){$tableAttrs+=' data-csv="'+(& $encode $CsvName)+'"'};if(@($RowAttrs).Count){$tableAttrs+=' data-csv-meta="'+$CsvMeta+'"'};if($SearchLabel){$tableAttrs+=' data-search-label="'+(& $encode $SearchLabel)+'"'}
        [void]$sb.Append('<div class="table-wrap" tabindex="0" role="region" aria-label="'+(& $encode $Caption)+'表格"><table'+$tableAttrs+'><caption>'+(& $encode $Caption)+'，共 '+@($RowCells).Count+' 筆</caption><thead><tr>')
        foreach($header in $Headers){[void]$sb.Append('<th scope="col">'+(& $encode $header)+'</th>')}
        [void]$sb.Append('</tr></thead><tbody>')
        $rowIndex=0
        foreach($cells in $RowCells){
            $attr='';if($rowIndex -lt @($RowAttrs).Count){$attr=' '+$RowAttrs[$rowIndex]}
            [void]$sb.Append('<tr'+$attr+'>')
            foreach($cell in $cells){
                if($cell -is [hashtable] -and $cell.ContainsKey('Toggle')){[void]$sb.Append('<td data-text="'+(& $encode $cell.Text)+'">'+(& $encode $cell.Text)+'<div class="region-summary" data-target="'+(& $encode $cell.Toggle)+'">'+(& $encode $cell.Summary)+'</div></td>')}
                elseif($cell -is [hashtable]){[void]$sb.Append('<td><span class="badge b-'+$cell.Class+'" data-icon="'+(& $encode $cell.Icon)+'">'+(& $encode $cell.Text)+'</span></td>')}
                else{[void]$sb.Append('<td>'+(& $encode $cell)+'</td>')}
            }
            [void]$sb.Append('</tr>')
            if($rowIndex -lt @($RowDetails).Count -and $RowDetails[$rowIndex]){[void]$sb.Append('<tr class="region-detail-row" id="rd-'+$rowIndex+'"><td colspan="'+@($Headers).Count+'">'+$RowDetails[$rowIndex]+'</td></tr>')}
            $rowIndex++
        }
        [void]$sb.Append('</tbody></table></div>')
        $sb.ToString()
    }
    $workloadText={param($Row)
        if(-not $Row.PSObject.Properties['Workloads'] -or $null -eq $Row.Workloads){return '未記錄'}
        $names=@($Row.Workloads | Where-Object {[string]$_})
        if(-not $names.Count){return '未關聯'}
        ($names -join '、')
    }
    $restoreCell={param($Row)
        if(-not $Row.PSObject.Properties['RestoreCondition'] -or $null -eq $Row.RestoreCondition){return @{Text='未記錄';Icon='?';Class='neutral'}}
        $code=[string]$Row.RestoreCondition.Code
        $icon=@{Restorable='✓';RequiresPrerequisite='◐';ManualOnly='!';NotApplicable='—'}
        $class=@{Restorable='ok';RequiresPrerequisite='warn';ManualOnly='warn';NotApplicable='neutral'}
        $short=@{Restorable='可還原';RequiresPrerequisite='需前置條件';ManualOnly='僅人工處理';NotApplicable='不適用'}
        @{Text=$(if($short.ContainsKey($code)){$short[$code]}else{[string]$Row.RestoreCondition.Text});Icon=$(if($icon.ContainsKey($code)){$icon[$code]}else{'?'});Class=$(if($class.ContainsKey($code)){$class[$code]}else{'neutral'})}
    }
    $rowAttr={param($Row)'data-id="'+(& $encode $Row.ItemId)+'" data-status="'+(& $encode $Row.Status)+'" data-reason="'+(& $encode $Row.ReasonCode)+'"'}
    $allRows=@($document.Rows | Where-Object {$null -ne $_})
    $backedRows=@($allRows | Where-Object {[string]$_.Status -ceq 'BackedUp'})
    $pendingRows=@($allRows | Where-Object {[string]$_.Status -ceq 'NotBackedUp'})
    $softwareRows=@($document.Software.SoftwareRows | Where-Object {$null -ne $_})
    $featureRows=@($document.Software.FeatureRows | Where-Object {$null -ne $_})
    $gapCount=@($document.Software.CoverageGaps | Where-Object {$null -ne $_}).Count
    $backedBadge=@{Text='已備份';Icon='✓';Class='ok'}
    $pendingBadge=@{Text='未備份';Icon='✕';Class='bad'}
    $backedCells=@(foreach($row in $backedRows){,@([string]$row.Name,[string]$row.Kind,(& $workloadText $row),[string]$row.Location,$(if($channelText.ContainsKey([string]$row.Channel)){$channelText[[string]$row.Channel]}else{[string]$row.Channel}),[string]$row.Files,(& $sizeText $row.Bytes),$backedBadge,(& $restoreCell $row))})
    $backedAttrs=@(foreach($row in $backedRows){& $rowAttr $row})
    $pendingCells=@(foreach($row in $pendingRows){,@([string]$row.Name,[string]$row.Kind,(& $workloadText $row),[string]$row.Location,[string]$row.Reason,[string]$row.NextStep,[string]$row.DiscoveryStatus,$pendingBadge)})
    $pendingAttrs=@(foreach($row in $pendingRows){& $rowAttr $row})
    # Software tab (B4). Every new field is read only when the result set recorded it; a missing field is shown as 未記錄, never as an empty value.
    $has={param($Row,[string]$Name)[bool]$Row.PSObject.Properties[$Name]}
    $softwareText={param($Row,[string]$Name)if(& $has $Row $Name){[string]$Row.$Name}else{'未記錄'}}
    $scopeText={param($Row)$t=[string]$Row.Scope;if((& $has $Row 'AccountContext') -and [string]$Row.AccountContext){$t+=' · '+[string]$Row.AccountContext};$t}
    $softwareGroupCell={param($Row)
        if(-not (& $has $Row 'RequiredBySelectedWorkload')){return @{Text='未記錄';Icon='?';Class='neutral'}}
        if([bool]$Row.RequiredBySelectedWorkload){return @{Text='已選工作負載必需';Icon='●';Class='ok'}}
        @{Text='其他已發現軟體';Icon='○';Class='neutral'}
    }
    $softwareWorkloadText={param($Row)
        if(-not (& $has $Row 'Workloads') -or $null -eq $Row.Workloads){return '未記錄'}
        $names=@($Row.Workloads | Where-Object {[string]$_})
        if($names.Count){return ($names -join '、')}
        if(& $has $Row 'RequiredBySelectedWorkload'){
            if([bool]$Row.RequiredBySelectedWorkload){return '已選項目使用（沒有工作負載名稱）'}
            if((& $has $Row 'HasLinkEvidence') -and [bool]$Row.HasLinkEvidence){return '關聯項目未選入'}
            return '無關聯證據'
        }
        '未關聯'
    }
    $stateCell={param($Row)
        $state=$(if(& $has $Row 'DecisionState'){[string]$Row.DecisionState}else{''})
        switch($state){'Reviewed'{@{Text='已審閱';Icon='✓';Class='ok'}}'Unreviewed'{@{Text='未審閱';Icon='○';Class='warn'}}'Stale'{@{Text='已過期，需重新審閱';Icon='!';Class='bad'}}default{@{Text='未記錄';Icon='?';Class='neutral'}}}
    }
    $softwareCells=@(foreach($row in $softwareRows){,@((& $softwareGroupCell $row),[string]$row.Name,[string]$row.Version,(& $softwareText $row 'ChosenVersion'),[string]$row.Publisher,[string]$row.Architecture,(& $scopeText $row),[string]$row.Location,(& $softwareWorkloadText $row),[string]$row.DispositionText,(& $stateCell $row),(& $softwareText $row 'ManualNote'))})
    $softwareAttrs=@(foreach($row in $softwareRows){'data-sid="'+(& $encode $row.SoftwareId)+'"'})
    $featureCells=@(foreach($row in $featureRows){,@([string]$row.Name,[string]$row.FeatureName,(& $workloadText $row))})
    $catalogState=$(if($document.Software.PSObject.Properties['CatalogState']){[string]$document.Software.CatalogState}else{''})
    $softwareEmptyText=switch($catalogState){'Present'{'沒有發現已安裝軟體'}'Unavailable'{'此備份沒有軟體清單（來源軟體盤點不可用），無法列出已安裝軟體'}default{'沒有項目（此結果集未記錄軟體清單狀態）'}}
    $softwareGrouped=(@($softwareRows | Where-Object {-not (& $has $_ 'RequiredBySelectedWorkload')}).Count -eq 0)
    $requiredSoftware=@($softwareRows | Where-Object {$softwareGrouped -and [bool]$_.RequiredBySelectedWorkload})
    $otherSoftware=@($softwareRows | Where-Object {$softwareGrouped -and -not [bool]$_.RequiredBySelectedWorkload})
    # Printable checklist: built from the full row set (no paging, no row cap); hidden on screen, shown only while the checklist print mode is on.
    $checklistSoftwareTable={param([object[]]$Rows)
        if(-not @($Rows).Count){return '<p class="empty">沒有項目</p>'}
        $sb=New-Object Text.StringBuilder
        [void]$sb.Append('<table class="check-table"><thead><tr><th scope="col">完成</th><th scope="col">名稱</th><th scope="col">選用版本</th><th scope="col">架構</th><th scope="col">範圍</th><th scope="col">決策</th><th scope="col">工作負載</th><th scope="col">人工備註</th></tr></thead><tbody>')
        foreach($r in $Rows){[void]$sb.Append('<tr data-sid="'+(& $encode $r.SoftwareId)+'"><td><span class="check-box" aria-hidden="true"></span></td><td>'+(& $encode $r.Name)+'</td><td>'+(& $encode (& $softwareText $r 'ChosenVersion'))+'</td><td>'+(& $encode $r.Architecture)+'</td><td>'+(& $encode (& $scopeText $r))+'</td><td>'+(& $encode $r.DispositionText)+'</td><td>'+(& $encode (& $softwareWorkloadText $r))+'</td><td>'+(& $encode (& $softwareText $r 'ManualNote'))+'</td></tr>')}
        [void]$sb.Append('</tbody></table>')
        $sb.ToString()
    }
    $checklist=New-Object Text.StringBuilder
    [void]$checklist.Append('<section id="checklist" class="checklist" aria-label="新機安裝檢查表"><h1>新機安裝檢查表</h1><p>配對 ID：'+(& $encode $document.PairId)+'；Attempt ID：'+(& $encode $document.AttemptId)+'；產生時間：'+(& $encode $document.GeneratedUtc)+'</p><p>這是舊機上發現的軟體清單，請在新機逐項安裝並勾選。工具不會自動安裝，也不保證新版相容。</p>')
    if(-not $softwareRows.Count){[void]$checklist.Append('<h2>安裝軟體</h2><p class="empty">'+(& $encode $softwareEmptyText)+'</p>')}
    elseif($softwareGrouped){
        [void]$checklist.Append('<h2>已選工作負載必需（'+$requiredSoftware.Count+'）</h2>'+(& $checklistSoftwareTable $requiredSoftware))
        [void]$checklist.Append('<h2>其他已發現軟體（'+$otherSoftware.Count+'）</h2>'+(& $checklistSoftwareTable $otherSoftware))
    }else{[void]$checklist.Append('<h2>已發現軟體（'+$softwareRows.Count+'；此結果集未記錄分組）</h2>'+(& $checklistSoftwareTable $softwareRows))}
    [void]$checklist.Append('<h2>Windows 角色與功能（'+$featureRows.Count+'）</h2>')
    if(-not $featureRows.Count){[void]$checklist.Append('<p class="empty">沒有發現已安裝的 Windows 角色或功能</p>')}
    else{
        [void]$checklist.Append('<table class="check-table"><thead><tr><th scope="col">完成</th><th scope="col">顯示名稱</th><th scope="col">Install-WindowsFeature 名稱</th><th scope="col">關聯工作負載</th></tr></thead><tbody>')
        foreach($r in $featureRows){[void]$checklist.Append('<tr><td><span class="check-box" aria-hidden="true"></span></td><td>'+(& $encode $r.Name)+'</td><td><code>'+(& $encode $r.FeatureName)+'</code></td><td>'+(& $encode (& $workloadText $r))+'</td></tr>')}
        [void]$checklist.Append('</tbody></table>')
    }
    [void]$checklist.Append('</section>')
    $sourceTexts=@{PackageControls='封裝內的來源盤點';TrustedInventory='已核驗的來源盤點';Unavailable='無法取得來源盤點'}
    $inventorySource=[string]$document.InventorySource
    $sourceText=$(if($sourceTexts.ContainsKey($inventorySource)){$sourceTexts[$inventorySource]}else{$inventorySource})
    $hashText={param($Value)$v=[string]$Value;if($v){'<code class="hash">'+(& $encode $v)+'</code>'}else{'未記錄'}}
    $manifestHash=$(if($document.PSObject.Properties['ManifestHash']){[string]$document.ManifestHash}else{''})
    $planHash=$(if($document.PSObject.Properties['PlanHash']){[string]$document.PlanHash}else{''})
    # N9d：安裝根內容分類的展開區塊（靜態 HTML；有 JavaScript 時預設收合，沒有時直接顯示）。路徑與檔名一律當資料跳脫。
    $badgeHtml={param($Cell)'<span class="badge b-'+$Cell.Class+'" data-icon="'+(& $encode $Cell.Icon)+'">'+(& $encode $Cell.Text)+'</span>'}
    $classBadge={param([string]$Class)
        switch($Class){
            'SuspectedBusinessData'{@{Text='人工處置';Icon='!';Class='warn'}}
            'Bundle'{@{Text='本體';Icon='■';Class='neutral'}}
            default{@{Text='未知';Icon='?';Class='neutral'}}
        }
    }
    $regionSummaryText={param($Region)
        $c=$Region.Contents
        $t='內容分類：本體 '+[string]$c.Counts.Bundle+' · 疑似業務資料 '+[string]$c.Counts.SuspectedBusinessData+' · 未知 '+[string]$c.Counts.Unknown
        if(-not [bool]$c.Complete){$t+='（未列完）'}
        $t
    }
    $regionDetailHtml={param($Region)
        $c=$Region.Contents;$root=([string]$Region.Path).TrimEnd('\')
        $sb=New-Object Text.StringBuilder
        [void]$sb.Append('<div class="region-detail" data-region="'+(& $encode $Region.Path)+'">')
        [void]$sb.Append('<p class="region-counts">安裝目錄內容（唯讀分類，整個目錄仍不備份）：本體 '+(& $encode $c.Counts.Bundle)+'、疑似業務資料 '+(& $encode $c.Counts.SuspectedBusinessData)+'、未知 '+(& $encode $c.Counts.Unknown)+'；已列 '+(& $encode $c.Listed)+' 筆檔案與目錄。')
        if(-not [bool]$c.Complete){[void]$sb.Append(' <span class="badge b-warn" data-icon="!">未列完</span> 超過列舉預算（'+(& $encode $c.IncompleteReason)+'），以上只是已列出的部分，不能當成全部。')}
        [void]$sb.Append('</p>')
        if($Region.PSObject.Properties['ManualHandling'] -and $Region.ManualHandling){
            $m=$Region.ManualHandling
            [void]$sb.Append('<div class="manual-box" role="note"><span class="badge b-warn" data-icon="!">人工處置</span> 疑似業務資料 '+(& $encode $m.FileCount)+' 個檔案。原因：'+(& $encode $m.Reason)+' 原件位置：<code>'+(& $encode $m.OriginalLocation)+'</code>。下一步：'+(& $encode $m.NextStep)+'</div>')
        }
        $samples=@($c.Samples|Where-Object {$null -ne $_})
        if($samples.Count){
            [void]$sb.Append('<div class="table-wrap" tabindex="0" role="region" aria-label="'+(& $encode $Region.Path)+' 的內容樣本表格"><table class="region-samples"><caption>內容樣本（每類最多 '+(& $encode $c.SamplesPerClass)+' 筆）</caption><thead><tr><th scope="col">類別</th><th scope="col">原件位置</th><th scope="col">大小</th><th scope="col">判斷依據</th><th scope="col">處置</th></tr></thead><tbody>')
            foreach($s in $samples){
                $disposition=$(if([string]$s.Class -ceq 'SuspectedBusinessData'){'人工處置：另外人工複製'}else{'不備份（依政策）'})
                [void]$sb.Append('<tr><td>'+(& $badgeHtml (& $classBadge ([string]$s.Class)))+'</td><td><code>'+(& $encode ($root+'\'+[string]$s.RelativePath))+'</code></td><td>'+(& $encode (& $sizeText $s.Bytes))+'</td><td>'+(& $encode $s.WhyText)+'</td><td>'+(& $encode $disposition)+'</td></tr>')
            }
            [void]$sb.Append('</tbody></table></div>')
        }
        if($Region.PSObject.Properties['SameName'] -and @($Region.SameName).Count){
            [void]$sb.Append('<h4>同名檔案追溯（僅標示，不改變任何備份或排除決定）</h4><ul class="same-name">')
            foreach($link in @($Region.SameName)){
                [void]$sb.Append('<li data-same-name="'+(& $encode $link.Name)+'" data-side="bundle"><code>'+(& $encode $link.Name)+'</code>（安裝根內）：同名，另一處位於 <code>'+(& $encode $link.OtherPath)+'</code>。分類：'+(& $encode $link.BundleClassText)+'。理由：'+(& $encode $link.BundleReason)+'</li>')
                [void]$sb.Append('<li data-same-name="'+(& $encode $link.Name)+'" data-side="other"><code>'+(& $encode $link.Name)+'</code>（另一處）：同名，另一處位於 <code>'+(& $encode $link.BundlePath)+'</code>。分類：'+(& $encode $link.OtherClassText)+'。理由：'+(& $encode $link.OtherReason)+'</li>')
            }
            [void]$sb.Append('</ul>')
        }
        [void]$sb.Append('</div>')
        $sb.ToString()
    }
    $completenessModel=Get-WsmBackupExcludedCompleteness $(if($document.PSObject.Properties['ExcludedRegions'] -and $null -ne $document.ExcludedRegions){@($document.ExcludedRegions)}else{$null})
    $completenessBadge=switch([string]$completenessModel.Status){'ManualItems'{@{Text='有人工處置項';Icon='!';Class='warn'}}'Unconfirmed'{@{Text='無法確認';Icon='?';Class='warn'}}'NoManualItems'{@{Text='未發現人工處置項';Icon='○';Class='neutral'}}default{@{Text='未記錄';Icon='?';Class='neutral'}}}
    $completenessDetail=$(if([string]$completenessModel.Status -ceq 'ManualItems'){[string]$completenessModel.ManualRegionCount+' 個區域、'+[string]$completenessModel.SuspectedFileCount+' 個疑似業務資料檔需要人工處置，請看「未備份」分頁的套裝本體與受保護區域。'}else{[string]$completenessModel.Text+'。'})
    $completenessHtml='<p class="completeness'+$(if([string]$completenessModel.Status -ceq 'ManualItems'){' note'}else{''})+'" id="completeness" role="status" data-status="'+(& $encode $completenessModel.Status)+'">整體完整度：'+(& $badgeHtml $completenessBadge)+' '+(& $encode $completenessDetail)+' '+(& $encode $completenessModel.Claim)+'</p>'
    $coverageHtml=''
    if(-not $document.PSObject.Properties['CoverageRegions'] -or $null -eq $document.CoverageRegions){$coverageHtml='<p class="empty">此結果集未記錄</p>'}
    else{
        $regionRows=@($document.CoverageRegions | Where-Object {$null -ne $_})
        if(-not $regionRows.Count){$coverageHtml='<p class="empty">沒有記錄到未涵蓋區域</p>'}
        else{
            $regionCells=@(foreach($region in $regionRows){,@([string]$region.Region,[string]$region.Reason,[string]$region.NextStep)})
            $coverageHtml=(& $buildTable 'tbl-coverage' '探索未涵蓋區域' '' @('區域','原因','下一步') $regionCells)
        }
    }
    $excludedHtml=''
    if(-not $document.PSObject.Properties['ExcludedRegions'] -or $null -eq $document.ExcludedRegions){$excludedHtml='<p class="empty">此結果集未記錄</p>'}
    else{
        $excludedRows=@($document.ExcludedRegions | Where-Object {$null -ne $_})
        if(-not $excludedRows.Count){$excludedHtml='<p class="empty">沒有記錄到被排除的區域</p>'}
        else{
            $excludedCells=@(for($i=0;$i -lt $excludedRows.Count;$i++){$region=$excludedRows[$i];if($region.PSObject.Properties['Contents'] -and $null -ne $region.Contents){,@(@{Text=[string]$region.Path;Toggle=('rd-'+$i);Summary=(& $regionSummaryText $region)},[string]$region.Reason,[string]$region.NextStep)}else{,@([string]$region.Path,[string]$region.Reason,[string]$region.NextStep)}})
            $excludedAttrs=@(foreach($region in $excludedRows){'data-reason="'+(& $encode $region.ReasonCode)+'"'})
            $excludedDetails=@(foreach($region in $excludedRows){if($region.PSObject.Properties['Contents'] -and $null -ne $region.Contents){& $regionDetailHtml $region}else{''}})
            $excludedHtml=(& $buildTable 'tbl-excluded' '套裝本體與受保護區域' '0' @('區域','原因','下一步') $excludedCells '1:區域類別' 'backup-excluded-regions.csv' $excludedAttrs 'region' '沒有項目' '搜尋區域路徑' $excludedDetails)
        }
    }
    $noJsNote='<noscript><p class="js-note">需啟用 JavaScript 才能匯出 CSV，也才能使用搜尋、篩選與分頁；目前顯示全部列。</p></noscript>'
    $layerRestore=$(if($isV2){'逐列顯示在已備份清單的「可還原條件」欄：可還原＝可由本工具還原；需前置條件＝可還原，但需先安裝軟體、角色或補齊帳密；僅人工處理＝工具不會自動還原；不適用＝未備份。'}else{'此結果集為舊格式，未記錄可還原條件。'})
    $page=New-Object Text.StringBuilder
    [void]$page.Append(@'
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>搬移備份報告</title>
<style>
body{margin:0;font:16px/1.6 system-ui,"Noto Sans TC","Microsoft JhengHei",sans-serif;color:#172033;background:#fff}
main{max-width:72rem;margin:0 auto;padding:1rem}
h1{font-size:1.5rem;margin:.5rem 0}
h2{font-size:1.25rem;margin:1.5rem 0 .5rem}
h3{font-size:1.1rem;margin:1.25rem 0 .5rem}
dl.meta{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:.25rem 1rem;margin:.5rem 0}
dl.meta dt{font-weight:700}
dl.meta dd{margin:0;min-width:0;overflow-wrap:anywhere}
code.hash{font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:.9rem;overflow-wrap:anywhere;word-break:break-all}
.note{border:2px solid #7a5a00;background:#fff6d6;padding:.75rem 1rem;margin:1rem 0;border-radius:4px}
.callout{border:2px solid #9b1c1c;background:#fdecec;padding:.75rem 1rem;margin:1rem 0;border-radius:4px}
.layers{border:1px solid #bbc4ce;padding:.5rem 1rem;margin:1rem 0;border-radius:4px}
.layers h2{margin-top:.5rem}
.layers ol{margin:.5rem 0;padding-left:1.5rem}
.layers li{margin:.35rem 0}
.empty{font-style:italic;margin:.5rem 0}
.js-note{margin:.5rem 0}
.completeness{margin:1rem 0}
.region-summary{margin-top:.25rem;font-size:.85rem}
.region-toggle{font:inherit;font-size:.85rem;padding:.2rem .6rem;cursor:pointer;text-align:left;max-width:100%;white-space:normal}
.region-toggle:focus{outline:3px solid #1b5fc1;outline-offset:2px}
.region-detail-row>td{background:#f7f9fc}
.region-detail{position:sticky;left:0;box-sizing:border-box;width:100%;max-width:calc(100vw - 3rem);padding:.25rem .5rem}
.region-detail .table-wrap{margin:.5rem 0}
.region-samples{min-width:34rem}
.region-detail h4{margin:.75rem 0 .25rem}
.manual-box{border:2px solid #7a5a00;background:#fff6d6;padding:.5rem .75rem;margin:.5rem 0;border-radius:4px}
.table-wrap{overflow-x:auto;max-width:100%;border:1px solid #bbc4ce}
.table-wrap:focus{outline:3px solid #1b5fc1;outline-offset:2px}
table{border-collapse:collapse;width:100%;font-size:.9rem}
caption{text-align:left;padding:.5rem;font-weight:700}
th,td{border:1px solid #bbc4ce;padding:.4rem .5rem;text-align:left;vertical-align:top;overflow-wrap:break-word}
th{background:#eef2f7}
.badge{display:inline-block;padding:.05rem .5rem;border:1px solid currentColor;border-radius:1rem;font-weight:700;font-size:.85rem;white-space:nowrap}
.badge::before{content:attr(data-icon) " ";font-weight:700}
.b-ok{background:#e3f4e8;color:#0b4a1f}
.b-warn{background:#fff6d6;color:#5c4300}
.b-bad{background:#fdecec;color:#7a1010}
.b-neutral{background:#eef2f7;color:#172033}
.check-box{display:inline-block;width:1rem;height:1rem;border:2px solid #172033;vertical-align:middle}
.checklist{display:none}
[hidden]{display:none!important}
.tabs{display:flex;flex-wrap:wrap;gap:.25rem;border-bottom:2px solid #172033;margin-top:1rem}
.tabs button{font:inherit;padding:.5rem .9rem;border:1px solid #172033;border-bottom:0;background:#eef2f7;color:#172033;cursor:pointer}
.tabs button[aria-selected=true]{background:#fff;font-weight:700;border-top:5px solid #172033;text-decoration:underline}
.tabs button:focus,.toolbar button:focus,.toolbar select:focus,.toolbar input:focus,.pager button:focus{outline:3px solid #1b5fc1;outline-offset:2px}
.toolbar,.pager{display:flex;flex-wrap:wrap;gap:.5rem;align-items:center;margin:.5rem 0}
.toolbar input{font:inherit;padding:.3rem .5rem;min-width:12rem;max-width:100%}
.toolbar select{font:inherit;padding:.3rem .5rem;max-width:100%}
.toolbar button,.pager button{font:inherit;padding:.3rem .8rem}
.toolbar .count{font-weight:700}
@media (max-width:480px){main{padding:.5rem}dl.meta{grid-template-columns:minmax(0,1fr)}.toolbar input{min-width:0;width:100%}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important;scroll-behavior:auto!important}}
@media print{
body.print-checklist main{display:none!important}
body.print-checklist .checklist{display:block}
.check-table{font-size:11pt}
.check-table th{white-space:nowrap}
.checklist h2{break-after:avoid}
.tabs,.toolbar,.pager,.js-note,noscript{display:none!important}
main > section[hidden]{display:block!important}
tbody tr[hidden]{display:table-row!important}
.table-wrap[hidden]{display:block!important}
.table-wrap{overflow:visible;border:0}
thead{display:table-header-group}
tr{break-inside:avoid}
body{font-size:12pt;color:#000}
a{color:#000}
.badge{border:1px solid #000;background:#fff;color:#000}
}
</style>
</head>
<body>
<main>
<h1>搬移備份報告</h1>
'@)
    [void]$page.Append("`n"+'<dl class="meta"><dt>配對 ID</dt><dd>'+(& $encode $document.PairId)+'</dd><dt>Attempt ID</dt><dd>'+(& $encode $document.AttemptId)+'</dd><dt>產生時間</dt><dd>'+(& $encode $document.GeneratedUtc)+'</dd><dt>來源盤點</dt><dd>'+(& $encode $sourceText)+'</dd><dt>ManifestHash</dt><dd>'+(& $hashText $manifestHash)+'</dd><dt>PlanHash</dt><dd>'+(& $hashText $planHash)+'</dd></dl>'+"`n")
    [void]$page.Append('<p class="note" role="note">這份報告顯示擷取與封存當時的狀態，不代表目前備份媒體仍然完整，也不代表新機的還原結果。新機匯入時會重新驗證所有檔案。</p>'+"`n")
    [void]$page.Append($completenessHtml+"`n")
    [void]$page.Append('<div class="layers" role="group" aria-labelledby="layers-title"><h2 id="layers-title">四層狀態說明</h2><ol>'+
        '<li><strong>資料已備份：</strong>本報告呈現（已備份與未備份分頁）。</li>'+
        '<li><strong>獨立副本已驗證：</strong>不在此報告判定。這是封存後才產生的收據，請看新機工作台或獨立副本收據。</li>'+
        '<li><strong>可還原條件：</strong>本報告呈現。'+$layerRestore+'</li>'+
        '<li><strong>業務可用：</strong>不在此報告判定。需要在新機驗證，本工具不判定。</li>'+
        '</ol></div>'+"`n")
    if($inventorySource -ceq 'Unavailable'){[void]$page.Append('<p class="callout">無法取得來源盤點，未備份清單只包含核准計畫內的項目，未選入的已發現項目沒有列出。</p>'+"`n")}
    [void]$page.Append('<section id="backed" data-tab="已備份（'+$backedRows.Count+'）"><h2>已備份（'+$backedRows.Count+'）</h2>'+"`n"+$noJsNote+"`n"+(& $buildTable 'tbl-backed' '已備份項目' '0,3' @('名稱','類型','工作負載','原位置','通道','檔案數','大小','狀態','可還原條件') $backedCells '1:類型;8:可還原條件' 'backup-backed-up.csv' $backedAttrs)+"`n</section>`n")
    [void]$page.Append('<section id="pending" data-tab="未備份（'+$pendingRows.Count+'）"><h2>未備份（'+$pendingRows.Count+'）</h2>'+"`n"+$noJsNote+"`n"+(& $buildTable 'tbl-pending' '未備份項目' '0,3' @('名稱','類型','工作負載','原位置','原因','下一步','盤點狀態','狀態') $pendingCells '1:類型;4:原因' 'backup-not-backed-up.csv' $pendingAttrs)+"`n"+'<h3>探索未涵蓋區域（以區域列出，不是項目）</h3>'+"`n"+$coverageHtml+"`n"+'<h3>套裝本體與受保護區域（依政策不納入備份；以區域列出，不是項目）</h3>'+"`n"+$excludedHtml+"`n</section>`n")
    [void]$page.Append('<section id="software" data-tab="安裝軟體（'+$softwareRows.Count+'）"><h2>安裝軟體（'+$softwareRows.Count+'）</h2>'+"`n"+$noJsNote+"`n"+'<p>這是舊機上發現的軟體清單，供您在新機自行安裝。工具不會自動安裝，也不保證新版相容。</p>'+"`n")
    if($gapCount -gt 0){
        [void]$page.Append('<p class="callout">軟體盤點有 '+$gapCount+' 個範圍未完整取得，清單可能不完整。</p>'+"`n"+'<ul class="software-gaps">')
        $gapStatusText=@{Partial='只取得部分資料';Failed='取得失敗';PermissionDenied='權限不足';Unsupported='此環境不支援';NotInstalled='未安裝'}
        foreach($gap in @($document.Software.CoverageGaps | Where-Object {$null -ne $_})){
            $gapParts=@(foreach($field in @('Probe','Scope','SID','View')){if($gap.PSObject.Properties[$field] -and [string]$gap.$field){[string]$gap.$field}})
            $gapStatus=[string]$gap.Status
            [void]$page.Append('<li>'+(& $encode $(if($gapStatusText.ContainsKey($gapStatus)){$gapStatusText[$gapStatus]}else{$gapStatus}))+'：'+(& $encode $(if($gapParts.Count){$gapParts -join ' / '}else{'範圍未記錄'}))+'</li>')
        }
        [void]$page.Append('</ul>'+"`n")
    }
    [void]$page.Append('<h3>安裝軟體清單</h3>'+"`n"+$(if($softwareGrouped){'<p>分組：已選工作負載必需 '+$requiredSoftware.Count+' 筆排在前面，其他已發現軟體 '+$otherSoftware.Count+' 筆在後；沒有關聯證據不等於不需要。</p>'+"`n"}else{'<p>此結果集未記錄工作負載分組。</p>'+"`n"})+(& $buildTable 'tbl-software' '安裝軟體' '1,2,4,7' @('分組','名稱','版本','選用版本','發行者','架構','範圍','安裝位置','工作負載','決策','審閱狀態','人工備註') $softwareCells '0:分組;9:決策;5:架構' 'installed-software.csv' $softwareAttrs 'software' $softwareEmptyText)+"`n"+'<h3>Windows 角色與功能</h3>'+"`n"+(& $buildTable 'tbl-features' 'Windows 角色與功能' '0,1' @('顯示名稱','Install-WindowsFeature 名稱','關聯工作負載') $featureCells '' 'windows-features.csv' @() '1' '沒有發現已安裝的 Windows 角色或功能')+"`n</section>`n")
    [void]$page.Append("</main>`n"+$checklist.ToString()+"`n"+@'
<script>
(function(){
var doc=document,PAGE=100;
doc.documentElement.className+=' js';
function mk(tag,text,cls){var e=doc.createElement(tag);if(text)e.textContent=text;if(cls)e.className=cls;return e;}
function cellText(c){return c.hasAttribute('data-text')?c.getAttribute('data-text'):c.textContent;}
function csvCell(v){var t=v==null?'':String(v);if(/^[=+\-@\t\r]/.test(t))t="'"+t;return '"'+t.replace(/"/g,'""')+'"';}
function downloadCsv(name,headers,rows){
 var lines=[headers].concat(rows).map(function(r){return r.map(csvCell).join(',');});
 var blob=new Blob(['﻿'+lines.join('\r\n')+'\r\n'],{type:'text/csv;charset=utf-8'});
 var url=URL.createObjectURL(blob),a=doc.createElement('a');
 a.href=url;a.download=name;a.hidden=true;doc.body.appendChild(a);a.click();doc.body.removeChild(a);
 setTimeout(function(){URL.revokeObjectURL(url);},0);
}
function enhanceTable(table){
 var wrap=table.parentNode,body=table.tBodies[0],allRows=[].slice.call(body.rows),rows=allRows.filter(function(r){return !/(^|\s)region-detail-row(\s|$)/.test(r.className);});
 var detailOf=rows.map(function(r){var n=r.nextElementSibling;return n&&/(^|\s)region-detail-row(\s|$)/.test(n.className)?n:null;}),open=rows.map(function(){return false;});
 var cols=(table.getAttribute('data-search')||'0').split(',');
 var texts=rows.map(function(r){return cols.map(function(c){return r.cells[+c]?cellText(r.cells[+c]):'';}).join('\n').toLowerCase();});
 var defs=(table.getAttribute('data-filters')||'').split(';').filter(Boolean).map(function(s){var i=s.indexOf(':');return {col:+s.slice(0,i),label:s.slice(i+1)};});
 var bar=mk('div','','toolbar'),label=mk('label',table.getAttribute('data-search-label')||'搜尋名稱或位置'),input=doc.createElement('input');
 input.type='search';input.id=table.id+'-q';input.autocomplete='off';label.htmlFor=input.id;bar.appendChild(label);bar.appendChild(input);
 var selects=defs.map(function(f){
  var sel=doc.createElement('select'),lab=mk('label',f.label),seen=Object.create(null),vals=[];
  sel.id=table.id+'-f'+f.col;lab.htmlFor=sel.id;
  rows.forEach(function(r){var v=r.cells[f.col]?cellText(r.cells[f.col]):'';if(!seen[v]){seen[v]=1;vals.push(v);}});
  vals.sort();
  var all=doc.createElement('option');all.value='';all.textContent='全部';sel.appendChild(all);
  vals.forEach(function(v){var o=doc.createElement('option');o.value=v;o.textContent=v;sel.appendChild(o);});
  bar.appendChild(lab);bar.appendChild(sel);return sel;
 });
 var csvName=table.getAttribute('data-csv'),csvMeta=table.getAttribute('data-csv-meta')||'',exportButton=null;
 if(csvName){exportButton=mk('button','匯出 CSV');exportButton.type='button';bar.appendChild(exportButton);}
 var count=mk('div','','count');count.setAttribute('role','status');count.setAttribute('aria-atomic','true');bar.appendChild(count);
 var none=mk('p','沒有符合搜尋條件的項目','empty');none.hidden=true;
 var pager=mk('div','','pager'),prev=mk('button','上一頁'),next=mk('button','下一頁'),pageInfo=mk('span');
 prev.type='button';next.type='button';
 pager.appendChild(prev);pager.appendChild(pageInfo);pager.appendChild(next);
 wrap.parentNode.insertBefore(bar,wrap);wrap.parentNode.insertBefore(none,wrap);wrap.parentNode.insertBefore(pager,wrap.nextSibling);
 var page=0,matched=[];
 function draw(){
  var q=input.value.toLowerCase(),m=[],i;
  for(i=0;i<rows.length;i++){
   if(q&&texts[i].indexOf(q)<0)continue;
   var ok=true;
   for(var k=0;k<selects.length;k++){if(selects[k].value&&cellText(rows[i].cells[defs[k].col])!==selects[k].value){ok=false;break;}}
   if(ok)m.push(i);
  }
  matched=m;
  var pages=Math.max(1,Math.ceil(m.length/PAGE));
  if(page>=pages)page=pages-1;if(page<0)page=0;
  for(i=0;i<rows.length;i++)rows[i].hidden=true;
  m.slice(page*PAGE,(page+1)*PAGE).forEach(function(k){rows[k].hidden=false;});
  for(i=0;i<rows.length;i++){if(detailOf[i])detailOf[i].hidden=rows[i].hidden||!open[i];}
  wrap.hidden=!m.length;none.hidden=m.length>0;pager.hidden=!m.length;
  count.textContent='顯示 '+m.length+'／共 '+rows.length+' 筆';
  pageInfo.textContent=m.length?'第 '+(page+1)+'／'+pages+' 頁':'';
  prev.hidden=next.hidden=pages<2;prev.disabled=page<=0;next.disabled=page>=pages-1;
 }
 input.addEventListener('input',function(){page=0;draw();});
 selects.forEach(function(s){s.addEventListener('change',function(){page=0;draw();});});
 prev.addEventListener('click',function(){page--;draw();});
 next.addEventListener('click',function(){page++;draw();});
 if(exportButton)exportButton.addEventListener('click',function(){
  var headers=[].slice.call(table.tHead.rows[0].cells).map(function(c){return c.textContent;});
  if(csvMeta==='1')headers=headers.concat(['項目 ID','狀態碼','原因碼']);else if(csvMeta==='software')headers=headers.concat(['SoftwareId']);else if(csvMeta==='region')headers=headers.concat(['原因碼']);
  var out=matched.map(function(i){
   var r=rows[i],cells=[].slice.call(r.cells).map(cellText);
   if(csvMeta==='1')cells=cells.concat([r.getAttribute('data-id'),r.getAttribute('data-status'),r.getAttribute('data-reason')]);else if(csvMeta==='software')cells=cells.concat([r.getAttribute('data-sid')]);else if(csvMeta==='region')cells=cells.concat([r.getAttribute('data-reason')]);
   return cells;
  });
  downloadCsv(csvName,headers,out);
 });
 rows.forEach(function(r,i){
  var d=detailOf[i],host=r.querySelector('.region-summary');if(!d||!host)return;
  var label=host.textContent,b=mk('button','▸ '+label,'region-toggle');
  b.type='button';b.setAttribute('aria-expanded','false');b.setAttribute('aria-controls',d.id);
  b.addEventListener('click',function(){open[i]=!open[i];b.setAttribute('aria-expanded',open[i]?'true':'false');b.textContent=(open[i]?'▾ ':'▸ ')+label;d.hidden=rows[i].hidden||!open[i];});
  host.textContent='';host.appendChild(b);
 });
 draw();
}
[].slice.call(doc.querySelectorAll('table[data-search]')).forEach(enhanceTable);
var checklist=doc.getElementById('checklist'),softwareSection=doc.getElementById('software');
if(checklist&&softwareSection){
 var tools=mk('div','','toolbar checklist-tools'),printButton=mk('button','列印新機安裝檢查表'),printHint=mk('span','產生含勾選方框的列印版面（全部列、不分頁）；工具不會安裝軟體。'),anchor=softwareSection.querySelector('h3');
 printButton.type='button';tools.appendChild(printButton);tools.appendChild(printHint);
 if(anchor)anchor.parentNode.insertBefore(tools,anchor);else softwareSection.appendChild(tools);
 printButton.addEventListener('click',function(){if(!/(^|\s)print-checklist(\s|$)/.test(doc.body.className))doc.body.className+=' print-checklist';window.print();});
 window.addEventListener('afterprint',function(){doc.body.className=doc.body.className.replace(/(^|\s)print-checklist(?=\s|$)/g,'');});
}
var sections=[].slice.call(doc.querySelectorAll('main > section[data-tab]'));
if(!sections.length)return;
var list=mk('div','','tabs'),tabs=[];
list.setAttribute('role','tablist');list.setAttribute('aria-label','備份明細分頁');
function select(n,focus){
 sections.forEach(function(s,i){var on=i===n;tabs[i].setAttribute('aria-selected',on?'true':'false');tabs[i].tabIndex=on?0:-1;s.hidden=!on;});
 if(focus)tabs[n].focus();
}
sections.forEach(function(s,i){
 var t=mk('button',s.getAttribute('data-tab'));
 t.type='button';t.id='tab-'+s.id;t.setAttribute('role','tab');t.setAttribute('aria-controls',s.id);
 s.setAttribute('role','tabpanel');s.setAttribute('aria-labelledby',t.id);
 t.addEventListener('click',function(){select(i,false);});
 t.addEventListener('keydown',function(e){
  var n=-1;
  if(e.key==='ArrowRight')n=(i+1)%sections.length;else if(e.key==='ArrowLeft')n=(i+sections.length-1)%sections.length;else if(e.key==='Home')n=0;else if(e.key==='End')n=sections.length-1;
  if(n<0)return;e.preventDefault();select(n,true);
 });
 list.appendChild(t);tabs.push(t);
});
sections[0].parentNode.insertBefore(list,sections[0]);
select(0,false);
})();
</script>
</body>
</html>
'@)
    $text=$page.ToString().Replace("`r`n","`n")
    [IO.File]::WriteAllText($OutputPath,$text,(New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($OutputPath);SHA256=(Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()}
}

# N6 (16.3-1)：隨交付附上的離線使用說明。靜態、唯讀、不連網、無 script；HTML 與純文字備援由同一份內容產生。
# 說明檔放在交付描述檔旁，不進封裝本體（16.5：不可循環引用自身 hash）；雜湊記在 attempt 的 OfflineGuide 並進獨立副本收據。
# 只寫檔名，不寫任何絕對路徑；也不收任何秘密。傳入的字串一律跳脫（HTML）或去除控制字元（文字）。
function Export-WsmBackupOfflineGuide([string]$HtmlPath,[string]$TextPath,$Facts) {
    Assert-WsmNoReparse $HtmlPath
    Assert-WsmNoReparse $TextPath
    $clean={param($Value)$t=[string]$Value;($t -replace '[\x00-\x1f\x7f]',' ').Trim()}
    $leaf={param($Value)$t=& $clean $Value;if(-not $t){return ''};[string]($t.Replace('/','\').Split('\')[-1])}
    $hashOf={param($Value)$t=([string]$Value).Trim().ToLowerInvariant();if($t -match '^[0-9a-f]{64}$'){$t}else{''}}
    $field={param([string]$Name)if($Facts.PSObject.Properties[$Name]){[string]$Facts.$Name}else{''}}
    $notRecorded='未記錄'
    $orNone={param($Value)$v=& $clean $Value;if($v){$v}else{$notRecorded}}
    $toolVersion=& $orNone (& $field 'ToolVersion')
    $toolFingerprint=& $orNone (& $hashOf (& $field 'ToolFingerprint'))
    $pairId=& $orNone (& $field 'PairId')
    $attemptId=& $orNone (& $field 'AttemptId')
    $mode=& $clean (& $field 'Mode')
    $modeText=$(switch($mode){'Directory'{'Directory（交付資料夾）'}'Zip'{'ZIP（分卷壓縮檔）'}default{& $orNone $mode}})
    $generatedUtc=& $orNone (& $field 'GeneratedUtc')
    $manifestHash=& $orNone (& $hashOf (& $field 'ManifestHash'))
    $planHash=& $orNone (& $hashOf (& $field 'PlanHash'))
    $deliveryName=& $orNone (& $leaf (& $field 'DeliveryName'))
    $deliveryHash=& $orNone (& $hashOf (& $field 'DeliverySHA256'))
    $resultsHash=& $orNone (& $hashOf (& $field 'ItemResultsSHA256'))
    $reportHash=& $orNone (& $hashOf (& $field 'OfflineReportSHA256'))
    $descriptorLabel=$(if($mode -ceq 'Zip'){'交付描述檔（transport.json）'}else{'交付描述檔（Directory 交付摘要）'})

    $html=New-Object Text.StringBuilder
    $txt=New-Object Text.StringBuilder
    $enc={param($v)ConvertTo-WsmHtmlText $v}
    $addH2={param([string]$Id,[string]$Title)[void]$html.Append('<section aria-labelledby="'+$Id+'"><h2 id="'+$Id+'">'+(& $enc $Title)+'</h2>');[void]$txt.Append("`n"+$Title+"`n"+('-'*30)+"`n")}
    $endSection={[void]$html.Append('</section>')}
    $addP={param([string]$Text)[void]$html.Append('<p>'+(& $enc $Text)+'</p>');[void]$txt.Append($Text+"`n")}
    $addList={param([string]$Tag,[string[]]$Items)[void]$html.Append('<'+$Tag+'>');$n=0;foreach($item in $Items){$n++;[void]$html.Append('<li>'+(& $enc $item)+'</li>');if($Tag -ceq 'ol'){[void]$txt.Append(([string]$n)+'. '+$item+"`n")}else{[void]$txt.Append('- '+$item+"`n")}};[void]$html.Append('</'+$Tag+'>')}
    $addMeta={param([object[]]$Rows)[void]$html.Append('<dl class="meta">');foreach($row in $Rows){$isHash=($row.Length -gt 2 -and $row[2] -ceq 'hash');[void]$html.Append('<dt>'+(& $enc $row[0])+'</dt><dd>'+$(if($isHash -and $row[1] -cne $notRecorded){'<code class="hash">'+(& $enc $row[1])+'</code>'}else{& $enc $row[1]})+'</dd>');[void]$txt.Append($row[0]+'：'+$row[1]+"`n")};[void]$html.Append('</dl>')}
    $addCode={param([string]$Text)[void]$html.Append('<pre><code>'+(& $enc $Text)+'</code></pre>');foreach($line in $Text.Split("`n")){[void]$txt.Append('    '+$line+"`n")}}

    $title='新機離線使用說明'
    [void]$html.Append('<!doctype html>'+"`n"+'<html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'+"`n"+'<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">'+"`n"+'<title>'+(& $enc $title)+'</title>'+"`n"+'<style>'+"`n")
    [void]$html.Append('body{margin:0;font:16px/1.6 system-ui,"Noto Sans TC","Microsoft JhengHei",sans-serif;color:#172033;background:#fff}'+"`n")
    [void]$html.Append('main{max-width:52rem;margin:0 auto;padding:1rem}'+"`n")
    [void]$html.Append('h1{font-size:1.5rem;margin:.5rem 0}h2{font-size:1.25rem;margin:1.5rem 0 .5rem;border-bottom:2px solid #172033}'+"`n")
    [void]$html.Append('p,li{overflow-wrap:anywhere}ol,ul{padding-left:1.5rem}li{margin:.35rem 0}'+"`n")
    [void]$html.Append('dl.meta{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:.25rem 1rem;margin:.5rem 0}dl.meta dt{font-weight:700}dl.meta dd{margin:0;min-width:0;overflow-wrap:anywhere}'+"`n")
    [void]$html.Append('code,pre{font-family:ui-monospace,Consolas,"Courier New",monospace;font-size:.9rem}code.hash{overflow-wrap:anywhere;word-break:break-all}'+"`n")
    [void]$html.Append('pre{margin:.5rem 0;padding:.5rem .75rem;background:#eef2f7;border:1px solid #bbc4ce;border-radius:4px;white-space:pre-wrap;overflow-wrap:anywhere}'+"`n")
    [void]$html.Append('.note{border:2px solid #7a5a00;background:#fff6d6;padding:.75rem 1rem;margin:1rem 0;border-radius:4px}'+"`n")
    [void]$html.Append('a{color:#1b5fc1}a:focus,summary:focus{outline:3px solid #1b5fc1;outline-offset:2px}'+"`n")
    [void]$html.Append('@media (max-width:480px){main{padding:.5rem}dl.meta{grid-template-columns:minmax(0,1fr)}}'+"`n")
    [void]$html.Append('@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important;scroll-behavior:auto!important}}'+"`n")
    [void]$html.Append('</style></head><body><main>'+"`n"+'<h1>'+(& $enc $title)+'</h1>')
    [void]$txt.Append($title+"`n"+('='*30)+"`n")
    & $addP '這份說明隨備份交付一併產生，給在新機操作、沒有舊機也不一定能上網的人閱讀。內容是靜態的，不會連網，也不會執行任何動作。'
    $warning='警語：這份說明只記錄產生當時的狀態，不代表媒體目前仍完整、也不代表備份可以還原。新機匯入時，工具會重新驗證每一個檔案的內容；驗證失敗就不會匯入。'
    [void]$html.Append('<p class="note" role="note"><strong>'+(& $enc $warning)+'</strong></p>');[void]$txt.Append("`n"+$warning+"`n")

    & $addH2 'sec-backup' '一、這份備份'
    & $addMeta @(@('配對 ID',$pairId),@('Attempt ID',$attemptId),@('交付方式',$modeText),@('說明產生時間（UTC）',$generatedUtc))
    & $endSection

    & $addH2 'sec-tool' '二、如何取得相容工具'
    & $addMeta @(@('工具版本',$toolVersion),@('ToolVersion（交付資料的版本標記）',$toolVersion),@('工具指紋（ToolFingerprint）',$toolFingerprint,'hash'))
    & $addList 'ul' @(
        '新機必須使用與上列版本相同的工具；版本不同的工具不保證讀得懂這份備份，也不要自行轉換格式。',
        '請向舊機的操作人員或貴組織的軟體發行管道，索取該版本的工具發行包（ZIP）、簽章檔與信任政策。',
        '這份說明不提供下載連結，新機也不必連回舊機下載任何東西。',
        '不要執行交付資料夾或壓縮檔裡的任何程式；備份內容只當資料讀取。')
    & $endSection

    & $addH2 'sec-verify' '三、如何驗證工具'
    & $addList 'ol' @(
        '用「不是這份交付」的獨立管道（例如當面、電話或公司的發行系統）取得發行包的 SHA256、簽章檔的 SHA256 與信任政策的 SHA256。',
        '在 Windows PowerShell 5.1 計算發行包的雜湊，並與取得的值逐字比對：',
        '若手上已有一份可信的同版本工具，用它驗證新取得的發行包簽章：')
    & $addCode 'Get-FileHash -Algorithm SHA256 -LiteralPath <發行包.zip>'
    & $addCode "Test-WsmToolRelease -Path <發行包.zip> -ExpectedHash <發行包SHA256> `n  -SignaturePath <簽章檔> -ExpectedSignatureHash <簽章SHA256> `n  -TrustPolicyPath <信任政策檔> -TrustPolicyHash <信任政策SHA256>"
    & $addP '不要用這份交付裡算出來的雜湊來當授權依據；雜湊與簽章必須來自獨立可信的管道。'
    & $endSection

    & $addH2 'sec-trust' '四、信任材料'
    & $addP '匯入時，請把下列值與舊機操作者另外給你的值逐字比對。不要只因為它們出現在這份說明裡就信任。'
    & $addMeta @(@('封裝 manifest 雜湊（manifest hash）',$manifestHash,'hash'),@('核准計畫雜湊（plan hash）',$planHash,'hash'),@('交付描述檔名稱',$deliveryName),@(($descriptorLabel+' 雜湊'),$deliveryHash,'hash'),@('逐項結果檔雜湊（backup-item-results.json）',$resultsHash,'hash'),@('備份報告雜湊（backup-report.html）',$reportHash,'hash'))
    & $endSection

    & $addH2 'sec-import' '五、新機匯入步驟'
    & $addList 'ol' @(
        '在新機以管理員身分開啟 Windows PowerShell 5.1，啟動上面驗證過的工具（Start-ServerMigration.ps1），選擇「目標」角色，指定專用的固定 WorkRoot。',
        '登記這台新機的身分；身分要和備份核准時指定的目標主機相符。',
        '匯入交付：Directory 選擇交付資料夾與其摘要檔，ZIP 選擇描述檔 transport.json 與同資料夾的所有分卷。',
        '貼上上面「信任材料」中經獨立管道核對過的雜湊；不符就停止，不要繼續。',
        '工具會重新驗證封裝與每個檔案，並在新機重新檢查目前的環境與軟體，再讓你勾選要還原的項目與預覽。',
        '還原前先看預覽；工具不會自動安裝軟體，需要的軟體、角色與帳密請依清單在新機補齊。')
    & $endSection

    & $addH2 'sec-docs' '六、既有文件的離線位置'
    & $addP '下列文件都在工具發行包內（相對於工具資料夾），可直接用瀏覽器開啟：'
    & $addList 'ul' @('docs\html\README.html（總覽）','docs\html\OPERATIONS.html（操作）','docs\html\GENERAL-HOST-WORKFLOW.html（一般主機流程）','docs\html\RECOVERY-RUNBOOK.html（中斷與復原）')
    if($resultsHash -cne $notRecorded){
        & $addP '同一個交付資料夾內的備份報告（逐項清單，可離線查閱）：'
        [void]$html.Append('<p><a href="backup-report.html">backup-report.html</a></p>');[void]$txt.Append("backup-report.html`n")
    }
    & $endSection
    [void]$html.Append("`n"+'</main></body></html>'+"`n")
    $htmlText=$html.ToString().Replace("`r`n","`n")
    $plainText=($txt.ToString().Replace("`r`n","`n")).Replace("`n","`r`n")
    [IO.File]::WriteAllText($HtmlPath,$htmlText,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($TextPath,$plainText,(New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($HtmlPath);SHA256=(Get-FileHash -LiteralPath $HtmlPath -Algorithm SHA256).Hash.ToLowerInvariant();TextPath=[IO.Path]::GetFullPath($TextPath);TextSHA256=(Get-FileHash -LiteralPath $TextPath -Algorithm SHA256).Hash.ToLowerInvariant()}
}

# 交付驗證：attempt 記了說明檔雜湊時，兩個檔都必須還在、內容一致；沒有記錄（舊 attempt 或產生失敗）則不檢查。回傳 $null 表示通過，否則是一句原因。
function Test-WsmBackupOfflineGuideFiles($Attempt) {
    if(-not $Attempt.PSObject.Properties['OfflineGuide'] -or -not $Attempt.OfflineGuide -or -not $Attempt.OfflineGuide.PSObject.Properties['Status'] -or [string]$Attempt.OfflineGuide.Status -cne 'Generated'){return $null}
    $guide=$Attempt.OfflineGuide
    foreach($pair in @(@([string]$guide.Path,[string]$guide.SHA256),@([string]$guide.TextPath,[string]$guide.TextSHA256))){
        if(-not $pair[0] -or $pair[1] -notmatch '^[a-fA-F0-9]{64}$'){return '離線使用說明的紀錄不完整。'}
        Assert-WsmNoReparse $pair[0]
        if(-not [IO.File]::Exists($pair[0]) -or (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ine $pair[1]){return '離線使用說明檔已不存在或內容被更改，請重新備份。'}
    }
    $null
}

# Latest delivered attempt that carries an item-results record and is bound to the current approved plan.
# Read-only: the backup root is computed without the owned-directory helper, which would create it.
function Get-WsmWizardLatestResultAttempt([string]$Workspace,[string]$PairId,$Profile,$PlanRef) {
    $viewBackupRoot=Join-Path (Join-Path (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'workspace-control') 'wizard-backups') $PairId
    if(-not [IO.Directory]::Exists($viewBackupRoot)){return $null}
    Assert-WsmNoReparse $viewBackupRoot
    $latest=$null
    foreach($file in @(Get-ChildItem -LiteralPath $viewBackupRoot -Filter '*.json' -File)){
        try{
            $row=Read-WsmJson $file.FullName
            [void](Assert-WsmWizardBackupAttempt $row $Workspace $PairId $Profile)
        }catch{continue}
        if([string]$row.PlanHash -ine [string]$PlanRef.SHA256 -or $row.Stage -cne 'Delivered' -or -not $row.PSObject.Properties['ItemResults']){continue}
        if(-not $latest -or [string]$row.UpdatedUtc -gt [string]$latest.UpdatedUtc){$latest=$row}
    }
    $latest
}

# N3: a failed (not delivered) attempt bound to the approved plan. Capture is all-or-nothing, so a failed attempt has no
# result set; this is the only place a capture failure or a failed read-back can be shown. Read-only, like the helper above.
function Get-WsmWizardLatestFailedAttempt([string]$Workspace,[string]$PairId,$Profile,$PlanRef) {
    $viewBackupRoot=Join-Path (Join-Path (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'workspace-control') 'wizard-backups') $PairId
    if(-not [IO.Directory]::Exists($viewBackupRoot)){return $null}
    Assert-WsmNoReparse $viewBackupRoot
    $latest=$null
    foreach($file in @(Get-ChildItem -LiteralPath $viewBackupRoot -Filter '*.json' -File)){
        try{
            $row=Read-WsmJson $file.FullName
            [void](Assert-WsmWizardBackupAttempt $row $Workspace $PairId $Profile)
        }catch{continue}
        if([string]$row.PlanHash -ine [string]$PlanRef.SHA256 -or [string]$row.Stage -cne 'Failed' -or -not $row.PSObject.Properties['Error'] -or $null -eq $row.Error){continue}
        if(-not $latest -or [string]$row.UpdatedUtc -gt [string]$latest.UpdatedUtc){$latest=$row}
    }
    $latest
}

# Classification comes from the durable error code written by the stage that failed:
#   core_export_failed  CaptureFailed  capture/seal did not finish; nothing partial is kept as a result set
#   package_test_failed NotVerified    sealed, but the read-back verification did not pass
#   delivery_failed     DeliveryFailed verified package, hand-over material incomplete
function ConvertTo-WsmBackupFailureView($Attempt) {
    $code=[string]$Attempt.Error.Code
    $table=@{
        core_export_failed=@('CaptureFailed','擷取或封存失敗','封存沒有完成，所以沒有產生任何備份結果集；工具不會把部分擷取的內容當成已備份。','修正失敗項目的問題後，從同一個作業續作。')
        package_test_failed=@('NotVerified','已封存但讀回驗證未通過','封存後的讀回驗證沒有通過，這份備份不能視為已備份。','先檢查作業紀錄與儲存空間，再從同一個作業續作驗證。')
        delivery_failed=@('DeliveryFailed','交接材料未完整產生','封裝已通過驗證，但交接材料沒有完整產生。','從同一個作業續作。')
    }
    $entry=$(if($table.ContainsKey($code)){$table[$code]}else{@('Failed','備份未完成','這次備份沒有完成。','查看作業紀錄後再續作。')})
    $failedItem=$null
    if($Attempt.Error.PSObject.Properties['FailedItem'] -and $Attempt.Error.FailedItem){
        $item=$Attempt.Error.FailedItem
        $failedItem=[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Name=[string]$item.Name;Kind=[string]$item.Kind;Channel=[string]$item.Channel;ErrorClass=[string]$item.ErrorClass;ErrorKind=[string]$item.ErrorKind}
    }
    [pscustomobject][ordered]@{attemptId=[string]$Attempt.AttemptId;errorCode=$code;classification=$entry[0];title=$entry[1];detail=$entry[2];nextStep=$entry[3];updatedUtc=[string]$Attempt.UpdatedUtc;failedItem=$failedItem}
}

# Re-checks the independent-copy receipt every time the view is read. The receipt is a set-level record
# (one per backup set, not per item), so the answer is one state for the whole column:
#   Verified     the attempt names a receipt that exists, whose bytes match the recorded SHA256, which belongs
#                to this pair/attempt/delivery and which cites the SHA256 of the current item-results set
#   NotVerified  no verified independent copy was ever recorded for this attempt
#   Unverifiable a verified copy is recorded but the receipt is missing, altered, outside its folder or
#                cites another result set; never presented as verified
# The attempt records only its newest receipt hash, so older receipts cannot be bound and are not consulted.
# This function only reads; sealed bytes are never modified (16.5: the receipt is stored apart from the set).
function Get-WsmWizardIndependentCopyProjection([string]$Workspace,[string]$PairId,$Attempt,[string]$ItemResultsSha256) {
    $notVerified=[pscustomobject][ordered]@{state='NotVerified';text='尚未驗證';verifiedUtc='';networkUnconfirmed=$false;reason='尚未建立並驗證獨立副本。'}
    $copy=$null;if($Attempt.PSObject.Properties['IndependentCopy']){$copy=$Attempt.IndependentCopy}
    if(-not $copy -or -not $copy.PSObject.Properties['Status'] -or [string]$copy.Status -cne 'Verified'){return $notVerified}
    $unverifiable={param([string]$Why)[pscustomobject][ordered]@{state='Unverifiable';text='收據無法核對';verifiedUtc='';networkUnconfirmed=$false;reason=$Why}}
    try{
        if(-not $copy.PSObject.Properties['ReceiptPath'] -or -not $copy.PSObject.Properties['ReceiptSHA256']){return (& $unverifiable '備份紀錄沒有收據路徑或雜湊。')}
        $receiptPath=[IO.Path]::GetFullPath([string]$copy.ReceiptPath)
        $receiptDir=([IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'workspace-control') 'wizard-backups') $PairId) 'independent-copies'))).TrimEnd('\')+'\'
        if(-not $receiptPath.StartsWith($receiptDir,[StringComparison]::OrdinalIgnoreCase)){return (& $unverifiable '收據不在備份集的收據資料夾內。')}
        Assert-WsmNoReparse $receiptPath
        if(-not [IO.File]::Exists($receiptPath)){return (& $unverifiable '收據檔已不存在。')}
        $recordedHash=[string]$copy.ReceiptSHA256
        if($recordedHash -notmatch '^[a-fA-F0-9]{64}$'){return (& $unverifiable '備份紀錄中的收據雜湊格式不正確。')}
        if((Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash -ine $recordedHash){return (& $unverifiable '收據檔內容與備份紀錄的雜湊不一致。')}
        $receipt=Read-WsmJson $receiptPath
        if([string]$receipt.Kind -cne 'IndependentCopyReceipt' -or [string]$receipt.PairId -cne $PairId -or [string]$receipt.AttemptId -cne [string]$Attempt.AttemptId){return (& $unverifiable '收據不屬於此備份。')}
        if(-not $Attempt.Delivery -or -not $receipt.PSObject.Properties['DeliverySHA256'] -or [string]$receipt.DeliverySHA256 -ine [string]$Attempt.Delivery.SHA256){return (& $unverifiable '收據引用的交付與目前備份的交付不同。')}
        if(-not $receipt.PSObject.Properties['ItemResultsSHA256'] -or [string]$receipt.ItemResultsSHA256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$receipt.ItemResultsSHA256 -ine $ItemResultsSha256){return (& $unverifiable '收據沒有引用、或引用的不是目前的逐項結果集。')}
        if($Attempt.PSObject.Properties['OfflineGuide'] -and $Attempt.OfflineGuide -and $Attempt.OfflineGuide.PSObject.Properties['Status'] -and [string]$Attempt.OfflineGuide.Status -ceq 'Generated'){
            if(-not $receipt.PSObject.Properties['OfflineGuideSHA256'] -or -not $receipt.PSObject.Properties['OfflineGuideTextSHA256'] -or [string]$receipt.OfflineGuideSHA256 -ine [string]$Attempt.OfflineGuide.SHA256 -or [string]$receipt.OfflineGuideTextSHA256 -ine [string]$Attempt.OfflineGuide.TextSHA256){return (& $unverifiable '收據沒有引用、或引用的不是目前的離線使用說明。')}
        }
        [pscustomobject][ordered]@{state='Verified';text='已驗證';verifiedUtc=[string]$receipt.VerifiedUtc;networkUnconfirmed=([string]$receipt.Availability -ceq 'VerifiedNetworkAvailabilityUnconfirmed');reason=''}
    }catch{
        & $unverifiable '收據無法讀取或核對。'
    }
}

# Shared by the results view and the file drill-down: the verified item-results document of the latest delivered attempt.
# Failure is the user-facing view object when nothing can be shown; callers must stop on it.
function Get-WsmWizardVerifiedResultSet([string]$Workspace,[string]$PairId,$Profile,$PlanRef) {
    $none=[pscustomobject]@{kind='BackupItemResultsView';available=$false;reason='目前還沒有已交付的備份。'}
    $attempt=Get-WsmWizardLatestResultAttempt $Workspace $PairId $Profile $PlanRef
    if(-not $attempt){return [pscustomobject]@{Failure=$none;Attempt=$null;Document=$null;ResultsSha256=''}}
    $itemResults=$attempt.ItemResults
    if($itemResults.Status -cne 'Generated'){
        $errorText=if($itemResults.PSObject.Properties['Error']){[string]$itemResults.Error}else{''}
        return [pscustomobject]@{Failure=[pscustomobject]@{kind='BackupItemResultsView';available=$false;reason=('逐項結果產生失敗：'+$errorText);attemptId=[string]$attempt.AttemptId};Attempt=$attempt;Document=$null;ResultsSha256=''}
    }
    $failed=[pscustomobject]@{kind='BackupItemResultsView';available=$false;integrity='Failed';reason='逐項結果檔案已不存在或內容被更改，請重新備份。';attemptId=[string]$attempt.AttemptId}
    $resultPath=[string]$itemResults.Path
    Assert-WsmNoReparse $resultPath
    if(-not [IO.File]::Exists($resultPath) -or (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash -ine [string]$itemResults.SHA256){return [pscustomobject]@{Failure=$failed;Attempt=$attempt;Document=$null;ResultsSha256=''}}
    $document=Read-WsmJson $resultPath
    if($document.Kind -cne 'BackupItemResults' -or $document.PairId -cne $PairId -or $document.AttemptId -cne [string]$attempt.AttemptId){return [pscustomobject]@{Failure=$failed;Attempt=$attempt;Document=$null;ResultsSha256=''}}
    # N6：說明檔雜湊記在 attempt；說明檔遺失或被改，交付驗證就失敗（舊 attempt 沒有記錄則不檢查）。
    $guideProblem=Test-WsmBackupOfflineGuideFiles $attempt
    if($guideProblem){return [pscustomobject]@{Failure=[pscustomobject]@{kind='BackupItemResultsView';available=$false;integrity='Failed';reason=$guideProblem;attemptId=[string]$attempt.AttemptId};Attempt=$attempt;Document=$null;ResultsSha256=''}}
    [pscustomobject]@{Failure=$null;Attempt=$attempt;Document=$document;ResultsSha256=([string]$itemResults.SHA256).ToLowerInvariant()}
}

function Get-WsmWizardBackupItemResultsView([string]$Workspace,[string]$PairId) {
    Assert-WsmId $PairId
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Source'){throw 'Backup item results are only available on the enrolled Source workspace.'}
    $planRef=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile
    if(-not $planRef){return [pscustomobject]@{kind='BackupItemResultsView';available=$false;reason='尚未匯入已核准計畫，沒有備份結果可查看。'}}
    $set=Get-WsmWizardVerifiedResultSet $Workspace $PairId $profile $planRef
    if($set.Failure){
        # N3: nothing delivered yet. A failed attempt explains why (capture failed / read-back failed); it never becomes a result row.
        if(-not $set.Attempt){try{$failedAttempt=Get-WsmWizardLatestFailedAttempt $Workspace $PairId $profile $planRef;if($failedAttempt){$set.Failure | Add-Member NoteProperty failedAttempt (ConvertTo-WsmBackupFailureView $failedAttempt) -Force}}catch{}}
        return $set.Failure
    }
    $attempt=$set.Attempt;$document=$set.Document
    $excludedRecorded=($document.PSObject.Properties['ExcludedRegions'] -and $null -ne $document.ExcludedRegions)
    [pscustomobject][ordered]@{kind='BackupItemResultsView';available=$true;integrity='Verified';attemptId=[string]$attempt.AttemptId;backupOperationId=[string]$attempt.StartedByOperationId;generatedUtc=$document.GeneratedUtc;inventorySource=$document.InventorySource;offlineReadiness=(ConvertTo-WsmWizardBackupResult $attempt ([string]$attempt.StartedByOperationId)).OfflineReadiness;counts=$document.Counts;rows=@($document.Rows);software=$document.Software;schemaVersion=$(if($document.PSObject.Properties['SchemaVersion']){[int]$document.SchemaVersion}else{1});coverageRegions=$(if($document.PSObject.Properties['CoverageRegions']){@($document.CoverageRegions)}else{$null});excludedRegions=$(if($excludedRecorded){@($document.ExcludedRegions)}else{$null});excludedRegionsBinding=$(if($document.PSObject.Properties['ExcludedRegionsBinding']){$document.ExcludedRegionsBinding}else{$null});excludedCompleteness=$(if($excludedRecorded){Get-WsmBackupExcludedCompleteness @($document.ExcludedRegions)}else{Get-WsmBackupExcludedCompleteness $null});independentCopy=(Get-WsmWizardIndependentCopyProjection $Workspace $PairId $attempt $set.ResultsSha256)}
}

# Read-only drill-down (action BackupItemFiles): the archived files of one backed-up item, 100 per page.
# The list comes only from the sealed package of the attempt that produced the current result set:
# manifest bytes must match the hash the attempt recorded, the result set must cite that manifest, and the
# artifact index must match the hash inside the manifest before a single row is read. No journal write.
function Get-WsmWizardBackupItemFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId,[int]$Page=1)
    Assert-WsmId $PairId
    if([string]::IsNullOrWhiteSpace($ItemId) -or $ItemId.Length -gt 200 -or $ItemId -match '[\x00-\x1f\x7f]'){throw 'ItemId is not valid.'}
    if($Page -lt 1 -or $Page -gt 1000000){throw 'Page is out of range.'}
    $pageSize=100
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Source'){throw 'Backup file details are only available on the enrolled Source workspace.'}
    $planRef=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile
    if(-not $planRef){throw 'No approved plan has been imported, so there is no backup to read.'}
    $set=Get-WsmWizardVerifiedResultSet $Workspace $PairId $profile $planRef
    if($set.Failure){throw ([string]$set.Failure.reason)}
    $attempt=$set.Attempt;$document=$set.Document
    $row=@($document.Rows | Where-Object {[string]$_.ItemId -ceq $ItemId})
    if($row.Count -ne 1){throw 'The item is not part of the current backup result set.'}
    if([string]$row[0].Status -cne 'BackedUp'){throw 'The item was not backed up, so the package holds no files for it.'}
    $test=$attempt.PackageTest;$core=$attempt.CoreExport
    if(-not $test -or -not $core -or -not $test.PSObject.Properties['Valid'] -or -not [bool]$test.Valid -or -not $core.PSObject.Properties['Sealed'] -or -not [bool]$core.Sealed){throw 'The backup package is not sealed and verified.'}
    if([string]$test.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$test.SHA256 -ine [string]$core.SHA256 -or [string]$test.PlanHash -ine [string]$planRef.SHA256){throw 'The backup package record does not match the approved plan.'}
    if([string]$document.ManifestHash -ine [string]$test.SHA256){throw 'The result set does not belong to this backup package.'}
    $manifestPath=[IO.Path]::GetFullPath([string]$test.ManifestPath)
    Assert-WsmNoReparse $manifestPath
    $manifest=Read-WsmTrustedJson $manifestPath ([string]$test.SHA256)
    Assert-WsmEnvelope $manifest 'MigrationPackage'
    Assert-WsmPackageHeaderContract $manifest
    if([string]$manifest.PairId -cne $PairId -or [string]$manifest.PlanHash -ine [string]$planRef.SHA256){throw 'The backup package is bound to another pair or plan.'}
    if(-not $manifest.PSObject.Properties['SealedUtc'] -or -not [string]$manifest.SealedUtc){throw 'The backup package is not sealed.'}
    $indexPath=Join-Path (Split-Path -Parent $manifestPath) 'artifacts.jsonl'
    $skip=($Page-1)*$pageSize
    $count=@{Total=[long]0;Directories=[long]0}
    $entries=New-Object 'System.Collections.Generic.List[object]'
    # Read-WsmArtifactLines hashes the whole index against the manifest's ArtifactsHash before it yields any row.
    Read-WsmArtifactLines $indexPath ([string]$manifest.ArtifactsHash) | ForEach-Object {
        if([string]$_.ItemId -ceq $ItemId){
            $isDirectory=[bool]$_.Directory
            if($count.Total -ge $skip -and $entries.Count -lt $pageSize){
                $bytes=[long]0;$prefix=''
                if(-not $isDirectory -and $_.Data){$bytes=[long]$_.Data.Bytes;$fileHash=[string]$_.Data.Hash;if($fileHash.Length -ge 12){$prefix=$fileHash.Substring(0,12).ToLowerInvariant()}}
                $entries.Add([pscustomobject][ordered]@{RelativePath=[string]$_.RelativePath;Bytes=$bytes;Sha256Prefix=$prefix;IsDirectory=$isDirectory})
            }
            $count.Total++
            if($isDirectory){$count.Directories++}
        }
    }
    $total=[long]$count.Total
    [pscustomobject][ordered]@{kind='BackupItemFiles';available=$true;AttemptId=[string]$attempt.AttemptId;ItemId=$ItemId;Page=$Page;PageSize=$pageSize;TotalCount=$total;DirectoryCount=[long]$count.Directories;PageCount=[int][Math]::Max(1,[Math]::Ceiling($total/[double]$pageSize));Entries=@($entries.ToArray())}
}
