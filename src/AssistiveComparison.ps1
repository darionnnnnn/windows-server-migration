function Clear-WsmAssistiveComparison($Catalog) {
    if ($Catalog.PSObject.Properties['Assistive']) {
        $Catalog.Assistive.Comparison=$null
        $Catalog.Assistive.Revision++
        $Catalog.Assistive.UpdatedUtc=Get-WsmUtc
    }
}

function Get-WsmAssistiveSelectionIndex($Catalog) {
    $index=@{}
    foreach($row in @($Catalog.Assistive.Selections.Items)){$index[[string]$row.ItemId]=$row}
    $index
}

function Get-WsmAssistiveWorkloadReviewIssues($Catalog,$Items) {
    $issues=New-Object 'System.Collections.Generic.List[object]'
    $included=@{};foreach($item in $Items){$included[[string]$item.ItemId]=$item}
    if(-not $Catalog.PSObject.Properties['WorkloadDiscovery']){return}
    $discovery=$Catalog.WorkloadDiscovery
    $itemIndex=@{};foreach($item in @($Catalog.Items)){$itemIndex[[string]$item.ItemId]=$item}
    $selectionIndex=Get-WsmAssistiveSelectionIndex $Catalog
    foreach($resource in @($discovery.SharedResources)) {
        $consumers=@($resource.ConsumerItemIds | Select-Object -Unique)
        if($consumers.Count -lt 2){continue}
        $selectedConsumers=@($consumers | Where-Object {$included.ContainsKey([string]$_)})
        if(-not $selectedConsumers.Count){continue}
        $unselectedConsumers=@($consumers | Where-Object {-not $included.ContainsKey([string]$_)})
        if(-not $unselectedConsumers.Count){continue}
        foreach($consumerId in $selectedConsumers){
            $consumer=$included[[string]$consumerId]
            $reviewed=$false
            if($consumer.PSObject.Properties['MigrationSpec'] -and $consumer.MigrationSpec.PSObject.Properties['WorkloadMappingReview']){
                $references=@($discovery.References | Where-Object {$_.ResourceItemId -ceq [string]$resource.ResourceItemId -and $_.ConsumerItemId -ceq [string]$consumerId})
                $rows=@($consumer.MigrationSpec.WorkloadMappingReview)
                $reviewed=($references.Count -gt 0)
                foreach($reference in $references){
                    $matches=@($rows | Where-Object {$_.FieldPointer -ceq $reference.FieldPointer -and $_.ReferenceKind -ceq $reference.ReferenceKind})
                    if($matches.Count -ne 1 -or $matches[0].ReviewRequired -or [string]::IsNullOrWhiteSpace([string]$matches[0].Reason)){$reviewed=$false;break}
                }
            }
            if(-not $reviewed){$issues.Add([pscustomobject]@{ItemId=[string]$consumerId;Gate='ReviewComplete';Issue=('Shared resource '+[string]$resource.ResourceItemId+' has an unselected or excluded consumer; record an explicit typed impact review before approval.')})}
            if($consumer.PSObject.Properties['MigrationSpec'] -and $consumer.MigrationSpec.PSObject.Properties['SharedResourceImpacts']){
                $impacts=@($consumer.MigrationSpec.SharedResourceImpacts | Where-Object {$_.ResourceItemId -ceq [string]$resource.ResourceItemId})
                $expectedIds=@($consumers | Sort-Object);$actualIds=@();$actualSelected=@();$actualUnselected=@();$requiresReview=($unselectedConsumers.Count -gt 0 -or @($consumers | Where-Object {-not $itemIndex.ContainsKey([string]$_)}).Count -gt 0)
                $expectedSelected=@($consumers | Where-Object {$selectionIndex.ContainsKey([string]$_) -and $selectionIndex[[string]$_].Selected} | Sort-Object)
                $expectedUnselected=@($consumers | Where-Object {-not $selectionIndex.ContainsKey([string]$_) -or -not $selectionIndex[[string]$_].Selected} | Sort-Object)
                if($impacts.Count -eq 1){$actualIds=@($impacts[0].ConsumerItemIds | Sort-Object);$actualSelected=@($impacts[0].SelectedConsumerItemIds | Sort-Object);$actualUnselected=@($impacts[0].UnselectedConsumerItemIds | Sort-Object)}
                if($impacts.Count -ne 1 -or (@($actualIds) -join '|') -cne (@($expectedIds) -join '|') -or (@($actualSelected) -join '|') -cne (@($expectedSelected) -join '|') -or (@($actualUnselected) -join '|') -cne (@($expectedUnselected) -join '|') -or [bool]$impacts[0].RequiresSharedReview -ne $requiresReview -or ($requiresReview -and [string]::IsNullOrWhiteSpace([string]$impacts[0].OwnerReviewReason))){
                    $issues.Add([pscustomobject]@{ItemId=[string]$consumerId;Gate='ReviewComplete';Issue=('Shared resource impact record does not match current discovery and selection for '+[string]$resource.ResourceItemId+'.')})
                }
            }else{$issues.Add([pscustomobject]@{ItemId=[string]$consumerId;Gate='ReviewComplete';Issue=('Typed shared resource impact record is required for '+[string]$resource.ResourceItemId+'.')})}
        }
    }
}

