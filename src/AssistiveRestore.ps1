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
        $spec=$item.MigrationSpec;$action='RestoreNow';$status='Ready';$reason='';$cv2=[bool]($package.Plan.PSObject.Properties['Assistive'] -and $package.Plan.Assistive -and $package.Plan.Assistive.PSObject.Properties['ContractVersion'] -and [int]$package.Plan.Assistive.ContractVersion -eq 2);$locationError='';$readiness=Get-WsmAssistiveWorkloadReadiness $item
        if($decision.Receipt.Decision -eq 'WaitForInstall'){$action='WaitForInstall';$status='DeferredSoftware';$reason='Owner chose to wait for target preparation; no target writes will occur.'}
        elseif($readiness.Status -ne 'Ready'){$action=$readiness.Status;$status=$readiness.Status;$reason=$readiness.Reason}
        else{
            $itemIssues=@(Get-WsmAssistiveItemDependencyIssues $issues ([string]$item.ItemId))
            if($itemIssues.Count -and @($decision.Receipt.AcceptedUnpreparedItemIds | Where-Object {$_ -ceq $item.ItemId}).Count -eq 0){$action='DeferredSoftware';$status='DeferredSoftware';$reason=(@($itemIssues | ForEach-Object Issue | Select-Object -Unique) -join '; ')}
            elseif($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'External'){$action='ExternalManual';$status='ManualEvidenceRequired';$reason='This selected workload depends on an external/non-C location; retain the source reference and complete the reviewed owner-managed transfer/readback procedure.'}
            elseif($spec.Adapter -eq 'FileScope' -and $cv2 -and ($locationError=$(try{Assert-WsmOfflineFullSetOriginalLocation $package.Plan $spec;''}catch{$_.Exception.Message}))){$action='BlockedLocation';$status='Blocked';$reason=$locationError}
            elseif($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC' -and -not $cv2){$action='DeferredNonC';$status='Deferred';$reason='Required non-C content must have a current trusted D result and live readback before G can mark the workload complete.';if($nonCError){$reason='D evidence validation/readback remains incomplete: '+$nonCError};if($nonCRows.ContainsKey([string]$item.ItemId)){$nonc=$nonCRows[[string]$item.ItemId];$status=[string]$nonc.Status;$reason=[string]$nonc.Reason;if($status -ceq 'Ready'){$action='AcceptVerifiedNonC';$reason='D result is bound to the final package and every required native target file/directory has verified live readback.'}else{$action='DeferredNonC'}}}
            elseif($spec.Adapter -eq 'FileScope'){
                $target=ConvertTo-WsmCanonicalPath $spec.TargetPath
                try{
                    $artifactRows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash $CancellationToken | Where-Object ItemId -CEQ $item.ItemId);$singleFileScope=($artifactRows.Count -eq 1 -and -not $artifactRows[0].Directory -and [string]::IsNullOrEmpty([string]$artifactRows[0].RelativePath));$requiredBytes=[long]0;foreach($row in @($artifactRows | Where-Object {-not $_.Directory})){if($row.PSObject.Properties['Data'] -and $row.Data -and $row.Data.PSObject.Properties['Bytes']){$requiredBytes+=[long]$row.Data.Bytes}};$gap=Get-WsmAssistiveTargetLocationGap $target $requiredBytes
                    if($gap){$action=$gap.Action;$status=$gap.Status;$reason=$gap.Reason}else{
                    Assert-WsmNoReparse $target
                    Assert-WsmAssistiveTargetScopeTopology -Path $target -Spec $spec -TargetRoot $target -Kind Root
                    foreach($artifact in $artifactRows){$artifactTarget=$target;if(-not $singleFileScope -and $artifact.RelativePath){$artifactTarget=Join-Path $target ([string]$artifact.RelativePath)};if([IO.File]::Exists($artifactTarget) -or [IO.Directory]::Exists($artifactTarget)){if($artifact.Directory){Assert-WsmAssistiveTargetScopeTopology -Path $artifactTarget -Spec $spec -TargetRoot $target -Artifact $artifact -Kind Directory -Destination $artifactTarget}else{$trustedExistingHash='';$priorItems=@($state.Items|Where-Object ItemId -CEQ $item.ItemId);if($priorItems.Count -eq 1 -and $priorItems[0].PSObject.Properties['OwnedFiles']){$priorOwners=@($priorItems[0].OwnedFiles|Where-Object {$_.RelativePath -ceq [string]$artifact.RelativePath -and $_.TargetPath -ieq $artifactTarget});if($priorOwners.Count -eq 1){$trustedExistingHash=[string]$priorOwners[0].SHA256}};Assert-WsmAssistiveTargetScopeTopology -Path $artifactTarget -Spec $spec -TargetRoot $target -Artifact $artifact -Kind File -Destination $artifactTarget -TrustedExistingHash $trustedExistingHash}}}
                    if($singleFileScope){
                        if([IO.Directory]::Exists($target)){$action='BlockedConflict';$status='BlockedConflict';$reason='A directory occupies the approved single-file target.'}
                        elseif([IO.File]::Exists($target)){$prior=@($state.Items|Where-Object ItemId -CEQ $item.ItemId);$owner=$null;if($prior.Count -eq 1 -and $prior[0].PSObject.Properties['OwnedFiles']){$matches=@($prior[0].OwnedFiles|Where-Object {$_.RelativePath -ceq '' -and $_.TargetPath -ieq $target});if($matches.Count -eq 1){$owner=$matches[0]}};$current=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant();if(-not $owner -or $current -ine [string]$owner.SHA256){$action='BlockedConflict';$status='BlockedConflict';$reason='Existing single-file target is not owned by an exact prior generation.'}elseif($current -ceq [string]$artifactRows[0].Data.Hash){$map=Resolve-WsmIdentityMap $package.Plan @{};$aclPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$aclPolicy=[string]$spec.AclControlPolicy};[void](Assert-WsmAssistiveMetadataReadback $target $artifactRows[0].Metadata $map $aclPolicy);$action='VerifyOwnedSingleFile';$status='Ready';$reason='Exact owned single-file bytes and required metadata match the approved artifact.'}else{$action='ReplaceOwnedSingleFile';$status='Ready';$reason='Exact prior single-file ownership is verified; preserve a rollback copy before replacement.'}}
                        else{$parent=[IO.Path]::GetDirectoryName($target);Assert-WsmNoReparse $parent;$action='CreateSingleFile';$status='Ready';$reason='Approved single-file target is absent; its parent directory will be retained or created without applying source-directory metadata.'}
                    }elseif([IO.File]::Exists($target)){$action='BlockedConflict';$status='BlockedConflict';$reason='A file occupies the approved directory target.'}
                    elseif([IO.Directory]::Exists($target)){$action='MergeIntoExistingDirectory';$status='Ready';$reason='Existing directories are retained; only new files and verified tool-owned unchanged files may be written.'}
                    }
                }
                catch{$action='Blocked';$status='Blocked';$reason='Target path could not be verified safely.'}
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
        $previewRow=[pscustomobject]@{ItemId=$item.ItemId;Name=$item.Name;Adapter=$spec.Adapter;Action=$action;Status=$status;Reason=$reason;Rollback='Per-item journal; exact owned state only';RebootPossible=($spec.Adapter -eq 'WindowsFeature')};$previewCredential=$null;if([string]$spec.Adapter -cin @('Service','ScheduledTask','IISPool')){try{$previewCredential=Get-WsmAdapterCredentialRequirement $spec}catch{$previewCredential=$null}};if($previewCredential){$previewRow|Add-Member NoteProperty CredentialRequired $true;$previewRow|Add-Member NoteProperty CredentialKind ([string]$previewCredential.Kind)};$rows.Add($previewRow)
    }
    $decisionBlocked=($decision.Receipt.Decision -eq 'RestoreNow' -and -not $decision.Snapshot)
    if($decisionBlocked){$problems.Add([pscustomobject]@{ItemId='';Reason='Target decision receipt requires a trusted target snapshot file.'})}
    $nonCFileResults=@(foreach($itemId in $nonCRows.Keys){foreach($fileResult in @($nonCRows[$itemId].FileResults)){$fileResult}})
    [pscustomobject]@{PairId=$package.Manifest.PairId;ManifestHash=$ExpectedHash;Generation=$package.Manifest.Generation;PlanHash=$package.Manifest.PlanHash;Mode='AssistivePerItem';ScopeMode='Assistive';Decision=$decision.Receipt.Decision;DecisionReceiptHash=$decision.ReceiptHash;SelectedItemIds=@($decision.SelectedItemIds);Rows=$rows.ToArray();NonCFileResults=$nonCFileResults;Problems=$problems.ToArray();GeneralHostIssues=$issues;NonCTransferPlanPath=$NonCTransferPlanPath;NonCTransferPlanHash=$NonCTransferPlanHash;NonCResultPath=$NonCResultPath;NonCResultHash=$NonCResultHash;NonCEvidenceIssue=$nonCError;Blocked=($decisionBlocked -or @($rows | Where-Object Status -EQ 'Blocked').Count -gt 0);CanRestoreIndependentItems=(@($rows | Where-Object Status -EQ 'Ready').Count -gt 0);NoOp=($rows.Count -eq 0);BusinessValidationRequired=$true;ProductionVerified=$false}
}

