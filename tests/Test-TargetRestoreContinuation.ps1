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
            $package=[pscustomobject]@{Root=$root;PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($items)};Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
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
        $packageS=[pscustomobject]@{Root=$root;PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($svcItem)};Manifest=[pscustomobject]@{PairId=$pairS;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
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
            $noInput=Invoke-WsmWizardTargetRestoreResumeFlow $root $pairsDirectory $c1.Package @()
            Check ($noInput.Status -ceq 'InputUnavailable' -and $script:writes -eq 0) 'Unavailable CLI input did not return a recognizable non-success result.'
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

        Write-Host ('PASS: TargetRestore continuation core ('+$script:checks+' checks).')
    } $root
} finally {
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92,[char]47);$full=[IO.Path]::GetFullPath($root)
    if([string]::Equals([IO.Path]::GetDirectoryName($full),$temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^wsm-restore-continuation-[0-9a-f]{32}$' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue}
}
