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
        $sourceCatalog=$null;if($Package.Plan.PSObject.Properties['GeneralHost'] -and $Package.Plan.GeneralHost -and $Package.Plan.GeneralHost.PSObject.Properties['SoftwareCatalog']){$sourceCatalog=$Package.Plan.GeneralHost.SoftwareCatalog}
        Assert-WsmAssistiveComparisonSnapshotVersions $receipt.Comparison $snapshot $sourceCatalog | Out-Null
    }
    [pscustomobject]@{Receipt=$receipt;ReceiptPath=[IO.Path]::GetFullPath($DecisionReceiptPath);ReceiptHash=$DecisionReceiptHash.ToLowerInvariant();Snapshot=$snapshot;SnapshotPath=$(if($TargetSnapshotPath){[IO.Path]::GetFullPath($TargetSnapshotPath)}else{''});SelectedItemIds=@($allowed)}
}

function Resolve-WsmAssistiveRestoreParentOperationId([string]$OperationId,$CancellationToken,[switch]$RequireDurableParent) {
    if($OperationId){Assert-WsmId $OperationId}
    if($RequireDurableParent -and -not $OperationId){throw 'Target Service restore requires its explicit durable TargetRestore parent OperationId; a cancellation token cannot create or substitute the parent.'}
    if($RequireDurableParent -and (-not $CancellationToken -or -not $CancellationToken.PSObject.Properties['OperationId'])){throw 'Target Service restore requires a cancellation token bound to its durable TargetRestore parent.'}
    if($OperationId -and $CancellationToken -and $CancellationToken.PSObject.Properties['OperationId'] -and [string]$CancellationToken.OperationId -cne $OperationId){throw 'Service restore cancellation control must be bound to the same durable TargetRestore parent OperationId.'}
    if($OperationId){return $OperationId}
    if($CancellationToken -and $CancellationToken.PSObject.Properties['OperationId']){Assert-WsmId ([string]$CancellationToken.OperationId);return [string]$CancellationToken.OperationId}
    if($RequireDurableParent){throw 'Target Service restore requires a cancellation token bound to its durable TargetRestore parent.'}
    [Guid]::NewGuid().ToString('D')
}

function Test-WsmAssistiveServiceChallengePreWriteRecovery([string]$StateDirectory,$State,[string]$OperationId) {
    $attempt=$State.RestoreAttempt;$challenge=$State.AssistiveServiceChallenge
    if([string]$challenge.State -cne 'Running' -or [string]$challenge.ParentOperationId -cne $OperationId -or [string]$attempt.OperationId -cne $OperationId -or [string]$attempt.Status -notin @('WaitingForInput','Running') -or [string]$State.Stage -notin @('WaitingForInput','Running')){throw 'Service challenge is not in a recoverable pre-write state.'}
    if(@($State.PendingOperations).Count){throw 'Service challenge has unresolved native intent; repair and read back the target before takeover.'}
    if(@($attempt.ItemResults).Count){throw 'Service challenge already has target item results; do not replay this parent automatically.'}
    $journal=Test-WsmJournal $StateDirectory ([string]$State.PairId);if(-not $journal.Consistent){throw 'Service challenge journal is inconsistent; repair and read back the target before takeover.'}
    $paths=Get-WsmOperationPaths $StateDirectory ([string]$State.PairId);$events=@(Read-WsmJournalEvents $paths);$restoreStarts=@($events|Where-Object {$_.Row.Action -ceq 'AssistiveRestoreStarted' -and $_.Row.Detail -and [string]$_.Row.Detail.OperationId -ceq $OperationId}|Sort-Object {$_.Row.Sequence})
    if($restoreStarts.Count){$startSequence=[long]$restoreStarts[-1].Row.Sequence;$postStart=@($events|Where-Object {[long]$_.Row.Sequence -gt $startSequence});if(@($postStart|Where-Object {$_.Row.Action -in @('AssistiveItemStarted','AssistiveItemCompleted','AssistiveItemFailed','AssistiveItemNeedsRepair','AssistiveRestoreCompleted','AssistiveRestoreCancelled')}).Count){throw 'Service challenge has crossed the native item boundary; explicit RepairOperation/readback is required before takeover.'}}
    elseif([string]$State.Stage -ceq 'Running' -or [string]$attempt.Status -ceq 'Running'){throw 'Running service challenge has no matching durable restore-start journal; preserve it for manual reconciliation.'}
    $currentItems=@($State.Items|Where-Object {$_.ItemId -in @($attempt.SelectedItemIds) -and [string]$_.AppliedManifestHash -ieq [string]$attempt.ManifestHash -and [long]$_.AppliedGeneration -eq [long]$attempt.Generation});if($currentItems.Count){throw 'Service challenge parent already has current-generation item readback; do not replay it automatically.'}
    [pscustomobject]@{SafeToTakeOver=$true;JournalSequence=[long]$journal.JournalSequence;JournalHash=[string]$journal.JournalHash;NativeItemStarted=$false;PendingOperations=0}
}

function Assert-WsmAssistiveReceiptComparisonBinding($Package,$Receipt) {
    if(-not $Receipt.PSObject.Properties['Comparison'] -or -not $Receipt.PSObject.Properties['ComparisonHash']){throw 'Schema 3 target decision receipt must embed its exact reviewed comparison and hash.'}
    $comparison=$Receipt.Comparison
    if(-not $comparison -or (Get-WsmHashText ($comparison | ConvertTo-Json -Depth 100 -Compress)) -ine [string]$Receipt.ComparisonHash -or [long]$comparison.Revision -ne [long]$Receipt.ComparisonRevision -or [string]$comparison.TargetSnapshotHash -ine [string]$Receipt.TargetSnapshotHash -or [long]$comparison.SelectionRevision -ne [long]$Receipt.SelectionRevision -or [string]$comparison.SourceSnapshotHash -ine [string]$Package.Plan.Assistive.SourceSnapshotHash){throw 'Target decision receipt comparison is not bound to the sealed source, exact target snapshot, selection, and comparison revision.'}
    $sourceEntries=@{};if($Package.Plan.PSObject.Properties['GeneralHost'] -and $Package.Plan.GeneralHost -and $Package.Plan.GeneralHost.PSObject.Properties['SoftwareCatalog'] -and $Package.Plan.GeneralHost.SoftwareCatalog){foreach($entry in @($Package.Plan.GeneralHost.SoftwareCatalog.Entries)){$sourceEntries[[string]$entry.SoftwareId]=$entry}}
    foreach($row in @($comparison.Rows)){
        if(-not $row.PSObject.Properties['SoftwareId']){throw 'Reviewed software comparison row has no stable software identity.'}
        if([string]$row.SoftwareId){foreach($field in @('SourceVersion','ChosenVersion','ObservedTargetVersion','TargetSoftwareId')){if(-not $row.PSObject.Properties[$field]){throw ('Reviewed software comparison is missing '+$field+' evidence.')}};if([string]$row.Status -ceq 'ChosenVersionObserved' -and ([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion) -or [string]::IsNullOrWhiteSpace([string]$row.ObservedTargetVersion) -or [string]$row.ChosenVersion -cne [string]$row.ObservedTargetVersion -or ($row.PSObject.Properties['TargetCaptureStatus'] -and [string]$row.TargetCaptureStatus -cne 'Success') -or ($row.PSObject.Properties['SourceCaptureStatus'] -and [string]$row.SourceCaptureStatus -cne 'Success'))){throw 'ChosenVersionObserved requires exact matching versions from successful source and target evidence.'};if([string]$row.Status -ceq 'DifferentFromChosenVersion' -and ([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion) -or [string]::IsNullOrWhiteSpace([string]$row.ObservedTargetVersion) -or [string]$row.ChosenVersion -ceq [string]$row.ObservedTargetVersion)){throw 'DifferentFromChosenVersion requires exact nonempty chosen and observed versions that differ.'};if($sourceEntries.ContainsKey([string]$row.SoftwareId)){$sourceEntry=$sourceEntries[[string]$row.SoftwareId];if([string]$row.SourceVersion -cne [string]$sourceEntry.Version){throw 'Comparison SourceVersion differs from the immutable sealed GeneralHost source software facts.'};foreach($pair in @(@('SourceCaptureStatus','CaptureStatus'),@('SourceKind','SourceKind'),@('SourceLocation','Location'))){$rowField=[string]$pair[0];$entryField=[string]$pair[1];if($row.PSObject.Properties[$rowField] -and $sourceEntry.PSObject.Properties[$entryField] -and [string]$row.$rowField -cne [string]$sourceEntry.$entryField){throw ('Comparison '+$rowField+' differs from immutable source software facts.') }};if($row.PSObject.Properties['SourceVersionEvidenceKind'] -and [string]$row.SourceVersionEvidenceKind -cne (Get-WsmAssistiveVersionEvidenceKind $sourceEntry)){throw 'Comparison source version provenance differs from immutable source software facts.'};if([string]$row.Status -ceq 'ChosenVersionObserved' -and $sourceEntry.PSObject.Properties['CaptureStatus'] -and [string]$sourceEntry.CaptureStatus -cne 'Success'){throw 'ChosenVersionObserved cannot be based on incomplete source software evidence.'}}}
    }
    $true
}

