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

function Get-WsmWizardBackupAttempt([string]$Workspace,[string]$PairId,$Profile,[string]$PlanHash) {
    $root=Get-WsmWizardBackupRoot $Workspace $PairId
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)){Assert-WsmNoReparse $file.FullName;$row=Read-WsmJson $file.FullName;Assert-WsmWizardBackupAttempt $row $Workspace $PairId $Profile|Out-Null;$resumeStage='';if($row.PSObject.Properties['ResumeStage']){$resumeStage=[string]$row.ResumeStage};$resumable=($row.Stage -in @('Authorized','CoreExported','PackageVerified') -or ($row.Stage -in @('Failed','Cancelled') -and $resumeStage -in @('Authorized','CoreExported','PackageVerified')));if($row.PlanHash -ieq $PlanHash -and $resumable){$rows.Add([pscustomobject]@{Path=$file.FullName;Attempt=$row})}}
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

function ConvertTo-WsmWizardBackupResult($Attempt,[string]$OperationId) {
    [pscustomobject][ordered]@{Kind='WizardBackupResult';Status=[string]$Attempt.Stage;PairId=[string]$Attempt.PairId;AttemptId=[string]$Attempt.AttemptId;OperationId=$OperationId;StartedByOperationId=[string]$Attempt.StartedByOperationId;Stage=[string]$Attempt.Stage;DeliveryMode=$(if($Attempt.PSObject.Properties['DeliveryMode']){[string]$Attempt.DeliveryMode}else{''});VolumeBytes=$(if($Attempt.PSObject.Properties['VolumeBytes']){[long]$Attempt.VolumeBytes}else{0});Freeze=$Attempt.Freeze;CoreExport=$Attempt.CoreExport;PackageTest=$Attempt.PackageTest;Delivery=$Attempt.Delivery;ChannelSummary=$Attempt.ChannelSummary;NonCStatus=$(if($Attempt.ChannelSummary){[string]$Attempt.ChannelSummary.NonC.Status}else{'Pending'});ResumeStage=$(if($Attempt.PSObject.Properties['ResumeStage']){[string]$Attempt.ResumeStage}else{''});CanResumeAfterReview=($Attempt.Stage -in @('Failed','Cancelled') -and $Attempt.ResumeStage -in @('Authorized','CoreExported','PackageVerified'));SourceResumeRequired=([bool]($Attempt.PSObject.Properties['SourceResumeRequired'] -and $Attempt.SourceResumeRequired));AuthoritativeApproval=$true;ProductionVerified=$false;ResumeRequired=($Attempt.Stage -in @('Authorized','CoreExported','PackageVerified') -or ($Attempt.Stage -in @('Failed','Cancelled') -and $Attempt.ResumeStage -in @('Authorized','CoreExported','PackageVerified')) -or [bool]($Attempt.PSObject.Properties['SourceResumeRequired'] -and $Attempt.SourceResumeRequired))}
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
    $packageValid=[bool]($PackageTest -and $PackageTest.Valid);$deliveryValid=[bool]($Delivery -and [string]$Delivery.SHA256 -match '^[a-fA-F0-9]{64}$')
    $cStatus=if($cItems.Count){if($packageValid -and $deliveryValid){'VerifiedDelivered'}elseif($packageValid){'VerifiedNotDelivered'}elseif($PackageTest){'Failed'}else{'Pending'}}elseif($PackageTest -and $packageValid){'NoIncludedCFileScope'}elseif($PackageTest){'Failed'}else{'NoIncludedCFileScope'}
    $nonCStatus=if(-not $nonCItems.Count){'NoIncludedNonCFileScope'}elseif($PackageTest -and $PackageTest.Final){'RequiresTargetTransferAndManagerResultImport'}else{'RequiresFinalSourceFreeze'}
    $configStatus=if(-not $configItems.Count){'NoIncludedSupportedConfiguration'}elseif($packageValid -and $deliveryValid){'VerifiedInSealedPlanAndDelivered'}elseif($packageValid){'VerifiedInSealedPlanNotDelivered'}elseif($PackageTest){'Failed'}else{'Pending'}
    # A valid Test-WsmMigrationPackage result has already checked every selected
    # Certificate artifact row and every blob hash. Keep this projection cheap:
    # it runs during result reads, so it must not re-run the deep package scan.
    $certificateStatus=if(-not $certificateItems.Count){'NoIncludedCertificate'}elseif($packageValid -and $deliveryValid){'VerifiedPayloadDelivered'}elseif($packageValid){'VerifiedPayloadNotDelivered'}elseif($PackageTest){'Failed'}else{'Pending'}
    $unresolved=$nonCItems.Count -or $manualItems.Count -or $unknownItems.Count -or ($cItems.Count -and -not ($packageValid -and $deliveryValid)) -or ($configItems.Count -and -not ($packageValid -and $deliveryValid)) -or ($certificateItems.Count -and -not ($packageValid -and $deliveryValid))
    $overall=if($unresolved){'ReviewRequired'}elseif(-not ($cItems.Count -or $nonCItems.Count -or $configItems.Count -or $certificateItems.Count)){'NoSupportedSelectedEvidence'}else{'Succeeded'}
    [pscustomobject][ordered]@{C=[pscustomobject]@{IncludedItemIds=@($cItems.ToArray());Status=$cStatus};NonC=[pscustomobject]@{IncludedItemIds=@($nonCItems.ToArray());Status=$nonCStatus};ConfigurationEvidence=[pscustomobject]@{IncludedItemIds=@($configItems.ToArray());Status=$configStatus};Certificate=[pscustomobject]@{IncludedItemIds=@($certificateItems.ToArray());Status=$certificateStatus};ManualArtifactsNotSupported=[pscustomobject]@{IncludedItemIds=@($manualItems.ToArray());Status=$(if($manualItems.Count){'ManualArtifactsNotSupported'}else{'NoIncludedManualWorkflow'})};UnsupportedIncludedItemIds=@($unknownItems.ToArray());OverallStatus=$overall;ProductionVerified=$false}
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
    $rows=New-Object 'System.Collections.Generic.List[object]';$shared=New-Object 'System.Collections.Generic.List[object]';$mutable=$false;$nonC=$false
    foreach($item in @($plan.Items | Where-Object Decision -CEQ 'Include')){
        $spec=$item.MigrationSpec;$adapter=if($spec){[string]$spec.Adapter}else{'Unknown'};$channel='Configuration';$requiresFreeze=$false;$quiescedByFreeze=$false;$identity=[ordered]@{ItemId=[string]$item.ItemId;Kind=[string]$item.Kind;Name=[string]$item.NaturalKey;Adapter=$adapter}
        if($adapter -ceq 'FileScope'){$channel=if($spec.PSObject.Properties['TransferChannel']){[string]$spec.TransferChannel}else{'C'};$identity.SourcePath=[string]$spec.SourcePath;$requiresFreeze=($spec.Consistency -cne 'Immutable');if($channel -ceq 'NonC'){$nonC=$true};if($requiresFreeze){$mutable=$true}}
        elseif($adapter -in @('Service','ScheduledTask','IISPool','IISSite','SmbShare')){$quiescedByFreeze=$true;if($adapter -ceq 'SmbShare'){$channel='SharedFileScope';$shared.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Producer=[string]$item.NaturalKey;Impact='If this plan requires source freeze, the selected share may be made unavailable to writers; existing open handles require owner review.'})}else{$channel='ProducerConfiguration';$impactText='If another selected scope requires source freeze, this producer may be disabled or stopped until an owner separately completes the existing SourceResume/recovery process.';if($adapter -ceq 'IISPool'){$impactText+=' Every site and application using this pool is affected; verify selected and unselected consumers.'};$shared.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Producer=[string]$item.NaturalKey;Impact=$impactText})}}
        if($spec -and $spec.PSObject.Properties['SharedResourceImpacts']){foreach($impact in @($spec.SharedResourceImpacts)){$shared.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Producer=[string]$item.NaturalKey;Impact=$impact;Source='Approved plan SharedResourceImpacts'})}}
        $rows.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Name=[string]$item.NaturalKey;Kind=[string]$item.Kind;Adapter=$adapter;Channel=$channel;Selected=$true;SourcePath=$(if($spec -and $spec.PSObject.Properties['SourcePath']){[string]$spec.SourcePath}else{''});ProducerIdentity=$identity;RequiresSourceFreeze=$requiresFreeze;ProducerQuiescedIfFreezeRuns=$quiescedByFreeze;PriorStateLocation=(Join-Path $Workspace ('pairs\freeze-'+$PairId+'-*'))})
    }
    $freezeRequired=($mutable -or $nonC)
    $evidence=@();if($freezeRequired){$evidence+=@('Independent hash-trusted ExternalReadinessEvidence with Phase=SourceFreezeReady, matching this approved plan, selected producers, current host, owner, and non-empty FreezeEpoch.','Named responsible owner and explicit quiescence evidence for each selected producer.','Separate explicit freeze authorization; the ordinary StartBackup confirmation does not authorize source changes.','After quiescence, inspect the durable source attempt and retain the exact prior runtime/ACL state for the existing SourceResume/recovery path.')}
    if($nonC){$evidence+=@('Non-C scopes are excluded from the C package and require the separate target transfer and manager result import before they are reported complete.')}
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
    $inventory=Get-WsmWizardPlanInventoryBinding $plan
    $included=@($plan.Items|Where-Object Decision -CEQ 'Include')
    $nonCIncluded=@($included|Where-Object {$_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'}).Count -gt 0
    $mutableIncluded=@($included|Where-Object {$_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.Consistency -cne 'Immutable'}).Count -gt 0
    $freezeRequired=($nonCIncluded -or $mutableIncluded)
    $authorizedFreezeEpoch=''
    if($freezeRequired){if(-not $FreezeAuthorization -or [string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Evidence) -or -not $FreezeExternalEvidencePath -or $FreezeExternalEvidenceHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'A final backup for mutable or NonC data requires a separate explicit freeze authorization, a human owner, quiescence evidence, and independently verified SourceFreezeReady file/hash.'};$externalRecord=Read-WsmTrustedJson $FreezeExternalEvidencePath $FreezeExternalEvidenceHash;$authorizedFreezeEpoch=[string]$externalRecord.FreezeEpoch;$external=Assert-WsmSourceFreezeEvidence $FreezeExternalEvidencePath $FreezeExternalEvidenceHash $plan $planRef.SHA256 $authorizedFreezeEpoch;if($external.Owner -cne $Owner){throw 'Source freeze evidence owner does not match the named responsible owner.'}}
    $root=Get-WsmWizardBackupRoot $Workspace $PairId
    $operationAttempt=Get-WsmWizardBackupAttemptForOperation $Workspace $PairId $profile $OperationId
    $existing=Get-WsmWizardBackupAttempt $Workspace $PairId $profile $planRef.SHA256
    $settingsAttempt=$existing;if($operationAttempt){$settingsAttempt=$operationAttempt}
    $deliverySettings=Get-WsmWizardBackupDeliverySettings $Workspace $PairId $profile $settingsAttempt ($PSBoundParameters.ContainsKey('DeliveryMode')) $DeliveryMode ($PSBoundParameters.ContainsKey('VolumeBytes')) $VolumeBytes
    if($operationAttempt){return (ConvertTo-WsmWizardBackupResult $operationAttempt.Attempt $OperationId)}
    if($deliverySettings.Mode -ceq 'Directory'){
        $plannedAttempt=if($existing){[string]$existing.Attempt.OutputRoot}else{Join-Path (Join-Path (Join-Path (Join-Path $profile.WorkRoot 'pairs') $PairId) 'attempts') $OperationId}
        Assert-WsmDirectoryDeliveryPathBudget (Join-Path (Join-Path $plannedAttempt 'transport') 'delivery') @(Get-WsmWizardBackupDirectoryMemberNames $plan)
    }
    if($existing){$record=$existing.Attempt;$path=$existing.Path;$attemptId=[string]$record.AttemptId;if($record.Stage -in @('Failed','Cancelled')){$record.Stage=[string]$record.ResumeStage;$record.ResumeStage='';$record.Error=$null};$operationIds=@();if($record.PSObject.Properties['OperationIds']){$operationIds=@($record.OperationIds)}else{$operationIds=@([string]$record.StartedByOperationId)};$record.OperationIds=@($operationIds)+@($OperationId);$record.LastOperationId=$OperationId;$resumeCount=0;if($record.PSObject.Properties['ResumeCount']){$resumeCount=[int]$record.ResumeCount};$record.ResumeCount=$resumeCount+1;$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace}
    else{
        $attemptId=$OperationId;$output=Resolve-WsmOutputWorkspace -WorkRoot $Workspace -Role Source -PairId $PairId -PlanHash $planRef.SHA256 -AttemptId $attemptId -AttemptMode $deliverySettings.Mode -AttemptVolumeBytes $deliverySettings.VolumeBytes
        $record=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WizardBackupAttempt';Workspace=[IO.Path]::GetFullPath($Workspace);ProfileId=[string]$profile.ProfileId;HostId=[string]$profile.HostId;PairId=$PairId;PlanPath=[IO.Path]::GetFullPath($planRef.Path);PlanHash=$planRef.SHA256;InventoryHash=$inventory.Hash;InventoryRevision=$inventory.Revision;AttemptId=$attemptId;StartedByOperationId=$OperationId;OperationIds=@($OperationId);LastOperationId=$OperationId;ResumeCount=0;DeliveryMode=$deliverySettings.Mode;VolumeBytes=[long]$deliverySettings.VolumeBytes;FreezeRequired=$freezeRequired;FreezeEvidencePath=$(if($freezeRequired){[IO.Path]::GetFullPath($FreezeExternalEvidencePath)}else{''});FreezeEvidenceHash=$(if($freezeRequired){$FreezeExternalEvidenceHash.ToLowerInvariant()}else{''});FreezeEpoch=$authorizedFreezeEpoch;FreezeOwner=$(if($freezeRequired){$Owner}else{''});FreezeEvidence=$(if($freezeRequired){$Evidence}else{''});Freeze=$null;FreezeAttemptStarted=$false;SourceResumeRequired=$false;Stage='Authorized';ResumeStage='';OutputRoot=[IO.Path]::GetFullPath($output.AttemptRoot);CoreExport=$null;PackageTest=$null;Delivery=$null;ChannelSummary=$null;Error=$null;StartedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc);ProductionVerified=$false}
        $path=Join-Path $root ($attemptId+'.json');Assert-WsmNoReparse $path;if([IO.File]::Exists($path)){throw 'An operation record already exists for this identifier; read the existing result instead of sending the operation again.'};Write-WsmWizardBackupAttempt $path $record $Workspace
    }
    if($record.PlanHash -ine $planRef.SHA256 -or $record.InventoryHash -ine $inventory.Hash -or [int]$record.InventoryRevision -ne $inventory.Revision){throw 'The approved plan or source inventory changed; start a fresh reviewed attempt.'}
    if([bool]$record.FreezeRequired -ne $freezeRequired -or ($freezeRequired -and ([string]$record.FreezeEvidenceHash -ine $FreezeExternalEvidenceHash -or [string]$record.FreezeOwner -cne $Owner -or [string]$record.FreezeEvidence -cne $Evidence -or ($record.PSObject.Properties['FreezeEpoch'] -and [string]$record.FreezeEpoch -cne $authorizedFreezeEpoch)))){throw 'This durable backup attempt was authorized against different source-freeze evidence; inspect the existing attempt before continuing.'}
    if($freezeRequired -and -not $record.PSObject.Properties['FreezeEpoch']){$record | Add-Member NoteProperty FreezeEpoch $authorizedFreezeEpoch;Write-WsmWizardBackupAttempt $path $record $Workspace}
    $output=Resolve-WsmOutputWorkspace -WorkRoot $Workspace -Role Source -PairId $PairId -PlanHash $planRef.SHA256 -AttemptId $attemptId
    if($record.PSObject.Properties['DeliveryMode'] -and ([string]$record.DeliveryMode -cne [string]$output.AttemptProfile.Mode -or [long]$record.VolumeBytes -ne [long]$output.AttemptProfile.VolumeBytes)){throw 'Backup attempt delivery format differs from its immutable output-attempt record.'}
    if(-not $record.PSObject.Properties['DeliveryMode']){$record | Add-Member NoteProperty DeliveryMode ([string]$output.AttemptProfile.Mode);$record | Add-Member NoteProperty VolumeBytes ([long]$output.AttemptProfile.VolumeBytes);Write-WsmWizardBackupAttempt $path $record $Workspace}
    if($record.Stage -eq 'Authorized'){
        try{
            Assert-WsmCancellationBoundary $CancellationToken 'BeforeSourceFreeze'
            if($freezeRequired -and -not $record.Freeze){
                $freezePath=Join-Path $record.OutputRoot 'source-freeze.json'
                if([IO.File]::Exists($freezePath)){$freezeHash=(Get-WsmAssistiveNonCHash $freezePath);$freeze=Read-WsmFreezeRecord $freezePath $freezeHash $plan $planRef.SHA256;$attestation=Assert-WsmSourceFreezeEvidence $record.FreezeEvidencePath $record.FreezeEvidenceHash $plan $planRef.SHA256 $freeze.FreezeEpoch;Assert-WsmSourceFreezeEvidenceMatchesAttestation $attestation $freeze;$frozen=[pscustomobject]@{Path=$freezePath;SHA256=$freezeHash;FreezeId=[string]$freeze.FreezeId;ExpiresUtc=[string]$freeze.ExpiresUtc}}
                else{$record.FreezeAttemptStarted=$true;$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace;$frozen=Export-WsmFreezeRecord -PlanPath $planRef.Path -ExpectedHash $planRef.SHA256 -Path $freezePath -Owner $record.FreezeOwner -Evidence $record.FreezeEvidence -Acknowledgement 'OWNER-CONFIRMED-QUIESCENCE' -SourceStateDirectory (Join-Path $Workspace 'pairs') -FreezeExternalEvidencePath $record.FreezeEvidencePath -FreezeExternalEvidenceHash $record.FreezeEvidenceHash -FreezeEpoch $record.FreezeEpoch -Confirm:$false}
                if(-not $frozen -or -not $frozen.Path -or -not $frozen.SHA256){throw 'Source freeze did not return a verifiable durable record.'}
                $record.Freeze=[pscustomobject]@{Status='Succeeded';Path=[IO.Path]::GetFullPath([string]$frozen.Path);SHA256=[string]$frozen.SHA256;FreezeId=[string]$frozen.FreezeId;ExpiresUtc=[string]$frozen.ExpiresUtc;Owner=[string]$record.FreezeOwner;EvidenceHash=[string]$record.FreezeEvidenceHash;ProductionVerified=$false};$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace
            }
            Assert-WsmCancellationBoundary $CancellationToken 'BeforeCoreExport'
            $exportArgs=@{PlanPath=$planRef.Path;ExpectedHash=$planRef.SHA256;SourceStateDirectory=(Join-Path $Workspace 'pairs');OutputDirectory=$output.PackagesDirectory;CancellationToken=$CancellationToken}
            if($freezeRequired){$exportArgs.FreezePath=[string]$record.Freeze.Path;$exportArgs.FreezeHash=[string]$record.Freeze.SHA256;$exportArgs.FreezeExternalEvidencePath=[string]$record.FreezeEvidencePath;$exportArgs.FreezeExternalEvidenceHash=[string]$record.FreezeEvidenceHash}
            $core=Export-WsmMigrationPackage @exportArgs
            $record.CoreExport=[pscustomobject]@{Status='Succeeded';ManifestPath=[IO.Path]::GetFullPath($core.ManifestPath);SHA256=[string]$core.SHA256;Generation=[int]$core.Generation;Files=[long]$core.Files;Bytes=[long]$core.Bytes;Final=[bool]$core.Final;Sealed=[bool]$core.Sealed;SoftwareScopeCoverage=@($(if($core.PSObject.Properties['SoftwareScopeCoverage']){@($core.SoftwareScopeCoverage)}else{@()}));ProductionVerified=$false};$record.Stage='CoreExported';$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace
        }
        catch{
            if($freezeRequired -and -not $record.Freeze -and $record.FreezeAttemptStarted){$record.ResumeStage='';$record.SourceResumeRequired=$true;$record.Stage='ReviewRequired';$record.Error=[pscustomobject]@{Code='source_freeze_interrupted';Message='來源停止寫入流程可能已部分執行；請先檢查來源恢復紀錄，勿直接重送。'}}
            else{$record.ResumeStage='Authorized';$record.Stage=if($_.Exception.Data['CancellationRequested']){'Cancelled'}else{'Failed'};$record.Error=[pscustomobject]@{Code=$(if($record.Stage -eq 'Cancelled'){'cancelled'}else{'core_export_failed'});Message='封裝未完成；已保留目前可核對的資料，請查看作業紀錄後再續作。'}}
            $record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace;throw
        }
    }
    if($record.Stage -eq 'CoreExported'){
        try{Assert-WsmCancellationBoundary $CancellationToken 'BeforePackageTest';$test=Test-WsmMigrationPackage -ManifestPath $record.CoreExport.ManifestPath -ExpectedHash $record.CoreExport.SHA256 -CancellationToken $CancellationToken;$record.PackageTest=[pscustomobject]@{Status='Succeeded';Valid=[bool]$test.Valid;ManifestPath=[IO.Path]::GetFullPath($record.CoreExport.ManifestPath);SHA256=[string]$record.CoreExport.SHA256;PlanHash=[string]$test.Manifest.PlanHash;Generation=[int]$test.Manifest.Generation;Files=[long]$test.Manifest.Files;Bytes=[long]$test.Manifest.Bytes;Final=[bool]$test.Manifest.Final;ProductionVerified=$false};$record.Stage='PackageVerified';$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace}
        catch{$resumeStage='CoreExported';$record.ResumeStage=$resumeStage;$record.Stage=if($_.Exception.Data['CancellationRequested']){'Cancelled'}else{'Failed'};$record.Error=[pscustomobject]@{Code=$(if($record.Stage -eq 'Cancelled'){'cancelled'}else{'package_test_failed'});Message='封裝核驗未完成；檔案保留，請先檢查作業紀錄。'};$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace;throw}
    }
    if($record.Stage -eq 'PackageVerified'){
        try{
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
            $record.Stage=if($record.ChannelSummary.OverallStatus -eq 'ReviewRequired'){'ReviewRequired'}else{'Delivered'};$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace
        }catch{$resumeStage='PackageVerified';$record.ResumeStage=$resumeStage;$record.Stage=if($_.Exception.Data['CancellationRequested']){'Cancelled'}else{'Failed'};$record.Error=[pscustomobject]@{Code=$(if($record.Stage -eq 'Cancelled'){'cancelled'}else{'delivery_failed'});Message='搬移封裝已核驗，但交接材料未完整產生；可從同一作業嘗試續作。'};$record.UpdatedUtc=Get-WsmUtc;Write-WsmWizardBackupAttempt $path $record $Workspace;throw}
    }
    ConvertTo-WsmWizardBackupResult $record $OperationId
}