function Get-WsmAssistiveReviewIssues($Catalog) {
    $selectionIndex=Get-WsmAssistiveSelectionIndex $Catalog
    $itemIndex=@{};foreach($item in @($Catalog.Items)){$itemIndex[[string]$item.ItemId]=$item}
    $effective=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in @($Catalog.Items)){
        if(-not $selectionIndex.ContainsKey([string]$item.ItemId)){throw (New-WsmContractError 'Assistive selection is missing for a catalog item.')}
        $selection=$selectionIndex[[string]$item.ItemId]
        if(-not $selection.Selected){continue}
        if($item.Decision -ceq 'Pending'){
            [pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue='Selected item needs an explicit Include or Exclude decision.'}
            continue
        }
        if($item.Decision -ceq 'Exclude'){
            if([string]::IsNullOrWhiteSpace([string]$item.Reason)){[pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue='Selected excluded item requires a reason.'}}
            if(($item.Status -cne 'Success' -or -not $item.Present) -and ([string]::IsNullOrWhiteSpace([string]$item.Owner) -or [string]::IsNullOrWhiteSpace([string]$item.Evidence))){[pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue='Incomplete selected exclusion requires an owner and external evidence reference.'}}
            continue
        }
        if($item.Decision -cne 'Include'){[pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue='Selected item has an unsupported decision.'};continue}
        $effective.Add($item)
        if(-not $item.Present -or $item.Status -cne 'Success'){[pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue='Selected included item has incomplete or absent discovery.'}}
        if(-not $item.PSObject.Properties['MigrationSpec'] -or $null -eq $item.MigrationSpec){[pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue='Selected included item requires a reviewed migration specification.'};continue}
        try { Assert-WsmMigrationSpec $item.MigrationSpec -Assistive }
        catch { [pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue='Selected migration specification is invalid: '+$_.Exception.Message};continue }
        foreach($dependency in @($item.Dependencies)){
            if($dependency.Type -cne 'Mandatory'){continue}
            if(-not $itemIndex.ContainsKey([string]$dependency.ItemId)){
                [pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue=('Required dependency is not discovered: '+[string]$dependency.ItemId)};continue
            }
            $required=$itemIndex[[string]$dependency.ItemId]
            $requiredSelected=($selectionIndex.ContainsKey([string]$required.ItemId) -and $selectionIndex[[string]$required.ItemId].Selected)
            if(-not $requiredSelected -or $required.Decision -cne 'Include'){
                [pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue=('Required dependency is not selected and included: '+[string]$dependency.ItemId)}
            }
        }
        if($item.MigrationSpec.PSObject.Properties['WorkloadMappingReview']){
            foreach($mapping in @($item.MigrationSpec.WorkloadMappingReview)){
                if($mapping.ReviewRequired -or [string]::IsNullOrWhiteSpace([string]$mapping.Reason)){
                    [pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue=('Typed workload reference needs an explicit mapping disposition at '+[string]$mapping.FieldPointer)}
                }
            }
        }
        if($Catalog.PSObject.Properties['WorkloadDiscovery'] -and $item.Kind -in @('IISSite','IISPool','ScheduledTask')){
            $references=@($Catalog.WorkloadDiscovery.References | Where-Object {$_.ConsumerItemId -ceq [string]$item.ItemId})
            if($references.Count -and (-not $item.MigrationSpec.PSObject.Properties['SourceXml'] -or -not $item.Settings.PSObject.Properties['Xml'] -or [string]$item.MigrationSpec.SourceXml -cne [string]$item.Settings.Xml)){
                [pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue='SourceXml must preserve the exact discovered source workload XML for typed reference and activation review.'}
            }
            foreach($reference in $references){
                $mappingRows=@();if($item.MigrationSpec.PSObject.Properties['WorkloadMappingReview']){$mappingRows=@($item.MigrationSpec.WorkloadMappingReview | Where-Object {$_.FieldPointer -ceq $reference.FieldPointer -and $_.ReferenceKind -ceq $reference.ReferenceKind})}
                if($mappingRows.Count -ne 1 -or $mappingRows[0].ReviewRequired -or [string]::IsNullOrWhiteSpace([string]$mappingRows[0].Reason)){
                    [pscustomobject]@{ItemId=$item.ItemId;Gate='ReviewComplete';Issue=('Discovered workload reference requires one explicit typed mapping or manual disposition: '+[string]$reference.FieldPointer)}
                }
            }
        }
    }
    Get-WsmAssistiveWorkloadReviewIssues $Catalog @($effective.ToArray())
    Get-WsmDependencyCycles @($effective.ToArray())
    Get-WsmMappingIssues @($effective.ToArray())
}

