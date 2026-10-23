#requires -Version 5.1
# 16.6 last row: single secret-sentinel sweep with a negative control.
# The sweep walks EVERY file under the workspace and console roots and looks for one synthetic secret as
# UTF-8, UTF-16LE and Base64 (three byte alignments). A positive run (credential wait -> submit -> defer ->
# refuse -> continue) must find nothing; deliberately planting the secret in a log file and a job record in each
# encoding must be found by name, otherwise the sweep itself is broken.
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-secret-sweep-'+[Guid]::NewGuid().ToString('N'))
function Assert-WsmSweepTestRoot([string]$Path){
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92,[char]47)
    $full=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetDirectoryName($full);$leaf=[IO.Path]::GetFileName($full)
    if(-not [string]::Equals($parent,$temp,[StringComparison]::OrdinalIgnoreCase) -or $leaf -notmatch '^wsm-secret-sweep-[0-9a-f]{32}$'){throw 'Refusing cleanup outside the expected direct temporary test root.'}
    if([IO.Directory]::Exists($full)){$item=Get-Item -LiteralPath $full -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing cleanup of a reparse-point test root.'}}
    return $full
}
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Generated sweep test root unexpectedly already exists.'}
[void](Assert-WsmSweepTestRoot $root)
$commonPath=Join-Path $PSScriptRoot 'SecretSweep.Common.ps1';$workspaceRoot=Join-Path $root 'workspace';$consoleRoot=Join-Path $root 'console-jobs'
[void][IO.Directory]::CreateDirectory($workspaceRoot);[void][IO.Directory]::CreateDirectory($consoleRoot)
try {
    & $module {
        param($workspaceRoot,$consoleRoot,$commonPath)
        $script:checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}

        # ---- shared sweep ------------------------------------------------------------------
        . $commonPath
        function Get-HitNames($Sweep){@($Sweep.Hits|ForEach-Object {[IO.Path]::GetFileName($_.File)}|Sort-Object)}

        # ---- scenario: the credential wait / submit / defer / refuse / continue flow (fixtures as in Test-CredentialDeferral) ----
        $secret='SYNTH-SWEEP-'+[Guid]::NewGuid().ToString('N')
        $names='Get-WsmAssistiveRestoreDecision','Assert-WsmAssistiveReceiptFresh','Get-WsmAssistiveReservations','Set-WsmAssistiveServiceReservationOperation','Register-WsmAssistivePackageMaterials','Complete-WsmAssistivePackageJob','Confirm-WsmOutputStateCheckpoint','Get-WsmAdapterState','Invoke-WsmAdapterRestore','Test-WsmAdapterConfiguration','Get-WsmAdapterObjectIdentity','Set-WsmAssistiveReservationEvidence','Get-WsmTaskSecurityReceiptsForSpec'
        $originals=@{};foreach($n in $names){$originals[$n]=(Get-Command $n -CommandType Function).ScriptBlock}
        try {
            $planHash='b'*64;$manifestHash='a'*64;$fingerprint='c'*64;$previewHash='d'*64
            Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value {param($Package,[string]$ManifestHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$SnapshotPath)$script:challengeDecision}
            Set-Item Function:\Assert-WsmAssistiveReceiptFresh -Value {param($Package,$Decision)$true}
            Set-Item Function:\Get-WsmAssistiveReservations -Value {param($Item,$Package,[string]$Workspace,[switch]$PreviewOnly,[string]$OperationId,[string]$OperationState)[pscustomobject]@{Preview=[pscustomobject]@{ResourceKey=('1'*64)};Reservation=[pscustomobject]@{Reserved=$true};Existing=$false}}
            Set-Item Function:\Set-WsmAssistiveServiceReservationOperation -Value {param([string]$Workspace,[string]$ResourceKey,[string]$PairId,[string]$ItemId,[string]$OperationId,[string]$State)}
            Set-Item Function:\Register-WsmAssistivePackageMaterials -Value {param($Package,$Decision,[string]$Workspace,$Preview)[pscustomobject]@{OperationId='fixture-material-job';MaterialIds=@()}}
            Set-Item Function:\Complete-WsmAssistivePackageJob -Value {param($Package,$Job,[string]$Workspace)}
            Set-Item Function:\Confirm-WsmOutputStateCheckpoint -Value {param([string]$StateDirectory,[string]$PairId,[string]$PlanHash)}
            Set-Item Function:\Get-WsmTaskSecurityReceiptsForSpec -Value {param($Spec,[object[]]$Receipts)@()}
            Set-Item Function:\Get-WsmAdapterState -Value {param($Spec)[pscustomobject]@{Exists=$false;Name='';Actual=$null}}
            Set-Item Function:\Invoke-WsmAdapterRestore -Value {param($Spec,$Secrets,$Package,$InstallerBaseline,$BeforeFolderCreate,$AfterFolderCreate,$OwnedReceipts,$SharedReceipts,$Workspace,$OperationId)
                $name=[string]$Spec.Desired.Name;$script:adapterLog+=@($name)
                if($script:rejectNames -contains $name){throw (New-Object System.ComponentModel.Win32Exception 1326)}
                [pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}}
            Set-Item Function:\Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,$SecurityReceipts)[pscustomobject]@{Passed=$true;Problems=@();Actual=[pscustomobject]@{Name=[string]$Spec.Desired.Name}}}
            Set-Item Function:\Get-WsmAdapterObjectIdentity -Value {param($Spec)[string]$Spec.Desired.Name}
            Set-Item Function:\Set-WsmAssistiveReservationEvidence -Value {param($Reservations,$Item,$Package,$Prior,$Desired,$Readback,$Undo,[string]$Workspace)}
            $script:adapterLog=@();$script:rejectNames=@()

            function New-SweepTaskSpec([string]$Name,[string]$Ref,[string]$Account){$xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="Author"><UserId>'+$Account+'</UserId><LogonType>Password</LogonType></Principal></Principals></Task>';[pscustomobject]@{Adapter='ScheduledTask';SecretRef=$Ref;CatchUpPolicy='SkipMissedRuns';Desired=[pscustomobject]@{TaskName=$Name;TaskPath='\';Xml=$xml;User=$Account}}}
            function New-SweepServiceSpec([string]$Name,[string]$Ref,[string]$Account){[pscustomobject]@{Adapter='Service';AccountMode='UserPassword';SecretRef=$Ref;Owner='Fixture owner';Desired=[pscustomobject]@{Name=$Name;Account=$Account;BinaryPathName='C:\Fixture\service.exe';Dependencies=@();Supplement=[pscustomobject]@{}}}}
            function New-SweepPassword([string]$Account){New-Object Management.Automation.PSCredential($Account,(ConvertTo-SecureString $secret -AsPlainText -Force))}
            $pairId=[Guid]::NewGuid().ToString('D');$opId=[Guid]::NewGuid().ToString('D');$items=@();$ids=@()
            foreach($d in @(@{Name='SweepSvc';Spec=(New-SweepServiceSpec 'SweepSvc' 'SweepSvcSecret' 'CONTOSO\svc-sweep')},@{Name='SweepTask';Spec=(New-SweepTaskSpec 'SweepTask' 'SweepTaskSecret' 'CONTOSO\batch')})){$id=Get-WsmHashText ('sweep-'+$d.Name+$pairId);$ids+=$id;$items+=[pscustomobject]@{ItemId=$id;Name=$d.Name;Kind='Fixture';Decision='Include';MigrationSpec=$d.Spec}}
            $package=[pscustomobject]@{Root=$workspaceRoot;PlanHash=$planHash;SHA256=$manifestHash;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($items)};Manifest=[pscustomobject]@{PairId=$pairId;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=7;DecisionRevision=9;Target=[pscustomobject]@{Fingerprint=$fingerprint}}}
            $script:challengeDecision=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $workspaceRoot 'decision.json');ReceiptHash=('e'*64);SnapshotPath=(Join-Path $workspaceRoot 'snapshot.json');SelectedItemIds=@($ids);Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=('f'*64)}}
            $preview=[pscustomobject]@{Rows=@($ids|ForEach-Object {[pscustomobject]@{ItemId=$_;Status='Ready'}});SelectedItemIds=@($ids);WizardPreviewHash=$previewHash}
            $token=New-WsmCancellationToken -PairId $pairId -PlanHash $planHash -ManifestHash $manifestHash -OperationId $opId -StateDirectory $workspaceRoot
            $context=[pscustomobject]@{Role='Target';Actor='S-1-5-18@FIXTURE';SessionId='fixture-session';ContextId='fixture-context';Revision=9;OperationId=$opId}
            function Invoke-SweepRestore([hashtable]$Secrets){Invoke-WsmAssistiveRestore -Package $package -ManifestHash $manifestHash -StateDirectory $workspaceRoot -Secrets $Secrets -SidMap @{} -CancellationToken $token -GeneralHostEvidence @() -ReceiptPath $script:challengeDecision.ReceiptPath -ReceiptHash $script:challengeDecision.ReceiptHash -TargetSnapshotPath $script:challengeDecision.SnapshotPath -Preview $preview -ParentOperationId $opId -ChallengeContext $context}

            $waiting=Invoke-SweepRestore @{}
            Check ($waiting.Status -ceq 'WaitingForInput' -and $waiting.RequiredSecretRefs.Count -eq 2) 'Scenario did not wait for both credential groups.'
            [void](Set-WsmAssistiveCredentialDeferral -StateDirectory $workspaceRoot -PairId $pairId -ParentOperationId $opId -PreviewHash $previewHash -SecretRefs @('SweepTaskSecret'))
            $script:rejectNames=@('SweepSvc')
            $refused=Invoke-SweepRestore @{SweepSvcSecret=(New-SweepPassword 'CONTOSO\svc-sweep')}
            Check ($refused.Status -ceq 'WaitingForInput' -and @($refused.CredentialRequirements|Where-Object SecretRef -CEQ 'SweepSvcSecret')[0].Attempts -eq 1) 'A refused credential did not return to WaitingForInput.'
            $script:rejectNames=@()
            $finished=Invoke-SweepRestore @{SweepSvcSecret=(New-SweepPassword 'CONTOSO\svc-sweep')}
            Check ($finished.Stage -ceq 'Partial') 'The corrected credential did not finish the parent as Partial (task group deferred).'
            Check (($script:adapterLog -join ',') -ceq 'SweepSvc,SweepSvc') 'Adapter call pattern is not refuse-then-accept for the service group only.'

            # Console job records: written through the product JSON writer in the console-jobs root, shaped like Test-HtmlConsole job records (no secret material by design).
            $consoleRecord=[pscustomobject]@{jobId=$opId;action='TargetRestore';idempotencyKey=[Guid]::NewGuid().ToString('D');RequestHash=('d'*64);workspace=$workspaceRoot;pairId=$pairId;role='Target';sessionId='fixture-session';contextId='fixture-context';status='Succeeded';StartedUtc=(Get-WsmUtc);CompletedUtc=(Get-WsmUtc);canCancel=$false;targetRestorePreviewHash=$previewHash;outputs=@([pscustomobject]@{Status=[string]$finished.Stage})}
            Write-WsmJson (Join-Path $consoleRoot ($opId+'.json')) $consoleRecord

            # ---- positive: the whole tree holds no trace of the secret --------------------------
            $roots=@($workspaceRoot,$consoleRoot)
            $positive=Invoke-SecretSweep $roots $secret
            $allNames=@(Get-ChildItem -LiteralPath $workspaceRoot,$consoleRoot -Recurse -File -Force|ForEach-Object Name)
            Check ($positive.FileCount -ge 4 -and $positive.FileCount -eq $allNames.Count) ('The sweep did not visit every file: scanned '+$positive.FileCount+' of '+$allNames.Count)
            Check (@($allNames|Where-Object {$_ -like '*.json'}).Count -ge 2 -and @($allNames|Where-Object {$_ -like '*.jsonl'}).Count -ge 1) 'The scenario produced no state/journal/job files, so a clean sweep would prove nothing.'
            Check ($positive.Hits.Count -eq 0) ('Secret found in durable output: '+(@($positive.Hits|ForEach-Object {$_.File+' ['+($_.Encodings -join ',')+']'}) -join '; '))

            # ---- negative controls: plant the secret in each encoding; the sweep must report each file by name ----
            $utf8Bytes=[Text.Encoding]::UTF8.GetBytes($secret)
            function Get-Base64Planted([int]$Shift){$filler=[Text.Encoding]::ASCII.GetBytes('xy'.Substring(0,$Shift));$buffer=New-Object byte[] ($filler.Length+$utf8Bytes.Length);[Array]::Copy($filler,0,$buffer,0,$filler.Length);[Array]::Copy($utf8Bytes,0,$buffer,$filler.Length,$utf8Bytes.Length);'cred='+[Convert]::ToBase64String($buffer)+' trailer'}
            $sha256=[Security.Cryptography.SHA256]::Create();$md5=[Security.Cryptography.MD5]::Create();$sha1=[Security.Cryptography.SHA1]::Create()
            try{$secretSha256=[BitConverter]::ToString($sha256.ComputeHash($utf8Bytes)).Replace('-','');$secretMd5=[BitConverter]::ToString($md5.ComputeHash($utf8Bytes)).Replace('-','');$secretSha1=[BitConverter]::ToString($sha1.ComputeHash($utf8Bytes)).Replace('-','');$secretSha256B64=[Convert]::ToBase64String($sha256.ComputeHash($utf8Bytes)).TrimEnd('=');$secretSha256Utf16=[BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::Unicode.GetBytes($secret))).Replace('-','')}finally{$sha256.Dispose();$md5.Dispose();$sha1.Dispose()}
            $planted=[ordered]@{
                'leak-utf8.log'=@{Dir=$workspaceRoot;Bytes=[Text.Encoding]::UTF8.GetBytes('2026-10-22 restore failed password='+$secret+"`r`n");Expect='UTF-8'}
                'leak-utf16.log'=@{Dir=$workspaceRoot;Bytes=[Text.Encoding]::Unicode.GetBytes("restore failed password="+$secret+"`r`n");Expect='UTF-16LE'}
                'leak-b64-a0.log'=@{Dir=$workspaceRoot;Bytes=[Text.Encoding]::ASCII.GetBytes((Get-Base64Planted 0));Expect='Base64@0'}
                'leak-b64-a1.json'=@{Dir=$consoleRoot;Bytes=[Text.Encoding]::ASCII.GetBytes('{"job":"'+(Get-Base64Planted 1)+'"}');Expect='Base64@1'}
                'leak-b64-a2.json'=@{Dir=$consoleRoot;Bytes=[Text.Encoding]::ASCII.GetBytes('{"job":"'+(Get-Base64Planted 2)+'"}');Expect='Base64@2'}
                'leak-job-utf8.json'=@{Dir=$consoleRoot;Bytes=[Text.Encoding]::UTF8.GetBytes((($consoleRecord|Add-Member NoteProperty leaked $secret -PassThru -Force)|ConvertTo-Json -Depth 6 -Compress));Expect='UTF-8'}
                'leak-sha256-lower.log'=@{Dir=$workspaceRoot;Bytes=[Text.Encoding]::UTF8.GetBytes('prefix='+$secretSha256.ToLowerInvariant()+';suffix');Expect='SHA256-hex-lower(UTF-8)'}
                'leak-sha256-upper.json'=@{Dir=$workspaceRoot;Bytes=[Text.Encoding]::UTF8.GetBytes('{"d":"'+$secretSha256+'"}');Expect='SHA256-hex-upper(UTF-8)'}
                'leak-md5.log'=@{Dir=$workspaceRoot;Bytes=[Text.Encoding]::UTF8.GetBytes($secretMd5.ToLowerInvariant());Expect='MD5-hex-lower(UTF-8)'}
                'leak-sha1.log'=@{Dir=$workspaceRoot;Bytes=[Text.Encoding]::UTF8.GetBytes('sha1='+$secretSha1.ToLowerInvariant());Expect='SHA1-hex-lower(UTF-8)'}
                'leak-sha256-b64.json'=@{Dir=$consoleRoot;Bytes=[Text.Encoding]::UTF8.GetBytes('{"h":"'+$secretSha256B64+'="}');Expect='SHA256-b64(UTF-8)'}
                'leak-sha256-utf16.log'=@{Dir=$workspaceRoot;Bytes=[Text.Encoding]::UTF8.GetBytes($secretSha256Utf16.ToLowerInvariant());Expect='SHA256-hex-lower(UTF-16LE)'}
            }
            foreach($leakName in $planted.Keys){[IO.File]::WriteAllBytes((Join-Path $planted[$leakName].Dir $leakName),$planted[$leakName].Bytes)}
            $negative=Invoke-SecretSweep $roots $secret
            Check (((Get-HitNames $negative) -join ',') -ceq (@($planted.Keys|Sort-Object) -join ',')) ('Sweep did not report exactly the planted files: '+((Get-HitNames $negative) -join ','))
            foreach($leakName in $planted.Keys){
                $hit=@($negative.Hits|Where-Object {[IO.Path]::GetFileName($_.File) -ceq $leakName})
                Check ($hit.Count -eq 1 -and ($hit[0].Encodings -contains $planted[$leakName].Expect) -and [IO.Path]::GetDirectoryName($hit[0].File) -ceq $planted[$leakName].Dir) ('Negative control '+$leakName+' was not detected as '+$planted[$leakName].Expect+'.')
            }
            Check ($negative.FileCount -eq $positive.FileCount+$planted.Count) 'Negative sweep did not count the planted files.'
            # Removing the planted files returns the tree to a clean sweep, so the hits above came from the plants and nothing else.
            foreach($leakName in $planted.Keys){[IO.File]::Delete((Join-Path $planted[$leakName].Dir $leakName))}
            $after=Invoke-SecretSweep $roots $secret
            Check ($after.Hits.Count -eq 0 -and $after.FileCount -eq $positive.FileCount) 'Sweep after removing the planted files is not clean.'
            Write-Host ('SWEEP: scanned '+$after.FileCount+' files (positive) / '+$negative.FileCount+' files (with '+$planted.Count+' planted) under: '+($roots -join ' ; '))
            Write-Host ('PASS: '+$script:checks+' single-secret sentinel sweep over workspace and console roots with UTF-8, UTF-16LE and Base64 negative controls and SHA256/SHA1/MD5 digest negative controls.')
        } finally {
            foreach($n in $names){try{Set-Item ('Function:\'+$n) -Value $originals[$n]}catch{Write-Warning ('Could not restore '+$n+': '+$_.Exception.Message)}}
        }
    } $workspaceRoot $consoleRoot $commonPath
} finally {
    try{$full=Assert-WsmSweepTestRoot $root;if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}}catch{Write-Warning ('Test root cleanup failed: '+$_.Exception.Message)}
}
