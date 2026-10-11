#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wsm-task-security-'+[Guid]::NewGuid().ToString('N'))))
if(-not $root.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'Workflow fixture cleanup root escaped the temp directory.'}
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:fixtureTasks=@{};$script:fixtureFolders=@{};$script:fixtureFingerprint=('a'*64);$script:fixtureRootSddl='O:SYG:SYD:(A;;FA;;;SY)';$script:fixtureOpsSddl='O:SYG:SYD:(A;;FA;;;SY)(A;;FR;;;BA)';$script:fixtureNestedSddl='O:SYG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)';$script:failReadbackPath=''
        function script:Get-WsmToolFingerprint {'a'*64}
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture';OS='Fixture Server';Version='10.fixture';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:New-WsmFixtureTaskFolder([string]$Path,[string]$Sddl){
            $folder=[pscustomobject]@{Path=$Path;SecuritySddl=$Sddl}
            $folder | Add-Member ScriptMethod GetSecurityDescriptor {param($Flags)if($Flags -ne 7){throw 'Expected exact owner/group/DACL query.'};$this.SecuritySddl}
            $folder | Add-Member ScriptMethod GetFolder {param($Name)$path=$this.Path;if($path -ceq '\'){$path='\'+$Name+'\'}else{$path=$path+$Name+'\'};if($script:failReadbackPath -ceq $path -and $script:fixtureFolders.ContainsKey($path)){$script:failReadbackPath='';throw (New-Object System.Runtime.InteropServices.COMException('interrupted readback',-2147024891))};if(-not $script:fixtureFolders.ContainsKey($path)){throw (New-Object System.Runtime.InteropServices.COMException('missing folder',-2147024894))};$script:fixtureFolders[$path]}
            $folder | Add-Member ScriptMethod CreateFolder {param($Name,$Sddl)if($this.Path -ceq '\'){$path='\'+$Name+'\'}else{$path=$this.Path+$Name+'\'};if($script:fixtureFolders.ContainsKey($path)){throw 'Folder already exists.'};$created=New-WsmFixtureTaskFolder $path $Sddl;$script:fixtureFolders[$path]=$created;$created}
            $folder | Add-Member ScriptMethod GetTask {param($Name)$script:fixtureTasks[$this.Path+$Name]}
            $folder | Add-Member ScriptMethod GetTasks {param($Flags)@($script:fixtureTasks.Keys | Where-Object {$_.StartsWith($this.Path,[StringComparison]::OrdinalIgnoreCase) -and $_.Substring($this.Path.Length).IndexOf('\') -lt 0} | ForEach-Object {$script:fixtureTasks[$_]})}
            $folder | Add-Member ScriptMethod GetFolders {param($Flags)@($script:fixtureFolders.Values | Where-Object {$_.Path -ne $this.Path -and $_.Path.StartsWith($this.Path,[StringComparison]::OrdinalIgnoreCase) -and $_.Path.Substring($this.Path.Length).Trim('\').IndexOf('\') -lt 0})}
            $folder | Add-Member ScriptMethod DeleteFolder {param($Name,$Flags)$path=$this.Path+$Name+'\';if(@($script:fixtureTasks.Keys | Where-Object {$_.StartsWith($path,[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Folder contains task.'};if(@($script:fixtureFolders.Values | Where-Object {$_.Path -ne $path -and $_.Path.StartsWith($path,[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Folder contains child folder.'};[void]$script:fixtureFolders.Remove($path)}
            $folder
        }
        $script:fixtureFolders['\']=New-WsmFixtureTaskFolder '\' $script:fixtureRootSddl
        $script:fixtureScheduler=[pscustomobject]@{};$script:fixtureScheduler | Add-Member ScriptMethod GetFolder {param($Path)if($Path -ceq '\'){return $script:fixtureFolders['\']};$folder=$script:fixtureFolders['\'];foreach($part in $Path.Trim('\').Split('\')){$folder=$folder.GetFolder($part)};$folder}
        function script:New-WsmTaskScheduler {$script:fixtureScheduler}
        function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$script:fixtureTasks[$TaskPath+$TaskName]}
        function script:Export-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$script:fixtureTasks[$TaskPath+$TaskName].Xml}
        function script:Register-ScheduledTask {param($TaskName,$TaskPath,$Xml,$User,$Password,$ErrorAction)$doc=Read-WsmXml $Xml;$enabled=$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");if(-not $enabled -or $enabled.InnerText -cne 'false'){throw 'Task registration was not disabled.'};$task=[pscustomobject]@{Xml=$Xml;SecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';Settings=[pscustomobject]@{Enabled=$false}};$task | Add-Member ScriptMethod SetSecurityDescriptor {param($Sddl,$Flags)$this.SecuritySddl=$Sddl};$task | Add-Member ScriptMethod GetSecurityDescriptor {param($Flags)if($Flags -ne 7){throw 'Expected exact task security query.'};$this.SecuritySddl};$script:fixtureTasks[$TaskPath+$TaskName]=$task}
        function script:Disable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$task=$script:fixtureTasks[$TaskPath+$TaskName];$doc=Read-WsmXml $task.Xml;$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']").InnerText='false';$task.Xml=$doc.OuterXml;$task.Settings.Enabled=$false}
        function script:Enable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$task=$script:fixtureTasks[$TaskPath+$TaskName];$doc=Read-WsmXml $task.Xml;$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']").InnerText='true';$task.Xml=$doc.OuterXml;$task.Settings.Enabled=$true}
        function script:Unregister-ScheduledTask {param($TaskName,$TaskPath,$Confirm)$script:fixtureTasks.Remove($TaskPath+$TaskName)}
        function script:Export-WsmInventory {param($OutputDirectory,[switch]$DeepDiscovery)[pscustomobject]@{Path=$script:fixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:fixtureInventoryPath).Hash}}
        function New-TaskSecurityFixture {
            param([string]$Name,[int]$TaskCount=2,[switch]$InterruptAfterCreate)
            $caseRoot=Join-Path $Root $Name;[void][IO.Directory]::CreateDirectory($caseRoot)
            $script:fixtureTasks=@{};$script:fixtureFolders=@{};$script:fixtureFolders['\']=New-WsmFixtureTaskFolder '\' $script:fixtureRootSddl;$script:failReadbackPath=''
            $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source';OS='Fixture Server';Version='10.fixture'};$items=New-Object 'System.Collections.Generic.List[object]'
            $xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>SYSTEM</UserId><LogonType>ServiceAccount</LogonType></Principal></Principals><Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers><Settings><Enabled>true</Enabled><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy></Settings><Actions><Exec><Command>C:\Fixture\task.exe</Command></Exec></Actions></Task>'
            for($n=1;$n -le $TaskCount;$n++){$taskName='FixtureTask'+$n;$settings=[ordered]@{TaskName=$taskName;TaskPath='\Ops\Nested\';Xml=$xml;TaskSecurityCaptureStatus='Captured';TaskSecurityCapture=[pscustomobject]@{SchemaVersion=1;Kind='TaskSecurityCapture';TaskPath='\Ops\Nested\';TaskName=$taskName;TaskFullPath=('\Ops\Nested\'+$taskName);TaskSecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';TaskSecurityHash=(Get-WsmHashText 'O:SYG:SYD:(A;;FA;;;SY)');Folders=@([pscustomobject]@{Path='\';SecuritySddl=$script:fixtureRootSddl;SecurityHash=(Get-WsmHashText $script:fixtureRootSddl)},[pscustomobject]@{Path='\Ops\';SecuritySddl=$script:fixtureOpsSddl;SecurityHash=(Get-WsmHashText $script:fixtureOpsSddl)},[pscustomobject]@{Path='\Ops\Nested\';SecuritySddl=$script:fixtureNestedSddl;SecurityHash=(Get-WsmHashText $script:fixtureNestedSddl)})}};$items.Add((New-WsmItem $source.HostId Tasks ScheduledTask $taskName ('\Ops\Nested\'+$taskName) $settings))}
            $inventory=New-WsmInventory $source 1 $items.ToArray();$inventoryPath=Join-Path $caseRoot 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:fixtureInventoryPath=$inventoryPath
            $workspace=Join-Path $caseRoot 'manager';Initialize-WsmWorkspace $workspace | Out-Null;$catalog=Import-WsmInventory $workspace $inventoryPath (Get-FileHash $inventoryPath).Hash ('fixture-target-'+$Name)
            foreach($item in $catalog.Items){$security=Get-WsmTaskSecurityDraftFields $item.Settings;$folderSecurity=@($security.FolderSecurity);$spec=[pscustomobject]@{Adapter='ScheduledTask';CatchUpPolicy='PreserveSourceSettings';DesiredFinalState='Enabled';Owner='fixture task owner';Evidence='fixture owner review';BusinessChecks=@('isolated task check');Desired=[pscustomobject]@{TaskName=$item.Settings.TaskName;TaskPath=$item.Settings.TaskPath;Xml=$item.Settings.Xml;User='SYSTEM';SecuritySddl=$security.SecuritySddl;FolderSecurity=$folderSecurity}};$specPath=Join-Path $caseRoot ($item.Settings.TaskName+'.json');Write-WsmJson $specPath $spec;Set-WsmMigrationSpec $workspace $catalog.PairId $item.ItemId $specPath (Get-FileHash $specPath).Hash $catalog.DecisionRevision;$catalog=Get-WsmCatalog $workspace $catalog.PairId;Set-WsmDecision $workspace $catalog.PairId @($item.ItemId) Include 'fixture task ACL approved' $catalog.DecisionRevision | Out-Null;$catalog=Get-WsmCatalog $workspace $catalog.PairId}
            $targetState=Join-Path $caseRoot 'target-state';$targetIdentityPath=Join-Path $caseRoot 'target.json';$script:fixtureFingerprint=('b'*64);$targetIdentity=Register-WsmTarget $targetState $targetIdentityPath
            $planPath=Join-Path $caseRoot 'plan.json';$approval=Approve-WsmMigrationPlan $workspace $catalog.PairId $targetIdentityPath $targetIdentity.SHA256 $planPath $catalog.DecisionRevision 'ISOLATED-PILOT'
            $script:fixtureFingerprint=('a'*64);$sourceState=Join-Path $caseRoot 'source-state';[void][IO.Directory]::CreateDirectory($sourceState);$packages=Join-Path $caseRoot 'packages';$package=Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState $packages
            $script:fixtureFingerprint=('b'*64);$statePath=Join-Path $caseRoot 'restore-state'
            if($InterruptAfterCreate){$script:failReadbackPath='\Ops\'}
            [pscustomobject]@{Root=$caseRoot;PairId=$catalog.PairId;StatePath=$statePath;Package=$package;PlanPath=$planPath;PlanHash=$approval.SHA256;Items=@($catalog.Items);Spec=$catalog.Items[0].MigrationSpec}
        }

        $shared=New-TaskSecurityFixture 'shared-folders' 2
        $preview=Get-WsmRestorePreview $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath
        if($preview.Blocked -or @($preview.Rows | Where-Object Action -ne 'Create').Count){throw ('Shared nested task folders did not pass the initial create preview: '+($preview | ConvertTo-Json -Depth 10 -Compress))}
        $state=Invoke-WsmRestore $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath
        if($state.Stage -ne 'Succeeded' -or $state.Items.Count -ne 2 -or $state.Items[0].AuxiliaryOwnership.Count -ne 2 -or $state.Items[1].AuxiliaryOwnership.Count -ne 0){throw 'Shared folder receipt ownership was duplicated or not durably attached to its creator.'}
        if(-not $script:fixtureFolders.ContainsKey('\Ops\Nested\') -or -not $script:fixtureFolders.ContainsKey('\Ops\')){throw 'Nested target folders were not created.'}
        $reservationPackage=Test-WsmMigrationPackage $shared.Package.ManifestPath $shared.Package.SHA256
        foreach($reservationItem in $reservationPackage.Plan.Items){[void](Get-WsmAssistiveReservations $reservationItem $reservationPackage $shared.StatePath)}
        $reservationRegistry=Get-WsmAssistiveResourceRegistry $shared.StatePath
        $folderReservations=@($reservationRegistry.Resources | Where-Object ResourceKind -EQ TaskFolder)
        if($folderReservations.Count -ne 3 -or @($folderReservations | Where-Object {$_.Owners.Count -ne 2}).Count){throw 'Real native task reservations did not permit distinct nested folders and matching shared folder definitions.'}
        $reservationRevision=$reservationRegistry.Revision
        foreach($reservationItem in $reservationPackage.Plan.Items){[void](Get-WsmAssistiveReservations $reservationItem $reservationPackage $shared.StatePath)}
        if((Get-WsmAssistiveResourceRegistry $shared.StatePath).Revision -ne $reservationRevision){throw 'Native task reservation retry duplicated existing owners.'}
        $replayPaths=Get-WsmOperationPaths $shared.StatePath $shared.PairId
        $replaySeed=ConvertFrom-WsmJson ($state | ConvertTo-Json -Depth 40);$replaySeed.Sequence=0;$replaySeed.JournalHash=('0'*64);$replaySeed.Items=@();$replaySeed.PendingOperations=@()
        Write-WsmJson $replayPaths.State $replaySeed;Restore-WsmJournalCheckpoint $replayPaths $replaySeed
        if($replaySeed.Items.Count -ne 2 -or $replaySeed.Items[0].AuxiliaryOwnership.Count -ne 2 -or $replaySeed.PendingOperations.Count -or -not (Test-WsmJournal $shared.StatePath $shared.PairId).Consistent){throw 'Actual task creation callback journal failed exact checkpoint replay.'}
        $retried=Invoke-WsmRestore $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath
        if($retried.Stage -ne 'Succeeded' -or $retried.Items[0].AuxiliaryOwnership.Count -ne 2 -or $retried.Items[1].AuxiliaryOwnership.Count -ne 0){throw 'Owned task retry must verify shared folders while retaining only creator ownership.'}
        $validation=Invoke-WsmValidation $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath
        if($validation.Checks.Count -ne 2 -or @($validation.Checks | Where-Object {-not $_.ConfigurationPassed}).Count -or @($validation.Checks | Where-Object BusinessPassed -EQ $true).Count){throw 'Staged validation must reuse exact owned/shared folder receipts without inventing business evidence.'}
        $script:fixtureFolders['\Ops\Nested\'].SecuritySddl='O:SYG:SYD:(A;;FR;;;BA)'
        $validationDrift=Invoke-WsmValidation $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath
        if(@($validationDrift.Checks | Where-Object ConfigurationPassed -EQ $true).Count){throw 'Staged validation accepted folder ACL drift.'}
        $drift=Get-WsmRestorePreview $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath
        if(-not $drift.Blocked){throw 'Nested folder ACL drift was accepted for retry.'}
        $rollbackDrift=Get-WsmRollbackPreview $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath
        if(@($rollbackDrift.Rows | Where-Object {-not $_.Blocked}).Count){throw 'Rollback preview allowed task removal after folder ACL drift.'}
        $script:fixtureFolders['\Ops\Nested\'].SecuritySddl=$script:fixtureNestedSddl
        $rollback=Get-WsmRollbackPreview $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath
        $rolled=Invoke-WsmRollback $shared.Package.ManifestPath $shared.Package.SHA256 $shared.StatePath $rollback.PreviewHash ('ROLLBACK '+$shared.PairId)
        if($rolled.Stage -ne 'RolledBack' -or $script:fixtureTasks.Count -ne 0 -or $script:fixtureFolders.ContainsKey('\Ops\') -or $script:fixtureFolders.ContainsKey('\Ops\Nested\')){throw 'Rollback did not remove created tasks and last-use owned folders in reverse nesting order.'}

        $activation=New-TaskSecurityFixture 'shared-activation' 2
        $activationState=Invoke-WsmRestore $activation.Package.ManifestPath $activation.Package.SHA256 $activation.StatePath
        $activationPackage=Test-WsmMigrationPackage $activation.Package.ManifestPath $activation.Package.SHA256
        $activationPaths=Get-WsmOperationPaths $activation.StatePath $activation.PairId
        $guardPackage=ConvertFrom-WsmJson ($activationPackage | ConvertTo-Json -Depth 60);$guardPackage.Plan.SchemaVersion=3;$guardPackage.Plan | Add-Member NoteProperty Assistive ([pscustomobject]@{ApprovedItemIds=@($guardPackage.Plan.Items.ItemId)})
        foreach($guardItem in $guardPackage.Plan.Items){$guardSpec=$guardItem.MigrationSpec;$guardSpec | Add-Member NoteProperty SourceXml ([string]$guardSpec.Desired.Xml);$guardSpec | Add-Member NoteProperty SourceAutoStart 'true';$guardSpec | Add-Member NoteProperty StagedDisabled $true;$guardSpec | Add-Member NoteProperty ActivationPolicyFieldPointer 'Task/Settings/Enabled';$guardSpec | Add-Member NoteProperty ReviewedActivation ([pscustomobject]@{FinalState='Enabled';Owner='Fixture task owner';Reason='Preserve reviewed source enabled task intent';SourceAutoStart='true';FieldPointer='Task/Settings/Enabled'})}
        $guardReceiptPath=Join-Path $activation.Root 'decision.json';$guardSnapshotPath=Join-Path $activation.Root 'snapshot.json'
        $guardAttempt=[pscustomobject]@{ManifestHash=$guardPackage.SHA256;Generation=$guardPackage.Manifest.Generation;DecisionReceiptPath=$guardReceiptPath;DecisionReceiptHash=('4'*64);TargetSnapshotPath=$guardSnapshotPath;TargetSnapshotHash=('5'*64);SelectedItemIds=@($guardPackage.Plan.Items.ItemId)}
        $activationState | Add-Member NoteProperty RestoreAttempt $guardAttempt -Force
        foreach($guardRecord in $activationState.Items){$guardRecord | Add-Member NoteProperty AppliedManifestHash $guardPackage.SHA256 -Force;$guardRecord | Add-Member NoteProperty AppliedGeneration $guardPackage.Manifest.Generation -Force}
        $script:guardDecisionFixture=[pscustomobject]@{Receipt=[pscustomobject]@{Decision='RestoreNow';TargetSnapshotHash=('5'*64)};ReceiptHash=('4'*64);ReceiptPath=$guardReceiptPath;SnapshotPath=$guardSnapshotPath;SelectedItemIds=@($guardPackage.Plan.Items.ItemId)}
        $nativeDecisionGuard=(Get-Command Get-WsmAssistiveRestoreDecision -CommandType Function).ScriptBlock
        Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value {param($Package,$ManifestHash,$ReceiptPath,$ReceiptHash,$SnapshotPath)$script:guardDecisionFixture}
        Assert-WsmAssistiveCutoverActivationIntent $guardPackage $activation.StatePath $activationState
        $activationState.Cutover=[pscustomobject]@{Activations=@();NewTransactionsPossible=$true}
        Invoke-WsmActivationSequence $activationPackage $activationPaths $activationState
        if($activationState.Cutover.Activations.Count -ne 2 -or @($activationState.Cutover.Activations | Where-Object Status -NE Completed).Count -or @($script:fixtureTasks.Values | Where-Object {$_.Settings.Enabled -ne $true}).Count){throw 'Native task activation failed to reuse owned/shared security receipts.'}
        foreach($guardItem in $guardPackage.Plan.Items){$activationState.Cutover.Activations | Where-Object ItemId -CEQ $guardItem.ItemId | ForEach-Object {$_.SpecHash=Get-WsmHashText ($guardItem.MigrationSpec | ConvertTo-Json -Depth 40 -Compress)}}
        Assert-WsmAssistiveCutoverActivationIntent $guardPackage $activation.StatePath $activationState
        $firstActivation=$activationState.Cutover.Activations[0];$firstGuardItem=@($guardPackage.Plan.Items | Where-Object ItemId -CEQ $firstActivation.ItemId)[0];$firstActivation.Status='Intent';Assert-WsmAssistiveCutoverActivationIntent $guardPackage $activation.StatePath $activationState;$firstActivation.Status='Completed'
        Disable-ScheduledTask -TaskName $firstGuardItem.MigrationSpec.Desired.TaskName -TaskPath $firstGuardItem.MigrationSpec.Desired.TaskPath
        $completedStageRejected=$false;try{Assert-WsmAssistiveCutoverActivationIntent $guardPackage $activation.StatePath $activationState}catch{$completedStageRejected=$true}
        if(-not $completedStageRejected){throw 'Completed Assistive activation checkpoint accepted a staged-only task.'}
        $firstActivation.Status='Intent';Assert-WsmAssistiveCutoverActivationIntent $guardPackage $activation.StatePath $activationState
        Enable-ScheduledTask -TaskName $firstGuardItem.MigrationSpec.Desired.TaskName -TaskPath $firstGuardItem.MigrationSpec.Desired.TaskPath
        $firstActivation.Status='Completed';$firstActivation.SpecHash=('f'*64);$checkpointDriftRejected=$false;try{Assert-WsmAssistiveCutoverActivationIntent $guardPackage $activation.StatePath $activationState}catch{$checkpointDriftRejected=$true}
        if(-not $checkpointDriftRejected){throw 'Assistive activation guard accepted a changed checkpoint spec binding.'}
        $firstActivation.SpecHash=Get-WsmHashText ($firstGuardItem.MigrationSpec | ConvertTo-Json -Depth 40 -Compress)
        Set-Item Function:\Get-WsmAssistiveRestoreDecision -Value $nativeDecisionGuard
        foreach($originalItem in $activationPackage.Plan.Items){$activationState.Cutover.Activations | Where-Object ItemId -CEQ $originalItem.ItemId | ForEach-Object {$_.SpecHash=Get-WsmHashText ($originalItem.MigrationSpec | ConvertTo-Json -Depth 40 -Compress)}}
        $script:fixtureFolders['\Ops\Nested\'].SecuritySddl='O:SYG:SYD:(A;;FR;;;BA)'
        $activationDriftBlocked=$false;try{Invoke-WsmActivationSequence $activationPackage $activationPaths $activationState -Resume}catch{$activationDriftBlocked=$true}
        if(-not $activationDriftBlocked){throw 'Completed task activation resume accepted shared folder security drift.'}
        $script:fixtureFolders['\Ops\Nested\'].SecuritySddl=$script:fixtureNestedSddl
        Invoke-WsmActivationSequence $activationPackage $activationPaths $activationState -Resume
        if($activationState.Cutover.Activations.Count -ne 2){throw 'Completed task activation resume duplicated checkpoints.'}
        $interrupted=New-TaskSecurityFixture 'interrupted-create' 1 -InterruptAfterCreate
        $failed=$false;try{Invoke-WsmRestore $interrupted.Package.ManifestPath $interrupted.Package.SHA256 $interrupted.StatePath | Out-Null}catch{$failed=$true}
        if(-not $failed -or $script:fixtureTasks.Count -ne 0 -or -not $script:fixtureFolders.ContainsKey('\Ops\')){throw 'Injected post-create/readback interruption did not preserve the folder intent boundary.'}
        $checkpoint=Join-Path (Join-Path $interrupted.StatePath $interrupted.PairId) 'state.json';$live=Read-WsmJson $checkpoint;$pending=@($live.PendingOperations | Where-Object {$_.Phase -eq 'AdapterCreating' -and $_.Adapter -eq 'ScheduledTask'})
        if($pending.Count -ne 1 -or $pending[0].FolderCreateIntents.Count -ne 1 -or $pending[0].AuxiliaryOwnership.Count -ne 0){throw 'Interrupted created folder did not retain intent without a false ownership receipt.'}
        $repairFailed=$false;try{Repair-WsmOperation $interrupted.Package.ManifestPath $interrupted.Package.SHA256 $interrupted.StatePath | Out-Null}catch{$repairFailed=$true}
        if(-not $repairFailed -or -not $script:fixtureFolders.ContainsKey('\Ops\') -or $script:fixtureTasks.Count -ne 0){throw 'Recovery adopted or deleted an unreceipted interrupted folder.'}
        $rollbackBlocked=$false;try{Get-WsmRollbackPreview $interrupted.Package.ManifestPath $interrupted.Package.SHA256 $interrupted.StatePath | Out-Null}catch{$rollbackBlocked=$true};if(-not $rollbackBlocked){throw 'Rollback proceeded while folder creation ownership remained ambiguous.'}
        if(-not (Test-WsmJournal $interrupted.StatePath $interrupted.PairId).Consistent){throw 'Task folder intent/receipt journal chain failed verification.'}
        Write-Host 'PASS: real plan/package/state/journal workflow verifies shared nested Task Scheduler ACL ownership, exact staged tasks, drift blocking, safe reverse rollback and ambiguous create/readback interruption.'
    } $root
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-task-security-*'){throw 'Workflow fixture cleanup ownership guard failed.'}
    if([IO.Directory]::Exists($resolved)){[IO.Directory]::Delete($resolved,$true)}
}
