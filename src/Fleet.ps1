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
function Assert-WsmAssistiveFileResultRows($Assistive,[long]$Generation) {
    if(-not $Assistive.PSObject.Properties['FileResults'] -or $Assistive.FileResults -isnot [array]){throw 'Schema 3 stage result requires complete per-file result rows.'}
    $fields=@('ItemId','EntryId','RelativePath','Channel','OriginalPath','PreservedPath','EffectivePath','Status','ExistingTargetPath','ExistingTargetHash','ObservedHash','SourceHash','Reason','Generation','ProjectedGeneration')
    $statuses=@('Applied','VerifiedOwned','DirectoryReady','BlockedConflict','DeferredManual','Deferred','Failed')
    $approved=@{};foreach($id in @($Assistive.ApprovedItemIds)){$approved[[string]$id]=$true}
    $seen=@{}
    foreach($row in @($Assistive.FileResults)){
        Assert-WsmFields $row $fields $fields
        foreach($field in $fields){if(-not $row.PSObject.Properties[$field]){throw ('Assistive file result is missing '+$field+'.')}}
        foreach($field in @('ItemId','EntryId','RelativePath','Channel','OriginalPath','PreservedPath','EffectivePath','Status','ExistingTargetPath','Reason')){
            if($row.$field -isnot [string] -or ([string]$row.$field).Length -gt 32768 -or [string]$row.$field -match '[\x00-\x1f]'){throw ('Assistive file result has an invalid '+$field+'.')}
        }
        foreach($field in @('ExistingTargetHash','ObservedHash','SourceHash')){if($row.$field -isnot [string] -or ([string]$row.$field -and [string]$row.$field -notmatch '^[a-fA-F0-9]{64}$')){throw ('Assistive file result has an invalid '+$field+'.')}}
        foreach($field in @('Generation','ProjectedGeneration')){if(($row.$field -isnot [int] -and $row.$field -isnot [long]) -or [long]$row.$field -ne $Generation){throw 'Assistive per-file result is not bound to the current projected generation.'}}
        if(-not $approved.ContainsKey([string]$row.ItemId) -or [string]$row.ItemId -notmatch '^[a-f0-9]{64}$' -or @('C','NonC','External','Unknown') -cnotcontains [string]$row.Channel -or $statuses -cnotcontains [string]$row.Status){throw 'Assistive file result is outside the approved item/channel/status contract.'}
        foreach($field in @('OriginalPath','PreservedPath','EffectivePath','ExistingTargetPath')){
            $path=[string]$row.$field
            $components=@($path -split '[\\/]+' | Where-Object {$_})
            $alternateStream=$false;if($path -match '^[A-Za-z]:'){$alternateStream=$path.Substring(2).Contains(':')}
            if($path -and ($path -match '[<>"|?*]' -or $alternateStream -or $path -match '^(?i:\\\\[?.\\])' -or $path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))' -or @($components | Where-Object {$_ -in @('.','..') -or $_ -match '[ .]$'}).Count)){throw ('Assistive file result has an unsafe '+$field+'.')}
        }
        $relative=[string]$row.RelativePath
        if($relative -and ($relative -match '^(?:[A-Za-z]:|[\\/])' -or $relative -match '[:<>"|?*]' -or @($relative -split '[\\/]+' | Where-Object {$_ -in @('.','..')}).Count -or $relative -match '[\\/]{2}')){throw 'Assistive file result has an unsafe relative path.'}
        if(-not $relative -and ($row.EntryId -or $row.Status -in @('Applied','VerifiedOwned'))){throw 'A concrete file result requires its relative path.'}
        if($row.Status -in @('Applied','VerifiedOwned','DirectoryReady') -and -not [string]$row.EffectivePath){throw 'A verified file or directory result requires its effective target path.'}
        if($row.Channel -ceq 'NonC') {if([string]$row.EntryId -notmatch '^[a-fA-F0-9]{64}$'){throw 'NonC per-file results require their exact transfer EntryId.'}}
        elseif([string]$row.EntryId){throw 'Only NonC transfer rows may carry an EntryId.'}
        if([string]$row.Reason -match '(?i)(?:password|passwd|pwd|secret|token|credential|private\s*key)\s*[:=]|<\?xml|<!DOCTYPE|<\w+[\s>]' ){throw 'Assistive file result reason contains secret-like or raw configuration material.'}
        if($row.Status -notin @('Applied','VerifiedOwned','DirectoryReady') -and [string]$row.EffectivePath){throw 'Unverified file results must leave EffectivePath empty.'}
        if($row.Status -in @('Applied','VerifiedOwned') -and (-not $row.SourceHash -or -not $row.ObservedHash -or $row.SourceHash -ine $row.ObservedHash)){throw 'Applied file result must bind matching source and observed content hashes.'}
        $key=([string]$row.ItemId)+'|'+[string]$row.Channel+'|'+[string]$row.EntryId+'|'+([string]$row.RelativePath).ToLowerInvariant()
        if($seen.ContainsKey($key)){throw 'Assistive file result has duplicate item/channel/entry/path rows.'};$seen[$key]=$true
    }
}

