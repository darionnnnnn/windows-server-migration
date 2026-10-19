function Get-WsmSourceCandidateWorkloadReferenceRows($Catalog,$Confirmation) {
    if(-not $Catalog.PSObject.Properties['WorkloadDiscovery'] -or -not $Catalog.WorkloadDiscovery -or $Catalog.WorkloadDiscovery.References -isnot [array]){throw 'Manager source inventory has no validated workload reference index.'}
    $rows=New-Object 'System.Collections.Generic.List[object]';$allReferences=@($Catalog.WorkloadDiscovery.References);$known=@{};$consumerIds=@{}
    foreach($confirmed in @($Confirmation.Selection.WorkloadReferences)){
        $matchingReferences=@($allReferences|Where-Object {
            [string]$_.ConsumerItemId -ceq [string]$confirmed.ConsumerItemId -and
            [string]$_.FieldPointer -ceq [string]$confirmed.FieldPointer -and
            [string]$_.ReferenceKind -ceq [string]$confirmed.ReferenceKind -and
            [string]$_.ResolvedPath -ieq [string]$confirmed.Path
        })
        if($matchingReferences.Count -ne 1){throw 'Candidate workload reference does not match exactly one source inventory reference.'}
        $referenceId=[string]$matchingReferences[0].ReferenceId
        if($referenceId -notmatch '^[a-f0-9]{64}$'){$referenceIndex=[Array]::IndexOf([object[]]$allReferences,$matchingReferences[0])+1;if($referenceIndex -lt 1){throw 'Source workload reference has no stable inventory position.'};$referenceId=Get-WsmHashText ([string]$Catalog.Source.HostId+'|workload-reference|'+[string]$matchingReferences[0].ConsumerItemId+'|'+[string]$matchingReferences[0].FieldPointer+'|'+[string]$referenceIndex)}
        $rows.Add([pscustomobject]@{Confirmed=$confirmed;Reference=$matchingReferences[0];ReferenceId=$referenceId});$known[$referenceId]=$true;$consumerIds[[string]$confirmed.ConsumerItemId]=$true
    }
    foreach($sourceReference in $allReferences){
        if(-not $consumerIds.ContainsKey([string]$sourceReference.ConsumerItemId)){continue}
        $referenceIndex=[Array]::IndexOf([object[]]$allReferences,$sourceReference)+1;if($referenceIndex -lt 1){continue}
        $referenceId=if($sourceReference.PSObject.Properties['ReferenceId'] -and [string]$sourceReference.ReferenceId -match '^[a-f0-9]{64}$'){[string]$sourceReference.ReferenceId}else{Get-WsmHashText ([string]$Catalog.Source.HostId+'|workload-reference|'+[string]$sourceReference.ConsumerItemId+'|'+[string]$sourceReference.FieldPointer+'|'+[string]$referenceIndex)}
        if($known.ContainsKey($referenceId)){continue}
        $path='';if($sourceReference.PSObject.Properties['ResolvedPath'] -and -not $sourceReference.Opaque -and (Get-WsmSafeWorkloadPathProjection ([string]$sourceReference.ResolvedPath))){$path=[string]$sourceReference.ResolvedPath}
        $confirmed=[pscustomobject][ordered]@{ConsumerItemId=[string]$sourceReference.ConsumerItemId;FieldPointer=[string]$sourceReference.FieldPointer;ReferenceKind=[string]$sourceReference.ReferenceKind;Path=$path;Required=[bool]$(if($sourceReference.PSObject.Properties['Required']){$sourceReference.Required}else{$false});ReviewRequired=[bool]$(if($sourceReference.PSObject.Properties['ReviewRequired']){$sourceReference.ReviewRequired}else{$true})}
        $rows.Add([pscustomobject]@{Confirmed=$confirmed;Reference=$sourceReference;ReferenceId=$referenceId});$known[$referenceId]=$true
    }
    @($rows.ToArray())
}

