function Assert-WsmAssistiveReference($Reference,[string]$Label) {
    if ($null -eq $Reference) { return }
    foreach ($field in @('Reference','SHA256','CreatedUtc')) {
        if (-not $Reference.PSObject.Properties[$field]) { throw (New-WsmContractError ($Label+' reference is missing '+$field+'.')) }
    }
    if (-not [string]$Reference.Reference -or [string]$Reference.Reference -match '(^|[\\/])\.\.(?:[\\/]|$)' -or [IO.Path]::IsPathRooted([string]$Reference.Reference)) { throw (New-WsmContractError ($Label+' reference path is unsafe.')) }
    if ([string]$Reference.SHA256 -notmatch '^[a-f0-9]{64}$') { throw (New-WsmContractError ($Label+' reference hash is invalid.')) }
    try { [void][DateTime]::Parse([string]$Reference.CreatedUtc).ToUniversalTime() } catch { throw (New-WsmContractError ($Label+' reference time is invalid.')) }
}

function Assert-WsmAssistiveWorkspaceReferences([string]$Workspace,$Catalog) {
    Assert-WsmAssistiveContract $Catalog Catalog | Out-Null
    $root=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')+'\'
    $references=@($Catalog.Assistive.SourceSnapshot)+@($Catalog.Assistive.TargetBaseline)+@($Catalog.Assistive.TargetCurrent)+@($Catalog.Assistive.MaterialReferences)+@($Catalog.Assistive.ResultReferences)
    foreach($reference in $references){
        if($null -eq $reference){continue}
        $relative=([string]$reference.Reference).Replace('/','\')
        $path=[IO.Path]::GetFullPath((Join-Path $Workspace $relative))
        if(-not $path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw (New-WsmContractError 'Assistive evidence reference escapes its protected workspace.')}
        Assert-WsmNoReparse $path
        if(-not [IO.File]::Exists($path)){throw (New-WsmContractError ('Referenced Assistive evidence is missing: '+$relative))}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$reference.SHA256){throw (New-WsmContractError ('Referenced Assistive evidence hash mismatch: '+$relative))}
    }
    return $true
}