function Get-WsmAssistiveSnapshotInventory([string]$Workspace,$Reference,[string]$Role) {
    if($null -eq $Reference -or -not $Reference.Reference){throw ($Role+' snapshot is not available.')}
    Assert-WsmAssistiveReference $Reference $Role
    $workspaceRoot=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')+'\'
    $path=[IO.Path]::GetFullPath((Join-Path $Workspace ([string]$Reference.Reference).Replace('/','\')))
    if(-not $path.StartsWith($workspaceRoot,[StringComparison]::OrdinalIgnoreCase)){throw ($Role+' snapshot reference escapes the workspace.')}
    Assert-WsmNoReparse $path
    if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$Reference.SHA256){throw ($Role+' snapshot bytes are missing or have changed.')}
    $inventory=Read-WsmJson $path
    Assert-WsmInventory $inventory
    if($inventory.Revision -ne $Reference.InventoryRevision){throw ($Role+' snapshot revision binding is invalid.')}
    if($Reference.PSObject.Properties['HostId'] -and $inventory.Source.HostId -cne $Reference.HostId){throw ($Role+' snapshot host identity binding is invalid.')}
    if($Reference.PSObject.Properties['Fingerprint'] -and $inventory.Source.Fingerprint -ine $Reference.Fingerprint){throw ($Role+' snapshot fingerprint binding is invalid.')}
    if(-not $inventory.PSObject.Properties['SoftwareCatalog']){throw ($Role+' inventory has no software evidence catalog; comparison is unavailable, not empty.')}
    Assert-WsmSoftwareCatalog $inventory.SoftwareCatalog -SourceInventory $inventory | Out-Null
    $inventory
}

function Update-WsmAssistiveTargetSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][int]$ExpectedRevision)
    $snapshot=Read-WsmFileSnapshot $Path $ExpectedHash
    $inventory=ConvertFrom-WsmJson $snapshot.Text
    Assert-WsmInventory $inventory
    if(-not $inventory.PSObject.Properties['SoftwareCatalog']){throw 'Target inventory has no software evidence catalog; it cannot be recorded as a comparison snapshot.'}
    Assert-WsmSoftwareCatalog $inventory.SoftwareCatalog -SourceInventory $inventory | Out-Null
    $bytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
    $reference=$null
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable Assistive mode before recording target software evidence.'}
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Assistive data changed; refresh before recording the target snapshot.'}
        if($inventory.Source.HostId -ceq $catalog.Source.HostId -or $inventory.Source.Fingerprint -ieq $catalog.Source.Fingerprint){throw 'Target snapshot must identify a distinct host from the source.'}
        if($catalog.Assistive.TargetCurrent -and $inventory.Source.HostId -cne $catalog.Assistive.TargetCurrent.HostId){throw 'Target host identity changed for this pair; register a separate target pair instead.'}
        if($catalog.Assistive.TargetCurrent -and $inventory.Source.Fingerprint -ine $catalog.Assistive.TargetCurrent.Fingerprint){throw 'Target host fingerprint changed for this pair.'}
        $directory=Join-Path (Join-Path $Workspace 'assistive') 'snapshots'
        if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory}
        $name=$snapshot.Hash.ToLowerInvariant()+'.json';$destination=Join-Path $directory $name;Assert-WsmNoReparse $destination
        if([IO.File]::Exists($destination)){
            if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $snapshot.Hash){throw 'Content-addressed target snapshot hash collision.'}
        }else{
            $temporary=$destination+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
            try{[IO.File]::WriteAllBytes($temporary,$bytes);if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine $snapshot.Hash){throw 'Target inventory bytes changed before durable write.'};[IO.File]::Move($temporary,$destination)}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
        }
        $reference=[pscustomobject][ordered]@{Reference=('assistive/snapshots/'+$name);SHA256=$snapshot.Hash.ToLowerInvariant();CreatedUtc=(Get-WsmUtc);HostId=[string]$inventory.Source.HostId;Fingerprint=[string]$inventory.Source.Fingerprint;InventoryRevision=[int]$inventory.Revision;Name=[string]$inventory.Source.Name}
        if($null -eq $catalog.Assistive.TargetBaseline){$reference | Add-Member NoteProperty BaselineKind 'FirstObserved';$catalog.Assistive.TargetBaseline=$reference}
        $catalog.Assistive.TargetCurrent=$reference
        Clear-WsmAssistiveComparison $catalog
        $catalog.DecisionRevision++;$catalog.Approval=$null
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        Assert-WsmAssistiveContract $catalog Catalog | Out-Null
        $catalog
    }
}

