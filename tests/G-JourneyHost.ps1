#requires -Version 5.1
# Test-side host for the offline restore journey (G). It runs one phase per child
# process. It never edits product bytes: the module is imported unchanged from the
# immutable snapshot and only module-scope function replacements (identity,
# platform observation, media class, one Service adapter boundary and one crash
# hook) are installed after the import. Everything is ASCII on purpose.
param(
    [Parameter(Mandatory)][ValidateSet('SourceInventory','ManagerApprove','SourceBackup','TargetSeedInventory','TargetConsole')][string]$Phase,
    [Parameter(Mandatory)][string]$Config,
    [string]$ReadyPath='',
    [string]$StopFile='',
    [string]$Workspace='',
    [int]$SeedRevision=1,
    [int]$SeedAgeHours=0,
    [switch]$SeedExtra
)
$ErrorActionPreference='Stop'
$cfg=Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$snapshotRoot=[IO.Path]::GetFullPath([string]$cfg.SnapshotRoot).TrimEnd([char]92)
if(([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd([char]92)) -ine $snapshotRoot){throw 'The host script is not running from the declared immutable snapshot.'}
# Every phase imports the execution copy: the snapshot's src bytes plus a test-only overlay appended to the psm1
# (inert unless WSM_G_OVERLAY=1). The product binds approvals to the installed tool bytes, so Source, Manager and
# Target must all run the same bytes. The pristine snapshot itself is never imported or modified.
$moduleRoot=[IO.Path]::GetFullPath([string]$cfg.ExecRoot).TrimEnd([char]92)
$moduleSrc=Join-Path $moduleRoot 'src'
$modulePath=Join-Path $moduleSrc 'WindowsServerMigration.psd1'
$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
if([IO.Path]::GetFullPath($module.ModuleBase).TrimEnd([char]92) -ine $moduleSrc.TrimEnd([char]92)){throw 'Module was not imported from the declared root.'}
function Write-PhaseResult([string]$Name,$Value){
    $path=Join-Path ([string]$cfg.RunDir) ('phase-'+$Name+'.json')
    [IO.File]::WriteAllText($path,($Value|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
}
function Read-PhaseResult([string]$Name){
    Get-Content -LiteralPath (Join-Path ([string]$cfg.RunDir) ('phase-'+$Name+'.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
}
$overrideScript=Join-Path $PSScriptRoot 'G-JourneyOverrides.ps1'

try{
switch($Phase){

'SourceInventory' {
    & $module {
        param($cfg,$overridePath)
        . $overridePath
        Install-GIdentity -Role Source
        $enrolled=Initialize-WsmOutputWorkspace -WorkRoot ([string]$cfg.WsSource) -Role Source
        $sourceHostId=[string]$enrolled.HostId
        $data=[string]$cfg.SrcData;$neighbor=[string]$cfg.SrcNeighbor
        foreach($directory in @($data,(Join-Path $data 'empty-dir'),(Join-Path $data 'nested'),$neighbor)){[void][IO.Directory]::CreateDirectory($directory)}
        $utf8=New-Object Text.UTF8Encoding($false)
        $chineseName=[string]([char]0x4E2D)+[char]0x6587+' '+[char]0x6E2C+[char]0x8A66+' '+[char]0x6A94+[char]0x6848+'.txt'
        [IO.File]::WriteAllText((Join-Path $data 'general.txt'),('G general payload '+[string]$cfg.RunId),$utf8)
        [IO.File]::WriteAllText((Join-Path $data $chineseName),('G chinese-named payload '+[string]$cfg.RunId),$utf8)
        [IO.File]::WriteAllText((Join-Path (Join-Path $data 'nested') 'inner file.cfg'),('G nested payload '+[string]$cfg.RunId),$utf8)
        $dllBytes=New-Object byte[] 4096;(New-Object Random 20261021).NextBytes($dllBytes);[IO.File]::WriteAllBytes((Join-Path $data 'Contoso.Business.Core.dll'),$dllBytes)
        [IO.File]::WriteAllText((Join-Path $neighbor 'neighbor-unselected.txt'),'G neighbor payload that must never be written on the Target',$utf8)
        $specs=@(
            [pscustomobject][ordered]@{Adapter='FileScope';SourcePath=$data;TargetPath=$data;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='G journey owner';Evidence='G journey reviewed C file scope';TransferChannel='C';ContentSelection='WholeScope'},
            [pscustomobject][ordered]@{Adapter='FileScope';SourcePath=$neighbor;TargetPath=$neighbor;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='G journey owner';Evidence='G journey reviewed neighbor scope that stays unselected';TransferChannel='C';ContentSelection='WholeScope'}
        )
        foreach($spec in $specs){Assert-WsmMigrationSpec $spec -Assistive}
        $source=[pscustomobject]@{HostId=$sourceHostId;Fingerprint=[string]$enrolled.Profile.Fingerprint;Name='G-Source'}
        $drive=[IO.Path]::GetPathRoot($data).TrimEnd('\')
        $nativeVolume=Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop | Where-Object {$_.DriveLetter -and ([string]$_.DriveLetter).TrimEnd('\') -ieq $drive} | Select-Object -First 1
        if(-not $nativeVolume){throw 'No drive-lettered Win32_Volume is available for the C volume binding.'}
        $items=New-Object 'System.Collections.Generic.List[object]'
        $items.Add((New-WsmItem $sourceHostId Storage Volume ([string]$nativeVolume.DeviceID) ([string]$nativeVolume.DeviceID) ([pscustomobject]@{DeviceID=[string]$nativeVolume.DeviceID;DriveLetter=[string]$nativeVolume.DriveLetter;Label=[string]$nativeVolume.Label;FileSystem=[string]$nativeVolume.FileSystem;Capacity=[long]$nativeVolume.Capacity}) @() Success Volume))
        $items.Add((New-WsmItem $sourceHostId Storage FileScope 'G selected scope' 'g-selected-scope' ([pscustomobject]@{SourcePath=$specs[0].SourcePath;TargetPath=$specs[0].TargetPath}) @() Success FileScope))
        $items.Add((New-WsmItem $sourceHostId Storage FileScope 'G neighbor scope' 'g-neighbor-scope' ([pscustomobject]@{SourcePath=$specs[1].SourcePath;TargetPath=$specs[1].TargetPath}) @() Success FileScope))
        $items.Add((New-WsmItem $sourceHostId Services Service 'G journey service' 'GJourneyService' ([pscustomobject]@{Name='GJourneyService';Status='Observed'}) @() Success Service))
        $inventory=New-WsmInventory $source 1 $items.ToArray()
        $now=[DateTime]::UtcNow.ToString('o')
        function New-GSoftwareEntry([string]$IdSuffix,[string]$Name,[string]$Version){
            [pscustomobject][ordered]@{SoftwareId=('sw-'+$IdSuffix.PadLeft(32,'0'));Name=$Name;Version=$Version;Publisher='G Test';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location=('fixture:'+$Name);SourceKind='Registry';Evidence=[pscustomobject]@{Probe='Uninstall'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
        }
        $entries=@((New-GSoftwareEntry 'a1' 'G Common Runtime' '1.0.0'),(New-GSoftwareEntry 'b2' 'G Controls Only Product' '2.0.0'))
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$source.HostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=''};CaptureContext=[pscustomobject]@{CapturedUtc=$now;CaptureIdentity='g journey fixture';AccountContext='Unknown';CaptureHost='g-journey';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=$entries;Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=2;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=$now});PreparationRequirements=@(foreach($entry in $entries){[pscustomobject]@{PreparationId=('prep-'+$entry.SoftwareId.Substring(3));SoftwareId=$entry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus=$entry.CaptureStatus;ConsumerItemIds=@($entry.ItemIds);Owner='';Reason='G journey fixture evidence only.'}});CatalogProjectionHash=('0'*64)}
        $inventory|Add-Member NoteProperty SoftwareCatalog $catalog
        $catalog.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $inventory
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
        Assert-WsmSoftwareCatalog $catalog -SourceInventory $inventory|Out-Null
        $inventoryPath=Join-Path ([string]$cfg.RunDir) 'source-inventory.json'
        Write-WsmJson $inventoryPath $inventory
        $inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $selectedSpecPath=Join-Path ([string]$cfg.RunDir) 'spec-selected.json';Write-WsmJson $selectedSpecPath $specs[0]
        $neighborSpecPath=Join-Path ([string]$cfg.RunDir) 'spec-neighbor.json';Write-WsmJson $neighborSpecPath $specs[1]
        $supplement=[pscustomobject][ordered]@{ServiceType='Win32OwnProcess';ErrorControl='Normal';LoadOrderGroup='';DelayedAutoStart=$false;FailureActions=[pscustomobject][ordered]@{ResetPeriodSeconds=0;RebootMessage='';Command='';Actions=@()};FailureActionsOnNonCrashFailures=$false;ServiceSidType='None';RequiredPrivileges=@();Environment=@();Triggers=@()}
        $serviceSpec=[pscustomobject][ordered]@{Adapter='Service';AccountMode='UserPassword';SecretRef=[string]$cfg.SecretRef;Owner='G journey owner';Evidence='Reviewed G journey service; the SecretRef is reviewed and carries no secret';DesiredFinalState='Automatic';Desired=[pscustomobject][ordered]@{Name='GJourneyService';DisplayName='G Journey Service';Account=[string]$cfg.ServiceAccount;BinaryPathName='C:\GFixture\gservice.exe';Dependencies=@();Description='G journey controlled service';Supplement=$supplement}}
        $serviceSpecPath=Join-Path ([string]$cfg.RunDir) 'spec-service.json';Write-WsmJson $serviceSpecPath $serviceSpec
        $files=@(Get-ChildItem -LiteralPath $data -Recurse -File | ForEach-Object {[pscustomobject]@{Relative=$_.FullName.Substring($data.TrimEnd('\').Length+1);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant();Bytes=$_.Length}})
        $dirs=@(Get-ChildItem -LiteralPath $data -Recurse -Directory | ForEach-Object {$_.FullName.Substring($data.TrimEnd('\').Length+1)})
        [pscustomobject]@{SourceHostId=$sourceHostId;SourceFingerprint=[string]$enrolled.Profile.Fingerprint;InventoryPath=$inventoryPath;InventoryHash=$inventoryHash;SelectedSpecPath=$selectedSpecPath;NeighborSpecPath=$neighborSpecPath;ServiceSpecPath=$serviceSpecPath;SelectedKey='g-selected-scope';NeighborKey='g-neighbor-scope';ServiceKey='GJourneyService';VolumeDeviceId=[string]$nativeVolume.DeviceID;SourceFiles=$files;SourceDirectories=$dirs;ChineseName=$chineseName;NeighborFile=(Join-Path $neighbor 'neighbor-unselected.txt')}
    } $cfg $overrideScript | ForEach-Object { Write-PhaseResult 'source-inventory' $_ }
}

'ManagerApprove' {
    $inv=Read-PhaseResult 'source-inventory'
    $tgt=Read-PhaseResult 'target-enroll'
    & $module {
        param($cfg,$inv,$tgt,$overridePath)
        . $overridePath
        Install-GIdentity -Role Manager
        [void](Initialize-WsmOutputWorkspace ([string]$cfg.WsManager) Manager)
        Initialize-WsmWorkspace ([string]$cfg.WsManager)|Out-Null
        $catalog=Import-WsmInventory ([string]$cfg.WsManager) ([string]$inv.InventoryPath) ([string]$inv.InventoryHash) 'G-Target'
        $pairId=[string]$catalog.PairId
        $catalog=Enable-WsmAssistiveMode ([string]$cfg.WsManager) $pairId $catalog.DecisionRevision
        $catalog=Get-WsmCatalog ([string]$cfg.WsManager) $pairId
        $byKey=@{};foreach($item in $catalog.Items){$byKey[[string]$item.NaturalKey]=$item}
        $volume=@($catalog.Items|Where-Object Kind -CEQ 'Volume')[0]
        $selected=$byKey[[string]$inv.SelectedKey];$neighbor=$byKey[[string]$inv.NeighborKey];$service=$byKey[[string]$inv.ServiceKey]
        if(-not $selected -or -not $neighbor -or -not $service -or -not $volume){throw 'Manager catalog does not hold the expected G items.'}
        Set-WsmDecision -Workspace ([string]$cfg.WsManager) -PairId $pairId -ItemId $volume.ItemId -Decision Exclude -Reason 'Volume is evidence only and not a migration payload.' -ExpectedRevision $catalog.DecisionRevision|Out-Null
        $catalog=Get-WsmCatalog ([string]$cfg.WsManager) $pairId
        Set-WsmDecision -Workspace ([string]$cfg.WsManager) -PairId $pairId -ItemId $neighbor.ItemId -Decision Exclude -Reason 'Neighbor scope is deliberately left unselected for the G journey.' -ExpectedRevision $catalog.DecisionRevision|Out-Null
        $catalog=Get-WsmCatalog ([string]$cfg.WsManager) $pairId
        Set-WsmDecision -Workspace ([string]$cfg.WsManager) -PairId $pairId -ItemId @($selected.ItemId,$service.ItemId) -Decision Include -Reason 'Owner reviewed the G journey selection.' -ExpectedRevision $catalog.DecisionRevision|Out-Null
        foreach($pair in @(@($selected,[string]$inv.SelectedSpecPath),@($service,[string]$inv.ServiceSpecPath))){
            $catalog=Get-WsmCatalog ([string]$cfg.WsManager) $pairId
            Set-WsmMigrationSpec ([string]$cfg.WsManager) $pairId $pair[0].ItemId $pair[1] (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash $catalog.DecisionRevision|Out-Null
        }
        $catalog=Get-WsmCatalog ([string]$cfg.WsManager) $pairId
        $planPath=Join-Path ([string]$cfg.RunDir) 'approved-plan.json'
        $approval=Approve-WsmMigrationPlan -Workspace ([string]$cfg.WsManager) -PairId $pairId -TargetIdentityPath ([string]$tgt.IdentityPath) -TargetIdentityHash ([string]$tgt.IdentityHash) -Path $planPath -ExpectedRevision $catalog.DecisionRevision -PilotAcknowledgement 'ISOLATED-PILOT' -OfflineFullSet
        $plan=Read-WsmMigrationPlan $approval.Path $approval.SHA256
        if([int]$plan.Assistive.ContractVersion -ne 2 -or [string]$plan.Assistive.SourcePolicy -cne 'ApprovedLocalVolumes'){throw 'Approved plan is not a CV2 ApprovedLocalVolumes plan.'}
        $included=@($plan.Items|Where-Object Decision -CEQ 'Include')
        [pscustomobject]@{PairId=$pairId;PlanPath=[string]$approval.Path;PlanHash=[string]$approval.SHA256;SelectedItemId=[string]$selected.ItemId;NeighborItemId=[string]$neighbor.ItemId;ServiceItemId=[string]$service.ItemId;IncludedItemIds=@($included|ForEach-Object ItemId);TargetFingerprint=[string]$plan.Target.Fingerprint;SourceFingerprint=[string]$plan.Source.Fingerprint;ManagerSourceSnapshotHash=[string]$plan.Assistive.SourceSnapshotHash}
    } $cfg $inv $tgt $overrideScript | ForEach-Object { Write-PhaseResult 'manager-approve' $_ }
}

'SourceBackup' {
    $inv=Read-PhaseResult 'source-inventory'
    $approve=Read-PhaseResult 'manager-approve'
    & $module {
        param($cfg,$inv,$approve,$overridePath)
        . $overridePath
        Install-GIdentity -Role Source
        Install-GSourceInventory -InventoryPath ([string]$inv.InventoryPath)
        Install-GRemovableMedia
        $imported=Import-WsmWizardApprovedPlan ([string]$cfg.WsSource) Source ([string]$approve.PlanPath) ([string]$approve.PlanHash)
        if([string]$imported.Status -cne 'ImportedVerified'){throw 'Source did not import the approved plan.'}
        $backupOperation=[Guid]::NewGuid().ToString('D')
        $backup=Invoke-WsmWizardStartBackup -Workspace ([string]$cfg.WsSource) -PairId ([string]$approve.PairId) -OperationId $backupOperation -DeliveryMode Directory -VolumeBytes 0 -Jobs @()
        if([string]$backup.Status -cne 'Delivered' -or [string]$backup.Delivery.Mode -cne 'Directory'){throw ('One-click backup did not deliver a Directory package: '+[string]$backup.Status)}
        New-Item -ItemType Directory -Force -Path ([string]$cfg.Media)|Out-Null
        $copy=Invoke-WsmWizardIndependentCopy -Workspace ([string]$cfg.WsSource) -PairId ([string]$approve.PairId) -BackupOperationId $backupOperation -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot ([string]$cfg.Media) -Mode Copy
        if([string]$copy.IndependentCopy.Status -cne 'Verified' -or [string]$copy.OfflineReadiness -cne 'Verified'){throw 'Independent copy was not verified.'}
        $copyRoot=[string]$copy.IndependentCopy.CopyRoot
        $summaryName=[IO.Path]::GetFileName([string]$backup.Delivery.Path)
        [pscustomobject]@{BackupOperationId=$backupOperation;BackupStatus=[string]$backup.Status;DeliveryMode=[string]$backup.Delivery.Mode;SourceDeliveryPath=[string]$backup.Delivery.Path;SourceDeliveryHash=[string]$backup.Delivery.SHA256;SourceDeliveryDirectory=[string]$backup.Delivery.Directory;CopyRoot=$copyRoot;MediaClass=[string]$copy.IndependentCopy.MediaClass;OfflineReadiness=[string]$copy.OfflineReadiness;CopySummaryPath=(Join-Path $copyRoot ('transport\'+$summaryName));CopySummaryHash=[string]$backup.Delivery.SHA256;CopyDeliveryDirectory=(Join-Path $copyRoot 'transport\delivery')}
    } $cfg $inv $approve $overrideScript | ForEach-Object { Write-PhaseResult 'source-backup' $_ }
}

'TargetSeedInventory' {
    # Pre-seeded Target inventory (declared fixture, not a full real capture) registered through the formal
    # job-record + Set-WsmWizardInventoryBinding entry, the same way Start-WizardRuntimeTestServer does it.
    if($env:WSM_G_OVERLAY -cne '1'){throw 'Seeding needs the runtime overlay environment.'}
    $approve=Read-PhaseResult 'manager-approve'
    & $module {
        param($cfg,$approve,$rev,$ageHours,$extra)
        $workspace=[string]$cfg.WsTarget
        $profile=Read-WsmOutputProfile $workspace
        if(-not $profile -or $profile.Role -cne 'Target'){throw 'Target workspace is not enrolled.'}
        $now=[DateTime]::UtcNow.ToString('o')
        $targetSource=[pscustomobject]@{HostId=[string]$profile.HostId;Fingerprint=[string]$profile.Fingerprint;Name=[string]$env:COMPUTERNAME}
        $inventory=New-WsmInventory $targetSource $rev @()
        if($ageHours -gt 0){$inventory.CreatedUtc=[DateTime]::UtcNow.AddHours(-$ageHours).ToString('o')}
        $entry=[pscustomobject][ordered]@{SoftwareId='sw-0000000000000000000000000000a1a1';Name='G Common Runtime';Version='1.0.0';Publisher='G Test';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location='fixture:G Common Runtime';SourceKind='Registry';Evidence=[pscustomobject]@{Probe='Uninstall'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
        $entries=@($entry)
        if($extra){$entries+=@([pscustomobject][ordered]@{SoftwareId='sw-0000000000000000000000000000b2b2';Name='G Later Install';Version='3.0.0';Publisher='G Test';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location='fixture:G Later Install';SourceKind='Registry';Evidence=[pscustomobject]@{Probe='Uninstall'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'})}
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$targetSource.HostId;Fingerprint=$targetSource.Fingerprint;Name=$targetSource.Name;InventoryRevision=$rev;InventoryProjectionHash=''};CaptureContext=[pscustomobject]@{CapturedUtc=$now;CaptureIdentity='g journey seeded target fixture';AccountContext='System';CaptureHost='g-journey-fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($entries);Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='ControlledNativeObservation';Count=$($entries.Count);Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=$now});PreparationRequirements=@(foreach($row in $entries){[pscustomobject]@{PreparationId=('prep-'+$row.SoftwareId.Substring(3));SoftwareId=$row.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='G journey fixture evidence only.'}});CatalogProjectionHash=('0'*64)}
        $inventory|Add-Member NoteProperty SoftwareCatalog $catalog
        $catalog.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $inventory
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
        Assert-WsmSoftwareCatalog $catalog -SourceInventory $inventory|Out-Null
        $inventoryRoot=Join-Path (Join-Path (Join-Path $workspace ('hosts\'+$profile.Fingerprint)) 'inventory') ''
        [void][IO.Directory]::CreateDirectory($inventoryRoot)
        $inventoryPath=Join-Path $inventoryRoot ('inventory-'+$rev+'.json')
        Write-WsmJson $inventoryPath $inventory
        $hash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $args=@{OutputDirectory=$inventoryRoot;DeepDiscovery=$false}
        $job=[pscustomobject][ordered]@{jobId=[Guid]::NewGuid().ToString('D');operationId='';idempotencyKey=[Guid]::NewGuid().ToString('D');RequestHash=(Get-WsmHtmlRequestHash $workspace ([string]$approve.PairId) 'Target' 'Inventory' $args 0);action='Inventory';role='Target';workspace=$workspace;pairId=[string]$approve.PairId;status='Succeeded';CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=$hash;Revision=1})}
        $jobRoot=Join-Path $workspace 'console-jobs';[void][IO.Directory]::CreateDirectory($jobRoot)
        Write-WsmJson (Join-Path $jobRoot ($job.jobId+'.json')) $job
        $bound=Set-WsmWizardInventoryBinding -Workspace $workspace -Role Target -JobId $job.jobId -ExpectedWizardRevision ([int](Get-WsmWizardState $workspace '' Target).Revision) -Jobs @($job)
        [pscustomobject]@{InventoryPath=$inventoryPath;InventoryHash=$hash;JobId=$job.jobId;Fixture='PreSeededTargetInventory'}
    } $cfg $approve $SeedRevision $SeedAgeHours ([bool]$SeedExtra) | ForEach-Object { Write-PhaseResult 'target-seed' $_ }
}

'TargetConsole' {
    if($env:WSM_G_OVERLAY -cne '1'){throw 'The Target console must be started with the runtime overlay enabled.'}
    if(-not $ReadyPath -or -not $StopFile){throw 'ReadyPath and StopFile are required.'}
    Start-WsmHtmlConsole -Workspace $(if($Workspace){$Workspace}else{[string]$cfg.WsTarget}) -Role Target -PairId '' -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile
}

default { throw ('Phase is not implemented yet: '+$Phase) }
}
}
catch{
    [Console]::Error.WriteLine('PHASE '+$Phase+' FAILED: '+$_.Exception.Message)
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    $inner=$_.Exception.InnerException;while($inner){[Console]::Error.WriteLine('INNER: '+$inner.Message);$inner=$inner.InnerException}
    exit 1
}
