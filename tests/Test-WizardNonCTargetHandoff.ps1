#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
foreach($name in @('Get-WsmWizardNonCTargetHandoffPreview','Import-WsmWizardNonCTargetHandoff','Get-WsmWizardTargetRestoreProjection')){$command=Get-Command $name -CommandType Function -ErrorAction Stop;$expectedFile=if($name -ceq 'Get-WsmWizardTargetRestoreProjection'){'WizardRestore.ps1'}else{'WizardNonCTargetHandoff.ps1'};if($command.ModuleName -cne 'WindowsServerMigration' -or -not $command.ScriptBlock.File -or [IO.Path]::GetFileName($command.ScriptBlock.File) -cne $expectedFile){throw ('Official module export '+$name+' did not resolve to its expected module source file. Module='+$command.ModuleName+' File='+$command.ScriptBlock.File)}}
. (Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1')
$systemRoot=[IO.Path]::GetPathRoot($env:SystemRoot)
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsmwnc-'+[Guid]::NewGuid().ToString('N').Substring(0,8));[void][IO.Directory]::CreateDirectory($root)
$fixtureDrive='';foreach($letter in @('R','S','T','U','V','W','X','Y','Z','Q','P','O','N','M','L','K','J','I','H','G','F','E','D')){if(-not [IO.Directory]::Exists(($letter+':\'))){$fixtureDrive=$letter+':';break}}
if(-not $fixtureDrive){Remove-Item -LiteralPath $root -Recurse -Force;throw 'No unused drive letter is available for the test-owned physical-volume observation fixture.'}
& (Join-Path $env:SystemRoot 'System32\subst.exe') $fixtureDrive $root
if($LASTEXITCODE -ne 0 -or -not [IO.Directory]::Exists(($fixtureDrive+'\'))){Remove-Item -LiteralPath $root -Recurse -Force;throw 'Could not create the test-owned temporary volume observation mapping.'}
try {
    & $module {
        param($Root,$Module,$FixtureDriveRoot,$ExternalFixturesPath)
        . $ExternalFixturesPath
        $script:observerContentCheckCalls=0;$script:realFileScopeContentCheck=(Get-Command Assert-WsmFileScopeContent -CommandType Function -ErrorAction Stop).ScriptBlock
        function script:Assert-WsmFileScopeContent {param([Parameter(Mandatory)][string]$Path,[switch]$ExactConfig);$script:observerContentCheckCalls++;& $script:realFileScopeContentCheck -Path $Path -ExactConfig:$ExactConfig}
        $script:fixtureFingerprint=('a'*64);$script:fixtureInventoryPath='';$script:fixtureShareRoot='';$script:fixtureDriveRoot=$FixtureDriveRoot;$script:targetPhysicalAliasProbeRoot='';$script:realPhysicalPath=(Get-Command Get-WsmPhysicalPath -CommandType Function).ScriptBlock
        $script:realNonCResultRows=(Get-Command Get-WsmAssistiveNonCResultRows -CommandType Function).ScriptBlock;$script:observedTargetNonCStateDirectories=@();$script:fixtureTargetHostId=''
        function script:Get-WsmAssistiveNonCResultRows($Package,[string]$TransferPlanPath,[string]$TransferPlanHash,[string]$ResultPath,[string]$ResultHash,[string]$StateDirectory=''){if($script:fixtureTargetHostId -and [string]$Package.Manifest.Target.HostId -ceq $script:fixtureTargetHostId){$script:observedTargetNonCStateDirectories+=@($StateDirectory)};& $script:realNonCResultRows $Package $TransferPlanPath $TransferPlanHash $ResultPath $ResultHash $StateDirectory}
        function script:Get-WsmPhysicalPath([string]$Path){if([string]$Path -like '\Device\HarddiskVolumeWsmWizardFixtureTarget*'){throw 'Native Target device paths cannot be used as logical I/O paths.'};$full=[IO.Path]::GetFullPath($Path);if($full.StartsWith('\\')){throw 'DeviceMup test sentinel: generic physical-path resolution must not be used for reviewed peer UNC paths.'};if($script:targetPhysicalAliasProbeRoot -and $full.StartsWith($script:targetPhysicalAliasProbeRoot,[StringComparison]::OrdinalIgnoreCase)){return (Join-Path $env:ProgramFiles 'WsmProtectedAlias')+$full.Substring($script:targetPhysicalAliasProbeRoot.Length)};$fixtureRoot=$script:fixtureDriveRoot.TrimEnd('\')+'\';if($full.StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase) -or $full -ieq $fixtureRoot.TrimEnd('\')){return '\Device\WsmWizardFixtureNonC'+$full.Substring(2)};$targetRoot=[string]$script:fixtureTargetShareRoot;if($targetRoot){$targetPrefix=$targetRoot.TrimEnd('\');if($full -ieq $targetPrefix -or $full.StartsWith($targetPrefix+'\',[StringComparison]::OrdinalIgnoreCase)){return '\Device\HarddiskVolumeWsmWizardFixtureTarget'+$full.Substring($targetPrefix.Length)}};& $script:realPhysicalPath $Path}
        $fixtureTargetPhysicalRoot='\Device\HarddiskVolumeWsmWizardFixtureTarget'
        Assert-WsmFileScopeGuard -Path ($fixtureTargetPhysicalRoot+'\business-data') -Mode Root -PathOnly -IsDirectory
        foreach($rejectedPath in @($fixtureTargetPhysicalRoot,($fixtureTargetPhysicalRoot+'\Program Files\Fixture'))){$guardRejected=$false;try{Assert-WsmFileScopeGuard -Path $rejectedPath -Mode Root -PathOnly -IsDirectory}catch{$guardRejected=$_.Exception.Message -match 'protected OS/software path'};if(-not $guardRejected){throw ('Target native-path guard fixture failed to reject protected path '+$rejectedPath)}}
        function script:Assert-WsmAssistiveSourceScope {param($Spec,[ValidateSet('SourceCOnly')][string]$Policy='SourceCOnly',[switch]$Native);$path=ConvertTo-WsmCanonicalPath ([string]$Spec.SourcePath);$fixtureRoot=$script:fixtureDriveRoot.TrimEnd('\')+'\';if(-not ($path.StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase) -or $path -ieq $fixtureRoot.TrimEnd('\'))){throw 'The test-only source volume fixture only classifies its own temporary subst path.'};if($Spec.TransferChannel -cne 'NonC'){throw 'The test fixture volume is classified NonC and does not permit a C-channel spec.'};$physical=Get-WsmPhysicalPath $path;$cPhysical=Get-WsmPhysicalPath 'C:\';[pscustomobject]@{Channel='NonC';PhysicalPath=$physical;SourceCPhysicalRoot=$cPhysical;Policy=$Policy;NativeVerified=[bool]$Native}}
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='wizard-nonc-fixture';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);[pscustomobject]@{Path=$script:fixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:fixtureInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        function script:New-WizardFixtureSoftwareCatalog($Inventory){
            $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$Inventory.Source.HostId;Fingerprint=$Inventory.Source.Fingerprint;Name=$Inventory.Source.Name;InventoryRevision=[int]$Inventory.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $Inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';ItemId='';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc='2026-10-10T00:00:00Z'});PreparationRequirements=@();CatalogProjectionHash=('0'*64)}
            $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
            Assert-WsmSoftwareCatalog $catalog -SourceInventory $Inventory | Out-Null
            $Inventory | Add-Member NoteProperty SoftwareCatalog $catalog
            $Inventory
        }
        # Test-only SMB observation seam. The actual peer-proof generator,
        # transfer-plan validator, transfer worker, journal and result importer
        # remain the production implementations.
        function script:Get-SmbShare {param([string]$Name,[string]$ErrorAction);[pscustomobject]@{Name=$Name;Path=$script:fixtureShareRoot;EncryptData=$false;ContinuouslyAvailable=$false}}
        function script:Get-SmbServerConfiguration {param([string]$ErrorAction);[pscustomobject]@{RequireSecuritySignature=$true;EnableSecuritySignature=$true}}
        function script:Get-SmbShareAccess {param([string]$Name,[string]$ErrorAction);[pscustomobject]@{AccountName='Everyone';AccessControlType='Allow';AccessRight='Read'}}
        function script:Test-WsmAssistivePeerDirectoryExists {
            param([string]$AccessPath,$PeerProof)
            $endpoint=[regex]::Match([string]$AccessPath,'^\\\\([^\\]+)\\([^\\]+)(?:\\|$)')
            if(-not $endpoint.Success -or $endpoint.Groups[1].Value -ine [string]$PeerProof.PeerName -or $endpoint.Groups[2].Value -ine [string]$PeerProof.ShareName){throw 'Fixture state-directory observation requires the exact reviewed peer server/share.'}
            $shareRoot=[IO.Path]::GetFullPath([string]$PeerProof.SharePath).TrimEnd('\')
            $relative=([string]$AccessPath).Substring($endpoint.Groups[0].Value.TrimEnd('\').Length).TrimStart('\')
            $localPath=if($relative){[IO.Path]::GetFullPath((Join-Path $shareRoot $relative))}else{$shareRoot}
            if(-not ($localPath.Equals($shareRoot,[StringComparison]::OrdinalIgnoreCase) -or $localPath.StartsWith($shareRoot+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Fixture state-directory path escaped its exact owned share root.'}
            [IO.Directory]::Exists($localPath)
        }
        function script:Test-WsmAssistivePeerPathExists {
            param([string]$Path,$Proof)
            $endpoint=[regex]::Match([string]$Path,'^\\\\([^\\]+)\\([^\\]+)(?:\\|$)')
            if(-not $endpoint.Success -or $endpoint.Groups[1].Value -ine [string]$Proof.PeerName -or $endpoint.Groups[2].Value -ine [string]$Proof.ShareName){throw 'Fixture peer-path observation requires the exact proof-bound endpoint.'}
            $shareRoot=if($Proof.ShareName -ceq 'FixtureSource'){$script:fixtureSourceShareRoot}elseif($Proof.ShareName -ceq 'FixtureTarget'){$script:fixtureTargetShareRoot}else{throw 'Fixture peer-path observation received an unrecognized share.'}
            $relative=([string]$Path).Substring($endpoint.Groups[0].Value.TrimEnd('\').Length).TrimStart('\')
            $localPath=if($relative){[IO.Path]::GetFullPath((Join-Path $shareRoot $relative))}else{[IO.Path]::GetFullPath($shareRoot)}
            $fullShare=[IO.Path]::GetFullPath($shareRoot).TrimEnd('\')
            if(-not ($localPath.Equals($fullShare,[StringComparison]::OrdinalIgnoreCase) -or $localPath.StartsWith($fullShare+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Fixture peer-path observation escaped its exact share.'}
            [IO.Directory]::Exists($localPath)
        }
        function script:Get-SmbConnection { [pscustomobject]@{ServerName=$env:COMPUTERNAME;ShareName='FixtureSource';Signed=$true;Encrypted=$false},[pscustomobject]@{ServerName=$env:COMPUTERNAME;ShareName='FixtureTarget';Signed=$true;Encrypted=$false} }
        function script:Resolve-WsmAssistiveIoPath {
            param([string]$Path)
            $full=[IO.Path]::GetFullPath($Path)
            $prefix='\\'+[string]$env:COMPUTERNAME+'\FixtureTarget'
            if(-not $full.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase) -and $full -ine $prefix){return $full}
            $relative=$full.Substring($prefix.Length).TrimStart('\')
            if($relative -match '(^|[\\/])\.{1,2}([\\/]|$)' -or $relative -match '^[A-Za-z]:'){throw 'Fixture I/O path contains traversal or a drive alias.'}
            $root=[IO.Path]::GetFullPath($script:fixtureTargetShareRoot).TrimEnd('\')
            $mapped=if($relative){[IO.Path]::GetFullPath((Join-Path $root $relative))}else{$root}
            if(-not ($mapped.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or $mapped.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Fixture I/O path escaped its owned target share root.'}
            $mapped
        }

        $sourceRoot=Join-Path $Root 'source-work';$managerRoot=Join-Path $Root 'manager-work';$targetRoot=Join-Path $Root 'target-work'
        $script:fixtureFingerprint=('a'*64);$sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $managerEnrollment=Initialize-WsmWizardWorkspace $managerRoot Manager
        $script:fixtureFingerprint=('b'*64)
        $targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target;$script:fixtureTargetHostId=[string]$targetEnrollment.Profile.HostId
        $script:fixtureTargetHostId=[string]$targetEnrollment.Profile.HostId
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json'
        $targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $sourceData=Join-Path ($script:fixtureDriveRoot+'\') 'source-data';$targetShareRoot=$Root;$targetData=Join-Path $targetShareRoot 'target-share\business-data';$script:fixtureSourceShareRoot=$sourceData;$script:fixtureTargetShareRoot=$targetShareRoot;$targetState=Join-Path $targetEnrollment.Profile.WorkRoot 'pairs';$targetUncShareRoot='\\'+[string]$env:COMPUTERNAME+'\FixtureTarget';$targetUncRoot=Join-Path $targetUncShareRoot 'target-share\business-data';$targetUncState=Join-Path $targetUncShareRoot 'target-work\pairs'
        [void][IO.Directory]::CreateDirectory($sourceData);[void][IO.Directory]::CreateDirectory($targetData)
        $exactRootSpec=[pscustomobject]@{ContentSelection='ExactFiles';SourcePath=$sourceData;TargetPath=$targetData;ConfigFiles=@([pscustomobject]@{RelativePath='reviewed.config';SHA256=('a'*64)})};Assert-WsmAssistiveNonCScopeTopology -Path $targetData -Spec $exactRootSpec -RelativePath '' -Target -IsDirectory
        $targetDataFull=[IO.Path]::GetFullPath($targetData);$targetShareFull=[IO.Path]::GetFullPath($targetShareRoot).TrimEnd('\')+'\'
        if(-not $targetDataFull.StartsWith($targetShareFull,[StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::GetFileSystemEntries($targetDataFull).Count -ne 0){throw 'The test may remove only its exact empty target business-data directory.'}
        Remove-Item -LiteralPath $targetDataFull
        $protectedTargetProbe=Join-Path $Root 'target-alias-must-not-be-created';$script:targetPhysicalAliasProbeRoot=[IO.Path]::GetFullPath($Root);$protectedSpec=[pscustomobject]@{ContentSelection='WholeScope';TargetPath=$protectedTargetProbe};$protectedBoundaryRejected=$false;try{Assert-WsmAssistiveNonCTargetBoundary -Path $protectedTargetProbe -Spec $protectedSpec -RelativePath '' -IsDirectory}catch{$protectedBoundaryRejected=$_.Exception.Message -match 'protected|installation|software'};$script:targetPhysicalAliasProbeRoot='';if(-not $protectedBoundaryRejected -or [IO.Directory]::Exists($protectedTargetProbe) -or [IO.File]::Exists($protectedTargetProbe)){throw 'A nonexistent NonC target alias to a protected installed-software root was not rejected before any destination write.'}
        $outsideTargetRejected=$false;try{Assert-WsmAssistiveNonCTargetBoundary -Path (Join-Path $Root 'outside-reviewed-root\settings.ini') -Spec ([pscustomobject]@{ContentSelection='ExactFiles';TargetPath=(Join-Path $Root 'exact-target');ConfigFiles=@([pscustomobject]@{RelativePath='settings.ini';SHA256=('a'*64)})}) -RelativePath 'settings.ini'}catch{$outsideTargetRejected=$_.Exception.Message -match 'exact reviewed target root'};if(-not $outsideTargetRejected){throw 'A nonexistent exact-file target outside its approved root was not rejected before any destination write.'}
        [void][IO.Directory]::CreateDirectory($sourceData);[void][IO.Directory]::CreateDirectory($targetShareRoot);[void][IO.Directory]::CreateDirectory($targetState)
        $sourceFile=Join-Path $sourceData 'settings.ini';$targetFile=Join-Path $targetData 'settings.ini';[IO.File]::WriteAllText($sourceFile,'verified non-C source bytes')
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source';OS='Fixture Windows Server'}
        $item=New-WsmItem $source.HostId Storage PathCandidate 'Reviewed business data' $sourceData @{OriginalPath=$sourceData;ResolvedCandidate=$sourceData}
        $inventory=New-WsmInventory $source 1 @($item);$inventory=New-WizardFixtureSoftwareCatalog $inventory;$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:fixtureInventoryPath=$inventoryPath
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-WsmAssistiveNonCHash $inventoryPath) 'fixture-target'
        $catalog=Enable-WsmAssistiveMode $managerRoot $catalog.PairId $catalog.DecisionRevision
        # Each SID subauthority is an unsigned 32-bit value. Keep this target
        # account fixture canonicalizable by Windows SecurityIdentifier.
        $targetSid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $targetIdentityItem=New-WsmItem $targetEnrollment.HostId Identity LocalUser 'fixture-target-service' $targetSid @{SID=$targetSid;Name='fixture-target-service'}
        $targetSource=[pscustomobject]@{HostId=$targetEnrollment.HostId;Fingerprint=('b'*64);Name='fixture-target';OS='Fixture Windows Server'}
        $targetInventory=New-WsmInventory $targetSource 1 @($targetIdentityItem);$targetInventory=New-WizardFixtureSoftwareCatalog $targetInventory
        # Bounded environment observation seam, matching Test-WizardRestore.
        # Package, plan, comparison, receipt and native file readback stay real;
        # this fixture does not claim this host's installed-software observation.
        function script:Get-WsmAssistiveCurrentSoftwareCatalog($Snapshot){$Snapshot.SoftwareCatalog}
        $targetInventoryPath=Join-Path $Root 'target-inventory.json';Write-WsmJson $targetInventoryPath $targetInventory
        $catalog=Update-WsmAssistiveTargetSnapshot $managerRoot $catalog.PairId $targetInventoryPath (Get-WsmAssistiveNonCHash $targetInventoryPath) $catalog.Assistive.Revision
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceData;TargetPath=$targetData;TransferChannel='NonC';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';Owner='Fixture data owner';Evidence='Reviewed isolated test scope';BusinessChecks=@('Read back transferred file bytes')}
        $specPath=Join-Path $Root 'spec.json';Write-WsmJson $specPath $spec
        $catalog=Get-WsmCatalog $managerRoot $catalog.PairId
        Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $specPath (Get-WsmAssistiveNonCHash $specPath) $catalog.DecisionRevision|Out-Null
        $catalog=Get-WsmCatalog $managerRoot $catalog.PairId
        Set-WsmDecision $managerRoot $catalog.PairId @($item.ItemId) Include 'Reviewed NonC scope' $catalog.DecisionRevision|Out-Null
        $catalog=Get-WsmCatalog $managerRoot $catalog.PairId
        $planPath=Join-Path $Root 'approved-plan.json';$approval=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $catalog.DecisionRevision 'ISOLATED-PILOT'
        $sealed=Read-WsmMigrationPlan $approval.Path $approval.SHA256
        if(@($sealed.Items|Where-Object {$_.ItemId -ceq $item.ItemId -and $_.Decision -ceq 'Include' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'}).Count -ne 1){throw 'Fixture approval did not seal the included NonC FileScope item.'}
        $approvalJob=[pscustomobject]@{action='ApproveMigration';status='Succeeded';role='Manager';workspace=$managerRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@([pscustomobject]@{Path=$approval.Path;SHA256=$approval.SHA256})}
        $script:fixtureFingerprint=('a'*64);$sourceImport=Import-WsmWizardApprovedPlan $sourceRoot Source $approval.Path $approval.SHA256
        if($sourceImport.Status -cne 'ImportedVerified' -or $sourceImport.PairId -cne $catalog.PairId){throw 'Source did not import the real target-bound approved plan.'}
        $freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $sealed -PlanHash $approval.SHA256 -Root $Root -Owner 'Fixture source owner'
        $freezePath=Join-Path $Root 'source-freeze.json'
        $operationId=[Guid]::NewGuid().ToString('D');$cancelToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approval.SHA256 -OperationId $operationId
        $script:fixtureFingerprint=('a'*64)
        try{$backup=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $operationId -Owner 'Fixture source owner' -Evidence 'Fixture owner confirmed source quiescence' -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -FreezeAuthorization -Jobs @() -CancellationToken $cancelToken}catch{if($_.Exception.InnerException){throw ('Fixture source freeze failed inside the real core consumer: '+$_.Exception.InnerException.Message)};throw}
        if($backup.Status -cne 'ReviewRequired' -or -not $backup.PackageTest.Final -or -not $backup.PackageTest.Valid -or $backup.NonCStatus -cne 'RequiresTargetTransferAndManagerResultImport'){throw 'NonC backup did not truthfully retain its pending transfer/result gate after producing the real final package.'}
        $backupJob=[pscustomobject]@{action='StartBackup';status='ReviewRequired';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;jobId=$operationId;CompletedUtc=(Get-WsmUtc);outputs=@($backup)}

        # The final package and separately verified evidence are handed to the
        # Manager workspace as current materials, just as the normal import path does.
        Register-WsmAssistiveMaterialReference -Workspace $managerRoot -PairId $catalog.PairId -Generation ([int]$backup.PackageTest.Generation) -Path $backup.PackageTest.ManifestPath -SHA256 $backup.PackageTest.SHA256 -Kind AssistivePackageManifest -ConsumerRefs @($item.ItemId)|Out-Null
        Register-WsmAssistiveMaterialReference -Workspace $managerRoot -PairId $catalog.PairId -Generation ([int]$backup.PackageTest.Generation) -Path $freezeProof.Path -SHA256 $freezeProof.SHA256 -Kind AssistiveSourceFreezeEvidence -ConsumerRefs @($item.ItemId)|Out-Null
        $script:fixtureShareRoot=$sourceData;$shareProofPath=Join-Path $Root 'source-share-proof.json'
        $script:fixtureFingerprint=('a'*64);$sourceProof=New-WsmAssistivePeerShareProof -Path $sourceData -ShareName 'FixtureSource' -PeerHostId $source.HostId -ProofPath $shareProofPath
        $script:fixtureFingerprint=('b'*64)
        $script:fixtureShareRoot=$targetShareRoot;$script:fixtureFingerprint=('b'*64);$targetPeerProofPath=Join-Path $Root 'target-share-proof.json';$targetPeerProof=New-WsmAssistivePeerShareProof -Path $targetShareRoot -ShareName 'FixtureTarget' -PeerHostId $targetEnrollment.HostId -ProofPath $targetPeerProofPath;$targetPeerReference=@([pscustomobject]@{Path=$targetPeerProof.Path;SHA256=$targetPeerProof.SHA256;PeerFingerprint=('b'*64)})
        $script:fixtureFingerprint=('a'*64);$targetProof=New-WsmAssistiveTargetPhysicalProof -TargetHostId $targetEnrollment.HostId -ApprovedTargetRoots @($targetUncRoot) -PeerShareProofReferences $targetPeerReference -ApprovedPeerFingerprints @('b'*64)
        Set-WsmWizardNonCReviewedStateDirectory $targetProof $targetUncState;$targetProofPath=Join-Path $Root 'target-proof.json';Write-WsmJson $targetProofPath $targetProof;$targetProofHash=Get-WsmAssistiveNonCHash $targetProofPath
        $targetProofRead=Read-WsmTrustedJson $targetProofPath $targetProofHash;$targetEndpoint=[regex]::Match($targetUncRoot,'^\\\\([^\\]+)\\([^\\]+)');$targetPeerMatches=@($targetProofRead.PeerShareProofs|Where-Object {$_.PeerName -ieq $targetEndpoint.Groups[1].Value -and $_.ShareName -ieq $targetEndpoint.Groups[2].Value})
        if($targetPeerMatches.Count -ne 1){throw ('Isolated Target SMB fixture is not bound to exactly one imported proof. Endpoint='+$targetUncRoot+' proofPeers='+(@($targetProofRead.PeerShareProofs|ForEach-Object {([string]$_.PeerName)+'\'+[string]$_.ShareName}) -join ','))}
        $targetAliasMismatchRejected=$false;try{Assert-WsmAssistiveNonCTargetShareAlias -TargetPath (Join-Path $Root 'outside-target-share') -PeerPath $targetUncRoot -PeerShareProofs @($targetProofRead.PeerShareProofs) -ExpectedFingerprint ('b'*64)|Out-Null}catch{$targetAliasMismatchRejected=$true};if(-not $targetAliasMismatchRejected){throw 'A target UNC alias was accepted for a sealed local Target FileScope outside the proof-bound share path.'}
        $null=Get-WsmAssistiveEndpointIdentity $targetUncRoot $targetProofRead.PeerShareProofs
        $null=Get-WsmAssistiveEndpointIdentity $targetUncState $targetProofRead.PeerShareProofs
        Register-WsmAssistiveMaterialReference -Workspace $managerRoot -PairId $catalog.PairId -Generation 1 -Path $sourceProof.Path -SHA256 $sourceProof.SHA256 -Kind AssistivePeerShareProof -ConsumerRefs @($item.ItemId)|Out-Null
        Register-WsmAssistiveMaterialReference -Workspace $managerRoot -PairId $catalog.PairId -Generation 1 -Path $targetProofPath -SHA256 $targetProofHash -Kind AssistiveTargetPhysicalProof -ConsumerRefs @($item.ItemId)|Out-Null
        $prep=Get-WsmWizardNonCPreparation -Workspace $managerRoot -PairId $catalog.PairId -ManifestSelection $backup.PackageTest.SHA256 -Jobs @($approvalJob,$backupJob)
        if(-not $prep.CanCreateTransferPlan -or $prep.Current.ManifestHash -ine $backup.PackageTest.SHA256){throw 'Manager preparation did not discover the exact final package, source freeze record and current proofs.'}
        $prepJob=[pscustomobject]@{action='GetNonCPreparation';status='Succeeded';role='Manager';workspace=$managerRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@($prep)}
        $observationId=[Guid]::NewGuid().ToString('D');$observationToken=New-WsmCancellationToken -StateDirectory (Join-Path $managerRoot 'pairs') -PairId $catalog.PairId -PlanHash $approval.SHA256 -OperationId $observationId
        $script:fixtureFingerprint=('a'*64)
        $script:observerContentCheckCalls=0
        $observation=Get-WsmWizardNonCAccountObservations -Workspace $managerRoot -PairId $catalog.PairId -OperationId $observationId -ManifestSelection $backup.PackageTest.SHA256 -SourcePeerProofHash $sourceProof.SHA256 -Jobs @($approvalJob,$prepJob) -CancellationToken $observationToken
        if($observation.Status -cne 'Succeeded' -or -not $observation.CoverageComplete -or $observation.ContentRead -or -not $observation.Entries.Count -or $script:observerContentCheckCalls -ne 0){throw ('The ACL-only observer read content or failed complete metadata coverage. ContentRead='+$observation.ContentRead+' ContentCheckCalls='+$script:observerContentCheckCalls+' Status='+$observation.Status)}
        $observationJob=[pscustomobject]@{action='InspectNonCAccountMappings';status='Succeeded';role='Manager';workspace=$managerRoot;pairId=$catalog.PairId;jobId=$observationId;outputs=@($observation)}
        $currentCatalog=Get-WsmCatalog $managerRoot $catalog.PairId;$currentApproved=Get-WsmWizardCurrentApprovedPlan $managerRoot $catalog.PairId (Read-WsmOutputProfile $managerRoot) $currentCatalog @($approvalJob,$backupJob,$prepJob)
        $observationSummary=Get-WsmWizardNonCAccountObservationSummary $managerRoot $catalog.PairId $currentApproved $prep $currentCatalog @($approvalJob,$backupJob,$prepJob,$observationJob)
        if(-not $observationSummary -or -not $observationSummary.hasDurableRecord -or -not $observationSummary.current -or -not $observationSummary.CoverageComplete -or $observationSummary.SourcePeerProofHash -ine $sourceProof.SHA256 -or $observationSummary.ContentRead){$savedObservation=Read-WsmTrustedJson $observation.Path $observation.SHA256;$diagnostics=[ordered]@{Projection=$observationSummary;Output=$observation;Saved=$savedObservation;SourceProofHash=$sourceProof.SHA256;SourceProofOptions=@($prep.ProofOptions|Where-Object kind -CEQ 'SourcePeerShareProof');Preparation=$prep|Select-Object Status,Current;CurrentApproved=$currentApproved|Select-Object Path,SHA256;TargetSnapshot=$currentCatalog.Assistive.TargetCurrent.SHA256};throw ('Current-only observation projection did not verify the actual owned observation file and registered source proof hash. Diagnostics='+($diagnostics|ConvertTo-Json -Depth 9 -Compress))}
        $mappingRows=@(foreach($principal in @($observationSummary.Entries[0].Principals)){$targetSidForPrincipal=$principal.SourceSid;if(@($observationSummary.TargetIdentities|Where-Object {$_.sid -ceq $targetSidForPrincipal}).Count -eq 0){$targetSidForPrincipal=$targetSid};[pscustomobject]@{SourceSid=[string]$principal.SourceSid;TargetSid=[string]$targetSidForPrincipal;OwnerObserved=[bool]$principal.OwnerObserved;Evidence='Owner reviewed the explicitly selected destination identity for this source SID.'}})
        $scope=@([pscustomobject]@{ItemId=$item.ItemId;SourceRoot=$sourceData;TargetRoot=$targetUncRoot;AccountMappings=$mappingRows})
        $transferPlan=New-WsmWizardNonCTransferPlan -Workspace $managerRoot -PairId $catalog.PairId -ManifestSelection $backup.PackageTest.SHA256 -SourcePeerProofHash $sourceProof.SHA256 -TargetPhysicalProofHash $targetProofHash -ItemScopes $scope -TargetStateDirectory $targetUncState -AccountObservationHash $observation.SHA256 -Owner 'Fixture mapping owner' -Evidence 'Fixture explicitly reviewed each observed source identity mapping.' -Jobs @($approvalJob,$backupJob,$prepJob,$observationJob)
        if($transferPlan.Status -cne 'Succeeded' -or $transferPlan.AuthoritativeApproval -or $transferPlan.ProductionVerified){throw 'Manager transfer plan was not an actual non-authoritative derived core plan.'}
        $sealedTransfer=Assert-WsmAssistiveNonCPlan $null $transferPlan.Path $transferPlan.SHA256;$expectedLocalRoot=[IO.Path]::GetFullPath($sourceData).TrimEnd('\');$expectedDriveRoot=[IO.Path]::GetFullPath($fixtureDriveRoot).TrimEnd('\');$expectedPeerRoot='\\'+[string]$sourceProof.Proof.PeerName+'\'+[string]$sourceProof.Proof.ShareName
        if(@($sealedTransfer.ApprovedSourceRoots|Where-Object {[IO.Path]::GetFullPath([string]$_).TrimEnd('\') -ieq $expectedLocalRoot}).Count -ne 1 -or @($sealedTransfer.ApprovedSourceRoots|Where-Object {[IO.Path]::GetFullPath([string]$_).TrimEnd('\') -ieq $expectedPeerRoot}).Count -ne 1 -or @($sealedTransfer.ApprovedSourceRoots|Where-Object {[IO.Path]::GetFullPath([string]$_).TrimEnd('\') -ieq $expectedDriveRoot}).Count -ne 0){throw ('Transfer plan did not bind the exact sealed local source root plus its proof-derived peer root without broadening to the drive root. Roots='+(@($sealedTransfer.ApprovedSourceRoots)-join '|')+' expectedLocal='+$expectedLocalRoot+' expectedPeer='+$expectedPeerRoot+' drive='+$expectedDriveRoot)}
        $accountMap=[ordered]@{};foreach($mapping in $mappingRows){$accountMap[[string]$mapping.SourceSid]=[string]$mapping.TargetSid};$coreEntry=[pscustomobject]@{ItemId=$item.ItemId;SourcePath=$sourceData;TargetPath=$targetUncRoot;ConsumerRefs=@($item.ItemId);AccountMap=$accountMap;Channel='NonC'}
        $coreArgs=@{SealedPlanPath=$approval.Path;SealedPlanHash=$approval.SHA256;TransferPlanPath=(Join-Path $Root 'wrong-host.transfer.json');PairId=$catalog.PairId;FreezeRecordPath=$prep.Current.FreezeRecordPath;FreezeRecordHash=[string]$prep.Current.FreezeRecordHash;FreezeEvidencePath=$freezeProof.Path;FreezeEvidenceHash=$freezeProof.SHA256;ManifestPath=$backup.PackageTest.ManifestPath;ManifestHash=$backup.PackageTest.SHA256;SourceInventoryHash=$prep.Current.InventoryHash;Channel='NonC';ApprovedSourceRoots=@($sourceData);ApprovedTargetRoots=@($targetUncRoot);Entries=@($coreEntry);TargetPhysicalId=$targetProof.TargetPhysicalId;TargetPhysicalProof=$targetProof;Generation=[int]$backup.PackageTest.Generation;TargetStateDirectory=$targetUncState;SourcePeerShareProofReferences=@([pscustomobject]@{Path=$sourceProof.Path;SHA256=$sourceProof.SHA256;PeerFingerprint=$sourceProof.Proof.PeerFingerprint});ApprovedSourcePeerFingerprints=@($source.Fingerprint)}
        $wrongHostRejected=$false;$wrongHostError='';$localSourceHostGateRejected=$false;$script:fixtureFingerprint=('b'*64);try{New-WsmAssistiveNonCTransferPlan @coreArgs|Out-Null}catch{$wrongHostError=$_.Exception.Message;$wrongHostRejected=$true};try{Assert-WsmAssistiveLocalSourceHost $source.Fingerprint|Out-Null}catch{$localSourceHostGateRejected=$_.Exception.Message -match 'Local source paths may only be resolved on the sealed source host'}finally{$script:fixtureFingerprint=('a'*64)};if(-not $wrongHostRejected -or -not $localSourceHostGateRejected){throw ('A remote-manager identity was allowed to use a local source drive instead of the reviewed peer UNC. ConstructorError='+$wrongHostError+' LocalPathGateRejected='+$localSourceHostGateRejected)}
        $parentArgs=@{};foreach($key in $coreArgs.Keys){$parentArgs[$key]=$coreArgs[$key]};$parentArgs.TransferPlanPath=Join-Path $Root 'parent-alias.transfer.json';$parentArgs.Entries=@([pscustomobject]@{ItemId=$item.ItemId;SourcePath=$fixtureDriveRoot;TargetPath=$targetUncRoot;ConsumerRefs=@($item.ItemId);AccountMap=$accountMap;Channel='NonC'});$parentAliasError='';try{New-WsmAssistiveNonCTransferPlan @parentArgs|Out-Null}catch{$parentAliasError=$_.Exception.Message};if(-not $parentAliasError){throw 'A local parent/drive-root alias was accepted instead of the exact sealed per-item source root.'}
        $forgedStatePlan=Read-WsmTrustedJson $transferPlan.Path $transferPlan.SHA256;$forgedStatePlan.TargetStateDirectoryAccessPath='\\unreviewed.invalid\OtherShare\target-state';$forgedStatePath=Join-Path $Root 'forged-target-state.transfer.json';Write-WsmJson $forgedStatePath $forgedStatePlan;$forgedStateHash=Get-WsmAssistiveNonCHash $forgedStatePath
        $forgedStateRejected=$false;try{Assert-WsmAssistiveNonCPlan $null $forgedStatePath $forgedStateHash|Out-Null}catch{$forgedStateRejected=$true};if(-not $forgedStateRejected){throw 'Transfer validator accepted a Target state UNC without its exact reviewed peer proof.'}

        $script:fixtureFingerprint=('a'*64)
        $sourceCopy=Import-WsmWizardNonCTransferPlan -Workspace $sourceRoot -PairId $catalog.PairId -Path $transferPlan.Path -ExpectedHash $transferPlan.SHA256 -FreezeEvidencePath $freezeProof.Path -FreezeEvidenceHash $freezeProof.SHA256 -Jobs @($backupJob)
        if($sourceCopy.Status -cne 'ImportedVerified' -or $sourceCopy.PairId -cne $catalog.PairId -or $sourceCopy.ManifestHash -ine $backup.PackageTest.SHA256){throw 'Source did not independently validate and import the exact NonC transfer plan.'}
        $importJob=[pscustomobject]@{action='ImportNonCTransferPlan';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@($sourceCopy)}
        $duplicateImportJob=[pscustomobject]@{action='ImportNonCTransferPlan';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@($sourceCopy)}
        $sourceChoices=Get-WsmWizardSourceNonCTransferChoices -Workspace $sourceRoot -PairId $catalog.PairId -Jobs @($backupJob,$importJob,$duplicateImportJob)
        if($sourceChoices.Status -cne 'Ready' -or $sourceChoices.TransferChoices.Count -ne 1 -or -not $sourceChoices.TransferChoices[0].ChoiceId -or -not $sourceChoices.TransferChoices[0].Label -or $sourceChoices.TransferChoices[0].PSObject.Properties['Path']){throw 'Current source NonC choice projection did not collapse an exact duplicate or exposed a raw material path.'}
        $staleImportBody=[ordered]@{};foreach($property in $sourceCopy.PSObject.Properties){$staleImportBody[$property.Name]=$property.Value};$staleImportBody.ManifestHash=('f'*64);$staleImport=[pscustomobject]$staleImportBody
        $staleImportJob=[pscustomobject]@{action='ImportNonCTransferPlan';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@($staleImport)}
        $staleChoicesSummary=Get-WsmWizardSourceNonCTransferChoices -Workspace $sourceRoot -PairId $catalog.PairId -Jobs @($backupJob,$importJob,$staleImportJob);$choicesWithStale=@($staleChoicesSummary.TransferChoices);if($choicesWithStale.Count -ne 1){throw 'A stale prior-manifest import changed the current backup choice or remained selectable.'}
        $forgedImportBody=[ordered]@{};foreach($property in $sourceCopy.PSObject.Properties){$forgedImportBody[$property.Name]=$property.Value};$forgedImportBody.TransferId=[Guid]::NewGuid().ToString('D');$forgedImport=[pscustomobject]$forgedImportBody
        $forgedImportJob=[pscustomobject]@{action='ImportNonCTransferPlan';status='Succeeded';role='Source';workspace=$sourceRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@($forgedImport)}
        $forgedSourceReceiptRejected=$false;try{Get-WsmWizardSourceNonCTransferChoices -Workspace $sourceRoot -PairId $catalog.PairId -Jobs @($backupJob,$importJob,$forgedImportJob)|Out-Null}catch{$forgedSourceReceiptRejected=$true};if(-not $forgedSourceReceiptRejected){throw 'Source choice projection accepted a receipt whose manifest binding differs from its verified transfer materials.'}
        $runId=[Guid]::NewGuid().ToString('D');$runToken=New-WsmCancellationToken -StateDirectory $targetUncState -PairId $catalog.PairId -PlanHash $approval.SHA256 -ManifestHash $backup.PackageTest.SHA256 -OperationId $runId
        $run=Invoke-WsmWizardNonCTransfer -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $runId -TransferChoiceId $sourceChoices.TransferChoices[0].ChoiceId -Jobs @($backupJob,$importJob,$duplicateImportJob) -CancellationToken $runToken
        if($run.Status -notin @('Succeeded','ReviewRequired') -or -not [IO.File]::Exists($targetFile) -or (Get-WsmAssistiveNonCHash $targetFile) -ine (Get-WsmAssistiveNonCHash $sourceFile)){throw 'The actual NonC worker did not preserve source bytes at the reviewed destination.'}
        $rawRunResult=Read-WsmTrustedJson $run.ResultPath $run.ResultHash;$fileRow=@($rawRunResult.Rows|Where-Object {$_.EntryType -ceq 'File' -and $_.Status -ceq 'Applied'});if($fileRow.Count -ne 1 -or -not $fileRow[0].Metadata -or -not $fileRow[0].Metadata.ReadbackSucceeded -or -not $fileRow[0].Metadata.OwnerApplied -or -not $fileRow[0].Metadata.DaclApplied){throw 'The exact FileScope copy did not read back the reviewed owner and DACL metadata.'}
        if(-not [IO.File]::Exists($run.ResultPath) -or (Get-WsmAssistiveNonCHash $run.ResultPath) -ine $run.ResultHash -or -not [IO.File]::Exists($run.JournalPath) -or (Get-WsmAssistiveNonCHash $run.JournalPath) -ine $run.JournalHash){throw 'Transfer result/journal was not durably hash-bound.'}
        $managerImport=Import-WsmWizardNonCResult -Workspace $managerRoot -PairId $catalog.PairId -TransferPlanHash $transferPlan.SHA256 -ResultPath $run.ResultPath -ExpectedResultHash $run.ResultHash -Jobs @($approvalJob,$backupJob,$prepJob,$observationJob)
        if($managerImport.Status -notin @('Succeeded','ReviewRequired') -or $managerImport.ResultHash -ine $run.ResultHash -or $managerImport.AuthoritativeApproval -or $managerImport.ProductionVerified){throw 'Manager did not persist the actual core-validated transfer receipt with truthful non-authority status.'}
        $current=Get-WsmCatalog $managerRoot $catalog.PairId
        $receipt=@($current.Assistive.ResultReferences|Where-Object {$_.SHA256 -ieq $run.ResultHash -and $_.TransferId -ceq $transferPlan.TransferId})
        if($receipt.Count -ne 1){throw 'The actual imported result receipt is not present uniquely in durable core state.'}
        $summaryJobs=@($approvalJob,$backupJob,$prepJob,$observationJob)
        $summaryPlan=Get-WsmWizardCurrentApprovedPlan $managerRoot $catalog.PairId (Read-WsmOutputProfile $managerRoot) $current $summaryJobs
        $summaryPreparation=Get-WsmWizardNonCPreparation -Workspace $managerRoot -PairId $catalog.PairId -ManifestSelection $backup.PackageTest.SHA256 -Jobs $summaryJobs
        $summary=Get-WsmWizardNonCResultSummary $managerRoot $catalog.PairId $summaryPlan $summaryPreparation $current
        if(-not $summary.current -or -not $summary.hasDurableRecord -or $summary.Status -cne 'Complete' -or $summary.OverallStatus -cne 'NonCVerified_NoIncludedCFileScope' -or $summary.CStatus -cne 'NoIncludedCFileScope' -or $summary.CIncludedItemCount -ne 0 -or $summary.CCompleted -or -not $summary.NonCCompleted -or $summary.NonCAppliedCount -lt 1 -or $summary.ContentRead){throw 'Current imported NonC result did not report verified NonC completion while truthfully reporting no included C file scope.'}
        if($summaryPreparation.CanImportResult -or $summaryPreparation.Status -cne 'ResultAlreadyImported'){throw 'Preparation continued to offer result import after the exact verified result had already been imported.'}

        # Portable Manager -> Target handoff uses the actual verified transfer
        # choice/result summary and the real Target package/snapshot consumers.
        $targetInventoryRoot=Join-Path (Join-Path (Join-Path $targetRoot ('hosts\'+$targetEnrollment.Profile.Fingerprint)) 'inventory') ''
        [void](New-WsmOutputOwnedDirectory $targetInventoryRoot);$targetInventoryOnTarget=Join-Path $targetInventoryRoot 'inventory-1.json';Copy-Item -LiteralPath $targetInventoryPath -Destination $targetInventoryOnTarget
        $targetInventoryOnTargetHash=Get-WsmAssistiveNonCHash $targetInventoryOnTarget
        $targetInventoryJob=[pscustomobject]@{action='Inventory';status='Succeeded';role='Target';workspace=$targetRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Path=$targetInventoryOnTarget;SHA256=$targetInventoryOnTargetHash})}
        $script:fixtureFingerprint=('b'*64)
        $targetPlanImport=Import-WsmWizardApprovedPlan -Workspace $targetRoot -Role Target -Path $approval.Path -ExpectedHash $approval.SHA256
        if($targetPlanImport.Status -cne 'ImportedVerified' -or $targetPlanImport.PairId -cne $catalog.PairId){throw 'Target did not receive the exact approved source plan before NonC result handoff.'}
        $targetDelivery=Export-WsmDirectoryDelivery -ManifestPath $backup.PackageTest.ManifestPath -ExpectedHash $backup.PackageTest.SHA256 -OutputDirectory (Join-Path $Root 'target-directory-delivery')
        $targetPackageImport=Import-WsmWizardTargetDirectoryPackage -Workspace $targetRoot -PairId $catalog.PairId -SummaryPath $targetDelivery.SummaryPath -ExpectedSummaryHash $targetDelivery.SummarySHA256 -SourceDirectory $targetDelivery.Directory -OperationId ([Guid]::NewGuid().ToString('D'))
        $targetPackageJob=[pscustomobject]@{action='DirectoryImport';status='Succeeded';role='Target';workspace=$targetRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');CompletedUtc=(Get-WsmUtc);outputs=@($targetPackageImport)}
        $targetJobs=@($targetInventoryJob,$targetPackageJob)
        $targetCatalog=Get-WsmCatalog $managerRoot $catalog.PairId
        $managerComparison=Update-WsmAssistiveComparison -Workspace $managerRoot -PairId $catalog.PairId -ExpectedRevision $targetCatalog.Assistive.Revision
        $comparisonMaterial=Export-WsmWizardTargetComparison -Workspace $managerRoot -PairId $catalog.PairId -Jobs $summaryJobs
        $targetComparison=Import-WsmWizardTargetComparison -Workspace $targetRoot -PairId $catalog.PairId -Path $comparisonMaterial.Path -ExpectedHash $comparisonMaterial.SHA256 -Jobs $targetJobs
        $targetComparisonJob=[pscustomobject]@{action='ImportTargetComparison';status='Succeeded';role='Target';workspace=$targetRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');CompletedUtc=(Get-WsmUtc);outputs=@($targetComparison)}
        $targetRestoreJobs=@($targetInventoryJob,$targetPackageJob,$targetComparisonJob)
        $targetDecision=Create-WsmWizardTargetDecisionReceipt -Workspace $targetRoot -PairId $catalog.PairId -Decision RestoreNow -Owner 'Target operator' -Reason 'Review the exact NonC readback gate before selecting the delivered handoff.' -SelectedItemIds @($item.ItemId) -Jobs $targetRestoreJobs
        $beforeHandoffProjection=Get-WsmWizardTargetRestoreProjection -Workspace $targetRoot -PairId $catalog.PairId -Jobs $targetRestoreJobs
        $beforeNonCRow=@($beforeHandoffProjection.Rows|Where-Object {$_.ItemId -ceq $item.ItemId})
        if($beforeNonCRow.Count -ne 1 -or $beforeNonCRow[0].Status -cne 'Deferred' -or $beforeNonCRow[0].Action -cne 'DeferredNonC' -or -not $beforeHandoffProjection.PreviewHash){throw 'The official Target restore projection did not keep the selected NonC item deferred before a current imported handoff.'}
        $deferredPreviewJob=[pscustomobject]@{action='TargetRestorePreview';status='ReviewRequired';role='Target';workspace=$targetRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');CompletedUtc=(Get-WsmUtc);outputs=@(Get-WsmHtmlResultProjection @($beforeHandoffProjection))}
        $deferredRuntime=Get-WsmWizardRuntimeProjection -Workspace $targetRoot -PairId $catalog.PairId -Role Target -Jobs (@($targetRestoreJobs)+@($deferredPreviewJob))
        if(-not $deferredRuntime.runtime.restorePreview -or $deferredRuntime.runtime.restorePreview.PreviewHash -cne $beforeHandoffProjection.PreviewHash -or @($deferredRuntime.actions|Where-Object {$_.id -ceq 'TargetRestore' -and $_.available}).Count){throw ('ReviewRequired NonC preview was hidden or incorrectly enabled restore before verified Target materials. RuntimeStatus='+$deferredRuntime.status+' PreviewPresent='+[bool]$deferredRuntime.runtime.restorePreview+' RestoreActions='+@($deferredRuntime.actions|Where-Object {$_.id -ceq 'TargetRestore' -and $_.available}).Count+' Issues='+(@($deferredRuntime.runtime.issues)-join '|'))}
        $handoff=Export-WsmWizardNonCTargetHandoff -Workspace $managerRoot -PairId $catalog.PairId -ManifestHash $transferPlan.ManifestHash -TransferPlanHash $transferPlan.SHA256 -Destination (Join-Path $Root 'target-nonc-handoff') -NextOperator 'Target operator' -Jobs $summaryJobs
        $independentHandoffHash=Get-WsmWizardNonCTargetHandoffHash $handoff.ManifestPath
        if($handoff.Status -cne 'Exported' -or $handoff.ObservedManifestHash -cne $independentHandoffHash -or $handoff.TargetSnapshotHash -ine $targetInventoryOnTargetHash -or $handoff.ResultHash -ine $run.ResultHash){throw 'Manager handoff export did not carry the exact current registered plan/result and Target snapshot bindings.'}
        $payloadHashBeforeHandoff=Get-WsmAssistiveNonCHash $targetFile
        $preview=Get-WsmWizardNonCTargetHandoffPreview -Workspace $targetRoot -PairId $catalog.PairId -Directory $handoff.Directory -ExpectedManifestHash $independentHandoffHash -Jobs $targetRestoreJobs
        $expectedTargetStateDirectory=Join-Path (Read-WsmOutputProfile $targetRoot).WorkRoot 'pairs';$wrongTargetStateInputs=@($script:observedTargetNonCStateDirectories|Where-Object {[IO.Path]::GetFullPath([string]$_) -ine [IO.Path]::GetFullPath($expectedTargetStateDirectory)});if(@($script:observedTargetNonCStateDirectories).Count -lt 1 -or $wrongTargetStateInputs.Count){throw ('Target handoff preview did not pass only the enrolled Target logical WorkRoot\pairs path into core readback. Expected='+$expectedTargetStateDirectory+' Observed='+(@($script:observedTargetNonCStateDirectories) -join '|'))}
        if($preview.Status -cne 'Ready' -or $preview.TransferId -cne $transferPlan.TransferId -or $preview.TargetSnapshotHash -cne $targetInventoryOnTargetHash){throw 'Target did not preview the exact current Manager verified NonC handoff.'}
        $badHashRejected=$false;try{Get-WsmWizardNonCTargetHandoffPreview -Workspace $targetRoot -PairId $catalog.PairId -Directory $handoff.Directory -ExpectedManifestHash ('0'*64) -Jobs $targetRestoreJobs|Out-Null}catch{$badHashRejected=$true};if(-not $badHashRejected){throw 'Target accepted a handoff using an incorrect independently supplied manifest hash.'}
        $tampered=Join-Path $Root 'tampered-target-nonc-handoff';[void][IO.Directory]::CreateDirectory($tampered);Get-ChildItem -LiteralPath $handoff.Directory -File -Recurse|ForEach-Object {$relative=$_.FullName.Substring($handoff.Directory.Length).TrimStart('\');$dest=Join-Path $tampered $relative;$destParent=Split-Path -Parent $dest;if(-not [IO.Directory]::Exists($destParent)){[void][IO.Directory]::CreateDirectory($destParent)};Copy-Item -LiteralPath $_.FullName -Destination $dest}
        [IO.File]::AppendAllText((Join-Path $tampered 'materials\transfer-result.json'),' ')
        $tamperRejected=$false;try{Get-WsmWizardNonCTargetHandoffPreview -Workspace $targetRoot -PairId $catalog.PairId -Directory $tampered -ExpectedManifestHash $independentHandoffHash -Jobs $targetRestoreJobs|Out-Null}catch{$tamperRejected=$true};if(-not $tamperRejected){throw 'Target preview accepted changed result bytes.'}
        # S4: hidden files / hidden directories / hidden reparse points must not escape the exact-file and no-reparse enumeration.
        function S4Message([string]$Dir){$m='';try{Get-WsmWizardNonCTargetHandoffStage $Dir $independentHandoffHash|Out-Null}catch{$m=$_.Exception.Message};$m}
        function S4Variant([string]$Name){$d=Join-Path $Root $Name;[void][IO.Directory]::CreateDirectory($d);Get-ChildItem -LiteralPath $handoff.Directory|Copy-Item -Destination $d -Recurse;$d}
        function S4Hide([string]$Path){[IO.File]::SetAttributes($Path,([IO.File]::GetAttributes($Path) -bor [IO.FileAttributes]::Hidden))}
        if((S4Message $handoff.Directory) -ne ''){throw 'S4 control: the untouched Target NonC handoff must stage cleanly.'}
        $s4File=S4Variant 's4-hidden-file';$s4FilePath=Join-Path $s4File 'stray-hidden.txt';[IO.File]::WriteAllText($s4FilePath,'stray');S4Hide $s4FilePath
        if((S4Message $s4File) -notlike '*unexpected files*'){throw 'S4: a hidden extra file escaped the Target handoff exact-file check.'}
        $s4Dir=S4Variant 's4-hidden-dir';$s4DirPath=Join-Path $s4Dir 'hidden-sub';[void][IO.Directory]::CreateDirectory($s4DirPath);[IO.File]::WriteAllText((Join-Path $s4DirPath 'inner.txt'),'stray');S4Hide $s4DirPath
        if((S4Message $s4Dir) -notlike '*unexpected files*'){throw 'S4: a file inside a hidden subdirectory escaped the Target handoff exact-file check.'}
        $s4Junction=S4Variant 's4-hidden-reparse';$s4JunctionTarget=Join-Path $Root 's4-junction-target';[void][IO.Directory]::CreateDirectory($s4JunctionTarget);$s4JunctionPath=Join-Path $s4Junction 'hidden-junction'
        try{
            & cmd.exe /c ('mklink /J "'+$s4JunctionPath+'" "'+$s4JunctionTarget+'"')|Out-Null;if($LASTEXITCODE -ne 0 -or -not [IO.Directory]::Exists($s4JunctionPath)){throw 'S4 fixture could not create a junction.'};S4Hide $s4JunctionPath
            if((S4Message $s4Junction) -notlike '*Reparse point*'){throw 'S4: a hidden reparse point under the Target handoff tree escaped the no-reparse check.'}
        }finally{if([IO.Directory]::Exists($s4JunctionPath)){& cmd.exe /c ('rmdir "'+$s4JunctionPath+'"')|Out-Null}}
        if([IO.Directory]::Exists($s4JunctionPath)){throw 'S4 fixture left a reparse point behind.'}
        $imported=Import-WsmWizardNonCTargetHandoff -Workspace $targetRoot -PairId $catalog.PairId -Directory $handoff.Directory -ExpectedManifestHash $independentHandoffHash -PreviewId $preview.PreviewId -Jobs $targetRestoreJobs
        $afterHandoffProjection=Get-WsmWizardTargetRestoreProjection -Workspace $targetRoot -PairId $catalog.PairId -Jobs $targetRestoreJobs
        $afterNonCRow=@($afterHandoffProjection.Rows|Where-Object {$_.ItemId -ceq $item.ItemId})
        if($afterNonCRow.Count -ne 1 -or $afterNonCRow[0].Status -cne 'Ready' -or $afterNonCRow[0].Action -cne 'AcceptVerifiedNonC' -or $afterNonCRow[0].Reason -notmatch 'every required native target file/directory has verified live readback' -or $afterHandoffProjection.PreviewHash -ceq $beforeHandoffProjection.PreviewHash){throw 'The official Target restore projection did not expose the exact imported NonC plan/result and core-verified native target readback.'}
        $verifiedPreviewJob=[pscustomobject]@{action='TargetRestorePreview';status='Succeeded';role='Target';workspace=$targetRoot;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');CompletedUtc=(Get-WsmUtc);outputs=@(Get-WsmHtmlResultProjection @($afterHandoffProjection))}
        $verifiedRuntimeJobs=@($targetRestoreJobs)+@($verifiedPreviewJob)
        $verifiedRuntime=Get-WsmWizardRuntimeProjection -Workspace $targetRoot -PairId $catalog.PairId -Role Target -Jobs $verifiedRuntimeJobs
        if($afterHandoffProjection.NonCTransferPlanHash -ine $transferPlan.SHA256 -or $afterHandoffProjection.NonCResultHash -ine $run.ResultHash -or -not $verifiedRuntime.runtime.restorePreview -or $verifiedRuntime.runtime.restorePreview.PreviewHash -cne $afterHandoffProjection.PreviewHash -or @($verifiedRuntime.actions|Where-Object {$_.id -ceq 'TargetRestore' -and $_.available}).Count -ne 1){throw 'Exact valid NonC preview did not survive the durable job-to-runtime boundary with its transfer/result bindings.'}
        $runtimePointerPath=Join-Path (Join-Path (Get-WsmWizardTargetMaterialRoot $targetRoot $catalog.PairId) 'nonc-handoffs') 'active-receipt.json'
        $runtimePointerBytes=[IO.File]::ReadAllBytes($runtimePointerPath)
        try{
            [IO.File]::WriteAllText($runtimePointerPath,'{}',(New-Object Text.UTF8Encoding($false)))
            $invalidRuntime=Get-WsmWizardRuntimeProjection -Workspace $targetRoot -PairId $catalog.PairId -Role Target -Jobs $verifiedRuntimeJobs
            if($invalidRuntime.runtime.restorePreview -or @($invalidRuntime.actions|Where-Object {$_.id -ceq 'TargetRestore' -and $_.available}).Count){throw 'Runtime retained an old NonC preview after the current active receipt pointer became invalid.'}
        }finally{[IO.File]::WriteAllBytes($runtimePointerPath,$runtimePointerBytes)}
        $targetInputs=Get-WsmWizardNonCTargetRestoreInputs -Workspace $targetRoot -PairId $catalog.PairId -Jobs $targetRestoreJobs
        if($imported.Status -cne 'ImportedVerified' -or $targetInputs.Status -cne 'Verified' -or $targetInputs.NonCTransferPlanHash -ine $transferPlan.SHA256 -or $targetInputs.NonCResultHash -ine $run.ResultHash -or -not [IO.File]::Exists($targetInputs.NonCTransferPlanPath) -or -not [IO.File]::Exists($targetInputs.NonCResultPath)){throw 'Target did not persist and revalidate the exact four NonC restore inputs from protected handoff materials.'}
        $replayed=Import-WsmWizardNonCTargetHandoff -Workspace $targetRoot -PairId $catalog.PairId -Directory $handoff.Directory -ExpectedManifestHash $independentHandoffHash -PreviewId $preview.PreviewId -Jobs $targetRestoreJobs
        $replayedInputs=Get-WsmWizardNonCTargetRestoreInputs -Workspace $targetRoot -PairId $catalog.PairId -Jobs $targetRestoreJobs
        if($replayed.ReceiptHash -cne $imported.ReceiptHash -or $replayedInputs.NonCTransferPlanHash -ine $transferPlan.SHA256 -or $replayedInputs.NonCResultHash -ine $run.ResultHash){throw 'Repeating the exact active Target NonC import changed its receipt or hid the active restore inputs.'}
        $secondHandoff=Export-WsmWizardNonCTargetHandoff -Workspace $managerRoot -PairId $catalog.PairId -ManifestHash $transferPlan.ManifestHash -TransferPlanHash $transferPlan.SHA256 -Destination (Join-Path $Root 'target-nonc-handoff-second') -NextOperator 'Target operator second handoff' -Jobs $summaryJobs
        $secondManifestHash=Get-WsmWizardNonCTargetHandoffHash $secondHandoff.ManifestPath
        $secondPreview=Get-WsmWizardNonCTargetHandoffPreview -Workspace $targetRoot -PairId $catalog.PairId -Directory $secondHandoff.Directory -ExpectedManifestHash $secondManifestHash -Jobs $targetRestoreJobs
        $priorActive=Get-WsmWizardNonCTargetActiveReceipt $targetRoot $catalog.PairId
        if($secondPreview.ActiveReceiptHash -cne $priorActive.Hash -or $priorActive.ReceiptHash -cne $imported.ReceiptHash -or $secondPreview.ContentBindingHash -ceq $preview.ContentBindingHash){throw 'A new explicit Target handoff preview did not bind the prior active pointer, receipt and exact new manifest.'}
        $secondImport=Import-WsmWizardNonCTargetHandoff -Workspace $targetRoot -PairId $catalog.PairId -Directory $secondHandoff.Directory -ExpectedManifestHash $secondManifestHash -PreviewId $secondPreview.PreviewId -Jobs $targetRestoreJobs
        $selectedInputs=Get-WsmWizardNonCTargetRestoreInputs -Workspace $targetRoot -PairId $catalog.PairId -Jobs $targetRestoreJobs
        if($secondImport.Status -cne 'ImportedVerified' -or $secondImport.ReceiptHash -ceq $imported.ReceiptHash -or $selectedInputs.NonCTransferPlanHash -ine $transferPlan.SHA256 -or $selectedInputs.NonCResultHash -ine $run.ResultHash){throw 'A newly previewed Target handoff did not select exactly one current verified receipt.'}
        $activePointerPath=Join-Path (Join-Path (Get-WsmWizardTargetMaterialRoot $targetRoot $catalog.PairId) 'nonc-handoffs') 'active-receipt.json';$activePointerHashBefore=(Get-FileHash -LiteralPath $activePointerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if((Get-WsmAssistiveNonCHash $targetFile) -ine $payloadHashBeforeHandoff){throw 'Target handoff import changed an existing target payload path.'}
        $stalePreviewRejected=$false;try{Import-WsmWizardNonCTargetHandoff -Workspace $targetRoot -PairId $catalog.PairId -Directory $handoff.Directory -ExpectedManifestHash $independentHandoffHash -PreviewId $preview.PreviewId -Jobs $targetRestoreJobs|Out-Null}catch{$stalePreviewRejected=$true};$activePointerHashAfter=(Get-FileHash -LiteralPath $activePointerPath -Algorithm SHA256).Hash.ToLowerInvariant();if(-not $stalePreviewRejected -or $activePointerHashAfter -ine $activePointerHashBefore){throw 'Target import accepted a stale preview or changed the active receipt after a failed compare-and-swap.'}

        $staleCatalog=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $current -Depth 50 -Compress);$staleCatalog.Assistive.ResultReferences[0].PlanHash=('0'*64)
        $staleSummary=Get-WsmWizardNonCResultSummary $managerRoot $catalog.PairId $summaryPlan $summaryPreparation $staleCatalog
        if($staleSummary.hasDurableRecord -or $staleSummary.NonCStatus -cne 'AwaitingTargetTransferResult'){throw 'A result reference with a stale plan hash was presented as current.'}
        $forgedResult=Read-WsmTrustedJson $run.ResultPath $run.ResultHash;$forgedResult.Rows[0].TargetPath=([string]$forgedResult.Rows[0].TargetPath+'.outside-reviewed-root');$forgedResultPath=Join-Path (Join-Path $managerRoot 'assistive\results') ((Get-WsmHashText ('forged-row|'+$run.ResultHash))+'.json');Write-WsmJson $forgedResultPath $forgedResult;$forgedResultHash=Get-WsmAssistiveNonCHash $forgedResultPath
        $forgedReference=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $receipt[0] -Depth 16 -Compress);$forgedReference.Reference='assistive/results/'+[IO.Path]::GetFileName($forgedResultPath);$forgedReference.SHA256=$forgedResultHash
        $malformedCatalog=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $current -Depth 50 -Compress);$malformedCatalog.Assistive.ResultReferences=@($malformedCatalog.Assistive.ResultReferences)+@($forgedReference)
        $malformedSummary=Get-WsmWizardNonCResultSummary $managerRoot $catalog.PairId $summaryPlan $summaryPreparation $malformedCatalog
        if(@($malformedSummary.NonCResults).Count -ne 1 -or $malformedSummary.NonCResults[0].ResultHash -ine $run.ResultHash -or -not $malformedSummary.NonCCompleted){throw 'The result summary accepted a registered hash-verified result whose row target differs from the exact reviewed transfer entry.'}
        # A newer registered but malformed package candidate must block a
        # silent fallback to the older valid generation. The evidence file is
        # real and hash-verified; only its deliberately incorrect registry kind
        # is test data.
        Register-WsmAssistiveMaterialReference -Workspace $managerRoot -PairId $catalog.PairId -Generation 999 -Path $freezeProof.Path -SHA256 $freezeProof.SHA256 -Kind AssistivePackageManifest -ConsumerRefs @($item.ItemId)|Out-Null
        $repairGate=Get-WsmWizardNonCPreparation -Workspace $managerRoot -PairId $catalog.PairId -ManifestSelection $backup.PackageTest.SHA256 -Jobs $summaryJobs
        if($repairGate.Status -cne 'NeedsMaterialRepair' -or $repairGate.CanCreateTransferPlan -or $repairGate.CanImportResult -or @($repairGate.Gates|Where-Object code -CEQ 'InvalidPackageMaterial').Count -lt 1){throw 'Malformed newer registered package material silently fell back to an older valid backup.'}
        Write-Host ('PASS: actual approved NonC plan, final package/freeze, typed manager transfer plan, source import, core transfer/readback, and manager result receipt ('+$run.Status+'). I/O used an exact UNC-to-owned-tempdir test adapter; native SMB authentication and transport were not tested.')
    } $root $module ($fixtureDrive+'\') (Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1')
} finally {
    $full=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if($full -ieq $tempRoot -or [IO.Path]::GetDirectoryName($full) -ine $tempRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmwnc-*'){throw 'Unsafe wizard NonC test cleanup path.'}
    & (Join-Path $env:SystemRoot 'System32\subst.exe') $fixtureDrive '/d'|Out-Null
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
}

