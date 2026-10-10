function Get-WsmAssistiveRestoreDecision {
    param([Parameter(Mandatory)]$Package,[Parameter(Mandatory)][string]$ManifestHash,[Parameter(Mandatory)][string]$DecisionReceiptPath,[Parameter(Mandatory)][string]$DecisionReceiptHash,[string]$TargetSnapshotPath='')
    if($Package.Plan.SchemaVersion -ne 3){throw 'Assistive decision receipts are required only for schema 3 plans.'}
    Assert-WsmAssistiveContract $Package.Plan MigrationPlan | Out-Null
    if([string]$Package.Manifest.PairId -cne [string]$Package.Plan.PairId -or [string]$Package.Manifest.PlanHash -ine [string]$Package.PlanHash -or [string]$Package.SHA256 -ine $ManifestHash){throw 'Assistive package plan, pair, or manifest binding mismatch.'}
    Assert-WsmTrustedFile $DecisionReceiptPath $DecisionReceiptHash
    $receipt=Read-WsmJson $DecisionReceiptPath
    Assert-WsmAssistiveContract $receipt TargetDecisionReceipt | Out-Null
    if($receipt.PairId -cne $Package.Manifest.PairId -or $receipt.PlanHash -ine $Package.Manifest.PlanHash -or $receipt.ManifestHash -ine $ManifestHash -or [long]$receipt.Generation -ne [long]$Package.Manifest.Generation){throw 'Target decision receipt is stale or bound to another package generation.'}
    Assert-WsmAssistiveReceiptComparisonBinding $Package $receipt | Out-Null
    $allowed=New-WsmAssistiveAllowedSubset $Package.Plan @($receipt.SelectedItemIds)
    if(@($allowed).Count -ne @($receipt.SelectedItemIds).Count){throw 'Target decision receipt includes a duplicate or unapproved item.'}
    $known=@{};foreach($item in @($Package.Plan.Items)){$known[[string]$item.ItemId]=$item}
    foreach($id in @($receipt.SelectedItemIds)){if(-not $known.ContainsKey([string]$id)){throw 'Target decision receipt includes an item absent from the exact sealed package.'}}
    if([string]::IsNullOrWhiteSpace($TargetSnapshotPath)){throw 'Schema 3 restore requires the exact reviewed target snapshot path for native target freshness and identity verification.'}
    $snapshot=$null
    if($TargetSnapshotPath){
        Assert-WsmTrustedFile $TargetSnapshotPath $receipt.TargetSnapshotHash
        $snapshot=Read-WsmTrustedJson $TargetSnapshotPath $receipt.TargetSnapshotHash
        $fingerprint='';if($snapshot.PSObject.Properties['Source'] -and $snapshot.Source.PSObject.Properties['Fingerprint']){$fingerprint=[string]$snapshot.Source.Fingerprint}elseif($snapshot.PSObject.Properties['HostIdentity'] -and $snapshot.HostIdentity.PSObject.Properties['Fingerprint']){$fingerprint=[string]$snapshot.HostIdentity.Fingerprint}
        if([string]::IsNullOrWhiteSpace($fingerprint) -or $fingerprint -notmatch '^[a-fA-F0-9]{64}$'){throw 'Target snapshot has no valid native host fingerprint; exact target identity cannot be established.'}
        if($fingerprint -ine [string]$Package.Manifest.Target.Fingerprint){throw 'Target snapshot host fingerprint differs from the sealed package target.'}
        Assert-WsmAssistiveSnapshotFresh $snapshot | Out-Null
        Assert-WsmAssistiveCurrentSoftware $snapshot | Out-Null
        Assert-WsmAssistiveComparisonSnapshotVersions $receipt.Comparison $snapshot | Out-Null
    }
    [pscustomobject]@{Receipt=$receipt;ReceiptPath=[IO.Path]::GetFullPath($DecisionReceiptPath);ReceiptHash=$DecisionReceiptHash.ToLowerInvariant();Snapshot=$snapshot;SnapshotPath=$(if($TargetSnapshotPath){[IO.Path]::GetFullPath($TargetSnapshotPath)}else{''});SelectedItemIds=@($allowed)}
}

function Assert-WsmAssistiveReceiptComparisonBinding($Package,$Receipt) {
    if(-not $Receipt.PSObject.Properties['Comparison'] -or -not $Receipt.PSObject.Properties['ComparisonHash']){throw 'Schema 3 target decision receipt must embed its exact reviewed comparison and hash.'}
    $comparison=$Receipt.Comparison
    if(-not $comparison -or (Get-WsmHashText ($comparison | ConvertTo-Json -Depth 100 -Compress)) -ine [string]$Receipt.ComparisonHash -or [long]$comparison.Revision -ne [long]$Receipt.ComparisonRevision -or [string]$comparison.TargetSnapshotHash -ine [string]$Receipt.TargetSnapshotHash -or [long]$comparison.SelectionRevision -ne [long]$Receipt.SelectionRevision -or [string]$comparison.SourceSnapshotHash -ine [string]$Package.Plan.Assistive.SourceSnapshotHash){throw 'Target decision receipt comparison is not bound to the sealed source, exact target snapshot, selection, and comparison revision.'}
    $sourceEntries=@{};if($Package.Plan.PSObject.Properties['GeneralHost'] -and $Package.Plan.GeneralHost -and $Package.Plan.GeneralHost.PSObject.Properties['SoftwareCatalog'] -and $Package.Plan.GeneralHost.SoftwareCatalog){foreach($entry in @($Package.Plan.GeneralHost.SoftwareCatalog.Entries)){$sourceEntries[[string]$entry.SoftwareId]=$entry}}
    foreach($row in @($comparison.Rows)){
        if(-not $row.PSObject.Properties['SoftwareId']){throw 'Reviewed software comparison row has no stable software identity.'}
        if([string]$row.SoftwareId){foreach($field in @('SourceVersion','ChosenVersion','ObservedTargetVersion','TargetSoftwareId')){if(-not $row.PSObject.Properties[$field]){throw ('Reviewed software comparison is missing '+$field+' evidence.')}};if([string]$row.Status -ceq 'ChosenVersionObserved' -and ([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion) -or [string]::IsNullOrWhiteSpace([string]$row.ObservedTargetVersion) -or [string]$row.ChosenVersion -cne [string]$row.ObservedTargetVersion)){throw 'ChosenVersionObserved requires an exact nonempty chosen/observed target version match.'};if([string]$row.Status -ceq 'DifferentFromChosenVersion' -and ([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion) -or [string]::IsNullOrWhiteSpace([string]$row.ObservedTargetVersion) -or [string]$row.ChosenVersion -ceq [string]$row.ObservedTargetVersion)){throw 'DifferentFromChosenVersion requires exact nonempty chosen and observed versions that differ.'};if($sourceEntries.ContainsKey([string]$row.SoftwareId) -and [string]$row.SourceVersion -cne [string]$sourceEntries[[string]$row.SoftwareId].Version){throw 'Comparison SourceVersion differs from the immutable sealed GeneralHost source software facts.'}}
    }
    $true
}

function Assert-WsmAssistiveComparisonSnapshotVersions($Comparison,$Snapshot) {
    if(-not $Snapshot.PSObject.Properties['SoftwareCatalog'] -or $Snapshot.SoftwareCatalog.Entries -isnot [array]){throw 'Target snapshot cannot validate the comparison observed-version evidence.'}
    $byId=@{};foreach($entry in @($Snapshot.SoftwareCatalog.Entries)){$id=[string]$entry.SoftwareId;if(-not $id -or $byId.ContainsKey($id)){throw 'Target snapshot has missing or duplicate software identity while validating comparison evidence.'};$byId[$id]=$entry}
    foreach($row in @($Comparison.Rows)){
        $targetId=[string]$row.TargetSoftwareId
        if([string]$row.SoftwareId -and [string]$row.Status -ceq 'ChosenVersionObserved' -and ([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion) -or [string]::IsNullOrWhiteSpace([string]$row.ObservedTargetVersion) -or [string]$row.ChosenVersion -cne [string]$row.ObservedTargetVersion)){throw 'ChosenVersionObserved does not match the exact selected target version.'}
        if([string]$row.SoftwareId -and [string]$row.Status -ceq 'DifferentFromChosenVersion' -and ([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion) -or [string]::IsNullOrWhiteSpace([string]$row.ObservedTargetVersion) -or [string]$row.ChosenVersion -ceq [string]$row.ObservedTargetVersion)){throw 'DifferentFromChosenVersion does not identify distinct exact chosen and observed target versions.'}
        if($targetId){if(-not $byId.ContainsKey($targetId) -or [string]$byId[$targetId].Version -cne [string]$row.ObservedTargetVersion){throw 'Reviewed comparison observed version differs from the exact target snapshot software facts.'}}
        elseif(-not [string]::IsNullOrEmpty([string]$row.ObservedTargetVersion) -and [string]$row.Status -cne 'TargetOnly'){throw 'Reviewed comparison has an observed version without a target software identity.'}
    }
    $true
}

function Assert-WsmAssistiveSnapshotFresh($Snapshot,[ValidateRange(1,720)][int]$MaximumAgeHours=24) {
    if(-not $Snapshot.PSObject.Properties['CreatedUtc']){throw 'Target snapshot has no capture timestamp; current target/software freshness cannot be established.'}
    $captured=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse([string]$Snapshot.CreatedUtc,[ref]$captured) -or $captured.Offset -ne [TimeSpan]::Zero){throw 'Target snapshot capture timestamp is invalid or not UTC.'}
    $age=([DateTimeOffset]::UtcNow-$captured).TotalHours
    if($age -lt -0.1 -or $age -gt $MaximumAgeHours){throw 'Target snapshot is stale or from the future; refresh target software and environment evidence before restore.'}
    $true
}

function Get-WsmAssistiveCurrentSoftwareCatalog($Snapshot) {
    if(-not (Get-Command Get-WsmSoftwareCatalog -ErrorAction SilentlyContinue)){throw 'Native target software inventory is unavailable; refresh target comparison before restore.'}
    $native=Get-WsmSoftwareCatalog -Source $Snapshot -MaxEntries 10000
    Assert-WsmSoftwareCatalog $native -SourceInventory $Snapshot | Out-Null
    $native
}

