#requires -Version 5.1
# P8: retry the failed items of a partially completed Target restore.
#   Part A: candidate calculation (pure function of the last parent's durable state, its bound receipt and the option set).
#   Part B: real wizard layer (sealed plan, verified package, comparison, receipt, preview, restore with one injected failed item):
#           the retry receipt holds only the candidates, the backend recomputes them and refuses anything else, nothing is written by creating the receipt.
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

        # ====================================== Part A: candidate calculation over plain durable inputs ======================================
        $mh=('a'*64);$rh=('b'*64)
        $pkg=[pscustomobject]@{ManifestHash=$mh;Package=[pscustomobject]@{Manifest=[pscustomobject]@{Generation=3}}}
        function Opt([string]$Id,[bool]$Restorable=$true,[string]$Code='',[string]$Reason=''){[pscustomobject]@{value=$Id;label=('item '+$Id);restorable=$Restorable;restorableCode=$Code;restorableReason=$Reason}}
        function Res([string]$Id,[string]$Status){[pscustomobject]@{ItemId=$Id;Status=$Status}}
        function Rec([string[]]$Selected,[string]$Owner='Target operator',[string[]]$Accepted=@(),[string]$Decision='RestoreNow'){[pscustomobject]@{SHA256=$rh;Path='C:\x\decision.json';Receipt=[pscustomobject]@{Decision=$Decision;Owner=$Owner;Reason='r';SelectedItemIds=$Selected;AcceptedUnpreparedItemIds=$Accepted}}}
        function St([string]$Stage,[object[]]$Results,[string[]]$Selected,[object[]]$Pending=@(),[string]$ReceiptHash=$rh,[long]$Generation=3,[string]$Manifest=$mh){[pscustomobject]@{Stage=$Stage;PendingOperations=@($Pending);RestoreAttempt=[pscustomobject]@{OperationId='attempt-1';ManifestHash=$Manifest;Generation=$Generation;DecisionReceiptHash=$ReceiptHash;SelectedItemIds=$Selected;ItemResults=@($Results);Status='Running'}}}
        function Core($State,$Decision,[object[]]$Options,$Pending=$null){Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkg -State $State -DecisionRecord $Decision -ItemOptions $Options -PendingRestore $Pending}
        function Ids($Value){(@($Value|Sort-Object) -join ',')}

        # A1. a mixed Partial result: success excluded, every non-success status included, unrestorable ones excluded with their code and reason
        $selected=@('a-ok','b-failed','c-deferred','d-credrej','e-needsrec','f-noresult','g-reboot','h-manual','i-novolume','j-blockedconflict','k-cancelled','l-partial')
        $results=@((Res 'a-ok' 'Succeeded'),(Res 'b-failed' 'Failed'),(Res 'c-deferred' 'Deferred'),(Res 'd-credrej' 'CredentialRejected'),(Res 'e-needsrec' 'NeedsReconciliation'),(Res 'g-reboot' 'RebootRequired'),(Res 'h-manual' 'ManualEvidenceRequired'),(Res 'i-novolume' 'Failed'),(Res 'j-blockedconflict' 'BlockedConflict'),(Res 'k-cancelled' 'Cancelled'),(Res 'l-partial' 'Partial'))
        $options=@((Opt 'a-ok'),(Opt 'b-failed'),(Opt 'c-deferred'),(Opt 'd-credrej'),(Opt 'e-needsrec'),(Opt 'f-noresult'),(Opt 'g-reboot'),(Opt 'h-manual' $false 'ManualWorkflow' 'manual only'),(Opt 'i-novolume' $false 'MissingVolume' 'volume Q: is missing'),(Opt 'j-blockedconflict' $false 'BlockedConflict' 'target conflict'),(Opt 'k-cancelled'),(Opt 'l-partial'))
        $state=St 'Partial' $results $selected
        $before=($state|ConvertTo-Json -Depth 20 -Compress)+($options|ConvertTo-Json -Depth 20 -Compress)
        $r=Core $state (Rec $selected 'Prior owner' @('b-failed','a-ok','h-manual')) $options
        Check ($r.Visible -and $r.Eligible -and $r.ReasonCode -ceq '') 'A partial result with restorable failures was not offered for retry.'
        Check ((Ids $r.CandidateItemIds) -ceq (Ids @('b-failed','c-deferred','d-credrej','e-needsrec','f-noresult','k-cancelled','l-partial'))) ('Candidates are not exactly the restorable non-successes: '+(Ids $r.CandidateItemIds))
        Check ((Ids $r.SucceededItemIds) -ceq (Ids @('a-ok','g-reboot')) -and @($r.CandidateItemIds|Where-Object {$_ -in @('a-ok','g-reboot')}).Count -eq 0) 'Succeeded (and reboot-pending applied) items were not kept out of the candidates.'
        Check ((Ids ($r.Excluded|ForEach-Object ItemId)) -ceq (Ids @('h-manual','i-novolume','j-blockedconflict'))) 'Unrestorable non-successes were not listed as excluded.'
        $ex=@{};foreach($row in @($r.Excluded)){$ex[[string]$row.ItemId]=$row}
        Check ($ex['i-novolume'].Code -ceq 'MissingVolume' -and $ex['i-novolume'].Reason -ceq 'volume Q: is missing' -and $ex['h-manual'].Code -ceq 'ManualWorkflow' -and $ex['j-blockedconflict'].Code -ceq 'BlockedConflict' -and $ex['i-novolume'].LastStatus -ceq 'Failed') 'Excluded rows lost their restorable code, reason or last status.'
        Check (@($r.CandidateItemIds|Where-Object {$ex.ContainsKey([string]$_)}).Count -eq 0) 'An unrestorable item is both a candidate and excluded.'
        Check ($r.SourceAttemptId -ceq 'attempt-1' -and $r.SourceReceiptHash -ceq $rh -and $r.SourceOwner -ceq 'Prior owner' -and $r.SourceStage -ceq 'Partial') 'Source attempt, source receipt hash, owner or stage were not reported.'
        Check ((Ids $r.PriorAcceptedUnpreparedItemIds) -ceq 'b-failed') 'Prior accepted-unprepared items were not intersected with the candidates.'
        Check ($r.SuggestedReason -match '7' -and $r.SuggestedReason.Contains($rh.Substring(0,12))) 'The suggested reason does not name the candidate count and the short source receipt hash.'
        Check (($state|ConvertTo-Json -Depth 20 -Compress)+($options|ConvertTo-Json -Depth 20 -Compress) -ceq $before) 'Candidate calculation mutated its inputs.'

        # A2. nothing to retry
        $allOk=@('a','b');$r=Core (St 'Succeeded' @((Res 'a' 'Succeeded'),(Res 'b' 'RebootRequired')) $allOk) (Rec $allOk) @((Opt 'a'),(Opt 'b'))
        Check (-not $r.Visible -and -not $r.Eligible -and $r.ReasonCode -ceq 'AllSucceeded' -and @($r.CandidateItemIds).Count -eq 0) 'A fully successful restore showed the retry entry.'
        $r=Core (St 'Succeeded' @((Res 'a' 'Succeeded')) $allOk) (Rec $allOk) @((Opt 'a'),(Opt 'b'))
        Check ($r.Visible -and $r.Eligible -and (Ids $r.CandidateItemIds) -ceq 'b') 'A Succeeded parent that still lacks a result for one selected item hid the retry entry.'
        # Partial only because unselected items are DeferredBySelection: every selected item succeeded, so this is not a failure to retry
        $r=Core (St 'Partial' @((Res 'a' 'Succeeded'),(Res 'b' 'Succeeded')) $allOk) (Rec $allOk) @((Opt 'a'),(Opt 'b'),(Opt 'c'))
        Check (-not $r.Visible -and $r.ReasonCode -ceq 'AllSucceeded') 'A Partial parent whose selected items all succeeded showed the retry entry.'
        $r=Core (St 'Partial' @((Res 'a' 'Failed'),(Res 'b' 'Failed')) $allOk) (Rec $allOk) @((Opt 'a' $false 'NoPayload' 'no payload'),(Opt 'b' $false 'External' 'external'))
        Check ($r.Visible -and -not $r.Eligible -and $r.ReasonCode -ceq 'NoRetryableItems' -and @($r.CandidateItemIds).Count -eq 0 -and @($r.Excluded).Count -eq 2 -and $r.Reason) 'An empty candidate set was not reported as visible, not retryable, with the excluded list.'
        $r=Core (St 'Partial' @((Res 'a' 'Failed')) @('a')) (Rec @('a')) @()
        Check ($r.Visible -and -not $r.Eligible -and @($r.Excluded).Count -eq 1 -and $r.Excluded[0].Code -ceq 'NotInApprovedPlan') 'An item that is no longer in the approved options was not excluded.'

        # A3. an unresolved pending intent makes the whole retry unavailable (the operator repairs first; nothing repairs automatically)
        $r=Core (St 'Partial' @((Res 'a' 'Succeeded'),(Res 'b' 'Succeeded')) $allOk @([pscustomobject]@{ItemId='b';Phase='AssistiveAdapterCreating'})) (Rec $allOk) @((Opt 'a'),(Opt 'b'))
        Check ($r.Visible -and -not $r.Eligible -and $r.ReasonCode -ceq 'PendingIntent') 'A Partial parent with a pending intent hid the repair-first notice although every result succeeded.'
        $r=Core (St 'Partial' @((Res 'a' 'Succeeded'),(Res 'b' 'Failed')) $allOk @([pscustomobject]@{ItemId='b';Phase='AssistiveAdapterCreating'})) (Rec $allOk) @((Opt 'a'),(Opt 'b'))
        Check ($r.Visible -and -not $r.Eligible -and $r.ReasonCode -ceq 'PendingIntent' -and @($r.CandidateItemIds).Count -eq 0 -and $r.Reason -match '修復') 'A pending intent did not make the retry unavailable with the repair-first reason.'

        # A4. states in which the entry must stay hidden
        $one=@('a','b');$opts=@((Opt 'a'),(Opt 'b'));$res=@((Res 'a' 'Succeeded'),(Res 'b' 'Failed'))
        foreach($stage in @('Running','WaitingForInput','Superseded','NotStarted')){$r=Core (St $stage $res $one) (Rec $one) $opts;Check (-not $r.Visible -and -not $r.Eligible -and @($r.CandidateItemIds).Count -eq 0) ('Retry was offered while the parent stage is '+$stage+'.')}
        $r=Core (St 'Partial' $res $one) (Rec $one) $opts ([pscustomobject]@{Status='WaitingForInput';Summary='x'})
        Check (-not $r.Visible -and $r.ReasonCode -ceq 'RestoreInProgress') 'Retry was offered while the newest TargetRestore parent waits for input.'
        $r=Core (St 'Partial' $res $one) (Rec $one) $opts ([pscustomobject]@{Status='Interrupted';Summary='x'})
        Check (-not $r.Visible) 'Retry was offered while the newest TargetRestore parent is interrupted.'
        $r=Core $null (Rec $one) $opts;Check (-not $r.Visible -and $r.ReasonCode -ceq 'NoRestoreAttempt') 'Retry was offered without any durable restore attempt.'
        $r=Core (St 'Partial' $res $one) $null $opts;Check (-not $r.Visible) 'Retry was offered without a decision receipt.'
        $r=Core (St 'Partial' $res $one @() ('c'*64)) (Rec $one) $opts;Check (-not $r.Visible -and $r.ReasonCode -ceq 'AttemptNotCurrent') 'Retry was offered for an attempt bound to a different (older) receipt.'
        $r=Core (St 'Partial' $res $one @() $rh 4) (Rec $one) $opts;Check (-not $r.Visible -and $r.ReasonCode -ceq 'AttemptNotCurrent') 'Retry was offered for an attempt of another package generation.'
        $r=Core (St 'Partial' $res $one @() $rh 3 ('d'*64)) (Rec $one) $opts;Check (-not $r.Visible -and $r.ReasonCode -ceq 'AttemptNotCurrent') 'Retry was offered for an attempt of another package manifest.'
        $r=Core (St 'Partial' $res @('a')) (Rec $one) $opts;Check (-not $r.Visible -and $r.ReasonCode -ceq 'AttemptNotCurrent') 'Retry was offered although the attempt selection differs from the receipt selection.'
        $r=Core (St 'Partial' $res $one) (Rec $one 'o' @() 'WaitForInstall') $opts;Check (-not $r.Visible) 'Retry was offered for a WaitForInstall receipt.'

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

            # B0. while the conflict remains, item 3 is a non-success that the shared restorable judgement refuses: visible, not retryable, excluded with the real code and reason
            $blocked=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($blocked.Visible -and -not $blocked.Eligible -and $blocked.ReasonCode -ceq 'NoRetryableItems' -and @($blocked.CandidateItemIds).Count -eq 0 -and (Ids $blocked.SucceededItemIds) -ceq (Ids @($id1,$id2)) -and @($blocked.Excluded).Count -eq 1 -and [string]$blocked.Excluded[0].ItemId -ceq $id3 -and [string]$blocked.Excluded[0].Code -ceq 'BlockedConflict' -and [string]$blocked.Excluded[0].Reason -match 'occupies' -and [string]$blocked.Excluded[0].LastStatus -ceq 'BlockedConflict') ('An item blocked by a real target conflict was not excluded with its code and reason: '+($blocked|ConvertTo-Json -Depth 6 -Compress))
            $restoreJob0=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restore1.AttemptOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($restore1)}
            $runtime0=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($restoreJob0)))
            $action0=@($runtime0.actions|Where-Object {[string]$_.id -ceq 'TargetRetryFailedItems'})
            Check ($runtime0.runtime.retry.visible -eq $true -and $runtime0.runtime.retry.eligible -eq $false -and @($runtime0.runtime.retry.excluded).Count -eq 1 -and [string]$runtime0.runtime.retry.excluded[0].code -ceq 'BlockedConflict' -and $action0.Count -eq 1 -and $action0[0].available -eq $false -and [string]$action0[0].reason) 'The runtime projection did not show a disabled retry with the excluded reason while the conflict remains.'
            Reject {Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'o' -Reason 'r' -SelectedItemIds @($id3) -RetryOfReceiptHash ([string]$blocked.SourceReceiptHash) -Jobs $allJobs} 'A retry receipt was created while no item qualifies.' 'not available'
            # the operator resolves the conflict (removes the occupying file); item 3 is restorable again
            [IO.File]::Delete($targets[2])

            # B1. candidates through the real wrapper (real state, real receipt, real options)
            $c=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($c.Visible -and $c.Eligible -and (Ids $c.CandidateItemIds) -ceq $id3 -and (Ids $c.SucceededItemIds) -ceq (Ids @($id1,$id2)) -and @($c.Excluded).Count -eq 0) ('Real candidates are not exactly the formerly blocked item: '+(Ids $c.CandidateItemIds))
            Check ($c.SourceReceiptHash -ceq [string]$receipt1.ReceiptHash -and $c.SourceAttemptId -ceq [string]$restore1.AttemptOperationId -and $c.SourceOwner -ceq 'First owner' -and $c.SourceStage -ceq 'Partial') 'Real candidates did not bind the source attempt, receipt hash, owner and stage.'
            $stateBytesBefore=[IO.File]::ReadAllBytes($statePath);$materialRoot=Get-WsmWizardTargetMaterialRoot $work $pair;$decisionFilesBefore=@(Get-ChildItem -LiteralPath $materialRoot -Filter 'decision-*.json'|ForEach-Object Name|Sort-Object)
            $null=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))) -ceq ([Convert]::ToBase64String($stateBytesBefore)) -and (@(Get-ChildItem -LiteralPath $materialRoot -Filter 'decision-*.json'|ForEach-Object Name|Sort-Object) -join ',') -ceq ($decisionFilesBefore -join ',')) 'Candidate calculation wrote the operation state or a receipt.'

            # B2. the runtime projection carries the same candidates, prefilled values and an available action (the receipt is the latest one and bound to the attempt)
            $restoreJob1=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restore1.AttemptOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($restore1)}
            $runtime=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($restoreJob1)))
            $rt=$runtime.runtime
            Check ([string]$runtime.status -ceq 'Partial' -and $rt.retry.visible -eq $true -and $rt.retry.eligible -eq $true -and (Ids $rt.retry.candidateItemIds) -ceq $id3 -and [int]$rt.retry.candidateCount -eq 1 -and [string]$rt.retry.sourceReceiptHash -ceq [string]$receipt1.ReceiptHash -and [string]$rt.retry.sourceReceiptShort -ceq ([string]$receipt1.ReceiptHash).Substring(0,12)) 'The runtime projection did not expose the retry candidates and the source receipt.'
            Check ([string]$rt.retry.defaultOwner -ceq 'First owner' -and [string]$rt.retry.defaultReason -match '1' -and ([string]$rt.retry.defaultReason).Contains(([string]$receipt1.ReceiptHash).Substring(0,12))) 'The runtime projection did not prefill the prior owner and the suggested reason.'
            $action=@($runtime.actions|Where-Object {[string]$_.id -ceq 'TargetRetryFailedItems'})
            Check ($action.Count -eq 1 -and $action[0].available -eq $true -and [string]$action[0].defaults.Decision -ceq 'RestoreNow' -and [string]$action[0].defaults.RetryOfReceiptHash -ceq [string]$receipt1.ReceiptHash -and (Ids $action[0].defaults.SelectedItemIds) -ceq $id3 -and (@($action[0].missing) -join ',') -ceq 'Owner,Reason') 'The runtime retry action is missing, unavailable, or does not leave Owner and Reason explicit.'
            Check (@($runtime.actions|Where-Object {[string]$_.id -ceq 'TargetRestore'}).Count -eq 0) 'A restore action is offered next to the retry action before a new receipt exists.'
            $noJobRuntime=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $allJobs
            Check ($noJobRuntime.runtime.retry.visible -eq $true) 'The retry entry depends on a restore job record instead of the durable attempt.'
            $contract=(Get-WsmWizardRuntimeActionContracts)['TargetRetryFailedItems']
            Check ($contract -and $contract.Command -ceq 'Create-WsmWizardTargetDecisionReceipt' -and @($contract.Defaults) -cnotcontains 'Owner' -and @($contract.Defaults) -cnotcontains 'Reason' -and @($contract.ExplicitFields) -ccontains 'Owner' -and @($contract.ExplicitFields) -ccontains 'Reason') 'The retry action contract does not keep Owner and Reason explicit.'

            # B3. refusals: owner / reason, malformed or wrong source hash, different item ids, a wrong decision
            $retryCall={param([string]$Owner,[string]$Reason,[string[]]$Selected,[string]$Source,[string]$Decision='RestoreNow',[string[]]$Accepted=@()) Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision $Decision -Owner $Owner -Reason $Reason -SelectedItemIds $Selected -AcceptedUnpreparedItemIds $Accepted -RetryOfReceiptHash $Source -Jobs $allJobs}
            $source=[string]$c.SourceReceiptHash
            $decisionFiles0=@(Get-ChildItem -LiteralPath $materialRoot -Filter 'decision-*.json').Count
            Reject {& $retryCall '' 'reason' @($id3) $source} 'A retry receipt was created without an owner.'
            Reject {& $retryCall 'owner' '   ' @($id3) $source} 'A retry receipt was created without a reason.'
            Reject {& $retryCall 'owner' 'reason' @($id3) ('0'*64)} 'A retry receipt was created for a source receipt that is not the latest restore receipt.' 'no longer the receipt'
            Reject {& $retryCall 'owner' 'reason' @($id3) 'not-a-hash'} 'A retry receipt accepted a malformed source hash.'
            Reject {& $retryCall 'owner' 'reason' @($id1,$id3) $source} 'The backend trusted a front-end item list that also holds an already succeeded item.' 'differ from the items that currently qualify'
            Reject {& $retryCall 'owner' 'reason' @($id1) $source} 'The backend trusted a front-end item list that holds only a succeeded item.' 'differ from the items that currently qualify'
            Reject {& $retryCall 'owner' 'reason' @($id1,$id2,$id3) $source} 'The backend trusted a front-end list that repeats the whole earlier selection.' 'differ from the items that currently qualify'
            Reject {& $retryCall 'owner' 'reason' @([Guid]::NewGuid().ToString()) $source} 'The backend accepted an item that is not in the sealed plan.'
            Reject {& $retryCall 'owner' 'reason' @($id3) $source 'WaitForInstall'} 'A retry receipt accepted the WaitForInstall decision.' 'RestoreNow'
            Reject {& $retryCall 'owner' 'reason' @($id3) $source 'RestoreNow' @($id3)} 'The backend trusted a front-end accepted-unprepared list that no core dependency issue backs.'
            Check (@(Get-ChildItem -LiteralPath $materialRoot -Filter 'decision-*.json').Count -eq $decisionFiles0) 'A refused retry still wrote a decision receipt.'

            # B4. a stale comparison (a newer comparison material bound to another Target snapshot) is refused by the existing revision checks
            $seqCtx=Assert-WsmWizardTargetRole $work $pair
            $staleSaved=Save-WsmWizardTargetComparisonMaterial -Workspace $work -PairId $pair -Ctx $seqCtx -Snapshot ([pscustomobject]@{SHA256=('9'*64)}) -Comparison ([pscustomobject]@{Revision=10;SourceSnapshotHash=$sourceHash;TargetSnapshotHash=('9'*64);SelectionRevision=$selectionRevision;Rows=@();ManualPreparation=@()}) -SelectionRevision $selectionRevision -ComparisonRevision 10 -SourceSnapshotHash $sourceHash -Provenance ManagerImport -ImportedFromHash ''
            Reject {& $retryCall 'owner' 'reason' @($id3) $source} 'A retry receipt was created over a comparison that no longer matches the current Target inventory.' 'comparison'
            [IO.File]::Delete($staleSaved.Path)
            Check ((Get-WsmWizardTargetComparisonRecord $work $pair $planHash).Comparison.Revision -eq 9) 'The stale comparison fixture was not removed.'

            # B5. the retry receipt: only the candidates, owner and reason from the operator, RestoreNow, and nothing is written by creating it
            $stateBytesBefore=[IO.File]::ReadAllBytes($statePath);$callsBefore=@{};foreach($k in $script:p8Calls.Keys){$callsBefore[$k]=$script:p8Calls[$k]}
            $retryReceipt=& $retryCall 'Retry operator' 'Retry the failed item after fixing the cause' @($id3) $source
            Check ($retryReceipt.Status -ceq 'Succeeded' -and $retryReceipt.Decision -ceq 'RestoreNow' -and (Ids $retryReceipt.SelectedItemIds) -ceq $id3 -and @($retryReceipt.SelectedItemIds).Count -eq 1 -and $retryReceipt.ReceiptHash -cne $receipt1.ReceiptHash) 'The retry receipt does not select exactly the failed item with RestoreNow.'
            $stored=Read-WsmTrustedJson $retryReceipt.ReceiptPath $retryReceipt.ReceiptHash
            Check ((Assert-WsmAssistiveContract $stored TargetDecisionReceipt) -and [string]$stored.Owner -ceq 'Retry operator' -and [string]$stored.Reason -ceq 'Retry the failed item after fixing the cause' -and @($stored.SelectedItemIds).Count -eq 1 -and [string]$stored.SelectedItemIds[0] -ceq $id3) 'The stored retry receipt lost the operator-provided owner and reason or the exact selection.'
            Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))) -ceq ([Convert]::ToBase64String($stateBytesBefore))) 'Creating the retry receipt changed the operation state (a restore or a repair started).'
            Check ((($script:p8Calls.Keys|Sort-Object|ForEach-Object {$_+'='+$script:p8Calls[$_]}) -join ',') -ceq (($callsBefore.Keys|Sort-Object|ForEach-Object {$_+'='+$callsBefore[$_]}) -join ',')) 'Creating the retry receipt called a file writer.'
            Check (-not [IO.Directory]::Exists($targets[2]) -and -not [IO.File]::Exists($targets[2])) 'Creating the retry receipt wrote the failed item to the target.'
            $after=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check (-not $after.Visible -and $after.ReasonCode -ceq 'AttemptNotCurrent') 'The retry entry stays visible although a newer receipt exists.'
            Reject {& $retryCall 'Retry operator' 'second click' @($id3) $source} 'The same retry could be created a second time from the old source receipt.'
            $runtimeAfter=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($restoreJob1))
            Check ($runtimeAfter.runtime.retry.visible -eq $false -and @($runtimeAfter.actions|Where-Object {[string]$_.id -ceq 'TargetRetryFailedItems'}).Count -eq 0) 'The runtime projection still offers the retry after the new receipt exists.'

            # B6. back to the normal preview and an explicit restore: only the failed item is written, the earlier results stay
            $preview2=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($preview2.Status -ceq 'Previewed' -and (Ids $preview2.SelectedItemIds) -ceq $id3 -and $preview2.PreviewHash -cne $preview1.PreviewHash) 'The preview after the retry receipt does not cover exactly the failed item.'
            $restore2=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview2.PreviewHash) -Jobs $allJobs
            Check (@($restore2.Deferred|Where-Object {[string]$_.Action -cne 'DeferredBySelection'}).Count -eq 0 -and @($restore2.ItemResults).Count -eq 1 -and [string]$restore2.ItemResults[0].ItemId -ceq $id3 -and [string]$restore2.ItemResults[0].Status -ceq 'Succeeded' -and $restore2.AttemptOperationId -cne $restore1.AttemptOperationId) ('The retry restore did not succeed for exactly the failed item in a new parent. '+$restore2.Status+' items='+(@($restore2.ItemResults|ForEach-Object {([string]$_.ItemId).Substring(0,6)+'='+[string]$_.Status+' '+[string]$_.Error}) -join ';')+' newParent='+($restore2.AttemptOperationId -cne $restore1.AttemptOperationId))
            Check ($script:p8Calls[$id1] -eq $callsAfterRestore[$id1] -and $script:p8Calls[$id2] -eq $callsAfterRestore[$id2] -and $script:p8Calls[$id3] -eq $callsAfterRestore[$id3]+1) 'The retry restore re-wrote an already succeeded item (writer call counts).'
            $state2=Read-WsmJson $statePath
            Check ((@($state2.Items|Where-Object {[string]$_.ItemId -in @($id1,$id2)}|ForEach-Object {$_|ConvertTo-Json -Depth 20 -Compress}) -join "`n") -ceq ($record1Before -join "`n")) 'The ownership records of the already succeeded items changed.'
            Check ((@($targets[0],$targets[1]|ForEach-Object {Sha (Join-Path $_ 'state.bin')}) -join ',') -ceq ($hashes1 -join ',') -and [IO.File]::Exists((Join-Path $targets[2] 'state.bin')) -and (Sha (Join-Path $targets[2] 'state.bin')) -ceq (Sha (Join-Path $scopes[2] 'state.bin'))) 'The bytes of the succeeded items changed, or the retried item does not hold its source bytes.'
            $final=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check (-not $final.Visible -and $final.ReasonCode -ceq 'AllSucceeded') 'After a fully successful retry the retry entry is still shown.'
        }finally{Set-Item -Path Function:\script:Invoke-WsmAssistiveFileScopeRestore -Value $script:p8OrigWriter}
        Write-Host ('PASS: retry failed items ('+$script:p8Checks+' checks): candidates exclude succeeded and unrestorable items with reasons, a pending intent or running restore blocks, the backend recomputes and refuses other item ids / owners / reasons / stale sources, creating the receipt writes nothing, the retry restore writes only the failed item.')
    } $root $workRoot
} finally {
    foreach($path in @($root,$workRoot)){if($path -and [IO.Directory]::Exists($path)){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$path+': '+$_.Exception.Message)}}}
}
