# A conservative, explicit batch wrapper over the existing wizard preparation
# review form and Submit-WsmAssistiveSpecReview CAS path. This helper never
# creates approvals or modifies a sealed migration plan.
$script:WsmBulkPreparationBeforeCoreSaveHook=$null
$script:WsmBulkPreparationAfterCoreSaveHook=$null

function Get-WsmWizardBulkPreparationRoot([string]$Workspace,[string]$PairId) {
    Assert-WsmId $PairId
    $root=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-preparation-bulk') $PairId))
    $base=[IO.Path]::GetFullPath((Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-preparation-bulk')).TrimEnd('\')+'\'
    if(-not $root.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Bulk preparation storage escaped its workspace boundary.'}
    $root
}

function Get-WsmWizardBulkPreparationPreviewPath([string]$Workspace,[string]$PairId,[string]$PreviewId) {
    Assert-WsmId $PreviewId
    Join-Path (Join-Path (Get-WsmWizardBulkPreparationRoot $Workspace $PairId) 'previews') ($PreviewId.ToLowerInvariant()+'.json')
}

function Get-WsmWizardBulkPreparationOperationPath([string]$Workspace,[string]$PairId,[string]$OperationId) {
    Assert-WsmId $OperationId
    Join-Path (Join-Path (Get-WsmWizardBulkPreparationRoot $Workspace $PairId) 'operations') ($OperationId.ToLowerInvariant()+'.json')
}

function Get-WsmWizardBulkPreparationStableFormHash($Review) {
    $rows=@(foreach($field in @($Review.FormFields)){
        $provenance=$null
        if($field.provenance){$p=[ordered]@{};foreach($property in $field.provenance.PSObject.Properties){if($property.Name -cne 'reviewHash'){$p[$property.Name]=$property.Value}};$provenance=[pscustomobject]$p}
        [ordered]@{key=[string]$field.key;value=$field.value;required=[bool]$field.required;editable=[bool]$field.editable;type=[string]$field.type;options=@($field.options);origin=[string]$field.origin;provenance=$provenance}
    })
    Get-WsmHashText (ConvertTo-Json -InputObject $rows -Depth 40 -Compress)
}

function Get-WsmWizardBulkPreparationContext([string]$Workspace,$Catalog,[string]$PairId) {
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Bulk preparation requires the enrolled Manager workspace.'}
    if(-not $Catalog.PSObject.Properties['Assistive'] -or -not $Catalog.Assistive.SourceSnapshot -or [string]$Catalog.Assistive.SourceSnapshot.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'A current hash-bound Assistive source snapshot is required.'}
    $selection=Get-WsmAssistiveCurrentSelections $Catalog
    # Build the selected set without relying on nested Where-Object scoping.
    $selectionById=@{};foreach($row in @($selection.Items)){$selectionById[[string]$row.ItemId]=$row}
    $included=@(foreach($item in @($Catalog.Items)){if($item.Decision -ceq 'Include' -and $selectionById.ContainsKey([string]$item.ItemId) -and [bool]$selectionById[[string]$item.ItemId].Selected){[string]$item.ItemId}});$included=@($included|Sort-Object -Unique)
    $rows=[ordered]@{PairId=$PairId;ManagerHostId=[string]$profile.HostId;ManagerFingerprint=[string]$profile.Fingerprint;ToolFingerprint=[string](Get-WsmToolFingerprint);SourceHostId=[string]$Catalog.Source.HostId;SourceFingerprint=[string]$Catalog.Source.Fingerprint;InventoryHash=[string]$Catalog.InventoryHash;InventoryRevision=[int]$Catalog.InventoryRevision;SourceSnapshotHash=[string]$Catalog.Assistive.SourceSnapshot.SHA256;DecisionRevision=[int]$Catalog.DecisionRevision;AssistiveRevision=[int]$Catalog.Assistive.Revision;SelectionRevision=[int]$selection.Revision;SelectionHash=(Get-WsmHashText (ConvertTo-Json -InputObject @($selection.Items|Sort-Object ItemId|Select-Object ItemId,Selected,Reason) -Depth 20 -Compress));IncludedItemIds=$included}
    [pscustomobject]$rows
}

function Get-WsmWizardBulkPreparationStoredPreview([string]$Workspace,[string]$PairId,[string]$PreviewId,[string]$PreviewHash) {
    $path=Get-WsmWizardBulkPreparationPreviewPath $Workspace $PairId $PreviewId
    if(-not [IO.File]::Exists($path)){throw 'Bulk preparation preview is unavailable; create a new preview.'}
    Assert-WsmNoReparse $path
    $record=Read-WsmJson $path
    if($record.Kind -cne 'WizardBulkPreparationPreview' -or $record.PairId -cne $PairId -or $record.PreviewId -cne $PreviewId -or $record.PreviewHash -ine $PreviewHash){throw 'Bulk preparation preview identity or hash is invalid.'}
    $copy=ConvertFrom-WsmJson (ConvertTo-Json -InputObject $record -Depth 50 -Compress);$copy.PSObject.Properties.Remove('PreviewHash')
    if((Get-WsmHashText (ConvertTo-Json -InputObject $copy -Depth 50 -Compress)) -ine $PreviewHash){throw 'Bulk preparation preview bytes do not match the returned preview hash.'}
    $record
}

function Get-WsmWizardBulkPreparationReferences([string]$Workspace,[string]$PairId) {
    $catalog=Get-WsmCatalog $Workspace $PairId
    $context=Get-WsmWizardBulkPreparationContext $Workspace $catalog $PairId
    $expected=ConvertTo-Json -InputObject $context -Depth 50 -Compress
    $directory=Join-Path (Get-WsmWizardBulkPreparationRoot $Workspace $PairId) 'previews'
    if(-not [IO.Directory]::Exists($directory)){return @()}
    Assert-WsmNoReparse $directory
    $paths=@([IO.Directory]::GetFiles($directory,'*.json'))
    if($paths.Count -gt 256){throw 'Too many retained preparation previews; explicitly select and reconcile the current review.'}
    @(foreach($path in $paths){
        try{
            Assert-WsmNoReparse $path;if((Get-Item -LiteralPath $path).Length -gt 16777216){continue}
            $row=Read-WsmJson $path;Assert-WsmId ([string]$row.PreviewId)
            if([IO.Path]::GetFileNameWithoutExtension($path) -cne $row.PreviewId -or $row.PreviewHash -notmatch '^[a-fA-F0-9]{64}$'){continue}
            $verified=Get-WsmWizardBulkPreparationStoredPreview $Workspace $PairId ([string]$row.PreviewId) ([string]$row.PreviewHash)
            if((ConvertTo-Json -InputObject $verified.Context -Depth 50 -Compress) -cne $expected -or -not @($verified.CandidateItemIds).Count){continue}
            [pscustomobject]@{value=[string]$verified.PreviewId;label=('批次準備 · '+[string]$verified.CreatedUtc+' · '+@($verified.CandidateItemIds).Count+' 項');previewHash=[string]$verified.PreviewHash}
        }catch{continue}
    })
}

function Get-WsmWizardBulkPreparationEligibility($Review) {
    $deferred=New-Object 'System.Collections.Generic.List[object]'
    if([bool]$Review.ManualReviewRequired){$deferred.Add([pscustomobject]@{Field='';Reason='ManualReviewRequired'})}
    foreach($missing in @($Review.MissingTypedFields)){
        if([string]$missing -notin @('Owner','Evidence','BusinessChecks')){$deferred.Add([pscustomobject]@{Field=[string]$missing;Reason='MissingTypedField'})}
    }
    if($Review.PSObject.Properties['Adapter'] -and [string]$Review.Adapter -ceq 'FileScope'){
        $content=@($Review.FormFields|Where-Object key -CEQ 'ContentSelection');$files=@($Review.FormFields|Where-Object key -CEQ 'ConfigFiles')
        if($content.Count -eq 1 -and [string]$content[0].value -ceq 'ExactFiles' -and ($files.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$files[0].value))){$deferred.Add([pscustomobject]@{Field='ConfigFiles';Reason='ExactFilesRequiresReviewedWhitelist'})}
    }
    foreach($field in @($Review.FormFields)){
        $key=[string]$field.key
        if($key -ceq 'BusinessChecks'){continue}
        # Empty optional values and safe false values are intentional typed
        # states in the shared form. The core submit performs adapter-specific
        # checks; only a required blank or a separate manual/missing marker is
        # a bulk eligibility blocker.
        # S9: the same choice judgement as the preparation form and its save-time validation.
        if((Get-WsmWizardPreparationChoiceIssue ([string]$field.type) @($field.options) $field.value) -ceq 'OutsideOptions'){$deferred.Add([pscustomobject]@{Field=$key;Reason='AmbiguousChoiceOutsideOptions'});continue}
        if($field.editable -and $field.required -and $field.origin -ceq 'NeedsHumanDecision'){$deferred.Add([pscustomobject]@{Field=$key;Reason='RequiredHumanDecision'});continue}
        if($field.required -and ($null -eq $field.value -or ($field.value -is [string] -and [string]::IsNullOrWhiteSpace([string]$field.value)) -or ($field.value -is [array] -and -not $field.value.Count))){$deferred.Add([pscustomobject]@{Field=$key;Reason='RequiredValueUnavailable'})}
        if($key -ceq 'SecretRef' -and $field.required -and ([string]$field.value -notmatch '^[A-Za-z0-9_.-]{1,128}$')){$deferred.Add([pscustomobject]@{Field=$key;Reason='SecretReferenceRequired'})}
        if($key -match '^(?:Desired/)?ArtifactPath$' -and $field.required -and [string]::IsNullOrWhiteSpace([string]$field.value)){$deferred.Add([pscustomobject]@{Field=$key;Reason='PublicCertificateArtifactRequired'})}
        if($key -ceq 'Desired/HasPrivateKey' -and $field.value -is [bool] -and [bool]$field.value){$deferred.Add([pscustomobject]@{Field=$key;Reason='PrivateKeyMaterialRequiresManualReview'})}
    }
    @($deferred.ToArray() | Sort-Object Field,Reason -Unique)
}

function Get-WsmWizardBulkPreparationPreview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId)
    $catalog=Get-WsmCatalog $Workspace $PairId;$context=Get-WsmWizardBulkPreparationContext $Workspace $catalog $PairId
    if($catalog.Approval -and $catalog.Approval.PSObject.Properties['Kind'] -and $catalog.Approval.Kind -ceq 'MigrationPlan'){throw 'A sealed approved migration plan cannot be changed by bulk preparation.'}
    if(-not @($context.IncludedItemIds).Count){throw 'There are no currently included and selected items to preview.'}
    $items=New-Object 'System.Collections.Generic.List[object]';$deferred=New-Object 'System.Collections.Generic.List[object]';$candidateIds=New-Object 'System.Collections.Generic.List[string]';$skipped=New-Object 'System.Collections.Generic.List[string]'
    foreach($itemId in @($context.IncludedItemIds)){
        $item=@($catalog.Items|Where-Object ItemId -CEQ $itemId)[0]
        if($item.PSObject.Properties['MigrationSpec']){$skipped.Add([string]$itemId);continue}
        $review=Get-WsmWizardPreparationReview $Workspace $PairId $itemId
        $reasons=@(Get-WsmWizardBulkPreparationEligibility $review)
        $fieldRows=@(foreach($field in @($review.FormFields)){[pscustomobject][ordered]@{key=[string]$field.key;value=$field.value;required=[bool]$field.required;editable=[bool]$field.editable;type=[string]$field.type;options=@($field.options);origin=[string]$field.origin;provenance=$field.provenance}})
        $row=[pscustomobject][ordered]@{ItemId=[string]$itemId;ItemName=[string]$review.ItemName;Adapter=[string]$review.Adapter;ReviewHash=[string]$review.ReviewHash;SpecHash=[string]$review.SpecHash;SourceSnapshotHash=[string]$review.SourceSnapshotHash;DecisionRevision=[int]$review.DecisionRevision;AssistiveRevision=[int]$review.AssistiveRevision;SelectionRevision=[int]$review.SelectionRevision;StableFormHash=(Get-WsmWizardBulkPreparationStableFormHash $review);FormFields=$fieldRows;DeferredFields=$reasons}
        $items.Add($row)
        if($reasons.Count){foreach($reason in $reasons){$deferred.Add([pscustomobject]@{ItemId=[string]$itemId;Field=[string]$reason.Field;Reason=[string]$reason.Reason})}}else{$candidateIds.Add([string]$itemId)}
    }
    $previewId=[Guid]::NewGuid().ToString('D');$record=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardBulkPreparationPreview';PreviewId=$previewId;PairId=$PairId;CreatedUtc=(Get-WsmUtc);Context=$context;CandidateItemIds=@($candidateIds.ToArray());SkippedExistingSpecItemIds=@($skipped.ToArray());DeferredFields=@($deferred.ToArray());Items=@($items.ToArray());ReviewedSourceDefaultsRequired=(@($items.ToArray()|Where-Object {$_.ItemId -in @($candidateIds.ToArray())}|ForEach-Object {$_.FormFields}|Where-Object {$_.editable -and $_.origin -in @('ConservativeDefault','TrustedSourceInventory')}).Count -gt 0);AuthoritativeApproval=$false;SpecWrites=0}
    $record.PSObject.Properties.Remove('PreviewHash');$hash=Get-WsmHashText (ConvertTo-Json -InputObject $record -Depth 50 -Compress);$record|Add-Member NoteProperty PreviewHash $hash
    $path=Get-WsmWizardBulkPreparationPreviewPath $Workspace $PairId $previewId;$directory=Split-Path -Parent $path;if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory};Assert-WsmNoReparse $directory;Write-WsmJson $path $record
    [pscustomobject][ordered]@{Kind='WizardBulkPreparationPreview';Status=$(if($candidateIds.Count){'ReadyForExplicitBulkReview'}else{'NoEligibleItems'});PairId=$PairId;PreviewId=$previewId;PreviewHash=$hash;Context=$context;CandidateItemIds=@($candidateIds.ToArray());SkippedExistingSpecItemIds=@($skipped.ToArray());DeferredFields=@($deferred.ToArray());Items=@($items.ToArray());ReviewedSourceDefaultsRequired=[bool]$record.ReviewedSourceDefaultsRequired;AuthoritativeApproval=$false;SpecWrites=0}
}