function Get-WsmAssistiveSoftwareFactsHash($SoftwareCatalog) {
    if(-not $SoftwareCatalog -or $SoftwareCatalog.Entries -isnot [array] -or $SoftwareCatalog.Coverage -isnot [array]){throw 'Target software evidence is incomplete; do not infer installed dependencies from absence.'}
    $facts=New-Object 'System.Collections.Generic.List[string]';$seen=@{}
    foreach($entry in @($SoftwareCatalog.Entries)){
        if(-not (Get-Command Get-WsmGeneralHostSoftwareFactsHash -ErrorAction SilentlyContinue)){throw 'Stable target software fact hashing is unavailable.'}
        $id=[string]$entry.SoftwareId;if(-not $id -or $seen.ContainsKey($id)){throw 'Target software inventory contains a missing or duplicate stable SoftwareId.'};$seen[$id]=$true
        $facts.Add(($id+'|'+(Get-WsmGeneralHostSoftwareFactsHash $entry)))
    }
    # Incomplete profile/portable/registry probes are valid observations, not
    # proof that software is absent. Bind the exact coverage vector so a probe
    # changing status or scope invalidates the receipt without blocking
    # unrelated FileScope items globally.
    $coverage=@($SoftwareCatalog.Coverage | ForEach-Object {[pscustomobject][ordered]@{Probe=[string]$_.Probe;Scope=[string]$_.Scope;SID=[string]$_.SID;View=[string]$_.View;Status=[string]$_.Status;EvidenceKind=[string]$_.EvidenceKind;Count=[long]$_.Count;ErrorKind=[string]$_.ErrorKind;ItemId=[string]$_.ItemId}} | Sort-Object Probe,Scope,SID,View,ItemId)
    $projection=[pscustomobject][ordered]@{Entries=@($facts.ToArray() | Sort-Object);Coverage=$coverage}
    Get-WsmHashText ($projection | ConvertTo-Json -Depth 20 -Compress)
}

function Assert-WsmAssistiveCurrentSoftware($Snapshot) {
    if(-not $Snapshot.PSObject.Properties['SoftwareCatalog']){throw 'Target snapshot has no software catalog; current install state cannot be compared safely.'}
    Assert-WsmSoftwareCatalog $Snapshot.SoftwareCatalog -SourceInventory $Snapshot | Out-Null
    $expected=Get-WsmAssistiveSoftwareFactsHash $Snapshot.SoftwareCatalog
    $current=Get-WsmAssistiveCurrentSoftwareCatalog $Snapshot
    $actual=Get-WsmAssistiveSoftwareFactsHash $current
    if($actual -ine $expected){throw 'Target software changed after its reviewed comparison; create a fresh target snapshot/comparison and decision receipt before restore.'}
    $gaps=@($current.Coverage | Where-Object Status -NotIn @('Success','NotInstalled'));[pscustomobject]@{Status='Match';ExpectedHash=$expected;CurrentHash=$actual;EntryCount=@($current.Entries).Count;Coverage=$(if($gaps.Count){'Incomplete'}else{'Complete'});CoverageGapCount=$gaps.Count;ProductionVerified=$false}
}

function Assert-WsmAssistiveReceiptFresh($Package,$Decision) {
    Assert-WsmTrustedFile $Decision.ReceiptPath $Decision.ReceiptHash
    $receipt=Read-WsmJson $Decision.ReceiptPath;Assert-WsmAssistiveContract $receipt TargetDecisionReceipt | Out-Null
    if($receipt.SHA256 -ine $Decision.Receipt.SHA256 -or $receipt.PlanHash -ine $Package.Manifest.PlanHash -or $receipt.ManifestHash -ine $Package.SHA256 -or [long]$receipt.Generation -ne [long]$Package.Manifest.Generation -or ($receipt.SelectedItemIds -join '|') -cne ($Decision.SelectedItemIds -join '|')){throw 'Target decision receipt changed after preview; refresh the target decision before writing.'}
    Assert-WsmAssistiveReceiptComparisonBinding $Package $receipt | Out-Null
    if(-not $Decision.SnapshotPath){throw 'A fresh trusted target snapshot path is required before schema 3 writes.'}
    Assert-WsmTrustedFile $Decision.SnapshotPath $receipt.TargetSnapshotHash
    $snapshot=Read-WsmTrustedJson $Decision.SnapshotPath $receipt.TargetSnapshotHash
    $fingerprint='';if($snapshot.PSObject.Properties['Source'] -and $snapshot.Source.PSObject.Properties['Fingerprint']){$fingerprint=[string]$snapshot.Source.Fingerprint}elseif($snapshot.PSObject.Properties['HostIdentity'] -and $snapshot.HostIdentity.PSObject.Properties['Fingerprint']){$fingerprint=[string]$snapshot.HostIdentity.Fingerprint};if([string]::IsNullOrWhiteSpace($fingerprint) -or $fingerprint -notmatch '^[a-fA-F0-9]{64}$' -or $fingerprint -ine [string]$Package.Manifest.Target.Fingerprint){throw 'Fresh target snapshot lacks the exact native fingerprint bound to the sealed target.'}
    Assert-WsmAssistiveSnapshotFresh $snapshot | Out-Null
    Assert-WsmAssistiveCurrentSoftware $snapshot | Out-Null
    Assert-WsmAssistiveComparisonSnapshotVersions $receipt.Comparison $snapshot | Out-Null
    $true
}

function Get-WsmAssistiveWorkloadReadiness($Item) {
    $spec=$Item.MigrationSpec
    if($spec.Adapter -eq 'ManualWorkflow'){return [pscustomobject]@{Status='ManualEvidenceRequired';Reason='This item requires its dedicated owner procedure and accepted evidence.'}}
    if($spec.PSObject.Properties['WorkloadMappingReview']){
        $unresolved=@($spec.WorkloadMappingReview | Where-Object {$_.ReviewRequired -or -not $_.Applied -or $_.Status -match '^(?i)(?:Unresolved|Opaque|Manual|ReviewRequired|Blocked)'} )
        if($unresolved.Count){return [pscustomobject]@{Status='ManualEvidenceRequired';Reason=('Typed workload references need owner-reviewed target values: '+(($unresolved | ForEach-Object FieldPointer | Select-Object -Unique) -join ', '))}}
    }
    if($spec.PSObject.Properties['SourceXml']){
        if(-not $spec.PSObject.Properties['StagedDisabled'] -or $spec.StagedDisabled -ne $true -or -not $spec.PSObject.Properties['ReviewedActivation'] -or [string]$spec.DesiredFinalState -cne [string]$spec.ReviewedActivation.FinalState){return [pscustomobject]@{Status='Blocked';Reason='Workload configuration needs an explicit reviewed final activation intent and a separate disabled staging state.'}}
        try{[void](Assert-WsmAssistiveStagedXml ([string]$spec.Desired.Xml) ([string]$spec.Adapter));[void](Assert-WsmAssistiveReviewedActivation $spec)}catch{return [pscustomobject]@{Status='Blocked';Reason='Reviewed activation or staged-disabled workload contract is invalid.'}}
    }
    [pscustomobject]@{Status='Ready';Reason=''}
}

function Get-WsmAssistiveItemDependencyIssues([object[]]$Issues,[string]$ItemId) {
    @($Issues | Where-Object {$_.ConsumerItemId -ceq $ItemId})
}

