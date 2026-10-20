#requires -Version 5.1
[CmdletBinding()]
param([switch]$BackendIsolated,[ValidateSet('All','Source','Target')][string]$FixtureScope='All')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$runtimePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\WizardRuntime.ps1'))
$outerCommand=Get-Command Get-WsmWizardRuntimeProjection -ErrorAction SilentlyContinue
if(-not $BackendIsolated){
    if(-not $outerCommand){throw 'Required module consumer Get-WsmWizardRuntimeProjection is missing; runtime integration has not been wired.'}
    if($outerCommand.ModuleName -cne $module.Name -or $outerCommand.ScriptBlock.File -ine $runtimePath){throw 'Runtime projection did not resolve to the module-owned WizardRuntime.ps1 implementation.'}
}elseif(-not $outerCommand){
    # This mode verifies only the newly added backend helper before integration.
    # It is deliberately not a full runtime/module acceptance result.
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-runtime-'+[Guid]::NewGuid().ToString('N').Substring(0,10))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$BackendOnly,$RuntimePath,$FixtureScope)
        if($BackendOnly){
            . $RuntimePath
            $inner=Get-Command Get-WsmWizardRuntimeProjection -ErrorAction Stop
            if($inner.ScriptBlock.File -ine $RuntimePath){throw 'Isolated runtime test did not load the requested helper source.'}
        }else{
            $inner=Get-Command Get-WsmWizardRuntimeProjection -ErrorAction Stop
            if($inner.ModuleName -cne $ExecutionContext.SessionState.Module.Name -or $inner.ScriptBlock.File -ine $RuntimePath){throw 'Nested runtime projection did not resolve to the module-owned implementation.'}
        }
        $script:runtimeChecks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:runtimeChecks++}
        function SaveProfileHash([string]$Work){(Get-FileHash -LiteralPath (Join-Path (Join-Path $Work 'workspace-control') 'output-profile.json') -Algorithm SHA256).Hash.ToLowerInvariant()}
        $sourceWork=Join-Path $Root 'source';$targetWork=Join-Path $Root 'target'
        Initialize-WsmOutputWorkspace -WorkRoot $sourceWork -Role Source|Out-Null
        Initialize-WsmOutputWorkspace -WorkRoot $targetWork -Role Target|Out-Null
        $pair=[Guid]::NewGuid().ToString()
        $sourceProfileHash=SaveProfileHash $sourceWork;$targetProfileHash=SaveProfileHash $targetWork
        $sourceStatePath=Get-WsmWizardStatePath $sourceWork $pair Source
        $targetStatePath=Get-WsmWizardStatePath $targetWork $pair Target
        $source=Get-WsmWizardRuntimeProjection -Workspace $sourceWork -PairId $pair -Role Source -Jobs @()
        $target=Get-WsmWizardRuntimeProjection -Workspace $targetWork -PairId $pair -Role Target -Jobs @()
        Check ($source.status -ceq 'NeedsApprovedPlan' -and $source.runtime.plan -eq $null) 'Source without an approved received plan did not remain in NeedsApprovedPlan.'
        Check ($target.status -ceq 'NeedsApprovedPlan' -and $target.runtime.plan -eq $null) 'Target without an approved received plan did not remain in NeedsApprovedPlan.'
        Check (@($target.actions|Where-Object id -ceq 'ImportApprovedPlan').Count -eq 1) 'Target without a plan did not expose the approved-plan import action.'
        Check (-not [IO.File]::Exists($sourceStatePath) -and -not [IO.File]::Exists($targetStatePath)) 'Read-only runtime projection created WizardState as a side effect.'
        Check ((SaveProfileHash $sourceWork) -ceq $sourceProfileHash -and (SaveProfileHash $targetWork) -ceq $targetProfileHash) 'Runtime defaults mutated the enrolled role profile.'
        $contracts=Get-WsmWizardRuntimeActionContracts
        foreach($name in @('StartBackup','IndependentCopy','SourceResume','ImportApprovedPlan','TargetZipImport','TargetDirectoryImport','BackupImpactPreview','ComparisonExport','ComparisonImport','CreateTargetDecisionReceipt','TargetRestorePreview','TargetRestore','TargetValidation','TargetAcceptance','TargetActivation')){
            Check ($contracts.Contains($name)) ('Runtime action contract is missing '+$name+'.')
        }
        foreach($name in @('Owner','Evidence','FreezeAuthorization','Acknowledgement','OwnershipEvidence','Reason','CutoverPlanPath','CutoverPlanHash')){
            foreach($contract in $contracts.Values){Check (@($contract.Defaults) -cnotcontains $name) ('Runtime contract derived explicit human field '+$name+'.')}
        }
        Check ($source.AuthoritativeApproval -eq $false -and $target.AuthoritativeApproval -eq $false -and $source.ProductionVerified -eq $false -and $target.ProductionVerified -eq $false) 'Runtime projection claimed approval or production verification.'
        if($FixtureScope -in @('All','Source')){
        # Exercise Source defaults against the real mutable-plan fixture after
        # its sealed approval has been received. Freeze authorization fields
        # must remain explicit while the action stays available to open that
        # form; the stricter readiness flag remains false until supplied.
        $backupTestPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Test-WizardBackup.ps1'))
        if(-not [IO.File]::Exists($backupTestPath)){throw 'Required real Test-WizardBackup fixture is missing.'}
        $backupSource=[IO.File]::ReadAllText($backupTestPath)
        $backupNeedle='        $freezeReadiness=New-WsmSourceFreezeEvidenceFixture'
        if(-not $backupSource.Contains($backupNeedle)){throw 'Could not locate the mutable-plan point in Test-WizardBackup fixture.'}
        $backupProbe=@'
        $sourceRuntime=Get-WsmWizardRuntimeProjection -Workspace $sourceRoot -PairId $catalog.PairId -Role Source -Jobs @()
        $sourceStart=@($sourceRuntime.actions|Where-Object id -ceq 'StartBackup'|Select-Object -First 1)
        if(-not ($sourceRuntime.runtime.sourceFreeze.required -and @($sourceRuntime.runtime.sourceFreeze.missingEvidence).Count -eq 5 -and $sourceStart.Count -eq 1 -and $sourceStart[0].available -and -not $sourceRuntime.runtime.canStartBackup)){throw 'Source freeze-required plan did not expose the explicit authorization form while remaining not-ready to start.'}
        foreach($field in @('Owner','Evidence','FreezeAuthorization','FreezeExternalEvidencePath','FreezeExternalEvidenceHash')){if(@($sourceStart[0].defaults.PSObject.Properties.Name) -ccontains $field){throw ('Source runtime filled explicit freeze field '+$field+'.')}}
        Write-Host 'PASS: source runtime explicit freeze-authorization form contract.'
'@
        $backupProbePath=Join-Path $PSScriptRoot ('Test-WizardBackup.RuntimeProbe-'+[Guid]::NewGuid().ToString('N')+'.ps1')
        try{
            $backupSource=$backupSource.Replace($backupNeedle,$backupProbe+[Environment]::NewLine+$backupNeedle)
            [IO.File]::WriteAllText($backupProbePath,$backupSource,(New-Object Text.UTF8Encoding($true)))
            $backupOutput=@(& $backupProbePath *>&1)
            if(-not (@($backupOutput|Where-Object {([string]$_) -like 'PASS: source runtime explicit freeze-authorization form contract.'}).Count)){throw ('Real Source backup fixture did not report runtime assertions: '+($backupOutput -join [Environment]::NewLine))}
            $script:runtimeChecks++
        }finally{if([IO.File]::Exists($backupProbePath)){Remove-Item -LiteralPath $backupProbePath -Force}}
        }
        if($FixtureScope -in @('All','Target')){
        # Reuse the production Test-WizardRestore fixture and inject only an
        # assertion at its final point, where real sealed plan, imported package,
        # Target inventory/comparison/receipt, restore and validation artifacts
        # already exist. This keeps the positive runtime path tied to real core
        # products rather than synthetic job data.
        $restoreTestPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Test-WizardRestore.ps1'))
        if(-not [IO.File]::Exists($restoreTestPath)){throw 'Required real Test-WizardRestore fixture is missing.'}
        $restoreSource=[IO.File]::ReadAllText($restoreTestPath)
        $needle="        Write-Host ('PASS: '+`$script:wizardRestoreChecks"
        if(-not $restoreSource.Contains($needle)){throw 'Could not locate the final assertion point in Test-WizardRestore fixture.'}
        $cancelNeedle='        $cancelWizard=Get-WsmWizardProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($cancelResultJob))'
        if(-not $restoreSource.Contains($cancelNeedle)){throw 'Could not locate the real cancelled Target result point in Test-WizardRestore fixture.'}
        $cancelProbe=@'
        $runtimeCancelled=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($cancelResultJob))
        if($runtimeCancelled.runtime.restoreResult.stage -cne 'Cancelled' -or -not $runtimeCancelled.runtime.noAutoResume -or -not $runtimeCancelled.runtime.noAutoActivation -or @($runtimeCancelled.actions|Where-Object id -ceq 'CreateTargetDecisionReceipt'|Where-Object available).Count -ne 1 -or @($runtimeCancelled.actions|Where-Object {$_.id -in @('TargetRestore','TargetValidation','TargetAcceptance','TargetActivation') -and $_.available}).Count){throw 'Runtime did not preserve cancellation as a terminal result with an explicit new-decision route and closed restore/validation/acceptance/activation gates.'}
        Write-Host 'PASS: runtime projection consumed the real durable cancelled Target restore result.'