function Get-WsmAssistiveCoverageComplete($SoftwareCatalog) {
    $coverage=@($SoftwareCatalog.Coverage)
    if(-not $coverage.Count){return $false}
    foreach($row in $coverage){if([string]$row.Status -notin @('Success','NotInstalled')){return $false}}
    return $true
}

function Get-WsmAssistiveSoftwareKey($Entry) {
    $parts=@([string]$Entry.Name,[string]$Entry.Publisher,[string]$Entry.Scope,[string]$Entry.SID,[string]$Entry.Architecture,[string]$Entry.AccountContext)
    (($parts | ForEach-Object { $_.Trim().ToUpperInvariant() }) -join '|')
}

function New-WsmAssistiveSoftwareRows($Source,$Target,$Baseline,$Choices,$TargetCoverageComplete) {
    $sourceEntries=@($Source.Entries);$targetEntries=@($Target.Entries);$baselineEntries=@();if($Baseline){$baselineEntries=@($Baseline.Entries)}
    $targetGroups=@{};foreach($entry in $targetEntries){$key=Get-WsmAssistiveSoftwareKey $entry;if(-not $targetGroups.ContainsKey($key)){$targetGroups[$key]=New-Object 'System.Collections.Generic.List[object]'};$targetGroups[$key].Add($entry)}
    $baseGroups=@{};foreach($entry in $baselineEntries){$key=Get-WsmAssistiveSoftwareKey $entry;if(-not $baseGroups.ContainsKey($key)){$baseGroups[$key]=New-Object 'System.Collections.Generic.List[object]'};$baseGroups[$key].Add($entry)}
    $sourceGroups=@{};foreach($entry in $sourceEntries){$key=Get-WsmAssistiveSoftwareKey $entry;if(-not $sourceGroups.ContainsKey($key)){$sourceGroups[$key]=New-Object 'System.Collections.Generic.List[object]'};$sourceGroups[$key].Add($entry)}
    $choiceById=@{};foreach($choice in @($Choices)){if($choiceById.ContainsKey([string]$choice.SoftwareId)){throw 'Duplicate chosen software version identity.'};$choiceById[[string]$choice.SoftwareId]=$choice}
    $rows=New-Object 'System.Collections.Generic.List[object]';$manual=New-Object 'System.Collections.Generic.List[object]';$seenTarget=@{}
    foreach($entry in $sourceEntries){
        $key=Get-WsmAssistiveSoftwareKey $entry;$targets=@();$bases=@();$identityStatus='Matched'
        if($sourceGroups[$key].Count -gt 1 -or ($targetGroups.ContainsKey($key) -and $targetGroups[$key].Count -gt 1)){$identityStatus='Ambiguous'}elseif($targetGroups.ContainsKey($key)){$targets=@($targetGroups[$key].ToArray())};if($baseGroups.ContainsKey($key)){$bases=@($baseGroups[$key].ToArray())}
        $targetVersion='';$targetId='';if($identityStatus -eq 'Matched' -and $targets.Count -eq 1){$targetVersion=[string]$targets[0].Version;$targetId=[string]$targets[0].SoftwareId;$seenTarget[$targetId]=$true}
        $baseVersion='';if($bases.Count -eq 1){$baseVersion=[string]$bases[0].Version}
        $sourceVersion=[string]$entry.Version;$chosenVersion=$sourceVersion;$choice=$null;$staleChoice=$false
        if($choiceById.ContainsKey([string]$entry.SoftwareId)){$choice=$choiceById[[string]$entry.SoftwareId];if($choice.SourceVersion -cne $sourceVersion){$staleChoice=$true}else{$chosenVersion=[string]$choice.ChosenVersion}}
        $status='TargetUnknown';$reason='Target software coverage is incomplete; absence cannot be concluded.'
        if($identityStatus -eq 'Ambiguous'){$status='Ambiguous';$reason='Multiple software instances share the available identity fields; owner matching is required.'}
        elseif($targets.Count -eq 0 -and $TargetCoverageComplete){$status='TargetMissing';$reason='Complete target coverage did not observe this source software identity.'}
        elseif($targets.Count -eq 1){
            if(-not $sourceVersion -or -not $chosenVersion -or -not $targetVersion){$status='VersionUnknown';$reason='Source, chosen, or observed target version is unknown.'}
            elseif($targetVersion -ceq $chosenVersion){$status='ChosenVersionObserved';$reason='Target reports the chosen version; compatibility is not established.'}
            else{$status='DifferentFromChosenVersion';$reason='Observed target version differs from the selected version; owner preparation and product validation are required.'}
        }
        if($staleChoice){$status='StaleChosenVersion';$reason='Source version facts changed after this choice; the saved choice is not applied to the changed source observation and must be reviewed again.'}
        elseif($entry.CaptureStatus -cne 'Success'){$status='SourceEvidenceIncomplete';$reason='Source software evidence is partial or manual and needs owner verification.'}
        $row=[pscustomobject][ordered]@{SoftwareId=[string]$entry.SoftwareId;Name=[string]$entry.Name;Publisher=[string]$entry.Publisher;Scope=[string]$entry.Scope;SID=[string]$entry.SID;Architecture=[string]$entry.Architecture;SourceVersion=$sourceVersion;ChosenVersion=$chosenVersion;ObservedTargetVersion=$targetVersion;TargetSoftwareId=$targetId;BaselineObservedVersion=$baseVersion;Status=$status;Reason=$reason;SourceCaptureStatus=[string]$entry.CaptureStatus;TargetCoverageComplete=[bool]$TargetCoverageComplete}
        $rows.Add($row)
        if($status -notin @('ChosenVersionObserved')){$manual.Add([pscustomobject]@{SoftwareId=[string]$entry.SoftwareId;Name=[string]$entry.Name;Status=$status;Owner='';Action=$(if($status -eq 'TargetMissing'){'Install or explicitly disposition this source software on the target.'}elseif($status -eq 'DifferentFromChosenVersion'){'Install the chosen version or update the chosen version after evidence review.'}elseif($status -eq 'Ambiguous'){'Identify the matching target instance and account scope.'}elseif($status -eq 'StaleChosenVersion'){'Review source facts and select a version against the current source observation.'}else{'Collect reliable software evidence and review with the product owner.'});CompatibilityDisclaimer='Observed version equality or selection is not compatibility evidence.'})}
    }
    foreach($entry in $targetEntries){if(-not $seenTarget.ContainsKey([string]$entry.SoftwareId)){$rows.Add([pscustomobject][ordered]@{SoftwareId='';Name=[string]$entry.Name;Publisher=[string]$entry.Publisher;Scope=[string]$entry.Scope;SID=[string]$entry.SID;Architecture=[string]$entry.Architecture;SourceVersion='';ChosenVersion='';ObservedTargetVersion=[string]$entry.Version;TargetSoftwareId=[string]$entry.SoftwareId;BaselineObservedVersion='';Status='TargetOnly';Reason='Target-only software is retained as an observed fact and is not treated as source compatibility.';SourceCaptureStatus='';TargetCoverageComplete=[bool]$TargetCoverageComplete})}}
    if(-not $TargetCoverageComplete){$manual.Add([pscustomobject]@{SoftwareId='';Name='Target software inventory';Status='CoverageIncomplete';Owner='';Action='Repeat target inventory with complete required probe coverage before concluding absence.';CompatibilityDisclaimer='No absence conclusions are drawn from incomplete coverage.'})}
    [pscustomobject]@{Rows=@($rows.ToArray());ManualPreparation=@($manual.ToArray())}
}

