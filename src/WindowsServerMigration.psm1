Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolVersion = '0.3.0'
$script:Categories = @('System','Web','Tasks','Services','Runtime','Storage','Identity','Certificates','Database','Network','Roles','External')
foreach ($file in @('Core.ps1','WorkspaceRecovery.ps1','ToolRelease.ps1','AdvancedReview.ps1','Review.ps1','Reports.ps1','Inventory.ps1','ScopeClassification.ps1','Fleet.ps1','Discovery.ps1','EnterpriseDiscovery.ps1','Archive.ps1','Templates.ps1','FailureDetails.ps1','Cancellation.ps1','NativeTools.ps1','PhysicalPaths.ps1','RemoteStorageContracts.ps1','ConfigArtifactContracts.ps1','MigrationContracts.ps1','IdentityMapping.ps1','InstallerSafety.ps1','ServiceIdentity.ps1','ServiceSupplement.ps1','Adapters.ps1','TaskSecurity.ps1','IisAdapter.ps1','StreamingDigest.ps1','Payload.ps1','DeltaContracts.ps1','Restore.ps1','CrossHostGates.ps1','CrossHostCoordination.ps1','Qualification.ps1','Cutover.ps1','ActivationRecovery.ps1','ShareQuiescence.ps1','SourceRecovery.ps1','SourceResults.ps1','JournalRecovery.ps1','Recovery.ps1','PackageTransport.ps1','DeltaWorkflow.ps1','DeltaWizard.ps1','LabValidation.ps1','OperationRequests.ps1','MigrationWizard.ps1','BulkMigrationSpecs.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}