function New-WsmSourceCandidateMappedReference($BoundRow) {
    $source=$BoundRow.Reference;$confirmed=$BoundRow.Confirmed
    [pscustomobject][ordered]@{ReferenceId=[string]$BoundRow.ReferenceId;ConsumerItemId=[string]$confirmed.ConsumerItemId;FieldPointer=[string]$confirmed.FieldPointer;ReferenceKind=[string]$confirmed.ReferenceKind;ResolvedPath=[string]$confirmed.Path;RawValue=$(if($source.PSObject.Properties['RawValue'] -and [string]$source.RawValue){[string]$source.RawValue}else{[string]$confirmed.Path});Opaque=[bool]$(if($source.PSObject.Properties['Opaque']){$source.Opaque}else{$false});Required=[bool]$confirmed.Required;ReviewRequired=[bool]$confirmed.ReviewRequired}
}

function Get-WsmSourceCandidateFileScopeBindingHash($Item) {
    if(-not $Item -or -not $Item.PSObject.Properties['MigrationSpec'] -or $Item.MigrationSpec.Adapter -cne 'FileScope'){throw 'Workload mapping target is not a FileScope item.'}
    $spec=$Item.MigrationSpec
    $members=@();if($spec.PSObject.Properties['Members']){$members=@(foreach($m in @($spec.Members)){[pscustomobject][ordered]@{RelativePath=([string]$m.RelativePath).Replace('/','\').ToLowerInvariant();SHA256=([string]$m.SHA256).ToLowerInvariant()}});$members=@($members|Sort-Object RelativePath)}
    $configFiles=@();if($spec.PSObject.Properties['ConfigFiles']){$configFiles=@(foreach($m in @($spec.ConfigFiles)){[pscustomobject][ordered]@{RelativePath=([string]$m.RelativePath).Replace('/','\').ToLowerInvariant();SHA256=([string]$m.SHA256).ToLowerInvariant()}});$configFiles=@($configFiles|Sort-Object RelativePath)}
    $excluded=@();if($spec.PSObject.Properties['ExcludedRelativePaths']){$excluded=@([string[]]@($spec.ExcludedRelativePaths)|ForEach-Object {$_.Replace('/','\').ToLowerInvariant()}|Sort-Object)}
    $body=[ordered]@{ItemId=[string]$Item.ItemId;SourcePath=(ConvertTo-WsmCanonicalPath ([string]$spec.SourcePath));TargetPath=(ConvertTo-WsmCanonicalPath ([string]$spec.TargetPath));ContentSelection=$(if($spec.PSObject.Properties['ContentSelection']){[string]$spec.ContentSelection}else{'WholeScope'});Members=$members;ConfigFiles=$configFiles;ExcludedRelativePaths=$excluded;TransferChannel=[string]$spec.TransferChannel}
    Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress)
}

function Get-WsmSourceCandidateMappingOwnedEvidence([string]$ReferenceId) {
    'Reviewed workload mapping '+$ReferenceId.ToLowerInvariant()
}

function Get-WsmSourceCandidateMappingItem($Catalog,[string]$ItemId) {
    $rows=@($Catalog.Items|Where-Object {$_.ItemId -ceq $ItemId -and [string]$_.NaturalKey -like 'manual:source-candidate-confirmation:*'})
    if($rows.Count -ne 1){throw 'Unknown source-confirmed candidate item.'}
    $rows[0]
}

function Get-WsmSourceCandidateWorkloadMappingReview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$CandidateItemId)
    $catalog=Get-WsmCatalog $Workspace $PairId
    if($catalog.SchemaVersion -ne 3 -or -not $catalog.PSObject.Properties['Assistive']){throw 'Workload mapping review requires an Assistive schema 3 Manager catalog.'}
    $item=Get-WsmSourceCandidateMappingItem $catalog $CandidateItemId
    $material=Get-WsmSourceCandidateConfirmationMaterial $Workspace $catalog $item;$confirmation=$material.Confirmation
    Assert-WsmSourceCandidateItemSpecMatchesConfirmation $Workspace $catalog $item $confirmation $material.Hash|Out-Null
    $prior=@();if($catalog.WorkloadDiscovery.PSObject.Properties['FileScopeMappings']){$prior=@($catalog.WorkloadDiscovery.FileScopeMappings)}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($bound in @(Get-WsmSourceCandidateWorkloadReferenceRows $catalog $confirmation)){
        $reference=New-WsmSourceCandidateMappedReference $bound;$existing=@($prior|Where-Object {[string]$_.ReferenceId -ceq [string]$reference.ReferenceId})
        $mapping=Resolve-WsmWorkloadReferenceMapping $catalog $reference -PreviewCandidateScopes
        $rows.Add([pscustomobject][ordered]@{
            ReferenceId=[string]$reference.ReferenceId;ConsumerItemId=[string]$reference.ConsumerItemId;FieldPointer=[string]$reference.FieldPointer;ReferenceKind=[string]$reference.ReferenceKind;Path=[string]$bound.Confirmed.Path;Required=[bool]$bound.Confirmed.Required;ReviewRequired=[bool]$bound.Confirmed.ReviewRequired;Opaque=[bool]$reference.Opaque
            DiscoveryStatus=[string]$mapping.Status;SuggestedFileScopeItemId=[string]$mapping.FileScopeItemId;SuggestedTargetValue=[string]$mapping.TargetValue;DiscoveryReason=[string]$mapping.Reason
            Decision=$(if($existing.Count -eq 1){[string]$existing[0].Decision}else{'Pending'});FileScopeItemId=$(if($existing.Count -eq 1){[string]$existing[0].FileScopeItemId}else{''});DependencyType=$(if($existing.Count -eq 1){[string]$existing[0].DependencyType}else{'None'});StoredStatus=$(if($existing.Count -gt 1){'InvalidDuplicate'}elseif($existing.Count -eq 1){'Recorded'}else{'NotRecorded'})
        })
    }
    [pscustomobject][ordered]@{Kind='SourceCandidateWorkloadMappingReview';PairId=$PairId;CandidateItemId=$CandidateItemId;ConfirmationId=[string]$confirmation.ConfirmationId;ConfirmationHash=$material.Hash;MaterialReference=$material.Reference;InventoryHash=[string]$confirmation.InventoryHash;InventoryRevision=[int]$confirmation.InventoryRevision;DecisionRevision=[int]$catalog.DecisionRevision;SelectionRevision=[int]$catalog.Assistive.Selections.Revision;References=@($rows.ToArray());AuthoritativeApproval=$false}
}

function Submit-WsmSourceCandidateWorkloadMappingReview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$CandidateItemId,[Parameter(Mandatory)][string]$ExpectedInventoryHash,[Parameter(Mandatory)][string]$ExpectedConfirmationHash,[Parameter(Mandatory)][object[]]$Decisions,[Parameter(Mandatory)][int]$ExpectedRevision)
    if($ExpectedInventoryHash -notmatch '^[a-fA-F0-9]{64}$' -or $ExpectedConfirmationHash -notmatch '^[a-fA-F0-9]{64}$' -or $Decisions.Count -gt 10000){throw 'Workload mapping identity or decision count is invalid.'}
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if([int]$catalog.DecisionRevision -ne $ExpectedRevision){throw 'Manager review changed; refresh workload mapping before submitting.'}
        if([string]$catalog.InventoryHash -ine $ExpectedInventoryHash -or [string]$catalog.Assistive.SourceSnapshot.SHA256 -ine $ExpectedInventoryHash){throw 'Workload mapping is bound to another source inventory.'}
        $candidate=Get-WsmSourceCandidateMappingItem $catalog $CandidateItemId
        $material=Get-WsmSourceCandidateConfirmationMaterial $Workspace $catalog $candidate;$confirmation=$material.Confirmation
        if([string]$material.Hash -ine $ExpectedConfirmationHash){throw 'Workload mapping is bound to another candidate confirmation.'}
        Assert-WsmSourceCandidateItemSpecMatchesConfirmation $Workspace $catalog $candidate $confirmation $material.Hash|Out-Null
        $selection=@($catalog.Assistive.Selections.Items|Where-Object {$_.ItemId -ceq $CandidateItemId -and $_.Selected})
        if($candidate.Decision -cne 'Include' -or -not $candidate.ReviewedBy -or -not $candidate.ReviewedUtc -or $selection.Count -ne 1){throw 'Candidate FileScope must be included, reviewed and selected before mapping workload references.'}
        $boundRows=@(Get-WsmSourceCandidateWorkloadReferenceRows $catalog $confirmation);$known=@{};foreach($bound in $boundRows){$known[[string]$bound.ReferenceId]=$bound}
        $decisionIndex=@{};foreach($decision in $Decisions){
            Assert-WsmFields $decision @('ReferenceId','Decision','FileScopeItemId','DependencyType') @('ReferenceId','Decision','FileScopeItemId','DependencyType')
            $id=[string]$decision.ReferenceId;if($id -notmatch '^[a-f0-9]{64}$' -or -not $known.ContainsKey($id) -or $decisionIndex.ContainsKey($id) -or [string]$decision.Decision -cnotin @('Include','Exclude','Manual')){throw 'Workload mapping decision has an unknown or duplicate E0 reference identity.'}
            if([string]$decision.Decision -ceq 'Include'){
                if([string]$decision.FileScopeItemId -notmatch '^[a-f0-9]{64}$' -or [string]$decision.DependencyType -cnotin @('None','Mandatory','Optional')){throw 'Included workload mapping requires an explicit FileScope and dependency disposition.'}
                $scopeRows=@($catalog.Items|Where-Object {$_.ItemId -ceq [string]$decision.FileScopeItemId});if($scopeRows.Count -ne 1){throw 'Workload mapping references an unknown FileScope item.'};$scope=$scopeRows[0]
                if($scope.Decision -cne 'Include' -or -not $scope.ReviewedBy -or -not $scope.ReviewedUtc){throw 'Workload mapping target scope must be included and reviewed.'}
                $scopeSelection=@($catalog.Assistive.Selections.Items|Where-Object {$_.ItemId -ceq $scope.ItemId -and $_.Selected});if($scopeSelection.Count -ne 1){throw 'Workload mapping target FileScope is not selected.'}
                $resolved=Resolve-WsmWorkloadReferenceMapping $catalog (New-WsmSourceCandidateMappedReference $known[$id]) -ExplicitFileScopeItemId ([string]$scope.ItemId)
                if($resolved.Status -cne 'Mapped' -or [string]$resolved.FileScopeItemId -cne [string]$scope.ItemId){throw ('Workload reference is not uniquely covered by the selected approved FileScope: '+[string]$resolved.Reason)}
            }elseif([string]$decision.FileScopeItemId -or [string]$decision.DependencyType -cne 'None'){throw 'Excluded or manual workload references cannot carry a FileScope or dependency edge.'}
            $decisionIndex[$id]=$decision
        }
        if(-not $decisionIndex.Count){throw 'No workload reference decisions were submitted.'}
        if($decisionIndex.Count -ne $boundRows.Count){throw 'Every source workload reference in this confirmation must receive exactly one explicit Include, Exclude, or Manual disposition.'}
        $oldRows=@();if($catalog.WorkloadDiscovery.PSObject.Properties['FileScopeMappings']){$oldRows=@($catalog.WorkloadDiscovery.FileScopeMappings)}
        $newRows=New-Object 'System.Collections.Generic.List[object]'
        $supersededRows=@($oldRows|Where-Object {$decisionIndex.ContainsKey([string]$_.ReferenceId)})
        foreach($old in $oldRows){if(-not $decisionIndex.ContainsKey([string]$old.ReferenceId)){$newRows.Add($old)}}
        $changedConsumers=@{}
        foreach($id in @($decisionIndex.Keys|Sort-Object)){
            $decision=$decisionIndex[$id];$bound=$known[$id];$reference=New-WsmSourceCandidateMappedReference $bound;$scope=$null;$scopeHash='';$targetConfirmationHash=''
            if([string]$decision.Decision -ceq 'Include'){$scope=@($catalog.Items|Where-Object ItemId -CEQ $decision.FileScopeItemId)[0];$scopeHash=Get-WsmSourceCandidateFileScopeBindingHash $scope;if([string]$scope.NaturalKey -like 'manual:source-candidate-confirmation:*'){$targetMaterial=Get-WsmSourceCandidateConfirmationMaterial $Workspace $catalog $scope;$targetConfirmationHash=[string]$targetMaterial.Hash}}
            $row=[pscustomobject][ordered]@{Version=1;ReferenceId=$id;ConsumerItemId=[string]$reference.ConsumerItemId;FieldPointer=[string]$reference.FieldPointer;ReferenceKind=[string]$reference.ReferenceKind;Path=[string]$bound.Confirmed.Path;CandidateItemId=[string]$CandidateItemId;CandidateItemSpecHash=(Get-WsmSourceCandidateFileScopeBindingHash $candidate);CandidateConfirmationId=[string]$confirmation.ConfirmationId;CandidateConfirmationHash=[string]$material.Hash;CandidateMemberSetHash=(Get-WsmSourceCandidateMemberSetHash $confirmation.Selection.Members);InventoryHash=[string]$confirmation.InventoryHash;InventoryRevision=[int]$confirmation.InventoryRevision;Decision=[string]$decision.Decision;FileScopeItemId=$(if($scope){[string]$scope.ItemId}else{''});FileScopeBindingHash=$scopeHash;FileScopeConfirmationHash=$targetConfirmationHash;DependencyType=[string]$decision.DependencyType;SubmittedDecisionRevision=[int]$catalog.DecisionRevision;UpdatedUtc=(Get-WsmUtc)}
            $newRows.Add($row);$changedConsumers[[string]$reference.ConsumerItemId]=$true
        }
        if(-not $catalog.WorkloadDiscovery.PSObject.Properties['FileScopeMappings']){$catalog.WorkloadDiscovery|Add-Member NoteProperty FileScopeMappings @() -Force}
        $catalog.WorkloadDiscovery.FileScopeMappings=@($newRows.ToArray())
        foreach($consumerId in $changedConsumers.Keys){
            $consumerRows=@($catalog.Items|Where-Object {$_.ItemId -ceq $consumerId});if($consumerRows.Count -ne 1){throw 'Workload reference consumer is absent from the current source inventory.'};$consumer=$consumerRows[0]
            $removeEvidence=@($supersededRows|Where-Object {$_.ConsumerItemId -ceq $consumerId -and [string]$_.DependencyType -cin @('Mandatory','Optional')}|ForEach-Object {Get-WsmSourceCandidateMappingOwnedEvidence ([string]$_.ReferenceId)})
            $dependencies=@($consumer.Dependencies|Where-Object {$removeEvidence -cnotcontains [string]$_.Evidence})
            foreach($row in @($newRows|Where-Object {$_.ConsumerItemId -ceq $consumerId -and $_.Decision -ceq 'Include' -and $_.DependencyType -cin @('Mandatory','Optional')})){
                $same=@($dependencies|Where-Object {$_.ItemId -ceq $row.FileScopeItemId})
                if($same.Count){if(@($same|Where-Object {$_.Type -ceq $row.DependencyType}).Count -eq 0){throw 'Explicit workload mapping conflicts with an existing dependency type.'};continue}
                $dependencies+=@([pscustomobject][ordered]@{ItemId=[string]$row.FileScopeItemId;Type=[string]$row.DependencyType;Evidence=(Get-WsmSourceCandidateMappingOwnedEvidence ([string]$row.ReferenceId));Confidence='ReviewedReferenceMapping'})
            }
            $consumer.Dependencies=@($dependencies);if($consumer.Decision -ceq 'Include'){$consumer.Decision='Pending';$consumer.Reason='Workload path mapping changed; review the dependent task or IIS item again.';$consumer.ReviewedBy='';$consumer.ReviewedUtc=''}
        }
        $catalog.DecisionRevision++;$catalog.Approval=$null;Clear-WsmAssistiveComparison $catalog
        $catalog.History=@($catalog.History)+@([pscustomobject][ordered]@{Actor=(Get-WsmExecutionActor);Revision=[int]$catalog.DecisionRevision;Action='SourceCandidateWorkloadMappings';CandidateItemId=$CandidateItemId;ReferenceIds=@($decisionIndex.Keys|Sort-Object);Utc=(Get-WsmUtc)})
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        [pscustomobject][ordered]@{Status='SubmittedReviewRequired';PairId=$PairId;CandidateItemId=$CandidateItemId;DecisionRevision=[int]$catalog.DecisionRevision;MappingCount=$decisionIndex.Count;ConsumerItemIds=@($changedConsumers.Keys|Sort-Object);AuthoritativeApproval=$false}
    }
}

function Assert-WsmSourceCandidateWorkloadMappingsBeforeSeal([string]$Workspace,$Catalog,$IncludedItems) {
    $active=New-Object 'System.Collections.Generic.List[object]';$includedConsumers=@{};foreach($item in @($IncludedItems)){$includedConsumers[[string]$item.ItemId]=$item}
    if(-not $Catalog.WorkloadDiscovery -or -not $Catalog.WorkloadDiscovery.PSObject.Properties['FileScopeMappings']){return [pscustomobject]@{ActiveMappings=@()}}
    foreach($row in @($Catalog.WorkloadDiscovery.FileScopeMappings)){
        # A stored mapping is dormant while its consumer is outside the selected
        # approval set. Keep it in the catalog for a later re-selection, but do
        # not let unrelated historic mappings block this plan.
        if(-not $includedConsumers.ContainsKey([string]$row.ConsumerItemId)){continue}
        Assert-WsmFields $row @('Version','ReferenceId','ConsumerItemId','FieldPointer','ReferenceKind','Path','CandidateItemId','CandidateItemSpecHash','CandidateConfirmationId','CandidateConfirmationHash','CandidateMemberSetHash','InventoryHash','InventoryRevision','Decision','FileScopeItemId','FileScopeBindingHash','FileScopeConfirmationHash','DependencyType','SubmittedDecisionRevision','UpdatedUtc') @('Version','ReferenceId','ConsumerItemId','FieldPointer','ReferenceKind','Path','CandidateItemId','CandidateItemSpecHash','CandidateConfirmationId','CandidateConfirmationHash','CandidateMemberSetHash','InventoryHash','InventoryRevision','Decision','FileScopeItemId','FileScopeBindingHash','FileScopeConfirmationHash','DependencyType')
        if([int]$row.Version -ne 1 -or [string]$row.ReferenceId -notmatch '^[a-f0-9]{64}$' -or [string]$row.CandidateItemSpecHash -notmatch '^[a-f0-9]{64}$' -or [string]$row.CandidateConfirmationHash -notmatch '^[a-f0-9]{64}$' -or [string]$row.CandidateMemberSetHash -notmatch '^[a-f0-9]{64}$' -or [string]$row.InventoryHash -ine [string]$Catalog.InventoryHash -or [int]$row.InventoryRevision -ne [int]$Catalog.InventoryRevision -or [string]$row.Decision -cnotin @('Include','Exclude','Manual')){throw 'Stored workload mapping is stale or malformed.'}
        $candidate=Get-WsmSourceCandidateMappingItem $Catalog ([string]$row.CandidateItemId);$material=Get-WsmSourceCandidateConfirmationMaterial $Workspace $Catalog $candidate;$confirmation=$material.Confirmation
        if((Get-WsmSourceCandidateFileScopeBindingHash $candidate) -ine [string]$row.CandidateItemSpecHash -or [string]$material.Hash -ine [string]$row.CandidateConfirmationHash -or [string]$confirmation.ConfirmationId -cne [string]$row.CandidateConfirmationId -or (Get-WsmSourceCandidateMemberSetHash $confirmation.Selection.Members) -ine [string]$row.CandidateMemberSetHash){throw 'Workload mapping candidate confirmation or member-set evidence changed.'}
        Assert-WsmSourceCandidateItemSpecMatchesConfirmation $Workspace $Catalog $candidate $confirmation $material.Hash|Out-Null
        $bound=@(Get-WsmSourceCandidateWorkloadReferenceRows $Catalog $confirmation|Where-Object {$ref=$_.Reference;$confirmedRow=$_.Confirmed;$ref -and $confirmedRow -and $ref.PSObject.Properties['ConsumerItemId'] -and $ref.PSObject.Properties['FieldPointer'] -and $ref.PSObject.Properties['ReferenceKind'] -and $confirmedRow.PSObject.Properties['Path'] -and [string]$_.ReferenceId -ceq [string]$row.ReferenceId -and [string]$ref.ConsumerItemId -ceq [string]$row.ConsumerItemId -and [string]$ref.FieldPointer -ceq [string]$row.FieldPointer -and [string]$ref.ReferenceKind -ceq [string]$row.ReferenceKind -and [string]$confirmedRow.Path -ieq [string]$row.Path})
        if($bound.Count -ne 1){throw 'Workload mapping no longer matches its E0 source reference.'}
        if($row.Decision -ceq 'Include'){
            $consumer=@($IncludedItems|Where-Object {$_.ItemId -ceq [string]$row.ConsumerItemId});$scope=@($IncludedItems|Where-Object {$_.ItemId -ceq [string]$row.FileScopeItemId});if($consumer.Count -ne 1 -or $scope.Count -ne 1){throw 'Included workload mapping requires its selected FileScope in the sealed plan.'}
            $selection=@($Catalog.Assistive.Selections.Items|Where-Object {$_.ItemId -ceq [string]$row.FileScopeItemId -and $_.Selected});if($selection.Count -ne 1 -or $scope[0].Decision -cne 'Include' -or -not $scope[0].ReviewedBy -or -not $scope[0].ReviewedUtc){throw 'Workload mapping FileScope is no longer included, reviewed and selected.'}
            if((Get-WsmSourceCandidateFileScopeBindingHash $scope[0]) -ine [string]$row.FileScopeBindingHash){throw 'Workload mapping FileScope scope or member hash changed.'}
            $resolved=Resolve-WsmWorkloadReferenceMapping $Catalog (New-WsmSourceCandidateMappedReference $bound[0]);if($resolved.Status -cne 'Mapped' -or [string]$resolved.FileScopeItemId -cne [string]$row.FileScopeItemId){throw 'Workload mapping became ambiguous or no longer covers the reference.'}
            if([string]$row.DependencyType -cin @('Mandatory','Optional') -and -not @($consumer[0].Dependencies|Where-Object {$_.ItemId -ceq [string]$row.FileScopeItemId -and $_.Type -ceq [string]$row.DependencyType}).Count){throw 'Explicit workload dependency is missing from its consumer item.'}
        }elseif([string]$row.FileScopeItemId -or [string]$row.DependencyType -cne 'None'){throw 'Excluded or manual workload mapping unexpectedly carries a scope or dependency.'}
        $active.Add($row)
    }
    [pscustomobject]@{ActiveMappings=@($active.ToArray())}
}

function Assert-WsmSealedFileScopeMappings($Plan) {
    if(-not $Plan.PSObject.Properties['FileScopeMappingsVersion'] -and -not $Plan.PSObject.Properties['FileScopeMappings']){return $true}
    if(-not $Plan.PSObject.Properties['FileScopeMappingsVersion'] -or [int]$Plan.FileScopeMappingsVersion -ne 1 -or $Plan.FileScopeMappings -isnot [array] -or $Plan.FileScopeMappings.Count -gt 10000){throw 'Sealed FileScopeMappings feature is malformed or unsupported.'}
    $ids=@{};$planItems=@{};foreach($item in @($Plan.Items)){$planItems[[string]$item.ItemId]=$item}
    foreach($row in @($Plan.FileScopeMappings)){
        Assert-WsmFields $row @('Version','ReferenceId','ConsumerItemId','FieldPointer','ReferenceKind','Path','CandidateItemId','CandidateItemSpecHash','CandidateConfirmationId','CandidateConfirmationHash','CandidateMemberSetHash','InventoryHash','InventoryRevision','Decision','FileScopeItemId','FileScopeBindingHash','FileScopeConfirmationHash','DependencyType','SubmittedDecisionRevision','UpdatedUtc') @('Version','ReferenceId','ConsumerItemId','FieldPointer','ReferenceKind','Path','CandidateItemId','CandidateItemSpecHash','CandidateConfirmationId','CandidateConfirmationHash','CandidateMemberSetHash','InventoryHash','InventoryRevision','Decision','FileScopeItemId','FileScopeBindingHash','FileScopeConfirmationHash','DependencyType')
        if([int]$row.Version -ne 1 -or [string]$row.ReferenceId -notmatch '^[a-f0-9]{64}$' -or $ids.ContainsKey([string]$row.ReferenceId) -or [string]$row.CandidateItemId -notmatch '^[a-f0-9]{64}$' -or [string]$row.CandidateItemSpecHash -notmatch '^[a-f0-9]{64}$' -or [string]$row.CandidateConfirmationHash -notmatch '^[a-f0-9]{64}$' -or [string]$row.CandidateMemberSetHash -notmatch '^[a-f0-9]{64}$' -or [string]$row.CandidateConfirmationId -notmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or [string]$row.InventoryHash -ine [string]$Plan.InventoryHash -or [int]$row.InventoryRevision -ne [int]$Plan.InventoryRevision -or [string]$row.Decision -cnotin @('Include','Exclude','Manual') -or $row.FieldPointer -isnot [string] -or ([string]$row.FieldPointer).Length -gt 2048 -or [string]$row.ReferenceKind -notmatch '^[A-Za-z][A-Za-z0-9]{0,63}$'){throw 'Sealed FileScopeMapping identity or source binding is invalid.'}
        $ids[[string]$row.ReferenceId]=$true
        $confirmationReference='assistive/materials/source-candidate/'+([string]$row.CandidateConfirmationHash).ToLowerInvariant()+'/confirmation.json';$material=@();if($Plan.Assistive -and $Plan.Assistive.PSObject.Properties['MaterialReferences']){$material=@($Plan.Assistive.MaterialReferences|Where-Object {[string]$_.Reference -ceq $confirmationReference -and [string]$_.SHA256 -ieq [string]$row.CandidateConfirmationHash})};if($material.Count -ne 1){throw 'Sealed FileScopeMapping lacks its immutable source confirmation material binding.'}
        if($planItems.ContainsKey([string]$row.CandidateItemId) -and $planItems[[string]$row.CandidateItemId].MigrationSpec.Adapter -ceq 'FileScope' -and (Get-WsmSourceCandidateFileScopeBindingHash $planItems[[string]$row.CandidateItemId]) -ine [string]$row.CandidateItemSpecHash){throw 'Sealed FileScopeMapping candidate hash does not match the included candidate spec.'}
        if([string]$row.Decision -ceq 'Include'){
            if(-not $planItems.ContainsKey([string]$row.ConsumerItemId) -or -not $planItems.ContainsKey([string]$row.FileScopeItemId) -or [string]$row.DependencyType -cnotin @('None','Mandatory','Optional') -or [string]$row.FileScopeBindingHash -notmatch '^[a-f0-9]{64}$'){throw 'Included sealed FileScopeMapping does not bind approved plan items and hashes.'}
            $scopeItem=$planItems[[string]$row.FileScopeItemId];if(-not $scopeItem.PSObject.Properties['MigrationSpec'] -or $scopeItem.MigrationSpec.Adapter -cne 'FileScope' -or (Get-WsmSourceCandidateFileScopeBindingHash $scopeItem) -ine [string]$row.FileScopeBindingHash){throw 'Sealed FileScopeMapping hash does not match the approved plan FileScope spec.'}
            if([string]$row.DependencyType -cin @('Mandatory','Optional') -and -not @($planItems[[string]$row.ConsumerItemId].Dependencies|Where-Object {$_.ItemId -ceq [string]$row.FileScopeItemId -and $_.Type -ceq [string]$row.DependencyType}).Count){throw 'Sealed FileScopeMapping dependency is absent from the approved consumer.'}
        }elseif([string]$row.FileScopeItemId -or [string]$row.DependencyType -cne 'None'){throw 'Non-included sealed FileScopeMapping carries a FileScope or dependency.'}
    }
    $true
}
