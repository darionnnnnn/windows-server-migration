# Closed UI projection. Raw plans, configuration definitions, secrets, ACL blobs
# and native diagnostic objects never cross this projection.
function ConvertTo-WsmWizardHtmlValue($Value,[int]$Depth=0) {
    if($Depth -gt 16 -or $null -eq $Value){return $null}
    if($Value -is [string]){
        $text=[regex]::Replace($Value,'(?i)(password|passwd|pwd|token|secret|credential|api[-_]?key)\s*[:=]\s*[^\s;,]+','$1=[redacted]')
        if($text.Length -gt 8192){$text=$text.Substring(0,8192)}
        return $text
    }
    if($Value -is [ValueType]){return $Value}
    if($Value -is [array]){return ,@(foreach($entry in $Value){ConvertTo-WsmWizardHtmlValue $entry ($Depth+1)})}
    $allowed=@('Kind','Status','Stage','Role','PairId','Workspace','ContextId','DataVersion','HasNonC','CurrentPlan','Preparation','AccountObservation','ResultSummary','SourceChoices','ProofAllowed','actions','actionContracts','publicActions','runtime','id','available','reason','defaults','missing','Command','RequiredFields','OptionalFields','ExplicitFields','Defaults','PublicAction','StartBackup','BackupImpactPreview','SourceResume','ImportApprovedPlan','TargetZipImport','TargetDirectoryImport','ComparisonExport','ComparisonImport','CreateTargetDecisionReceipt','TargetRestorePreview','TargetRestore','TargetValidation','TargetAcceptance','TargetActivation','plan','package','inventory','comparison','decision','restorePreview','restoreResult','mechanicalValidation','businessAcceptance','activation','result','gates','issues','itemOptions','backupPreview','backupResult','delivery','sourceFreeze','choices','canStartBackup','required','missingEvidence','resumeRequired','resumeRoute','impact','mode','volumeBytes','frozen','attemptId','sourceAttemptPath','sourceAttemptHash','acknowledgementRequired','noAutoResume','noAutoActivation','Path','Directory','Root','SHA256','Hash','PlanPath','PlanHash','ExpectedHash','ManifestPath','ManifestHash','InventoryHash','InventoryRevision','SourceInventoryHash','SourceInventoryRevision','TargetSnapshotHash','SourceSnapshotHash','SourceSelectionRevision','TargetIdentityHash','Generation','RunId','JobId','OperationId','AttemptId','AttemptOperationId','StartedByOperationId','DeliveryMode','VolumeBytes','ResumeStage','CanResumeAfterReview','SourceResumeRequired','AuthoritativeApproval','ProductionVerified','BusinessAcceptance','BusinessAccepted','BusinessValidationRequired','Passed','Checks','FinalAccepted','RetirementReady','MissingFinal','MissingRetirement','Observation','RetirementAction','JournalPath','JournalHash','ItemResultsHash','SafeProjectedItemResults','ItemResults','Deferred','Rows','Problems','GeneralHostIssues','CanRestoreIndependentItems','Blocked','PreviewHash','PreviewId','ReceiptPath','ReceiptHash','TargetSnapshotPath','ComparisonHash','ComparisonRevision','SelectionRevision','Decision','SelectedItemIds','AcceptedUnpreparedItemIds','Owner','Evidence','Reason','Acknowledgement','Confirmed','FreezeAuthorization','ReviewedSourceDefaults','FreezeExternalEvidencePath','FreezeExternalEvidenceHash','FreezeRequired','FreezeAuthorized','SourceChanged','SourceFreezeReadiness','PackageScope','SourceHost','Producers','SharedImpact','QuiescenceDisclosure','PriorState','EvidenceRequirements','ProducerIdentity','RequiresSourceFreeze','ProducerQuiescedIfFreezeRuns','PriorStateLocation','Location','BackupAttemptRoot','Description','Freeze','CoreExport','PackageTest','Delivery','ChannelSummary','C','NonC','ConfigurationEvidence','Certificate','ManualArtifactsNotSupported','UnsupportedIncludedItemIds','IncludedItemIds','OverallStatus','NonCStatus','Sealed','Final','Valid','Files','Bytes','Mode','PackageManifestHash','IndexPath','IndexSHA256','FreezeId','ExpiresUtc','EvidenceHash','producedUtc','completedUtc','CreatedUtc','UpdatedUtc','ImportedUtc','ProducedUtc','ProducedLocal','ImportedLocal','TimeZone','NextOperator','NextMachine','NextAction','HostId','Name','Fingerprint','value','label','kind','adapter','ItemId','ItemName','Adapter','Channel','Selected','SourcePath','TargetPath','SourceRoot','TargetRoot','TargetStateDirectory','SourceStateDirectory','SourceAttemptPath','SourceAttemptHash','OwnershipEvidence','ResumeExternalEvidencePath','ResumeExternalEvidenceHash','TaskReconciliationPath','TaskReconciliationHash','TransportPath','SummaryPath','ExpectedSummaryHash','SourceDirectory','CutoverPlanPath','CutoverPlanHash','Phase','TargetRestore','Inventory','OutputDirectory','DeepDiscovery','IncludeSoftwareCatalog','WorkRoot','InventoryPath','ReadOnly','HumanConfirmationRequired','Current','Entries','MaterialChoices','ProofOptions','TransferChoices','MissingFields','Gates','CanCreateTransferPlan','CanImportResult','NonCItemIds','MaterialRegistryRevision','FreezeRecordPath','FreezeRecordHash','FreezeEvidencePath','FreezeEvidenceHash','ConsumerRefs','RequiredHumanInputs','SourceIdentities','TargetIdentities','Principals','Sid','SID','SourceSid','TargetSid','AccountMappings','AccountMap','CoverageComplete','VisitedCount','MaximumEntries','ElapsedMilliseconds','TimeoutSeconds','TimedOut','Cancelled','ContentRead','UnresolvedCount','AclReadFailureCount','RequireSacl','MetadataPolicy','AccountObservationHash','SourcePeerProofHash','TargetPhysicalProofHash','TransferPlanHash','TransferId','TransferChoiceId','ChoiceId','Label','TransferPlanPath','ExpectedPlanHash','ResultPath','ResultHash','ExpectedResultHash','AppliedCount','BlockedCount','DeferredCount','EntryId','ReasonCode','ObservedChecks','PendingChecks','Replay','NoTargetWrites','ResumeRequiredAfterPreparation','hasDurableRecord','hasPackage','current','jobStatus','workerStatus','appliedCount','failedCount','blockedCount','source','Metadata','ReadbackSucceeded','NativeVerified','TargetPhysicalId','MetadataPolicyHash','FreezeEpoch','sha256','path','hash','manifestHash','inventoryHash','inventoryRevision','planHash','generation','manifestPath','statusDescription','activity','currentOperation','percent','processedCount','updatedUtc')
    $allowed+=@('SourceIdentityId','SourceKind','SourceName','SourceNameSource','OwnerObserved','RuleCount','DisplayLabel','IdentityId','StableBuiltin','LocalRoots','StateDirectory','ObservedManifestHash','ExpectedManifestHash','SourceProofContentHash','TargetProofContentHash','MaterialRefs','RegisteredReferences','RegistryRevision','ToolFingerprint','TrustMethod','Destination','ShareName','LocalPath','ProofKind','MemberCount','Summary','CurrentSource','CurrentTarget','TargetHostId','SourceHostId','Included','Succeeded','Failed','Cancelled','PendingOperations','ValidationPath','ValidationHash','StageResultPath','StageResultHash','Result','FinalPassed','Issues','Missing','Eligible','CanProceed','CanActivate','CanAccept','NeedsHumanBusinessValidation','StatusCode','CanImport','Imported','ProofHash','PhysicalProofHash','LocalPhysicalRoot','NextStep','RequiredAcknowledgement','TargetHost','ReviewedTargetRoots','Materials','HostName','RootCount','requiresRootReview','SelectionRequired','CStatus','CCompleted','CIncludedItemIds','CIncludedItemCount','CManifestPath','CManifestHash','ConfigurationEvidenceStatus','ConfigurationItemIds','CertificateStatus','CertificateItemIds','NonCResults','NonCCompleted','NonCAppliedCount','NonCBlockedCount','NonCDeferredCount','RecoveredAfterWorkerFailure','WorkerStatus','Producer','ResourceKind','ResourceItemId','ResourceName','ConsumerItemIds','AffectedItemIds','RequiresSharedReview','Scope','ReviewReason','ContentBindingHash','ActiveReceiptHash','TransferPlanItemCount','ValidatedItemCount','NonCEvidenceIssue','RestoreAttemptId','DecisionReceiptHash','AdditionalShares','SourcePeerProofHashes','SourcePeerProofs','SourcePeerProofContentHash','ContentHash','FinalValidationPath','FinalValidationHash','JournalSnapshotPath')
    $allowed+=@('Shares','ReviewedTargetRootMappings','TargetStateShareName','UNCPath','CreatedLocal','TimeZoneId','NonCTransferPlanHash','NonCResultHash')
    $allowed+=@('Action','Rollback','RebootPossible','RequirementId','ConsumerItemId','Gate','Issue')
    $allowed+=@('CutoverPlanHash','CutoverStage')
    $allowed+=@('manualReviewRequired','manualReviewReason','sourceResumed','resumeAvailable')
    $allowed+=@('IndependentCopy','offlineReadiness','OfflineReadiness','Availability','MediaClass','CopyRoot','ReceiptSHA256','VerifiedUtc','BackupOperationId','DestinationRoot')
    $allowed+=@('TargetLocalComparison','Provenance')
    $allowed+=@('group','restorable','restorableReason','restored','statusSummary')
    $safe=[ordered]@{}
    if($Value -is [Collections.IDictionary]){$properties=@(foreach($key in $Value.Keys){[pscustomobject]@{Name=[string]$key;Value=$Value[$key]}})}else{$properties=@($Value.PSObject.Properties)}
    foreach($property in $properties){
        if($property.Name -ceq 'Receipt' -and $property.Value -and $property.Value.PSObject.Properties['Kind'] -and [string]$property.Value.Kind -ceq 'AssistiveTargetDecisionReceipt'){
            # The runtime has already verified the receipt. Expose only the
            # responsibility summary, never its embedded comparison or payload.
            $summary=[ordered]@{}
            foreach($name in @('Kind','Owner','Reason','Decision','CreatedUtc')){
                if($property.Value.PSObject.Properties[$name] -and $property.Value.$name -is [string]){$summary[$name]=ConvertTo-WsmWizardHtmlValue $property.Value.$name ($Depth+1)}
            }
            $safe.Receipt=[pscustomobject]$summary
        }elseif($property.Name -in $allowed){$safe[$property.Name]=ConvertTo-WsmWizardHtmlValue $property.Value ($Depth+1)}
    }
    [pscustomobject]$safe
}

