# Local console transport. Commands and journal authority remain in the module.
function Get-WsmHtmlActionMap {
    $map=Get-WsmOperationActions
    foreach($entry in @(
        @('Initialize','Initialize-WsmWorkspace'),@('Inventory','Export-WsmInventory'),@('ImportInventory','Import-WsmInventory'),
        @('Items','Get-WsmItems'),@('ReviewIssues','Get-WsmReviewIssues'),@('Decision','Set-WsmDecision'),
        @('Mapping','Set-WsmMapping'),@('Evidence','Set-WsmEvidence'),@('Dependencies','Set-WsmDependencies'),
        @('ManualItem','Add-WsmManualItem'),@('ReviewMetadata','Set-WsmReviewMetadata'),@('ReviewTemplate','Export-WsmReviewTemplate'),
        @('TemplatePreview','Get-WsmTemplatePreview'),@('ApplyTemplate','Invoke-WsmReviewTemplate'),@('Fleet','Get-WsmFleet'),
        @('PairPlan','Set-WsmPairPlan'),@('CrossHostDependency','Set-WsmCrossHostDependency'),@('Report','Export-WsmReport'),
        @('FleetReport','Export-WsmFleetReport'),@('SaveSelection','Set-WsmHtmlSelection'),@('SetRestoreChoice','Set-WsmHtmlRestoreChoice')
    )){$map[$entry[0]]=$entry[1]}
    foreach($entry in @(@('SpecReview','Get-WsmAssistiveSpecReview'),@('SaveSpecReview','Submit-WsmAssistiveSpecReview'),@('TargetReceipt','Export-WsmAssistiveTargetDecisionReceipt'),@('AssistiveReport','Export-WsmAssistiveReport'),@('SetSoftwareVersion','Set-WsmAssistiveSoftwareVersion'),@('TargetSnapshot','Update-WsmAssistiveTargetSnapshot'),@('PublishComparison','Update-WsmAssistiveComparison'),@('EnvironmentProbe','Export-WsmAssistiveEnvironmentProbe'),@('ProbeImport','Import-WsmAssistiveEnvironmentProbe'))){
        if(Get-Command $entry[1] -CommandType Function -ErrorAction SilentlyContinue){$map[$entry[0]]=$entry[1]}
    }
    $map
}

function Set-WsmHtmlSelection {
    param([string]$Workspace,[string]$PairId,[int]$ExpectedRevision,[string[]]$SelectedItemIds,$UnselectedItems,[Parameter(DontShow)]$ExpectedDecisionRevision=$null,[Parameter(DontShow)]$ExpectedSelectionRevision=$null,[Parameter(DontShow)][string]$ExpectedDataVersion='')
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Review changed.'}
        if($null -ne $ExpectedDecisionRevision -and [int]$catalog.DecisionRevision -ne [int]$ExpectedDecisionRevision){throw 'Review changed: decision revision.'}
        $currentSelectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision
        if($null -ne $ExpectedSelectionRevision -and $currentSelectionRevision -ne [int]$ExpectedSelectionRevision){throw 'Review changed: selection revision.'}
        if($ExpectedDataVersion -and (Get-WsmHtmlDataVersion $Workspace $PairId) -cne $ExpectedDataVersion){throw 'Review changed: data version.'}
        $ids=@{};foreach($id in $SelectedItemIds){if($ids.ContainsKey($id)){throw 'Duplicate selection.'};$ids[$id]=$true}
        $reasons=@{};foreach($row in @($UnselectedItems)){Assert-WsmFields $row @('itemId','reason') @('itemId','reason');if(-not $row.reason -or $ids.ContainsKey($row.itemId) -or $reasons.ContainsKey($row.itemId)){throw 'Invalid deselection reason.'};$reasons[$row.itemId]=[string]$row.reason}
        $known=@{};foreach($item in $catalog.Items){$known[$item.ItemId]=$true;if(-not $ids.ContainsKey($item.ItemId) -and -not $reasons.ContainsKey($item.ItemId)){throw 'Every discovery needs a selection or a reason.'}}
        foreach($id in @($ids.Keys)+@($reasons.Keys)){if(-not $known.ContainsKey($id)){throw 'Unknown item.'}}
        $current=Get-WsmAssistiveCurrentSelections $catalog
        $sealed=($catalog.Approval -and $catalog.Approval.PSObject.Properties['Kind'] -and $catalog.Approval.Kind -ceq 'MigrationPlan')
        if($sealed){foreach($id in $ids.Keys){$source=@($catalog.Assistive.Selections.Items | Where-Object ItemId -CEQ $id);$item=@($catalog.Items | Where-Object ItemId -CEQ $id);if($source.Count -ne 1 -or -not $source[0].Selected -or $item.Count -ne 1 -or $item[0].Decision -cne 'Include'){throw 'Target selection exceeds the sealed source approval.'}}}
        foreach($selection in $current.Items){$selection.Selected=$ids.ContainsKey($selection.ItemId);$selection.Reason=if($selection.Selected){''}else{$reasons[$selection.ItemId]};$selection.UpdatedUtc=Get-WsmUtc}
        $current.Revision++;Clear-WsmAssistiveComparison $catalog
        if($sealed){$catalog.Assistive | Add-Member NoteProperty TargetSelections $current -Force}else{$catalog.DecisionRevision++;$catalog.Approval=$null}
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        [pscustomobject]@{Status='Saved';Revision=$catalog.Assistive.Revision}
    }
}

function Set-WsmHtmlRestoreChoice {
    param([string]$Workspace,[string]$PairId,[int]$ExpectedRevision,[ValidateSet('RestoreNow','WaitForInstall')][string]$Choice,[Parameter(DontShow)]$ExpectedDecisionRevision=$null,[Parameter(DontShow)]$ExpectedSelectionRevision=$null,[Parameter(DontShow)][string]$ExpectedDataVersion='')
    $projection=Get-WsmAssistiveComparison $Workspace $PairId
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Review changed.'}
        if($null -ne $ExpectedDecisionRevision -and [int]$catalog.DecisionRevision -ne [int]$ExpectedDecisionRevision){throw 'Review changed: decision revision.'}
        $currentSelectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision
        if($null -ne $ExpectedSelectionRevision -and $currentSelectionRevision -ne [int]$ExpectedSelectionRevision){throw 'Review changed: selection revision.'}
        if($ExpectedDataVersion -and (Get-WsmHtmlDataVersion $Workspace $PairId) -cne $ExpectedDataVersion){throw 'Review changed: data version.'}
        if($projection.SourceSnapshotHash -ine $catalog.Assistive.SourceSnapshot.SHA256 -or -not $catalog.Assistive.TargetCurrent -or $projection.TargetSnapshotHash -ine $catalog.Assistive.TargetCurrent.SHA256 -or $projection.SelectionRevision -ne $catalog.Assistive.Selections.Revision){throw 'Review changed. Refresh target comparison.'}
        if(-not $catalog.Assistive.Comparison){$catalog.Assistive.Comparison=$projection;$catalog.Assistive.ComparisonRevisionCounter=$projection.Revision}
        $record=[pscustomobject]@{Choice=$Choice;ComparisonRevision=$catalog.Assistive.Comparison.Revision;SourceSnapshotHash=$catalog.Assistive.SourceSnapshot.SHA256;TargetSnapshotHash=$catalog.Assistive.TargetCurrent.SHA256;SelectionRevision=$catalog.Assistive.Selections.Revision;Owner=[Environment]::UserName;Actor=(Get-WsmExecutionActor);CreatedUtc=(Get-WsmUtc);ExecutionAuthorized=$false}
        $catalog.Assistive.RestoreDecisionHistory=@($catalog.Assistive.RestoreDecisionHistory)+@($record)
        $catalog.Assistive.Revision++;$catalog.Assistive.UpdatedUtc=Get-WsmUtc
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        [pscustomobject]@{Status=$Choice;Revision=$catalog.Assistive.Revision;ExecutionAuthorized=$false}
    }
}

function Get-WsmHtmlObjectSchema([string]$Name) {
    $schemas=@{
        UnselectedItems=@{itemId=@{type='string';required=$true};reason=@{type='string';required=$true}}
        Dependencies=@{ItemId=@{type='string';required=$true};Type=@{type='enum';options=@('Mandatory','Optional');required=$true};Evidence=@{type='string';required=$true}}
        Changes=@{ItemId=@{type='string';required=$true};Disposition=@{type='string';required=$true};Owner=@{type='string';required=$true};Evidence=@{type='string';required=$true};Reason=@{type='string'}}
        Credential=@{UserName=@{type='string';required=$true};Password=@{type='string';required=$true;sensitive=$true}}
    }
    $reference=@{Path=@{type='path';required=$true};SHA256=@{type='string';required=$true}}
    foreach($key in @('ReportReferences','GeneralHostEvidence','EnvironmentConfirmationReferences','DeliveryReceiptReferences','Receipts','AnchorReceipts','ExternalEvidenceReferences')){$schemas[$key]=$reference}
    $schemas.Members=@{PlanPath=@{type='path';required=$true};PlanHash=@{type='string';required=$true}}
    $schemas.Requirements=@{};foreach($key in @('Permissions','ConsistencyMethod','RebootBehavior','SideEffects','RollbackLevel')){$schemas.Requirements[$key]=@{type='string';required=$true}}
    $schemas.Evidence=@{EvidenceId=@{type='string';required=$true};Type=@{type='enum';required=$true;options=@('Fixture','RealFiles','ServerLab','IsolatedPilot','ProductionAcceptance')};Owner=@{type='string';required=$true};Reference=@{type='path';required=$true};ObservedUtc=@{type='string';required=$true};ExpiresUtc=@{type='string';required=$true};SHA256=@{type='string';required=$true}}
    $os=@{properties=@{Family=@{type='string';required=$true};Version=@{type='string';required=$true};Build=@{type='string';required=$true};Edition=@{type='string';required=$true};Architecture=@{type='enum';required=$true;options=@('x64','Arm64','x86')};InstallationType=@{type='string'}}}
    $schemas.Tuple=@{ToolFingerprint=@{type='string';required=$true};Adapter=@{type='string';required=$true};AdapterFingerprint=@{type='string';required=$true};Product=@{type='string';required=$true};ProductVersion=@{type='string';required=$true};Source=@{type='object';required=$true;schema=$os};Target=@{type='object';required=$true;schema=$os}}
    $runtime=@{properties=@{}};foreach($field in @('PowerShellVersion','Edition','ProcessArchitecture','LanguageMode','CLRVersion','DotNetFrameworkRelease')){$runtime.properties[$field]=@{type='string';required=$true}}
    foreach($field in @('SourceProductVersion','TargetProductVersion')){$schemas.Tuple[$field]=@{type='string'}}
    $schemas.Tuple.Runtime=@{type='object';schema=@{properties=@{Source=@{type='object';required=$true;schema=$runtime};Target=@{type='object';required=$true;schema=$runtime}}}}
    $oracle=@{properties=@{}};foreach($field in @('Product','Version','Architecture','Context')){$oracle.properties[$field]=@{type='string';required=$true}}
    foreach($field in @('OracleProvider','OracleConsumer')){$schemas.Tuple[$field]=@{type='object';schema=$oracle}}
    $release=@{properties=@{}};foreach($field in @('ArchiveSHA256','SignatureSHA256','ToolFingerprint','SignerThumbprint','TrustPolicyHash')){$release.properties[$field]=@{type='string';required=$true}}
    $schemas.Tuple.ReleaseArtifact=@{type='object';schema=$release}
    $schemas.Secrets=@{Ref=@{type='string';required=$true};Kind=@{type='enum';required=$true;options=@('SecureString','Credential')};Value=@{type='string';sensitive=$true};UserName=@{type='string'};Password=@{type='string';sensitive=$true}}
    $schemas.Consumers=@{ProviderSoftwareId=@{type='string';required=$true};ProviderItemId=@{type='string'};Provider=@{type='string';required=$true};Version=@{type='string';required=$true};Architecture=@{type='enum';required=$true;options=@('x64','x86','Arm64','Unknown')};OracleHome=@{type='path';required=$true};AccountType=@{type='enum';required=$true;options=@('Machine','Local','Domain','Service','ManagedService','Unknown')};AccountName=@{type='string';required=$true};AccountSid=@{type='string';required=$true};ConsumerItemIds=@{type='stringArray';required=$true};ObservedEffectivePath=@{type='path';required=$true};ApprovedIFiles=@{type='stringArray';required=$true}}
    $schemas.ExternalActivatedReceipts=@{TrustedPath=@{type='path';required=$true};TrustedSHA256=@{type='string';required=$true}}
    $schemas.SourcePeerShareProofReferences=@{Path=@{type='path';required=$true};SHA256=@{type='string';required=$true};PeerFingerprint=@{type='string';required=$true}}
    $schemas.Entries=@{ItemId=@{type='string';required=$true};SourcePath=@{type='path';required=$true};TargetPath=@{type='path';required=$true};Channel=@{type='enum';options=@('C','NonC');required=$true};ConsumerRefs=@{type='stringArray';required=$true};AccountMap=@{type='map';required=$true}}
    $configFile=@{properties=@{RelativePath=@{type='path';required=$true};SHA256=@{type='string';required=$true};Owner=@{type='string';required=$true};Evidence=@{type='string';required=$true}}}
    $reviewValue=@{properties=@{FieldPointer=@{type='string';required=$true};Value=@{type='string';required=$true;allowEmpty=$true}}}
    $bindings=@{properties=@{Index=@{type='integer';required=$true};Protocol=@{type='string';required=$true};BindingInformation=@{type='string';required=$true};CertificateHash=@{type='string';required=$true;allowEmpty=$true};CertificateStoreName=@{type='string';required=$true;allowEmpty=$true};SslFlags=@{type='string';required=$true;allowEmpty=$true};SslFlagsPresent=@{type='boolean';required=$true}}}
    $apps=@{properties=@{Index=@{type='integer';required=$true};ApplicationPath=@{type='path';required=$true};PoolName=@{type='string';required=$true}}}
    $schemas.Fields=@{TargetPath=@{type='path'};TransferChannel=@{type='enum';options=@('C','NonC','External')};ContentSelection=@{type='enum';options=@('ExactFiles','WholeScope')};ExcludedRelativePaths=@{type='stringArray'};Consistency=@{type='enum';options=@('OwnerFreeze','Immutable')};Metadata=@{type='enum';options=@('DaclOwner','DaclOwnerSacl')};ConflictPolicy=@{type='enum';options=@('Block')};AclControlPolicy=@{type='enum';options=@('Exact','AllowAutoInheritedUpgrade');description='僅適用於 FileScope，其他 adapter 留空。Exact 為預設；AllowAutoInheritedUpgrade 僅經審查後容許新增 AI；Owner、Group、ACE 與 P/AR 仍須精確，並需重新核准。'};ConfigFiles=@{type='objectArray';schema=$configFile};DesiredFinalState=@{type='enum';options=@('Disabled','Enabled')};BusinessChecks=@{type='stringArray'};Product=@{type='string'};Procedure=@{type='string'};Artifacts=@{type='stringArray'};CatchUpPolicy=@{type='enum';options=@('PreserveSourceSettings','SkipMissedRuns','DedicatedManualCatchUp')};WorkloadFieldReviews=@{type='objectArray';schema=$reviewValue};IisBindings=@{type='objectArray';schema=$bindings};IisApplicationPools=@{type='objectArray';schema=$apps};IisPoolSettings=@{type='map'};ActivationOwner=@{type='string'};ActivationReason=@{type='string'};PrincipalUser=@{type='string'}}
    $schemas.Fields.SharedResourceReviewReasons=@{type='objectArray';schema=@{properties=@{ResourceItemId=@{type='string';required=$true};ConsumerItemIds=@{type='stringArray';required=$true};Owner=@{type='string';required=$true};Reason=@{type='string';required=$true}}}}
    $schemas.Fields.ActivationPolicyFieldPointer=@{type='string'}
    $schemas.RequirementDecisions=[ordered]@{RequirementId=@{type='string';required=$true};Decision=@{type='enum';options=@('Pending','Required','NotNeeded');required=$true};Owner=@{type='string';required=$true};DecisionReason=@{type='string';required=$true};DecisionEvidence=@{type='string';required=$true}}
    $schemas.Fields.IisConfigChanges=@{type='objectArray';schema=@{properties=@{FieldPointer=@{type='string';required=$true};Operation=@{type='enum';required=$true;options=@('SetAttribute','AddElement','RemoveElement')};ElementName=@{type='string';required=$true};KeyAttributes=@{type='objectArray';schema=@{properties=@{Name=@{type='string';required=$true};Value=@{type='string';required=$true;sensitive=$true;allowEmpty=$true}}}};AttributeName=@{type='string';required=$true;allowEmpty=$true};BeforeValue=@{type='string';required=$true;sensitive=$true;allowEmpty=$true};AfterValue=@{type='string';required=$true;sensitive=$true;allowEmpty=$true}}}}
    $schemas.WindowsSettingDecisions=@{SettingId=@{type='string';required=$true};Action=@{type='enum';required=$true;options=@('KeepTarget','External','ReviewedMigration')};Owner=@{type='string'};Reason=@{type='string'};Evidence=@{type='string'}}
    $schemas.DispositionDecisions=@{ItemId=@{type='string'};SoftwareId=@{type='string'};ScopeDisposition=@{type='enum';required=$true;options=@('Migrate','Prepare','External','NotNeeded','Reinstall','Portable','KeepCompatible')};Owner=@{type='string';required=$true};Reason=@{type='string';required=$true};Evidence=@{type='string';required=$true}}
    $schemas.TargetRequirements=@{}
    foreach($field in @('RequirementId','Type','ProviderSoftwareId','ProviderItemId','ExternalId','Certainty','RequiredPhase','ExpectedVersion','Architecture','Owner','Decision','DecisionReason','DecisionEvidence')){$schemas.TargetRequirements[$field]=@{type='string';required=$true;allowEmpty=($field -in @('ProviderSoftwareId','ProviderItemId','ExternalId','DecisionReason','DecisionEvidence'))}}
    $schemas.TargetRequirements.ConsumerItemIds=@{type='stringArray';required=$true}
    $schemas.TargetRequirements.Context=@{type='map';required=$true}
    $schemas.TargetRequirements.SourceProof=@{type='object';required=$true;schema=@{properties=@{InventoryHash=@{type='string';required=$true};EvidenceHash=@{type='string';required=$true};Status=@{type='string';required=$true}}}}
    if($schemas.ContainsKey($Name)){return @{title=$Name;properties=$schemas[$Name]}}
    return $null
}

