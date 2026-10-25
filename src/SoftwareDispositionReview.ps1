function Get-WsmAssistiveSoftwareDispositionReview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId)

    $catalog=Get-WsmCatalog $Workspace $PairId
    Assert-WsmGeneralHostContract $catalog | Out-Null
    $general=Get-WsmGeneralHostContract $catalog
    if(-not $general.SoftwareCatalog){throw 'A validated source SoftwareCatalog is required for software disposition review.'}
    $entries=@($general.SoftwareCatalog.Entries)
    $decisionIndex=@{};foreach($decision in @($general.SoftwareDecisions)){$decisionIndex[[string]$decision.SoftwareId]=$decision}
    # R14: decisions kept as Stale after a drifted re-import are prefill only; a current decision always wins.
    $staleIndex=@{};if($general.PSObject.Properties['StaleSoftwareDecisions']){foreach($staleDecision in @($general.StaleSoftwareDecisions)){$staleIndex[[string]$staleDecision.SoftwareId]=$staleDecision}}
    $itemIndex=@{};foreach($item in @($catalog.Items)){$itemIndex[[string]$item.ItemId]=$item}
    $rows=@(foreach($entry in $entries){
        $decision=$null;$decisionKeptStale=$false;if($decisionIndex.ContainsKey([string]$entry.SoftwareId)){$decision=$decisionIndex[[string]$entry.SoftwareId]}elseif($staleIndex.ContainsKey([string]$entry.SoftwareId)){$decision=$staleIndex[[string]$entry.SoftwareId];$decisionKeptStale=$true}
        $consumers=@(foreach($id in @($entry.ItemIds)){if($itemIndex.ContainsKey([string]$id)){[pscustomobject][ordered]@{ItemId=[string]$id;Name=[string]$itemIndex[[string]$id].Name;Decision=[string]$itemIndex[[string]$id].Decision}}})
        $special=[bool](Test-WsmGeneralHostSpecialSoftware $entry)
        [pscustomobject][ordered]@{
            SoftwareId=[string]$entry.SoftwareId
            SoftwareHash=(Get-WsmGeneralHostSoftwareFactsHash $entry)
            Name=[string]$entry.Name
            Publisher=[string]$entry.Publisher
            Version=[string]$entry.Version
            Architecture=[string]$entry.Architecture
            Scope=[string]$entry.Scope
            SID=[string]$entry.SID
            RegistryView=[string]$entry.RegistryView
            Location=[string]$entry.Location
            SourceKind=[string]$entry.SourceKind
            CaptureStatus=[string]$entry.CaptureStatus
            ConsumerItems=$consumers
            SpecialProduct=$special
            AllowedDispositions=$(if($special){@('External','NotNeeded')}else{@('Reinstall','Portable','KeepCompatible','External','NotNeeded','Unknown')})
            DecisionState=$(if(-not $decision){'Unreviewed'}elseif($decisionKeptStale){'Stale'}elseif([string]$decision.SoftwareHash -ceq (Get-WsmGeneralHostSoftwareFactsHash $entry)){'Reviewed'}else{'Stale'})
            DecisionSoftwareHash=$(if($decision){[string]$decision.SoftwareHash}else{''})
            Disposition=$(if($decision){[string]$decision.Disposition}else{''})
            Owner=$(if($decision){[string]$decision.Owner}else{''})
            Reason=$(if($decision){[string]$decision.Reason}else{''})
            Evidence=$(if($decision){[string]$decision.Evidence}else{''})
        }
    })
    $coverage=@(foreach($row in @($general.SoftwareCatalog.Coverage)){
        $budget=$row.Budget
        [pscustomobject][ordered]@{
            Probe=[string]$row.Probe;Scope=[string]$row.Scope;SID=[string]$row.SID;View=[string]$row.View
            Status=[string]$row.Status;EvidenceKind=[string]$row.EvidenceKind;Count=[long]$row.Count;ErrorKind=[string]$row.ErrorKind
            Budget=[pscustomobject][ordered]@{MaxEntries=[long]$budget.MaxEntries;MaxDepth=$(if($budget.PSObject.Properties['MaxDepth']){[long]$budget.MaxDepth}else{$null});MaxMetadataBytes=$(if($budget.PSObject.Properties['MaxMetadataBytes']){[long]$budget.MaxMetadataBytes}else{$null});VisitedEntries=$(if($budget.PSObject.Properties['VisitedEntries']){[long]$budget.VisitedEntries}else{$null});MetadataBytes=$(if($budget.PSObject.Properties['MetadataBytes']){[long]$budget.MetadataBytes}else{$null})}
        }
    })
    $sourceInventory=Get-WsmCatalogInventoryProjection $catalog
    $sourceInventory | Add-Member NoteProperty SoftwareCatalog $general.SoftwareCatalog
    $rootCoverage=Get-WsmTrustedInstalledSoftwareRoots $sourceInventory
    $review=[pscustomobject][ordered]@{
        Kind='AssistiveSoftwareDispositionReview';SchemaVersion=1;Status='Previewed';PairId=[string]$PairId
        DecisionRevision=[int]$catalog.DecisionRevision;InventoryHash=[string]$catalog.InventoryHash
        SoftwareCatalogHash=[string]$general.SoftwareCatalogHash
        Rows=$rows;Coverage=$coverage
        TrustedSoftwareRoots=[pscustomobject][ordered]@{Status=[string]$rootCoverage.Status;Count=@($rootCoverage.Roots).Count;Diagnostics=@($rootCoverage.Diagnostics)}
        ReadinessProof=$false;AuthoritativeApproval=$false
    }
    $review | Add-Member NoteProperty PreviewHash (Get-WsmHashText ($review | ConvertTo-Json -Depth 40 -Compress))
    $review
}

