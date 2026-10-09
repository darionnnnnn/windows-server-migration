function Get-WsmGeneralHostContract($Catalog) {
    if (-not $Catalog.PSObject.Properties['GeneralHost'] -or -not $Catalog.GeneralHost) { throw (New-WsmContractError 'GeneralHost scope requires its versioned contract.') }
    $Catalog.GeneralHost
}

function Get-WsmGeneralHostProjectionHash($Catalog,[string[]]$ConsumerItemIds=@(),[string[]]$RequirementIds=@(),[ValidateSet('PreparationReady','RestoreReady','StagedDependencyVerified','CutoverReady','FinalAccepted','RetirementReady')][string]$Phase='PreparationReady') {
    # Read-only projections must still evaluate under caller -WhatIf.
    $WhatIfPreference=$false
    $g=Get-WsmGeneralHostContract $Catalog
    $consumers=@($ConsumerItemIds | Sort-Object -Unique)
    $requirements=@($g.Requirements | Where-Object {
        $r=$_
        (-not $RequirementIds.Count -or $RequirementIds -contains $r.RequirementId) -and
        (-not $consumers.Count -or @($r.ConsumerItemIds | Where-Object { $consumers -contains $_ }).Count -gt 0) -and
        ([array]::IndexOf(@('PreparationReady','RestoreReady','StagedDependencyVerified','CutoverReady','FinalAccepted','RetirementReady'),[string]$r.RequiredPhase) -le [array]::IndexOf(@('PreparationReady','RestoreReady','StagedDependencyVerified','CutoverReady','FinalAccepted','RetirementReady'),$Phase))
    } | Sort-Object RequirementId | ForEach-Object {
        [ordered]@{RequirementId=$_.RequirementId;Type=$_.Type;ProviderSoftwareId=$_.ProviderSoftwareId;ProviderItemId=$_.ProviderItemId;ExternalId=$_.ExternalId;ConsumerItemIds=@($_.ConsumerItemIds | Sort-Object -Unique);Certainty=$_.Certainty;RequiredPhase=$_.RequiredPhase;ExpectedVersion=$_.ExpectedVersion;Architecture=$_.Architecture;Context=(ConvertTo-WsmGeneralHostCanonicalValue $_.Context);Owner=$_.Owner;Decision=$_.Decision;DecisionReason=$_.DecisionReason;SourceProof=(ConvertTo-WsmGeneralHostCanonicalValue $_.SourceProof)}
    })
    $consumerDecisions=@(foreach($id in $consumers){$item=@($Catalog.Items | Where-Object ItemId -CEQ $id | Select-Object -First 1);if($item.Count){$override=$null;if($item[0].PSObject.Properties['GeneralHostOverride']){$o=$item[0].GeneralHostOverride;$override=[ordered]@{Disposition=$o.Disposition;Owner=$o.Owner;Reason=$o.Reason;Evidence=$o.Evidence}};[ordered]@{ItemId=$id;Decision=$item[0].Decision;Owner=$item[0].Owner;Reason=$item[0].Reason;Evidence=$item[0].Evidence;Override=$override}}})
    $providerIds=@($requirements | ForEach-Object ProviderSoftwareId | Where-Object {$_} | Sort-Object -Unique)
    $providerFacts=@();if($g.SoftwareCatalog){$providerFacts=@(foreach($id in $providerIds){$entry=@($g.SoftwareCatalog.Entries | Where-Object SoftwareId -CEQ $id | Select-Object -First 1);if($entry.Count){$e=$entry[0];$owner='';$evidenceHash='';if($e.PSObject.Properties['Owner']){$owner=$e.Owner};if($e.PSObject.Properties['EvidenceHash']){$evidenceHash=$e.EvidenceHash};[ordered]@{SoftwareId=$e.SoftwareId;Name=$e.Name;Version=$e.Version;Publisher=$e.Publisher;Architecture=$e.Architecture;Scope=$e.Scope;SID=$e.SID;RegistryView=$e.RegistryView;Location=$e.Location;SourceKind=$e.SourceKind;Evidence=$e.Evidence;CaptureStatus=$e.CaptureStatus;ItemIds=@($e.ItemIds);AccountContext=$e.AccountContext;Owner=$owner;EvidenceHash=$evidenceHash}}})}
    $providerDecisions=@(foreach($id in $providerIds){$decision=@($g.SoftwareDecisions | Where-Object SoftwareId -CEQ $id | Select-Object -First 1);if($decision.Count){$d=$decision[0];[ordered]@{SoftwareId=$d.SoftwareId;SoftwareHash=$d.SoftwareHash;Disposition=$d.Disposition;Owner=$d.Owner;Reason=$d.Reason;Evidence=$d.Evidence}}})
    $projection=[ordered]@{SchemaVersion=1;PairId=$Catalog.PairId;SourceHostId=$Catalog.Source.HostId;SourceFingerprint=$Catalog.Source.Fingerprint;InventoryHash=$Catalog.InventoryHash;Consumers=$consumers;ConsumerDecisions=@($consumerDecisions);Phase=$Phase;Requirements=@($requirements);ProviderFacts=@($providerFacts);ProviderDecisions=@($providerDecisions)}
    Get-WsmHashText ($projection | ConvertTo-Json -Depth 30 -Compress)
}

function ConvertTo-WsmGeneralHostCanonicalValue($Value) {
    if($null -eq $Value){return $null}
    if($Value -is [System.Collections.IDictionary]){$canonical=[ordered]@{};foreach($key in @($Value.Keys | ForEach-Object {[string]$_} | Sort-Object -CaseSensitive)){$canonical[$key]=ConvertTo-WsmGeneralHostCanonicalValue $Value[$key]};return $canonical}
    if($Value -is [System.Array]){return ,@($Value | ForEach-Object {ConvertTo-WsmGeneralHostCanonicalValue $_})}
    if($Value -is [pscustomobject]){$canonical=[ordered]@{};foreach($property in @($Value.PSObject.Properties | Sort-Object Name -CaseSensitive)){$canonical[$property.Name]=ConvertTo-WsmGeneralHostCanonicalValue $property.Value};return $canonical}
    $Value
}

function Get-WsmGeneralHostRequirementId($Requirement) {
    $identity=[ordered]@{Type=$Requirement.Type;ProviderSoftwareId=$Requirement.ProviderSoftwareId;ProviderItemId=$Requirement.ProviderItemId;ExternalId=$Requirement.ExternalId;ConsumerItemIds=@($Requirement.ConsumerItemIds | Sort-Object -Unique);RequiredPhase=$Requirement.RequiredPhase;ExpectedVersion=$Requirement.ExpectedVersion;Architecture=$Requirement.Architecture;Context=(ConvertTo-WsmGeneralHostCanonicalValue $Requirement.Context)}
    Get-WsmHashText ($identity | ConvertTo-Json -Depth 12 -Compress)
}