function Assert-WsmAssistiveContract($Data,[ValidateSet('Catalog','MigrationPlan','TargetDecisionReceipt')][string]$Kind) {
    if ($Kind -eq 'Catalog') {
        if (-not $Data.PSObject.Properties['Assistive']) { throw (New-WsmContractError 'Schema 3 Catalog requires Assistive.') }
        $a=$Data.Assistive
        foreach ($field in @('ContractVersion','PairId','Revision','SourceSnapshot','TargetBaseline','TargetCurrent','Comparison','Selections','RestoreDecisionHistory','MaterialReferences','ResultReferences','UpdatedUtc')) { if (-not $a.PSObject.Properties[$field]) { throw (New-WsmContractError ('Assistive catalog missing '+$field+'.')) } }
        if ($a.ContractVersion -ne 1 -or $a.PairId -cne $Data.PairId -or ($a.Revision -isnot [int] -and $a.Revision -isnot [long]) -or $a.Revision -lt 1) { throw (New-WsmContractError 'Invalid Assistive catalog version, pair, or revision.') }
        if($a.PSObject.Properties['ComparisonRevisionCounter'] -and (($a.ComparisonRevisionCounter -isnot [int] -and $a.ComparisonRevisionCounter -isnot [long]) -or $a.ComparisonRevisionCounter -lt 0)){throw (New-WsmContractError 'Assistive comparison revision counter is invalid.')}
        if($null -eq $a.SourceSnapshot){throw (New-WsmContractError 'Source snapshot is required.')}
        Assert-WsmAssistiveReference $a.SourceSnapshot 'Source snapshot'
        if ($a.SourceSnapshot.InventoryRevision -ne $Data.InventoryRevision -or $a.SourceSnapshot.SHA256 -ine $Data.InventoryHash) { throw (New-WsmContractError 'Assistive source snapshot does not match the catalog inventory.') }
        Assert-WsmAssistiveReference $a.TargetBaseline 'Target baseline'
        Assert-WsmAssistiveReference $a.TargetCurrent 'Target current snapshot'
        if ($null -ne $a.Comparison) {
            foreach($field in @('Revision','SourceSnapshotHash','TargetSnapshotHash','Rows','CreatedUtc')) { if(-not $a.Comparison.PSObject.Properties[$field]){throw (New-WsmContractError ('Assistive comparison missing '+$field+'.'))} }
            if (($a.Comparison.Revision -isnot [int] -and $a.Comparison.Revision -isnot [long]) -or $a.Comparison.Revision -lt 1 -or $a.Comparison.SourceSnapshotHash -ine $a.SourceSnapshot.SHA256 -or $a.Comparison.TargetSnapshotHash -ine $a.TargetCurrent.SHA256 -or $a.Comparison.Rows -isnot [array]) { throw (New-WsmContractError 'Assistive comparison is stale or malformed.') }
        }
        $itemIds=@{}; foreach($item in @($Data.Items)){ $itemIds[[string]$item.ItemId]=$true }
        $seen=@{}; if(($a.Selections.Revision -isnot [int] -and $a.Selections.Revision -isnot [long]) -or $a.Selections.Revision -lt 1 -or $a.Selections.Items -isnot [array]){throw (New-WsmContractError 'Invalid Assistive selections collection.')}
        foreach($selection in @($a.Selections.Items)){
            foreach($field in @('ItemId','SourceRevision','Selected','Reason','UpdatedUtc')){if(-not $selection.PSObject.Properties[$field]){throw (New-WsmContractError ('Assistive selection missing '+$field+'.'))}}
            if(-not $itemIds.ContainsKey([string]$selection.ItemId) -or $seen.ContainsKey([string]$selection.ItemId) -or ($selection.SourceRevision -isnot [int] -and $selection.SourceRevision -isnot [long]) -or $selection.SourceRevision -ne $Data.InventoryRevision -or $selection.Selected -isnot [bool]){throw (New-WsmContractError 'Assistive selection references an invalid or duplicate item.')}
            $seen[[string]$selection.ItemId]=$true
        }
        foreach($id in $itemIds.Keys){if(-not $seen.ContainsKey([string]$id)){throw (New-WsmContractError 'Every catalog item needs an explicit Assistive selection.') }}
        if($a.PSObject.Properties['TargetSelections']){
            if(-not $Data.Approval -or $Data.Approval.Kind -cne 'MigrationPlan' -or $a.TargetSelections.Revision -lt 1 -or $a.TargetSelections.Items -isnot [array]){throw (New-WsmContractError 'Target selections require a sealed approved source plan.')}
            if($a.TargetSelections.Items.Count -ne $Data.Items.Count){throw (New-WsmContractError 'Target selections must cover every discovered item.')}
            $targetSeen=@{};foreach($row in $a.TargetSelections.Items){if(-not $itemIds.ContainsKey([string]$row.ItemId) -or $targetSeen.ContainsKey([string]$row.ItemId) -or $row.Selected -isnot [bool]){throw (New-WsmContractError 'Invalid or duplicated target selection.')};$targetSeen[[string]$row.ItemId]=$true;if($row.Selected){$source=@($a.Selections.Items | Where-Object ItemId -CEQ $row.ItemId);$item=@($Data.Items | Where-Object ItemId -CEQ $row.ItemId);if(-not $source[0].Selected -or $item[0].Decision -cne 'Include'){throw (New-WsmContractError 'Target selection exceeds sealed source approval.')}}}
            if($targetSeen.Count -ne $itemIds.Count){throw (New-WsmContractError 'Target selection disposition is incomplete.')}
        }
        if($a.RestoreDecisionHistory -isnot [array] -or $a.MaterialReferences -isnot [array] -or $a.ResultReferences -isnot [array]){throw (New-WsmContractError 'Assistive history and references must be arrays.')}
        foreach($reference in @($a.MaterialReferences)){Assert-WsmAssistiveReference $reference 'Material'}
        foreach($reference in @($a.ResultReferences)){Assert-WsmAssistiveReference $reference 'Result'}
        if($a.PSObject.Properties['SoftwareChoices']){
            if($a.SoftwareChoices -isnot [array]){throw (New-WsmContractError 'Assistive software choices must be an array.')}
            $choiceIds=@{}
            foreach($choice in @($a.SoftwareChoices)){
                Assert-WsmFields $choice @('SoftwareId','SourceVersion','ChosenVersion','Reason','UpdatedUtc') @('SoftwareId','SourceVersion','ChosenVersion','Reason','UpdatedUtc')
                if([string]$choice.SoftwareId -notmatch '^sw-[a-f0-9]{32}$' -or $choiceIds.ContainsKey([string]$choice.SoftwareId) -or [string]::IsNullOrWhiteSpace([string]$choice.ChosenVersion) -or ([string]$choice.ChosenVersion).Length -gt 128 -or [string]$choice.ChosenVersion -match '[\x00-\x1f]' -or ([string]$choice.ChosenVersion -cne [string]$choice.SourceVersion -and [string]::IsNullOrWhiteSpace([string]$choice.Reason))){throw (New-WsmContractError 'Assistive software choice identity, version, or reason is invalid.')}
                try{[void][DateTime]::Parse([string]$choice.UpdatedUtc).ToUniversalTime()}catch{throw (New-WsmContractError 'Assistive software choice timestamp is invalid.')}
                $choiceIds[[string]$choice.SoftwareId]=$true
            }
        }
        try{[void][DateTime]::Parse([string]$a.UpdatedUtc).ToUniversalTime()}catch{throw (New-WsmContractError 'Assistive update time is invalid.')}
        return $true
    }
    if ($Kind -eq 'MigrationPlan') {
        if (-not $Data.PSObject.Properties['Assistive']) { throw (New-WsmContractError 'Schema 3 MigrationPlan requires Assistive source policy.') }
        $a=$Data.Assistive
        foreach($field in @('ContractVersion','PairId','SourceSnapshotHash','SourcePolicy','SourceSelectionsVersion','ApprovedItemIds','MaterialReferences','DiscoveryAuthority')){if(-not $a.PSObject.Properties[$field]){throw (New-WsmContractError ('MigrationPlan Assistive missing '+$field+'.'))}}
        if($a.ContractVersion -ne 1 -or $a.PairId -cne $Data.PairId -or $a.SourceSnapshotHash -ine $Data.InventoryHash -or $a.SourcePolicy -cne 'SourceCOnly' -or ($a.SourceSelectionsVersion -isnot [int] -and $a.SourceSelectionsVersion -isnot [long]) -or $a.SourceSelectionsVersion -lt 1 -or $a.ApprovedItemIds -isnot [array] -or $a.MaterialReferences -isnot [array]){throw (New-WsmContractError 'Invalid sealed MigrationPlan Assistive policy.')}
        $authority=$a.DiscoveryAuthority
        Assert-WsmFields $authority @('SourceSnapshotReference','InventoryRevision','SelectionRevision','Dispositions') @('SourceSnapshotReference','InventoryRevision','SelectionRevision','Dispositions')
        Assert-WsmAssistiveReference $authority.SourceSnapshotReference 'Sealed discovery authority'
        if($authority.SourceSnapshotReference.SHA256 -ine $a.SourceSnapshotHash -or ($authority.InventoryRevision -isnot [int] -and $authority.InventoryRevision -isnot [long]) -or $authority.InventoryRevision -ne $Data.InventoryRevision -or ($authority.SelectionRevision -isnot [int] -and $authority.SelectionRevision -isnot [long]) -or $authority.SelectionRevision -ne $a.SourceSelectionsVersion -or $authority.Dispositions -isnot [array]){throw (New-WsmContractError 'Sealed discovery authority reference/revision binding is invalid.')}
        $planIds=@{};foreach($item in @($Data.Items)){$planIds[[string]$item.ItemId]=$true}
        $seen=@{};foreach($id in @($a.ApprovedItemIds)){if(-not $planIds.ContainsKey([string]$id) -or $seen.ContainsKey([string]$id)){throw (New-WsmContractError 'Assistive approved items must be a unique subset of the sealed plan.')};$seen[[string]$id]=$true}
        $dispositions=@{};$expected=@{}
        foreach($row in @($authority.Dispositions)){
            Assert-WsmFields $row @('ItemId','Selected','Decision','Reason') @('ItemId','Selected','Decision','Reason')
            if([string]$row.ItemId -notmatch '^[a-f0-9]{64}$' -or $dispositions.ContainsKey([string]$row.ItemId) -or $row.Selected -isnot [bool] -or @('Pending','Include','Exclude') -cnotcontains [string]$row.Decision){throw (New-WsmContractError 'Sealed discovery disposition is malformed or duplicated.')}
            $dispositions[[string]$row.ItemId]=$true
            if($row.Selected -and $row.Decision -ceq 'Include'){$expected[[string]$row.ItemId]=$true}
        }
        if($expected.Count -ne $seen.Count){throw (New-WsmContractError 'Approved items do not exactly match the selected Include discovery dispositions.')}
        foreach($id in $expected.Keys){if(-not $seen.ContainsKey([string]$id)){throw (New-WsmContractError 'Approved items do not exactly match the selected Include discovery dispositions.')}}
        if($planIds.Count -ne $seen.Count){throw (New-WsmContractError 'Schema 3 plan may contain only selected approved Include items.')}
        foreach($reference in @($a.MaterialReferences)){Assert-WsmAssistiveReference $reference 'Material'}
        return $true
    }
    Assert-WsmAssistiveTargetDecisionReceipt $Data
}