function Get-WsmWizardBulkPreparationNormalizedAnswers($Review,[string[]]$BusinessChecks) {
    $answers=[ordered]@{}
    foreach($field in @($Review.FormFields)){
        if(-not $field.editable){continue}
        if($field.origin -in @('ConservativeDefault','TrustedSourceInventory')){$answers[[string]$field.key]=$field.value}
        if([string]$field.key -ceq 'BusinessChecks'){$answers[[string]$field.key]=(@($BusinessChecks|ForEach-Object {[string]$_.Trim()}|Where-Object {$_}) -join "`n")}
    }
    $answers
}

function Get-WsmWizardBulkPreparationCanonicalValue($Value,[string]$Type) {
    if($Type -ceq 'lines'){
        if($Value -is [array]){$lines=@($Value|ForEach-Object {[string]$_ -split '\r?\n'}|ForEach-Object {$_.Trim()}|Where-Object {$_})}
        else{$lines=@(([string]$Value -split '\r?\n')|ForEach-Object {$_.Trim()}|Where-Object {$_})}
        return ($lines -join "`n")
    }
    ConvertTo-Json -InputObject $Value -Depth 40 -Compress
}

function Get-WsmWizardBulkPreparationCommittedArtifact([string]$Workspace,[string]$PairId,[string]$ItemId,$Spec) {
    $directory=[IO.Path]::GetFullPath((Join-Path (Join-Path $Workspace 'assistive') 'review-forms'))
    if(-not [IO.Directory]::Exists($directory)){return $null}
    Assert-WsmNoReparse $directory
    $prefix=$directory.TrimEnd('\')+'\';$expected=ConvertTo-Json -InputObject $Spec -Depth 50 -Compress
    $artifactMatches=New-Object 'System.Collections.Generic.List[object]'
    $paths=@([IO.Directory]::GetFiles($directory,('spec-'+$PairId+'-'+$ItemId+'-*.json')))
    if($paths.Count -gt 256){throw 'Too many retained specification artifacts to prove a unique interrupted write.'}
    foreach($path in $paths){
        $full=[IO.Path]::GetFullPath($path)
        if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch ('^spec-'+[regex]::Escape($PairId)+'-'+[regex]::Escape($ItemId)+'-[a-fA-F0-9]{32}\.json$')){continue}
        Assert-WsmNoReparse $full
        if((Get-Item -LiteralPath $full).Length -gt 1048576){continue}
        try{$parsed=Read-WsmJson $full}catch{continue}
        if((ConvertTo-Json -InputObject $parsed -Depth 50 -Compress) -ceq $expected){$hash=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant();$artifactMatches.Add([pscustomobject]@{SpecPath=$full;SpecHash=$hash})}
    }
    if($artifactMatches.Count -ne 1){return $null}
    $artifactMatches[0]
}