function Get-WsmGeneralHostContextHash($Context) { Get-WsmHashText ((ConvertTo-WsmGeneralHostCanonicalValue $Context) | ConvertTo-Json -Depth 20 -Compress) }

function Assert-WsmPreparationEvidence($Evidence) {
    $fields=@('MediaReference','MediaSHA256','VerificationMethod','SignatureEvidence','VendorOSSupportReference','VendorSupportCheckedUtc','LicenseReference','InstallOrder','IsolationEvidenceSHA256','RestartStatus','SideEffectsReference')
    if($null -eq $Evidence){throw 'Preparation requires media, vendor support, licensing, isolation, restart and side-effect evidence.'}
    Assert-WsmFields $Evidence $fields $fields
    foreach($name in @('MediaReference','SignatureEvidence','VendorOSSupportReference','LicenseReference','SideEffectsReference')){if($Evidence.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Evidence.$name) -or $Evidence.$name.Length -gt 2048 -or $Evidence.$name -match '(?i)(password|pwd|secret|token)\s*=|//[^\s/:]+:[^\s/@]+@'){throw ('Invalid preparation evidence reference: '+$name)}}
    if($Evidence.MediaSHA256 -notmatch '^[a-fA-F0-9]{64}$' -or $Evidence.IsolationEvidenceSHA256 -notmatch '^[a-fA-F0-9]{64}$' -or $Evidence.VerificationMethod -cnotin @('SignatureVerified','OwnerVerified') -or $Evidence.RestartStatus -cnotin @('CompletedAndVerified','NotRequired') -or ($Evidence.InstallOrder -isnot [int] -and $Evidence.InstallOrder -isnot [long]) -or $Evidence.InstallOrder -lt 1){throw 'Preparation media, isolation, installation order or restart has not been verified.'}
    $checked=[DateTimeOffset]::MinValue
    if([string]$Evidence.VendorSupportCheckedUtc -notmatch '^\d{4}-\d{2}-\d{2}T.*(?:Z|\+00:00)$' -or -not [DateTimeOffset]::TryParse([string]$Evidence.VendorSupportCheckedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$checked) -or $checked.Offset -ne [TimeSpan]::Zero -or $checked -gt [DateTimeOffset]::UtcNow.AddMinutes(5)){throw 'Vendor support check requires a valid observed ISO-8601 UTC timestamp.'}
}

function Get-WsmGeneralHostSoftwareFactsHash($Entry) {
    $owner='';$evidenceHash='';if($Entry.PSObject.Properties['Owner']){$owner=[string]$Entry.Owner};if($Entry.PSObject.Properties['EvidenceHash']){$evidenceHash=[string]$Entry.EvidenceHash}
    $facts=[ordered]@{SoftwareId=[string]$Entry.SoftwareId;Name=[string]$Entry.Name;Version=[string]$Entry.Version;Publisher=[string]$Entry.Publisher;Architecture=[string]$Entry.Architecture;Scope=[string]$Entry.Scope;SID=[string]$Entry.SID;RegistryView=[string]$Entry.RegistryView;Location=[string]$Entry.Location;SourceKind=[string]$Entry.SourceKind;Evidence=(ConvertTo-WsmGeneralHostCanonicalValue $Entry.Evidence);CaptureStatus=[string]$Entry.CaptureStatus;ItemIds=@($Entry.ItemIds | Sort-Object -Unique);AccountContext=[string]$Entry.AccountContext;Owner=$owner;EvidenceHash=$evidenceHash}
    Get-WsmHashText ($facts | ConvertTo-Json -Depth 24 -Compress)
}

function Test-WsmGeneralHostSpecialSoftware($Entry) {
    $text=([string]$Entry.Name+' '+[string]$Entry.Publisher+' '+[string]$Entry.SourceKind)
    $text -match '(?i)(^|\W)(Oracle Database( Server)?\s+\d|Microsoft SQL Server.*Database Engine|SQL Server Database Engine|PostgreSQL Server|MySQL Server|MariaDB Server|MongoDB Server)(\W|$)'
}

function Get-WsmCatalogInventoryProjection($Catalog) {
    $sourceInventory=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='Inventory';Source=$Catalog.Source;Revision=$Catalog.InventoryRevision;CreatedUtc=[string]$Catalog.ImportedUtc;Items=@(foreach($item in @($Catalog.Items)){if($item.PSObject.Properties['Present'] -and -not [bool]$item.Present){continue};if($item.PSObject.Properties['ManualEntry'] -and [bool]$item.ManualEntry){continue};[pscustomobject][ordered]@{ItemId=$item.ItemId;Category=$item.Category;Kind=$item.Kind;Name=$item.Name;NaturalKey=$item.NaturalKey;Settings=$item.Settings;SettingsHash=$item.SettingsHash;Dependencies=@($item.Dependencies);Status=$item.Status;Adapter=$item.Adapter}})}
    $sourceInventory
}

function Assert-WsmGeneralHostSoftwareCatalog($SoftwareCatalog,$Catalog=$null) {
    if ($null -eq $SoftwareCatalog) { throw (New-WsmContractError 'GeneralHost mode requires a complete SoftwareCatalog; source inventory alone is insufficient.') }
    if (-not (Get-Command Assert-WsmSoftwareCatalog -ErrorAction SilentlyContinue)) { throw 'SoftwareCatalog validator is unavailable; GeneralHost cannot proceed.' }
    if($Catalog){$sourceInventory=Get-WsmCatalogInventoryProjection $Catalog;Assert-WsmSoftwareCatalog $SoftwareCatalog -SourceInventory $sourceInventory | Out-Null}else{Assert-WsmSoftwareCatalog $SoftwareCatalog | Out-Null}
    $true
}

