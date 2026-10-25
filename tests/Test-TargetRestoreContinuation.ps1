#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-restore-continuation-'+[Guid]::NewGuid().ToString('N'))
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Generated continuation test root unexpectedly already exists.'}
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($root)
        $script:checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Reject([scriptblock]$action,[string]$message){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $message}
        $pairsDirectory=Join-Path $root 'pairs';[void][IO.Directory]::CreateDirectory($pairsDirectory)
        $manifestHash='a'*64;$planHash='b'*64;$fingerprint='c'*64;$previewHash='d'*64;$receiptHash='e'*64;$snapshotHash='f'*64

        # ---- replacement of every native / external edge; the continuation logic itself is real ----
        $script:native=@{};$script:writes=0;$script:writeLog=@()
        $script:fixture=$null
        Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value {param($Package,[string]$ManifestHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$SnapshotPath)$script:fixture.Decision}
        Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value {param($Package,$Decision)$true}
        Set-Item Function:\Get-WsmAssistiveReservations -Value {param($Item,$Package,[string]$Workspace,[switch]$PreviewOnly,[string]$OperationId,[string]$OperationState)if([string]$Item.MigrationSpec.Adapter -ceq 'Service'){[pscustomobject]@{Preview=[pscustomobject]@{ResourceKey=('1'*64)};Reservation=[pscustomobject]@{Reserved=$true};Existing=$false}}}
        Set-Item Function:\Set-WsmAssistiveServiceReservationOperation -Value {param([string]$Workspace,[string]$ResourceKey,[string]$PairId,[string]$ItemId,[string]$OperationId,[string]$State)$script:reservationState=$State}
        Set-Item Function:\Register-WsmAssistivePackageMaterials -Value {param($Package,$Decision,[string]$Workspace,$Preview)[pscustomobject]@{OperationId='fixture-material-job';MaterialIds=@()}}
        Set-Item Function:\Complete-WsmAssistivePackageJob -Value {param($Package,$Job,[string]$Workspace)}
        Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value {param([string]$StateDirectory,[string]$PairId,[string]$PlanHash)}
        Set-Item Function:\Set-WsmAssistiveReservationEvidence -Value {param($Reservations,$Item,$Package,$Prior,$Desired,$Readback,$Undo,[string]$Workspace)}
        Set-Item Function:\Assert-WsmCancellationBoundary -Value {param($Token,[string]$Name)}
        Set-Item Function:\Get-WsmAdapterState -Value {param($Spec)$key=([string]$Spec.Desired.Name).ToLowerInvariant();[pscustomobject]@{Exists=[bool]($script:native.ContainsKey($key));Name=[string]$Spec.Desired.Name;Actual=$null}}
        Set-Item Function:\Invoke-WsmAdapterRestore -Value {param($Spec,$Secrets,$Package,$InstallerBaseline,$BeforeFolderCreate,$AfterFolderCreate,$OwnedReceipts,$SharedReceipts,$Workspace,$OperationId)$key=([string]$Spec.Desired.Name).ToLowerInvariant();$script:writes++;$script:writeLog+=@($key);if($Secrets -and $Secrets.Count){$script:sawSecretCount=$Secrets.Count};$script:native[$key]=@{Passes=$true};[pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}}
        Set-Item Function:\Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,$SecurityReceipts)$key=([string]$Spec.Desired.Name).ToLowerInvariant();$ok=($script:native.ContainsKey($key) -and $script:native[$key].Passes);[pscustomobject]@{Passed=$ok;Problems=$(if($ok){@()}else{@('Fixture readback differs.')});Actual=[pscustomobject]@{Name=[string]$Spec.Desired.Name}}}
        Set-Item Function:\Get-WsmAdapterObjectIdentity -Value {param($Spec)[string]$Spec.Desired.Name}
        # Resume-WsmWizardTargetRestore edges
        Set-Item Function:\Assert-WsmWizardTargetRole -Value {param([string]$Workspace,[string]$PairId)$script:fixture.Context}
        Set-Item Function:\Get-WsmWizardTargetPackage -Value {param([string]$Workspace,[string]$PairId,$Context,[object[]]$Jobs)[pscustomobject]@{Package=$script:fixture.Package;ManifestPath=(Join-Path $root 'manifest.json');ManifestHash=$script:fixture.Package.SHA256}}
        Set-Item Function:\Test-WsmMigrationPackage -Value {param($ManifestPath,$ExpectedHash,$CancellationToken)$script:fixture.Package}
        Set-Item Function:\Get-WsmWizardTargetRestoreProjection -Value {param([string]$Workspace,[string]$PairId,[object[]]$Jobs,[object[]]$GeneralHostEvidence)$script:fixture.Projection}
        Set-Item Function:\Get-WsmWizardTargetDecisionRecord -Value {param([string]$Workspace,[string]$PairId,[string]$PlanHash)[pscustomobject]@{Receipt=$script:fixture.Decision.Receipt}}
        Set-Item Function:\Get-WsmWizardSelectedNonCPreviewInputs -Value {param([string]$Workspace,[string]$PairId,$Plan,$Decision,[object[]]$Jobs)[pscustomobject]@{Arguments=@{};Issue=''}}
        Set-Item Function:\Get-WsmAssistiveRestorePreview -Value {param([string]$ManifestPath,[string]$ExpectedHash,[string]$StateDirectory,[string]$AssistiveDecisionReceiptPath,[string]$AssistiveDecisionReceiptHash,[string]$AssistiveTargetSnapshotPath,[object[]]$GeneralHostEvidence)$script:fixture.Preview.PSObject.Copy()}

        function PoolSpec([string]$name){[pscustomobject]@{Adapter='IISPool';Desired=[pscustomobject]@{Name=$name;Xml=('<add name="'+$name+'" />')}}}
        function SiteSpec([string]$name,[string]$pool){[pscustomobject]@{Adapter='IISSite';Desired=[pscustomobject]@{Name=$name;Xml=('<site name="'+$name+'"><application path="/" applicationPool="'+$pool+'" /></site>')}}}
        # Builds one isolated pair: package, decision, preview rows and projection. Rows are Ready unless overridden.
        function NewFixture([string[]]$ItemNames,[hashtable]$RowStatus=@{},[string]$Hash=$previewHash){
            $pair=[Guid]::NewGuid().ToString('D');$parent=[Guid]::NewGuid().ToString('D')
            $items=@();$ids=@{}
            $defs=[ordered]@{PoolA=(PoolSpec 'PoolA');PoolB=(PoolSpec 'PoolB');SiteA=(SiteSpec 'SiteA' 'PoolA');SiteB=(SiteSpec 'SiteB' 'PoolB')}
            foreach($name in $ItemNames){$id=Get-WsmHashText ('continuation-item-'+$name);$ids[$name]=$id;$items+=@([pscustomobject]@{ItemId=$id;Name=$name;Kind=$defs[$name].Adapter;Decision='Include';MigrationSpec=$defs[$name]})}
            $package=[pscustomobject]@{Root=(Join-Path $root 'backup-media-fixture');PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($items)};Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
            $selected=@($items|ForEach-Object {$_.ItemId})
            $decision=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $root 'decision.json');ReceiptHash=$receiptHash;SnapshotPath=(Join-Path $root 'snapshot.json');SelectedItemIds=$selected;Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=$snapshotHash}}
            $originalRows=@($items|ForEach-Object {[pscustomobject]@{ItemId=$_.ItemId;Adapter=$_.MigrationSpec.Adapter;Action='RestoreNow';Status='Ready';Reason=''}})
            $liveRows=@($items|ForEach-Object {$status='Ready';if($RowStatus.ContainsKey($_.Name)){$status=[string]$RowStatus[$_.Name]};[pscustomobject]@{ItemId=$_.ItemId;Adapter=$_.MigrationSpec.Adapter;Action=$(if($status -eq 'Ready'){'RestoreNow'}else{'BlockedConflict'});Status=$status;Reason=$(if($status -eq 'Ready'){''}else{'Existing target object is not owned by an exact prior Assistive generation.'})}})
            $preview=[pscustomobject]@{Rows=$liveRows;SelectedItemIds=$selected;Problems=@();GeneralHostIssues=@();Blocked=$false;CanRestoreIndependentItems=$true;WizardPreviewHash=$Hash}
            $projection=[pscustomobject]@{Status='Previewed';PairId=$pair;PlanHash=$planHash;ManifestPath=(Join-Path $root 'manifest.json');ManifestHash=$manifestHash;Generation=7;ReceiptPath=$decision.ReceiptPath;ReceiptHash=$receiptHash;TargetSnapshotPath=$decision.SnapshotPath;TargetSnapshotHash=$snapshotHash;ComparisonHash=('9'*64);ComparisonRevision=1;SelectionRevision=1;Decision='RestoreNow';SelectedItemIds=$selected;Rows=$liveRows;Problems=@();GeneralHostIssues=@();Blocked=$false;CanRestoreIndependentItems=$true;PreviewHash=$Hash}
            $context=[pscustomobject]@{Plan=[pscustomobject]@{Items=@($items)};Received=[pscustomobject]@{SHA256=$planHash}}
            [pscustomobject]@{Pair=$pair;Parent=$parent;Package=$package;Decision=$decision;Items=$items;Ids=$ids;OriginalRows=$originalRows;Preview=$preview;Projection=$projection;Context=$context;Workspace=$root}
        }
        # Durable state exactly as an interrupted run leaves it: attempt Running, intent journalled.
        function NewInterruptedState($Fixture,[hashtable]$Pending=@{},[hashtable]$Owned=@{},[object[]]$PriorResults=@(),[string]$Stage='Running',[string]$AttemptStatus='Running'){
            $paths=Get-WsmOperationPaths $pairsDirectory $Fixture.Pair;$state=Get-WsmOperationState $paths $Fixture.Package
            $attempt=[pscustomobject]@{ManifestHash=$manifestHash;Generation=7;PreviousManifest='';OperationId=$Fixture.Parent;DecisionReceiptPath=[string]$Fixture.Decision.ReceiptPath;DecisionReceiptHash=$receiptHash;TargetSnapshotPath=[string]$Fixture.Decision.SnapshotPath;TargetSnapshotHash=$snapshotHash;SelectedItemIds=@($Fixture.Decision.SelectedItemIds);WizardPreviewHash=$previewHash;ItemResults=@($PriorResults);PreviewRowHashes=@(Get-WsmAssistivePreviewRowHashes $Fixture.OriginalRows);MaterialJobOperationId='';MaterialIds=@();Status=$AttemptStatus;StartedUtc=(Get-WsmUtc)}
            $state.ManifestHash=$manifestHash;$state.Generation=7;$state.Stage=$Stage;$state|Add-Member NoteProperty RestoreAttempt $attempt -Force
            foreach($name in @($Owned.Keys)){$state.Items=@($state.Items)+@([pscustomobject]@{ItemId=$Fixture.Ids[$name];Status='Succeeded';CreatedByTool=$true;AppliedManifestHash=$manifestHash;AppliedGeneration=7;ActualHash=('7'*64);Target=$name;Error='';NativeCode=0});$script:native[$name.ToLowerInvariant()]=@{Passes=$true}}
            Add-WsmJournal $paths $state 'AssistiveRestoreStarted' '' $attempt
            foreach($name in @($Pending.Keys)){
                $item=@($Fixture.Items|Where-Object Name -CEQ $name)[0];$spec=$item.MigrationSpec
                $intent=[pscustomobject]@{ItemId=$item.ItemId;Phase='AssistiveAdapterCreating';Adapter=$spec.Adapter;ManifestHash=$manifestHash;Generation=7;Before=[pscustomobject]@{Exists=$false};BeforeHash=(Get-WsmHashText ([pscustomobject]@{Exists=$false}|ConvertTo-Json -Depth 30 -Compress));DesiredHash=(Get-WsmHashText ($spec.Desired|ConvertTo-Json -Depth 40 -Compress));AbsentBefore=$true;BootBefore='';InstallerBaselinePath='';InstallerBaselineHash='';FolderCreateIntents=@();AuxiliaryOwnership=@()}
                $state.PendingOperations=@($state.PendingOperations)+@($intent);Add-WsmJournal $paths $state 'AssistiveAdapterIntent' $item.ItemId $intent
                if($Pending[$name] -ceq 'NativeAppliedReadbackOk'){$script:native[$name.ToLowerInvariant()]=@{Passes=$true}}
                elseif($Pending[$name] -ceq 'NativeAppliedUnprovable'){$script:native[$name.ToLowerInvariant()]=@{Passes=$false}}
            }
            $paths
        }
        function StateOf($Fixture){$paths=Get-WsmOperationPaths $pairsDirectory $Fixture.Pair;Read-WsmJson $paths.State}
        function ResultOf($Result,$Fixture,[string]$Name){@($Result.ItemResults|Where-Object ItemId -CEQ $Fixture.Ids[$Name])}
        function ResumeNow($Fixture,[string]$ContinuationId=([Guid]::NewGuid().ToString('D')),[hashtable]$Secrets=@{},$Context=$null){
            $script:fixture=$Fixture
            Resume-WsmWizardTargetRestore -Workspace $root -PairId $Fixture.Pair -ParentOperationId $Fixture.Parent -ContinuationId $ContinuationId -Secrets $Secrets -ChallengeContext $Context -CancellationToken ([pscustomobject]@{OperationId=$Fixture.Parent})
        }
        function ResetNative(){$script:native=@{};$script:writes=0;$script:writeLog=@()}

        # ---- breakpoint 1: interrupted before the intent was journalled ----
        ResetNative;$f1=NewFixture @('PoolA','PoolB','SiteA','SiteB');[void](NewInterruptedState $f1)
        $r1=ResumeNow $f1
        Check ($r1.Status -ceq 'Succeeded' -and $script:writes -eq 4) 'Breakpoint before the intent: every item must be written exactly once on continuation.'
        Check (@($r1.ItemResults|Where-Object Status -CEQ 'Succeeded').Count -eq 4 -and @($r1.PendingOperations).Count -eq 0) 'Breakpoint before the intent: items did not all succeed with nothing pending.'

        # ---- breakpoint 2: intent journalled, native never touched ----
        ResetNative;$f2=NewFixture @('PoolA','PoolB','SiteA','SiteB');[void](NewInterruptedState $f2 -Pending @{PoolA='NativeAbsent'})
        $r2=ResumeNow $f2
        Check ($r2.Status -ceq 'Succeeded' -and $script:writes -eq 4 -and (ResultOf $r2 $f2 'PoolA')[0].Status -ceq 'Succeeded') 'Breakpoint after intent but before native: abandoned intent must be re-applied exactly once.'
        Check (@((StateOf $f2).PendingOperations).Count -eq 0) 'Breakpoint after intent but before native: pending intent was not cleared.'

        # ---- breakpoint 3: native applied, journal incomplete, readback proves it ----
        ResetNative;$f3=NewFixture @('PoolA','PoolB','SiteA','SiteB') @{PoolA='BlockedConflict'};[void](NewInterruptedState $f3 -Pending @{PoolA='NativeAppliedReadbackOk'})
        $r3=ResumeNow $f3
        Check ($r3.Status -ceq 'Succeeded' -and $script:writes -eq 3 -and ($script:writeLog -notcontains 'poola')) 'Breakpoint after native with provable readback: the applied item must not be written again (stale conflict row included).'
        Check ((ResultOf $r3 $f3 'PoolA')[0].Status -ceq 'Succeeded' -and @((StateOf $f3).PendingOperations).Count -eq 0) 'Breakpoint after native with provable readback: item was not adopted as succeeded.'

        # ---- breakpoint 4 + dependency: native applied, readback cannot prove it ----
        ResetNative;$f4=NewFixture @('PoolA','PoolB','SiteA','SiteB') @{PoolA='BlockedConflict'};[void](NewInterruptedState $f4 -Pending @{PoolA='NativeAppliedUnprovable'})
        $r4=ResumeNow $f4
        Check ($r4.Status -ceq 'Partial' -and $r4.Stage -ceq 'Partial') 'Unprovable native result must make the parent Partial, never Succeeded.'
        Check ((ResultOf $r4 $f4 'PoolA')[0].Status -ceq 'NeedsReconciliation') 'Unprovable item was not marked NeedsReconciliation.'
        Check ((ResultOf $r4 $f4 'SiteA')[0].Status -ceq 'BlockedByUnknownDependency' -and (ResultOf $r4 $f4 'SiteA')[0].Error -match 'PoolA') 'IISSite pointing at the unknown IISPool was not blocked with the unknown item named.'
        Check ((ResultOf $r4 $f4 'PoolB')[0].Status -ceq 'Succeeded' -and (ResultOf $r4 $f4 'SiteB')[0].Status -ceq 'Succeeded') 'Independent items (and the site using another pool) must still complete.'
        Check ($script:writes -eq 2 -and ($script:writeLog -notcontains 'poola') -and ($script:writeLog -notcontains 'sitea')) 'Unknown item and its dependent must not be written or re-applied.'
        $s4=StateOf $f4
        Check (@($s4.PendingOperations).Count -eq 1 -and [string]$s4.PendingOperations[0].ItemId -ceq $f4.Ids['PoolA'] -and $script:native.ContainsKey('poola')) 'Unknown item must keep its pending intent and its native object (no delete).'
        Check (@($s4.Items|Where-Object ItemId -CEQ $f4.Ids['PoolA']).Count -eq 0) 'Unknown item gained an ownership record without proof.'
        $options=Get-WsmWizardTargetItemOptions $f4.Context ([pscustomobject]@{ManifestHash=$manifestHash}) $s4
        Check (@($options|Where-Object {$_.value -ceq $f4.Ids['PoolA'] -or $_.value -ceq $f4.Ids['SiteA']}|Where-Object restored).Count -eq 0 -and @($options|Where-Object restored).Count -eq 2) 'restored counted a NeedsReconciliation or blocked item as restored.'
        # unprovable item is not the dependency of an unrelated site
        Check ((Get-WsmAssistiveUnknownDependencyBlocks @($f4.Package.Plan.Items) @{($f4.Ids['PoolB'])='x'}).Count -eq 1) 'Dependency helper should block exactly the one site that references the unknown pool.'
        Check ((Get-WsmAssistiveUnknownDependencyBlocks @($f4.Package.Plan.Items) @{($f4.Ids['SiteA'])='x'}).Count -eq 0) 'A site is not a dependency of anything; nothing may be blocked.'

        # ---- owned items only read back, never rewritten ----
        ResetNative;$f5=NewFixture @('PoolA','PoolB','SiteA','SiteB');[void](NewInterruptedState $f5 -Owned @{PoolA=1;PoolB=1;SiteA=1;SiteB=1})
        $r5=ResumeNow $f5
        Check ($r5.Status -ceq 'Succeeded' -and $script:writes -eq 0 -and @($r5.ItemResults|Where-Object Status -CEQ 'Succeeded').Count -eq 4) 'Already-owned items were written again instead of only read back.'

        # ---- same ContinuationId replays, terminal parents are refused ----
        $writesBefore=$script:writes;$cid=[Guid]::NewGuid().ToString('D')
        ResetNative;$f6=NewFixture @('PoolA','PoolB');[void](NewInterruptedState $f6)
        $r6=ResumeNow $f6 $cid
        Check ($r6.Status -ceq 'Succeeded' -and $script:writes -eq 2) 'Baseline continuation for replay test failed.'
        $r6b=ResumeNow $f6 $cid
        Check ($r6b.Replay -and $r6b.Status -ceq 'Succeeded' -and $r6b.ContinuationId -ceq $cid -and $script:writes -eq 2) 'Resending the same ContinuationId must return the first result without redoing anything.'
        Check (@((StateOf $f6).RestoreAttempt.Continuations).Count -eq 1) 'Replay appended a second continuation record.'
        Reject {ResumeNow $f6} 'A terminal parent accepted a continuation with a new ContinuationId.'
        Check ($script:writes -eq 2) 'Rejected continuation of a terminal parent wrote natively.'

        # ---- preview drift ----
        ResetNative;$f7=NewFixture @('PoolA','PoolB');[void](NewInterruptedState $f7)
        $paths7=Get-WsmOperationPaths $pairsDirectory $f7.Pair;$state7=Get-WsmOperationState $paths7 $f7.Package
        $state7|Add-Member NoteProperty AssistiveServiceChallenge ([pscustomobject]@{State='WaitingForInput';ParentOperationId=$f7.Parent;PairId=$f7.Pair;Role='Target';Actor='A';SessionId='S';ContextId='C';Revision=1;ManifestHash=$manifestHash;Generation=7;PreviewHash=$previewHash;RequiredSecretRefs=@();Requirements=@();ServiceReservations=@();CreatedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc)}) -Force
        $state7.Stage='WaitingForInput';$state7.RestoreAttempt.Status='WaitingForInput';Add-WsmJournal $paths7 $state7 'AssistiveServiceCredentialChallengeWaiting' '' $state7.AssistiveServiceChallenge
        $f7.Projection.TargetSnapshotHash=('0'*64);$f7.Projection.PreviewHash=('1'*64)
        $r7=ResumeNow $f7
        $s7=StateOf $f7
        Check ($r7.Status -ceq 'NeedsNewPreview' -and $r7.NoTargetWrites -and $script:writes -eq 0) 'A changed snapshot must yield NeedsNewPreview with no native write.'
        Check ([string]$s7.AssistiveServiceChallenge.State -ceq 'Revoked' -and [string]$s7.AssistiveServiceChallenge.RevokeReason -ceq 'PreviewChanged' -and [string]$s7.RestoreAttempt.Status -ceq 'Superseded') 'Preview drift did not revoke the challenge and supersede the attempt.'
        Reject {ResumeNow $f7} 'A superseded parent accepted another continuation.'
        # a row that drifted for a reason unrelated to this parent's own work is also a changed review
        ResetNative;$f7b=NewFixture @('PoolA','PoolB') @{PoolB='BlockedConflict'};[void](NewInterruptedState $f7b);$f7b.Projection.PreviewHash=('2'*64)
        $r7b=ResumeNow $f7b
        Check ($r7b.Status -ceq 'NeedsNewPreview' -and $script:writes -eq 0) 'An unexplained row change must require a new preview.'

        # ---- cancellation is sticky ----
        ResetNative;$f8=NewFixture @('PoolA');[void](NewInterruptedState $f8 -Stage 'Cancelled' -AttemptStatus 'Cancelled')
        Reject {ResumeNow $f8} 'A cancelled attempt accepted a continuation.'
        ResetNative;$f8b=NewFixture @('PoolA');$paths8=NewInterruptedState $f8b;$state8=Get-WsmOperationState $paths8 $f8b.Package
        $state8|Add-Member NoteProperty AssistiveServiceChallenge ([pscustomobject]@{State='Cancelled';ParentOperationId=$f8b.Parent;PairId=$f8b.Pair;Role='Target';Actor='A';SessionId='S';ContextId='C';Revision=1;ManifestHash=$manifestHash;Generation=7;PreviewHash=$previewHash;RequiredSecretRefs=@();ServiceReservations=@()}) -Force
        Add-WsmJournal $paths8 $state8 'AssistiveServiceCredentialChallengeCancelled' '' $state8.AssistiveServiceChallenge
        Reject {ResumeNow $f8b} 'A cancelled challenge was revived by a continuation.'
        Check ($script:writes -eq 0) 'Cancelled parent wrote natively.'

        # ---- Running challenge with provable pre-write state: ask again under the new session ----
        ResetNative;$f9=NewFixture @('PoolA');$paths9=NewInterruptedState $f9 -Stage 'WaitingForInput' -AttemptStatus 'WaitingForInput';$state9=Get-WsmOperationState $paths9 $f9.Package
        $state9|Add-Member NoteProperty AssistiveServiceChallenge ([pscustomobject]@{State='Running';ParentOperationId=$f9.Parent;PairId=$f9.Pair;Role='Target';Actor='OLD-ACTOR';SessionId='OLD-SESSION';ContextId='OLD-CONTEXT';Revision=3;ManifestHash=$manifestHash;Generation=7;PreviewHash=$previewHash;RequiredSecretRefs=@('SecretOld');Requirements=@();ServiceReservations=@();CreatedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc)}) -Force
        Add-WsmJournal $paths9 $state9 'AssistiveServiceCredentialChallengeResuming' '' $state9.AssistiveServiceChallenge
        $newContext=[pscustomobject]@{Role='Target';Actor='NEW-ACTOR';SessionId='NEW-SESSION';ContextId='NEW-CONTEXT';Revision=3;OperationId=$f9.Parent}
        $r9=ResumeNow $f9 -Context $newContext
        $s9=StateOf $f9
        Check ($r9.Status -ceq 'WaitingForInput' -and $r9.NoTargetWrites -and $script:writes -eq 0 -and ($r9.RequiredSecretRefs -contains 'SecretOld')) 'Running challenge with a provable pre-write state must return WaitingForInput asking for fresh input.'
        Check ([string]$s9.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and [string]$s9.AssistiveServiceChallenge.SessionId -ceq 'NEW-SESSION' -and [string]$s9.AssistiveServiceChallenge.Actor -ceq 'NEW-ACTOR' -and [string]$s9.AssistiveServiceChallenge.ContextId -ceq 'NEW-CONTEXT') 'Challenge was not rebound to the current session.'
        $oldContext=[pscustomobject]@{Role='Target';Actor='OLD-ACTOR';SessionId='OLD-SESSION';ContextId='OLD-CONTEXT';Revision=3;OperationId=$f9.Parent}
        $script:fixture=$f9;$f9.Preview.WizardPreviewHash=$previewHash
        Reject {Invoke-WsmAssistiveRestore -Package $f9.Package -ManifestHash $manifestHash -StateDirectory $pairsDirectory -Secrets @{} -SidMap @{} -CancellationToken ([pscustomobject]@{OperationId=$f9.Parent}) -GeneralHostEvidence @() -ReceiptPath $f9.Decision.ReceiptPath -ReceiptHash $receiptHash -TargetSnapshotPath $f9.Decision.SnapshotPath -Preview $f9.Preview -ParentOperationId $f9.Parent -ChallengeContext $oldContext} 'A secret reply from the old session was accepted after the challenge was rebound.'
        Check ($script:writes -eq 0) 'Old-session reply wrote natively.'
        # same Running challenge but a pending intent exists: not provable, so no password prompt; per-item reconciliation instead
        ResetNative;$f9b=NewFixture @('PoolA','PoolB');$paths9b=NewInterruptedState $f9b -Pending @{PoolA='NativeAppliedReadbackOk'};$state9b=Get-WsmOperationState $paths9b $f9b.Package
        $state9b|Add-Member NoteProperty AssistiveServiceChallenge ([pscustomobject]@{State='Running';ParentOperationId=$f9b.Parent;PairId=$f9b.Pair;Role='Target';Actor='OLD-ACTOR';SessionId='OLD-SESSION';ContextId='OLD-CONTEXT';Revision=3;ManifestHash=$manifestHash;Generation=7;PreviewHash=$previewHash;RequiredSecretRefs=@('SecretOld');Requirements=@();ServiceReservations=@();CreatedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc)}) -Force
        Add-WsmJournal $paths9b $state9b 'AssistiveServiceCredentialChallengeResuming' '' $state9b.AssistiveServiceChallenge
        $newContextB=[pscustomobject]@{Role='Target';Actor='NEW-ACTOR';SessionId='NEW-SESSION';ContextId='NEW-CONTEXT';Revision=3;OperationId=$f9b.Parent};$r9b=ResumeNow $f9b -Context $newContextB
        Check ($r9b.Status -ceq 'Succeeded' -and $script:writes -eq 1 -and ($script:writeLog -notcontains 'poola')) 'A Running challenge past the pre-write boundary must reconcile per item instead of asking for a password again.'

        # ---- ItemResults are merged, not replaced ----
        ResetNative;$f10=NewFixture @('PoolA','PoolB')
        $legacyId=Get-WsmHashText 'earlier-item-outside-this-run'
        $prior=@([pscustomobject]@{ItemId=$legacyId;Status='Succeeded';CreatedByTool=$true;AppliedManifestHash=$manifestHash;AppliedGeneration=7;Error='first-run'},[pscustomobject]@{ItemId=$f10.Ids['PoolA'];Status='Failed';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error='first-run-failure'})
        [void](NewInterruptedState $f10 -PriorResults $prior)
        $r10=ResumeNow $f10
        Check (@($r10.ItemResults|Where-Object ItemId -CEQ $legacyId).Count -eq 1 -and (@($r10.ItemResults|Where-Object ItemId -CEQ $legacyId)[0].Error -ceq 'first-run')) 'An item result from the first run vanished after the continuation.'
        Check (@($r10.ItemResults|Where-Object ItemId -CEQ $f10.Ids['PoolA']).Count -eq 1 -and (ResultOf $r10 $f10 'PoolA')[0].Status -ceq 'Succeeded') 'A new result must replace the earlier result of the same item.'
        Check (@((StateOf $f10).RestoreAttempt.ItemResults).Count -eq 3) 'Durable attempt item results were not merged.'

        # ---- non-continuation still refuses to run over another parent's pending intent ----
        ResetNative;$f11=NewFixture @('PoolA','PoolB');[void](NewInterruptedState $f11 -Pending @{PoolA='NativeAbsent'})
        $script:fixture=$f11;$f11.Preview.WizardPreviewHash=$previewHash
        Reject {Invoke-WsmAssistiveRestore -Package $f11.Package -ManifestHash $manifestHash -StateDirectory $pairsDirectory -Secrets @{} -SidMap @{} -CancellationToken ([pscustomobject]@{OperationId=[Guid]::NewGuid().ToString('D')}) -GeneralHostEvidence @() -ReceiptPath $f11.Decision.ReceiptPath -ReceiptHash $receiptHash -TargetSnapshotPath $f11.Decision.SnapshotPath -Preview $f11.Preview -ParentOperationId ([Guid]::NewGuid().ToString('D'))} 'A non-continuation run was not blocked by unresolved pending operations.'
        Check ($script:writes -eq 0) 'Blocked non-continuation run wrote natively.'

        # ---- secrets never reach durable state or journal ----
        ResetNative;$sentinel='SYNTHETIC-CONTINUATION-SENTINEL-4f9c';$pairS=[Guid]::NewGuid().ToString('D');$parentS=[Guid]::NewGuid().ToString('D')
        $svcId=Get-WsmHashText 'continuation-service-item'
        $svcSpec=[pscustomobject]@{Adapter='Service';AccountMode='UserPassword';SecretRef='ServiceSecretA';Owner='Fixture owner';Desired=[pscustomobject]@{Name='FixtureContinuationService';Account='CONTOSO\svc-app';BinaryPathName='C:\Fixture\service.exe';Dependencies=@();Supplement=[pscustomobject]@{}}}
        $svcItem=[pscustomobject]@{ItemId=$svcId;Name='Svc';Decision='Include';MigrationSpec=$svcSpec}
        $packageS=[pscustomobject]@{Root=(Join-Path $root 'backup-media-fixture');PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($svcItem)};Manifest=[pscustomobject]@{PairId=$pairS;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
        $decisionS=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $root 'decision.json');ReceiptHash=$receiptHash;SnapshotPath=(Join-Path $root 'snapshot.json');SelectedItemIds=@($svcId);Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=$snapshotHash}}
        $rowsS=@([pscustomobject]@{ItemId=$svcId;Adapter='Service';Action='RestoreNow';Status='Ready';Reason=''})
        $previewS=[pscustomobject]@{Rows=$rowsS;SelectedItemIds=@($svcId);Problems=@();GeneralHostIssues=@();Blocked=$false;CanRestoreIndependentItems=$true;WizardPreviewHash=$previewHash}
        $projectionS=[pscustomobject]@{Status='Previewed';PairId=$pairS;PlanHash=$planHash;ManifestPath=(Join-Path $root 'manifest.json');ManifestHash=$manifestHash;Generation=7;ReceiptPath=$decisionS.ReceiptPath;ReceiptHash=$receiptHash;TargetSnapshotPath=$decisionS.SnapshotPath;TargetSnapshotHash=$snapshotHash;ComparisonHash=('9'*64);ComparisonRevision=1;SelectionRevision=1;Decision='RestoreNow';SelectedItemIds=@($svcId);Rows=$rowsS;Problems=@();GeneralHostIssues=@();Blocked=$false;CanRestoreIndependentItems=$true;PreviewHash=$previewHash}
        $fS=[pscustomobject]@{Pair=$pairS;Parent=$parentS;Package=$packageS;Decision=$decisionS;Items=@($svcItem);Ids=@{Svc=$svcId};Preview=$previewS;Projection=$projectionS;Context=[pscustomobject]@{Plan=[pscustomobject]@{Items=@($svcItem)};Received=[pscustomobject]@{SHA256=$planHash}};Workspace=$root}
        $script:fixture=$fS
        $contextS=[pscustomobject]@{Role='Target';Actor='S-1-5-18@FIXTURE';SessionId='fixture-session';ContextId='fixture-context';Revision=9;OperationId=$parentS}
        $waitingS=Invoke-WsmAssistiveRestore -Package $packageS -ManifestHash $manifestHash -StateDirectory $pairsDirectory -Secrets @{} -SidMap @{} -CancellationToken ([pscustomobject]@{OperationId=$parentS}) -GeneralHostEvidence @() -ReceiptPath $decisionS.ReceiptPath -ReceiptHash $receiptHash -TargetSnapshotPath $decisionS.SnapshotPath -Preview $previewS -ParentOperationId $parentS -ChallengeContext $contextS
        Check ($waitingS.Status -ceq 'WaitingForInput') 'Service fixture did not enter its credential challenge.'
        $credential=New-Object Management.Automation.PSCredential('CONTOSO\svc-app',(ConvertTo-SecureString $sentinel -AsPlainText -Force))
        $rS=ResumeNow $fS -Secrets @{ServiceSecretA=$credential} -Context $contextS
        Check ($rS.Status -ceq 'Succeeded' -and $script:writes -eq 1 -and $script:sawSecretCount -eq 1) 'Continuation of a waiting Service challenge with a fresh in-memory credential did not complete.'
        $pathsS=Get-WsmOperationPaths $pairsDirectory $pairS
        $durable=[IO.File]::ReadAllText($pathsS.State)+[IO.File]::ReadAllText($pathsS.Journal)
        foreach($file in @(Get-ChildItem -LiteralPath $pathsS.Root -Recurse -File)){$durable+=[IO.File]::ReadAllText($file.FullName)}
        Check ($durable -notmatch [regex]::Escape($sentinel)) 'The synthetic secret sentinel reached durable state or journal.'
        Check ($durable -match 'AssistiveRestoreContinuation') 'The continuation journal event was not written.'

        # ---- E3b-2 core: one shared judgment, sticky cancel, read-only resume preview, newer restore over a stale parent ----
        Set-Item Function:\Get-WsmWizardTargetPreviewHash -Value {param($Preview,$PairId,$PlanHash,$ManifestHash,$Generation,$ReceiptHash,$TargetSnapshotHash,$ComparisonHash,$ComparisonRevision,$SelectionRevision,$Decision)[string]$script:fixture.Projection.PreviewHash}
        function AddWaitingChallenge($Fixture,$Paths){
            $st=Get-WsmOperationState $Paths $Fixture.Package
            $st|Add-Member NoteProperty AssistiveServiceChallenge ([pscustomobject]@{State='WaitingForInput';ParentOperationId=$Fixture.Parent;PairId=$Fixture.Pair;Role='Target';Actor='A';SessionId='S';ContextId='C';Revision=1;ManifestHash=$manifestHash;Generation=7;PreviewHash=$previewHash;RequiredSecretRefs=@('SecretX');Requirements=@([pscustomobject]@{SecretRef='SecretX';Kinds=@('Service');ItemIds=@('i');DisplayNames=@('d');ApprovedAccount='D\u'});ServiceReservations=@();CreatedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc)}) -Force
            $st.Stage='WaitingForInput';$st.RestoreAttempt.Status='WaitingForInput';Add-WsmJournal $Paths $st 'AssistiveServiceCredentialChallengeWaiting' '' $st.AssistiveServiceChallenge
        }
        function FileHash([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
        function Restart($Fixture,[string]$NewOperationId,[string]$Hash,[object[]]$Jobs=@()){
            $script:fixture=$Fixture
            Invoke-WsmWizardTargetRestore -Workspace $root -PairId $Fixture.Pair -PreviewHash $Hash -Jobs $Jobs -OperationId $NewOperationId -CancellationToken ([pscustomobject]@{OperationId=$NewOperationId})
        }

        # shared judgment: exact hash, own-write drift, anything else is a changed review
        ResetNative;$j1=NewFixture @('PoolA','PoolB');$pj1=NewInterruptedState $j1;$sj1=Get-WsmOperationState $pj1 $j1.Package
        Check (Test-WsmWizardTargetRestorePreviewCurrent $sj1.RestoreAttempt $sj1 $j1.Projection) 'The shared judgment rejected an identical preview hash.'
        $j1.Projection.PreviewHash=('1'*64)
        Check (-not (Test-WsmWizardTargetRestorePreviewCurrent $sj1.RestoreAttempt $sj1 $j1.Projection)) 'The shared judgment accepted a different hash with no own-write explanation.'
        $explained=NewFixture @('PoolA','PoolB') @{PoolA='MergeIntoExisting'};$pe=NewInterruptedState $explained -Owned @{PoolA=1};$se=Get-WsmOperationState $pe $explained.Package;$explained.Projection.PreviewHash=('2'*64)
        Check (Test-WsmWizardTargetRestorePreviewCurrent $se.RestoreAttempt $se $explained.Projection) 'The shared judgment ignored the tolerance for rows this parent itself wrote.'

        # read-only resume preview: no file changes at all
        ResetNative;$j2=NewFixture @('PoolA','PoolB');$pj2=NewInterruptedState $j2 -Pending @{PoolA='NativeAbsent'};$script:fixture=$j2
        $beforeState=FileHash $pj2.State;$beforeJournal=FileHash $pj2.Journal
        $rp=Get-WsmWizardTargetRestoreResumePreview -Workspace $root -PairId $j2.Pair -ParentOperationId $j2.Parent
        Check ((FileHash $pj2.State) -ceq $beforeState -and (FileHash $pj2.Journal) -ceq $beforeJournal) 'The resume preview wrote state or journal.'
        Check ($rp.Resumable -and $rp.PreviewCurrent -and $rp.Reason -ceq 'Resumable' -and $rp.PendingCount -eq 1 -and $rp.PendingItems[0].itemId -ceq $j2.Ids['PoolA'] -and $rp.PendingItems[0].displayName -ceq 'PoolA' -and $rp.PendingItems[0].phase -ceq 'AssistiveAdapterCreating') 'The resume preview did not report the pending item with its name and phase.'
        $j2.Projection.PreviewHash=('3'*64);$rp2=Get-WsmWizardTargetRestoreResumePreview -Workspace $root -PairId $j2.Pair -ParentOperationId $j2.Parent
        Check ($rp2.Resumable -and -not $rp2.PreviewCurrent -and $rp2.Reason -ceq 'PreviewChanged') 'The resume preview did not flag a changed preview.'
        Check (-not (Get-WsmWizardTargetRestoreResumePreview -Workspace $root -PairId $j2.Pair -ParentOperationId ([Guid]::NewGuid().ToString('D'))).Resumable) 'The resume preview accepted another parent id.'

        # sticky cancel: attempt and challenge Cancelled, pending record and native object kept, never resumable afterwards
        ResetNative;$j3=NewFixture @('PoolA','PoolB');$pj3=NewInterruptedState $j3 -Pending @{PoolA='NativeAppliedUnprovable'};AddWaitingChallenge $j3 $pj3
        Reject {Stop-WsmWizardTargetRestoreParent -StateDirectory $pairsDirectory -PairId $j3.Pair -ParentOperationId $j3.Parent -Jobs @([pscustomobject]@{jobId=$j3.Parent;status='Running'})} 'A parent with a running worker was cancelled by the sticky cancel.'
        $stopped=Stop-WsmWizardTargetRestoreParent -StateDirectory $pairsDirectory -PairId $j3.Pair -ParentOperationId $j3.Parent
        $s3=StateOf $j3
        Check ($stopped.Status -ceq 'Cancelled' -and [string]$s3.RestoreAttempt.Status -ceq 'Cancelled' -and [string]$s3.AssistiveServiceChallenge.State -ceq 'Cancelled' -and [string]$s3.Stage -ceq 'Cancelled') 'The sticky cancel did not mark attempt, challenge and stage Cancelled.'
        Check (@($s3.PendingOperations).Count -eq 1 -and $script:native.ContainsKey('poola') -and $script:writes -eq 0) 'The sticky cancel removed a pending record or touched a native object.'
        Check ((Get-Content -LiteralPath (Get-WsmOperationPaths $pairsDirectory $j3.Pair).Journal -Raw) -match 'AssistiveRestoreParentCancelled') 'The sticky cancel left no journal event.'
        Reject {ResumeNow $j3} 'A cancelled parent accepted a continuation.'
        Reject {Stop-WsmWizardTargetRestoreParent -StateDirectory $pairsDirectory -PairId $j3.Pair -ParentOperationId $j3.Parent} 'A cancelled parent was cancelled twice.'
        Check (-not (Get-WsmWizardTargetRestoreResumePreview -Workspace $root -PairId $j3.Pair).Resumable) 'A cancelled parent still reported itself resumable.'

        # contract 6, three cases. (a) changed preview: older parent revoked first, then the new restore runs
        ResetNative;$k1=NewFixture @('PoolA','PoolB');$pk1=NewInterruptedState $k1;AddWaitingChallenge $k1 $pk1;$k1.Projection.PreviewHash=('4'*64);$newId=[Guid]::NewGuid().ToString('D')
        $rk1=Restart $k1 $newId ('4'*64);$sk1=StateOf $k1
        Check ($rk1.Status -ceq 'Succeeded' -and $script:writes -eq 2 -and [string]$sk1.RestoreAttempt.OperationId -ceq $newId) 'A changed preview did not let the new restore proceed after revoking the older parent.'
        Check ([string]$sk1.AssistiveServiceChallenge.State -ceq 'Revoked' -and [string]$sk1.AssistiveServiceChallenge.RevokeReason -ceq 'SupersededByNewPreview') 'The older parent challenge was not revoked with the superseded reason.'
        Check ((Get-Content -LiteralPath (Get-WsmOperationPaths $pairsDirectory $k1.Pair).Journal -Raw) -match ('AssistiveRestoreParentSuperseded.*'+$k1.Parent)) 'Superseding the older parent left no journal event naming it.'
        # (b) unchanged preview: existing rule stays, nothing is revoked automatically
        ResetNative;$k2=NewFixture @('PoolA','PoolB');$pk2=NewInterruptedState $k2;AddWaitingChallenge $k2 $pk2
        Reject {Restart $k2 ([Guid]::NewGuid().ToString('D')) $previewHash} 'A new restore silently took over a waiting parent whose preview is unchanged.'
        $sk2=StateOf $k2
        Check ([string]$sk2.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and [string]$sk2.RestoreAttempt.Status -ceq 'WaitingForInput' -and $script:writes -eq 0) 'An unchanged-preview parent was revoked or written by a refused restore.'
        # (c) older worker still alive: refused, nothing revoked
        ResetNative;$k3=NewFixture @('PoolA','PoolB');$pk3=NewInterruptedState $k3;AddWaitingChallenge $k3 $pk3;$k3.Projection.PreviewHash=('5'*64)
        Reject {Restart $k3 ([Guid]::NewGuid().ToString('D')) ('5'*64) @([pscustomobject]@{jobId=$k3.Parent;status='Running'})} 'A new restore started while the older parent worker was alive.'
        $sk3=StateOf $k3
        Check ([string]$sk3.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and [string]$sk3.RestoreAttempt.Status -ceq 'WaitingForInput' -and $script:writes -eq 0) 'A live older parent was revoked or written by a refused restore.'
        # (d) unresolved native intent is never auto-revoked
        ResetNative;$k4=NewFixture @('PoolA','PoolB');$pk4=NewInterruptedState $k4 -Pending @{PoolA='NativeAbsent'};$k4.Projection.PreviewHash=('6'*64)
        $script:fixture=$k4
        Check ((Invoke-WsmWizardSupersedeStaleTargetRestoreParent -Workspace $root -PairId $k4.Pair -OperationId ([Guid]::NewGuid().ToString('D')) -PreviewHash ('6'*64) -Projection $k4.Projection) -ceq '') 'A parent with an unresolved native intent was auto-revoked.'
        Check ([string](StateOf $k4).RestoreAttempt.Status -ceq 'Running') 'The pending-intent parent changed state.'

        # ---- CLI: an interrupted parent is resumed only after RESUME is typed ----
        $originalCliPrompt=(Get-Command Read-WsmWizardValue -CommandType Function).ScriptBlock
        try{
            ResetNative;$c1=NewFixture @('PoolA','PoolB','SiteA','SiteB');[void](NewInterruptedState $c1);$script:fixture=$c1
            Set-Item Function:\Read-WsmWizardValue -Value {param([string]$Label,[switch]$Optional)$script:cliPrompts++;'NO'};$script:cliPrompts=0
            $declined=Invoke-WsmWizardTargetRestoreResumeFlow $root $pairsDirectory $c1.Package @()
            Check ($declined.Status -ceq 'NotResumed' -and $declined.ParentOperationId -ceq $c1.Parent -and $declined.NoTargetWrites -and $script:cliPrompts -eq 1 -and $script:writes -eq 0 -and -not (StateOf $c1).RestoreAttempt.PSObject.Properties['Continuations']) 'A CLI answer other than RESUME resumed or changed the parent.'
            Set-Item Function:\Read-WsmWizardValue -Value {param([string]$Label,[switch]$Optional)throw (New-Object IO.EndOfStreamException('Console input ended.'))}
            $noInput=$null;try{Invoke-WsmWizardTargetRestoreResumeFlow $root $pairsDirectory $c1.Package @()|Out-Null}catch{$noInput=$_.Exception}
            Check ($noInput -is [IO.EndOfStreamException] -and $noInput.Data.Contains('WsmWaitingForInput') -and [string]$noInput.Data['ParentOperationId'] -ceq $c1.Parent -and $script:writes -eq 0) 'Unavailable CLI input did not stop as WaitingForInput naming the parent (R16: exit 2, not InputUnavailable/3).'
            Set-Item Function:\Read-WsmWizardValue -Value {param([string]$Label,[switch]$Optional)throw 'Required value is blank.'}
            Check ((Invoke-WsmWizardTargetRestoreResumeFlow $root $pairsDirectory $c1.Package @()).Status -ceq 'NotResumed') 'A blank CLI answer was not treated as no action.'
            Set-Item Function:\Read-WsmWizardValue -Value {param([string]$Label,[switch]$Optional)'RESUME'}
            $resumed=Invoke-WsmWizardTargetRestoreResumeFlow $root $pairsDirectory $c1.Package @()
            Check ($resumed.Status -ceq 'Succeeded' -and $script:writes -eq 4 -and @((StateOf $c1).RestoreAttempt.Continuations).Count -eq 1) 'Typing RESUME did not continue the same parent through Resume-WsmWizardTargetRestore.'
            # nothing to resume (terminal) or a preview that changed: the normal restore flow decides
            Check ($null -eq (Invoke-WsmWizardTargetRestoreResumeFlow $root $pairsDirectory $c1.Package @())) 'A terminal parent was offered for resume.'
            ResetNative;$c2=NewFixture @('PoolA');[void](NewInterruptedState $c2);$c2.Projection.PreviewHash=('8'*64);$script:fixture=$c2
            Check ($null -eq (Invoke-WsmWizardTargetRestoreResumeFlow $root $pairsDirectory $c2.Package @())) 'A parent whose preview changed was offered for resume instead of a new restore.'
        }finally{Set-Item Function:\Read-WsmWizardValue -Value $originalCliPrompt}

        # ---- E3b-3: mid-flight FileScope ownership (D5) and re-asking for the credential on continuation (D6) ----
        $script:payloadCopies=@{};$script:crash=$null;$script:onPayload=$null;$script:driftFixture=$null;$script:driftHash=''
        $script:realJournal=(Get-Command Add-WsmJournal -CommandType Function).ScriptBlock
        Set-Item Function:\Add-WsmJournal -Value {param($Paths,$State,[string]$Action,[string]$ItemId,$Detail)if($script:crash){if($script:crash.Dead){throw 'SIMULATED-PROCESS-DEATH'};if($Action -ceq $script:crash.Action){$script:crash.Seen++;if($script:crash.Seen -eq $script:crash.N){$script:crash.Dead=$true;throw [OperationCanceledException]::new('SIMULATED-PROCESS-DEATH')}}};& $script:realJournal $Paths $State $Action $ItemId $Detail}
        Set-Item Function:\Read-WsmArtifactLines -Value {param($Path,$Hash,$CancellationToken)$script:fixture.Entries}
        Set-Item Function:\Restore-WsmPayloadBytes -Value {param($Entry,$PackageRoot,$Destination,$CancellationToken)$key=[string]$Entry.RelativePath;if($script:onPayload){& $script:onPayload $key};if($script:payloadCopies.ContainsKey($key)){$script:payloadCopies[$key]++}else{$script:payloadCopies[$key]=1};[IO.File]::Copy([string]$Entry.Data.SourcePath,$Destination,$true)}
        function Set-FixtureAcl([string]$Path){$acl=Get-Acl -LiteralPath $Path;$acl.SetAccessRuleProtection($true,$false);$inherit=[Security.AccessControl.InheritanceFlags]([int][Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [int][Security.AccessControl.InheritanceFlags]::ObjectInherit);foreach($id in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')){$sid=New-Object Security.Principal.SecurityIdentifier($id);[void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))};Set-Acl -LiteralPath $Path -AclObject $acl}
        function NewScopeFixture([bool]$WithService){
            $pair=[Guid]::NewGuid().ToString('D');$parent=[Guid]::NewGuid().ToString('D')
            $src=Join-Path $root ('fs-src-'+$pair);$sub=Join-Path $src 'sub';[void][IO.Directory]::CreateDirectory($sub);Set-FixtureAcl $src;Set-FixtureAcl $sub
            $target=Join-Path $root ('fs-target-'+$pair)
            $fileDefs=@(@('one.txt',(Join-Path $src 'one.txt'),'first file bytes'),@('sub\two.txt',(Join-Path $sub 'two.txt'),'second file bytes'),@('three.txt',(Join-Path $src 'three.txt'),'third file bytes'))
            foreach($def in $fileDefs){[IO.File]::WriteAllText($def[1],$def[2])}
            $itemId=Get-WsmHashText ('e3b3-files-'+$pair)
            $entries=@([pscustomobject]@{ItemId=$itemId;RelativePath='';Directory=$true;Data=$null;Metadata=(Get-WsmFileMetadata $src 'DaclOwner')},[pscustomobject]@{ItemId=$itemId;RelativePath='sub';Directory=$true;Data=$null;Metadata=(Get-WsmFileMetadata $sub 'DaclOwner')})
            foreach($def in $fileDefs){$entries+=@([pscustomobject]@{ItemId=$itemId;RelativePath=$def[0];Directory=$false;Data=[pscustomobject]@{Hash=(Get-FileHash -LiteralPath $def[1] -Algorithm SHA256).Hash.ToLowerInvariant();Bytes=([IO.FileInfo]$def[1]).Length;SourcePath=$def[1]};Metadata=(Get-WsmFileMetadata $def[1] 'DaclOwner')})}
            $fileItem=[pscustomobject]@{ItemId=$itemId;Name='Files';Kind='FileScope';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C';TargetPath=$target;Metadata='DaclOwner';AclControlPolicy='Exact'}}
            $items=@($fileItem);$ids=@{Files=$itemId}
            if($WithService){$svcId=Get-WsmHashText ('e3b3-service-'+$pair);$ids['Svc']=$svcId;$items+=@([pscustomobject]@{ItemId=$svcId;Name='Svc';Kind='Service';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='Service';AccountMode='UserPassword';SecretRef='ServiceSecretA';Owner='Fixture owner';Desired=[pscustomobject]@{Name=('E3b3Svc'+$pair.Substring(0,8));Account='CONTOSO\svc-app';BinaryPathName='C:\Fixture\service.exe';Dependencies=@();Supplement=[pscustomobject]@{}}}})}
            $package=[pscustomobject]@{Root=(Join-Path $root 'backup-media-fixture');PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($items)};Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;ArtifactsHash=('b'*64);Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
            $selected=@($items|ForEach-Object {$_.ItemId})
            $decision=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $root 'decision.json');ReceiptHash=$receiptHash;SnapshotPath=(Join-Path $root 'snapshot.json');SelectedItemIds=$selected;Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=$snapshotHash}}
            $rows=@($items|ForEach-Object {[pscustomobject]@{ItemId=$_.ItemId;Adapter=$_.MigrationSpec.Adapter;Action='RestoreNow';Status='Ready';Reason=''}})
            $preview=[pscustomobject]@{Rows=$rows;SelectedItemIds=$selected;Problems=@();GeneralHostIssues=@();Blocked=$false;CanRestoreIndependentItems=$true;WizardPreviewHash=$previewHash}
            $projection=[pscustomobject]@{Status='Previewed';PairId=$pair;PlanHash=$planHash;ManifestPath=(Join-Path $root 'manifest.json');ManifestHash=$manifestHash;Generation=7;ReceiptPath=$decision.ReceiptPath;ReceiptHash=$receiptHash;TargetSnapshotPath=$decision.SnapshotPath;TargetSnapshotHash=$snapshotHash;ComparisonHash=('9'*64);ComparisonRevision=1;SelectionRevision=1;Decision='RestoreNow';SelectedItemIds=$selected;Rows=$rows;Problems=@();GeneralHostIssues=@();Blocked=$false;CanRestoreIndependentItems=$true;PreviewHash=$previewHash}
            [pscustomobject]@{Pair=$pair;Parent=$parent;Package=$package;Decision=$decision;Items=$items;Ids=$ids;OriginalRows=$rows;Preview=$preview;Projection=$projection;Context=[pscustomobject]@{Plan=[pscustomobject]@{Items=@($items)};Received=[pscustomobject]@{SHA256=$planHash}};Workspace=$root;Entries=$entries;Target=$target;ServiceName=$(if($WithService){('e3b3svc'+$pair.Substring(0,8))}else{''})}
        }
        function RunFresh($Fixture,[hashtable]$Secrets=@{},$Context=$null){
            $script:fixture=$Fixture
            Invoke-WsmAssistiveRestore -Package $Fixture.Package -ManifestHash $manifestHash -StateDirectory $pairsDirectory -Secrets $Secrets -SidMap @{} -CancellationToken ([pscustomobject]@{OperationId=$Fixture.Parent}) -GeneralHostEvidence @() -ReceiptPath $Fixture.Decision.ReceiptPath -ReceiptHash $receiptHash -TargetSnapshotPath $Fixture.Decision.SnapshotPath -Preview $Fixture.Preview -ParentOperationId $Fixture.Parent -ChallengeContext $Context
        }
        # Simulated process death: the Nth journal event of the action throws a cancellation (so the item handler cannot continue with later native side effects) and every later journal append throws too, so no in-memory change reaches disk.
        function RunUntilDeath([scriptblock]$Run,[string]$Action,[int]$Nth){
            $script:crash=@{Action=$Action;N=$Nth;Seen=0;Dead=$false};$died=$false
            try{& $Run|Out-Null}catch{if($_.Exception.Message -match 'SIMULATED-PROCESS-DEATH'){$died=$true}else{throw}}finally{$script:crash=$null}
            $died
        }
        function FileStatus($Result,$Fixture,[string]$Relative){$record=(ResultOf $Result $Fixture 'Files')[0];@($record.FileResults|Where-Object RelativePath -CEQ $Relative)[0].Status}
        function MakeDeadScopeRun([bool]$WithService){
            ResetNative;$script:payloadCopies=@{}
            $fx=NewScopeFixture $WithService
            Check (RunUntilDeath {RunFresh $fx} 'AssistiveFileCompleted' 2) 'The simulated process death did not interrupt the FileScope after the second file was written.'
            $fx
        }

        # D5 positive: three files, one created subdirectory; first completed, second written but not journalled as completed.
        $d1=MakeDeadScopeRun $false
        $sd1=StateOf $d1
        Check (@($sd1.PendingOperations).Count -eq 1 -and [string]$sd1.PendingOperations[0].RelativePath -ceq 'sub\two.txt') 'The dead run did not leave the second file transaction pending.'
        Check ([IO.File]::Exists((Join-Path $d1.Target 'one.txt')) -and [IO.File]::Exists((Join-Path $d1.Target 'sub\two.txt')) -and -not [IO.File]::Exists((Join-Path $d1.Target 'three.txt'))) 'The dead run did not stop between the second and third file.'
        $partial1=@($sd1.AssistivePartialOwnership)
        Check (@($partial1|Where-Object {$_.Kind -ceq 'File' -and $_.Record.RelativePath -ceq 'one.txt'}).Count -eq 1 -and @($partial1|Where-Object Kind -ceq 'File').Count -eq 1 -and @($partial1|Where-Object Kind -ceq 'Directory').Count -eq 2) 'In-flight ownership must be durable for the completed file and both created directories, and for nothing else.'
        Check (@($partial1|Where-Object {[string]$_.ParentOperationId -cne $d1.Parent -or [string]$_.ManifestHash -cne $manifestHash -or [long]$_.Generation -ne 7}).Count -eq 0) 'In-flight ownership is not bound to the parent operation, manifest and generation.'
        $r1d=ResumeNow $d1
        Check ($r1d.Status -ceq 'Succeeded') ('D5: the continuation did not finish Succeeded; status='+$r1d.Status+'; files='+((@((ResultOf $r1d $d1 'Files')[0].FileResults|ForEach-Object {$_.RelativePath+'='+$_.Status+':'+$_.Reason})) -join ' | '))
        Check ((FileStatus $r1d $d1 'one.txt') -ceq 'VerifiedOwned' -and (FileStatus $r1d $d1 'sub\two.txt') -ceq 'VerifiedOwned' -and (FileStatus $r1d $d1 'three.txt') -ceq 'Applied') 'D5: completed, in-doubt and remaining files must end VerifiedOwned / VerifiedOwned / Applied.'
        Check ((FileStatus $r1d $d1 'sub') -ceq 'DirectoryVerified' -and (FileStatus $r1d $d1 '') -ceq 'DirectoryVerified') ('D5: directories created by this parent must be verified, not DirectoryPreserved; files='+((@((ResultOf $r1d $d1 'Files')[0].FileResults|ForEach-Object {'['+$_.RelativePath+']='+$_.Status+':'+$_.Reason})) -join ' | '))
        Check ((ResultOf $r1d $d1 'Files')[0].Status -ceq 'Succeeded' -and @((ResultOf $r1d $d1 'Files')[0].OwnedFiles).Count -eq 3 -and @((ResultOf $r1d $d1 'Files')[0].OwnedDirectories).Count -eq 2) 'D5: the FileScope item must end Succeeded owning all three files and both directories.'
        Check ($script:payloadCopies['one.txt'] -eq 1 -and $script:payloadCopies['sub\two.txt'] -eq 1 -and $script:payloadCopies['three.txt'] -eq 1) 'D5: a file was written more than once.'
        $sd1b=StateOf $d1
        Check (@($sd1b.AssistivePartialOwnership|Where-Object ItemId -CEQ $d1.Ids['Files']).Count -eq 0) 'D5: in-flight ownership was not folded into the final record and cleared.'

        # D5 counter 1: in-flight ownership of another parent operation grants nothing.
        $d2=MakeDeadScopeRun $false
        $pp2=Get-WsmOperationPaths $pairsDirectory $d2.Pair;$st2=Get-WsmOperationState $pp2 $d2.Package;foreach($entry2 in @($st2.AssistivePartialOwnership)){$entry2.ParentOperationId=[Guid]::NewGuid().ToString('D')};Write-WsmJson $pp2.State $st2
        $r2d=ResumeNow $d2
        # R3: a same-content file that no trustworthy ownership record covers is no longer a conflict: it is recorded as an adopted existing file (Ownership=AdoptedExisting, never rewritten, never deleted by a rollback).
        # What the foreign in-flight record must still NOT grant is tool ownership: the row carries the AdoptedExisting class, the directory stays DirectoryPreserved, and the file is not written again.
        $r2Files=(ResultOf $r2d $d2 'Files')[0];$r2One=@($r2Files.OwnedFiles|Where-Object {[string]$_.RelativePath -ceq 'one.txt'})
        Check ((FileStatus $r2d $d2 'one.txt') -ceq 'VerifiedOwned' -and $r2One.Count -eq 1 -and $r2One[0].PSObject.Properties['Ownership'] -and [string]$r2One[0].Ownership -ceq 'AdoptedExisting' -and (FileStatus $r2d $d2 'sub') -ceq 'DirectoryPreserved') ('D5: in-flight ownership of another parent operation must not grant tool ownership (expected an adopted existing file); files='+((@($r2Files.FileResults|ForEach-Object {'['+$_.RelativePath+']='+$_.Status+':'+$_.Reason})) -join ' | '))
        Check ($script:payloadCopies['one.txt'] -eq 1 -and [IO.File]::ReadAllText((Join-Path $d2.Target 'one.txt')) -ceq 'first file bytes') 'D5: the foreign-parent case rewrote the first file.'
        # D5 counter 2: in-flight ownership of another generation grants nothing.
        $d2b=MakeDeadScopeRun $false
        $pp2b=Get-WsmOperationPaths $pairsDirectory $d2b.Pair;$st2b=Get-WsmOperationState $pp2b $d2b.Package;foreach($entry2b in @($st2b.AssistivePartialOwnership)){$entry2b.Generation=6};Write-WsmJson $pp2b.State $st2b
        $r2e=ResumeNow $d2b
        # R3: same reasoning as counter 1; the in-flight record of another generation is ignored, the identical bytes are adopted (not tool-owned).
        $r2eFiles=(ResultOf $r2e $d2b 'Files')[0];$r2eOne=@($r2eFiles.OwnedFiles|Where-Object {[string]$_.RelativePath -ceq 'one.txt'})
        Check ((FileStatus $r2e $d2b 'one.txt') -ceq 'VerifiedOwned' -and $r2eOne.Count -eq 1 -and $r2eOne[0].PSObject.Properties['Ownership'] -and [string]$r2eOne[0].Ownership -ceq 'AdoptedExisting') ('D5: in-flight ownership of another generation must not grant tool ownership (expected an adopted existing file); files='+((@($r2eFiles.FileResults|ForEach-Object {'['+$_.RelativePath+']='+$_.Status+':'+$_.Reason})) -join ' | '))
        # D5 counter 3: the first file changed externally after the death: reported as drift, never overwritten.
        $d3=MakeDeadScopeRun $false
        [IO.File]::WriteAllText((Join-Path $d3.Target 'one.txt'),'externally changed')
        $r3d=ResumeNow $d3
        Check ((FileStatus $r3d $d3 'one.txt') -ceq 'BlockedConflict' -and [IO.File]::ReadAllText((Join-Path $d3.Target 'one.txt')) -ceq 'externally changed' -and $script:payloadCopies['one.txt'] -eq 1 -and $r3d.Status -ceq 'Partial') 'D5: an externally changed completed file was overwritten or accepted.'
        Check ((FileStatus $r3d $d3 'three.txt') -ceq 'Applied') 'D5: drift of one file stopped the remaining files.'

        # D6: FileScope first, Service (UserPassword) second; credential submitted, process dies inside the FileScope.
        $sentinel6='SYNTHETIC-E3B3-SENTINEL-71ac'
        $ctx1=[pscustomobject]@{Role='Target';Actor='S-1-5-18@FIXTURE';SessionId='session-one';ContextId='context-one';Revision=9;OperationId=''}
        function NewContext([string]$Parent,[string]$Session){[pscustomobject]@{Role='Target';Actor='S-1-5-18@FIXTURE';SessionId=$Session;ContextId=('context-'+$Session);Revision=9;OperationId=$Parent}}
        function StartDeadServiceRun(){
            ResetNative;$script:payloadCopies=@{}
            $fx=NewScopeFixture $true
            $c1=NewContext $fx.Parent 'session-one'
            $w=RunFresh $fx @{} $c1
            Check ($w.Status -ceq 'WaitingForInput' -and @($w.RequiredSecretRefs) -contains 'ServiceSecretA') 'D6 setup: the first call did not wait for the Service credential.'
            $cred=New-Object Management.Automation.PSCredential('CONTOSO\svc-app',(ConvertTo-SecureString $sentinel6 -AsPlainText -Force))
            Check (RunUntilDeath {RunFresh $fx @{ServiceSecretA=$cred} $c1} 'AssistiveFileCompleted' 2) 'D6 setup: the submitted run did not die inside the FileScope.'
            $fx
        }
        $e1=StartDeadServiceRun
        $se1=StateOf $e1
        Check ([string]$se1.AssistiveServiceChallenge.State -ceq 'Running' -and [string]$se1.AssistiveServiceChallenge.SessionId -ceq 'session-one') 'D6 setup: the dead run must leave a Running challenge bound to the old session.'
        $ctx2=NewContext $e1.Parent 'session-two'
        $r6=ResumeNow $e1 -Context $ctx2
        $s6=StateOf $e1
        Check ($r6.Status -ceq 'WaitingForInput' -and $r6.ParentOperationId -ceq $e1.Parent -and @($r6.RequiredSecretRefs).Count -eq 1 -and @($r6.RequiredSecretRefs)[0] -ceq 'ServiceSecretA') ('D6: the continuation without a secret must wait for the Service credential only; status='+$r6.Status)
        Check ($script:writes -eq 0 -and -not $script:native.ContainsKey($e1.ServiceName)) 'D6: the Service was written without a credential.'
        Check ([string]$s6.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and [string]$s6.AssistiveServiceChallenge.SessionId -ceq 'session-two' -and [string]$s6.AssistiveServiceChallenge.ContextId -ceq 'context-session-two' -and [string]$s6.AssistiveServiceChallenge.Actor -ceq 'S-1-5-18@FIXTURE' -and @($s6.AssistiveServiceChallenge.RequiredSecretRefs).Count -eq 1) 'D6: the challenge was not rebound to the current session.'
        Check ([string]$s6.RestoreAttempt.Status -ceq 'WaitingForInput' -and [string]$s6.Stage -ceq 'WaitingForInput' -and @($s6.PendingOperations).Count -eq 0) 'D6: the parent is not back in WaitingForInput with nothing pending.'
        $filesRecord6=@($s6.Items|Where-Object ItemId -CEQ $e1.Ids['Files'])
        Check ($filesRecord6.Count -eq 1 -and [string]$filesRecord6[0].Status -ceq 'Succeeded' -and @($filesRecord6[0].OwnedFiles).Count -eq 3 -and $script:payloadCopies['one.txt'] -eq 1 -and $script:payloadCopies['sub\two.txt'] -eq 1 -and $script:payloadCopies['three.txt'] -eq 1) 'D6: the FileScope was not finished exactly once before waiting.'
        Check (@($s6.Items|Where-Object ItemId -CEQ $e1.Ids['Svc']).Count -eq 0 -and -not (@($s6.RestoreAttempt.ItemResults|Where-Object ItemId -CEQ $e1.Ids['Svc']).Count)) 'D6: the Service was marked with a result although it was never attempted.'
        # reply from the old session is refused; reply from the new session finishes the parent
        $cred6=New-Object Management.Automation.PSCredential('CONTOSO\svc-app',(ConvertTo-SecureString $sentinel6 -AsPlainText -Force))
        $script:fixture=$e1
        Reject {Invoke-WsmWizardTargetRestore -Workspace $root -PairId $e1.Pair -PreviewHash $previewHash -Jobs @() -OperationId $e1.Parent -CancellationToken ([pscustomobject]@{OperationId=$e1.Parent}) -Secrets @{ServiceSecretA=$cred6} -ChallengeContext (NewContext $e1.Parent 'session-one')} 'D6: a secret reply from the old session was accepted.'
        Check ($script:writes -eq 0) 'D6: the old-session reply wrote natively.'
        $done6=Invoke-WsmWizardTargetRestore -Workspace $root -PairId $e1.Pair -PreviewHash $previewHash -Jobs @() -OperationId $e1.Parent -CancellationToken ([pscustomobject]@{OperationId=$e1.Parent}) -Secrets @{ServiceSecretA=$cred6} -ChallengeContext $ctx2
        Check ($done6.Status -ceq 'Succeeded' -and $script:writes -eq 1 -and @($script:writeLog|Where-Object {$_ -ceq $e1.ServiceName}).Count -eq 1) ('D6: the Service was not applied exactly once after the new reply; status='+$done6.Status)
        Check ($script:payloadCopies['one.txt'] -eq 1 -and $script:payloadCopies['three.txt'] -eq 1) 'D6: the finished FileScope was redone after the credential arrived.'
        Check ([string](StateOf $e1).Stage -ceq 'Succeeded') 'D6: the parent did not end Succeeded.'
        $pathsE=Get-WsmOperationPaths $pairsDirectory $e1.Pair;$durableE=[IO.File]::ReadAllText($pathsE.State)+[IO.File]::ReadAllText($pathsE.Journal)
        foreach($fileE in @(Get-ChildItem -LiteralPath $pathsE.Root -Recurse -File)){$durableE+=[IO.File]::ReadAllText($fileE.FullName)}
        Check ($durableE -notmatch [regex]::Escape($sentinel6) -and $durableE -match 'AssistiveServiceCredentialReprompt') 'D6: the synthetic secret reached durable state, or the reprompt left no journal event.'

        # D6 counter: the remaining credential group was already deferred -> no input is requested; the parent ends Partial.
        $e2=StartDeadServiceRun
        $pe2=Get-WsmOperationPaths $pairsDirectory $e2.Pair;$ste2=Get-WsmOperationState $pe2 $e2.Package
        foreach($requirement2 in @($ste2.AssistiveServiceChallenge.Requirements)){$requirement2|Add-Member NoteProperty Deferred $true -Force;$requirement2|Add-Member NoteProperty DeferReason 'CredentialRejectedLimit' -Force}
        Write-WsmJson $pe2.State $ste2
        $r6d=ResumeNow $e2 -Context (NewContext $e2.Parent 'session-two')
        Check ($r6d.Status -ceq 'Partial' -and (ResultOf $r6d $e2 'Svc')[0].Status -ceq 'Deferred' -and $script:writes -eq 0) ('D6: a deferred credential group was asked for again or written; status='+$r6d.Status)
        # D6 counter: an already owned Service only reads back and needs no credential on continuation.
        $e3=StartDeadServiceRun
        $script:native[$e3.ServiceName]=@{Passes=$true}
        $pe3=Get-WsmOperationPaths $pairsDirectory $e3.Pair;$ste3=Get-WsmOperationState $pe3 $e3.Package
        $ste3.Items=@($ste3.Items)+@([pscustomobject]@{ItemId=$e3.Ids['Svc'];Status='Succeeded';CreatedByTool=$true;AppliedManifestHash=$manifestHash;AppliedGeneration=7;ActualHash=('7'*64);Target=$e3.ServiceName;Error='';NativeCode=0});Write-WsmJson $pe3.State $ste3
        $r6e=ResumeNow $e3 -Context (NewContext $e3.Parent 'session-two')
        Check ($r6e.Status -ceq 'Succeeded' -and $script:writes -eq 0) ('D6: a Service that already exists and is owned was asked for a credential; status='+$r6e.Status)

        # ---- E3b-4: a preview that moved because of this parent's own writes is rebound durably (G-D7) ----
        function JournalRows([string]$Pair){$jp=(Get-WsmOperationPaths $pairsDirectory $Pair).Journal;@([IO.File]::ReadAllLines($jp)|Where-Object {$_}|ForEach-Object {ConvertFrom-WsmJson $_})}
        function ReboundRows([string]$Pair){@(JournalRows $Pair|Where-Object Action -CEQ 'AssistiveRestorePreviewRebound')}
        function DriftFilesRow($Fixture,[string]$Hash){
            $Fixture.Projection.Rows=@($Fixture.Projection.Rows|ForEach-Object {$c=$_.PSObject.Copy();if([string]$c.ItemId -ceq $Fixture.Ids['Files']){$c.Action='MergeIntoExistingDirectory';$c.Reason='Rows written by this parent.'};$c})
            $Fixture.Projection.PreviewHash=$Hash
        }
        $rebindHash=('5'*64)
        $g1=StartDeadServiceRun
        $ctxG=NewContext $g1.Parent 'session-two'
        # the continuation itself writes the third file, which is what moves the live preview (the Files row turns into a merge)
        $script:driftFixture=$g1;$script:driftHash=$rebindHash
        $script:onPayload={param($key)if($key -ceq 'three.txt'){DriftFilesRow $script:driftFixture $script:driftHash}}
        try{$gr=ResumeNow $g1 -Context $ctxG}finally{$script:onPayload=$null}
        $sg=StateOf $g1
        Check ($gr.Status -ceq 'WaitingForInput' -and [string]$gr.PreviewHash -ceq $rebindHash) ('E3b-4: the waiting result must carry the rebound preview hash; status='+$gr.Status+' hash='+$gr.PreviewHash)
        Check ([string]$sg.RestoreAttempt.WizardPreviewHash -ceq $rebindHash -and [string]$sg.AssistiveServiceChallenge.PreviewHash -ceq $rebindHash) 'E3b-4: attempt and challenge were not both rebound to the current preview.'
        $expectedRows=@(Get-WsmAssistivePreviewRowHashes $g1.Projection.Rows)
        Check ((($sg.RestoreAttempt.PreviewRowHashes|ForEach-Object {$_.ItemId+'='+$_.Hash}) -join ';') -ceq (($expectedRows|ForEach-Object {$_.ItemId+'='+$_.Hash}) -join ';')) 'E3b-4: the stored per-row digests were not moved to the current rows.'
        $reboundG=@(ReboundRows $g1.Pair)
        Check ($reboundG.Count -eq 1 -and [string]$reboundG[0].Detail.ParentOperationId -ceq $g1.Parent -and [string]$reboundG[0].Detail.PreviousPreviewHash -ceq $previewHash -and [string]$reboundG[0].Detail.PreviewHash -ceq $rebindHash -and [string]$reboundG[0].Detail.Reason -ceq 'OwnWritesExplained') 'E3b-4: AssistiveRestorePreviewRebound was not journalled once with parent, old hash, new hash and reason.'
        # strictness is unchanged: the old reviewed hash no longer matches the durable parent
        $cred7=New-Object Management.Automation.PSCredential('CONTOSO\svc-app',(ConvertTo-SecureString 'SYNTHETIC-E3B4-SENTINEL-2d1e' -AsPlainText -Force))
        $script:fixture=$g1
        Reject {Invoke-WsmWizardTargetRestore -Workspace $root -PairId $g1.Pair -PreviewHash $previewHash -Jobs @() -OperationId $g1.Parent -CancellationToken ([pscustomobject]@{OperationId=$g1.Parent}) -Secrets @{ServiceSecretA=$cred7} -ChallengeContext $ctxG} 'E3b-4: the superseded old preview hash was still accepted.'
        Check ($script:writes -eq 0) 'E3b-4: a refused old-hash reply wrote natively.'
        $doneG=Invoke-WsmWizardTargetRestore -Workspace $root -PairId $g1.Pair -PreviewHash ([string]$gr.PreviewHash) -Jobs @() -OperationId $g1.Parent -CancellationToken ([pscustomobject]@{OperationId=$g1.Parent}) -Secrets @{ServiceSecretA=$cred7} -ChallengeContext $ctxG
        Check ($doneG.Status -ceq 'Succeeded' -and $script:writes -eq 1 -and @($script:writeLog|Where-Object {$_ -ceq $g1.ServiceName}).Count -eq 1) ('E3b-4: the Service was not applied exactly once with the rebound hash; status='+$doneG.Status)
        Check ($script:payloadCopies['one.txt'] -eq 1 -and $script:payloadCopies['sub\two.txt'] -eq 1 -and $script:payloadCopies['three.txt'] -eq 1) 'E3b-4: a file was written again after the rebind.'
        Check (@(ReboundRows $g1.Pair).Count -eq 1) 'E3b-4: the final restore rebound the preview again although the hash was unchanged.'

        # equal hash: nothing is written and the stored value is returned
        ResetNative;$h1=NewFixture @('PoolA','PoolB');$ph1=NewInterruptedState $h1;AddWaitingChallenge $h1 $ph1;$script:fixture=$h1
        $beforeStateH=FileHash $ph1.State;$beforeJournalH=FileHash $ph1.Journal
        $sameHash=Update-WsmWizardTargetRestorePreviewBinding -StateDirectory $pairsDirectory -PairId $h1.Pair -ParentOperationId $h1.Parent -Projection $h1.Projection
        Check ($sameHash -ceq $previewHash -and (FileHash $ph1.State) -ceq $beforeStateH -and (FileHash $ph1.Journal) -ceq $beforeJournalH) 'E3b-4: an unchanged preview hash wrote state or journal.'
        # a different hash with no own-write explanation: refused, nothing moves, and the resolver leaves the given hash alone
        $h1.Projection.PreviewHash=('6'*64)
        Reject {Update-WsmWizardTargetRestorePreviewBinding -StateDirectory $pairsDirectory -PairId $h1.Pair -ParentOperationId $h1.Parent -Projection $h1.Projection} 'E3b-4: an unexplained preview change was rebound.'
        Check ((Resolve-WsmWizardTargetRestorePreviewBinding -Workspace $root -PairId $h1.Pair -ParentOperationId $h1.Parent -PreviewHash $previewHash) -ceq $previewHash -and (FileHash $ph1.State) -ceq $beforeStateH -and (FileHash $ph1.Journal) -ceq $beforeJournalH) 'E3b-4: the resolver rebound or wrote after a false judgment.'
        # counter: one row explained by own writes, another row changed by something else -> the judgment is false, no rebind, the normal revoke path applies
        ResetNative;$h2=NewFixture @('PoolA','PoolB') @{PoolA='MergeIntoExisting';PoolB='BlockedConflict'};$ph2=NewInterruptedState $h2 -Owned @{PoolA=1};AddWaitingChallenge $h2 $ph2;$h2.Projection.PreviewHash=('7'*64);$script:fixture=$h2
        $beforeStateH2=FileHash $ph2.State;$beforeJournalH2=FileHash $ph2.Journal
        Reject {Update-WsmWizardTargetRestorePreviewBinding -StateDirectory $pairsDirectory -PairId $h2.Pair -ParentOperationId $h2.Parent -Projection $h2.Projection} 'E3b-4: a change outside this parent own writes was rebound.'
        Check ((FileHash $ph2.State) -ceq $beforeStateH2 -and (FileHash $ph2.Journal) -ceq $beforeJournalH2 -and @(ReboundRows $h2.Pair).Count -eq 0) 'E3b-4: the refused rebind changed state or journal.'
        $rh2=ResumeNow $h2
        Check ($rh2.Status -ceq 'NeedsNewPreview' -and [string](StateOf $h2).AssistiveServiceChallenge.State -ceq 'Revoked' -and @(ReboundRows $h2.Pair).Count -eq 0 -and $script:writes -eq 0) 'E3b-4: an externally changed row must still revoke through the existing path without any rebind.'
        # replay: AssistiveRestorePreviewRebound restores both hashes after the checkpoint rolled back
        ResetNative;$h3=NewFixture @('PoolA','PoolB') @{PoolA='MergeIntoExisting'};$ph3=NewInterruptedState $h3 -Owned @{PoolA=1};AddWaitingChallenge $h3 $ph3;$h3.Projection.PreviewHash=('8'*64);$script:fixture=$h3
        $checkpointBytes=[IO.File]::ReadAllBytes($ph3.State)
        $newH3=Update-WsmWizardTargetRestorePreviewBinding -StateDirectory $pairsDirectory -PairId $h3.Pair -ParentOperationId $h3.Parent -Projection $h3.Projection
        Check ($newH3 -ceq ('8'*64) -and @(ReboundRows $h3.Pair).Count -eq 1 -and [string](StateOf $h3).AssistiveServiceChallenge.PreviewHash -ceq ('8'*64)) 'E3b-4: the explained own-write drift was not rebound by the core function.'
        [IO.File]::WriteAllBytes($ph3.State,$checkpointBytes)
        $rolledBack=Read-WsmJson $ph3.State
        Check ([string]$rolledBack.AssistiveServiceChallenge.PreviewHash -ceq $previewHash -and [string]$rolledBack.RestoreAttempt.WizardPreviewHash -ceq $previewHash) 'E3b-4 replay setup: the rolled back checkpoint should hold the old hash.'
        Restore-WsmJournalCheckpoint $ph3 $rolledBack
        $replayed=StateOf $h3
        Check ([string]$replayed.RestoreAttempt.WizardPreviewHash -ceq ('8'*64) -and [string]$replayed.AssistiveServiceChallenge.PreviewHash -ceq ('8'*64)) 'E3b-4: journal replay did not restore the rebound hash on attempt and challenge.'
        Check ((($replayed.RestoreAttempt.PreviewRowHashes|ForEach-Object {$_.ItemId+'='+$_.Hash}) -join ';') -ceq ((@(Get-WsmAssistivePreviewRowHashes $h3.Projection.Rows)|ForEach-Object {$_.ItemId+'='+$_.Hash}) -join ';')) 'E3b-4: journal replay did not restore the per-row digests.'


        Write-Host ('PASS: TargetRestore continuation core ('+$script:checks+' checks).')
    } $root
} finally {
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92,[char]47);$full=[IO.Path]::GetFullPath($root)
    if([string]::Equals([IO.Path]::GetDirectoryName($full),$temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^wsm-restore-continuation-[0-9a-f]{32}$' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}
}
