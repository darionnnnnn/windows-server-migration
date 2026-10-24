#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wst-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:textRuntimeChecks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:textRuntimeChecks++}
        function Find-UnsafePersistedKey($Value) {
            if($null -eq $Value){return @()}
            $found=New-Object 'System.Collections.Generic.List[string]'
            if($Value -is [System.Collections.IDictionary]){foreach($key in $Value.Keys){if([string]$key -match '^(Arguments|Secrets|Password|Credential|SensitivePayload)$'){$found.Add([string]$key)};$found.AddRange([string[]]@(Find-UnsafePersistedKey $Value[$key]))}}
            elseif($Value -is [System.Management.Automation.PSCustomObject]){foreach($property in $Value.PSObject.Properties){if($property.Name -match '^(Arguments|Secrets|Password|Credential|SensitivePayload)$'){$found.Add([string]$property.Name)};$found.AddRange([string[]]@(Find-UnsafePersistedKey $property.Value))}}
            elseif($Value -is [array]){foreach($entry in $Value){$found.AddRange([string[]]@(Find-UnsafePersistedKey $entry))}}
            @($found.ToArray())
        }
        function Reader([string[]]$Answers){$script:textRuntimeAnswers=New-Object 'System.Collections.Queue';$script:textRuntimePrompts=New-Object 'System.Collections.Generic.List[string]';foreach($answer in $Answers){$script:textRuntimeAnswers.Enqueue($answer)};{param($prompt) $script:textRuntimePrompts.Add([string]$prompt);if($script:textRuntimeAnswers.Count -eq 0){throw ('Unexpected prompt: '+$prompt)};[string]$script:textRuntimeAnswers.Dequeue()}}

        # Use only an isolated local Target identity fixture. The schema-3 plan,
        # package validator, directory delivery, importer, durable jobs and runtime
        # consumer all remain real core implementations.
        $script:textRuntimeFingerprint='a'*64
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:textRuntimeFingerprint;Name='text-runtime-target';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        $targetRoot=Join-Path $Root 'tw';$enrollment=Initialize-WsmOutputWorkspace $targetRoot Target;Initialize-WsmWorkspace $targetRoot|Out-Null
        $script:textRuntimeFingerprint=[string]$enrollment.Profile.Fingerprint
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$enrollment.Profile.HostId)) 'target-identity.json'
        Check ([IO.File]::Exists($targetIdentityPath)) 'Target enrollment did not create its identity binding.'

        $pair=[Guid]::NewGuid().ToString('D');$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('b'*64);Name='text-runtime-source';OS='Fixture Server';Version='10.0'}
        $item=New-WsmItem $source.HostId Storage DataRoot 'Manual fixture workload' 'text-runtime-fixture' @{}
        $manualSpec=[pscustomobject][ordered]@{Adapter='ManualWorkflow';Owner='Fixture owner';Evidence='Isolated, non-production manual workflow fixture';Product='Fixture product';Procedure='Owner reviews the fixture package';Artifacts=@();BusinessChecks=@('Confirm the received package identity')}
        $item|Add-Member NoteProperty Decision Include -Force;$item|Add-Member NoteProperty Reason 'Explicit isolated fixture inclusion' -Force;$item|Add-Member NoteProperty Owner $manualSpec.Owner -Force;$item|Add-Member NoteProperty Evidence $manualSpec.Evidence -Force;$item|Add-Member NoteProperty MigrationSpec $manualSpec -Force
        $snapshotPath=Join-Path $Root 'source-inventory.json';[IO.File]::WriteAllText($snapshotPath,'independent source snapshot fixture',(New-Object Text.UTF8Encoding($false)))
        $snapshotHash=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant();$inventoryRevision=1;$selectionRevision=1
        $targetIdentity=Read-WsmJson $targetIdentityPath
        $plan=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion=$script:ToolVersion;Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString('D');PairId=$pair;ApprovalId=[Guid]::NewGuid().ToString('D');Source=$source;Target=[pscustomobject]@{HostId=$enrollment.Profile.HostId;Fingerprint=$enrollment.Profile.Fingerprint;Name=$targetIdentity.Name;OS='Fixture Server';Version='10.0'};InventoryRevision=$inventoryRevision;DecisionRevision=2;InventoryHash=$snapshotHash;ImportedUtc=(Get-WsmUtc);Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);ApprovedUtc=(Get-WsmUtc);Items=@($item);ScopeMode='Assistive'}
        $authority=[pscustomobject][ordered]@{SourceSnapshotReference=[pscustomobject][ordered]@{Reference='source-inventory.json';SHA256=$snapshotHash;InventoryRevision=$inventoryRevision;CreatedUtc=(Get-WsmUtc)};InventoryRevision=$inventoryRevision;SelectionRevision=$selectionRevision;Dispositions=@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Selected=$true;Decision='Include';Reason='Explicit isolated fixture selection'})}
        $plan|Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=$pair;SourceSnapshotHash=$snapshotHash;SourcePolicy='SourceCOnly';SourceSelectionsVersion=$selectionRevision;ApprovedItemIds=@([string]$item.ItemId);MaterialReferences=@();DiscoveryAuthority=$authority}) -Force
        Assert-WsmAssistiveContract $plan MigrationPlan|Out-Null
        $planPath=Join-Path $Root 'approved-plan.json';Write-WsmJson $planPath $plan
        $planHash=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()

        $packageRoot=Join-Path $Root 'sealed-package';[void][IO.Directory]::CreateDirectory($packageRoot);[void][IO.Directory]::CreateDirectory((Join-Path $packageRoot 'payload'))
        [IO.File]::Copy($planPath,(Join-Path $packageRoot 'plan.json'),$false)
        $indexPath=Join-Path $packageRoot 'artifacts.jsonl';[IO.File]::WriteAllText($indexPath,'',(New-Object Text.UTF8Encoding($false)))
        $indexHash=(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString('D');BatchId=$plan.BatchId;PairId=$pair;ApprovalId=$plan.ApprovalId;PlanHash=$planHash;Source=$plan.Source;Target=$plan.Target;InventoryRevision=$inventoryRevision;DecisionRevision=[int]$plan.DecisionRevision;Generation=1;BaseManifestHash='';Final=$false;FreezeHash='';ArtifactsHash=$indexHash;Files=0;Bytes=[long]0;Records=0;ChunkBytes=65536;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot';SourceCollectionProofs=@()}
        $manifestPath=Join-Path $packageRoot 'manifest.json';Write-WsmJson $manifestPath $manifest
        $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $validated=Test-WsmMigrationPackage $manifestPath $manifestHash
        Check ($validated.Valid -and $validated.Manifest.Generation -eq 1 -and $validated.PlanHash -ceq $planHash) 'The real core package validator rejected the sealed zero-file control package.'
        $delivery=Export-WsmDirectoryDelivery -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $Root 'directory-delivery')

        # Explicit APPLY is required; cancellation before it must not import or
        # create an operation record.
        $cancel=Invoke-WsmTypedTextOperation -Workspace $targetRoot -PromptReader (Reader @('2','ImportApprovedPlan',$planPath,$planHash,'','no'))
        Check (-not $cancel.Executed -and $cancel.Status -ceq 'Cancelled') 'Typed plan intake ran without explicit APPLY.'
        Check (-not (Get-WsmWizardReceivedApprovedPlan $targetRoot $pair (Read-WsmOutputProfile $targetRoot))) 'Cancelled typed intake mutated received-plan state.'
        $jobsRoot=Join-Path $targetRoot 'console-jobs'
        Check (-not [IO.Directory]::Exists($jobsRoot) -or @(Get-ChildItem -LiteralPath $jobsRoot -Filter '*.json' -File).Count -eq 0) 'A form cancelled before APPLY wrote an operation record.'

        $actionMap=Get-WsmOperationActions
        Check ($actionMap.NonCTargetHandoffExport -ceq 'Export-WsmWizardNonCTargetHandoff' -and $actionMap.NonCTargetHandoffPreview -ceq 'Get-WsmWizardNonCTargetHandoffPreview' -and $actionMap.NonCTargetHandoffImport -ceq 'Import-WsmWizardNonCTargetHandoff') 'The typed CLI action map omitted a Target Non-C handoff action.'
        Check ((Get-WsmTextActionGroup 'NonCTargetHandoffExport') -ceq 'Manager' -and (Get-WsmTextActionGroup 'NonCTargetHandoffPreview') -ceq 'Target' -and (Get-WsmTextActionGroup 'NonCTargetHandoffImport') -ceq 'Target') 'The typed CLI placed a Target Non-C handoff action under the wrong role.'
        $cancelSource=New-Object Threading.CancellationTokenSource;$cancelSource.Cancel();$cancelException=New-Object OperationCanceledException('wrapped cancellation fixture',$cancelSource.Token);$cancelException.Data['CancellationRequested']=$true
        $wrappedFailure=New-Object Management.Automation.MethodInvocationException('worker EndInvoke wrapper',$cancelException)
        Check ((Get-WsmWorkerFailureStatus $wrappedFailure) -ceq 'Cancelled') 'Wrapped typed cancellation was not classified from the durable CancellationRequested contract.'
        $notRequested=New-Object OperationCanceledException('unconfirmed cancellation fixture')
        Check ((Get-WsmWorkerFailureStatus $notRequested) -ceq 'Failed') 'An unrequested OperationCanceledException was incorrectly classified as Cancelled.'

        # A live process holds the OS-level workspace guard. A second handle is
        # rejected while it is held, read-only history keeps the active status,
        # and guarded recovery only marks that stale record after exclusive
        # ownership is established. Release permits the next worker to enter.
        $workerGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -OperationId ([Guid]::NewGuid().ToString('D')) -Role 'Target' -PairId $pair -Action 'GuardFixture'
        try {
            $overlapRejected=$false
            try{$competingGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -Role 'Target' -PairId $pair -Action 'OverlapFixture';Exit-WsmWorkspaceWorkerGuard $competingGuard}catch{$overlapRejected=$_.Exception.Message -like 'WorkspaceWorkerBusy:*'}
            Check $overlapRejected 'A second live worker acquired the workspace guard concurrently.'
            $probeGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -Role 'Target' -PairId $pair -Action 'DeveloperProbe'
            Check ($probeGuard.Lane -ceq 'DeveloperProbe' -and $probeGuard.Path -cne $workerGuard.Path) 'DeveloperProbe did not acquire its independent workspace lane.'
            $probeOverlapRejected=$false
            try{$competingProbe=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -Role 'Target' -PairId $pair -Action 'DeveloperProbe';Exit-WsmWorkspaceWorkerGuard $competingProbe}catch{$probeOverlapRejected=$_.Exception.Message -like 'WorkspaceWorkerBusy:*'}
            Check $probeOverlapRejected 'Two DeveloperProbe workers acquired the probe lane concurrently.'
            $migrationOverlapRejected=$false
            try{$competingMigration=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -Role 'Target' -PairId $pair -Action 'OtherMigrationAction';Exit-WsmWorkspaceWorkerGuard $competingMigration}catch{$migrationOverlapRejected=$_.Exception.Message -like 'WorkspaceWorkerBusy:*'}
            Check $migrationOverlapRejected 'Two migration workers acquired the migration lane concurrently.'
            Assert-WsmWorkspaceWorkerGuard $probeGuard $targetRoot 'DeveloperProbe'
            $wrongLaneRejected=$false
            try{Assert-WsmWorkspaceWorkerGuard $probeGuard $targetRoot 'Migration'}catch{$wrongLaneRejected=$true}
            Check $wrongLaneRejected 'Guard validation accepted a probe lock as the migration lane.'
            Exit-WsmWorkspaceWorkerGuard $probeGuard
            $probeAfterRelease=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -Role 'Target' -PairId $pair -Action 'DeveloperProbe'
            Check ($probeAfterRelease.Lane -ceq 'DeveloperProbe') 'Releasing one lane did not permit a later probe worker.'
            Exit-WsmWorkspaceWorkerGuard $probeAfterRelease
            $migrationStillHeld=$false
            try{$competingMigration=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -Role 'Target' -PairId $pair -Action 'OtherMigrationAction';Exit-WsmWorkspaceWorkerGuard $competingMigration}catch{$migrationStillHeld=$_.Exception.Message -like 'WorkspaceWorkerBusy:*'}
            Check $migrationStillHeld 'Releasing the probe lane incorrectly released the still-active migration lane.'
            $staleId=[Guid]::NewGuid().ToString('D')
            $staleRecord=[pscustomobject][ordered]@{jobId=$staleId;operationId=$staleId;action='WizardRuntimeProjection';status='Running';role='Target';workspace=[IO.Path]::GetFullPath($targetRoot);pairId=$pair;StartedUtc=(Get-WsmUtc);CompletedUtc=$null;outputs=@()}
            [void](Write-WsmTextJobRecord $targetRoot $staleRecord)
            $readHistory=@(Get-WsmTextWizardJobs $targetRoot $pair 'Target'|Where-Object jobId -CEQ $staleId)
            Check ($readHistory.Count -eq 1 -and $readHistory[0].status -ceq 'Running' -and (Read-WsmJson (Join-Path $jobsRoot ($staleId+'.json'))).status -ceq 'Running') 'A read-only history projection changed a live job to Interrupted.'
            $recoveredHistory=@(Recover-WsmTextWizardJobs $targetRoot $pair 'Target' $workerGuard|Where-Object jobId -CEQ $staleId)
            $recoveredRecord=Read-WsmJson (Join-Path $jobsRoot ($staleId+'.json'))
            Check ($recoveredHistory.Count -eq 1 -and $recoveredHistory[0].status -ceq 'Interrupted' -and $recoveredRecord.status -ceq 'Interrupted' -and $recoveredRecord.canCancel -eq $false) 'Guarded stale-job recovery did not persist an Interrupted non-cancellable terminal state.'
        } finally {Exit-WsmWorkspaceWorkerGuard $workerGuard}
        $releasedGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -Role 'Target' -PairId $pair -Action 'ReleaseFixture';Exit-WsmWorkspaceWorkerGuard $releasedGuard

        $planImport=Invoke-WsmTypedTextOperation -Workspace $targetRoot -PromptReader (Reader @('2','ImportApprovedPlan',$planPath,$planHash,'','APPLY'))
        Check ($planImport.Executed -and $planImport.Status -ceq 'Applied') 'Typed approved-plan intake failed after explicit APPLY.'
        $received=Get-WsmWizardReceivedApprovedPlan $targetRoot $pair (Read-WsmOutputProfile $targetRoot)
        Check ($received -and $received.SHA256 -ceq $planHash) 'Typed intake did not create the real Target-bound approved-plan receipt.'

        # Target acceptance is a state-writing gate even though its verb starts
        # with Get. A typed form must collect/preview its parameters without
        # invoking that gate or creating any artifact until the operator enters
        # APPLY.
        $script:textRuntimeAcceptanceOriginal=(Get-Command Get-WsmWizardTargetAcceptanceGates -CommandType Function).ScriptBlock
        $script:textRuntimeAcceptanceCalls=0
        function script:Get-WsmWizardTargetAcceptanceGates {
            [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[object[]]$Jobs=@(),[object[]]$GeneralHostEvidence=@())
            $script:textRuntimeAcceptanceCalls++;throw 'Acceptance gate invocation is forbidden before explicit APPLY in this fixture.'
        }
        try {
            $acceptanceMetadata=@(Get-WsmHtmlActionMetadata -Role Target|Where-Object action -CEQ TargetAcceptance|Select-Object -First 1)
            Check ($acceptanceMetadata.Count -eq 1 -and $acceptanceMetadata[0].readOnly -eq $false) 'TargetAcceptance was incorrectly classified as a read-only CLI action.'
            $acceptanceFilesBefore=@(Get-ChildItem -LiteralPath $targetRoot -File -Recurse|ForEach-Object {[pscustomobject]@{path=$_.FullName.Substring($targetRoot.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}}|Sort-Object path)
            $acceptanceNotApplied=Invoke-WsmTypedTextOperation -Workspace $targetRoot -PromptReader (Reader @('2','1','TargetAcceptance','','no'))
            Check ($acceptanceNotApplied.Status -ceq 'Cancelled' -and -not $acceptanceNotApplied.Executed -and $acceptanceNotApplied.Preview.action -ceq 'TargetAcceptance') 'TargetAcceptance did not stop cleanly when APPLY was withheld.'
            Check ($script:textRuntimeAcceptanceCalls -eq 0) 'TargetAcceptance ran before explicit APPLY.'
            $acceptanceFilesAfter=@(Get-ChildItem -LiteralPath $targetRoot -File -Recurse|ForEach-Object {[pscustomobject]@{path=$_.FullName.Substring($targetRoot.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}}|Sort-Object path)
            Check ($acceptanceFilesAfter.Count -eq $acceptanceFilesBefore.Count -and -not @(Compare-Object -ReferenceObject $acceptanceFilesBefore -DifferenceObject $acceptanceFilesAfter -Property path,sha256).Count) 'Withholding APPLY changed a Target artifact or durable record.'
        } finally {Set-Item -Path Function:script:Get-WsmWizardTargetAcceptanceGates -Value $script:textRuntimeAcceptanceOriginal}

        $script:textRuntimeRealNonCDefaults=(Get-Command Get-WsmWizardNonCActionDefaults).ScriptBlock
        $script:textRuntimeDefaultMode='real';$script:textRuntimeDefaultCall=$null
        function script:Get-WsmWizardNonCActionDefaults([string]$Workspace,[string]$PairId,[string]$Role,[string]$Action,[object[]]$Jobs){
            $script:textRuntimeDefaultCall=[pscustomobject]@{Workspace=$Workspace;PairId=$PairId;Role=$Role;Action=$Action}
            if($script:textRuntimeDefaultMode -ceq 'missing'){return [pscustomobject]@{action=$Action;requiredRole='Target';roleAvailable=$true;args=[pscustomobject]@{Workspace=$Workspace}}}
            & $script:textRuntimeRealNonCDefaults -Workspace $Workspace -PairId $PairId -Role $Role -Action $Action -Jobs $Jobs
        }
        try {
            $targetProofDefaults=Get-WsmWizardNonCActionDefaults -Workspace $targetRoot -PairId $pair -Role 'Target' -Action 'NonCTargetProofExport' -Jobs @()
            Check ($targetProofDefaults.roleAvailable -and [string]$targetProofDefaults.args.StateDirectory -ceq (Join-Path $targetRoot 'pairs')) 'Target proof defaults did not resolve the enrolled Target WorkRoot\pairs path.'
            Check (-not $targetProofDefaults.args.PSObject.Properties['ShareName'] -and -not $targetProofDefaults.args.PSObject.Properties['LocalRoots'] -and -not $targetProofDefaults.args.PSObject.Properties['Destination'] -and -not $targetProofDefaults.args.PSObject.Properties['NextOperator']) 'Trusted defaults filled operator intent or proof inputs.'
            $proofReader=Reader @('2','1','NonCTargetProofExport','FixtureShare',$targetRoot,$targetRoot,'','D:\\proof-output','Manager','0','no')
            $proofCancelled=Invoke-WsmTypedTextOperation -Workspace $targetRoot -PromptReader $proofReader
            Check ($proofCancelled.Status -ceq 'Cancelled' -and -not $proofCancelled.Executed) 'Target proof test submitted despite explicit cancellation before APPLY.'
            Check ($script:textRuntimeDefaultCall.Role -ceq 'Target' -and $script:textRuntimeDefaultCall.PairId -ceq $pair -and $script:textRuntimeDefaultCall.Action -ceq 'NonCTargetProofExport') 'Typed CLI resolved defaults against a different role, pair, or action.'
            Check (-not @($script:textRuntimePrompts|Where-Object {$_ -match 'StateDirectory|狀態目錄'}).Count) 'Typed CLI prompted for a trusted Target StateDirectory that was already resolved.'

            $script:textRuntimeDefaultMode='missing'
            $missingReader=Reader @('2','1','NonCTargetProofExport','FixtureShare',$targetRoot,$targetRoot,'',(Join-Path $targetRoot 'pairs'),'D:\\proof-output','Manager','0','no')
            $missingDefaultCancelled=Invoke-WsmTypedTextOperation -Workspace $targetRoot -PromptReader $missingReader
            Check ($missingDefaultCancelled.Status -ceq 'Cancelled' -and -not $missingDefaultCancelled.Executed) 'Missing trusted default test unexpectedly submitted.'
            Check (@($script:textRuntimePrompts|Where-Object {$_ -match 'StateDirectory'}).Count -eq 1) 'A required parameter stayed hidden when its trusted current value was unavailable.'
        } finally {Set-Item -Path Function:script:Get-WsmWizardNonCActionDefaults -Value $script:textRuntimeRealNonCDefaults;$script:textRuntimeDefaultMode='real'}

        $directoryImport=Invoke-WsmTypedTextOperation -Workspace $targetRoot -PromptReader (Reader @('2','1','TargetDirectoryImport',$delivery.SummaryPath,$delivery.SummarySHA256,$delivery.Directory,'APPLY'))
        Check ($directoryImport.Executed -and $directoryImport.Status -ceq 'Applied' -and $directoryImport.Action -ceq 'TargetDirectoryImport') 'Typed directory package intake failed after explicit APPLY.'
        $packageRecords=@(Get-WsmTextWizardJobs $targetRoot $pair 'Target'|Where-Object action -CEQ TargetDirectoryImport)
        Check ($packageRecords.Count -eq 1 -and $packageRecords[0].status -ceq 'Succeeded' -and $packageRecords[0].outputs.Count -eq 1) 'CLI package intake was not available as a validated durable job result.'
        Check ($packageRecords[0].outputs[0].PairId -ceq $pair -and $packageRecords[0].outputs[0].PlanHash -ceq $planHash -and $packageRecords[0].outputs[0].ManifestPath -and $packageRecords[0].outputs[0].ManifestHash -ceq $manifestHash -and $packageRecords[0].outputs[0].Generation -eq 1 -and $packageRecords[0].outputs[0].Valid) 'The real import terminal record lost its safe current-plan/package/generation bindings.'

        # Verify that the same durable history is accepted by the real package
        # resolver before exercising the interactive typed runner. This pinpoints
        # any failure to history projection vs parameter binding in the runner.
        $history=@(Get-WsmTextWizardJobs $targetRoot $pair 'Target')
        $targetContext=Assert-WsmWizardTargetRole $targetRoot $pair
        $directPackage=Get-WsmWizardTargetPackage $targetRoot $pair $targetContext $history
        Check ($directPackage.Package.Manifest.Generation -eq 1 -and $directPackage.ManifestHash -ceq $manifestHash) 'Durable typed-import history was rejected by the real Target package resolver.'
        $directRuntime=Get-WsmWizardRuntimeProjection -Workspace $targetRoot -PairId $pair -Role Target -Jobs $history
        Check ($directRuntime.runtime.package.ManifestHash -ceq $manifestHash) 'The real Target runtime consumer did not resolve the package from the same direct durable history.'

        # This action runs the genuine Target consumer over the job history just
        # written by the preceding typed CLI intake; there are no injected fake jobs.
        $runtime=Invoke-WsmTypedTextOperation -Workspace $targetRoot -PromptReader (Reader @('2','1','WizardRuntimeProjection','APPLY'))
        Check ($runtime.Executed -and $runtime.Status -ceq 'Applied' -and $runtime.Action -ceq 'WizardRuntimeProjection') 'The next typed Target consumer did not run.'
        $projection=@($runtime.Result|Where-Object Kind -CEQ WizardRuntimeProjection|Select-Object -First 1)
        Check ($projection.Count -eq 1 -and $projection[0].PairId -ceq $pair -and $projection[0].Role -ceq 'Target') 'The real Target runtime projection lost its pair or role binding.'
        Check ($projection[0].runtime.package.ManifestHash -ceq $manifestHash -and $projection[0].runtime.plan.generation -eq 1) 'The real runtime consumer did not resolve the exact package bytes and generation from its CLI-written job record.'
        Check ($projection[0].runtime.status -ceq 'NeedsTargetInventory' -and -not $projection[0].runtime.mechanicalValidation.available -and -not $projection[0].runtime.businessAcceptance.available -and -not $projection[0].runtime.activation.available) 'Package intake bypassed Target inventory, mechanical validation, business acceptance, or activation gates.'

        $records=@(Get-ChildItem -LiteralPath $jobsRoot -Filter '*.json' -File|ForEach-Object {Read-WsmJson $_.FullName})
        Check ($records.Count -eq 4 -and @($records|Where-Object action -CEQ ImportApprovedPlan).Count -eq 1 -and @($records|Where-Object action -CEQ TargetDirectoryImport).Count -eq 1 -and @($records|Where-Object action -CEQ WizardRuntimeProjection).Count -eq 2) 'Typed CLI did not persist exactly one record per applied action plus the stale-job recovery fixture.'
        foreach($record in $records){
            $expectedTerminal=if($record.jobId -ceq $staleId){'Interrupted'}elseif($record.action -ceq 'WizardRuntimeProjection'){'ReviewRequired'}else{'Succeeded'}
            Check ($record.jobId -ceq $record.operationId -and $record.status -ceq $expectedTerminal -and $(if($expectedTerminal -ceq 'Interrupted'){$null -eq $record.CompletedUtc}else{[bool]$record.CompletedUtc}) -and $record.workspace -ceq [IO.Path]::GetFullPath($targetRoot) -and $record.role -ceq 'Target' -and $record.pairId -ceq $pair) 'A typed operation record lost exact operation, terminal state, or current workspace context.'
            $persisted=Read-WsmJson (Join-Path $jobsRoot ($record.jobId+'.json'))
            $unsafeKeys=@(Find-UnsafePersistedKey $persisted)
            Check ($unsafeKeys.Count -eq 0) ('Typed CLI persisted command argument or credential fields: '+($unsafeKeys -join ', '))
        }
        $postCliGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $targetRoot -Role 'Target' -PairId $pair -Action 'AfterCliRelease';Exit-WsmWorkspaceWorkerGuard $postCliGuard
        Check ($true) 'The CLI did not release its worker guard after the terminal record was persisted.'

        # Exercise the CLI-only DeveloperProbe seam in a workspace without an
        # enrollment or pair. The production probe writer remains real; only its
        # collector inputs use the bounded adapter contract already used by the
        # native DeveloperProbe tests.
        $probeRoot=Join-Path $Root 'probe-cli-workspace';[void][IO.Directory]::CreateDirectory($probeRoot)
        $script:textRuntimeProbeOriginal=(Get-Command Export-WsmDeveloperProbe -CommandType Function).ScriptBlock
        $script:textRuntimeCancelBeforeProbe=$false
        $script:textRuntimeFailProbe=$false
        $script:textRuntimeProbeAdapter={
            param($CollectorId,$Context)
            switch($CollectorId){
                PlatformIdentity {[pscustomobject]@{OS='Windows Server Fixture';Version='10.0';Build='fixture';Administrator=$true;IsServer=$true;Is64Bit=$true;HostName='probe-cli-fixture'}}
                CommandsModules {[pscustomobject]@{Commands=@();Modules=@()}}
                LocalVolumes {[pscustomobject]@{Volumes=@()}}
                NativeInventory {[pscustomobject]@{Status='Captured';InventorySHA256=('a'*64);Inventory=[pscustomobject]@{ToolVersion='fixture';ToolFingerprint=('b'*64);Source=[pscustomobject]@{Name='probe-cli-fixture';Fingerprint=('c'*64);DiscoveryDepth='Deep'};Items=@();WorkloadDiscovery=[pscustomobject]@{Kind='WorkloadDiscovery';References=@();SharedResources=@();RuntimeObservations=@();ProducerProvenance=@();ConfigurationCoverage=@();Coverage=@();CompletenessReason='Fixture'};SoftwareCatalog=[pscustomobject]@{SchemaVersion=1;ToolVersion='fixture';Kind='SoftwareCatalog';CaptureContext=@{};Entries=@();Coverage=@();PreparationRequirements=@()}}}}
            }
        }
        function script:Export-WsmDeveloperProbe {
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Workspace,[ValidateSet('Source','Target','Manager')][string]$Role='Manager',[string]$Origin,[string]$PairId,[ValidateRange(1,300)][int]$CollectorTimeoutSeconds=30,[ValidateRange(16384,67108864)][long]$MaximumOutputBytes=4194304,[psobject]$CancellationToken,[Parameter(DontShow)][hashtable]$CollectorAdapter)
            if($script:textRuntimeFailProbe){throw 'Bounded CLI fixture failure before probe output.'}
            if($script:textRuntimeCancelBeforeProbe){Request-WsmDeveloperProbeCancellation -CancellationToken $CancellationToken|Out-Null}
            $fixtureAdapters=@{PlatformIdentity=$script:textRuntimeProbeAdapter;CommandsModules=$script:textRuntimeProbeAdapter;LocalVolumes=$script:textRuntimeProbeAdapter;NativeInventory=$script:textRuntimeProbeAdapter}
            & $script:textRuntimeProbeOriginal -Workspace $Workspace -Role $Role -Origin $Origin -PairId $PairId -CollectorTimeoutSeconds $CollectorTimeoutSeconds -MaximumOutputBytes $MaximumOutputBytes -CancellationToken $CancellationToken -CollectorAdapter $fixtureAdapters
        }
        $migrationHeld=Enter-WsmWorkspaceWorkerGuard -Workspace $probeRoot -Role 'Source' -Action 'ProbeOverlapMigration'
        try {
            $probeRun=Invoke-WsmTypedTextOperation -Workspace $probeRoot -PromptReader (Reader @('1','DeveloperProbe','','','','APPLY'))
            Check ($probeRun.Executed -and $probeRun.Status -ceq 'Applied' -and $probeRun.Action -ceq 'DeveloperProbe') 'Typed CLI did not run DeveloperProbe from an unenrolled, no-pair workspace.'
            Check (-not (Read-WsmOutputProfile $probeRoot)) 'DeveloperProbe CLI unexpectedly enrolled a workspace or created role authority.'
            $probeHistory=@(Get-WsmTextDeveloperProbeJobs $probeRoot 'Source')
            $probeTerminal=@($probeHistory|Where-Object {$_.status -ceq 'Succeeded'}|Select-Object -Last 1)
            Check ($probeTerminal.Count -eq 1 -and -not $probeTerminal[0].pairId -and $probeTerminal[0].role -ceq 'Source' -and $probeTerminal[0].CompletedUtc -and $probeTerminal[0].outputs.Count -eq 1) 'CLI probe job did not persist a truthful, no-pair terminal result.'
            $probeOutput=$probeTerminal[0].outputs[0]
            $probePersisted=Read-WsmJson (Join-Path (Join-Path $probeRoot 'console-jobs') ($probeTerminal[0].jobId+'.json'))
            Check ($probePersisted.canCancel -eq $false) 'A succeeded CLI probe terminal record remained marked cancellable.'
            Check ($probeOutput.Status -ceq 'Completed' -and $probeOutput.Path -and $probeOutput.HtmlPath -and $probeOutput.SHA256) 'CLI probe history lost its actual probe status or artifact bindings.'
            $probeZip=[IO.Compression.ZipFile]::OpenRead([string]$probeOutput.Path)
            try {Check ($probeZip.GetEntry('probe.json') -and $probeZip.GetEntry('index.html') -and $probeZip.GetEntry('files-index.json')) 'CLI probe ZIP did not contain real sanitized JSON, HTML, and file index.'} finally {$probeZip.Dispose()}
            Check ([IO.File]::Exists([string]$probeOutput.HtmlPath) -and (Get-FileHash -LiteralPath ([string]$probeOutput.Path) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$probeOutput.SHA256) 'CLI probe artifacts were not durably written and hash-bound.'
            $probeLockReleased=Enter-WsmWorkspaceWorkerGuard -Workspace $probeRoot -Role 'Source' -Action 'DeveloperProbe';Exit-WsmWorkspaceWorkerGuard $probeLockReleased
            $migrationStillHeld=$false;try{$otherMigration=Enter-WsmWorkspaceWorkerGuard -Workspace $probeRoot -Role 'Source' -Action 'AnotherMigration';Exit-WsmWorkspaceWorkerGuard $otherMigration}catch{$migrationStillHeld=$_.Exception.Data['WsmWorkspaceWorkerBusy'] -eq $true}
            Check $migrationStillHeld 'The DeveloperProbe CLI released or occupied the independent migration lane.'
            $probeId=[string]$probeTerminal[0].jobId
            $reconnected=Invoke-WsmTypedTextOperation -Workspace $probeRoot -PromptReader (Reader @('1','DeveloperProbe',$probeId))
            Check ($reconnected.Status -ceq 'Reconnected' -and $reconnected.Job.jobId -ceq $probeId -and $reconnected.Job.outputs[0].SHA256 -ceq $probeOutput.SHA256) 'Typed CLI could not query the same durable DeveloperProbe result without starting another probe.'
        } finally {Exit-WsmWorkspaceWorkerGuard $migrationHeld}

        $activeProbeId=[Guid]::NewGuid().ToString('D');$activeProbeRecord=[pscustomobject][ordered]@{jobId=$activeProbeId;operationId=$activeProbeId;action='DeveloperProbe';status='Running';role='Source';workspace=[IO.Path]::GetFullPath($probeRoot);pairId='';StartedUtc=(Get-WsmUtc);CompletedUtc=$null;canCancel=$true;outputs=@()};[void](Write-WsmTextJobRecord $probeRoot $activeProbeRecord)
        $activeProbeGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $probeRoot -Role 'Source' -Action 'DeveloperProbe'
        try {
            $cancelProbe=Invoke-WsmTypedTextOperation -Workspace $probeRoot -PromptReader (Reader @('1','DeveloperProbe',$activeProbeId))
            $cancelMarker=Get-WsmDeveloperProbeCancellationPath $probeRoot $activeProbeId
            Check ($cancelProbe.Status -ceq 'CancelRequested' -and $cancelProbe.Job.jobId -ceq $activeProbeId -and [IO.File]::Exists($cancelMarker)) 'CLI did not request cancellation for the exact active DeveloperProbe operation.'
            $marker=Read-WsmJson $cancelMarker
            Check ($marker.OperationId -ceq $activeProbeId -and (Read-WsmJson (Join-Path (Join-Path $probeRoot 'console-jobs') ($activeProbeId+'.json'))).status -ceq 'Running') 'CLI cancellation changed another record or prematurely invented a terminal state.'
            Check (-not [IO.File]::Exists((Get-WsmDeveloperProbeCancellationPath $probeRoot ([Guid]::NewGuid().ToString('D')))) -and -not (Get-Content -LiteralPath (Join-Path (Join-Path $probeRoot 'console-jobs') ($activeProbeId+'.json')) -Raw).Contains('DeveloperProbeCancellationToken')) 'A cancellation token or request for a different operation leaked into the durable job record.'
        } finally {Exit-WsmWorkspaceWorkerGuard $activeProbeGuard}
        $script:textRuntimeCancelBeforeProbe=$true
        $cancelRun=Invoke-WsmTypedTextOperation -Workspace $probeRoot -PromptReader (Reader @('1','DeveloperProbe','','','','','APPLY'))
        $script:textRuntimeCancelBeforeProbe=$false
        $cancelledProbe=@(Get-WsmTextDeveloperProbeJobs $probeRoot 'Source'|Where-Object {$_.status -ceq 'Cancelled'}|Select-Object -Last 1)
        Check ($cancelRun.Executed -and $cancelledProbe.Count -eq 1 -and $cancelledProbe[0].outputs[0].Status -ceq 'Cancelled' -and @($cancelledProbe[0].outputs[0].CollectorResults|Where-Object Status -CEQ Cancelled).Count -gt 0) 'Typed CLI dropped the real per-collector cancellation result or marked it successful.'
        $cancelledPersisted=Read-WsmJson (Join-Path (Join-Path $probeRoot 'console-jobs') ($cancelledProbe[0].jobId+'.json'))
        Check ($cancelledPersisted.canCancel -eq $false -and -not (Get-Content -LiteralPath (Join-Path (Join-Path $probeRoot 'console-jobs') ($cancelledProbe[0].jobId+'.json')) -Raw).Contains('DeveloperProbeCancellationToken')) 'Cancelled CLI probe remained cancellable or persisted its operation token.'
        $script:textRuntimeFailProbe=$true;$failedCliProbe=$false
        try{$null=Invoke-WsmTypedTextOperation -Workspace $probeRoot -PromptReader (Reader @('1','DeveloperProbe','','','','','APPLY'))}catch{$failedCliProbe=$true}finally{$script:textRuntimeFailProbe=$false}
        $failedProbe=@(Get-WsmTextDeveloperProbeJobs $probeRoot 'Source'|Where-Object {$_.status -ceq 'Failed'}|Select-Object -Last 1)
        $failedPersisted=if($failedProbe.Count){Read-WsmJson (Join-Path (Join-Path $probeRoot 'console-jobs') ($failedProbe[0].jobId+'.json'))}else{$null}
        Check ($failedCliProbe -and $failedProbe.Count -eq 1 -and $failedProbe[0].outputs.Count -eq 0 -and $failedPersisted.canCancel -eq $false) 'A failed CLI probe did not persist a non-cancellable truthful terminal record.'
        Set-Item -Path Function:script:Export-WsmDeveloperProbe -Value $script:textRuntimeProbeOriginal
        $script:textRuntimeProbeOriginal=$null;$script:textRuntimeProbeAdapter=$null
        Write-Output ('PASS Test-WizardTextRuntime checks='+$script:textRuntimeChecks+'; real schema-3 plan and zero-file package intake flowed through typed CLI metadata/job records into the Target package consumer; DeveloperProbe CLI wrote and reconnected real sanitized artifacts with independent cancellation and truthful terminal cancellability; no host service was invoked.')
    } $root
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'wst-*'){throw 'Unsafe text runtime test cleanup path.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