function Assert-WsmGeneralHostContract($Catalog) {
    if(-not $Catalog.PSObject.Properties['GeneralHost']){throw (New-WsmContractError 'Schema 2 catalog requires GeneralHost contract.')}
    $g=$Catalog.GeneralHost
    foreach($f in @('SchemaVersion','ScopeMode','SoftwareCatalog','SoftwareCatalogHash','SoftwareDecisions','Requirements','OrphanedRequirements','EvidenceReceipts','UpdatedUtc')){if(-not $g.PSObject.Properties[$f]){throw ('GeneralHost contract missing '+$f+'.')}}
    if($g.SchemaVersion -ne 1 -or $g.ScopeMode -cne 'GeneralHost' -or $g.SoftwareDecisions -isnot [array] -or $g.Requirements -isnot [array] -or $g.OrphanedRequirements -isnot [array] -or $g.EvidenceReceipts -isnot [array]){throw 'Invalid GeneralHost contract version, mode or collections.'}
    if($g.SoftwareCatalog){Assert-WsmGeneralHostSoftwareCatalog $g.SoftwareCatalog $Catalog | Out-Null;if($g.SoftwareCatalogHash -cne (Get-WsmHashText ($g.SoftwareCatalog | ConvertTo-Json -Depth 30 -Compress))){throw 'SoftwareCatalog hash mismatch.'}}
    elseif($g.SoftwareCatalogHash){throw 'SoftwareCatalog hash is present without catalog data.'}
    $ids=@{};$itemIds=@{};foreach($item in @($Catalog.Items)){$itemIds[$item.ItemId]=$true};$softwareEntryIds=@{};if($g.SoftwareCatalog){foreach($entry in @($g.SoftwareCatalog.Entries)){$softwareEntryIds[$entry.SoftwareId]=$true}}
    $softwareDecisionIds=@{};foreach($d in @($g.SoftwareDecisions)){foreach($f in @('SoftwareId','SoftwareHash','Disposition','Owner','Reason','Evidence','SourceHash')){if(-not $d.PSObject.Properties[$f]){throw 'Software decision record is incomplete.'}};if($d.SoftwareId -notmatch '^sw-[a-f0-9]{32}$' -or $d.SoftwareHash -notmatch '^[a-f0-9]{64}$' -or $d.SourceHash -notmatch '^[a-f0-9]{64}$' -or $softwareDecisionIds.ContainsKey($d.SoftwareId) -or @('Reinstall','Portable','KeepCompatible','External','NotNeeded','Unknown') -cnotcontains $d.Disposition -or -not $d.Owner -or -not $d.Reason -or -not $d.Evidence){throw 'Invalid or duplicate software disposition.'};$softwareDecisionIds[$d.SoftwareId]=$true}
    foreach($r in @($g.Requirements)){
        foreach($f in @('RequirementId','Type','ProviderSoftwareId','ProviderItemId','ExternalId','ConsumerItemIds','Certainty','RequiredPhase','ExpectedVersion','Architecture','Context','Owner','SourceProof','Decision','DecisionReason','DecisionEvidence')){if(-not $r.PSObject.Properties[$f]){throw ('Requirement missing '+$f+'.')}}
        if($r.RequirementId -notmatch '^[a-f0-9]{64}$' -or $ids.ContainsKey($r.RequirementId)){throw 'Invalid or duplicate RequirementId.'};$ids[$r.RequirementId]=$true
        if(@('Preparation','ExternalDependency') -cnotcontains $r.Type -or @('Required','Candidate') -cnotcontains $r.Certainty -or @('PreparationReady','StagedDependencyVerified','CutoverReady') -cnotcontains $r.RequiredPhase -or @('Pending','Required','NotNeeded') -cnotcontains $r.Decision){throw 'Invalid typed requirement values.'}
        if($r.RequirementId -cne (Get-WsmGeneralHostRequirementId $r)){throw 'RequirementId does not match its stable relation identity.'}
        if(-not $r.ExpectedVersion -or -not $r.Architecture -or $null -eq $r.Context -or -not $r.Owner){throw 'Typed requirements need expected version, architecture, context and accountable owner.'}
        if($r.Type -ceq 'Preparation' -and $r.ProviderSoftwareId -and $r.RequiredPhase -ceq 'PreparationReady'){$preparationEvidence=$null;if($r.Context.PSObject.Properties['PreparationEvidence']){$preparationEvidence=$r.Context.PreparationEvidence};Assert-WsmPreparationEvidence $preparationEvidence}
        if($r.Type -eq 'Preparation'){$hasSoftware=($r.ProviderSoftwareId -match '^sw-[a-f0-9]{32}$');$hasProviderItem=([bool]$r.ProviderItemId);if($hasSoftware -eq $hasProviderItem -or $r.ExternalId){throw 'Preparation requirement must identify exactly one provider SoftwareId or ItemId.'};if($hasSoftware -and -not $softwareEntryIds.ContainsKey($r.ProviderSoftwareId)){throw 'Preparation requirement references a SoftwareId absent from the source SoftwareCatalog.'}}
        if($r.Type -eq 'ExternalDependency' -and (-not $r.ExternalId -or $r.ProviderSoftwareId -or $r.ProviderItemId)){throw 'External dependency must identify an external provider.'}
        if($r.ProviderItemId -and -not $itemIds.ContainsKey($r.ProviderItemId)){throw 'Requirement references unknown provider ItemId.'}
        if(-not @($r.ConsumerItemIds).Count){throw 'Typed requirement must have at least one consumer.'}
        foreach($id in $r.ConsumerItemIds){if(-not $itemIds.ContainsKey($id)){throw 'Requirement references unknown consumer ItemId.'}}
        if(-not $r.SourceProof -or -not $r.SourceProof.PSObject.Properties['InventoryHash'] -or $r.SourceProof.InventoryHash -ine $Catalog.InventoryHash -or @($r.SourceProof.PSObject.Properties).Count -lt 2){throw 'Typed requirement needs current source inventory proof and source-specific evidence.'}
        if($r.Decision -ne 'Pending' -and (-not $r.DecisionReason -or -not $r.DecisionEvidence)){throw 'Owner dependency decisions require reason and independent evidence.'}
    }
    foreach($receipt in @($g.EvidenceReceipts)){Assert-WsmGeneralHostReceipt $receipt $Catalog -StructureOnly}
    foreach($item in @($Catalog.Items)){if($item.PSObject.Properties['GeneralHostOverride']){$d=$item.GeneralHostOverride;if(@('Disposition','Owner','Reason','Evidence','SourceHash','Utc') | Where-Object { -not $d.PSObject.Properties[$_] } | Select-Object -First 1){throw 'GeneralHost owner disposition record is incomplete.'};if(@('Migrate','Prepare','External','NotNeeded') -cnotcontains $d.Disposition -or -not $d.Owner -or -not $d.Reason -or -not $d.Evidence -or $d.SourceHash -notmatch '^[a-f0-9]{64}$'){throw 'Invalid GeneralHost owner disposition.'}}}
    $true
}

