#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$runtimePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\WizardRuntime.ps1'))
$evidenceFixturePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-recovery-'+[Guid]::NewGuid().ToString('N').Substring(0,10))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$RuntimePath,$EvidenceFixturePath)
        . $RuntimePath
        . $EvidenceFixturePath
        $script:checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
        $script:recoveryFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:recoveryFingerprint;Name='recovery-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        $sourceRoot=Join-Path $Root 'source';$targetRoot=Join-Path $Root 'target';$managerRoot=Join-Path $Root 'manager'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:recoveryFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:recoveryFingerprint=('a'*64);$source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='recovery-fixture-source'}
        $dataRoot=Join-Path $Root 'data';[void][IO.Directory]::CreateDirectory($dataRoot);[IO.File]::WriteAllText((Join-Path $dataRoot 'payload.txt'),'fixture bytes')
        $fileItem=New-WsmItem $source.HostId Storage DataRoot 'Recovery fixture files' 'recovery-files' @{Path=$dataRoot}
        $inventory=New-WsmInventory $source 1 @($fileItem);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory
        $script:recoveryInventoryPath=$inventoryPath
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);[pscustomobject]@{Path=$script:recoveryInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:recoveryInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        Initialize-WsmWorkspace $managerRoot|Out-Null;$catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'recovery-target'
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$dataRoot;TargetPath=(Join-Path $Root 'restored');TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Narrow recovery test';BusinessChecks=@('Read back fixture bytes')}
        $spec|Add-Member NoteProperty SharedResourceImpacts @([pscustomobject]@{ResourceKind='IISPool';ResourceItemId='fixture-shared-pool';ConsumerItemIds=@('fixture-consumer-one','fixture-consumer-two');RequiresSharedReview=$true;OwnerReviewReason='Fixture shared resource review.'}) -Force
        $specPath=Join-Path $Root 'spec.json';Write-WsmJson $specPath $spec;Set-WsmMigrationSpec $managerRoot $catalog.PairId $fileItem.ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash 0|Out-Null
        Set-WsmDecision $managerRoot $catalog.PairId @($fileItem.ItemId) Include 'Fixture selection' 1|Out-Null
        $planPath=Join-Path $Root 'plan.json';$approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath 2 'ISOLATED-PILOT'
        $script:recoveryFingerprint=('a'*64);$null=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        $profile=Read-WsmOutputProfile $sourceRoot;$planRef=Get-WsmWizardCurrentApprovedPlan $sourceRoot $catalog.PairId $profile $null @();$plan=$planRef.Plan
        $wizardState=Get-WsmWizardState $sourceRoot $catalog.PairId Source;Set-WsmWizardState $sourceRoot $catalog.PairId Source $wizardState.Revision ([pscustomobject]@{Mode='Automatic'})|Out-Null
        $backupRoot=Get-WsmWizardBackupRoot $sourceRoot $catalog.PairId;$opId=[Guid]::NewGuid().ToString('D');$attemptId=$opId
        $freezeOwner='Fixture freeze owner';$freezeEvidenceText='No source producer is in the fixture plan; synthetic external writer evidence remains fixture-only.';$freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $plan -PlanHash $planRef.SHA256 -Root $Root -Owner $freezeOwner
        $pairsRoot=Join-Path $sourceRoot 'pairs';$token=New-WsmCancellationToken -StateDirectory $pairsRoot -PairId $catalog.PairId -PlanHash $planRef.SHA256 -OperationId $opId
        $script:recoveryToken=$token;$script:recoveryOriginalFreeze=(Get-Command Export-WsmFreezeRecord -CommandType Function).ScriptBlock
        function script:Export-WsmFreezeRecord {
            [CmdletBinding(SupportsShouldProcess)]param([string]$PlanPath,[string]$ExpectedHash,[string]$Path,[string]$Owner,[string]$Evidence,[Parameter(Mandatory)][string]$Acknowledgement,[switch]$SourceIdentityReleased,[string]$ReleaseEvidence,[ValidateRange(1,48)][int]$ValidHours=4,[Parameter(Mandatory)][string]$SourceStateDirectory,[string]$PreviousFreezePath,[string]$PreviousFreezeHash,[string]$PreviousAttemptPath,[string]$PreviousAttemptHash,[Parameter(Mandatory)][string]$FreezeExternalEvidencePath,[Parameter(Mandatory)][string]$FreezeExternalEvidenceHash,[string]$FreezeEpoch)
            $result=& $script:recoveryOriginalFreeze @PSBoundParameters
            Request-WsmCancellation -Token $script:recoveryToken -Owner 'Fixture worker' -Evidence 'Cancel after real core freeze, before core export'|Out-Null
            $result
        }
        $cancelled=$false;$cancelError='';try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $opId -Owner $freezeOwner -Evidence $freezeEvidenceText -FreezeAuthorization -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -Jobs @() -CancellationToken $token -DeliveryMode Zip -VolumeBytes 536870912|Out-Null}catch{$cancelled=$true;$cancelError=$_.Exception.ToString()}
        Set-Item -Path Function:\script:Export-WsmFreezeRecord -Value $script:recoveryOriginalFreeze
        $backupPath=Join-Path $backupRoot ($attemptId+'.json');$backup=Read-WsmJson $backupPath
        Check ($cancelled -and $backup.Stage -ceq 'Cancelled' -and $backup.FreezeAttemptStarted -and $backup.Freeze -and $backup.SourceResumeRequired) ('A cancellation after a real core freeze did not preserve a recovery-needed result. '+$cancelError)
        $backupJob=[pscustomobject]@{jobId=$opId;action='StartBackup';status='Cancelled';role='Source';workspace=[IO.Path]::GetFullPath($sourceRoot);pairId=$catalog.PairId;outputs=@([pscustomobject]@{AttemptId=$attemptId})}
        $sealedImpactPreview=Get-WsmWizardBackupImpactPreview -Workspace $sourceRoot -PairId $catalog.PairId -Jobs @($backupJob)
        Check (@($sealedImpactPreview.SharedImpact|Where-Object {$_.Source -ceq 'Approved plan SharedResourceImpacts'}).Count -eq 1) ('The real approved-plan SharedResourceImpacts consumer did not flatten bounded rows with its provenance field. PlanSpec='+(ConvertTo-Json -InputObject $plan.Items[0].MigrationSpec.SharedResourceImpacts -Depth 8 -Compress)+' Rows='+(ConvertTo-Json -InputObject $sealedImpactPreview.SharedImpact -Depth 8 -Compress))
        $outputRoot=[string]$backup.OutputRoot;$receiptPath=Join-Path $outputRoot 'source-freeze.json';$pairsRoot=Join-Path $sourceRoot 'pairs'
        $freezeReceipt=Read-WsmFreezeRecord $receiptPath ([string]$backup.Freeze.SHA256) $plan $planRef.SHA256;$sourceAttemptPath=[string]$freezeReceipt.SourceAttemptPath;$sourceAttemptHash=[string]$freezeReceipt.SourceAttemptHash;$sourceAttempt=Read-WsmSourceAttempt $sourceAttemptPath $sourceAttemptHash $plan $planRef.SHA256
        # Simulate the worker dying after the core receipt is durably written
        # but before the WizardBackup attempt records its Freeze reference.
        $receiptRaw=[IO.File]::ReadAllText($receiptPath)
        Remove-Item -LiteralPath $receiptPath -Force
        $crashRuntime=Get-WsmWizardRuntimeSource $sourceRoot $catalog.PairId $profile @($backupJob)
        $crashStart=@($crashRuntime.actions|Where-Object id -ceq 'StartBackup'|Select-Object -First 1);$crashResume=@($crashRuntime.actions|Where-Object id -ceq 'SourceResume'|Select-Object -First 1)
        Check ($crashStart.Count -eq 1 -and -not $crashStart[0].available -and $crashResume.Count -eq 1 -and $crashResume[0].available -and $crashRuntime.sourceFreeze.resumeRoute.sourceAttemptPath -ceq $sourceAttemptPath) 'A worker crash after the durable FreezeAttemptStarted marker but before receipt writeback did not locate the unique owned attempt.'
        [IO.File]::WriteAllText($receiptPath,$receiptRaw,(New-Object Text.UTF8Encoding($false)))
        $backup.Freeze=[pscustomobject]@{Path=$receiptPath;SHA256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()};Write-WsmJson $backupPath $backup
        $runtime=Get-WsmWizardRuntimeSource $sourceRoot $catalog.PairId $profile @($backupJob)
        $available=Get-WsmWizardBackupAvailability $sourceRoot $catalog.PairId $profile @($backupJob)
        Check ($null -ne $available -and $available.attempt.Stage -ceq 'Cancelled') 'Real backup availability did not surface the cancelled job whose durable source freeze requires recovery.'
        $start=@($runtime.actions|Where-Object id -ceq 'StartBackup'|Select-Object -First 1);$resume=@($runtime.actions|Where-Object id -ceq 'SourceResume'|Select-Object -First 1)
        Check ($start.Count -eq 1 -and $start[0].available -and $resume.Count -eq 1 -and $resume[0].available -and $runtime.sourceFreeze.resumeAvailable -and -not $runtime.sourceFreeze.resumeRequired) 'A verified, fresh Frozen attempt must allow optional SourceResume and same-attempt StartBackup.'
        Check ($sourceAttempt.State.Status -ceq 'Frozen') 'Runtime read triggered SourceResume automatically.'
        $html=ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{sourceFreeze=$runtime.sourceFreeze;unknownSensitive='private-token'})
        Check ($html.sourceFreeze.resumeAvailable -and $html.sourceFreeze.resumeRoute.sourceAttemptPath -ceq $sourceAttemptPath -and -not $html.PSObject.Properties['unknownSensitive']) 'Safe HTML runtime projection lost resume fields or exposed an unknown sensitive property.'
        $receipt=Read-WsmJson $receiptPath;$receipt.ProducedUtc=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o');$receipt.ExpiresUtc=[DateTimeOffset]::UtcNow.AddHours(-1).ToString('o');Write-WsmJson $receiptPath $receipt;$backup.Freeze.SHA256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();Write-WsmJson $backupPath $backup
        $expired=Get-WsmWizardRuntimeSource $sourceRoot $catalog.PairId $profile @($backupJob)
        $expiredStart=@($expired.actions|Where-Object id -ceq 'StartBackup'|Select-Object -First 1);$expiredResume=@($expired.actions|Where-Object id -ceq 'SourceResume'|Select-Object -First 1)
        Check ($expiredStart.Count -eq 1 -and -not $expiredStart[0].available -and $expiredResume.Count -eq 1 -and $expiredResume[0].available -and $expired.sourceFreeze.resumeRequired) 'An expired but verifiable receipt must permit recovery guidance while blocking continuation of the old final backup.'
        $blocked=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId ([Guid]::NewGuid().ToString('D')) -Owner $backup.FreezeOwner -Evidence $backup.FreezeEvidence -FreezeAuthorization -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -Jobs @($backupJob)|Out-Null}catch{$blocked=$true}
        Check $blocked 'StartBackup accepted a stale/expired freeze continuation.'
        $secondFreezeFolder=Join-Path $pairsRoot ('freeze-'+$catalog.PairId+'-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($secondFreezeFolder)
        $secondBaseline=Join-Path $secondFreezeFolder 'baseline.json';Write-WsmJson $secondBaseline $inventory
        $secondAttempt=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceFreezeAttempt';AttemptId=[Guid]::NewGuid().ToString('D');PairId=$catalog.PairId;ApprovalId=$plan.ApprovalId;PlanHash=$planRef.SHA256;SourceFingerprint=$profile.Fingerprint;BaselinePath=$secondBaseline;BaselineHash=(Get-FileHash -LiteralPath $secondBaseline -Algorithm SHA256).Hash.ToLowerInvariant();Items=@();ShareBaselines=@();ShareQuiescence=@();Status='Interrupted';Owner=$backup.FreezeOwner;Evidence=$backup.FreezeEvidence;Utc=(Get-WsmUtc)}
        $secondAttemptPath=Join-Path $secondFreezeFolder 'attempt.json';Write-WsmJson $secondAttemptPath $secondAttempt
        Remove-Item -LiteralPath $receiptPath -Force
        $backup.Freeze=$null;Write-WsmJson $backupPath $backup
        $ambiguous=Get-WsmWizardRuntimeSource $sourceRoot $catalog.PairId $profile @($backupJob)
        $ambiguousStart=@($ambiguous.actions|Where-Object id -ceq 'StartBackup'|Select-Object -First 1);$ambiguousResume=@($ambiguous.actions|Where-Object id -ceq 'SourceResume'|Select-Object -First 1)
        Check ($ambiguousStart.Count -eq 1 -and -not $ambiguousStart[0].available -and $ambiguousResume.Count -eq 1 -and -not $ambiguousResume[0].available -and $ambiguous.sourceFreeze.manualReviewRequired -and $ambiguous.sourceFreeze.manualReviewReason -match '多份.*無法自動選擇') 'Ambiguous crash recovery candidates were guessed instead of requiring manual review.'
        Remove-Item -LiteralPath $secondAttemptPath -Force;Write-WsmJson $receiptPath $receipt; $backup.Freeze=[pscustomobject]@{Path=$receiptPath;SHA256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()};Write-WsmJson $backupPath $backup

        $resumeProof=New-WsmSourceResumeEvidenceFixture -Plan $plan -PlanHash $planRef.SHA256 -AttemptId $sourceAttempt.State.AttemptId -AttemptHash $sourceAttemptHash -Root $Root -Owner $freezeOwner
        $resumeAnswers=@{
            '選擇操作情境角色'='1';'選配對編號'='1';'輸入完整操作識別碼'='SourceResume';
            'PlanPath'=$planRef.Path;'ExpectedHash'=$planRef.SHA256;'SourceAttemptPath'=$sourceAttemptPath;'SourceAttemptHash'=$sourceAttemptHash;
            'SourceStateDirectory'=$pairsRoot;'Owner'=$freezeOwner;'OwnershipEvidence'='Fixture confirms target stopped and writes reconciled.';
            'Acknowledgement'=('SOURCE-OWNERSHIP-RESTORED '+$catalog.PairId);'ResumeExternalEvidencePath'=$resumeProof.Path;'ResumeExternalEvidenceHash'=$resumeProof.SHA256;
            'TaskReconciliationPath'='';'TaskReconciliationHash'='';'APPLY'='APPLY'
        }
        $resumeReader={param($prompt) foreach($key in @($resumeAnswers.Keys|Sort-Object Length -Descending)){if(([string]$prompt).Contains([string]$key)){return [string]$resumeAnswers[$key]}};throw ('Unexpected SourceResume prompt: '+$prompt)}.GetNewClosure()
        $resumeResult=Invoke-WsmTypedTextOperation -Workspace $sourceRoot -PromptReader $resumeReader
        $resumeJobs=@(Get-WsmTextWizardJobs $sourceRoot $catalog.PairId 'Source')
        $resumeJob=@($resumeJobs|Where-Object {$_.action -ceq 'SourceResume' -and $_.status -ceq 'Succeeded'}|Select-Object -First 1)
        $resumedAttemptHash=(Get-FileHash -LiteralPath $sourceAttemptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Check ($resumeJob.Count -eq 1 -and @($resumeJob[0].outputs|Where-Object {$_.Path -ieq $sourceAttemptPath -and $_.SHA256 -ieq $resumedAttemptHash}).Count -eq 1) ('The real typed-text SourceResume consumer did not persist a successful job with exact path/SHA output. JobFiles='+(Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'console-jobs') -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) } | Out-String)+' Jobs='+(ConvertTo-Json -InputObject @($resumeJobs) -Depth 8 -Compress))
        $resumedRuntime=Get-WsmWizardRuntimeSource $sourceRoot $catalog.PairId $profile (@($backupJob)+$resumeJobs)
        $resumedStart=@($resumedRuntime.actions|Where-Object id -ceq 'StartBackup'|Select-Object -First 1);$resumedResume=@($resumedRuntime.actions|Where-Object id -ceq 'SourceResume')
        Check ($resumeResult.Status -ceq 'Applied' -and $resumeResult.Executed -and @($resumeResult.Result|Where-Object Status -ceq 'SourceResumed').Count -eq 1 -and $resumedRuntime.sourceFreeze.sourceResumed -and $resumedStart.Count -eq 1 -and $resumedStart[0].available -and $resumedResume.Count -eq 0) 'A hash-crosschecked real SourceResume result did not unlock a new backup attempt or still offered repeat recovery.'
        $backup.SourceResumeRequired=$false;$backup | Add-Member NoteProperty SourceResumed $true -Force;$backup | Add-Member NoteProperty SourceResumeFreshFreezePending $true -Force;$backup | Add-Member NoteProperty SourceAttemptPath $sourceAttemptPath -Force;$backup | Add-Member NoteProperty SourceAttemptHash $resumedAttemptHash -Force;Write-WsmJson $backupPath $backup
        $staleRejected=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId ([Guid]::NewGuid().ToString('D')) -Owner $freezeOwner -Evidence 'Must reject pre-resume readiness.' -FreezeAuthorization -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -Jobs (@($backupJob)+$resumeJobs)|Out-Null}catch{$staleRejected=$true}
        Check ($staleRejected -and (Read-WsmJson $backupPath).SourceResumeFreshFreezePending -and @(Get-ChildItem -LiteralPath $backupRoot -Filter '*.json' -File).Count -eq 1) 'A crash-persisted SourceResumed handoff marker allowed stale FreezeReady evidence or lost its gate before the next backup was durable.'
        $newFreezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $plan -PlanHash $planRef.SHA256 -Root $Root -Owner $freezeOwner
        $newOperationId=[Guid]::NewGuid().ToString('D');$cancelToken=New-WsmCancellationToken -StateDirectory $pairsRoot -PairId $catalog.PairId -PlanHash $planRef.SHA256 -OperationId $newOperationId;Request-WsmCancellation -Token $cancelToken -Owner $freezeOwner -Evidence 'Stop before the newly authorized freeze starts.'|Out-Null
        $startBlockedByCancel=$false;$startFailure='';try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $newOperationId -Owner $freezeOwner -Evidence 'New post-resume freeze authorization.' -FreezeAuthorization:$true -FreezeExternalEvidencePath $newFreezeProof.Path -FreezeExternalEvidenceHash $newFreezeProof.SHA256 -Jobs (@($backupJob)+$resumeJobs) -DeliveryMode Zip -VolumeBytes 536870912 -CancellationToken $cancelToken|Out-Null}catch{$startBlockedByCancel=$true;$startFailure=$_.Exception.ToString()}
        $newAttemptPath=Join-Path $backupRoot ($newOperationId+'.json')
        $newExists=[IO.File]::Exists($newAttemptPath);$newRecord=$null;if($newExists){$newRecord=Read-WsmJson $newAttemptPath};Check ($startBlockedByCancel -and $newExists -and $newRecord.AttemptId -cne $attemptId -and $newRecord.FreezeEpoch -cne $backup.FreezeEpoch) ('SourceResumed did not create a separate new backup/output attempt with a new freeze epoch before the injected pre-freeze cancellation. caught='+$startBlockedByCancel+' exists='+$newExists+' owner='+$freezeOwner+' readinessPath='+$newFreezeProof.Path+' readinessHash='+$newFreezeProof.SHA256+' readinessOwner='+$newFreezeProof.Evidence.Owner+' failure='+$startFailure)
        $oldAfterHandoff=Read-WsmJson $backupPath;$oldAfterHandoff.SourceResumeFreshFreezePending=$true;Write-WsmJson $backupPath $oldAfterHandoff
        $selectedAttempt=Get-WsmWizardBackupAttempt $sourceRoot $catalog.PairId $profile $planRef.SHA256
        Check ($selectedAttempt -and $selectedAttempt.Attempt.AttemptId -ceq $newOperationId) 'A crash after writing the new attempt but before clearing the old handoff marker left two unfinished backup records instead of following the exact child lineage.'
        $oldAfterHandoff=Read-WsmJson $backupPath;$oldAfterHandoff.SourceResumeFreshFreezePending=$false;Write-WsmJson $backupPath $oldAfterHandoff
        $childAfterHandoff=Read-WsmJson $newAttemptPath;$childAfterHandoff.Stage='Delivered';Write-WsmJson $newAttemptPath $childAfterHandoff
        Check ($null -eq (Get-WsmWizardBackupAttempt $sourceRoot $catalog.PairId $profile $planRef.SHA256)) 'A completed SourceResumed parent resurfaced as a resumable attempt after the new child reached a terminal delivered stage.'
        $childAfterHandoff.Stage='Cancelled';Write-WsmJson $newAttemptPath $childAfterHandoff
        $oldAttemptHashBeforeReplay=(Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant();$oldReplay=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $opId -Jobs (@($backupJob)+$resumeJobs)
        Check ($oldReplay.AttemptId -ceq $attemptId -and (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $oldAttemptHashBeforeReplay) 'Replaying the old operation ID did not return its original durable attempt unchanged after SourceResumed.'

        $pool=New-WsmItem $profile.HostId Web IISPool 'Fixture shared pool' 'DefaultAppPool' @{Xml='<applicationPool name="DefaultAppPool" autoStart="true" />'}
        $siteOne=New-WsmItem $profile.HostId Web IISSite 'Fixture site one' 'Site One' @{Xml='<site name="Site One"><application path="/" applicationPool="DefaultAppPool" /></site>'}
        $siteTwo=New-WsmItem $profile.HostId Web IISSite 'Fixture site two' ('Site Two '+('x'*8100)) @{Xml='<site name="Site Two"><application path="/" applicationPool="DefaultAppPool" /></site>'}
        $sharedInventory=New-WsmInventory $source 2 @($pool,$siteOne,$siteTwo)
        $sharedPlan=[pscustomobject]@{InventoryHash='';InventoryRevision=2;Source=$source;Items=@([pscustomobject]@{ItemId=$pool.ItemId;Decision='Include'},[pscustomobject]@{ItemId=$siteOne.ItemId;Decision='Include'},[pscustomobject]@{ItemId=$siteTwo.ItemId;Decision='Exclude'})}
        $impact=[pscustomobject]@{ResourceKind='IISPool';ResourceItemId=$pool.ItemId;ConsumerItemIds=@()}
        $impactRows=@(Get-WsmWizardBackupSharedImpactRows $pool.ItemId $pool.NaturalKey $impact $sharedInventory $sharedPlan)
        Check ($impactRows.Count -eq 2 -and @($impactRows|Where-Object Impact -match 'Site One.*本次已選').Count -eq 1 -and @($impactRows|Where-Object Impact -match 'Site Two.*本次未選').Count -eq 1) 'Shared pool impact did not name both consumers and disclose the unselected site.'
        Check (@($impactRows|Where-Object {$_.Impact -match 'consumer name truncated'}).Count -eq 1 -and @($impactRows|Where-Object {$_.Impact.Length -ge 8192}).Count -eq 0) 'Long per-consumer text was silently truncated by the HTML string bound.'
        $inventoryDirectory=Join-Path (Join-Path (Join-Path $sourceRoot ('hosts\'+$profile.Fingerprint)) 'inventory') ''
        $sharedInventoryPath=Join-Path $inventoryDirectory 'inventory-2.json';Write-WsmJson $sharedInventoryPath $sharedInventory
        $sharedPlan.InventoryHash=(Get-FileHash -LiteralPath $sharedInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $goodInventoryJob=[pscustomobject]@{jobId=[Guid]::NewGuid().ToString('D');action='Inventory';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;outputs=@([pscustomobject]@{Path=$sharedInventoryPath;SHA256=$sharedPlan.InventoryHash})}
        $trusted=Get-WsmWizardBackupTrustedInventory $sourceRoot $profile $sharedPlan @($goodInventoryJob)
        Check ($trusted -and $trusted.Revision -eq $sharedPlan.InventoryRevision -and $trusted.Source.HostId -ceq $profile.HostId) 'A truly hash-, revision-, and host-bound inventory observation was not accepted by the shared impact helper.'
        $wrongInventoryJob=[pscustomobject]@{jobId=[Guid]::NewGuid().ToString('D');action='Inventory';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;outputs=@([pscustomobject]@{Path=$sharedInventoryPath;SHA256=('0'*64)})}
        $untrusted=Get-WsmWizardBackupTrustedInventory $sourceRoot $profile $sharedPlan @($wrongInventoryJob)
        $unknownImpact=@(Get-WsmWizardBackupSharedImpactRows $pool.ItemId $pool.NaturalKey $impact $untrusted $sharedPlan)
        $unknownSafe=ConvertTo-WsmWizardHtmlValue @($unknownImpact)
        Check ($null -eq $untrusted -and $unknownImpact.Count -eq 1 -and $unknownImpact[0] -isnot [array] -and $unknownImpact[0].Impact -match '未能核對.*重新盤點' -and $unknownSafe[0].Impact -match '未能核對.*重新盤點') 'Shared impact claimed a complete consumer set without a hash-consistent host/revision-bound inventory observation or produced a nested array instead of a safe row.'
        Write-Host ('PASS: narrow SourceResume recovery contract ('+$script:checks+' assertions).')
    } $root $runtimePath $evidenceFixturePath
} finally { if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force} }