function Get-WsmAssistiveComparison {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId)
    $observed=Get-WsmCatalog $Workspace $PairId
    if(-not $observed.PSObject.Properties['Assistive']){throw 'Enable Assistive mode before comparing software.'}
    if($null -eq $observed.Assistive.TargetCurrent){throw 'Capture and import an initial target snapshot before comparing software.'}
    $sourceInventory=Get-WsmAssistiveSnapshotInventory $Workspace $observed.Assistive.SourceSnapshot Source
    $targetInventory=Get-WsmAssistiveSnapshotInventory $Workspace $observed.Assistive.TargetCurrent Target
    $baselineInventory=$null;if($observed.Assistive.TargetBaseline){$baselineInventory=Get-WsmAssistiveSnapshotInventory $Workspace $observed.Assistive.TargetBaseline 'First-observed target baseline'}
    if($targetInventory.Source.HostId -cne $observed.Assistive.TargetCurrent.HostId -or $targetInventory.Source.Fingerprint -ine $observed.Assistive.TargetCurrent.Fingerprint -or $sourceInventory.Source.HostId -cne $observed.Source.HostId -or $sourceInventory.Source.Fingerprint -ine $observed.Source.Fingerprint -or $sourceInventory.Source.HostId -ceq $targetInventory.Source.HostId){throw 'Source/target host binding is inconsistent.'}
    if($observed.Assistive.Comparison -and $observed.Assistive.Comparison.SourceSnapshotHash -ieq $observed.Assistive.SourceSnapshot.SHA256 -and $observed.Assistive.Comparison.TargetSnapshotHash -ieq $observed.Assistive.TargetCurrent.SHA256 -and $observed.Assistive.Comparison.SelectionRevision -eq $observed.Assistive.Selections.Revision){return $observed.Assistive.Comparison}
    $coverageComplete=Get-WsmAssistiveCoverageComplete $targetInventory.SoftwareCatalog
    $compared=New-WsmAssistiveSoftwareRows $sourceInventory.SoftwareCatalog $targetInventory.SoftwareCatalog $(if($baselineInventory){$baselineInventory.SoftwareCatalog}else{$null}) @($observed.Assistive.SoftwareChoices) $coverageComplete
    $sourceCoverage=@($sourceInventory.SoftwareCatalog.Coverage | Where-Object {$_.Status -notin @('Success','NotInstalled')})
    foreach($gap in $sourceCoverage){$compared.ManualPreparation=@($compared.ManualPreparation)+@([pscustomobject]@{SoftwareId='';Name=[string]$gap.Probe;Status='SourceCoverageIncomplete';Owner='';Action=('Resolve source inventory gap: '+[string]$gap.Status+'/'+[string]$gap.ErrorKind);CompatibilityDisclaimer='Incomplete source inventory cannot support absence or compatibility conclusions.'})}
    $priorRevision=0;if($observed.Assistive.PSObject.Properties['ComparisonRevisionCounter']){$priorRevision=[int]$observed.Assistive.ComparisonRevisionCounter}elseif($observed.Assistive.Comparison){$priorRevision=[int]$observed.Assistive.Comparison.Revision}
    [pscustomobject][ordered]@{Revision=($priorRevision+1);SourceSnapshotHash=[string]$observed.Assistive.SourceSnapshot.SHA256;TargetSnapshotHash=[string]$observed.Assistive.TargetCurrent.SHA256;TargetBaselineHash=$(if($observed.Assistive.TargetBaseline){[string]$observed.Assistive.TargetBaseline.SHA256}else{''});SelectionRevision=[int]$observed.Assistive.Selections.Revision;Rows=[object[]]@($compared.Rows);ManualPreparation=[object[]]@($compared.ManualPreparation);VersionDisclaimer='Source versions, chosen versions and observed target versions are separate evidence. A chosen version or matching version numbers are not compatibility evidence for product behavior, licensing, provider, account scope or workload readiness.';CreatedUtc=(Get-WsmUtc)}
}