function Submit-WsmAssistiveSoftwareDispositionReview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$ExpectedPreviewHash,[Parameter(Mandatory)][switch]$Ack,[Parameter(Mandatory)][ValidateCount(1,50000)][object[]]$Decisions)
    if(-not $Ack){throw 'Applying software dispositions requires -Ack after reviewing the current software disposition preview.'}
    if($ExpectedPreviewHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Software disposition preview hash is invalid.'}
    $review=Get-WsmAssistiveSoftwareDispositionReview $Workspace $PairId
    if($review.DecisionRevision -ne $ExpectedRevision -or $review.PreviewHash -ine $ExpectedPreviewHash){throw 'Software disposition review changed; obtain a new preview.'}
    $rowIndex=@{};foreach($row in @($review.Rows)){$rowIndex[[string]$row.SoftwareId]=$row}
    $seen=@{};$typed=New-Object 'System.Collections.Generic.List[object]'
    foreach($decision in $Decisions){
        Assert-WsmFields $decision @('SoftwareId','Disposition','Owner','Reason','Evidence') @('SoftwareId','Disposition','Owner','Reason','Evidence')
        $softwareId=[string]$decision.SoftwareId
        if(-not $softwareId -or $seen.ContainsKey($softwareId)){throw 'Software disposition batch contains a duplicate or empty SoftwareId.'}
        if(-not $rowIndex.ContainsKey($softwareId)){throw 'Software disposition batch references a SoftwareId absent from the current review.'}
        $row=$rowIndex[$softwareId];$disposition=[string]$decision.Disposition
        if(@($row.AllowedDispositions) -cnotcontains $disposition){throw 'Software disposition is not allowed for the current software evidence.'}
        foreach($field in @('SoftwareId','Disposition','Owner','Reason','Evidence')){Assert-WsmQualificationText ([string]$decision.$field) ('SoftwareDisposition.'+$field) 2048}
        $seen[$softwareId]=$true
        $typed.Add([pscustomobject][ordered]@{SoftwareId=$softwareId;ScopeDisposition=$disposition;Owner=[string]$decision.Owner;Reason=[string]$decision.Reason;Evidence=[string]$decision.Evidence})
    }
    $result=Submit-WsmAssistiveGeneralHostDispositions -Workspace $Workspace -PairId $PairId -ExpectedRevision $ExpectedRevision -Ack -Decisions $typed.ToArray()
    [pscustomobject][ordered]@{
        Kind='AssistiveSoftwareDispositionSubmission';Status='Applied';PairId=[string]$PairId
        ExpectedRevision=$ExpectedRevision;DecisionRevision=[int]$result.DecisionRevision;PreviewHash=$ExpectedPreviewHash
        SubmittedCount=$typed.Count;SubmittedSoftwareIds=@($typed | ForEach-Object SoftwareId)
        ReopenedReview=(Get-WsmAssistiveSoftwareDispositionReview $Workspace $PairId)
        ReadinessProof=$false;AuthoritativeApproval=$false
    }
}
