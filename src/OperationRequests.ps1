function Get-WsmOperationActions {
    [ordered]@{SourceCandidateScan='Invoke-WsmSourceCandidateScan';NonCTargetHandoffExport='Export-WsmWizardNonCTargetHandoff';NonCTargetHandoffPreview='Get-WsmWizardNonCTargetHandoffPreview';NonCTargetHandoffImport='Import-WsmWizardNonCTargetHandoff';NonCSourceProofExport='Export-WsmWizardNonCSourceProofHandoff';NonCTargetProofExport='Export-WsmWizardNonCTargetProofHandoff';NonCProofPreview='Get-WsmWizardNonCProofHandoffPreview';NonCProofImport='Import-WsmWizardNonCProofHandoff';TargetZipImport='Import-WsmWizardTargetZipPackage';TargetDirectoryImport='Import-WsmWizardTargetDirectoryPackage';BackupImpactPreview='Get-WsmWizardBackupImpactPreview';ComparisonExport='Export-WsmWizardTargetComparison';ComparisonImport='Import-WsmWizardTargetComparison';TargetLocalComparison='New-WsmWizardTargetLocalComparison';CreateNonCTransferPlan='New-WsmWizardNonCTransferPlan';CreateTargetDecisionReceipt='Create-WsmWizardTargetDecisionReceipt';ImportNonCResult='Import-WsmWizardNonCResult';ImportNonCTransferPlan='Import-WsmWizardNonCTransferPlan';NonCAccountObservation='Get-WsmWizardNonCAccountObservations';NonCPreparation='Get-WsmWizardNonCPreparation';StartBackup='Invoke-WsmWizardStartBackup';IndependentCopy='Invoke-WsmWizardIndependentCopy';StartNonCTransfer='Invoke-WsmWizardNonCTransfer';TargetAcceptance='Get-WsmWizardTargetAcceptanceGates';TargetActivation='Invoke-WsmWizardTargetActivation';TargetRestore='Invoke-WsmWizardTargetRestore';TargetRestorePreview='Get-WsmWizardTargetRestoreProjection';TargetValidation='Invoke-WsmWizardTargetValidation';WizardRuntimeProjection='Get-WsmWizardRuntimeProjection';BulkPreparationPreview='Get-WsmWizardBulkPreparationPreview';BulkPreparationSave='Save-WsmWizardBulkPreparationReview';ExportTargetHandoff='Export-WsmWizardTargetHandoff';GetTargetHandoffPreview='Get-WsmWizardTargetHandoffPreview';CommitTargetHandoff='Commit-WsmWizardTargetHandoff';GetPreparationReview='Get-WsmWizardPreparationReview';SavePreparationReview='Save-WsmWizardPreparationReview';OsProvidedCapture='Export-WsmAssistiveOsProvidedTaskCapture';OsProvidedBaseline='Export-WsmAssistiveOsProvidedBaseline';OsProvidedReview='Get-WsmAssistiveOsProvidedReview';OsProvidedSubmit='Submit-WsmAssistiveOsProvidedReview';RequirementReview='Get-WsmAssistiveGeneralHostRequirementReview';RequirementDecisionSubmit='Submit-WsmAssistiveGeneralHostRequirementDecisions';PreparationPreview='Get-WsmAssistivePreparationPreview';PreparationEvidence='Export-WsmAssistivePreparationEvidence';WindowsSettingsPreviewExport='Export-WsmAssistiveWindowsSettingsPreview';WindowsSettingsSubmit='Submit-WsmAssistiveWindowsSettingsReview';DispositionSubmit='Submit-WsmAssistiveGeneralHostDispositions';RequirementSubmit='Submit-WsmAssistiveGeneralHostRequirements';HttpIntegrityProbe='Export-WsmAssistiveHttpProbe';SpecReview='Get-WsmAssistiveSpecReview';SaveSpecReview='Submit-WsmAssistiveSpecReview';TargetReceipt='Export-WsmAssistiveTargetDecisionReceipt';AssistiveReport='Export-WsmAssistiveReport';AssistiveReportCheck='Test-WsmAssistiveReport';AssistiveComparison='Get-WsmAssistiveComparison';PublishComparison='Update-WsmAssistiveComparison';TargetSnapshot='Update-WsmAssistiveTargetSnapshot';SetSoftwareVersion='Set-WsmAssistiveSoftwareVersion';FilePlacementPreview='Get-WsmFilePlacementPreview';NonCPeerProof='New-WsmAssistivePeerShareProof';NonCPhysicalProof='New-WsmAssistiveTargetPhysicalProof';NonCPlan='New-WsmAssistiveNonCTransferPlan';NonCTransfer='Invoke-WsmAssistiveNonCTransfer';NonCImport='Import-WsmAssistiveNonCResult';ReservationPreview='Get-WsmAssistiveResourceReservationPreview';ReserveResource='Reserve-WsmAssistiveResource';ResourceEvidence='Set-WsmAssistiveResourceEvidence';ReleaseResource='Release-WsmAssistiveResource';RegisterMaterial='Register-WsmAssistiveMaterialReference';CloseMaterial='Set-WsmAssistiveMaterialClosed';JobLock='Set-WsmAssistiveJobLock';MaterialJobStatus='Export-WsmAssistiveMaterialJobStatus';CleanupPreview='Get-WsmAssistiveCleanupPreview';Cleanup='Invoke-WsmAssistiveCleanup';EnvironmentProbe='Export-WsmAssistiveEnvironmentProbe';ProbeImport='Import-WsmAssistiveEnvironmentProbe';AssistiveEnable='Enable-WsmAssistiveMode';AssistiveSelections='Set-WsmAssistiveSelections';AssistiveTargetDecisionReceipt='New-WsmAssistiveTargetDecisionReceipt';WorkspaceTransferPreview='New-WsmOutputWorkspaceTransferPreview';WorkspaceTransfer='Invoke-WsmOutputWorkspaceTransfer';WorkspaceTransferRestorePreview='New-WsmOutputWorkspaceTransferRestorePreview';WorkspaceTransferRestore='Invoke-WsmOutputWorkspaceTransferRestore';DeliveryDocument='Export-WsmDeliveryDocument';ImportedDeliveryReceipt='Export-WsmImportedDeliveryReceipt';DeliveryReceiptImport='Import-WsmDeliveryReceipt';WindowsSettingsPreview='Get-WsmWindowsSettingsReviewWorkspacePreview';WindowsSettingsApply='Apply-WsmWindowsSettingsReview';QualificationSigningRequest='New-WsmQualificationSigningRequest';QualificationSigningComplete='Complete-WsmQualificationSigningRequest';CheckToolRelease='Test-WsmToolRelease';DeltaDirectory='Export-WsmArtifactDeltaDirectory';DeltaDirectoryImport='Import-WsmArtifactDeltaDirectory';GeneralHostMode='Set-WsmGeneralHostMode';SoftwareAttach='Set-WsmGeneralHostSoftwareCatalog';DispositionPreview='Get-WsmGeneralHostDispositionPreview';DispositionApply='Set-WsmGeneralHostDispositions';RequirementPreview='Get-WsmGeneralHostRequirementPreview';RequirementApply='Set-WsmGeneralHostRequirements';GeneralHostEvidence='Import-WsmGeneralHostEvidence';SoftwareEvidence='Export-WsmSoftwareCatalogEvidence';OutputInitialize='Initialize-WsmOutputWorkspace';OutputResolve='Resolve-WsmOutputWorkspace';OutputRegisterPair='Register-WsmOutputPair';OutputConfirmState='Confirm-WsmOutputOperationState';OutputPreferences='Set-WsmOutputPreferences';EnrolledInventory='Export-WsmEnrolledInventory';EnrolledDelivery='Export-WsmEnrolledPackageDelivery';DirectoryDelivery='Export-WsmDirectoryDelivery';DirectoryImport='Import-WsmDirectoryDelivery';OracleBindingTemplate='Export-WsmOracleConsumerBindingTemplate';OracleConfigDraft='Get-WsmOracleClientConfigDraft';EnvironmentConfirmation='Export-WsmEnvironmentConfirmation';DeltaVolumes='Export-WsmArtifactDeltaVolumes';DeltaVolumeImport='Import-WsmArtifactDeltaVolumes';LabReport='Export-WsmLabValidationReport';ConfigReview='Export-WsmConfigArtifactReview';ConfigScopeDraft='Export-WsmConfigArtifactScopeDraft';DeltaManifest='New-WsmArtifactDeltaManifest';DeltaCheck='Test-WsmArtifactDeltaManifest';DeltaZip='Export-WsmArtifactDeltaZip';DeltaImport='Import-WsmArtifactDeltaZip';DeltaRestore='Invoke-WsmArtifactDeltaRestore';DeltaRepair='Repair-WsmArtifactDeltaRestore';CancellationToken='New-WsmCancellationToken';RequestCancellation='Request-WsmCancellation';GroupPlan='New-WsmConsistencyGroupPlan';GroupReceipt='New-WsmConsistencyGroupReceipt';GroupBarrier='Assert-WsmConsistencyGroupBarrier';RollbackResult='Export-WsmRollbackResult';QualificationKey='Get-WsmQualificationRecordKey';QualificationRecord='New-WsmQualificationRecord';QualificationAdd='Add-WsmQualification';QualificationRevoke='Revoke-WsmQualification';QualificationLookup='Resolve-WsmProductionQualification';QualificationMatrix='Get-WsmQualificationMatrix';SourceTaskTemplate='Export-WsmSourceTaskReconciliationTemplate';SourceResume='Invoke-WsmSourceResume';SpecBundleExport='Export-WsmMigrationSpecBundle';SpecBundlePreview='Get-WsmMigrationSpecBundlePreview';SpecBundleImport='Import-WsmMigrationSpecBundle';RepairWorkspace='Repair-WsmWorkspace';RawEvidence='Export-WsmRawEvidenceManifest';RegisterTarget='Register-WsmTarget';ToolRelease='Export-WsmToolRelease';SourceResult='Export-WsmSourceStageResult';IdentityMap='Set-WsmIdentityMap';ConfigureMigration='Set-WsmMigrationSpec';ApproveMigration='Approve-WsmMigrationPlan';EstimatePackage='Get-WsmPackageEstimate';ExportPackage='Export-WsmMigrationPackage';CheckPackage='Test-WsmMigrationPackage';RestorePreview='Get-WsmRestorePreview';Restore='Invoke-WsmRestore';FreezeSource='Export-WsmFreezeRecord';ValidationEvidence='Set-WsmValidationEvidence';Validate='Invoke-WsmValidation';CutoverPlan='New-WsmCutoverPlan';Cutover='Invoke-WsmCutover';Acceptance='Get-WsmAcceptanceGates';ExportResult='Export-WsmStageResult';Repair='Repair-WsmOperation';RollbackPreview='Get-WsmRollbackPreview';Rollback='Invoke-WsmRollback';CheckJournal='Test-WsmJournal';PackageZip='Export-WsmPackageZip';ImportPackageZip='Import-WsmPackageZip';MigrationReport='Export-WsmOperationReport';ImportApprovedPlan='Import-WsmWizardApprovedPlan';InspectWizardFiles='Export-WsmWizardFileDetails';ExportSourceReviewHandoff='Export-WsmWizardSourceReviewHandoff';ImportSourceReviewHandoff='Import-WsmWizardSourceReviewHandoff';SourceCandidateConfirmExport='Export-WsmSourceCandidateConfirmation';SourceCandidateConfirmImport='Import-WsmSourceCandidateConfirmation';SourceCandidateConfirmReview='Get-WsmSourceCandidateConfirmationReview';SourceCandidateMappingReview='Get-WsmSourceCandidateWorkloadMappingReview';SourceCandidateMappingSubmit='Submit-WsmSourceCandidateWorkloadMappingReview';SoftwareDispositionReview='Get-WsmAssistiveSoftwareDispositionReview';SoftwareDispositionReviewSubmit='Submit-WsmAssistiveSoftwareDispositionReview'}
}
function Invoke-WsmOperationRequest {
    [CmdletBinding(SupportsShouldProcess)]param([string]$Path,[string]$ExpectedHash,[hashtable]$Secrets=@{})
    $request=Read-WsmTrustedJson $Path $ExpectedHash;Assert-WsmEnvelope $request 'OperationRequest';Assert-WsmFields $request @('SchemaVersion','ToolVersion','Kind','Action','Arguments') @('SchemaVersion','ToolVersion','Kind','Action','Arguments')
    $actions=Get-WsmOperationActions;if(-not $actions.Contains($request.Action)){throw (New-WsmContractError 'Unknown operation request action.')};$command=Get-Command $actions[$request.Action] -CommandType Function
    $arguments=@{};foreach($p in $request.Arguments.PSObject.Properties){if(-not $command.Parameters.ContainsKey($p.Name) -or $p.Name -in @('Secrets','Verbose','Debug','ErrorAction','ErrorVariable','OutVariable','OutBuffer','PipelineVariable','InformationAction','InformationVariable','WarningAction','WarningVariable','Confirm','WhatIf')){throw (New-WsmContractError ('Unsupported request parameter: '+$p.Name))};$parameter=$command.Parameters[$p.Name];if($parameter.ParameterType -eq [scriptblock] -or @($parameter.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.DontShow}).Count){throw (New-WsmContractError 'Internal request parameters prohibited.')};$value=$p.Value;if($p.Name -eq 'SidMap'){$value=@{};foreach($entry in $p.Value.PSObject.Properties){$value[$entry.Name]=[string]$entry.Value}};if($command.Parameters[$p.Name].ParameterType -in @([hashtable],[System.Collections.IDictionary])){$typed=@{};foreach($entry in $value.PSObject.Properties){$typed[$entry.Name]=$entry.Value};if($p.Name -ceq 'Fields' -and $typed.ContainsKey('IisPoolSettings')){$pool=@{};foreach($entry in $typed.IisPoolSettings.PSObject.Properties){$pool[$entry.Name]=$entry.Value};$typed.IisPoolSettings=$pool};$value=$typed};$arguments[$p.Name]=$value}
    if($command.Parameters.ContainsKey('Secrets')){$arguments.Secrets=$Secrets}
    foreach($parameter in $command.Parameters.Values){$mandatory=@($parameter.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0;if($mandatory -and (-not $arguments.ContainsKey($parameter.Name) -or $null -eq $arguments[$parameter.Name])){throw (New-WsmContractError ('Required request parameter missing; noninteractive prompts prohibited: '+$parameter.Name))}}
    if($WhatIfPreference -and $command.Parameters.ContainsKey('WhatIf')){$arguments.WhatIf=$true}
    if(-not $command.Parameters.ContainsKey('WhatIf')){
        if(-not $PSCmdlet.ShouldProcess([string]$request.Action,'Execute the validated local operation request')){return [pscustomobject]@{Kind='OperationRequestPreview';Action=[string]$request.Action;Status='NotStarted';Executed=$false;GatesEvaluated=$false;NextStep='Use the dedicated DispositionPreview, RequirementPreview, RestorePreview, RollbackPreview or CutoverPlan operation to evaluate its contract.'}}
    }
    # Only this locally installed allowlist is executable. Requests contain typed data, never commands.
    & $command @arguments
}
function Get-WsmOperationStatusCode($Result) {
    $code=0
    $knownStates=@('Delivered','Exported','ReadyForExplicitCommit','ReadyForExplicitBulkReview','Export','Retirement','PostCutoverValidation','Activated','Previewed','EvidenceRecorded','ObservedMatches','AddingTemporaryDeny','Applied','Blocked','BlockedByOpenHandles','BlockedConflict','BudgetExceeded','Cancelled','Captured','CloseCommandSucceeded','CloseFailed','CloseFailedObservedGone','CloseFailedStillOpen','CloseIntent','ClosingReviewedHandles','Completed','CoverageGap','Cutover','DeferredSoftware','Draft','Exporting','External','ExternalProductWorkflowRequired','ExternalRequired','FAIL','Failed','Frozen','Generated','ImportedVerified','IndexValidationFailed','Intent','Interrupted','Inventory','Manual','ManualEvidenceRequired','Mapped','Migrated','NeedsOwnerReview','NetworkApplied','NoApproval','NoChange','NoReceipt','NotAvailable','NotFound','NotInstalled','NotLoaded','NotObserved','NotSearched','NotStarted','NotTested','NotApplicable','NotRun','NotNeeded','OwnerAttestedStaticOnly','OwnerReviewRequired','PASS','Partial','Pending','PermissionDenied','PostCutoverValidationRequired','PreCutoverValidation','Prepared','ProjectionHashVerified','ProviderVersionSpecificBehaviorRequiresOwnerObservation','Quiesced','Quiescing','Read','ReadStaticConfigOnly','Ready','RebootRequired','RecoveredApplied','RecoveredPriorReadback','RenameRebootRequired','ReportLocatorOnly','ReportOnly','RequiresReview','Restored','RestoredPriorValue','Restore','ReviewRequired','RetryPending','RollbackEvidenceComplete','RollbackRunning','RolledBack','Running','Sealed','Skipped','SourceResumed','Succeeded','SucceededWithWarnings','Success','Unknown','Unavailable','Unmapped','UnresolvedPath','Unsupported','Verified','VerifiedTrustedBase','WaitForInstall','WaitForOwner','WaitingForInput','None')
    foreach($r in @($Result)){
        if($null -eq $r){continue}
        $states=@();foreach($field in @('Stage','Status')){if($r.PSObject.Properties[$field]){$states+=@([string]$r.$field)}}
        if($r.PSObject.Properties['Result'] -and $r.Result -and $r.Result.PSObject.Properties['Kind'] -and $r.Result.Kind -ceq 'StageResult' -and $r.Result.PSObject.Properties['Status']){$states+=@([string]$r.Result.Status)}
        if($states -ccontains 'Failed' -or $states -ccontains 'FAIL'){return 1}
        if($states -ccontains 'Cancelled'){$code=3;continue}
        $blocked=@($states | Where-Object {$_ -cin @('NotStarted','Ready','Running','WaitingForInput','Blocked','BlockedByOpenHandles','BlockedConflict','Partial','RetryPending','ManualEvidenceRequired','RebootRequired','PostCutoverValidationRequired','ReviewRequired','DeferredSoftware','WaitForInstall','NotInstalled','PermissionDenied','Unsupported','NotTested','NeedsOwnerReview','Interrupted','NeedsNewPreview','Superseded','Unmapped','Manual') -or ($_.Length -gt 0 -and $_ -cnotin $knownStates)}).Count -gt 0
        if($r.PSObject.Properties['Qualified'] -and -not $r.Qualified){$blocked=$true}
        if($r.PSObject.Properties['Blocked'] -and $r.Blocked){$blocked=$true}
        if($r.PSObject.Properties['Passed'] -and -not $r.Passed){$blocked=$true}
        if($r.PSObject.Properties['FinalAccepted'] -and (-not $r.FinalAccepted -or -not $r.RetirementReady)){$blocked=$true}
        if($blocked -and $code -eq 0){$code=2}
    }
    $code
}

