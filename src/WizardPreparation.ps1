# A bounded plain-language form over the existing typed specification review.
# The client receives safe values and field keys; source identity and CAS stay server-owned.
function Get-WsmWizardPreparationFields($Review) {
    $fields=[ordered]@{}
    $allowed=@('TargetPath','TransferChannel','ContentSelection','ExcludedRelativePaths','Consistency','Metadata','ConflictPolicy','AclControlPolicy','ConfigFiles','ConfigOverrides','DesiredFinalState','BusinessChecks','Product','Procedure','Artifacts','CatchUpPolicy','WorkloadFieldReviews','IisBindings','IisApplicationPools','IisPoolSettings','IisConfigChanges','DesiredChanges','ActivationPolicyFieldPointer','PrincipalUser','ActivationOwner','ActivationReason','Desired','SecretRef','InstalledSoftwareScope','SoftwareExclusionCandidates','SoftwareScopeDiagnostics')
    foreach($name in $allowed){if($Review.TypedFields.PSObject.Properties[$name]){
        $original=$Review.TypedFields.$name
        if($name -ceq 'Desired'){
            $editable=@{Service=@('Name','Description');SmbShare=@('Name','Path','Description','EncryptData','DrainPolicy','DrainEvidence','Access');LocalUser=@('Name','FullName','Description');LocalGroup=@('Name','Description','Members');Certificate=@('Thumbprint','Store','ArtifactPath','ArtifactHash','HasPrivateKey')}
            if(-not $editable.ContainsKey([string]$Review.Adapter)){continue}
            $safe=[ordered]@{};foreach($property in $original.PSObject.Properties){if($editable[[string]$Review.Adapter] -ccontains [string]$property.Name){$safe[[string]$property.Name]=$property.Value}}
            $original=[pscustomobject]$safe
        }
        $envelope=ConvertFrom-WsmJson (ConvertTo-Json -InputObject ([pscustomobject]@{Value=$original}) -Depth 32 -Compress)
        if($original -is [array]){$fields[$name]=[object[]]@($envelope.Value)}else{$fields[$name]=$envelope.Value}
        if($name -ceq 'IisPoolSettings'){$map=@{};foreach($property in $fields[$name].PSObject.Properties){$map[$property.Name]=$property.Value};$fields[$name]=$map}
    }}
    if($Review.Adapter -in @('ScheduledTask','IISSite','IISPool','IISSection','IISLocation')){
        if(-not $fields.Contains('ActivationOwner')){$fields.ActivationOwner=''};if(-not $fields.Contains('ActivationReason')){$fields.ActivationReason=''}
    }
    if(@($Review.SharedResourceReviewReasons).Count){$fields.SharedResourceReviewReasons=@($Review.SharedResourceReviewReasons)}
    $fields
}