function Update-WsmAssistiveComparison {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision)
    $comparison=Get-WsmAssistiveComparison $Workspace $PairId
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable Assistive mode before publishing a comparison.'}
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Assistive data changed; refresh and publish the comparison again.'}
        if($catalog.Assistive.SourceSnapshot.SHA256 -ine $comparison.SourceSnapshotHash -or -not $catalog.Assistive.TargetCurrent -or $catalog.Assistive.TargetCurrent.SHA256 -ine $comparison.TargetSnapshotHash -or $catalog.Assistive.Selections.Revision -ne $comparison.SelectionRevision){throw 'Comparison inputs changed; refresh and publish again.'}
        if($catalog.Assistive.Comparison -and $catalog.Assistive.Comparison.SourceSnapshotHash -ieq $comparison.SourceSnapshotHash -and $catalog.Assistive.Comparison.TargetSnapshotHash -ieq $comparison.TargetSnapshotHash -and $catalog.Assistive.Comparison.SelectionRevision -eq $comparison.SelectionRevision){return $catalog.Assistive.Comparison}
        $counter=0;if($catalog.Assistive.PSObject.Properties['ComparisonRevisionCounter']){$counter=[int]$catalog.Assistive.ComparisonRevisionCounter}elseif($catalog.Assistive.Comparison){$counter=[int]$catalog.Assistive.Comparison.Revision}
        $comparison.Revision=$counter+1
        $catalog.Assistive.ComparisonRevisionCounter=$comparison.Revision
        $catalog.Assistive.Comparison=$comparison;$catalog.Assistive.Revision++;$catalog.Assistive.UpdatedUtc=Get-WsmUtc
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        Assert-WsmAssistiveContract $catalog Catalog | Out-Null
        $comparison
    }
}

