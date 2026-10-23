#requires -Version 5.1
# N5：反例測試（15.3-2、15.3-10、15.2-4）。
#   15.3-2   C:\Data 與 X:\Data（subst 模擬的第二個卷）相對路徑相同，封裝成員、結果集、還原目的地三處不碰撞也不覆蓋。
#   15.3-10  混卷、重複卷、未知版本不可默默接受。
#   15.2-4   父子範圍重疊的核准計畫要拒絕。
# 用的是真正的 Manager 核准、Source 封存、封裝驗證與還原預覽；只替身：本機身分、Source 的 inventory 重掃、
# Win32_Volume（多加一個 subst 出來的 X: 卷）與 X: 的實體路徑解析（回報成另一個 HarddiskVolume，因為 subst 實際落在 C: 卷）。
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-n5-scope-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$idMarker=[IO.Path]::GetFileName($root)
$letter=[string](@('X','Y','Z','W','V','U','T','S','R','Q'|Where-Object {-not (Test-Path -LiteralPath ($_+':\'))})[0])
if(-not $letter){throw 'No free drive letter is available for the second-volume fixture.'}
$volumeRoot=Join-Path $root 'second-volume';[void][IO.Directory]::CreateDirectory($volumeRoot)
try {
  $substOutput=& subst.exe ($letter+':') $volumeRoot 2>&1
  if($LASTEXITCODE -ne 0){throw ('subst failed: '+$substOutput)}
  & $module {
    param($root,$letter)
    $script:checks=0
    function Check($condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
    function RejectExpected($action,[string]$expected,[string]$message){$actual='';try{& $action|Out-Null}catch{$actual=$_.Exception.Message};Check ($actual -ceq $expected) ($message+' [actual: '+$actual+']')}
    function RejectLike($action,[string]$pattern,[string]$message){$actual='';try{& $action|Out-Null}catch{$actual=$_.Exception.Message};Check ($actual -and $actual -like $pattern) ($message+' [actual: '+$actual+']')}
    function Sha([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}

    # ---- 固定的來源／目標身分與角色切換（只有身分是替身）
    $managerIdentity=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('c'*64);Name='FixtureManager';OS='Windows Server fixture';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
    $sourceIdentity=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='FixtureSource';OS='Windows Server fixture';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
    $targetIdentity=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='FixtureTarget';OS='Windows Server fixture';Version='10.0'}
    $script:role='Manager'
    function Get-WsmMachineIdentity { if($script:role -ceq 'Manager'){$managerIdentity}elseif($script:role -ceq 'Target'){$targetIdentity}else{$sourceIdentity} }
    function Assert-WsmMigrationHost($Identity,[string]$Fingerprint) { if($Identity.Fingerprint -cne $Fingerprint){throw 'Fixture host role/identity mismatch.'} }

    # ---- 第二個卷：subst 出來的磁碟在 Win32_Volume 看不到，所以替身化 Win32_Volume 與它的實體路徑（落在另一個 HarddiskVolume）。
    $secondDevice='\\?\Volume{33333333-3333-3333-3333-333333333333}\'
    $secondDrive=$letter+':'
    $realCim=Get-Command Get-CimInstance -CommandType Cmdlet
    $script:extraVolumes=@([pscustomobject]@{DriveLetter=$secondDrive;DeviceID=$secondDevice})
    function Get-CimInstance {param([string]$ClassName,[string]$ErrorAction);$rows=@(& $realCim -ClassName $ClassName -ErrorAction Stop);if($ClassName -ceq 'Win32_Volume'){$rows+=@($script:extraVolumes)};$rows}
    $script:physicalResolver=(Get-Command Get-WsmPhysicalPath -CommandType Function).ScriptBlock
    function Get-WsmPhysicalPath([string]$Path){
        if($script:role -ceq 'Manager'){throw 'Manager approval attempted a source-native physical path lookup.'}
        $full=[IO.Path]::GetFullPath($Path)
        # $script:physicalSplit：模擬「scope 底下有一段實際落在另一個卷」（掛載點或接合點把第二個卷的子目錄接到別的卷）。
        if($script:physicalSplit -and $full.StartsWith($script:secondDriveText+'\Data',[StringComparison]::OrdinalIgnoreCase)){return '\Device\HarddiskVolume77'+$full.Substring(2).TrimEnd('\')}
        if($full.StartsWith($script:secondDriveText+'\',[StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\') -ieq $script:secondDriveText){return '\Device\HarddiskVolume99'+$full.Substring(2).TrimEnd('\')}
        & $script:physicalResolver $Path
    }
    $script:secondDriveText=$secondDrive;$script:physicalSplit=$false

    # ---- 來源資料：兩個卷各有一份 Data，相對路徑相同（x.txt、sub\y.txt、空資料夾 empty）但位元組不同
    $cBase=Join-Path $root 'c-side';$cData=Join-Path $cBase 'Data';$xData=$secondDrive+'\Data'
    foreach($dir in @($cData,(Join-Path $cData 'sub'),(Join-Path $cData 'empty'),$xData,(Join-Path $xData 'sub'),(Join-Path $xData 'empty'))){[void][IO.Directory]::CreateDirectory($dir)}
    [IO.File]::WriteAllText((Join-Path $cData 'x.txt'),'C volume x');[IO.File]::WriteAllText((Join-Path $cData 'sub\y.txt'),'C volume y')
    [IO.File]::WriteAllText((Join-Path $xData 'x.txt'),'second volume x');[IO.File]::WriteAllText((Join-Path $xData 'sub\y.txt'),'second volume y')
    # same.txt：兩個卷同名且位元組完全相同（內容定址的 blob 可以共用，但成員列與還原目的地不能合併）。
    $sameBytes='identical bytes on both volumes';[IO.File]::WriteAllText((Join-Path $cData 'same.txt'),$sameBytes);[IO.File]::WriteAllText((Join-Path $xData 'same.txt'),$sameBytes)
    function New-ScopeSpec([string]$Path,[string]$Channel,[string]$Evidence){[pscustomobject]@{Adapter='FileScope';SourcePath=$Path;TargetPath=$Path;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture';Evidence=$Evidence;TransferChannel=$Channel;ContentSelection='WholeScope'}}
    $cDrive=[IO.Path]::GetPathRoot($cData).TrimEnd('\')
    $cVolume=Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop | Where-Object {$_.DriveLetter -and ([string]$_.DriveLetter).TrimEnd('\') -ieq $cDrive} | Select-Object -First 1
    if(-not $cVolume){throw 'No real drive-lettered Win32_Volume is available for the C-side fixture.'}
    function New-VolumeItem($Device,[string]$Letter){New-WsmItem $sourceIdentity.HostId Storage Volume $Device $Device ([pscustomobject]@{DeviceID=$Device;DriveLetter=$Letter;Label='fixture';FileSystem='NTFS';Capacity=[long]1000}) @() Success Volume}
    function New-SoftwareCatalogFor($Inventory){
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$sourceIdentity.HostId;Fingerprint=$sourceIdentity.Fingerprint;Name=$sourceIdentity.Name;InventoryRevision=1;InventoryProjectionHash=''};CaptureContext=[pscustomobject]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=[DateTime]::UtcNow.ToString('o')});PreparationRequirements=@();CatalogProjectionHash=('0'*64)}
        $Inventory|Add-Member NoteProperty SoftwareCatalog $catalog -Force
        $catalog.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $Inventory
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
        $catalog
    }
    $targetIdentityPath=Join-Path $root 'target-identity.json';Write-WsmJson $targetIdentityPath ([pscustomobject]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='TargetIdentity';HostId=$targetIdentity.HostId;Fingerprint=$targetIdentity.Fingerprint;Name=$targetIdentity.Name;OS=$targetIdentity.OS;Version=$targetIdentity.Version});$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash
    $script:caseNumber=0
    # 建立一個 Manager 工作區：匯入指定的 inventory 與規格，全部納入，回傳核准所需的東西。
    function New-ManagerCase([object[]]$VolumeItems,[object[]]$Specs){
        $script:caseNumber++;$caseRoot=Join-Path $root ('case-'+$script:caseNumber);$state=Join-Path $caseRoot 'manager-state';[void][IO.Directory]::CreateDirectory($state)
        $items=New-Object 'System.Collections.Generic.List[object]'
        foreach($volume in $VolumeItems){$items.Add($volume)}
        for($i=0;$i -lt $Specs.Count;$i++){$items.Add((New-WsmItem $sourceIdentity.HostId Storage FileScope ('Scope '+$i) ('n5-scope-'+$i) ([pscustomobject]@{SourcePath=$Specs[$i].SourcePath;TargetPath=$Specs[$i].TargetPath}) @() Success FileScope))}
        $inventory=New-WsmInventory $sourceIdentity 1 $items.ToArray();[void](New-SoftwareCatalogFor $inventory)
        $inventoryPath=Join-Path $caseRoot 'source-inventory.json';Write-WsmJson $inventoryPath $inventory;$inventoryHash=Sha $inventoryPath
        [void](Initialize-WsmWorkspace $state);[void](Import-WsmInventory -Workspace $state -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'FixtureTarget')
        $pairId=[string]((Get-WsmFleet $state).Pairs[0].PairId);$catalog=Get-WsmCatalog $state $pairId
        [void](Enable-WsmAssistiveMode $state $pairId $catalog.DecisionRevision);$catalog=Get-WsmCatalog $state $pairId
        $materialRel='assistive\materials\review.json';$materialPath=Join-Path $state $materialRel;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($materialPath));[IO.File]::WriteAllText($materialPath,'{"review":"explicit fixture"}')
        $catalog.Assistive.MaterialReferences=@([pscustomobject]@{Reference=$materialRel;SHA256=(Sha $materialPath);CreatedUtc=(Get-WsmUtc)});Write-WsmJson (Get-WsmCatalogPath $state $pairId) $catalog;$catalog=Get-WsmCatalog $state $pairId
        foreach($volumeItem in @($catalog.Items|Where-Object Kind -CEQ 'Volume')){Set-WsmDecision -Workspace $state -PairId $pairId -ItemId $volumeItem.ItemId -Decision Exclude -Reason 'Volume is evidence only.' -ExpectedRevision $catalog.DecisionRevision|Out-Null;$catalog=Get-WsmCatalog $state $pairId}
        $scopeCatalogItems=@($catalog.Items|Where-Object Kind -CEQ 'FileScope')
        Set-WsmDecision -Workspace $state -PairId $pairId -ItemId @($scopeCatalogItems|ForEach-Object ItemId) -Decision Include -Reason 'Owner reviewed local payload scope.' -ExpectedRevision $catalog.DecisionRevision|Out-Null;$catalog=Get-WsmCatalog $state $pairId
        for($i=0;$i -lt $Specs.Count;$i++){$id=[string]($scopeCatalogItems|Where-Object NaturalKey -CEQ ('n5-scope-'+$i)|Select-Object -ExpandProperty ItemId);$specPath=Join-Path $caseRoot ('spec-'+$i+'.json');Write-WsmJson $specPath $Specs[$i];Set-WsmMigrationSpec $state $pairId $id $specPath (Sha $specPath) $catalog.DecisionRevision|Out-Null;$catalog=Get-WsmCatalog $state $pairId}
        [pscustomobject]@{CaseRoot=$caseRoot;State=$state;PairId=$pairId;Catalog=$catalog;InventoryPath=$inventoryPath;InventoryHash=$inventoryHash}
    }
    function Approve-Case($Case,[string]$Name='plan.json'){
        $script:role='Manager'
        Approve-WsmMigrationPlan -Workspace $Case.State -PairId $Case.PairId -TargetIdentityPath $targetIdentityPath -TargetIdentityHash $targetIdentityHash -Path (Join-Path $Case.CaseRoot $Name) -ExpectedRevision (Get-WsmCatalog $Case.State $Case.PairId).DecisionRevision -PilotAcknowledgement 'ISOLATED-PILOT' -OfflineFullSet
    }
    $cVolumeItem=New-VolumeItem ([string]$cVolume.DeviceID) ([string]$cVolume.DriveLetter)
    $xVolumeItem=New-VolumeItem $secondDevice $secondDrive
    $specC=New-ScopeSpec $cData 'C' 'reviewed C volume data'
    $specX=New-ScopeSpec $xData 'NonC' 'reviewed second volume data'

    # ======================================================================== 15.3-2 同名相對路徑在兩個卷
    $case=New-ManagerCase @($cVolumeItem,$xVolumeItem) @($specC,$specX)
    $approval=Approve-Case $case
    $plan=Read-WsmMigrationPlan $approval.Path $approval.SHA256
    $planItems=@($plan.Items|Where-Object Decision -CEQ 'Include')
    $itemC=@($planItems|Where-Object {$_.MigrationSpec.SourcePath -ieq $cData})[0];$itemX=@($planItems|Where-Object {$_.MigrationSpec.SourcePath -ieq $xData})[0]
    Check ($planItems.Count -eq 2 -and $itemC.MigrationSpec.TransferChannel -ceq 'C' -and $itemX.MigrationSpec.TransferChannel -ceq 'NonC' -and $plan.Assistive.ApprovedLocalVolumes.Count -eq 2) 'Approval did not seal one C scope and one second-volume scope with their own volume bindings.'
    Check (@($plan.Assistive.ApprovedLocalVolumes|Where-Object {$_.DriveLetter -ceq $secondDrive -and $_.DeviceID -ceq $secondDevice}).Count -eq 1 -and @($plan.Assistive.ApprovedLocalVolumes|Where-Object DeviceID -CEQ ([string]$cVolume.DeviceID)).Count -eq 1) 'Approved volume bindings are not one per distinct volume.'
    $script:role='Source'
    $freshInventory=[pscustomobject]@{Path=(Join-Path $case.State ('assistive\snapshots\'+$case.InventoryHash+'.json'));SHA256=$case.InventoryHash}
    function Export-WsmInventory {param($SourceStateDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog)$script:freshInventory}
    $script:freshInventory=$freshInventory
    $export=Export-WsmMigrationPackageCore -PlanPath $approval.Path -ExpectedHash $approval.SHA256 -SourceStateDirectory $case.State -OutputDirectory (Join-Path $case.CaseRoot 'package-work') -ChunkBytes 65536
    $package=Test-WsmMigrationPackage -ManifestPath $export.ManifestPath -ExpectedHash $export.SHA256
    Check ($package.Valid -and $package.Manifest.SchemaVersion -eq 2 -and $package.Manifest.SourceCollectionProofs.Count -eq 2) 'The two-volume CV2 package was not sealed with one collection proof per scope.'

    # 封裝成員：兩個 scope 都有 x.txt 與 sub\y.txt，成員以 ItemId＋相對路徑區分，內容不互相覆蓋。
    $artifacts=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash)
    $rowsC=@($artifacts|Where-Object ItemId -CEQ $itemC.ItemId);$rowsX=@($artifacts|Where-Object ItemId -CEQ $itemX.ItemId)
    Check ($rowsC.Count -eq 6 -and $rowsX.Count -eq 6 -and $artifacts.Count -eq 12) ('Member count per scope is wrong (C='+$rowsC.Count+', second='+$rowsX.Count+', all='+$artifacts.Count+').')
    $keys=@($artifacts|ForEach-Object {$_.ItemId+'|'+$_.RelativePath.ToLowerInvariant()});Check (@($keys|Select-Object -Unique).Count -eq 12) 'Package members collide on ItemId plus relative path.'
    foreach($relative in @('x.txt','sub\y.txt')){
        $rc=@($rowsC|Where-Object RelativePath -CEQ $relative);$rx=@($rowsX|Where-Object RelativePath -CEQ $relative)
        Check ($rc.Count -eq 1 -and $rx.Count -eq 1 -and $rc[0].Data.Hash -cne $rx[0].Data.Hash) ('Same relative path '+$relative+' on two volumes was merged or shares one blob.')
    }
    $sameC=@($rowsC|Where-Object RelativePath -CEQ 'same.txt');$sameX=@($rowsX|Where-Object RelativePath -CEQ 'same.txt')
    Check ($sameC.Count -eq 1 -and $sameX.Count -eq 1 -and $sameC[0].Data.Hash -ceq $sameX[0].Data.Hash -and $sameC[0].ItemId -cne $sameX[0].ItemId) 'Identical bytes at the same relative path on two volumes must stay two member rows (one per ItemId).'
    $payloadFiles=@(Get-ChildItem -LiteralPath (Join-Path $package.Root 'payload') -File -Recurse)
    Check ($payloadFiles.Count -ge 4) 'Payload does not hold separate blobs for the four distinct file contents.'

    # 結果集：備份逐項結果以 ItemId 分列，各自的檔數與位元組數，不因相對路徑相同而合併。
    $sourceInventory=Read-WsmJson $case.InventoryPath
    $resultRows=@(Get-WsmBackupItemResultRows $plan $sourceInventory $artifacts $true)
    $resultC=@($resultRows|Where-Object ItemId -CEQ $itemC.ItemId);$resultX=@($resultRows|Where-Object ItemId -CEQ $itemX.ItemId)
    Check ($resultC.Count -eq 1 -and $resultX.Count -eq 1 -and $resultC[0].Status -ceq 'BackedUp' -and $resultX[0].Status -ceq 'BackedUp') 'Result set does not hold exactly one backed-up row per volume scope.'
    Check ([long]$resultC[0].Files -eq 3 -and [long]$resultX[0].Files -eq 3 -and [long]$resultC[0].Bytes -eq ('C volume x'.Length+'C volume y'.Length+$sameBytes.Length) -and [long]$resultX[0].Bytes -eq ('second volume x'.Length+'second volume y'.Length+$sameBytes.Length)) ('Result set counts mixed the two volumes (C files='+$resultC[0].Files+' bytes='+$resultC[0].Bytes+', second files='+$resultX[0].Files+' bytes='+$resultX[0].Bytes+').')
    # 還原目的地（預覽）：每一列的目的地都在自己 scope 的 TargetPath 底下，兩個卷的 x.txt 不指向同一個目的地。
    $script:role='Target'
    $placement=Get-WsmFilePlacementPreview -ManifestPath $export.ManifestPath -ExpectedHash $export.SHA256 -StateDirectory ''
    $placementC=@($placement.Rows|Where-Object ItemId -CEQ $itemC.ItemId);$placementX=@($placement.Rows|Where-Object ItemId -CEQ $itemX.ItemId)
    Check ($placement.Total -eq 12 -and $placementC.Count -eq 6 -and $placementX.Count -eq 6) 'Placement preview does not hold one row per member per volume.'
    Check (@($placementC|Where-Object {-not ($_.PreservedPath -ieq $cData -or $_.PreservedPath.StartsWith($cData+'\',[StringComparison]::OrdinalIgnoreCase))}).Count -eq 0 -and @($placementX|Where-Object {-not ($_.PreservedPath -ieq $xData -or $_.PreservedPath.StartsWith($xData+'\',[StringComparison]::OrdinalIgnoreCase))}).Count -eq 0) 'A placement row points outside its own volume scope.'
    Check (@($placement.Rows|ForEach-Object {$_.PreservedPath.ToLowerInvariant()}|Select-Object -Unique).Count -eq 12) 'Two placement rows share one destination.'
    # 還原目的地（寫入）：模擬新機（兩邊來源資料都不在），逐項走真正的還原預檢與寫入；兩個卷的同名檔案各回各的位置、位元組不交換。
    foreach($dir in @($cData,$xData)){Remove-Item -LiteralPath $dir -Recurse -Force}
    function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){ }
    function Assert-WsmCancellationBoundary($Token,[string]$Name){ }
    $identityMap=Resolve-WsmIdentityMap $package.Plan @{}
    $restoreState=[pscustomobject]@{Items=@();PendingOperations=@()};$restorePaths=[pscustomobject]@{Root=$case.CaseRoot;State=(Join-Path $case.CaseRoot 'restore-state.json');Journal=(Join-Path $case.CaseRoot 'restore-journal.jsonl')}
    foreach($restoreItem in @($itemC,$itemX)){
        $gap=Get-WsmAssistiveFileScopeRestoreGap $restoreItem $package $restoreState $true $null $null
        Check ($gap.Status -ceq 'Ready' -and $gap.Action -ceq 'RestoreNow') ('Restore gap for '+$restoreItem.MigrationSpec.SourcePath+' is not Ready: '+$gap.Action+'/'+$gap.Status+' '+$gap.Reason)
    }
    $restoreC=Invoke-WsmAssistiveFileScopeRestore $itemC $package $restorePaths $restoreState $identityMap $null
    $restoreX=Invoke-WsmAssistiveFileScopeRestore $itemX $package $restorePaths $restoreState $identityMap $null
    Check ($restoreC.Status -ceq 'Succeeded' -and $restoreX.Status -ceq 'Succeeded') ('Restore did not succeed for both volumes (C='+$restoreC.Status+', second='+$restoreX.Status+').')
    Check ([IO.File]::ReadAllText((Join-Path $cData 'x.txt')) -ceq 'C volume x' -and [IO.File]::ReadAllText((Join-Path $cData 'sub\y.txt')) -ceq 'C volume y' -and [IO.File]::ReadAllText((Join-Path $xData 'x.txt')) -ceq 'second volume x' -and [IO.File]::ReadAllText((Join-Path $xData 'sub\y.txt')) -ceq 'second volume y' -and [IO.File]::ReadAllText((Join-Path $cData 'same.txt')) -ceq $sameBytes -and [IO.File]::ReadAllText((Join-Path $xData 'same.txt')) -ceq $sameBytes) 'Restored bytes were swapped or overwritten across the two volumes.'
    Check (@(Get-ChildItem -LiteralPath $cData -Recurse -File).Count -eq 3 -and @(Get-ChildItem -LiteralPath $xData -Recurse -File).Count -eq 3 -and [IO.Directory]::Exists((Join-Path $cData 'empty')) -and [IO.Directory]::Exists((Join-Path $xData 'empty'))) 'A restore wrote extra or missing members on one of the volumes.'
    function Copy-Json($Value){$Value|ConvertTo-Json -Depth 100|ConvertFrom-Json}
    function TryMessage([scriptblock]$Action){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};$message}
    function ManifestFiles([string]$Directory){@(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter 'manifest*.json' -ErrorAction SilentlyContinue)}

    # ======================================================================== 15.3-10 混卷
    # (a) 封存當下 scope 底下有一段實際落在另一個卷：原生來源檢查拒絕，沒有封出任何 manifest。
    $script:role='Source'
    $bindings=@($plan.Assistive.ApprovedLocalVolumes)
    $control=Assert-WsmAssistiveSourceScope $itemX.MigrationSpec ApprovedLocalVolumes -Native -ApprovedVolumes $bindings
    Check ($control.Channel -ceq 'FullSet' -and $control.VolumeDeviceID -ceq $secondDevice -and $control.PhysicalVolumeRoot -ceq '\Device\HarddiskVolume99') 'Control: a scope entirely on its approved volume was not accepted by the native source check.'
    $script:physicalSplit=$true
    try{
        RejectExpected {Assert-WsmAssistiveSourceScope $itemX.MigrationSpec ApprovedLocalVolumes -Native -ApprovedVolumes $bindings} 'OfflineFullSet source path no longer resolves beneath its approved physical source volume.' 'A scope whose physical path left its approved volume was accepted by the native source check.'
        $splitOutput=Join-Path $case.CaseRoot 'package-work-split'
        $splitMessage=TryMessage {Export-WsmMigrationPackageCore -PlanPath $approval.Path -ExpectedHash $approval.SHA256 -SourceStateDirectory $case.State -OutputDirectory $splitOutput -ChunkBytes 65536}
        Check ($splitMessage -ceq 'OfflineFullSet source path no longer resolves beneath its approved physical source volume.' -and @(ManifestFiles $splitOutput).Count -eq 0) ('Export of a scope spanning two volumes was not refused before sealing: '+$splitMessage)
    }finally{$script:physicalSplit=$false}
    # (b) 範圍內有接合點通往另一個卷：擷取不跟隨，也沒有封出 manifest。
    $junction=Join-Path $cData 'crossing'
    & cmd.exe /c ('mklink /J "'+$junction+'" "'+$xData+'"') | Out-Null
    Check ([IO.Directory]::Exists($junction)) 'Fixture junction toward the second volume was not created.'
    try{
        $crossOutput=Join-Path $case.CaseRoot 'package-work-crossing'
        $crossMessage=TryMessage {Export-WsmMigrationPackageCore -PlanPath $approval.Path -ExpectedHash $approval.SHA256 -SourceStateDirectory $case.State -OutputDirectory $crossOutput -ChunkBytes 65536}
        Check ($crossMessage -and @(ManifestFiles $crossOutput).Count -eq 0) ('A junction from the C scope into the second volume was followed or silently accepted; message=['+$crossMessage+']')
        Check ($crossMessage -like '*eparse*') ('The junction was refused for an unexpected reason: '+$crossMessage)
    }finally{& cmd.exe /c ('rmdir "'+$junction+'"') | Out-Null}
    Check (-not [IO.Directory]::Exists($junction) -and [IO.File]::Exists((Join-Path $xData 'x.txt'))) 'Removing the fixture junction damaged the second volume.'
    # (c) 讀取端：收集證明把第二個卷的路徑指到另一個卷（物理根與路徑不在同一卷）。
    function Test-ManifestMutation([string]$Label,[scriptblock]$Mutate,[string]$Expected,[string]$Message){
        $probe=Join-Path $case.CaseRoot ('mut-'+$Label);Copy-Item -LiteralPath $package.Root -Destination $probe -Recurse
        $probeManifest=Join-Path $probe 'manifest.json';$mutable=Read-WsmJson $probeManifest
        & $Mutate $mutable $probe
        Write-WsmJson $probeManifest $mutable
        RejectExpected {Test-WsmMigrationPackage -ManifestPath $probeManifest -ExpectedHash (Sha $probeManifest)} $Expected $Message
    }
    Test-ManifestMutation 'proof-other-volume' {param($m,$dir) $proof=@($m.SourceCollectionProofs|Where-Object ItemId -CEQ $itemX.ItemId)[0];$proof.PhysicalPath='\Device\HarddiskVolume77\Data'} 'OfflineFullSet collection proof does not match the approved local source volume.' 'Reader accepted a collection proof whose physical path lies on a different volume than its approved physical root.'
    Test-ManifestMutation 'proof-other-device' {param($m,$dir) $proof=@($m.SourceCollectionProofs|Where-Object ItemId -CEQ $itemX.ItemId)[0];$proof.VolumeDeviceID=[string]$cVolume.DeviceID} 'OfflineFullSet collection proof does not match the approved local source volume.' 'Reader accepted a second-volume proof that claims the C volume device.'
    Test-ManifestMutation 'proof-wrong-channel' {param($m,$dir) $proof=@($m.SourceCollectionProofs|Where-Object ItemId -CEQ $itemX.ItemId)[0];$proof.Channel='NonC'} 'OfflineFullSet collection proof does not match the approved local source volume.' 'Reader accepted a proof channel other than FullSet.'
    # (d) 核准端：來源與目標在不同的卷（混卷搬移）、或 scope 所在的卷不在可信 inventory。
    $script:role='Manager'
    $mixSpec=New-ScopeSpec $cData 'C' 'source on C, target on second volume';$mixSpec.TargetPath=$secondDrive+'\Moved'
    $mixCase=New-ManagerCase @($cVolumeItem,$xVolumeItem) @($mixSpec)
    RejectExpected {Approve-Case $mixCase 'mixed.json'} 'OfflineFullSet requires the approved original logical source and target paths to be identical.' 'Approval accepted a scope whose source and target are on different volumes.'
    Check (-not [IO.File]::Exists((Join-Path $mixCase.CaseRoot 'mixed.json'))) 'A refused mixed-volume approval left a plan file.'
    $missingVolumeCase=New-ManagerCase @($cVolumeItem) @($specC,$specX)
    RejectExpected {Approve-Case $missingVolumeCase 'missing-volume.json'} 'Trusted source inventory does not identify exactly one volume for the approved FileScope.' 'Approval accepted a scope on a volume absent from the trusted inventory.'

    # ======================================================================== 15.3-10 重複卷
    # 同一個卷（同一個 DeviceID）在可信 inventory 內用兩個代號出現（兩個項目的 NaturalKey 不同，所以不會被重複 ItemId 擋下）。
    $aliasVolume=New-WsmItem $sourceIdentity.HostId Storage Volume 'alias-volume' 'alias-volume' ([pscustomobject]@{DeviceID=[string]$cVolume.DeviceID;DriveLetter=$secondDrive;Label='alias';FileSystem='NTFS';Capacity=[long]1000}) @() Success Volume
    $dupCase=New-ManagerCase @($cVolumeItem,$aliasVolume) @($specC,$specX)
    RejectExpected {Approve-Case $dupCase 'duplicate-volume.json'} 'Trusted source inventory names the same volume (DeviceID) under more than one volume entry or drive letter.' 'Approval accepted one volume appearing under two drive letters.'
    Check (-not [IO.File]::Exists((Join-Path $dupCase.CaseRoot 'duplicate-volume.json'))) 'A refused duplicate-volume approval left a plan file.'
    # 同一個代號出現兩次且對應不同卷。
    $letterTwice=New-VolumeItem $secondDevice ([string]$cVolume.DriveLetter)
    $letterCase=New-ManagerCase @($cVolumeItem,$letterTwice) @($specC)
    RejectExpected {Approve-Case $letterCase 'duplicate-letter.json'} 'Trusted source inventory does not identify exactly one volume for the approved FileScope.' 'Approval accepted one drive letter naming two volumes.'
    # 讀取端：封存計畫裡的綁定本身就把同一個卷綁到兩個代號（計畫與證明一起被改成一致，其他逐項檢查都會通過）。
    Check ((TryMessage {Assert-WsmAssistiveCollectionProofs $package.Manifest $package.Plan}) -ceq '') 'Control: the genuine two-volume package no longer passes the collection proof reader.'
    $planDup=Copy-Json $package.Plan;$manifestDup=Copy-Json $package.Manifest
    @($planDup.Assistive.ApprovedLocalVolumes|Where-Object DriveLetter -CEQ $secondDrive)[0].DeviceID=[string]$cVolume.DeviceID
    @($manifestDup.SourceCollectionProofs|Where-Object ItemId -CEQ $itemX.ItemId)[0].VolumeDeviceID=[string]$cVolume.DeviceID
    RejectExpected {Assert-WsmAssistiveCollectionProofs $manifestDup $planDup} 'OfflineFullSet approved volume bindings name one volume under more than one drive letter.' 'Reader accepted bindings that name one volume under two drive letters.'
    $planLetter=Copy-Json $package.Plan;$manifestLetter=Copy-Json $package.Manifest
    @($planLetter.Assistive.ApprovedLocalVolumes|Where-Object DriveLetter -CEQ $secondDrive)[0].DriveLetter=[string]$cVolume.DriveLetter
    RejectExpected {Assert-WsmAssistiveCollectionProofs $manifestLetter $planLetter} 'OfflineFullSet approved volume bindings name one drive letter under more than one volume.' 'Reader accepted bindings that name one drive letter under two volumes.'
    # 對照：同一個卷上的多個 scope 共用同一組（DeviceID，代號）是正常的，不能被誤擋。
    $sameVolume=@([pscustomobject]@{DeviceID=$secondDevice;DriveLetter='X:'},[pscustomobject]@{DeviceID=$secondDevice.ToUpperInvariant();DriveLetter='x:'})
    Check ((TryMessage {Assert-WsmAssistiveVolumeBindingsUnique $sameVolume}) -ceq '') 'Two scopes on one volume (same DeviceID and letter, any case) were refused as a duplicate volume.'
    # 計畫契約本身：同一個項目綁定兩次、綁定數量與 scope 數不符。
    $planBindingTwice=Copy-Json $package.Plan;$planBindingTwice.Assistive.ApprovedLocalVolumes=@($planBindingTwice.Assistive.ApprovedLocalVolumes[0],$planBindingTwice.Assistive.ApprovedLocalVolumes[0])
    Check ((TryMessage {Assert-WsmAssistiveContract $planBindingTwice MigrationPlan}) -ne '') 'Plan contract accepted a volume binding repeated for one FileScope.'

    # ======================================================================== 15.3-10 未知版本：拒絕，不可默默接受或忽略
    $planNewer=Copy-Json $package.Plan;$planNewer.Assistive.ContractVersion=3
    Check ((TryMessage {Assert-WsmAssistiveContract $planNewer MigrationPlan}) -ne '') 'Plan contract accepted an Assistive ContractVersion newer than this reader supports.'
    Test-ManifestMutation 'schema-3' {param($m,$dir) $m.SchemaVersion=3} 'Schema 3 requires tool version 0.4.0 and a Catalog or MigrationPlan envelope.' 'Reader accepted a package manifest with an unknown schema version.'
    Test-ManifestMutation 'offline-contract-2' {param($m,$dir) $m.OfflineFullSet.ContractVersion=2} 'Invalid OfflineFullSet package envelope; CV2 requires a bounded complete full set with portable controls and no base.' 'Reader accepted an OfflineFullSet envelope with an unknown contract version.'
    Test-ManifestMutation 'offline-unknown-field' {param($m,$dir) $m.OfflineFullSet|Add-Member NoteProperty FutureFeature $true -Force} 'Unknown contract field: FutureFeature' 'Reader silently ignored an unknown OfflineFullSet field instead of refusing it.'
    Test-ManifestMutation 'drop-envelope' {param($m,$dir) [void]$m.PSObject.Properties.Remove('OfflineFullSet')} 'OfflineFullSet package envelope is missing its CV2 proof.' 'Reader accepted a CV2 package whose OfflineFullSet envelope was removed.'
    Test-ManifestMutation 'controls-schema-2' {param($m,$dir) $indexPath=Join-Path $dir 'controls\index.json';$index=Read-WsmJson $indexPath;$index.SchemaVersion=2;Write-WsmJson $indexPath $index;$m.OfflineFullSet.ControlIndexHash=Sha $indexPath} 'OfflineFullSet control index is incomplete, oversized or bound to another source snapshot.' 'Reader accepted a control index with an unknown schema version.'

    # ======================================================================== 15.2-4 父子範圍重疊
    # 核准計畫不可同時包含父資料夾與它底下的子資料夾兩個獨立範圍（也不可同一路徑兩次、大小寫不同的同一路徑、或精確成員落在另一個範圍底下）。
    $script:role='Manager'
    $appDir=Join-Path $cBase 'App';$appData=Join-Path $appDir 'Data';[void][IO.Directory]::CreateDirectory($appData)
    [IO.File]::WriteAllText((Join-Path $appData 'f.txt'),'child file');[IO.File]::WriteAllText((Join-Path $appDir 'a.txt'),'parent file')
    $specApp=New-ScopeSpec $appDir 'C' 'reviewed parent scope';$specAppData=New-ScopeSpec $appData 'C' 'reviewed child scope'
    $specAppUpper=New-ScopeSpec $appData.ToUpperInvariant() 'C' 'same child path, different case'
    $specExactParent=[pscustomobject]@{Adapter='FileScope';SourcePath=$appDir;TargetPath=$appDir;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture';Evidence='reviewed exact member under the child scope';TransferChannel='C';ContentSelection='ExactMembers';Members=@([pscustomobject]@{RelativePath='Data\f.txt';SHA256=(Sha (Join-Path $appData 'f.txt'))})}
    $overlapExpected='Migration scopes have overlapping destinations.'
    $overlapCases=@(
        @{Label='parent then child';Specs=@($specApp,$specAppData)},
        @{Label='child then parent';Specs=@($specAppData,$specApp)},
        @{Label='same path twice';Specs=@($specApp,$specApp)},
        @{Label='child path in different case';Specs=@($specApp,$specAppUpper)},
        @{Label='exact member below a whole-scope child';Specs=@($specExactParent,$specAppData)}
    )
    foreach($overlapCase in $overlapCases){
        $overlap=New-ManagerCase @($cVolumeItem) @($overlapCase.Specs)
        $planName='overlap-'+($overlapCase.Label -replace '[^a-z]','-')+'.json'
        RejectExpected {Approve-Case $overlap $planName} $overlapExpected ('Approval accepted overlapping scopes ('+$overlapCase.Label+').')
        $overlapCatalog=Get-WsmCatalog $overlap.State $overlap.PairId
        Check (-not [IO.File]::Exists((Join-Path $overlap.CaseRoot $planName)) -and -not $overlapCatalog.Approval) ('A refused overlapping approval ('+$overlapCase.Label+') left a plan file or an approval record.')
    }
    # 對照：名稱只是前綴相同的兄弟資料夾（App 與 AppData）不是父子，必須照常核准；不同卷上同名的 Data 也是（15.3-2）。
    $appSibling=Join-Path $cBase 'AppData';[void][IO.Directory]::CreateDirectory($appSibling);[IO.File]::WriteAllText((Join-Path $appSibling 'z.txt'),'sibling file')
    $siblingCase=New-ManagerCase @($cVolumeItem) @($specApp,(New-ScopeSpec $appSibling 'C' 'reviewed sibling scope'))
    $siblingApproval=Approve-Case $siblingCase 'sibling.json'
    $siblingPlan=Read-WsmMigrationPlan $siblingApproval.Path $siblingApproval.SHA256
    Check (@($siblingPlan.Items|Where-Object Decision -CEQ 'Include').Count -eq 2 -and $siblingPlan.Assistive.ApprovedLocalVolumes.Count -eq 2) 'Sibling scopes that only share a name prefix were refused or not both sealed.'

    Write-Host ('PASS: '+$script:checks+' scope/volume counterexamples (same relative paths on two volumes across package members, result set and restore destinations; mixed, duplicate and unknown-version volume contracts; parent/child scope overlap).')
  } $root $letter
} finally {
  foreach($mapping in @(& subst.exe 2>&1|Where-Object {([string]$_).Contains($idMarker)})){$mappedLetter=([string]$mapping).Substring(0,2);& subst.exe $mappedLetter /d 2>&1|Out-Null}
  $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
  if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'wsm-n5-scope-*'){throw 'Unsafe cleanup path.'}
  if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
