#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$testModule=Get-Module WindowsServerMigration
$reportPath=Join-Path $PSScriptRoot '..\src\AssistiveReports.ps1'
function Invoke-TestAssistiveReport([string]$Workspace,[string]$PairId,[string]$OutputDirectory){& $testModule {param($Path,$Workspace,$PairId,$OutputDirectory) . $Path;Export-WsmAssistiveReport -Workspace $Workspace -PairId $PairId -OutputDirectory $OutputDirectory} $reportPath $Workspace $PairId $OutputDirectory}
function Test-TestAssistiveReport([string]$ManifestPath,[string]$ExpectedHash){& $testModule {param($Path,$ManifestPath,$ExpectedHash) . $Path;Test-WsmAssistiveReport -ManifestPath $ManifestPath -ExpectedHash $ExpectedHash} $reportPath $ManifestPath $ExpectedHash}
function Get-TestAssistiveReportCounts($Catalog,$StageProjection){& $testModule {param($Path,$Catalog,$StageProjection) . $Path;Get-WsmAssistiveReportCountRows $Catalog $StageProjection @()} $reportPath $Catalog $StageProjection}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-assistive-report-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};Check $rejected $Message}
function SaveJson($Data,[string]$Path){[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)));$Path}
function Get-TestCatalogPath([string]$Workspace,[string]$PairId){& $testModule {param($Workspace,$PairId) Get-WsmCatalogPath $Workspace $PairId} $Workspace $PairId}
try {
    $workspace=Join-Path $root 'manager';Initialize-WsmWorkspace $workspace | Out-Null
    $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='source <script>alert(1)</script>'}
    $item=New-WsmItem $source.HostId Web IISSite 'Site <img src=x onerror=alert(2)>' 'fixture-site' @{Xml='<site password="do-not-display">xml-secret-sentinel</site>';PhysicalPath='C:\old\<img src=x>'}
    $inventory=New-WsmInventory $source 1 @($item)
    $inventoryPath=Join-Path $root 'source.json';SaveJson $inventory $inventoryPath | Out-Null
    $inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=Import-WsmInventory $workspace $inventoryPath $inventoryHash 'target <b>name</b>'
    $catalog=Enable-WsmAssistiveMode $workspace $catalog.PairId $catalog.DecisionRevision
    $catalog=Set-WsmDecision $workspace $catalog.PairId @($item.ItemId) Include 'fixture reviewed' $catalog.DecisionRevision
    $catalog=Get-WsmCatalog $workspace $catalog.PairId
    $planHash='b'*64;$manifestHash='c'*64;$targetId=[Guid]::NewGuid().ToString();$targetFingerprint='d'*64;$generation=1
    $catalog.Approval=[pscustomobject]@{Kind='MigrationPlan';ApprovalId=[Guid]::NewGuid().ToString();Hash=$planHash;Utc=[DateTime]::UtcNow.ToString('o');TargetHostId=$targetId;TargetFingerprint=$targetFingerprint}
    SaveJson $catalog (Get-TestCatalogPath $workspace $catalog.PairId) | Out-Null
    $catalog=Get-WsmCatalog $workspace $catalog.PairId
    $fileResults=New-Object 'System.Collections.Generic.List[object]'
    for($i=0;$i -lt 2501;$i++){
        $fileStatus='Applied';$effective=('D:\apps\fixture\file-{0:D4}.bin' -f $i);$existing='';$existingHash='';$reason='Verified target placement.'
        if($i -eq 0){$fileStatus='BlockedConflict';$effective='';$existing='D:\apps\fixture\file-0000.bin';$existingHash='f'*64;$reason='Existing target differs; owner review required.'}
        $fileResults.Add([pscustomobject][ordered]@{ItemId=$item.ItemId;EntryId='';RelativePath=('folder/file-{0:D4}.bin' -f $i);Channel='C';OriginalPath=('C:\apps\fixture\file-{0:D4}.bin' -f $i);PreservedPath=('D:\apps\fixture\file-{0:D4}.bin' -f $i);EffectivePath=$effective;Status=$fileStatus;ExistingTargetPath=$existing;ExistingTargetHash=$existingHash;ObservedHash=$(if($i -eq 0){''}else{'a'*64});SourceHash=('a'*64);Reason=$reason;Generation=$generation;ProjectedGeneration=$generation})
    }
    $stage=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='StageResult';BatchId=$catalog.BatchId;PairId=$catalog.PairId;SourceHostId=$catalog.Source.HostId;TargetHostId=$targetId;TargetFingerprint=$targetFingerprint;InventoryRevision=$catalog.InventoryRevision;DecisionRevision=$catalog.DecisionRevision;RunId=[Guid]::NewGuid().ToString();Sequence=1;Stage='Restore';Status='Succeeded';ProducedUtc=[DateTime]::UtcNow.ToString('o');Mode='IsolatedPilot';ProductionVerified=$false;ApprovalId=$catalog.Approval.ApprovalId;PlanHash=$planHash;ManifestHash=$manifestHash;PayloadGeneration=$generation;JournalHash=('e'*64);Assistive=[pscustomobject][ordered]@{ApprovedItemIds=@($item.ItemId);ItemResults=@([pscustomobject]@{ItemId=$item.ItemId;Decision='Include';Status='Succeeded';AppliedManifestHash=$manifestHash;AppliedGeneration=$generation;Pending=$false;Deferred=$false});AppliedItemIds=@($item.ItemId);PendingItemIds=@();DeferredItemIds=@();FileResults=$fileResults.ToArray()}}
    $stagePath=Join-Path $root 'stage-result.json';SaveJson $stage $stagePath | Out-Null;Import-WsmStageResult $workspace $stagePath (Get-FileHash -LiteralPath $stagePath -Algorithm SHA256).Hash | Out-Null
    $catalog=Get-WsmCatalog $workspace $catalog.PairId
    $output=Join-Path $root 'bundle-output'
    $result=Invoke-TestAssistiveReport $workspace $catalog.PairId $output
    Check (Test-Path -LiteralPath $result.ReportPath -PathType Leaf) 'Report HTML was not created.'
    Check ($result.ProductionVerified -eq $false -and $result.BusinessValidationStatus -eq 'NotTested' -and $result.TransferStatus -like 'Restore: Succeeded*' -and $result.QualificationStatus -eq 'NotTested') 'Report overstated an execution, transfer, or acceptance gate.'
    $reference=Get-Content -LiteralPath (Join-Path $result.EvidenceDirectory ($inventoryHash+'.reference.json')) -Raw | ConvertFrom-Json;Check ($reference.OriginalSHA256 -ceq $inventoryHash -and $reference.OriginalBytesIncluded -eq $false -and $reference.ImportAuthority -eq $false -and -not $reference.PSObject.Properties['SourcePath']) 'Portable source reference did not retain only safe verified authority metadata.'
    $allDownloads=@(Get-ChildItem -LiteralPath $result.BundlePath -File -Recurse | ForEach-Object {[IO.File]::ReadAllText($_.FullName)}) -join '';Check (-not $allDownloads.Contains('xml-secret-sentinel') -and -not $allDownloads.Contains('do-not-display')) 'Document downloads leaked original configuration content.'
    Check ($result.DocumentManifestPath -and $result.DocumentManifestHash -match '^[a-f0-9]{64}$' -and $result.BundleName -eq [IO.Path]::GetFileName($result.BundlePath)) 'Export did not return its bundle and independently checkable document-manifest identity.'
    $docCheck=Test-TestAssistiveReport $result.DocumentManifestPath $result.DocumentManifestHash
    Check ($docCheck.Valid -and $docCheck.MemberCount -eq $result.DocumentMemberCount -and $docCheck.ImportAuthority -eq $false -and $docCheck.RestoreAuthority -eq $false) 'Native document consumer did not verify the complete safe projection.'
    $docManifest=Get-Content -LiteralPath $result.DocumentManifestPath -Raw | ConvertFrom-Json
    Check ($docManifest.PairId -ceq $catalog.PairId -and $docManifest.CatalogHash -ceq $result.CatalogHash -and $docManifest.SourceSnapshotHash -ceq $inventoryHash -and $docManifest.SelectionRevision -eq $catalog.Assistive.Selections.Revision) 'Document manifest omitted pair, catalog/source hash, or assistive selection revisions.'
    $evidenceMember=@($docManifest.Members | Where-Object {$_.Path -like 'evidence/*' -and $_.OriginalSHA256 -ceq $inventoryHash})[0]
    Check ($evidenceMember -and $evidenceMember.ProjectionSHA256 -ceq (Get-FileHash -LiteralPath (Join-Path $result.BundlePath $evidenceMember.Path.Replace('/','\')) -Algorithm SHA256).Hash.ToLowerInvariant()) 'Document manifest did not distinguish original authority hash from exact metadata projection bytes.'
    $html=[IO.File]::ReadAllText($result.ReportPath)
    Check ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;') -and -not $html.Contains('<script>alert(1)</script>')) 'Malicious inventory text was not HTML-encoded.'
    Check (-not $html.Contains('xml-secret-sentinel') -and -not $html.Contains('do-not-display')) 'Raw configuration XML or a secret value was displayed in HTML.'
    Check ($html.Contains('folder/file-0000.bin') -and $html.Contains('folder/file-1250.bin') -and $html.Contains('folder/file-2500.bin')) 'The complete per-file report omitted boundary or middle rows.'
    $fileSection=[regex]::Match($html,'(?s)<section><h2>Complete per-file C / Non-C result and placement evidence</h2>.*?</section>')
    Check ($fileSection.Success -and [regex]::Matches($fileSection.Value,'<tr>').Count -eq 2502) 'The per-file report truncated or lost one or more of 2,501 accepted result rows.'
    Check ($fileSection.Value.Contains('BlockedConflict') -and $fileSection.Value.Contains('Existing target differs; owner review required.') -and $fileSection.Value.Contains('D:\apps\fixture\file-0000.bin')) 'The per-file report omitted conflict state, target path, or uncertainty reason.'
    Check ($html.Contains('Discovery, selection and execution denominators') -and $html.Contains('Currently selected and source-approved Includes') -and $html.Contains('No combined completion percentage')) 'Report omitted separated discovery/selection/approval denominators or introduced a combined percentage.'
    Check ($html.Contains('Accepted file rows') -and $html.Contains('Availability') -and $html.Contains('NotTested')) 'Report omitted accepted file-row counts or falsely implied availability was tested.'
    Check ($html.Contains('FirstObserved only when recorded') -and $html.Contains('No result references are imported') -and $html.Contains('Stage result item vector')) 'Report did not distinguish absent evidence from an assumed clean target or show the accepted per-item result.'
    Check ($html.Contains($inventoryHash) -and $html.Contains('Immutable source inventory')) 'Portable report did not index its immutable source snapshot.'

    # A compact management scenario exercises mixed channels, an unselected exclusion,
    # selected ManualWorkflow work, pending/deferred statuses, and a truthful zero-file result.
    $manualId='1'*64;$unselectedId='2'*64;$nonCId='3'*64
    $scenarioItems=@(
        [pscustomobject]@{ItemId=$item.ItemId;Decision='Include';Status='Success';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C'}},
        [pscustomobject]@{ItemId=$manualId;Decision='Include';Status='Success';MigrationSpec=[pscustomobject]@{Adapter='ManualWorkflow'}},
        [pscustomobject]@{ItemId=$unselectedId;Decision='Exclude';Status='Unsupported';MigrationSpec=$null},
        [pscustomobject]@{ItemId=$nonCId;Decision='Exclude';Status='Success';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='NonC'}}
    )
    $scenarioSelection=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=$item.ItemId;Selected=$true},[pscustomobject]@{ItemId=$manualId;Selected=$true},[pscustomobject]@{ItemId=$unselectedId;Selected=$false},[pscustomobject]@{ItemId=$nonCId;Selected=$false})}
    $scenarioCatalog=[pscustomobject]@{Items=$scenarioItems;Approval=$null;Assistive=[pscustomobject]@{Selections=$scenarioSelection}}
    $scenarioStage=[pscustomobject]@{Latest=[pscustomobject]@{Assistive=[pscustomobject]@{ItemResults=@([pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';Pending=$false;Deferred=$false},[pscustomobject]@{ItemId=$manualId;Status='ManualEvidenceRequired';Pending=$true;Deferred=$true});FileResults=@()}}}
    $scenario=Get-TestAssistiveReportCounts $scenarioCatalog $scenarioStage
    Check ($scenario.Totals.Discovered -eq 4 -and $scenario.Totals.Selected -eq 2 -and $scenario.Totals.ApprovedSelected -eq 2 -and $scenario.Totals.Excluded -eq 2 -and $scenario.Totals.Unsupported -eq 1) 'Management scenario denominators did not separate discovered, selected, approved, excluded, and unsupported items.'
    Check ($scenario.Totals.AcceptedStageObjects -eq 2 -and $scenario.Totals.ManualPending -eq 1 -and $scenario.Totals.Pending -eq 1 -and $scenario.Totals.Deferred -eq 1 -and $scenario.Totals.Availability -ceq 'NotTested') 'Management scenario lost selected ManualWorkflow, pending/deferred, or availability state.'
    $zeroC=@($scenario.Rows | Where-Object {$_[0] -ceq 'Accepted execution results' -and $_[1] -ceq 'C'})[0]
    $zeroNonC=@($scenario.Rows | Where-Object {$_[0] -ceq 'Accepted execution results' -and $_[1] -ceq 'NonC'})[0]
    Check ($zeroC[10] -eq 0 -and $zeroNonC[10] -eq 0 -and $scenario.Totals.FileExpansion -like 'Accepted FileResults rows only*') 'Explicit accepted empty file results were not reported as zero rows with a bounded denominator.'
    $unknownStage=[pscustomobject]@{Latest=[pscustomobject]@{Assistive=[pscustomobject]@{}}}
    $unknownCounts=Get-TestAssistiveReportCounts $scenarioCatalog $unknownStage
    Check ($unknownCounts.Totals.FileExpansion -like 'Unknown:*' -and (@($unknownCounts.Rows | Where-Object {$_[0] -ceq 'Accepted execution results'} | Where-Object {$_[10] -ceq 'Unknown'}).Count -eq 2)) 'Missing file expansion was silently counted as zero instead of Unknown.'
    Check ($unknownCounts.Totals.Pending -ceq 'Unknown' -and $unknownCounts.Totals.Deferred -ceq 'Unknown' -and $unknownCounts.Totals.OwnershipConflicts -ceq 'Unknown') 'Missing accepted execution vectors were falsely reported as zero pending, deferred, or ownership-conflict results.'
    $evidenceLinks=[regex]::Matches($html,'(?:href|src)="(evidence/[^"]+)"')
    foreach($match in $evidenceLinks){Check (Test-Path -LiteralPath (Join-Path (Split-Path $result.ReportPath -Parent) $match.Groups[1].Value.Replace('/','\')) -PathType Leaf) 'A portable evidence link is broken.'}
    $moved=Join-Path $root 'moved-bundle';[IO.Directory]::Move((Split-Path $result.ReportPath -Parent),$moved)
    $movedManifest=Join-Path $moved 'document-manifest.json';$movedCheck=Test-TestAssistiveReport $movedManifest $result.DocumentManifestHash
    Check ($movedCheck.Valid -and $movedCheck.DocumentId -ceq $result.DocumentId) 'Document consumer depended on the original export directory after moving the bundle.'
    $movedHtml=Join-Path $moved 'index.html';$movedContent=[IO.File]::ReadAllText($movedHtml)
    $movedLinks=[regex]::Matches($movedContent,'(?:href|src)="(evidence/[^"]+)"')
    foreach($match in $movedLinks){Check (Test-Path -LiteralPath (Join-Path $moved $match.Groups[1].Value.Replace('/','\')) -PathType Leaf) 'Evidence links did not remain valid after moving the report bundle.'}
    [IO.File]::Move($movedHtml,($movedHtml+'.missing'));Reject { Test-TestAssistiveReport $movedManifest $result.DocumentManifestHash } 'Document consumer accepted a missing HTML page.';[IO.File]::Move(($movedHtml+'.missing'),$movedHtml)
    $mutableRef=Join-Path (Join-Path $moved 'evidence') ($inventoryHash+'.reference.json');$refBytes=[IO.File]::ReadAllBytes($mutableRef);[IO.File]::AppendAllText($mutableRef,' ');Reject { Test-TestAssistiveReport $movedManifest $result.DocumentManifestHash } 'Document consumer accepted changed evidence metadata bytes.';[IO.File]::WriteAllBytes($mutableRef,$refBytes)
    $savedHtml=[IO.File]::ReadAllBytes($movedHtml);[IO.File]::AppendAllText($movedHtml,'tampered');Reject { Test-TestAssistiveReport $movedManifest $result.DocumentManifestHash } 'Document consumer accepted a tampered report page.';[IO.File]::WriteAllBytes($movedHtml,$savedHtml)
    $duplicate=$docManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json;$duplicate.Members=@($duplicate.Members)+@($duplicate.Members[0]);$duplicatePath=Join-Path $moved 'duplicate-manifest.json';SaveJson $duplicate $duplicatePath | Out-Null;$duplicateHash=(Get-FileHash -LiteralPath $duplicatePath -Algorithm SHA256).Hash.ToLowerInvariant();Reject { Test-TestAssistiveReport $duplicatePath $duplicateHash } 'Document consumer accepted duplicate manifest member paths.'
    $unsafe=$docManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json;$unsafe.Members[0].Path='../outside.json';$unsafePath=Join-Path $moved 'unsafe-manifest.json';SaveJson $unsafe $unsafePath | Out-Null;$unsafeHash=(Get-FileHash -LiteralPath $unsafePath -Algorithm SHA256).Hash.ToLowerInvariant();Reject { Test-TestAssistiveReport $unsafePath $unsafeHash } 'Document consumer accepted a traversal member path.'
    $oversized=$docManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json;$oversized.Members[0].Bytes=67108865;$oversizedPath=Join-Path $moved 'oversized-manifest.json';SaveJson $oversized $oversizedPath | Out-Null;$oversizedHash=(Get-FileHash -LiteralPath $oversizedPath -Algorithm SHA256).Hash.ToLowerInvariant();Reject { Test-TestAssistiveReport $oversizedPath $oversizedHash } 'Document consumer accepted a member beyond the 64 MiB bound.'
    $extra=Join-Path $moved 'unlisted.txt';[IO.File]::WriteAllText($extra,'unlisted');Reject { Test-TestAssistiveReport $movedManifest $result.DocumentManifestHash } 'Document consumer accepted an unmanifested bundle member.';Remove-Item -LiteralPath $extra -Force
    Reject { Test-TestAssistiveReport $movedManifest ('0'*64) } 'Document consumer accepted a changed or untrusted manifest hash.'
    $sourceCopy=Join-Path $workspace ('assistive\snapshots\'+$inventoryHash+'.json')
    [IO.File]::AppendAllText($sourceCopy,'tampered')
    $before=@(Get-ChildItem -LiteralPath $output -Directory).Count
    Reject { Invoke-TestAssistiveReport $workspace $catalog.PairId $output } 'Tampered source evidence was accepted for report export.'
    Check (@(Get-ChildItem -LiteralPath $output -Directory).Count -eq $before) 'Failed tampered-reference export left a partial report bundle.'
    [IO.File]::Copy($inventoryPath,$sourceCopy,$true);Remove-Item -LiteralPath $sourceCopy -Force
    Reject { Invoke-TestAssistiveReport $workspace $catalog.PairId $output } 'Missing source evidence was accepted for report export.'
    Check (@(Get-ChildItem -LiteralPath $output -Directory).Count -eq $before) 'Failed missing-reference export left a partial report bundle.'
    Write-Host ('PASS: '+$passed+' Assistive report checks.')
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
