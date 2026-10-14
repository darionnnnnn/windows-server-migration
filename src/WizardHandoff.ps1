function Get-WsmWizardHandoffHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-WsmWizardHandoffRoot([string]$Workspace) {
    Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard') 'handoff'
}

function Get-WsmWizardHandoffLocalTime([string]$Utc) {
    $instant=[DateTimeOffset]::Parse($Utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $local=$instant.ToLocalTime()
    [pscustomobject]@{Utc=$instant.ToUniversalTime().ToString('o');Local=$local.ToString('yyyy-MM-dd HH:mm:ss zzz');TimeZone=[TimeZoneInfo]::Local.Id}
}

function Get-WsmWizardHandoffSelectionHash($Catalog) {
    Get-WsmHashText ($Catalog.Assistive.Selections | ConvertTo-Json -Depth 100 -Compress)
}

function Get-WsmWizardHandoffTargetBinding($Catalog) {
    $target=$Catalog.Assistive.TargetCurrent
    [pscustomobject][ordered]@{
        SHA256=$(if($target){[string]$target.SHA256}else{''})
        HostId=$(if($target){[string]$target.HostId}else{''})
        Fingerprint=$(if($target){[string]$target.Fingerprint}else{''})
        DecisionRevision=[int]$Catalog.DecisionRevision
        AssistiveRevision=[int]$Catalog.Assistive.Revision
        HasApproval=[bool]($Catalog.Approval -and $Catalog.Approval.Kind -ceq 'MigrationPlan')
    }
}

function Get-WsmWizardHandoffReceiptPath([string]$Workspace,$Record) {
    $context=Get-WsmHashText (@([string]$Record.PairId,[string]$Record.ManifestHash,[string]$Record.SourceInventoryHash,[string]$Record.SourceSnapshotHash,[string]$Record.SelectionHash,[string]$Record.ToolFingerprint) -join '|')
    Join-Path (Join-Path (Get-WsmWizardHandoffRoot $Workspace) 'materials') ([string]$Record.PairId+'-'+$context+'.json')
}

function Export-WsmWizardTargetHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$InventoryPath,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $workspace=Initialize-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Target
    $profile=$workspace.Profile
    $identityPath=Join-Path (Join-Path (Join-Path $WorkRoot ('targets\'+$profile.HostId)) '') 'target-identity.json'
    Assert-WsmNoReparse $identityPath
    if(-not [IO.File]::Exists($identityPath)){throw 'The enrolled Target identity file is missing.'}
    $identityBytes=[IO.File]::ReadAllBytes($identityPath);$identityHash=Get-WsmWizardHandoffHash $identityPath
    $identity=ConvertFrom-WsmJson ([Text.Encoding]::UTF8.GetString($identityBytes))
    Assert-WsmEnvelope $identity 'TargetIdentity'
    if($identity.HostId -cne $profile.HostId -or $identity.Fingerprint -ine $profile.Fingerprint -or $workspace.TargetIdentity.HostId -cne $identity.HostId){throw 'Target identity bytes do not match the existing Target enrollment.'}
    $inventorySnapshot=Read-WsmFileSnapshot $InventoryPath ''
    $inventory=ConvertFrom-WsmJson $inventorySnapshot.Text
    Assert-WsmInventory $inventory
    if($inventory.Source.Fingerprint -ine $profile.Fingerprint -or $inventory.Source.Fingerprint -ieq $identity.Fingerprint -and $inventory.Source.HostId -ceq $identity.HostId -and $inventory.Source.Name -cne $identity.Name){throw 'Target inventory does not identify the enrolled Target host.'}
    $output=[IO.Path]::GetFullPath($OutputDirectory);Assert-WsmNoReparse $output
    if([IO.File]::Exists($output)){throw 'Target handoff output path is a file.'}
    if(-not [IO.Directory]::Exists($output)){[void][IO.Directory]::CreateDirectory($output);Protect-WsmDirectory $output}
    if(@(Get-ChildItem -LiteralPath $output -Force).Count){throw 'Target handoff output directory must be empty; preserve existing material and choose a new directory.'}
    $identityOut=Join-Path $output 'target-identity.json';$inventoryOut=Join-Path $output 'target-inventory.json';$manifestPath=Join-Path $output 'handoff.json'
    [IO.File]::WriteAllBytes($identityOut,$identityBytes)
    $inventoryBytes=[IO.File]::ReadAllBytes([IO.Path]::GetFullPath($InventoryPath));[IO.File]::WriteAllBytes($inventoryOut,$inventoryBytes)
    $manifest=[pscustomobject][ordered]@{
        SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WizardTargetHandoff';CreatedUtc=(Get-WsmUtc)
        Source=[pscustomobject]@{HostId='';Name='';Fingerprint=''}
        Target=[pscustomobject]@{HostId=[string]$identity.HostId;Name=[string]$identity.Name;Fingerprint=[string]$identity.Fingerprint;OS=[string]$identity.OS;Version=[string]$identity.Version}
        Inventory=[pscustomobject]@{File='target-inventory.json';SHA256=$inventorySnapshot.Hash.ToLowerInvariant();Revision=[int]$inventory.Revision;ObservedUtc=[string]$inventory.CreatedUtc}
        TargetIdentity=[pscustomobject]@{File='target-identity.json';SHA256=$identityHash}
        PortableFiles=@('handoff.json','target-identity.json','target-inventory.json')
        TrustNotice='Hashes in this handoff describe observed bytes. Manager must independently establish or explicitly confirm the handoff reference.'
    }
    Write-WsmJson $manifestPath $manifest
    $manifestHash=Get-WsmWizardHandoffHash $manifestPath
    $stamp=Get-WsmWizardHandoffLocalTime $manifest.CreatedUtc
    [pscustomobject][ordered]@{
        Kind='WizardTargetHandoffExport';Status='Exported';Directory=$output;ManifestPath=$manifestPath;ObservedManifestHash=$manifestHash
        Source=[pscustomobject]@{Name='Not applicable';HostId=''};Target=$manifest.Target;WorkRoot=$profile.WorkRoot
        InventoryRevision=[int]$inventory.Revision;InventoryHash=$inventorySnapshot.Hash.ToLowerInvariant();TargetIdentityHash=$identityHash
        ProducedUtc=$stamp.Utc;ProducedLocal=$stamp.Local;TimeZone=$stamp.TimeZone
        FieldMetadata=@([pscustomobject]@{Name='Target.HostId';Label='Target host identifier';Source='Registered Target profile';Editable=$false},[pscustomobject]@{Name='Target.Fingerprint';Label='Target host fingerprint';Source='Registered Target profile';Editable=$false},[pscustomobject]@{Name='Inventory.SHA256';Label='Target inventory SHA256';Source='Observed from copied file';Editable=$false})
        NextOperator='Target operator';NextMachine=[string]$identity.Name;NextAction='Move all three listed files to the Manager and provide the manifest SHA256 through an independent trusted channel.'
        ProductionVerified=$false
    }
}

function Get-WsmWizardTargetHandoffPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$HandoffDirectory,
        [Parameter(Mandatory)][int]$ExpectedAssistiveRevision,
        [Parameter(Mandatory)][string]$ExpectedManifestHash
    )
    Assert-WsmId $PairId
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Only an enrolled Manager workspace can preview a Target handoff.'}
    $directory=[IO.Path]::GetFullPath($HandoffDirectory);Assert-WsmNoReparse $directory
    if(-not [IO.Directory]::Exists($directory)){throw 'Target handoff directory is missing.'}
    $children=@(Get-ChildItem -LiteralPath $directory -Force)
    if($children.Count -ne 3 -or @($children|Where-Object {$_.PSIsContainer -or $_.Name -notin @('handoff.json','target-identity.json','target-inventory.json')}).Count){throw 'Target handoff must contain exactly the three declared regular files.'}
    $manifestPath=Join-Path $directory 'handoff.json';$identityPath=Join-Path $directory 'target-identity.json';$inventoryPath=Join-Path $directory 'target-inventory.json'
    foreach($path in @($manifestPath,$identityPath,$inventoryPath)){Assert-WsmNoReparse $path;if(-not [IO.File]::Exists($path)){throw ('Target handoff is missing required file: '+[IO.Path]::GetFileName($path))}}
    $manifestHash=Get-WsmWizardHandoffHash $manifestPath
    if($ExpectedManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or $manifestHash -ine $ExpectedManifestHash){throw 'Independent trusted handoff hash is missing or does not match the received manifest.'}
    $trustMethod='IndependentManifestHash'
    $manifest=Read-WsmTrustedJson $manifestPath $manifestHash;Assert-WsmEnvelope $manifest 'WizardTargetHandoff'
    Assert-WsmFields $manifest @('SchemaVersion','ToolVersion','Kind','CreatedUtc','Source','Target','Inventory','TargetIdentity','PortableFiles','TrustNotice') @('SchemaVersion','Kind','CreatedUtc','Source','Target','Inventory','TargetIdentity','PortableFiles')
    if($manifest.SchemaVersion -ne 1 -or @($manifest.PortableFiles).Count -ne 3 -or @($manifest.PortableFiles|Where-Object {$_ -notin @('handoff.json','target-identity.json','target-inventory.json')}).Count){throw 'Unsupported or incomplete Target handoff manifest.'}
    if($manifest.Inventory.File -cne 'target-inventory.json' -or $manifest.TargetIdentity.File -cne 'target-identity.json'){throw 'Target handoff contains an unexpected artifact path.'}
    $identityHash=Get-WsmWizardHandoffHash $identityPath;$inventoryHash=Get-WsmWizardHandoffHash $inventoryPath
    if($identityHash -ine [string]$manifest.TargetIdentity.SHA256 -or $inventoryHash -ine [string]$manifest.Inventory.SHA256){throw 'Target handoff artifact bytes differ from the manifest.'}
    $identity=Read-WsmTrustedJson $identityPath $identityHash;Assert-WsmEnvelope $identity 'TargetIdentity'
    $inventory=Read-WsmTrustedJson $inventoryPath $inventoryHash;Assert-WsmInventory $inventory
    Assert-WsmId ([string]$identity.HostId)
    if([string]$identity.Fingerprint -notmatch '^[a-fA-F0-9]{64}$'){throw 'Target identity fingerprint is malformed.'}
    if($identity.HostId -cne $manifest.Target.HostId -or $identity.Fingerprint -ine $manifest.Target.Fingerprint -or $inventory.Source.Fingerprint -ine $identity.Fingerprint -or [int]$inventory.Revision -ne [int]$manifest.Inventory.Revision){throw 'Target handoff identity and inventory bindings do not match.'}
    $catalog=Get-WsmCatalog $Workspace $PairId
    if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable Assistive mode before preparing a target inventory handoff.'}
    if([int]$catalog.Assistive.Revision -ne $ExpectedAssistiveRevision){throw 'Manager review changed; refresh before previewing Target material.'}
    if($identity.HostId -ceq $catalog.Source.HostId -or $identity.Fingerprint -ieq $catalog.Source.Fingerprint){throw 'The Source host cannot be registered as the Target.'}
    $root=Get-WsmWizardHandoffRoot $Workspace;$previewId=[Guid]::NewGuid().ToString('D');$previewRoot=Join-Path (Join-Path $root 'previews') $previewId
    foreach($dir in @($root,(Join-Path $root 'previews'),$previewRoot)){if(-not [IO.Directory]::Exists($dir)){[void][IO.Directory]::CreateDirectory($dir);Protect-WsmDirectory $dir};Assert-WsmNoReparse $dir}
    $pManifest=Join-Path $previewRoot 'handoff.json';$pIdentity=Join-Path $previewRoot 'target-identity.json';$pInventory=Join-Path $previewRoot 'target-inventory.json'
    [IO.File]::Copy($manifestPath,$pManifest,$false);[IO.File]::Copy($identityPath,$pIdentity,$false);[IO.File]::Copy($inventoryPath,$pInventory,$false)
    foreach($pair in @(@($pManifest,$manifestHash),@($pIdentity,$identityHash),@($pInventory,$inventoryHash))){if((Get-WsmWizardHandoffHash $pair[0]) -ine $pair[1]){throw 'Target handoff bytes changed while the preview snapshot was created.'}}
    $record=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardTargetHandoffPreview';PreviewId=$previewId;PairId=$PairId;Role='Manager';ManagerHostId=$profile.HostId;ManagerFingerprint=$profile.Fingerprint;ToolFingerprint=(Get-WsmToolFingerprint);SourceHostId=[string]$catalog.Source.HostId;SourceFingerprint=[string]$catalog.Source.Fingerprint;SourceInventoryHash=[string]$catalog.InventoryHash;SourceSnapshotHash=[string]$catalog.Assistive.SourceSnapshot.SHA256;SelectionRevision=[int]$catalog.Assistive.Selections.Revision;SelectionHash=(Get-WsmWizardHandoffSelectionHash $catalog);TargetHostId=[string]$identity.HostId;TargetFingerprint=[string]$identity.Fingerprint;ManifestHash=$manifestHash;ExpectedManifestHash=$ExpectedManifestHash.ToLowerInvariant();IdentityHash=$identityHash;InventoryHash=$inventoryHash;ManifestPath=$manifestPath;IdentityPath=$identityPath;InventoryPath=$inventoryPath;SnapshotRoot=$previewRoot;ExpectedAssistiveRevision=$ExpectedAssistiveRevision;ExpectedTargetBinding=(Get-WsmWizardHandoffTargetBinding $catalog);TrustMethod=$trustMethod;CreatedUtc=(Get-WsmUtc)}
    Write-WsmJson (Join-Path $previewRoot 'preview.json') $record
    $stamp=Get-WsmWizardHandoffLocalTime $manifest.CreatedUtc
    [pscustomobject][ordered]@{Kind='WizardTargetHandoffPreview';Status='ReadyForExplicitCommit';PreviewId=$previewId;PairId=$PairId;CurrentTarget=(Get-WsmWizardHandoffTargetBinding $catalog);ExpectedManifestHash=$ExpectedManifestHash.ToLowerInvariant();Source=[pscustomobject]@{HostId=[string]$catalog.Source.HostId;Name=[string]$catalog.Source.Name};Target=[pscustomobject]@{HostId=[string]$identity.HostId;Name=[string]$identity.Name;Fingerprint=[string]$identity.Fingerprint};InventoryRevision=[int]$inventory.Revision;InventoryHash=$inventoryHash;SourceInventoryHash=[string]$catalog.InventoryHash;SourceSelectionRevision=[int]$catalog.Assistive.Selections.Revision;ToolFingerprint=[string]$record.ToolFingerprint;ManifestHash=$manifestHash;TargetIdentityHash=$identityHash;TrustMethod=$trustMethod;ProducedUtc=$stamp.Utc;ProducedLocal=$stamp.Local;TimeZone=$stamp.TimeZone;FieldMetadata=@([pscustomobject]@{Name='Source.Name';Label='Source host';Source='Manager catalog';Editable=$false},[pscustomobject]@{Name='Target.Name';Label='Target host';Source='Registered Target identity';Editable=$false},[pscustomobject]@{Name='Target.Fingerprint';Label='Target host fingerprint';Source='Registered Target identity';Editable=$false},[pscustomobject]@{Name='Inventory.SHA256';Label='Target inventory SHA256';Source='Received bytes';Editable=$false},[pscustomobject]@{Name='TrustMethod';Label='Material trust method';Source='Independent trusted manifest hash';Editable=$false});NextOperator='Manager operator';NextMachine=[string]$profile.HostId;NextAction='Review the Source and Target identities, then explicitly commit this preview to update the Manager TargetSnapshot.';ProductionVerified=$false}
}

function Commit-WsmWizardTargetHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$PreviewId)
    Assert-WsmId $PairId
    $parsed=[Guid]::Empty;if(-not [Guid]::TryParseExact($PreviewId,'D',[ref]$parsed)){throw 'PreviewId must be a GUID.'}
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Only an enrolled Manager workspace can commit a Target handoff.'}
    $previewRoot=Join-Path (Join-Path (Join-Path (Get-WsmWizardHandoffRoot $Workspace) 'previews') $parsed.ToString('D')) ''
    $recordPath=Join-Path $previewRoot 'preview.json';Assert-WsmNoReparse $recordPath;if(-not [IO.File]::Exists($recordPath)){throw 'Target handoff preview has expired or is missing.'}
    $record=Read-WsmJson $recordPath
    if([string]$record.PairId -cne $PairId){throw 'Target handoff preview belongs to another active pair.'}
    if($record.Kind -cne 'WizardTargetHandoffPreview' -or $record.PreviewId -cne $parsed.ToString('D') -or $record.Role -cne 'Manager' -or $record.ManagerHostId -cne $profile.HostId -or $record.ManagerFingerprint -ine $profile.Fingerprint){throw 'Target handoff preview belongs to another Manager or was changed.'}
    if([string]$record.ToolFingerprint -ine (Get-WsmToolFingerprint)){throw 'Installed tool bytes changed after preview; create a new Target handoff preview.'}
    $catalog=Get-WsmCatalog $Workspace ([string]$record.PairId)
    if([int]$catalog.Assistive.Revision -notin @([int]$record.ExpectedAssistiveRevision,([int]$record.ExpectedAssistiveRevision+1)) -or $catalog.Source.HostId -cne $record.SourceHostId -or $catalog.Source.Fingerprint -ine $record.SourceFingerprint -or [string]$catalog.InventoryHash -ine [string]$record.SourceInventoryHash -or [string]$catalog.Assistive.SourceSnapshot.SHA256 -ine [string]$record.SourceSnapshotHash -or [int]$catalog.Assistive.Selections.Revision -ne [int]$record.SelectionRevision -or (Get-WsmWizardHandoffSelectionHash $catalog) -ine [string]$record.SelectionHash){throw 'Manager source inventory, selection, or review changed after preview; create a new Target handoff preview.'}
    foreach($entry in @(@($record.ManifestPath,$record.ManifestHash),@($record.IdentityPath,$record.IdentityHash),@($record.InventoryPath,$record.InventoryHash))){Assert-WsmNoReparse $entry[0];if(-not [IO.File]::Exists($entry[0]) -or (Get-WsmWizardHandoffHash $entry[0]) -ine $entry[1]){throw 'Target handoff bytes changed after preview; no Manager state was changed.'}}
    $pManifest=Join-Path $previewRoot 'handoff.json';$pIdentity=Join-Path $previewRoot 'target-identity.json';$pInventory=Join-Path $previewRoot 'target-inventory.json'
    foreach($entry in @(@($pManifest,$record.ManifestHash),@($pIdentity,$record.IdentityHash),@($pInventory,$record.InventoryHash))){Assert-WsmNoReparse $entry[0];if(-not [IO.File]::Exists($entry[0]) -or (Get-WsmWizardHandoffHash $entry[0]) -ine $entry[1]){throw 'Isolated preview snapshot changed; no Manager state was changed.'}}
    $verified=Read-WsmTrustedJson $pManifest ([string]$record.ManifestHash);Assert-WsmEnvelope $verified 'WizardTargetHandoff'
    $identity=Read-WsmTrustedJson $pIdentity ([string]$record.IdentityHash);Assert-WsmEnvelope $identity 'TargetIdentity'
    $inventory=Read-WsmTrustedJson $pInventory ([string]$record.InventoryHash);Assert-WsmInventory $inventory
    if($identity.HostId -cne $record.TargetHostId -or $identity.Fingerprint -ine $record.TargetFingerprint -or $identity.HostId -ceq $catalog.Source.HostId -or $identity.Fingerprint -ieq $catalog.Source.Fingerprint){throw 'Target identity does not match the preview or is the Source host.'}
    if($inventory.Source.HostId -cne $identity.HostId -or $inventory.Source.Fingerprint -ine $identity.Fingerprint -or [string]$record.TrustMethod -cne 'IndependentManifestHash' -or [string]$record.ExpectedManifestHash -ine [string]$record.ManifestHash){throw 'Target inventory or independent trust binding differs from the reviewed preview.'}
    $materialRoot=Join-Path (Get-WsmWizardHandoffRoot $Workspace) 'materials';if(-not [IO.Directory]::Exists($materialRoot)){[void][IO.Directory]::CreateDirectory($materialRoot);Protect-WsmDirectory $materialRoot};Assert-WsmNoReparse $materialRoot
    $identityMaterial=Join-Path $materialRoot ('target-'+$record.TargetHostId+'-'+$record.IdentityHash+'.json')
    if([IO.File]::Exists($identityMaterial)){if((Get-WsmWizardHandoffHash $identityMaterial) -ine $record.IdentityHash){throw 'Existing Target identity material was changed.'}}else{[IO.File]::Copy($pIdentity,$identityMaterial,$false);if((Get-WsmWizardHandoffHash $identityMaterial) -ine $record.IdentityHash){throw 'Target identity material changed during Manager registration.'}}
    $receiptPath=Get-WsmWizardHandoffReceiptPath $Workspace $record
    $intentDirectory=Join-Path (Get-WsmWizardHandoffRoot $Workspace) 'commits';if(-not [IO.Directory]::Exists($intentDirectory)){[void][IO.Directory]::CreateDirectory($intentDirectory);Protect-WsmDirectory $intentDirectory};Assert-WsmNoReparse $intentDirectory
    $intentPath=Join-Path $intentDirectory ($parsed.ToString('D')+'.json')
    $intent=$null;if([IO.File]::Exists($intentPath)){Assert-WsmNoReparse $intentPath;$intent=Read-WsmJson $intentPath}
    $sameBinding={param($candidate) $candidate.Kind -ceq 'WizardTargetHandoffCommitIntent' -and $candidate.PreviewId -ceq $record.PreviewId -and $candidate.PairId -ceq $record.PairId -and $candidate.ManagerHostId -ceq $record.ManagerHostId -and $candidate.ManagerFingerprint -ieq $record.ManagerFingerprint -and $candidate.ToolFingerprint -ieq $record.ToolFingerprint -and $candidate.SourceHostId -ceq $record.SourceHostId -and $candidate.SourceFingerprint -ieq $record.SourceFingerprint -and $candidate.SourceInventoryHash -ieq $record.SourceInventoryHash -and $candidate.SourceSnapshotHash -ieq $record.SourceSnapshotHash -and $candidate.SelectionRevision -eq $record.SelectionRevision -and $candidate.SelectionHash -ieq $record.SelectionHash -and $candidate.TargetHostId -ceq $record.TargetHostId -and $candidate.TargetFingerprint -ieq $record.TargetFingerprint -and $candidate.ManifestHash -ieq $record.ManifestHash -and $candidate.IdentityHash -ieq $record.IdentityHash -and $candidate.InventoryHash -ieq $record.InventoryHash -and $candidate.ExpectedAssistiveRevision -eq $record.ExpectedAssistiveRevision -and $candidate.ExpectedTargetBinding.SHA256 -ieq $record.ExpectedTargetBinding.SHA256 -and $candidate.ExpectedTargetBinding.HostId -ceq $record.ExpectedTargetBinding.HostId -and $candidate.ExpectedTargetBinding.Fingerprint -ieq $record.ExpectedTargetBinding.Fingerprint -and $candidate.ExpectedTargetBinding.DecisionRevision -eq $record.ExpectedTargetBinding.DecisionRevision -and $candidate.ExpectedTargetBinding.AssistiveRevision -eq $record.ExpectedTargetBinding.AssistiveRevision -and $candidate.ExpectedTargetBinding.HasApproval -eq $record.ExpectedTargetBinding.HasApproval }
    if($intent -and -not (& $sameBinding $intent)){throw 'A prior commit intent for this PreviewId has different material or Manager bindings.'}
    if([IO.File]::Exists($receiptPath)){
        $receipt=Read-WsmJson $receiptPath
        if($receipt.Kind -cne 'WizardTargetHandoffImport' -or $receipt.PairId -cne $record.PairId -or $receipt.ManifestHash -ine $record.ManifestHash -or $receipt.IdentityHash -ine $record.IdentityHash -or $receipt.InventoryHash -ine $record.InventoryHash -or $receipt.TargetSnapshotHash -ine $record.InventoryHash -or $receipt.TargetHostId -cne $record.TargetHostId -or $receipt.TargetFingerprint -ine $record.TargetFingerprint -or $receipt.TargetIdentityPath -ine [IO.Path]::GetFullPath($identityMaterial) -or $receipt.TrustMethod -cne $record.TrustMethod -or $receipt.ToolFingerprint -ine $record.ToolFingerprint -or $receipt.SourceInventoryHash -ine $record.SourceInventoryHash -or $receipt.SourceSnapshotHash -ine $record.SourceSnapshotHash -or $receipt.SourceSelectionRevision -ne $record.SelectionRevision -or $receipt.SourceSelectionHash -ine $record.SelectionHash -or -not $catalog.Assistive.TargetCurrent -or $catalog.Assistive.TargetCurrent.SHA256 -ine $record.InventoryHash -or $catalog.Assistive.TargetCurrent.HostId -cne $record.TargetHostId -or $catalog.Assistive.TargetCurrent.Fingerprint -ine $record.TargetFingerprint){throw 'Existing handoff receipt does not match the authoritative current Target snapshot.'}
        $snapshot=$catalog; $stamp=Get-WsmWizardHandoffLocalTime $receipt.ImportedUtc
        return [pscustomobject][ordered]@{Kind='WizardTargetHandoffImport';Status='ImportedVerified';PairId=$record.PairId;Source=[pscustomobject]@{HostId=[string]$catalog.Source.HostId;Name=[string]$catalog.Source.Name};Target=[pscustomobject]@{HostId=[string]$identity.HostId;Name=[string]$identity.Name;Fingerprint=[string]$identity.Fingerprint};TargetIdentityPath=[IO.Path]::GetFullPath($identityMaterial);TargetIdentityHash=[string]$record.IdentityHash;InventoryHash=[string]$record.InventoryHash;ManifestHash=[string]$record.ManifestHash;TargetSnapshotHash=[string]$catalog.Assistive.TargetCurrent.SHA256;ImportedUtc=$stamp.Utc;ImportedLocal=$stamp.Local;TimeZone=$stamp.TimeZone;NextOperator='Manager operator';NextMachine=[string]$record.SourceHostId;NextAction='Review and publish the Source/Target comparison, complete source selection and preparation, approve with this Target identity, then deliver the approved plan to the Source for Import-WsmWizardApprovedPlan.';ProductionVerified=$false;ReceiptPath=[IO.Path]::GetFullPath($receiptPath);Duplicate=$true}
    }
    if(-not $intent){
        $expected=$record.ExpectedTargetBinding;$actual=Get-WsmWizardHandoffTargetBinding $catalog
        if($actual.SHA256 -ine $expected.SHA256 -or $actual.HostId -cne $expected.HostId -or $actual.Fingerprint -ine $expected.Fingerprint -or $actual.DecisionRevision -ne $expected.DecisionRevision -or $actual.AssistiveRevision -ne $expected.AssistiveRevision -or $actual.HasApproval -ne $expected.HasApproval){throw 'Manager Target snapshot changed after preview; create a new Target handoff preview.'}
        $currentTarget=$catalog.Assistive.TargetCurrent
        $snapshotAlreadyCurrent=($currentTarget -and [string]$currentTarget.SHA256 -ieq [string]$record.InventoryHash -and [string]$currentTarget.HostId -ceq [string]$record.TargetHostId -and [string]$currentTarget.Fingerprint -ieq [string]$record.TargetFingerprint)
        $snapshotWriteRequired=(-not $snapshotAlreadyCurrent)
        $postDecision=[int]$expected.DecisionRevision+$(if($expected.HasApproval -or -not $snapshotWriteRequired){0}else{1})
        $postAssistive=[int]$record.ExpectedAssistiveRevision+$(if($snapshotWriteRequired){1}else{0})
        $intent=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardTargetHandoffCommitIntent';PreviewId=$record.PreviewId;PairId=$record.PairId;ManagerHostId=$record.ManagerHostId;ManagerFingerprint=$record.ManagerFingerprint;ToolFingerprint=$record.ToolFingerprint;SourceHostId=$record.SourceHostId;SourceFingerprint=$record.SourceFingerprint;SourceInventoryHash=$record.SourceInventoryHash;SourceSnapshotHash=$record.SourceSnapshotHash;SelectionRevision=$record.SelectionRevision;SelectionHash=$record.SelectionHash;TargetHostId=$record.TargetHostId;TargetFingerprint=$record.TargetFingerprint;ManifestHash=$record.ManifestHash;IdentityHash=$record.IdentityHash;InventoryHash=$record.InventoryHash;ExpectedAssistiveRevision=$record.ExpectedAssistiveRevision;ExpectedTargetBinding=$expected;SnapshotWriteRequired=[bool]$snapshotWriteRequired;ExpectedPostDecisionRevision=$postDecision;ExpectedPostAssistiveRevision=$postAssistive;ImportedUtc=(Get-WsmUtc)}
        Write-WsmJson $intentPath $intent
        if($snapshotWriteRequired){$snapshot=Update-WsmAssistiveTargetSnapshot -Workspace $Workspace -PairId $record.PairId -Path $pInventory -ExpectedHash $record.InventoryHash -ExpectedRevision ([int]$record.ExpectedAssistiveRevision)}else{$snapshot=$catalog}
    }else{
        $target=$catalog.Assistive.TargetCurrent
        $snapshotWriteRequired=$true;if($intent.PSObject.Properties['SnapshotWriteRequired']){if($intent.SnapshotWriteRequired -isnot [bool]){throw 'Prior commit intent snapshot-write flag is malformed.'};$snapshotWriteRequired=[bool]$intent.SnapshotWriteRequired}
        $expectedPostDecision=[int]$intent.ExpectedTargetBinding.DecisionRevision+$(if($intent.ExpectedTargetBinding.HasApproval -or -not $snapshotWriteRequired){0}else{1})
        $expectedPostAssistive=[int]$intent.ExpectedAssistiveRevision+$(if($snapshotWriteRequired){1}else{0})
        if([int]$intent.ExpectedPostDecisionRevision -ne $expectedPostDecision -or [int]$intent.ExpectedPostAssistiveRevision -ne $expectedPostAssistive -or -not $target -or [string]$target.SHA256 -ine [string]$intent.InventoryHash -or [string]$target.HostId -cne [string]$intent.TargetHostId -or [string]$target.Fingerprint -ine [string]$intent.TargetFingerprint -or [int]$catalog.DecisionRevision -ne [int]$intent.ExpectedPostDecisionRevision -or [int]$catalog.Assistive.Revision -ne [int]$intent.ExpectedPostAssistiveRevision){throw 'Prior commit intent does not match the authoritative Target snapshot transition; no receipt was regenerated.'}
        $snapshot=$catalog
    }
    $receipt=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardTargetHandoffImport';PreviewId=$record.PreviewId;PairId=$record.PairId;ManifestHash=$record.ManifestHash;IdentityHash=$record.IdentityHash;InventoryHash=$record.InventoryHash;TargetHostId=$record.TargetHostId;TargetFingerprint=$record.TargetFingerprint;TargetIdentityPath=[IO.Path]::GetFullPath($identityMaterial);TrustMethod=$record.TrustMethod;ToolFingerprint=$record.ToolFingerprint;SourceInventoryHash=$record.SourceInventoryHash;SourceSnapshotHash=$record.SourceSnapshotHash;SourceSelectionRevision=$record.SelectionRevision;SourceSelectionHash=$record.SelectionHash;ImportedUtc=[string]$intent.ImportedUtc;TargetSnapshotHash=[string]$snapshot.Assistive.TargetCurrent.SHA256}
    Write-WsmJson $receiptPath $receipt
    $stamp=Get-WsmWizardHandoffLocalTime $receipt.ImportedUtc
    [pscustomobject][ordered]@{Kind='WizardTargetHandoffImport';Status='ImportedVerified';PairId=$record.PairId;Source=[pscustomobject]@{HostId=[string]$catalog.Source.HostId;Name=[string]$catalog.Source.Name};Target=[pscustomobject]@{HostId=[string]$identity.HostId;Name=[string]$identity.Name;Fingerprint=[string]$identity.Fingerprint};TargetIdentityPath=[IO.Path]::GetFullPath($identityMaterial);TargetIdentityHash=[string]$record.IdentityHash;InventoryHash=[string]$record.InventoryHash;SourceInventoryHash=[string]$record.SourceInventoryHash;SourceSelectionRevision=[int]$record.SelectionRevision;ToolFingerprint=[string]$record.ToolFingerprint;ManifestHash=[string]$record.ManifestHash;TargetSnapshotHash=[string]$snapshot.Assistive.TargetCurrent.SHA256;ImportedUtc=$stamp.Utc;ImportedLocal=$stamp.Local;TimeZone=$stamp.TimeZone;NextOperator='Manager operator';NextMachine=[string]$record.SourceHostId;NextAction='Review and publish the Source/Target comparison, complete source selection and preparation, approve with this Target identity, then deliver the approved plan to the Source for Import-WsmWizardApprovedPlan.';ProductionVerified=$false;ReceiptPath=[IO.Path]::GetFullPath($receiptPath);Duplicate=$false}
}