function Get-WsmAssistiveNonCTargetNativePath($Package,$Entry,[object[]]$ItemEntries,$TargetPhysicalProof,[string]$ProviderId='') {
    $items=@($Package.Plan.Items | Where-Object ItemId -CEQ ([string]$Entry.ItemId));if($items.Count -ne 1 -or $items[0].MigrationSpec.Adapter -cne 'FileScope' -or $items[0].MigrationSpec.TransferChannel -cne 'NonC'){throw 'NonC result entry has no unique sealed FileScope target.'}
    $spec=$items[0].MigrationSpec;$root=[string]$spec.TargetPath;if(-not $root -or -not [IO.Path]::IsPathRooted($root) -or $root.StartsWith('\\')){throw 'NonC FileScope has no local native target root for restore projection.'}
    $relative=[string]$Entry.RelativePath;if($relative){Assert-WsmRelativePath $relative | Out-Null}
    $isExactFiles=($spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactFiles')
    $hasDirectoryRows=@($ItemEntries | Where-Object {$_.EntryType -ceq 'Directory'}).Count -gt 0
    $singleFileTarget=(-not $isExactFiles -and -not $hasDirectoryRows -and $Entry.EntryType -ceq 'File')
    $path=$root;if(-not $singleFileTarget -and $relative){$path=[IO.Path]::Combine($root,$relative)}
    $native=[IO.Path]::GetFullPath($path)
    if($native.StartsWith('\\') -or $native -match '^(?i:\\\?\\)' -or $native -match '[<>"|?*]'){throw 'NonC FileScope target projection is not a safe local native path.'}
    $peers=@();if($TargetPhysicalProof -and $TargetPhysicalProof.PeerShareProofs){$peers=@($TargetPhysicalProof.PeerShareProofs)}
    $planned=[IO.Path]::GetFullPath([string]$Entry.TargetPath)
    if($planned.StartsWith('\\')){$matchedPeer=@($peers|Where-Object {$planned -match ('^\\\\'+[regex]::Escape([string]$_.PeerName)+'\\'+[regex]::Escape([string]$_.ShareName)+'(?:\\|$)')});if($matchedPeer.Count -ne 1 -or [string]$Entry.TargetPhysicalIdentity -ine (Get-WsmAssistiveEndpointIdentity $planned $peers $ProviderId) -or -not ([IO.Path]::GetFullPath((Resolve-WsmAssistivePeerPhysicalPath $planned $matchedPeer[0])).Equals($native,[StringComparison]::OrdinalIgnoreCase))){throw 'NonC transfer UNC target does not resolve through its exact peer proof to the sealed native destination.'}}
    elseif(-not $planned.Equals($native,[StringComparison]::OrdinalIgnoreCase) -or [string]$Entry.TargetPhysicalIdentity -ine (Get-WsmAssistiveEndpointIdentity $native $peers $ProviderId)){throw 'NonC transfer target path differs from the sealed local target root and relative-path rule.'}
    $native
}

function Get-WsmAssistiveComparisonDependencyIssues($Package,$Decision) {
    $issues=New-Object 'System.Collections.Generic.List[object]';if(-not $Package.Plan.PSObject.Properties['GeneralHost'] -or -not $Package.Plan.GeneralHost.PSObject.Properties['Requirements']){return @()}
    $selected=@{};foreach($id in @($Decision.SelectedItemIds)){$selected[[string]$id]=$true}
    $rows=@{};foreach($row in @($Decision.Receipt.Comparison.Rows)){if([string]$row.SoftwareId -and -not $rows.ContainsKey([string]$row.SoftwareId)){$rows[[string]$row.SoftwareId]=$row}}
    foreach($requirement in @($Package.Plan.GeneralHost.Requirements | Where-Object {$_.ProviderSoftwareId})){if([string]$requirement.Certainty -ceq 'Candidate' -and [string]$requirement.Decision -ceq 'NotNeeded'){continue};foreach($consumerId in @($requirement.ConsumerItemIds)){
        if(-not $selected.ContainsKey([string]$consumerId) -or @($Package.Plan.Items | Where-Object ItemId -CEQ ([string]$consumerId)).Count -ne 1){continue}
        $softwareId=[string]$requirement.ProviderSoftwareId;$reason='';if([string]$requirement.Decision -ceq 'PhasePending'){$reason='Required software dependency remains phase-pending; target version observation does not satisfy its preparation evidence gate.'}elseif([string]$requirement.Decision -ceq 'NotNeeded'){$reason='Owner marked a non-candidate software dependency NotNeeded; the selected consumer remains blocked.'}elseif(-not $rows.ContainsKey($softwareId)){$reason='Required software has no source/chosen/observed version row in the reviewed comparison.'}
        else{$row=$rows[$softwareId];if([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion)){$reason='Required software chosen version is unknown.'}elseif([string]$row.Status -cne 'ChosenVersionObserved'){$reason='Required software chosen version is not observed on the exact target snapshot.'}}
        if($reason){$issues.Add([pscustomobject]@{ConsumerItemId=[string]$consumerId;Issue=$reason;SoftwareId=$softwareId;RequirementId=[string]$requirement.RequirementId})}
    }}
    $issues.ToArray()
}

function ConvertTo-WsmAssistiveNonCFileResultRows([string]$ItemId,[object[]]$Entries) {
    @(foreach($entry in @($Entries)){$status=[string]$entry.Status;if($status -eq 'Applied' -and $entry.EntryType -eq 'Directory'){$status='DirectoryReady'};$effective='';$existing='';$metadataHash='';if($entry.Status -eq 'Applied'){$effective=[string]$entry.TargetPath;try{$metadataHash=Get-WsmAssistiveMetadataHash (Get-WsmFileMetadata $effective 'DaclOwner')}catch{$status='Deferred';$effective=''}}elseif($entry.Status -eq 'BlockedConflict'){$existing=[string]$entry.TargetPath};[pscustomobject][ordered]@{ItemId=$ItemId;EntryId=[string]$entry.EntryId;EntryType=[string]$entry.EntryType;RelativePath=[string]$entry.RelativePath;Channel='NonC';OriginalPath=[string]$entry.OriginalSourcePath;PreservedPath=[string]$entry.TargetPath;EffectivePath=$effective;Status=$status;ExistingTargetPath=$existing;ExistingTargetHash='';ObservedHash=[string]$entry.SHA256;SourceHash=[string]$entry.SourceSHA256;MetadataHash=$metadataHash;Reason=[string]$entry.Reason;Generation=[long]$entry.Generation;ProjectedGeneration=[long]$entry.Generation}})
}

function Get-WsmAssistiveNonCResultRows($Package,[string]$TransferPlanPath,[string]$TransferPlanHash,[string]$ResultPath,[string]$ResultHash,[string]$StateDirectory='') {
    $rows=@{}
    if(-not $TransferPlanPath -or -not $TransferPlanHash -or -not $ResultPath -or -not $ResultHash){return $rows}
    if(-not $Package.Manifest.Final){throw 'NonC evidence may only be consumed with the exact final frozen package generation.'}
    Assert-WsmAssistiveHash $TransferPlanHash 'NonC transfer plan hash';Assert-WsmAssistiveHash $ResultHash 'NonC result hash'
    $transfer=Assert-WsmAssistiveNonCPlan $null $TransferPlanPath $TransferPlanHash
    $result=Read-WsmTrustedJson $ResultPath $ResultHash
    if($result.Kind -cne 'AssistiveNonCTransferResult' -or $result.SchemaVersion -notin @(1,2,3) -or $result.PairId -cne $Package.Manifest.PairId -or $result.PlanFileHash -ine $TransferPlanHash -or $result.SealedPlanHash -ine $Package.Manifest.PlanHash -or $result.ManifestHash -ine $Package.SHA256 -or [long]$result.Generation -ne [long]$Package.Manifest.Generation -or $result.SourceInventoryHash -ine [string]$Package.Plan.Assistive.SourceSnapshotHash -or $result.SelectionRevision -ne [int]$transfer.SelectionRevision -or $result.SelectionHash -ine $transfer.SelectionHash -or $result.TargetPhysicalId -cne $transfer.TargetPhysicalId -or $result.TargetPhysicalProofHash -ine $transfer.TargetPhysicalProof.ProofHash -or $result.MetadataPolicyHash -ine $transfer.MetadataPolicyHash -or $result.FreezeEpoch -cne $transfer.FreezeEpoch -or $result.FreezeProofHash -ine $transfer.FreezeProof.ProofHash -or $result.TransferId -cne $transfer.TransferId -or $result.Channel -cne $transfer.Channel -or ($result.SchemaVersion -ge 2 -and $result.SourceExpansionHash -ine $transfer.SourceExpansionHash)){throw 'NonC result is stale or not bound to this sealed pair, final manifest generation, selection, expanded source and freeze.'}
    if($result.SchemaVersion -ge 3){
        foreach($field in @('TargetStateDirectory','TargetStateDirectoryIdentity','TargetStateDirectoryAccessPath','TargetStateDirectoryPeerProofHash','TargetStateDirectoryProofHash')){if(-not $transfer.PSObject.Properties[$field] -or -not $result.PSObject.Properties[$field] -or [string]$result.$field -cne [string]$transfer.$field){throw ('NonC target state directory binding differs from the transfer plan: '+$field)}}
        if(-not $StateDirectory){throw 'Current target state directory is required to consume schema 3 NonC results.'}
        $nativeState=[string](Get-WsmPhysicalPath $StateDirectory);$identity=([string]$Package.Plan.Target.Fingerprint).ToLowerInvariant()+'|'+$nativeState.ToLowerInvariant();$proofHash=Get-WsmHashText ($identity+'|'+([string]$transfer.TargetStateDirectoryAccessPath).ToLowerInvariant()+'|'+([string]$transfer.TargetStateDirectoryPeerProofHash).ToLowerInvariant())
        if($nativeState.TrimEnd('\') -ine ([string]$transfer.TargetStateDirectory).TrimEnd('\') -or $identity -cne [string]$transfer.TargetStateDirectoryIdentity -or $proofHash -ine [string]$transfer.TargetStateDirectoryProofHash){throw 'NonC transfer was not bound to the exact native state directory and current target fingerprint.'}
    }
    $proof=$transfer.TargetPhysicalProof;Assert-WsmAssistiveTargetPhysicalProof $proof $transfer.TargetPhysicalId @($proof.PhysicalIdentities) | Out-Null
    if($proof.TargetHostId -cne $Package.Plan.Target.HostId -or $proof.ObserverMachineFingerprint -ine $Package.Plan.Target.Fingerprint -or (Get-WsmAssistiveMachineFingerprint) -ine $Package.Plan.Target.Fingerprint){throw 'NonC target proof does not bind the exact target host running restore.'}
    $transferEntries=@{};foreach($entry in @($transfer.Entries)){$key=[string]$entry.ItemId;if($result.SchemaVersion -ge 2){$key=[string]$entry.EntryId};if(-not $key -or $transferEntries.ContainsKey($key)){throw 'NonC transfer plan has a missing or duplicate entry identity.'};$transferEntries[$key]=$entry}
    $groups=@{}
    foreach($row in @($result.Rows)){
        $id=[string]$row.ItemId;$key=$id;if($result.SchemaVersion -ge 2){$key=[string]$row.EntryId};if(-not $transferEntries.ContainsKey($key) -or $rows.ContainsKey($key)){throw 'NonC result has a duplicate or unplanned transfer entry row.'};$entry=$transferEntries[$key]
        if($row.TargetPath -cne $entry.TargetPath -or $row.TargetPhysicalIdentity -cne $entry.TargetPhysicalIdentity -or ($row.ConsumerRefs | ConvertTo-Json -Compress) -cne ($entry.ConsumerRefs | ConvertTo-Json -Compress)){throw 'NonC result row differs from the trusted transfer plan.'}
        if($result.SchemaVersion -ge 2 -and ($row.EntryId -cne $entry.EntryId -or $row.EntryType -cne $entry.EntryType -or $row.RelativePath -cne $entry.RelativePath -or $row.SourcePath -cne $entry.SourcePath -or $row.OriginalSourcePath -cne $entry.OriginalSourcePath -or $row.SourcePeerFingerprint -cne $entry.SourcePeerFingerprint -or $row.SourcePeerProofHash -cne $entry.SourcePeerProofHash -or $row.SourceSHA256 -ine $entry.SourceSHA256 -or [long]$row.Bytes -ne [long]$entry.Bytes)){throw 'NonC result entry differs from its exact typed source/target plan.'}
        $nativeTargetPath=Get-WsmAssistiveNonCTargetNativePath $Package $entry @($transfer.Entries | Where-Object ItemId -CEQ $id) $transfer.TargetPhysicalProof ([string]$transfer.ProviderId);$verified=$false;$reason='D result did not prove successful target content and metadata readback.'
        $targetReadbackMatches=([string]$row.TargetPath -ceq [string]$entry.TargetPath -and [string]$row.TargetPhysicalIdentity -ceq [string]$entry.TargetPhysicalIdentity);$nativeObservedExists=if($row.EntryType -eq 'Directory'){[IO.Directory]::Exists($nativeTargetPath)}else{[IO.File]::Exists($nativeTargetPath)}
        $blockedConflictConfirmed=($row.Status -eq 'BlockedConflict' -and $targetReadbackMatches -and $nativeObservedExists)
        if(-not $targetReadbackMatches -and $row.Status -eq 'Applied'){$reason='D readback target physical identity does not bind the sealed local native destination.'}
        elseif($row.Status -eq 'BlockedConflict' -and -not $blockedConflictConfirmed){$reason='D conflict path does not resolve to an existing sealed native target object.'}
        if($targetReadbackMatches -and $row.Status -eq 'Applied' -and $row.Metadata.ReadbackSucceeded -and $row.Metadata.MetadataStatus -eq 'Verified' -and $row.Metadata.OwnerStatus -eq 'Verified' -and $row.Metadata.OwnerApplied -and $row.Metadata.DaclApplied -and $row.Metadata.ReadbackAccessSucceeded -and -not $entry.RequireSacl -and $row.Metadata.ReadbackOwnerSid -ceq $row.Metadata.ExpectedOwnerSid -and $row.Metadata.ReadbackDaclHash -ceq $row.Metadata.ExpectedDaclHash){
            Assert-WsmNoReparse $nativeTargetPath
            if($result.SchemaVersion -ge 2 -and $row.EntryType -eq 'Directory'){
                if([string]$row.SHA256 -or [long]$row.Bytes -ne 0 -or $row.DirectoryCreatedByTransfer -isnot [bool] -or -not [IO.Directory]::Exists($nativeTargetPath)){throw 'NonC directory row does not match its exact target directory readback.'}
                $directoryAcl=Get-Acl -LiteralPath $nativeTargetPath -ErrorAction Stop;$directoryRules=New-Object 'System.Collections.Generic.List[string]';foreach($rule in @($directoryAcl.Access)){$sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;$directoryRules.Add(($sid+'|'+$rule.AccessControlType+'|'+$rule.FileSystemRights+'|'+$rule.InheritanceFlags+'|'+$rule.PropagationFlags))};$directoryHash=Get-WsmHashText (($directoryRules|Sort-Object) -join "`n");if($directoryHash -ine [string]$row.Metadata.ReadbackDaclHash -or $directoryHash -ine [string]$row.Metadata.ExpectedDaclHash -or $directoryRules.Count -ne [int]$row.Metadata.ReadbackRuleCount -or $directoryAcl.AreAccessRulesProtected -ne [bool]$row.Metadata.DestinationAclProtected){throw 'NonC target directory DACL readback differs from its trusted transfer result.'};$directoryOwner=$directoryAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value;$directoryInfo=Get-Item -LiteralPath $nativeTargetPath -Force;if($directoryOwner -ine [string]$row.Metadata.ReadbackOwnerSid -or $directoryOwner -ine [string]$row.Metadata.ExpectedOwnerSid -or $directoryInfo.CreationTimeUtc.ToString('o') -cne [string]$row.Metadata.CreationTimeUtc -or $directoryInfo.LastWriteTimeUtc.ToString('o') -cne [string]$row.Metadata.LastWriteTimeUtc -or -not $row.Metadata.ReadbackAccessSucceeded){throw 'NonC directory owner, timestamps or access readback differs from the trusted result.'};$verified=$true
            }else{
                $expectedSource=[string]$entry.SourceSHA256;$expectedDestination=[string]$row.SHA256
                if($expectedSource -notmatch '^[a-fA-F0-9]{64}$' -or $expectedDestination -ine $expectedSource -or [long]$row.Bytes -ne [long]$entry.Bytes -or -not [IO.File]::Exists($nativeTargetPath)){throw 'NonC file result does not match the reviewed source content hash/size.'}
                if((Get-FileHash -LiteralPath $nativeTargetPath -Algorithm SHA256).Hash -ine $expectedDestination){throw 'NonC target file differs from the transferred result readback hash.'}
                $acl=Get-Acl -LiteralPath $nativeTargetPath -ErrorAction Stop;$signatures=New-Object 'System.Collections.Generic.List[string]';foreach($rule in @($acl.Access)){$sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;$signatures.Add(($sid+'|'+$rule.AccessControlType+'|'+$rule.FileSystemRights+'|'+$rule.InheritanceFlags+'|'+$rule.PropagationFlags))};$aclHash=Get-WsmHashText (($signatures|Sort-Object) -join "`n");if($aclHash -ine [string]$row.Metadata.ReadbackDaclHash -or $signatures.Count -ne [int]$row.Metadata.ReadbackRuleCount -or $acl.AreAccessRulesProtected -ne [bool]$row.Metadata.DestinationAclProtected){throw 'NonC target DACL readback differs from the trusted transfer result.'}
                $ownerSid=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value;$fileInfo=Get-Item -LiteralPath $nativeTargetPath -Force;if($ownerSid -ine [string]$row.Metadata.ReadbackOwnerSid -or $ownerSid -ine [string]$row.Metadata.ExpectedOwnerSid -or $fileInfo.CreationTimeUtc.ToString('o') -cne [string]$row.Metadata.CreationTimeUtc -or $fileInfo.LastWriteTimeUtc.ToString('o') -cne [string]$row.Metadata.LastWriteTimeUtc -or -not $row.Metadata.ReadbackAccessSucceeded){throw 'NonC target owner, timestamps or access readback differs from the trusted result.'};$verified=$true
            }
        }
        $rows[$key]=[pscustomobject]@{ItemId=$id;EntryId=[string]$row.EntryId;Status=$(if($verified){'Applied'}elseif($blockedConflictConfirmed){'BlockedConflict'}else{'Deferred'});Reason=$(if($verified){''}elseif($row.Reason -and $blockedConflictConfirmed){[string]$row.Reason}else{$reason});TargetPath=$nativeTargetPath;SourcePath=[string]$entry.SourcePath;OriginalSourcePath=[string]$entry.OriginalSourcePath;RelativePath=[string]$row.RelativePath;EntryType=[string]$row.EntryType;SHA256=[string]$row.SHA256;SourceSHA256=[string]$entry.SourceSHA256;TransferId=$result.TransferId;Generation=[long]$Package.Manifest.Generation}
    }
    if($rows.Count -ne $transferEntries.Count){throw 'NonC result omitted a transfer-plan entry row.'}
    foreach($entry in @($transfer.Entries)){$itemId=[string]$entry.ItemId;if(-not $groups.ContainsKey($itemId)){$groups[$itemId]=New-Object 'System.Collections.Generic.List[object]'};$lookupKey=$itemId;if($result.SchemaVersion -ge 2){$lookupKey=[string]$entry.EntryId};$groups[$itemId].Add($rows[$lookupKey])}
    $byItem=@{};foreach($itemId in $groups.Keys){$entries=@($groups[$itemId].ToArray());$blocked=@($entries|Where-Object Status -EQ BlockedConflict).Count;$bad=@($entries|Where-Object Status -NE Applied).Count;$fileRows=ConvertTo-WsmAssistiveNonCFileResultRows $itemId $entries;$byItem[$itemId]=[pscustomobject]@{Status=$(if($blocked){'BlockedConflict'}elseif($bad){'Deferred'}else{'Ready'});Reason=$(if($blocked){'At least one required NonC file or directory is blocked.'}elseif($bad){'At least one required NonC file or directory lacks complete target readback.'}else{'Every required NonC file and directory has matching bytes, owner, DACL and target readback; separate workload validation remains required.'});Entries=$entries;FileResults=$fileRows;TransferId=$result.TransferId}}
    $byItem
}

function Get-WsmAssistiveRestorePreview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$StateDirectory,[hashtable]$Secrets=@{},$CancellationToken=$null,[object[]]$GeneralHostEvidence=@(),[Parameter(Mandatory)][string]$AssistiveDecisionReceiptPath,[Parameter(Mandatory)][string]$AssistiveDecisionReceiptHash,[string]$AssistiveTargetSnapshotPath='',[string]$NonCTransferPlanPath='',[string]$NonCTransferPlanHash='',[string]$NonCResultPath='',[string]$NonCResultHash='')
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash $CancellationToken
    Assert-WsmMigrationHost (Get-WsmMachineIdentity) $package.Manifest.Target.Fingerprint
    $decision=Get-WsmAssistiveRestoreDecision $package $ExpectedHash $AssistiveDecisionReceiptPath $AssistiveDecisionReceiptHash $AssistiveTargetSnapshotPath
    $paths=Get-WsmOperationPaths $StateDirectory $package.Manifest.PairId;$state=Get-WsmOperationState $paths $package;$nonCError='';$nonCRows=@{};try{$nonCRows=Get-WsmAssistiveNonCResultRows $package $NonCTransferPlanPath $NonCTransferPlanHash $NonCResultPath $NonCResultHash $StateDirectory}catch{$nonCError=$_.Exception.GetType().FullName}
    $selected=@{};foreach($id in $decision.SelectedItemIds){$selected[[string]$id]=$true}
    $issues=@();if($package.Plan.PSObject.Properties['GeneralHost']){$issues=@(Get-WsmGeneralHostIssues $package.Plan RestoreReady $package.Manifest.Target.Fingerprint '' $package.Manifest.PlanHash $GeneralHostEvidence)}
    $issues+=@(Get-WsmAssistiveComparisonDependencyIssues $package $decision)
    $rows=New-Object 'System.Collections.Generic.List[object]';$problems=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in @($package.Plan.Items)){
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveRestorePreviewItem'
        if(-not $selected.ContainsKey([string]$item.ItemId)){$rows.Add([pscustomobject]@{ItemId=$item.ItemId;Adapter=$item.MigrationSpec.Adapter;Action='DeferredBySelection';Status='Deferred';Reason='This approved item was not selected in the current target decision receipt.'});continue}
        $spec=$item.MigrationSpec;$action='RestoreNow';$status='Ready';$reason='';$readiness=Get-WsmAssistiveWorkloadReadiness $item
        if($decision.Receipt.Decision -eq 'WaitForInstall'){$action='WaitForInstall';$status='DeferredSoftware';$reason='Owner chose to wait for target preparation; no target writes will occur.'}
        elseif($readiness.Status -ne 'Ready'){$action=$readiness.Status;$status=$readiness.Status;$reason=$readiness.Reason}
        else{
            $itemIssues=@(Get-WsmAssistiveItemDependencyIssues $issues ([string]$item.ItemId))
            if($itemIssues.Count -and @($decision.Receipt.AcceptedUnpreparedItemIds | Where-Object {$_ -ceq $item.ItemId}).Count -eq 0){$action='DeferredSoftware';$status='DeferredSoftware';$reason=(@($itemIssues | ForEach-Object Issue | Select-Object -Unique) -join '; ')}
            elseif($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'External'){$action='ExternalManual';$status='ManualEvidenceRequired';$reason='This selected workload depends on an external/non-C location; retain the source reference and complete the reviewed owner-managed transfer/readback procedure.'}
            elseif($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC'){$action='DeferredNonC';$status='Deferred';$reason='Required non-C content must have a current trusted D result and live readback before G can mark the workload complete.';if($nonCError){$reason='D evidence validation/readback remains incomplete: '+$nonCError};if($nonCRows.ContainsKey([string]$item.ItemId)){$nonc=$nonCRows[[string]$item.ItemId];$status=[string]$nonc.Status;$reason=[string]$nonc.Reason;if($status -ceq 'Ready'){$action='AcceptVerifiedNonC';$reason='D result is bound to the final package and every required native target file/directory has verified live readback.'}else{$action='DeferredNonC'}}}
            elseif($spec.Adapter -eq 'FileScope'){
                $target=ConvertTo-WsmCanonicalPath $spec.TargetPath
                try{
                    Assert-WsmNoReparse $target;$artifactRows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash $CancellationToken | Where-Object ItemId -CEQ $item.ItemId);$singleFileScope=($artifactRows.Count -eq 1 -and -not $artifactRows[0].Directory -and [string]::IsNullOrEmpty([string]$artifactRows[0].RelativePath))
                    if([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)){Assert-WsmAssistiveFileTopology $target}
                    foreach($artifact in $artifactRows){$artifactTarget=$target;if(-not $singleFileScope -and $artifact.RelativePath){$artifactTarget=Join-Path $target ([string]$artifact.RelativePath)};if([IO.File]::Exists($artifactTarget) -or [IO.Directory]::Exists($artifactTarget)){Assert-WsmAssistiveFileTopology $artifactTarget}}
                    if($singleFileScope){
                        if([IO.Directory]::Exists($target)){$action='BlockedConflict';$status='BlockedConflict';$reason='A directory occupies the approved single-file target.'}
                        elseif([IO.File]::Exists($target)){$prior=@($state.Items|Where-Object ItemId -CEQ $item.ItemId);$owner=$null;if($prior.Count -eq 1 -and $prior[0].PSObject.Properties['OwnedFiles']){$matches=@($prior[0].OwnedFiles|Where-Object {$_.RelativePath -ceq '' -and $_.TargetPath -ieq $target});if($matches.Count -eq 1){$owner=$matches[0]}};$current=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant();if(-not $owner -or $current -ine [string]$owner.SHA256){$action='BlockedConflict';$status='BlockedConflict';$reason='Existing single-file target is not owned by an exact prior generation.'}elseif($current -ceq [string]$artifactRows[0].Data.Hash){$map=Resolve-WsmIdentityMap $package.Plan @{};$aclPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$aclPolicy=[string]$spec.AclControlPolicy};[void](Assert-WsmAssistiveMetadataReadback $target $artifactRows[0].Metadata $map $aclPolicy);$action='VerifyOwnedSingleFile';$status='Ready';$reason='Exact owned single-file bytes and required metadata match the approved artifact.'}else{$action='ReplaceOwnedSingleFile';$status='Ready';$reason='Exact prior single-file ownership is verified; preserve a rollback copy before replacement.'}}
                        else{$parent=[IO.Path]::GetDirectoryName($target);Assert-WsmNoReparse $parent;$action='CreateSingleFile';$status='Ready';$reason='Approved single-file target is absent; its parent directory will be retained or created without applying source-directory metadata.'}
                    }elseif([IO.File]::Exists($target)){$action='BlockedConflict';$status='BlockedConflict';$reason='A file occupies the approved directory target.'}
                    elseif([IO.Directory]::Exists($target)){$action='MergeIntoExistingDirectory';$status='Ready';$reason='Existing directories are retained; only new files and verified tool-owned unchanged files may be written.'}
                }
                catch{$action='Blocked';$status='Blocked';$reason='Target path could not be verified safely.'}
            }else{
                foreach($command in (Get-WsmAdapterRequiredCommands $spec.Adapter)){if(-not (Get-Command $command -ErrorAction SilentlyContinue)){$action='DeferredSoftware';$status='DeferredSoftware';$reason=('Required target dependency is unavailable: '+$command);break}}
                if($status -eq 'Ready'){
                    try{$existing=Get-WsmAdapterState $spec;$prior=@($state.Items | Where-Object ItemId -CEQ $item.ItemId);if($existing.Exists -and -not ($prior.Count -and $prior[0].CreatedByTool -and $prior[0].AppliedManifestHash -and $prior[0].Status -in @('Succeeded','Partial'))){$action='BlockedConflict';$status='BlockedConflict';$reason='Existing target object is not owned by an exact prior Assistive generation.'}}
                    catch{$action='DeferredSoftware';$status='DeferredSoftware';$reason=('Native target preflight unavailable: '+$_.Exception.GetType().FullName)}
                }
            }
        }
        if($spec.PSObject.Properties['SharedResourceImpacts']){foreach($impact in @($spec.SharedResourceImpacts | Where-Object RequiresSharedReview)){$problems.Add([pscustomobject]@{ItemId=$item.ItemId;Reason=('Shared resource reservation/review required: '+$impact.ResourceKind+' '+$impact.ResourceItemId)})}}
        if($status -in @('Blocked','BlockedConflict')){$problems.Add([pscustomobject]@{ItemId=$item.ItemId;Reason=$reason})}
        $rows.Add([pscustomobject]@{ItemId=$item.ItemId;Name=$item.Name;Adapter=$spec.Adapter;Action=$action;Status=$status;Reason=$reason;Rollback='Per-item journal; exact owned state only';RebootPossible=($spec.Adapter -eq 'WindowsFeature')})
    }
    $decisionBlocked=($decision.Receipt.Decision -eq 'RestoreNow' -and -not $decision.Snapshot)
    if($decisionBlocked){$problems.Add([pscustomobject]@{ItemId='';Reason='Target decision receipt requires a trusted target snapshot file.'})}
    $nonCFileResults=@(foreach($itemId in $nonCRows.Keys){foreach($fileResult in @($nonCRows[$itemId].FileResults)){$fileResult}})
    [pscustomobject]@{PairId=$package.Manifest.PairId;ManifestHash=$ExpectedHash;Generation=$package.Manifest.Generation;PlanHash=$package.Manifest.PlanHash;Mode='AssistivePerItem';ScopeMode='Assistive';Decision=$decision.Receipt.Decision;DecisionReceiptHash=$decision.ReceiptHash;SelectedItemIds=@($decision.SelectedItemIds);Rows=$rows.ToArray();NonCFileResults=$nonCFileResults;Problems=$problems.ToArray();GeneralHostIssues=$issues;NonCTransferPlanPath=$NonCTransferPlanPath;NonCTransferPlanHash=$NonCTransferPlanHash;NonCResultPath=$NonCResultPath;NonCResultHash=$NonCResultHash;NonCEvidenceIssue=$nonCError;Blocked=($decisionBlocked -or @($rows | Where-Object Status -EQ 'Blocked').Count -gt 0);CanRestoreIndependentItems=(@($rows | Where-Object Status -EQ 'Ready').Count -gt 0);NoOp=($rows.Count -eq 0);BusinessValidationRequired=$true;ProductionVerified=$false}
}