function Assert-WsmGeneralHostReceipt($Receipt,$Catalog,[switch]$StructureOnly,[string]$TargetFingerprint,[string]$PlanHash) {
    $allowed=@('SchemaVersion','ReceiptId','PairId','SourceFingerprint','TargetFingerprint','InventoryHash','ToolFingerprint','Context','RequirementIds','RequirementProjectionHash','Phase','EvidenceKind','EvidencePathHash','Owner','ObservedUtc','ExpiresUtc','PlanHash')
    Assert-WsmFields $Receipt $allowed @('SchemaVersion','ReceiptId','PairId','SourceFingerprint','TargetFingerprint','InventoryHash','ToolFingerprint','Context','RequirementIds','RequirementProjectionHash','Phase','EvidenceKind','EvidencePathHash','Owner','ObservedUtc','ExpiresUtc')
    if($Receipt.SchemaVersion -ne 1 -or $Receipt.ReceiptId -notmatch '^[a-f0-9]{64}$' -or $Receipt.PairId -cne $Catalog.PairId -or $Receipt.SourceFingerprint -cne $Catalog.Source.Fingerprint -or $Receipt.TargetFingerprint -notmatch '^[a-f0-9]{64}$' -or @('PreparationReady','StagedDependencyVerified','CutoverReady','FinalAccepted','RetirementReady') -cnotcontains $Receipt.Phase -or @('OwnerReadback','NativeReadback','ExternalOwner') -cnotcontains $Receipt.EvidenceKind -or $Receipt.EvidencePathHash -notmatch '^[a-f0-9]{64}$' -or $Receipt.ToolFingerprint -notmatch '^[a-f0-9]{64}$' -or $Receipt.RequirementProjectionHash -notmatch '^[a-f0-9]{64}$' -or $null -eq $Receipt.Context -or -not $Receipt.Owner){throw 'Invalid GeneralHost evidence receipt.'}
    if($Receipt.EvidenceKind -eq 'ExternalOwner' -and $Receipt.Phase -notin @('CutoverReady','FinalAccepted','RetirementReady')){throw 'External business evidence is only valid at a consumer or later phase.'}
    if(-not $StructureOnly){
        $now=[DateTime]::UtcNow;$observed=[DateTime]::Parse([string]$Receipt.ObservedUtc).ToUniversalTime();$expires=[DateTime]::Parse([string]$Receipt.ExpiresUtc).ToUniversalTime();if($expires -le $now -or $observed -gt $now.AddMinutes(5) -or $expires -le $observed){throw 'GeneralHost evidence is expired or has an invalid time window.'}
        if($TargetFingerprint -and $Receipt.TargetFingerprint -cne $TargetFingerprint){throw 'GeneralHost evidence target fingerprint mismatch.'}
        if($Receipt.ToolFingerprint -ine (Get-WsmToolFingerprint)){throw 'GeneralHost evidence tool fingerprint mismatch.'}
        if($Receipt.InventoryHash -ine $Catalog.InventoryHash){throw 'GeneralHost evidence source projection is stale.'}
        $requirements=@($Catalog.GeneralHost.Requirements | Where-Object RequirementId -In $Receipt.RequirementIds)
        if($requirements.Count -ne @($Receipt.RequirementIds).Count){throw 'Evidence references an unknown requirement.'}
        $expected=Get-WsmGeneralHostProjectionHash $Catalog @($requirements | ForEach-Object { $_.ConsumerItemIds } | Sort-Object -Unique) @($Receipt.RequirementIds) $Receipt.Phase
        if($expected -ine $Receipt.RequirementProjectionHash){throw 'GeneralHost evidence requirement projection is stale.'}
        if($PlanHash -and $Receipt.PlanHash -and $Receipt.PlanHash -ine $PlanHash){throw 'GeneralHost evidence plan binding is stale.'}
    }
    $true
}

function Get-WsmGeneralHostEvidencePath([string]$Workspace,[string]$PairId) {
    Assert-WsmId $PairId
    Join-Path (Join-Path $Workspace 'pairs') ($PairId+'.generalhost-evidence.json')
}

function Read-WsmGeneralHostEvidenceReferences([object[]]$References,$Catalog) {
    $receipts=New-Object System.Collections.Generic.List[object]
    foreach($reference in @($References)){
        Assert-WsmFields $reference @('Path','SHA256') @('Path','SHA256')
        $data=Read-WsmTrustedJson ([string]$reference.Path) ([string]$reference.SHA256)
        if($data.PSObject.Properties['Kind'] -and $data.Kind -ceq 'GeneralHostEvidenceSet'){
            Assert-WsmFields $data @('SchemaVersion','ToolVersion','Kind','PairId','SourceFingerprint','Receipts') @('SchemaVersion','Kind','PairId','SourceFingerprint','Receipts')
            if($data.SchemaVersion -ne 1 -or $data.PairId -cne $Catalog.PairId -or $data.SourceFingerprint -cne $Catalog.Source.Fingerprint){throw 'GeneralHost evidence set pair/source binding mismatch.'}
            foreach($r in @($data.Receipts)){$receipts.Add($r)}
        } else {$receipts.Add($data)}
    }
    @($receipts.ToArray())
}

