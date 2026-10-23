#requires -Version 5.1
# P5-b: after N9h, a NonC-labelled FileScope of an OfflineFullSet CV2 plan is written by the CV2 FileScope writer and therefore creates a shared-resource
# reservation (Get-WsmAssistiveReservations, channel label still 'NonC'). This test drives the three outcomes (success, failure, cancellation) through the real
# Invoke-WsmAssistiveRestore loop and the real reservation registry (preview, reserve, evidence, owner records) for BOTH a C-labelled and a NonC-labelled scope
# and requires the two to behave identically except for the channel label. It also checks that a later restore / repair / second restore is neither wrongly
# blocked nor wrongly let through by a leftover reservation.
# Doubles: only the FileScope writer (the file bytes are not the subject; it succeeds, throws, or requests the owner cancellation through the REAL token and
# the REAL Assert-WsmCancellationBoundary), plus package / receipt edges that Test-TargetRestoreContinuation.ps1 also replaces.
# Design facts the test pins (current product behaviour): a reservation is made before the writer runs; success records evidence (DriftStatus Match);
# failure and cancellation keep the reservation as Unverified for reconciliation (nothing releases it automatically); only an explicit
# Release-WsmAssistiveResource releases it.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-cv2-nonc-resv-'+[Guid]::NewGuid().ToString('N'))
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Generated test root unexpectedly already exists.'}
[void][IO.Directory]::CreateDirectory($root)
$checks=0
try {
    $checks=& $module {
        param($root)
        $script:checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw ('FAIL: '+$message)};$script:checks++}
        $pairsDirectory=Join-Path $root 'pairs';[void][IO.Directory]::CreateDirectory($pairsDirectory)
        $manifestHash='a'*64;$planHash='b'*64;$fingerprint='c'*64;$previewHash='d'*64;$receiptHash='e'*64;$snapshotHash='f'*64

        $script:fixture=$null;$script:writerCalls=@();$script:writerMode=@{}
        Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value {param($Package,[string]$ManifestHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$SnapshotPath)$script:fixture.Decision}
        Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value {param($Package,$Decision)$true}
        Set-Item Function:\Register-WsmAssistivePackageMaterials -Value {param($Package,$Decision,[string]$Workspace,$Preview)[pscustomobject]@{OperationId='fixture-material-job';MaterialIds=@()}}
        Set-Item Function:\Complete-WsmAssistivePackageJob -Value {param($Package,$Job,[string]$Workspace)}
        Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value {param([string]$StateDirectory,[string]$PairId,[string]$PlanHash)}
        Set-Item Function:\Get-WsmMachineIdentity -Value {[pscustomobject]@{Fingerprint=('c'*64)}}
        Set-Item Function:\Read-WsmMigrationPlan -Value {param([string]$Path,[string]$ExpectedHash)[pscustomobject]@{Target=[pscustomobject]@{Fingerprint=('c'*64)}}}
        Set-Item Function:\Read-WsmArtifactLines -Value {param([string]$Path,[string]$ExpectedHash,$CancellationToken)@()}
        # The FileScope writer double. Cancel: the owner cancellation is requested through the real token and observed by the real boundary check.
        Set-Item Function:\Invoke-WsmAssistiveFileScopeRestore -Value {param($Item,$Package,$Paths,$State,[hashtable]$SidMap,$CancellationToken,[string]$Workspace='')
            $script:writerCalls+=@([string]$Item.ItemId);$mode=[string]$script:writerMode[[string]$Item.ItemId]
            if($mode -ceq 'Fail'){throw 'P5 injected FileScope writer failure'}
            if($mode -ceq 'Cancel'){[void](Request-WsmCancellation $CancellationToken 'P5 test owner' 'P5 owner cancellation evidence');Assert-WsmCancellationBoundary $CancellationToken 'P5FileScopeWriter';throw 'P5: the cancellation boundary did not fire'}
            [pscustomobject]@{ItemId=$Item.ItemId;Status='Succeeded';CreatedByTool=$true;AppliedManifestHash=$manifestHash;AppliedGeneration=7;ActualHash=('9'*64);Target=[string]$Item.MigrationSpec.TargetPath;OwnedFiles=@();OwnedDirectories=@();Error='';NativeCode=0}}

        function NewScopeItem([string]$Pair,[string]$Channel,[string]$Name,[string]$TargetPath,[string]$Owner='P5 owner'){
            [void][IO.Directory]::CreateDirectory($TargetPath)
            $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$TargetPath;TargetPath=$TargetPath;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner=$Owner;Evidence='P5 fixture';TransferChannel=$Channel;ContentSelection='WholeScope'}
            [pscustomobject]@{ItemId=(Get-WsmHashText ('p5-resv-'+$Pair+'-'+$Channel+'-'+$Name+'-'+$TargetPath));Name=$Name;Kind='FileScope';Decision='Include';MigrationSpec=$spec}
        }
        function NewFixture([string]$Channel,[string[]]$Names=@('A')){
            $pair=[Guid]::NewGuid().ToString('D');$base=Join-Path $root ('t-'+$pair.Substring(0,8))
            $items=@();foreach($name in $Names){$items+=@(NewScopeItem $pair $Channel $name (Join-Path $base $name))}
            [pscustomobject]@{Pair=$pair;Channel=$Channel;Base=$base;Items=$items;Package=(NewPackage $pair $items);Decision=(NewDecision $items)}
        }
        function NewPackage([string]$Pair,$Items){[pscustomobject]@{Root=(Join-Path $root 'backup-media-fixture');PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Assistive=[pscustomobject]@{ContractVersion=2};Items=@($Items)};Manifest=[pscustomobject]@{PairId=$Pair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;ArtifactsHash=('1'*64);Target=[pscustomobject]@{Fingerprint=$fingerprint}}}}
        function NewDecision($Items){[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $root 'decision.json');ReceiptHash=$receiptHash;SnapshotPath=(Join-Path $root 'snapshot.json');SelectedItemIds=@($Items|ForEach-Object {$_.ItemId});Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=$snapshotHash}}}
        function Rebind($Fixture,$Items){$Fixture.Items=@($Items);$Fixture.Package=(NewPackage $Fixture.Pair $Items);$Fixture.Decision=(NewDecision $Items)}
        function NewToken($Fixture){$op=[Guid]::NewGuid().ToString('D');[pscustomobject]@{Token=(New-WsmCancellationToken $Fixture.Pair $planHash $manifestHash $op $pairsDirectory);Op=$op}}
        function RestoreNow($Fixture,$Items=$null){
            if($Items){Rebind $Fixture $Items}
            $rows=@($Fixture.Items|ForEach-Object {[pscustomobject]@{ItemId=$_.ItemId;Adapter='FileScope';Action='RestoreNow';Status='Ready';Reason=''}})
            $preview=[pscustomobject]@{Rows=$rows;SelectedItemIds=@($Fixture.Items|ForEach-Object {$_.ItemId});Problems=@();GeneralHostIssues=@();Blocked=$false;CanRestoreIndependentItems=$true;WizardPreviewHash=$previewHash}
            $t=NewToken $Fixture;$script:fixture=$Fixture
            Invoke-WsmAssistiveRestore -Package $Fixture.Package -ManifestHash $manifestHash -StateDirectory $pairsDirectory -Secrets @{} -SidMap @{} -CancellationToken $t.Token -GeneralHostEvidence @() -ReceiptPath $Fixture.Decision.ReceiptPath -ReceiptHash $receiptHash -TargetSnapshotPath $Fixture.Decision.SnapshotPath -Preview $preview -ParentOperationId $t.Op
        }
        function OwnerOf($Item){
            $registry=Get-WsmAssistiveResourceRegistry $pairsDirectory
            $found=@(foreach($record in @($registry.Resources)){foreach($owner in @($record.Owners)){if([string]$owner.ItemId -ceq [string]$Item.ItemId){[pscustomobject]@{Record=$record;Owner=$owner}}}})
            $found
        }
        function Shape($Item){
            # Channel-neutral description of one reservation owner record: the part that must be identical for C and NonC.
            $rows=@(OwnerOf $Item);if($rows.Count -ne 1){return ('owners='+$rows.Count)}
            $o=$rows[0].Owner
            ('owners=1;drift='+[string]$o.DriftStatus+';evidence='+$(if([string]$o.EvidenceHash){'yes'}else{'no'})+';desired='+$(if($null -ne $o.Desired){'yes'}else{'no'})+';readback='+$(if($null -ne $o.Readback){'yes'}else{'no'})+';active='+$(if([string]$o.ActiveOperationId){'yes'}else{'no'})+';kind='+[string]$o.ResourceKind)
        }
        function ResultOf($Result,$Item){@($Result.Results|Where-Object ItemId -CEQ $Item.ItemId)}
        function StateOf($Fixture){Read-WsmJson (Get-WsmOperationPaths $pairsDirectory $Fixture.Pair).State}
        function Reset(){$script:writerCalls=@();$script:writerMode=@{}}

        $observed=@{}
        foreach($channel in @('C','NonC')){
            $log=New-Object 'System.Collections.Generic.List[string]'

            # ---------- success: the reservation is made, evidence recorded, and it stays (owned) after the parent completes ----------
            Reset;$s=NewFixture $channel;$a=$s.Items[0];$script:writerMode[$a.ItemId]='Succeed'
            $r=RestoreNow $s
            $own=@(OwnerOf $a)
            Check ($own.Count -eq 1) ($channel+' success: expected exactly one reservation owner record for the scope (a CV2 scope must reserve its target).')
            Check ([string]$own[0].Owner.Channel -ceq $channel -and [string]$own[0].Record.ResourceKind -ceq 'FileScope') ($channel+' success: the owner record must carry the channel label of the scope and the FileScope kind.')
            Check ([string]$own[0].Owner.DriftStatus -ceq 'Match' -and [string]$own[0].Owner.EvidenceHash -match '^[a-f0-9]{64}$' -and $null -ne $own[0].Owner.Desired -and $null -ne $own[0].Owner.Readback) ($channel+' success: evidence (desired, readback, Match) was not recorded on the reservation.')
            Check ([string]$r.Stage -ceq 'Succeeded' -and (ResultOf $r $a)[0].Status -ceq 'Succeeded' -and @((ResultOf $r $a)[0].ResourceReservations).Count -eq 1 -and [string]@((ResultOf $r $a)[0].ResourceReservations)[0] -ceq [string]$own[0].Record.ResourceKey) ($channel+' success: the item result does not list the reservation it holds.')
            Check ($script:writerCalls.Count -eq 1) ($channel+' success: the writer must be called once.')
            $log.Add('success|'+(Shape $a))

            # ---------- failure: writer throws -> the reservation is kept, unverified, for reconciliation (same for C and NonC) ----------
            Reset;$f=NewFixture $channel -Names @('A');$fa=$f.Items[0];$script:writerMode[$fa.ItemId]='Fail'
            $rf=RestoreNow $f;$stf=StateOf $f
            Check ($script:writerCalls.Count -eq 1 -and (ResultOf $rf $fa)[0].Status -ceq 'Failed' -and [string]$rf.Stage -ceq 'Partial') ($channel+' failure: the injected writer failure was not reached or not reported as a Failed item.')
            $own=@(OwnerOf $fa)
            Check ($own.Count -eq 1 -and [string]$own[0].Owner.Channel -ceq $channel) ($channel+' failure: the reservation of a failed item must be retained, not silently dropped.')
            Check ([string]$own[0].Owner.DriftStatus -ceq 'Unverified' -and -not [string]$own[0].Owner.EvidenceHash -and $null -eq $own[0].Owner.Desired -and $null -eq $own[0].Owner.Readback) ($channel+' failure: a failed item may not carry evidence (it must stay Unverified).')
            Check (@($stf.PendingOperations).Count -eq 0) ($channel+' failure: the FileScope failure double leaves no pending operation; the test assumes a clean state.')
            $log.Add('failure|'+(Shape $fa))

            # -- leftover reservation versus other consumers (same failed state) --
            $x=NewScopeItem $f.Pair $channel 'X' $fa.MigrationSpec.TargetPath 'P5 other owner'      # same target, different reviewed source -> different consumer
            $y=NewScopeItem $f.Pair $channel 'Y' (Join-Path $fa.MigrationSpec.TargetPath 'child') 'P5 child owner'    # inside the reserved scope
            $z=NewScopeItem $f.Pair $channel 'Z' (Join-Path $f.Base 'Z') 'P5 sibling owner'          # unrelated sibling directory
            foreach($i in @($x,$y,$z)){$script:writerMode[$i.ItemId]='Succeed'}
            $script:writerCalls=@();$rx=RestoreNow $f -Items @($x,$y,$z)
            Check ((ResultOf $rx $x)[0].Status -ceq 'Failed' -and (ResultOf $rx $y)[0].Status -ceq 'Failed' -and $script:writerCalls -notcontains $x.ItemId -and $script:writerCalls -notcontains $y.ItemId) ($channel+' after failure: a different consumer of the same or an overlapping target must stay blocked by the leftover reservation (wrongly let through).')
            Check ((ResultOf $rx $z)[0].Status -ceq 'Succeeded' -and $script:writerCalls -contains $z.ItemId -and @(OwnerOf $z).Count -eq 1) ($channel+' after failure: an unrelated sibling scope must not be blocked by the leftover reservation (wrongly blocked).')
            Check (@(OwnerOf $x).Count -eq 0 -and @(OwnerOf $y).Count -eq 0) ($channel+' after failure: a blocked consumer must not have created a reservation of its own.')
            $log.Add('blocked-while-unverified|x='+(ResultOf $rx $x)[0].Status+';y='+(ResultOf $rx $y)[0].Status+';z='+(ResultOf $rx $z)[0].Status)

            # -- repair-style second restore of the same item: it adopts its own leftover reservation and completes it --
            $script:writerMode[$fa.ItemId]='Succeed';$script:writerCalls=@()
            $r2=RestoreNow $f -Items @($fa)
            $own=@(OwnerOf $fa)
            Check ((ResultOf $r2 $fa)[0].Status -ceq 'Succeeded' -and $script:writerCalls.Count -eq 1 -and [string]$r2.Stage -ceq 'Succeeded') ($channel+' retry: the second restore of the failed item did not succeed (its own leftover reservation must not block it).')
            Check ($own.Count -eq 1 -and [string]$own[0].Owner.DriftStatus -ceq 'Match' -and [string]$own[0].Owner.EvidenceHash -match '^[a-f0-9]{64}$') ($channel+' retry: the retried item must reuse its single reservation and finish it with evidence.')
            $log.Add('retry|'+(Shape $fa))
            # -- once owned, other consumers of that target are still blocked; an explicit release opens it --
            $script:writerCalls=@();$rb=RestoreNow $f -Items @($x)
            Check ((ResultOf $rb $x)[0].Status -ceq 'Failed' -and $script:writerCalls.Count -eq 0) ($channel+' owned: another consumer must stay blocked while the scope is owned.')
            $rev=(Get-WsmAssistiveResourceRegistry $pairsDirectory).Revision
            [void](Release-WsmAssistiveResource -Workspace $pairsDirectory -ResourceKey ([string]$own[0].Record.ResourceKey) -PairId $f.Pair -ItemId $fa.ItemId -Channel $channel -ExpectedRevision $rev -Reason 'P5 explicit release after reconciliation')
            Check (@(OwnerOf $fa).Count -eq 0) ($channel+' release: the explicit release did not remove the owner record.')
            $script:writerCalls=@();$rc=RestoreNow $f -Items @($x)
            Check ((ResultOf $rc $x)[0].Status -ceq 'Succeeded' -and $script:writerCalls.Count -eq 1 -and @(OwnerOf $x).Count -eq 1) ($channel+' release: after the release the other consumer must be allowed and reserve the scope.')
            $log.Add('after-release|x='+(ResultOf $rc $x)[0].Status+';'+(Shape $x))

            # ---------- failure that was never retried: an unverified reservation is releasable (nobody is stuck forever) ----------
            Reset;$u=NewFixture $channel;$ua=$u.Items[0];$script:writerMode[$ua.ItemId]='Fail';[void](RestoreNow $u)
            $own=@(OwnerOf $ua);$rev=(Get-WsmAssistiveResourceRegistry $pairsDirectory).Revision
            [void](Release-WsmAssistiveResource -Workspace $pairsDirectory -ResourceKey ([string]$own[0].Record.ResourceKey) -PairId $u.Pair -ItemId $ua.ItemId -Channel $channel -ExpectedRevision $rev -Reason 'P5 explicit release of an unverified reservation')
            Check (@(OwnerOf $ua).Count -eq 0) ($channel+' unverified release: a failed item reservation could not be released.')
            $log.Add('unverified-release|ok')

            # ---------- cancellation: the owner requests it through the real token while the writer is running ----------
            Reset;$c=NewFixture $channel;$ca=$c.Items[0];$script:writerMode[$ca.ItemId]='Cancel'
            $rcnl=RestoreNow $c;$stc=StateOf $c
            Check ([string]$rcnl.Stage -ceq 'Cancelled' -and [string]$stc.Stage -ceq 'Cancelled' -and $script:writerCalls.Count -eq 1) ($channel+' cancel: the real cancellation token did not stop the restore at the writer boundary.')
            Check (@($rcnl.Results|Where-Object ItemId -CEQ $ca.ItemId).Count -eq 0) ($channel+' cancel: a cancelled item must not get a result.')
            $own=@(OwnerOf $ca)
            Check ($own.Count -eq 1 -and [string]$own[0].Owner.Channel -ceq $channel -and [string]$own[0].Owner.DriftStatus -ceq 'Unverified' -and -not [string]$own[0].Owner.EvidenceHash) ($channel+' cancel: the reservation of a cancelled item must be retained as Unverified (same rule as failure).')
            $log.Add('cancel|'+(Shape $ca))
            $cx=NewScopeItem $c.Pair $channel 'X' $ca.MigrationSpec.TargetPath 'P5 other owner';$script:writerMode[$cx.ItemId]='Succeed';$script:writerCalls=@()
            $rcx=RestoreNow $c -Items @($cx)
            Check ((ResultOf $rcx $cx)[0].Status -ceq 'Failed' -and $script:writerCalls.Count -eq 0) ($channel+' after cancel: a different consumer must stay blocked by the cancelled item reservation.')
            $script:writerMode[$ca.ItemId]='Succeed';$script:writerCalls=@()
            $rca=RestoreNow $c -Items @($ca);$own=@(OwnerOf $ca)
            Check ((ResultOf $rca $ca)[0].Status -ceq 'Succeeded' -and $own.Count -eq 1 -and [string]$own[0].Owner.DriftStatus -ceq 'Match' -and [string]$rca.Stage -ceq 'Succeeded') ($channel+' after cancel: a new restore of the cancelled item must reuse its reservation and complete it.')
            $log.Add('cancel-retry|'+(Shape $ca))

            $observed[$channel]=@($log.ToArray())
        }
        # ---------- the point of the test: C and NonC behave identically (only the label differs) ----------
        Check ($observed['C'].Count -eq $observed['NonC'].Count -and $observed['C'].Count -ge 8) 'twin run lengths differ.'
        for($i=0;$i -lt $observed['C'].Count;$i++){Check ($observed['C'][$i] -ceq $observed['NonC'][$i]) ('C and NonC diverge at step '+$i+': C=['+$observed['C'][$i]+'] NonC=['+$observed['NonC'][$i]+']')}
        $script:checks
    } $root
    Write-Host ('PASS: CV2 NonC reservation lifecycle ('+$checks+' checks).')
}
finally {
    if([IO.Directory]::Exists($root)){try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Host ('Cleanup left '+$root+': '+$_.Exception.Message)}}
}
