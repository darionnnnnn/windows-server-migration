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
    param([string]$Workspace,[string]$PairId,[int]$ExpectedRevision,[string[]]$SelectedItemIds,$UnselectedItems)
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Review changed.'}
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
    param([string]$Workspace,[string]$PairId,[int]$ExpectedRevision,[ValidateSet('RestoreNow','WaitForInstall')][string]$Choice)
    $projection=Get-WsmAssistiveComparison $Workspace $PairId
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Review changed.'}
        if($projection.SourceSnapshotHash -ine $catalog.Assistive.SourceSnapshot.SHA256 -or -not $catalog.Assistive.TargetCurrent -or $projection.TargetSnapshotHash -ine $catalog.Assistive.TargetCurrent.SHA256 -or $projection.SelectionRevision -ne $catalog.Assistive.Selections.Revision){throw 'Review changed. Refresh target comparison.'}
        if(-not $catalog.Assistive.Comparison){$catalog.Assistive.Comparison=$projection;$catalog.Assistive.ComparisonRevisionCounter=$projection.Revision}
        $record=[pscustomobject]@{Choice=$Choice;ComparisonRevision=$catalog.Assistive.Comparison.Revision;SourceSnapshotHash=$catalog.Assistive.SourceSnapshot.SHA256;TargetSnapshotHash=$catalog.Assistive.TargetCurrent.SHA256;SelectionRevision=$catalog.Assistive.Selections.Revision;Owner=[Environment]::UserName;CreatedUtc=(Get-WsmUtc);ExecutionAuthorized=$false}
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
    $reviewValue=@{properties=@{FieldPointer=@{type='string';required=$true};Value=@{type='string';required=$true;allowEmpty=$true;sensitive=$true}}}
    $bindings=@{properties=@{Index=@{type='integer';required=$true};Protocol=@{type='enum';options=@('http','https');required=$true};BindingInformation=@{type='string';required=$true};CertificateHash=@{type='string';required=$true;allowEmpty=$true};CertificateStoreName=@{type='string';required=$true;allowEmpty=$true};SslFlags=@{type='integer';required=$true}}}
    $apps=@{properties=@{Index=@{type='integer';required=$true};ApplicationPath=@{type='path';required=$true};PoolName=@{type='string';required=$true}}}
    $schemas.Fields=@{TargetPath=@{type='path'};TransferChannel=@{type='enum';options=@('C','NonC','External')};ContentSelection=@{type='enum';options=@('ExactFiles','WholeScope')};ExcludedRelativePaths=@{type='stringArray'};Consistency=@{type='enum';options=@('OwnerFreeze','Immutable')};Metadata=@{type='enum';options=@('DaclOwner','DaclOwnerSacl')};ConflictPolicy=@{type='enum';options=@('Block')};ConfigFiles=@{type='objectArray';schema=$configFile};DesiredFinalState=@{type='enum';options=@('Disabled','Enabled')};BusinessChecks=@{type='stringArray'};Product=@{type='string'};Procedure=@{type='string'};Artifacts=@{type='stringArray'};CatchUpPolicy=@{type='enum';options=@('PreserveSourceSettings','SkipMissedRuns','DedicatedManualCatchUp')};WorkloadFieldReviews=@{type='objectArray';schema=$reviewValue};IisBindings=@{type='objectArray';schema=$bindings};IisApplicationPools=@{type='objectArray';schema=$apps};IisPoolSettings=@{type='map'};ActivationOwner=@{type='string'};ActivationReason=@{type='string'};PrincipalUser=@{type='string'}}
    $schemas.Fields.SharedResourceReviewReasons=@{type='objectArray';schema=@{properties=@{ResourceItemId=@{type='string';required=$true};ConsumerItemIds=@{type='stringArray';required=$true};Owner=@{type='string';required=$true};Reason=@{type='string';required=$true}}}}
    $schemas.Fields.ActivationPolicyFieldPointer=@{type='string'}
    $schemas.RequirementDecisions=@{properties=@{RequirementId=@{type='string';required=$true};Decision=@{type='enum';options=@('Pending','Required','NotNeeded');required=$true};Owner=@{type='string';required=$true};DecisionReason=@{type='string';required=$true};DecisionEvidence=@{type='string';required=$true}}}
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
        [pscustomobject]@{action=$entry.Key;label=$entry.Key;description=$entry.Value;role=$Role;readOnly=$readOnly;impact=@($(if($readOnly){'Read local state'}else{'Write local state or approved system resources'}));previewAction=$previewAction;parameters=$parameters}
    }
}