function Get-WsmGeneralHostIssues($Catalog,[ValidateSet('ReviewComplete','PreparationReady','RestoreReady','StagedDependencyVerified','CutoverReady','FinalAccepted','RetirementReady')][string]$Phase='ReviewComplete',[string]$TargetFingerprint,[string]$Context='',[string]$PlanHash='',[object[]]$TrustedEvidence=@()) {
    # Read-only projections must still evaluate under caller -WhatIf.
    $WhatIfPreference=$false
    $g=Get-WsmGeneralHostContract $Catalog
    $issues=New-Object 'System.Collections.Generic.List[object]'
    if(-not $g.SoftwareCatalog){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId='';Gate=$Phase;Issue='Complete source SoftwareCatalog and coverage are required.'});return $issues.ToArray()}
    try{Assert-WsmGeneralHostSoftwareCatalog $g.SoftwareCatalog $Catalog | Out-Null}catch{$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId='';Gate=$Phase;Issue='SoftwareCatalog source binding or schema is invalid.'});return $issues.ToArray()}
    foreach($softwareDecision in @($g.SoftwareDecisions | Where-Object {$_.Disposition -cin @('Reinstall','Portable','KeepCompatible')})){
        $entry=@($g.SoftwareCatalog.Entries | Where-Object SoftwareId -CEQ $softwareDecision.SoftwareId)
        $linkedConsumers=@($g.Requirements | Where-Object ProviderSoftwareId -CEQ $softwareDecision.SoftwareId | ForEach-Object {$_.ConsumerItemIds});if($entry.Count){$linkedConsumers+=@($entry[0].ItemIds)}
        foreach($consumer in @($Catalog.Items | Where-Object {$_.Decision -ceq 'Include' -and $linkedConsumers -contains $_.ItemId})){
            $preparation=@($g.Requirements | Where-Object {$_.ProviderSoftwareId -ceq $softwareDecision.SoftwareId -and $_.RequiredPhase -ceq 'PreparationReady' -and $_.Certainty -ceq 'Required' -and $_.ConsumerItemIds -contains $consumer.ItemId})
            if(-not $preparation.Count){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId=$consumer.ItemId;Gate=$Phase;Issue=('Required software needs a separate PreparationReady requirement: '+$softwareDecision.SoftwareId)})}
        }
    }
    if($Phase -eq 'ReviewComplete'){
        $softwareIds=@{};foreach($entry in @($g.SoftwareCatalog.Entries)){$softwareIds[$entry.SoftwareId]=$true;$dec=@($g.SoftwareDecisions | Where-Object SoftwareId -CEQ $entry.SoftwareId);$entryHash=Get-WsmGeneralHostSoftwareFactsHash $entry;if($dec.Count -ne 1 -or $dec[0].SoftwareHash -cne $entryHash -or $dec[0].Disposition -eq 'Unknown' -or ((Test-WsmGeneralHostSpecialSoftware $entry) -and $dec[0].Disposition -notin @('External','NotNeeded'))){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId='';Gate=$Phase;Issue=('Software requires an allowed current owner disposition: '+$entry.SoftwareId)})}}
        foreach($dec in @($g.SoftwareDecisions)){if(-not $softwareIds.ContainsKey($dec.SoftwareId)){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId='';Gate=$Phase;Issue=('Software disposition references missing SoftwareId: '+$dec.SoftwareId)})}}
        foreach($item in @($Catalog.Items)){
            if($item.Decision -eq 'Pending'){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId=$item.ItemId;Gate=$Phase;Issue='Every discovered object needs a reviewed disposition.'})}
            if($item.Decision -ne 'Pending' -and (-not $item.PSObject.Properties['GeneralHostOverride'] -or -not $item.GeneralHostOverride.Owner -or -not $item.GeneralHostOverride.Reason -or -not $item.GeneralHostOverride.Evidence)){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId=$item.ItemId;Gate=$Phase;Issue='Every object decision requires owner, reason and evidence.'})}
            if($item.Decision -eq 'Include' -and $item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -eq 'SpecialProduct'){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId=$item.ItemId;Gate=$Phase;Issue='Special server products and roles cannot be automatically included.'})}
            if($item.Decision -eq 'Include' -and $item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -eq 'Preparation'){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId=$item.ItemId;Gate=$Phase;Issue='Runtime, client, driver and role preparation cannot be installed by this migration plan.'})}
            if($item.Decision -eq 'Include' -and $item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -eq 'Unknown' -and (-not $item.GeneralHostOverride -or $item.GeneralHostOverride.Disposition -cne 'Migrate')){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId=$item.ItemId;Gate=$Phase;Issue='Unknown classification requires explicit Migrate owner disposition.'})}
        }
        foreach($r in $g.Requirements){if($r.Decision -eq 'Pending' -or ($r.Certainty -eq 'Candidate' -and -not $r.DecisionReason)){$issues.Add([pscustomobject]@{RequirementId=$r.RequirementId;ConsumerItemId=(@($r.ConsumerItemIds)[0]);Gate=$Phase;Issue='Typed dependency requires an owner decision and evidence.'})}}
        foreach($r in @($g.OrphanedRequirements)){$issues.Add([pscustomobject]@{RequirementId=[string]$r.RequirementId;ConsumerItemId='';Gate=$Phase;Issue='Source refresh detached a dependency relation; owner must re-review its consumers.'})}
        foreach($candidate in @($g.SoftwareCatalog.PreparationRequirements | Where-Object Status -EQ 'NeedsOwnerReview')){if(@($candidate.ConsumerItemIds).Count){$linked=@($g.Requirements | Where-Object {$_.ProviderSoftwareId -ceq $candidate.SoftwareId -and (@($_.ConsumerItemIds | Where-Object {$candidate.ConsumerItemIds -contains $_}).Count -gt 0)});if(-not $linked.Count){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId=(@($candidate.ConsumerItemIds | Select-Object -First 1));Gate=$Phase;Issue=('Software preparation candidate needs an owner decision: '+$candidate.PreparationId)})}}}
        foreach($coverage in @($g.SoftwareCatalog.Coverage)){if($coverage.Status -notin @('Success','NotInstalled')){$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId='';Gate=$Phase;Issue=('Software discovery coverage is incomplete: '+$coverage.Probe+' '+$coverage.Scope+' '+$coverage.SID)})}}
        return $issues.ToArray()
    }
    $phaseRank=@{PreparationReady=0;RestoreReady=1;StagedDependencyVerified=2;CutoverReady=3;FinalAccepted=4;RetirementReady=5}
    $required=@($g.Requirements | Where-Object {$_.Decision -ne 'NotNeeded' -and $phaseRank[$_.RequiredPhase] -le $phaseRank[$Phase] -and $_.Decision -ne 'Pending'})
    foreach($r in @($g.Requirements | Where-Object {$_.Decision -eq 'Pending' -and $phaseRank[$_.RequiredPhase] -le $phaseRank[$Phase]})){$issues.Add([pscustomobject]@{RequirementId=$r.RequirementId;ConsumerItemId=(@($r.ConsumerItemIds)[0]);Gate=$Phase;Issue='Required dependency decision is unresolved.'})}
    foreach($r in @($g.Requirements | Where-Object {$_.Decision -eq 'NotNeeded' -and $_.Certainty -eq 'Required' -and $phaseRank[$_.RequiredPhase] -le $phaseRank[$Phase]})){foreach($consumerId in $r.ConsumerItemIds){$issues.Add([pscustomobject]@{RequirementId=$r.RequirementId;ConsumerItemId=$consumerId;Gate=$Phase;Issue='Owner marked a required dependency NotNeeded; this does not satisfy the consumer gate.'})}}
    $consumerIds=@($required | ForEach-Object { $_.ConsumerItemIds } | Sort-Object -Unique)
    $runtimeReceipts=@();try{$runtimeReceipts=@(Read-WsmGeneralHostEvidenceReferences $TrustedEvidence $Catalog)}catch{$issues.Add([pscustomobject]@{RequirementId='';ConsumerItemId='';Gate=$Phase;Issue='Trusted GeneralHost evidence file or hash is invalid.'})};$allReceipts=@($g.EvidenceReceipts)+@($runtimeReceipts)
    foreach($consumerId in $consumerIds){
        $consumerReq=@($required | Where-Object {$_.ConsumerItemIds -contains $consumerId})
        foreach($r in $consumerReq){
            if($r.ProviderSoftwareId -and ($r.ExpectedVersion -match '^(?i:unknown|notTested|unspecified)$' -or $r.Architecture -match '^(?i:unknown|notTested|unspecified)$')){$issues.Add([pscustomobject]@{RequirementId=$r.RequirementId;ConsumerItemId=$consumerId;Gate=$Phase;Issue='Required software version or architecture is unknown; owner evidence cannot substitute an unresolved expectation.'});continue}
            $covered=$false
            $requiredContextHash=Get-WsmGeneralHostContextHash $r.Context
            foreach($receipt in @($allReceipts | Where-Object {$_.Phase -ceq $r.RequiredPhase -and $_.TargetFingerprint -ceq $TargetFingerprint -and (Get-WsmGeneralHostContextHash $_.Context) -ceq $requiredContextHash -and $_.RequirementIds -contains $r.RequirementId})){
                try{Assert-WsmGeneralHostReceipt $receipt $Catalog -TargetFingerprint $TargetFingerprint -PlanHash $PlanHash | Out-Null;if($r.Type -eq 'ExternalDependency' -and $receipt.EvidenceKind -ne 'ExternalOwner'){continue};$covered=$true;break}catch{}
            }
            if(-not $covered){$issues.Add([pscustomobject]@{RequirementId=$r.RequirementId;ConsumerItemId=$consumerId;Gate=$Phase;Issue=('Missing or stale '+$r.RequiredPhase+' evidence for '+$r.Type+' requirement.')})}
        }
    }
    $issues.ToArray()
}

