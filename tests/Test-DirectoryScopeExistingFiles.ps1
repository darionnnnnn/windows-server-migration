#requires -Version 5.1
# R3: 目錄範圍「目標已有、但不是工具擁有的檔案」逐檔判定（過去：預覽 Ready、選項可還原，寫入器才 BlockedConflict，重試候選又把它列回來 -> 無限重試）。
# 全程走真實 wizard 層與真實 FileScope 寫入器（只有「Repair 情境」另外注入一次寫入例外，用來製造 P9 的 ownership 不完整狀態）。
#   Part A  靜態守門：預覽（含 Target 選項 N1 與重試候選）、寫入器、Repair 共用「單一」逐檔判定函式，沒有第二份；衝突原因文字只在一個函式；預計寫入量只有一個算法。
#   Part B  Repair 情境：同內容檔 -> 補登為 AdoptedExisting；內容不同 -> 保留原檔並記為衝突（P9 + R3）。
#   Part C  same 情境：已有與封存位元組相同的外部檔 -> 預覽、選項、寫入器三方都是 Ready；還原成功；該檔記為 AdoptedExisting，沒被重寫（位元組、ACL、時間戳不變）；回復後仍在。
#   Part D  diff 情境：已有內容不同的外部檔 -> 預覽列衝突檔數 1、選項 restorable=false／BlockedConflict 並附原因、P8 重試候選排除、連按重試兩次都不會進候選；原檔不變。
#   Part E  預計寫入量扣除衝突檔與 adopted 檔（含容量候選）。
#   Part F  單檔範圍對照組：行為不變（同內容、不同內容的外部檔都 BlockedConflict，原檔不變）。
# 本檔全程在 Set-StrictMode -Version Latest 下執行，不可在任何地方關閉 strict mode。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-r3-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$workRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsmr3w-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$srcDir=Join-Path $PSScriptRoot '..\src'
try {
    & $module {
        param($Root,$WorkRoot,$SrcDir)
        $script:r3Checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:r3Checks++}
        function SaveJson($data,[string]$path){[IO.File]::WriteAllText($path,($data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$path}
        function Sha([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Ids($Value){(@($Value|Sort-Object) -join ',')}
        function HasProp($Object,[string]$Name){$null -ne $Object -and [bool]$Object.PSObject.Properties[$Name]}
        function OwnClass($Row){if(HasProp $Row 'Ownership'){[string]$Row.Ownership}else{'<none>'}}
        $noteText='沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。'
        $conflictText='目標已有不同內容的檔案，需先人工處理'

        # ====================================== Part A: static guards (one judgement, not private copies) ======================================
        $astCache=@{}
        function FnAst([string]$file,[string]$name){
            if(-not $astCache.ContainsKey($file)){$astCache[$file]=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SrcDir $file),[ref]$null,[ref]$null)}
            $found=@($astCache[$file].FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
            if($found.Count -ne 1){throw ('Could not locate exactly one function '+$name+' in '+$file)}
            $found[0]
        }
        function CallCount($fn,[string]$command){@($fn.Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq $command},$true)).Count}
        $shared='Get-WsmAssistiveExistingFileDisposition'
        Check ((CallCount (FnAst 'AssistiveRestore.ps1' 'Get-WsmAssistiveFileScopeRestoreGap') $shared) -ge 1) 'A1: the shared preview/N1 judgement (Get-WsmAssistiveFileScopeRestoreGap) does not call the one per-file judgement.'
        Check ((CallCount (FnAst 'AssistiveRestore.ps1' 'Invoke-WsmAssistiveFileScopeRestore') $shared) -ge 1) 'A1: the writer does not call the one per-file judgement (a second private copy of the condition).'
        Check ((CallCount (FnAst 'Recovery.ps1' 'Complete-WsmAssistiveFileScopeOwnershipRepair') $shared) -ge 1) 'A1: Repair does not call the one per-file judgement.'
        # the sharers must not re-hash a target file to classify it themselves: the writer only hashes for the owned-file branch, Repair and the preview never
        Check ((CallCount (FnAst 'Recovery.ps1' 'Complete-WsmAssistiveFileScopeOwnershipRepair') 'Get-FileHash') -eq 0) 'A1: Repair classifies existing files with its own hash instead of the shared judgement.'
        Check ((CallCount (FnAst 'AssistiveRestore.ps1' 'Get-WsmAssistiveFileScopeRestoreGap') 'Get-FileHash') -le 1) 'A1: the preview judgement hashes target files outside the shared judgement (only the single-file branch may hash).'
        # the conflict reason text lives in exactly one function
        $reasonOwners=New-Object 'System.Collections.Generic.List[string]'
        foreach($sourceFile in @(Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1')){
            $fileAst=[Management.Automation.Language.Parser]::ParseFile($sourceFile.FullName,[ref]$null,[ref]$null)
            foreach($fn in @($fileAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){
                if(@($fn.Body.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and ([string]$n.Value).StartsWith('目標已有不同內容的檔案')},$true)).Count){$reasonOwners.Add($sourceFile.Name+':'+$fn.Name)}
            }
        }
        Check ((Ids $reasonOwners) -ceq 'AssistiveRestore.ps1:Get-WsmAssistiveDifferentContentConflictReason') ('A2: the different-content conflict reason text lives outside its one function: '+(Ids $reasonOwners))
        foreach($consumer in @(@('AssistiveRestore.ps1','Get-WsmAssistiveFileScopeRestoreGap'),@('AssistiveRestore.ps1','Invoke-WsmAssistiveFileScopeRestore'))){Check ((CallCount (FnAst $consumer[0] $consumer[1]) 'Get-WsmAssistiveDifferentContentConflictReason') -ge 1) ('A2: '+$consumer[1]+' does not take the conflict reason from the shared function.')}
        # the planned write amount has one algorithm, used by the preview
        Check ((CallCount (FnAst 'AssistiveRestore.ps1' 'Get-WsmAssistiveRestorePreview') 'Get-WsmAssistivePlannedWriteAmount') -eq 1) 'A3: the preview does not compute the planned write amount through the one function.'
        # the unit level truth of the planned amount: adopted and conflict files are subtracted, never below zero
        $planUnit=Get-WsmAssistivePlannedWriteAmount ([pscustomobject]@{FileCount=[long]3;Bytes=[long]300;AdoptedFileCount=[long]1;AdoptedBytes=[long]100;ConflictFileCount=[long]1;ConflictBytes=[long]50})
        Check ($planUnit.Files -eq 1 -and $planUnit.Bytes -eq 150) ('A3: planned amount must subtract adopted and conflict files, got '+$planUnit.Files+'/'+$planUnit.Bytes)
        $planPlain=Get-WsmAssistivePlannedWriteAmount ([pscustomobject]@{FileCount=[long]2;Bytes=[long]20})
        Check ($planPlain.Files -eq 2 -and $planPlain.Bytes -eq 20) 'A3: a row without the new fields must keep its full amount.'
        $planFloor=Get-WsmAssistivePlannedWriteAmount ([pscustomobject]@{FileCount=[long]1;Bytes=[long]5;AdoptedFileCount=[long]3;AdoptedBytes=[long]50;ConflictFileCount=[long]0;ConflictBytes=[long]0})
        Check ($planFloor.Files -eq 0 -and $planFloor.Bytes -eq 0) 'A3: planned amount must never go below zero.'
        # the display-only fields stay out of the preview hash
        $hashRow=[pscustomobject]@{ItemId='x';Status='Ready';FileCount=[long]1;Bytes=[long]1;AdoptedFileCount=[long]1;AdoptedBytes=[long]1;ConflictFileCount=[long]0;ConflictBytes=[long]0}
        $stripped=Remove-WsmAssistivePreviewDisplayFields $hashRow
        Check (-not (HasProp $stripped 'AdoptedFileCount') -and -not (HasProp $stripped 'ConflictFileCount') -and -not (HasProp $stripped 'AdoptedBytes') -and -not (HasProp $stripped 'ConflictBytes') -and (HasProp $stripped 'Status')) 'A4: the new display fields must be removed before hashing the preview rows.'

        # ====================================== shared fixture: one real sealed package ======================================
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='Target fixture';OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:wsmR3Target}
        $script:wsmR3Target=$target
        $work=$WorkRoot;$enrollment=Initialize-WsmOutputWorkspace -WorkRoot $work -Role Target;$target|Add-Member NoteProperty HostId ([string]$enrollment.Profile.HostId) -Force
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='Source fixture';OS='Fixture Windows Server';Version='10.0'}
        # dir scope: same / diff / rsame / rdiff; single-file scope: single (same bytes) / singlediff (different bytes)
        $defs=@(
            [pscustomobject]@{Key='same';Kind='dir';Files=@('s1.bin','s2.bin')},
            [pscustomobject]@{Key='diff';Kind='dir';Files=@('d1.bin','d2.bin')},
            [pscustomobject]@{Key='rsame';Kind='dir';Files=@('r1.bin','r2.bin')},
            [pscustomobject]@{Key='rdiff';Kind='dir';Files=@('x1.bin','x2.bin')},
            [pscustomobject]@{Key='single';Kind='file';Files=@('sf.bin')},
            [pscustomobject]@{Key='singlediff';Kind='file';Files=@('sd.bin')}
        )
        $items=@();$scopes=@{};$targets=@{};$ids=@{};$targetRoots=@{}
        foreach($def in $defs){
            $it=New-WsmItem $source.HostId Storage DataRoot ('R3 workload '+$def.Key) ('r3-source-'+$def.Key) @{Path=('C:\fixture\r3-'+$def.Key)}
            $it|Add-Member NoteProperty Decision Include -Force;$it|Add-Member NoteProperty Reason 'Source owner reviewed fixture scope' -Force;$it|Add-Member NoteProperty Owner 'Source owner' -Force;$it|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
            $scopeDir=Join-Path $Root ('source-'+$def.Key);[void][IO.Directory]::CreateDirectory($scopeDir)
            $fileIndex=0
            foreach($name in $def.Files){$fileIndex++;$path=Join-Path $scopeDir $name;[IO.File]::WriteAllBytes($path,[Text.Encoding]::UTF8.GetBytes(('R3 payload '+$def.Key+' '+$name+' '+('x'*(17*$fileIndex))+' '+[Guid]::NewGuid().ToString('N'))))}
            $restoredDir=Join-Path $Root ('restored-'+$def.Key)
            if($def.Kind -ceq 'file'){$sourcePath=Join-Path $scopeDir $def.Files[0];$targetPath=Join-Path $restoredDir $def.Files[0]}else{$sourcePath=$scopeDir;$targetPath=$restoredDir}
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
            if($def.Kind -ceq 'dir'){$records+=@([pscustomobject][ordered]@{ItemId=[string]$items[$i].ItemId;RelativePath='';Directory=$true;Metadata=(Get-WsmFileMetadata $scopes[$def.Key] 'DaclOwner');Data=$null})}
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
        function RepairNow{Repair-WsmOperation -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory -Confirm:$false}
        function Meta([string]$path){Get-WsmAssistiveMetadataHash (Get-WsmFileMetadata $path 'DaclOwner')}
        function FileFacts([string]$path){[pscustomobject]@{Sha=(Sha $path);Meta=(Meta $path);Sddl=[string](Get-Acl -LiteralPath $path).Sddl;Ticks=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks;Created=(Get-Item -LiteralPath $path).CreationTimeUtc.Ticks}}
        function SameFacts($a,$b){$a.Sha -ceq $b.Sha -and $a.Meta -ceq $b.Meta -and $a.Sddl -ceq $b.Sddl -and $a.Ticks -eq $b.Ticks -and $a.Created -eq $b.Created}
        # an operator-placed file at the target: the sealed bytes + sealed metadata (same content), or other bytes (different content)
        $placeSame={param([string]$key,[string]$name,[string]$dest)[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));[IO.File]::WriteAllBytes($dest,$sourceBytes[$key+'/'+$name]);Set-WsmFileMetadata $dest $sourceMeta[$key+'/'+$name] @{}}
        $placeDifferent={param([string]$dest,[string]$text)[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));[IO.File]::WriteAllBytes($dest,[Text.Encoding]::UTF8.GetBytes($text))}
        function RowsJson($state){,@($state.Items|Sort-Object ItemId|ForEach-Object {$_|ConvertTo-Json -Depth 40 -Compress})}
        function NewReceipt([string[]]$selected,[string]$owner){[void](Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner $owner -Reason ('R3 '+$owner) -SelectedItemIds ([string[]]$selected) -Jobs $allJobs)}
        function Preview([string[]]$selected,[string]$owner){NewReceipt $selected $owner;$pv=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs;$byRow=@{};foreach($row in @($pv.Rows)){$byRow[[string]$row.ItemId]=$row};[pscustomobject]@{Projection=$pv;ByItem=$byRow}}
        function RestoreNow([string[]]$selected,[string]$owner){
            NewReceipt $selected $owner
            $pv=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $res=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$pv.PreviewHash) -Jobs $allJobs
            $by=@{};$full=@{};foreach($row in @($res.ItemResults)){$by[[string]$row.ItemId]=[string]$row.Status;$full[[string]$row.ItemId]=$row}
            [pscustomobject]@{Preview=$pv;Result=$res;By=$by;Full=$full}
        }
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
            }finally{[IO.File]::WriteAllBytes($statePath,$liveBytes)}
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) ($label+': the journal is inconsistent after the replay check.')
        }
        function Retry{Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs}

        # inject a write-phase exception for chosen items only (the real writer runs otherwise); this is how the P9 "no OwnedFiles" state is made
        $script:r3OrigWriter=(Get-Command Invoke-WsmAssistiveFileScopeRestore -CommandType Function).ScriptBlock
        $script:r3OrigBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock
        $script:r3Victims=@{};$script:r3Armed=$false;$script:r3Fired=0
        function Invoke-WsmAssistiveFileScopeRestore {
            $itemId=[string]$args[0].ItemId;$script:r3Armed=$script:r3Victims.ContainsKey($itemId)
            try{& $script:r3OrigWriter @args}finally{$script:r3Armed=$false}
        }
        function script:Assert-WsmCancellationBoundary {
            if($script:r3Armed -and [string]$args[1] -ceq 'AssistiveFileWrite'){$script:r3Fired++;throw 'R3 injected write-phase failure'}
            & $script:r3OrigBoundary @args
        }
        try{
            # ====================================== Part B1: the P9 defect state for rsame / rdiff (Failed rows without OwnedFiles) ======================================
            $script:r3Victims[$ids.rsame]=$true;$script:r3Victims[$ids.rdiff]=$true
            $rA=RestoreNow @($ids.rsame,$ids.rdiff) 'Failure owner'
            $script:r3Victims=@{}
            Check ($script:r3Fired -eq 2) ('B1: the injected write-phase exception did not fire once per victim (fired '+$script:r3Fired+').')
            Check ($rA.By[$ids.rsame] -ceq 'Failed' -and $rA.By[$ids.rdiff] -ceq 'Failed') ('B1: unexpected restore statuses: '+(($rA.By.GetEnumerator()|ForEach-Object {$_.Key.Substring(0,6)+'='+$_.Value}) -join ','))
            $stateA=StateNow;$stateBytesA=[IO.File]::ReadAllBytes($statePath)
            Check ((RowOf $stateA 'rsame').Count -eq 1 -and -not (HasProp (RowOf $stateA 'rsame')[0] 'OwnedFiles') -and -not (HasProp (RowOf $stateA 'rdiff')[0] 'OwnedFiles')) 'B1: the victims must be Failed rows without OwnedFiles (the P9 defect state).'
            # the operator now places an external file in each: rsame gets r1 with the sealed bytes, rdiff gets x1 with other bytes
            & $placeSame 'rsame' 'r1.bin' (Join-Path $targetRoots.rsame 'r1.bin')
            & $placeDifferent (Join-Path $targetRoots.rdiff 'x1.bin') 'operator bytes that differ from the backup'
            $factsR1=FileFacts (Join-Path $targetRoots.rsame 'r1.bin');$factsX1=FileFacts (Join-Path $targetRoots.rdiff 'x1.bin')
            foreach($k in @('rsame','rdiff')){$o=Opt $k;Check ($o.restorable -eq $false -and [string]$o.restorableCode -ceq 'NeedsReconciliation') ('B1: '+$k+' must need reconciliation before Repair, got '+[string]$o.restorableCode)}

            # ====================================== Part B2: Repair adopts the same-content file, keeps the different one and records the conflict ======================================
            $repair=RepairNow
            $rec=@{};foreach($o in @($repair.OwnershipReconcile)){$rec[[string]$o.ItemId]=$o}
            Check ($rec.Count -eq 2 -and $rec[$ids.rsame].Status -ceq 'Reconciled' -and (Ids $rec[$ids.rsame].Adopted) -ceq 'r1.bin' -and (Ids $rec[$ids.rsame].Absent) -ceq 'r2.bin') ('B2: Repair did not adopt exactly r1: '+($rec.Values|ConvertTo-Json -Depth 4 -Compress))
            Check ($rec[$ids.rdiff].Status -ceq 'ManualRequired' -and @($rec[$ids.rdiff].Adopted).Count -eq 0 -and @($rec[$ids.rdiff].Conflicts).Count -eq 1 -and [string]@($rec[$ids.rdiff].Conflicts)[0].RelativePath -ceq 'x1.bin') ('B2: Repair must report the different-content file x1 as the one conflict and adopt nothing: '+($rec[$ids.rdiff]|ConvertTo-Json -Depth 4 -Compress))
            $stateB=StateNow
            $rsameOwned=OwnedOf $stateB 'rsame'
            Check ($rsameOwned.Count -eq 1 -and [string]$rsameOwned[0].RelativePath -ceq 'r1.bin' -and (OwnClass $rsameOwned[0]) -ceq 'AdoptedExisting' -and [string]$rsameOwned[0].Backup -ceq '') 'B2: Repair must record r1 as AdoptedExisting without any backup.'
            Check ((OwnedOf $stateB 'rdiff').Count -eq 0 -and (HasProp (RowOf $stateB 'rdiff')[0] 'ReconcileConflicts') -and @((RowOf $stateB 'rdiff')[0].ReconcileConflicts).Count -eq 1) 'B2: the different-content file must not be adopted; the row keeps one ReconcileConflict.'
            Check ((SameFacts $factsR1 (FileFacts (Join-Path $targetRoots.rsame 'r1.bin'))) -and (SameFacts $factsX1 (FileFacts (Join-Path $targetRoots.rdiff 'x1.bin')))) 'B2: Repair changed (bytes, ACL, metadata or timestamps) one of the external files.'
            Check (-not [IO.File]::Exists((Join-Path $targetRoots.rsame 'r2.bin')) -and -not [IO.File]::Exists((Join-Path $targetRoots.rdiff 'x2.bin'))) 'B2: Repair wrote a file (it must only reconcile state).'
            $optRsame=Opt 'rsame';$optRdiff=Opt 'rdiff'
            Check ($optRsame.restorable -eq $true -and [string]$optRsame.restorableCode -ceq '' -and [int]$optRsame.adoptedExistingCount -eq 1) 'B2: after Repair the adopted item must be restorable (and show one adopted file).'
            Check ($optRdiff.restorable -eq $false -and [string]$optRdiff.restorableCode -ceq 'NeedsReconciliation') 'B2: the item with an unresolved conflict must stay blocked until the operator handles it.'

            # ====================================== Part C0/D0/F0: place the external files of the same / diff / single scenarios ======================================
            & $placeSame 'same' 's1.bin' (Join-Path $targetRoots.same 's1.bin')
            & $placeDifferent (Join-Path $targetRoots.diff 'd1.bin') 'operator data that is not the backup'
            & $placeSame 'single' 'sf.bin' $targets.single
            & $placeDifferent $targets.singlediff 'operator single file with other bytes'
            $factsS1=FileFacts (Join-Path $targetRoots.same 's1.bin');$factsD1=FileFacts (Join-Path $targetRoots.diff 'd1.bin');$factsSf=FileFacts $targets.single;$factsSd=FileFacts $targets.singlediff
            $s2Bytes=[long]$sourceBytes['same/s2.bin'].Length;$r2Bytes=[long]$sourceBytes['rsame/r2.bin'].Length;$s1Bytes=[long]$sourceBytes['same/s1.bin'].Length;$d1Bytes=[long]$sourceBytes['diff/d1.bin'].Length;$d2Bytes=[long]$sourceBytes['diff/d2.bin'].Length

            # ====================================== Part C1: same -> preview, option and the shared judgement all say Ready ======================================
            $ctx=Assert-WsmWizardTargetRole $work $pair
            $optSame=Opt 'same'
            Check ($optSame.restorable -eq $true -and [string]$optSame.restorableCode -ceq '') ('C1: option for the same-content scenario must be restorable, got '+[string]$optSame.restorableCode+' / '+[string]$optSame.restorableReason)
            $gapState=StateNow
            $itemSame=@($pkgT.Plan.Items|Where-Object {[string]$_.ItemId -ceq $ids.same})[0]
            $gapSame=Get-WsmAssistiveFileScopeRestoreGap $itemSame $pkgT $gapState $false $null $null
            Check ([string]$gapSame.Status -ceq 'Ready' -and [string]$gapSame.Action -ceq 'MergeIntoExistingDirectory' -and [long]$gapSame.AdoptedFileCount -eq 1 -and [long]$gapSame.ConflictFileCount -eq 0) ('C1: the N1 shared judgement must be Ready with one adopted file, got '+[string]$gapSame.Action+'/'+[string]$gapSame.Status+' adopted='+[string]$gapSame.AdoptedFileCount)
            Check ([long]$gapSame.Capacity.Bytes -eq $s2Bytes) ('E1: the capacity candidate must not count the adopted file (expected '+$s2Bytes+', got '+[string]$gapSame.Capacity.Bytes+').')

            # ====================================== Part D1/F1: diff and the single-file scopes -> option and shared judgement ======================================
            $optDiff=Opt 'diff'
            Check ($optDiff.restorable -eq $false -and [string]$optDiff.restorableCode -ceq 'BlockedConflict') ('D1: the different-content option must be restorable=false / BlockedConflict, got restorable='+[string]$optDiff.restorable+' code='+[string]$optDiff.restorableCode)
            Check (([string]$optDiff.restorableReason).Contains($conflictText) -and ([string]$optDiff.restorableReason).Contains('1')) ('D1: the option must carry the reason text with the conflict count, got: '+[string]$optDiff.restorableReason)
            $itemDiff=@($pkgT.Plan.Items|Where-Object {[string]$_.ItemId -ceq $ids.diff})[0]
            $gapDiff=Get-WsmAssistiveFileScopeRestoreGap $itemDiff $pkgT $gapState $false $null $null
            Check ([string]$gapDiff.Status -ceq 'BlockedConflict' -and [string]$gapDiff.Action -ceq 'BlockedConflict' -and [long]$gapDiff.ConflictFileCount -eq 1 -and [long]$gapDiff.AdoptedFileCount -eq 0 -and ([string]$gapDiff.Reason).StartsWith($conflictText,[StringComparison]::Ordinal)) ('D1: the shared judgement must be BlockedConflict with one conflict file, got '+[string]$gapDiff.Action+'/'+[string]$gapDiff.Status+' conflicts='+[string]$gapDiff.ConflictFileCount+' '+[string]$gapDiff.Reason)
            Check ([long]$gapDiff.ConflictBytes -eq $d1Bytes) 'D1: the conflict bytes must be the sealed size of the conflicting file.'
            Check ((Get-WsmAssistiveDifferentContentConflictReason) -ceq $conflictText -and (Get-WsmAssistiveDifferentContentConflictReason 2).StartsWith($conflictText,[StringComparison]::Ordinal)) 'D1: the reason function must return the fixed text (the count is only appended).'
            foreach($k in @('single','singlediff')){$o=Opt $k;Check ($o.restorable -eq $false -and [string]$o.restorableCode -ceq 'BlockedConflict') ('F1: single-file control '+$k+' must stay restorable=false / BlockedConflict, got '+[string]$o.restorableCode)}

            # ====================================== Part C2/D2/E2/F2: one preview over every scenario: Ready only where the writer will agree, planned amount subtracts ======================================
            $selection=@($ids.same,$ids.diff,$ids.rsame,$ids.single,$ids.singlediff)
            $pv=Preview $selection 'Scenario owner'
            $rowSame=$pv.ByItem[$ids.same];$rowDiff=$pv.ByItem[$ids.diff];$rowRsame=$pv.ByItem[$ids.rsame];$rowSingle=$pv.ByItem[$ids.single];$rowSingleDiff=$pv.ByItem[$ids.singlediff]
            Check ([string]$rowSame.Status -ceq 'Ready' -and [string]$rowSame.Action -ceq 'MergeIntoExistingDirectory' -and [long]$rowSame.AdoptedFileCount -eq 1 -and [long]$rowSame.ConflictFileCount -eq 0) ('C2: the same-content preview row must be Ready with one adopted file, got '+[string]$rowSame.Action+'/'+[string]$rowSame.Status)
            Check ([string]$rowRsame.Status -ceq 'Ready' -and [long]$rowRsame.AdoptedFileCount -eq 1) ('C2: the Repair-adopted preview row must be Ready with one adopted file (owned-and-adopted counts as no-write), got '+[string]$rowRsame.Action+'/'+[string]$rowRsame.Status+' adopted='+[string]$rowRsame.AdoptedFileCount)
            Check ([string]$rowDiff.Status -ceq 'BlockedConflict' -and [string]$rowDiff.Action -ceq 'BlockedConflict' -and [long]$rowDiff.ConflictFileCount -eq 1 -and ([string]$rowDiff.Reason).StartsWith($conflictText,[StringComparison]::Ordinal)) ('D2: the different-content preview row must be BlockedConflict listing 1 conflict file with the fixed reason, got '+[string]$rowDiff.Action+'/'+[string]$rowDiff.Status+' conflicts='+[string]$rowDiff.ConflictFileCount+' '+[string]$rowDiff.Reason)
            Check ([string]$rowSingle.Status -ceq 'BlockedConflict' -and [string]$rowSingleDiff.Status -ceq 'BlockedConflict') 'F2: single-file scope: both external files must still be BlockedConflict in the preview.'
            Check (-not (HasProp $rowSingle 'ConflictFileCount') -or [long]$rowSingle.ConflictFileCount -eq 0) 'F2: single-file scope must not be re-judged per file (no directory-scope conflict count).'
            Check ([long]$pv.Projection.PlannedFileCount -eq 2 -and [long]$pv.Projection.PlannedBytes -eq ($s2Bytes+$r2Bytes)) ('E2: the planned write amount must subtract the adopted files and skip the conflicts (expected 2 files / '+($s2Bytes+$r2Bytes)+' bytes, got '+[string]$pv.Projection.PlannedFileCount+' / '+[string]$pv.Projection.PlannedBytes+').')
            Check ([long]$rowSame.FileCount -eq 2 -and [long]$rowSame.Bytes -eq ($s1Bytes+$s2Bytes)) 'E2: the row itself keeps the full sealed amount (only the planned total subtracts).'
            # preview, option and the writer agree: Ready rows == restorable options of the selected items
            $readyRows=@($pv.Projection.Rows|Where-Object {[string]$_.Status -ceq 'Ready'}|ForEach-Object {[string]$_.ItemId})
            Check ((Ids $readyRows) -ceq (Ids @($ids.same,$ids.rsame))) ('C2: the preview Ready items must be exactly same and rsame, got '+(Ids $readyRows))

            # ====================================== Part C3/D3/F3: restore for real ======================================
            $r1=RestoreNow $selection 'Scenario owner'
            Check ($r1.By[$ids.same] -ceq 'Succeeded' -and $r1.By[$ids.rsame] -ceq 'Succeeded') ('C3: same-content items must restore successfully, got '+(($r1.By.GetEnumerator()|ForEach-Object {$_.Key.Substring(0,6)+'='+$_.Value}) -join ','))
            Check ($r1.By[$ids.diff] -ceq 'BlockedConflict' -and $r1.By[$ids.single] -ceq 'BlockedConflict' -and $r1.By[$ids.singlediff] -ceq 'BlockedConflict') 'D3/F3: different-content and single-file external files must end BlockedConflict.'
            $s1Result=@($r1.Full[$ids.same].FileResults|Where-Object {[string]$_.RelativePath -ceq 's1.bin'});$s2Result=@($r1.Full[$ids.same].FileResults|Where-Object {[string]$_.RelativePath -ceq 's2.bin'})
            Check ($s1Result.Count -eq 1 -and [string]$s1Result[0].Status -ceq 'VerifiedOwned' -and [string]$s1Result[0].MetadataStatus -ceq 'NotApplied' -and [string]$s1Result[0].Reason -ceq $noteText) 'C3: the existing same-content file must be reported as adopted (VerifiedOwned + the 沿用既有檔 note), not rewritten.'
            Check ($s2Result.Count -eq 1 -and [string]$s2Result[0].Status -ceq 'Applied') 'C3: the absent sibling must still be written.'
            Check ((SameFacts $factsS1 (FileFacts (Join-Path $targetRoots.same 's1.bin')))) 'C3: the adopted s1 changed (bytes, ACL, metadata or timestamps): it was rewritten.'
            Check ((Sha (Join-Path $targetRoots.same 's2.bin')) -ceq (Sha (Join-Path $scopes.same 's2.bin'))) 'C3: s2 does not hold the sealed bytes.'
            $stateC=StateNow;$sameOwned=OwnedOf $stateC 'same'
            Check ($sameOwned.Count -eq 2 -and (OwnClass (@($sameOwned|Where-Object {[string]$_.RelativePath -ceq 's1.bin'})[0])) -ceq 'AdoptedExisting' -and (OwnClass (@($sameOwned|Where-Object {[string]$_.RelativePath -ceq 's2.bin'})[0])) -ceq '<none>') 'C3: s1 must be recorded as AdoptedExisting and the tool-written s2 without an Ownership field.'
            $s1Owner=@($sameOwned|Where-Object {[string]$_.RelativePath -ceq 's1.bin'})[0]
            Check ([string]$s1Owner.Backup -ceq '' -and [string]$s1Owner.SHA256 -ceq $factsS1.Sha -and [string]$s1Owner.MetadataHash -ceq $factsS1.Meta -and [long]$s1Owner.Generation -eq 1) 'C3: the adopted row must hold the observed hash and metadata hash, no backup, and the current generation.'
            $rsameR2=@($r1.Full[$ids.rsame].FileResults|Where-Object {[string]$_.RelativePath -ceq 'r2.bin'});$rsameR1=@($r1.Full[$ids.rsame].FileResults|Where-Object {[string]$_.RelativePath -ceq 'r1.bin'})
            Check ($rsameR2.Count -eq 1 -and [string]$rsameR2[0].Status -ceq 'Applied' -and $rsameR1.Count -eq 1 -and [string]$rsameR1[0].Status -ceq 'VerifiedOwned' -and (SameFacts $factsR1 (FileFacts (Join-Path $targetRoots.rsame 'r1.bin')))) 'C3: the Repair-adopted r1 must stay untouched and r2 must be written.'
            Check ((SameFacts $factsD1 (FileFacts (Join-Path $targetRoots.diff 'd1.bin'))) -and @(Get-ChildItem -LiteralPath $targetRoots.diff -Recurse -Force).Count -eq 1) 'D3: the different-content file changed or the blocked item gained Target files.'
            Check ((SameFacts $factsSf (FileFacts $targets.single)) -and (SameFacts $factsSd (FileFacts $targets.singlediff))) 'F3: a single-file external file was changed.'
            Check ((OwnedOf $stateC 'diff').Count -eq 0 -and (OwnedOf $stateC 'single').Count -eq 0 -and (OwnedOf $stateC 'singlediff').Count -eq 0) 'D3/F3: no ownership may be recorded for a blocked external file.'
            Check ((Opt 'same').restored -eq $true -and (Opt 'rsame').restored -eq $true -and (Opt 'diff').restored -eq $false) 'C3: only the items that really succeeded are marked restored.'
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'C3: the journal is inconsistent after the restore.'

            # ====================================== Part D4: the retry loop is gone ======================================
            # 連按重試兩次：每一次候選都不含衝突項目，建立重試收據也都被拒絕；明確再還原一次，結果不變、原檔不變。
            for($press=1;$press -le 2;$press++){
                $retry=Retry
                Check ($retry.Visible) ('D4 press '+$press+': the retry panel must stay visible (items did not succeed).')
                Check (@($retry.CandidateItemIds|Where-Object {$_ -ceq $ids.diff}).Count -eq 0 -and @($retry.CandidateItemIds|Where-Object {$_ -ceq $ids.single}).Count -eq 0 -and @($retry.CandidateItemIds|Where-Object {$_ -ceq $ids.singlediff}).Count -eq 0) ('D4 press '+$press+': a BlockedConflict item is still a retry candidate: '+(Ids $retry.CandidateItemIds))
                $excludedDiff=@($retry.Excluded|Where-Object {[string]$_.ItemId -ceq $ids.diff})
                Check ($excludedDiff.Count -eq 1 -and [string]$excludedDiff[0].Code -ceq 'BlockedConflict' -and ([string]$excludedDiff[0].Reason).Contains($conflictText)) ('D4 press '+$press+': the retry list must exclude the conflict item with its code and reason.')
                $threw=$false;try{[void](Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Retry owner' -Reason 'press retry' -SelectedItemIds @($ids.diff) -Jobs $allJobs -RetryOfReceiptHash ([string]$retry.SourceReceiptHash))}catch{$threw=$true}
                Check $threw ('D4 press '+$press+': a retry receipt for a BlockedConflict item must be refused.')
                $again=RestoreNow @($ids.diff) ('Explicit owner '+$press)
                Check ($again.By[$ids.diff] -ceq 'BlockedConflict' -and (SameFacts $factsD1 (FileFacts (Join-Path $targetRoots.diff 'd1.bin'))) -and @(Get-ChildItem -LiteralPath $targetRoots.diff -Recurse -Force).Count -eq 1) ('D4 press '+$press+': an explicit restore of the conflict item must stay BlockedConflict and leave the file alone.')
            }
            # after the explicit presses, the candidates still never contain it (the attempt now carries only the conflicting item)
            $retryLast=Retry
            Check (@($retryLast.CandidateItemIds).Count -eq 0 -and -not $retryLast.Eligible) 'D4: after the second press the retry list must still have no candidate.'

            # ====================================== Part C4: rollback keeps the adopted file, then restore again ======================================
            $factsBeforeRollback=FileFacts (Join-Path $targetRoots.same 's1.bin');$s2Before=Sha (Join-Path $targetRoots.same 's2.bin')
            $rp=Get-WsmRollbackPreview $targetImport.ManifestPath $targetImport.ManifestHash $stateDirectory
            $rpRows=@{};foreach($row in @($rp.Rows)){$rpRows[[string]$row.ItemId]=$row}
            Check ($rpRows.ContainsKey($ids.same) -and [int]$rpRows[$ids.same].AdoptedExistingFiles -eq 1 -and -not [bool]$rpRows[$ids.same].Blocked) 'C4: the rollback preview must list the adopted file as report-only for the same-content item.'
            $rollbackResult=Invoke-WsmRollback -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory -PreviewHash ([string]$rp.PreviewHash) -Acknowledgement ('ROLLBACK '+$pair) -Confirm:$false
            Check ([string]$rollbackResult.Stage -ceq 'RolledBack') ('C4: the rollback did not finish: '+[string]$rollbackResult.Stage)
            Check ([IO.File]::Exists((Join-Path $targetRoots.same 's1.bin')) -and (SameFacts $factsBeforeRollback (FileFacts (Join-Path $targetRoots.same 's1.bin')))) 'C4: after the rollback the adopted s1 must still exist with the same bytes, ACL, metadata and timestamps.'
            Check ((Sha (Join-Path $targetRoots.rsame 'r1.bin')) -ceq $factsR1.Sha -and (SameFacts $factsR1 (FileFacts (Join-Path $targetRoots.rsame 'r1.bin')))) 'C4: after the rollback the Repair-adopted r1 must still exist untouched.'
            Check (-not [IO.File]::Exists((Join-Path $targetRoots.same 's2.bin')) -and -not [IO.File]::Exists((Join-Path $targetRoots.rsame 'r2.bin'))) 'C4: the tool-written files must be moved away by the rollback.'
            $stateD=StateNow;$sameOwnedD=OwnedOf $stateD 'same'
            Check ($sameOwnedD.Count -eq 1 -and [string]$sameOwnedD[0].RelativePath -ceq 's1.bin' -and (OwnClass $sameOwnedD[0]) -ceq 'AdoptedExisting') 'C4: after the rollback the item keeps exactly the adopted row.'
            Check ((Opt 'same').restorable -eq $true) 'C4: after the rollback the item is restorable again.'
            $r2=RestoreNow @($ids.same) 'After rollback'
            Check ($r2.By[$ids.same] -ceq 'Succeeded' -and (SameFacts $factsBeforeRollback (FileFacts (Join-Path $targetRoots.same 's1.bin'))) -and (Sha (Join-Path $targetRoots.same 's2.bin')) -ceq (Sha (Join-Path $scopes.same 's2.bin'))) 'C4: restore after the rollback must succeed, rewrite only s2 and leave the adopted s1 alone.'
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'C4: the journal is inconsistent after rollback and re-restore.'
            ReplayEqualsLive $stateBytesA 'whole-flow replay (Repair adoption, adopt on restore, rollback, re-restore)'

            # ====================================== Part G: the real writer called directly agrees with the preview (last: it journals without saving state) ======================================
            $writerState=Get-WsmOperationState $pathsT $pkgT
            $writerRecord=Invoke-WsmAssistiveFileScopeRestore $itemDiff $pkgT $pathsT $writerState @{} $null ''
            $d1Row=@($writerRecord.FileResults|Where-Object {[string]$_.RelativePath -ceq 'd1.bin'})
            Check ([string]$writerRecord.Status -ceq 'BlockedConflict' -and $d1Row.Count -eq 1 -and [string]$d1Row[0].Status -ceq 'BlockedConflict' -and [string]$d1Row[0].Reason -ceq $conflictText) ('G1: the writer must refuse the different-content file with the same reason as the preview, got '+[string]$writerRecord.Status+' / '+(@($writerRecord.FileResults|ForEach-Object {[string]$_.RelativePath+'='+[string]$_.Status}) -join ',')+' '+(@($d1Row|ForEach-Object Reason) -join ';'))
            Check ((SameFacts $factsD1 (FileFacts (Join-Path $targetRoots.diff 'd1.bin'))) -and @($writerRecord.OwnedFiles|Where-Object {[string]$_.RelativePath -ceq 'd1.bin'}).Count -eq 0) 'G1: the writer overwrote or adopted the different-content file.'
            # G2 (main agent): the writer itself must keep the single-file scope conservative even when called directly (the preview already blocks it, so the restore path never reaches this guard).
            $itemSingle=@($pkgT.Plan.Items|Where-Object {[string]$_.ItemId -ceq $ids.single})[0]
            $singleRecord=Invoke-WsmAssistiveFileScopeRestore $itemSingle $pkgT $pathsT (Get-WsmOperationState $pathsT $pkgT) @{} $null ''
            Check ([string]$singleRecord.Status -ceq 'BlockedConflict' -and @($singleRecord.OwnedFiles).Count -eq 0 -and (SameFacts $factsSf (FileFacts $targets.single))) ('G2: the writer must not adopt a same-content external file in a single-file scope, got '+[string]$singleRecord.Status)
        }finally{
            Set-Item -Path Function:\script:Invoke-WsmAssistiveFileScopeRestore -Value $script:r3OrigWriter
            Set-Item -Path Function:\script:Assert-WsmCancellationBoundary -Value $script:r3OrigBoundary
        }
        Write-Host ('PASS: directory scope existing files ('+$script:r3Checks+' checks, strict mode on throughout): one per-file judgement shared by preview/options/retry/writer/Repair; same-content external file = Ready everywhere, restored as AdoptedExisting without rewrite and kept by rollback; different-content file = BlockedConflict with count and reason, excluded from the retry list (two presses), original untouched; Repair adopts same-content and keeps different-content files; planned write amount subtracts adopted and conflict files; single-file scope unchanged.')
    } $root $workRoot $srcDir
} finally {
    foreach($path in @($root,$workRoot)){if($path -and [IO.Directory]::Exists($path)){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$path+': '+$_.Exception.Message)}}}
}