function Get-WsmHtmlRevision([string]$Workspace,[string]$PairId) {
    if(-not $PairId){return 0}
    $catalog=Get-WsmCatalog $Workspace $PairId
    if($catalog.PSObject.Properties['Assistive']){return [int]$catalog.Assistive.Revision}
    [int]$catalog.DecisionRevision
}

function Get-WsmHtmlContext([string]$Workspace,[string]$PairId,[string]$Role,[string]$ContextId) {
    $pairs=@()
    if([IO.File]::Exists((Join-Path $Workspace 'fleet.json'))){$pairs=@((Get-WsmFleet $Workspace).Pairs|ForEach-Object {[pscustomobject]@{pairId=$_.PairId;label=$_.PairId}})}
    [pscustomobject]@{workspace=$Workspace;pairId=$PairId;role=$Role;contextId=$ContextId;revision=(Get-WsmHtmlRevision $Workspace $PairId);pairs=$pairs;roles=@('Source','Target','Manager')}
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
    $fields=@('Status','Stage','Path','SHA256','Hash','ReportPath','HtmlPath','ManifestPath','ManifestHash','Archive','ArchiveSHA256','RunId','PairId','Generation','Revision','ObservedChecks','PendingChecks','SpecPath','SpecHash','ReceiptPath','ReceiptHash','DecisionRevision','AssistiveRevision','SelectionRevision','TargetPhysicalId','RegistryRevision','ResourceKey','DocumentManifestPath','DocumentManifestHash','DocumentId','BundlePath','MemberCount','Valid','ProbeStatus','IndexPath','Kind','ExpectedRevision','PreviewPath','PreviewFileHash','PreviewHash','ReviewWindowsSettings','RowCount','SourceInventoryPath','SourceInventoryHash','TargetInventoryPath','TargetInventoryHash','GeneratedDecisionsPath','GeneratedDecisionsHash','GeneratedRequirementsPath','GeneratedRequirementsHash','FailureCode','ReviewHash')
    @(foreach($row in @($Output)){$safe=[ordered]@{};foreach($field in $fields){if($row -and $row.PSObject.Properties[$field]){$value=$row.$field;if($value -is [string] -or $value -is [ValueType]){$safe[$field]=$value}}};if($row -and $row.PSObject.Properties['Kind'] -and $row.Kind -cin @('AssistiveWindowsSettingsPreviewOutput','AssistivePreparationPreview','AssistiveRequirementReview')){
            $rowFields=if($row.Kind -ceq 'AssistiveWindowsSettingsPreviewOutput'){@('SettingId','SourceItemId','Category','Kind','SettingName','SourceValueHash','TargetValueHash','TargetDiff','ControlSource','SupportedActions','DefaultAction','RequiredConsumerItemIds')}else{@('RequirementId','Type','ProviderItemId','ExternalId','ProviderSoftwareId','ExpectedVersion','Architecture','RequiredPhase','Decision','Certainty','ConsumerItemIds','ContextHash')}
            $safe.Rows=@(foreach($entry in @($row.Rows)){$record=[ordered]@{};foreach($field in $rowFields){if($entry.PSObject.Properties[$field]){$value=$entry.$field;if($value -is [string] -or $value -is [ValueType]){$record[$field]=$value}elseif($value -is [array]){$record[$field]=@($value | Where-Object {$_ -is [string]})}}};[pscustomobject]$record})
        };if($safe.Count){[pscustomobject]$safe}})
}

