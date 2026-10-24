#requires -Version 5.1
# S1／S2（第六輪終檢 P1）：文字端 job 狀態白名單與舊作業紀錄相容。
# S1：HTML 寫出的每一種 status（含 WaitingForInput）文字端都讀得回來，RESUME／TAKEOVER 不被歷史讀取擋住；白名單只有一份。
# S2：舊紀錄缺 CompletedUtc／outputs 時 Recover 不中斷、Interrupted 的 CompletedUtc 為 null（文字端與 HTML 端一致），WizardFlow 讀取不丟例外。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$srcRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-jobcompat-'+[Guid]::NewGuid().ToString('N'))
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Generated job compatibility test root unexpectedly already exists.'}
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($root,$srcRoot)
        Set-StrictMode -Version Latest
        $script:checks=0
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Reject([scriptblock]$action,[string]$message){$rejected=$false;try{& $action|Out-Null}catch{$rejected=$true};Check $rejected $message}
        function New-Workspace([string]$Name){$w=Join-Path $root $Name;[void][IO.Directory]::CreateDirectory((Join-Path $w 'console-jobs'));$w}
        function Write-HtmlFormatJob([string]$Workspace,[string]$PairId,[string]$Role,[string]$Action,[string]$Status,[string]$JobId=''){
            # 與 HtmlConsole 寫出的 durable 紀錄同形（含 idempotencyKey／RequestHash／sessionId 等欄位），CompletedUtc 與 outputs 齊全。
            if(-not $JobId){$JobId=[Guid]::NewGuid().ToString('D')}
            $record=[pscustomobject][ordered]@{jobId=$JobId;action=$Action;idempotencyKey=[Guid]::NewGuid().ToString('D');RequestHash=('a'*64);Actor='fixture';workspace=[IO.Path]::GetFullPath($Workspace);pairId=$PairId;role=$Role;sessionId='s';contextId='c';startedRevision=1;startedDecisionRevision=1;startedSelectionRevision=1;startedDataVersion=1;status=$Status;StartedUtc=(Get-WsmUtc);CompletedUtc=$null;canCancel=$false;outputs=@()}
            Write-WsmJson (Join-Path (Join-Path $Workspace 'console-jobs') ($JobId+'.json')) $record
            $JobId
        }
        function Write-LegacyJob([string]$Workspace,[string]$PairId,[string]$Role,[string]$Status){
            # 舊紀錄：沒有 CompletedUtc 與 outputs 兩個屬性。
            $id=[Guid]::NewGuid().ToString('D')
            $record=[pscustomobject][ordered]@{jobId=$id;operationId=$id;action='WizardRuntimeProjection';status=$Status;role=$Role;workspace=[IO.Path]::GetFullPath($Workspace);pairId=$PairId;StartedUtc=(Get-WsmUtc)}
            Write-WsmJson (Join-Path (Join-Path $Workspace 'console-jobs') ($id+'.json')) $record
            $id
        }
        function Job-Path([string]$Workspace,[string]$Id){Join-Path (Join-Path $Workspace 'console-jobs') ($Id+'.json')}
        $pair=[Guid]::NewGuid().ToString('D')

        # ================= S1：單一白名單 =================
        $values=@(Get-WsmJobStatusValues)
        Check ($values.Count -eq @($values|Select-Object -Unique).Count) 'The shared status list contains duplicates.'
        foreach($required in @('Queued','Running','CancelRequested','WaitingForInput','Succeeded','Saved','Completed','Failed','Cancelled','Interrupted','Blocked','ReviewRequired','Deferred')){Check ($values -ccontains $required) ('The shared status list lacks '+$required)}
        # 前端狀態表必須與這份清單相同。
        $consoleJs=[IO.File]::ReadAllText((Join-Path $srcRoot 'ui\console.js'),[Text.Encoding]::UTF8)
        $m=[regex]::Match($consoleJs,"knownStatuses\s*=\s*new Set\(\[([^\]]+)\]\)")
        Check $m.Success 'console.js knownStatuses table was not found.'
        $jsStatuses=@([regex]::Matches($m.Groups[1].Value,"'([A-Za-z]+)'")|ForEach-Object {$_.Groups[1].Value})
        Check ((@($jsStatuses|Sort-Object) -join ',') -ceq (@($values|Sort-Object) -join ',')) ('console.js status table differs from Get-WsmJobStatusValues: '+($jsStatuses -join ',')+' vs '+($values -join ','))
        # 文字端必須用共用清單，而不是自己一份：原始碼只引用函式；行為上，替換共用清單後文字端跟著變。
        $readerText=(Get-Command Get-WsmTextWizardJobs -CommandType Function).ScriptBlock.ToString()
        Check ($readerText -match 'Get-WsmJobStatusValues') 'Get-WsmTextWizardJobs does not use the shared status list.'
        Check ($readerText -notmatch "'CancelRequested'\s*,\s*'Interrupted'") 'Get-WsmTextWizardJobs still carries its own literal status list.'
        $ws1=New-Workspace 'ws-shared'
        $oddId=Write-HtmlFormatJob $ws1 $pair 'Target' 'TargetRestore' 'ZzSharedProbeStatus'
        Reject {Get-WsmTextWizardJobs $ws1 $pair 'Target'} 'A status outside the shared list was accepted by the text reader.'
        $originalValues=(Get-Command Get-WsmJobStatusValues -CommandType Function).ScriptBlock
        try{
            Set-Item Function:\Get-WsmJobStatusValues -Value {@('Running','ZzSharedProbeStatus')}
            $odd=@(Get-WsmTextWizardJobs $ws1 $pair 'Target')
            Check ($odd.Count -eq 1 -and $odd[0].status -ceq 'ZzSharedProbeStatus') 'The text reader did not follow the shared status list.'
        }finally{Set-Item Function:\Get-WsmJobStatusValues -Value $originalValues}

        # HtmlConsole 寫入 Status 的每個位置：由原始碼蒐集後逐一比對。
        $htmlSource=[IO.File]::ReadAllText((Join-Path $srcRoot 'HtmlConsole.ps1'),[Text.Encoding]::UTF8)
        $written=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($rx in @("(?i)\`$(?:job\.)?record\.status\s*=\s*'([A-Za-z]+)'","(?i)\`$Job\.Record\.Status\s*=\s*'([A-Za-z]+)'","(?i)\[string\]\`$Status\s*=\s*'([A-Za-z]+)'")){foreach($hit in [regex]::Matches($htmlSource,$rx)){[void]$written.Add($hit.Groups[1].Value)}}
        foreach($line in ($htmlSource -split "`r?`n")){if($line -match '(?i)\.Status=if\(\$code'){foreach($hit in [regex]::Matches($line,"\{'([A-Za-z]+)'\}")){[void]$written.Add($hit.Groups[1].Value)}}}
        foreach($floor in @('Running','Interrupted','WaitingForInput','Succeeded','Failed','Cancelled','ReviewRequired','CancelRequested')){Check $written.Contains($floor) ('The HtmlConsole status harvest missed a known write: '+$floor+' (harvest is broken).')}
        Check (Test-Path Function:\Get-WsmWorkerFailureStatus) 'Get-WsmWorkerFailureStatus (Failed/Cancelled) is expected to exist.'
        $ws2=New-Workspace 'ws-html'
        foreach($status in @($written|Sort-Object)){
            Check ($values -ccontains $status) ('HtmlConsole writes status '+$status+' which is not in the shared list.')
            $id=Write-HtmlFormatJob $ws2 $pair 'Target' 'TargetRestore' $status
            $read=@(Get-WsmTextWizardJobs $ws2 $pair 'Target'|Where-Object jobId -CEQ $id)
            Check ($read.Count -eq 1 -and $read[0].status -ceq $status) ('The text reader did not read back the HTML-written status '+$status)
        }

        # S1 主情境：HTML 寫入的 WaitingForInput TargetRestore。
        $ws3=New-Workspace 'ws-waiting'
        $waitId=Write-HtmlFormatJob $ws3 $pair 'Target' 'TargetRestore' 'WaitingForInput'
        $history=@(Get-WsmTextWizardJobs $ws3 $pair 'Target')
        Check ($history.Count -eq 1 -and $history[0].status -ceq 'WaitingForInput' -and $history[0].action -ceq 'TargetRestore') 'The text history did not list the WaitingForInput TargetRestore job.'
        $beforeBytes=[IO.File]::ReadAllBytes((Job-Path $ws3 $waitId))
        $guard=Enter-WsmWorkspaceWorkerGuard -Workspace $ws3 -OperationId ([Guid]::NewGuid().ToString('D')) -Role 'Target' -PairId $pair -Action 'GuardFixture'
        try{
            $recovered=@(Recover-WsmTextWizardJobs $ws3 $pair 'Target' $guard)
            Check ($recovered.Count -eq 1 -and $recovered[0].status -ceq 'WaitingForInput') 'Recover changed or dropped a WaitingForInput job (it is durable, waiting for credentials, not a dead worker).'
            Check ([Convert]::ToBase64String($beforeBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Job-Path $ws3 $waitId)))) 'Recover rewrote the WaitingForInput job record.'
            # RESUME：歷史讀取（Recover）成功之後，CLI 續作入口收到 RESUME 並走到 Resume；核心以替身取代，只驗入口沒被歷史讀取擋住。
            $originalPrompt=(Get-Command Read-WsmWizardValue -CommandType Function).ScriptBlock
            $originalPreview=(Get-Command Get-WsmWizardTargetRestoreResumePreview -CommandType Function).ScriptBlock
            $originalResume=(Get-Command Resume-WsmWizardTargetRestore -CommandType Function).ScriptBlock
            $originalTakeover=(Get-Command Takeover-WsmAssistiveServiceCredentialChallenge -CommandType Function).ScriptBlock
            $originalContext=(Get-Command Get-WsmWizardServiceChallengeContext -CommandType Function).ScriptBlock
            try{
                $script:parent=$waitId;$script:prev=('d'*64);$parent=$waitId;$prev=('d'*64)
                $package=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$pair;PlanHash=('b'*64);DecisionRevision=1};SHA256=('a'*64)}
                Set-Item Function:\Get-WsmWizardTargetRestoreResumePreview -Value {param([string]$Workspace,[string]$PairId,[string]$ParentOperationId,$GeneralHostEvidence)[pscustomobject]@{Resumable=$true;PreviewCurrent=$true;ParentOperationId=$script:parent;PendingCount=2;ChallengeState='WaitingForInput';PreviewHash=$script:prev}}
                Set-Item Function:\Resume-WsmWizardTargetRestore -Value {param($Workspace,$PairId,$ParentOperationId,$ContinuationId,$CancellationToken,$Secrets,$GeneralHostEvidence,$ChallengeContext)$script:resumeCalls++;[pscustomobject]@{Status='Succeeded';ParentOperationId=$ParentOperationId}}
                Set-Item Function:\Get-WsmWizardServiceChallengeContext -Value {param($Package,[string]$OperationId)[pscustomobject]@{Role='Target';Actor='NEW-ACTOR';SessionId='NEW-SESSION';ContextId='InteractiveTargetRestore';Revision=1;OperationId=$OperationId}}
                Set-Item Function:\Read-WsmWizardValue -Value {param([string]$Label,[switch]$Optional)$script:prompts+=@($Label);if($Label -match 'TAKEOVER'){'TAKEOVER'}else{'RESUME'}}
                Set-Item Function:\Takeover-WsmAssistiveServiceCredentialChallenge -Value {param($StateDirectory,$PairId,$OperationId,$PreviewHash,$Actor,$SessionId,$ContextId,$Revision,[switch]$ConfirmTakeover)$script:takeovers++;$true}
                $script:resumeCalls=0;$script:takeovers=0;$script:prompts=@()
                $stateDir=Join-Path $root 'pairs';[void][IO.Directory]::CreateDirectory($stateDir)
                $paths=Get-WsmOperationPaths $stateDir $pair;[void][IO.Directory]::CreateDirectory((Split-Path $paths.State -Parent))
                Write-WsmJson $paths.State ([pscustomobject]@{AssistiveServiceChallenge=[pscustomobject]@{State='WaitingForInput';ParentOperationId=$parent;PreviewHash=$prev;Actor='OLD-ACTOR';SessionId='OLD-SESSION';ContextId='InteractiveTargetRestore'}})
                $afterHistory=@(Recover-WsmTextWizardJobs $ws3 $pair 'Target' $guard)
                Check ($afterHistory.Count -eq 1) 'History read before RESUME failed.'
                $flow=Invoke-WsmWizardTargetRestoreResumeFlow $ws3 $stateDir $package @()
                Check ($flow.Status -ceq 'Succeeded' -and $script:resumeCalls -eq 1) 'Typing RESUME did not reach Resume-WsmWizardTargetRestore.'
                Check ($script:takeovers -eq 1 -and @($script:prompts|Where-Object {$_ -match 'TAKEOVER'}).Count -eq 1) 'The TAKEOVER confirmation for the earlier CLI session was not exercised.'
            }finally{
                Set-Item Function:\Read-WsmWizardValue -Value $originalPrompt
                Set-Item Function:\Get-WsmWizardTargetRestoreResumePreview -Value $originalPreview
                Set-Item Function:\Resume-WsmWizardTargetRestore -Value $originalResume
                Set-Item Function:\Takeover-WsmAssistiveServiceCredentialChallenge -Value $originalTakeover
                Set-Item Function:\Get-WsmWizardServiceChallengeContext -Value $originalContext
            }
        }finally{Exit-WsmWorkspaceWorkerGuard $guard}

        # ================= S2：舊紀錄缺欄位 =================
        $ws4=New-Workspace 'ws-legacy-text';$ws5=New-Workspace 'ws-legacy-html'
        $textRunning=Write-LegacyJob $ws4 $pair 'Target' 'Running';$textDone=Write-LegacyJob $ws4 $pair 'Target' 'Succeeded';$textOther=Write-LegacyJob $ws4 $pair 'Target' 'Running'
        $htmlRunning=Write-LegacyJob $ws5 $pair 'Target' 'Running';$htmlDone=Write-LegacyJob $ws5 $pair 'Target' 'Succeeded'
        foreach($pathId in @(@($ws4,$textRunning),@($ws4,$textDone),@($ws5,$htmlRunning))){$raw=Read-WsmJson (Job-Path $pathId[0] $pathId[1]);Check (-not $raw.PSObject.Properties['CompletedUtc'] -and -not $raw.PSObject.Properties['outputs']) 'The legacy fixture unexpectedly carries CompletedUtc or outputs.'}
        $readLegacy=@(Get-WsmTextWizardJobs $ws4 $pair 'Target')
        Check ($readLegacy.Count -eq 3 -and @($readLegacy|Where-Object {@($_.outputs).Count -eq 0}).Count -eq 3) 'The read-only text history rejected or mis-projected legacy records.'
        $textGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $ws4 -OperationId ([Guid]::NewGuid().ToString('D')) -Role 'Target' -PairId $pair -Action 'GuardFixture'
        try{
            $textRecovered=@(Recover-WsmTextWizardJobs $ws4 $pair 'Target' $textGuard)
        }finally{Exit-WsmWorkspaceWorkerGuard $textGuard}
        Check ($textRecovered.Count -eq 3) 'Recover did not return every legacy job.'
        foreach($id in @($textRunning,$textOther)){
            $disk=Read-WsmJson (Job-Path $ws4 $id)
            Check ($disk.status -ceq 'Interrupted' -and $disk.PSObject.Properties['CompletedUtc'] -and $null -eq $disk.CompletedUtc -and $disk.canCancel -eq $false -and $disk.PSObject.Properties['outputs']) 'A legacy Running job was not durably marked Interrupted with a null CompletedUtc.'
            $row=@($textRecovered|Where-Object jobId -CEQ $id)[0];Check ($row.status -ceq 'Interrupted') 'The recovered text row does not report Interrupted.'
        }
        $doneDisk=Read-WsmJson (Job-Path $ws4 $textDone);Check ($doneDisk.status -ceq 'Succeeded') 'Recover changed a legacy Succeeded job.'
        Check (@($textRecovered|Where-Object jobId -CEQ $textDone)[0].status -ceq 'Succeeded') 'The recovered row of the Succeeded job changed.'
        # 文字端與 HTML 端的 Interrupted 結果一致：HTML 匯入同形舊紀錄。
        $htmlGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $ws5 -OperationId ([Guid]::NewGuid().ToString('D')) -Role 'Target' -PairId $pair -Action 'GuardFixture'
        try{
            $jobsTable=@{};$keysTable=@{}
            Import-WsmHtmlJobHistory (Join-Path $ws5 'console-jobs') $jobsTable $keysTable @($htmlGuard)
        }finally{Exit-WsmWorkspaceWorkerGuard $htmlGuard}
        Check ($jobsTable.Count -eq 2) 'The HTML import dropped a legacy record.'
        $htmlDisk=Read-WsmJson (Job-Path $ws5 $htmlRunning);$textDisk=Read-WsmJson (Job-Path $ws4 $textRunning)
        Check ($htmlDisk.status -ceq 'Interrupted' -and $null -eq $htmlDisk.CompletedUtc -and $htmlDisk.PSObject.Properties['CompletedUtc'] -and $htmlDisk.PSObject.Properties['outputs']) 'The HTML import did not mark the legacy Running job Interrupted with a null CompletedUtc.'
        Check ($htmlDisk.status -ceq $textDisk.status -and $null -eq $htmlDisk.CompletedUtc -and $null -eq $textDisk.CompletedUtc -and @($htmlDisk.outputs).Count -eq @($textDisk.outputs).Count) 'Text and HTML Interrupted results differ.'
        Check ($jobsTable[$htmlRunning].Record.PSObject.Properties['outputs'] -and $jobsTable[$htmlDone].Record.PSObject.Properties['CompletedUtc'] -and $jobsTable[$htmlDone].Record.status -ceq 'Succeeded') 'The HTML in-memory legacy records were not normalized.'

        # WizardFlow 三處讀取 job 紀錄：缺 CompletedUtc／outputs 時不丟例外。
        $legacyJob=[pscustomobject][ordered]@{jobId=[Guid]::NewGuid().ToString('D');action='Inventory';status='Succeeded';role='Source';workspace=[IO.Path]::GetFullPath($root);pairId=$pair}
        $profile=[pscustomobject]@{Role='Source';Fingerprint=('c'*64)}
        $none=Get-WsmWizardInventoryFromJobs $root $profile @($legacyJob)
        Check ($null -eq $none -and $legacyJob.PSObject.Properties['outputs']) 'Inventory lookup did not tolerate a job without outputs.'
        $legacyApprove=[pscustomobject][ordered]@{jobId=[Guid]::NewGuid().ToString('D');action='ApproveMigration';status='Succeeded';role='Manager';workspace=[IO.Path]::GetFullPath($root);pairId=$pair}
        $catalog=[pscustomobject]@{Approval=[pscustomobject]@{Kind='MigrationPlan'}}
        [void](Get-WsmWizardCurrentApprovedPlan $root $pair $null $catalog @($legacyApprove))
        Check ($legacyApprove.PSObject.Properties['outputs'] -and $legacyApprove.PSObject.Properties['CompletedUtc']) 'Approved-plan lookup did not normalize a legacy job.'
        $originalReceived=(Get-Command Get-WsmWizardReceivedApprovedPlan -CommandType Function).ScriptBlock
        try{
            Set-Item Function:\Get-WsmWizardReceivedApprovedPlan -Value {param([string]$Workspace,[string]$PairId,$Profile)[pscustomobject]@{Plan=[pscustomobject]@{Items=@()}}}
            $legacyInspect=[pscustomobject][ordered]@{jobId=[Guid]::NewGuid().ToString('D');action='InspectWizardFiles';status='Succeeded';role='Source';workspace=[IO.Path]::GetFullPath($root);pairId=$pair}
            $index=Get-WsmWizardFileDetailIndex $root $pair 'Source' $profile @($legacyInspect)
            Check ($index -is [hashtable] -and $legacyInspect.PSObject.Properties['outputs']) 'File-detail lookup did not tolerate a job without outputs/CompletedUtc.'
        }finally{Set-Item Function:\Get-WsmWizardReceivedApprovedPlan -Value $originalReceived}
        # 正規化 helper 本身：只補缺的、不覆蓋既有值、容忍 null。
        $keep=[pscustomobject]@{CompletedUtc='2026-01-01T00:00:00Z';outputs=@(1,2)};$null=ConvertTo-WsmNormalizedJobRecord $keep
        Check ($keep.CompletedUtc -ceq '2026-01-01T00:00:00Z' -and @($keep.outputs).Count -eq 2) 'Normalization overwrote existing values.'
        Check ($null -eq (ConvertTo-WsmNormalizedJobRecord $null)) 'Normalization of null must return null.'
        Write-Output ('Job record compatibility: '+$script:checks+' checks passed.')
    } $root $srcRoot
} finally {
    if([IO.Directory]::Exists($root)){try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{}}
}
