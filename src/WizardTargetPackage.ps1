function Get-WsmWizardTargetPackageContext {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId)
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Target'){throw 'Package import requires the enrolled Target workspace.'}
    $received=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile
    if(-not $received){throw 'Import the current target-bound approved plan before importing its package.'}
    [pscustomobject]@{Profile=$profile;Received=$received}
}

function Get-WsmWizardTargetSnapshotForRuntime([string]$Workspace,$Context,[object[]]$Jobs) {
    # A GET verifies the exact persisted Target inventory artifact and its
    # bounded timestamp, but never runs a native software rescan. Fresh current
    # software comparison belongs to the explicit preview and restore writers.
    # Prefer the inventory this Target explicitly bound in its wizard state, as every other caller does; several successful inventory jobs (a re-inventory after installing software) are normal and must not be ambiguous.
    $boundState=Get-WsmWizardState $Workspace '' Target;$inventory=Get-WsmWizardInventoryFromJobs $Workspace $Context.Profile $Jobs ([string]$boundState.SourceInventoryHash) ([string]$boundState.InventoryJobId)
    if(-not $inventory -or $inventory.Ambiguous){throw 'A unique successful current Target inventory job is required; refresh Target inventory before continuing.'}
    if($inventory.Inventory.Source.HostId -cne $Context.Profile.HostId -or $inventory.Inventory.Source.Fingerprint -ine $Context.Profile.Fingerprint){throw 'Current Target inventory does not match the enrolled local host identity.'}
    if(-not $inventory.Inventory.PSObject.Properties['SoftwareCatalog']){throw 'Target inventory has no native software catalog; do not infer software absence.'}
    Assert-WsmSoftwareCatalog $inventory.Inventory.SoftwareCatalog -SourceInventory $inventory.Inventory | Out-Null
    Assert-WsmAssistiveSnapshotFresh $inventory.Inventory | Out-Null
    [pscustomobject]@{Path=[string]$inventory.Path;SHA256=[string]$inventory.SHA256;Inventory=$inventory.Inventory;JobId=[string]$inventory.JobId;CurrentSoftwareRevalidated=$false}
}

function Assert-WsmWizardTargetPackageTransport {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,$Context,[Parameter(Mandatory)][string]$PairId)
    $transport=Read-WsmTrustedJson $Path $ExpectedHash
    Assert-WsmEnvelope $transport 'PackageTransport'
    if([string]$transport.PairId -cne $PairId -or [string]$transport.PlanHash -ine [string]$Context.Received.SHA256){throw 'ZIP transport does not match the currently received approved plan and target pair.'}
    if(-not $transport.PSObject.Properties['ManifestHash'] -or [string]$transport.ManifestHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'ZIP transport has no valid package manifest binding.'}
    $transport
}

function Assert-WsmWizardTargetDirectoryDelivery {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,$Context,[Parameter(Mandatory)][string]$PairId)
    $summary=Read-WsmTrustedJson $Path $ExpectedHash
    Assert-WsmEnvelope $summary 'DirectoryDelivery'
    if([string]$summary.PairId -cne $PairId -or [string]$summary.PlanHash -ine [string]$Context.Received.SHA256){throw 'Directory delivery does not match the currently received approved plan and target pair.'}
    if(-not $summary.PSObject.Properties['ManifestHash'] -or [string]$summary.ManifestHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Directory delivery has no valid package manifest binding.'}
    $summary
}

function New-WsmWizardTargetPackageCancellation {
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][ValidateSet('ImportPackageZip','DirectoryImport')][string]$Action,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$OperationId)
    $context=Get-WsmWizardTargetPackageContext $Workspace $PairId
    if($Action -ceq 'ImportPackageZip'){$binding=Assert-WsmWizardTargetPackageTransport $Path $ExpectedHash $context $PairId}else{$binding=Assert-WsmWizardTargetDirectoryDelivery $Path $ExpectedHash $context $PairId}
    $stateDirectory=$Workspace;if($Action -ceq 'ImportPackageZip'){$stateDirectory=Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-package-imports';[void](New-WsmOutputOwnedDirectory $stateDirectory)}
    New-WsmCancellationToken -StateDirectory $stateDirectory -PairId $PairId -PlanHash $context.Received.SHA256 -ManifestHash ([string]$binding.ManifestHash) -OperationId $OperationId
}