'@
        $restoreSource=$restoreSource.Replace($cancelNeedle,$cancelProbe+[Environment]::NewLine+$cancelNeedle)
        if($BackendOnly){
            $flowAssertion="        Check (`$cancelWizard.nextStep -ceq 'result' -and -not @(`$cancelWizard.actions|Where-Object {`$_.action -in @('TargetValidation','TargetAcceptance') -and `$_.available}).Count -and @(`$cancelWizard.actions|Where-Object {`$_.action -ceq 'CreateTargetDecisionReceipt' -and `$_.available}).Count -eq 1) 'Cancelled restore did not lead to its result and explicit new-decision route, or unlocked successful validation/acceptance.'"
            if(-not $restoreSource.Contains($flowAssertion)){throw 'Backend-isolated runtime test could not locate the known pending WizardFlow consumer assertion.'}
            $restoreSource=$restoreSource.Replace($flowAssertion,"        # Isolated backend runner omits only the pending public Flow consumer assertion; checked-in source remains strict.")
        }
        $probe=@'
        function ConvertTo-WsmRuntimeHttpJob($Job){$copy=[ordered]@{};foreach($property in $Job.PSObject.Properties){if($property.Name -cne 'outputs'){$copy[$property.Name]=$property.Value}};$copy.outputs=@(Get-WsmHtmlResultProjection @($Job.outputs));[pscustomobject]$copy}
        $runtimeVisibleJobs=@(foreach($runtimeJob in @($allJobs)){ConvertTo-WsmRuntimeHttpJob $runtimeJob})
        $runtimeValidationJob=ConvertTo-WsmRuntimeHttpJob ([pscustomobject]@{action='TargetValidation';status=[string]$stagedValidation.Status;role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@($stagedValidation)})
        $explicitRuntimePreview=Get-WsmWizardTargetRestoreProjection -Workspace $work -PairId $pair -Jobs $allJobs
        $sensitivePreview=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $explicitRuntimePreview -Depth 80 -Compress);if(@($sensitivePreview.Rows).Count){$sensitivePreview.Rows[0].Reason='password=sentinel-secret';$safeSensitivePreview=@(Get-WsmHtmlResultProjection @($sensitivePreview))[0];$previewHashArgs=@($pair,[string]$explicitRuntimePreview.PlanHash,[string]$explicitRuntimePreview.ManifestHash,[long]$explicitRuntimePreview.Generation,[string]$explicitRuntimePreview.ReceiptHash,[string]$explicitRuntimePreview.TargetSnapshotHash,[string]$explicitRuntimePreview.ComparisonHash,[int]$explicitRuntimePreview.ComparisonRevision,[int]$explicitRuntimePreview.SelectionRevision,[string]$explicitRuntimePreview.Decision);$rawPreviewHash=Get-WsmWizardTargetPreviewHash $sensitivePreview @previewHashArgs;$safePreviewHash=Get-WsmWizardTargetPreviewHash $safeSensitivePreview @previewHashArgs;Check ($rawPreviewHash -ceq $safePreviewHash -and -not (ConvertTo-Json -InputObject $safeSensitivePreview -Depth 80 -Compress).Contains('sentinel-secret')) 'PreviewHash did not survive closed HTTP projection with secret-pattern redaction.'}else{throw 'The real Target restore preview fixture has no rows for the safe-projection round-trip check.'}
        $explicitRuntimePreviewJob=ConvertTo-WsmRuntimeHttpJob ([pscustomobject]@{action='TargetRestorePreview';status='Succeeded';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@($explicitRuntimePreview)})
        $runtimeJobs=@($runtimeVisibleJobs)+@(ConvertTo-WsmRuntimeHttpJob $restoreAvailabilityJob)+@($explicitRuntimePreviewJob)+@($runtimeValidationJob)
        $operationPaths=Get-WsmOperationPaths (Join-Path $work 'pairs') $pair
        $journalBeforeRead=(Get-FileHash -LiteralPath $operationPaths.Journal -Algorithm SHA256).Hash.ToLowerInvariant()
        $journalSnapshotRoot=Join-Path $operationPaths.Root 'restore-journals';$journalSnapshotsBefore=@(Get-ChildItem -LiteralPath $journalSnapshotRoot -File|ForEach-Object Name|Sort-Object)
        $runtimeNativeObservationCalls=0;$runtimeNativeObservationOriginal=(Get-Command Get-WsmAssistiveCurrentSoftwareCatalog -ErrorAction Stop).ScriptBlock
        Set-Item Function:script:Get-WsmAssistiveCurrentSoftwareCatalog -Value {param($Snapshot)$script:runtimeNativeObservationCalls++;throw 'Generic runtime GET unexpectedly ran the native current-software observation.'}
        try{
            $runtimeProjection=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $runtimeJobs
            $genericWizardProjection=Get-WsmWizardProjection -Workspace $work -PairId $pair -Role Target -Jobs $runtimeJobs
        }finally{Set-Item Function:\script:Get-WsmAssistiveCurrentSoftwareCatalog -Value $runtimeNativeObservationOriginal}
        Check ((Get-FileHash -LiteralPath $operationPaths.Journal -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $journalBeforeRead) 'Runtime GET mutated the Target journal while projecting acceptance gates.'
        Check ($runtimeNativeObservationCalls -eq 0) 'A GET reran the unbounded native Target software scan instead of returning the exact bounded inventory and requiring explicit revalidation.'
        Check ((@(Get-ChildItem -LiteralPath $journalSnapshotRoot -File|ForEach-Object Name|Sort-Object) -join '|') -ceq ($journalSnapshotsBefore -join '|')) 'A GET created or changed the set of immutable restore-journal snapshots.'
        Check ($genericWizardProjection.results.restore.attemptId -ceq [string]$restored.AttemptOperationId) 'Generic wizard GET did not retain the exact terminal Target result after removing automatic native restore recovery.'
        Check ($runtimeProjection.runtime.package.ManifestHash -ceq $manifestHash -and $runtimeProjection.runtime.plan.hash -ceq $planHash -and $runtimeProjection.runtime.plan.generation -eq 1) 'Runtime projection did not consume the exact real sealed plan and imported package generation.'
        Check ($runtimeProjection.runtime.restorePreview.PreviewHash -ceq [string]$explicitRuntimePreview.PreviewHash -and @($runtimeProjection.actions|Where-Object id -ceq 'TargetRestorePreview'|Where-Object available).Count -eq 1) 'Runtime GET did not consume the exact successful explicit preview job output.'
        Check ($runtimeProjection.runtime.restoreResult -and $runtimeProjection.runtime.restoreResult.attemptId -ceq [string]$restored.AttemptOperationId -and $runtimeProjection.runtime.restoreResult.stage -ceq [string]$restoreAvailability.stage) 'Runtime projection lost the current durable real restore attempt.'
        Check ($runtimeProjection.runtime.mechanicalValidation.available -and $runtimeProjection.runtime.mechanicalValidation.status -ceq $(if($stagedValidation.Passed){'Succeeded'}else{'ReviewRequired'})) 'Runtime projection did not bind the real Staged validation artifact and formal output.'
        Check ($stagedValidation.RestoreAttemptId -ceq [string]$restored.AttemptOperationId -and $stagedValidation.DecisionReceiptHash -match '^[a-f0-9]{64}$' -and $stagedValidation.TargetSnapshotHash -match '^[a-f0-9]{64}$' -and [IO.File]::Exists([string]$stagedValidation.JournalPath)) 'Staged validation output did not carry exact restore-attempt and immutable journal-snapshot bindings.'
        Check (($runtimeProjection.runtime.activation.available -eq [bool]$stagedValidation.Passed) -and (@($runtimeProjection.actions|Where-Object id -ceq 'TargetActivation'|Where-Object available).Count -eq [int][bool]$stagedValidation.Passed) -and -not $runtimeProjection.runtime.businessAcceptance.gates) 'A valid Staged result must expose only the separate activation-review form before business FinalAccepted; it must not claim activation.'
        $blockedValidationJob=[pscustomobject]@{action='TargetValidation';status='Blocked';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@($stagedValidation)}
        $blockedValidationJobs=@($runtimeJobs|Where-Object action -cne 'TargetValidation')+@($blockedValidationJob)
        $blockedValidationProjection=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $blockedValidationJobs
        Check (($blockedValidationProjection.runtime.mechanicalValidation.status -cne 'Succeeded') -and -not $blockedValidationProjection.runtime.activation.available) 'Blocked validation output must not open the separate activation-review form.'
        foreach($field in @('PlanHash','ManifestHash','Generation','Phase','SHA256','JournalHash','RestoreAttemptId','DecisionReceiptHash','TargetSnapshotHash')){
            $badOutput=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $stagedValidation -Depth 60 -Compress)
            switch($field){PlanHash{$badOutput.PlanHash=('0'*64)}ManifestHash{$badOutput.ManifestHash=('0'*64)}Generation{$badOutput.Generation=0}Phase{$badOutput.Phase='Final'}SHA256{$badOutput.SHA256=('0'*64)}JournalHash{$badOutput.JournalHash=('0'*64)}RestoreAttemptId{$badOutput.RestoreAttemptId=[Guid]::NewGuid().ToString()}DecisionReceiptHash{$badOutput.DecisionReceiptHash=('0'*64)}TargetSnapshotHash{$badOutput.TargetSnapshotHash=('0'*64)}}
            $badJob=[pscustomobject]@{action='TargetValidation';status=[string]$stagedValidation.Status;role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@($badOutput)}
            $badProjection=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($allJobs)+@($restoreAvailabilityJob)+@($badJob))
            Check ($badProjection.runtime.mechanicalValidation.status -cne 'Succeeded' -and -not $badProjection.runtime.businessAcceptance.available -and -not $badProjection.runtime.activation.available) ('Runtime accepted a validation result with mismatched '+$field+'.')
        }
        $validationBytes=[IO.File]::ReadAllBytes([string]$stagedValidation.Path)
        try{
            [IO.File]::WriteAllText([string]$stagedValidation.Path,'{}',(New-Object Text.UTF8Encoding($true)))
            $tamperedProjection=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $runtimeJobs
            Check ($tamperedProjection.runtime.mechanicalValidation.status -cne 'Succeeded' -and -not $tamperedProjection.runtime.businessAcceptance.available -and -not $tamperedProjection.runtime.activation.available) 'Runtime accepted tampered validation file bytes.'
        }finally{[IO.File]::WriteAllBytes([string]$stagedValidation.Path,$validationBytes)}
        $journalSnapshotBytes=[IO.File]::ReadAllBytes([string]$stagedValidation.JournalPath)
        try{
            [IO.File]::AppendAllText([string]$stagedValidation.JournalPath,'tampered',(New-Object Text.UTF8Encoding($false)))
            $tamperedSnapshot=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $runtimeJobs
            Check ($tamperedSnapshot.runtime.mechanicalValidation.status -cne 'Succeeded' -and -not $tamperedSnapshot.runtime.activation.available) 'Runtime accepted a modified immutable validation journal snapshot.'
        }finally{[IO.File]::WriteAllBytes([string]$stagedValidation.JournalPath,$journalSnapshotBytes)}
        $acceptance=Get-WsmWizardTargetAcceptanceGates -Workspace $work -PairId $pair -Jobs $allJobs
        $acceptanceJob=ConvertTo-WsmRuntimeHttpJob ([pscustomobject]@{action='TargetAcceptance';status='Succeeded';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@($acceptance)})
        $acceptedJobs=@($runtimeJobs)+@($acceptanceJob)
        $journalAfterAcceptance=(Get-FileHash -LiteralPath $operationPaths.Journal -Algorithm SHA256).Hash.ToLowerInvariant()
        $afterAcceptance=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $acceptedJobs
        Check ($afterAcceptance.runtime.mechanicalValidation.status -ceq $(if($stagedValidation.Passed){'Succeeded'}else{'ReviewRequired'})) 'Final acceptance journal append invalidated the prior exact Staged validation proof.'
        Check (-not $acceptance.FinalAccepted -and $afterAcceptance.runtime.businessAcceptance.gates -and $afterAcceptance.runtime.businessAcceptance.status -ceq [string]$acceptance.Status -and ($afterAcceptance.runtime.activation.available -eq [bool]$stagedValidation.Passed)) 'Runtime must retain ReviewRequired business gates while exposing only the separately gated activation-review form after Staged validation.'
        Check ((Get-FileHash -LiteralPath $operationPaths.Journal -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $journalAfterAcceptance) 'Runtime GET mutated the Target journal after explicit acceptance was persisted.'
        $badAcceptance=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $acceptance -Depth 60 -Compress);$badAcceptance.RestoreAttemptId=[Guid]::NewGuid().ToString()
        $badAcceptanceJob=ConvertTo-WsmRuntimeHttpJob ([pscustomobject]@{action='TargetAcceptance';status='Succeeded';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@($badAcceptance)})
        $badAcceptanceProjection=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($runtimeJobs)+@($badAcceptanceJob))
        Check (-not $badAcceptanceProjection.runtime.businessAcceptance.gates -and ($badAcceptanceProjection.runtime.activation.available -eq [bool]$stagedValidation.Passed)) 'Runtime accepted an acceptance job whose restore attempt binding was stale.'
        $acceptanceBytes=[IO.File]::ReadAllBytes([string]$acceptance.Path)
        try{
            [IO.File]::WriteAllText([string]$acceptance.Path,'{}',(New-Object Text.UTF8Encoding($true)))
            $tamperedAcceptance=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs $acceptedJobs
            Check (-not $tamperedAcceptance.runtime.businessAcceptance.gates -and ($tamperedAcceptance.runtime.activation.available -eq [bool]$stagedValidation.Passed)) 'Runtime accepted modified immutable acceptance-gate artifact bytes.'
        }finally{[IO.File]::WriteAllBytes([string]$acceptance.Path,$acceptanceBytes)}
        Check (-not $runtimeProjection.runtime.plan.AuthoritativeApproval -and -not $runtimeProjection.AuthoritativeApproval -and -not $runtimeProjection.ProductionVerified) 'Target runtime projection fabricated plan authority or production verification.'
        # Controlled post-cutover state observation: no service or network activation.
        $priorStateBytes=[IO.File]::ReadAllBytes($operationPaths.State)
        try{
            $postState=Get-WsmOperationState $operationPaths $validated
            $postState.Stage='PostCutoverValidationRequired'
            $postState.Cutover=[pscustomobject]@{Stage='Activated';PlanHash=('d'*64);NewTransactionsPossible=$true}
            Write-WsmJson $operationPaths.State $postState
            $activationJob=ConvertTo-WsmRuntimeHttpJob ([pscustomobject]@{action='TargetActivation';status='ReviewRequired';role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@([pscustomobject]@{Status='PostCutoverValidationRequired';CutoverStage='Activated';CutoverPlanHash=('d'*64);PairId=$pair;PlanHash=$planHash;ManifestHash=$manifestHash;Generation=1})})
            $postProjection=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($acceptedJobs)+@($activationJob))
            Check ($postProjection.runtime.restoreResult.attemptId -ceq $restored.AttemptOperationId -and $postProjection.status -ceq 'PostCutoverValidationRequired') 'Exact restore history disappeared after the controlled activated-state transition.'
            Check (-not @($postProjection.actions|Where-Object {$_.id -in @('TargetRestore','TargetActivation') -and $_.available}).Count -and @($postProjection.actions|Where-Object {$_.id -ceq 'TargetValidation' -and $_.defaults.Phase -ceq 'Final'}).Count -eq 1 -and @($postProjection.actions|Where-Object {$_.id -ceq 'TargetAcceptance' -and $_.available}).Count -eq 1) 'Post-cutover projection repeated restore/activation or hid Final validation/acceptance.'
            Check ($postProjection.runtime.mechanicalValidation.status -ceq 'NotRun') 'An earlier Staged validation must not stand in for post-activation Final validation.'
            $postValidation=Invoke-WsmWizardTargetValidation -Workspace $work -PairId $pair -Phase Final -Jobs $allJobs
            $postValidationJob=ConvertTo-WsmRuntimeHttpJob ([pscustomobject]@{action='TargetValidation';status=[string]$postValidation.Status;role='Target';pairId=$pair;workspace=$work;jobId=[Guid]::NewGuid().ToString();outputs=@($postValidation)})
            $postValidated=Get-WsmWizardRuntimeProjection -Workspace $work -PairId $pair -Role Target -Jobs (@($acceptedJobs)+@($activationJob,$postValidationJob))
            Check ($postValidated.runtime.mechanicalValidation.status -ceq [string]$postValidation.Status -and $postValidated.runtime.mechanicalValidation.result.Phase -ceq 'Final' -and -not $postValidated.runtime.activation.available) 'Post-activation Final validation did not read its own exact durable artifact and formal job binding.'

        }finally{[IO.File]::WriteAllBytes($operationPaths.State,$priorStateBytes)}
        Write-Host 'PASS: real runtime projection consumed exact restore and staged-validation fixture products.'
