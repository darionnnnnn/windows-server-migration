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
    $states=@('NotStarted','Ready','Running','Succeeded','Failed','Blocked','RetryPending','ManualEvidenceRequired','RebootRequired','Cancelled','Partial')
    if ($stages -cnotcontains $r.Stage -or $states -cnotcontains $r.Status -or ($r.Sequence -isnot [int] -and $r.Sequence -isnot [long]) -or $r.Sequence -lt 1) { throw 'Invalid stage result.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $r.PairId
        if ($r.BatchId -cne $c.BatchId -or $r.SourceHostId -cne $c.Source.HostId -or $r.InventoryRevision -ne $c.InventoryRevision -or $r.DecisionRevision -ne $c.DecisionRevision) { throw 'Result identity/revision mismatch.' }
        $results=@(); if ($c.PSObject.Properties['StageResults']) { $results=@($c.StageResults) }
        $older=@($results | Where-Object { $_.Stage -ceq $r.Stage -and $_.InventoryRevision -eq $c.InventoryRevision -and $_.DecisionRevision -eq $c.DecisionRevision -and ($r.Stage -ceq 'Inventory' -or ($_.PSObject.Properties['ApprovalId'] -and $_.ApprovalId -ceq $r.ApprovalId)) })
        if ($older.Count) { $last=$older | Sort-Object Sequence -Descending | Select-Object -First 1; if ($r.RunId -cne $last.RunId -or $r.Sequence -le $last.Sequence) { throw 'Duplicate, stale or conflicting result; current result retained.' } }
        if ($r.Stage -ne 'Inventory') {
            if(-not $c.Approval -or -not $c.Approval.PSObject.Properties['Kind'] -or $c.Approval.Kind -ne 'MigrationPlan' -or $r.ToolVersion -ne '0.3.0'){throw 'Unqualified restore/cutover success cannot unlock migration gates.'}
            foreach($field in @('Mode','ProductionVerified','ApprovalId','PlanHash','TargetHostId','TargetFingerprint','ManifestHash','PayloadGeneration','JournalHash')){if(-not $r.PSObject.Properties[$field]){throw 'Migration stage result requires sealed plan/target/generation binding.'}}
            Assert-WsmId $r.TargetHostId;Assert-WsmId $r.ApprovalId;if($r.ProductionVerified -isnot [bool] -or ($r.PayloadGeneration -isnot [int] -and $r.PayloadGeneration -isnot [long])){throw 'Stage result requires boolean qualification and integer generation.'}
            if($r.Mode -cne 'IsolatedPilot' -or $r.ProductionVerified -ne $false -or $r.ApprovalId -cne $c.Approval.ApprovalId -or $r.PlanHash -ine $c.Approval.Hash -or $r.TargetHostId -cne $c.Approval.TargetHostId -or $r.TargetFingerprint -cne $c.Approval.TargetFingerprint -or $r.ManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or $r.JournalHash -notmatch '^[a-f0-9]{64}$' -or $r.PayloadGeneration -lt 1){throw 'Stage result migration binding mismatch.'}
            $latest=@($results | Where-Object {$_.PSObject.Properties['PayloadGeneration'] -and $_.PSObject.Properties['ApprovalId'] -and $_.ApprovalId -ceq $r.ApprovalId} | Sort-Object PayloadGeneration -Descending | Select-Object -First 1);if($latest.Count -and $r.PayloadGeneration -lt $latest[0].PayloadGeneration){throw 'Stale payload generation result refused.'}
        }
        if($r.Stage -ne 'Inventory'){
            $sameGeneration=@($results | Where-Object {$_.PSObject.Properties['PayloadGeneration'] -and $_.PSObject.Properties['ApprovalId'] -and $_.ApprovalId -ceq $r.ApprovalId -and $_.PayloadGeneration -eq $r.PayloadGeneration})
            foreach($previous in $sameGeneration){if($previous.ManifestHash -ine $r.ManifestHash){throw 'Conflicting manifest for the same approved generation.'}}
        }
        $produced=[DateTimeOffset]::MinValue
        if (-not $r.PSObject.Properties['ProducedUtc'] -or -not [DateTimeOffset]::TryParse($r.ProducedUtc,[ref]$produced) -or $produced.Offset -ne [TimeSpan]::Zero) { throw 'Result requires a valid UTC ProducedUtc timestamp.' }
        if($produced -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){throw 'Source result clock exceeds accepted skew; synchronize and reissue.'}
        $sameProducer=@($results | Where-Object {
            if($_.InventoryRevision -ne $c.InventoryRevision -or $_.DecisionRevision -ne $c.DecisionRevision){return $false}
            if($r.Stage -ceq 'Inventory'){return ($_.Stage -ceq 'Inventory')}
            if(-not $_.PSObject.Properties['ApprovalId'] -or $_.ApprovalId -cne $r.ApprovalId){return $false}
            if($r.Stage -cin @('Export','FinalDelta')){return ($_.Stage -cin @('Export','FinalDelta'))}
            return ($_.Stage -cnotin @('Inventory','Export','FinalDelta'))
        })
        foreach($previous in $sameProducer){
            if($previous.RunId -cne $r.RunId -or $r.Sequence -le $previous.Sequence -or $produced -lt [DateTimeOffset]::Parse($previous.ProducedUtc)){throw 'Producer run/sequence/time regression; retain the current evidence.'}
        }
        $results+= $r; $c | Add-Member NoteProperty StageResults $results -Force
        Write-WsmJson (Get-WsmCatalogPath $Workspace $r.PairId) $c
    }
}