function Get-WsmHtmlWizardRuntime([string]$Workspace,[string]$PairId,[string]$Role,[hashtable]$Jobs) {
    if($Role -notin @('Source','Target')){throw 'Runtime controls require the enrolled Source or Target role.'}
    $before=Get-WsmHtmlRevisionVector $Workspace $PairId
    $projection=ConvertTo-WsmWizardHtmlValue (Get-WsmWizardRuntimeProjection -Workspace $Workspace -PairId $PairId -Role $Role -Jobs (Get-WsmHtmlWizardJobs $Jobs $Workspace))
    $after=Get-WsmHtmlRevisionVector $Workspace $PairId
    if(($before|ConvertTo-Json -Depth 5 -Compress) -cne ($after|ConvertTo-Json -Depth 5 -Compress)){throw 'Review changed: runtime materials changed while the view was being read.'}
    $projection|Add-Member NoteProperty viewContext $after -Force
    $projection
}

function Get-WsmHtmlWizardTerminalOutput($Record,[object[]]$Jobs) {
    if(-not $Record -or $Record.status -notin @('Failed','Cancelled','Interrupted')){return $null}
    $workspace=[string]$Record.workspace;$pair=[string]$Record.pairId;$operation=[string]$Record.jobId
    Assert-WsmId $operation;Assert-WsmId $pair
    $profile=Read-WsmOutputProfile $workspace
    if(-not $profile -or $profile.Role -cne [string]$Record.role){return $null}
    if($Record.action -ceq 'StartBackup' -and $Record.role -ceq 'Source'){
        $root=Get-WsmWizardBackupRoot $workspace $pair;if(-not [IO.Directory]::Exists($root)){return $null}
        $bound=Get-WsmWizardBackupAttemptForOperation $workspace $pair $profile $operation
        if($bound){return ConvertTo-WsmWizardBackupResult $bound.Attempt $operation}
    }
    if($Record.action -ceq 'TargetRestore' -and $Record.role -ceq 'Target'){
        return Get-WsmWizardTargetTerminalResultForOperation $workspace $pair $operation $Jobs
    }
    $null
}

