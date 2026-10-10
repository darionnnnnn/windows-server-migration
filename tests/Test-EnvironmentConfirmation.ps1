#requires -Version 5.1
param([ValidateRange(6,5001)][int]$FixtureCount=2501)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function ConvertFrom-EnvironmentFixtureJson([string]$Json) {
    $convertCommand=Get-Command ConvertFrom-Json
    if($convertCommand.Parameters.ContainsKey('DateKind')){return ConvertFrom-Json -InputObject $Json -DateKind String}
    ConvertFrom-Json -InputObject $Json
}

# Freeze the source set before importing so concurrent implementation cannot
# change the code under test. The copied source tree is verified both before
# and after the test run.
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=[IO.Path]::GetFullPath((Join-Path $tempRoot ('wsm-environment-confirmation-'+[Guid]::NewGuid().ToString('N'))))
if(-not $testRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Directory]::Exists($testRoot)){throw 'Refusing unsafe test-owned directory.'}
[void][IO.Directory]::CreateDirectory($testRoot)
$snapshot=Join-Path $testRoot 'snapshot'
[void][IO.Directory]::CreateDirectory($snapshot)
$sourceFiles=@(Get-ChildItem -LiteralPath (Join-Path $repo 'src') -File | Where-Object Extension -EQ '.ps1')
$snapshotReady=$false;$before=@{}
for($attempt=0;$attempt -lt 5 -and -not $snapshotReady;$attempt++){
    $before=@{};foreach($file in $sourceFiles){$before[$file.Name]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    foreach($file in Get-ChildItem -LiteralPath $snapshot -File){Remove-Item -LiteralPath $file.FullName -Force}
    foreach($file in $sourceFiles){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $snapshot $file.Name)}
    Copy-Item -LiteralPath (Join-Path $repo 'src\WindowsServerMigration.psm1') -Destination (Join-Path $snapshot 'WindowsServerMigration.psm1')
    Copy-Item -LiteralPath (Join-Path $repo 'src\WindowsServerMigration.psd1') -Destination (Join-Path $snapshot 'WindowsServerMigration.psd1')
    $snapshotReady=$true;foreach($file in $sourceFiles){if((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $before[$file.Name]){$snapshotReady=$false;break}}
    if(-not $snapshotReady){Start-Sleep -Milliseconds 250}
}
if(-not $snapshotReady){throw 'Could not freeze a consistent fixed source snapshot while another implementation stage was writing.'}
$snapshotHashes=@{};foreach($file in Get-ChildItem -LiteralPath $snapshot -File){$snapshotHashes[$file.Name]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}

$module=$null
try {
    $module=Import-Module (Join-Path $snapshot 'WindowsServerMigration.psd1') -Force -PassThru
    $catalogPath=Join-Path $snapshot 'EnvironmentConfirmation.ps1'
    function Invoke-EnvironmentModule {
        param($Fixture,[scriptblock]$Action,[object[]]$Arguments=@())
        & $module {
            param($SourcePath,$CatalogFixture,$InnerActionText,$InnerArguments)
            $script:EnvironmentFixture=$CatalogFixture
            function Get-WsmCatalog { param([string]$Workspace,[string]$PairId) $script:EnvironmentFixture }
            . $SourcePath
            $moduleAction=[scriptblock]::Create($InnerActionText)
            & $moduleAction @InnerArguments
        } $catalogPath $Fixture $Action.ToString() $Arguments
    }
    function Get-EnvironmentSoftwareCatalogHash($SoftwareCatalog) {
        & $module {param($Catalog) Get-WsmSoftwareCatalogProjectionHash $Catalog} $SoftwareCatalog
    }
    function Set-EnvironmentSoftwareBinding($Catalog) {
        & $module {param($InputCatalog) $InputCatalog.GeneralHost.SoftwareCatalog=$InputCatalog.SoftwareCatalog;$InputCatalog.GeneralHost.SoftwareCatalogHash=Get-WsmHashText ($InputCatalog.SoftwareCatalog | ConvertTo-Json -Depth 30 -Compress);$InputCatalog} $Catalog
    }

    $workspace=Join-Path $testRoot 'workspace';$output=Join-Path $testRoot 'reports'
    Initialize-WsmWorkspace $workspace | Out-Null
    $fixture=& $module {
        param($Count)
        $host=[Guid]::NewGuid().ToString('D');$pair=[Guid]::NewGuid().ToString('D')
        $entries=New-Object 'System.Collections.Generic.List[object]'
        for($n=0;$n -lt $Count;$n++){
            $scope='Machine';$sid='';$view='Registry64';$version='1.0'
            if($n -eq 1){$view='Registry32';$version='2.0'}
            if($n -eq 2){$scope='User';$sid='S-1-5-21-1-2-3-1001';$view='Registry64';$version='1.0'}
            if($n -eq 3){$scope='User';$sid='S-1-5-21-1-2-3-1002';$view='Registry64';$version='1.0'}
            if($n -eq 4){$scope='OwnerProvided';$view='Manual';$version='3.0'}
            $id='sw-'+(Get-WsmHashText ($n.ToString()+'|'+$scope+'|'+$sid+'|'+$view)).Substring(0,32)
            $name='Fixture Software '+$n;if($n -le 4){$name='Same Name'};if($n -eq 5){$name='=HYPERLINK("https://evil.invalid") ![image](https://evil.invalid) | `<script>`'}
            $entry=[ordered]@{SoftwareId=$id;Name=$name;Version=$version;Publisher='Publisher';Architecture='Unknown';Scope=$scope;SID=$sid;RegistryView=$view;Location=('registry:fixture/'+$n);SourceKind=$(if($scope -eq 'OwnerProvided'){'OwnerProvided'}else{'Registry'});Evidence=[pscustomobject]@{Probe='Fixture';NaturalKey=('fixture-'+$n)};ObservedUtc=[DateTime]::UtcNow.ToString('o');CaptureStatus=$(if($scope -eq 'OwnerProvided'){'Manual'}else{'Success'});ItemIds=@();AccountContext='Unknown'}
            if($scope -eq 'OwnerProvided'){$entry.Owner='App owner';$entry.EvidenceHash='a'*64;$entry.ProvidedUtc=[DateTime]::UtcNow.ToString('o')}
            $entries.Add([pscustomobject]$entry)
        }
        $coverage=@(
            [pscustomobject]@{Probe='HKLM-Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=($Count-1);Budget=[pscustomobject]@{MaxEntries=10000};ErrorKind=$null;ObservedUtc=[DateTime]::UtcNow.ToString('o')},
            [pscustomobject]@{Probe='HKU-Uninstall';Scope='User';SID='S-1-5-21-1-2-3-1002';View='Registry64';Status='NotTested';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=10000};ErrorKind='ProfileHiveNotLoaded';ObservedUtc=[DateTime]::UtcNow.ToString('o')},
            [pscustomobject]@{Probe='ODBCUserDSN';Scope='User';SID='S-1-5-21-1-2-3-1001';View='Default';Status='PermissionDenied';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=10000};ErrorKind='AccessDenied';ObservedUtc=[DateTime]::UtcNow.ToString('o')},
            [pscustomobject]@{Probe='PortableFiles';Scope='Portable';SID='';View='Filesystem';Status='Partial';EvidenceKind='FileMetadata';Count=0;Budget=[pscustomobject]@{MaxEntries=10;VisitedEntries=10;MaxDepth=2;MaxMetadataBytes=4096};ErrorKind='ReparsePointRejected';ObservedUtc=[DateTime]::UtcNow.ToString('o')},
            [pscustomobject]@{Probe='AbsentCandidate';Scope='Machine';SID='';View='Registry64';Status='NotInstalled';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=10000};ErrorKind=$null;ObservedUtc=[DateTime]::UtcNow.ToString('o')}
        )
        $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$host;Fingerprint=('a'*64);Name='fixture-source';InventoryRevision=1;InventoryProjectionHash=('b'*64)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CaptureIdentity=[Guid]::NewGuid().ToString('N');AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='7.5.0';RequestedPortableRoots=@()};Entries=$entries.ToArray();Coverage=$coverage;PreparationRequirements=@(foreach($entry in $entries){[pscustomobject][ordered]@{PreparationId=('prep-'+$entry.SoftwareId.Substring(3));SoftwareId=$entry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus=$entry.CaptureStatus;ConsumerItemIds=@($entry.ItemIds);Owner='';Reason='Evidence inventory only; owner review required.'}});CatalogProjectionHash=('0'*64)}
        $software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software
        $sourceItem=New-WsmItem -HostId $host -Category 'System' -Kind 'TimeZone' -Name 'TimeZone' -NaturalKey 'tz' -Settings ([ordered]@{Zone='Pacific Standard Time'}) -Status Success
        $sourceInventory=New-WsmInventory -Source ([pscustomobject][ordered]@{HostId=$host;Fingerprint=('a'*64);Name='fixture-source';OS='Windows Server';Version='Unknown'}) -Revision 1 -Items @($sourceItem)
        $item1=[pscustomobject][ordered]@{ItemId=(Get-WsmHashText ($host+'|Runtime|Service|svc'));Category='Runtime';Kind='Service';Name='Service name';NaturalKey='svc';SettingsHash=(Get-WsmHashText ('{}'));Status='Success';Present=$false;Decision='Exclude';Reason='owner pending';Owner='App owner';Mapping='C:\target';AccountMapping='DOMAIN\svc';EndpointMapping='';BuiltIn=$false;RuleId='fixture';Evidence='safe-evidence-reference';ConsistencyGroup='';ApplicationGroup='';Dependencies=@();Adapter='Manual';Settings=[pscustomobject]@{Password='item-secret';DSN='Data Source=X;Password=dsn-secret'};MigrationSpec=[pscustomobject]@{ConfigFiles=@([pscustomobject]@{ArtifactId='tns-one';RelativePath='network/admin/tnsnames.ora';SHA256=('d'*64);Length=120;Encoding='UTF-8';Sensitivity='Internal';Owner='Oracle owner';EvidencePointer='Evidence#/tns';OracleClient=$true;ConnectionString='full-connection-secret'})}}
        $item2=[pscustomobject][ordered]@{ItemId=$sourceItem.ItemId;Category='System';Kind='TimeZone';Name='TimeZone';NaturalKey='tz';SettingsHash=$sourceItem.SettingsHash;Status=$sourceItem.Status;Present=$true;Decision='Pending';Reason='Unknown';Owner='Platform owner';Mapping='';AccountMapping='';EndpointMapping='';BuiltIn=$false;RuleId='fixture';Evidence='safe-evidence-reference';ConsistencyGroup='';ApplicationGroup='';Dependencies=@();Adapter=$sourceItem.Adapter;Settings=$sourceItem.Settings}
        $catalog=[pscustomobject][ordered]@{SchemaVersion=2;ToolVersion=$script:ToolVersion;Kind='Catalog';PairId=$pair;BatchId=[Guid]::NewGuid().ToString('D');InventoryRevision=1;InventoryHash=('f'*64);DecisionRevision=2;Source=[pscustomobject]@{HostId=$host;Fingerprint=('a'*64);Name='fixture-source';OS='Windows Server';Build='Unknown'};TargetName='fixture-target';ImportedUtc=[DateTime]::UtcNow.ToString('o');Items=@($item1,$item2);Approval=$null;SoftwareCatalog=$software;GeneralHost=[pscustomobject][ordered]@{ScopeMode='GeneralHost';SoftwareCatalog=$software;SoftwareDecisions=@([pscustomobject]@{SoftwareId=$entries[0].SoftwareId;Disposition='Unknown';Owner='';Reason='';Evidence=''});Requirements=@([pscustomobject]@{RequirementId='req-one';Type='ExternalDependency';ProviderSoftwareId=$entries[0].SoftwareId;ProviderItemId='';ExternalId='oracle-client';ConsumerItemIds=@($item1.ItemId);Certainty='Candidate';RequiredPhase='CutoverReady';ExpectedVersion='Unknown';Architecture='Unknown';Context=[pscustomobject]@{RuntimeAccount='DOMAIN\svc';Password='dsn-secret';ConnectionString='full-connection-secret'};Owner='App owner';Decision='Pending';DecisionReason='Review';SourceProof=[pscustomobject]@{InventoryHash=('f'*64);Evidence='ticket'}});OrphanedRequirements=@();EvidenceReceipts=@([pscustomobject]@{ReceiptId=('1'*64);RequirementIds=@('req-one');Phase='PreparationReady';TargetFingerprint=('2'*64);Context=[pscustomobject]@{RuntimeAccount='DOMAIN\svc';Password='dsn-secret'};ObservedUtc=[DateTime]::UtcNow.ToString('o');ExpiresUtc=[DateTime]::UtcNow.AddDays(1).ToString('o');Result='Unknown';EvidenceKind='OwnerReadback';EvidencePathHash=('3'*64);ToolFingerprint=('4'*64);RequirementProjectionHash=('5'*64);Owner='App owner'})}}
        $external=$catalog.GeneralHost.Requirements[0];$external.ProviderSoftwareId='';$external | Add-Member NoteProperty DecisionEvidence '' -Force;$external.RequirementId=Get-WsmGeneralHostRequirementId $external
        $softwareDecision=$catalog.GeneralHost.SoftwareDecisions[0];$softwareDecision | Add-Member NoteProperty SoftwareHash (Get-WsmGeneralHostSoftwareFactsHash $entries[0]) -Force;$softwareDecision | Add-Member NoteProperty SourceHash $software.CatalogProjectionHash -Force;$softwareDecision.Owner='Application owner';$softwareDecision.Reason='Owner review remains pending';$softwareDecision.Evidence='evidence://software-review'
        $preparationEvidence=[pscustomobject][ordered]@{MediaReference='evidence://media/package-1';MediaSHA256=('6'*64);VerificationMethod='OwnerVerified';SignatureEvidence='evidence://manual-verification/ticket-1';VendorOSSupportReference='evidence://vendor/support-matrix';VendorSupportCheckedUtc=[DateTime]::UtcNow.ToString('o');LicenseReference='evidence://license/record-1';InstallOrder=[int]1;IsolationEvidenceSHA256=('7'*64);RestartStatus='NotRequired';SideEffectsReference='evidence://review/side-effects'}
        $preparationRequirement=[pscustomobject][ordered]@{RequirementId=('0'*64);Type='Preparation';ProviderSoftwareId=$entries[0].SoftwareId;ProviderItemId='';ExternalId='';ConsumerItemIds=@($item1.ItemId);Certainty='Required';RequiredPhase='PreparationReady';ExpectedVersion='1.0';Architecture='Unknown';Context=[pscustomobject]@{PreparationEvidence=$preparationEvidence};Owner='Runtime owner';SourceProof=[pscustomobject]@{InventoryHash=('f'*64);Evidence='owner fixture'};Decision='Pending';DecisionReason='';DecisionEvidence=''}
        $preparationRequirement.RequirementId=Get-WsmGeneralHostRequirementId $preparationRequirement
        $catalog.GeneralHost.Requirements=@($external,$preparationRequirement)
        $software.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $sourceInventory
        $software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software
        $catalog.GeneralHost | Add-Member NoteProperty SchemaVersion 1 -Force
        $catalog.GeneralHost | Add-Member NoteProperty SoftwareCatalogHash (Get-WsmHashText ($software | ConvertTo-Json -Depth 30 -Compress)) -Force
        $catalog.GeneralHost | Add-Member NoteProperty UpdatedUtc ([DateTime]::UtcNow.ToString('o')) -Force
        [pscustomobject]@{Catalog=$catalog;PairId=$pair;SoftwareIds=@($entries | ForEach-Object SoftwareId);HostId=$host}
    } $FixtureCount
    & $module { param($Catalog) $script:EnvironmentFixture=$Catalog } $fixture.Catalog
    $catalogScript=Get-Content -LiteralPath $catalogPath -Raw
    if([Text.Encoding]::UTF8.GetByteCount($catalogScript) -gt 128MB){throw 'Test fixture source unexpectedly exceeded the bounded JSON limit.'}

    $targetPath=Join-Path $testRoot 'target-observation.json'
    $target=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.3.0';Kind='TargetObservation';PairId=$fixture.PairId;InventoryRevision=1;DecisionRevision=2;TargetObservationRevision=1;TargetFingerprint=('9'*64);ObservedUtc=[DateTime]::UtcNow.ToString('o');Status='Observed'}
    [IO.File]::WriteAllText($targetPath,($target | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $targetHash=(Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $result=Invoke-EnvironmentModule $fixture.Catalog { param($Workspace,$PairId,$OutputDirectory) Export-WsmEnvironmentConfirmation -Workspace $Workspace -PairId $PairId -OutputDirectory $OutputDirectory -Phase Preparation -Context 'application-service' } @($workspace,$fixture.PairId,$output)
    if(-not $result.Registered -or $result.ProductionQualified -or $result.AuthoritativeDecisionInput){throw 'Confirmation incorrectly claims approval or failed to register immutable outputs.'}
    $json=Get-Content -LiteralPath $result.JsonPath -Raw | ConvertFrom-Json
    if($json.Projection.Counts.Software -ne $FixtureCount -or @($json.Projection.Software).Count -ne $FixtureCount){throw 'Full software rows were truncated from the JSON projection.'}
    if(@($json.Projection.Software | Where-Object ManualEntry).Count -ne 1){throw 'Owner-provided software entry was omitted.'}
    if(@($json.Projection.Items | Where-Object { -not $_.Present }).Count -ne 1){throw 'Retained deleted item was omitted.'}
    if(@($json.Projection.Coverage | Where-Object Status -EQ NotTested).Count -ne 1 -or @($json.Projection.Coverage | Where-Object Status -EQ PermissionDenied).Count -ne 1 -or @($json.Projection.Coverage | Where-Object Status -EQ NotInstalled).Count -ne 1){throw 'Coverage status distinctions were collapsed.'}
    if(@($json.Projection.Software | Where-Object { $_.Name -eq 'Same Name' }).Count -ne 5){throw 'Same-name versions, user SIDs and owner-provided rows were merged.'}
    if(@($json.Projection.Software | Where-Object Architecture -NE Unknown).Count -ne 0){throw 'Registry view was treated as proof of bitness.'}
    if($json.Projection.TargetDiff.ReadinessProof -or $json.Projection.ReadinessProjection.TargetObservationIsReadinessProof -or $json.Projection.ProductionQualified){throw 'Target metadata or report was treated as readiness proof.'}
    $preparationEvidenceRow=@($json.Projection.PreparationRequirements | Where-Object SoftwareId -CEQ $fixture.SoftwareIds[0] | Select-Object -First 1)
    if($preparationEvidenceRow.Count -ne 1 -or $preparationEvidenceRow[0].MediaSHA256 -cne ('6'*64) -or $preparationEvidenceRow[0].VerificationMethod -cne 'OwnerVerified' -or $preparationEvidenceRow[0].VendorOSSupportReference -cne 'evidence://vendor/support-matrix' -or $preparationEvidenceRow[0].InstallOrder -ne 1 -or $preparationEvidenceRow[0].RestartStatus -cne 'NotRequired' -or -not $preparationEvidenceRow[0].IsolationEvidenceSHA256){throw 'Typed PreparationEvidence was not projected into the full preparation checklist.'}
    $missingPreparationEvidence=@($json.Projection.PreparationRequirements | Where-Object { $_.SoftwareId -cne $fixture.SoftwareIds[0] } | Select-Object -First 1)
    if($missingPreparationEvidence.Count -ne 1 -or $missingPreparationEvidence[0].EvidenceStatus -notlike 'NotTested*' -or -not $missingPreparationEvidence[0].OwnerRequired -or $missingPreparationEvidence[0].VendorOSSupportStatus -ne 'NotTested'){throw 'Missing preparation owner evidence was not explicit and NotTested.'}
    $md=Get-Content -LiteralPath $result.Path -Raw -Encoding UTF8;$html=Get-Content -LiteralPath $result.HtmlPath -Raw;$txt=Get-Content -LiteralPath $result.TextPath -Raw;$csvRows=@(Import-Csv -LiteralPath $result.CsvPath)
    foreach($secret in @('item-secret','dsn-secret','full-connection-secret','command-secret')){foreach($content in @($md,$html,$txt,(Get-Content -LiteralPath $result.JsonPath -Raw),[IO.File]::ReadAllText($result.CsvPath))){if($content.Contains($secret)){throw ('Secret-bearing fixture value leaked into report: '+$secret)}}}
    foreach($notice in @('專業／環境軟體本體只列清單','環境設定檔另列搬移','ConfigFiles 不是封裝白名單','列出或核准不等於已還原','不提供整機／System State 復原')){if(-not $md.Contains($notice)){throw ('Generated Markdown omits required software/configuration support boundary: '+$notice)}}
    if($md -match '<script>|\]\(https://evil.invalid\)|\| `'){throw 'Markdown names can create executable markup or links.'}
    if($html -match '<script>alert\(1\)</script>|<img\b|<a\s+href="https://evil.invalid'){throw 'HTML report rendered untrusted names as active markup or links.'}
    if(@($csvRows | Where-Object Section -EQ Software).Count -ne $FixtureCount){throw 'CSV omitted or truncated software rows.'}
    $markdownSoftwareRows=@([regex]::Matches($md,'(?m)^\| sw-[a-f0-9]{32} \|'))
    $htmlCountPresent=$html -match ('Software \('+[regex]::Escape([string]$FixtureCount)+'\)')
    $markdownCountPresent=$md -match ('Software.{0,80}'+[regex]::Escape([string]$FixtureCount))
    if($markdownSoftwareRows.Count -ne $FixtureCount -or -not $htmlCountPresent -or -not $markdownCountPresent){throw ('Markdown rows='+$markdownSoftwareRows.Count+'; HTML section='+[bool]$htmlCountPresent+'; Markdown count='+[bool]$markdownCountPresent)}
    if($csvRows | Where-Object { $_.Section -eq 'Software' -and $_.Name -like '=HYPERLINK*' } | Where-Object { $_.Name -notlike "'*" }){throw 'CSV formula guard did not prefix a formula-like name.'}

    $smallCatalog=ConvertFrom-EnvironmentFixtureJson (ConvertTo-Json -InputObject $fixture.Catalog -Depth 45 -Compress)
    $smallCatalog.SoftwareCatalog.Entries=@($smallCatalog.SoftwareCatalog.Entries | Select-Object -First 1)
    $smallCatalog.SoftwareCatalog.PreparationRequirements=@($smallCatalog.SoftwareCatalog.PreparationRequirements | Where-Object SoftwareId -CEQ $smallCatalog.SoftwareCatalog.Entries[0].SoftwareId)
    $smallCatalog.SoftwareCatalog.CatalogProjectionHash=Get-EnvironmentSoftwareCatalogHash $smallCatalog.SoftwareCatalog
    $smallCatalog=Set-EnvironmentSoftwareBinding $smallCatalog
    $oldHash=(Get-FileHash -LiteralPath $result.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $target.TargetObservationRevision=2;$target.Status='Blocked';[IO.File]::WriteAllText($targetPath,($target | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)));$targetHash2=(Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $result2=Invoke-EnvironmentModule $smallCatalog { param($Workspace,$PairId,$OutputDirectory,$ObservationPath,$ObservationHash) Export-WsmEnvironmentConfirmation -Workspace $Workspace -PairId $PairId -OutputDirectory $OutputDirectory -Phase Preparation -TargetObservationPath $ObservationPath -TargetObservationHash $ObservationHash -Context 'application-service' } @($workspace,$fixture.PairId,$output,$targetPath,$targetHash2)
    if($result2.DocumentId -eq $result.DocumentId -or $result2.TargetObservationRevision -ne 2 -or (Get-FileHash -LiteralPath $result.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $oldHash){throw 'New target observation overwrote or mutated the previous immutable report.'}
    $refs=Invoke-EnvironmentModule $fixture.Catalog { param($Workspace,$PairId) Get-WsmEnvironmentConfirmationReferences -Workspace $Workspace -PairId $PairId } @($workspace,$fixture.PairId)
    if(@($refs.Documents).Count -ne 2 -or $refs.LatestDocumentId -cne $result2.DocumentId -or $refs.AuthoritativeApproval){throw 'Confirmation references did not append a non-authoritative latest locator.'}
    $target.TargetObservationRevision=3;$target.Status='Observed';[IO.File]::WriteAllText($targetPath,($target | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)));$observedHash=(Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $actualReadiness=Invoke-EnvironmentModule $smallCatalog { param($Catalog,$TargetFingerprint) Get-WsmGeneralHostReadinessProjection $Catalog $TargetFingerprint 'application-service' '' @() } @($smallCatalog,$target.TargetFingerprint)
    if(@($actualReadiness.Phases).Count -lt 5 -or $actualReadiness.ProductionVerified){throw 'Actual GeneralHost readiness fixture is incomplete or claims production qualification.'}
    $observedResult=Invoke-EnvironmentModule $smallCatalog { param($Workspace,$PairId,$OutputDirectory,$ObservationPath,$ObservationHash) Export-WsmEnvironmentConfirmation -Workspace $Workspace -PairId $PairId -OutputDirectory $OutputDirectory -Phase Preparation -TargetObservationPath $ObservationPath -TargetObservationHash $ObservationHash -Context 'application-service' } @($workspace,$fixture.PairId,$output,$targetPath,$observedHash)
    $observedJson=Get-Content -LiteralPath $observedResult.JsonPath -Raw | ConvertFrom-Json
    $readinessProjection=$observedJson.Projection.ReadinessProjection;$readinessProofProperty=$readinessProjection.PSObject.Properties['TargetObservationIsReadinessProof'];$productionProperty=$readinessProjection.PSObject.Properties['ProductionVerified'];$phaseProperty=$readinessProjection.PSObject.Properties['Phases']
    if(($readinessProofProperty -and $readinessProofProperty.Value) -or ($productionProperty -and $productionProperty.Value) -or -not $phaseProperty -or @($phaseProperty.Value).Count -lt 5){throw ('Observed target metadata bypassed actual readiness projection or was treated as proof; status='+$readinessProjection.Status+'; error='+$readinessProjection.ErrorKind+'; phases='+$(if($phaseProperty){@($phaseProperty.Value).Count}else{0}))}
    $rejected=$false;$target.Status='Ready';[IO.File]::WriteAllText($targetPath,($target | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)));$wrongHash=(Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant();try{Invoke-EnvironmentModule $fixture.Catalog { param($Workspace,$PairId,$OutputDirectory,$ObservationPath,$ObservationHash) Export-WsmEnvironmentConfirmation $Workspace $PairId $OutputDirectory -TargetObservationPath $ObservationPath -TargetObservationHash $ObservationHash | Out-Null } @($workspace,$fixture.PairId,$output,$targetPath,$wrongHash)}catch{$rejected=$true};if(-not $rejected){throw 'Unsupported target PASS status was accepted.'}
    $rejected=$false;try{Invoke-EnvironmentModule $fixture.Catalog { param($Workspace,$PairId,$OutputDirectory,$ObservationPath) Export-WsmEnvironmentConfirmation $Workspace $PairId $OutputDirectory -TargetObservationPath $ObservationPath -TargetObservationHash ('0'*64) | Out-Null } @($workspace,$fixture.PairId,$output,$targetPath)}catch{$rejected=$true};if(-not $rejected){throw 'Wrong target observation hash was accepted.'}

    $missingCatalog=ConvertFrom-EnvironmentFixtureJson (ConvertTo-Json -InputObject $fixture.Catalog -Depth 45 -Compress)
    $missing=Invoke-EnvironmentModule $missingCatalog { param($Catalog) $Catalog.SoftwareCatalog=$null;$Catalog.GeneralHost.SoftwareCatalog=$null;Get-WsmEnvironmentConfirmationProjection -Catalog $Catalog } @($missingCatalog)
    if(@($missing.Coverage | Where-Object ErrorKind -EQ SourceSoftwareCaptureMissing).Count -ne 1 -or $missing.Coverage[0].Status -ne 'NotTested'){throw 'Missing source software capture did not create an explicit coverage gap.'}

    $reportCatalog=ConvertFrom-EnvironmentFixtureJson (ConvertTo-Json -InputObject $fixture.Catalog -Depth 45 -Compress)
    $reportCatalog.SoftwareCatalog.Entries=@($reportCatalog.SoftwareCatalog.Entries | Where-Object Name -Like '=HYPERLINK*' | Select-Object -First 1)
    $reportCatalog.SoftwareCatalog.PreparationRequirements=@($reportCatalog.SoftwareCatalog.PreparationRequirements | Where-Object SoftwareId -CEQ $reportCatalog.SoftwareCatalog.Entries[0].SoftwareId)
    $reportCatalog.SoftwareCatalog.CatalogProjectionHash=Get-EnvironmentSoftwareCatalogHash $reportCatalog.SoftwareCatalog
    $reportCatalog=Set-EnvironmentSoftwareBinding $reportCatalog
    $genericReport=Join-Path $testRoot 'catalog-report.html'
    $reportResult=Invoke-EnvironmentModule $reportCatalog { param($Workspace,$PairId,$Path) Export-WsmReport -Workspace $Workspace -PairId $PairId -Path $Path } @($workspace,$fixture.PairId,$genericReport)
    $reportJson=Get-Content -LiteralPath $reportResult.JsonPath -Raw | ConvertFrom-Json
    $reportCsv=@(Import-Csv -LiteralPath $reportResult.CsvPath)
    $reportJsonSoftwareCount=@($reportJson.Software).Count;$reportCsvSoftwareCount=@($reportCsv | Where-Object Section -EQ Software).Count;$reportResultSoftwareCount=[int]$reportResult.Counts.Software
    if($reportJsonSoftwareCount -ne 1 -or $reportCsvSoftwareCount -ne 1 -or $reportResultSoftwareCount -ne 1){throw ('Catalog report software counts differ: JSON='+$reportJsonSoftwareCount+' CSV='+$reportCsvSoftwareCount+' result='+$reportResultSoftwareCount)}
    if(@($reportJson.Requirements).Count -ne 2 -or @($reportJson.EvidenceReceipts).Count -ne 1){throw 'Generic catalog report omitted GeneralHost requirements or receipts.'}
    if($reportCsv | Where-Object { $_.Section -eq 'Software' -and $_.Name -like '=HYPERLINK*' } | Where-Object { $_.Name -notlike "'*" }){throw 'Generic catalog CSV formula guard did not prefix a formula-like name.'}
    foreach($secret in @('item-secret','dsn-secret','full-connection-secret','command-secret')){foreach($content in @((Get-Content -LiteralPath $reportResult.HtmlPath -Raw),(Get-Content -LiteralPath $reportResult.TextPath -Raw),(Get-Content -LiteralPath $reportResult.JsonPath -Raw),[IO.File]::ReadAllText($reportResult.CsvPath))){if($content.Contains($secret)){throw ('Generic catalog report leaked a secret-bearing fixture value: '+$secret)}}}
    if((Get-Content -LiteralPath ($genericReport+'.txt') -Raw) -notmatch 'Readiness' -or (Get-Content -LiteralPath $genericReport -Raw) -notmatch 'chunk-0'){throw 'Catalog reports omit GeneralHost coverage/readiness or software rows.'}

    Write-Host ('PASS: Environment confirmation is complete, immutable, safely rendered and count-consistent for '+$FixtureCount+' software rows.')
} finally {
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    foreach($file in Get-ChildItem -LiteralPath $snapshot -File -ErrorAction SilentlyContinue){if($snapshotHashes.ContainsKey($file.Name) -and (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $snapshotHashes[$file.Name]){throw ('Fixed test snapshot changed during tests: '+$file.Name)}}
    $resolved=[IO.Path]::GetFullPath($testRoot);if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('wsm-environment-confirmation-')){throw 'Refusing cleanup outside the uniquely named test-owned temporary directory.'};Remove-Item -LiteralPath $resolved -Recurse -Force
}