function Import-WsmStageResult {
    param([string]$Workspace,[string]$Path,[string]$ExpectedHash)
    $r=Read-WsmTrustedJson $Path $ExpectedHash; Assert-WsmEnvelope $r 'StageResult'
    Assert-WsmId $r.PairId; Assert-WsmId $r.RunId
    $stages=@('Inventory','Export','Restore','PreCutoverValidation','FinalDelta','Cutover','PostCutoverValidation','Retirement')
    $states=@('NotStarted','Ready','Running','Succeeded','Failed','Blocked','RetryPending','ManualEvidenceRequired','RebootRequired','Cancelled','Partial','Deferred','DeferredSoftware','WaitForInstall','BlockedConflict')
    if ($stages -cnotcontains $r.Stage -or $states -cnotcontains $r.Status -or ($r.Sequence -isnot [int] -and $r.Sequence -isnot [long]) -or $r.Sequence -lt 1) { throw 'Invalid stage result.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $r.PairId
        if($c.SchemaVersion -eq 3 -and $r.ToolVersion -cne '0.4.0'){throw 'Legacy stage results cannot be imported into or promote a schema 3 migration.'}
        if ($r.BatchId -cne $c.BatchId -or $r.SourceHostId -cne $c.Source.HostId -or $r.InventoryRevision -ne $c.InventoryRevision -or $r.DecisionRevision -ne $c.DecisionRevision) { throw 'Result identity/revision mismatch.' }
        $results=@(); if ($c.PSObject.Properties['StageResults']) { $results=@($c.StageResults) }
        $older=@($results | Where-Object { $_.Stage -ceq $r.Stage -and $_.InventoryRevision -eq $c.InventoryRevision -and $_.DecisionRevision -eq $c.DecisionRevision -and ($r.Stage -ceq 'Inventory' -or ($_.PSObject.Properties['ApprovalId'] -and $_.ApprovalId -ceq $r.ApprovalId)) })
        if ($older.Count) { $last=$older | Sort-Object Sequence -Descending | Select-Object -First 1; if ($r.RunId -cne $last.RunId -or $r.Sequence -le $last.Sequence) { throw 'Duplicate, stale or conflicting result; current result retained.' } }
        if ($r.Stage -ne 'Inventory') {
            $schema3=($c.SchemaVersion -eq 3)
            $expectedVersion='0.3.0';if($schema3){$expectedVersion='0.4.0'}
            if(-not $c.Approval -or -not $c.Approval.PSObject.Properties['Kind'] -or $c.Approval.Kind -ne 'MigrationPlan' -or ($schema3 -and $r.ToolVersion -cne $expectedVersion) -or (-not $schema3 -and $r.ToolVersion -cnotin @('0.3.0','0.4.0'))){throw 'Stage result tool version does not match the current approved plan schema.'}
            foreach($field in @('Mode','ProductionVerified','ApprovalId','PlanHash','TargetHostId','TargetFingerprint','ManifestHash','PayloadGeneration','JournalHash')){if(-not $r.PSObject.Properties[$field]){throw 'Migration stage result requires sealed plan/target/generation binding.'}}
            Assert-WsmId $r.TargetHostId;Assert-WsmId $r.ApprovalId;if($r.ProductionVerified -isnot [bool] -or ($r.PayloadGeneration -isnot [int] -and $r.PayloadGeneration -isnot [long])){throw 'Stage result requires boolean qualification and integer generation.'}
            if($r.Mode -cne 'IsolatedPilot' -or $r.ProductionVerified -ne $false -or $r.ApprovalId -cne $c.Approval.ApprovalId -or $r.PlanHash -ine $c.Approval.Hash -or $r.TargetHostId -cne $c.Approval.TargetHostId -or $r.TargetFingerprint -cne $c.Approval.TargetFingerprint -or $r.ManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or $r.JournalHash -notmatch '^[a-f0-9]{64}$' -or $r.PayloadGeneration -lt 1){throw 'Stage result migration binding mismatch.'}
            if($schema3){
                if(-not $r.PSObject.Properties['Assistive'] -or $null -eq $r.Assistive){throw 'Assistive stage result requires its per-item Assistive binding; legacy flat results cannot attest an Assistive generation.'}
                $assistive=$r.Assistive
                Assert-WsmFields $assistive @('ApprovedItemIds','ItemResults','AppliedItemIds','PendingItemIds','DeferredItemIds','FileResults') @('ApprovedItemIds','ItemResults','AppliedItemIds','PendingItemIds','DeferredItemIds','FileResults')
                foreach($field in @('ApprovedItemIds','ItemResults','AppliedItemIds','PendingItemIds','DeferredItemIds','FileResults')){if(-not $assistive.PSObject.Properties[$field]){throw ('Assistive stage result is missing '+$field+'.')}}
                foreach($field in @('ApprovedItemIds','ItemResults','AppliedItemIds','PendingItemIds','DeferredItemIds','FileResults')){if($assistive.$field -isnot [array]){throw ('Assistive '+$field+' must be an array.')}}
                $expectedList=New-Object 'System.Collections.Generic.List[string]';foreach($item in @($c.Items)){$selection=@($c.Assistive.Selections.Items | Where-Object ItemId -CEQ $item.ItemId);if($item.Decision -ceq 'Include' -and $selection.Count -eq 1 -and $selection[0].Selected){$expectedList.Add([string]$item.ItemId)}};$expectedIds=@($expectedList.ToArray() | Sort-Object -Unique)
                $reportedIds=@();$approvedSeen=@{};foreach($id in @($assistive.ApprovedItemIds)){if([string]$id -notmatch '^[a-f0-9]{64}$' -or $approvedSeen.ContainsKey([string]$id)){throw 'Assistive approved item identity is malformed or duplicated.'};$approvedSeen[[string]$id]=$true;$reportedIds+= [string]$id}
                if((@($reportedIds | Sort-Object -Unique) -join '|') -cne ($expectedIds -join '|')){throw 'Assistive stage result approved item set differs from the exact current selected Include set.'}
                $itemSeen=@{};$itemIds=@();$appliedExpected=@();$pendingExpected=@();$deferredExpected=@();$itemStatuses=@('Succeeded','Failed','Blocked','BlockedConflict','Deferred','DeferredSoftware','WaitForInstall','ManualEvidenceRequired','RebootRequired','Cancelled','Partial','NotTested')
                foreach($itemResult in @($assistive.ItemResults)){
                    Assert-WsmFields $itemResult @('ItemId','Decision','Status','AppliedManifestHash','AppliedGeneration','Pending','Deferred') @('ItemId','Decision','Status','AppliedManifestHash','AppliedGeneration','Pending','Deferred')
                    foreach($field in @('ItemId','Decision','Status','AppliedManifestHash','AppliedGeneration','Pending','Deferred')){if(-not $itemResult.PSObject.Properties[$field]){throw ('Assistive item result is missing '+$field+'.')}}
                    if([string]$itemResult.ItemId -notmatch '^[a-f0-9]{64}$' -or -not $approvedSeen.ContainsKey([string]$itemResult.ItemId) -or $itemSeen.ContainsKey([string]$itemResult.ItemId) -or [string]$itemResult.Decision -cne 'Include' -or $itemStatuses -cnotcontains [string]$itemResult.Status -or $itemResult.Pending -isnot [bool] -or $itemResult.Deferred -isnot [bool] -or ($itemResult.AppliedGeneration -isnot [int] -and $itemResult.AppliedGeneration -isnot [long])){throw 'Assistive item result is malformed, duplicated, outside the approved set, or has an unknown status.'}
                    $applied=($itemResult.Status -ceq 'Succeeded' -and [string]$itemResult.AppliedManifestHash -ieq [string]$r.ManifestHash -and [long]$itemResult.AppliedGeneration -eq [long]$r.PayloadGeneration -and -not $itemResult.Pending -and -not $itemResult.Deferred)
                    if(($itemResult.Status -ceq 'Succeeded') -ne $applied){throw 'Assistive success must bind to the exact current manifest and generation with no pending/deferred state.'}
                    if($itemResult.Pending){$pendingExpected+= [string]$itemResult.ItemId};if($itemResult.Deferred -or $itemResult.Status -in @('Deferred','DeferredSoftware','WaitForInstall')){$deferredExpected+= [string]$itemResult.ItemId};if($applied){$appliedExpected+= [string]$itemResult.ItemId}
                    $itemSeen[[string]$itemResult.ItemId]=$true;$itemIds+= [string]$itemResult.ItemId
                }
                if((@($itemIds | Sort-Object -Unique) -join '|') -cne ($expectedIds -join '|')){throw 'Assistive stage result item rows do not exactly cover the approved item set.'}
                foreach($tuple in @(@{Field='AppliedItemIds';Expected=$appliedExpected},@{Field='PendingItemIds';Expected=$pendingExpected},@{Field='DeferredItemIds';Expected=$deferredExpected})){
                    $actual=@();$seenIds=@{};foreach($id in @($assistive.($tuple.Field))){if(-not $approvedSeen.ContainsKey([string]$id) -or $seenIds.ContainsKey([string]$id)){throw ('Assistive '+$tuple.Field+' contains an unknown or duplicate item.')};$seenIds[[string]$id]=$true;$actual+= [string]$id}
                    if((@($actual | Sort-Object -Unique) -join '|') -cne (@($tuple.Expected | Sort-Object -Unique) -join '|')){throw ('Assistive '+$tuple.Field+' does not match the recorded per-item states.')}
                }
                Assert-WsmAssistiveFileResultRows $assistive ([long]$r.PayloadGeneration)
            }
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
    $summary=''
    if($Catalog.PSObject.Properties['StageResults']){$latest=Get-WsmLatestStageResult $Catalog;if($latest){$rows=@($Catalog.StageResults | Where-Object {(Test-WsmStageResultCurrent $Catalog $_) -and ((-not $latest.PSObject.Properties['PayloadGeneration'] -and $_.Stage -ceq 'Inventory') -or ($_.PSObject.Properties['PayloadGeneration'] -and $_.PayloadGeneration -eq $latest.PayloadGeneration))});$summary=@($rows | Group-Object Stage | ForEach-Object {$row=$_.Group | Sort-Object Sequence -Descending | Select-Object -First 1;$row.Stage+':'+$row.Status} | Sort-Object) -join '; '}}
    if($Catalog.PSObject.Properties['GeneralHost']){
        $target='';if($Catalog.Approval -and $Catalog.Approval.PSObject.Properties['TargetFingerprint']){$target=[string]$Catalog.Approval.TargetFingerprint}
        if($target){$projection=Get-WsmGeneralHostReadinessProjection $Catalog $target '' $(if($Catalog.Approval.PSObject.Properties['Hash']){$Catalog.Approval.Hash}else{''});$issues=@($projection.PendingIssues)}else{$issues=@(Get-WsmGeneralHostIssues $Catalog ReviewComplete)}
        $suffix='GeneralHost:'+$(if($issues.Count){'Blocked'}else{'ReadyForReview'});if($issues.Count){$suffix+=' ['+(@($issues | ForEach-Object {($_.Gate+'/'+$_.ConsumerItemId+': '+$_.Issue)} | Select-Object -First 30) -join ' | ')+']';if($issues.Count -gt 30){$suffix+=' | '+($issues.Count-30)+' additional issues'}}
        if($summary){$summary+='; '};$summary+=$suffix
    }
    $summary
}
function Get-WsmFleetDeliverySummary($Catalog) {
    if(-not (Get-Command Get-WsmDeliveryReceiptSummary -ErrorAction SilentlyContinue)){return [pscustomobject]@{Status='ReceiptSupportUnavailable';Mode='';Generation=0;VolumeCount=0;TotalVolumeBytes=0;TransportHash='';DeliveryId='';ReportOnly=$true;ReadinessProof=$false;ProductionVerified=$false}}
    Get-WsmDeliveryReceiptSummary $Catalog
}
function Test-WsmStageResultCurrent($Catalog,$Result) {
    if($Result.InventoryRevision -ne $Catalog.InventoryRevision -or $Result.DecisionRevision -ne $Catalog.DecisionRevision){return $false}
    if($Result.Stage -ceq 'Inventory'){return $true}
    if(-not $Catalog.Approval -or -not $Catalog.Approval.PSObject.Properties['ApprovalId'] -or -not $Result.PSObject.Properties['ApprovalId']){return $false}
    $Result.ApprovalId -ceq $Catalog.Approval.ApprovalId -and $Result.PlanHash -ieq $Catalog.Approval.Hash -and $Result.TargetHostId -ceq $Catalog.Approval.TargetHostId -and $Result.TargetFingerprint -ceq $Catalog.Approval.TargetFingerprint
}
