# Read-only runtime projection for the Source and Target migration wizard.
# It deliberately does not call Get-WsmWizardProjection, so it can be composed
# by that public projection without recursion.

function Get-WsmWizardRuntimeActionContracts {
    $contracts=[ordered]@{}
    $contracts.StartBackup=[pscustomobject]@{Command='Invoke-WsmWizardStartBackup';RequiredFields=@('Workspace','PairId','OperationId');OptionalFields=@('DeliveryMode','VolumeBytes','Jobs','CancellationToken');ExplicitFields=@('Owner','Evidence','FreezeAuthorization','FreezeExternalEvidencePath','FreezeExternalEvidenceHash');Defaults=@('Workspace','PairId','DeliveryMode','VolumeBytes');PublicAction='StartBackup'}
    $contracts.IndependentCopy=[pscustomobject]@{Command='Invoke-WsmWizardIndependentCopy';RequiredFields=@('Workspace','PairId','OperationId','BackupOperationId','DestinationRoot');OptionalFields=@('Mode','CancellationToken');ExplicitFields=@('DestinationRoot');Defaults=@('Workspace','PairId','BackupOperationId','Mode');PublicAction='IndependentCopy'}
    $contracts.SourceResume=[pscustomobject]@{Command='Invoke-WsmSourceResume';RequiredFields=@('PlanPath','ExpectedHash','SourceAttemptPath','SourceAttemptHash','SourceStateDirectory','Owner','OwnershipEvidence','Acknowledgement','ResumeExternalEvidencePath','ResumeExternalEvidenceHash');OptionalFields=@('TaskReconciliationPath','TaskReconciliationHash');Defaults=@();PublicAction='SourceResume'}
    $contracts.ImportApprovedPlan=[pscustomobject]@{Command='Import-WsmWizardApprovedPlan';RequiredFields=@('Workspace','Role','Path','ExpectedHash');OptionalFields=@('SourceSnapshotPath');Defaults=@('Workspace','Role');PublicAction='ImportApprovedPlan'}
    $contracts.TargetZipImport=[pscustomobject]@{Command='Import-WsmWizardTargetZipPackage';RequiredFields=@('Workspace','PairId','TransportPath','ExpectedHash','OperationId');OptionalFields=@('CancellationToken');Defaults=@('Workspace','PairId');PublicAction='TargetZipImport'}
    $contracts.TargetDirectoryImport=[pscustomobject]@{Command='Import-WsmWizardTargetDirectoryPackage';RequiredFields=@('Workspace','PairId','SummaryPath','ExpectedSummaryHash','SourceDirectory','OperationId');OptionalFields=@('CancellationToken');Defaults=@('Workspace','PairId');PublicAction='TargetDirectoryImport'}
    $contracts.BackupImpactPreview=[pscustomobject]@{Command='Get-WsmWizardBackupImpactPreview';RequiredFields=@('Workspace','PairId');OptionalFields=@('DeliveryMode','VolumeBytes','Jobs','FreezeExternalEvidencePath','FreezeExternalEvidenceHash');ExplicitFields=@('FreezeExternalEvidencePath','FreezeExternalEvidenceHash');Defaults=@('Workspace','PairId','DeliveryMode','VolumeBytes');PublicAction='BackupImpactPreview'}
    $contracts.ComparisonExport=[pscustomobject]@{Command='Export-WsmWizardTargetComparison';RequiredFields=@('Workspace','PairId');OptionalFields=@('Jobs');Defaults=@('Workspace','PairId');PublicAction='ComparisonExport'}
    $contracts.ComparisonImport=[pscustomobject]@{Command='Import-WsmWizardTargetComparison';RequiredFields=@('Workspace','PairId','Path','ExpectedHash');OptionalFields=@('Jobs');ExplicitFields=@('Path','ExpectedHash');Defaults=@('Workspace','PairId');PublicAction='ComparisonImport'}
    $contracts.TargetLocalComparison=[pscustomobject]@{Command='New-WsmWizardTargetLocalComparison';RequiredFields=@('Workspace','PairId');OptionalFields=@('Jobs');ExplicitFields=@();Defaults=@('Workspace','PairId');PublicAction='TargetLocalComparison'}
    $contracts.CreateTargetDecisionReceipt=[pscustomobject]@{Command='Create-WsmWizardTargetDecisionReceipt';RequiredFields=@('Workspace','PairId','Decision','Owner','Reason','SelectedItemIds');OptionalFields=@('AcceptedUnpreparedItemIds','Jobs');ExplicitFields=@('Decision','Owner','Reason','SelectedItemIds','AcceptedUnpreparedItemIds');Defaults=@('Workspace','PairId');PublicAction='CreateTargetDecisionReceipt'}
    $contracts.TargetRetryFailedItems=[pscustomobject]@{Command='Create-WsmWizardTargetDecisionReceipt';RequiredFields=@('Workspace','PairId','Decision','Owner','Reason','SelectedItemIds','RetryOfReceiptHash');OptionalFields=@('AcceptedUnpreparedItemIds','Jobs');ExplicitFields=@('Owner','Reason');Defaults=@('Workspace','PairId','Decision','SelectedItemIds','RetryOfReceiptHash');PublicAction='TargetRetryFailedItems'}
    $contracts.TargetRestorePreview=[pscustomobject]@{Command='Get-WsmWizardTargetRestoreProjection';RequiredFields=@('Workspace','PairId');OptionalFields=@('Jobs','GeneralHostEvidence');Defaults=@('Workspace','PairId');PublicAction='TargetRestorePreview'}
    $contracts.TargetRestore=[pscustomobject]@{Command='Invoke-WsmWizardTargetRestore';RequiredFields=@('Workspace','PairId','PreviewHash');OptionalFields=@('Jobs','CancellationToken','Secrets','GeneralHostEvidence','OperationId','ChallengeContext');Defaults=@('Workspace','PairId','PreviewHash');PublicAction='TargetRestore'}
    $contracts.TargetValidation=[pscustomobject]@{Command='Invoke-WsmWizardTargetValidation';RequiredFields=@('Workspace','PairId');OptionalFields=@('Phase','Jobs','GeneralHostEvidence');Defaults=@('Workspace','PairId','Phase');PublicAction='TargetValidation'}
    $contracts.TargetAcceptance=[pscustomobject]@{Command='Get-WsmWizardTargetAcceptanceGates';RequiredFields=@('Workspace','PairId');OptionalFields=@('Jobs','GeneralHostEvidence');Defaults=@('Workspace','PairId');PublicAction='TargetAcceptance'}
    $contracts.TargetActivation=[pscustomobject]@{Command='Invoke-WsmWizardTargetActivation';RequiredFields=@('Workspace','PairId','CutoverPlanPath','CutoverPlanHash','Acknowledgement');OptionalFields=@('Jobs','Secrets','GeneralHostEvidence','ExternalEvidenceReferences','ResumeActivation','ResumeOwner','ResumeEvidence');Defaults=@('Workspace','PairId');ExplicitFields=@('CutoverPlanPath','CutoverPlanHash','Acknowledgement','ResumeOwner','ResumeEvidence');PublicAction='TargetActivation'}
    $contracts
}

function New-WsmWizardRuntimeAction([string]$Id,[bool]$Available,[string]$Reason,[hashtable]$Defaults=@{},[string[]]$Missing=@()) {
    [pscustomobject][ordered]@{id=$Id;available=$Available;reason=$Reason;defaults=[pscustomobject]$Defaults;missing=@($Missing)}
}

