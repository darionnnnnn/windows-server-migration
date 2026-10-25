#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-journal-replay-'+[Guid]::NewGuid().ToString('N'))
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Refusing to reuse a pre-existing journal replay test directory.'}
[void][IO.Directory]::CreateDirectory($root)
try {
  & $module {
    param($Root,$SrcDir)
    $script:checks=0
    function Check($condition,[string]$message){if(-not $condition){throw $message};$script:checks++}

    # ---- Guard: every Add-WsmJournal action in src must be replayable (or listed with a reason) -------------------------------
    # Actions that are intentionally NOT replayed and therefore fail closed. Each entry needs a reason; an entry whose action is also
    # handled by the replay switch is a stale entry and fails the guard. Currently every writer is replayed, so the list is empty.
    $intentionallyFailClosed=@{}
    $replaySource=Join-Path $SrcDir 'JournalRecovery.ps1'
    $replayAst=[Management.Automation.Language.Parser]::ParseFile($replaySource,[ref]$null,[ref]$null)
    $replayFunction=@($replayAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Restore-WsmJournalCheckpoint'},$true))
    Check ($replayFunction.Count -eq 1) 'Could not locate the single journal replay function.'
    $replaySwitch=@($replayFunction[0].FindAll({param($n)$n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -ceq '$event.Action'},$true))
    Check ($replaySwitch.Count -eq 1) 'Could not locate the single action switch of the journal replay function.'
    $registered=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($clause in $replaySwitch[0].Clauses){foreach($literal in @($clause.Item1.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true))){[void]$registered.Add([string]$literal.Value)};if($clause.Item1 -is [Management.Automation.Language.StringConstantExpressionAst]){[void]$registered.Add([string]$clause.Item1.Value)}}
    $written=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($file in Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1' -File){
      $ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$null)
      $calls=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Add-WsmJournal'},$true))
      foreach($call in $calls){
        $argument=$call.CommandElements[3]
        if($argument -is [Management.Automation.Language.StringConstantExpressionAst]){[void]$written.Add([string]$argument.Value);continue}
        Check ($argument -is [Management.Automation.Language.VariableExpressionAst]) ('Add-WsmJournal action in '+$file.Name+' is neither a literal nor a variable with literal assignments: '+$call.Extent.Text.Substring(0,[Math]::Min(80,$call.Extent.Text.Length)))
        $variableName=$argument.VariablePath.UserPath
        $assigned=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq $variableName},$true))
        $literals=@();foreach($assignment in $assigned){$literals+=@($assignment.Right.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true) | ForEach-Object {[string]$_.Value})}
        Check ($literals.Count -gt 0) ('Add-WsmJournal action variable $'+$variableName+' in '+$file.Name+' has no literal assignment the guard can resolve.')
        foreach($literal in $literals){[void]$written.Add($literal)}
      }
    }
    Check ($written.Count -gt 40) 'The journal action scan found suspiciously few writers; the guard itself is broken.'
    foreach($name in @($intentionallyFailClosed.Keys)){Check (-not [string]::IsNullOrWhiteSpace([string]$intentionallyFailClosed[$name])) ('Fail-closed action '+$name+' has no recorded reason.');Check (-not $registered.Contains($name)) ('Fail-closed action '+$name+' is also replayed; remove the stale entry.')}
    $missing=@($written | Where-Object {-not $registered.Contains($_) -and -not $intentionallyFailClosed.ContainsKey($_)} | Sort-Object)
    Check ($missing.Count -eq 0) ('Journal actions written by src but neither replayed nor listed as fail-closed: '+($missing -join ', '))

    # ---- Fixture helpers -------------------------------------------------------------------------------------------------------
    function ConvertTo-Canon($Value){
      if($null -eq $Value){return 'null'}
      if($Value -is [string]){return ('"'+$Value+'"')}
      if($Value -is [bool]){return $Value.ToString().ToLowerInvariant()}
      if($Value.GetType().IsPrimitive){return [string]$Value}
      if($Value -is [System.Collections.IEnumerable]){return '['+((@($Value | ForEach-Object {ConvertTo-Canon $_})) -join ',')+']'}
      '{'+((@($Value.PSObject.Properties | Where-Object {$_.Name -notmatch 'Utc$'} | Sort-Object Name | ForEach-Object {$_.Name+':'+(ConvertTo-Canon $_.Value)})) -join ',')+'}'
    }
    function Get-Field($Object,[string]$Name){if($Object.PSObject.Properties[$Name]){$Object.$Name}else{'<absent>'}}
    function New-State0([string]$PairId){[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OperationState';BatchId=[Guid]::NewGuid().ToString();PairId=$PairId;TargetFingerprint=('b'*64);PlanHash=('c'*64);RunId=[Guid]::NewGuid().ToString();ManifestHash='';Generation=0;Stage='NotStarted';Sequence=[long]0;ResultSequence=[long]0;JournalHash=('0'*64);JournalSegment=0;Items=@();Evidence=@();Cutover=$null;PendingOperations=@()}}
    $mh=('d'*64);$ph=('a'*64)
    function New-Attempt([string]$Op,[string]$Status){[pscustomobject][ordered]@{ManifestHash=$mh;Generation=[long]3;PreviousManifest='';OperationId=$Op;DecisionReceiptPath='r.json';DecisionReceiptHash=('e'*64);TargetSnapshotPath='s.json';TargetSnapshotHash=('f'*64);SelectedItemIds=@('i1','i2');WizardPreviewHash=$ph;MaterialJobOperationId='';MaterialIds=@();ItemResults=@([pscustomobject]@{ItemId='i0';Status='Succeeded'});PreviewRowHashes=@([pscustomobject]@{ItemId='i1';Hash=('1'*64)});Status=$Status;CreatedUtc='2026-01-01T00:00:00Z'}}
    function New-Requirement([string]$Ref){[pscustomobject][ordered]@{SecretRef=$Ref;Kinds=@('Service');ItemIds=@('i1');DisplayNames=@('svc '+$Ref);ApprovedAccount='DOM\svc';Deferred=$false;DeferReason='';LastFailure='';Attempts=0}}
    function New-Challenge([string]$Pair,[string]$Op,[string]$State){[pscustomobject][ordered]@{State=$State;ParentOperationId=$Op;PairId=$Pair;Role='Target';Actor='alice';SessionId='s1';ContextId='c1';Revision=[int]1;ManifestHash=$mh;Generation=[long]3;PreviewHash=$ph;RequiredSecretRefs=@('ref-a','ref-b');Requirements=@((New-Requirement 'ref-a'),(New-Requirement 'ref-b'));ServiceReservations=@();CreatedUtc='2026-01-01T00:00:00Z';UpdatedUtc='2026-01-01T00:00:00Z'}}
    function New-Context([string]$Name){$pair=[Guid]::NewGuid().ToString();$directory=Join-Path $Root $Name;$paths=Get-WsmOperationPaths $directory $pair;[pscustomobject]@{Pair=$pair;Dir=$directory;Paths=$paths;Op=[Guid]::NewGuid().ToString();State=$null}}
    $fakePackage=[pscustomobject]@{SHA256=$mh;Manifest=[pscustomobject]@{Generation=3;PairId='';PlanHash=('c'*64);Target=[pscustomobject]@{Fingerprint=('b'*64)}}}
    $sentinel='J1-SYNTHETIC-SECRET-'+[Guid]::NewGuid().ToString('N')
    $script:replayed=New-Object 'System.Collections.Generic.List[string]'
    # One scenario: seed a durable checkpoint, let the real/mimicked writer append exactly one event (journal then state), then roll the
    # state back to the seeded checkpoint and replay. The replayed fields must equal the directly written ones.
    function Invoke-ReplayScenario([string]$Name,[scriptblock]$Seed,[scriptblock]$Run,[string[]]$Fields,[switch]$NoStateChange){
      $c=New-Context $Name;$state0=New-State0 $c.Pair;& $Seed $state0 $c
      Write-WsmJson $c.Paths.State $state0;$seedText=[IO.File]::ReadAllText($c.Paths.State)
      $c.State=Read-WsmJson $c.Paths.State
      & $Run $c
      $direct=Read-WsmJson $c.Paths.State
      Check ($direct.Sequence -eq 1) ($Name+': the writer did not append exactly one journal event.')
      [IO.File]::WriteAllText($c.Paths.State,$seedText,(New-Object Text.UTF8Encoding($false)))
      $stale=Read-WsmJson $c.Paths.State
      Restore-WsmJournalCheckpoint $c.Paths $stale
      $replayedState=Read-WsmJson $c.Paths.State
      Check ($replayedState.Sequence -eq 1 -and $replayedState.JournalHash -ceq $direct.JournalHash) ($Name+': replay did not land on the same journal checkpoint.')
      $changed=$false
      foreach($field in $Fields){
        $expectedText=ConvertTo-Canon (Get-Field $direct $field);$actualText=ConvertTo-Canon (Get-Field $replayedState $field);$seedField=ConvertTo-Canon (Get-Field (ConvertFrom-WsmJson $seedText) $field)
        Check ($expectedText -ceq $actualText) ($Name+': replayed field '+$field+' differs from the directly written state.'+[Environment]::NewLine+'expected='+$expectedText+[Environment]::NewLine+'actual='+$actualText)
        if($expectedText -cne $seedField){$changed=$true}
        Check (-not $expectedText.Contains($sentinel) -and -not $actualText.Contains($sentinel)) ($Name+': a synthetic secret reached durable state.')
      }
      if($NoStateChange){Check (-not $changed) ($Name+': a no-op action changed the compared fields; it needs a real handler.')}else{Check $changed ($Name+': the scenario never changed any compared field, so it proves nothing.')}
      Check (-not [IO.File]::ReadAllText($c.Paths.Journal).Contains($sentinel)) ($Name+': a synthetic secret reached the journal.')
      $script:replayed.Add($Name)
    }
    $challengeFields=@('Stage','ManifestHash','Generation','RestoreAttempt','AssistiveServiceChallenge')

    # ---- Service credential challenge group ------------------------------------------------------------------------------------
    Invoke-ReplayScenario 'challenge-waiting-new' {param($s,$c)} {
      param($c)$s=$c.State;$attempt=New-Attempt $c.Op 'WaitingForInput';$challenge=New-Challenge $c.Pair $c.Op 'WaitingForInput'
      $s.ManifestHash=$mh;$s.Generation=[long]3;$s.Stage='WaitingForInput';$s|Add-Member NoteProperty RestoreAttempt $attempt -Force;$s|Add-Member NoteProperty AssistiveServiceChallenge $challenge -Force
      $detail=ConvertFrom-WsmJson ($challenge | ConvertTo-Json -Depth 40);$detail | Add-Member NoteProperty RestoreAttempt $s.RestoreAttempt -Force
      Add-WsmJournal $c.Paths $s 'AssistiveServiceCredentialChallengeWaiting' '' $detail
    } $challengeFields
    Invoke-ReplayScenario 'challenge-waiting-legacy-row-keeps-durable-attempt' {param($s,$c)$s|Add-Member NoteProperty RestoreAttempt (New-Attempt $c.Op 'Running') -Force} {
      param($c)$s=$c.State;$challenge=New-Challenge $c.Pair $c.Op 'WaitingForInput'
      $s.ManifestHash=$mh;$s.Generation=[long]3;$s.Stage='WaitingForInput';$s|Add-Member NoteProperty AssistiveServiceChallenge $challenge -Force
      Add-WsmJournal $c.Paths $s 'AssistiveServiceCredentialChallengeWaiting' '' $challenge
    } @('Stage','ManifestHash','Generation','AssistiveServiceChallenge')
    Invoke-ReplayScenario 'challenge-resuming' {param($s,$c)$s|Add-Member NoteProperty RestoreAttempt (New-Attempt $c.Op 'WaitingForInput') -Force;$s|Add-Member NoteProperty AssistiveServiceChallenge (New-Challenge $c.Pair $c.Op 'WaitingForInput') -Force} {
      param($c)$s=$c.State;$s.AssistiveServiceChallenge.State='Running';$s.AssistiveServiceChallenge.UpdatedUtc=Get-WsmUtc
      Add-WsmJournal $c.Paths $s 'AssistiveServiceCredentialChallengeResuming' '' $s.AssistiveServiceChallenge
    } @('AssistiveServiceChallenge')
    $waitingSeed={param($s,$c)$s.Stage='WaitingForInput';$s|Add-Member NoteProperty RestoreAttempt (New-Attempt $c.Op 'WaitingForInput') -Force;$s|Add-Member NoteProperty AssistiveServiceChallenge (New-Challenge $c.Pair $c.Op 'WaitingForInput') -Force}
    Invoke-ReplayScenario 'challenge-cancelled' $waitingSeed {param($c)[void](Cancel-WsmAssistiveServiceCredentialChallenge $c.Dir $c.Pair $c.Op $ph)} $challengeFields
    Invoke-ReplayScenario 'challenge-deferred' $waitingSeed {param($c)[void](Set-WsmAssistiveCredentialDeferral -StateDirectory $c.Dir -PairId $c.Pair -ParentOperationId $c.Op -PreviewHash $ph -SecretRefs @('ref-a'))} $challengeFields
    Invoke-ReplayScenario 'challenge-taken-over-waiting' $waitingSeed {param($c)[void](Takeover-WsmAssistiveServiceCredentialChallenge $c.Dir $c.Pair $c.Op $ph 'bob' 's2' 'c2' 1 -ConfirmTakeover)} $challengeFields
    $runningSeed={param($s,$c)$s.Stage='Running';$s|Add-Member NoteProperty RestoreAttempt (New-Attempt $c.Op 'Running') -Force;$s|Add-Member NoteProperty AssistiveServiceChallenge (New-Challenge $c.Pair $c.Op 'Running') -Force}
    $preWrite=[pscustomobject]@{Proven=$true;Services=@('svc-a')}
    Invoke-ReplayScenario 'challenge-taken-over-from-running' $runningSeed {
      param($c)$s=$c.State;$attempt=$s.RestoreAttempt;$challenge=$s.AssistiveServiceChallenge
      $s.Stage='WaitingForInput';$attempt.Status='WaitingForInput';$attempt|Add-Member NoteProperty LastPreWriteRecovery $preWrite -Force;$challenge.State='WaitingForInput';$challenge|Add-Member NoteProperty LastPreWriteRecovery $preWrite -Force
      $challenge.Actor='bob';$challenge.SessionId='s2';$challenge.ContextId='c2';$challenge|Add-Member NoteProperty TakeoverCount 1 -Force;$challenge|Add-Member NoteProperty LastTakeoverUtc (Get-WsmUtc) -Force
      Add-WsmJournal $c.Paths $s 'AssistiveServiceCredentialChallengeTakenOver' '' ([pscustomobject]@{ParentOperationId=$c.Op;PairId=$c.Pair;PreviewHash=$ph;Actor='bob';SessionId='s2';ContextId='c2';Revision=1;TakeoverCount=1;PreWriteRecovery=$preWrite})
    } $challengeFields
    Invoke-ReplayScenario 'challenge-rebound' $runningSeed {
      param($c)$s=$c.State;$attempt=$s.RestoreAttempt;$challenge=$s.AssistiveServiceChallenge
      $challenge.State='WaitingForInput';$challenge.Actor='bob';$challenge.Role='Target';$challenge.SessionId='s3';$challenge.ContextId='c3';$challenge.Revision=[int]2;$challenge.UpdatedUtc=Get-WsmUtc;$challenge|Add-Member NoteProperty LastPreWriteRecovery $preWrite -Force
      $attempt|Add-Member NoteProperty Status 'WaitingForInput' -Force;$s.Stage='WaitingForInput'
      Add-WsmJournal $c.Paths $s 'AssistiveServiceCredentialChallengeRebound' '' ([pscustomobject]@{ParentOperationId=$c.Op;ContinuationId='cont-1';Actor='bob';SessionId='s3';ContextId='c3';Revision=[int]2;PreWriteRecovery=$preWrite})
    } $challengeFields

    # Rejected / Reprompt / RejectedLimit: the writer's challenge and attempt are journaled as exact non-secret snapshots.
    function Set-RejectedState($s,$c,[bool]$limit){
      $challenge=$s.AssistiveServiceChallenge;$attempt=$s.RestoreAttempt
      $challenge.Requirements[0].LastFailure='CredentialRejected';$challenge.Requirements[0].Attempts=1;$challenge|Add-Member NoteProperty DeferredSecretRefs @() -Force
      if($limit){$challenge.Requirements[0].Deferred=$true;$challenge.Requirements[0].DeferReason='CredentialRejectedLimit';$challenge|Add-Member NoteProperty DeferredSecretRefs @('ref-a') -Force}
      $challenge.UpdatedUtc=Get-WsmUtc
    }
    Invoke-ReplayScenario 'challenge-rejected-limit' $runningSeed {
      param($c)$s=$c.State;Set-RejectedState $s $c $true
      Add-WsmJournal $c.Paths $s 'AssistiveServiceCredentialRejectedLimit' '' ([pscustomobject]@{ParentOperationId=$c.Op;SecretRefs=@('ref-a');MaxAttempts=3;Reason='CredentialRejectedLimit';ChallengeSnapshot=$s.AssistiveServiceChallenge})
    } @('AssistiveServiceChallenge')
    foreach($waitingAction in @('AssistiveServiceCredentialRejected','AssistiveServiceCredentialReprompt')){
      $actionName=$waitingAction
      Invoke-ReplayScenario ('challenge-'+$actionName) $runningSeed {
        param($c)$s=$c.State;Set-RejectedState $s $c $false
        $s.AssistiveServiceChallenge.RequiredSecretRefs=@('ref-a');$s.AssistiveServiceChallenge.State='WaitingForInput'
        $s.RestoreAttempt|Add-Member NoteProperty ItemResults @([pscustomobject]@{ItemId='i0';Status='Succeeded'},[pscustomobject]@{ItemId='i1';Status='CredentialRejected'}) -Force;$s.RestoreAttempt|Add-Member NoteProperty Status 'WaitingForInput' -Force
        $s.ManifestHash=$mh;$s.Generation=[long]3;$s.Stage='WaitingForInput'
        Add-WsmJournal $c.Paths $s $actionName '' ([pscustomobject]@{ParentOperationId=$c.Op;PairId=$c.Pair;PreviewHash=$ph;Rejections=@([pscustomobject]@{SecretRef='ref-a';Attempts=1;MaxAttempts=3;Deferred=$false});RequiredSecretRefs=@('ref-a');ChallengeSnapshot=$s.AssistiveServiceChallenge;RestoreAttempt=$s.RestoreAttempt})
      } $challengeFields
    }
    Invoke-ReplayScenario 'item-credential-rejected' {param($s,$c)$s.PendingOperations=@([pscustomobject]@{ItemId='i1';Phase='AssistiveAdapterCreating'},[pscustomobject]@{ItemId='i2';Phase='AssistiveAdapterCreating'})} {
      param($c)$s=$c.State;$s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE 'i1')
      Add-WsmJournal $c.Paths $s 'AssistiveItemCredentialRejected' 'i1' ([pscustomobject]@{ItemId='i1';SecretRef='ref-a';Adapter='Service'})
    } @('PendingOperations')
    Invoke-ReplayScenario 'restore-cancelled' $runningSeed {
      param($c)$s=$c.State;$s.Stage='Cancelled';$s.ManifestHash=$mh;$s.Generation=[long]3
      $results=@([pscustomobject]@{ItemId='i0';Status='Succeeded'},[pscustomobject]@{ItemId='i1';Status='NeedsReconciliation'});$s.RestoreAttempt.ItemResults=$results;$s.AssistiveServiceChallenge.State='Cancelled';$s.AssistiveServiceChallenge.UpdatedUtc=Get-WsmUtc
      $cancel=[ordered]@{Status='Cancelled';ManifestHash=$mh;Generation=[long]3;OperationId='';Boundary='AssistiveBeforeItem';PendingOperationCount=0};$cancel['ItemResults']=@($results)
      Add-WsmJournal $c.Paths $s 'AssistiveRestoreCancelled' '' ([pscustomobject]$cancel)
    } $challengeFields

    # ---- Parent / continuation group (real writers) ------------------------------------------------------------------------------
    Invoke-ReplayScenario 'parent-superseded' $waitingSeed {param($c)Revoke-WsmWizardTargetRestoreParent -StateDirectory $c.Dir -PairId $c.Pair -ParentOperationId $c.Op -Reason 'PreviewChanged'} $challengeFields
    Invoke-ReplayScenario 'parent-cancelled' $waitingSeed {param($c)[void](Stop-WsmWizardTargetRestoreParent -StateDirectory $c.Dir -PairId $c.Pair -ParentOperationId $c.Op)} $challengeFields
    Invoke-ReplayScenario 'continuation-superseded' $waitingSeed {param($c)Revoke-WsmWizardTargetRestoreParent -StateDirectory $c.Dir -PairId $c.Pair -ParentOperationId $c.Op -Reason 'PreviewChanged' -ContinuationId 'cont-9' -ContinuationResult ([pscustomobject]@{Status='NeedsNewPreview';ParentOperationId=$c.Op}) -Actor 'bob' -SessionId 's9'} $challengeFields
    Invoke-ReplayScenario 'continuation-started' $waitingSeed {
      param($c)$s=$c.State;$attempt=$s.RestoreAttempt
      $attempt|Add-Member NoteProperty Continuations @([pscustomobject][ordered]@{ContinuationId='cont-1';StartedUtc=(Get-WsmUtc);Actor='bob';SessionId='s2';Result=$null}) -Force
      Add-WsmJournal $c.Paths $s 'AssistiveRestoreContinuation' '' ([pscustomobject]@{ParentOperationId=$c.Op;ContinuationId='cont-1';Actor='bob';SessionId='s2';Phase='Started'})
    } @('RestoreAttempt')
    $startedSeed={param($s,$c)$s.Stage='WaitingForInput';$attempt=New-Attempt $c.Op 'WaitingForInput';$attempt|Add-Member NoteProperty Continuations @([pscustomobject][ordered]@{ContinuationId='cont-1';StartedUtc='2026-01-01T00:00:00Z';Actor='bob';SessionId='s2';Result=$null}) -Force;$s|Add-Member NoteProperty RestoreAttempt $attempt -Force}
    $completedPackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId='';PlanHash=('c'*64);Target=[pscustomobject]@{Fingerprint=('b'*64)}}}
    Invoke-ReplayScenario 'continuation-completed' $startedSeed {
      param($c)$completedPackage.Manifest.PairId=$c.Pair
      Set-WsmWizardContinuationResult $c.Paths $completedPackage $c.Op 'cont-1' ([pscustomobject]@{Status='Succeeded';Items=@('i1')})
    } @('RestoreAttempt')

    # ---- Per-item, import and rollback evidence -------------------------------------------------------------------------------
    # The rollback writers (Recovery.ps1) mark the item RolledBack and clear CreatedByTool/UpdatedByTool; replay must do the same so a later restore never treats a rolled-back object as tool-owned.
    Invoke-ReplayScenario 'rollback-completed-clears-ownership' {param($s,$c)$s.Items=@([pscustomobject]@{ItemId='r1';Status='Succeeded';CreatedByTool=$true;UpdatedByTool=$true;AppliedManifestHash=('a'*64)});$s.PendingOperations=@([pscustomobject]@{ItemId='r1';Phase='RollbackIntent'})} {
      param($c)$s=$c.State;$record=@($s.Items|Where-Object ItemId -CEQ 'r1');$record[0].Status='RolledBack';$record[0].CreatedByTool=$false;$record[0]|Add-Member NoteProperty UpdatedByTool $false -Force;$s.PendingOperations=@($s.PendingOperations|Where-Object ItemId -CNE 'r1')
      Add-WsmJournal $c.Paths $s 'RollbackCompleted' 'r1' ([pscustomobject]@{Status='RolledBack'})
    } @('Items','PendingOperations')
    # R2: a rollback releases the ownership it undid (AssistiveRollbackOwnershipReleased). Live writer and replay call the same Remove-WsmAssistiveRolledBackOwnership; rows outside the rollback vector (AdoptedExisting) stay.
    $ownedA=[pscustomobject]@{RelativePath='a.txt';TargetPath='D:\data\a.txt';SHA256=('1'*64);MetadataHash=('3'*64);Backup='';BackupHash='';Generation=[long]1}
    $ownedAdopted=[pscustomobject]@{RelativePath='keep.txt';TargetPath='D:\data\keep.txt';SHA256=('2'*64);MetadataHash=('4'*64);Backup='';BackupHash='';Generation=[long]1;Ownership='AdoptedExisting'}
    $ownedDirectory=[pscustomobject]@{RelativePath='';TargetPath='D:\data';MetadataHash=('5'*64);CreatedByTool=$true;Generation=[long]1}
    Invoke-ReplayScenario 'rollback-ownership-released-keeps-adopted' {param($s,$c)$s.Stage='RollbackRunning';$s.Items=@([pscustomobject]@{ItemId='r2';Status='Succeeded';CreatedByTool=$true;ActualHash=('9'*64);OwnedFiles=@($ownedA,$ownedAdopted);OwnedDirectories=@($ownedDirectory)});$s.PendingOperations=@([pscustomobject]@{ItemId='r2';Phase='RollbackAssistiveFiles'})} {
      param($c)$s=$c.State;Remove-WsmAssistiveRolledBackOwnership $s 'r2' ([string[]]@('a.txt'))
      Add-WsmJournal $c.Paths $s 'AssistiveRollbackOwnershipReleased' 'r2' ([pscustomobject]@{ItemId='r2';ReleasedFiles=[string[]]@('a.txt');ReleasedDirectories=[string[]]@('')})
    } @('Items','PendingOperations')
    $releasedProbe=[pscustomobject]@{Items=@([pscustomobject]@{ItemId='r2';Status='Succeeded';CreatedByTool=$true;ActualHash=('9'*64);OwnedFiles=@($ownedA,$ownedAdopted);OwnedDirectories=@($ownedDirectory)},[pscustomobject]@{ItemId='other';Status='Succeeded';CreatedByTool=$true;OwnedFiles=@($ownedA);OwnedDirectories=@($ownedDirectory)})}
    Remove-WsmAssistiveRolledBackOwnership $releasedProbe 'r2' ([string[]]@('a.txt'))
    $probeRow=@($releasedProbe.Items|Where-Object ItemId -CEQ 'r2')[0];$otherRow=@($releasedProbe.Items|Where-Object ItemId -CEQ 'other')[0]
    Check (@($probeRow.OwnedFiles).Count -eq 1 -and $probeRow.OwnedFiles[0].RelativePath -ceq 'keep.txt' -and $probeRow.OwnedFiles[0].Ownership -ceq 'AdoptedExisting' -and @($probeRow.OwnedDirectories).Count -eq 0 -and $probeRow.ActualHash -ceq (Get-WsmAssistiveFileOwnershipHash @($ownedAdopted))) 'rollback-ownership-released: the helper must drop only the rolled-back file, keep the adopted row, clear directories and recompute ActualHash.'
    Check (@($otherRow.OwnedFiles).Count -eq 1 -and @($otherRow.OwnedDirectories).Count -eq 1) 'rollback-ownership-released: the helper touched another item.'
    $ownedSingle=[pscustomobject]@{RelativePath='';TargetPath='D:\data\one.bin';SHA256=('6'*64);MetadataHash=('7'*64);Backup='';BackupHash='';Generation=[long]1}
    Invoke-ReplayScenario 'rollback-ownership-released-single-file-scope' {param($s,$c)$s.Stage='RollbackRunning';$s.Items=@([pscustomobject]@{ItemId='r3';Status='Succeeded';CreatedByTool=$true;OwnedFiles=@($ownedSingle);OwnedDirectories=@()});$s.PendingOperations=@([pscustomobject]@{ItemId='r3';Phase='RollbackAssistiveFiles'})} {
      param($c)$s=$c.State;Remove-WsmAssistiveRolledBackOwnership $s 'r3' ([string[]]@(''))
      Add-WsmJournal $c.Paths $s 'AssistiveRollbackOwnershipReleased' 'r3' ([pscustomobject]@{ItemId='r3';ReleasedFiles=[string[]]@('');ReleasedDirectories=[string[]]@()})
    } @('Items','PendingOperations')
    # Q6a2: the writer journals a pre-move record (AssistiveFilePrepared carrying PreMoveStagingHash) before it moves a staging file onto a target it does not own yet. Replay replaces the pending intent with the whole detail, so the evidence survives a checkpoint rollback;
    # an old journal (intent only) replays to a pending row without the field, which Repair treats as no evidence (AdoptedExisting, never tool-owned).
    $premoveIntent=[pscustomobject][ordered]@{ItemId='q1';Phase='AssistiveFileReplace';ManifestHash=$mh;Generation=[long]3;RelativePath='a.ini';Target='D:\data.ini';Staging='D:\data.ini.wsm-0123456789abcdef0123456789abcdef.tmp';Backup='';PreviousHash='';PreviousMetadataHash='';PreviousMetadata=$null;ExpectedHash=('1'*64);ExpectedMetadata=[pscustomobject]@{MetadataMode='DaclOwner'};WasOwned=$false;PriorOwner=$null}
    Invoke-ReplayScenario 'file-prepared-premove-evidence-nonowner' {param($s,$c)$s.PendingOperations=@($premoveIntent)} {
      param($c)$s=$c.State;$pending=$s.PendingOperations[0];$pending|Add-Member NoteProperty PreMoveStagingHash ('1'*64) -Force
      Add-WsmJournal $c.Paths $s 'AssistiveFilePrepared' 'q1' $pending
    } @('PendingOperations')
    Invoke-ReplayScenario 'noncfile-results-imported' {param($s,$c)} {
      param($c)$s=$c.State;$rows=@([pscustomobject]@{ItemId='n1';Status='Applied';EffectivePath='D:\data';Generation=3})
      $s|Add-Member NoteProperty AssistiveFileResults @($rows) -Force
      Add-WsmJournal $c.Paths $s 'AssistiveNonCFileResultsImported' '' ([pscustomobject]@{Generation=[long]3;Rows=@($rows)})
    } @('AssistiveFileResults')
    $itemResult=[pscustomobject]@{ItemId='i1';Status='NeedsReconciliation';CreatedByTool=$false;AppliedManifestHash='';AppliedGeneration=0;Error='unknown';NativeCode=$null}
    foreach($noOpAction in @('AssistiveItemNeedsReconciliation','AssistiveItemBlockedByUnknownDependency','AssistiveItemCredentialDeferred')){
      $actionName=$noOpAction
      Invoke-ReplayScenario ('no-state-'+$actionName) $runningSeed {param($c)Add-WsmJournal $c.Paths $c.State $actionName 'i1' $itemResult} @('Stage','Items','PendingOperations','RestoreAttempt','AssistiveServiceChallenge') -NoStateChange
    }
    $rollbackActions=@('AssistiveRollbackFileDisplaced','AssistiveRollbackFileRestored','AssistiveRollbackNewFileRetained','AssistiveRollbackDirectoryAbsent','AssistiveRollbackDirectoryRemoved','AssistiveRollbackDirectoryRetainedExternalContent','AssistiveRollbackDirectoryMetadataRestored')
    foreach($rollbackAction in $rollbackActions){
      $actionName=$rollbackAction
      Invoke-ReplayScenario ('rollback-'+$actionName) {param($s,$c)$s.Stage='RollbackRunning';$s.Items=@([pscustomobject]@{ItemId='i1';Status='Succeeded';CreatedByTool=$true});$s.PendingOperations=@([pscustomobject]@{ItemId='i1';Phase='RollbackAdapter'})} {param($c)Add-WsmJournal $c.Paths $c.State $actionName 'i1' ([pscustomobject]@{Target='D:\data\a.txt'})} @('Stage','Items','PendingOperations') -NoStateChange
    }

    # ---- Partial ownership (E3b-3) ---------------------------------------------------------------------------------------------
    $fileRecord=[pscustomobject]@{RelativePath='sub\a.txt';TargetPath='D:\data\sub\a.txt';SHA256=('1'*64);MetadataHash=('2'*64);Backup='';BackupHash='';BackupMetadata=$null;BackupMetadataHash='';BackupMaterialId='';Generation=[long]3}
    $fileItem=[pscustomobject]@{ItemId='i1'}
    $fileSeed={param($s,$c)$s.Stage='Running';$s|Add-Member NoteProperty RestoreAttempt (New-Attempt $c.Op 'Running') -Force;$s.PendingOperations=@([pscustomobject]@{ItemId='i1';Phase='AssistiveFileReplace';Target='D:\data\sub\a.txt'})}
    Invoke-ReplayScenario 'file-completed-partial-ownership' $fileSeed {
      param($c)$s=$c.State;$s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE 'i1')
      Set-WsmAssistivePartialOwnership $s $fileItem $fakePackage 'File' $fileRecord
      $record=[pscustomobject]@{ItemId='i1';Status='Partial';CreatedByTool=$true;AppliedManifestHash='';AppliedGeneration=0;OwnedFiles=@($fileRecord);OwnedDirectories=@();Target='';Error='One file transaction completed; the full scope still requires reconciliation.'}
      $s.Items=@($record)
      Add-WsmJournal $c.Paths $s 'AssistiveFileCompleted' 'i1' ([pscustomobject]@{ItemId='i1';Record=$fileRecord;Target='D:\data\sub\a.txt'})
    } @('Items','PendingOperations','AssistivePartialOwnership')
    $ownedSeed={param($s,$c)$s.Stage='Running';$attempt=New-Attempt $c.Op 'Running';$s|Add-Member NoteProperty RestoreAttempt $attempt -Force;Set-WsmAssistivePartialOwnership $s $fileItem $fakePackage 'File' $fileRecord;Set-WsmAssistivePartialOwnership $s ([pscustomobject]@{ItemId='i2'}) $fakePackage 'File' $fileRecord;$s.PendingOperations=@([pscustomobject]@{ItemId='i1';Phase='AssistiveFileReplace'})}
    Invoke-ReplayScenario 'item-completed-clears-partial-ownership' $ownedSeed {
      param($c)$s=$c.State;$result=[pscustomobject]@{ItemId='i1';Status='Succeeded';CreatedByTool=$true;AppliedManifestHash=$mh;AppliedGeneration=[long]3}
      $s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE 'i1');Clear-WsmAssistivePartialOwnership $s 'i1';$s.Items=@($s.Items | Where-Object ItemId -CNE 'i1')+@($result)
      Add-WsmJournal $c.Paths $s 'AssistiveItemCompleted' 'i1' $result
    } @('Items','PendingOperations','AssistivePartialOwnership')

    # ---- SettingTransition group -----------------------------------------------------------------------------------------------
    $transition=[pscustomobject][ordered]@{TransitionHash=('7'*64);Action='UpdateReviewed';Adapter='RegistryValue';RequiredPhase='StagedDependencyVerified';After=[pscustomobject]@{Value='new'}}
    $intent=[pscustomobject][ordered]@{SchemaVersion=1;Kind='SettingTransitionIntent';IntentId=[Guid]::NewGuid().ToString();TransitionHash=$transition.TransitionHash;Prior=[pscustomobject]@{Value='old'}}
    $receiptBase=[pscustomobject][ordered]@{Kind='SettingTransitionReceipt';Status='Applied';Action='UpdateReviewed';TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId;CreatedByTool=$false;UpdatedByTool=$true;Before=$intent.Prior;After=$transition.After;ReceiptHash=('8'*64)}
    Invoke-ReplayScenario 'setting-transition-intent' {param($s,$c)$s.Stage='Running'} {
      param($c)$s=$c.State
      $pending=[pscustomobject]@{ItemId='s1';Phase='SettingTransition';ManifestHash=$mh;TransitionHash=$transition.TransitionHash;Transition=$transition;Intent=$null;Receipt=$null;AppliedPhase='StagedDependencyVerified';RequiredPhase=$transition.RequiredPhase}
      $s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE 's1')+@($pending);$pending.Intent=$intent
      Add-WsmJournal $c.Paths $s 'SettingTransitionIntent' 's1' ([pscustomobject]@{ManifestHash=$mh;TransitionHash=$transition.TransitionHash;Intent=$intent;Transition=$transition;AppliedPhase='StagedDependencyVerified';RequiredPhase=$transition.RequiredPhase})
    } @('PendingOperations')
    $transitionPending={param($s,$c)$s.Stage='Running';$s.PendingOperations=@([pscustomobject]@{ItemId='s1';Phase='SettingTransition';ManifestHash=$mh;TransitionHash=$transition.TransitionHash;Transition=$transition;Intent=$intent;Receipt=$null;AppliedPhase='StagedDependencyVerified';RequiredPhase=$transition.RequiredPhase})}
    Invoke-ReplayScenario 'setting-transition-receipt' $transitionPending {
      param($c)$s=$c.State;$s.PendingOperations[0].Receipt=$receiptBase
      Add-WsmJournal $c.Paths $s 'SettingTransitionReceipt' 's1' ([pscustomobject]@{ManifestHash=$mh;TransitionHash=$transition.TransitionHash;Receipt=$receiptBase;AppliedPhase='StagedDependencyVerified';RequiredPhase=$transition.RequiredPhase})
    } @('PendingOperations')
    $receiptSeed={param($s,$c)$s.Stage='Running';$s.Items=@([pscustomobject]@{ItemId='s1';Status='Prepared'});$s.PendingOperations=@([pscustomobject]@{ItemId='s1';Phase='SettingTransition';ManifestHash=$mh;TransitionHash=$transition.TransitionHash;Transition=$transition;Intent=$intent;Receipt=$receiptBase;AppliedPhase='StagedDependencyVerified';RequiredPhase=$transition.RequiredPhase})}
    foreach($withHash in @($true,$false)){
      $includeHash=$withHash
      Invoke-ReplayScenario ('setting-transition-recovered-actualhash-'+$withHash) $receiptSeed {
        param($c)$s=$c.State;$operation=$s.PendingOperations[0];$receipt=ConvertFrom-WsmJson ($operation.Receipt | ConvertTo-Json -Depth 20);$receipt | Add-Member NoteProperty Intent $operation.Intent -Force
        $result=[pscustomobject]@{ItemId='s1';Status='Succeeded';CreatedByTool=($transition.Action -eq 'CreateNew');UpdatedByTool=($transition.Action -eq 'UpdateReviewed');ActualHash=(Get-WsmHashText ($receipt | ConvertTo-Json -Depth 20 -Compress));Backup='';Target='';Error='';NativeCode=0;SettingTransitionDeferred=$false;SettingTransitionIntent=$operation.Intent;SettingTransitionReceipt=$receipt}
        $s.Items=@($s.Items | Where-Object ItemId -CNE 's1')+@($result);$s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE 's1')
        $detail=[pscustomobject]@{TransitionHash=$transition.TransitionHash;IntentId=$operation.Intent.IntentId;Receipt=$receipt};if($includeHash){$detail|Add-Member NoteProperty ActualHash $result.ActualHash}
        Add-WsmJournal $c.Paths $s 'SettingTransitionRecovered' 's1' $detail
      } @('Items','PendingOperations')
    }
    $rollbackIntent=[pscustomobject]@{TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId;TargetFingerprint=('b'*64);ExpectedCurrent=$transition.After;RestorePrior=$intent.Prior;ReceiptHash=$receiptBase.ReceiptHash;ManifestHash=$mh}
    $rollbackSeed={param($s,$c)$s.Stage='RollbackRunning';$s.PendingOperations=@([pscustomobject]@{ItemId='s1';Phase='RollbackAdapter';ManifestHash=$mh;TransitionHash=$transition.TransitionHash;SettingTransitionIntent=$intent;SettingTransitionReceipt=$receiptBase;SettingTransitionRollbackIntent=$null})}
    Invoke-ReplayScenario 'setting-transition-rollback-intent' $rollbackSeed {
      param($c)$s=$c.State;$s.PendingOperations[0].SettingTransitionRollbackIntent=$rollbackIntent
      Add-WsmJournal $c.Paths $s 'SettingTransitionRollbackIntent' 's1' $rollbackIntent
    } @('PendingOperations')
    $rollbackReceipt=[pscustomobject]@{Kind='SettingTransitionRollbackReceipt';Status='RestoredPriorValue';TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId;Restored=$intent.Prior}
    $rollbackSeed2={param($s,$c)$s.Stage='RollbackRunning';$s.PendingOperations=@([pscustomobject]@{ItemId='s1';Phase='RollbackAdapter';ManifestHash=$mh;TransitionHash=$transition.TransitionHash;SettingTransitionIntent=$intent;SettingTransitionReceipt=$receiptBase;SettingTransitionRollbackIntent=$rollbackIntent})}
    Invoke-ReplayScenario 'setting-transition-rollback-receipt' $rollbackSeed2 {
      param($c)$s=$c.State;$s.PendingOperations[0]|Add-Member NoteProperty SettingTransitionRollbackReceipt $rollbackReceipt -Force
      Add-WsmJournal $c.Paths $s 'SettingTransitionRollbackReceipt' 's1' ([pscustomobject]@{Receipt=$rollbackReceipt;TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId})
    } @('PendingOperations')
    Invoke-ReplayScenario 'setting-transition-rollback-receipt-exact-prior' $rollbackSeed2 {
      param($c)Add-WsmJournal $c.Paths $c.State 'SettingTransitionRollbackReceipt' 's1' ([pscustomobject]@{Receipt=$rollbackReceipt;Recovery='ExactPriorReadback'})
    } @('PendingOperations') -NoStateChange

    # ---- Fail-closed messages name the action and reason instead of failing silently -------------------------------------------
    function Test-ReplayThrows([string]$Name,[scriptblock]$Seed,[string]$Action,[string]$ItemId,$Detail,[string]$Pattern){
      $c=New-Context $Name;$state0=New-State0 $c.Pair;& $Seed $state0 $c;Write-WsmJson $c.Paths.State $state0;$seedText=[IO.File]::ReadAllText($c.Paths.State);$c.State=Read-WsmJson $c.Paths.State
      Add-WsmJournal $c.Paths $c.State $Action $ItemId $Detail
      [IO.File]::WriteAllText($c.Paths.State,$seedText,(New-Object Text.UTF8Encoding($false)))
      $stale=Read-WsmJson $c.Paths.State;$message='';try{Restore-WsmJournalCheckpoint $c.Paths $stale}catch{$message=$_.Exception.Message}
      Check ($message -match $Pattern) ($Name+': expected a specific fail-closed message but got: '+$message)
    }
    Test-ReplayThrows 'limit-row-without-snapshot' $runningSeed 'AssistiveServiceCredentialRejectedLimit' '' ([pscustomobject]@{ParentOperationId='x';SecretRefs=@('ref-a')}) 'AssistiveServiceCredentialRejectedLimit lacks the durable challenge'
    Test-ReplayThrows 'deferred-without-challenge' {param($s,$c)} 'AssistiveServiceCredentialDeferred' '' ([pscustomobject]@{SecretRefs=@('ref-a');RemainingSecretRefs=@()}) 'AssistiveServiceCredentialDeferred found no durable Service credential challenge'
    Test-ReplayThrows 'transition-intent-without-transition' {param($s,$c)} 'SettingTransitionIntent' 's1' ([pscustomobject]@{ManifestHash=$mh;TransitionHash=('7'*64);Intent=$intent}) 'SettingTransitionIntent lacks the exact transition'
    Test-ReplayThrows 'parent-mismatch' $waitingSeed 'AssistiveRestoreParentCancelled' '' ([pscustomobject]@{ParentOperationId=[Guid]::NewGuid().ToString();PendingOperationCount=0}) 'does not match the durable TargetRestore parent'
    Test-ReplayThrows 'unknown-action-still-fails' {param($s,$c)} 'FixtureUnregisteredAction' '' $null 'Unknown recovery event: FixtureUnregisteredAction'

    Write-Host ('PASS: '+$script:checks+' checks; '+$written.Count+' journal actions all replayable or listed fail-closed; '+$script:replayed.Count+' replay-equivalence scenarios.')
  } $root (Join-Path $PSScriptRoot '..\src')
} finally {
  if([IO.Directory]::Exists($root)){
    $canonical=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if([IO.Path]::GetDirectoryName($canonical).TrimEnd('\') -ine $tempRoot.TrimEnd('\') -or [IO.Path]::GetFileName($canonical) -notmatch '^wsm-journal-replay-[a-f0-9]{32}$'){throw 'Refusing to clean an unexpected journal replay test directory.'}
    Remove-Item -LiteralPath $canonical -Recurse -Force
  }
}
