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

            # Case b: ZIP / Copy / Network
            $destB = Join-Path $Root 'copy-dest-b'; [void][IO.Directory]::CreateDirectory($destB)
            $script:fixtureMediaClass = 'Network'
            $resB = Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $catalog.PairId -BackupOperationId $zipOperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destB -Mode Copy
            if($resB.OfflineReadiness -cne 'VerifiedNetworkAvailabilityUnconfirmed'){throw 'Case b: ZIP Copy Network OfflineReadiness mismatch.'}

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
        Write-Host 'PASS: real sealed approval, source host binding, Directory and ZIP export/import, actual payload hash readback, and durable wizard result projection.'
    } $root $backupScriptPath
} finally {
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmwb-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
