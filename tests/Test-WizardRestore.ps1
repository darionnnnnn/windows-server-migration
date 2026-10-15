#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$outerRestoreCommand=Get-Command Get-WsmWizardTargetRestoreProjection -ErrorAction Stop
if($outerRestoreCommand.ModuleName -cne $module.Name -or $outerRestoreCommand.ScriptBlock.File -notlike '*\WizardRestore.ps1'){throw 'Target restore preview wrapper did not resolve to the exported module-owned implementation.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-wtr-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$workRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsmwtr-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
try {
    & $module {
        param($Root,$HelperPath,$WorkRoot)
        $innerRestoreCommand=Get-Command Get-WsmWizardTargetRestoreProjection -ErrorAction Stop
        if($innerRestoreCommand.ModuleName -cne $ExecutionContext.SessionState.Module.Name -or $innerRestoreCommand.ScriptBlock.File -notlike '*\WizardRestore.ps1'){throw 'Nested Target restore preview wrapper did not resolve to the module-owned implementation.'}
        $script:wizardRestoreChecks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:wizardRestoreChecks++}
        function Reject([scriptblock]$action,[string]$message){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $message}
        function SaveJson($data,[string]$path){[IO.File]::WriteAllText($path,($data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$path}

        # The only substituted observation is the local host identity. Plan, receipt,
        # inventory, comparison validation and durable material readers remain core code.
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='Target fixture';OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:wsmWizardRestoreTarget}
        $script:wsmWizardRestoreTarget=$target
        $work=$WorkRoot;$enrollment=Initialize-WsmOutputWorkspace -WorkRoot $work -Role Target;$target|Add-Member NoteProperty HostId ([string]$enrollment.Profile.HostId) -Force
        $initialProfileHash=(Get-FileHash -LiteralPath (Join-Path (Join-Path $work 'workspace-control') 'output-profile.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        Check ($enrollment.Profile.Mode -ceq 'Zip' -and [long]$enrollment.Profile.VolumeBytes -eq 536870912) 'Target enrollment did not retain the default ZIP OutputProfile.'
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='Source fixture';OS='Fixture Windows Server';Version='10.0'}
        $item=New-WsmItem $source.HostId Storage DataRoot 'Approved fixture workload' 'fixture-source' @{Path='C:\fixture\source'}
        $item|Add-Member NoteProperty Decision Include -Force;$item|Add-Member NoteProperty Reason 'Source owner reviewed fixture scope' -Force;$item|Add-Member NoteProperty Owner 'Source owner' -Force;$item|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
        $scopeRoot=Join-Path $Root 'source-scope';[void][IO.Directory]::CreateDirectory($scopeRoot);$sourceBytes=New-Object byte[] (2*1024*1024);$randomBytes=[Security.Cryptography.RandomNumberGenerator]::Create();try{$randomBytes.GetBytes($sourceBytes)}finally{$randomBytes.Dispose()};$sourceFile=Join-Path $scopeRoot 'state.bin';[IO.File]::WriteAllBytes($sourceFile,$sourceBytes)
        $targetRoot=Join-Path $Root 'restored-scope'
        $fileSpec=[pscustomobject][ordered]@{Adapter='FileScope';Product='Fixture workload';Procedure='Owner independently verifies the restored file';Artifacts=@();BusinessChecks=@('Owner confirms exact file bytes and ACL');Owner='Source owner';Evidence='fixture approval evidence';SourcePath=$scopeRoot;TargetPath=$targetRoot;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';TransferChannel='C';ContentSelection='WholeScope';ConfigFiles=@();ConfigOverrides=@()}
        $item|Add-Member NoteProperty MigrationSpec $fileSpec -Force
        $scopeRoot2=Join-Path $Root 'source-scope-2';[void][IO.Directory]::CreateDirectory($scopeRoot2);$sourceBytes2=[Text.Encoding]::UTF8.GetBytes('second actual Target restore payload');$sourceFile2=Join-Path $scopeRoot2 'state.bin';[IO.File]::WriteAllBytes($sourceFile2,$sourceBytes2)
        $targetRoot2=Join-Path $Root 'restored-scope-2';[void][IO.Directory]::CreateDirectory($targetRoot2);$targetFile2=Join-Path $targetRoot2 'state.bin';$preexistingBytes=[Text.Encoding]::UTF8.GetBytes('unowned target file must remain untouched');[IO.File]::WriteAllBytes($targetFile2,$preexistingBytes);$preexistingHash=(Get-FileHash -LiteralPath $targetFile2 -Algorithm SHA256).Hash.ToLowerInvariant();$preexistingMetadata=Get-WsmFileMetadata $targetFile2 'DaclOwner';$preexistingCreationTicks=(Get-Item -LiteralPath $targetFile2).CreationTimeUtc.Ticks
        $item2=New-WsmItem $source.HostId Storage DataRoot 'Approved conflicting fixture workload' 'fixture-source-2' @{Path='C:\fixture\source-2'}
        $item2|Add-Member NoteProperty Decision Include -Force;$item2|Add-Member NoteProperty Reason 'Source owner reviewed second fixture scope' -Force;$item2|Add-Member NoteProperty Owner 'Source owner' -Force;$item2|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
        $fileSpec2=$fileSpec|ConvertTo-Json -Depth 40|ConvertFrom-Json;$fileSpec2.SourcePath=$scopeRoot2;$fileSpec2.TargetPath=$targetRoot2;$item2|Add-Member NoteProperty MigrationSpec $fileSpec2 -Force
        $scopeRoot3=Join-Path $Root 'source-scope-3';[void][IO.Directory]::CreateDirectory($scopeRoot3);$sourceBytes3=New-Object byte[] (512*1024);$randomBytes3=[Security.Cryptography.RandomNumberGenerator]::Create();try{$randomBytes3.GetBytes($sourceBytes3)}finally{$randomBytes3.Dispose()};$sourceFile3=Join-Path $scopeRoot3 'state.bin';[IO.File]::WriteAllBytes($sourceFile3,$sourceBytes3)
        $targetRoot3=Join-Path $Root 'restored-scope-3'
        $item3=New-WsmItem $source.HostId Storage DataRoot 'Approved resumable fixture workload' 'fixture-source-3' @{Path='C:\fixture\source-3'}
        $item3|Add-Member NoteProperty Decision Include -Force;$item3|Add-Member NoteProperty Reason 'Source owner reviewed third fixture scope' -Force;$item3|Add-Member NoteProperty Owner 'Source owner' -Force;$item3|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
        $fileSpec3=$fileSpec|ConvertTo-Json -Depth 40|ConvertFrom-Json;$fileSpec3.SourcePath=$scopeRoot3;$fileSpec3.TargetPath=$targetRoot3;$item3|Add-Member NoteProperty MigrationSpec $fileSpec3 -Force
        # Control-only NonC observation fixture: no NonC payload/I/O is claimed.
        $item4=New-WsmItem $source.HostId Storage DataRoot 'Deferred NonC observation fixture' 'fixture-source-4' @{Path='D:\wsm-r6-deferred-fixture'}
        foreach($name in @('Decision','Reason','Owner','Evidence')){$item4|Add-Member NoteProperty $name $item3.$name -Force}
        $fileSpec4=$fileSpec|ConvertTo-Json -Depth 40|ConvertFrom-Json;$fileSpec4.SourcePath='D:\wsm-r6-deferred-fixture';$fileSpec4.TargetPath=Join-Path $Root 'deferred-nonc';$fileSpec4.TransferChannel='NonC';$item4|Add-Member NoteProperty MigrationSpec $fileSpec4 -Force
        $sourceInventory=New-WsmInventory $source 1 @($item,$item2,$item3,$item4)
        $sourceInventoryPath=Join-Path $Root 'source-inventory.json';SaveJson $sourceInventory $sourceInventoryPath|Out-Null;$sourceHash=(Get-FileHash -LiteralPath $sourceInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $pair=[Guid]::NewGuid().ToString();$selectionRevision=3;$planItem=$item|ConvertTo-Json -Depth 40|ConvertFrom-Json;$planItem2=$item2|ConvertTo-Json -Depth 40|ConvertFrom-Json;$planItem3=$item3|ConvertTo-Json -Depth 40|ConvertFrom-Json
        $plan=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion='0.4.0';Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString();PairId=$pair;ApprovalId=[Guid]::NewGuid().ToString();Source=$source;Target=[pscustomobject]@{HostId=$enrollment.Profile.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;OS=$target.OS;Version=$target.Version};InventoryRevision=1;DecisionRevision=4;InventoryHash=$sourceHash;ImportedUtc=(Get-WsmUtc);Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);ApprovedUtc=(Get-WsmUtc);Items=@($planItem2,$planItem,$planItem3);ScopeMode='Assistive'}
        $authority=[pscustomobject][ordered]@{SourceSnapshotReference=[pscustomobject][ordered]@{Reference='source-inventory.json';SHA256=$sourceHash;InventoryRevision=1;CreatedUtc=(Get-WsmUtc)};InventoryRevision=1;SelectionRevision=$selectionRevision;Dispositions=@([pscustomobject][ordered]@{ItemId=[string]$item2.ItemId;Selected=$true;Decision='Include';Reason='Explicitly reviewed source selection'},[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Selected=$true;Decision='Include';Reason='Explicitly reviewed source selection'},[pscustomobject][ordered]@{ItemId=[string]$item3.ItemId;Selected=$true;Decision='Include';Reason='Explicitly reviewed source selection'})}
        $plan|Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=$pair;SourceSnapshotHash=$sourceHash;SourcePolicy='SourceCOnly';SourceSelectionsVersion=$selectionRevision;ApprovedItemIds=@([string]$item2.ItemId,[string]$item.ItemId,[string]$item3.ItemId);MaterialReferences=@();DiscoveryAuthority=$authority}) -Force
        $plan.Items+=@($item4|ConvertTo-Json -Depth 40|ConvertFrom-Json)
        $plan.Assistive.ApprovedItemIds+=@([string]$item4.ItemId)
        $plan.Assistive.DiscoveryAuthority.Dispositions+=@([pscustomobject]@{ItemId=[string]$item4.ItemId;Selected=$true;Decision='Include';Reason='Explicitly reviewed control-only NonC observation fixture'})
        Assert-WsmAssistiveContract $plan MigrationPlan|Out-Null
        $planPath=Join-Path $Root 'sealed-plan.json';SaveJson $plan $planPath|Out-Null;$planHash=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $import=Import-WsmWizardApprovedPlan -Workspace $work -Role Target -Path $planPath -ExpectedHash $planHash
        Check ($import.Status -ceq 'ImportedVerified' -and $import.PairId -ceq $pair) 'Core target import did not durably receive the typed schema-3 plan.'

        $coverage=@([pscustomobject][ordered]@{Probe='FixtureComplete';Scope='Machine';SID='';View='All';Status='Success';EvidenceKind='FixtureObservation';Count=0;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind=$null;ItemId='';ObservedUtc=(Get-WsmUtc)})
        $targetInventory=New-WsmInventory $target 7 @()
        $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$target.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;InventoryRevision=7;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $targetInventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='isolated native observation fixture';AccountContext='System';CaptureHost='local fixture';PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=''}
        $software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software
        $targetInventory|Add-Member NoteProperty SoftwareCatalog $software -Force
        Assert-WsmSoftwareCatalog $software -SourceInventory $targetInventory|Out-Null
        function script:Get-WsmAssistiveCurrentSoftwareCatalog($Snapshot){$Snapshot.SoftwareCatalog}
        $inventoryDir=Join-Path (Join-Path (Join-Path $work ('hosts\'+$target.Fingerprint)) 'inventory') ''
        [void](New-WsmOutputOwnedDirectory $inventoryDir);$inventoryPath=Join-Path $inventoryDir 'inventory-7.json';SaveJson $targetInventory $inventoryPath|Out-Null;$inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $jobs=@([pscustomobject]@{status='Succeeded';action='Inventory';role='Target';workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash})})
        $comparison=[pscustomobject][ordered]@{Revision=9;SourceSnapshotHash=$sourceHash;TargetSnapshotHash=$inventoryHash;SelectionRevision=$selectionRevision;Rows=@();ManualPreparation=@();CreatedUtc=(Get-WsmUtc);VersionDisclaimer='Observed versions are facts, not compatibility proof.'}
        $handoff=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardTargetComparisonMaterial';PairId=$pair;PlanHash=$planHash;SourceSnapshotHash=$sourceHash;TargetSnapshotHash=$inventoryHash;SelectionRevision=$selectionRevision;ComparisonRevision=9;Comparison=$comparison;InformationalOnly=$true;CreatedUtc=(Get-WsmUtc)}
        $handoffPath=Join-Path $Root 'manager-comparison.json';SaveJson $handoff $handoffPath|Out-Null;$handoffHash=(Get-FileHash -LiteralPath $handoffPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $receivedComparison=Import-WsmWizardTargetComparison -Workspace $work -PairId $pair -Path $handoffPath -ExpectedHash $handoffHash -Jobs $jobs
        Check ($receivedComparison.Status -ceq 'Succeeded' -and $receivedComparison.TargetSnapshotHash -ceq $inventoryHash -and -not $receivedComparison.AuthoritativeApproval) 'Target comparison import lost current snapshot/hash bindings or claimed authority.'
        $stored=Get-WsmWizardTargetComparisonRecord $work $pair $planHash
        Check ($stored -and $stored.Comparison.Revision -eq 9 -and $stored.Document.SelectionRevision -eq $selectionRevision) 'Target did not retain the exact typed comparison in owned materials.'
        $jobs+=@([pscustomobject]@{action='ImportTargetComparison';status='Succeeded';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@($receivedComparison)})
        $badHashRejected=$false;try{Import-WsmWizardTargetComparison -Workspace $work -PairId $pair -Path $handoffPath -ExpectedHash ('0'*64) -Jobs $jobs|Out-Null}catch{$badHashRejected=$true}
        Check $badHashRejected 'Comparison import accepted a mismatched independent SHA-256.'
        $wrongPairRejected=$false;try{Import-WsmWizardTargetComparison -Workspace $work -PairId ([Guid]::NewGuid().ToString()) -Path $handoffPath -ExpectedHash $handoffHash -Jobs $jobs|Out-Null}catch{$wrongPairRejected=$true}
        Check $wrongPairRejected 'Comparison import accepted a cross-pair material.'

        # Build a real, non-final schema-3 package fixture from native C-volume
        # observations. The only injected observations remain local identity and
        # software-catalog collection; package validation and restore stay core.
        $packageRoot=Join-Path $Root 'sealed-package';[void][IO.Directory]::CreateDirectory($packageRoot);[void][IO.Directory]::CreateDirectory((Join-Path $packageRoot 'payload'))
        [IO.File]::Copy($planPath,(Join-Path $packageRoot 'plan.json'))
        $proof=Assert-WsmAssistiveSourceScope $fileSpec SourceCOnly -Native;$proof2=Assert-WsmAssistiveSourceScope $fileSpec2 SourceCOnly -Native;$proof3=Assert-WsmAssistiveSourceScope $fileSpec3 SourceCOnly -Native
        if($proof.Channel -cne 'C' -or $proof2.Channel -cne 'C' -or $proof3.Channel -cne 'C'){throw 'The isolated source fixtures must be on the native C volume.'}
        $rootMetadata=Get-WsmFileMetadata $scopeRoot 'DaclOwner';$fileMetadata=Get-WsmFileMetadata $sourceFile 'DaclOwner';$rootMetadata2=Get-WsmFileMetadata $scopeRoot2 'DaclOwner';$fileMetadata2=Get-WsmFileMetadata $sourceFile2 'DaclOwner';$rootMetadata3=Get-WsmFileMetadata $scopeRoot3 'DaclOwner';$fileMetadata3=Get-WsmFileMetadata $sourceFile3 'DaclOwner'
        $blob=Write-WsmPayloadFile $sourceFile (Join-Path $packageRoot 'payload') 65536 0 $null;$blob2=Write-WsmPayloadFile $sourceFile2 (Join-Path $packageRoot 'payload') 65536 0 $null;$blob3=Write-WsmPayloadFile $sourceFile3 (Join-Path $packageRoot 'payload') 65536 0 $null
        $records=@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;RelativePath='';Directory=$true;Metadata=$rootMetadata;Data=$null},[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;RelativePath='state.bin';Directory=$false;Metadata=$fileMetadata;Data=$blob},[pscustomobject][ordered]@{ItemId=[string]$item2.ItemId;RelativePath='';Directory=$true;Metadata=$rootMetadata2;Data=$null},[pscustomobject][ordered]@{ItemId=[string]$item2.ItemId;RelativePath='state.bin';Directory=$false;Metadata=$fileMetadata2;Data=$blob2},[pscustomobject][ordered]@{ItemId=[string]$item3.ItemId;RelativePath='';Directory=$true;Metadata=$rootMetadata3;Data=$null},[pscustomobject][ordered]@{ItemId=[string]$item3.ItemId;RelativePath='state.bin';Directory=$false;Metadata=$fileMetadata3;Data=$blob3})
        $indexPath=Join-Path $packageRoot 'artifacts.jsonl';$indexText=(@($records|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) -join "`n")+"`n";[IO.File]::WriteAllText($indexPath,$indexText,(New-Object Text.UTF8Encoding($false)));$indexHash=(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString();BatchId=$plan.BatchId;PairId=$pair;ApprovalId=$plan.ApprovalId;PlanHash=$planHash;Source=$plan.Source;Target=$plan.Target;InventoryRevision=1;DecisionRevision=4;Generation=1;BaseManifestHash='';Final=$false;FreezeHash='';ArtifactsHash=$indexHash;Files=3;Bytes=[long]($sourceBytes.Length+$sourceBytes2.Length+$sourceBytes3.Length);Records=6;ChunkBytes=65536;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot';SourceCollectionProofs=@([pscustomobject][ordered]@{ItemId=$item.ItemId;Channel=$proof.Channel;PhysicalPath=$proof.PhysicalPath;SourceCPhysicalRoot=$proof.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true},[pscustomobject][ordered]@{ItemId=$item2.ItemId;Channel=$proof2.Channel;PhysicalPath=$proof2.PhysicalPath;SourceCPhysicalRoot=$proof2.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true},[pscustomobject][ordered]@{ItemId=$item3.ItemId;Channel=$proof3.Channel;PhysicalPath=$proof3.PhysicalPath;SourceCPhysicalRoot=$proof3.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true})}
        $manifest.SourceCollectionProofs+=@([pscustomobject]@{ItemId=[string]$item4.ItemId;Channel='NonC';PhysicalPath='\Device\HarddiskVolumeWsmNonCObservation\wsm-r6-deferred-fixture';SourceCPhysicalRoot=[string]$proof.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true})
        $manifestPath=Join-Path $packageRoot 'manifest.json';SaveJson $manifest $manifestPath|Out-Null;$manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant();$validated=Test-WsmMigrationPackage $manifestPath $manifestHash
        Check ($validated.Valid -and $validated.Manifest.Generation -eq 1 -and $validated.PlanHash -ceq $planHash -and $validated.ManifestPath -ceq [IO.Path]::GetFullPath($manifestPath) -and $validated.Plan.Assistive.SourceSelectionsVersion -eq $selectionRevision) 'Core package validator rejected or changed the real schema-3 payload fixture or omitted its verified PlanHash/manifest path.'
        $delivery1=Export-WsmDirectoryDelivery -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $Root 'delivery-one')
        $delivery2=Export-WsmDirectoryDelivery -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $Root 'delivery-two')
        Reject {Import-WsmWizardTargetDirectoryPackage -Workspace $work -PairId $pair -SummaryPath $delivery1.SummaryPath -ExpectedSummaryHash ('0'*64) -SourceDirectory $delivery1.Directory -OperationId ([Guid]::NewGuid().ToString())} 'Target directory import trusted a summary whose bytes differ from the independently supplied expected hash.'
        $directoryCapacityOperationId=[Guid]::NewGuid().ToString();$directoryCapacityToken=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action DirectoryImport -Path $delivery1.SummaryPath -ExpectedHash $delivery1.SummarySHA256 -OperationId $directoryCapacityOperationId
        $script:originalDirectoryCapacityBytes=(Get-Command Get-WsmAvailableBytes -CommandType Function).ScriptBlock
        function script:Get-WsmAvailableBytes([string]$Path){[long]0}
        try{Reject {Import-WsmWizardTargetDirectoryPackage -Workspace $work -PairId $pair -SummaryPath $delivery1.SummaryPath -ExpectedSummaryHash $delivery1.SummarySHA256 -SourceDirectory $delivery1.Directory -OperationId $directoryCapacityOperationId -CancellationToken $directoryCapacityToken} 'Target directory import ignored insufficient target workspace capacity.'}
        finally{Set-Item -Path Function:\script:Get-WsmAvailableBytes -Value $script:originalDirectoryCapacityBytes;Remove-Variable originalDirectoryCapacityBytes -Scope Script -ErrorAction SilentlyContinue}
        $directoryCapacityAttemptRoot=Join-Path $work ('pairs\'+$pair+'\attempts\'+([Guid]$directoryCapacityOperationId).ToString('D'));$directoryCapacityStage=Join-Path (Join-Path (Join-Path $work 'workspace-control') 'directory-imports') (([Guid]$delivery1.DeliveryId).ToString('N')+'.partial')
        Check (-not [IO.Directory]::Exists($directoryCapacityAttemptRoot) -and -not [IO.Directory]::Exists($directoryCapacityStage)) 'Insufficient directory-import capacity created an attempt package directory or partial incoming delivery.'
        $directoryToken1=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action DirectoryImport -Path $delivery1.SummaryPath -ExpectedHash $delivery1.SummarySHA256 -OperationId ([Guid]::NewGuid().ToString())
        $targetImport1=Import-WsmWizardTargetDirectoryPackage -Workspace $work -PairId $pair -SummaryPath $delivery1.SummaryPath -ExpectedSummaryHash $delivery1.SummarySHA256 -SourceDirectory $delivery1.Directory -OperationId $directoryToken1.OperationId -CancellationToken $directoryToken1
        $directoryToken2=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action DirectoryImport -Path $delivery2.SummaryPath -ExpectedHash $delivery2.SummarySHA256 -OperationId ([Guid]::NewGuid().ToString())
        $targetImport2=Import-WsmWizardTargetDirectoryPackage -Workspace $work -PairId $pair -SummaryPath $delivery2.SummaryPath -ExpectedSummaryHash $delivery2.SummarySHA256 -SourceDirectory $delivery2.Directory -OperationId $directoryToken2.OperationId -CancellationToken $directoryToken2
        $directoryAttempt=Resolve-WsmOutputWorkspace -WorkRoot $work -Role Target -PairId $pair -PlanHash $planHash -AttemptId $directoryToken1.OperationId -AttemptMode Directory -AttemptVolumeBytes 0
        $directoryRecordPath=Join-Path $directoryAttempt.AttemptRoot 'attempt.json';$directoryRecordHash=(Get-FileHash -LiteralPath $directoryRecordPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Reject {Resolve-WsmOutputWorkspace -WorkRoot $work -Role Target -PairId $pair -PlanHash $planHash -AttemptId $directoryToken1.OperationId -AttemptMode Zip} 'An existing Directory attempt changed format on reentry.'
        Check ((Get-FileHash -LiteralPath $directoryRecordPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $directoryRecordHash -and (Get-FileHash -LiteralPath (Join-Path (Join-Path $work 'workspace-control') 'output-profile.json') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $initialProfileHash -and $directoryAttempt.AttemptProfile.Mode -ceq 'Directory' -and [long]$directoryAttempt.AttemptProfile.VolumeBytes -eq 0) 'Directory delivery changed the default ZIP profile or failed to freeze its per-attempt mode.'
        $invalidZipAttemptId=[Guid]::NewGuid().ToString('D');$invalidZipAttemptPath=Join-Path (Join-Path $work ('pairs\'+$pair+'\attempts')) $invalidZipAttemptId
        Reject {Resolve-WsmOutputWorkspace -WorkRoot $work -Role Target -PairId $pair -PlanHash $planHash -AttemptId $invalidZipAttemptId -AttemptMode Zip -AttemptVolumeBytes 133169152} 'A ZIP attempt accepted a volume limit below the supported 128 MiB minimum.'
        Check (-not [IO.Directory]::Exists($invalidZipAttemptPath)) 'Invalid per-attempt ZIP volume settings left a durable attempt directory.'
        $invalidDirectoryAttemptId=[Guid]::NewGuid().ToString('D');$invalidDirectoryAttemptPath=Join-Path (Join-Path $work ('pairs\'+$pair+'\attempts')) $invalidDirectoryAttemptId
        Reject {Resolve-WsmOutputWorkspace -WorkRoot $work -Role Target -PairId $pair -PlanHash $planHash -AttemptId $invalidDirectoryAttemptId -AttemptMode Directory -AttemptVolumeBytes 1} 'A Directory attempt accepted a nonzero ZIP volume limit.'
        Check (-not [IO.Directory]::Exists($invalidDirectoryAttemptPath)) 'Invalid per-attempt Directory settings left a durable attempt directory.'
        $zipExport=Export-WsmPackageZip -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $Root 'zip-transport') -VolumeBytes 1048576
        Check ($zipExport.Volumes -ge 2) 'The ZIP fixture did not produce multiple independently verified transport volumes.'
        $zipTransportHash=[string]$zipExport.SHA256
        $zipStateRoot=Join-Path (Join-Path $work 'workspace-control') 'wizard-package-imports'

        # A receiver-supplied expected hash is a separate trust input. Rehashing
        # a forged descriptor must not make its altered plan binding acceptable.
        Reject {Import-WsmWizardTargetZipPackage -Workspace $work -PairId $pair -TransportPath $zipExport.Path -ExpectedHash ('0'*64) -OperationId ([Guid]::NewGuid().ToString())} 'Target ZIP import accepted a transport whose bytes differ from the separately supplied expected hash.'
        $forgedTransport=Read-WsmTrustedJson $zipExport.Path $zipTransportHash;$forgedTransport.PlanHash=('f'*64)
        $forgedTransportPath=Join-Path $Root 'forged-self-hash-transport.json';SaveJson $forgedTransport $forgedTransportPath|Out-Null;$forgedTransportHash=(Get-FileHash -LiteralPath $forgedTransportPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Reject {Import-WsmWizardTargetZipPackage -Workspace $work -PairId $pair -TransportPath $forgedTransportPath -ExpectedHash $forgedTransportHash -OperationId ([Guid]::NewGuid().ToString())} 'A self-hashed forged ZIP descriptor replaced the current target-bound approved plan.'
        $incomingRoot=Join-Path $zipStateRoot ('incoming-'+$forgedTransport.PackageId)
        Check (-not [IO.Directory]::Exists($incomingRoot)) 'Rejected self-hash transport created an incoming package before plan binding passed.'

        # Missing, cross-volume mixed, and truncated members fail preflight before
        # an incoming package is published. The canonical trusted transport stays
        # unchanged; each fixture copy retains its independently known descriptor hash.
        $zipDocument=Read-WsmTrustedJson $zipExport.Path $zipTransportHash
        function CopyZipFixture([string]$Destination,[int]$SkipVolume=-1){
            [void][IO.Directory]::CreateDirectory($Destination)
            [IO.File]::Copy($zipExport.Path,(Join-Path $Destination 'transport.json'))
            for($volumeIndex=0;$volumeIndex -lt $zipDocument.Volumes.Count;$volumeIndex++){
                if($SkipVolume -ge 0 -and $volumeIndex -eq $SkipVolume){continue}
                $volume=$zipDocument.Volumes[$volumeIndex];[IO.File]::Copy((Join-Path (Split-Path -Parent $zipExport.Path) $volume.Name),(Join-Path $Destination $volume.Name))
            }
            Join-Path $Destination 'transport.json'
        }
        $missingTransportPath=CopyZipFixture (Join-Path $Root 'zip-missing-volume') ($zipDocument.Volumes.Count-1)
        $missingToken=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action ImportPackageZip -Path $missingTransportPath -ExpectedHash $zipTransportHash -OperationId ([Guid]::NewGuid().ToString())
        Reject {Import-WsmWizardTargetZipPackage -Workspace $work -PairId $pair -TransportPath $missingTransportPath -ExpectedHash $zipTransportHash -OperationId $missingToken.OperationId -CancellationToken $missingToken} 'Target ZIP import accepted a missing transport volume.'
        $mixedTransportPath=CopyZipFixture (Join-Path $Root 'zip-mixed-volumes')
        $mixedDirectory=Split-Path -Parent $mixedTransportPath;$firstVolume=$zipDocument.Volumes[0];$lastVolume=$zipDocument.Volumes[$zipDocument.Volumes.Count-1]
        $firstPath=Join-Path $mixedDirectory $firstVolume.Name;$lastPath=Join-Path $mixedDirectory $lastVolume.Name;$swapPath=Join-Path $mixedDirectory 'volume-swap.tmp'
        [IO.File]::Move($firstPath,$swapPath);[IO.File]::Move($lastPath,$firstPath);[IO.File]::Move($swapPath,$lastPath)
        $mixedToken=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action ImportPackageZip -Path $mixedTransportPath -ExpectedHash $zipTransportHash -OperationId ([Guid]::NewGuid().ToString())
        Reject {Import-WsmWizardTargetZipPackage -Workspace $work -PairId $pair -TransportPath $mixedTransportPath -ExpectedHash $zipTransportHash -OperationId $mixedToken.OperationId -CancellationToken $mixedToken} 'Target ZIP import accepted volumes mixed across distinct volume contents.'
        $truncatedTransportPath=CopyZipFixture (Join-Path $Root 'zip-truncated-volumes')
        $truncatedDirectory=Split-Path -Parent $truncatedTransportPath;$truncatedVolume=Join-Path $truncatedDirectory $lastVolume.Name;$truncateStream=[IO.File]::Open($truncatedVolume,'Open','Write','None');try{$truncateStream.SetLength([Math]::Max(0,$truncateStream.Length-64))}finally{$truncateStream.Dispose()}
        $truncatedToken=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action ImportPackageZip -Path $truncatedTransportPath -ExpectedHash $zipTransportHash -OperationId ([Guid]::NewGuid().ToString())
        Reject {Import-WsmWizardTargetZipPackage -Workspace $work -PairId $pair -TransportPath $truncatedTransportPath -ExpectedHash $zipTransportHash -OperationId $truncatedToken.OperationId -CancellationToken $truncatedToken} 'Target ZIP import accepted a truncated transport volume.'
        Check (-not [IO.Directory]::Exists($incomingRoot)) 'Invalid ZIP volume fixtures left a package marked as imported.'

        # Capacity is a real core gate; substitute only the disk-free-space
        # observation to exercise the insufficient-space branch without filling
        # the developer's filesystem.
        $capacityToken=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action ImportPackageZip -Path $zipExport.Path -ExpectedHash $zipTransportHash -OperationId ([Guid]::NewGuid().ToString())
        $script:originalAvailableBytes=(Get-Command Get-WsmAvailableBytes -CommandType Function).ScriptBlock
        function script:Get-WsmAvailableBytes([string]$Path){[long]0}
        try{Reject {Import-WsmWizardTargetZipPackage -Workspace $work -PairId $pair -TransportPath $zipExport.Path -ExpectedHash $zipTransportHash -OperationId $capacityToken.OperationId -CancellationToken $capacityToken} 'Target ZIP import ignored insufficient target workspace capacity.'}
        finally{Set-Item -Path Function:\script:Get-WsmAvailableBytes -Value $script:originalAvailableBytes;Remove-Variable originalAvailableBytes -Scope Script -ErrorAction SilentlyContinue}
        Check (-not [IO.Directory]::Exists($incomingRoot)) 'Insufficient-capacity rejection created an incoming package before preflight completed.'

        # Deterministically request a real durable cancellation after ZIP extraction
        # has written a partial member, then use a fresh operation ID to resume the
        # exact transport into the same target incoming root.
        $zipCancelOperationId=[Guid]::NewGuid().ToString();$zipCancelToken=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action ImportPackageZip -Path $zipExport.Path -ExpectedHash $zipTransportHash -OperationId $zipCancelOperationId
        $script:zipExtractBoundaries=0;$script:zipCancelToken=$zipCancelToken;$script:originalZipBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock
        function script:Assert-WsmCancellationBoundary($Token,[string]$Phase){
            if($Phase -ceq 'ZipExtractBuffer'){$script:zipExtractBoundaries++;if($script:zipExtractBoundaries -eq 2){Request-WsmCancellation -Token $script:zipCancelToken -Owner 'Target operator' -Evidence 'Stop after verified ZIP extraction has written a partial member'|Out-Null}}
            & $script:originalZipBoundary $Token $Phase
        }
        $zipImportInterrupted=$false
        try{Import-WsmWizardTargetZipPackage -Workspace $work -PairId $pair -TransportPath $zipExport.Path -ExpectedHash $zipTransportHash -OperationId $zipCancelOperationId -CancellationToken $zipCancelToken|Out-Null}catch{$zipImportInterrupted=$true}
        Set-Item -Path Function:\script:Assert-WsmCancellationBoundary -Value $script:originalZipBoundary
        $incomingRoot=Join-Path $zipStateRoot ('incoming-'+$zipDocument.PackageId);$partialMembers=@();if([IO.Directory]::Exists($incomingRoot)){$partialMembers=@(Get-ChildItem -LiteralPath $incomingRoot -File -Filter '*.partial' -Recurse|Where-Object Length -GT 0)}
        if(-not $zipImportInterrupted -or $script:zipExtractBoundaries -lt 2 -or -not $partialMembers.Count){throw 'ZIP cancellation did not interrupt a real non-empty partial member at an extraction boundary.'}
        $zipResumeToken=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action ImportPackageZip -Path $zipExport.Path -ExpectedHash $zipTransportHash -OperationId ([Guid]::NewGuid().ToString())
        $zipImport=Import-WsmWizardTargetZipPackage -Workspace $work -PairId $pair -TransportPath $zipExport.Path -ExpectedHash $zipTransportHash -OperationId $zipResumeToken.OperationId -CancellationToken $zipResumeToken
        $zipAttempt=Resolve-WsmOutputWorkspace -WorkRoot $work -Role Target -PairId $pair -PlanHash $planHash -AttemptId $zipResumeToken.OperationId -AttemptMode Zip
        $zipAttemptRecordPath=Join-Path $zipAttempt.AttemptRoot 'attempt.json';$zipAttemptRecordHash=(Get-FileHash -LiteralPath $zipAttemptRecordPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Reject {Resolve-WsmOutputWorkspace -WorkRoot $work -Role Target -PairId $pair -PlanHash $planHash -AttemptId $zipResumeToken.OperationId -AttemptMode Zip -AttemptVolumeBytes 134217728} 'A ZIP attempt changed its sealed volume limit on reentry.'
        Check ($zipAttempt.AttemptProfile.Mode -ceq 'Zip' -and [long]$zipAttempt.AttemptProfile.VolumeBytes -eq 536870912 -and (Get-FileHash -LiteralPath $zipAttemptRecordPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $zipAttemptRecordHash -and (Get-FileHash -LiteralPath (Join-Path (Join-Path $work 'workspace-control') 'output-profile.json') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $initialProfileHash) 'Validated ZIP import did not select a frozen ZIP attempt or changed the Target profile.'
        $directoryPreferenceWork=Join-Path $Root 'target-directory-preference';$directoryPreferenceEnrollment=Initialize-WsmOutputWorkspace -WorkRoot $directoryPreferenceWork -Role Target -Mode Directory
        $directoryPreferenceProfileHash=(Get-FileHash -LiteralPath (Join-Path (Join-Path $directoryPreferenceWork 'workspace-control') 'output-profile.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        $zipIntoDirectoryPreference=Resolve-WsmOutputWorkspace -WorkRoot $directoryPreferenceWork -Role Target -PairId $pair -PlanHash $planHash -AttemptId $zipResumeToken.OperationId -AttemptMode Zip
        Check ($directoryPreferenceEnrollment.Profile.Mode -ceq 'Directory' -and $zipIntoDirectoryPreference.AttemptProfile.Mode -ceq 'Zip' -and [long]$zipIntoDirectoryPreference.AttemptProfile.VolumeBytes -eq 536870912 -and (Get-FileHash -LiteralPath (Join-Path (Join-Path $directoryPreferenceWork 'workspace-control') 'output-profile.json') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $directoryPreferenceProfileHash) 'A validated ZIP delivery could not select a frozen ZIP attempt under an unchanged Target Directory preference.'
        Set-Item -Path Function:\script:Assert-WsmCancellationBoundary -Value $script:originalZipBoundary
        Remove-Variable zipExtractBoundaries,zipCancelToken,originalZipBoundary -Scope Script -ErrorAction SilentlyContinue
        $zipStateRoot=Join-Path (Join-Path $work 'workspace-control') 'wizard-package-imports'
        Check ($zipResumeToken.StateDirectory -ceq [IO.Path]::GetFullPath($zipStateRoot) -and [IO.Directory]::Exists($zipStateRoot) -and $directoryToken1.StateDirectory -ceq [IO.Path]::GetFullPath($work) -and @(Get-ChildItem -LiteralPath $incomingRoot -File -Filter '*.partial' -Recurse).Count -eq 0) 'Target import cancellation tokens were not bound to the wrapper-owned protected roots or re-entry left partial ZIP members.'
        Check ($zipImport.Status -ceq 'Succeeded' -and $zipImport.Valid -and $zipImport.PairId -ceq $pair -and $zipImport.PlanHash -ceq $planHash -and $zipImport.ManifestHash -ceq $manifestHash -and $zipImport.Generation -eq 1) 'Wizard ZIP package importer did not return exact verified delivery bindings.'
        Check ($targetImport1.Status -ceq 'Succeeded' -and $targetImport1.PairId -ceq $pair -and $targetImport1.PlanHash -ceq $planHash -and $targetImport1.ManifestHash -ceq $manifestHash -and $targetImport1.Generation -eq 1) 'Wizard directory package importer did not return exact verified delivery bindings.'
        $zipPackageJob=[pscustomobject]@{status='Succeeded';action='ImportPackageZip';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$zipImport.ManifestPath;SHA256=$zipImport.ManifestHash;ManifestHash=$zipImport.ManifestHash;PairId=$zipImport.PairId;PlanHash=$zipImport.PlanHash;Generation=$zipImport.Generation;AttemptId='zip-fixture-attempt'})}
        $packageJobs=@(
            [pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$targetImport1.ManifestPath;ManifestHash=$targetImport1.ManifestHash;PairId=$pair;PlanHash=$planHash;Generation=$targetImport1.Generation;AttemptId=$targetImport1.AttemptId})},
            [pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$targetImport2.ManifestPath;ManifestHash=$targetImport2.ManifestHash;PairId=$pair;PlanHash=$planHash;Generation=$targetImport2.Generation;AttemptId=$targetImport2.AttemptId})}
        )
        $zipResolved=Get-WsmWizardTargetPackage $work $pair (Assert-WsmWizardTargetRole $work $pair) (@($jobs)+@($zipPackageJob))
        Check ($zipResolved.Action -ceq 'ImportPackageZip' -and $zipResolved.ManifestHash -ceq $manifestHash) 'Target did not consume the verified package from a successful ZIP import job.'
        $allJobs=@($jobs)+@($packageJobs)+@($zipPackageJob)
        $samePackage=Get-WsmWizardTargetPackage $work $pair (Assert-WsmWizardTargetRole $work $pair) $allJobs
        Check ($samePackage.ManifestHash -ceq $manifestHash -and $samePackage.Package.Manifest.Generation -eq 1) 'Repeated exact package delivery was not deduplicated by sealed manifest identity.'
        Reject {Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Target operator' -Reason 'Attempt to select an item outside this sealed plan' -SelectedItemIds @([Guid]::NewGuid().ToString()) -Jobs $allJobs} 'Target decision receipt accepted an item outside the exact sealed-plan include set.'
        $restoreReceipt=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision WaitForInstall -Owner 'Target operator' -Reason 'Wait for owner-managed workload preparation' -SelectedItemIds @($item.ItemId) -Jobs $allJobs
        Check (@($restoreReceipt.SelectedItemIds).Count -eq 1 -and [string]$restoreReceipt.SelectedItemIds[0] -ceq [string]$item.ItemId) 'Target decision receipt did not preserve the exact allowed subset chosen by the Target owner.'
        Check ($restoreReceipt.Decision -ceq 'WaitForInstall' -and (Assert-WsmAssistiveContract (Read-WsmTrustedJson $restoreReceipt.ReceiptPath $restoreReceipt.ReceiptHash) TargetDecisionReceipt)) 'Target did not persist a core-validated deferred receipt with exact package bindings.'
        $deferredPreview=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        Check (@($deferredPreview.SelectedItemIds).Count -eq 1 -and [string]$deferredPreview.SelectedItemIds[0] -ceq [string]$item.ItemId) 'Target restore preview widened a valid receipt subset to the whole package.'
        $deferred=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $deferredPreview.PreviewHash -Jobs $allJobs
        Check ($deferred.Status -ceq 'DeferredSoftware' -and $deferred.NoTargetWrites -and -not [IO.Directory]::Exists($targetRoot)) 'WaitForInstall performed a Target write or failed to expose deferred resume.'
        Check (-not (Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile $allJobs)) 'Deferred WaitForInstall was projected as a completed restore result.'
        $restoreReceipt=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Target operator' -Reason 'Explicitly authorize the reviewed isolated file restore and leave the existing conflict untouched' -SelectedItemIds @($item.ItemId,$item2.ItemId) -Jobs $allJobs
        $preview=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        $readyRow=@($preview.Rows|Where-Object ItemId -CEQ $item.ItemId)[0];$conflictRow=@($preview.Rows|Where-Object ItemId -CEQ $item2.ItemId)[0]
        Check ($preview.Status -ceq 'Previewed' -and $preview.CanRestoreIndependentItems -and $preview.SelectedItemIds.Count -eq 2 -and $readyRow.Status -ceq 'Ready' -and $conflictRow.Status -eq 'Ready' -and $conflictRow.Action -ceq 'MergeIntoExistingDirectory' -and $preview.PreviewHash -match '^[a-f0-9]{64}$') ('Actual core restore preview did not expose both selected merged-directory items and the bound preview hash: '+($preview.Rows|ConvertTo-Json -Depth 20 -Compress))
        $nonCHandoffRoot=Join-Path (Get-WsmWizardTargetMaterialRoot $work $pair) 'nonc-handoffs';[void](New-WsmOutputOwnedDirectory $nonCHandoffRoot)
        $badNonCPointer=Join-Path $nonCHandoffRoot 'active-receipt.json';Write-WsmJson $badNonCPointer ([pscustomobject]@{Kind='CorruptNonCTestFixture'})
        $cOnlyPreview=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        Check ($cOnlyPreview.PreviewHash -ceq $preview.PreviewHash -and $cOnlyPreview.CanRestoreIndependentItems -and -not $cOnlyPreview.NonCEvidenceIssue) 'Unrelated corrupt NonC materials blocked or changed an exact C-only decision.'
        [void](Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Target operator' -Reason 'Review independent C with deferred NonC' -SelectedItemIds @($item.ItemId,$item4.ItemId) -Jobs $allJobs)
        $mixedInvalid=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        Check ($mixedInvalid.CanRestoreIndependentItems -and $mixedInvalid.NonCEvidenceIssue -match '^CurrentNonCMaterialsInvalid' -and @($mixedInvalid.Rows|Where-Object {$_.ItemId -ceq $item.ItemId -and $_.Status -ceq 'Ready'}).Count -eq 1 -and @($mixedInvalid.Rows|Where-Object {$_.ItemId -ceq $item4.ItemId -and $_.Action -ceq 'DeferredNonC'}).Count -eq 1) 'Invalid NonC evidence blocked an independent C row or lost its explicit deferred issue.'
        [IO.File]::Delete($badNonCPointer)
        $mixedMissing=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        Check ($mixedMissing.PreviewHash -cne $mixedInvalid.PreviewHash -and -not $mixedMissing.NonCEvidenceIssue) 'Changing invalid NonC evidence to absent did not invalidate the reviewed preview hash.'
        Reject {Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $mixedInvalid.PreviewHash -Jobs $allJobs} 'Restore reused a preview after the exact NonC evidence issue changed.'
        $restoreReceipt=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Target operator' -Reason 'Explicitly return to the reviewed C-only restore' -SelectedItemIds @($item.ItemId,$item2.ItemId) -Jobs $allJobs
        $preview=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        Reject {Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ('0'*64) -Jobs $allJobs} 'Restore accepted a stale/forged PreviewHash.'
        $restoreStateDirectory=Join-Path $work 'pairs';[void][IO.Directory]::CreateDirectory($restoreStateDirectory)
        $cancelOperationId=[Guid]::NewGuid().ToString();$cancelToken=New-WsmCancellationToken -PairId $pair -PlanHash $preview.PlanHash -ManifestHash $preview.ManifestHash -OperationId $cancelOperationId -StateDirectory $restoreStateDirectory
        Request-WsmCancellation -Token $cancelToken -Owner 'Target operator' -Evidence 'Cancel before the first approved item boundary' | Out-Null
        $cancelled=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $preview.PreviewHash -Jobs $allJobs -CancellationToken $cancelToken
        $cancelPaths=Get-WsmOperationPaths $restoreStateDirectory $pair;$cancelState=Get-WsmOperationState $cancelPaths $validated;$cancelJournal=Test-WsmJournal $restoreStateDirectory $pair;$cancelRegistry=Get-WsmAssistiveResourceRegistry $restoreStateDirectory
        Check ($cancelled.Status -ceq 'Cancelled' -and $cancelled.AttemptOperationId -ceq $cancelOperationId -and -not [IO.Directory]::Exists($targetRoot) -and @($cancelled.PendingOperations).Count -eq 0 -and $cancelJournal.Consistent -and @($cancelRegistry.LiveJobs).Count -eq 0) 'Pre-cancelled Target restore did not stop before writes and durably close its worker while retaining a consistent journal.'
        $cancelReplay=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $preview.PreviewHash -Jobs $allJobs
        Check ($cancelReplay.Replay -and $cancelReplay.Status -ceq 'Cancelled' -and $cancelReplay.AttemptOperationId -ceq $cancelOperationId -and $cancelReplay.JournalHash -ceq $cancelled.JournalHash) 'Cancelled attempt retry created a duplicate attempt or changed its journal.'
        $cancelResultJob=[pscustomobject]@{action='TargetRestore';status='Cancelled';role='Target';pairId=$pair;workspace=$work;jobId=$cancelOperationId;outputs=@($cancelled)}
        $cancelAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($cancelResultJob))
        Check ($cancelAvailability -and $cancelAvailability.status -ceq 'Cancelled' -and $cancelAvailability.attemptId -ceq $cancelOperationId -and $cancelAvailability.appliedCount -eq 0) 'A cancelled restore lost its durable result or was projected as an applied restore.'
        $wrongTargetProfile=(Assert-WsmWizardTargetRole $work $pair).Profile|ConvertTo-Json -Depth 20|ConvertFrom-Json;$wrongTargetProfile.Fingerprint=('0'*64)
        Check (-not (Get-WsmWizardTargetRestoreAvailability $work $pair $wrongTargetProfile (@($allJobs)+@($cancelResultJob)))) 'Restore availability accepted a caller profile with a mismatched Target fingerprint.'
        $cancelWizard=Get-WsmWizardProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($cancelResultJob))
        Check ($cancelWizard.nextStep -ceq 'result' -and -not @($cancelWizard.actions|Where-Object {$_.action -in @('TargetValidation','TargetAcceptance') -and $_.available}).Count -and @($cancelWizard.actions|Where-Object {$_.action -ceq 'CreateTargetDecisionReceipt' -and $_.available}).Count -eq 1) 'Cancelled restore did not lead to its result and explicit new-decision route, or unlocked successful validation/acceptance.'
        $restoreReceipt=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Target operator' -Reason 'Exercise cancellation after one selected FileScope item is fully committed' -SelectedItemIds @($item.ItemId,$item3.ItemId) -Jobs $allJobs
        $midPreview=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        $midOperationId=[Guid]::NewGuid().ToString();$midCancelToken=New-WsmCancellationToken -PairId $pair -PlanHash $midPreview.PlanHash -ManifestHash $midPreview.ManifestHash -OperationId $midOperationId -StateDirectory $restoreStateDirectory
        $script:originalRestoreJournal=(Get-Command Add-WsmJournal -CommandType Function).ScriptBlock;$script:midRestoreItemCalls=0;$script:midRestoreCancellationToken=$midCancelToken
        function script:Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){& $script:originalRestoreJournal $Paths $State $Action $ItemId $Detail;if($Action -ceq 'AssistiveItemCompleted' -and $script:midRestoreItemCalls -eq 0){$script:midRestoreItemCalls++;Request-WsmCancellation -Token $script:midRestoreCancellationToken -Owner 'Target operator' -Evidence 'Cancel after the first selected FileScope item and reservation evidence have been durably journaled'|Out-Null}}
        try{$midCancelled=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $midPreview.PreviewHash -Jobs $allJobs -CancellationToken $midCancelToken;$midRestoreCallsCompleted=[int]$script:midRestoreItemCalls}
        finally{Set-Item -Path Function:\script:Add-WsmJournal -Value $script:originalRestoreJournal;Remove-Variable originalRestoreJournal,midRestoreItemCalls,midRestoreCancellationToken -Scope Script -ErrorAction SilentlyContinue}
        $midPaths=Get-WsmOperationPaths $restoreStateDirectory $pair;$midState=Get-WsmOperationState $midPaths $validated;$midJournal=Test-WsmJournal $restoreStateDirectory $pair;$midPending=@($midState.PendingOperations)
        $midWrittenFile=Join-Path $targetRoot 'state.bin';$midWrittenHash=(Get-FileHash -LiteralPath $midWrittenFile -Algorithm SHA256).Hash.ToLowerInvariant();$midWrittenMetadata=Get-WsmFileMetadata $midWrittenFile 'DaclOwner'
        $midWrittenCreationTicks=(Get-Item -LiteralPath $midWrittenFile).CreationTimeUtc.Ticks
        Check ($midRestoreCallsCompleted -eq 1 -and $midCancelled.Status -ceq 'Cancelled' -and $midCancelled.AttemptOperationId -ceq $midOperationId -and $midState.Stage -ceq 'Cancelled' -and $midPending.Count -eq 0 -and $midJournal.Consistent -and $midWrittenHash -ceq $blob.Hash.ToLowerInvariant() -and -not [IO.File]::Exists((Join-Path $targetRoot3 'state.bin')) -and @(Get-ChildItem -LiteralPath $targetRoot3 -File -Filter '*.partial' -ErrorAction SilentlyContinue).Count -eq 0) 'Real owner cancellation after a complete FileScope payload write did not preserve that completed item and withhold the next selected item.'
        Check (@($midCancelled.ItemResults|Where-Object ItemId -CEQ $item.ItemId|Where-Object Status -CEQ 'Succeeded').Count -eq 1 -and @($midCancelled.ItemResults|Where-Object ItemId -CEQ $item3.ItemId).Count -eq 0) 'Cancellation did not preserve the earlier successful item while withholding the interrupted next item.'
        $midResultJob=[pscustomobject]@{action='TargetRestore';status='Cancelled';role='Target';pairId=$pair;workspace=$work;jobId=$midOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($midCancelled)}
        $midAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($midResultJob))
        Check ($midAvailability -and $midAvailability.status -ceq 'Cancelled' -and $midAvailability.attemptId -ceq $midOperationId -and $midAvailability.appliedCount -eq 1 -and $midAvailability.failedCount -eq 0) 'Cancellation after the first completed item hid its applied result or projected the cancelled attempt as wholly successful.'
        Repair-WsmOperation -ManifestPath $manifestPath -ExpectedHash $manifestHash -StateDirectory $restoreStateDirectory -Confirm:$false|Out-Null
        $repairedMidState=Get-WsmOperationState $midPaths $validated;$repairedMidJournal=Test-WsmJournal $restoreStateDirectory $pair
        Check ($repairedMidState.Stage -ceq 'Cancelled' -and @($repairedMidState.PendingOperations).Count -eq 0 -and $repairedMidJournal.Consistent -and (Get-FileHash -LiteralPath $midWrittenFile -Algorithm SHA256).Hash -ieq $midWrittenHash -and -not [IO.File]::Exists((Join-Path $targetRoot3 'state.bin')) -and @(Get-ChildItem -LiteralPath $targetRoot3 -File -Filter '*.partial' -ErrorAction SilentlyContinue).Count -eq 0) 'Repair did not preserve the completed item and leave the unstarted next selected payload absent.'
        $midReplay=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $midPreview.PreviewHash -Jobs $allJobs
        Check ($midReplay.Replay -and $midReplay.Status -ceq 'Cancelled' -and $midReplay.AttemptOperationId -ceq $midOperationId -and (Get-FileHash -LiteralPath $midWrittenFile -Algorithm SHA256).Hash -ieq $midWrittenHash -and (Get-WsmFileMetadata $midWrittenFile 'DaclOwner').LastWriteUtc -ceq $midWrittenMetadata.LastWriteUtc -and (Get-Item -LiteralPath $midWrittenFile).CreationTimeUtc.Ticks -eq $midWrittenCreationTicks -and @($midReplay.ItemResults|Where-Object ItemId -CEQ $item.ItemId|Where-Object Status -CEQ 'Succeeded').Count -eq 1) 'Repaired cancellation replay changed its attempt or repeated the prior successful payload write.'
        # Cancel inside the genuine second-item payload writer, after one real
        # chunk was flushed, with the first item already durably completed.
        $chunkReceipt=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Target operator' -Reason 'Explicitly exercise second-item partial payload cancellation' -SelectedItemIds @($item.ItemId,$item3.ItemId) -Jobs $allJobs
        $chunkPreview=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        $chunkOperationId=[Guid]::NewGuid().ToString();$chunkToken=New-WsmCancellationToken -PairId $pair -PlanHash $chunkPreview.PlanHash -ManifestHash $chunkPreview.ManifestHash -OperationId $chunkOperationId -StateDirectory $restoreStateDirectory
        $script:chunkOriginalJournal=(Get-Command Add-WsmJournal).ScriptBlock;$script:chunkOriginalBoundary=(Get-Command Assert-WsmCancellationBoundary).ScriptBlock
        $script:chunkFirstCompleted=$false;$script:chunkObservedBytes=0L;$script:chunkToken=$chunkToken;$script:chunkTargetRoot=$targetRoot3
        function script:Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){& $script:chunkOriginalJournal $Paths $State $Action $ItemId $Detail;if($Action -ceq 'AssistiveItemCompleted'){$script:chunkFirstCompleted=$true}}
        function script:Assert-WsmCancellationBoundary($Token,[string]$Boundary){
            if($script:chunkFirstCompleted -and $Boundary -ceq 'PayloadChunkRestored' -and $script:chunkObservedBytes -eq 0){
                $partial=@(Get-ChildItem -LiteralPath $script:chunkTargetRoot -File -Filter '*.partial');if($partial.Count -ne 1){throw 'Expected one actual in-flight native partial payload.'};$script:chunkObservedBytes=[long]$partial[0].Length
                Request-WsmCancellation -Token $script:chunkToken -Owner 'Target operator' -Evidence 'Stop after a flushed real chunk of the next payload'|Out-Null
            }
            & $script:chunkOriginalBoundary $Token $Boundary
        }
        try{$chunkCancelled=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $chunkPreview.PreviewHash -Jobs $allJobs -CancellationToken $chunkToken;$observedPartialBytes=$script:chunkObservedBytes}
        finally{Set-Item Function:\script:Add-WsmJournal $script:chunkOriginalJournal;Set-Item Function:\script:Assert-WsmCancellationBoundary $script:chunkOriginalBoundary;Remove-Variable chunkOriginalJournal,chunkOriginalBoundary,chunkFirstCompleted,chunkObservedBytes,chunkToken,chunkTargetRoot -Scope Script -ErrorAction SilentlyContinue}
        Check ($observedPartialBytes -gt 0 -and $observedPartialBytes -lt $sourceBytes3.Length -and $chunkCancelled.Status -ceq 'Cancelled' -and @($chunkCancelled.ItemResults|Where-Object ItemId -CEQ $item.ItemId|Where-Object Status -CEQ Succeeded).Count -eq 1 -and -not [IO.File]::Exists((Join-Path $targetRoot3 'state.bin')) -and @(Get-ChildItem -LiteralPath $targetRoot3 -File -Filter '*.partial').Count -eq 0) 'Actual partial payload cancellation lost the completed item or published/retained an incomplete payload.'
        Repair-WsmOperation -ManifestPath $manifestPath -ExpectedHash $manifestHash -StateDirectory $restoreStateDirectory -Confirm:$false|Out-Null
        $chunkRepairedState=Get-WsmOperationState $midPaths $validated
        Check ($chunkRepairedState.Stage -ceq 'Cancelled' -and @($chunkRepairedState.PendingOperations).Count -eq 0 -and (Test-WsmJournal $restoreStateDirectory $pair).Consistent -and (Get-FileHash -LiteralPath $midWrittenFile -Algorithm SHA256).Hash -ieq $midWrittenHash -and -not [IO.File]::Exists((Join-Path $targetRoot3 'state.bin'))) 'Explicit repair after partial cancellation changed the completed item or started the next payload.'
        $restoreReceipt=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Target operator' -Reason 'After reviewing the cancelled attempt, explicitly authorize a new restore attempt' -SelectedItemIds @($item.ItemId,$item3.ItemId,$item2.ItemId) -Jobs $allJobs
        $preview=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        $restored=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $preview.PreviewHash -Jobs $allJobs
        $targetFile=Join-Path $targetRoot 'state.bin';$actualHash=(Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash.ToLowerInvariant();$actualMetadata=Get-WsmFileMetadata $targetFile 'DaclOwner';$actualCreationTicks=(Get-Item -LiteralPath $targetFile).CreationTimeUtc.Ticks
        $firstItemResult=@($restored.ItemResults|Where-Object ItemId -CEQ $item.ItemId)[0];$secondItemResult=@($restored.ItemResults|Where-Object ItemId -CEQ $item2.ItemId)[0];$thirdItemResult=@($restored.ItemResults|Where-Object ItemId -CEQ $item3.ItemId)[0]
        Check ($restored.Stage -ceq 'Partial' -and $restored.AttemptOperationId -cne $midOperationId -and $restoreReceipt.Decision -ceq 'RestoreNow' -and $restored.JournalHash -match '^[a-f0-9]{64}$' -and $firstItemResult.Status -ceq 'Succeeded' -and $firstItemResult.AppliedManifestHash -ceq $manifestHash -and [long]$firstItemResult.AppliedGeneration -eq 1 -and $secondItemResult.Status -ceq 'BlockedConflict' -and $thirdItemResult.Status -ceq 'Succeeded' -and $actualHash -ceq $blob.Hash.ToLowerInvariant() -and (Get-FileHash -LiteralPath (Join-Path $targetRoot3 'state.bin') -Algorithm SHA256).Hash -ieq $blob3.Hash) 'A new explicit restore decision did not create a distinct durable attempt that resumed exact items while preserving the existing conflict.'
        Check ($actualMetadata.Sddl -ceq $fileMetadata.Sddl -and [int]$actualMetadata.Attributes -eq [int]$fileMetadata.Attributes -and [DateTimeOffset]::Parse($actualMetadata.LastWriteUtc).UtcDateTime.Ticks -eq [DateTimeOffset]::Parse($fileMetadata.LastWriteUtc).UtcDateTime.Ticks) 'Core restore did not preserve exact native ACL, attributes and timestamp readback.'
        $restoreAvailabilityJob=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restored.AttemptOperationId;outputs=@($restored)}
        $restoreAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($restoreAvailabilityJob))
        $parsedResultUtc=$false;try{[void][DateTimeOffset]::Parse([string]$restoreAvailability.completedUtc);$parsedResultUtc=$true}catch{}
        Check ($restoreAvailability -and $restoreAvailability.current -and $restoreAvailability.manifestHash -ceq $manifestHash -and $restoreAvailability.generation -eq 1 -and $restoreAvailability.attemptId -ceq [string]$restored.AttemptOperationId -and $parsedResultUtc) 'Durable result view did not bind the exact package/attempt or safely fall back when CompletedUtc was absent.'
        Check ([string]$restored.ItemResultsHash -match '^[a-f0-9]{64}$') 'Core restore result omitted its hash binding to the exact durable item-result rows.'
        $safeRows=@(foreach($row in @($restored.ItemResults)){[pscustomobject]@{ItemId=[string]$row.ItemId;Status=[string]$row.Status;Reason='safe projected text';ReasonCode='safe';ObservedChecks=@();PendingChecks=@()}})
        $safeResult=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $restored -Depth 100 -Compress);$safeResult.ItemResults=$safeRows;$safeResult|Add-Member NoteProperty SafeProjectedItemResults $true -Force;$safeResult.ItemResultsHash=[string]$restored.ItemResultsHash
        $safeResultJob=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restored.AttemptOperationId;outputs=@($safeResult)}
        $safeAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($safeResultJob))
        Check ($safeAvailability -and $safeAvailability.attemptId -ceq [string]$restored.AttemptOperationId) 'A safe projected result carrying the exact core-authored raw result hash was rejected.'
        $fakeSafe=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $safeResult -Depth 100 -Compress);$fakeSafe.ItemResultsHash=('0'*64)
        $fakeSafeJob=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restored.AttemptOperationId;outputs=@($fakeSafe)}
        Check (-not (Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($fakeSafeJob)))) 'Safe projected rows with a forged/mismatched item-result hash were accepted.'
        $staleRestoreOutput=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $restored -Depth 50 -Compress);$staleRestoreOutput.Generation=0
        $staleRestoreJob=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restored.AttemptOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($staleRestoreOutput)}
        $mixedAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($restoreAvailabilityJob)+@($staleRestoreJob))
        $staleOnlyAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($staleRestoreJob))
        Check ($mixedAvailability -and $mixedAvailability.generation -eq 1 -and -not $staleOnlyAvailability) 'A stale-generation restore result replaced the current exact package-generation result.'
        $failedWorkerJob=[pscustomobject]@{action='TargetRestore';status='Failed';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restored.AttemptOperationId;outputs=@($restored)}
        $failedWorkerAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($failedWorkerJob))
        Check ($failedWorkerAvailability -and $failedWorkerAvailability.stage -ceq 'Partial' -and $failedWorkerAvailability.workerStatus -ceq 'Failed' -and $failedWorkerAvailability.status -cne 'Succeeded') 'A failed worker was projected as a successful Target restore despite its durable partial core result.'
        $emptyFailedWorker=[pscustomobject]@{action='TargetRestore';status='Failed';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restored.AttemptOperationId;outputs=@()}
        $recoveredTerminal=Get-WsmWizardTargetTerminalResultForOperation -Workspace $work -PairId $pair -OperationId ([string]$restored.AttemptOperationId) -Jobs (@($allJobs)+@($emptyFailedWorker))
        Check ($recoveredTerminal -and $recoveredTerminal.RecoveredAfterWorkerFailure -and $recoveredTerminal.Status -ceq 'Partial' -and $recoveredTerminal.AttemptOperationId -ceq $restored.AttemptOperationId -and $recoveredTerminal.ItemResultsHash -ceq $restored.ItemResultsHash -and $recoveredTerminal.JournalHash -ceq $restored.JournalHash -and [IO.File]::Exists($recoveredTerminal.JournalPath)) 'Empty EndInvoke output did not recover the exact current operation-bound durable result.'
        Check (-not (Get-WsmWizardTargetTerminalResultForOperation -Workspace $work -PairId $pair -OperationId ([Guid]::NewGuid().ToString()) -Jobs (@($allJobs)+@($emptyFailedWorker)))) 'Terminal recovery accepted a different operation id.'
        $recoveredJob=[pscustomobject]@{action='TargetRestore';status='Failed';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restored.AttemptOperationId;outputs=@($recoveredTerminal)}
        $recoveredAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($recoveredJob))
        Check ($recoveredAvailability -and $recoveredAvailability.stage -ceq 'Partial' -and $recoveredAvailability.workerStatus -ceq 'Failed' -and $recoveredAvailability.attemptId -ceq $restored.AttemptOperationId) 'Recovered empty-output worker result did not retain its failed worker status and exact durable attempt.'
        $unownedObservedBytes=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($targetFile2));$unownedObservedHash=(Get-FileHash -LiteralPath $targetFile2 -Algorithm SHA256).Hash;$unownedObservedMetadata=Get-WsmFileMetadata $targetFile2 'DaclOwner';$unownedObservedCreation=(Get-Item -LiteralPath $targetFile2).CreationTimeUtc.Ticks
        Write-Host ('unowned-check bytes={0}; hash={1}/{2}; lastWrite={3}/{4}; creation={5}/{6}' -f $unownedObservedBytes,$unownedObservedHash,$preexistingHash,$unownedObservedMetadata.LastWriteUtc,$preexistingMetadata.LastWriteUtc,$unownedObservedCreation,$preexistingCreationTicks)
        Check ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($targetFile2)) -ceq [Text.Encoding]::UTF8.GetString($preexistingBytes) -and (Get-FileHash -LiteralPath $targetFile2 -Algorithm SHA256).Hash -ieq [string]$preexistingHash -and (Get-WsmFileMetadata $targetFile2 'DaclOwner').LastWriteUtc -ceq $preexistingMetadata.LastWriteUtc -and (Get-Item -LiteralPath $targetFile2).CreationTimeUtc.Ticks -eq $preexistingCreationTicks) 'Restore changed unowned Target bytes or timestamp in an existing merged directory.'
        $replay=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash $preview.PreviewHash -Jobs $allJobs
        $afterReplayMetadata=Get-WsmFileMetadata $targetFile 'DaclOwner'
        Check ($replay.Replay -and $replay.AttemptOperationId -ceq $restored.AttemptOperationId -and $replay.JournalHash -ceq $restored.JournalHash -and (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash -ieq $actualHash -and $afterReplayMetadata.LastWriteUtc -ceq $actualMetadata.LastWriteUtc -and (Get-Item -LiteralPath $targetFile).CreationTimeUtc.Ticks -eq $actualCreationTicks -and @($replay.ItemResults|Where-Object ItemId -CEQ $item2.ItemId|Where-Object Status -CEQ 'BlockedConflict').Count -eq 1 -and @($replay.ItemResults|Where-Object ItemId -CEQ $item.ItemId|Where-Object Status -CEQ 'Succeeded').Count -eq 1) 'Repeated Target restore invocation changed prior bytes/metadata or failed to return the exact completed attempt, conflict and journal.'
        $stagedValidation=Invoke-WsmWizardTargetValidation -Workspace $work -PairId $pair -Phase Staged -Jobs $allJobs
        Check ($stagedValidation.Status -in @('Succeeded','ReviewRequired') -and $stagedValidation.ManifestHash -ceq $manifestHash -and [long]$stagedValidation.Generation -eq 1 -and $stagedValidation.SHA256 -match '^[a-f0-9]{64}$' -and [IO.File]::Exists($stagedValidation.Path)) 'Target staged validation did not produce a durable current-generation core result.'
        $afterValidationAvailability=Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($restoreAvailabilityJob))
        Check ($afterValidationAvailability -and $afterValidationAvailability.attemptId -ceq $restored.AttemptOperationId -and $afterValidationAvailability.journalHash -ceq $restored.JournalHash -and (Get-FileHash -LiteralPath $restored.JournalPath -Algorithm SHA256).Hash -ieq $restored.JournalHash) 'Appending real staged validation hid or rewrote the immutable current restore result proof.'
        $changedResult=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $restored -Depth 100 -Compress);$changedResult.ItemResults[0].Status='Succeeded'
        if($changedResult.ItemResults[0].Status -ceq $restored.ItemResults[0].Status){$changedResult.ItemResults[0].Status='BlockedConflict'}
        $changedResultJob=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restored.AttemptOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($changedResult)}
        Check (-not (Get-WsmWizardTargetRestoreAvailability $work $pair (Assert-WsmWizardTargetRole $work $pair).Profile (@($allJobs)+@($changedResultJob)))) 'Altered result rows were accepted despite differing from the authoritative exact restore attempt.'
        $acceptance=Get-WsmWizardTargetAcceptanceGates -Workspace $work -PairId $pair -Jobs $allJobs
        Check ($acceptance.Status -ceq 'ReviewRequired' -and -not $acceptance.FinalAccepted -and $acceptance.ManifestHash -ceq $manifestHash -and [long]$acceptance.Generation -eq 1) 'Nonfinal staged Target state incorrectly passed final acceptance gates.'
        Reject {New-WsmCutoverPlan -ManifestPath $manifestPath -ExpectedHash $manifestHash -StateDirectory $restoreStateDirectory} 'Core Cutover plan accepted the staged nonfinal package without freeze and final acceptance.'
        $outsidePackage=[pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pair;workspace=(Join-Path $Root 'other-workspace');outputs=$packageJobs[0].outputs};Reject {Get-WsmWizardTargetPackage $work $pair (Assert-WsmWizardTargetRole $work $pair) (@($jobs)+@($outsidePackage))} 'Package resolver accepted a delivery job from another workspace.'
        $malformedRoot=Join-Path $Root 'malformed-newer';Copy-Item -LiteralPath $packageRoot -Destination $malformedRoot -Recurse
        $malformedManifestPath=Join-Path $malformedRoot 'manifest.json';$malformedManifest=Read-WsmTrustedJson $malformedManifestPath $manifestHash;$malformedManifest.Generation=2;$malformedManifest.ArtifactsHash=('0'*64);SaveJson $malformedManifest $malformedManifestPath|Out-Null;$malformedHash=(Get-FileHash -LiteralPath $malformedManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Reject {Test-WsmMigrationPackage $malformedManifestPath $malformedHash} 'Core package validator accepted malformed newer-generation material.'
        $malformedJob=[pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$malformedManifestPath;ManifestHash=$malformedHash;PairId=$pair;PlanHash=$planHash;AttemptId=[Guid]::NewGuid().ToString()})}
        Reject {Get-WsmWizardTargetPackage $work $pair (Assert-WsmWizardTargetRole $work $pair) (@($allJobs)+@($malformedJob))} 'Package resolver silently fell back to older material after a newer successful delivery had drifted.'
        Write-Host ('PASS: '+$script:wizardRestoreChecks+' Target contracts plus real ZIP/directory wrapper receive, repeated-delivery dedupe, deferred decision, schema-3 preview/restore, pre-write cancellation and cancellation after the first fully written item, safe recovery, staged validation/acceptance gates, frozen activation gate, byte/ACL readback, and exact same-attempt replay verified.')
    } $root (Join-Path $module.ModuleBase 'WizardRestore.ps1') $workRoot
} finally {
    $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'wsm-wtr-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
    $workFull=[IO.Path]::GetFullPath($workRoot)
    if(-not $workFull.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($workFull) -notlike 'wsmwtr-*'){throw 'Unsafe target WorkRoot cleanup path.'}
    if([IO.Directory]::Exists($workFull)){Remove-Item -LiteralPath $workFull -Recurse -Force}
}

