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
            Write-Host ('PASS: '+$script:checks+' durable Service challenge and credential-binding checks.')
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
        }
    } $root
} finally {Remove-WsmChallengeTestRoot $root 'wsm-service-challenge-flow-'}
