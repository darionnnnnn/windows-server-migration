# Curated wizard entry points for the existing Assistive NonC core.
# Human path/account choices are explicit inputs; plan/package/proof authority
# is always re-read from the enrolled workspace and durable verified materials.

function Get-WsmWizardNonCMaterialRoot([string]$Workspace,[string]$PairId) {
    Assert-WsmId $PairId
    $root=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials') ('nonc-'+$PairId)))
    $base=[IO.Path]::GetFullPath((Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials')).TrimEnd('\')+'\'
    if(-not $root.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'NonC wizard material path escaped its owned workspace root.'}
    $root
}

function Get-WsmWizardNonCTransferMaterial($Preparation,[string]$TransferPlanHash) {
    if(-not $Preparation -or $Preparation.Kind -cne 'WizardNonCPreparation'){throw 'Current NonC preparation is unavailable.'}
    $matches=@($Preparation.TransferChoices|Where-Object {$_.sha256 -ieq $TransferPlanHash})
    if($matches.Count -ne 1){throw 'Choose one exact currently verified NonC transfer plan.'}
    $matches[0]
}

function Get-WsmWizardNonCProofHashes($Record) {
    if($Record -and $Record.PSObject.Properties['SourcePeerProofHashes']){$values=@($Record.SourcePeerProofHashes|ForEach-Object {[string]$_})}
    elseif($Record -and $Record.PSObject.Properties['SourcePeerProofHash'] -and [string]$Record.SourcePeerProofHash){$values=@([string]$Record.SourcePeerProofHash)}
    else{return @()}
    $normalized=@($values|Where-Object {$_}|ForEach-Object {$_.Trim().ToLowerInvariant()})
    if(@($normalized|Sort-Object -Unique).Count -ne $normalized.Count){return @()}
    @($normalized|Sort-Object -Unique)
}

function Test-WsmWizardNonCCurrentProofBindings([string]$Workspace,[string]$PairId,$ApprovedPlan,$Preparation,[string[]]$Hashes,$Record) {
    if(-not $Hashes.Count){return $false}
    $bindingRows=@();if($Record -and $Record.PSObject.Properties['SourcePeerProofs']){$bindingRows=@($Record.SourcePeerProofs)}
    if(-not $bindingRows.Count -and $Hashes.Count -eq 1){
        $legacyContentHash='';if($Record -and $Record.PSObject.Properties['SourcePeerProofContentHash']){$legacyContentHash=[string]$Record.SourcePeerProofContentHash}
        if($legacyContentHash){$bindingRows=@([pscustomobject]@{SHA256=[string]$Hashes[0];ContentHash=$legacyContentHash})}
    }
    if(-not $bindingRows.Count){return $false}
    $registry=Get-WsmAssistiveResourceRegistry $Workspace
    if(@($registry.Materials).Count -eq 0){return $false}
    if($bindingRows.Count -ne $Hashes.Count){return $false}
    $options=@($Preparation.ProofOptions|Where-Object kind -CEQ 'SourcePeerShareProof')
    foreach($hash in $Hashes){
        $option=@($options|Where-Object {$_.sha256 -ieq $hash});if($option.Count -ne 1){return $false}
        $ref=@($registry.Materials|Where-Object {$_.PairId -ceq $PairId -and $_.Kind -ceq 'AssistivePeerShareProof' -and $_.Path -ieq [string]$option[0].path -and $_.SHA256 -ieq [string]$option[0].sha256});if($ref.Count -ne 1){return $false}
        $proof=Read-WsmAssistivePeerShareProof ([string]$option[0].path) ([string]$option[0].sha256) ([string]$ApprovedPlan.Plan.Source.Fingerprint)
        if($proof.PeerHostId -cne [string]$ApprovedPlan.Plan.Source.HostId){return $false}
        $binding=@($bindingRows|Where-Object {$_.SHA256 -ieq $hash});if($binding.Count -ne 1 -or [string]$binding[0].ContentHash -ine [string]$proof.ProofHash){return $false}
    }
    if($Record.PSObject.Properties['Entries']){foreach($entry in @($Record.Entries)){if([string]$entry.Status -ceq 'Observed'){if([string]$entry.SourcePeerProofHash -notin $Hashes){return $false};$entryBinding=@($bindingRows|Where-Object {$_.SHA256 -ieq [string]$entry.SourcePeerProofHash});if($entryBinding.Count -ne 1 -or [string]$entry.SourcePeerProofContentHash -ine [string]$entryBinding[0].ContentHash){return $false}}}}
    $true
}

function Get-WsmWizardNonCAccountObservationFromJobs([string]$Workspace,[string]$PairId,[object[]]$Jobs,$ApprovedPlan,$Preparation,$Catalog) {
    if(-not $ApprovedPlan -or -not $Preparation -or -not $Preparation.Current.ManifestHash -or -not $Catalog.Assistive.TargetCurrent){return $null}
    $sourceProofHashes=@($Preparation.ProofOptions|Where-Object kind -CEQ 'SourcePeerShareProof'|ForEach-Object {([string]$_.sha256).ToLowerInvariant()})
    foreach($job in @($Jobs|Where-Object {$_.action -ceq 'InspectNonCAccountMappings' -and $_.role -ceq 'Manager' -and $_.pairId -ceq $PairId -and $_.status -cin @('Succeeded','ReviewRequired','Cancelled') -and $_.PSObject.Properties['workspace'] -and [IO.Path]::GetFullPath([string]$_.workspace) -ieq [IO.Path]::GetFullPath($Workspace)}|Sort-Object CompletedUtc -Descending)){
        foreach($output in @($job.outputs)){
            $hashes=@(Get-WsmWizardNonCProofHashes $output)
            if($output.Kind -cne 'WizardNonCAccountObservationResult' -or $output.PairId -cne $PairId -or $output.PlanHash -ine $ApprovedPlan.SHA256 -or $output.ManifestHash -ine $Preparation.Current.ManifestHash -or [int]$output.SelectionRevision -ne [int]$Preparation.Current.SelectionRevision -or $output.TargetSnapshotHash -ine [string]$Catalog.Assistive.TargetCurrent.SHA256 -or -not $hashes.Count -or @($hashes|Where-Object {$sourceProofHashes -cnotcontains $_}).Count -or [string]$output.SourcePeerProofHash.ToLowerInvariant() -notin $hashes -or -not (Test-WsmWizardNonCCurrentProofBindings $Workspace $PairId $ApprovedPlan $Preparation $hashes $output)){continue}
            if($output.PSObject.Properties['SourcePeerProofHashes'] -and ((@($output.SourcePeerProofHashes|ForEach-Object {([string]$_).ToLowerInvariant()}|Sort-Object -Unique) -join '|') -cne ($hashes -join '|'))){continue}
            return $output
        }
    }
    $null
}

function Get-WsmWizardNonCAccountObservationSummary([string]$Workspace,[string]$PairId,$ApprovedPlan,$Preparation,$Catalog,[object[]]$Jobs) {
    if(-not $ApprovedPlan -or -not $Preparation -or -not $Catalog -or -not $Catalog.Assistive){return $null}
    $output=Get-WsmWizardNonCAccountObservationFromJobs $Workspace $PairId $Jobs $ApprovedPlan $Preparation $Catalog
    if(-not $output -or [string]$output.Status -notin @('Succeeded','ReviewRequired','Cancelled')){return $null}
    $root=[IO.Path]::GetFullPath((Join-Path (Join-Path (Get-WsmWizardNonCMaterialRoot $Workspace $PairId) 'account-observations') '')).TrimEnd('\')+'\'
    try {
        $path=[IO.Path]::GetFullPath([string]$output.Path)
        if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){return $null}
        Assert-WsmNoReparse $path;Assert-WsmTrustedFile $path ([string]$output.SHA256)
        $saved=Read-WsmTrustedJson $path ([string]$output.SHA256)
        $outputHashes=@(Get-WsmWizardNonCProofHashes $output);$savedHashes=@(Get-WsmWizardNonCProofHashes $saved)
        if($saved.Kind -cne 'WizardNonCAccountObservations' -or $saved.PairId -cne $PairId -or $saved.PlanHash -ine [string]$ApprovedPlan.SHA256 -or $saved.ManifestHash -ine [string]$Preparation.Current.ManifestHash -or [long]$saved.Generation -ne [long]$Preparation.Current.Generation -or $saved.InventoryHash -ine [string]$Preparation.Current.InventoryHash -or [int]$saved.SelectionRevision -ne [int]$Preparation.Current.SelectionRevision -or $saved.TargetSnapshotHash -ine [string]$Catalog.Assistive.TargetCurrent.SHA256 -or [string]$saved.SourcePeerProofHash -ine [string]$output.SourcePeerProofHash -or ($savedHashes -join '|') -cne ($outputHashes -join '|') -or -not (Test-WsmWizardNonCCurrentProofBindings $Workspace $PairId $ApprovedPlan $Preparation $savedHashes $saved)){return $null}
        [pscustomobject][ordered]@{Kind='WizardNonCAccountObservationResult';Status=[string]$output.Status;PairId=$PairId;PlanHash=[string]$saved.PlanHash;ManifestHash=[string]$saved.ManifestHash;Generation=[long]$saved.Generation;InventoryHash=[string]$saved.InventoryHash;SelectionRevision=[int]$saved.SelectionRevision;TargetSnapshotHash=[string]$saved.TargetSnapshotHash;SourcePeerProofHash=[string]$saved.SourcePeerProofHash;SourcePeerProofHashes=@($savedHashes);SourcePeerProofs=@($saved.SourcePeerProofs);Path=$path;SHA256=([string]$output.SHA256).ToLowerInvariant();CreatedUtc=[string]$saved.CreatedUtc;CoverageComplete=[bool]$saved.CoverageComplete;VisitedCount=[long]$saved.VisitedCount;MaximumEntries=[int]$saved.MaximumEntries;ElapsedMilliseconds=[long]$saved.ElapsedMilliseconds;TimeoutSeconds=[int]$saved.TimeoutSeconds;TimedOut=[bool]$saved.TimedOut;Cancelled=[bool]$saved.Cancelled;ContentRead=[bool]$saved.ContentRead;UnresolvedCount=[long](@($saved.Entries|Measure-Object -Property UnresolvedCount -Sum).Sum);AclReadFailureCount=[long](@($saved.Entries|Measure-Object -Property AclReadFailureCount -Sum).Sum);hasDurableRecord=$true;current=$true;SourceIdentities=@($saved.SourceIdentities);TargetIdentities=@($saved.TargetIdentities);Entries=@($saved.Entries);AuthoritativeApproval=$false;ProductionVerified=$false}
    }catch{return $null}
}

function ConvertFrom-WsmWizardAccountMap([string]$Text) {
    if([string]::IsNullOrWhiteSpace($Text)){throw 'Review an explicit source SID to target SID mapping for this folder.'}
    $map=[ordered]@{}
    foreach($line in @($Text -split "`r?`n")){
        if([string]::IsNullOrWhiteSpace($line)){continue}
        $parts=$line.Split('=',2)
        if($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])){throw 'Account mappings must use one source-SID=target-SID row per line.'}
        $source=(New-Object Security.Principal.SecurityIdentifier($parts[0].Trim())).Value
        $target=(New-Object Security.Principal.SecurityIdentifier($parts[1].Trim())).Value
        if($map.Contains($source)){throw 'Account mapping contains a duplicate source SID.'}
        $map[$source]=$target
    }
    if(-not $map.Count){throw 'At least one explicit account SID mapping is required.'}
    [pscustomobject]$map
}

function New-WsmWizardNonCTransferPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$ManifestSelection,[Parameter(Mandatory)][string]$SourcePeerProofHash,[string[]]$SourcePeerProofHashes=@(),
        [Parameter(Mandatory)][string]$TargetPhysicalProofHash,[Parameter(Mandatory)][object[]]$ItemScopes,
        [Parameter(Mandatory)][string]$TargetStateDirectory,[Parameter(Mandatory)][string]$AccountObservationHash,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Evidence,[ValidateSet('DaclOwnerMappedAndBasicTimes','DaclOwnerSaclMappedAndBasicTimes')][string]$MetadataPolicy='DaclOwnerMappedAndBasicTimes',
        [object[]]$Jobs=@()
    )
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Creating a NonC transfer plan requires the enrolled Manager workspace.'}
    Assert-WsmId $PairId
    if([string]::IsNullOrWhiteSpace($Owner) -or $Owner.Length -gt 200 -or [string]::IsNullOrWhiteSpace($Evidence) -or $Evidence.Length -gt 2000){throw 'Mapping review requires a named owner and concise evidence, up to 2000 characters.'}
    $preparation=Get-WsmWizardNonCPreparation -Workspace $Workspace -PairId $PairId -Jobs $Jobs -ManifestSelection $ManifestSelection
    if(-not $preparation.CanCreateTransferPlan){throw 'Current approved package and independently verified freeze/proof materials are not ready for a NonC transfer plan.'}
    $catalog=Get-WsmCatalog $Workspace $PairId;$approvedForObservation=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $Jobs
    $observationResult=Get-WsmWizardNonCAccountObservationFromJobs $Workspace $PairId $Jobs $approvedForObservation $preparation $catalog
    if(-not $observationResult -or -not $observationResult.CoverageComplete -or [string]$observationResult.SHA256 -ine $AccountObservationHash){throw 'A complete current ACL account observation is required; rerun identity inspection after any material change.'}
    $sourceInventory=Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.SourceSnapshot Source;$targetInventory=Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.TargetCurrent Target
    if($sourceInventory.Source.HostId -cne $approvedForObservation.Plan.Source.HostId -or $sourceInventory.Source.Fingerprint -ine $approvedForObservation.Plan.Source.Fingerprint -or $targetInventory.Source.HostId -cne $approvedForObservation.Plan.Target.HostId -or $targetInventory.Source.Fingerprint -ine $approvedForObservation.Plan.Target.Fingerprint){throw 'Current host-bound source or target inventory no longer matches the approved plan.'}
    $observationRoot=[IO.Path]::GetFullPath((Join-Path (Get-WsmWizardNonCMaterialRoot $Workspace $PairId) 'account-observations')).TrimEnd('\')+'\';$observationPath=[IO.Path]::GetFullPath([string]$observationResult.Path)
    if(-not $observationPath.StartsWith($observationRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'The current account observation is outside its owned material directory.'}
    Assert-WsmNoReparse $observationPath;Assert-WsmTrustedFile $observationPath ([string]$observationResult.SHA256)
    $accountObservation=Read-WsmTrustedJson ([string]$observationResult.Path) ([string]$observationResult.SHA256)
    if($accountObservation.Kind -cne 'WizardNonCAccountObservations' -or $accountObservation.PairId -cne $PairId -or $accountObservation.PlanHash -ine $approvedForObservation.SHA256 -or $accountObservation.ManifestHash -ine $preparation.Current.ManifestHash -or [int]$accountObservation.SelectionRevision -ne [int]$preparation.Current.SelectionRevision -or $accountObservation.TargetSnapshotHash -ine [string]$catalog.Assistive.TargetCurrent.SHA256 -or -not $accountObservation.CoverageComplete){throw 'The persisted ACL observation is stale or incomplete.'}
    $selectedProofHashes=@((@($SourcePeerProofHash)+@($SourcePeerProofHashes)|Where-Object {$_}|ForEach-Object {([string]$_).Trim().ToLowerInvariant()}|Sort-Object -Unique))
    $observationProofHashes=@(Get-WsmWizardNonCProofHashes $observationResult)
    if(($selectedProofHashes -join '|') -cne ($observationProofHashes -join '|')){throw 'The selected source share proof set must exactly match the complete current ACL observation proof set.'}
    if(-not (Test-WsmWizardNonCCurrentProofBindings $Workspace $PairId $approvedForObservation $preparation $selectedProofHashes $observationResult)){throw 'One or more selected source peer proofs are no longer exact current registered materials.'}
    $sourceMatches=@(foreach($hash in $selectedProofHashes){@($preparation.ProofOptions|Where-Object {$_.kind -ceq 'SourcePeerShareProof' -and $_.sha256 -ieq $hash})})
    $sourceMatches=@($sourceMatches|Where-Object {$_})
    $targetMatches=@($preparation.ProofOptions|Where-Object {$_.kind -ceq 'TargetPhysicalProof' -and $_.sha256 -ieq $TargetPhysicalProofHash})
    if($sourceMatches.Count -ne $selectedProofHashes.Count -or $targetMatches.Count -ne 1){throw 'Select every exact current source share proof and the target physical proof from the verified proof options.'}
    $approved=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile (Get-WsmCatalog $Workspace $PairId) $Jobs
    if(-not $approved -or $approved.SHA256 -ine $preparation.Current.PlanHash){throw 'The approved plan changed while preparing the transfer.'}
    $plan=Read-WsmMigrationPlan $approved.Path $approved.SHA256
    $sourceProofs=@(foreach($sourceMatch in $sourceMatches){$proof=Read-WsmAssistivePeerShareProof ([string]$sourceMatch.path) ([string]$sourceMatch.sha256) ([string]$plan.Source.Fingerprint);if($proof.PeerHostId -cne $plan.Source.HostId){throw 'A selected source peer proof host identity differs from the approved source.'};$proof})
    $targetProof=Read-WsmTrustedJson ([string]$targetMatches[0].path) ([string]$targetMatches[0].sha256)
    Assert-WsmAssistiveTargetPhysicalProof $targetProof ([string]$targetProof.TargetPhysicalId) @($targetProof.PhysicalIdentities)|Out-Null
    if(-not $targetProof.PSObject.Properties['ReviewedTargetStateDirectory'] -or [string]::IsNullOrWhiteSpace([string]$targetProof.ReviewedTargetStateDirectory)){throw 'Re-export and review the Target proof handoff so its enrolled WorkRoot pairs directory is explicitly bound; older unbound proofs require the advanced core workflow.'}
    if([IO.Path]::GetFullPath($TargetStateDirectory) -ine [IO.Path]::GetFullPath([string]$targetProof.ReviewedTargetStateDirectory)){throw 'Target StateDirectory differs from the enrolled WorkRoot pairs directory bound by the reviewed Target proof handoff.'}
    if($targetProof.TargetHostId -cne $plan.Target.HostId -or $targetProof.ObserverMachineFingerprint -ine $plan.Target.Fingerprint){throw 'Target physical proof does not match the approved target host.'}
    $entryById=@{};foreach($entry in @($preparation.Entries)){$entryById[[string]$entry.ItemId]=$entry}
    if(@($ItemScopes).Count -ne $entryById.Count){throw 'Provide exactly one reviewed path/account row for every currently included NonC item.'}
    $scopeById=@{};foreach($scope in @($ItemScopes)){
        foreach($field in @('ItemId','SourceRoot','TargetRoot','AccountMappings')){if(-not $scope.PSObject.Properties[$field]){throw ('NonC item scope is missing '+$field+'.')}}
        $id=[string]$scope.ItemId;if(-not $entryById.ContainsKey($id) -or $scopeById.ContainsKey($id)){throw 'NonC item scope contains an unknown or duplicate item.'}
        $sourceRoot=[string]$scope.SourceRoot;$targetRoot=[string]$scope.TargetRoot
        if([string]::IsNullOrWhiteSpace($sourceRoot) -or [string]::IsNullOrWhiteSpace($targetRoot)){throw 'Review both source and target folder roots for every NonC item.'}
        $observedEntry=@($accountObservation.Entries|Where-Object {$_.ItemId -ceq $id -and $_.Status -ceq 'Observed'});if($observedEntry.Count -ne 1){throw 'The current account observation has no unique complete entry for a selected NonC item.'}
        $observedSids=@($observedEntry[0].Principals|ForEach-Object {[string]$_.SourceSid}|Sort-Object -Unique);$targetSids=@($accountObservation.TargetIdentities|ForEach-Object {[string]$_.sid}|Sort-Object -Unique);$map=[ordered]@{};$mapped=@{}
        foreach($mapping in @($scope.AccountMappings)){
            foreach($field in @('SourceSid','TargetSid')){if(-not $mapping.PSObject.Properties[$field]){throw ('NonC account mapping is missing '+$field+'.')}}
            $sourceSid=(New-Object Security.Principal.SecurityIdentifier([string]$mapping.SourceSid)).Value;$targetSid=(New-Object Security.Principal.SecurityIdentifier([string]$mapping.TargetSid)).Value
            if($observedSids -cnotcontains $sourceSid -or $targetSids -cnotcontains $targetSid){throw 'Each mapping must use an observed source ACL SID and an identity in the current target inventory.'}
            if($mapped.ContainsKey($sourceSid)){throw 'Account mapping contains a duplicate source SID.'};$mapped[$sourceSid]=$true;$map[$sourceSid]=$targetSid
        }
        if($mapped.Count -ne $observedSids.Count){throw 'Map every observed source owner and ACL principal to one explicitly chosen target account.'}
        $scopeById[$id]=[pscustomobject]@{ItemId=$id;SourceRoot=$sourceRoot;TargetRoot=$targetRoot;AccountMap=[pscustomobject]$map;AccountMappings=@($scope.AccountMappings)}
    }
    $transferEntries=@(foreach($entry in @($preparation.Entries)){$scope=$scopeById[[string]$entry.ItemId];[pscustomobject]@{ItemId=[string]$entry.ItemId;SourcePath=[string]$scope.SourceRoot;TargetPath=[string]$scope.TargetRoot;ConsumerRefs=@($entry.ConsumerRefs);AccountMap=$scope.AccountMap;Channel='NonC'}})
    $sourcePeerReferences=@(foreach($sourceMatch in $sourceMatches){$proof=@($sourceProofs|Where-Object {$_.ProofHash -ceq [string](@($observationResult.SourcePeerProofs|Where-Object {$_.SHA256 -ieq [string]$sourceMatch.sha256})[0].ContentHash)});if($proof.Count -ne 1){throw 'A selected source share proof has no unique current content binding.'};[pscustomobject]@{Path=[string]$sourceMatch.path;SHA256=[string]$sourceMatch.sha256;PeerFingerprint=[string]$proof[0].PeerFingerprint}})
    $requestScopes=@(foreach($scope in @($scopeById.Values|Sort-Object ItemId)){$m=[ordered]@{};foreach($property in $scope.AccountMap.PSObject.Properties){$m[$property.Name]=[string]$property.Value};[pscustomobject][ordered]@{ItemId=$scope.ItemId;SourceRoot=$scope.SourceRoot;TargetRoot=$scope.TargetRoot;AccountMap=$m}})
    $request=[ordered]@{PairId=$PairId;PlanHash=[string]$preparation.Current.PlanHash;ManifestHash=[string]$preparation.Current.ManifestHash;AccountObservationHash=$AccountObservationHash.ToLowerInvariant();MappingReviewOwner=$Owner.Trim();MappingReviewEvidence=$Evidence.Trim();SourcePeerProofHash=[string]$SourcePeerProofHash.ToLowerInvariant();SourcePeerProofHashes=@($selectedProofHashes);TargetPhysicalProofHash=[string]$targetMatches[0].sha256;TargetStateDirectory=[IO.Path]::GetFullPath($TargetStateDirectory);MetadataPolicy=$MetadataPolicy;ItemScopes=$requestScopes}
    $requestHash=Get-WsmHashText (ConvertTo-Json -InputObject $request -Depth 20 -Compress)
    $root=Get-WsmWizardNonCMaterialRoot $Workspace $PairId;[void](New-WsmOutputOwnedDirectory $root);Assert-WsmNoReparse $root
    $transferPath=Join-Path $root ($requestHash.ToLowerInvariant()+'.transfer.json')
    if([IO.File]::Exists($transferPath)){
        Assert-WsmNoReparse $transferPath;$transferHash=(Get-WsmAssistiveNonCHash $transferPath);$transfer=Assert-WsmAssistiveNonCPlan $null $transferPath $transferHash
        if($transfer.SealedPlanHash -ine $preparation.Current.PlanHash -or $transfer.ManifestHash -ine $preparation.Current.ManifestHash -or [long]$transfer.Generation -ne [long]$preparation.Current.Generation){throw 'Existing immutable transfer plan no longer matches current approved material.'}
    }else{
        $result=New-WsmAssistiveNonCTransferPlan -SealedPlanPath $preparation.Current.PlanPath -SealedPlanHash $preparation.Current.PlanHash -TransferPlanPath $transferPath -PairId $PairId -FreezeRecordPath $preparation.Current.FreezeRecordPath -FreezeRecordHash $preparation.Current.FreezeRecordHash -FreezeEvidencePath $preparation.Current.FreezeEvidencePath -FreezeEvidenceHash $preparation.Current.FreezeEvidenceHash -ManifestPath $preparation.Current.ManifestPath -ManifestHash $preparation.Current.ManifestHash -SourceInventoryHash $preparation.Current.InventoryHash -Channel NonC -ApprovedSourceRoots @($requestScopes|ForEach-Object SourceRoot) -ApprovedTargetRoots @($requestScopes|ForEach-Object TargetRoot) -Entries $transferEntries -TargetPhysicalId ([string]$targetProof.TargetPhysicalId) -TargetPhysicalProof $targetProof -Generation ([int]$preparation.Current.Generation) -TargetStateDirectory $TargetStateDirectory -MetadataPolicy $MetadataPolicy -SourcePeerShareProofReferences $sourcePeerReferences -ApprovedSourcePeerFingerprints @([string]$plan.Source.Fingerprint)
        $transferHash=[string]$result.SHA256;$transfer=$result.Plan
        Register-WsmAssistiveMaterialReference -Workspace $Workspace -PairId $PairId -Generation ([int]$preparation.Current.Generation) -Path $transferPath -SHA256 $transferHash -Kind AssistiveNonCTransferPlan -ConsumerRefs @($preparation.Current.NonCItemIds)|Out-Null
    }
    $reviewRoot=Join-Path $root 'account-mapping-reviews';[void](New-WsmOutputOwnedDirectory $reviewRoot);Assert-WsmNoReparse $reviewRoot
    $review=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardNonCMappingReview';PairId=$PairId;PlanHash=[string]$transfer.SealedPlanHash;TransferPlanPath=[IO.Path]::GetFullPath($transferPath);TransferPlanHash=[string]$transferHash;TransferId=[string]$transfer.TransferId;ManifestHash=[string]$transfer.ManifestHash;Generation=[int]$transfer.Generation;SelectionRevision=[int]$transfer.SelectionRevision;MetadataPolicyHash=[string]$transfer.MetadataPolicyHash;FreezeEpoch=[string]$transfer.FreezeEpoch;AccountObservationHash=$AccountObservationHash.ToLowerInvariant();SourcePeerProofHash=[string]$SourcePeerProofHash.ToLowerInvariant();SourcePeerProofHashes=@($selectedProofHashes);TargetPhysicalProofHash=[string]$targetMatches[0].sha256;Owner=$Owner.Trim();Evidence=$Evidence.Trim();Items=@(foreach($scope in @($scopeById.Values|Sort-Object ItemId)){[pscustomobject][ordered]@{ItemId=[string]$scope.ItemId;SourceRoot=[string]$scope.SourceRoot;TargetRoot=[string]$scope.TargetRoot;Mappings=@(foreach($mapping in @($scope.AccountMappings)){[pscustomobject]@{SourceSid=[string]$mapping.SourceSid;TargetSid=[string]$mapping.TargetSid;Owner=$Owner.Trim();Evidence=$Evidence.Trim()}})}});AuthoritativeApproval=$false;ProductionVerified=$false;CreatedUtc=(Get-WsmUtc);ProofHash=''}
    # S15: CreatedUtc is recorded but kept out of the hash so the same reviewed content always yields the same ProofHash.
    $reviewBody=[ordered]@{};foreach($property in $review.PSObject.Properties){if($property.Name -cnotin @('ProofHash','CreatedUtc')){$reviewBody[$property.Name]=$property.Value}};$reviewHash=Get-WsmHashText (ConvertTo-Json -InputObject $reviewBody -Depth 20 -Compress);$review.ProofHash=$reviewHash;$reviewPath=Join-Path $reviewRoot ($requestHash.ToLowerInvariant()+'.review.json')
    if([IO.File]::Exists($reviewPath)){Assert-WsmNoReparse $reviewPath;Assert-WsmTrustedFile $reviewPath (Get-WsmAssistiveNonCHash $reviewPath)}else{Write-WsmJson $reviewPath $review}
    $savedReview=Read-WsmTrustedJson $reviewPath (Get-WsmAssistiveNonCHash $reviewPath)
    $savedReviewBody=[ordered]@{};foreach($property in $savedReview.PSObject.Properties){if($property.Name -cnotin @('ProofHash','CreatedUtc')){$savedReviewBody[$property.Name]=$property.Value}};$savedReviewHash=Get-WsmHashText (ConvertTo-Json -InputObject $savedReviewBody -Depth 20 -Compress)
    if($savedReview.Kind -cne 'WizardNonCMappingReview' -or $savedReview.ProofHash -ine $savedReviewHash -or $savedReview.ProofHash -ine $reviewHash -or $savedReview.TransferPlanHash -ine $transferHash -or $savedReview.AccountObservationHash -ine $AccountObservationHash){throw 'The durable account mapping review does not match this exact transfer plan.'}
    [pscustomobject][ordered]@{Kind='WizardNonCTransferPlan';Status='Succeeded';PairId=$PairId;Path=[IO.Path]::GetFullPath($transferPath);SHA256=$transferHash;ReviewPath=[IO.Path]::GetFullPath($reviewPath);ReviewHash=(Get-WsmAssistiveNonCHash $reviewPath);TransferId=[string]$transfer.TransferId;ManifestHash=[string]$transfer.ManifestHash;Generation=[int]$transfer.Generation;Owner=$Owner.Trim();ItemIds=@($transfer.ApprovedItemIds);AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Import-WsmWizardNonCTransferPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$FreezeEvidencePath,[Parameter(Mandatory)][string]$FreezeEvidenceHash,[object[]]$Jobs=@())
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'Importing a NonC transfer plan requires the enrolled Source workspace.'}
    $received=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile;if(-not $received){throw 'A current received approved plan is required on this source host.'}
    Assert-WsmTrustedFile $Path $ExpectedHash;$transfer=Assert-WsmAssistiveNonCPlan $null $Path $ExpectedHash
    if($transfer.PairId -cne $PairId -or $transfer.SealedPlanHash -ine $received.SHA256 -or $transfer.SourceInventoryHash -ine $received.Plan.Assistive.SourceSnapshotHash -or [int]$transfer.SelectionRevision -ne [int]$received.Plan.Assistive.SourceSelectionsVersion -or $transfer.Channel -cne 'NonC'){throw 'Transfer plan is not bound to this exact source pair, approved plan, inventory and selection.'}
    # A truthful NonC backup ends ReviewRequired until target-side transfer and
    # manager result import complete. Its final C package is still verified and
    # is valid input to the separately gated NonC transfer-plan import.
    $packageJobs=@($Jobs|Where-Object {$_.action -ceq 'StartBackup' -and $_.role -ceq 'Source' -and $_.pairId -ceq $PairId -and $_.status -cin @('Succeeded','ReviewRequired') -and $_.PSObject.Properties['workspace'] -and [IO.Path]::GetFullPath([string]$_.workspace) -ieq [IO.Path]::GetFullPath($Workspace)})
    $packages=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in $packageJobs){foreach($output in @($job.outputs)){if($output.Kind -ceq 'WizardBackupResult' -and $output.PackageTest -and $output.PackageTest.Final -and $output.PackageTest.SHA256 -ieq $transfer.ManifestHash){$packages.Add($output)}}}
    $uniquePackages=@{};foreach($row in $packages){$key=([IO.Path]::GetFullPath([string]$row.PackageTest.ManifestPath).ToLowerInvariant()+'|'+([string]$row.PackageTest.SHA256).ToLowerInvariant());if(-not $uniquePackages.ContainsKey($key)){$uniquePackages[$key]=$row}};$packages=@($uniquePackages.Values)
    if($packages.Count -ne 1){throw 'A unique durable final package job for this exact transfer generation is required on Source.'}
    $packageRef=$packages[0].PackageTest;$package=Test-WsmMigrationPackage ([string]$packageRef.ManifestPath) ([string]$packageRef.SHA256);$plan=Read-WsmMigrationPlan $received.Path $received.SHA256
    $freezePath=Join-Path ([string]$package.Root) 'freeze.json';if(-not [IO.File]::Exists($freezePath)){throw 'The final package is missing its source freeze record.'}
    $freeze=Read-WsmFreezeRecord $freezePath ([string]$package.Manifest.FreezeHash) $plan $received.SHA256
    $proof=Assert-WsmSourceFreezeEvidence $FreezeEvidencePath $FreezeEvidenceHash $plan $received.SHA256 $freeze.FreezeEpoch
    Assert-WsmSourceFreezeEvidenceMatchesAttestation $proof $freeze
    $context=Assert-WsmAssistiveNonCTransferContext -TransferPlanPath $Path -TransferPlanHash $ExpectedHash -SealedPlanPath $received.Path -SealedPlanHash $received.SHA256 -ManifestPath $package.ManifestPath -ManifestHash $package.SHA256 -FreezeEvidencePath $FreezeEvidencePath -FreezeEvidenceHash $FreezeEvidenceHash -ImportOnly
    $root=Get-WsmWizardNonCMaterialRoot $Workspace $PairId;[void](New-WsmOutputOwnedDirectory $root)
    $planDestination=Join-Path $root ($ExpectedHash.ToLowerInvariant()+'.transfer.json');$evidenceDestination=Join-Path $root ($FreezeEvidenceHash.ToLowerInvariant()+'.freeze-evidence.json')
    foreach($copy in @(@($Path,$ExpectedHash,$planDestination),@($FreezeEvidencePath,$FreezeEvidenceHash,$evidenceDestination))){if([IO.File]::Exists($copy[2])){Assert-WsmTrustedFile $copy[2] $copy[1]}else{[IO.File]::Copy([IO.Path]::GetFullPath($copy[0]),$copy[2]);if((Get-WsmAssistiveNonCHash $copy[2]) -ine $copy[1]){[IO.File]::Delete($copy[2]);throw 'Imported material changed while it was copied into the owned workspace.'}}}
    [pscustomobject][ordered]@{Kind='WizardNonCTransferPlanImport';Status='ImportedVerified';PairId=$PairId;Path=[IO.Path]::GetFullPath($planDestination);SHA256=$ExpectedHash.ToLowerInvariant();FreezeEvidencePath=[IO.Path]::GetFullPath($evidenceDestination);FreezeEvidenceHash=$FreezeEvidenceHash.ToLowerInvariant();TransferId=[string]$context.Plan.TransferId;PlanHash=[string]$received.SHA256;ManifestPath=[IO.Path]::GetFullPath([string]$package.ManifestPath);ManifestHash=[string]$package.SHA256;Generation=[int]$package.Manifest.Generation;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Get-WsmWizardSourceNonCContext([string]$Workspace,[string]$PairId,[object[]]$Jobs,[string]$TransferPlanPath='',[string]$ExpectedPlanHash='',[string]$TransferChoiceId='',[switch]$AvailabilityOnly) {
    $hasPathChoice=([bool]$TransferPlanPath -or [bool]$ExpectedPlanHash)
    if($hasPathChoice -and (-not $TransferPlanPath -or -not $ExpectedPlanHash)){throw 'A transfer plan path and its trusted SHA-256 must be supplied together.'}
    if($hasPathChoice -and $TransferChoiceId){throw 'Select a transfer using either the user-facing choice or the exact internal path/hash, not both.'}
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'NonC transfer execution requires the enrolled Source workspace.'}
    $received=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile;if(-not $received){throw 'A current received approved plan is required.'}
    $jobScope=@($Jobs|Where-Object {$_.role -ceq 'Source' -and $_.pairId -ceq $PairId -and $_.PSObject.Properties['workspace'] -and [IO.Path]::GetFullPath([string]$_.workspace) -ieq [IO.Path]::GetFullPath($Workspace)})
    $currentBackup=Get-WsmWizardBackupAvailability $Workspace $PairId $profile $Jobs
    if(-not $currentBackup -or -not $currentBackup.current -or -not $currentBackup.packageTest -or -not $currentBackup.packageTest.Final -or -not $currentBackup.packageTest.Valid -or $currentBackup.packageTest.PlanHash -ine $received.SHA256){if($AvailabilityOnly){return [pscustomobject]@{Import=$null;Transfer=$null;TransferChoices=@();SelectionRequired=$false;Received=$received;Package=$null;Freeze=$null;FreezeRecordPath=''}};throw 'A verified final Source backup for the current approved plan is required before NonC transfer.'}
    $currentPackages=@{};$ref=$currentBackup.packageTest;$manifestPath=[IO.Path]::GetFullPath([string]$ref.ManifestPath);if($AvailabilityOnly){Assert-WsmTrustedFile $manifestPath ([string]$ref.SHA256);$manifest=Read-WsmTrustedJson $manifestPath ([string]$ref.SHA256);Assert-WsmEnvelope $manifest 'MigrationPackage';Assert-WsmPackageHeaderContract $manifest;$package=[pscustomobject]@{Root=[IO.Path]::GetDirectoryName($manifestPath);Manifest=$manifest;ManifestPath=$manifestPath;SHA256=[string]$ref.SHA256}}else{$package=Test-WsmMigrationPackage $manifestPath ([string]$ref.SHA256)};if(-not $package.Manifest.Final -or $package.Manifest.PairId -cne $PairId -or $package.Manifest.PlanHash -ine $received.SHA256 -or [int]$package.Manifest.Generation -ne [int]$ref.Generation){throw 'The current source backup job is not bound to the approved plan and exact final package generation.'};$packageKey=$manifestPath.ToLowerInvariant()+'|'+([string]$ref.SHA256).ToLowerInvariant()+'|'+[string]([int]$ref.Generation);$currentPackages[$packageKey]=[pscustomobject]@{Ref=$ref;Package=$package}
    $imports=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($jobScope|Where-Object {$_.action -ceq 'ImportNonCTransferPlan' -and $_.status -ceq 'Succeeded'})){foreach($output in @($job.outputs)){if($output.Kind -ceq 'WizardNonCTransferPlanImport' -and $output.PlanHash -ieq $received.SHA256){$imports.Add($output)}}}
    if(-not $imports.Count){if($AvailabilityOnly){return [pscustomobject]@{Import=$null;Transfer=$null;TransferChoices=@();SelectionRequired=$false;Received=$received;Package=$null;Freeze=$null;FreezeRecordPath=''}};throw 'Import the exact current NonC transfer plan before starting the transfer.'}
    $validatedImports=@{}
    foreach($import in $imports){
        foreach($field in @('Path','SHA256','PairId','TransferId','PlanHash','ManifestPath','ManifestHash','Generation','FreezeEvidencePath','FreezeEvidenceHash')){if(-not $import.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$import.$field)){throw 'A NonC source import receipt is missing a required material binding.'}}
        if($import.PairId -cne $PairId -or $import.PlanHash -ine $received.SHA256){continue}
        $packageKey=[IO.Path]::GetFullPath([string]$import.ManifestPath).ToLowerInvariant()+'|'+([string]$import.ManifestHash).ToLowerInvariant()+'|'+[string]([int]$import.Generation);if(-not $currentPackages.ContainsKey($packageKey)){continue};$packageRecord=$currentPackages[$packageKey];$packageRef=$packageRecord.Ref;$package=$packageRecord.Package
        $materialRoot=Get-WsmWizardNonCMaterialRoot $Workspace $PairId;$ownedImportPath=Join-Path $materialRoot (([string]$import.SHA256).ToLowerInvariant()+'.transfer.json');$ownedEvidencePath=Join-Path $materialRoot (([string]$import.FreezeEvidenceHash).ToLowerInvariant()+'.freeze-evidence.json');if([IO.Path]::GetFullPath([string]$import.Path) -ine [IO.Path]::GetFullPath($ownedImportPath) -or [IO.Path]::GetFullPath([string]$import.FreezeEvidencePath) -ine [IO.Path]::GetFullPath($ownedEvidencePath)){throw 'A NonC source import receipt points outside its content-addressed owned materials.'}
        Assert-WsmTrustedFile ([string]$import.Path) ([string]$import.SHA256);Assert-WsmTrustedFile ([string]$import.FreezeEvidencePath) ([string]$import.FreezeEvidenceHash)
        $freezeRecordPath=Join-Path ([string]$package.Root) 'freeze.json';$freeze=Read-WsmFreezeRecord $freezeRecordPath ([string]$package.Manifest.FreezeHash) $received.Plan $received.SHA256;$freezeEvidence=Assert-WsmSourceFreezeEvidence ([string]$import.FreezeEvidencePath) ([string]$import.FreezeEvidenceHash) $received.Plan $received.SHA256 $freeze.FreezeEpoch;Assert-WsmSourceFreezeEvidenceMatchesAttestation $freezeEvidence $freeze
        if($AvailabilityOnly){$transfer=Read-WsmTrustedJson ([string]$import.Path) ([string]$import.SHA256);if($transfer.Kind -cne 'AssistiveNonCTransferPlan' -or $transfer.SchemaVersion -ne 3){throw 'A stored NonC transfer plan has an unsupported contract.'};$context=$null}else{$context=Assert-WsmAssistiveNonCTransferContext -TransferPlanPath ([string]$import.Path) -TransferPlanHash ([string]$import.SHA256) -SealedPlanPath $received.Path -SealedPlanHash $received.SHA256 -ManifestPath $package.ManifestPath -ManifestHash $package.SHA256 -FreezeEvidencePath ([string]$import.FreezeEvidencePath) -FreezeEvidenceHash ([string]$import.FreezeEvidenceHash) -ImportOnly;$transfer=$context.Plan}
        if($transfer.PairId -cne $PairId -or $transfer.TransferId -cne $import.TransferId -or $transfer.SealedPlanHash -ine $received.SHA256 -or $transfer.ManifestHash -ine $package.SHA256 -or [int]$transfer.Generation -ne [int]$package.Manifest.Generation -or $transfer.SourceInventoryHash -ine $received.Plan.Assistive.SourceSnapshotHash -or $transfer.FreezeEpoch -cne $freeze.FreezeEpoch -or $transfer.FreezeProof.FreezeRecordHash -ine $package.Manifest.FreezeHash -or $transfer.FreezeProof.EvidenceHash -ine $import.FreezeEvidenceHash){throw 'The imported NonC transfer, source freeze, inventory, or final package materials do not match current sealed identities.'}
        $identity=[ordered]@{PairId=$PairId;PlanHash=$received.SHA256;Path=[IO.Path]::GetFullPath([string]$import.Path);SHA256=([string]$import.SHA256).ToLowerInvariant();TransferId=[string]$transfer.TransferId;ManifestPath=[IO.Path]::GetFullPath([string]$import.ManifestPath);ManifestHash=([string]$import.ManifestHash).ToLowerInvariant();Generation=[int]$import.Generation;FreezeRecordHash=([string]$package.Manifest.FreezeHash).ToLowerInvariant();FreezeEvidencePath=[IO.Path]::GetFullPath([string]$import.FreezeEvidencePath);FreezeEvidenceHash=([string]$import.FreezeEvidenceHash).ToLowerInvariant();FreezeEpoch=[string]$transfer.FreezeEpoch}
        $key=Get-WsmHashText (ConvertTo-Json -InputObject $identity -Depth 8 -Compress)
        $targetLabel='目標主機';foreach($field in @('Name','ComputerName','HostName')){if($received.Plan.Target.PSObject.Properties[$field] -and -not [string]::IsNullOrWhiteSpace([string]$received.Plan.Target.$field)){$targetLabel=[string]$received.Plan.Target.$field;break}}
        $workLabel='目前搬移工作';foreach($field in @('Name','DisplayName')){if($received.Plan.PSObject.Properties[$field] -and -not [string]::IsNullOrWhiteSpace([string]$received.Plan.$field)){$workLabel=[string]$received.Plan.$field;break}}
        $stampUtc=[string]$transfer.CreatedUtc;if(-not $stampUtc){$stampUtc=[string]$package.Manifest.CreatedUtc};$stamp='時間未核驗';try{$stamp=[string](Get-WsmWizardHandoffLocalTime $stampUtc).Local}catch{};$fileCount=[long]$package.Manifest.Files;$choice=[pscustomobject][ordered]@{ChoiceId=$key;Label=('{0} · {1} · 備份第 {2} 代 · {3} 個檔案 · {4}' -f $workLabel,$targetLabel,[int]$package.Manifest.Generation,$fileCount,$stamp);Path=[IO.Path]::GetFullPath([string]$import.Path);SHA256=([string]$import.SHA256).ToLowerInvariant();TransferId=[string]$transfer.TransferId;PlanHash=[string]$received.SHA256;ManifestPath=[IO.Path]::GetFullPath([string]$import.ManifestPath);ManifestHash=([string]$import.ManifestHash).ToLowerInvariant();Generation=[int]$import.Generation;FreezeEvidencePath=[IO.Path]::GetFullPath([string]$import.FreezeEvidencePath);FreezeEvidenceHash=([string]$import.FreezeEvidenceHash).ToLowerInvariant();FreezeEpoch=[string]$transfer.FreezeEpoch}
        if(-not $validatedImports.ContainsKey($key)){$validatedImports[$key]=[pscustomobject]@{Import=$import;Transfer=$transfer;Package=$package;Freeze=$freeze;FreezeRecordPath=$freezeRecordPath;Choice=$choice}}
    }
    $choices=@($validatedImports.Values|ForEach-Object {$_.Choice}|Sort-Object Label)
    $selected=$null
    if($TransferChoiceId){$matches=@($validatedImports.Values|Where-Object {$_.Choice.ChoiceId -ieq $TransferChoiceId});if($matches.Count -ne 1){throw 'The selected NonC transfer choice is no longer one verified current import.'};$selected=$matches[0]}
    elseif($TransferPlanPath){$requestedPath=[IO.Path]::GetFullPath($TransferPlanPath);$matches=@($validatedImports.Values|Where-Object {[IO.Path]::GetFullPath([string]$_.Import.Path) -ieq $requestedPath -and $_.Import.SHA256 -ieq $ExpectedPlanHash});if($matches.Count -ne 1){throw 'The selected NonC transfer plan path/hash does not identify one validated current import.'};$selected=$matches[0]}
    elseif($validatedImports.Count -eq 1){$selected=@($validatedImports.Values)[0]}
    $selectedPackage=if($selected){$selected.Package}else{$null};$selectedFreeze=if($selected){$selected.Freeze}else{$null};$selectedFreezePath=if($selected){[IO.Path]::GetFullPath([string]$selected.FreezeRecordPath)}else{''}
    [pscustomobject]@{Import=$(if($selected){$selected.Import}else{$null});Transfer=$(if($selected){$selected.Transfer}else{$null});TransferChoices=$choices;SelectionRequired=($validatedImports.Count -gt 1 -and -not $selected);Received=$received;Package=$selectedPackage;Freeze=$selectedFreeze;FreezeRecordPath=$selectedFreezePath}
}