function New-WsmAssistiveCatalogContract {
    param([Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SourceReference,[Parameter(Mandatory)][string]$SourceHash,[Parameter(Mandatory)][int]$InventoryRevision,[Parameter(Mandatory)]$Items,$Prior)
    $selections=@{};if($Prior -and $Prior.Selections){foreach($entry in @($Prior.Selections.Items)){$selections[[string]$entry.ItemId]=$entry}}
    $selectionRows=@(foreach($item in @($Items)){$priorSelection=$null;if($selections.ContainsKey([string]$item.ItemId)){$priorSelection=$selections[[string]$item.ItemId]};[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;SourceRevision=$InventoryRevision;Selected=$(if($priorSelection){[bool]$priorSelection.Selected}else{$true});Reason=$(if($priorSelection){[string]$priorSelection.Reason}else{''});UpdatedUtc=(Get-WsmUtc)}})
    $history=[object[]]@();$materials=[object[]]@();$results=[object[]]@();$choices=[object[]]@()
    if($Prior){$history=[object[]]@($Prior.RestoreDecisionHistory);$materials=[object[]]@($Prior.MaterialReferences);$results=[object[]]@($Prior.ResultReferences);if($Prior.PSObject.Properties['SoftwareChoices']){$choices=[object[]]@($Prior.SoftwareChoices)}}
    $oldSource=$null;if($Prior -and $Prior.SourceSnapshot -and $Prior.SourceSnapshot.SHA256 -ieq $SourceHash){$oldSource=$Prior.SourceSnapshot}
    [pscustomobject][ordered]@{
        ContractVersion=1;PairId=$PairId;Revision=$(if($Prior){[int]$Prior.Revision+1}else{1});ComparisonRevisionCounter=$(if($Prior -and $Prior.PSObject.Properties['ComparisonRevisionCounter']){[int]$Prior.ComparisonRevisionCounter}elseif($Prior -and $Prior.Comparison){[int]$Prior.Comparison.Revision}else{0})
        SourceSnapshot=[pscustomobject][ordered]@{Reference=$SourceReference;SHA256=$SourceHash.ToLowerInvariant();InventoryRevision=$InventoryRevision;CreatedUtc=(Get-WsmUtc)}
        TargetBaseline=$(if($Prior){$Prior.TargetBaseline}else{$null});TargetCurrent=$(if($Prior){$Prior.TargetCurrent}else{$null});Comparison=$(if($Prior -and $Prior.SourceSnapshot.SHA256 -ieq $SourceHash){$Prior.Comparison}else{$null})
        Selections=[pscustomobject][ordered]@{Revision=$(if($Prior -and $Prior.Selections){[int]$Prior.Selections.Revision+1}else{1});Items=$selectionRows}
        RestoreDecisionHistory=$history;MaterialReferences=$materials;ResultReferences=$results;SoftwareChoices=$choices;UpdatedUtc=(Get-WsmUtc)
    }
}

function New-WsmAssistiveMigrationPlanContract {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Catalog)
    Assert-WsmAssistiveContract $Catalog Catalog | Out-Null
    $planIds=@{};foreach($item in @($Plan.Items)){$planIds[[string]$item.ItemId]=$true}
    $selected=@($Catalog.Assistive.Selections.Items | Where-Object {$_.Selected -and $planIds.ContainsKey([string]$_.ItemId)} | ForEach-Object {[string]$_.ItemId} | Sort-Object -Unique)
    $Plan.SchemaVersion=3;$Plan.ToolVersion='0.4.0'
    $dispositions=@(foreach($item in @($Catalog.Items)){$selection=@($Catalog.Assistive.Selections.Items | Where-Object ItemId -CEQ $item.ItemId);if($selection.Count -ne 1){throw 'Every sealed discovery disposition requires one source selection.'};[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Selected=[bool]$selection[0].Selected;Decision=[string]$item.Decision;Reason=[string]$item.Reason}})
    $authority=[pscustomobject][ordered]@{SourceSnapshotReference=$Catalog.Assistive.SourceSnapshot;InventoryRevision=[int]$Catalog.InventoryRevision;SelectionRevision=[int]$Catalog.Assistive.Selections.Revision;Dispositions=$dispositions}
    $Plan | Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=[string]$Catalog.PairId;SourceSnapshotHash=[string]$Catalog.Assistive.SourceSnapshot.SHA256;SourcePolicy='SourceCOnly';SourceSelectionsVersion=[int]$Catalog.Assistive.Selections.Revision;ApprovedItemIds=$selected;MaterialReferences=@($Catalog.Assistive.MaterialReferences);DiscoveryAuthority=$authority}) -Force
    Assert-WsmAssistiveContract $Plan MigrationPlan | Out-Null
    $Plan
}