function Get-WsmAssistiveFileOwnershipHash($Rows) {
    $body=@($Rows | Sort-Object RelativePath | Select-Object RelativePath,TargetPath,SHA256,Generation)
    Get-WsmHashText ($body | ConvertTo-Json -Depth 12 -Compress)
}

function Get-WsmAssistiveMetadataHash($Metadata) {
    Get-WsmHashText ($Metadata | ConvertTo-Json -Depth 8 -Compress)
}

function Assert-WsmAssistiveMetadataReadback([string]$Path,$Expected,[hashtable]$SidMap,[string]$AclPolicy='Exact') {
    $actual=Get-WsmFileMetadata $Path $Expected.MetadataMode
    $mapped=Convert-WsmMappedSddl ([string]$Expected.Sddl) $SidMap
    if(-not (Test-WsmSddlMatch $mapped ([string]$actual.Sddl) $AclPolicy)){throw 'FileScope metadata readback ACL differs from the sealed artifact.'}
    if([int]$actual.Attributes -ne [int]$Expected.Attributes){throw 'FileScope metadata readback attributes differ from the sealed artifact.'}
    foreach($field in @('CreationUtc','LastWriteUtc')){
        if([DateTimeOffset]::Parse([string]$actual.$field).UtcDateTime.Ticks -ne [DateTimeOffset]::Parse([string]$Expected.$field).UtcDateTime.Ticks){throw ('FileScope metadata readback '+$field+' differs from the sealed artifact.')}
    }
    $actual
}