function Get-WsmLatestStageResult($Catalog) {
    if(-not $Catalog.PSObject.Properties['StageResults'] -or -not $Catalog.StageResults.Count){return $null}
    $current=@($Catalog.StageResults | Where-Object {(Test-WsmStageResultCurrent $Catalog $_)})
    if(-not $current.Count){$current=@($Catalog.StageResults)}
    $current | Sort-Object @{Expression={if($_.PSObject.Properties['PayloadGeneration']){[long]$_.PayloadGeneration}else{0}};Descending=$true},@{Expression={[DateTimeOffset]::Parse($_.ProducedUtc)};Descending=$true},@{Expression={[long]$_.Sequence};Descending=$true} | Select-Object -First 1
}
function Get-WsmStageResultSummary($Catalog) {
    if(-not $Catalog.PSObject.Properties['StageResults']){return ''}
    $latest=Get-WsmLatestStageResult $Catalog
    if(-not $latest){return ''}
    $rows=@($Catalog.StageResults | Where-Object {(Test-WsmStageResultCurrent $Catalog $_) -and ((-not $latest.PSObject.Properties['PayloadGeneration'] -and $_.Stage -ceq 'Inventory') -or ($_.PSObject.Properties['PayloadGeneration'] -and $_.PayloadGeneration -eq $latest.PayloadGeneration))})
    @($rows | Group-Object Stage | ForEach-Object {$row=$_.Group | Sort-Object Sequence -Descending | Select-Object -First 1;$row.Stage+':'+$row.Status} | Sort-Object) -join '; '
}
function Test-WsmStageResultCurrent($Catalog,$Result) {
    if($Result.InventoryRevision -ne $Catalog.InventoryRevision -or $Result.DecisionRevision -ne $Catalog.DecisionRevision){return $false}
    if($Result.Stage -ceq 'Inventory'){return $true}
    if(-not $Catalog.Approval -or -not $Catalog.Approval.PSObject.Properties['ApprovalId'] -or -not $Result.PSObject.Properties['ApprovalId']){return $false}
    $Result.ApprovalId -ceq $Catalog.Approval.ApprovalId -and $Result.PlanHash -ieq $Catalog.Approval.Hash -and $Result.TargetHostId -ceq $Catalog.Approval.TargetHostId -and $Result.TargetFingerprint -ceq $Catalog.Approval.TargetFingerprint
}