function Get-WsmHtmlActionMetadata {
    param([ValidateSet('Source','Target','Manager')][string]$Role='Manager')
    $common=@('Verbose','Debug','ErrorAction','ErrorVariable','OutVariable','OutBuffer','PipelineVariable','InformationAction','InformationVariable','WarningAction','WarningVariable','Confirm','WhatIf','ProgressAction')
    foreach($entry in (Get-WsmHtmlActionMap).GetEnumerator()){
        $command=Get-Command $entry.Value -CommandType Function
        $registryCas=$command.Name -in @('Submit-WsmAssistiveWindowsSettingsReview','Submit-WsmAssistiveGeneralHostDispositions','Submit-WsmAssistiveGeneralHostRequirements','Submit-WsmAssistiveGeneralHostRequirementDecisions','Reserve-WsmAssistiveResource','Set-WsmAssistiveResourceEvidence','Release-WsmAssistiveResource','Set-WsmAssistiveMaterialClosed','Invoke-WsmAssistiveCleanup')
        $parameters=@(foreach($p in $command.Parameters.Values){
            if($p.ParameterType -eq [scriptblock] -or @($p.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.DontShow}).Count -or $p.Name -in $common -or $p.Name -in @('CancellationToken','Workspace','PairId') -or ($p.Name -eq 'ExpectedRevision' -and -not $registryCas)){continue}
            $required=@($p.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0
            $options=@($p.Attributes | Where-Object {$_ -is [Management.Automation.ValidateSetAttribute]} | ForEach-Object ValidValues)
            $type='string';$schema=$null;$sensitive=$p.Name -match 'Password|Secret|Credential|Token'
            if($options.Count){$type='enum'}
            elseif($p.ParameterType -in @([bool],[Management.Automation.SwitchParameter])){$type='boolean'}
            elseif($p.ParameterType -in @([int],[long],[uint32],[uint64])){$type='integer'}
            elseif($p.ParameterType -in @([double],[decimal])){$type='number'}
            elseif($p.ParameterType -eq [string[]]){$type='stringArray'}
            elseif($p.Name -ceq 'Secrets'){$type='objectArray';$schema=Get-WsmHtmlObjectSchema Secrets}
            elseif($p.Name -ceq 'Decisions'){$type='objectArray';$schema=Get-WsmHtmlObjectSchema $(if($command.Name -ceq 'Submit-WsmAssistiveGeneralHostDispositions'){'DispositionDecisions'}elseif($command.Name -ceq 'Submit-WsmAssistiveGeneralHostRequirementDecisions'){'RequirementDecisions'}else{'WindowsSettingDecisions'})}
            elseif($p.Name -ceq 'Requirements' -and $command.Name -ceq 'Submit-WsmAssistiveGeneralHostRequirements'){$type='objectArray';$schema=Get-WsmHtmlObjectSchema TargetRequirements}
            elseif($p.Name -ceq 'Fields'){$type='object';$schema=Get-WsmHtmlObjectSchema Fields}
            elseif($p.ParameterType -eq [hashtable]){$type='map'}
            elseif($p.ParameterType -eq [Management.Automation.PSCredential]){$type='object';$schema=Get-WsmHtmlObjectSchema Credential}
            elseif($p.ParameterType -eq [object] -or $p.ParameterType.IsArray){$type=if($p.ParameterType.IsArray -or $p.Name -in @('UnselectedItems','Dependencies','Changes','Consumers')){'objectArray'}else{'object'};$schema=Get-WsmHtmlObjectSchema $p.Name}
            elseif($p.Name -match 'Path|Directory|Workspace|WorkRoot'){$type='path'}
            if($type -eq 'object' -and -not $schema){$schema=@{title='Load an existing trusted artifact';properties=@{TrustedPath=@{type='path';required=$true};TrustedSHA256=@{type='string';required=$true}}}}
            if($type -eq 'objectArray' -and -not $schema){$schema=@{title='Existing typed evidence';properties=@{TrustedPath=@{type='path';required=$true};TrustedSHA256=@{type='string';required=$true}}}}
            [pscustomobject]@{name=$p.Name;label=$p.Name;type=$type;required=$required;allowEmpty=(@($p.Attributes | Where-Object {$_ -is [Management.Automation.AllowEmptyCollectionAttribute] -or $_ -is [Management.Automation.AllowEmptyStringAttribute]}).Count -gt 0);options=$options;sensitive=$sensitive;schema=$schema;description=$(if($sensitive){'Memory-only secret input; never stored in drafts or reports.'}else{''})}
        })
        $readOnly=$entry.Value -match '^(Get|Test|Assert|Read)-'
        $previewAction=if($entry.Key -eq 'Restore'){'RestorePreview'}elseif($entry.Key -eq 'Rollback'){'RollbackPreview'}elseif($entry.Key -eq 'SpecBundleImport'){'SpecBundlePreview'}else{$null}
        $requiredRole=Get-WsmTextActionGroup $entry.Key
        $supportedRoles=@($requiredRole);if($entry.Key -ceq 'Inventory'){$supportedRoles=@('Source','Target')}
        [pscustomobject]@{action=$entry.Key;label=(Get-WsmTextActionLabel $entry.Key);description=(Get-WsmTextActionGuidance $entry.Key);role=$Role;requiredRole=$requiredRole;supportedRoles=$supportedRoles;roleAvailable=($supportedRoles -contains $Role);readOnly=$readOnly;impact=@($(if($readOnly){'Read local state'}else{'Write local state or approved system resources'}));previewAction=$previewAction;parameters=$parameters}
    }
}

function Get-WsmHtmlRevision([string]$Workspace,[string]$PairId) {
    if(-not $PairId){return 0}
    $catalog=Get-WsmCatalog $Workspace $PairId
    if($catalog.PSObject.Properties['Assistive']){return [int]$catalog.Assistive.Revision}
    [int]$catalog.DecisionRevision
}

function Get-WsmHtmlRevisionVector([string]$Workspace,[string]$PairId) {
    Invoke-WsmLocked $Workspace {
        $catalog=$null;$revision=0;$decisionRevision=$null;$selectionRevision=$null;$sourceSelectionRevision=$null;$actualPair=$null
        if($PairId){$catalog=Get-WsmCatalog $Workspace $PairId;$actualPair=[string]$catalog.PairId;$revision=if($catalog.PSObject.Properties['Assistive']){[int]$catalog.Assistive.Revision}else{[int]$catalog.DecisionRevision};$decisionRevision=[int]$catalog.DecisionRevision;if($catalog.PSObject.Properties['Assistive'] -and $catalog.Assistive.PSObject.Properties['Selections']){$sourceSelectionRevision=[int]$catalog.Assistive.Selections.Revision;$selectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision}}
        $dataVersion=Get-WsmHtmlDataVersion $Workspace $PairId
        [pscustomobject]@{revision=$revision;decisionRevision=$decisionRevision;selectionRevision=$selectionRevision;sourceSelectionRevision=$sourceSelectionRevision;dataVersion=$dataVersion;pairId=$actualPair}
    }
}

function Test-WsmHtmlExpectedVector($Body,$Current) {
    if($Body.PSObject.Properties['expectedDataVersion'] -and [string]$Body.expectedDataVersion -cne [string]$Current.dataVersion){return $false}
    foreach($binding in @(@('expectedDecisionRevision','decisionRevision'),@('expectedSelectionRevision','selectionRevision'))){
        $field=$binding[0];$actualField=$binding[1]
        if(-not $Body.PSObject.Properties[$field]){continue}
        $expected=$Body.$field;$actual=$Current.$actualField
        if($null -eq $expected){if($null -ne $actual){return $false};continue}
        $parsed=0;if(-not [int]::TryParse([string]$expected,[ref]$parsed) -or $null -eq $actual -or $parsed -ne [int]$actual){return $false}
    }
    return $true
}