function Assert-WsmAssistiveComparisonSnapshotVersions($Comparison,$Snapshot,$SourceCatalog=$null) {
    if(-not $Snapshot.PSObject.Properties['SoftwareCatalog'] -or $Snapshot.SoftwareCatalog.Entries -isnot [array]){throw 'Target snapshot cannot validate the comparison observed-version evidence.'}
    $byId=@{};foreach($entry in @($Snapshot.SoftwareCatalog.Entries)){$id=[string]$entry.SoftwareId;if(-not $id -or $byId.ContainsKey($id)){throw 'Target snapshot has missing or duplicate software identity while validating comparison evidence.'};$byId[$id]=$entry}
    $sourceById=@{};if($SourceCatalog -and $SourceCatalog.Entries -is [array]){foreach($entry in @($SourceCatalog.Entries)){if([string]$entry.SoftwareId){$sourceById[[string]$entry.SoftwareId]=$entry}}}
    foreach($row in @($Comparison.Rows)){
        $targetId=[string]$row.TargetSoftwareId
        if([string]$row.SoftwareId -and [string]$row.Status -ceq 'ChosenVersionObserved' -and ([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion) -or [string]::IsNullOrWhiteSpace([string]$row.ObservedTargetVersion) -or [string]$row.ChosenVersion -cne [string]$row.ObservedTargetVersion)){throw 'ChosenVersionObserved does not match the exact selected target version.'}
        if([string]$row.SoftwareId -and [string]$row.Status -ceq 'DifferentFromChosenVersion' -and ([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion) -or [string]::IsNullOrWhiteSpace([string]$row.ObservedTargetVersion) -or [string]$row.ChosenVersion -ceq [string]$row.ObservedTargetVersion)){throw 'DifferentFromChosenVersion does not identify distinct exact chosen and observed target versions.'}
        if($targetId){if(-not $byId.ContainsKey($targetId) -or [string]$byId[$targetId].Version -cne [string]$row.ObservedTargetVersion){throw 'Reviewed comparison observed version differs from the exact target snapshot software facts.'};$targetEntry=$byId[$targetId];foreach($pair in @(@('TargetCaptureStatus','CaptureStatus'),@('TargetSourceKind','SourceKind'),@('TargetLocation','Location'))){$rowField=[string]$pair[0];$entryField=[string]$pair[1];if($row.PSObject.Properties[$rowField] -and [string]$row.$rowField -cne [string]$targetEntry.$entryField){throw ('Reviewed comparison '+$rowField+' differs from the exact target snapshot software facts.') }};if($row.PSObject.Properties['TargetVersionEvidenceKind'] -and [string]$row.TargetVersionEvidenceKind -cne (Get-WsmAssistiveVersionEvidenceKind $targetEntry)){throw 'Reviewed comparison target version provenance differs from the exact target snapshot software facts.'};if([string]$row.SoftwareId -and [string]$row.Status -ceq 'ChosenVersionObserved' -and [string]$targetEntry.CaptureStatus -cne 'Success'){throw 'ChosenVersionObserved cannot be based on incomplete target software evidence.'};if([string]$row.SoftwareId -and [string]$row.Status -ceq 'ChosenVersionObserved' -and $sourceById.ContainsKey([string]$row.SoftwareId)){$sourceEntry=$sourceById[[string]$row.SoftwareId];if($sourceEntry.PSObject.Properties['CaptureStatus'] -and [string]$sourceEntry.CaptureStatus -cne 'Success'){throw 'ChosenVersionObserved cannot be based on incomplete source software evidence.'};if($sourceEntry.PSObject.Properties['SourceKind'] -and $sourceEntry.PSObject.Properties['Evidence'] -and (Get-WsmAssistiveVersionEvidenceKind $sourceEntry) -cne (Get-WsmAssistiveVersionEvidenceKind $targetEntry)){throw 'ChosenVersionObserved cannot compare different source/target version evidence provenance.'}}}
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
    $coverage=@($SoftwareCatalog.Coverage | ForEach-Object {[pscustomobject][ordered]@{Probe=[string]$_.Probe;Scope=[string]$_.Scope;SID=[string]$_.SID;View=[string]$_.View;Status=[string]$_.Status;EvidenceKind=[string]$_.EvidenceKind;Count=[long]$_.Count;ErrorKind=[string]$_.ErrorKind;ItemId=$(if($_.PSObject.Properties['ItemId']){[string]$_.ItemId}else{''})}} | Sort-Object Probe,Scope,SID,View,ItemId)
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
        $sourceCatalog=$null;if($Package.Plan.PSObject.Properties['GeneralHost'] -and $Package.Plan.GeneralHost -and $Package.Plan.GeneralHost.PSObject.Properties['SoftwareCatalog']){$sourceCatalog=$Package.Plan.GeneralHost.SoftwareCatalog}
        Assert-WsmAssistiveComparisonSnapshotVersions $receipt.Comparison $snapshot $sourceCatalog | Out-Null
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
    $spec=$items[0].MigrationSpec;if($spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactMembers'){throw 'ExactMembers is not supported by the legacy NonC restore reader.'};$root=[string]$spec.TargetPath;if(-not $root -or -not [IO.Path]::IsPathRooted($root) -or $root.StartsWith('\\')){throw 'NonC FileScope has no local native target root for restore projection.'}
    $relative=[string]$Entry.RelativePath;if($relative){Assert-WsmRelativePath $relative | Out-Null}
    $isExactFiles=($spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactFiles')
    $hasDirectoryRows=@($ItemEntries | Where-Object {$_.EntryType -ceq 'Directory'}).Count -gt 0
    $singleFileTarget=(-not $isExactFiles -and -not $hasDirectoryRows -and $Entry.EntryType -ceq 'File')
    $path=$root;if(-not $singleFileTarget -and $relative){$path=[IO.Path]::Combine($root,$relative)}
    $native=[IO.Path]::GetFullPath($path)
    if($native.StartsWith('\\') -or $native -match '^(?i:\\\?\\)' -or $native -match '[<>"|?*]'){throw 'NonC FileScope target projection is not a safe local native path.'}
    $peers=@();if($TargetPhysicalProof -and $TargetPhysicalProof.PeerShareProofs){$peers=@($TargetPhysicalProof.PeerShareProofs)}
    $planned=[IO.Path]::GetFullPath([string]$Entry.TargetPath)
    if($planned.StartsWith('\\')){$matchedPeer=@($peers|Where-Object {$planned -match ('^\\\\'+[regex]::Escape([string]$_.PeerName)+'\\'+[regex]::Escape([string]$_.ShareName)+'(?:\\|$)')});if($matchedPeer.Count -ne 1 -or [string]$Entry.TargetPhysicalIdentity -ine (Get-WsmAssistiveEndpointIdentity $planned $peers $ProviderId) -or -not ([string](Resolve-WsmAssistivePeerPhysicalPath $planned $matchedPeer[0])).TrimEnd('\').Equals(([string](Get-WsmPhysicalPath $native)).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){throw 'NonC transfer UNC target does not resolve through its exact peer proof to the sealed native destination.'}}
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
        else{$row=$rows[$softwareId];if([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion)){$reason='Required software chosen version is unknown.'}elseif([string]$row.Status -cne 'ChosenVersionObserved' -or ($row.PSObject.Properties['TargetCaptureStatus'] -and [string]$row.TargetCaptureStatus -cne 'Success') -or ($row.PSObject.Properties['SourceCaptureStatus'] -and [string]$row.SourceCaptureStatus -cne 'Success') -or ($row.PSObject.Properties['SourceVersionEvidenceKind'] -and [string]$row.SourceVersionEvidenceKind -cne [string]$row.TargetVersionEvidenceKind)){$reason='Required software version is not supported by successful, matching source and target evidence on the exact reviewed snapshots.'}}
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

function Assert-WsmAssistiveTargetScopeTopology {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Spec,[Parameter(Mandatory)][string]$TargetRoot,[Parameter()][AllowNull()]$Artifact,[ValidateSet('Root','Directory','File','Staging','Backup')][string]$Kind='File',[string]$Destination='',[string]$TrustedExistingHash='')
    if($Spec.PSObject.Properties['ContentSelection'] -and [string]$Spec.ContentSelection -ceq 'ExactMembers'){
        $root=[IO.Path]::GetFullPath($TargetRoot);if($root -ine [IO.Path]::GetFullPath([string]$Spec.TargetPath)){throw 'ExactMembers target root differs from its sealed TargetPath.'}
        if($Kind -eq 'Root'){if([IO.Path]::GetFullPath($Path) -ine $root){throw 'ExactMembers root check is not bound to its sealed TargetPath.'};Assert-WsmFileScopeGuard -Path $Path -Mode Root -AllowDriveRoot;Assert-WsmFileScopeGuard -Path (Get-WsmPhysicalPath $Path) -Mode Root -AllowDriveRoot;Assert-WsmNoReparse $Path;return}
        if($null -eq $Artifact -or -not $Artifact.PSObject.Properties['RelativePath']){throw 'ExactMembers target operation requires a validated package artifact row.'}
        $relative=[string]$Artifact.RelativePath;Assert-WsmRelativePath $relative;$members=@($Spec.Members|Where-Object {[string]$_.RelativePath -ceq $relative})
        $directoryMember=($members.Count -eq 1 -and (Test-WsmExactDirectoryMember $members[0]))
        if($directoryMember -or [bool]$Artifact.Directory){
            # A directory artifact must be exactly one sealed leaf Directory member and may only be checked as a Directory.
            if(-not $directoryMember -or -not [bool]$Artifact.Directory -or $Kind -ne 'Directory'){throw 'ExactMembers directory artifact is not exactly one sealed directory member.'}
            $expected=[IO.Path]::GetFullPath((Join-Path $root $relative));$destPath=if($Destination){[IO.Path]::GetFullPath($Destination)}else{$expected}
            if($destPath -ine $expected){throw 'ExactMembers destination differs from the exact reviewed target-relative member.'}
            if([IO.Path]::GetFullPath($Path).TrimEnd('\') -ine $expected.TrimEnd('\')){throw 'ExactMembers directory member check is not bound to its reviewed target-relative path.'}
            Assert-WsmNoReparse $Path;Assert-WsmFileScopeGuard -Path $Path -Mode ExactMembers -SourceRoot $root -RelativePath $relative -IsDirectory -PathOnly -CheckPhysicalAlias;Assert-WsmAssistiveFileTopology $Path;return
        }
        if($members.Count -ne 1 -or $Artifact.Directory -or -not $Artifact.Data -or [string]$Artifact.Data.Hash -cne [string]$members[0].SHA256){throw 'ExactMembers artifact is not exactly one hash-bound sealed member.'}
        $expected=[IO.Path]::GetFullPath((Join-Path $root $relative));$destPath=if($Destination){[IO.Path]::GetFullPath($Destination)}else{$expected}
        if($destPath -ine $expected){throw 'ExactMembers destination differs from the exact reviewed target-relative member.'}
        if($Kind -eq 'Directory'){
            $candidate=[IO.Path]::GetFullPath($Path).TrimEnd('\');$rootTrim=$root.TrimEnd('\');$parent=[IO.Path]::GetDirectoryName($expected)
            if($candidate -ieq $rootTrim){Assert-WsmFileScopeGuard -Path $Path -Mode Root -AllowDriveRoot;Assert-WsmNoReparse $Path;return}
            if($candidate -ine $parent -and -not $parent.StartsWith($candidate.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'ExactMembers directory is not an ancestor of its approved member.'}
            Assert-WsmNoReparse $Path;Assert-WsmFileScopeGuard -Path $Path -Mode ExactMembers -SourceRoot $root -RelativePath $relative -IsDirectory -PathOnly -CheckPhysicalAlias;Assert-WsmAssistiveFileTopology $Path;return
        }
        if($Kind -eq 'File'){$expectedPath=$expected}
        elseif($Kind -eq 'Staging'){if([IO.Path]::GetFullPath($Path) -notmatch ('^'+[regex]::Escape($expected)+'\.wsm-[a-f0-9]{32}\.tmp$')){throw 'ExactMembers staging file is not an operation-generated sibling of its approved member.'};$expectedPath=$Path}
        elseif($Kind -eq 'Backup'){$prefix=[string]$Artifact.ItemId;if(-not $TrustedExistingHash -or $TrustedExistingHash -notmatch '^[a-fA-F0-9]{64}$' -or [IO.Path]::GetFullPath($Path) -notmatch ('^'+[regex]::Escape($expected)+'\.wsm-assistive-backup-'+[regex]::Escape($prefix.Substring(0,12))+'-[a-f0-9]{32}$')){throw 'ExactMembers backup is not an operation-generated sibling of its approved member.'};$expectedPath=$Path}
        else{throw 'Unsupported ExactMembers target topology operation.'}
        Assert-WsmNoReparse $expectedPath;Assert-WsmFileScopeGuard -Path $expectedPath -Mode ExactMembers -SourceRoot $root -RelativePath $relative -CheckPhysicalAlias;Assert-WsmAssistiveFileTopology $expectedPath
        if([IO.File]::Exists($expectedPath)){$actual=(Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant();$accepted=[string]$Artifact.Data.Hash;if($TrustedExistingHash -and $actual -ceq $TrustedExistingHash){$accepted=$TrustedExistingHash};if($actual -cne $accepted){throw 'Existing ExactMembers bytes are neither the sealed member nor its durably owned prior version.'}}
        return
    }
    if(-not ($Spec.PSObject.Properties['ContentSelection'] -and [string]$Spec.ContentSelection -ceq 'ExactFiles')){
        if($Kind -eq 'Root'){Assert-WsmFileScopeGuard -Path $Path -Mode Root;Assert-WsmFileScopeGuard -Path (Get-WsmPhysicalPath $Path) -Mode Root;if([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)){Assert-WsmAssistiveFileTopology $Path};return}
        Assert-WsmAssistiveFileTopology $Path;return
    }
    if($Kind -eq 'Root'){
        if([IO.Path]::GetFullPath($Path) -ine [IO.Path]::GetFullPath($TargetRoot)){throw 'Exact target root does not match the sealed TargetPath.'}
        Assert-WsmFileScopeGuard -Path $Path -Mode Root -AllowProtectedExactRoot
        Assert-WsmFileScopeGuard -Path (Get-WsmPhysicalPath $Path) -Mode Root -AllowProtectedExactRoot
        Assert-WsmNoReparse $Path
        return
    }
    if($null -eq $Artifact -or -not $Artifact.PSObject.Properties['RelativePath']){throw 'Target config exception requires one validated package artifact row.'}
    $relative=[string]$Artifact.RelativePath
    $configured=@(Get-WsmConfigSpecEntries $Spec 'ConfigFiles' | Where-Object {[string]$_.RelativePath -ceq $relative})
    if($Kind -eq 'Directory'){
        if($configured.Count -eq 1 -and $Artifact.PSObject.Properties['Data'] -and $Artifact.Data.PSObject.Properties['Hash'] -and [string]$configured[0].SHA256 -ieq [string]$Artifact.Data.Hash){
            $configForTopology=$relative
        }else{
            $descendants=@(if($relative){Get-WsmConfigSpecEntries $Spec 'ConfigFiles' | Where-Object {[string]$_.RelativePath -like ($relative.TrimEnd('\')+'\*')}}else{Get-WsmConfigSpecEntries $Spec 'ConfigFiles'})
            if($descendants.Count -eq 0){throw 'Target directory is not a parent of an approved exact config file.'}
            $configForTopology=[string]$descendants[0].RelativePath
        }
    }else{
        if(-not $Artifact.PSObject.Properties['Data'] -or -not $Artifact.Data.PSObject.Properties['Hash'] -or $configured.Count -ne 1 -or [string]$configured[0].SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$configured[0].SHA256 -ine [string]$Artifact.Data.Hash){throw 'Target config artifact is not the exact hash-bound member of the approved ConfigFiles whitelist.'}
        $configForTopology=$relative
    }
    if($relative){Assert-WsmRelativePath $relative}
    $expected=if($relative){Join-Path $TargetRoot $relative}else{$TargetRoot}
    $destinationPath=if($Destination){$Destination}else{$expected}
    if([IO.Path]::GetFullPath($expected) -ine [IO.Path]::GetFullPath($destinationPath)){throw 'Expected config destination differs from the reviewed target-relative artifact path.'}
    switch($Kind){
        Directory {
            $candidate=[IO.Path]::GetFullPath($Path).TrimEnd('\');$root=[IO.Path]::GetFullPath($TargetRoot).TrimEnd('\');$target=[IO.Path]::GetFullPath($expected).TrimEnd('\')
            if(($candidate -ine $root -and -not $candidate.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) -or ($target -ine $candidate -and -not $target.StartsWith($candidate+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Target directory exception is outside the reviewed root or is not an ancestor of the approved config artifact.'}
            Assert-WsmAssistiveFileTopology -Path $Path -ExactConfig -SourceRoot $TargetRoot -RelativePath $configForTopology
            Assert-WsmFileScopeGuard -Path (Get-WsmPhysicalPath $Path) -Mode ExactConfig -SourceRoot (Get-WsmPhysicalPath $TargetRoot) -RelativePath $configForTopology -IsDirectory -CheckPhysicalAlias
        }
        File {
            if([IO.Path]::GetFullPath($Path) -ine [IO.Path]::GetFullPath($expected)){throw 'Target file exception is not the exact reviewed config destination.'}
            Assert-WsmAssistiveFileTopology -Path $Path -ExactConfig -SourceRoot $TargetRoot -RelativePath $relative
            Assert-WsmFileScopeGuard -Path (Get-WsmPhysicalPath $Path) -Mode ExactConfig -SourceRoot (Get-WsmPhysicalPath $TargetRoot) -RelativePath $relative -CheckPhysicalAlias
            if([IO.File]::Exists($Path)){$actual=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant();if($actual -ine [string]$Artifact.Data.Hash -and (-not $TrustedExistingHash -or $actual -ine $TrustedExistingHash)){throw 'Existing target config bytes are neither the approved artifact nor the durably owned prior version.'}}
        }
        Staging {
            $dest=[IO.Path]::GetFullPath($expected);$stage=[IO.Path]::GetFullPath($Path)
            if($stage -notmatch ('^'+[regex]::Escape($dest)+'\.wsm-[a-f0-9]{32}\.tmp$')){throw 'Staging file is not the operation-generated sibling of the exact approved destination.'}
            Assert-WsmAssistiveFileTopology -Path $Path -ExactConfig -SourceRoot $TargetRoot -RelativePath $relative
            Assert-WsmFileScopeGuard -Path (Get-WsmPhysicalPath $Path) -Mode ExactConfig -SourceRoot (Get-WsmPhysicalPath $TargetRoot) -RelativePath $relative -CheckPhysicalAlias
            if([IO.File]::Exists($Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine [string]$Artifact.Data.Hash){throw 'Staged config bytes differ from the exact approved artifact.'}
        }
        Backup {
            $dest=[IO.Path]::GetFullPath($expected);$backup=[IO.Path]::GetFullPath($Path);$itemPrefix=[string]$Artifact.ItemId
            if(-not $TrustedExistingHash -or $TrustedExistingHash -notmatch '^[a-fA-F0-9]{64}$' -or $backup -notmatch ('^'+[regex]::Escape($dest)+'\.wsm-assistive-backup-'+[regex]::Escape($itemPrefix.Substring(0,12))+'-[a-f0-9]{32}$')){throw 'Backup file is not the operation-generated sibling of the exact approved config destination.'}
            Assert-WsmAssistiveFileTopology -Path $Path -ExactConfig -SourceRoot $TargetRoot -RelativePath $relative
            Assert-WsmFileScopeGuard -Path (Get-WsmPhysicalPath $Path) -Mode ExactConfig -SourceRoot (Get-WsmPhysicalPath $TargetRoot) -RelativePath $relative -CheckPhysicalAlias
            if([IO.File]::Exists($Path) -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $TrustedExistingHash){throw 'Backup bytes differ from the durably owned prior file hash.'}
        }
    }
}

# 預覽列的顯示專用欄位：檔數、位元組、缺少的必要相依、是否已還原過。它們由已驗證封裝與目前狀態推得，不是核對依據；
# 預覽雜湊與逐列雜湊一律先移除這些欄位，所以既有續作的漂移容忍與重綁判定、以及升級前留下的雜湊都不受影響。
function Remove-WsmAssistivePreviewDisplayFields($Row) {
    if($null -eq $Row){return $null}
    $names=@('FileCount','Bytes','MissingDependencies','AlreadyRestored','UncResponsibility','AdoptedFileCount','AdoptedBytes','ConflictFileCount','ConflictBytes')
    $present=$false;foreach($name in $names){if($Row.PSObject.Properties[$name]){$present=$true;break}}
    if(-not $present){return $Row}
    $Row|Select-Object -Property * -ExcludeProperty $names
}
function Add-WsmAssistivePreviewDisplayFields($Row,$Item,[hashtable]$Totals,[hashtable]$Selected,[hashtable]$PlanItems,[hashtable]$Restored) {
    $itemId=[string]$Item.ItemId;$files=[long]0;$bytes=[long]0
    if($Totals.ContainsKey($itemId)){$files=[long]$Totals[$itemId].Files;$bytes=[long]$Totals[$itemId].Bytes}
    $missing=New-Object 'System.Collections.Generic.List[string]'
    if($Item.PSObject.Properties['Dependencies']){
        foreach($dependency in @($Item.Dependencies)){
            if(-not $dependency -or [string]$dependency.Type -cne 'Mandatory'){continue}
            $dependencyId=[string]$dependency.ItemId
            if(-not $dependencyId -or $dependencyId -ceq $itemId -or -not $PlanItems.ContainsKey($dependencyId)){continue}
            $dependencyItem=$PlanItems[$dependencyId];if($dependencyItem.PSObject.Properties['Decision'] -and [string]$dependencyItem.Decision -cne 'Include'){continue}
            if($Selected.ContainsKey($dependencyId) -or $Restored.ContainsKey($dependencyId) -or $missing.Contains($dependencyId)){continue}
            $missing.Add($dependencyId)
        }
    }
    $Row|Add-Member NoteProperty FileCount $files
    $Row|Add-Member NoteProperty Bytes $bytes
    $Row|Add-Member NoteProperty MissingDependencies ([string[]]@($missing.ToArray()))
    $Row|Add-Member NoteProperty AlreadyRestored ([bool]$Restored.ContainsKey($itemId))
    # Q2: UNC 項目明列責任分類（沿用外部共享／另行遷移）；純顯示欄位，不進預覽雜湊，也不改變任何還原動作。
    $unc=Get-WsmItemUncResponsibility $Item;if($unc){$Row|Add-Member NoteProperty UncResponsibility $unc}
}

function Test-WsmAssistivePlanContractV2($Plan) {
    # N9h-D4: the single judgement of "this plan is OfflineFullSet contract version 2". The preview and the executor must both use it:
    # in a CV2 plan a NonC-labelled FileScope is written by the CV2 FileScope writer (original location, volume binding, ownership), never by the legacy NonC branch.
    [bool]($Plan -and $Plan.PSObject.Properties['Assistive'] -and $Plan.Assistive -and $Plan.Assistive.PSObject.Properties['ContractVersion'] -and [int]$Plan.Assistive.ContractVersion -eq 2)
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
    # 顯示專用的數量與相依：數量只取自已驗證封裝的 artifacts.jsonl（目錄列不計檔也不計位元組）；相依只認封裝計畫內的必要相依。
    $artifactTotals=@{}
    if($package.PSObject.Properties['Root'] -and $package.Manifest.PSObject.Properties['ArtifactsHash']){Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash $CancellationToken | ForEach-Object {
        $totalId=[string]$_.ItemId;if(-not $artifactTotals.ContainsKey($totalId)){$artifactTotals[$totalId]=[pscustomobject]@{Files=[long]0;Bytes=[long]0}}
        if(-not [bool]$_.Directory){$artifactTotals[$totalId].Files++;if($_.PSObject.Properties['Data'] -and $_.Data -and $_.Data.PSObject.Properties['Bytes']){$artifactTotals[$totalId].Bytes+=[long]$_.Data.Bytes}}
    }}
    $planItemsById=@{};foreach($planItem in @($package.Plan.Items)){$planItemsById[[string]$planItem.ItemId]=$planItem}
    # B6（R26-B6）：「已還原」只有一個判定（Get-WsmAssistiveRestoredItemIdSet；Target 選項的容量判定也呼叫它）。已還原項目不計入同磁碟的容量加總。
    $restoredIds=Get-WsmAssistiveRestoredItemIdSet $state $ExpectedHash
    # 會寫入的 FileScope 項目先登記（所在卷、所需位元組），迴圈結束後依卷加總再比對一次容量。
    $capacityCandidates=New-Object 'System.Collections.Generic.List[object]'
    # Q3：已驗證封裝的匯入資料夾就在新機 WorkRoot（journal、狀態也在其下的 pairs），以它所在磁碟代表 workspace 磁碟。
    $workspaceRoot='';if($package.PSObject.Properties['Root'] -and $package.Root){$workspaceRoot=[string]$package.Root}
    foreach($item in @($package.Plan.Items)){
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveRestorePreviewItem'
        if(-not $selected.ContainsKey([string]$item.ItemId)){$deferredRow=[pscustomobject]@{ItemId=$item.ItemId;Adapter=$item.MigrationSpec.Adapter;Action='DeferredBySelection';Status='Deferred';Reason='This approved item was not selected in the current target decision receipt.'};Add-WsmAssistivePreviewDisplayFields $deferredRow $item $artifactTotals $selected $planItemsById $restoredIds;$deferredRow.MissingDependencies=[string[]]@();$rows.Add($deferredRow);continue}
        $spec=$item.MigrationSpec;$action='RestoreNow';$status='Ready';$reason='';$cv2=Test-WsmAssistivePlanContractV2 $package.Plan;$locationError='';$readiness=Get-WsmAssistiveWorkloadReadiness $item;$fileGap=$null
        if($decision.Receipt.Decision -eq 'WaitForInstall'){$action='WaitForInstall';$status='DeferredSoftware';$reason='Owner chose to wait for target preparation; no target writes will occur.'}
        elseif($readiness.Status -ne 'Ready'){$action=$readiness.Status;$status=$readiness.Status;$reason=$readiness.Reason}
        else{
            $itemIssues=@(Get-WsmAssistiveItemDependencyIssues $issues ([string]$item.ItemId))
            if($itemIssues.Count -and @($decision.Receipt.AcceptedUnpreparedItemIds | Where-Object {$_ -ceq $item.ItemId}).Count -eq 0){$action='DeferredSoftware';$status='DeferredSoftware';$reason=(@($itemIssues | ForEach-Object Issue | Select-Object -Unique) -join '; ')}
            elseif($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'External'){$action='ExternalManual';$status='ManualEvidenceRequired';$reason='This selected workload depends on an external/non-C location; retain the source reference and complete the reviewed owner-managed transfer/readback procedure.'}
            elseif($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC' -and -not $cv2){$action='DeferredNonC';$status='Deferred';$reason='Required non-C content must have a current trusted D result and live readback before G can mark the workload complete.';if($nonCError){$reason='D evidence validation/readback remains incomplete: '+$nonCError};if($nonCRows.ContainsKey([string]$item.ItemId)){$nonc=$nonCRows[[string]$item.ItemId];$status=[string]$nonc.Status;$reason=[string]$nonc.Reason;if($status -ceq 'Ready'){$action='AcceptVerifiedNonC';$reason='D result is bound to the final package and every required native target file/directory has verified live readback.'}else{$action='DeferredNonC'}}}
            elseif($spec.Adapter -eq 'FileScope'){
                $fileGap=Get-WsmAssistiveFileScopeRestoreGap $item $package $state $cv2 $null $CancellationToken ([bool]$restoredIds.ContainsKey([string]$item.ItemId))
                $action=$fileGap.Action;$status=$fileGap.Status;$reason=$fileGap.Reason
                if($fileGap.Capacity){$capacityCandidates.Add($fileGap.Capacity)}
            }elseif($spec.Adapter -in @('IISSection','IISLocation')){
                try{Assert-WsmAssistiveIisConfigSpec $spec;$existing=Get-WsmIisConfigState $spec;$prior=@($state.Items | Where-Object ItemId -CEQ $item.ItemId);if(-not $existing.Exists){$action='BlockedConflict';$status='BlockedConflict';$reason='Reviewed IIS section/location is unavailable on the target.'}elseif($prior.Count -and ($prior[0].CreatedByTool -or ($prior[0].PSObject.Properties['UpdatedByTool'] -and $prior[0].UpdatedByTool)) -and $prior[0].AppliedManifestHash -and $prior[0].Status -in @('Succeeded','Partial')){$ownedCheck=Test-WsmAdapterConfiguration $spec Staged;if(-not $ownedCheck.Passed){$action='BlockedConflict';$status='BlockedConflict';$reason='Previously owned IIS section/location drifted from the exact staged configuration.'}else{$action='VerifyOwnedIisConfig'}}else{$candidate=Set-WsmIisConfigChanges (Read-WsmXml ([string]$existing.Xml)) @($spec.Desired.Changes);$desired=Read-WsmXml ([string]$spec.Desired.Xml);if((ConvertTo-WsmXmlComparable $candidate.DocumentElement) -cne (ConvertTo-WsmXmlComparable $desired.DocumentElement)){throw 'Reviewed IIS field changes do not produce the exact staged Desired.Xml.'};$action='ApplyReviewedIisChanges'}}catch{$action='BlockedConflict';$status='BlockedConflict';$reason=$_.Exception.Message}
            }else{
                if($spec.PSObject.Properties['SettingTransition']){Assert-WsmSettingTransition $spec.SettingTransition | Out-Null;$intent=Get-WsmSettingTransitionIntent $spec.SettingTransition $package.Manifest.Target.Fingerprint;$action='ApplySettingTransition';if($spec.SettingTransition.RequiredPhase -eq 'CutoverReady'){$reason='Reviewed setting is applied and read back during isolated staging; its external dependency gate remains due before activation.'}}
                else{
                foreach($command in (Get-WsmAdapterRequiredCommands $spec.Adapter)){if(-not (Get-Command $command -ErrorAction SilentlyContinue)){$action='DeferredSoftware';$status='DeferredSoftware';$reason=('Required target dependency is unavailable: '+$command);break}}
                if($status -eq 'Ready'){
                    try{$existing=Get-WsmAdapterState $spec;$prior=@($state.Items | Where-Object ItemId -CEQ $item.ItemId);$priorCreated=($prior.Count -and $prior[0].CreatedByTool -and $prior[0].AppliedManifestHash -and $prior[0].Status -in @('Succeeded','Partial','RebootRequired'));if($existing.Exists -and $spec.Adapter -ceq 'WindowsFeature' -and -not $priorCreated){if([string]$existing.Name -ine [string]$spec.Desired.Name){throw 'Installed Windows feature name differs from the exact approved feature.'};$action='VerifyExistingFeature';$reason='The exact approved Windows feature is already installed; verify it without claiming installer or rollback ownership.'}elseif($existing.Exists -and -not $priorCreated){$action='BlockedConflict';$status='BlockedConflict';$reason='Existing target object is not owned by an exact prior Assistive generation.'};if($existing.Exists -and $prior.Count -and $prior[0].Status -eq 'RebootRequired'){if($spec.Adapter -cne 'WindowsFeature'){throw 'Only a WindowsFeature result may require a reviewed reboot before retry.'};Assert-WsmRebootCompleted $prior[0]}}
                    catch{$action='DeferredSoftware';$status='DeferredSoftware';$reason=('Native target preflight unavailable: '+$_.Exception.GetType().FullName)}
                }
                }
            }
        }
        if($spec.PSObject.Properties['SharedResourceImpacts']){foreach($impact in @($spec.SharedResourceImpacts | Where-Object RequiresSharedReview)){$problems.Add([pscustomobject]@{ItemId=$item.ItemId;Reason=('Shared resource reservation/review required: '+$impact.ResourceKind+' '+$impact.ResourceItemId)})}}
        if($status -in @('Blocked','BlockedConflict')){$problems.Add([pscustomobject]@{ItemId=$item.ItemId;Reason=$reason})}
        $previewRow=[pscustomobject]@{ItemId=$item.ItemId;Name=$item.Name;Adapter=$spec.Adapter;Action=$action;Status=$status;Reason=$reason;Rollback='Per-item journal; exact owned state only';RebootPossible=($spec.Adapter -eq 'WindowsFeature')};$previewCredential=$null;if([string]$spec.Adapter -cin @('Service','ScheduledTask','IISPool')){try{$previewCredential=Get-WsmAdapterCredentialRequirement $spec}catch{$previewCredential=$null}};if($previewCredential){$previewRow|Add-Member NoteProperty CredentialRequired $true;$previewRow|Add-Member NoteProperty CredentialKind ([string]$previewCredential.Kind)};Add-WsmAssistivePreviewDisplayFields $previewRow $item $artifactTotals $selected $planItemsById $restoredIds;Add-WsmAssistiveFileDispositionDisplayFields $previewRow $fileGap;$rows.Add($previewRow)
    }
    # 容量依目標卷加總：同一磁碟上所有會寫入的已選項目合計後只比對一次（舊流程 Restore.ps1 亦先依磁碟根加總）。
    # Q3：寫入、另磁碟的 staging、回復保留各自計入「實際占用的磁碟」；B6：已還原項目不計入合計，單項過大只擋該項。
    # 單看各項都夠、合計不夠時，該卷上所有會寫入的項目一律標 AddTargetCapacity。
    foreach($volumeResult in @(Get-WsmAssistiveVolumeCapacityResults $capacityCandidates.ToArray() $workspaceRoot)){
        $volumeRow=@($rows.ToArray() | Where-Object {[string]$_.ItemId -ceq [string]$volumeResult.ItemId})
        if($volumeRow.Count -ne 1){continue}
        if($volumeResult.Error){$volumeRow[0].Action='Blocked';$volumeRow[0].Status='Blocked';$volumeRow[0].Reason='Target path could not be verified safely.';$problems.Add([pscustomobject]@{ItemId=$volumeResult.ItemId;Reason=$volumeRow[0].Reason})}
        else{$volumeRow[0].Action=$volumeResult.Action;$volumeRow[0].Status=$volumeResult.Status;$volumeRow[0].Reason=$volumeResult.Reason}
    }
    $decisionBlocked=($decision.Receipt.Decision -eq 'RestoreNow' -and -not $decision.Snapshot)
    if($decisionBlocked){$problems.Add([pscustomobject]@{ItemId='';Reason='Target decision receipt requires a trusted target snapshot file.'})}
    $nonCFileResults=@(foreach($itemId in $nonCRows.Keys){foreach($fileResult in @($nonCRows[$itemId].FileResults)){$fileResult}})
    # 預計寫入量：只加總實際會寫入的列（Ready 且不是只核對的動作）；其他列不計。R3：每列再扣掉不會寫入的檔案（沿用既有檔 AdoptedFileCount、衝突檔 ConflictFileCount），數量見 Get-WsmAssistivePlannedWriteAmount。
    $plannedFileCount=[long]0;$plannedBytes=[long]0
    foreach($plannedRow in $rows.ToArray()){if($plannedRow.PSObject.Properties['FileCount'] -and [string]$plannedRow.Status -ceq 'Ready' -and [string]$plannedRow.Action -notlike 'Verify*'){$plannedAmount=Get-WsmAssistivePlannedWriteAmount $plannedRow;$plannedFileCount+=[long]$plannedAmount.Files;$plannedBytes+=[long]$plannedAmount.Bytes}}
    [pscustomobject]@{PairId=$package.Manifest.PairId;ManifestHash=$ExpectedHash;Generation=$package.Manifest.Generation;PlanHash=$package.Manifest.PlanHash;Mode='AssistivePerItem';ScopeMode='Assistive';Decision=$decision.Receipt.Decision;DecisionReceiptHash=$decision.ReceiptHash;SelectedItemIds=@($decision.SelectedItemIds);Rows=$rows.ToArray();PlannedFileCount=$plannedFileCount;PlannedBytes=$plannedBytes;NonCFileResults=$nonCFileResults;Problems=$problems.ToArray();GeneralHostIssues=$issues;NonCTransferPlanPath=$NonCTransferPlanPath;NonCTransferPlanHash=$NonCTransferPlanHash;NonCResultPath=$NonCResultPath;NonCResultHash=$NonCResultHash;NonCEvidenceIssue=$nonCError;Blocked=($decisionBlocked -or @($rows | Where-Object Status -EQ 'Blocked').Count -gt 0);CanRestoreIndependentItems=(@($rows | Where-Object Status -EQ 'Ready').Count -gt 0);NoOp=($rows.Count -eq 0);BusinessValidationRequired=$true;ProductionVerified=$false}
}

function Get-WsmAssistiveTargetVolumeKey([string]$TargetPath) {
    # 加總鍵：目標所在卷。含掛載點的目標已先被 MountPointNotSupported 擋下，所以此處磁碟根即實際所在卷；不分大小寫。
    ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($TargetPath))).ToUpperInvariant()
}
function Get-WsmAssistiveTargetMissingVolumeGap([string]$TargetPath) {
    $root=[IO.Path]::GetPathRoot($TargetPath)
    if(-not [IO.Directory]::Exists($root)){return [pscustomobject]@{Action='PrepareSameLocation';Status='Deferred';Reason=('目標主機缺少 '+$root+' 磁碟或掛載點；請準備相同位置後重新檢查。工具不會改寫到其他磁碟。')}}
    return $null
}
function Get-WsmAssistiveCapacityRequiredBytes([long]$WriteBytes,[long]$StagingBytes=0,[long]$RecoveryBytes=0) {
    # Q3：容量需求的唯一算式＝原位置寫入＋「另一個磁碟上」的 staging＋回復保留，再加 256 MiB 緩衝。
    # 預覽、Target 選項（可還原集合）與單項檢查（Get-WsmAssistiveVolumeCapacityGap）都經這個函式，沒有第二份。
    [long]($WriteBytes + $StagingBytes + $RecoveryBytes + 256MB)
}
function Get-WsmAssistiveStagingLocation([string]$TargetPath) {
    # Q3：還原寫入前的 staging 檔放在哪個磁碟的觀測縫。
    # 正式行為（Invoke-WsmAssistiveFileScopeRestore 的 $staging＝$dest+'.wsm-<guid>.tmp'；Restore-WsmPayloadBytes 先寫 <guid>.partial 再改名成它）是
    # 與目的檔同目錄的兄弟檔，所以恆在目的地所在磁碟；它以改名（非複製）成為最終檔，空間已含在寫入量內，同磁碟時不重複計。
    # 若 staging 改放到別的磁碟，Get-WsmAssistiveCapacityPieces 會把「單一最大檔」另計到該磁碟。
    [pscustomobject]@{Root=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($TargetPath));Key=(Get-WsmAssistiveTargetVolumeKey $TargetPath)}
}
function Get-WsmAssistiveRecoveryReserveBytes([long]$FileCount) {
    # Q3：必要回復空間。覆寫既有檔時舊檔以改名（同目錄 .wsm-assistive-backup-*）保留，不另占空間（Invoke-WsmAssistiveFileScopeRestore 的 [IO.File]::Move），
    # 回復（Complete-WsmAssistiveFileRollback）也只是改名，所以不計舊檔位元組；真正需要的是 journal（意圖／已備份／完成）、
    # 暫止意圖與每檔擁有紀錄（含 metadata／SDDL）、狀態檔改寫所需的空間，寫在 workspace 所在磁碟。
    # 每個會寫入的檔案固定預留 16 KiB（約為 4 筆 journal 與 1 筆擁有紀錄的實測量級的數倍，偏保守）。
    if($FileCount -le 0){return [long]0}
    [long]($FileCount * 16KB)
}
function Format-WsmAssistiveMiB([long]$Bytes) {
    if($Bytes -le 0){return '0'}
    if($Bytes -lt 1MB){return '不到 1'}
    [string][math]::Ceiling($Bytes/1MB)
}
function Get-WsmAssistiveCapacityBreakdownText([long]$WriteBytes,[long]$StagingBytes,[long]$RecoveryBytes) {
    # 原因文字用：寫明這一次計入了哪些項目。
    ('寫入 '+(Format-WsmAssistiveMiB $WriteBytes)+' MiB（含同磁碟的 staging：staging 檔以改名成為最終檔）、另一個磁碟上的 staging '+(Format-WsmAssistiveMiB $StagingBytes)+' MiB、回復保留（journal、狀態與回復紀錄）'+(Format-WsmAssistiveMiB $RecoveryBytes)+' MiB，另加 256 MiB 緩衝')
}
function Get-WsmAssistiveRestoredItemIdSet($State,[string]$ManifestHash) {
    # B6（R26-B6）：「已還原」的唯一判定。預覽（Get-WsmAssistiveRestorePreview）與 Target 選項的容量判定（Get-WsmWizardTargetRestorableGaps）共用。
    # 已還原＝狀態紀錄 Succeeded、套用的是目前這份封裝（AppliedManifestHash），且沒有未解決的暫止意圖。
    $restored=@{}
    if($null -eq $State -or -not $State.PSObject.Properties['Items']){return $restored}
    $pendingIds=@{};if($State.PSObject.Properties['PendingOperations']){foreach($pendingOp in @($State.PendingOperations)){if($pendingOp -and $pendingOp.PSObject.Properties['ItemId']){$pendingIds[[string]$pendingOp.ItemId]=$true}}}
    foreach($stateItem in @($State.Items)){if($stateItem -and $stateItem.PSObject.Properties['ItemId'] -and [string]$stateItem.Status -ceq 'Succeeded' -and $stateItem.PSObject.Properties['AppliedManifestHash'] -and [string]$stateItem.AppliedManifestHash -ieq $ManifestHash -and -not $pendingIds.ContainsKey([string]$stateItem.ItemId)){$restored[[string]$stateItem.ItemId]=$true}}
    $restored
}
function Get-WsmAssistiveVolumeCapacityGap([string]$Root,[long]$TotalBytes) {
    # 預覽與單項檢查共用的容量判定：該卷可用空間必須大於同卷已選項目合計需求加 256 MiB 緩衝（算式見 Get-WsmAssistiveCapacityRequiredBytes）。
    # 另帶出卷代號與需要量／可用量（只供可還原集合顯示；預覽列的 Reason 文字不變）。
    $available=[long](Get-WsmAvailableBytes $Root)
    $required=Get-WsmAssistiveCapacityRequiredBytes $TotalBytes
    if($available -lt $required){return [pscustomobject]@{Action='AddTargetCapacity';Status='Deferred';Reason=('目標磁碟 '+$Root+' 可用空間不足（同一磁碟上已選項目合計約 '+[math]::Ceiling($TotalBytes/1MB)+' MiB）；請釋出空間後重新檢查。');Root=$Root;RequiredBytes=$required;AvailableBytes=$available}}
    return $null
}
function Get-WsmAssistiveTargetLocationGap([string]$TargetPath,[long]$RequiredBytes) {
    $missing=Get-WsmAssistiveTargetMissingVolumeGap $TargetPath;if($missing){return $missing}
    Get-WsmAssistiveVolumeCapacityGap ([IO.Path]::GetPathRoot($TargetPath)) $RequiredBytes
}
function Get-WsmAssistiveBackupMediaOverlapReason([string]$TargetPath,$Package) {
    # N5（15.5-6）：備份媒體（已驗證封裝的匯入資料夾）與還原目的範圍不得相同、互相包含；否則還原會寫入或覆蓋備份本身。
    # 預覽、可還原集合共用這個判定（寫在 Get-WsmAssistiveFileScopeRestoreGap 內），寫入端另用同一函式再擋一次。
    # 先比邏輯路徑（不分大小寫），再比實體路徑（subst、junction 之類的別名）；任何一步無法驗證就丟出例外，由呼叫端以保守方向處理。
    # 沒有封裝資料夾資訊時沒有可比對的對象，回傳空字串。
    if($null -eq $Package -or -not $Package.PSObject.Properties['Root'] -or [string]::IsNullOrWhiteSpace([string]$Package.Root)){return ''}
    $media=[IO.Path]::GetFullPath([string]$Package.Root).TrimEnd('\');$target=[IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
    $overlap=(Test-WsmPathOverlap $target $media)
    if(-not $overlap){$overlap=(Test-WsmPathOverlap (Get-WsmPhysicalPath $target) (Get-WsmPhysicalPath $media))}
    if($overlap){return ('備份媒體（匯入的封裝資料夾 '+$media+'）與還原目的範圍 '+$target+' 重疊；還原會寫入或覆蓋備份本身，工具不會還原。請把備份集放到還原範圍之外的位置後重新匯入。')}
    ''
}
function Test-WsmAssistiveFileScopeOwnershipIncomplete($State,[string]$ItemId) {
    # P9：先前 FileScope 紀錄的 ownership 是否不完整。寫入器的拒絕（Invoke-WsmAssistiveFileScopeRestore）與 N1 的共用可還原判定
    # （Get-WsmAssistiveFileScopeRestoreGap，預覽與 Target 項目選項都走它）都呼叫這一個函式，條件只有這一份。
    # 沒有先前紀錄＝沒有東西要對帳，視為完整。不完整＝有先前紀錄，但不是剛好一筆、沒有 OwnedFiles，
    # 或帶著上次對帳尚未解決的衝突（ReconcileConflicts；由 Repair 的 FileScope 對帳寫入）。
    if($null -eq $State -or -not $State.PSObject.Properties['Items']){return $false}
    $prior=@($State.Items | Where-Object ItemId -CEQ $ItemId)
    if(-not $prior.Count){return $false}
    if($prior.Count -ne 1 -or -not $prior[0].PSObject.Properties['OwnedFiles']){return $true}
    if($prior[0].PSObject.Properties['ReconcileConflicts'] -and @($prior[0].ReconcileConflicts).Count){return $true}
    $false
}
function Get-WsmAssistiveFileScopeRestoreGap($Item,$Package,$State,[bool]$ContractV2,$ArtifactRows=$null,$CancellationToken=$null,[bool]$AlreadyRestored=$false) {
    # 預覽與「可還原集合」共用的 FileScope 判定：原位置、封裝內容、掛載點、缺卷、既有目標衝突、可寫入性與（單項）容量需求。
    # 全程唯讀：不建目錄、不寫檔、不取鎖。回傳 Action／Status／Reason，以及會寫入時的容量候選（Capacity；由呼叫端依卷加總）。
    $spec=$Item.MigrationSpec;$action='RestoreNow';$status='Ready';$reason='';$capacity=$null
    $adoptedFiles=[long]0;$adoptedBytes=[long]0;$conflictFiles=[long]0;$conflictBytes=[long]0;$differentFiles=[long]0;$writeFileCount=[long]0;$largestFileBytes=[long]0
    if($ContractV2){$locationError=$(try{Assert-WsmOfflineFullSetOriginalLocation $Package.Plan $spec;''}catch{$_.Exception.Message});if($locationError){return [pscustomobject]@{Action='BlockedLocation';Status='Blocked';Reason=$locationError;Capacity=$null}}}
    if(Test-WsmAssistiveFileScopeOwnershipIncomplete $State ([string]$Item.ItemId)){return [pscustomobject]@{Action='NeedsReconciliation';Status='Blocked';Reason='Prior schema 3 FileScope ownership data is incomplete; reconcile it with the Repair operation before retrying.';Capacity=$null}}
    $target=ConvertTo-WsmCanonicalPath $spec.TargetPath
    try{
        if($null -ne $ArtifactRows){$artifactRows=@($ArtifactRows)}else{$artifactRows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash $CancellationToken | Where-Object ItemId -CEQ $item.ItemId)};if(-not $artifactRows.Count){return [pscustomobject]@{Action='NoPayload';Status='Blocked';Reason='封裝中沒有這個核准項目的備份內容（缺少 artifact），工具不會還原。';Capacity=$null}};$singleFileScope=($artifactRows.Count -eq 1 -and -not $artifactRows[0].Directory -and [string]::IsNullOrEmpty([string]$artifactRows[0].RelativePath));$requiredBytes=[long]0;foreach($row in @($artifactRows | Where-Object {-not $_.Directory})){if($row.PSObject.Properties['Data'] -and $row.Data -and $row.Data.PSObject.Properties['Bytes']){$requiredBytes+=[long]$row.Data.Bytes}};$mountPoint=Get-WsmAssistiveMountPointAncestor $target;if($mountPoint){$gap=[pscustomobject]@{Action='MountPointNotSupported';Status='Blocked';Reason=('目標路徑位於另一個掛載點（'+$mountPoint+'），工具不會寫入掛載點底下；請改用相同位置的一般目錄或另行處理。')}}else{$gap=Get-WsmAssistiveTargetMissingVolumeGap $target}
        if(-not $gap){$mediaReason=Get-WsmAssistiveBackupMediaOverlapReason $target $Package;if($mediaReason){$gap=[pscustomobject]@{Action='BackupMediaOverlap';Status='Blocked';Reason=$mediaReason}}}
        if($gap){$action=$gap.Action;$status=$gap.Status;$reason=$gap.Reason}else{
        Assert-WsmNoReparse $target
        Assert-WsmAssistiveTargetScopeTopology -Path $target -Spec $spec -TargetRoot $target -Kind Root
        # R3：逐檔判定。目標已存在的每個檔案都走 Get-WsmAssistiveExistingFileDisposition（寫入器、Repair 也呼叫同一個函式）：
        #   Adopt／OwnedAdopted＝沿用既有檔（不寫入）、ConflictDifferent／Directory＝衝突（整個項目 BlockedConflict）、其餘維持既有行為。目錄範圍才逐檔判衝突；單檔範圍維持下方原有判定。
        $priorForFiles=@();if($null -ne $state -and $state.PSObject.Properties['Items']){$priorForFiles=@($state.Items|Where-Object ItemId -CEQ $item.ItemId)}
        foreach($artifact in $artifactRows){$artifactTarget=$target;if(-not $singleFileScope -and $artifact.RelativePath){$artifactTarget=Join-Path $target ([string]$artifact.RelativePath)};if([IO.File]::Exists($artifactTarget) -or [IO.Directory]::Exists($artifactTarget)){if($artifact.Directory){Assert-WsmAssistiveTargetScopeTopology -Path $artifactTarget -Spec $spec -TargetRoot $target -Artifact $artifact -Kind Directory -Destination $artifactTarget}else{
            $artifactOwner=$null;if($priorForFiles.Count -eq 1 -and $priorForFiles[0].PSObject.Properties['OwnedFiles']){$ownerRows=@($priorForFiles[0].OwnedFiles|Where-Object {[string]$_.RelativePath -ceq [string]$artifact.RelativePath});if($ownerRows.Count -gt 1){throw 'Duplicate per-file ownership record.'};if($ownerRows.Count -eq 1){$artifactOwner=$ownerRows[0]}}
            $fileDisposition=Get-WsmAssistiveExistingFileDisposition $spec $target $artifact $artifactTarget $artifactOwner (-not $singleFileScope)
            $dispositionBytes=[long]0;if($artifact.PSObject.Properties['Data'] -and $artifact.Data -and $artifact.Data.PSObject.Properties['Bytes']){$dispositionBytes=[long]$artifact.Data.Bytes}
            switch -CaseSensitive ([string]$fileDisposition.Disposition){
                'ConflictUnverifiable' {throw [string]$fileDisposition.Reason}
                'Directory' {if(-not $singleFileScope){$conflictFiles++;$conflictBytes+=$dispositionBytes}}
                'ConflictDifferent' {$conflictFiles++;$differentFiles++;$conflictBytes+=$dispositionBytes}
                'Adopt' {$adoptedFiles++;$adoptedBytes+=$dispositionBytes}
                'OwnedAdopted' {$adoptedFiles++;$adoptedBytes+=$dispositionBytes}
            }
        }}}
        $requiredBytes=[Math]::Max([long]0,[long]($requiredBytes-$adoptedBytes))
        # Q3：回復保留依「會寫入的檔案數」預留；staging 以單一最大檔計（逐檔進行，同時只有一個 staging 檔）。
        $payloadRows=@($artifactRows|Where-Object {-not $_.Directory});$writeFileCount=[Math]::Max([long]0,[long]($payloadRows.Count-$adoptedFiles))
        foreach($payloadRow in $payloadRows){if($payloadRow.PSObject.Properties['Data'] -and $payloadRow.Data -and $payloadRow.Data.PSObject.Properties['Bytes'] -and [long]$payloadRow.Data.Bytes -gt $largestFileBytes){$largestFileBytes=[long]$payloadRow.Data.Bytes}}
        # R2：先前有擁有紀錄、但目標檔現在不存在，N1 與寫入器判定相同（Test-WsmAssistiveOwnedFileAbsentConflict）：BlockedConflict，不說 Ready。
        $absentOwnedFiles=@();$priorForAbsent=@();if($null -ne $state -and $state.PSObject.Properties['Items']){$priorForAbsent=@($state.Items|Where-Object ItemId -CEQ $item.ItemId)}
        if($priorForAbsent.Count -eq 1 -and $priorForAbsent[0].PSObject.Properties['OwnedFiles']){foreach($artifact in @($artifactRows|Where-Object {-not $_.Directory})){$artifactTarget=$target;if(-not $singleFileScope -and $artifact.RelativePath){$artifactTarget=Join-Path $target ([string]$artifact.RelativePath)};$artifactOwners=@($priorForAbsent[0].OwnedFiles|Where-Object {[string]$_.RelativePath -ceq [string]$artifact.RelativePath});$artifactOwner=$null;if($artifactOwners.Count -ge 1){$artifactOwner=$artifactOwners[0]};if(Test-WsmAssistiveOwnedFileAbsentConflict $artifactOwner ([IO.File]::Exists($artifactTarget) -or [IO.Directory]::Exists($artifactTarget))){$absentOwnedFiles+=@([string]$artifact.RelativePath)}}}
        if($absentOwnedFiles.Count){$action='BlockedConflict';$status='BlockedConflict';$reason=(Get-WsmAssistiveOwnedFileAbsentReason)}
        elseif($conflictFiles -gt 0){$action='BlockedConflict';$status='BlockedConflict';$reason=$(if($differentFiles -gt 0){Get-WsmAssistiveDifferentContentConflictReason $differentFiles}else{'A directory occupies the required file path.'})}
        elseif($singleFileScope){
            if([IO.Directory]::Exists($target)){$action='BlockedConflict';$status='BlockedConflict';$reason='A directory occupies the approved single-file target.'}
            elseif([IO.File]::Exists($target)){$prior=@($state.Items|Where-Object ItemId -CEQ $item.ItemId);$owner=$null;if($prior.Count -eq 1 -and $prior[0].PSObject.Properties['OwnedFiles']){$matches=@($prior[0].OwnedFiles|Where-Object {$_.RelativePath -ceq '' -and $_.TargetPath -ieq $target});if($matches.Count -eq 1){$owner=$matches[0]}};$current=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant();if(-not $owner -or $current -ine [string]$owner.SHA256){$action='BlockedConflict';$status='BlockedConflict';$reason=$(if($owner -and (Test-WsmAssistiveOwnedFileAdopted $owner)){'Adopted existing single-file target changed after it was adopted; it is only reported and is never overwritten.'}else{'Existing single-file target is not owned by an exact prior generation.'})}elseif($owner -and (Test-WsmAssistiveOwnedFileAdopted $owner)){if($current -cne [string]$artifactRows[0].Data.Hash){$action='BlockedConflict';$status='BlockedConflict';$reason='Adopted existing single-file target differs from this package; it is preserved and never overwritten.'}else{$adoptedMetadata=Get-WsmFileMetadata $target ([string]$artifactRows[0].Metadata.MetadataMode);if((Get-WsmAssistiveMetadataHash $adoptedMetadata) -ine [string]$owner.MetadataHash){$action='BlockedConflict';$status='BlockedConflict';$reason='Adopted existing single-file target metadata changed after it was adopted; it is only reported and is never modified.'}else{$action='VerifyAdoptedExistingFile';$status='Ready';$reason=(Get-WsmAssistiveAdoptedExistingNote)}}}elseif($current -ceq [string]$artifactRows[0].Data.Hash){$map=Resolve-WsmIdentityMap $package.Plan @{};$aclPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$aclPolicy=[string]$spec.AclControlPolicy};[void](Assert-WsmAssistiveMetadataReadback $target $artifactRows[0].Metadata $map $aclPolicy);$action='VerifyOwnedSingleFile';$status='Ready';$reason='Exact owned single-file bytes and required metadata match the approved artifact.'}else{$action='ReplaceOwnedSingleFile';$status='Ready';$reason='Exact prior single-file ownership is verified; preserve a rollback copy before replacement.'}}
            else{$parent=[IO.Path]::GetDirectoryName($target);Assert-WsmNoReparse $parent;$action='CreateSingleFile';$status='Ready';$reason='Approved single-file target is absent; its parent directory will be retained or created without applying source-directory metadata.'}
        }elseif([IO.File]::Exists($target)){$action='BlockedConflict';$status='BlockedConflict';$reason='A file occupies the approved directory target.'}
        elseif([IO.Directory]::Exists($target)){$action='MergeIntoExistingDirectory';$status='Ready';$reason='Existing directories are retained; only new files and verified tool-owned unchanged files may be written.'}
        }
        if($status -ceq 'Ready' -and $action -cin @('CreateSingleFile','ReplaceOwnedSingleFile','MergeIntoExistingDirectory','RestoreNow')){
            $writeDirectory=Get-WsmAssistiveNearestExistingDirectory $target
            $needSubdirectories=($action -cin @('MergeIntoExistingDirectory','RestoreNow') -or [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($target))).TrimEnd('\') -ine $writeDirectory.TrimEnd('\'))
            if(-not (Test-WsmAssistiveDirectoryWritable $writeDirectory -Subdirectories:$needSubdirectories)){$action='PermissionDenied';$status='Deferred';$reason=('目前帳號無法寫入 '+$writeDirectory+'；請以具權限的帳號執行或調整權限後重新檢查。')}
            else{$stagingLocation=Get-WsmAssistiveStagingLocation $target;$capacity=[pscustomobject]@{ItemId=[string]$item.ItemId;Root=[IO.Path]::GetPathRoot($target);Key=(Get-WsmAssistiveTargetVolumeKey $target);Bytes=[long]$requiredBytes;FileCount=[long]$writeFileCount;StagingBytes=[long]$largestFileBytes;StagingRoot=[string]$stagingLocation.Root;StagingKey=[string]$stagingLocation.Key;Restored=[bool]$AlreadyRestored}}
        }
    }
    catch{$action='Blocked';$status='Blocked';$reason='Target path could not be verified safely.'}
    [pscustomobject]@{Action=$action;Status=$status;Reason=$reason;Capacity=$capacity;AdoptedFileCount=$adoptedFiles;AdoptedBytes=$adoptedBytes;ConflictFileCount=$conflictFiles;ConflictBytes=$conflictBytes}
}
function Get-WsmAssistiveCapacityPieces($Candidate,[string]$WorkspaceRoot='') {
    # Q3：一個候選項目對各磁碟的需求，依「實際占用空間的所在磁碟」拆開。
    #   寫入：目的地磁碟（原位置寫入的位元組）。
    #   staging：寫入前的 staging 檔；只有它不在目的地磁碟時才另計（單一最大檔，見 Get-WsmAssistiveStagingLocation 的說明）。
    #   回復保留：journal、狀態與回復紀錄，每個要寫入的檔案固定預留（Get-WsmAssistiveRecoveryReserveBytes）；寫在 workspace 所在磁碟，沒有 workspace 資訊時與寫入同磁碟。
    $key=[string]$Candidate.Key;$root=[string]$Candidate.Root
    $pieces=New-Object 'System.Collections.Generic.List[object]'
    $pieces.Add([pscustomobject]@{Key=$key;Root=$root;Write=[long]$Candidate.Bytes;Staging=[long]0;Recovery=[long]0;Primary=$true})
    if($Candidate.PSObject.Properties['StagingKey'] -and [string]$Candidate.StagingKey -and [string]$Candidate.StagingKey -cne $key){$pieces.Add([pscustomobject]@{Key=[string]$Candidate.StagingKey;Root=[string]$Candidate.StagingRoot;Write=[long]0;Staging=[long]$Candidate.StagingBytes;Recovery=[long]0;Primary=$false})}
    $reserve=[long]0;if($Candidate.PSObject.Properties['FileCount']){$reserve=[long](Get-WsmAssistiveRecoveryReserveBytes ([long]$Candidate.FileCount))}
    if($reserve -gt 0){
        $recoveryKey=$key;$recoveryRoot=$root
        if($WorkspaceRoot){$recoveryRoot=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($WorkspaceRoot));$recoveryKey=$recoveryRoot.ToUpperInvariant()}
        $pieces.Add([pscustomobject]@{Key=$recoveryKey;Root=$recoveryRoot;Write=[long]0;Staging=[long]0;Recovery=$reserve;Primary=$false})
    }
    $pieces.ToArray()
}
function Get-WsmAssistiveVolumeCapacityResults([object[]]$Candidates,[string]$WorkspaceRoot='') {
    # 容量依磁碟加總（預覽與可還原集合共用）：
    #  1. 逐項判定（B6）：單看一個項目（寫入＋staging＋回復保留）就超過該磁碟可用空間，只有該項 Deferred（Scope=Item），且不再計入合計。
    #  2. 合計判定：其餘待寫項目依磁碟加總後各比對一次；不夠（或無法驗證）時，該磁碟上每個待寫項目各回傳一列（Scope=Volume，原因附合計與計入項目）。
    #  已還原的項目（Restored）不寫入，不計入任何加總，也不被標成容量不足；原因文字另外提示它們被排除。
    # 每個磁碟只探測一次可用空間。
    $observedByKey=@{}
    $probe={param([string]$Key,[string]$Root)
        if(-not $observedByKey.ContainsKey($Key)){try{$observedByKey[$Key]=[pscustomobject]@{Available=[long](Get-WsmAvailableBytes $Root);Error=$false}}catch{$observedByKey[$Key]=[pscustomobject]@{Available=[long]-1;Error=$true}}}
        $observedByKey[$Key]
    }
    $all=@($Candidates|Where-Object {$null -ne $_})
    $pending=@($all|Where-Object {-not ($_.PSObject.Properties['Restored'] -and [bool]$_.Restored)})
    $restored=@($all|Where-Object {$_.PSObject.Properties['Restored'] -and [bool]$_.Restored})
    $survivors=New-Object 'System.Collections.Generic.List[object]'
    foreach($candidate in $pending){
        $pieces=@(Get-WsmAssistiveCapacityPieces $candidate $WorkspaceRoot);$short=$null
        foreach($group in @($pieces|Group-Object Key)){
            $groupPieces=@($group.Group);$write=[long]0;$staging=[long]0;$recovery=[long]0
            foreach($piece in $groupPieces){$write+=[long]$piece.Write;$staging+=[long]$piece.Staging;$recovery+=[long]$piece.Recovery}
            $observed=& $probe ([string]$group.Name) ([string]$groupPieces[0].Root)
            if($observed.Error){continue}
            $required=Get-WsmAssistiveCapacityRequiredBytes $write $staging $recovery
            if($observed.Available -lt $required){$short=[pscustomobject]@{Root=[string]$groupPieces[0].Root;Write=$write;Staging=$staging;Recovery=$recovery;Required=$required;Available=[long]$observed.Available};break}
        }
        if($short){
            [pscustomobject]@{ItemId=[string]$candidate.ItemId;Error=$false;Action='AddTargetCapacity';Status='Deferred';Reason=('目標磁碟 '+$short.Root+' 可用空間不足（這個項目單獨需要約 '+[math]::Round($short.Required/1MB)+' MiB（含 256 MiB 緩衝），目前可用約 '+[math]::Floor($short.Available/1MB)+' MiB；計入項目：'+(Get-WsmAssistiveCapacityBreakdownText $short.Write $short.Staging $short.Recovery)+'）；請釋出空間後重新檢查。');Root=$short.Root;RequiredBytes=$short.Required;AvailableBytes=$short.Available;Scope='Item';WriteBytes=$short.Write;StagingBytes=$short.Staging;RecoveryBytes=$short.Recovery;RestoredCount=0;RestoredBytes=[long]0}
            continue
        }
        $survivors.Add([pscustomobject]@{Candidate=$candidate;Pieces=$pieces})
    }
    $volumes=[ordered]@{}
    foreach($entry in $survivors.ToArray()){
        foreach($piece in @($entry.Pieces)){
            $volumeKey=[string]$piece.Key
            if(-not $volumes.Contains($volumeKey)){$volumes[$volumeKey]=[pscustomobject]@{Root=[string]$piece.Root;Write=[long]0;Staging=[long]0;Recovery=[long]0;Dest=(New-Object 'System.Collections.Generic.List[string]');Other=(New-Object 'System.Collections.Generic.List[string]');RestoredCount=0;RestoredBytes=[long]0}}
            $volume=$volumes[$volumeKey];$volume.Write+=[long]$piece.Write;$volume.Recovery+=[long]$piece.Recovery;if([long]$piece.Staging -gt $volume.Staging){$volume.Staging=[long]$piece.Staging}
            $memberId=[string]$entry.Candidate.ItemId
            if($piece.Primary){if(-not $volume.Dest.Contains($memberId)){$volume.Dest.Add($memberId)}}elseif(-not $volume.Other.Contains($memberId)){$volume.Other.Add($memberId)}
        }
    }
    foreach($restoredCandidate in $restored){$restoredKey=[string]$restoredCandidate.Key;if($volumes.Contains($restoredKey)){$volumes[$restoredKey].RestoredCount++;$volumes[$restoredKey].RestoredBytes+=[long]$restoredCandidate.Bytes}}
    foreach($volumeKey in @($volumes.Keys)){
        $volume=$volumes[$volumeKey]
        # 同磁碟「所有待寫項目」＝寫入目的地在這個磁碟的項目；磁碟上只有 staging／回復保留時，則是占用它的那些項目。
        $members=@($volume.Dest.ToArray());if(-not $members.Count){$members=@($volume.Other.ToArray())}
        $observed=& $probe $volumeKey $volume.Root
        $required=Get-WsmAssistiveCapacityRequiredBytes $volume.Write $volume.Staging $volume.Recovery
        if($observed.Error){
            foreach($memberId in $members){[pscustomobject]@{ItemId=$memberId;Error=$true;Action='Blocked';Status='Blocked';Reason='Target path could not be verified safely.';Root=$volume.Root;RequiredBytes=[long]$required;AvailableBytes=[long]-1;Scope='Volume'}}
            continue
        }
        if($observed.Available -ge $required){continue}
        $restoredNote='';if($volume.RestoredCount -gt 0){$restoredNote='；已還原的 '+$volume.RestoredCount+' 項（約 '+(Format-WsmAssistiveMiB $volume.RestoredBytes)+' MiB）不計入合計'}
        $reason=('目標磁碟 '+$volume.Root+' 可用空間不足（同一磁碟上已選項目合計約 '+[math]::Ceiling($volume.Write/1MB)+' MiB；計入項目：'+(Get-WsmAssistiveCapacityBreakdownText $volume.Write $volume.Staging $volume.Recovery)+$restoredNote+'）；請釋出空間後重新檢查。')
        foreach($memberId in $members){[pscustomobject]@{ItemId=$memberId;Error=$false;Action='AddTargetCapacity';Status='Deferred';Reason=$reason;Root=$volume.Root;RequiredBytes=[long]$required;AvailableBytes=[long]$observed.Available;Scope='Volume';WriteBytes=$volume.Write;StagingBytes=$volume.Staging;RecoveryBytes=$volume.Recovery;RestoredCount=$volume.RestoredCount;RestoredBytes=$volume.RestoredBytes}}
    }
}
function Initialize-WsmAssistiveMountPointApi {
    if('WsmAssistiveTargetNative' -as [type]){return}
    # https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-getvolumenameforvolumemountpointw
    # https://learn.microsoft.com/windows/win32/fileio/file-security-and-access-rights
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class WsmAssistiveTargetNative {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetVolumeNameForVolumeMountPointW(string mountPoint, StringBuilder volumeName, uint length);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr handle);
    public static bool IsVolumeMountPoint(string path) {
        StringBuilder name = new StringBuilder(262);
        return GetVolumeNameForVolumeMountPointW(path, name, (uint)name.Capacity);
    }
    // 只開啟既存目錄控制代碼並要求新增檔案／子目錄權限，由核心做有效存取權檢查；不建立任何東西，也不改動目錄時間戳。
    public static bool CanAddToDirectory(string path, bool subdirectories) {
        uint access = 0x0002; // FILE_ADD_FILE
        if(subdirectories) access |= 0x0004; // FILE_ADD_SUBDIRECTORY
        IntPtr handle = CreateFileW(path, access, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero); // share all, OPEN_EXISTING, BACKUP_SEMANTICS
        if(handle == (IntPtr)(-1)) {
            int error = Marshal.GetLastWin32Error();
            if(error == 5) return false; // ERROR_ACCESS_DENIED
            throw new Win32Exception(error);
        }
        CloseHandle(handle);
        return true;
    }
}
'@
}
function Get-WsmAssistiveMountPointAncestor([string]$Path) {
    # 由目標往上找第一個「磁碟區掛載點」（reparse 目錄且 GetVolumeNameForVolumeMountPoint 成功）；磁碟根本身不算。找不到回 $null。
    $cursor=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    while($cursor){
        $parent=[IO.Path]::GetDirectoryName($cursor);if(-not $parent){break}
        if([IO.Directory]::Exists($cursor) -and (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){Initialize-WsmAssistiveMountPointApi;if([WsmAssistiveTargetNative]::IsVolumeMountPoint($cursor+'\')){return $cursor}}
        $cursor=$parent.TrimEnd('\')
    }
    return $null
}
function Get-WsmAssistiveNearestExistingDirectory([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while(-not [IO.Directory]::Exists($cursor)){$parent=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\'));if(-not $parent -or $parent -ceq $cursor){throw 'Writable ancestor directory is unavailable.'};$cursor=$parent}
    $cursor
}
function Test-WsmAssistiveDirectoryWritable([string]$Directory,[switch]$Subdirectories) {
    # 可寫入性預檢採「有效存取權檢查」：以 FILE_ADD_FILE（需要建立子目錄時加 FILE_ADD_SUBDIRECTORY）開啟既存目錄，
    # 完全不建立暫存檔，因此預覽不會留下任何檔案，也不會改動目標目錄的時間戳（試寫會改動目錄 LastWriteTime，造成之後的中繼資料回讀誤判）。
    # 拒絕存取回 $false，其他錯誤往上拋（由呼叫端記為無法安全驗證）。
    Initialize-WsmAssistiveMountPointApi
    [WsmAssistiveTargetNative]::CanAddToDirectory($Directory,[bool]$Subdirectories)
}
function Test-WsmAssistiveOwnedFileAdopted($File) {
    # P10：逐檔 Ownership 欄位。只有 P9 對帳（Repair）在「沒有 journal 或 intent 證明是工具寫入」且內容雜湊等於封存值時，才會寫入 Ownership='AdoptedExisting'（沿用既有檔）。
    # 沒有這個欄位（舊紀錄、正常寫入路徑、intent 復原路徑）一律視為工具擁有，行為不變。全專案只用這一個判定函式讀它。
    if($null -eq $File -or -not $File.PSObject.Properties['Ownership']){return $false}
    [string]$File.Ownership -ceq 'AdoptedExisting'
}
function Test-WsmAssistiveOwnedFileAbsentConflict($Owner,[bool]$TargetExists) {
    # R2：「有先前擁有紀錄、但目標檔不存在」的唯一判定。寫入器（Invoke-WsmAssistiveFileScopeRestore）與 N1 共用判定（Get-WsmAssistiveFileScopeRestoreGap，預覽、Target 選項、重試候選都走它）都呼叫這一個函式，條件只有這一份。
    # 工具不會默默重建一個曾被記為己有的檔案，也不會默默丟掉它的擁有紀錄；回復（rollback）會在釋放擁有紀錄後才讓項目回到可再還原的狀態（見 Remove-WsmAssistiveRolledBackOwnership）。
    ($null -ne $Owner) -and (-not $TargetExists)
}
function Get-WsmAssistiveOwnedFileAbsentReason {
    'Previously owned file is absent; do not silently recreate or discard its prior ownership.'
}
function Get-WsmAssistiveDifferentContentConflictReason([long]$Count=0) {
    # R3：目標已有「不是工具擁有、內容又和封存不同」的檔案。預覽、Target 選項（N1）、寫入器共用這一段文字；Count>0 時附上衝突檔數（畫面只投影既有的原因欄位，數量跟著文字走）。
    $text='目標已有不同內容的檔案，需先人工處理'
    if($Count -gt 0){$text+=('（衝突 '+$Count+' 個檔案）')}
    $text
}
function Get-WsmAssistiveExistingFileDisposition($Spec,[string]$TargetRoot,$Artifact,[string]$Destination,$Owner,[bool]$AllowAdopt) {
    # R3：目錄範圍逐檔判定的「單一」函式。預覽（Get-WsmAssistiveFileScopeRestoreGap，Target 選項 N1 與重試候選也走它）、寫入器（Invoke-WsmAssistiveFileScopeRestore）
    # 與 Repair（Complete-WsmAssistiveFileScopeOwnershipRepair）都呼叫這一個函式，沒有第二份判定；全程唯讀，只讀檔案屬性、雜湊與拓樸。
    # 回傳 Disposition：
    #   Absent              目標不存在。
    #   Directory           目錄佔用了檔案位置。
    #   ConflictUnverifiable  reparse（含上層）、替代資料流等拓樸不支援，或讀不到；一律保守，保留原檔。Reason 帶例外訊息，ErrorType 帶例外型別。
    #   Owned／OwnedAdopted   已有先前擁有紀錄（OwnedAdopted＝沿用既有檔、內容仍等於紀錄與封存）；後續的漂移與 metadata 判定維持原狀。
    #   Adopt               沒有擁有紀錄、內容雜湊等於封存值、不是 reparse 也不是目錄（AllowAdopt 為真時）：記為 AdoptedExisting，不重寫（語意同 P10）。
    #   ConflictDifferent   沒有擁有紀錄、內容不同：保留原檔，需先人工處理。
    #   ConflictUnowned     沒有擁有紀錄且不允許沿用（單檔範圍）：維持原本的 BlockedConflict。
    $make={param([string]$Disposition,[string]$Reason='',[string]$ErrorType='',[string]$ContentHash='')[pscustomobject]@{Disposition=$Disposition;Reason=$Reason;ErrorType=$ErrorType;ContentHash=$ContentHash}}
    try{Assert-WsmNoReparse $Destination}catch{return (& $make 'ConflictUnverifiable' ([string]$_.Exception.Message) ($_.Exception.GetType().Name))}
    if([IO.Directory]::Exists($Destination)){return (& $make 'Directory' 'A directory occupies the required file path.')}
    if(-not [IO.File]::Exists($Destination)){return (& $make 'Absent')}
    try{
        if($null -ne $Owner){
            Assert-WsmAssistiveTargetScopeTopology -Path $Destination -Spec $Spec -TargetRoot $TargetRoot -Artifact $Artifact -Kind File -Destination $Destination -TrustedExistingHash ([string]$Owner.SHA256)
            if(Test-WsmAssistiveOwnedFileAdopted $Owner){
                $adoptedNow=(Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
                if($adoptedNow -ieq [string]$Owner.SHA256 -and $adoptedNow -ieq [string]$Artifact.Data.Hash){return (& $make 'OwnedAdopted' '' '' $adoptedNow)}
            }
            return (& $make 'Owned')
        }
        if(-not $AllowAdopt){
            Assert-WsmAssistiveTargetScopeTopology -Path $Destination -Spec $Spec -TargetRoot $TargetRoot -Artifact $Artifact -Kind File -Destination $Destination -TrustedExistingHash ''
            return (& $make 'ConflictUnowned')
        }
        $observed=(Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if($observed -ine [string]$Artifact.Data.Hash){return (& $make 'ConflictDifferent' '' '' $observed)}
        Assert-WsmAssistiveTargetScopeTopology -Path $Destination -Spec $Spec -TargetRoot $TargetRoot -Artifact $Artifact -Kind File -Destination $Destination -TrustedExistingHash ''
        return (& $make 'Adopt' '' '' $observed)
    }catch{return (& $make 'ConflictUnverifiable' ([string]$_.Exception.Message) ($_.Exception.GetType().Name))}
}
function New-WsmAssistiveAdoptedFileRecord([string]$RelativePath,[string]$TargetPath,[string]$Hash,$Metadata,[long]$Generation) {
    # R3：沿用既有檔（AdoptedExisting，P10）的逐檔擁有紀錄；寫入器（同內容的外部檔）與 Repair 對帳（P9）共用這一個建構函式，Ownership 欄位只在這裡設定。
    # 沒有 journal 或 intent 證明是工具寫的，所以不帶備份；回復（rollback）永遠不刪除、不覆寫、不改 ACL。
    [pscustomobject]@{RelativePath=$RelativePath;TargetPath=$TargetPath;SHA256=$Hash;MetadataHash=(Get-WsmAssistiveMetadataHash $Metadata);Backup='';BackupHash='';BackupMetadata=$null;BackupMetadataHash='';BackupMaterialId='';Generation=$Generation;Ownership='AdoptedExisting'}
}
function Add-WsmAssistiveFileDispositionDisplayFields($Row,$Gap) {
    # R3：把逐檔判定的結果（沿用檔數／位元組、衝突檔數／位元組）掛到預覽列，只供顯示與預計寫入量；預覽雜湊會先移除這些欄位（Remove-WsmAssistivePreviewDisplayFields）。
    if($null -eq $Gap){return}
    foreach($name in @('AdoptedFileCount','AdoptedBytes','ConflictFileCount','ConflictBytes')){$value=[long]0;if($Gap.PSObject.Properties[$name]){$value=[long]$Gap.$name};$Row|Add-Member NoteProperty $name $value -Force}
}
function Get-WsmAssistivePlannedWriteAmount($Row) {
    # R3：預計寫入量的單一算法：列的總檔數／位元組，扣掉不會寫入的沿用檔（Adopted）與衝突檔（Conflict）；不會小於 0。
    $files=[long]$Row.FileCount;$bytes=[long]$Row.Bytes
    foreach($name in @('AdoptedFileCount','ConflictFileCount')){if($Row.PSObject.Properties[$name]){$files-=[long]$Row.$name}}
    foreach($name in @('AdoptedBytes','ConflictBytes')){if($Row.PSObject.Properties[$name]){$bytes-=[long]$Row.$name}}
    [pscustomobject]@{Files=[Math]::Max([long]0,$files);Bytes=[Math]::Max([long]0,$bytes)}
}
function Get-WsmAssistiveAdoptedExistingNote {
    # 顯示用說明；Cutover 的檔案結果列把它放在 Reason 開頭（Fleet 的 FileResults 欄位集合固定，不能加欄位），畫面與報告以開頭文字辨識。
    '沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。'
}
function Test-WsmAssistiveAdoptedExistingReason([string]$Reason) {
    # 檔案結果列（Fleet 欄位集合固定）靠 Reason 開頭辨識沿用既有檔；console.js 的 ADOPTED_EXISTING_LABEL 與這裡同字（有守門測試）。
    $Reason.StartsWith('沿用既有檔：',[StringComparison]::Ordinal)
}
function Get-WsmAssistiveFileOwnershipHash($Rows) {
    # 舊紀錄（沒有 Ownership 欄位）的雜湊維持原樣；AdoptedExisting 列才多帶 Ownership，讓雜湊綁定擁有權類別。
    $body=@($Rows | Sort-Object RelativePath | ForEach-Object {if(Test-WsmAssistiveOwnedFileAdopted $_){[pscustomobject][ordered]@{RelativePath=$_.RelativePath;TargetPath=$_.TargetPath;SHA256=$_.SHA256;Generation=$_.Generation;Ownership='AdoptedExisting'}}else{$_ | Select-Object RelativePath,TargetPath,SHA256,Generation}})
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

function Get-WsmAssistiveReservations($Item,$Package,[string]$Workspace,[switch]$PreviewOnly,[string]$OperationId='',[ValidateSet('Running','WaitingForInput')][string]$OperationState='Running') {
    if(-not (Get-Command Get-WsmAssistiveResourceReservationPreview -ErrorAction SilentlyContinue) -or -not (Get-Command Reserve-WsmAssistiveResource -ErrorAction SilentlyContinue)){throw 'Shared-resource reservation support is unavailable; this workload cannot be written safely.'}
    $spec=$Item.MigrationSpec;$channel='C';if($spec.Adapter -eq 'FileScope' -and $spec.PSObject.Properties['TransferChannel'] -and $spec.TransferChannel -eq 'NonC'){$channel='NonC'}
    $sourceHash=Get-WsmHashText ($spec | ConvertTo-Json -Depth 40 -Compress);if($spec.Adapter -eq 'IISLocation'){$location=[string]$spec.Desired.LocationPath;$coLocated=@($Package.Plan.Items | Where-Object {$_.Decision -ceq 'Include' -and $_.PSObject.Properties['MigrationSpec'] -and $_.MigrationSpec -and $_.MigrationSpec.PSObject.Properties['Adapter'] -and $_.MigrationSpec.Adapter -ceq 'IISLocation' -and $_.MigrationSpec.PSObject.Properties['Desired'] -and $_.MigrationSpec.Desired -and $_.MigrationSpec.Desired.PSObject.Properties['LocationPath'] -and [string]$_.MigrationSpec.Desired.LocationPath -ceq $location} | Sort-Object {$_.MigrationSpec.Desired.SectionPath},ItemId | ForEach-Object {$_.MigrationSpec});$sourceHash=Get-WsmHashText ($coLocated | ConvertTo-Json -Depth 40 -Compress)};$consumerRefs=@([string]$Item.ItemId);$requests=New-Object 'System.Collections.Generic.List[object]'
    $kind='';$name=''
    switch($spec.Adapter){
        'FileScope' {$kind='FileScope';$name=[string]$spec.TargetPath}
        'IISPool' {$kind='IISPool';$name=[string]$spec.Desired.Name}
        'IISSite' {$kind='IISSite';$name='name:'+([string]$spec.Desired.Name)}
        'IISSection' {$kind='IISSection';$name=[string]$spec.Desired.SectionPath}
        'IISLocation' {$kind='IISLocation';$name='site:'+([string]$spec.Desired.LocationPath.Split('/')[0])+'|location:'+([string]$spec.Desired.LocationPath)}
        'ScheduledTask' {$kind='ScheduledTask';$name=([string]$spec.Desired.TaskPath)+([string]$spec.Desired.TaskName)}
        'Service' {$kind='Service';$name=[string]$spec.Desired.Name}
        default {return @()}
    }
    $names=@([pscustomobject]@{Kind=$kind;Name=$name});if($spec.Adapter -ceq 'FileScope' -and $spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactMembers'){$names=@(foreach($member in $spec.Members){[pscustomobject]@{Kind='FileScope';Name=(Join-Path ([string]$spec.TargetPath) ([string]$member.RelativePath))}})};$taskFolderSpecs=@()
    if($spec.Adapter -eq 'ScheduledTask'){$taskFolderSpecs=@(ConvertTo-WsmTaskSecurityFolderSpecs @($spec.Desired.FolderSecurity));foreach($folder in $taskFolderSpecs){$names+=@([pscustomobject]@{Kind='TaskFolder';Name=[string]$folder.Path;Folder=$folder})}}
    foreach($resource in $names){
        $resourceSourceHash=$sourceHash;if($resource.Kind -eq 'TaskFolder'){$resourceSourceHash=Get-WsmHashText (($resource.Folder | Select-Object Path,SecurityHash,ExistingPolicy) | ConvertTo-Json -Depth 8 -Compress)}
        $args=@{Workspace=$Workspace;PairId=[string]$Package.Manifest.PairId;ItemId=[string]$Item.ItemId;Channel=$channel;SourceHash=$resourceSourceHash;ConsumerRefs=$consumerRefs;ResourceKind=$resource.Kind;ResourceName=$resource.Name;TargetFingerprint=[string]$Package.Manifest.Target.Fingerprint;SealedPlanPath=(Join-Path $Package.Root 'plan.json');SealedPlanHash=[string]$Package.Manifest.PlanHash}
        if($resource.Kind -ceq 'Service'){Assert-WsmId $OperationId;$args.OperationId=$OperationId}
        if($resource.Kind -eq 'FileScope'){$args.Path=[string]$spec.TargetPath;$physical=Resolve-WsmAssistivePhysicalResource $args.Path 'LocalFileSystem';$args.TargetPhysicalId=$physical.PhysicalIdentity}
        $preview=Get-WsmAssistiveResourceReservationPreview @args
        if(-not $preview.CanReserve){throw 'Shared resource is reserved with a conflicting owner; this item remains unmodified.'}
        $sameOwner=@($preview.ExistingOwners | Where-Object {$_.PairId -ceq $Package.Manifest.PairId -and $_.ItemId -ceq $Item.ItemId -and $_.Channel -ceq $channel -and $_.SourceHash -ceq $resourceSourceHash})
        if($resource.Kind -ceq 'Service' -and $sameOwner.Count -and [string]$sameOwner[0].ActiveOperationId -and [string]$sameOwner[0].ActiveOperationId -cne $OperationId){throw 'Target service is reserved by another waiting or active restore operation.'}
        if($sameOwner.Count){if($resource.Kind -ceq 'Service' -and -not $PreviewOnly){Set-WsmAssistiveServiceReservationOperation -Workspace $Workspace -ResourceKey $preview.ResourceKey -PairId $Package.Manifest.PairId -ItemId $Item.ItemId -OperationId $OperationId -State $OperationState | Out-Null};$requests.Add([pscustomobject]@{Preview=$preview;Existing=$true;Reservation=$null});continue}
        if($PreviewOnly){$requests.Add([pscustomobject]@{Preview=$preview;Existing=$false;Reservation=$null});continue}
        $reservation=Reserve-WsmAssistiveResource -Workspace $Workspace -Preview $preview -ExpectedPreviewHash $preview.SHA256 -ExpectedRevision $preview.RegistryRevision -Reason ('Assistive generation '+$Package.Manifest.Generation+' item '+$Item.ItemId)
        if($resource.Kind -ceq 'Service' -and -not $PreviewOnly){Set-WsmAssistiveServiceReservationOperation -Workspace $Workspace -ResourceKey $preview.ResourceKey -PairId $Package.Manifest.PairId -ItemId $Item.ItemId -OperationId $OperationId -State $OperationState | Out-Null}
        $requests.Add([pscustomobject]@{Preview=$preview;Existing=$false;Reservation=$reservation})
    }
    $requests.ToArray()
}

function Cancel-WsmAssistiveServiceCredentialChallenge([string]$StateDirectory,[string]$PairId,[string]$OperationId,[string]$PreviewHash) {
    Assert-WsmId $PairId;Assert-WsmId $OperationId;Assert-WsmAssistiveHash $PreviewHash 'Service challenge preview hash'
    $paths=Get-WsmOperationPaths $StateDirectory $PairId
    Invoke-WsmLocked $paths.Root {
        $state=Read-WsmJson $paths.State
        if($state.PairId -cne $PairId -or -not $state.PSObject.Properties['AssistiveServiceChallenge']){throw 'Durable Service credential challenge was not found.'}
        $challenge=$state.AssistiveServiceChallenge
        if([string]$challenge.ParentOperationId -cne $OperationId -or [string]$challenge.PreviewHash -ine $PreviewHash -or [string]$challenge.State -cne 'WaitingForInput'){throw 'Service credential challenge binding changed or is no longer cancellable.'}
        foreach($reservation in @($challenge.ServiceReservations)){
            Revoke-WsmAssistiveServiceChallengeReservation -Workspace $StateDirectory -ResourceKey ([string]$reservation.ResourceKey) -PairId $PairId -ItemId ([string]$reservation.ItemId) -OperationId $OperationId -Created ([bool]$reservation.Created) | Out-Null
        }
        $challenge.State='Cancelled';$challenge|Add-Member NoteProperty CancelReason 'Operator cancelled secure credential entry' -Force;$challenge.UpdatedUtc=Get-WsmUtc;$state.Stage='Cancelled'
        if($state.PSObject.Properties['RestoreAttempt'] -and [string]$state.RestoreAttempt.OperationId -ceq $OperationId){$state.RestoreAttempt|Add-Member NoteProperty Status 'Cancelled' -Force;$state.RestoreAttempt|Add-Member NoteProperty CancelledUtc (Get-WsmUtc) -Force}
        Add-WsmJournal $paths $state 'AssistiveServiceCredentialChallengeCancelled' '' $challenge
        $challenge
    }
}

function Get-WsmAssistiveCredentialMaxAttempts {
    # The single place for the per-parent retry limit of one SecretRef: this many CredentialRejected verdicts defer the whole group.
    3
}

function Get-WsmAssistiveCredentialLimitNotice {
    # The single wording shown (result, job projection) when a SecretRef group was auto-deferred at the retry limit.
    '已達重試上限，請確認帳號狀態後在新的還原中處理'
}

function Test-WsmAssistiveCredentialRejectedError($Failure) {
    # Classifies a native failure as "the account/password was refused" (Win32 1326 logon failure, 1069 service logon failure and their
    # 0x8007xxxx HRESULT forms). It walks HResult / NativeErrorCode over the exception chain and every ErrorRecord.Exception. Anything else,
    # for example 5 access denied or a plain IOException, is not a rejection. It never probes a login; it only reads what was thrown.
    $rejectedCodes=@(1326,1069)
    $queue=New-Object 'System.Collections.Generic.Queue[object]';$queue.Enqueue($Failure);$seen=0
    while($queue.Count -and $seen -lt 64){
        $current=$queue.Dequeue();$seen++
        if($null -eq $current){continue}
        if($current -is [Management.Automation.ErrorRecord]){$queue.Enqueue($current.Exception);continue}
        if($current -isnot [Exception]){continue}
        $hresult=[int]$current.HResult
        if($hresult -in $rejectedCodes){return $true}
        if(($hresult -band -65536) -eq -2147024896 -and (($hresult -band 65535) -in $rejectedCodes)){return $true}
        $nativeProperty=$current.PSObject.Properties['NativeErrorCode']
        if($nativeProperty -and $null -ne $nativeProperty.Value){$nativeCode=0;if([int]::TryParse([string]$nativeProperty.Value,[ref]$nativeCode) -and $nativeCode -in $rejectedCodes){return $true}}
        $recordProperty=$current.PSObject.Properties['ErrorRecord']
        if($recordProperty -and $recordProperty.Value -is [Management.Automation.ErrorRecord] -and -not [object]::ReferenceEquals($recordProperty.Value.Exception,$current)){$queue.Enqueue($recordProperty.Value.Exception)}
        if($current.InnerException){$queue.Enqueue($current.InnerException)}
        $innerProperty=$current.PSObject.Properties['InnerExceptions']
        if($innerProperty -and $innerProperty.Value){foreach($inner in @($innerProperty.Value)){$queue.Enqueue($inner)}}
    }
    $false
}

function Get-WsmAssistiveCredentialRejectionVerdict($Failure,$Spec) {
    # CredentialRejected only when the failure is a refusal AND a fresh readback proves the target object still does not exist
    # (the item was only written when it was absent, so "absent now" equals "same as before the failure"). Every other case,
    # including an unreadable target, is Unknown and keeps the pending intent for repair / reconciliation.
    if(-not (Test-WsmAssistiveCredentialRejectedError $Failure)){return 'Unknown'}
    try{$after=Get-WsmAdapterState $Spec}catch{return 'Unknown'}
    if($null -eq $after -or -not $after.PSObject.Properties['Exists'] -or $after.Exists -isnot [bool]){return 'Unknown'}
    if($after.Exists){return 'Unknown'}
    'Rejected'
}

function Get-WsmAssistiveCredentialStateMap($Challenge) {
    # SecretRef -> durable per-group state (Deferred / DeferReason / LastFailure / Attempts) read from the challenge Requirements.
    $map=New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal)
    if($Challenge -and $Challenge.PSObject.Properties['Requirements']){foreach($requirement in @($Challenge.Requirements)){
        if(-not $requirement -or -not $requirement.PSObject.Properties['SecretRef']){continue}
        $deferred=$false;if($requirement.PSObject.Properties['Deferred'] -and $requirement.Deferred -is [bool]){$deferred=[bool]$requirement.Deferred}
        $reason='';if($requirement.PSObject.Properties['DeferReason']){$reason=[string]$requirement.DeferReason}
        $failure='';if($requirement.PSObject.Properties['LastFailure']){$failure=[string]$requirement.LastFailure}
        $attempts=0;if($requirement.PSObject.Properties['Attempts']){$attempts=[int]$requirement.Attempts}
        $map[[string]$requirement.SecretRef]=[pscustomobject]@{Deferred=$deferred;DeferReason=$reason;LastFailure=$failure;Attempts=$attempts}
    }}
    $map
}

function New-WsmAssistiveCredentialRequirementList([string[]]$Refs,$CredentialByItem,$ItemsById,$AccountByRef,$StateByRef) {
    @(foreach($requirementRef in @($Refs)){
        $matchedIds=@($CredentialByItem.Keys|Where-Object {[string]$CredentialByItem[$_].SecretRef -ceq $requirementRef}|Sort-Object)
        $matchedNames=@(foreach($matchedId in $matchedIds){$matchedName=[string]$matchedId;$matchedItem=$ItemsById[[string]$matchedId];if($matchedItem -and $matchedItem.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string]$matchedItem.Name)){$matchedName=[string]$matchedItem.Name};$matchedName})
        $groupState=$StateByRef[[string]$requirementRef];$deferred=$false;$reason='';$failure='';$attempts=0
        if($groupState){$deferred=[bool]$groupState.Deferred;$reason=[string]$groupState.DeferReason;$failure=[string]$groupState.LastFailure;$attempts=[int]$groupState.Attempts}
        [pscustomobject][ordered]@{SecretRef=[string]$requirementRef;Kinds=@($matchedIds|ForEach-Object {[string]$CredentialByItem[$_].Kind}|Sort-Object -Unique);ItemIds=@($matchedIds|ForEach-Object {[string]$_});DisplayNames=@($matchedNames);ApprovedAccount=[string]$AccountByRef[[string]$requirementRef];Deferred=$deferred;DeferReason=$reason;LastFailure=$failure;Attempts=$attempts}
    })
}

function Set-WsmAssistiveCredentialDeferral {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$StateDirectory,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ParentOperationId,[Parameter(Mandatory)][string]$PreviewHash,[Parameter(Mandatory)][string[]]$SecretRefs)
    # Marks whole SecretRef groups of a WaitingForInput challenge as deferred. Durable and secret-free: only the group names are stored.
    # The next run (credential reply or resume) will not ask for these groups; their items end Deferred / CredentialDeferred without an intent.
    Assert-WsmId $PairId;Assert-WsmId $ParentOperationId;Assert-WsmAssistiveHash $PreviewHash 'Credential deferral preview hash'
    $refs=@($SecretRefs|ForEach-Object {[string]$_}|Sort-Object -Unique)
    if(-not $refs.Count){throw 'At least one SecretRef is required to defer.'}
    foreach($ref in $refs){if([string]::IsNullOrWhiteSpace($ref) -or $ref.Length -gt 256 -or $ref -match '[\x00-\x1f]'){throw 'A deferred SecretRef is malformed.'}}
    $paths=Get-WsmOperationPaths $StateDirectory $PairId
    Invoke-WsmLocked $paths.Root {
        $state=Read-WsmJson $paths.State
        if($state.PairId -cne $PairId -or -not $state.PSObject.Properties['AssistiveServiceChallenge'] -or -not $state.PSObject.Properties['RestoreAttempt']){throw 'Durable Service credential challenge was not found.'}
        $challenge=$state.AssistiveServiceChallenge;$attempt=$state.RestoreAttempt
        if([string]$challenge.ParentOperationId -cne $ParentOperationId -or [string]$attempt.OperationId -cne $ParentOperationId -or [string]$challenge.PairId -cne $PairId -or [string]$challenge.PreviewHash -ine $PreviewHash -or [string]$attempt.WizardPreviewHash -ine $PreviewHash){throw 'Credential deferral is not bound to this durable TargetRestore parent and preview.'}
        if([string]$challenge.State -cne 'WaitingForInput' -or [string]$attempt.Status -cne 'WaitingForInput' -or [string]$state.Stage -cne 'WaitingForInput'){throw 'Credentials can only be deferred while the restore is waiting for input.'}
        if(-not $challenge.PSObject.Properties['Requirements'] -or -not @($challenge.Requirements).Count){throw 'This challenge has no recorded credential requirements; refresh the restore preview.'}
        $required=@($challenge.RequiredSecretRefs|ForEach-Object {[string]$_})
        foreach($ref in $refs){if($ref -cnotin $required){throw 'A SecretRef to defer is not a current credential requirement of this challenge.'}}
        $already=@();if($challenge.PSObject.Properties['DeferredSecretRefs']){$already=@($challenge.DeferredSecretRefs|ForEach-Object {[string]$_})}
        foreach($requirement in @($challenge.Requirements)){if([string]$requirement.SecretRef -cin $refs){$requirement|Add-Member NoteProperty Deferred $true -Force;$requirement|Add-Member NoteProperty DeferReason 'CredentialDeferred' -Force}}
        $challenge.RequiredSecretRefs=@($required|Where-Object {$_ -cnotin $refs})
        $challenge|Add-Member NoteProperty DeferredSecretRefs @(@($already)+@($refs)|Sort-Object -Unique) -Force
        $challenge.UpdatedUtc=Get-WsmUtc
        Add-WsmJournal $paths $state 'AssistiveServiceCredentialDeferred' '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;PairId=$PairId;PreviewHash=$PreviewHash;SecretRefs=@($refs);Reason='CredentialDeferred';RemainingSecretRefs=@($challenge.RequiredSecretRefs)})
        [pscustomobject][ordered]@{DeferredSecretRefs=@($refs);RemainingSecretRefs=@($challenge.RequiredSecretRefs);AllDeferred=(@($challenge.RequiredSecretRefs).Count -eq 0);Requirements=@($challenge.Requirements)}
    }
}

function Takeover-WsmAssistiveServiceCredentialChallenge([string]$StateDirectory,[string]$PairId,[string]$OperationId,[string]$PreviewHash,[string]$Actor,[string]$SessionId,[string]$ContextId,[int]$Revision,[switch]$ConfirmTakeover) {
    Assert-WsmId $PairId;Assert-WsmId $OperationId;Assert-WsmAssistiveHash $PreviewHash 'Service challenge preview hash'
    if(-not $ConfirmTakeover){throw 'Service credential challenge takeover requires explicit operator confirmation.'}
    foreach($binding in @(@($Actor,'actor'),@($SessionId,'session id'),@($ContextId,'context id'))){if([string]::IsNullOrWhiteSpace([string]$binding[0]) -or ([string]$binding[0]).Length -gt 256 -or [string]$binding[0] -match '[\x00-\x1f]'){throw ('Service challenge takeover has an invalid '+[string]$binding[1]+'.')}}
    if($Revision -lt 0){throw 'Service challenge takeover requires the current Target decision revision.'}
    $paths=Get-WsmOperationPaths $StateDirectory $PairId
    Invoke-WsmLocked $paths.Root {
        $state=Read-WsmJson $paths.State
        if($state.PairId -cne $PairId -or -not $state.PSObject.Properties['RestoreAttempt'] -or -not $state.PSObject.Properties['AssistiveServiceChallenge']){throw 'No durable TargetRestore parent is available for takeover.'}
        $attempt=$state.RestoreAttempt;$challenge=$state.AssistiveServiceChallenge
        if([string]$attempt.OperationId -cne $OperationId -or [string]$challenge.ParentOperationId -cne $OperationId -or [string]$challenge.PairId -cne $PairId -or [string]$challenge.PreviewHash -ine $PreviewHash -or [string]$attempt.WizardPreviewHash -ine $PreviewHash -or [string]$attempt.ManifestHash -ine [string]$challenge.ManifestHash -or [long]$attempt.Generation -ne [long]$challenge.Generation -or [int]$challenge.Revision -ne $Revision -or [string]$challenge.Role -cne 'Target'){throw 'Service credential challenge changed; takeover requires the same current durable TargetRestore parent and preview.'}
        $readback=$null;if([string]$challenge.State -ceq 'Running'){$readback=Test-WsmAssistiveServiceChallengePreWriteRecovery $StateDirectory $state $OperationId;$state.Stage='WaitingForInput';$attempt.Status='WaitingForInput';$attempt|Add-Member NoteProperty LastPreWriteRecovery $readback -Force;$challenge.State='WaitingForInput';$challenge|Add-Member NoteProperty LastPreWriteRecovery $readback -Force}
        elseif([string]$state.Stage -cne 'WaitingForInput' -or [string]$attempt.Status -cne 'WaitingForInput' -or [string]$challenge.State -cne 'WaitingForInput'){throw 'Service credential challenge state cannot be safely taken over.'}
        if([string]$challenge.Actor -ceq $Actor -and [string]$challenge.SessionId -ceq $SessionId -and [string]$challenge.ContextId -ceq $ContextId){throw 'Current actor/session already owns this service challenge; takeover is unnecessary.'}
        $takeoverCount=0;if($challenge.PSObject.Properties['TakeoverCount']){$takeoverCount=[int]$challenge.TakeoverCount};$takeoverCount++
        $challenge.Actor=$Actor;$challenge.SessionId=$SessionId;$challenge.ContextId=$ContextId;$challenge|Add-Member NoteProperty TakeoverCount $takeoverCount -Force;$challenge|Add-Member NoteProperty LastTakeoverUtc (Get-WsmUtc) -Force
        Add-WsmJournal $paths $state 'AssistiveServiceCredentialChallengeTakenOver' '' ([pscustomobject]@{ParentOperationId=$OperationId;PairId=$PairId;PreviewHash=$PreviewHash;Actor=$Actor;SessionId=$SessionId;ContextId=$ContextId;Revision=$Revision;TakeoverCount=$takeoverCount;PreWriteRecovery=$readback})
        $challenge
    }
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
    if(-not $Preview -or -not $Preview.PSObject -or -not $Preview.PSObject.Properties){throw 'Assistive package material registration requires the exact typed restore preview.'}
    $ids=New-Object 'System.Collections.Generic.List[string]';$consumers=@($Decision.SelectedItemIds)
    if(-not $consumers.Count){return [pscustomobject]@{MaterialIds=@();OperationId=''}}
    $files=@([pscustomobject]@{Path=(Join-Path $Package.Root 'plan.json');Hash=$Package.Manifest.PlanHash;Kind='AssistiveSealedPlan'},[pscustomobject]@{Path=(Join-Path $Package.Root 'manifest.json');Hash=$Package.SHA256;Kind='AssistivePackageManifest'},[pscustomobject]@{Path=(Join-Path $Package.Root 'artifacts.jsonl');Hash=$Package.Manifest.ArtifactsHash;Kind='AssistiveArtifactIndex'},[pscustomobject]@{Path=$Decision.ReceiptPath;Hash=$Decision.ReceiptHash;Kind='AssistiveTargetDecisionReceipt'})
    # A nonfinal immutable-scope generation has no source freeze record. It may
    # be restored as an isolated stage, but it must not invent or retain a
    # freeze authorization. Final packages have already passed Test-WsmMigrationPackage
    # and bind their real freeze bytes through this explicit material reference.
    if($Package.Manifest.Final){$freezePath=Join-Path $Package.Root 'freeze.json';$freezeHash=[string]$Package.Manifest.FreezeHash;if($freezeHash -notmatch '^[a-f0-9]{64}$' -or -not [IO.File]::Exists($freezePath) -or (Get-FileHash -LiteralPath $freezePath -Algorithm SHA256).Hash -ine $freezeHash){throw 'Final Assistive package freeze material is missing or changed.'};$files+=@([pscustomobject]@{Path=$freezePath;Hash=$freezeHash;Kind='AssistiveFreezeRecord'})}
    if($Decision.SnapshotPath){$files+=@([pscustomobject]@{Path=$Decision.SnapshotPath;Hash=[string]$Decision.Receipt.TargetSnapshotHash;Kind='AssistiveTargetSnapshot'})}
    foreach($binding in @(@{Path='NonCTransferPlanPath';Hash='NonCTransferPlanHash';Kind='AssistiveNonCTransferPlan'},@{Path='NonCResultPath';Hash='NonCResultHash';Kind='AssistiveNonCTransferResult'})){
        $pathProperty=$Preview.PSObject.Properties[[string]$binding.Path];$hashProperty=$Preview.PSObject.Properties[[string]$binding.Hash]
        $materialPath='';$materialHash='';if($pathProperty){$materialPath=[string]$pathProperty.Value};if($hashProperty){$materialHash=[string]$hashProperty.Value}
        if([bool]$materialPath -xor [bool]$materialHash){throw ('Assistive preview has an incomplete immutable material binding: '+$binding.Kind)}
        if($materialPath){$files+=@([pscustomobject]@{Path=$materialPath;Hash=$materialHash;Kind=[string]$binding.Kind})}
    }
    foreach($file in $files){if(-not [IO.File]::Exists($file.Path) -or (Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -ine [string]$file.Hash){throw ('Required immutable material is missing or drifted: '+$file.Kind)}}
    # The batch registry contract names the byte digest SHA256. Keep Hash for
    # the legacy single-material path and supply the explicit batch field too.
    foreach($file in $files){if(-not $file.PSObject.Properties['SHA256']){$file | Add-Member NoteProperty SHA256 ([string]$file.Hash)}}
    if(Get-Command Register-WsmAssistiveMaterialBatch -ErrorAction SilentlyContinue){$batch=Register-WsmAssistiveMaterialBatch $Workspace $Package.Manifest.PairId ([int]$Package.Manifest.Generation) @($files) $consumers;foreach($id in @($batch.MaterialIds)){$ids.Add([string]$id)}}else{foreach($file in $files){$entry=Register-WsmAssistiveMaterialReference -Workspace $Workspace -PairId $Package.Manifest.PairId -Generation ([int]$Package.Manifest.Generation) -Path $file.Path -SHA256 $file.Hash -Kind $file.Kind -ConsumerRefs $consumers;$ids.Add([string]$entry.MaterialId)}}
    $operationId=[Guid]::NewGuid().ToString();Set-WsmAssistiveJobLock -Workspace $Workspace -OperationId $operationId -PairId $Package.Manifest.PairId -Generation ([int]$Package.Manifest.Generation) -MaterialIds @($ids.ToArray()) -Active $true | Out-Null
    [pscustomobject]@{MaterialIds=$ids.ToArray();OperationId=$operationId}
}

function Complete-WsmAssistivePackageJob($Package,$Job,[string]$Workspace) {
    if($Job -and $Job.OperationId -and (Get-Command Set-WsmAssistiveJobLock -ErrorAction SilentlyContinue)){Set-WsmAssistiveJobLock -Workspace $Workspace -OperationId $Job.OperationId -PairId $Package.Manifest.PairId -Generation ([int]$Package.Manifest.Generation) -MaterialIds @($Job.MaterialIds) -Active $false | Out-Null}
}

function Assert-WsmAssistiveCredentialAccount($Requirement,[hashtable]$Secrets) {
    $credential=$Secrets[[string]$Requirement.SecretRef]
    if($credential -isnot [Management.Automation.PSCredential]){throw 'A reviewed SecretRef must resolve to an in-memory PSCredential.'}
    if([string]::IsNullOrWhiteSpace([string]$Requirement.ApprovedAccount) -or [string]$credential.UserName -ine [string]$Requirement.ApprovedAccount){throw 'In-memory credential username does not match the reviewed approved account.'}
}
function Assert-WsmAssistiveCredentialAvailable($Spec,[hashtable]$Secrets) {
    $requirement=$null;if([string]$Spec.Adapter -cin @('Service','ScheduledTask','IISPool')){try{$requirement=Get-WsmAdapterCredentialRequirement $Spec}catch{$requirement=$null}}
    if(-not $requirement){return}
    $secretRef=[string]$requirement.SecretRef
    if(-not $secretRef -or -not $Secrets -or -not $Secrets.ContainsKey($secretRef) -or $Secrets[$secretRef] -isnot [Management.Automation.PSCredential]){throw 'Required in-memory credential is unavailable; no intent or native write may begin without it.'}
}
function Get-WsmAssistivePreviewRowHashes($Rows) {
    # Per-row digests let a continuation tell which preview rows drifted. A very large plan keeps the strict whole-preview comparison only.
    $list=New-Object 'System.Collections.Generic.List[object]'
    if(@($Rows).Count -gt 2000){return @()}
    foreach($row in @($Rows)){if($row){$list.Add([pscustomobject][ordered]@{ItemId=[string]$row.ItemId;Hash=(Get-WsmHashText ((Remove-WsmAssistivePreviewDisplayFields $row) | ConvertTo-Json -Depth 20 -Compress))})}}
    $list.ToArray()
}

function Merge-WsmAssistiveItemResults($Prior,$New) {
    # Item results merge by ItemId: a new result replaces the same item, earlier results of other items stay.
    $merged=New-Object 'System.Collections.Generic.List[object]';$index=@{}
    foreach($result in @(@($Prior)+@($New))){
        if(-not $result){continue}
        $key=[string]$result.ItemId
        if($key -and $index.ContainsKey($key)){$merged[[int]$index[$key]]=$result}else{if($key){$index[$key]=$merged.Count};$merged.Add($result)}
    }
    $merged.ToArray()
}

function Invoke-WsmAssistiveContinuationReconcile($Package,$Paths,$State,[hashtable]$SidMap,[string]$ManifestHash) {
    # Reuses the existing per-item repair logic (Complete-WsmAssistiveOperationRepair) under the workspace lock.
    # Success adopts the proven native result or abandons a proven-unapplied intent. A throw keeps the pending intent
    # untouched and marks the item as unknown; nothing is re-applied or deleted for it.
    $unknown=@{}
    $itemsById=@{};foreach($planItem in @($Package.Plan.Items)){$itemsById[[string]$planItem.ItemId]=$planItem}
    foreach($op in @($State.PendingOperations)){
        $itemId=[string]$op.ItemId
        try{
            $item=$itemsById[$itemId]
            if(-not $item -or [string]$item.Decision -cne 'Include' -or [string]$op.Phase -cnotin @('AssistiveAdapterCreating','AssistiveFileReplace') -or [string]$op.ManifestHash -ine $ManifestHash){throw 'Pending intent is not an exact current Assistive item intent that can be reconciled automatically.'}
            Invoke-WsmLocked $Paths.Root {[void](Complete-WsmAssistiveOperationRepair $item $op $Package $Paths $State $SidMap)}
        }catch [OperationCanceledException]{throw}catch{
            $message=[string]$_.Exception.Message;if($message.Length -gt 300){$message=$message.Substring(0,300)}
            $unknown[$itemId]=('Native result could not be proven by readback; pending intent retained for manual reconciliation: '+$message)
        }
    }
    $unknown
}

function Get-WsmAssistiveUnknownDependencyBlocks([object[]]$Items,[hashtable]$UnknownItems) {
    # 相依判斷只涵蓋兩種明確關聯：
    # 1. IISSite 的 application 其 applicationPool 指向「未知」的 IISPool 名稱。
    # 2. Service 的 Desired.Dependencies 含「未知」的 Service 名稱。
    # 其他類型（FileScope、ScheduledTask、IISSection 等）一律視為獨立項，不連帶阻擋。
    # 被阻擋的 Service 會再被當成未知項，讓依賴它的 Service 一併阻擋（僅限 Service 對 Service）。
    $blocked=@{}
    if(-not $UnknownItems -or -not $UnknownItems.Count){return $blocked}
    $byId=@{};foreach($item in @($Items)){$byId[[string]$item.ItemId]=$item}
    $unknownNames=@{}
    $registerName={param($Item,[string]$ItemId)if($Item -and $Item.MigrationSpec -and [string]$Item.MigrationSpec.Adapter -cin @('IISPool','Service') -and $Item.MigrationSpec.PSObject.Properties['Desired'] -and $Item.MigrationSpec.Desired -and $Item.MigrationSpec.Desired.PSObject.Properties['Name']){$unknownNames[[string]$Item.MigrationSpec.Adapter+'|'+([string]$Item.MigrationSpec.Desired.Name).ToLowerInvariant()]=$ItemId}}
    foreach($unknownId in @($UnknownItems.Keys)){& $registerName $byId[[string]$unknownId] ([string]$unknownId)}
    do{
        $changed=$false
        foreach($item in @($Items)){
            $id=[string]$item.ItemId
            if($UnknownItems.ContainsKey($id) -or $blocked.ContainsKey($id) -or [string]$item.Decision -cne 'Include' -or -not $item.MigrationSpec){continue}
            $spec=$item.MigrationSpec;$cause=''
            if([string]$spec.Adapter -ceq 'IISSite'){
                try{$doc=Read-WsmXml ([string]$spec.Desired.Xml);foreach($app in @($doc.SelectNodes("//*[local-name()='application'][@applicationPool]"))){$poolName=[string]$app.GetAttribute('applicationPool');$key='IISPool|'+$poolName.ToLowerInvariant();if($unknownNames.ContainsKey($key)){$cause=('IIS application pool '+$poolName+' (item '+$unknownNames[$key]+')');break}}}catch{}
            }elseif([string]$spec.Adapter -ceq 'Service' -and $spec.PSObject.Properties['Desired'] -and $spec.Desired -and $spec.Desired.PSObject.Properties['Dependencies']){
                foreach($dependency in @($spec.Desired.Dependencies)){$key='Service|'+([string]$dependency).ToLowerInvariant();if($unknownNames.ContainsKey($key)){$cause=('Service dependency '+[string]$dependency+' (item '+$unknownNames[$key]+')');break}}
            }
            if($cause){$blocked[$id]=('Not written because '+$cause+' has an unknown native result that still needs reconciliation.');if([string]$spec.Adapter -ceq 'Service'){& $registerName $item $id};$changed=$true}
        }
    }while($changed)
    $blocked
}

function Invoke-WsmAssistiveRestore($Package,[string]$ManifestHash,[string]$StateDirectory,[hashtable]$Secrets,[hashtable]$SidMap,$CancellationToken,[object[]]$GeneralHostEvidence,[string]$ReceiptPath,[string]$ReceiptHash,[string]$TargetSnapshotPath,$Preview,[string]$ParentOperationId='', [object]$ChallengeContext=$null, [switch]$Continuation) {
    $paths=Get-WsmOperationPaths $StateDirectory $Package.Manifest.PairId
    $state=Get-WsmOperationState $paths $Package
    if($state.Cutover){throw 'Restore after cutover requires reviewed data reconciliation; no automatic reverse synchronization.'}
    # A new parent never inherits another parent's unresolved native intent. Only an explicit continuation of the original parent reconciles it item by item.
    if(@($state.PendingOperations).Count -and -not $Continuation){throw 'Interrupted Assistive item operation blocks a new parent operation; continue the original parent through Resume-WsmWizardTargetRestore or run Repair-WsmOperation before retry.'}
    $decision=Get-WsmAssistiveRestoreDecision $Package $ManifestHash $ReceiptPath $ReceiptHash $TargetSnapshotPath
    if($decision.Receipt.Decision -eq 'WaitForInstall'){return $Preview}
    Assert-WsmAssistiveReceiptFresh $Package $decision | Out-Null
    if(-not $decision.ReceiptPath -or -not $decision.ReceiptHash -or -not $decision.SnapshotPath -or -not $decision.Receipt.TargetSnapshotHash){throw 'Assistive restore decision has no canonical receipt and target snapshot references.'}
    $serviceRows=New-Object 'System.Collections.Generic.List[object]';$serviceItemIds=@{};foreach($serviceItem in @($Package.Plan.Items|Where-Object {$_.MigrationSpec.Adapter -ceq 'Service'})){$serviceItemIds[[string]$serviceItem.ItemId]=$true};foreach($serviceRow in @($Preview.Rows)){if([string]$serviceRow.Status -ceq 'Ready' -and $serviceItemIds.ContainsKey([string]$serviceRow.ItemId)){$serviceRows.Add($serviceRow)}}
    $preflightItemsById=@{};foreach($item in @($Package.Plan.Items)){$preflightItemsById[[string]$item.ItemId]=$item}
    # A parent that went back to WaitingForInput after a rejected password keeps the items it already settled (done, failed, deferred); they are
    # neither redone nor asked for a credential again. Only items that ended CredentialRejected (or were never attempted) are still open.
    $settledByParent=@{};$parentWasWaiting=$false
    if($state.PSObject.Properties['RestoreAttempt'] -and $state.RestoreAttempt -and [string]$state.RestoreAttempt.OperationId -ceq $ParentOperationId -and [string]$state.RestoreAttempt.Status -ceq 'WaitingForInput'){
        $parentWasWaiting=$true
        if($state.RestoreAttempt.PSObject.Properties['ItemResults']){foreach($settledResult in @($state.RestoreAttempt.ItemResults)){if($settledResult -and $settledResult.PSObject.Properties['ItemId'] -and [string]$settledResult.Status -cne 'CredentialRejected'){$settledByParent[[string]$settledResult.ItemId]=$true}}}
    }
    $credentialByItem=@{};foreach($row in @($Preview.Rows|Where-Object Status -CEQ 'Ready')){$item=$preflightItemsById[[string]$row.ItemId];if(-not $item){continue};if($settledByParent.ContainsKey([string]$item.ItemId)){continue};$credentialRequirement=$null;if($item.MigrationSpec.Adapter -ceq 'Service'){$policy=Get-WsmServiceAccountPolicy $item.MigrationSpec.Desired $item.MigrationSpec;if($policy.Mode -ceq 'UserPassword'){$credentialRequirement=[pscustomobject][ordered]@{Kind='Service';SecretRef=[string]$policy.SecretRef;ApprovedAccount=[string]$policy.CanonicalAccount}}}elseif($item.MigrationSpec.Adapter -cin @('ScheduledTask','IISPool')){try{$credentialRequirement=Get-WsmAdapterCredentialRequirement $item.MigrationSpec}catch{$credentialRequirement=$null}};if($credentialRequirement){$credentialByItem[[string]$item.ItemId]=$credentialRequirement}}
    $ParentOperationId=Resolve-WsmAssistiveRestoreParentOperationId $ParentOperationId $CancellationToken -RequireDurableParent:([bool]($serviceRows.Count -or $credentialByItem.Count))
    $contextRole='Target';$contextActor=[string](Get-WsmExecutionActor);$contextSession='';$contextId='';$contextRevision=-1
    if($ChallengeContext){if($ChallengeContext.PSObject.Properties['Role']){$contextRole=[string]$ChallengeContext.Role};if($ChallengeContext.PSObject.Properties['Actor']){$contextActor=[string]$ChallengeContext.Actor};if($ChallengeContext.PSObject.Properties['SessionId']){$contextSession=[string]$ChallengeContext.SessionId};if($ChallengeContext.PSObject.Properties['ContextId']){$contextId=[string]$ChallengeContext.ContextId};if($ChallengeContext.PSObject.Properties['Revision']){$contextRevision=[int]$ChallengeContext.Revision}}
    if($contextRole -cne 'Target' -or -not $contextActor -or $contextSession.Length -gt 256 -or $contextId.Length -gt 256 -or ($ChallengeContext -and $ChallengeContext.PSObject.Properties['OperationId'] -and [string]$ChallengeContext.OperationId -cne $ParentOperationId)){throw 'Service credential challenge must bind a valid Target actor/session context and parent operation id.'}
    $challenge=$null;$challengeCrossed=$false;if($state.PSObject.Properties['AssistiveServiceChallenge']){$challenge=$state.AssistiveServiceChallenge;if([string]$challenge.ParentOperationId -cne $ParentOperationId -and [string]$challenge.State -ceq 'Revoked'){$challenge=$null}}
    if($challenge){
        if([string]$challenge.ParentOperationId -cne $ParentOperationId){throw 'A prior Service credential challenge requires explicit owner takeover before another parent can resume it.'}
        if([string]$challenge.PairId -cne [string]$Package.Manifest.PairId -or [string]$challenge.ManifestHash -ine $ManifestHash -or [long]$challenge.Generation -ne [long]$Package.Manifest.Generation -or [string]$challenge.PreviewHash -ine [string]$Preview.WizardPreviewHash){throw 'Service credential challenge binding changed; refresh preview and establish a new reviewed operation.'}
        if($Continuation -and [string]$challenge.State -cin @('Cancelled','Revoked','Completed')){throw 'A cancelled, revoked or completed Service credential challenge cannot be resumed by a continuation.'}
        # A challenge still Running here already crossed the pre-write boundary (the caller proved otherwise and rebound it). It never asks for or replays a password; items that need one and are not yet owned fail closed.
        if($Continuation -and [string]$challenge.State -ceq 'Running'){$challengeCrossed=$true}
        else{
            if([string]$challenge.Actor -cne $contextActor -or [string]$challenge.Role -cne $contextRole -or [string]$challenge.SessionId -cne $contextSession -or [string]$challenge.ContextId -cne $contextId -or [int]$challenge.Revision -ne $contextRevision){throw 'Service credential challenge actor/session/revision changed; explicit takeover is required.'}
            if([string]$challenge.State -cne 'WaitingForInput'){throw 'Service credential challenge is not waiting for input and cannot be replayed.'}
        }
    }
    $preflightItemsById=@{};foreach($item in @($Package.Plan.Items)){$preflightItemsById[[string]$item.ItemId]=$item}
    $credentialAccountByRef=New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal);foreach($credentialItemId in @($credentialByItem.Keys)){$credentialRequirement=$credentialByItem[$credentialItemId];$credentialRef=[string]$credentialRequirement.SecretRef;if([string]::IsNullOrWhiteSpace($credentialRef)){throw 'A ready item requires a credential but has no reviewed SecretRef; review the item before restore.'};if($credentialAccountByRef.ContainsKey($credentialRef) -and [string]$credentialAccountByRef[$credentialRef] -ine [string]$credentialRequirement.ApprovedAccount){throw 'One SecretRef is shared by items with different reviewed accounts; use a separate SecretRef per account before restore.'};$credentialAccountByRef[$credentialRef]=[string]$credentialRequirement.ApprovedAccount}
    $expectedReviewedServiceRefs=@($credentialAccountByRef.Keys|ForEach-Object {[string]$_}|Sort-Object -Unique);$inputServiceRefs=@($Secrets.Keys|ForEach-Object {[string]$_}|Sort-Object -Unique);if(@($inputServiceRefs|Where-Object {$_ -cnotin $expectedReviewedServiceRefs}).Count){throw 'In-memory credential map contains a SecretRef outside the reviewed ready credential rows.'}
    # Durable per-group state: deferred groups are never asked for; attempts / last failure survive each return to WaitingForInput.
    $credentialState=Get-WsmAssistiveCredentialStateMap $challenge;$deferredRefs=New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal);foreach($stateRef in @($credentialState.Keys)){if($credentialState[$stateRef].Deferred){$deferredRefs[[string]$stateRef]=[string]$credentialState[$stateRef].DeferReason}}
    if(@($inputServiceRefs|Where-Object {$deferredRefs.ContainsKey($_)}).Count){throw 'A credential was supplied for a deferred SecretRef; deferred groups are not restored in this parent.'}
    $maxCredentialAttempts=Get-WsmAssistiveCredentialMaxAttempts;$rejectedItemRefs=@{};$repromptItemRefs=@{}
    $reservationOperationState='Running';if(-not $challengeCrossed -and @($expectedReviewedServiceRefs|Where-Object {$_ -cnotin $inputServiceRefs -and -not $deferredRefs.ContainsKey($_)}).Count){$reservationOperationState='WaitingForInput'}
    $serviceReservations=New-Object 'System.Collections.Generic.List[object]';$requiredSecretRefs=New-Object 'System.Collections.Generic.List[string]';$serviceSecretRefs=New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach($row in @($Preview.Rows|Where-Object Status -CEQ 'Ready')){
            $item=$preflightItemsById[[string]$row.ItemId];if(-not $item){continue}
            if($settledByParent.ContainsKey([string]$item.ItemId)){continue}
            if($item.MigrationSpec.Adapter -cne 'Service'){$otherRequirement=$credentialByItem[[string]$item.ItemId];if($otherRequirement){$serviceSecretRefs.Add([string]$otherRequirement.SecretRef);if($Secrets.ContainsKey([string]$otherRequirement.SecretRef)){Assert-WsmAssistiveCredentialAccount $otherRequirement $Secrets}elseif(-not $deferredRefs.ContainsKey([string]$otherRequirement.SecretRef)){$requiredSecretRefs.Add([string]$otherRequirement.SecretRef)}};continue}
            $spec=$item.MigrationSpec;$policy=Get-WsmServiceAccountPolicy $spec.Desired $spec
            if($policy.Mode -eq 'ManagedServiceAccount'){[void](Test-WsmServiceAccountTargetPreflight $policy)}
            elseif($policy.Mode -ceq 'UserPassword'){
                $serviceSecretRefs.Add([string]$policy.SecretRef)
                if($Secrets.ContainsKey([string]$policy.SecretRef)){[void](New-WsmServiceAccountCredential $policy $Secrets)}elseif(-not $deferredRefs.ContainsKey([string]$policy.SecretRef)){$requiredSecretRefs.Add([string]$policy.SecretRef)}
            }
            $reservations=@(Get-WsmAssistiveReservations $item $Package $StateDirectory -OperationId $ParentOperationId -OperationState $reservationOperationState)
            foreach($reservation in $reservations){$serviceReservations.Add([pscustomobject]@{ItemId=[string]$item.ItemId;ResourceKey=[string]$reservation.Preview.ResourceKey;Created=($null -ne $reservation.Reservation)})}
        }
    } catch {
        if(-not $challenge){
        foreach($reservation in @($serviceReservations.ToArray())) {
            try {
                Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State Released | Out-Null
                if($reservation.Created) {
                    $registry=Get-WsmAssistiveResourceRegistry $StateDirectory
                    $resource=@($registry.Resources | Where-Object ResourceKey -CEQ $reservation.ResourceKey | Select-Object -First 1)
                    $owner=$null
                    if($resource.Count){$owner=@($resource[0].Owners | Where-Object {$_.PairId -ceq $Package.Manifest.PairId -and $_.ItemId -ceq $reservation.ItemId -and $_.OperationId -ceq $ParentOperationId} | Select-Object -First 1)}
                    if($owner){Release-WsmAssistiveResource -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -Channel ([string]$owner[0].Channel) -ExpectedRevision $registry.Revision -Reason 'Service credential preflight rejected before native write' | Out-Null}
                }
            } catch { }
        }
        }
        throw
    }
    $expectedServiceRefs=@($serviceSecretRefs.ToArray()|Sort-Object -Unique);$providedServiceRefs=@($Secrets.Keys|ForEach-Object {[string]$_}|Sort-Object -Unique)
    if(@($providedServiceRefs|Where-Object {$_ -cnotin $expectedServiceRefs}).Count){throw 'In-memory credential map contains a SecretRef outside the reviewed ready Service rows.'}
    $activeServiceRefs=@($expectedServiceRefs|Where-Object {-not $deferredRefs.ContainsKey($_)})
    if($challenge -and -not $challengeCrossed){$challengeRefs=@($challenge.RequiredSecretRefs|Sort-Object -Unique);if(($challengeRefs -join "`n") -cne ($activeServiceRefs -join "`n")){throw 'Service credential challenge SecretRef set changed; explicit review is required.'};if(-not $requiredSecretRefs.Count -and ($providedServiceRefs -join "`n") -cne ($challengeRefs -join "`n")){throw 'Service credential challenge did not receive its exact reviewed SecretRef set.'}}
    $credentialRequirements=@(New-WsmAssistiveCredentialRequirementList $expectedServiceRefs $credentialByItem $preflightItemsById $credentialAccountByRef $credentialState)
    if($requiredSecretRefs.Count -and -not $challengeCrossed){
        foreach($reservation in @($serviceReservations.ToArray())){Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State WaitingForInput | Out-Null}
        $existingAttempt=$null;if($state.PSObject.Properties['RestoreAttempt']){$existingAttempt=$state.RestoreAttempt}
        if($existingAttempt){if([string]$existingAttempt.OperationId -cne $ParentOperationId -or [string]$existingAttempt.ManifestHash -ine $ManifestHash -or [long]$existingAttempt.Generation -ne [long]$Package.Manifest.Generation -or [string]$existingAttempt.DecisionReceiptHash -ine [string]$decision.ReceiptHash -or [string]$existingAttempt.TargetSnapshotHash -ine [string]$decision.Receipt.TargetSnapshotHash -or [string]$existingAttempt.WizardPreviewHash -ine [string]$Preview.WizardPreviewHash -or (@($existingAttempt.SelectedItemIds|Sort-Object -Unique)-join "`n") -cne (@($decision.SelectedItemIds|Sort-Object -Unique)-join "`n")){throw 'Durable TargetRestore parent changed before entering the Service credential challenge.'}}
        else{$existingAttempt=[pscustomobject][ordered]@{ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviousManifest=$state.ManifestHash;OperationId=$ParentOperationId;DecisionReceiptPath=[string]$decision.ReceiptPath;DecisionReceiptHash=[string]$decision.ReceiptHash;TargetSnapshotPath=[string]$decision.SnapshotPath;TargetSnapshotHash=[string]$decision.Receipt.TargetSnapshotHash;SelectedItemIds=@($decision.SelectedItemIds);WizardPreviewHash=[string]$Preview.WizardPreviewHash;MaterialJobOperationId='';MaterialIds=@();ItemResults=@();PreviewRowHashes=@(Get-WsmAssistivePreviewRowHashes $Preview.Rows);Status='WaitingForInput';CreatedUtc=(Get-WsmUtc)}}
        $state.ManifestHash=$ManifestHash;$state.Generation=[long]$Package.Manifest.Generation;$state.Stage='WaitingForInput';$state|Add-Member NoteProperty RestoreAttempt $existingAttempt -Force
        if(-not $challenge){$challenge=[pscustomobject][ordered]@{State='WaitingForInput';ParentOperationId=$ParentOperationId;PairId=[string]$Package.Manifest.PairId;Role=$contextRole;Actor=$contextActor;SessionId=$contextSession;ContextId=$contextId;Revision=[int]$contextRevision;ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviewHash=[string]$Preview.WizardPreviewHash;RequiredSecretRefs=$activeServiceRefs;Requirements=@($credentialRequirements);ServiceReservations=@($serviceReservations.ToArray());CreatedUtc=Get-WsmUtc;UpdatedUtc=Get-WsmUtc};$state|Add-Member NoteProperty AssistiveServiceChallenge $challenge -Force}else{$challenge.RequiredSecretRefs=$activeServiceRefs;$challenge|Add-Member NoteProperty Requirements @($credentialRequirements) -Force;$challenge.UpdatedUtc=Get-WsmUtc}
        # The journal row carries the non-secret challenge plus the RestoreAttempt snapshot so replay can rebuild both (J1).
        $waitingDetail=ConvertFrom-WsmJson ($challenge | ConvertTo-Json -Depth 40);$waitingDetail | Add-Member NoteProperty RestoreAttempt $state.RestoreAttempt -Force
        Add-WsmJournal $paths $state 'AssistiveServiceCredentialChallengeWaiting' '' $waitingDetail
        return [pscustomobject][ordered]@{Status='WaitingForInput';PairId=[string]$Package.Manifest.PairId;ParentOperationId=$ParentOperationId;RequiredSecretRefs=@($challenge.RequiredSecretRefs);CredentialRequirements=@($credentialRequirements);ServiceReservations=@($challenge.ServiceReservations);ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviewHash=[string]$Preview.WizardPreviewHash;Role=$contextRole;Actor=$contextActor;SessionId=$contextSession;ContextId=$contextId;Revision=[int]$contextRevision;NoTargetWrites=$true;ResumeRequired=$true;ProductionVerified=$false}
    }
    if($challenge){$challenge.State='Running';$challenge.UpdatedUtc=Get-WsmUtc;Add-WsmJournal $paths $state 'AssistiveServiceCredentialChallengeResuming' '' $challenge}
    if($Preview.PSObject.Properties['NonCFileResults'] -and @($Preview.NonCFileResults).Count){$state | Add-Member NoteProperty AssistiveFileResults @($Preview.NonCFileResults) -Force;Add-WsmJournal $paths $state 'AssistiveNonCFileResultsImported' '' ([pscustomobject]@{Generation=[long]$Package.Manifest.Generation;Rows=@($Preview.NonCFileResults)})}
    # Continuation: reconcile each unresolved native intent on its own. An item whose native result cannot be proven stays pending and blocks only itself and its explicit dependents.
    $unknownItems=@{};$blockedItems=@{};$pendingItemIds=@{}
    if($Continuation){
        foreach($pendingOp in @($state.PendingOperations)){$pendingItemIds[[string]$pendingOp.ItemId]=$true}
        if($pendingItemIds.Count){$unknownItems=Invoke-WsmAssistiveContinuationReconcile $Package $paths $state $SidMap $ManifestHash}
        $blockedItems=Get-WsmAssistiveUnknownDependencyBlocks @($Package.Plan.Items) $unknownItems
    }
    $job=Register-WsmAssistivePackageMaterials $Package $decision $StateDirectory $Preview
    $state.Stage='Running'
    # Only the same durable parent still waiting for input (or taken over before native writes) continues; an earlier finished or cancelled attempt never lends its identity to a new restore.
    $attempt=$null;if($state.PSObject.Properties['RestoreAttempt'] -and [string]$state.RestoreAttempt.OperationId -ceq $ParentOperationId -and [string]$state.RestoreAttempt.Status -cin @('WaitingForInput','Running')){$attempt=$state.RestoreAttempt}
    if(-not $attempt){$attempt=[pscustomobject]@{ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviousManifest=$state.ManifestHash;OperationId=$ParentOperationId;DecisionReceiptPath=[string]$decision.ReceiptPath;DecisionReceiptHash=[string]$decision.ReceiptHash;TargetSnapshotPath=[string]$decision.SnapshotPath;TargetSnapshotHash=[string]$decision.Receipt.TargetSnapshotHash;SelectedItemIds=@($decision.SelectedItemIds);WizardPreviewHash=$(if($Preview.PSObject.Properties['WizardPreviewHash']){[string]$Preview.WizardPreviewHash}else{''});ItemResults=@();PreviewRowHashes=@(Get-WsmAssistivePreviewRowHashes $Preview.Rows)}}
    $attempt|Add-Member NoteProperty MaterialJobOperationId $job.OperationId -Force;$attempt|Add-Member NoteProperty MaterialIds @($job.MaterialIds) -Force;$attempt|Add-Member NoteProperty Status 'Running' -Force;$attempt|Add-Member NoteProperty StartedUtc (Get-WsmUtc) -Force
    $state | Add-Member NoteProperty RestoreAttempt $attempt -Force
    Add-WsmJournal $paths $state 'AssistiveRestoreStarted' '' $attempt
    Confirm-WsmOutputStateCheckpoint -StateDirectory $StateDirectory -PairId $Package.Manifest.PairId -PlanHash $Package.Manifest.PlanHash
    $itemsById=@{};foreach($item in @($Package.Plan.Items)){$itemsById[[string]$item.ItemId]=$item}
    $itemResults=New-Object 'System.Collections.Generic.List[object]'
    $priorItemResults=@();if(($Continuation -or $parentWasWaiting) -and $attempt.PSObject.Properties['ItemResults']){$priorItemResults=@($attempt.ItemResults)}
    $cv2=Test-WsmAssistivePlanContractV2 $Package.Plan
    try { foreach($row in @($Preview.Rows)){
        if($settledByParent.ContainsKey([string]$row.ItemId)){continue}
        if($unknownItems.ContainsKey([string]$row.ItemId)){$unknownResult=[pscustomobject]@{ItemId=$row.ItemId;Status='NeedsReconciliation';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error=[string]$unknownItems[[string]$row.ItemId];NativeCode=$null};$itemResults.Add($unknownResult);Add-WsmJournal $paths $state 'AssistiveItemNeedsReconciliation' $row.ItemId $unknownResult;continue}
        if($blockedItems.ContainsKey([string]$row.ItemId)){$blockedResult=[pscustomobject]@{ItemId=$row.ItemId;Status='BlockedByUnknownDependency';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error=[string]$blockedItems[[string]$row.ItemId];NativeCode=$null};$itemResults.Add($blockedResult);Add-WsmJournal $paths $state 'AssistiveItemBlockedByUnknownDependency' $row.ItemId $blockedResult;continue}
        # The preview was computed before this item's own pending intent was reconciled; its stale conflict row must not hide the reconciled item.
        $stalePendingRow=($Continuation -and $pendingItemIds.ContainsKey([string]$row.ItemId) -and [string]$row.Status -cin @('BlockedConflict','Blocked'))
        if($row.Status -ne 'Ready' -and -not $stalePendingRow){if($row.Status -notin @('Deferred','DeferredSoftware')){$itemResults.Add([pscustomobject]@{ItemId=$row.ItemId;Status=$row.Status;CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error=$row.Reason})};continue}
        # A deferred SecretRef group never reaches the adapter: no intent, no native write; the item ends Deferred with the recorded reason.
        $deferredCredential=$credentialByItem[[string]$row.ItemId]
        if($deferredCredential -and $deferredRefs.ContainsKey([string]$deferredCredential.SecretRef)){
            $deferReason=[string]$deferredRefs[[string]$deferredCredential.SecretRef];if(-not $deferReason){$deferReason='CredentialDeferred'}
            $deferredResult=[pscustomobject]@{ItemId=$row.ItemId;Status='Deferred';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error=$deferReason;Reason=$deferReason;NativeCode=$null}
            $itemResults.Add($deferredResult);Add-WsmJournal $paths $state 'AssistiveItemCredentialDeferred' $row.ItemId ([pscustomobject]@{ItemId=$row.ItemId;SecretRef=[string]$deferredCredential.SecretRef;Reason=$deferReason});continue
        }
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveBeforeItem'
        Assert-WsmAssistiveReceiptFresh $Package $decision | Out-Null
        $item=$itemsById[[string]$row.ItemId];$spec=$item.MigrationSpec
        try{
            # Continuation without the secret an unfinished credential item needs: ask again under the current session instead of failing it. Already-existing owned objects only read back and never need it.
            if($Continuation -and $credentialByItem.ContainsKey([string]$item.ItemId) -and -not $Secrets.ContainsKey([string]$credentialByItem[[string]$item.ItemId].SecretRef) -and -not (Get-WsmAdapterState $spec).Exists){$repromptItemRefs[[string]$item.ItemId]=[string]$credentialByItem[[string]$item.ItemId].SecretRef;continue}
            $reservations=@();if(-not ($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC' -and -not $cv2)){$reservations=Get-WsmAssistiveReservations $item $Package $StateDirectory -OperationId $ParentOperationId}
            $priorRecord=@($state.Items | Where-Object ItemId -CEQ $item.ItemId);$undo=$null;if($priorRecord.Count){$undo=$priorRecord[0]}
            Add-WsmJournal $paths $state 'AssistiveItemStarted' $item.ItemId ([pscustomobject]@{Adapter=$spec.Adapter;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;DecisionReceiptHash=$decision.ReceiptHash})
            if($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC' -and -not $cv2){$fileRows=@($Preview.NonCFileResults|Where-Object ItemId -CEQ $item.ItemId);if(-not $fileRows.Count -or @($fileRows|Where-Object {$_.Status -notin @('Applied','DirectoryReady') -or -not $_.EffectivePath -or [long]$_.Generation -ne [long]$Package.Manifest.Generation}).Count){throw 'NonC result lost its exact-generation native readback before G acceptance.'};$result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=$false;ExternalOwnershipVerified=$true;OwnershipChannel='NonC';AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=(Get-WsmHashText ($fileRows|Sort-Object EntryId|ConvertTo-Json -Depth 20 -Compress));Target=$spec.TargetPath;OwnedFiles=@();OwnedDirectories=@();FileResults=$fileRows;Error='';NativeCode=0}}
            elseif($spec.Adapter -eq 'FileScope'){$result=Invoke-WsmAssistiveFileScopeRestore $item $Package $paths $state $SidMap $CancellationToken $StateDirectory}
            elseif($spec.Adapter -eq 'ManualWorkflow'){$result=[pscustomobject]@{ItemId=$item.ItemId;Status='ManualEvidenceRequired';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error='Dedicated owner procedure and accepted evidence are required.'}}
            else{
                $before=Get-WsmAdapterState $spec
                $prior=@($state.Items | Where-Object ItemId -CEQ $item.ItemId)
                if($spec.Adapter -ceq 'WindowsFeature' -and $before.Exists -and -not ($prior.Count -and $prior[0].CreatedByTool -and $prior[0].AppliedManifestHash -and $prior[0].Status -in @('Succeeded','Partial','RebootRequired'))){
                    if([string]$before.Name -ine [string]$spec.Desired.Name){throw 'Installed Windows feature name differs from the exact approved feature.'}
                    $check=Test-WsmAdapterConfiguration $spec Staged;if(-not $check.Passed){throw ('Preinstalled Windows feature verification failed: '+($check.Problems -join '; '))}
                    $actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress)
                    $result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=$false;AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=(Get-WsmAdapterObjectIdentity $spec);Backup='';Error='';NativeCode=0;OwnershipChannel='Preexisting'}
                }
                elseif($spec.Adapter -in @('IISSection','IISLocation')){
                    Assert-WsmAssistiveIisConfigSpec $spec
                    if(-not $before.Exists){throw 'Reviewed IIS section/location is unavailable on the target.'}
                    if($prior.Count -and (($prior[0].CreatedByTool) -or ($prior[0].PSObject.Properties['UpdatedByTool'] -and $prior[0].UpdatedByTool)) -and $prior[0].AppliedManifestHash -and $prior[0].Status -in @('Succeeded','Partial')){
                        $check=Test-WsmAdapterConfiguration $spec Staged
                        if(-not $check.Passed){throw ('Previously owned IIS section/location has drifted: '+($check.Problems -join '; '))}
                        $actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress)
                        $result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=[bool]$prior[0].CreatedByTool;UpdatedByTool=([bool]$prior[0].UpdatedByTool);AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=(Get-WsmAdapterObjectIdentity $spec);Backup='';Error='';NativeCode=0;PriorManifestHash=[string]$prior[0].AppliedManifestHash;Before=$prior[0].Before;PriorXml=[string]$prior[0].PriorXml;BeforeHash=[string]$prior[0].BeforeHash}
                    }else{
                        $candidate=Set-WsmIisConfigChanges (Read-WsmXml ([string]$before.Xml)) @($spec.Desired.Changes);$desired=Read-WsmXml ([string]$spec.Desired.Xml)
                        if((ConvertTo-WsmXmlComparable $candidate.DocumentElement) -cne (ConvertTo-WsmXmlComparable $desired.DocumentElement)){throw 'Reviewed IIS field changes do not produce the exact staged Desired.Xml.'}
                        $pending=[pscustomobject]@{ItemId=$item.ItemId;Phase='AssistiveAdapterCreating';Adapter=$spec.Adapter;ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;Before=$before;BeforeHash=(Get-WsmHashText ($before | ConvertTo-Json -Depth 30 -Compress));DesiredHash=(Get-WsmHashText ($spec.Desired | ConvertTo-Json -Depth 40 -Compress));AbsentBefore=$false;BootBefore='';InstallerBaselinePath='';InstallerBaselineHash='';FolderCreateIntents=@();AuxiliaryOwnership=@();UpdatedByTool=$true}
                        $state.PendingOperations=@($state.PendingOperations | Where-Object ItemId -CNE $item.ItemId)+@($pending);Add-WsmJournal $paths $state 'AssistiveAdapterIntent' $item.ItemId $pending
                        $nativeResult=Invoke-WsmAdapterRestore $spec $Secrets $Package -ReservationWorkspace $StateDirectory -ReservationOperationId $ParentOperationId
                        if(-not $nativeResult.PSObject.Properties['PriorXml'] -or [string]$nativeResult.PriorXml -cne [string]$before.Xml){throw 'Native IIS restore prior XML differs from the exact durable before-state; retain the pending intent for reconciliation.'}
                        $check=Test-WsmAdapterConfiguration $spec Staged;if(-not $check.Passed){throw ('Native IIS readback failed: '+($check.Problems -join '; '))}
                        $actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress)
                        $result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=$false;UpdatedByTool=$true;AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=(Get-WsmAdapterObjectIdentity $spec);Backup='';Error='';NativeCode=0;Before=$before;PriorXml=[string]$nativeResult.PriorXml;BeforeHash=(Get-WsmHashText ($before | ConvertTo-Json -Depth 30 -Compress))}
                    }
                }
                elseif($spec.PSObject.Properties['SettingTransition']){
                    $transitionReceipt=Invoke-WsmSettingTransitionForPhase $item $Package $paths $state StagedDependencyVerified
                    $actual=Get-WsmHashText ($transitionReceipt | ConvertTo-Json -Depth 30 -Compress)
                    $result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=[bool]$transitionReceipt.CreatedByTool;UpdatedByTool=[bool]$transitionReceipt.UpdatedByTool;AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=(Get-WsmAdapterObjectIdentity $spec);Backup='';Error='';NativeCode=0;SettingTransitionIntent=$transitionReceipt.Intent;SettingTransitionReceipt=$transitionReceipt;SettingTransitionDeferred=($spec.SettingTransition.RequiredPhase -eq 'CutoverReady')}
                }
                else{
                    if($before.Exists -and -not ($prior.Count -eq 1 -and $prior[0].CreatedByTool -and $prior[0].AppliedManifestHash)) {throw 'Existing target object is not owned by a verified prior Assistive generation.'}
                    if($before.Exists){$ownedReceipts=@();$allReceipts=@();if($spec.Adapter -ceq 'ScheduledTask'){$ifOwned=$prior[0].PSObject.Properties['AuxiliaryOwnership'];if($ifOwned){$ownedReceipts=@($prior[0].AuxiliaryOwnership)};$allReceipts=Get-WsmTaskSecurityReceiptsForSpec $spec (Get-WsmTaskSecurityOwnershipReceipts $state)};$check=Test-WsmAdapterConfiguration $spec Staged $allReceipts;if(-not $check.Passed){throw ('Prior owned object has drifted: '+($check.Problems -join '; '))};$actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress);$priorStatus='Succeeded';$priorBoot='';$priorBaselinePath='';$priorBaselineHash='';$priorSafety=$null;$priorInstallerResult=$null;if($prior[0].PSObject.Properties['BootBefore']){$priorBoot=[string]$prior[0].BootBefore};if($prior[0].PSObject.Properties['InstallerBaselinePath']){$priorBaselinePath=[string]$prior[0].InstallerBaselinePath};if($prior[0].PSObject.Properties['InstallerBaselineHash']){$priorBaselineHash=[string]$prior[0].InstallerBaselineHash};if($prior[0].PSObject.Properties['InstallerSafety']){$priorSafety=$prior[0].InstallerSafety};if($prior[0].PSObject.Properties['InstallerResult']){$priorInstallerResult=$prior[0].InstallerResult};if($spec.Adapter -eq 'WindowsFeature'){$baselineOperation=[pscustomobject]@{ItemId=$item.ItemId;InstallerBaselinePath=$priorBaselinePath;InstallerBaselineHash=$priorBaselineHash};$baseline=Read-WsmInstallerBaseline $baselineOperation $paths $item.ItemId;$priorSafety=Protect-WsmInstallerSideEffects $spec.Desired $baseline $StateDirectory ([string]$Package.Manifest.Target.Fingerprint);[void](Test-WsmInstallerConsumers $spec.Desired $priorSafety Staged);if($prior[0].Status -eq 'RebootRequired'){Assert-WsmRebootCompleted $prior[0]}};$result=[pscustomobject]@{ItemId=$item.ItemId;Status=$priorStatus;CreatedByTool=[bool]$prior[0].CreatedByTool;AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=(Get-WsmAdapterObjectIdentity $spec);Backup='';Error='';NativeCode=0;PriorManifestHash=[string]$prior[0].AppliedManifestHash;AuxiliaryOwnership=@($ownedReceipts);BootBefore=$priorBoot;InstallerBaselinePath=$priorBaselinePath;InstallerBaselineHash=$priorBaselineHash;InstallerSafety=$priorSafety;InstallerResult=$priorInstallerResult}}
                    else{
                        Assert-WsmAssistiveCredentialAvailable $spec $Secrets
                        $bootBefore='';$installerBaseline=$null;$installerBaselinePath='';$installerBaselineHash='';if($spec.Adapter -eq 'WindowsFeature'){$bootBefore=Get-WsmBootStamp;$installerBaseline=Get-WsmInstallerSnapshot;$installerBaselinePath=Join-Path $paths.Root ($item.ItemId+'.installer-baseline.json');Write-WsmJson $installerBaselinePath $installerBaseline;$installerBaselineHash=(Get-FileHash -LiteralPath $installerBaselinePath -Algorithm SHA256).Hash.ToLowerInvariant()}
                        $pending=[pscustomobject]@{ItemId=$item.ItemId;Phase='AssistiveAdapterCreating';Adapter=$spec.Adapter;ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;Before=$before;BeforeHash=(Get-WsmHashText ($before | ConvertTo-Json -Depth 30 -Compress));DesiredHash=(Get-WsmHashText ($spec.Desired | ConvertTo-Json -Depth 40 -Compress));AbsentBefore=$true;BootBefore=$bootBefore;InstallerBaselinePath=$installerBaselinePath;InstallerBaselineHash=$installerBaselineHash;FolderCreateIntents=@();AuxiliaryOwnership=@()}
                        $state.PendingOperations=@($state.PendingOperations | Where-Object ItemId -CNE $item.ItemId)+@($pending);Add-WsmJournal $paths $state 'AssistiveAdapterIntent' $item.ItemId $pending
                        $beforeFolderCreate={param($intent)$current=@($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId)[0];$current.FolderCreateIntents+=@($intent);$detail=[pscustomobject]@{ItemId=$item.ItemId;Adapter='ScheduledTask';ManifestHash=$ManifestHash;Phase='TaskFolderCreateIntent';Intent=$intent};Add-WsmJournal $paths $state 'TaskFolderCreateIntent' $item.ItemId $detail}
                        $afterFolderCreate={param($receipt)$current=@($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId)[0];$current.FolderCreateIntents=@($current.FolderCreateIntents | Where-Object OperationId -CNE $receipt.OperationId);$current.AuxiliaryOwnership+=@($receipt);$detail=[pscustomobject]@{ItemId=$item.ItemId;Adapter='ScheduledTask';ManifestHash=$ManifestHash;Phase='TaskFolderOwned';Receipt=$receipt};Add-WsmJournal $paths $state 'TaskFolderOwned' $item.ItemId $detail}
                        $ownedReceipts=@();$sharedReceipts=@();if($spec.Adapter -ceq 'ScheduledTask'){$allReceipts=Get-WsmTaskSecurityReceiptsForSpec $spec (Get-WsmTaskSecurityOwnershipReceipts $state);$ownedReceipts=@($pending.AuxiliaryOwnership);$sharedReceipts=@($allReceipts | Where-Object {$_.OperationId -notin @($ownedReceipts | ForEach-Object {$_.OperationId})})}
                        $nativeResult=Invoke-WsmAdapterRestore $spec $Secrets $Package $installerBaseline $beforeFolderCreate $afterFolderCreate $ownedReceipts $sharedReceipts $StateDirectory $ParentOperationId
                        $auxiliaryOwnership=@();if($nativeResult.PSObject.Properties['AuxiliaryOwnership']){$auxiliaryOwnership=@($nativeResult.AuxiliaryOwnership)}
                        $installerSafety=$null;$installerResult=$null;$reboot=[bool]$nativeResult.RebootRequired;if($spec.Adapter -eq 'WindowsFeature'){$installerSafety=$nativeResult.InstallerSafety;$installerResult=[pscustomobject]@{NativeTool='Install-WindowsFeature';NativeResult=$nativeResult.NativeResult;RestartNeeded=$nativeResult.RestartNeeded};[void](Test-WsmInstallerConsumers $spec.Desired $installerSafety Staged)}
                        $allReceipts=@();if($spec.Adapter -ceq 'ScheduledTask'){$allReceipts=Get-WsmTaskSecurityReceiptsForSpec $spec (Get-WsmTaskSecurityOwnershipReceipts $state)}
                        $check=Test-WsmAdapterConfiguration $spec Staged $allReceipts
                        if(-not $check.Passed){throw ('Native readback failed: '+($check.Problems -join '; '))}
                        $actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress)
                        $status='Succeeded';if($reboot){$status='RebootRequired'}
                        $result=[pscustomobject]@{ItemId=$item.ItemId;Status=$status;CreatedByTool=$true;AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=(Get-WsmAdapterObjectIdentity $spec);Backup='';Error='';NativeCode=0;Before=$before;BootBefore=$bootBefore;InstallerBaselinePath=$installerBaselinePath;InstallerBaselineHash=$installerBaselineHash;InstallerSafety=$installerSafety;InstallerResult=$installerResult;AuxiliaryOwnership=@($auxiliaryOwnership)}
                    }
                }
            }
            if(-not $result.PSObject.Properties['AppliedManifestHash']){$result | Add-Member NoteProperty AppliedManifestHash $ManifestHash}
            if(-not $result.PSObject.Properties['AppliedGeneration']){$result | Add-Member NoteProperty AppliedGeneration ([long]$Package.Manifest.Generation)}
            if($result.Status -eq 'Succeeded' -and -not $result.PSObject.Properties['ActualHash']){$result | Add-Member NoteProperty ActualHash ([string]$result.ActualHash)}
            if(@($reservations).Count){$desiredEvidence=$null;if($spec.Adapter -eq 'FileScope'){$desiredEvidence=@(Read-WsmArtifactLines (Join-Path $Package.Root 'artifacts.jsonl') $Package.Manifest.ArtifactsHash $CancellationToken | Where-Object ItemId -CEQ $item.ItemId | Select-Object RelativePath,Directory,Data,Metadata)}else{$desiredEvidence=$spec.Desired};$readback=$result;if($result.PSObject.Properties['OwnedFiles']){$readback=[pscustomobject]@{OwnedFiles=$result.OwnedFiles;OwnedDirectories=$result.OwnedDirectories;ActualHash=$result.ActualHash}};Set-WsmAssistiveReservationEvidence $reservations $item $Package $undo $desiredEvidence $readback $undo $StateDirectory;$result | Add-Member NoteProperty ResourceReservations @($reservations | ForEach-Object {$_.Preview.ResourceKey}) -Force}
            $state.PendingOperations=@($state.PendingOperations | Where-Object ItemId -CNE $item.ItemId)
            Clear-WsmAssistivePartialOwnership $state ([string]$item.ItemId)
            $state.Items=@($state.Items | Where-Object ItemId -CNE $item.ItemId)+@($result)
            $itemResults.Add($result)
            Add-WsmJournal $paths $state 'AssistiveItemCompleted' $item.ItemId $result
        } catch [OperationCanceledException] {throw} catch {
            $caughtFailure=$_
            # CredentialRejected only for a credential consumer whose single creating intent is proven side-effect free: a refusal-class error AND a fresh readback that
            # still finds no target object. Everything else keeps the pending intent below (repair / reconciliation) and never asks for the password again.
            $rejectedCredential=$credentialByItem[[string]$item.ItemId]
            if($rejectedCredential){
                $rejectedPending=@($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId)
                if($rejectedPending.Count -eq 1 -and [string]$rejectedPending[0].Phase -ceq 'AssistiveAdapterCreating' -and $rejectedPending[0].AbsentBefore -eq $true -and -not @($rejectedPending[0].FolderCreateIntents).Count -and -not @($rejectedPending[0].AuxiliaryOwnership).Count -and (Get-WsmAssistiveCredentialRejectionVerdict $caughtFailure $spec) -ceq 'Rejected'){
                    $state.PendingOperations=@($state.PendingOperations | Where-Object ItemId -CNE $item.ItemId)
                    $rejectedResult=[pscustomobject]@{ItemId=$item.ItemId;Status='CredentialRejected';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error='CredentialRejected';NativeCode=$null}
                    $itemResults.Add($rejectedResult);$rejectedItemRefs[[string]$item.ItemId]=[string]$rejectedCredential.SecretRef
                    Add-WsmJournal $paths $state 'AssistiveItemCredentialRejected' $item.ItemId ([pscustomobject]@{ItemId=$item.ItemId;SecretRef=[string]$rejectedCredential.SecretRef;Adapter=[string]$spec.Adapter})
                    continue
                }
            }
            $failed=[pscustomobject]@{ItemId=$item.ItemId;Status='Failed';CreatedByTool=(@($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId).Count -gt 0);AppliedManifestHash='';AppliedGeneration=0;Error=$_.Exception.GetType().FullName;NativeCode=$null}
            $state.Items=@($state.Items | Where-Object ItemId -CNE $item.ItemId)+@($failed);$itemResults.Add($failed)
            # Keep an ambiguous intent durable for repair; never erase it just because a native call threw.
            if(-not @($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId).Count){Add-WsmJournal $paths $state 'AssistiveItemFailed' $item.ItemId $failed}else{Add-WsmJournal $paths $state 'AssistiveItemNeedsRepair' $item.ItemId ([pscustomobject]@{Error=$failed.Error;Pending=@($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId)})}
        }
    }} catch [OperationCanceledException] {
        # A cancellation is a terminal worker outcome, but any completed item or
        # unresolved native intent remains authoritative in the state and journal.
        # Releasing the material lock records that this worker has stopped; it
        # does not repair or discard a pending operation.
        $state.ManifestHash=$ManifestHash;$state.Generation=[long]$Package.Manifest.Generation;$state.Stage='Cancelled'
        $cancelResults=@(Merge-WsmAssistiveItemResults $priorItemResults $itemResults.ToArray());$attempt.ItemResults=$cancelResults
        $cancel=[ordered]@{Status='Cancelled';ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;OperationId='';Boundary='';PendingOperationCount=[int]@($state.PendingOperations).Count}
        if($_.Exception.Data['OperationId']){$cancel.OperationId=[string]$_.Exception.Data['OperationId']}
        if($_.Exception.Data['CancellationBoundary']){$cancel.Boundary=[string]$_.Exception.Data['CancellationBoundary']}
        if($challenge){$challenge.State='Cancelled';$challenge.UpdatedUtc=Get-WsmUtc;foreach($reservation in @($serviceReservations.ToArray())){Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State Released | Out-Null}}
        $cancel['ItemResults']=@($cancelResults)
        Add-WsmJournal $paths $state 'AssistiveRestoreCancelled' '' ([pscustomobject]$cancel)
        Complete-WsmAssistivePackageJob $Package $job $StateDirectory
        return [pscustomobject]@{PairId=$Package.Manifest.PairId;ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;Stage='Cancelled';Items=$state.Items;Results=$cancelResults;Deferred=@($Preview.Rows | Where-Object Status -in @('Deferred','DeferredSoftware','Blocked','BlockedConflict','ManualEvidenceRequired'));PendingOperations=@($state.PendingOperations);JournalHash=$state.JournalHash;BusinessValidationRequired=$true;ProductionVerified=$false}
    }
    $credentialNotice=''
    if($rejectedItemRefs.Count -or $repromptItemRefs.Count){
        # Refused passwords with a proven no-effect failure: count the attempt per SecretRef. Below the limit the parent returns to WaitingForInput
        # (other settled items stay); at the limit the whole group is deferred and the rest of the restore finishes.
        $waitingRefs=New-Object 'System.Collections.Generic.List[string]';$limitRefs=New-Object 'System.Collections.Generic.List[string]';$rejectionSummary=@()
        foreach($rejectedRef in @($rejectedItemRefs.Values|Sort-Object -Unique)){
            $newAttempts=1;if($credentialState.ContainsKey($rejectedRef)){$newAttempts=[int]$credentialState[$rejectedRef].Attempts+1}
            $atLimit=($newAttempts -ge $maxCredentialAttempts)
            $credentialState[$rejectedRef]=[pscustomobject]@{Deferred=$atLimit;DeferReason=$(if($atLimit){'CredentialRejectedLimit'}else{''});LastFailure='CredentialRejected';Attempts=$newAttempts}
            if($atLimit){$limitRefs.Add($rejectedRef)}else{$waitingRefs.Add($rejectedRef)}
            $rejectionSummary+=@([pscustomobject]@{SecretRef=$rejectedRef;Attempts=$newAttempts;MaxAttempts=$maxCredentialAttempts;Deferred=$atLimit})
        }
        foreach($repromptRef in @($repromptItemRefs.Values|Sort-Object -Unique)){if(-not $waitingRefs.Contains([string]$repromptRef)){$waitingRefs.Add([string]$repromptRef)}}
        foreach($limitItemId in @($rejectedItemRefs.Keys|Where-Object {$rejectedItemRefs[$_] -cin $limitRefs.ToArray()})){
            $limitResult=[pscustomobject]@{ItemId=$limitItemId;Status='Deferred';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error='CredentialRejectedLimit';Reason='CredentialRejectedLimit';NativeCode=$null}
            for($resultIndex=0;$resultIndex -lt $itemResults.Count;$resultIndex++){if([string]$itemResults[$resultIndex].ItemId -ceq [string]$limitItemId){$itemResults[$resultIndex]=$limitResult}}
            Add-WsmJournal $paths $state 'AssistiveItemCredentialDeferred' $limitItemId ([pscustomobject]@{ItemId=$limitItemId;SecretRef=[string]$rejectedItemRefs[$limitItemId];Reason='CredentialRejectedLimit'})
        }
        if(-not $challenge){$challenge=[pscustomobject][ordered]@{State='Running';ParentOperationId=$ParentOperationId;PairId=[string]$Package.Manifest.PairId;Role=$contextRole;Actor=$contextActor;SessionId=$contextSession;ContextId=$contextId;Revision=[int]$contextRevision;ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviewHash=[string]$Preview.WizardPreviewHash;RequiredSecretRefs=@();Requirements=@();ServiceReservations=@();CreatedUtc=Get-WsmUtc;UpdatedUtc=Get-WsmUtc};$state|Add-Member NoteProperty AssistiveServiceChallenge $challenge -Force}
        $deferredAll=@($credentialState.Keys|Where-Object {$credentialState[$_].Deferred}|Sort-Object)
        $requirementRefs=@($expectedServiceRefs|Where-Object {$_ -cin $waitingRefs.ToArray() -or $_ -cin $deferredAll})
        $credentialRequirements=@(New-WsmAssistiveCredentialRequirementList $requirementRefs $credentialByItem $preflightItemsById $credentialAccountByRef $credentialState)
        $challenge|Add-Member NoteProperty Requirements @($credentialRequirements) -Force;$challenge|Add-Member NoteProperty DeferredSecretRefs @($deferredAll) -Force;$challenge.UpdatedUtc=Get-WsmUtc;if($repromptItemRefs.Count){$challenge|Add-Member NoteProperty Role $contextRole -Force;$challenge|Add-Member NoteProperty Actor $contextActor -Force;$challenge|Add-Member NoteProperty SessionId $contextSession -Force;$challenge|Add-Member NoteProperty ContextId $contextId -Force;$challenge|Add-Member NoteProperty Revision ([int]$contextRevision) -Force}
        if($limitRefs.Count){$credentialNotice=Get-WsmAssistiveCredentialLimitNotice;Add-WsmJournal $paths $state 'AssistiveServiceCredentialRejectedLimit' '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;SecretRefs=@($limitRefs.ToArray());MaxAttempts=$maxCredentialAttempts;Reason='CredentialRejectedLimit';ChallengeSnapshot=$challenge})}
        if($waitingRefs.Count){
            $waitingItemIds=@(@($rejectedItemRefs.Keys|Where-Object {$rejectedItemRefs[$_] -cin $waitingRefs.ToArray()})+@($repromptItemRefs.Keys))
            $priorReservations=@();if($challenge.PSObject.Properties['ServiceReservations']){$priorReservations=@($challenge.ServiceReservations)};$keptReservations=@()
            foreach($reservation in @($serviceReservations.ToArray())){
                if([string]$reservation.ItemId -cin $waitingItemIds){
                    Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State WaitingForInput | Out-Null
                    $keep=@($priorReservations|Where-Object {[string]$_.ItemId -ceq [string]$reservation.ItemId -and [string]$_.ResourceKey -ceq [string]$reservation.ResourceKey}|Select-Object -First 1);if($keep.Count){$keptReservations+=@($keep[0])}else{$keptReservations+=@($reservation)}
                }elseif(-not @($state.PendingOperations|Where-Object ItemId -CEQ $reservation.ItemId).Count){
                    Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State Released | Out-Null
                }
            }
            $challenge|Add-Member NoteProperty ServiceReservations @($keptReservations) -Force;$challenge|Add-Member NoteProperty RequiredSecretRefs @($waitingRefs.ToArray()|Sort-Object) -Force;$challenge.State='WaitingForInput'
            $waitingResults=@(Merge-WsmAssistiveItemResults $priorItemResults $itemResults.ToArray())
            $attempt|Add-Member NoteProperty ItemResults @($waitingResults) -Force;$attempt|Add-Member NoteProperty Status 'WaitingForInput' -Force
            $state.ManifestHash=$ManifestHash;$state.Generation=[long]$Package.Manifest.Generation;$state.Stage='WaitingForInput'
            $waitingAction='AssistiveServiceCredentialRejected';if(-not $rejectedItemRefs.Count){$waitingAction='AssistiveServiceCredentialReprompt'}
            Add-WsmJournal $paths $state $waitingAction '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;PairId=[string]$Package.Manifest.PairId;PreviewHash=[string]$Preview.WizardPreviewHash;Rejections=@($rejectionSummary);RequiredSecretRefs=@($challenge.RequiredSecretRefs);ChallengeSnapshot=$challenge;RestoreAttempt=$attempt})
            Complete-WsmAssistivePackageJob $Package $job $StateDirectory
            return [pscustomobject][ordered]@{Status='WaitingForInput';PairId=[string]$Package.Manifest.PairId;ParentOperationId=$ParentOperationId;RequiredSecretRefs=@($challenge.RequiredSecretRefs);CredentialRequirements=@($credentialRequirements);ServiceReservations=@($challenge.ServiceReservations);ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviewHash=[string]$Preview.WizardPreviewHash;Role=$contextRole;Actor=$contextActor;SessionId=$contextSession;ContextId=$contextId;Revision=[int]$contextRevision;NoTargetWrites=$false;ResumeRequired=$true;CredentialRejected=[bool]$rejectedItemRefs.Count;CredentialNotice=$credentialNotice;Results=@($waitingResults);ProductionVerified=$false}
        }
    }
    $state.ManifestHash=$ManifestHash;$state.Generation=[long]$Package.Manifest.Generation
    $finalResults=@(Merge-WsmAssistiveItemResults $priorItemResults $itemResults.ToArray());$attempt.ItemResults=$finalResults
    # A stale conflict row of an item whose own pending intent was just reconciled to success is not a remaining deferred row.
    $resolvedPendingIds=@{};if($Continuation){foreach($finalResult in $finalResults){if($pendingItemIds.ContainsKey([string]$finalResult.ItemId) -and [string]$finalResult.Status -cin @('Succeeded','RebootRequired')){$resolvedPendingIds[[string]$finalResult.ItemId]=$true}}}
    $remaining=@($Preview.Rows | Where-Object {$_.Status -in @('Deferred','DeferredSoftware','Blocked','BlockedConflict','ManualEvidenceRequired') -and -not $resolvedPendingIds.ContainsKey([string]$_.ItemId)})
    $failedCount=@($finalResults | Where-Object Status -in @('Failed','BlockedConflict','Blocked','ManualEvidenceRequired','NeedsReconciliation','BlockedByUnknownDependency','Deferred')).Count
    $state.Stage='Succeeded';if($remaining.Count -or $failedCount -or @($state.PendingOperations).Count){$state.Stage='Partial'};if(@($finalResults | Where-Object Status -EQ RebootRequired).Count){$state.Stage='RebootRequired'}
    if($challenge){$challenge.State='Completed';$challenge.UpdatedUtc=Get-WsmUtc}
    Add-WsmJournal $paths $state 'AssistiveRestoreCompleted' '' ([pscustomobject]@{Status=$state.Stage;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;DecisionReceiptHash=$decision.ReceiptHash;ItemResults=$finalResults;DeferredRows=$remaining})
    if($state.Stage -in @('Succeeded','Partial','RebootRequired') -and -not @($state.PendingOperations).Count){foreach($reservation in @($serviceReservations.ToArray())){Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State Released | Out-Null}}
    Complete-WsmAssistivePackageJob $Package $job $StateDirectory
    [pscustomobject]@{PairId=$Package.Manifest.PairId;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;Stage=$state.Stage;Items=$state.Items;Results=$finalResults;Deferred=$remaining;JournalHash=$state.JournalHash;CredentialNotice=$credentialNotice;BusinessValidationRequired=$true;ProductionVerified=$false}
}

# ---- Q1：還原後重新核對（唯讀）--------------------------------------------------------------------------------------------
# 安裝、重啟或權限變更可能改寫已還原的檔案或設定。這組函式只重查「最近一次還原中結果為 Succeeded 的項目」：
#   * 不寫入 Target、不覆寫、不刪除、不改 ACL、不開還原，也不改 state.json 與 journal；唯一的寫入是 <pair>\rechecks\ 下一筆內容定址的核對紀錄。
#   * FileScope：內容與擁有權沿用 Get-WsmFilePlacementPreview（OwnedFileDrift／AdoptedExisting／VerifiedOwned）的判定；metadata 用寫入器記下的 MetadataHash 與同一個 Get-WsmFileMetadata 重算。
#   * typed 設定：沿用各 adapter 既有的 Test-WsmAdapterConfiguration（Staged 或 Final 任一通過即吻合，與 Cutover 驗證相同）。
#   * 沒有 readback 能力、讀不到或沒有擁有紀錄的項目一律標 Unverifiable（無法自動核對），絕不當成吻合。
#   * AdoptedExisting（P10）：漂移只回報（ReportOnly），工具永遠不會覆寫或刪除它。
#   * 舊的成功結果不改寫：ItemResults 原樣留在 state；漂移只出現在核對紀錄與投影（Succeeded 降為 NeedsRecheck）。
function Get-WsmAssistiveRecheckAdapters {
    # 有原生 readback 比對（Test-WsmAdapterConfiguration）的 typed adapter；不在清單內（例如 ManualWorkflow）一律無法自動核對。
    @('ScheduledTask','Service','SmbShare','MachineEnvironment','TimeZone','WindowsFeature','LocalUser','LocalGroup','FirewallRule','Certificate','IISPool','IISSite','IISSection','IISLocation')
}
function Get-WsmAssistiveRecheckReasonText([string]$Code) {
    switch -CaseSensitive ($Code) {
        'Content' {return '內容已變動：目前檔案與還原時記錄的雜湊不同。'}
        'AdoptedExistingDrift' {return '沿用既有檔已變動：只回報，工具不會覆寫或刪除它。'}
        'Missing' {return '已不存在：還原過的檔案或資料夾已被移除。'}
        'Topology' {return '檔案結構異常（例如替代資料流）：保留原樣供人工檢視。'}
        'Acl' {return '權限（ACL）已變動：與還原時記錄的不同。'}
        'Metadata' {return '檔案屬性或時間戳已變動：與還原時記錄的不同。'}
        'Setting' {return '設定已變動：原生讀回與還原時的設定不同。'}
        'NoReadback' {return '無法自動核對：這個項目類型沒有自動讀回能力，請人工確認。'}
        'NonCChannel' {return '無法自動核對：這個項目的內容由另一台主機（非 C 通道）處理，本機沒有可重查的擁有紀錄。'}
        'NoOwnership' {return '無法自動核對：沒有可比對的擁有紀錄。'}
        'Unreadable' {return '無法自動核對：目前讀不到檔案或權限資訊。'}
        'ReadbackFailed' {return '無法自動核對：原生讀回失敗，不能當成吻合。'}
        'DeferredSetting' {return '無法自動核對：這個設定要到切換階段才會套用。'}
        default {return '無法自動核對。'}
    }
}
function New-WsmAssistiveRecheckReason([string]$Kind,[string]$Code,[string]$RelativePath='',[string]$Detail='',[bool]$ReportOnly=$false) {
    [pscustomobject][ordered]@{Kind=$Kind;Code=$Code;Text=(Get-WsmAssistiveRecheckReasonText $Code);RelativePath=$RelativePath;Detail=$Detail;ReportOnly=$ReportOnly}
}
function Test-WsmAssistiveRecheckFileScope($Item,$StateRow,[object[]]$PlacementRows,[object[]]$ArtifactRows,[hashtable]$SidMap) {
    $reasons=New-Object 'System.Collections.Generic.List[object]';$checked=0;$spec=$Item.MigrationSpec;$itemId=[string]$Item.ItemId
    if($StateRow -and $StateRow.PSObject.Properties['OwnershipChannel'] -and [string]$StateRow.OwnershipChannel -ceq 'NonC'){
        $reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'NonCChannel'));return [pscustomobject]@{Reasons=$reasons.ToArray();CheckedFiles=0}
    }
    $ownedFiles=@();$ownedDirectories=@()
    if($StateRow -and $StateRow.PSObject.Properties['OwnedFiles']){$ownedFiles=@($StateRow.OwnedFiles)}
    if($StateRow -and $StateRow.PSObject.Properties['OwnedDirectories']){$ownedDirectories=@($StateRow.OwnedDirectories)}
    if(-not $ownedFiles.Count -and -not $ownedDirectories.Count){
        $reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'NoOwnership'));return [pscustomobject]@{Reasons=$reasons.ToArray();CheckedFiles=0}
    }
    $aclPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$aclPolicy=[string]$spec.AclControlPolicy}
    foreach($file in $ownedFiles){
        $relative=[string]$file.RelativePath;$checked++;$adopted=[bool](Test-WsmAssistiveOwnedFileAdopted $file)
        $placement=@($PlacementRows | Where-Object {[string]$_.ItemId -ceq $itemId -and [string]$_.RelativePath -ceq $relative -and -not $_.Directory})
        if($placement.Count -ne 1){$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'NoOwnership' $relative 'placement row missing'));continue}
        $status=[string]$placement[0].PlacementStatus
        if($status -ceq 'OwnedFileDrift'){$reasons.Add((New-WsmAssistiveRecheckReason 'Drift' $(if($adopted){'AdoptedExistingDrift'}else{'Content'}) $relative '' $adopted));continue}
        if($status -ceq 'CanPlace'){$reasons.Add((New-WsmAssistiveRecheckReason 'Drift' 'Missing' $relative '' $adopted));continue}
        if($status -ceq 'BlockedConflict'){$reasons.Add((New-WsmAssistiveRecheckReason 'Drift' 'Topology' $relative '' $adopted));continue}
        if($status -ceq 'UnknownPermission'){$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'Unreadable' $relative));continue}
        if($status -cnotin @('VerifiedOwned','AdoptedExisting')){$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'NoOwnership' $relative ('placement '+$status)));continue}
        # 內容與擁有權吻合；再核對 metadata（與寫入器同一個 MetadataHash 與 Get-WsmFileMetadata）。
        $entry=@($ArtifactRows | Where-Object {[string]$_.ItemId -ceq $itemId -and [string]$_.RelativePath -ceq $relative -and -not $_.Directory})
        if($entry.Count -ne 1 -or -not $file.PSObject.Properties['MetadataHash'] -or -not [string]$file.MetadataHash){$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'NoOwnership' $relative 'no metadata baseline'));continue}
        $actual=$null;try{$actual=Get-WsmFileMetadata ([string]$file.TargetPath) ([string]$entry[0].Metadata.MetadataMode)}catch{$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'Unreadable' $relative));continue}
        if((Get-WsmAssistiveMetadataHash $actual) -ine [string]$file.MetadataHash){
            # 沿用既有檔從未套用過封存 ACL，不能拿封存 ACL 當基準；只有工具寫入的檔案才分出 ACL 與其他 metadata。
            $code='Metadata'
            if(-not $adopted){$aclSame=$false;try{$aclSame=[bool](Test-WsmSddlMatch (Convert-WsmMappedSddl ([string]$entry[0].Metadata.Sddl) $SidMap) ([string]$actual.Sddl) $aclPolicy)}catch{$aclSame=$false};if(-not $aclSame){$code='Acl'}}
            $reasons.Add((New-WsmAssistiveRecheckReason 'Drift' $code $relative '' $adopted))
        }
    }
    foreach($directory in $ownedDirectories){
        $relative=[string]$directory.RelativePath;$checked++;$path=[string]$directory.TargetPath
        if(-not [IO.Directory]::Exists($path)){$reasons.Add((New-WsmAssistiveRecheckReason 'Drift' 'Missing' $relative));continue}
        $entry=@($ArtifactRows | Where-Object {[string]$_.ItemId -ceq $itemId -and [string]$_.RelativePath -ceq $relative -and $_.Directory})
        $mode='DaclOwner';if($entry.Count -eq 1){$mode=[string]$entry[0].Metadata.MetadataMode}
        if(-not $directory.PSObject.Properties['CurrentMetadata'] -or -not $directory.CurrentMetadata){$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'NoOwnership' $relative 'no directory metadata baseline'));continue}
        $actual=$null;try{$actual=Get-WsmFileMetadata $path $mode}catch{$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'Unreadable' $relative));continue}
        # 目錄的最後寫入時間會隨裡面的檔案增減而變，不當成漂移；比對 ACL（含擁有者）與屬性。
        if([string]$actual.Sddl -cne [string]$directory.CurrentMetadata.Sddl){$reasons.Add((New-WsmAssistiveRecheckReason 'Drift' 'Acl' $relative))}
        elseif([int]$actual.Attributes -ne [int]$directory.CurrentMetadata.Attributes){$reasons.Add((New-WsmAssistiveRecheckReason 'Drift' 'Metadata' $relative))}
    }
    [pscustomobject]@{Reasons=$reasons.ToArray();CheckedFiles=$checked}
}
function Test-WsmAssistiveRecheckTyped($Item,$Result,$State) {
    $reasons=New-Object 'System.Collections.Generic.List[object]';$spec=$Item.MigrationSpec;$adapter=[string]$spec.Adapter
    if($adapter -cnotin @(Get-WsmAssistiveRecheckAdapters)){$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'NoReadback'))}
    elseif($Result.PSObject.Properties['SettingTransitionDeferred'] -and [bool]$Result.SettingTransitionDeferred){$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'DeferredSetting'))}
    else{
        try{
            $receipts=@();if($adapter -ceq 'ScheduledTask'){$receipts=@(Get-WsmTaskSecurityReceiptsForSpec $spec (Get-WsmTaskSecurityOwnershipReceipts $State))}
            $passed=$false;$stagedProblems=@()
            foreach($phase in @('Staged','Final')){$check=Test-WsmAdapterConfiguration $spec $phase $receipts;if($check.Passed){$passed=$true;break};if($phase -ceq 'Staged'){$stagedProblems=@($check.Problems)}}
            if(-not $passed){$detail=(@($stagedProblems|Select-Object -First 3|ForEach-Object {[string]$_}) -join '; ');if($detail.Length -gt 300){$detail=$detail.Substring(0,300)};$reasons.Add((New-WsmAssistiveRecheckReason 'Drift' 'Setting' '' $detail))}
        }catch{$reasons.Add((New-WsmAssistiveRecheckReason 'Unverifiable' 'ReadbackFailed' '' $_.Exception.GetType().FullName))}
    }
    [pscustomobject]@{Reasons=$reasons.ToArray();CheckedFiles=0}
}
function Get-WsmAssistiveRecheckSucceededTimes($Paths) {
    # 「曾成功於」的時間取自 journal 最後一筆該項目的 AssistiveItemCompleted；讀不到時呼叫端退回還原開始時間。
    $times=@{}
    try{foreach($journalEvent in @(Read-WsmJournalEvents $Paths)){$row=$journalEvent.Row;if($row -and [string]$row.Action -ceq 'AssistiveItemCompleted' -and $row.ItemId -and $row.PSObject.Properties['Detail'] -and $row.Detail -and $row.Detail.PSObject.Properties['Status'] -and [string]$row.Detail.Status -ceq 'Succeeded'){$times[[string]$row.ItemId]=[string]$row.Utc}}}catch{}
    $times
}
function Get-WsmAssistiveRestoreRecheck {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$StateDirectory,$CancellationToken=$null)
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash $CancellationToken
    Assert-WsmMigrationHost (Get-WsmMachineIdentity) $package.Manifest.Target.Fingerprint
    $pairId=[string]$package.Manifest.PairId;Assert-WsmId $pairId
    $statePath=Join-Path (Join-Path ([IO.Path]::GetFullPath($StateDirectory)) $pairId) 'state.json'
    if(-not [IO.File]::Exists($statePath)){throw 'There is no restore state to recheck for this pair.'}
    $paths=Get-WsmOperationPaths $StateDirectory $pairId;$state=Get-WsmOperationState $paths $package
    if(-not $state.PSObject.Properties['RestoreAttempt'] -or -not $state.RestoreAttempt){throw 'There is no restore attempt to recheck for this pair.'}
    $attempt=$state.RestoreAttempt
    if([string]$state.Stage -cnotin @('Succeeded','Partial','RebootRequired')){throw ('Recheck needs a finished restore; the current stage is '+[string]$state.Stage+'.')}
    if([string]$attempt.ManifestHash -ine $ExpectedHash -or [long]$attempt.Generation -ne [long]$package.Manifest.Generation){throw 'The latest restore attempt belongs to another package generation.'}
    $attemptResults=@();if($attempt.PSObject.Properties['ItemResults']){$attemptResults=@($attempt.ItemResults)}
    $itemResultsHash=Get-WsmHashText ($attemptResults|ConvertTo-Json -Depth 100 -Compress)
    $planItems=@{};foreach($planItem in @($package.Plan.Items)){$planItems[[string]$planItem.ItemId]=$planItem}
    $succeeded=@($attemptResults | Where-Object {$_ -and $_.PSObject.Properties['ItemId'] -and $_.PSObject.Properties['Status'] -and [string]$_.Status -ceq 'Succeeded' -and $planItems.ContainsKey([string]$_.ItemId)})
    $skippedCount=@($attemptResults).Count-$succeeded.Count
    $stateRows=@{};foreach($row in @($state.Items)){if($row -and $row.PSObject.Properties['ItemId']){$stateRows[[string]$row.ItemId]=$row}}
    $fileItems=@($succeeded | Where-Object {[string]$planItems[[string]$_.ItemId].MigrationSpec.Adapter -ceq 'FileScope'})
    $placementRows=@();$artifactRows=@()
    if($fileItems.Count){
        $placementRows=@((Get-WsmFilePlacementPreview -ManifestPath $ManifestPath -ExpectedHash $ExpectedHash -StateDirectory $StateDirectory).Rows)
        $artifactRows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash $CancellationToken)
    }
    $times=Get-WsmAssistiveRecheckSucceededTimes $paths;$startedUtc='';if($attempt.PSObject.Properties['StartedUtc']){$startedUtc=[string]$attempt.StartedUtc}
    $items=New-Object 'System.Collections.Generic.List[object]'
    foreach($result in $succeeded){
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveRecheckItem'
        $itemId=[string]$result.ItemId;$item=$planItems[$itemId];$adapter=[string]$item.MigrationSpec.Adapter;$stateRow=$null;if($stateRows.ContainsKey($itemId)){$stateRow=$stateRows[$itemId]}
        $outcome=$null
        if($adapter -ceq 'FileScope'){$outcome=Test-WsmAssistiveRecheckFileScope $item $stateRow $placementRows $artifactRows @{}}
        else{$outcome=Test-WsmAssistiveRecheckTyped $item $result $state}
        $reasons=@($outcome.Reasons);$status='Matched'
        if(@($reasons|Where-Object Kind -CEQ 'Drift').Count){$status='NeedsRecheck'}elseif($reasons.Count){$status='Unverifiable'}
        $succeededUtc=$startedUtc;if($times.ContainsKey($itemId)){$succeededUtc=[string]$times[$itemId]}
        $items.Add([pscustomobject][ordered]@{ItemId=$itemId;Name=[string]$item.Name;Adapter=$adapter;PreviousStatus='Succeeded';SucceededUtc=$succeededUtc;Status=$status;CheckedFiles=[int]$outcome.CheckedFiles;Reasons=$reasons})
    }
    $rows=$items.ToArray()
    [pscustomobject][ordered]@{Kind='PostRestoreRecheck';PairId=$pairId;PlanHash=[string]$package.Manifest.PlanHash;ManifestHash=([string]$ExpectedHash).ToLowerInvariant();Generation=[long]$package.Manifest.Generation;RestoreAttemptId=[string]$attempt.OperationId;DecisionReceiptHash=[string]$attempt.DecisionReceiptHash;AttemptTargetSnapshotHash=[string]$attempt.TargetSnapshotHash;ItemResultsHash=$itemResultsHash;StateStage=[string]$state.Stage;CheckedUtc=(Get-WsmUtc);Summary=[pscustomobject][ordered]@{Checked=$rows.Count;Matched=@($rows|Where-Object Status -CEQ 'Matched').Count;NeedsRecheck=@($rows|Where-Object Status -CEQ 'NeedsRecheck').Count;Unverifiable=@($rows|Where-Object Status -CEQ 'Unverifiable').Count;NotInScope=$skippedCount};Items=$rows;ReadOnly=$true}
}
function Get-WsmAssistiveRecheckRecords($Paths) {
    # 核對紀錄是內容定址的唯讀檔（檔名＝內容 SHA-256），依 Sequence 排序；檔名與內容不符、格式不對或別的 Pair 的一律略過，不信任。
    $root=Join-Path $Paths.Root 'rechecks';if(-not [IO.Directory]::Exists($root)){return @()}
    Assert-WsmNoReparse $root
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)){
        try{
            Assert-WsmNoReparse $file.FullName;if($file.Length -gt 4194304){continue}
            $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();if([IO.Path]::GetFileNameWithoutExtension($file.Name) -cne $hash){continue}
            $record=Read-WsmTrustedJson $file.FullName $hash
            if([string]$record.Kind -cne 'WizardTargetRecheck' -or [int]$record.SchemaVersion -ne 1 -or [string]$record.PairId -cne [string](Split-Path -Leaf $Paths.Root)){continue}
            $rows.Add([pscustomobject]@{Path=$file.FullName;SHA256=$hash;Sequence=[long]$record.Sequence;Record=$record})
        }catch{}
    }
    @($rows.ToArray() | Sort-Object Sequence)
}
function Get-WsmAssistiveLatestRecheck($Paths,[string]$AttemptId,[string]$ItemResultsHash) {
    # 只認綁定這次還原嘗試、且 ItemResults 雜湊仍相同的最新一筆；嘗試換了或結果變了，舊的核對紀錄不再套用到目前結果。
    $matches=@(Get-WsmAssistiveRecheckRecords $Paths | Where-Object {[string]$_.Record.RestoreAttemptId -ceq $AttemptId -and [string]$_.Record.ItemResultsHash -ieq $ItemResultsHash})
    if($matches.Count){return $matches[$matches.Count-1]}
    $null
}
function Save-WsmAssistiveRecheckRecord($Paths,$Check,[string]$ObservedSnapshotHash='') {
    $root=New-WsmOutputOwnedDirectory (Join-Path $Paths.Root 'rechecks')
    Invoke-WsmLocked $Paths.Root {
        $existing=@(Get-WsmAssistiveRecheckRecords $Paths);$sequence=[long]1;$previous=''
        if($existing.Count){$sequence=[long]$existing[$existing.Count-1].Sequence+1;$previous=[string]$existing[$existing.Count-1].SHA256}
        $record=[ordered]@{SchemaVersion=1;Kind='WizardTargetRecheck';Sequence=$sequence;PreviousRecheckHash=$previous}
        foreach($property in $Check.PSObject.Properties){if($property.Name -cne 'Kind'){$record[$property.Name]=$property.Value}}
        $record['ObservedSnapshotHash']=$ObservedSnapshotHash
        $json=([pscustomobject]$record) | ConvertTo-Json -Depth 40
        $bytes=[Text.Encoding]::UTF8.GetBytes($json)
        $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $path=Join-Path $root ($hash+'.json');Assert-WsmNoReparse $path
        if([IO.File]::Exists($path)){throw 'A recheck record with these exact bytes already exists.'}
        $temporary=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.tmp')
        try{$stream=[IO.File]::Open($temporary,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};[IO.File]::Move($temporary,$path)}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hash){throw 'The recheck record changed while it was being retained.'}
        [pscustomobject]@{Path=[IO.Path]::GetFullPath($path);SHA256=$hash;Sequence=$sequence;PreviousRecheckHash=$previous}
    }
}
function Get-WsmAssistiveRecheckCliRows($Check) {
    # CLI／文字備援的輸出列：每個核對項目一列，待核對與無法自動核對的原因逐條列出。
    @(foreach($item in @($Check.Items)){
        $label=switch -CaseSensitive ([string]$item.Status){'NeedsRecheck'{'待核對'}'Unverifiable'{'無法自動核對'}default{'吻合'}}
        $reasonText=(@($item.Reasons|ForEach-Object {$text=[string]$_.Text;if($_.RelativePath){$text=[string]$_.RelativePath+'：'+$text};$text}) -join '；')
        [pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Name=[string]$item.Name;Status=[string]$item.Status;StatusText=$label;Reason=$reasonText}
    })
}
function Invoke-WsmTargetRestoreRecheck {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$StateDirectory,[string]$ObservedSnapshotHash='',$CancellationToken=$null)
    $check=Get-WsmAssistiveRestoreRecheck -ManifestPath $ManifestPath -ExpectedHash $ExpectedHash -StateDirectory $StateDirectory -CancellationToken $CancellationToken
    $paths=Get-WsmOperationPaths $StateDirectory $check.PairId
    $saved=Save-WsmAssistiveRecheckRecord $paths $check $ObservedSnapshotHash
    $outcome='Matched';if($check.Summary.NeedsRecheck){$outcome='NeedsRecheck'}elseif($check.Summary.Unverifiable){$outcome='Unverifiable'}elseif(-not $check.Summary.Checked){$outcome='NothingToCheck'}
    # Status 只用 Get-WsmOperationStatusCode 已認得的狀態：全部吻合是 Succeeded，其餘（待核對、無法自動核對）都要人看，是 ReviewRequired。
    $status='ReviewRequired';if($outcome -cin @('Matched','NothingToCheck')){$status='Succeeded'}
    [pscustomobject][ordered]@{Kind='PostRestoreRecheck';Status=$status;Outcome=$outcome;PairId=[string]$check.PairId;PlanHash=[string]$check.PlanHash;ManifestHash=[string]$check.ManifestHash;Generation=[long]$check.Generation;RestoreAttemptId=[string]$check.RestoreAttemptId;DecisionReceiptHash=[string]$check.DecisionReceiptHash;ItemResultsHash=[string]$check.ItemResultsHash;CheckedUtc=[string]$check.CheckedUtc;Summary=$check.Summary;Items=@($check.Items);Rows=@(Get-WsmAssistiveRecheckCliRows $check);RecordPath=[string]$saved.Path;RecordHash=[string]$saved.SHA256;Sequence=[long]$saved.Sequence;ReadOnly=$true;NoTargetWrites=$true;ProductionVerified=$false}
}

