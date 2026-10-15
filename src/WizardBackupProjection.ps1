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
            $stage=[string]$attempt.Stage;$jobStatus=[string]$job.status
            $stageMatches=switch($jobStatus){
                'Succeeded' { $stage -in @('Delivered','ReviewRequired') }
                'Failed' { $stage -ceq 'Failed' }
                'Cancelled' { $stage -ceq 'Cancelled' }
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
    $percent=$null;try{$candidate=[int]$record.PercentComplete;if($candidate -ge 0 -and $candidate -le 100){$percent=$candidate}}catch{}
    $processedCount=$null
    foreach($source in @($Job,$jobRecord)){$value=Get-WsmTextMetadataValue $source 'processedCount';if($null -ne $value){try{$count=[long]$value;if($count -ge 0){$processedCount=$count;break}}catch{}}}
    $activity=ConvertTo-WsmProgressText $record.Activity;$status=ConvertTo-WsmProgressText $record.StatusDescription;$operation=ConvertTo-WsmProgressText $record.CurrentOperation
    $previous=Get-WsmTextMetadataValue $jobRecord 'progress';$observedCount=Get-WsmTextMetadataValue $Job 'ObservedProgressCount';$updated=Get-WsmUtc
    if($previous -and $null -ne $observedCount -and [int]$observedCount -eq $streamCount -and [string]$previous.activity -ceq $activity -and [string]$previous.statusDescription -ceq $status -and [string]$previous.currentOperation -ceq $operation -and $previous.percent -eq $percent -and $previous.processedCount -eq $processedCount){$updated=[string]$previous.updatedUtc}
    if($Job -is [Collections.IDictionary]){$Job['ObservedProgressCount']=$streamCount}else{$Job|Add-Member NoteProperty ObservedProgressCount $streamCount -Force}
    [pscustomobject][ordered]@{activity=$activity;statusDescription=$status;currentOperation=$operation;percent=$percent;processedCount=$processedCount;updatedUtc=$updated}
}