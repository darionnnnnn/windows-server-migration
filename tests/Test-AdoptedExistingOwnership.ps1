#requires -Version 5.1
# P10: a file that holds the sealed backup's exact bytes but has no journal/intent proof that the tool wrote it is recorded as "adopted existing"
# (per-file OwnedFiles[].Ownership = 'AdoptedExisting', shown as 沿用既有檔). Restore treats it as already restored (no rewrite, success); rollback never deletes, overwrites,
# re-ACLs or restores metadata of it; drift on it is only reported, never auto-corrected. Rows without the field (old records, normal writes, intent recovery) stay tool-owned.
#   Part A: unit level  - the one predicate, the ownership hash (old records keep their exact hash), the consumer inventory guard, display text vs console.js.
#   Part B: end to end through the real wizard layer, the REAL file-scope writer (only an exception is injected into the write phase), Repair, restore, rollback:
#           directory scope (adopt -> restore does not rewrite -> rollback keeps bytes/ACL/metadata), mixed item (tool-written + adopted), drift (reported only),
#           single-file scope (RelativePath='') six cases (absent / same bytes / different bytes / reparse / directory occupying / unreadable), normal writes still rolled back,
#           journal replay row-for-row, projections (options, stage file rows, placement preview, rollback preview, offline report rows, HTML-allowed runtime projection).
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-p10-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$workRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsmp10w-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$srcDir=Join-Path $PSScriptRoot '..\src'
try {
    & $module {
        param($Root,$WorkRoot,$SrcDir)
        $script:p10Checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:p10Checks++}
        function Reject([scriptblock]$action,[string]$message,[string]$pattern=''){$rejected=$false;$text='';try{& $action|Out-Null}catch{$rejected=$true;$text=[string]$_.Exception.Message};Check $rejected $message;if($pattern){Check ($text -match $pattern) ($message+' (wrong rejection: '+$text+')')}}
        function SaveJson($data,[string]$path){[IO.File]::WriteAllText($path,($data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$path}
        function Sha([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Ids($Value){(@($Value|Sort-Object) -join ',')}
        function HasProp($Object,[string]$Name){$null -ne $Object -and [bool]$Object.PSObject.Properties[$Name]}
        function OwnClass($Row){if(HasProp $Row 'Ownership'){[string]$Row.Ownership}else{'<none>'}}
        $noteText='沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。'

        # ====================================== Part A1: the one predicate ======================================
        Check (-not (Test-WsmAssistiveOwnedFileAdopted $null)) 'A1: null row must be tool-owned.'
        Check (-not (Test-WsmAssistiveOwnedFileAdopted ([pscustomobject]@{RelativePath='a'}))) 'A1: a row without Ownership (old record) must be tool-owned.'
        Check (Test-WsmAssistiveOwnedFileAdopted ([pscustomobject]@{RelativePath='a';Ownership='AdoptedExisting'})) 'A1: Ownership=AdoptedExisting must be adopted.'
        Check (-not (Test-WsmAssistiveOwnedFileAdopted ([pscustomobject]@{Ownership='adoptedexisting'}))) 'A1: the value is case-sensitive.'
        Check (-not (Test-WsmAssistiveOwnedFileAdopted ([pscustomobject]@{Ownership=''}))) 'A1: an empty Ownership must be tool-owned.'
        Check (-not (Test-WsmAssistiveOwnedFileAdopted ([pscustomobject]@{Ownership='ToolOwned'}))) 'A1: any other value must be tool-owned.'
        Check ((Get-WsmAssistiveAdoptedExistingNote) -ceq $noteText) 'A1: the display note changed.'
        Check ((Test-WsmAssistiveAdoptedExistingReason $noteText) -and -not (Test-WsmAssistiveAdoptedExistingReason 'File bytes and metadata match the sealed artifact and current-generation ownership/readback.')) 'A1: the reason-prefix test does not separate the note from ordinary reasons.'

        # ====================================== Part A2: ownership hash - old records keep their exact hash ======================================
        # The three expected values were computed with the function as it was BEFORE this change (HEAD 29e8129).
        $oneRow=@([pscustomobject]@{RelativePath='a.bin';TargetPath='C:\x\a.bin';SHA256=('a'*64);MetadataHash=('1'*64);Backup='';BackupHash='';Generation=[long]3})
        $twoRows=@([pscustomobject]@{RelativePath='b.bin';TargetPath='C:\x\b.bin';SHA256=('b'*64);MetadataHash=('2'*64);Backup='C:\x\b.bak';BackupHash=('c'*64);Generation=[long]3},[pscustomobject]@{RelativePath='a.bin';TargetPath='C:\x\a.bin';SHA256=('a'*64);MetadataHash=('1'*64);Backup='';BackupHash='';Generation=[long]2})
        Check ((Get-WsmAssistiveFileOwnershipHash $oneRow) -ceq '0fad4a78a29f7680b2cfb9e89830ffff42bf864344405c9861edd3501a1cfef8') 'A2: the hash of an old one-row record changed.'
        Check ((Get-WsmAssistiveFileOwnershipHash $twoRows) -ceq '1282400ac7c318544279ea2e22856617e53885d540f0dc9bed39150ffb76f6fd') 'A2: the hash of an old two-row record changed.'
        Check ((Get-WsmAssistiveFileOwnershipHash @()) -ceq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') 'A2: the hash of an empty record changed.'
        $adoptedOne=@([pscustomobject]@{RelativePath='a.bin';TargetPath='C:\x\a.bin';SHA256=('a'*64);MetadataHash=('1'*64);Backup='';BackupHash='';Generation=[long]3;Ownership='AdoptedExisting'})
        Check ((Get-WsmAssistiveFileOwnershipHash $adoptedOne) -cne (Get-WsmAssistiveFileOwnershipHash $oneRow)) 'A2: the hash does not bind the AdoptedExisting class.'
        Check ((Get-WsmAssistiveFileOwnershipHash @($twoRows[0],$adoptedOne[0])) -cne (Get-WsmAssistiveFileOwnershipHash @($twoRows[0],$oneRow[0]))) 'A2: a mixed set does not bind the AdoptedExisting class.'

        # ====================================== Part A3: consumer inventory guard (every function that reads OwnedFiles is classified) ======================================
        # Adding a new reader of OwnedFiles must be a conscious decision about AdoptedExisting; add it here with its decision.
        $classified=[ordered]@{
            'AssistiveFiles.ps1:Get-WsmFilePlacementPreview'='placement preview: adopted + same bytes -> AdoptedExisting; adopted + changed -> OwnedFileDrift (reported only)'
            'AssistiveRestore.ps1:Test-WsmAssistiveFileScopeOwnershipIncomplete'='shape only (property presence), class-agnostic'
            'AssistiveRestore.ps1:Get-WsmAssistiveFileScopeRestoreGap'='N1 single-file: adopted -> VerifyAdoptedExistingFile / BlockedConflict (never replace); directory scope: trusted hash only'
            'AssistiveRestore.ps1:Invoke-WsmAssistiveRestore'='NonC result record has no files; reservation evidence passes rows through unchanged'
            'AssistiveRestore.ps1:Test-WsmAssistiveRecheckFileScope'='Q1 recheck (read-only): adopted drift -> reported (ReportOnly, AdoptedExistingDrift), never overwritten or deleted; the sealed ACL is not used as the adopted baseline'
            'AssistiveRestore.ps1:Invoke-WsmAssistiveFileScopeRestore'='writer: adopted -> VerifiedOwned without rewrite/ACL assert, drift or new package bytes -> BlockedConflict, skipped by the final metadata pass'
            'Cutover.ps1:Get-WsmAssistiveStageFileResultRows'='stage file rows: Applied with the adopted note as Reason'
            'DeltaWorkflow.ps1:Assert-WsmAssistiveDeltaBaseOwnership'='property presence only'
            'JournalRecovery.ps1:Restore-WsmJournalCheckpoint'='replays Record verbatim; Ownership survives'
            'Recovery.ps1:Complete-WsmAssistiveOperationRepair'='intent recovery: rows are tool-owned (the intent is the proof); no Ownership written'
            'Recovery.ps1:Complete-WsmAssistiveFileScopeOwnershipRepair'='R3: adopts same-content files through the shared record builder New-WsmAssistiveAdoptedFileRecord (it no longer sets Ownership itself)'
            'Recovery.ps1:Get-WsmRollbackPreview'='adopted rows are never blocked, only reported'
            'Recovery.ps1:Remove-WsmAssistiveRolledBackOwnership'='R2: rollback releases the rolled-back per-file ownership; rows outside the rollback vector (AdoptedExisting) are kept verbatim'
            'Recovery.ps1:Invoke-WsmRollback'='adopted rows are excluded from the per-file rollback vector'
            'WizardRuntime.ps1:Get-WsmWizardTargetItemOptions'='projection: adoptedExistingCount/Note'
        }
        $found=New-Object 'System.Collections.Generic.List[string]'
        foreach($sourceFile in @(Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1')){
            $fileAst=[Management.Automation.Language.Parser]::ParseFile($sourceFile.FullName,[ref]$null,[ref]$null)
            foreach($fn in @($fileAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){
                $hits=@($fn.Body.FindAll({param($n)($n -is [Management.Automation.Language.MemberExpressionAst] -and [string]$n.Member.Extent.Text -match '^[''"]?OwnedFiles[''"]?$') -or ($n -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Value -ceq 'OwnedFiles')},$true))
                $keys=@($fn.Body.FindAll({param($n)$n -is [Management.Automation.Language.HashtableAst]},$true)|ForEach-Object {foreach($kv in $_.KeyValuePairs){if($kv.Item1.Extent.Text -ceq 'OwnedFiles'){$kv.Item1}}})
                if($hits.Count -or $keys.Count){$found.Add($sourceFile.Name+':'+$fn.Name)}
            }
        }
        Check ((Ids $found) -ceq (Ids @($classified.Keys))) ('A3: the set of functions that read OwnedFiles changed; classify the new consumer for AdoptedExisting. Found: '+(Ids $found))

        # ====================================== Part A4: the display words are the same in PowerShell and in console.js ======================================
        $consoleJs=[IO.File]::ReadAllText((Join-Path $SrcDir 'ui\console.js'),[Text.Encoding]::UTF8)
        Check ($consoleJs.Contains("ADOPTED_EXISTING_LABEL = '沿用既有檔'") -and $consoleJs.Contains("ADOPTED_EXISTING_NOTE = '內容與備份相同但來歷不明，回復時不會刪除。'")) 'A4: console.js does not carry the adopted label and note.'
        Check ($noteText -ceq ('沿用既有檔：'+'內容與備份相同但來歷不明，回復時不會刪除。')) 'A4: PowerShell note and console.js note differ.'
        Check ($consoleJs.Contains("AdoptedExisting:'沿用既有檔'")) 'A4: console.js statusName has no AdoptedExisting.'

        # ====================================== Part A5: offline report file rows show the class ======================================
        $stageRows=@(
            [pscustomobject]@{ItemId=('a'*64);Channel='C';RelativePath='x.bin';OriginalPath='C:\s\x.bin';PreservedPath='C:\t\x.bin';EffectivePath='C:\t\x.bin';Status='Applied';ExistingTargetPath='';ExistingTargetHash='';SourceHash=('1'*64);ObservedHash=('1'*64);Reason=$noteText;EntryId='';Generation=1;ProjectedGeneration=1},
            [pscustomobject]@{ItemId=('a'*64);Channel='C';RelativePath='y.bin';OriginalPath='C:\s\y.bin';PreservedPath='C:\t\y.bin';EffectivePath='C:\t\y.bin';Status='Applied';ExistingTargetPath='';ExistingTargetHash='';SourceHash=('2'*64);ObservedHash=('2'*64);Reason='File bytes and metadata match the sealed artifact and current-generation ownership/readback.';EntryId='';Generation=1;ProjectedGeneration=1})
        $reportRows=Get-WsmAssistiveReportFileResultRows ([pscustomobject]@{Latest=[pscustomobject]@{Assistive=[pscustomobject]@{FileResults=$stageRows}}}) ([pscustomobject]@{Items=@()})
        Check ($reportRows.Count -eq 2 -and ([string]$reportRows[0][7]).Contains('沿用既有檔') -and ([string]$reportRows[0][7]).StartsWith('Applied') -and [string]$reportRows[1][7] -ceq 'Applied') 'A5: the offline report file row does not show 沿用既有檔 for the adopted file only.'
        Check (([string]$reportRows[0][12]).StartsWith('沿用既有檔：')) 'A5: the offline report reason column lost the note.'

        # ====================================== shared fixture: one real sealed package ======================================
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='Target fixture';OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:wsmP10Target}
        $script:wsmP10Target=$target
        $work=$WorkRoot;$enrollment=Initialize-WsmOutputWorkspace -WorkRoot $work -Role Target;$target|Add-Member NoteProperty HostId ([string]$enrollment.Profile.HostId) -Force
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='Source fixture';OS='Fixture Windows Server';Version='10.0'}
        $defs=@(
            [pscustomobject]@{Key='adopt';Kind='dir';Files=@('a1.bin','a2.bin')},
            [pscustomobject]@{Key='drift';Kind='dir';Files=@('d1.bin','d2.bin')},
            [pscustomobject]@{Key='plain';Kind='dir';Files=@('p1.bin')},
            [pscustomobject]@{Key='sfabsent';Kind='file';Files=@('sf.bin')},
            [pscustomobject]@{Key='sfsame';Kind='file';Files=@('sf.bin')},
            [pscustomobject]@{Key='sfdiff';Kind='file';Files=@('sf.bin')},
            [pscustomobject]@{Key='sfreparse';Kind='file';Files=@('sf.bin')},
            [pscustomobject]@{Key='sfdirocc';Kind='file';Files=@('sf.bin')},
            [pscustomobject]@{Key='sfunread';Kind='file';Files=@('sf.bin')}
        )
        $items=@();$scopes=@{};$targets=@{};$ids=@{};$targetRoots=@{}
        foreach($def in $defs){
            $it=New-WsmItem $source.HostId Storage DataRoot ('P10 workload '+$def.Key) ('p10-source-'+$def.Key) @{Path=('C:\fixture\p10-'+$def.Key)}
            $it|Add-Member NoteProperty Decision Include -Force;$it|Add-Member NoteProperty Reason 'Source owner reviewed fixture scope' -Force;$it|Add-Member NoteProperty Owner 'Source owner' -Force;$it|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
            $scopeDir=Join-Path $Root ('source-'+$def.Key);[void][IO.Directory]::CreateDirectory($scopeDir)
            foreach($name in $def.Files){[IO.File]::WriteAllBytes((Join-Path $scopeDir $name),[Text.Encoding]::UTF8.GetBytes('P10 payload '+$def.Key+' '+$name+' '+[Guid]::NewGuid().ToString('N')))}
            $restoredDir=Join-Path $Root ('restored-'+$def.Key)
            if($def.Kind -ceq 'file'){
                $sourcePath=Join-Path $scopeDir 'sf.bin';$targetPath=Join-Path $restoredDir 'sf.bin'
                if($def.Key -ceq 'sfreparse'){$targetPath=Join-Path (Join-Path $restoredDir 'jct') 'sf.bin'}
            }else{$sourcePath=$scopeDir;$targetPath=$restoredDir}
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
        Check ($validated.Valid) 'Core package validator rejected the real schema-3 payload fixture (directory and single-file items).'
        $delivery=Export-WsmDirectoryDelivery -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $Root 'delivery-one')
        $token=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action DirectoryImport -Path $delivery.SummaryPath -ExpectedHash $delivery.SummarySHA256 -OperationId ([Guid]::NewGuid().ToString())
        $targetImport=Import-WsmWizardTargetDirectoryPackage -Workspace $work -PairId $pair -SummaryPath $delivery.SummaryPath -ExpectedSummaryHash $delivery.SummarySHA256 -SourceDirectory $delivery.Directory -OperationId $token.OperationId -CancellationToken $token
        $allJobs=@($jobs)+@([pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$targetImport.ManifestPath;ManifestHash=$targetImport.ManifestHash;PairId=$pair;PlanHash=$planHash;Generation=$targetImport.Generation;AttemptId=$targetImport.AttemptId})})
        $stateDirectory=Join-Path $work 'pairs';$statePath=Join-Path (Join-Path $stateDirectory $pair) 'state.json'
        $pkgT=Test-WsmMigrationPackage $targetImport.ManifestPath $targetImport.ManifestHash
        $pathsT=Get-WsmOperationPaths $stateDirectory $pair
        function Opts{$ctx=Assert-WsmWizardTargetRole $work $pair;$pr=Get-WsmWizardTargetPackage $work $pair $ctx $allJobs;$p=Get-WsmOperationPaths $stateDirectory $pair;$st=$null;if([IO.File]::Exists($p.State)){$st=Get-WsmOperationState $p $pr.Package};$dec=Get-WsmWizardTargetDecisionRecord $work $pair $ctx.Received.SHA256;@(Get-WsmWizardTargetItemOptions $ctx $pr $st $dec)}
        function Opt([string]$key){@(Opts|Where-Object {[string]$_.value -ceq $ids[$key]})[0]}
        function StateNow{Read-WsmJson $statePath}
        function RowOf($state,[string]$key){,@($state.Items|Where-Object {[string]$_.ItemId -ceq $ids[$key]})}
        function OwnedOf($state,[string]$key){$r=RowOf $state $key;if($r.Count -ne 1 -or -not (HasProp $r[0] 'OwnedFiles')){return ,@()};,@($r[0].OwnedFiles)}
        function Tree([string]$path){if([IO.File]::Exists($path)){return ('F '+(Sha $path))};if(-not [IO.Directory]::Exists($path)){return 'absent'};(@(Get-ChildItem -LiteralPath $path -Recurse -Force|Sort-Object FullName|ForEach-Object {$rel=$_.FullName.Substring($path.Length);if($_.PSIsContainer){'D '+$rel}else{'F '+$rel+' '+(Sha $_.FullName)}}) -join "`n")}
        function RepairNow{Repair-WsmOperation -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory -Confirm:$false}
        function Meta([string]$path){Get-WsmAssistiveMetadataHash (Get-WsmFileMetadata $path 'DaclOwner')}
        function FileFacts([string]$path){[pscustomobject]@{Sha=(Sha $path);Meta=(Meta $path);Sddl=[string](Get-Acl -LiteralPath $path).Sddl;Ticks=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks;Created=(Get-Item -LiteralPath $path).CreationTimeUtc.Ticks}}
        function SameFacts($a,$b){$a.Sha -ceq $b.Sha -and $a.Meta -ceq $b.Meta -and $a.Sddl -ceq $b.Sddl -and $a.Ticks -eq $b.Ticks -and $a.Created -eq $b.Created}
        $asArtifact={param([string]$key,[string]$name,[string]$dest)[IO.File]::WriteAllBytes($dest,$sourceBytes[$key+'/'+$name]);Set-WsmFileMetadata $dest $sourceMeta[$key+'/'+$name] @{}}

        # ====================================== Part B1: real writer, only a write-phase exception injected ======================================
        $script:p10Calls=@{};$script:p10OrigWriter=(Get-Command Invoke-WsmAssistiveFileScopeRestore -CommandType Function).ScriptBlock
        $script:p10OrigBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock
        $script:p10Victims=@{};$script:p10Armed=$false;$script:p10Fired=0
        function Invoke-WsmAssistiveFileScopeRestore {
            $itemId=[string]$args[0].ItemId;$script:p10Calls[$itemId]=1+[int]$(if($script:p10Calls.ContainsKey($itemId)){$script:p10Calls[$itemId]}else{0})
            $script:p10Armed=$script:p10Victims.ContainsKey($itemId)
            try{& $script:p10OrigWriter @args}finally{$script:p10Armed=$false}
        }
        function script:Assert-WsmCancellationBoundary {
            if($script:p10Armed -and [string]$args[1] -ceq 'AssistiveFileWrite'){$script:p10Fired++;throw 'P10 injected write-phase failure'}
            & $script:p10OrigBoundary @args
        }
        $junctionDestination=Join-Path $Root 'junction-destination';$script:p10Junction='';$script:p10DenySid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$script:p10DenyPath=''
        try{
            # the operator (or somebody else) had already put the exact backup bytes at a1 and d1 before the tool ran
            foreach($k in @('adopt','drift')){[void][IO.Directory]::CreateDirectory($targetRoots[$k])}
            & $asArtifact 'adopt' 'a1.bin' (Join-Path $targetRoots.adopt 'a1.bin')
            & $asArtifact 'drift' 'd1.bin' (Join-Path $targetRoots.drift 'd1.bin')
            $selected1=@($defs|ForEach-Object {$ids[$_.Key]})
            foreach($def in $defs){if($def.Key -cne 'plain'){$script:p10Victims[$ids[$def.Key]]=$true}}
            $receipt1=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'First owner' -Reason 'Restore every fixture item' -SelectedItemIds ([string[]]$selected1) -Jobs $allJobs
            $preview1=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            Check (@($preview1.Rows|Where-Object {[string]$_.Status -ceq 'Ready'}).Count -eq 9) ('B1: the fresh preview did not show all nine items Ready: '+(@($preview1.Rows|ForEach-Object {[string]$_.Action+'/'+[string]$_.Status}) -join ','))
            $restore1=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview1.PreviewHash) -Jobs $allJobs
            $by1=@{};foreach($row in @($restore1.ItemResults)){$by1[[string]$row.ItemId]=[string]$row.Status}
            Check ($script:p10Fired -eq 8) ('B1: the injected write-phase exception did not fire once per victim (fired '+$script:p10Fired+').')
            Check ($by1[$ids.plain] -ceq 'Succeeded' -and @($defs|Where-Object {$_.Key -cne 'plain'}|Where-Object {$by1[$ids[$_.Key]] -ceq 'Failed'}).Count -eq 8) ('B1: expected plain Succeeded and eight Failed items: '+(($by1.Values|Sort-Object) -join ','))
            $state1=StateNow;$stateBytesAfterRestore1=[IO.File]::ReadAllBytes($statePath)
            Check (@($state1.PendingOperations).Count -eq 0) 'B1: this shape must leave no pending intent.'
            foreach($def in $defs){if($def.Key -cne 'plain'){$r=RowOf $state1 $def.Key;Check ($r.Count -eq 1 -and [string]$r[0].Status -ceq 'Failed' -and -not (HasProp $r[0] 'OwnedFiles')) ('B1: '+$def.Key+' did not end as a Failed row without OwnedFiles (the P9 defect state).')}}
            $plainOwned1=OwnedOf $state1 'plain'
            Check ($plainOwned1.Count -eq 1 -and -not (HasProp $plainOwned1[0] 'Ownership')) 'B1: a normally written file must carry no Ownership field (tool-owned).'
            $plainBeforeRollback=Sha (Join-Path $targetRoots.plain 'p1.bin')

            # ---- B2. stage the disks the operator would find after the write failure (single-file scope: six situations) ----
            # sfsame: exactly the backup bytes (and metadata) at the target file
            [void][IO.Directory]::CreateDirectory($targetRoots.sfsame);& $asArtifact 'sfsame' 'sf.bin' $targets.sfsame
            # sfdiff: somebody else's content
            [void][IO.Directory]::CreateDirectory($targetRoots.sfdiff);[IO.File]::WriteAllText($targets.sfdiff,'FOREIGN single-file content that must survive')
            # sfreparse: the target file's parent is a junction to a directory that holds the exact bytes
            [void][IO.Directory]::CreateDirectory($junctionDestination);& $asArtifact 'sfreparse' 'sf.bin' (Join-Path $junctionDestination 'sf.bin')
            $jct=Join-Path $targetRoots.sfreparse 'jct';if([IO.Directory]::Exists($jct)){[IO.Directory]::Delete($jct,$false)}
            $mk=(& cmd.exe /c ('mklink /J "'+$jct+'" "'+$junctionDestination+'"') 2>&1);$script:p10Junction=$jct
            Check (([IO.File]::GetAttributes($jct) -band [IO.FileAttributes]::ReparsePoint) -ne 0) ('B2: could not create the junction fixture: '+($mk -join ' '))
            # sfdirocc: a directory occupies the single-file path
            [void][IO.Directory]::CreateDirectory((Join-Path $targets.sfdirocc 'inner'));[IO.File]::WriteAllText((Join-Path (Join-Path $targets.sfdirocc 'inner') 'keep.txt'),'FOREIGN content inside the occupying directory')
            # sfunread: exact bytes, but the account is denied read access (explicit deny ACE; removed in the finally block below)
            [void][IO.Directory]::CreateDirectory($targetRoots.sfunread);& $asArtifact 'sfunread' 'sf.bin' $targets.sfunread
            # sfabsent: nothing at all
            $untouched=@{sfdiff=(Tree $targets.sfdiff);sfdirocc=(Tree $targetRoots.sfdirocc);junction=(Tree $junctionDestination);sfunread=(Sha $targets.sfunread)}
            $facts=@{a1=(FileFacts (Join-Path $targetRoots.adopt 'a1.bin'));d1=(FileFacts (Join-Path $targetRoots.drift 'd1.bin'));sfsame=(FileFacts $targets.sfsame)}
            $adoptTreeBefore=Tree $targetRoots.adopt

            # ---- B3. the exit: Repair-WsmOperation (the P9 reconcile) ----
            $script:p10DenyPath=$targets.sfunread
            $denyOut=(& icacls.exe $targets.sfunread /deny ('*'+$script:p10DenySid+':(RD)') 2>&1)
            $denied=$false;try{[void][IO.File]::ReadAllBytes($targets.sfunread)}catch{$denied=$true}
            Check $denied ('B3: the deny ACE did not make the file unreadable (the "cannot read" case cannot be built on this machine): '+($denyOut -join ' '))
            try{$repair=RepairNow}finally{[void](& icacls.exe $targets.sfunread /remove:d ('*'+$script:p10DenySid) 2>&1);$script:p10DenyPath=''}
            $acl=Get-Acl -LiteralPath $targets.sfunread
            Check (@($acl.Access|Where-Object {[string]$_.AccessControlType -ceq 'Deny'}).Count -eq 0 -and (Sha $targets.sfunread) -ceq $untouched.sfunread) 'B3: the deny ACE was not removed again, or the unreadable file changed.'
            $rec=@{};foreach($o in @($repair.OwnershipReconcile)){$rec[[string]$o.ItemId]=$o}
            Check ($rec.Count -eq 8) ('B3: Repair did not reconcile exactly the eight incomplete items (got '+$rec.Count+').')
            # (a) directory scope: the same-content file is adopted
            Check ($rec[$ids.adopt].Status -ceq 'Reconciled' -and (Ids $rec[$ids.adopt].Adopted) -ceq 'a1.bin' -and (Ids $rec[$ids.adopt].Absent) -ceq 'a2.bin' -and @($rec[$ids.adopt].Conflicts).Count -eq 0 -and [string]$rec[$ids.adopt].AdoptedNote -ceq $noteText) ('B3: adopt item outcome: '+($rec[$ids.adopt]|ConvertTo-Json -Depth 4 -Compress))
            Check ($rec[$ids.drift].Status -ceq 'Reconciled' -and (Ids $rec[$ids.drift].Adopted) -ceq 'd1.bin') 'B3: drift item did not adopt d1.'
            # (b) single-file scope, six cases
            Check ($rec[$ids.sfabsent].Status -ceq 'Reconciled' -and @($rec[$ids.sfabsent].Adopted).Count -eq 0 -and (Ids $rec[$ids.sfabsent].Absent) -ceq '(single file)' -and [string]$rec[$ids.sfabsent].AdoptedNote -ceq '') 'B3(b1): an absent single file must be reported absent, with no ownership.'
            Check ($rec[$ids.sfsame].Status -ceq 'Reconciled' -and (Ids $rec[$ids.sfsame].Adopted) -ceq '(single file)' -and @($rec[$ids.sfsame].Conflicts).Count -eq 0) ('B3(b2): same bytes must be adopted: '+($rec[$ids.sfsame]|ConvertTo-Json -Depth 4 -Compress))
            foreach($pair2 in @(@('sfdiff','content differs'),@('sfreparse','reparse point'),@('sfdirocc','directory occupies'),@('sfunread','could not be verified safely'))){
                $k=$pair2[0];$o=$rec[$ids[$k]]
                Check ($o.Status -ceq 'ManualRequired' -and @($o.Adopted).Count -eq 0 -and @($o.Conflicts).Count -eq 1 -and [string]@($o.Conflicts)[0].Reason -match $pair2[1] -and [string]@($o.Conflicts)[0].RelativePath -ceq '(single file)') ('B3(b): '+$k+' must stay manual with the right reason ('+$pair2[1]+'): '+($o|ConvertTo-Json -Depth 4 -Compress))
                $r=RowOf (StateNow) $k;Check ($r.Count -eq 1 -and @($r[0].OwnedFiles).Count -eq 0 -and @($r[0].ReconcileConflicts).Count -eq 1) ('B3(b): '+$k+' gained ownership or lost its conflict marker.')
            }
            Check ((Tree $targets.sfdiff) -ceq $untouched.sfdiff -and (Tree $targetRoots.sfdirocc) -ceq $untouched.sfdirocc -and (Tree $junctionDestination) -ceq $untouched.junction -and (Sha $targets.sfunread) -ceq $untouched.sfunread) 'B3(b): Repair changed one of the preserved single-file targets.'
            $state2=StateNow
            $aOwned=OwnedOf $state2 'adopt';Check ($aOwned.Count -eq 1 -and [string]$aOwned[0].RelativePath -ceq 'a1.bin' -and (OwnClass $aOwned[0]) -ceq 'AdoptedExisting' -and [string]$aOwned[0].Backup -ceq '' -and [string]$aOwned[0].SHA256 -ceq $facts.a1.Sha) 'B3: the adopt record does not hold exactly a1 as AdoptedExisting.'
            $sOwned=OwnedOf $state2 'sfsame';Check ($sOwned.Count -eq 1 -and [string]$sOwned[0].RelativePath -ceq '' -and (OwnClass $sOwned[0]) -ceq 'AdoptedExisting') 'B3: the single-file record is not AdoptedExisting.'
            Check ((SameFacts $facts.a1 (FileFacts (Join-Path $targetRoots.adopt 'a1.bin'))) -and (SameFacts $facts.sfsame (FileFacts $targets.sfsame)) -and (Tree $targetRoots.adopt) -ceq $adoptTreeBefore) 'B3: Repair changed an adopted file (bytes, ACL, metadata or timestamps) or the adopt tree.'
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'B3: the journal is inconsistent after Repair.'
            $stateBytesAfterRepair=[IO.File]::ReadAllBytes($statePath)
            $stateAfterRepairItems=($state2.Items|Sort-Object ItemId|ConvertTo-Json -Depth 30 -Compress)

            # ---- B4. journal replay: rebuilt rows equal the live rows, including the Ownership column ----
            [IO.File]::WriteAllBytes($statePath,$stateBytesAfterRestore1)
            Check ((Test-WsmJournal $stateDirectory $pair).RecoveryRequired) 'B4: the rolled-back state is not behind the journal (fixture error).'
            $sReplay=Get-WsmOperationState $pathsT $pkgT -AllowRecovery
            Invoke-WsmLocked $pathsT.Root {Restore-WsmJournalCheckpoint $pathsT $sReplay}|Out-Null
            $stateReplayed=StateNow
            Check (($stateReplayed.Items|Sort-Object ItemId|ConvertTo-Json -Depth 30 -Compress) -ceq $stateAfterRepairItems) 'B4: replaying the journal does not reproduce the item records.'
            foreach($k in @('adopt','drift','sfsame','sfabsent')){
                $live=OwnedOf $state2 $k;$re=OwnedOf $stateReplayed $k
                Check ($live.Count -eq $re.Count) ('B4: '+$k+' row counts differ after replay.')
                for($n=0;$n -lt $live.Count;$n++){Check ((HasProp $live[$n] 'Ownership') -eq (HasProp $re[$n] 'Ownership') -and ([string]$(if(HasProp $live[$n] 'Ownership'){$live[$n].Ownership}else{''})) -ceq ([string]$(if(HasProp $re[$n] 'Ownership'){$re[$n].Ownership}else{''})) -and ($live[$n]|ConvertTo-Json -Depth 10 -Compress) -ceq ($re[$n]|ConvertTo-Json -Depth 10 -Compress)) ('B4: '+$k+' row '+$n+' differs after replay.')}
            }
            Check ((OwnClass (OwnedOf $stateReplayed 'adopt')[0]) -ceq 'AdoptedExisting') 'B4: the replayed adopt row lost its Ownership column.'

            # ---- B5. N1 options: adopted counts are projected; reconciled items are restorable, conflicted ones are not ----
            $oAdopt=Opt 'adopt';$oPlain=Opt 'plain';$oAbsent=Opt 'sfabsent';$oSame=Opt 'sfsame'
            Check ([int]$oAdopt.adoptedExistingCount -eq 1 -and [string]$oAdopt.adoptedExistingNote -ceq $noteText -and [int]$oSame.adoptedExistingCount -eq 1 -and [int]$oPlain.adoptedExistingCount -eq 0 -and [string]$oPlain.adoptedExistingNote -ceq '' -and [int]$oAbsent.adoptedExistingCount -eq 0) 'B5: the item options do not project the adopted-existing count and note (or project them for ordinary items).'
            foreach($k in @('adopt','drift','sfabsent','sfsame')){Check ((Opt $k).restorable -eq $true) ('B5: '+$k+' is not restorable after reconcile.')}
            foreach($k in @('sfdiff','sfreparse','sfdirocc','sfunread')){Check ((Opt $k).restorable -eq $false -and [string](Opt $k).restorableCode -ceq 'NeedsReconciliation' -and [int](Opt $k).adoptedExistingCount -eq 0) ('B5: '+$k+' became restorable although its conflict is unresolved.')}

            # ---- B6. drift: d1 is changed in place after it was adopted; restore must report it and leave it ----
            [IO.File]::WriteAllText((Join-Path $targetRoots.drift 'd1.bin'),'CHANGED by somebody after adoption');$driftChanged=FileFacts (Join-Path $targetRoots.drift 'd1.bin')
            $place0=Get-WsmFilePlacementPreview -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory
            $pRow=@($place0.Rows|Where-Object {[string]$_.ItemId -ceq $ids.drift -and [string]$_.RelativePath -ceq 'd1.bin'})
            Check ($pRow.Count -eq 1 -and [string]$pRow[0].PlacementStatus -ceq 'OwnedFileDrift' -and [string]$pRow[0].Reason -match 'only reported') ('B6: the placement preview did not report the drifted adopted file as OwnedFileDrift (reported only): '+$pRow[0].PlacementStatus+' / '+$pRow[0].Reason)
            $aRow=@($place0.Rows|Where-Object {[string]$_.ItemId -ceq $ids.adopt -and [string]$_.RelativePath -ceq 'a1.bin'})
            Check ($aRow.Count -eq 1 -and [string]$aRow[0].PlacementStatus -ceq 'AdoptedExisting' -and [string]$aRow[0].Reason -ceq $noteText) 'B6: the placement preview did not mark the unchanged adopted file AdoptedExisting with the note.'
            $sRow=@($place0.Rows|Where-Object {[string]$_.ItemId -ceq $ids.sfsame})
            Check ($sRow.Count -eq 1 -and [string]$sRow[0].PlacementStatus -ceq 'AdoptedExisting') 'B6: the placement preview did not mark the single-file adopted target AdoptedExisting.'

            # ---- B7. restore again: adopt (a1 not rewritten, a2 written by the tool), drift (d1 reported), sfsame (not rewritten), sfabsent (written by the tool) ----
            $script:p10Victims=@{};$callsBefore=@{};foreach($k in $script:p10Calls.Keys){$callsBefore[$k]=$script:p10Calls[$k]}
            $selected2=@($ids.adopt,$ids.drift,$ids.sfsame,$ids.sfabsent)
            $receipt2=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Second owner' -Reason 'Restore the reconciled items' -SelectedItemIds ([string[]]$selected2) -Jobs $allJobs
            $preview2=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $sameRowPreview=@($preview2.Rows|Where-Object {[string]$_.ItemId -ceq $ids.sfsame})
            Check ($sameRowPreview.Count -eq 1 -and [string]$sameRowPreview[0].Action -ceq 'VerifyAdoptedExistingFile' -and [string]$sameRowPreview[0].Status -ceq 'Ready' -and [string]$sameRowPreview[0].Reason -ceq $noteText) ('B7: the restore preview for the adopted single file is not VerifyAdoptedExistingFile/Ready with the note: '+$sameRowPreview[0].Action+' / '+$sameRowPreview[0].Reason)
            $restore2=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview2.PreviewHash) -Jobs $allJobs
            $by2=@{};$res2=@{};foreach($row in @($restore2.ItemResults)){$by2[[string]$row.ItemId]=[string]$row.Status;$res2[[string]$row.ItemId]=$row}
            Check ($by2[$ids.adopt] -ceq 'Succeeded' -and $by2[$ids.sfsame] -ceq 'Succeeded' -and $by2[$ids.sfabsent] -ceq 'Succeeded' -and $by2[$ids.drift] -ceq 'BlockedConflict') ('B7: unexpected statuses '+(($by2.GetEnumerator()|ForEach-Object {$_.Key.Substring(0,6)+'='+$_.Value}) -join ','))
            $a1Result=@($res2[$ids.adopt].FileResults|Where-Object {[string]$_.RelativePath -ceq 'a1.bin'})
            Check ($a1Result.Count -eq 1 -and [string]$a1Result[0].Status -ceq 'VerifiedOwned' -and [string]$a1Result[0].Reason -ceq $noteText -and [string]$a1Result[0].MetadataStatus -ceq 'NotApplied') 'B7: the writer did not treat the adopted a1 as already restored (VerifiedOwned with the note, no metadata applied).'
            $a2Result=@($res2[$ids.adopt].FileResults|Where-Object {[string]$_.RelativePath -ceq 'a2.bin'})
            Check ($a2Result.Count -eq 1 -and [string]$a2Result[0].Status -ceq 'Applied') 'B7: the writer did not write the absent a2.'
            Check ((SameFacts $facts.a1 (FileFacts (Join-Path $targetRoots.adopt 'a1.bin'))) -and (SameFacts $facts.sfsame (FileFacts $targets.sfsame))) 'B7: restore rewrote an adopted file (bytes, ACL, metadata or timestamps changed).'
            Check ((Sha (Join-Path $targetRoots.adopt 'a2.bin')) -ceq (Sha (Join-Path $scopes.adopt 'a2.bin')) -and (Sha $targets.sfabsent) -ceq (Sha (Join-Path $scopes.sfabsent 'sf.bin'))) 'B7: a2 / the absent single file do not hold the source bytes.'
            Check (@(Get-ChildItem -LiteralPath $targetRoots.adopt -Force|Where-Object {$_.Name -like '.wsm-*'}).Count -eq 0) 'B7: restore left transaction material (staging/backup) next to the adopted file.'
            $d1Result=@($res2[$ids.drift].FileResults|Where-Object {[string]$_.RelativePath -ceq 'd1.bin'})
            Check ($d1Result.Count -eq 1 -and [string]$d1Result[0].Status -ceq 'BlockedConflict' -and [string]$d1Result[0].Reason -match 'only reported' -and [string]$d1Result[0].Reason -match 'never overwritten') 'B7: the drifted adopted file was not reported as BlockedConflict (reported only, never overwritten).'
            Check ((SameFacts $driftChanged (FileFacts (Join-Path $targetRoots.drift 'd1.bin'))) -and [IO.File]::ReadAllText((Join-Path $targetRoots.drift 'd1.bin')) -ceq 'CHANGED by somebody after adoption') 'B7: the drifted adopted file was overwritten or modified.'
            $state3=StateNow
            $a3=OwnedOf $state3 'adopt'
            Check ($a3.Count -eq 2 -and (OwnClass (@($a3|Where-Object {[string]$_.RelativePath -ceq 'a1.bin'})[0])) -ceq 'AdoptedExisting' -and -not (HasProp (@($a3|Where-Object {[string]$_.RelativePath -ceq 'a2.bin'})[0]) 'Ownership')) 'B7: the mixed item must hold a1 as AdoptedExisting and the tool-written a2 without an Ownership field.'
            $abs3=OwnedOf $state3 'sfabsent';Check ($abs3.Count -eq 1 -and -not (HasProp $abs3[0] 'Ownership')) 'B7: a normally written single file must be tool-owned (no Ownership field).'
            Check (@($script:p10Calls.Keys|Where-Object {[int]$script:p10Calls[$_] -ne [int]$callsBefore[$_]+$(if($selected2 -ccontains $_){1}else{0})}).Count -eq 0) 'B7: the writer ran for an item that was not selected.'

            # ---- B8. projections: stage file rows (Fleet contract), restore option, runtime projection, report rows ----
            $projection=Get-WsmAssistiveStageResultProjection $pkgT $state3
            $adoptStage=@($projection.FileResults|Where-Object {[string]$_.ItemId -ceq $ids.adopt})
            $a1Stage=@($adoptStage|Where-Object {[string]$_.RelativePath -ceq 'a1.bin'});$a2Stage=@($adoptStage|Where-Object {[string]$_.RelativePath -ceq 'a2.bin'})
            Check ($a1Stage.Count -eq 1 -and [string]$a1Stage[0].Status -ceq 'Applied' -and [string]$a1Stage[0].Reason -ceq $noteText -and $a2Stage.Count -eq 1 -and [string]$a2Stage[0].Status -ceq 'Applied' -and -not (Test-WsmAssistiveAdoptedExistingReason ([string]$a2Stage[0].Reason))) 'B8: the stage file rows must show the note for the adopted a1 and an ordinary reason for the tool-written a2 (both Applied).'
            $sfStage=@($projection.FileResults|Where-Object {[string]$_.ItemId -ceq $ids.sfsame});Check ($sfStage.Count -eq 1 -and [string]$sfStage[0].Reason -ceq $noteText) 'B8: the single-file stage row does not show the note.'
            $fleetCheck=[pscustomobject]@{ApprovedItemIds=@($ids.adopt);FileResults=[object[]]$adoptStage}
            $fleetOk=$true;try{Assert-WsmAssistiveFileResultRows $fleetCheck ([long]1)}catch{$fleetOk=$false;$fleetErr=$_.Exception.Message}
            Check $fleetOk ('B8: the Fleet per-file result contract rejects a stage row that carries the adopted note: '+$(if($fleetOk){''}else{$fleetErr}))
            $driftStage=@($projection.FileResults|Where-Object {[string]$_.ItemId -ceq $ids.drift -and [string]$_.RelativePath -ceq 'd1.bin'})
            Check ($driftStage.Count -eq 1 -and [string]$driftStage[0].Status -cne 'Applied') 'B8: the drifted adopted file must not be reported as an applied file in the stage rows.'
            $reportRows2=Get-WsmAssistiveReportFileResultRows ([pscustomobject]@{Latest=[pscustomobject]@{Assistive=[pscustomobject]@{FileResults=$projection.FileResults}}}) ([pscustomobject]@{Items=@()})
            Check (@($reportRows2|Where-Object {([string]$_[7]).Contains('沿用既有檔')}).Count -eq 2) 'B8: the offline report rows show 沿用既有檔 for exactly the two unchanged adopted files (adopt a1, sfsame).'
            $restoreJob2=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restore2.AttemptOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($restore2)}
            $runtime=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($restoreJob2)))
            $runtimeJson=($runtime|ConvertTo-Json -Depth 30 -Compress)
            $runtimeBody=$runtime.runtime;if(HasProp $runtimeBody 'target'){$runtimeBody=$runtimeBody.target};$optionsHtml=@($runtimeBody.itemOptions)
            $htmlAdopt=@($optionsHtml|Where-Object {[string]$_.value -ceq $ids.adopt});$htmlPlain=@($optionsHtml|Where-Object {[string]$_.value -ceq $ids.plain})
            Check ($htmlAdopt.Count -eq 1 -and [int]$htmlAdopt[0].adoptedExistingCount -eq 1 -and [string]$htmlAdopt[0].adoptedExistingNote -ceq $noteText -and $htmlPlain.Count -eq 1 -and [int]$htmlPlain[0].adoptedExistingCount -eq 0) 'B8: the HTML-allowed runtime projection drops the adopted count/note or shows it for a normal item.'

            # ---- B9. rollback preview, then the real rollback ----
            # R1：這個區塊與整支測試一樣在 Set-StrictMode -Version Latest 下執行；回復預覽對沒有 Backup 欄位的逐檔 FileScope 紀錄有屬性守門。
            $rp=Get-WsmRollbackPreview $targetImport.ManifestPath $targetImport.ManifestHash $stateDirectory
            $rpRows=@{};foreach($row in @($rp.Rows)){$rpRows[[string]$row.ItemId]=$row}
            Check (@($rp.Rows|Where-Object Blocked).Count -eq 0) ('B9: the rollback preview is blocked although adopted files must never block it: '+(@($rp.Rows|Where-Object Blocked|ForEach-Object {$_.Reason}) -join ';'))
            Check ([int]$rpRows[$ids.adopt].AdoptedExistingFiles -eq 1 -and [string]$rpRows[$ids.adopt].Reason -match '沿用既有檔' -and [int]$rpRows[$ids.sfsame].AdoptedExistingFiles -eq 1 -and [int]$rpRows[$ids.plain].AdoptedExistingFiles -eq 0 -and [string]$rpRows[$ids.plain].Reason -notmatch '沿用既有檔') 'B9: the rollback preview rows do not state the adopted files (or state them for an ordinary item).'
            Check ([int]$rpRows[$ids.drift].AdoptedExistingFiles -eq 1 -and [string]$rpRows[$ids.drift].Reason -match '已變更' -and [string]$rpRows[$ids.drift].Reason -match '僅回報') 'B9: the rollback preview does not report the changed adopted file (reported only).'
            $beforeRollback=@{a1=(FileFacts (Join-Path $targetRoots.adopt 'a1.bin'));sfsame=(FileFacts $targets.sfsame);d1=(FileFacts (Join-Path $targetRoots.drift 'd1.bin'));a2=(Sha (Join-Path $targetRoots.adopt 'a2.bin'));sfabsent=(Sha $targets.sfabsent);d2=(Sha (Join-Path $targetRoots.drift 'd2.bin'))}
            $rollbackResult=Invoke-WsmRollback -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory -PreviewHash ([string]$rp.PreviewHash) -Acknowledgement ('ROLLBACK '+$pair) -Confirm:$false
            Check ([string]$rollbackResult.Stage -ceq 'RolledBack') ('B9: the rollback did not finish: '+[string]$rollbackResult.Stage)
            # adopted files: still there, byte for byte, ACL and metadata unchanged
            Check ((SameFacts $beforeRollback.a1 (FileFacts (Join-Path $targetRoots.adopt 'a1.bin'))) -and (SameFacts $beforeRollback.sfsame (FileFacts $targets.sfsame)) -and (SameFacts $beforeRollback.d1 (FileFacts (Join-Path $targetRoots.drift 'd1.bin')))) 'B9: rollback deleted, rewrote or re-ACLed an adopted file (bytes, ACL, metadata or timestamps changed).'
            Check ([IO.File]::ReadAllText((Join-Path $targetRoots.drift 'd1.bin')) -ceq 'CHANGED by somebody after adoption') 'B9: rollback touched the drifted adopted file.'
            # tool-written files: rolled back (displaced to a retained sibling), exactly as before this change
            Check (-not [IO.File]::Exists((Join-Path $targetRoots.adopt 'a2.bin')) -and -not [IO.File]::Exists($targets.sfabsent) -and -not [IO.File]::Exists((Join-Path $targetRoots.drift 'd2.bin')) -and -not [IO.File]::Exists((Join-Path $targetRoots.plain 'p1.bin'))) 'B9: rollback no longer removes the files the tool wrote (a2, d2, the single file, p1): the ordinary case became "never delete".'
            $retainedHashes=@(foreach($dirPath in @($targetRoots.adopt,$targetRoots.drift,$targetRoots.plain,$targetRoots.sfabsent)){Get-ChildItem -LiteralPath $dirPath -Force|Where-Object {$_.Name -like '.wsm-assistive-rollback-*'}|ForEach-Object {Sha $_.FullName}})
            Check (@($retainedHashes|Where-Object {$_ -ceq $beforeRollback.a2 -or $_ -ceq $beforeRollback.sfabsent -or $_ -ceq $beforeRollback.d2 -or $_ -ceq $plainBeforeRollback}).Count -eq 4) 'B9: the displaced tool-written files are not retained next to their targets.'
            $state4=StateNow
            foreach($k in @('adopt','drift','plain','sfabsent','sfsame')){$r=RowOf $state4 $k;Check ($r.Count -eq 1 -and [string]$r[0].Status -ceq 'RolledBack' -and $r[0].CreatedByTool -eq $false) ('B9: '+$k+' is not retired by the rollback.')}
            $a4=OwnedOf $state4 'adopt';Check ($a4.Count -eq 1 -and [string]$a4[0].RelativePath -ceq 'a1.bin' -and (OwnClass $a4[0]) -ceq 'AdoptedExisting') 'B9: the rolled-back record must keep only the adopted a1 (R2: the tool-written a2 ownership is released by the rollback, the adopted class is not).'
            # the four unresolved single-file cases keep their original bytes
            Check ((Tree $targets.sfdiff) -ceq $untouched.sfdiff -and (Tree $targetRoots.sfdirocc) -ceq $untouched.sfdirocc -and (Tree $junctionDestination) -ceq $untouched.junction -and (Sha $targets.sfunread) -ceq $untouched.sfunread) 'B9: rollback changed a preserved single-file case (different bytes / directory / junction / unreadable).'
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'B9: the journal is inconsistent after rollback.'
            # journal replay of the whole flow still reproduces every row (restore, repair, rollback)
            $stateFinalItems=($state4.Items|Sort-Object ItemId|ConvertTo-Json -Depth 30 -Compress)
            [IO.File]::WriteAllBytes($statePath,$stateBytesAfterRestore1)
            $sReplay2=Get-WsmOperationState $pathsT $pkgT -AllowRecovery
            Invoke-WsmLocked $pathsT.Root {Restore-WsmJournalCheckpoint $pathsT $sReplay2}|Out-Null
            $replayFinal=StateNow
            foreach($k in @('adopt','drift','sfsame','sfabsent','plain')){
                $live=OwnedOf $state4 $k;$re=OwnedOf $replayFinal $k
                Check ($live.Count -eq $re.Count) ('B9: '+$k+' owned rows differ in number after the whole-flow replay.')
                for($n=0;$n -lt $live.Count;$n++){Check (([string]$(if(HasProp $live[$n] 'Ownership'){$live[$n].Ownership}else{'<none>'})) -ceq ([string]$(if(HasProp $re[$n] 'Ownership'){$re[$n].Ownership}else{'<none>'}))) ('B9: '+$k+' row '+$n+' Ownership differs after the whole-flow replay.')}
            }
        }finally{
            if($script:p10DenyPath -and [IO.File]::Exists($script:p10DenyPath)){[void](& icacls.exe $script:p10DenyPath /remove:d ('*'+$script:p10DenySid) 2>&1)}
            Set-Item -Path Function:\script:Invoke-WsmAssistiveFileScopeRestore -Value $script:p10OrigWriter
            Set-Item -Path Function:\script:Assert-WsmCancellationBoundary -Value $script:p10OrigBoundary
            if($script:p10Junction -and [IO.Directory]::Exists($script:p10Junction) -and (([IO.File]::GetAttributes($script:p10Junction) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){[IO.Directory]::Delete($script:p10Junction,$false)}
        }
        # (static, placed after the behavioural parts so that behaviour is what fails first) Only ONE record builder may produce AdoptedExisting (R3): every hashtable that sets an Ownership key in src must be New-WsmAssistiveAdoptedFileRecord (called by the P9 reconcile and by the R3 directory-scope writer) or the hash body (a copy of an existing row).
        # The intent recovery (AssistiveFileIntent / AssistiveFileReplace evidence) never sets it, and the writer's tool-written rows carry no Ownership field, so those rows stay tool-owned.
        $ownershipKeyFns=New-Object 'System.Collections.Generic.List[string]'
        foreach($sourceFile in @(Get-ChildItem -LiteralPath $SrcDir -Filter '*.ps1')){
            $fileAst=[Management.Automation.Language.Parser]::ParseFile($sourceFile.FullName,[ref]$null,[ref]$null)
            foreach($fn in @($fileAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){
                $setters=@($fn.Body.FindAll({param($n)$n -is [Management.Automation.Language.HashtableAst]},$true)|ForEach-Object {foreach($kv in $_.KeyValuePairs){if($kv.Item1.Extent.Text -ceq 'Ownership'){$kv.Item1}}})
                if($setters.Count){$ownershipKeyFns.Add($sourceFile.Name+':'+$fn.Name)}
            }
        }
        Check ((Ids $ownershipKeyFns) -ceq (Ids @('AssistiveRestore.ps1:Get-WsmAssistiveFileOwnershipHash','AssistiveRestore.ps1:New-WsmAssistiveAdoptedFileRecord'))) ('A3: something other than the shared adopted-record builder sets an Ownership key: '+(Ids $ownershipKeyFns))

        # no deny ACE may survive anywhere under the fixture
        $leftover=@(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue|Where-Object {@((Get-Acl -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Access|Where-Object {[string]$_.AccessControlType -ceq 'Deny'}).Count -gt 0})
        Check ($leftover.Count -eq 0) ('Cleanup: a deny ACE survived on '+(($leftover|ForEach-Object FullName) -join ';'))
        Write-Host ('PASS: adopted existing ownership ('+$script:p10Checks+' checks): the one predicate, old ownership hashes unchanged, consumer inventory guarded, Repair adopts same-content files (directory and single-file scope, six single-file cases), restore does not rewrite them, rollback keeps bytes/ACL/metadata while tool-written files are still rolled back, drift is reported only, journal replay row for row, projections show 沿用既有檔.')
    } $root $workRoot $srcDir
} finally {
    foreach($path in @($root,$workRoot)){if($path -and [IO.Directory]::Exists($path)){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$path+': '+$_.Exception.Message)}}}
}
