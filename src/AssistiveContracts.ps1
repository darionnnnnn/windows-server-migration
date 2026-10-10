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
        if($a.RestoreDecisionHistory -isnot [array] -or $a.MaterialReferences -isnot [array] -or $a.ResultReferences -isnot [array]){throw (New-WsmContractError 'Assistive history and references must be arrays.')}
        foreach($reference in @($a.MaterialReferences)){Assert-WsmAssistiveReference $reference 'Material'}
        foreach($reference in @($a.ResultReferences)){Assert-WsmAssistiveReference $reference 'Result'}
        try{[void][DateTime]::Parse([string]$a.UpdatedUtc).ToUniversalTime()}catch{throw (New-WsmContractError 'Assistive update time is invalid.')}
        return $true
    }
    if ($Kind -eq 'MigrationPlan') {
        if (-not $Data.PSObject.Properties['Assistive']) { throw (New-WsmContractError 'Schema 3 MigrationPlan requires Assistive source policy.') }
        $a=$Data.Assistive
        foreach($field in @('ContractVersion','PairId','SourceSnapshotHash','SourcePolicy','SourceSelectionsVersion','ApprovedItemIds','MaterialReferences')){if(-not $a.PSObject.Properties[$field]){throw (New-WsmContractError ('MigrationPlan Assistive missing '+$field+'.'))}}
        if($a.ContractVersion -ne 1 -or $a.PairId -cne $Data.PairId -or $a.SourceSnapshotHash -ine $Data.InventoryHash -or $a.SourcePolicy -cne 'SourceCOnly' -or ($a.SourceSelectionsVersion -isnot [int] -and $a.SourceSelectionsVersion -isnot [long]) -or $a.SourceSelectionsVersion -lt 1 -or $a.ApprovedItemIds -isnot [array] -or $a.MaterialReferences -isnot [array]){throw (New-WsmContractError 'Invalid sealed MigrationPlan Assistive policy.')}
        $planIds=@{};foreach($item in @($Data.Items)){$planIds[[string]$item.ItemId]=$true}
        $seen=@{};foreach($id in @($a.ApprovedItemIds)){if(-not $planIds.ContainsKey([string]$id) -or $seen.ContainsKey([string]$id)){throw (New-WsmContractError 'Assistive approved items must be a unique subset of the sealed plan.')};$seen[[string]$id]=$true}
        foreach($reference in @($a.MaterialReferences)){Assert-WsmAssistiveReference $reference 'Material'}
        return $true
    }
    Assert-WsmAssistiveTargetDecisionReceipt $Data
}