function New-WsmAssistiveAllowedSubset {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string[]]$ItemIds)
    if($Plan.Kind -cne 'MigrationPlan' -or $Plan.SchemaVersion -ne 3){throw (New-WsmContractError 'Allowed subset requires an Assistive sealed MigrationPlan.')}
    Assert-WsmAssistiveContract $Plan MigrationPlan | Out-Null
    $allowed=@{};foreach($id in @($Plan.Assistive.ApprovedItemIds)){$allowed[[string]$id]=$true}
    $seen=@{};foreach($id in $ItemIds){if(-not $allowed.ContainsKey([string]$id) -or $seen.ContainsKey([string]$id)){throw (New-WsmContractError 'Reselection can include only unique items already approved in the sealed plan.')};$seen[[string]$id]=$true}
    $result=[object[]]@($seen.Keys | Sort-Object);return ,$result
}

function Assert-WsmAssistiveTargetDecisionReceipt($Receipt) {
    if(-not $Receipt.PSObject.Properties['Comparison'] -or -not $Receipt.PSObject.Properties['ComparisonHash']){throw (New-WsmContractError 'Target receipt requires the reviewed comparison and hash.')}
    if($Receipt.PSObject.Properties['Comparison'] -or $Receipt.PSObject.Properties['ComparisonHash']) {
        if(-not $Receipt.PSObject.Properties['Comparison'] -or -not $Receipt.PSObject.Properties['ComparisonHash'] -or $Receipt.ComparisonHash -notmatch '^[a-f0-9]{64}$'){throw (New-WsmContractError 'Incomplete target comparison evidence binding.')}
        $comparison=$Receipt.Comparison
        Assert-WsmFields $comparison @('Revision','SourceSnapshotHash','TargetSnapshotHash','SelectionRevision','Rows','ManualPreparation','TargetCoverageComplete','CreatedUtc','TargetBaselineHash','VersionDisclaimer','ItemPreparation','WorkloadReviewIssues') @('Revision','SourceSnapshotHash','TargetSnapshotHash','SelectionRevision','Rows')
        if($comparison.Revision -ne $Receipt.ComparisonRevision -or $comparison.TargetSnapshotHash -ine $Receipt.TargetSnapshotHash -or $comparison.SelectionRevision -ne $Receipt.SelectionRevision -or $comparison.SourceSnapshotHash -notmatch '^[a-f0-9]{64}$' -or $comparison.Rows -isnot [array] -or (Get-WsmHashText ($comparison | ConvertTo-Json -Depth 100 -Compress)) -ine $Receipt.ComparisonHash){throw (New-WsmContractError 'Target comparison evidence hash or revision binding is invalid.')}
    }
    foreach($field in @('SchemaVersion','Kind','ReceiptId','PairId','PlanHash','ManifestHash','Generation','TargetSnapshotHash','ComparisonRevision','SelectionRevision','Decision','Owner','Reason','SelectedItemIds','AcceptedUnpreparedItemIds','CreatedUtc','SHA256')){if(-not $Receipt.PSObject.Properties[$field]){throw (New-WsmContractError ('Target decision receipt missing '+$field+'.'))}}
    if($Receipt.SchemaVersion -ne 1 -or $Receipt.Kind -cne 'AssistiveTargetDecisionReceipt' -or $Receipt.PlanHash -notmatch '^[a-f0-9]{64}$' -or $Receipt.ManifestHash -notmatch '^[a-f0-9]{64}$' -or $Receipt.TargetSnapshotHash -notmatch '^[a-f0-9]{64}$' -or ($Receipt.Generation -isnot [int] -and $Receipt.Generation -isnot [long]) -or $Receipt.Generation -lt 0 -or ($Receipt.ComparisonRevision -isnot [int] -and $Receipt.ComparisonRevision -isnot [long]) -or $Receipt.ComparisonRevision -lt 1 -or ($Receipt.SelectionRevision -isnot [int] -and $Receipt.SelectionRevision -isnot [long]) -or $Receipt.SelectionRevision -lt 1 -or @('WaitForInstall','RestoreNow') -cnotcontains $Receipt.Decision -or -not $Receipt.Owner -or -not $Receipt.Reason -or $Receipt.SelectedItemIds -isnot [array] -or $Receipt.AcceptedUnpreparedItemIds -isnot [array] -or $Receipt.SHA256 -notmatch '^[a-f0-9]{64}$'){throw (New-WsmContractError 'Target decision receipt is malformed.')}
    Assert-WsmId ([string]$Receipt.PairId);Assert-WsmId ([string]$Receipt.ReceiptId)
    $selected=@{};foreach($id in @($Receipt.SelectedItemIds)){if([string]$id -notmatch '^[a-f0-9]{64}$' -or $selected.ContainsKey([string]$id)){throw (New-WsmContractError 'Target decision receipt selection is invalid or duplicated.')};$selected[[string]$id]=$true}
    $accepted=@{};foreach($id in @($Receipt.AcceptedUnpreparedItemIds)){if(-not $selected.ContainsKey([string]$id) -or $accepted.ContainsKey([string]$id)){throw (New-WsmContractError 'Accepted unprepared items must be unique members of the selected subset.')};$accepted[[string]$id]=$true}
    if($Receipt.Decision -ceq 'WaitForInstall' -and $accepted.Count){throw (New-WsmContractError 'WaitForInstall cannot accept items for immediate restore.')}
    $body=[ordered]@{};foreach($p in $Receipt.PSObject.Properties){if($p.Name -cne 'SHA256'){$body[$p.Name]=$p.Value}};if((Get-WsmHashText ($body | ConvertTo-Json -Depth 20 -Compress)) -ine $Receipt.SHA256){throw (New-WsmContractError 'Target decision receipt hash mismatch.')}
    return $true
}

