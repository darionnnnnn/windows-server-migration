#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$bulk=Join-Path $PSScriptRoot '..\src\WizardPreparationBulk.ps1'
& $module {param($path) . $path} $bulk
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-manager-journey-'+[Guid]::NewGuid().ToString('N').Substring(0,10))
[void][IO.Directory]::CreateDirectory($root)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()){& $script:module $Block @Arguments}
function SaveJson($Data,[string]$Path){CallModule {param($value,$file) Write-WsmJson $file $value|Out-Null} @($Data,$Path);$Path}
function NewSoftwareCatalog($Inventory){
    CallModule {
        param($inventory)
        $coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc='2026-10-14T00:00:00Z'})
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$inventory.Source.HostId;Fingerprint=$inventory.Source.Fingerprint;Name=$inventory.Source.Name;InventoryRevision=[int]$inventory.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=('0'*64)}
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog;Assert-WsmSoftwareCatalog $catalog -SourceInventory $inventory|Out-Null;$catalog
    } @($Inventory)
}
function NewInventoryJob([string]$Workspace,[string]$Role,[string]$Path,[string]$Hash){
    [pscustomobject]@{jobId=[Guid]::NewGuid().ToString('D');action='Inventory';status='Succeeded';role=$Role;workspace=$Workspace;CompletedUtc=[DateTime]::UtcNow.ToString('o');outputs=@([pscustomobject]@{Path=$Path;SHA256=$Hash})}
}
try {
    # Each local-host fact is synthetic. Enrollment, inventory contracts,
    # source handoff, Target registration/export, Manager preview/commit,
    # preparation, comparison, approval, and received-plan import are real.
    $script:fingerprint='a'*64
    CallModule {param($fp) $script:journeyFingerprint=$fp;function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:journeyFingerprint;Name=$(if($script:journeyFingerprint -ceq ('a'*64)){'journey-source'}elseif($script:journeyFingerprint -ceq ('b'*64)){'journey-target'}else{'journey-manager'});OS='Windows Server';Version='2025';IsServer=$true;Administrator=$true;Is64Bit=$true}}} @($script:fingerprint)

    $sourceRoot=Join-Path $root 'source';$sourceWorkspace=CallModule {param($w) Initialize-WsmOutputWorkspace -WorkRoot $w -Role Source} @($sourceRoot);CallModule {param($w) Initialize-WsmWizardWorkspace $w Source|Out-Null} @($sourceRoot)
    $firstUse=CallModule {param($w) Get-WsmWizardState $w '' Source} @($sourceRoot)
    $firstUse=CallModule {param($w,$rev) Set-WsmWizardState $w '' Source $rev ([pscustomobject]@{Mode='Automatic';AutoContinue=$true})} @($sourceRoot,$firstUse.Revision)

    $sourceFacts=[pscustomobject]@{HostId=$sourceWorkspace.HostId;Fingerprint=$sourceWorkspace.Profile.Fingerprint;Name='journey-source'}
    $sourceServiceSettings=[pscustomobject][ordered]@{Name='JourneySvc';DisplayName='Journey service';Description='Fixture service';PathName='C:\Fixture\journey.exe';StartMode='Disabled';StartName='LocalSystem';ServiceType='Win32OwnProcess';Supplement=[pscustomobject][ordered]@{ServiceType='Win32OwnProcess';ErrorControl='Normal';LoadOrderGroup='';DelayedAutoStart=$false;FailureActions=[pscustomobject][ordered]@{ResetPeriodSeconds=0;RebootMessage='';Command='';Actions=@()};FailureActionsOnNonCrashFailures=$false;ServiceSidType='None';RequiredPrivileges=@();Environment=@();Triggers=@()}}
    $included=CallModule {param($hostId,$settings) New-WsmItem $hostId Services Service 'Journey service' 'JourneySvc' $settings @() Success Service} @($sourceFacts.HostId,$sourceServiceSettings)
    $excluded=CallModule {param($hostId) New-WsmItem $hostId Identity LocalGroup 'Review-only group' 'S-1-5-21-1-2-3-2001' ([pscustomobject]@{Name='Review-only group';SID='S-1-5-21-1-2-3-2001';Members=@()}) @() Success LocalGroup} @($sourceFacts.HostId)
    $sourceInventory=CallModule {param($host,$items) New-WsmInventory $host 1 $items} @($sourceFacts,@($included,$excluded));$sourceInventory|Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $sourceInventory)
    $sourceInventoryPath=Join-Path $sourceWorkspace.InventoryDirectory 'inventory-1.json';SaveJson $sourceInventory $sourceInventoryPath|Out-Null;$sourceHash=(Get-FileHash -LiteralPath $sourceInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant();$sourceJob=NewInventoryJob $sourceRoot Source $sourceInventoryPath $sourceHash
    $bound=CallModule {param($w,$id,$rev,$jobs) Set-WsmWizardInventoryBinding -Workspace $w -Role Source -JobId $id -ExpectedWizardRevision $rev -Jobs $jobs} @($sourceRoot,$sourceJob.jobId,$firstUse.Revision,@($sourceJob))
    $sourceState=CallModule {param($w) Get-WsmWizardState $w '' Source} @($sourceRoot)
    foreach($row in @(@{Item=$included;Selected=$true;Reason=''},@{Item=$excluded;Selected=$false;Reason='Not included by owner review.'})){
        $saved=CallModule {param($w,$itemId,$selected,$reason,$inventoryRevision,$wizardRevision,$job) Set-WsmWizardChoice -Workspace $w -Role Source -ItemId $itemId -Selected $selected -Reason $reason -ExpectedDecisionRevision $inventoryRevision -ExpectedSelectionRevision $wizardRevision -ExpectedWizardRevision $wizardRevision -Jobs @($job)} @($sourceRoot,$row.Item.ItemId,$row.Selected,$row.Reason,$sourceInventory.Revision,$sourceState.Revision,$sourceJob)
        $sourceState=CallModule {param($w) Get-WsmWizardState $w '' Source} @($sourceRoot)
    }
    $sourceProjection=CallModule {param($w,$job) Get-WsmWizardProjection $w '' Source @($job)} @($sourceRoot,$sourceJob)
    Check ($sourceProjection.mode -ceq 'Automatic' -and $sourceProjection.state.AutoContinue -and $sourceProjection.sourceInventory.sha256 -ceq $sourceHash) 'Source first-use preferences or verified inventory binding were not current before handoff.'
    $sourceHandoff=CallModule {param($w,$job) Export-WsmWizardSourceReviewHandoff -Workspace $w -Jobs @($job)} @($sourceRoot,$sourceJob)
    Check ($sourceHandoff.Status -ceq 'Succeeded' -and $sourceHandoff.ConfirmedChoiceCount -eq 2 -and $sourceHandoff.IncludedChoiceCount -eq 1 -and -not $sourceHandoff.AuthoritativeApproval) 'Source did not export the exact confirmed review intent as a non-authoritative handoff.'

    $managerRoot=Join-Path $root 'manager';CallModule {param($w) Initialize-WsmOutputWorkspace -WorkRoot $w -Role Manager|Out-Null;Initialize-WsmWorkspace $w|Out-Null;Initialize-WsmWizardWorkspace $w Manager|Out-Null} @($managerRoot)
    $managerImport=CallModule {param($w,$path,$hash) Import-WsmWizardSourceReviewHandoff -Workspace $w -Path $path -ExpectedHash $hash -TargetName 'journey-target'} @($managerRoot,$sourceHandoff.Path,$sourceHandoff.SHA256)
    $pairId=[string]$managerImport.PairId;$catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$pairId)
    Check ($managerImport.Status -ceq 'Succeeded' -and $managerImport.AppliedChoiceCount -eq 2 -and @($catalog.Items|Where-Object Decision -CEQ Include|ForEach-Object ItemId) -join '|' -ceq $included.ItemId) 'Manager did not import the exact Source intent set into decisions.'
    Check (@($catalog.Assistive.Selections.Items|Where-Object Selected|ForEach-Object ItemId) -join '|' -ceq $included.ItemId) 'Manager source and Assistive selections differ from the imported source intent.'
    $catalog=CallModule {param($w,$p,$rev) Enable-WsmAssistiveMode $w $p $rev} @($managerRoot,$pairId,$catalog.DecisionRevision)
    $sourceHashBefore=[string]$catalog.InventoryHash;$sourceSnapshotHashBefore=[string]$catalog.Assistive.SourceSnapshot.SHA256

    $script:fingerprint='b'*64;CallModule {param($fp) $script:journeyFingerprint=$fp} @($script:fingerprint)
    $targetRoot=Join-Path $root 'target';CallModule {param($w) Initialize-WsmWizardWorkspace $w Target|Out-Null} @($targetRoot)
    $targetWorkspace=CallModule {param($w) Initialize-WsmOutputWorkspace -WorkRoot $w -Role Target} @($targetRoot)
    $registeredPath=Join-Path $root 'registered-target.json';$registration=CallModule {param($state,$path) Register-WsmTarget $state $path} @($targetWorkspace.StateDirectory,$registeredPath)
    $identityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetWorkspace.HostId)) 'target-identity.json';$identityHash=(Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Check ($registration.Enrolled -and $registration.Target.HostId -ceq $targetWorkspace.HostId -and $identityHash -ieq $registration.SHA256) 'Target did not preserve the exact registered identity bytes.'
    $targetFacts=[pscustomobject]@{HostId=$targetWorkspace.HostId;Fingerprint=$targetWorkspace.Profile.Fingerprint;Name='journey-target'}
    $targetInventory=CallModule {param($host) New-WsmInventory $host 1 @()} @($targetFacts);$targetInventory|Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $targetInventory)
    $targetInventoryPath=Join-Path $targetWorkspace.InventoryDirectory 'inventory-1.json';SaveJson $targetInventory $targetInventoryPath|Out-Null;$targetInventoryHash=(Get-FileHash -LiteralPath $targetInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $targetHandoffDirectory=Join-Path $root 'target-handoff';$targetExport=CallModule {param($w,$i,$o) Export-WsmWizardTargetHandoff -WorkRoot $w -InventoryPath $i -OutputDirectory $o} @($targetRoot,$targetInventoryPath,$targetHandoffDirectory)
    $independentManifestHash=(Get-FileHash -LiteralPath $targetExport.ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Check ($targetExport.Status -ceq 'Exported' -and $targetExport.ObservedManifestHash -ceq $independentManifestHash -and $targetExport.Target.HostId -ceq $registration.Target.HostId -and $targetExport.InventoryHash -ceq $targetInventoryHash) 'Target handoff export did not bind registered identity and exact inventory bytes.'
    $tampered=Join-Path $root 'tampered-target';[void][IO.Directory]::CreateDirectory($tampered);Get-ChildItem -LiteralPath $targetHandoffDirectory -File|Copy-Item -Destination $tampered
    [IO.File]::AppendAllText((Join-Path $tampered 'target-inventory.json'),' ')
    $tamperManifest=CallModule {param($p) Read-WsmJson $p} (Join-Path $tampered 'handoff.json');$tamperManifest.Inventory.SHA256=(Get-FileHash (Join-Path $tampered 'target-inventory.json') -Algorithm SHA256).Hash.ToLowerInvariant();SaveJson $tamperManifest (Join-Path $tampered 'handoff.json')|Out-Null
    Reject {CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$pairId,$tampered,$catalog.Assistive.Revision,$independentManifestHash)} 'Target self-rehash was accepted as independent handoff trust.'
    $stalePreview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$pairId,$targetHandoffDirectory,$catalog.Assistive.Revision,$independentManifestHash)
    $catalog=CallModule {param($w,$p,$rev,$id) Set-WsmAssistiveSelections -Workspace $w -PairId $p -ExpectedRevision $rev -ItemIds @($id) -Selected $false -Reason 'Temporary stale-preview test'} @($managerRoot,$pairId,$catalog.Assistive.Revision,$included.ItemId)
    $catalog=CallModule {param($w,$p,$rev,$id) Set-WsmAssistiveSelections -Workspace $w -PairId $p -ExpectedRevision $rev -ItemIds @($id) -Selected $true} @($managerRoot,$pairId,$catalog.Assistive.Revision,$included.ItemId)
    Reject {CallModule {param($w,$p,$id) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $p -PreviewId $id} @($managerRoot,$pairId,$stalePreview.PreviewId)} 'Stale Target preview was committed after source selection changed.'
    Check (-not (CallModule {param($w,$p) (Get-WsmCatalog $w $p).Assistive.TargetCurrent} @($managerRoot,$pairId))) 'Rejected stale Target write changed authoritative TargetSnapshot.'
    $current=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$pairId)
    $preview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$pairId,$targetHandoffDirectory,$current.Assistive.Revision,$independentManifestHash)
    $targetCommit=CallModule {param($w,$p,$id) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $p -PreviewId $id} @($managerRoot,$pairId,$preview.PreviewId)
    $afterTarget=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$pairId)
    Check ($targetCommit.Status -ceq 'ImportedVerified' -and $afterTarget.Assistive.TargetCurrent.SHA256 -ceq $targetInventoryHash -and $afterTarget.Assistive.TargetCurrent.HostId -ceq $targetWorkspace.HostId -and $afterTarget.Assistive.TargetCurrent.Fingerprint -ceq $targetWorkspace.Profile.Fingerprint) 'Manager did not commit Target snapshot bound to enrolled Target identity/version.'
    Check ($afterTarget.InventoryHash -ceq $sourceHashBefore -and $afterTarget.Assistive.SourceSnapshot.SHA256 -ceq $sourceSnapshotHashBefore -and $afterTarget.Source.HostId -ceq $sourceFacts.HostId -and $afterTarget.Assistive.TargetCurrent.HostId -cne $afterTarget.Source.HostId) 'Target handoff polluted the Source inventory or Source snapshot.'

    $bulkPreview=CallModule {param($w,$p) Get-WsmWizardBulkPreparationPreview -Workspace $w -PairId $p} @($managerRoot,$pairId)
    Check ($bulkPreview.CandidateItemIds -contains $included.ItemId -and $bulkPreview.AuthoritativeApproval -eq $false -and @($bulkPreview.DeferredFields|Where-Object ItemId -CEQ $included.ItemId).Count -eq 0) 'Preparation backend did not admit the selected LocalSystem service for a real spec write.'
    $savedSpec=CallModule {param($w,$p,$preview) Save-WsmWizardBulkPreparationReview -Workspace $w -PairId $p -PreviewId $preview.PreviewId -PreviewHash $preview.PreviewHash -Owner 'Journey owner' -Evidence 'Reviewed the exact LocalSystem service facts for this fixture.' -BusinessChecks @('Verify service starts on target') -OperationId ([Guid]::NewGuid().ToString('D')) -ReviewedSourceDefaults} @($managerRoot,$pairId,$bulkPreview)
    Check ($savedSpec.Status -ceq 'Succeeded' -and $savedSpec.SavedItemIds -contains $included.ItemId -and -not $savedSpec.AuthoritativeApproval) 'Preparation spec save did not use the real bulk->core consumer or claimed approval.'
    $afterSpec=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$pairId)
    Check (@($afterSpec.Items|Where-Object Decision -CEQ Include|ForEach-Object ItemId) -join '|' -ceq $included.ItemId -and $afterSpec.Items[0].MigrationSpec) 'Manager preparation changed Source-intended Include membership or failed to persist the reviewed spec.'

    $beforeApprovalDefaults=CallModule {param($w,$p) Get-WsmWizardActionDefaults -Workspace $w -PairId $p -Role Manager -Action ApproveMigration} @($managerRoot,$pairId)
    Check (@($beforeApprovalDefaults.missingFields|Where-Object name -CEQ 'PilotAcknowledgement').Count -eq 1 -and $beforeApprovalDefaults.args.TargetIdentityHash -ceq $targetCommit.TargetIdentityHash) 'Approval defaults fabricated pilot acknowledgement or lost independently imported Target identity binding.'
    Reject {CallModule {param($w,$p,$identity,$hash,$path,$rev) Approve-WsmMigrationPlan -Workspace $w -PairId $p -TargetIdentityPath $identity -TargetIdentityHash $hash -Path $path -ExpectedRevision $rev -PilotAcknowledgement ''} @($managerRoot,$pairId,$targetCommit.TargetIdentityPath,$targetCommit.TargetIdentityHash,(Join-Path $root 'must-not-exist.json'),$afterSpec.DecisionRevision)} 'Approval succeeded without explicit ISOLATED-PILOT acknowledgement.'
    Check (-not (CallModule {param($w,$p) (Get-WsmCatalog $w $p).Approval} @($managerRoot,$pairId))) 'Missing pilot acknowledgement changed authoritative approval state.'
    $comparison=CallModule {param($w,$p,$rev) Update-WsmAssistiveComparison -Workspace $w -PairId $p -ExpectedRevision $rev} @($managerRoot,$pairId,$afterSpec.Assistive.Revision)
    Check ($comparison.SourceSnapshotHash -ceq $sourceSnapshotHashBefore -and $comparison.TargetSnapshotHash -ceq $targetInventoryHash -and $comparison.SelectionRevision -eq $afterSpec.Assistive.Selections.Revision) 'Published comparison was not bound to current Source, Target, and selection.'
    $planPath=Join-Path $root 'approved-plan.json'
    $approval=CallModule {param($w,$p,$identity,$hash,$path,$rev) Approve-WsmMigrationPlan -Workspace $w -PairId $p -TargetIdentityPath $identity -TargetIdentityHash $hash -Path $path -ExpectedRevision $rev -PilotAcknowledgement 'ISOLATED-PILOT'} @($managerRoot,$pairId,$targetCommit.TargetIdentityPath,$targetCommit.TargetIdentityHash,$planPath,$afterSpec.DecisionRevision)
    $sealed=CallModule {param($path,$hash) Read-WsmMigrationPlan $path $hash} @($approval.Path,$approval.SHA256)
    Check (@($sealed.Items|ForEach-Object ItemId) -join '|' -ceq $included.ItemId -and @($sealed.Assistive.ApprovedItemIds) -join '|' -ceq $included.ItemId -and -not $approval.ProductionVerified) 'Sealed Include set differs from the exact Source intent set or implied production verification.'

    $tamperedPlan=Join-Path $root 'tampered-plan.json';Copy-Item -LiteralPath $approval.Path -Destination $tamperedPlan;[IO.File]::AppendAllText($tamperedPlan,' ')
    Reject {CallModule {param($w,$path,$hash) Import-WsmWizardApprovedPlan -Workspace $w -Role Source -Path $path -ExpectedHash $hash} @($sourceRoot,$tamperedPlan,$approval.SHA256)} 'Source accepted a modified approved plan by relying on its bytes without the independent hash.'
    CallModule {param($fp) $script:journeyFingerprint=$fp} @($sourceFacts.Fingerprint)
    $sourceImport=CallModule {param($w,$path,$hash,$op) Import-WsmWizardApprovedPlan -Workspace $w -Role Source -Path $path -ExpectedHash $hash -OperationId $op} @($sourceRoot,$approval.Path,$approval.SHA256,[Guid]::NewGuid().ToString('D'))
    $receivedState=CallModule {param($w,$p) Get-WsmWizardState $w $p Source} @($sourceRoot,$pairId)
    Check ($sourceImport.Status -ceq 'ImportedVerified' -and $sourceImport.PairId -ceq $pairId -and $receivedState.Mode -ceq 'Automatic' -and $receivedState.AutoContinue) 'First pair-bound Source preferences were not inherited from the no-pair workspace.'
    $receivedState=CallModule {param($w,$p,$rev) Set-WsmWizardState $w $p Source $rev ([pscustomobject]@{Mode='ItemByItem';AutoContinue=$false})} @($sourceRoot,$pairId,$receivedState.Revision)
    $repeatImport=CallModule {param($w,$path,$hash,$op) Import-WsmWizardApprovedPlan -Workspace $w -Role Source -Path $path -ExpectedHash $hash -OperationId $op} @($sourceRoot,$approval.Path,$approval.SHA256,[Guid]::NewGuid().ToString('D'))
    $existingPairState=CallModule {param($w,$p) Get-WsmWizardState $w $p Source} @($sourceRoot,$pairId)
    Check ($repeatImport.Status -ceq 'ImportedVerified' -and $existingPairState.Mode -ceq 'ItemByItem' -and -not $existingPairState.AutoContinue) 'Reimport reset preferences on an existing Source pair.'
    $receivedPlanRoot=Join-Path (Join-Path (Join-Path $sourceRoot 'workspace-control') 'wizard-materials') 'received-plans'
    Check ((Get-ChildItem -LiteralPath $receivedPlanRoot -File|Where-Object Name -like ('*'+$approval.SHA256+'*')).Count -ge 1 -and -not (Test-Path (Join-Path $sourceRoot 'target-inventory.json')) -and -not (Test-Path (Join-Path $sourceRoot 'target-identity.json'))) 'Source import crossed Target handoff artifacts into the Source workspace.'
    Write-Output ('PASS Test-WizardManagerApprovalJourney checks='+$checks+'; all host identities are fixtures; no real migration or production qualification is claimed.')
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    $absolute=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notlike 'wsm-manager-journey-*'){throw 'Unsafe journey test cleanup path.'}
    if([IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
