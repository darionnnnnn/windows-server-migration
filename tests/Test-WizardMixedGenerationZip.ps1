#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-mgz-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$work=Join-Path ([IO.Path]::GetTempPath()) ('wsm-mgzw-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$module=$null;$snapshotHashes=[ordered]@{}
try {
    $repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$snapshotRoot=Join-Path $root 'source-snapshot';$snapshotSource=Join-Path $snapshotRoot 'src'
[void][IO.Directory]::CreateDirectory($snapshotSource)
foreach($sourceFile in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -File -Recurse)){
    $relative=$sourceFile.FullName.Substring((Join-Path $repoRoot 'src').Length).TrimStart('\')
    $snapshotFile=Join-Path $snapshotSource $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($snapshotFile))
    $before=(Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::Copy($sourceFile.FullName,$snapshotFile,$false)
    $copied=(Get-FileHash -LiteralPath $snapshotFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $after=(Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if($before -cne $copied -or $before -cne $after){throw ('Source changed while taking immutable test snapshot: '+$relative)}
    $snapshotHashes[$relative]=$copied
}
$launcherPath=Join-Path $repoRoot 'Start-ServerMigration.ps1';$snapshotLauncher=Join-Path $snapshotRoot 'Start-ServerMigration.ps1'
$launcherBefore=(Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash.ToLowerInvariant();[IO.File]::Copy($launcherPath,$snapshotLauncher,$false);$launcherCopy=(Get-FileHash -LiteralPath $snapshotLauncher -Algorithm SHA256).Hash.ToLowerInvariant();$launcherAfter=(Get-FileHash -LiteralPath $launcherPath -Algorithm SHA256).Hash.ToLowerInvariant()
if($launcherBefore -cne $launcherCopy -or $launcherBefore -cne $launcherAfter){throw 'Start-ServerMigration.ps1 changed while taking the immutable test snapshot.'}
$snapshotHashes['Start-ServerMigration.ps1']=$launcherCopy
$launcherCmdPath=Join-Path $repoRoot 'Start-ServerMigration.cmd'
if([IO.File]::Exists($launcherCmdPath)){$snapshotLauncherCmd=Join-Path $snapshotRoot 'Start-ServerMigration.cmd';$launcherCmdBefore=(Get-FileHash -LiteralPath $launcherCmdPath -Algorithm SHA256).Hash.ToLowerInvariant();[IO.File]::Copy($launcherCmdPath,$snapshotLauncherCmd,$false);$launcherCmdCopy=(Get-FileHash -LiteralPath $snapshotLauncherCmd -Algorithm SHA256).Hash.ToLowerInvariant();$launcherCmdAfter=(Get-FileHash -LiteralPath $launcherCmdPath -Algorithm SHA256).Hash.ToLowerInvariant();if($launcherCmdBefore -cne $launcherCmdCopy -or $launcherCmdBefore -cne $launcherCmdAfter){throw 'Start-ServerMigration.cmd changed while taking the immutable test snapshot.'};$snapshotHashes['Start-ServerMigration.cmd']=$launcherCmdCopy}
$module=Import-Module (Join-Path $snapshotSource 'WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
    & $module {
        param($Root,$Work)
        $script:mixedGenerationChecks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:mixedGenerationChecks++}
        function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
        function SaveJson($Data,[string]$Path){[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$Path}

        # Keep the actual package validator, exporter and Target ZIP importer. Only
        # the machine identity is a fixture, and payload bytes are bounded to 2 MiB.
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('b'*64);Name='Mixed ZIP Target';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:mixedGenerationTarget}
        $script:mixedGenerationTarget=$target
        $enrollment=Initialize-WsmOutputWorkspace -WorkRoot $Work -Role Target
        Initialize-WsmWorkspace $Work|Out-Null
        $pair=[Guid]::NewGuid().ToString('D')
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='Mixed ZIP Source';OS='Fixture Server';Version='10.0'}
        $item=New-WsmItem $source.HostId Storage DataRoot 'Mixed-generation ZIP fixture' 'mixed-generation-fixture' @{Path='C:\fixture\mixed-generation'}
        foreach($name in @('Decision','Reason','Owner','Evidence')){$value=switch($name){Decision{'Include'}Reason{'Reviewed fixture package'}Owner{'Fixture owner'}Evidence{'Isolated mixed-generation test'}};$item|Add-Member NoteProperty $name $value -Force}
        $scope=Join-Path $Root 'payload-scope';[void][IO.Directory]::CreateDirectory($scope)
        $payload=New-Object byte[] (2*1024*1024);$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($payload)}finally{$rng.Dispose()}
        $sourcePath=Join-Path $scope 'state.bin';[IO.File]::WriteAllBytes($sourcePath,$payload)
        $targetScope=Join-Path $Root 'target-scope'
        $spec=[pscustomobject][ordered]@{Adapter='FileScope';Product='Fixture';Procedure='Inspect test payload';Artifacts=@();BusinessChecks=@('Confirm fixture bytes');Owner='Fixture owner';Evidence='Isolated test';SourcePath=$scope;TargetPath=$targetScope;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';TransferChannel='C';ContentSelection='WholeScope';ConfigFiles=@();ConfigOverrides=@()}
        $item|Add-Member NoteProperty MigrationSpec $spec -Force
        $snapshot=New-WsmInventory $source 1 @($item);$snapshotPath=Join-Path $Root 'source-inventory.json';SaveJson $snapshot $snapshotPath|Out-Null
        $snapshotHash=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $planItem=$item|ConvertTo-Json -Depth 50|ConvertFrom-Json
        $plan=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion=$script:ToolVersion;Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString('D');PairId=$pair;ApprovalId=[Guid]::NewGuid().ToString('D');Source=$source;Target=[pscustomobject]@{HostId=$enrollment.Profile.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;OS=$target.OS;Version=$target.Version};InventoryRevision=1;DecisionRevision=2;InventoryHash=$snapshotHash;ImportedUtc=(Get-WsmUtc);Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);ApprovedUtc=(Get-WsmUtc);Items=@($planItem);ScopeMode='Assistive'}
        $plan|Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=$pair;SourceSnapshotHash=$snapshotHash;SourcePolicy='SourceCOnly';SourceSelectionsVersion=1;ApprovedItemIds=@([string]$item.ItemId);MaterialReferences=@();DiscoveryAuthority=[pscustomobject][ordered]@{SourceSnapshotReference=[pscustomobject][ordered]@{Reference='source-inventory.json';SHA256=$snapshotHash;InventoryRevision=1;CreatedUtc=(Get-WsmUtc)};InventoryRevision=1;SelectionRevision=1;Dispositions=@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Selected=$true;Decision='Include';Reason='Explicitly selected test fixture'})}}) -Force
        Assert-WsmAssistiveContract $plan MigrationPlan|Out-Null
        $planPath=Join-Path $Root 'approved-plan.json';SaveJson $plan $planPath|Out-Null
        $planHash=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $planImport=Import-WsmWizardApprovedPlan -Workspace $Work -Role Target -Path $planPath -ExpectedHash $planHash
        Check ($planImport.Status -ceq 'ImportedVerified' -and $planImport.PairId -ceq $pair) 'Target did not receive the real approved schema-3 fixture plan.'

        $packageRoot=Join-Path $Root 'package';$payloadRoot=Join-Path $packageRoot 'payload';[void][IO.Directory]::CreateDirectory($payloadRoot)
        [IO.File]::Copy($planPath,(Join-Path $packageRoot 'plan.json'))
        $proof=Assert-WsmAssistiveSourceScope $spec SourceCOnly -Native
        Check ($proof.Channel -ceq 'C') 'The bounded package fixture was not on the native C volume.'
        $rootMetadata=Get-WsmFileMetadata $scope 'DaclOwner';$fileMetadata=Get-WsmFileMetadata $sourcePath 'DaclOwner'
        $blob=Write-WsmPayloadFile $sourcePath $payloadRoot 65536 0 $null
        $record=[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;RelativePath='state.bin';Directory=$false;Metadata=$fileMetadata;Data=$blob}
        $recordsPath=Join-Path $packageRoot 'artifacts.jsonl';[IO.File]::WriteAllText($recordsPath,(ConvertTo-Json -InputObject $record -Depth 30 -Compress)+"`n",(New-Object Text.UTF8Encoding($false)))
        $indexHash=(Get-FileHash -LiteralPath $recordsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString('D');BatchId=$plan.BatchId;PairId=$pair;ApprovalId=$plan.ApprovalId;PlanHash=$planHash;Source=$plan.Source;Target=$plan.Target;InventoryRevision=1;DecisionRevision=2;Generation=1;BaseManifestHash='';Final=$false;FreezeHash='';ArtifactsHash=$indexHash;Files=1;Bytes=[long]$payload.Length;Records=1;ChunkBytes=65536;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot';SourceCollectionProofs=@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Channel='C';PhysicalPath=$proof.PhysicalPath;SourceCPhysicalRoot=$proof.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true})}
        $manifestPath=Join-Path $packageRoot 'manifest.json';SaveJson $manifest $manifestPath|Out-Null
        $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $validated=Test-WsmMigrationPackage $manifestPath $manifestHash
        Check ($validated.Valid -and [int]$validated.Manifest.Generation -eq 1 -and $validated.PlanHash -ceq $planHash) 'Core validator rejected the valid first-generation package.'
        $zipOne=Export-WsmPackageZip -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $Root 'zip-generation-one') -VolumeBytes 1048576
        Check ([int]$zipOne.Volumes -ge 2) 'Generation 1 did not produce at least two ZIP volumes at the 1 MiB core fixture limit.'

        # Generation 2 is a genuine new sealed manifest in the same Pair and plan,
        # chained to the prior manifest. The payload remains the same bounded fixture.
        $manifest.Generation=2;$manifest.BaseManifestHash=$manifestHash;$manifest.PackageId=[Guid]::NewGuid().ToString('D');$manifest.SealedUtc=(Get-WsmUtc)
        SaveJson $manifest $manifestPath|Out-Null
        $generationTwoHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $validatedTwo=Test-WsmMigrationPackage $manifestPath $generationTwoHash
        Check ($validatedTwo.Valid -and [int]$validatedTwo.Manifest.Generation -eq 2 -and $validatedTwo.Manifest.BaseManifestHash -ceq $manifestHash -and $validatedTwo.PlanHash -ceq $planHash) 'Core validator rejected the valid chained second-generation package.'
        $zipTwo=Export-WsmPackageZip -ManifestPath $manifestPath -ExpectedHash $generationTwoHash -OutputDirectory (Join-Path $Root 'zip-generation-two') -VolumeBytes 1048576
        Check ([int]$zipTwo.Volumes -ge 2) 'Generation 2 did not produce at least two ZIP volumes at the 1 MiB core fixture limit.'
        $transportOne=Read-WsmTrustedJson $zipOne.Path ([string]$zipOne.SHA256)
        $transportTwo=Read-WsmTrustedJson $zipTwo.Path ([string]$zipTwo.SHA256)
        Check ($transportOne.PairId -ceq $pair -and $transportTwo.PairId -ceq $pair -and $transportOne.ManifestHash -ceq $zipOne.PackageManifestHash -and $transportTwo.ManifestHash -ceq $zipTwo.PackageManifestHash) 'The real ZIP transports do not represent both manifest generations of the same Pair.'

        # Start with generation 1's authentic descriptor and volume set, then swap
        # one real generation 2 volume into it. This is a true cross-generation mix.
        $mixedDirectory=Join-Path $Root 'mixed-zip';[void][IO.Directory]::CreateDirectory($mixedDirectory)
        [IO.File]::Copy($zipOne.Path,(Join-Path $mixedDirectory 'transport.json'))
        foreach($volume in $transportOne.Volumes){[IO.File]::Copy((Join-Path (Split-Path -Parent $zipOne.Path) $volume.Name),(Join-Path $mixedDirectory $volume.Name))}
        $firstOne=$transportOne.Volumes[0];$firstTwo=$transportTwo.Volumes[0]
        $mixedVolumePath=Join-Path $mixedDirectory $firstOne.Name
        [IO.File]::Copy((Join-Path (Split-Path -Parent $zipTwo.Path) $firstTwo.Name),$mixedVolumePath,$true)
        $sourceVolumeHash=(Get-FileHash -LiteralPath $mixedVolumePath -Algorithm SHA256).Hash.ToLowerInvariant()
        Check ($sourceVolumeHash -cne [string]$firstOne.Hash -and $sourceVolumeHash -ceq [string]$firstTwo.Hash) 'The selected volume was not replaced with a distinct authentic generation 2 volume.'
        $mixedTransport=Join-Path $mixedDirectory 'transport.json'
        $beforeProfileHash=(Get-FileHash -LiteralPath (Join-Path (Join-Path $Work 'workspace-control') 'output-profile.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        $operationId=[Guid]::NewGuid().ToString('D')
        $token=New-WsmWizardTargetPackageCancellation -Workspace $Work -PairId $pair -Action ImportPackageZip -Path $mixedTransport -ExpectedHash ([string]$zipOne.SHA256) -OperationId $operationId
        Reject {Import-WsmWizardTargetZipPackage -Workspace $Work -PairId $pair -TransportPath $mixedTransport -ExpectedHash ([string]$zipOne.SHA256) -OperationId $operationId -CancellationToken $token} 'The formal Target ZIP importer accepted volumes mixed between two generations of the same Pair.'
        $incomingRoot=Join-Path (Join-Path (Join-Path $Work 'workspace-control') 'wizard-package-imports') ([string]$transportOne.PackageId)
        Check (-not [IO.Directory]::Exists($incomingRoot)) 'Rejected mixed-generation ZIP created a package import state directory.'
        $noPackageAuthority=$false
        try{$null=Get-WsmWizardTargetPackage -Workspace $Work -PairId $pair -Context (Assert-WsmWizardTargetRole $Work $pair) -Jobs @()}catch{$noPackageAuthority=$_.Exception.Message -like 'No durable successful Target package-delivery job*'}
        Check $noPackageAuthority 'Rejected mixed-generation ZIP left a resolvable authoritative imported-package state for this Pair.'
        $afterProfileHash=(Get-FileHash -LiteralPath (Join-Path (Join-Path $Work 'workspace-control') 'output-profile.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        Check ($beforeProfileHash -ceq $afterProfileHash) 'Rejected mixed-generation ZIP changed the Target workspace role/profile authority.'
        Write-Output ('PASS Test-WizardMixedGenerationZip checks='+$script:mixedGenerationChecks+'; real core-validated generation 1 and 2 ZIPs for one Pair were mixed and rejected before Target import state was created.')
    } $root $work
} finally {
    if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue}
    foreach($relative in @($snapshotHashes.Keys)){$snapshotFile=if($relative -ceq 'Start-ServerMigration.ps1'){$snapshotLauncher}elseif($relative -ceq 'Start-ServerMigration.cmd'){$snapshotLauncherCmd}else{Join-Path $snapshotSource $relative};$actual=(Get-FileHash -LiteralPath $snapshotFile -Algorithm SHA256).Hash.ToLowerInvariant();if($actual -cne [string]$snapshotHashes[$relative]){throw ('Immutable test snapshot changed: '+$relative)}}
    foreach($candidate in @($root,$work)){
        $full=[IO.Path]::GetFullPath($candidate);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^wsm-mgz(w)?-'){throw 'Unsafe mixed-generation ZIP test cleanup path.'}
        if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
    }
}
