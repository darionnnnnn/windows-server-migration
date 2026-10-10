function Get-WsmAssistiveTargetPlan($Package,$Decision) {
    Assert-WsmAssistiveReceiptComparisonBinding $Package $Decision.Receipt | Out-Null
    $plan=ConvertFrom-WsmJson ($Package.Plan | ConvertTo-Json -Depth 100)
    if(-not $plan.PSObject.Properties['GeneralHost']){return $plan}
    $plan.GeneralHost.Requirements=@($plan.GeneralHost.Requirements | Where-Object {@($_.ConsumerItemIds | Where-Object {$Decision.SelectedItemIds -ccontains $_}).Count -gt 0})
    $rows=@{};foreach($row in @($Decision.Receipt.Comparison.Rows)){if($row.SoftwareId){if($rows.ContainsKey([string]$row.SoftwareId)){throw 'Ambiguous target software expectation.'};$rows[[string]$row.SoftwareId]=$row}}
    foreach($requirement in @($plan.GeneralHost.Requirements)){
        if(-not $requirement.ProviderSoftwareId -or ($requirement.Decision -ceq 'NotNeeded' -and $requirement.Certainty -ceq 'Candidate')){continue}
        if(-not $rows.ContainsKey([string]$requirement.ProviderSoftwareId)){continue}
        $row=$rows[[string]$requirement.ProviderSoftwareId]
        if([string]::IsNullOrWhiteSpace([string]$row.ChosenVersion)){continue}
        $requirement.ExpectedVersion=[string]$row.ChosenVersion
        $requirement.Context=[pscustomobject][ordered]@{OriginalContext=$requirement.Context;AssistiveTargetBinding=[pscustomobject][ordered]@{DecisionReceiptHash=[string]$Decision.ReceiptHash;TargetSnapshotHash=[string]$Decision.Receipt.TargetSnapshotHash;ComparisonHash=[string]$Decision.Receipt.ComparisonHash}}
        $requirement.RequirementId=Get-WsmGeneralHostRequirementId $requirement
    }
    # Source facts and the sealed plan are immutable. Only this ephemeral target
    # expectation is passed to the existing phase-evidence validator.
    $knownIds=@($plan.GeneralHost.Requirements.RequirementId);$plan.GeneralHost.EvidenceReceipts=@($plan.GeneralHost.EvidenceReceipts | Where-Object {@($_.RequirementIds | Where-Object {$_ -cnotin $knownIds}).Count -eq 0})
    $plan
}

function Get-WsmAssistiveTargetGeneralHostIssues($Package,$Decision,[string]$Phase,[object[]]$GeneralHostEvidence=@()) {
    if(-not $Package.Plan.PSObject.Properties['GeneralHost']){return @()}
    $targetPlan=Get-WsmAssistiveTargetPlan $Package $Decision
    @(Get-WsmGeneralHostIssues $targetPlan $Phase $Package.Manifest.Target.Fingerprint '' $Package.Manifest.PlanHash $GeneralHostEvidence)
}

function Get-WsmAssistiveStateGeneralHostIssues($Package,$State,[string]$Phase,[object[]]$GeneralHostEvidence=@()) {
    if(-not $Package.Plan.PSObject.Properties['GeneralHost']){return @()}
    if(-not $State.PSObject.Properties['RestoreAttempt'] -or -not $State.RestoreAttempt.PSObject.Properties['DecisionReceiptPath'] -or -not $State.RestoreAttempt.PSObject.Properties['TargetSnapshotPath']){throw 'Current target preparation requires durable receipt and target snapshot references.'}
    $attempt=$State.RestoreAttempt
    if($attempt.ManifestHash -ine $Package.SHA256 -or [long]$attempt.Generation -ne [long]$Package.Manifest.Generation){throw 'Target preparation decision belongs to another applied generation.'}
    $decision=Get-WsmAssistiveRestoreDecision $Package $Package.SHA256 $attempt.DecisionReceiptPath $attempt.DecisionReceiptHash $attempt.TargetSnapshotPath
    Assert-WsmAssistiveReceiptFresh $Package $decision | Out-Null
    @(Get-WsmAssistiveTargetGeneralHostIssues $Package $decision $Phase $GeneralHostEvidence)
}

