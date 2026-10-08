function Get-WsmReviewDefaults($Item) {
    $defaults=[ordered]@{ ManualEntry=$false; BuiltIn='Unknown'; ApplicationGroup=''; RuleId=''; Mapping=''; AccountMapping=''; EndpointMapping=''; Owner=''; Evidence=''; ScopeUnit='Object'; ExportSupported=$false; RestoreSupported=$false; VerifySupported=$false; ConsistencyGroup=''; ConsistencyOwner=''; ConsistencyEvidence='' }
    foreach ($key in $defaults.Keys) { if (-not $Item.PSObject.Properties[$key]) { $Item | Add-Member NoteProperty $key $defaults[$key] } }
    $Item
}
function Get-WsmFilteredItems($Catalog,[string]$Category,[string]$Search,[string]$Decision='All',[string]$BuiltIn='All',[string]$Group,[string]$Sort='Name') {
    if ($Category -and $script:Categories -cnotcontains $Category) { throw 'Unknown category.' }
    @($Catalog.Items | Where-Object {
        $i=$_
        (-not $Category -or $i.Category -ceq $Category) -and ($Decision -eq 'All' -or $i.Decision -ceq $Decision) -and
        ($BuiltIn -eq 'All' -or $i.BuiltIn -ceq $BuiltIn) -and (-not $Group -or $i.ApplicationGroup -ceq $Group) -and
        (-not $Search -or (($i.Name+' '+$i.NaturalKey+' '+$i.Mapping+' '+$i.AccountMapping+' '+$i.EndpointMapping+' '+$i.ApplicationGroup).IndexOf($Search,[StringComparison]::OrdinalIgnoreCase) -ge 0))
    } | Sort-Object $Sort,ItemId)
}
function Get-WsmCategorySummary {
    param([string]$Workspace,[string]$PairId)
    $c=Get-WsmCatalog $Workspace $PairId
    foreach ($category in $script:Categories) {
        $rows=@($c.Items | Where-Object Category -CEQ $category)
        [pscustomobject]@{ Category=$category; Total=$rows.Count; Include=@($rows | Where-Object Decision -EQ Include).Count; Exclude=@($rows | Where-Object Decision -EQ Exclude).Count; Pending=@($rows | Where-Object Decision -EQ Pending).Count; Incomplete=@($rows | Where-Object { $_.Status -ne 'Success' -or -not $_.Present }).Count }
    }
}
function Get-WsmDecisionPreview {
    param([string]$Workspace,[string]$PairId,[string[]]$ItemId,[ValidateSet('Include','Exclude','Pending')][string]$Decision,[string]$Reason='')
    $c=Get-WsmCatalog $Workspace $PairId; $index=@{}; foreach ($i in $c.Items) { $index[$i.ItemId]=$i }
    $ids=@($ItemId | Select-Object -Unique); $before=New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in $ids) {
        if (-not $index.ContainsKey($id)) { throw 'Unknown ItemId.' }
        $i=$index[$id]; $before.Add([pscustomobject]@{ ItemId=$id; Name=$i.Name; Before=$i.Decision; After=$Decision; Changed=($i.Decision -cne $Decision -or $i.Reason -cne $Reason) }); $i.Decision=$Decision
    }
    $conflicts=New-Object 'System.Collections.Generic.List[object]'
    foreach ($i in $c.Items) { if ($i.Decision -eq 'Include') { foreach ($d in $i.Dependencies) { if ($d.Type -eq 'Mandatory' -and (-not $index.ContainsKey($d.ItemId) -or $index[$d.ItemId].Decision -ne 'Include')) { $conflicts.Add([pscustomobject]@{ ItemId=$i.ItemId; Name=$i.Name; DependencyId=$d.ItemId }) } } } }
    [pscustomobject]@{ DecisionRevision=$c.DecisionRevision; Selected=$ids.Count; Changed=@($before.ToArray() | Where-Object Changed).Count; Sample=@($before.ToArray() | Select-Object -First 10); Changes=$before.ToArray(); Conflicts=$conflicts.ToArray() }
}
function Get-WsmRulePreview {
    param([string]$Workspace,[string]$PairId,[string]$Category,[string]$Search,[ValidateSet('All','Include','Exclude','Pending')][string]$CurrentDecision='All',[ValidateSet('All','Unknown','SuggestedInternal','ConfirmedInternal','ConfirmedThirdParty')][string]$BuiltIn='All',[string]$Group,[ValidateSet('Include','Exclude','Pending')][string]$Decision,[string]$Reason='')
    $c=Get-WsmCatalog $Workspace $PairId
    $rows=@(Get-WsmFilteredItems $c $Category $Search $CurrentDecision $BuiltIn $Group)
    if (-not $rows.Count) { throw 'No matching items.' }
    Get-WsmDecisionPreview $Workspace $PairId @($rows | ForEach-Object ItemId) $Decision $Reason
}
function Invoke-WsmReviewRule {
    [CmdletBinding(SupportsShouldProcess)] param([string]$Workspace,[string]$PairId,[string]$Category,[string]$Search,[ValidateSet('All','Include','Exclude','Pending')][string]$CurrentDecision='All',[ValidateSet('All','Unknown','SuggestedInternal','ConfirmedInternal','ConfirmedThirdParty')][string]$BuiltIn='All',[string]$Group,[ValidateSet('Include','Exclude','Pending')][string]$Decision,[string]$Reason='',[int]$ExpectedRevision)
    if ($Decision -eq 'Exclude' -and [string]::IsNullOrWhiteSpace($Reason)) { throw 'Exclusion requires a reason.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed; regenerate preview.' }
        $rows=@(Get-WsmFilteredItems $c $Category $Search $CurrentDecision $BuiltIn $Group); if (-not $rows.Count) { throw 'No matching items.' }
        if (-not $PSCmdlet.ShouldProcess($PairId,('Apply explicit rule to '+$rows.Count+' matching items across all pages'))) { return }
        $ruleId=[Guid]::NewGuid().ToString(); $before=New-Object 'System.Collections.Generic.List[object]'
        foreach ($i in $rows) { $before.Add([pscustomobject]@{ ItemId=$i.ItemId; Decision=$i.Decision; Reason=$i.Reason; ReviewedBy=$i.ReviewedBy; ReviewedUtc=$i.ReviewedUtc; RuleId=$i.RuleId }); $i.Decision=$Decision; $i.Reason=$Reason; $i.RuleId=$ruleId; $i.ReviewedBy=[Environment]::UserName; $i.ReviewedUtc=Get-WsmUtc }
        $rule=[pscustomobject]@{ RuleId=$ruleId; Category=$Category; Search=$Search; CurrentDecision=$CurrentDecision; BuiltIn=$BuiltIn; ApplicationGroup=$Group; Decision=$Decision; Reason=$Reason; Matched=$rows.Count; Utc=(Get-WsmUtc); AutoApplyOnRescan=$false }
        $c.DecisionRevision++; $c.Approval=$null; $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='Decision'; Before=$before.ToArray(); Rule=$rule; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c; $rule
    }
}
function Add-WsmManualItem {
    param([string]$Workspace,[string]$PairId,[string]$Category,[string]$Name,[string]$NaturalKey,[string]$Owner,[string]$Evidence,[int]$ExpectedRevision)
    if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Evidence)) { throw 'Manual entries require an owner and evidence reference.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $i=New-WsmItem $c.Source.HostId $Category ManualItem $Name ('manual:'+$NaturalKey) @{ EvidenceReference=$Evidence } @() Unsupported
        if (@($c.Items | Where-Object ItemId -CEQ $i.ItemId).Count) { throw 'Manual item already exists.' }
        $i=Get-WsmReviewDefaults $i
        foreach ($kv in @{ Decision='Pending'; Reason=''; ReviewedBy=''; ReviewedUtc=''; Present=$true }.GetEnumerator()) { $i | Add-Member NoteProperty $kv.Key $kv.Value }
        $i.ManualEntry=$true; $i.Owner=$Owner; $i.Evidence=$Evidence
        $c.Items=@($c.Items)+@($i); $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='ManualItem'; ItemId=$i.ItemId; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c; $i
    }
}
function Set-WsmReviewMetadata {
    param([string]$Workspace,[string]$PairId,[string]$ItemId,[string]$ApplicationGroup,[ValidateSet('Unknown','SuggestedInternal','ConfirmedInternal','ConfirmedThirdParty')][string]$BuiltIn='Unknown',[int]$ExpectedRevision)
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $rows=@($c.Items | Where-Object ItemId -CEQ $ItemId); if ($rows.Count -ne 1) { throw 'Unknown item.' }
        $rows[0].ApplicationGroup=$ApplicationGroup; $rows[0].BuiltIn=$BuiltIn; $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='Metadata'; ItemId=$ItemId; ApplicationGroup=$ApplicationGroup; BuiltIn=$BuiltIn; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function Set-WsmDependencies {
    param([string]$Workspace,[string]$PairId,[string]$ItemId,[object[]]$Dependencies,[int]$ExpectedRevision)
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $rows=@($c.Items | Where-Object ItemId -CEQ $ItemId); if ($rows.Count -ne 1) { throw 'Unknown item.' }
        $seen=@{}; foreach ($d in $Dependencies) { if ($d.ItemId -notmatch '^[a-f0-9]{64}$' -or @('Mandatory','Optional','External') -cnotcontains $d.Type -or $seen.ContainsKey($d.ItemId)) { throw 'Invalid or duplicate dependency.' }; $seen[$d.ItemId]=$true }
        $rows[0].Dependencies=@($Dependencies); $rows[0].Decision='Pending'; $rows[0].Reason='Dependencies changed; review required.'
        $c.DecisionRevision++; $c.Approval=$null; $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='Dependencies'; ItemId=$ItemId; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function Get-WsmDependencyCycles($Items) {
    # Kahn elimination is iterative: deep dependency graphs cannot exhaust the call stack.
    $index=@{}; $degree=@{}; $out=@{}
    foreach ($i in $Items) { if ($i.Decision -eq 'Include') { $index[$i.ItemId]=$i; $degree[$i.ItemId]=0; $out[$i.ItemId]=New-Object 'System.Collections.Generic.List[string]' } }
    foreach ($i in $index.Values) { foreach ($d in $i.Dependencies) { if ($d.Type -eq 'Mandatory' -and $index.ContainsKey($d.ItemId)) { $degree[$i.ItemId]++; $out[$d.ItemId].Add($i.ItemId) } } }
    $queue=New-Object 'System.Collections.Generic.Queue[string]'; foreach ($id in @($degree.Keys)) { if ($degree[$id] -eq 0) { $queue.Enqueue($id) } }
    while ($queue.Count) { $id=$queue.Dequeue(); foreach ($next in $out[$id]) { $degree[$next]--; if ($degree[$next] -eq 0) { $queue.Enqueue($next) } } }
    $remaining=@($degree.Keys | Where-Object { $degree[$_] -gt 0 })
    $groups=@($remaining | ForEach-Object { $index[$_].ConsistencyGroup } | Select-Object -Unique)
    $confirmed=($remaining.Count -gt 0 -and $groups.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($groups[0]))
    foreach ($id in $remaining) { if ([string]::IsNullOrWhiteSpace($index[$id].ConsistencyOwner) -or [string]::IsNullOrWhiteSpace($index[$id].ConsistencyEvidence)) { $confirmed=$false } }
    if (-not $confirmed) { foreach ($id in $remaining) { [pscustomobject]@{ ItemId=$id; Gate='ReviewComplete'; Issue='Mandatory cycle or dependent of cycle; define a reviewed consistency group before approval' } } }
}
function Set-WsmConsistencyGroup {
    param([string]$Workspace,[string]$PairId,[string[]]$ItemId,[string]$Name,[string]$Owner,[string]$Evidence,[int]$ExpectedRevision)
    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Evidence)) { throw 'Consistency group requires name, owner and freeze/activation/rollback evidence.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $index=@{}; foreach ($i in $c.Items) { $index[$i.ItemId]=$i }; foreach ($id in $ItemId) { if (-not $index.ContainsKey($id)) { throw 'Unknown item.' } }
        foreach ($id in $ItemId) { $i=$index[$id]; $i.ConsistencyGroup=$Name; $i.ConsistencyOwner=$Owner; $i.ConsistencyEvidence=$Evidence }
        $c.DecisionRevision++; $c.Approval=$null; $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='ConsistencyGroup'; Items=@($ItemId); Name=$Name; Owner=$Owner; Evidence=$Evidence; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function Set-WsmReviewView {
    param([string]$Workspace,[string]$PairId,[string]$Category,[string]$Search,[int]$Page=1,[ValidateSet(20,50,100)][int]$PageSize=50,[ValidateSet('All','Include','Exclude','Pending')][string]$Decision='All',[ValidateSet('All','Unknown','SuggestedInternal','ConfirmedInternal','ConfirmedThirdParty')][string]$BuiltIn='All',[string]$Group,[ValidateSet('Name','Category','Kind','Decision','NaturalKey')][string]$Sort='Name')
    if ($Page -lt 1 -or ($Category -and $script:Categories -cnotcontains $Category)) { throw 'Invalid review view.' }
    Invoke-WsmLocked $Workspace { $c=Get-WsmCatalog $Workspace $PairId; $view=[pscustomobject]@{ Category=$Category; Search=$Search; Page=$Page; PageSize=$PageSize; Decision=$Decision; BuiltIn=$BuiltIn; Group=$Group; Sort=$Sort }; $c | Add-Member NoteProperty ReviewView $view -Force; Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c }
}
function ConvertTo-WsmCanonicalPath([string]$Path) {
    if ($Path -notmatch '^(?:[a-zA-Z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))' -or $Path -match '[<>"|?*]' -or $Path.Contains('..') -or $Path -match '(?i)^\\\\[?.]\\' -or $Path.Substring(2).Contains(':')) { throw 'Use an absolute drive/UNC path without device paths, wildcards or traversal.' }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -eq 2) { $full+='\' }
    $full
}
function Get-WsmMappingIssues($Items) {
    $mapped=@($Items | Where-Object { $_.Decision -eq 'Include' -and $_.Mapping })
    for ($a=0;$a -lt $mapped.Count;$a++) { for ($b=$a+1;$b -lt $mapped.Count;$b++) {
        $left=(ConvertTo-WsmCanonicalPath $mapped[$a].Mapping).TrimEnd('\'); $right=(ConvertTo-WsmCanonicalPath $mapped[$b].Mapping).TrimEnd('\')
        if ($left -ieq $right -or $left.StartsWith($right+'\',[StringComparison]::OrdinalIgnoreCase) -or $right.StartsWith($left+'\',[StringComparison]::OrdinalIgnoreCase)) { [pscustomobject]@{ ItemId=$mapped[$a].ItemId; Gate='ReviewComplete'; Issue=('Overlapping target mapping with '+$mapped[$b].ItemId) } }
    } }
}
