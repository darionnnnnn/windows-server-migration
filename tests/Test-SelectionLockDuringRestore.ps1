#requires -Version 5.1
# Q4: while a TargetRestore parent is in progress (Running / WaitingForInput / Interrupted, plus Queued / CancelRequested) the selection and the decision receipt cannot change.
#   Create-WsmWizardTargetDecisionReceipt (normal path and the P8 RetryOfReceiptHash path) refuses with 'RestoreInProgress:' before anything is written,
#   the runtime projection carries the lock (runtime.restoreLock) and disables the create-receipt / retry actions, and a finished restore (Partial / Succeeded) unlocks again.
#   The fixture (sealed plan, verified package, comparison, a real Partial restore) is the one of Test-RetryFailedItems.ps1; job records are stubs.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-p8-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$workRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsmp8w-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
try {
    & $module {
        param($Root,$WorkRoot)
        $script:p8Checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:p8Checks++}
        function Reject([scriptblock]$action,[string]$message,[string]$pattern=''){$rejected=$false;$text='';try{& $action|Out-Null}catch{$rejected=$true;$text=[string]$_.Exception.Message};Check $rejected $message;if($pattern){Check ($text -match $pattern) ($message+' (wrong rejection: '+$text+')')}}
        function SaveJson($data,[string]$path){[IO.File]::WriteAllText($path,($data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$path}
        function Sha([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}

        # ====================================== Part B: the real wizard layer ======================================
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='Target fixture';OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:wsmP8Target}
        $script:wsmP8Target=$target
        $work=$WorkRoot;$enrollment=Initialize-WsmOutputWorkspace -WorkRoot $work -Role Target;$target|Add-Member NoteProperty HostId ([string]$enrollment.Profile.HostId) -Force
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='Source fixture';OS='Fixture Windows Server';Version='10.0'}
        $fileSpec=$null;$items=@();$scopes=@();$targets=@()
        foreach($n in 1..3){
            $it=New-WsmItem $source.HostId Storage DataRoot ('Approved fixture workload '+$n) ('fixture-source-'+$n) @{Path=('C:\fixture\source-'+$n)}
            $it|Add-Member NoteProperty Decision Include -Force;$it|Add-Member NoteProperty Reason 'Source owner reviewed fixture scope' -Force;$it|Add-Member NoteProperty Owner 'Source owner' -Force;$it|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
            $scope=Join-Path $Root ('source-scope-'+$n);[void][IO.Directory]::CreateDirectory($scope);[IO.File]::WriteAllBytes((Join-Path $scope 'state.bin'),[Text.Encoding]::UTF8.GetBytes('P8 payload '+$n+' '+[Guid]::NewGuid().ToString('N')))
            $targetRoot=Join-Path $Root ('restored-scope-'+$n)
            $spec=[pscustomobject][ordered]@{Adapter='FileScope';Product='Fixture workload';Procedure='Owner independently verifies the restored file';Artifacts=@();BusinessChecks=@('Owner confirms exact file bytes and ACL');Owner='Source owner';Evidence='fixture approval evidence';SourcePath=$scope;TargetPath=$targetRoot;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';TransferChannel='C';ContentSelection='WholeScope';ConfigFiles=@();ConfigOverrides=@()}
            $it|Add-Member NoteProperty MigrationSpec $spec -Force;$items+=@($it);$scopes+=@($scope);$targets+=@($targetRoot)
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
        # real sealed package from native C-volume observations
        $packageRoot=Join-Path $Root 'sealed-package';[void][IO.Directory]::CreateDirectory($packageRoot);[void][IO.Directory]::CreateDirectory((Join-Path $packageRoot 'payload'))
        [IO.File]::Copy($planPath,(Join-Path $packageRoot 'plan.json'))
        $records=@();$proofs=@();$totalBytes=[long]0
        for($i=0;$i -lt 3;$i++){
            $proof=Assert-WsmAssistiveSourceScope $items[$i].MigrationSpec SourceCOnly -Native;if($proof.Channel -cne 'C'){throw 'The isolated source fixtures must be on the native C volume.'}
            $file=Join-Path $scopes[$i] 'state.bin';$blob=Write-WsmPayloadFile $file (Join-Path $packageRoot 'payload') 65536 0 $null;$totalBytes+=[long](Get-Item -LiteralPath $file).Length
            $records+=@([pscustomobject][ordered]@{ItemId=[string]$items[$i].ItemId;RelativePath='';Directory=$true;Metadata=(Get-WsmFileMetadata $scopes[$i] 'DaclOwner');Data=$null},[pscustomobject][ordered]@{ItemId=[string]$items[$i].ItemId;RelativePath='state.bin';Directory=$false;Metadata=(Get-WsmFileMetadata $file 'DaclOwner');Data=$blob})
            $proofs+=@([pscustomobject][ordered]@{ItemId=$items[$i].ItemId;Channel=$proof.Channel;PhysicalPath=$proof.PhysicalPath;SourceCPhysicalRoot=$proof.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true})
        }
        $indexPath=Join-Path $packageRoot 'artifacts.jsonl';$indexText=(@($records|ForEach-Object {ConvertTo-Json -InputObject $_ -Depth 30 -Compress}) -join "`n")+"`n";[IO.File]::WriteAllText($indexPath,$indexText,(New-Object Text.UTF8Encoding($false)));$indexHash=Sha $indexPath
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString();BatchId=$plan.BatchId;PairId=$pair;ApprovalId=$plan.ApprovalId;PlanHash=$planHash;Source=$plan.Source;Target=$plan.Target;InventoryRevision=1;DecisionRevision=4;Generation=1;BaseManifestHash='';Final=$false;FreezeHash='';ArtifactsHash=$indexHash;Files=3;Bytes=$totalBytes;Records=6;ChunkBytes=65536;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot';SourceCollectionProofs=$proofs}
        $manifestPath=Join-Path $packageRoot 'manifest.json';SaveJson $manifest $manifestPath|Out-Null;$manifestHash=Sha $manifestPath;$validated=Test-WsmMigrationPackage $manifestPath $manifestHash
        Check ($validated.Valid) 'Core package validator rejected the real schema-3 payload fixture.'
        $delivery=Export-WsmDirectoryDelivery -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $Root 'delivery-one')
        $token=New-WsmWizardTargetPackageCancellation -Workspace $work -PairId $pair -Action DirectoryImport -Path $delivery.SummaryPath -ExpectedHash $delivery.SummarySHA256 -OperationId ([Guid]::NewGuid().ToString())
        $targetImport=Import-WsmWizardTargetDirectoryPackage -Workspace $work -PairId $pair -SummaryPath $delivery.SummaryPath -ExpectedSummaryHash $delivery.SummarySHA256 -SourceDirectory $delivery.Directory -OperationId $token.OperationId -CancellationToken $token
        $allJobs=@($jobs)+@([pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$targetImport.ManifestPath;ManifestHash=$targetImport.ManifestHash;PairId=$pair;PlanHash=$planHash;Generation=$targetImport.Generation;AttemptId=$targetImport.AttemptId})})
        $ids=@($items|ForEach-Object {[string]$_.ItemId});$id1=$ids[0];$id2=$ids[1];$id3=$ids[2]
        $statePath=Join-Path (Join-Path (Join-Path $work 'pairs') $pair) 'state.json'

        # One restore of all three items. Item 3's approved directory target is occupied by a FILE: the real preview blocks it (BlockedConflict) and the real
        # restore writes items 1 and 2 and leaves item 3 without a state row. The file-scope writer is only wrapped to count its calls (no behavior change).
        $script:p8Calls=@{};$script:p8OrigWriter=(Get-Command Invoke-WsmAssistiveFileScopeRestore -CommandType Function).ScriptBlock
        function Invoke-WsmAssistiveFileScopeRestore {
            $itemId=[string]$args[0].ItemId;$script:p8Calls[$itemId]=1+[int]$(if($script:p8Calls.ContainsKey($itemId)){$script:p8Calls[$itemId]}else{0})
            & $script:p8OrigWriter @args
        }
        $conflictText='a file occupies the approved directory target';[IO.File]::WriteAllText($targets[2],$conflictText)
        try{
            $receipt1=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'First owner' -Reason 'Restore all three fixture items' -SelectedItemIds ([string[]]$ids) -Jobs $allJobs
            $noAttempt=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check (-not $noAttempt.Visible -and $noAttempt.ReasonCode -ceq 'NoRestoreAttempt') 'Retry was offered before any restore ran.'
            $preview1=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $restore1=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview1.PreviewHash) -Jobs $allJobs
            $by1=@{};foreach($row in @($restore1.ItemResults)){$by1[[string]$row.ItemId]=[string]$row.Status}
            Check ($restore1.Status -ceq 'Partial' -and $by1[$id1] -ceq 'Succeeded' -and $by1[$id2] -ceq 'Succeeded' -and $by1[$id3] -ceq 'BlockedConflict') ('The target conflict did not produce one Partial result with exactly item 3 blocked: '+($by1.Values -join ','))
            $state1=Read-WsmJson $statePath
            Check (@($state1.PendingOperations).Count -eq 0) 'The blocked item left a pending intent; this scenario expects none.'
            $record1Before=@($state1.Items|Where-Object {[string]$_.ItemId -in @($id1,$id2)}|ForEach-Object {$_|ConvertTo-Json -Depth 20 -Compress})
            $hashes1=@($targets[0],$targets[1]|ForEach-Object {Sha (Join-Path $_ 'state.bin')})
            Check ([IO.File]::Exists($targets[2]) -and [IO.File]::ReadAllText($targets[2]) -ceq $conflictText) 'The conflicting file was touched by the restore.'
            $callsAfterRestore=@{};foreach($k in $script:p8Calls.Keys){$callsAfterRestore[$k]=$script:p8Calls[$k]}

            # ====================================== Q4: selection is locked while the restore parent is in progress ======================================
            function Ids($Value){(@($Value|Sort-Object) -join ',')}
            $materialRoot=Get-WsmWizardTargetMaterialRoot $work $pair
            function DecisionCount{@(Get-ChildItem -LiteralPath $materialRoot -Filter 'decision-*.json' -ErrorAction SilentlyContinue).Count}
            function RestoreJob([string]$Status,[int]$MinutesFromNow=1,[string]$JobPair=$pair,[string]$JobWorkspace=$work){[pscustomobject]@{action='TargetRestore';status=$Status;role='Target';pairId=$JobPair;workspace=$JobWorkspace;jobId=[Guid]::NewGuid().ToString();StartedUtc=([DateTime]::UtcNow.AddMinutes($MinutesFromNow).ToString('o'))}}
            # the operator resolves the conflict so the retry candidates exist (the same state as the P8 test before it creates the retry receipt)
            [IO.File]::Delete($targets[2])
            $cand=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($cand.Visible -and $cand.Eligible -and (Ids $cand.CandidateItemIds) -ceq $id3) 'The Q4 fixture does not offer the failed item for retry before the lock scenarios.'
            $source=[string]$cand.SourceReceiptHash
            $normalCall={param([object[]]$J) Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Q4 operator' -Reason 'Q4 lock scenario' -SelectedItemIds ([string[]]$ids) -Jobs $J}
            $retryCall={param([object[]]$J) Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Q4 operator' -Reason 'Q4 retry scenario' -SelectedItemIds @($id3) -RetryOfReceiptHash $source -Jobs $J}
            $stateBytes0=[Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath));$filesBefore=DecisionCount

            # Q4-1. Running / WaitingForInput / Interrupted (and the not-yet-finished Queued / CancelRequested): both entries are refused with RestoreInProgress and leave no receipt file
            foreach($status in @('Running','WaitingForInput','Interrupted','Queued','CancelRequested')){
                $lockJobs=@($allJobs)+@((RestoreJob $status))
                $lock=Get-WsmWizardTargetRestoreLock $work $pair $lockJobs
                Check ($lock -and [string]$lock.Status -ceq $status) ('The restore lock did not recognise the '+$status+' parent.')
                Reject {& $normalCall $lockJobs} ('A decision receipt was created while the restore parent is '+$status+'.') '^RestoreInProgress:'
                Reject {& $retryCall $lockJobs} ('A retry receipt was created while the restore parent is '+$status+'.') '^RestoreInProgress:'
                # Q4 (main agent): the wizard choice entry of the Target role (Set-WsmWizardChoice / saveChoice) is locked by the same judgement.
                Reject {Set-WsmWizardChoice -Workspace $work -PairId $pair -Role Target -ItemId 'q4-any-item' -Selected $false -Reason 'q4' -ExpectedDecisionRevision 0 -ExpectedSelectionRevision 0 -Jobs $lockJobs} ('A Target wizard choice was accepted while the restore parent is '+$status+'.') '^RestoreInProgress:'
                Check ((DecisionCount) -eq $filesBefore) ('A refused receipt left a decision file behind ('+$status+').')
            }
            Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))) -ceq $stateBytes0) 'A refused receipt changed the operation state.'
            Reject {& $normalCall @((RestoreJob 'Running'))} 'The Running lock depends on other job records.' '^RestoreInProgress:'
            # the refusal text says why and how to continue
            $why='';try{& $normalCall (@($allJobs)+@((RestoreJob 'Running')))|Out-Null}catch{$why=[string]$_.Exception.Message}
            Check ($why -match '還原進行中，完成或取消後才能變更選擇') 'The refusal does not explain that the restore must finish or be cancelled first.'

            # Q4-2. the newest TargetRestore parent decides; another pair or workspace never locks this one
            $superseded=@($allJobs)+@((RestoreJob 'Running' -5),(RestoreJob 'ReviewRequired' 1))
            Check (-not (Get-WsmWizardTargetRestoreLock $work $pair $superseded)) 'An older Running parent locks selection although a newer parent finished.'
            $foreign=@($allJobs)+@((RestoreJob 'Running' 1 ([Guid]::NewGuid().ToString())),(RestoreJob 'Running' 1 $pair (Join-Path $Root 'other-workspace')))
            Check (-not (Get-WsmWizardTargetRestoreLock $work $pair $foreign)) 'A Running parent of another pair or workspace locks this pair.'
            Check (-not (Get-WsmWizardTargetRestoreLock $work $pair $allJobs)) 'The lock is set without any restore parent.'

            # Q4-3. the runtime projection carries the lock, disables the receipt and retry actions and gives the reason
            foreach($status in @('Running','WaitingForInput','Interrupted')){
                $lockJobs=@($allJobs)+@((RestoreJob $status))
                $runtimeLocked=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $lockJobs)
                $rl=$runtimeLocked.runtime.restoreLock
                Check ($rl.active -eq $true -and [string]$rl.status -ceq $status -and [string]$rl.reason -match '還原進行中，完成或取消後才能變更選擇') ('The runtime projection does not carry the lock for '+$status+'.')
                $receiptAction=@($runtimeLocked.actions|Where-Object {[string]$_.id -ceq 'CreateTargetDecisionReceipt'})
                Check ($receiptAction.Count -eq 1 -and $receiptAction[0].available -eq $false -and [string]$receiptAction[0].reason -match '還原進行中') ('The create-receipt action stays available while '+$status+'.')
                $retryAction=@($runtimeLocked.actions|Where-Object {[string]$_.id -ceq 'TargetRetryFailedItems'})
                if($status -ceq 'Running'){
                    Check ($runtimeLocked.runtime.retry.visible -eq $true -and $runtimeLocked.runtime.retry.eligible -eq $false -and [string]$runtimeLocked.runtime.retry.reasonCode -ceq 'RestoreInProgress' -and $retryAction.Count -eq 1 -and $retryAction[0].available -eq $false) 'The retry entry is not shown disabled with the lock reason while the restore Running.'
                }else{
                    Check ($retryAction.Count -eq 0 -or $retryAction[0].available -eq $false) ('The retry action is available while '+$status+'.')
                }
            }
            $runtimeFree=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@((RestoreJob 'ReviewRequired'))))
            $freeAction=@($runtimeFree.actions|Where-Object {[string]$_.id -ceq 'CreateTargetDecisionReceipt'})
            Check ($runtimeFree.runtime.restoreLock.active -eq $false -and $freeAction.Count -eq 1 -and $freeAction[0].available -eq $true) 'A finished restore still locks the selection in the projection.'

            # Q4-4. after the restore finished (Partial state, job Succeeded / ReviewRequired) receipts and the P8 retry work again
            $finished=@($allJobs)+@((RestoreJob 'ReviewRequired'))
            $retryReceipt=& $retryCall $finished
            Check ($retryReceipt.Status -ceq 'Succeeded' -and (Ids $retryReceipt.SelectedItemIds) -ceq $id3 -and (DecisionCount) -eq ($filesBefore+1)) 'The P8 retry receipt cannot be created after the restore finished.'
            $normalReceipt=& $normalCall (@($allJobs)+@((RestoreJob 'Succeeded')))
            Check ($normalReceipt.Status -ceq 'Succeeded' -and @($normalReceipt.SelectedItemIds).Count -eq 3 -and (DecisionCount) -eq ($filesBefore+2)) 'A normal decision receipt cannot be created after the restore finished.'
            # a new running restore locks again even though receipts exist now
            Reject {& $normalCall (@($allJobs)+@((RestoreJob 'Succeeded' -3),(RestoreJob 'Running' 2)))} 'A second restore that is Running did not lock the selection.' '^RestoreInProgress:'
            Check ((DecisionCount) -eq ($filesBefore+2)) 'A refused receipt after a restart left a decision file behind.'

        }finally{Set-Item -Path Function:\script:Invoke-WsmAssistiveFileScopeRestore -Value $script:p8OrigWriter}
        Write-Host ('PASS: selection lock during restore ('+$script:p8Checks+' checks): Running / WaitingForInput / Interrupted refuse both receipt paths with RestoreInProgress and leave no file, the projection disables the actions, finished restores unlock.')
    } $root $workRoot
} finally {
    foreach($path in @($root,$workRoot)){if($path -and [IO.Directory]::Exists($path)){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$path+': '+$_.Exception.Message)}}}
}