function Get-WsmGeneralHostReadinessProjection($Catalog,[string]$TargetFingerprint,[string]$Context='',[string]$PlanHash='',[object[]]$TrustedEvidence=@()) {
    # Read-only projections must still evaluate under caller -WhatIf.
    $WhatIfPreference=$false
    $phases=@('ReviewComplete','PreparationReady','RestoreReady','StagedDependencyVerified','CutoverReady','FinalAccepted','RetirementReady')
    $pending=New-Object 'System.Collections.Generic.List[object]';$phaseRows=New-Object 'System.Collections.Generic.List[object]'
    foreach($phase in $phases){$issues=@();if($phase -eq 'ReviewComplete'){$issues=@(Get-WsmGeneralHostIssues $Catalog ReviewComplete)}else{$issues=@(Get-WsmGeneralHostIssues $Catalog $phase $TargetFingerprint $Context $PlanHash $TrustedEvidence)};foreach($issue in $issues){$pending.Add([pscustomobject]@{Gate=$phase;RequirementId=[string]$issue.RequirementId;ConsumerItemId=[string]$issue.ConsumerItemId;Issue=[string]$issue.Issue})};$hash='';try{$hash=Get-WsmGeneralHostProjectionHash $Catalog @() @() $phase}catch{};$phaseRows.Add([pscustomobject]@{Phase=$phase;ProjectionHash=$hash;PendingIssueCount=$issues.Count;Ready=($issues.Count -eq 0)})}
    $g=Get-WsmGeneralHostContract $Catalog
    [pscustomobject][ordered]@{PairId=[string]$Catalog.PairId;ScopeMode='GeneralHost';SourceFingerprint=[string]$Catalog.Source.Fingerprint;InventoryHash=[string]$Catalog.InventoryHash;SoftwareCatalogHash=[string]$g.SoftwareCatalogHash;TargetFingerprint=$TargetFingerprint;PlanHash=$PlanHash;DecisionRevision=[int]$Catalog.DecisionRevision;Phases=$phaseRows.ToArray();PendingIssues=$pending.ToArray();ProductionVerified=$false}
}

function Set-WsmGeneralHostMode {
    param([string]$Workspace,[string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision)
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; refresh before selecting GeneralHost mode.'}
        if($c.PSObject.Properties['GeneralHost']){if($c.GeneralHost.ScopeMode -cne 'GeneralHost'){throw 'Catalog already has an incompatible scope mode.'};return $c}
        $software=$null;$softwareHash='';if($c.PSObject.Properties['SoftwareCatalog']){$software=$c.SoftwareCatalog;$softwareHash=Get-WsmHashText ($software | ConvertTo-Json -Depth 30 -Compress)};$c.SchemaVersion=2;$c | Add-Member NoteProperty GeneralHost ([pscustomobject][ordered]@{SchemaVersion=1;ScopeMode='GeneralHost';SoftwareCatalog=$software;SoftwareCatalogHash=$softwareHash;SoftwareDecisions=@();Requirements=@();OrphanedRequirements=@();EvidenceReceipts=@();UpdatedUtc=(Get-WsmUtc)})
        $c.DecisionRevision++;$c.Approval=$null;$c.History=@($c.History)+@([pscustomobject]@{Revision=$c.DecisionRevision;Action='ScopeMode';ScopeMode='GeneralHost';Utc=(Get-WsmUtc)})
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c;$c
    }
}

function Set-WsmGeneralHostSoftwareCatalog {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[Parameter(Mandatory)][int]$ExpectedRevision)
    $snapshot=Read-WsmFileSnapshot $Path $ExpectedHash;$software=ConvertFrom-WsmJson $snapshot.Text
    Invoke-WsmLocked $Workspace {$c=Get-WsmCatalog $Workspace $PairId;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; preview current software catalog and retry.'};$g=Get-WsmGeneralHostContract $c;Assert-WsmGeneralHostSoftwareCatalog $software $c;$g.SoftwareCatalog=$software;$g.SoftwareCatalogHash=Get-WsmHashText ($software | ConvertTo-Json -Depth 30 -Compress);$c | Add-Member NoteProperty SoftwareCatalog $software -Force;$g.SoftwareDecisions=@($g.SoftwareDecisions | Where-Object {$d=$_;$entry=@($software.Entries | Where-Object SoftwareId -CEQ $d.SoftwareId);$entry.Count -eq 1 -and $d.SoftwareHash -ceq (Get-WsmGeneralHostSoftwareFactsHash $entry[0])});$g.UpdatedUtc=Get-WsmUtc;$g.EvidenceReceipts=@($g.EvidenceReceipts | Where-Object {$receipt=$_;$req=@($g.Requirements | Where-Object RequirementId -In $receipt.RequirementIds);$consumers=@($req | ForEach-Object { $_.ConsumerItemIds } | Sort-Object -Unique);$receipt.InventoryHash -ceq $c.InventoryHash -and $req.Count -eq @($receipt.RequirementIds).Count -and $receipt.RequirementProjectionHash -ceq (Get-WsmGeneralHostProjectionHash $c $consumers @($receipt.RequirementIds) $receipt.Phase)});Assert-WsmGeneralHostContract $c | Out-Null;$c.DecisionRevision++;$c.Approval=$null;$c.History=@($c.History)+@([pscustomobject]@{Revision=$c.DecisionRevision;Action='SoftwareCatalog';SourceHash=$snapshot.Hash;Utc=(Get-WsmUtc)});Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c;$c}
}