function New-WsmAssistiveTargetDecisionReceipt {
    param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$PlanHash,[Parameter(Mandatory)][string]$ManifestHash,[Parameter(Mandatory)][int]$Generation,[Parameter(Mandatory)][string]$TargetSnapshotHash,[Parameter(Mandatory)][int]$ComparisonRevision,[Parameter(Mandatory)][int]$SelectionRevision,[Parameter(Mandatory)][ValidateSet('WaitForInstall','RestoreNow')][string]$Decision,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Reason,[Parameter(Mandatory)][string[]]$SelectedItemIds,[string[]]$AcceptedUnpreparedItemIds=@(),[Parameter(Mandatory)][object]$Comparison)
    Assert-WsmTrustedFile $PlanPath $PlanHash
    $plan=Read-WsmJson $PlanPath;Assert-WsmEnvelope $plan 'MigrationPlan';Assert-WsmAssistiveContract $plan MigrationPlan | Out-Null
    $subset=New-WsmAssistiveAllowedSubset $plan $SelectedItemIds
    $receipt=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveTargetDecisionReceipt';ReceiptId=[Guid]::NewGuid().ToString();PairId=[string]$plan.PairId;PlanHash=$PlanHash.ToLowerInvariant();ManifestHash=$ManifestHash.ToLowerInvariant();Generation=$Generation;TargetSnapshotHash=$TargetSnapshotHash.ToLowerInvariant();ComparisonRevision=$ComparisonRevision;SelectionRevision=$SelectionRevision;Decision=$Decision;Owner=$Owner;Reason=$Reason;SelectedItemIds=$subset;AcceptedUnpreparedItemIds=[object[]]@($AcceptedUnpreparedItemIds);CreatedUtc=(Get-WsmUtc);SHA256=''}
    if($receipt.ManifestHash -notmatch '^[a-f0-9]{64}$' -or $receipt.TargetSnapshotHash -notmatch '^[a-f0-9]{64}$' -or $ComparisonRevision -lt 1 -or $SelectionRevision -ne $plan.Assistive.SourceSelectionsVersion){throw (New-WsmContractError ('Target decision receipt has stale comparison or invalid material binding: selections '+$SelectionRevision+'/'+$plan.Assistive.SourceSelectionsVersion+'.'))}
    if($PSBoundParameters.ContainsKey('Comparison')){if(-not $Comparison -or $Comparison.SourceSnapshotHash -ine $plan.Assistive.SourceSnapshotHash){throw (New-WsmContractError 'Target comparison does not reference this sealed source snapshot.')};$receipt | Add-Member NoteProperty Comparison $Comparison;$receipt | Add-Member NoteProperty ComparisonHash (Get-WsmHashText ($Comparison | ConvertTo-Json -Depth 100 -Compress))}
    $body=[ordered]@{};foreach($p in $receipt.PSObject.Properties){if($p.Name -cne 'SHA256'){$body[$p.Name]=$p.Value}};$receipt.SHA256=Get-WsmHashText ($body | ConvertTo-Json -Depth 20 -Compress)
    Assert-WsmAssistiveTargetDecisionReceipt $receipt | Out-Null;$receipt
}