function Get-WsmAssistiveRestoreParentId($State) {
    if($State -and $State.PSObject.Properties['RestoreAttempt'] -and $State.RestoreAttempt -and $State.RestoreAttempt.PSObject.Properties['OperationId']){return [string]$State.RestoreAttempt.OperationId}
    ''
}
# In-flight FileScope ownership: durable per file / per created directory, scoped to one parent operation + manifest + generation.
function Get-WsmAssistivePartialOwnership($State,$Item,$Package,[string]$Kind) {
    $parent=Get-WsmAssistiveRestoreParentId $State
    if(-not $parent -or -not $State.PSObject.Properties['AssistivePartialOwnership']){return @()}
    @($State.AssistivePartialOwnership | Where-Object {$_ -and [string]$_.ItemId -ceq [string]$Item.ItemId -and [string]$_.Kind -ceq $Kind -and [string]$_.ParentOperationId -ceq $parent -and [string]$_.ManifestHash -ieq [string]$Package.SHA256 -and [long]$_.Generation -eq [long]$Package.Manifest.Generation -and $_.Record})
}
function Set-WsmAssistivePartialOwnership($State,$Item,$Package,[string]$Kind,$Record) {
    $parent=Get-WsmAssistiveRestoreParentId $State;if(-not $parent){return}
    $kept=@();if($State.PSObject.Properties['AssistivePartialOwnership']){$kept=@($State.AssistivePartialOwnership | Where-Object {$_ -and -not ([string]$_.ItemId -ceq [string]$Item.ItemId -and [string]$_.Kind -ceq $Kind -and [string]$_.RelativePath -ceq [string]$Record.RelativePath)})}
    $entry=[pscustomobject][ordered]@{ItemId=[string]$Item.ItemId;Kind=$Kind;RelativePath=[string]$Record.RelativePath;ParentOperationId=$parent;ManifestHash=[string]$Package.SHA256;Generation=[long]$Package.Manifest.Generation;Record=$Record}
    $State | Add-Member NoteProperty AssistivePartialOwnership (@($kept)+@($entry)) -Force
}
function Clear-WsmAssistivePartialOwnership($State,[string]$ItemId) {
    if($State.PSObject.Properties['AssistivePartialOwnership']){$State.AssistivePartialOwnership=@($State.AssistivePartialOwnership | Where-Object {$_ -and [string]$_.ItemId -cne $ItemId})}
}

