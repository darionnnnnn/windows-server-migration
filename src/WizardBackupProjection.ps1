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

function Get-WsmHtmlProgressProjection($Job) {
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
        param([string]$Id,[string]$Caption,[string]$SearchColumns,[string[]]$Headers,[object[]]$RowCells,[string]$Filters='',[string]$CsvName='',[string[]]$RowAttrs=@(),[string]$CsvMeta='1',[string]$EmptyText='沒有項目')
        if(@($RowCells).Count -eq 0){return '<p class="empty">'+(& $encode $EmptyText)+'</p>'}
        $sb=New-Object Text.StringBuilder
        $tableAttrs=' id="'+$Id+'"';if($SearchColumns){$tableAttrs+=' data-search="'+$SearchColumns+'"'};if($Filters){$tableAttrs+=' data-filters="'+(& $encode $Filters)+'"'};if($CsvName){$tableAttrs+=' data-csv="'+(& $encode $CsvName)+'"'};if(@($RowAttrs).Count){$tableAttrs+=' data-csv-meta="'+$CsvMeta+'"'}
        [void]$sb.Append('<div class="table-wrap" tabindex="0" role="region" aria-label="'+(& $encode $Caption)+'表格"><table'+$tableAttrs+'><caption>'+(& $encode $Caption)+'，共 '+@($RowCells).Count+' 筆</caption><thead><tr>')
        foreach($header in $Headers){[void]$sb.Append('<th scope="col">'+(& $encode $header)+'</th>')}
        [void]$sb.Append('</tr></thead><tbody>')
        $rowIndex=0
        foreach($cells in $RowCells){
            $attr='';if($rowIndex -lt @($RowAttrs).Count){$attr=' '+$RowAttrs[$rowIndex]}
            [void]$sb.Append('<tr'+$attr+'>')
            foreach($cell in $cells){
                if($cell -is [hashtable]){[void]$sb.Append('<td><span class="badge b-'+$cell.Class+'" data-icon="'+(& $encode $cell.Icon)+'">'+(& $encode $cell.Text)+'</span></td>')}
                else{[void]$sb.Append('<td>'+(& $encode $cell)+'</td>')}
            }
            [void]$sb.Append('</tr>')
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
    [void]$page.Append('<div class="layers" role="group" aria-labelledby="layers-title"><h2 id="layers-title">四層狀態說明</h2><ol>'+
        '<li><strong>資料已備份：</strong>本報告呈現（已備份與未備份分頁）。</li>'+
        '<li><strong>獨立副本已驗證：</strong>不在此報告判定。這是封存後才產生的收據，請看新機工作台或獨立副本收據。</li>'+
        '<li><strong>可還原條件：</strong>本報告呈現。'+$layerRestore+'</li>'+
        '<li><strong>業務可用：</strong>不在此報告判定。需要在新機驗證，本工具不判定。</li>'+
        '</ol></div>'+"`n")
    if($inventorySource -ceq 'Unavailable'){[void]$page.Append('<p class="callout">無法取得來源盤點，未備份清單只包含核准計畫內的項目，未選入的已發現項目沒有列出。</p>'+"`n")}
    [void]$page.Append('<section id="backed" data-tab="已備份（'+$backedRows.Count+'）"><h2>已備份（'+$backedRows.Count+'）</h2>'+"`n"+$noJsNote+"`n"+(& $buildTable 'tbl-backed' '已備份項目' '0,3' @('名稱','類型','工作負載','原位置','通道','檔案數','大小','狀態','可還原條件') $backedCells '1:類型;8:可還原條件' 'backup-backed-up.csv' $backedAttrs)+"`n</section>`n")
    [void]$page.Append('<section id="pending" data-tab="未備份（'+$pendingRows.Count+'）"><h2>未備份（'+$pendingRows.Count+'）</h2>'+"`n"+$noJsNote+"`n"+(& $buildTable 'tbl-pending' '未備份項目' '0,3' @('名稱','類型','工作負載','原位置','原因','下一步','盤點狀態','狀態') $pendingCells '1:類型;4:原因' 'backup-not-backed-up.csv' $pendingAttrs)+"`n"+'<h3>探索未涵蓋區域（以區域列出，不是項目）</h3>'+"`n"+$coverageHtml+"`n</section>`n")
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
function csvCell(v){var t=v==null?'':String(v);if(/^[=+\-@\t\r]/.test(t))t="'"+t;return '"'+t.replace(/"/g,'""')+'"';}
function downloadCsv(name,headers,rows){
 var lines=[headers].concat(rows).map(function(r){return r.map(csvCell).join(',');});
 var blob=new Blob(['﻿'+lines.join('\r\n')+'\r\n'],{type:'text/csv;charset=utf-8'});
 var url=URL.createObjectURL(blob),a=doc.createElement('a');
 a.href=url;a.download=name;a.hidden=true;doc.body.appendChild(a);a.click();doc.body.removeChild(a);
 setTimeout(function(){URL.revokeObjectURL(url);},0);
}
function enhanceTable(table){
 var wrap=table.parentNode,body=table.tBodies[0],rows=[].slice.call(body.rows);
 var cols=(table.getAttribute('data-search')||'0').split(',');
 var texts=rows.map(function(r){return cols.map(function(c){return r.cells[+c]?r.cells[+c].textContent:'';}).join('\n').toLowerCase();});
 var defs=(table.getAttribute('data-filters')||'').split(';').filter(Boolean).map(function(s){var i=s.indexOf(':');return {col:+s.slice(0,i),label:s.slice(i+1)};});
 var bar=mk('div','','toolbar'),label=mk('label','搜尋名稱或位置'),input=doc.createElement('input');
 input.type='search';input.id=table.id+'-q';input.autocomplete='off';label.htmlFor=input.id;bar.appendChild(label);bar.appendChild(input);
 var selects=defs.map(function(f){
  var sel=doc.createElement('select'),lab=mk('label',f.label),seen=Object.create(null),vals=[];
  sel.id=table.id+'-f'+f.col;lab.htmlFor=sel.id;
  rows.forEach(function(r){var v=r.cells[f.col]?r.cells[f.col].textContent:'';if(!seen[v]){seen[v]=1;vals.push(v);}});
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
   for(var k=0;k<selects.length;k++){if(selects[k].value&&rows[i].cells[defs[k].col].textContent!==selects[k].value){ok=false;break;}}
   if(ok)m.push(i);
  }
  matched=m;
  var pages=Math.max(1,Math.ceil(m.length/PAGE));
  if(page>=pages)page=pages-1;if(page<0)page=0;
  for(i=0;i<rows.length;i++)rows[i].hidden=true;
  m.slice(page*PAGE,(page+1)*PAGE).forEach(function(k){rows[k].hidden=false;});
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
  if(csvMeta==='1')headers=headers.concat(['項目 ID','狀態碼','原因碼']);else if(csvMeta==='software')headers=headers.concat(['SoftwareId']);
  var out=matched.map(function(i){
   var r=rows[i],cells=[].slice.call(r.cells).map(function(c){return c.textContent;});
   if(csvMeta==='1')cells=cells.concat([r.getAttribute('data-id'),r.getAttribute('data-status'),r.getAttribute('data-reason')]);else if(csvMeta==='software')cells=cells.concat([r.getAttribute('data-sid')]);
   return cells;
  });
  downloadCsv(csvName,headers,out);
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
    [pscustomobject]@{Failure=$null;Attempt=$attempt;Document=$document;ResultsSha256=([string]$itemResults.SHA256).ToLowerInvariant()}
}

function Get-WsmWizardBackupItemResultsView([string]$Workspace,[string]$PairId) {
    Assert-WsmId $PairId
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Source'){throw 'Backup item results are only available on the enrolled Source workspace.'}
    $planRef=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile
    if(-not $planRef){return [pscustomobject]@{kind='BackupItemResultsView';available=$false;reason='尚未匯入已核准計畫，沒有備份結果可查看。'}}
    $set=Get-WsmWizardVerifiedResultSet $Workspace $PairId $profile $planRef
    if($set.Failure){return $set.Failure}
    $attempt=$set.Attempt;$document=$set.Document
    [pscustomobject][ordered]@{kind='BackupItemResultsView';available=$true;integrity='Verified';attemptId=[string]$attempt.AttemptId;backupOperationId=[string]$attempt.StartedByOperationId;generatedUtc=$document.GeneratedUtc;inventorySource=$document.InventorySource;offlineReadiness=(ConvertTo-WsmWizardBackupResult $attempt ([string]$attempt.StartedByOperationId)).OfflineReadiness;counts=$document.Counts;rows=@($document.Rows);software=$document.Software;schemaVersion=$(if($document.PSObject.Properties['SchemaVersion']){[int]$document.SchemaVersion}else{1});coverageRegions=$(if($document.PSObject.Properties['CoverageRegions']){@($document.CoverageRegions)}else{$null});independentCopy=(Get-WsmWizardIndependentCopyProjection $Workspace $PairId $attempt $set.ResultsSha256)}
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