function Test-WsmWizardBulkPreparationCommittedItem($Workspace,[string]$PairId,$PreviewItem,[string]$Owner,[string]$Evidence,[string[]]$BusinessChecks,$BoundContext,[int]$CompletedBefore) {
    $catalog=Get-WsmCatalog $Workspace $PairId;$rows=@($catalog.Items|Where-Object {[string]$_.ItemId -ceq [string]$PreviewItem.ItemId})
    if($rows.Count -ne 1 -or -not $rows[0].PSObject.Properties['MigrationSpec']){return $null}
    if([int]$catalog.DecisionRevision -ne ([int]$BoundContext.DecisionRevision+$CompletedBefore+1) -or [int]$catalog.Assistive.Revision -ne ([int]$BoundContext.AssistiveRevision+$CompletedBefore+1) -or [string]$catalog.Assistive.SourceSnapshot.SHA256 -ine [string]$BoundContext.SourceSnapshotHash){return $null}
    $spec=$rows[0].MigrationSpec;if([string]$spec.Owner -cne $Owner -or [string]$spec.Evidence -cne $Evidence){return $null}
    $review=Get-WsmWizardPreparationReview $Workspace $PairId ([string]$PreviewItem.ItemId)
    $expectedAnswers=[ordered]@{}
    foreach($field in @($PreviewItem.FormFields)){
        if($field.editable -and $field.origin -in @('ConservativeDefault','TrustedSourceInventory')){$expectedAnswers[[string]$field.key]=$field.value}
        if($field.editable -and [string]$field.key -ceq 'BusinessChecks'){$expectedAnswers[[string]$field.key]=(@($BusinessChecks|ForEach-Object {[string]$_.Trim()}|Where-Object {$_}) -join "`n")}
    }
    foreach($key in @($expectedAnswers.Keys)){
        $field=@($PreviewItem.FormFields|Where-Object key -CEQ $key)[0]
        if(-not $field.editable){return $null}
        $current=@($review.FormFields|Where-Object {[string]$_.key -ceq [string]$field.key});if($current.Count -ne 1){return $null}
        if((Get-WsmWizardBulkPreparationCanonicalValue $current[0].value ([string]$field.type)) -cne (Get-WsmWizardBulkPreparationCanonicalValue $expectedAnswers[$key] ([string]$field.type))){return $null}
    }
    $artifact=Get-WsmWizardBulkPreparationCommittedArtifact $Workspace $PairId ([string]$PreviewItem.ItemId) $spec
    if(-not $artifact){return $null}
    [pscustomobject]@{Spec=$spec;Catalog=$catalog;Review=$review;SpecPath=[string]$artifact.SpecPath;SpecHash=[string]$artifact.SpecHash}
}