function Get-WsmWizardSourceNonCTransferChoices([string]$Workspace,[string]$PairId,[object[]]$Jobs) {
    $context=Get-WsmWizardSourceNonCContext $Workspace $PairId $Jobs '' '' '' -AvailabilityOnly
    $choices=@($context.TransferChoices|ForEach-Object {[pscustomobject][ordered]@{ChoiceId=[string]$_.ChoiceId;Label=[string]$_.Label;TransferId=[string]$_.TransferId;PlanHash=[string]$_.PlanHash;ManifestHash=[string]$_.ManifestHash;Generation=[int]$_.Generation;FreezeEpoch=[string]$_.FreezeEpoch}})
    [pscustomobject][ordered]@{Status=$(if($choices.Count){'Ready'}else{'NeedsImport'});SelectionRequired=($choices.Count -gt 1);TransferChoices=$choices;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Invoke-WsmWizardNonCTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$OperationId,[string]$TransferPlanPath='',[string]$ExpectedPlanHash='', [string]$TransferChoiceId='', [object[]]$Jobs=@(),$CancellationToken=$null)
    Assert-WsmId $OperationId;$context=Get-WsmWizardSourceNonCContext $Workspace $PairId $Jobs $TransferPlanPath $ExpectedPlanHash $TransferChoiceId
    if(-not $context.Import -or -not $context.Transfer){throw 'Choose one exact current NonC transfer plan from the verified import choices before starting the transfer.'}
    if(($TransferPlanPath -or $ExpectedPlanHash) -and ([IO.Path]::GetFullPath($context.Import.Path) -ine [IO.Path]::GetFullPath($TransferPlanPath) -or $context.Import.SHA256 -ine $ExpectedPlanHash)){throw 'Transfer plan path/hash does not match the durable source import receipt.'}
    # The core transfer contract binds cancellation to the target state directory
    # sealed in the imported transfer plan, not to the source workspace's pairs dir.
    $targetStateDirectory=[IO.Path]::GetFullPath([string]$context.Transfer.TargetStateDirectoryAccessPath)
    if([string]::IsNullOrWhiteSpace($targetStateDirectory)){throw 'The verified NonC transfer plan has no target state directory binding.'}
    if(-not $CancellationToken){$CancellationToken=New-WsmCancellationToken -StateDirectory $targetStateDirectory -PairId $PairId -PlanHash $context.Received.SHA256 -ManifestHash $context.Package.SHA256 -OperationId $OperationId}
    Assert-WsmCancellationTokenBinding $CancellationToken $PairId $context.Received.SHA256 $context.Package.SHA256 $targetStateDirectory|Out-Null
    $root=Get-WsmWizardNonCMaterialRoot $Workspace $PairId;[void](New-WsmOutputOwnedDirectory $root);$transferId=[string]$context.Transfer.TransferId
    $runRoot=Join-Path $root ('run-'+$transferId);[void](New-WsmOutputOwnedDirectory $runRoot)
    $resultPath=Join-Path $runRoot 'result.json';$journalPath=Join-Path $runRoot 'journal.json'
    $result=Invoke-WsmAssistiveNonCTransfer -TransferPlanPath $context.Import.Path -ExpectedPlanHash $context.Import.SHA256 -SealedPlanPath $context.Received.Path -SealedPlanHash $context.Received.SHA256 -ManifestPath $context.Package.ManifestPath -ManifestHash $context.Package.SHA256 -FreezeEvidencePath $context.Import.FreezeEvidencePath -FreezeEvidenceHash $context.Import.FreezeEvidenceHash -JournalPath $journalPath -ResultPath $resultPath -CancellationToken $CancellationToken
    $rows=@($result.Result.Rows);$status=if(@($rows|Where-Object Status -ne 'Applied').Count){'ReviewRequired'}else{'Succeeded'}
    [pscustomobject][ordered]@{Kind='WizardNonCTransferResult';Status=$status;PairId=$PairId;OperationId=$OperationId;TransferId=$transferId;TransferPlanPath=$context.Import.Path;TransferPlanHash=$context.Import.SHA256;PlanHash=$context.Received.SHA256;ManifestHash=$context.Package.SHA256;Generation=[int]$context.Package.Manifest.Generation;ResultPath=[IO.Path]::GetFullPath($result.Path);ResultHash=[string]$result.SHA256;JournalPath=[IO.Path]::GetFullPath($journalPath);JournalHash=(Get-WsmAssistiveNonCHash $journalPath);Rows=$rows|ForEach-Object {$readback=$false;if($_.PSObject.Properties['Metadata'] -and $_.Metadata -and $_.Metadata.PSObject.Properties['ReadbackSucceeded']){$readback=[bool]$_.Metadata.ReadbackSucceeded};[pscustomobject]@{ItemId=[string]$_.ItemId;EntryId=[string]$_.EntryId;Status=[string]$_.Status;Reason=[string]$_.Reason;Bytes=[long]$_.Bytes;SHA256=[string]$_.SHA256;ReadbackSucceeded=$readback}};AppliedCount=@($rows|Where-Object Status -ceq 'Applied').Count;BlockedCount=@($rows|Where-Object Status -ceq 'BlockedConflict').Count;DeferredCount=@($rows|Where-Object Status -ceq 'DeferredManual').Count;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Import-WsmWizardNonCResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$TransferPlanHash,[Parameter(Mandatory)][string]$ResultPath,[Parameter(Mandatory)][string]$ExpectedResultHash,[object[]]$Jobs=@())
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Importing a NonC result requires the enrolled Manager workspace.'}
    $preparation=Get-WsmWizardNonCPreparation -Workspace $Workspace -PairId $PairId -Jobs $Jobs
    if(-not $preparation.Current.ManifestHash -or -not $preparation.Current.FreezeEvidencePath){throw 'Current final package and source freeze evidence are required before importing a transfer result.'}
    $choice=Get-WsmWizardNonCTransferMaterial $preparation $TransferPlanHash
    Assert-WsmTrustedFile $ResultPath $ExpectedResultHash
    $transfer=Assert-WsmAssistiveNonCPlan $null ([string]$choice.path) ([string]$choice.sha256)
    $plan=Read-WsmMigrationPlan $preparation.Current.PlanPath $preparation.Current.PlanHash
    $catalog=Get-WsmCatalog $Workspace $PairId
    $imported=Import-WsmAssistiveNonCResult -Workspace $Workspace -PairId $PairId -ExpectedRevision ([int]$catalog.DecisionRevision) -PlanPath $preparation.Current.PlanPath -PlanHash $preparation.Current.PlanHash -ManifestPath $preparation.Current.ManifestPath -ManifestHash $preparation.Current.ManifestHash -TransferPlanPath ([string]$choice.path) -TransferPlanHash ([string]$choice.sha256) -Generation ([int]$preparation.Current.Generation) -TargetPhysicalId ([string]$transfer.TargetPhysicalId) -MetadataPolicyHash ([string]$transfer.MetadataPolicyHash) -FreezeEpoch ([string]$transfer.FreezeEpoch) -FreezeEvidencePath $preparation.Current.FreezeEvidencePath -FreezeEvidenceHash $preparation.Current.FreezeEvidenceHash -ResultPath $ResultPath -ExpectedResultHash $ExpectedResultHash
    $reference=@($imported.Assistive.ResultReferences|Where-Object {$_.SHA256 -ieq $ExpectedResultHash -and $_.TransferId -ceq $transfer.TransferId})
    if($reference.Count -ne 1){throw 'Core result import did not persist the unique verified transfer receipt.'}
    [pscustomobject][ordered]@{Kind='WizardNonCResultImport';Status=$(if($reference[0].BlockedConflict -or $reference[0].DeferredManual){'ReviewRequired'}else{'Succeeded'});PairId=$PairId;TransferId=[string]$reference[0].TransferId;PlanHash=[string]$preparation.Current.PlanHash;ManifestHash=[string]$preparation.Current.ManifestHash;Generation=[int]$preparation.Current.Generation;ResultHash=[string]$reference[0].SHA256;AppliedCount=[int]$reference[0].Applied;BlockedCount=[int]$reference[0].BlockedConflict;DeferredCount=[int]$reference[0].DeferredManual;CatalogRevision=[int]$imported.Assistive.Revision;AuthoritativeApproval=$false;ProductionVerified=$false}
}
