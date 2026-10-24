#requires -Version 5.1
# Q1 (R7-08): re-check after a restore. Installing software, a reboot or a permission change can rewrite what was restored; the restore result must not keep saying "success".
# The re-check is read-only: it compares the items of the latest restore that ended Succeeded with their durable ownership/readback records and writes one new
# content-addressed record under <pair>\rechecks. Drifted items drop from Succeeded to NeedsRecheck in the projection (with the reason), the old ItemResults and the
# journal stay as they were, nothing is overwritten, and a re-restore still needs an explicit selection and still meets BlockedConflict / ownership rules.
#   Part A: pure inputs: retry candidates, the typed readback judgement (no readback / readback failure is never a match), adopted-existing drift, the projection guards, entries.
#   Part B: end to end with the REAL file-scope writer (only a write-phase exception is injected) and typed MachineEnvironment doubles whose readback can drift:
#           restore -> clean re-check (nothing drifts) -> simulated install (content of one file, ACL of another, one setting, an adopted file, an unreadable setting) ->
#           re-check -> NeedsRecheck with reasons, the rest stays success, bytes/ACL/state/journal/ItemResults untouched -> projection, history text, new-snapshot hint,
#           P8 candidates -> CLI output -> an explicit re-restore of a drifted item is still refused (BlockedConflict) and overwrites nothing.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-q1-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$workRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsmq1w-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
$srcDir=Join-Path $PSScriptRoot '..\src'
try {
    & $module {
        param($Root,$WorkRoot,$SrcDir)
        $script:q1Checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:q1Checks++}
        function Reject([scriptblock]$action,[string]$message,[string]$pattern=''){$rejected=$false;$text='';try{& $action|Out-Null}catch{$rejected=$true;$text=[string]$_.Exception.Message};Check $rejected $message;if($pattern){Check ($text -match $pattern) ($message+' (wrong rejection: '+$text+')')}}
        function SaveJson($data,[string]$path){[IO.File]::WriteAllText($path,($data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$path}
        function Sha([string]$path){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Ids($Value){(@($Value|Sort-Object) -join ',')}

        # ====================================== Part A: pure inputs ======================================
        # ---- A1. retry candidates: a NeedsRecheck item is not a failure
        $mh=('a'*64);$rh=('b'*64)
        $pkg=[pscustomobject]@{ManifestHash=$mh;Package=[pscustomobject]@{Manifest=[pscustomobject]@{Generation=3}}}
        function Opt([string]$Id,[bool]$Restorable=$true){[pscustomobject]@{value=$Id;label=('item '+$Id);restorable=$Restorable;restorableCode='';restorableReason=''}}
        function Res([string]$Id,[string]$Status){[pscustomobject]@{ItemId=$Id;Status=$Status}}
        $dec=[pscustomobject]@{SHA256=$rh;Path='C:\x\decision.json';Receipt=[pscustomobject]@{Decision='RestoreNow';Owner='Target operator';Reason='r';SelectedItemIds=@('a','b','c');AcceptedUnpreparedItemIds=@()}}
        function St([string]$Stage,[object[]]$Results,[string[]]$Selected){[pscustomobject]@{Stage=$Stage;PendingOperations=@();RestoreAttempt=[pscustomobject]@{OperationId='attempt-1';ManifestHash=$mh;Generation=3;DecisionReceiptHash=$rh;SelectedItemIds=$Selected;ItemResults=@($Results);Status='Running'}}}
        $recheckA=@([pscustomobject]@{itemId='a';status='NeedsRecheck'},[pscustomobject]@{itemId='b';status='Succeeded'})
        $rA=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkg -State (St 'Partial' @((Res 'a' 'Succeeded'),(Res 'b' 'Succeeded'),(Res 'c' 'Failed')) @('a','b','c')) -DecisionRecord $dec -ItemOptions @((Opt 'a'),(Opt 'b'),(Opt 'c')) -RecheckItems $recheckA
        Check ($rA.Visible -and $rA.Eligible -and (Ids $rA.CandidateItemIds) -ceq 'c') ('A1: the retry candidates must hold only the failed item, got '+(Ids $rA.CandidateItemIds))
        Check ((Ids $rA.NeedsRecheckItemIds) -ceq 'a' -and (Ids $rA.SucceededItemIds) -ceq 'a,b' -and (Ids $rA.NotSucceededItemIds) -ceq 'c') 'A1: a NeedsRecheck item must stay on the succeeded side (history kept), be listed as NeedsRecheck, and never be counted as not succeeded.'
        Check (@($rA.Excluded|Where-Object {[string]$_.ItemId -ceq 'a'}).Count -eq 0) 'A1: a NeedsRecheck item must not appear in the excluded (cannot retry) list either.'
        $dec2=[pscustomobject]@{SHA256=$rh;Path='C:\x\decision.json';Receipt=[pscustomobject]@{Decision='RestoreNow';Owner='o';Reason='r';SelectedItemIds=@('a','b');AcceptedUnpreparedItemIds=@()}}
        $rB=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkg -State (St 'Succeeded' @((Res 'a' 'Succeeded'),(Res 'b' 'Succeeded')) @('a','b')) -DecisionRecord $dec2 -ItemOptions @((Opt 'a'),(Opt 'b')) -RecheckItems $recheckA
        Check (-not $rB.Visible -and -not $rB.Eligible -and $rB.ReasonCode -ceq 'AllSucceeded' -and @($rB.CandidateItemIds).Count -eq 0 -and (Ids $rB.NeedsRecheckItemIds) -ceq 'a') 'A1: when everything succeeded, a NeedsRecheck item must not make the retry appear.'
        $rC=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkg -State (St 'Succeeded' @((Res 'a' 'Succeeded'),(Res 'b' 'Succeeded')) @('a','b')) -DecisionRecord $dec2 -ItemOptions @((Opt 'a'),(Opt 'b'))
        Check (-not $rC.Visible -and @($rC.NeedsRecheckItemIds).Count -eq 0) 'A1: without recheck items the old P8 behaviour must be unchanged.'

        # ---- A2. typed readback judgement: only a real readback can match
        function TypedItem([string]$Adapter){[pscustomobject]@{ItemId=('t-'+$Adapter);Name=('typed '+$Adapter);MigrationSpec=[pscustomobject]@{Adapter=$Adapter;Desired=[pscustomobject]@{Name='X';Value='1'}}}}
        $emptyState=[pscustomobject]@{Items=@()}
        Check (@(Get-WsmAssistiveRecheckAdapters) -cnotcontains 'ManualWorkflow' -and @(Get-WsmAssistiveRecheckAdapters) -ccontains 'MachineEnvironment' -and @(Get-WsmAssistiveRecheckAdapters) -ccontains 'IISSite' -and @(Get-WsmAssistiveRecheckAdapters) -ccontains 'ScheduledTask') 'A2: the readback-capable adapter list is wrong (ManualWorkflow must be absent).'
        $manual=Test-WsmAssistiveRecheckTyped (TypedItem 'ManualWorkflow') ([pscustomobject]@{Status='Succeeded'}) $emptyState
        Check (@($manual.Reasons).Count -eq 1 -and [string]$manual.Reasons[0].Code -ceq 'NoReadback' -and [string]$manual.Reasons[0].Kind -ceq 'Unverifiable' -and [string]$manual.Reasons[0].Text -match '無法自動核對') 'A2: an adapter without readback must be 無法自動核對 (NoReadback), never a match.'
        $unknown=Test-WsmAssistiveRecheckTyped (TypedItem 'SomethingNew') ([pscustomobject]@{Status='Succeeded'}) $emptyState
        Check ([string]$unknown.Reasons[0].Code -ceq 'NoReadback') 'A2: an unknown adapter must be NoReadback.'
        $deferred=Test-WsmAssistiveRecheckTyped (TypedItem 'MachineEnvironment') ([pscustomobject]@{Status='Succeeded';SettingTransitionDeferred=$true}) $emptyState
        Check ([string]$deferred.Reasons[0].Code -ceq 'DeferredSetting' -and [string]$deferred.Reasons[0].Kind -ceq 'Unverifiable') 'A2: a setting that is only applied at cutover cannot be rechecked now.'
        $script:q1OrigConfig=(Get-Command Test-WsmAdapterConfiguration -CommandType Function).ScriptBlock
        try{
            $script:q1ConfigMode='Pass';$script:q1ConfigPhases=@()
            Set-Item Function:\Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,[object[]]$OwnedReceipts=@())$script:q1ConfigPhases+=@([string]$Phase);switch($script:q1ConfigMode){'Pass'{[pscustomobject]@{Passed=$true;Problems=@();Actual=$null}}'FinalOnly'{[pscustomobject]@{Passed=($Phase -ceq 'Final');Problems=@('staged differs');Actual=$null}}'Drift'{[pscustomobject]@{Passed=$false;Problems=@('Environment value mismatch');Actual=$null}}'Throw'{throw 'readback unavailable'}}}
            $okTyped=Test-WsmAssistiveRecheckTyped (TypedItem 'MachineEnvironment') ([pscustomobject]@{Status='Succeeded'}) $emptyState
            Check (@($okTyped.Reasons).Count -eq 0) 'A2: a passing readback must produce no reason.'
            $script:q1ConfigMode='FinalOnly';$script:q1ConfigPhases=@()
            $finalTyped=Test-WsmAssistiveRecheckTyped (TypedItem 'MachineEnvironment') ([pscustomobject]@{Status='Succeeded'}) $emptyState
            Check (@($finalTyped.Reasons).Count -eq 0 -and ($script:q1ConfigPhases -join ',') -ceq 'Staged,Final') 'A2: Staged or Final passing is a match (same rule as the cutover check).'
            $script:q1ConfigMode='Drift'
            $driftTyped=Test-WsmAssistiveRecheckTyped (TypedItem 'MachineEnvironment') ([pscustomobject]@{Status='Succeeded'}) $emptyState
            Check (@($driftTyped.Reasons).Count -eq 1 -and [string]$driftTyped.Reasons[0].Code -ceq 'Setting' -and [string]$driftTyped.Reasons[0].Kind -ceq 'Drift' -and [string]$driftTyped.Reasons[0].Detail -match 'Environment value mismatch') 'A2: a failing readback must be a Setting drift with the adapter problem as detail.'
            $script:q1ConfigMode='Throw'
            $throwTyped=Test-WsmAssistiveRecheckTyped (TypedItem 'MachineEnvironment') ([pscustomobject]@{Status='Succeeded'}) $emptyState
            Check (@($throwTyped.Reasons).Count -eq 1 -and [string]$throwTyped.Reasons[0].Code -ceq 'ReadbackFailed' -and [string]$throwTyped.Reasons[0].Kind -ceq 'Unverifiable') 'A2: a readback that throws must be 無法自動核對 (ReadbackFailed), not a match and not a drift.'
        }finally{Set-Item Function:\Test-WsmAdapterConfiguration -Value $script:q1OrigConfig}

        # ---- A3. FileScope judgement on synthetic rows: adopted existing drift is only reported; no ownership means unverifiable
        $fileItem=[pscustomobject]@{ItemId='f1';Name='files';MigrationSpec=[pscustomobject]@{Adapter='FileScope';AclControlPolicy='Exact'}}
        $adoptedOwned=[pscustomobject]@{RelativePath='x.bin';TargetPath='C:\nope\x.bin';SHA256=('1'*64);MetadataHash=('2'*64);Ownership='AdoptedExisting'}
        $plainOwned=[pscustomobject]@{RelativePath='y.bin';TargetPath='C:\nope\y.bin';SHA256=('3'*64);MetadataHash=('4'*64)}
        $adoptedRow=[pscustomobject]@{ItemId='f1';RelativePath='x.bin';Directory=$false;PlacementStatus='OwnedFileDrift'}
        $plainRow=[pscustomobject]@{ItemId='f1';RelativePath='y.bin';Directory=$false;PlacementStatus='OwnedFileDrift'}
        $fsA=Test-WsmAssistiveRecheckFileScope $fileItem ([pscustomobject]@{ItemId='f1';OwnedFiles=@($adoptedOwned,$plainOwned);OwnedDirectories=@()}) @($adoptedRow,$plainRow) @() @{}
        $byFile=@{};foreach($reason in @($fsA.Reasons)){$byFile[[string]$reason.RelativePath]=$reason}
        Check ([string]$byFile['x.bin'].Code -ceq 'AdoptedExistingDrift' -and $byFile['x.bin'].ReportOnly -eq $true -and [string]$byFile['x.bin'].Kind -ceq 'Drift') 'A3: a drifted adopted existing file must be reported as AdoptedExistingDrift, ReportOnly.'
        Check ([string]$byFile['y.bin'].Code -ceq 'Content' -and $byFile['y.bin'].ReportOnly -eq $false) 'A3: a drifted tool-owned file is a Content drift, not report-only.'
        $fsNonC=Test-WsmAssistiveRecheckFileScope $fileItem ([pscustomobject]@{ItemId='f1';OwnershipChannel='NonC';OwnedFiles=@();OwnedDirectories=@()}) @() @() @{}
        Check (@($fsNonC.Reasons).Count -eq 1 -and [string]$fsNonC.Reasons[0].Code -ceq 'NonCChannel' -and [string]$fsNonC.Reasons[0].Kind -ceq 'Unverifiable') 'A3: a NonC channel result has no local readback and must be 無法自動核對.'
        $fsNone=Test-WsmAssistiveRecheckFileScope $fileItem $null @() @() @{}
        Check (@($fsNone.Reasons).Count -eq 1 -and [string]$fsNone.Reasons[0].Code -ceq 'NoOwnership' -and [string]$fsNone.Reasons[0].Kind -ceq 'Unverifiable') 'A3: no ownership record must be 無法自動核對, not a match.'
        $fsMissingRow=Test-WsmAssistiveRecheckFileScope $fileItem ([pscustomobject]@{ItemId='f1';OwnedFiles=@($plainOwned);OwnedDirectories=@()}) @() @() @{}
        Check ([string]$fsMissingRow.Reasons[0].Code -ceq 'NoOwnership' -and [string]$fsMissingRow.Reasons[0].Kind -ceq 'Unverifiable') 'A3: a file without a placement row must be unverifiable.'
        $placementCases=[ordered]@{CanPlace=@('Missing','Drift');BlockedConflict=@('Topology','Drift');UnknownPermission=@('Unreadable','Unverifiable');Surprise=@('NoOwnership','Unverifiable')}
        foreach($status in $placementCases.Keys){
            $caseRow=[pscustomobject]@{ItemId='f1';RelativePath='y.bin';Directory=$false;PlacementStatus=$status}
            $caseResult=Test-WsmAssistiveRecheckFileScope $fileItem ([pscustomobject]@{ItemId='f1';OwnedFiles=@($plainOwned);OwnedDirectories=@()}) @($caseRow) @() @{}
            Check ([string]$caseResult.Reasons[0].Code -ceq $placementCases[$status][0] -and [string]$caseResult.Reasons[0].Kind -ceq $placementCases[$status][1]) ('A3: placement '+$status+' was not judged '+$placementCases[$status][0]+'/'+$placementCases[$status][1])
        }

        # ---- A4. the runtime projection guards (pure inputs; nothing native is read)
        $guardPackage=[pscustomobject]@{ManifestHash=$mh;Package=[pscustomobject]@{Manifest=[pscustomobject]@{Generation=3}}}
        function GuardState([string]$Stage,[object[]]$Results){[pscustomobject]@{Stage=$Stage;PendingOperations=@();RestoreAttempt=[pscustomobject]@{OperationId='attempt-1';ManifestHash=$mh;Generation=3;TargetSnapshotHash=('c'*64);ItemResults=@($Results)}}}
        $g0=Get-WsmWizardRuntimeRecheck 'C:\nope' 'pair' $guardPackage $null $null
        Check (-not $g0.visible -and -not $g0.available -and $g0.reasonCode -ceq 'NoRestoreAttempt') 'A4: no restore attempt: nothing to recheck.'
        $g1=Get-WsmWizardRuntimeRecheck 'C:\nope' 'pair' $guardPackage (GuardState 'Running' @((Res 'a' 'Succeeded'))) $null
        Check (-not $g1.visible -and $g1.reasonCode -ceq 'RestoreNotFinished') 'A4: a restore that has not finished cannot be rechecked.'
        $g2=Get-WsmWizardRuntimeRecheck 'C:\nope' 'pair' $guardPackage (GuardState 'Partial' @((Res 'a' 'Failed'))) $null
        Check (-not $g2.visible -and $g2.reasonCode -ceq 'NothingToCheck') 'A4: no succeeded item: nothing to recheck.'
        $otherGeneration=[pscustomobject]@{ManifestHash=$mh;Package=[pscustomobject]@{Manifest=[pscustomobject]@{Generation=4}}}
        $g3=Get-WsmWizardRuntimeRecheck 'C:\nope' 'pair' $otherGeneration (GuardState 'Succeeded' @((Res 'a' 'Succeeded'))) $null
        Check (-not $g3.visible -and $g3.reasonCode -ceq 'AttemptNotCurrent') 'A4: an attempt of another generation is not the current result.'
        Check ((ConvertTo-WsmWizardRecheckProjectedStatus 'NeedsRecheck') -ceq 'NeedsRecheck' -and (ConvertTo-WsmWizardRecheckProjectedStatus 'Unverifiable') -ceq 'Unverifiable' -and (ConvertTo-WsmWizardRecheckProjectedStatus 'Matched') -ceq 'Succeeded') 'A4: the projected status mapping is wrong.'

        # ---- A5. entrances: HTML action, runtime contract, text console, CLI menu, console.js
        $actionMap=Get-WsmHtmlActionMap
        Check ($actionMap.Contains('TargetRecheck') -and [string]$actionMap['TargetRecheck'] -ceq 'Invoke-WsmWizardTargetRecheck') 'A5: the HTML action map has no TargetRecheck -> Invoke-WsmWizardTargetRecheck.'
        Check ((Get-WsmTextActionGroup 'TargetRecheck') -ceq 'Target' -and (Get-WsmTextActionLabel 'TargetRecheck') -match '重新核對') 'A5: the text console has no Target group / label for TargetRecheck.'
        $contract=(Get-WsmWizardRuntimeActionContracts).TargetRecheck
        Check ([string]$contract.Command -ceq 'Invoke-WsmWizardTargetRecheck' -and @($contract.RequiredFields).Count -eq 2 -and @($contract.ExplicitFields).Count -eq 0) 'A5: the runtime action contract needs only Workspace and PairId (no operator input, no explicit fields).'
        $recheckCommand=Get-Command Invoke-WsmWizardTargetRecheck -CommandType Function
        Check ($recheckCommand.Parameters.ContainsKey('Workspace') -and $recheckCommand.Parameters.ContainsKey('PairId') -and $recheckCommand.Parameters.ContainsKey('Jobs')) 'A5: the entrance does not take Workspace/PairId/Jobs.'
        $wizardCli=[IO.File]::ReadAllText((Join-Path $SrcDir 'MigrationWizard.ps1'),[Text.Encoding]::UTF8)
        Check ($wizardCli.Contains('16 還原後重新核對（唯讀）') -and $wizardCli -match "'16' \{Show-WsmTargetRestoreRecheckResult \(Invoke-WsmTargetRestoreRecheck") 'A5: the CLI Target menu has no 16 還原後重新核對 -> Invoke-WsmTargetRestoreRecheck.'
        $consoleJs=[IO.File]::ReadAllText((Join-Path $SrcDir 'ui\console.js'),[Text.Encoding]::UTF8)
        Check ($consoleJs.Contains("TargetRecheck:'重新核對'") -or $consoleJs -match "TargetRecheck\s*:\s*'重新核對'") 'A5: the HTML label of TargetRecheck is not 重新核對.'

        # ====================================== shared fixture: a real sealed package (four FileScope items + three typed settings) ======================================
        $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='Target fixture';OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        function script:Get-WsmMachineIdentity {$script:wsmQ1Target}
        $script:wsmQ1Target=$target
        $work=$WorkRoot;$enrollment=Initialize-WsmOutputWorkspace -WorkRoot $work -Role Target;$target|Add-Member NoteProperty HostId ([string]$enrollment.Profile.HostId) -Force
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='Source fixture';OS='Fixture Windows Server';Version='10.0'}
        $defs=@(
            [pscustomobject]@{Key='docs';Files=@('a.bin','b.bin','c.bin')},
            [pscustomobject]@{Key='plain';Files=@('p1.bin')},
            [pscustomobject]@{Key='adopt';Files=@('x1.bin')},
            [pscustomobject]@{Key='victim';Files=@('v1.bin')}
        )
        $items=@();$scopes=@{};$targets=@{};$ids=@{}
        function CommonSpec([string]$Adapter){[ordered]@{Adapter=$Adapter;Product='Fixture workload';Procedure='Owner independently verifies the restored item';Artifacts=@();BusinessChecks=@('Owner confirms the restored item');Owner='Source owner';Evidence='fixture approval evidence'}}
        foreach($def in $defs){
            $it=New-WsmItem $source.HostId Storage DataRoot ('Q1 workload '+$def.Key) ('q1-source-'+$def.Key) @{Path=('C:\fixture\q1-'+$def.Key)}
            $it|Add-Member NoteProperty Decision Include -Force;$it|Add-Member NoteProperty Reason 'Source owner reviewed fixture scope' -Force;$it|Add-Member NoteProperty Owner 'Source owner' -Force;$it|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
            $scope=Join-Path $Root ('source-'+$def.Key);[void][IO.Directory]::CreateDirectory($scope)
            foreach($name in $def.Files){[IO.File]::WriteAllBytes((Join-Path $scope $name),[Text.Encoding]::UTF8.GetBytes('Q1 payload '+$def.Key+' '+$name+' '+[Guid]::NewGuid().ToString('N')))}
            $targetRoot=Join-Path $Root ('restored-'+$def.Key)
            $specHash=CommonSpec 'FileScope';foreach($kv in ([ordered]@{SourcePath=$scope;TargetPath=$targetRoot;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';TransferChannel='C';ContentSelection='WholeScope';ConfigFiles=@();ConfigOverrides=@()}).GetEnumerator()){$specHash[$kv.Key]=$kv.Value}
            $it|Add-Member NoteProperty MigrationSpec ([pscustomobject]$specHash) -Force;$items+=@($it);$scopes[$def.Key]=$scope;$targets[$def.Key]=$targetRoot;$ids[$def.Key]=[string]$it.ItemId
        }
        foreach($envKey in @('env','env2','env3')){
            $envName=('WSM_Q1_'+$envKey.ToUpperInvariant())
            $it=New-WsmItem $source.HostId System EnvironmentVariable ('Q1 setting '+$envKey) ('q1-setting-'+$envKey) @{Name=$envName}
            $it|Add-Member NoteProperty Decision Include -Force;$it|Add-Member NoteProperty Reason 'Source owner reviewed fixture setting' -Force;$it|Add-Member NoteProperty Owner 'Source owner' -Force;$it|Add-Member NoteProperty Evidence 'fixture approval evidence' -Force
            $specHash=CommonSpec 'MachineEnvironment';$specHash['Desired']=[pscustomobject]@{Name=$envName;Value=('reviewed-'+$envKey)}
            $it|Add-Member NoteProperty MigrationSpec ([pscustomobject]$specHash) -Force;$items+=@($it);$ids[$envKey]=[string]$it.ItemId
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
        function NewTargetInventory([int]$Revision){
            $coverage=@([pscustomobject][ordered]@{Probe='FixtureComplete';Scope='Machine';SID='';View='All';Status='Success';EvidenceKind='FixtureObservation';Count=0;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind=$null;ItemId='';ObservedUtc=(Get-WsmUtc)})
            $targetInventory=New-WsmInventory $target $Revision @()
            $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$target.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;InventoryRevision=$Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $targetInventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='isolated native observation fixture';AccountContext='System';CaptureHost='local fixture';PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=''}
            $software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software
            $targetInventory|Add-Member NoteProperty SoftwareCatalog $software -Force
            Assert-WsmSoftwareCatalog $software -SourceInventory $targetInventory|Out-Null
            $inventoryDir=Join-Path (Join-Path (Join-Path $work ('hosts\'+$target.Fingerprint)) 'inventory') ''
            [void](New-WsmOutputOwnedDirectory $inventoryDir);$inventoryPath=Join-Path $inventoryDir ('inventory-'+$Revision+'.json');SaveJson $targetInventory $inventoryPath|Out-Null
            [pscustomobject]@{Path=$inventoryPath;Hash=(Sha $inventoryPath);Job=[pscustomobject]@{status='Succeeded';action='Inventory';role='Target';workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=(Sha $inventoryPath)})}}
        }
        function script:Get-WsmAssistiveCurrentSoftwareCatalog($Snapshot){$Snapshot.SoftwareCatalog}
        $inv7=NewTargetInventory 7;$inventoryHash=$inv7.Hash
        $jobs=@($inv7.Job)
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
        $stateDirectory=Join-Path $work 'pairs';$statePath=Join-Path (Join-Path $stateDirectory $pair) 'state.json';$pairRoot=Join-Path $stateDirectory $pair
        function StateNow{Read-WsmJson $statePath}
        function Tree([string]$path){if(-not [IO.Directory]::Exists($path)){return 'absent'};(@(Get-ChildItem -LiteralPath $path -Recurse -Force|Sort-Object FullName|ForEach-Object {$rel=$_.FullName.Substring($path.Length);if($_.PSIsContainer){'D '+$rel}else{'F '+$rel+' '+(Sha $_.FullName)}}) -join "`n")}
        function RepairNow{Repair-WsmOperation -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory -Confirm:$false}
        function Recheck{Invoke-WsmTargetRestoreRecheck -ManifestPath $targetImport.ManifestPath -ExpectedHash $targetImport.ManifestHash -StateDirectory $stateDirectory}
        function ItemOf($Check,[string]$key){@($Check.Items|Where-Object {[string]$_.ItemId -ceq $ids[$key]})}
        function CodesOf($Item){(@($Item.Reasons|ForEach-Object {[string]$_.Code+':'+[string]$_.RelativePath}|Sort-Object) -join ',')}
        # everything the recheck must leave alone: state, journal, the other control files of the pair, the restored trees, the typed settings
        function Persisted{
            $other=@(Get-ChildItem -LiteralPath $pairRoot -Recurse -Force -File|Where-Object {$_.FullName -notmatch '\\rechecks\\' -and $_.Name -cne '.wsm.lock' -and $_.Name -cne 'state.json' -and $_.Name -cne 'journal.jsonl'}|Sort-Object FullName|ForEach-Object {$_.FullName.Substring($pairRoot.Length)+' '+(Sha $_.FullName)})
            [pscustomobject]@{State=(Sha $statePath);Journal=(Sha (Join-Path $pairRoot 'journal.jsonl'));ItemResults=(Get-WsmHashText ((@((StateNow).RestoreAttempt.ItemResults))|ConvertTo-Json -Depth 100 -Compress));Other=($other -join "`n");Trees=((@('docs','plain','adopt','victim')|ForEach-Object {Tree $targets[$_]}) -join "`n--`n");Env=(($script:q1Env.GetEnumerator()|Sort-Object Name|ForEach-Object {$_.Name+'='+$_.Value}) -join ';');AdapterRestoreCalls=$script:q1AdapterRestoreCalls}
        }
        function SamePersisted($Before,$After,[string]$Where){foreach($property in @('State','Journal','ItemResults','Other','Trees','Env','AdapterRestoreCalls')){Check ([string]$Before.$property -ceq [string]$After.$property) ($Where+': the recheck changed the persisted '+$property+'.')}}

        # ---- doubles: the typed MachineEnvironment settings live in a dictionary (their readback can drift); the file-scope writer is real, only a write-phase exception is injected
        $script:q1Env=@{};$script:q1EnvThrow=@{};$script:q1AdapterRestoreCalls=0
        $script:q1OrigState=(Get-Command Get-WsmAdapterState -CommandType Function).ScriptBlock
        $script:q1OrigRestore=(Get-Command Invoke-WsmAdapterRestore -CommandType Function).ScriptBlock
        $script:q1OrigBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock
        $script:q1Victims=@{};$script:q1Armed=$false;$script:q1Fired=0
        $script:q1OrigWriter=(Get-Command Invoke-WsmAssistiveFileScopeRestore -CommandType Function).ScriptBlock
        function script:Get-WsmAdapterState($Spec){
            $name=[string]$Spec.Desired.Name
            if($script:q1EnvThrow.ContainsKey($name) -and $script:q1EnvThrow[$name]){throw 'No automatic adapter state for this workflow.'}
            if($script:q1Env.ContainsKey($name)){return [pscustomobject]@{Exists=$true;Value=[string]$script:q1Env[$name]}}
            [pscustomobject]@{Exists=$false;Value=$null}
        }
        function script:Invoke-WsmAdapterRestore($Spec,[hashtable]$Secrets,$Package,$InstallerBaseline=$null,[scriptblock]$BeforeFolderCreate,[scriptblock]$AfterFolderCreate,[object[]]$OwnedReceipts=@(),[object[]]$SharedReceipts=@(),[string]$ReservationWorkspace='',[string]$ReservationOperationId=''){
            $script:q1AdapterRestoreCalls++;$script:q1Env[[string]$Spec.Desired.Name]=[string]$Spec.Desired.Value
            [pscustomobject]@{RebootRequired=$false;AuxiliaryOwnership=@()}
        }
        function script:Invoke-WsmAssistiveFileScopeRestore {
            $itemId=[string]$args[0].ItemId;$script:q1Armed=$script:q1Victims.ContainsKey($itemId)
            try{& $script:q1OrigWriter @args}finally{$script:q1Armed=$false}
        }
        function script:Assert-WsmCancellationBoundary {
            if($script:q1Armed -and [string]$args[1] -ceq 'AssistiveFileWrite'){$script:q1Fired++;throw 'Q1 injected write-phase failure'}
            & $script:q1OrigBoundary @args
        }
        try{
            # ====================================== Part B: end to end ======================================
            # ---- B1. restore 1: only the "adopt" item, an external file with the same bytes already sits at its target and the writer dies in its write phase;
            #          Repair then adopts the same-content file (P9/P10), so the item carries an AdoptedExisting ownership row.
            [void][IO.Directory]::CreateDirectory($targets.adopt)
            [IO.File]::WriteAllBytes((Join-Path $targets.adopt 'x1.bin'),$sourceBytes['adopt/x1.bin']);Set-WsmFileMetadata (Join-Path $targets.adopt 'x1.bin') $sourceMeta['adopt/x1.bin'] @{}
            $script:q1Victims=@{$ids.adopt=$true}
            $receipt1=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'First owner' -Reason 'Restore the adopt item' -SelectedItemIds ([string[]]@($ids.adopt)) -Jobs $allJobs
            $preview1=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $restore1=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview1.PreviewHash) -Jobs $allJobs
            Check ($script:q1Fired -eq 1 -and [string]$restore1.ItemResults[0].Status -ceq 'Failed') 'B1: the injected write-phase exception did not fail the adopt item once.'
            $script:q1Victims=@{}
            $repair1=RepairNow
            $adoptRow=@((StateNow).Items|Where-Object {[string]$_.ItemId -ceq $ids.adopt})
            Check ($adoptRow.Count -eq 1 -and @($adoptRow[0].OwnedFiles).Count -eq 1 -and (Test-WsmAssistiveOwnedFileAdopted $adoptRow[0].OwnedFiles[0])) 'B1: Repair did not adopt the same-content external file.'

            # ---- B2. restore 2: all seven items; "victim" dies in its write phase (a Failed item), everything else succeeds -> Partial
            $script:q1Victims=@{$ids.victim=$true}
            $selected2=@($ids.docs,$ids.plain,$ids.adopt,$ids.victim,$ids.env,$ids.env2,$ids.env3)
            $receipt2=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Second owner' -Reason 'Restore everything' -SelectedItemIds ([string[]]$selected2) -Jobs $allJobs
            $preview2=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $restore2=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview2.PreviewHash) -Jobs $allJobs
            $script:q1Victims=@{}
            $by2=@{};foreach($row in @($restore2.ItemResults)){$by2[[string]$row.ItemId]=[string]$row.Status}
            Check ($restore2.Status -ceq 'Partial' -and $script:q1Fired -eq 2 -and $by2[$ids.victim] -ceq 'Failed') ('B2: expected a Partial restore with the victim failed: '+$restore2.Status)
            foreach($key in @('docs','plain','adopt','env','env2','env3')){Check ($by2[$ids[$key]] -ceq 'Succeeded') ('B2: '+$key+' did not succeed: '+$by2[$ids[$key]])}
            $stateAfterRestore=StateNow
            Check ([string]$stateAfterRestore.Stage -ceq 'Partial' -and @($stateAfterRestore.PendingOperations).Count -eq 0) 'B2: the second restore did not end Partial without a pending intent.'

            # ---- B3. a clean recheck: nothing was changed, so nothing may drift (no false positive from directories, adopted files or settings)
            $beforeClean=Persisted
            $clean=Recheck
            Check ($clean.Outcome -ceq 'Matched' -and $clean.Status -ceq 'Succeeded' -and $clean.Summary.Checked -eq 6 -and $clean.Summary.Matched -eq 6 -and $clean.Summary.NeedsRecheck -eq 0 -and $clean.Summary.Unverifiable -eq 0) ('B3: a clean recheck must match all six succeeded items: '+($clean.Summary|ConvertTo-Json -Compress)+' '+(($clean.Items|Where-Object Status -CNE 'Matched'|ForEach-Object {$_.Name+' '+(CodesOf $_)}) -join ' | '))
            Check ($clean.Summary.NotInScope -eq 1 -and @($clean.Items|Where-Object {[string]$_.ItemId -ceq $ids.victim}).Count -eq 0) 'B3: the failed item must be outside the recheck scope (counted, not checked).'
            SamePersisted $beforeClean (Persisted) 'B3'
            Check ($clean.ReadOnly -eq $true -and $clean.NoTargetWrites -eq $true -and $clean.Sequence -eq 1) 'B3: the result must say read-only and be record number 1.'
            $recordFiles=@(Get-ChildItem -LiteralPath (Join-Path $pairRoot 'rechecks') -File)
            Check ($recordFiles.Count -eq 1 -and $recordFiles[0].BaseName -ceq $clean.RecordHash -and (Sha $recordFiles[0].FullName) -ceq $clean.RecordHash) 'B3: the record must be one content-addressed file (name = SHA-256 of its bytes).'
            $cleanRecord=Read-WsmJson $recordFiles[0].FullName
            Check ($cleanRecord.Kind -ceq 'WizardTargetRecheck' -and $cleanRecord.PairId -ceq $pair -and $cleanRecord.RestoreAttemptId -ceq [string]$stateAfterRestore.RestoreAttempt.OperationId -and $cleanRecord.ItemResultsHash -ceq (Get-WsmHashText ((@($stateAfterRestore.RestoreAttempt.ItemResults))|ConvertTo-Json -Depth 100 -Compress)) -and $cleanRecord.Sequence -eq 1 -and [string]$cleanRecord.PreviousRecheckHash -ceq '') 'B3: the record is not bound to the restore attempt, its ItemResults hash and sequence 1.'

            # ---- B4. simulate "installing software / permission change": content of one file, ACL of another, one setting, the adopted file, and one setting whose state cannot be read any more
            $aPath=Join-Path $targets.docs 'a.bin';$bPath=Join-Path $targets.docs 'b.bin';$cPath=Join-Path $targets.docs 'c.bin';$xPath=Join-Path $targets.adopt 'x1.bin'
            $aOriginal=Sha $aPath;$bOriginal=Sha $bPath;$cOriginal=Sha $cPath;$bAclOriginal=(Get-WsmFileMetadata $bPath 'DaclOwner').Sddl;$cMetaBefore=(Get-WsmFileMetadata $cPath 'DaclOwner'|ConvertTo-Json -Compress)
            [IO.File]::WriteAllBytes($aPath,[Text.Encoding]::UTF8.GetBytes('INSTALLER rewrote a.bin after the restore '+[Guid]::NewGuid().ToString('N')))
            $grant=(& icacls.exe $bPath /grant '*S-1-5-32-545:(R)' 2>&1);if($LASTEXITCODE -ne 0){throw ('B4: could not change the ACL of b.bin: '+($grant -join ' '))}
            [IO.File]::WriteAllText($xPath,'INSTALLER replaced the adopted file '+[Guid]::NewGuid().ToString('N'))
            $script:q1Env['WSM_Q1_ENV']='changed-by-installer'
            $script:q1EnvThrow['WSM_Q1_ENV3']=$true
            $aModified=Sha $aPath;$bModified=Sha $bPath;$bAclModified=(Get-WsmFileMetadata $bPath 'DaclOwner').Sddl;$xModified=Sha $xPath
            Check ($aModified -cne $aOriginal -and $bModified -ceq $bOriginal -and $bAclModified -cne $bAclOriginal) 'B4: the simulated install did not change what it should (content of a, ACL of b).'
            $beforeDrift=Persisted
            $drift=Recheck
            Check ($drift.Outcome -ceq 'NeedsRecheck' -and $drift.Status -ceq 'ReviewRequired' -and $drift.Summary.Checked -eq 6 -and $drift.Summary.NeedsRecheck -eq 3 -and $drift.Summary.Unverifiable -eq 1 -and $drift.Summary.Matched -eq 2) ('B4: expected 3 NeedsRecheck, 1 Unverifiable, 2 Matched: '+($drift.Summary|ConvertTo-Json -Compress))
            $docsItem=(ItemOf $drift 'docs')[0];$plainItem=(ItemOf $drift 'plain')[0];$adoptItem=(ItemOf $drift 'adopt')[0];$envItem=(ItemOf $drift 'env')[0];$env2Item=(ItemOf $drift 'env2')[0];$env3Item=(ItemOf $drift 'env3')[0]
            Check ([string]$docsItem.Status -ceq 'NeedsRecheck' -and (CodesOf $docsItem) -ceq 'Acl:b.bin,Content:a.bin') ('B4: docs must be NeedsRecheck with exactly the content drift of a.bin and the ACL drift of b.bin (c.bin untouched): '+(CodesOf $docsItem))
            Check ([string]$envItem.Status -ceq 'NeedsRecheck' -and (CodesOf $envItem) -ceq 'Setting:' -and [string]@($envItem.Reasons)[0].Detail -match 'Environment value mismatch') 'B4: the changed setting must be NeedsRecheck with the adapter readback problem.'
            Check ([string]$adoptItem.Status -ceq 'NeedsRecheck' -and (CodesOf $adoptItem) -ceq 'AdoptedExistingDrift:x1.bin' -and @($adoptItem.Reasons)[0].ReportOnly -eq $true) 'B4: the changed adopted file must be reported (AdoptedExistingDrift, ReportOnly).'
            Check ([string]$plainItem.Status -ceq 'Matched' -and @($plainItem.Reasons).Count -eq 0 -and [string]$env2Item.Status -ceq 'Matched' -and @($env2Item.Reasons).Count -eq 0) 'B4: the unchanged file item and the unchanged setting must stay matched.'
            Check ([string]$env3Item.Status -ceq 'Unverifiable' -and (CodesOf $env3Item) -ceq 'ReadbackFailed:' -and [string]@($env3Item.Reasons)[0].Text -match '無法自動核對') 'B4: a setting whose readback fails must be 無法自動核對, not a match.'
            Check ([string]$docsItem.PreviousStatus -ceq 'Succeeded' -and [string]$docsItem.SucceededUtc) 'B4: the item keeps its previous status and the time it succeeded.'
            # read-only: no byte of the restored content, no ACL, no setting, no state, no journal, no ItemResults changed
            Check ((Sha $aPath) -ceq $aModified -and (Sha $bPath) -ceq $bModified -and (Get-WsmFileMetadata $bPath 'DaclOwner').Sddl -ceq $bAclModified -and (Sha $xPath) -ceq $xModified -and (Sha $cPath) -ceq $cOriginal -and (Get-WsmFileMetadata $cPath 'DaclOwner'|ConvertTo-Json -Compress) -ceq $cMetaBefore) 'B4: the recheck overwrote or changed a restored file (it must keep the modified bytes and the changed ACL).'
            SamePersisted $beforeDrift (Persisted) 'B4'
            Check ((Persisted).ItemResults -ceq $beforeClean.ItemResults) 'B4: the old ItemResults were rewritten.'
            Check ((Test-WsmJournal $stateDirectory $pair).Consistent) 'B4: the journal is inconsistent after the recheck.'
            Check (@((StateNow).RestoreAttempt.ItemResults|Where-Object {[string]$_.Status -ceq 'Succeeded'}).Count -eq 6) 'B4: the durable ItemResults must still say Succeeded for all six items (history preserved).'
            # records: a second one chains to the first; junk next to them is ignored
            Check ($drift.Sequence -eq 2 -and @(Get-ChildItem -LiteralPath (Join-Path $pairRoot 'rechecks') -File).Count -eq 2) 'B4: the second recheck must be a new record, the first one stays.'
            Check ((Read-WsmJson (Join-Path (Join-Path $pairRoot 'rechecks') ($drift.RecordHash+'.json'))).PreviousRecheckHash -ceq $clean.RecordHash) 'B4: the second record must chain to the first (PreviousRecheckHash).'
            [IO.File]::WriteAllText((Join-Path (Join-Path $pairRoot 'rechecks') 'junk.json'),'{"Kind":"WizardTargetRecheck","SchemaVersion":1,"PairId":"'+$pair+'","Sequence":99}')
            [IO.File]::WriteAllText((Join-Path (Join-Path $pairRoot 'rechecks') (('0'*64)+'.json')),'{"Kind":"WizardTargetRecheck","SchemaVersion":1,"PairId":"'+$pair+'","Sequence":98}')
            Check (@(Get-WsmAssistiveRecheckRecords (Get-WsmOperationPaths $stateDirectory $pair)).Count -eq 2) 'B4: a record whose name is not its content hash must be ignored.'

            # ---- B5. projection: Succeeded drops to NeedsRecheck with the reason, the history sentence, the old results untouched, the action offered
            $restoreJob2=[pscustomobject]@{action='TargetRestore';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[string]$restore2.AttemptOperationId;CompletedUtc=(Get-WsmUtc);outputs=@($restore2)}
            $runtimeJobs=@($allJobs)+@($restoreJob2)
            $runtime=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $runtimeJobs)
            $target2=$runtime.runtime;$rc=$target2.recheck
            Check ($rc.visible -eq $true -and $rc.available -eq $true -and $rc.checked -eq $true -and $rc.needsRecheckCount -eq 3 -and $rc.unverifiableCount -eq 1 -and $rc.matchedCount -eq 2 -and $rc.checkedCount -eq 6 -and $rc.sequence -eq 2) ('B5: the recheck projection counts are wrong: '+($rc|Select-Object visible,available,checked,needsRecheckCount,unverifiableCount,matchedCount,sequence|ConvertTo-Json -Compress))
            $pDocs=@($rc.items|Where-Object {[string]$_.itemId -ceq $ids.docs})[0];$pEnv=@($rc.items|Where-Object {[string]$_.itemId -ceq $ids.env})[0];$pPlain=@($rc.items|Where-Object {[string]$_.itemId -ceq $ids.plain})[0];$pEnv3=@($rc.items|Where-Object {[string]$_.itemId -ceq $ids.env3})[0]
            Check ([string]$pDocs.status -ceq 'NeedsRecheck' -and [string]$pEnv.status -ceq 'NeedsRecheck' -and [string]$pPlain.status -ceq 'Succeeded' -and [string]$pEnv3.status -ceq 'Unverifiable') 'B5: the projection must show drifted items as NeedsRecheck, clean ones as Succeeded, unreadable ones as Unverifiable.'
            Check (@($pDocs.reasons|ForEach-Object {[string]$_.code+':'+[string]$_.relativePath}|Sort-Object) -join ',' -ceq 'Acl:b.bin,Content:a.bin') 'B5: the projection must carry the drift reasons (content of a.bin, ACL of b.bin).'
            Check ([string]$pDocs.statusText -ceq '待核對' -and [string]$pDocs.previousStatus -ceq 'Succeeded' -and [string]$pDocs.historyText -match '^曾成功於 \d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC，\d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC 核對發現漂移$') ('B5: the history sentence is wrong: '+[string]$pDocs.historyText)
            Check ([string]$pEnv3.statusText -ceq '無法自動核對') 'B5: the unverifiable item must read 無法自動核對.'
            $resultStatuses=@($target2.restoreResult.itemResults|ForEach-Object {[string]$_.Status}|Sort-Object -Unique)
            Check ($target2.restoreResult -and $resultStatuses -join ',' -ceq 'Failed,Succeeded' -and @($target2.restoreResult.itemResults|Where-Object {[string]$_.Status -ceq 'Succeeded'}).Count -eq 6) 'B5: the restore result in the projection must keep its old statuses (Succeeded stays Succeeded there).'
            $recheckAction=@($runtime.actions|Where-Object {[string]$_.id -ceq 'TargetRecheck'})
            Check ($recheckAction.Count -eq 1 -and $recheckAction[0].available -eq $true -and @($recheckAction[0].missing).Count -eq 0 -and [string]$recheckAction[0].defaults.PairId -ceq $pair) 'B5: the TargetRecheck action must be offered with Workspace/PairId defaults and nothing missing.'
            Check ([string]$runtime.actionContracts.TargetRecheck.Command -ceq 'Invoke-WsmWizardTargetRecheck') 'B5: the action contract is not in the projection.'
            $optionsById=@{};foreach($option in @($target2.itemOptions)){$optionsById[[string]$option.value]=$option}
            Check ([string]$optionsById[$ids.docs].recheckStatus -ceq 'NeedsRecheck' -and [string]$optionsById[$ids.plain].recheckStatus -ceq 'Succeeded' -and [string]$optionsById[$ids.victim].recheckStatus -ceq '' -and $optionsById[$ids.docs].restored -eq $true) 'B5: the item options must carry the recheck status without changing restored.'
            Check ($target2.recheck.suggested -eq $false) 'B5: with the snapshot the restore was made with, no "changed" hint is due.'

            # ---- B6. P8: NeedsRecheck is not a failure; only the failed item is a retry candidate (after Repair clears the failed item's incomplete ownership)
            $c0=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($c0.Visible -and -not $c0.Eligible -and (Ids $c0.NotSucceededItemIds) -ceq $ids.victim -and (Ids $c0.NeedsRecheckItemIds) -ceq (Ids @($ids.docs,$ids.adopt,$ids.env))) 'B6: before Repair the retry must be visible (the failed item) and list the NeedsRecheck items separately.'
            Check (@($c0.Excluded|ForEach-Object {[string]$_.ItemId}) -notcontains $ids.docs -and @($c0.Excluded|ForEach-Object {[string]$_.ItemId}) -notcontains $ids.env) 'B6: a NeedsRecheck item must not be listed as a cannot-retry failure.'
            $repair2=RepairNow
            $c1=Get-WsmWizardTargetRetryCandidates -Workspace $work -PairId $pair -Jobs $allJobs
            Check ($c1.Visible -and $c1.Eligible -and (Ids $c1.CandidateItemIds) -ceq $ids.victim) ('B6: the retry candidates must be exactly the failed item, got '+(Ids $c1.CandidateItemIds))
            Check ((Ids $c1.SucceededItemIds) -ceq (Ids @($ids.docs,$ids.plain,$ids.adopt,$ids.env,$ids.env2,$ids.env3)) -and (Ids $c1.NotSucceededItemIds) -ceq $ids.victim) 'B6: the succeeded side keeps all six (history), the failed side is only the victim.'
            Reject {Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'o' -Reason 'r' -SelectedItemIds @($ids.victim,$ids.docs) -RetryOfReceiptHash ([string]$c1.SourceReceiptHash) -Jobs $allJobs} 'B6: a retry receipt that adds a NeedsRecheck item was accepted.' 'differ'
            $runtimeRetry=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $runtimeJobs)
            Check ((@($runtimeRetry.runtime.retry.candidateItemIds)-join ',') -ceq $ids.victim -and (Ids $runtimeRetry.runtime.retry.needsRecheckItemIds) -ceq (Ids @($ids.docs,$ids.adopt,$ids.env))) 'B6: the retry projection must offer only the failed item and name the NeedsRecheck items.'

            # ---- B7. a new Target inventory is imported: the projection hints that restored content may have changed (no automatic recheck)
            $recordsBeforeHint=@(Get-ChildItem -LiteralPath (Join-Path $pairRoot 'rechecks') -File -Filter '*.json'|Where-Object {$_.BaseName -match '^[0-9a-f]{64}$' -and $_.BaseName -cne ('0'*64)}).Count
            Start-Sleep -Milliseconds 1200
            $inv8=NewTargetInventory 8
            $newJobs=@($inv8.Job,$allJobs[1])+@($restoreJob2)
            $hinted=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $newJobs)
            Check ($hinted.runtime.recheck.suggested -eq $true -and [string]$hinted.runtime.recheck.suggestedText -ceq '已還原內容可能已變動，建議重新核對。') ('B7: importing a new Target inventory did not produce the hint: '+($hinted.runtime.recheck|ConvertTo-Json -Compress -Depth 3).Substring(0,200))
            Check ($hinted.runtime.recheck.visible -eq $true -and @($hinted.actions|Where-Object {[string]$_.id -ceq 'TargetRecheck' -and $_.available -eq $true}).Count -eq 1) 'B7: the hint must come with the available TargetRecheck action even though the page now needs a new comparison.'
            Check ([string]$hinted.status -cin @('NeedsComparison','NeedsTargetDecision')) ('B7: expected the page to need a new comparison after the new inventory, got '+[string]$hinted.status)
            $afterHintRecords=@(Get-ChildItem -LiteralPath (Join-Path $pairRoot 'rechecks') -File -Filter '*.json'|Where-Object {$_.BaseName -match '^[0-9a-f]{64}$' -and $_.BaseName -cne ('0'*64)}).Count
            Check ($recordsBeforeHint -eq $afterHintRecords) 'B7: showing the hint must not run a recheck by itself.'
            $viaWizard=Invoke-WsmWizardTargetRecheck -Workspace $work -PairId $pair -Jobs $newJobs
            Check ($viaWizard.Outcome -ceq 'NeedsRecheck' -and $viaWizard.Summary.NeedsRecheck -eq 3) 'B7: the wizard entrance did not return the same finding.'
            Check ((Read-WsmJson (Join-Path (Join-Path $pairRoot 'rechecks') ($viaWizard.RecordHash+'.json'))).ObservedSnapshotHash -ceq $inv8.Hash) 'B7: the record does not name the Target inventory that was current when it was made.'
            $afterRecheck=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $newJobs)
            Check ($afterRecheck.runtime.recheck.suggested -eq $false -and $afterRecheck.runtime.recheck.needsRecheckCount -eq 3) 'B7: once rechecked against the new inventory the hint must go away and the findings stay.'

            # ---- B8. CLI output (menu 16 prints this): the NeedsRecheck items with their reasons
            $cli=Recheck
            $cliText=((Show-WsmTargetRestoreRecheckResult $cli 6>&1) | Out-String)
            Check ($cliText -match '待核對 3' -and $cliText -match '待核對：Q1 workload docs' -and $cliText -match 'a\.bin：內容已變動' -and $cliText -match 'b\.bin：權限（ACL）已變動' -and $cliText -match '無法自動核對：Q1 setting env3' -and $cliText -match '沒有覆寫、刪除或修改') ('B8: the CLI output does not list the findings: '+$cliText)
            Check (@($cli.Rows|Where-Object Status -CEQ 'NeedsRecheck').Count -eq 3 -and @($cli.Rows|Where-Object {$_.StatusText -ceq '吻合'}).Count -eq 2) 'B8: the CLI rows are wrong.'

            # ---- B9. an explicit re-restore of a drifted item is still protected: the writer refuses with BlockedConflict and overwrites nothing
            $docsTreeBefore=Tree $targets.docs
            $receipt9=Create-WsmWizardTargetDecisionReceipt -Workspace $work -PairId $pair -Decision RestoreNow -Owner 'Operator' -Reason 'Explicitly re-restore the drifted docs item' -SelectedItemIds ([string[]]@($ids.docs)) -Jobs $allJobs
            $preview9=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
            $restore9=Invoke-WsmWizardTargetRestore -Workspace $work -PairId $pair -PreviewHash ([string]$preview9.PreviewHash) -Jobs $allJobs
            Check (@($restore9.ItemResults).Count -eq 1 -and [string]$restore9.ItemResults[0].Status -ceq 'BlockedConflict') ('B9: the drifted item was not refused with BlockedConflict: '+[string]$restore9.ItemResults[0].Status)
            Check ((Sha $aPath) -ceq $aModified -and (Sha $bPath) -ceq $bModified -and (Tree $targets.docs) -ceq $docsTreeBefore) 'B9: the explicit re-restore overwrote the drifted files.'
            Check ((Sha $xPath) -ceq $xModified) 'B9: an unselected item changed.'
        }finally{
            Set-Item Function:\Get-WsmAdapterState -Value $script:q1OrigState
            Set-Item Function:\Invoke-WsmAdapterRestore -Value $script:q1OrigRestore
            Set-Item Function:\script:Assert-WsmCancellationBoundary -Value $script:q1OrigBoundary
            Set-Item Function:\script:Invoke-WsmAssistiveFileScopeRestore -Value $script:q1OrigWriter
        }
        Write-Host ('PASS: post-restore recheck ('+$script:q1Checks+' checks): read-only recheck of the succeeded items (file content/ACL/adopted files and typed settings), drift drops Succeeded to NeedsRecheck with reasons and history, no readback is never a match, state/journal/ItemResults/files untouched, new-inventory hint, P8 candidates exclude NeedsRecheck, CLI output, an explicit re-restore still meets BlockedConflict.')
    } $root $workRoot $srcDir
} finally {
    foreach($path in @($root,$workRoot)){if($path -and [IO.Directory]::Exists($path)){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$path+': '+$_.Exception.Message)}}}
}