function Save-WsmWizardBulkPreparationReviewCore {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$PreviewId,[Parameter(Mandatory)][string]$PreviewHash,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][string[]]$BusinessChecks,[Parameter(Mandatory)][string]$OperationId,[switch]$ReviewedSourceDefaults)
    Assert-WsmId $OperationId
    if([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Evidence)){throw 'An explicit non-empty Owner and Evidence are required for bulk review.'}
    if($Owner.Length -gt 8192 -or $Evidence.Length -gt 8192 -or @($BusinessChecks|Where-Object {$_ -and $_.Length -gt 8192}).Count){throw 'Bulk review text exceeds the bounded 8192 character limit.'}
    $preview=Get-WsmWizardBulkPreparationStoredPreview $Workspace $PairId $PreviewId $PreviewHash
    if(-not @($preview.CandidateItemIds).Count){throw 'This preview has no eligible items to save.'}
    if($preview.ReviewedSourceDefaultsRequired -and -not $ReviewedSourceDefaults){throw 'This preview contains trusted or conservative source defaults; explicitly confirm ReviewedSourceDefaults before adopting them.'}
    if(-not @($BusinessChecks|Where-Object {[string]::IsNullOrWhiteSpace($_) -eq $false}).Count){throw 'Explicit post-migration business checks are required; mechanical verification is not business acceptance.'}
    $inputHash=Get-WsmHashText (ConvertTo-Json -InputObject ([ordered]@{Owner=$Owner;Evidence=$Evidence;BusinessChecks=@($BusinessChecks);ReviewedSourceDefaults=[bool]$ReviewedSourceDefaults}) -Depth 20 -Compress)
    $opPath=Get-WsmWizardBulkPreparationOperationPath $Workspace $PairId $OperationId;$opDirectory=Split-Path -Parent $opPath
    if(-not [IO.Directory]::Exists($opDirectory)){[void][IO.Directory]::CreateDirectory($opDirectory);Protect-WsmDirectory $opDirectory};Assert-WsmNoReparse $opDirectory
    $operation=$null
    if([IO.File]::Exists($opPath)){
        Assert-WsmNoReparse $opPath;$operation=Read-WsmJson $opPath
        if($operation.Kind -cne 'WizardBulkPreparationOperation' -or $operation.PairId -cne $PairId -or $operation.OperationId -cne $OperationId -or $operation.PreviewId -cne $PreviewId -or $operation.PreviewHash -ine $PreviewHash -or $operation.InputHash -ine $inputHash){throw 'OperationId is already bound to different bulk preparation inputs.'}
        if($operation.Status -ceq 'Succeeded'){return $operation.Result}
    }else{
        $operation=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardBulkPreparationOperation';PairId=$PairId;OperationId=$OperationId;PreviewId=$PreviewId;PreviewHash=$PreviewHash;InputHash=$inputHash;Context=$preview.Context;CandidateItemIds=@($preview.CandidateItemIds);CompletedItemIds=@();CurrentItemId='';CurrentItemStatus='';ItemResults=@();Result=$null;Status='Running';CreatedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc);AuthoritativeApproval=$false}
        Write-WsmJson $opPath $operation
    }
    if($operation.CurrentItemId -and $operation.CurrentItemId -notin @($operation.CompletedItemIds)){
        $intentItem=@($preview.Items|Where-Object {[string]$_.ItemId -ceq [string]$operation.CurrentItemId})
        if($intentItem.Count -ne 1){throw 'Bulk operation intent references an item outside its bound preview.'}
        $recovered=Test-WsmWizardBulkPreparationCommittedItem $Workspace $PairId $intentItem[0] $Owner $Evidence $BusinessChecks $operation.Context @($operation.CompletedItemIds).Count
        if(-not $recovered){
            $catalogNow=Get-WsmCatalog $Workspace $PairId;$intentCatalogItem=@($catalogNow.Items|Where-Object {[string]$_.ItemId -ceq [string]$operation.CurrentItemId});$notWritten=($intentCatalogItem.Count -eq 1 -and -not $intentCatalogItem[0].PSObject.Properties['MigrationSpec'] -and [int]$catalogNow.DecisionRevision -eq ([int]$operation.Context.DecisionRevision+@($operation.CompletedItemIds).Count) -and [int]$catalogNow.Assistive.Revision -eq ([int]$operation.Context.AssistiveRevision+@($operation.CompletedItemIds).Count) -and [string]$catalogNow.Assistive.SourceSnapshot.SHA256 -ieq [string]$operation.Context.SourceSnapshotHash)
            if($notWritten){$operation.CurrentItemId='';$operation.CurrentItemStatus='NotWrittenProven';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation}
            else{$operation.CurrentItemStatus='Unknown';$operation.Status='Partial';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation;throw 'Bulk write status is Unknown: current item and catalog revisions do not prove either a committed match or that no write occurred. Inspect before retrying.'}
        } else {
        $operation.CompletedItemIds=@(@($operation.CompletedItemIds)+@([string]$operation.CurrentItemId)|Sort-Object -Unique);$operation.ItemResults=@(@($operation.ItemResults)+@([pscustomobject]@{ItemId=[string]$operation.CurrentItemId;Status='Saved';SpecPath=$recovered.SpecPath;SpecHash=$recovered.SpecHash;DecisionRevision=[int]$recovered.Catalog.DecisionRevision;ReplayedWrite=$true}));$operation.CurrentItemId='';$operation.CurrentItemStatus='';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation
        }
    }
    $catalog=Get-WsmCatalog $Workspace $PairId;$currentContext=Get-WsmWizardBulkPreparationContext $Workspace $catalog $PairId
    $expectedDecision=[int]$preview.Context.DecisionRevision+@($operation.CompletedItemIds).Count
    $expectedAssistive=[int]$preview.Context.AssistiveRevision+@($operation.CompletedItemIds).Count
    $contextStable=($currentContext.ManagerHostId -ceq $preview.Context.ManagerHostId -and $currentContext.ManagerFingerprint -ieq $preview.Context.ManagerFingerprint -and $currentContext.ToolFingerprint -ieq $preview.Context.ToolFingerprint -and $currentContext.SourceHostId -ceq $preview.Context.SourceHostId -and $currentContext.SourceFingerprint -ieq $preview.Context.SourceFingerprint -and $currentContext.InventoryHash -ieq $preview.Context.InventoryHash -and $currentContext.InventoryRevision -eq $preview.Context.InventoryRevision -and $currentContext.SourceSnapshotHash -ieq $preview.Context.SourceSnapshotHash -and $currentContext.AssistiveRevision -eq $expectedAssistive -and $currentContext.SelectionRevision -eq $preview.Context.SelectionRevision -and $currentContext.SelectionHash -ieq $preview.Context.SelectionHash -and (ConvertTo-Json -InputObject $currentContext.IncludedItemIds -Depth 10 -Compress) -ceq (ConvertTo-Json -InputObject $preview.Context.IncludedItemIds -Depth 10 -Compress) -and [int]$currentContext.DecisionRevision -eq $expectedDecision)
    if(-not $contextStable){$operation.Status='Partial';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation;throw 'Source inventory, included selection, tool, or review context changed after the bulk preview; refresh before applying.'}
    $allCurrent=@();foreach($itemId in @($preview.CandidateItemIds)){
        if($itemId -in @($operation.CompletedItemIds)){continue}
        $review=Get-WsmWizardPreparationReview $Workspace $PairId $itemId;$row=@($preview.Items|Where-Object ItemId -CEQ $itemId)[0]
        if($review.SpecHash -ine $row.SpecHash -or $review.SourceSnapshotHash -ine $row.SourceSnapshotHash -or (Get-WsmWizardBulkPreparationStableFormHash $review) -ine $row.StableFormHash){throw 'A candidate specification or default-field provenance changed after preview; no additional bulk saves were started.'}
        $allCurrent+=@([pscustomobject]@{ItemId=$itemId;Review=$review})
    }
    $initialDecision=[int]$preview.Context.DecisionRevision;$initialAssistive=[int]$preview.Context.AssistiveRevision;$initialSelection=[int]$preview.Context.SelectionRevision;$completed=@($operation.CompletedItemIds)
    foreach($candidate in $allCurrent){
        $itemId=[string]$candidate.ItemId;if($itemId -in $completed){continue}
        $before=Get-WsmCatalog $Workspace $PairId;$freshContext=Get-WsmWizardBulkPreparationContext $Workspace $before $PairId
        if([int]$before.DecisionRevision -ne ($initialDecision+$completed.Count) -or [int]$before.Assistive.Revision -ne ($initialAssistive+$completed.Count) -or [int]$freshContext.SelectionRevision -ne $initialSelection -or [string]$freshContext.SourceSnapshotHash -ine [string]$preview.Context.SourceSnapshotHash -or [string]$freshContext.ToolFingerprint -ine [string]$preview.Context.ToolFingerprint){$operation.Status='Partial';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation;throw ('Concurrent review context mismatch: decision '+$before.DecisionRevision+'/'+($initialDecision+$completed.Count)+' assistive '+$before.Assistive.Revision+'/'+($initialAssistive+$completed.Count)+' selection '+$freshContext.SelectionRevision+'/'+$initialSelection+' source '+$freshContext.SourceSnapshotHash+'/'+$preview.Context.SourceSnapshotHash+' tool '+$freshContext.ToolFingerprint+'/'+$preview.Context.ToolFingerprint)}
        $currentReview=Get-WsmWizardPreparationReview $Workspace $PairId $itemId;$previewItem=@($preview.Items|Where-Object ItemId -CEQ $itemId)[0]
        if($currentReview.SpecHash -ine $previewItem.SpecHash -or (Get-WsmWizardBulkPreparationStableFormHash $currentReview) -ine $previewItem.StableFormHash){$operation.Status='Partial';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation;throw 'Candidate review changed while applying; no stale form was submitted.'}
        $answers=Get-WsmWizardBulkPreparationNormalizedAnswers $currentReview $BusinessChecks
        $operation.CurrentItemId=$itemId;$operation.CurrentItemStatus='IntentUnknown';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation
        $saved=$null
        try{if($script:WsmBulkPreparationBeforeCoreSaveHook){$hook=$script:WsmBulkPreparationBeforeCoreSaveHook;$script:WsmBulkPreparationBeforeCoreSaveHook=$null;& $hook};$saved=Save-WsmWizardPreparationReview -Workspace $Workspace -PairId $PairId -ItemId $itemId -ReviewHash ([string]$currentReview.ReviewHash) -Owner $Owner -Evidence $Evidence -Answers $answers}
        catch{
            $recovered=Test-WsmWizardBulkPreparationCommittedItem $Workspace $PairId $previewItem $Owner $Evidence $BusinessChecks $preview.Context $completed.Count
            if(-not $recovered){$operation.CurrentItemStatus='Unknown';$operation.Status='Partial';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation;throw}
            $itemResult=[pscustomobject]@{ItemId=$itemId;Status='Saved';SpecPath=$recovered.SpecPath;SpecHash=$recovered.SpecHash;DecisionRevision=[int]$recovered.Catalog.DecisionRevision;ReplayedWrite=$true}
        }
        if($saved){$itemResult=[pscustomobject]@{ItemId=$itemId;Status='Saved';SpecPath=[string]$saved.SpecPath;SpecHash=[string]$saved.SpecHash;DecisionRevision=[int]$saved.DecisionRevision;ReplayedWrite=$false}}
        if($script:WsmBulkPreparationAfterCoreSaveHook){$hook=$script:WsmBulkPreparationAfterCoreSaveHook;$script:WsmBulkPreparationAfterCoreSaveHook=$null;& $hook}
        $operation.CompletedItemIds=@(@($operation.CompletedItemIds)+@($itemId)|Sort-Object -Unique);$operation.ItemResults=@(@($operation.ItemResults)+@($itemResult));$operation.CurrentItemId='';$operation.CurrentItemStatus='';$operation.Status='Running';$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation;$completed=@($operation.CompletedItemIds)
    }
    $result=[pscustomobject][ordered]@{Kind='WizardBulkPreparationSaved';Status='Succeeded';PairId=$PairId;OperationId=$OperationId;PreviewId=$PreviewId;PreviewHash=$PreviewHash;CandidateItemIds=@($preview.CandidateItemIds);SavedItemIds=@($operation.CompletedItemIds);Items=@($operation.ItemResults);BusinessAcceptance=$false;AuthoritativeApproval=$false;SpecWrites=@($operation.ItemResults|Where-Object {$_.ReplayedWrite -eq $false}).Count}
    $operation.Status='Succeeded';$operation.Result=$result;$operation.UpdatedUtc=Get-WsmUtc;Write-WsmJson $opPath $operation;$result
}

function Save-WsmWizardBulkPreparationReview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$PreviewId,[Parameter(Mandatory)][string]$PreviewHash,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][string[]]$BusinessChecks,[Parameter(Mandatory)][string]$OperationId,[switch]$ReviewedSourceDefaults)
    Assert-WsmId $OperationId
    $operationPath=Get-WsmWizardBulkPreparationOperationPath $Workspace $PairId $OperationId;$directory=Split-Path -Parent $operationPath
    if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory};Assert-WsmNoReparse $directory
    $lockPath=$operationPath+'.lock';$lock=$null
    try{
        $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
        Save-WsmWizardBulkPreparationReviewCore -Workspace $Workspace -PairId $PairId -PreviewId $PreviewId -PreviewHash $PreviewHash -Owner $Owner -Evidence $Evidence -BusinessChecks $BusinessChecks -OperationId $OperationId -ReviewedSourceDefaults:$ReviewedSourceDefaults
    }finally{if($lock){$lock.Dispose()}}
}