function Set-WsmAssistiveSoftwareVersion {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SoftwareId,[Parameter(Mandatory)][string]$ChosenVersion,[Parameter(Mandatory)][int]$ExpectedRevision,[string]$Reason='')
    if([string]::IsNullOrWhiteSpace($ChosenVersion) -or $ChosenVersion.Length -gt 128 -or $ChosenVersion -match '[\x00-\x1f]'){throw 'ChosenVersion must be a nonempty safe version label.'}
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable Assistive mode before selecting software versions.'}
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Assistive data changed; refresh before selecting a version.'}
        $sourceInventory=Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.SourceSnapshot Source
        $entries=@($sourceInventory.SoftwareCatalog.Entries | Where-Object SoftwareId -CEQ $SoftwareId)
        if($entries.Count -ne 1){throw 'SoftwareId must identify exactly one source evidence entry.'}
        $sourceVersion=[string]$entries[0].Version
        if($ChosenVersion -cne $sourceVersion -and [string]::IsNullOrWhiteSpace($Reason)){throw 'A reason is required when selecting a version different from the source observation.'}
        if(-not $catalog.Assistive.PSObject.Properties['SoftwareChoices']){$catalog.Assistive | Add-Member NoteProperty SoftwareChoices @()}
        $choices=@($catalog.Assistive.SoftwareChoices | Where-Object SoftwareId -CNE $SoftwareId)
        $choice=[pscustomobject][ordered]@{SoftwareId=$SoftwareId;SourceVersion=$sourceVersion;ChosenVersion=$ChosenVersion;Reason=$Reason;UpdatedUtc=(Get-WsmUtc)}
        $catalog.Assistive.SoftwareChoices=@($choices)+@($choice)
        Clear-WsmAssistiveComparison $catalog
        $catalog.DecisionRevision++;$catalog.Approval=$null
        $catalog.History=@($catalog.History)+@([pscustomobject]@{Revision=$catalog.DecisionRevision;Action='AssistiveSoftwareVersion';SoftwareId=$SoftwareId;SourceVersion=$sourceVersion;ChosenVersion=$ChosenVersion;Reason=$Reason;Utc=(Get-WsmUtc)})
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        Assert-WsmAssistiveContract $catalog Catalog | Out-Null
        $catalog
    }
}