function Get-WsmAssistiveReservations($Item,$Package,[string]$Workspace,[switch]$PreviewOnly) {
    if(-not (Get-Command Get-WsmAssistiveResourceReservationPreview -ErrorAction SilentlyContinue) -or -not (Get-Command Reserve-WsmAssistiveResource -ErrorAction SilentlyContinue)){throw 'Shared-resource reservation support is unavailable; this workload cannot be written safely.'}
    $spec=$Item.MigrationSpec;$channel='C';if($spec.TransferChannel -eq 'NonC'){$channel='NonC'}
    $sourceHash=Get-WsmHashText ($spec | ConvertTo-Json -Depth 40 -Compress);$consumerRefs=@([string]$Item.ItemId);$requests=New-Object 'System.Collections.Generic.List[object]'
    $kind='';$name=''
    switch($spec.Adapter){
        'FileScope' {$kind='FileScope';$name=[string]$spec.TargetPath}
        'IISPool' {$kind='IISPool';$name=[string]$spec.Desired.Name}
        'IISSite' {$kind='IISSite';$name='name:'+([string]$spec.Desired.Name)}
        'IISSection' {$kind='IISSection';$name=[string]$spec.Desired.SectionPath}
        'IISLocation' {$kind='IISLocation';$name='site:'+([string]$spec.Desired.LocationPath.Split('/')[0])+'|location:'+([string]$spec.Desired.LocationPath)}
        'ScheduledTask' {$kind='ScheduledTask';$name=([string]$spec.Desired.TaskPath)+([string]$spec.Desired.TaskName)}
        default {return @()}
    }
    $names=@([pscustomobject]@{Kind=$kind;Name=$name})
    if($spec.Adapter -eq 'ScheduledTask'){foreach($folder in @($spec.Desired.FolderSecurity)){$names+=@([pscustomobject]@{Kind='TaskFolder';Name=[string]$folder.Path})}}
    foreach($resource in $names){
        $args=@{Workspace=$Workspace;PairId=[string]$Package.Manifest.PairId;ItemId=[string]$Item.ItemId;Channel=$channel;SourceHash=$sourceHash;ConsumerRefs=$consumerRefs;ResourceKind=$resource.Kind;ResourceName=$resource.Name;TargetFingerprint=[string]$Package.Manifest.Target.Fingerprint;SealedPlanPath=(Join-Path $Package.Root 'plan.json');SealedPlanHash=[string]$Package.Manifest.PlanHash}
        if($resource.Kind -eq 'FileScope'){$args.Path=[string]$spec.TargetPath;$physical=Resolve-WsmAssistivePhysicalResource $args.Path 'LocalFileSystem';$args.TargetPhysicalId=$physical.PhysicalIdentity}
        $preview=Get-WsmAssistiveResourceReservationPreview @args
        if(-not $preview.CanReserve){throw 'Shared resource is reserved with a conflicting owner; this item remains unmodified.'}
        if(@($preview.ExistingOwners | Where-Object {$_.PairId -ceq $Package.Manifest.PairId -and $_.ItemId -ceq $Item.ItemId -and $_.Channel -ceq $channel -and $_.SourceHash -ceq $sourceHash}).Count){$requests.Add([pscustomobject]@{Preview=$preview;Existing=$true;Reservation=$null});continue}
        if($PreviewOnly){$requests.Add([pscustomobject]@{Preview=$preview;Existing=$false;Reservation=$null});continue}
        $reservation=Reserve-WsmAssistiveResource -Workspace $Workspace -Preview $preview -ExpectedPreviewHash $preview.SHA256 -ExpectedRevision $preview.RegistryRevision -Reason ('Assistive generation '+$Package.Manifest.Generation+' item '+$Item.ItemId)
        $requests.Add([pscustomobject]@{Preview=$preview;Existing=$false;Reservation=$reservation})
    }
    $requests.ToArray()
}

