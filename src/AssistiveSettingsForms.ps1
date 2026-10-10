function Get-WsmAssistiveFormDecisionPath([string]$Workspace,[string]$PairId,[int]$Revision,[string]$Kind) {
    Assert-WsmId $PairId
    $root=[IO.Path]::GetFullPath($Workspace);Assert-WsmNoReparse $root
    $assistive=Join-Path $root 'assistive';if(-not [IO.Directory]::Exists($assistive)){[void][IO.Directory]::CreateDirectory($assistive);Protect-WsmDirectory $assistive};Assert-WsmNoReparse $assistive
    $forms=Join-Path $assistive 'forms';if(-not [IO.Directory]::Exists($forms)){[void][IO.Directory]::CreateDirectory($forms);Protect-WsmDirectory $forms};Assert-WsmNoReparse $forms
    $path=Join-Path $forms ($Kind+'-'+$PairId+'-r'+$Revision+'-'+[Guid]::NewGuid().ToString('N')+'.json')
    if([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)){throw 'Generated decision output collision; retry.'}
    $path
}

function Export-WsmAssistiveWindowsSettingsPreview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SourceInventoryPath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$SourceInventoryHash,[Parameter(Mandatory)][string]$TargetInventoryPath,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$TargetInventoryHash,[Parameter(Mandatory)][bool]$ReviewWindowsSettings,[string]$OutputPath='')
    Assert-WsmId $PairId;foreach($path in @($SourceInventoryPath,$TargetInventoryPath)){Assert-WsmNoReparse ([IO.Path]::GetFullPath($path))}
    $catalog=Get-WsmCatalog $Workspace $PairId;$preview=Get-WsmWindowsSettingsReviewWorkspacePreview -Workspace $Workspace -PairId $PairId -SourceInventoryPath $SourceInventoryPath -SourceInventoryHash $SourceInventoryHash -TargetInventoryPath $TargetInventoryPath -TargetInventoryHash $TargetInventoryHash -ReviewWindowsSettings:$ReviewWindowsSettings
    $generatedPath=Get-WsmAssistiveFormDecisionPath $Workspace $PairId ([int]$catalog.DecisionRevision) 'windows-settings-preview';$formsRoot=[IO.Path]::GetDirectoryName($generatedPath).TrimEnd('\')+'\';$fullOutput=$generatedPath;if($OutputPath){$fullOutput=[IO.Path]::GetFullPath($OutputPath)}
    if(-not $fullOutput.StartsWith($formsRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($fullOutput) -cne '.json'){throw 'Windows settings preview output must be a new JSON file inside the protected workspace forms directory.'}
    Assert-WsmNoReparse $fullOutput;if([IO.File]::Exists($fullOutput) -or [IO.Directory]::Exists($fullOutput)){throw 'Preview output already exists; choose a new revisioned path.'}
    Write-WsmJson $fullOutput $preview;$fileHash=(Get-FileHash -LiteralPath $fullOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    $safeRows=@(foreach($row in @($preview.Rows)){[pscustomobject][ordered]@{SettingId=[string]$row.SettingId;SourceItemId=[string]$row.SourceItemId;Category=[string]$row.Category;Kind=[string]$row.Kind;SettingName=[string]$row.SettingName;SourceValueHash=[string]$row.SourceValueHash;TargetValueHash=[string]$row.TargetValueHash;TargetDiff=[string]$row.TargetDiff;ControlSource=[string]$row.ControlSource;SupportedActions=@($row.SupportedActions);DefaultAction=[string]$row.DefaultAction;RequiredConsumerItemIds=@($row.RequiredConsumerItemIds);RequiredConsumerGateUnchanged=[bool]$row.RequiredConsumerGateUnchanged}})
    [pscustomobject][ordered]@{Kind='AssistiveWindowsSettingsPreviewOutput';Status='Previewed';PairId=$PairId;SourceInventoryPath=$SourceInventoryPath;SourceInventoryHash=$SourceInventoryHash;TargetInventoryPath=$TargetInventoryPath;TargetInventoryHash=$TargetInventoryHash;ExpectedRevision=[int]$catalog.DecisionRevision;PreviewPath=$fullOutput;PreviewFileHash=$fileHash;PreviewHash=[string]$preview.PreviewHash;ReviewWindowsSettings=$ReviewWindowsSettings;RowCount=$safeRows.Count;Rows=$safeRows;ReadinessProof=$false;AuthoritativeApproval=$false}
}

function Submit-WsmAssistiveWindowsSettingsReview {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$SourceInventoryPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$SourceInventoryHash,
        [Parameter(Mandatory)][string]$TargetInventoryPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$TargetInventoryHash,
        [Parameter(Mandatory)][string]$PreviewPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$PreviewHash,
        [Parameter(Mandatory)][int]$ExpectedRevision,
        [Parameter(Mandatory)][switch]$Ack,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Decisions
    )
    if(-not $Ack){throw 'Applying Windows settings requires -Ack after reviewing the bound preview.'}
    Assert-WsmId $PairId
    foreach($path in @($SourceInventoryPath,$TargetInventoryPath,$PreviewPath)){Assert-WsmNoReparse ([IO.Path]::GetFullPath($path))}
    $catalog=Get-WsmCatalog $Workspace $PairId;if($catalog.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; regenerate the Windows settings preview.'}
    $savedPreview=Read-WsmTrustedJson $PreviewPath $PreviewHash
    if($savedPreview.Kind -cne 'WindowsSettingsReviewPreview' -or -not $savedPreview.PSObject.Properties['ReviewWindowsSettings']){throw 'A trusted Windows settings review preview is required.'}
    if((Get-WsmWindowsSettingsPreviewHash $savedPreview) -ine [string]$savedPreview.PreviewHash){throw 'Saved Windows settings preview projection hash is invalid.'}
    $livePreview=Get-WsmWindowsSettingsReviewWorkspacePreview -Workspace $Workspace -PairId $PairId -SourceInventoryPath $SourceInventoryPath -SourceInventoryHash $SourceInventoryHash -TargetInventoryPath $TargetInventoryPath -TargetInventoryHash $TargetInventoryHash -ReviewWindowsSettings:([bool]$savedPreview.ReviewWindowsSettings)
    if($savedPreview.PreviewHash -ine $livePreview.PreviewHash){throw 'Source, target, or settings changed after the reviewed preview; refresh before submitting decisions.'}
    if($Decisions -isnot [array] -or $Decisions.Count -ne @($livePreview.Rows).Count){throw 'Exactly one typed decision is required for every current setting row.'}
    $rowsById=@{};foreach($row in @($livePreview.Rows)){if($rowsById.ContainsKey([string]$row.SettingId)){throw 'Current preview contains duplicate setting identities.'};$rowsById[[string]$row.SettingId]=$row}
    $decisionById=@{};foreach($decision in $Decisions){
        Assert-WsmFields $decision @('SettingId','Action','Owner','Reason','Evidence') @('SettingId','Action')
        $settingId=[string]$decision.SettingId;if($settingId -notmatch '^[a-f0-9]{64}$' -or -not $rowsById.ContainsKey($settingId) -or $decisionById.ContainsKey($settingId)){throw 'Decision set contains an unknown or duplicate setting identity.'}
        $row=$rowsById[$settingId];$action=[string]$decision.Action;if([string]::IsNullOrWhiteSpace($action) -or $row.SupportedActions -cnotcontains $action){throw ('Unsupported action for setting '+$settingId+'.')}
        foreach($field in @('Owner','Reason','Evidence')){if($decision.PSObject.Properties[$field]){Assert-WsmQualificationText ([string]$decision.$field) ('Decision.'+$field) 2048}}
        if($livePreview.ReviewWindowsSettings -and (-not $decision.PSObject.Properties['Owner'] -or -not $decision.PSObject.Properties['Reason'] -or -not $decision.PSObject.Properties['Evidence'] -or [string]::IsNullOrWhiteSpace([string]$decision.Owner) -or [string]::IsNullOrWhiteSpace([string]$decision.Reason) -or [string]::IsNullOrWhiteSpace([string]$decision.Evidence))){throw 'Reviewed settings decisions require owner, reason, and evidence.'}
        $decisionById[$settingId]=$decision
    }
    foreach($settingId in $rowsById.Keys){if(-not $decisionById.ContainsKey($settingId)){throw 'Decision set omitted a current setting row.'}}
    $typed=Get-WsmWindowsSettingsDecisionTemplate $livePreview
    foreach($row in @($livePreview.Rows)){$decision=$decisionById[[string]$row.SettingId];$bound=@($typed.Decisions | Where-Object SettingId -CEQ $row.SettingId);if($bound.Count -ne 1){throw 'Native decision template did not produce one exact setting row.'};$bound[0].Action=[string]$decision.Action;if($decision.PSObject.Properties['Owner']){$bound[0].Owner=[string]$decision.Owner};if($decision.PSObject.Properties['Reason']){$bound[0].Reason=[string]$decision.Reason};if($decision.PSObject.Properties['Evidence']){$bound[0].Evidence=[string]$decision.Evidence}}
    $decisionPath=Get-WsmAssistiveFormDecisionPath $Workspace $PairId $ExpectedRevision 'windows-settings-review'
    Write-WsmJson $decisionPath $typed;$decisionHash=(Get-FileHash -LiteralPath $decisionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    try {
        $applied=Apply-WsmWindowsSettingsReview -Workspace $Workspace -PairId $PairId -SourceInventoryPath $SourceInventoryPath -SourceInventoryHash $SourceInventoryHash -TargetInventoryPath $TargetInventoryPath -TargetInventoryHash $TargetInventoryHash -PreviewPath $PreviewPath -PreviewHash $PreviewHash -DecisionsPath $decisionPath -DecisionsHash $decisionHash -ExpectedRevision $ExpectedRevision -Ack
        [pscustomobject][ordered]@{Status='Applied';Applied=[bool]$applied.Applied;PairId=$PairId;ExpectedRevision=$ExpectedRevision;DecisionRevision=[int]$applied.DecisionRevision;PreviewHash=[string]$applied.PreviewHash;DecisionCount=$Decisions.Count;GeneratedDecisionsPath=[IO.Path]::GetFullPath($decisionPath);GeneratedDecisionsHash=$decisionHash;ReadinessProof=$false;AuthoritativeApproval=$false}
    } catch { [pscustomobject][ordered]@{Status='Rejected';Applied=$false;PairId=$PairId;ExpectedRevision=$ExpectedRevision;PreviewHash=[string]$livePreview.PreviewHash;DecisionCount=$Decisions.Count;GeneratedDecisionsPath=[IO.Path]::GetFullPath($decisionPath);GeneratedDecisionsHash=$decisionHash;FailureCode='CoreApplyRejected';ReadinessProof=$false;AuthoritativeApproval=$false} }
}

function Submit-WsmAssistiveGeneralHostDispositions {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][switch]$Ack,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Decisions)
    if(-not $Ack){throw 'Applying GeneralHost dispositions requires -Ack after reviewing the current disposition preview.'}
    Assert-WsmId $PairId;$catalog=Get-WsmCatalog $Workspace $PairId;if($catalog.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; refresh GeneralHost disposition preview.'}
    $normalized=New-Object 'System.Collections.Generic.List[object]';foreach($decision in $Decisions){Assert-WsmFields $decision @('ItemId','SoftwareId','ScopeDisposition','Owner','Reason','Evidence') @('ScopeDisposition','Owner','Reason','Evidence');foreach($field in @('Owner','Reason','Evidence','ScopeDisposition')){Assert-WsmQualificationText ([string]$decision.$field) ('Disposition.'+$field) 2048};$row=[ordered]@{ScopeDisposition=[string]$decision.ScopeDisposition;Owner=[string]$decision.Owner;Reason=[string]$decision.Reason;Evidence=[string]$decision.Evidence};if($decision.PSObject.Properties['ItemId']){$row.ItemId=[string]$decision.ItemId};if($decision.PSObject.Properties['SoftwareId']){$row.SoftwareId=[string]$decision.SoftwareId};$normalized.Add([pscustomobject]$row)}
    $path=Get-WsmAssistiveFormDecisionPath $Workspace $PairId $ExpectedRevision 'generalhost-dispositions';Write-WsmJson $path ([pscustomobject]@{Dispositions=$normalized.ToArray()});$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    try{$preview=Get-WsmGeneralHostDispositionPreview $Workspace $PairId $path $hash $ExpectedRevision;$previewHash=Get-WsmGeneralHostPreviewHash $preview Disposition;$updated=Set-WsmGeneralHostDispositions $Workspace $PairId $path $hash $ExpectedRevision $previewHash;[pscustomobject][ordered]@{Status='Applied';PairId=$PairId;DecisionRevision=[int]$updated.DecisionRevision;DecisionCount=$preview.Rows.Count;GeneratedDecisionsPath=[IO.Path]::GetFullPath($path);GeneratedDecisionsHash=$hash;ReadinessProof=$false;AuthoritativeApproval=$false}}catch{if([IO.File]::Exists($path)){[IO.File]::Delete($path)};throw}
}

function Submit-WsmAssistiveGeneralHostRequirements {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][switch]$Ack,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Requirements)
    if(-not $Ack){throw 'Applying GeneralHost requirements requires -Ack after reviewing the current requirement preview.'}
    Assert-WsmId $PairId;$catalog=Get-WsmCatalog $Workspace $PairId;if($catalog.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; refresh GeneralHost requirement preview.'}
    $normalized=New-Object 'System.Collections.Generic.List[object]';$seen=@{};foreach($requirement in $Requirements){$allowed=@('RequirementId','Type','ProviderSoftwareId','ProviderItemId','ExternalId','ConsumerItemIds','Certainty','RequiredPhase','ExpectedVersion','Architecture','Context','Owner','SourceProof','Decision','DecisionReason','DecisionEvidence');Assert-WsmFields $requirement $allowed $allowed;if([string]$requirement.RequirementId -cne (Get-WsmGeneralHostRequirementId $requirement) -or $seen.ContainsKey([string]$requirement.RequirementId)){throw 'Requirement form has an invalid or duplicate stable requirement identity.'};$seen[[string]$requirement.RequirementId]=$true;$normalized.Add($requirement)}
    foreach($existing in @($catalog.GeneralHost.Requirements)){if(-not $seen.ContainsKey([string]$existing.RequirementId)){throw 'Requirement form cannot silently remove an existing obligation.'}}
    $path=Get-WsmAssistiveFormDecisionPath $Workspace $PairId $ExpectedRevision 'generalhost-requirements';Write-WsmJson $path ([pscustomobject]@{Requirements=$normalized.ToArray()});$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    try{$preview=Get-WsmGeneralHostRequirementPreview $Workspace $PairId $path $hash $ExpectedRevision;$previewHash=Get-WsmGeneralHostPreviewHash $preview Requirement;$updated=Set-WsmGeneralHostRequirements $Workspace $PairId $path $hash $ExpectedRevision $previewHash;[pscustomobject][ordered]@{Status='Applied';PairId=$PairId;DecisionRevision=[int]$updated.DecisionRevision;RequirementCount=$preview.Requirements.Count;GeneratedRequirementsPath=[IO.Path]::GetFullPath($path);GeneratedRequirementsHash=$hash;ReadinessProof=$false;AuthoritativeApproval=$false}}catch{if([IO.File]::Exists($path)){[IO.File]::Delete($path)};throw}
}

function Get-WsmAssistiveGeneralHostRequirementReview {
 [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId)
 $catalog=Get-WsmCatalog $Workspace $PairId
 if(-not $catalog.PSObject.Properties['GeneralHost']){throw 'GeneralHost requirements are unavailable.'}
 $reviewHash=Get-WsmHashText ($catalog.GeneralHost.Requirements|ConvertTo-Json -Depth 100 -Compress)
 $rows=@(foreach($r in @($catalog.GeneralHost.Requirements)){[pscustomobject]@{RequirementId=$r.RequirementId;Type=$r.Type;ProviderSoftwareId=$r.ProviderSoftwareId;ProviderItemId=$r.ProviderItemId;ExternalId=$r.ExternalId;ConsumerItemIds=@($r.ConsumerItemIds);Certainty=$r.Certainty;RequiredPhase=$r.RequiredPhase;ExpectedVersion=$r.ExpectedVersion;Architecture=$r.Architecture;ContextHash=(Get-WsmGeneralHostContextHash $r.Context);Decision=$r.Decision;Owner='';DecisionReason='';DecisionEvidence=''}})
 [pscustomobject]@{Kind='AssistiveRequirementReview';Status='Previewed';PairId=$PairId;ExpectedRevision=[int]$catalog.DecisionRevision;ReviewHash=$reviewHash;Rows=$rows;ReadinessProof=$false;AuthoritativeApproval=$false}
}

function Submit-WsmAssistiveGeneralHostRequirementDecisions {
 [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$ReviewHash,[Parameter(Mandatory)][switch]$Ack,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Decisions)
 if(-not $Ack){throw 'Requirement decisions require explicit owner confirmation.'}
 $catalog=Get-WsmCatalog $Workspace $PairId
 if($catalog.DecisionRevision -ne $ExpectedRevision -or (Get-WsmHashText ($catalog.GeneralHost.Requirements|ConvertTo-Json -Depth 100 -Compress)) -cne $ReviewHash){throw 'Requirement review changed; obtain a new preview.'}
 $requirements=@($catalog.GeneralHost.Requirements);if($Decisions.Count -ne $requirements.Count){throw 'Review every current requirement exactly once.'}
 $byId=@{};foreach($d in $Decisions){Assert-WsmFields $d @('RequirementId','Decision','Owner','DecisionReason','DecisionEvidence') @('RequirementId','Decision','Owner','DecisionReason','DecisionEvidence');if($byId.ContainsKey([string]$d.RequirementId)){throw 'Duplicate requirement decision.'};foreach($field in @('RequirementId','Decision','Owner','DecisionReason','DecisionEvidence')){Assert-WsmQualificationText ([string]$d.$field) $field 2048};$byId[[string]$d.RequirementId]=$d}
 $complete=@(foreach($r in $requirements){if(-not $byId.ContainsKey([string]$r.RequirementId)){throw 'Missing or unknown current requirement decision.'};$copy=ConvertFrom-WsmJson ($r|ConvertTo-Json -Depth 100 -Compress);$d=$byId[[string]$r.RequirementId];$copy.Decision=[string]$d.Decision;$copy.Owner=[string]$d.Owner;$copy.DecisionReason=[string]$d.DecisionReason;$copy.DecisionEvidence=[string]$d.DecisionEvidence;$copy})
 Submit-WsmAssistiveGeneralHostRequirements -Workspace $Workspace -PairId $PairId -ExpectedRevision $ExpectedRevision -Ack -Requirements $complete
}