function Invoke-WsmAssistiveFileScopeRestore($Item,$Package,$Paths,$State,[hashtable]$SidMap,$CancellationToken,[string]$Workspace='') {
    $spec=$Item.MigrationSpec;$target=ConvertTo-WsmCanonicalPath $spec.TargetPath;if($Package.PSObject.Properties['Plan']){Assert-WsmOfflineFullSetOriginalLocation $Package.Plan $spec};if(-not [IO.Directory]::Exists([IO.Path]::GetPathRoot($target))){throw 'Target volume for the original location is not available; prepare the same location and recheck.'};$mediaOverlap=Get-WsmAssistiveBackupMediaOverlapReason $target $Package;if($mediaOverlap){throw $mediaOverlap};Assert-WsmNoReparse $target;Assert-WsmAssistiveTargetScopeTopology -Path $target -Spec $spec -TargetRoot $target -Kind Root
    $index=Join-Path $Package.Root 'artifacts.jsonl';$entries=@(Read-WsmArtifactLines $index $Package.Manifest.ArtifactsHash $CancellationToken | Where-Object {$_.ItemId -ceq $Item.ItemId});if(-not $entries.Count){throw 'Approved FileScope has no package artifacts.'}
    $singleFileScope=($entries.Count -eq 1 -and -not $entries[0].Directory -and [string]::IsNullOrEmpty([string]$entries[0].RelativePath));$restoreRoot=$target;$createdDirs=New-Object 'System.Collections.Generic.List[string]'
    if($singleFileScope){if([IO.Directory]::Exists($target)){throw 'A directory occupies the approved single-file target.'};$restoreRoot=[IO.Path]::GetDirectoryName($target);Assert-WsmNoReparse $restoreRoot;if(-not [IO.Directory]::Exists($restoreRoot)){[void][IO.Directory]::CreateDirectory($restoreRoot)}}
    else{if([IO.File]::Exists($target)){throw 'A file occupies the approved FileScope directory.'};if(-not [IO.Directory]::Exists($target)){[void][IO.Directory]::CreateDirectory($target);$createdDirs.Add($target)};Assert-WsmAssistiveTargetScopeTopology -Path $target -Spec $spec -TargetRoot $target -Kind Root}
    $prior=@($State.Items | Where-Object ItemId -CEQ $Item.ItemId);$ownedFiles=@();$ownedDirectories=@()
    if($prior.Count){if(Test-WsmAssistiveFileScopeOwnershipIncomplete $State ([string]$Item.ItemId)){throw 'Prior schema 3 FileScope ownership data is incomplete; preserve and reconcile.'};$ownedFiles=@($prior[0].OwnedFiles);if($prior[0].PSObject.Properties['OwnedDirectories']){$ownedDirectories=@($prior[0].OwnedDirectories)}}
    $results=New-Object 'System.Collections.Generic.List[object]';$nextFiles=New-Object 'System.Collections.Generic.List[object]';foreach($f in $ownedFiles){$nextFiles.Add($f)}
    $nextDirectories=New-Object 'System.Collections.Generic.List[object]';foreach($d in $ownedDirectories){$nextDirectories.Add($d)}
    $partialDirectories=@(Get-WsmAssistivePartialOwnership $State $Item $Package 'Directory')
    foreach($partialFile in @(Get-WsmAssistivePartialOwnership $State $Item $Package 'File')){$partialRecord=$partialFile.Record;$known=@($nextFiles | Where-Object RelativePath -CEQ ([string]$partialRecord.RelativePath));if(-not $known.Count){$nextFiles.Add($partialRecord)}elseif([long]$partialRecord.Generation -gt [long]$known[0].Generation){[void]$nextFiles.Remove($known[0]);$nextFiles.Add($partialRecord)}}
    $directoriesToApply=New-Object 'System.Collections.Generic.List[object]';$blockedDirectoryPaths=New-Object 'System.Collections.Generic.List[string]';$aclPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$aclPolicy=[string]$spec.AclControlPolicy}
    foreach($entry in @($entries | Where-Object Directory | Sort-Object {if($_.RelativePath){$_.RelativePath.Split([char]92).Count}else{0}})){
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveDirectoryCreate'
        $path=$target;if($entry.RelativePath){$path=Join-Path $target $entry.RelativePath};Assert-WsmNoReparse $path
        if([IO.File]::Exists($path)){ $results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='A file occupies the required directory path.'});continue }
        $directoryOwner=@($nextDirectories | Where-Object RelativePath -CEQ ([string]$entry.RelativePath));if($directoryOwner.Count -gt 1){throw 'Duplicate per-directory ownership record.'}
        $adoptPartialDirectory=$false;if(-not $directoryOwner.Count){$partialDirectory=@($partialDirectories | Where-Object {[string]$_.Record.RelativePath -ceq [string]$entry.RelativePath});if($partialDirectory.Count -eq 1 -and [IO.Directory]::Exists($path)){try{$adoptPartialDirectory=(([IO.Directory]::GetCreationTimeUtc($path).Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)) -ceq [string]$partialDirectory[0].Record.CreationTicksUtc)}catch{$adoptPartialDirectory=$false}}}
        $newDirectory=($createdDirs -contains $path) -or -not [IO.Directory]::Exists($path) -or $adoptPartialDirectory;if(-not [IO.Directory]::Exists($path)){[void][IO.Directory]::CreateDirectory($path);$createdDirs.Add($path)};if($newDirectory){Set-WsmAssistivePartialOwnership $State $Item $Package 'Directory' ([pscustomobject][ordered]@{RelativePath=[string]$entry.RelativePath;TargetPath=$path;CreationTicksUtc=[IO.Directory]::GetCreationTimeUtc($path).Ticks.ToString([Globalization.CultureInfo]::InvariantCulture);CreatedByTool=$true;Generation=[long]$Package.Manifest.Generation})};Assert-WsmAssistiveTargetScopeTopology -Path $path -Spec $spec -TargetRoot $target -Artifact $entry -Kind Directory -Destination $path
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
        if(-not [IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent);$createdDirs.Add($parent)};if($spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -cin @('ExactFiles','ExactMembers')){Assert-WsmAssistiveTargetScopeTopology -Path $parent -Spec $spec -TargetRoot $target -Artifact $entry -Kind Directory -Destination $dest}
        $owners=@($nextFiles | Where-Object RelativePath -CEQ $entry.RelativePath);if($owners.Count -gt 1){throw 'Duplicate per-file ownership record.'};$owner=$null;if($owners.Count){$owner=$owners[0]}
        $priorMetadataForBackup=$null
        # R3：目標已有檔案時的判定與預覽、Repair 共用 Get-WsmAssistiveExistingFileDisposition（目錄範圍才允許沿用同內容的外部檔；單檔範圍維持 BlockedConflict）。
        $disposition=Get-WsmAssistiveExistingFileDisposition $spec $target $entry $dest $owner (-not $singleFileScope)
        if($disposition.Disposition -ceq 'Directory'){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='A directory occupies the required file path.'});continue}
        if($disposition.Disposition -cne 'Absent'){
            if($disposition.Disposition -ceq 'ConflictUnverifiable'){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Existing file topology is unsupported or could not be verified safely.'});continue}
            if(-not $owner){
                if($disposition.Disposition -ceq 'ConflictDifferent'){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason=(Get-WsmAssistiveDifferentContentConflictReason)});continue}
                if($disposition.Disposition -ceq 'Adopt'){
                    # 同內容的外部檔：記為沿用既有檔，不重寫、不改 ACL；回復時不刪除（語意同 P10）。
                    try{$adoptedMetadata=Get-WsmFileMetadata $dest ([string]$entry.Metadata.MetadataMode);$adoptedRecord=New-WsmAssistiveAdoptedFileRecord ([string]$entry.RelativePath) $dest ([string]$disposition.ContentHash) $adoptedMetadata ([long]$Package.Manifest.Generation)}catch{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Existing file metadata is unreadable; it is preserved and not adopted.'});continue}
                    $nextFiles=@($nextFiles | Where-Object RelativePath -CNE $entry.RelativePath)+@($adoptedRecord)
                    $results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='VerifiedOwned';MetadataStatus='NotApplied';Reason=(Get-WsmAssistiveAdoptedExistingNote)});continue
                }
                $results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Existing external file is preserved; matching bytes do not grant tool ownership.'});continue
            }
            $current=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
            if($current -ine [string]$owner.SHA256){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason=$(if(Test-WsmAssistiveOwnedFileAdopted $owner){'Adopted existing file changed after it was adopted; it is only reported and is never overwritten.'}else{'Owned file drifted since its last verified generation.'})});continue}
            if(-not $owner.PSObject.Properties['MetadataHash']){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Prior owned file has no metadata readback baseline; preserve it and reconcile.'});continue}
            try{$priorMetadata=Get-WsmFileMetadata $dest $entry.Metadata.MetadataMode;if((Get-WsmAssistiveMetadataHash $priorMetadata) -ine [string]$owner.MetadataHash){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Owned file metadata drifted since its last verified generation.'});continue};$priorMetadataForBackup=$priorMetadata}catch{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Owned file metadata is unreadable; preserve it and reconcile.'});continue}
            if(Test-WsmAssistiveOwnedFileAdopted $owner){if($current -ieq [string]$entry.Data.Hash){$owner.Generation=[long]$Package.Manifest.Generation;$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='VerifiedOwned';MetadataStatus='NotApplied';Reason=(Get-WsmAssistiveAdoptedExistingNote)})}else{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Adopted existing file differs from the current package; it is preserved and never overwritten.'})};continue}
            if($current -ieq [string]$entry.Data.Hash){try{$actualMetadata=Assert-WsmAssistiveMetadataReadback $dest $entry.Metadata $SidMap $aclPolicy;$owner.MetadataHash=Get-WsmAssistiveMetadataHash $actualMetadata;$owner.Generation=[long]$Package.Manifest.Generation;$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='VerifiedOwned';MetadataStatus='Verified';Reason='Owned file bytes and required metadata match the current package.'})}catch{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Owned file metadata drifted from the current package; preserve it and reconcile.'})};continue}
        }elseif(Test-WsmAssistiveOwnedFileAbsentConflict $owner ([IO.File]::Exists($dest))){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason=(Get-WsmAssistiveOwnedFileAbsentReason)});continue}
        $staging=$dest+'.wsm-'+[Guid]::NewGuid().ToString('N')+'.tmp';$backup='';$previousHash='';$expectedHash=[string]$entry.Data.Hash
        $pending=[pscustomobject]@{ItemId=$Item.ItemId;Phase='AssistiveFileReplace';ManifestHash=$Package.SHA256;Generation=[long]$Package.Manifest.Generation;RelativePath=[string]$entry.RelativePath;Target=$dest;Staging=$staging;Backup='';PreviousHash='';PreviousMetadataHash=$(if($owner){[string]$owner.MetadataHash}else{''});PreviousMetadata=$priorMetadataForBackup;ExpectedHash=$expectedHash;ExpectedMetadata=$entry.Metadata;WasOwned=[bool]$owner;PriorOwner=$owner}
        $State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)+@($pending);Add-WsmJournal $Paths $State 'AssistiveFileIntent' $Item.ItemId $pending
        try{
            Restore-WsmPayloadBytes $entry $Package.Root $staging $CancellationToken
            Assert-WsmAssistiveTargetScopeTopology -Path $staging -Spec $spec -TargetRoot $target -Artifact $entry -Kind Staging -Destination $dest
            if((Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash -ine $expectedHash){throw 'Staged file hash differs from the sealed artifact.'}
            Set-WsmFileMetadata $staging $entry.Metadata $SidMap
            [void](Assert-WsmAssistiveMetadataReadback $staging $entry.Metadata $SidMap $aclPolicy)
            $backupMaterialId=''
            if($owner){
                $previousHash=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant();$backup=$dest+'.wsm-assistive-backup-'+$Item.ItemId.Substring(0,12)+'-'+[Guid]::NewGuid().ToString('N');$pending.PreviousHash=$previousHash;$pending.Backup=$backup;Add-WsmJournal $Paths $State 'AssistiveFilePrepared' $Item.ItemId $pending
                Assert-WsmAssistiveTargetScopeTopology -Path $dest -Spec $spec -TargetRoot $target -Artifact $entry -Kind File -Destination $dest -TrustedExistingHash $previousHash;$preMoveMetadata=Get-WsmFileMetadata $dest $entry.Metadata.MetadataMode;if($previousHash -ine [string]$owner.SHA256 -or (Get-WsmAssistiveMetadataHash $preMoveMetadata) -ine [string]$owner.MetadataHash){throw 'Owned file changed after preflight; do not move or replace it.'}
                [IO.File]::Move($dest,$backup)
                Assert-WsmAssistiveTargetScopeTopology -Path $backup -Spec $spec -TargetRoot $target -Artifact $entry -Kind Backup -Destination $dest -TrustedExistingHash $previousHash
                if($Workspace -and (Get-Command Register-WsmAssistiveMaterialReference -ErrorAction SilentlyContinue)){$material=Register-WsmAssistiveMaterialReference -Workspace $Workspace -PairId $Package.Manifest.PairId -Generation ([int]$Package.Manifest.Generation) -Path $backup -SHA256 $previousHash -Kind 'AssistiveOwnedFilePriorBackup' -ConsumerRefs @([string]$Item.ItemId);$backupMaterialId=[string]$material.MaterialId;$pending | Add-Member NoteProperty BackupMaterialId $backupMaterialId -Force;Add-WsmJournal $Paths $State 'AssistiveFileBackupRetained' $Item.ItemId ([pscustomobject]@{Backup=$backup;SHA256=$previousHash;MaterialId=$backupMaterialId;Generation=$Package.Manifest.Generation})}
                try{[IO.File]::Move($staging,$dest)}catch{if([IO.File]::Exists($backup) -and -not [IO.File]::Exists($dest)){[IO.File]::Move($backup,$dest)};throw}
            }else{[IO.File]::Move($staging,$dest)}
            Assert-WsmAssistiveTargetScopeTopology -Path $dest -Spec $spec -TargetRoot $target -Artifact $entry -Kind File -Destination $dest
            if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ine $expectedHash){throw 'Target file readback hash differs after replacement.'}
            $actualMetadata=Assert-WsmAssistiveMetadataReadback $dest $entry.Metadata $SidMap $aclPolicy
            $record=[pscustomobject]@{RelativePath=[string]$entry.RelativePath;TargetPath=$dest;SHA256=$expectedHash;MetadataHash=(Get-WsmAssistiveMetadataHash $actualMetadata);Backup=$backup;BackupHash=$previousHash;BackupMetadata=$priorMetadataForBackup;BackupMetadataHash=$(if($owner){[string]$owner.MetadataHash}else{''});BackupMaterialId=$backupMaterialId;Generation=[long]$Package.Manifest.Generation}
            $nextFiles=@($nextFiles | Where-Object RelativePath -CNE $entry.RelativePath)+@($record)
            $State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)
            Set-WsmAssistivePartialOwnership $State $Item $Package 'File' $record
            Add-WsmJournal $Paths $State 'AssistiveFileCompleted' $Item.ItemId ([pscustomobject]@{ItemId=$Item.ItemId;Record=$record;Target=$dest})
            $results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='Applied';MetadataStatus='Verified';Reason=''})
        }catch [OperationCanceledException] {throw}catch{
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
    # Parent ACL application can propagate inheritable ACEs to files already read back.
    # Reverify final bytes and sealed metadata after all directories, then persist only
    # a policy-verified final ownership baseline; never adopt an unexplained drift.
    foreach($fileEntry in @($entries)){
        $successfulFileResult=@($results | Where-Object {$_.RelativePath -ceq [string]$fileEntry.RelativePath -and $_.Status -in @('Applied','VerifiedOwned','DirectoryVerified')})
        if(-not $successfulFileResult.Count){continue}
        $ownedCollection=if($fileEntry.Directory){$nextDirectories}else{$nextFiles};$finalOwned=@($ownedCollection | Where-Object RelativePath -CEQ ([string]$fileEntry.RelativePath))
        if($finalOwned.Count -ne 1 -or [long]$finalOwned[0].Generation -ne [long]$Package.Manifest.Generation){continue}
        if(-not $fileEntry.Directory -and (Test-WsmAssistiveOwnedFileAdopted $finalOwned[0])){continue}
        try{
            $finalPath=[string]$finalOwned[0].TargetPath;if($fileEntry.Directory){Assert-WsmAssistiveFileTopology $finalPath}else{Assert-WsmAssistiveTargetScopeTopology -Path $finalPath -Spec $spec -TargetRoot $target -Artifact $fileEntry -Kind File -Destination $finalPath}
            if(-not $fileEntry.Directory -and (Get-FileHash -LiteralPath $finalPath -Algorithm SHA256).Hash -ine [string]$fileEntry.Data.Hash){throw 'File bytes changed while parent directory metadata was applied.'}
            $finalMetadata=Assert-WsmAssistiveMetadataReadback $finalPath $fileEntry.Metadata $SidMap $aclPolicy
            $finalOwned[0].MetadataHash=Get-WsmAssistiveMetadataHash $finalMetadata;if($fileEntry.Directory){$finalOwned[0].CurrentMetadata=$finalMetadata}
        }catch{
            foreach($priorResult in @($results | Where-Object RelativePath -CEQ ([string]$fileEntry.RelativePath))){[void]$results.Remove($priorResult)}
            $results.Add([pscustomobject]@{RelativePath=$fileEntry.RelativePath;Status='Failed';MetadataStatus='FinalReadbackFailed';Reason=$_.Exception.GetType().FullName})
        }
    }
    $statuses=@($results | ForEach-Object Status);$blocked=@($statuses | Where-Object {$_ -eq 'BlockedConflict'}).Count;$failed=@($statuses | Where-Object {$_ -in @('Failed','DirectoryVerified') -and $_ -eq 'Failed'}).Count
    $status='Succeeded';if($blocked){$status='BlockedConflict'}elseif($failed){$status='Failed'}
    $fileArray=@();foreach($fileRecord in $nextFiles){$fileArray+=@($fileRecord)};$directoryArray=@();foreach($directoryRecord in $nextDirectories){$directoryArray+=@($directoryRecord)}
    $record=[pscustomobject]@{ItemId=$Item.ItemId;Status=$status;CreatedByTool=$true;AppliedManifestHash=$Package.SHA256;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=(Get-WsmAssistiveFileOwnershipHash $fileArray);Target=$target;OwnedFiles=$fileArray;OwnedDirectories=$directoryArray;FileResults=$results.ToArray();Error='';NativeCode=0}
    $record
}