function Get-WsmWizardRuntimeActionDefaults([string]$Workspace,[string]$PairId,[string]$Role,[string]$Action,[object[]]$Jobs) {
    $map=Get-WsmOperationActions
    if(-not $map.Contains($Action)){throw 'Action is outside the installed runtime allowlist.'}
    $command=Get-Command $map[$Action] -CommandType Function
    $args=[ordered]@{Workspace=$Workspace;PairId=$PairId};$available=$false;$reason='目前材料或角色尚未可用。';$explicitMissing=@()
    if($Action -ceq 'WizardRuntimeProjection'){$args.Role=$Role;$available=($Role -in @('Source','Target') -and [bool]$PairId)}
    else{
        $projection=Get-WsmWizardRuntimeProjection -Workspace $Workspace -PairId $PairId -Role $Role -Jobs $Jobs
        $selected=@($projection.actions|Where-Object id -CEQ $Action)
        if($Action -ceq 'BackupImpactPreview' -and $Role -ceq 'Source' -and $projection.runtime.plan){$args.DeliveryMode=$projection.runtime.delivery.mode;$args.VolumeBytes=$projection.runtime.delivery.volumeBytes;$available=$true;$reason='先檢查精確影響，尚未停止寫入。'}
        elseif($selected.Count -eq 1){$available=[bool]$selected[0].available;$reason=[string]$selected[0].reason;foreach($property in $selected[0].defaults.PSObject.Properties){$args[$property.Name]=$property.Value};$explicitMissing=@($selected[0].missing)}
    }
    foreach($key in @($args.Keys)){if(-not $command.Parameters.ContainsKey($key)){$args.Remove($key)}}
    $required=@($command.Parameters.Values|Where-Object {$_.Name -notin @('Workspace','PairId','Jobs','OperationId','CancellationToken') -and @($_.Attributes|Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0}|ForEach-Object {$_.Name})
    $names=@(@($required)+@($explicitMissing)|Where-Object {$_ -notin @('Workspace','PairId','Jobs','OperationId','CancellationToken')}|Sort-Object -Unique)
    $missing=@(foreach($name in $names){if(-not $args.Contains($name)){[pscustomobject]@{name=$name;required=$true;source='ExplicitIntentOrTrustedMaterial';reason='由操作者明確提供或核對獨立可信材料，不能由內容 self-hash 代填。';options=@()}}})
    [pscustomobject]@{schemaVersion=1;kind='WizardActionDefaults';action=$Action;requiredRole=$Role;args=[pscustomobject]$args;fields=@(foreach($name in $names){if($args.Contains($name)){[pscustomobject]@{name=$name;required=$true;present=$true;source='CurrentVerifiedRuntime';reason='';options=@()}}else{@($missing|Where-Object name -CEQ $name)[0]}});missingFields=$missing;blocked=(-not $available -or $missing.Count -gt 0);blockReason=$(if($available){if($missing.Count){'尚有明確意圖或可信材料欄位待提供。'}else{''}}else{$reason});roleAvailable=([bool]$available);sourceProvenance=$null;context=$null;executionPermission='Defaults are not freeze, restore, acceptance or activation permission.'}
}

function Get-WsmWizardNonCActionDefaults([string]$Workspace,[string]$PairId,[string]$Role,[string]$Action,[object[]]$Jobs) {
    $map=Get-WsmOperationActions;$command=Get-Command $map[$Action] -CommandType Function
    $requiredRole=Get-WsmTextActionGroup $Action;$profile=Read-WsmOutputProfile $Workspace
    $roleAvailable=([bool]$profile -and $profile.Role -ceq $Role -and $Role -ceq $requiredRole)
    $args=[ordered]@{Workspace=$Workspace};if($PairId -and $command.Parameters.ContainsKey('PairId')){$args.PairId=$PairId}
    if($roleAvailable -and $Action -ceq 'NonCTargetProofExport'){$args.StateDirectory=Join-Path $profile.WorkRoot 'pairs'}
    if($roleAvailable -and $PairId -and $Action -ceq 'NonCTargetHandoffExport'){
        $preparation=Get-WsmWizardNonCPreparation -Workspace $Workspace -PairId $PairId -Jobs $Jobs
        if($preparation.Current -and $preparation.Current.ManifestHash){$args.ManifestHash=[string]$preparation.Current.ManifestHash}
        $choices=@((Get-WsmTextMetadataValue $preparation 'TransferChoices' @())|Group-Object sha256|ForEach-Object {$_.Group[0]})
        if($choices.Count -eq 1){$args.TransferPlanHash=[string]$choices[0].sha256}
    }
    $required=@($command.Parameters.Values|Where-Object {$_.Name -notin @('Workspace','PairId','Jobs','OperationId','CancellationToken') -and @($_.Attributes|Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0}|ForEach-Object {$_.Name})
    $missing=@(foreach($name in $required){if(-not $args.Contains($name)){[pscustomobject]@{name=$name;required=$true;present=$false;source='ExplicitIntentOrTrustedMaterial';reason='明確提供目前核准範圍的操作值或獨立可信材料。';options=@()}}})
    [pscustomobject]@{schemaVersion=1;kind='WizardActionDefaults';action=$Action;requiredRole=$requiredRole;args=[pscustomobject]$args;fields=$missing;missingFields=$missing;blocked=($missing.Count -gt 0 -or -not $roleAvailable);blockReason=$(if($roleAvailable){'請審閱並提供必要欄位。'}else{'目前工作區用途不符合這個操作。'});roleAvailable=$roleAvailable;sourceProvenance=$null;context=$null;executionPermission='Defaults do not authorize transfer, account mapping or proof import.'}
}

function Get-WsmHtmlWizardNonC([string]$Workspace,[string]$PairId,[string]$Role,[hashtable]$Jobs,[string]$ContextId) {
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne $Role){throw 'NonC controls require the enrolled workspace role.'}
    $records=Get-WsmHtmlWizardJobs $Jobs $Workspace;$catalog=$null
    if($Role -ceq 'Manager'){$catalog=Get-WsmCatalog $Workspace $PairId}
    $plan=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $records
    $items=@();if($plan){$items=@($plan.Plan.Items)}elseif($catalog){$items=@($catalog.Items)}
    $nonc=@($items|Where-Object {$_.Decision -ceq 'Include' -and $_.PSObject.Properties['MigrationSpec'] -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.PSObject.Properties['TransferChannel'] -and $_.MigrationSpec.TransferChannel -ceq 'NonC'})
    $result=[ordered]@{Kind='WizardNonCProjection';Role=$Role;PairId=$PairId;ContextId=$ContextId;DataVersion=(Get-WsmHtmlDataVersion $Workspace $PairId);HasNonC=($nonc.Count -gt 0);CurrentPlan=$(if($plan){[pscustomobject]@{path=$plan.Path;hash=$plan.SHA256}}else{$null});Preparation=$null;AccountObservation=$null;ResultSummary=$null;SourceChoices=$null;ProofAllowed=([bool]$plan -and $nonc.Count -gt 0)}
    if($nonc.Count -gt 0 -and $Role -ceq 'Manager'){
        $prep=Get-WsmWizardNonCPreparation -Workspace $Workspace -PairId $PairId -Jobs $records;$result.Preparation=$prep
        if($plan){$result.AccountObservation=Get-WsmWizardNonCAccountObservationSummary $Workspace $PairId $plan $prep $catalog $records;$result.ResultSummary=Get-WsmWizardNonCResultSummary $Workspace $PairId $plan $prep $catalog}
    }elseif($nonc.Count -gt 0 -and $Role -ceq 'Source'){$result.SourceChoices=Get-WsmWizardSourceNonCTransferChoices $Workspace $PairId $records}
    $actions=New-Object 'System.Collections.Generic.List[object]'
    if($nonc.Count -gt 0){
        if($Role -ceq 'Source'){
            $actions.Add((New-WsmWizardRuntimeAction 'NonCSourceProofExport' ([bool]$plan) '明確選擇本機既有共享與來源路徑；不建立共享、不提供新密碼。'))
            $backup=Get-WsmWizardBackupAvailability $Workspace $PairId $profile $records
            $ready=[bool]($backup -and $backup.packageTest -and $backup.packageTest.Final -and $backup.hasPackage)
            $actions.Add((New-WsmWizardRuntimeAction 'ImportNonCTransferPlan' $ready '需要目前已核驗的最終備份與獨立可信的傳輸／停寫材料。'))
            $canStart=[bool]($result.SourceChoices -and @($result.SourceChoices.TransferChoices).Count -gt 0)
            $actions.Add((New-WsmWizardRuntimeAction 'StartNonCTransfer' $canStart '只執行明確選擇且與目前最終備份綁定的傳輸，不代表離線備份或啟用。'))
        }elseif($Role -ceq 'Target'){
            $actions.Add((New-WsmWizardRuntimeAction 'NonCTargetProofExport' ([bool]$plan) '明確審閱目的地及狀態目錄，核對本機既有共享；不建立新共享。'))
            foreach($id in @('NonCTargetHandoffPreview','NonCTargetHandoffImport')){$actions.Add((New-WsmWizardRuntimeAction $id ([bool]$plan) '先以獨立可信指紋核對 Manager 交接，再明確選擇供復原使用的材料；不寫入目的檔案。'))}
        }
        else{
            foreach($id in @('NonCProofPreview','NonCProofImport')){$actions.Add((New-WsmWizardRuntimeAction $id ([bool]$plan) '使用獨立可信管道的預期 hash 核對 proof 交接，不需等最終備份。'))}
            $prep=$result.Preparation
            $canObserve=[bool]($prep -and $prep.Current.ManifestHash -and @($prep.ProofOptions|Where-Object kind -CEQ SourcePeerShareProof).Count -gt 0)
            $actions.Add((New-WsmWizardRuntimeAction 'NonCAccountObservation' $canObserve '唯讀觀測已核准範圍的 owner／DACL SID；未知值不作姓名猜測。'))
            $canPlan=[bool]($prep -and $prep.CanCreateTransferPlan -and $result.AccountObservation -and $result.AccountObservation.CoverageComplete)
            $actions.Add((New-WsmWizardRuntimeAction 'CreateNonCTransferPlan' $canPlan '明確審閱每個範圍與每個 principal 的目的 SID 後產生不可變傳輸計畫。'))
            $actions.Add((New-WsmWizardRuntimeAction 'ImportNonCResult' ([bool]($prep -and $prep.CanImportResult)) '核驗目前 exact 傳輸計畫的結果收據；staged 資料不代表備份或啟用完成。'))
            $actions.Add((New-WsmWizardRuntimeAction 'NonCTargetHandoffExport' ([bool]($result.ResultSummary -and $result.ResultSummary.hasDurableRecord -and $result.ResultSummary.current)) '明確選擇目前已核驗的傳輸計畫及結果交給 Target，再由 Target 核驗並執行復原。'))
        }
    }
    $result.actions=@($actions.ToArray())
    ConvertTo-WsmWizardHtmlValue ([pscustomobject]$result)
}