function Enable-WsmAssistiveMode {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision)
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if($catalog.DecisionRevision -ne $ExpectedRevision){throw 'Catalog changed; refresh before enabling Assistive mode.'}
        if($catalog.PSObject.Properties['Assistive']){Assert-WsmAssistiveContract $catalog Catalog | Out-Null;return $catalog}
        if($catalog.Approval -or ($catalog.PSObject.Properties['PairPlan'] -and $catalog.PairPlan) -or ($catalog.PSObject.Properties['StageResults'] -and @($catalog.StageResults).Count)){throw 'Legacy approved or executing work cannot be promoted; reconcile ownership and begin a fresh migration.'}
        $sourcePath=Join-Path (Join-Path $Workspace 'assistive\snapshots') ($catalog.InventoryHash.ToLowerInvariant()+'.json')
        if(-not [IO.File]::Exists($sourcePath)){throw 'Trusted source inventory snapshot is unavailable; re-import inventory in Assistive mode.'}
        $catalog | Add-Member NoteProperty Assistive (New-WsmAssistiveCatalogContract $PairId ('assistive/snapshots/'+$catalog.InventoryHash.ToLowerInvariant()+'.json') $catalog.InventoryHash ([int]$catalog.InventoryRevision) @($catalog.Items) $null)
        $catalog.SchemaVersion=3;$catalog.ToolVersion='0.4.0';$catalog.DecisionRevision++;$catalog.Approval=$null
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        Assert-WsmAssistiveContract $catalog Catalog | Out-Null;$catalog
    }
}

