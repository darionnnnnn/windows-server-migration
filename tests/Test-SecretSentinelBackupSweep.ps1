#requires -Version 5.1
# 16.6-12 (N8b): the single-secret sentinel sweep, widened to the outputs of a REAL one-click backup.
# The Source side runs the production backup chain (inventory -> core-sealed target-bound plan -> export -> package verification ->
# Directory delivery -> offline item results / report / guide -> independent copy and receipt) with a plan that contains
# credential-bearing items (Service, scheduled task, IIS pool; SecretRef rules of 17.39). The Target side then imports the delivery and
# drives the production TargetRestore credential-reply path (wait -> defer -> refuse -> corrected reply -> Partial) with ONE synthetic
# secret. Every output category must hold no trace of the secret (UTF-8, UTF-16LE, Base64, SHA256/SHA1/MD5 digests); then a test-side
# copy of one existing file per category, with the leak appended in the original / Base64 / digest / UTF-16LE form, must be found by name.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$backupScriptPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\WizardBackup.ps1'))
$commonPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'SecretSweep.Common.ps1'))
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path payload test.'}
$substCommand='subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"';cmd.exe /c $substCommand
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the sweep test.'}
$root=Join-Path ($driveLetter+':\') ('wsmwb-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$BackupScriptPath,$CommonPath)
        . $BackupScriptPath
        . $CommonPath
        $script:checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Get-HitNames($Sweep){@($Sweep.Hits|ForEach-Object {[IO.Path]::GetFileName($_.File)}|Sort-Object)}
        $script:backupFixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:backupFixtureFingerprint;Name='backup-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        # Only host qualification observations are substituted; export, verification, delivery, reports and payload bytes are production code.
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:backupFixtureInventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:backupFixtureInventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:backupFixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:backupFixtureInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}

        $secret='SYNTH-BACKUP-SWEEP-'+[Guid]::NewGuid().ToString('N')
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager-work';$consoleRoot=Join-Path $Root 'console-jobs'
        [void][IO.Directory]::CreateDirectory($consoleRoot)
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:backupFixtureFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:backupFixtureFingerprint=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        $sourceData=Join-Path $Root 'source-data';[void][IO.Directory]::CreateDirectory($sourceData)
        [IO.File]::WriteAllText((Join-Path $sourceData 'settings.ini'),'actual source bytes')
        [IO.File]::WriteAllText((Join-Path $sourceData 'second.txt'),'second source bytes')

        # ---- plan: one payload scope plus three credential-bearing items (17.39) ----------------------
        $taskXml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="Author"><UserId>CONTOSO\batch</UserId><LogonType>Password</LogonType></Principal></Principals><Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers><Settings><Enabled>true</Enabled><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy></Settings><Actions><Exec><Command>C:\Fixture\worker.exe</Command></Exec></Actions></Task>'
        $poolXml='<add name="SweepPool"><processModel identityType="SpecificUser" userName="CONTOSO\poolsvc" /></add>'
        $supplement=[pscustomobject][ordered]@{ServiceType='Win32OwnProcess';ErrorControl='Normal';LoadOrderGroup='';DelayedAutoStart=$false;FailureActions=[pscustomobject][ordered]@{ResetPeriodSeconds=0;RebootMessage='';Command='';Actions=@()};FailureActionsOnNonCrashFailures=$false;ServiceSidType='None';RequiredPrivileges=@();Environment=@();Triggers=@()}
        $fileItem=New-WsmItem $source.HostId Storage DataRoot 'Fixture settings folder' 'fixture-settings' @{Path=$sourceData}
        $svcItem=New-WsmItem $source.HostId Services Service 'SweepSvc' 'sweepsvc' @{Name='SweepSvc';Account='CONTOSO\svc-sweep'}
        $taskItem=New-WsmItem $source.HostId Tasks ScheduledTask 'SweepTask' '\sweep\sweeptask' @{TaskName='SweepTask';TaskPath='\Sweep\'}
        $poolItem=New-WsmItem $source.HostId Web IISPool 'SweepPool' 'sweeppool' @{Name='SweepPool'}
        $inventory=New-WsmInventory $source 1 @($fileItem,$svcItem,$taskItem,$poolItem);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:backupFixtureInventoryPath=$inventoryPath
        Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target'
        $fileSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceData;TargetPath=(Join-Path $Root 'restored');TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Isolated actual bytes test';BusinessChecks=@('Read back each source file')}
        $svcSpec=[pscustomobject]@{Adapter='Service';AccountMode='UserPassword';SecretRef='SweepSvcSecret';Owner='Fixture owner';Evidence='fixture-reviewed';DesiredFinalState='Automatic';Desired=[pscustomobject]@{Name='SweepSvc';Supplement=$supplement;DisplayName='Sweep service';BinaryPathName='C:\Fixture\service.exe';Account='CONTOSO\svc-sweep';Dependencies=@();Description='fixture'}}
        $taskSpec=[pscustomobject]@{Adapter='ScheduledTask';SecretRef='SweepTaskSecret';CatchUpPolicy='PreserveSourceSettings';Owner='Fixture owner';Evidence='fixture-reviewed';DesiredFinalState='Enabled';Desired=[pscustomobject]@{TaskName='SweepTask';TaskPath='\Sweep\';Xml=$taskXml;User='CONTOSO\batch';SecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';FolderSecurity=@([pscustomobject]@{Path='\';SecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';ExistingPolicy='VerifyExact'},[pscustomobject]@{Path='\Sweep\';SecuritySddl='O:SYG:SYD:(A;;FA;;;BA)';ExistingPolicy='CreateOnly'})}}
        $poolSpec=[pscustomobject]@{Adapter='IISPool';SecretRef='SweepPoolSecret';Owner='Fixture owner';Evidence='fixture-reviewed';DesiredFinalState='Enabled';Desired=[pscustomobject]@{Name='SweepPool';Xml=$poolXml}}
        $revision=0
        foreach($pair in @(@($fileItem,$fileSpec),@($svcItem,$svcSpec),@($taskItem,$taskSpec),@($poolItem,$poolSpec))){
            $specPath=Join-Path $Root ('spec-'+[Guid]::NewGuid().ToString('N')+'.json');Write-WsmJson $specPath $pair[1]
            Set-WsmMigrationSpec $managerRoot $catalog.PairId $pair[0].ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash $revision
            $revision++
        }
        Set-WsmDecision $managerRoot $catalog.PairId @($fileItem.ItemId,$svcItem.ItemId,$taskItem.ItemId,$poolItem.ItemId) Include 'Explicit fixture selection' $revision|Out-Null
        $revision++
        $planPath=Join-Path $Root 'approved-plan.json';$approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $revision 'ISOLATED-PILOT'
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        Check ($import.Status -ceq 'ImportedVerified' -and $import.PairId -ceq $catalog.PairId) 'Source did not import the actual core-sealed target-bound plan.'
        $pairId=[string]$catalog.PairId

        # ---- Source: the real one-click backup ----------------------------------------------------------
        $modeState=Get-WsmWizardState $sourceRoot $pairId Source
        [void](Set-WsmWizardState $sourceRoot $pairId Source $modeState.Revision ([pscustomobject]@{Mode='ItemByItem'}))
        $operationId=[Guid]::NewGuid().ToString('D')
        $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $pairId -PlanHash $approved.SHA256 -OperationId $operationId
        $result=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId $operationId -DeliveryMode Directory -VolumeBytes 0 -Jobs @() -CancellationToken $token
        Check ($result.Status -ceq 'Delivered' -and $result.CoreExport.Sealed -and $result.PackageTest.Valid -and $result.ItemResults.Status -ceq 'Generated' -and $result.OfflineReport.Status -ceq 'Generated') 'The one-click backup did not finish the real export, verification, delivery and offline reports.'
        $itemRows=@((Read-WsmJson $result.ItemResults.Path).Rows)
        Check (@($itemRows|Where-Object {$_.Status -ceq 'BackedUp'}).Count -eq 4 -and @($itemRows|Where-Object {$_.ReasonCode -ceq 'ConfigurationCaptured'}).Count -eq 3) 'The backup plan did not carry three configuration (credential-bearing) items next to the payload scope.'
        $attempt=(Get-WsmWizardBackupAttemptForOperation $sourceRoot $pairId (Read-WsmOutputProfile $sourceRoot) $operationId).Attempt
        Check ($attempt.OfflineGuide.Status -ceq 'Generated') 'The delivery did not carry an offline guide.'

        # ---- independent copy and receipt (17.47 / 17.80) --------------------------------------------------
        $backupOriginalMediaClass=(Get-Command Get-WsmIndependentCopyMediaClass -CommandType Function).ScriptBlock
        function script:Get-WsmIndependentCopyMediaClass {param($DestinationRoot)'Removable'}
        function Get-WsmIndependentCopyMediaClass {param($DestinationRoot)'Removable'}
        try {
            $copyDest=Join-Path $Root 'copy-dest';[void][IO.Directory]::CreateDirectory($copyDest)
            $copy=Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pairId -BackupOperationId $operationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $copyDest -Mode Copy
            Check ($copy.IndependentCopy.Status -ceq 'Verified' -and [IO.File]::Exists($copy.IndependentCopy.ReceiptPath)) 'The independent copy was not verified or has no receipt.'
        } finally {
            Set-Item -Path Function:\script:Get-WsmIndependentCopyMediaClass -Value $backupOriginalMediaClass
            Set-Item -Path Function:\Get-WsmIndependentCopyMediaClass -Value $backupOriginalMediaClass
        }

        # ---- Target: import the delivery, then the production credential-reply path with the synthetic secret ----
        $script:backupFixtureFingerprint=('b'*64)
        $deliveryRoot=[string]$result.Delivery.Directory
        $directoryImport=Import-WsmDirectoryDelivery -SummaryPath $result.Delivery.Path -ExpectedSummaryHash $result.Delivery.SHA256 -SourceDirectory $deliveryRoot -WorkRoot $targetRoot
        $package=Test-WsmMigrationPackage $directoryImport.ManifestPath $directoryImport.ManifestHash
        $secretItems=@($package.Plan.Items|Where-Object {$_.MigrationSpec -and $_.MigrationSpec.PSObject.Properties['SecretRef'] -and $_.MigrationSpec.SecretRef})
        Check ($secretItems.Count -eq 3) 'The imported sealed plan does not hold the three credential-bearing items.'
        $ids=@($secretItems|ForEach-Object {[string]$_.ItemId})
        $names='Get-WsmAssistiveRestoreDecision','Assert-WsmAssistiveReceiptFresh','Get-WsmAssistiveReservations','Set-WsmAssistiveServiceReservationOperation','Register-WsmAssistivePackageMaterials','Complete-WsmAssistivePackageJob','Confirm-WsmOutputStateCheckpoint','Get-WsmAdapterState','Invoke-WsmAdapterRestore','Test-WsmAdapterConfiguration','Get-WsmAdapterObjectIdentity','Set-WsmAssistiveReservationEvidence','Get-WsmTaskSecurityReceiptsForSpec'
        $originals=@{};foreach($n in $names){$originals[$n]=(Get-Command $n -CommandType Function).ScriptBlock}
        try {
            # Same host-boundary doubles as Test-CredentialDeferral / Test-SecretSentinelSweep; the credential challenge, deferral and journal are production code.
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
                $name=[string]$Spec.Desired.Name;if($Spec.Adapter -ceq 'ScheduledTask'){$name=[string]$Spec.Desired.TaskName};$script:adapterLog+=@($name)
                if($script:rejectNames -contains $name){throw (New-Object System.ComponentModel.Win32Exception 1326)}
                [pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}}
            Set-Item Function:\Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,$SecurityReceipts)[pscustomobject]@{Passed=$true;Problems=@();Actual=[pscustomobject]@{Name=[string]$Spec.Desired.Name}}}
            Set-Item Function:\Get-WsmAdapterObjectIdentity -Value {param($Spec)[string]$Spec.Adapter+':'+[string]$Spec.SecretRef}
            Set-Item Function:\Set-WsmAssistiveReservationEvidence -Value {param($Reservations,$Item,$Package,$Prior,$Desired,$Readback,$Undo,[string]$Workspace)}
            $script:adapterLog=@();$script:rejectNames=@()
            $manifest=$package.Manifest;$restorePair=[string]$manifest.PairId;$restoreOp=[Guid]::NewGuid().ToString('D');$previewHash='d'*64
            $script:challengeDecision=[pscustomobject]@{Decision='RestoreNow';ReceiptPath=(Join-Path $targetRoot 'decision.json');ReceiptHash=('e'*64);SnapshotPath=(Join-Path $targetRoot 'snapshot.json');SelectedItemIds=@($ids);Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=('f'*64)}}
            $preview=[pscustomobject]@{Rows=@($ids|ForEach-Object {[pscustomobject]@{ItemId=$_;Status='Ready'}});SelectedItemIds=@($ids);WizardPreviewHash=$previewHash}
            $restoreToken=New-WsmCancellationToken -PairId $restorePair -PlanHash ([string]$package.PlanHash) -ManifestHash ([string]$directoryImport.ManifestHash) -OperationId $restoreOp -StateDirectory $targetRoot
            $context=[pscustomobject]@{Role='Target';Actor='S-1-5-18@FIXTURE';SessionId='fixture-session';ContextId='fixture-context';Revision=9;OperationId=$restoreOp}
            function New-SweepPassword([string]$Account){New-Object Management.Automation.PSCredential($Account,(ConvertTo-SecureString $secret -AsPlainText -Force))}
            function Invoke-SweepRestore([hashtable]$Secrets){Invoke-WsmAssistiveRestore -Package $package -ManifestHash ([string]$directoryImport.ManifestHash) -StateDirectory $targetRoot -Secrets $Secrets -SidMap @{} -CancellationToken $restoreToken -GeneralHostEvidence @() -ReceiptPath $script:challengeDecision.ReceiptPath -ReceiptHash $script:challengeDecision.ReceiptHash -TargetSnapshotPath $script:challengeDecision.SnapshotPath -Preview $preview -ParentOperationId $restoreOp -ChallengeContext $context}
            $waiting=Invoke-SweepRestore @{}
            Check ($waiting.Status -ceq 'WaitingForInput' -and $waiting.RequiredSecretRefs.Count -eq 3) 'The restore did not wait for all three credential groups.'
            [void](Set-WsmAssistiveCredentialDeferral -StateDirectory $targetRoot -PairId $restorePair -ParentOperationId $restoreOp -PreviewHash $previewHash -SecretRefs @('SweepTaskSecret','SweepPoolSecret'))
            $script:rejectNames=@('SweepSvc')
            $refused=Invoke-SweepRestore @{SweepSvcSecret=(New-SweepPassword 'CONTOSO\svc-sweep')}
            Check ($refused.Status -ceq 'WaitingForInput' -and @($refused.CredentialRequirements|Where-Object SecretRef -CEQ 'SweepSvcSecret')[0].Attempts -eq 1) 'A refused credential did not return to WaitingForInput.'
            $script:rejectNames=@()
            $finished=Invoke-SweepRestore @{SweepSvcSecret=(New-SweepPassword 'CONTOSO\svc-sweep')}
            Check ($finished.Stage -ceq 'Partial') 'The corrected credential did not finish the parent as Partial (task and pool groups deferred).'
            Check (($script:adapterLog -join ',') -ceq 'SweepSvc,SweepSvc') 'Adapter call pattern is not refuse-then-accept for the service group only.'
        } finally {
            foreach($n in $names){try{Set-Item ('Function:\'+$n) -Value $originals[$n]}catch{Write-Warning ('Could not restore '+$n+': '+$_.Exception.Message)}}
        }
        # Console job record (shape of Test-HtmlConsole records), written through the product JSON writer, carrying the real backup and restore outputs.
        $consoleRecord=[pscustomobject]@{jobId=$restoreOp;action='TargetRestore';idempotencyKey=[Guid]::NewGuid().ToString('D');RequestHash=('d'*64);workspace=$targetRoot;pairId=$restorePair;role='Target';sessionId='fixture-session';contextId='fixture-context';status='Succeeded';StartedUtc=(Get-WsmUtc);CompletedUtc=(Get-WsmUtc);canCancel=$false;targetRestorePreviewHash=$previewHash;outputs=@([pscustomobject]@{Status=[string]$finished.Stage;Backup=$result})}
        Write-WsmJson (Join-Path $consoleRoot ($restoreOp+'.json')) $consoleRecord

        # ---- output categories -------------------------------------------------------------------------------
        $guideFiles=@([string]$attempt.OfflineGuide.Path,[string]$attempt.OfflineGuide.TextPath)
        $deliveryIndexFiles=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -Filter 'delivery-index*.json'|ForEach-Object FullName)
        Check ($deliveryIndexFiles.Count -ge 1) 'The backup produced no delivery index file.'
        $categories=[ordered]@{
            'source-workspace'=@($sourceRoot)
            'target-workspace'=@($targetRoot)
            'progress'=@(Join-Path (Get-WsmWizardBackupRoot $sourceRoot $pairId) 'progress')
            'item-results'=@([string]$result.ItemResults.Path)
            'offline-report'=@([string]$result.OfflineReport.Path)
            'offline-guide'=$guideFiles
            'delivery-folder'=@($deliveryRoot)
            'delivery-descriptor'=@([string]$result.Delivery.Path)
            'delivery-index'=$deliveryIndexFiles
            'independent-copy'=@([string]$copy.IndependentCopy.CopyRoot)
            'receipt'=@([string]$copy.IndependentCopy.ReceiptPath)
            'console-jobs'=@($consoleRoot)
        }
        $sweepRoots=@($sourceRoot,$targetRoot,$copyDest,$consoleRoot)
        $categoryFiles=[ordered]@{}
        foreach($category in $categories.Keys){
            $files=New-Object 'System.Collections.Generic.List[string]'
            foreach($path in $categories[$category]){
                if([IO.File]::Exists($path)){$files.Add([IO.Path]::GetFullPath($path))}
                elseif([IO.Directory]::Exists($path)){foreach($f in @(Get-ChildItem -LiteralPath $path -Recurse -File -Force)){$files.Add($f.FullName)}}
                else{throw ('Output category '+$category+' names a path that does not exist: '+$path)}
            }
            Check ($files.Count -ge 1) ('Output category '+$category+' holds no file, so a clean sweep would prove nothing.')
            $categoryFiles[$category]=@($files.ToArray())
        }

        # ---- positive: no trace of the secret in any category ------------------------------------------------------
        $positive=Invoke-SecretSweep $sweepRoots $secret
        $allFiles=@($sweepRoots|ForEach-Object {Get-ChildItem -LiteralPath $_ -Recurse -File -Force}|ForEach-Object FullName)
        Check ($positive.FileCount -eq $allFiles.Count -and $positive.FileCount -gt 0) ('The sweep did not visit every file: scanned '+$positive.FileCount+' of '+$allFiles.Count)
        foreach($category in $categoryFiles.Keys){foreach($f in $categoryFiles[$category]){Check ($allFiles -contains $f) ('A '+$category+' file lies outside the swept roots: '+$f)}}
        $perCategory=@(foreach($category in $categoryFiles.Keys){$category+'='+$categoryFiles[$category].Count}) -join ' '
        Check ($positive.Hits.Count -eq 0) ('Secret found in backup/restore output: '+(@($positive.Hits|ForEach-Object {$_.File+' ['+($_.Encodings -join ',')+']'}) -join '; '))

        # ---- negative controls: test-side copy of one existing file per category + appended leak ------------------
        $utf8Bytes=[Text.Encoding]::UTF8.GetBytes($secret)
        $b64=[Convert]::ToBase64String($utf8Bytes)
        $sha=[Security.Cryptography.SHA256]::Create();try{$digest=[BitConverter]::ToString($sha.ComputeHash($utf8Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $variants=@(
            @{Tag='raw';Text=("`r`nleak password="+$secret+"`r`n");Expect='UTF-8'},
            @{Tag='b64';Text=("`r`nleak cred="+$b64+"`r`n");Expect='Base64@0'},
            @{Tag='sha256';Text=("`r`nleak digest="+$digest+"`r`n");Expect='SHA256-hex-lower(UTF-8)'},
            @{Tag='utf16';Text='';Bytes=[Text.Encoding]::Unicode.GetBytes("`r`nleak wide="+$secret+"`r`n");Expect='UTF-16LE'})
        $planted=@()
        foreach($category in $categoryFiles.Keys){
            # Pick the smallest real file of the category that is not itself one of the other categories' planted copies.
            $existing=@($categoryFiles[$category]|Sort-Object {(New-Object IO.FileInfo($_)).Length},{$_})[0]
            foreach($variant in $variants){
                $copyName=[IO.Path]::GetFileNameWithoutExtension($existing)+'.n8b-leak-'+$category+'-'+$variant.Tag+[IO.Path]::GetExtension($existing)
                $copyPath=Join-Path ([IO.Path]::GetDirectoryName($existing)) $copyName
                [IO.File]::Copy($existing,$copyPath,$false)
                $stream=[IO.File]::Open($copyPath,[IO.FileMode]::Append,[IO.FileAccess]::Write);try{$leakBytes=$(if($variant.ContainsKey('Bytes')){$variant.Bytes}else{[Text.Encoding]::UTF8.GetBytes($variant.Text)});$stream.Write($leakBytes,0,$leakBytes.Length)}finally{$stream.Dispose()}
                $planted+=,[pscustomobject]@{Category=$category;Variant=$variant.Tag;Path=$copyPath;Name=$copyName;Expect=$variant.Expect}
            }
        }
        $negative=Invoke-SecretSweep $sweepRoots $secret
        Check ($negative.Hits.Count -eq $planted.Count) ('Negative sweep hit count '+$negative.Hits.Count+' is not the planted count '+$planted.Count+': '+((Get-HitNames $negative) -join ','))
        Check (((@($negative.Hits|ForEach-Object {$_.File}|Sort-Object)) -join '|') -ceq ((@($planted|ForEach-Object {$_.Path}|Sort-Object)) -join '|')) 'Sweep did not report exactly the planted copies.'
        foreach($plant in $planted){
            $hit=@($negative.Hits|Where-Object {$_.File -ceq $plant.Path})
            Check ($hit.Count -eq 1 -and ($hit[0].Encodings -contains $plant.Expect)) ('Negative control '+$plant.Name+' ('+$plant.Category+'/'+$plant.Variant+') was not detected as '+$plant.Expect+'.')
        }
        Check ($negative.FileCount -eq $positive.FileCount+$planted.Count) 'Negative sweep did not count the planted copies.'
        foreach($plant in $planted){[IO.File]::Delete($plant.Path)}
        $after=Invoke-SecretSweep $sweepRoots $secret
        Check ($after.Hits.Count -eq 0 -and $after.FileCount -eq $positive.FileCount) 'Sweep after removing the planted copies is not clean.'
        Write-Host ('SWEEP: scanned '+$positive.FileCount+' files (positive) / '+$negative.FileCount+' files (with '+$planted.Count+' planted copies) under '+$sweepRoots.Count+' roots')
        Write-Host ('SWEEP categories (files): '+$perCategory)
        Write-Host ('PASS: '+$script:checks+' single-secret sentinel sweep over a real one-click backup (Source and Target workspaces, progress, item results, offline report and guide, delivery folder and index, independent copy and receipt, console jobs) with raw, Base64 and digest negative controls per category.')
    } $root $backupScriptPath $commonPath
} finally {
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmwb-*'){throw 'Unsafe cleanup path.'}
    try{Remove-Item -LiteralPath $full -Recurse -Force}catch{Write-Warning ('Test root cleanup failed: '+$_.Exception.Message)}
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
