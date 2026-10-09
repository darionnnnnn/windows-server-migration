$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:ToolVersion='0.3.0'
function Assert-DeliveryReceiptTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-WsmNoReparse([string]$Path){$full=[IO.Path]::GetFullPath($Path);if(Test-Path -LiteralPath $full -PathType Leaf){$item=Get-Item -LiteralPath $full -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse path'}}}
. (Join-Path $PSScriptRoot '..\src\DeliveryReceipts.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('.delivery-receipt-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    $long=('complete-source-member-reference-'*400)
    $receipt=[pscustomobject][ordered]@{Status='Sealed';DeliveryId='11111111-1111-4111-8111-111111111111';ReceiptId='22222222-2222-4222-8222-222222222222';Mode='Zip';OperationKind='Full';BaseVerificationStatus='None';PairId='33333333-3333-4333-8333-333333333333';SourceHostId='44444444-4444-4444-8444-444444444444';TargetHostId='55555555-5555-4555-8555-555555555555';ApprovalId='66666666-6666-4666-8666-666666666666';PlanHash=('a'*64);Generation=3;PackageId='77777777-7777-4777-8777-777777777777';ManifestHash=('b'*64);BaseManifestHash='';TransportHash=('c'*64);TotalVolumeBytes=99;Volumes=@([pscustomobject]@{Number=1;Name='package-fixture-0001.zip';Bytes=99;SHA256=('d'*64)});Members=@([pscustomobject]@{Name='manifest.json';Bytes=1;SHA256=('e'*64)})}
    $report=@([pscustomobject]@{DocumentId='88888888-8888-4888-8888-888888888888';DocumentType='ReportLocatorOnly';Path=('<script>alert(1)</script>|'+$long);SHA256=('e'*64);ReportProjectionHash='';TargetObservationRevision=$null})
    $markdown=Join-Path $root 'delivery.md';Write-WsmDeliveryMarkdown $markdown $receipt $report;$text=[IO.File]::ReadAllText($markdown)
    Assert-DeliveryReceiptTest ($text.Contains('&lt;script&gt;alert(1)&lt;/script&gt;\|')) 'Markdown did not escape untrusted HTML and table delimiters.'
    Assert-DeliveryReceiptTest ($text.Contains($long)) 'Markdown truncated a complete report reference.'
    Assert-DeliveryReceiptTest ($text.Contains('SHA256 '+('d'*64))) 'Markdown omitted a complete volume hash.'
    Assert-DeliveryReceiptTest ($text.Contains('ProductionVerified and ReadinessProof are false.')) 'Delivery document did not retain its report-only warning.'
    $catalog=[pscustomobject]@{Approval=[pscustomobject]@{ApprovalId=$receipt.ApprovalId;Hash=$receipt.PlanHash;TargetHostId=$receipt.TargetHostId};Source=[pscustomobject]@{HostId=$receipt.SourceHostId};DeliveryReceipts=@([pscustomobject]@{ApprovalId=$receipt.ApprovalId;PlanHash=$receipt.PlanHash;SourceHostId=$receipt.SourceHostId;TargetHostId=$receipt.TargetHostId;Status='ImportedVerified';Generation=3;ImportedUtc='2026-10-09T00:00:00.0000000Z';Mode='Zip';VolumeCount=4;TotalVolumeBytes=200;TransportHash=('f'*64);DeliveryId=$receipt.DeliveryId})}
    $summary=Get-WsmDeliveryReceiptSummary $catalog
    Assert-DeliveryReceiptTest ($summary.Status -ceq 'ImportedVerified' -and $summary.VolumeCount -eq 4 -and $summary.ProductionVerified -eq $false -and $summary.ReadinessProof -eq $false) 'Current receipt Fleet projection is incomplete or implies readiness.'
    $noApproval=Get-WsmDeliveryReceiptSummary ([pscustomobject]@{Approval=$null;DeliveryReceipts=@()})
    Assert-DeliveryReceiptTest ($noApproval.Status -ceq 'NoApproval') 'Missing manager approval was not projected safely.'
    $catalog | Add-Member NoteProperty Generation 4 -Force;$oldGeneration=Get-WsmDeliveryReceiptSummary $catalog
    Assert-DeliveryReceiptTest ($oldGeneration.Status -ceq 'Stale') 'Older receipt generation was not projected as stale.'
    $catalog.Approval.Hash='9'*64;$stale=Get-WsmDeliveryReceiptSummary $catalog
    Assert-DeliveryReceiptTest ($stale.Status -ceq 'OldApproval') 'Stale approval receipt was not surfaced as OldApproval in the Fleet projection.'
    Write-Host 'PASS: delivery Markdown escapes untrusted content without truncation; Fleet receipt projection is current-approval-bound and report-only.'
}finally{if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}}

# Exercise real producers and the manager receipt importer with a small, empty
# but valid approved package. This verifies receipt plumbing without OS restore.
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$flowRoot=Join-Path ([IO.Path]::GetTempPath()) ('drf-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
try{
    & $module {
        param($FlowRoot,$FixturePath)
        . $FixturePath
        function Assert-DeliveryFlow([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
        function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=('a'*64);Name='receipt-source';OS='Windows Server fixture';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        # This contract tests receipt references, not native host enumeration.
        function Export-WsmInventory {
            param([string]$OutputDirectory,[switch]$DeepDiscovery)
            $inventory=New-WsmInventory ([pscustomobject]@{HostId=$script:ReceiptFixtureSourceId;Fingerprint=('a'*64);Name='receipt-source';OS='Windows Server fixture';Version='10.0'}) 1 @()
            $path=Join-Path $OutputDirectory 'receipt-fixture-inventory.json'
            Write-WsmJson $path $inventory
            [pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
        Write-Host 'Delivery flow: workspace enrollment.'
        $sourceWorkRoot=Join-Path $FlowRoot 'source-workroot';$sourceEnrollment=Initialize-WsmOutputWorkspace -WorkRoot $sourceWorkRoot -Role Source;$script:ReceiptFixtureSourceId=$sourceEnrollment.HostId
        Write-Host 'Delivery flow: report reference projection.'
        $packageRoot=Join-Path $FlowRoot 'package';[void][IO.Directory]::CreateDirectory($packageRoot)
        $projection=[pscustomobject][ordered]@{Setting='fixture';Value='safe'}
        $projectionHash=Get-WsmHashText (ConvertTo-Json -InputObject $projection -Depth 45 -Compress)
        $reportPath=Join-Path $FlowRoot 'confirmation.json'
        Write-WsmJson $reportPath ([pscustomobject]@{ReportProjectionHash=$projectionHash;Projection=$projection})
        $reportRef=[pscustomobject]@{DocumentId=[Guid]::NewGuid().ToString('D');Path=$reportPath;SHA256=(Get-FileHash $reportPath).Hash;ReportProjectionHash=$projectionHash}
        $verified=@(Assert-WsmDeliveryReportReferences @($reportRef))
        Assert-DeliveryFlow ($verified.Count -eq 1 -and $verified[0].ReportProjectionHash -ceq $projectionHash) 'Exact report projection was not verified.'
        Write-WsmJson $reportPath ([pscustomobject]@{ReportProjectionHash=$projectionHash;Projection=[pscustomobject]@{Setting='fixture';Value='changed'}})
        $reportRef.SHA256=(Get-FileHash $reportPath).Hash
        $projectionRejected=$false;try{Assert-WsmDeliveryReportReferences @($reportRef)|Out-Null}catch{$projectionRejected=$true}
        Assert-DeliveryFlow $projectionRejected 'Changed projection content was accepted merely because its file hash was current.'
        $batch=[Guid]::NewGuid().ToString('D');$pair=[Guid]::NewGuid().ToString('D');$approval=[Guid]::NewGuid().ToString('D');$sourceId=$sourceEnrollment.HostId;$targetId=[Guid]::NewGuid().ToString('D')
        $source=[pscustomobject]@{HostId=$sourceId;Fingerprint=('a'*64);Name='receipt-source'};$target=[pscustomobject]@{HostId=$targetId;Fingerprint=('b'*64);Name='receipt-target'}
        $plan=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPlan';BatchId=$batch;PairId=$pair;ApprovalId=$approval;Source=$source;Target=$target;InventoryRevision=1;DecisionRevision=1;Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);Items=@()}
        $planPath=Join-Path $packageRoot 'plan.json';Write-WsmJson $planPath $plan;$planHash=(Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $artifactPath=Join-Path $packageRoot 'artifacts.jsonl';[IO.File]::WriteAllText($artifactPath,'',(New-Object Text.UTF8Encoding($false)));$artifactHash=(Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString('D');BatchId=$batch;PairId=$pair;ApprovalId=$approval;PlanHash=$planHash;Source=$source;Target=$target;InventoryRevision=1;DecisionRevision=1;Generation=1;BaseManifestHash='';Final=$false;FreezeHash='';ArtifactsHash=$artifactHash;Files=0;Bytes=0;Records=0;ChunkBytes=65536;SealedUtc=[DateTime]::UtcNow.ToString('o');Mode='IsolatedPilot'}
        $manifestPath=Join-Path $packageRoot 'manifest.json';Write-WsmJson $manifestPath $manifest;$manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host 'Delivery flow: full ZIP producer.'
        $zipRoot=Join-Path $FlowRoot 'zip';$zip=Export-WsmPackageZip -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory $zipRoot -VolumeBytes 1048576
        $zipDoc=Export-WsmDeliveryDocument -TransportPath $zip.Path -ExpectedHash $zip.SHA256 -ManifestPath $manifestPath -ExpectedManifestHash $manifestHash -OutputDirectory (Join-Path $FlowRoot 'zip-report')
        $sealed=Read-WsmJson $zipDoc.ReceiptPath
        $expectedDeliveryId=[Guid]::ParseExact((Get-WsmHashText ($zip.SHA256.ToLowerInvariant()+'|'+$manifest.PackageId)).Substring(0,32),'N').ToString('D')
        Assert-DeliveryFlow ($sealed.Status -ceq 'Sealed' -and $sealed.Mode -ceq 'Zip' -and $sealed.DeliveryId -ceq $expectedDeliveryId) ('ZIP delivery document did not emit a stable sealed receipt. Actual='+$sealed.Status+'/'+$sealed.Mode+'/'+$sealed.DeliveryId+' Expected='+$expectedDeliveryId)
        $sourceSealHash=(Get-FileHash -LiteralPath $zipDoc.ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-Host 'Delivery flow: source LabReport receipt reference.'
        $labReport=Export-WsmLabValidationReport -OutputDirectory (Join-Path $FlowRoot 'lab-report') -Role Source -ManifestPath $manifestPath -ExpectedHash $manifestHash -DeliveryReceiptReferences @([pscustomobject]@{Path=$zipDoc.ReceiptPath;SHA256=$sourceSealHash})
        $labReportJson=Read-WsmJson $labReport.JSONPath;$labReportText=[IO.File]::ReadAllText($labReport.TextPath)
        Assert-DeliveryFlow (@($labReportJson.Checks | Where-Object {$_.Code -ceq 'NativeInventoryCollected' -and $_.Status -ceq 'PASS'}).Count -eq 1) 'Receipt test did not consume its trusted source inventory fixture.'
        Assert-DeliveryFlow ($labReportJson.DeliveryReceiptReferences.Count -eq 1 -and $labReportJson.DeliveryReceiptReferences[0].Status -ceq 'Sealed' -and $labReportJson.DeliveryReceiptReferencesReadinessProof -eq $false -and $labReportJson.DeliveryReceiptReferencesProductionVerified -eq $false -and $labReportText.Contains($sourceSealHash) -and $labReportJson.Readiness -ne 'Ready') 'Lab report did not retain its exact receipt reference as report-only JSON/text output.'
        Write-Host 'Delivery flow: full Directory producer.'
        $directory=Export-WsmDirectoryDelivery -ManifestPath $manifestPath -ExpectedHash $manifestHash -OutputDirectory (Join-Path $FlowRoot 'directory-package')
        $directoryDoc=Export-WsmDeliveryDocument -TransportPath $directory.SummaryPath -ExpectedHash $directory.SummarySHA256 -ManifestPath (Join-Path $directory.Directory 'manifest.json') -ExpectedManifestHash $manifestHash -OutputDirectory (Join-Path $FlowRoot 'directory-report')
        $directoryReceipt=Read-WsmJson $directoryDoc.ReceiptPath
        Assert-DeliveryFlow ($directoryReceipt.Status -ceq 'Sealed' -and $directoryReceipt.Mode -ceq 'Directory' -and $directoryReceipt.Members.Count -eq 3 -and $directoryReceipt.Volumes.Count -eq 0) 'Directory delivery document omitted its complete package member set.'
        Write-WsmJson $reportPath ([pscustomobject]@{ReportProjectionHash=$projectionHash;Projection=$projection})
        $reportRef.SHA256=(Get-FileHash $reportPath).Hash
        Write-Host 'Delivery flow: enrolled source ZIP producer.'
        $enrolled=Export-WsmEnrolledPackageDelivery -WorkRoot $sourceWorkRoot -ManifestPath $manifestPath -ExpectedHash $manifestHash -ReportReferences @($reportRef)
        $enrolledReceipt=Read-WsmJson $enrolled.DeliveryDocumentation.ReceiptPath
        Assert-DeliveryFlow ($enrolledReceipt.Status -ceq 'Sealed' -and $enrolledReceipt.Mode -ceq 'Zip' -and (Get-FileHash -LiteralPath $enrolled.DeliveryDocumentation.MarkdownPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $enrolled.DeliveryDocumentation.MarkdownHash -and [IO.File]::Exists($enrolled.IndexPath)) 'Real enrolled source delivery did not create a hash-bound Markdown document and index.'
        $enrolledIndex=Read-WsmJson $enrolled.IndexPath
        Assert-DeliveryFlow ($enrolledIndex.ReportReferences[0].ReportProjectionHash -ceq $projectionHash -and [IO.File]::ReadAllText($enrolled.DeliveryDocumentation.MarkdownPath).Contains('ProjectionHashVerified')) 'Enrolled ZIP lost its verified report projection reference.'
        $sourceProfilePath=Join-Path $sourceWorkRoot 'workspace-control\output-profile.json'
        Set-WsmOutputPreferences -WorkRoot $sourceWorkRoot -Role Source -ExpectedProfileHash (Get-FileHash $sourceProfilePath).Hash -Mode Directory | Out-Null
        Write-Host 'Delivery flow: enrolled source Directory producer.'
        $enrolledDirectory=Export-WsmEnrolledPackageDelivery -WorkRoot $sourceWorkRoot -ManifestPath $manifestPath -ExpectedHash $manifestHash -ReportReferences @($reportRef)
        Assert-DeliveryFlow ($enrolledDirectory.AttemptId -cne $enrolled.AttemptId -and [IO.File]::ReadAllText($enrolledDirectory.DeliveryDocumentation.MarkdownPath).Contains('ProjectionHashVerified')) 'Enrolled Directory did not preserve its independent attempt and verified report projection.'
        Write-Host 'Delivery flow: native full import and target receipt.'
        $incoming=Import-WsmPackageZip -TransportPath $zip.Path -ExpectedHash $zip.SHA256 -OutputDirectory (Join-Path $FlowRoot 'incoming')
        $targetReceipt=Export-WsmImportedDeliveryReceipt -TransportPath $zip.Path -ExpectedHash $zip.SHA256 -ManifestPath $incoming.ManifestPath -ExpectedManifestHash $incoming.SHA256 -OutputDirectory (Join-Path $FlowRoot 'target-receipt')
        $receipt=Read-WsmJson $targetReceipt.Path;$receiptHash=(Get-FileHash -LiteralPath $targetReceipt.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-DeliveryFlow ($receipt.Status -ceq 'ImportedVerified' -and -not $receipt.ReadinessProof -and -not $receipt.ProductionVerified) 'Target did not emit a report-only ImportedVerified receipt.'
        Write-Host 'Delivery flow: manager stage-aware imports.'
        $manager=Join-Path $FlowRoot 'manager';[void][IO.Directory]::CreateDirectory((Join-Path $manager 'pairs'))
        Write-WsmJson (Join-Path $manager 'fleet.json') ([pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='Fleet';BatchId=$batch;CreatedUtc=[DateTime]::UtcNow.ToString('o');Pairs=@([pscustomobject]@{PairId=$pair})})
        $catalog=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='Catalog';BatchId=$batch;PairId=$pair;Source=$source;TargetName='receipt-target';ImportedUtc=[DateTime]::UtcNow.ToString('o');InventoryRevision=1;DecisionRevision=1;Items=@();Approval=[pscustomobject]@{Kind='MigrationPlan';Mode='IsolatedPilot';ApprovalId=$approval;Hash=$planHash;TargetHostId=$targetId;TargetFingerprint=$target.Fingerprint}}
        Write-WsmJson (Join-Path (Join-Path $manager 'pairs') ($pair+'.json')) $catalog
        $sealedImport=Import-WsmDeliveryReceipt -Workspace $manager -Path $zipDoc.ReceiptPath -ExpectedHash $sourceSealHash
        Assert-DeliveryFlow ($sealedImport.Status -ceq 'Sealed') 'Manager could not import the source Sealed receipt stage.'
        $imported=Import-WsmDeliveryReceipt -Workspace $manager -Path $targetReceipt.Path -ExpectedHash $receiptHash
        $tampered=$receipt|ConvertTo-Json -Depth 20|ConvertFrom-Json;$tampered.TargetFingerprint='9'*64;$tamperedPath=Join-Path $FlowRoot 'tampered-target-receipt.json';Write-WsmJson $tamperedPath $tampered;$tamperedHash=(Get-FileHash -LiteralPath $tamperedPath -Algorithm SHA256).Hash.ToLowerInvariant();$wrongTargetRejected=$false;try{Import-WsmDeliveryReceipt -Workspace $manager -Path $tamperedPath -ExpectedHash $tamperedHash|Out-Null}catch{$wrongTargetRejected=$true}
        Assert-DeliveryFlow $wrongTargetRejected 'Manager accepted a receipt bound to a different target fingerprint.'
        $summary=Get-WsmDeliveryReceiptSummary (Get-WsmCatalog $manager $pair)
        Assert-DeliveryFlow ($imported.Status -ceq 'ImportedVerified' -and $summary.Status -ceq 'ImportedVerified' -and $summary.Generation -eq 1 -and -not $summary.ReadinessProof -and -not $summary.ProductionVerified) 'Manager importer failed to retain the exact report-only receipt projection.'
        # Empty approved package indexes keep this transport test independent of
        # machine-specific payload adapters while exercising native Delta contracts.
        Write-Host 'Delivery flow: native delta receipt producers.'
        $deltaRoot=Join-Path $FlowRoot 'delta';$baseRoot=Join-Path $deltaRoot 'base';$currentRoot=Join-Path $deltaRoot 'current';[void][IO.Directory]::CreateDirectory($baseRoot);[void][IO.Directory]::CreateDirectory($currentRoot)
        $deltaSource=Join-Path $deltaRoot 'source-scope';$deltaTarget=Join-Path $deltaRoot 'target-scope';[void][IO.Directory]::CreateDirectory($deltaSource);[void][IO.Directory]::CreateDirectory($deltaTarget);$deltaItemId=Get-WsmHashText ($source.HostId+'|Storage|FileScope|receipt-delta-fixture');$deltaSpec=[pscustomobject][ordered]@{Adapter='FileScope';Owner='receipt fixture owner';Evidence='receipt fixture evidence';SourcePath=$deltaSource;TargetPath=$deltaTarget;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='ReplaceOwned'};$deltaItem=[pscustomobject]@{ItemId=$deltaItemId;Decision='Include';MigrationSpec=$deltaSpec}
        $deltaPlan=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPlan';BatchId=$batch;PairId=$pair;ApprovalId=$approval;Source=$source;Target=$target;InventoryRevision=1;DecisionRevision=1;Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);Items=@($deltaItem)}
        $deltaPlanPath=Join-Path $baseRoot 'plan.json';Write-WsmJson $deltaPlanPath $deltaPlan;$deltaPlanHash=(Get-FileHash -LiteralPath $deltaPlanPath -Algorithm SHA256).Hash.ToLowerInvariant();Copy-Item -LiteralPath $deltaPlanPath -Destination (Join-Path $currentRoot 'plan.json')
        $metadata=Get-WsmFileMetadata $deltaSource 'DaclOwner';$row=[pscustomobject]@{ItemId=$deltaItemId;RelativePath='';Directory=$true;Metadata=$metadata;Data=$null};$rowJson=ConvertTo-Json -InputObject $row -Depth 20 -Compress
        foreach($packageDir in @($baseRoot,$currentRoot)){[IO.File]::WriteAllText((Join-Path $packageDir 'artifacts.jsonl'),$rowJson+"`n",(New-Object Text.UTF8Encoding($false)))}
        $baseManifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString('D');BatchId=$batch;PairId=$pair;ApprovalId=$approval;PlanHash=$deltaPlanHash;Source=$source;Target=$target;InventoryRevision=1;DecisionRevision=1;Generation=1;BaseManifestHash='';Final=$false;FreezeHash='';ArtifactsHash=(Get-FileHash -LiteralPath (Join-Path $baseRoot 'artifacts.jsonl')).Hash.ToLowerInvariant();Files=0;Bytes=0;Records=0;ChunkBytes=65536;SealedUtc=[DateTime]::UtcNow.ToString('o');Mode='IsolatedPilot'}
        $baseManifestPath=Join-Path $baseRoot 'manifest.json';Write-WsmJson $baseManifestPath $baseManifest;$baseManifestHash=(Get-FileHash -LiteralPath $baseManifestPath).Hash.ToLowerInvariant()
        $freezeFixture=New-WsmSourceFreezeEvidenceFixture -Plan $deltaPlan -PlanHash $deltaPlanHash -Root $deltaRoot -Owner 'receipt fixture owner';$freezeAttestation=Assert-WsmSourceFreezeEvidence $freezeFixture.Path $freezeFixture.SHA256 $deltaPlan $deltaPlanHash $freezeFixture.FreezeEpoch
        $freezePath=Join-Path $currentRoot 'freeze.json';$freeze=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceFreeze';FreezeId=[Guid]::NewGuid().ToString();BatchId=$batch;PairId=$pair;ApprovalId=$approval;PlanHash=$deltaPlanHash;SourceHostId=$source.HostId;SourceFingerprint=$source.Fingerprint;TargetFingerprint=$target.Fingerprint;FreezeEpoch=$freezeFixture.FreezeEpoch;SourceFreezeEvidence=$freezeAttestation;Owner='receipt fixture owner';Evidence='temporary local test fixture';Acknowledgement='OWNER-CONFIRMED-QUIESCENCE';SourceIdentityReleased=$true;ReleaseEvidence='fixture source isolated';Activities=@();QuiescedSettingsHashes=@();ProducedUtc=[DateTime]::UtcNow.ToString('o');ExpiresUtc=[DateTime]::UtcNow.AddHours(2).ToString('o');Scope='temporary local test fixture'};Write-WsmJson $freezePath $freeze;$freezeHash=(Get-FileHash -LiteralPath $freezePath).Hash.ToLowerInvariant()
        $currentManifest=$baseManifest|ConvertTo-Json -Depth 20|ConvertFrom-Json;$currentManifest.PackageId=[Guid]::NewGuid().ToString('D');$currentManifest.Generation=2;$currentManifest.BaseManifestHash=$baseManifestHash;$currentManifest.Final=$true;$currentManifest.FreezeHash=$freezeHash
        $currentManifestPath=Join-Path $currentRoot 'manifest.json';Write-WsmJson $currentManifestPath $currentManifest;$currentManifestHash=(Get-FileHash -LiteralPath $currentManifestPath).Hash.ToLowerInvariant()
        $changesPath=Join-Path $deltaRoot 'changes.jsonl';$deltaSummaryPath=Join-Path $deltaRoot 'summary.json';$deltaSummary=New-WsmArtifactDeltaManifest -BaseManifestPath $baseManifestPath -BaseManifestHash $baseManifestHash -BasePlanPath $deltaPlanPath -BasePlanHash $deltaPlanHash -CurrentManifestPath $currentManifestPath -CurrentManifestHash $currentManifestHash -CurrentPlanPath (Join-Path $currentRoot 'plan.json') -CurrentPlanHash $deltaPlanHash -OutputPath $changesPath -SummaryPath $deltaSummaryPath -OwnedItemIds @($deltaItemId)
        $zipDelta=Export-WsmArtifactDeltaVolumes -BaseManifestPath $baseManifestPath -BaseManifestHash $baseManifestHash -BasePlanPath $deltaPlanPath -BasePlanHash $deltaPlanHash -CurrentManifestPath $currentManifestPath -CurrentManifestHash $currentManifestHash -CurrentPlanPath (Join-Path $currentRoot 'plan.json') -CurrentPlanHash $deltaPlanHash -SummaryPath $deltaSummaryPath -SummaryHash $deltaSummary.SummaryHash -ChangesPath $changesPath -OutputDirectory (Join-Path $deltaRoot 'zip') -ScratchDirectory (Join-Path $deltaRoot 'zip-scratch') -VolumeBytes 1048576
        $zipDoc=Export-WsmDeliveryDocument -TransportPath $zipDelta.TransportPath -ExpectedHash $zipDelta.SHA256 -ManifestPath $currentManifestPath -ExpectedManifestHash $currentManifestHash -BaseManifestPath $baseManifestPath -BaseManifestHash $baseManifestHash -OperationKind Delta -SummaryPath $deltaSummaryPath -SummaryHash $deltaSummary.SummaryHash -ChangesPath $changesPath -OutputDirectory (Join-Path $deltaRoot 'zip-doc')
        $wrongKindRejected=$false;try{Export-WsmDeliveryDocument -TransportPath $zip.Path -ExpectedHash $zip.SHA256 -ManifestPath $currentManifestPath -ExpectedManifestHash $currentManifestHash -OperationKind Delta -BaseManifestPath $baseManifestPath -BaseManifestHash $baseManifestHash -OutputDirectory (Join-Path $deltaRoot 'wrong-kind-doc')|Out-Null}catch{$wrongKindRejected=$true}
        $wrongModeRejected=$false;try{Export-WsmDeliveryDocument -TransportPath $zipDelta.TransportPath -ExpectedHash $zipDelta.SHA256 -ManifestPath $currentManifestPath -ExpectedManifestHash $currentManifestHash -OperationKind Full -OutputDirectory (Join-Path $deltaRoot 'wrong-mode-doc')|Out-Null}catch{$wrongModeRejected=$true}
        $wrongBaseRejected=$false;try{Export-WsmDeliveryDocument -TransportPath $zipDelta.TransportPath -ExpectedHash $zipDelta.SHA256 -ManifestPath $currentManifestPath -ExpectedManifestHash $currentManifestHash -BaseManifestPath $baseManifestPath -BaseManifestHash ('0'*64) -OperationKind Delta -SummaryPath $deltaSummaryPath -SummaryHash $deltaSummary.SummaryHash -ChangesPath $changesPath -OutputDirectory (Join-Path $deltaRoot 'wrong-base-doc')|Out-Null}catch{$wrongBaseRejected=$true}
        $wrongHashRejected=$false;try{Export-WsmDeliveryDocument -TransportPath $zipDelta.TransportPath -ExpectedHash ('0'*64) -ManifestPath $currentManifestPath -ExpectedManifestHash $currentManifestHash -BaseManifestPath $baseManifestPath -BaseManifestHash $baseManifestHash -OperationKind Delta -SummaryPath $deltaSummaryPath -SummaryHash $deltaSummary.SummaryHash -ChangesPath $changesPath -OutputDirectory (Join-Path $deltaRoot 'wrong-hash-doc')|Out-Null}catch{$wrongHashRejected=$true}
        Assert-DeliveryFlow ($wrongKindRejected -and $wrongModeRejected -and $wrongBaseRejected -and $wrongHashRejected) 'Delta delivery receipt accepted a wrong transport kind, operation mode, base hash or transport hash.'
        $zipImported=Import-WsmArtifactDeltaVolumes -TransportPath $zipDelta.TransportPath -ExpectedHash $zipDelta.SHA256 -OutputDirectory (Join-Path $deltaRoot 'zip-in') -ScratchDirectory (Join-Path $deltaRoot 'zip-in-scratch')
        $zipImportReceipt=Export-WsmImportedDeliveryReceipt -TransportPath $zipDelta.TransportPath -ExpectedHash $zipDelta.SHA256 -ManifestPath (Join-Path (Join-Path $zipImported.Directory 'current') 'manifest.json') -ExpectedManifestHash $currentManifestHash -BaseManifestPath (Join-Path (Join-Path $zipImported.Directory 'base') 'manifest.json') -BaseManifestHash $baseManifestHash -OperationKind Delta -ImportedDirectory $zipImported.Directory -OutputDirectory (Join-Path $deltaRoot 'zip-import-receipt')
        $zipImportedReceipt=Read-WsmJson $zipImportReceipt.Path
        Assert-DeliveryFlow ($zipImported.Valid -and $zipImportedReceipt.Status -ceq 'ImportedVerified' -and $zipImportedReceipt.OperationKind -ceq 'Delta' -and $zipImportedReceipt.BaseVerificationStatus -ceq 'VerifiedTrustedBase' -and -not $zipImportedReceipt.ReadinessProof -and -not $zipImportedReceipt.ProductionVerified) 'Native ZIP delta import did not produce the bound report-only delta receipt.'
        $directoryDelta=Export-WsmArtifactDeltaDirectory -BaseManifestPath $baseManifestPath -BaseManifestHash $baseManifestHash -BasePlanPath $deltaPlanPath -BasePlanHash $deltaPlanHash -CurrentManifestPath $currentManifestPath -CurrentManifestHash $currentManifestHash -CurrentPlanPath (Join-Path $currentRoot 'plan.json') -CurrentPlanHash $deltaPlanHash -SummaryPath $deltaSummaryPath -SummaryHash $deltaSummary.SummaryHash -ChangesPath $changesPath -OutputDirectory (Join-Path $deltaRoot 'directory') -ScratchDirectory (Join-Path $deltaRoot 'directory-scratch')
        $directoryDoc=Export-WsmDeliveryDocument -TransportPath $directoryDelta.TransportPath -ExpectedHash $directoryDelta.SHA256 -ManifestPath $currentManifestPath -ExpectedManifestHash $currentManifestHash -BaseManifestPath $baseManifestPath -BaseManifestHash $baseManifestHash -OperationKind Delta -SummaryPath $deltaSummaryPath -SummaryHash $deltaSummary.SummaryHash -ChangesPath $changesPath -OutputDirectory (Join-Path $deltaRoot 'directory-doc')
        $directoryImported=Import-WsmArtifactDeltaDirectory -TransportPath $directoryDelta.TransportPath -ExpectedHash $directoryDelta.SHA256 -OutputDirectory (Join-Path $deltaRoot 'directory-in') -ScratchDirectory (Join-Path $deltaRoot 'directory-in-scratch')
        $directoryImportReceipt=Export-WsmImportedDeliveryReceipt -TransportPath $directoryDelta.TransportPath -ExpectedHash $directoryDelta.SHA256 -ManifestPath (Join-Path (Join-Path $directoryImported.Directory 'current') 'manifest.json') -ExpectedManifestHash $currentManifestHash -BaseManifestPath (Join-Path (Join-Path $directoryImported.Directory 'base') 'manifest.json') -BaseManifestHash $baseManifestHash -OperationKind Delta -ImportedDirectory $directoryImported.Directory -OutputDirectory (Join-Path $deltaRoot 'directory-import-receipt')
        $directoryImportedReceipt=Read-WsmJson $directoryImportReceipt.Path
        Assert-DeliveryFlow ($directoryImported.Valid -and $directoryImportedReceipt.Status -ceq 'ImportedVerified' -and $directoryImportedReceipt.Mode -ceq 'Directory' -and $directoryImportedReceipt.BaseVerificationStatus -ceq 'VerifiedTrustedBase' -and $directoryImportedReceipt.Members.Count -gt 0) 'Native Directory delta import did not produce the bound report-only delta receipt.'
        Write-Host 'PASS: full ZIP/directory and enrolled-source delivery documents plus ZIP and Directory delta producer→imported receipt flows are exact-bound, manager stage-aware, and report-only.'
    } $flowRoot (Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1')
}finally{if([IO.Directory]::Exists($flowRoot)){[IO.Directory]::Delete([IO.Path]::GetFullPath($flowRoot),$true)}}
