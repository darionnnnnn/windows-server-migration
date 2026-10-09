#requires -Version 5.1
param([ValidateRange(0,64)][int]$SmallFiles=16)
$ErrorActionPreference='Stop'
$pipelineWatch=[Diagnostics.Stopwatch]::StartNew()
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
. (Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-pipeline-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$sourceRoot=Join-Path $root 'source';$sourceState=Join-Path $root 'source-state';[void][IO.Directory]::CreateDirectory($sourceState);$targetRoot=Join-Path $root 'target';$packages=Join-Path $root 'packages';$workspace=Join-Path $root 'manager';$targetState=Join-Path $root 'target-state'
[void][IO.Directory]::CreateDirectory($sourceRoot);[void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'nested'));[void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'excluded'))
[IO.File]::WriteAllText((Join-Path $sourceRoot 'nested\unicode-中文.txt'),'initial fixture');[IO.File]::WriteAllText((Join-Path $sourceRoot 'excluded\not-selected.txt'),'never packaged')
$large=New-Object byte[] 2500000;for($n=0;$n -lt $large.Length;$n++){$large[$n]=[byte]($n%251)};[IO.File]::WriteAllBytes((Join-Path $sourceRoot 'chunked.bin'),$large)
if($SmallFiles){$smallRoot=Join-Path $sourceRoot 'small-files';[void][IO.Directory]::CreateDirectory($smallRoot);for($n=0;$n -lt $SmallFiles;$n++){[IO.File]::WriteAllText((Join-Path $smallRoot ('file-'+$n+'.txt')),('fixture bytes '+$n))}}
$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source'}
$item=New-WsmItem $source.HostId Storage DataRoot 'Approved data' 'approved-root' @{Path=$sourceRoot}
$inv=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $root 'inventory.json';[IO.File]::WriteAllText($inventoryPath,($inv | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
Initialize-WsmWorkspace $workspace | Out-Null;$catalog=Import-WsmInventory $workspace $inventoryPath (Get-FileHash $inventoryPath).Hash 'fixture-target';$pair=$catalog.PairId
# Only machine identity/collector are substituted; file bytes, ACLs, package hash and restore are real.
& $module {param($InventoryPath) $script:fixtureInventory=$InventoryPath;$script:fixtureFingerprint=('b'*64);function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture';OS='Fixture Server';Version='10.0.fixture';IsServer=$true;Administrator=$true;Is64Bit=$true}};function script:Export-WsmInventory {param($OutputDirectory)[pscustomobject]@{Path=$script:fixtureInventory;SHA256=(Get-FileHash -LiteralPath $script:fixtureInventory).Hash}}} $inventoryPath
$targetIdentity=Join-Path $root 'target-identity.json';$identity=Register-WsmTarget $targetState $targetIdentity
$spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceRoot;TargetPath=$targetRoot;ExcludedRelativePaths=@('excluded');Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='fixture-scope-review';BusinessChecks=@('Read expected fixture file')}
$specPath=Join-Path $root 'scope.json';[IO.File]::WriteAllText($specPath,($spec | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
Set-WsmMigrationSpec $workspace $pair $item.ItemId $specPath (Get-FileHash $specPath).Hash 0
Set-WsmDecision $workspace $pair @($item.ItemId) Include 'fixture approved' 1 | Out-Null
$planPath=Join-Path $root 'plan.json';$approval=Approve-WsmMigrationPlan $workspace $pair $targetIdentity $identity.SHA256 $planPath 2 ISOLATED-PILOT
& $module {$script:fixtureFingerprint=('a'*64)}
$package=Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState $packages -ChunkBytes 65536
if(-not $package.Sealed -or $package.Files -ne (2+$SmallFiles) -or $package.Generation -ne 1){throw 'Initial package counters incorrect.'}
$verified=Test-WsmMigrationPackage $package.ManifestPath $package.SHA256
$directoryDelivery=Export-WsmDirectoryDelivery $package.ManifestPath $package.SHA256 (Join-Path $root 'directory-delivery')
$directoryPackage=Test-WsmMigrationPackage (Join-Path $directoryDelivery.Directory 'manifest.json') $package.SHA256
if($directoryPackage.Manifest.PackageId -cne $verified.Manifest.PackageId -or (Test-Path (Join-Path $directoryDelivery.Directory 'export-state.json'))){throw 'Clean directory delivery did not preserve package identity or leaked export state.'}
$volumeBytes=1MB
    & $module {$script:originalZipVerifier=(Get-Command Test-WsmZipVolume).ScriptBlock;$script:zipFault=$true;function script:Test-WsmZipVolume {param($Path,$Expected,$ExpectedHash='')if($script:zipFault -and $Path -like '*-0002.zip.partial'){$script:zipFault=$false;throw 'Injected ZIP interruption after first sealed volume'};& $script:originalZipVerifier $Path $Expected $ExpectedHash}}
    $zipFailed=$false;try{Export-WsmPackageZip $package.ManifestPath $package.SHA256 (Join-Path $root 'zip') -VolumeBytes $volumeBytes | Out-Null}catch{$zipFailed=$true};if(-not $zipFailed -or (Test-Path (Join-Path $root 'zip\transport.json'))){throw 'ZIP interruption fixture failed or incomplete transport was sealed.'}
$transport=Export-WsmPackageZip $package.ManifestPath $package.SHA256 (Join-Path $root 'zip') -VolumeBytes $volumeBytes
$zipAgain=Export-WsmPackageZip $package.ManifestPath $package.SHA256 (Join-Path $root 'zip') -VolumeBytes $volumeBytes;if($zipAgain.SHA256 -ine $transport.SHA256){throw 'Completed ZIP retry changed trusted transport.'}
if($transport.Volumes -lt 3){throw 'ZIP volume split not enforced.'}
$transportIndex=Get-Content -LiteralPath $transport.Path -Raw -Encoding UTF8 | ConvertFrom-Json
$lastVolume=Join-Path (Split-Path $transport.Path -Parent) $transportIndex.Volumes[-1].Name
$withheldVolume=$lastVolume+'.withheld'
[IO.File]::Move($lastVolume,$withheldVolume)
try{
    $missingRejected=$false;try{Import-WsmPackageZip $transport.Path $transport.SHA256 (Join-Path $root 'missing-volume') | Out-Null}catch{$missingRejected=$true}
    if(-not $missingRejected -or (Test-Path (Join-Path $root ('missing-volume\incoming-'+$verified.Manifest.PackageId)))){throw 'Missing final volume was not rejected before incoming package creation.'}
}finally{[IO.File]::Move($withheldVolume,$lastVolume)}
$unpacked=Import-WsmPackageZip $transport.Path $transport.SHA256 (Join-Path $root 'unpacked')
if($unpacked.SHA256 -ine $package.SHA256 -or -not $unpacked.Valid){throw 'Verified multipart ZIP import failed.'}
if(@(Get-ChildItem (Join-Path $package.Directory 'payload') -Filter *.blob).Count -lt 3){throw 'Large file was not split into bounded payload chunks.'}
if((Get-Content (Join-Path $package.Directory 'artifacts.jsonl') -Raw) -match 'not-selected|never packaged'){throw 'Excluded data leaked.'}
& $module {$script:fixtureFingerprint=('b'*64)}
$preview=Get-WsmRestorePreview $package.ManifestPath $package.SHA256 $targetState
if($preview.Blocked -or $preview.Rows[0].Action -ne 'Create'){throw 'Fresh target preview incorrect.'}
$state=Invoke-WsmRestore $package.ManifestPath $package.SHA256 $targetState
if($state.Stage -ne 'Succeeded' -or (Get-FileHash (Join-Path $targetRoot 'chunked.bin')).Hash -ine (Get-FileHash (Join-Path $sourceRoot 'chunked.bin')).Hash){throw 'File restore/content mismatch.'}
if(Test-Path (Join-Path $targetRoot 'excluded')){throw 'Excluded subtree restored.'}
$timestampFile=Join-Path $targetRoot 'chunked.bin';$savedWrite=[IO.File]::GetLastWriteTimeUtc($timestampFile);[IO.File]::SetLastWriteTimeUtc($timestampFile,$savedWrite.AddSeconds(-30))
$timestampDrift=Get-WsmRestorePreview $package.ManifestPath $package.SHA256 $targetState;if(-not $timestampDrift.Blocked){throw 'Timestamp-only drift was ignored'}
& $module {param($Path,$Hash,$Target)$p=Test-WsmMigrationPackage $Path $Hash;$check=Test-WsmFileScope $p.Plan.Items[0] $p $Target;if($check.Passed -or $check.Problems -notmatch 'timestamp'){throw 'File timestamp was not compared against artifact metadata'}} $package.ManifestPath $package.SHA256 $targetRoot
[IO.File]::SetLastWriteTimeUtc($timestampFile,$savedWrite)
$again=Invoke-WsmRestore $package.ManifestPath $package.SHA256 $targetState;if($again.Items.Count -ne 1){throw 'Retry duplicated ownership rows.'}
if(-not (Test-WsmJournal $targetState $pair).Consistent){throw 'Journal checkpoint/hash chain inconsistent.'}
$checkpointPath=Join-Path (Join-Path $targetState $pair) 'state.json';$oldCheckpoint=[IO.File]::ReadAllText($checkpointPath)
Set-WsmExternalFixtureValidationEvidence $package.ManifestPath $package.SHA256 $targetState $item.ItemId BusinessStaged 'Crash fixture owner' 'durable event before checkpoint crash' $true | Out-Null
[IO.File]::WriteAllText($checkpointPath,$oldCheckpoint,(New-Object Text.UTF8Encoding($false)))
if(-not (Test-WsmJournal $targetState $pair).RecoveryRequired){throw 'Crash boundary not detected.'}
$crashBlocked=$false;try{Invoke-WsmRestore $package.ManifestPath $package.SHA256 $targetState | Out-Null}catch{$crashBlocked=$true};if(-not $crashBlocked){throw 'Restore overwrote incomplete checkpoint.'}
Repair-WsmOperation $package.ManifestPath $package.SHA256 $targetState | Out-Null
if(-not (Test-WsmJournal $targetState $pair).Consistent){throw 'Durable event replay failed.'}
$recovered=Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
if(@($recovered.Evidence | Where-Object Evidence -EQ 'durable event before checkpoint crash').Count -ne 1){throw 'Replay lost durable evidence.'}
# Remove fixture evidence through a durable replacement, so the next assertion still tests missing business acceptance.
Set-WsmExternalFixtureValidationEvidence $package.ManifestPath $package.SHA256 $targetState $item.ItemId BusinessStaged 'Fixture owner' 'not yet accepted' $false | Out-Null
$staged=Invoke-WsmValidation $package.ManifestPath $package.SHA256 $targetState Staged;if($staged.Passed){throw 'Configuration alone incorrectly passed business gate.'}
Set-WsmExternalFixtureValidationEvidence $package.ManifestPath $package.SHA256 $targetState $item.ItemId BusinessStaged 'Fixture owner' 'fixture functional read passed' $true | Out-Null
if(-not (Invoke-WsmValidation $package.ManifestPath $package.SHA256 $targetState Staged).Passed){throw 'Valid business evidence failed.'}
$priorTargetWrite=[IO.Directory]::GetLastWriteTimeUtc($targetRoot);[IO.File]::WriteAllText((Join-Path $targetRoot 'unexpected.txt'),'new target data');$drift=Get-WsmRestorePreview $package.ManifestPath $package.SHA256 $targetState;if(-not $drift.Blocked){throw 'Unowned target change did not block retry.'};[IO.File]::Delete((Join-Path $targetRoot 'unexpected.txt'));[IO.Directory]::SetLastWriteTimeUtc($targetRoot,$priorTargetWrite)
# Final full snapshot replaces only the previously owned root, preserving its rollback root.
& $module {$script:fixtureFingerprint=('a'*64)}
$approvedPlan=& $module {param($Path,$Hash)Read-WsmMigrationPlan $Path $Hash} $planPath $approval.SHA256;$freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $approvedPlan -PlanHash $approval.SHA256 -Root $root -Owner 'Fixture owner'
$freezePath=Join-Path $root 'freeze.json';$freeze=Export-WsmFreezeRecord $planPath $approval.SHA256 $freezePath 'Fixture owner' 'fixture writers quiesced' OWNER-CONFIRMED-QUIESCENCE -SourceIdentityReleased -ReleaseEvidence 'fixture old name and IP withdrawn' -SourceStateDirectory $sourceState -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -FreezeEpoch $freezeProof.FreezeEpoch
$expiredFreeze=Get-Content -LiteralPath $freezePath -Raw | ConvertFrom-Json;$expiredFreeze.ProducedUtc=[DateTime]::UtcNow.AddHours(-2).ToString('o');$expiredFreeze.ExpiresUtc=[DateTime]::UtcNow.AddHours(-1).ToString('o');$expiredPath=Join-Path $root 'expired-freeze.json';[IO.File]::WriteAllText($expiredPath,($expiredFreeze | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))
$renewedProof=New-WsmSourceFreezeEvidenceFixture -Plan $approvedPlan -PlanHash $approval.SHA256 -Root $root -Owner 'Fixture owner';$renewedPath=Join-Path $root 'renewed-freeze.json';$freeze=Export-WsmFreezeRecord $planPath $approval.SHA256 $renewedPath 'Fixture owner' 'renewed owner freeze evidence' OWNER-CONFIRMED-QUIESCENCE -SourceIdentityReleased -ReleaseEvidence 'fixture source remains isolated' -SourceStateDirectory $sourceState -PreviousFreezePath $expiredPath -PreviousFreezeHash (Get-FileHash $expiredPath).Hash -FreezeExternalEvidencePath $renewedProof.Path -FreezeExternalEvidenceHash $renewedProof.SHA256 -FreezeEpoch $renewedProof.FreezeEpoch;$freezePath=$renewedPath
[IO.File]::WriteAllText((Join-Path $sourceRoot 'nested\unicode-中文.txt'),'final fixture');[IO.File]::Delete((Join-Path $sourceRoot 'chunked.bin'))
$final=Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState $packages -ChunkBytes 65536 -BaseManifestPath $package.ManifestPath -BaseManifestHash $package.SHA256 -FreezePath $freezePath -FreezeHash $freeze.SHA256 -FreezeExternalEvidencePath $renewedProof.Path -FreezeExternalEvidenceHash $renewedProof.SHA256
& $module {$script:fixtureFingerprint=('b'*64)}
$restored=Invoke-WsmRestore $final.ManifestPath $final.SHA256 $targetState
if($restored.Generation -ne 2 -or (Test-Path (Join-Path $targetRoot 'chunked.bin')) -or [IO.File]::ReadAllText((Join-Path $targetRoot 'nested\unicode-中文.txt')) -cne 'final fixture'){throw 'Final generation updates/deletion incorrect.'}
if(-not (Test-Path -LiteralPath $restored.Items[0].Backup)){throw 'Owned root rollback point lost.'}
if((Invoke-WsmValidation $final.ManifestPath $final.SHA256 $targetState Staged).Passed){throw 'Old-generation business evidence was reused.'}
Set-WsmExternalFixtureValidationEvidence $final.ManifestPath $final.SHA256 $targetState $item.ItemId BusinessStaged 'Fixture owner' 'final fixture read passed' $true | Out-Null
# Cutover OS commands are replaced; no real computer/network configuration is changed.
& $module {
    $script:fixtureAddresses=@([pscustomobject]@{InterfaceAlias='FixtureNIC';IPAddress='192.0.2.10';PrefixLength=24;AddressState='Preferred'})
    function script:Get-WsmNetworkSnapshot {[pscustomobject]@{Name='fixture';Addresses=$script:fixtureAddresses;DNS=@();Routes=@()}}
    function script:Get-NetAdapter {param($Name,$ErrorAction)[pscustomobject]@{Name=$Name}}
    function script:Get-NetIPAddress {param($InterfaceAlias,$IPAddress,$ErrorAction)$script:fixtureAddresses | Where-Object {$_.InterfaceAlias -eq $InterfaceAlias -and $_.IPAddress -eq $IPAddress}}
    function script:New-NetIPAddress {param($InterfaceAlias,$IPAddress,$PrefixLength,$DefaultGateway,$ErrorAction)$script:fixtureAddresses+=@([pscustomobject]@{InterfaceAlias=$InterfaceAlias;IPAddress=$IPAddress;PrefixLength=$PrefixLength;AddressState='Preferred'})}
    function script:Remove-NetIPAddress {param([Parameter(ValueFromPipeline)]$InputObject,[switch]$Confirm)process{$script:fixtureAddresses=@($script:fixtureAddresses | Where-Object IPAddress -NE $InputObject.IPAddress)}}
    function script:Set-DnsClientServerAddress {param($InterfaceAlias,$ServerAddresses)$script:fixtureDns=$ServerAddresses}
    function script:Get-DnsClientServerAddress {param($InterfaceAlias,$AddressFamily,$ErrorAction)[pscustomobject]@{ServerAddresses=$script:fixtureDns}}
    function script:Get-NetRoute {param($InterfaceAlias,$DestinationPrefix,$ErrorAction)[pscustomobject]@{NextHop='192.0.2.1'}}
}
$network=[pscustomobject]@{FinalName=$env:COMPUTERNAME;InterfaceAlias='FixtureNIC';FinalIP='192.0.2.20';PrefixLength=24;DefaultGateway='192.0.2.1';DnsServers=@('192.0.2.53');TemporaryIP=@('192.0.2.10');DomainProcedureEvidence='fixture domain identity prechecked';RollbackProcedure='fixture stop/reconcile then identity rollback';Owner='Fixture owner';MaintenanceWindowUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');ValidUntilUtc=[DateTime]::UtcNow.AddHours(1).ToString('o')}
$networkPath=Join-Path $root 'network.json';[IO.File]::WriteAllText($networkPath,($network | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
$cutoverPath=Join-Path $root 'cutover.json';$cutover=New-WsmCutoverPlan $final.ManifestPath $final.SHA256 $targetState $networkPath (Get-FileHash $networkPath).Hash $cutoverPath -ExternalEvidenceReferences (New-WsmCutoverEvidenceFixtureReferences -Package (Test-WsmMigrationPackage $final.ManifestPath $final.SHA256) -Root $root)
$activated=Invoke-WsmCutover $final.ManifestPath $final.SHA256 $targetState $cutoverPath $cutover.SHA256 ('CUTOVER '+$pair)
if($activated.Stage -ne 'PostCutoverValidationRequired' -or -not $activated.Cutover.NewTransactionsPossible){throw 'Cutover did not keep final business gate/data rollback boundary.'}
$addresses=@(& $module {$script:fixtureAddresses});if($addresses.Count -ne 1 -or $addresses[0].IPAddress -ne '192.0.2.20'){throw 'Cutover did not apply reviewed final/remove temporary address.'}
$gates=Get-WsmAcceptanceGates $final.ManifestPath $final.SHA256 $targetState;if($gates.FinalAccepted -or $gates.RetirementReady){throw 'Activation falsely accepted/retired server.'}
Set-WsmExternalFixtureValidationEvidence $final.ManifestPath $final.SHA256 $targetState $item.ItemId BusinessFinal 'Fixture owner' 'final client read passed' $true | Out-Null
foreach($check in @('DNS','Kerberos','ExternalConnectivity','Monitoring','SecurityAgent','License','UserAcceptance')){Set-WsmExternalFixtureValidationEvidence $final.ManifestPath $final.SHA256 $targetState '' $check 'Fixture owner' ('fixture '+$check+' passed') $true | Out-Null}
$gates=Get-WsmAcceptanceGates $final.ManifestPath $final.SHA256 $targetState;if(-not $gates.FinalAccepted -or $gates.RetirementReady){throw 'FinalAccepted/RetirementReady not distinct.'}
# Only the observation clock is advanced in this fixture; no real elapsed-time qualification is claimed.
& $module {function script:Get-WsmObservationClock {[DateTimeOffset]::UtcNow.AddHours(25)}}
foreach($check in @('BackupRestore','LongCycleJobs','Observation','RetirementRetention','ExternalConsumerOldPathDrained','SpecialProductDisposition','DataRetentionHandoff','CredentialHandoff','CertificateHandoff','CMDBHandoff','DNSHandoff','LicenseHandoff','MonitoringHandoff','RollbackCutoffAndDeletionOwner')){Set-WsmExternalFixtureValidationEvidence $final.ManifestPath $final.SHA256 $targetState '' $check 'Fixture owner' ('fixture '+$check+' passed') $true | Out-Null}
if(-not (Get-WsmAcceptanceGates $final.ManifestPath $final.SHA256 $targetState).RetirementReady){throw 'Complete retirement evidence rejected.'}
$rollback=Get-WsmRollbackPreview $final.ManifestPath $final.SHA256 $targetState;$bad=$false;try{Invoke-WsmRollback $final.ManifestPath $final.SHA256 $targetState $rollback.PreviewHash ('ROLLBACK '+$pair) | Out-Null}catch{$bad=$true};if(-not $bad){throw 'Post-transaction rollback allowed without reconciliation.'}
Set-WsmExternalFixtureValidationEvidence $final.ManifestPath $final.SHA256 $targetState '' RollbackReconcile 'Fixture owner' 'fixture all writers stopped and target changes reconciled' $true | Out-Null
$rollback=Get-WsmRollbackPreview $final.ManifestPath $final.SHA256 $targetState
$rolledBack=Invoke-WsmRollback $final.ManifestPath $final.SHA256 $targetState $rollback.PreviewHash ('ROLLBACK '+$pair)
if($rolledBack.Stage -ne 'RolledBack' -or -not (Test-Path (Join-Path $targetRoot 'chunked.bin'))){throw 'Reviewed rollback did not restore retained previous root.'}
$bad=$false;try{Get-WsmRestorePreview $package.ManifestPath $package.SHA256 $targetState | Out-Null}catch{$bad=$true};if(-not $bad){throw 'Old generation accepted.'}
# Independently trusted manifest protects its indexes, whose hashes protect every chunk.
$blob=Get-ChildItem (Join-Path $final.Directory 'payload') -Filter *.blob | Select-Object -First 1;[IO.File]::WriteAllText($blob.FullName,'tampered');$bad=$false;try{Test-WsmMigrationPackage $final.ManifestPath $final.SHA256 | Out-Null}catch{$bad=$true};if(-not $bad){throw 'Tampered payload accepted.'}
$pipelineEvidence=[pscustomobject]@{SmallFiles=$SmallFiles;ElapsedSeconds=$pipelineWatch.Elapsed.TotalSeconds;PrivateBytes=[Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64;HostApisAreFixtures=$true;RealFilesAndMetadata=$true;ProductionVerified=$false};[IO.File]::WriteAllText((Join-Path $root 'result.json'),($pipelineEvidence | ConvertTo-Json))
Write-Host ('PASS: real file/ACL package and staged restore, exclusion, chunks, retry, drift, final generation/deletion/backup, evidence invalidation, old generation and tampering. SmallFiles='+$SmallFiles+' / '+[Math]::Round($pipelineWatch.Elapsed.TotalSeconds,2)+'s. Evidence: '+$root)
