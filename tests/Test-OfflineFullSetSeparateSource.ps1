#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# G-D2: Manager and Source use separate workspaces. The approved CV2 plan must
# carry its source snapshot as an attachment that the Source verifies against
# the sealed hash before placing it at the approved reference.
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path test.'}
$substCommand='subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"';cmd.exe /c $substCommand
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the test.'}
$root=Join-Path ($driveLetter+':\') ('wsmd2-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$HelperPath)
        . $HelperPath
        $script:checks=0
        function Check($condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
        function Sha([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
        $script:fixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='d2-fixture';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:fixtureInventory=[pscustomobject]@{Path='';SHA256=''}
        function script:Export-WsmInventory {param($OutputDirectory,$SourceStateDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog);$script:fixtureInventory}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager-work'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:fixtureFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:fixtureFingerprint=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        $serviceSettings=[pscustomobject]@{Name='FixtureSvc';DisplayName='Fixture service';Description='CV2 separate source fixture';PathName='C:\Fixture\service.exe';StartMode='Auto';StartName='LocalSystem';ServiceType='Own Process';State='Running';Dependencies=@()}
        $serviceItem=New-WsmItem $source.HostId Services Service 'Fixture service' 'FixtureSvc' $serviceSettings @() Success Service
        $inventory=New-WsmInventory $source 1 @($serviceItem);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$inventoryHash=Sha $inventoryPath
        $script:fixtureInventory=[pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash}
        Initialize-WsmWorkspace $managerRoot|Out-Null
        Import-WsmInventory -Workspace $managerRoot -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'FixtureTarget'|Out-Null
        $pairId=[string]((Get-WsmFleet $managerRoot).Pairs[0].PairId)
        $catalog=Get-WsmCatalog $managerRoot $pairId;Enable-WsmAssistiveMode $managerRoot $pairId $catalog.DecisionRevision|Out-Null;$catalog=Get-WsmCatalog $managerRoot $pairId
        $serviceSpec=[pscustomobject]@{Adapter='Service';Owner='fixture service owner';Evidence='explicit CV2 separate source fixture';DesiredFinalState='Automatic';Desired=[pscustomobject]@{Name='FixtureSvc';DisplayName='Fixture service';BinaryPathName='C:\Fixture\service.exe';Account='LocalSystem';Dependencies=@();Description='CV2 separate source fixture';Supplement=(New-WsmFixtureServiceSupplement)}}
        $specPath=Join-Path $Root 'spec.json';Write-WsmJson $specPath $serviceSpec
        Set-WsmMigrationSpec $managerRoot $pairId $serviceItem.ItemId $specPath (Sha $specPath) $catalog.DecisionRevision|Out-Null;$catalog=Get-WsmCatalog $managerRoot $pairId
        Set-WsmDecision $managerRoot $pairId $serviceItem.ItemId Include 'Owner approved this service setting.' $catalog.DecisionRevision|Out-Null;$catalog=Get-WsmCatalog $managerRoot $pairId
        $deliver=Join-Path $Root 'deliver';[void][IO.Directory]::CreateDirectory($deliver)
        $planPath=Join-Path $deliver 'approved-plan.json'
        $approved=Approve-WsmMigrationPlan -Workspace $managerRoot -PairId $pairId -TargetIdentityPath $targetIdentityPath -TargetIdentityHash $targetIdentityHash -Path $planPath -ExpectedRevision $catalog.DecisionRevision -PilotAcknowledgement 'ISOLATED-PILOT' -OfflineFullSet
        $plan=Read-WsmMigrationPlan $planPath $approved.SHA256
        Check ($plan.Assistive.ContractVersion -eq 2) 'Fixture did not seal a CV2 plan.'

        # Contract 1: Manager emits the attachment next to the plan.
        $attachment=$planPath+'.source-snapshot.json'
        Check ([IO.File]::Exists($attachment)) 'CV2 approval did not emit the source snapshot attachment.'
        Check ((Sha $attachment) -ceq [string]$plan.Assistive.SourceSnapshotHash) 'Attachment hash does not equal the sealed SourceSnapshotHash.'
        $managerSnapshot=Join-Path $managerRoot ([string]$plan.Assistive.DiscoveryAuthority.SourceSnapshotReference.Reference).Replace('/','\')
        $attachmentBytes=[IO.File]::ReadAllBytes($attachment);$managerBytes=[IO.File]::ReadAllBytes($managerSnapshot)
        Check ($attachmentBytes.Length -eq $managerBytes.Length -and [Convert]::ToBase64String($attachmentBytes) -ceq [Convert]::ToBase64String($managerBytes)) 'Attachment is not a byte-for-byte copy of the Manager snapshot.'
        Check ($approved.SourceSnapshotAttachmentPath -ceq [IO.Path]::GetFullPath($attachment)) 'Approval result does not report the attachment path.'
        $snapshotRelative=([string]$plan.Assistive.DiscoveryAuthority.SourceSnapshotReference.Reference).Replace('/','\')
        $sourceSnapshot=Join-Path (Join-Path $sourceRoot 'pairs') $snapshotRelative

        # Counter-example: tampered attachment is rejected and leaves nothing behind.
        $tamperDir=Join-Path $Root 'tamper';[void][IO.Directory]::CreateDirectory($tamperDir)
        $tamperPlan=Join-Path $tamperDir 'approved-plan.json';Copy-Item -LiteralPath $planPath -Destination $tamperPlan
        $tamperBytes=[byte[]]$attachmentBytes.Clone();$tamperBytes[$tamperBytes.Length-1]=$tamperBytes[$tamperBytes.Length-1] -bxor 1
        [IO.File]::WriteAllBytes($tamperPlan+'.source-snapshot.json',$tamperBytes)
        $tamperMessage='';try{Import-WsmWizardApprovedPlan $sourceRoot Source $tamperPlan $approved.SHA256|Out-Null}catch{$tamperMessage=$_.Exception.Message}
        Check ($tamperMessage -like '*does not match the approved source snapshot hash*') ('Tampered attachment was not rejected: '+$tamperMessage)
        $receivedRoot=Get-WsmWizardReceivedPlanRoot $sourceRoot
        Check (-not [IO.File]::Exists($sourceSnapshot) -and (-not [IO.Directory]::Exists($receivedRoot) -or @(Get-ChildItem -LiteralPath $receivedRoot -File -ErrorAction SilentlyContinue).Count -eq 0)) 'Tampered import left a plan or snapshot behind.'
        $explicitTamper='';try{Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256 -SourceSnapshotPath ($tamperPlan+'.source-snapshot.json')|Out-Null}catch{$explicitTamper=$_.Exception.Message}
        Check ($explicitTamper -like '*does not match the approved source snapshot hash*') 'Explicit tampered SourceSnapshotPath was not rejected.'

        # Counter-example: destination already holds different content.
        foreach($level in @((Join-Path $sourceRoot 'pairs'),(Join-Path (Join-Path $sourceRoot 'pairs') 'assistive'),[IO.Path]::GetDirectoryName($sourceSnapshot))){[void](New-WsmOutputOwnedDirectory $level)};[IO.File]::WriteAllText($sourceSnapshot,'{"different":"content"}')
        $conflictMessage='';try{Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256|Out-Null}catch{$conflictMessage=$_.Exception.Message}
        Check ($conflictMessage -like 'A different source snapshot already exists*') ('Conflicting destination snapshot was not rejected: '+$conflictMessage)
        Check ((Sha $sourceSnapshot) -cne [string]$plan.Assistive.SourceSnapshotHash -and (-not [IO.Directory]::Exists($receivedRoot) -or @(Get-ChildItem -LiteralPath $receivedRoot -File -ErrorAction SilentlyContinue).Count -eq 0)) 'Conflicting import changed the destination or registered a plan.'
        Remove-Item -LiteralPath $sourceSnapshot -Force

        # Counter-example: attachment missing -> plan imports, backup refuses with a hint.
        $missingDir=Join-Path $Root 'missing';[void][IO.Directory]::CreateDirectory($missingDir)
        $missingPlan=Join-Path $missingDir 'approved-plan.json';Copy-Item -LiteralPath $planPath -Destination $missingPlan
        $missingImport=Import-WsmWizardApprovedPlan $sourceRoot Source $missingPlan $approved.SHA256
        Check ($missingImport.Status -ceq 'ImportedVerified' -and $missingImport.SourceSnapshotStatus -ceq 'Missing' -and $missingImport.SourceSnapshotNextStep -like '*approved-plan.json.source-snapshot.json*') 'Missing attachment did not import with SourceSnapshotStatus=Missing and a next step.'
        $projected=@(Get-WsmHtmlResultProjection @($missingImport));Check ($projected.Count -eq 1 -and [string]$projected[0].SourceSnapshotStatus -ceq 'Missing' -and [string]$projected[0].SourceSnapshotNextStep -like '*source-snapshot.json*') 'HTML result projection dropped the missing-attachment status or next step.'
        $runtime=Get-WsmWizardRuntimeSource $sourceRoot $pairId (Read-WsmOutputProfile $sourceRoot) @()
        $startAction=@($runtime.actions|Where-Object id -ceq 'StartBackup')[0]
        Check ($startAction -and [string]$startAction.reason -like '*.source-snapshot.json*') 'Source runtime projection does not show the missing snapshot next step.'
        $failOperation=[Guid]::NewGuid().ToString('D');$failToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $pairId -PlanHash $approved.SHA256 -OperationId $failOperation
        $failMessage='';try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId $failOperation -DeliveryMode Directory -VolumeBytes 0 -Jobs @() -CancellationToken $failToken|Out-Null}catch{$failMessage=$_.Exception.Message}
        Check ($failMessage -like 'OfflineFullSet source snapshot is missing*') ('One-click backup did not refuse with the existing message: '+$failMessage)
        $failRecord=Read-WsmJson (Join-Path (Get-WsmWizardBackupRoot $sourceRoot $pairId) ($failOperation+'.json'))
        Check ([string]$failRecord.Error.Message -like '*source-snapshot.json*') 'Backup failure record does not mention the required attachment.'

        # Contract 2: attachment placed next to the plan is found automatically.
        $okImport=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        Check ($okImport.Status -ceq 'ImportedVerified' -and $okImport.SourceSnapshotStatus -ceq 'Imported') 'Import with the auto-discovered attachment did not report Imported.'
        Check ([IO.File]::Exists($sourceSnapshot) -and (Sha $sourceSnapshot) -ceq [string]$plan.Assistive.SourceSnapshotHash) 'Snapshot was not placed at the approved reference with the sealed hash.'
        $again=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        Check ($again.SourceSnapshotStatus -ceq 'Imported') 'Re-import with an identical snapshot already in place failed.'

        $okOperation=[Guid]::NewGuid().ToString('D');$okToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $pairId -PlanHash $approved.SHA256 -OperationId $okOperation
        $result=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId $okOperation -DeliveryMode Directory -VolumeBytes 0 -Jobs @() -CancellationToken $okToken
        Check ($result.Status -ceq 'Delivered' -and $result.CoreExport.Sealed -and $result.PackageTest.Valid) 'One-click backup did not succeed on a separate Source after attachment import.'
        $package=Test-WsmMigrationPackage -ManifestPath $result.CoreExport.ManifestPath -ExpectedHash $result.CoreExport.SHA256
        $packagedInventory=Join-Path $package.Root 'controls\source-inventory.json'
        Check ((Sha $packagedInventory) -ceq [string]$plan.Assistive.SourceSnapshotHash) 'Packaged controls/source-inventory.json hash differs from the approved hash.'
        Write-Host ('PASS: CV2 snapshot attachment emitted by Manager, verified and placed by a separate Source, one-click backup succeeded ('+$script:checks+' checks).')
    } $root (Join-Path $PSScriptRoot 'Helper-Fixtures.ps1')
} finally {
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmd2-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