function Get-WsmWizardPreparationForm($Fields,[string]$Adapter='',[string]$AccountMode='') {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $labels=@{TargetPath='新電腦要存放的位置';TransferChannel='資料來源磁碟通道';ContentSelection='要保存的資料範圍';ExcludedRelativePaths='不搬移的子資料夾（每行一個）';Consistency='備份時如何避免檔案繼續變動';Metadata='需要保存的檔案權限';ConflictPolicy='遇到新電腦已有資料時';AclControlPolicy='檔案權限比對方式';BusinessChecks='搬移後需要確認的項目（每行一項）';Product='需要處理的軟體或服務';Procedure='人工處理步驟';Artifacts='需保留的交接資料（每行一項）';CatchUpPolicy='漏執行的排程如何處理';DesiredFinalState='日後另行核准啟用時的狀態';ActivationOwner='日後啟用的確認人';ActivationReason='日後啟用的理由';Value='新電腦使用的值';BindingInformation='網站位址與連接埠';PoolName='網站執行環境名稱';Protocol='網站連線方式';CertificateHash='網站憑證指紋';CertificateStoreName='網站憑證存放區';SslFlags='網站加密連線設定';Owner='共享設定的確認人';Reason='共享設定的確認理由';PrincipalUser='新電腦執行排程使用的帳號';ConfigOverrides='已審閱設定的調整';IisConfigChanges='網站設定的調整';DesiredChanges='已審閱設定的調整';ActivationPolicyFieldPointer='啟用設定的對應位置';Operation='這項設定要如何調整';ElementName='設定項目名稱';AttributeName='設定欄位名稱';BeforeValue='原本的設定值';AfterValue='新電腦使用的設定值';KeyAttributes='此設定的識別欄位';Name='設定名稱';managedRuntimeVersion='網站執行環境版本';managedPipelineMode='網站要求處理方式';enable32BitAppOnWin64='允許使用 32 位元網站程式';startMode='日後啟用時的啟動方式';queueLength='可等候處理的網站要求數';SslFlagsPresent='原始網站有指定加密連線設定';Description='用途說明';EncryptData='啟用 SMB 傳輸加密';DrainPolicy='共享資料變更時的處理方式';DrainEvidence='共享資料處理依據';Members='群組成員（每行一位）';ArtifactPath='公開憑證 CER 檔案位置';ArtifactHash='公開憑證檔案 SHA256';FullName='帳號顯示名稱';SecretRef='密碼保管項目參照（只填參照名稱，不填密碼）';Path='共享資料夾位置';Access='共享權限';AccountName='權限帳號';AccessControlType='允許或拒絕';AccessRight='共享權限等級';HasPrivateKey='來源憑證是否含私密金鑰';Thumbprint='憑證指紋';Store='目標憑證存放區'}
    $labels['InstalledSoftwareScope']='已安裝軟體目錄盤點狀態';$labels['SoftwareExclusionCandidates']='已確認的軟體安裝目錄排除候選';$labels['SoftwareScopeDiagnostics']='軟體目錄盤點限制與待辦';$labels['SoftwareId']='軟體項目識別';$labels['SourceKind']='安裝來源類型';$labels['Reason']='排除此安裝軟體目錄的依據';$labels['Coverage']='盤點完整性說明'
    $labels['ExactMemberSummary']='已確認的精確檔案集合'
    $options=@{TransferChannel=@('C','NonC','External');ContentSelection=@('ExactFiles','WholeScope');Consistency=@('OwnerFreeze','Immutable');Metadata=@('DaclOwner','DaclOwnerSacl');ConflictPolicy=@('Block');AclControlPolicy=@('Exact','AllowAutoInheritedUpgrade');DesiredFinalState=@('Disabled','Enabled');CatchUpPolicy=@('PreserveSourceSettings','SkipMissedRuns','DedicatedManualCatchUp');Protocol=@('http','https');DrainPolicy=@('BlockNewOpens','CloseReviewedHandles');AccessControlType=@('Allow','Deny');AccessRight=@('Read','Change','Full')}
    $walk={param($Value,[string]$Key,[string]$Name)
        if($rows.Count -ge 512){throw 'This review exceeds the bounded wizard form; use the existing controlled review workflow.'}
        $label=if($labels.ContainsKey($Name)){$labels[$Name]}else{$Name}
        if($Key -ceq 'ExactMemberSummary/Count'){$label='已確認檔案數'}elseif($Key -ceq 'ExactMemberSummary/SetHash'){$label='精確集合核對值'}elseif($Key -ceq 'ExactMemberSummary/Selection'){$label='範圍限制'}
        $readonly=$Name -in @('TransferChannel','Index','ApplicationPath','FieldPointer','ActivationPolicyFieldPointer','ResourceItemId','ConsumerItemIds','RelativePath','SoftwareId','SourceKind','Reason','SourceInventoryHash','InventoryRevision','Selection','InstalledSoftwareScope','SoftwareExclusionCandidates','SoftwareScopeDiagnostics','ArtifactHash','SHA256','BeforeValue','Name','HasPrivateKey','Thumbprint','Store','Protocol') -or $Key -match '^(ConfigFiles|ExactMemberSummary)/' -or ($Name -ceq 'ContentSelection' -and $Value -ceq 'ExactMembers')
        if($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long]){
            $withheld=($Value -is [string] -and $Value -match '\[(?:review required|sensitive text|withheld)')
            $type=if($Value -is [bool]){'boolean'}elseif($Value -is [int] -or $Value -is [long]){'integer'}elseif($options.ContainsKey($Name) -and $Value -cin $options[$Name]){'choice'}else{'text'}
            $requiresSecretRef=($Key -ceq 'SecretRef' -and ($Adapter -ceq 'LocalUser' -or ($Adapter -ceq 'Service' -and [string]$AccountMode -ceq 'UserPassword')))
            $requiresPublicCertificate=($Key -ceq 'Desired/ArtifactPath' -and $Adapter -ceq 'Certificate')
            $requiredCommand=$false
            if($Key -match '^WorkloadFieldReviews/(\d+)/Value$' -and $Fields.Contains('WorkloadFieldReviews')){$position=[int]$Matches[1];$reviews=@($Fields.WorkloadFieldReviews);if($position -lt $reviews.Count){$requiredCommand=([string]$reviews[$position].FieldPointer -match '/Command$')}}
            $required=$Name -in @('TargetPath','ActivationOwner','ActivationReason','Owner','Reason','Product','Procedure') -or $requiresSecretRef -or $requiresPublicCertificate -or $requiredCommand
            $fieldOptions=[string[]]@();if($options.ContainsKey($Name)){$fieldOptions=[string[]]@($options[$Name])}
            $rows.Add([pscustomobject][ordered]@{key=$Key;label=$label;type=$type;value=$Value;required=$required;editable=(-not $readonly -and -not $withheld);options=$fieldOptions;origin=$(if($withheld){'ProtectedEvidence'}elseif($Value -eq '' -or $null -eq $Value){'NeedsHumanDecision'}else{'CurrentDraft'})})
        }elseif($Value -is [array]){
            if(-not @($Value|Where-Object {$null -ne $_ -and $_ -isnot [string]}).Count){$rows.Add([pscustomobject][ordered]@{key=$Key;label=$label;type='lines';value=(@($Value)-join "`n");required=($Name -eq 'BusinessChecks');editable=(-not $readonly);options=@();origin='CurrentDraft'})}
            else{for($i=0;$i -lt $Value.Count;$i++){& $walk $Value[$i] ($Key+'/'+$i) $Name}}
        }elseif($Value -is [Collections.IDictionary]){foreach($child in $Value.Keys){& $walk $Value[$child] ($Key+'/'+[string]$child) ([string]$child)}}
        else{foreach($child in $Value.PSObject.Properties){& $walk $child.Value ($Key+'/'+$child.Name) $child.Name}}
    }
    foreach($key in $Fields.Keys){& $walk $Fields[$key] ([string]$key) ([string]$key)}
    @($rows.ToArray())
}

