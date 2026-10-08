function Get-WsmItems {
    param([string]$Workspace,[string]$PairId,[string]$Category,[string]$Search,[ValidateSet('Pending','Include','Exclude','All')][string]$Decision='All',[int]$Page=1,[ValidateSet(20,50,100)][int]$PageSize=50,[ValidateSet('All','Unknown','SuggestedInternal','ConfirmedInternal','ConfirmedThirdParty')][string]$BuiltIn='All',[string]$Group,[ValidateSet('Name','Category','Kind','Decision','NaturalKey')][string]$Sort='Name')
    if ($Page -lt 1) { throw 'Page must be positive.' }
    if ($Category -and $script:Categories -cnotcontains $Category) { throw 'Unknown category.' }
    $catalog=Get-WsmCatalog $Workspace $PairId
    $rows=@(Get-WsmFilteredItems $catalog $Category $Search $Decision $BuiltIn $Group $Sort)
    [pscustomobject]@{ Total=$rows.Count; Page=$Page; PageSize=$PageSize; DecisionRevision=$catalog.DecisionRevision; Items=@($rows | Select-Object -Skip (($Page-1)*$PageSize) -First $PageSize) }
}
function Set-WsmDecision {
    [CmdletBinding(SupportsShouldProcess)] param([string]$Workspace,[string]$PairId,[Parameter(Mandatory)][string[]]$ItemId,[ValidateSet('Pending','Include','Exclude')][string]$Decision,[string]$Reason='',[Parameter(Mandatory)][int]$ExpectedRevision)
    if ($Decision -eq 'Exclude' -and [string]::IsNullOrWhiteSpace($Reason)) { throw 'Exclusion requires a reason.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId
        if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed; refresh before applying.' }
        $index=@{}; foreach ($i in $c.Items) { $index[$i.ItemId]=$i }
        $ids=@($ItemId | Select-Object -Unique)
        foreach ($id in $ids) { if (-not $index.ContainsKey($id)) { throw 'Unknown ItemId; nothing applied.' } }
        if (-not $PSCmdlet.ShouldProcess($PairId,('Change decisions for '+$ids.Count+' items'))) { return }
        $before=New-Object 'System.Collections.Generic.List[object]'; foreach ($id in $ids) { $i=$index[$id]; $before.Add([pscustomobject]@{ ItemId=$id; Decision=$i.Decision; Reason=$i.Reason; ReviewedBy=$i.ReviewedBy; ReviewedUtc=$i.ReviewedUtc; RuleId=$i.RuleId }) }
        foreach ($id in $ids) { $i=$index[$id]; $i.Decision=$Decision; $i.Reason=$Reason; $i.RuleId=''; $i.ReviewedBy=[Environment]::UserName; $i.ReviewedUtc=Get-WsmUtc }
        $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='Decision'; Before=$before.ToArray(); Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
        $c
    }
}
function Undo-WsmDecision {
    param([string]$Workspace,[string]$PairId,[int]$ExpectedRevision)
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId
        if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $last=@($c.History | Select-Object -Last 1)
        if (-not $last.Count -or $last[0].Action -ne 'Decision') { throw 'No reversible decision at this revision.' }
        $index=@{}; foreach ($i in $c.Items) { $index[$i.ItemId]=$i }
        foreach ($b in $last[0].Before) { foreach ($f in @('Decision','Reason','ReviewedBy','ReviewedUtc')) { $index[$b.ItemId].$f=$b.$f } }
        foreach ($b in $last[0].Before) { if ($b.PSObject.Properties['RuleId']) { $index[$b.ItemId].RuleId=$b.RuleId } }
        $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='Undo'; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c; $c
    }
}
function Get-WsmReviewIssues {
    param([string]$Workspace,[string]$PairId)
    $c=Get-WsmCatalog $Workspace $PairId; $index=@{}; foreach ($i in $c.Items) { $index[$i.ItemId]=$i }
    foreach ($i in $c.Items) {
        if ($i.Decision -eq 'Pending') { [pscustomobject]@{ ItemId=$i.ItemId; Gate='ReviewComplete'; Issue='Decision required' } }
        if (($i.Status -ne 'Success' -or -not $i.Present) -and $i.Decision -ne 'Pending' -and ([string]::IsNullOrWhiteSpace($i.Evidence) -or [string]::IsNullOrWhiteSpace($i.Owner))) { [pscustomobject]@{ ItemId=$i.ItemId; Gate='ReviewComplete'; Issue='Incomplete discovery requires owner and external evidence, even when excluded' } }
        if ($i.Decision -eq 'Include') {
            if (-not $i.Present -or $i.Status -ne 'Success') { [pscustomobject]@{ ItemId=$i.ItemId; Gate='ExportReady'; Issue='Inventory incomplete or item absent' } }
            foreach ($d in $i.Dependencies) { if ($d.Type -eq 'Mandatory' -and (-not $index.ContainsKey($d.ItemId) -or $index[$d.ItemId].Decision -ne 'Include')) { [pscustomobject]@{ ItemId=$i.ItemId; Gate='ReviewComplete'; Issue=('Mandatory dependency not included: '+$d.ItemId) } } }
            [pscustomobject]@{ ItemId=$i.ItemId; Gate='ExportReady'; Issue='Restore adapter not yet implemented; manual migration required' }
        }
    }
    Get-WsmDependencyCycles $c.Items
    Get-WsmMappingIssues $c.Items
}
function Set-WsmEvidence {
    param([string]$Workspace,[string]$PairId,[string]$ItemId,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Evidence,[int]$ExpectedRevision)
    if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Evidence)) { throw 'Owner and independent evidence reference required.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId
        if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $rows=@($c.Items | Where-Object ItemId -CEQ $ItemId); if ($rows.Count -ne 1) { throw 'Unknown ItemId.' }
        $rows[0].Owner=$Owner; $rows[0].Evidence=$Evidence; $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='Evidence'; ItemId=$ItemId; Owner=$Owner; Evidence=$Evidence; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function Set-WsmMapping {
    param([string]$Workspace,[string]$PairId,[string]$ItemId,[string]$Mapping,[int]$ExpectedRevision,[ValidateSet('Path','Account','Endpoint')][string]$Type='Path')
    if ($Mapping -and $Type -eq 'Path') { $Mapping=ConvertTo-WsmCanonicalPath $Mapping }
    if ($Mapping -match '[\r\n\x00]') { throw 'Mapping cannot contain control characters.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId
        if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $rows=@($c.Items | Where-Object ItemId -CEQ $ItemId); if ($rows.Count -ne 1) { throw 'Unknown ItemId.' }
        $field='Mapping'; if ($Type -eq 'Account') { $field='AccountMapping' }; if ($Type -eq 'Endpoint') { $field='EndpointMapping' }
        $rows[0].$field=$Mapping; $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='Mapping'; ItemId=$ItemId; Type=$Type; Mapping=$Mapping; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function ConvertTo-WsmCsvSafe([string]$Value) { if ($Value -match "^[=+@\-\t\r\n']") { return "'"+$Value }; $Value }
function Export-WsmDecisions {
    param([string]$Workspace,[string]$PairId,[string]$Path)
    $c=Get-WsmCatalog $Workspace $PairId
    $c.Items | ForEach-Object { [pscustomobject][ordered]@{ BatchId=$c.BatchId; PairId=$c.PairId; SourceHostId=$c.Source.HostId; ItemId=$_.ItemId; InventoryRevision=$c.InventoryRevision; DecisionRevision=$c.DecisionRevision; Category=$_.Category; Name=(ConvertTo-WsmCsvSafe $_.Name); AllowedDecisions='Include|Exclude|Pending'; Decision=$_.Decision; Reason=(ConvertTo-WsmCsvSafe $_.Reason) } } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}
function Import-WsmDecisions {
    [CmdletBinding(SupportsShouldProcess)] param([string]$Workspace,[string]$PairId,[string]$Path,[switch]$Preview,[string]$ExpectedHash)
    $snapshot=Read-WsmFileSnapshot $Path $ExpectedHash
    $rows=@($snapshot.Text | ConvertFrom-Csv)
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; $index=@{}; foreach ($i in $c.Items) { $index[$i.ItemId]=$i }; $seen=@{}
        if (-not $rows.Count) { if ($Preview) { return [pscustomobject]@{ DecisionRevision=$c.DecisionRevision; SourceHash=$snapshot.Hash; Rows=0; Changed=0; Changes=@() } }; return $c }
        $processed=0
        foreach ($r in $rows) {
            $processed++; if ($processed % 500 -eq 0) { Write-Progress -Activity 'Validating CSV (no changes committed)' -Status ($processed.ToString()+'/'+$rows.Count) -PercentComplete ([int](100*$processed/$rows.Count)) }
            if (@($r.PSObject.Properties.Name | Sort-Object) -join ',' -cne 'AllowedDecisions,BatchId,Category,Decision,DecisionRevision,InventoryRevision,ItemId,Name,PairId,Reason,SourceHostId') { throw 'CSV columns changed.' }
            if (-not $index.ContainsKey($r.ItemId) -or $seen.ContainsKey($r.ItemId)) { throw 'CSV contains unknown or duplicate identity.' }; $seen[$r.ItemId]=$true
            $i=$index[$r.ItemId]
            if ($r.BatchId -cne $c.BatchId -or $r.PairId -cne $c.PairId -or $r.SourceHostId -cne $c.Source.HostId -or $r.AllowedDecisions -cne 'Include|Exclude|Pending') { throw 'CSV identity or allowed values changed.' }
            if ($r.InventoryRevision -cne [string]$c.InventoryRevision -or $r.DecisionRevision -cne [string]$c.DecisionRevision -or $r.Category -cne $i.Category -or $r.Name -cne (ConvertTo-WsmCsvSafe $i.Name)) { throw 'CSV is stale or read-only fields changed.' }
            if (@('Include','Exclude','Pending') -cnotcontains $r.Decision) { throw 'Invalid CSV decision.' }
            if ($r.Reason -match "^'[=+@\-\t\r\n']") { $r.Reason=$r.Reason.Substring(1) }
            if ($r.Decision -eq 'Exclude' -and [string]::IsNullOrWhiteSpace($r.Reason)) { throw 'Exclusion requires reason.' }
        }
        Write-Progress -Activity 'Validating CSV (no changes committed)' -Completed
        $changes=@($rows | Where-Object { $index[$_.ItemId].Decision -cne $_.Decision -or $index[$_.ItemId].Reason -cne $_.Reason })
        if ($Preview) { return [pscustomobject]@{ DecisionRevision=$c.DecisionRevision; SourceHash=$snapshot.Hash; Rows=$rows.Count; Changed=$changes.Count; Changes=@($changes | ForEach-Object { [pscustomobject]@{ ItemId=$_.ItemId; Name=$index[$_.ItemId].Name; Before=$index[$_.ItemId].Decision; After=$_.Decision; Reason=$_.Reason } }) } }
        if (-not $changes.Count) { return $c }
        if (-not $PSCmdlet.ShouldProcess($PairId,('Apply '+$rows.Count+' CSV rows'))) { return }
        $before=New-Object 'System.Collections.Generic.List[object]'; foreach ($r in $changes) { $i=$index[$r.ItemId]; $before.Add([pscustomobject]@{ ItemId=$i.ItemId; Decision=$i.Decision; Reason=$i.Reason; ReviewedBy=$i.ReviewedBy; ReviewedUtc=$i.ReviewedUtc; RuleId=$i.RuleId }); $i.Decision=$r.Decision; $i.Reason=$r.Reason; $i.RuleId=''; $i.ReviewedBy=[Environment]::UserName; $i.ReviewedUtc=Get-WsmUtc }
        $c.DecisionRevision++; $c.Approval=$null; $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='Decision'; Before=$before.ToArray(); Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c; $c
    }
}
function Approve-WsmPlan {
    param([string]$Workspace,[string]$PairId,[string]$Path,[int]$ExpectedRevision)
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId
        if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        if (@(Get-WsmReviewIssues $Workspace $PairId | Where-Object Gate -EQ ReviewComplete).Count) { throw 'Review is incomplete or dependencies conflict.' }
        $plan=[pscustomobject][ordered]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='ApprovedReview'; ApprovalId=[Guid]::NewGuid().ToString(); PairId=$PairId; Source=$c.Source; TargetName=$c.TargetName; InventoryRevision=$c.InventoryRevision; DecisionRevision=$c.DecisionRevision; InventoryHash=$c.InventoryHash; ApprovedUtc=(Get-WsmUtc); Gate='ReviewComplete'; ExportReady=$false; Items=@($c.Items | Select-Object ItemId,SettingsHash,Decision,Reason,Mapping,Owner,Evidence) }
        Write-WsmJson $Path $plan
        $hash=(Get-FileHash -LiteralPath $Path).Hash
        $c.Approval=[pscustomobject]@{ ApprovalId=$plan.ApprovalId; Hash=$hash; Utc=$plan.ApprovedUtc }
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
        [pscustomobject]@{ Path=[IO.Path]::GetFullPath($Path); SHA256=$hash; Gate='ReviewComplete'; ExportReady=$false }
    }
}
function Import-WsmApprovedPlan {
    param([string]$Path,[string]$ExpectedHash,[string]$InventoryPath)
    $p=Read-WsmTrustedJson $Path $ExpectedHash; Assert-WsmEnvelope $p 'ApprovedReview'
    $i=Read-WsmTrustedJson $InventoryPath $p.InventoryHash; Assert-WsmInventory $i
    if ($p.Source.HostId -cne $i.Source.HostId -or $p.Source.Fingerprint -cne $i.Source.Fingerprint -or $p.InventoryRevision -ne $i.Revision) { throw 'Plan/source binding mismatch.' }
    $p
}
