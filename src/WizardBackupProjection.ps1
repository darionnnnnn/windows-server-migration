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

function Get-WsmBackupItemResultRows($Plan,$Inventory,[object[]]$ArtifactRows,[bool]$OfflineFullSet) {
    $reasonText=@{
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
        $rows.Add([pscustomobject][ordered]@{ItemId=$id;Name=[string](& $get $base 'Name');Kind=[string](& $get $base 'Kind');Category=[string](& $get $base 'Category');Location=$location;Channel=$channel;Status=$status;ReasonCode=$code;Reason=$reasonText[$code][0];NextStep=$reasonText[$code][1];Files=$files;Bytes=$bytes;Decision=$decision;DiscoveryStatus=$(if($inventoryItem){[string](& $get $inventoryItem 'Status')}else{''})})
    }
    @($rows.ToArray() | Sort-Object -Property @{Expression={if($_.Status -ceq 'BackedUp'){0}else{1}}},@{Expression={([string]$_.Name).ToLowerInvariant()}})
}

function Get-WsmBackupSoftwareRows($Plan,$Inventory) {
    $dispositionText=@{Reinstall='新機重新安裝';Portable='可攜版，隨資料搬移';KeepCompatible='保留相容版本';External='由外部處理';NotNeeded='新機不需要';SpecialProduct='特殊產品，人工處理';Unknown='尚未決定';Undecided='尚未決定'}
    $general=$(if($Plan.PSObject.Properties['GeneralHost']){$Plan.GeneralHost}else{$null})
    $catalog=$null
    if($general -and $general.PSObject.Properties['SoftwareCatalog'] -and $general.SoftwareCatalog -and $general.SoftwareCatalog.PSObject.Properties['Entries']){$catalog=$general.SoftwareCatalog}
    elseif($Inventory -and $Inventory.PSObject.Properties['SoftwareCatalog'] -and $Inventory.SoftwareCatalog -and $Inventory.SoftwareCatalog.PSObject.Properties['Entries']){$catalog=$Inventory.SoftwareCatalog}
    $decisionById=@{}
    if($general -and $general.PSObject.Properties['SoftwareDecisions']){foreach($decision in @($general.SoftwareDecisions)){if($decision){$decisionById[[string]$decision.SoftwareId]=$decision}}}
    $softwareRows=New-Object 'System.Collections.Generic.List[object]'
    if($catalog){
        foreach($entry in @($catalog.Entries)){
            $softwareId=[string]$entry.SoftwareId
            $disposition=$(if($decisionById.ContainsKey($softwareId)){[string]$decisionById[$softwareId].Disposition}else{'Undecided'})
            if(-not $dispositionText.ContainsKey($disposition)){$disposition='Unknown'}
            $version=[string]$entry.Version;if([string]::IsNullOrWhiteSpace($version)){$version='未知'}
            $softwareRows.Add([pscustomobject][ordered]@{SoftwareId=$softwareId;Name=[string]$entry.Name;Version=$version;Publisher=[string]$entry.Publisher;Architecture=[string]$entry.Architecture;Scope=[string]$entry.Scope;Location=[string]$entry.Location;SourceKind=[string]$entry.SourceKind;Disposition=$disposition;DispositionText=$dispositionText[$disposition]})
        }
    }
    $featureRows=New-Object 'System.Collections.Generic.List[object]'
    if($Inventory){foreach($inventoryItem in @($Inventory.Items)){if($inventoryItem.Category -ceq 'Roles' -and $inventoryItem.Kind -ceq 'WindowsFeature'){$featureRows.Add([pscustomobject][ordered]@{Name=[string]$inventoryItem.Name;FeatureName=[string]$inventoryItem.NaturalKey})}}}
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
        SoftwareRows=@($softwareRows.ToArray() | Sort-Object -Property @{Expression={([string]$_.Name).ToLowerInvariant()}},@{Expression={([string]$_.Version).ToLowerInvariant()}})
        FeatureRows=@($featureRows.ToArray())
        CoverageGaps=@($coverageGaps.ToArray())
    }
}