function Get-WsmGeneralHostDispositionPreview {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[Parameter(Mandatory)][int]$ExpectedRevision)
    $snapshot=Read-WsmFileSnapshot $Path $ExpectedHash;$doc=ConvertFrom-WsmJson $snapshot.Text;Assert-WsmFields $doc @('Dispositions') @('Dispositions');$c=Get-WsmCatalog $Workspace $PairId;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; refresh before disposition preview.'};$seen=@{};$rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($d in @($doc.Dispositions)){
        Assert-WsmFields $d @('ItemId','SoftwareId','ScopeDisposition','Owner','Reason','Evidence') @('ScopeDisposition','Owner','Reason','Evidence')
        $itemId='';$softwareId='';if($d.PSObject.Properties['ItemId']){$itemId=[string]$d.ItemId};if($d.PSObject.Properties['SoftwareId']){$softwareId=[string]$d.SoftwareId};if([bool]$itemId -eq [bool]$softwareId){throw 'Disposition must identify exactly one ItemId or SoftwareId.'};$key=$itemId;if($softwareId){$key=$softwareId};if(-not $key -or $seen.ContainsKey($key)){throw 'Disposition must identify one unique ItemId or SoftwareId.'};$seen[$key]=$true;if(@('Migrate','Prepare','External','NotNeeded','Reinstall','Portable','KeepCompatible','Unknown') -cnotcontains $d.ScopeDisposition -or -not $d.Owner -or -not $d.Reason -or -not $d.Evidence){throw 'Disposition requires a valid choice, owner, reason and evidence.'}
        if($softwareId){if($d.ScopeDisposition -in @('Migrate','Prepare')){throw 'Software handling must select Reinstall, Portable, KeepCompatible, External, NotNeeded or Unknown.'};$g=Get-WsmGeneralHostContract $c;$entries=@($g.SoftwareCatalog.Entries | Where-Object SoftwareId -CEQ $softwareId);if($entries.Count -ne 1){throw 'Unknown SoftwareId.'};if((Test-WsmGeneralHostSpecialSoftware $entries[0]) -and $d.ScopeDisposition -notin @('External','NotNeeded')){throw 'Database engines and special products require external product handling.'};$rows.Add([pscustomobject][ordered]@{SoftwareId=$softwareId;SoftwareHash=(Get-WsmGeneralHostSoftwareFactsHash $entries[0]);ScopeDisposition=$d.ScopeDisposition;Owner=$d.Owner;Reason=$d.Reason;Evidence=$d.Evidence});continue}
        if(-not $itemId){throw 'Disposition must identify an ItemId or SoftwareId.'};if($d.ScopeDisposition -in @('Reinstall','Portable','KeepCompatible','Unknown')){throw 'Item disposition must select Migrate, Prepare, External or NotNeeded.'};$matches=@($c.Items | Where-Object ItemId -CEQ $itemId);if($matches.Count -ne 1){throw 'Unknown disposition ItemId.'};$item=$matches[0];if($item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -eq 'SpecialProduct' -and $d.ScopeDisposition -eq 'Migrate'){throw 'Special server products cannot be selected for automatic migration.'};if($item.PSObject.Properties['Classification'] -and $item.Classification.Disposition -eq 'Preparation' -and $d.ScopeDisposition -eq 'Migrate'){throw 'Runtime, client, driver and role preparation is manual; choose Prepare.'};$decision='Exclude';if($d.ScopeDisposition -eq 'Migrate'){$decision='Pending'}
        $rows.Add([pscustomobject][ordered]@{ItemId=$d.ItemId;Decision=$decision;ScopeDisposition=$d.ScopeDisposition;Owner=$d.Owner;Reason=$d.Reason;Evidence=$d.Evidence})
    }
    [pscustomobject][ordered]@{PairId=$PairId;DecisionRevision=$ExpectedRevision;SourceHash=$snapshot.Hash;Rows=@($rows.ToArray())}
}

function Set-WsmGeneralHostDispositions {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[Parameter(Mandatory)][int]$ExpectedRevision,[string]$ExpectedPreviewHash)
    $preview=Get-WsmGeneralHostDispositionPreview $Workspace $PairId $Path $ExpectedHash $ExpectedRevision;if($ExpectedPreviewHash -ine (Get-WsmHashText ($preview | ConvertTo-Json -Depth 20 -Compress))){throw 'Disposition preview hash mismatch.'}
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed after disposition preview.'};$g=Get-WsmGeneralHostContract $c;$index=@{};foreach($i in $c.Items){$index[$i.ItemId]=$i}
        foreach($row in $preview.Rows){$softwareId='';$itemId='';if($row.PSObject.Properties['SoftwareId']){$softwareId=[string]$row.SoftwareId};if($row.PSObject.Properties['ItemId']){$itemId=[string]$row.ItemId};if($softwareId){$g.SoftwareDecisions=@($g.SoftwareDecisions | Where-Object SoftwareId -CNE $softwareId)+@([pscustomobject]@{SoftwareId=$softwareId;SoftwareHash=$row.SoftwareHash;Disposition=$row.ScopeDisposition;Owner=$row.Owner;Reason=$row.Reason;Evidence=$row.Evidence;SourceHash=$preview.SourceHash});continue};if(-not $itemId -or -not $index.ContainsKey($itemId)){throw 'Disposition preview item identity is missing.'};$i=$index[$itemId];$i.Decision=$row.Decision;$i.Reason=$row.Reason;$i.Owner=$row.Owner;$i.Evidence=$row.Evidence;$i.ReviewedBy=[Environment]::UserName;$i.ReviewedUtc=Get-WsmUtc;$i | Add-Member NoteProperty GeneralHostOverride ([pscustomobject]@{Disposition=$row.ScopeDisposition;Owner=$row.Owner;Reason=$row.Reason;Evidence=$row.Evidence;SourceHash=$preview.SourceHash;Utc=(Get-WsmUtc)}) -Force}
        $g.UpdatedUtc=Get-WsmUtc;Assert-WsmGeneralHostContract $c | Out-Null;$c.DecisionRevision++;$c.Approval=$null;$historyItems=@($preview.Rows | ForEach-Object {$id='';if($_.PSObject.Properties['ItemId']){$id=[string]$_.ItemId};if(-not $id -and $_.PSObject.Properties['SoftwareId']){$id=[string]$_.SoftwareId};$id});$c.History=@($c.History)+@([pscustomobject]@{Revision=$c.DecisionRevision;Action='GeneralHostDispositions';SourceHash=$preview.SourceHash;PreviewHash=$ExpectedPreviewHash;Items=$historyItems;Utc=(Get-WsmUtc)});Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c;$c
    }
}

function Get-WsmGeneralHostPreviewHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Preview,[Parameter(Mandatory)][ValidateSet('Disposition','Requirement')][string]$Kind)
    $rowField='Rows';$depth=20;if($Kind -ceq 'Requirement'){$rowField='Requirements';$depth=25}
    $allowed=@('PairId','DecisionRevision','SourceHash',$rowField);if($Kind -ceq 'Requirement'){$allowed+=@('Existing','Proposed','Changed')}
    Assert-WsmFields $Preview $allowed @('PairId','DecisionRevision','SourceHash',$rowField)
    Assert-WsmId ([string]$Preview.PairId)
    if($Preview.SourceHash -notmatch '^[a-fA-F0-9]{64}$' -or $Preview.DecisionRevision -lt 0){throw 'Invalid review preview binding.'}
    Get-WsmHashText ($Preview | ConvertTo-Json -Depth $depth -Compress)
}

