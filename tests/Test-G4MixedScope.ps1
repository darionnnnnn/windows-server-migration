#requires -Version 5.1
# G4 (N9f): mixed scope. Unrelated C data (confirmed from a real scan) + a "D slot" IIS site (content folder and typed
# IISSite spec) + an "E slot" scheduled task (content folder and typed ScheduledTask spec); the installed-software bundle on C
# is not moved. One immutable snapshot of the tracked tree; the product is imported unchanged from it.
# Flow: Source scan -> confirmation -> Manager import / approval (CV2, three volumes) -> one-click backup -> Target import,
# comparison, receipt, preview, restore (typed IIS / task restore doubles, counted) -> original-location readback.
# Target run: one wizard restore of all five approved items; the typed IIS restore double fails its only call on purpose (a failure unrelated to any product defect):
# the C / D / E / task successes must not mask it, and the failed item keeps its own status in the core, HTML and runtime projections.
# -Mutation RepairAndRetry (P5-a): after the restore, repair the pending IIS intent through Repair-WsmOperation and retry through a new decision receipt (see the Notes in the verdict).
# -Mutation RetryFailedButton (P8): same failure and repair, then the retry goes through the runtime projection and the mapped runtime action (the retry button path): the backend candidates hold only the failed IIS site, the new receipt is created through the action command with the operator's owner and reason, nothing starts until the normal preview and restore, and the succeeded items are not rewritten.
# Output: work\r7\g-journey\<RunId>\verdict.json (same shape as the main journey).
param(
    [string]$RunId='g4a001',
    [switch]$KeepArtifacts,
    [ValidateSet('Backup','Preview','All')][string]$Through='All',
    [ValidateSet('','MoveTheBundle','RepairAndRetry','RetryFailedButton')][string]$Mutation=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'G-ScenarioCommon.ps1')
Initialize-GScenario 'g4' 'G4 mixed scope' $RunId $Mutation