function Get-WsmAssistiveTargetLocationGap([string]$TargetPath,[long]$RequiredBytes) {
    $root=[IO.Path]::GetPathRoot($TargetPath)
    if(-not [IO.Directory]::Exists($root)){return [pscustomobject]@{Action='PrepareSameLocation';Status='Deferred';Reason=('目標主機缺少 '+$root+' 磁碟或掛載點；請準備相同位置後重新檢查。工具不會改寫到其他磁碟。')}}
    if((Get-WsmAvailableBytes $root) -lt ($RequiredBytes + 256MB)){return [pscustomobject]@{Action='AddTargetCapacity';Status='Deferred';Reason=('目標磁碟 '+$root+' 可用空間不足（需要約 '+[math]::Ceiling($RequiredBytes/1MB)+' MiB）；請釋出空間後重新檢查。')}}
    return $null
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
function Invoke-WsmAssistiveRestore($Package,[string]$ManifestHash,[string]$StateDirectory,[hashtable]$Secrets,[hashtable]$SidMap,$CancellationToken,[object[]]$GeneralHostEvidence,[string]$ReceiptPath,[string]$ReceiptHash,[string]$TargetSnapshotPath,$Preview,[string]$ParentOperationId='', [object]$ChallengeContext=$null) {
    $paths=Get-WsmOperationPaths $StateDirectory $Package.Manifest.PairId
    $state=Get-WsmOperationState $paths $Package
    if($state.Cutover){throw 'Restore after cutover requires reviewed data reconciliation; no automatic reverse synchronization.'}
    if(@($state.PendingOperations).Count){throw 'Interrupted Assistive item operation needs Repair-WsmOperation before retry.'}
    $decision=Get-WsmAssistiveRestoreDecision $Package $ManifestHash $ReceiptPath $ReceiptHash $TargetSnapshotPath
    if($decision.Receipt.Decision -eq 'WaitForInstall'){return $Preview}
    Assert-WsmAssistiveReceiptFresh $Package $decision | Out-Null
    if(-not $decision.ReceiptPath -or -not $decision.ReceiptHash -or -not $decision.SnapshotPath -or -not $decision.Receipt.TargetSnapshotHash){throw 'Assistive restore decision has no canonical receipt and target snapshot references.'}
    $serviceRows=New-Object 'System.Collections.Generic.List[object]';$serviceItemIds=@{};foreach($serviceItem in @($Package.Plan.Items|Where-Object {$_.MigrationSpec.Adapter -ceq 'Service'})){$serviceItemIds[[string]$serviceItem.ItemId]=$true};foreach($serviceRow in @($Preview.Rows)){if([string]$serviceRow.Status -ceq 'Ready' -and $serviceItemIds.ContainsKey([string]$serviceRow.ItemId)){$serviceRows.Add($serviceRow)}}
    $preflightItemsById=@{};foreach($item in @($Package.Plan.Items)){$preflightItemsById[[string]$item.ItemId]=$item}
    $credentialByItem=@{};foreach($row in @($Preview.Rows|Where-Object Status -CEQ 'Ready')){$item=$preflightItemsById[[string]$row.ItemId];if(-not $item){continue};$credentialRequirement=$null;if($item.MigrationSpec.Adapter -ceq 'Service'){$policy=Get-WsmServiceAccountPolicy $item.MigrationSpec.Desired $item.MigrationSpec;if($policy.Mode -ceq 'UserPassword'){$credentialRequirement=[pscustomobject][ordered]@{Kind='Service';SecretRef=[string]$policy.SecretRef;ApprovedAccount=[string]$policy.CanonicalAccount}}}elseif($item.MigrationSpec.Adapter -cin @('ScheduledTask','IISPool')){try{$credentialRequirement=Get-WsmAdapterCredentialRequirement $item.MigrationSpec}catch{$credentialRequirement=$null}};if($credentialRequirement){$credentialByItem[[string]$item.ItemId]=$credentialRequirement}}
    $ParentOperationId=Resolve-WsmAssistiveRestoreParentOperationId $ParentOperationId $CancellationToken -RequireDurableParent:([bool]($serviceRows.Count -or $credentialByItem.Count))
    $contextRole='Target';$contextActor=[string](Get-WsmExecutionActor);$contextSession='';$contextId='';$contextRevision=-1
    if($ChallengeContext){if($ChallengeContext.PSObject.Properties['Role']){$contextRole=[string]$ChallengeContext.Role};if($ChallengeContext.PSObject.Properties['Actor']){$contextActor=[string]$ChallengeContext.Actor};if($ChallengeContext.PSObject.Properties['SessionId']){$contextSession=[string]$ChallengeContext.SessionId};if($ChallengeContext.PSObject.Properties['ContextId']){$contextId=[string]$ChallengeContext.ContextId};if($ChallengeContext.PSObject.Properties['Revision']){$contextRevision=[int]$ChallengeContext.Revision}}
    if($contextRole -cne 'Target' -or -not $contextActor -or $contextSession.Length -gt 256 -or $contextId.Length -gt 256 -or ($ChallengeContext -and $ChallengeContext.PSObject.Properties['OperationId'] -and [string]$ChallengeContext.OperationId -cne $ParentOperationId)){throw 'Service credential challenge must bind a valid Target actor/session context and parent operation id.'}
    $challenge=$null;if($state.PSObject.Properties['AssistiveServiceChallenge']){$challenge=$state.AssistiveServiceChallenge;if([string]$challenge.ParentOperationId -cne $ParentOperationId){throw 'A prior Service credential challenge requires explicit owner takeover before another parent can resume it.'};if([string]$challenge.PairId -cne [string]$Package.Manifest.PairId -or [string]$challenge.ManifestHash -ine $ManifestHash -or [long]$challenge.Generation -ne [long]$Package.Manifest.Generation -or [string]$challenge.PreviewHash -ine [string]$Preview.WizardPreviewHash){throw 'Service credential challenge binding changed; refresh preview and establish a new reviewed operation.'};if([string]$challenge.Actor -cne $contextActor -or [string]$challenge.Role -cne $contextRole -or [string]$challenge.SessionId -cne $contextSession -or [string]$challenge.ContextId -cne $contextId -or [int]$challenge.Revision -ne $contextRevision){throw 'Service credential challenge actor/session/revision changed; explicit takeover is required.'};if([string]$challenge.State -cne 'WaitingForInput'){throw 'Service credential challenge is not waiting for input and cannot be replayed.'}}
    $preflightItemsById=@{};foreach($item in @($Package.Plan.Items)){$preflightItemsById[[string]$item.ItemId]=$item}
    $credentialAccountByRef=New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal);foreach($credentialItemId in @($credentialByItem.Keys)){$credentialRequirement=$credentialByItem[$credentialItemId];$credentialRef=[string]$credentialRequirement.SecretRef;if([string]::IsNullOrWhiteSpace($credentialRef)){throw 'A ready item requires a credential but has no reviewed SecretRef; review the item before restore.'};if($credentialAccountByRef.ContainsKey($credentialRef) -and [string]$credentialAccountByRef[$credentialRef] -ine [string]$credentialRequirement.ApprovedAccount){throw 'One SecretRef is shared by items with different reviewed accounts; use a separate SecretRef per account before restore.'};$credentialAccountByRef[$credentialRef]=[string]$credentialRequirement.ApprovedAccount}
    $expectedReviewedServiceRefs=@($credentialAccountByRef.Keys|ForEach-Object {[string]$_}|Sort-Object -Unique);$inputServiceRefs=@($Secrets.Keys|ForEach-Object {[string]$_}|Sort-Object -Unique);if(@($inputServiceRefs|Where-Object {$_ -cnotin $expectedReviewedServiceRefs}).Count){throw 'In-memory credential map contains a SecretRef outside the reviewed ready credential rows.'};$reservationOperationState='Running';if(@($expectedReviewedServiceRefs|Where-Object {$_ -cnotin $inputServiceRefs}).Count){$reservationOperationState='WaitingForInput'}
    $serviceReservations=New-Object 'System.Collections.Generic.List[object]';$requiredSecretRefs=New-Object 'System.Collections.Generic.List[string]';$serviceSecretRefs=New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach($row in @($Preview.Rows|Where-Object Status -CEQ 'Ready')){
            $item=$preflightItemsById[[string]$row.ItemId];if(-not $item){continue}
            if($item.MigrationSpec.Adapter -cne 'Service'){$otherRequirement=$credentialByItem[[string]$item.ItemId];if($otherRequirement){$serviceSecretRefs.Add([string]$otherRequirement.SecretRef);if($Secrets.ContainsKey([string]$otherRequirement.SecretRef)){Assert-WsmAssistiveCredentialAccount $otherRequirement $Secrets}else{$requiredSecretRefs.Add([string]$otherRequirement.SecretRef)}};continue}
            $spec=$item.MigrationSpec;$policy=Get-WsmServiceAccountPolicy $spec.Desired $spec
            if($policy.Mode -eq 'ManagedServiceAccount'){[void](Test-WsmServiceAccountTargetPreflight $policy)}
            elseif($policy.Mode -ceq 'UserPassword'){
                $serviceSecretRefs.Add([string]$policy.SecretRef)
                if($Secrets.ContainsKey([string]$policy.SecretRef)){[void](New-WsmServiceAccountCredential $policy $Secrets)}else{$requiredSecretRefs.Add([string]$policy.SecretRef)}
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
    if($challenge){$challengeRefs=@($challenge.RequiredSecretRefs|Sort-Object -Unique);if(($challengeRefs -join "`n") -cne ($expectedServiceRefs -join "`n")){throw 'Service credential challenge SecretRef set changed; explicit review is required.'};if(-not $requiredSecretRefs.Count -and ($providedServiceRefs -join "`n") -cne ($challengeRefs -join "`n")){throw 'Service credential challenge did not receive its exact reviewed SecretRef set.'}}
    $credentialRequirements=@();foreach($requirementRef in $expectedServiceRefs){$matchedIds=@($credentialByItem.Keys|Where-Object {[string]$credentialByItem[$_].SecretRef -ceq $requirementRef}|Sort-Object);$matchedNames=@(foreach($matchedId in $matchedIds){$matchedName=[string]$matchedId;$matchedItem=$preflightItemsById[[string]$matchedId];if($matchedItem -and $matchedItem.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string]$matchedItem.Name)){$matchedName=[string]$matchedItem.Name};$matchedName});$credentialRequirements+=[pscustomobject][ordered]@{SecretRef=[string]$requirementRef;Kinds=@($matchedIds|ForEach-Object {[string]$credentialByItem[$_].Kind}|Sort-Object -Unique);ItemIds=@($matchedIds|ForEach-Object {[string]$_});DisplayNames=@($matchedNames);ApprovedAccount=[string]$credentialAccountByRef[[string]$requirementRef]}}
    if($requiredSecretRefs.Count){
        foreach($reservation in @($serviceReservations.ToArray())){Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State WaitingForInput | Out-Null}
        $existingAttempt=$null;if($state.PSObject.Properties['RestoreAttempt']){$existingAttempt=$state.RestoreAttempt}
        if($existingAttempt){if([string]$existingAttempt.OperationId -cne $ParentOperationId -or [string]$existingAttempt.ManifestHash -ine $ManifestHash -or [long]$existingAttempt.Generation -ne [long]$Package.Manifest.Generation -or [string]$existingAttempt.DecisionReceiptHash -ine [string]$decision.ReceiptHash -or [string]$existingAttempt.TargetSnapshotHash -ine [string]$decision.Receipt.TargetSnapshotHash -or [string]$existingAttempt.WizardPreviewHash -ine [string]$Preview.WizardPreviewHash -or (@($existingAttempt.SelectedItemIds|Sort-Object -Unique)-join "`n") -cne (@($decision.SelectedItemIds|Sort-Object -Unique)-join "`n")){throw 'Durable TargetRestore parent changed before entering the Service credential challenge.'}}
        else{$existingAttempt=[pscustomobject][ordered]@{ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviousManifest=$state.ManifestHash;OperationId=$ParentOperationId;DecisionReceiptPath=[string]$decision.ReceiptPath;DecisionReceiptHash=[string]$decision.ReceiptHash;TargetSnapshotPath=[string]$decision.SnapshotPath;TargetSnapshotHash=[string]$decision.Receipt.TargetSnapshotHash;SelectedItemIds=@($decision.SelectedItemIds);WizardPreviewHash=[string]$Preview.WizardPreviewHash;MaterialJobOperationId='';MaterialIds=@();ItemResults=@();Status='WaitingForInput';CreatedUtc=(Get-WsmUtc)}}
        $state.ManifestHash=$ManifestHash;$state.Generation=[long]$Package.Manifest.Generation;$state.Stage='WaitingForInput';$state|Add-Member NoteProperty RestoreAttempt $existingAttempt -Force
        if(-not $challenge){$challenge=[pscustomobject][ordered]@{State='WaitingForInput';ParentOperationId=$ParentOperationId;PairId=[string]$Package.Manifest.PairId;Role=$contextRole;Actor=$contextActor;SessionId=$contextSession;ContextId=$contextId;Revision=[int]$contextRevision;ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviewHash=[string]$Preview.WizardPreviewHash;RequiredSecretRefs=$expectedServiceRefs;Requirements=@($credentialRequirements);ServiceReservations=@($serviceReservations.ToArray());CreatedUtc=Get-WsmUtc;UpdatedUtc=Get-WsmUtc};$state|Add-Member NoteProperty AssistiveServiceChallenge $challenge -Force}else{$challenge.RequiredSecretRefs=$expectedServiceRefs;$challenge|Add-Member NoteProperty Requirements @($credentialRequirements) -Force;$challenge.UpdatedUtc=Get-WsmUtc}
        Add-WsmJournal $paths $state 'AssistiveServiceCredentialChallengeWaiting' '' $challenge
        return [pscustomobject][ordered]@{Status='WaitingForInput';PairId=[string]$Package.Manifest.PairId;ParentOperationId=$ParentOperationId;RequiredSecretRefs=@($challenge.RequiredSecretRefs);CredentialRequirements=@($credentialRequirements);ServiceReservations=@($challenge.ServiceReservations);ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviewHash=[string]$Preview.WizardPreviewHash;Role=$contextRole;Actor=$contextActor;SessionId=$contextSession;ContextId=$contextId;Revision=[int]$contextRevision;NoTargetWrites=$true;ResumeRequired=$true;ProductionVerified=$false}
    }
    if($challenge){$challenge.State='Running';$challenge.UpdatedUtc=Get-WsmUtc;Add-WsmJournal $paths $state 'AssistiveServiceCredentialChallengeResuming' '' $challenge}
    if($Preview.PSObject.Properties['NonCFileResults'] -and @($Preview.NonCFileResults).Count){$state | Add-Member NoteProperty AssistiveFileResults @($Preview.NonCFileResults) -Force;Add-WsmJournal $paths $state 'AssistiveNonCFileResultsImported' '' ([pscustomobject]@{Generation=[long]$Package.Manifest.Generation;Rows=@($Preview.NonCFileResults)})}
    $job=Register-WsmAssistivePackageMaterials $Package $decision $StateDirectory $Preview
    $state.Stage='Running'
    # Only the same durable parent still waiting for input (or taken over before native writes) continues; an earlier finished or cancelled attempt never lends its identity to a new restore.
    $attempt=$null;if($state.PSObject.Properties['RestoreAttempt'] -and [string]$state.RestoreAttempt.OperationId -ceq $ParentOperationId -and [string]$state.RestoreAttempt.Status -cin @('WaitingForInput','Running')){$attempt=$state.RestoreAttempt}
    if(-not $attempt){$attempt=[pscustomobject]@{ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;PreviousManifest=$state.ManifestHash;OperationId=$ParentOperationId;DecisionReceiptPath=[string]$decision.ReceiptPath;DecisionReceiptHash=[string]$decision.ReceiptHash;TargetSnapshotPath=[string]$decision.SnapshotPath;TargetSnapshotHash=[string]$decision.Receipt.TargetSnapshotHash;SelectedItemIds=@($decision.SelectedItemIds);WizardPreviewHash=$(if($Preview.PSObject.Properties['WizardPreviewHash']){[string]$Preview.WizardPreviewHash}else{''});ItemResults=@()}}
    $attempt|Add-Member NoteProperty MaterialJobOperationId $job.OperationId -Force;$attempt|Add-Member NoteProperty MaterialIds @($job.MaterialIds) -Force;$attempt|Add-Member NoteProperty Status 'Running' -Force;$attempt|Add-Member NoteProperty StartedUtc (Get-WsmUtc) -Force
    $state | Add-Member NoteProperty RestoreAttempt $attempt -Force
    Add-WsmJournal $paths $state 'AssistiveRestoreStarted' '' $attempt
    Confirm-WsmOutputStateCheckpoint -StateDirectory $StateDirectory -PairId $Package.Manifest.PairId -PlanHash $Package.Manifest.PlanHash
    $itemsById=@{};foreach($item in @($Package.Plan.Items)){$itemsById[[string]$item.ItemId]=$item}
    $itemResults=New-Object 'System.Collections.Generic.List[object]'
    try { foreach($row in @($Preview.Rows)){
        if($row.Status -ne 'Ready'){if($row.Status -notin @('Deferred','DeferredSoftware')){$itemResults.Add([pscustomobject]@{ItemId=$row.ItemId;Status=$row.Status;CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error=$row.Reason})};continue}
        Assert-WsmCancellationBoundary $CancellationToken 'AssistiveBeforeItem'
        Assert-WsmAssistiveReceiptFresh $Package $decision | Out-Null
        $item=$itemsById[[string]$row.ItemId];$spec=$item.MigrationSpec
        try{
            $reservations=@();if(-not ($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC')){$reservations=Get-WsmAssistiveReservations $item $Package $StateDirectory -OperationId $ParentOperationId}
            $priorRecord=@($state.Items | Where-Object ItemId -CEQ $item.ItemId);$undo=$null;if($priorRecord.Count){$undo=$priorRecord[0]}
            Add-WsmJournal $paths $state 'AssistiveItemStarted' $item.ItemId ([pscustomobject]@{Adapter=$spec.Adapter;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;DecisionReceiptHash=$decision.ReceiptHash})
            if($spec.Adapter -eq 'FileScope' -and $spec.TransferChannel -eq 'NonC'){$fileRows=@($Preview.NonCFileResults|Where-Object ItemId -CEQ $item.ItemId);if(-not $fileRows.Count -or @($fileRows|Where-Object {$_.Status -notin @('Applied','DirectoryReady') -or -not $_.EffectivePath -or [long]$_.Generation -ne [long]$Package.Manifest.Generation}).Count){throw 'NonC result lost its exact-generation native readback before G acceptance.'};$result=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=$false;ExternalOwnershipVerified=$true;OwnershipChannel='NonC';AppliedManifestHash=$ManifestHash;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=(Get-WsmHashText ($fileRows|Sort-Object EntryId|ConvertTo-Json -Depth 20 -Compress));Target=$spec.TargetPath;OwnedFiles=@();OwnedDirectories=@();FileResults=$fileRows;Error='';NativeCode=0}}
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
            $state.Items=@($state.Items | Where-Object ItemId -CNE $item.ItemId)+@($result)
            $itemResults.Add($result)
            Add-WsmJournal $paths $state 'AssistiveItemCompleted' $item.ItemId $result
        } catch [OperationCanceledException] {throw} catch {
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
        $attempt.ItemResults=@($itemResults.ToArray())
        $cancel=[ordered]@{Status='Cancelled';ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;OperationId='';Boundary='';PendingOperationCount=[int]@($state.PendingOperations).Count}
        if($_.Exception.Data['OperationId']){$cancel.OperationId=[string]$_.Exception.Data['OperationId']}
        if($_.Exception.Data['CancellationBoundary']){$cancel.Boundary=[string]$_.Exception.Data['CancellationBoundary']}
        if($challenge){$challenge.State='Cancelled';$challenge.UpdatedUtc=Get-WsmUtc;foreach($reservation in @($serviceReservations.ToArray())){Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State Released | Out-Null}}
        Add-WsmJournal $paths $state 'AssistiveRestoreCancelled' '' ([pscustomobject]$cancel)
        Complete-WsmAssistivePackageJob $Package $job $StateDirectory
        return [pscustomobject]@{PairId=$Package.Manifest.PairId;ManifestHash=$ManifestHash;Generation=[long]$Package.Manifest.Generation;Stage='Cancelled';Items=$state.Items;Results=$itemResults.ToArray();Deferred=@($Preview.Rows | Where-Object Status -in @('Deferred','DeferredSoftware','Blocked','BlockedConflict','ManualEvidenceRequired'));PendingOperations=@($state.PendingOperations);JournalHash=$state.JournalHash;BusinessValidationRequired=$true;ProductionVerified=$false}
    }
    $state.ManifestHash=$ManifestHash;$state.Generation=[long]$Package.Manifest.Generation
    $attempt.ItemResults=@($itemResults.ToArray())
    $remaining=@($Preview.Rows | Where-Object {$_.Status -in @('Deferred','DeferredSoftware','Blocked','BlockedConflict','ManualEvidenceRequired')})
    $failedCount=@($itemResults | Where-Object Status -in @('Failed','BlockedConflict','Blocked','ManualEvidenceRequired')).Count
    $state.Stage='Succeeded';if($remaining.Count -or $failedCount -or @($state.PendingOperations).Count){$state.Stage='Partial'};if(@($itemResults | Where-Object Status -EQ RebootRequired).Count){$state.Stage='RebootRequired'}
    if($challenge){$challenge.State='Completed';$challenge.UpdatedUtc=Get-WsmUtc}
    Add-WsmJournal $paths $state 'AssistiveRestoreCompleted' '' ([pscustomobject]@{Status=$state.Stage;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;DecisionReceiptHash=$decision.ReceiptHash;ItemResults=$itemResults.ToArray();DeferredRows=$remaining})
    if($state.Stage -in @('Succeeded','Partial','RebootRequired') -and -not @($state.PendingOperations).Count){foreach($reservation in @($serviceReservations.ToArray())){Set-WsmAssistiveServiceReservationOperation -Workspace $StateDirectory -ResourceKey $reservation.ResourceKey -PairId $Package.Manifest.PairId -ItemId $reservation.ItemId -OperationId $ParentOperationId -State Released | Out-Null}}
    Complete-WsmAssistivePackageJob $Package $job $StateDirectory
    [pscustomobject]@{PairId=$Package.Manifest.PairId;ManifestHash=$ManifestHash;Generation=$Package.Manifest.Generation;Stage=$state.Stage;Items=$state.Items;Results=$itemResults.ToArray();Deferred=$remaining;JournalHash=$state.JournalHash;BusinessValidationRequired=$true;ProductionVerified=$false}
}

function Invoke-WsmAssistiveFileScopeRestore($Item,$Package,$Paths,$State,[hashtable]$SidMap,$CancellationToken,[string]$Workspace='') {
    $spec=$Item.MigrationSpec;$target=ConvertTo-WsmCanonicalPath $spec.TargetPath;if($Package.PSObject.Properties['Plan']){Assert-WsmOfflineFullSetOriginalLocation $Package.Plan $spec};if(-not [IO.Directory]::Exists([IO.Path]::GetPathRoot($target))){throw 'Target volume for the original location is not available; prepare the same location and recheck.'};Assert-WsmNoReparse $target;Assert-WsmAssistiveTargetScopeTopology -Path $target -Spec $spec -TargetRoot $target -Kind Root
    $index=Join-Path $Package.Root 'artifacts.jsonl';$entries=@(Read-WsmArtifactLines $index $Package.Manifest.ArtifactsHash $CancellationToken | Where-Object {$_.ItemId -ceq $Item.ItemId});if(-not $entries.Count){throw 'Approved FileScope has no package artifacts.'}
    $singleFileScope=($entries.Count -eq 1 -and -not $entries[0].Directory -and [string]::IsNullOrEmpty([string]$entries[0].RelativePath));$restoreRoot=$target;$createdDirs=New-Object 'System.Collections.Generic.List[string]'
    if($singleFileScope){if([IO.Directory]::Exists($target)){throw 'A directory occupies the approved single-file target.'};$restoreRoot=[IO.Path]::GetDirectoryName($target);Assert-WsmNoReparse $restoreRoot;if(-not [IO.Directory]::Exists($restoreRoot)){[void][IO.Directory]::CreateDirectory($restoreRoot)}}
    else{if([IO.File]::Exists($target)){throw 'A file occupies the approved FileScope directory.'};if(-not [IO.Directory]::Exists($target)){[void][IO.Directory]::CreateDirectory($target);$createdDirs.Add($target)};Assert-WsmAssistiveTargetScopeTopology -Path $target -Spec $spec -TargetRoot $target -Kind Root}
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
        $newDirectory=($createdDirs -contains $path) -or -not [IO.Directory]::Exists($path);if(-not [IO.Directory]::Exists($path)){[void][IO.Directory]::CreateDirectory($path);$createdDirs.Add($path)};Assert-WsmAssistiveTargetScopeTopology -Path $path -Spec $spec -TargetRoot $target -Artifact $entry -Kind Directory -Destination $path
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
        if([IO.Directory]::Exists($dest)){$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='A directory occupies the required file path.'});continue}
        if([IO.File]::Exists($dest)){
            try{Assert-WsmAssistiveTargetScopeTopology -Path $dest -Spec $spec -TargetRoot $target -Artifact $entry -Kind File -Destination $dest -TrustedExistingHash:$(if($owner){[string]$owner.SHA256}else{''})}catch{$results.Add([pscustomobject]@{RelativePath=$entry.RelativePath;Status='BlockedConflict';Reason='Existing file topology is unsupported or could not be verified safely.'});continue}
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
