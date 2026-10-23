#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$backupScriptPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\WizardBackup.ps1'))
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path payload test.'}
$substCommand='subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"';cmd.exe /c $substCommand
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the payload test.'}
$root=Join-Path ($driveLetter+':\') ('wsmwb-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$BackupScriptPath)
        . $BackupScriptPath
        $outputDefaults=Get-WsmOutputProfileDefaults
        if($outputDefaults.Mode -cne 'Zip' -or [long]$outputDefaults.VolumeBytes -ne 536870912){throw 'New output preferences must default to ZIP with a 512 MiB volume limit.'}
        foreach($mib in @(128,512,1024)){Assert-WsmOutputProfileValues ([pscustomobject]@{Mode='Zip';VolumeBytes=([long]$mib*1048576)})}
        foreach($invalidBytes in @([long](127*1048576),[long](1024*1048576+1))){ $rejected=$false;try{Assert-WsmOutputProfileValues ([pscustomobject]@{Mode='Zip';VolumeBytes=$invalidBytes})}catch{$rejected=$true};if(-not $rejected){throw ('Invalid ZIP volume size was accepted: '+$invalidBytes)} }
        $script:backupFixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:backupFixtureFingerprint;Name='backup-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        # The test substitutes only host qualification observations. Inventory,
        # package export, package verification, delivery, and payload bytes use
        # the production implementations unchanged.
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:backupFixtureInventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:backupFixtureInventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:backupFixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:backupFixtureInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager-work'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:backupFixtureFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:backupFixtureFingerprint=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        $sourceData=Join-Path $Root 'source-data';[void][IO.Directory]::CreateDirectory($sourceData)
        [IO.File]::WriteAllText((Join-Path $sourceData 'settings.ini'),'actual source bytes')
        [IO.File]::WriteAllText((Join-Path $sourceData 'second.txt'),'second source bytes')
        $item=New-WsmItem $source.HostId Storage DataRoot 'Fixture settings folder' 'fixture-settings' @{Path=$sourceData}
        $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:backupFixtureInventoryPath=$inventoryPath
        Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target'
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceData;TargetPath=(Join-Path $Root 'restored');TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Isolated actual bytes test';BusinessChecks=@('Read back each source file')}
        $specPath=Join-Path $Root 'spec.json';Write-WsmJson $specPath $spec
        Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash 0
        Set-WsmDecision $managerRoot $catalog.PairId @($item.ItemId) Include 'Explicit fixture selection' 1|Out-Null
        $planPath=Join-Path $Root 'approved-plan.json';$approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath 2 'ISOLATED-PILOT'
        $script:backupFixtureFingerprint=('a'*64)
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        if($import.Status -cne 'ImportedVerified' -or $import.PairId -cne $catalog.PairId){throw 'Source did not import the actual core-sealed target-bound plan.'}
        $freezeRoot=Join-Path $sourceRoot 'pairs';$freezeBefore=@(Get-ChildItem -LiteralPath $freezeRoot -Directory -Filter ('freeze-'+$catalog.PairId+'-*') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName);$impact=Get-WsmWizardBackupImpactPreview -Workspace $sourceRoot -PairId $catalog.PairId -Jobs @()
        if($impact.Kind -cne 'WizardBackupImpactPreview' -or $impact.PairId -cne $catalog.PairId -or $impact.SourceHost.HostId -cne $sourceEnrollment.HostId -or $impact.FreezeRequired -or $impact.FreezeAuthorized -or $impact.SourceChanged -or $impact.QuiescenceDisclosure -notmatch 'No source freeze is required' -or @($impact.Producers).Count -ne 1 -or $impact.Producers[0].ItemId -cne $item.ItemId -or $impact.Producers[0].SourcePath -cne $sourceData){throw 'Read-only impact preview did not show the exact approved host and C producer without implying source change or freeze authorization.'}
        if($impact.Producers[0].ProducerQuiescedIfFreezeRuns){throw 'A plain immutable FileScope was incorrectly claimed to be an automatically stopped producer.'}
        $freezeAfter=@(Get-ChildItem -LiteralPath $freezeRoot -Directory -Filter ('freeze-'+$catalog.PairId+'-*') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName);if(@(Compare-Object $freezeBefore $freezeAfter).Count){throw 'Impact preview created or changed source freeze state.'}
        $startParameters=(Get-Command Invoke-WsmWizardStartBackup -CommandType Function).Parameters
        if($startParameters.ContainsKey('ConfirmQuiescence') -or -not $startParameters.ContainsKey('FreezeAuthorization') -or $startParameters['FreezeAuthorization'].SwitchParameter -ne $true){throw 'StartBackup does not require a separate typed freeze-authorization switch; ordinary backup confirmation could be mistaken for quiescence consent.'}
        $outputProfilePath=Join-Path (Join-Path $sourceRoot 'workspace-control') 'output-profile.json';$outputProfileHash=(Get-FileHash -LiteralPath $outputProfilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $modeState=Get-WsmWizardState $sourceRoot $catalog.PairId Source
        $modeState=Set-WsmWizardState $sourceRoot $catalog.PairId Source $modeState.Revision ([pscustomobject]@{Mode='Automatic'})
        $defaultPreview=Get-WsmWizardBackupImpactPreview -Workspace $sourceRoot -PairId $catalog.PairId
        if($defaultPreview.DeliveryMode -cne 'Zip' -or [long]$defaultPreview.VolumeBytes -ne 536870912){throw 'Default J2 ZIP preview did not follow Automatic mode with its 512 MiB per-attempt fallback.'}
        $automaticDirectoryOverride=Get-WsmWizardBackupImpactPreview -Workspace $sourceRoot -PairId $catalog.PairId -DeliveryMode Directory -VolumeBytes 0
        if($automaticDirectoryOverride.DeliveryMode -cne 'Directory' -or [long]$automaticDirectoryOverride.VolumeBytes -ne 0){throw 'Explicit Directory per-attempt override was not honored under Automatic/J2 mode.'}
        $modeState=Set-WsmWizardState $sourceRoot $catalog.PairId Source $modeState.Revision ([pscustomobject]@{Mode='ItemByItem'})
        $itemByItemPreview=Get-WsmWizardBackupImpactPreview -Workspace $sourceRoot -PairId $catalog.PairId
        if($itemByItemPreview.DeliveryMode -cne 'Directory' -or [long]$itemByItemPreview.VolumeBytes -ne 0){throw 'Default J1 Directory preview did not follow the actual wizard mode.'}
        foreach($badVolume in @(0,134217728.5,134217729,134217727,1073741825)){ $rejected=$false;try{Get-WsmWizardBackupImpactPreview -Workspace $sourceRoot -PairId $catalog.PairId -DeliveryMode Zip -VolumeBytes $badVolume|Out-Null}catch{$rejected=$true};if(-not $rejected){throw ('Preview accepted invalid ZIP volume '+$badVolume)} }
        $directoryPreview=Get-WsmWizardBackupImpactPreview -Workspace $sourceRoot -PairId $catalog.PairId -DeliveryMode Directory -VolumeBytes 0
        if($directoryPreview.DeliveryMode -cne 'Directory' -or [long]$directoryPreview.VolumeBytes -ne 0){throw 'Backup impact preview did not disclose the explicit Directory attempt format and zero volume limit.'}
        foreach($invalidChoice in @(@{Mode='Zip';Bytes=134217728.5},@{Mode='Directory';Bytes=1})){ $invalidOperation=[Guid]::NewGuid().ToString('D');$rejected=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $invalidOperation -DeliveryMode $invalidChoice.Mode -VolumeBytes $invalidChoice.Bytes|Out-Null}catch{$rejected=$true};$invalidAttemptPath=Join-Path (Get-WsmWizardBackupRoot $sourceRoot $catalog.PairId) ($invalidOperation+'.json');$invalidOutputPath=Join-Path (Join-Path (Join-Path (Join-Path $sourceRoot 'pairs') $catalog.PairId) 'attempts') $invalidOperation;if(-not $rejected -or [IO.File]::Exists($invalidAttemptPath) -or [IO.Directory]::Exists($invalidOutputPath)){throw ('Invalid per-attempt transport choice created durable state: '+$invalidChoice.Mode+'/'+$invalidChoice.Bytes)} }
        $operationId=[Guid]::NewGuid().ToString('D')
        $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $operationId
        Request-WsmCancellation -Token $token -Owner 'Fixture operator' -Evidence 'Exercise durable cancel before the first package write'|Out-Null
        $cancelled=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $operationId -Jobs @() -CancellationToken $token|Out-Null}catch{$cancelled=$true}
        $backupProfile=Read-WsmOutputProfile $sourceRoot;$attemptRoot=Get-WsmWizardBackupRoot $sourceRoot $catalog.PairId;$attemptFile=Join-Path $attemptRoot ($operationId+'.json')
        $cancelStage='missing';if([IO.File]::Exists($attemptFile)){$cancelStage=(Read-WsmJson $attemptFile).Stage}
        if(-not $cancelled -or -not [IO.File]::Exists($attemptFile) -or $cancelStage -cne 'Cancelled'){throw ('A pre-export cancellation did not persist its durable backup attempt as Cancelled. caught='+$cancelled+' stage='+$cancelStage)}
        $cancelledAttempt=Read-WsmJson $attemptFile;$cancelOutputAttempt=Read-WsmJson (Join-Path $cancelledAttempt.OutputRoot 'attempt.json')
        if($cancelledAttempt.DeliveryMode -cne 'Directory' -or [long]$cancelledAttempt.VolumeBytes -ne 0 -or $cancelOutputAttempt.Mode -cne 'Directory' -or [long]$cancelOutputAttempt.VolumeBytes -ne 0 -or (Get-FileHash -LiteralPath $outputProfilePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $outputProfileHash){throw 'Per-attempt Directory selection changed the shared profile or failed to freeze the selected delivery mode.'}
        $modeState=Get-WsmWizardState $sourceRoot $catalog.PairId Source;$modeState=Set-WsmWizardState $sourceRoot $catalog.PairId Source $modeState.Revision ([pscustomobject]@{Mode='Automatic'})
        $frozenPreview=Get-WsmWizardBackupImpactPreview -Workspace $sourceRoot -PairId $catalog.PairId
        if($frozenPreview.DeliveryMode -cne 'Directory' -or [long]$frozenPreview.VolumeBytes -ne 0){throw 'Changing J1 to J2 rewrote the frozen cancelled attempt format.'}
        Write-Host 'PASS: durable pre-export cancellation.'
        $retryOperationId=[Guid]::NewGuid().ToString('D');$retryToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $retryOperationId
        $script:backupFixtureFingerprint=('a'*64);$preRetryPlan=Get-WsmWizardReceivedApprovedPlan $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot);if(-not $preRetryPlan){$sourceProfile=Read-WsmOutputProfile $sourceRoot;$machineIdentity=Get-WsmMachineIdentity;throw ('Test fixture lost its source approval before retry. profile='+$sourceProfile.Fingerprint+' machine='+$machineIdentity.Fingerprint+' receiptCount='+@(Get-ChildItem -LiteralPath (Get-WsmWizardReceivedPlanRoot $sourceRoot) -Filter '*.json' -File).Count)}
        $originalPackageTest=(Get-Command Test-WsmMigrationPackage -CommandType Function).ScriptBlock
        $script:backupOriginalPackageTest=$originalPackageTest;$script:backupPackageTestCalls=0
        function script:Test-WsmMigrationPackage {param([string]$ManifestPath,[string]$ExpectedHash,$CancellationToken=$null);$script:backupPackageTestCalls++;if($script:backupPackageTestCalls -ge 2){throw 'Injected package verification interruption.'};& $script:backupOriginalPackageTest $ManifestPath $ExpectedHash $CancellationToken}
        $failed=$false;$failureText='';try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $retryOperationId -Jobs @() -CancellationToken $retryToken|Out-Null}catch{$failed=$true;$failureText=$_.Exception.ToString()}
        Set-Item -Path Function:\script:Test-WsmMigrationPackage -Value $originalPackageTest
        Remove-Variable backupOriginalPackageTest,backupPackageTestCalls -Scope Script -ErrorAction SilentlyContinue
        $failedAttempt=Read-WsmJson $attemptFile
        $coreSealed=$false;if($failedAttempt.CoreExport -and $failedAttempt.CoreExport.PSObject.Properties['Sealed']){$coreSealed=[bool]$failedAttempt.CoreExport.Sealed}
        if(-not $failed -or $failedAttempt.Stage -cne 'Failed' -or $failedAttempt.ResumeStage -cne 'CoreExported' -or -not $coreSealed){$errorMessage='';if($failedAttempt.Error){$errorMessage=[string]$failedAttempt.Error.Message};throw ('A package-verification failure did not preserve the sealed core export and exact retry stage. failed='+$failed+' stage='+$failedAttempt.Stage+' resume='+$failedAttempt.ResumeStage+' sealed='+$coreSealed+' error='+$errorMessage+' detail='+$failureText)}
        Write-Host 'PASS: sealed package retry checkpoint.'
        $failedAttemptHash=(Get-FileHash -LiteralPath $attemptFile -Algorithm SHA256).Hash.ToLowerInvariant();$formatConflictRejected=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $retryOperationId -DeliveryMode Zip -VolumeBytes 134217728 -Jobs @() -CancellationToken $retryToken|Out-Null}catch{$formatConflictRejected=$true};if(-not $formatConflictRejected -or (Get-FileHash -LiteralPath $attemptFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $failedAttemptHash){throw 'An explicit changed format was accepted on replay or modified the frozen backup attempt.'};$sameOperation=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $retryOperationId -Jobs @() -CancellationToken $retryToken
        Write-Host 'PASS: durable replay lookup.'
        if($sameOperation.Stage -cne 'Failed' -or (Get-FileHash -LiteralPath $attemptFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $failedAttemptHash){throw 'Replaying a submitted operation identity changed or re-executed its durable backup attempt.'}
        $successOperationId=[Guid]::NewGuid().ToString('D');$successToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $successOperationId
        $result=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $successOperationId -Jobs @() -CancellationToken $successToken
        if($result.Status -cne 'Delivered' -or $result.Stage -cne 'Delivered' -or $result.DeliveryMode -cne 'Directory' -or [long]$result.VolumeBytes -ne 0 -or -not $result.CoreExport.Sealed -or -not $result.PackageTest.Valid -or -not $result.Delivery.SHA256){throw 'Wizard backup did not finish the real core export, package verification, and enrolled directory delivery chain.'}
        $assertItemResults={
            param($BackupResult,[string]$Label)
            $itemResults=$BackupResult.ItemResults
            if(-not $itemResults -or $itemResults.Status -cne 'Generated'){throw ($Label+': backup item results were not generated.')}
            if(-not [IO.File]::Exists($itemResults.Path) -or (Get-FileHash -LiteralPath $itemResults.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $itemResults.SHA256){throw ($Label+': backup item results file is missing or its SHA256 differs from the attempt record.')}
            if([IO.Path]::GetDirectoryName($itemResults.Path) -cne [IO.Path]::GetDirectoryName([string]$BackupResult.Delivery.Path)){throw ($Label+': backup item results were not written next to the delivery descriptor.')}
            if($itemResults.Counts.BackedUp -lt 1 -or $itemResults.Counts.Total -ne ($itemResults.Counts.BackedUp+$itemResults.Counts.NotBackedUp)){throw ($Label+': backup item result counts are inconsistent.')}
            $itemResultsDocument=Read-WsmJson $itemResults.Path
            $fixtureRows=@($itemResultsDocument.Rows | Where-Object ItemId -CEQ $item.ItemId)
            if($fixtureRows.Count -ne 1 -or $fixtureRows[0].Status -cne 'BackedUp' -or $fixtureRows[0].ReasonCode -cne 'PayloadCaptured' -or [int]$fixtureRows[0].Files -ne 2){throw ($Label+': the fixture FileScope item was not reported as a backed-up payload with two files.')}
            if($itemResultsDocument.Kind -cne 'BackupItemResults' -or $itemResultsDocument.Counts.Total -ne $itemResults.Counts.Total -or -not $itemResultsDocument.Software.PSObject.Properties['SoftwareRows']){throw ($Label+': backup item results document shape is wrong.')}
            $offlineReport=$BackupResult.OfflineReport
            if(-not $offlineReport -or $offlineReport.Status -cne 'Generated'){throw ($Label+': the offline backup report was not generated.')}
            if(-not [IO.File]::Exists($offlineReport.Path) -or (Get-FileHash -LiteralPath $offlineReport.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $offlineReport.SHA256){throw ($Label+': the offline backup report is missing or its SHA256 differs from the attempt record.')}
            if([IO.Path]::GetDirectoryName($offlineReport.Path) -cne [IO.Path]::GetDirectoryName([string]$BackupResult.Delivery.Path)){throw ($Label+': the offline backup report was not written next to the delivery descriptor.')}
            $offlineReportHtml=[IO.File]::ReadAllText($offlineReport.Path,[Text.Encoding]::UTF8)
            if($offlineReportHtml.IndexOf('Fixture settings folder',[StringComparison]::Ordinal) -lt 0){throw ($Label+': the offline backup report does not contain the fixture FileScope item name.')}
            foreach($forbidden in @('http://','https://','fetch(','XMLHttpRequest')){if($offlineReportHtml.IndexOf($forbidden,[StringComparison]::Ordinal) -ge 0){throw ($Label+': the offline backup report must not contain '+$forbidden)}}
        }
        & $assertItemResults $result 'Directory'
        $package=Test-WsmMigrationPackage $result.CoreExport.ManifestPath $result.CoreExport.SHA256
        $deliveryRoot=[string]$result.Delivery.Directory;if(-not $deliveryRoot){throw 'Directory-mode delivery did not return its exact owned delivery directory.'}
        $artifacts=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash)
        foreach($artifact in $artifacts){
            if(-not $artifact.Directory){
                foreach($chunk in @($artifact.Data.Chunks)){
                    $delivered=Join-Path (Join-Path $deliveryRoot 'payload') ($chunk.Hash+'.blob')
                    if(-not [IO.File]::Exists($delivered)){throw ('Delivered package is missing a verified payload chunk: '+$chunk.Hash)}
                    if((Get-FileHash -LiteralPath $delivered -Algorithm SHA256).Hash -ine $chunk.Hash){throw ('Delivered payload bytes differ from the sealed package chunk: '+$chunk.Hash)}
                }
            }
        }
        $backupAvailabilityCommand=Get-Command Get-WsmWizardBackupAvailability -CommandType Function -ErrorAction SilentlyContinue
        if(-not $backupAvailabilityCommand){throw 'Required WizardFlow consumer seam Get-WsmWizardBackupAvailability is not integrated; backup result availability must be derived from the durable attempt and matching job binding.'}
        $projection=Get-WsmWizardProjection $sourceRoot $catalog.PairId Source @([pscustomobject]@{jobId=$successOperationId;action='StartBackup';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;CompletedUtc=(Get-WsmUtc);outputs=@($result)})
        if(-not $projection.results.backup -or -not $projection.results.backup.current -or $projection.results.backup.attemptId -cne $result.AttemptId){throw 'Wizard projection did not derive the backup result from its durable attempt and job binding.'}
        $durableAttempt=Read-WsmJson $attemptFile
        if(@($durableAttempt.OperationIds).Count -ne 3 -or $durableAttempt.StartedByOperationId -cne $operationId -or $durableAttempt.LastOperationId -cne $successOperationId -or [int]$durableAttempt.ResumeCount -ne 2){throw 'Durable backup attempt did not preserve distinct initial, retry and current operation identity.'}
        $targetProfilePath=Join-Path (Join-Path $targetRoot 'workspace-control') 'output-profile.json'
        $script:backupFixtureFingerprint=('b'*64)
        $targetProfileHash=(Get-FileHash -LiteralPath $targetProfilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:backupFixtureFingerprint=('b'*64)
        $directoryImport=Import-WsmDirectoryDelivery -SummaryPath $result.Delivery.Path -ExpectedSummaryHash $result.Delivery.SHA256 -SourceDirectory $deliveryRoot -WorkRoot $targetRoot
        $directoryPackage=Test-WsmMigrationPackage $directoryImport.ManifestPath $directoryImport.ManifestHash
        foreach($artifact in @(Read-WsmArtifactLines (Join-Path $directoryPackage.Root 'artifacts.jsonl') $directoryPackage.Manifest.ArtifactsHash)){
            if(-not $artifact.Directory){foreach($chunk in @($artifact.Data.Chunks)){$destination=Join-Path (Join-Path $directoryPackage.Root 'payload') ($chunk.Hash+'.blob');if(-not [IO.File]::Exists($destination) -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $chunk.Hash -or (New-Object IO.FileInfo($destination)).Length -ne $chunk.Bytes){throw ('Directory import payload readback did not match source bytes for '+$artifact.RelativePath)}}}
        }
        Write-Host 'PASS: Directory delivery import and payload hash readback.'
        $script:backupFixtureFingerprint=('a'*64)
        $modeState=Get-WsmWizardState $sourceRoot $catalog.PairId Source
        [void](Set-WsmWizardState $sourceRoot $catalog.PairId Source $modeState.Revision ([pscustomobject]@{Mode='ItemByItem'}))
        $zipProfileHash=(Get-FileHash -LiteralPath $outputProfilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $zipOperationId=[Guid]::NewGuid().ToString('D');$zipToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $zipOperationId
        $zipResult=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $zipOperationId -DeliveryMode Zip -VolumeBytes 134217728 -Jobs @() -CancellationToken $zipToken
        Write-Host 'PASS: enrolled ZIP backup attempt completed.'
        if($zipResult.Status -cne 'Delivered' -or $zipResult.DeliveryMode -cne 'Zip' -or [long]$zipResult.VolumeBytes -ne 134217728 -or $zipResult.Delivery.Mode -cne 'Zip' -or -not [IO.File]::Exists($zipResult.Delivery.Path) -or $zipResult.Delivery.SHA256 -notmatch '^[a-f0-9]{64}$'){throw 'Wizard backup did not produce the real enrolled ZIP transport.'}
        & $assertItemResults $zipResult 'ZIP'
        $zipTransport=Read-WsmTrustedJson $zipResult.Delivery.Path $zipResult.Delivery.SHA256
        foreach($volume in @($zipTransport.Volumes)){$volumePath=Join-Path (Split-Path -Parent $zipResult.Delivery.Path) $volume.Name;if((Get-FileHash -LiteralPath $volumePath -Algorithm SHA256).Hash -ine $volume.Hash -or (New-Object IO.FileInfo($volumePath)).Length -ne $volume.Bytes){throw 'ZIP transport volume bytes or hash differ from its durable transport descriptor.'}}
        $script:backupFixtureFingerprint=('b'*64)
        $targetProfileHash=(Get-FileHash -LiteralPath $targetProfilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $zipImportRoot=Join-Path $Root 'zip-imported';$zipImport=Import-WsmPackageZip -TransportPath $zipResult.Delivery.Path -ExpectedHash $zipResult.Delivery.SHA256 -OutputDirectory $zipImportRoot
        $zipPackage=Test-WsmMigrationPackage $zipImport.ManifestPath $zipImport.SHA256
        foreach($artifact in @(Read-WsmArtifactLines (Join-Path $zipPackage.Root 'artifacts.jsonl') $zipPackage.Manifest.ArtifactsHash)){
            if(-not $artifact.Directory){foreach($chunk in @($artifact.Data.Chunks)){$destination=Join-Path (Join-Path $zipPackage.Root 'payload') ($chunk.Hash+'.blob');if(-not [IO.File]::Exists($destination) -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $chunk.Hash -or (New-Object IO.FileInfo($destination)).Length -ne $chunk.Bytes){throw ('ZIP import payload readback did not match source bytes for '+$artifact.RelativePath)}}}
        }
        Write-Host 'PASS: ZIP transport import and payload hash readback.'
        if((Get-FileHash -LiteralPath $outputProfilePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $outputProfileHash -or (Get-FileHash -LiteralPath $targetProfilePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $targetProfileHash){throw 'Per-attempt transport selection mutated an enrolled output profile.'}
        # Return from Target import observation to the enrolled Source host.
        $script:backupFixtureFingerprint=('a'*64)
        # Independent copy and verification tests (Task 02)
        $uncClassDirect = Get-WsmIndependentCopyMediaClass '\\fixture-server\share\x'
        if($uncClassDirect -cne 'Network'){throw ('Case i: UNC classification failed: ' + $uncClassDirect)}
        $sysClassDirect = Get-WsmIndependentCopyMediaClass $env:SystemRoot
        if($sysClassDirect -cne 'LocalFixed'){throw ('Case i: SystemRoot classification failed: ' + $sysClassDirect)}

        $backupOriginalMediaClass = (Get-Command Get-WsmIndependentCopyMediaClass -CommandType Function).ScriptBlock
        function script:Get-WsmIndependentCopyMediaClass {param($DestinationRoot)$script:fixtureMediaClass}
        function Get-WsmIndependentCopyMediaClass {param($DestinationRoot)$script:fixtureMediaClass}
        try {
            # Case a: Directory / Copy / Removable
            $destA = Join-Path $Root 'copy-dest-a'; [void][IO.Directory]::CreateDirectory($destA)
            $script:fixtureMediaClass = 'Removable'
            $resA = Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destA -Mode Copy
            if($resA.OfflineReadiness -cne 'Verified' -or $resA.IndependentCopy.Status -cne 'Verified'){throw 'Case a: Directory Copy Removable readiness or status mismatch.'}
            if(-not [IO.File]::Exists($resA.IndependentCopy.ReceiptPath)){throw 'Case a: Receipt file does not exist.'}
            $receiptHashA = (Get-FileHash -LiteralPath $resA.IndependentCopy.ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if($receiptHashA -cne $resA.IndependentCopy.ReceiptSHA256){throw 'Case a: Receipt hash mismatch.'}
            $receiptA = Read-WsmJson $resA.IndependentCopy.ReceiptPath
            if($receiptA.BackupOperationId -cne $successOperationId){throw 'Case a: Receipt BackupOperationId mismatch.'}
            if($receiptA.RequestOperationId -ceq $receiptA.BackupOperationId){throw 'Case a: Receipt RequestOperationId must differ from BackupOperationId.'}


            $actNull = Get-WsmWizardIndependentCopyAction $null
            if($actNull.available -ne $false){throw 'Action for null availability must be unavailable.'}
            if((Get-WsmWizardOfflineReadiness $null) -cne 'NotDelivered'){throw 'OfflineReadiness for null must be NotDelivered.'}
            $testGuid = [Guid]::NewGuid().ToString('D')
            $synthDelivered = [pscustomobject]@{stage='Delivered';hasPackage=$true;runId=$testGuid}
            $actDelivered = Get-WsmWizardIndependentCopyAction $synthDelivered
            if($actDelivered.available -ne $true){throw 'Action for delivered availability must be available.'}
            if($actDelivered.defaults.BackupOperationId -cne $testGuid){throw 'Action defaults BackupOperationId mismatch.'}
            if($actDelivered.defaults.Mode -cne 'Copy'){throw 'Action defaults Mode mismatch.'}
            if(@($actDelivered.missing) -cnotcontains 'DestinationRoot'){throw 'Action missing must contain DestinationRoot.'}
            $synthFailed = [pscustomobject]@{stage='Failed';hasPackage=$false}
            $actFailed = Get-WsmWizardIndependentCopyAction $synthFailed
            if($actFailed.available -ne $false){throw 'Action for failed availability must be unavailable.'}
            $attemptA = (Get-WsmWizardBackupAttemptForOperation $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $successOperationId).Attempt
            $synthAttemptA = [pscustomobject]@{stage='Delivered';hasPackage=$true;runId=$successOperationId;attempt=$attemptA}
            if((Get-WsmWizardOfflineReadiness $synthAttemptA) -cne 'Verified'){throw 'OfflineReadiness for verified attempt must be Verified.'}
            $copyRootA = $resA.IndependentCopy.CopyRoot
            $sourcePayloadDir = Join-Path $result.Delivery.Directory 'payload'
            $copiedPayloadDir = Join-Path (Join-Path $copyRootA 'transport\delivery') 'payload'
            $sourceBlobs = @(Get-ChildItem -LiteralPath $sourcePayloadDir -Filter '*.blob' -File)
            if($sourceBlobs.Count -eq 0){throw 'Case a: No payload blobs found in source.'}
            foreach($blob in $sourceBlobs){
                $copiedBlobPath = Join-Path $copiedPayloadDir $blob.Name
                if(-not [IO.File]::Exists($copiedBlobPath)){throw ('Case a: Missing copied blob ' + $blob.Name)}
                $copiedHash = (Get-FileHash -LiteralPath $copiedBlobPath -Algorithm SHA256).Hash
                $srcHash = (Get-FileHash -LiteralPath $blob.FullName -Algorithm SHA256).Hash
                if($copiedHash -ine $srcHash){throw ('Case a: Copied blob hash mismatch for ' + $blob.Name)}
            }

            $copiedItemResultsA = Join-Path $copyRootA 'transport\backup-item-results.json'
            if(-not [IO.File]::Exists($copiedItemResultsA)){throw 'Case a: backup-item-results.json was not copied into the independent copy.'}
            $itemResultsOriginalBytes = [IO.File]::ReadAllBytes($copiedItemResultsA)
            $itemResultsTamperBytes = [byte[]]$itemResultsOriginalBytes.Clone()
            $itemResultsTamperBytes[0] = [byte]($itemResultsTamperBytes[0] -bxor 0x01)
            [IO.File]::WriteAllBytes($copiedItemResultsA, $itemResultsTamperBytes)
            $itemResultsTamperRejected = $false
            try {
                Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destA -Mode VerifyExisting | Out-Null
            } catch {
                $itemResultsTamperRejected = $_.Exception.Message -like '*backup-item-results.json*'
            }
            [IO.File]::WriteAllBytes($copiedItemResultsA, $itemResultsOriginalBytes)
            if(-not $itemResultsTamperRejected){throw 'Case a: a one-byte change to the copied backup-item-results.json was not rejected by VerifyExisting.'}
            $copiedReportA = Join-Path $copyRootA 'transport\backup-report.html'
            if(-not [IO.File]::Exists($copiedReportA)){throw 'Case a: backup-report.html was not copied into the independent copy.'}
            $reportOriginalBytes = [IO.File]::ReadAllBytes($copiedReportA)
            $reportTamperBytes = [byte[]]$reportOriginalBytes.Clone()
            $reportTamperBytes[0] = [byte]($reportTamperBytes[0] -bxor 0x01)
            [IO.File]::WriteAllBytes($copiedReportA, $reportTamperBytes)
            $reportTamperRejected = $false
            try {
                Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destA -Mode VerifyExisting | Out-Null
            } catch {
                $reportTamperRejected = $_.Exception.Message -like '*backup-report.html*'
            }
            [IO.File]::WriteAllBytes($copiedReportA, $reportOriginalBytes)
            if(-not $reportTamperRejected){throw 'Case a: a one-byte change to the copied backup-report.html was not rejected by VerifyExisting.'}

            # N6 (16.3-1): offline guide next to the delivery descriptor, hashed in the attempt, carried by the independent copy and its receipt.
            $assertGuide={param($Attempt,$Delivery,[string]$ManifestHash,[string]$PlanHash,[string]$Label)
                $g=$null;if($Attempt.PSObject.Properties['OfflineGuide']){$g=$Attempt.OfflineGuide}
                if(-not $g -or $g.Status -cne 'Generated' -or [string]$g.SHA256 -notmatch '^[a-f0-9]{64}$' -or [string]$g.TextSHA256 -notmatch '^[a-f0-9]{64}$'){throw ($Label+': the attempt does not index the offline guide hashes.')}
                $guideDirectory=Split-Path -Parent ([string]$Delivery.Path)
                $guideHtmlPath=Join-Path $guideDirectory 'offline-guide.html';$guideTextPath=Join-Path $guideDirectory 'offline-guide.txt'
                if([IO.Path]::GetFullPath([string]$g.Path) -ine [IO.Path]::GetFullPath($guideHtmlPath) -or [IO.Path]::GetFullPath([string]$g.TextPath) -ine [IO.Path]::GetFullPath($guideTextPath)){throw ($Label+': the offline guide is not stored next to the delivery descriptor.')}
                if((Get-FileHash -LiteralPath $guideHtmlPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$g.SHA256 -or (Get-FileHash -LiteralPath $guideTextPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$g.TextSHA256){throw ($Label+': the indexed offline guide hashes differ from the files.')}
                $guideHtml=[IO.File]::ReadAllText($guideHtmlPath);$guideText=[IO.File]::ReadAllText($guideTextPath)
                $descriptorName=[IO.Path]::GetFileName([string]$Delivery.Path)
                foreach($doc in @(@('html',$guideHtml),@('txt',$guideText))){
                    $body=[string]$doc[1]
                    foreach($needle in @($ManifestHash.ToLowerInvariant(),$PlanHash.ToLowerInvariant(),([string]$Delivery.SHA256).ToLowerInvariant(),[string]$script:ToolVersion,$descriptorName,'ToolVersion','不代表媒體目前仍完整','重新驗證')){if(-not $body.Contains([string]$needle)){throw ($Label+': offline guide '+$doc[0]+' is missing "'+$needle+'".')}}
                    if($body -match '(?i)[a-z]:\\' -or $body -match '(?i)https?://' -or $body.Contains($Root) -or $body.Contains($sourceRoot)){throw ($Label+': offline guide '+$doc[0]+' carries an absolute path or a network address.')}
                }
                if($guideHtml -match '(?i)<script' -or $guideHtml -notmatch '<h1>' -or $guideHtml -notmatch '<h2 id=' -or $guideHtml -notmatch 'lang="zh-Hant"' -or $guideHtml -notmatch 'prefers-reduced-motion' -or $guideHtml -notmatch 'Noto Sans TC'){throw ($Label+': offline guide HTML lost its static, semantic, reduced-motion structure.')}
                if($Delivery.PSObject.Properties['Directory'] -and $Delivery.Directory -and [IO.Directory]::Exists([string]$Delivery.Directory)){if(@(Get-ChildItem -LiteralPath ([string]$Delivery.Directory) -Recurse -File -Filter 'offline-guide*').Count -ne 0){throw ($Label+': the offline guide must stay out of the sealed delivery body.')}}
                $g
            }
            $attemptGuideA=(Get-WsmWizardBackupAttemptForOperation $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $successOperationId).Attempt
            $guideA=& $assertGuide $attemptGuideA $result.Delivery ([string]$result.PackageTest.SHA256) ([string]$approved.SHA256) 'Directory'
            $copiedGuideHtmlA=Join-Path $copyRootA 'transport\offline-guide.html';$copiedGuideTextA=Join-Path $copyRootA 'transport\offline-guide.txt'
            if(-not [IO.File]::Exists($copiedGuideHtmlA) -or -not [IO.File]::Exists($copiedGuideTextA)){throw 'Case a: the offline guide was not copied into the independent copy.'}
            if([string]$receiptA.OfflineGuideSHA256 -cne [string]$guideA.SHA256 -or [string]$receiptA.OfflineGuideTextSHA256 -cne [string]$guideA.TextSHA256){throw 'Case a: the independent copy receipt does not reference the offline guide hashes.'}
            foreach($guideCopy in @(@($copiedGuideHtmlA,'offline-guide.html'),@($copiedGuideTextA,'offline-guide.txt'))){
                $guideOriginalBytes=[IO.File]::ReadAllBytes($guideCopy[0]);$guideTamperBytes=[byte[]]$guideOriginalBytes.Clone();$guideTamperBytes[$guideTamperBytes.Length-1]=[byte]($guideTamperBytes[$guideTamperBytes.Length-1] -bxor 0x01)
                [IO.File]::WriteAllBytes($guideCopy[0],$guideTamperBytes);$guideTamperRejected=$false
                try{Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destA -Mode VerifyExisting | Out-Null}catch{$guideTamperRejected=($_.Exception.Message -like ('*'+$guideCopy[1]+'*'))}
                [IO.File]::WriteAllBytes($guideCopy[0],$guideOriginalBytes)
                if(-not $guideTamperRejected){throw ('Case a: a one-byte change to the copied '+$guideCopy[1]+' was not rejected by VerifyExisting.')}
            }
            $resA2=Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destA -Mode VerifyExisting
            if($resA2.IndependentCopy.Status -cne 'Verified'){throw 'Case a: restoring the copied offline guide bytes did not verify again.'}
            $attemptGuideA2=(Get-WsmWizardBackupAttemptForOperation $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $successOperationId).Attempt
            $projectionA2=Get-WsmWizardIndependentCopyProjection $sourceRoot $catalog.PairId $attemptGuideA2 ([string]$attemptGuideA2.ItemResults.SHA256)
            if($projectionA2.state -cne 'Verified'){throw ('Case a: the workbench receipt check (B2) no longer accepts a receipt that carries the offline guide fields: '+$projectionA2.state+' '+$projectionA2.reason)}
            # The receipt check must also bind the guide: a receipt that omits (or changes) the guide hash is not accepted.
            $receiptA2Path=[string]$attemptGuideA2.IndependentCopy.ReceiptPath;$receiptA2Bytes=[IO.File]::ReadAllBytes($receiptA2Path);$attemptGuideA2Hash=[string]$attemptGuideA2.IndependentCopy.ReceiptSHA256
            try{
                $receiptA2=Read-WsmJson $receiptA2Path;$receiptA2.OfflineGuideSHA256=('0'*64);Write-WsmJson $receiptA2Path $receiptA2
                $attemptGuideA2.IndependentCopy.ReceiptSHA256=(Get-FileHash -LiteralPath $receiptA2Path -Algorithm SHA256).Hash.ToLowerInvariant()
                $projectionBad=Get-WsmWizardIndependentCopyProjection $sourceRoot $catalog.PairId $attemptGuideA2 ([string]$attemptGuideA2.ItemResults.SHA256)
                if($projectionBad.state -cne 'Unverifiable'){throw 'Case a: a receipt with a different offline guide hash was still accepted by the workbench receipt check.'}
            }finally{[IO.File]::WriteAllBytes($receiptA2Path,$receiptA2Bytes);$attemptGuideA2.IndependentCopy.ReceiptSHA256=$attemptGuideA2Hash}
            Write-Host 'PASS: offline guide (Directory): content, index hashes, independent copy, receipt binding and tamper rejection.'

            # Case b: ZIP / Copy / Network
            $destB = Join-Path $Root 'copy-dest-b'; [void][IO.Directory]::CreateDirectory($destB)
            $script:fixtureMediaClass = 'Network'
            $resB = Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $zipOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destB -Mode Copy
            if($resB.OfflineReadiness -cne 'VerifiedNetworkAvailabilityUnconfirmed'){throw 'Case b: ZIP Copy Network OfflineReadiness mismatch.'}
            $attemptGuideB=(Get-WsmWizardBackupAttemptForOperation $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $zipOperationId).Attempt
            $guideB=& $assertGuide $attemptGuideB $zipResult.Delivery ([string]$zipResult.PackageTest.SHA256) ([string]$approved.SHA256) 'ZIP'
            $receiptB=Read-WsmJson $resB.IndependentCopy.ReceiptPath
            foreach($guideName in @('offline-guide.html','offline-guide.txt')){if(-not [IO.File]::Exists((Join-Path (Join-Path $resB.IndependentCopy.CopyRoot 'transport') $guideName))){throw ('Case b: ZIP independent copy is missing '+$guideName)}}
            if([string]$receiptB.OfflineGuideSHA256 -cne [string]$guideB.SHA256 -or [string]$receiptB.OfflineGuideTextSHA256 -cne [string]$guideB.TextSHA256){throw 'Case b: the ZIP independent copy receipt does not reference the offline guide hashes.'}
            Write-Host 'PASS: offline guide (ZIP).'

            # Case c: Tamper
            $blobToTamper = @(Get-ChildItem -LiteralPath $copiedPayloadDir -Filter '*.blob' -File)[0]
            $tamperBytes = [IO.File]::ReadAllBytes($blobToTamper.FullName)
            $tamperBytes[0] = [byte]($tamperBytes[0] -bxor 0xFF)
            [IO.File]::WriteAllBytes($blobToTamper.FullName, $tamperBytes)
            $script:fixtureMediaClass = 'Removable'
            $tamperFailed = $false
            try {
                Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destA -Mode VerifyExisting | Out-Null
            } catch {
                $tamperFailed = $true
            }
            if(-not $tamperFailed){throw 'Case c: Tampered payload blob was not rejected.'}
            $attemptAfterTamper = (Get-WsmWizardBackupAttemptForOperation $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $successOperationId).Attempt
            $tamperResult = ConvertTo-WsmWizardBackupResult $attemptAfterTamper $successOperationId
            if($attemptAfterTamper.IndependentCopy.Status -cne 'Failed' -or $tamperResult.OfflineReadiness -cne 'AwaitingIndependentCopy'){
                throw 'Case c: Attempt status or OfflineReadiness after tamper did not record failure.'
            }

            # Case d: Missing file
            $copyRootB = $resB.IndependentCopy.CopyRoot
            $zipVolumes = @(Get-ChildItem -LiteralPath (Join-Path $copyRootB 'transport') -Filter '*.zip' -File)
            if($zipVolumes.Count -eq 0){throw 'Case d: No zip volumes found.'}
            Remove-Item -LiteralPath $zipVolumes[0].FullName -Force
            $missingFailed = $false
            try {
                Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $zipOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destB -Mode VerifyExisting | Out-Null
            } catch {
                $missingFailed = $true
            }
            if(-not $missingFailed){throw 'Case d: Missing volume was not rejected.'}

            # Case e: Manual copy
            $destE = Join-Path $Root 'copy-dest-e'; [void][IO.Directory]::CreateDirectory($destE)
            $attemptA = (Get-WsmWizardBackupAttemptForOperation $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $successOperationId).Attempt
            $offlineSubDirE = Join-Path $destE ('wsm-offline-' + $catalog.PairId + '-' + [string]$attemptA.AttemptId)
            $transportE = Join-Path $offlineSubDirE 'transport'
            [void][IO.Directory]::CreateDirectory($transportE)
            Copy-Item -LiteralPath $result.Delivery.Path -Destination $transportE -Force
            Copy-Item -LiteralPath $result.Delivery.Directory -Destination $transportE -Recurse -Force
            Copy-Item -LiteralPath $result.ItemResults.Path -Destination $transportE -Force
            Copy-Item -LiteralPath $result.OfflineReport.Path -Destination $transportE -Force
            Copy-Item -LiteralPath ([string]$attemptA.OfflineGuide.Path) -Destination $transportE -Force
            Copy-Item -LiteralPath ([string]$attemptA.OfflineGuide.TextPath) -Destination $transportE -Force
            $script:fixtureMediaClass = 'Removable'
            $resE = Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destE -Mode VerifyExisting
            if($resE.OfflineReadiness -cne 'Verified' -or $resE.IndependentCopy.Status -cne 'Verified'){throw 'Case e: Manual copy VerifyExisting not verified.'}
            $receiptE = Read-WsmJson $resE.IndependentCopy.ReceiptPath
            if($receiptE.Mode -cne 'VerifyExisting'){throw 'Case e: Receipt Mode is not VerifyExisting.'}
            # Case k: an unlisted extra file inside the copied delivery directory is rejected.
            $extraFileE=Join-Path (Join-Path $transportE 'delivery') 'unlisted-extra.txt';[IO.File]::WriteAllText($extraFileE,'not part of the sealed delivery');$extraRejected=$false;try{Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destE -Mode VerifyExisting|Out-Null}catch{$extraRejected=$_.Exception.Message -like '*Unexpected extra file*'};if(-not $extraRejected){throw 'Case k: Unlisted extra file in independent copy delivery was accepted.'};[IO.File]::Delete($extraFileE)

            # Case f: LocalFixed
            $destF = Join-Path $Root 'copy-dest-f'; [void][IO.Directory]::CreateDirectory($destF)
            $script:fixtureMediaClass = 'LocalFixed'
            $attemptFileBeforeF = (Get-WsmWizardBackupAttemptForOperation $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $successOperationId).Path
            $attemptHashBeforeF = (Get-FileHash -LiteralPath $attemptFileBeforeF -Algorithm SHA256).Hash
            $localFixedThrown = $false; $localFixedMsg = ''
            try {
                Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destF -Mode Copy | Out-Null
            } catch {
                $localFixedThrown = $true
                $localFixedMsg = $_.Exception.Message
            }
            $attemptHashAfterF = (Get-FileHash -LiteralPath $attemptFileBeforeF -Algorithm SHA256).Hash
            $copyRootF = Join-Path $destF ('wsm-offline-' + $catalog.PairId + '-' + [string]$attemptA.AttemptId)
            if(-not $localFixedThrown -or $localFixedMsg -notlike '*not independent*' -or [IO.Directory]::Exists($copyRootF) -or $attemptHashBeforeF -cne $attemptHashAfterF){
                throw 'Case f: LocalFixed did not reject with not independent or mutated attempt/destination.'
            }

            # Case g: Destination inside source workspace
            $destInside = Join-Path $sourceRoot 'inside-dest'
            $insideThrown = $false; $insideMsg = ''
            try {
                Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destInside -Mode Copy | Out-Null
            } catch {
                $insideThrown = $true
                $insideMsg = $_.Exception.Message
            }
            if(-not $insideThrown -or $insideMsg -notlike '*outside the source workspace*'){
                throw 'Case g: Destination inside source workspace did not throw outside the source workspace.'
            }

            # Case h: Not Delivered operation
            $fakeOpId = [Guid]::NewGuid().ToString('D')
            $destH = Join-Path $Root 'copy-dest-h'; [void][IO.Directory]::CreateDirectory($destH)
            $script:fixtureMediaClass = 'Removable'
            $hThrown = $false; $hMsg = ''
            try {
                Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $fakeOpId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destH -Mode Copy | Out-Null
            } catch {
                $hThrown = $true
                $hMsg = $_.Exception.Message
            }
            if(-not $hThrown -or $hMsg -notlike '*delivered backup attempt*'){
                throw 'Case h: Non-delivered OperationId did not throw delivered backup attempt.'
            }

            # Case j: Copy mode destination already has different content
            $destJ = Join-Path $Root 'copy-dest-j'; [void][IO.Directory]::CreateDirectory($destJ)
            $offlineSubDirJ = Join-Path $destJ ('wsm-offline-' + $catalog.PairId + '-' + [string]$attemptA.AttemptId)
            $transportJ = Join-Path $offlineSubDirJ 'transport'
            [void][IO.Directory]::CreateDirectory($transportJ)
            $summaryNameJ = [IO.Path]::GetFileName($result.Delivery.Path)
            $conflictFileJ = Join-Path $transportJ $summaryNameJ
            [IO.File]::WriteAllText($conflictFileJ, 'DIFFERENT CONTENT PRIOR TO COPY')
            $conflictHashBefore = (Get-FileHash -LiteralPath $conflictFileJ -Algorithm SHA256).Hash
            $script:fixtureMediaClass = 'Removable'
            $jThrown = $false; $jMsg = ''
            try {
                Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $successOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destJ -Mode Copy | Out-Null
            } catch {
                $jThrown = $true
                $jMsg = $_.Exception.Message
            }
            $conflictHashAfter = (Get-FileHash -LiteralPath $conflictFileJ -Algorithm SHA256).Hash
            if(-not $jThrown -or $jMsg -notlike '*different content*' -or $conflictHashBefore -cne $conflictHashAfter){
                throw 'Case j: Destination with different content was overwritten or did not throw different content.'
            }

            Write-Host 'PASS: independent copy Directory/ZIP copy, manual-copy verification, tamper/missing/local-fixed/inside-workspace/not-delivered/overwrite rejections.'
        } finally {
            Set-Item -Path Function:\script:Get-WsmIndependentCopyMediaClass -Value $backupOriginalMediaClass
            Set-Item -Path Function:\Get-WsmIndependentCopyMediaClass -Value $backupOriginalMediaClass
            Remove-Variable backupOriginalMediaClass,fixtureMediaClass -Scope Script -ErrorAction SilentlyContinue
        }
        $stageCases=@(
            [pscustomobject]@{Name='running-authorized';Stage='Authorized';JobStatus='Running';PackageTest=$null;HasResult=$false},
            [pscustomobject]@{Name='running-core-exported';Stage='CoreExported';JobStatus='Running';PackageTest=$null;HasResult=$false},
            [pscustomobject]@{Name='running-package-verified';Stage='PackageVerified';JobStatus='Running';PackageTest=$result.PackageTest;HasResult=$false},
            [pscustomobject]@{Name='failed-no-package';Stage='Failed';JobStatus='Failed';PackageTest=$null;HasResult=$true},
            [pscustomobject]@{Name='cancelled-no-package';Stage='Cancelled';JobStatus='Cancelled';PackageTest=$null;HasResult=$true},
            [pscustomobject]@{Name='interrupted-no-completed-time';Stage='ReviewRequired';JobStatus='Interrupted';PackageTest=$null;HasResult=$true},
            [pscustomobject]@{Name='delivered-no-completed-time';Stage='Delivered';JobStatus='Succeeded';PackageTest=$result.PackageTest;HasResult=$true},
            [pscustomobject]@{Name='review-required-no-completed-time';Stage='ReviewRequired';JobStatus='ReviewRequired';PackageTest=$result.PackageTest;HasResult=$true}
        )
        $stageFixturePaths=New-Object 'System.Collections.Generic.List[string]'
        try {
            foreach($case in $stageCases){
                $attemptId=[Guid]::NewGuid().ToString('D');$operationIdForCase=[Guid]::NewGuid().ToString('D');$attemptBody=[ordered]@{}
                foreach($property in $durableAttempt.PSObject.Properties){$attemptBody[$property.Name]=$property.Value}
                $attemptBody.AttemptId=$attemptId;$attemptBody.StartedByOperationId=$operationIdForCase;$attemptBody.OperationIds=@($operationIdForCase);$attemptBody.LastOperationId=$operationIdForCase;$attemptBody.ResumeCount=0;$attemptBody.Stage=$case.Stage;$attemptBody.UpdatedUtc=Get-WsmUtc;$attemptBody.PackageTest=$case.PackageTest
                $attemptPath=Join-Path $attemptRoot ($attemptId+'.json');Write-WsmJson $attemptPath ([pscustomobject]$attemptBody);$stageFixturePaths.Add($attemptPath)
                $job=[pscustomobject]@{jobId=$operationIdForCase;action='StartBackup';status=$case.JobStatus;role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;outputs=@([pscustomobject]@{AttemptId=$attemptId})}
                $availability=Get-WsmWizardBackupAvailability $sourceRoot $catalog.PairId $backupProfile @($job)
                if([bool]$availability -ne [bool]$case.HasResult){throw ('Backup result availability did not follow the durable terminal stage/job boundary for '+$case.Name+'.')}
                if($availability -and ($availability.attemptId -cne $attemptId -or -not $availability.hasDurableRecord -or -not $availability.current)){throw ('Backup result projection lost its exact current attempt binding for '+$case.Name+'.')}
                if($case.HasResult){
                    $wrongOutput=[pscustomobject]@{jobId=$operationIdForCase;action='StartBackup';status=$case.JobStatus;role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;outputs=@([pscustomobject]@{AttemptId=[Guid]::NewGuid().ToString('D')})}
                    if(Get-WsmWizardBackupAvailability $sourceRoot $catalog.PairId $backupProfile @($wrongOutput)){throw ('Backup result accepted a job output bound to another attempt for '+$case.Name+'.')}
                    $wrongOperation=[pscustomobject]@{jobId=[Guid]::NewGuid().ToString('D');action='StartBackup';status=$case.JobStatus;role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;outputs=@([pscustomobject]@{AttemptId=$attemptId})}
                    if(Get-WsmWizardBackupAvailability $sourceRoot $catalog.PairId $backupProfile @($wrongOperation)){throw ('Backup result accepted an operation not recorded by the durable attempt for '+$case.Name+'.')}
                    $wrongWorkspace=[pscustomobject]@{jobId=$operationIdForCase;action='StartBackup';status=$case.JobStatus;role='Source';workspace=(Join-Path $sourceRoot 'other');pairId=$catalog.PairId;outputs=@([pscustomobject]@{AttemptId=$attemptId})}
                    if(Get-WsmWizardBackupAvailability $sourceRoot $catalog.PairId $backupProfile @($wrongWorkspace)){throw ('Backup result accepted a job from another workspace for '+$case.Name+'.')}
                    $wrongRole=[pscustomobject]@{jobId=$operationIdForCase;action='StartBackup';status=$case.JobStatus;role='Manager';workspace=$sourceRoot;pairId=$catalog.PairId;outputs=@([pscustomobject]@{AttemptId=$attemptId})}
                    if(Get-WsmWizardBackupAvailability $sourceRoot $catalog.PairId $backupProfile @($wrongRole)){throw ('Backup result accepted a non-Source job for '+$case.Name+'.')}
                    $wrongPair=[pscustomobject]@{jobId=$operationIdForCase;action='StartBackup';status=$case.JobStatus;role='Source';workspace=$sourceRoot;pairId=[Guid]::NewGuid().ToString('D');outputs=@([pscustomobject]@{AttemptId=$attemptId})}
                    if(Get-WsmWizardBackupAvailability $sourceRoot $catalog.PairId $backupProfile @($wrongPair)){throw ('Backup result accepted a job for another pair for '+$case.Name+'.')}
                }
            }
        } finally {foreach($fixturePath in $stageFixturePaths){if([IO.File]::Exists($fixturePath)){[IO.File]::Delete($fixturePath)}}}
        $generationFixturePaths=New-Object 'System.Collections.Generic.List[string]';$generationJobs=New-Object 'System.Collections.Generic.List[object]'
        try{
            $olderId=[Guid]::NewGuid().ToString('D');$olderOperation=[Guid]::NewGuid().ToString('D');$olderBody=[ordered]@{};foreach($property in $durableAttempt.PSObject.Properties){$olderBody[$property.Name]=$property.Value};$olderBody.AttemptId=$olderId;$olderBody.StartedByOperationId=$olderOperation;$olderBody.OperationIds=@($olderOperation);$olderBody.LastOperationId=$olderOperation;$olderBody.Stage='Delivered';$olderBody.ResumeStage='';$olderBody.UpdatedUtc=Get-WsmUtc
            $olderPath=Join-Path $attemptRoot ($olderId+'.json');Write-WsmJson $olderPath ([pscustomobject]$olderBody);$generationFixturePaths.Add($olderPath);$generationJobs.Add([pscustomobject]@{jobId=$olderOperation;action='StartBackup';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{AttemptId=$olderId})})
            $newerId=[Guid]::NewGuid().ToString('D');$newerOperation=[Guid]::NewGuid().ToString('D');$newerBody=[ordered]@{};foreach($property in $durableAttempt.PSObject.Properties){$newerBody[$property.Name]=$property.Value};$newerBody.AttemptId=$newerId;$newerBody.StartedByOperationId=$newerOperation;$newerBody.OperationIds=@($newerOperation);$newerBody.LastOperationId=$newerOperation;$newerBody.Stage='Delivered';$newerBody.ResumeStage='';$newerBody.UpdatedUtc=Get-WsmUtc;$newerBody.CoreExport=[pscustomobject]@{};foreach($property in $durableAttempt.CoreExport.PSObject.Properties){$newerBody.CoreExport|Add-Member NoteProperty $property.Name $property.Value};$newerBody.CoreExport.Generation=([int]$durableAttempt.CoreExport.Generation+1);$newerBody.PackageTest=[pscustomobject]@{};foreach($property in $durableAttempt.PackageTest.PSObject.Properties){$newerBody.PackageTest|Add-Member NoteProperty $property.Name $property.Value};$newerBody.PackageTest.Generation=([int]$newerBody.CoreExport.Generation)
            $newerPath=Join-Path $attemptRoot ($newerId+'.json');Write-WsmJson $newerPath ([pscustomobject]$newerBody);$generationFixturePaths.Add($newerPath);$generationJobs.Add([pscustomobject]@{jobId=$newerOperation;action='StartBackup';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{AttemptId=$newerId})})
            $newest=Get-WsmWizardBackupAvailability $sourceRoot $catalog.PairId $backupProfile @($generationJobs.ToArray())
            if(-not $newest -or -not $newest.current -or [int]$newest.generation -ne [int]$newerBody.CoreExport.Generation -or $newest.status -cne 'MaterialUnavailable' -or $newest.hasPackage){throw 'A tampered latest backup generation fell back to older valid delivered material.'}
        } finally {foreach($fixturePath in $generationFixturePaths){if([IO.File]::Exists($fixturePath)){[IO.File]::Delete($fixturePath)}}}
        $manualPlan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=('c'*64);Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='ManualWorkflow'}})}
        $manualSummary=Get-WsmWizardChannelSummary $manualPlan ([pscustomobject]@{Valid=$true;Final=$true}) ([pscustomobject]@{SHA256=('d'*64)})
        if($manualSummary.OverallStatus -cne 'ReviewRequired' -or $manualSummary.C.Status -cne 'NoIncludedCFileScope' -or $manualSummary.ManualArtifactsNotSupported.Status -cne 'ManualArtifactsNotSupported' -or @($manualSummary.ManualArtifactsNotSupported.IncludedItemIds).Count -ne 1){throw 'A sealed schema-3 control package with only ManualWorkflow selected was incorrectly presented as a complete backup.'}
        $unknownPlan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=('e'*64);Decision='Include';MigrationSpec=$null})}
        $unknownSummary=Get-WsmWizardChannelSummary $unknownPlan ([pscustomobject]@{Valid=$true;Final=$true}) ([pscustomobject]@{SHA256=('d'*64)})
        if($unknownSummary.OverallStatus -cne 'ReviewRequired' -or @($unknownSummary.UnsupportedIncludedItemIds).Count -ne 1){throw 'A sealed control package with an unsupported selected item was incorrectly presented as a complete backup.'}
        $nonCPlan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=('f'*64);Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='NonC'}})}
        $nonCSummary=Get-WsmWizardChannelSummary $nonCPlan ([pscustomobject]@{Valid=$true;Final=$true}) ([pscustomobject]@{SHA256=('d'*64)})
        if($nonCSummary.OverallStatus -cne 'ReviewRequired' -or $nonCSummary.NonC.Status -cne 'RequiresTargetTransferAndManagerResultImport' -or $nonCSummary.C.Status -cne 'NoIncludedCFileScope'){throw 'A control package without C payload or imported NonC result was presented as a complete backup.'}
        $allConfigPlan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=('1'*64);Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='Service'}})}
        $allConfigSummary=Get-WsmWizardChannelSummary $allConfigPlan ([pscustomobject]@{Valid=$true;Final=$true}) ([pscustomobject]@{SHA256=('d'*64)})
        if($allConfigSummary.OverallStatus -cne 'Succeeded' -or $allConfigSummary.ConfigurationEvidence.Status -cne 'VerifiedInSealedPlanAndDelivered'){throw 'A verified supported configuration-only schema-3 plan was incorrectly treated as missing payload.'}
        $mixedPlan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=('2'*64);Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C'}},[pscustomobject]@{ItemId=('3'*64);Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='Service'}})}
        $mixedSummary=Get-WsmWizardChannelSummary $mixedPlan ([pscustomobject]@{Valid=$true;Final=$true}) ([pscustomobject]@{SHA256=('d'*64)})
        if($mixedSummary.OverallStatus -cne 'Succeeded' -or $mixedSummary.C.Status -cne 'VerifiedDelivered' -or $mixedSummary.ConfigurationEvidence.Status -cne 'VerifiedInSealedPlanAndDelivered'){throw 'A mixed C-payload and supported configuration-evidence result was not reported by channel.'}
        $certificatePlan=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=('4'*64);Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='Certificate';Desired=[pscustomobject]@{ArtifactHash=('5'*64)}}})}
        $certificateSummary=Get-WsmWizardChannelSummary $certificatePlan ([pscustomobject]@{Valid=$true;Final=$true}) ([pscustomobject]@{SHA256=('d'*64)})
        if($certificateSummary.OverallStatus -cne 'Succeeded' -or $certificateSummary.Certificate.Status -cne 'VerifiedPayloadDelivered'){throw 'A package already accepted by the real deep verifier did not report its included certificate artifact as delivered.'}
        # Backup item results: pure row rules (a-i), software rows, and non-fatal failure.
        $irItem={param([string]$Id,[string]$Name,$Spec,[string]$Decision,[string]$Kind='DataRoot',[string]$Category='Storage')[pscustomobject]@{ItemId=$Id;Name=$Name;Kind=$Kind;Category=$Category;NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{Path=('C:\settings\'+$Id)};Decision=$Decision;MigrationSpec=$Spec}}
        $irFile={param([string]$Channel)[pscustomobject]@{Adapter='FileScope';SourcePath=('D:\scope\'+$Channel);TransferChannel=$Channel}}
        $irPlan=[pscustomobject]@{Items=@(
            (& $irItem 'ext' 'A external' (& $irFile 'External') 'Include'),
            (& $irItem 'nonc' 'B nonc' (& $irFile 'NonC') 'Include'),
            (& $irItem 'cap' 'C captured' (& $irFile 'C') 'Include'),
            (& $irItem 'nocap' 'D nocontent' (& $irFile 'C') 'Include'),
            (& $irItem 'man' 'E manual' ([pscustomobject]@{Adapter='ManualWorkflow'}) 'Include'),
            (& $irItem 'nospec' 'F nospec' $null 'Include'),
            (& $irItem 'cfg' 'G config' ([pscustomobject]@{Adapter='Service'}) 'Include' 'Service' 'Services'),
            (& $irItem 'exc' 'H excluded' (& $irFile 'C') 'Exclude'),
            (& $irItem 'pend' 'I pending' (& $irFile 'C') 'Pending'))}
        $irInventory=[pscustomobject]@{Items=@(
            [pscustomobject]@{ItemId='cap';Name='C captured';Kind='DataRoot';Category='Storage';NaturalKey='key-cap';Settings=[pscustomobject]@{};Status='Success'},
            [pscustomobject]@{ItemId='sel';Name='J selected-not';Kind='DataRoot';Category='Storage';NaturalKey='key-sel';Settings=[pscustomobject]@{Path='E:\only-inventory'};Status='PermissionDenied'})}
        $irArtifacts=@(
            [pscustomobject]@{ItemId='cap';RelativePath='dir';Directory=$true;Data=$null},
            [pscustomobject]@{ItemId='cap';RelativePath='dir\a.txt';Directory=$false;Data=[pscustomobject]@{Bytes=10}},
            [pscustomobject]@{ItemId='cap';RelativePath='dir\b.txt';Directory=$false;Data=[pscustomobject]@{Bytes=5}},
            [pscustomobject]@{ItemId='cfg';RelativePath='ignored-by-config';Directory=$true;Data=$null})
        $irRows=@(Get-WsmBackupItemResultRows $irPlan $irInventory $irArtifacts $false)
        $irExpected=[ordered]@{ext=@('NotBackedUp','ExternalHandling');nonc=@('NotBackedUp','SeparateNonCTransfer');cap=@('BackedUp','PayloadCaptured');nocap=@('NotBackedUp','NoCapturedContent');man=@('NotBackedUp','ManualHandling');nospec=@('NotBackedUp','ManualHandling');cfg=@('BackedUp','PayloadCaptured');exc=@('NotBackedUp','Excluded');pend=@('NotBackedUp','NotIncluded');sel=@('NotBackedUp','PermissionDenied')}
        if($irRows.Count -ne $irExpected.Count){throw ('Backup item rows must contain exactly one row per plan-or-inventory item; got '+$irRows.Count)}
        foreach($expectedId in $irExpected.Keys){$irRow=@($irRows | Where-Object ItemId -CEQ $expectedId);if($irRow.Count -ne 1 -or $irRow[0].Status -cne $irExpected[$expectedId][0] -or $irRow[0].ReasonCode -cne $irExpected[$expectedId][1]){throw ('Backup item row rule mismatch for '+$expectedId+': '+(($irRow | ForEach-Object {$_.Status+'/'+$_.ReasonCode}) -join ','))}}
        $irCapRow=@($irRows | Where-Object ItemId -CEQ 'cap')[0]
        if($irCapRow.Files -ne 2 -or $irCapRow.Bytes -ne 15 -or $irCapRow.Location -cne 'D:\scope\C' -or $irCapRow.Channel -cne 'C'){throw 'Captured FileScope row did not carry its file count, byte sum, source path and channel.'}
        $irCfgConfigRows=@(Get-WsmBackupItemResultRows ([pscustomobject]@{Items=@((& $irItem 'cfg2' 'G2 config' ([pscustomobject]@{Adapter='Service'}) 'Include' 'Service' 'Services'))}) $null @() $false)
        if($irCfgConfigRows[0].Status -cne 'BackedUp' -or $irCfgConfigRows[0].ReasonCode -cne 'ConfigurationCaptured' -or $irCfgConfigRows[0].Files -ne 0 -or $irCfgConfigRows[0].Bytes -ne 0 -or $irCfgConfigRows[0].Channel -cne 'Configuration' -or $irCfgConfigRows[0].Location -cne 'C:\settings\cfg2'){throw 'Configuration-only Include row was not reported as captured configuration with zero files and its configuration channel/location.'}
        if((@($irRows | Where-Object ItemId -CEQ 'sel')[0]).DiscoveryStatus -cne 'PermissionDenied' -or (@($irRows | Where-Object ItemId -CEQ 'sel')[0]).Channel -cne '' -or (@($irRows | Where-Object ItemId -CEQ 'sel')[0]).Location -cne 'E:\only-inventory'){throw 'Inventory-only row did not carry the inventory DiscoveryStatus, empty channel and Settings.Path location.'}
        if((@($irRows | Where-Object ItemId -CEQ 'cap')[0]).DiscoveryStatus -cne 'Success' -or (@($irRows | Where-Object ItemId -CEQ 'cfg')[0]).DiscoveryStatus -cne ''){throw 'DiscoveryStatus must come from the inventory item when present and be empty otherwise.'}
        $irFirstNot=-1;$irLastBacked=-1;for($irIndex=0;$irIndex -lt $irRows.Count;$irIndex++){if($irRows[$irIndex].Status -ceq 'BackedUp'){$irLastBacked=$irIndex}elseif($irFirstNot -lt 0){$irFirstNot=$irIndex}}
        if($irLastBacked -ge $irFirstNot){throw 'Backup item rows must list BackedUp before NotBackedUp.'}
        $irOfflineRows=@(Get-WsmBackupItemResultRows ([pscustomobject]@{Items=@((& $irItem 'nonc2' 'NonC with records' (& $irFile 'NonC') 'Include'))}) $null @([pscustomobject]@{ItemId='nonc2';RelativePath='x.txt';Directory=$false;Data=[pscustomobject]@{Bytes=3}}) $true)
        if($irOfflineRows.Count -ne 1 -or $irOfflineRows[0].Status -cne 'BackedUp' -or $irOfflineRows[0].ReasonCode -cne 'PayloadCaptured'){throw 'An offline full-set NonC Include with captured records must be BackedUp.'}
        $softwarePlan=[pscustomobject]@{Items=@();GeneralHost=[pscustomobject]@{
            SoftwareCatalog=[pscustomobject]@{Entries=@(
                [pscustomobject]@{SoftwareId='sw-a1';Name='Contoso Tool';Version='1.0';Publisher='Contoso';Architecture='x64';Scope='Machine';Location='C:\a';SourceKind='Uninstall'},
                [pscustomobject]@{SoftwareId='sw-a2';Name='Contoso Tool';Version='2.0';Publisher='Contoso';Architecture='x64';Scope='Machine';Location='C:\b';SourceKind='Uninstall'},
                [pscustomobject]@{SoftwareId='sw-z';Name='Zeta Agent';Version='';Publisher='Zeta';Architecture='x86';Scope='User';Location='';SourceKind='Uninstall'});
                Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='64';Status='Success';EvidenceKind='Registry';Count=2},[pscustomobject]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-1';View='64';Status='Partial';EvidenceKind='Registry';Count=0})}
            SoftwareDecisions=@([pscustomobject]@{SoftwareId='sw-a1';Disposition='Reinstall'})}}
        $softwareInventory=[pscustomobject]@{Items=@([pscustomobject]@{ItemId='feat1';Name='Web Server (IIS)';Kind='WindowsFeature';Category='Roles';NaturalKey='Web-Server';Settings=[pscustomobject]@{};Status='Success'},[pscustomobject]@{ItemId='other1';Name='Not a feature';Kind='DataRoot';Category='Storage';NaturalKey='x';Settings=[pscustomobject]@{};Status='Success'})}
        $softwareResult=Get-WsmBackupSoftwareRows $softwarePlan $softwareInventory
        $softwareRowsA=@($softwareResult.SoftwareRows | Where-Object Name -CEQ 'Contoso Tool');$softwareRowZ=@($softwareResult.SoftwareRows | Where-Object SoftwareId -CEQ 'sw-z')
        if(@($softwareResult.SoftwareRows).Count -ne 3 -or $softwareRowsA.Count -ne 2 -or $softwareRowsA[0].Version -cne '1.0' -or $softwareRowsA[1].Version -cne '2.0'){throw 'Same-named software with different versions must be listed as separate rows.'}
        if($softwareRowZ[0].Version -cne '未知'){throw 'A blank software version must display as the unknown label.'}
        if($softwareRowsA[0].Disposition -cne 'Reinstall' -or $softwareRowsA[0].DispositionText -cne '新機重新安裝'){throw 'A Reinstall decision must show its Chinese disposition text.'}
        if($softwareRowsA[1].Disposition -cne 'Undecided' -or $softwareRowsA[1].DispositionText -cne '尚未決定' -or $softwareRowZ[0].DispositionText -cne '尚未決定'){throw 'Software without a decision must show the undecided text.'}
        if(@($softwareResult.FeatureRows).Count -ne 1 -or $softwareResult.FeatureRows[0].FeatureName -cne 'Web-Server' -or $softwareResult.FeatureRows[0].Name -cne 'Web Server (IIS)'){throw 'WindowsFeature inventory rows must be listed with their installable feature name.'}
        if(@($softwareResult.CoverageGaps).Count -ne 1 -or $softwareResult.CoverageGaps[0].Status -cne 'Partial'){throw 'Only non-Success coverage rows may be reported as software coverage gaps.'}
        # A failure while building the result set must not fail the backup itself.
        $script:backupOriginalItemRows=(Get-Command Get-WsmBackupItemResultRows -CommandType Function).ScriptBlock
        function script:Get-WsmBackupItemResultRows {param($Plan,$Inventory,[object[]]$ArtifactRows,[bool]$OfflineFullSet);throw 'Injected item result failure.'}
        $itemFailureOperation=[Guid]::NewGuid().ToString('D');$itemFailureToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $itemFailureOperation
        try{$itemFailureResult=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $itemFailureOperation -DeliveryMode Directory -VolumeBytes 0 -Jobs @() -CancellationToken $itemFailureToken}
        finally{Set-Item -Path Function:\script:Get-WsmBackupItemResultRows -Value $script:backupOriginalItemRows;Remove-Variable backupOriginalItemRows -Scope Script -ErrorAction SilentlyContinue}
        if($itemFailureResult.Status -cne 'Delivered' -or $itemFailureResult.ItemResults.Status -cne 'Failed' -or $itemFailureResult.ItemResults.Error -notlike '*Injected item result failure*'){throw 'A failure while generating backup item results must leave the backup Delivered and record ItemResults as Failed.'}
        Write-Host 'PASS: backup item results.'
        $script:backupFixtureFingerprint=('a'*64)
        $viewOperationId=[Guid]::NewGuid().ToString('D');$viewToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $viewOperationId
        $viewBackup=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $viewOperationId -DeliveryMode Directory -VolumeBytes 0 -Jobs @() -CancellationToken $viewToken
        if($viewBackup.Status -cne 'Delivered' -or $viewBackup.ItemResults.Status -cne 'Generated'){throw 'The backup used by the item results view test must be delivered with generated item results.'}
        $itemView=Get-WsmWizardBackupItemResultsView $sourceRoot $catalog.PairId
        if($itemView.available -ne $true -or $itemView.integrity -cne 'Verified' -or @($itemView.rows).Count -ne [int]$itemView.counts.Total -or $itemView.attemptId -cne [string]$viewBackup.AttemptId -or $itemView.backupOperationId -cne $viewOperationId){throw 'The item results view must verify and return the latest delivered backup.'}
        $viewResultPath=[string]$viewBackup.ItemResults.Path;$viewOriginalBytes=[IO.File]::ReadAllBytes($viewResultPath)
        try{
            $tamperedBytes=[byte[]]$viewOriginalBytes.Clone();$tamperedBytes[$tamperedBytes.Length-2]=[byte](($tamperedBytes[$tamperedBytes.Length-2]+1) % 256);[IO.File]::WriteAllBytes($viewResultPath,$tamperedBytes)
            $tamperedView=Get-WsmWizardBackupItemResultsView $sourceRoot $catalog.PairId
            if($tamperedView.available -ne $false -or $tamperedView.integrity -cne 'Failed'){throw 'A modified item results file must make the view fail integrity.'}
        }finally{[IO.File]::WriteAllBytes($viewResultPath,$viewOriginalBytes)}
        if((Get-WsmWizardBackupItemResultsView $sourceRoot $catalog.PairId).integrity -cne 'Verified'){throw 'Restoring the original item results bytes must verify again.'}
        foreach($guideFileName in @('offline-guide.html','offline-guide.txt')){
            $viewGuidePath=Join-Path (Split-Path -Parent ([string]$viewBackup.Delivery.Path)) $guideFileName;$viewGuideBytes=[IO.File]::ReadAllBytes($viewGuidePath)
            try{
                $guideTamper=[byte[]]$viewGuideBytes.Clone();$guideTamper[$guideTamper.Length-1]=[byte]($guideTamper[$guideTamper.Length-1] -bxor 0x01);[IO.File]::WriteAllBytes($viewGuidePath,$guideTamper)
                $guideView=Get-WsmWizardBackupItemResultsView $sourceRoot $catalog.PairId
                if($guideView.available -ne $false -or $guideView.integrity -cne 'Failed' -or $guideView.reason -notlike '*離線使用說明*'){throw ('A modified '+$guideFileName+' must make the delivery verification fail.')}
                [IO.File]::Delete($viewGuidePath)
                $guideMissingView=Get-WsmWizardBackupItemResultsView $sourceRoot $catalog.PairId
                if($guideMissingView.available -ne $false -or $guideMissingView.integrity -cne 'Failed'){throw ('A missing '+$guideFileName+' must make the delivery verification fail.')}
            }finally{[IO.File]::WriteAllBytes($viewGuidePath,$viewGuideBytes)}
        }
        if((Get-WsmWizardBackupItemResultsView $sourceRoot $catalog.PairId).integrity -cne 'Verified'){throw 'Restoring the offline guide bytes must verify the delivery again.'}
        Write-Host 'PASS: offline guide delivery verification.'
        $targetRejected=$false;try{[void](Get-WsmHtmlView $targetRoot $catalog.PairId 'backup-items' 'Target')}catch{$targetRejected=($_.Exception.Message -like '*only available to the Source role*')}
        if(-not $targetRejected){throw 'The backup-items view must be rejected for the Target role.'}
        Write-Host 'PASS: backup item results view.'
        $synthRowTemplate={param([string]$Name,[string]$Status)[pscustomobject][ordered]@{ItemId=[Guid]::NewGuid().ToString('D');Name=$Name;Kind='DataRoot';Category='Storage';Location='C:\synthetic\'+$Name;Channel='C';Status=$Status;ReasonCode='PayloadCaptured';Reason='synthetic reason';NextStep='synthetic next step';Files=1;Bytes=[long]2048;Decision='Include';DiscoveryStatus='Present'}}
        $synthWrite={
            param([string]$FileName,[object[]]$Rows,[string]$InventorySource)
            $synthPath=Join-Path $Root $FileName
            Write-WsmJson $synthPath ([pscustomobject][ordered]@{SchemaVersion=1;Kind='BackupItemResults';PairId='synthetic-pair';AttemptId='synthetic-attempt';PlanHash=('c'*64);ManifestHash=('d'*64);InventorySource=$InventorySource;GeneratedUtc='2026-10-20T00:00:00Z';Counts=[pscustomobject]@{Total=@($Rows).Count};Software=[pscustomobject][ordered]@{SoftwareRows=@();FeatureRows=@();CoverageGaps=@()};Rows=@($Rows)})
            $synthPath
        }
        $bigRows=@(1..2500|ForEach-Object {& $synthRowTemplate ('synthetic-item-{0:D4}' -f $_) 'BackedUp'})
        $bigPath=& $synthWrite 'synthetic-big.json' $bigRows 'TrustedInventory'
        $bigReport=Export-WsmBackupOfflineReport $bigPath (Get-FileHash -LiteralPath $bigPath -Algorithm SHA256).Hash (Join-Path $Root 'synthetic-big.html')
        $bigBytes=[IO.File]::ReadAllBytes($bigReport.Path)
        if($bigBytes.Length -ge 3 -and $bigBytes[0] -eq 0xEF -and $bigBytes[1] -eq 0xBB -and $bigBytes[2] -eq 0xBF){throw 'The offline report must be UTF-8 without a BOM.'}
        if($bigReport.SHA256 -cne (Get-FileHash -LiteralPath $bigReport.Path -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'The offline report export must return the lowercase SHA256 of the written file.'}
        $bigHtml=[Text.Encoding]::UTF8.GetString($bigBytes)
        if($bigHtml.IndexOf('synthetic-item-2500',[StringComparison]::Ordinal) -lt 0 -or $bigHtml.IndexOf('synthetic-item-0001',[StringComparison]::Ordinal) -lt 0){throw 'The offline report must list every row without truncation.'}
        $xssName='</script><img src=x onerror=alert(1)>'
        $xssPath=& $synthWrite 'synthetic-xss.json' @((& $synthRowTemplate $xssName 'BackedUp'),(& $synthRowTemplate $xssName 'NotBackedUp')) 'Unavailable'
        $xssReport=Export-WsmBackupOfflineReport $xssPath (Get-FileHash -LiteralPath $xssPath -Algorithm SHA256).Hash (Join-Path $Root 'synthetic-xss.html')
        $xssHtml=[IO.File]::ReadAllText($xssReport.Path,[Text.Encoding]::UTF8)
        if($xssHtml.IndexOf('<img src=x',[StringComparison]::Ordinal) -ge 0 -or $xssHtml.IndexOf('&lt;img src=x',[StringComparison]::Ordinal) -lt 0){throw 'Data values in the offline report must be HTML-encoded.'}
        $emptyPath=& $synthWrite 'synthetic-empty.json' @() 'PackageControls'
        $emptyReport=Export-WsmBackupOfflineReport $emptyPath (Get-FileHash -LiteralPath $emptyPath -Algorithm SHA256).Hash (Join-Path $Root 'synthetic-empty.html')
        $emptyHtml=[IO.File]::ReadAllText($emptyReport.Path,[Text.Encoding]::UTF8)
        foreach($sectionId in @('backed','pending','software')){
            $sectionStart=$emptyHtml.IndexOf('<section id="'+$sectionId+'"',[StringComparison]::Ordinal)
            if($sectionStart -lt 0){throw ('The empty offline report must still contain section '+$sectionId+'.')}
            $sectionEnd=$emptyHtml.IndexOf('</section>',$sectionStart,[StringComparison]::Ordinal)
            if($emptyHtml.Substring($sectionStart,$sectionEnd-$sectionStart).IndexOf('沒有項目',[StringComparison]::Ordinal) -lt 0){throw ('The empty offline report section '+$sectionId+' must say there are no items.')}
        }
        $wrongHashRejected=$false
        try{[void](Export-WsmBackupOfflineReport $bigPath ('0'*64) (Join-Path $Root 'synthetic-wrong.html'))}catch{$wrongHashRejected=$true}
        if(-not $wrongHashRejected -or [IO.File]::Exists((Join-Path $Root 'synthetic-wrong.html'))){throw 'A wrong expected SHA256 must be rejected before any report is written.'}
        Write-Host 'PASS: offline backup report.'
        # Separate mutable FileScope approval proves the cancellation boundary is
        # reached before the producer-freeze provider could be invoked.
        . (Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1')
        # An already-used pair cannot be rebound to another plan. Exercise the
        # mutable approval on a distinct core-created pair, preserving ownership
        # and all prior immutable attempt material.
        $managerRoot=Join-Path $Root 'manager-freeze';Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target-freeze'
        $mutableSpec=$spec|ConvertTo-Json -Depth 40|ConvertFrom-Json;$mutableSpec.Consistency='OwnerFreeze';$mutableSpecPath=Join-Path $Root 'mutable-spec.json';Write-WsmJson $mutableSpecPath $mutableSpec
        Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $mutableSpecPath (Get-FileHash -LiteralPath $mutableSpecPath -Algorithm SHA256).Hash 0
        Set-WsmDecision $managerRoot $catalog.PairId @($item.ItemId) Include 'Explicit mutable fixture selection' 1|Out-Null
        $mutablePlanPath=Join-Path $Root 'mutable-approved-plan.json';$mutableApproval=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $mutablePlanPath 2 'ISOLATED-PILOT'
        $mutablePlan=Read-WsmMigrationPlan $mutablePlanPath $mutableApproval.SHA256;$mutableImport=Import-WsmWizardApprovedPlan $sourceRoot Source $mutablePlanPath $mutableApproval.SHA256
        if($mutableImport.Status -cne 'ImportedVerified'){throw 'Mutable FileScope fixture did not import its newly approved, target-bound plan.'}
        $freezeReadiness=New-WsmSourceFreezeEvidenceFixture -Plan $mutablePlan -PlanHash $mutableApproval.SHA256 -Root $Root -Owner 'Fixture freeze owner'
        $freezeCancelOperation=[Guid]::NewGuid().ToString('D');$freezeCancelToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $mutableApproval.SHA256 -OperationId $freezeCancelOperation;Request-WsmCancellation -Token $freezeCancelToken -Owner 'Fixture operator' -Evidence 'Cancel before source producer freeze'|Out-Null
        $script:backupOriginalFreeze=(Get-Command Export-WsmFreezeRecord -CommandType Function).ScriptBlock;$script:backupFreezeCalls=0
        function script:Export-WsmFreezeRecord { param([string]$PlanPath,[string]$ExpectedHash,[string]$Path,[string]$Owner,[string]$Evidence,[string]$Acknowledgement,[string]$SourceStateDirectory,[string]$FreezeExternalEvidencePath,[string]$FreezeExternalEvidenceHash,[string]$FreezeEpoch,[switch]$Confirm) $script:backupFreezeCalls++;throw 'Freeze provider must not run for a pre-requested cancellation.' }
        $freezeCancelled=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $freezeCancelOperation -Owner 'Fixture freeze owner' -Evidence 'Fixture evidence' -FreezeExternalEvidencePath $freezeReadiness.Path -FreezeExternalEvidenceHash $freezeReadiness.SHA256 -FreezeAuthorization -Jobs @() -CancellationToken $freezeCancelToken|Out-Null}catch{$freezeCancelled=$true}
        $freezeProviderCalls=$script:backupFreezeCalls;Set-Item -Path Function:\script:Export-WsmFreezeRecord -Value $script:backupOriginalFreeze;Remove-Variable backupOriginalFreeze,backupFreezeCalls -Scope Script -ErrorAction SilentlyContinue
        $freezeCancelRecord=Read-WsmJson (Join-Path (Get-WsmWizardBackupRoot $sourceRoot $catalog.PairId) ($freezeCancelOperation+'.json'))
        if(-not $freezeCancelled -or $freezeProviderCalls -ne 0 -or $freezeCancelRecord.Stage -cne 'Cancelled' -or $freezeCancelRecord.FreezeAttemptStarted -or $freezeCancelRecord.SourceResumeRequired -or $freezeCancelRecord.Freeze){throw 'A pre-requested cancellation invoked source freeze or recorded a partial producer change.'}
        # ---- B7: D3b delivery fault cases (disk full, media pulled mid-copy, crash retry without mixing generations) ----
        # Only the fault is substituted (a member copy / stream copy / cancellation-boundary seam); capture, sealing, verification and delivery are the production code.
        $b7Pair=[string]$import.PairId;$b7Plan=[string]$approved.SHA256;$b7DiskFull=[int]'-2147024784'
        $b7Profile=Read-WsmOutputProfile $sourceRoot
        function B7Start([string]$Mode,[long]$Volume,[string]$Op){$t=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $b7Pair -PlanHash $b7Plan -OperationId $Op;Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $b7Pair -OperationId $Op -DeliveryMode $Mode -VolumeBytes $Volume -Jobs @() -CancellationToken $t}
        function B7Try([scriptblock]$Action){try{& $Action|Out-Null;$null}catch{$_.Exception}}
        function B7Attempt([string]$Op){(Get-WsmWizardBackupAttemptForOperation $sourceRoot $b7Pair (Read-WsmOutputProfile $sourceRoot) $Op).Attempt}
        function B7HasHResult($Exception,[int]$HResult){$e=$Exception;while($e){if($e.HResult -eq $HResult){return $true};$e=$e.InnerException};$false}
        function B7Tree([string]$Directory){(@(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}) -join "`n")}
        function B7Find([string]$Directory,[string[]]$Patterns){@(Get-ChildItem -LiteralPath $Directory -Recurse -Force -ErrorAction SilentlyContinue|Where-Object {$name=$_.Name;@($Patterns|Where-Object {$name -like $_}).Count -gt 0})}
        function B7ReceiptCount(){$dir=Join-Path (Get-WsmWizardBackupRoot $sourceRoot $b7Pair) 'independent-copies';if([IO.Directory]::Exists($dir)){@(Get-ChildItem -LiteralPath $dir -File -Force).Count}else{0}}
        $b7OrigCopyMember=(Get-Command Copy-WsmOutputMember -CommandType Function).ScriptBlock
        $b7OrigStreamCopy=(Get-Command Copy-WsmCancellableStream -CommandType Function).ScriptBlock
        $b7OrigWritePayload=(Get-Command Write-WsmPayloadFile -CommandType Function).ScriptBlock
        $b7OrigBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock
        $b7OrigMediaClass=(Get-Command Get-WsmIndependentCopyMediaClass -CommandType Function).ScriptBlock
        $b7SettingsPath=Join-Path $sourceData 'settings.ini';$b7SecondPath=Join-Path $sourceData 'second.txt'
        $b7MediaDir='';$b7Letter=''
        try {
            # Case 1: disk full while the Directory delivery copies its 2nd member.
            $b7PrevDir=[string]$result.Delivery.Directory;$b7PrevTree=B7Tree $b7PrevDir;$b7PrevSummary=(Get-FileHash -LiteralPath ([string]$result.Delivery.Path) -Algorithm SHA256).Hash
            $b7Op1=[Guid]::NewGuid().ToString('D');$script:b7Calls=0;$script:b7OrigCopyMember=$b7OrigCopyMember
            function script:Copy-WsmOutputMember {param([string]$Source,[string]$Destination,[long]$ExpectedBytes,[string]$ExpectedHash,$CancellationToken=$null);$script:b7Calls++;if($script:b7Calls -eq 2){throw (New-Object IO.IOException('There is not enough space on the disk.',[int]'-2147024784'))};& $script:b7OrigCopyMember $Source $Destination $ExpectedBytes $ExpectedHash $CancellationToken}
            try{$b7Ex1=B7Try {B7Start Directory 0 $b7Op1}}finally{Set-Item -Path Function:\script:Copy-WsmOutputMember -Value $b7OrigCopyMember}
            if(-not $b7Ex1 -or -not (B7HasHResult $b7Ex1 $b7DiskFull) -or $script:b7Calls -lt 2){throw 'B7 case 1: a disk-full IOException during Directory delivery did not fail the backup.'}
            $b7A1=B7Attempt $b7Op1
            if($b7A1.Stage -cne 'Failed' -or $b7A1.ResumeStage -cne 'PackageVerified' -or $b7A1.Delivery -or $b7A1.PSObject.Properties['ItemResults'] -or (ConvertTo-WsmWizardBackupResult $b7A1 $b7Op1).OfflineReadiness -cne 'NotDelivered'){throw ('B7 case 1: failed delivery was reported as delivered. stage='+$b7A1.Stage+' resume='+$b7A1.ResumeStage)}
            $b7Leftover=@(B7Find ([string]$b7A1.OutputRoot) @('delivery','delivery-*','.d-*','*.partial','backup-report.html','backup-item-results.json'))
            if($b7Leftover.Count){throw ('B7 case 1: failed delivery left a sealed member, summary, receipt, index or partial: '+(($b7Leftover|ForEach-Object FullName) -join '; '))}
            if((B7Tree $b7PrevDir) -cne $b7PrevTree -or (Get-FileHash -LiteralPath ([string]$result.Delivery.Path) -Algorithm SHA256).Hash -cne $b7PrevSummary){throw 'B7 case 1: an earlier valid delivery set was changed by the failed one.'}
            Write-Host 'PASS: B7 disk full during Directory delivery.'

            # Case 3 (same attempt, retried): a short write that reports success must still be refused before the directory is sealed.
            $b7Op1b=[Guid]::NewGuid().ToString('D');$script:b7Calls=0
            function script:Copy-WsmOutputMember {param([string]$Source,[string]$Destination,[long]$ExpectedBytes,[string]$ExpectedHash,$CancellationToken=$null);$script:b7Calls++;& $script:b7OrigCopyMember $Source $Destination $ExpectedBytes $ExpectedHash $CancellationToken;if($script:b7Calls -eq 2){$fs=[IO.File]::Open($Destination,'Open','Write','None');try{$fs.SetLength($fs.Length-1)}finally{$fs.Dispose()}}}
            try{$b7Ex1b=B7Try {B7Start Directory 0 $b7Op1b}}finally{Set-Item -Path Function:\script:Copy-WsmOutputMember -Value $b7OrigCopyMember}
            $b7A1b=B7Attempt $b7Op1b
            if(-not $b7Ex1b -or $b7A1b.Stage -cne 'Failed' -or $b7A1b.Delivery){throw 'B7 case 3: a silently truncated member was accepted into the sealed directory delivery.'}
            $b7Leftover=@(B7Find ([string]$b7A1b.OutputRoot) @('delivery','delivery-*','.d-*','*.partial','backup-report.html'))
            if($b7Leftover.Count){throw ('B7 case 3: truncated delivery was renamed or left behind: '+(($b7Leftover|ForEach-Object FullName) -join '; '))}
            Write-Host 'PASS: B7 short write refused before sealing.'

            # Recovery: same attempt, space available again.
            $b7Op1c=[Guid]::NewGuid().ToString('D');$b7R1=B7Start Directory 0 $b7Op1c
            $b7A1c=B7Attempt $b7Op1c
            if($b7R1.Status -cne 'Delivered' -or $b7A1c.AttemptId -cne $b7A1.AttemptId -or @($b7A1c.OperationIds).Count -ne 3 -or -not [IO.Directory]::Exists([string]$b7R1.Delivery.Directory)){throw 'B7 case 1: the retry did not finish the same attempt after space returned.'}
            $b7Pkg1=Test-WsmMigrationPackage (Join-Path ([string]$b7R1.Delivery.Directory) 'manifest.json') ((Get-FileHash -LiteralPath (Join-Path ([string]$b7R1.Delivery.Directory) 'manifest.json') -Algorithm SHA256).Hash)
            if(-not $b7Pkg1.Valid -or $b7Pkg1.Manifest.Generation -ne [int]$b7A1c.CoreExport.Generation){throw 'B7 case 1: retried delivery is not the sealed generation.'}
            if((B7Tree $b7PrevDir) -cne $b7PrevTree){throw 'B7 case 1: retry changed an earlier valid delivery set.'}

            # Case 2: disk full / short write while writing a ZIP volume; the .partial must never become a formal volume.
            $b7PrevZipTree=B7Tree (Split-Path -Parent ([string]$zipResult.Delivery.Path))
            $b7Op2=[Guid]::NewGuid().ToString('D');$script:b7Calls=0;$script:b7OrigStreamCopy=$b7OrigStreamCopy
            function script:Copy-WsmCancellableStream {param($InputStream,$OutputStream,$CancellationToken=$null,[string]$Phase='CopyBuffer');if($Phase -ceq 'ZipWriteBuffer'){$script:b7Calls++;if($script:b7Calls -eq 2){throw (New-Object IO.IOException('There is not enough space on the disk.',[int]'-2147024784'))}};& $script:b7OrigStreamCopy $InputStream $OutputStream $CancellationToken $Phase}
            try{$b7Ex2=B7Try {B7Start Zip 134217728 $b7Op2}}finally{Set-Item -Path Function:\script:Copy-WsmCancellableStream -Value $b7OrigStreamCopy}
            $b7A2=B7Attempt $b7Op2
            if(-not $b7Ex2 -or -not (B7HasHResult $b7Ex2 $b7DiskFull) -or $b7A2.Stage -cne 'Failed' -or $b7A2.ResumeStage -cne 'PackageVerified' -or $b7A2.Delivery){throw 'B7 case 2: a disk-full IOException while writing a ZIP volume did not fail the backup.'}
            $b7Formal=@(B7Find ([string]$b7A2.OutputRoot) @('package-*.zip','transport.json','delivery-index-*','backup-report.html'))
            if($b7Formal.Count){throw ('B7 case 2: a failed ZIP volume was renamed to a formal member or sealed: '+(($b7Formal|ForEach-Object FullName) -join '; '))}
            $b7State=@(B7Find ([string]$b7A2.OutputRoot) @('zip-state.json'));if($b7State.Count -ne 1 -or (Read-WsmJson $b7State[0].FullName).Status -cne 'Failed'){throw 'B7 case 2: the ZIP checkpoint did not record the failure.'}
            Write-Host 'PASS: B7 disk full during ZIP volume write.'
            $b7Op2b=[Guid]::NewGuid().ToString('D')
            function script:Copy-WsmCancellableStream {param($InputStream,$OutputStream,$CancellationToken=$null,[string]$Phase='CopyBuffer');if($Phase -ceq 'ZipWriteBuffer'){$buffer=New-Object byte[] 8;$read=$InputStream.Read($buffer,0,$buffer.Length);if($read -gt 0){$OutputStream.Write($buffer,0,$read-1)};return};& $script:b7OrigStreamCopy $InputStream $OutputStream $CancellationToken $Phase}
            try{$b7Ex2b=B7Try {B7Start Zip 134217728 $b7Op2b}}finally{Set-Item -Path Function:\script:Copy-WsmCancellableStream -Value $b7OrigStreamCopy}
            $b7A2b=B7Attempt $b7Op2b
            $b7Formal=@(B7Find ([string]$b7A2b.OutputRoot) @('package-*.zip','transport.json','delivery-index-*','backup-report.html'))
            if(-not $b7Ex2b -or $b7A2b.Stage -cne 'Failed' -or $b7A2b.Delivery -or $b7Formal.Count){throw ('B7 case 2: a short-written ZIP .partial was renamed to a formal volume: '+(($b7Formal|ForEach-Object FullName) -join '; '))}
            Write-Host 'PASS: B7 short-written ZIP volume refused before rename.'
            $b7Op2c=[Guid]::NewGuid().ToString('D');$b7R2=B7Start Zip 134217728 $b7Op2c;$b7A2c=B7Attempt $b7Op2c
            if($b7R2.Status -cne 'Delivered' -or $b7A2c.AttemptId -cne $b7A2.AttemptId -or @(B7Find ([string]$b7A2c.OutputRoot) @('*.partial')).Count){throw 'B7 case 2: the ZIP retry did not finish the same attempt or left a .partial behind.'}
            $b7Zip=Read-WsmTrustedJson $b7R2.Delivery.Path $b7R2.Delivery.SHA256
            foreach($volume in @($b7Zip.Volumes)){if((Get-FileHash -LiteralPath (Join-Path (Split-Path -Parent $b7R2.Delivery.Path) $volume.Name) -Algorithm SHA256).Hash -ine $volume.Hash){throw 'B7 case 2: a retried ZIP volume differs from its descriptor.'}}
            $b7ZipImport=Import-WsmPackageZip -TransportPath $b7R2.Delivery.Path -ExpectedHash $b7R2.Delivery.SHA256 -OutputDirectory (Join-Path $Root 'b7-zip-imported')
            $b7ZipPkg=Test-WsmMigrationPackage $b7ZipImport.ManifestPath $b7ZipImport.SHA256
            if(-not $b7ZipPkg.Valid -or $b7ZipPkg.Manifest.Generation -ne [int]$b7A2c.CoreExport.Generation -or $b7ZipPkg.Manifest.PackageId -cne (Read-WsmJson ([string]$b7A2c.CoreExport.ManifestPath)).PackageId){throw 'B7 case 2: the retried ZIP is not the sealed package set.'}
            if((B7Tree (Split-Path -Parent ([string]$zipResult.Delivery.Path))) -cne $b7PrevZipTree){throw 'B7 case 2: an earlier valid ZIP delivery was changed.'}

            # Case 5: independent copy. Disk full, then the medium is pulled in the middle of Copy, then re-inserted.
            $b7Letter=(@('R','S','T','U','V','W','X','Y','Z')|Where-Object {$_ -cne $Root.Substring(0,1) -and -not (Test-Path -LiteralPath ($_+':\'))}|Select-Object -First 1)
            if(-not $b7Letter){throw 'B7 case 5: no free drive letter for the removable-medium fixture.'}
            $b7MediaDir=Join-Path ([IO.Path]::GetTempPath()) ('wsmwb-media-'+[Guid]::NewGuid().ToString('N').Substring(0,8));[void][IO.Directory]::CreateDirectory($b7MediaDir)
            function B7Subst([string]$Letter,[string]$Path){cmd.exe /c ('subst '+$Letter+': "'+$Path+'"')|Out-Null;if($LASTEXITCODE -ne 0){throw 'B7: unable to map the removable-medium fixture drive.'}}
            function B7Unsubst([string]$Letter){cmd.exe /c ('subst '+$Letter+': /D')|Out-Null}
            B7Subst $b7Letter $b7MediaDir
            $script:b7MediaLetter=$b7Letter;$script:b7BoundaryMode='';$script:b7Calls=0;$script:b7OrigBoundary=$b7OrigBoundary
            function script:Get-WsmIndependentCopyMediaClass {param($DestinationRoot)'Removable'}
            function Get-WsmIndependentCopyMediaClass {param($DestinationRoot)'Removable'}
            function script:Assert-WsmCancellationBoundary {param($Token,[string]$Phase);if($Phase -ceq 'IndependentCopyFile'){$script:b7Calls++;if($script:b7BoundaryMode -ceq 'DiskFull' -and $script:b7Calls -eq 2){throw (New-Object IO.IOException('There is not enough space on the disk.',[int]'-2147024784'))};if($script:b7BoundaryMode -ceq 'Pull' -and $script:b7Calls -eq 3){cmd.exe /c ('subst '+$script:b7MediaLetter+': /D')|Out-Null}};& $script:b7OrigBoundary $Token $Phase}
            $b7Dest=$b7Letter+':\offline-media';[void][IO.Directory]::CreateDirectory($b7Dest)
            $b7Receipts0=B7ReceiptCount
            function B7Copy([string]$Mode){Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $b7Pair -BackupOperationId $b7Op1c -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $b7Dest -Mode $Mode}
            $b7CopyRoot=Join-Path $b7Dest ('wsm-offline-'+$b7Pair+'-'+[string]$b7A1c.AttemptId)
            try{
                $script:b7BoundaryMode='DiskFull';$script:b7Calls=0
                $b7Ex5a=B7Try {B7Copy Copy}
                $b7A5a=B7Attempt $b7Op1c
                if(-not $b7Ex5a -or -not (B7HasHResult $b7Ex5a $b7DiskFull)){throw ('B7 case 5: the disk-full independent copy did not fail with the disk-full IOException: '+$b7Ex5a)}
                if($b7A5a.IndependentCopy.Status -cne 'Failed' -or (ConvertTo-WsmWizardBackupResult $b7A5a $b7Op1c).OfflineReadiness -cne 'AwaitingIndependentCopy'){throw ('B7 case 5: a failed independent copy was recorded as '+$b7A5a.IndependentCopy.Status+' stage='+$b7A5a.Stage)}
                if((B7ReceiptCount) -ne $b7Receipts0 -or @(B7Find $b7Dest @('*.partial')).Count){throw 'B7 case 5: a disk-full independent copy wrote a receipt or left a .partial.'}
                $script:b7BoundaryMode='Pull';$script:b7Calls=0
                $b7Ex5b=B7Try {B7Copy Copy}
                $b7Pulled=-not [IO.Directory]::Exists($b7Letter+':\')
                $b7A5b=B7Attempt $b7Op1c
                if(-not $b7Ex5b -or -not $b7Pulled -or $b7A5b.IndependentCopy.Status -cne 'Failed' -or (ConvertTo-WsmWizardBackupResult $b7A5b $b7Op1c).OfflineReadiness -cne 'AwaitingIndependentCopy' -or (B7ReceiptCount) -ne $b7Receipts0){throw ('B7 case 5: pulling the medium mid-copy did not fail without a receipt. pulled='+$b7Pulled+' error='+$b7Ex5b)}
                $b7Partial=@(Get-ChildItem -LiteralPath $b7MediaDir -Recurse -File -Force|Where-Object Name -like '*.partial')
                if($b7Partial.Count){throw 'B7 case 5: the pulled medium holds an unfinished .partial member.'}
                B7Subst $b7Letter $b7MediaDir
                $script:b7BoundaryMode=''
                $b7Retry=B7Copy Copy
                if($b7Retry.IndependentCopy.Status -cne 'Verified' -or $b7Retry.OfflineReadiness -cne 'Verified' -or (B7ReceiptCount) -ne $b7Receipts0+1 -or -not [IO.File]::Exists($b7Retry.IndependentCopy.ReceiptPath)){throw 'B7 case 5: the same backup set could not be re-copied onto the re-inserted medium.'}
                foreach($blob in @(Get-ChildItem -LiteralPath (Join-Path ([string]$b7R1.Delivery.Directory) 'payload') -Filter '*.blob' -File)){$copied=Join-Path $b7CopyRoot ('transport\delivery\payload\'+$blob.Name);if(-not [IO.File]::Exists($copied) -or (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ine (Get-FileHash -LiteralPath $blob.FullName -Algorithm SHA256).Hash){throw ('B7 case 5: re-copied member differs from the sealed delivery: '+$blob.Name)}}
                $b7Verify=B7Copy VerifyExisting
                if($b7Verify.IndependentCopy.Status -cne 'Verified' -or (Read-WsmJson $b7Verify.IndependentCopy.ReceiptPath).Mode -cne 'VerifyExisting'){throw 'B7 case 5: VerifyExisting did not accept the re-inserted copy.'}
            }finally{
                Set-Item -Path Function:\script:Assert-WsmCancellationBoundary -Value $b7OrigBoundary
                Set-Item -Path Function:\script:Get-WsmIndependentCopyMediaClass -Value $b7OrigMediaClass
                Set-Item -Path Function:\Get-WsmIndependentCopyMediaClass -Value $b7OrigMediaClass
            }
            Write-Host 'PASS: B7 independent copy disk full, medium pulled mid-copy and re-copied onto the same set.'

            # Case 4: crash in the middle of capture, source changes, retry captures anew; nothing of the aborted capture is sealed.
            $b7Op4=[Guid]::NewGuid().ToString('D');$script:b7Calls=0;$script:b7OrigWritePayload=$b7OrigWritePayload
            function script:Write-WsmPayloadFile {param($SourcePath,$BlobRoot,$ChunkBytes,$BytesPerSecond,$CancellationToken=$null);$script:b7Calls++;if($script:b7Calls -eq 2){throw 'Injected crash in the middle of package capture.'};& $script:b7OrigWritePayload $SourcePath $BlobRoot $ChunkBytes $BytesPerSecond $CancellationToken}
            try{$b7Ex4=B7Try {B7Start Directory 0 $b7Op4}}finally{Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $b7OrigWritePayload}
            $b7A4=B7Attempt $b7Op4
            if(-not $b7Ex4 -or $b7Ex4.Message -notlike '*Injected crash*' -or $b7A4.Stage -cne 'Failed' -or $b7A4.ResumeStage -cne 'Authorized' -or $b7A4.CoreExport){throw 'B7 case 4: an interrupted capture was recorded as sealed.'}
            $b7Packages=Join-Path ([string]$b7A4.OutputRoot) 'packages'
            if(@(B7Find $b7Packages @('manifest.json')).Count){throw 'B7 case 4: an interrupted capture produced a sealed manifest.'}
            $b7StaleBlobs=@(B7Find $b7Packages @('*.blob')|ForEach-Object {$_.BaseName})
            if($b7StaleBlobs.Count -lt 1){throw 'B7 case 4: the crash fixture left no aborted blob, so the retry proves nothing.'}
            [IO.File]::WriteAllText($b7SettingsPath,'changed after the crash: settings');[IO.File]::WriteAllText($b7SecondPath,'changed after the crash: second')
            $b7Op4b=[Guid]::NewGuid().ToString('D');$b7R4=B7Start Directory 0 $b7Op4b;$b7A4b=B7Attempt $b7Op4b
            if($b7R4.Status -cne 'Delivered' -or $b7A4b.AttemptId -cne $b7A4.AttemptId){throw 'B7 case 4: the retry did not finish the interrupted attempt.'}
            $b7Pkg4=Test-WsmMigrationPackage ([string]$b7A4b.CoreExport.ManifestPath) ([string]$b7A4b.CoreExport.SHA256)
            $b7Rows4=@(Read-WsmArtifactLines (Join-Path $b7Pkg4.Root 'artifacts.jsonl') $b7Pkg4.Manifest.ArtifactsHash)
            $b7Referenced=@($b7Rows4|Where-Object {-not $_.Directory}|ForEach-Object {$_.Data.Chunks}|ForEach-Object {[string]$_.Hash}|Sort-Object -Unique)
            $b7NewHashes=@((Get-FileHash -LiteralPath $b7SettingsPath -Algorithm SHA256).Hash.ToLowerInvariant(),(Get-FileHash -LiteralPath $b7SecondPath -Algorithm SHA256).Hash.ToLowerInvariant()|Sort-Object -Unique)
            if((@($b7Referenced) -join ',') -cne (@($b7NewHashes) -join ',') -or @($b7Referenced|Where-Object {$b7StaleBlobs -contains $_}).Count){throw 'B7 case 4: the retried package references bytes of the aborted capture instead of the new capture.'}
            $b7Delivered=[string]$b7R4.Delivery.Directory;$b7DeliveredBlobs=@(Get-ChildItem -LiteralPath (Join-Path $b7Delivered 'payload') -Filter '*.blob' -File|ForEach-Object {$_.BaseName}|Sort-Object)
            if((@($b7DeliveredBlobs) -join ',') -cne (@($b7Referenced) -join ',') -or @($b7DeliveredBlobs|Where-Object {$b7StaleBlobs -contains $_}).Count){throw 'B7 case 4: the delivery contains a member that does not belong to the sealed generation.'}
            $b7Summary=Read-WsmTrustedJson ([string]$b7R4.Delivery.Path) ([string]$b7R4.Delivery.SHA256)
            foreach($member in @($b7Summary.Members)){if((Get-FileHash -LiteralPath (Join-Path $b7Delivered ([string]$member.Name).Replace('/','\')) -Algorithm SHA256).Hash -ine [string]$member.SHA256){throw ('B7 case 4: delivered member hash differs from the sealed summary: '+$member.Name)}}
            $b7Delivered4=Test-WsmMigrationPackage (Join-Path $b7Delivered 'manifest.json') ((Get-FileHash -LiteralPath (Join-Path $b7Delivered 'manifest.json') -Algorithm SHA256).Hash)
            if($b7Delivered4.Manifest.Generation -ne $b7Pkg4.Manifest.Generation -or $b7Delivered4.Manifest.PackageId -cne $b7Pkg4.Manifest.PackageId -or @(B7Find $b7Pkg4.Root @('artifacts.jsonl.partial','manifest.pending.json')).Count){throw 'B7 case 4: delivered manifest or generation differs from the sealed package, or capture temporaries remain.'}
            Write-Host 'PASS: B7 crash mid-capture and retry did not mix an aborted capture into the sealed generation.'
        } finally {
            foreach($restore in @(@('Copy-WsmOutputMember',$b7OrigCopyMember),@('Copy-WsmCancellableStream',$b7OrigStreamCopy),@('Write-WsmPayloadFile',$b7OrigWritePayload),@('Assert-WsmCancellationBoundary',$b7OrigBoundary),@('Get-WsmIndependentCopyMediaClass',$b7OrigMediaClass))){try{Set-Item -Path ('Function:\script:'+$restore[0]) -Value $restore[1]}catch{Write-Warning ('B7 could not restore '+$restore[0]+': '+$_.Exception.Message)}}
            [IO.File]::WriteAllText($b7SettingsPath,'actual source bytes');[IO.File]::WriteAllText($b7SecondPath,'second source bytes')
            if($b7Letter){try{cmd.exe /c ('subst '+$b7Letter+': /D')|Out-Null}catch{Write-Warning ('B7 could not unmap the removable-medium fixture: '+$_.Exception.Message)}}
            if($b7MediaDir){try{$mediaFull=[IO.Path]::GetFullPath($b7MediaDir);if([IO.Path]::GetDirectoryName($mediaFull).TrimEnd('\') -ieq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and [IO.Path]::GetFileName($mediaFull) -like 'wsmwb-media-*' -and [IO.Directory]::Exists($mediaFull)){Remove-Item -LiteralPath $mediaFull -Recurse -Force}}catch{Write-Warning ('B7 media fixture cleanup failed: '+$_.Exception.Message)}}
        }
        Write-Host 'PASS: B7 delivery fault cases (disk full, short write, medium pulled, crash retry).'
        Write-Host 'PASS: real sealed approval, source host binding, Directory and ZIP export/import, actual payload hash readback, and durable wizard result projection.'
    } $root $backupScriptPath
} finally {
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmwb-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