function Read-WsmTextEntry([string]$Prompt,[scriptblock]$PromptReader) {
    if($PromptReader){return & $PromptReader $Prompt}
    $answer=Read-Host $Prompt
    if($null -eq $answer){throw (New-Object IO.EndOfStreamException('Console input ended.'))}
    [string]$answer
}
function Get-WsmTextMetadataValue($Metadata,[string]$Name,$Default=$null) {
    if($Metadata -is [System.Collections.IDictionary]){if($Metadata.Contains($Name)){return $Metadata[$Name]};return $Default}
    if($Metadata -and $Metadata.PSObject.Properties[$Name]){return $Metadata.$Name}
    $Default
}
function Get-WsmTextActionGroup([string]$Action) {
    # B5: C2/D2 actions are named explicitly because the prefix patterns below would otherwise classify the SourceCandidate* review actions as Source.
    # Role follows the function's own check: Export-WsmSourceCandidateConfirmation requires the enrolled Source profile; the others read or write the Manager pair catalog.
    if($Action -in @('SourceCandidateList','SourceCandidateConfirmExport')){return 'Source'}
    if($Action -in @('SourceCandidateConfirmImport','SourceCandidateConfirmReview','SourceCandidateMappingReview','SourceCandidateMappingSubmit','SoftwareDispositionReview','SoftwareDispositionReviewSubmit')){return 'Manager'}
    if($Action -in @('NonCSourceProofExport','BackupImpactPreview','StartBackup','IndependentCopy','ImportNonCTransferPlan','StartNonCTransfer')){return 'Source'}
    if($Action -in @('NonCTargetHandoffExport','NonCProofPreview','NonCProofImport','NonCPreparation','NonCAccountObservation','CreateNonCTransferPlan','ImportNonCResult','ComparisonExport')){return 'Manager'}
    if($Action -in @('NonCTargetProofExport','NonCTargetHandoffPreview','NonCTargetHandoffImport','TargetZipImport','TargetDirectoryImport','ComparisonImport','TargetLocalComparison','CreateTargetDecisionReceipt','TargetRestorePreview','TargetRestore','TargetValidation','TargetAcceptance','TargetActivation')){return 'Target'}
    if($Action -ceq 'ExportSourceReviewHandoff'){return 'Source'}
    if($Action -ceq 'ImportSourceReviewHandoff'){return 'Manager'}
    if($Action -eq 'ExportTargetHandoff'){return 'Target'}
    if($Action -in @('GetTargetHandoffPreview','CommitTargetHandoff','BulkPreparationPreview','BulkPreparationSave')){return 'Manager'}
    if($Action -eq 'ImportApprovedPlan'){return 'Source'}
    if($Action -in @('InspectWizardFiles','SourceCandidateScan')){return 'Source'}
    if($Action -eq 'OsProvidedCapture'){return 'Source'}
    if($Action -in @('GetPreparationReview','SavePreparationReview','OsProvidedBaseline','OsProvidedReview','OsProvidedSubmit','TargetSnapshot','NonCPlan','ImportInventory')){return 'Manager'}
    if($Action -eq 'EnrolledInventory'){return 'Source'}
    if($Action -eq 'MaterialJobStatus'){return 'Target'}
    if($Action -match '^(Source|Inventory|FreezeSource|SourceResult|SourceTask|SourceResume|NonCPeer)'){return 'Source'}
    if($Action -match '(Target|Preparation|Restore|Rollback|Cutover|Validation|Resource|Reservation|Reserve|Release|Cleanup|NonCPhysical|NonCTransfer)'){return 'Target'}
    'Manager'
}
function Get-WsmTextActionLabel([string]$Action) {
    $known=@{SourceCandidateList='列出來源候選掃描結果';SourceCandidateConfirmExport='匯出來源候選確認材料';SourceCandidateConfirmImport='匯入來源候選確認材料';SourceCandidateConfirmReview='檢視來源候選確認內容';SourceCandidateMappingReview='檢視工作負載對應審閱';SourceCandidateMappingSubmit='送出工作負載對應審閱';SoftwareDispositionReview='檢視軟體處置審閱';SoftwareDispositionReviewSubmit='送出軟體處置審閱';IndependentCopy='建立並驗證獨立備份副本';TargetLocalComparison='在新機本機產生軟體比較（離線）';ExportSourceReviewHandoff='匯出來源盤點與已確認選擇';ImportSourceReviewHandoff='匯入來源盤點與選擇';OsProvidedCapture='擷取 OS 提供排程工作證據（來源／目標）';OsProvidedBaseline='建立 OS 提供排程工作可信基準';OsProvidedReview='比對 OS 提供排程工作證據';OsProvidedSubmit='提交 OS 提供排程工作審閱';SourceCandidateScan='探索來源 C 槽候選與覆蓋缺口';InspectWizardFiles='查看已核准範圍的檔案清單';SpecReview='查看規格審閱';SaveSpecReview='保存規格審閱';WindowsSettingsPreviewExport='匯出 Windows 設定審閱預覽';WindowsSettingsSubmit='提交 Windows 設定審閱';RequirementReview='預覽主機需求審閱';RequirementDecisionSubmit='提交主機需求決策';PreparationPreview='預覽目標準備需求';PreparationEvidence='匯出準備佐證';AssistiveReport='匯出管理報告';AssistiveReportCheck='檢查管理報告';HttpIntegrityProbe='檢查本機頁面傳輸完整性';RestorePreview='預覽還原';Restore='執行還原';RollbackPreview='預覽回復';Rollback='執行回復';CutoverPlan='預覽切換計畫';Cutover='執行切換';SourceInventory='匯出來源主機盤點';SourceSnapshot='擷取來源主機快照';TargetSnapshot='擷取目標主機快照';Validate='執行驗證';Acceptance='檢視驗收條件'}
    if($known.ContainsKey($Action)){return $known[$Action]}
    $group=Get-WsmTextActionGroup $Action
    if($Action -match '^(Get|Test|Assert|Read)'){'檢視或檢查：'+$Action}else{'具名操作：'+$Action}
}
function Get-WsmTextActionGuidance([string]$Action) {
    $guidance=@{
        SourceCandidateList='目的：唯讀列出指定掃描（ScanId）的候選清單與候選檔案雜湊，供來源端挑選一個候選匯出確認材料。不讀檔案內容、不核准。'
        SourceCandidateConfirmExport='目的：在來源主機對你挑選的一個候選逐檔讀取內容並計算雜湊，匯出不可變的確認材料；前提：已完成候選掃描（ScanId、候選雜湊、候選識別碼）且來源盤點為最新。輸出：確認材料位置、SHA-256 與成員數；下一步：以可信管道把材料與雜湊交給管理端匯入。此步驟不核准、不建立檔案範圍。'
        SourceCandidateConfirmImport='目的：管理端匯入來源確認材料並建立待審項目；前提：材料位置、獨立取得的 SHA-256、與來源相同的原始路徑（不得改寫）、負責人與證據。輸出：待審項目與新的決策 revision；下一步：檢視確認內容，再逐項審閱工作負載對應。'
        SourceCandidateConfirmReview='目的：唯讀檢視已匯入的確認內容：成員數（檔案與空目錄分開計）、雜湊與工作負載引用。不核准。'
        SourceCandidateMappingReview='目的：唯讀列出此確認涉及的每一筆工作負載路徑引用與工具建議的對應；前提：該候選已匯入且納入、已審閱並已選取。'
        SourceCandidateMappingSubmit='目的：對每一筆工作負載引用明確記錄「對應／不對應／人工處理」；必須帶審閱當下的盤點雜湊、確認雜湊與決策 revision，任一項已變更即拒絕並要求重新讀取。送出後需重新審閱並重新核准。'
        SoftwareDispositionReview='目的：唯讀列出全部來源軟體與目前處置、涵蓋範圍缺口與預覽雜湊；套裝本體（特殊產品）只能選外部處理或不需要。'
        SoftwareDispositionReviewSubmit='目的：批次記錄軟體處置；必須帶預覽雜湊與決策 revision，並明確勾選確認（Ack）。預覽已變更時拒絕並要求重新讀取，不會自動重送。處置不代表就緒或核准。'
        IndependentCopy='目的：把已封存的備份交付複製到可移除磁碟或網路位置，逐檔比對雜湊後留下驗證收據；也可驗證已人工複製的副本（Mode=VerifyExisting）。舊機本機固定磁碟不算獨立副本；網路位置需在新機確認可取用。'
        TargetLocalComparison='目的：沒有舊 Manager 時，用已驗證的備份集與本機最新盤點產生軟體比較，供建立還原決策收據。不含 Manager 端選定的軟體版本與首次基準；結果僅供參考，不代表相容性或業務可用。'
        SourceCandidateScan='目的：在已登錄來源 C 槽執行有界唯讀中繼資料探索；只列候選與覆蓋缺口，不讀檔案內容、不執行腳本、不建立 FileScope 或核准。部分結果以相同 ScanId 明確續作。'
        InspectWizardFiles='目的：在已核准的檔案範圍內擷取有限檔案中繼資料；不讀取檔案內容，也不代表已備份。'
        OsProvidedCapture='目的：擷取指定主機上已觀察到的工作定義與安全資訊；前提：選擇來源或目標角色，並提供明確工作路徑與名稱。輸出：受保護的捕獲檔及雜湊；下一步：分別擷取兩端，再由管理角色建立可信基準。'
        OsProvidedBaseline='目的：以獨立來源與目標證據建立可核對的可信基準；前提：兩端捕獲與供應者來源佐證均已取得，並填寫基準負責人。輸出：基準檔及實體檔案雜湊；下一步：用該基準執行唯讀比對。'
        OsProvidedReview='目的：比較來源、目標、可信基準與目前目標讀回；前提：當前配對、兩端捕獲、目標盤點與可信基準路徑及 SHA-256。輸出：不含原始工作定義的差異摘要；下一步：審核全部差異及人工原因，再進入提交。'
        OsProvidedSubmit='目的：記錄逐項審閱結論並以目前決策 revision 寫入；前提：先完成同一證據集的比對，確認 Owner、Reason、Disposition 及 Ack。輸出：綁定配對與 revision 的審閱收據；下一步：重新整理並檢查核心狀態。此流程不證明供應者背書、就緒或業務驗收。'
    }
    if($guidance.ContainsKey($Action)){return $guidance[$Action]}
    if($Action -match 'Preview|Review|Probe|Check|Get|Test'){return '目的：唯讀檢視或預覽。先提供明確的配對與可信輸入；查看輸出、限制與待補證據，再選擇後續具名操作。'}
    if($Action -match 'Submit|Apply|Restore|Rollback|Cutover|Import|Transfer|Release|Cleanup'){return '目的：執行具名變更。先完成相對應的唯讀預覽、核對輸入與 revision；只有確認輸出及影響後，才在下方明確輸入 APPLY。'}
    '目的：執行明確的核心操作。依型別提示提供參數；先檢視安全輸出與下一步，系統不會執行任意 shell 命令。'
}
function Read-WsmTextTypedObject($Schema,[scriptblock]$PromptReader,[int]$Depth=0) {
    if($Depth -gt 6){throw 'Nested text form exceeds the supported depth.'}
    $result=[ordered]@{}
    foreach($entry in @($Schema.properties.GetEnumerator())){
        $property=$entry.Value;$required=[bool](Get-WsmTextMetadataValue $property 'required' $false);$label=[string]$entry.Key
        $value=Read-WsmTextTypedValue $label $property $PromptReader $Depth
        if($null -ne $value){$result[$label]=$value}
        elseif($required -and -not $property.allowEmpty){throw ('Required nested value missing: '+$label)}
    }
    [pscustomobject]$result
}
function Read-WsmTextTypedValue([string]$Name,$Metadata,[scriptblock]$PromptReader,[int]$Depth=0) {
    if($Depth -gt 6){throw 'Nested text form exceeds the supported depth.'}
    $type=[string](Get-WsmTextMetadataValue $Metadata 'type' 'string');$required=[bool](Get-WsmTextMetadataValue $Metadata 'required' $false);$allowEmpty=[bool](Get-WsmTextMetadataValue $Metadata 'allowEmpty' $false)
    $metadataSchema=Get-WsmTextMetadataValue $Metadata 'schema'
    if($type -eq 'object' -and $metadataSchema -and (Get-WsmTextMetadataValue $metadataSchema 'title') -eq 'Load an existing trusted artifact'){
        return Read-WsmTextTypedObject $metadataSchema $PromptReader ($Depth+1)
    }
    if($type -eq 'objectArray'){
        $countText=Read-WsmTextEntry ($Name+' 列數（0 可明確表示空集合；Enter 留空略過）') $PromptReader
        if([string]::IsNullOrWhiteSpace($countText)){if($required -and $allowEmpty){return ,@()};if($required){throw ('Required row count missing: '+$Name)};return $null}
        $count=0;if(-not [int]::TryParse($countText,[ref]$count) -or $count -lt 0 -or $count -gt 500){throw 'Row count must be between 0 and 500.'}
        if($count -eq 0){if($required -and -not $allowEmpty){throw 'This operation requires at least one row.'};return ,@()}
        $schema=Get-WsmTextMetadataValue $Metadata 'schema';if(-not $schema){throw ('No typed row schema is available for '+$Name)}
        $rows=New-Object 'System.Collections.Generic.List[object]';for($row=0;$row -lt $count;$row++){$rows.Add((Read-WsmTextTypedObject $schema $PromptReader ($Depth+1)))}
        return ,@($rows.ToArray())
    }
    if($type -eq 'object'){
        $schema=Get-WsmTextMetadataValue $Metadata 'schema';if(-not $schema){throw ('No typed object schema is available for '+$Name)}
        return Read-WsmTextTypedObject $schema $PromptReader ($Depth+1)
    }
    if($type -eq 'stringArray' -or $type -eq 'array'){
        $values=New-Object 'System.Collections.Generic.List[string]';while($values.Count -lt 500){$answer=Read-WsmTextEntry ($Name+' 項目 '+($values.Count+1)+'（空白行結束）') $PromptReader;if([string]::IsNullOrEmpty($answer)){break};if($answer.Length -gt 32768){throw 'Text value exceeds the supported length.'};$values.Add($answer)}
        if($required -and -not $allowEmpty -and -not $values.Count){throw ('At least one value is required: '+$Name)}
        return ,@($values.ToArray())
    }
    if($type -eq 'map' -or $type -eq 'stringMap'){
        $values=[ordered]@{};while($values.Count -lt 500){$key=Read-WsmTextEntry ($Name+' 鍵（空白行結束）') $PromptReader;if([string]::IsNullOrEmpty($key)){break};if($values.Contains($key)){throw 'Duplicate map key.'};$values[$key]=Read-WsmTextEntry ($Name+'「'+$key+'」值') $PromptReader}
        if($required -and -not $allowEmpty -and -not $values.Count){throw ('At least one map entry is required: '+$Name)}
        return [pscustomobject]$values
    }
    if($type -eq 'enum'){
        $options=@(Get-WsmTextMetadataValue $Metadata 'options' @());for($i=0;$i -lt $options.Count;$i++){Write-Host (('  {0}. {1}' -f ($i+1),$options[$i]))}
        $answer=Read-WsmTextEntry ($Name+'（輸入編號或選項值）') $PromptReader
        if([string]::IsNullOrWhiteSpace($answer)){if($required){throw ('Required value missing: '+$Name)};return $null}
        $index=0;if([int]::TryParse($answer,[ref]$index) -and $index -ge 1 -and $index -le $options.Count){return [string]$options[$index-1]}
        if($options -ccontains $answer){return $answer};throw ('Unsupported value for '+$Name)
    }
    $answer=Read-WsmTextEntry ($Name+$(if($required){'（必填）'}elseif($allowEmpty){'（可留空）'}else{'（Enter 略過）'})) $PromptReader
    if($type -eq 'boolean'){
        if([string]::IsNullOrWhiteSpace($answer)){if($required){throw ('Required value missing: '+$Name)};return $null}
        if($answer -match '^(?i:y|yes|true|1)$'){return $true};if($answer -match '^(?i:n|no|false|0)$'){return $false};throw ('Enter yes/no for '+$Name)
    }
    if([string]::IsNullOrWhiteSpace($answer) -and -not $allowEmpty){if($required){throw ('Required value missing: '+$Name)};return $null}
    if($answer.Length -gt 32768){throw 'Text value exceeds the supported length.'}
    if($type -eq 'integer'){[int]$number=0;if(-not [int]::TryParse($answer,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){throw ('Invalid integer: '+$Name)};return $number}
    if($type -eq 'number'){$number=0.0;if(-not [double]::TryParse($answer,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){throw ('Invalid number: '+$Name)};return $number}
    $answer
}
function Get-WsmTextCurrentRevision([string]$Name,[string]$Workspace,[string]$PairId,[string]$CommandName) {
    if(-not $PairId){return $null}
    try{$catalog=Get-WsmCatalog $Workspace $PairId;switch($Name){'ExpectedAssistiveRevision' {return [int]$catalog.Assistive.Revision};'ExpectedSelectionRevision' {return [int]$catalog.Assistive.Selections.Revision};'ExpectedDecisionRevision' {return [int]$catalog.DecisionRevision};'DecisionRevision' {if($CommandName -ceq 'Export-WsmAssistiveOsProvidedTaskCapture'){return [int]$catalog.DecisionRevision};return $null};'ExpectedRevision' {if($CommandName -in @('Reserve-WsmAssistiveResource','Set-WsmAssistiveResourceEvidence','Release-WsmAssistiveResource','Set-WsmAssistiveMaterialClosed','Invoke-WsmAssistiveCleanup')){return $null};if($CommandName -in @('Set-WsmHtmlSelections','Set-WsmHtmlRestoreDecision','Set-WsmAssistiveSelections','Update-WsmAssistiveTargetSnapshot','Update-WsmAssistiveComparison','Set-WsmAssistiveSoftwareVersion')){return [int]$catalog.Assistive.Revision};return [int]$catalog.DecisionRevision};default {return $null}}}catch{return $null}
}
function Test-WsmTextApplyConfirmation([string]$Value) {return ($Value -ceq 'APPLY')}
function Get-WsmWorkerFailureStatus($Failure) {
    $current=$Failure
    for($depth=0;$depth -lt 8 -and $current;$depth++){
        if($current -is [System.Management.Automation.ErrorRecord]){$current=$current.Exception;continue}
        if($current -is [OperationCanceledException] -and $current.Data -and $current.Data['CancellationRequested'] -is [bool] -and $current.Data['CancellationRequested']){return 'Cancelled'}
        if($current -is [Exception] -and $current.InnerException){$current=$current.InnerException;continue}
        break
    }
    'Failed'
}
function Get-WsmTextWizardActions {
    @('SourceCandidateScan','BackupImpactPreview','StartBackup','IndependentCopy','SourceResume','NonCSourceProofExport','StartNonCTransfer','ImportApprovedPlan','ExportSourceReviewHandoff','ImportSourceReviewHandoff','ExportTargetHandoff','GetTargetHandoffPreview','CommitTargetHandoff','BulkPreparationPreview','BulkPreparationSave','TargetZipImport','TargetDirectoryImport','ComparisonExport','ComparisonImport','TargetLocalComparison','TargetReceipt','CreateTargetDecisionReceipt','TargetRestorePreview','TargetRestore','TargetValidation','TargetAcceptance','TargetActivation','NonCTargetProofExport','NonCTargetHandoffExport','NonCTargetHandoffPreview','NonCTargetHandoffImport','NonCProofPreview','NonCProofImport','CreateNonCTransferPlan','ImportNonCResult','NonCAccountObservation','NonCPreparation','WizardRuntimeProjection','TargetSnapshot','AssistiveComparison','PublishComparison','SetSoftwareVersion','AssistiveEnable','AssistiveSelections')
}
function Get-WsmTextDeveloperProbeJobs([string]$Workspace,[string]$Role) {
    @(Get-WsmTextWizardJobs $Workspace '' $Role | Where-Object {$_.action -ceq 'DeveloperProbe'})
}
function Resolve-WsmTextDeveloperProbeJob([string]$Workspace,[string]$Role,[string]$JobId) {
    Assert-WsmId $JobId
    $jobs=@(Get-WsmTextDeveloperProbeJobs $Workspace $Role)
    $matches=@($jobs|Where-Object {$_.jobId -ceq $JobId})
    if($matches.Count -ne 1){throw 'Developer probe job was not found for this workspace and role.'}
    $job=$matches[0]
    if($job.status -in @('Running','CancelRequested')){
        $guard=$null
        try{$guard=Enter-WsmWorkspaceWorkerGuard -Workspace $Workspace -OperationId $JobId -Role $Role -Action 'DeveloperProbe'}
        catch{
            if(-not ($_.Exception.Data -and $_.Exception.Data['WsmWorkspaceWorkerBusy'] -eq $true)){throw}
            $token=New-WsmDeveloperProbeCancellationToken -Workspace $Workspace -OperationId $JobId
            $request=Request-WsmDeveloperProbeCancellation -CancellationToken $token
            return [pscustomobject]@{Status='CancelRequested';Executed=$false;Action='DeveloperProbe';Job=$job;CancellationRequestedUtc=[string]$request.RequestedUtc}
        }
        try{
            Assert-WsmWorkspaceWorkerGuard $guard $Workspace 'DeveloperProbe'
            $jobs=@(Recover-WsmTextWizardJobs $Workspace '' $Role $guard)
            $job=@($jobs|Where-Object {$_.jobId -ceq $JobId})|Select-Object -First 1
            if(-not $job){throw 'Developer probe job disappeared during guarded recovery.'}
        }finally{if($guard){Exit-WsmWorkspaceWorkerGuard $guard}}
    }
    [pscustomobject]@{Status='Reconnected';Executed=$false;Action='DeveloperProbe';Job=$job}
}
function Enter-WsmWorkspaceWorkerGuard {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[string]$OperationId,[string]$Role,[string]$PairId,[string]$Action)
    $workspaceRoot=[IO.Path]::GetFullPath($Workspace)
    if(-not [IO.Directory]::Exists($workspaceRoot)){throw 'Workspace worker guard requires an initialized workspace directory.'}
    Assert-WsmNoReparse $workspaceRoot
    $lane=if($Action -ceq 'DeveloperProbe'){'DeveloperProbe'}else{'Migration'}
    $lockName=if($lane -ceq 'DeveloperProbe'){'console-probe-worker.lock'}else{'console-worker.lock'}
    $path=Join-Path $workspaceRoot $lockName;Assert-WsmNoReparse $path
    if($OperationId){Assert-WsmId $OperationId}
    $stream=$null
    try{$stream=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{$busy=New-Object InvalidOperationException('WorkspaceWorkerBusy: another console worker or recovery currently owns this workspace. Wait for it to finish, then retry.',$_.Exception);$busy.Data['WsmWorkspaceWorkerBusy']=$true;throw $busy}
    try{
        $metadata=[ordered]@{ProcessId=$PID;StartedUtc=(Get-WsmUtc);OperationId=$OperationId;Role=$Role;PairId=$PairId;Action=$Action}|ConvertTo-Json -Depth 4 -Compress
        $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($metadata);$stream.SetLength(0);$stream.Position=0;$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
        [pscustomobject]@{Path=$path;Workspace=$workspaceRoot;Lane=$lane;Stream=$stream;ProcessId=$PID;OperationId=$OperationId;Role=$Role;PairId=$PairId;Action=$Action}
    }catch{$stream.Dispose();throw}
}
function Exit-WsmWorkspaceWorkerGuard {
    [CmdletBinding()]param([Parameter(Mandatory)]$Guard)
    if(-not $Guard.PSObject.Properties['Stream'] -or -not $Guard.PSObject.Properties['Workspace']){throw 'Invalid workspace worker guard handle.'}
    if($Guard.Stream -and -not $Guard.Stream.SafeFileHandle.IsClosed){$Guard.Stream.Dispose()}
}
function Assert-WsmWorkspaceWorkerGuard($Guard,[string]$Workspace,[string]$ExpectedLane) {
    if(-not $Guard -or -not $Guard.PSObject.Properties['Stream'] -or -not $Guard.PSObject.Properties['Workspace'] -or -not $Guard.PSObject.Properties['Lane'] -or -not $Guard.Stream -or $Guard.Stream.SafeFileHandle.IsClosed){throw 'A live workspace worker guard is required for durable job recovery.'}
    if([IO.Path]::GetFullPath([string]$Guard.Workspace) -ine [IO.Path]::GetFullPath($Workspace)){throw 'Workspace worker guard does not belong to the requested workspace.'}
    if($ExpectedLane -and [string]$Guard.Lane -cne $ExpectedLane){throw 'Workspace worker guard does not own the required worker lane.'}
}
function Recover-WsmTextWizardJobs([string]$Workspace,[string]$PairId,[string]$Role,$Guard) {
    Assert-WsmWorkspaceWorkerGuard $Guard $Workspace
    $records=@(Get-WsmTextWizardJobs $Workspace $PairId $Role)
    foreach($job in $records){
        if($job.status -notin @('Running','CancelRequested')){continue}
        $recordPath=Join-Path (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'console-jobs') ($job.jobId+'.json');Assert-WsmNoReparse $recordPath
        $record=Read-WsmJson $recordPath
        if([string]$record.jobId -cne [string]$job.jobId -or [string]$record.workspace -ine [IO.Path]::GetFullPath($Workspace) -or [string]$record.role -cne $Role -or [string]$record.pairId -cne $PairId){throw 'A durable wizard job changed identity during guarded recovery.'}
        if($record.status -notin @('Running','CancelRequested')){continue}
        $record.status='Interrupted';$record.CompletedUtc=Get-WsmUtc;$record|Add-Member NoteProperty canCancel $false -Force
        $recovered=@()
        if(Get-Command Get-WsmHtmlWizardTerminalOutput -ErrorAction SilentlyContinue){try{$recovered=@(Get-WsmHtmlWizardTerminalOutput $record $records|Where-Object {$null -ne $_})}catch{$recovered=@()}}
        $record.outputs=@(Get-WsmHtmlResultProjection $recovered)
        Write-WsmJson $recordPath $record
        $job.status='Interrupted';$job.CompletedUtc=[string]$record.CompletedUtc;$job.outputs=@($record.outputs)
    }
    @($records)
}
function Get-WsmTextWizardJobs([string]$Workspace,[string]$PairId,[string]$Role) {
    $root=[IO.Path]::GetFullPath((Join-Path $Workspace 'console-jobs'))
    if(-not [IO.Directory]::Exists($root)){return @()}
    Assert-WsmNoReparse $root
    $workspaceRoot=[IO.Path]::GetFullPath($Workspace)
    $knownStatuses=@('Running','CancelRequested','Interrupted','Succeeded','ReviewRequired','Failed','Cancelled','Blocked','Deferred','Completed','Saved')
    $result=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File)){
        Assert-WsmNoReparse $file.FullName
        if($file.Length -gt 16777216){throw 'A local console job record exceeds its supported size; inspect the protected history before continuing.'}
        $record=Read-WsmJson $file.FullName
        if(-not $record -or -not $record.PSObject.Properties['jobId']){throw 'A local console job record has no operation identity; inspect the protected history before continuing.'}
        $jobId=[string]$record.jobId;Assert-WsmId $jobId
        if([IO.Path]::GetFileNameWithoutExtension($file.Name) -cne $jobId){throw 'A local console job filename does not match its recorded operation identity.'}
        if($record.PSObject.Properties['operationId'] -and [string]$record.operationId -cne $jobId){throw 'A local console job operation identifier does not match its durable record identity.'}
        if(-not $record.PSObject.Properties['workspace'] -or -not $record.workspace){continue}
        try{if([IO.Path]::GetFullPath([string]$record.workspace) -ine $workspaceRoot){continue}}catch{throw 'A local console job has an invalid workspace binding.'}
        if([string]$record.role -cne $Role -or [string]$record.pairId -cne $PairId){continue}
        if(-not $record.PSObject.Properties['action'] -or (([string]$record.action -cne 'DeveloperProbe') -and -not (Get-WsmOperationActions).Contains([string]$record.action)) -or [string]$record.status -notin $knownStatuses){throw 'A matching local console job record has an invalid action or status.'}
        $status=[string]$record.status
        $outputs=@();if($record.PSObject.Properties['outputs']){
            $rawOutputs=@($record.outputs);$outputs=@(Get-WsmHtmlResultProjection $rawOutputs)
            for($i=0;$i -lt [Math]::Min($rawOutputs.Count,$outputs.Count);$i++){
                if($rawOutputs[$i] -and $rawOutputs[$i].PSObject.Properties['SafeProjectedItemResults'] -and $rawOutputs[$i].SafeProjectedItemResults -is [bool] -and $rawOutputs[$i].SafeProjectedItemResults -and $rawOutputs[$i].PSObject.Properties['ItemResultsHash'] -and [string]$rawOutputs[$i].ItemResultsHash -match '^[a-fA-F0-9]{64}$'){
                    $outputs[$i]|Add-Member NoteProperty SafeProjectedItemResults $true -Force
                    $outputs[$i]|Add-Member NoteProperty ItemResultsHash ([string]$rawOutputs[$i].ItemResultsHash) -Force
                }
            }
        }
        $result.Add([pscustomobject][ordered]@{jobId=$jobId;action=[string]$record.action;status=$status;role=$Role;pairId=$PairId;workspace=$workspaceRoot;CompletedUtc=$(if($record.PSObject.Properties['CompletedUtc']){[string]$record.CompletedUtc}elseif($record.PSObject.Properties['completedUtc']){[string]$record.completedUtc}else{''});outputs=$outputs})
    }
    @($result.ToArray())
}
function Get-WsmTextJobStatus($Result) {
    $code=Get-WsmOperationStatusCode $Result
    if($code -eq 3){return 'Cancelled'}
    if($code -eq 1){return 'Failed'}
    if($code -eq 2){return 'ReviewRequired'}
    'Succeeded'
}
function Get-WsmTextWizardTerminalOutputs($Record,[object[]]$Jobs) {
    $recovered=@()
    if(Get-Command Get-WsmHtmlWizardTerminalOutput -ErrorAction SilentlyContinue){try{$recovered=@(Get-WsmHtmlWizardTerminalOutput $Record $Jobs|Where-Object {$null -ne $_})}catch{$recovered=@()}}
    @(Get-WsmHtmlResultProjection $recovered)
}
function Write-WsmTextJobRecord([string]$Workspace,$Record) {
    $root=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'console-jobs'
    if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root}
    Assert-WsmNoReparse $root
    $path=Join-Path $root ([string]$Record.jobId+'.json');Assert-WsmNoReparse $path
    if([IO.File]::Exists($path)){throw 'This operation identifier already has a durable record; inspect it and create a new explicit operation instead of retrying.'}
    Write-WsmJson $path $Record
    $path
}
function Invoke-WsmTypedTextOperation {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[scriptblock]$PromptReader)
    if(-not (Get-Command Get-WsmHtmlActionMetadata -ErrorAction SilentlyContinue)){throw 'Typed forms are unavailable; load the installed HTML schema helpers first.'}
    $roles=@('Source','Target','Manager');for($i=0;$i -lt $roles.Count;$i++){Write-Host ('{0}. {1}' -f ($i+1),$roles[$i])};$roleAnswer=Read-WsmTextEntry '選擇操作情境角色（只供上下文與指引，不代表授權）' $PromptReader;$roleIndex=0
    if(-not [int]::TryParse($roleAnswer,[ref]$roleIndex) -or $roleIndex -lt 1 -or $roleIndex -gt $roles.Count){throw 'Choose Source, Target, or Manager.'};$role=$roles[$roleIndex-1]
    $pairs=New-Object 'System.Collections.Generic.List[object]';$seenPairIds=@{};$fleetPath=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'fleet.json'
    if([IO.File]::Exists($fleetPath)){$fleet=Get-WsmFleet $Workspace;foreach($fleetPair in @($fleet.Pairs)){if($fleetPair -and $fleetPair.PairId -and -not $seenPairIds.ContainsKey([string]$fleetPair.PairId)){$seenPairIds[[string]$fleetPair.PairId]=$true;$pairs.Add($fleetPair)}}}
    elseif($role -ceq 'Manager'){[void](Get-WsmFleet $Workspace)}
    if($role -in @('Source','Target')){$enrolled=Read-WsmOutputProfile $Workspace;if($enrolled -and [string]$enrolled.Role -ceq $role){foreach($receivedPair in @(Get-WsmWizardReceivedPlanChoices $Workspace $enrolled)){if($receivedPair -and $receivedPair.pairId -and -not $seenPairIds.ContainsKey([string]$receivedPair.pairId)){$seenPairIds[[string]$receivedPair.pairId]=$true;$pairs.Add([pscustomobject]@{PairId=[string]$receivedPair.pairId;TargetName=[string]$receivedPair.targetName})}}}}
    $pairs=@($pairs.ToArray());$pairId=''
    if($pairs.Count){Write-Host '可用配對：';for($i=0;$i -lt $pairs.Count;$i++){Write-Host ('{0}. {1} — {2}' -f ($i+1),$pairs[$i].PairId,$pairs[$i].TargetName)};$pairAnswer=Read-WsmTextEntry '選配對編號（Enter 使用不指定配對的本機操作）' $PromptReader;if($pairAnswer){$pairIndex=0;if(-not [int]::TryParse($pairAnswer,[ref]$pairIndex) -or $pairIndex -lt 1 -or $pairIndex -gt $pairs.Count){throw 'Invalid pair selection.'};$pairId=[string]$pairs[$pairIndex-1].PairId}}
    $pairLabel='未指定';if($pairId){$pairLabel=$pairId};Write-Host ('Core context：Workspace='+[IO.Path]::GetFullPath($Workspace)+'；操作情境角色='+$role+'；PairId='+$pairLabel)
    $metadata=@(Get-WsmHtmlActionMetadata -Role $role);$map=Get-WsmHtmlActionMap
    foreach($group in @('Source','Manager','Target')){Write-Host ('['+$(switch($group){Source{'來源端'}Manager{'管理端'}Target{'目標端'}})+']');$rows=@($metadata | Where-Object {(Get-WsmTextActionGroup ([string]$_.action)) -ceq $group});foreach($row in $rows){Write-Host ('  '+$row.action+' — '+(Get-WsmTextActionLabel ([string]$row.action)) )}}
    $action=Read-WsmTextEntry '輸入完整操作識別碼（0 取消）' $PromptReader;if($action -eq '0'){return [pscustomobject]@{Status='Cancelled';Executed=$false}}
    $entry=$metadata | Where-Object {$_.action -ceq $action} | Select-Object -First 1;if(-not $entry -or -not $map.Contains($action)){throw 'Unknown operation for this installed module.'}
    if($action -ceq 'SourceCandidateScan' -and $pairId){Write-Host '來源 C 槽候選探索使用未配對的來源盤點；本次不套用選取配對。';$pairId=''}
    if($action -ceq 'DeveloperProbe'){
        $probeJobs=@(Get-WsmTextDeveloperProbeJobs $Workspace $role)
        if($probeJobs.Count){foreach($probeJob in @($probeJobs|Sort-Object CompletedUtc -Descending|Select-Object -First 8)){Write-Host ('既有探測：'+$probeJob.jobId+' · '+$probeJob.status)};$probeChoice=Read-WsmTextEntry '輸入既有探測工作識別碼以查詢／取消；Enter 開始新探測' $PromptReader;if(-not [string]::IsNullOrWhiteSpace($probeChoice)){return Resolve-WsmTextDeveloperProbeJob $Workspace $role $probeChoice}}
    }
    Write-Host ("`n操作指引："+(Get-WsmTextActionGuidance $action))
    $command=Get-Command $map[$action] -CommandType Function;$raw=[ordered]@{};$secretValues=@{};$credentialValues=@{};$wizardAction=($action -in @(Get-WsmTextWizardActions));$durableJobAction=($wizardAction -or $action -ceq 'DeveloperProbe');$jobHistory=@();$jobRecord=$null;$jobPath='';$workerGuard=$null;$readOnlyResultCaptured=$false
    try {
        if($wizardAction){
            $profile=Read-WsmOutputProfile $Workspace
            if(-not $profile -or [string]$profile.Role -cne $role){throw 'The selected operation role must match the currently enrolled workspace role.'}
            if(-not $entry.roleAvailable){throw 'The selected operation is unavailable for this enrolled role.'}
            if(-not $pairId -and $command.Parameters.ContainsKey('PairId') -and @($command.Parameters.PairId.Attributes|Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count){throw 'Choose the current pair before starting this wizard operation.'}
            if($action -ceq 'SourceCandidateScan'){$jobHistory=@(Get-WsmTextWizardJobs $Workspace '' $role)}elseif($pairId){$jobHistory=@(Get-WsmTextWizardJobs $Workspace $pairId $role)}
        }elseif($action -ceq 'DeveloperProbe'){
            if(-not $entry.roleAvailable){throw 'The selected developer probe is unavailable for this role.'}
            $jobHistory=@(Get-WsmTextDeveloperProbeJobs $Workspace $role)
        }
        $trustedDefaultNames=@(switch($action){
            'NonCTargetProofExport'{'StateDirectory';break}
            'NonCTargetHandoffExport'{'ManifestHash','TransferPlanHash';break}
            default{@()}
        })
        if($wizardAction -and $trustedDefaultNames.Count -and (Get-Command Get-WsmWizardNonCActionDefaults -ErrorAction SilentlyContinue)){
            $defaults=Get-WsmWizardNonCActionDefaults -Workspace $Workspace -PairId $pairId -Role $role -Action $action -Jobs $jobHistory
            if($defaults -and [string]$defaults.action -ceq $action -and [string]$defaults.requiredRole -ceq $role -and $defaults.roleAvailable -eq $true -and $defaults.args){
                foreach($name in $trustedDefaultNames){
                    if(-not $command.Parameters.ContainsKey($name)){continue}
                    $property=$defaults.args.PSObject.Properties[$name]
                    if($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)){$raw[$name]=$property.Value}
                }
            }
        }
        foreach($parameter in @($entry.parameters)){
            if($parameter.name -in @('Workspace','PairId','Role','Secrets')){continue}
            if(-not $command.Parameters.ContainsKey($parameter.name)){continue}
            if($raw.Contains($parameter.name)){Write-Host ($parameter.name+'：採用目前工作區核對的值；沒有要求重新輸入。');continue}
            $value=$null
            if($parameter.name -match '^(Expected.*Revision|DecisionRevision)$'){$value=Get-WsmTextCurrentRevision $parameter.name $Workspace $pairId $command.Name}
            if($null -ne $value){Write-Host ($parameter.name+'：目前核心 revision '+$value+'；按 Enter 採用，或輸入其他 revision。');$answer=Read-WsmTextEntry 'revision' $PromptReader;if($answer){$number=0;if(-not [int]::TryParse($answer,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)){throw ('Invalid integer: '+$parameter.name)};$value=$number}else{$value=[int]$value}}
            elseif($command.Parameters[$parameter.name].ParameterType -eq [Management.Automation.PSCredential]){$credential=Get-Credential -Message ('本次操作認證：'+$parameter.name);if(-not $credential){throw 'Credential entry cancelled.'};$credentialValues[$parameter.name]=$credential;$value=[pscustomobject]@{UserName='typed-memory-only';Password='placeholder-not-a-secret'}}
            else{$value=Read-WsmTextTypedValue $parameter.name $parameter $PromptReader}
            if($null -ne $value){$raw[$parameter.name]=$value}
        }
        if($command.Parameters.ContainsKey('ExpectedRevision') -and -not $raw.Contains('ExpectedRevision')){
            $revision=Get-WsmTextCurrentRevision 'ExpectedRevision' $Workspace $pairId $command.Name
            if($null -ne $revision){Write-Host ('ExpectedRevision：目前核心 revision '+$revision+'；按 Enter 採用，或輸入要比較的 revision。');$answer=Read-WsmTextEntry '預期 revision' $PromptReader;if($answer){$typed=@{name='ExpectedRevision';type='integer';required=$true};$raw.ExpectedRevision=Read-WsmTextTypedValue 'ExpectedRevision' $typed $PromptReader}else{$raw.ExpectedRevision=[int]$revision}}
            elseif(@($command.Parameters.ExpectedRevision.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count){$typed=@{name='ExpectedRevision';type='integer';required=$true};$raw.ExpectedRevision=Read-WsmTextTypedValue 'ExpectedRevision（請先執行專屬預覽以取得 CAS 值）' $typed $PromptReader}
        }
        if($command.Parameters.ContainsKey('Secrets')){
            while($true){$ref=Read-WsmTextEntry 'SecretRef（空白結束；秘密僅留在此程序記憶體）' $PromptReader;if(-not $ref){break};if($secretValues.ContainsKey($ref)){throw 'Duplicate SecretRef.'};$kind=Read-WsmTextEntry '秘密類型：Credential 或 SecureString' $PromptReader
                if($kind -eq 'Credential'){$credential=Get-Credential -Message ('SecretRef '+$ref);if(-not $credential){throw 'Credential entry cancelled.'};$secretValues[$ref]=$credential;$credential=$null}
                elseif($kind -eq 'SecureString'){if($PromptReader){throw 'SecureString text-console fixture must use the credential provider; interactive secret entry is required.'};$secretValues[$ref]=Read-Host -AsSecureString ('SecretRef '+$ref)}else{throw 'Unsupported secret kind.'}
            }
        }
        foreach($binding in @(@('Workspace',$Workspace),@('PairId',$pairId),@('Role',$role))){if($command.Parameters.ContainsKey($binding[0]) -and -not $raw.Contains($binding[0]) -and $binding[1]){$raw[$binding[0]]=$binding[1]}}
        $arguments=ConvertTo-WsmHtmlArguments $command ([pscustomobject]$raw)
        $operationId=[Guid]::NewGuid().ToString('D')
        if($wizardAction -and $command.Parameters.ContainsKey('Jobs')){$arguments.Jobs=@($jobHistory)}
        if($command.Parameters.ContainsKey('OperationId')){$arguments.OperationId=$operationId;Write-Host ('本次工作識別碼：'+$operationId+'；保留此識別碼以查核中斷或未知寫入，不會自動重送。')}
        foreach($name in $credentialValues.Keys){$arguments[$name]=$credentialValues[$name]}
        foreach($binding in @(@('Workspace',$Workspace),@('PairId',$pairId),@('Role',$role))){if($command.Parameters.ContainsKey($binding[0]) -and -not $arguments.ContainsKey($binding[0]) -and $binding[1]){$arguments[$binding[0]]=$binding[1]}}
        if($command.Parameters.ContainsKey('Secrets')){$arguments.Secrets=$secretValues}
        foreach($parameter in $command.Parameters.Values){$mandatory=@($parameter.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0;if($mandatory -and $parameter.Name -cne 'CancellationToken' -and -not $arguments.ContainsKey($parameter.Name)){throw ('Required parameter missing; interactive prompts are disabled in command execution: '+$parameter.Name)}}
        $revision=Get-WsmHtmlRevision $Workspace $pairId;$previewAction=$entry.previewAction;$preview=$null;$previewKind='ParametersOnly'
        if($previewAction -and $map.Contains($previewAction)){$previewCommand=Get-Command $map[$previewAction] -CommandType Function;$previewArgs=@{};foreach($key in $arguments.Keys){if($previewCommand.Parameters.ContainsKey($key)){$previewArgs[$key]=$arguments[$key]}};$preview=& $previewCommand @previewArgs;$previewKind='ResourcePreview'}
        elseif($entry.readOnly){$preview=& $command @arguments;$previewKind='ResourcePreview';$readOnlyResultCaptured=$true}
        elseif($command.Parameters.ContainsKey('WhatIf')){$whatIfArgs=@{};foreach($key in $arguments.Keys){$whatIfArgs[$key]=$arguments[$key]};$whatIfArgs.WhatIf=$true;$preview=& $command @whatIfArgs;$previewKind='WhatIf'}
        $safePreview=ConvertTo-WsmHtmlPreview $preview $action $revision $previewKind
        Write-Host ("`n預覽："+$safePreview.summary)
        if($safePreview.issues){$safePreview.issues | ForEach-Object {Write-Host ('  '+$_)}}
        foreach($row in @($safePreview.items)){$row | Format-List | Out-Host}
        if($previewKind -eq 'ParametersOnly'){Write-Host '此處僅檢查參數形狀，未評估資源就緒、核准、目標讀回或執行閘門。請另用專屬預覽操作；只有確認接受此限制才可明確套用。' -ForegroundColor Yellow}
        if($safePreview.canExecute -eq $false){return [pscustomobject]@{Status='Blocked';Executed=$false;Preview=$safePreview}}
        $confirmation=Read-WsmTextEntry '若已逐項檢查並決定提交，請輸入大寫 APPLY；其他輸入取消' $PromptReader
        if(-not (Test-WsmTextApplyConfirmation $confirmation)){return [pscustomobject]@{Status='Cancelled';Executed=$false;Preview=$safePreview}}
        if($command.Parameters.ContainsKey('Confirm')){$arguments.Confirm=$false}
        if($durableJobAction){
            $workerGuard=Enter-WsmWorkspaceWorkerGuard -Workspace $Workspace -OperationId $operationId -Role $role -PairId $(if($action -in @('DeveloperProbe','SourceCandidateScan')){''}else{$pairId}) -Action $action
            if($action -ceq 'DeveloperProbe'){$jobHistory=@(Recover-WsmTextWizardJobs $Workspace '' $role $workerGuard);$probeCancellation=New-WsmDeveloperProbeCancellationToken -Workspace $Workspace -OperationId $operationId;$arguments.CancellationToken=$probeCancellation;Write-Host ('本次開發者探測工作識別碼：'+$operationId+'；另一個 CLI 可用相同識別碼查詢或要求取消。')}
            elseif($action -ceq 'SourceCandidateScan'){$jobHistory=@(Recover-WsmTextWizardJobs $Workspace '' $role $workerGuard);if($command.Parameters.ContainsKey('Jobs')){$arguments.Jobs=@($jobHistory)}}
            elseif($pairId){$jobHistory=@(Recover-WsmTextWizardJobs $Workspace $pairId $role $workerGuard);if($command.Parameters.ContainsKey('Jobs')){$arguments.Jobs=@($jobHistory)}}
            $jobRecord=[pscustomobject][ordered]@{jobId=$operationId;operationId=$operationId;action=$action;status='Running';role=$role;workspace=[IO.Path]::GetFullPath($Workspace);pairId=$(if($action -in @('DeveloperProbe','SourceCandidateScan')){''}else{$pairId});StartedUtc=(Get-WsmUtc);CompletedUtc=$null;canCancel=($action -in @('DeveloperProbe','SourceCandidateScan'));outputs=@()}
            $jobPath=Write-WsmTextJobRecord $Workspace $jobRecord
        }
        if($action -ceq 'DeveloperProbe'){
            if(-not $arguments.ContainsKey('CancellationToken')){throw 'Developer probe requires its operation-bound cancellation token.'}
        }elseif($command.Parameters.ContainsKey('CancellationToken') -and (Get-Command New-WsmHtmlCancellation -ErrorAction SilentlyContinue)){
            $token=New-WsmHtmlCancellation $command $arguments $operationId $jobHistory
            $cancelRequired=@($command.Parameters.CancellationToken.Attributes|Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0
            if($token){$arguments.CancellationToken=$token;Write-Host ('核心取消權杖已綁定。工作識別碼：'+$operationId+'；如需停止，請在另一個管理程序對同一工作上下文提出取消。')}
            elseif($cancelRequired){throw 'This operation requires a hash-bound safe cancellation context before it can start.'}
            else{Write-Host '本次參數沒有建立可用取消權杖；命令執行期間不可由此文字選單取消。'}
        }
        try {
            if($readOnlyResultCaptured){$result=$preview}else{$result=& $command @arguments}
            if($durableJobAction){
                $safeOutputs=@(Get-WsmHtmlResultProjection @($result));$status=Get-WsmTextJobStatus $result
                $jobRecord.status=$status;$jobRecord.CompletedUtc=Get-WsmUtc;$jobRecord|Add-Member NoteProperty canCancel $false -Force;$jobRecord.outputs=$safeOutputs
                if(-not $jobRecord.pairId){foreach($output in $safeOutputs){if($output -and $output.PSObject.Properties['PairId'] -and $output.PairId){$jobRecord.pairId=[string]$output.PairId;break}}}
                Write-WsmJson $jobPath $jobRecord
                $result=$safeOutputs
            }
        } catch {
            if($jobRecord){$jobRecord.status=Get-WsmWorkerFailureStatus $_;$jobRecord.CompletedUtc=Get-WsmUtc;$jobRecord|Add-Member NoteProperty canCancel $false -Force;$jobRecord.outputs=@(Get-WsmTextWizardTerminalOutputs $jobRecord (@($jobHistory)+@($jobRecord)));Write-WsmJson $jobPath $jobRecord}
            throw
        }
        Write-Host '核心命令已回傳；以下僅顯示安全欄位。'
        if($durableJobAction){$result | Format-List | Out-Host}elseif(Get-Command Get-WsmHtmlResultProjection -ErrorAction SilentlyContinue){Get-WsmHtmlResultProjection $result | Format-List | Out-Host}else{$result | Format-List | Out-Host}
        [pscustomobject]@{Status='Applied';Executed=$true;Action=$action;Result=$result}
    } catch {
        if($jobRecord -and [string]$jobRecord.status -ceq 'Running'){$jobRecord.status=Get-WsmWorkerFailureStatus $_;$jobRecord.CompletedUtc=Get-WsmUtc;$jobRecord|Add-Member NoteProperty canCancel $false -Force;$jobRecord.outputs=@(Get-WsmTextWizardTerminalOutputs $jobRecord (@($jobHistory)+@($jobRecord)));if($jobPath){Write-WsmJson $jobPath $jobRecord}}
        throw
    } finally {if($workerGuard){Exit-WsmWorkspaceWorkerGuard $workerGuard};$secretValues.Clear();$credentialValues.Clear();$raw.Clear();$arguments=$null;$credential=$null}
}
function Show-WsmMigrationMenu {
    param([string]$Workspace)
    while($true){Write-Host "`n遷移階段（目前為隔離 pilot；真實 Server 資格未驗收）";Write-Host '來源本機：ExportPackage／FreezeSource。目標本機：RegisterTarget／RestorePreview／Restore／Validate／Cutover／Rollback。';Write-Host '管理工作區：ConfigureMigration／ApproveMigration／MigrationReport。所有操作使用相同核心。';Write-Host '1 列出操作  2 Core 型別化操作（不需手編 JSON）  3 預覽進階 OperationRequest  4 執行進階 OperationRequest  0 返回';$choice=Read-Host '選項';if($null -eq $choice){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($choice -eq '0'){return}
        try{switch($choice){
            '1' {foreach($entry in (Get-WsmOperationActions).GetEnumerator()){Write-Host ($entry.Key+': '+(@((Get-Command $entry.Value).Parameters.Keys | Where-Object {$_ -notin @('Secrets','Verbose','Debug','ErrorAction','ErrorVariable','OutVariable','OutBuffer','PipelineVariable','InformationAction','InformationVariable','WarningAction','WarningVariable','Confirm','WhatIf')}) -join ', '))}}
            '2' {Invoke-WsmTypedTextOperation -Workspace $Workspace | Out-Null}
            '3' {$path=Read-WsmWizardValue 'OperationRequest JSON 路徑（0 取消）';if($path -eq '0'){continue};$hash=Read-WsmWizardValue '獨立可信 SHA256';$request=Read-WsmTrustedJson $path $hash;Assert-WsmEnvelope $request 'OperationRequest';$request | ConvertTo-Json -Depth 12 | Write-Host;Write-Host '進階備援不執行操作。資源預覽請改用專屬操作。'}
            '4' {$path=Read-WsmWizardValue 'OperationRequest JSON 路徑（0 取消）';if($path -eq '0'){continue};$hash=Read-WsmWizardValue '獨立可信 SHA256';$request=Read-WsmTrustedJson $path $hash;Assert-WsmEnvelope $request 'OperationRequest';Write-Host ('操作：'+$request.Action);$request.Arguments | Format-List;$secretRefs=Read-WsmWizardValue -Optional '需要的 SecretRef，以逗號分隔（可留空；密碼僅記憶體）';$secrets=@{};try{foreach($name in $secretRefs.Split(',')){if($name.Trim()){$credential=Get-Credential -Message ('SecretRef '+$name.Trim());if(-not $credential){throw 'Credential entry cancelled.'};$secrets[$name.Trim()]=$credential}};Invoke-WsmOperationRequest $path $hash $secrets | Format-List}finally{$secrets.Clear();$credential=$null}}
            default {Write-Host '無效選項；未修改。'}
        }}catch [OperationCanceledException]{Write-Host $_.Exception.Message}catch [IO.EndOfStreamException]{throw}catch{Write-Host ('操作失敗：'+$_.Exception.Message) -ForegroundColor Red;Get-WsmFailureDetails $_ | Format-List Category,NativeCode,Hint}
    }
}