function Get-WsmAssistivePreparationPreview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$AssistiveDecisionReceiptPath,[Parameter(Mandatory)][string]$AssistiveDecisionReceiptHash,[Parameter(Mandatory)][string]$AssistiveTargetSnapshotPath)
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash
    Assert-WsmMigrationHost (Get-WsmMachineIdentity) $package.Manifest.Target.Fingerprint
    $decision=Get-WsmAssistiveRestoreDecision $package $ExpectedHash $AssistiveDecisionReceiptPath $AssistiveDecisionReceiptHash $AssistiveTargetSnapshotPath
    Assert-WsmAssistiveReceiptFresh $package $decision | Out-Null
    $plan=Get-WsmAssistiveTargetPlan $package $decision
    $rows=@();if($plan.PSObject.Properties['GeneralHost']){$rows=@(foreach($r in @($plan.GeneralHost.Requirements)){[pscustomobject]@{RequirementId=[string]$r.RequirementId;ProviderSoftwareId=[string]$r.ProviderSoftwareId;ExpectedVersion=[string]$r.ExpectedVersion;Architecture=[string]$r.Architecture;RequiredPhase=[string]$r.RequiredPhase;Decision=[string]$r.Decision;Certainty=[string]$r.Certainty;ConsumerItemIds=@($r.ConsumerItemIds);ContextHash=(Get-WsmGeneralHostContextHash $r.Context)}})}
    [pscustomobject]@{Kind='AssistivePreparationPreview';Status='Previewed';PairId=$package.Manifest.PairId;ManifestHash=$ExpectedHash;DecisionReceiptHash=$decision.ReceiptHash;TargetSnapshotHash=$decision.Receipt.TargetSnapshotHash;Rows=$rows;ReadinessProof=$false}
}

