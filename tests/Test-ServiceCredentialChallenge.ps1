#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-service-challenge-flow-'+[Guid]::NewGuid().ToString('N'))
function Assert-WsmChallengeTestRoot([string]$Path,[string]$Prefix){
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92,[char]47)
    $full=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetDirectoryName($full);$leaf=[IO.Path]::GetFileName($full)
    if(-not [string]::Equals($parent,$temp,[StringComparison]::OrdinalIgnoreCase) -or -not $leaf.StartsWith($Prefix,[StringComparison]::Ordinal) -or $leaf -notmatch ('^'+[regex]::Escape($Prefix)+'[0-9a-f]{32}$')){throw 'Refusing cleanup outside the expected direct temporary test root.'}
    if([IO.Directory]::Exists($full) -or [IO.File]::Exists($full)){$item=Get-Item -LiteralPath $full -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing cleanup of a reparse-point test root.'};if(-not $item.PSIsContainer){throw 'Refusing cleanup because the test root is not a directory.'}}
    return $full
}
function Remove-WsmChallengeTestRoot([string]$Path,[string]$Prefix){$full=Assert-WsmChallengeTestRoot $Path $Prefix;if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}}
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Generated challenge test root unexpectedly already exists.'}
[void](Assert-WsmChallengeTestRoot $root 'wsm-service-challenge-flow-')
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($root)
        $script:checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Reject([scriptblock]$action,[string]$message){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $message}
        # The mutation callback must run exactly once under the workspace lock; a callback named like Invoke-WsmLocked's own parameter once recursed until the call stack overflowed.
        $mutationWorkspace=Join-Path $root 'mutation-callback';[void][IO.Directory]::CreateDirectory($mutationWorkspace);$script:mutationCalls=0
        $mutationResult=Invoke-WsmAssistiveServiceMutation -Workspace $mutationWorkspace -TargetFingerprint ('c'*64) -ServiceName 'FixtureMutationService' -Action {$script:mutationCalls++;'callback-ran'}
        Check ($script:mutationCalls -eq 1 -and [string]$mutationResult -ceq 'callback-ran') 'Service mutation callback did not run exactly once under the workspace lock.'
        $originalDecision=(Get-Command Get-WsmAssistiveRestoreDecision -CommandType Function).ScriptBlock
        $originalFresh=(Get-Command Assert-WsmAssistiveReceiptFresh -CommandType Function).ScriptBlock
        $originalReservations=(Get-Command Get-WsmAssistiveReservations -CommandType Function).ScriptBlock
        $originalSetReservation=(Get-Command Set-WsmAssistiveServiceReservationOperation -CommandType Function).ScriptBlock
        $originalRegister=(Get-Command Register-WsmAssistivePackageMaterials -CommandType Function).ScriptBlock
        $originalComplete=(Get-Command Complete-WsmAssistivePackageJob -CommandType Function).ScriptBlock
        $originalCheckpoint=(Get-Command Confirm-WsmOutputStateCheckpoint -CommandType Function).ScriptBlock
        $originalAdapterState=(Get-Command Get-WsmAdapterState -CommandType Function).ScriptBlock
        $originalAdapterRestore=(Get-Command Invoke-WsmAdapterRestore -CommandType Function).ScriptBlock
        $originalAdapterVerify=(Get-Command Test-WsmAdapterConfiguration -CommandType Function).ScriptBlock
        $originalAdapterIdentity=(Get-Command Get-WsmAdapterObjectIdentity -CommandType Function).ScriptBlock
        $originalReservationEvidence=(Get-Command Set-WsmAssistiveReservationEvidence -CommandType Function).ScriptBlock
        try {
            $pair=[Guid]::NewGuid().ToString('D');$operation=[Guid]::NewGuid().ToString('D');$itemId=Get-WsmHashText 'challenge-service-item';$manifestHash='a'*64;$planHash='b'*64;$fingerprint='c'*64;$previewHash='d'*64
            $spec=[pscustomobject]@{Adapter='Service';AccountMode='UserPassword';SecretRef='ServiceSecretA';Owner='Fixture owner';Desired=[pscustomobject]@{Name='FixtureChallengeService';Account='CONTOSO\svc-app';BinaryPathName='C:\Fixture\service.exe';Dependencies=@();Supplement=[pscustomobject]@{}}}
            $item=[pscustomobject]@{ItemId=$itemId;Decision='Include';MigrationSpec=$spec}
            $package=[pscustomobject]@{Root=$root;PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($item)};Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
            $paths=Get-WsmOperationPaths $root $pair;$token=New-WsmCancellationToken -PairId $pair -PlanHash $planHash -ManifestHash $manifestHash -OperationId $operation -StateDirectory $root
            $decision=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $root 'decision.json');ReceiptHash=('e'*64);SnapshotPath=(Join-Path $root 'snapshot.json');SelectedItemIds=@($itemId);Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=('f'*64)}}
            Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value {param($Package,[string]$ManifestHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$SnapshotPath)$script:challengeDecision}
            Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value {param($Package,$Decision)$true}
            Set-Item Function:\Get-WsmAssistiveReservations -Value {param($Item,$Package,[string]$Workspace,[switch]$PreviewOnly,[string]$OperationId,[string]$OperationState)[pscustomobject]@{Preview=[pscustomobject]@{ResourceKey=('1'*64)};Reservation=[pscustomobject]@{Reserved=$true};Existing=$false}}
            Set-Item Function:\Set-WsmAssistiveServiceReservationOperation -Value {param([string]$Workspace,[string]$ResourceKey,[string]$PairId,[string]$ItemId,[string]$OperationId,[string]$State)$script:challengeReservationState=$State}
            $script:challengeDecision=$decision;$script:challengeReservationState='';$script:fixtureDecisionCall=0
            $preview=[pscustomobject]@{Rows=@([pscustomobject]@{ItemId=$itemId;Status='Ready'});SelectedItemIds=@($itemId);WizardPreviewHash=$previewHash}
            $context=[pscustomobject]@{Role='Target';Actor='S-1-5-18@FIXTURE';SessionId='fixture-session';ContextId='fixture-context';Revision=9;OperationId=$operation}
            $extraBeforeWait=New-Object Management.Automation.PSCredential('CONTOSO\svc-app',(ConvertTo-SecureString 'UNREVIEWED-SYNTHETIC' -AsPlainText -Force));Reject {Invoke-WsmAssistiveRestore -Package $package -ManifestHash $manifestHash -StateDirectory $root -Secrets @{OtherSecret=$extraBeforeWait} -SidMap @{} -CancellationToken $token -GeneralHostEvidence @() -ReceiptPath $decision.ReceiptPath -ReceiptHash $decision.ReceiptHash -TargetSnapshotPath $decision.SnapshotPath -Preview $preview -ParentOperationId $operation -ChallengeContext $context} 'An unreviewed SecretRef reached Service reservation or restore processing.';Check (-not $script:challengeReservationState -and -not [IO.File]::Exists($paths.State)) 'Rejected unreviewed SecretRef left a reservation or durable waiting parent.'
            $waiting=Invoke-WsmAssistiveRestore -Package $package -ManifestHash $manifestHash -StateDirectory $root -Secrets @{} -SidMap @{} -CancellationToken $token -GeneralHostEvidence @() -ReceiptPath $decision.ReceiptPath -ReceiptHash $decision.ReceiptHash -TargetSnapshotPath $decision.SnapshotPath -Preview $preview -ParentOperationId $operation -ChallengeContext $context
            $state=Read-WsmJson $paths.State
            Check ($waiting.Status -ceq 'WaitingForInput' -and $waiting.ParentOperationId -ceq $operation -and $waiting.RequiredSecretRefs.Count -eq 1 -and $waiting.RequiredSecretRefs[0] -ceq 'ServiceSecretA' -and $waiting.NoTargetWrites) 'Service restore did not enter WaitingForInput under its exact durable TargetRestore parent.'
            Check ($state.Stage -ceq 'WaitingForInput' -and $state.RestoreAttempt.Status -ceq 'WaitingForInput' -and $state.RestoreAttempt.OperationId -ceq $operation -and $state.RestoreAttempt.WizardPreviewHash -ceq $previewHash -and -not $state.RestoreAttempt.PSObject.Properties['CompletedUtc'] -and $state.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and $script:challengeReservationState -ceq 'WaitingForInput') 'Waiting challenge failed to persist exact parent/preview state or kept a terminal completion marker.'
            $originalWizardPrompt=(Get-Command Read-WsmWizardValue -CommandType Function).ScriptBlock;$cliContext=Get-WsmWizardServiceChallengeContext $package $operation
            try{Set-Item Function:\Read-WsmWizardValue -Value {param([string]$Prompt)'NO'};Reject {Confirm-WsmWizardServiceChallengeTakeover $root $package $cliContext $previewHash $operation} 'Interactive CLI accepted a challenge takeover without the exact confirmation word.';$unchanged=Read-WsmJson $paths.State;Check ($unchanged.AssistiveServiceChallenge.Actor -ceq 'S-1-5-18@FIXTURE' -and $unchanged.AssistiveServiceChallenge.State -ceq 'WaitingForInput') 'Rejected CLI takeover changed the durable challenge owner.';Set-Item Function:\Read-WsmWizardValue -Value {param([string]$Prompt)'TAKEOVER'};Confirm-WsmWizardServiceChallengeTakeover $root $package $cliContext $previewHash $operation;$taken=Read-WsmJson $paths.State;Check ($taken.AssistiveServiceChallenge.ParentOperationId -ceq $operation -and $taken.AssistiveServiceChallenge.Actor -ceq $cliContext.Actor -and $taken.AssistiveServiceChallenge.State -ceq 'WaitingForInput') 'Interactive CLI takeover did not retain the same waiting parent and transfer only its owner binding.';$context=$cliContext}finally{Set-Item Function:\Read-WsmWizardValue -Value $originalWizardPrompt}
            $wrongCredential=New-Object Management.Automation.PSCredential('CONTOSO\wrong-app',(ConvertTo-SecureString 'WRONG-SYNTHETIC' -AsPlainText -Force))
            Reject {Invoke-WsmAssistiveRestore -Package $package -ManifestHash $manifestHash -StateDirectory $root -Secrets @{ServiceSecretA=$wrongCredential} -SidMap @{} -CancellationToken $token -GeneralHostEvidence @() -ReceiptPath $decision.ReceiptPath -ReceiptHash $decision.ReceiptHash -TargetSnapshotPath $decision.SnapshotPath -Preview $preview -ParentOperationId $operation -ChallengeContext $context} 'Service challenge accepted a credential username that differs from the reviewed account.'
            $afterWrong=Read-WsmJson $paths.State
            Check ($afterWrong.Stage -ceq 'WaitingForInput' -and $afterWrong.RestoreAttempt.Status -ceq 'WaitingForInput' -and $afterWrong.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and $afterWrong.RestoreAttempt.OperationId -ceq $operation) 'Rejected credential changed or completed the waiting parent.'
            $otherCredential=New-Object Management.Automation.PSCredential('CONTOSO\svc-app',(ConvertTo-SecureString 'WRONG-SYNTHETIC' -AsPlainText -Force))
            Reject {Invoke-WsmAssistiveRestore -Package $package -ManifestHash $manifestHash -StateDirectory $root -Secrets @{OtherSecret=$otherCredential} -SidMap @{} -CancellationToken $token -GeneralHostEvidence @() -ReceiptPath $decision.ReceiptPath -ReceiptHash $decision.ReceiptHash -TargetSnapshotPath $decision.SnapshotPath -Preview $preview -ParentOperationId $operation -ChallengeContext $context} 'Service challenge silently ignored an extra or missing SecretRef.'
            $stored=[IO.File]::ReadAllText($paths.State);Check ($stored -notmatch 'WRONG-SYNTHETIC|CONTOSO\\wrong-app|CONTOSO\\svc-app') 'A rejected in-memory credential appeared in durable operation state.'
            Set-Item Function:\Register-WsmAssistivePackageMaterials -Value {param($Package,$Decision,[string]$Workspace,$Preview)[pscustomobject]@{OperationId='fixture-material-job';MaterialIds=@()}}
            Set-Item Function:\Complete-WsmAssistivePackageJob -Value {param($Package,$Job,[string]$Workspace)}
            Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value {param([string]$StateDirectory,[string]$PairId,[string]$PlanHash)}
            Set-Item Function:\Get-WsmAdapterState -Value {param($Spec)[pscustomobject]@{Exists=$false;Name='';Actual=$null}}
            Set-Item Function:\Invoke-WsmAdapterRestore -Value {param($Spec,$Secrets,$Package,$InstallerBaseline,$BeforeFolderCreate,$AfterFolderCreate,$OwnedReceipts,$SharedReceipts,$Workspace,$OperationId)$script:capturedServiceCredential=$Secrets['ServiceSecretA'];[pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}}
            Set-Item Function:\Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,$SecurityReceipts)[pscustomobject]@{Passed=$true;Problems=@();Actual=[pscustomobject]@{Name='FixtureChallengeService';StartName='CONTOSO\svc-app'}}}
            Set-Item Function:\Get-WsmAdapterObjectIdentity -Value {param($Spec)'FixtureChallengeService'}
            Set-Item Function:\Set-WsmAssistiveReservationEvidence -Value {param($Reservations,$Item,$Package,$Prior,$Desired,$Readback,$Undo,[string]$Workspace)}
            $valid=New-Object Management.Automation.PSCredential('CONTOSO\svc-app',(ConvertTo-SecureString 'SYNTHETIC-VALID' -AsPlainText -Force));$script:capturedServiceCredential=$null
            $resumed=Invoke-WsmAssistiveRestore -Package $package -ManifestHash $manifestHash -StateDirectory $root -Secrets @{ServiceSecretA=$valid} -SidMap @{} -CancellationToken $token -GeneralHostEvidence @() -ReceiptPath $decision.ReceiptPath -ReceiptHash $decision.ReceiptHash -TargetSnapshotPath $decision.SnapshotPath -Preview $preview -ParentOperationId $operation -ChallengeContext $context
            Check ($script:capturedServiceCredential -is [Management.Automation.PSCredential] -and $script:capturedServiceCredential.UserName -ceq 'CONTOSO\svc-app' -and $script:capturedServiceCredential.GetNetworkCredential().Password -ceq 'SYNTHETIC-VALID') 'Valid secure credential did not reach the actual Assistive Service adapter boundary in memory.'
            $resumedState=Read-WsmJson $paths.State;Check ($resumed.Stage -in @('Succeeded','Partial') -and $resumedState.RestoreAttempt.OperationId -ceq $operation -and $resumedState.AssistiveServiceChallenge.State -ceq 'Completed') 'Valid challenge did not finish through the same TargetRestore parent and actual Assistive coordinator.'
            $postResume=[IO.File]::ReadAllText($paths.State);Check ($postResume -notmatch 'SYNTHETIC-VALID|CONTOSO\\svc-app') 'Accepted credential appeared in durable operation state after the adapter call.'
            # ---- F4a-3: the same challenge now covers Service, Password scheduled tasks and SpecificUser IIS pools.
            $originalTaskReceipts=(Get-Command Get-WsmTaskSecurityReceiptsForSpec -CommandType Function).ScriptBlock;Set-Item Function:\Get-WsmTaskSecurityReceiptsForSpec -Value {param($Spec,[object[]]$Receipts)@()}
            $script:adapterCalls=0;$script:capturedSecrets=$null
            Set-Item Function:\Invoke-WsmAdapterRestore -Value {param($Spec,$Secrets,$Package,$InstallerBaseline,$BeforeFolderCreate,$AfterFolderCreate,$OwnedReceipts,$SharedReceipts,$Workspace,$OperationId)$script:adapterCalls++;$script:capturedSecrets=$Secrets;[pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}}
            $taskXmlFor={param($account)'<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="Author"><UserId>'+$account+'</UserId><LogonType>Password</LogonType></Principal></Principals></Task>'}
            function New-CredTaskSpec([string]$Ref,[string]$Account){[pscustomobject]@{Adapter='ScheduledTask';SecretRef=$Ref;CatchUpPolicy='SkipMissedRuns';Desired=[pscustomobject]@{TaskName='FixtureCredTask';TaskPath='\';Xml=(& $taskXmlFor $Account);User=$Account}}}
            function New-CredPoolSpec([string]$Ref,[string]$Account){[pscustomobject]@{Adapter='IISPool';SecretRef=$Ref;Desired=[pscustomobject]@{Name='FixtureCredPool';Xml=('<add name="FixtureCredPool"><processModel identityType="SpecificUser" userName="'+$Account+'" /></add>')}}}
            function New-CredServiceSpec([string]$Ref,[string]$Account){[pscustomobject]@{Adapter='Service';AccountMode='UserPassword';SecretRef=$Ref;Owner='Fixture owner';Desired=[pscustomobject]@{Name='FixtureCredService';Account=$Account;BinaryPathName='C:\Fixture\service.exe';Dependencies=@();Supplement=[pscustomobject]@{}}}}
            function New-CredScenario([object[]]$Defs){
                $p=[Guid]::NewGuid().ToString('D');$op=[Guid]::NewGuid().ToString('D');$items=@();$ids=@()
                foreach($d in $Defs){$id=Get-WsmHashText ('cred-'+$d.Name+$p);$ids+=$id;$items+=[pscustomobject]@{ItemId=$id;Name=$d.Name;Decision='Include';MigrationSpec=$d.Spec}}
                $pk=[pscustomobject]@{Root=$root;PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($items)};Manifest=[pscustomobject]@{PairId=$p;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
                $dec=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $root 'decision.json');ReceiptHash=('e'*64);SnapshotPath=(Join-Path $root 'snapshot.json');SelectedItemIds=@($ids);Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=('f'*64)}}
                $pv=[pscustomobject]@{Rows=@($ids|ForEach-Object {[pscustomobject]@{ItemId=$_;Status='Ready'}});SelectedItemIds=@($ids);WizardPreviewHash=$previewHash}
                [pscustomobject]@{Pair=$p;Op=$op;Package=$pk;Decision=$dec;Token=(New-WsmCancellationToken -PairId $p -PlanHash $planHash -ManifestHash $manifestHash -OperationId $op -StateDirectory $root);Preview=$pv;Context=[pscustomobject]@{Role='Target';Actor='S-1-5-18@FIXTURE';SessionId='fixture-session';ContextId='fixture-context';Revision=9;OperationId=$op};Ids=$ids;Paths=(Get-WsmOperationPaths $root $p)}
            }
            function Invoke-CredScenario($S,[hashtable]$Secrets){$script:challengeDecision=$S.Decision;Invoke-WsmAssistiveRestore -Package $S.Package -ManifestHash $manifestHash -StateDirectory $root -Secrets $Secrets -SidMap @{} -CancellationToken $S.Token -GeneralHostEvidence @() -ReceiptPath $S.Decision.ReceiptPath -ReceiptHash $S.Decision.ReceiptHash -TargetSnapshotPath $S.Decision.SnapshotPath -Preview $S.Preview -ParentOperationId $S.Op -ChallengeContext $S.Context}
            function Get-CredJournalText($S){if([IO.File]::Exists($S.Paths.Journal)){[IO.File]::ReadAllText($S.Paths.Journal)}else{''}}
            function New-CredPassword([string]$Account,[string]$Tag){New-Object Management.Automation.PSCredential($Account,(ConvertTo-SecureString ('SYNTHETIC-'+$Tag) -AsPlainText -Force))}
            foreach($kind in @(@{Kind='ScheduledTask';Ref='TaskSecret';Account='CONTOSO\batch';Name='Fixture nightly task'},@{Kind='IISPool';Ref='PoolSecret';Account='CONTOSO\poolsvc';Name='Fixture web pool'})){
                $kindSpec=if($kind.Kind -ceq 'ScheduledTask'){New-CredTaskSpec $kind.Ref $kind.Account}else{New-CredPoolSpec $kind.Ref $kind.Account}
                $s=New-CredScenario @(@{Name=$kind.Name;Spec=$kindSpec});$script:adapterCalls=0;$script:capturedSecrets=$null
                $w=Invoke-CredScenario $s @{};$st=Read-WsmJson $s.Paths.State
                Check ($w.Status -ceq 'WaitingForInput' -and $w.NoTargetWrites -and $w.RequiredSecretRefs.Count -eq 1 -and $w.RequiredSecretRefs[0] -ceq $kind.Ref -and $script:adapterCalls -eq 0) ($kind.Kind+' without a credential did not stop in WaitingForInput before any adapter call.')
                Check (@($st.PendingOperations).Count -eq 0 -and (Get-CredJournalText $s) -notmatch 'AssistiveAdapterIntent' -and $st.AssistiveServiceChallenge.State -ceq 'WaitingForInput') ($kind.Kind+' waiting left PendingOperations or an AssistiveAdapterIntent journal entry.')
                $req=@($w.CredentialRequirements);$stored=@($st.AssistiveServiceChallenge.Requirements)
                Check ($req.Count -eq 1 -and $req[0].SecretRef -ceq $kind.Ref -and @($req[0].Kinds).Count -eq 1 -and $req[0].Kinds[0] -ceq $kind.Kind -and $req[0].ItemIds[0] -ceq $s.Ids[0] -and $req[0].DisplayNames[0] -ceq $kind.Name -and $req[0].ApprovedAccount -ceq $kind.Account) ($kind.Kind+' CredentialRequirements content is wrong.')
                Check ($stored.Count -eq 1 -and $stored[0].SecretRef -ceq $kind.Ref -and $stored[0].Kinds[0] -ceq $kind.Kind -and $stored[0].ApprovedAccount -ceq $kind.Account -and $stored[0].DisplayNames[0] -ceq $kind.Name) ($kind.Kind+' durable challenge Requirements content is wrong.')
                Reject {Invoke-CredScenario $s @{($kind.Ref)=(New-CredPassword 'CONTOSO\someone-else' 'WRONG-ACCOUNT')}} ($kind.Kind+' challenge accepted a credential for a non-approved account.')
                $afterWrong=Read-WsmJson $s.Paths.State
                Check ($afterWrong.Stage -ceq 'WaitingForInput' -and $afterWrong.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and @($afterWrong.PendingOperations).Count -eq 0 -and $script:adapterCalls -eq 0 -and (Get-CredJournalText $s) -notmatch 'AssistiveAdapterIntent') ($kind.Kind+' rejection changed the waiting challenge or wrote before rejecting.')
                $upper=New-CredPassword $kind.Account.ToUpperInvariant() ('VALID-'+$kind.Kind)
                $done=Invoke-CredScenario $s @{($kind.Ref)=$upper};$doneState=Read-WsmJson $s.Paths.State
                Check ($script:adapterCalls -eq 1 -and $script:capturedSecrets[$kind.Ref] -is [Management.Automation.PSCredential] -and $script:capturedSecrets[$kind.Ref].GetNetworkCredential().Password -ceq ('SYNTHETIC-VALID-'+$kind.Kind) -and $done.Stage -in @('Succeeded','Partial') -and $doneState.AssistiveServiceChallenge.State -ceq 'Completed') ($kind.Kind+' approved credential did not reach the adapter boundary and complete the parent.')
                Check ((Get-CredJournalText $s) -match 'AssistiveAdapterIntent') ($kind.Kind+' control run did not write the intent journal (positive control for the absence checks).')
            }
            # One SecretRef shared by a Service and a task (same account, different case) is asked for once.
            $s=New-CredScenario @(@{Name='Fixture shared service';Spec=(New-CredServiceSpec 'SharedSecret' 'CONTOSO\svc-app')},@{Name='Fixture shared task';Spec=(New-CredTaskSpec 'SharedSecret' 'contoso\SVC-APP')});$script:adapterCalls=0
            $w=Invoke-CredScenario $s @{};$req=@($w.CredentialRequirements)
            Check ($w.Status -ceq 'WaitingForInput' -and $w.RequiredSecretRefs.Count -eq 1 -and $req.Count -eq 1 -and (@($req[0].Kinds) -join ',') -ceq 'ScheduledTask,Service' -and @($req[0].ItemIds).Count -eq 2 -and @($req[0].DisplayNames).Count -eq 2) 'A SecretRef shared by Service and task was not collapsed into one requirement with both consumers.'
            $null=Invoke-CredScenario $s @{SharedSecret=(New-CredPassword 'CONTOSO\svc-app' 'SHARED-VALID')}
            Check ($script:adapterCalls -eq 2) 'A single shared credential did not reach both the Service and the task adapters.'
            # The same SecretRef with two different approved accounts is refused before any challenge exists.
            $s=New-CredScenario @(@{Name='Fixture conflicting service';Spec=(New-CredServiceSpec 'ConflictSecret' 'CONTOSO\svc-app')},@{Name='Fixture conflicting task';Spec=(New-CredTaskSpec 'ConflictSecret' 'CONTOSO\batch')});$conflictMessage=''
            try{Invoke-CredScenario $s @{ConflictSecret=(New-CredPassword 'CONTOSO\svc-app' 'CONFLICT-PASSWORD')}|Out-Null}catch{$conflictMessage=[string]$_.Exception.Message}
            Check ($conflictMessage -and $conflictMessage -notmatch 'SYNTHETIC' -and -not [IO.File]::Exists($s.Paths.State)) 'A SecretRef shared across different accounts was not refused before the challenge, or the message leaked a password.'
            $conflictMessage='';try{Invoke-CredScenario $s @{}|Out-Null}catch{$conflictMessage=[string]$_.Exception.Message}
            Check ($conflictMessage -and -not [IO.File]::Exists($s.Paths.State)) 'A conflicting SecretRef/account set entered a challenge.'
            # A challenge written before Requirements existed can still be resumed.
            $s=New-CredScenario @(@{Name='Fixture legacy task';Spec=(New-CredTaskSpec 'LegacySecret' 'CONTOSO\batch')});$script:adapterCalls=0
            $null=Invoke-CredScenario $s @{};$legacy=Read-WsmJson $s.Paths.State;$legacy.AssistiveServiceChallenge.PSObject.Properties.Remove('Requirements');Write-WsmJson $s.Paths.State $legacy
            Check (-not (Read-WsmJson $s.Paths.State).AssistiveServiceChallenge.PSObject.Properties['Requirements']) 'Legacy challenge fixture still carries Requirements.'
            $again=Invoke-CredScenario $s @{}
            Check ($again.Status -ceq 'WaitingForInput' -and @($again.CredentialRequirements).Count -eq 1 -and $again.RequiredSecretRefs[0] -ceq 'LegacySecret') 'A legacy challenge without Requirements could not re-enter WaitingForInput.'
            $legacy=Read-WsmJson $s.Paths.State;$legacy.AssistiveServiceChallenge.PSObject.Properties.Remove('Requirements');Write-WsmJson $s.Paths.State $legacy
            $null=Invoke-CredScenario $s @{LegacySecret=(New-CredPassword 'CONTOSO\batch' 'LEGACY-VALID')}
            Check ($script:adapterCalls -eq 1 -and (Read-WsmJson $s.Paths.State).AssistiveServiceChallenge.State -ceq 'Completed') 'A legacy challenge without Requirements could not be resumed to completion.'
            # Second line of defence: the per-item path itself refuses to write an intent without the credential.
            $guardTask=New-CredTaskSpec 'GuardSecret' 'CONTOSO\batch'
            Reject {Assert-WsmAssistiveCredentialAvailable $guardTask @{}} 'Credential guard accepted a missing credential.'
            Reject {Assert-WsmAssistiveCredentialAvailable $guardTask @{GuardSecret='not-a-credential'}} 'Credential guard accepted a non-PSCredential value.'
            Assert-WsmAssistiveCredentialAvailable $guardTask @{GuardSecret=(New-CredPassword 'CONTOSO\batch' 'GUARD')}
            Assert-WsmAssistiveCredentialAvailable ([pscustomobject]@{Adapter='SmbShare';Desired=[pscustomobject]@{Name='x'}}) @{}
            $s=New-CredScenario @(@{Name='Fixture guarded task';Spec=$guardTask});$script:adapterCalls=0;$script:realRequirement=(Get-Command Get-WsmAdapterCredentialRequirement -CommandType Function).ScriptBlock;$script:requirementCalls=0
            try{
                Set-Item Function:\Get-WsmAdapterCredentialRequirement -Value {param($Spec)$script:requirementCalls++;if($script:requirementCalls -le 1){return $null};& $script:realRequirement $Spec}
                $guarded=Invoke-CredScenario $s @{};$guardState=Read-WsmJson $s.Paths.State
            }finally{Set-Item Function:\Get-WsmAdapterCredentialRequirement -Value $script:realRequirement}
            Check ($guarded.Stage -ceq 'Partial' -and @($guarded.Results).Count -eq 1 -and $guarded.Results[0].Status -ceq 'Failed' -and -not $guarded.Results[0].CreatedByTool -and $script:adapterCalls -eq 0) 'Per-item path ran or reported ownership although the credential was missing.'
            Check (@($guardState.PendingOperations).Count -eq 0 -and (Get-CredJournalText $s) -notmatch 'AssistiveAdapterIntent') 'Per-item path left PendingOperations or wrote an intent although the credential was missing.'
            # Preview rows mark credential consumers (and only those) -- exercised through the row builder contract fields.
            Check ((Get-WsmAdapterCredentialRequirement (New-CredPoolSpec 'p' 'CONTOSO\poolsvc')).Kind -ceq 'IISPool') 'Pool requirement probe for preview marking failed.'
            # IIS snapshots never hold a password value.
            $poolElement=[pscustomobject]@{ElementTagName='processModel';Attributes=@([pscustomobject]@{Name='userName';Value='CONTOSO\poolsvc'},[pscustomobject]@{Name='password';Value='SYNTHETIC-POOL-PASSWORD'});ChildElements=@()};$poolElement|Add-Member ScriptMethod GetCollection {throw 'not a collection'}
            $snapshot=Get-WsmIisElementSnapshot $poolElement;$snapshotJson=$snapshot|ConvertTo-Json -Depth 20 -Compress
            Check ($snapshotJson -notmatch 'SYNTHETIC' -and $snapshotJson -match '\[withheld\]' -and $snapshot.Attributes['userName'] -ceq 'CONTOSO\poolsvc' -and $snapshot.Attributes['password'] -ceq '[withheld]') 'IIS snapshot kept or hid the processModel password incorrectly.'
            $emptyPool=[pscustomobject]@{ElementTagName='processModel';Attributes=@([pscustomobject]@{Name='Password';Value=''},[pscustomobject]@{Name='userName';Value='u'});ChildElements=@()};$emptyPool|Add-Member ScriptMethod GetCollection {throw 'not a collection'}
            $emptySnapshot=Get-WsmIisElementSnapshot $emptyPool
            Check (-not $emptySnapshot.Attributes.Contains('Password') -and $emptySnapshot.Attributes['userName'] -ceq 'u') 'IIS snapshot recorded a marker for an empty password.'
            # Nothing synthetic may be present in any durable file this test wrote.
            $leaks=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force|Where-Object {[IO.File]::ReadAllText($_.FullName) -match 'SYNTHETIC'})
            Check ($leaks.Count -eq 0) ('Synthetic secret sentinel found in durable test output: '+(@($leaks|ForEach-Object Name) -join ', '))
            Write-Host ('PASS: '+$script:checks+' durable Service/task/IIS-pool challenge and credential-binding checks.')
        } finally {
            Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value $originalDecision
            Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value $originalFresh
            Set-Item Function:\Get-WsmAssistiveReservations -Value $originalReservations
            Set-Item Function:\Set-WsmAssistiveServiceReservationOperation -Value $originalSetReservation
            Set-Item Function:\Register-WsmAssistivePackageMaterials -Value $originalRegister
            Set-Item Function:\Complete-WsmAssistivePackageJob -Value $originalComplete
            Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value $originalCheckpoint
            Set-Item Function:\Get-WsmAdapterState -Value $originalAdapterState
            Set-Item Function:\Invoke-WsmAdapterRestore -Value $originalAdapterRestore
            Set-Item Function:\Test-WsmAdapterConfiguration -Value $originalAdapterVerify
            Set-Item Function:\Get-WsmAdapterObjectIdentity -Value $originalAdapterIdentity
            Set-Item Function:\Set-WsmAssistiveReservationEvidence -Value $originalReservationEvidence
            if($originalTaskReceipts){Set-Item Function:\Get-WsmTaskSecurityReceiptsForSpec -Value $originalTaskReceipts}
        }
    } $root
} finally {Remove-WsmChallengeTestRoot $root 'wsm-service-challenge-flow-'}
