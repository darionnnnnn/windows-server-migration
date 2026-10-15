# Frozen projection boundary checks for the loaded module and installed action map.
# Synthetic payloads intentionally include hostile fields; they are not runtime data.
#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-html-projection-'+[Guid]::NewGuid().ToString('N').Substring(0,10))
[void][IO.Directory]::CreateDirectory($root)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Has($Object,[string]$Name){return [bool]($Object -and $Object.PSObject.Properties[$Name])}
function CheckNoProperty($Object,[string[]]$Names,[string]$Where){foreach($name in $Names){Check (-not (Has $Object $name)) ($Where+' leaked forbidden field '+$name+'.')}}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()){& $script:module $Block @Arguments}
function Get-Projection($Value){@(& $script:module {param($v)ConvertTo-WsmWizardHtmlValue $v} @($Value))[0]}
function Get-ResultProjection($Value){& $script:module {param($v)Get-WsmHtmlResultProjection $v} @($Value)}
function Get-ActionInfo([string]$Workspace,[string]$PairId,[string]$Role,[string]$Action){
    CallModule {
        param($workspace,$pairId,$role,$action)
        $map=Get-WsmOperationActions
        if(-not $map.Contains($action)){throw ('Action missing from installed map: '+$action)}
        $command=Get-Command $map[$action] -CommandType Function
        $allMandatory=@($command.Parameters.Values|Where-Object {@($_.Attributes|Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -gt 0}|ForEach-Object Name)
        $external=@($allMandatory|Where-Object {$_ -notin @('Workspace','PairId','Jobs','OperationId','CancellationToken')}|Sort-Object -Unique)
        $defaults=Get-WsmWizardActionDefaults -Workspace $workspace -PairId $pairId -Role $role -Action $action
        [pscustomobject]@{Action=$action;Command=$map[$action];AllMandatory=$allMandatory;Required=$external;Defaults=$defaults}
    } @($Workspace,$PairId,$Role,$Action)
}
try {
    # Exercise the actual module converter against the real public consumer shape.
    $backup=[pscustomobject][ordered]@{
        Kind='WizardBackupResult';Status='Exported';Path='C:\safe\backup.json';SHA256=('a'*64);ManifestPath='C:\safe\manifest.json';ManifestHash=('b'*64)
        NextOperator='Target operator';NextAction='<img src=x onerror=alert(1)> & password=not-for-ui';AuthoritativeApproval=$false;ProductionVerified=$false
        RawSettings=@{password='do-not-show'};ACL=[pscustomobject]@{Owner='S-1-5-18';Sddl='O:SY'}
        Diagnostics=[pscustomobject]@{Exception='password=DoNotLeak';NativeMessage='forbidden'};UnknownHostSecret='api_key=abc123'
    }
    $safeBackup=Get-Projection $backup
    foreach($field in @('Kind','Status','Path','SHA256','ManifestPath','ManifestHash','NextOperator','NextAction')){Check (Has $safeBackup $field) ('Backup consumer field was lost: '+$field)}
    Check ($safeBackup.NextAction -ceq '<img src=x onerror=alert(1)> & password=[redacted]') 'Hostile display text was not retained as plain text with secret assignment redacted.'
    CheckNoProperty $safeBackup @('RawSettings','ACL','Diagnostics','UnknownHostSecret') 'BackupResult projection'

    $proof=[pscustomobject][ordered]@{
        Kind='WizardNonCProofHandoffPreview';Status='Ready';PreviewId='preview-id';PreviewHash=('c'*64);PairId='pair-id';Role='Target'
        ManifestHash=('d'*64);ObservedManifestHash=('d'*64);PlanHash=('e'*64);SourceHost='source-01';SourceHostId='source-id';TargetHost='target-01';TargetHostId='target-id'
        SourceInventoryHash=('f'*64);TargetInventoryHash=('1'*64);SelectionRevision=4;AssistiveRevision=8;RegistryRevision=3
        Materials=@([pscustomobject]@{Kind='TargetPhysicalProof';SHA256=('2'*64);Role='Target';HostName='target-01';HostId='target-id';RootCount=2;RawProof='no'})
        ReviewedTargetRoots=@('\\target-01\data','\\target-01\state');TargetStateDirectory='\\target-01\state'
        NextOperator='Manager';NextAction='Review and import';CanImport=$true;AuthoritativeApproval=$false;ProductionVerified=$false
        RawProof=[pscustomobject]@{PhysicalIdentities=@('secret');ACL='raw';Password='dont-render'};NativeDiagnostics='password=hidden'
    }
    $safeProof=Get-Projection $proof
    $multiProof=Get-Projection ([pscustomobject]@{Shares=@([pscustomobject]@{Name='data';LocalPath='D:\data';Password='hidden'},[pscustomobject]@{Name='state';LocalPath='C:\work'});ReviewedTargetRootMappings=@([pscustomobject]@{LocalPath='D:\data';ShareName='data';UNCPath='\\target\data';RawProof='hidden'});TargetStateShareName='state';CreatedLocal='2026-10-15T12:00:00+08:00';TimeZoneId='Taipei Standard Time'})
    Check (@($multiProof.Shares).Count -eq 2 -and $multiProof.Shares[1].Name -ceq 'state' -and $multiProof.TargetStateShareName -ceq 'state') 'Reviewed data/state shares were lost at the formal projection boundary.'
    Check ($multiProof.ReviewedTargetRootMappings[0].UNCPath -ceq '\\target\data' -and $multiProof.CreatedLocal -match '\+08:00$' -and $multiProof.TimeZoneId -ceq 'Taipei Standard Time') 'Share mapping or local-time handoff provenance was lost.'
    CheckNoProperty $multiProof.Shares[0] @('Password') 'Share projection'
    CheckNoProperty $multiProof.ReviewedTargetRootMappings[0] @('RawProof') 'Share mapping projection'
    foreach($field in @('PreviewId','ManifestHash','ObservedManifestHash','PlanHash','SourceHost','TargetHost','ReviewedTargetRoots','TargetStateDirectory','NextOperator','NextAction','Materials','CanImport')){Check (Has $safeProof $field) ('Proof preview consumer field was lost: '+$field)}
    Check ((@($safeProof.Materials).Count -eq 1) -and $safeProof.Materials[0].SHA256 -ceq ('2'*64)) 'Proof material reference was not retained.'
    CheckNoProperty $safeProof @('RawProof','NativeDiagnostics') 'Proof preview projection'
    CheckNoProperty $safeProof.Materials[0] @('RawProof') 'Proof material projection'

    $principal=[pscustomobject][ordered]@{SourceSid='S-1-5-18';SourceName='SYSTEM';OwnerObserved=$true;RuleCount=2;Acl='raw descriptor';RawSettings=@{pwd='secret'};Diagnostics='password=never'}
    $observation=[pscustomobject][ordered]@{
        Kind='WizardNonCAccountObservationResult';Status='Succeeded';PairId='pair-id';PlanHash=('3'*64);ManifestHash=('4'*64);Generation=2;InventoryHash=('5'*64)
        SelectionRevision=4;TargetSnapshotHash=('6'*64);SourcePeerProofHash=('7'*64);Path='C:\safe\observation.json';SHA256=('8'*64);CreatedUtc='2026-10-14T00:00:00Z'
        CoverageComplete=$true;VisitedCount=10;MaximumEntries=100;ElapsedMilliseconds=12;TimeoutSeconds=45;TimedOut=$false;Cancelled=$false;ContentRead=$false;UnresolvedCount=0;AclReadFailureCount=0
        hasDurableRecord=$true;current=$true;SourceIdentities=@([pscustomobject]@{identityId='S-1-5-18';name='SYSTEM';kind='StableWindowsWellKnownSID';sid='S-1-5-18';stableBuiltin=$true;source='fixture';Raw='x'})
        TargetIdentities=@([pscustomobject]@{identityId='S-1-5-19';name='LOCAL SERVICE';kind='StableWindowsWellKnownSID';sid='S-1-5-19';stableBuiltin=$true;source='fixture';Credentials='hidden'})
        Entries=@([pscustomobject]@{ItemId='item-1';Name='Share';Status='Observed';Principals=@($principal);RawAcl='secret'})
        AuthoritativeApproval=$false;ProductionVerified=$false;RawACL='private';Diagnostics='password=never'
    }
    $safeObservation=Get-Projection $observation
    $pluralProofs=Get-Projection ([pscustomobject]@{SourcePeerProofHashes=@(('a'*64),('b'*64));SourcePeerProofs=@([pscustomobject]@{SHA256=('a'*64);ContentHash=('c'*64);Credentials='hidden'});Entries=@([pscustomobject]@{ItemId='item-1';SourcePeerProofHash=('a'*64);SourcePeerProofContentHash=('c'*64)})})
    Check (@($pluralProofs.SourcePeerProofHashes).Count -eq 2 -and $pluralProofs.SourcePeerProofs[0].ContentHash -ceq ('c'*64) -and $pluralProofs.Entries[0].SourcePeerProofContentHash -ceq ('c'*64)) 'Multi-share observation bindings did not survive the formal projection boundary.'
    CheckNoProperty $pluralProofs.SourcePeerProofs[0] @('Credentials') 'Source proof projection'
    $nonCPreview=Get-Projection ([pscustomobject]@{NonCTransferPlanHash=('a'*64);NonCResultHash=('b'*64);RawProof='hidden'})
    Check ($nonCPreview.NonCTransferPlanHash -ceq ('a'*64) -and $nonCPreview.NonCResultHash -ceq ('b'*64)) 'NonC preview material bindings were lost in durable HTML job output.'
    CheckNoProperty $nonCPreview @('RawProof') 'NonC preview projection'
    $reviewRow=Get-Projection ([pscustomobject]@{Action='Restore';Rollback='Per-item journal';RebootPossible=$false;RequirementId='requirement-1';ConsumerItemId='item-1';Gate='CutoverReady';Issue='Explicit dependency evidence required';ACL='hidden'})
    foreach($name in @('Action','Rollback','RebootPossible','RequirementId','ConsumerItemId','Gate','Issue')){Check (Has $reviewRow $name) ('Typed review field lost at the durable boundary: '+$name)}
    CheckNoProperty $reviewRow @('ACL') 'Typed review row projection'
    foreach($field in @('CoverageComplete','SourceIdentities','TargetIdentities','Entries','SHA256','PlanHash','TargetSnapshotHash','SourcePeerProofHash')){Check (Has $safeObservation $field) ('Account observation consumer field was lost: '+$field)}
    Check ((@($safeObservation.TargetIdentities).Count -eq 1) -and $safeObservation.TargetIdentities[0].sid -ceq 'S-1-5-19') 'UI target identity choice fields were lost.'
    Check ((@($safeObservation.Entries[0].Principals).Count -eq 1) -and $safeObservation.Entries[0].Principals[0].SourceSid -ceq 'S-1-5-18' -and $safeObservation.Entries[0].Principals[0].OwnerObserved -eq $true -and $safeObservation.Entries[0].Principals[0].RuleCount -eq 2) 'UI source principal identity fields were lost.'
    CheckNoProperty $safeObservation @('RawACL','Diagnostics') 'Account observation projection'
    CheckNoProperty $safeObservation.TargetIdentities[0] @('Credentials','Raw') 'Target identity projection'
    CheckNoProperty $safeObservation.Entries[0] @('RawAcl') 'Account observation entry projection'
    CheckNoProperty $safeObservation.Entries[0].Principals[0] @('Acl','RawSettings','Diagnostics') 'Account principal projection'

    $restore=[pscustomobject][ordered]@{
        Kind='WizardTargetRestoreResult';Status='ReviewRequired';PairId='pair-id';ItemResultsHash=('9'*64);ItemResults=@([pscustomobject]@{ItemId='item-1';Status='Restored';Reason='Observed';RawSettings=@{password='secret'};ACL='raw';Diagnostics='password=never'})
        RawItemResults=@('secret');Diagnostics='password=hidden';AuthoritativeApproval=$false;ProductionVerified=$false
    }
    $safeRestore=@(Get-ResultProjection $restore)[0]
    foreach($field in @('Kind','Status','PairId','ItemResultsHash','SafeProjectedItemResults')){Check (Has $safeRestore $field) ('Target restore result field was lost: '+$field)}
    Check ($safeRestore.SafeProjectedItemResults -eq $true) 'Target restore projection did not mark item results as safely projected.'
    Check ((@($safeRestore.ItemResults).Count -eq 1) -and $safeRestore.ItemResults[0].ItemId -ceq 'item-1' -and $safeRestore.ItemResults[0].Status -ceq 'Restored') 'Safe restore item result fields were lost.'
    CheckNoProperty $safeRestore @('RawItemResults','Diagnostics','RawSettings','ACL') 'Target restore result projection'
    CheckNoProperty $safeRestore.ItemResults[0] @('RawSettings','ACL','Diagnostics') 'Target restore item projection'

    # Unsafe display markup remains an inert string. Verify the actual widget uses textContent.
    $uiPath=Join-Path $PSScriptRoot '..\src\ui\nonc.js';$ui=[IO.File]::ReadAllText([IO.Path]::GetFullPath($uiPath))
    Check ($ui.Contains('node.textContent = text(label);') -and -not $ui.Contains('.innerHTML')) 'NonC widget is not using textContent-only rendering.'
    Check ($safeBackup.NextAction -like '<img*onerror*') 'Hostile display sample was unexpectedly transformed into HTML markup.'

    # Confirm the installed operation map, target function exports and role/default contract.
    $sourceWorkspace=Join-Path $root 'source';$managerWorkspace=Join-Path $root 'manager';$targetWorkspace=Join-Path $root 'target'
    foreach($entry in @([pscustomobject]@{Path=$sourceWorkspace;Role='Source'},[pscustomobject]@{Path=$managerWorkspace;Role='Manager'},[pscustomobject]@{Path=$targetWorkspace;Role='Target'})){
        CallModule {param($path,$role)Initialize-WsmOutputWorkspace -WorkRoot $path -Role $role|Out-Null;if($role -ceq 'Manager'){Initialize-WsmWorkspace $path|Out-Null;Initialize-WsmWizardWorkspace $path Manager|Out-Null}} @($entry.Path,$entry.Role)
    }
    # Produce a genuine, not-yet-approved NonC projection through the loaded
    # workspace/catalog/preparation consumers. Its empty choices remain typed
    # MaterialChoices; it must not claim readiness or invent approval.
    $inventoryPath=Join-Path $root 'inventory.json';$specPath=Join-Path $root 'migration-spec.json'
    $inventory=CallModule {
        param($itemPath)
        $host=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='projection-source';OS='Windows Server 2025'}
        $item=New-WsmItem $host.HostId Storage PathCandidate 'Projection business data' $itemPath ([pscustomobject]@{OriginalPath=$itemPath;ResolvedCandidate=$itemPath}) @() Success Manual
        $value=New-WsmInventory $host 1 @($item)
        $coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc='2026-10-14T00:00:00Z'})
        $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$value.Source.HostId;Fingerprint=$value.Source.Fingerprint;Name=$value.Source.Name;InventoryRevision=[int]$value.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $value)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=('0'*64)}
        $software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software;Assert-WsmSoftwareCatalog $software -SourceInventory $value|Out-Null;$value|Add-Member NoteProperty SoftwareCatalog $software;$value
    } @((Join-Path $root 'source-root'))
    CallModule {param($data,$path)Write-WsmJson $path $data|Out-Null} @($inventory,$inventoryPath)
    $catalog=CallModule {param($workspace,$path)$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();Import-WsmInventory -Workspace $workspace -Path $path -ExpectedHash $hash -TargetName 'projection-target'} @($managerWorkspace,$inventoryPath)
    $spec=[pscustomobject]@{Adapter='FileScope';SourcePath='C:\projection-source';TargetPath='D:\projection-target';TransferChannel='NonC';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';Owner='Projection reviewer';Evidence='Projection fixture';BusinessChecks=@('Check staged bytes')}
    CallModule {param($data,$path)Write-WsmJson $path $data|Out-Null} @($spec,$specPath)
    $catalog=CallModule {param($workspace,$pairId,$itemId,$path,$revision)$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();Set-WsmDecision -Workspace $workspace -PairId $pairId -ItemId @($itemId) -Decision Include -ExpectedRevision $revision|Out-Null;$current=Get-WsmCatalog $workspace $pairId;Set-WsmMigrationSpec $workspace $pairId $itemId $path $hash $current.DecisionRevision|Out-Null;Get-WsmCatalog $workspace $pairId} @($managerWorkspace,$catalog.PairId,$catalog.Items[0].ItemId,$specPath,$catalog.DecisionRevision)
    $actualNonC=@(CallModule {param($workspace,$pairId)Get-WsmHtmlWizardNonC $workspace $pairId Manager @{} 'projection-context'} @($managerWorkspace,$catalog.PairId))[0]
    Check ($actualNonC.Kind -ceq 'WizardNonCProjection' -and $actualNonC.HasNonC -eq $true -and $actualNonC.CurrentPlan -eq $null -and $actualNonC.ProofAllowed -eq $false) 'Genuine unapproved NonC projection fabricated approval or lost its selected scope.'
    Check ($actualNonC.Preparation.Status -ceq 'NeedsApproval' -and (Has $actualNonC.Preparation 'MaterialChoices') -and @($actualNonC.Preparation.MaterialChoices).Count -eq 0) 'Genuine preparation projection lost its MaterialChoices field or represented approval as ready.'
    $contracts=@(
        [pscustomobject]@{Action='NonCSourceProofExport';Role='Source';Workspace=$sourceWorkspace;Required=@('ShareName','LocalPath','Destination','NextOperator')},
        [pscustomobject]@{Action='NonCTargetProofExport';Role='Target';Workspace=$targetWorkspace;Required=@('ShareName','LocalPath','LocalRoots','StateDirectory','Destination','NextOperator')},
        [pscustomobject]@{Action='NonCProofPreview';Role='Manager';Workspace=$managerWorkspace;Required=@('Directory','ExpectedManifestHash')},
        [pscustomobject]@{Action='NonCProofImport';Role='Manager';Workspace=$managerWorkspace;Required=@('Directory','ExpectedManifestHash','PreviewId')},
        [pscustomobject]@{Action='NonCAccountObservation';Role='Manager';Workspace=$managerWorkspace;Required=@('ManifestSelection','SourcePeerProofHash')},
        [pscustomobject]@{Action='CreateNonCTransferPlan';Role='Manager';Workspace=$managerWorkspace;Required=@('ManifestSelection','SourcePeerProofHash','TargetPhysicalProofHash','ItemScopes','TargetStateDirectory','AccountObservationHash','Owner','Evidence')},
        [pscustomobject]@{Action='ImportNonCResult';Role='Manager';Workspace=$managerWorkspace;Required=@('TransferPlanHash','ResultPath','ExpectedResultHash')},
        [pscustomobject]@{Action='ImportNonCTransferPlan';Role='Source';Workspace=$sourceWorkspace;Required=@('Path','ExpectedHash','FreezeEvidencePath','FreezeEvidenceHash')},
        [pscustomobject]@{Action='StartNonCTransfer';Role='Source';Workspace=$sourceWorkspace;Required=@()}
    )
    foreach($contract in $contracts){
        $info=Get-ActionInfo $contract.Workspace 'pair-fixture' $contract.Role $contract.Action
        Check (-not [string]::IsNullOrWhiteSpace([string]$info.Command)) ('Installed operation map has no command for '+$contract.Action+'.')
        Check ($info.Defaults.requiredRole -ceq $contract.Role) ('Action has the wrong required role: '+$contract.Action+'.')
        Check ($info.Defaults.blocked -eq ($contract.Required.Count -gt 0)) ('Action defaults blocked state disagrees with mandatory explicit inputs: '+$contract.Action+'.')
        $actual=@($info.Required|Sort-Object -Unique);$wanted=@($contract.Required|Sort-Object -Unique)
        Check (($actual -join '|') -ceq ($wanted -join '|')) ('Mandatory consumer parameters changed for '+$contract.Action+': expected '+($wanted -join ',')+' got '+($actual -join ',')+'.')
        $reported=@($info.Defaults.missingFields|ForEach-Object {[string]$_.name}|Sort-Object -Unique)
        $explicitWanted=@($wanted|Where-Object {-not ($contract.Action -ceq 'NonCTargetProofExport' -and $_ -ceq 'StateDirectory')})
        Check (($reported -join '|') -ceq ($explicitWanted -join '|')) ('Runtime defaults do not expose the required explicit fields for '+$contract.Action+'.')
        if($contract.Action -ceq 'NonCTargetProofExport'){Check ($info.Defaults.args.StateDirectory -ieq (Join-Path $targetWorkspace 'pairs')) 'Target proof default did not bind the enrolled fixed WorkRoot pairs directory.'}
    }
    $scopeMetadata=& $module {Get-WsmHtmlActionMetadata Manager|Where-Object action -CEQ CreateNonCTransferPlan}
    $scopeParameter=@($scopeMetadata.parameters|Where-Object name -CEQ ItemScopes)[0]
    Check ($scopeParameter.schema.properties.ContainsKey('ItemId') -and $scopeParameter.schema.properties.AccountMappings.schema.properties.ContainsKey('TargetSid')) 'NonC text metadata replaced typed roots/principal mappings with an opaque JSON artifact.'
    $backupMetadata=& $module {Get-WsmHtmlActionMetadata Source|Where-Object action -CEQ StartBackup}
    Check (@($backupMetadata.parameters|Where-Object name -CEQ VolumeBytes)[0].type -ceq 'integer') 'Backup volume size must be a numeric field rather than an opaque JSON artifact.'
    $observationMetadata=& $module {Get-WsmHtmlActionMetadata Manager|Where-Object action -CEQ NonCAccountObservation}
    Check (-not $observationMetadata.readOnly) 'Account observation persists a receipt and must not execute as a read-only preview before explicit APPLY.'
    $wrongRole=Get-ActionInfo $targetWorkspace 'pair-fixture' 'Target' 'NonCSourceProofExport'
    Check ($wrongRole.Defaults.roleAvailable -eq $false) 'Source proof export was available from an enrolled Target workspace.'

    # All public projection properties consumed by the widget must survive the real whitelist.
    $widgetNeeds=@('Kind','Role','PairId','ContextId','DataVersion','HasNonC','CurrentPlan','Preparation','AccountObservation','ResultSummary','SourceChoices','ProofAllowed','actions','Current','Entries','MaterialChoices','ProofOptions','TransferChoices','MissingFields','Gates','CanCreateTransferPlan','CanImportResult','NonCItemIds','CoverageComplete','TargetIdentities','SourceIdentities','Principals','SourceSid','SourceName','OwnerObserved','RuleCount','value','label','generation','path','sha256','ChoiceId','Label','PreviewId','ReviewedTargetRoots','TargetStateDirectory')
    $consumerShape=[ordered]@{};foreach($field in $widgetNeeds){$consumerShape[$field]='retained consumer field'}
    $consumerProjection=Get-Projection ([pscustomobject]$consumerShape)
    foreach($field in $widgetNeeds){Check (Has $consumerProjection $field) ('Actual projection omitted widget consumer field '+$field+'.')}
    $merged=Get-Projection ([pscustomobject]@{CStatus='VerifiedPackageAvailable';CCompleted=$true;NonCStatus='Succeeded';NonCCompleted=$true;NonCAppliedCount=2;NonCBlockedCount=0;NonCDeferredCount=0;NonCResults=@([pscustomobject]@{TransferId='t';AppliedCount=2})})
    Check ($merged.CCompleted -and $merged.NonCCompleted -and $merged.NonCAppliedCount -eq 2 -and $merged.NonCResults[0].AppliedCount -eq 2) 'Verified merged C/NonC counts disappeared at the actual projection boundary.'
    $prepFixture=[pscustomobject]@{MaterialChoices=@([pscustomobject]@{value=('a'*64);label='final package';generation=3;path='C:\safe\manifest.json'})}
    $safePrep=Get-Projection $prepFixture
    Check ((Has $safePrep 'MaterialChoices') -and $safePrep.MaterialChoices[0].value -ceq ('a'*64)) 'Actual preparation field MaterialChoices was not retained by the whitelist.'
    Check ($ui.Contains('prep.materialChoices || prep.MaterialChoices || prep.choices || prep.Choices')) 'Manager UI does not consume the actual MaterialChoices projection field.'
    Write-Output ('PASS Test-WizardHtmlRuntimeProjection checks='+$checks+'; genuine unapproved projection and synthetic adversarial result examples; no runtime success or production qualification asserted.')
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    $absolute=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notlike 'wsm-html-projection-*'){throw 'Unsafe projection test cleanup path.'}
    if([IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
