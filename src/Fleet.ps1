function Set-WsmPairPlan {
    param([string]$Workspace,[string]$PairId,[string]$Owner,[string]$Wave,[string]$FinalName,[string]$TemporaryIP,[string]$FinalIP,[string]$Domain,[int]$ExpectedRevision)
    foreach ($ip in @($TemporaryIP,$FinalIP)) { if ($ip) { $parsed=$null; if (-not [Net.IPAddress]::TryParse($ip,[ref]$parsed)) { throw 'Invalid IP address.' } } }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $plan=[pscustomobject]@{ Owner=$Owner; Wave=$Wave; FinalName=$FinalName; TemporaryIP=$TemporaryIP; FinalIP=$FinalIP; Domain=$Domain }
        $c | Add-Member NoteProperty PairPlan $plan -Force; $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='PairPlan'; Plan=$plan; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function Set-WsmCrossHostDependency {
    param([string]$Workspace,[string]$PairId,[string]$DependencyPairId,[ValidateSet('Mandatory','Optional','External')][string]$Type='Mandatory',[string]$Evidence,[int]$ExpectedRevision)
    if ($PairId -ceq $DependencyPairId -or [string]::IsNullOrWhiteSpace($Evidence)) { throw 'Distinct pairs and evidence required.' }
    Invoke-WsmLocked $Workspace {
        [void](Get-WsmCatalog $Workspace $DependencyPairId)
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $edges=@(); if ($c.PSObject.Properties['CrossHostDependencies']) { $edges=@($c.CrossHostDependencies | Where-Object PairId -CNE $DependencyPairId) }
        $edges+= [pscustomobject]@{ PairId=$DependencyPairId; Type=$Type; Evidence=$Evidence }
        $c | Add-Member NoteProperty CrossHostDependencies $edges -Force; $c.DecisionRevision++; $c.Approval=$null
        $c.History=@($c.History)+@([pscustomobject]@{ Revision=$c.DecisionRevision; Action='CrossHostDependency'; Dependencies=$edges; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function Export-WsmFleetGraph {
    param([string]$Workspace,[string]$Path)
    $fleet=Get-WsmFleet $Workspace
    $nodes=@(); $edges=@()
    foreach ($p in $fleet.Pairs) { $c=Get-WsmCatalog $Workspace $p.PairId; $nodes+=[pscustomobject]@{ PairId=$p.PairId; Source=$c.Source.Name; Target=$c.TargetName }; if ($c.PSObject.Properties['CrossHostDependencies']) { foreach ($d in $c.CrossHostDependencies) { $edges+=[pscustomobject]@{ From=$p.PairId; To=$d.PairId; Type=$d.Type; Evidence=$d.Evidence } } } }
    Write-WsmJson $Path ([pscustomobject]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='FleetGraph'; BatchId=$fleet.BatchId; Nodes=$nodes; Edges=$edges; CreatedUtc=(Get-WsmUtc) })
}
function Import-WsmStageResult {
    param([string]$Workspace,[string]$Path,[string]$ExpectedHash)
    $r=Read-WsmTrustedJson $Path $ExpectedHash; Assert-WsmEnvelope $r 'StageResult'
    Assert-WsmId $r.PairId; Assert-WsmId $r.RunId
    $stages=@('Inventory','Export','Restore','PreCutoverValidation','FinalDelta','Cutover','PostCutoverValidation','Retirement')
    $states=@('NotStarted','Ready','Running','Succeeded','Failed','Blocked','RetryPending','ManualEvidenceRequired','RebootRequired')
    if ($stages -cnotcontains $r.Stage -or $states -cnotcontains $r.Status -or ($r.Sequence -isnot [int] -and $r.Sequence -isnot [long]) -or $r.Sequence -lt 1) { throw 'Invalid stage result.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $r.PairId
        if ($r.BatchId -cne $c.BatchId -or $r.SourceHostId -cne $c.Source.HostId -or $r.InventoryRevision -ne $c.InventoryRevision -or $r.DecisionRevision -ne $c.DecisionRevision) { throw 'Result identity/revision mismatch.' }
        $results=@(); if ($c.PSObject.Properties['StageResults']) { $results=@($c.StageResults) }
        $older=@($results | Where-Object { $_.Stage -ceq $r.Stage })
        if ($older.Count) { $last=$older | Sort-Object Sequence -Descending | Select-Object -First 1; if ($r.Sequence -le $last.Sequence) { throw 'Duplicate, stale or conflicting result; current result retained.' } }
        if ($r.Status -eq 'Succeeded' -and $r.Stage -ne 'Inventory') { throw 'Restore/cutover adapters are not validated; success claims cannot unlock migration gates.' }
        $produced=[DateTimeOffset]::MinValue
        if (-not $r.PSObject.Properties['ProducedUtc'] -or -not [DateTimeOffset]::TryParse($r.ProducedUtc,[ref]$produced) -or $produced.Offset -ne [TimeSpan]::Zero) { throw 'Result requires a valid UTC ProducedUtc timestamp.' }
        $results+= $r; $c | Add-Member NoteProperty StageResults $results -Force
        Write-WsmJson (Get-WsmCatalogPath $Workspace $r.PairId) $c
    }
}
