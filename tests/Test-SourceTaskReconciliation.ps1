#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wsm-source-task-'+[Guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        . (Join-Path $PSScriptRoot '..\tests\ExternalReadinessEvidenceFixtures.ps1')
        $script:sourceFixture=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source';OS='Fixture Server';Version='10.fixture'}
        $script:fixtureFingerprint='a'*64
        $script:fixtureRevision=0
        $script:fixtureTask=[pscustomobject]@{TaskName='FixtureTask';TaskPath='\Fixture\';Xml='<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="Author"><UserId>SYSTEM</UserId><LogonType>ServiceAccount</LogonType></Principal></Principals><Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers><Settings><Enabled>true</Enabled><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy></Settings><Actions><Exec><Command>C:\Fixture\worker.exe</Command></Exec></Actions></Task>';Enabled=$true;Running=$true}
        $script:enableCalls=0;$script:disableCalls=0;$script:startCalls=0
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture';OS='Fixture Server';Version='10.fixture';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)if($TaskName -cne $script:fixtureTask.TaskName -or $TaskPath -cne $script:fixtureTask.TaskPath){throw 'Unexpected fixture task query'};[pscustomobject]@{TaskName=$script:fixtureTask.TaskName;TaskPath=$script:fixtureTask.TaskPath;Settings=[pscustomobject]@{Enabled=$script:fixtureTask.Enabled};State=$(if($script:fixtureTask.Running){'Running'}else{'Ready'})}}
        function script:Disable-ScheduledTask {param($TaskName,$TaskPath)$script:disableCalls++;$script:fixtureTask.Enabled=$false}
        function script:Enable-ScheduledTask {param($TaskName,$TaskPath)$script:enableCalls++;$script:fixtureTask.Enabled=$true}
        function script:Start-ScheduledTask {param($TaskName,$TaskPath)$script:startCalls++;$script:fixtureTask.Running=$true}
        function script:Export-WsmInventory {
            param($OutputDirectory,[switch]$DeepDiscovery)
            $script:fixtureRevision++
            $settings=[ordered]@{TaskName=$script:fixtureTask.TaskName;TaskPath=$script:fixtureTask.TaskPath;Xml=$script:fixtureTask.Xml;TaskSecurityCaptureStatus='ReviewRequired'}
            $item=New-WsmItem $script:sourceFixture.HostId Tasks ScheduledTask 'Fixture scheduled task' ($script:fixtureTask.TaskPath+$script:fixtureTask.TaskName) $settings
            $inventory=New-WsmInventory $script:sourceFixture $script:fixtureRevision @($item)
            $path=Join-Path $OutputDirectory ('inventory-'+$script:fixtureRevision+'.json')
            Write-WsmJson $path $inventory
            [pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}
        }
        function New-TaskFixtureCase {
            param([string]$Name,[bool]$InitiallyRunning)
            $script:fixtureTask.Enabled=$true;$script:fixtureTask.Running=$InitiallyRunning;$script:fixtureRevision=0;$script:enableCalls=0;$script:disableCalls=0;$script:startCalls=0
            $caseRoot=Join-Path $Root $Name;[void][IO.Directory]::CreateDirectory($caseRoot)
            $workspace=Join-Path $caseRoot 'manager';$state=Join-Path $caseRoot 'source-state';[void][IO.Directory]::CreateDirectory($state);Initialize-WsmWorkspace $workspace | Out-Null
            $first=Export-WsmInventory $state;$catalog=Import-WsmInventory $workspace $first.Path $first.SHA256 ('fixture-target-'+$Name)
            $item=$catalog.Items[0]
            $spec=[pscustomobject]@{
                Adapter='ScheduledTask';CatchUpPolicy='PreserveSourceSettings';DesiredFinalState='Enabled';Owner='Fixture task owner';Evidence='fixture://task/review';BusinessChecks=@('owner confirms staged task data')
                Desired=[pscustomobject]@{TaskName='FixtureTask';TaskPath='\Fixture\';Xml=$script:fixtureTask.Xml;User='SYSTEM';SecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';FolderSecurity=@([pscustomobject]@{Path='\';SecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';ExistingPolicy='VerifyExact'},[pscustomobject]@{Path='\Fixture\';SecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';ExistingPolicy='CreateOnly'})}
            }
            $specPath=Join-Path $caseRoot 'spec.json';[IO.File]::WriteAllText($specPath,($spec | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
            Set-WsmMigrationSpec $workspace $catalog.PairId $item.ItemId $specPath (Get-FileHash -LiteralPath $specPath).Hash $catalog.DecisionRevision
            $catalog=Get-WsmCatalog $workspace $catalog.PairId
            Set-WsmDecision $workspace $catalog.PairId @($item.ItemId) Include 'fixture task review' $catalog.DecisionRevision | Out-Null
            $catalog=Get-WsmCatalog $workspace $catalog.PairId
            $target=[pscustomobject]@{SchemaVersion=1;ToolVersion='0.3.0';Kind='TargetIdentity';HostId=[Guid]::NewGuid().ToString();Fingerprint=(Get-WsmHashText ('target-'+$Name));Name=('fixture-target-'+$Name)}
            $targetPath=Join-Path $caseRoot 'target.json';[IO.File]::WriteAllText($targetPath,($target | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
            $planPath=Join-Path $caseRoot 'plan.json';$approval=Approve-WsmMigrationPlan $workspace $catalog.PairId $targetPath (Get-FileHash -LiteralPath $targetPath).Hash $planPath $catalog.DecisionRevision 'ISOLATED-PILOT'
            $approvedPlan=Read-WsmMigrationPlan $planPath $approval.SHA256;$freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $approvedPlan -PlanHash $approval.SHA256 -Root $caseRoot -Owner 'Fixture task owner'
            [pscustomobject]@{Root=$caseRoot;Workspace=$workspace;SourceState=$state;PairId=$catalog.PairId;Item=$item;PlanPath=$planPath;PlanHash=$approval.SHA256;AttemptPath=(Join-Path $caseRoot 'freeze.json');FreezeProof=$freezeProof}
        }
        function New-TaskReconciliationProof($Case,$AttemptHash,[string]$Outcome='Reconciled') {
            $attempt=Read-WsmJson $Case.AttemptPath;$utc=[DateTime]::UtcNow.ToString('o')
            [pscustomobject]@{
                SchemaVersion=1;ToolVersion='0.3.0';Kind='SourceTaskReconciliation';PairId=$Case.PairId;PlanHash=$Case.PlanHash;OriginalBaselineHash=$attempt.BaselineHash;SourceAttemptHash=$AttemptHash;Owner='Fixture task owner';Utc=$utc
                Items=@([pscustomobject]@{ItemId=$Case.Item.ItemId;TaskId='\Fixture\FixtureTask';Outcome=$Outcome;Owner='Fixture task owner';Evidence='fixture://owner/task-work-reconciled';Utc=$utc})
            }
        }
        function Get-TestSourceStateFingerprint([string]$Path) {
            return (@(Get-ChildItem -LiteralPath $Path -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n")
        }

        $runningCase=New-TaskFixtureCase 'running-original' $true
        $freezeFailed=$false;$freezeError=''
        try{Export-WsmFreezeRecord $runningCase.PlanPath $runningCase.PlanHash $runningCase.AttemptPath 'Fixture task owner' 'fixture task quiescence review' OWNER-CONFIRMED-QUIESCENCE -SourceStateDirectory $runningCase.SourceState -FreezeExternalEvidencePath $runningCase.FreezeProof.Path -FreezeExternalEvidenceHash $runningCase.FreezeProof.SHA256 -FreezeEpoch $runningCase.FreezeProof.FreezeEpoch | Out-Null}catch{$freezeFailed=$true;$freezeError=$_.Exception.Message}
        $interruptedAttempts=@(Get-ChildItem -LiteralPath $runningCase.SourceState -Filter attempt.json -Recurse)
        if(-not $freezeFailed -or $interruptedAttempts.Count -ne 1){throw ('Running-task freeze interruption did not retain the original source attempt. '+$freezeError)}
        $runningCase.AttemptPath=$interruptedAttempts[0].FullName
        $attempt=Read-WsmJson $runningCase.AttemptPath
        if($attempt.Status -ne 'Interrupted' -or @($attempt.Items | Where-Object {$_.ItemId -ceq $runningCase.Item.ItemId -and $_.OriginalRuntime.Running}).Count -ne 1 -or $script:fixtureTask.Enabled){throw 'Interrupted task attempt did not preserve the originally running task and disabled scheduler state.'}
        $script:fixtureTask.Running=$false # Represents separately completed owner reconciliation; no scheduler API is called.
        $attemptHash=(Get-FileHash -LiteralPath $runningCase.AttemptPath).Hash
        $approvedPlan=Read-WsmMigrationPlan $runningCase.PlanPath $runningCase.PlanHash;$resumeProof=New-WsmSourceResumeEvidenceFixture -Plan $approvedPlan -PlanHash $runningCase.PlanHash -AttemptId $attempt.AttemptId -AttemptHash $attemptHash -Root $runningCase.Root -Owner 'Fixture task owner'
        $sourceStateBefore=Get-TestSourceStateFingerprint $runningCase.SourceState

        $templatePath=Join-Path $runningCase.Root 'task-reconciliation-draft.json'
        $templateResult=Export-WsmSourceTaskReconciliationTemplate $runningCase.PlanPath $runningCase.PlanHash $runningCase.AttemptPath $attemptHash $templatePath
        $draft=Read-WsmTrustedJson $templatePath $templateResult.SHA256
        if(-not $templateResult.Draft -or $templateResult.ResumeReady -or -not $templateResult.OwnerReviewRequired -or -not $templateResult.TaskProofRequired -or $draft.Kind -cne 'SourceTaskReconciliation' -or $draft.PlanHash -ine $runningCase.PlanHash -or $draft.PairId -cne $runningCase.PairId -or $draft.SourceAttemptHash -ine $attemptHash -or $draft.OriginalBaselineHash -ine $attempt.BaselineHash -or @($draft.Items).Count -ne 1 -or $draft.Items[0].TaskId -cne '\Fixture\FixtureTask' -or $draft.Items[0].Outcome -cne 'ReviewRequired' -or $draft.Items[0].Evidence -or $draft.Items[0].Owner){throw 'Task reconciliation template lacks exact bindings or is not an owner-required draft.'}

        $missingBlocked=$false
        try{Invoke-WsmSourceResume $runningCase.PlanPath $runningCase.PlanHash $runningCase.AttemptPath $attemptHash $runningCase.SourceState 'Fixture task owner' 'fixture target stopped and data reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$runningCase.PairId) -ResumeExternalEvidencePath $resumeProof.Path -ResumeExternalEvidenceHash $resumeProof.SHA256 | Out-Null}catch{$missingBlocked=$true}
        if(-not $missingBlocked -or $script:enableCalls -ne 0 -or $script:fixtureTask.Enabled -or (Get-TestSourceStateFingerprint $runningCase.SourceState) -cne $sourceStateBefore){throw 'Resume without running-task reconciliation evidence changed source scheduler or durable state.'}

        $draftBlocked=$false
        try{Invoke-WsmSourceResume $runningCase.PlanPath $runningCase.PlanHash $runningCase.AttemptPath $attemptHash $runningCase.SourceState 'Fixture task owner' 'fixture target stopped and data reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$runningCase.PairId) -TaskReconciliationPath $templatePath -TaskReconciliationHash $templateResult.SHA256 -ResumeExternalEvidencePath $resumeProof.Path -ResumeExternalEvidenceHash $resumeProof.SHA256 | Out-Null}catch{$draftBlocked=$true}
        if(-not $draftBlocked -or $script:enableCalls -ne 0 -or $script:fixtureTask.Enabled -or (Get-TestSourceStateFingerprint $runningCase.SourceState) -cne $sourceStateBefore){throw 'Unreviewed task reconciliation template was accepted or changed source state.'}

        $wrongProof=New-TaskReconciliationProof $runningCase $attemptHash
        $wrongProof.PlanHash='F'*64
        $wrongProofPath=Join-Path $runningCase.Root 'wrong-reconciliation.json';Write-WsmJson $wrongProofPath $wrongProof;$wrongProofHash=(Get-FileHash -LiteralPath $wrongProofPath).Hash
        $wrongBlocked=$false
        try{Invoke-WsmSourceResume $runningCase.PlanPath $runningCase.PlanHash $runningCase.AttemptPath $attemptHash $runningCase.SourceState 'Fixture task owner' 'fixture target stopped and data reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$runningCase.PairId) -TaskReconciliationPath $wrongProofPath -TaskReconciliationHash $wrongProofHash -ResumeExternalEvidencePath $resumeProof.Path -ResumeExternalEvidenceHash $resumeProof.SHA256 | Out-Null}catch{$wrongBlocked=$true}
        if(-not $wrongBlocked -or $script:enableCalls -ne 0 -or $script:fixtureTask.Enabled -or (Get-TestSourceStateFingerprint $runningCase.SourceState) -cne $sourceStateBefore){throw 'Resume with a reconciliation proof bound to the wrong plan changed source state.'}

        $wrongAttemptProof=New-TaskReconciliationProof $runningCase $attemptHash
        $wrongAttemptProof.SourceAttemptHash='0'*64
        $wrongAttemptPath=Join-Path $runningCase.Root 'wrong-attempt-reconciliation.json';Write-WsmJson $wrongAttemptPath $wrongAttemptProof;$wrongAttemptHash=(Get-FileHash -LiteralPath $wrongAttemptPath).Hash
        $wrongAttemptBlocked=$false
        try{Invoke-WsmSourceResume $runningCase.PlanPath $runningCase.PlanHash $runningCase.AttemptPath $attemptHash $runningCase.SourceState 'Fixture task owner' 'fixture target stopped and data reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$runningCase.PairId) -TaskReconciliationPath $wrongAttemptPath -TaskReconciliationHash $wrongAttemptHash -ResumeExternalEvidencePath $resumeProof.Path -ResumeExternalEvidenceHash $resumeProof.SHA256 | Out-Null}catch{$wrongAttemptBlocked=$true}
        if(-not $wrongAttemptBlocked -or $script:enableCalls -ne 0 -or $script:fixtureTask.Enabled -or (Get-TestSourceStateFingerprint $runningCase.SourceState) -cne $sourceStateBefore){throw 'Resume with a reconciliation proof bound to the wrong attempt changed source state.'}

        $validProof=$draft
        $proofUtc=[DateTime]::UtcNow.ToString('o')
        $validProof.Owner='Fixture task owner';$validProof.Utc=$proofUtc
        $validProof.Items[0].Outcome='NoPendingWork';$validProof.Items[0].Owner='Fixture task owner';$validProof.Items[0].Evidence='fixture://owner/task-work-reconciled';$validProof.Items[0].Utc=$proofUtc
        $validProofPath=Join-Path $runningCase.Root 'task-reconciliation.json';Write-WsmJson $validProofPath $validProof;$validProofHash=(Get-FileHash -LiteralPath $validProofPath).Hash
        $resumed=Invoke-WsmSourceResume $runningCase.PlanPath $runningCase.PlanHash $runningCase.AttemptPath $attemptHash $runningCase.SourceState 'Fixture task owner' 'fixture target stopped and data reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$runningCase.PairId) -TaskReconciliationPath $validProofPath -TaskReconciliationHash $validProofHash -ResumeExternalEvidencePath $resumeProof.Path -ResumeExternalEvidenceHash $resumeProof.SHA256
        $durable=Read-WsmJson $runningCase.AttemptPath
        if($resumed.Status -ne 'SourceResumed' -or $resumed.TaskProcessStateRestored -ne $false -or $resumed.TaskReconciliationSHA256 -ine $validProofHash -or $durable.TaskProcessStateRestored -ne $false -or $durable.TaskReconciliationSHA256 -ine $validProofHash -or -not $script:fixtureTask.Enabled -or $script:fixtureTask.Running -or $script:startCalls -ne 0){throw 'Valid task reconciliation did not resume scheduler enablement while accurately leaving task process state unrestored.'}

        $notRunningCase=New-TaskFixtureCase 'not-running-original' $false
        $notRunningFreeze=Export-WsmFreezeRecord $notRunningCase.PlanPath $notRunningCase.PlanHash $notRunningCase.AttemptPath 'Fixture task owner' 'fixture task quiescence review' OWNER-CONFIRMED-QUIESCENCE -SourceStateDirectory $notRunningCase.SourceState -FreezeExternalEvidencePath $notRunningCase.FreezeProof.Path -FreezeExternalEvidenceHash $notRunningCase.FreezeProof.SHA256 -FreezeEpoch $notRunningCase.FreezeProof.FreezeEpoch
        $emptyTemplatePath=Join-Path $notRunningCase.Root 'empty-task-reconciliation-draft.json'
        $emptyTemplate=Export-WsmSourceTaskReconciliationTemplate $notRunningCase.PlanPath $notRunningCase.PlanHash $notRunningFreeze.SourceAttemptPath $notRunningFreeze.SourceAttemptHash $emptyTemplatePath
        $emptyDraft=Read-WsmTrustedJson $emptyTemplatePath $emptyTemplate.SHA256
        if($emptyTemplate.TaskProofRequired -or $emptyTemplate.OriginallyRunningTaskCount -ne 0 -or @($emptyDraft.Items).Count -ne 0 -or $emptyTemplate.ResumeReady){throw 'Task reconciliation template incorrectly required task proof when no included task was originally running.'}
        $script:fixtureTask.Running=$true # Unexpected process state appears after freeze; resume must stop before enabling.
        $unexpectedBlocked=$false
        $notRunningAttempt=Read-WsmJson $notRunningFreeze.SourceAttemptPath;$notRunningPlan=Read-WsmMigrationPlan $notRunningCase.PlanPath $notRunningCase.PlanHash;$notRunningResumeProof=New-WsmSourceResumeEvidenceFixture -Plan $notRunningPlan -PlanHash $notRunningCase.PlanHash -AttemptId $notRunningAttempt.AttemptId -AttemptHash $notRunningFreeze.SourceAttemptHash -Root $notRunningCase.Root -Owner 'Fixture task owner'
        try{Invoke-WsmSourceResume $notRunningCase.PlanPath $notRunningCase.PlanHash $notRunningFreeze.SourceAttemptPath $notRunningFreeze.SourceAttemptHash $notRunningCase.SourceState 'Fixture task owner' 'fixture target stopped and data reconciled' ('SOURCE-OWNERSHIP-RESTORED '+$notRunningCase.PairId) -ResumeExternalEvidencePath $notRunningResumeProof.Path -ResumeExternalEvidenceHash $notRunningResumeProof.SHA256 | Out-Null}catch{$unexpectedBlocked=$true}
        if(-not $unexpectedBlocked -or $script:enableCalls -ne 0 -or $script:fixtureTask.Enabled){throw 'Unexpectedly running originally stopped task was changed instead of refusing resume.'}
        Write-Host 'PASS: actual fixture Export-WsmFreezeRecord/Invoke-WsmSourceResume seam binds task reconciliation to plan/pair/baseline/attempt/task/owner/UTC, rejects missing/stale proof before scheduler mutation, restores enablement only and never starts a task. Scheduler and inventory host APIs are fixtures.'
    } $root
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $ownedRoot=[IO.Path]::GetFullPath($root)
    $expectedPrefix=$tempRoot+'\'
    $ownedParent=[IO.Path]::GetDirectoryName($ownedRoot).TrimEnd('\')
    $leaf=[IO.Path]::GetFileName($ownedRoot)
    if(-not $ownedRoot.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not $ownedParent.Equals($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or $leaf -notmatch '^wsm-source-task-[a-f0-9]{32}$'){
        throw 'Test cleanup refused a path outside its exact unique temporary root.'
    }
    if([IO.Directory]::Exists($ownedRoot)){Remove-Item -LiteralPath $ownedRoot -Recurse -Force}
}
