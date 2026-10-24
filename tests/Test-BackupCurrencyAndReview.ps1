#requires -Version 5.1
# R4 + R5 (health-check P1): a backup that contains manual / external items, and the single definition of "the current attempt".
#   R4  The plan has a FileScope item plus a ManualWorkflow item and an External FileScope item. The producer ends the attempt as
#       Stage=ReviewRequired although the delivery is verified and the result set / offline report exist. Every consumer that used to
#       compare Stage with 'Delivered' must now follow the delivery evidence (Test-WsmWizardBackupAttemptDelivered):
#       results view, file drill-down, independent-copy action and writer, OfflineReadiness, progress state and its annotation.
#   R5  Two delivered attempts (op1, op2). An independent copy made for op1 refreshes op1's UpdatedUtc; the results view and the action
#       area must still point at op2. "Resumable" has one definition that excludes attempts already handed off.
# Real caller (Invoke-WsmWizardStartBackup), real capture, seal, verify and delivery. Only host qualification observations and the
# independent-copy media class are substituted. ASCII only on purpose: user-facing Chinese text is asserted in the browser tests.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path test.'}
$substCommand='subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"';cmd.exe /c $substCommand
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the test.'}
$root=Join-Path ($driveLetter+':\') ('wsmr45-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:Checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:Checks++}
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        $script:Fp=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:Fp;Name='r45-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:InventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:InventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:InventoryPath;SHA256=(Get-FileHash -LiteralPath $script:InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $script:FixtureMediaClass='Removable'
        $script:OrigMediaClass=(Get-Command Get-WsmIndependentCopyMediaClass -CommandType Function).ScriptBlock
        Set-Item -Path Function:\script:Get-WsmIndependentCopyMediaClass -Value {param($DestinationRoot)$script:FixtureMediaClass}

        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work'
        [void](Initialize-WsmOutputWorkspace $sourceRoot Source)
        $script:Fp=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=Sha $targetIdentityPath
        $script:Fp=('a'*64)
        $sourceEnrollment=Read-WsmOutputProfile $sourceRoot
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        $dataA=Join-Path $Root 'data-a';$dataX=Join-Path $Root 'data-external';foreach($dir in @($dataA,$dataX)){[void][IO.Directory]::CreateDirectory($dir)}
        [IO.File]::WriteAllText((Join-Path $dataA 'a1.txt'),'scope A first file');[IO.File]::WriteAllText((Join-Path $dataA 'a2.txt'),'scope A second file')
        [IO.File]::WriteAllText((Join-Path $dataX 'x1.txt'),'handled outside the tool')
        $itemA=New-WsmItem $source.HostId Storage DataRoot 'R45 scope A' 'r45-scope-a' @{Path=$dataA}
        $itemM=New-WsmItem $source.HostId Storage DataRoot 'R45 manual product' 'r45-manual' @{Path=(Join-Path $Root 'manual-product')}
        $itemX=New-WsmItem $source.HostId Storage DataRoot 'R45 external scope' 'r45-external' @{Path=$dataX}
        $inventory=New-WsmInventory $source 1 @($itemA,$itemM,$itemX);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:InventoryPath=$inventoryPath

        function New-R45Plan([string]$Label,[bool]$WithReviewItems){
            $managerRoot=Join-Path $Root ('manager-'+$Label);Initialize-WsmWorkspace $managerRoot|Out-Null
            $catalog=Import-WsmInventory $managerRoot $inventoryPath (Sha $inventoryPath) ('target-'+$Label)
            $included=New-Object 'System.Collections.Generic.List[string]'
            $specs=New-Object 'System.Collections.Generic.List[object]'
            $specs.Add(@($itemA,[pscustomobject]@{Adapter='FileScope';SourcePath=$dataA;TargetPath=(Join-Path $Root ('restored-'+$Label+'-a'));TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='R45 fixture';BusinessChecks=@('Read back each source file')}))
            if($WithReviewItems){
                $specs.Add(@($itemM,[pscustomobject]@{Adapter='ManualWorkflow';Product='R45 manual product';Procedure='Install and configure by hand';Artifacts=@();Owner='Fixture owner';Evidence='R45 fixture';BusinessChecks=@('Open the product and confirm the licence')}))
                $specs.Add(@($itemX,[pscustomobject]@{Adapter='FileScope';SourcePath=$dataX;TargetPath=(Join-Path $Root ('restored-'+$Label+'-x'));TransferChannel='External';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='R45 fixture';BusinessChecks=@('Confirm the external handling')}))
            }
            foreach($pair in $specs){
                $specPath=Join-Path $Root ('spec-'+$Label+'-'+[Guid]::NewGuid().ToString('N').Substring(0,6)+'.json');Write-WsmJson $specPath $pair[1]
                $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
                Set-WsmMigrationSpec $managerRoot $catalog.PairId $pair[0].ItemId $specPath (Sha $specPath) $revision|Out-Null
                $included.Add([string]$pair[0].ItemId)
            }
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            Set-WsmDecision $managerRoot $catalog.PairId @($included.ToArray()) Include 'Explicit R45 selection' $revision|Out-Null
            $excluded=@(@($itemA,$itemM,$itemX)|Where-Object {-not $included.Contains([string]$_.ItemId)}|ForEach-Object {[string]$_.ItemId})
            if($excluded.Count){
                $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
                Set-WsmDecision $managerRoot $catalog.PairId $excluded Exclude 'Explicit R45 exclusion' $revision|Out-Null
            }
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            $planPath=Join-Path $Root ('approved-plan-'+$Label+'.json')
            $approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $revision 'ISOLATED-PILOT'
            $script:Fp=('a'*64)
            $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
            if($import.Status -cne 'ImportedVerified'){throw ('Source did not import the approved '+$Label+' plan.')}
            [pscustomobject]@{PairId=[string]$catalog.PairId;PlanHash=[string]$approved.SHA256;PlanPath=$planPath}
        }
        function Start-R45Backup($PlanInfo,[string]$Op){
            $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $PlanInfo.PairId -PlanHash $PlanInfo.PlanHash -OperationId $Op
            Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $PlanInfo.PairId -OperationId $Op -Jobs @() -CancellationToken $token -DeliveryMode Directory -VolumeBytes 0
        }
        function Get-R45Attempt($PlanInfo,[string]$Op){(Get-WsmWizardBackupAttemptForOperation $sourceRoot $PlanInfo.PairId (Read-WsmOutputProfile $sourceRoot) $Op)}
        function New-R45Job($PlanInfo,[string]$Op,[string]$Status,[switch]$NoCompletedUtc){
            $attempt=(Get-R45Attempt $PlanInfo $Op).Attempt
            $job=[ordered]@{jobId=$Op;action='StartBackup';status=$Status;role='Source';workspace=$sourceRoot;pairId=$PlanInfo.PairId}
            if(-not $NoCompletedUtc){$job.CompletedUtc=(Get-WsmUtc)}
            $job.outputs=@([pscustomobject]@{AttemptId=[string]$attempt.AttemptId})
            [pscustomobject]$job
        }
        function New-R45Copy($PlanInfo,[string]$BackupOp,[string]$Tag){
            $destination=Join-Path $Root ('copy-'+$Tag);[void][IO.Directory]::CreateDirectory($destination)
            Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $PlanInfo.PairId -BackupOperationId $BackupOp -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $destination -Mode Copy
        }
        function Clone-Json($Value){($Value|ConvertTo-Json -Depth 40 -Compress)|ConvertFrom-Json}

        try {
            # ======================================================================================================
            # R4. FileScope + ManualWorkflow + External: the delivery is verified, the stage is ReviewRequired.
            # ======================================================================================================
            $reviewPlan=New-R45Plan 'review' $true
            $pairR=$reviewPlan.PairId
            $opR=[Guid]::NewGuid().ToString('D')
            $resultR=Start-R45Backup $reviewPlan $opR
            $attemptRefR=Get-R45Attempt $reviewPlan $opR;$attemptR=$attemptRefR.Attempt
            Check ($resultR.Status -ceq 'ReviewRequired' -and $attemptR.Stage -ceq 'ReviewRequired' -and $attemptR.ChannelSummary.OverallStatus -ceq 'ReviewRequired') ('R4 precondition: the real backup did not end ReviewRequired (Stage='+$attemptR.Stage+')')
            Check ([bool]$attemptR.PackageTest.Valid -and [string]$attemptR.Delivery.SHA256 -match '^[a-f0-9]{64}$' -and $attemptR.ItemResults.Status -ceq 'Generated' -and $attemptR.OfflineReport.Status -ceq 'Generated') 'R4 precondition: a ReviewRequired attempt must still have a verified delivery, a result set and an offline report'
            Check (@($attemptR.ChannelSummary.ManualArtifactsNotSupported.IncludedItemIds).Count -eq 1 -and @($attemptR.ChannelSummary.UnsupportedIncludedItemIds).Count -eq 1) ('R4 precondition: expected one manual and one external item, got manual='+@($attemptR.ChannelSummary.ManualArtifactsNotSupported.IncludedItemIds).Count+' unsupported='+@($attemptR.ChannelSummary.UnsupportedIncludedItemIds).Count)
            Write-Host 'PASS: R4-0 the one-click backup of FileScope + ManualWorkflow + External ends ReviewRequired with a verified delivery.'

            # --- the single delivery decision ---
            Check (Test-WsmWizardBackupAttemptDelivered $attemptR) 'R4-1 a ReviewRequired attempt with verified delivery evidence must count as delivered'
            Check ((Get-WsmWizardBackupReviewItemCount $attemptR.ChannelSummary) -eq 2) ('R4-1 the annotation count must be 2 (manual + external), got '+(Get-WsmWizardBackupReviewItemCount $attemptR.ChannelSummary))
            $mutations=@(
                @('no Delivery',{param($a)$a.Delivery=$null}),
                @('Delivery hash is not a SHA-256',{param($a)$a.Delivery.SHA256='abc'}),
                @('PackageTest is not valid',{param($a)$a.PackageTest.Valid=$false}),
                @('no PackageTest',{param($a)$a.PackageTest=$null}),
                @('ItemResults failed',{param($a)$a.ItemResults=[pscustomobject]@{Status='Failed';Error='x'}}),
                @('ItemResults missing',{param($a)$a.PSObject.Properties.Remove('ItemResults')}),
                @('a non-C channel still waiting for its direct transfer (existing G3 contract: never a complete backup)',{param($a)$a.ChannelSummary.NonC.Status='RequiresTargetTransferAndManagerResultImport'}),
                @('a non-C channel waiting for the final source freeze',{param($a)$a.ChannelSummary.NonC.Status='RequiresFinalSourceFreeze'}),
                @('no ChannelSummary',{param($a)$a.ChannelSummary=$null}),
                @('stage Failed with every field intact',{param($a)$a.Stage='Failed'}),
                @('stage Cancelled with every field intact',{param($a)$a.Stage='Cancelled'}),
                @('stage PackageVerified with every field intact',{param($a)$a.Stage='PackageVerified'})
            )
            foreach($case in $mutations){
                $clone=Clone-Json $attemptR;& $case[1] $clone
                Check (-not (Test-WsmWizardBackupAttemptDelivered $clone)) ('R4-1 an attempt with '+$case[0]+' must not count as delivered')
                Check ((ConvertTo-WsmWizardBackupResult $clone $opR).OfflineReadiness -ceq 'NotDelivered') ('R4-1 OfflineReadiness must be NotDelivered with '+$case[0])
            }
            $deliveredClone=Clone-Json $attemptR;$deliveredClone.Stage='Delivered'
            Check ((Test-WsmWizardBackupAttemptDelivered $deliveredClone) -and (Test-WsmWizardBackupStageDelivered 'Delivered' $null) -and -not (Test-WsmWizardBackupStageDelivered 'ReviewRequired' $null)) 'R4-1 Delivered stays delivered; a bare ReviewRequired stage with no attempt is not evidence'
            Write-Host 'PASS: R4-1 one delivery decision: evidence passes, each missing piece of evidence and every other stage fails.'

            # --- results view (current result set), with the annotation ---
            $view=Get-WsmWizardBackupItemResultsView $sourceRoot $pairR
            Check ($view.available -eq $true -and $view.integrity -ceq 'Verified' -and $view.attemptId -ceq [string]$attemptR.AttemptId) ('R4-2 the results view shows no result for a ReviewRequired backup: '+($view|ConvertTo-Json -Depth 4 -Compress))
            Check ([int]$view.reviewItemCount -eq 2) ('R4-2 the results view must carry the annotation count 2, got '+$view.reviewItemCount)
            $rowM=@($view.rows|Where-Object {$_.ItemId -ceq $itemM.ItemId});$rowX=@($view.rows|Where-Object {$_.ItemId -ceq $itemX.ItemId});$rowA=@($view.rows|Where-Object {$_.ItemId -ceq $itemA.ItemId})
            Check ($rowM.Count -eq 1 -and $rowM[0].Status -ceq 'NotBackedUp' -and $rowM[0].ReasonCode -ceq 'ManualHandling') 'R4-2 the pending tab must list the ManualWorkflow item as ManualHandling'
            Check ($rowX.Count -eq 1 -and $rowX[0].Status -ceq 'NotBackedUp' -and $rowX[0].ReasonCode -ceq 'ExternalHandling') 'R4-2 the pending tab must list the External item as ExternalHandling'
            Check ($rowA.Count -eq 1 -and $rowA[0].Status -ceq 'BackedUp' -and [long]$rowA[0].Files -eq 2) 'R4-2 the FileScope item must be listed as backed up with its two files'
            Check ([int]$view.counts.BackedUp -eq 1 -and [int]$view.counts.NotBackedUp -ge 2) ('R4-2 counts must be 1 backed up and at least 2 not backed up, got '+($view.counts|ConvertTo-Json -Compress))
            Write-Host 'PASS: R4-2 results view shows the ReviewRequired backup, lists ManualHandling and ExternalHandling, and carries the annotation count.'

            # --- file drill-down ---
            $files=Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pairR -ItemId $itemA.ItemId
            Check ($files.available -eq $true -and [long]$files.TotalCount -ge 2 -and [string]$files.AttemptId -ceq [string]$attemptR.AttemptId) 'R4-3 the file drill-down must read the files of a ReviewRequired backup'
            Write-Host 'PASS: R4-3 file drill-down works for the ReviewRequired backup.'

            # --- OfflineReadiness and the independent-copy action ---
            $profile=Read-WsmOutputProfile $sourceRoot
            Check ((ConvertTo-WsmWizardBackupResult $attemptR $opR).OfflineReadiness -ceq 'AwaitingIndependentCopy') 'R4-4 OfflineReadiness before the copy must be AwaitingIndependentCopy, not NotDelivered'
            $jobR=New-R45Job $reviewPlan $opR 'ReviewRequired'
            $availR=Get-WsmWizardBackupAvailability $sourceRoot $pairR $profile @($jobR)
            Check ($availR -and $availR.current -and $availR.stage -ceq 'ReviewRequired' -and $availR.hasPackage -and [string]$availR.runId -ceq $opR) 'R4-4 the availability row must be current and carry the verified package'
            $actionR=Get-WsmWizardIndependentCopyAction $availR
            Check ($actionR.available -eq $true -and [string]$actionR.defaults.BackupOperationId -ceq $opR) 'R4-4 the independent-copy action must be available for the ReviewRequired backup'
            Check ((Get-WsmWizardOfflineReadiness $availR) -ceq 'AwaitingIndependentCopy') 'R4-4 Get-WsmWizardOfflineReadiness must follow the evidence'
            $tampered=Clone-Json $availR;$tampered.hasPackage=$false
            Check ((Get-WsmWizardIndependentCopyAction $tampered).available -eq $false) 'R4-4 without a verified package the action stays unavailable'
            $failedStage=Clone-Json $availR;$failedStage.stage='Failed';$failedStage.attempt.Stage='Failed'
            Check ((Get-WsmWizardIndependentCopyAction $failedStage).available -eq $false) 'R4-4 a failed stage must not enable the action'
            Write-Host 'PASS: R4-4 OfflineReadiness and the independent-copy action follow the delivery evidence.'

            # --- progress state before the copy: delivered but not yet independent -> awaiting delivery, with the annotation ---
            $raw=Read-WsmWizardBackupProgress $sourceRoot $pairR $opR
            Check ($null -ne $raw) 'R4-5 the durable progress record of the backup must exist'
            $progressJob={param([string]$Status)[pscustomobject]@{Record=[pscustomobject]@{action='StartBackup';status=$Status;workspace=$sourceRoot;pairId=$pairR;jobId=$opR}}}
            $viewBefore=Get-WsmHtmlBackupProgress (& $progressJob 'ReviewRequired')
            Check ($viewBefore -and [string]$viewBefore.State -ceq 'AwaitingDelivery' -and [int]$viewBefore.ReviewItemCount -eq 2) ('R4-5 before the copy the progress card must be AwaitingDelivery with 2 annotated items, got '+($viewBefore|ConvertTo-Json -Compress))

            # --- independent copy writer on the ReviewRequired attempt ---
            $copyR=New-R45Copy $reviewPlan $opR 'review'
            Check ($copyR.IndependentCopy.Status -ceq 'Verified' -and $copyR.OfflineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed')) ('R4-6 the independent copy of a ReviewRequired backup was not verified: '+$copyR.OfflineReadiness)
            Check ($copyR.Stage -ceq 'ReviewRequired') 'R4-6 the copy must not rewrite the producer stage'
            $viewAfter=Get-WsmWizardBackupItemResultsView $sourceRoot $pairR
            Check ($viewAfter.independentCopy.state -ceq 'Verified' -and $viewAfter.offlineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed')) 'R4-6 the results view must show the verified independent copy'
            $viewDone=Get-WsmHtmlBackupProgress (& $progressJob 'ReviewRequired')
            Check ($viewDone -and [string]$viewDone.State -ceq 'Completed' -and [int]$viewDone.ReviewItemCount -eq 2 -and [string]$viewDone.EndReason -ceq '') ('R4-6 after the copy the progress card must be Completed with the annotation, got '+($viewDone|ConvertTo-Json -Compress))
            # state table: ReviewRequired judged like Succeeded when there is delivery evidence, a failure only without it
            foreach($row in @(
                @('ReviewRequired','AwaitingIndependentCopy',0,'AwaitingDelivery'),
                @('ReviewRequired','Verified',0,'Completed'),
                @('ReviewRequired','VerifiedNetworkAvailabilityUnconfirmed',0,'Completed'),
                @('ReviewRequired','Verified',3,'PartialFailure'),
                @('ReviewRequired','NotDelivered',0,'PartialFailure'),
                @('ReviewRequired','',0,'PartialFailure'),
                @('Succeeded','Verified',0,'Completed'),
                @('Succeeded','AwaitingIndependentCopy',0,'AwaitingDelivery'),
                @('Succeeded','NotDelivered',0,'AwaitingDelivery')
            )){
                $state=Get-WsmBackupProgressState $row[0] 'ignored-stage' $row[1] $row[2]
                Check ($state.State -ceq $row[3]) ('R4-6 state for '+$row[0]+'/'+$row[1]+'/'+$row[2]+' must be '+$row[3]+', got '+$state.State)
            }
            # a ReviewRequired attempt that never delivered (source freeze interrupted) is still a failure on the card
            $interrupted=Clone-Json $attemptR;$interrupted.Delivery=$null;$interrupted.PackageTest=$null;$interrupted.Stage='ReviewRequired'
            $interruptedResult=ConvertTo-WsmWizardBackupResult $interrupted $opR
            Check ($interruptedResult.OfflineReadiness -ceq 'NotDelivered' -and (Get-WsmBackupProgressState 'ReviewRequired' $interruptedResult.Stage $interruptedResult.OfflineReadiness 0).State -ceq 'PartialFailure') 'R4-6 an interrupted ReviewRequired attempt without delivery must stay a failure'
            Write-Host 'PASS: R4-5/6 independent copy writer, progress state and annotation follow the delivery evidence.'

            # ======================================================================================================
            # R5. Two delivered attempts; an independent copy for the OLDER one must not move "current".
            # ======================================================================================================
            $twoPlan=New-R45Plan 'two' $false
            $pairT=$twoPlan.PairId
            $op1=[Guid]::NewGuid().ToString('D');$result1=Start-R45Backup $twoPlan $op1
            Start-Sleep -Milliseconds 60
            $op2=[Guid]::NewGuid().ToString('D');$result2=Start-R45Backup $twoPlan $op2
            $attempt1=(Get-R45Attempt $twoPlan $op1).Attempt;$attempt2=(Get-R45Attempt $twoPlan $op2).Attempt
            Check ($result1.Status -ceq 'Delivered' -and $result2.Status -ceq 'Delivered' -and [string]$attempt1.AttemptId -cne [string]$attempt2.AttemptId) 'R5 precondition: two separate delivered attempts are expected'
            Check ([int]$attempt1.CoreExport.Generation -eq 1 -and [int]$attempt2.CoreExport.Generation -eq 1) 'R5 precondition: every new attempt starts at generation 1 (so the generation cannot tell them apart)'
            Check ([DateTimeOffset]::Parse([string]$attempt2.StartedUtc) -gt [DateTimeOffset]::Parse([string]$attempt1.StartedUtc)) 'R5 precondition: op2 started after op1'
            $viewT0=Get-WsmWizardBackupItemResultsView $sourceRoot $pairT
            Check ($viewT0.available -and [string]$viewT0.attemptId -ceq [string]$attempt2.AttemptId) 'R5-1 before any copy the results view must show op2'
            $jobs=@((New-R45Job $twoPlan $op1 'Succeeded'),(New-R45Job $twoPlan $op2 'Succeeded'))
            $availT0=Get-WsmWizardBackupAvailability $sourceRoot $pairT $profile $jobs
            Check ($availT0.current -and [string]$availT0.attemptId -ceq [string]$attempt2.AttemptId -and [string]$availT0.runId -ceq $op2) 'R5-1 before any copy the availability row must be op2'
            Check ([string](Get-WsmWizardIndependentCopyAction $availT0).defaults.BackupOperationId -ceq $op2) 'R5-1 before any copy the action must target op2'
            # the independent copy for op1 refreshes op1's UpdatedUtc (the old results-view rule picked "Delivered with the largest UpdatedUtc")
            $copy1=New-R45Copy $twoPlan $op1 'op1'
            Check ($copy1.IndependentCopy.Status -ceq 'Verified') 'R5-2 the independent copy for op1 must succeed'
            $attempt1After=(Get-R45Attempt $twoPlan $op1).Attempt;$attempt2After=(Get-R45Attempt $twoPlan $op2).Attempt
            Check ([DateTimeOffset]::Parse([string]$attempt1After.UpdatedUtc) -gt [DateTimeOffset]::Parse([string]$attempt2After.UpdatedUtc)) 'R5-2 precondition: the copy must have made op1 the most recently updated attempt'
            $viewT1=Get-WsmWizardBackupItemResultsView $sourceRoot $pairT
            Check ($viewT1.available -and [string]$viewT1.attemptId -ceq [string]$attempt2.AttemptId -and [string]$viewT1.backupOperationId -ceq $op2) ('R5-2 the results view turned back to the older attempt after an independent copy for it (attempt '+$viewT1.attemptId+')')
            $availT1=Get-WsmWizardBackupAvailability $sourceRoot $pairT $profile $jobs
            Check ($availT1.current -and [string]$availT1.attemptId -ceq [string]$attempt2.AttemptId -and [string]$availT1.runId -ceq $op2) 'R5-2 the availability row moved away from op2'
            Check ([string](Get-WsmWizardIndependentCopyAction $availT1).defaults.BackupOperationId -ceq $op2) 'R5-2 the action area moved away from op2'
            # a job record without a completion time falls back to the attempt's UpdatedUtc for its time; that must not decide "current" either
            $jobsNoTime=@((New-R45Job $twoPlan $op1 'Succeeded' -NoCompletedUtc),(New-R45Job $twoPlan $op2 'Succeeded' -NoCompletedUtc))
            $availNoTime=Get-WsmWizardBackupAvailability $sourceRoot $pairT $profile $jobsNoTime
            Check ($availNoTime.current -and [string]$availNoTime.attemptId -ceq [string]$attempt2.AttemptId -and [string]$availNoTime.runId -ceq $op2) 'R5-2 without job completion times the availability row moved to the attempt that was updated last (op1)'
            Check ([string](Get-WsmWizardIndependentCopyAction $availNoTime).defaults.BackupOperationId -ceq $op2) 'R5-2 without job completion times the action area moved to op1'
            Check (@($availNoTime | Where-Object {$_.attemptId -cne [string]$attempt2.AttemptId}).Count -eq 0) 'R5-2 only the current attempt may be returned'
            Check ([string]$viewT1.attemptId -ceq [string]$availT1.attemptId) 'R5-2 the results view and the availability disagree about the current attempt'
            $files2=Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pairT -ItemId $itemA.ItemId
            Check ([string]$files2.AttemptId -ceq [string]$attempt2.AttemptId) 'R5-2 the file drill-down must read the current attempt as well'
            Write-Host 'PASS: R5-1/2 an independent copy for op1 leaves the results view, the availability row, the action and the drill-down on op2.'

            # --- the helper itself: StartedUtc, then generation, never UpdatedUtc; records without the field still sort ---
            $t1='2026-10-01T00:00:00.0000000Z';$t2='2026-10-02T00:00:00.0000000Z';$t9='2026-10-30T00:00:00.0000000Z'
            $olderRefreshed=[pscustomobject]@{AttemptId='aaaa';StartedUtc=$t1;UpdatedUtc=$t9;CoreExport=[pscustomobject]@{Generation=1}}
            $newerQuiet=[pscustomobject]@{AttemptId='bbbb';StartedUtc=$t2;UpdatedUtc=$t2;CoreExport=[pscustomobject]@{Generation=1}}
            Check ([string](Get-WsmWizardCurrentBackupAttempt @($olderRefreshed,$newerQuiet)).AttemptId -ceq 'bbbb' -and [string](Get-WsmWizardCurrentBackupAttempt @($newerQuiet,$olderRefreshed)).AttemptId -ceq 'bbbb') 'R5-3 UpdatedUtc must not decide the current attempt (either input order)'
            $sameStartLowGen=[pscustomobject]@{AttemptId='cccc';StartedUtc=$t1;UpdatedUtc=$t1;CoreExport=[pscustomobject]@{Generation=1}}
            $sameStartHighGen=[pscustomobject]@{AttemptId='dddd';StartedUtc=$t1;UpdatedUtc=$t1;CoreExport=[pscustomobject]@{Generation=2}}
            Check ([string](Get-WsmWizardCurrentBackupAttempt @($sameStartLowGen,$sameStartHighGen)).AttemptId -ceq 'dddd') 'R5-3 equal StartedUtc falls back to the generation'
            $noStarted=[pscustomobject]@{AttemptId='eeee';UpdatedUtc=$t9}
            $badStarted=[pscustomobject]@{AttemptId='ffff';StartedUtc='not a time';UpdatedUtc=$t9;CoreExport=$null}
            $noCore=[pscustomobject]@{AttemptId='gggg';StartedUtc=$t1}
            Check ([string](Get-WsmWizardCurrentBackupAttempt @($noStarted,$noCore)).AttemptId -ceq 'gggg' -and [string](Get-WsmWizardCurrentBackupAttempt @($badStarted,$noCore)).AttemptId -ceq 'gggg') 'R5-3 old records with no (or unreadable) StartedUtc sort as the oldest and never beat a dated one'
            Check ([string](Get-WsmWizardCurrentBackupAttempt @($noStarted,$badStarted)).AttemptId -ceq 'ffff' -and [string](Get-WsmWizardCurrentBackupAttempt @($badStarted,$noStarted)).AttemptId -ceq 'ffff') 'R5-3 two undated records resolve deterministically (AttemptId)'
            Check ($null -eq (Get-WsmWizardCurrentBackupAttempt @()) -and [string](Get-WsmWizardCurrentBackupAttempt @($noCore)).AttemptId -ceq 'gggg') 'R5-3 no candidates gives null, one candidate gives itself'
            # real records carry no sequence field; they must sort exactly as before the helper existed
            Check (-not $attempt1.PSObject.Properties['AttemptSequence'] -and [string](Get-WsmWizardCurrentBackupAttempt @($attempt1After,$attempt2After)).AttemptId -ceq [string]$attempt2.AttemptId) 'R5-3 the real records (no new field) sort op2 as the current one even though op1 was updated last'
            Write-Host 'PASS: R5-3 the current-attempt helper orders by StartedUtc then generation; old records without fields sort as the oldest.'

            # ======================================================================================================
            # Resumable: one definition, used by the resume entry point and by the result object, excluding handed-off attempts.
            # ======================================================================================================
            $backupRoot=Get-WsmWizardBackupRoot $sourceRoot $pairT
            $baseAttempt=Read-WsmJson (Get-R45Attempt $twoPlan $op2).Path
            $resumeCases=@(
                @('Authorized','',$false,$false,$false,$true),
                @('CoreExported','',$false,$false,$false,$true),
                @('PackageVerified','',$false,$false,$false,$true),
                @('Failed','Authorized',$false,$false,$false,$true),
                @('Cancelled','PackageVerified',$false,$false,$false,$true),
                @('Failed','',$false,$false,$false,$false),
                @('ReviewRequired','',$true,$false,$false,$true),
                @('ReviewRequired','',$false,$false,$false,$false),
                @('Delivered','',$false,$false,$false,$false),
                @('Authorized','',$false,$true,$false,$false),
                @('Failed','Authorized',$true,$true,$false,$false),
                @('ReviewRequired','',$true,$true,$false,$false),
                @('ReviewRequired','',$false,$true,$true,$true)
            )
            $caseNumber=0
            foreach($case in $resumeCases){
                $caseNumber++
                $id=[Guid]::NewGuid().ToString('D');$body=[ordered]@{};foreach($property in $baseAttempt.PSObject.Properties){$body[$property.Name]=$property.Value}
                $body.AttemptId=$id;$body.StartedByOperationId=$id;$body.OperationIds=@($id);$body.LastOperationId=$id
                $body.Stage=$case[0];$body.ResumeStage=$case[1];$body.SourceResumeRequired=$case[2];$body.SourceResumed=$case[3];$body.SourceResumeFreshFreezePending=$case[4]
                $path=Join-Path $backupRoot ($id+'.json');Write-WsmJson $path ([pscustomobject]$body)
                try{
                    $stored=Read-WsmJson $path
                    $viaHelper=Test-WsmWizardBackupAttemptResumable $stored
                    $viaResult=[bool](ConvertTo-WsmWizardBackupResult $stored $id).ResumeRequired
                    $viaEntry=($null -ne (Get-WsmWizardBackupAttempt $sourceRoot $pairT $profile $twoPlan.PlanHash))
                    $canAfterReview=[bool](ConvertTo-WsmWizardBackupResult $stored $id).CanResumeAfterReview
                }finally{[IO.File]::Delete($path)}
                $label='resume case '+$caseNumber+' ('+($case[0..4] -join '/')+')'
                Check ($viaHelper -eq $case[5] -and $viaResult -eq $case[5] -and $viaEntry -eq $case[5]) ($label+': expected '+$case[5]+' from all three; helper='+$viaHelper+' result='+$viaResult+' entry='+$viaEntry)
                Check ($canAfterReview -eq ($case[5] -and $case[0] -cin @('Failed','Cancelled'))) ($label+': CanResumeAfterReview disagrees (got '+$canAfterReview+')')
            }
            # a legacy record that never had the hand-off fields still reads as resumable when its stage says so
            $legacy=[ordered]@{};foreach($property in $baseAttempt.PSObject.Properties){if($property.Name -cnotin @('SourceResumed','SourceResumeRequired','SourceResumeFreshFreezePending','ResumeStage')){$legacy[$property.Name]=$property.Value}}
            $legacy.Stage='Authorized'
            Check ((Test-WsmWizardBackupAttemptResumable ([pscustomobject]$legacy)) -and [bool](ConvertTo-WsmWizardBackupResult ([pscustomobject]$legacy) 'legacy').ResumeRequired) 'resume: a legacy record without hand-off fields must still be resumable at an unfinished stage'
            Write-Host 'PASS: resumable has one definition; the resume entry and the result object agree on all 13 cases and exclude handed-off attempts.'

            # a delivered backup is never "resumable" and the real attempts of this run were not touched by the clones
            Check (-not [bool](ConvertTo-WsmWizardBackupResult $attempt2After $op2).ResumeRequired -and -not [bool](ConvertTo-WsmWizardBackupResult $attemptR $opR).ResumeRequired) 'a delivered or ReviewRequired-with-delivery attempt must not ask to be resumed'
        } finally {
            Set-Item -Path Function:\script:Get-WsmIndependentCopyMediaClass -Value $script:OrigMediaClass
        }
        Write-Host ('PASS: R4 + R5 backup currency and review annotation ('+$script:Checks+' checks).')
    } $root
} finally {
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmr45-*'){throw 'Unsafe cleanup path.'}
    if([IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
