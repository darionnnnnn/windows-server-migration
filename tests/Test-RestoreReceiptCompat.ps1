#requires -Version 5.1
# Batch B of the round-seven audit fixes (R8, R12, R20, R23). Everything here runs under Set-StrictMode -Version Latest and never turns strict mode off.
#   R8   decision receipt: monotonic Sequence beats CreatedUtc, legacy receipts rank before any receipt with a Sequence, RetryOfReceiptHash is part of the receipt hash.
#   R12  a rolled-back restore is a terminal state for the retry judgement: its own reason code and text, never RestoreInProgress.
#   R20  legacy state whose RestoreAttempt has no Status, terminal Status written back, progress records without ItemsDone / Recent still project.
#   R23  the restore item picker receives a bounded, safe file list (first 100 relative paths + total) from one cached read of the verified artifact index.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$srcRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-rb-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$SrcRoot)
        $script:rbChecks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:rbChecks++}
        function Reject([scriptblock]$action,[string]$message,[string]$pattern=''){$rejected=$false;$text='';try{& $action|Out-Null}catch{$rejected=$true;$text=[string]$_.Exception.Message};Check $rejected $message;if($pattern){Check ($text -match $pattern) ($message+' (wrong rejection: '+$text+')')}}
        # Runs an action and returns the error id and message ('' when it did not throw). A strict-mode crash on missing legacy data has the language-independent id PropertyNotFoundStrict.
        function Thrown([scriptblock]$action){try{& $action|Out-Null;''}catch{[string]$_.FullyQualifiedErrorId+' '+[string]$_.Exception.Message}}
        $strictCrash='PropertyNotFound'
        $script:rbPreview=$null;$script:rbResolved=$null;$script:rbSuperseded=$null;$script:rbView=$null

        # ====================================== R8: decision receipt ordering and retry binding ======================================
        $wsA=Join-Path $Root 'ws-receipts';[void][IO.Directory]::CreateDirectory($wsA)
        $planHash=('3'*64)
        function New-ReceiptFile([string]$Pair,[string]$Tag,[string]$CreatedUtc,$Sequence=$null,[string]$RetryOf='') {
            $materialRoot=Get-WsmWizardTargetMaterialRoot $wsA $Pair;[void][IO.Directory]::CreateDirectory($materialRoot)
            $comparison=[pscustomobject][ordered]@{Revision=1;SourceSnapshotHash=('1'*64);TargetSnapshotHash=('2'*64);SelectionRevision=1;Rows=@()}
            $receipt=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveTargetDecisionReceipt';ReceiptId=[Guid]::NewGuid().ToString();PairId=$Pair;PlanHash=$planHash;ManifestHash=('4'*64);Generation=1;TargetSnapshotHash=('2'*64);ComparisonRevision=1;SelectionRevision=1;Decision='RestoreNow';Owner=$Tag;Reason='fixture';SelectedItemIds=@(('a'*64));AcceptedUnpreparedItemIds=@();CreatedUtc=$CreatedUtc;SHA256=''}
            $receipt|Add-Member NoteProperty Comparison $comparison;$receipt|Add-Member NoteProperty ComparisonHash (Get-WsmHashText ($comparison|ConvertTo-Json -Depth 100 -Compress))
            if($null -ne $Sequence){$receipt|Add-Member NoteProperty Sequence ([long]$Sequence)}
            if($RetryOf){$receipt|Add-Member NoteProperty RetryOfReceiptHash $RetryOf}
            $body=[ordered]@{};foreach($property in $receipt.PSObject.Properties){if($property.Name -cne 'SHA256'){$body[$property.Name]=$property.Value}}
            $receipt.SHA256=Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress)
            $path=Join-Path $materialRoot ('decision-'+$receipt.ReceiptId+'.json');Write-WsmJson $path $receipt;$path
        }
        function Pick([string]$Pair){$record=Get-WsmWizardTargetDecisionRecord $wsA $Pair $planHash;if($record){[string]$record.Receipt.Owner}else{''}}

        # A1: the clock went backwards — the second receipt has the smaller CreatedUtc but the larger Sequence and must win.
        $p1=[Guid]::NewGuid().ToString();[void](New-ReceiptFile $p1 'first' '2026-10-10T00:00:00.0000000Z' 1);[void](New-ReceiptFile $p1 'second' '2026-10-01T00:00:00.0000000Z' 2)
        Check ((Pick $p1) -ceq 'second') 'R8: with the clock stepped back, the older-dated receipt with the higher Sequence was not selected.'
        # A2: legacy receipts (no Sequence) rank before any receipt with a Sequence, even when their CreatedUtc is later; legacy ones order by CreatedUtc among themselves.
        $p2=[Guid]::NewGuid().ToString()
        [void](New-ReceiptFile $p2 'legacy-late' '2026-12-01T00:00:00.0000000Z');[void](New-ReceiptFile $p2 'legacy-early' '2026-01-01T00:00:00.0000000Z');[void](New-ReceiptFile $p2 'new-1' '2026-02-01T00:00:00.0000000Z' 1)
        Check ((Pick $p2) -ceq 'new-1') 'R8: a legacy receipt with a later CreatedUtc outranked a receipt that has a Sequence.'
        [void](New-ReceiptFile $p2 'new-5' '2026-01-15T00:00:00.0000000Z' 5)
        Check ((Pick $p2) -ceq 'new-5') 'R8: the highest Sequence did not win among mixed legacy and new receipts.'
        $p3=[Guid]::NewGuid().ToString();[void](New-ReceiptFile $p3 'legacy-a' '2026-03-01T00:00:00.0000000Z');[void](New-ReceiptFile $p3 'legacy-b' '2026-04-01T00:00:00.0000000Z')
        Check ((Pick $p3) -ceq 'legacy-b') 'R8: legacy receipts are no longer ordered by CreatedUtc among themselves.'
        $p3b=[Guid]::NewGuid().ToString();[void](New-ReceiptFile $p3b 'only-legacy' '2026-03-01T00:00:00.0000000Z')
        Check ((Pick $p3b) -ceq 'only-legacy') 'R8: a single legacy receipt could not be read.'
        # A3: equal Sequence falls back to CreatedUtc; fully equal is ambiguous (existing fail-closed behaviour).
        $p4=[Guid]::NewGuid().ToString();[void](New-ReceiptFile $p4 'seq-old' '2026-05-01T00:00:00.0000000Z' 3);[void](New-ReceiptFile $p4 'seq-new' '2026-06-01T00:00:00.0000000Z' 3)
        Check ((Pick $p4) -ceq 'seq-new') 'R8: equal Sequence did not fall back to CreatedUtc.'
        $p5=[Guid]::NewGuid().ToString();[void](New-ReceiptFile $p5 'x' '2026-05-01T00:00:00.0000000Z' 3);[void](New-ReceiptFile $p5 'y' '2026-05-01T00:00:00.0000000Z' 3)
        Reject {Pick $p5} 'R8: two receipts with equal Sequence and equal CreatedUtc were not reported as ambiguous.' 'ambiguous'
        $p6=[Guid]::NewGuid().ToString();[void](New-ReceiptFile $p6 'x' '2026-05-01T00:00:00.0000000Z');[void](New-ReceiptFile $p6 'y' '2026-05-01T00:00:00.0000000Z')
        Reject {Pick $p6} 'R8: two legacy receipts with equal CreatedUtc were not reported as ambiguous.' 'ambiguous'
        # A4: RetryOfReceiptHash is part of the receipt hash — editing it makes the receipt unreadable, so selection falls back to the other one.
        $p7=[Guid]::NewGuid().ToString();[void](New-ReceiptFile $p7 'base' '2026-05-01T00:00:00.0000000Z' 1)
        $retryHash=('9'*64);$retryPath=New-ReceiptFile $p7 'retry' '2026-05-02T00:00:00.0000000Z' 2 $retryHash
        Check ((Pick $p7) -ceq 'retry') 'R8: the retry receipt was not selected.'
        $stored=Read-WsmJson $retryPath;Check ([string]$stored.RetryOfReceiptHash -ceq $retryHash -and [long]$stored.Sequence -eq 2) 'R8: the fixture receipt lost its RetryOfReceiptHash or Sequence.'
        $tampered=[IO.File]::ReadAllText($retryPath).Replace($retryHash,('8'*64));[IO.File]::WriteAllText($retryPath,$tampered,(New-Object Text.UTF8Encoding($false)))
        Check ((Pick $p7) -ceq 'base') 'R8: a receipt whose RetryOfReceiptHash was edited was still accepted.'
        # A5: the next Sequence is the pair-wide maximum plus one (legacy counts as zero), under the same single definition the comparison material uses.
        $p8=[Guid]::NewGuid().ToString();[void][IO.Directory]::CreateDirectory((Get-WsmWizardTargetMaterialRoot $wsA $p8))
        Check ((Get-WsmWizardTargetNextDecisionSequence $wsA $p8) -eq 1) 'R8: the first Sequence of an empty pair is not 1.'
        [void](New-ReceiptFile $p8 'legacy' '2026-01-01T00:00:00.0000000Z');Check ((Get-WsmWizardTargetNextDecisionSequence $wsA $p8) -eq 1) 'R8: a legacy receipt must count as Sequence zero.'
        [void](New-ReceiptFile $p8 'n7' '2026-01-02T00:00:00.0000000Z' 7);Check ((Get-WsmWizardTargetNextDecisionSequence $wsA $p8) -eq 8) 'R8: the next Sequence is not the maximum plus one.'
        Write-Host ('PASS: R8 receipt ordering ('+$script:rbChecks+' checks so far).')

        # ====================================== R12: a rolled-back restore is terminal for the retry judgement ======================================
        $mh=('a'*64);$rh=('b'*64);$ids=@('a','b')
        $pkgRecord=[pscustomobject]@{ManifestHash=$mh;Package=[pscustomobject]@{Manifest=[pscustomobject]@{Generation=3}}}
        function Rolled([string]$Stage,[object[]]$Pending=@()){[pscustomobject]@{Stage=$Stage;PendingOperations=@($Pending);RestoreAttempt=[pscustomobject]@{OperationId='attempt-1';ManifestHash=$mh;Generation=3;DecisionReceiptHash=$rh;SelectedItemIds=$ids;ItemResults=@([pscustomobject]@{ItemId='a';Status='Succeeded'},[pscustomobject]@{ItemId='b';Status='Failed'})}}}
        $decisionRow=[pscustomobject]@{SHA256=$rh;Path='C:\x\decision.json';Receipt=[pscustomobject]@{Decision='RestoreNow';Owner='o';Reason='r';SelectedItemIds=$ids;AcceptedUnpreparedItemIds=@()}}
        $options=@([pscustomobject]@{value='a';label='a';restorable=$true;restorableCode='';restorableReason=''},[pscustomobject]@{value='b';label='b';restorable=$true;restorableCode='';restorableReason=''})
        $rolledText='已回復，請重新選擇還原'
        $r=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkgRecord -State (Rolled 'RolledBack') -DecisionRecord $decisionRow -ItemOptions $options
        Check (-not $r.Visible -and -not $r.Eligible -and $r.ReasonCode -ceq 'RolledBack' -and $r.ReasonCode -cne 'RestoreInProgress' -and $r.Reason.Contains($rolledText) -and @($r.CandidateItemIds).Count -eq 0) 'R12: a rolled-back state did not answer with the RolledBack code and the rolled-back text.'
        $r=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkgRecord -State (Rolled 'RolledBack' @([pscustomobject]@{ItemId='b';Phase='RollbackAdapter'})) -DecisionRecord $decisionRow -ItemOptions $options
        Check ($r.ReasonCode -ceq 'RolledBack' -and $r.Reason.Contains($rolledText)) 'R12: a leftover pending record turned a rolled-back state into another reason.'
        # The durable state is the truth: an old Interrupted / WaitingForInput job record must not turn a rolled-back state back into "restore in progress".
        foreach($pendingStatus in @('Interrupted','WaitingForInput')){
            $r=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkgRecord -State (Rolled 'RolledBack') -DecisionRecord $decisionRow -ItemOptions $options -PendingRestore ([pscustomobject]@{Status=$pendingStatus;Summary='x'})
            Check ($r.ReasonCode -ceq 'RolledBack' -and $r.Reason.Contains($rolledText) -and -not $r.Visible) ('R12: a stale '+$pendingStatus+' job record outranked the durable RolledBack stage.')
        }
        # Stages that are still running keep the in-progress answer.
        foreach($stage in @('Running','RollbackRunning')){$r=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkgRecord -State (Rolled $stage) -DecisionRecord $decisionRow -ItemOptions $options;Check ($r.ReasonCode -ceq 'RestoreInProgress' -and -not $r.Reason.Contains($rolledText)) ('R12: stage '+$stage+' must keep the in-progress answer.')}
        $r=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $pkgRecord -State (Rolled 'Partial') -DecisionRecord $decisionRow -ItemOptions $options
        Check ($r.Visible -and $r.Eligible -and $r.ReasonCode -ceq '') 'R12: the rolled-back change broke the normal Partial retry.'
        Write-Host ('PASS: R12 rolled-back retry judgement ('+$script:rbChecks+' checks so far).')

        # ====================================== R20: legacy state (RestoreAttempt without Status), strict mode on ======================================
        $stateMh=('a'*64);$legacyPreview=('c'*64)
        function New-LegacyState([string]$Name,[string]$Stage,$Status=$null) {
            $workspace=Join-Path $Root $Name;$pair=[Guid]::NewGuid().ToString();$stateDirectory=Join-Path $workspace 'pairs';$directory=Join-Path $stateDirectory $pair;[void][IO.Directory]::CreateDirectory($directory)
            $attempt=[ordered]@{OperationId=[Guid]::NewGuid().ToString();ManifestHash=$stateMh;Generation=3;DecisionReceiptHash=('b'*64);WizardPreviewHash=$legacyPreview;SelectedItemIds=@('i1');ItemResults=@()}
            if($null -ne $Status){$attempt['Status']=$Status}
            Write-WsmJson (Join-Path $directory 'state.json') ([pscustomobject][ordered]@{SchemaVersion=1;Kind='OperationState';PairId=$pair;Stage=$Stage;PendingOperations=@();RestoreAttempt=[pscustomobject]$attempt})
            [pscustomobject]@{Workspace=$workspace;StateDirectory=$stateDirectory;Pair=$pair;Op=[string]$attempt.OperationId;Json=(Join-Path $directory 'state.json')}
        }
        # R20-a: the CLI resume preview must not crash and must judge the legacy state by its Stage.
        $expectedResume=@{Succeeded=@{Resumable=$false;Reason='Terminal'};Partial=@{Resumable=$false;Reason='Terminal'};RebootRequired=@{Resumable=$false;Reason='Terminal'};Cancelled=@{Resumable=$false;Reason='Cancelled'};Superseded=@{Resumable=$false;Reason='Superseded'};Running=@{Resumable=$true;Reason='PreviewUnavailable'};WaitingForInput=@{Resumable=$true;Reason='PreviewUnavailable'}}
        foreach($stage in @($expectedResume.Keys|Sort-Object)){
            $legacy=New-LegacyState ('legacy-resume-'+$stage) $stage
            Check (-not ((Read-WsmJson $legacy.Json).RestoreAttempt.PSObject.Properties['Status'])) 'R20: the fixture must really lack RestoreAttempt.Status.'
            $script:rbPreview=$null;$message=Thrown {$script:rbPreview=Get-WsmWizardTargetRestoreResumePreview -Workspace $legacy.Workspace -PairId $legacy.Pair};$preview=$script:rbPreview
            Check ($message -notmatch $strictCrash -and $message -ceq '') ('R20: ResumePreview crashed on a legacy '+$stage+' state: '+$message)
            Check ([bool]$preview.Resumable -eq [bool]$expectedResume[$stage].Resumable -and [string]$preview.Reason -ceq [string]$expectedResume[$stage].Reason) ('R20: ResumePreview judged a legacy '+$stage+' state wrongly: '+[string]$preview.Reason+' resumable='+$preview.Resumable)
        }
        # R20-b: every other reader on the restore parent path reaches its own intended terminal answer instead of a strict-mode crash.
        foreach($stage in @('Succeeded','Partial','Cancelled')){
            $legacy=New-LegacyState ('legacy-parent-'+$stage) $stage
            Reject {Stop-WsmWizardTargetRestoreParent -StateDirectory $legacy.StateDirectory -PairId $legacy.Pair -ParentOperationId $legacy.Op} ('R20: Stop on a legacy '+$stage+' parent did not answer "already terminal".') 'already reached a terminal state'
            Reject {Revoke-WsmWizardTargetRestoreParent -StateDirectory $legacy.StateDirectory -PairId $legacy.Pair -ParentOperationId $legacy.Op} ('R20: Revoke on a legacy '+$stage+' parent did not answer "no longer active".') 'no longer active'
            Reject {Update-WsmWizardTargetRestorePreviewBinding -StateDirectory $legacy.StateDirectory -PairId $legacy.Pair -ParentOperationId $legacy.Op -Projection ([pscustomobject]@{PreviewHash=$legacyPreview;Rows=@()})} ('R20: Update-PreviewBinding on a legacy '+$stage+' parent did not answer "no longer active".') 'no longer active'
            $script:rbResolved=$null;$message=Thrown {$script:rbResolved=Resolve-WsmWizardTargetRestorePreviewBinding -Workspace $legacy.Workspace -PairId $legacy.Pair -ParentOperationId $legacy.Op -PreviewHash ('d'*64)};$resolved=$script:rbResolved
            Check ($message -ceq '' -and [string]$resolved -ceq ('d'*64)) ('R20: Resolve on a legacy '+$stage+' parent crashed or changed the hash: '+$message)
            $script:rbSuperseded=$null;$message=Thrown {$script:rbSuperseded=Invoke-WsmWizardSupersedeStaleTargetRestoreParent -Workspace $legacy.Workspace -PairId $legacy.Pair -PreviewHash ('d'*64)}
            Check ($message -ceq '' -and [string]$script:rbSuperseded -ceq '') ('R20: the stale-parent check crashed or revoked a legacy '+$stage+' parent: '+$message)
            Check ([string](Read-WsmJson $legacy.Json).Stage -ceq $stage) ('R20: a refused call changed the legacy '+$stage+' state.')
        }
        # R20-c: the Service challenge pre-write recovery judge reads the same status through the same helper (a legacy Running parent is "running", not a crash).
        $legacyRunning=New-LegacyState 'legacy-prewrite' 'Running'
        $stateObject=Read-WsmJson $legacyRunning.Json;$challenge=[pscustomobject][ordered]@{State='Running';ParentOperationId=$legacyRunning.Op}
        $stateObject|Add-Member NoteProperty AssistiveServiceChallenge $challenge -Force
        $message=Thrown {Test-WsmAssistiveServiceChallengePreWriteRecovery $legacyRunning.StateDirectory $stateObject $legacyRunning.Op}
        Check ($message -notmatch $strictCrash) ('R20: the pre-write recovery judge crashed on a legacy attempt: '+$message)
        Check ((Get-WsmAssistiveRestoreAttemptStatus $stateObject.RestoreAttempt $stateObject) -ceq 'Running') 'R20: the shared status helper did not derive Running from a legacy Running stage.'
        # The helper's one rule: a recorded Status wins; a missing one falls back to the state Stage; nothing known is the empty string.
        Check ((Get-WsmAssistiveRestoreAttemptStatus ([pscustomobject]@{Status='Cancelled'}) ([pscustomobject]@{Stage='Running'})) -ceq 'Cancelled') 'R20: a recorded Status did not win over the Stage.'
        Check ((Get-WsmAssistiveRestoreAttemptStatus ([pscustomobject]@{OperationId='x'}) ([pscustomobject]@{Stage='Partial'})) -ceq 'Partial') 'R20: a missing Status did not fall back to the state Stage.'
        Check ((Get-WsmAssistiveRestoreAttemptStatus ([pscustomobject]@{OperationId='x'}) $null) -ceq '' -and (Get-WsmAssistiveRestoreAttemptStatus $null $null) -ceq '') 'R20: unknown inputs must give the empty string.'
        # R20-d (guard): no source file reads <attempt>.Status directly any more. The detector is proved on a snippet first so the guard cannot go blind.
        function Find-DirectAttemptStatusReads([string]$Text) {
            $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
            # The one shared reader is the only place allowed to touch the property (behind a PSObject.Properties check).
            $insideReader={param($n)$cursor=$n.Parent;while($cursor){if($cursor -is [Management.Automation.Language.FunctionDefinitionAst] -and $cursor.Name -ceq 'Get-WsmAssistiveRestoreAttemptStatus'){return $true};$cursor=$cursor.Parent};$false}
            @($ast.FindAll({param($n)$n -is [Management.Automation.Language.MemberExpressionAst] -and $n.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and [string]$n.Member.Value -ceq 'Status' -and $n.Expression.Extent.Text -match '(?i)attempt$' -and -not ($n.Parent -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Parent.Left -eq $n)},$true)|Where-Object {-not (& $insideReader $_)}|ForEach-Object {$_.Extent.Text})
        }
        Check (@(Find-DirectAttemptStatusReads 'function F($state){ [string]$state.RestoreAttempt.Status -ceq "x" }').Count -eq 1 -and @(Find-DirectAttemptStatusReads 'function F($attempt){ $attempt.Status }').Count -eq 1 -and @(Find-DirectAttemptStatusReads 'function F($currentAttempt){ if([string]$currentAttempt.Status -cnotin @("a")){1} }').Count -eq 1) 'R20: the guard detector does not flag direct reads.'
        Check (@(Find-DirectAttemptStatusReads 'function F($attempt){ $attempt.Status=1; $x.Status; $attempt.PSObject.Properties["Status"] }').Count -eq 0 -and @(Find-DirectAttemptStatusReads 'function Get-WsmAssistiveRestoreAttemptStatus($Attempt){ [string]$Attempt.Status }').Count -eq 0 -and @(Find-DirectAttemptStatusReads 'function Other($Attempt){ [string]$Attempt.Status }').Count -eq 1) 'R20: the guard detector flags assignments, unrelated reads or the shared reader, or misses a copy of it under another name.'
        foreach($name in @('WizardRestore.ps1','AssistiveRestore.ps1')){
            $found=@(Find-DirectAttemptStatusReads ([IO.File]::ReadAllText((Join-Path $SrcRoot $name))))
            Check ($found.Count -eq 0) ('R20: '+$name+' still reads an attempt Status directly ('+$found.Count+' places, first: '+($found|Select-Object -First 1)+').')
        }
        Write-Host ('PASS: R20 legacy state ('+$script:rbChecks+' checks so far).')

        # ====================================== R20: progress records that lack ItemsDone / Recent still project ======================================
        $rawBase=[ordered]@{Kind='WizardBackupProgress';Stage='Capture';StageIndex=1;StageCount=3;Workload='w';CurrentFile='f.txt';StartedUtc='2026-10-24T00:00:00Z';UpdatedUtc='2026-10-24T00:00:01Z';BytesDone=0;Terminal=$false;Outcome='';FailedCount=0}
        $full=[ordered]@{};foreach($key in $rawBase.Keys){$full[$key]=$rawBase[$key]};$full['ItemsDone']=1;$full['ItemsTotal']=4;$full['BytesTotal']=100;$full['Recent']=@([pscustomobject]@{ItemId='i1';Result='Generated'})
        $fullView=ConvertTo-WsmWizardBackupProgressView ([pscustomobject]$full) 'Running'
        Check ($null -ne $fullView -and [long]$fullView.ItemsDone -eq 1 -and [int]$fullView.Percent -eq 25 -and @($fullView.Recent).Count -eq 1) 'R20: the complete progress record no longer projects.'
        foreach($missing in @(@('ItemsDone'),@('Recent'),@('ItemsDone','Recent'),@('ItemsTotal'),@('BytesTotal'),@('ItemsDone','ItemsTotal','BytesTotal','Recent'))){
            $copy=[ordered]@{};foreach($key in $full.Keys){if($key -cnotin $missing){$copy[$key]=$full[$key]}}
            $script:rbView=$null;$message=Thrown {$script:rbView=ConvertTo-WsmWizardBackupProgressView ([pscustomobject]$copy) 'Running'};$view=$script:rbView
            Check ($message -ceq '' -and $null -ne $view) ('R20: a progress record without '+($missing -join '/')+' did not project: '+$message)
            Check ([string]$view.State -ceq 'Running' -and [string]$view.Stage -ceq 'Capture' -and @($view.Recent).Count -eq $(if('Recent' -cin $missing){0}else{1})) ('R20: the projection of a record without '+($missing -join '/')+' has the wrong state or Recent.')
            if('ItemsDone' -cin $missing){Check ($null -eq $view.ItemsDone -and $null -eq $view.Percent) 'R20: a missing ItemsDone must read as unknown, not as a number.'}
        }
        # The production reader (job card) keeps the card instead of swallowing the exception.
        $workspaceP=Join-Path $Root 'progress-ws';[void][IO.Directory]::CreateDirectory($workspaceP);$pairP=[Guid]::NewGuid().ToString('D');$opP=[Guid]::NewGuid().ToString('D')
        $onDisk=[ordered]@{};foreach($key in $rawBase.Keys){$onDisk[$key]=$rawBase[$key]};$onDisk['OperationId']=$opP;$onDisk['PairId']=$pairP
        Write-WsmWizardBackupProgressFile (Get-WsmWizardBackupProgressPath $workspaceP $pairP $opP) ($onDisk|ConvertTo-Json -Depth 6 -Compress)
        $jobP=@{Record=[pscustomobject]@{action='StartBackup';status='Running';workspace=$workspaceP;pairId=$pairP;jobId=$opP;role='Source'};Path=(Join-Path $workspaceP 'job.json');Handle=$null;PowerShell=$null}
        $card=Get-WsmHtmlBackupProgress $jobP
        Check ($null -ne $card -and [string]$card.State -ceq 'Running') 'R20: the progress card disappeared for a record that lacks ItemsDone and Recent.'
        Write-Host ('PASS: R20 progress view ('+$script:rbChecks+' checks so far).')

        # ====================================== R23: bounded safe file list from one cached read of the verified index ======================================
        $pkgRoot=Join-Path $Root 'pkg-d';[void][IO.Directory]::CreateDirectory($pkgRoot)
        $rlo=[string][char]0x202E;$zwsp=[string][char]0x200B
        $evilNames=@(('evil'+$rlo+'fdp.exe'),'<img src=x onerror=alert(1)>.txt',('zero'+$zwsp+'width.txt'),("line`nbreak.txt"))
        $lines=New-Object 'System.Collections.Generic.List[string]'
        function AddRow([string]$ItemId,[string]$Relative,[bool]$Directory,[long]$Bytes){$lines.Add((ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ItemId=$ItemId;RelativePath=$Relative;Directory=$Directory;Data=$(if($Directory){$null}else{[pscustomobject]@{Bytes=$Bytes}})}) -Depth 6 -Compress))}
        AddRow 'ITEM-A' 'dir' $true 0;for($i=1;$i -le 250;$i++){AddRow 'ITEM-A' ('dir\file-'+$i.ToString('000')+'.txt') $false 10}
        foreach($name in $evilNames){AddRow 'ITEM-B' $name $false 5}
        for($i=1;$i -le 100;$i++){AddRow 'ITEM-C' ('c\f'+$i+'.bin') $false 1}
        for($i=1;$i -le 101;$i++){AddRow 'ITEM-D' ('d\f'+$i+'.bin') $false 1}
        AddRow 'ITEM-E' ('x'*400) $false 1
        [IO.File]::WriteAllText((Join-Path $pkgRoot 'artifacts.jsonl'),(($lines.ToArray()) -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
        $indexHash=(Get-FileHash -LiteralPath (Join-Path $pkgRoot 'artifacts.jsonl') -Algorithm SHA256).Hash.ToLowerInvariant()
        $packageRecord=[pscustomobject]@{ManifestHash=$mh;Package=[pscustomobject]@{Root=$pkgRoot;Manifest=[pscustomobject]@{ArtifactsHash=$indexHash};Plan=$null}}
        $script:rbReads=0;$script:rbOriginalRead=(Get-Command Read-WsmArtifactLines -CommandType Function).ScriptBlock
        function Read-WsmArtifactLines {$script:rbReads++;& $script:rbOriginalRead @args}
        try{
            $totals=Get-WsmWizardTargetArtifactTotals $packageRecord
            Check ($totals['ITEM-A'].Files -eq 250 -and $totals['ITEM-A'].Bytes -eq 2500) 'R23: the existing file and byte totals changed.'
            $itemFor={param($id)[pscustomobject]@{ItemId=$id;Name=('Item '+$id);Kind='DataRoot';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope'}}}
            $context=[pscustomobject]@{Plan=[pscustomobject]@{Items=@('ITEM-A','ITEM-B','ITEM-C','ITEM-D','ITEM-E'|ForEach-Object {& $itemFor $_})}}
            $options=@(Get-WsmWizardTargetItemOptions $context $packageRecord $null)
            $byId=@{};foreach($option in $options){$byId[[string]$option.value]=$option}
            $a=$byId['ITEM-A'];Check ($a.fileCount -eq 250 -and @($a.fileList).Count -eq 100 -and [long]$a.fileListMore -eq 150 -and [string]$a.fileList[0] -ceq 'dir\file-001.txt' -and [string]$a.fileList[99] -ceq 'dir\file-100.txt') 'R23: item A (250 files) must list the first 100 files and report 150 more; directory rows are not files.'
            Check (@($a.fileList|Where-Object {[string]$_ -ceq 'dir'}).Count -eq 0) 'R23: a directory row was listed as a file.'
            $c=$byId['ITEM-C'];Check (@($c.fileList).Count -eq 100 -and [long]$c.fileListMore -eq 0) 'R23: exactly 100 files must list all of them with nothing more.'
            $d=$byId['ITEM-D'];Check (@($d.fileList).Count -eq 100 -and [long]$d.fileListMore -eq 1) 'R23: 101 files must list 100 and report 1 more.'
            $b=$byId['ITEM-B'];Check (@($b.fileList).Count -eq 4 -and [long]$b.fileListMore -eq 0) 'R23: item B must list its four files.'
            foreach($entry in @($b.fileList)){foreach($char in ([string]$entry).ToCharArray()){$category=[Globalization.CharUnicodeInfo]::GetUnicodeCategory($char);Check ($category -ne [Globalization.UnicodeCategory]::Control -and $category -ne [Globalization.UnicodeCategory]::Format -and $category -ne [Globalization.UnicodeCategory]::LineSeparator -and $category -ne [Globalization.UnicodeCategory]::ParagraphSeparator) 'R23: a control or bidi character reached the file list.'}}
            Check (([string]$b.fileList[0]).Contains('\u202E') -and ([string]$b.fileList[1]) -ceq '<img src=x onerror=alert(1)>.txt' -and ([string]$b.fileList[2]).Contains('\u200B') -and ([string]$b.fileList[3]).Contains('\u000A')) 'R23: unsafe characters are not shown as visible escapes (markup stays plain data for textContent).'
            foreach($i in 0..3){Check ([string]$b.fileList[$i] -ceq [string](ConvertTo-WsmBackupSafePathText $evilNames[$i] 260).text) 'R23: the file list does not use the shared path display rule.'}
            $e=$byId['ITEM-E'];Check (([string]$e.fileList[0]).EndsWith('…（已截斷）') -and ([string]$e.fileList[0]).Length -lt 300) 'R23: an over-long path was cut silently instead of being marked as truncated.'
            # One read for the totals call and the options call, and again none for further calls (the verified index is keyed by its hash).
            Check ($script:rbReads -eq 1) ('R23: the artifact index was read '+$script:rbReads+' times for two calls; it must be one cached read.')
            [void](Get-WsmWizardTargetItemOptions $context $packageRecord $null);[void](Get-WsmWizardTargetArtifactTotals $packageRecord)
            Check ($script:rbReads -eq 1) 'R23: a repeated call re-read the whole index.'
            # A different index hash is a different cache entry and is verified again (a changed file is refused by the hash check).
            $otherRoot=Join-Path $Root 'pkg-d2';[void][IO.Directory]::CreateDirectory($otherRoot);$otherLines=@((ConvertTo-Json -InputObject ([pscustomobject][ordered]@{ItemId='ITEM-A';RelativePath='only.txt';Directory=$false;Data=[pscustomobject]@{Bytes=1}}) -Depth 6 -Compress))
            [IO.File]::WriteAllText((Join-Path $otherRoot 'artifacts.jsonl'),($otherLines -join "`n")+"`n",(New-Object Text.UTF8Encoding($false)))
            $otherRecord=[pscustomobject]@{ManifestHash=$mh;Package=[pscustomobject]@{Root=$otherRoot;Manifest=[pscustomobject]@{ArtifactsHash=(Get-FileHash -LiteralPath (Join-Path $otherRoot 'artifacts.jsonl') -Algorithm SHA256).Hash.ToLowerInvariant()};Plan=$null}}
            $otherTotals=Get-WsmWizardTargetArtifactTotals $otherRecord
            Check ($script:rbReads -eq 2 -and $otherTotals['ITEM-A'].Files -eq 1 -and @($otherTotals['ITEM-A'].Paths).Count -eq 1) 'R23: another package index was served from the cache or mis-read.'
            $wrongHash=[pscustomobject]@{ManifestHash=$mh;Package=[pscustomobject]@{Root=$otherRoot;Manifest=[pscustomobject]@{ArtifactsHash=('0'*64)};Plan=$null}}
            Reject {Get-WsmWizardTargetArtifactTotals $wrongHash} 'R23: an index that does not match the trusted hash was accepted.' 'changed before use'
            # The closed HTML projection forwards the new fields.
            $projected=ConvertTo-WsmWizardHtmlValue $a
            Check (@($projected.fileList).Count -eq 100 -and [long]$projected.fileListMore -eq 150) 'R23: the closed projection dropped fileList / fileListMore.'
        }finally{Remove-Item -Path Function:\Read-WsmArtifactLines -ErrorAction SilentlyContinue}
        Write-Host ('PASS: restore receipt compatibility ('+$script:rbChecks+' checks): receipt Sequence/legacy ordering and retry binding, rolled-back retry judgement, legacy RestoreAttempt without Status under strict mode, progress records without ItemsDone/Recent, bounded safe cached restore file list.')
    } $root $srcRoot
} finally {
    if($root -and [IO.Directory]::Exists($root)){try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Test cleanup could not remove '+$root+': '+$_.Exception.Message)}}
}
