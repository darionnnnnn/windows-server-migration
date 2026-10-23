#requires -Version 5.1
# P5-a: can a pending Assistive adapter intent that a FAILED item leaves behind (the G4 IISSite case) be cleared, and what happens afterwards?
# Real code: Invoke-WsmAssistiveRestore (the item loop, the intent write, the catch that keeps the intent), Repair-WsmOperation,
# Complete-WsmAssistiveOperationRepair, Resume-WsmWizardTargetRestore guards, journal and state files. Doubles: only the native adapter boundary
# (Get-WsmAdapterState / Invoke-WsmAdapterRestore / Test-WsmAdapterConfiguration) and package / receipt / reservation edges, the same set that
# Test-TargetRestoreContinuation.ps1 uses. The failure is injected: the adapter double throws on its first call for one item.
# The end-to-end version through the real wizard (backup, import, preview, restore, repair, second restore) is Test-G4MixedScope.ps1 -Mutation RepairAndRetry.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-pending-intent-'+[Guid]::NewGuid().ToString('N'))
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Generated test root unexpectedly already exists.'}
[void][IO.Directory]::CreateDirectory($root)
$checks=0
try {
    $checks=& $module {
        param($root)
        $script:checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw ('FAIL: '+$message)};$script:checks++}
        function Reject([scriptblock]$action,[string]$pattern,[string]$message){$text='';try{& $action|Out-Null}catch{$text=[string]$_.Exception.Message};Check ($text -and $text -match $pattern) ($message+' (got: '+$text+')')}
        $pairsDirectory=Join-Path $root 'pairs';[void][IO.Directory]::CreateDirectory($pairsDirectory)
        $manifestHash='a'*64;$planHash='b'*64;$fingerprint='c'*64;$previewHash='d'*64;$receiptHash='e'*64;$snapshotHash='f'*64

        # ---- doubles: native boundary and package edges only ----
        $script:native=@{};$script:writes=0;$script:writeLog=@();$script:inject=@{};$script:fixture=$null
        Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value {param($Package,[string]$ManifestHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$SnapshotPath)$script:fixture.Decision}
        Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value {param($Package,$Decision)$true}
        Set-Item Function:\Get-WsmAssistiveReservations -Value {param($Item,$Package,[string]$Workspace,[switch]$PreviewOnly,[string]$OperationId,[string]$OperationState)@()}
        Set-Item Function:\Register-WsmAssistivePackageMaterials -Value {param($Package,$Decision,[string]$Workspace,$Preview)[pscustomobject]@{OperationId='fixture-material-job';MaterialIds=@()}}
        Set-Item Function:\Complete-WsmAssistivePackageJob -Value {param($Package,$Job,[string]$Workspace)}
        Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value {param([string]$StateDirectory,[string]$PairId,[string]$PlanHash)}
        Set-Item Function:\Set-WsmAssistiveReservationEvidence -Value {param($Reservations,$Item,$Package,$Prior,$Desired,$Readback,$Undo,[string]$Workspace)}
        Set-Item Function:\Assert-WsmCancellationBoundary -Value {param($Token,[string]$Name)}
        Set-Item Function:\Get-WsmAdapterState -Value {param($Spec)$key=([string]$Spec.Desired.Name).ToLowerInvariant();[pscustomobject]@{Exists=[bool]($script:native.ContainsKey($key));Name=[string]$Spec.Desired.Name;Actual=$null}}
        Set-Item Function:\Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,$SecurityReceipts)$key=([string]$Spec.Desired.Name).ToLowerInvariant();$ok=($script:native.ContainsKey($key) -and $script:native[$key].Passes);[pscustomobject]@{Passed=$ok;Problems=$(if($ok){@()}else{@('Fixture readback differs.')});Actual=[pscustomobject]@{Name=[string]$Spec.Desired.Name}}}
        Set-Item Function:\Get-WsmAdapterObjectIdentity -Value {param($Spec)[string]$Spec.Desired.Name}
        # Fault injection: the first call for a keyed item throws. Mode picks what the native side looks like at that moment.
        #   BeforeApply = nothing was created (the G4 case); AfterApplyOk = created and readback passes; AfterApplyDiffers = created but readback differs.
        Set-Item Function:\Invoke-WsmAdapterRestore -Value {param($Spec,$Secrets,$Package,$InstallerBaseline,$BeforeFolderCreate,$AfterFolderCreate,$OwnedReceipts,$SharedReceipts,$Workspace,$OperationId)
            $key=([string]$Spec.Desired.Name).ToLowerInvariant();$script:writes++;$script:writeLog+=@($key)
            if($script:inject.ContainsKey($key)){
                $mode=[string]$script:inject[$key];$script:inject.Remove($key)
                if($mode -ceq 'AfterApplyOk'){$script:native[$key]=@{Passes=$true}}
                elseif($mode -ceq 'AfterApplyDiffers'){$script:native[$key]=@{Passes=$false}}
                throw ('P5 injected adapter failure ('+$mode+') for '+$key)
            }
            $script:native[$key]=@{Passes=$true}
            [pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}}
        # Repair-WsmOperation / Resume edges
        Set-Item Function:\Test-WsmMigrationPackage -Value {param($ManifestPath,$ExpectedHash,$CancellationToken)$script:fixture.Package}
        Set-Item Function:\Assert-WsmMigrationHost -Value {param($Identity,[string]$ExpectedFingerprint)}
        Set-Item Function:\Get-WsmMachineIdentity -Value {[pscustomobject]@{Fingerprint=('c'*64)}}
        Set-Item Function:\Assert-WsmWizardTargetRole -Value {param([string]$Workspace,[string]$PairId)$script:fixture.Context}
        Set-Item Function:\Get-WsmWizardTargetPackage -Value {param([string]$Workspace,[string]$PairId,$Context,[object[]]$Jobs)[pscustomobject]@{Package=$script:fixture.Package;ManifestPath=(Join-Path $root 'manifest.json');ManifestHash=$script:fixture.Package.SHA256}}

        function PoolSpec([string]$name){[pscustomobject]@{Adapter='IISPool';Desired=[pscustomobject]@{Name=$name;Xml=('<add name="'+$name+'" />')}}}
        function SiteSpec([string]$name,[string]$pool){[pscustomobject]@{Adapter='IISSite';Desired=[pscustomobject]@{Name=$name;Xml=('<site name="'+$name+'"><application path="/" applicationPool="'+$pool+'" /></site>')}}}
        function NewFixture {
            $pair=[Guid]::NewGuid().ToString('D');$items=@();$ids=@{}
            $defs=[ordered]@{PoolA=(PoolSpec 'PoolA');PoolB=(PoolSpec 'PoolB');SiteA=(SiteSpec 'SiteA' 'PoolA')}
            foreach($name in $defs.Keys){$id=Get-WsmHashText ('p5-pending-'+$pair+'-'+$name);$ids[$name]=$id;$items+=@([pscustomobject]@{ItemId=$id;Name=$name;Kind=$defs[$name].Adapter;Decision='Include';MigrationSpec=$defs[$name]})}
            $package=[pscustomobject]@{Root=(Join-Path $root 'backup-media-fixture');PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($items)};Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
            $selected=@($items|ForEach-Object {$_.ItemId})
            $decision=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $root 'decision.json');ReceiptHash=$receiptHash;SnapshotPath=(Join-Path $root 'snapshot.json');SelectedItemIds=$selected;Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=$snapshotHash}}
            $rows=@($items|ForEach-Object {[pscustomobject]@{ItemId=$_.ItemId;Adapter=$_.MigrationSpec.Adapter;Action='RestoreNow';Status='Ready';Reason=''}})
            $preview=[pscustomobject]@{Rows=$rows;SelectedItemIds=$selected;Problems=@();GeneralHostIssues=@();Blocked=$false;CanRestoreIndependentItems=$true;WizardPreviewHash=$previewHash}
            $context=[pscustomobject]@{Plan=[pscustomobject]@{Items=@($items)};Received=[pscustomobject]@{SHA256=$planHash}}
            [pscustomobject]@{Pair=$pair;Package=$package;Decision=$decision;Items=$items;Ids=$ids;Preview=$preview;Context=$context}
        }
        function RestoreNow($Fixture,[string]$Parent=([Guid]::NewGuid().ToString('D'))){
            $script:fixture=$Fixture
            Invoke-WsmAssistiveRestore -Package $Fixture.Package -ManifestHash $manifestHash -StateDirectory $pairsDirectory -Secrets @{} -SidMap @{} -CancellationToken ([pscustomobject]@{OperationId=$Parent}) -GeneralHostEvidence @() -ReceiptPath $Fixture.Decision.ReceiptPath -ReceiptHash $receiptHash -TargetSnapshotPath $Fixture.Decision.SnapshotPath -Preview $Fixture.Preview -ParentOperationId $Parent
        }
        function StateOf($Fixture){Read-WsmJson (Get-WsmOperationPaths $pairsDirectory $Fixture.Pair).State}
        function JournalActions($Fixture){@(Get-Content -LiteralPath (Get-WsmOperationPaths $pairsDirectory $Fixture.Pair).Journal -Encoding UTF8|ForEach-Object {($_|ConvertFrom-Json).Action})}
        function ResultOf($Result,$Fixture,[string]$Name){@($Result.Results|Where-Object ItemId -CEQ $Fixture.Ids[$Name])}
        function Reset(){$script:native=@{};$script:writes=0;$script:writeLog=@();$script:inject=@{}}
        function RepairNow($Fixture){$script:fixture=$Fixture;Repair-WsmOperation -ManifestPath (Join-Path $root 'manifest.json') -ExpectedHash $manifestHash -StateDirectory $pairsDirectory -Confirm:$false}

        # ================= 1. the G4 shape: one item fails (adapter throws before any native effect), the others succeed =================
        Reset;$f1=NewFixture;$script:inject['sitea']='BeforeApply'
        $r1=RestoreNow $f1;$s1=StateOf $f1
        Check ($script:inject.Count -eq 0 -and $script:writes -eq 3) '1: the injected failure was not actually triggered (the adapter double was not reached for the failing item).'
        Check ((ResultOf $r1 $f1 'SiteA')[0].Status -ceq 'Failed' -and (ResultOf $r1 $f1 'PoolA')[0].Status -ceq 'Succeeded' -and (ResultOf $r1 $f1 'PoolB')[0].Status -ceq 'Succeeded') '1: expected exactly the injected item to fail and the independent items to succeed.'
        Check ([string]$r1.Stage -ceq 'Partial' -and [string]$s1.Stage -ceq 'Partial') '1: a failed item must leave the parent Partial, never Succeeded.'
        Check (@($s1.PendingOperations).Count -eq 1 -and [string]$s1.PendingOperations[0].ItemId -ceq $f1.Ids['SiteA'] -and [string]$s1.PendingOperations[0].Phase -ceq 'AssistiveAdapterCreating' -and $s1.PendingOperations[0].AbsentBefore -eq $true) '1: the failed item must keep its pending AssistiveAdapterCreating intent (design: never erase an ambiguous intent).'
        Check ((JournalActions $f1) -contains 'AssistiveAdapterIntent' -and (JournalActions $f1) -contains 'AssistiveItemNeedsRepair') '1: journal lacks the intent and needs-repair rows.'
        Check (-not $script:native.ContainsKey('sitea') -and $script:native.ContainsKey('poola') -and $script:native.ContainsKey('poolb')) '1: native state is not what the scenario assumes (site absent, pools created).'

        # ================= 2. the entrances that must NOT clear it =================
        $writes2=$script:writes
        Reject {RestoreNow $f1} 'Interrupted Assistive item operation blocks a new parent operation' '2: a new parent over a pending intent must be blocked'
        Check ($script:writes -eq $writes2) '2: the blocked new parent wrote natively.'
        Reject {$script:fixture=$f1;Resume-WsmWizardTargetRestore -Workspace $root -PairId $f1.Pair -ParentOperationId ([Guid]::NewGuid().ToString('D')) -ContinuationId ([Guid]::NewGuid().ToString('D'))} 'No durable TargetRestore parent matches' '2: Resume with an unrelated parent id must be refused'
        $parentId=[string]$s1.RestoreAttempt.OperationId
        Reject {$script:fixture=$f1;Resume-WsmWizardTargetRestore -Workspace $root -PairId $f1.Pair -ParentOperationId $parentId -ContinuationId ([Guid]::NewGuid().ToString('D'))} 'already reached a terminal result \(Partial\)' '2: Resume of a Partial (completed-with-failure) parent is, by current design, refused'
        $s2=StateOf $f1
        Check (@($s2.PendingOperations).Count -eq 1 -and $script:writes -eq $writes2) '2: refused entrances must leave the intent and the native state untouched.'

        # ================= 3. Repair-WsmOperation clears it (adapter absent => abandoned, proven by readback) =================
        $repair=RepairNow $f1;$s3=StateOf $f1
        Check (@($repair.Repaired) -contains $f1.Ids['SiteA'] -and [int]$repair.Remaining -eq 0) '3: Repair-WsmOperation did not report the failed item repaired with nothing remaining.'
        Check (@($s3.PendingOperations).Count -eq 0) '3: the pending intent is still in the durable state after Repair-WsmOperation (user permanently blocked).'
        Check ((JournalActions $f1) -contains 'AssistiveAdapterAbandoned') '3: journal lacks AssistiveAdapterAbandoned.'
        Check ($script:writes -eq $writes2 -and $script:native.ContainsKey('poola') -and $script:native.ContainsKey('poolb') -and -not $script:native.ContainsKey('sitea')) '3: Repair wrote or deleted native state; it must only reconcile.'
        Check (@($s3.Items|Where-Object {$_.ItemId -ceq $f1.Ids['SiteA']}).Count -eq 1 -and [string]@($s3.Items|Where-Object {$_.ItemId -ceq $f1.Ids['SiteA']})[0].Status -ceq 'Failed') '3: the Failed record must remain as history until a real retry replaces it.'
        $journalCheck=Test-WsmJournal $pairsDirectory $f1.Pair
        Check ($journalCheck.Consistent) '3: the journal is inconsistent after Repair.'

        # ================= 4. a new restore after the repair retries only the failed item; owned items are read back, not rewritten =================
        $writesBefore=$script:writes;$script:writeLog=@()
        $r4=RestoreNow $f1;$s4=StateOf $f1
        Check ($script:writeLog.Count -eq 1 -and $script:writeLog[0] -ceq 'sitea' -and $script:writes -eq $writesBefore+1) ('4: only the failed item may be written again (write log: '+($script:writeLog -join ',')+').')
        Check ((ResultOf $r4 $f1 'SiteA')[0].Status -ceq 'Succeeded' -and (ResultOf $r4 $f1 'PoolA')[0].Status -ceq 'Succeeded' -and (ResultOf $r4 $f1 'PoolB')[0].Status -ceq 'Succeeded') '4: after the retry every item must be Succeeded.'
        Check ([string]$r4.Stage -ceq 'Succeeded' -and @($s4.PendingOperations).Count -eq 0) '4: the retry parent must end Succeeded with nothing pending.'
        Check ([string](ResultOf $r4 $f1 'PoolA')[0].PriorManifestHash -ceq $manifestHash -and [string](ResultOf $r4 $f1 'PoolB')[0].PriorManifestHash -ceq $manifestHash) '4: owned items must be adopted through the prior ownership record (PriorManifestHash), not recreated.'
        Check (@($s4.Items|Where-Object {$_.ItemId -ceq $f1.Ids['SiteA']}).Count -eq 1 -and [string]@($s4.Items|Where-Object {$_.ItemId -ceq $f1.Ids['SiteA']})[0].Status -ceq 'Succeeded' -and [bool]@($s4.Items|Where-Object {$_.ItemId -ceq $f1.Ids['SiteA']})[0].CreatedByTool) '4: the retried item must now be owned (CreatedByTool, Succeeded).'

        # ================= 5. the intent was written but the native result is ambiguous =================
        # 5a: the adapter threw AFTER creating the object and the exact readback passes -> Repair adopts it; a later restore does not rewrite it
        Reset;$f5=NewFixture;$script:inject['sitea']='AfterApplyOk'
        [void](RestoreNow $f5);$s5=StateOf $f5
        Check (@($s5.PendingOperations).Count -eq 1 -and $script:native.ContainsKey('sitea')) '5a: scenario precondition (intent kept, object exists).'
        $repair5=RepairNow $f5;$s5b=StateOf $f5;$siteRecord=@($s5b.Items|Where-Object {$_.ItemId -ceq $f5.Ids['SiteA']})
        Check (@($repair5.Repaired) -contains $f5.Ids['SiteA'] -and @($s5b.PendingOperations).Count -eq 0 -and $siteRecord.Count -eq 1 -and [string]$siteRecord[0].Status -ceq 'Succeeded' -and [bool]$siteRecord[0].CreatedByTool) '5a: Repair must adopt the proven object as owned and clear the intent.'
        Check ((JournalActions $f5) -contains 'AssistiveAdapterRecovered') '5a: journal lacks AssistiveAdapterRecovered.'
        $script:writeLog=@();$r5=RestoreNow $f5
        Check ($script:writeLog.Count -eq 0 -and [string]$r5.Stage -ceq 'Succeeded') '5a: a restore after adoption must write nothing (everything is owned).'
        # 5b: created but the readback differs -> the intent is preserved for manual reconciliation, nothing is guessed; once the object is gone Repair abandons it
        Reset;$f6=NewFixture;$script:inject['sitea']='AfterApplyDiffers'
        [void](RestoreNow $f6)
        Reject {RepairNow $f6} 'differs from exact staged' '5b: an object that does not match the staged spec must not be adopted'
        Check (@((StateOf $f6).PendingOperations).Count -eq 1) '5b: an unprovable intent must stay pending.'
        Reject {RestoreNow $f6} 'Interrupted Assistive item operation blocks a new parent operation' '5b: the unprovable intent must keep blocking a new parent'
        [void]$script:native.Remove('sitea')
        $repair6=RepairNow $f6
        Check (@($repair6.Repaired) -contains $f6.Ids['SiteA'] -and @((StateOf $f6).PendingOperations).Count -eq 0) '5b: after the operator removes the unproven object, Repair must abandon the intent.'

        # ================= 6. Complete-WsmAssistiveOperationRepair (the per-item reconcile that Repair and Resume share) called directly =================
        Reset;$f7=NewFixture;$script:inject['sitea']='BeforeApply'
        [void](RestoreNow $f7)
        $paths7=Get-WsmOperationPaths $pairsDirectory $f7.Pair;$state7=Get-WsmOperationState $paths7 $f7.Package;$op7=@($state7.PendingOperations)[0];$item7=@($f7.Items|Where-Object Name -CEQ 'SiteA')[0]
        Invoke-WsmLocked $paths7.Root {Complete-WsmAssistiveOperationRepair $item7 $op7 $f7.Package $paths7 $state7 @{}}|Out-Null
        Check (@((StateOf $f7).PendingOperations).Count -eq 0 -and (JournalActions $f7) -contains 'AssistiveAdapterAbandoned') '6: Complete-WsmAssistiveOperationRepair did not clear a proven-absent intent.'
        $script:checks
    } $root
    Write-Host ('PASS: pending intent recovery ('+$checks+' checks).')
}
finally {
    if([IO.Directory]::Exists($root)){try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Host ('Cleanup left '+$root+': '+$_.Exception.Message)}}
}