function Export-WsmAssistivePreparationEvidence {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$AssistiveDecisionReceiptPath,[Parameter(Mandatory)][string]$AssistiveDecisionReceiptHash,[Parameter(Mandatory)][string]$AssistiveTargetSnapshotPath,[Parameter(Mandatory)][string[]]$RequirementIds,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$EvidencePath,[Parameter(Mandatory)][string]$EvidenceHash,[Parameter(Mandatory)][string]$ObservedUtc,[Parameter(Mandatory)][string]$ExpiresUtc,[Parameter(Mandatory)][string]$Workspace,[string]$OutputPath='',[Parameter(Mandatory)][switch]$AckContextReadback)
    if(-not $AckContextReadback){throw 'Owner confirmation of the exact required context readback is required.'}
    Assert-WsmQualificationText $Owner Owner
    $observed=ConvertTo-WsmQualificationUtc $ObservedUtc ObservedUtc;$expires=ConvertTo-WsmQualificationUtc $ExpiresUtc ExpiresUtc
    if($observed -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or $expires -le [DateTimeOffset]::UtcNow -or $expires -le $observed){throw 'Preparation evidence time window is invalid.'}
    Assert-WsmTrustedFile $EvidencePath $EvidenceHash
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $package.Manifest.Target.Fingerprint
    $decision=Get-WsmAssistiveRestoreDecision $package $ExpectedHash $AssistiveDecisionReceiptPath $AssistiveDecisionReceiptHash $AssistiveTargetSnapshotPath
    Assert-WsmAssistiveReceiptFresh $package $decision | Out-Null

    $plan=Get-WsmAssistiveTargetPlan $package $decision
    if(-not $plan.PSObject.Properties['GeneralHost']){throw 'This plan has no GeneralHost preparation requirements.'}
    if(-not $RequirementIds.Count -or @($RequirementIds | Select-Object -Unique).Count -ne $RequirementIds.Count){throw 'Unique current target requirement identities are required.'}
    $requirements=@($plan.GeneralHost.Requirements | Where-Object RequirementId -CIn $RequirementIds)
    if($requirements.Count -ne $RequirementIds.Count){throw 'Requirement identity is stale or outside this target decision.'}
    $consumerIds=@($requirements | ForEach-Object ConsumerItemIds | Where-Object {$decision.SelectedItemIds -ccontains $_} | Select-Object -Unique);if(-not $consumerIds.Count){throw 'Preparation evidence has no selected current consumer.'};if(@(Get-WsmAssistiveComparisonDependencyIssues $package $decision | Where-Object {$consumerIds -ccontains $_.ConsumerItemId}).Count){throw 'Chosen software is not observed for the requested selected consumers.'}
    $receipts=@(foreach($r in $requirements){
        if($r.Decision -cne 'Required'){throw 'Evidence cannot approve unresolved or unnecessary requirements.'}
        $kind='OwnerReadback';if($r.Type -ceq 'ExternalDependency'){$kind='ExternalOwner'}
        $receipt=[pscustomobject][ordered]@{SchemaVersion=1;ReceiptId='';PairId=$plan.PairId;SourceFingerprint=$plan.Source.Fingerprint;TargetFingerprint=$package.Manifest.Target.Fingerprint;InventoryHash=$plan.InventoryHash;ToolFingerprint=(Get-WsmToolFingerprint);Context=$r.Context;RequirementIds=@([string]$r.RequirementId);RequirementProjectionHash=(Get-WsmGeneralHostProjectionHash $plan @($r.ConsumerItemIds) @([string]$r.RequirementId) $r.RequiredPhase);Phase=$r.RequiredPhase;EvidenceKind=$kind;EvidencePathHash=$EvidenceHash.ToLowerInvariant();Owner=$Owner;ObservedUtc=$ObservedUtc;ExpiresUtc=$ExpiresUtc;PlanHash=$package.Manifest.PlanHash}
        $receipt.ReceiptId=Get-WsmHashText ($receipt | ConvertTo-Json -Depth 100 -Compress)
        Assert-WsmGeneralHostReceipt $receipt $plan -TargetFingerprint $package.Manifest.Target.Fingerprint -PlanHash $package.Manifest.PlanHash | Out-Null
        $receipt
    })
    $generated=Get-WsmAssistiveFormDecisionPath $Workspace $plan.PairId ([int]$package.Manifest.Generation) 'target-preparation-evidence';$formsRoot=[IO.Path]::GetDirectoryName($generated).TrimEnd('\')+'\';$full=$generated;if($OutputPath){$full=[IO.Path]::GetFullPath($OutputPath)};if(-not $full.StartsWith($formsRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Target evidence must remain in the protected workspace forms directory.'};Assert-WsmNoReparse $full;if([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)){throw 'Evidence output exists; choose a new revisioned path.'}

    Write-WsmJson $full ([pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='GeneralHostEvidenceSet';PairId=$plan.PairId;SourceFingerprint=$plan.Source.Fingerprint;Receipts=$receipts})
    $outputHash=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    Register-WsmAssistiveMaterialBatch -Workspace $Workspace -PairId $plan.PairId -Generation ([int]$package.Manifest.Generation) -ConsumerRefs $consumerIds -Materials @(
        [pscustomobject]@{Path=$full;SHA256=$outputHash;Kind='TargetPreparationReceipt'},
        [pscustomobject]@{Path=$EvidencePath;SHA256=$EvidenceHash;Kind='TargetPreparationOwnerEvidence'}
    ) | Out-Null
    [pscustomobject]@{Status='EvidenceRecorded';Path=$full;SHA256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant();ReceiptCount=$receipts.Count;ReadinessProof=$false;ProductionVerified=$false}
}
