#requires -Version 5.1
# P9: a FileScope item whose writer threw leaves a Failed state row without OwnedFiles. The writer refuses such a row on the next restore
# ("Prior schema 3 FileScope ownership data is incomplete; preserve and reconcile."), so N1's shared restorable judgement must say so up front (NeedsReconciliation)
# and there must be an exit (Repair-WsmOperation reconciles the row: only exact backup-hash files are adopted, everything else is preserved).
#   Part A: the one shared predicate (truth table), the shared N1 judgement against a real package, non-FileScope items, static single-source guard, UI/CLI entry names.
#   Part B: end to end through the real wizard layer and the REAL file-scope writer (only an exception is injected into the writer's write phase):
#           write failure -> N1/preview/P8 candidates say needs reconciliation -> Repair -> restorable again -> TargetRetryFailedItems retry succeeds -> other items untouched.
#           Counter-examples (different content / reparse / directory occupying) are preserved byte for byte and never gain ownership; a mixed item adopts only the exact files.
#   Part C: the pending-intent shape (the writer died after the intent) is cleared and reconciled by one Repair call.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-p9-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$workRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsmp9w-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$srcDir=Join-Path $PSScriptRoot '..\src'
try {
    & $module {
        param($Root,$WorkRoot,$SrcDir)
        $script:p9Checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:p9Checks++}
        function Reject([scriptblock]$action,[string]$message,[string]$pattern=''){$rejected=$false;$text='';try{& $action|Out-Null}catch{$rejected=$true;$text=[string]$_.Exception.Message};Check $rejected $message;if($pattern){Check ($text -match $pattern) ($message+' (wrong rejection: '+$text+')')}}
        function SaveJson($data,[string]$path){[IO.File]::WriteAllText($path,($data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$path}
        function Sha([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Ids($Value){(@($Value|Sort-Object) -join ',')}

        # ====================================== Part A1: the shared predicate (truth table) ======================================
        function Row([string]$Id,[string]$Status,[object[]]$Owned=$null,[object[]]$Conflicts=$null){
            $r=[ordered]@{ItemId=$Id;Status=$Status};if($null -ne $Owned){$r.OwnedFiles=@($Owned)};if($null -ne $Conflicts){$r.ReconcileConflicts=@($Conflicts)};[pscustomobject]$r}
        function Inc($Rows,[string]$Id='x'){Test-WsmAssistiveFileScopeOwnershipIncomplete ([pscustomobject]@{Items=@($Rows)}) $Id}
        $ownedOne=@([pscustomobject]@{RelativePath='a.bin';SHA256=('a'*64)})
        Check (-not (Inc @())) 'A1: no prior record must be complete (nothing to reconcile).'
        Check (-not (Test-WsmAssistiveFileScopeOwnershipIncomplete $null 'x')) 'A1: a null state must be complete.'
        Check (-not (Test-WsmAssistiveFileScopeOwnershipIncomplete ([pscustomobject]@{Stage='x'}) 'x')) 'A1: a state without Items must be complete.'
        Check (-not (Inc @((Row 'x' 'Succeeded' $ownedOne)))) 'A1: a record with OwnedFiles must be complete.'
        Check (-not (Inc @((Row 'x' 'Partial' @())))) 'A1: a record with an EMPTY OwnedFiles is complete (the writer accepts it).'
        Check (Inc @((Row 'x' 'Failed'))) 'A1: a Failed row without OwnedFiles must be incomplete.'
        Check (Inc @((Row 'x' 'Succeeded'))) 'A1: any row without OwnedFiles must be incomplete, whatever its status.'
        Check (Inc @((Row 'x' 'Partial' $ownedOne),(Row 'x' 'Failed' $ownedOne))) 'A1: two rows for one item must be incomplete.'
        Check (-not (Inc @((Row 'y' 'Failed')))) 'A1: another item''s incomplete row must not affect this item.'
        Check (-not (Inc @((Row 'x' 'Partial' $ownedOne @())))) 'A1: an empty conflict list is complete.'
        Check (Inc @((Row 'x' 'Partial' $ownedOne @([pscustomobject]@{RelativePath='m3.bin';Reason='differs'})))) 'A1: an unresolved reconcile conflict keeps the record incomplete.'

        # ====================================== Part A2: static single-source guard (writer and N1 call the same predicate) ======================================
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SrcDir 'AssistiveRestore.ps1'),[ref]$null,[ref]$null)
        function FnBody([string]$name){$f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($f.Count -eq 1) ('A2: could not find exactly one function '+$name);$f[0]}
        function CallsPredicate($fn){@($fn.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Test-WsmAssistiveFileScopeOwnershipIncomplete'},$true)).Count}
        Check ((CallsPredicate (FnBody 'Get-WsmAssistiveFileScopeRestoreGap')) -ge 1) 'A2: the N1 shared judgement does not call the shared predicate.'
        Check ((CallsPredicate (FnBody 'Invoke-WsmAssistiveFileScopeRestore')) -ge 1) 'A2: the writer does not call the shared predicate.'
        $throws=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Value -match 'preserve and reconcile'},$true))
        Check ($throws.Count -eq 1) 'A2: the incomplete-ownership refusal text must exist exactly once (the writer).'
        $enclosing=$throws[0].Parent;while($enclosing -and -not ($enclosing -is [Management.Automation.Language.IfStatementAst])){$enclosing=$enclosing.Parent}
        Check ($enclosing -and $enclosing.Clauses[0].Item1.Extent.Text -match 'Test-WsmAssistiveFileScopeOwnershipIncomplete') 'A2: the writer refusal is not gated by the shared predicate (a second private copy of the condition).'

        # ====================================== Part A3: UI and CLI entrance names (the reason text points at an operation that exists on both) ======================================
        $reasonText=Get-WsmWizardRestorableReason 'NeedsReconciliation' $null
        foreach($needle in @('需先對帳','修復','Repair','11 修復 checkpoint','Repair-WsmOperation')){Check ($reasonText.Contains($needle)) ('A3: the reason text does not name '+$needle)}
        $actionMap=Get-WsmHtmlActionMap
        Check ($actionMap.Contains('Repair') -and [string]$actionMap['Repair'] -ceq 'Repair-WsmOperation') 'A3: the HTML action map has no Repair -> Repair-WsmOperation.'
        Check ((Get-WsmOperationActions).Contains('Repair') -and (Get-Command ((Get-WsmOperationActions)['Repair']) -CommandType Function).Parameters.ContainsKey('ManifestPath')) 'A3: the CLI request action Repair is not bound to Repair-WsmOperation.'
        Check (-not [string]::IsNullOrWhiteSpace([string](Get-WsmTextActionGroup 'Repair'))) 'A3: the typed text console has no group for the Repair action.'
        $consoleJs=[IO.File]::ReadAllText((Join-Path $SrcDir 'ui\console.js'),[Text.Encoding]::UTF8)
        Check ($consoleJs -match "Repair:'修復'") 'A3: the HTML action label vocabulary does not translate Repair to 修復.'
        Check (-not ($consoleJs -match "actionOverrides\s*=\s*\{[^}]*\bRepair\s*:")) 'A3: an action override renames Repair, so the reason text would not match the HTML label.'
        Check ($consoleJs -match "actions:\['Repair'") 'A3: the HTML workflow groups do not list the Repair action.'
        $wizardCli=[IO.File]::ReadAllText((Join-Path $SrcDir 'MigrationWizard.ps1'),[Text.Encoding]::UTF8)
        Check ($wizardCli.Contains('11 修復 checkpoint') -and $wizardCli -match "'11' \{Repair-WsmOperation") 'A3: the CLI Target menu has no 11 修復 checkpoint -> Repair-WsmOperation.'

        # ====================================== shared fixture: a real sealed package (six FileScope items) and the real wizard layer ======================================
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='Target fixture';OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:wsmP9Target}
        $script:wsmP9Target=$target
        $work=$WorkRoot;$enrollment=Initialize-WsmOutputWorkspace -WorkRoot $work -Role Target;$target|Add-Member NoteProperty HostId ([string]$enrollment.Profile.HostId) -Force
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='Source fixture';OS='Fixture Windows Server';Version='10.0'}
        $defs=@(
            [pscustomobject]@{Key='ok';Files=@('state.bin')},
            [pscustomobject]@{Key='victim';Files=@('state.bin','extra.bin')},
            [pscustomobject]@{Key='mixed';Files=@('m1.bin','m2.bin','m3.bin')},
            [pscustomobject]@{Key='differ';Files=@('d1.bin')},
            [pscustomobject]@{Key='reparse';Files=@('r1.bin')},
            [pscustomobject]@{Key='dirocc';Files=@('o1.bin')},
            [pscustomobject]@{Key='pend';Files=@('p1.bin')}
        )
        $items=@();$scopes=@{};$targets=@{};$ids=@{}
        foreach($def in $defs){
            $it=New-WsmItem $source.HostId Storage DataRoot ('P9 workload '+$def.Key) ('p9-source-'+$def.Key) @{Path=('C:\fixture\p9-'+$def.Key)}
            $it|Add-Member NoteProperty Decision Include -Force;$it|Add-Member NoteProperty Reason 'Source owner reviewed fixture scope' -Force;$it|Add-Member NoteProperty Owner 'Source owner' -Force;$it|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
            $scope=Join-Path $Root ('source-'+$def.Key);[void][IO.Directory]::CreateDirectory($scope)
            foreach($name in $def.Files){[IO.File]::WriteAllBytes((Join-Path $scope $name),[Text.Encoding]::UTF8.GetBytes('P9 payload '+$def.Key+' '+$name+' '+[Guid]::NewGuid().ToString('N')))}
            $targetRoot=Join-Path $Root ('restored-'+$def.Key)
            $spec=[pscustomobject][ordered]@{Adapter='FileScope';Product='Fixture workload';Procedure='Owner independently verifies the restored file';Artifacts=@();BusinessChecks=@('Owner confirms exact file bytes and ACL');Owner='Source owner';Evidence='fixture approval evidence';SourcePath=$scope;TargetPath=$targetRoot;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';TransferChannel='C';ContentSelection='WholeScope';ConfigFiles=@();ConfigOverrides=@()}
            $it|Add-Member NoteProperty MigrationSpec $spec -Force;$items+=@($it);$scopes[$def.Key]=$scope;$targets[$def.Key]=$targetRoot;$ids[$def.Key]=[string]$it.ItemId
        }
        $sourceInventory=New-WsmInventory $source 1 $items
        $sourceInventoryPath=Join-Path $Root 'source-inventory.json';SaveJson $sourceInventory $sourceInventoryPath|Out-Null;$sourceHash=Sha $sourceInventoryPath
        $pair=[Guid]::NewGuid().ToString();$selectionRevision=3
        $plan=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion='0.4.0';Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString();PairId=$pair;ApprovalId=[Guid]::NewGuid().ToString();Source=$source;Target=[pscustomobject]@{HostId=$enrollment.Profile.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;OS=$target.OS;Version=$target.Version};InventoryRevision=1;DecisionRevision=4;InventoryHash=$sourceHash;ImportedUtc=(Get-WsmUtc);Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);ApprovedUtc=(Get-WsmUtc);Items=@($items|ForEach-Object {$_|ConvertTo-Json -Depth 40|ConvertFrom-Json});ScopeMode='Assistive'}
        $authority=[pscustomobject][ordered]@{SourceSnapshotReference=[pscustomobject][ordered]@{Reference='source-inventory.json';SHA256=$sourceHash;InventoryRevision=1;CreatedUtc=(Get-WsmUtc)};InventoryRevision=1;SelectionRevision=$selectionRevision;Dispositions=@($items|ForEach-Object {[pscustomobject][ordered]@{ItemId=[string]$_.ItemId;Selected=$true;Decision='Include';Reason='Explicitly reviewed source selection'}})}
        $plan|Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=$pair;SourceSnapshotHash=$sourceHash;SourcePolicy='SourceCOnly';SourceSelectionsVersion=$selectionRevision;ApprovedItemIds=@($items|ForEach-Object {[string]$_.ItemId});MaterialReferences=@();DiscoveryAuthority=$authority}) -Force
        Assert-WsmAssistiveContract $plan MigrationPlan|Out-Null
        $planPath=Join-Path $Root 'sealed-plan.json';SaveJson $plan $planPath|Out-Null;$planHash=Sha $planPath
        $import=Import-WsmWizardApprovedPlan -Workspace $work -Role Target -Path $planPath -ExpectedHash $planHash
        Check ($import.Status -ceq 'ImportedVerified') 'Core target import did not receive the schema-3 plan.'
        $coverage=@([pscustomobject][ordered]@{Probe='FixtureComplete';Scope='Machine';SID='';View='All';Status='Success';EvidenceKind='FixtureObservation';Count=0;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind=$null;ItemId='';ObservedUtc=(Get-WsmUtc)})
        $targetInventory=New-WsmInventory $target 7 @()
        $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$target.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;InventoryRevision=7;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $targetInventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='isolated native observation fixture';AccountContext='System';CaptureHost='local fixture';PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=''}
        $software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software
        $targetInventory|Add-Member NoteProperty SoftwareCatalog $software -Force
        Assert-WsmSoftwareCatalog $software -SourceInventory $targetInventory|Out-Null
        function script:Get-WsmAssistiveCurrentSoftwareCatalog($Snapshot){$Snapshot.SoftwareCatalog}
        $inventoryDir=Join-Path (Join-Path (Join-Path $work ('hosts\'+$target.Fingerprint)) 'inventory') ''
        [void](New-WsmOutputOwnedDirectory $inventoryDir);$inventoryPath=Join-Path $inventoryDir 'inventory-7.json';SaveJson $targetInventory $inventoryPath|Out-Null;$inventoryHash=Sha $inventoryPath
        $jobs=@([pscustomobject]@{status='Succeeded';action='Inventory';role='Target';workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash})})
        $comparison=[pscustomobject][ordered]@{Revision=9;SourceSnapshotHash=$sourceHash;TargetSnapshotHash=$inventoryHash;SelectionRevision=$selectionRevision;Rows=@();ManualPreparation=@();CreatedUtc=(Get-WsmUtc);VersionDisclaimer='Observed versions are facts, not compatibility proof.'}
        $handoff=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardTargetComparisonMaterial';PairId=$pair;PlanHash=$planHash;SourceSnapshotHash=$sourceHash;TargetSnapshotHash=$inventoryHash;SelectionRevision=$selectionRevision;ComparisonRevision=9;Comparison=$comparison;InformationalOnly=$true;CreatedUtc=(Get-WsmUtc)}
        $handoffPath=Join-Path $Root 'manager-comparison.json';SaveJson $handoff $handoffPath|Out-Null;$handoffHash=Sha $handoffPath
        $receivedComparison=Import-WsmWizardTargetComparison -Workspace $work -PairId $pair -Path $handoffPath -ExpectedHash $handoffHash -Jobs $jobs
        Check ($receivedComparison.Status -ceq 'Succeeded') 'Target comparison import failed.'
        $packageRoot=Join-Path $Root 'sealed-package';[void][IO.Directory]::CreateDirectory($packageRoot);[void][IO.Directory]::CreateDirectory((Join-Path $packageRoot 'payload'))
        [IO.File]::Copy($planPath,(Join-Path $packageRoot 'plan.json'))
        $records=@();$proofs=@();$totalBytes=[long]0;$totalFiles=0;$sourceMeta=@{};$sourceBytes=@{}
        for($i=0;$i -lt $defs.Count;$i++){
            $def=$defs[$i];$proof=Assert-WsmAssistiveSourceScope $items[$i].MigrationSpec SourceCOnly -Native;if($proof.Channel -cne 'C'){throw 'The isolated source fixtures must be on the native C volume.'}
            $records+=@([pscustomobject][ordered]@{ItemId=[string]$items[$i].ItemId;RelativePath='';Directory=$true;Metadata=(Get-WsmFileMetadata $scopes[$def.Key] 'DaclOwner');Data=$null})
            foreach($name in $def.Files){
                $file=Join-Path $scopes[$def.Key] $name;$blob=Write-WsmPayloadFile $file (Join-Path $packageRoot 'payload') 65536 0 $null;$totalBytes+=[long](Get-Item -LiteralPath $file).Length;$totalFiles++
                $meta=Get-WsmFileMetadata $file 'DaclOwner';$sourceMeta[$def.Key+'/'+$name]=$meta;$sourceBytes[$def.Key+'/'+$name]=[IO.File]::ReadAllBytes($file)
                $records+=@([pscustomobject][ordered]@{ItemId=[string]$items[$i].ItemId;RelativePath=$name;Directory=$false;Metadata=$meta;Data=$blob})
            }
            $proofs+=@([pscustomobject][ordered]@{ItemId=$items[$i].ItemId;Channel=$proof.Channel;PhysicalPath=$proof.PhysicalPath;SourceCPhysicalRoot=$proof.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true})
        }
        $indexPath=Join-Path $packageRoot 'artifacts.jsonl';$indexText=(@($records|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) -join "`n")+"`n";[IO.File]::WriteAllText($indexPath,$indexText,(New-Object Text.UTF8Encoding($false)));$indexHash=Sha $indexPath
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString();BatchId=$plan.BatchId;PairId=$pair;ApprovalId=$plan.ApprovalId;PlanHash=$planHash;Source=$plan.Source;Target=$plan.Target;InventoryRevision=1;DecisionRevision=4;Generation=1;BaseManifestHash='';Final=$false;FreezeHash='';ArtifactsHash=$indexHash;Files=$totalFiles;Bytes=$totalBytes;Records=$records.Count;ChunkBytes=65536;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot';SourceCollectionProofs=$proofs}
        $manifestPath=Join-Path $packageRoot 'manifest.json';SaveJson $manifest $manifestPath|Out-Null;$manifestHash=Sha $manifestPath;$validated=Test-WsmMigrationPackage $manifestPath $manifestHash
        Check ($validated.Valid) 'Core package validator rejected the real schema-3 payload fixture.'
        $delivery=Export-WsmDirectoryDelivery -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $Root 'delivery-one')
        $token=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action DirectoryImport -Path $delivery.SummaryPath -ExpectedHash $delivery.SummarySHA256 -OperationId ([Guid]::NewGuid().ToString())
        $targetImport=Import-WsmWizardTargetDirectoryPackage -Workspace $work -PairId $pair -SummaryPath $delivery.SummaryPath -ExpectedSummaryHash $delivery.SummarySHA256 -SourceDirectory $delivery.Directory -OperationId $token.OperationId -CancellationToken $token
        $allJobs=@($jobs)+@([pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$targetImport.ManifestPath;ManifestHash=$targetImport.ManifestHash;PairId=$pair;PlanHash=$planHash;Generation=$targetImport.Generation;AttemptId=$targetImport.AttemptId})})
        $stateDirectory=Join-Path $work 'pairs';$statePath=Join-Path (Join-Path $stateDirectory $pair) 'state.json'
        $pkgT=Test-WsmMigrationPackage $targetImport.ManifestPath $targetImport.ManifestHash
        function PlanItem([string]$key){@($pkgT.Plan.Items|Where-Object {[string]$_.ItemId -ceq $ids[$key]})[0]}
        function Opts{$ctx=Assert-WsmWizardTargetRole $work $pair;$pr=Get-WsmWizardTargetPackage $work $pair $ctx $allJobs;$p=Get-WsmOperationPaths $stateDirectory $pair;$st=$null;if([IO.File]::Exists($p.State)){$st=Get-WsmOperationState $p $pr.Package};$dec=Get-WsmWizardTargetDecisionRecord $work $pair $ctx.Received.SHA256;@(Get-WsmWizardTargetItemOptions $ctx $pr $st $dec)}
        function Opt([string]$key){@(Opts|Where-Object {[string]$_.value -ceq $ids[$key]})[0]}
        function StateNow{Read-WsmJson $statePath}
        function RowOf($state,[string]$key){,@($state.Items|Where-Object {[string]$_.ItemId -ceq $ids[$key]})}
        function Tree([string]$path){if(-not [IO.Directory]::Exists($path)){return 'absent'};(@(Get-ChildItem -LiteralPath $path -Recurse -Force|Sort-Object FullName|ForEach-Object {$rel=$_.FullName.Substring($path.Length);if($_.PSIsContainer){'D '+$rel}else{'F '+$rel+' '+(Sha $_.FullName)}}) -join "`n")}
        function RepairNow{Repair-WsmOperation -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory -Confirm:$false}

        # ====================================== Part A4: the shared N1 judgement against the real package (targets are still absent) ======================================
        $vItem=PlanItem 'victim';$cleanState=[pscustomobject]@{Items=@();PendingOperations=@()}
        $gap0=Get-WsmAssistiveFileScopeRestoreGap $vItem $pkgT $cleanState $false $null $null
        Check ($gap0.Action -ceq 'RestoreNow' -and $gap0.Status -ceq 'Ready') ('A4: no prior record must be restorable: '+$gap0.Action+'/'+$gap0.Status)
        $gapComplete=Get-WsmAssistiveFileScopeRestoreGap $vItem $pkgT ([pscustomobject]@{Items=@((Row $ids.victim 'Partial' @()))}) $false $null $null
        Check ($gapComplete.Action -ceq 'RestoreNow' -and $gapComplete.Status -ceq 'Ready') 'A4: a complete prior record (empty OwnedFiles) must stay restorable.'
        $gapBad=Get-WsmAssistiveFileScopeRestoreGap $vItem $pkgT ([pscustomobject]@{Items=@((Row $ids.victim 'Failed'))}) $false $null $null
        Check ($gapBad.Action -ceq 'NeedsReconciliation' -and $gapBad.Status -ceq 'Blocked' -and $gapBad.Reason -match 'incomplete' -and -not $gapBad.Capacity) ('A4: an incomplete prior record was not judged NeedsReconciliation/Blocked: '+$gapBad.Action+'/'+$gapBad.Status)
        $gapDup=Get-WsmAssistiveFileScopeRestoreGap $vItem $pkgT ([pscustomobject]@{Items=@((Row $ids.victim 'Partial' @()),(Row $ids.victim 'Failed'))}) $false $null $null
        Check ($gapDup.Action -ceq 'NeedsReconciliation') 'A4: two prior rows must be judged NeedsReconciliation like the writer does.'
        # a non-FileScope item with the same row shape is not touched by this judgement (options layer, no package needed)
        $iisItem=[pscustomobject]@{ItemId='p9-iis-item';Name='iis site';Kind='IISSite';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='IISSite';Desired=[pscustomobject]@{Name='S'}}}
        $iisOpts=@(Get-WsmWizardTargetItemOptions ([pscustomobject]@{Plan=[pscustomobject]@{Items=@($iisItem)}}) $null ([pscustomobject]@{Items=@((Row 'p9-iis-item' 'Failed'));PendingOperations=@()}) $null)
        Check ($iisOpts.Count -eq 1 -and $iisOpts[0].restorable -eq $true -and [string]$iisOpts[0].restorableCode -ceq '') 'A4: a non-FileScope item with a Failed row without OwnedFiles must stay restorable (only FileScope owns this shape).'
        # the writer refuses the same shapes the judgement refuses (real writer, real package; it throws before touching any file)
        $pathsT=Get-WsmOperationPaths $stateDirectory $pair
        Check (-not [IO.Directory]::Exists($targets.victim)) 'A4: precondition: the victim target is absent.'

        # ====================================== Part B: end to end with the real writer ======================================
        $script:p9Calls=@{};$script:p9OrigWriter=(Get-Command Invoke-WsmAssistiveFileScopeRestore -CommandType Function).ScriptBlock
        $script:p9OrigBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock
        $script:p9OrigJournal=(Get-Command Add-WsmJournal -CommandType Function).ScriptBlock
        $script:p9Victims=@{};$script:p9JournalVictims=@{};$script:p9Armed=$false;$script:p9JournalArmed=$false;$script:p9Fired=@{}
        function Invoke-WsmAssistiveFileScopeRestore {
            $itemId=[string]$args[0].ItemId;$script:p9Calls[$itemId]=1+[int]$(if($script:p9Calls.ContainsKey($itemId)){$script:p9Calls[$itemId]}else{0})
            $script:p9Armed=$script:p9Victims.ContainsKey($itemId);$script:p9JournalArmed=$script:p9JournalVictims.ContainsKey($itemId)
            try{& $script:p9OrigWriter @args}finally{$script:p9Armed=$false;$script:p9JournalArmed=$false}
        }
        # The only fault injected: an exception in the write phase of the real writer (before the first file of the item is written).
        function script:Assert-WsmCancellationBoundary {
            if($script:p9Armed -and [string]$args[1] -ceq 'AssistiveFileWrite'){$script:p9Fired['boundary']=1+[int]$(if($script:p9Fired.ContainsKey('boundary')){$script:p9Fired['boundary']}else{0});throw 'P9 injected write-phase failure'}
            & $script:p9OrigBoundary @args
        }
        function script:Add-WsmJournal {
            if($script:p9JournalArmed -and [string]$args[2] -ceq 'AssistiveFileIntent'){$script:p9Fired['journal']=1+[int]$(if($script:p9Fired.ContainsKey('journal')){$script:p9Fired['journal']}else{0});throw 'P9 injected failure after the file intent'}
            & $script:p9OrigJournal @args
        }
        $junctionTarget=Join-Path $Root 'junction-destination';$script:p9Junction=''
        try{
            # ---- B1. one restore of six items; five writers die in the write phase, one succeeds ----
            $selected1=@($ids.ok,$ids.victim,$ids.mixed,$ids.differ,$ids.reparse,$ids.dirocc)
            foreach($k in @('victim','mixed','differ','reparse','dirocc')){$script:p9Victims[$ids[$k]]=$true}
            $receipt1=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'First owner' -Reason 'Restore six fixture items' -SelectedItemIds ([string[]]$selected1) -Jobs $allJobs
            $preview1=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            Check (@($preview1.Rows|Where-Object {[string]$_.Status -ceq 'Ready'}).Count -eq 6) 'B1: the fresh preview did not show all six selected items Ready.'
            $restore1=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview1.PreviewHash) -Jobs $allJobs
            $by1=@{};foreach($row in @($restore1.ItemResults)){$by1[[string]$row.ItemId]=[string]$row.Status}
            Check ($script:p9Fired['boundary'] -eq 5) ('B1: the injected write-phase exception did not fire exactly once per victim (fired '+$script:p9Fired['boundary']+').')
            Check ($restore1.Status -ceq 'Partial' -and $by1[$ids.ok] -ceq 'Succeeded' -and (@($selected1|Where-Object {$_ -cne $ids.ok}|Where-Object {$by1[$_] -ceq 'Failed'}).Count -eq 5)) ('B1: expected one Succeeded and five Failed items: '+(($by1.Values|Sort-Object) -join ','))
            $state1=StateNow
            Check (@($state1.PendingOperations).Count -eq 0) 'B1: this shape must leave no pending intent (the write phase died before the first file intent).'
            foreach($k in @('victim','mixed','differ','reparse','dirocc')){$r=RowOf $state1 $k;Check ($r.Count -eq 1 -and [string]$r[0].Status -ceq 'Failed' -and -not $r[0].PSObject.Properties['OwnedFiles']) ('B1: '+$k+' did not end as a Failed row without OwnedFiles (the defect state).')}
            $okRowBefore=(RowOf $state1 'ok')[0]|ConvertTo-Json -Depth 20 -Compress
            $okTreeBefore=Tree $targets.ok
            Check ((Test-WsmAssistiveFileScopeOwnershipIncomplete $state1 $ids.victim) -and -not (Test-WsmAssistiveFileScopeOwnershipIncomplete $state1 $ids.ok)) 'B1: the shared predicate does not tell the failed row from the healthy one.'

            # ---- B2. N1: options, preview and P8 candidates all say "needs reconciliation" with the exit named ----
            foreach($k in @('victim','mixed','differ','reparse','dirocc')){
                $o=Opt $k
                Check ($o.restorable -eq $false -and [string]$o.restorableCode -ceq 'NeedsReconciliation' -and [string]$o.restorableReason -match '需先對帳') ('B2: the N1 option for '+$k+' is not NeedsReconciliation / 需先對帳: '+$o.restorable+'/'+$o.restorableCode)
            }
            $okOpt=Opt 'ok';Check ($okOpt.restorable -eq $true -and $okOpt.restored -eq $true) 'B2: the healthy item lost its restorable/restored state.'
            $preview2=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            foreach($k in @('victim','mixed','differ','reparse','dirocc')){
                $row=@($preview2.Rows|Where-Object {[string]$_.ItemId -ceq $ids[$k]})
                Check ($row.Count -eq 1 -and [string]$row[0].Action -ceq 'NeedsReconciliation' -and [string]$row[0].Status -ceq 'Blocked' -and [string]$row[0].Reason -match 'incomplete') ('B2: the preview row for '+$k+' is not NeedsReconciliation/Blocked: '+$row[0].Action+'/'+$row[0].Status)
            }
            $c1=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($c1.Visible -and -not $c1.Eligible -and $c1.ReasonCode -ceq 'NoRetryableItems' -and @($c1.CandidateItemIds).Count -eq 0) ('B2: the P8 retry offered an item that needs reconciliation: '+(Ids $c1.CandidateItemIds))
            Check ((Ids ($c1.Excluded|ForEach-Object ItemId)) -ceq (Ids @($ids.victim,$ids.mixed,$ids.differ,$ids.reparse,$ids.dirocc))) 'B2: the P8 excluded list is not exactly the five failed items.'
            foreach($e in @($c1.Excluded)){Check ([string]$e.Code -ceq 'NeedsReconciliation' -and [string]$e.Reason -match '需先對帳' -and [string]$e.Reason -match 'Repair-WsmOperation' -and [string]$e.LastStatus -ceq 'Failed') 'B2: an excluded item lacks the NeedsReconciliation code, the reason, or the named exit.'}
            $restoreJob1=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restore1.AttemptOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($restore1)}
            $runtime1=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($restoreJob1)))
            $retryAction1=@($runtime1.actions|Where-Object {[string]$_.id -ceq 'TargetRetryFailedItems'})
            Check ($runtime1.runtime.retry.visible -eq $true -and $runtime1.runtime.retry.eligible -eq $false -and @($runtime1.runtime.retry.excluded).Count -eq 5 -and $retryAction1.Count -eq 1 -and $retryAction1[0].available -eq $false) 'B2: the projection did not show a disabled retry with five excluded items.'
            foreach($e in @($runtime1.runtime.retry.excluded)){foreach($needle in @('需先對帳','修復','Repair','11 修復 checkpoint','Repair-WsmOperation')){Check (([string]$e.reason).Contains($needle)) ('B2: the excluded reason shown on the screen does not name '+$needle)}}
            Reject {Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'o' -Reason 'r' -SelectedItemIds @($ids.victim) -RetryOfReceiptHash ([string]$c1.SourceReceiptHash) -Jobs $allJobs} 'B2: a retry receipt was created while every failed item needs reconciliation.' 'not available'
            # the writer's own refusal is still there (real writer, called directly; it refuses before it writes anything)
            $stateForWriter=Get-WsmOperationState $pathsT $pkgT
            $victimTreeBefore=Tree $targets.victim
            Reject {Invoke-WsmAssistiveFileScopeRestore (PlanItem 'victim') $pkgT $pathsT $stateForWriter @{} $null ''} 'B2: the real writer accepted an incomplete prior ownership row.' 'ownership data is incomplete'
            Check ((Tree $targets.victim) -ceq $victimTreeBefore) 'B2: the writer refusal changed the target.'
            $script:p9Calls[$ids.victim]=[int]$script:p9Calls[$ids.victim]-1

            # ---- B3. stage the "partially written" disk the operator would find, then record every byte we must not touch ----
            $asArtifact={param([string]$key,[string]$name,[string]$dest)[IO.File]::WriteAllBytes($dest,$sourceBytes[$key+'/'+$name]);Set-WsmFileMetadata $dest $sourceMeta[$key+'/'+$name] @{}}
            # mixed: m1 already written with the exact bytes, m2 never written, m3 holds somebody else's content
            [void][IO.Directory]::CreateDirectory($targets.mixed);& $asArtifact 'mixed' 'm1.bin' (Join-Path $targets.mixed 'm1.bin');[IO.File]::WriteAllText((Join-Path $targets.mixed 'm3.bin'),'FOREIGN m3 content that must survive')
            # differ: the only file holds different content
            [void][IO.Directory]::CreateDirectory($targets.differ);[IO.File]::WriteAllText((Join-Path $targets.differ 'd1.bin'),'FOREIGN d1 content that must survive')
            # reparse: the scope root is a junction to a directory that holds the exact bytes
            [void][IO.Directory]::CreateDirectory($junctionTarget);& $asArtifact 'reparse' 'r1.bin' (Join-Path $junctionTarget 'r1.bin')
            if([IO.Directory]::Exists($targets.reparse)){[IO.Directory]::Delete($targets.reparse,$false)}
            $mk=(& cmd.exe /c ('mklink /J "'+$targets.reparse+'" "'+$junctionTarget+'"') 2>&1);$script:p9Junction=$targets.reparse
            Check (([IO.File]::GetAttributes($targets.reparse) -band [IO.FileAttributes]::ReparsePoint) -ne 0) ('B3: could not create the junction fixture: '+($mk -join ' '))
            # dirocc: a directory occupies the file path
            [void][IO.Directory]::CreateDirectory((Join-Path (Join-Path $targets.dirocc 'o1.bin') 'inner'));[IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $targets.dirocc 'o1.bin') 'inner') 'keep.txt'),'FOREIGN content inside the occupying directory')
            $untouched=@{};foreach($k in @('mixed','differ','dirocc')){$untouched[$k]=Tree $targets[$k]};$untouched['junction']=Tree $junctionTarget
            $untouchedMixedM1Time=(Get-Item -LiteralPath (Join-Path $targets.mixed 'm1.bin')).LastWriteTimeUtc.Ticks

            # ---- B4. the exit: Repair-WsmOperation ----
            $stateBytesBeforeRepair=[IO.File]::ReadAllBytes($statePath)
            $repair=RepairNow
            $rec=@{};foreach($o in @($repair.OwnershipReconcile)){$rec[[string]$o.ItemId]=$o}
            Check ($rec.Count -eq 5) ('B4: Repair did not reconcile exactly the five incomplete items (got '+$rec.Count+').')
            Check ($rec[$ids.victim].Status -ceq 'Reconciled' -and @($rec[$ids.victim].Adopted).Count -eq 0 -and @($rec[$ids.victim].Absent).Count -eq 2 -and @($rec[$ids.victim].Conflicts).Count -eq 0) 'B4: the untouched victim must be reconciled with nothing adopted and both files absent.'
            Check ($rec[$ids.mixed].Status -ceq 'ManualRequired' -and (Ids $rec[$ids.mixed].Adopted) -ceq 'm1.bin' -and (Ids $rec[$ids.mixed].Absent) -ceq 'm2.bin' -and (Ids ($rec[$ids.mixed].Conflicts|ForEach-Object RelativePath)) -ceq 'm3.bin') ('B4: the mixed item must adopt only m1, leave m2 absent, and flag m3: '+($rec[$ids.mixed]|ConvertTo-Json -Depth 5 -Compress))
            Check (@($rec[$ids.differ].Conflicts)[0].Reason -match 'content differs' -and @($rec[$ids.reparse].Conflicts)[0].Reason -match 'reparse point' -and @($rec[$ids.dirocc].Conflicts)[0].Reason -match 'directory occupies') 'B4: the counter-examples were not refused for their own reasons (content differs / reparse point / directory occupies).'
            foreach($k in @('differ','reparse','dirocc')){Check ($rec[$ids[$k]].Status -ceq 'ManualRequired' -and @($rec[$ids[$k]].Adopted).Count -eq 0 -and @($rec[$ids[$k]].Conflicts).Count -ge 1) ('B4: '+$k+' must stay manual with nothing adopted: '+($rec[$ids[$k]]|ConvertTo-Json -Depth 5 -Compress))}
            Check (@($repair.Repaired) -contains $ids.victim -and @($repair.Repaired) -notcontains $ids.mixed -and [int]$repair.Remaining -eq 0) 'B4: only the fully reconciled item may be reported repaired.'
            $state2=StateNow
            $vRow=RowOf $state2 'victim'
            Check ($vRow.Count -eq 1 -and $vRow[0].PSObject.Properties['OwnedFiles'] -and @($vRow[0].OwnedFiles).Count -eq 0 -and -not $vRow[0].PSObject.Properties['ReconcileConflicts'] -and [string]$vRow[0].Status -ceq 'Partial') 'B4: the victim row is not a complete record with empty ownership.'
            $mRow=RowOf $state2 'mixed'
            Check ($mRow.Count -eq 1 -and @($mRow[0].OwnedFiles).Count -eq 1 -and [string]$mRow[0].OwnedFiles[0].RelativePath -ceq 'm1.bin' -and [string]$mRow[0].OwnedFiles[0].SHA256 -ceq (Sha (Join-Path $targets.mixed 'm1.bin')) -and [string]$mRow[0].OwnedFiles[0].MetadataHash -match '^[a-f0-9]{64}$' -and @($mRow[0].ReconcileConflicts).Count -eq 1 -and [string]$mRow[0].ReconcileConflicts[0].RelativePath -ceq 'm3.bin') 'B4: the mixed row did not adopt exactly m1 with a conflict marker for m3.'
            foreach($k in @('differ','reparse','dirocc')){$r=RowOf $state2 $k;Check ($r.Count -eq 1 -and @($r[0].OwnedFiles).Count -eq 0 -and @($r[0].ReconcileConflicts).Count -ge 1) ('B4: '+$k+' gained ownership or lost its conflict marker.')}
            foreach($k in @('mixed','differ','dirocc')){Check ((Tree $targets[$k]) -ceq $untouched[$k]) ('B4: Repair changed the target of '+$k+' (it must only read).')}
            Check ((Tree $junctionTarget) -ceq $untouched['junction'] -and (Get-Item -LiteralPath (Join-Path $targets.mixed 'm1.bin')).LastWriteTimeUtc.Ticks -eq $untouchedMixedM1Time) 'B4: Repair changed the junction destination or rewrote m1.'
            Check ((Tree $targets.victim) -ceq $victimTreeBefore) 'B4: Repair changed the victim target (it must only read; the writer left an empty root directory and nothing else).'
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'B4: the journal is inconsistent after Repair.'
            $journalActions=@(Get-Content -LiteralPath $pathsT.Journal -Encoding UTF8|ForEach-Object {$j=$_|ConvertFrom-Json;if($j.Action -ceq 'AssistiveFileRecovered' -and $j.Detail.PSObject.Properties['Reconciled']){$j}})
            Check ($journalActions.Count -eq 5 -and @($journalActions|Where-Object {[string]$_.ItemId -ceq $ids.victim -and @($_.Detail.Record.OwnedFiles).Count -eq 0}).Count -eq 1) 'B4: the reconcile did not journal one replayable AssistiveFileRecovered row per item with its record.'

            # ---- B4b. the journal replays the reconcile (state rolled back to before Repair, then rebuilt from the journal) ----
            $stateAfterRepair=($state2.Items|Sort-Object ItemId|ConvertTo-Json -Depth 30 -Compress)
            [IO.File]::WriteAllBytes($statePath,$stateBytesBeforeRepair)
            Check ((Test-WsmJournal $stateDirectory $pair).RecoveryRequired) 'B4b: the rolled-back state is not behind the journal (fixture error).'
            $sReplay=Get-WsmOperationState $pathsT $pkgT -AllowRecovery
            Invoke-WsmLocked $pathsT.Root {Restore-WsmJournalCheckpoint $pathsT $sReplay}|Out-Null
            $stateReplayed=StateNow
            Check (($stateReplayed.Items|Sort-Object ItemId|ConvertTo-Json -Depth 30 -Compress) -ceq $stateAfterRepair) 'B4b: replaying the journal does not reproduce the reconciled item records.'

            # ---- B5. N1 turns restorable only for the reconciled item; the P8 retry offers exactly it ----
            Check ((Opt 'victim').restorable -eq $true -and [string](Opt 'victim').restorableCode -ceq '') 'B5: the reconciled victim is not restorable again.'
            foreach($k in @('mixed','differ','reparse','dirocc')){Check ((Opt $k).restorable -eq $false -and [string](Opt $k).restorableCode -ceq 'NeedsReconciliation') ('B5: '+$k+' became restorable although its conflict is unresolved.')}
            $c2=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($c2.Visible -and $c2.Eligible -and (Ids $c2.CandidateItemIds) -ceq $ids.victim -and (Ids ($c2.Excluded|ForEach-Object ItemId)) -ceq (Ids @($ids.mixed,$ids.differ,$ids.reparse,$ids.dirocc)) -and (Ids $c2.SucceededItemIds) -ceq $ids.ok) ('B5: the retry candidates are not exactly the reconciled victim: '+(Ids $c2.CandidateItemIds))

            # ---- B6. the P8 retry path (TargetRetryFailedItems -> receipt -> preview -> restore) writes only the victim ----
            $callsBefore=@{};foreach($k in $script:p9Calls.Keys){$callsBefore[$k]=$script:p9Calls[$k]}
            $script:p9Victims=@{}
            $retryReceipt=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Retry operator' -Reason 'Retry the reconciled item' -SelectedItemIds @($ids.victim) -RetryOfReceiptHash ([string]$c2.SourceReceiptHash) -Jobs $allJobs
            Check ($retryReceipt.Status -ceq 'Succeeded' -and (Ids $retryReceipt.SelectedItemIds) -ceq $ids.victim) 'B6: the retry receipt does not select exactly the reconciled item.'
            $preview3=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $victimPreviewRow=@($preview3.Rows|Where-Object {[string]$_.ItemId -ceq $ids.victim})
            Check ($victimPreviewRow.Count -eq 1 -and [string]$victimPreviewRow[0].Status -ceq 'Ready') 'B6: the preview does not show the reconciled item Ready.'
            $restore3=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview3.PreviewHash) -Jobs $allJobs
            Check (@($restore3.ItemResults).Count -eq 1 -and [string]$restore3.ItemResults[0].ItemId -ceq $ids.victim -and [string]$restore3.ItemResults[0].Status -ceq 'Succeeded') ('B6: the retry did not succeed for exactly the reconciled item: '+(@($restore3.ItemResults|ForEach-Object {[string]$_.Status+' '+[string]$_.Error}) -join ';'))
            $state3=StateNow
            $callDelta=@($script:p9Calls.Keys|Where-Object {[int]$script:p9Calls[$_] -ne [int]$callsBefore[$_]+$(if($_ -ceq $ids.victim){1}else{0})})
            Check ($callDelta.Count -eq 0 -and $script:p9Calls.Count -eq $callsBefore.Count) 'B6: the retry called the file writer for an item other than the reconciled one (or not exactly once for it).'
            Check (((RowOf $state3 'ok')[0]|ConvertTo-Json -Depth 20 -Compress) -ceq $okRowBefore -and (Tree $targets.ok) -ceq $okTreeBefore) 'B6: the already succeeded item was rewritten or lost its ownership record.'
            Check ((Sha (Join-Path $targets.victim 'state.bin')) -ceq (Sha (Join-Path $scopes.victim 'state.bin')) -and (Sha (Join-Path $targets.victim 'extra.bin')) -ceq (Sha (Join-Path $scopes.victim 'extra.bin'))) 'B6: the retried item does not hold its source bytes.'
            $vFinal=RowOf $state3 'victim'
            Check ($vFinal.Count -eq 1 -and [string]$vFinal[0].Status -ceq 'Succeeded' -and @($vFinal[0].OwnedFiles).Count -eq 2) 'B6: the retried item is not owned and Succeeded.'
            # counter-examples: bytes, ownership and markers untouched by the retry
            foreach($k in @('mixed','differ','dirocc')){Check ((Tree $targets[$k]) -ceq $untouched[$k]) ('B6: the retry changed the target of '+$k+'.')}
            Check ((Tree $junctionTarget) -ceq $untouched['junction']) 'B6: the retry changed the junction destination.'
            foreach($k in @('differ','reparse','dirocc')){$r=RowOf $state3 $k;Check ($r.Count -eq 1 -and @($r[0].OwnedFiles).Count -eq 0 -and @($r[0].ReconcileConflicts).Count -ge 1) ('B6: '+$k+' gained ownership through the retry.')}
            $mRow3=RowOf $state3 'mixed';Check ($mRow3.Count -eq 1 -and @($mRow3[0].OwnedFiles).Count -eq 1 -and @($mRow3[0].ReconcileConflicts).Count -eq 1) 'B6: the mixed item ownership changed through the retry.'

            # ---- B7. the manual step the reason asks for: the operator moves the foreign m3.bin away, runs Repair again, and the mixed item completes ----
            $c3=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check (-not $c3.Visible) 'B7: the retry entry stays visible after a fully successful retry.'
            [IO.File]::Delete((Join-Path $targets.mixed 'm3.bin'))
            # NTFS file tunneling gives a file re-created under a just-deleted name (within about 15 s) the old creation time, which the metadata readback would reject; a real operator takes longer than that.
            Start-Sleep -Seconds 16
            Check ((Opt 'mixed').restorable -eq $false) 'B7: deleting the foreign file alone must not make the item restorable before Repair reconciled it.'
            $repair2=RepairNow
            $rec2=@{};foreach($o in @($repair2.OwnershipReconcile)){$rec2[[string]$o.ItemId]=$o}
            Check ($rec2[$ids.mixed].Status -ceq 'Reconciled' -and @($rec2[$ids.mixed].Conflicts).Count -eq 0 -and (Ids $rec2[$ids.mixed].Absent) -ceq 'm2.bin,m3.bin' -and @($rec2[$ids.mixed].Adopted).Count -eq 0) ('B7: the second Repair did not resolve the mixed item: '+($rec2[$ids.mixed]|ConvertTo-Json -Depth 5 -Compress))
            Check ($rec2[$ids.differ].Status -ceq 'ManualRequired' -and $rec2[$ids.reparse].Status -ceq 'ManualRequired' -and $rec2[$ids.dirocc].Status -ceq 'ManualRequired' -and -not $rec2.ContainsKey($ids.victim)) 'B7: the second Repair mishandled the other items.'
            $mRow4=(RowOf (StateNow) 'mixed');Check (@($mRow4[0].OwnedFiles).Count -eq 1 -and -not $mRow4[0].PSObject.Properties['ReconcileConflicts']) 'B7: the mixed row still carries a conflict marker or lost m1.'
            Check ((Opt 'mixed').restorable -eq $true) 'B7: the mixed item is not restorable after its conflict was resolved and Repair ran.'
            $receipt4=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Second owner' -Reason 'Restore the reconciled mixed item' -SelectedItemIds @($ids.mixed) -Jobs $allJobs
            $preview4=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $restore4=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview4.PreviewHash) -Jobs $allJobs
            Check (@($restore4.ItemResults).Count -eq 1 -and [string]$restore4.ItemResults[0].Status -ceq 'Succeeded') ('B7: the mixed item restore did not succeed: '+(@($restore4.ItemResults|ForEach-Object {[string]$_.Status+' '+[string]$_.Error+' '+($_|ConvertTo-Json -Depth 6 -Compress)}) -join ';'))
            Check ((Get-Item -LiteralPath (Join-Path $targets.mixed 'm1.bin')).LastWriteTimeUtc.Ticks -eq $untouchedMixedM1Time -and (Sha (Join-Path $targets.mixed 'm1.bin')) -ceq (Sha (Join-Path $scopes.mixed 'm1.bin')) -and (Sha (Join-Path $targets.mixed 'm2.bin')) -ceq (Sha (Join-Path $scopes.mixed 'm2.bin')) -and (Sha (Join-Path $targets.mixed 'm3.bin')) -ceq (Sha (Join-Path $scopes.mixed 'm3.bin'))) 'B7: m1 was rewritten, or m2/m3 do not hold the source bytes.'
            $mRow5=RowOf (StateNow) 'mixed';Check ([string]$mRow5[0].Status -ceq 'Succeeded' -and @($mRow5[0].OwnedFiles).Count -eq 3) 'B7: the mixed item is not fully owned after the retry.'
            foreach($k in @('differ','dirocc')){Check ((Tree $targets[$k]) -ceq $untouched[$k]) ('B7: the later restore changed the target of '+$k+'.')}
            Check ((Tree $junctionTarget) -ceq $untouched['junction'] -and (@((RowOf (StateNow) 'reparse')[0].OwnedFiles).Count -eq 0)) 'B7: the junction case changed.'

            # ====================================== Part C: the pending-intent shape (the writer died after recording its file intent) ======================================
            $script:p9JournalVictims[$ids.pend]=$true
            $receiptC=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'C owner' -Reason 'Restore the pending-shape item' -SelectedItemIds @($ids.pend) -Jobs $allJobs
            $previewC=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $restoreC=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$previewC.PreviewHash) -Jobs $allJobs
            Check ($script:p9Fired['journal'] -eq 1 -and @($restoreC.ItemResults).Count -eq 1 -and [string]$restoreC.ItemResults[0].Status -ceq 'Failed') 'C: the injected failure after the file intent did not fail exactly the pending-shape item.'
            $stateC=StateNow;$pRow=RowOf $stateC 'pend'
            Check (@($stateC.PendingOperations).Count -eq 1 -and [string]$stateC.PendingOperations[0].Phase -ceq 'AssistiveFileReplace' -and $pRow.Count -eq 1 -and -not $pRow[0].PSObject.Properties['OwnedFiles']) 'C: the failure did not leave a pending file intent plus an incomplete Failed row.'
            $cC=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($cC.Visible -and -not $cC.Eligible -and $cC.ReasonCode -ceq 'PendingIntent') 'C: with a pending intent the retry must say repair first.'
            Check ((Opt 'pend').restorable -eq $false -and [string](Opt 'pend').restorableCode -ceq 'NeedsReconciliation') 'C: the pending-shape item is not NeedsReconciliation in N1.'
            $repairC=RepairNow
            $recC=@($repairC.OwnershipReconcile|Where-Object {[string]$_.ItemId -ceq $ids.pend})
            Check (@($repairC.Repaired) -contains $ids.pend -and [int]$repairC.Remaining -eq 0 -and $recC.Count -eq 1 -and $recC[0].Status -ceq 'Reconciled') ('C: one Repair call did not clear the pending intent and reconcile the row: remaining='+$repairC.Remaining)
            $pRow2=RowOf (StateNow) 'pend';Check (@((StateNow).PendingOperations).Count -eq 0 -and $pRow2[0].PSObject.Properties['OwnedFiles'] -and @($pRow2[0].OwnedFiles).Count -eq 0) 'C: the pending-shape item still has a pending intent or an incomplete row.'
            Check ((Opt 'pend').restorable -eq $true) 'C: the pending-shape item is not restorable after Repair.'
            $cC2=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($cC2.Visible -and $cC2.Eligible -and (Ids $cC2.CandidateItemIds) -ceq $ids.pend) 'C: the retry did not offer exactly the repaired pending-shape item.'
            $script:p9JournalVictims=@{}
            $retryC=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'C retry' -Reason 'Retry the pending-shape item' -SelectedItemIds @($ids.pend) -RetryOfReceiptHash ([string]$cC2.SourceReceiptHash) -Jobs $allJobs
            $previewC2=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $restoreC2=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$previewC2.PreviewHash) -Jobs $allJobs
            Check (@($restoreC2.ItemResults).Count -eq 1 -and [string]$restoreC2.ItemResults[0].Status -ceq 'Succeeded' -and (Sha (Join-Path $targets.pend 'p1.bin')) -ceq (Sha (Join-Path $scopes.pend 'p1.bin'))) 'C: the pending-shape retry did not succeed with the source bytes.'
            foreach($k in @('differ','dirocc')){Check ((Tree $targets[$k]) -ceq $untouched[$k]) ('C: the pending-shape flow changed the target of '+$k+'.')}
        }finally{
            Set-Item -Path Function:\script:Invoke-WsmAssistiveFileScopeRestore -Value $script:p9OrigWriter
            Set-Item -Path Function:\script:Assert-WsmCancellationBoundary -Value $script:p9OrigBoundary
            Set-Item -Path Function:\script:Add-WsmJournal -Value $script:p9OrigJournal
            if($script:p9Junction -and [IO.Directory]::Exists($script:p9Junction) -and (([IO.File]::GetAttributes($script:p9Junction) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){[IO.Directory]::Delete($script:p9Junction,$false)}
        }
        Write-Host ('PASS: FileScope incomplete ownership ('+$script:p9Checks+' checks): one shared predicate for the writer and N1, NeedsReconciliation in options/preview/P8 candidates with the Repair entrance named on HTML and CLI, Repair adopts only exact backup-hash files and preserves every other case, the P8 retry then writes only the reconciled item.')
    } $root $workRoot $srcDir
} finally {
    foreach($path in @($root,$workRoot)){if($path -and [IO.Directory]::Exists($path)){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$path+': '+$_.Exception.Message)}}}
}
