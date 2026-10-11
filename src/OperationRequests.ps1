function Get-WsmOperationActions {
    [ordered]@{OsProvidedCapture='Export-WsmAssistiveOsProvidedTaskCapture';OsProvidedBaseline='Export-WsmAssistiveOsProvidedBaseline';OsProvidedReview='Get-WsmAssistiveOsProvidedReview';OsProvidedSubmit='Submit-WsmAssistiveOsProvidedReview';RequirementReview='Get-WsmAssistiveGeneralHostRequirementReview';RequirementDecisionSubmit='Submit-WsmAssistiveGeneralHostRequirementDecisions';PreparationPreview='Get-WsmAssistivePreparationPreview';PreparationEvidence='Export-WsmAssistivePreparationEvidence';WindowsSettingsPreviewExport='Export-WsmAssistiveWindowsSettingsPreview';WindowsSettingsSubmit='Submit-WsmAssistiveWindowsSettingsReview';DispositionSubmit='Submit-WsmAssistiveGeneralHostDispositions';RequirementSubmit='Submit-WsmAssistiveGeneralHostRequirements';HttpIntegrityProbe='Export-WsmAssistiveHttpProbe';SpecReview='Get-WsmAssistiveSpecReview';SaveSpecReview='Submit-WsmAssistiveSpecReview';TargetReceipt='Export-WsmAssistiveTargetDecisionReceipt';AssistiveReport='Export-WsmAssistiveReport';AssistiveReportCheck='Test-WsmAssistiveReport';AssistiveComparison='Get-WsmAssistiveComparison';PublishComparison='Update-WsmAssistiveComparison';TargetSnapshot='Update-WsmAssistiveTargetSnapshot';SetSoftwareVersion='Set-WsmAssistiveSoftwareVersion';FilePlacementPreview='Get-WsmFilePlacementPreview';NonCPeerProof='New-WsmAssistivePeerShareProof';NonCPhysicalProof='New-WsmAssistiveTargetPhysicalProof';NonCPlan='New-WsmAssistiveNonCTransferPlan';NonCTransfer='Invoke-WsmAssistiveNonCTransfer';NonCImport='Import-WsmAssistiveNonCResult';ReservationPreview='Get-WsmAssistiveResourceReservationPreview';ReserveResource='Reserve-WsmAssistiveResource';ResourceEvidence='Set-WsmAssistiveResourceEvidence';ReleaseResource='Release-WsmAssistiveResource';RegisterMaterial='Register-WsmAssistiveMaterialReference';CloseMaterial='Set-WsmAssistiveMaterialClosed';JobLock='Set-WsmAssistiveJobLock';MaterialJobStatus='Export-WsmAssistiveMaterialJobStatus';CleanupPreview='Get-WsmAssistiveCleanupPreview';Cleanup='Invoke-WsmAssistiveCleanup';EnvironmentProbe='Export-WsmAssistiveEnvironmentProbe';ProbeImport='Import-WsmAssistiveEnvironmentProbe';AssistiveEnable='Enable-WsmAssistiveMode';AssistiveSelections='Set-WsmAssistiveSelections';AssistiveTargetDecisionReceipt='New-WsmAssistiveTargetDecisionReceipt';WorkspaceTransferPreview='New-WsmOutputWorkspaceTransferPreview';WorkspaceTransfer='Invoke-WsmOutputWorkspaceTransfer';WorkspaceTransferRestorePreview='New-WsmOutputWorkspaceTransferRestorePreview';WorkspaceTransferRestore='Invoke-WsmOutputWorkspaceTransferRestore';DeliveryDocument='Export-WsmDeliveryDocument';ImportedDeliveryReceipt='Export-WsmImportedDeliveryReceipt';DeliveryReceiptImport='Import-WsmDeliveryReceipt';WindowsSettingsPreview='Get-WsmWindowsSettingsReviewWorkspacePreview';WindowsSettingsApply='Apply-WsmWindowsSettingsReview';QualificationSigningRequest='New-WsmQualificationSigningRequest';QualificationSigningComplete='Complete-WsmQualificationSigningRequest';CheckToolRelease='Test-WsmToolRelease';DeltaDirectory='Export-WsmArtifactDeltaDirectory';DeltaDirectoryImport='Import-WsmArtifactDeltaDirectory';GeneralHostMode='Set-WsmGeneralHostMode';SoftwareAttach='Set-WsmGeneralHostSoftwareCatalog';DispositionPreview='Get-WsmGeneralHostDispositionPreview';DispositionApply='Set-WsmGeneralHostDispositions';RequirementPreview='Get-WsmGeneralHostRequirementPreview';RequirementApply='Set-WsmGeneralHostRequirements';GeneralHostEvidence='Import-WsmGeneralHostEvidence';SoftwareEvidence='Export-WsmSoftwareCatalogEvidence';OutputInitialize='Initialize-WsmOutputWorkspace';OutputResolve='Resolve-WsmOutputWorkspace';OutputRegisterPair='Register-WsmOutputPair';OutputConfirmState='Confirm-WsmOutputOperationState';OutputPreferences='Set-WsmOutputPreferences';EnrolledInventory='Export-WsmEnrolledInventory';EnrolledDelivery='Export-WsmEnrolledPackageDelivery';DirectoryDelivery='Export-WsmDirectoryDelivery';DirectoryImport='Import-WsmDirectoryDelivery';OracleBindingTemplate='Export-WsmOracleConsumerBindingTemplate';OracleConfigDraft='Get-WsmOracleClientConfigDraft';EnvironmentConfirmation='Export-WsmEnvironmentConfirmation';DeltaVolumes='Export-WsmArtifactDeltaVolumes';DeltaVolumeImport='Import-WsmArtifactDeltaVolumes';LabReport='Export-WsmLabValidationReport';ConfigReview='Export-WsmConfigArtifactReview';ConfigScopeDraft='Export-WsmConfigArtifactScopeDraft';DeltaManifest='New-WsmArtifactDeltaManifest';DeltaCheck='Test-WsmArtifactDeltaManifest';DeltaZip='Export-WsmArtifactDeltaZip';DeltaImport='Import-WsmArtifactDeltaZip';DeltaRestore='Invoke-WsmArtifactDeltaRestore';DeltaRepair='Repair-WsmArtifactDeltaRestore';CancellationToken='New-WsmCancellationToken';RequestCancellation='Request-WsmCancellation';GroupPlan='New-WsmConsistencyGroupPlan';GroupReceipt='New-WsmConsistencyGroupReceipt';GroupBarrier='Assert-WsmConsistencyGroupBarrier';RollbackResult='Export-WsmRollbackResult';QualificationKey='Get-WsmQualificationRecordKey';QualificationRecord='New-WsmQualificationRecord';QualificationAdd='Add-WsmQualification';QualificationRevoke='Revoke-WsmQualification';QualificationLookup='Resolve-WsmProductionQualification';QualificationMatrix='Get-WsmQualificationMatrix';SourceTaskTemplate='Export-WsmSourceTaskReconciliationTemplate';SourceResume='Invoke-WsmSourceResume';SpecBundleExport='Export-WsmMigrationSpecBundle';SpecBundlePreview='Get-WsmMigrationSpecBundlePreview';SpecBundleImport='Import-WsmMigrationSpecBundle';RepairWorkspace='Repair-WsmWorkspace';RawEvidence='Export-WsmRawEvidenceManifest';RegisterTarget='Register-WsmTarget';ToolRelease='Export-WsmToolRelease';SourceResult='Export-WsmSourceStageResult';IdentityMap='Set-WsmIdentityMap';ConfigureMigration='Set-WsmMigrationSpec';ApproveMigration='Approve-WsmMigrationPlan';EstimatePackage='Get-WsmPackageEstimate';ExportPackage='Export-WsmMigrationPackage';CheckPackage='Test-WsmMigrationPackage';RestorePreview='Get-WsmRestorePreview';Restore='Invoke-WsmRestore';FreezeSource='Export-WsmFreezeRecord';ValidationEvidence='Set-WsmValidationEvidence';Validate='Invoke-WsmValidation';CutoverPlan='New-WsmCutoverPlan';Cutover='Invoke-WsmCutover';Acceptance='Get-WsmAcceptanceGates';ExportResult='Export-WsmStageResult';Repair='Repair-WsmOperation';RollbackPreview='Get-WsmRollbackPreview';Rollback='Invoke-WsmRollback';CheckJournal='Test-WsmJournal';PackageZip='Export-WsmPackageZip';ImportPackageZip='Import-WsmPackageZip';MigrationReport='Export-WsmOperationReport'}
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
    $knownStates=@('Export','Retirement','PostCutoverValidation','Activated','Previewed','EvidenceRecorded','ObservedMatches','AddingTemporaryDeny','Applied','Blocked','BlockedByOpenHandles','BlockedConflict','BudgetExceeded','Cancelled','Captured','CloseCommandSucceeded','CloseFailed','CloseFailedObservedGone','CloseFailedStillOpen','CloseIntent','ClosingReviewedHandles','Completed','CoverageGap','Cutover','DeferredSoftware','Draft','Exporting','External','ExternalProductWorkflowRequired','ExternalRequired','FAIL','Failed','Frozen','Generated','ImportedVerified','IndexValidationFailed','Intent','Interrupted','Inventory','Manual','ManualEvidenceRequired','Mapped','Migrated','NeedsOwnerReview','NetworkApplied','NoApproval','NoChange','NoReceipt','NotAvailable','NotFound','NotInstalled','NotLoaded','NotObserved','NotSearched','NotStarted','NotTested','NotApplicable','NotRun','NotNeeded','OwnerAttestedStaticOnly','OwnerReviewRequired','PASS','Partial','Pending','PermissionDenied','PostCutoverValidationRequired','PreCutoverValidation','Prepared','ProjectionHashVerified','ProviderVersionSpecificBehaviorRequiresOwnerObservation','Quiesced','Quiescing','Read','ReadStaticConfigOnly','Ready','RebootRequired','RecoveredApplied','RecoveredPriorReadback','RenameRebootRequired','ReportLocatorOnly','ReportOnly','RequiresReview','Restored','RestoredPriorValue','Restore','ReviewRequired','RetryPending','RollbackEvidenceComplete','RollbackRunning','RolledBack','Running','Sealed','Skipped','SourceResumed','Succeeded','SucceededWithWarnings','Success','Unknown','Unavailable','Unmapped','UnresolvedPath','Unsupported','Verified','VerifiedTrustedBase','WaitForInstall','WaitForOwner','None')
    foreach($r in @($Result)){
        if($null -eq $r){continue}
        $states=@();foreach($field in @('Stage','Status')){if($r.PSObject.Properties[$field]){$states+=@([string]$r.$field)}}
        if($r.PSObject.Properties['Result'] -and $r.Result -and $r.Result.PSObject.Properties['Kind'] -and $r.Result.Kind -ceq 'StageResult' -and $r.Result.PSObject.Properties['Status']){$states+=@([string]$r.Result.Status)}
        if($states -ccontains 'Failed' -or $states -ccontains 'FAIL'){return 1}
        if($states -ccontains 'Cancelled'){$code=3;continue}
        $blocked=@($states | Where-Object {$_ -cin @('NotStarted','Ready','Running','Blocked','BlockedByOpenHandles','BlockedConflict','Partial','RetryPending','ManualEvidenceRequired','RebootRequired','PostCutoverValidationRequired','ReviewRequired','DeferredSoftware','WaitForInstall','NotInstalled','PermissionDenied','Unsupported','NotTested','NeedsOwnerReview','Interrupted','Unmapped','Manual') -or ($_.Length -gt 0 -and $_ -cnotin $knownStates)}).Count -gt 0
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
    if($Action -eq 'OsProvidedCapture'){return 'Source'}
    if($Action -in @('OsProvidedBaseline','OsProvidedReview','OsProvidedSubmit')){return 'Manager'}
    if($Action -match '^(Source|Inventory|FreezeSource|SourceResult|SourceTask|SourceResume|NonCPeer)'){return 'Source'}
    if($Action -match '(Target|Preparation|Restore|Rollback|Cutover|Validation|Resource|Reservation|Reserve|Release|Cleanup|NonCPhysical|NonCTransfer)'){return 'Target'}
    'Manager'
}
function Get-WsmTextActionLabel([string]$Action) {
    $known=@{OsProvidedCapture='擷取 OS 提供排程工作證據（來源／目標）';OsProvidedBaseline='建立 OS 提供排程工作可信基準';OsProvidedReview='比對 OS 提供排程工作證據';OsProvidedSubmit='提交 OS 提供排程工作審閱';SpecReview='查看規格審閱';SaveSpecReview='保存規格審閱';WindowsSettingsPreviewExport='匯出 Windows 設定審閱預覽';WindowsSettingsSubmit='提交 Windows 設定審閱';RequirementReview='預覽主機需求審閱';RequirementDecisionSubmit='提交主機需求決策';PreparationPreview='預覽目標準備需求';PreparationEvidence='匯出準備佐證';AssistiveReport='匯出管理報告';AssistiveReportCheck='檢查管理報告';HttpIntegrityProbe='檢查本機頁面傳輸完整性';RestorePreview='預覽還原';Restore='執行還原';RollbackPreview='預覽回復';Rollback='執行回復';CutoverPlan='預覽切換計畫';Cutover='執行切換';SourceInventory='匯出來源主機盤點';SourceSnapshot='擷取來源主機快照';TargetSnapshot='擷取目標主機快照';Validate='執行驗證';Acceptance='檢視驗收條件'}
    if($known.ContainsKey($Action)){return $known[$Action]}
    $group=Get-WsmTextActionGroup $Action
    if($Action -match '^(Get|Test|Assert|Read)'){'檢視或檢查：'+$Action}else{'具名操作：'+$Action}
}
function Get-WsmTextActionGuidance([string]$Action) {
    $guidance=@{
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
function Invoke-WsmTypedTextOperation {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[scriptblock]$PromptReader)
    if(-not (Get-Command Get-WsmHtmlActionMetadata -ErrorAction SilentlyContinue)){throw 'Typed forms are unavailable; load the installed HTML schema helpers first.'}
    $roles=@('Source','Target','Manager');for($i=0;$i -lt $roles.Count;$i++){Write-Host ('{0}. {1}' -f ($i+1),$roles[$i])};$roleAnswer=Read-WsmTextEntry '選擇操作情境角色（只供上下文與指引，不代表授權）' $PromptReader;$roleIndex=0
    if(-not [int]::TryParse($roleAnswer,[ref]$roleIndex) -or $roleIndex -lt 1 -or $roleIndex -gt $roles.Count){throw 'Choose Source, Target, or Manager.'};$role=$roles[$roleIndex-1]
    $fleet=Get-WsmFleet $Workspace;$pairs=@($fleet.Pairs);$pairId=''
    if($pairs.Count){Write-Host '可用配對：';for($i=0;$i -lt $pairs.Count;$i++){Write-Host ('{0}. {1} — {2}' -f ($i+1),$pairs[$i].PairId,$pairs[$i].TargetName)};$pairAnswer=Read-WsmTextEntry '選配對編號（Enter 使用不指定配對的本機操作）' $PromptReader;if($pairAnswer){$pairIndex=0;if(-not [int]::TryParse($pairAnswer,[ref]$pairIndex) -or $pairIndex -lt 1 -or $pairIndex -gt $pairs.Count){throw 'Invalid pair selection.'};$pairId=[string]$pairs[$pairIndex-1].PairId}}
    $pairLabel='未指定';if($pairId){$pairLabel=$pairId};Write-Host ('Core context：Workspace='+[IO.Path]::GetFullPath($Workspace)+'；操作情境角色='+$role+'；PairId='+$pairLabel)
    $metadata=@(Get-WsmHtmlActionMetadata -Role $role);$map=Get-WsmHtmlActionMap
    foreach($group in @('Source','Manager','Target')){Write-Host ('['+$(switch($group){Source{'來源端'}Manager{'管理端'}Target{'目標端'}})+']');$rows=@($metadata | Where-Object {(Get-WsmTextActionGroup ([string]$_.action)) -ceq $group});foreach($row in $rows){Write-Host ('  '+$row.action+' — '+(Get-WsmTextActionLabel ([string]$row.action)) )}}
    $action=Read-WsmTextEntry '輸入完整操作識別碼（0 取消）' $PromptReader;if($action -eq '0'){return [pscustomobject]@{Status='Cancelled';Executed=$false}}
    $entry=$metadata | Where-Object {$_.action -ceq $action} | Select-Object -First 1;if(-not $entry -or -not $map.Contains($action)){throw 'Unknown operation for this installed module.'}
    Write-Host ("`n操作指引："+(Get-WsmTextActionGuidance $action))
    $command=Get-Command $map[$action] -CommandType Function;$raw=[ordered]@{};$secretValues=@{};$credentialValues=@{}
    try {
        foreach($parameter in @($entry.parameters)){
            if($parameter.name -in @('Workspace','PairId','Role','Secrets')){continue}
            if(-not $command.Parameters.ContainsKey($parameter.name)){continue}
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
        foreach($name in $credentialValues.Keys){$arguments[$name]=$credentialValues[$name]}
        foreach($binding in @(@('Workspace',$Workspace),@('PairId',$pairId),@('Role',$role))){if($command.Parameters.ContainsKey($binding[0]) -and -not $arguments.ContainsKey($binding[0]) -and $binding[1]){$arguments[$binding[0]]=$binding[1]}}
        if($command.Parameters.ContainsKey('Secrets')){$arguments.Secrets=$secretValues}
        foreach($parameter in $command.Parameters.Values){$mandatory=@($parameter.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0;if($mandatory -and $parameter.Name -cne 'CancellationToken' -and -not $arguments.ContainsKey($parameter.Name)){throw ('Required parameter missing; interactive prompts are disabled in command execution: '+$parameter.Name)}}
        $revision=Get-WsmHtmlRevision $Workspace $pairId;$previewAction=$entry.previewAction;$preview=$null;$previewKind='ParametersOnly'
        if($previewAction -and $map.Contains($previewAction)){$previewCommand=Get-Command $map[$previewAction] -CommandType Function;$previewArgs=@{};foreach($key in $arguments.Keys){if($previewCommand.Parameters.ContainsKey($key)){$previewArgs[$key]=$arguments[$key]}};$preview=& $previewCommand @previewArgs;$previewKind='ResourcePreview'}
        elseif($entry.readOnly){$preview=& $command @arguments;$previewKind='ResourcePreview'}
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
        if($command.Parameters.ContainsKey('CancellationToken') -and (Get-Command New-WsmHtmlCancellation -ErrorAction SilentlyContinue)){$operationId=[Guid]::NewGuid().ToString('D');$token=New-WsmHtmlCancellation $command $arguments $operationId;if($token){$arguments.CancellationToken=$token;Write-Host ('核心取消權杖已綁定。工作識別碼：'+$operationId+'；如需停止，請在另一個管理程序對同一工作上下文提出取消。')}else{Write-Host '本次參數沒有建立可用取消權杖；命令執行期間不可由此文字選單取消。'}}
        $result=& $command @arguments
        Write-Host '核心命令已回傳；以下僅顯示安全欄位。'
        if(Get-Command Get-WsmHtmlResultProjection -ErrorAction SilentlyContinue){Get-WsmHtmlResultProjection $result | Format-List | Out-Host}else{$result | Format-List | Out-Host}
        [pscustomobject]@{Status='Applied';Executed=$true;Action=$action;Result=$result}
    } finally {$secretValues.Clear();$credentialValues.Clear();$raw.Clear();$arguments=$null;$credential=$null}
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
