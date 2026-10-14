#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$helper=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\WizardHandoff.ps1'))
& $module {param($path) . $path;foreach($function in @(Get-Command -CommandType Function|Where-Object {$_.Name -match '^(Get|Export|Commit)-WsmWizard.*Handoff'})){Set-Item -Path ('Function:\script:'+ $function.Name) -Value $function.ScriptBlock}} $helper
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-handoff-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()) { & $script:module $Block @Arguments }
function SaveJson($Data,[string]$Path){[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 50 -Compress),(New-Object Text.UTF8Encoding($false)));$Path}
function NewSoftwareCatalog($Inventory){
    CallModule {
        param($inventory)
        $coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc='2026-10-14T00:00:00Z'})
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$inventory.Source.HostId;Fingerprint=$inventory.Source.Fingerprint;Name=$inventory.Source.Name;InventoryRevision=[int]$inventory.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=('0'*64)}
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
        Assert-WsmSoftwareCatalog $catalog -SourceInventory $inventory | Out-Null
        $catalog
    } @($Inventory)
}
try {
    # Only the OS identity observation is synthetic. Enrollment, Target registration,
    # handoff file writers, manager snapshot import, and catalog persistence are real.
    $managerFingerprint='c'*64
    CallModule {param($fingerprint) $script:handoffFingerprint=$fingerprint;function script:Get-WsmMachineIdentity { [pscustomobject]@{Fingerprint=$script:handoffFingerprint;Name=$(if($script:handoffFingerprint -ceq ('b'*64)){'fixture-target'}elseif($script:handoffFingerprint -ceq ('a'*64)){'fixture-source'}else{'fixture-manager'});OS='Windows Server';Version='2025';IsServer=$true;Administrator=$true;Is64Bit=$true} }} @($managerFingerprint)
    $managerRoot=Join-Path $root 'manager-work';CallModule {param($w) Initialize-WsmWizardWorkspace $w Manager|Out-Null} @($managerRoot)
    $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='fixture-source'}
    $sourceItem=CallModule {param($h) New-WsmItem $h Services Service 'Source service' 'source-service' @{Path='C:\fixture\svc.exe'}} @($source.HostId)
    $sourceInventory=CallModule {param($s,$items) New-WsmInventory $s 1 $items} @($source,@($sourceItem))
    $sourceInventory|Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $sourceInventory)
    $sourcePath=SaveJson $sourceInventory (Join-Path $root 'source-inventory.json')
    $sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=CallModule {param($w,$p,$h) Import-WsmInventory $w $p $h 'fixture-target'} @($managerRoot,$sourcePath,$sourceHash)
    $catalog=CallModule {param($w,$pair,$rev) Enable-WsmAssistiveMode $w $pair $rev} @($managerRoot,$catalog.PairId,$catalog.DecisionRevision)
    $sourceHashBefore=$catalog.InventoryHash

    $targetFingerprint='b'*64
    CallModule {param($fingerprint) $script:handoffFingerprint=$fingerprint} @($targetFingerprint)
    $targetRoot=Join-Path $root 'target-work';$targetProfile=CallModule {param($w) Initialize-WsmWizardWorkspace $w Target} @($targetRoot)
    $targetWorkspace=CallModule {param($w) Initialize-WsmOutputWorkspace -WorkRoot $w -Role Target} @($targetRoot)
    $identityPath=Join-Path (Join-Path (Join-Path $targetRoot ('targets\'+$targetWorkspace.HostId)) '') 'target-identity.json'
    $registered=CallModule {param($state,$path) Register-WsmTarget $state $path} @($targetWorkspace.StateDirectory,(Join-Path $root 'registered-target.json'))
    Check ($registered.Enrolled -and $registered.Target.HostId -ceq $targetWorkspace.HostId -and (Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash -ieq $registered.SHA256) 'Target bootstrap did not reuse the exact registered Target identity bytes.'

    $target=[pscustomobject]@{HostId=$targetWorkspace.HostId;Fingerprint=$targetFingerprint;Name='fixture-target';OS='Windows Server';Version='2025'}
    $targetInventory=CallModule {param($s) New-WsmInventory $s 1 @()} @($target)
    $targetInventory|Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $targetInventory)
    $targetInventoryPath=SaveJson $targetInventory (Join-Path $root 'target-inventory.json')
    $targetInventoryHash=(Get-FileHash -LiteralPath $targetInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $handoffDirectory=Join-Path $root 'portable-target-handoff'
    $export=CallModule {param($w,$i,$o) Export-WsmWizardTargetHandoff -WorkRoot $w -InventoryPath $i -OutputDirectory $o} @($targetRoot,$targetInventoryPath,$handoffDirectory)
    Check ($export.Status -ceq 'Exported' -and $export.Target.HostId -ceq $targetWorkspace.HostId -and $export.NextMachine -ceq 'fixture-target' -and $export.ProducedUtc -and $export.ProducedLocal -and $export.TimeZone) 'Target export omitted readable identity, time-zone, or next-action information.'

    $preview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$catalog.PairId,$handoffDirectory,$catalog.Assistive.Revision,$export.ObservedManifestHash)
    Check ($preview.Status -ceq 'ReadyForExplicitCommit' -and $preview.Source.HostId -ceq $source.HostId -and $preview.Target.HostId -ceq $targetWorkspace.HostId -and $preview.Target.HostId -cne $preview.Source.HostId -and $preview.SourceInventoryHash -ceq $sourceHashBefore -and $preview.SourceSelectionRevision -eq $catalog.Assistive.Selections.Revision -and $preview.ToolFingerprint -match '^[a-f0-9]{64}$') 'Manager preview did not bind the distinct Source and Target identities, source inventory, selection, and tool.'

    # Replacing a payload and rewriting its in-package hash cannot satisfy the
    # separately received manifest hash.
    $tamperRoot=Join-Path $root 'tampered-copy';[void][IO.Directory]::CreateDirectory($tamperRoot)
    Get-ChildItem -LiteralPath $handoffDirectory -File|Copy-Item -Destination $tamperRoot -Force
    $tamperedInventoryPath=Join-Path $tamperRoot 'target-inventory.json'
    [IO.File]::AppendAllText($tamperedInventoryPath,' ')
    $tamperedManifest=Get-Content -Raw -LiteralPath (Join-Path $tamperRoot 'handoff.json')|ConvertFrom-Json
    $tamperedManifest.Inventory.SHA256=(Get-FileHash -LiteralPath $tamperedInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    SaveJson $tamperedManifest (Join-Path $tamperRoot 'handoff.json')|Out-Null
    Reject {CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$catalog.PairId,$tamperRoot,$catalog.Assistive.Revision,$export.ObservedManifestHash)} 'Self-rehashed payload was trusted without its independent manifest hash.'
    $sourceMasquerade=Join-Path $root 'source-as-target';[void][IO.Directory]::CreateDirectory($sourceMasquerade)
    Get-ChildItem -LiteralPath $handoffDirectory -File|Copy-Item -Destination $sourceMasquerade -Force
    $sourceIdentity=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='TargetIdentity';HostId=$source.HostId;Fingerprint=$source.Fingerprint;Name=$source.Name;OS='Windows Server';Version='2025';CreatedUtc=(CallModule {Get-WsmUtc})}
    $sourceIdentityPath=SaveJson $sourceIdentity (Join-Path $sourceMasquerade 'target-identity.json')
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $sourceMasquerade 'target-inventory.json') -Force
    $sourceMasqueradeManifest=Get-Content -Raw -LiteralPath (Join-Path $sourceMasquerade 'handoff.json')|ConvertFrom-Json
    $sourceMasqueradeManifest.Target.HostId=$source.HostId;$sourceMasqueradeManifest.Target.Name=$source.Name;$sourceMasqueradeManifest.Target.Fingerprint=$source.Fingerprint
    $sourceMasqueradeManifest.TargetIdentity.SHA256=(Get-FileHash -LiteralPath $sourceIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceMasqueradeManifest.Inventory.SHA256=(Get-FileHash -LiteralPath (Join-Path $sourceMasquerade 'target-inventory.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    SaveJson $sourceMasqueradeManifest (Join-Path $sourceMasquerade 'handoff.json')|Out-Null
    Reject {CallModule {param($w,$p,$dir,$rev,$host,$fingerprint) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ConfirmIndependentMaterial -ConfirmedTargetHostId $host -ConfirmedTargetFingerprint $fingerprint -ConfirmationPhrase 'I independently checked the Target identity and copied handoff against the Target copy'} @($managerRoot,$catalog.PairId,$sourceMasquerade,$catalog.Assistive.Revision,$source.HostId,$source.Fingerprint)} 'Untrusted operator-confirmation parameter route remained available.'

    # Manager selection changes invalidate the exact reviewed source binding.
    $selectionPreview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$catalog.PairId,$handoffDirectory,$catalog.Assistive.Revision,$export.ObservedManifestHash)
    $catalog=CallModule {param($w,$p,$rev,$item) Set-WsmAssistiveSelections -Workspace $w -PairId $p -ExpectedRevision $rev -ItemIds @($item) -Selected $false -Reason 'Test selection binding change'} @($managerRoot,$catalog.PairId,$catalog.Assistive.Revision,$sourceItem.ItemId)
    Reject {CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$selectionPreview.PreviewId,$catalog.PairId)} 'Changed source selection was accepted after Target handoff preview.'
    $catalog=CallModule {param($w,$p,$rev,$item) Set-WsmAssistiveSelections -Workspace $w -PairId $p -ExpectedRevision $rev -ItemIds @($item) -Selected $true -Reason ''} @($managerRoot,$catalog.PairId,$catalog.Assistive.Revision,$sourceItem.ItemId)

    # A preview is a review point. Any change to the handed-off originals before
    # commit is rejected without mutating the authoritative Manager catalog.
    $racedPreview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$catalog.PairId,$handoffDirectory,$catalog.Assistive.Revision,$export.ObservedManifestHash)
    [IO.File]::AppendAllText((Join-Path $handoffDirectory 'target-inventory.json'),' ')
    $beforeRace=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$catalog.PairId)
    Reject {CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$racedPreview.PreviewId,$catalog.PairId)} 'Changed handoff bytes were accepted after preview.'
    $afterRace=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$catalog.PairId)
    Check ($afterRace.Assistive.Revision -eq $beforeRace.Assistive.Revision -and -not $afterRace.Assistive.TargetCurrent) 'Failed preview-to-commit race changed the authoritative Target snapshot.'

    # Restore the exact transferred bytes from the immutable preview snapshot into
    # a fresh handoff copy, then exercise the real TargetSnapshot writer.
    $freshDirectory=Join-Path $root 'fresh-handoff';[void][IO.Directory]::CreateDirectory($freshDirectory)
    $previewSnapshotRoot=Join-Path (Join-Path (Join-Path (Join-Path $managerRoot 'workspace-control\wizard\handoff') 'previews') $racedPreview.PreviewId) ''
    foreach($name in @('handoff.json','target-identity.json','target-inventory.json')){Copy-Item -LiteralPath (Join-Path $previewSnapshotRoot $name) -Destination (Join-Path $freshDirectory $name) -Force}
    $freshManifestHash=(Get-FileHash -LiteralPath (Join-Path $freshDirectory 'handoff.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    $freshPreview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$catalog.PairId,$freshDirectory,$catalog.Assistive.Revision,$freshManifestHash)
    Reject {CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$freshPreview.PreviewId,[Guid]::NewGuid().ToString('D'))} 'A preview for another active pair was accepted.'
    $commitDefaults=CallModule {param($w,$p) Get-WsmWizardActionDefaults -Workspace $w -PairId $p -Role Manager -Action CommitTargetHandoff} @($managerRoot,$catalog.PairId)
    Check ($commitDefaults.args.PreviewId -ceq $freshPreview.PreviewId -and -not $commitDefaults.blocked) 'The real defaults consumer did not select the sole current untampered Target handoff preview.'
    $materialRoot=Join-Path $managerRoot 'workspace-control\wizard\handoff\materials'
    $receiptPath=CallModule {param($w,$id) $record=Read-WsmJson (Join-Path (Join-Path (Join-Path (Join-Path (Get-WsmWizardHandoffRoot $w) 'previews') $id) '') 'preview.json');Get-WsmWizardHandoffReceiptPath $w $record} @($managerRoot,$freshPreview.PreviewId)
    CallModule {
        param($targetPath)
        $script:handoffOriginalWriter=(Get-Command Write-WsmJson).ScriptBlock
        $script:handoffFailPath=$targetPath
        $script:handoffFailureUsed=$false
        function script:Write-WsmJson([string]$Path,$Data){
            if(-not $script:handoffFailureUsed -and [IO.Path]::GetFullPath($Path) -ieq [IO.Path]::GetFullPath($script:handoffFailPath)){$script:handoffFailureUsed=$true;throw 'Deterministic test failure after TargetSnapshot commit.'}
            & $script:handoffOriginalWriter $Path $Data
        }
    } @($receiptPath)
    Reject {CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$freshPreview.PreviewId,$catalog.PairId)} 'Injected receipt-write failure did not surface after the snapshot update.'
    $afterReceiptFailure=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$catalog.PairId)
    $intentPath=Join-Path (Join-Path (Join-Path $managerRoot 'workspace-control\wizard\handoff') 'commits') ($freshPreview.PreviewId+'.json')
    Check ($afterReceiptFailure.Assistive.TargetCurrent.SHA256 -ceq $targetInventoryHash -and $afterReceiptFailure.DecisionRevision -eq ($catalog.DecisionRevision+1) -and [IO.File]::Exists($intentPath) -and -not [IO.File]::Exists($receiptPath)) 'Post-snapshot failure did not persist the commit intent and authoritative snapshot exactly once.'
    CallModule {Set-Item Function:\script:Write-WsmJson -Value $script:handoffOriginalWriter;Remove-Variable handoffFailPath,handoffFailureUsed,handoffOriginalWriter -Scope Script -ErrorAction SilentlyContinue}
    $revisionAfterSnapshot=$afterReceiptFailure.DecisionRevision
    $imported=CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$freshPreview.PreviewId,$catalog.PairId)
    $afterImport=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$catalog.PairId)
    Check ($imported.Status -ceq 'ImportedVerified' -and $afterImport.Assistive.TargetCurrent.SHA256 -ceq $targetInventoryHash -and $afterImport.InventoryHash -ceq $sourceHashBefore -and $afterImport.DecisionRevision -eq $revisionAfterSnapshot -and [IO.File]::Exists($receiptPath)) 'Commit replay did not recover its receipt without changing the authoritative snapshot again.'
    $duplicateReplay=CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$freshPreview.PreviewId,$catalog.PairId)
    Check ($duplicateReplay.Duplicate -and (CallModule {param($w,$p) (Get-WsmCatalog $w $p).DecisionRevision} @($managerRoot,$catalog.PairId)) -eq $revisionAfterSnapshot) 'Duplicate same-preview commit did not read back the existing receipt idempotently.'
    $duplicateMaterialPreview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$catalog.PairId,$freshDirectory,$afterImport.Assistive.Revision,$freshPreview.ManifestHash)
    $duplicateMaterial=CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$duplicateMaterialPreview.PreviewId,$catalog.PairId)
    Check ($duplicateMaterial.Duplicate -and $duplicateMaterial.ManifestHash -ceq $freshPreview.ManifestHash -and $duplicateMaterial.ReceiptPath -ceq $receiptPath) 'A second preview of the same source review context did not deduplicate to its existing receipt.'

    # A later source-selection context must retain the earlier receipt while
    # accepting the same independently trusted Target bytes. The exact current
    # snapshot is already authoritative, so commit may only write its receipt.
    $originalReceipt=CallModule {param($path) Read-WsmJson $path} @($receiptPath)
    $catalog=CallModule {param($w,$p,$rev,$item) Set-WsmAssistiveSelections -Workspace $w -PairId $p -ExpectedRevision $rev -ItemIds @($item) -Selected $false -Reason 'Post-import source review changed'} @($managerRoot,$catalog.PairId,$afterImport.Assistive.Revision,$sourceItem.ItemId)
    $newContextPreview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$catalog.PairId,$freshDirectory,$catalog.Assistive.Revision,$freshPreview.ManifestHash)
    $newContextReceiptPath=CallModule {param($w,$id) $record=Read-WsmJson (Join-Path (Join-Path (Join-Path (Join-Path (Get-WsmWizardHandoffRoot $w) 'previews') $id) '') 'preview.json');Get-WsmWizardHandoffReceiptPath $w $record} @($managerRoot,$newContextPreview.PreviewId)
    $newContextPreviewRecord=CallModule {param($w,$id) Read-WsmJson (Join-Path (Join-Path (Join-Path (Join-Path (Get-WsmWizardHandoffRoot $w) 'previews') $id) '') 'preview.json')} @($managerRoot,$newContextPreview.PreviewId)
    $beforeNoOpCommit=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$catalog.PairId)
    $targetCurrentBeforeNoOp=$beforeNoOpCommit.Assistive.TargetCurrent|ConvertTo-Json -Depth 30 -Compress
    $noOpRevision=$beforeNoOpCommit.DecisionRevision;$noOpAssistiveRevision=$beforeNoOpCommit.Assistive.Revision
    Check ($newContextPreview.ManifestHash -ceq $freshPreview.ManifestHash -and $newContextReceiptPath -cne $receiptPath -and $newContextPreviewRecord.SourceInventoryHash -ceq $originalReceipt.SourceInventoryHash -and $newContextPreviewRecord.SelectionHash -cne $originalReceipt.SourceSelectionHash -and [IO.File]::Exists($receiptPath) -and -not [IO.File]::Exists($newContextReceiptPath)) 'A changed Source selection did not produce an independently bound receipt context while preserving the original receipt.'
    $noOpIntentPath=Join-Path (Join-Path (Join-Path $managerRoot 'workspace-control\wizard\handoff') 'commits') ($newContextPreview.PreviewId+'.json')
    CallModule {
        param($targetPath)
        $script:handoffOriginalWriter=(Get-Command Write-WsmJson).ScriptBlock
        $script:handoffFailPath=$targetPath
        $script:handoffFailureUsed=$false
        function script:Write-WsmJson([string]$Path,$Data){
            if(-not $script:handoffFailureUsed -and [IO.Path]::GetFullPath($Path) -ieq [IO.Path]::GetFullPath($script:handoffFailPath)){$script:handoffFailureUsed=$true;throw 'Deterministic test failure before no-op receipt persistence.'}
            & $script:handoffOriginalWriter $Path $Data
        }
    } @($newContextReceiptPath)
    Reject {CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$newContextPreview.PreviewId,$catalog.PairId)} 'Injected no-op receipt-write failure did not surface.'
    $afterNoOpFailure=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$catalog.PairId)
    Check ($afterNoOpFailure.DecisionRevision -eq $noOpRevision -and $afterNoOpFailure.Assistive.Revision -eq $noOpAssistiveRevision -and ($afterNoOpFailure.Assistive.TargetCurrent|ConvertTo-Json -Depth 30 -Compress) -ceq $targetCurrentBeforeNoOp -and [IO.File]::Exists($noOpIntentPath) -and -not [IO.File]::Exists($newContextReceiptPath)) 'No-op receipt failure rewrote the authoritative Target observation or lost its durable intent.'
    CallModule {Set-Item Function:\script:Write-WsmJson -Value $script:handoffOriginalWriter;Remove-Variable handoffFailPath,handoffFailureUsed,handoffOriginalWriter -Scope Script -ErrorAction SilentlyContinue}
    $newContextImport=CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$newContextPreview.PreviewId,$catalog.PairId)
    $afterNoOpImport=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($managerRoot,$catalog.PairId)
    $newContextReceipt=CallModule {param($path) Read-WsmJson $path} @($newContextReceiptPath)
    Check ($newContextImport.Status -ceq 'ImportedVerified' -and $afterNoOpImport.DecisionRevision -eq $noOpRevision -and $afterNoOpImport.Assistive.Revision -eq $noOpAssistiveRevision -and ($afterNoOpImport.Assistive.TargetCurrent|ConvertTo-Json -Depth 30 -Compress) -ceq $targetCurrentBeforeNoOp -and [IO.File]::Exists($receiptPath) -and $newContextReceipt.SourceSelectionHash -ceq $newContextPreviewRecord.SelectionHash -and $newContextReceipt.SourceSnapshotHash -ceq $newContextPreviewRecord.SourceSnapshotHash -and $newContextReceipt.ToolFingerprint -ceq $newContextPreviewRecord.ToolFingerprint) 'Same-target no-op commit did not recover a receipt bound to the new source context without touching TargetSnapshot revisions or observation.'
    $newContextReplay=CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$newContextPreview.PreviewId,$catalog.PairId)
    Check ($newContextReplay.Duplicate -and $newContextReplay.ReceiptPath -ceq $newContextReceiptPath -and (CallModule {param($w,$p) (Get-WsmCatalog $w $p).DecisionRevision} @($managerRoot,$catalog.PairId)) -eq $noOpRevision) 'No-op context receipt replay was not idempotent.'
    $duplicateNewContextPreview=CallModule {param($w,$p,$dir,$rev,$hash) Get-WsmWizardTargetHandoffPreview -Workspace $w -PairId $p -HandoffDirectory $dir -ExpectedAssistiveRevision $rev -ExpectedManifestHash $hash} @($managerRoot,$catalog.PairId,$freshDirectory,$afterNoOpImport.Assistive.Revision,$freshPreview.ManifestHash)
    $duplicateNewContext=CallModule {param($w,$id,$pairId) Commit-WsmWizardTargetHandoff -Workspace $w -PairId $pairId -PreviewId $id} @($managerRoot,$duplicateNewContextPreview.PreviewId,$catalog.PairId)
    Check ($duplicateNewContext.Duplicate -and $duplicateNewContext.ReceiptPath -ceq $newContextReceiptPath) 'A second preview of the new source review context did not reuse its context-bound receipt.'

    $approvalDefaults=CallModule {param($w,$p) Get-WsmWizardActionDefaults -Workspace $w -PairId $p -Role Manager -Action ApproveMigration} @($managerRoot,$catalog.PairId)
    Check ($approvalDefaults.args.TargetIdentityPath -ceq $newContextImport.TargetIdentityPath -and $approvalDefaults.args.TargetIdentityHash -ceq $newContextImport.TargetIdentityHash -and $approvalDefaults.args.Path -and @($approvalDefaults.missingFields|Where-Object name -CEQ 'PilotAcknowledgement').Count -eq 1) 'Approval defaults lost the current independent handoff identity or silently supplied pilot consent.'
    Write-Output ('PASS Test-WizardHandoff checks='+$passed)
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}
}
