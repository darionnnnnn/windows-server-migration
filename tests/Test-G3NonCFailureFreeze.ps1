#requires -Version 5.1
# G3 (N9f): C succeeds / NonC fails, freeze expiry, source change, cancel and resume (R7-02 / R7-10).
# One immutable snapshot of the tracked tree; the product is imported unchanged from it. The one-click backup core is the
# real code (freeze, capture, seal, verify, delivery, item results, offline report, SourceResume). The NonC channel is the
# TransferChannel label on a scope that lives on a subst "second volume"; the injected faults are a payload crash on that scope,
# a cancellation requested while that scope is captured, and an expired freeze receipt.
# Judged beyond the core result (N4 does that): the result projection, the workbench result view, the offline report, the HTML
# result projection, the HTML runtime projection and the "no retirement / no success" facts.
# Output: work\r7\g-journey\<RunId>\verdict.json (same shape as the main journey).
param(
    [string]$RunId='g3a001',
    [switch]$KeepArtifacts,
    [ValidateSet('','ProjectionClaimsComplete')][string]$Mutation=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'G-ScenarioCommon.ps1')
Initialize-GScenario 'g3' 'G3 NonC failure / freeze / cancel' $RunId $Mutation

try{
    Write-GStage 1 'snapshot, product imported from the immutable copy, two subst drives'
    if([IO.Directory]::Exists($script:GTestRoot)){throw 'Refusing to reuse an existing test root.'}
    [void][IO.Directory]::CreateDirectory($script:GTestRoot)
    $module=New-GSnapshot @('tests/G-ScenarioCommon.ps1','tests/Test-G3NonCFailureFreeze.ps1')
    $fixturePath=Join-Path $script:GSnapshot 'tests\ExternalReadinessEvidenceFixtures.ps1'
    $wsDrive=New-GSubst (Join-Path $script:GTestRoot 'ws')
    $volDrive=New-GSubst (Join-Path $script:GTestRoot 'second-volume')
    Add-GDouble 'subst workspace drive' ('drive '+$wsDrive+': maps the workspace folder so the nested attempt/package paths stay below MAX_PATH')
    Add-GDouble 'subst second volume' ('drive '+$volDrive+': maps a folder and stands for the NonC volume; the NonC scope is also labelled TransferChannel=NonC (this runner has no second physical volume)')
    Add-GDouble 'Get-WsmMachineIdentity / Get-WsmPreflight / Export-WsmInventory' 'host qualification observation and the fixture inventory file only'
    Add-GDouble 'fault: Write-WsmPayloadFile' 'throws (crash) or requests cancellation while a file of the NonC scope is captured; everything else calls the original'
    Add-GDouble 'fault: expired freeze receipt' 'the freeze receipt file is rewritten with ProducedUtc/ExpiresUtc in the past and the attempt record re-hashed (same device as N4)'
    Add-GDouble 'freeze / SourceResume evidence' 'New-WsmSourceFreezeEvidenceFixture / New-WsmSourceResumeEvidenceFixture (typed fixture evidence); the freeze record and SourceResume consumers are real'
    if($Mutation -ceq 'ProjectionClaimsComplete'){Add-GDouble 'MUTATION ProjectionClaimsComplete' 'ConvertTo-WsmWizardBackupResult is wrapped so that a failed / unfinished backup is reported as Delivered / VerifiedDelivered / Verified'}

    Write-GStage 2 'C scope captured, NonC scope fails; expiry, source change, SourceResume, new attempt; cancel and resume'
    $observations=& $module {
        param($Root,$FixturePath,$MutationName,$Report,$WsRoot,$VolRoot)
        . $FixturePath
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Try-Run([scriptblock]$Action){try{& $Action|Out-Null;$null}catch{$_.Exception}}
        function Tree([string]$Directory){(@(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Sha $_.FullName)}) -join "`n")}
        function Has($Object,[string]$Name){[bool]($Object -and $Object.PSObject.Properties[$Name])}
        $obs=[ordered]@{}
        $script:g3Fp=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:g3Fp;Name='g3-fixture';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:g3InventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:g3InventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:g3InventoryPath;SHA256=(Get-FileHash -LiteralPath $script:g3InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        if($MutationName -ceq 'ProjectionClaimsComplete'){
            $script:g3OrigResult=(Get-Command ConvertTo-WsmWizardBackupResult -CommandType Function).ScriptBlock
            function script:ConvertTo-WsmWizardBackupResult($Attempt,[string]$OperationId){
                $result=& $script:g3OrigResult $Attempt $OperationId
                if($Attempt.Stage -cne 'Delivered'){$result.Status='Delivered';$result.Stage='Delivered';$result.NonCStatus='VerifiedDelivered';$result.OfflineReadiness='Verified'}
                $result
            }
        }
        $sourceRoot=Join-Path $WsRoot 's';$targetRoot=Join-Path $WsRoot 't'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:g3Fp=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=Sha $targetIdentityPath
        $script:g3Fp=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='g3-source'}
        $dataC=Join-Path $Root 'c-data';$dataN=Join-Path $VolRoot 'nonc-data'
        foreach($dir in @($dataC,$dataN)){[void][IO.Directory]::CreateDirectory($dir)}
        $fileC1=Join-Path $dataC 'c1.txt';$fileN1=Join-Path $dataN 'n1.txt';$fileN2=Join-Path $dataN 'n2.txt';$fileCNew=Join-Path $dataC 'c-added-after.txt'
        function Set-SourceBytes([string]$Tag){[IO.File]::WriteAllText($fileC1,('C channel bytes '+$Tag));[IO.File]::WriteAllText($fileN1,('NonC first bytes '+$Tag));[IO.File]::WriteAllText($fileN2,('NonC second bytes '+$Tag))}
        Set-SourceBytes 'generation-one'
        $itemC=New-WsmItem $source.HostId Storage DataRoot 'G3 C scope' 'g3-c-scope' @{Path=$dataC}
        $itemN=New-WsmItem $source.HostId Storage DataRoot 'G3 NonC scope' 'g3-nonc-scope' @{Path=$dataN}
        $inventory=New-WsmInventory $source 1 @($itemC,$itemN);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:g3InventoryPath=$inventoryPath
        function New-G3Plan([string]$Label,[string]$Consistency){
            $managerRoot=Join-Path $WsRoot ('m-'+$Label);Initialize-WsmWorkspace $managerRoot|Out-Null
            $catalog=Import-WsmInventory $managerRoot $inventoryPath (Sha $inventoryPath) ('target-'+$Label)
            foreach($pair in @(@($itemC,$dataC,'c','C'),@($itemN,$dataN,'n','NonC'))){
                $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$pair[1];TargetPath=(Join-Path $Root ('restored-'+$Label+'-'+$pair[2]));TransferChannel=$pair[3];ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency=$Consistency;Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='G3 owner';Evidence='G3 fixture';BusinessChecks=@('Read back each source file')}
                $specPath=Join-Path $Root ('spec-'+$Label+'-'+$pair[2]+'.json');Write-WsmJson $specPath $spec
                $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
                Set-WsmMigrationSpec $managerRoot $catalog.PairId $pair[0].ItemId $specPath (Sha $specPath) $revision|Out-Null
            }
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            Set-WsmDecision $managerRoot $catalog.PairId @($itemC.ItemId,$itemN.ItemId) Include 'Explicit G3 selection' $revision|Out-Null
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            $planPath=Join-Path $Root ('approved-plan-'+$Label+'.json')
            $approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $revision 'ISOLATED-PILOT'
            $script:g3Fp=('a'*64)
            $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
            if($import.Status -cne 'ImportedVerified'){throw ('Source did not import the approved '+$Label+' plan.')}
            [pscustomobject]@{Label=$Label;PairId=[string]$catalog.PairId;PlanHash=[string]$approved.SHA256;PlanPath=$planPath;Plan=(Read-WsmMigrationPlan $planPath $approved.SHA256);ManagerRoot=$managerRoot}
        }
        $freezeOwner='G3 freeze owner';$freezeText='Synthetic owner-confirmed quiescence; fixture only.'
        function New-FreezeAuth($PlanInfo){[pscustomobject]@{Proof=(New-WsmSourceFreezeEvidenceFixture -Plan $PlanInfo.Plan -PlanHash $PlanInfo.PlanHash -Root $Root -Owner $freezeOwner)}}
        function New-Token($PlanInfo,[string]$Op){New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $PlanInfo.PairId -PlanHash $PlanInfo.PlanHash -OperationId $Op}
        function Start-Backup($PlanInfo,[string]$Op,$Auth,$Token=$null){
            if(-not $Token){$Token=New-Token $PlanInfo $Op}
            Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $PlanInfo.PairId -OperationId $Op -Owner $freezeOwner -Evidence $freezeText -FreezeAuthorization -FreezeExternalEvidencePath $Auth.Proof.Path -FreezeExternalEvidenceHash $Auth.Proof.SHA256 -Jobs @() -CancellationToken $Token -DeliveryMode Directory -VolumeBytes 0
        }
        function Get-Attempt($PlanInfo,[string]$Op){(Get-WsmWizardBackupAttemptForOperation $sourceRoot $PlanInfo.PairId (Read-WsmOutputProfile $sourceRoot) $Op).Attempt}
        function Count-AttemptFiles($PlanInfo){@(Get-ChildItem -LiteralPath (Get-WsmWizardBackupRoot $sourceRoot $PlanInfo.PairId) -Filter '*.json' -File).Count}
        function Count-FreezeFolders($PlanInfo){$pairs=Join-Path $sourceRoot 'pairs';if(-not [IO.Directory]::Exists($pairs)){return 0};@(Get-ChildItem -LiteralPath $pairs -Directory -Filter ('freeze-'+$PlanInfo.PairId+'-*')).Count}
        function Find-Files([string]$Directory,[string[]]$Patterns){@(Get-ChildItem -LiteralPath $Directory -Recurse -Force -ErrorAction SilentlyContinue|Where-Object {$name=$_.Name;@($Patterns|Where-Object {$name -like $_}).Count -gt 0})}
        # --- the projections under judgement ---
        function Get-HtmlResult($Result){@(Get-WsmHtmlResultProjection @($Result))[0]}
        function Get-HtmlRuntime($PlanInfo,[object[]]$Jobs){ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $sourceRoot -PairId $PlanInfo.PairId -Role Source -Jobs $Jobs)}
        # the console only shows an attempt that a finished StartBackup job record names (jobId in the attempt's OperationIds, output AttemptId)
        function New-BackupJob($PlanInfo,[string]$Op,[string]$Status,$Attempt){[pscustomobject]@{jobId=$Op;action='StartBackup';status=$Status;role='Source';workspace=[IO.Path]::GetFullPath($sourceRoot);pairId=$PlanInfo.PairId;outputs=@([pscustomobject]@{AttemptId=[string]$Attempt.AttemptId})}}
        function Get-Json($Value){ConvertTo-Json -InputObject $Value -Depth 14 -Compress}
        # A "complete backup" claim is: delivered stage, verified offline readiness, a verified-delivered NonC status, a successful overall
        # channel summary, a zero status code, or an available workbench result view. Any of them for a not-finished NonC channel is a lie.
        function Get-CompleteClaims($Result,$HtmlResult,$Runtime,$View){
            $claims=New-Object 'System.Collections.Generic.List[string]'
            if([string]$Result.Status -ceq 'Delivered' -or [string]$Result.Stage -ceq 'Delivered'){$claims.Add('result.Status=Delivered')}
            if([string]$Result.OfflineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed')){$claims.Add('result.OfflineReadiness='+$Result.OfflineReadiness)}
            if([string]$Result.NonCStatus -ceq 'VerifiedDelivered'){$claims.Add('result.NonCStatus=VerifiedDelivered')}
            if($Result.ChannelSummary -and [string]$Result.ChannelSummary.OverallStatus -ceq 'Succeeded'){$claims.Add('result.ChannelSummary.OverallStatus=Succeeded')}
            if((Get-WsmOperationStatusCode $Result) -eq 0){$claims.Add('statusCode=0')}
            if($HtmlResult){if([string]$HtmlResult.Status -ceq 'Delivered' -or ((Has $HtmlResult 'Stage') -and [string]$HtmlResult.Stage -ceq 'Delivered')){$claims.Add('html result Status/Stage=Delivered')};if((Has $HtmlResult 'OfflineReadiness') -and [string]$HtmlResult.OfflineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed')){$claims.Add('html result OfflineReadiness='+$HtmlResult.OfflineReadiness)};if((Has $HtmlResult 'NonCStatus') -and [string]$HtmlResult.NonCStatus -ceq 'VerifiedDelivered'){$claims.Add('html result NonCStatus=VerifiedDelivered')}}
            if($Runtime){if([string]$Runtime.runtime.offlineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed')){$claims.Add('runtime.offlineReadiness='+$Runtime.runtime.offlineReadiness)};$availabilityAttempt=$null;if($Runtime.runtime.backupResult -and (Has $Runtime.runtime.backupResult 'attempt')){$availabilityAttempt=$Runtime.runtime.backupResult.attempt};if($availabilityAttempt -and [string]$availabilityAttempt.Stage -ceq 'Delivered'){$claims.Add('runtime.backupResult.attempt.Stage=Delivered')}}
            if($View -and [bool]$View.available){$claims.Add('workbench result view available')}
            @($claims.ToArray())
        }
        # A retirement / activation judgement would need one of these facts. The backup flow must not produce any of them.
        function Get-RetirementFacts($PlanInfo,$Result,$HtmlResult,$Runtime){
            $facts=New-Object 'System.Collections.Generic.List[string]'
            foreach($name in @('FinalAccepted','RetirementReady','Activated','CutoverReady')){
                if((Has $Result $name) -and [bool]$Result.$name){$facts.Add('result.'+$name)}
                if($HtmlResult -and (Has $HtmlResult $name) -and [bool]$HtmlResult.$name){$facts.Add('html.'+$name)}
            }
            $managerCatalog=Get-WsmCatalog $PlanInfo.ManagerRoot $PlanInfo.PairId
            $stages=@();if($managerCatalog.PSObject.Properties['StageResults']){$stages=@($managerCatalog.StageResults)}
            foreach($row in $stages){if([string]$row.Stage -cin @('Cutover','PostCutoverValidation','Retirement')){$facts.Add('manager StageResult '+$row.Stage)}}
            $sourceFiles=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -in @('cutover.json','activation.json','retirement.json') -or $_.FullName -like '*\cutover*' -or $_.FullName -like '*\retire*'})
            foreach($file in $sourceFiles){$facts.Add('source file '+$file.Name)}
            if($Runtime -and (Has $Runtime.runtime 'actions')){foreach($action in @($Runtime.runtime.actions)){if([string]$action.id -cin @('TargetActivation','TargetAcceptance') -and $action.available -eq $true){$facts.Add('source runtime offers '+$action.id)}}}
            @($facts.ToArray())
        }
        $script:g3OrigPayload=(Get-Command Write-WsmPayloadFile -CommandType Function).ScriptBlock

        # ======================= S1: C captured, NonC capture fails while the freeze is held =======================
        $planA=New-G3Plan 'fz' 'OwnerFreeze'
        $authA=New-FreezeAuth $planA
        $opA=[Guid]::NewGuid().ToString('D')
        $script:g3NonCDir=$dataN
        function script:Write-WsmPayloadFile {param($SourcePath,$BlobRoot,$ChunkBytes,$BytesPerSecond,$CancellationToken=$null);if(([string]$SourcePath).StartsWith($script:g3NonCDir,[StringComparison]::OrdinalIgnoreCase)){throw 'Injected crash while the NonC scope is being captured.'};& $script:g3OrigPayload $SourcePath $BlobRoot $ChunkBytes $BytesPerSecond $CancellationToken}
        try{$crashError=Try-Run {Start-Backup $planA $opA $authA}}finally{Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:g3OrigPayload}
        $attemptA=Get-Attempt $planA $opA
        $resultA=ConvertTo-WsmWizardBackupResult $attemptA $opA
        & $Report 's1_nonc_failed_mid_capture_attempt_failed_freeze_held_nothing_sealed' ($crashError -and $crashError.Message -like '*Injected crash*' -and $attemptA.Stage -ceq 'Failed' -and $attemptA.ResumeStage -ceq 'Authorized' -and $attemptA.Freeze -and $attemptA.SourceResumeRequired -and -not $attemptA.CoreExport) ('Stage='+$attemptA.Stage+' ResumeStage='+$attemptA.ResumeStage)
        $packagesA=Join-Path ([string]$attemptA.OutputRoot) 'packages'
        $partialA=@(Find-Files $packagesA @('artifacts.jsonl.partial'))
        $partialRows=@();if($partialA.Count -eq 1){$partialRows=@(Get-Content -LiteralPath $partialA[0].FullName -Encoding UTF8|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json})}
        $oldC1Hash=Sha $fileC1
        & $Report 's1_c_scope_is_in_the_partial_nonc_scope_is_not_and_no_manifest_exists' ($partialA.Count -eq 1 -and @($partialRows|Where-Object {$_.ItemId -ceq $itemC.ItemId -and -not $_.Directory -and $_.Data.Hash -ceq $oldC1Hash}).Count -eq 1 -and @($partialRows|Where-Object {$_.ItemId -ceq $itemN.ItemId -and -not $_.Directory}).Count -eq 0 -and @(Find-Files $packagesA @('manifest.json','manifest.pending.json')).Count -eq 0) 'C blob captured, no NonC file, nothing sealed'
        $htmlResultA=Get-HtmlResult $resultA
        $jobA=New-BackupJob $planA $opA 'Failed' $attemptA
        $runtimeA=Get-HtmlRuntime $planA @($jobA)
        $viewA=Get-WsmWizardBackupItemResultsView $sourceRoot $planA.PairId
        $claimsA=@(Get-CompleteClaims $resultA $htmlResultA $runtimeA $viewA)
        & $Report 's1_result_html_runtime_and_workbench_projections_do_not_claim_a_complete_backup' ($claimsA.Count -eq 0) $(if($claimsA.Count){'CLAIMS: '+($claimsA -join '; ')}else{'result Status='+$resultA.Status+' html Status='+$htmlResultA.Status+' runtime offlineReadiness='+$runtimeA.runtime.offlineReadiness+' view available='+$viewA.available})
        $statusCodeA=Get-WsmOperationStatusCode $resultA
        & $Report 's1_parent_operation_is_failed_not_success_and_names_the_nonc_channel' ($statusCodeA -eq 1 -and [string]$resultA.Status -ceq 'Failed' -and $viewA.PSObject.Properties['failedAttempt'] -and [string]$viewA.failedAttempt.classification -ceq 'CaptureFailed' -and [string]$viewA.failedAttempt.failedItem.Channel -ceq 'NonC' -and [string]$viewA.failedAttempt.failedItem.ItemId -ceq [string]$itemN.ItemId) ('statusCode='+$statusCodeA+' failedItem.Channel='+$(if($viewA.PSObject.Properties['failedAttempt']){[string]$viewA.failedAttempt.failedItem.Channel}else{'-'}))
        $retireA=@(Get-RetirementFacts $planA $resultA $htmlResultA $runtimeA)
        & $Report 's1_no_retirement_activation_or_acceptance_fact_is_produced' ($retireA.Count -eq 0 -and $resultA.ProductionVerified -eq $false) $(if($retireA.Count){'FACTS: '+($retireA -join '; ')}else{'no StageResult, no gate property, no source cutover file, ProductionVerified=false'})
        & $Report 's1_runtime_projection_offers_source_resume_but_nothing_resumes_or_restarts_by_itself' ([bool]$runtimeA.runtime.sourceFreeze.resumeAvailable -and [string]$runtimeA.runtime.sourceFreeze.resumeRoute.action -ceq 'SourceResume' -and -not [bool]$runtimeA.runtime.sourceFreeze.sourceResumed -and (Count-AttemptFiles $planA) -eq 1 -and (Count-FreezeFolders $planA) -eq 1) ('resumeAvailable='+$runtimeA.runtime.sourceFreeze.resumeAvailable+' sourceResumed='+$runtimeA.runtime.sourceFreeze.sourceResumed+' attempts='+(Count-AttemptFiles $planA)+' freezeFolders='+(Count-FreezeFolders $planA))
        $obs.S1=[ordered]@{AttemptStage=[string]$attemptA.Stage;StatusCode=$statusCodeA;HtmlResultKeys=@($htmlResultA.PSObject.Properties.Name);RuntimeStatus=[string]$runtimeA.status;RuntimeOfflineReadiness=[string]$runtimeA.runtime.offlineReadiness;ViewReason=[string]$viewA.reason}

        # ======================= S2: freeze receipt expired, source changed (new file too), SourceResume, a NEW attempt =======================
        $partialHashA=Sha $partialA[0].FullName;$packagesTreeA=Tree $packagesA
        Set-SourceBytes 'generation-two'
        [IO.File]::WriteAllText($fileCNew,'C file added after the failed attempt')
        $receiptPath=[string]$attemptA.Freeze.Path
        $receipt=Read-WsmJson $receiptPath;$receipt.ProducedUtc=[DateTimeOffset]::UtcNow.AddHours(-3).ToString('o');$receipt.ExpiresUtc=[DateTimeOffset]::UtcNow.AddHours(-1).ToString('o');Write-WsmJson $receiptPath $receipt
        $attemptPathA=Join-Path (Get-WsmWizardBackupRoot $sourceRoot $planA.PairId) ($opA+'.json')
        $record=Read-WsmJson $attemptPathA;$record.Freeze.SHA256=Sha $receiptPath;Write-WsmJson $attemptPathA $record
        $staleJob=$jobA
        $runtimeExpired=Get-HtmlRuntime $planA @($jobA)
        & $Report 's2_runtime_projection_requires_source_resume_once_the_freeze_receipt_expired' ([bool]$runtimeExpired.runtime.sourceFreeze.resumeRequired -and [string]$runtimeExpired.runtime.sourceFreeze.resumeRoute.action -ceq 'SourceResume' -and [string]$runtimeExpired.runtime.offlineReadiness -ceq 'NotDelivered') ('resumeRequired='+$runtimeExpired.runtime.sourceFreeze.resumeRequired+' offlineReadiness='+$runtimeExpired.runtime.offlineReadiness)
        $authStale=New-FreezeAuth $planA
        $opStale=[Guid]::NewGuid().ToString('D');$tokenStale=New-Token $planA $opStale
        $staleError=Try-Run {Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $planA.PairId -OperationId $opStale -Owner $freezeOwner -Evidence $freezeText -FreezeAuthorization -FreezeExternalEvidencePath $authStale.Proof.Path -FreezeExternalEvidenceHash $authStale.Proof.SHA256 -Jobs @($staleJob) -CancellationToken $tokenStale -DeliveryMode Directory -VolumeBytes 0}
        & $Report 's2_expired_freeze_refuses_to_continue_and_names_expiry' ($staleError -and $staleError.Message -like '*expired*') $(if($staleError){[string]$staleError.Message}else{'NOT REFUSED'})
        & $Report 's2_refused_continuation_changed_nothing_old_partial_and_tree_intact' ((Sha $partialA[0].FullName) -ceq $partialHashA -and (Tree $packagesA) -ceq $packagesTreeA -and (Count-AttemptFiles $planA) -eq 1 -and (Get-Attempt $planA $opA).Stage -ceq 'Failed' -and @(Find-Files $packagesA @('manifest.json')).Count -eq 0) 'partial bytes, package tree, attempt count, stage unchanged'
        $planRef=Get-WsmWizardCurrentApprovedPlan $sourceRoot $planA.PairId (Read-WsmOutputProfile $sourceRoot) $null @()
        $freezeReceipt=Read-WsmFreezeRecord $receiptPath (Sha $receiptPath) $planA.Plan $planA.PlanHash -AllowExpired
        $sourceAttemptPath=[string]$freezeReceipt.SourceAttemptPath;$sourceAttemptHash=[string]$freezeReceipt.SourceAttemptHash
        $sourceAttempt=Read-WsmSourceAttempt $sourceAttemptPath $sourceAttemptHash $planA.Plan $planA.PlanHash
        $pairsRoot=Join-Path $sourceRoot 'pairs'
        $resumeProof=New-WsmSourceResumeEvidenceFixture -Plan $planA.Plan -PlanHash $planA.PlanHash -AttemptId $sourceAttempt.State.AttemptId -AttemptHash $sourceAttemptHash -Root $Root -Owner $freezeOwner
        $choices=@(Get-WsmWizardReceivedPlanChoices $sourceRoot (Read-WsmOutputProfile $sourceRoot));$pairIndex=0;for($i=0;$i -lt $choices.Count;$i++){if([string]$choices[$i].pairId -ceq $planA.PairId){$pairIndex=$i+1}};if($pairIndex -lt 1){throw 'The pair is not offered by the typed-text pair picker.'}
        $answers=@{
            ([string][char]0x9078+[char]0x64C7+[char]0x64CD+[char]0x4F5C+[char]0x60C5+[char]0x5883+[char]0x89D2+[char]0x8272)='1'
            ([string][char]0x9078+[char]0x914D+[char]0x5C0D+[char]0x7DE8+[char]0x865F)=[string]$pairIndex
            ([string][char]0x8F38+[char]0x5165+[char]0x5B8C+[char]0x6574+[char]0x64CD+[char]0x4F5C+[char]0x8B58+[char]0x5225+[char]0x78BC)='SourceResume'
            'PlanPath'=$planRef.Path;'ExpectedHash'=$planA.PlanHash;'SourceAttemptPath'=$sourceAttemptPath;'SourceAttemptHash'=$sourceAttemptHash
            'SourceStateDirectory'=$pairsRoot;'Owner'=$freezeOwner;'OwnershipEvidence'='Fixture confirms target stopped and writes reconciled.'
            'Acknowledgement'=('SOURCE-OWNERSHIP-RESTORED '+$planA.PairId);'ResumeExternalEvidencePath'=$resumeProof.Path;'ResumeExternalEvidenceHash'=$resumeProof.SHA256
            'TaskReconciliationPath'='';'TaskReconciliationHash'='';'APPLY'='APPLY'
        }
        $reader={param($prompt) foreach($key in @($answers.Keys|Sort-Object Length -Descending)){if(([string]$prompt).Contains([string]$key)){return [string]$answers[$key]}};throw ('Unexpected SourceResume prompt: '+$prompt)}.GetNewClosure()
        $resumeResult=Invoke-WsmTypedTextOperation -Workspace $sourceRoot -PromptReader $reader
        $resumeJobs=@(Get-WsmTextWizardJobs $sourceRoot $planA.PairId 'Source')
        & $Report 's2_source_resume_consumer_released_the_source_explicitly' ($resumeResult.Status -ceq 'Applied' -and @($resumeResult.Result|Where-Object Status -ceq 'SourceResumed').Count -eq 1) ([string]$resumeResult.Status)
        $authNew=New-FreezeAuth $planA
        $opNew=[Guid]::NewGuid().ToString('D');$tokenNew=New-Token $planA $opNew
        $newResult=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $planA.PairId -OperationId $opNew -Owner $freezeOwner -Evidence $freezeText -FreezeAuthorization -FreezeExternalEvidencePath $authNew.Proof.Path -FreezeExternalEvidenceHash $authNew.Proof.SHA256 -Jobs (@($staleJob)+$resumeJobs) -CancellationToken $tokenNew -DeliveryMode Directory -VolumeBytes 0
        $attemptNew=Get-Attempt $planA $opNew
        & $Report 's2_new_attempt_has_its_own_output_root_freeze_epoch_and_sealed_final_package' ($attemptNew.AttemptId -cne $attemptA.AttemptId -and [string]$attemptNew.OutputRoot -cne [string]$attemptA.OutputRoot -and $attemptNew.FreezeEpoch -cne $attemptA.FreezeEpoch -and $attemptNew.CoreExport.Sealed -and $attemptNew.CoreExport.Final -and [string]$attemptNew.Freeze.SHA256 -cne [string]$attemptA.Freeze.SHA256) ('old '+$attemptA.AttemptId.Substring(0,8)+' new '+$attemptNew.AttemptId.Substring(0,8))
        $packageNew=Test-WsmMigrationPackage ([string]$attemptNew.CoreExport.ManifestPath) ([string]$attemptNew.CoreExport.SHA256)
        $rowsNew=@(Read-WsmArtifactLines (Join-Path $packageNew.Root 'artifacts.jsonl') $packageNew.Manifest.ArtifactsHash|Where-Object {-not $_.Directory})
        $expectedNew=@(Sha $fileC1;Sha $fileCNew;Sha $fileN1;Sha $fileN2)|Sort-Object
        $actualNew=@($rowsNew|ForEach-Object {[string]$_.Data.Hash}|Sort-Object)
        & $Report 's2_new_generation_holds_only_the_new_bytes_including_the_added_file_and_no_old_blob' ((($actualNew -join ',') -ceq ($expectedNew -join ',')) -and @($rowsNew|Where-Object {$_.Data.Hash -ceq $oldC1Hash}).Count -eq 0 -and $packageNew.Manifest.Generation -eq 1 -and $packageNew.Manifest.Files -eq 4) ('files='+$packageNew.Manifest.Files+' generation='+$packageNew.Manifest.Generation)
        & $Report 's2_old_failed_attempt_partial_and_tree_untouched_by_the_new_attempt' ((Sha $partialA[0].FullName) -ceq $partialHashA -and (Tree $packagesA) -ceq $packagesTreeA) 'old partial index and old package tree unchanged'
        $parentAfter=ConvertTo-WsmWizardBackupResult (Get-Attempt $planA $opA) $opA
        & $Report 's2_old_parent_stays_failed_and_carries_no_package_or_delivery_from_the_new_attempt' ((Get-WsmOperationStatusCode $parentAfter) -eq 1 -and -not $parentAfter.Delivery -and -not $parentAfter.CoreExport -and [string]$parentAfter.Status -ceq 'Failed') ([string]$parentAfter.Status)
        # the new attempt's own result: C is delivered, NonC is not -> not complete, not success
        $jobNew=New-BackupJob $planA $opNew 'ReviewRequired' $attemptNew
        $htmlNew=Get-HtmlResult $newResult;$runtimeNew=Get-HtmlRuntime $planA @($staleJob,$jobNew);$viewNew=Get-WsmWizardBackupItemResultsView $sourceRoot $planA.PairId
        $claimsNew=@(Get-CompleteClaims $newResult $htmlNew $runtimeNew $viewNew)
        & $Report 's2_c_delivered_does_not_mask_nonc_result_is_review_required_with_nonc_pending' ([string]$newResult.Status -ceq 'ReviewRequired' -and [string]$newResult.ChannelSummary.C.Status -ceq 'VerifiedDelivered' -and [string]$newResult.NonCStatus -ceq 'RequiresTargetTransferAndManagerResultImport' -and [string]$newResult.ChannelSummary.OverallStatus -ceq 'ReviewRequired' -and (Get-WsmOperationStatusCode $newResult) -eq 2) ('Status='+$newResult.Status+' C='+$newResult.ChannelSummary.C.Status+' NonC='+$newResult.NonCStatus+' statusCode='+(Get-WsmOperationStatusCode $newResult))
        & $Report 's2_result_html_runtime_and_workbench_projections_do_not_claim_a_complete_backup' ($claimsNew.Count -eq 0) $(if($claimsNew.Count){'CLAIMS: '+($claimsNew -join '; ')}else{'html Status='+$htmlNew.Status+' runtime offlineReadiness='+$runtimeNew.runtime.offlineReadiness+' view available='+$viewNew.available})
        $resultsDoc=Read-WsmJson ([string]$newResult.ItemResults.Path)
        $rowC=@($resultsDoc.Rows|Where-Object {[string]$_.ItemId -ceq [string]$itemC.ItemId});$rowN=@($resultsDoc.Rows|Where-Object {[string]$_.ItemId -ceq [string]$itemN.ItemId})
        & $Report 's2_item_results_list_nonc_as_not_backed_up_with_its_own_reason_while_c_is_backed_up' ($rowC.Count -eq 1 -and $rowN.Count -eq 1 -and [string]$rowC[0].Status -ceq 'BackedUp' -and [string]$rowN[0].Status -ceq 'NotBackedUp' -and [string]$rowN[0].ReasonCode -ceq 'SeparateNonCTransfer' -and [string]$rowN[0].Channel -ceq 'NonC') ('C='+$rowC[0].Status+' NonC='+$rowN[0].Status+'/'+$rowN[0].ReasonCode)
        $reportHtml=[IO.File]::ReadAllText([string]$newResult.OfflineReport.Path,[Text.Encoding]::UTF8)
        $nonCNameIndex=$reportHtml.IndexOf('G3 NonC scope')
        & $Report 's2_offline_report_html_shows_the_nonc_reason_code_and_never_lists_it_as_backed_up' ($nonCNameIndex -ge 0 -and $reportHtml.Contains('SeparateNonCTransfer') -and $reportHtml.Contains('G3 C scope')) 'the report names the NonC scope with its reason code'
        $retireNew=@(Get-RetirementFacts $planA $newResult $htmlNew $runtimeNew)
        & $Report 's2_no_retirement_activation_or_acceptance_fact_after_the_new_attempt' ($retireNew.Count -eq 0 -and $newResult.ProductionVerified -eq $false) $(if($retireNew.Count){'FACTS: '+($retireNew -join '; ')}else{'none; ProductionVerified=false'})
        $obs.S2=[ordered]@{NewStatus=[string]$newResult.Status;NewNonC=[string]$newResult.NonCStatus;OverallStatus=[string]$newResult.ChannelSummary.OverallStatus;ViewAvailable=[bool]$viewNew.available;ViewReason=[string]$viewNew.reason;RuntimeOfflineReadiness=[string]$runtimeNew.runtime.offlineReadiness;HtmlResultStatus=[string]$htmlNew.Status}

        # ======================= S3: cancel while the NonC scope is captured, then resume the same attempt =======================
        $planB=New-G3Plan 'cx' 'OwnerFreeze'
        $authB=New-FreezeAuth $planB
        Set-SourceBytes 'generation-three'
        [IO.File]::Delete($fileCNew)
        $opCancel=[Guid]::NewGuid().ToString('D');$tokenCancel=New-Token $planB $opCancel
        $script:g3CancelToken=$tokenCancel
        function script:Write-WsmPayloadFile {param($SourcePath,$BlobRoot,$ChunkBytes,$BytesPerSecond,$CancellationToken=$null);if(([string]$SourcePath).StartsWith($script:g3NonCDir,[StringComparison]::OrdinalIgnoreCase)){Request-WsmCancellation -Token $script:g3CancelToken -Owner 'G3 operator' -Evidence 'Cancel while the NonC scope is captured' | Out-Null};& $script:g3OrigPayload $SourcePath $BlobRoot $ChunkBytes $BytesPerSecond $CancellationToken}
        try{$cancelError=Try-Run {Start-Backup $planB $opCancel $authB $tokenCancel}}finally{Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:g3OrigPayload}
        $attemptCancel=Get-Attempt $planB $opCancel
        $resultCancel=ConvertTo-WsmWizardBackupResult $attemptCancel $opCancel
        & $Report 's3_cancel_stopped_the_capture_attempt_cancelled_and_resumable_nothing_sealed' ($cancelError -and $attemptCancel.Stage -ceq 'Cancelled' -and $attemptCancel.ResumeStage -ceq 'Authorized' -and -not $attemptCancel.CoreExport -and $resultCancel.CanResumeAfterReview -and @(Find-Files (Join-Path ([string]$attemptCancel.OutputRoot) 'packages') @('manifest.json')).Count -eq 0) ('Stage='+$attemptCancel.Stage+' CanResumeAfterReview='+$resultCancel.CanResumeAfterReview)
        $jobCancel=New-BackupJob $planB $opCancel 'Cancelled' $attemptCancel
        $htmlCancel=Get-HtmlResult $resultCancel;$runtimeCancel=Get-HtmlRuntime $planB @($jobCancel);$viewCancel=Get-WsmWizardBackupItemResultsView $sourceRoot $planB.PairId
        $claimsCancel=@(Get-CompleteClaims $resultCancel $htmlCancel $runtimeCancel $viewCancel)
        $codeCancel=Get-WsmOperationStatusCode $resultCancel
        & $Report 's3_cancelled_parent_is_not_success_and_no_projection_claims_a_complete_backup' ($codeCancel -eq 3 -and $claimsCancel.Count -eq 0) $(if($claimsCancel.Count){'CLAIMS: '+($claimsCancel -join '; ')}else{'statusCode='+$codeCancel})
        $retireCancel=@(Get-RetirementFacts $planB $resultCancel $htmlCancel $runtimeCancel)
        & $Report 's3_cancel_produces_no_retirement_fact_and_does_not_restart_or_resume_by_itself' ($retireCancel.Count -eq 0 -and (Count-AttemptFiles $planB) -eq 1 -and (Count-FreezeFolders $planB) -eq 1 -and [bool]$runtimeCancel.runtime.sourceFreeze.resumeAvailable -and -not [bool]$runtimeCancel.runtime.sourceFreeze.sourceResumed) ('attempts='+(Count-AttemptFiles $planB)+' freezeFolders='+(Count-FreezeFolders $planB)+' resumeAvailable='+$runtimeCancel.runtime.sourceFreeze.resumeAvailable)
        $cancelPartial=@(Find-Files (Join-Path ([string]$attemptCancel.OutputRoot) 'packages') @('artifacts.jsonl.partial'))
        $oldCancelC1=Sha $fileC1;$oldCancelBlob=''
        $cancelRows=@();if($cancelPartial.Count -eq 1){$cancelRows=@(Get-Content -LiteralPath $cancelPartial[0].FullName -Encoding UTF8|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json})}
        if($cancelPartial.Count -eq 1){$oldCancelBlob=Join-Path (Join-Path (Split-Path -Parent $cancelPartial[0].FullName) 'payload') ($oldCancelC1+'.blob')}
        & $Report 's3_cancelled_partial_holds_the_c_blob_and_no_nonc_file_until_the_resume' ($cancelPartial.Count -eq 1 -and @($cancelRows|Where-Object {$_.ItemId -ceq $itemC.ItemId -and -not $_.Directory -and $_.Data.Hash -ceq $oldCancelC1}).Count -eq 1 -and @($cancelRows|Where-Object {$_.ItemId -ceq $itemN.ItemId -and -not $_.Directory}).Count -eq 0) 'partial kept for inspection after the cancel'
        Set-SourceBytes 'generation-four'
        $opResume=[Guid]::NewGuid().ToString('D')
        $resumed=Start-Backup $planB $opResume $authB
        $attemptResumed=Get-Attempt $planB $opResume
        $packageResumed=Test-WsmMigrationPackage ([string]$attemptResumed.CoreExport.ManifestPath) ([string]$attemptResumed.CoreExport.SHA256)
        $rowsResumed=@(Read-WsmArtifactLines (Join-Path $packageResumed.Root 'artifacts.jsonl') $packageResumed.Manifest.ArtifactsHash|Where-Object {-not $_.Directory})
        $expectedResumed=@(Sha $fileC1;Sha $fileN1;Sha $fileN2)|Sort-Object
        $actualResumed=@($rowsResumed|ForEach-Object {[string]$_.Data.Hash}|Sort-Object)
        & $Report 's3_resume_continues_the_same_attempt_without_a_second_attempt_or_freeze' ($attemptResumed.AttemptId -ceq $attemptCancel.AttemptId -and [int]$attemptResumed.ResumeCount -eq 1 -and (Count-AttemptFiles $planB) -eq 1 -and $attemptResumed.CoreExport.Sealed) ('ResumeCount='+$attemptResumed.ResumeCount+' attempts='+(Count-AttemptFiles $planB))
        & $Report 's3_resumed_generation_is_not_spliced_only_new_bytes_no_pre_cancel_blob' ((($actualResumed -join ',') -ceq ($expectedResumed -join ',')) -and @($rowsResumed|Where-Object {$_.Data.Hash -ceq $oldCancelC1}).Count -eq 0 -and $packageResumed.Manifest.Generation -eq 1 -and $packageResumed.Manifest.Files -eq 3) ('files='+$packageResumed.Manifest.Files)
        & $Report 's3_resumed_attempt_leaves_no_pre_cancel_blob_in_its_sealed_package' (-not [IO.File]::Exists($oldCancelBlob) -or @($rowsResumed|Where-Object {$_.Data.Hash -ceq $oldCancelC1}).Count -eq 0) 'the pre-cancel C blob hash is not referenced by the sealed index'
        $jobResumed=New-BackupJob $planB $opResume 'ReviewRequired' $attemptResumed
        $htmlResumed=Get-HtmlResult $resumed;$runtimeResumed=Get-HtmlRuntime $planB @($jobCancel,$jobResumed);$viewResumed=Get-WsmWizardBackupItemResultsView $sourceRoot $planB.PairId
        $claimsResumed=@(Get-CompleteClaims $resumed $htmlResumed $runtimeResumed $viewResumed)
        & $Report 's3_resumed_result_keeps_nonc_pending_and_claims_no_complete_backup' ([string]$resumed.NonCStatus -ceq 'RequiresTargetTransferAndManagerResultImport' -and [string]$resumed.Status -ceq 'ReviewRequired' -and $claimsResumed.Count -eq 0) $(if($claimsResumed.Count){'CLAIMS: '+($claimsResumed -join '; ')}else{'Status='+$resumed.Status+' NonC='+$resumed.NonCStatus})
        $obs.S3=[ordered]@{CancelStage=[string]$attemptCancel.Stage;CancelStatusCode=$codeCancel;ResumedStatus=[string]$resumed.Status}
        $obs
    } $script:GTestRoot $fixturePath $Mutation ${function:Set-GCheck} ($wsDrive+':'+[char]92) ($volDrive+':'+[char]92)
    $script:GVerdict.Observations=$observations

    Write-GStage 3 'snapshot unchanged, test bytes recorded'
    Confirm-GSnapshotUnchanged @((Join-Path $PSScriptRoot 'G-ScenarioCommon.ps1'),$PSCommandPath)
}
catch{
    $script:GVerdict.Error=[string]$_.Exception.Message
    $script:GVerdict.ErrorPosition=[string]$_.InvocationInfo.PositionMessage
    $script:GVerdict.ErrorStack=[string]$_.ScriptStackTrace
    $innerMessages=@();$inner=$_.Exception.InnerException;while($inner){$innerMessages+=@([string]$inner.Message);if($inner -is [Management.Automation.IContainsErrorRecord]){$innerMessages+=@([string]$inner.ErrorRecord.InvocationInfo.PositionMessage,[string]$inner.ErrorRecord.ScriptStackTrace)};$inner=$inner.InnerException};$script:GVerdict.ErrorInner=$innerMessages
    Write-Host ('FAILED: '+$_.Exception.Message)
    $script:GFailed=$true
}
finally{
    $overall=Complete-GScenario ([bool]$KeepArtifacts)
}
if($overall -cne 'Passed'){exit 1}