function Get-WsmAssistiveCurrentSelections($Catalog) {
    if($Catalog.Approval -and $Catalog.Approval.PSObject.Properties['Kind'] -and $Catalog.Approval.Kind -ceq 'MigrationPlan') {
        if($Catalog.Assistive.PSObject.Properties['TargetSelections']){return $Catalog.Assistive.TargetSelections}
        $copy=ConvertFrom-WsmJson ($Catalog.Assistive.Selections | ConvertTo-Json -Depth 100)
        foreach($row in $copy.Items){$item=@($Catalog.Items | Where-Object ItemId -CEQ $row.ItemId);if($item.Count -ne 1 -or $item[0].Decision -cne 'Include'){$row.Selected=$false;$row.Reason='Outside the sealed approved Include scope.'}}
        return $copy
    }
    return $Catalog.Assistive.Selections
}

function Set-WsmAssistiveSelections {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string[]]$ItemIds,[Parameter(Mandatory)][bool]$Selected,[string]$Reason='')
    if(-not $Selected -and [string]::IsNullOrWhiteSpace($Reason)){throw 'A reason is required when deselecting discovered items.'}
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable Assistive mode before changing selections.'}
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Assistive data changed; refresh before editing selections.'}
        $sealed=($catalog.Approval -and $catalog.Approval.PSObject.Properties['Kind'] -and $catalog.Approval.Kind -ceq 'MigrationPlan')
        $current=Get-WsmAssistiveCurrentSelections $catalog
        $known=@{};foreach($selection in @($current.Items)){$known[[string]$selection.ItemId]=$selection}
        $unique=@{};foreach($id in $ItemIds){if(-not $known.ContainsKey([string]$id) -or $unique.ContainsKey([string]$id)){throw 'Selection request contains an unknown or duplicate ItemId.'};$unique[[string]$id]=$true}
        foreach($id in $unique.Keys){if($sealed -and $Selected){$source=@($catalog.Assistive.Selections.Items | Where-Object ItemId -CEQ $id);$item=@($catalog.Items | Where-Object ItemId -CEQ $id);if($source.Count -ne 1 -or -not $source[0].Selected -or $item.Count -ne 1 -or $item[0].Decision -cne 'Include'){throw 'Target selection exceeds the sealed source scope; source review and approval are required.'}};$known[$id].Selected=$Selected;$known[$id].Reason=$Reason;$known[$id].UpdatedUtc=Get-WsmUtc}
        if($sealed){$current.Revision++;$catalog.Assistive | Add-Member NoteProperty TargetSelections $current -Force;Clear-WsmAssistiveComparison $catalog;Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog;Assert-WsmAssistiveContract $catalog Catalog | Out-Null;return $catalog}
        $catalog.Assistive.Selections.Items=@($catalog.Assistive.Selections.Items)
        $catalog.Assistive.Selections.Revision++;Clear-WsmAssistiveComparison $catalog
        $catalog.DecisionRevision++;$catalog.Approval=$null
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        Assert-WsmAssistiveContract $catalog Catalog | Out-Null;$catalog
    }
}
