#requires -Version 5.1
# B6: ExactMembers carries leaf empty directories end to end:
# contract -> sealed plan -> CV2 package artifact -> original-location restore.
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-exact-dirs-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    & $module {
        param($root)
        function Check($condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Reject($action,[string]$message){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $message}
        $script:checks=0
        $source=Join-Path $root 'source';$target=Join-Path $root 'target';$packageWork=Join-Path $root 'package-work';$state=Join-Path $root 'state'
        foreach($directory in @($source,$target,$packageWork,$state)){[void][IO.Directory]::CreateDirectory($directory)}
        $keepFile=Join-Path $source 'data\keep.dat';[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($keepFile));[IO.File]::WriteAllText($keepFile,'keep bytes')
        $keepHash=(Get-FileHash -LiteralPath $keepFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $externalLeaf=Join-Path $source 'data\empty-one';$deepLeaf=Join-Path $source 'tree\level1\level2';foreach($directory in @($externalLeaf,$deepLeaf)){[void][IO.Directory]::CreateDirectory($directory)}
        $newMembers={@([pscustomobject]@{RelativePath='data\keep.dat';SHA256=$keepHash},[pscustomobject]@{RelativePath='data\empty-one';SHA256='';EntryType='Directory'},[pscustomobject]@{RelativePath='tree\level1\level2';SHA256='';EntryType='Directory'})}
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$source;TargetPath=$target;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture owner';Evidence='explicit exact member confirmation';TransferChannel='C';ContentSelection='ExactMembers';Members=(& $newMembers)}

        # Contract 2: Members validation accepts leaf directory members and keeps every existing check for them.
        Assert-WsmMigrationSpec $spec -Assistive
        Check $true 'contract accepts file and leaf empty-directory members'
        function Copy-Spec($Value){ConvertFrom-WsmJson ($Value|ConvertTo-Json -Depth 20 -Compress)}
        $bad=Copy-Spec $spec;$bad.Members[1].SHA256=('a'*64);Reject {Assert-WsmMigrationSpec $bad -Assistive} 'a directory member carrying a content hash is rejected'
        $bad=Copy-Spec $spec;$bad.Members[1].EntryType='Symlink';Reject {Assert-WsmMigrationSpec $bad -Assistive} 'an unsupported EntryType is rejected'
        $bad=Copy-Spec $spec;$bad.Members[0]|Add-Member NoteProperty EntryType 'File';Reject {Assert-WsmMigrationSpec $bad -Assistive} 'a file member cannot declare an EntryType'
        $bad=Copy-Spec $spec;$bad.Members[1].RelativePath='..\outside';Reject {Assert-WsmMigrationSpec $bad -Assistive} 'a directory member escaping the root is rejected'
        $bad=Copy-Spec $spec;$bad.Members[2].RelativePath='data\EMPTY-ONE';Reject {Assert-WsmMigrationSpec $bad -Assistive} 'a case-colliding directory member is rejected'
        $bad=Copy-Spec $spec;$bad.Members[1].RelativePath='data';Reject {Assert-WsmMigrationSpec $bad -Assistive} 'a directory member that contains another member is rejected'
        $bad=Copy-Spec $spec;$bad.Members[1].RelativePath='C:\Windows\x';Reject {Assert-WsmMigrationSpec $bad -Assistive} 'an absolute directory member path is rejected'
        $bad=Copy-Spec $spec;$bad.TransferChannel='NonC';Reject {Assert-WsmMigrationSpec $bad -Assistive} 'directory members do not open non-C ExactMembers'

        # Consumers outside the packaging path: wizard file details and the static detail projection treat directory members as directories.
        $detailItem=[pscustomobject]@{ItemId='b6-detail';MigrationSpec=$spec};$details=Export-WsmWizardFileDetails -Item $detailItem -OutputDirectory (Join-Path $root 'details');$detailRecord=Read-WsmJson $details.Path
        $detailDirs=@($detailRecord.Entries|Where-Object {$_.directory});$detailFiles=@($detailRecord.Entries|Where-Object {-not $_.directory})
        Check ($details.Status -ceq 'Complete' -and $details.GapCount -eq 0 -and $detailDirs.Count -eq 2 -and $detailFiles.Count -eq 1 -and @($detailDirs|Where-Object {$_.path -ceq 'tree\level1\level2'}).Count -eq 1) ('wizard file details list directory members as directories without gaps: '+$details.Status+'/'+$details.GapCount)
        $projection=@(Get-WsmWizardFileDetails $detailItem)
        Check (@($projection|Where-Object {$_.status -ceq 'ReviewedExactDirectory'}).Count -eq 2 -and @($projection|Where-Object {$_.status -ceq 'ReviewedExactMember'}).Count -eq 1) 'detail projection labels directory members as reviewed empty directories, not hash-bound files'
        # Contract 3: package-time enumeration emits Directory artifacts and re-checks emptiness.
        $entries=@(Get-WsmScopeEntries $spec $packageWork)
        Check ($entries.Count -eq 3 -and @($entries|Where-Object {$_.Directory}).Count -eq 2 -and @($entries|Where-Object {$_.Directory -and $_.RelativePath -ceq 'data\empty-one'}).Count -eq 1 -and @($entries|Where-Object {$_.Directory -and $_.RelativePath -ceq 'tree\level1\level2'}).Count -eq 1 -and @($entries|Where-Object {-not $_.Directory -and $_.RelativePath -ceq 'data\keep.dat'}).Count -eq 1) 'enumeration yields the file plus exactly the two directory members (no implied ancestors)'
        [IO.File]::WriteAllText((Join-Path $externalLeaf 'late.txt'),'late');Reject {Get-WsmScopeEntries $spec $packageWork} 'a directory member that is no longer empty blocks packaging';[IO.File]::Delete((Join-Path $externalLeaf 'late.txt'))
        [IO.Directory]::Delete($deepLeaf);Reject {Get-WsmScopeEntries $spec $packageWork} 'an absent directory member blocks packaging';[void][IO.Directory]::CreateDirectory($deepLeaf)

        $sourceIdentity=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=(Get-WsmAssistiveMachineFingerprint);Name='FixtureSource';OS='Windows Server fixture';Version='10.0'}
        $targetIdentity=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='FixtureTarget';OS='Windows Server fixture';Version='10.0'}
        $script:sourceIdentity=$sourceIdentity
        $installRoot=Join-Path $root 'trusted-runtime';[void][IO.Directory]::CreateDirectory($installRoot)
        $sourceInventory=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='Inventory';Source=$sourceIdentity;Revision=1;Items=@()}
        $softwareEntry=[pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId 'Machine' '' 'Registry64' $installRoot 'fixture-product');Name='Fixture Runtime';Version='1';Publisher='Fixture';Architecture='Unknown';Scope='Machine';SID='';RegistryView='Registry64';Location=$installRoot;SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='HKLM\Software\Fixture';NaturalKey='fixture-product'};ObservedUtc=[DateTime]::UtcNow.ToString('o');CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
        $softwareCatalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$sourceIdentity.HostId;Fingerprint=$sourceIdentity.Fingerprint;Name=$sourceIdentity.Name;InventoryRevision=1;InventoryProjectionHash=''};CaptureContext=[pscustomobject]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($softwareEntry);Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=[DateTime]::UtcNow.ToString('o')});PreparationRequirements=@([pscustomobject]@{PreparationId=('prep-'+$softwareEntry.SoftwareId.Substring(3));SoftwareId=$softwareEntry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='Evidence inventory only.'});CatalogProjectionHash=('0'*64)}
        $sourceInventory|Add-Member NoteProperty SoftwareCatalog $softwareCatalog
        $softwareCatalog.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $sourceInventory;$softwareCatalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $softwareCatalog;Assert-WsmSoftwareCatalog $softwareCatalog -SourceInventory $sourceInventory|Out-Null

        # Contract 2: sealed plan binds the directory members (plan hash changes with them).
        $itemId=('c'*64);$pairId=[Guid]::NewGuid().ToString()
        $catalogItem=[pscustomobject][ordered]@{ItemId=$itemId;Category='Storage';Kind='FileScope';Name='Reviewed exact member set';NaturalKey='exact-members-fixture';Settings=[pscustomobject]@{SourcePath=$source;TargetPath=$target};SettingsHash=('d'*64);Dependencies=@();Status='Success';Adapter='FileScope';Decision='Include';Reason='explicitly reviewed';ReviewedBy='fixture reviewer';ReviewedUtc=Get-WsmUtc;RuleId='';Mapping='';Evidence='';Owner='fixture reviewer';Present=$true;MigrationSpec=$spec}
        $inventoryHash=('e'*64);$snapshotReference=[pscustomobject][ordered]@{Reference='assistive\snapshots\fixture.json';SHA256=$inventoryHash;CreatedUtc=Get-WsmUtc;InventoryRevision=1}
        $catalog=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion='0.4.0';Kind='Catalog';PairId=$pairId;SourceHostId=$sourceIdentity.HostId;SourceName=$sourceIdentity.Name;InventoryHash=$inventoryHash;InventoryRevision=1;DecisionRevision=1;Approval=$null;Items=@($catalogItem)}
        $catalog | Add-Member NoteProperty Assistive (New-WsmAssistiveCatalogContract -PairId $pairId -SourceReference $snapshotReference.Reference -SourceHash $inventoryHash -InventoryRevision 1 -Items @($catalogItem) -Prior $null)
        $planSeed=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString();PairId=$pairId;ApprovalId=[Guid]::NewGuid().ToString();Source=$sourceIdentity;Target=$targetIdentity;InventoryHash=$inventoryHash;InventoryRevision=1;DecisionRevision=1;Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);ApprovedUtc=Get-WsmUtc;Items=@([pscustomobject]@{ItemId=$itemId;Category='Storage';Kind='ManualItem';Name='Reviewed exact member set';NaturalKey='exact-members-fixture';Status='Success';Adapter='FileScope';Present=$true;Decision='Include';Reason='explicitly reviewed';MigrationSpec=$spec;Dependencies=@();Settings=[pscustomobject]@{};SettingsHash=('d'*64)})}
        $plan=New-WsmAssistiveMigrationPlanContract -Plan $planSeed -Catalog $catalog
        $planPath=Join-Path $root 'plan.json';Write-WsmJson $planPath $plan;$planHash=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $validatedPlan=Read-WsmMigrationPlan $planPath $planHash
        $sealedMembers=@($validatedPlan.Items[0].MigrationSpec.Members)
        Check ($sealedMembers.Count -eq 3 -and @($sealedMembers|Where-Object {$_.PSObject.Properties['EntryType'] -and $_.EntryType -ceq 'Directory'}).Count -eq 2) 'the sealed-plan reader keeps both directory members bound in the plan'
        $tamperedPlan=Copy-Spec $plan;$tamperedPlan.Items[0].MigrationSpec.Members=@($tamperedPlan.Items[0].MigrationSpec.Members|Where-Object {-not $_.PSObject.Properties['EntryType']})
        $tamperedPath=Join-Path $root 'plan-tampered.json';Write-WsmJson $tamperedPath $tamperedPlan
        Reject {Read-WsmMigrationPlan $tamperedPath $planHash} 'dropping directory members from a sealed plan breaks its hash binding'

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
        $directoryRows=@($rows|Where-Object Directory)
        Check ($package.Valid -and $rows.Count -eq 3 -and $directoryRows.Count -eq 2 -and @($directoryRows|Where-Object {$_.RelativePath -ceq 'data\empty-one' -and $null -eq $_.Data -and $_.Metadata}).Count -eq 1 -and @($directoryRows|Where-Object {$_.RelativePath -ceq 'tree\level1\level2' -and $null -eq $_.Data}).Count -eq 1 -and @($rows|Where-Object {-not $_.Directory -and $_.Data.Hash -ceq $keepHash}).Count -eq 1) 'CV2 package carries Directory=true artifacts (same form as WholeScope) for both members and the hashed file'

        $forged=Join-Path $root 'forged-package';Copy-Item -LiteralPath $package.Root -Destination $forged -Recurse
        $forgedIndex=Join-Path $forged 'artifacts.jsonl';$forgedRows=@(Read-WsmArtifactLines $forgedIndex $package.Manifest.ArtifactsHash);$rogue=$forgedRows|Where-Object {$_.Directory -and $_.RelativePath -ceq 'data\empty-one'}|Select-Object -First 1;$rogue=$rogue.PSObject.Copy();$rogue.RelativePath='data\rogue-dir'
        $forgedLines=@($forgedRows|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 20})+@($rogue|ConvertTo-Json -Compress -Depth 20);[IO.File]::WriteAllLines($forgedIndex,$forgedLines,(New-Object Text.UTF8Encoding($false)))
        $forgedManifestPath=Join-Path $forged 'manifest.json';$forgedManifest=Read-WsmJson $forgedManifestPath;$forgedManifest.ArtifactsHash=(Get-FileHash -LiteralPath $forgedIndex -Algorithm SHA256).Hash.ToLowerInvariant();$forgedManifest.Records=4;Write-WsmJson $forgedManifestPath $forgedManifest;$forgedHash=(Get-FileHash -LiteralPath $forgedManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Reject {Test-WsmMigrationPackage -ManifestPath $forgedManifestPath -ExpectedHash $forgedHash} 'package reader rejects a directory artifact outside the sealed member set'
        $forgedShort=Join-Path $root 'forged-short';Copy-Item -LiteralPath $package.Root -Destination $forgedShort -Recurse
        $shortIndex=Join-Path $forgedShort 'artifacts.jsonl';$shortLines=@($forgedRows|Where-Object {-not ($_.Directory -and $_.RelativePath -ceq 'tree\level1\level2')}|ForEach-Object {$_|ConvertTo-Json -Compress -Depth 20});[IO.File]::WriteAllLines($shortIndex,$shortLines,(New-Object Text.UTF8Encoding($false)))
        $shortManifestPath=Join-Path $forgedShort 'manifest.json';$shortManifest=Read-WsmJson $shortManifestPath;$shortManifest.ArtifactsHash=(Get-FileHash -LiteralPath $shortIndex -Algorithm SHA256).Hash.ToLowerInvariant();$shortManifest.Records=2;Write-WsmJson $shortManifestPath $shortManifest;$shortHash=(Get-FileHash -LiteralPath $shortManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Reject {Test-WsmMigrationPackage -ManifestPath $shortManifestPath -ExpectedHash $shortHash} 'package reader rejects a package that omits a sealed directory member'

        # Contract 4: restore creates the empty directories at the original location, owns only what it created,
        # and preserves a same-named external directory without taking it over.
        $externalTarget=Join-Path $target 'data\empty-one';[void][IO.Directory]::CreateDirectory($externalTarget)
        $paths=[pscustomobject]@{Root=$state;State=$null;Journal=$null};$restoreState=[pscustomobject]@{Items=@();PendingOperations=@()}
        function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){}
        $restored=Invoke-WsmAssistiveFileScopeRestore $package.Plan.Items[0] $package $paths $restoreState @{} $null
        $deepTarget=Join-Path $target 'tree\level1\level2'
        Check ($restored.Status -ceq 'Succeeded') 'restore of an ExactMembers set with directory members succeeds'
        Check ([IO.Directory]::Exists($deepTarget) -and @([IO.Directory]::EnumerateFileSystemEntries($deepTarget)).Count -eq 0) 'the nested empty directory exists at its original location and is empty'
        Check ((Get-FileHash -LiteralPath (Join-Path $target 'data\keep.dat') -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $keepHash) 'file bytes match the approved member hash'
        $ownedDirectories=@($restored.OwnedDirectories|ForEach-Object RelativePath)
        Check ($ownedDirectories -ccontains 'tree\level1\level2' -and $ownedDirectories -cnotcontains 'data\empty-one') 'ownership records only the directory the tool created'
        $directoryResult=@($restored.FileResults|Where-Object {$_.RelativePath -ceq 'tree\level1\level2'})
        $preservedResult=@($restored.FileResults|Where-Object {$_.RelativePath -ceq 'data\empty-one'})
        Check ($directoryResult.Count -eq 1 -and $directoryResult[0].Status -ceq 'DirectoryVerified') 'a created directory member reads back as DirectoryVerified'
        Check ($preservedResult.Count -eq 1 -and $preservedResult[0].Status -ceq 'DirectoryPreserved' -and [IO.Directory]::Exists($externalTarget)) 'a same-named external directory is preserved and not taken over'
        Write-Host ('PASS: '+$script:checks+' ExactMembers empty-directory contract, plan binding, CV2 artifact and original-location restore checks.')
    } $root
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