function Get-WsmHtmlReportArtifacts([string]$Action,$Outputs) {
    if($Action -notin @('Report','FleetReport','AssistiveReport','EnvironmentProbe','HttpIntegrityProbe','LabReport','MigrationReport','DeliveryDocument')){return}
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
    if($View -ceq 'actions'){return [pscustomobject]@{actions=@(Get-WsmHtmlActionMetadata $Role)}}
    if(-not $PairId){return [pscustomobject]@{items=@();metrics=@{discovered=0;selected=0;approved=0;executable=0;pendingOrFailed=0};workloadStatus='NotStarted'}}
    $catalog=Get-WsmCatalog $Workspace $PairId
    $stage=Get-WsmAssistiveReportStageResults $catalog
    $resultIndex=@{};if($stage.Latest -and $stage.Latest.PSObject.Properties['Assistive']){foreach($row in @($stage.Latest.Assistive.ItemResults)){$resultIndex[[string]$row.ItemId]=$row}}
    $selected=@{};if($catalog.PSObject.Properties['Assistive']){foreach($selection in (Get-WsmAssistiveCurrentSelections $catalog).Items){$selected[$selection.ItemId]=$selection.Selected}}
    switch($View){
        inventory {
            [pscustomobject]@{items=@(foreach($item in $catalog.Items){[pscustomobject]@{itemId=$item.ItemId;name=$item.Name;category=$item.Category;source=$item.NaturalKey;selected=($selected.ContainsKey($item.ItemId) -and $selected[$item.ItemId]);reason=$(if($catalog.PSObject.Properties['Assistive']){[string]@((Get-WsmAssistiveCurrentSelections $catalog).Items|Where-Object ItemId -CEQ $item.ItemId)[0].Reason}else{''});selectable=($null -eq $catalog.Approval -or $item.Decision -ceq 'Include');approvalStatus=$(if($catalog.Approval -and $item.Decision -eq 'Include'){'Approved'}else{$item.Decision});executionStatus=$(if($resultIndex.ContainsKey($item.ItemId)){$resultIndex[$item.ItemId].Status}else{'NotObserved'});impact=(@($item.Dependencies).Count.ToString()+' dependencies; approval and restore preview remain required')}})}
        }
        software {
                        if(Get-Command Get-WsmAssistiveComparison -ErrorAction SilentlyContinue){
                $comparison=Get-WsmAssistiveComparison $Workspace $PairId
                [pscustomobject]@{rows=@(foreach($row in $comparison.Rows){[pscustomobject]@{softwareId=$row.SoftwareId;name=$row.Name;sourceVersion=$row.SourceVersion;chosenVersion=$row.ChosenVersion;observedVersion=$row.ObservedTargetVersion;status=$row.Status;manualAction=$row.Reason;versionChoices=@([pscustomobject]@{label=$row.SourceVersion;value=$row.SourceVersion});versionSelectionAction='SetSoftwareVersion'}});manualPreparation=$comparison.ManualPreparation;comparisonRevision=$comparison.Revision}
            }else{[pscustomobject]@{rows=@()}}
        }
        files {
            if($stage.Latest -and $stage.Latest.PSObject.Properties['Assistive'] -and $stage.Latest.Assistive.PSObject.Properties['FileResults']){return [pscustomobject]@{rows=@(foreach($file in $stage.Latest.Assistive.FileResults){[pscustomobject]@{itemId=$file.ItemId;sourcePath=$file.OriginalPath;preservedPath=$file.PreservedPath;effectivePath=$(if($file.EffectivePath){$file.EffectivePath}else{'NotObserved'});placementStatus=$file.Status;reason=$file.Reason;existingTargetPath=$file.ExistingTargetPath;existingTargetHash=$file.ExistingTargetHash;sourceHash=$file.SourceHash;observedHash=$file.ObservedHash;scopeImpact=$file.ItemId}})}}
            [pscustomobject]@{rows=@(foreach($item in $catalog.Items){if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec -and $item.MigrationSpec.Adapter -eq 'FileScope'){[pscustomobject]@{itemId=$item.ItemId;sourcePath=$item.MigrationSpec.SourcePath;preservedPath=$item.MigrationSpec.TargetPath;effectivePath='NotObserved';placementStatus='ReviewRequired';reason='Use file placement and restore preview on the target for per-file evidence.';scopeImpact=$item.Name}}})}
        }
        overview {
            $selectedCount=@($selected.Values | Where-Object {$_}).Count
            [pscustomobject]@{metrics=@{discovered=@($catalog.Items).Count;selected=$selectedCount;approved=$(if($catalog.Approval){@($catalog.Items|Where-Object Decision -EQ Include).Count}else{0});executable='NotMeasured';pendingOrFailed=$(if($stage.Latest -and $stage.Latest.PSObject.Properties['Assistive']){@($stage.Latest.Assistive.ItemResults | Where-Object {$_.Pending -or $_.Deferred}).Count}else{'NotMeasured'})};workloadStatus=$(if($stage.Latest){$stage.Latest.Status}else{'NotObserved'});nextStep=@{title='Review inventory and target preparation';description='Selection does not authorize execution. Verify target software, paths and the approved workload.'};steps=@()}
        }
        default {throw 'Unknown view.'}
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

function Get-WsmHtmlRequestHash([string]$Workspace,[string]$PairId,[string]$Role,[string]$Action,$Arguments,[int]$ExpectedRevision) {
    Get-WsmHashText ([ordered]@{Workspace=[IO.Path]::GetFullPath($Workspace).ToLowerInvariant();PairId=$PairId;Role=$Role;Action=$Action;Arguments=$Arguments;ExpectedRevision=$ExpectedRevision}|ConvertTo-Json -Depth 30 -Compress)
}

function Import-WsmHtmlJobHistory([string]$consoleRoot,[hashtable]$jobs,[hashtable]$keys) {
    foreach($old in @(Get-ChildItem -LiteralPath $consoleRoot -Filter '*.json' -File)){Assert-WsmNoReparse $old.FullName;$record=Read-WsmJson $old.FullName;Assert-WsmId ([string]$record.jobId);if([IO.Path]::GetFileNameWithoutExtension($old.Name) -cne [string]$record.jobId -or $jobs.ContainsKey([string]$record.jobId)){throw 'Invalid durable job identity.'};if($record.PSObject.Properties['idempotencyKey'] -and $record.PSObject.Properties['RequestHash']){Assert-WsmId ([string]$record.idempotencyKey);if([string]$record.RequestHash -notmatch '^[a-f0-9]{64}$' -or $keys.ContainsKey([string]$record.idempotencyKey)){throw 'Invalid durable idempotency record.'};$keys[[string]$record.idempotencyKey]=@{Hash=[string]$record.RequestHash;Id=[string]$record.jobId}};if($record.status -in @('Running','CancelRequested')){$record.status='Interrupted';Write-WsmJson $old.FullName $record};$record|Add-Member NoteProperty canCancel $false -Force;$jobs[$record.jobId]=@{Record=$record;Path=$old.FullName;Handle=$null;PowerShell=$null;CancellationToken=$null}}
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
    $consoleRoot=Join-Path $Workspace 'console-jobs';if(-not [IO.Directory]::Exists($consoleRoot)){[void][IO.Directory]::CreateDirectory($consoleRoot);Protect-WsmDirectory $consoleRoot};Assert-WsmNoReparse $consoleRoot
    Import-WsmHtmlJobHistory $consoleRoot $jobs $keys
    try{
        if($ReadyPath){Write-WsmJson $ReadyPath ([pscustomobject]@{Url=$origin;SessionId=$sessionId;Pid=$PID})}
        Write-Host ('Local migration console: '+$origin)
        if(-not $NoBrowser){try{Start-Process $origin | Out-Null}catch{Write-Host 'A browser could not be opened. Open the printed local URL, or use -Action Menu for the text fallback.'}}
        while(-not ($StopFile -and [IO.File]::Exists($StopFile))){
            foreach($job in @($jobs.Values)){
                if($job.PowerShell -and $job.PowerShell.Streams.Progress.Count){$p=$job.PowerShell.Streams.Progress[$job.PowerShell.Streams.Progress.Count-1];$job.Record|Add-Member NoteProperty progress ([pscustomobject]@{activity=[string]$p.Activity;percent=[int]$p.PercentComplete}) -Force}
                if($job.Handle -and $job.Handle.IsCompleted){
                    $output=@();try{$output=@($job.PowerShell.EndInvoke($job.Handle));$code=Get-WsmOperationStatusCode $output;$job.Record.Status=if($code -eq 0){'Succeeded'}elseif($code -eq 3){'Cancelled'}elseif($code -eq 1){'Failed'}else{'ReviewRequired'}}catch{$job.Record.Status='Failed'}
                    $job.Record|Add-Member NoteProperty outputs @(Get-WsmHtmlResultProjection $output) -Force
                    $job.Record|Add-Member NoteProperty reportArtifacts @(Get-WsmHtmlReportArtifacts $job.Record.action $job.Record.outputs) -Force
                    $job.Record.canCancel=$false
                    $job.Record.CompletedUtc=Get-WsmUtc;$job.Handle=$null;$job.PowerShell.Dispose();$job.PowerShell=$null;Write-WsmJson $job.Path $job.Record
                }
            }
            if(-not $listener.Pending()){Start-Sleep -Milliseconds 50;continue}
            $client=$listener.AcceptTcpClient()
            try{
                $request=Read-WsmLocalHttpRequest $client;$status=200;$type='application/json; charset=utf-8';$response=$null;$bytes=$null
                if(-not $request.Headers.ContainsKey('host') -or $request.Headers.host -cne ('127.0.0.1:'+$actualPort)){throw 'RejectedHost'}
                if($request.Headers.ContainsKey('origin') -and $request.Headers.origin -cne $origin){throw 'RejectedOrigin'}
                if($request.Method -ceq 'POST' -and (-not $request.Headers.ContainsKey('origin') -or $request.Headers.origin -cne $origin)){throw 'RejectedOrigin'}
                $uri=New-Object Uri($origin+$request.Target);$route=$uri.AbsolutePath
                $query=@{};foreach($part in $uri.Query.TrimStart('?').Split('&')){if($part){$kv=$part.Split('=',2);if($query.ContainsKey($kv[0])){throw 'Duplicate query parameter.'};$query[$kv[0]]=[Uri]::UnescapeDataString($(if($kv.Count -gt 1){$kv[1]}else{''}))}}
                $static=@{'/'='index.html';'/index.html'='index.html';'/console.js'='console.js';'/console.css'='console.css';'/guide.html'='guide.html';'/ui/'='index.html';'/ui/console.js'='console.js';'/ui/console.css'='console.css';'/ui/guide.html'='guide.html';'/ui/index.html'='index.html'}
                $docRoot=Join-Path ([IO.Path]::GetDirectoryName($PSScriptRoot)) 'docs'
                $documents=@{'/operations-guide.html'=(Join-Path $docRoot 'ASSISTIVE-OPERATIONS.html');'/ASSISTIVE-OPERATIONS.css'=(Join-Path $docRoot 'ASSISTIVE-OPERATIONS.css');'/docs/ASSISTIVE-OPERATIONS.html'=(Join-Path $docRoot 'ASSISTIVE-OPERATIONS.html');'/docs/ASSISTIVE-OPERATIONS.css'=(Join-Path $docRoot 'ASSISTIVE-OPERATIONS.css')}
                $manualRoot=Join-Path $docRoot 'html'
                if([IO.Directory]::Exists($manualRoot)){foreach($document in @(Get-ChildItem -LiteralPath $manualRoot -File | Where-Object Extension -In @('.html','.css'))){$documents['/docs/html/'+$document.Name]=$document.FullName;$documents['/html/'+$document.Name]=$document.FullName}}
                if($documents.ContainsKey($route) -and $request.Method -ceq 'GET'){$file=$documents[$route];Assert-WsmNoReparse $file;$bytes=[IO.File]::ReadAllBytes($file);$type=if($file.EndsWith('.css')){'text/css; charset=utf-8'}else{'text/html; charset=utf-8'}}
                elseif($static.ContainsKey($route) -and $request.Method -ceq 'GET'){
                    $file=Join-Path (Join-Path $PSScriptRoot 'ui') $static[$route];Assert-WsmNoReparse $file;$bytes=[IO.File]::ReadAllBytes($file)
                    $type=if($file.EndsWith('.js')){'application/javascript; charset=utf-8'}elseif($file.EndsWith('.css')){'text/css; charset=utf-8'}else{'text/html; charset=utf-8'}
                }
                elseif($route -ceq '/api/session' -and $request.Method -ceq 'GET'){
                    $assetHashes=@{};foreach($asset in @('index.html','console.js','console.css','guide.html')){$file=Join-Path $uiRoot $asset;Assert-WsmNoReparse $file;$assetHashes['/ui/'+$asset]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()}
                    $response=@{token=$token;sessionId=$sessionId;contextId=$contextId;hostName=$env:COMPUTERNAME;role=$Role;workspace=$Workspace;pairId=$PairId;revision=(Get-WsmHtmlRevision $Workspace $PairId);principal=[Environment]::UserName;assetHashes=$assetHashes}
                }
                else{
                    if(-not $request.Headers.ContainsKey('x-wsm-token') -or $request.Headers['x-wsm-token'] -cne $token){throw 'RejectedToken'}
                    if($route -ceq '/api/context' -and $request.Method -ceq 'GET'){$response=Get-WsmHtmlContext $Workspace $PairId $Role $contextId}
                    elseif($route -ceq '/api/context' -and $request.Method -ceq 'POST'){
                        $change=ConvertFrom-WsmJson $request.Body;Assert-WsmFields $change @('pairId','role','expectedRevision','contextId') @('pairId','role','expectedRevision','contextId')
                        if($change.contextId -cne $contextId -or [int]$change.expectedRevision -ne (Get-WsmHtmlRevision $Workspace $PairId)){$status=409;$response=@{message='Context changed. Refresh before switching.'}}
                        elseif(@($jobs.Values|Where-Object {$_.Handle -and -not $_.Handle.IsCompleted}).Count){throw 'Wait for active jobs before switching context.'}
                        else{
                            if($change.role -cnotin @('Source','Target','Manager')){throw 'Invalid role.'}
                            if($change.pairId){Assert-WsmId $change.pairId;[void](Get-WsmCatalog $Workspace $change.pairId)}
                            $PairId=[string]$change.pairId;$Role=[string]$change.role;$contextId=[Guid]::NewGuid().ToString();$response=Get-WsmHtmlContext $Workspace $PairId $Role $contextId
                        }
                    }
                    elseif($route -ceq '/api/jobs' -and $request.Method -ceq 'GET'){$response=@{items=@($jobs.Values|ForEach-Object Record)}}
                    elseif($route -match '^/api/jobs/([a-fA-F0-9-]{36})/reports/([0-9]+)/open$' -and $request.Method -ceq 'POST'){
                        $id=$Matches[1];$index=[int]$Matches[2];if(-not $jobs.ContainsKey($id)){throw 'UnknownJob'}
                        $record=$jobs[$id].Record;if(-not $record.PSObject.Properties['reportArtifacts'] -or $index -ge @($record.reportArtifacts).Count){throw 'Unknown report artifact.'}
                        $open=ConvertFrom-WsmJson $request.Body;Assert-WsmFields $open @('SHA256') @('SHA256');$artifact=$record.reportArtifacts[$index]
                        if($open.SHA256 -ine $artifact.SHA256){throw 'Report hash changed.'};Assert-WsmNoReparse $artifact.Path;Assert-WsmTrustedFile $artifact.Path $artifact.SHA256
                        Start-Process -FilePath $artifact.Path | Out-Null;$response=@{status='Opened';SHA256=$artifact.SHA256}
                    }
                    elseif($route -match '^/api/jobs/([a-fA-F0-9-]{36})(/cancel)?$'){
                        $id=$Matches[1];$cancel=$Matches[2];if(-not $jobs.ContainsKey($id)){throw 'UnknownJob'};$job=$jobs[$id]
                        if($cancel -and $request.Method -ceq 'POST'){
                            if(-not $job.Handle -or $job.Handle.IsCompleted){throw 'Job has already stopped; inspect its authoritative journal before recovery.'}
                            if($job.CancellationToken){Request-WsmCancellation -Token $job.CancellationToken -Owner ([Environment]::UserName) -Evidence 'User requested cancellation from local HTML console' | Out-Null;$job.Record.Status='CancelRequested'}else{throw 'NoSafeCancellationBoundary'}
                        }
                        $response=$job.Record
                    }
                    elseif($route -ceq '/api/spec-review' -and $request.Method -ceq 'GET'){$response=Get-WsmAssistiveSpecReview -Workspace $Workspace -PairId $PairId -ItemId $query.itemId}
                    elseif($route -ceq '/api/view' -and $request.Method -ceq 'GET'){$response=Get-WsmHtmlView $Workspace $PairId $query.action $Role}
                    elseif($route -in @('/api/operations','/api/view') -and $request.Method -ceq 'POST'){
                        if(-not $request.Headers.ContainsKey('content-type') -or $request.Headers['content-type'] -notmatch '^application/json(?:;|$)'){throw 'JSON body required.'}
                        $body=ConvertFrom-WsmJson $request.Body
                        Assert-WsmFields $body @('action','args','operationId','idempotencyKey','expectedRevision','contextId') @('action','args','expectedRevision','contextId')
                        if($body.contextId -cne $contextId){$status=409;throw 'Review changed: context changed.'}
                        $map=Get-WsmHtmlActionMap;if(-not $map.Contains($body.action)){throw 'Unknown action.'}
                        $revision=Get-WsmHtmlRevision $Workspace $PairId
                        if([int]$body.expectedRevision -ne $revision){$status=409;$response=@{message='Review changed; refresh the current catalog.';currentRevision=$revision}}
                        else{
                            $command=Get-Command $map[$body.action] -CommandType Function
                            foreach($binding in @(@('Workspace',$Workspace),@('PairId',$PairId))){if($command.Parameters.ContainsKey($binding[0]) -and -not $body.args.PSObject.Properties[$binding[0]]){$body.args | Add-Member NoteProperty $binding[0] $binding[1]}}
                            if($command.Parameters.ContainsKey('ExpectedRevision') -and -not $body.args.PSObject.Properties['ExpectedRevision']){
                                if($command.Name -in @('Reserve-WsmAssistiveResource','Set-WsmAssistiveResourceEvidence','Release-WsmAssistiveResource','Set-WsmAssistiveMaterialClosed','Invoke-WsmAssistiveCleanup')){throw 'Resource registry revision from the reviewed preview is required.'}
                                $nativeRevision=$revision
                                if($PairId -and ($command.Name -notmatch 'Assistive|Set-WsmHtml' -or $command.Name -in @('Submit-WsmAssistiveWindowsSettingsReview','Submit-WsmAssistiveGeneralHostDispositions','Submit-WsmAssistiveGeneralHostRequirements','Submit-WsmAssistiveGeneralHostRequirementDecisions'))){$nativeRevision=(Get-WsmCatalog $Workspace $PairId).DecisionRevision}
                                $body.args | Add-Member NoteProperty ExpectedRevision $nativeRevision
                            }
                            $arguments=ConvertTo-WsmHtmlArguments $command $body.args
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
                                $hash=Get-WsmHtmlRequestHash $Workspace $PairId $Role $body.action $body.args ([int]$body.expectedRevision)
                                if($keys.ContainsKey($body.idempotencyKey)){
                                    $prior=$keys[$body.idempotencyKey];if($prior.Hash -cne $hash){throw 'Idempotency key was reused with different input.'};$response=$jobs[$prior.Id].Record
                                }
                                elseif($jobs.ContainsKey($body.operationId)){throw 'Operation ID already used.'} elseif(@($jobs.Values | Where-Object {$_.Record.status -in @('Running','CancelRequested')}).Count -ge 8){$status=409;$response=@{message='The local worker limit is reached; wait for an active job to finish before retrying.'}}
                                elseif($body.action -in @('SaveSelection','SetRestoreChoice','SetSoftwareVersion')){
                                    $record=[pscustomobject]@{jobId=$body.operationId;action=$body.action;idempotencyKey=[string]$body.idempotencyKey;RequestHash=$hash;status='Running';StartedUtc=(Get-WsmUtc);CompletedUtc=$null;canCancel=$false}
                                    $recordPath=Join-Path $consoleRoot ($body.operationId+'.json');Write-WsmJson $recordPath $record;$jobs[$body.operationId]=@{Record=$record;Path=$recordPath;Handle=$null;PowerShell=$null;CancellationToken=$null};$keys[$body.idempotencyKey]=@{Hash=$hash;Id=$body.operationId}
                                    try{$arguments.ExpectedRevision=$revision;$result=& $command @arguments;$record.status='Succeeded';$record.CompletedUtc=Get-WsmUtc;Write-WsmJson $recordPath $record;$response=@{revision=(Get-WsmHtmlRevision $Workspace $PairId);status='Saved'}}
                                    catch{$record.status='Failed';$record.CompletedUtc=Get-WsmUtc;Write-WsmJson $recordPath $record;throw}
                                }
                                else{
                                    $record=[pscustomobject]@{jobId=$body.operationId;action=$body.action;idempotencyKey=[string]$body.idempotencyKey;RequestHash=$hash;status='Running';StartedUtc=(Get-WsmUtc);CompletedUtc=$null;canCancel=$false}
                                    $recordPath=Join-Path $consoleRoot ($body.operationId+'.json')
                                    $cancellation=New-WsmHtmlCancellation $command $arguments $body.operationId
                                    if($command.Parameters.ContainsKey('CancellationToken') -and @($command.Parameters['CancellationToken'].Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -and -not $cancellation){throw 'This operation requires a hash-bound safe cancellation context before submission.'}
                                    if($cancellation){$arguments.CancellationToken=$cancellation}
                                    $worker=[Management.Automation.PowerShell]::Create()
                                    [void]$worker.AddScript('param($modulePath,$commandName,$arguments) Import-Module $modulePath -Force -DisableNameChecking; $ConfirmPreference="None"; $ErrorActionPreference="Stop"; $command=Get-Command $commandName -CommandType Function; if($command.Parameters.ContainsKey("Confirm")){$arguments.Confirm=$false}; & $command @arguments').AddArgument($modulePath).AddArgument($command.Name).AddArgument($arguments)
                                    $record.canCancel=($null -ne $cancellation);Write-WsmJson $recordPath $record
                                    $handle=$worker.BeginInvoke();$jobs[$body.operationId]=@{Record=$record;Path=$recordPath;PowerShell=$worker;Handle=$handle;CancellationToken=$cancellation};$keys[$body.idempotencyKey]=@{Hash=$hash;Id=$body.operationId};$status=202;$response=@{job=$record}
                                    $arguments=$null
                                }
                            }
                        }
                        $body=$null
                    }
                    else{$status=404;$response=@{message='Unknown route.'}}
                }
                if($null -eq $bytes){$bytes=[Text.Encoding]::UTF8.GetBytes(($response|ConvertTo-Json -Depth 30 -Compress))}
                Write-WsmLocalHttpResponse $client $status $type $bytes
            }catch{
                $status=400;if($_.Exception.Message -match '^Rejected'){$status=403}elseif($_.Exception.Message -match '^Review changed'){$status=409}
                $message=if($_.Exception.Message -match 'Review changed'){'Review changed; refresh and retry.'}else{'Request rejected. Inspect the approved local parameters and operation state.'}
                try{Write-WsmLocalHttpResponse $client $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((@{message=$message}|ConvertTo-Json -Compress)))}catch{}
            }finally{$client.Dispose()}
        }
    }finally{
        $listener.Stop()
        foreach($job in @($jobs.Values)){if($job.PowerShell){$job.PowerShell.Stop();$job.PowerShell.Dispose();$job.Record.Status='Interrupted';Write-WsmJson $job.Path $job.Record}}
        $token=$null;$keys.Clear()
    }
}