'@
        $restoreProbePath=Join-Path $PSScriptRoot ('Test-WizardRestore.RuntimeProbe-'+[Guid]::NewGuid().ToString('N')+'.ps1')
        try{
            $restoreSource=$restoreSource.Replace($needle,$probe+[Environment]::NewLine+$needle)
            [IO.File]::WriteAllText($restoreProbePath,$restoreSource,(New-Object Text.UTF8Encoding($true)))
            $restoreOutput=@(& $restoreProbePath *>&1)
            $lastExitCodeVariable=Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue;if($lastExitCodeVariable -and [int]$lastExitCodeVariable.Value -ne 0){throw ('Real restore/runtime fixture failed: '+($restoreOutput -join [Environment]::NewLine))}
            if(-not (@($restoreOutput|Where-Object {([string]$_) -like 'PASS: *runtime projection*'}).Count)){throw ('Real restore fixture did not report runtime assertions: '+($restoreOutput -join [Environment]::NewLine))}
            $script:runtimeChecks++
        }finally{if([IO.File]::Exists($restoreProbePath)){Remove-Item -LiteralPath $restoreProbePath -Force}}
        }
        if($BackendOnly){Write-Output ('ISOLATED BACKEND-ONLY checks passed for fixture scope '+$FixtureScope+': '+$script:runtimeChecks+'; module/action/flow integration is not verified.')}else{Write-Output ('Wizard runtime module contract checks passed for fixture scope '+$FixtureScope+': '+$script:runtimeChecks)}
    } $root ([bool]$BackendIsolated) $runtimePath $FixtureScope
}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