function Set-WsmAssistiveReservationEvidence($Reservations,$Item,$Package,$Prior,$Desired,$Readback,$Undo,[string]$Workspace) {
    if(-not (Get-Command Set-WsmAssistiveResourceEvidence -ErrorAction SilentlyContinue)){throw 'Shared-resource evidence writer is unavailable.'}
    foreach($request in @($Reservations)){
        $owner=@($request.Preview.ExistingOwners | Where-Object {$_.PairId -ceq $Package.Manifest.PairId -and $_.ItemId -ceq $Item.ItemId})
        $revision=(Get-WsmAssistiveResourceRegistry $Workspace).Revision
        $drift='Match';if($Readback.PSObject.Properties['Status'] -and $Readback.Status -ne 'Succeeded'){$drift='Unknown'}
        Set-WsmAssistiveResourceEvidence -Workspace $Workspace -ResourceKey $request.Preview.ResourceKey -PairId $Package.Manifest.PairId -ItemId $Item.ItemId -Channel $request.Preview.Channel -ExpectedRevision $revision -Prior $Prior -Desired $Desired -Readback $Readback -Undo $Undo -DriftStatus $drift | Out-Null
    }
}

function Register-WsmAssistivePackageMaterials($Package,$Decision,[string]$Workspace,$Preview) {
    if(-not (Get-Command Register-WsmAssistiveMaterialReference -ErrorAction SilentlyContinue) -or -not (Get-Command Set-WsmAssistiveJobLock -ErrorAction SilentlyContinue)){throw 'Assistive material retention/job-lock support is unavailable; schema 3 writes are blocked.'}
    $ids=New-Object 'System.Collections.Generic.List[string]';$consumers=@($Decision.SelectedItemIds)
    if(-not $consumers.Count){return [pscustomobject]@{MaterialIds=@();OperationId=''}}
    $files=@([pscustomobject]@{Path=(Join-Path $Package.Root 'plan.json');Hash=$Package.Manifest.PlanHash;Kind='AssistiveSealedPlan'},[pscustomobject]@{Path=(Join-Path $Package.Root 'manifest.json');Hash=$Package.SHA256;Kind='AssistivePackageManifest'},[pscustomobject]@{Path=(Join-Path $Package.Root 'artifacts.jsonl');Hash=$Package.Manifest.ArtifactsHash;Kind='AssistiveArtifactIndex'},[pscustomobject]@{Path=(Join-Path $Package.Root 'freeze.json');Hash=$Package.Manifest.FreezeHash;Kind='AssistiveFreezeRecord'},[pscustomobject]@{Path=$Decision.ReceiptPath;Hash=$Decision.ReceiptHash;Kind='AssistiveTargetDecisionReceipt'})
    if($Decision.SnapshotPath){$files+=@([pscustomobject]@{Path=$Decision.SnapshotPath;Hash=[string]$Decision.Receipt.TargetSnapshotHash;Kind='AssistiveTargetSnapshot'})}
    if($Preview.NonCTransferPlanPath -and $Preview.NonCTransferPlanHash){$files+=@([pscustomobject]@{Path=[string]$Preview.NonCTransferPlanPath;Hash=[string]$Preview.NonCTransferPlanHash;Kind='AssistiveNonCTransferPlan'})}
    if($Preview.NonCResultPath -and $Preview.NonCResultHash){$files+=@([pscustomobject]@{Path=[string]$Preview.NonCResultPath;Hash=[string]$Preview.NonCResultHash;Kind='AssistiveNonCTransferResult'})}
    foreach($file in $files){if(-not [IO.File]::Exists($file.Path) -or (Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -ine [string]$file.Hash){throw ('Required immutable material is missing or drifted: '+$file.Kind)}}
    if(Get-Command Register-WsmAssistiveMaterialBatch -ErrorAction SilentlyContinue){$batch=Register-WsmAssistiveMaterialBatch $Workspace $Package.Manifest.PairId ([int]$Package.Manifest.Generation) @($files) $consumers;foreach($id in @($batch.MaterialIds)){$ids.Add([string]$id)}}else{foreach($file in $files){$entry=Register-WsmAssistiveMaterialReference -Workspace $Workspace -PairId $Package.Manifest.PairId -Generation ([int]$Package.Manifest.Generation) -Path $file.Path -SHA256 $file.Hash -Kind $file.Kind -ConsumerRefs $consumers;$ids.Add([string]$entry.MaterialId)}}
    $operationId=[Guid]::NewGuid().ToString();Set-WsmAssistiveJobLock -Workspace $Workspace -OperationId $operationId -PairId $Package.Manifest.PairId -Generation ([int]$Package.Manifest.Generation) -MaterialIds @($ids.ToArray()) -Active $true | Out-Null
    [pscustomobject]@{MaterialIds=$ids.ToArray();OperationId=$operationId}
}

function Complete-WsmAssistivePackageJob($Package,$Job,[string]$Workspace) {
    if($Job -and $Job.OperationId -and (Get-Command Set-WsmAssistiveJobLock -ErrorAction SilentlyContinue)){Set-WsmAssistiveJobLock -Workspace $Workspace -OperationId $Job.OperationId -PairId $Package.Manifest.PairId -Generation ([int]$Package.Manifest.Generation) -MaterialIds @($Job.MaterialIds) -Active $false | Out-Null}
}

function Invoke-WsmAssistiveRestore($Package,[string]$ManifestHash,[string]$StateDirectory,[hashtable]$Secrets,[hashtable]$SidMap,$CancellationToken,[object[]]$GeneralHostEvidence,[string]$ReceiptPath,[string]$ReceiptHash,[string]$TargetSnapshotPath,$Preview) {
    $paths=Get-WsmOperationPaths $StateDirectory $Package.Manifest.PairId
    $state=Get-WsmOperationState $paths $Package
    if($state.Cutover){throw 'Restore after cutover requires reviewed data reconciliation; no automatic reverse synchronization.'}
    if(@($state.PendingOperations).Count){throw 'Interrupted Assistive item operation needs Repair-WsmOperation before retry.'}
    $decision=Get-WsmAssistiveRestoreDecision $Package $ManifestHash $ReceiptPath $ReceiptHash $TargetSnapshotPath
    if($decision.Receipt.Decision -eq 'WaitForInstall'){return $Preview}
    Assert-WsmAssistiveReceiptFresh $Package $decision | Out-Null
    if(-not $decision.ReceiptPath -or -not $decision.ReceiptHash -or -not $decision.SnapshotPath -or -not $decision.Receipt.TargetSnapshotHash){throw 'Assistive restore decision has no canonical receipt and target snapshot references.'}
    if($Preview.PSObject.Properties['NonCFileResults'] -and @($Preview.NonCFileResults).Count){$state | Add-Member NoteProperty AssistiveFileResults @($Preview.NonCFileResults) -Force;Add-WsmJournal $paths $state 'AssistiveNonCFileResultsImported' '' ([pscustomobject]@{Generation=[long]$Package.Manifest.Generation;Rows=@($Preview.NonCFileResults)})}
    $job=Register-WsmAssistivePackageMaterials $Package $decision $StateDirectory $Preview
    $state.Stage='Running'
    $attempt=[pscustomobject]@{ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviousManifest=$state.ManifestHash;OperationId=$(if($CancellationToken){$CancellationToken.OperationId}else{[Guid]::NewGuid().ToString()});DecisionReceiptPath=[string]$decision.ReceiptPath;DecisionReceiptHash=[string]$decision.ReceiptHash;TargetSnapshotPath=[string]$decision.SnapshotPath;TargetSnapshotHash=[string]$decision.Receipt.TargetSnapshotHash;SelectedItemIds=@($decision.SelectedItemIds);MaterialJobOperationId=$job.OperationId;MaterialIds=@($job.MaterialIds)}
    $state | Add-Member NoteProperty RestoreAttempt $attempt -Force
    Add-WsmJournal $paths $state 'AssistiveRestoreStarted' '' $attempt
    Confirm-WsmOutputStateCheckpoint -StateDirectory $StateDirectory -PairId $Package.Manifest.PairId -PlanHash $Package.Manifest.PlanHash
    $itemsById=@{};foreach($item in @($Package.Plan.Items)){$itemsById[[string]$item.ItemId]=$item}
    $itemResults=New-Object 'System.Collections.Generic.List[object]'
    foreach($row in @($Preview.Rows)){
        if($row.Status -ne 'Ready'){if($row.Status -notin @('Deferred','DeferredSoftware')){$itemResults.Add([pscustomobject]@{ItemId=$row.ItemId;Status=$row.Status;CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error=$row.Reason})};continue}
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveBeforeItem'
        Assert-WsmAssistiveReceiptFresh $Package $decision | Out-Null
        $item=$itemsById[[string]$row.ItemId];$spec=$item.MigrationSpec
        try{
            $reservations=@();if(-not ($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC')){$reservations=Get-WsmAssistiveReservations $item $Package $StateDirectory}
            $priorRecord=@($state.Items | Where-Object ItemId -CEQ $item.ItemId);$undo=$null;if($priorRecord.Count){$undo=$priorRecord[0]}
            Add-WsmJournal $paths $state 'AssistiveItemStarted' $item.ItemId ([pscustomobject]@{Adapter=$spec.Adapter;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;DecisionReceiptHash=$decision.ReceiptHash})
            if($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC'){$fileRows=@($Preview.NonCFileResults|Where-Object ItemId -CEQ $item.ItemId);if(-not $fileRows.Count -or @($fileRows|Where-Object {$_.Status -notin @('Applied','DirectoryReady') -or -not $_.EffectivePath -or [long]$_.Generation -ne [long]$Package.Manifest.Generation}).Count){throw 'NonC result lost its exact-generation native readback before G acceptance.'};$result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=$false;ExternalOwnershipVerified=$true;OwnershipChannel='NonC';AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=(Get-WsmHashText ($fileRows|Sort-Object EntryId|ConvertTo-Json -Depth 20 -Compress));Target=$spec.TargetPath;OwnedFiles=@();OwnedDirectories=@();FileResults=$fileRows;Error='';NativeCode=0}}
            elseif($spec.Adapter -eq 'FileScope'){$result=Invoke-WsmAssistiveFileScopeRestore $item $Package $paths $state $SidMap $CancellationToken $StateDirectory}
            elseif($spec.Adapter -eq 'ManualWorkflow'){$result=[pscustomobject]@{ItemId=$item.ItemId;Status='ManualEvidenceRequired';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error='Dedicated owner procedure and accepted evidence are required.'}}
            else{
                $before=Get-WsmAdapterState $spec
                $prior=@($state.Items | Where-Object ItemId -CEQ $item.ItemId)
                if($before.Exists -and -not ($prior.Count -eq 1 -and $prior[0].CreatedByTool -and $prior[0].AppliedManifestHash)) {throw 'Existing target object is not owned by a verified prior Assistive generation.'}
                if($before.Exists){$check=Test-WsmAdapterConfiguration $spec Staged;if(-not $check.Passed){throw ('Prior owned object has drifted: '+($check.Problems -join '; '))};$actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress);$result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=[bool]$prior[0].CreatedByTool;AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=$spec.Desired.Name;Backup='';Error='';NativeCode=0;PriorManifestHash=[string]$prior[0].AppliedManifestHash}}
                else{
                    $pending=[pscustomobject]@{ItemId=$item.ItemId;Phase='AssistiveAdapterCreating';Adapter=$spec.Adapter;ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;Before=$before;BeforeHash=(Get-WsmHashText ($before | ConvertTo-Json -Depth 30 -Compress));DesiredHash=(Get-WsmHashText ($spec.Desired | ConvertTo-Json -Depth 40 -Compress))}
                    $state.PendingOperations=@($state.PendingOperations | Where-Object ItemId -CNE $item.ItemId)+@($pending);Add-WsmJournal $paths $state 'AssistiveAdapterIntent' $item.ItemId $pending
                    $null=Invoke-WsmAdapterRestore $spec $Secrets $Package
                    $check=Test-WsmAdapterConfiguration $spec Staged
                    if(-not $check.Passed){throw ('Native readback failed: '+($check.Problems -join '; '))}
                    $actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress)
                    $result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=$true;AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=$spec.Desired.Name;Backup='';Error='';NativeCode=0;Before=$before}
                }
            }
            if(-not $result.PSObject.Properties['AppliedManifestHash']){$result | Add-Member NoteProperty AppliedManifestHash $ManifestHash}
            if(-not $result.PSObject.Properties['AppliedGeneration']){$result | Add-Member NoteProperty AppliedGeneration ([long]$Package.Manifest.Generation)}
            if($result.Status -eq 'Succeeded' -and -not $result.PSObject.Properties['ActualHash']){$result | Add-Member NoteProperty ActualHash ([string]$result.ActualHash)}
            if(@($reservations).Count){$desiredEvidence=$spec.Desired;if($spec.Adapter -eq 'FileScope'){$desiredEvidence=@(Read-WsmArtifactLines (Join-Path $Package.Root 'artifacts.jsonl') $Package.Manifest.ArtifactsHash $CancellationToken | Where-Object ItemId -CEQ $item.ItemId | Select-Object RelativePath,Directory,Data,Metadata)};$readback=$result;if($result.PSObject.Properties['OwnedFiles']){$readback=[pscustomobject]@{OwnedFiles=$result.OwnedFiles;OwnedDirectories=$result.OwnedDirectories;ActualHash=$result.ActualHash}};Set-WsmAssistiveReservationEvidence $reservations $item $Package $undo $desiredEvidence $readback $undo $StateDirectory;$result | Add-Member NoteProperty ResourceReservations @($reservations | ForEach-Object {$_.Preview.ResourceKey}) -Force}
            $state.PendingOperations=@($state.PendingOperations | Where-Object ItemId -CNE $item.ItemId)
            $state.Items=@($state.Items | Where-Object ItemId -CNE $item.ItemId)+@($result)
            $itemResults.Add($result)
            Add-WsmJournal $paths $state 'AssistiveItemCompleted' $item.ItemId $result
        } catch [OperationCanceledException] {throw} catch {
            $failed=[pscustomobject]@{ItemId=$item.ItemId;Status='Failed';CreatedByTool=(@($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId).Count -gt 0);AppliedManifestHash='';AppliedGeneration=0;Error=$_.Exception.GetType().FullName;NativeCode=$null}
            $state.Items=@($state.Items | Where-Object ItemId -CNE $item.ItemId)+@($failed);$itemResults.Add($failed)
            # Keep an ambiguous intent durable for repair; never erase it just because a native call threw.
            if(-not @($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId).Count){Add-WsmJournal $paths $state 'AssistiveItemFailed' $item.ItemId $failed}else{Add-WsmJournal $paths $state 'AssistiveItemNeedsRepair' $item.ItemId ([pscustomobject]@{Error=$failed.Error;Pending=@($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId)})}
        }
    }
    $state.ManifestHash=$ManifestHash;$state.Generation=[long]$Package.Manifest.Generation
    $remaining=@($Preview.Rows | Where-Object {$_.Status -in @('Deferred','DeferredSoftware','Blocked','BlockedConflict','ManualEvidenceRequired')})
    $failedCount=@($itemResults | Where-Object Status -in @('Failed','BlockedConflict','Blocked','ManualEvidenceRequired')).Count
    $state.Stage='Succeeded';if($remaining.Count -or $failedCount -or @($state.PendingOperations).Count){$state.Stage='Partial'}
    Add-WsmJournal $paths $state 'AssistiveRestoreCompleted' '' ([pscustomobject]@{Status=$state.Stage;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;DecisionReceiptHash=$decision.ReceiptHash;ItemResults=$itemResults.ToArray();DeferredRows=$remaining})
    Complete-WsmAssistivePackageJob $Package $job $StateDirectory
    [pscustomobject]@{PairId=$Package.Manifest.PairId;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;Stage=$state.Stage;Items=$state.Items;Results=$itemResults.ToArray();Deferred=$remaining;JournalHash=$state.JournalHash;BusinessValidationRequired=$true;ProductionVerified=$false}
}

