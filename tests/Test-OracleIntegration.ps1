#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=[IO.Path]::GetFullPath((Join-Path $tempRoot ('wsm-oracle-integration-'+[Guid]::NewGuid().ToString('N'))))
if(-not $testRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($testRoot)){throw 'Refusing unsafe Oracle integration test directory.'}
[void][IO.Directory]::CreateDirectory($testRoot)
$snapshot=Join-Path $testRoot 'snapshot';[void][IO.Directory]::CreateDirectory($snapshot)
$sourceFiles=@(Get-ChildItem -LiteralPath (Join-Path $repo 'src') -File | Where-Object Extension -EQ '.ps1')+@((Get-Item -LiteralPath (Join-Path $repo 'src\WindowsServerMigration.psm1')),(Get-Item -LiteralPath (Join-Path $repo 'src\WindowsServerMigration.psd1')))
$snapshotReady=$false;$sourceHashes=@{}
for($attempt=0;$attempt -lt 5 -and -not $snapshotReady;$attempt++){
    $sourceHashes=@{};foreach($file in $sourceFiles){$sourceHashes[$file.Name]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    foreach($file in Get-ChildItem -LiteralPath $snapshot -File){Remove-Item -LiteralPath $file.FullName -Force}
    foreach($file in $sourceFiles){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $snapshot $file.Name)}
    $snapshotReady=$true;foreach($file in $sourceFiles){if((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $sourceHashes[$file.Name]){$snapshotReady=$false;break}}
    if(-not $snapshotReady){Start-Sleep -Milliseconds 250}
}
if(-not $snapshotReady){throw 'Could not freeze a stable Oracle integration source snapshot.'}
$snapshotHashes=@{};foreach($file in Get-ChildItem -LiteralPath $snapshot -File){$snapshotHashes[$file.Name]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
$module=$null
try {
    $module=Import-Module (Join-Path $snapshot 'WindowsServerMigration.psd1') -Force -PassThru
    & $module {
        param([string]$Root)
        Set-StrictMode -Version Latest
        function Assert-OracleIntegration([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
        function Write-OracleFixtureJson([string]$Path,$Value){Write-WsmJson $Path $Value;(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Get-OracleFixtureJson([string]$Path,[string]$Hash){Read-WsmTrustedJson $Path $Hash}
        function Test-OracleRejected([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action}catch{$rejected=$true};if(-not $rejected){throw $Message}}

        $inputRoot=Join-Path $Root 'inputs';$scope=Join-Path $inputRoot 'source files';$effective=Join-Path $scope 'network admin';$targetRoot=Join-Path $inputRoot 'target files';$appRoot=Join-Path $inputRoot 'application';$workspace=Join-Path $Root 'workspace';$output=Join-Path $Root 'draft output'
        foreach($directory in @($inputRoot,$scope,$effective,$targetRoot,$appRoot,$output)){[void][IO.Directory]::CreateDirectory($directory)}
        $application=Join-Path $appRoot 'consumer.exe';[IO.File]::WriteAllText($application,'Synthetic executable metadata only; never run.',(New-Object Text.UTF8Encoding($false)))
        $applicationConfig=$application+'.config';$xml='<configuration><appSettings><add key="TNS_ADMIN" value="'+[Security.SecurityElement]::Escape($effective)+'" /></appSettings></configuration>';[IO.File]::WriteAllText($applicationConfig,$xml,(New-Object Text.UTF8Encoding($true)))
        $tns=Join-Path $effective 'tnsnames.ora';$tnsBytes=(New-Object Text.UTF8Encoding($true)).GetBytes("# reviewed fixture`r`nAPPDB = (DESCRIPTION=(ADDRESS=(HOST=db.example.invalid)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=APPDB)))`r`n");[IO.File]::WriteAllBytes($tns,$tnsBytes)
        $wallet=Join-Path $effective 'cwallet.sso';[IO.File]::WriteAllText($wallet,'SYNTHETIC-WALLET-SECRET-MUST-REMAIN-EXTERNAL',(New-Object Text.UTF8Encoding($false)))

        $hostId=[Guid]::NewGuid().ToString('D');$service=New-WsmItem -HostId $hostId -Category Services -Kind Service -Name 'Synthetic Oracle consumer' -NaturalKey 'SyntheticOracleConsumer' -Settings ([pscustomobject]@{PathName=('"'+$application+'"');StartName='NT AUTHORITY\SYSTEM'})
        $providerItem=New-WsmItem -HostId $hostId -Category Runtime -Kind InstalledApplication -Name 'Oracle ODAC 19.3 provider' -NaturalKey 'oracle-odac-provider-19.3' -Settings ([pscustomobject]@{DisplayName='Oracle ODAC 19.3';DisplayVersion='19.3.0';Publisher='Oracle';InstallLocation=(Join-Path $inputRoot 'oracle-home')})
        $fingerprint='a'*64;$source=[pscustomobject][ordered]@{HostId=$hostId;Fingerprint=$fingerprint;Name='synthetic-source';OS='Synthetic Windows';Version='Unknown';Build='Unknown';Edition='Unknown';InstallationType='Unknown';Architecture='Unknown'}
        $inventory=New-WsmInventory -Source $source -Revision 1 -Items @($service,$providerItem)
        $softwareId=Get-WsmSoftwareStableId 'Machine' '' 'Registry64' 'registry:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OracleODAC' 'Oracle ODAC 19.3|19.3.0'
        $observed=(Get-WsmSoftwareUtc)
        $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$hostId;Fingerprint=$fingerprint;Name='synthetic-source';InventoryRevision=1;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=$observed;CaptureIdentity='oracle-integration-fixture';AccountContext='Unknown';CaptureHost='synthetic-fixture';PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@()};Entries=@([pscustomobject][ordered]@{SoftwareId=$softwareId;Name='Oracle ODAC 19.3 provider';Version='19.3.0';Publisher='Oracle';Architecture='Unknown';Scope='Machine';SID='';RegistryView='Registry64';Location='registry:HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OracleODAC';SourceKind='Registry';Evidence=[pscustomobject][ordered]@{RegistryPath='HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OracleODAC';NaturalKey='OracleODAC'};ObservedUtc=$observed;CaptureStatus='Success';ItemIds=@($providerItem.ItemId);AccountContext='Unknown'});Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=10000};ErrorKind=$null;ObservedUtc=$observed});PreparationRequirements=@([pscustomobject][ordered]@{PreparationId=('prep-'+$softwareId.Substring(3));SoftwareId=$softwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@($providerItem.ItemId);Owner='';Reason='Synthetic captured source evidence; owner review required.'});CatalogProjectionHash=('0'*64)}
        $software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software
        Assert-WsmSoftwareCatalog $software -SourceInventory $inventory | Out-Null
        $inventory | Add-Member NoteProperty SoftwareCatalog $software
        Assert-WsmInventory $inventory | Out-Null
        $inventoryPath=Join-Path $inputRoot 'inventory.json';$inventoryHash=Write-OracleFixtureJson $inventoryPath $inventory
        $softwarePath=Join-Path $inputRoot 'software-catalog.json';$softwareHash=Write-OracleFixtureJson $softwarePath $software

        # Only the private native Oracle observation seam is synthetic. File
        # candidate parsing, trusted file readers and all validators are real.
        function Get-WsmOracleNativeObservations($SourceInventory) {
            [pscustomobject]@{Candidates=@([pscustomobject]@{Source='MachineEnvironment';Name='TNS_ADMIN';Value=$effective;Exists=$true;IsEmpty=$false;ValueType='';RegistryView='';CandidateOnly=$true;EffectiveValueProven=$false},[pscustomobject]@{Source='OracleRegistry';Name='TNS_ADMIN';Value=(Join-Path $inputRoot 'unselected-32');Exists=$true;IsEmpty=$false;ValueType='String';RegistryView='Registry32';CandidateOnly=$true;EffectiveValueProven=$false},[pscustomobject]@{Source='OracleRegistry';Name='TNS_ADMIN';Value=(Join-Path $inputRoot 'unselected-64');Exists=$true;IsEmpty=$false;ValueType='String';RegistryView='Registry64';CandidateOnly=$true;EffectiveValueProven=$false});Homes=@();Coverage=@([pscustomobject]@{Source='FixtureNativeOracleSnapshot';Status='NotTested';Reason='Synthetic candidates; no native server was inspected.'});AdminProcessEnvironmentRead=$false}
        }
        $consumerInput=[pscustomobject][ordered]@{ProviderSoftwareId=$softwareId;ProviderItemId=$providerItem.ItemId;Provider='ODP.NET.Managed';Version='19.3.0';Architecture='Unknown';OracleHome=(Join-Path $inputRoot 'oracle-home');AccountType='Service';AccountName='NT AUTHORITY\SYSTEM';AccountSid='S-1-5-18';ConsumerItemIds=@($service.ItemId);ObservedEffectivePath=$effective;ApprovedIFiles=@()}
        $bindingTemplatePath=Join-Path $output 'consumer-binding-template.json'
        $templateResult=Export-WsmOracleConsumerBindingTemplate -InventoryPath $inventoryPath -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash -Consumers @($consumerInput) -Path $bindingTemplatePath
        Assert-OracleIntegration ($templateResult.ReviewStatus -eq 'OwnerReviewRequired' -and -not $templateResult.Trusted) 'Consumer template did not remain an untrusted owner-review draft.'
        $template=Get-OracleFixtureJson $bindingTemplatePath $templateResult.SHA256
        Assert-OracleIntegration ($template.Consumers[0].ProviderSoftwareId -ceq $softwareId -and $template.Consumers[0].ProviderItemId -ceq $providerItem.ItemId -and $template.ConnectionProofStatus -ceq 'NotTested') 'Template lost its B1 software/provider-item linkage or claimed connection evidence.'

        $badProvider=$consumerInput.PSObject.Copy();$badProvider.ProviderSoftwareId='sw-'+('0'*32)
        Test-OracleRejected {Export-WsmOracleConsumerBindingTemplate -InventoryPath $inventoryPath -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash -Consumers @($badProvider) -Path (Join-Path $output 'bad-provider.json')} 'Unknown provider SoftwareId was accepted.'
        Test-OracleRejected {Export-WsmOracleConsumerBindingTemplate -InventoryPath $inventoryPath -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash ('0'*64) -Consumers @($consumerInput) -Path (Join-Path $output 'bad-catalog-hash.json')} 'Incorrect software-catalog file hash was accepted.'
        $badCatalog=$software.PSObject.Copy();$badCatalog.Source=$software.Source.PSObject.Copy();$badCatalog.Source.InventoryProjectionHash='0'*64;$badCatalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $badCatalog;$badCatalogPath=Join-Path $inputRoot 'wrong-source-projection.json';$badCatalogHash=Write-OracleFixtureJson $badCatalogPath $badCatalog
        Test-OracleRejected {Read-WsmOracleSoftwareCatalog $badCatalogPath $badCatalogHash $inventory | Out-Null} 'B1 software catalog with an incompatible source projection was accepted.'

        $reviewedBinding=$template.PSObject.Copy();$reviewedBinding.ReviewStatus='OwnerConfirmed';$reviewedConsumer=$template.Consumers[0].PSObject.Copy();$reviewedConsumer.Owner='Oracle application owner';$reviewedConsumer.Evidence='change-record:oracle-consumer-1';$reviewedConsumer.ReviewStatus='OwnerConfirmed';$reviewedBinding.Consumers=@($reviewedConsumer)
        $bindingPath=Join-Path $inputRoot 'consumer-binding-reviewed.json';$bindingHash=Write-OracleFixtureJson $bindingPath $reviewedBinding
        $binding=Read-WsmOracleConsumerBinding -Path $bindingPath -ExpectedHash $bindingHash -Inventory $inventory -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash
        Assert-OracleIntegration ($binding.ReviewStatus -ceq 'OwnerConfirmed' -and $binding.Consumers[0].Owner -ceq 'Oracle application owner') 'Reviewed binding did not pass the actual trusted binding validator.'
        $badItemBinding=$reviewedBinding.PSObject.Copy();$badItemConsumer=$reviewedBinding.Consumers[0].PSObject.Copy();$badItemConsumer.ProviderItemId='f'*64;$badItemConsumer.ConsumerId=Get-WsmOracleConsumerId $badItemConsumer;$badItemBinding.Consumers=@($badItemConsumer);$badItemPath=Join-Path $inputRoot 'bad-provider-item.json';$badItemHash=Write-OracleFixtureJson $badItemPath $badItemBinding
        Test-OracleRejected {Read-WsmOracleConsumerBinding -Path $badItemPath -ExpectedHash $badItemHash -Inventory $inventory -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash | Out-Null} 'ProviderItemId outside the trusted inventory/catalog relation was accepted.'
        $badBindingHash=$reviewedBinding.PSObject.Copy();$badBindingHash.SoftwareCatalogHash='0'*64;$badBindingHashPath=Join-Path $inputRoot 'bad-binding-catalog-hash.json';$badBindingHashDigest=Write-OracleFixtureJson $badBindingHashPath $badBindingHash
        Test-OracleRejected {Read-WsmOracleConsumerBinding -Path $badBindingHashPath -ExpectedHash $badBindingHashDigest -Inventory $inventory -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash | Out-Null} 'Consumer binding pinned to a different software catalog hash was accepted.'

        $spec=[pscustomobject][ordered]@{Adapter='FileScope';SourcePath=$scope;TargetPath=$targetRoot;ExcludedRelativePaths=@('network admin\cwallet.sso');Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='Block';Owner='Oracle configuration owner';Evidence='review-record:oracle-file-scope';ConfigFiles=@();ConfigOverrides=@()}
        $specPath=Join-Path $inputRoot 'file-scope.json';$specHash=Write-OracleFixtureJson $specPath $spec
        $draftPath=Join-Path $output 'oracle-config-draft.json'
        $draftResult=Get-WsmOracleClientConfigDraft -InventoryPath $inventoryPath -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash -FileScopeSpecPath $specPath -ExpectedSpecHash $specHash -ConsumerBindingPath $bindingPath -ExpectedBindingHash $bindingHash -Path $draftPath
        Assert-OracleIntegration ($draftResult.Status -ceq 'OwnerAttestedStaticOnly' -and $draftResult.ConnectionProofStatus -ceq 'NotTested' -and -not $draftResult.ProductionVerified) 'Draft did not remain static owner-attested evidence.'
        $draft=Get-OracleFixtureJson $draftPath $draftResult.SHA256
        Assert-OracleIntegration ($draft.ConfigFiles.Count -eq 1 -and $draft.ConfigFiles[0].RelativePath -ceq 'network admin\tnsnames.ora' -and $draft.ConfigFiles[0].SHA256 -ceq (Get-FileHash -LiteralPath $tns -Algorithm SHA256).Hash.ToLowerInvariant()) 'Draft did not bind the exact ConfigFiles path and raw-byte SHA-256.'
        Assert-OracleIntegration (@($draft.ExternalMaterials | Where-Object { $_.Class -eq 'ExternalSecretOrWallet' -and -not $_.IncludedInPackage }).Count -eq 1 -and @($draft.ConfigFiles | Where-Object RelativePath -Match 'wallet').Count -eq 0) 'Wallet was included or did not receive an explicit external-only classification.'
        Assert-OracleIntegration ($draft.Consumers[0].NativeTnsAdminCandidateMatched -and $draft.Consumers[0].ApplicationTnsAdminCandidateMatched -and $draft.Consumers[0].ConnectionProofStatus -ceq 'NotTested') 'Native or application TNS_ADMIN candidates were not retained as unproven candidate evidence.'

        # The actual external-material helper must find nested material,
        # reject incomplete walks, and make the draft fail closed on errors.
        $nestedWalletDirectory=Join-Path (Join-Path $effective 'secure') 'wallet';[void][IO.Directory]::CreateDirectory($nestedWalletDirectory)
        $nestedWallet=Join-Path $nestedWalletDirectory 'ewallet.p12';[IO.File]::WriteAllText($nestedWallet,'NESTED-WALLET-SECRET-MUST-REMAIN-EXTERNAL',(New-Object Text.UTF8Encoding($false)))
        $nestedScan=Get-WsmOracleExternalMaterialCandidates -Root $effective -MaxEntries 32 -MaxDepth 8
        Assert-OracleIntegration (@($nestedScan.Candidates | Where-Object { $_.Path -ceq $nestedWalletDirectory }).Count -eq 1 -and @($nestedScan.Candidates | Where-Object { $_.Path -ceq $nestedWallet }).Count -eq 0) 'Bounded recursive walk did not classify a nested wallet directory as external material.'
        Test-OracleRejected {Get-WsmOracleExternalMaterialCandidates -Root $effective -MaxEntries 1 -MaxDepth 8 | Out-Null} 'External-material walker did not fail at its entry budget.'
        $nestedSpec=$spec.PSObject.Copy();$nestedSpec.ExcludedRelativePaths=@($spec.ExcludedRelativePaths)+@('network admin\secure\wallet')
        $nestedSpecPath=Join-Path $inputRoot 'nested-wallet-file-scope.json';$nestedSpecHash=Write-OracleFixtureJson $nestedSpecPath $nestedSpec
        $nestedDraftPath=Join-Path $output 'nested-wallet-draft.json';$nestedDraftResult=Get-WsmOracleClientConfigDraft -InventoryPath $inventoryPath -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash -FileScopeSpecPath $nestedSpecPath -ExpectedSpecHash $nestedSpecHash -ConsumerBindingPath $bindingPath -ExpectedBindingHash $bindingHash -Path $nestedDraftPath
        $nestedDraft=Get-OracleFixtureJson $nestedDraftPath $nestedDraftResult.SHA256
        Assert-OracleIntegration ($nestedDraftResult.Status -ceq 'OwnerAttestedStaticOnly' -and @($nestedDraft.ExternalMaterials | Where-Object { $_.RelativePath -ceq 'network admin\secure\wallet' -and $_.Class -ceq 'ExternalSecretOrWallet' -and -not $_.IncludedInPackage }).Count -eq 1) 'Nested wallet was not represented as an external-only material with exact reviewed exclusion.'
        $unexcludedNestedSpec=$spec.PSObject.Copy();$unexcludedNestedSpecPath=Join-Path $inputRoot 'unexcluded-nested-wallet-file-scope.json';$unexcludedNestedSpecHash=Write-OracleFixtureJson $unexcludedNestedSpecPath $unexcludedNestedSpec
        $unexcludedNestedDraftPath=Join-Path $output 'unexcluded-nested-wallet-draft.json';$unexcludedNestedResult=Get-WsmOracleClientConfigDraft -InventoryPath $inventoryPath -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash -FileScopeSpecPath $unexcludedNestedSpecPath -ExpectedSpecHash $unexcludedNestedSpecHash -ConsumerBindingPath $bindingPath -ExpectedBindingHash $bindingHash -Path $unexcludedNestedDraftPath
        $unexcludedNestedDraft=Get-OracleFixtureJson $unexcludedNestedDraftPath $unexcludedNestedResult.SHA256
        Assert-OracleIntegration ($unexcludedNestedResult.Status -ceq 'Blocked' -and @($unexcludedNestedDraft.Issues | Where-Object { $_.Code -ceq 'ExternalMaterialInsidePackageScope' -and $_.Path -ceq 'network admin\secure\wallet' }).Count -eq 1) 'Nested wallet inside the package scope did not block the draft.'
        $realDirectoryEnumerator=(Get-Command Get-WsmOracleDirectoryEnumerator).ScriptBlock
        $script:WsmOracleFixtureFailureRoot=[IO.Path]::GetFullPath($effective);$script:WsmOracleFixtureRealEnumerator=$realDirectoryEnumerator
        function Get-WsmOracleDirectoryEnumerator([string]$Path) { if([IO.Path]::GetFullPath($Path) -ieq $script:WsmOracleFixtureFailureRoot){throw 'Injected external-material enumeration failure.'}; & $script:WsmOracleFixtureRealEnumerator $Path }
        try {
            $failedWalkPath=Join-Path $output 'failed-wallet-walk-draft.json'
            $failedWalkResult=Get-WsmOracleClientConfigDraft -InventoryPath $inventoryPath -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash -FileScopeSpecPath $nestedSpecPath -ExpectedSpecHash $nestedSpecHash -ConsumerBindingPath $bindingPath -ExpectedBindingHash $bindingHash -Path $failedWalkPath
            $failedWalk=Get-OracleFixtureJson $failedWalkPath $failedWalkResult.SHA256
            Assert-OracleIntegration ($failedWalkResult.Status -ceq 'Blocked' -and @($failedWalk.Issues | Where-Object Code -ceq 'ExternalMaterialDiscoveryIncomplete').Count -eq 1 -and @($failedWalk.Consumers | Where-Object Status -CEQ Blocked).Count -eq 1) 'External-material enumeration failure did not block the actual Oracle draft.'
        } finally {
            Set-Item -Path Function:\Get-WsmOracleDirectoryEnumerator -Value $realDirectoryEnumerator
            Remove-Variable WsmOracleFixtureFailureRoot,WsmOracleFixtureRealEnumerator -Scope Script -ErrorAction SilentlyContinue
        }
        $wrongScopeSpec=$spec.PSObject.Copy();$wrongScopeSpec.SourcePath=Join-Path $inputRoot 'unrelated-file-scope';[void][IO.Directory]::CreateDirectory($wrongScopeSpec.SourcePath);$wrongScopeSpecPath=Join-Path $inputRoot 'wrong-scope.json';$wrongScopeHash=Write-OracleFixtureJson $wrongScopeSpecPath $wrongScopeSpec
        $wrongScopeDraftPath=Join-Path $output 'wrong-scope-draft.json';$wrongScopeDraft=Get-WsmOracleClientConfigDraft -InventoryPath $inventoryPath -ExpectedInventoryHash $inventoryHash -SoftwareCatalogPath $softwarePath -ExpectedSoftwareCatalogHash $softwareHash -FileScopeSpecPath $wrongScopeSpecPath -ExpectedSpecHash $wrongScopeHash -ConsumerBindingPath $bindingPath -ExpectedBindingHash $bindingHash -Path $wrongScopeDraftPath
        $wrongScopeDoc=Get-OracleFixtureJson $wrongScopeDraftPath $wrongScopeDraft.SHA256
        Assert-OracleIntegration ($wrongScopeDraft.Status -ceq 'Blocked' -and @($wrongScopeDoc.Issues | Where-Object Code -CEQ EffectiveConfigBlocked).Count -eq 1) 'Effective Oracle settings outside the reviewed FileScope were accepted as portable config.'
        $preparation=@($draft.Requirements | Where-Object Type -CEQ Preparation)[0]
        Assert-OracleIntegration ($preparation.ProviderSoftwareId -ceq $softwareId -and -not $preparation.ProviderItemId -and $preparation.Context.ProviderItemId -ceq $providerItem.ItemId -and $preparation.RequiredPhase -ceq 'StagedDependencyVerified') 'Typed requirement did not bind exactly one B1 provider while retaining its linked ItemId evidence.'
        Assert-OracleIntegration (@($draft.Requirements | Where-Object Type -CEQ ExternalDependency | Where-Object RequiredPhase -CEQ CutoverReady).Count -eq 1) 'Actual consumer workflow omitted its external consumer test gate.'

        # Exercise the actual owner-reviewed FileScope and GeneralHost import
        # APIs against the same trusted inventory, provider catalog and draft.
        Initialize-WsmWorkspace $workspace | Out-Null
        $imported=Import-WsmInventory -Workspace $workspace -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'synthetic-target'
        $general=Set-WsmGeneralHostMode -Workspace $workspace -PairId $imported.PairId -ExpectedRevision $imported.DecisionRevision
        $generalState=Get-WsmCatalog $workspace $imported.PairId
        Set-WsmGeneralHostSoftwareCatalog -Workspace $workspace -PairId $imported.PairId -Path $softwarePath -ExpectedHash $softwareHash -ExpectedRevision $generalState.DecisionRevision | Out-Null
        $general=Get-WsmCatalog $workspace $imported.PairId
        $reviewedSpec=$spec.PSObject.Copy();$reviewedSpec.ConfigFiles=@($draft.ConfigFiles);$reviewedSpecPath=Join-Path $inputRoot 'reviewed-file-scope.json';$reviewedSpecHash=Write-OracleFixtureJson $reviewedSpecPath $reviewedSpec
        Assert-WsmMigrationSpec (Get-OracleFixtureJson $reviewedSpecPath $reviewedSpecHash) | Out-Null
        $stored=Set-WsmMigrationSpec -Workspace $workspace -PairId $imported.PairId -ItemId $service.ItemId -Path $reviewedSpecPath -ExpectedHash $reviewedSpecHash -ExpectedRevision $general.DecisionRevision
        $storedCatalog=Get-WsmCatalog $workspace $imported.PairId;$storedItem=@($storedCatalog.Items | Where-Object ItemId -CEQ $service.ItemId)[0]
        Assert-OracleIntegration ($storedItem.MigrationSpec.ConfigFiles.Count -eq 1 -and $storedItem.MigrationSpec.ConfigFiles[0].OracleClient.BindingHash -ceq $bindingHash) 'Owner-reviewed ConfigFiles did not persist with the trusted Oracle consumer binding.'
        $missingWalletExclusion=$reviewedSpec.PSObject.Copy();$missingWalletExclusion.ExcludedRelativePaths=@()
        Test-OracleRejected {Assert-WsmMigrationSpec $missingWalletExclusion | Out-Null} 'FileScope spec without exact wallet exclusion was accepted.'

        $typedRequirements=@(foreach($sourceRequirement in $draft.Requirements){$requirement=$sourceRequirement.PSObject.Copy();$requirement | Add-Member NoteProperty Certainty Required -Force;$requirement | Add-Member NoteProperty Decision Pending -Force;$requirement | Add-Member NoteProperty DecisionReason '' -Force;$requirement | Add-Member NoteProperty DecisionEvidence '' -Force;$requirement})
        $requirementsPath=Join-Path $inputRoot 'reviewed-requirements.json';$requirementsDoc=[pscustomobject]@{Requirements=$typedRequirements};$requirementsHash=Write-OracleFixtureJson $requirementsPath $requirementsDoc
        $catalogBefore=Get-WsmCatalog $workspace $imported.PairId
        $preview=Get-WsmGeneralHostRequirementPreview -Workspace $workspace -PairId $imported.PairId -Path $requirementsPath -ExpectedHash $requirementsHash -ExpectedRevision $catalogBefore.DecisionRevision
        $previewHash=Get-WsmGeneralHostPreviewHash -Preview $preview -Kind Requirement
        Set-WsmGeneralHostRequirements -Workspace $workspace -PairId $imported.PairId -Path $requirementsPath -ExpectedHash $requirementsHash -ExpectedRevision $catalogBefore.DecisionRevision -ExpectedPreviewHash $previewHash | Out-Null
        $final=Get-WsmCatalog $workspace $imported.PairId
        Assert-WsmGeneralHostContract $final | Out-Null
        Assert-OracleIntegration (@($final.GeneralHost.Requirements).Count -eq 2 -and @($final.GeneralHost.Requirements | Where-Object { $_.ProviderSoftwareId -ceq $softwareId -and -not $_.ProviderItemId -and $_.RequiredPhase -ceq 'StagedDependencyVerified' }).Count -eq 1 -and @($final.GeneralHost.Requirements | Where-Object { $_.Type -ceq 'ExternalDependency' -and $_.RequiredPhase -ceq 'CutoverReady' }).Count -eq 1) 'Actual GeneralHost requirement application did not preserve B2 staged and external gates.'
        $planItem=$final.Items | Where-Object ItemId -CEQ $service.ItemId;$planItem.Decision='Include';$plan=[pscustomobject]@{Items=@($planItem)};$ownership=Assert-WsmOraclePlanConfigOwnership $plan
        Assert-OracleIntegration ($ownership.Valid -and $ownership.OracleConfigFiles -eq 1 -and $ownership.SharedFilesHaveOneOwner) 'Actual Oracle plan ownership validator rejected or lost the reviewed ConfigFiles binding.'

        # Empty values are observed if the key exists; absence remains no row.
        $candidateRows=New-Object 'System.Collections.Generic.List[object]';Add-WsmOracleEnvironmentCandidates $candidateRows @{TNS_ADMIN='';NLS_LANG='   '} 'MachineEnvironment' '' '' '' 'fixture-machine'
        Assert-OracleIntegration (@($candidateRows.ToArray() | Where-Object Name -CEQ TNS_ADMIN | Where-Object { $_.Exists -and $_.IsEmpty -and $_.Value -ceq '' -and $_.CandidateOnly -and -not $_.EffectiveValueProven }).Count -eq 1) 'Present empty TNS_ADMIN was dropped, represented as absent, or treated as an effective fallback.'
        Assert-OracleIntegration (@($candidateRows.ToArray() | Where-Object Name -CEQ NLS_LANG | Where-Object { $_.Exists -and -not $_.IsEmpty -and $_.Value -ceq '   ' }).Count -eq 1) 'Present whitespace environment value was normalized or dropped.'
        Assert-OracleIntegration (@($candidateRows.ToArray() | Where-Object Name -CEQ ORACLE_HOME).Count -eq 0) 'Absent Oracle variable was incorrectly represented as a candidate.'
        $serviceRows=New-Object 'System.Collections.Generic.List[object]';$serviceCoverage=New-Object 'System.Collections.Generic.List[object]';Add-WsmOracleServiceEnvironmentCandidates $serviceRows $serviceCoverage $service.ItemId @('TNS_ADMIN=','NLS_LANG=   ','UNRELATED=value') 'MultiString' 'HKLM\SYSTEM\CurrentControlSet\Services\SyntheticOracleConsumer\Environment'
        Assert-OracleIntegration (@($serviceRows.ToArray() | Where-Object { $_.Name -ceq 'TNS_ADMIN' -and $_.Exists -and $_.IsEmpty -and $_.ValueType -ceq 'MultiString' }).Count -eq 1) 'Service REG_MULTI_SZ empty TNS_ADMIN candidate was lost.'
        Assert-OracleIntegration (@($serviceRows.ToArray() | Where-Object { $_.Name -ceq 'NLS_LANG' -and $_.Value -ceq '   ' -and $_.ValueType -ceq 'MultiString' }).Count -eq 1) 'Service REG_MULTI_SZ whitespace candidate was changed.'
        $invalidServiceRows=New-Object 'System.Collections.Generic.List[object]';$invalidCoverage=New-Object 'System.Collections.Generic.List[object]';Add-WsmOracleServiceEnvironmentCandidates $invalidServiceRows $invalidCoverage $service.ItemId 'TNS_ADMIN=bad' 'String' 'fixture-service-environment'
        Assert-OracleIntegration (@($invalidCoverage.ToArray() | Where-Object Status -CEQ CoverageGap).Count -eq 1 -and $invalidServiceRows.Count -eq 0) 'Unsupported service Environment registry kind was mistaken for no service setting.'
        Assert-OracleIntegration ($draft.ConnectionProofStatus -ceq 'NotTested' -and $draft.ProductionVerified -eq $false -and $template.ConnectionProofStatus -ceq 'NotTested') 'Synthetic integration fixture claims native Server, Oracle or business qualification.'
        Write-Host 'PASS: actual Oracle template, trusted consumer binding, config draft, FileScope validation, GeneralHost typed requirements, wallet exclusion, and empty/service-environment candidate semantics.'
    } $testRoot
} finally {
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    foreach($file in Get-ChildItem -LiteralPath $snapshot -File -ErrorAction SilentlyContinue){if($snapshotHashes.ContainsKey($file.Name) -and (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $snapshotHashes[$file.Name]){throw ('Fixed test snapshot changed during test: '+$file.Name)}}
    $resolved=[IO.Path]::GetFullPath($testRoot);$tempPrefix=$tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-oracle-integration-*'){throw 'Refusing cleanup outside the unique test-owned absolute directory.'}
    if([IO.Directory]::Exists($resolved)){[IO.Directory]::Delete($resolved,$true)}
}