function Get-WsmGeneralHostRequirementPreview {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[Parameter(Mandatory)][int]$ExpectedRevision)
    $snapshot=Read-WsmFileSnapshot $Path $ExpectedHash;$doc=ConvertFrom-WsmJson $snapshot.Text;Assert-WsmFields $doc @('Requirements') @('Requirements');$c=Get-WsmCatalog $Workspace $PairId;$g=Get-WsmGeneralHostContract $c;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; refresh before requirement preview.'};$before=@($g.Requirements);$new=@($doc.Requirements)
    foreach($r in $new){if(-not $r.PSObject.Properties['RequirementId']){throw 'RequirementId is required and must be stable.'};foreach($f in @('Type','ProviderSoftwareId','ProviderItemId','ExternalId','ConsumerItemIds','Certainty','RequiredPhase','ExpectedVersion','Architecture','Context','Owner','SourceProof','Decision','DecisionReason','DecisionEvidence')){if(-not $r.PSObject.Properties[$f]){throw ('Requirement missing '+$f)}};if($r.RequirementId -cne (Get-WsmGeneralHostRequirementId $r)){throw 'RequirementId does not match its stable relation identity.'};if(-not $r.SourceProof.PSObject.Properties['InventoryHash'] -or $r.SourceProof.InventoryHash -ine $c.InventoryHash -or @($r.SourceProof.PSObject.Properties).Count -lt 2){throw 'Requirement source proof must bind the current inventory hash and include source-specific evidence.'}}
    $candidate=ConvertFrom-WsmJson ($c | ConvertTo-Json -Depth 40 -Compress);$candidate.GeneralHost.Requirements=$new;Assert-WsmGeneralHostContract $candidate | Out-Null
    [pscustomobject]@{PairId=$PairId;DecisionRevision=$ExpectedRevision;SourceHash=$snapshot.Hash;Existing=@($before).Count;Proposed=@($new).Count;Changed=($before | ConvertTo-Json -Depth 20 -Compress) -cne ($new | ConvertTo-Json -Depth 20 -Compress);Requirements=$new}
}

function Set-WsmGeneralHostRequirements {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[Parameter(Mandatory)][int]$ExpectedRevision,[string]$ExpectedPreviewHash)
    $preview=Get-WsmGeneralHostRequirementPreview $Workspace $PairId $Path $ExpectedHash $ExpectedRevision;if($ExpectedPreviewHash -ine (Get-WsmHashText ($preview | ConvertTo-Json -Depth 25 -Compress))){throw 'Requirement preview hash mismatch.'}
    Invoke-WsmLocked $Workspace {$c=Get-WsmCatalog $Workspace $PairId;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed after requirement preview.'};$g=Get-WsmGeneralHostContract $c;$g.Requirements=@($preview.Requirements);$g.OrphanedRequirements=@();$g.UpdatedUtc=Get-WsmUtc;$g.EvidenceReceipts=@($g.EvidenceReceipts | Where-Object {$_.RequirementProjectionHash -ceq (Get-WsmGeneralHostProjectionHash $c @() @($_.RequirementIds) $_.Phase)});Assert-WsmGeneralHostContract $c | Out-Null;$c.DecisionRevision++;$c.Approval=$null;$c.History=@($c.History)+@([pscustomobject]@{Revision=$c.DecisionRevision;Action='GeneralHostRequirements';SourceHash=$preview.SourceHash;PreviewHash=$ExpectedPreviewHash;Utc=(Get-WsmUtc)});Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c;$c}
}

function Import-WsmGeneralHostEvidence {
    param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$ExpectedTargetFingerprint,[string]$ExpectedPlanHash='')
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or $ExpectedTargetFingerprint -notmatch '^[a-f0-9]{64}$'){throw 'Independent evidence file hash and target fingerprint are required.'}
    $snapshot=Read-WsmFileSnapshot $Path $ExpectedHash;$receipt=ConvertFrom-WsmJson $snapshot.Text
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId;if($c.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; evidence import preview is stale.'};$g=Get-WsmGeneralHostContract $c
        if($receipt.TargetFingerprint -cne $ExpectedTargetFingerprint){throw 'Evidence target fingerprint differs from the independently supplied target binding.'}
        Assert-WsmGeneralHostReceipt $receipt $c -TargetFingerprint $ExpectedTargetFingerprint -PlanHash $ExpectedPlanHash
        if($c.Approval -and $c.Approval.Kind -ceq 'MigrationPlan'){
            if(-not $ExpectedPlanHash -or $ExpectedPlanHash -ine $c.Approval.Hash -or $receipt.PlanHash -ine $ExpectedPlanHash){throw 'Postapproval evidence must bind the current approved plan hash.'}
            $evidencePath=Get-WsmGeneralHostEvidencePath $Workspace $PairId;$set=$null
            if([IO.File]::Exists($evidencePath)){$set=Read-WsmJson $evidencePath;if($set.PairId -cne $PairId -or $set.SourceFingerprint -cne $c.Source.Fingerprint){throw 'Existing GeneralHost evidence set binding mismatch.'}}
            else{$set=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='GeneralHostEvidenceSet';PairId=$PairId;SourceFingerprint=$c.Source.Fingerprint;Receipts=@()}}
            if(@($set.Receipts | Where-Object ReceiptId -CEQ $receipt.ReceiptId).Count){throw 'ReceiptId already exists; evidence receipts are append-only.'}
            $set.Receipts=@($set.Receipts)+@($receipt);Write-WsmJson $evidencePath $set
            return [pscustomobject]@{Path=[IO.Path]::GetFullPath($evidencePath);SHA256=(Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant();Receipt=$receipt;ApprovalPreserved=$true}
        }
        if(@($g.EvidenceReceipts | Where-Object ReceiptId -CEQ $receipt.ReceiptId).Count){throw 'ReceiptId already exists; evidence receipts are append-only.'}
        $g.EvidenceReceipts=@($g.EvidenceReceipts)+@($receipt);$g.UpdatedUtc=Get-WsmUtc;$c.DecisionRevision++;$c.Approval=$null;$c.History=@($c.History)+@([pscustomobject]@{Revision=$c.DecisionRevision;Action='GeneralHostEvidence';ReceiptId=$receipt.ReceiptId;EvidenceHash=$snapshot.Hash;Utc=(Get-WsmUtc)});Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
        [pscustomobject]@{Receipt=$receipt;ApprovalPreserved=$false}
    }
}
