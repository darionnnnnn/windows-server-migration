#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-credential-deferral-'+[Guid]::NewGuid().ToString('N'))
function Assert-WsmDeferralTestRoot([string]$Path,[string]$Prefix){
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92,[char]47)
    $full=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetDirectoryName($full);$leaf=[IO.Path]::GetFileName($full)
    if(-not [string]::Equals($parent,$temp,[StringComparison]::OrdinalIgnoreCase) -or -not $leaf.StartsWith($Prefix,[StringComparison]::Ordinal) -or $leaf -notmatch ('^'+[regex]::Escape($Prefix)+'[0-9a-f]{32}$')){throw 'Refusing cleanup outside the expected direct temporary test root.'}
    if([IO.Directory]::Exists($full) -or [IO.File]::Exists($full)){$item=Get-Item -LiteralPath $full -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing cleanup of a reparse-point test root.'};if(-not $item.PSIsContainer){throw 'Refusing cleanup because the test root is not a directory.'}}
    return $full
}
function Remove-WsmDeferralTestRoot([string]$Path,[string]$Prefix){$full=Assert-WsmDeferralTestRoot $Path $Prefix;if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}}
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Generated deferral test root unexpectedly already exists.'}
[void](Assert-WsmDeferralTestRoot $root 'wsm-credential-deferral-')
[void][IO.Directory]::CreateDirectory($root)
$script:primaryFailure=$null
try {
    & $module {
        param($root)
        $script:checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Reject([scriptblock]$action,[string]$message){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $message}
        $names='Get-WsmAssistiveRestoreDecision','Assert-WsmAssistiveReceiptFresh','Get-WsmAssistiveReservations','Set-WsmAssistiveServiceReservationOperation','Register-WsmAssistivePackageMaterials','Complete-WsmAssistivePackageJob','Confirm-WsmOutputStateCheckpoint','Get-WsmAdapterState','Invoke-WsmAdapterRestore','Test-WsmAdapterConfiguration','Get-WsmAdapterObjectIdentity','Set-WsmAssistiveReservationEvidence','Get-WsmTaskSecurityReceiptsForSpec'
        $originals=@{};foreach($n in $names){$originals[$n]=(Get-Command $n -CommandType Function).ScriptBlock}
        try {
            $planHash='b'*64;$manifestHash='a'*64;$fingerprint='c'*64;$previewHash='d'*64
            Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value {param($Package,[string]$ManifestHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$SnapshotPath)$script:challengeDecision}
            Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value {param($Package,$Decision)$true}
            Set-Item Function:\Get-WsmAssistiveReservations -Value {param($Item,$Package,[string]$Workspace,[switch]$PreviewOnly,[string]$OperationId,[string]$OperationState)[pscustomobject]@{Preview=[pscustomobject]@{ResourceKey=('1'*64)};Reservation=[pscustomobject]@{Reserved=$true};Existing=$false}}
            Set-Item Function:\Set-WsmAssistiveServiceReservationOperation -Value {param([string]$Workspace,[string]$ResourceKey,[string]$PairId,[string]$ItemId,[string]$OperationId,[string]$State)$script:reservationStates[$ItemId]=$State}
            Set-Item Function:\Register-WsmAssistivePackageMaterials -Value {param($Package,$Decision,[string]$Workspace,$Preview)[pscustomobject]@{OperationId='fixture-material-job';MaterialIds=@()}}
            Set-Item Function:\Complete-WsmAssistivePackageJob -Value {param($Package,$Job,[string]$Workspace)}
            Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value {param([string]$StateDirectory,[string]$PairId,[string]$PlanHash)}
            Set-Item Function:\Get-WsmTaskSecurityReceiptsForSpec -Value {param($Spec,[object[]]$Receipts)@()}
            Set-Item Function:\Get-WsmAdapterState -Value {param($Spec)$script:stateCalls++;$exists=$false;if($script:existsNow.ContainsKey([string]$Spec.Desired.Name)){$exists=[bool]$script:existsNow[[string]$Spec.Desired.Name]};[pscustomobject]@{Exists=$exists;Name='';Actual=$null}}
            Set-Item Function:\Invoke-WsmAdapterRestore -Value {param($Spec,$Secrets,$Package,$InstallerBaseline,$BeforeFolderCreate,$AfterFolderCreate,$OwnedReceipts,$SharedReceipts,$Workspace,$OperationId)
                $name=[string]$Spec.Desired.Name;$script:adapterLog+=@($name)
                if($script:rejectNames -contains $name){if($script:flipOnThrow){$script:existsNow[$name]=$true};throw (New-Object System.ComponentModel.Win32Exception 1326)}
                [pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}}
            Set-Item Function:\Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,$SecurityReceipts)[pscustomobject]@{Passed=$true;Problems=@();Actual=[pscustomobject]@{Name=[string]$Spec.Desired.Name}}}
            Set-Item Function:\Get-WsmAdapterObjectIdentity -Value {param($Spec)[string]$Spec.Desired.Name}
            Set-Item Function:\Set-WsmAssistiveReservationEvidence -Value {param($Reservations,$Item,$Package,$Prior,$Desired,$Readback,$Undo,[string]$Workspace)}
            $script:reservationStates=@{};$script:stateCalls=0;$script:existsNow=@{};$script:adapterLog=@();$script:rejectNames=@();$script:flipOnThrow=$false

            function New-DefTaskSpec([string]$Name,[string]$Ref,[string]$Account){$xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="Author"><UserId>'+$Account+'</UserId><LogonType>Password</LogonType></Principal></Principals></Task>';[pscustomobject]@{Adapter='ScheduledTask';SecretRef=$Ref;CatchUpPolicy='SkipMissedRuns';Desired=[pscustomobject]@{TaskName=$Name;TaskPath='\';Xml=$xml;User=$Account}}}
            function New-DefServiceSpec([string]$Name,[string]$Ref,[string]$Account){[pscustomobject]@{Adapter='Service';AccountMode='UserPassword';SecretRef=$Ref;Owner='Fixture owner';Desired=[pscustomobject]@{Name=$Name;Account=$Account;BinaryPathName='C:\Fixture\service.exe';Dependencies=@();Supplement=[pscustomobject]@{}}}}
            function New-DefScenario([object[]]$Defs){
                $p=[Guid]::NewGuid().ToString('D');$op=[Guid]::NewGuid().ToString('D');$items=@();$ids=@()
                foreach($d in $Defs){$id=Get-WsmHashText ('def-'+$d.Name+$p);$ids+=$id;$items+=[pscustomobject]@{ItemId=$id;Name=$d.Name;Kind='Fixture';Decision='Include';MigrationSpec=$d.Spec}}
                $pk=[pscustomobject]@{Root=$root;PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($items)};Manifest=[pscustomobject]@{PairId=$p;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
                $dec=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $root 'decision.json');ReceiptHash=('e'*64);SnapshotPath=(Join-Path $root 'snapshot.json');SelectedItemIds=@($ids);Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=('f'*64)}}
                $pv=[pscustomobject]@{Rows=@($ids|ForEach-Object {[pscustomobject]@{ItemId=$_;Status='Ready'}});SelectedItemIds=@($ids);WizardPreviewHash=$previewHash}
                [pscustomobject]@{Pair=$p;Op=$op;Package=$pk;Decision=$dec;Token=(New-WsmCancellationToken -PairId $p -PlanHash $planHash -ManifestHash $manifestHash -OperationId $op -StateDirectory $root);Preview=$pv;Context=[pscustomobject]@{Role='Target';Actor='S-1-5-18@FIXTURE';SessionId='fixture-session';ContextId='fixture-context';Revision=9;OperationId=$op};Ids=$ids;Paths=(Get-WsmOperationPaths $root $p)}
            }
            function Invoke-DefScenario($S,[hashtable]$Secrets){$script:challengeDecision=$S.Decision;Invoke-WsmAssistiveRestore -Package $S.Package -ManifestHash $manifestHash -StateDirectory $root -Secrets $Secrets -SidMap @{} -CancellationToken $S.Token -GeneralHostEvidence @() -ReceiptPath $S.Decision.ReceiptPath -ReceiptHash $S.Decision.ReceiptHash -TargetSnapshotPath $S.Decision.SnapshotPath -Preview $S.Preview -ParentOperationId $S.Op -ChallengeContext $S.Context}
            function Get-DefJournalLines($S){if([IO.File]::Exists($S.Paths.Journal)){@([IO.File]::ReadAllLines($S.Paths.Journal))}else{@()}}
            function New-DefPassword([string]$Account,[string]$Tag){New-Object Management.Automation.PSCredential($Account,(ConvertTo-SecureString ('SYNTHETIC-'+$Tag) -AsPlainText -Force))}
            function Get-DefIntentItems($S){@(Get-DefJournalLines $S|Where-Object {$_ -match '"Action":"AssistiveAdapterIntent"'}|ForEach-Object {([string]$_|ConvertFrom-Json).ItemId})}
            function Defer-Refs($S,[string[]]$Refs){Set-WsmAssistiveCredentialDeferral -StateDirectory $root -PairId $S.Pair -ParentOperationId $S.Op -PreviewHash $previewHash -SecretRefs $Refs}
            function Reset-Fixture(){$script:adapterLog=@();$script:rejectNames=@();$script:flipOnThrow=$false;$script:existsNow=@{};$script:stateCalls=0;$script:reservationStates=@{}}

            # ---- classifier: refused logon is recognised through every shape, anything else is not.
            Check (Test-WsmAssistiveCredentialRejectedError (New-Object System.ComponentModel.Win32Exception 1326)) 'Win32 1326 was not classified as a refused logon.'
            Check (Test-WsmAssistiveCredentialRejectedError (New-Object System.ComponentModel.Win32Exception 1069)) 'Win32 1069 was not classified as a refused logon.'
            $hresultException=New-Object System.Runtime.InteropServices.COMException('logon failure',[int]'-2147023570')
            Check (Test-WsmAssistiveCredentialRejectedError $hresultException) 'HRESULT 0x8007052E was not classified as a refused logon.'
            $hresult1069=New-Object System.Runtime.InteropServices.COMException('service logon failure',[int]'-2147023827')
            Check (Test-WsmAssistiveCredentialRejectedError $hresult1069) 'HRESULT 0x8007042D (1069) was not classified as a refused logon.'
            $wrapped=New-Object System.InvalidOperationException('outer',(New-Object System.ComponentModel.Win32Exception 1326))
            Check (Test-WsmAssistiveCredentialRejectedError $wrapped) 'A refused logon wrapped in an InnerException was not classified.'
            $record=New-Object Management.Automation.ErrorRecord($wrapped,'fixture','NotSpecified',$null)
            Check (Test-WsmAssistiveCredentialRejectedError $record) 'A refused logon inside an ErrorRecord was not classified.'
            Check (-not (Test-WsmAssistiveCredentialRejectedError (New-Object System.ComponentModel.Win32Exception 5))) 'Access denied (5) was classified as a refused logon.'
            Check (-not (Test-WsmAssistiveCredentialRejectedError (New-Object System.IO.IOException 'disk full'))) 'A plain IOException was classified as a refused logon.'
            Check (-not (Test-WsmAssistiveCredentialRejectedError $null)) 'A null failure was classified as a refused logon.'
            Check ((Get-WsmAssistiveCredentialMaxAttempts) -eq 3) 'The retry limit is not 3.'

            # ---- verdict: refusal AND proven absence; no probe for any other error.
            $verdictSpec=New-DefServiceSpec 'VerdictService' 'VerdictSecret' 'CONTOSO\svc-app';Reset-Fixture
            Check ((Get-WsmAssistiveCredentialRejectionVerdict (New-Object System.ComponentModel.Win32Exception 1326) $verdictSpec) -ceq 'Rejected') 'A refusal with the target still absent was not Rejected.'
            $script:existsNow['VerdictService']=$true
            Check ((Get-WsmAssistiveCredentialRejectionVerdict (New-Object System.ComponentModel.Win32Exception 1326) $verdictSpec) -ceq 'Unknown') 'A refusal with an existing target was not Unknown.'
            $script:existsNow['VerdictService']=$false;$script:stateCalls=0
            Check ((Get-WsmAssistiveCredentialRejectionVerdict (New-Object System.ComponentModel.Win32Exception 5) $verdictSpec) -ceq 'Unknown' -and $script:stateCalls -eq 0) 'A non-refusal error was probed or classified as Rejected.'

            # ---- 1. defer the task group, enter the Service group.
            Reset-Fixture
            $s=New-DefScenario @(@{Name='DefSvcA';Spec=(New-DefServiceSpec 'DefSvcA' 'SvcSecret' 'CONTOSO\svc-app')},@{Name='DefTaskA';Spec=(New-DefTaskSpec 'DefTaskA' 'TaskSecret' 'CONTOSO\batch')})
            $w=Invoke-DefScenario $s @{}
            Check ($w.Status -ceq 'WaitingForInput' -and $w.RequiredSecretRefs.Count -eq 2) 'Two-group scenario did not wait for both SecretRefs.'
            $r0=@($w.CredentialRequirements)[0];Check ($r0.PSObject.Properties['Deferred'] -and $r0.Deferred -eq $false -and $r0.Attempts -eq 0 -and $r0.LastFailure -ceq '') 'Fresh requirement lacks the Deferred/Attempts/LastFailure fields.'
            Reject {Defer-Refs $s @('NotARequirement')} 'Deferral accepted a SecretRef outside the challenge requirements.'
            Reject {Defer-Refs $s @()} 'Deferral accepted an empty SecretRef list.'
            Reject {Set-WsmAssistiveCredentialDeferral -StateDirectory $root -PairId $s.Pair -ParentOperationId $s.Op -PreviewHash ('9'*64) -SecretRefs @('TaskSecret')} 'Deferral accepted a different preview hash.'
            Reject {Set-WsmAssistiveCredentialDeferral -StateDirectory $root -PairId $s.Pair -ParentOperationId ([Guid]::NewGuid().ToString('D')) -PreviewHash $previewHash -SecretRefs @('TaskSecret')} 'Deferral accepted a different parent operation.'
            $afterBad=Read-WsmJson $s.Paths.State;Check (@($afterBad.AssistiveServiceChallenge.Requirements|Where-Object Deferred).Count -eq 0 -and @($afterBad.AssistiveServiceChallenge.RequiredSecretRefs).Count -eq 2) 'A rejected deferral changed the durable challenge.'
            $deferred=Defer-Refs $s @('TaskSecret')
            $st=Read-WsmJson $s.Paths.State;$taskReq=@($st.AssistiveServiceChallenge.Requirements|Where-Object SecretRef -CEQ 'TaskSecret')[0]
            Check ($taskReq.Deferred -eq $true -and $taskReq.DeferReason -ceq 'CredentialDeferred' -and (@($st.AssistiveServiceChallenge.RequiredSecretRefs) -join ',') -ceq 'SvcSecret' -and $st.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and -not $deferred.AllDeferred) 'Deferral did not durably mark only the task group.'
            Check (@((Get-DefJournalLines $s) -match 'AssistiveServiceCredentialDeferred').Count -ge 1) 'Deferral wrote no journal entry.'
            $reAsk=Invoke-DefScenario $s @{};Check ($reAsk.Status -ceq 'WaitingForInput' -and (@($reAsk.RequiredSecretRefs) -join ',') -ceq 'SvcSecret' -and @($reAsk.CredentialRequirements|Where-Object {$_.SecretRef -ceq 'TaskSecret' -and $_.Deferred}).Count -eq 1) 'Re-entering the wait still asked for the deferred group or lost its Deferred flag.'
            Reject {Invoke-DefScenario $s @{TaskSecret=(New-DefPassword 'CONTOSO\batch' 'DEFERRED-TASK')}} 'A credential for a deferred SecretRef was accepted.'
            $script:adapterLog=@()
            $done=Invoke-DefScenario $s @{SvcSecret=(New-DefPassword 'CONTOSO\svc-app' 'SVC-VALID')}
            $doneState=Read-WsmJson $s.Paths.State;$byId=@{};foreach($rr in @($done.Results)){$byId[[string]$rr.ItemId]=$rr}
            Check ($done.Stage -ceq 'Partial' -and $doneState.Stage -ceq 'Partial') 'Parent with a deferred group did not end Partial.'
            Check ($byId[$s.Ids[0]].Status -ceq 'Succeeded' -and $byId[$s.Ids[1]].Status -ceq 'Deferred' -and $byId[$s.Ids[1]].Error -ceq 'CredentialDeferred') 'Service group did not finish while the task group ended Deferred / CredentialDeferred.'
            Check (($script:adapterLog -join ',') -ceq 'DefSvcA') 'The deferred task reached the adapter.'
            Check ((@(Get-DefIntentItems $s) -join ',') -ceq $s.Ids[0] -and @($doneState.PendingOperations).Count -eq 0 -and @($doneState.Items|Where-Object ItemId -CEQ $s.Ids[1]).Count -eq 0) 'The deferred task wrote an intent or a state item.'
            $opts=@(Get-WsmWizardTargetItemOptions ([pscustomobject]@{Plan=$s.Package.Plan}) ([pscustomobject]@{ManifestHash=$manifestHash}) $doneState);$optBy=@{};foreach($o in $opts){$optBy[$o.value]=$o}
            Check ($optBy[$s.Ids[0]].restored -eq $true -and $optBy[$s.Ids[1]].restored -eq $false) 'restored must include the Service and exclude the deferred task.'
            Reject {Defer-Refs $s @('SvcSecret')} 'Deferral was accepted after the parent finished.'

            # ---- 2. defer everything: no input requested, other items still restore.
            Reset-Fixture
            $s=New-DefScenario @(@{Name='DefSvcB';Spec=(New-DefServiceSpec 'DefSvcB' 'SvcSecretB' 'CONTOSO\svc-app')},@{Name='DefPlainFeature';Spec=[pscustomobject]@{Adapter='SmbShare';Desired=[pscustomobject]@{Name='DefPlainShare'}}})
            $w=Invoke-DefScenario $s @{};Check ($w.Status -ceq 'WaitingForInput' -and $w.RequiredSecretRefs.Count -eq 1) 'All-deferred scenario did not first wait for the single group.'
            $all=Defer-Refs $s @('SvcSecretB');Check ($all.AllDeferred -eq $true) 'Deferring the only group did not report AllDeferred.'
            $done=Invoke-DefScenario $s @{}
            $byId=@{};foreach($rr in @($done.Results)){$byId[[string]$rr.ItemId]=$rr}
            Check ($done.Stage -ceq 'Partial' -and $byId[$s.Ids[0]].Status -ceq 'Deferred' -and $byId[$s.Ids[1]].Status -ceq 'Succeeded') 'With every group deferred, the other items did not finish and the parent did not end Partial.'
            Check (($script:adapterLog -join ',') -ceq 'DefPlainShare' -and @(Get-DefIntentItems $s).Count -eq 1) 'The all-deferred run touched the deferred group or skipped the plain item.'

            # ---- 3. a refused password with the target still absent returns to WaitingForInput.
            Reset-Fixture
            $s=New-DefScenario @(@{Name='RejSvcA';Spec=(New-DefServiceSpec 'RejSvcA' 'RejSecretA' 'CONTOSO\svc-a')},@{Name='RejSvcB';Spec=(New-DefServiceSpec 'RejSvcB' 'RejSecretB' 'CONTOSO\svc-b')})
            $null=Invoke-DefScenario $s @{}
            $script:rejectNames=@('RejSvcB')
            $back=Invoke-DefScenario $s @{RejSecretA=(New-DefPassword 'CONTOSO\svc-a' 'REJ-A');RejSecretB=(New-DefPassword 'CONTOSO\svc-b' 'REJ-B1')}
            $st=Read-WsmJson $s.Paths.State;$reqB=@($st.AssistiveServiceChallenge.Requirements|Where-Object SecretRef -CEQ 'RejSecretB')[0]
            Check ($back.Status -ceq 'WaitingForInput' -and (@($back.RequiredSecretRefs) -join ',') -ceq 'RejSecretB' -and $st.Stage -ceq 'WaitingForInput' -and $st.RestoreAttempt.Status -ceq 'WaitingForInput' -and $st.AssistiveServiceChallenge.State -ceq 'WaitingForInput') 'A refused password did not return the parent to WaitingForInput for that group only.'
            Check (@($st.PendingOperations).Count -eq 0 -and $reqB.Attempts -eq 1 -and $reqB.LastFailure -ceq 'CredentialRejected' -and $reqB.Deferred -eq $false) 'Refusal left a pending intent or did not record attempts=1 / LastFailure.'
            $backReq=@($back.CredentialRequirements|Where-Object SecretRef -CEQ 'RejSecretB')[0];Check ($backReq.Attempts -eq 1 -and $backReq.LastFailure -ceq 'CredentialRejected') 'The returned requirement lacks attempts / LastFailure.'
            $itemA=@($st.Items|Where-Object ItemId -CEQ $s.Ids[0]);Check ($itemA.Count -eq 1 -and $itemA[0].Status -ceq 'Succeeded' -and @($st.Items|Where-Object ItemId -CEQ $s.Ids[1]).Count -eq 0) 'The already completed item was not kept (or the refused one was recorded).'
            $script:rejectNames=@();$script:adapterLog=@()
            $done=Invoke-DefScenario $s @{RejSecretB=(New-DefPassword 'CONTOSO\svc-b' 'REJ-B2')}
            $st=Read-WsmJson $s.Paths.State
            Check (($script:adapterLog -join ',') -ceq 'RejSvcB' -and $done.Stage -ceq 'Succeeded' -and @($done.Results|Where-Object Status -CEQ 'Succeeded').Count -eq 2) 'After the corrected password only the refused item ran and the parent did not finish Succeeded.'
            Check ($st.AssistiveServiceChallenge.State -ceq 'Completed') 'The challenge did not complete after the corrected password.'

            # a first call that already carries the credential (no earlier wait) also returns to WaitingForInput after a refusal
            Reset-Fixture
            $s=New-DefScenario @(@{Name='DirSvc';Spec=(New-DefServiceSpec 'DirSvc' 'DirSecret' 'CONTOSO\svc-dir')});$script:rejectNames=@('DirSvc')
            $d1=Invoke-DefScenario $s @{DirSecret=(New-DefPassword 'CONTOSO\svc-dir' 'DIR-1')};$st=Read-WsmJson $s.Paths.State
            Check ($d1.Status -ceq 'WaitingForInput' -and $st.AssistiveServiceChallenge.State -ceq 'WaitingForInput' -and $st.Stage -ceq 'WaitingForInput' -and @($st.PendingOperations).Count -eq 0 -and (@($d1.CredentialRequirements)[0].Attempts) -eq 1) 'A refusal on a call without a prior challenge did not create the waiting challenge.'
            $script:rejectNames=@();$d2=Invoke-DefScenario $s @{DirSecret=(New-DefPassword 'CONTOSO\svc-dir' 'DIR-2')}
            Check ($d2.Stage -ceq 'Succeeded') 'The corrected password did not finish a challenge created by a refusal.'

            # ---- 4. refusal but the target now exists: unknown handling, no new password request.
            Reset-Fixture
            $s=New-DefScenario @(@{Name='UnkSvc';Spec=(New-DefServiceSpec 'UnkSvc' 'UnkSecret' 'CONTOSO\svc-u')})
            $null=Invoke-DefScenario $s @{}
            $script:rejectNames=@('UnkSvc');$script:flipOnThrow=$true
            $unk=Invoke-DefScenario $s @{UnkSecret=(New-DefPassword 'CONTOSO\svc-u' 'UNK')}
            $st=Read-WsmJson $s.Paths.State
            Check ($unk.Stage -ceq 'Partial' -and @($st.PendingOperations).Count -eq 1 -and $unk.Results[0].Status -ceq 'Failed' -and $script:adapterLog.Count -eq 1) 'A refusal with an existing target must keep the pending intent and not wait for a password again.'
            Check ($st.AssistiveServiceChallenge.State -ceq 'Completed' -and @($st.AssistiveServiceChallenge.Requirements|Where-Object {$_.Attempts -gt 0}).Count -eq 0) 'Unknown handling recorded a credential attempt.'
            $unk2=$null;try{Invoke-DefScenario $s @{UnkSecret=(New-DefPassword 'CONTOSO\svc-u' 'UNK2')}|Out-Null}catch{$unk2=$_}
            Check ($null -ne $unk2 -and $script:adapterLog.Count -eq 1) 'A second submission re-applied the item after an unknown failure.'
            # A non-refusal error is also unknown.
            Reset-Fixture
            $s=New-DefScenario @(@{Name='OtherSvc';Spec=(New-DefServiceSpec 'OtherSvc' 'OtherSecret' 'CONTOSO\svc-o')})
            $null=Invoke-DefScenario $s @{}
            Set-Item Function:\Invoke-WsmAdapterRestore -Value {param($Spec,$Secrets,$Package,$InstallerBaseline,$BeforeFolderCreate,$AfterFolderCreate,$OwnedReceipts,$SharedReceipts,$Workspace,$OperationId)$script:adapterLog+=@([string]$Spec.Desired.Name);throw (New-Object System.ComponentModel.Win32Exception 5)}
            $oth=Invoke-DefScenario $s @{OtherSecret=(New-DefPassword 'CONTOSO\svc-o' 'OTHER')};$st=Read-WsmJson $s.Paths.State
            Check ($oth.Stage -ceq 'Partial' -and @($st.PendingOperations).Count -eq 1) 'Access denied was treated as a refused password.'
            Set-Item Function:\Invoke-WsmAdapterRestore -Value {param($Spec,$Secrets,$Package,$InstallerBaseline,$BeforeFolderCreate,$AfterFolderCreate,$OwnedReceipts,$SharedReceipts,$Workspace,$OperationId)
                $name=[string]$Spec.Desired.Name;$script:adapterLog+=@($name)
                if($script:rejectNames -contains $name){if($script:flipOnThrow){$script:existsNow[$name]=$true};throw (New-Object System.ComponentModel.Win32Exception 1326)}
                [pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}}

            # ---- 5. third refusal of one group defers it automatically; the rest finishes.
            Reset-Fixture
            $s=New-DefScenario @(@{Name='LimSvcA';Spec=(New-DefServiceSpec 'LimSvcA' 'LimSecretA' 'CONTOSO\svc-la')},@{Name='LimSvcB';Spec=(New-DefServiceSpec 'LimSvcB' 'LimSecretB' 'CONTOSO\svc-lb')})
            $null=Invoke-DefScenario $s @{};$script:rejectNames=@('LimSvcB')
            $r1=Invoke-DefScenario $s @{LimSecretA=(New-DefPassword 'CONTOSO\svc-la' 'LIM-A');LimSecretB=(New-DefPassword 'CONTOSO\svc-lb' 'LIM-B1')}
            Check ($r1.Status -ceq 'WaitingForInput' -and (@($r1.CredentialRequirements|Where-Object SecretRef -CEQ 'LimSecretB')[0].Attempts) -eq 1) 'First refusal did not wait with attempts=1.'
            $r2=Invoke-DefScenario $s @{LimSecretB=(New-DefPassword 'CONTOSO\svc-lb' 'LIM-B2')}
            Check ($r2.Status -ceq 'WaitingForInput' -and (@($r2.CredentialRequirements|Where-Object SecretRef -CEQ 'LimSecretB')[0].Attempts) -eq 2) 'Second refusal did not wait with attempts=2.'
            $callsBeforeThird=$script:adapterLog.Count
            $r3=Invoke-DefScenario $s @{LimSecretB=(New-DefPassword 'CONTOSO\svc-lb' 'LIM-B3')}
            $st=Read-WsmJson $s.Paths.State;$byId=@{};foreach($rr in @($r3.Results)){$byId[[string]$rr.ItemId]=$rr}
            Check ($r3.Stage -ceq 'Partial' -and $st.Stage -ceq 'Partial') 'The third refusal did not end the parent Partial.'
            Check ($byId[$s.Ids[0]].Status -ceq 'Succeeded' -and $byId[$s.Ids[1]].Status -ceq 'Deferred' -and $byId[$s.Ids[1]].Error -ceq 'CredentialRejectedLimit') 'The limit did not defer the refused group (reason CredentialRejectedLimit) and keep the finished item.'
            Check ($script:adapterLog.Count -eq $callsBeforeThird+1 -and @($st.PendingOperations).Count -eq 0) 'Limit handling re-ran items or left a pending intent.'
            $limReq=@($st.AssistiveServiceChallenge.Requirements|Where-Object SecretRef -CEQ 'LimSecretB')[0]
            Check ($limReq.Deferred -eq $true -and $limReq.DeferReason -ceq 'CredentialRejectedLimit' -and $limReq.Attempts -eq 3 -and $st.AssistiveServiceChallenge.State -ceq 'Completed') 'The limit state was not recorded durably.'
            Check (-not [string]::IsNullOrWhiteSpace([string]$r3.CredentialNotice) -and [string]$r3.CredentialNotice -ceq (Get-WsmAssistiveCredentialLimitNotice)) 'The result does not explain the retry limit.'

            # ---- 6. CLI: DEFER per group, recorded durably, then the same parent continues; a refused password loops back.
            Reset-Fixture
            $s=New-DefScenario @(@{Name='CliSvc';Spec=(New-DefServiceSpec 'CliSvc' 'CliSvcSecret' 'CONTOSO\svc-cli')},@{Name='CliTask';Spec=(New-DefTaskSpec 'CliTask' 'CliTaskSecret' 'CONTOSO\batch')})
            $cliWaiting=Invoke-DefScenario $s @{}
            $originalReadValue=(Get-Command Read-WsmWizardValue -CommandType Function).ScriptBlock;$originalInvokeTarget=(Get-Command Invoke-WsmWizardTargetRestore -CommandType Function).ScriptBlock
            try{
                $script:cliPrompts=@();$script:cliCredentialMessages=@();$script:cliInvocations=@()
                Set-Item Function:\Read-WsmWizardValue -Value {param([string]$Label,[switch]$Optional)$script:cliPrompts+=@($Label);if($script:cliPrompts.Count -eq 2){'DEFER'}else{''}}
                Set-Item Function:\Get-Credential -Value {param([string]$Message,[string]$UserName)$script:cliCredentialMessages+=@($Message);New-DefPassword $UserName 'CLI-PASSWORD'}
                Set-Item Function:\Invoke-WsmWizardTargetRestore -Value {param($Workspace,$PairId,$PreviewHash,$CancellationToken,$Secrets,$GeneralHostEvidence,$OperationId,$ChallengeContext)$script:cliInvocations+=@(,@($Secrets.Keys|Sort-Object));if($script:cliInvocations.Count -eq 1){[pscustomobject]@{Status='WaitingForInput';ParentOperationId=$OperationId;PreviewHash=$PreviewHash;RequiredSecretRefs=@('CliSvcSecret');CredentialRequirements=@([pscustomobject]@{SecretRef='CliSvcSecret';Kinds=@('Service');ItemIds=@('x');DisplayNames=@('CliSvc');ApprovedAccount='CONTOSO\svc-cli';Deferred=$false;LastFailure='CredentialRejected';Attempts=1});CredentialNotice=''}}else{[pscustomobject]@{Stage='Partial';CredentialNotice=''}}}
                $cliFinal=Resolve-WsmWizardServiceChallenge -WaitingResult $cliWaiting -WorkRoot $root -StateDirectory $root -PairId $s.Pair -OperationId $s.Op -CancellationToken $s.Token -GeneralHostEvidence @() -ChallengeContext $s.Context
                Check ($cliFinal.Stage -ceq 'Partial' -and $script:cliInvocations.Count -eq 2) 'The CLI did not loop back to the credential prompt after a refused password.'
                Check ((@($script:cliInvocations[0]) -join ',') -ceq 'CliSvcSecret' -and (@($script:cliInvocations[1]) -join ',') -ceq 'CliSvcSecret') 'The CLI sent a credential for the deferred group.'
                Check (@($script:cliPrompts|Where-Object {$_ -match 'DEFER'}).Count -eq $script:cliPrompts.Count -and $script:cliPrompts.Count -eq 3) 'The CLI prompt does not explain DEFER for every group (expected 2 groups, then 1 on the retry).'
                $cliState=Read-WsmJson $s.Paths.State;$cliTaskReq=@($cliState.AssistiveServiceChallenge.Requirements|Where-Object SecretRef -CEQ 'CliTaskSecret')[0]
                Check ($cliTaskReq.Deferred -eq $true -and $cliTaskReq.DeferReason -ceq 'CredentialDeferred' -and @($cliState.AssistiveServiceChallenge.Requirements|Where-Object {$_.SecretRef -ceq 'CliSvcSecret' -and $_.PSObject.Properties['Deferred'] -and $_.Deferred}).Count -eq 0) 'CLI DEFER was not recorded durably for exactly the deferred group.'
                Check (@($script:cliCredentialMessages).Count -eq 2) 'The CLI asked for a credential for the deferred group.'
            }finally{
                Set-Item Function:\Read-WsmWizardValue -Value $originalReadValue;Set-Item Function:\Invoke-WsmWizardTargetRestore -Value $originalInvokeTarget
                if(Test-Path Function:\Get-Credential){Remove-Item Function:\Get-Credential -ErrorAction SilentlyContinue}
            }

            # ---- 7. no password sentinel in any durable file.
            $leaks=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force|Where-Object {[IO.File]::ReadAllText($_.FullName) -match 'SYNTHETIC'})
            Check ($leaks.Count -eq 0) ('Synthetic secret sentinel found in durable test output: '+(@($leaks|ForEach-Object Name) -join ', '))
            Write-Host ('PASS: '+$script:checks+' credential deferral, refusal classification and retry-limit checks.')
        } catch {
            $script:deferralFailure=$_
            throw
        } finally {
            foreach($n in $names){try{Set-Item ('Function:\'+$n) -Value $originals[$n]}catch{Write-Warning ('Could not restore '+$n+': '+$_.Exception.Message)}}
        }
    } $root
} catch {
    $script:primaryFailure=$_
    throw
} finally {
    try{Remove-WsmDeferralTestRoot $root 'wsm-credential-deferral-'}catch{Write-Warning ('Test root cleanup failed: '+$_.Exception.Message)}
}