function Invoke-WsmAssistiveFileScopeRestore($Item,$Package,$Paths,$State,[hashtable]$SidMap,$CancellationToken,[string]$Workspace='') {
    $spec=$Item.MigrationSpec;$target=ConvertTo-WsmCanonicalPath $spec.TargetPath;Assert-WsmNoReparse $target;if([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)){Assert-WsmAssistiveFileTopology $target}
    $index=Join-Path $Package.Root 'artifacts.jsonl';$entries=@(Read-WsmArtifactLines $index $Package.Manifest.ArtifactsHash $CancellationToken | Where-Object {$_.ItemId -ceq $Item.ItemId});if(-not $entries.Count){throw 'Approved FileScope has no package artifacts.'}
    $singleFileScope=($entries.Count -eq 1 -and -not $entries[0].Directory -and [string]::IsNullOrEmpty([string]$entries[0].RelativePath));$restoreRoot=$target;$createdDirs=New-Object 'System.Collections.Generic.List[string]'
    if($singleFileScope){if([IO.Directory]::Exists($target)){throw 'A directory occupies the approved single-file target.'};$restoreRoot=[IO.Path]::GetDirectoryName($target);Assert-WsmNoReparse $restoreRoot;if(-not [IO.Directory]::Exists($restoreRoot)){[void][IO.Directory]::CreateDirectory($restoreRoot)}}
    else{if([IO.File]::Exists($target)){throw 'A file occupies the approved FileScope directory.'};if(-not [IO.Directory]::Exists($target)){[void][IO.Directory]::CreateDirectory($target);$createdDirs.Add($target)}}
    $prior=@($State.Items | Where-Object ItemId -CEQ $Item.ItemId);$ownedFiles=@();$ownedDirectories=@()
    if($prior.Count){if($prior.Count -ne 1 -or -not $prior[0].PSObject.Properties['OwnedFiles']){throw 'Prior schema 3 FileScope ownership data is incomplete; preserve and reconcile.'};$ownedFiles=@($prior[0].OwnedFiles);if($prior[0].PSObject.Properties['OwnedDirectories']){$ownedDirectories=@($prior[0].OwnedDirectories)}}
    $results=New-Object 'System.Collections.Generic.List[object]';$nextFiles=New-Object 'System.Collections.Generic.List[object]';foreach($f in $ownedFiles){$nextFiles.Add($f)}
    $nextDirectories=New-Object 'System.Collections.Generic.List[object]';foreach($d in $ownedDirectories){$nextDirectories.Add($d)}
    $directoriesToApply=New-Object 'System.Collections.Generic.List[object]';$blockedDirectoryPaths=New-Object 'System.Collections.Generic.List[string]';$aclPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$aclPolicy=[string]$spec.AclControlPolicy}
    foreach($entry in @($entries | Where-Object Directory | Sort-Object {if($_.RelativePath){$_.RelativePath.Split([char]92).Count}else{0}})){
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveDirectoryCreate'
        $path=$target;if($entry.RelativePath){$path=Join-Path $target $entry.RelativePath};Assert-WsmNoReparse $path
        if([IO.File]::Exists($path)){ $results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='A file occupies the required directory path.'});continue }
        $directoryOwner=@($nextDirectories | Where-Object RelativePath -CEQ ([string]$entry.RelativePath));if($directoryOwner.Count -gt 1){throw 'Duplicate per-directory ownership record.'}
        $newDirectory=($createdDirs -contains $path) -or -not [IO.Directory]::Exists($path);if(-not [IO.Directory]::Exists($path)){[void][IO.Directory]::CreateDirectory($path);$createdDirs.Add($path)};Assert-WsmAssistiveFileTopology $path
        $ownedDirectory=($newDirectory -or $directoryOwner.Count -eq 1)
        $priorDirectoryMetadata=$null
        if($directoryOwner.Count -eq 1 -and -not $newDirectory){
            try{$currentMetadata=Get-WsmFileMetadata $path $entry.Metadata.MetadataMode;if(-not $directoryOwner[0].MetadataHash -or (Get-WsmAssistiveMetadataHash $currentMetadata) -ine [string]$directoryOwner[0].MetadataHash){$blockedDirectoryPaths.Add($path);$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Previously owned directory metadata drifted; preserve it and reconcile.'});continue};$priorDirectoryMetadata=$currentMetadata}catch{$blockedDirectoryPaths.Add($path);$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Previously owned directory metadata is unreadable; preserve it and reconcile.'});continue}
        }
        if($ownedDirectory){$directoriesToApply.Add([pscustomobject]@{Entry=$entry;Path=$path;Owner=$(if($directoryOwner.Count){$directoryOwner[0]}else{$null});PriorMetadata=$priorDirectoryMetadata;CreatedByTool=$newDirectory})}
        else{try{[void](Get-WsmFileMetadata $path $entry.Metadata.MetadataMode);$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='DirectoryPreserved';Reason='Existing external directory is preserved; metadata is readable.'})}catch{$blockedDirectoryPaths.Add($path);$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Existing external directory metadata is unreadable; preserve it and reconcile.'})}}
    }
    foreach($entry in @($entries | Where-Object {-not $_.Directory})){
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveFileWrite'
        $dest=$target;if($entry.RelativePath){$dest=Join-Path $restoreRoot $entry.RelativePath};$parent=[IO.Path]::GetDirectoryName($dest);Assert-WsmNoReparse $parent
        $blockedParent=@($blockedDirectoryPaths | Where-Object {$parent -ieq $_ -or $parent.StartsWith($_.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)});if($blockedParent.Count){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='A containing directory has unresolved ownership or metadata drift.'});continue}
        if(-not [IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent);$createdDirs.Add($parent)}
        $owners=@($nextFiles | Where-Object RelativePath -CEQ $entry.RelativePath);if($owners.Count -gt 1){throw 'Duplicate per-file ownership record.'};$owner=$null;if($owners.Count){$owner=$owners[0]}
        $priorMetadataForBackup=$null
        if([IO.Directory]::Exists($dest)){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='A directory occupies the required file path.'});continue}
        if([IO.File]::Exists($dest)){
            try{Assert-WsmAssistiveFileTopology $dest}catch{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Existing file topology is unsupported or could not be verified safely.'});continue}
            if(-not $owner){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Existing external file is preserved; matching bytes do not grant tool ownership.'});continue}
            $current=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
            if($current -ine [string]$owner.SHA256){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Owned file drifted since its last verified generation.'});continue}
            if(-not $owner.PSObject.Properties['MetadataHash']){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Prior owned file has no metadata readback baseline; preserve it and reconcile.'});continue}
            try{$priorMetadata=Get-WsmFileMetadata $dest $entry.Metadata.MetadataMode;if((Get-WsmAssistiveMetadataHash $priorMetadata) -ine [string]$owner.MetadataHash){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Owned file metadata drifted since its last verified generation.'});continue};$priorMetadataForBackup=$priorMetadata}catch{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Owned file metadata is unreadable; preserve it and reconcile.'});continue}
            if($current -ieq [string]$entry.Data.Hash){try{$actualMetadata=Assert-WsmAssistiveMetadataReadback $dest $entry.Metadata $SidMap $aclPolicy;$owner.MetadataHash=Get-WsmAssistiveMetadataHash $actualMetadata;$owner.Generation=[long]$Package.Manifest.Generation;$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='VerifiedOwned';MetadataStatus='Verified';Reason='Owned file bytes and required metadata match the current package.'})}catch{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Owned file metadata drifted from the current package; preserve it and reconcile.'})};continue}
        }elseif($owner){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Previously owned file is absent; do not silently recreate or discard its prior ownership.'});continue}
        $staging=$dest+'.wsm-'+[Guid]::NewGuid().ToString('N')+'.tmp';$backup='';$previousHash='';$expectedHash=[string]$entry.Data.Hash
        $pending=[pscustomobject]@{ItemId=$Item.ItemId;Phase='AssistiveFileReplace';ManifestHash=$Package.SHA256;Generation=[long]$Package.Manifest.Generation;RelativePath=[string]$entry.RelativePath;Target=$dest;Staging=$staging;Backup='';PreviousHash='';PreviousMetadataHash=$(if($owner){[string]$owner.MetadataHash}else{''});PreviousMetadata=$priorMetadataForBackup;ExpectedHash=$expectedHash;ExpectedMetadata=$entry.Metadata;WasOwned=[bool]$owner;PriorOwner=$owner}
        $State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)+@($pending);Add-WsmJournal $Paths $State 'AssistiveFileIntent' $Item.ItemId $pending
        try{
            Restore-WsmPayloadBytes $entry $Package.Root $staging $CancellationToken
            Assert-WsmAssistiveFileTopology $staging
            if((Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash -ine $expectedHash){throw 'Staged file hash differs from the sealed artifact.'}
            Set-WsmFileMetadata $staging $entry.Metadata $SidMap
            [void](Assert-WsmAssistiveMetadataReadback $staging $entry.Metadata $SidMap $aclPolicy)
            $backupMaterialId=''
            if($owner){
                $previousHash=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant();$backup=$dest+'.wsm-assistive-backup-'+$Item.ItemId.Substring(0,12)+'-'+[Guid]::NewGuid().ToString('N');$pending.PreviousHash=$previousHash;$pending.Backup=$backup;Add-WsmJournal $Paths $State 'AssistiveFilePrepared' $Item.ItemId $pending
                Assert-WsmAssistiveFileTopology $dest;$preMoveMetadata=Get-WsmFileMetadata $dest $entry.Metadata.MetadataMode;if($previousHash -ine [string]$owner.SHA256 -or (Get-WsmAssistiveMetadataHash $preMoveMetadata) -ine [string]$owner.MetadataHash){throw 'Owned file changed after preflight; do not move or replace it.'}
                [IO.File]::Move($dest,$backup)
                if($Workspace -and (Get-Command Register-WsmAssistiveMaterialReference -ErrorAction SilentlyContinue)){$material=Register-WsmAssistiveMaterialReference -Workspace $Workspace -PairId $Package.Manifest.PairId -Generation ([int]$Package.Manifest.Generation) -Path $backup -SHA256 $previousHash -Kind 'AssistiveOwnedFilePriorBackup' -ConsumerRefs @([string]$Item.ItemId);$backupMaterialId=[string]$material.MaterialId;$pending | Add-Member NoteProperty BackupMaterialId $backupMaterialId -Force;Add-WsmJournal $Paths $State 'AssistiveFileBackupRetained' $Item.ItemId ([pscustomobject]@{Backup=$backup;SHA256=$previousHash;MaterialId=$backupMaterialId;Generation=$Package.Manifest.Generation})}
                try{[IO.File]::Move($staging,$dest)}catch{if([IO.File]::Exists($backup) -and -not [IO.File]::Exists($dest)){[IO.File]::Move($backup,$dest)};throw}
            }else{[IO.File]::Move($staging,$dest)}
            Assert-WsmAssistiveFileTopology $dest
            if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ine $expectedHash){throw 'Target file readback hash differs after replacement.'}
            $actualMetadata=Assert-WsmAssistiveMetadataReadback $dest $entry.Metadata $SidMap $aclPolicy
            $record=[pscustomobject]@{RelativePath=[string]$entry.RelativePath;TargetPath=$dest;SHA256=$expectedHash;MetadataHash=(Get-WsmAssistiveMetadataHash $actualMetadata);Backup=$backup;BackupHash=$previousHash;BackupMetadata=$priorMetadataForBackup;BackupMetadataHash=$(if($owner){[string]$owner.MetadataHash}else{''});BackupMaterialId=$backupMaterialId;Generation=[long]$Package.Manifest.Generation}
            $nextFiles=@($nextFiles | Where-Object RelativePath -CNE $entry.RelativePath)+@($record)
            $State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)
            Add-WsmJournal $Paths $State 'AssistiveFileCompleted' $Item.ItemId ([pscustomobject]@{ItemId=$Item.ItemId;Record=$record;Target=$dest})
            $results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='Applied';MetadataStatus='Verified';Reason=''})
        }catch{
            $results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='Failed';MetadataStatus='NotVerified';Reason=$_.Exception.GetType().FullName})
            # Clear only a proven no-effect intent. Any backup, missing prior target, changed target,
            # or target containing the expected new bytes remains durable for explicit repair.
            $retainIntent=$false
            if([IO.File]::Exists($backup)){$retainIntent=$true}
            elseif([IO.File]::Exists($dest)){$observedHash=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant();if(($owner -and $observedHash -ine [string]$owner.SHA256) -or (-not $owner -and $observedHash -ieq $expectedHash)){$retainIntent=$true}}
            elseif($owner){$retainIntent=$true}
            if(-not $retainIntent){if([IO.File]::Exists($staging)){[IO.File]::Delete($staging)};$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)}else{break}
        }
    }
    foreach($directoryWork in $directoriesToApply){$entry=$directoryWork.Entry;$path=$directoryWork.Path;try{Assert-WsmAssistiveFileTopology $path;if($directoryWork.PriorMetadata){$beforeMetadata=Get-WsmFileMetadata $path $entry.Metadata.MetadataMode;if($beforeMetadata.Sddl -cne $directoryWork.PriorMetadata.Sddl -or [int]$beforeMetadata.Attributes -ne [int]$directoryWork.PriorMetadata.Attributes -or [string]$beforeMetadata.CreationUtc -cne [string]$directoryWork.PriorMetadata.CreationUtc){throw 'Owned directory ACL, owner, attributes or creation time changed after preflight.'}};Set-WsmFileMetadata $path $entry.Metadata $SidMap;$actualMetadata=Assert-WsmAssistiveMetadataReadback $path $entry.Metadata $SidMap $aclPolicy;$nextDirectories=@($nextDirectories | Where-Object RelativePath -CNE ([string]$entry.RelativePath))+@([pscustomobject]@{RelativePath=[string]$entry.RelativePath;TargetPath=$path;MetadataHash=(Get-WsmAssistiveMetadataHash $actualMetadata);CurrentMetadata=$actualMetadata;BackupMetadata=$directoryWork.PriorMetadata;BackupMetadataHash=$(if($directoryWork.PriorMetadata){Get-WsmAssistiveMetadataHash $directoryWork.PriorMetadata}else{''});CreatedByTool=[bool]$directoryWork.CreatedByTool;Generation=[long]$Package.Manifest.Generation});$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='DirectoryVerified';MetadataStatus='Verified';Reason=''})}catch{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='Failed';MetadataStatus='ReadbackFailed';Reason=$_.Exception.GetType().FullName})}}
    $statuses=@($results | ForEach-Object Status);$blocked=@($statuses | Where-Object {$_ -eq 'BlockedConflict'}).Count;$failed=@($statuses | Where-Object {$_ -in @('Failed','DirectoryVerified') -and $_ -eq 'Failed'}).Count
    $status='Succeeded';if($blocked){$status='BlockedConflict'}elseif($failed){$status='Failed'}
    $fileArray=@();foreach($fileRecord in $nextFiles){$fileArray+=@($fileRecord)};$directoryArray=@();foreach($directoryRecord in $nextDirectories){$directoryArray+=@($directoryRecord)}
    $record=[pscustomobject]@{ItemId=$Item.ItemId;Status=$status;CreatedByTool=$true;AppliedManifestHash=$Package.SHA256;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=(Get-WsmAssistiveFileOwnershipHash $fileArray);Target=$target;OwnedFiles=$fileArray;OwnedDirectories=$directoryArray;FileResults=$results.ToArray();Error='';NativeCode=0}
    $record
}