try{
    Write-GStage 1 'snapshot, product imported from the immutable copy, three subst drives'
    if([IO.Directory]::Exists($script:GTestRoot)){throw 'Refusing to reuse an existing test root.'}
    [void][IO.Directory]::CreateDirectory($script:GTestRoot)
    $module=New-GSnapshot @('tests/G-ScenarioCommon.ps1','tests/Test-G4MixedScope.ps1')
    $fixturePath=Join-Path $script:GSnapshot 'tests\ExternalReadinessEvidenceFixtures.ps1'
    $wsDrive=New-GSubst (Join-Path $script:GTestRoot 'ws')
    $dDrive=New-GSubst (Join-Path $script:GTestRoot 'slot-d')
    $eDrive=New-GSubst (Join-Path $script:GTestRoot 'slot-e')
    Add-GDouble 'subst workspace drive' ('drive '+$wsDrive+': maps the workspace folder so the nested attempt/package paths stay below MAX_PATH')
    Add-GDouble 'subst D slot / E slot' ('drive '+$dDrive+': stands for the D volume (IIS site content), drive '+$eDrive+': stands for the E volume (scheduled task files); each also gets a fake Win32_Volume row and a fake physical device (the N5 device)')
    Add-GDouble 'Get-WsmMachineIdentity / Get-WsmPreflight / Export-WsmInventory' 'host qualification observation and the fixture inventory file only'
    Add-GDouble 'Get-WsmSourceCandidateRoot' 'the scan walks a fixture directory that stands for the C volume; scan, confirmation and everything after are the real code'
    Add-GDouble 'freeze evidence' 'New-WsmSourceFreezeEvidenceFixture (typed fixture evidence); the freeze record consumer is real'
    Add-GDouble 'Invoke-WsmAdapterRestore (IISSite, its only call)' 'N9h: the typed IIS restore double throws on its only call on purpose so that the restore keeps one stable, defect-independent failed item (the item stays pending repair by design; no second restore is attempted). The typed ScheduledTask boundary succeeds and is counted.'

    $script:GVerdict.Notes+=@('N9h-D1/D3/D4 (fixed): the inventory file carries the SourceResolutionContext (D3), the one-click backup reads the confirmation material where the scan wrote it (D1, no copy into <ws>/pairs), and the NonC-labelled D / E scopes of the CV2 plan are restored by the CV2 FileScope writer inside the wizard restore (D4, no direct writer call).')
    $script:GVerdict.Notes+=@('N9h: the not-masked-failure judgement uses an injected typed IIS adapter failure (stable), not a product defect.')
    if($Mutation -ceq 'RetryFailedButton'){$script:GVerdict.Notes+=@('P8 (-Mutation RetryFailedButton): after the injected IIS failure the run asks for the retry candidates before the repair (the pending intent makes the retry unavailable), repairs through Repair-WsmOperation, then drives the retry through the runtime projection (action TargetRetryFailedItems) and the mapped command with the same argument conversion as the console route. Anything other than exactly the failed item, or an empty owner / reason, is refused by the backend.')}
    if($Mutation -ceq 'RepairAndRetry'){$script:GVerdict.Notes+=@('P5-a (-Mutation RepairAndRetry): after the injected IIS failure the run continues with the real entrances: a second restore and Resume are refused while the intent is pending, Repair-WsmOperation clears it, and a restore under a NEW decision receipt retries only the failed item (the typed IIS double throws on its first call only). A restore under the SAME receipt replays the earlier Partial result without a native call (recorded in g4-observations.json as SameReceiptRestoreReplaysEarlierPartialWithoutRetry). Run in this mode because the end-to-end chain (receipt, preview hash, replay rules) cannot be reproduced by doubles; the fast version is Test-PendingIntentRecovery.ps1.')}
    Write-GStage 2 'Source scan, confirmation, Manager approval, one-click backup (C + D + E + typed IIS / task)'
    $observations=& $module {
        param($Root,$FixturePath,$MutationName,$Report,$WsRoot,$DRoot,$ERoot,$ThroughStage,$RunDir)
        . $FixturePath
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function New-PeBytes([byte]$Tail=0){ [byte[]]$bytes=New-Object byte[] 256;$bytes[0]=0x4d;$bytes[1]=0x5a;[BitConverter]::GetBytes([int]128).CopyTo($bytes,60);$bytes[128]=0x50;$bytes[129]=0x45;$bytes[255]=$Tail;$bytes }
        function Rel([string]$Base,[string]$Path){$Path.Substring($Base.TrimEnd('\').Length+1)}
        function Get-Json($Value){ConvertTo-Json -InputObject $Value -Depth 14 -Compress}
        function Get-RestoreJobStatus($Result){switch((Get-WsmOperationStatusCode $Result)){0{'Succeeded'}1{'Failed'}3{'Cancelled'}default{'ReviewRequired'}}}
        $obs=[ordered]@{}
        function Save-Obs {[IO.File]::WriteAllText((Join-Path $RunDir 'g4-observations.json'),(ConvertTo-Json -InputObject $obs -Depth 8),(New-Object Text.UTF8Encoding($false)))}
        $script:g4Fp=('a'*64);$script:g4Role='Source'
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:g4Fp;Name=('G4-'+$script:g4Role);OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:g4InventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog,[int]$MaxSoftwareEntries,[string[]]$PortableRoot,[string]$ManualEvidencePath,[string]$ManualEvidenceSha256);if(-not $script:g4InventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:g4InventoryPath;SHA256=(Get-FileHash -LiteralPath $script:g4InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        # D / E slots are subst drives: they are not Win32_Volume rows and resolve to the same physical volume as C, so both are replaced (N5 device).
        $dDrive=$DRoot.TrimEnd('\');$eDrive=$ERoot.TrimEnd('\')
        $dDevice='\\?\Volume{33333333-3333-3333-3333-333333333333}\';$eDevice='\\?\Volume{44444444-4444-4444-4444-444444444444}\'
        $script:g4Slots=@{D=$dDrive;E=$eDrive}
        $realCim=Get-Command Get-CimInstance -CommandType Cmdlet
        $script:g4ExtraVolumes=@([pscustomobject]@{DriveLetter=$dDrive;DeviceID=$dDevice},[pscustomobject]@{DriveLetter=$eDrive;DeviceID=$eDevice})
        function Get-CimInstance {param([string]$ClassName,[string]$ErrorAction);$rows=@(& $realCim -ClassName $ClassName -ErrorAction Stop);if($ClassName -ceq 'Win32_Volume'){$rows+=@($script:g4ExtraVolumes)};$rows}
        $script:g4PhysicalResolver=(Get-Command Get-WsmPhysicalPath -CommandType Function).ScriptBlock
        function Get-WsmPhysicalPath([string]$Path){
            $full=[IO.Path]::GetFullPath($Path)
            if($full.StartsWith($script:g4Slots.D+'\',[StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\') -ieq $script:g4Slots.D){return '\Device\HarddiskVolume91'+$full.Substring(2).TrimEnd('\')}
            if($full.StartsWith($script:g4Slots.E+'\',[StringComparison]::OrdinalIgnoreCase) -or $full.TrimEnd('\') -ieq $script:g4Slots.E){return '\Device\HarddiskVolume92'+$full.Substring(2).TrimEnd('\')}
            & $script:g4PhysicalResolver $Path
        }

        $sourceRoot=Join-Path $WsRoot 's';$managerRoot=Join-Path $WsRoot 'm'
        $fx=Join-Path $Root 'C-fx'
        $unrelated=Join-Path $fx 'Unrelated Data';$installRoot=Join-Path $fx 'Vendor App'
        $siteDir=Join-Path $DRoot 'Sites\Shop';$jobsDir=Join-Path $ERoot 'Jobs'
        foreach($dir in @((Join-Path $unrelated 'notes'),(Join-Path $installRoot 'lib'),(Join-Path $installRoot 'Reports'),(Join-Path $siteDir 'bin'),(Join-Path $siteDir 'App_Data'),(Join-Path $jobsDir 'data'))){[void][IO.Directory]::CreateDirectory($dir)}
        $utf8=New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $unrelated 'ledger.dat'),'G4 unrelated C ledger',$utf8)
        [IO.File]::WriteAllText((Join-Path $unrelated 'notes\readme.txt'),'G4 unrelated C note',$utf8)
        [IO.File]::WriteAllBytes((Join-Path $unrelated 'core.dll'),(New-PeBytes 1))
        [IO.File]::WriteAllBytes((Join-Path $installRoot 'app.exe'),(New-PeBytes 2))
        [IO.File]::WriteAllBytes((Join-Path $installRoot 'lib\core.dll'),(New-PeBytes 3))
        [IO.File]::WriteAllText((Join-Path $installRoot 'Reports\sales.csv'),'a,b',$utf8)
        [IO.File]::WriteAllText((Join-Path $siteDir 'default.htm'),'<html>G4 shop</html>',$utf8)
        [IO.File]::WriteAllBytes((Join-Path $siteDir 'bin\shop.dll'),(New-PeBytes 4))
        [IO.File]::WriteAllText((Join-Path $siteDir 'App_Data\orders.dat'),'G4 orders',$utf8)
        [IO.File]::WriteAllText((Join-Path $jobsDir 'worker.cmd'),'@echo G4 worker',$utf8)
        [IO.File]::WriteAllText((Join-Path $jobsDir 'data\input.csv'),'id,value',$utf8)
        $bundleOnlyHashes=@(Sha (Join-Path $installRoot 'app.exe');Sha (Join-Path $installRoot 'lib\core.dll');Sha (Join-Path $installRoot 'Reports\sales.csv'))
        function Get-TreeMap([string]$Dir){$m=[ordered]@{};foreach($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force|Sort-Object FullName)){$m[(Rel $Dir $f.FullName).ToLowerInvariant()]=Sha $f.FullName};$m}
        $before=[ordered]@{Unrelated=(Get-TreeMap $unrelated);Site=(Get-TreeMap $siteDir);Jobs=(Get-TreeMap $jobsDir);Bundle=(Get-TreeMap $installRoot)}

        # ---- enrolment: Source (a), Target (b), Manager (c)
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:g4Fp=('b'*64);$script:g4Role='Target'
        $targetRoots=@{F=(Join-Path $WsRoot 'tf');S=(Join-Path $WsRoot 'ts')}
        $targetEnrollment=Initialize-WsmOutputWorkspace $targetRoots.S Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoots.S ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=Sha $targetIdentityPath
        $script:g4Fp=('c'*64);$script:g4Role='Manager';[void](Initialize-WsmOutputWorkspace $managerRoot Manager);Initialize-WsmWorkspace $managerRoot|Out-Null
        $script:g4Fp=('a'*64);$script:g4Role='Source'
        $profile=Read-WsmOutputProfile $sourceRoot
        $source=[pscustomobject][ordered]@{HostId=[string]$profile.HostId;Fingerprint=([string]$profile.Fingerprint).ToLowerInvariant();Name='G4-Source';OS='Windows Server';Version='2025'}

        # ---- source inventory: three volumes, D / E file scopes, the IIS site, the scheduled task, path candidates (with resolution basis), software bundle
        $cVolume=@(& $realCim -ClassName Win32_Volume -ErrorAction Stop|Where-Object {([string]$_.DriveLetter).TrimEnd('\') -ieq 'C:'});if($cVolume.Count -ne 1){throw 'Fixture requires the local C: volume identity.'}
        $volC=New-WsmItem $source.HostId Storage Volume 'C: fixture volume' 'volume:C:' @{DriveLetter='C:';DeviceID=[string]$cVolume[0].DeviceID} @() Success 'Manual'
        $volD=New-WsmItem $source.HostId Storage Volume 'D slot fixture volume' ('volume:'+$dDrive) @{DriveLetter=$dDrive;DeviceID=$dDevice} @() Success 'Manual'
        $volE=New-WsmItem $source.HostId Storage Volume 'E slot fixture volume' ('volume:'+$eDrive) @{DriveLetter=$eDrive;DeviceID=$eDevice} @() Success 'Manual'
        $scopeD=New-WsmItem $source.HostId Storage FileScope 'G4 D slot site content' 'g4-d-site-content' ([pscustomobject]@{SourcePath=$siteDir;TargetPath=$siteDir}) @() Success FileScope
        $scopeE=New-WsmItem $source.HostId Storage FileScope 'G4 E slot task files' 'g4-e-task-files' ([pscustomobject]@{SourcePath=$jobsDir;TargetPath=$jobsDir}) @() Success FileScope
        $siteSource=('<site name="G4 Shop" id="2" serverAutoStart="true"><bindings><binding protocol="http" bindingInformation="*:8081:g4shop.example" /></bindings><application path="/"><virtualDirectory path="/" physicalPath="'+$siteDir+'" /></application></site>')
        $siteStaged=$siteSource.Replace('serverAutoStart="true"','serverAutoStart="false"')
        $siteItem=New-WsmItem $source.HostId Web IISSite 'G4 Shop' 'G4 Shop' ([pscustomobject]@{Name='G4 Shop';Xml=$siteSource}) @() Success
        $taskSource='<Task><Principals><Principal><UserId>S-1-5-18</UserId></Principal></Principals><Settings><Enabled>true</Enabled></Settings><Actions><Exec><Command>%G4_JOBS%\worker.cmd</Command><WorkingDirectory>%G4_USERVAR%\work</WorkingDirectory></Exec></Actions></Task>'
        $taskStaged=$taskSource.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>')
        $taskSddl='O:SYG:SYD:(A;;FA;;;SY)'
        $taskSecurity=[pscustomobject]@{TaskSecurityCapture=[pscustomobject]@{Kind='TaskSecurityCapture';SchemaVersion=1;TaskName='Worker';TaskPath='\G4\';TaskFullPath='\G4\Worker';TaskSecuritySddl=$taskSddl;TaskSecurityHash=(Get-WsmHashText $taskSddl);Folders=@(Get-WsmTaskSecurityFolderAncestors '\G4\'|ForEach-Object {[pscustomobject]@{Path=$_;SecuritySddl=$taskSddl;SecurityHash=(Get-WsmHashText $taskSddl)}})};TaskSecurityCaptureStatus='Captured'}
        $taskItem=New-WsmItem $source.HostId Tasks ScheduledTask 'G4 Worker task' '\G4\Worker' @{TaskName='Worker';TaskPath='\G4\';Xml=$taskSource;ObservedRuntime=[pscustomobject]@{State='NotObserved';Evidence='G4 fixture'};TaskSecurityCapture=$taskSecurity.TaskSecurityCapture;TaskSecurityCaptureStatus=$taskSecurity.TaskSecurityCaptureStatus} @() Success 'Manual'
        $now=[DateTime]::UtcNow.ToString('o')
        $context=[pscustomobject][ordered]@{SchemaVersion=1;Kind='SourceResolutionContext';HostId=$source.HostId;ObservedUtc=$now;MachineEnvironmentStatus='Success';MachineEnvironment=@([pscustomobject][ordered]@{Name='G4_JOBS';Value=$jobsDir;Origin='MachineEnvironment'},[pscustomobject][ordered]@{Name='SystemDrive';Value='C:';Origin='MachineSystem'});ExcludedEnvironmentNames=@();ProfileListStatus='Success';Accounts=@([pscustomobject][ordered]@{Account='SYSTEM';Sources=@('ScheduledTask');Sid='S-1-5-18';SidStatus='Resolved';ProfileImagePath=$null;ProfileStatus='NoProfile'});Note='G4 fixture: machine layer only, no user hive.'}
        $baseItems=@($volC,$volD,$volE,$scopeD,$scopeE,$siteItem,$taskItem)
        $candidates=@(Get-WsmPathCandidates $source.HostId $baseItems $context)
        $inventory=New-WsmInventory $source 1 (@($baseItems)+@($candidates))
        $inventory|Add-Member NoteProperty SourceResolutionContext $context -Force
        $softwareId='sw-'+('d'*32)
        $softwareEntry=[pscustomobject][ordered]@{SoftwareId=$softwareId;Name='G4 Vendor App';Version='1';Publisher='G4 Test';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location=$installRoot;SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='HKLM:\Software\G4';NaturalKey='G4 Vendor App'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Machine'}
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$source.HostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=$now;CaptureIdentity='g4 fixture';AccountContext='Machine';CaptureHost='g4';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($softwareEntry);Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind='';ObservedUtc=$now});PreparationRequirements=@([pscustomobject][ordered]@{PreparationId=('prep-'+$softwareId.Substring(3));SoftwareId=$softwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='G4 fixture evidence only.'});CatalogProjectionHash=('0'*64)}
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
        $inventory|Add-Member NoteProperty SoftwareCatalog $catalog -Force
        $inventoryPath=Join-Path (Join-Path (Join-Path (Join-Path $sourceRoot 'hosts') $profile.Fingerprint) 'inventory') 'inventory-1.json'
        Write-WsmJson $inventoryPath $inventory;$script:g4InventoryPath=$inventoryPath
        $inventoryHash=Sha $inventoryPath
        $snapshotPath=Join-Path $sourceRoot ('assistive/snapshots/'+$inventoryHash+'.json');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($snapshotPath));[IO.File]::Copy($inventoryPath,$snapshotPath,$false)
        $jobId=[Guid]::NewGuid().ToString('D');$job=[pscustomobject]@{jobId=$jobId;action='SourceInventory';role='Source';workspace=$sourceRoot;status='Succeeded';outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash})}
        $null=Set-WsmWizardInventoryBinding -Workspace $sourceRoot -Role Source -JobId $jobId -ExpectedWizardRevision 0 -Jobs @($job)

        # ---- N9c: the source context resolves the task's machine-level variable, with a basis; the user-level variable stays unresolved
        $commandCandidate=@($candidates|Where-Object {[string]$_.Settings.OriginalPath -ceq '%G4_JOBS%\worker.cmd'})
        $workdirCandidate=@($candidates|Where-Object {[string]$_.Settings.OriginalPath -ceq '%G4_USERVAR%\work'})
        $commandResolution=Resolve-WsmSourcePath '%G4_JOBS%\worker.cmd' $context 'S-1-5-18'
        $workdirResolution=Resolve-WsmSourcePath '%G4_USERVAR%\work' $context 'S-1-5-18'
        & $Report 'n9c_machine_variable_in_the_task_command_resolves_with_basis_machine_to_the_e_slot' ($commandCandidate.Count -eq 1 -and [string]$commandCandidate[0].Settings.ResolutionBasis -ceq 'Machine' -and @($commandCandidate[0].Settings.ResolutionVariables) -contains 'G4_JOBS' -and [string]$commandCandidate[0].Settings.ResolvedCandidate -ieq (Join-Path $jobsDir 'worker.cmd') -and [string]$commandResolution.Basis -ceq 'Machine') ('candidate basis='+$(if($commandCandidate.Count){[string]$commandCandidate[0].Settings.ResolutionBasis}else{'-'})+' resolved='+$(if($commandCandidate.Count){[string]$commandCandidate[0].Settings.ResolvedCandidate}else{'-'}))
        $workdirView=Get-WsmItemPathResolutionView $workdirCandidate[0]
        & $Report 'n9c_user_level_variable_stays_unresolved_with_a_reason_and_a_manual_next_step' ($workdirCandidate.Count -eq 1 -and [string]$workdirResolution.Basis -ceq 'Unresolved' -and [string]$workdirResolution.Reason -ceq 'VariableNotInSourceContext' -and [string]$workdirCandidate[0].Settings.ResolutionBasis -ceq 'Unresolved' -and [string]::IsNullOrEmpty([string]$workdirCandidate[0].Settings.ResolvedCandidate)) ('reason='+$workdirResolution.Reason)

        # ---- 1. Source: candidate scan over the fixture C volume
        $script:g4FixtureRoot=$fx
        Set-Item Function:\script:Get-WsmSourceCandidateRoot -Value {param([string]$Workspace,$Profile)$script:g4FixtureRoot}
        $scan=Invoke-WsmSourceCandidateScan -Workspace $sourceRoot -Jobs @($job)
        $artifact=Get-Content -LiteralPath $scan.CandidatePath -Raw -Encoding UTF8|ConvertFrom-Json
        $candUnrelated=@($artifact.Candidates|Where-Object {$_.CandidateType -ceq 'DirectoryRoot' -and $_.Path -ieq $unrelated})
        $insideBundle=@($artifact.Candidates|Where-Object {([string]$_.Path) -ieq $installRoot -or ([string]$_.Path).StartsWith($installRoot+'\',[StringComparison]::OrdinalIgnoreCase)}).Count
        $bundleArea=@($artifact.ExcludedAreas|Where-Object Path -IEQ $installRoot)
        & $Report 'scan_found_the_unrelated_c_data_and_put_the_bundle_in_excluded_areas_with_no_candidate_inside' (($scan.ScanStatus -ceq 'Succeeded') -and $candUnrelated.Count -eq 1 -and $bundleArea.Count -eq 1 -and $bundleArea[0].Category -ceq 'BundleExcluded' -and $insideBundle -eq 0) ('candidates='+@($artifact.Candidates).Count+' bundle areas='+$bundleArea.Count+' inside='+$insideBundle)
        $confirm=Export-WsmSourceCandidateConfirmation -Workspace $sourceRoot -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId $candUnrelated[0].CandidateId -Jobs @($job)
        $confirmBody=Get-Content -LiteralPath $confirm.ConfirmationPath -Raw -Encoding UTF8|ConvertFrom-Json

        # ---- 2. Manager: import, review, specs for the D / E scopes and the typed IIS / task items, approval
        $mCatalog=Import-WsmInventory -Workspace $managerRoot -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'G4-Target'
        $pairId=[string]$mCatalog.PairId
        $mCatalog=Enable-WsmAssistiveMode -Workspace $managerRoot -PairId $pairId -ExpectedRevision $mCatalog.DecisionRevision
        $excludeIds=@($candidates|ForEach-Object {[string]$_.ItemId})
        $mCatalog=Set-WsmAssistiveSelections -Workspace $managerRoot -PairId $pairId -ExpectedRevision $mCatalog.Assistive.Revision -ItemIds @([string]$volC.ItemId,[string]$volD.ItemId,[string]$volE.ItemId) -Selected $false -Reason 'G4 volume bindings only; no volume migration item is selected.'
        $mCatalog=Set-WsmAssistiveSelections -Workspace $managerRoot -PairId $pairId -ExpectedRevision $mCatalog.Assistive.Revision -ItemIds $excludeIds -Selected $false -Reason 'G4 path candidates are evidence; the D and E folders are approved as explicit scopes.'
        $imported=@(Import-WsmSourceCandidateConfirmation -Workspace $managerRoot -PairId $pairId -Path $confirm.ConfirmationPath -ExpectedHash $confirm.ConfirmationHash -TargetPath ([string]$confirmBody.Selection.ScopeRoot) -Owner 'G4 owner' -Evidence 'change:g4-fixture' -ExpectedRevision (Get-WsmCatalog $managerRoot $pairId).DecisionRevision)[-1]
        $unrelatedItemId=[string]$imported.ItemId
        $mCatalog=Get-WsmCatalog $managerRoot $pairId
        $mCatalog=Set-WsmDecision -Workspace $managerRoot -PairId $pairId -ItemId $excludeIds -Decision Exclude -Reason 'G4 path candidates are evidence; the E / D folders are approved as explicit scopes.' -ExpectedRevision $mCatalog.DecisionRevision
        $fileSpec={param([string]$Path,[string]$Evidence)[pscustomobject]@{Adapter='FileScope';SourcePath=$Path;TargetPath=$Path;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='G4 owner';Evidence=$Evidence;TransferChannel='NonC';ContentSelection='WholeScope'}}
        $siteSpec=[pscustomobject][ordered]@{Adapter='IISSite';Owner='G4 IIS owner';Evidence='G4 typed IIS site fixture';DesiredFinalState='Disabled';BusinessChecks=@('Owner review required');Desired=[pscustomobject][ordered]@{Name='G4 Shop';Xml=$siteStaged;Bindings=@([pscustomobject][ordered]@{Protocol='http';BindingInformation='*:8081:g4shop.example';CertificateHash='';CertificateStoreName='';SslFlags=0})};SourceXml=$siteSource;SourceAutoStart='true';StagedDisabled=$true;ActivationPolicyFieldPointer='IIS/site/@serverAutoStart';ReviewedActivation=[pscustomobject][ordered]@{FinalState='Disabled';Owner='G4 IIS owner';Reason='G4 owner keeps the site staged disabled.';SourceAutoStart='true';FieldPointer='IIS/site/@serverAutoStart'}}
        $taskSpec=[pscustomobject][ordered]@{Adapter='ScheduledTask';Owner='G4 task owner';Evidence='G4 typed task fixture';DesiredFinalState='Disabled';BusinessChecks=@('Owner review required');Desired=[pscustomobject][ordered]@{TaskName='Worker';TaskPath='\G4\';Xml=$taskStaged;User='SYSTEM';SecuritySddl=$taskSddl;FolderSecurity=@($taskSecurity.TaskSecurityCapture.Folders|ForEach-Object {[pscustomobject][ordered]@{Path=$_.Path;SecuritySddl=$_.SecuritySddl;ExistingPolicy=$(if($_.Path -ceq '\'){'VerifyExact'}else{'CreateOnly'})}})};SourceXml=$taskSource;SourceAutoStart='true';StagedDisabled=$true;ActivationPolicyFieldPointer='Task/Settings/Enabled';ReviewedActivation=[pscustomobject][ordered]@{FinalState='Disabled';Owner='G4 task owner';Reason='G4 owner keeps the task staged disabled.';SourceAutoStart='true';FieldPointer='Task/Settings/Enabled'};CatchUpPolicy='DedicatedManualCatchUp'}
        $specs=@(@($scopeD,(& $fileSpec $siteDir 'G4 reviewed D slot site content'),'d'),@($scopeE,(& $fileSpec $jobsDir 'G4 reviewed E slot task files'),'e'),@($siteItem,$siteSpec,'site'),@($taskItem,$taskSpec,'task'))
        foreach($entry in $specs){
            $specPath=Join-Path $Root ('g4-spec-'+$entry[2]+'.json');Write-WsmJson $specPath $entry[1]
            $mCatalog=Get-WsmCatalog $managerRoot $pairId
            Set-WsmMigrationSpec $managerRoot $pairId $entry[0].ItemId $specPath (Sha $specPath) $mCatalog.DecisionRevision|Out-Null
        }
        $includeIds=@($unrelatedItemId,[string]$scopeD.ItemId,[string]$scopeE.ItemId,[string]$siteItem.ItemId,[string]$taskItem.ItemId)
        $mCatalog=Get-WsmCatalog $managerRoot $pairId
        $mCatalog=Set-WsmDecision -Workspace $managerRoot -PairId $pairId -ItemId $includeIds -Decision Include -Reason 'Owner reviewed the G4 mixed selection.' -ExpectedRevision $mCatalog.DecisionRevision
        $mCatalog=Get-WsmCatalog $managerRoot $pairId
        $reviewIssues=@(Get-WsmReviewIssues $managerRoot $pairId|Where-Object Gate -EQ ReviewComplete)
        $obs.ReviewIssuesBeforeApproval=@($reviewIssues|ForEach-Object {[string]$_.ItemId+': '+[string]$_.Issue})
        if($reviewIssues.Count){throw ('Review issues before approval: '+((@($reviewIssues|ForEach-Object {([string]$_.ItemId).Substring(0,8)+' '+[string]$_.Gate+' '+[string]$_.Issue})|Select-Object -First 6) -join ' | '))}
        $planPath=Join-Path $Root 'g4-approved-plan.json'
        $sealed=Approve-WsmMigrationPlan -Workspace $managerRoot -PairId $pairId -TargetIdentityPath $targetIdentityPath -TargetIdentityHash $targetIdentityHash -Path $planPath -ExpectedRevision $mCatalog.DecisionRevision -PilotAcknowledgement 'ISOLATED-PILOT' -OfflineFullSet
        $plan=Read-WsmMigrationPlan $sealed.Path $sealed.SHA256
        $planIncluded=@($plan.Items|Where-Object Decision -CEQ 'Include'|ForEach-Object {[string]$_.ItemId}|Sort-Object)
        $channelOf=@{};foreach($planItem in @($plan.Items|Where-Object Decision -CEQ 'Include')){if($planItem.MigrationSpec.Adapter -ceq 'FileScope'){$channelOf[[string]$planItem.ItemId]=[string]$planItem.MigrationSpec.TransferChannel}else{$channelOf[[string]$planItem.ItemId]=[string]$planItem.MigrationSpec.Adapter}}
        & $Report 'plan_holds_exactly_the_five_mixed_items_with_c_and_nonc_channels_and_three_bound_volumes' (($planIncluded -join ',') -ceq (@($includeIds|Sort-Object) -join ',') -and $channelOf[$unrelatedItemId] -ceq 'C' -and $channelOf[[string]$scopeD.ItemId] -ceq 'NonC' -and $channelOf[[string]$scopeE.ItemId] -ceq 'NonC' -and $channelOf[[string]$siteItem.ItemId] -ceq 'IISSite' -and $channelOf[[string]$taskItem.ItemId] -ceq 'ScheduledTask' -and @($plan.Assistive.ApprovedLocalVolumes).Count -eq 3 -and [int]$plan.Assistive.ContractVersion -eq 2) ('included='+$planIncluded.Count+' volumes='+@($plan.Assistive.ApprovedLocalVolumes).Count)
        & $Report 'unconfirmed_path_candidates_and_the_bundle_are_not_plan_items' (@($plan.Items|Where-Object {$_.Decision -ceq 'Include' -and [string]$_.ItemId -in $excludeIds}).Count -eq 0 -and @($plan.Items|Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec.PSObject.Properties['SourcePath'] -and ([string]$_.MigrationSpec.SourcePath -ieq $installRoot -or ([string]$_.MigrationSpec.SourcePath).StartsWith($installRoot+'\',[StringComparison]::OrdinalIgnoreCase))}).Count -eq 0) 'no plan item covers the Vendor App root'

        # ---- 3. Source: import the plan, one-click backup (the confirmation material stays where the scan wrote it)
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $sealed.Path $sealed.SHA256
        & $Report 'source_imported_the_approved_plan_verified' ([string]$import.Status -ceq 'ImportedVerified') ([string]$import.Status)
        & $Report 'no_confirmation_material_was_copied_into_the_source_pairs_directory' (-not [IO.Directory]::Exists((Join-Path (Join-Path $sourceRoot 'pairs') 'assistive\materials')) -and @($plan.Assistive.MaterialReferences).Count -ge 1) ('material references='+@($plan.Assistive.MaterialReferences).Count+'; pairs\assistive\materials absent')
        # ---- Source-side typed doubles: the freeze really quiesces the selected task and IIS site, so their native boundary is replaced by a
        # small state machine (task enabled flag, site auto-start / running). The quiesced inventory that the freeze re-reads is the fixture
        # inventory with exactly the two expected changes (task Enabled=false, site serverAutoStart=false).
        $script:g4Run=[ordered]@{TaskEnabled=$true;TaskDisableCalls=0;SiteAuto=$true;SiteRunning=$true;SiteStopCalls=0}
        $script:g4OrigRuntime=(Get-Command Get-WsmSourceRuntime -CommandType Function).ScriptBlock
        function Get-WsmSourceRuntime($Item){
            switch([string]$Item.Kind){
                'ScheduledTask' {[pscustomobject]@{Enabled=[bool]$script:g4Run.TaskEnabled;Running=$false}}
                'IISSite' {[pscustomobject]@{AutoStart=[bool]$script:g4Run.SiteAuto;Running=[bool]$script:g4Run.SiteRunning}}
                default {& $script:g4OrigRuntime $Item}
            }
        }
        function Disable-ScheduledTask {param($TaskName,$TaskPath);$script:g4Run.TaskEnabled=$false;$script:g4Run.TaskDisableCalls++;[pscustomobject]@{TaskName=$TaskName;TaskPath=$TaskPath}}
        function Get-ScheduledTask {param($TaskName,$TaskPath);[pscustomobject]@{Settings=[pscustomobject]@{Enabled=[bool]$script:g4Run.TaskEnabled};State='Ready'}}
        function New-WsmIisManager {
            $site=[pscustomobject]@{ServerAutoStart=[bool]$script:g4Run.SiteAuto;State=$(if($script:g4Run.SiteRunning){'Started'}else{'Stopped'})}
            $site|Add-Member ScriptMethod Stop {$this.State='Stopped';$script:g4Run.SiteRunning=$false;$script:g4Run.SiteStopCalls++}
            $site|Add-Member ScriptMethod Start {$this.State='Started';$script:g4Run.SiteRunning=$true}
            $manager=[pscustomobject]@{Sites=@{'G4 Shop'=$site};ApplicationPools=@{};SiteObject=$site}
            $manager|Add-Member ScriptMethod CommitChanges {$script:g4Run.SiteAuto=[bool]$this.SiteObject.ServerAutoStart}
            $manager|Add-Member ScriptMethod Dispose {}
            $manager
        }
        $script:g4QuiescedPath=Join-Path $Root 'g4-quiesced-inventory.json'
        function script:Export-WsmInventory {
            param([string]$OutputDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog,[int]$MaxSoftwareEntries,[string[]]$PortableRoot,[string]$ManualEvidencePath,[string]$ManualEvidenceSha256)
            if(-not $script:g4InventoryPath){throw 'Fixture inventory observation was not initialized.'}
            if($script:g4Run.TaskEnabled -and $script:g4Run.SiteAuto){return [pscustomobject]@{Path=$script:g4InventoryPath;SHA256=(Get-FileHash -LiteralPath $script:g4InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
            $copy=Read-WsmJson $script:g4InventoryPath
            foreach($item in @($copy.Items)){
                if([string]$item.Kind -ceq 'ScheduledTask' -and -not $script:g4Run.TaskEnabled){$doc=Read-WsmXml ([string]$item.Settings.Xml);$node=$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");$node.InnerText='false';$item.Settings.Xml=$doc.OuterXml;$item.SettingsHash=Get-WsmHashText ($item.Settings|ConvertTo-Json -Depth 30 -Compress)}
                if([string]$item.Kind -ceq 'IISSite' -and -not $script:g4Run.SiteAuto){$doc=Read-WsmXml ([string]$item.Settings.Xml);$doc.DocumentElement.SetAttribute('serverAutoStart','false');$item.Settings.Xml=$doc.OuterXml;$item.SettingsHash=Get-WsmHashText ($item.Settings|ConvertTo-Json -Depth 30 -Compress)}
            }
            if($copy.PSObject.Properties['SoftwareCatalog']){$copy.SoftwareCatalog.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $copy;$copy.SoftwareCatalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $copy.SoftwareCatalog}
            Write-WsmJson $script:g4QuiescedPath $copy|Out-Null
            [pscustomobject]@{Path=$script:g4QuiescedPath;SHA256=(Get-FileHash -LiteralPath $script:g4QuiescedPath -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
        $freezeOwner='G4 freeze owner';$freezeText='Synthetic owner-confirmed quiescence; fixture only.'
        $freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $plan -PlanHash $sealed.SHA256 -Root $Root -Owner $freezeOwner
        $backupOperation=[Guid]::NewGuid().ToString('D')
        $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $pairId -PlanHash $sealed.SHA256 -OperationId $backupOperation
        $backup=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId $backupOperation -Owner $freezeOwner -Evidence $freezeText -FreezeAuthorization -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -Jobs @() -CancellationToken $token -DeliveryMode Directory -VolumeBytes 0
        & $Report 'backup_delivered_sealed_valid_and_c_nonc_and_typed_channels_are_all_verified' (([string]$backup.Status -ceq 'Delivered') -and $backup.CoreExport.Sealed -and $backup.PackageTest.Valid -and [string]$backup.ChannelSummary.C.Status -ceq 'VerifiedDelivered' -and [string]$backup.ChannelSummary.NonC.Status -ceq 'VerifiedDelivered' -and [string]$backup.ChannelSummary.ConfigurationEvidence.Status -ceq 'VerifiedInSealedPlanAndDelivered' -and @($backup.ChannelSummary.ConfigurationEvidence.IncludedItemIds).Count -eq 2 -and @($backup.ChannelSummary.NonC.IncludedItemIds).Count -eq 2 -and @($backup.ChannelSummary.C.IncludedItemIds).Count -eq 1) ('Status='+$backup.Status+' C='+$backup.ChannelSummary.C.Status+' NonC='+$backup.ChannelSummary.NonC.Status+' Config='+$backup.ChannelSummary.ConfigurationEvidence.Status)
        $afterBackup=[ordered]@{Unrelated=(Get-TreeMap $unrelated);Site=(Get-TreeMap $siteDir);Jobs=(Get-TreeMap $jobsDir);Bundle=(Get-TreeMap $installRoot)}
        $treeSame=$true;foreach($key in $before.Keys){if((Get-Json $before[$key]) -cne (Get-Json $afterBackup[$key])){$treeSame=$false}}
        & $Report 'source_trees_c_d_e_and_bundle_are_byte_identical_after_discovery_and_backup' $treeSame 'four trees re-hashed'

        # ---- 4. archive: per channel, per scope, and the bundle is not in it
        $package=Test-WsmMigrationPackage ([string]$backup.CoreExport.ManifestPath) ([string]$backup.CoreExport.SHA256)
        $allRows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash)
        $fileRows=@($allRows|Where-Object {-not $_.Directory})
        $expectByItem=@{
            $unrelatedItemId=@($before.Unrelated.Values|Sort-Object)
            ([string]$scopeD.ItemId)=@($before.Site.Values|Sort-Object)
            ([string]$scopeE.ItemId)=@($before.Jobs.Values|Sort-Object)
        }
        $archiveOk=$true;$archiveDetail=@()
        foreach($id in $expectByItem.Keys){
            $actual=@($fileRows|Where-Object {[string]$_.ItemId -ceq $id}|ForEach-Object {[string]$_.Data.Hash}|Sort-Object)
            $match=(($actual -join ',') -ceq ($expectByItem[$id] -join ','))
            if(-not $match){$archiveOk=$false};$archiveDetail+=@($channelOf[$id]+'='+$actual.Count+$(if($match){'ok'}else{'DIFF'}))
        }
        & $Report 'archive_c_channel_and_both_nonc_scopes_hold_exactly_their_source_file_hashes' $archiveOk ($archiveDetail -join ' ')
        $archiveHashes=@($fileRows|ForEach-Object {[string]$_.Data.Hash})
        & $Report 'archive_holds_nothing_from_the_software_bundle_and_nothing_for_the_typed_items' (@($archiveHashes|Where-Object {$bundleOnlyHashes -contains $_}).Count -eq 0 -and @($allRows|Where-Object {[string]$_.ItemId -in @([string]$siteItem.ItemId,[string]$taskItem.ItemId)}).Count -eq 0) ('archive files='+$fileRows.Count)

        # ---- 5. result set: rows, excluded regions with visibility classes, gaps and responsibilities
        $view=Get-WsmWizardBackupItemResultsView $sourceRoot $pairId
        $rowOf={param([string]$Id)@($view.rows|Where-Object {[string]$_.ItemId -ceq $Id})}
        $rUnrelated=@(& $rowOf $unrelatedItemId);$rD=@(& $rowOf ([string]$scopeD.ItemId));$rE=@(& $rowOf ([string]$scopeE.ItemId));$rSite=@(& $rowOf ([string]$siteItem.ItemId));$rTask=@(& $rowOf ([string]$taskItem.ItemId))
        & $Report 'result_rows_back_up_c_d_e_and_the_two_typed_items_each_with_its_own_channel_and_restore_condition' ($view.available -and $rUnrelated.Count -eq 1 -and $rD.Count -eq 1 -and $rE.Count -eq 1 -and $rSite.Count -eq 1 -and $rTask.Count -eq 1 -and @($rUnrelated+$rD+$rE+$rSite+$rTask|Where-Object {[string]$_.Status -ceq 'BackedUp'}).Count -eq 5 -and [string]$rUnrelated[0].Channel -ceq 'C' -and [string]$rD[0].Channel -ceq 'NonC' -and [string]$rE[0].Channel -ceq 'NonC' -and [string]$rSite[0].RestoreCondition.Code -ceq 'RequiresPrerequisite' -and [string]$rTask[0].RestoreCondition.Code -ceq 'RequiresPrerequisite' -and [string]$rD[0].RestoreCondition.Code -ceq 'Restorable') ('available='+$view.available+' rows='+@($view.rows).Count)
        $viewBundle=@($view.excludedRegions|Where-Object {[string]$_.Path -ieq $installRoot})
        $sameName=@();if($viewBundle.Count -and $viewBundle[0].PSObject.Properties['SameName']){$sameName=@($viewBundle[0].SameName)}
        & $Report 'bundle_root_is_an_excluded_region_with_n9d_visibility_class_contents_manual_handling_and_same_name_trace' ($viewBundle.Count -eq 1 -and [string]$viewBundle[0].ReasonCode -ceq 'BundleExcluded' -and [string]$viewBundle[0].CategorySource -ceq 'Structured' -and $viewBundle[0].Contents.Counts.Bundle -ge 2 -and $viewBundle[0].Contents.Counts.SuspectedBusinessData -ge 1 -and $viewBundle[0].ManualHandling.Required -eq $true -and $sameName.Count -eq 1 -and [string]$sameName[0].Name -ceq 'core.dll' -and [string]$sameName[0].OtherPath -ieq (Join-Path $unrelated 'core.dll') -and [string]$view.excludedRegionsBinding.Status -ceq 'Bound') ('class='+$(if($viewBundle.Count){[string]$viewBundle[0].ReasonCode}else{'-'})+' sameName='+$sameName.Count+' binding='+$view.excludedRegionsBinding.Status)
        $gapRows=@($view.rows|Where-Object {[string]$_.Status -ceq 'NotBackedUp'})
        $gapComplete=($gapRows.Count -ge 1);foreach($row in $gapRows){if(-not ([string]$row.Reason) -or -not ([string]$row.NextStep)){$gapComplete=$false}}
        $regionComplete=($viewBundle.Count -eq 1 -and [bool]$viewBundle[0].Reason -and [bool]$viewBundle[0].NextStep -and [bool]$viewBundle[0].ManualHandling.OriginalLocation -and [bool]$viewBundle[0].ManualHandling.NextStep)
        $ownersComplete=$true;foreach($planItem in @($plan.Items|Where-Object Decision -CEQ 'Include')){if(-not [string]$planItem.MigrationSpec.Owner){$ownersComplete=$false}}
        $candidateRows=@($view.rows|Where-Object {[string]$_.ItemId -in $excludeIds -and [string]$_.Status -ceq 'NotBackedUp' -and [string]$_.ReasonCode -cin @('Excluded','NotSelected','NotIncluded') -and [string]$_.Reason -and [string]$_.NextStep})
        & $Report 'gaps_responsibilities_and_results_are_explicit_every_gap_row_has_reason_next_step_original_location_and_every_included_item_has_an_owner' ($gapComplete -and $regionComplete -and $ownersComplete -and $candidateRows.Count -eq $excludeIds.Count -and [string]$view.excludedCompleteness.Status -ceq 'ManualItems') ('gap rows='+$gapRows.Count+' not-backed-up candidate rows='+$candidateRows.Count+'/'+$excludeIds.Count+' codes='+((@($view.rows|Where-Object {[string]$_.ItemId -in $excludeIds}|ForEach-Object {[string]$_.ReasonCode}|Sort-Object -Unique)) -join ',')+' completeness='+$view.excludedCompleteness.Status)
        $obs.Backup=[ordered]@{PairId=$pairId;Status=[string]$backup.Status;ArchiveFiles=$fileRows.Count;GapRows=$gapRows.Count}
        if($ThroughStage -ceq 'Backup'){return $obs}

        # ======================= Target side: originals moved aside, import, comparison, receipt, preview, restore =======================
        foreach($dir in @($unrelated,$siteDir,$jobsDir)){[IO.Directory]::Move($dir,$dir+'.moved-away')}
        $script:g4Fp=('b'*64);$script:g4Role='Target'
        $targetRoot=$targetRoots.S
        $tImport=Import-WsmWizardApprovedPlan $targetRoot Target $sealed.Path $sealed.SHA256
        & $Report 'target_imported_the_approved_plan_verified_with_the_source_snapshot_attachment' ([string]$tImport.Status -ceq 'ImportedVerified') ([string]$tImport.Status)
        # Target inventory (pre-seeded fixture registered through the formal job-record + binding entry, as the main journey does) and its live software observation
        $tProfile=Read-WsmOutputProfile $targetRoot
        $tSource=[pscustomobject]@{HostId=[string]$tProfile.HostId;Fingerprint=[string]$tProfile.Fingerprint;Name='G4-Target'}
        $tInventory=New-WsmInventory $tSource 1 @()
        $tNow=[DateTime]::UtcNow.ToString('o')
        $tEntry=[pscustomobject][ordered]@{SoftwareId='sw-0000000000000000000000000000a1a1';Name='G4 Common Runtime';Version='1.0.0';Publisher='G4 Test';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location='fixture:G4 Common Runtime';SourceKind='Registry';Evidence=[pscustomobject]@{Probe='Uninstall'};ObservedUtc=$tNow;CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
        $tCatalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$tSource.HostId;Fingerprint=$tSource.Fingerprint;Name=$tSource.Name;InventoryRevision=1;InventoryProjectionHash=''};CaptureContext=[pscustomobject]@{CapturedUtc=$tNow;CaptureIdentity='g4 seeded target fixture';AccountContext='System';CaptureHost='g4-fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($tEntry);Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='ControlledNativeObservation';Count=1;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=$tNow});PreparationRequirements=@([pscustomobject]@{PreparationId='prep-0000000000000000000000000000a1a1';SoftwareId=$tEntry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='G4 fixture evidence only.'});CatalogProjectionHash=('0'*64)}
        $tInventory|Add-Member NoteProperty SoftwareCatalog $tCatalog
        $tCatalog.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $tInventory
        $tCatalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $tCatalog
        Assert-WsmSoftwareCatalog $tCatalog -SourceInventory $tInventory|Out-Null
        $tInventoryRoot=Join-Path (Join-Path (Join-Path $targetRoot ('hosts\'+$tProfile.Fingerprint)) 'inventory') ''
        [void][IO.Directory]::CreateDirectory($tInventoryRoot)
        $tInventoryPath=Join-Path $tInventoryRoot 'inventory-1.json';Write-WsmJson $tInventoryPath $tInventory
        $tInventoryHash=Sha $tInventoryPath
        $tInventoryJob=[pscustomobject][ordered]@{jobId=[Guid]::NewGuid().ToString('D');operationId='';idempotencyKey=[Guid]::NewGuid().ToString('D');action='Inventory';role='Target';workspace=$targetRoot;pairId=$pairId;status='Succeeded';CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Path=$tInventoryPath;SHA256=$tInventoryHash;Revision=1})}
        $null=Set-WsmWizardInventoryBinding -Workspace $targetRoot -Role Target -JobId $tInventoryJob.jobId -ExpectedWizardRevision ([int](Get-WsmWizardState $targetRoot '' Target).Revision) -Jobs @($tInventoryJob)
        $script:g4TargetInventoryPath=$tInventoryPath
        $script:g4OrigSoftwareCatalog=(Get-Command Get-WsmSoftwareCatalog -CommandType Function).ScriptBlock
        function Get-WsmSoftwareCatalog {
            [CmdletBinding()]param($Source,[string[]]$PortableRoot=@(),[int]$MaxEntries=10000,[int]$MaxDepth=8,[long]$MaxMetadataBytes=4194304,[string]$ManualEvidencePath,[string]$ManualEvidenceSha256)
            if($Source -and $Source.PSObject.Properties['Source']){$seeded=Read-WsmJson $script:g4TargetInventoryPath;if([string]$Source.Source.Fingerprint -ceq [string]$seeded.Source.Fingerprint){return $seeded.SoftwareCatalog}}
            & $script:g4OrigSoftwareCatalog @PSBoundParameters
        }
        # typed restore doubles: the native boundary of the two typed adapters only. Calls are counted and the received spec is recorded.
        $script:g4Typed=[ordered]@{IISSite=0;ScheduledTask=0;Specs=@();Applied=@{};InjectedFailures=0}
        $script:g4OrigAdapterState=(Get-Command Get-WsmAdapterState -CommandType Function).ScriptBlock
        $script:g4OrigAdapterRestore=(Get-Command Invoke-WsmAdapterRestore -CommandType Function).ScriptBlock
        $script:g4OrigAdapterTest=(Get-Command Test-WsmAdapterConfiguration -CommandType Function).ScriptBlock
        function Get-WsmAdapterState($Spec){
            if([string]$Spec.Adapter -cin @('IISSite','ScheduledTask')){return [pscustomobject]@{Exists=[bool]$script:g4Typed.Applied.ContainsKey([string]$Spec.Adapter)}}
            & $script:g4OrigAdapterState $Spec
        }
        function Test-WsmAdapterConfiguration($Spec,[string]$Phase,[object[]]$TaskSecurityReceipts=@()){
            if([string]$Spec.Adapter -cin @('IISSite','ScheduledTask')){return [pscustomobject]@{Passed=$true;Problems=@();Actual=[pscustomobject]@{Adapter=[string]$Spec.Adapter;Name=$(if($Spec.Desired.PSObject.Properties['Name']){[string]$Spec.Desired.Name}else{[string]$Spec.Desired.TaskName});Fixture='typed-double'}}}
            & $script:g4OrigAdapterTest @PSBoundParameters
        }
        function Invoke-WsmAdapterRestore($Spec,[hashtable]$Secrets,$Package,$InstallerBaseline=$null,[scriptblock]$BeforeFolderCreate,[scriptblock]$AfterFolderCreate,[object[]]$OwnedReceipts=@(),[object[]]$SharedReceipts=@(),[string]$ReservationWorkspace='',[string]$ReservationOperationId=''){
            if([string]$Spec.Adapter -cin @('IISSite','ScheduledTask')){
                $script:g4Typed[[string]$Spec.Adapter]++
                $name=$(if($Spec.Desired.PSObject.Properties['Name']){[string]$Spec.Desired.Name}else{[string]$Spec.Desired.TaskPath+[string]$Spec.Desired.TaskName})
                $script:g4Typed.Specs=@($script:g4Typed.Specs)+@([pscustomobject]@{Adapter=[string]$Spec.Adapter;Name=$name;StagedDisabled=[bool]$Spec.StagedDisabled;FinalState=[string]$Spec.DesiredFinalState;XmlHash=(Get-WsmHashText ([string]$Spec.Desired.Xml))})
                if([string]$Spec.Adapter -ceq 'IISSite' -and $script:g4Typed.IISSite -eq 1){$script:g4Typed.InjectedFailures++;throw 'G4 injected typed IISSite adapter failure (first call only; unrelated to any product defect)'}
                $script:g4Typed.Applied[[string]$Spec.Adapter]=$true
                return [pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}
            }
            & $script:g4OrigAdapterRestore $Spec $Secrets $Package $InstallerBaseline $BeforeFolderCreate $AfterFolderCreate $OwnedReceipts $SharedReceipts $ReservationWorkspace $ReservationOperationId
        }

        $pkgImport=Import-WsmWizardTargetDirectoryPackage -Workspace $targetRoot -PairId $pairId -SummaryPath ([string]$backup.Delivery.Path) -ExpectedSummaryHash ([string]$backup.Delivery.SHA256) -SourceDirectory ([string]$backup.Delivery.Directory) -OperationId ([Guid]::NewGuid().ToString('D'))
        $importJob=[pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pairId;workspace=$targetRoot;jobId=[Guid]::NewGuid().ToString('D');CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$pkgImport.ManifestPath;ManifestHash=$pkgImport.ManifestHash;PairId=$pairId;PlanHash=[string]$sealed.SHA256;Generation=$pkgImport.Generation;AttemptId=$pkgImport.AttemptId})}
        $tJobs=@($tInventoryJob,$importJob)
        & $Report 'target_imported_the_sealed_package_from_the_directory_delivery_without_the_source' ([string]$pkgImport.Status -ceq 'Succeeded' -and [string]$pkgImport.ManifestHash -ieq [string]$backup.CoreExport.SHA256) ([string]$pkgImport.Status)
        $comparison=New-WsmWizardTargetLocalComparison -Workspace $targetRoot -PairId $pairId -Jobs $tJobs
        $receipt=Create-WsmWizardTargetDecisionReceipt -Workspace $targetRoot -PairId $pairId -Decision RestoreNow -Owner 'G4 target operator' -Reason 'Reviewed the local comparison; restore every approved mixed item.' -SelectedItemIds ([string[]]$includeIds) -Jobs $tJobs
        $preview=Get-WsmWizardTargetRestoreProjection -Workspace $targetRoot -PairId $pairId -Jobs $tJobs
        $previewRows=@($preview.Rows)
        $obs.PreviewRows=@($previewRows|ForEach-Object {([string]$_.ItemId).Substring(0,8)+' '+[string]$_.Status+'/'+[string]$_.Action})
        & $Report 'target_preview_is_previewed_unblocked_and_covers_exactly_the_five_selected_items' ([string]$comparison.Status -ceq 'Succeeded' -and [string]$preview.Status -ceq 'Previewed' -and -not [bool]$preview.Blocked -and @($preview.SelectedItemIds).Count -eq 5 -and @($previewRows|Where-Object {[string]$_.Status -ceq 'Ready'}).Count -ge 5) ('Status='+$preview.Status+' blocked='+$preview.Blocked+' rows='+($obs.PreviewRows -join '; '))
        if($ThroughStage -ceq 'Preview'){return $obs}

        # ======================= Restore: every approved item selected; the injected typed IIS failure must stay visible =======================
        # The restore covers C, D, E, the IIS site and the scheduled task. The typed IIS restore double fails its call on purpose (a failure that has nothing to do with any product defect):
        # the failed item keeps the parent result, the HTML projection and the runtime projection from reading as success, and the C / D / E successes do not hide it.
        $restoreStateDirectory=Join-Path $targetRoot 'pairs'
        $script:g4OrigFileRestore=(Get-Command Invoke-WsmAssistiveFileScopeRestore -CommandType Function).ScriptBlock
        $script:g4BundleLeak=($MutationName -ceq 'MoveTheBundle');$script:g4BundleSource=$installRoot;$script:g4UnrelatedDir=$unrelated
        function Invoke-WsmAssistiveFileScopeRestore {
            $written=& $script:g4OrigFileRestore @args
            if($script:g4BundleLeak -and [string]$args[0].MigrationSpec.SourcePath -ieq $script:g4UnrelatedDir){[IO.File]::Copy((Join-Path $script:g4BundleSource 'app.exe'),(Join-Path $script:g4UnrelatedDir 'app.exe'),$true)}
            $written
        }
        $selection1=@($includeIds)
        $receipt1=Create-WsmWizardTargetDecisionReceipt -Workspace $targetRoot -PairId $pairId -Decision RestoreNow -Owner 'G4 target operator' -Reason 'Restore every approved mixed item; the IIS site is made to fail by the test double.' -SelectedItemIds ([string[]]$selection1) -Jobs $tJobs
        $preview1=Get-WsmWizardTargetRestoreProjection -Workspace $targetRoot -PairId $pairId -Jobs $tJobs
        $global:Error.Clear()
        $restore1=Invoke-WsmWizardTargetRestore -Workspace $targetRoot -PairId $pairId -PreviewHash ([string]$preview1.PreviewHash) -Jobs $tJobs
        $obs.Restore1Errors=@($global:Error|Select-Object -First 8|ForEach-Object {[string]$_.Exception.Message})
        $r1ByItem=@{};foreach($row in @($restore1.ItemResults)){$r1ByItem[[string]$row.ItemId]=[string]$row.Status}
        $obs.Restore1=[ordered]@{Status=[string]$restore1.Status;Items=@($restore1.ItemResults|ForEach-Object {([string]$_.ItemId).Substring(0,8)+'='+[string]$_.Status});StatusCode=(Get-WsmOperationStatusCode $restore1)}
        $restoreJob1=[pscustomobject]@{action='TargetRestore';status=(Get-RestoreJobStatus $restore1);role='Target';pairId=$pairId;workspace=$targetRoot;jobId=[string]$restore1.AttemptOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($restore1)}
        $htmlRestore1=@(Get-WsmHtmlResultProjection @($restore1))[0]
        $runtime1=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $targetRoot -PairId $pairId -Role Target -Jobs (@($tJobs)+@($restoreJob1)))
        $obs.Runtime1=[ordered]@{Status=[string]$runtime1.status;RuntimeKeys=@($runtime1.runtime.PSObject.Properties.Name);Result=$runtime1.runtime.restoreResult}
        Save-Obs
        $c1=[string]$r1ByItem[$unrelatedItemId];$d1=[string]$r1ByItem[[string]$scopeD.ItemId];$e1=[string]$r1ByItem[[string]$scopeE.ItemId];$site1=[string]$r1ByItem[[string]$siteItem.ItemId];$task1=[string]$r1ByItem[[string]$taskItem.ItemId]
        $failed1=@($restore1.ItemResults|Where-Object {[string]$_.Status -cne 'Succeeded'})
        & $Report 'restore_c_d_e_and_task_succeeded_and_only_the_injected_iis_site_failure_is_reported_as_its_own_failed_item' ($c1 -ceq 'Succeeded' -and $d1 -ceq 'Succeeded' -and $e1 -ceq 'Succeeded' -and $task1 -ceq 'Succeeded' -and $site1 -ceq 'Failed' -and $failed1.Count -eq 1 -and [string]$failed1[0].ItemId -ceq [string]$siteItem.ItemId -and $script:g4Typed.InjectedFailures -eq 1) ('C='+$c1+' D='+$d1+' E='+$e1+' task='+$task1+' site='+$site1+' failed items='+$failed1.Count+' injected='+$script:g4Typed.InjectedFailures)
        $d1Result=@($restore1.ItemResults|Where-Object {[string]$_.ItemId -ceq [string]$scopeD.ItemId});$e1Result=@($restore1.ItemResults|Where-Object {[string]$_.ItemId -ceq [string]$scopeE.ItemId})
        $viaLegacyNonC=@($d1Result+$e1Result|Where-Object {$_.PSObject.Properties['OwnershipChannel'] -and [string]$_.OwnershipChannel -ceq 'NonC'}).Count
        & $Report 'n9h_d4_nonc_labelled_scopes_of_the_cv2_plan_were_written_by_the_cv2_filescope_writer_not_the_legacy_nonc_branch' ($d1Result.Count -eq 1 -and $e1Result.Count -eq 1 -and $viaLegacyNonC -eq 0 -and @($d1Result[0].OwnedFiles).Count -eq 3 -and @($e1Result[0].OwnedFiles).Count -eq 2) ('legacy NonC results='+$viaLegacyNonC+' ownedFiles D='+@($d1Result[0].OwnedFiles).Count+' E='+@($e1Result[0].OwnedFiles).Count)
        $runtimeResult=$runtime1.runtime.restoreResult
        $runtimeResultStatus=$(if($runtimeResult -and $runtimeResult.PSObject.Properties['status']){[string]$runtimeResult.status}else{'(none)'})
        $retire1=@();foreach($name in @('FinalAccepted','RetirementReady','Activated')){if($restore1.PSObject.Properties[$name] -and [bool]$restore1.$name){$retire1+=@($name)}}
        $noMask=($failed1.Count -ge 1) -and [string]$restore1.Status -cne 'Succeeded' -and (Get-WsmOperationStatusCode $restore1) -ne 0 -and [string]$htmlRestore1.Status -cne 'Succeeded' -and $runtimeResultStatus -cne 'Succeeded'
        & $Report 'the_failed_iis_item_is_not_masked_by_the_c_d_e_and_task_successes_in_core_html_and_runtime_projection' ($noMask -and $retire1.Count -eq 0) ('failed items='+$failed1.Count+' core='+$restore1.Status+' code='+(Get-WsmOperationStatusCode $restore1)+' html='+$htmlRestore1.Status+' runtime.restoreResult='+$runtimeResultStatus)
        $siteApplied=$script:g4Typed.Applied.ContainsKey('IISSite')
        & $Report 'the_failed_iis_item_left_no_applied_state_behind' (-not $siteApplied) 'typed IISSite boundary recorded no applied state'
        $obs.D4=[ordered]@{Id='N9h-D4';NonCScopesFailedInWizardRestore=@($d1,$e1|Where-Object {$_ -cne 'Succeeded'}).Count;LegacyNonCResults=$viaLegacyNonC}

        & $Report 'typed_iis_double_failed_its_only_call_and_the_task_double_was_called_exactly_once' ($script:g4Typed.IISSite -eq 1 -and $script:g4Typed.ScheduledTask -eq 1 -and $script:g4Typed.InjectedFailures -eq 1) ('IISSite='+$script:g4Typed.IISSite+' ScheduledTask='+$script:g4Typed.ScheduledTask+' injected='+$script:g4Typed.InjectedFailures)
        $recorded=@($script:g4Typed.Specs)
        & $Report 'typed_doubles_received_the_reviewed_staged_disabled_specs_for_the_right_objects' ($recorded.Count -eq 2 -and @($recorded|Where-Object {$_.Adapter -ceq 'IISSite' -and $_.Name -ceq 'G4 Shop' -and $_.StagedDisabled -and $_.FinalState -ceq 'Disabled'}).Count -eq 1 -and @($recorded|Where-Object {$_.Adapter -ceq 'ScheduledTask' -and $_.Name -ceq '\G4\Worker' -and $_.StagedDisabled -and $_.FinalState -ceq 'Disabled'}).Count -eq 1) (($recorded|ForEach-Object {$_.Adapter+':'+$_.Name}) -join ',')

        # ======================= original locations: bytes, nothing extra, the bundle neither moved nor copied =======================
        $after=[ordered]@{Unrelated=(Get-TreeMap $unrelated);Site=(Get-TreeMap $siteDir);Jobs=(Get-TreeMap $jobsDir)}
        $restoredSame=$true;$restoredDetail=@()
        foreach($key in $after.Keys){$same=((Get-Json $before[$key]) -ceq (Get-Json $after[$key]));if(-not $same){$restoredSame=$false};$restoredDetail+=@($key+'='+$after[$key].Count+$(if($same){'ok'}else{'DIFF'}))}
        & $Report 'restore_wrote_c_d_and_e_files_to_their_original_locations_with_the_source_bytes_and_no_extra_file' $restoredSame ($restoredDetail -join ' ')
        $movedSame=((Get-Json $before.Unrelated) -ceq (Get-Json (Get-TreeMap ($unrelated+'.moved-away')))) -and ((Get-Json $before.Site) -ceq (Get-Json (Get-TreeMap ($siteDir+'.moved-away')))) -and ((Get-Json $before.Jobs) -ceq (Get-Json (Get-TreeMap ($jobsDir+'.moved-away'))))
        & $Report 'moved_aside_originals_are_untouched_by_the_restore' $movedSame 'three moved-away trees re-hashed'
        $allRestoredHashes=@($after.Values|ForEach-Object {$_.Values}|ForEach-Object {[string]$_})
        $bundleAfter=Get-TreeMap $installRoot
        & $Report 'software_bundle_was_not_moved_not_archived_not_restored_and_its_source_is_unchanged' (@($allRestoredHashes|Where-Object {$bundleOnlyHashes -contains $_}).Count -eq 0 -and (Get-Json $bundleAfter) -ceq (Get-Json $before.Bundle) -and @($archiveHashes|Where-Object {$bundleOnlyHashes -contains $_}).Count -eq 0) 'no bundle-only hash in the archive or in any restored tree; Vendor App unchanged'

        # ======================= "not enabled" =======================
        $finalJob=$restoreJob1
        $runtime2=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $targetRoot -PairId $pairId -Role Target -Jobs (@($tJobs)+@($finalJob)))
        $obs.Runtime2Status=[string]$runtime2.status
        $activationActions=@($runtime2.actions|Where-Object {[string]$_.id -ceq 'TargetActivation' -and $_.available -eq $true})
        & $Report 'runtime_projection_claims_nothing_enabled_verified_or_authoritative_and_offers_no_activation' ($runtime2.ProductionVerified -eq $false -and $runtime2.AuthoritativeApproval -eq $false -and $restore1.ProductionVerified -eq $false -and $activationActions.Count -eq 0) ('ProductionVerified='+$runtime2.ProductionVerified+' activation actions available='+$activationActions.Count)
        & $Report 'typed_items_stay_staged_disabled_by_the_reviewed_spec_and_nothing_was_activated_or_resumed' ($script:g4Run.TaskEnabled -eq $false -and $script:g4Run.SiteAuto -eq $false -and @($recorded|Where-Object {$_.FinalState -ceq 'Disabled'}).Count -eq 2 -and $retire1.Count -eq 0) ('source task enabled='+$script:g4Run.TaskEnabled+' site auto='+$script:g4Run.SiteAuto+' (quiesced by the freeze, not resumed); target specs FinalState=Disabled')
        $obs.Restore=[ordered]@{Status=$obs.Restore1.Status;TypedCalls=@("IIS=$($script:g4Typed.IISSite)","Task=$($script:g4Typed.ScheduledTask)")}

        # ======================= P5-a (-Mutation RepairAndRetry): the failed IIS item left a pending intent; can the user get out, and does a second restore retry only that item? =======================
        # Real entrances only: Invoke-WsmWizardTargetRestore (a second restore), Resume-WsmWizardTargetRestore, Repair-WsmOperation, then a second restore. The typed IIS double
        # throws only on its first call, so the retry can succeed.
        if($MutationName -cin @('RepairAndRetry','RetryFailedButton')){
            $retry=[ordered]@{}
            $jobsAfter=@(@($tJobs)+@($restoreJob1))
            $siteId=[string]$siteItem.ItemId
            $pendingBefore=@((Read-WsmJson (Join-Path (Join-Path $restoreStateDirectory $pairId) 'state.json')).PendingOperations)
            & $Report 'p5a_precondition_the_failed_iis_item_left_exactly_one_pending_adapter_intent' ($pendingBefore.Count -eq 1 -and [string]$pendingBefore[0].ItemId -ceq $siteId -and [string]$pendingBefore[0].Phase -ceq 'AssistiveAdapterCreating') ('pending='+$pendingBefore.Count)
            if($MutationName -ceq 'RetryFailedButton'){
                # P8: before the repair, the pending intent makes the retry unavailable and the runtime projection says so
                $candBefore=Get-WsmWizardTargetRetryCandidates -Workspace $targetRoot -PairId $pairId -Jobs $jobsAfter
                $runtimeBefore=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $targetRoot -PairId $pairId -Role Target -Jobs $jobsAfter)
                $actionBefore=@($runtimeBefore.actions|Where-Object {[string]$_.id -ceq 'TargetRetryFailedItems'})
                & $Report 'p8_pending_intent_makes_the_retry_unavailable_with_the_repair_first_reason' ($candBefore.Visible -and -not $candBefore.Eligible -and [string]$candBefore.ReasonCode -ceq 'PendingIntent' -and @($candBefore.CandidateItemIds).Count -eq 0 -and $runtimeBefore.runtime.retry.visible -eq $true -and $runtimeBefore.runtime.retry.eligible -eq $false -and $actionBefore.Count -eq 1 -and $actionBefore[0].available -eq $false) ('reason='+$candBefore.ReasonCode+' action available='+$(if($actionBefore.Count){$actionBefore[0].available}else{'-'}))
            }
            $previewAfterFail=Get-WsmWizardTargetRestoreProjection -Workspace $targetRoot -PairId $pairId -Jobs $jobsAfter
            $retry.PreviewAfterFailStatus=[string]$previewAfterFail.Status;$retry.PreviewAfterFailHashSame=([string]$previewAfterFail.PreviewHash -ceq [string]$preview1.PreviewHash)
            # (1) a second restore through the wizard entrance is blocked while the intent exists
            $writesBlocked=$script:g4Typed.IISSite+$script:g4Typed.ScheduledTask
            $blockedText='';try{$null=Invoke-WsmWizardTargetRestore -Workspace $targetRoot -PairId $pairId -PreviewHash ([string]$previewAfterFail.PreviewHash) -Jobs $jobsAfter}catch{$blockedText=[string]$_.Exception.Message}
            $retry.BlockedText=$blockedText
            & $Report 'p5a_second_restore_over_the_pending_intent_is_refused_and_writes_nothing' ($blockedText -match 'unresolved journal intent|blocks a new parent' -and ($script:g4Typed.IISSite+$script:g4Typed.ScheduledTask) -eq $writesBlocked) $blockedText
            # (2) Resume of the completed-with-failure parent
            $resumeText='';try{$null=Resume-WsmWizardTargetRestore -Workspace $targetRoot -PairId $pairId -ParentOperationId ([string]$restore1.AttemptOperationId) -ContinuationId ([Guid]::NewGuid().ToString('D')) -Jobs $jobsAfter}catch{$resumeText=[string]$_.Exception.Message}
            $retry.ResumeText=$resumeText
            & $Report 'p5a_resume_of_the_partial_parent_is_refused_by_design_and_writes_nothing' ($resumeText -match 'terminal result' -and ($script:g4Typed.IISSite+$script:g4Typed.ScheduledTask) -eq $writesBlocked) $resumeText
            # (3) Repair-WsmOperation clears the intent
            $repair=Repair-WsmOperation -ManifestPath ([string]$pkgImport.ManifestPath) -ExpectedHash ([string]$pkgImport.ManifestHash) -StateDirectory $restoreStateDirectory -Confirm:$false
            $stateAfterRepair=Read-WsmJson (Join-Path (Join-Path $restoreStateDirectory $pairId) 'state.json')
            $retry.Repaired=@($repair.Repaired);$retry.RemainingAfterRepair=[int]$repair.Remaining
            & $Report 'p5a_repair_operation_cleared_the_intent_of_the_failed_iis_item_without_touching_the_others' (@($repair.Repaired) -contains $siteId -and [int]$repair.Remaining -eq 0 -and @($stateAfterRepair.PendingOperations).Count -eq 0 -and $script:g4Typed.IISSite -eq 1 -and $script:g4Typed.ScheduledTask -eq 1) ('repaired='+@($repair.Repaired).Count+' remaining='+$repair.Remaining)
            # (4) a second restore through the wizard: which entrance does the user have now?
            $previewRetry=Get-WsmWizardTargetRestoreProjection -Workspace $targetRoot -PairId $pairId -Jobs $jobsAfter
            $retry.PreviewAfterRepair=[ordered]@{Status=[string]$previewRetry.Status;Hash=[string]$previewRetry.PreviewHash;SameAsBefore=([string]$previewRetry.PreviewHash -ceq [string]$previewAfterFail.PreviewHash);Rows=@($previewRetry.Rows|ForEach-Object {([string]$_.ItemId).Substring(0,8)+' '+[string]$_.Status+'/'+[string]$_.Action})}
            $retryText='';$restore2=$null;try{$restore2=Invoke-WsmWizardTargetRestore -Workspace $targetRoot -PairId $pairId -PreviewHash ([string]$previewRetry.PreviewHash) -Jobs $jobsAfter}catch{$retryText=[string]$_.Exception.Message}
            $retry.RetryError=$retryText
            if($restore2){$retry.Restore2=[ordered]@{Status=[string]$restore2.Status;Replay=[bool]($restore2.PSObject.Properties['Replay'] -and $restore2.Replay);Attempt=[string]$restore2.AttemptOperationId;Items=@($restore2.ItemResults|ForEach-Object {([string]$_.ItemId).Substring(0,8)+'='+[string]$_.Status})}}
            # (4b) observation only: the same receipt replays the earlier Partial result (no native call, the failed item is not retried); a new decision receipt is the way to retry
            $sameReceiptReplay=($restore2 -and [string]$restore2.AttemptOperationId -ceq [string]$restore1.AttemptOperationId -and ($script:g4Typed.IISSite -eq 1))
            $retry.SameReceiptRestoreReplaysEarlierPartialWithoutRetry=[bool]$sameReceiptReplay
            if($MutationName -ceq 'RepairAndRetry'){
            # (5) a new decision receipt that selects only the failed item opens a new parent; the others are not touched
            $receipt3=Create-WsmWizardTargetDecisionReceipt -Workspace $targetRoot -PairId $pairId -Decision RestoreNow -Owner 'G4 target operator' -Reason 'Retry only the failed IIS site after Repair-WsmOperation cleared its intent.' -SelectedItemIds ([string[]]@($siteId)) -Jobs $tJobs
            $preview3=Get-WsmWizardTargetRestoreProjection -Workspace $targetRoot -PairId $pairId -Jobs $jobsAfter
            $retry.Preview3=[ordered]@{Status=[string]$preview3.Status;Rows=@($preview3.Rows|ForEach-Object {([string]$_.ItemId).Substring(0,8)+' '+[string]$_.Status+'/'+[string]$_.Action})}
            $restore3=Invoke-WsmWizardTargetRestore -Workspace $targetRoot -PairId $pairId -PreviewHash ([string]$preview3.PreviewHash) -Jobs $jobsAfter
            $state3=Read-WsmJson (Join-Path (Join-Path $restoreStateDirectory $pairId) 'state.json')
            $r3Site=@($restore3.ItemResults|Where-Object {[string]$_.ItemId -ceq $siteId})
            $siteRecord3=@($state3.Items|Where-Object {[string]$_.ItemId -ceq $siteId})
            $retry.Restore3=[ordered]@{Status=[string]$restore3.Status;Attempt=[string]$restore3.AttemptOperationId;NewParent=([string]$restore3.AttemptOperationId -cne [string]$restore1.AttemptOperationId);Items=@($restore3.ItemResults|ForEach-Object {([string]$_.ItemId).Substring(0,8)+'='+[string]$_.Status})}
            & $Report 'p5a_after_repair_a_new_receipt_restore_retries_only_the_failed_iis_item_which_now_succeeds_the_unselected_rows_stay_deferred_by_selection' (@($restore3.ItemResults).Count -eq 1 -and @($restore3.Deferred|Where-Object {[string]$_.Status -cne 'Deferred' -or [string]$_.Action -cne 'DeferredBySelection'}).Count -eq 0 -and [string]$restore3.AttemptOperationId -cne [string]$restore1.AttemptOperationId -and $r3Site.Count -eq 1 -and [string]$r3Site[0].Status -ceq 'Succeeded' -and $script:g4Typed.IISSite -eq 2 -and $script:g4Typed.ScheduledTask -eq 1 -and @($state3.PendingOperations).Count -eq 0) ('status='+$restore3.Status+' IIS calls='+$script:g4Typed.IISSite+' task calls='+$script:g4Typed.ScheduledTask+' items='+@($restore3.ItemResults).Count)
            & $Report 'p5a_the_retried_item_is_now_owned_and_the_earlier_succeeded_items_keep_their_ownership_records' ($siteRecord3.Count -eq 1 -and [string]$siteRecord3[0].Status -ceq 'Succeeded' -and @($state3.Items|Where-Object {[string]$_.Status -ceq 'Succeeded'}).Count -eq 5) ('succeeded records='+@($state3.Items|Where-Object {[string]$_.Status -ceq 'Succeeded'}).Count)
            $afterRetry=[ordered]@{Unrelated=(Get-TreeMap $unrelated);Site=(Get-TreeMap $siteDir);Jobs=(Get-TreeMap $jobsDir)}
            $retrySame=$true;foreach($key in $afterRetry.Keys){if((Get-Json $before[$key]) -cne (Get-Json $afterRetry[$key])){$retrySame=$false}}
            & $Report 'p5a_the_retry_left_the_c_d_e_trees_byte_identical_to_the_source' $retrySame 'three restored trees re-hashed after the retry'
            $retry.TypedCallsAfterRetry="IIS=$($script:g4Typed.IISSite) Task=$($script:g4Typed.ScheduledTask)"
            }
            if($MutationName -ceq 'RetryFailedButton'){
            # (5') P8: the retry button path. Candidates and the action come from the real runtime projection; the command is the one the action maps to,
            # called with the argument conversion of the console route; Jobs are injected like the worker does.
            $statePathRetry=Join-Path (Join-Path $restoreStateDirectory $pairId) 'state.json'
            $itemsBefore=@((Read-WsmJson $statePathRetry).Items|Where-Object {[string]$_.ItemId -cne $siteId}|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 20 -Compress})
            $stateBytesBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($statePathRetry));$callsBefore="IIS=$($script:g4Typed.IISSite) Task=$($script:g4Typed.ScheduledTask)"
            $cand=Get-WsmWizardTargetRetryCandidates -Workspace $targetRoot -PairId $pairId -Jobs $jobsAfter
            & $Report 'p8_after_repair_the_backend_candidates_are_exactly_the_failed_iis_site_and_the_four_succeeded_items_are_excluded' ($cand.Visible -and $cand.Eligible -and (@($cand.CandidateItemIds) -join ',') -ceq $siteId -and @($cand.SucceededItemIds).Count -eq 4 -and @($cand.Excluded).Count -eq 0 -and [string]$cand.SourceAttemptId -ceq [string]$restore1.AttemptOperationId) ('candidates='+@($cand.CandidateItemIds).Count+' succeeded='+@($cand.SucceededItemIds).Count)
            $runtimeRetry=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $targetRoot -PairId $pairId -Role Target -Jobs $jobsAfter)
            $retryAction=@($runtimeRetry.actions|Where-Object {[string]$_.id -ceq 'TargetRetryFailedItems'})
            & $Report 'p8_runtime_projection_offers_the_retry_action_with_prefilled_owner_and_reason_and_the_same_candidate' ($retryAction.Count -eq 1 -and $retryAction[0].available -eq $true -and $runtimeRetry.runtime.retry.eligible -eq $true -and [string]$runtimeRetry.runtime.retry.defaultOwner -ceq 'G4 target operator' -and [string]$runtimeRetry.runtime.retry.defaultReason -match '1' -and (@($retryAction[0].defaults.SelectedItemIds) -join ',') -ceq $siteId -and [string]$retryAction[0].defaults.RetryOfReceiptHash -ceq [string]$cand.SourceReceiptHash) 'projection action available, defaults carry the candidate and the source receipt hash'
            $handlerMap=Get-WsmHtmlActionMap;$handlerCommand=Get-Command $handlerMap['TargetRetryFailedItems'] -CommandType Function
            $callHandler={param([hashtable]$Overrides)
                $wire=[ordered]@{};foreach($property in $retryAction[0].defaults.PSObject.Properties){$wire[$property.Name]=$property.Value};$wire['Owner']='G4 retry operator';$wire['Reason']='Retry the failed IIS site after the repair';foreach($key in $Overrides.Keys){$wire[$key]=$Overrides[$key]}
                $body=($wire|ConvertTo-Json -Depth 6 -Compress)|ConvertFrom-Json
                $converted=ConvertTo-WsmHtmlArguments $handlerCommand $body
                & $handlerCommand @converted -Jobs $jobsAfter}
            $refusals=@()
            foreach($case in @(@{Name='all five items';Overrides=@{SelectedItemIds=[string[]]$includeIds}},@{Name='a succeeded item only';Overrides=@{SelectedItemIds=[string[]]@([string]$taskItem.ItemId)}},@{Name='empty owner';Overrides=@{Owner=''}},@{Name='blank reason';Overrides=@{Reason='  '}},@{Name='stale source receipt';Overrides=@{RetryOfReceiptHash=('0'*64)}})){
                $refusedText='';try{$null=& $callHandler $case.Overrides}catch{$refusedText=[string]$_.Exception.Message};$refusals+=@($case.Name+': '+$(if($refusedText){'refused'}else{'ACCEPTED'}))
            }
            $retry.HandlerRefusals=$refusals
            & $Report 'p8_the_handler_path_refuses_other_item_ids_an_empty_owner_or_reason_and_a_stale_source_receipt' (@($refusals|Where-Object {$_ -notmatch ': refused$'}).Count -eq 0) ($refusals -join '; ')
            $retryReceipt=& $callHandler @{}
            $retry.RetryReceipt=[ordered]@{Selected=@($retryReceipt.SelectedItemIds|ForEach-Object {([string]$_).Substring(0,8)});Decision=[string]$retryReceipt.Decision}
            $storedRetry=Read-WsmTrustedJson $retryReceipt.ReceiptPath $retryReceipt.ReceiptHash
            & $Report 'p8_new_receipt_selects_only_the_failed_item_with_the_operators_owner_and_reason_and_RestoreNow' ([string]$retryReceipt.Status -ceq 'Succeeded' -and @($retryReceipt.SelectedItemIds).Count -eq 1 -and [string]$retryReceipt.SelectedItemIds[0] -ceq $siteId -and [string]$retryReceipt.Decision -ceq 'RestoreNow' -and [string]$storedRetry.Owner -ceq 'G4 retry operator' -and [string]$storedRetry.Reason -ceq 'Retry the failed IIS site after the repair' -and [string]$retryReceipt.ReceiptHash -cne [string]$receipt1.ReceiptHash) 'receipt selection, decision, owner and reason'
            & $Report 'p8_creating_the_receipt_started_nothing_state_bytes_and_native_call_counts_are_unchanged' (([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePathRetry))) -ceq $stateBytesBefore -and "IIS=$($script:g4Typed.IISSite) Task=$($script:g4Typed.ScheduledTask)" -ceq $callsBefore) $callsBefore
            $preview5=Get-WsmWizardTargetRestoreProjection -Workspace $targetRoot -PairId $pairId -Jobs $jobsAfter
            & $Report 'p8_preview_after_the_new_receipt_covers_exactly_the_failed_item' ([string]$preview5.Status -ceq 'Previewed' -and @($preview5.SelectedItemIds).Count -eq 1 -and [string]$preview5.SelectedItemIds[0] -ceq $siteId) ('status='+$preview5.Status+' selected='+@($preview5.SelectedItemIds).Count)
            $restore5=Invoke-WsmWizardTargetRestore -Workspace $targetRoot -PairId $pairId -PreviewHash ([string]$preview5.PreviewHash) -Jobs $jobsAfter
            $state5=Read-WsmJson $statePathRetry
            $itemsAfter=@($state5.Items|Where-Object {[string]$_.ItemId -cne $siteId}|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 20 -Compress})
            $siteRecord5=@($state5.Items|Where-Object {[string]$_.ItemId -ceq $siteId})
            & $Report 'p8_retry_restore_succeeds_for_the_site_in_a_new_parent_and_the_succeeded_items_were_not_rewritten_records_and_typed_call_counts' (@($restore5.ItemResults).Count -eq 1 -and [string]$restore5.ItemResults[0].ItemId -ceq $siteId -and [string]$restore5.ItemResults[0].Status -ceq 'Succeeded' -and [string]$restore5.AttemptOperationId -cne [string]$restore1.AttemptOperationId -and $script:g4Typed.IISSite -eq 2 -and $script:g4Typed.ScheduledTask -eq 1 -and ($itemsBefore -join "`n") -ceq ($itemsAfter -join "`n") -and $siteRecord5.Count -eq 1 -and [string]$siteRecord5[0].Status -ceq 'Succeeded' -and @($state5.PendingOperations).Count -eq 0) ('IIS calls='+$script:g4Typed.IISSite+' task calls='+$script:g4Typed.ScheduledTask+' other item records unchanged='+(($itemsBefore -join "`n") -ceq ($itemsAfter -join "`n")))
            $afterButton=[ordered]@{Unrelated=(Get-TreeMap $unrelated);Site=(Get-TreeMap $siteDir);Jobs=(Get-TreeMap $jobsDir)}
            $buttonSame=$true;foreach($key in $afterButton.Keys){if((Get-Json $before[$key]) -cne (Get-Json $afterButton[$key])){$buttonSame=$false}}
            & $Report 'p8_the_c_d_e_trees_are_byte_identical_to_the_source_after_the_retry' $buttonSame 'three restored trees re-hashed after the retry'
            $candFinal=Get-WsmWizardTargetRetryCandidates -Workspace $targetRoot -PairId $pairId -Jobs $jobsAfter
            & $Report 'p8_after_the_successful_retry_the_retry_entry_is_hidden' (-not $candFinal.Visible -and [string]$candFinal.ReasonCode -ceq 'AllSucceeded') ([string]$candFinal.ReasonCode)
            $retry.TypedCallsAfterRetry="IIS=$($script:g4Typed.IISSite) Task=$($script:g4Typed.ScheduledTask)"
            }
            $obs.RepairAndRetry=$retry
            Save-Obs
        }
        $obs
    } $script:GTestRoot $fixturePath $Mutation ${function:Set-GCheck} ($wsDrive+':'+[char]92) ($dDrive+':'+[char]92) ($eDrive+':'+[char]92) $Through $script:GRunDir
    $script:GVerdict.Observations=$observations

    Write-GStage 3 'snapshot unchanged, test bytes recorded'
    Confirm-GSnapshotUnchanged @((Join-Path $PSScriptRoot 'G-ScenarioCommon.ps1'),$PSCommandPath)
}
catch{
    $script:GVerdict.Error=[string]$_.Exception.Message
    $script:GVerdict.ErrorPosition=[string]$_.InvocationInfo.PositionMessage
    $script:GVerdict.ErrorStack=[string]$_.ScriptStackTrace
    $innerMessages=@();$inner=$_.Exception.InnerException;while($inner){$innerMessages+=@([string]$inner.Message);if($inner -is [Management.Automation.IContainsErrorRecord]){$innerMessages+=@([string]$inner.ErrorRecord.InvocationInfo.PositionMessage,[string]$inner.ErrorRecord.ScriptStackTrace)};$inner=$inner.InnerException};$script:GVerdict.ErrorInner=$innerMessages
    Write-Host ('FAILED: '+$_.Exception.Message)
    $script:GFailed=$true
}
finally{
    $overall=Complete-GScenario ([bool]$KeepArtifacts)
}
if($overall -cne 'Passed'){exit 1}