function Get-WsmWizardPreparationSourceEvidence([string]$Workspace,$Catalog,$ItemId) {
    $snapshot=$Catalog.Assistive.SourceSnapshot
    if(-not $snapshot -or [string]$snapshot.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){return $null}
    try{$path=Get-WsmAssistiveReportReferencePath $Workspace $snapshot 'Source snapshot';$inventory=Read-WsmTrustedJson $path ([string]$snapshot.SHA256);if($inventory.Kind -cne 'Inventory' -or [int]$inventory.Revision -ne [int]$snapshot.InventoryRevision){return $null};$items=@($inventory.Items|Where-Object ItemId -CEQ $ItemId);if($items.Count -ne 1){return $null};$catalogItems=@($Catalog.Items|Where-Object ItemId -CEQ $ItemId);if($catalogItems.Count -ne 1 -or [string]$catalogItems[0].SettingsHash -ine [string]$items[0].SettingsHash){return $null};[pscustomobject]@{InventoryHash=[string]$snapshot.SHA256;InventoryRevision=[int]$inventory.Revision;CapturedUtc=[string]$inventory.CreatedUtc;Item=$items[0];Inventory=$inventory}}catch{$null}
}

function Get-WsmWizardInstalledSoftwareScope($SourceEvidence,$Spec,[bool]$SavedSpec) {
    $result=[ordered]@{Status='Unavailable';SourceInventoryHash='';InventoryRevision=0;Candidates=@();Diagnostics=@('Trusted source software inventory is unavailable; no installation roots were suggested.')}
    if(-not $SourceEvidence -or -not $SourceEvidence.Inventory -or $Spec.Adapter -cne 'FileScope'){return [pscustomobject]$result}
    $result.SourceInventoryHash=[string]$SourceEvidence.InventoryHash;$result.InventoryRevision=[int]$SourceEvidence.InventoryRevision
    try{$roots=Get-WsmTrustedInstalledSoftwareRoots $SourceEvidence.Inventory}catch{$result.Diagnostics=@('Trusted software catalog could not be validated: '+[string]$_.Exception.Message);return [pscustomobject]$result}
    $result.Status=[string]$roots.Status;$result.Diagnostics=@($roots.Diagnostics);$sourceRoot='';try{$sourceRoot=ConvertTo-WsmCanonicalPath ([string]$Spec.SourcePath)}catch{$result.Status='Partial';$result.Diagnostics+=@('Source root could not be canonicalized for installed-root comparison.');return [pscustomobject]$result}
    $candidates=New-Object 'System.Collections.Generic.List[object]';$blocking=New-Object 'System.Collections.Generic.List[string]'
    foreach($install in @($roots.Roots)){
        try{$installPath=ConvertTo-WsmCanonicalPath ([string]$install.Path)}catch{continue}
        if($installPath.StartsWith($sourceRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){
            $relative=$installPath.Substring($sourceRoot.TrimEnd('\').Length).TrimStart('\')
            if(-not $relative -or $relative -match '(^|\\)\.\.?($|\\)'){continue}
            $already=@($Spec.ExcludedRelativePaths|Where-Object { [string]$_ -ceq $relative -or $relative.StartsWith(([string]$_).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            $candidates.Add([pscustomobject][ordered]@{RelativePath=$relative;SoftwareId=[string]$install.SoftwareId;SourceKind=[string]$install.SourceKind;Reason='Trusted source inventory identifies this exact directory as an installed software root. Review excluding it from business-data transfer.';SourceInventoryHash=[string]$SourceEvidence.InventoryHash;InventoryRevision=[int]$SourceEvidence.InventoryRevision;Selection=$(if($already){'AlreadyExcluded'}elseif($SavedSpec){'SavedChoiceNeedsReview'}else{'SuggestedForReview'})})
        }elseif($sourceRoot -ieq $installPath -or $sourceRoot.StartsWith($installPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$blocking.Add(('Selected source scope overlaps installed software root '+[string]$install.SoftwareId+' ('+$installPath+'); narrow the source scope or use ExactFiles.'))}
    }
    if($blocking.Count){$result.Status='Blocked';$result.Diagnostics+=@($blocking.ToArray())}
    $result.Candidates=@($candidates.ToArray());[pscustomobject]$result
}

function Get-WsmWizardPreparationBindingHash($Review,$Catalog,$Spec,$SourceEvidence,$SoftwareScope) {
    $binding=[ordered]@{Review=$Review;SpecHash=(Get-WsmHashText ($Spec|ConvertTo-Json -Depth 40 -Compress));SourceSnapshotHash=[string]$Catalog.Assistive.SourceSnapshot.SHA256;SourceInventoryRevision=$(if($SourceEvidence){[int]$SourceEvidence.InventoryRevision}else{0});SourceInventoryHash=$(if($SourceEvidence){[string]$SourceEvidence.InventoryHash}else{''});SoftwareScopeStatus=[string]$SoftwareScope.Status;SoftwareExclusionCandidates=@($SoftwareScope.Candidates|ForEach-Object {[ordered]@{RelativePath=[string]$_.RelativePath;SoftwareId=[string]$_.SoftwareId;SourceKind=[string]$_.SourceKind;SourceInventoryHash=[string]$_.SourceInventoryHash}})}
    Get-WsmHashText ($binding|ConvertTo-Json -Depth 50 -Compress)
}

function Get-WsmWizardPreparationReview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId)
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Specification review requires the enrolled organizing workspace.'}
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Preparation review requires an enrolled Manager workspace.'}
    $review=Get-WsmAssistiveSpecReview $Workspace $PairId $ItemId
    $itemContext=Get-WsmAssistiveReviewItem $Workspace $PairId $ItemId
    $values=Get-WsmWizardPreparationFields $review
    $sourceEvidence=Get-WsmWizardPreparationSourceEvidence $Workspace $itemContext.Catalog $ItemId
    $savedSpec=[bool]$itemContext.Item.PSObject.Properties['MigrationSpec'];$savedConfirmed=($savedSpec -and -not [string]::IsNullOrWhiteSpace([string]$itemContext.Spec.Owner) -and -not [string]::IsNullOrWhiteSpace([string]$itemContext.Spec.Evidence));$specHash=Get-WsmHashText ($itemContext.Spec|ConvertTo-Json -Depth 40 -Compress)
    $softwareScope=Get-WsmWizardInstalledSoftwareScope $sourceEvidence $itemContext.Spec $savedSpec
    if(-not $savedSpec -and $softwareScope.Status -ne 'Blocked' -and @($softwareScope.Candidates).Count -and $values.Contains('ExcludedRelativePaths')){$values.ExcludedRelativePaths=@(@($values.ExcludedRelativePaths)+@($softwareScope.Candidates|ForEach-Object {$_.RelativePath})|Sort-Object -Unique)}
    if($review.TypedFields.PSObject.Properties['ExactMemberSummary']){$values.ExactMemberSummary=$review.TypedFields.ExactMemberSummary}
    $values.InstalledSoftwareScope=([string]$softwareScope.Status+$(if($softwareScope.SourceInventoryHash){' — source inventory '+$softwareScope.SourceInventoryHash+' revision '+$softwareScope.InventoryRevision}else{''}))
    $values.SoftwareExclusionCandidates=@($softwareScope.Candidates)
    $values.SoftwareScopeDiagnostics=@($softwareScope.Diagnostics)
    $accountMode=if($review.TypedFields.PSObject.Properties['AccountMode']){[string]$review.TypedFields.AccountMode}else{''}
    $form=@(Get-WsmWizardPreparationForm $values ([string]$review.Adapter) $accountMode)
    $hash=Get-WsmWizardPreparationBindingHash $review $itemContext.Catalog $itemContext.Spec $sourceEvidence $softwareScope
    $candidate='';if($sourceEvidence -and $sourceEvidence.Item.Settings.PSObject.Properties['ResolvedCandidate'] -and [string]$sourceEvidence.Item.Settings.ResolvedCandidate){$candidate=[string]$sourceEvidence.Item.Settings.ResolvedCandidate}elseif($sourceEvidence -and $sourceEvidence.Item.Settings.PSObject.Properties['OriginalPath']){$candidate=[string]$sourceEvidence.Item.Settings.OriginalPath}
    foreach($field in $form){
        if(-not $field.PSObject.Properties['provenance']){$field|Add-Member NoteProperty provenance $null}
        $isCandidate=($sourceEvidence -and $candidate -and $field.key -in @('SourcePath','TargetPath') -and [string]$field.value -ceq $candidate)
        $isInstalledSuggestion=($field.key -ceq 'ExcludedRelativePaths' -and -not $savedSpec -and @($softwareScope.Candidates).Count -gt 0 -and ([string]$field.value -split '\r?\n'|Sort-Object -Unique) -join '|' -ceq (@($softwareScope.Candidates|ForEach-Object {$_.RelativePath}|Sort-Object -Unique) -join '|'))
        if($field.origin -ceq 'NeedsHumanDecision'){$field.provenance=[pscustomobject][ordered]@{kind='NeedsHumanDecision';freshness='No trusted value is available.';reviewHash=$hash}}
        elseif($isInstalledSuggestion){$field.origin='TrustedSourceInventory';$field.provenance=[pscustomobject][ordered]@{kind='TrustedSourceInventory';inventoryHash=[string]$sourceEvidence.InventoryHash;inventoryRevision=[int]$sourceEvidence.InventoryRevision;itemId=$ItemId;settingsHash=[string]$sourceEvidence.Item.SettingsHash;softwareIds=@($softwareScope.Candidates|ForEach-Object SoftwareId);reasons=@($softwareScope.Candidates|ForEach-Object Reason);reviewHash=$hash;freshness='Suggested exclusions come from this hash-bound source software catalog and require explicit owner review before the specification is saved.'}}
        elseif($savedConfirmed){$field.origin='SameWorkSavedReview';$field.provenance=[pscustomobject][ordered]@{kind='SameWorkSavedReview';specHash=$specHash;sourceInventoryHash=[string]$itemContext.Catalog.Assistive.SourceSnapshot.SHA256;decisionRevision=[int]$review.DecisionRevision;assistiveRevision=[int]$review.AssistiveRevision;selectionRevision=[int]$review.SelectionRevision;reviewHash=$hash;freshness='Current only for this exact saved specification, source snapshot and review revisions; changes invalidate this value.'}}
        elseif($isCandidate){$field.origin='TrustedSourceInventory';$field.provenance=[pscustomobject][ordered]@{kind='TrustedSourceInventory';inventoryHash=[string]$sourceEvidence.InventoryHash;inventoryRevision=[int]$sourceEvidence.InventoryRevision;capturedUtc=[string]$sourceEvidence.CapturedUtc;itemId=$ItemId;settingsHash=[string]$sourceEvidence.Item.SettingsHash;reviewHash=$hash;freshness='Current only while this exact source snapshot and review remain current; no time expiry is asserted.'}}
        elseif($savedSpec){$field.origin='SavedWorkDraft';$field.provenance=[pscustomobject][ordered]@{kind='SavedWorkDraft';specHash=$specHash;sourceInventoryHash=[string]$itemContext.Catalog.Assistive.SourceSnapshot.SHA256;decisionRevision=[int]$review.DecisionRevision;assistiveRevision=[int]$review.AssistiveRevision;selectionRevision=[int]$review.SelectionRevision;reviewHash=$hash;freshness='Draft is bound to this exact specification and review; stale review hashes are rejected.'}}
        else{$field.origin='ConservativeDefault';$field.provenance=[pscustomobject][ordered]@{kind='ConservativeDefault';reviewHash=$hash;freshness='Current only for this exact review; explicit answers take priority.'}}
    }
    $editablePointers=@();if($review.TypedFields.PSObject.Properties['WorkloadFieldReviews']){$editablePointers=@($review.TypedFields.WorkloadFieldReviews|ForEach-Object {$_.FieldPointer})}
    $manualRequired=@($review.OpaqueReviewRequired|Where-Object {$_.FieldPointer -cnotin $editablePointers}).Count -gt 0
    [pscustomobject][ordered]@{Kind='WizardPreparationReview';PairId=$PairId;ItemId=$ItemId;ItemName=[string](ConvertTo-WsmAssistiveSafeValue ([string]$itemContext.Item.Name) 'ItemName');ReviewHash=$hash;SpecHash=$specHash;Adapter=$review.Adapter;DecisionRevision=$review.DecisionRevision;AssistiveRevision=$review.AssistiveRevision;SelectionRevision=$review.SelectionRevision;Owner=$review.Owner;Evidence=$review.Evidence;FormFields=$form;DefaultPriority=@('ExplicitUserAnswer','SameWorkSavedReview','TrustedSourceInventory','ConservativeDefault');SourceSnapshotHash=[string]$itemContext.Catalog.Assistive.SourceSnapshot.SHA256;SoftwareScopeStatus=[string]$softwareScope.Status;SoftwareScopeSourceInventoryHash=[string]$softwareScope.SourceInventoryHash;SoftwareScopeDiagnostics=@($softwareScope.Diagnostics);SoftwareExclusionCandidates=@($softwareScope.Candidates);MissingTypedFields=@($review.MissingTypedFields);ManualReviewRequired=$manualRequired;SourceXmlSHA256=$review.SourceXmlSHA256;RawXmlIncluded=$false;SecretsIncluded=$false;AuthoritativeApproval=$false}
}

function Set-WsmWizardPreparationValue($Fields,[string]$Key,$Value) {
    $segments=$Key.Split('/');$node=$Fields
    for($i=0;$i -lt $segments.Length-1;$i++){if($node -is [array]){$node=$node[[int]$segments[$i]]}elseif($node -is [Collections.IDictionary]){$node=$node[$segments[$i]]}else{$node=$node.($segments[$i])}}
    $last=$segments[-1];if($node -is [array]){$node[[int]$last]=$Value}elseif($node -is [Collections.IDictionary]){$node[$last]=$Value}else{$node.$last=$Value}
}

function New-WsmWizardPreparationFieldError([string]$Key,[ValidateSet('required','type','option','format','length')][string]$Reason,[switch]$TopLevel) {
    $token=$Key.Replace('~','~0').Replace('/','~1');$pointer=if($TopLevel){'/'+$token}else{'/Answers/'+$token}
    New-WsmContractError ('PreparationFieldValidation|'+$pointer+'|'+$Reason)
}
function Save-WsmWizardPreparationReview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId,[Parameter(Mandatory)][string]$ReviewHash,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][Collections.IDictionary]$Answers)
    if($ReviewHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'A verified current specification review hash is required.'}
    $projection=Get-WsmWizardPreparationReview $Workspace $PairId $ItemId
    if($projection.ReviewHash -ine $ReviewHash){throw 'Review changed; refresh the current specification before saving.'}
    $review=Get-WsmAssistiveSpecReview $Workspace $PairId $ItemId
    $itemContext=Get-WsmAssistiveReviewItem $Workspace $PairId $ItemId
    $sourceEvidence=Get-WsmWizardPreparationSourceEvidence $Workspace $itemContext.Catalog $ItemId
    $softwareScope=Get-WsmWizardInstalledSoftwareScope $sourceEvidence $itemContext.Spec ([bool]$itemContext.Item.PSObject.Properties['MigrationSpec'])
    if((Get-WsmWizardPreparationBindingHash $review $itemContext.Catalog $itemContext.Spec $sourceEvidence $softwareScope) -ine $ReviewHash){throw 'Review or hash-bound source software evidence changed while loading; refresh before saving.'}
    $fields=Get-WsmWizardPreparationFields $review
    if($review.Adapter -ceq 'FileScope' -and -not $itemContext.Item.PSObject.Properties['MigrationSpec'] -and -not $Answers.Contains('ExcludedRelativePaths')){
        if($softwareScope.Status -ne 'Blocked' -and @($softwareScope.Candidates).Count){$fields.ExcludedRelativePaths=@(@($fields.ExcludedRelativePaths)+@($softwareScope.Candidates|ForEach-Object {$_.RelativePath})|Sort-Object -Unique)}
    }
    $index=@{};foreach($field in $projection.FormFields){$index[$field.key]=$field}
    foreach($key in $Answers.Keys){if(-not $index.ContainsKey([string]$key) -or -not $index[[string]$key].editable){throw ('The answer attempts to change a source-derived or unknown review field: '+[string]$key)};$field=$index[[string]$key];$value=$Answers[$key]
        switch($field.type){
            boolean {if($value -isnot [bool]){throw (New-WsmWizardPreparationFieldError $key type)}}
            integer {if($value -isnot [int] -and $value -isnot [long]){throw (New-WsmWizardPreparationFieldError $key type)}}
            lines {if($value -isnot [string]){throw (New-WsmWizardPreparationFieldError $key type)};if($value.Length -gt 8192){throw (New-WsmWizardPreparationFieldError $key length)};$value=[string[]]@($value -split '\r?\n'|ForEach-Object {$_.Trim()}|Where-Object {$_})}
            default {if($value -isnot [string] -or $value.Length -gt 8192){throw (New-WsmWizardPreparationFieldError $key type)};if($field.type -eq 'choice' -and $value -cnotin $field.options){throw (New-WsmWizardPreparationFieldError $key option)}}
        }
        if($field.required -and (($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) -or ($value -is [array] -and -not $value.Count))){throw (New-WsmWizardPreparationFieldError $key required)}
        if([string]$key -ceq 'SecretRef' -and -not [string]::IsNullOrWhiteSpace([string]$value) -and [string]$value -notmatch '^[A-Za-z0-9_.-]{1,128}$'){throw (New-WsmWizardPreparationFieldError $key format)}
        Set-WsmWizardPreparationValue $fields ([string]$key) $value
    }
    foreach($field in @($projection.FormFields|Where-Object {$_.editable -and $_.required})){
        $effective=if($Answers.Contains([string]$field.key)){$Answers[[string]$field.key]}else{$field.value}
        if($null -eq $effective -or ($effective -is [string] -and [string]::IsNullOrWhiteSpace($effective)) -or ($effective -is [array] -and -not $effective.Count)){throw (New-WsmWizardPreparationFieldError ([string]$field.key) required)}
    }
    Submit-WsmAssistiveSpecReview -Workspace $Workspace -PairId $PairId -ItemId $ItemId -ExpectedDecisionRevision $review.DecisionRevision -ExpectedAssistiveRevision $review.AssistiveRevision -ExpectedSelectionRevision $review.SelectionRevision -Owner $Owner -Evidence $Evidence -Fields $fields
}