function Import-WsmWizardTargetZipPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$TransportPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$OperationId,$CancellationToken=$null)
    $context=Get-WsmWizardTargetPackageContext $Workspace $PairId
    $transport=Assert-WsmWizardTargetPackageTransport $TransportPath $ExpectedHash $context $PairId
    if(-not $CancellationToken){$outputRoot=Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-package-imports';[void](New-WsmOutputOwnedDirectory $outputRoot);$CancellationToken=New-WsmCancellationToken -StateDirectory $outputRoot -PairId $PairId -PlanHash $context.Received.SHA256 -ManifestHash ([string]$transport.ManifestHash) -OperationId $OperationId}
    [void](Assert-WsmCancellationTokenBinding $CancellationToken $PairId $context.Received.SHA256 ([string]$transport.ManifestHash) (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-package-imports'))
    $output=Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-package-imports'
    $import=Import-WsmPackageZip -TransportPath $TransportPath -ExpectedHash $ExpectedHash -OutputDirectory $output -CancellationToken $CancellationToken
    $package=Test-WsmMigrationPackage -ManifestPath $import.ManifestPath -ExpectedHash $import.SHA256 -CancellationToken $CancellationToken
    if([string]$package.Manifest.PairId -cne $PairId -or [string]$package.Manifest.PlanHash -ine [string]$context.Received.SHA256 -or [string]$package.Plan.Target.Fingerprint -cne [string]$context.Profile.Fingerprint){throw 'Imported ZIP package does not match the received plan, pair and enrolled target.'}
    $attemptWorkspace=Resolve-WsmOutputWorkspace -WorkRoot $Workspace -Role Target -PairId $PairId -PlanHash ([string]$context.Received.SHA256) -AttemptId $OperationId -AttemptMode Zip
    [pscustomobject][ordered]@{Kind='WizardTargetPackageImport';Status='Succeeded';PairId=$PairId;PlanHash=[string]$context.Received.SHA256;ManifestPath=[IO.Path]::GetFullPath([string]$import.ManifestPath);ManifestHash=[string]$import.SHA256;Directory=[IO.Path]::GetFullPath([string]$import.Directory);Generation=[int]$package.Manifest.Generation;Valid=$true;TransportHash=$ExpectedHash.ToLowerInvariant();AttemptId=[string]$attemptWorkspace.AttemptId;AttemptMode=[string]$attemptWorkspace.AttemptProfile.Mode;AttemptVolumeBytes=[long]$attemptWorkspace.AttemptProfile.VolumeBytes;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Import-WsmWizardTargetDirectoryPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SummaryPath,[Parameter(Mandatory)][string]$ExpectedSummaryHash,[Parameter(Mandatory)][string]$SourceDirectory,[Parameter(Mandatory)][string]$OperationId,$CancellationToken=$null)
    $context=Get-WsmWizardTargetPackageContext $Workspace $PairId
    $summary=Assert-WsmWizardTargetDirectoryDelivery $SummaryPath $ExpectedSummaryHash $context $PairId
    if(-not $CancellationToken){$CancellationToken=New-WsmCancellationToken -StateDirectory $Workspace -PairId $PairId -PlanHash $context.Received.SHA256 -ManifestHash ([string]$summary.ManifestHash) -OperationId $OperationId}
    $import=Import-WsmDirectoryDelivery -SummaryPath $SummaryPath -ExpectedSummaryHash $ExpectedSummaryHash -SourceDirectory $SourceDirectory -WorkRoot $Workspace -AttemptId $OperationId -AttemptMode Directory -AttemptVolumeBytes 0 -CancellationToken $CancellationToken
    if([string]$import.PairId -cne $PairId -or [string]$import.PlanHash -ine [string]$context.Received.SHA256 -or [string]$import.ManifestHash -ine [string]$summary.ManifestHash){throw 'Imported directory package does not match the received plan, pair and selected delivery summary.'}
    $package=Test-WsmMigrationPackage -ManifestPath ([string]$import.ManifestPath) -ExpectedHash ([string]$import.ManifestHash) -CancellationToken $CancellationToken
    if([string]$package.Manifest.PairId -cne $PairId -or [string]$package.Manifest.PlanHash -ine [string]$context.Received.SHA256 -or [string]$package.Plan.Target.Fingerprint -cne [string]$context.Profile.Fingerprint -or [string]$package.SHA256 -ine [string]$summary.ManifestHash){throw 'Imported directory package failed independent core verification against the received target-bound plan.'}
    $import | Add-Member NoteProperty Kind 'WizardTargetPackageImport' -Force
    $import | Add-Member NoteProperty Status 'Succeeded' -Force
    $import | Add-Member NoteProperty Generation ([int]$package.Manifest.Generation) -Force
    $import | Add-Member NoteProperty AttemptMode 'Directory' -Force
    $import | Add-Member NoteProperty AttemptVolumeBytes 0 -Force
    $import | Add-Member NoteProperty Valid $true -Force
    $import | Add-Member NoteProperty AuthoritativeApproval $false -Force
    $import | Add-Member NoteProperty ProductionVerified $false -Force
    $import
}