function Get-WsmHtmlDataVersion([string]$Workspace,[string]$PairId) {
    $fleetPath=Join-Path $Workspace 'fleet.json';$fleetHash='missing'
    if([IO.File]::Exists($fleetPath)){Assert-WsmNoReparse $fleetPath;$fleetHash=(Get-FileHash -LiteralPath $fleetPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    $catalogHash='none';if($PairId){$catalogPath=Get-WsmCatalogPath $Workspace $PairId;Assert-WsmNoReparse $catalogPath;$catalogHash=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    Get-WsmHashText ([string]$PairId+'|'+$fleetHash+'|'+$catalogHash)
}

function New-WsmHtmlSoftwareBeforeWrite([string]$Workspace,[string]$PairId,$Vector) {
    # GetNewClosure creates a new dynamic module scope. Capture module-owned
    # private helpers explicitly so the lock-time gate can call them there.
    $selectionGetter=(Get-Command Get-WsmAssistiveCurrentSelections -CommandType Function -ErrorAction Stop).ScriptBlock
    $dataVersionGetter=(Get-Command Get-WsmHtmlDataVersion -CommandType Function -ErrorAction Stop).ScriptBlock
    $capturedWorkspace=$Workspace;$capturedPairId=$PairId;$capturedVector=$Vector
    {
        param($lockedCatalog)
        if([int]$lockedCatalog.Assistive.Revision -ne [int]$capturedVector.revision){throw 'Review changed: Assistive revision.'}
        if([int]$lockedCatalog.DecisionRevision -ne [int]$capturedVector.decisionRevision){throw 'Review changed: decision revision.'}
        $selection=[int](& $selectionGetter $lockedCatalog).Revision
        if($null -ne $capturedVector.selectionRevision -and $selection -ne [int]$capturedVector.selectionRevision){throw 'Review changed: selection revision.'}
        if((& $dataVersionGetter $capturedWorkspace $capturedPairId) -cne [string]$capturedVector.dataVersion){throw 'Review changed: data version.'}
    }.GetNewClosure()
}

function Get-WsmHtmlDocuments([string]$DocRoot) {
    $documents=@{'/operations-guide.html'=(Join-Path $DocRoot 'ASSISTIVE-OPERATIONS.html');'/ASSISTIVE-OPERATIONS.css'=(Join-Path $DocRoot 'ASSISTIVE-OPERATIONS.css');'/docs/ASSISTIVE-OPERATIONS.html'=(Join-Path $DocRoot 'ASSISTIVE-OPERATIONS.html');'/docs/ASSISTIVE-OPERATIONS.css'=(Join-Path $DocRoot 'ASSISTIVE-OPERATIONS.css')}
    $manualRoot=Join-Path $DocRoot 'html'
    if([IO.Directory]::Exists($manualRoot)){
        foreach($document in @(Get-ChildItem -LiteralPath $manualRoot -File | Where-Object {($_.Extension -in @('.html','.css')) -and $_.Name -notmatch '(?i)^MIGRATION-.*-PLAN\.html$'})){
            $documents['/docs/html/'+$document.Name]=$document.FullName;$documents['/html/'+$document.Name]=$document.FullName
        }
    }
    return $documents
}

function Get-WsmHtmlOverviewProjection($Catalog,$Stage,$Selected,[string]$Role,[int]$Revision) {
    $items=@($Catalog.Items);$selectedCount=@($Selected.Values | Where-Object {$_}).Count
    if(-not $Catalog.PSObject.Properties['Assistive']){
        $reason='此配對尚未啟用輔助模式；選取與階段結果尚未建立，不能以零代替未知。';$meta=@(Get-WsmHtmlActionMetadata $Role|Where-Object {$_.action -ceq 'AssistiveEnable' -and $_.roleAvailable}|Select-Object -First 1);$nextMeta=if($meta.Count){$meta[0]}else{$null};if(-not $nextMeta){$reason+=' 請切換至 Manager 角色啟用。'}
        return [pscustomobject]@{metrics=@{discovered=$items.Count;selected='Unknown';approved='NotMeasured';executable='NotMeasured';pendingOrFailed='NotMeasured'};workloadStatus='NotObserved';stateReason=$reason;stateNextAction=$nextMeta;nextStep=[pscustomobject]@{title='啟用輔助模式';description=$reason;action=$(if($nextMeta){'AssistiveEnable'}else{$null});reason=$reason;actionMetadata=$nextMeta};steps=@([pscustomobject]@{id='selection';label='項目選取';status='Unknown';source='輔助模式尚未啟用';value='未知'},[pscustomobject]@{id='approval';label='核准證據';status='Unknown';source='輔助模式尚未啟用';value='未知'});counts=@([pscustomobject]@{id='discovered';label='盤點項目';value=$items.Count;unit='項';source='目前配對目錄';status='Observed';definition='目前目錄中的項目列數。'},[pscustomobject]@{id='selected';label='已選項目';value='Unknown';unit='項';source='尚未啟用輔助模式';status='Unknown';definition='目前尚無可驗證的輔助模式選取資料。'},[pscustomobject]@{id='availability';label='服務可用性';value='未測試';unit='資格狀態';source='此總覽沒有可用性測試結果生產者';status='NotTested';definition='本總覽不推定正式環境就緒。'});provenance=[pscustomobject]@{pairId=$Catalog.PairId;role=$Role;revision=$Revision;readUtc=(Get-WsmUtc);generation=$null;stage=$null;stageStatus=$null;producedUtc=$null;planHash=$null;approvalReference=$null;approvalKind=$null}}
    }
    $approvedSelected=@($items | Where-Object { $_.Decision -ceq 'Include' -and $Selected.ContainsKey([string]$_.ItemId) -and $Selected[[string]$_.ItemId] }).Count
    $latest=$Stage.Latest;$allCurrent=@();if($Stage -and $Stage.PSObject.Properties['AllCurrent']){$allCurrent=@($Stage.AllCurrent)};$assistive=$null;if($latest -and $latest.PSObject.Properties['Assistive']){$assistive=$latest.Assistive}
    $currentGeneration=$null;if($latest -and $latest.PSObject.Properties['PayloadGeneration']){$currentGeneration=[long]$latest.PayloadGeneration}elseif(@($allCurrent|Where-Object {$_.PSObject.Properties['PayloadGeneration']}).Count){$currentGeneration=[long](($allCurrent|Measure-Object -Property PayloadGeneration -Maximum).Maximum)}
    if($null -ne $currentGeneration){$allCurrent=@($allCurrent|Where-Object {$_.PSObject.Properties['PayloadGeneration'] -and [long]$_.PayloadGeneration -eq $currentGeneration})}
    $itemResultsKnown=($assistive -and $assistive.PSObject.Properties['ItemResults'])
    $resultRows=@();if($itemResultsKnown){$resultRows=@($assistive.ItemResults)}
    $pending='Unknown';$deferred='Unknown';$failed='Unknown';$pendingOrFailed='NotMeasured'
    if($itemResultsKnown){$pendingIds=@{};$deferredIds=@{};$failedIds=@{};foreach($row in $resultRows){$id=[string]$row.ItemId;if(-not $id){continue};if($row.Pending -or [string]$row.Status -ceq 'DeferredManual'){$pendingIds[$id]=$true};if($row.Deferred -or [string]$row.Status -ceq 'DeferredManual'){$deferredIds[$id]=$true};if([string]$row.Status -cin @('Failed','BlockedConflict')){$failedIds[$id]=$true}};$pending=$pendingIds.Count;$deferred=$deferredIds.Count;$failed=$failedIds.Count;$combined=@{};foreach($id in @($pendingIds.Keys)+@($deferredIds.Keys)+@($failedIds.Keys)){$combined[[string]$id]=$true};$pendingOrFailed=$combined.Count}
    $fileResultsKnown=($assistive -and $assistive.PSObject.Properties['FileResults']);$fileRows=@();if($fileResultsKnown){$fileRows=@($assistive.FileResults)}
    $conflicts='Unknown';if($fileResultsKnown){$conflicts=@($fileRows | Where-Object {$_.Status -ceq 'BlockedConflict'}).Count}
    $workflowStatus='NotObserved';if($latest){$workflowStatus=[string]$latest.Status}
    $generation=$null;$stageName=$null;$stageStatus=$null
    if($latest){if($latest.PSObject.Properties['PayloadGeneration']){$generation=$latest.PayloadGeneration};if($latest.PSObject.Properties['Stage']){$stageName=[string]$latest.Stage};$stageStatus=[string]$latest.Status}
    $sourceSnapshot=$null;$targetCurrent=$null;$comparison=$null
    if($Catalog.PSObject.Properties['Assistive']){$assistiveCatalog=$Catalog.Assistive;if($assistiveCatalog.PSObject.Properties['SourceSnapshot']){$sourceSnapshot=$assistiveCatalog.SourceSnapshot};if($assistiveCatalog.PSObject.Properties['TargetCurrent']){$targetCurrent=$assistiveCatalog.TargetCurrent};if($assistiveCatalog.PSObject.Properties['Comparison']){$comparison=$assistiveCatalog.Comparison}}
    $preparationKnown=($comparison -and $comparison.PSObject.Properties['ManualPreparation']);$preparationRows=@();if($preparationKnown){$preparationRows=@($comparison.ManualPreparation)}
    $latestStage = {
        param([string[]]$Names)
        $matches = @($allCurrent | Where-Object { $_.Stage -in $Names })
        if ($matches.Count -eq 0) { return $null }
        $matches | Sort-Object -Property @(
            @{ Expression = { if ($_.ProducedUtc) { [DateTimeOffset]::Parse([string]$_.ProducedUtc) } else { [DateTimeOffset]::MinValue } }; Descending = $true },
            @{ Expression = { if ($_.PSObject.Properties['Sequence']) { [long]$_.Sequence } else { 0 } }; Descending = $true }
        ) | Select-Object -First 1
    }
    $stageStep = {
        param([string]$Id,[string]$Label,[string[]]$Names,[string]$Source)
        $row = & $latestStage $Names
        if ($row) {
            $stageName=switch([string]$row.Stage){'Restore'{'還原'}'PreCutoverValidation'{'切換前驗證'}'Cutover'{'切換啟用'}'PostCutoverValidation'{'切換後驗證'}'Retirement'{'退役'}default{[string]$row.Stage}}
            $stageStatus=switch([string]$row.Status){'Succeeded'{'完成'}'Partial'{'部分完成'}'Failed'{'失敗'}'ManualEvidenceRequired'{'需要人工證據'}'Cancelled'{'已取消'}'Interrupted'{'中斷'}'ReviewRequired'{'需要審查'}default{'未識別狀態：'+[string]$row.Status}}
            [pscustomobject]@{id=$Id;label=$Label;status='Recorded';source=$Source;value=($stageName+' · '+$stageStatus);resultStatus=[string]$row.Status;stage=[string]$row.Stage;generation=$row.PayloadGeneration;producedUtc=[string]$row.ProducedUtc}
        } else {
            [pscustomobject]@{id=$Id;label=$Label;status='NotObserved';source=$Source;value='尚無本世代階段結果';resultStatus=$null;stage=$null;generation=$null;producedUtc=$null}
        }
    }
    $postCutover=& $latestStage @('PostCutoverValidation')
    $businessStep=if($postCutover){$businessValue=switch([string]$postCutover.Status){'Succeeded'{'切換後驗證已成功；此證據記錄業務接受'}'Partial'{'切換後驗證部分完成；尚不能宣告業務接受'}'ManualEvidenceRequired'{'仍需人工證據；尚不能宣告業務接受'}default{'切換後驗證狀態：'+[string]$postCutover.Status+'；尚不能宣告業務接受'}};[pscustomobject]@{id='businessAcceptance';label='業務接受';status=$(if([string]$postCutover.Status -ceq 'Succeeded'){'Accepted'}else{'ReviewRequired'});source='目前世代的 PostCutoverValidation 階段結果';value=$businessValue;resultStatus=[string]$postCutover.Status;stage=[string]$postCutover.Stage;generation=$postCutover.PayloadGeneration;producedUtc=[string]$postCutover.ProducedUtc}}else{[pscustomobject]@{id='businessAcceptance';label='業務接受';status='NotObserved';source='目前世代的 PostCutoverValidation 階段結果';value='尚無切換後驗證成功證據；不得宣告業務接受';resultStatus=$null;stage=$null;generation=$null;producedUtc=$null}}
    $delivery=Get-WsmDeliveryReceiptSummary $Catalog
    $deliveryStatusText=switch([string]$delivery.Status){'NoApproval'{'尚無核准'}'NoReceipt'{'尚無交付收據'}'Sealed'{'交付收據已封存；尚待依核准與匯入狀態核對'}'ImportedVerified'{'交付收據已驗證匯入'}'Stale'{'交付證據已過期'}'OldApproval'{'交付使用舊核准'}default{'未識別交付狀態：'+[string]$delivery.Status}}
    $deliveryStep=[pscustomobject]@{id='delivery';label='交付';status=$(if($delivery.Status -in @('NoApproval','NoReceipt')){'NotObserved'}elseif($delivery.Status -in @('Stale','OldApproval')){'ReviewRequired'}else{'Recorded'});source='DeliveryReceipts 核驗摘要與目前核准綁定';value=($deliveryStatusText+$(if($delivery.Generation){' · 世代 '+[string]$delivery.Generation}else{''}));resultStatus=[string]$delivery.Status;generation=$delivery.Generation;deliveryId=$delivery.DeliveryId;mode=$delivery.Mode;transportHash=$delivery.TransportHash;reportOnly=[bool]$delivery.ReportOnly;readinessProof=[bool]$delivery.ReadinessProof;productionVerified=[bool]$delivery.ProductionVerified}
    $steps=@(
        [pscustomobject]@{id='source';label='來源盤點';status=$(if($sourceSnapshot){'Recorded'}else{'NotObserved'});source='目前配對輔助目錄';value=$(if($sourceSnapshot){'已記錄目前來源快照'}else{'尚無來源快照'})},
        [pscustomobject]@{id='selection';label='項目選取';status=$(if($selectedCount -gt 0){'Recorded'}else{'ReviewRequired'});source='目前已保存的選取集合';value=($selectedCount.ToString()+' 個項目已選取')},
        [pscustomobject]@{id='approval';label='核准證據';status=$(if($Catalog.Approval){'Recorded'}else{'NotObserved'});source='目前配對核准參照；效力仍須核對封存計畫';value=$(if($Catalog.Approval){'已記錄核准參照；仍須由目前封存計畫驗證效力'}else{'尚無核准證據'})},
        [pscustomobject]@{id='target';label='目標快照';status=$(if($targetCurrent){'Recorded'}else{'NotObserved'});source='目前配對輔助目錄';value=$(if($targetCurrent){'已記錄目前目標快照'}else{'尚無目前目標快照'})},
        [pscustomobject]@{id='comparison';label='目標比較';status=$(if($comparison){'Recorded'}else{'NotObserved'});source='目前來源與目標軟體比較';value=$(if($comparison){'已記錄比較證據'}else{'尚無目前比較證據'})},
        [pscustomobject]@{id='softwarePreparation';label='軟體準備審查';status=$(if($preparationKnown){if($preparationRows.Count){'ReviewRequired'}else{'Recorded'}}else{'NotObserved'});source='目前比較結果 ManualPreparation 列';value=$(if($preparationKnown){$preparationRows.Count.ToString()+' 筆需處理或審查資料'}else{'尚無可讀取的軟體準備比較結果'})},
        $deliveryStep,
        (& $stageStep 'restore' '還原' @('Restore') '目前世代已接受的 Restore 階段結果'),
        (& $stageStep 'preCutoverValidation' '切換前驗證' @('PreCutoverValidation') '目前世代已接受的 PreCutoverValidation 階段結果'),
        (& $stageStep 'activation' '啟用' @('Cutover') '目前世代 Cutover 階段結果；不代表業務接受'),
        (& $stageStep 'postCutoverValidation' '切換後驗證' @('PostCutoverValidation') '目前世代已接受的 PostCutoverValidation 階段結果'),
        (& $stageStep 'retirement' '退役' @('Retirement') '目前世代已接受的 Retirement 階段結果'),
        $businessStep
    )
    $counts=@(
        [pscustomobject]@{id='discovered';label='盤點項目';value=$items.Count;unit='項';source='目前配對目錄';status='Observed';definition='目前目錄中的項目列數。'},
        [pscustomobject]@{id='selected';label='已選項目';value=$selectedCount;unit='項';source='目前已保存的選取';status='Observed';definition='目前選取的目錄項目，不代表核准。'},
        [pscustomobject]@{id='includeSelected';label='已標為 Include 的選取項目';value=$approvedSelected;unit='項';source='目前目錄決策與選取';status='Observed';definition='已選項目中明確標為 Include 的數量，不等同封存核准。'},
        [pscustomobject]@{id='stageObjects';label='階段項目結果';value=$(if($itemResultsKnown){$resultRows.Count}else{'Unknown'});unit='項目結果列';source='目前世代有效階段結果的 ItemResults';status=$(if($itemResultsKnown){'Observed'}else{'Unknown'});definition='ItemResults 中實際存在的列數，不是完成百分比。'},
        [pscustomobject]@{id='pending';label='待處理項目';value=$pending;unit='項';source='ItemResults Pending 旗標與 DeferredManual 狀態';status=$(if($itemResultsKnown){'Observed'}else{'Unknown'});definition='明確標記 Pending 或 DeferredManual 的不同項目。'},
        [pscustomobject]@{id='deferred';label='延後項目';value=$deferred;unit='項';source='ItemResults Deferred 旗標與 DeferredManual 狀態';status=$(if($itemResultsKnown){'Observed'}else{'Unknown'});definition='明確標記 Deferred 或 DeferredManual 的不同項目。'},
        [pscustomobject]@{id='failedItems';label='明確失敗項目';value=$failed;unit='項';source='ItemResults 狀態 Failed 或 BlockedConflict';status=$(if($itemResultsKnown){'Observed'}else{'Unknown'});definition='狀態明確為 Failed 或 BlockedConflict 的不同項目；DeferredManual 另列為延後。'},
        [pscustomobject]@{id='pendingOrFailed';label='待處理或明確失敗項目';value=$pendingOrFailed;unit='項';source='ItemResults 待處理、延後與明確失敗旗標';status=$(if($itemResultsKnown){'Observed'}else{'Unknown'});definition='待處理、延後或明確失敗集合的不同項目聯集。'},
        [pscustomobject]@{id='fileConflicts';label='檔案衝突';value=$conflicts;unit='檔案結果列';source='FileResults 狀態 BlockedConflict';status=$(if($fileResultsKnown){'Observed'}else{'Unknown'});definition='目前有效 FileResults 中標記 BlockedConflict 的列數，不推算來源檔案總數。'},
        [pscustomobject]@{id='softwarePreparationRows';label='軟體準備審查資料列';value=$(if($preparationKnown){$preparationRows.Count}else{'Unknown'});unit='審查資料列';source='目前比較結果 ManualPreparation';status=$(if($preparationKnown){'Observed'}else{'Unknown'});definition='實際存在的軟體人工準備或缺口資料列，不代表已準備完成。'},
        [pscustomobject]@{id='availability';label='服務可用性';value='未測試';unit='資格狀態';source='此總覽沒有可用性測試結果生產者';status='NotTested';definition='本總覽不推定正式環境就緒。'}
    )
    $channelRows=Get-WsmAssistiveReportCountRows $Catalog $Stage (Get-WsmAssistiveReportFileResultRows $Stage $Catalog)
    foreach($channel in @('C','NonC')){
        $row=@($channelRows.Rows|Where-Object {$_[0] -ceq 'Accepted execution results' -and $_[1] -ceq $channel})|Select-Object -First 1
        if($row){$values=@($row);$counts+=@(
            [pscustomobject]@{id=($channel.ToLowerInvariant()+'Items');label=($channel+' 通道盤點');value=$values[2];unit='項';source='有效 Assistive 分通道報告計數';status='Observed';definition='依目前目錄 TransferChannel 分組的項目數。'},
            [pscustomobject]@{id=($channel.ToLowerInvariant()+'Selected');label=($channel+' 通道已選');value=$values[3];unit='項';source='有效 Assistive 分通道報告計數';status='Observed';definition='目前已保存選取的該通道項目數。'},
            [pscustomobject]@{id=($channel.ToLowerInvariant()+'StageItems');label=($channel+' 通道階段結果');value=$values[5];unit='項';source='有效 Assistive 分通道報告計數';status=$(if($itemResultsKnown){'Observed'}else{'Unknown'});definition='最新有效階段結果中屬於該通道的不同項目數。'},
            [pscustomobject]@{id=($channel.ToLowerInvariant()+'ManualWorkflowSelected');label=($channel+' 通道人工流程選取');value=$values[6];unit='項';source='有效 Assistive ManualWorkflow 項目計數';status='Observed';definition='目前選取的 ManualWorkflow 項目數，不代表人工工作已完成。'},
            [pscustomobject]@{id=($channel.ToLowerInvariant()+'FileRows');label=($channel+' 通道檔案結果');value=$values[10];unit='檔案結果列';source='最新有效階段 FileResults';status=$(if($fileResultsKnown){'Observed'}else{'Unknown'});definition='該通道實際回報的檔案結果列；沒有來源檔案分母。'},
            [pscustomobject]@{id=($channel.ToLowerInvariant()+'PlacedFiles');label=($channel+' 通道已套用路徑列');value=$values[11];unit='檔案結果列';source='FileResults 有效路徑且狀態 Applied';status=$(if($fileResultsKnown){'Observed'}else{'Unknown'});definition='FileResults 中有有效路徑且狀態為 Applied 的列數；不代表另有讀回雜湊或業務驗收。'},
            [pscustomobject]@{id=($channel.ToLowerInvariant()+'ReadbackHashVerifiedFiles');label=($channel+' 通道讀回雜湊相符列');value=$(if($fileResultsKnown){@($fileRows|Where-Object {$_.Channel -ceq $channel -and $_.Status -ceq 'Applied' -and [string]$_.SourceHash -match '^[0-9a-fA-F]{64}$' -and [string]$_.ObservedHash -match '^[0-9a-fA-F]{64}$' -and [string]$_.SourceHash -ieq [string]$_.ObservedHash}).Count}else{'Unknown'});unit='檔案結果列';source='目前世代 FileResults 的 SourceHash 與 ObservedHash';status=$(if($fileResultsKnown){'Observed'}else{'Unknown'});definition='只計入 Applied 列中來源與讀回 SHA-256 均存在且相符的列；不代表全體檔案都已讀回。'}
        )}
    }
    $next=[pscustomobject]@{title='檢查目前證據';description='依目前配對、選取、核准及階段證據確認下一個可用操作。';action=$null;reason='目前生產者證據不足以安全指定下一個操作。';actionMetadata=$null}
    $actionId=$null;$reason=$null
    if($selectedCount -eq 0){$actionId='SaveSelection';$reason='目前沒有已選取的項目；請先檢視清單並保存選取理由。'}
    elseif(-not $targetCurrent){$actionId='TargetSnapshot';$reason='目前沒有目標快照；請在目標主機擷取可信盤點後再送出。'}
    elseif(-not $comparison){$actionId='PublishComparison';$reason='目前沒有來源與目標比較證據；請先產生並檢查比較。'}
    elseif($latest -and [string]$latest.Status -cin @('Partial','Failed','ManualEvidenceRequired','BlockedConflict')){$actionId='AssistiveReport';$reason='目前世代的階段結果需要檢查；先查看管理報告中的部分結果、衝突與明確待辦，再決定重做或續作。'}
    elseif($latest -and [string]$latest.Status -ceq 'Cancelled'){$actionId='AssistiveReport';$reason='目前世代的作業已取消；先檢視管理報告與已記錄結果，再依核心日誌及復原指引判斷是否可續作。'}
    elseif($latest -and [string]$latest.Status -ceq 'Interrupted'){$actionId='AssistiveReport';$reason='目前世代的作業曾中斷；先檢查權威日誌、復原狀態與管理報告，不要僅依主控台重新提交。'}
    elseif($latest -and [string]$latest.Status -ceq 'ReviewRequired'){$actionId='AssistiveReport';$reason='目前世代結果需要審查；查看管理報告中的原始狀態與待辦，再決定下一個有核准的操作。'}
    elseif($latest -and [string]$latest.Stage -ceq 'Cutover' -and -not $postCutover){$actionId='Validate';$reason='目前世代已記錄切換結果，但尚無切換後驗證；依現況完成驗證前，不得宣告業務接受。'}
    elseif($latest -and [string]$latest.Stage -ceq 'Restore' -and [string]$latest.Status -ceq 'Succeeded' -and -not (& $latestStage @('PreCutoverValidation'))){$actionId='Validate';$reason='目前世代還原結果已完成；下一步是檢查切換前驗證條件，仍須經核准與核心閘門。'}
    elseif($postCutover -and [string]$postCutover.Status -ceq 'Succeeded'){$reason='目前世代的切換後驗證已成功；交付狀態仍依獨立核驗收據呈現。'}
    elseif($preparationKnown -and $preparationRows.Count){$actionId='AssistiveReport';$reason='軟體比較含人工準備或證據缺口；查看管理報告中的實際資料列，確認負責人和證據後再進行預覽。'}
    elseif(-not ($Catalog.Approval -and $Catalog.Approval.PSObject.Properties['Kind'] -and $Catalog.Approval.Kind -ceq 'MigrationPlan')){$actionId='ApproveMigration';$reason='目前沒有與配對及計畫雜湊綁定的封存遷移計畫核准；先檢查計畫、未解決項目與目標條件，再由管理角色執行核心核准閘門。Include 選取本身不代表核准。'}
    elseif(-not $latest){$actionId=if($Role -ceq 'Target'){'RestorePreview'}else{'AssistiveReport'};$reason='目前已具備來源、目標與封存核准資料，但尚無本世代階段結果；請先依目前角色檢視原生還原預覽或管理報告，再由核心重新驗證所有執行閘門。'}
    $available=@(Get-WsmHtmlActionMetadata $Role)
    if($actionId -and @($available | Where-Object action -CEQ $actionId).Count){$meta=@($available | Where-Object action -CEQ $actionId | Select-Object -First 1)[0];if($meta.roleAvailable){$next=[pscustomobject]@{title=$meta.label;description=$meta.description;action=$actionId;reason=$reason;actionMetadata=$meta}}else{$roleReason=$reason+' 此操作需使用 '+$meta.requiredRole+' 角色。';$next=[pscustomobject]@{title=$meta.label;description=$meta.description;action=$null;reason=$roleReason;actionMetadata=$null}}}
    elseif($reason){$next=[pscustomobject]@{title='目前階段狀態';description=$reason;action=$null;reason=$reason;actionMetadata=$null}}
    [pscustomobject]@{
         metrics=@{discovered=$items.Count;selected=$selectedCount;approved='NotMeasured';executable='NotMeasured';pendingOrFailed=$pendingOrFailed}
        workloadStatus=$workflowStatus;stateReason=$next.reason;stateNextAction=$next.actionMetadata;nextStep=$next;steps=$steps;counts=$counts
        provenance=[pscustomobject]@{pairId=$Catalog.PairId;role=$Role;revision=$Revision;readUtc=(Get-WsmUtc);generation=$generation;stage=$stageName;stageStatus=$stageStatus;producedUtc=$(if($latest -and $latest.PSObject.Properties['ProducedUtc']){[string]$latest.ProducedUtc}else{$null});planHash=$(if($latest -and $latest.PSObject.Properties['PlanHash']){[string]$latest.PlanHash}else{$null});approvalReference=$(if($Catalog.Approval -and $Catalog.Approval.PSObject.Properties['Hash']){[string]$Catalog.Approval.Hash}else{$null});approvalKind=$(if($Catalog.Approval -and $Catalog.Approval.PSObject.Properties['Kind']){[string]$Catalog.Approval.Kind}else{$null});deliveryStatus=$delivery.Status;deliveryGeneration=$delivery.Generation;deliveryId=$delivery.DeliveryId;transportHash=$delivery.TransportHash;deliveryReportOnly=$delivery.ReportOnly;deliveryReadinessProof=$delivery.ReadinessProof;deliveryProductionVerified=$delivery.ProductionVerified}
    }
}

function Get-WsmHtmlContext([string]$Workspace,[string]$PairId,[string]$Role,[string]$ContextId) {
    Invoke-WsmLocked $Workspace {
        $pairs=@();if([IO.File]::Exists((Join-Path $Workspace 'fleet.json'))){$pairs=@((Get-WsmFleet $Workspace).Pairs|ForEach-Object {[pscustomobject]@{pairId=$_.PairId;label=$_.PairId}})}
        $catalog=$null;$revision=0;$decisionRevision=$null;$selectionRevision=$null;$sourceSelectionRevision=$null
        if($PairId){$catalog=Get-WsmCatalog $Workspace $PairId;$revision=if($catalog.PSObject.Properties['Assistive']){[int]$catalog.Assistive.Revision}else{[int]$catalog.DecisionRevision};$decisionRevision=[int]$catalog.DecisionRevision;if($catalog.PSObject.Properties['Assistive'] -and $catalog.Assistive.PSObject.Properties['Selections']){$sourceSelectionRevision=[int]$catalog.Assistive.Selections.Revision;$selectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision}}
        $dataVersion=Get-WsmHtmlDataVersion $Workspace $PairId
        [pscustomobject]@{workspace=$Workspace;pairId=$PairId;role=$Role;contextId=$ContextId;revision=$revision;decisionRevision=$decisionRevision;selectionRevision=$selectionRevision;sourceSelectionRevision=$sourceSelectionRevision;dataVersion=$dataVersion;pairs=$pairs;roles=@('Source','Target','Manager')}
    }
}

function ConvertTo-WsmHtmlPreview($Result,[string]$Action,[int]$Revision,[string]$Kind='ResourcePreview') {
    # Never return raw Desired/Settings/XML, native exception text, credentials or tokens.
    $safe=@('ItemId','Name','Adapter','Action','Status','Reason','Issue','Gate','RelativePath','SourcePath','PreservedPath','EffectivePath','EffectivePathStatus','OriginalPathStatus','OriginalPathHash','OriginalPathChangedByApprovedMapping','OriginalPathChangeReason','PlacementStatus','Generation','ScopeImpact')
    $rows=@()
    foreach($name in @('Rows','Items','Problems','Issues','Changes')){
        if($Result -and $Result.PSObject.Properties[$name]){foreach($row in @($Result.$name)){$projection=[ordered]@{};foreach($field in $safe){if($row -and $row.PSObject.Properties[$field]){$projection[$field]=$row.$field}};if($projection.Count){$rows+=,[pscustomobject]$projection}}}
    }
    $blocked=$false;if($Result -and $Result.PSObject.Properties['Blocked']){$blocked=[bool]$Result.Blocked}
    $notes=@();if($Kind -ceq 'ParametersOnly'){$notes=@('Parameter review only. Resource readiness requires the applicable native preview, sealed evidence and execution gates.')}
    [pscustomobject]@{revision=$Revision;action=$Action;executed=$false;previewKind=$Kind;canExecute=(-not $blocked);items=$rows;issues=$notes;summary=$(if($blocked){'Blocked: review the listed issues.'}elseif($Kind -ceq 'ParametersOnly'){'Parameters reviewed; native readiness has not been verified.'}else{'Native preview completed. Execution will revalidate evidence and target state.'})}
}

function Get-WsmHtmlResultProjection($Output) {
    $fields=@('Status','Stage','Path','SHA256','Hash','ReportPath','HtmlPath','ManifestPath','ManifestHash','Archive','ArchiveSHA256','RunId','PairId','Generation','Revision','ObservedChecks','PendingChecks','SpecPath','SpecHash','ReceiptPath','ReceiptHash','DecisionRevision','AssistiveRevision','SelectionRevision','TargetPhysicalId','RegistryRevision','ResourceKey','DocumentManifestPath','DocumentManifestHash','DocumentId','BundlePath','MemberCount','Valid','ProbeStatus','IndexPath','Kind','ExpectedRevision','PreviewPath','PreviewFileHash','PreviewHash','ReviewWindowsSettings','RowCount','SourceInventoryPath','SourceInventoryHash','TargetInventoryPath','TargetInventoryHash','GeneratedDecisionsPath','GeneratedDecisionsHash','GeneratedRequirementsPath','GeneratedRequirementsHash','FailureCode','ReviewHash','Role','HostFingerprint','TaskPath','TaskName','TaskXmlSHA256','TaskSecuritySHA256','CapturedUtc','RawDefinitionReturned','RawDefinitionsReturned','RawDefinitionsIncluded','ProductionVerified','VendorVerified','ReadinessProof','BusinessAcceptance','ProviderId','Owner','SourceOS','TargetOS','TargetFingerprint','TargetSnapshotHash','TargetSnapshotUtc','SourceTaskXmlSHA256','SourceTaskSecuritySHA256','TargetTaskXmlSHA256','TargetTaskSecuritySHA256','SourceProviderProvenanceReference','TargetProviderProvenanceReference','TrustedBaselinePath','TrustedBaselineHash','TrustedBaselineOwner','SourceBaselineMatched','TargetBaselineMatched','DefinitionsDiffer','OSProvidedEligible','ValuesWithheld','EvidencePath','EvidenceHash','Disposition')
    @(foreach($row in @($Output)){$safe=[ordered]@{};foreach($field in $fields){if($row -and $row.PSObject.Properties[$field]){$value=$row.$field;if($value -is [string] -or $value -is [ValueType]){$safe[$field]=$value}}};if($row -and $row.PSObject.Properties['ManualReasons']){$safe.ManualReasons=@($row.ManualReasons | Where-Object {$_ -is [string]})};if($row -and $row.PSObject.Properties['Kind'] -and $row.Kind -cin @('AssistiveWindowsSettingsPreviewOutput','AssistivePreparationPreview','AssistiveRequirementReview')){
            $rowFields=if($row.Kind -ceq 'AssistiveWindowsSettingsPreviewOutput'){@('SettingId','SourceItemId','Category','Kind','SettingName','SourceValueHash','TargetValueHash','TargetDiff','ControlSource','SupportedActions','DefaultAction','RequiredConsumerItemIds')}else{@('RequirementId','Type','ProviderItemId','ExternalId','ProviderSoftwareId','ExpectedVersion','Architecture','RequiredPhase','Decision','Certainty','ConsumerItemIds','ContextHash')}
            $safe.Rows=@(foreach($entry in @($row.Rows)){$record=[ordered]@{};foreach($field in $rowFields){if($entry.PSObject.Properties[$field]){$value=$entry.$field;if($value -is [string] -or $value -is [ValueType]){$record[$field]=$value}elseif($value -is [array]){$record[$field]=@($value | Where-Object {$_ -is [string]})}}};[pscustomobject]$record})
        };if($safe.Count){[pscustomobject]$safe}})
}

function Get-WsmHtmlReportArtifacts([string]$Action,$Outputs) {
    if($Action -notin @('Report','FleetReport','AssistiveReport','EnvironmentProbe','HttpIntegrityProbe','LabReport','MigrationReport','DeliveryDocument','MaterialJobStatus')){return}
    $artifacts=@();$seen=@{}
    foreach($output in @($Outputs)){foreach($field in @('ReportPath','HtmlPath','Path')){
        if($output.PSObject.Properties[$field] -and $output.$field -is [string]){
            $path=[IO.Path]::GetFullPath([string]$output.$field)
            if([IO.Path]::GetExtension($path) -ieq '.html' -and [IO.File]::Exists($path) -and -not $seen.ContainsKey($path)){
                Assert-WsmNoReparse $path;$seen[$path]=$true
                $artifacts+=@([pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();Label=[IO.Path]::GetFileName($path)})
            }
        }
    }}
    return $artifacts
}

function New-WsmHtmlCancellation($Command,$Arguments,[string]$OperationId) {
    if(-not $Command.Parameters.ContainsKey('CancellationToken')){return $null}
    if($Arguments.ContainsKey('TransferPlanPath') -and $Arguments.ContainsKey('ExpectedPlanHash')){
        $plan=Read-WsmTrustedJson $Arguments.TransferPlanPath $Arguments.ExpectedPlanHash
        return New-WsmCancellationToken -StateDirectory $plan.TargetStateDirectoryAccessPath -PairId $plan.PairId -PlanHash $plan.SealedPlanHash -ManifestHash $plan.ManifestHash -OperationId $OperationId
    }
    if($Arguments.ContainsKey('TransportPath') -and $Arguments.ContainsKey('ExpectedTransportHash') -and $Arguments.ContainsKey('TargetStateDirectory')){
        if([IO.Path]::GetExtension($Arguments.TransportPath) -ieq '.json'){if((Get-WsmDeltaVolumeHash $Arguments.TransportPath) -ine $Arguments.ExpectedTransportHash){throw 'Delta transport hash mismatch.'};$transport=Read-WsmJson $Arguments.TransportPath}else{Test-WsmDeltaTransportZipBinding $Arguments.TransportPath $Arguments.ExpectedTransportHash $Arguments.ImportedDirectory $null;$transport=Read-WsmJson (Join-Path $Arguments.ImportedDirectory 'transport.json')}
        return New-WsmCancellationToken -StateDirectory $Arguments.TargetStateDirectory -PairId $transport.PairId -PlanHash $transport.PlanHash -ManifestHash $transport.CurrentManifestHash -OperationId $OperationId
    }
    if($Arguments.ContainsKey('ManifestPath') -and $Arguments.ContainsKey('ExpectedHash') -and $Arguments.ContainsKey('StateDirectory')){
        $package=Test-WsmMigrationPackage $Arguments.ManifestPath $Arguments.ExpectedHash
        return New-WsmCancellationToken -StateDirectory $Arguments.StateDirectory -PairId $package.Manifest.PairId -PlanHash $package.Manifest.PlanHash -ManifestHash $Arguments.ExpectedHash -OperationId $OperationId
    }
    if($Arguments.ContainsKey('PlanPath') -and $Arguments.ContainsKey('ExpectedHash') -and $Arguments.ContainsKey('SourceStateDirectory')){
        $plan=Read-WsmMigrationPlan $Arguments.PlanPath $Arguments.ExpectedHash
        return New-WsmCancellationToken -StateDirectory $Arguments.SourceStateDirectory -PairId $plan.PairId -PlanHash $Arguments.ExpectedHash -OperationId $OperationId
    }
    return $null
}

function Get-WsmHtmlView {
    param([string]$Workspace,[string]$PairId,[string]$View,[string]$Role)
    if($View -ceq 'actions'){
        $actions=@(Get-WsmHtmlActionMetadata $Role)
        if($PairId){
            $decisionRevision=[int](Get-WsmCatalog $Workspace $PairId).DecisionRevision
            foreach($action in $actions){
                $parameterName=switch($action.action){
                    'OsProvidedCapture' {'DecisionRevision'}
                    'OsProvidedBaseline' {'ExpectedDecisionRevision'}
                    'OsProvidedSubmit' {'ExpectedDecisionRevision'}
                    default {$null}
                }
                if($parameterName){
                    $action | Add-Member NoteProperty nativeRevisionBinding 'DecisionRevision' -Force
                    $action | Add-Member NoteProperty nativeRevision $decisionRevision -Force
                    $parameter=@($action.parameters | Where-Object name -CEQ $parameterName | Select-Object -First 1)
                    if($parameter.Count){$parameter[0] | Add-Member NoteProperty readOnly $true -Force;$parameter[0] | Add-Member NoteProperty value $decisionRevision -Force;$parameter[0].description='由本機核心提供並於預覽與提交時再次核對；請勿以其他 revision 取代。'}
                }
            }
        }
        return [pscustomobject]@{actions=$actions}
    }
    if(-not $PairId){
        $fleetPairs=@();$fleetPath=Join-Path $Workspace 'fleet.json';if([IO.File]::Exists($fleetPath)){$fleetPairs=@((Get-WsmFleet $Workspace).Pairs)}
        $firstAction=$null;$reason='尚未選擇配對。'
        if($Role -ceq 'Source'){$firstAction='Inventory';$reason='此工作區尚未選擇配對；請先在來源主機擷取盤點，交由管理者匯入並建立配對。'}
        elseif($Role -ceq 'Manager' -and -not $fleetPairs.Count){$firstAction='Initialize';$reason='工作區尚無配對；先初始化工作區，再從來源主機匯入盤點。'}
        elseif($Role -ceq 'Manager'){$reason='工作區已有配對；請從目前工作區配對清單選擇要檢視的配對。'}
        else{$reason='尚未選擇配對；請由管理者選取或建立配對後，再使用此主機角色。'}
        $firstMeta=$null;if($firstAction){$firstMeta=@(Get-WsmHtmlActionMetadata $Role|Where-Object {$_.action -ceq $firstAction -and $_.roleAvailable}|Select-Object -First 1);if($firstMeta.Count){$firstMeta=$firstMeta[0]}else{$firstMeta=$null}}
        if($View -ceq 'overview') {
            $nextAction=$null
            if($firstMeta){$nextAction=[string]$firstMeta.action}
            $nextStep=[pscustomobject]@{title='選擇或建立配對';description=$reason;action=$nextAction;reason=$reason;actionMetadata=$firstMeta}
            $steps=@([pscustomobject]@{id='pair';label='配對';status='NotObserved';source='目前主控台內容';value='尚未選擇配對'})
            $counts=@(
                [pscustomobject]@{id='discovered';label='盤點項目';value='Unknown';unit='項';source='尚無目前配對目錄';status='Unknown';definition='選擇配對前不推定盤點數。'},
                [pscustomobject]@{id='availability';label='服務可用性';value='未測試';unit='資格狀態';source='此總覽沒有可用性測試結果生產者';status='NotTested';definition='本總覽不推定正式環境就緒。'}
            )
            $provenance=[pscustomobject]@{pairId=$null;role=$Role;revision=0;readUtc=(Get-WsmUtc);generation=$null;stage=$null;stageStatus=$null;producedUtc=$null;planHash=$null;approvalReference=$null;approvalKind=$null}
            return [pscustomobject]@{metrics=@{discovered=0;selected=0;approved='NotMeasured';executable='NotMeasured';pendingOrFailed='NotMeasured'};workloadStatus='NotStarted';stateReason=$reason;stateNextAction=$firstMeta;nextStep=$nextStep;steps=$steps;counts=$counts;provenance=$provenance}
        }
        return [pscustomobject]@{items=@();metrics=@{discovered='Unknown';selected='Unknown';approved='NotMeasured';executable='NotMeasured';pendingOrFailed='NotMeasured'};workloadStatus='NotStarted';stateReason=$reason;stateNextAction=$firstMeta}
    }
    $catalog=Get-WsmCatalog $Workspace $PairId
    $stage=Get-WsmAssistiveReportStageResults $catalog
    $resultIndex=@{};if($stage.Latest -and $stage.Latest.PSObject.Properties['Assistive']){foreach($row in @($stage.Latest.Assistive.ItemResults)){$resultIndex[[string]$row.ItemId]=$row}}
    $selected=@{};if($catalog.PSObject.Properties['Assistive']){foreach($selection in (Get-WsmAssistiveCurrentSelections $catalog).Items){$selected[$selection.ItemId]=$selection.Selected}}
    switch($View){
        inventory {
            Get-WsmHtmlInventoryProjection $catalog $selected $resultIndex
        }
        software {
            if(-not $catalog.PSObject.Properties['Assistive'] -or -not $catalog.Assistive.PSObject.Properties['SourceSnapshot']){return [pscustomobject]@{rows=@()}}
            if(-not $catalog.Assistive.TargetCurrent){return [pscustomobject]@{rows=@()}}
            if(Get-Command Get-WsmAssistiveComparison -ErrorAction SilentlyContinue){
                $comparison=Get-WsmAssistiveComparison $Workspace $PairId
                [pscustomobject]@{rows=@(foreach($row in $comparison.Rows){[pscustomobject]@{softwareId=$row.SoftwareId;name=$row.Name;sourceVersion=$row.SourceVersion;chosenVersion=$row.ChosenVersion;chosenVersionReason=$(if($row.SoftwareId -and $catalog.Assistive.PSObject.Properties['SoftwareChoices']){[string](Get-WsmConfirmationValue ($catalog.Assistive.SoftwareChoices | Where-Object SoftwareId -CEQ $row.SoftwareId | Select-Object -First 1) 'Reason' '')}else{''});observedVersion=$row.ObservedTargetVersion;status=$row.Status;reason=$row.Reason;manualActions=@(foreach($manual in @($comparison.ManualPreparation | Where-Object SoftwareId -CEQ $row.SoftwareId)){[pscustomobject]@{status=$manual.Status;owner=$manual.Owner;action=$manual.Action}});sourceAccountContext=(Get-WsmConfirmationValue $row 'SourceAccountContext');sourceSID=$(if($row.SoftwareId){Get-WsmConfirmationValue $row 'SID'}else{''});targetAccountContext=(Get-WsmConfirmationValue $row 'TargetAccountContext');targetSID=$(if($row.SoftwareId){Get-WsmConfirmationValue $row 'TargetSID'}else{Get-WsmConfirmationValue $row 'SID'});accountScopeStatus=(Get-WsmConfirmationValue $row 'AccountScopeStatus');sourceCaptureStatus=(Get-WsmConfirmationValue $row 'SourceCaptureStatus');targetCaptureStatus=(Get-WsmConfirmationValue $row 'TargetCaptureStatus');sourceKind=(Get-WsmConfirmationValue $row 'SourceKind');targetSourceKind=(Get-WsmConfirmationValue $row 'TargetSourceKind');sourceLocation=(Get-WsmConfirmationValue $row 'SourceLocation');targetLocation=(Get-WsmConfirmationValue $row 'TargetLocation');sourceVersionEvidenceKind=(Get-WsmConfirmationValue $row 'SourceVersionEvidenceKind');targetVersionEvidenceKind=(Get-WsmConfirmationValue $row 'TargetVersionEvidenceKind');sourceVersionType=(Get-WsmConfirmationValue $row 'SourceVersionType');targetVersionType=(Get-WsmConfirmationValue $row 'TargetVersionType');versionChoices=@([pscustomobject]@{label=$row.SourceVersion;value=$row.SourceVersion});versionSelectionAction=$(if($row.SoftwareId){'SetSoftwareVersion'}else{$null})}});manualPreparation=$comparison.ManualPreparation;comparisonRevision=$comparison.Revision}
            }else{[pscustomobject]@{rows=@()}}
        }
        files {
            if($stage.Latest -and $stage.Latest.PSObject.Properties['Assistive'] -and $stage.Latest.Assistive.PSObject.Properties['FileResults']){return [pscustomobject]@{rows=@(foreach($file in $stage.Latest.Assistive.FileResults){[pscustomobject]@{itemId=$file.ItemId;sourcePath=$file.OriginalPath;preservedPath=$file.PreservedPath;effectivePath=$(if($file.EffectivePath){$file.EffectivePath}else{'NotObserved'});placementStatus=$file.Status;reason=$file.Reason;existingTargetPath=$file.ExistingTargetPath;existingTargetHash=$file.ExistingTargetHash;sourceHash=$file.SourceHash;observedHash=$file.ObservedHash;scopeImpact=$file.ItemId}})}}
            [pscustomobject]@{rows=@(foreach($item in $catalog.Items){if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec -and $item.MigrationSpec.Adapter -eq 'FileScope'){[pscustomobject]@{itemId=$item.ItemId;sourcePath=$item.MigrationSpec.SourcePath;preservedPath=$item.MigrationSpec.TargetPath;effectivePath='NotObserved';placementStatus='ReviewRequired';reason='Use file placement and restore preview on the target for per-file evidence.';scopeImpact=$item.Name}}})}
        }
        overview {
            $revision=Get-WsmHtmlRevision $Workspace $PairId
            Get-WsmHtmlOverviewProjection $catalog $stage $selected $Role $revision
        }
        default {throw 'Unknown view.'}
    }
}

function Get-WsmHtmlInventoryProjection($Catalog,$Selected,$ResultIndex) {
    $sourceSelected=@{};if($Catalog.PSObject.Properties['Assistive'] -and $Catalog.Assistive.PSObject.Properties['Selections']){foreach($selection in @($Catalog.Assistive.Selections.Items)){$sourceSelected[[string]$selection.ItemId]=[bool]$selection.Selected}}
    $sealedApproval=([bool]$Catalog.Approval -and $Catalog.Approval.PSObject.Properties['Kind'] -and $Catalog.Approval.Kind -ceq 'MigrationPlan')
    $selectionRows=@();if($Catalog.PSObject.Properties['Assistive']){if($sealedApproval -and $Catalog.Assistive.PSObject.Properties['TargetSelections']){$selectionRows=@($Catalog.Assistive.TargetSelections.Items)}elseif($Catalog.Assistive.PSObject.Properties['Selections']){$selectionRows=@($Catalog.Assistive.Selections.Items)}}
    [pscustomobject]@{items=@(foreach($item in $Catalog.Items){$allowed=([bool]$Catalog.PSObject.Properties['Assistive'] -and (-not $sealedApproval -or ($item.Decision -ceq 'Include' -and $sourceSelected.ContainsKey([string]$item.ItemId) -and $sourceSelected[[string]$item.ItemId])));$approvalStatus=if($sealedApproval){if($allowed){'Approved'}elseif($item.Decision -ceq 'Include'){'NotInApprovedSource'}else{$item.Decision}}elseif($Catalog.Approval){'ApprovalNotSealed'}else{$item.Decision};$itemSelection=@($selectionRows|Where-Object ItemId -CEQ $item.ItemId);$selectionReason='';if($itemSelection.Count -and $itemSelection[0].PSObject.Properties['Reason']){$selectionReason=[string]$itemSelection[0].Reason};[pscustomobject]@{itemId=$item.ItemId;name=$item.Name;category=$item.Category;source=$item.NaturalKey;selected=($Selected.ContainsKey($item.ItemId) -and $Selected[$item.ItemId]);reason=$selectionReason;selectable=$allowed;selectionConstraint=$(if(-not $Catalog.PSObject.Properties['Assistive']){'AssistiveDisabled'}elseif($sealedApproval -and -not $allowed){'OutsideSealedSourceApproval'}else{$null});approvalStatus=$approvalStatus;executionStatus=$(if($ResultIndex.ContainsKey($item.ItemId)){$ResultIndex[$item.ItemId].Status}else{'NotObserved'});impact=(@($item.Dependencies).Count.ToString()+' dependencies; approval and restore preview remain required')}})}
}

function New-WsmHtmlError([string]$Message,[string]$Code,[string]$NextStep) {
    [pscustomobject]@{message=$Message;code=$Code;correlationId=[Guid]::NewGuid().ToString();nextStep=$NextStep}
}

function Get-WsmHtmlSafeError([string]$ExceptionMessage,[string]$ExceptionType='') {
    if($ExceptionMessage -match 'Review changed|Context changed') { return (New-WsmHtmlError 'The reviewed context or data changed.' 'stale_context' 'Refresh the context and view, then review the operation again.') }
    if($ExceptionMessage -match 'Interrupted workspace transaction|workspace.*requires? repair|Repair-WsmWorkspace') { return (New-WsmHtmlError 'The workspace needs recovery before it can be used.' 'workspace_recovery_required' 'Use the text menu or CLI Repair-WsmWorkspace workflow, and retain controlled materials until recovery is complete.') }
    if($ExceptionMessage -match 'RejectedToken') { return (New-WsmHtmlError 'This request was not accepted by the local console.' 'invalid_token' 'Refresh the console page to renew its local session, then try again.') }
    if($ExceptionMessage -match 'RejectedOrigin') { return (New-WsmHtmlError 'This request came from an unrecognized page origin.' 'rejected_origin' 'Use the console at its current local URL and retry from that page.') }
    if($ExceptionMessage -match 'RejectedHost') { return (New-WsmHtmlError 'This request used an unrecognized local address.' 'rejected_host' 'Open the console from its current local URL and retry.') }
    if($ExceptionType -ceq 'System.UnauthorizedAccessException' -or $ExceptionMessage -match 'UnauthorizedAccess|access.*denied|administrator privilege') { return (New-WsmHtmlError 'This operation needs permission that is not available to the current Windows user.' 'permission_denied' 'Ask an administrator to review the required permission and run the operation from the authorized account.') }
    if($ExceptionMessage -match 'worker limit|active jobs|Wait for active jobs') { return (New-WsmHtmlError 'A local operation is still active.' 'active_operation' 'Check the operation history and wait for the active operation to finish.') }
    if($ExceptionMessage -match '^ReportUnavailable') { return (New-WsmHtmlError 'The verified report is unavailable.' 'report_unavailable' 'Refresh operation history and verify the report still exists and matches its recorded hash.') }
    if($ExceptionMessage -match 'UnknownJob|Unknown report|hash changed|trusted file') { return (New-WsmHtmlError 'The requested operation or report is no longer available.' 'operation_unavailable' 'Refresh operation history and use its current report or recovery guidance.') }
    if($ExceptionMessage -match 'Unknown route|Unknown view|Unknown action|Invalid role|Unsupported operation|parameter|JSON body|Malformed|Duplicate query') { return (New-WsmHtmlError 'The request could not be used.' 'invalid_request' 'Review the current page and its fields, then try again.') }
    if($ExceptionMessage -match 'NoSafeCancellationBoundary|already stopped|requires a hash-bound safe cancellation') { return (New-WsmHtmlError 'The operation cannot be cancelled safely in its current state.' 'operation_not_cancellable' 'Inspect the operation history and authoritative journal before recovery.') }
    return (New-WsmHtmlError 'The local operation could not be completed.' 'operation_failed' 'Check operation history and the protected local logs before deciding whether to retry.')
}

function Get-WsmHtmlReplayResponse($Record) {
    if($Record.action -in @('SaveSelection','SetRestoreChoice','SetSoftwareVersion') -and $Record.status -ceq 'Succeeded' -and $Record.PSObject.Properties['revision']){return @{jobId=$Record.jobId;status='Saved';revision=[int]$Record.revision}}
    return @{job=(ConvertTo-WsmHtmlPublicJobRecord $Record)}
}

function Write-WsmHtmlErrorRecord([string]$ErrorRoot,$SafeError,[string]$Route,[string]$PairId) {
    $path=Join-Path $ErrorRoot 'errors.jsonl'
    if([IO.File]::Exists($path)){Assert-WsmNoReparse $path}
    $entry=[pscustomobject]@{utc=(Get-WsmUtc);correlationId=$SafeError.correlationId;code=$SafeError.code;route=$Route;pairId=$PairId}
    [IO.File]::AppendAllText($path,(($entry|ConvertTo-Json -Compress)+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
}

function ConvertTo-WsmHtmlPublicJobRecord($Record) {
    $public=[ordered]@{}
    foreach($property in $Record.PSObject.Properties){if($property.Name -notin @('idempotencyKey','RequestHash')){$public[$property.Name]=$property.Value}}
    [pscustomobject]$public
}

function Get-WsmHtmlViewSnapshot([string]$Workspace,[string]$PairId,[string]$View,[string]$Role,[string]$SessionId,[string]$ContextId,[string]$ExpectedDataVersion) {
    Invoke-WsmLocked $Workspace {
        $catalog=$null;$revision=0;$decisionRevision=$null;$selectionRevision=$null;$sourceSelectionRevision=$null
        if($PairId){$catalog=Get-WsmCatalog $Workspace $PairId;$revision=if($catalog.PSObject.Properties['Assistive']){[int]$catalog.Assistive.Revision}else{[int]$catalog.DecisionRevision};$decisionRevision=[int]$catalog.DecisionRevision;if($catalog.PSObject.Properties['Assistive'] -and $catalog.Assistive.PSObject.Properties['Selections']){$sourceSelectionRevision=[int]$catalog.Assistive.Selections.Revision;$selectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision}}
        $dataVersion=Get-WsmHtmlDataVersion $Workspace $PairId
        if($ExpectedDataVersion -and $ExpectedDataVersion -cne $dataVersion){throw 'Review changed: view data version is stale.'}
        $data=Get-WsmHtmlView $Workspace $PairId $View $Role
        if(-not $data.PSObject.Properties['stateReason']){
            $stateReason='目前資料已載入；請依畫面列出的有效證據、待辦與未知欄位判斷下一步。';$stateAction=$null
            if(-not $PairId){$stateReason='尚未選擇配對；先選擇或建立配對，再讀取目前資料。'}
            elseif(-not $catalog.PSObject.Properties['Assistive']){$stateReason='此配對尚未啟用輔助模式；請由管理角色啟用後再查看軟體、檔案及階段結果。';$stateAction='AssistiveEnable'}
            elseif($View -ceq 'software' -and -not $catalog.Assistive.SourceSnapshot){$stateReason='目前來源軟體快照不存在；請重新擷取來源盤點並檢查輔助模式來源證據。';$stateAction='Inventory'}
            elseif($View -ceq 'software' -and -not $catalog.Assistive.TargetCurrent){$stateReason='目前目標快照不存在；在目標主機擷取可信盤點後再比較軟體準備狀態。';$stateAction='TargetSnapshot'}
            elseif($View -ceq 'software' -and -not $catalog.Assistive.Comparison){$stateReason='目前尚無來源與目標軟體比較；先產生目前比較證據。';$stateAction='PublishComparison'}
            elseif($View -ceq 'overview' -and $data.PSObject.Properties['nextStep']){$stateReason=[string]$data.nextStep.reason;$stateNext=$data.nextStep.actionMetadata}
            if($data.PSObject.Properties['stateReason']){$stateReason=[string]$data.stateReason};if($data.PSObject.Properties['stateNextAction']){$stateNext=$data.stateNextAction}else{$stateNext=$null}
            if(-not $stateNext -and $stateAction){$candidate=@(Get-WsmHtmlActionMetadata $Role|Where-Object {$_.action -ceq $stateAction -and $_.roleAvailable}|Select-Object -First 1);if($candidate.Count){$stateNext=$candidate[0]}else{$stateReason+=' 目前角色需為 '+(Get-WsmTextActionGroup $stateAction)+'。'}}
            if(-not $data.PSObject.Properties['stateReason']){$data|Add-Member NoteProperty stateReason $stateReason -Force};if(-not $data.PSObject.Properties['stateNextAction']){$data|Add-Member NoteProperty stateNextAction $stateNext -Force}
        }
        if($PairId){$after=Get-WsmCatalog $Workspace $PairId;$afterRevision=if($after.PSObject.Properties['Assistive']){[int]$after.Assistive.Revision}else{[int]$after.DecisionRevision};$afterSelection=$null;$afterSourceSelection=$null;if($after.PSObject.Properties['Assistive'] -and $after.Assistive.PSObject.Properties['Selections']){$afterSourceSelection=[int]$after.Assistive.Selections.Revision;$afterSelection=[int](Get-WsmAssistiveCurrentSelections $after).Revision};if($afterRevision -ne $revision -or [int]$after.DecisionRevision -ne $decisionRevision -or $afterSelection -ne $selectionRevision -or $afterSourceSelection -ne $sourceSelectionRevision -or (Get-WsmHtmlDataVersion $Workspace $PairId) -cne $dataVersion){throw 'Review changed while reading the view.'}}
        $assistiveEnabled=($catalog -and $catalog.PSObject.Properties['Assistive'])
        $canSaveSelection=([bool]$PairId -and [bool]$assistiveEnabled)
        $data|Add-Member NoteProperty assistiveEnabled ([bool]$assistiveEnabled) -Force
        $data|Add-Member NoteProperty canSaveSelection ([bool]$canSaveSelection) -Force
        $data|Add-Member NoteProperty viewContext ([pscustomobject]@{sessionId=$SessionId;contextId=$ContextId;pairId=$PairId;role=$Role;revision=$revision;decisionRevision=$decisionRevision;selectionRevision=$selectionRevision;sourceSelectionRevision=$sourceSelectionRevision;dataVersion=$dataVersion;readUtc=(Get-WsmUtc)}) -Force
        $data
    }
}

function Get-WsmHtmlSpecReviewSnapshot([string]$Workspace,[string]$PairId,[string]$ItemId,[string]$Role,[string]$SessionId,[string]$ContextId,[string]$ExpectedDataVersion) {
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId;$revision=if($catalog.PSObject.Properties['Assistive']){[int]$catalog.Assistive.Revision}else{[int]$catalog.DecisionRevision};$decisionRevision=[int]$catalog.DecisionRevision;$selectionRevision=$null;$sourceSelectionRevision=$null;if($catalog.PSObject.Properties['Assistive'] -and $catalog.Assistive.PSObject.Properties['Selections']){$sourceSelectionRevision=[int]$catalog.Assistive.Selections.Revision;$selectionRevision=[int](Get-WsmAssistiveCurrentSelections $catalog).Revision};$dataVersion=Get-WsmHtmlDataVersion $Workspace $PairId;if($ExpectedDataVersion -and $ExpectedDataVersion -cne $dataVersion){throw 'Review changed: specification data version is stale.'}
        $data=Get-WsmAssistiveSpecReview -Workspace $Workspace -PairId $PairId -ItemId $ItemId
        $after=Get-WsmCatalog $Workspace $PairId;$afterRevision=if($after.PSObject.Properties['Assistive']){[int]$after.Assistive.Revision}else{[int]$after.DecisionRevision};$afterSelection=$null;$afterSourceSelection=$null;if($after.PSObject.Properties['Assistive'] -and $after.Assistive.PSObject.Properties['Selections']){$afterSourceSelection=[int]$after.Assistive.Selections.Revision;$afterSelection=[int](Get-WsmAssistiveCurrentSelections $after).Revision};if($afterRevision -ne $revision -or [int]$after.DecisionRevision -ne $decisionRevision -or $afterSelection -ne $selectionRevision -or $afterSourceSelection -ne $sourceSelectionRevision -or (Get-WsmHtmlDataVersion $Workspace $PairId) -cne $dataVersion){throw 'Review changed while reading the specification review.'}
        $data|Add-Member NoteProperty viewContext ([pscustomobject]@{sessionId=$SessionId;contextId=$ContextId;pairId=$PairId;role=$Role;revision=$revision;decisionRevision=$decisionRevision;selectionRevision=$selectionRevision;sourceSelectionRevision=$sourceSelectionRevision;dataVersion=$dataVersion;readUtc=(Get-WsmUtc)}) -Force
        $data
    }
}

function ConvertTo-WsmHtmlArguments($Command,$Arguments) {
    $result=@{};$common=@('Verbose','Debug','ErrorAction','ErrorVariable','OutVariable','OutBuffer','PipelineVariable','InformationAction','InformationVariable','WarningAction','WarningVariable','Confirm','WhatIf','ProgressAction')
    foreach($p in $Arguments.PSObject.Properties){
        if(-not $Command.Parameters.ContainsKey($p.Name) -or $p.Name -in $common){throw 'Unsupported operation parameter.'}
        $parameter=$Command.Parameters[$p.Name];if($parameter.ParameterType -eq [scriptblock] -or @($parameter.Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.DontShow}).Count){throw 'Internal operation parameter is prohibited.'};$value=$p.Value
        if($p.Name -ceq 'Secrets'){
            $value=@{};foreach($secret in @($p.Value)){
                Assert-WsmFields $secret @('Ref','Kind','Value','UserName','Password') @('Ref','Kind')
                if(-not $secret.Ref -or $value.ContainsKey($secret.Ref)){throw 'Invalid secret reference.'}
                if($secret.Kind -ceq 'Credential'){$secure=ConvertTo-SecureString ([string]$secret.Password) -AsPlainText -Force;$value[$secret.Ref]=New-Object Management.Automation.PSCredential([string]$secret.UserName,$secure)}
                elseif($secret.Kind -ceq 'SecureString'){$value[$secret.Ref]=ConvertTo-SecureString ([string]$secret.Value) -AsPlainText -Force}else{throw 'Unsupported secret kind.'}
            }
        }
        elseif($parameter.ParameterType -eq [hashtable] -or $parameter.ParameterType -eq [System.Collections.IDictionary]){$value=@{};foreach($entry in $p.Value.PSObject.Properties){$value[$entry.Name]=$entry.Value};if($p.Name -ceq 'Fields' -and $value.ContainsKey('IisPoolSettings')){$settings=@{};foreach($setting in $value.IisPoolSettings.PSObject.Properties){$settings[$setting.Name]=$setting.Value};$value.IisPoolSettings=$settings}}
        elseif($parameter.ParameterType -eq [object] -and $p.Value.PSObject.Properties['TrustedPath']){Assert-WsmFields $p.Value @('TrustedPath','TrustedSHA256') @('TrustedPath','TrustedSHA256');$value=Read-WsmTrustedJson $p.Value.TrustedPath $p.Value.TrustedSHA256}
        elseif($p.Name -ceq 'ExternalActivatedReceipts'){$value=@(foreach($reference in @($p.Value)){Assert-WsmFields $reference @('TrustedPath','TrustedSHA256') @('TrustedPath','TrustedSHA256');[pscustomobject]@{Result=(Read-WsmTrustedJson $reference.TrustedPath $reference.TrustedSHA256);IndependentHash=$reference.TrustedSHA256}})}
        elseif($parameter.ParameterType.IsArray -and @($p.Value | Where-Object {$_.PSObject.Properties['TrustedPath']}).Count){$value=@(foreach($reference in @($p.Value)){Assert-WsmFields $reference @('TrustedPath','TrustedSHA256') @('TrustedPath','TrustedSHA256');Read-WsmTrustedJson $reference.TrustedPath $reference.TrustedSHA256})}
        elseif($parameter.ParameterType -eq [Management.Automation.PSCredential]){Assert-WsmFields $p.Value @('UserName','Password') @('UserName','Password');$secure=ConvertTo-SecureString ([string]$p.Value.Password) -AsPlainText -Force;$value=New-Object Management.Automation.PSCredential([string]$p.Value.UserName,$secure)}
        elseif($parameter.ParameterType -eq [Security.SecureString]){$value=ConvertTo-SecureString ([string]$value) -AsPlainText -Force}
        $result[$p.Name]=$value
    }
    foreach($parameter in $Command.Parameters.Values){$mandatory=@($parameter.Attributes|Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0;if($mandatory -and $parameter.Name -cne 'CancellationToken' -and -not $result.ContainsKey($parameter.Name)){throw ('Required parameter missing: '+$parameter.Name)}}
    $result
}

function Read-WsmLocalHttpRequest($Client,[int]$MaximumBodyBytes=1048576,[ValidateRange(10,30000)][int]$MaximumRequestMilliseconds=5000) {
    $stream=$Client.GetStream();$stream.ReadTimeout=2000;$stream.WriteTimeout=2000;$deadline=[Diagnostics.Stopwatch]::StartNew()
    $header=New-Object 'System.Collections.Generic.List[byte]'
    while($true){$remaining=$MaximumRequestMilliseconds-$deadline.ElapsedMilliseconds;if($remaining -le 0){throw 'HTTP request deadline exceeded.'};$stream.ReadTimeout=[int][Math]::Min(2000,$remaining);$value=$stream.ReadByte();if($deadline.ElapsedMilliseconds -ge $MaximumRequestMilliseconds){throw 'HTTP request deadline exceeded.'};if($value -lt 0){throw 'Incomplete HTTP headers.'};$header.Add([byte]$value);if($header.Count -gt 8192){throw 'HTTP headers too large.'};$n=$header.Count;if($n -ge 4 -and $header[$n-4] -eq 13 -and $header[$n-3] -eq 10 -and $header[$n-2] -eq 13 -and $header[$n-1] -eq 10){break}}
    $lines=([Text.Encoding]::ASCII.GetString($header.ToArray())).Split(@("`r`n"),[StringSplitOptions]::None)
    if($lines[0] -notmatch '^(GET|POST) (/[^ ]*) HTTP/1\.[01]$'){throw 'Unsupported HTTP request line.'}
    $method=$Matches[1];$target=$Matches[2];$headers=@{}
    foreach($line in $lines[1..($lines.Length-1)]){if(-not $line){continue};if($line -notmatch '^([A-Za-z0-9-]+):[ \t]*(.*)$'){throw 'Invalid HTTP header.'};$name=$Matches[1].ToLowerInvariant();if($headers.ContainsKey($name)){throw 'Duplicate HTTP header.'};$headers[$name]=$Matches[2]}
    if($headers.ContainsKey('transfer-encoding')){throw 'Transfer-Encoding is unsupported.'}
    $length=0;if($headers.ContainsKey('content-length')){if($headers['content-length'] -notmatch '^\d{1,8}$'){throw 'Invalid content length.'};$length=[int]$headers['content-length']}
    if($length -gt $MaximumBodyBytes){throw 'HTTP body too large.'}
    $bytes=New-Object byte[] $length;$offset=0;while($offset -lt $length){$remaining=$MaximumRequestMilliseconds-$deadline.ElapsedMilliseconds;if($remaining -le 0){throw 'HTTP request deadline exceeded.'};$stream.ReadTimeout=[int][Math]::Min(2000,$remaining);$n=$stream.Read($bytes,$offset,$length-$offset);if($deadline.ElapsedMilliseconds -ge $MaximumRequestMilliseconds){throw 'HTTP request deadline exceeded.'};if($n -eq 0){throw 'Incomplete body.'};$offset+=$n}
    [pscustomobject]@{Method=$method;Target=$target;Headers=$headers;Body=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)}
}

function Write-WsmLocalHttpResponse($Client,[int]$Status,[string]$ContentType,[byte[]]$Bytes) {
    $names=@{200='OK';202='Accepted';204='No Content';400='Bad Request';401='Unauthorized';403='Forbidden';404='Not Found';409='Conflict';500='Internal Server Error'}
    $name=$names[$Status];if(-not $name){$name='Error'}
    $header="HTTP/1.1 $Status $name`r`nContent-Type: $ContentType`r`nContent-Length: $($Bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`r`n`r`n"
    $stream=$Client.GetStream();$head=[Text.Encoding]::ASCII.GetBytes($header);$stream.Write($head,0,$head.Length);$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush()
}

function Get-WsmHtmlRequestHash([string]$Workspace,[string]$PairId,[string]$Role,[string]$Action,$Arguments,[int]$ExpectedRevision,$ExpectedDecisionRevision=$null,$ExpectedSelectionRevision=$null,$ExpectedDataVersion=$null) {
    Get-WsmHashText ([ordered]@{Workspace=[IO.Path]::GetFullPath($Workspace).ToLowerInvariant();PairId=$PairId;Role=$Role;Action=$Action;Arguments=$Arguments;ExpectedRevision=$ExpectedRevision;ExpectedDecisionRevision=$ExpectedDecisionRevision;ExpectedSelectionRevision=$ExpectedSelectionRevision;ExpectedDataVersion=$ExpectedDataVersion}|ConvertTo-Json -Depth 30 -Compress)
}

function Get-WsmHtmlRequestHashForBody([string]$Workspace,[string]$PairId,[string]$Role,[string]$Action,$Body) {
    $decisionRevision=$null;$selectionRevision=$null;$dataVersion=$null
    if($Body.PSObject.Properties['expectedDecisionRevision']){$decisionRevision=$Body.expectedDecisionRevision}
    if($Body.PSObject.Properties['expectedSelectionRevision']){$selectionRevision=$Body.expectedSelectionRevision}
    if($Body.PSObject.Properties['expectedDataVersion']){$dataVersion=$Body.expectedDataVersion}
    Get-WsmHtmlRequestHash $Workspace $PairId $Role $Action $Body.args ([int]$Body.expectedRevision) $decisionRevision $selectionRevision $dataVersion
}

function Import-WsmHtmlJobHistory([string]$consoleRoot,[hashtable]$jobs,[hashtable]$keys) {
    foreach($old in @(Get-ChildItem -LiteralPath $consoleRoot -Filter '*.json' -File)){Assert-WsmNoReparse $old.FullName;$record=Read-WsmJson $old.FullName;Assert-WsmId ([string]$record.jobId);if([IO.Path]::GetFileNameWithoutExtension($old.Name) -cne [string]$record.jobId -or $jobs.ContainsKey([string]$record.jobId)){throw 'Invalid durable job identity.'};if($record.PSObject.Properties['idempotencyKey'] -and $record.PSObject.Properties['RequestHash']){Assert-WsmId ([string]$record.idempotencyKey);if([string]$record.RequestHash -notmatch '^[a-f0-9]{64}$' -or $keys.ContainsKey([string]$record.idempotencyKey)){throw 'Invalid durable idempotency record.'};$keys[[string]$record.idempotencyKey]=@{Hash=[string]$record.RequestHash;Id=[string]$record.jobId}};foreach($field in @('workspace','pairId','role','sessionId','contextId','startedRevision','startedDecisionRevision','startedSelectionRevision','startedDataVersion')){if(-not $record.PSObject.Properties[$field]){$record|Add-Member NoteProperty $field $null -Force}};if($record.status -in @('Running','CancelRequested')){$record.status='Interrupted';Write-WsmJson $old.FullName $record};$record|Add-Member NoteProperty canCancel $false -Force;$jobs[$record.jobId]=@{Record=$record;Path=$old.FullName;Handle=$null;PowerShell=$null;CancellationToken=$null}}
}

function Start-WsmHtmlConsole {
    [CmdletBinding()]param([string]$Workspace,[ValidateSet('Source','Target','Manager')][string]$Role='Manager',[string]$PairId,[ValidateRange(0,65535)][int]$Port=0,[switch]$NoBrowser,[string]$ReadyPath,[string]$StopFile)
    Assert-WsmNoReparse $Workspace
    if(-not [IO.Directory]::Exists($Workspace)){[void][IO.Directory]::CreateDirectory($Workspace);Protect-WsmDirectory $Workspace}
    $uiRoot=Join-Path $PSScriptRoot 'ui'
    foreach($asset in @('index.html','console.js','console.css','guide.html')){$path=Join-Path $uiRoot $asset;if(-not [IO.File]::Exists($path)){throw ('Required console asset is missing: '+$asset)};Assert-WsmNoReparse $path}
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port)
    $random=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($random)}finally{$rng.Dispose()}
    $token=[Convert]::ToBase64String($random);$sessionId=[Guid]::NewGuid().ToString();$contextId=[Guid]::NewGuid().ToString();$jobs=@{};$keys=@{}
    $listener.Start();$actualPort=$listener.LocalEndpoint.Port;$origin='http://127.0.0.1:'+$actualPort
    $modulePath=Join-Path $PSScriptRoot 'WindowsServerMigration.psd1'
    $consoleRoot=Join-Path $Workspace 'console-jobs';Assert-WsmNoReparse $consoleRoot;if(-not [IO.Directory]::Exists($consoleRoot)){[void][IO.Directory]::CreateDirectory($consoleRoot);Protect-WsmDirectory $consoleRoot};Assert-WsmNoReparse $consoleRoot
    $errorRoot=Join-Path $Workspace 'console-errors';Assert-WsmNoReparse $errorRoot;if(-not [IO.Directory]::Exists($errorRoot)){[void][IO.Directory]::CreateDirectory($errorRoot)};Assert-WsmNoReparse $errorRoot;Protect-WsmDirectory $errorRoot
    Import-WsmHtmlJobHistory $consoleRoot $jobs $keys
    try{
        if($ReadyPath){Write-WsmJson $ReadyPath ([pscustomobject]@{Url=$origin;SessionId=$sessionId;Pid=$PID})}
        Write-Host ('Local migration console: '+$origin)
        if(-not $NoBrowser){try{Start-Process $origin | Out-Null}catch{Write-Host 'A browser could not be opened. Open the printed local URL, or use -Action Menu for the text fallback.'}}
        while(-not ($StopFile -and [IO.File]::Exists($StopFile))){
            foreach($job in @($jobs.Values)){
                if($job.PowerShell -and $job.PowerShell.Streams.Progress.Count){$p=$job.PowerShell.Streams.Progress[$job.PowerShell.Streams.Progress.Count-1];$job.Record|Add-Member NoteProperty progress ([pscustomobject]@{activity=[string]$p.Activity;percent=[int]$p.PercentComplete}) -Force}
                if($job.Handle -and $job.Handle.IsCompleted){
                    $output=@();try{$output=@($job.PowerShell.EndInvoke($job.Handle));$code=Get-WsmOperationStatusCode $output;$job.Record.Status=if($code -eq 0){'Succeeded'}elseif($code -eq 3){'Cancelled'}elseif($code -eq 1){'Failed'}else{'ReviewRequired'};if($code -eq 1){$workerError=Get-WsmHtmlSafeError 'WorkerReportedFailure';$job.Record|Add-Member NoteProperty error $workerError -Force;try{Write-WsmHtmlErrorRecord $errorRoot $workerError '/worker' ([string]$job.Record.pairId)}catch{}}}catch{$job.Record.Status='Failed';$workerError=Get-WsmHtmlSafeError $_.Exception.Message $_.Exception.GetType().FullName;$job.Record|Add-Member NoteProperty error $workerError -Force;try{Write-WsmHtmlErrorRecord $errorRoot $workerError '/worker' ([string]$job.Record.pairId)}catch{}}
                    $job.Record|Add-Member NoteProperty outputs @(Get-WsmHtmlResultProjection $output) -Force
                    $job.Record|Add-Member NoteProperty reportArtifacts @(Get-WsmHtmlReportArtifacts $job.Record.action $job.Record.outputs) -Force
                    $job.Record.canCancel=$false
                    $job.Record.CompletedUtc=Get-WsmUtc;$job.Handle=$null;$job.PowerShell.Dispose();$job.PowerShell=$null;Write-WsmJson $job.Path $job.Record
                }
            }
            if(-not $listener.Pending()){Start-Sleep -Milliseconds 50;continue}
            $client=$listener.AcceptTcpClient()
            $requestSafeError=$null
            try{
                $request=Read-WsmLocalHttpRequest $client;$status=200;$type='application/json; charset=utf-8';$response=$null;$bytes=$null
                if(-not $request.Headers.ContainsKey('host') -or $request.Headers.host -cne ('127.0.0.1:'+$actualPort)){throw 'RejectedHost'}
                if($request.Headers.ContainsKey('origin') -and $request.Headers.origin -cne $origin){throw 'RejectedOrigin'}
                if($request.Method -ceq 'POST' -and (-not $request.Headers.ContainsKey('origin') -or $request.Headers.origin -cne $origin)){throw 'RejectedOrigin'}
                $uri=New-Object Uri($origin+$request.Target);$route=$uri.AbsolutePath
                $query=@{};foreach($part in $uri.Query.TrimStart('?').Split('&')){if($part){$kv=$part.Split('=',2);if($query.ContainsKey($kv[0])){throw 'Duplicate query parameter.'};$query[$kv[0]]=[Uri]::UnescapeDataString($(if($kv.Count -gt 1){$kv[1]}else{''}))}}
                $static=@{'/'='index.html';'/index.html'='index.html';'/console.js'='console.js';'/console.css'='console.css';'/guide.html'='guide.html';'/ui/'='index.html';'/ui/console.js'='console.js';'/ui/console.css'='console.css';'/ui/guide.html'='guide.html';'/ui/index.html'='index.html'}
                $docRoot=Join-Path ([IO.Path]::GetDirectoryName($PSScriptRoot)) 'docs'
                $documents=Get-WsmHtmlDocuments $docRoot
                if($documents.ContainsKey($route) -and $request.Method -ceq 'GET'){$file=$documents[$route];Assert-WsmNoReparse $file;$bytes=[IO.File]::ReadAllBytes($file);$type=if($file.EndsWith('.css')){'text/css; charset=utf-8'}else{'text/html; charset=utf-8'}}
                elseif($static.ContainsKey($route) -and $request.Method -ceq 'GET'){
                    $file=Join-Path (Join-Path $PSScriptRoot 'ui') $static[$route];Assert-WsmNoReparse $file;$bytes=[IO.File]::ReadAllBytes($file)
                    $type=if($file.EndsWith('.js')){'application/javascript; charset=utf-8'}elseif($file.EndsWith('.css')){'text/css; charset=utf-8'}else{'text/html; charset=utf-8'}
                }
                elseif($route -ceq '/api/session' -and $request.Method -ceq 'GET'){
                    $assetHashes=@{};foreach($asset in @('index.html','console.js','console.css','guide.html')){$file=Join-Path $uiRoot $asset;Assert-WsmNoReparse $file;$assetHashes['/ui/'+$asset]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()}
                    $contextSnapshot=Get-WsmHtmlContext $Workspace $PairId $Role $contextId
                    $response=@{token=$token;sessionId=$sessionId;contextId=$contextId;hostName=$env:COMPUTERNAME;role=$Role;workspace=$Workspace;pairId=$PairId;revision=$contextSnapshot.revision;decisionRevision=$contextSnapshot.decisionRevision;selectionRevision=$contextSnapshot.selectionRevision;sourceSelectionRevision=$contextSnapshot.sourceSelectionRevision;dataVersion=$contextSnapshot.dataVersion;principal=[Environment]::UserName;assetHashes=$assetHashes}
                }
                else{
                    if(-not $request.Headers.ContainsKey('x-wsm-token') -or $request.Headers['x-wsm-token'] -cne $token){throw 'RejectedToken'}
                    if($route -ceq '/api/context' -and $request.Method -ceq 'GET'){$response=Get-WsmHtmlContext $Workspace $PairId $Role $contextId}
                    elseif($route -ceq '/api/context' -and $request.Method -ceq 'POST'){
                        $change=ConvertFrom-WsmJson $request.Body;Assert-WsmFields $change @('pairId','role','expectedRevision','expectedDecisionRevision','expectedSelectionRevision','expectedDataVersion','contextId') @('pairId','role','expectedRevision','contextId')
                        $currentVector=Get-WsmHtmlRevisionVector $Workspace $PairId
                        if($change.contextId -cne $contextId -or [int]$change.expectedRevision -ne [int]$currentVector.revision -or -not (Test-WsmHtmlExpectedVector $change $currentVector)){$status=409;$response=New-WsmHtmlError 'The context or data changed before switching.' 'stale_context' 'Refresh the context and review the requested change again.'}
                        elseif(@($jobs.Values|Where-Object {$_.Handle -and -not $_.Handle.IsCompleted}).Count){$status=409;$response=New-WsmHtmlError 'A local operation is still active.' 'active_operation' 'Check operation history and wait for the active operation to finish.'}
                        else{
                            if($change.role -cnotin @('Source','Target','Manager')){throw 'Invalid role.'}
                            if($change.pairId){Assert-WsmId $change.pairId;[void](Get-WsmCatalog $Workspace $change.pairId)}
                            $PairId=[string]$change.pairId;$Role=[string]$change.role;$contextId=[Guid]::NewGuid().ToString();$response=Get-WsmHtmlContext $Workspace $PairId $Role $contextId
                        }
                    }
                    elseif($route -ceq '/api/jobs' -and $request.Method -ceq 'GET'){$response=@{items=@($jobs.Values|ForEach-Object {ConvertTo-WsmHtmlPublicJobRecord $_.Record})}}
                    elseif($route -match '^/api/jobs/([a-fA-F0-9-]{36})/reports/([0-9]+)/open$' -and $request.Method -ceq 'POST'){
                        $id=$Matches[1];$index=[int]$Matches[2];if(-not $jobs.ContainsKey($id)){throw 'UnknownJob'}
                        try{$record=$jobs[$id].Record;if(-not $record.PSObject.Properties['reportArtifacts'] -or $index -ge @($record.reportArtifacts).Count){throw 'Unavailable'}
                            $open=ConvertFrom-WsmJson $request.Body;Assert-WsmFields $open @('SHA256') @('SHA256');$artifact=$record.reportArtifacts[$index]
                            if($open.SHA256 -ine $artifact.SHA256){throw 'Unavailable'};Assert-WsmNoReparse $artifact.Path;Assert-WsmTrustedFile $artifact.Path $artifact.SHA256
                            Start-Process -FilePath $artifact.Path | Out-Null;$response=@{status='Opened';SHA256=$artifact.SHA256}
                        }catch{throw 'ReportUnavailable'}
                    }
                    elseif($route -match '^/api/jobs/([a-fA-F0-9-]{36})(/cancel)?$'){
                        $id=$Matches[1];$cancel=$Matches[2];if(-not $jobs.ContainsKey($id)){throw 'UnknownJob'};$job=$jobs[$id]
                        if($cancel -and $request.Method -ceq 'POST'){
                            if(-not $job.Handle -or $job.Handle.IsCompleted){throw 'Job has already stopped; inspect its authoritative journal before recovery.'}
                            if($job.CancellationToken){Request-WsmCancellation -Token $job.CancellationToken -Owner ([Environment]::UserName) -Evidence 'User requested cancellation from local HTML console' | Out-Null;$job.Record.Status='CancelRequested'}else{throw 'NoSafeCancellationBoundary'}
                        }
                        $response=ConvertTo-WsmHtmlPublicJobRecord $job.Record
                    }
                    elseif($route -ceq '/api/spec-review' -and $request.Method -ceq 'GET'){
                        if($query.ContainsKey('contextId') -and $query.contextId -cne $contextId){$status=409;$response=New-WsmHtmlError 'The console context changed before this review was read.' 'stale_context' 'Refresh the current context and request the review again.'}
                        else{$response=Get-WsmHtmlSpecReviewSnapshot $Workspace $PairId $query.itemId $Role $sessionId $contextId $query.dataVersion}
                    }
                    elseif($route -ceq '/api/view' -and $request.Method -ceq 'GET'){
                        if($query.ContainsKey('contextId') -and $query.contextId -cne $contextId){$status=409;$response=New-WsmHtmlError 'The console context changed before this view was read.' 'stale_context' 'Refresh the context and request the view again.'}
                        else{$viewDataVersion=if($query.ContainsKey('dataVersion')){[string]$query['dataVersion']}else{''};$response=Get-WsmHtmlViewSnapshot $Workspace $PairId $query.action $Role $sessionId $contextId $viewDataVersion}
                    }
                    elseif($route -in @('/api/operations','/api/view') -and $request.Method -ceq 'POST'){
                        if(-not $request.Headers.ContainsKey('content-type') -or $request.Headers['content-type'] -notmatch '^application/json(?:;|$)'){throw 'JSON body required.'}
                        $body=ConvertFrom-WsmJson $request.Body
                        Assert-WsmFields $body @('action','args','operationId','idempotencyKey','expectedRevision','expectedDecisionRevision','expectedSelectionRevision','expectedDataVersion','contextId') @('action','args','expectedRevision','contextId')
                        if($body.contextId -cne $contextId){$status=409;throw 'Review changed: context changed.'}
                        $map=Get-WsmHtmlActionMap;if(-not $map.Contains($body.action)){throw 'Unknown action.'}
                        $requestHash=$null
                        if($route -ceq '/api/operations'){
                            Assert-WsmId ([string]$body.operationId);Assert-WsmId ([string]$body.idempotencyKey)
                            $requestHash=Get-WsmHtmlRequestHashForBody $Workspace $PairId $Role $body.action $body
                        }
                        $currentVector=Get-WsmHtmlRevisionVector $Workspace $PairId;$revision=[int]$currentVector.revision
                        if([int]$body.expectedRevision -ne $revision -or -not (Test-WsmHtmlExpectedVector $body $currentVector)){
                            $replayed=$false
                            if($route -ceq '/api/operations' -and $body.PSObject.Properties['operationId'] -and $body.PSObject.Properties['idempotencyKey']){
                                Assert-WsmId ([string]$body.operationId);Assert-WsmId ([string]$body.idempotencyKey)
                                if($keys.ContainsKey($body.idempotencyKey)){
                                    $prior=$keys[$body.idempotencyKey]
                                    if($prior.Hash -cne $requestHash -or $prior.Id -cne $body.operationId){throw 'Idempotency key was reused with different input.'}
                                    $response=Get-WsmHtmlReplayResponse $jobs[$prior.Id].Record;$replayed=$true
                                }
                            }
                            if(-not $replayed){$status=409;$response=New-WsmHtmlError 'The reviewed data changed before this operation was submitted.' 'stale_revision' 'Refresh the current view, review the change, and submit a new operation if it is still needed.';$response|Add-Member NoteProperty currentRevision $revision -Force}
                        }
                        else{
                            $command=Get-Command $map[$body.action] -CommandType Function
                            foreach($binding in @(@('Workspace',$Workspace),@('PairId',$PairId))){if($command.Parameters.ContainsKey($binding[0]) -and -not $body.args.PSObject.Properties[$binding[0]]){$body.args | Add-Member NoteProperty $binding[0] $binding[1]}}
                            $nativeRevisionParameter=switch([string]$body.action){
                                'OsProvidedCapture' {'DecisionRevision'}
                                'OsProvidedBaseline' {'ExpectedDecisionRevision'}
                                'OsProvidedSubmit' {'ExpectedDecisionRevision'}
                                default {$null}
                            }
                            if($nativeRevisionParameter){
                                if(-not $PairId){throw 'OSProvided actions require a current pair and native catalog revision.'}
                                $nativeDecisionRevision=[int]$currentVector.decisionRevision
                                $provided=$body.args.PSObject.Properties[$nativeRevisionParameter]
                                if($provided){$parsedRevision=0;if(-not [int]::TryParse([string]$provided.Value,[ref]$parsedRevision) -or $parsedRevision -ne $nativeDecisionRevision){$status=409;throw 'Review changed: native decision revision no longer matches the reviewed operation.'}}
                                else{$body.args | Add-Member NoteProperty $nativeRevisionParameter $nativeDecisionRevision}
                            }
                            if($command.Parameters.ContainsKey('ExpectedRevision') -and -not $body.args.PSObject.Properties['ExpectedRevision']){
                                if($command.Name -in @('Reserve-WsmAssistiveResource','Set-WsmAssistiveResourceEvidence','Release-WsmAssistiveResource','Set-WsmAssistiveMaterialClosed','Invoke-WsmAssistiveCleanup')){throw 'Resource registry revision from the reviewed preview is required.'}
                                $nativeRevision=$revision
                                if($PairId -and ($command.Name -notmatch 'Assistive|Set-WsmHtml' -or $command.Name -in @('Submit-WsmAssistiveWindowsSettingsReview','Submit-WsmAssistiveGeneralHostDispositions','Submit-WsmAssistiveGeneralHostRequirements','Submit-WsmAssistiveGeneralHostRequirementDecisions'))){$nativeRevision=[int]$currentVector.decisionRevision}
                                $body.args | Add-Member NoteProperty ExpectedRevision $nativeRevision
                            }
                            $arguments=ConvertTo-WsmHtmlArguments $command $body.args
                            if($route -ceq '/api/operations' -and $body.action -ceq 'SetSoftwareVersion'){
                                $arguments.BeforeWrite=New-WsmHtmlSoftwareBeforeWrite $Workspace $PairId $currentVector
                            }
                            foreach($binding in @(@('Workspace',$Workspace),@('PairId',$PairId))){if($command.Parameters.ContainsKey($binding[0]) -and -not $arguments.ContainsKey($binding[0])){$arguments[$binding[0]]=$binding[1]}}
                            if($arguments.ContainsKey('Workspace') -and [IO.Path]::GetFullPath($arguments.Workspace) -ine [IO.Path]::GetFullPath($Workspace)){throw 'Session workspace mismatch.'}
                            if($arguments.ContainsKey('PairId') -and $arguments.PairId -cne $PairId){throw 'Session pair mismatch.'}
                            if($route -ceq '/api/view'){
                                $previewMap=@{Restore='RestorePreview';Rollback='RollbackPreview';SpecBundleImport='SpecBundlePreview'}
                                $result=$null;$kind='ParametersOnly'
                                if($previewMap.ContainsKey($body.action)){
                                    $previewCommand=Get-Command $map[$previewMap[$body.action]] -CommandType Function;$previewArgs=@{}
                                    foreach($key in $arguments.Keys){if($previewCommand.Parameters.ContainsKey($key)){$previewArgs[$key]=$arguments[$key]}}
                                    $result=& $previewCommand @previewArgs;$kind='ResourcePreview'
                                }elseif($command.Name -match '^(Get|Test|Assert|Read)-'){$result=& $command @arguments;$kind='ResourcePreview'}
                                $response=ConvertTo-WsmHtmlPreview $result $body.action $revision $kind
                            }
                            else{
                                Assert-WsmId ([string]$body.operationId);Assert-WsmId ([string]$body.idempotencyKey)
                                $hash=$requestHash
                                if($keys.ContainsKey($body.idempotencyKey)){
                                    $prior=$keys[$body.idempotencyKey];if($prior.Hash -cne $hash -or $prior.Id -cne $body.operationId){throw 'Idempotency key was reused with different input.'};$response=Get-WsmHtmlReplayResponse $jobs[$prior.Id].Record
                                }
                                elseif($jobs.ContainsKey($body.operationId)){throw 'Operation ID already used.'} elseif(@($jobs.Values | Where-Object {$_.Record.status -in @('Running','CancelRequested')}).Count -ge 8){$status=409;$response=New-WsmHtmlError 'The local worker limit is reached.' 'worker_limit' 'Check operation history and wait for an active operation to finish.'}
                                elseif($body.action -in @('SaveSelection','SetRestoreChoice','SetSoftwareVersion')){
                                    $record=[pscustomobject]@{jobId=$body.operationId;action=$body.action;idempotencyKey=[string]$body.idempotencyKey;RequestHash=$hash;Actor=(Get-WsmExecutionActor);workspace=$Workspace;pairId=$PairId;role=$Role;sessionId=$sessionId;contextId=$contextId;startedRevision=$revision;startedDecisionRevision=$currentVector.decisionRevision;startedSelectionRevision=$currentVector.selectionRevision;startedDataVersion=$currentVector.dataVersion;status='Running';StartedUtc=(Get-WsmUtc);CompletedUtc=$null;canCancel=$false}
                                    $recordPath=Join-Path $consoleRoot ($body.operationId+'.json');Write-WsmJson $recordPath $record;$jobs[$body.operationId]=@{Record=$record;Path=$recordPath;Handle=$null;PowerShell=$null;CancellationToken=$null};$keys[$body.idempotencyKey]=@{Hash=$hash;Id=$body.operationId}
                                    try{
                                        $arguments.ExpectedRevision=[int]$body.expectedRevision
                                        if($body.action -in @('SaveSelection','SetRestoreChoice')){
                                            if($body.PSObject.Properties['expectedDecisionRevision']){$arguments.ExpectedDecisionRevision=$body.expectedDecisionRevision}
                                            if($body.PSObject.Properties['expectedSelectionRevision']){$arguments.ExpectedSelectionRevision=$body.expectedSelectionRevision}
                                            if($body.PSObject.Properties['expectedDataVersion']){$arguments.ExpectedDataVersion=[string]$body.expectedDataVersion}
                                        }
                                        $result=& $command @arguments
                                        $savedRevision=$null;if($result -and $result.PSObject.Properties['Revision']){$savedRevision=[int]$result.Revision}elseif($result -and $result.PSObject.Properties['Assistive'] -and $result.Assistive.PSObject.Properties['Revision']){$savedRevision=[int]$result.Assistive.Revision}
                                        if($null -eq $savedRevision){throw 'Quick-save operation did not return its authoritative revision.'}
                                        $record.status='Succeeded';$record.CompletedUtc=Get-WsmUtc;$record|Add-Member NoteProperty revision $savedRevision -Force;Write-WsmJson $recordPath $record;$response=@{jobId=$record.jobId;revision=$record.revision;status='Saved'}
                                    }
                                    catch{$requestSafeError=Get-WsmHtmlSafeError $_.Exception.Message $_.Exception.GetType().FullName;$record.status='Failed';$record.CompletedUtc=Get-WsmUtc;$record|Add-Member NoteProperty error $requestSafeError -Force;Write-WsmJson $recordPath $record;throw}
                                }
                                else{
                                    $record=[pscustomobject]@{jobId=$body.operationId;action=$body.action;idempotencyKey=[string]$body.idempotencyKey;RequestHash=$hash;Actor=(Get-WsmExecutionActor);workspace=$Workspace;pairId=$PairId;role=$Role;sessionId=$sessionId;contextId=$contextId;startedRevision=$revision;startedDecisionRevision=$currentVector.decisionRevision;startedSelectionRevision=$currentVector.selectionRevision;startedDataVersion=$currentVector.dataVersion;status='Running';StartedUtc=(Get-WsmUtc);CompletedUtc=$null;canCancel=$false}
                                    $recordPath=Join-Path $consoleRoot ($body.operationId+'.json')
                                    $cancellation=New-WsmHtmlCancellation $command $arguments $body.operationId
                                    if($command.Parameters.ContainsKey('CancellationToken') -and @($command.Parameters['CancellationToken'].Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -and -not $cancellation){throw 'This operation requires a hash-bound safe cancellation context before submission.'}
                                    if($cancellation){$arguments.CancellationToken=$cancellation}
                                    $worker=[Management.Automation.PowerShell]::Create()
                                    [void]$worker.AddScript('param($modulePath,$commandName,$arguments) Import-Module $modulePath -Force -DisableNameChecking; $ConfirmPreference="None"; $ErrorActionPreference="Stop"; $command=Get-Command $commandName -CommandType Function; if($command.Parameters.ContainsKey("Confirm")){$arguments.Confirm=$false}; & $command @arguments').AddArgument($modulePath).AddArgument($command.Name).AddArgument($arguments)
                                    $record.canCancel=($null -ne $cancellation);Write-WsmJson $recordPath $record
                                    $handle=$worker.BeginInvoke();$jobs[$body.operationId]=@{Record=$record;Path=$recordPath;PowerShell=$worker;Handle=$handle;CancellationToken=$cancellation};$keys[$body.idempotencyKey]=@{Hash=$hash;Id=$body.operationId};$status=202;$response=@{job=(ConvertTo-WsmHtmlPublicJobRecord $record)}
                                    $arguments=$null
                                }
                            }
                        }
                        $body=$null
                    }
                    else{$status=404;$response=New-WsmHtmlError 'The requested route is unavailable.' 'invalid_request' 'Return to the console and use one of its current actions.'}
                }
                if($response -and $response.PSObject.Properties['correlationId'] -and $response.PSObject.Properties['code']){try{Write-WsmHtmlErrorRecord $errorRoot $response $route $PairId}catch{}}
                if($null -eq $bytes){$jsonResponse=$response|ConvertTo-Json -Depth 30 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($jsonResponse)}
                Write-WsmLocalHttpResponse $client $status $type $bytes
            }catch{
                $status=400;if($_.Exception.Message -match '^Rejected'){$status=403}elseif($_.Exception.Message -match 'Review changed|Context changed'){$status=409}elseif($_.Exception.Message -match 'UnknownJob|Unknown route'){$status=404}
                $safeError=$requestSafeError;if(-not $safeError){$safeError=Get-WsmHtmlSafeError $_.Exception.Message $_.Exception.GetType().FullName}
                try{Write-WsmHtmlErrorRecord $errorRoot $safeError $route $PairId}catch{}
                try{$errorBytes=[Text.Encoding]::UTF8.GetBytes(($safeError|ConvertTo-Json -Compress));Write-WsmLocalHttpResponse $client $status 'application/json; charset=utf-8' $errorBytes}catch{}
            }finally{$client.Dispose()}
        }
    }finally{
        $listener.Stop()
        foreach($job in @($jobs.Values)){if($job.PowerShell){$job.PowerShell.Stop();$job.PowerShell.Dispose();$job.Record.Status='Interrupted';Write-WsmJson $job.Path $job.Record}}
        $token=$null;$keys.Clear()
    }
}