function New-WsmAssistiveCatalogContract {
    param([Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SourceReference,[Parameter(Mandatory)][string]$SourceHash,[Parameter(Mandatory)][int]$InventoryRevision,[Parameter(Mandatory)]$Items,$Prior)
    $selections=@{};if($Prior -and $Prior.Selections){foreach($entry in @($Prior.Selections.Items)){$selections[[string]$entry.ItemId]=$entry}}
    $selectionRows=@(foreach($item in @($Items)){$priorSelection=$null;if($selections.ContainsKey([string]$item.ItemId)){$priorSelection=$selections[[string]$item.ItemId]};[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;SourceRevision=$InventoryRevision;Selected=$(if($priorSelection){[bool]$priorSelection.Selected}else{$true});Reason=$(if($priorSelection){[string]$priorSelection.Reason}else{''});UpdatedUtc=(Get-WsmUtc)}})
    $history=[object[]]@();$materials=[object[]]@();$results=[object[]]@()
    if($Prior){$history=[object[]]@($Prior.RestoreDecisionHistory);$materials=[object[]]@($Prior.MaterialReferences);$results=[object[]]@($Prior.ResultReferences)}
    $oldSource=$null;if($Prior -and $Prior.SourceSnapshot -and $Prior.SourceSnapshot.SHA256 -ieq $SourceHash){$oldSource=$Prior.SourceSnapshot}
    [pscustomobject][ordered]@{
        ContractVersion=1;PairId=$PairId;Revision=$(if($Prior){[int]$Prior.Revision+1}else{1})
        SourceSnapshot=[pscustomobject][ordered]@{Reference=$SourceReference;SHA256=$SourceHash.ToLowerInvariant();InventoryRevision=$InventoryRevision;CreatedUtc=(Get-WsmUtc)}
        TargetBaseline=$(if($Prior){$Prior.TargetBaseline}else{$null});TargetCurrent=$(if($Prior){$Prior.TargetCurrent}else{$null});Comparison=$(if($Prior -and $Prior.SourceSnapshot.SHA256 -ieq $SourceHash){$Prior.Comparison}else{$null})
        Selections=[pscustomobject][ordered]@{Revision=$(if($Prior -and $Prior.Selections){[int]$Prior.Selections.Revision+1}else{1});Items=$selectionRows}
        RestoreDecisionHistory=$history;MaterialReferences=$materials;ResultReferences=$results;UpdatedUtc=(Get-WsmUtc)
    }
}

function New-WsmAssistiveMigrationPlanContract {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Catalog)
    Assert-WsmAssistiveContract $Catalog Catalog | Out-Null
    $planIds=@{};foreach($item in @($Plan.Items)){$planIds[[string]$item.ItemId]=$true}
    $selected=@($Catalog.Assistive.Selections.Items | Where-Object {$_.Selected -and $planIds.ContainsKey([string]$_.ItemId)} | ForEach-Object {[string]$_.ItemId} | Sort-Object -Unique)
    $Plan.SchemaVersion=3;$Plan.ToolVersion='0.4.0'
    $Plan | Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=[string]$Catalog.PairId;SourceSnapshotHash=[string]$Catalog.Assistive.SourceSnapshot.SHA256;SourcePolicy='SourceCOnly';SourceSelectionsVersion=[int]$Catalog.Assistive.Selections.Revision;ApprovedItemIds=$selected;MaterialReferences=@($Catalog.Assistive.MaterialReferences)}) -Force
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
    param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$PlanHash,[Parameter(Mandatory)][string]$ManifestHash,[Parameter(Mandatory)][int]$Generation,[Parameter(Mandatory)][string]$TargetSnapshotHash,[Parameter(Mandatory)][int]$ComparisonRevision,[Parameter(Mandatory)][int]$SelectionRevision,[Parameter(Mandatory)][ValidateSet('WaitForInstall','RestoreNow')][string]$Decision,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Reason,[Parameter(Mandatory)][string[]]$SelectedItemIds,[string[]]$AcceptedUnpreparedItemIds=@())
    Assert-WsmTrustedFile $PlanPath $PlanHash
    $plan=Read-WsmJson $PlanPath;Assert-WsmEnvelope $plan 'MigrationPlan';Assert-WsmAssistiveContract $plan MigrationPlan | Out-Null
    $subset=New-WsmAssistiveAllowedSubset $plan $SelectedItemIds
    $receipt=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveTargetDecisionReceipt';ReceiptId=[Guid]::NewGuid().ToString();PairId=[string]$plan.PairId;PlanHash=$PlanHash.ToLowerInvariant();ManifestHash=$ManifestHash.ToLowerInvariant();Generation=$Generation;TargetSnapshotHash=$TargetSnapshotHash.ToLowerInvariant();ComparisonRevision=$ComparisonRevision;SelectionRevision=$SelectionRevision;Decision=$Decision;Owner=$Owner;Reason=$Reason;SelectedItemIds=$subset;AcceptedUnpreparedItemIds=[object[]]@($AcceptedUnpreparedItemIds);CreatedUtc=(Get-WsmUtc);SHA256=''}
    if($receipt.ManifestHash -notmatch '^[a-f0-9]{64}$' -or $receipt.TargetSnapshotHash -notmatch '^[a-f0-9]{64}$' -or $ComparisonRevision -lt 1 -or $SelectionRevision -ne $plan.Assistive.SourceSelectionsVersion){throw (New-WsmContractError ('Target decision receipt has stale comparison or invalid material binding: selections '+$SelectionRevision+'/'+$plan.Assistive.SourceSelectionsVersion+'.'))}
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

function Set-WsmAssistiveSelections {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string[]]$ItemIds,[Parameter(Mandatory)][bool]$Selected,[string]$Reason='')
    if(-not $Selected -and [string]::IsNullOrWhiteSpace($Reason)){throw 'A reason is required when deselecting discovered items.'}
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable Assistive mode before changing selections.'}
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Assistive data changed; refresh before editing selections.'}
        $known=@{};foreach($selection in @($catalog.Assistive.Selections.Items)){$known[[string]$selection.ItemId]=$selection}
        $unique=@{};foreach($id in $ItemIds){if(-not $known.ContainsKey([string]$id) -or $unique.ContainsKey([string]$id)){throw 'Selection request contains an unknown or duplicate ItemId.'};$unique[[string]$id]=$true}
        foreach($id in $unique.Keys){$known[$id].Selected=$Selected;$known[$id].Reason=$Reason;$known[$id].UpdatedUtc=Get-WsmUtc}
        $catalog.Assistive.Selections.Items=@($catalog.Assistive.Selections.Items)
        $catalog.Assistive.Selections.Revision++;$catalog.Assistive.Revision++;$catalog.Assistive.UpdatedUtc=Get-WsmUtc
        $catalog.DecisionRevision++;$catalog.Approval=$null
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        Assert-WsmAssistiveContract $catalog Catalog | Out-Null;$catalog
    }
}