function Test-WsmWizardRuntimeActivatedBinding([string]$Workspace,[string]$PairId,$Plan,$Package,$State,[object[]]$Jobs) {
    if([string]$State.Stage -cne 'PostCutoverValidationRequired' -or -not $State.Cutover -or [string]$State.Cutover.Stage -cne 'Activated' -or -not $State.Cutover.NewTransactionsPossible -or [string]$State.Cutover.PlanHash -notmatch '^[a-fA-F0-9]{64}$'){return $false}
    foreach($job in @($Jobs)){
        if([string](Get-WsmWizardTargetJobField $job action Action) -cne 'TargetActivation' -or [string](Get-WsmWizardTargetJobField $job role Role) -cne 'Target' -or [string](Get-WsmWizardTargetJobField $job pairId PairId) -cne $PairId -or [string](Get-WsmWizardTargetJobField $job status Status) -notin @('Succeeded','ReviewRequired')){continue}
        try{if([IO.Path]::GetFullPath([string](Get-WsmWizardTargetJobField $job workspace Workspace)) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
        foreach($output in @((Get-WsmWizardTargetJobField $job outputs Outputs))){
            if($output -and [string]$output.Status -ceq 'PostCutoverValidationRequired' -and [string]$output.CutoverStage -ceq 'Activated' -and [string]$output.PairId -ceq $PairId -and [string]$output.PlanHash -ieq [string]$Plan.SHA256 -and [string]$output.ManifestHash -ieq [string]$Package.ManifestHash -and [long]$output.Generation -eq [long]$Package.Package.Manifest.Generation -and [string]$output.CutoverPlanHash -ieq [string]$State.Cutover.PlanHash){return $true}
        }
    }
    $false
}

function Get-WsmWizardRuntimeTargetRestoreResult([string]$Workspace,[string]$PairId,$Plan,$Package,$Snapshot,$Decision,[object[]]$Jobs) {
    $runtimeRestoreMatches=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($Jobs)){
        if(-not $job -or [string](Get-WsmWizardTargetJobField $job action Action) -cne 'TargetRestore' -or [string](Get-WsmWizardTargetJobField $job role Role) -cne 'Target' -or [string](Get-WsmWizardTargetJobField $job pairId PairId) -cne $PairId -or [string](Get-WsmWizardTargetJobField $job status Status) -notin @('Succeeded','ReviewRequired','Cancelled','Failed','Interrupted')){continue}
        try{if([IO.Path]::GetFullPath([string](Get-WsmWizardTargetJobField $job workspace Workspace)) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
        $jobId=[string](Get-WsmWizardTargetJobField $job jobId JobId)
        foreach($output in @((Get-WsmWizardTargetJobField $job outputs Outputs))){
            if(-not $output -or [string]$output.PairId -cne $PairId -or [string]$output.PlanHash -ine [string]$Plan.SHA256 -or [string]$output.ManifestHash -ine [string]$Package.ManifestHash -or [long]$output.Generation -ne [long]$Package.Package.Manifest.Generation -or [string]$output.Decision -cne [string]$Decision.Receipt.Decision -or [string]$output.DecisionReceiptHash -ine [string]$Decision.SHA256){continue}
            if((@($output.SelectedItemIds | Sort-Object -Unique) -join "`n") -cne (@($Decision.Receipt.SelectedItemIds | Sort-Object -Unique) -join "`n")){continue}
            $status=[string]$output.Status
            if($status -ceq 'DeferredSoftware' -and [string]$Decision.Receipt.Decision -ceq 'WaitForInstall'){
                $runtimeRestoreMatches.Add([pscustomobject][ordered]@{status='WaitingForInstall';stage='WaitingForInstall';workerStatus=[string](Get-WsmWizardTargetJobField $job status Status);pairId=$PairId;planHash=[string]$Plan.SHA256;manifestHash=[string]$Package.ManifestHash;generation=[long]$Package.Package.Manifest.Generation;attemptId='';current=$true;hasDurableRecord=$true;authoritativeApproval=$false;productionVerified=$false;rows=@($output.Rows);itemResults=@();journalPath='';journalHash=''})
                continue
            }
            $attemptId=[string]$output.AttemptOperationId
            if($status -notin @('Succeeded','Partial','RebootRequired','Cancelled','Failed') -or -not $attemptId -or $attemptId -cne $jobId -or [string]$output.TargetSnapshotHash -ine [string]$Snapshot.SHA256 -or [string]$output.ItemResultsHash -notmatch '^[a-fA-F0-9]{64}$' -or -not $output.PSObject.Properties['ItemResults']){continue}
            $safeProjectedItemResults=($output.PSObject.Properties['SafeProjectedItemResults'] -and $output.SafeProjectedItemResults -is [bool] -and $output.SafeProjectedItemResults)
            if(-not $safeProjectedItemResults -and (Get-WsmHashText ($output.ItemResults|ConvertTo-Json -Depth 100 -Compress)) -ine [string]$output.ItemResultsHash){continue}
            try{
                $paths=Get-WsmOperationPaths (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs') $PairId
                if(-not [IO.File]::Exists($paths.State)){continue};$state=Get-WsmOperationState $paths $Package.Package;$attempt=$state.RestoreAttempt
                if(-not $attempt -or ([string]$state.Stage -cne $status -and -not ($status -in @('Succeeded','Partial','RebootRequired') -and (Test-WsmWizardRuntimeActivatedBinding $Workspace $PairId $Plan $Package $state $Jobs))) -or [string]$attempt.OperationId -cne $attemptId -or [string]$attempt.ManifestHash -ine [string]$Package.ManifestHash -or [long]$attempt.Generation -ne [long]$Package.Package.Manifest.Generation -or [string]$attempt.DecisionReceiptHash -ine [string]$Decision.SHA256 -or [string]$attempt.TargetSnapshotHash -ine [string]$Snapshot.SHA256 -or [string]$attempt.TargetSnapshotPath -ine [string]$Snapshot.Path -or [string]$attempt.DecisionReceiptPath -ine [string]$Decision.Path -or (@($attempt.SelectedItemIds|Sort-Object -Unique)-join "`n") -cne (@($Decision.Receipt.SelectedItemIds|Sort-Object -Unique)-join "`n") -or (@($state.PendingOperations).Count -gt 0)){continue}
                $attemptResultsHash=Get-WsmHashText (@($attempt.ItemResults)|ConvertTo-Json -Depth 100 -Compress)
                if($attemptResultsHash -ine [string]$output.ItemResultsHash){continue}
                $journalRoot=[IO.Path]::GetFullPath((Join-Path $paths.Root 'restore-journals')).TrimEnd('\')+'\';$journalPath=[IO.Path]::GetFullPath([string]$output.JournalPath)
                if([string]$output.JournalHash -notmatch '^[a-fA-F0-9]{64}$' -or -not $journalPath.StartsWith($journalRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($journalPath).TrimEnd('\') -ine $journalRoot.TrimEnd('\') -or [IO.Path]::GetFileName($journalPath) -cne ([string]$output.JournalHash+'.jsonl') -or -not [IO.File]::Exists($journalPath)){continue}
                Assert-WsmNoReparse $journalPath;if((Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash -ine [string]$output.JournalHash){continue}
                $runtimeRestoreMatches.Add([pscustomobject][ordered]@{status=$status;stage=$status;workerStatus=[string](Get-WsmWizardTargetJobField $job status Status);pairId=$PairId;planHash=[string]$Plan.SHA256;manifestHash=[string]$Package.ManifestHash;generation=[long]$Package.Package.Manifest.Generation;attemptId=$attemptId;runId=$jobId;current=$true;hasDurableRecord=$true;authoritativeApproval=$false;productionVerified=$false;rows=@($output.Rows);itemResults=@($output.ItemResults);itemResultsHash=[string]$output.ItemResultsHash;journalPath=$journalPath;journalHash=([string]$output.JournalHash).ToLowerInvariant()})
            }catch{continue}
        }
    }
    if($runtimeRestoreMatches.Count -ne 1){return $null};$runtimeRestoreMatches[0]
}

function Get-WsmWizardRuntimeFailedRestore([string]$Workspace,[string]$PairId,$Package,$Snapshot,$DecisionRecord,[object[]]$Jobs) {
    # RestoreAvailability intentionally admits only receipts with a valid
    # terminal journal. A failed pre-journal attempt still needs to be visible
    # for an explicit new decision, so recognize it only from the durable
    # operation state plus its exact formal job/output binding.
    try{
        $paths=Get-WsmOperationPaths (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs') $PairId
        if(-not [IO.File]::Exists($paths.State)){return $null}
        $state=Get-WsmOperationState $paths $Package.Package
        if([string]$state.Stage -cne 'Failed' -or -not $state.RestoreAttempt){return $null}
        $attempt=$state.RestoreAttempt
        if([string]$state.PairId -cne $PairId -or [string]$state.ManifestHash -ine [string]$Package.ManifestHash -or [long]$state.Generation -ne [long]$Package.Package.Manifest.Generation -or [string]$attempt.ManifestHash -ine [string]$Package.ManifestHash -or [long]$attempt.Generation -ne [long]$Package.Package.Manifest.Generation -or [string]$attempt.TargetSnapshotHash -ine [string]$Snapshot.SHA256 -or [string]$attempt.DecisionReceiptHash -ine [string]$DecisionRecord.SHA256 -or [string]$attempt.DecisionReceiptPath -ine [string]$DecisionRecord.Path){return $null}
        foreach($job in @($Jobs)){
            if([string](Get-WsmWizardTargetJobField $job action Action) -cne 'TargetRestore' -or [string](Get-WsmWizardTargetJobField $job role Role) -cne 'Target' -or [string](Get-WsmWizardTargetJobField $job pairId PairId) -cne $PairId -or [string](Get-WsmWizardTargetJobField $job status Status) -notin @('Failed','Interrupted')){continue}
            if([string](Get-WsmWizardTargetJobField $job jobId JobId) -cne [string]$attempt.OperationId){continue}
            try{if([IO.Path]::GetFullPath([string](Get-WsmWizardTargetJobField $job workspace Workspace)) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
            foreach($output in @((Get-WsmWizardTargetJobField $job outputs Outputs))){
                if(-not $output){continue}
                $attemptId=[string](Get-WsmWizardTargetJobField $output AttemptOperationId AttemptId);if(-not $attemptId){$attemptId=[string](Get-WsmWizardTargetJobField $output OperationId OperationId)}
                if($attemptId -cne [string]$attempt.OperationId -or [string](Get-WsmWizardTargetJobField $output PairId PairId) -cne $PairId -or [string](Get-WsmWizardTargetJobField $output ManifestHash ManifestHash) -ine [string]$Package.ManifestHash){continue}
                try{if([long](Get-WsmWizardTargetJobField $output Generation Generation) -ne [long]$Package.Package.Manifest.Generation){continue}}catch{continue}
                return [pscustomobject][ordered]@{status='Failed';stage='Failed';workerStatus=[string](Get-WsmWizardTargetJobField $job status Status);pairId=$PairId;manifestHash=[string]$Package.ManifestHash;generation=[long]$Package.Package.Manifest.Generation;attemptId=[string]$attempt.OperationId;runId=[string](Get-WsmWizardTargetJobField $job jobId JobId);current=$true;hasDurableRecord=$true;authoritativeApproval=$false;productionVerified=$false}
            }
        }
    }catch{}
    $null
}

function Test-WsmWizardRuntimeTargetNonCPreviewBinding([string]$Workspace,[string]$PairId,$Plan,$Package,$Snapshot,$Decision,$Output) {
    $selected=@($Decision.Receipt.SelectedItemIds)
    $nonCItems=@($Plan.Plan.Items|Where-Object {$selected -ccontains [string]$_.ItemId -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'})
    $outputPlanHash=if($Output.PSObject.Properties['NonCTransferPlanHash']){[string]$Output.NonCTransferPlanHash}else{''}
    $outputResultHash=if($Output.PSObject.Properties['NonCResultHash']){[string]$Output.NonCResultHash}else{''}
    if(-not $nonCItems.Count){return (-not $outputPlanHash -and -not $outputResultHash)}
    $invalidMaterialsIssue='CurrentNonCMaterialsInvalid; retain the materials for inspection and import a newly verified handoff before restoring NonC items.'
    try{
        $active=Get-WsmWizardNonCTargetActiveReceipt $Workspace $PairId
        if(-not $active){return (-not [string]$Output.NonCEvidenceIssue -and -not $outputPlanHash -and -not $outputResultHash)}
        $record=$active.Receipt
        if([string]$record.PairId -cne $PairId -or [string]$record.PlanHash -ine [string]$Plan.SHA256 -or [string]$record.ManifestHash -ine [string]$Package.ManifestHash -or [long]$record.Generation -ne [long]$Package.Package.Manifest.Generation -or [string]$record.TargetSnapshotHash -ine [string]$Snapshot.SHA256){return $false}
        if([string]$record.TransferPlanHash -notmatch '^[a-fA-F0-9]{64}$' -or [string]$record.ResultHash -notmatch '^[a-fA-F0-9]{64}$' -or $outputPlanHash -ine [string]$record.TransferPlanHash -or $outputResultHash -ine [string]$record.ResultHash -or [string]$Output.NonCEvidenceIssue){return $false}
        Assert-WsmTrustedFile ([string]$record.TransferPlanPath) ([string]$record.TransferPlanHash) | Out-Null
        Assert-WsmTrustedFile ([string]$record.ResultPath) ([string]$record.ResultHash) | Out-Null
        return $true
    }catch{return ([string]$Output.NonCEvidenceIssue -ceq $invalidMaterialsIssue -and -not $outputPlanHash -and -not $outputResultHash)}
}

function Get-WsmWizardRuntimeTargetPreviewJobResult([string]$Workspace,[string]$PairId,$Plan,$Package,$Snapshot,$Comparison,$Decision,[object[]]$Jobs) {
    $runtimePreviewMatches=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($Jobs)){
        if(-not $job -or [string](Get-WsmWizardTargetJobField $job action Action) -cne 'TargetRestorePreview' -or [string](Get-WsmWizardTargetJobField $job role Role) -cne 'Target' -or [string](Get-WsmWizardTargetJobField $job pairId PairId) -cne $PairId -or [string](Get-WsmWizardTargetJobField $job status Status) -notin @('Succeeded','ReviewRequired')){continue}
        try{if([IO.Path]::GetFullPath([string](Get-WsmWizardTargetJobField $job workspace Workspace)) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
        foreach($output in @((Get-WsmWizardTargetJobField $job outputs Outputs))){
            if(-not $output -or [string]$output.Status -cne 'Previewed' -or [string]$output.PairId -cne $PairId -or [string]$output.PlanHash -ine [string]$Plan.SHA256 -or [string]$output.ManifestHash -ine [string]$Package.ManifestHash -or [long]$output.Generation -ne [long]$Package.Package.Manifest.Generation -or [string]$output.ReceiptHash -ine [string]$Decision.SHA256 -or [string]$output.TargetSnapshotHash -ine [string]$Snapshot.SHA256 -or [string]$output.ComparisonHash -ine [string]$Decision.Receipt.ComparisonHash -or [int]$output.ComparisonRevision -ne [int]$Decision.Receipt.ComparisonRevision -or [int]$output.SelectionRevision -ne [int]$Decision.Receipt.SelectionRevision -or [string]$output.Decision -cne [string]$Decision.Receipt.Decision -or [string]$output.PreviewHash -notmatch '^[a-fA-F0-9]{64}$'){continue}
            if((@($output.SelectedItemIds | Sort-Object -Unique) -join "`n") -cne (@($Decision.Receipt.SelectedItemIds | Sort-Object -Unique) -join "`n")){continue}
            $wizardIssue='';if($output.PSObject.Properties['NonCEvidenceIssue']){$wizardIssue=[string]$output.NonCEvidenceIssue};$output | Add-Member NoteProperty WizardNonCEvidenceIssue $wizardIssue -Force
            try{$calculated=Get-WsmWizardTargetPreviewHash $output $PairId ([string]$Plan.SHA256) ([string]$Package.ManifestHash) ([long]$Package.Package.Manifest.Generation) ([string]$Decision.SHA256) ([string]$Snapshot.SHA256) ([string]$Decision.Receipt.ComparisonHash) ([int]$Decision.Receipt.ComparisonRevision) ([int]$Decision.Receipt.SelectionRevision) ([string]$Decision.Receipt.Decision)}catch{continue}
            if($calculated -ine [string]$output.PreviewHash){continue}
            if(-not (Test-WsmWizardRuntimeTargetNonCPreviewBinding $Workspace $PairId $Plan $Package $Snapshot $Decision $output)){continue}
            $runtimePreviewMatches.Add([pscustomobject]@{Output=$output;CompletedUtc=[string](Get-WsmWizardTargetJobField $job CompletedUtc completedUtc);JobId=[string](Get-WsmWizardTargetJobField $job jobId JobId)})
        }
    }
    if(-not $runtimePreviewMatches.Count){return $null}
    $latest=@($runtimePreviewMatches.ToArray() | Sort-Object @{Expression={try{[DateTimeOffset]::Parse([string]$_.CompletedUtc)}catch{[DateTimeOffset]::MinValue}};Descending=$true},@{Expression={$_.JobId};Descending=$false})
    $latest[0].Output
}

function Get-WsmWizardSourceResumeEvidence([string]$Workspace,[string]$PairId,$Profile,$PlanRef,$BackupAttempt,[object[]]$Jobs) {
    $pairsRoot=[IO.Path]::GetFullPath((Join-Path $Workspace 'pairs'));$sourceAttemptPath='';$sourceAttemptHash='';$sourceAttempt=$null;$receiptError='';$attemptError='';$freezeRecordVerified=$false;$freezeRecordFresh=$false
    try{
        $freezePath='';$freezeHash=''
        if($BackupAttempt.Freeze -and $BackupAttempt.Freeze.Path -and $BackupAttempt.Freeze.SHA256 -match '^[a-fA-F0-9]{64}$'){$freezePath=[IO.Path]::GetFullPath([string]$BackupAttempt.Freeze.Path);$freezeHash=[string]$BackupAttempt.Freeze.SHA256}
        elseif($BackupAttempt.OutputRoot){$freezePath=[IO.Path]::GetFullPath((Join-Path ([string]$BackupAttempt.OutputRoot) 'source-freeze.json'));if([IO.File]::Exists($freezePath)){$freezeHash=(Get-FileHash -LiteralPath $freezePath -Algorithm SHA256).Hash}}
        if($freezePath -and [IO.File]::Exists($freezePath)){
            Assert-WsmNoReparse $freezePath
            if((Get-FileHash -LiteralPath $freezePath -Algorithm SHA256).Hash -ieq $freezeHash){
                $freeze=Read-WsmFreezeRecord $freezePath $freezeHash $PlanRef.Plan ([string]$PlanRef.SHA256) -AllowExpired
                if($freeze.PairId -ceq $PairId -and $freeze.PlanHash -ieq [string]$PlanRef.SHA256 -and $freeze.PSObject.Properties['SourceAttemptPath'] -and $freeze.PSObject.Properties['SourceAttemptHash']){
                    $freezeRecordVerified=$true
                    $freezeExpiry=[DateTimeOffset]::MinValue;if([DateTimeOffset]::TryParse([string]$freeze.ExpiresUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$freezeExpiry) -and $freezeExpiry.Offset -eq [TimeSpan]::Zero -and $freezeExpiry -gt [DateTimeOffset]::UtcNow){$freezeRecordFresh=$true}
                    $candidate=[IO.Path]::GetFullPath([string]$freeze.SourceAttemptPath);Assert-WsmNoReparse $candidate
                    $candidateDirectory=[IO.Path]::GetDirectoryName($candidate);$ownedPrefix=$pairsRoot.TrimEnd('\')+'\freeze-'+$PairId+'-'
                    if($candidate.StartsWith($ownedPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($candidate) -ceq 'attempt.json' -and [IO.File]::Exists($candidate)){
                        $actualHash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
                        if($actualHash -ieq [string]$freeze.SourceAttemptHash){$sourceAttemptPath=$candidate;$sourceAttemptHash=$actualHash}
                        else{
                            # SourceResume updates the owned attempt in place. A changed
                            # hash is usable only as a status observation; unlocking a
                            # new backup still requires the matching successful job output.
                            $observed=Read-WsmSourceAttempt $candidate $actualHash $PlanRef.Plan ([string]$PlanRef.SHA256)
                            if($observed.State.Status -ceq 'SourceResumed'){$sourceAttemptPath=$candidate;$sourceAttemptHash=$actualHash}
                        }
                        if($sourceAttemptPath){$sourceAttempt=Read-WsmSourceAttempt $sourceAttemptPath $sourceAttemptHash $PlanRef.Plan ([string]$PlanRef.SHA256)}
                    }
                }
            }
        }
    }catch{$receiptError=$_.Exception.Message;$sourceAttemptPath='';$sourceAttemptHash='';$sourceAttempt=$null}
    if(-not $sourceAttempt -and $BackupAttempt.PSObject.Properties['FreezeAttemptStarted'] -and $BackupAttempt.FreezeAttemptStarted -and $BackupAttempt.PSObject.Properties['FreezeAttemptStartedUtc'] -and $BackupAttempt.FreezeAttemptStartedUtc){
        try{
            $started=[DateTimeOffset]::MinValue
            if(-not [DateTimeOffset]::TryParse([string]$BackupAttempt.FreezeAttemptStartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$started) -or $started.Offset -ne [TimeSpan]::Zero){throw 'Freeze attempt start timestamp is missing or invalid.'}
            Assert-WsmNoReparse $pairsRoot
            $candidates=New-Object 'System.Collections.Generic.List[object]'
            foreach($folder in @(Get-ChildItem -LiteralPath $pairsRoot -Directory -Filter ('freeze-'+$PairId+'-*'))){
                Assert-WsmNoReparse $folder.FullName;$candidate=Join-Path $folder.FullName 'attempt.json';if(-not [IO.File]::Exists($candidate)){continue};Assert-WsmNoReparse $candidate
                try{$hash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant();$observed=Read-WsmSourceAttempt $candidate $hash $PlanRef.Plan ([string]$PlanRef.SHA256);$utc=[DateTimeOffset]::Parse([string]$observed.State.Utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind);if($utc -lt $started -or [string]$observed.State.Owner -cne [string]$BackupAttempt.FreezeOwner -or [string]$observed.State.Evidence -cne [string]$BackupAttempt.FreezeEvidence){continue};$candidates.Add([pscustomobject]@{Path=[IO.Path]::GetFullPath($candidate);Hash=$hash;Attempt=$observed})}catch{}
            }
            if($candidates.Count -eq 1){$sourceAttemptPath=$candidates[0].Path;$sourceAttemptHash=$candidates[0].Hash;$sourceAttempt=$candidates[0].Attempt}
            elseif($candidates.Count -gt 1){$attemptError='發現多份符合停寫開始紀錄的來源停寫資料，無法自動選擇；請保留資料並人工核對。'}
        }catch{$attemptError=$_.Exception.Message}
    }
    $resumeJobVerified=$false
    if($sourceAttempt -and $sourceAttempt.State.Status -ceq 'SourceResumed'){
        $operationRoot=[IO.Path]::GetFullPath((Join-Path $pairsRoot ('source-operations\'+$PairId)))
        try{Assert-WsmNoReparse $operationRoot;if(-not [IO.Directory]::Exists($operationRoot)){$sourceAttempt=$null}}catch{$sourceAttempt=$null}
    }
    if($sourceAttempt -and $sourceAttempt.State.Status -ceq 'SourceResumed'){
        foreach($job in @($Jobs)){
            if(-not $job -or [string](Get-WsmWizardTargetJobField $job action Action) -cne 'SourceResume' -or [string](Get-WsmWizardTargetJobField $job status Status) -cne 'Succeeded' -or [string](Get-WsmWizardTargetJobField $job role Role) -cne 'Source' -or [string](Get-WsmWizardTargetJobField $job pairId PairId) -cne $PairId){continue}
            try{if([IO.Path]::GetFullPath([string](Get-WsmWizardTargetJobField $job workspace Workspace)) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
            foreach($output in @(Get-WsmWizardTargetJobField $job outputs Outputs)){
                if($output -and $output.PSObject.Properties['Path'] -and $output.PSObject.Properties['SHA256'] -and [IO.Path]::GetFullPath([string]$output.Path) -ieq $sourceAttemptPath -and [string]$output.SHA256 -ieq $sourceAttemptHash){$resumeJobVerified=$true;break}
            }
            if($resumeJobVerified){break}
        }
    }
    [pscustomobject]@{Path=$sourceAttemptPath;Hash=$sourceAttemptHash;Attempt=$sourceAttempt;FreezeRecordVerified=$freezeRecordVerified;FreezeRecordFresh=$freezeRecordFresh;ResumeJobVerified=$resumeJobVerified;MissingReason=$(if($attemptError){$attemptError}elseif($receiptError){'停寫收據無法核對；請保留資料並檢查收據與來源停寫紀錄。'}else{'未找到唯一可核對的來源停寫紀錄；請保留資料並檢查配對目錄中的停寫收據與嘗試紀錄。'})}
}

function Get-WsmWizardRuntimeSource([string]$Workspace,[string]$PairId,$Profile,[object[]]$Jobs) {
    $planRef=$null
    try{$planRef=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $Profile $null $Jobs}catch{}
    if(-not $planRef){
        $choices=@();try{$choices=@(Get-WsmWizardReceivedPlanChoices $Workspace $Profile)}catch{}
        $importDefaults=@{Workspace=[IO.Path]::GetFullPath($Workspace);Role='Source'}
        $action=New-WsmWizardRuntimeAction 'ImportApprovedPlan' ($choices.Count -gt 0) $(if($choices.Count){'選擇已核准且綁定目前來源主機的計畫。'}else{'目前沒有可匯入的已核准計畫；需先由 Manager 產生可信交接材料。'}) $importDefaults @('Path','ExpectedHash')
        return [pscustomobject][ordered]@{status='NeedsApprovedPlan';plan=$null;backupPreview=$null;backupResult=$null;delivery=[pscustomobject]@{mode='';volumeBytes=$null;frozen=$false};sourceFreeze=[pscustomobject]@{required=$false;missingEvidence=@();resumeRequired=$false;resumeRoute=$null;sourceResumed=$false;manualReviewRequired=$false;manualReviewReason=''};actions=@($action);choices=$choices;canStartBackup=$false;offlineReadiness='NotDelivered'}
    }
    # A runtime read must not create a WizardState record as a side effect.
    $state=$null
    try{$statePath=Get-WsmWizardStatePath $Workspace $PairId Source;if([IO.File]::Exists($statePath)){$state=Read-WsmJson $statePath;Assert-WsmWizardState $state $Profile $PairId|Out-Null}}catch{$state=$null}
    $selectedMode='Zip';$volume=[long]536870912
    if($state -and $state.PSObject.Properties['Mode']){switch([string]$state.Mode){'ItemByItem'{$selectedMode='Directory';$volume=0};'Automatic'{$selectedMode='Zip';$volume=536870912};default{throw 'Unknown wizard mode while projecting Source delivery defaults.'}}}
    $existing=$null;$backupRoot=Join-Path (Join-Path (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'workspace-control') 'wizard-backups') $PairId
    if([IO.Directory]::Exists($backupRoot)){
        try{$existing=Get-WsmWizardBackupAttempt $Workspace $PairId $Profile ([string]$planRef.SHA256)}catch{}
    }
    $frozen=$false;$attempt=$null
    if($existing -and $existing.Attempt){
        $attempt=$existing.Attempt
        try{$output=Resolve-WsmOutputWorkspace -WorkRoot $Workspace -Role Source -PairId $PairId -PlanHash ([string]$planRef.SHA256) -AttemptId ([string]$attempt.AttemptId);$selectedMode=[string]$output.AttemptProfile.Mode;$volume=[long]$output.AttemptProfile.VolumeBytes;$frozen=$true}catch{}
    }
    $preview=$null;try{$preview=Get-WsmWizardBackupImpactPreview -Workspace $Workspace -PairId $PairId -Jobs $Jobs}catch{}
    $availability=$null;try{$availability=Get-WsmWizardBackupAvailability $Workspace $PairId $Profile $Jobs}catch{}
    $freezeRequired=[bool]($preview -and $preview.FreezeRequired)
    $missingEvidence=@();if($freezeRequired){$missingEvidence=@('Owner','Evidence','FreezeAuthorization','FreezeExternalEvidencePath','FreezeExternalEvidenceHash')}
    $sourceResumeEvidence=$null;$sourceResumed=$false;$sourceResumeRequired=$false;$sourceResumeAvailable=$false;$sourceResumeFreshFreezePending=$false
    if($availability -and $availability.attempt){
        $backupAttempt=$availability.attempt
        $sourceResumeRequired=[bool]($backupAttempt.PSObject.Properties['SourceResumeRequired'] -and $backupAttempt.SourceResumeRequired)
        $sourceResumeFreshFreezePending=[bool]($backupAttempt.PSObject.Properties['SourceResumeFreshFreezePending'] -and $backupAttempt.SourceResumeFreshFreezePending)
        if(-not $sourceResumeRequired -and $backupAttempt.PSObject.Properties['FreezeAttemptStarted'] -and $backupAttempt.FreezeAttemptStarted -and -not $backupAttempt.ChannelSummary -and [string]$backupAttempt.Stage -in @('Authorized','CoreExported','PackageVerified','Failed','Cancelled')){$sourceResumeRequired=$true}
        if($sourceResumeRequired -or $sourceResumeFreshFreezePending){$sourceResumeEvidence=Get-WsmWizardSourceResumeEvidence $Workspace $PairId $Profile $planRef $backupAttempt $Jobs;if($sourceResumeEvidence.Attempt){$sourceAttemptStatus=[string]$sourceResumeEvidence.Attempt.State.Status;$sourceResumeAvailable=$sourceAttemptStatus -in @('Prepared','Quiescing','Interrupted','Frozen')};if($sourceResumeEvidence.Attempt -and $sourceResumeEvidence.Attempt.State.Status -ceq 'SourceResumed' -and $sourceResumeEvidence.ResumeJobVerified){$sourceResumed=$true;$sourceResumeRequired=$false;$sourceResumeAvailable=$false}elseif($sourceResumeEvidence.FreezeRecordVerified -and $sourceResumeEvidence.FreezeRecordFresh -and $sourceResumeEvidence.Attempt -and $sourceResumeEvidence.Attempt.State.Status -ceq 'Frozen'){$sourceResumeRequired=$false}}
    }
    if($sourceResumed){$attempt=$null;$frozen=$false;$selectedMode='Zip';$volume=[long]536870912;if($state -and $state.PSObject.Properties['Mode']){switch([string]$state.Mode){'ItemByItem'{$selectedMode='Directory';$volume=0};'Automatic'{$selectedMode='Zip';$volume=536870912}}}}
    $resumeRoute=$null
    if($sourceResumeRequired -or $sourceResumeAvailable){
        $sourceAttemptPath='';$sourceAttemptHash='';$manualReviewReason='';if($sourceResumeEvidence){$sourceAttemptPath=[string]$sourceResumeEvidence.Path;$sourceAttemptHash=[string]$sourceResumeEvidence.Hash;if(-not $sourceAttemptPath){$manualReviewReason=[string]$sourceResumeEvidence.MissingReason}elseif($sourceResumeEvidence.Attempt.State.Status -ceq 'SourceResumed'){$manualReviewReason='來源停寫紀錄顯示已恢復，但尚無可核對的恢復成功收據（SourceResume 工作路徑與 SHA256）；請保留資料並人工核對所有權與紀錄。'}}
        if(-not $sourceAttemptPath){$sourceResumeAvailable=$false};if($manualReviewReason){$sourceResumeAvailable=$false}
        $resumeRoute=[pscustomobject][ordered]@{required=$sourceResumeRequired;action='SourceResume';command='Invoke-WsmSourceResume';sourceAttemptPath=$sourceAttemptPath;sourceAttemptHash=$sourceAttemptHash;sourceStateDirectory=(Join-Path $Workspace 'pairs');manualReviewRequired=[bool]$manualReviewReason;manualReviewReason=$manualReviewReason;missingExplicitFields=@('Owner','OwnershipEvidence','Acknowledgement','ResumeExternalEvidencePath','ResumeExternalEvidenceHash')}
    }
    $status='Ready';if($freezeRequired -and $missingEvidence.Count){$status='NeedsFreezeEvidence'}elseif($availability -and [string]$availability.status -in @('Failed','Cancelled','Prepared','ReviewRequired')){$status=[string]$availability.status};if($sourceResumed){$status='Ready'}
    $startDefaults=@{Workspace=[IO.Path]::GetFullPath($Workspace);PairId=$PairId;DeliveryMode=$selectedMode;VolumeBytes=$volume}
    # Availability means the user may open the explicit authorization form;
    # canStartBackup is the stricter statement that the current projection has
    # no unresolved freeze fields. StartBackup still revalidates every supplied
    # value and trusted SourceFreezeReady evidence at submission time.
    $startAvailable=($null -ne $planRef -and -not $sourceResumeRequired)
    $canStartBackupReady=($startAvailable -and -not ($freezeRequired -and $missingEvidence.Count))
    $startReason=if($sourceResumeRequired -and $sourceResumeEvidence -and $sourceResumeEvidence.FreezeRecordVerified -and -not $sourceResumeEvidence.FreezeRecordFresh){'來源凍結收據已過期；可先明確執行 SourceResume，但續作此備份前必須重新取得 SourceFreezeReady 並重新核准停寫。'}elseif($sourceResumeRequired){'來源停寫狀態或恢復材料未能完整核對；先完成 SourceResume 或人工修復核對，不會自動恢復或續跑。'}elseif($sourceResumed){'已核對來源恢復結果；重新備份會建立全新的輸出嘗試，並重新要求獨立 FreezeReady 與明確停寫授權。'}elseif($sourceResumeAvailable){'來源已停寫且完整凍結材料可核對；可明確續作目前備份，或另行核准 SourceResume。'}elseif($freezeRequired -and $missingEvidence.Count){'所選範圍需要來源停寫；先核對影響並取得責任人、證據與獨立 SourceFreezeReady 材料。'}elseif($attempt){'此未完成嘗試已凍結交付格式；續作會沿用同一格式與容量。'}else{'交付格式依目前精靈模式預設；StartBackup 會重新驗證核准、來源盤點與材料。'}
    if($null -ne $planRef -and $planRef.Plan.PSObject.Properties['Assistive'] -and $planRef.Plan.Assistive.PSObject.Properties['ContractVersion'] -and $planRef.Plan.Assistive.ContractVersion -eq 2){$snapshotReferenceText=[string]$planRef.Plan.Assistive.DiscoveryAuthority.SourceSnapshotReference.Reference;if(-not [IO.File]::Exists((Join-Path (Join-Path $Workspace 'pairs') $snapshotReferenceText.Replace('/','\')))){$startReason=$startReason+' 注意：離線完整備份缺少核准時的來源盤點快照；請把 Manager 交付的 <計畫檔名>.source-snapshot.json 附件放在原核准計畫檔旁後重新匯入計畫。'}}
    $actions=@((New-WsmWizardRuntimeAction 'StartBackup' $startAvailable $startReason $startDefaults $missingEvidence),(Get-WsmWizardIndependentCopyAction $availability))
    if($sourceResumeRequired -or $sourceResumeAvailable){$resumeDefaults=@{PlanPath=[string]$planRef.Path;ExpectedHash=[string]$planRef.SHA256;SourceStateDirectory=(Join-Path $Workspace 'pairs')};$resumeMissing=@('Owner','OwnershipEvidence','Acknowledgement','ResumeExternalEvidencePath','ResumeExternalEvidenceHash');if($resumeRoute.sourceAttemptPath -and $resumeRoute.sourceAttemptHash){$resumeDefaults.SourceAttemptPath=$resumeRoute.sourceAttemptPath;$resumeDefaults.SourceAttemptHash=$resumeRoute.sourceAttemptHash}else{$resumeMissing=@('SourceAttemptPath','SourceAttemptHash')+$resumeMissing};$resumeActionAvailable=([bool]$resumeRoute.sourceAttemptPath -and [bool]$resumeRoute.sourceAttemptHash -and -not $resumeRoute.manualReviewRequired);$resumeReason=if($resumeRoute.manualReviewRequired){[string]$resumeRoute.manualReviewReason}elseif($sourceResumeRequired){'來源恢復材料需明確人工核對；不會自動恢復或續跑。'}else{'來源恢復需要明確責任人、證據與單一寫入者條件；不會自動送出。'};$actions+=New-WsmWizardRuntimeAction 'SourceResume' $resumeActionAvailable $resumeReason $resumeDefaults $resumeMissing}
    [pscustomobject][ordered]@{status=$status;plan=[pscustomobject]@{path=[string]$planRef.Path;hash=[string]$planRef.SHA256;inventoryHash=[string]$planRef.Plan.InventoryHash;inventoryRevision=[int]$planRef.Plan.InventoryRevision;AuthoritativeApproval=$false};backupPreview=$preview;backupResult=$availability;delivery=[pscustomobject]@{mode=$selectedMode;volumeBytes=$volume;frozen=$frozen;attemptId=$(if($attempt){[string]$attempt.AttemptId}else{''})};sourceFreeze=[pscustomobject]@{required=$freezeRequired;missingEvidence=@($missingEvidence);resumeRequired=$sourceResumeRequired;resumeAvailable=$sourceResumeAvailable;resumeRoute=$resumeRoute;impact=$preview;sourceResumed=$sourceResumed;manualReviewRequired=[bool]($resumeRoute -and $resumeRoute.manualReviewRequired);manualReviewReason=$(if($resumeRoute){[string]$resumeRoute.manualReviewReason}else{''})};actions=$actions;canStartBackup=$canStartBackupReady;offlineReadiness=(Get-WsmWizardOfflineReadiness $availability)}
}

# 項目選擇器的類型篩選標籤（只做顯示分類；還原語意由 adapter 決定）。
function Get-WsmWizardItemTypeLabel([string]$Adapter,[string]$Kind) {
    switch -CaseSensitive ($Adapter) {
        'IISSite' {return '網站'}
        'IISPool' {return '應用程式集區'}
        'IISSection' {return 'IIS 設定區段'}
        'IISLocation' {return 'IIS 設定位置'}
        'ScheduledTask' {return '排程工作'}
        'FileScope' {return '檔案範圍'}
        'Service' {return '服務'}
        'WindowsFeature' {return 'Windows 功能'}
        'Certificate' {return '憑證'}
        'LocalUser' {return '本機使用者'}
        'LocalGroup' {return '本機群組'}
        'ManualWorkflow' {return '人工處理'}
    }
    if($Adapter){return $Adapter}
    if($Kind){return $Kind}
    '其他'
}

# 每個項目的檔數與位元組，只取自已驗證封裝的 artifacts.jsonl（Read-WsmArtifactLines 會先核對索引雜湊，被改過就丟例外）。
# 目錄列只是結構，不算檔案也不算位元組。沒有已驗證封裝（尚未匯入）時回傳 $null，呼叫端標示「數量尚未取得」。
function Get-WsmWizardTargetArtifactTotals($PackageRecord) {
    if(-not $PackageRecord -or -not $PackageRecord.PSObject.Properties['Package'] -or -not $PackageRecord.Package){return $null}
    $verified=$PackageRecord.Package
    if(-not $verified.PSObject.Properties['Root'] -or -not $verified.PSObject.Properties['Manifest'] -or -not $verified.Manifest.PSObject.Properties['ArtifactsHash']){return $null}
    $root=[string]$verified.Root;$expected=[string]$verified.Manifest.ArtifactsHash
    if(-not $root -or -not $expected){return $null}
    $totals=@{}
    Read-WsmArtifactLines (Join-Path $root 'artifacts.jsonl') $expected | ForEach-Object {
        $id=[string]$_.ItemId
        if(-not $totals.ContainsKey($id)){$totals[$id]=[pscustomobject]@{Files=[long]0;Bytes=[long]0}}
        if(-not [bool]$_.Directory){
            $totals[$id].Files++
            if($_.PSObject.Properties['Data'] -and $_.Data -and $_.Data.PSObject.Properties['Bytes']){$totals[$id].Bytes+=[long]$_.Data.Bytes}
        }
    }
    $totals
}

# 項目選擇器的「可還原」判定：核准（計畫內 Include）∩ 有可用 payload ∩ 目標可放置。
# 判定一律呼叫預覽使用的同一份函式（Get-WsmAssistiveFileScopeRestoreGap／Get-WsmAssistiveVolumeCapacityResults），這裡只負責把預覽動作對應成代碼與中文原因。
# 全程唯讀：不建目錄、不寫檔、不取鎖。沒有已驗證封裝（尚未匯入）時回傳空表，不假裝知道 payload 與目標狀況。
function ConvertTo-WsmWizardRestorableCode([string]$PreviewAction) {
    switch -CaseSensitive ($PreviewAction) {
        'PrepareSameLocation' {return 'MissingVolume'}
        'AddTargetCapacity' {return 'InsufficientCapacity'}
    }
    $PreviewAction
}
function Get-WsmWizardRestorableReason([string]$Code,$Gap) {
    switch -CaseSensitive ($Code) {
        'NoPayload' {return '封裝裡沒有這個項目的備份內容（缺少 artifact），工具不會還原。'}
        'MissingVolume' {return [string]$Gap.Reason}
        'MountPointNotSupported' {return [string]$Gap.Reason}
        'PermissionDenied' {return [string]$Gap.Reason}
        'InsufficientCapacity' {
            if($Gap.PSObject.Properties['Root'] -and $Gap.PSObject.Properties['RequiredBytes'] -and [long]$Gap.AvailableBytes -ge 0){
                $needMib=[math]::Ceiling([double]$Gap.RequiredBytes/1MB);$freeMib=[math]::Floor([double]$Gap.AvailableBytes/1MB)
                return ('目標磁碟 '+[string]$Gap.Root+' 空間不足：同一磁碟上全部可還原項目合計需要約 '+$needMib+' MiB（含 256 MiB 緩衝），目前可用約 '+$freeMib+' MiB。')
            }
            return [string]$Gap.Reason
        }
        'BlockedLocation' {return ('不符合原位置還原的條件，工具不會還原：'+[string]$Gap.Reason)}
        'BlockedConflict' {return ('目標位置已有衝突，需要人工處理：'+[string]$Gap.Reason)}
        'NeedsReconciliation' {return '需先對帳：上次還原這個項目時中途失敗，沒有留下完整的檔案擁有紀錄，工具不會直接寫入。請先執行「修復」（HTML 動作「修復」〈Repair〉；CLI 目標本機選單「11 修復 checkpoint」，命令 Repair-WsmOperation）：已寫入且與備份相同的檔案會補登為工具擁有，不存在的檔案維持未寫入；內容不同、有重新分析點或被目錄佔用的檔案不會被動，仍須人工處理後才能重試。'}
        'Blocked' {return '無法安全驗證目標路徑，工具不會還原。'}
    }
    ('目標位置目前無法還原（'+$Code+'）：'+[string]$Gap.Reason)
}
function Get-WsmWizardTargetRestorableGaps($Context,$PackageRecord,$State) {
    $gaps=@{}
    if(-not $PackageRecord -or -not $PackageRecord.PSObject.Properties['Package'] -or -not $PackageRecord.Package){return $gaps}
    $verified=$PackageRecord.Package
    foreach($required in @('Root','Manifest','Plan')){if(-not $verified.PSObject.Properties[$required] -or -not $verified.$required){return $gaps}}
    if(-not $verified.Manifest.PSObject.Properties['ArtifactsHash']){return $gaps}
    $cv2=[bool]($verified.Plan.PSObject.Properties['Assistive'] -and $verified.Plan.Assistive -and $verified.Plan.Assistive.PSObject.Properties['ContractVersion'] -and [int]$verified.Plan.Assistive.ContractVersion -eq 2)
    $gapState=$State;if(-not $gapState -or -not $gapState.PSObject.Properties['Items']){$gapState=[pscustomobject]@{Items=@()}}
    # 只評估會由預覽判定的 FileScope：外部處理與舊格式非 C 傳輸由預覽另有流程，這裡不替它們下結論。
    $candidates=@($Context.Plan.Items|Where-Object {
        $_.Decision -ceq 'Include' -and $_.MigrationSpec -and [string]$_.MigrationSpec.Adapter -ceq 'FileScope' -and
        -not ($_.MigrationSpec.PSObject.Properties['TransferChannel'] -and [string]$_.MigrationSpec.TransferChannel -ceq 'External') -and
        -not ($_.MigrationSpec.PSObject.Properties['TransferChannel'] -and [string]$_.MigrationSpec.TransferChannel -ceq 'NonC' -and -not $cv2)
    })
    if(-not $candidates.Count){return $gaps}
    $rowsById=@{};foreach($candidate in $candidates){$rowsById[[string]$candidate.ItemId]=New-Object 'System.Collections.Generic.List[object]'}
    Read-WsmArtifactLines (Join-Path ([string]$verified.Root) 'artifacts.jsonl') ([string]$verified.Manifest.ArtifactsHash) | ForEach-Object {$rowId=[string]$_.ItemId;if($rowsById.ContainsKey($rowId)){$rowsById[$rowId].Add($_)}}
    $capacityCandidates=New-Object 'System.Collections.Generic.List[object]'
    foreach($candidate in $candidates){
        $candidateId=[string]$candidate.ItemId
        try{$gap=Get-WsmAssistiveFileScopeRestoreGap $candidate $verified $gapState $cv2 @($rowsById[$candidateId].ToArray())}
        catch{$gap=[pscustomobject]@{Action='Blocked';Status='Blocked';Reason='Target path could not be verified safely.';Capacity=$null}}
        if([string]$gap.Status -cne 'Ready'){$code=ConvertTo-WsmWizardRestorableCode ([string]$gap.Action);$gaps[$candidateId]=[pscustomobject]@{Code=$code;Reason=(Get-WsmWizardRestorableReason $code $gap)};continue}
        if($gap.Capacity){$capacityCandidates.Add($gap.Capacity)}
    }
    # 容量依卷加總（17.62）：以「全部可還原項目都選取」為前提；某卷不夠時，該卷上會寫入的項目全部標 InsufficientCapacity。
    foreach($volumeResult in @(Get-WsmAssistiveVolumeCapacityResults $capacityCandidates.ToArray())){
        $volumeCode=ConvertTo-WsmWizardRestorableCode ([string]$volumeResult.Action)
        $gaps[[string]$volumeResult.ItemId]=[pscustomobject]@{Code=$volumeCode;Reason=(Get-WsmWizardRestorableReason $volumeCode $volumeResult)}
    }
    $gaps
}

function Get-WsmWizardTargetItemOptions($Context,$Package,$State,$Decision=$null) {
    $manifestHash=if($Package){[string]$Package.ManifestHash}else{''}
    $rows=@{};if($Package -and $manifestHash -and $State -and $State.PSObject.Properties['Items']){foreach($row in @($State.Items)){if($row -and $row.PSObject.Properties['ItemId']){$rows[[string]$row.ItemId]=$row}}}
    # An item with an unresolved native intent or a continuation result of NeedsReconciliation / BlockedByUnknownDependency is never counted as restored; neither is one deferred (credential deferral / retry limit) or refused (CredentialRejected).
    $unproven=@{};if($Package -and $State){if($State.PSObject.Properties['PendingOperations']){foreach($op in @($State.PendingOperations)){if($op -and $op.PSObject.Properties['ItemId']){$unproven[[string]$op.ItemId]=$true}}};if($State.PSObject.Properties['RestoreAttempt'] -and $State.RestoreAttempt -and $State.RestoreAttempt.PSObject.Properties['ItemResults']){foreach($itemResult in @($State.RestoreAttempt.ItemResults)){if($itemResult -and $itemResult.PSObject.Properties['Status'] -and [string]$itemResult.Status -cin @('NeedsReconciliation','BlockedByUnknownDependency','Deferred','CredentialRejected')){$unproven[[string]$itemResult.ItemId]=$true}}}}
    $included=@($Context.Plan.Items|Where-Object Decision -CEQ Include)
    # 必要相依（Type=Mandatory）只認同樣在還原範圍內的項目；RequiredBy 是同一份關係的反向。
    $includedIds=@{};foreach($entry in $included){$includedIds[[string]$entry.ItemId]=$true}
    $dependencyMap=@{};$requiredByMap=@{}
    foreach($entry in $included){
        $entryId=[string]$entry.ItemId;$dependsOnList=New-Object 'System.Collections.Generic.List[string]'
        if($entry.PSObject.Properties['Dependencies']){
            foreach($dependency in @($entry.Dependencies)){
                if(-not $dependency -or -not $dependency.PSObject.Properties['Type'] -or [string]$dependency.Type -cne 'Mandatory'){continue}
                $dependencyId=[string]$dependency.ItemId
                if(-not $dependencyId -or $dependencyId -ceq $entryId -or -not $includedIds.ContainsKey($dependencyId) -or $dependsOnList.Contains($dependencyId)){continue}
                $dependsOnList.Add($dependencyId)
                if(-not $requiredByMap.ContainsKey($dependencyId)){$requiredByMap[$dependencyId]=New-Object 'System.Collections.Generic.List[string]'}
                $requiredByMap[$dependencyId].Add($entryId)
            }
        }
        $dependencyMap[$entryId]=$dependsOnList
    }
    $artifactTotals=Get-WsmWizardTargetArtifactTotals $Package
    $restorableGaps=Get-WsmWizardTargetRestorableGaps $Context $Package $State
    # 最後一份決策收據的選取；沒有收據時 preselected 為 $null（前端改用預設全選未還原項）。
    $chosen=$null
    if($Decision -and $Decision.PSObject.Properties['Receipt'] -and $Decision.Receipt -and $Decision.Receipt.PSObject.Properties['SelectedItemIds']){$chosen=@{};foreach($chosenId in @($Decision.Receipt.SelectedItemIds)){$chosen[[string]$chosenId]=$true}}
    @($included|ForEach-Object {
        $spec=$_.MigrationSpec;$adapter=if($spec){[string]$spec.Adapter}else{''}
        $group=if($adapter -cin @('IISSite','IISPool','IISSection','IISLocation')){'Web'}elseif($adapter -ceq 'ScheduledTask'){'Tasks'}elseif($adapter -ceq 'FileScope'){'Data'}else{'Settings'}
        $restorable=$true;$reason='';$restorableCode=''
        if(-not $spec -or $adapter -ceq 'ManualWorkflow'){$restorable=$false;$restorableCode='ManualWorkflow';$reason='需要人工處理，工具不會還原。'}elseif($adapter -ceq 'FileScope' -and $spec.PSObject.Properties['TransferChannel'] -and [string]$spec.TransferChannel -ceq 'External'){$restorable=$false;$restorableCode='External';$reason='標示為外部處理，未包含在備份中。'}
        if($restorable -and $restorableGaps.ContainsKey([string]$_.ItemId)){$restorable=$false;$restorableCode=[string]$restorableGaps[[string]$_.ItemId].Code;$reason=[string]$restorableGaps[[string]$_.ItemId].Reason}
        $row=$rows[[string]$_.ItemId];$restored=[bool]($row -and -not $unproven.ContainsKey([string]$_.ItemId) -and [string]$row.Status -ceq 'Succeeded' -and $row.PSObject.Properties['AppliedManifestHash'] -and [string]$row.AppliedManifestHash -ceq $manifestHash)
        $optionId=[string]$_.ItemId;$fileCount=[long]0;$byteCount=[long]0
        if($null -ne $artifactTotals -and $artifactTotals.ContainsKey($optionId)){$fileCount=[long]$artifactTotals[$optionId].Files;$byteCount=[long]$artifactTotals[$optionId].Bytes}
        $dependsOn=@();if($dependencyMap.ContainsKey($optionId)){$dependsOn=@($dependencyMap[$optionId].ToArray())}
        $neededBy=@();if($requiredByMap.ContainsKey($optionId)){$neededBy=@($requiredByMap[$optionId].ToArray())}
        $preselected=$null;if($null -ne $chosen){$preselected=[bool]$chosen.ContainsKey($optionId)}
        # P10：沿用既有檔（內容與備份相同但來歷不明）的個數；回復時這些檔案不會被刪除或覆寫。只讀狀態列的逐檔 Ownership。
        $adoptedExistingCount=0;if($row -and $row.PSObject.Properties['OwnedFiles']){$adoptedExistingCount=@(@($row.OwnedFiles)|Where-Object {Test-WsmAssistiveOwnedFileAdopted $_}).Count}
        [pscustomobject]@{value=$optionId;label=[string]$_.Name;kind=[string]$_.Kind;adapter=$adapter;group=$group;typeLabel=(Get-WsmWizardItemTypeLabel $adapter ([string]$_.Kind));restorable=$restorable;restorableReason=$reason;restorableCode=$restorableCode;restored=$restored;fileCount=$fileCount;bytes=$byteCount;countsAvailable=[bool]($null -ne $artifactTotals);dependencies=$dependsOn;requiredBy=$neededBy;preselected=$preselected;adoptedExistingCount=$adoptedExistingCount;adoptedExistingNote=$(if($adoptedExistingCount){Get-WsmAssistiveAdoptedExistingNote}else{''})}
    })
}

function Get-WsmWizardRuntimeTargetPendingRestore([string]$Workspace,[string]$PairId,[object[]]$Jobs) {
    # The newest TargetRestore parent of this pair decides: WaitingForInput / Interrupted are not a finished or startable restore.
    $latest=$null;$latestTime=''
    foreach($job in @($Jobs)){
        if(-not $job -or [string](Get-WsmWizardTargetJobField $job action Action) -cne 'TargetRestore' -or [string](Get-WsmWizardTargetJobField $job role Role) -cne 'Target' -or [string](Get-WsmWizardTargetJobField $job pairId PairId) -cne $PairId){continue}
        try{if([IO.Path]::GetFullPath([string](Get-WsmWizardTargetJobField $job workspace Workspace)) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
        $time=[string](Get-WsmWizardTargetJobField $job startedUtc StartedUtc);if(-not $time){$time=[string](Get-WsmWizardTargetJobField $job createdUtc CreatedUtc)}
        if($null -eq $latest -or [string]::CompareOrdinal($time,$latestTime) -ge 0){$latest=$job;$latestTime=$time}
    }
    if(-not $latest){return $null}
    $status=[string](Get-WsmWizardTargetJobField $latest status Status)
    if($status -ceq 'WaitingForInput'){return [pscustomobject]@{Status='WaitingForInput';Summary='等待帳密輸入：還原尚未完成，請在還原畫面輸入或延後帳密後續作；目前不可重新開始還原。';ParentOperationId=[string](Get-WsmWizardTargetJobField $latest jobId JobId)}}
    if($status -ceq 'Interrupted'){return [pscustomobject]@{Status='Interrupted';Summary='還原中斷，可檢視恢復預覽後續作。';ParentOperationId=[string](Get-WsmWizardTargetJobField $latest jobId JobId)}}
    $null
}
function Get-WsmWizardRuntimeTarget([string]$Workspace,[string]$PairId,$Profile,[object[]]$Jobs) {
    $actions=New-Object 'System.Collections.Generic.List[object]'
    $defaults=@{Workspace=[IO.Path]::GetFullPath($Workspace);PairId=$PairId}
    $result=[ordered]@{status='NeedsApprovedPlan';plan=$null;package=$null;inventory=$null;comparison=$null;softwareCheck=$null;decision=$null;restorePreview=$null;restoreResult=$null;retry=$null;statusSummary='';itemOptions=@();mechanicalValidation=[pscustomobject]@{available=$false;status='Locked';result=$null};businessAcceptance=[pscustomobject]@{available=$false;status='NotAccepted';gates=$null};activation=[pscustomobject]@{available=$false;status='Locked';acknowledgementRequired=$true};actions=@();noAutoResume=$true;noAutoActivation=$true;issues=@()}
    $received=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $Profile
    if(-not $received){$actions.Add((New-WsmWizardRuntimeAction 'ImportApprovedPlan' $true '先取得與目前 Target 身分綁定的核准計畫及獨立預期 hash。' @{Workspace=$Workspace;Role='Target'} @('Path','ExpectedHash')));$result.actions=@($actions.ToArray());return [pscustomobject]$result}
    if([int]$received.Plan.SchemaVersion -ne 3){$result.status='UseExistingWorkflow';$result.issues=@('此核准計畫使用原核心格式，請由既有流程檢查材料與續作；不將原格式重新解讀為 schema-3 還原授權。');$result.actions=@();return [pscustomobject]$result}
    $context=Assert-WsmWizardTargetRole $Workspace $PairId
    $result.plan=[pscustomobject]@{path=$received.Path;hash=$received.SHA256;generation=$null;AuthoritativeApproval=$false}
    $result.itemOptions=@(Get-WsmWizardTargetItemOptions $context $null $null)
    $actions.Add((New-WsmWizardRuntimeAction 'TargetZipImport' $true '接收 ZIP；內容 hash 與獨立可信管道的預期值分開核對。' $defaults @('TransportPath','ExpectedHash')))
    $actions.Add((New-WsmWizardRuntimeAction 'TargetDirectoryImport' $true '接收資料夾交接摘要及內容；不改全域格式設定。' $defaults @('SummaryPath','ExpectedSummaryHash','SourceDirectory')))
    $candidateJobs=@($Jobs|Where-Object {$_ -and [string](Get-WsmWizardTargetJobField $_ action Action) -in @('TargetZipImport','TargetDirectoryImport','ImportPackageZip','DirectoryImport') -and [string](Get-WsmWizardTargetJobField $_ role Role) -ceq 'Target' -and [string](Get-WsmWizardTargetJobField $_ pairId PairId) -ceq $PairId -and [string](Get-WsmWizardTargetJobField $_ status Status) -ceq 'Succeeded'})
    $package=$null
    if($candidateJobs.Count){try{$package=Get-WsmWizardTargetPackage $Workspace $PairId $context $Jobs}catch{$result.status='MaterialUnavailable';$result.issues=@('已登錄的交接材料無法核驗；保留紀錄並重新取得目前材料，不使用舊世代代替。');$result.actions=@($actions.ToArray());return [pscustomobject]$result}}
    if(-not $package){$result.status='NeedsPackage';$result.actions=@($actions.ToArray());return [pscustomobject]$result}
    $result.package=$package;$result.plan.generation=[long]$package.Package.Manifest.Generation
    $itemState=$null;try{$itemPaths=Get-WsmOperationPaths (Join-Path $Profile.WorkRoot 'pairs') $PairId;if([IO.File]::Exists($itemPaths.State)){$itemState=Get-WsmOperationState $itemPaths $package.Package}}catch{$itemState=$null}
    # 重新開啟頁面時，選擇器以最後一份決策收據的選取為準預選（讀不到就用預設）。
    $lastDecision=$null;try{$lastDecision=Get-WsmWizardTargetDecisionRecord $Workspace $PairId ([string]$received.SHA256)}catch{$lastDecision=$null}
    $result.itemOptions=@(Get-WsmWizardTargetItemOptions $context $package $itemState $lastDecision)
    $inventoryDefaults=@{OutputDirectory=(Join-Path $Workspace ('hosts\'+$Profile.Fingerprint+'\inventory'));DeepDiscovery=$true;IncludeSoftwareCatalog=$true}
    $actions.Add((New-WsmWizardRuntimeAction 'Inventory' $true '重新觀測本機 Target 現況，不更新封存的來源事實。' $inventoryDefaults @()))
    $snapshot=$null
    try{$snapshot=Get-WsmWizardTargetSnapshotForRuntime $Workspace $context $Jobs}catch{$result.status='NeedsTargetInventory';$result.issues=@('需要與本機 Target 綁定、仍新鮮且含原生軟體觀測的盤點。');$result.actions=@($actions.ToArray());return [pscustomobject]$result}
    $result.inventory=$snapshot
    $actions.Add((New-WsmWizardRuntimeAction 'ExportTargetHandoff' $true '將目前 Target 盤點交回 Manager 更新比較；不覆蓋來源盤點。' @{WorkRoot=$Workspace;InventoryPath=$snapshot.Path;OutputDirectory=(Join-Path $Workspace ('workspace-control\target-handoffs\'+[Guid]::NewGuid().ToString('N')))} @()))
    $actions.Add((New-WsmWizardRuntimeAction 'ComparisonImport' $true '核對 Manager 比較材料的獨立預期 hash；比較必須綁定這份最新 Target 盤點。' $defaults @('Path','ExpectedHash')))
    $comparisonRecord=Get-WsmWizardTargetComparisonRecord $Workspace $PairId $received.SHA256
    $needsComparison=(-not $comparisonRecord -or $comparisonRecord.Document.TargetSnapshotHash -ine $snapshot.SHA256 -or $comparisonRecord.Document.SourceSnapshotHash -ine $context.Plan.Assistive.SourceSnapshotHash -or [int]$comparisonRecord.Document.SelectionRevision -ne [int]$context.Plan.Assistive.SourceSelectionsVersion)
    $actions.Add((New-WsmWizardRuntimeAction 'TargetLocalComparison' $needsComparison $(if($needsComparison){'沒有舊 Manager 時，可在本機產生軟體比較。'}else{'已有符合目前 Target 盤點的比較材料；不需要重新產生。'}) $defaults @()))
    if($needsComparison){$result.status='NeedsComparison';$result.actions=@($actions.ToArray());return [pscustomobject]$result}
    $comparison=$comparisonRecord.Comparison;$result.comparison=$comparisonRecord;$result.softwareCheck=Get-WsmWizardTargetSoftwareCheck $comparisonRecord
    $actions.Add((New-WsmWizardRuntimeAction 'CreateTargetDecisionReceipt' $true '明確選擇已核准項目與現在還原／待補裝；責任人和理由由操作者提供。' $defaults @('Decision','Owner','Reason','SelectedItemIds')))
    $decisionRecord=Get-WsmWizardTargetDecisionRecord $Workspace $PairId $received.SHA256
    if(-not $decisionRecord -or $decisionRecord.Receipt.TargetSnapshotHash -ine $snapshot.SHA256 -or $decisionRecord.Receipt.ManifestHash -ine $package.ManifestHash -or [long]$decisionRecord.Receipt.Generation -ne [long]$package.Package.Manifest.Generation -or $decisionRecord.Receipt.ComparisonHash -ine (Get-WsmHashText ($comparison|ConvertTo-Json -Depth 100 -Compress))){$result.status='NeedsTargetDecision';$result.actions=@($actions.ToArray());return [pscustomobject]$result}
    $result.decision=$decisionRecord
    $actions.Add((New-WsmWizardRuntimeAction 'TargetRestorePreview' $true '重新核驗這份決策的逐項相依與還原範圍；不寫入 Target 業務資源。' $defaults @()))
    $result.restorePreview=Get-WsmWizardRuntimeTargetPreviewJobResult $Workspace $PairId $received $package $snapshot $comparisonRecord $decisionRecord $Jobs
    $result.restoreResult=Get-WsmWizardRuntimeTargetRestoreResult $Workspace $PairId $received $package $snapshot $decisionRecord $Jobs
    if(-not $result.restoreResult){$result.restoreResult=Get-WsmWizardRuntimeFailedRestore $Workspace $PairId $package $snapshot $decisionRecord $Jobs}
    $stage=if($result.restoreResult){[string]$result.restoreResult.stage}else{''}
    $postActivation=$false
    if($result.restoreResult){$postPaths=Get-WsmOperationPaths (Join-Path $Profile.WorkRoot 'pairs') $PairId;$postState=Get-WsmOperationState $postPaths $package.Package;$postActivation=Test-WsmWizardRuntimeActivatedBinding $Workspace $PairId $received $package $postState $Jobs}
    $validationPhase=if($postActivation){'Final'}else{'Staged'}
    $pendingRestore=$null;if(-not $stage){$pendingRestore=Get-WsmWizardRuntimeTargetPendingRestore $Workspace $PairId $Jobs}
    $result.status=if($stage){$stage}elseif($decisionRecord.Receipt.Decision -ceq 'WaitForInstall'){'WaitingForInstall'}elseif($result.restorePreview -and ([bool]$result.restorePreview.CanRestoreIndependentItems)){'ReadyForRestore'}elseif($result.restorePreview){'ReviewRequired'}else{'ReadyForRestorePreview'}
    if($pendingRestore){$result.status=$pendingRestore.Status;$result.statusSummary=$pendingRestore.Summary}
    # P8：部分完成時的「重試失敗項目」。候選只由最近一次母作業、它綁定的最新決策收據與目前的可還原判定算出（唯讀）；
    # 按鈕只是一個動作入口：後端在建立收據時會自己重新計算候選，不信任這裡的清單。
    $retryPending=$pendingRestore;if($stage){$retryPending=Get-WsmWizardRuntimeTargetPendingRestore $Workspace $PairId $Jobs}
    $retryCandidates=$null;try{$retryCandidates=Get-WsmWizardTargetRetryCandidatesCore -PackageRecord $package -State $itemState -DecisionRecord $decisionRecord -ItemOptions @($result.itemOptions) -PendingRestore $retryPending}catch{$retryCandidates=$null}
    $result.retry=[pscustomobject][ordered]@{visible=$false;eligible=$false;reasonCode=$(if($retryCandidates){[string]$retryCandidates.ReasonCode}else{'Unavailable'});reason='';candidateItemIds=@();candidateCount=0}
    if($retryCandidates -and $retryCandidates.Visible -and -not $postActivation -and [string]$result.status -notin @('WaitingForInput','Interrupted','WaitingForInstall')){
        $retryShort=([string]$retryCandidates.SourceReceiptHash).Substring(0,12)
        $result.retry=[pscustomobject][ordered]@{visible=$true;eligible=[bool]$retryCandidates.Eligible;reasonCode=[string]$retryCandidates.ReasonCode;reason=[string]$retryCandidates.Reason;candidateItemIds=@($retryCandidates.CandidateItemIds);candidateCount=@($retryCandidates.CandidateItemIds).Count;succeededCount=@($retryCandidates.SucceededItemIds).Count;notSucceededCount=@($retryCandidates.NotSucceededItemIds).Count;excluded=@($retryCandidates.Excluded|ForEach-Object {[pscustomobject][ordered]@{itemId=[string]$_.ItemId;name=[string]$_.Name;code=[string]$_.Code;reason=[string]$_.Reason;lastStatus=[string]$_.LastStatus}});sourceAttemptId=[string]$retryCandidates.SourceAttemptId;sourceReceiptHash=[string]$retryCandidates.SourceReceiptHash;sourceReceiptShort=$retryShort;sourceStage=[string]$retryCandidates.SourceStage;defaultOwner=[string]$retryCandidates.SourceOwner;defaultReason=[string]$retryCandidates.SuggestedReason}
        $retryDefaults=@{Workspace=[IO.Path]::GetFullPath($Workspace);PairId=$PairId;Decision='RestoreNow';SelectedItemIds=[string[]]@($retryCandidates.CandidateItemIds);RetryOfReceiptHash=[string]$retryCandidates.SourceReceiptHash}
        $retryActionReason=if($retryCandidates.Eligible){'依上次部分完成的結果自動產生只含失敗項目的新選擇紀錄；責任人與理由由操作者確認，建立後不會自動開始還原。'}else{[string]$retryCandidates.Reason}
        $actions.Add((New-WsmWizardRuntimeAction 'TargetRetryFailedItems' ([bool]$retryCandidates.Eligible) $retryActionReason $retryDefaults @('Owner','Reason')))
    }
    if(-not $stage -and -not $pendingRestore -and $result.restorePreview -and $decisionRecord.Receipt.Decision -ceq 'RestoreNow' -and ([bool]$result.restorePreview.CanRestoreIndependentItems)){$actions.Add((New-WsmWizardRuntimeAction 'TargetRestore' $true '確認此明確預覽後還原；寫入時會重新核對目前 Target 軟體與全部綁定。' @{Workspace=$Workspace;PairId=$PairId;PreviewHash=[string]$result.restorePreview.PreviewHash} @()))}
    if($postActivation){$result.status='PostCutoverValidationRequired';$result.activation.status='Activated'}
    if($stage -in @('Succeeded','Partial','RebootRequired')){
        $result.mechanicalValidation=[pscustomobject]@{available=$true;status='NotRun';result=$null}
        $actions.Add((New-WsmWizardRuntimeAction 'TargetValidation' $true '機械驗證目前已還原世代；部分結果仍逐項保留，不代表业务或啟用通過。' @{Workspace=$Workspace;PairId=$PairId;Phase=$validationPhase} @()))
        $paths=Get-WsmOperationPaths (Join-Path $Workspace 'pairs') $PairId;$validationPath=[IO.Path]::GetFullPath((Join-Path $paths.Root ('validation-'+$validationPhase+'.json')))
        $validationJobs=@($Jobs|Where-Object {$_ -and [string](Get-WsmWizardTargetJobField $_ action Action) -ceq 'TargetValidation' -and [string](Get-WsmWizardTargetJobField $_ role Role) -ceq 'Target' -and [string](Get-WsmWizardTargetJobField $_ pairId PairId) -ceq $PairId -and [string](Get-WsmWizardTargetJobField $_ status Status) -in @('Succeeded','ReviewRequired')})
        if([IO.File]::Exists($validationPath) -and $validationJobs.Count){
            try{
                Assert-WsmNoReparse $validationPath
                $validation=Read-WsmJson $validationPath
                $validationHash=(Get-FileHash -LiteralPath $validationPath -Algorithm SHA256).Hash.ToLowerInvariant()
                $stateDirectory=Join-Path $Profile.WorkRoot 'pairs';$operationPaths=Get-WsmOperationPaths $stateDirectory $PairId;$operationState=Get-WsmOperationState $operationPaths $package.Package
                $attempt=$operationState.RestoreAttempt
                if(-not $attempt -or [string]$attempt.OperationId -cne [string]$result.restoreResult.attemptId -or [string]$attempt.DecisionReceiptHash -ine [string]$decisionRecord.SHA256 -or [string]$attempt.TargetSnapshotHash -ine [string]$snapshot.SHA256 -or ([string]$operationState.Stage -notin @('Succeeded','Partial','RebootRequired') -and -not $postActivation)){throw 'Current restore attempt no longer matches the restore result, decision receipt and Target snapshot.'}
                $journalRoot=[IO.Path]::GetFullPath((Join-Path $operationPaths.Root 'restore-journals')).TrimEnd('\')+'\'
                $accepted=$false
                foreach($job in $validationJobs){
                    try{if([IO.Path]::GetFullPath([string](Get-WsmWizardTargetJobField $job workspace Workspace)) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
                    foreach($output in @((Get-WsmWizardTargetJobField $job outputs Outputs))){
                        if(-not $output){continue}
                        try{
                            $outputPath=[IO.Path]::GetFullPath([string]$output.Path);$outputJournalPath=[IO.Path]::GetFullPath([string]$output.JournalPath)
                            if($outputPath -ine $validationPath -or [string]$output.SHA256 -inotmatch '^[a-fA-F0-9]{64}$' -or [string]$output.SHA256 -ine $validationHash -or [string]$output.PairId -cne $PairId -or [string]$output.PlanHash -ine [string]$received.SHA256 -or [string]$output.ManifestHash -ine [string]$package.ManifestHash -or [long]$output.Generation -ne [long]$package.Package.Manifest.Generation -or [string]$output.RestoreAttemptId -cne [string]$attempt.OperationId -or [string]$output.DecisionReceiptHash -ine [string]$decisionRecord.SHA256 -or [string]$output.TargetSnapshotHash -ine [string]$snapshot.SHA256 -or [string]$output.Phase -cne $validationPhase -or -not $outputJournalPath.StartsWith($journalRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($outputJournalPath).TrimEnd('\') -ine $journalRoot.TrimEnd('\') -or [IO.Path]::GetFileName($outputJournalPath) -cne ([string]$output.JournalHash+'.jsonl') -or [string]$output.JournalHash -notmatch '^[a-fA-F0-9]{64}$' -or -not [IO.File]::Exists($outputJournalPath) -or (Get-FileHash -LiteralPath $outputJournalPath -Algorithm SHA256).Hash -ine [string]$output.JournalHash){continue}
                            Assert-WsmNoReparse $outputJournalPath
                            if([string]$job.status -cne [string]$output.Status -or [string]$output.Status -notin @('Succeeded','ReviewRequired')){continue}
                            if([string]$validation.Kind -cne 'ValidationResult' -or [string]$validation.PairId -cne $PairId -or [string]$validation.ManifestHash -ine [string]$package.ManifestHash -or [long]$validation.Generation -ne [long]$package.Package.Manifest.Generation -or [string]$validation.Phase -cne $validationPhase -or [bool]$validation.Passed -ne [bool]$output.Passed){continue}
                            $accepted=$true;break
                        }catch{continue}
                    }
                    if($accepted){break}
                }
                if(-not $accepted){throw 'Validation artifact has no exact formal job/output binding to the current pair, received plan, package generation and journal.'}
                $result.mechanicalValidation.result=$validation
                $result.mechanicalValidation.status=if($validation.Passed){'Succeeded'}else{'ReviewRequired'}
                if($validation.Passed){
                    $result.businessAcceptance.available=$true
                    # Opening the separately gated activation form is not activation; the writer rechecks cutover gates.
                    $result.activation.available=(-not $postActivation)
                    $actions.Add((New-WsmWizardRuntimeAction 'TargetAcceptance' $true '列出獨立接受條件與缺口；不自動建立業務接受證據。' $defaults @()))
                }
                $acceptance=Get-WsmWizardTargetAcceptanceRecord $Workspace $PairId $context $package $snapshot $decisionRecord $Jobs
                if($acceptance){
                    $result.businessAcceptance.gates=$acceptance.Record.Gates
                    $result.businessAcceptance.status=[string]$acceptance.Output.Status
                }
            }catch{$result.issues+=@('已保存的驗證證據不符合目前世代或缺少精確工作記錄綁定。')}
        }
    }
    if($postActivation){$result.businessAcceptance.available=$true;if(-not @($actions.ToArray()|Where-Object id -CEQ 'TargetAcceptance').Count){$actions.Add((New-WsmWizardRuntimeAction 'TargetAcceptance' $true '明確重查啟用後的接受條件；不代簽業務證據。' $defaults @()))};$postAcceptance=Get-WsmWizardTargetAcceptanceRecord $Workspace $PairId $context $package $snapshot $decisionRecord $Jobs;if($postAcceptance){$result.businessAcceptance.gates=$postAcceptance.Record.Gates;$result.businessAcceptance.status=[string]$postAcceptance.Output.Status}}
    if($result.activation.available){$result.activation.status='SeparateCutoverGate';$actions.Add((New-WsmWizardRuntimeAction 'TargetActivation' $true '只有另外核對 CutoverPlan 與精確確認才可啟用。' $defaults @('CutoverPlanPath','CutoverPlanHash','Acknowledgement')))}
    $result.actions=@($actions.ToArray());[pscustomobject]$result
}
function Get-WsmWizardRuntimeProjection {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role,[object[]]$Jobs=@())
    Assert-WsmId $PairId
    $profile=Read-WsmOutputProfile ([IO.Path]::GetFullPath($Workspace))
    if(-not $profile -or $profile.Role -cne $Role){throw 'Runtime projection role does not match the enrolled workspace.'}
    $contracts=Get-WsmWizardRuntimeActionContracts
    $runtime=if($Role -ceq 'Source'){Get-WsmWizardRuntimeSource $Workspace $PairId $profile $Jobs}else{Get-WsmWizardRuntimeTarget $Workspace $PairId $profile $Jobs}
    [pscustomobject][ordered]@{Kind='WizardRuntimeProjection';Workspace=[IO.Path]::GetFullPath($Workspace);PairId=$PairId;Role=$Role;status=[string]$runtime.status;actions=@($runtime.actions);publicActions=@($runtime.actions|ForEach-Object {$_.id});actionContracts=$contracts;runtime=$runtime;AuthoritativeApproval=$false;ProductionVerified=$false}
}
