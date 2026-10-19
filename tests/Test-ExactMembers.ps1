#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-exact-members-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    & $module {
        param($root)
        function Check($condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Reject($action,[string]$message){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $message}
        $script:checks=0
        $source=Join-Path $root 'source';$target=Join-Path $root 'target';$packageWork=Join-Path $root 'package-work';$state=Join-Path $root 'state'
        foreach($directory in @($source,$target,$packageWork,$state)){[void][IO.Directory]::CreateDirectory($directory)}
        $sourceFile=Join-Path $source 'app\BusinessPlugin.dll';[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sourceFile))
        [byte[]]$pe=New-Object byte[] 72;$pe[0]=0x4d;$pe[1]=0x5a;[BitConverter]::GetBytes([int]64).CopyTo($pe,60);$pe[64]=0x50;$pe[65]=0x45
        [IO.File]::WriteAllBytes($sourceFile,$pe);$sourceHash=(Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash.ToLowerInvariant();$exeSourceFile=Join-Path $source 'app\BusinessAgent.exe';[IO.File]::WriteAllBytes($exeSourceFile,$pe);$exeSourceHash=(Get-FileHash -LiteralPath $exeSourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $emptySourceFile=Join-Path $source 'empty.dat';[IO.File]::WriteAllBytes($emptySourceFile,(New-Object byte[] 0));$emptySourceHash=(Get-FileHash -LiteralPath $emptySourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $source 'unselected-neighbor.dll'),'neighbor before seal')
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$source;TargetPath=$target;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture owner';Evidence='explicit exact member confirmation';TransferChannel='C';ContentSelection='ExactMembers';Members=@([pscustomobject]@{RelativePath='app\BusinessPlugin.dll';SHA256=$sourceHash},[pscustomobject]@{RelativePath='app\BusinessAgent.exe';SHA256=$exeSourceHash},[pscustomobject]@{RelativePath='empty.dat';SHA256=$emptySourceHash})}
        Assert-WsmMigrationSpec $spec -Assistive
        $entries=@(Get-WsmScopeEntries $spec $packageWork)
        Check ($entries.Count -eq 3 -and @($entries|Where-Object RelativePath -CEQ 'app\BusinessPlugin.dll').Count -eq 1 -and @($entries|Where-Object RelativePath -CEQ 'app\BusinessAgent.exe').Count -eq 1 -and @($entries|Where-Object RelativePath -CEQ 'empty.dat').Count -eq 1 -and @($entries|Where-Object Directory).Count -eq 0) 'ExactMembers enumeration did not return only the approved files.'
        Check ([IO.File]::ReadAllBytes($sourceFile).Length -eq 72) 'ExactMembers fixture is not an app-local PE-shaped DLL.'
        [IO.File]::WriteAllText((Join-Path $source 'unselected-after-review.txt'),'new neighbor')
        Check (@(Get-WsmScopeEntries $spec $packageWork).Count -eq 3) 'A new neighboring file entered the fixed member set.'
        $spec.Members[0].SHA256='0'*64;Reject {Get-WsmScopeEntries $spec $packageWork} 'Stale approved member hash was accepted.';$spec.Members[0].SHA256=$sourceHash
        $bad=[pscustomobject]@{Adapter='FileScope';SourcePath=$source;TargetPath=$target;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture owner';Evidence='fixture';TransferChannel='C';ContentSelection='ExactMembers';Members=@([pscustomobject]@{RelativePath='app\BusinessPlugin.dll';SHA256=$sourceHash},[pscustomobject]@{RelativePath='APP\businessplugin.DLL';SHA256=$sourceHash})}
        Reject {Assert-WsmMigrationSpec $bad -Assistive} 'Case-colliding ExactMembers entries were accepted.'
        $bad.Members=@([pscustomobject]@{RelativePath='app\BusinessPlugin.dll';SHA256=$sourceHash});$bad.ExcludedRelativePaths=@('app\BusinessPlugin.dll');Reject {Assert-WsmMigrationSpec $bad -Assistive} 'ExactMembers accepted a contradictory exclusion for an approved member.';$bad.ExcludedRelativePaths=@()
        $bad.PSObject.Properties.Remove('Members');Reject {Assert-WsmMigrationSpec $bad -Assistive} 'ExactMembers without Members was not rejected as a contract error.';$bad|Add-Member NoteProperty Members @()
        $bad.Members=@([pscustomobject]@{RelativePath='..\outside.dll';SHA256=$sourceHash});Reject {Assert-WsmMigrationSpec $bad -Assistive} 'Escaping ExactMembers path was accepted.'
        $bad.Members=@([pscustomobject]@{RelativePath='app\BusinessPlugin.dll';SHA256=$sourceHash});$bad.TransferChannel='NonC';Reject {Assert-WsmMigrationSpec $bad -Assistive} 'Unsupported ExactMembers NonC mode was accepted instead of being rejected.'
        $rootSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='C:\';TargetPath='C:\';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture owner';Evidence='one explicit root member';TransferChannel='C';ContentSelection='ExactMembers';Members=@([pscustomobject]@{RelativePath='Users\Public\fixture.dll';SHA256=$sourceHash})}
        Assert-WsmMigrationSpec $rootSpec -Assistive
        Check $true 'An exact member under C:\ could not be approved.'

        $sourceIdentity=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=(Get-WsmAssistiveMachineFingerprint);Name='FixtureSource';OS='Windows Server fixture';Version='10.0'}
        $targetIdentity=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='FixtureTarget';OS='Windows Server fixture';Version='10.0'}
        $script:sourceIdentity=$sourceIdentity
        $installRoot=Join-Path $source 'trusted-runtime';[void][IO.Directory]::CreateDirectory($installRoot)
        $sourceInventory=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='Inventory';Source=$sourceIdentity;Revision=1;Items=@()}
        $softwareEntry=[pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId 'Machine' '' 'Registry64' $installRoot 'fixture-product');Name='Fixture Runtime';Version='1';Publisher='Fixture';Architecture='Unknown';Scope='Machine';SID='';RegistryView='Registry64';Location=$installRoot;SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='HKLM\Software\Fixture';NaturalKey='fixture-product'};ObservedUtc=[DateTime]::UtcNow.ToString('o');CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
        $softwareCatalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$sourceIdentity.HostId;Fingerprint=$sourceIdentity.Fingerprint;Name=$sourceIdentity.Name;InventoryRevision=1;InventoryProjectionHash=''};CaptureContext=[pscustomobject]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($softwareEntry);Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=[DateTime]::UtcNow.ToString('o')});PreparationRequirements=@([pscustomobject]@{PreparationId=('prep-'+$softwareEntry.SoftwareId.Substring(3));SoftwareId=$softwareEntry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='Evidence inventory only.'});CatalogProjectionHash=('0'*64)}
        $sourceInventory|Add-Member NoteProperty SoftwareCatalog $softwareCatalog
        $softwareCatalog.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $sourceInventory;$softwareCatalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $softwareCatalog;Assert-WsmSoftwareCatalog $softwareCatalog -SourceInventory $sourceInventory|Out-Null
        $installMemberSpec=$spec.PSObject.Copy();$installMemberSpec.Members=@([pscustomobject]@{RelativePath='trusted-runtime\host.dll';SHA256=$sourceHash})
        Reject {Assert-WsmFileScopeInstalledRoots $installMemberSpec $sourceInventory} 'The real ExactMembers installed-root guard accepted a member inside a trusted installer root.'
        $businessGuard=Assert-WsmFileScopeInstalledRoots $spec $sourceInventory
        Check ($businessGuard.Status -eq 'Captured' -and $businessGuard.RootsChecked -eq 1) 'The real ExactMembers installed-root guard rejected an unrelated business member.'
        $memberPlan=[pscustomobject]@{Items=@([pscustomobject]@{Decision='Include';MigrationSpec=$spec})}
        Reject {Assert-WsmSourceWorkspaceSeparation $memberPlan $sourceFile} 'The real ExactMembers workspace guard accepted a workspace overlapping an approved member.'
        $rootMemberPlan=[pscustomobject]@{Items=@([pscustomobject]@{Decision='Include';MigrationSpec=$rootSpec})}
        Assert-WsmSourceWorkspaceSeparation $rootMemberPlan (Join-Path $root 'unrelated-workspace')
        Check $true 'The real ExactMembers workspace guard rejected C:\ root members despite an unrelated workspace.'
        Reject {Assert-WsmMigrationSpec $spec} 'A non-Assistive schema ExactMembers spec bypassed the new-mode contract restriction.'

        $setterItem=New-WsmItem $sourceIdentity.HostId Storage FileScope 'Exact setter fixture' 'exact-setter-fixture' ([pscustomobject]@{SourcePath=$source;TargetPath=$target}) @() Success FileScope
        $setterInventory=New-WsmInventory $sourceIdentity 1 @($setterItem);$setterInventory|Add-Member NoteProperty SoftwareCatalog $softwareCatalog
        $softwareCatalog.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $setterInventory;$softwareCatalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $softwareCatalog;Assert-WsmSoftwareCatalog $softwareCatalog -SourceInventory $setterInventory|Out-Null
        $setterInventoryPath=Join-Path $root 'setter-inventory.json';Write-WsmJson $setterInventoryPath $setterInventory;$setterWorkspace=Join-Path $root 'setter-workspace';Initialize-WsmWorkspace $setterWorkspace|Out-Null;$setterCatalog=Import-WsmInventory $setterWorkspace $setterInventoryPath (Get-FileHash -LiteralPath $setterInventoryPath -Algorithm SHA256).Hash 'setter-target'
        $setterSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='C:\';TargetPath='C:\';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture owner';Evidence='explicit exact setter review';TransferChannel='C';ContentSelection='ExactMembers';Members=@([pscustomobject]@{RelativePath='Users\Public\setter.dll';SHA256=$sourceHash})};$setterSpecPath=Join-Path $root 'setter-spec.json';Write-WsmJson $setterSpecPath $setterSpec
        Reject {Set-WsmMigrationSpec $setterWorkspace $setterCatalog.PairId $setterItem.ItemId $setterSpecPath (Get-FileHash -LiteralPath $setterSpecPath -Algorithm SHA256).Hash $setterCatalog.DecisionRevision} 'The legacy public setter accepted an ExactMembers contract outside schema 3 Assistive context.'
        $setterCatalog=Enable-WsmAssistiveMode $setterWorkspace $setterCatalog.PairId $setterCatalog.DecisionRevision
        Set-WsmMigrationSpec $setterWorkspace $setterCatalog.PairId $setterItem.ItemId $setterSpecPath (Get-FileHash -LiteralPath $setterSpecPath -Algorithm SHA256).Hash $setterCatalog.DecisionRevision|Out-Null;$setterCatalog=Get-WsmCatalog $setterWorkspace $setterCatalog.PairId
        Check ($setterCatalog.Items[0].MigrationSpec.ContentSelection -ceq 'ExactMembers' -and $setterCatalog.Items[0].MigrationSpec.SourcePath -ceq 'C:\') 'The public Assistive setter rejected a valid ExactMembers C:\ root spec.'

        $itemId=('c'*64);$pairId=[Guid]::NewGuid().ToString()
        $catalogItem=[pscustomobject][ordered]@{ItemId=$itemId;Category='Storage';Kind='FileScope';Name='Reviewed exact member set';NaturalKey='exact-members-fixture';Settings=[pscustomobject]@{SourcePath=$source;TargetPath=$target};SettingsHash=('d'*64);Dependencies=@();Status='Success';Adapter='FileScope';Decision='Include';Reason='explicitly reviewed';ReviewedBy='fixture reviewer';ReviewedUtc=Get-WsmUtc;RuleId='';Mapping='';Evidence='';Owner='fixture reviewer';Present=$true;MigrationSpec=$spec}
        $inventoryHash=('e'*64);$snapshotReference=[pscustomobject][ordered]@{Reference='assistive\snapshots\fixture.json';SHA256=$inventoryHash;CreatedUtc=Get-WsmUtc;InventoryRevision=1}
        $catalog=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion='0.4.0';Kind='Catalog';PairId=$pairId;SourceHostId=$sourceIdentity.HostId;SourceName=$sourceIdentity.Name;InventoryHash=$inventoryHash;InventoryRevision=1;DecisionRevision=1;Approval=$null;Items=@($catalogItem)}
        $catalog | Add-Member NoteProperty Assistive (New-WsmAssistiveCatalogContract -PairId $pairId -SourceReference $snapshotReference.Reference -SourceHash $inventoryHash -InventoryRevision 1 -Items @($catalogItem) -Prior $null)
        $planSeed=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString();PairId=$pairId;ApprovalId=[Guid]::NewGuid().ToString();Source=$sourceIdentity;Target=$targetIdentity;InventoryHash=$inventoryHash;InventoryRevision=1;DecisionRevision=1;Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);ApprovedUtc=Get-WsmUtc;Items=@([pscustomobject]@{ItemId=$itemId;Category='Storage';Kind='ManualItem';Name='Reviewed exact member set';NaturalKey='exact-members-fixture';Status='Success';Adapter='FileScope';Present=$true;Decision='Include';Reason='explicitly reviewed';MigrationSpec=$spec;Dependencies=@();Settings=[pscustomobject]@{};SettingsHash=('d'*64)})}
        $plan=New-WsmAssistiveMigrationPlanContract -Plan $planSeed -Catalog $catalog
        $planPath=Join-Path $root 'plan.json';Write-WsmJson $planPath $plan;$planHash=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant();$script:plan=$plan
        $validatedPlan=Read-WsmMigrationPlan $planPath $planHash
        Check ($validatedPlan.SchemaVersion -eq 3 -and $validatedPlan.Assistive.SourcePolicy -ceq 'SourceCOnly' -and @($validatedPlan.Assistive.ApprovedItemIds|Where-Object {$_ -ceq $itemId}).Count -eq 1 -and $validatedPlan.Items[0].MigrationSpec.ContentSelection -ceq 'ExactMembers') 'Real sealed-plan reader did not validate the Assistive contract and ExactMembers spec.'
        $detailOutput=Join-Path $root 'member-details';$details=Export-WsmWizardFileDetails -Item $validatedPlan.Items[0] -OutputDirectory $detailOutput;$detailRecord=Read-WsmJson $details.Path
        Check ($detailRecord.Entries.Count -eq 3 -and @($detailRecord.Entries|Where-Object {$_.directory -or $_.path -in @('unselected-neighbor.dll','unselected-after-review.txt')}).Count -eq 0 -and @($detailRecord.Entries|Where-Object {$_.approvedSha256 -match '^[a-f0-9]{64}$' -and -not $_.contentRead}).Count -eq 3) 'ExactMembers file details enumerated neighboring paths or omitted approved member hash metadata.'
        $reportRows=Get-WsmAssistiveReportPathRows $catalog;$scopeReport=New-Object 'System.Collections.Generic.List[object]';$memberReport=New-Object 'System.Collections.Generic.List[object]'
        foreach($row in $reportRows){if($row -is [array] -and $row.Count -gt 10){if([string]$row[5] -like 'ExactMembers set (*)'){$scopeReport.Add($row)};if([string]$row[5] -ceq 'Approved exact member'){$memberReport.Add($row)}}}
        $memberHashes=@(foreach($row in $memberReport){if([string]$row[9] -match '^[a-f0-9]{64}$'){$row[9]}})
        $reportValid=$false;$scopeText='';$scopeNote='';if($scopeReport.Count -eq 1){$scopeRow=$scopeReport[0];$scopeText=[string]$scopeRow[5];$scopeNote=[string]$scopeRow[10]}
        if($scopeReport.Count -eq 1 -and $memberReport.Count -eq 3 -and $memberHashes.Count -eq 3){$reportValid=($scopeText -ceq 'ExactMembers set (3 files; no directory coverage)' -and $scopeNote.Contains('not fully covered'))}
        Check $reportValid 'Assistive report failed to show the exact member count, per-file hash baselines, or no-directory-coverage statement.'
        function Get-WsmMachineIdentity{$script:sourceIdentity}
        function Assert-WsmMigrationHost($Identity,[string]$Fingerprint){}
        function Assert-WsmSourceWorkspaceSeparation($Plan,[string]$Workspace){}
        function Assert-WsmFileScopeInstalledRoots($Spec,$SourceInventory,[switch]$NativeSource){[pscustomobject]@{Status='Captured';RootsChecked=0;Diagnostics=@()}}
        $inventoryPath=Join-Path $root 'inventory.json';Write-WsmJson $inventoryPath ([pscustomobject]@{Kind='Inventory';Source=$sourceIdentity;Items=@();SoftwareCatalog=[pscustomobject]@{Entries=@();Coverage=@()}})
        $script:freshInventory=[pscustomobject]@{Path=$inventoryPath;SHA256=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Export-WsmInventory {param($SourceStateDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog)$script:freshInventory}
        $export=Export-WsmMigrationPackageCore -PlanPath $planPath -ExpectedHash $planHash -SourceStateDirectory $state -OutputDirectory $packageWork -ChunkBytes 65536
        $package=Test-WsmMigrationPackage -ManifestPath $export.ManifestPath -ExpectedHash $export.SHA256
        $rows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash)
        Check ($rows.Count -eq 3 -and @($rows|Where-Object {$_.RelativePath -ceq 'app\BusinessPlugin.dll' -and $_.Data.Hash -ceq $sourceHash}).Count -eq 1 -and @($rows|Where-Object {$_.RelativePath -ceq 'app\BusinessAgent.exe' -and $_.Data.Hash -ceq $exeSourceHash}).Count -eq 1 -and @($rows|Where-Object {$_.RelativePath -ceq 'empty.dat' -and $_.Data.Hash -ceq $emptySourceHash -and $_.Data.Bytes -eq 0}).Count -eq 1) 'Sealed package artifacts differ from the approved ExactMembers set or lost a binary/zero-length member.'

        $legacyPlan=ConvertFrom-WsmJson ($plan|ConvertTo-Json -Depth 50 -Compress);$legacyPlan.SchemaVersion=1;$legacyPlan.PSObject.Properties.Remove('Assistive');$legacySpec=$legacyPlan.Items[0].MigrationSpec;$legacySpec.PSObject.Properties.Remove('ContentSelection');$legacySpec.PSObject.Properties.Remove('Members');$legacySpec.PSObject.Properties.Remove('TransferChannel')
        $legacyPlanPath=Join-Path $root 'legacy-plan.json';Write-WsmJson $legacyPlanPath $legacyPlan;$legacyPlanHash=(Get-FileHash -LiteralPath $legacyPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $legacyExport=Export-WsmMigrationPackageCore -PlanPath $legacyPlanPath -ExpectedHash $legacyPlanHash -SourceStateDirectory $state -OutputDirectory (Join-Path $root 'legacy-package-work') -ChunkBytes 65536
        $legacyPackage=Test-WsmMigrationPackage -ManifestPath $legacyExport.ManifestPath -ExpectedHash $legacyExport.SHA256
        Check ($legacyPackage.Valid -and $legacyPackage.Manifest.Files -eq 5) 'A real legacy FileScope package with no ContentSelection failed package production/reader validation or lost whole-scope files.'

        $forged=Join-Path $root 'forged-package';Copy-Item -LiteralPath $package.Root -Destination $forged -Recurse
        $forgedIndex=Join-Path $forged 'artifacts.jsonl';$forgedRows=@(Read-WsmArtifactLines $forgedIndex $package.Manifest.ArtifactsHash);$neighbor=$forgedRows[0].PSObject.Copy();$neighbor.RelativePath='unselected-neighbor.dll'
        $forgedLines=@($forgedRows|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 20})+@($neighbor|ConvertTo-Json -Compress -Depth 20);[IO.File]::WriteAllLines($forgedIndex,$forgedLines,(New-Object Text.UTF8Encoding($false)))
        $forgedManifestPath=Join-Path $forged 'manifest.json';$forgedManifest=Read-WsmJson $forgedManifestPath;$forgedManifest.ArtifactsHash=(Get-FileHash -LiteralPath $forgedIndex -Algorithm SHA256).Hash.ToLowerInvariant();$forgedManifest.Records=4;$forgedManifest.Files=4;$forgedManifest.Bytes=[long]($forgedManifest.Bytes+$neighbor.Data.Bytes);Write-WsmJson $forgedManifestPath $forgedManifest;$forgedHash=(Get-FileHash -LiteralPath $forgedManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Reject {Test-WsmMigrationPackage -ManifestPath $forgedManifestPath -ExpectedHash $forgedHash} 'Package reader accepted an extra neighboring artifact outside the sealed ExactMembers set.'

        $placement=Get-WsmFilePlacementPreview -ManifestPath $export.ManifestPath -ExpectedHash $export.SHA256 -StateDirectory $state
        Check ($placement.Rows.Count -eq 3 -and @($placement.Rows|Where-Object PlacementStatus -NE 'CanPlace').Count -eq 0) 'Placement preview did not preserve the exact member set.'
        [IO.File]::WriteAllText((Join-Path $target 'unselected-neighbor.txt'),'operator data')
        $paths=[pscustomobject]@{Root=$state;State=$null;Journal=$null};$restoreState=[pscustomobject]@{Items=@();PendingOperations=@()}
        function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){}
        $restored=Invoke-WsmAssistiveFileScopeRestore $package.Plan.Items[0] $package $paths $restoreState @{} $null
        $targetFile=Join-Path $target 'app\BusinessPlugin.dll'
        Check ($restored.Status -ceq 'Succeeded' -and [IO.File]::Exists($targetFile) -and (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $sourceHash) 'ExactMembers restore did not read back the approved member hash.'
        Check ((Get-FileHash -LiteralPath (Join-Path $target 'app\BusinessAgent.exe') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $exeSourceHash) 'ExactMembers filtered an approved app-local EXE by its extension.'
        Check ([IO.File]::Exists((Join-Path $target 'empty.dat')) -and (Get-Item -LiteralPath (Join-Path $target 'empty.dat')).Length -eq 0) 'ExactMembers restore omitted an approved zero-length file.'
        Check ([IO.File]::ReadAllText((Join-Path $target 'unselected-neighbor.txt')) -ceq 'operator data' -and -not [IO.File]::Exists((Join-Path $target 'unselected-neighbor.dll')) -and -not [IO.File]::Exists((Join-Path $target 'unselected-after-review.txt'))) 'Unselected neighbors were changed or restored.'

        $reparseRoot=Join-Path $source 'reparse';$outside=Join-Path $root 'outside';[void][IO.Directory]::CreateDirectory($outside);$outsideFile=Join-Path $outside 'outside.dll';[IO.File]::WriteAllText($outsideFile,'outside')
        try{New-Item -ItemType Junction -Path $reparseRoot -Target $outside -ErrorAction Stop|Out-Null;$reparseSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$source;TargetPath=$target;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture';Evidence='fixture';TransferChannel='C';ContentSelection='ExactMembers';Members=@([pscustomobject]@{RelativePath='reparse\outside.dll';SHA256=(Get-FileHash $outsideFile).Hash.ToLowerInvariant()})};Reject {Get-WsmScopeEntries $reparseSpec $packageWork} 'ExactMembers followed a reparse-point parent.'}catch{if($_.Exception.Message -notmatch 'privilege|access|administrator|not supported|symbolic|junction'){throw};Write-Warning 'Junction creation unavailable in this environment; reparse member behavior remains covered by Assert-WsmNoReparse and was not exercised with a native junction.'}
        Write-Host ('PASS: '+$script:checks+' ExactMembers contract, source hashing, package set equality, placement and restore checks; source candidate-to-approval hashing remains a separate D1/D2 connection.')
    } $root
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