function Export-WsmBackupItemResults([string]$Path,[object[]]$Rows,$Meta) {
    $allRows=@($Rows)
    $backedUp=@($allRows | Where-Object Status -CEQ 'BackedUp').Count
    $counts=[ordered]@{Total=$allRows.Count;BackedUp=$backedUp;NotBackedUp=($allRows.Count-$backedUp);Software=@($Meta.Software.SoftwareRows).Count;Features=@($Meta.Software.FeatureRows).Count}
    $document=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='BackupItemResults';PairId=[string]$Meta.PairId;AttemptId=[string]$Meta.AttemptId;PlanHash=[string]$Meta.PlanHash;ManifestHash=[string]$Meta.ManifestHash;InventorySource=[string]$Meta.InventorySource;GeneratedUtc=(Get-WsmUtc);Counts=[pscustomobject]$counts;Software=[pscustomobject][ordered]@{SoftwareRows=@($Meta.Software.SoftwareRows);FeatureRows=@($Meta.Software.FeatureRows);CoverageGaps=@($Meta.Software.CoverageGaps)};Rows=$allRows}
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
    $buildTable={
        param([string]$Id,[string]$Caption,[string]$SearchColumns,[string[]]$Headers,[object[]]$RowCells)
        if(@($RowCells).Count -eq 0){return '<p class="empty">沒有項目</p>'}
        $sb=New-Object Text.StringBuilder
        [void]$sb.Append('<div class="table-wrap" tabindex="0" role="region" aria-label="'+(& $encode $Caption)+'表格"><table id="'+$Id+'" data-search="'+$SearchColumns+'"><caption>'+(& $encode $Caption)+'，共 '+@($RowCells).Count+' 筆</caption><thead><tr>')
        foreach($header in $Headers){[void]$sb.Append('<th scope="col">'+(& $encode $header)+'</th>')}
        [void]$sb.Append('</tr></thead><tbody>')
        foreach($cells in $RowCells){
            [void]$sb.Append('<tr>')
            foreach($cell in $cells){[void]$sb.Append('<td>'+(& $encode $cell)+'</td>')}
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</tbody></table></div>')
        $sb.ToString()
    }
    $allRows=@($document.Rows | Where-Object {$null -ne $_})
    $backedRows=@($allRows | Where-Object {[string]$_.Status -ceq 'BackedUp'})
    $pendingRows=@($allRows | Where-Object {[string]$_.Status -ceq 'NotBackedUp'})
    $softwareRows=@($document.Software.SoftwareRows | Where-Object {$null -ne $_})
    $featureRows=@($document.Software.FeatureRows | Where-Object {$null -ne $_})
    $gapCount=@($document.Software.CoverageGaps | Where-Object {$null -ne $_}).Count
    $backedCells=@(foreach($row in $backedRows){,@([string]$row.Name,[string]$row.Kind,[string]$row.Location,$(if($channelText.ContainsKey([string]$row.Channel)){$channelText[[string]$row.Channel]}else{[string]$row.Channel}),[string]$row.Files,(& $sizeText $row.Bytes))})
    $pendingCells=@(foreach($row in $pendingRows){,@([string]$row.Name,[string]$row.Kind,[string]$row.Location,[string]$row.Reason,[string]$row.NextStep,[string]$row.DiscoveryStatus)})
    $softwareCells=@(foreach($row in $softwareRows){,@([string]$row.Name,[string]$row.Version,[string]$row.Publisher,[string]$row.Architecture,[string]$row.Scope,[string]$row.Location,[string]$row.DispositionText)})
    $featureCells=@(foreach($row in $featureRows){,@([string]$row.Name,[string]$row.FeatureName)})
    $sourceTexts=@{PackageControls='封裝內的來源盤點';TrustedInventory='已核驗的來源盤點';Unavailable='無法取得來源盤點'}
    $inventorySource=[string]$document.InventorySource
    $sourceText=$(if($sourceTexts.ContainsKey($inventorySource)){$sourceTexts[$inventorySource]}else{$inventorySource})
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
dl.meta{display:grid;grid-template-columns:max-content 1fr;gap:.25rem 1rem;margin:.5rem 0}
dl.meta dt{font-weight:700}
dl.meta dd{margin:0;overflow-wrap:anywhere}
.note{border:2px solid #7a5a00;background:#fff6d6;padding:.75rem 1rem;margin:1rem 0;border-radius:4px}
.callout{border:2px solid #9b1c1c;background:#fdecec;padding:.75rem 1rem;margin:1rem 0;border-radius:4px}
.empty{font-style:italic;margin:.5rem 0}
.table-wrap{overflow-x:auto;max-width:100%;border:1px solid #bbc4ce}
.table-wrap:focus{outline:3px solid #1b5fc1;outline-offset:2px}
table{border-collapse:collapse;width:100%;font-size:.9rem}
caption{text-align:left;padding:.5rem;font-weight:700}
th,td{border:1px solid #bbc4ce;padding:.4rem .5rem;text-align:left;vertical-align:top;overflow-wrap:anywhere}
th{background:#eef2f7}
[hidden]{display:none!important}
.tabs{display:flex;flex-wrap:wrap;gap:.25rem;border-bottom:2px solid #172033;margin-top:1rem}
.tabs button{font:inherit;padding:.5rem .9rem;border:1px solid #172033;border-bottom:0;background:#eef2f7;color:#172033;cursor:pointer}
.tabs button[aria-selected=true]{background:#fff;font-weight:700;border-top:5px solid #172033;text-decoration:underline}
.tabs button:focus{outline:3px solid #1b5fc1;outline-offset:2px}
.toolbar,.pager{display:flex;flex-wrap:wrap;gap:.5rem;align-items:center;margin:.5rem 0}
.toolbar input{font:inherit;padding:.3rem .5rem;min-width:12rem;max-width:100%}
.pager button{font:inherit;padding:.3rem .8rem}
@media (max-width:480px){main{padding:.5rem}dl.meta{grid-template-columns:1fr}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important;scroll-behavior:auto!important}}
</style>
</head>
<body>
<main>
<h1>搬移備份報告</h1>
'@)
    [void]$page.Append("`n"+'<dl class="meta"><dt>配對 ID</dt><dd>'+(& $encode $document.PairId)+'</dd><dt>Attempt ID</dt><dd>'+(& $encode $document.AttemptId)+'</dd><dt>產生時間</dt><dd>'+(& $encode $document.GeneratedUtc)+'</dd><dt>來源盤點</dt><dd>'+(& $encode $sourceText)+'</dd></dl>'+"`n")
    [void]$page.Append('<p class="note" role="note">這份報告顯示擷取與封存當時的狀態，不代表目前備份媒體仍然完整，也不代表新機的還原結果。新機匯入時會重新驗證所有檔案。</p>'+"`n")
    if($inventorySource -ceq 'Unavailable'){[void]$page.Append('<p class="callout">無法取得來源盤點，未備份清單只包含核准計畫內的項目，未選入的已發現項目沒有列出。</p>'+"`n")}
    [void]$page.Append('<section id="backed" data-tab="已備份（'+$backedRows.Count+'）"><h2>已備份（'+$backedRows.Count+'）</h2>'+"`n"+(& $buildTable 'tbl-backed' '已備份項目' '0,2' @('名稱','類型','原位置','通道','檔案數','大小') $backedCells)+"`n</section>`n")
    [void]$page.Append('<section id="pending" data-tab="未備份（'+$pendingRows.Count+'）"><h2>未備份（'+$pendingRows.Count+'）</h2>'+"`n"+(& $buildTable 'tbl-pending' '未備份項目' '0,2' @('名稱','類型','原位置','原因','下一步','盤點狀態') $pendingCells)+"`n</section>`n")
    [void]$page.Append('<section id="software" data-tab="安裝軟體（'+$softwareRows.Count+'）"><h2>安裝軟體（'+$softwareRows.Count+'）</h2>'+"`n"+'<p>這是舊機上發現的軟體清單，供您在新機自行安裝。工具不會自動安裝，也不保證新版相容。</p>'+"`n")
    if($gapCount -gt 0){[void]$page.Append('<p class="callout">軟體盤點有 '+$gapCount+' 個範圍未完整取得，清單可能不完整。</p>'+"`n")}
    [void]$page.Append('<h3>安裝軟體清單</h3>'+"`n"+(& $buildTable 'tbl-software' '安裝軟體' '0,1,5' @('名稱','版本','發行者','架構','範圍','安裝位置','新機決策') $softwareCells)+"`n"+'<h3>Windows 角色與功能</h3>'+"`n"+(& $buildTable 'tbl-features' 'Windows 角色與功能' '0,1' @('顯示名稱','Install-WindowsFeature 名稱') $featureCells)+"`n</section>`n")
    [void]$page.Append(@'
</main>
<script>
(function(){
var doc=document,PAGE=100;
doc.documentElement.className+=' js';
function mk(tag,text,cls){var e=doc.createElement(tag);if(text)e.textContent=text;if(cls)e.className=cls;return e;}
function enhanceTable(table){
 var wrap=table.parentNode,body=table.tBodies[0],rows=[].slice.call(body.rows);
 var cols=(table.getAttribute('data-search')||'0').split(',');
 var texts=rows.map(function(r){return cols.map(function(c){return r.cells[+c]?r.cells[+c].textContent:'';}).join('\n').toLowerCase();});
 var bar=mk('div','','toolbar'),label=mk('label','搜尋名稱或位置'),input=doc.createElement('input');
 input.type='search';input.id=table.id+'-q';input.autocomplete='off';label.htmlFor=input.id;bar.appendChild(label);bar.appendChild(input);
 var none=mk('p','沒有符合搜尋條件的項目','empty');none.hidden=true;
 var pager=mk('div','','pager'),prev=mk('button','上一頁'),next=mk('button','下一頁'),status=mk('span');
 prev.type='button';next.type='button';status.setAttribute('aria-live','polite');
 pager.appendChild(prev);pager.appendChild(status);pager.appendChild(next);
 wrap.parentNode.insertBefore(bar,wrap);wrap.parentNode.insertBefore(none,wrap);wrap.parentNode.insertBefore(pager,wrap.nextSibling);
 var page=0;
 function draw(){
  var q=input.value.toLowerCase(),m=[],i;
  for(i=0;i<rows.length;i++){if(!q||texts[i].indexOf(q)>=0)m.push(i);}
  var pages=Math.max(1,Math.ceil(m.length/PAGE));
  if(page>=pages)page=pages-1;if(page<0)page=0;
  for(i=0;i<rows.length;i++)rows[i].hidden=true;
  m.slice(page*PAGE,(page+1)*PAGE).forEach(function(k){rows[k].hidden=false;});
  wrap.hidden=!m.length;none.hidden=m.length>0;pager.hidden=!m.length;
  status.textContent=m.length?'第 '+(page+1)+'／'+pages+' 頁，共 '+m.length+' 筆':'';
  prev.hidden=next.hidden=pages<2;prev.disabled=page<=0;next.disabled=page>=pages-1;
 }
 input.addEventListener('input',function(){page=0;draw();});
 prev.addEventListener('click',function(){page--;draw();});
 next.addEventListener('click',function(){page++;draw();});
 draw();
}
[].slice.call(doc.querySelectorAll('table[data-search]')).forEach(enhanceTable);
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

function Get-WsmWizardBackupItemResultsView([string]$Workspace,[string]$PairId) {
    Assert-WsmId $PairId
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Source'){throw 'Backup item results are only available on the enrolled Source workspace.'}
    $planRef=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile
    if(-not $planRef){return [pscustomobject]@{kind='BackupItemResultsView';available=$false;reason='尚未匯入已核准計畫，沒有備份結果可查看。'}}
    $latest=$null
    # Read-only: compute the backup root without the owned-directory helper, which would create it.
    $viewBackupRoot=Join-Path (Join-Path (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'workspace-control') 'wizard-backups') $PairId
    if(-not [IO.Directory]::Exists($viewBackupRoot)){return [pscustomobject]@{kind='BackupItemResultsView';available=$false;reason='目前還沒有已交付的備份。'}}
    Assert-WsmNoReparse $viewBackupRoot
    foreach($file in @(Get-ChildItem -LiteralPath $viewBackupRoot -Filter '*.json' -File)){
        try{
            $row=Read-WsmJson $file.FullName
            [void](Assert-WsmWizardBackupAttempt $row $Workspace $PairId $profile)
        }catch{continue}
        if([string]$row.PlanHash -ine [string]$planRef.SHA256 -or $row.Stage -cne 'Delivered' -or -not $row.PSObject.Properties['ItemResults']){continue}
        if(-not $latest -or [string]$row.UpdatedUtc -gt [string]$latest.UpdatedUtc){$latest=$row}
    }
    if(-not $latest){return [pscustomobject]@{kind='BackupItemResultsView';available=$false;reason='目前還沒有已交付的備份。'}}
    $attempt=$latest;$itemResults=$attempt.ItemResults
    if($itemResults.Status -cne 'Generated'){
        $errorText=if($itemResults.PSObject.Properties['Error']){[string]$itemResults.Error}else{''}
        return [pscustomobject]@{kind='BackupItemResultsView';available=$false;reason=('逐項結果產生失敗：'+$errorText);attemptId=[string]$attempt.AttemptId}
    }
    $failed=[pscustomobject]@{kind='BackupItemResultsView';available=$false;integrity='Failed';reason='逐項結果檔案已不存在或內容被更改，請重新備份。';attemptId=[string]$attempt.AttemptId}
    $resultPath=[string]$itemResults.Path
    Assert-WsmNoReparse $resultPath
    if(-not [IO.File]::Exists($resultPath) -or (Get-FileHash -LiteralPath $resultPath -Algorithm SHA256).Hash -ine [string]$itemResults.SHA256){return $failed}
    $document=Read-WsmJson $resultPath
    if($document.Kind -cne 'BackupItemResults' -or $document.PairId -cne $PairId -or $document.AttemptId -cne [string]$attempt.AttemptId){return $failed}
    [pscustomobject][ordered]@{kind='BackupItemResultsView';available=$true;integrity='Verified';attemptId=[string]$attempt.AttemptId;backupOperationId=[string]$attempt.StartedByOperationId;generatedUtc=$document.GeneratedUtc;inventorySource=$document.InventorySource;offlineReadiness=(ConvertTo-WsmWizardBackupResult $attempt ([string]$attempt.StartedByOperationId)).OfflineReadiness;counts=$document.Counts;rows=@($document.Rows);software=$document.Software}
}
