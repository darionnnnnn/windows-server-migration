#requires -Version 5.1
# R1 + R2 (recovery path): restore -> rollback preview -> rollback -> restore again, all through the REAL wizard layer and the REAL file-scope writer.
#   R1: Get-WsmRollbackPreview (the function behind CLI menu 10) must not throw under strict mode for per-file FileScope records that carry no Backup field.
#   R2: a rollback must release the per-file / per-directory ownership it just undid, so the next restore of the same item is not turned into BlockedConflict
#       ("previously owned file is absent"). AdoptedExisting rows (P10) are outside the rollback vector: kept, never deleted, and they stay "already there, same bytes" afterwards.
#       The option (N1), the preview, the retry candidates and the writer judge "owned but absent" through ONE function (Test-WsmAssistiveOwnedFileAbsentConflict).
#       The ownership release is journaled (AssistiveRollbackOwnershipReleased); replaying the journal gives the same item rows as the live state.
# This whole script runs under Set-StrictMode -Version Latest. Do not turn strict mode off anywhere in this file.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-r12-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$workRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsmr12w-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$srcDir=Join-Path $PSScriptRoot '..\src'
try {
    & $module {
        param($Root,$WorkRoot,$SrcDir)
        $script:r12Checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:r12Checks++}
        function SaveJson($data,[string]$path){[IO.File]::WriteAllText($path,($data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$path}
        function Sha([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Ids($Value){(@($Value|Sort-Object) -join ',')}
        function HasProp($Object,[string]$Name){$null -ne $Object -and [bool]$Object.PSObject.Properties[$Name]}
        function OwnClass($Row){if(HasProp $Row 'Ownership'){[string]$Row.Ownership}else{'<none>'}}
        $noteText='沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。'

        # ====================================== Part A: static guards (same source, not two private copies) ======================================
        $astCache=@{}
        function FnAst([string]$file,[string]$name){
            if(-not $astCache.ContainsKey($file)){$astCache[$file]=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SrcDir $file),[ref]$null,[ref]$null)}
            $found=@($astCache[$file].FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
            if($found.Count -ne 1){throw ('Could not locate exactly one function '+$name+' in '+$file)}
            $found[0]
        }
        function CallCount($fn,[string]$command){@($fn.Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq $command},$true)).Count}
        # A1 the "owned but absent" verdict: N1 and the writer both call the one predicate; no third copy of its reason text exists
        Check ((CallCount (FnAst 'AssistiveRestore.ps1' 'Get-WsmAssistiveFileScopeRestoreGap') 'Test-WsmAssistiveOwnedFileAbsentConflict') -ge 1) 'A1: the N1 shared judgement does not call the shared owned-but-absent predicate.'
        Check ((CallCount (FnAst 'AssistiveRestore.ps1' 'Invoke-WsmAssistiveFileScopeRestore') 'Test-WsmAssistiveOwnedFileAbsentConflict') -ge 1) 'A1: the writer does not call the shared owned-but-absent predicate (a second private copy of the condition).'
        Check ((CallCount (FnAst 'AssistiveRestore.ps1' 'Get-WsmAssistiveFileScopeRestoreGap') 'Get-WsmAssistiveOwnedFileAbsentReason') -ge 1 -and (CallCount (FnAst 'AssistiveRestore.ps1' 'Invoke-WsmAssistiveFileScopeRestore') 'Get-WsmAssistiveOwnedFileAbsentReason') -ge 1) 'A1: N1 and the writer do not take the owned-but-absent reason from the shared function.'
        $reasonOwners=New-Object 'System.Collections.Generic.List[string]'
        foreach($sourceFile in @(Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1')){
            $fileAst=[Management.Automation.Language.Parser]::ParseFile($sourceFile.FullName,[ref]$null,[ref]$null)
            foreach($fn in @($fileAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){
                if(@($fn.Body.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and ([string]$n.Value).StartsWith('Previously owned file is absent')},$true)).Count){$reasonOwners.Add($sourceFile.Name+':'+$fn.Name)}
            }
        }
        Check ((Ids $reasonOwners) -ceq 'AssistiveRestore.ps1:Get-WsmAssistiveOwnedFileAbsentReason') ('A1: the owned-but-absent reason text lives outside its one function: '+(Ids $reasonOwners))
        # A2 the ownership release: live rollback and journal replay run the same mutation
        Check ((CallCount (FnAst 'Recovery.ps1' 'Complete-WsmAssistiveFileRollback') 'Remove-WsmAssistiveRolledBackOwnership') -eq 1) 'A2: the live rollback does not release ownership through the shared function.'
        Check ((CallCount (FnAst 'JournalRecovery.ps1' 'Restore-WsmJournalCheckpoint') 'Remove-WsmAssistiveRolledBackOwnership') -eq 1) 'A2: journal replay does not release ownership through the shared function.'
        Check ((@((FnAst 'Recovery.ps1' 'Complete-WsmAssistiveFileRollback').Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Add-WsmJournal' -and $n.CommandElements.Count -gt 3 -and $n.CommandElements[3].Extent.Text -match 'AssistiveRollbackOwnershipReleased'},$true)).Count) -eq 1) 'A2: the rollback does not journal the ownership release.'
        # A3 R1: the preview reads the optional record-level Backup field only through a property guard
        $previewFn=FnAst 'Recovery.ps1' 'Get-WsmRollbackPreview'
        $directBackup=@($previewFn.Body.FindAll({param($n)$n -is [Management.Automation.Language.MemberExpressionAst] -and [string]$n.Member.Extent.Text -ceq 'Backup' -and $n.Expression -is [Management.Automation.Language.IndexExpressionAst]},$true))
        Check ($directBackup.Count -eq 0) 'A3: the rollback preview reads $r[0].Backup directly; a FileScope record without that field throws under strict mode.'

        # A4 R1: an item row that carries no CreatedByTool field is "not created by the tool" (not owned), never a strict-mode exception
        $noOwnerSpec=[pscustomobject]@{Adapter='FileScope'}
        Check ((Test-WsmRollbackRecordOwnership ([pscustomobject]@{ItemId='x';Status='Failed'}) $noOwnerSpec) -eq $false) 'A4: a row without CreatedByTool must not be treated as tool-created (or throw under strict mode).'
        Check ((Test-WsmRollbackRecordOwnership ([pscustomobject]@{ItemId='x';Status='Succeeded';CreatedByTool=$true}) $noOwnerSpec) -eq $true -and (Test-WsmRollbackRecordOwnership ([pscustomobject]@{ItemId='x';Status='Succeeded';CreatedByTool=$false}) $noOwnerSpec) -eq $false) 'A4: the CreatedByTool flag must still decide ownership when it is present.'

        # ====================================== shared fixture: one real sealed package ======================================
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='Target fixture';OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:wsmR12Target}
        $script:wsmR12Target=$target
        $work=$WorkRoot;$enrollment=Initialize-WsmOutputWorkspace -WorkRoot $work -Role Target;$target|Add-Member NoteProperty HostId ([string]$enrollment.Profile.HostId) -Force
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='Source fixture';OS='Fixture Windows Server';Version='10.0'}
        # plain: directory scope with a created sub directory; single: single-file scope; mixed: directory scope that ends up holding an adopted file and a tool-written file
        $defs=@(
            [pscustomobject]@{Key='plain';Kind='dir';Dirs=@('sub');Files=@('p1.bin','sub\p2.bin')},
            [pscustomobject]@{Key='single';Kind='file';Dirs=@();Files=@('sf.bin')},
            [pscustomobject]@{Key='mixed';Kind='dir';Dirs=@();Files=@('m1.bin','m2.bin')}
        )
        $items=@();$scopes=@{};$targets=@{};$ids=@{};$targetRoots=@{}
        foreach($def in $defs){
            $it=New-WsmItem $source.HostId Storage DataRoot ('R12 workload '+$def.Key) ('r12-source-'+$def.Key) @{Path=('C:\fixture\r12-'+$def.Key)}
            $it|Add-Member NoteProperty Decision Include -Force;$it|Add-Member NoteProperty Reason 'Source owner reviewed fixture scope' -Force;$it|Add-Member NoteProperty Owner 'Source owner' -Force;$it|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
            $scopeDir=Join-Path $Root ('source-'+$def.Key);[void][IO.Directory]::CreateDirectory($scopeDir)
            foreach($name in $def.Files){$path=Join-Path $scopeDir $name;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllBytes($path,[Text.Encoding]::UTF8.GetBytes('R12 payload '+$def.Key+' '+$name+' '+[Guid]::NewGuid().ToString('N')))}
            $restoredDir=Join-Path $Root ('restored-'+$def.Key)
            if($def.Kind -ceq 'file'){$sourcePath=Join-Path $scopeDir 'sf.bin';$targetPath=Join-Path $restoredDir 'sf.bin'}else{$sourcePath=$scopeDir;$targetPath=$restoredDir}
            $spec=[pscustomobject][ordered]@{Adapter='FileScope';Product='Fixture workload';Procedure='Owner independently verifies the restored file';Artifacts=@();BusinessChecks=@('Owner confirms exact file bytes and ACL');Owner='Source owner';Evidence='fixture approval evidence';SourcePath=$sourcePath;TargetPath=$targetPath;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';TransferChannel='C';ContentSelection='WholeScope';ConfigFiles=@();ConfigOverrides=@()}
            $it|Add-Member NoteProperty MigrationSpec $spec -Force;$items+=@($it);$scopes[$def.Key]=$scopeDir;$targets[$def.Key]=$targetPath;$targetRoots[$def.Key]=$restoredDir;$ids[$def.Key]=[string]$it.ItemId
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
            if($def.Kind -ceq 'dir'){
                $records+=@([pscustomobject][ordered]@{ItemId=[string]$items[$i].ItemId;RelativePath='';Directory=$true;Metadata=(Get-WsmFileMetadata $scopes[$def.Key] 'DaclOwner');Data=$null})
                foreach($subDirectory in @($def.Dirs)){$records+=@([pscustomobject][ordered]@{ItemId=[string]$items[$i].ItemId;RelativePath=[string]$subDirectory;Directory=$true;Metadata=(Get-WsmFileMetadata (Join-Path $scopes[$def.Key] $subDirectory) 'DaclOwner');Data=$null})}
            }
            foreach($name in $def.Files){
                $file=Join-Path $scopes[$def.Key] $name;$blob=Write-WsmPayloadFile $file (Join-Path $packageRoot 'payload') 65536 0 $null;$totalBytes+=[long](Get-Item -LiteralPath $file).Length;$totalFiles++
                $meta=Get-WsmFileMetadata $file 'DaclOwner';$sourceMeta[$def.Key+'/'+$name]=$meta;$sourceBytes[$def.Key+'/'+$name]=[IO.File]::ReadAllBytes($file)
                $relative=$name;if($def.Kind -ceq 'file'){$relative=''}
                $records+=@([pscustomobject][ordered]@{ItemId=[string]$items[$i].ItemId;RelativePath=$relative;Directory=$false;Metadata=$meta;Data=$blob})
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
        $pathsT=Get-WsmOperationPaths $stateDirectory $pair
        function StateNow{Read-WsmJson $statePath}
        function Opts{$ctx=Assert-WsmWizardTargetRole $work $pair;$pr=Get-WsmWizardTargetPackage $work $pair $ctx $allJobs;$p=Get-WsmOperationPaths $stateDirectory $pair;$st=$null;if([IO.File]::Exists($p.State)){$st=Get-WsmOperationState $p $pr.Package};$dec=Get-WsmWizardTargetDecisionRecord $work $pair $ctx.Received.SHA256;@(Get-WsmWizardTargetItemOptions $ctx $pr $st $dec)}
        function Opt([string]$key){@(Opts|Where-Object {[string]$_.value -ceq $ids[$key]})[0]}
        function RowOf($state,[string]$key){,@($state.Items|Where-Object {[string]$_.ItemId -ceq $ids[$key]})}
        function OwnedOf($state,[string]$key){$r=RowOf $state $key;if($r.Count -ne 1 -or -not (HasProp $r[0] 'OwnedFiles')){return ,@()};,@($r[0].OwnedFiles)}
        function DirsOf($state,[string]$key){$r=RowOf $state $key;if($r.Count -ne 1 -or -not (HasProp $r[0] 'OwnedDirectories')){return ,@()};,@($r[0].OwnedDirectories)}
        function RepairNow{Repair-WsmOperation -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory -Confirm:$false}
        function Meta([string]$path){Get-WsmAssistiveMetadataHash (Get-WsmFileMetadata $path 'DaclOwner')}
        function FileFacts([string]$path){[pscustomobject]@{Sha=(Sha $path);Meta=(Meta $path);Sddl=[string](Get-Acl -LiteralPath $path).Sddl;Ticks=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks;Created=(Get-Item -LiteralPath $path).CreationTimeUtc.Ticks}}
        function SameFacts($a,$b){$a.Sha -ceq $b.Sha -and $a.Meta -ceq $b.Meta -and $a.Sddl -ceq $b.Sddl -and $a.Ticks -eq $b.Ticks -and $a.Created -eq $b.Created}
        $asArtifact={param([string]$key,[string]$name,[string]$dest)[IO.File]::WriteAllBytes($dest,$sourceBytes[$key+'/'+$name]);Set-WsmFileMetadata $dest $sourceMeta[$key+'/'+$name] @{}}
        function ItemsJson($state){($state.Items|Sort-Object ItemId|ConvertTo-Json -Depth 40 -Compress)}
        function RowsJson($state){,@($state.Items|Sort-Object ItemId|ForEach-Object {$_|ConvertTo-Json -Depth 40 -Compress})}
        function NewReceipt([string[]]$selected,[string]$owner){[void](Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner $owner -Reason ('R12 '+$owner) -SelectedItemIds ([string[]]$selected) -Jobs $allJobs)}
        function RestoreNow([string[]]$selected,[string]$owner){
            NewReceipt $selected $owner
            $pv=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $res=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$pv.PreviewHash) -Jobs $allJobs
            $by=@{};$full=@{};foreach($row in @($res.ItemResults)){$by[[string]$row.ItemId]=[string]$row.Status;$full[[string]$row.ItemId]=$row}
            [pscustomobject]@{Preview=$pv;Result=$res;By=$by;Full=$full}
        }
        # Replay the whole journal from a stale (earlier) checkpoint and compare every item row with the live state, row by row.
        function ReplayEqualsLive([byte[]]$staleBytes,[string]$label){
            $liveBytes=[IO.File]::ReadAllBytes($statePath);$live=StateNow;$liveRows=RowsJson $live
            [IO.File]::WriteAllBytes($statePath,$staleBytes)
            try{
                Check ((Test-WsmJournal $stateDirectory $pair).RecoveryRequired) ($label+': the stale checkpoint is not behind the journal (fixture error).')
                $sReplay=Get-WsmOperationState $pathsT $pkgT -AllowRecovery
                Invoke-WsmLocked $pathsT.Root {Restore-WsmJournalCheckpoint $pathsT $sReplay}|Out-Null
                $replayed=StateNow;$replayRows=RowsJson $replayed
                Check ($replayRows.Count -eq $liveRows.Count) ($label+': the replayed state holds a different number of item rows.')
                for($n=0;$n -lt $liveRows.Count;$n++){Check ($liveRows[$n] -ceq $replayRows[$n]) ($label+': item row '+$n+' differs between the live state and the journal replay.'+[Environment]::NewLine+'live='+$liveRows[$n]+[Environment]::NewLine+'replay='+$replayRows[$n])}
                Check ([string]$replayed.Stage -ceq [string]$live.Stage) ($label+': the replayed stage differs from the live stage.')
            }finally{[IO.File]::WriteAllBytes($statePath,$liveBytes)}
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) ($label+': the journal is inconsistent after the replay check.')
        }

        # inject a write-phase exception for chosen items only (the real writer runs otherwise); this is how the P9/P10 tests build the "no OwnedFiles" state
        $script:r12OrigWriter=(Get-Command Invoke-WsmAssistiveFileScopeRestore -CommandType Function).ScriptBlock
        $script:r12OrigBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock
        $script:r12Victims=@{};$script:r12Armed=$false;$script:r12Fired=0
        function Invoke-WsmAssistiveFileScopeRestore {
            $itemId=[string]$args[0].ItemId;$script:r12Armed=$script:r12Victims.ContainsKey($itemId)
            try{& $script:r12OrigWriter @args}finally{$script:r12Armed=$false}
        }
        function script:Assert-WsmCancellationBoundary {
            if($script:r12Armed -and [string]$args[1] -ceq 'AssistiveFileWrite'){$script:r12Fired++;throw 'R12 injected write-phase failure'}
            & $script:r12OrigBoundary @args
        }
        try{
            # ====================================== Part B1: restore #1 (plain + single succeed; mixed fails mid-write) ======================================
            [void][IO.Directory]::CreateDirectory($targetRoots.mixed);& $asArtifact 'mixed' 'm1.bin' (Join-Path $targetRoots.mixed 'm1.bin')   # the operator had already put m1's exact bytes there
            $script:r12Victims[$ids.mixed]=$true
            $r1=RestoreNow @($ids.plain,$ids.single,$ids.mixed) 'First owner'
            $script:r12Victims=@{}
            Check ($script:r12Fired -eq 1) ('B1: the injected write-phase exception did not fire exactly once (fired '+$script:r12Fired+').')
            Check ($r1.By[$ids.plain] -ceq 'Succeeded' -and $r1.By[$ids.single] -ceq 'Succeeded' -and $r1.By[$ids.mixed] -ceq 'Failed') ('B1: unexpected restore #1 statuses: '+(($r1.By.GetEnumerator()|ForEach-Object {$_.Key.Substring(0,6)+'='+$_.Value}) -join ','))
            $state1=StateNow;$stateBytes1=[IO.File]::ReadAllBytes($statePath)
            $mixedRow1=RowOf $state1 'mixed';Check ($mixedRow1.Count -eq 1 -and [string]$mixedRow1[0].Status -ceq 'Failed' -and -not (HasProp $mixedRow1[0] 'OwnedFiles')) 'B1: the mixed item did not end as a Failed row without OwnedFiles (the P9 defect state).'
            $plainOwned1=OwnedOf $state1 'plain'
            Check ($plainOwned1.Count -eq 2 -and (Ids @($plainOwned1|ForEach-Object {[string]$_.RelativePath})) -ceq (Ids @('p1.bin','sub\p2.bin'))) ('B1: the plain item does not own exactly its two files: '+(Ids @($plainOwned1|ForEach-Object {[string]$_.RelativePath})))
            Check ((DirsOf $state1 'plain').Count -ge 2) 'B1: the plain item must own the created root and sub directories.'
            Check (-not (HasProp (RowOf $state1 'plain')[0] 'Backup')) 'B1: fixture assumption: a per-file FileScope state row carries no record-level Backup field (this is what made the preview throw).'

            # ====================================== Part B2 (R1): the rollback preview under strict mode, then Repair adopts m1, restore #2 writes m2 ======================================
            $cliPreview=Get-WsmRollbackPreview $targetImport.ManifestPath $targetImport.ManifestHash $stateDirectory
            $cliText=(@($cliPreview|Format-List|Out-String)+@($cliPreview.Rows|Format-Table|Out-String)) -join "`n"
            Check ($cliText.Length -gt 0 -and @($cliPreview.Rows).Count -eq 2) ('B2: CLI menu 10 preview (Get-WsmRollbackPreview, Format-List, Format-Table) did not list the two owned items; rows='+@($cliPreview.Rows).Count)
            Check (@($cliPreview.Rows|Where-Object Blocked).Count -eq 0) 'B2: the preview must not block a plain restored item.'
            foreach($previewRow in @($cliPreview.Rows)){Check ((HasProp $previewRow 'Backup') -and [string]$previewRow.Backup -ceq '') ('B2: a row without a record-level Backup must show an empty Backup, got: '+[string]$previewRow.Backup)}
            # a record that also lacks the OwnedDirectories field must not make the preview throw either (older / partial records)
            $liveText=[IO.File]::ReadAllText($statePath);$stripped=Read-WsmJson $statePath
            foreach($row in @($stripped.Items)){if([string]$row.ItemId -ceq $ids.plain){$row.PSObject.Properties.Remove('OwnedDirectories')}}
            [IO.File]::WriteAllText($statePath,($stripped|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
            try{$strippedPreview=Get-WsmRollbackPreview $targetImport.ManifestPath $targetImport.ManifestHash $stateDirectory;Check (@($strippedPreview.Rows|Where-Object {[string]$_.ItemId -ceq $ids.plain}).Count -eq 1) 'B2: a record without OwnedDirectories is missing from the preview.'}finally{[IO.File]::WriteAllText($statePath,$liveText,(New-Object Text.UTF8Encoding($false)))}
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'B2: the state/journal pair is not consistent after the OwnedDirectories-less preview probe.'

            $facts=@{m1=(FileFacts (Join-Path $targetRoots.mixed 'm1.bin'))}
            $repair=RepairNow
            $rec=@{};foreach($o in @($repair.OwnershipReconcile)){$rec[[string]$o.ItemId]=$o}
            Check ($rec.Count -eq 1 -and $rec[$ids.mixed].Status -ceq 'Reconciled' -and (Ids $rec[$ids.mixed].Adopted) -ceq 'm1.bin' -and (Ids $rec[$ids.mixed].Absent) -ceq 'm2.bin') ('B2: Repair did not adopt exactly m1: '+($rec.Values|ConvertTo-Json -Depth 4 -Compress))
            $r2=RestoreNow @($ids.mixed) 'Second owner'
            Check ($r2.By[$ids.mixed] -ceq 'Succeeded') ('B2: restore #2 did not complete the mixed item: '+$r2.By[$ids.mixed])
            $m1Result=@($r2.Full[$ids.mixed].FileResults|Where-Object {[string]$_.RelativePath -ceq 'm1.bin'})
            Check ($m1Result.Count -eq 1 -and [string]$m1Result[0].Status -ceq 'VerifiedOwned' -and [string]$m1Result[0].Reason -ceq $noteText) 'B2: the adopted m1 was not treated as already restored.'
            $mixedOwned2=OwnedOf (StateNow) 'mixed'
            Check ($mixedOwned2.Count -eq 2 -and (OwnClass (@($mixedOwned2|Where-Object {[string]$_.RelativePath -ceq 'm1.bin'})[0])) -ceq 'AdoptedExisting' -and (OwnClass (@($mixedOwned2|Where-Object {[string]$_.RelativePath -ceq 'm2.bin'})[0])) -ceq '<none>') 'B2: the mixed item must own m1 as AdoptedExisting and m2 as tool-owned.'
            Check ((SameFacts $facts.m1 (FileFacts (Join-Path $targetRoots.mixed 'm1.bin')))) 'B2: restore #2 rewrote the adopted m1.'
            $stateBytes2=[IO.File]::ReadAllBytes($statePath)

            # ====================================== Part B3 (R2): rollback everything, check ownership, bytes, journal ======================================
            $stateBeforeRollback=StateNow
            $beforeRollback=@{p1=(Sha (Join-Path $targetRoots.plain 'p1.bin'));p2=(Sha (Join-Path $targetRoots.plain 'sub\p2.bin'));sf=(Sha $targets.single);m2=(Sha (Join-Path $targetRoots.mixed 'm2.bin'));m1=(FileFacts (Join-Path $targetRoots.mixed 'm1.bin'))}
            $rp=Get-WsmRollbackPreview $targetImport.ManifestPath $targetImport.ManifestHash $stateDirectory
            $rpRows=@{};foreach($row in @($rp.Rows)){$rpRows[[string]$row.ItemId]=$row}
            Check ($rpRows.Count -eq 3 -and @($rp.Rows|Where-Object Blocked).Count -eq 0 -and [int]$rpRows[$ids.mixed].AdoptedExistingFiles -eq 1 -and [string]$rpRows[$ids.mixed].Reason -match '沿用既有檔' -and [int]$rpRows[$ids.plain].AdoptedExistingFiles -eq 0) 'B3: the rollback preview rows are not the three owned items (mixed with one adopted file), unblocked.'
            $rollbackResult=Invoke-WsmRollback -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory -PreviewHash ([string]$rp.PreviewHash) -Acknowledgement ('ROLLBACK '+$pair) -Confirm:$false
            Check ([string]$rollbackResult.Stage -ceq 'RolledBack') ('B3: the rollback did not finish: '+[string]$rollbackResult.Stage)
            Check (-not [IO.File]::Exists((Join-Path $targetRoots.plain 'p1.bin')) -and -not [IO.File]::Exists((Join-Path $targetRoots.plain 'sub\p2.bin')) -and -not [IO.File]::Exists($targets.single) -and -not [IO.File]::Exists((Join-Path $targetRoots.mixed 'm2.bin'))) 'B3: rollback no longer moves the tool-written files away.'
            Check ([IO.File]::Exists((Join-Path $targetRoots.mixed 'm1.bin'))) 'B3: rollback deleted or moved away the adopted m1 (AdoptedExisting must never be removed by a rollback).'
            Check ((SameFacts $beforeRollback.m1 (FileFacts (Join-Path $targetRoots.mixed 'm1.bin')))) 'B3: rollback deleted, rewrote or re-ACLed the adopted m1 (bytes, ACL, metadata or timestamps changed).'
            $retained=@(foreach($dirPath in @($targetRoots.plain,(Join-Path $targetRoots.plain 'sub'),$targetRoots.single,$targetRoots.mixed)){if([IO.Directory]::Exists($dirPath)){Get-ChildItem -LiteralPath $dirPath -Force -File|Where-Object {$_.Name -like '.wsm-assistive-rollback-*'}|ForEach-Object {Sha $_.FullName}}})
            Check (@($retained|Where-Object {$_ -ceq $beforeRollback.p1 -or $_ -ceq $beforeRollback.p2 -or $_ -ceq $beforeRollback.sf -or $_ -ceq $beforeRollback.m2}).Count -eq 4) 'B3: the displaced tool-written files are not retained next to their targets.'
            $state3=StateNow
            foreach($k in @('plain','single','mixed')){$r=RowOf $state3 $k;Check ($r.Count -eq 1 -and [string]$r[0].Status -ceq 'RolledBack' -and $r[0].CreatedByTool -eq $false) ('B3: '+$k+' is not retired by the rollback.')}
            # R2: the rolled-back per-file / per-directory ownership is released; the adopted row is not
            Check ((OwnedOf $state3 'plain').Count -eq 0 -and (OwnedOf $state3 'single').Count -eq 0) 'B3: the rolled-back tool-written files are still recorded as owned (R2).'
            Check ((DirsOf $state3 'plain').Count -eq 0 -and (DirsOf $state3 'single').Count -eq 0 -and (DirsOf $state3 'mixed').Count -eq 0) 'B3: the rolled-back directory ownership is still recorded (R2).'
            $mixedOwned3=OwnedOf $state3 'mixed'
            Check ($mixedOwned3.Count -eq 1 -and [string]$mixedOwned3[0].RelativePath -ceq 'm1.bin' -and (OwnClass $mixedOwned3[0]) -ceq 'AdoptedExisting') 'B3: the mixed item must keep exactly the adopted m1 and release the tool-written m2 (R2 + P10).'
            Check (@($state3.PendingOperations).Count -eq 0) 'B3: the rollback left a pending operation.'
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'B3: the journal is inconsistent after the rollback.'
            $releaseEvents=@(Read-WsmJournalEvents $pathsT|Where-Object {[string]$_.Row.Action -ceq 'AssistiveRollbackOwnershipReleased'})
            Check ($releaseEvents.Count -eq 3) ('B3: the rollback must journal one ownership release per item (got '+$releaseEvents.Count+').')
            # journal replay from two different stale checkpoints reproduces every item row
            ReplayEqualsLive $stateBytes2 'B3 replay (restore #2 -> rollback)'
            ReplayEqualsLive $stateBytes1 'B3 replay (restore #1 -> repair -> restore #2 -> rollback)'

            # ====================================== Part B4 (R2): after the rollback every judge says "restorable", and the writer agrees ======================================
            $ctx=Assert-WsmWizardTargetRole $work $pair
            foreach($k in @('plain','single','mixed')){$o=Opt $k;Check ($o.restorable -eq $true -and [string]$o.restorableCode -ceq '') ('B4: option for '+$k+' is not restorable after the rollback: '+[string]$o.restorableCode)}
            NewReceipt @($ids.plain,$ids.single,$ids.mixed) 'Third owner'
            $pv3=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $pvRows=@{};foreach($row in @($pv3.Rows)){$pvRows[[string]$row.ItemId]=$row}
            foreach($k in @('plain','single','mixed')){Check ([string]$pvRows[$ids[$k]].Status -ceq 'Ready') ('B4: the preview for '+$k+' is not Ready after the rollback: '+[string]$pvRows[$ids[$k]].Action+'/'+[string]$pvRows[$ids[$k]].Status+' '+[string]$pvRows[$ids[$k]].Reason)}
            $retry=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check (-not $retry.Visible -and -not $retry.Eligible -and @($retry.CandidateItemIds).Count -eq 0 -and [string]$retry.ReasonCode -ceq 'RolledBack') ('B4: after the rollback the retry list must be hidden with its own reason (RolledBack), got '+[string]$retry.ReasonCode+' visible='+$retry.Visible)
            $pkgRecord=Get-WsmWizardTargetPackage $work $pair $ctx $allJobs
            $gapState=StateNow
            foreach($k in @('plain','single','mixed')){
                $item=@($pkgT.Plan.Items|Where-Object {[string]$_.ItemId -ceq $ids[$k]})[0]
                $gap=Get-WsmAssistiveFileScopeRestoreGap $item $pkgT $gapState $false $null $null
                Check ([string]$gap.Status -ceq 'Ready') ('B4: the N1 shared judgement for '+$k+' is not Ready after the rollback: '+[string]$gap.Action+' / '+[string]$gap.Reason)
            }

            # ====================================== Part B5 (R2): restore again, bytes back, adopted file untouched ======================================
            $r3=RestoreNow @($ids.plain,$ids.single,$ids.mixed) 'Fourth owner'
            Check ($r3.By[$ids.plain] -ceq 'Succeeded' -and $r3.By[$ids.single] -ceq 'Succeeded' -and $r3.By[$ids.mixed] -ceq 'Succeeded') ('B5: restore after rollback did not succeed for every item: '+(($r3.By.GetEnumerator()|ForEach-Object {$_.Key.Substring(0,6)+'='+$_.Value}) -join ','))
            Check ((Sha (Join-Path $targetRoots.plain 'p1.bin')) -ceq (Sha (Join-Path $scopes.plain 'p1.bin')) -and (Sha (Join-Path $targetRoots.plain 'sub\p2.bin')) -ceq (Sha (Join-Path $scopes.plain 'sub\p2.bin')) -and (Sha $targets.single) -ceq (Sha (Join-Path $scopes.single 'sf.bin')) -and (Sha (Join-Path $targetRoots.mixed 'm2.bin')) -ceq (Sha (Join-Path $scopes.mixed 'm2.bin'))) 'B5: the restored files do not hold the sealed bytes.'
            $p1Bytes=[IO.File]::ReadAllBytes((Join-Path $targetRoots.plain 'p1.bin'));$p1Expected=$sourceBytes['plain/p1.bin']
            Check ($p1Bytes.Length -eq $p1Expected.Length -and [Convert]::ToBase64String($p1Bytes) -ceq [Convert]::ToBase64String($p1Expected)) 'B5: p1 differs byte for byte from the sealed source bytes.'
            $m1After=@($r3.Full[$ids.mixed].FileResults|Where-Object {[string]$_.RelativePath -ceq 'm1.bin'})
            Check ($m1After.Count -eq 1 -and [string]$m1After[0].Status -ceq 'VerifiedOwned' -and [string]$m1After[0].Reason -ceq $noteText) 'B5: after the rollback the adopted m1 must still be treated as an existing same-content file (VerifiedOwned with the note), not BlockedConflict.'
            Check ((SameFacts $beforeRollback.m1 (FileFacts (Join-Path $targetRoots.mixed 'm1.bin')))) 'B5: the re-restore rewrote the adopted m1.'
            $plainFileResults=@($r3.Full[$ids.plain].FileResults|Where-Object {[string]$_.Status -ceq 'BlockedConflict'});Check ($plainFileResults.Count -eq 0) 'B5: the re-restore reported a BlockedConflict file row for the plain item.'
            $state5=StateNow
            Check ((OwnedOf $state5 'plain').Count -eq 2 -and (OwnedOf $state5 'single').Count -eq 1 -and (OwnedOf $state5 'mixed').Count -eq 2) 'B5: the re-restore did not record ownership for the rewritten files.'
            Check ((OwnClass (@((OwnedOf $state5 'mixed')|Where-Object {[string]$_.RelativePath -ceq 'm1.bin'})[0])) -ceq 'AdoptedExisting') 'B5: m1 lost its adopted class on the re-restore.'
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'B5: the journal is inconsistent after the re-restore.'
            ReplayEqualsLive $stateBytes1 'B5 replay (whole flow including the second restore)'

            # ====================================== Part B6: one more rollback after the re-restore works as well (ownership was re-recorded) ======================================
            $rp2=Get-WsmRollbackPreview $targetImport.ManifestPath $targetImport.ManifestHash $stateDirectory
            Check (@($rp2.Rows).Count -eq 3 -and @($rp2.Rows|Where-Object Blocked).Count -eq 0) ('B6: the second rollback preview is not three unblocked rows: '+(@($rp2.Rows|Where-Object Blocked|ForEach-Object {$_.Reason}) -join ';'))

            # ====================================== Part C (judgement agreement): a recorded-owned file that is simply gone ======================================
            # No rollback this time: the file the tool wrote was deleted behind its back. Option, preview, retry list and writer must all say the same thing (BlockedConflict).
            $gone=Join-Path $targetRoots.plain 'p1.bin'
            [IO.File]::Delete($gone)
            $optionGone=Opt 'plain'
            Check ($optionGone.restorable -eq $false -and [string]$optionGone.restorableCode -ceq 'BlockedConflict') ('C1: the option must be blocked for an owned-but-absent file, got restorable='+[string]$optionGone.restorable+' code='+[string]$optionGone.restorableCode)
            $pvGone=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $goneRow=@($pvGone.Rows|Where-Object {[string]$_.ItemId -ceq $ids.plain})[0]
            Check ([string]$goneRow.Status -ceq 'BlockedConflict' -and [string]$goneRow.Reason -ceq (Get-WsmAssistiveOwnedFileAbsentReason)) ('C1: the preview must be BlockedConflict with the shared reason, got '+[string]$goneRow.Status+' / '+[string]$goneRow.Reason)
            # the other two items are still fine in the same preview
            Check ([string](@($pvGone.Rows|Where-Object {[string]$_.ItemId -ceq $ids.single})[0].Status) -ceq 'Ready' -and [string](@($pvGone.Rows|Where-Object {[string]$_.ItemId -ceq $ids.mixed})[0].Status) -ceq 'Ready') 'C1: the unaffected items are no longer Ready.'
            # retry list: the same judgement decides eligibility (feed the pure core a state in which this item failed)
            $stateGone=StateNow;$copyState=ConvertFrom-WsmJson ($stateGone|ConvertTo-Json -Depth 60)
            foreach($itemResult in @($copyState.RestoreAttempt.ItemResults)){if([string]$itemResult.ItemId -ceq $ids.plain){$itemResult.Status='Failed'}}
            $copyState.Stage='Partial'
            $decisionRecord=Get-WsmWizardTargetDecisionRecord $work $pair $ctx.Received.SHA256
            $retryCore=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkgRecord -State $copyState -DecisionRecord $decisionRecord -ItemOptions @(Opts) -PendingRestore $null
            $excludedPlain=@($retryCore.Excluded|Where-Object {[string]$_.ItemId -ceq $ids.plain})
            Check ($retryCore.Visible -and @($retryCore.CandidateItemIds).Count -eq 0 -and $excludedPlain.Count -eq 1 -and [string]$excludedPlain[0].Code -ceq 'BlockedConflict') ('C1: the retry list must exclude the owned-but-absent item with BlockedConflict, got visible='+$retryCore.Visible+' candidates='+@($retryCore.CandidateItemIds).Count+' excluded='+(@($retryCore.Excluded|ForEach-Object {[string]$_.Code}) -join ','))
            # writer: the real writer, called directly against the real state, refuses and writes nothing
            $writerItem=@($pkgT.Plan.Items|Where-Object {[string]$_.ItemId -ceq $ids.plain})[0]
            $writerState=Get-WsmOperationState $pathsT $pkgT
            $writerRecord=Invoke-WsmAssistiveFileScopeRestore $writerItem $pkgT $pathsT $writerState @{} $null ''
            $p1Rows=@($writerRecord.FileResults|Where-Object {[string]$_.RelativePath -ceq 'p1.bin'})
            Check ([string]$writerRecord.Status -ceq 'BlockedConflict' -and $p1Rows.Count -eq 1 -and [string]$p1Rows[0].Status -ceq 'BlockedConflict' -and [string]$p1Rows[0].Reason -ceq (Get-WsmAssistiveOwnedFileAbsentReason)) ('C1: the writer must refuse the owned-but-absent file with the shared reason, got '+[string]$writerRecord.Status+' / '+(@($writerRecord.FileResults|ForEach-Object {[string]$_.RelativePath+'='+[string]$_.Status}) -join ','))
            Check (-not [IO.File]::Exists($gone)) 'C1: the writer silently recreated the owned-but-absent file.'
            # the N1 judgement and the writer give the same verdict for the single-file scope too
            $singleGone=Join-Path $targetRoots.single 'sf.bin';[IO.File]::Delete($singleGone)
            $singleItem=@($pkgT.Plan.Items|Where-Object {[string]$_.ItemId -ceq $ids.single})[0]
            $singleGap=Get-WsmAssistiveFileScopeRestoreGap $singleItem $pkgT (StateNow) $false $null $null
            $singleWriter=Invoke-WsmAssistiveFileScopeRestore $singleItem $pkgT $pathsT (Get-WsmOperationState $pathsT $pkgT) @{} $null ''
            Check ([string]$singleGap.Status -ceq 'BlockedConflict' -and [string]$singleWriter.Status -ceq 'BlockedConflict' -and -not [IO.File]::Exists($singleGone)) ('C2: single-file scope: N1 and the writer disagree about an owned-but-absent file: '+[string]$singleGap.Status+' vs '+[string]$singleWriter.Status)
            # and the predicate itself
            Check ((Test-WsmAssistiveOwnedFileAbsentConflict ([pscustomobject]@{RelativePath='a'}) $false) -and -not (Test-WsmAssistiveOwnedFileAbsentConflict ([pscustomobject]@{RelativePath='a'}) $true) -and -not (Test-WsmAssistiveOwnedFileAbsentConflict $null $false) -and -not (Test-WsmAssistiveOwnedFileAbsentConflict $null $true)) 'C3: the shared predicate truth table is wrong.'
        }finally{
            Set-Item -Path Function:\script:Invoke-WsmAssistiveFileScopeRestore -Value $script:r12OrigWriter
            Set-Item -Path Function:\script:Assert-WsmCancellationBoundary -Value $script:r12OrigBoundary
        }
        Write-Host ('PASS: rollback then restore ('+$script:r12Checks+' checks, strict mode on throughout): CLI menu 10 preview survives records without Backup/OwnedDirectories; rollback releases the rolled-back ownership (journaled, replay row-for-row equal) and keeps the adopted file; restore after rollback succeeds with the sealed bytes; option, preview, retry list and writer agree, including for an owned-but-absent file.')
    } $root $workRoot $srcDir
} finally {
    foreach($path in @($root,$workRoot)){if($path -and [IO.Directory]::Exists($path)){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$path+': '+$_.Exception.Message)}}}
}
