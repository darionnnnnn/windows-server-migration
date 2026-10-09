#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
. (Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-config-workflow-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$draftWorkspace=Join-Path ([IO.Path]::GetTempPath()) ('wsm-config-draft-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($draftWorkspace)
function Assert-ConfigWorkflow([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Get-ConfigWorkflowHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Write-ConfigWorkflowIndex([string]$Path,[object[]]$Rows){$writer=New-Object IO.StreamWriter($Path,$false,(New-Object Text.UTF8Encoding($false)));try{foreach($row in $Rows){$writer.WriteLine((ConvertTo-Json -InputObject $row -Depth 30 -Compress))}}finally{$writer.Dispose()};Get-ConfigWorkflowHash $Path}
function New-ConfigWorkflowTamperedPackage($SourcePackage,[string]$Destination,[string]$Change){
    Copy-Item -LiteralPath $SourcePackage.Directory -Destination $Destination -Recurse
    $indexPath=Join-Path $Destination 'artifacts.jsonl';$rows=@(Get-Content -LiteralPath $indexPath | ForEach-Object {ConvertFrom-Json $_});$manifestPath=Join-Path $Destination 'manifest.json';$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    switch($Change){
        'Modified' {
            $row=@($rows | Where-Object {$_.RelativePath -ceq 'web.config'})[0];$bytes=[Text.Encoding]::UTF8.GetBytes('approved-config-v2');$hash=[BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes)).Replace('-','').ToLowerInvariant();$blob=Join-Path (Join-Path $Destination 'payload') ($hash+'.blob');[IO.File]::WriteAllBytes($blob,$bytes);$row.Data.Bytes=$bytes.Length;$row.Data.Hash=$hash;$row.Data.Chunks=@([pscustomobject]@{Hash=$hash;Bytes=$bytes.Length})
        }
        'Added' {
            $template=@($rows | Where-Object {$_.RelativePath -ceq 'web.config'})[0];$bytes=[Text.Encoding]::UTF8.GetBytes('new-config-v1');$hash=[BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($bytes)).Replace('-','').ToLowerInvariant();$blob=Join-Path (Join-Path $Destination 'payload') ($hash+'.blob');[IO.File]::WriteAllBytes($blob,$bytes);$newRow=ConvertFrom-Json ($template | ConvertTo-Json -Depth 30 -Compress);$newRow.RelativePath='appsettings.new.json';$newRow.Data.Bytes=$bytes.Length;$newRow.Data.Hash=$hash;$newRow.Data.Chunks=@([pscustomobject]@{Hash=$hash;Bytes=$bytes.Length});$rows+=@($newRow);$manifest.Files++;$manifest.Bytes+=$bytes.Length;$manifest.Records++
        }
        'Deleted' {
            $deleted=@($rows | Where-Object {$_.RelativePath -ceq 'web.config'})[0];$rows=@($rows | Where-Object {$_.RelativePath -cne 'web.config'});$manifest.Files--;$manifest.Bytes-=[long]$deleted.Data.Bytes;$manifest.Records--
        }
        default {throw 'Unknown configuration drift fixture.'}
    }
    $manifest.ArtifactsHash=Write-ConfigWorkflowIndex $indexPath $rows
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{ManifestPath=$manifestPath;ManifestHash=(Get-ConfigWorkflowHash $manifestPath);IndexPath=$indexPath;Directory=$Destination}
}
try {
    $sourceRoot=Join-Path $root 'source';[void][IO.Directory]::CreateDirectory($sourceRoot)
    $configPath=Join-Path $sourceRoot 'web.config';$businessPath=Join-Path $sourceRoot 'business.dat'
    [IO.File]::WriteAllText($configPath,'approved-config-v1',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($businessPath,'business-data-v1',(New-Object Text.UTF8Encoding($false)))
    # Persist runner-specific ACL control bits on test-owned paths before exact package capture.
    foreach($fixturePath in @($sourceRoot,$configPath,$businessPath)){$fixtureAcl=Get-Acl -LiteralPath $fixturePath;Set-Acl -LiteralPath $fixturePath -AclObject $fixtureAcl}
    $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source';OS='Fixture Server';Version='10.0.fixture'}
    $item=New-WsmItem $source.HostId Storage DataRoot 'Fixture data scope' 'fixture-config-scope' @{Path=$sourceRoot}
    $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $root 'inventory.json';[IO.File]::WriteAllText($inventoryPath,($inventory | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
    $workspace=Join-Path $root 'manager';$sourceState=Join-Path $root 'source-state';$targetState=Join-Path $root 'target-state';$targetIdentityPath=Join-Path $root 'target-identity.json';$planPath=Join-Path $root 'plan.json';$draftPath=Join-Path $draftWorkspace 'config-draft.jsonl'
    Initialize-WsmWorkspace $workspace | Out-Null
    $catalog=Import-WsmInventory $workspace $inventoryPath (Get-ConfigWorkflowHash $inventoryPath) 'fixture-target'
    # Mock only machine identity and the inventory collection boundary. File bytes,
    # ACL metadata, plan review, package sealing, package tests and delta consumers stay real.
    & $module {param($InventoryPath)$script:fixtureInventory=$InventoryPath;$script:fixtureFingerprint=('b'*64);function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture';OS='Fixture Server';Version='10.0.fixture';IsServer=$true;Administrator=$true;Is64Bit=$true}};function script:Export-WsmInventory {param($OutputDirectory,[switch]$DeepDiscovery)[pscustomobject]@{Path=$script:fixtureInventory;SHA256=(Get-FileHash -LiteralPath $script:fixtureInventory -Algorithm SHA256).Hash}}} $inventoryPath
    $scopeSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceRoot;ExcludedRelativePaths=@()};$scopeSpecPath=Join-Path $root 'scope-draft-spec.json';[IO.File]::WriteAllText($scopeSpecPath,($scopeSpec | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
    $draft=Export-WsmConfigArtifactScopeDraft -SpecPath $scopeSpecPath -ExpectedHash (Get-ConfigWorkflowHash $scopeSpecPath) -ItemId $item.ItemId -Path $draftPath
    $draftRows=@(Get-Content -LiteralPath $draftPath | ForEach-Object {ConvertFrom-Json $_})
    Assert-ConfigWorkflow ($draft.ReviewStatus -eq 'Draft' -and $draft.RequiresOwnerEvidenceReview -and $draftRows.Count -eq 1 -and $draftRows[0].RelativePath -ceq 'web.config') 'FileScope config draft did not discover the actual source config file for owner review.'
    $spec=[pscustomobject][ordered]@{Adapter='FileScope';SourcePath=$sourceRoot;TargetPath=(Join-Path $root 'target');ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='Fixture owner';Evidence='Fixture scope review';ConfigFiles=@([pscustomobject][ordered]@{RelativePath=$draftRows[0].RelativePath;SHA256=$draftRows[0].SHA256;Owner='Configuration owner';Evidence='Approved change CHG-CONFIG-1'});ConfigOverrides=@([pscustomobject][ordered]@{RelativePath='business.dat';Classification='BusinessData';Owner='Data owner';Evidence='Approved data review';Reason='Application data file is not configuration'})}
    $specPath=Join-Path $root 'reviewed-spec.json';[IO.File]::WriteAllText($specPath,($spec | ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
    Set-WsmMigrationSpec $workspace $catalog.PairId $item.ItemId $specPath (Get-ConfigWorkflowHash $specPath) 0
    Set-WsmDecision $workspace $catalog.PairId @($item.ItemId) Include 'Fixture scope approved' 1 | Out-Null
    $targetIdentity=Register-WsmTarget $targetState $targetIdentityPath
    $approval=Approve-WsmMigrationPlan $workspace $catalog.PairId $targetIdentityPath $targetIdentity.SHA256 $planPath 2 ISOLATED-PILOT
    Assert-ConfigWorkflow ($approval.Mode -ceq 'IsolatedPilot' -and (Test-Path -LiteralPath $planPath)) 'Actual migration plan approval API did not approve the reviewed config scope.'
    & $module {$script:fixtureFingerprint=('a'*64)}
    $base=Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState (Join-Path $root 'packages-base') -ChunkBytes 65536
    $baseVerified=Test-WsmMigrationPackage $base.ManifestPath $base.SHA256
    Assert-ConfigWorkflow ($base.Sealed -and $baseVerified.Valid -and $base.Generation -eq 1) 'Approved base package did not seal and validate through production consumers.'
    $review=Export-WsmConfigArtifactReview -PlanPath $planPath -ExpectedHash $approval.SHA256 -Path (Join-Path $root 'review\config-review.json')
    Assert-ConfigWorkflow (-not $review.RequiresReapproval) 'Actual source config review consumer rejected unchanged approved configuration.'
    & $module {$script:fixtureFingerprint=('b'*64)}
    Invoke-WsmRestore $base.ManifestPath $base.SHA256 $targetState | Out-Null
    $statePath=Join-Path (Join-Path $targetState $catalog.PairId) 'state.json';$stateHash=Get-ConfigWorkflowHash $statePath
    $lab=Export-WsmLabValidationReport -OutputDirectory (Join-Path $root 'lab-reports') -Role Target -ManifestPath $base.ManifestPath -ExpectedHash $base.SHA256 -StateDirectory $targetState
    Assert-ConfigWorkflow (@($lab.Report.Checks | Where-Object {$_.Code -ceq 'FileScopeExact' -and $_.Status -ceq 'PASS'}).Count -eq 1 -and $lab.ProductionVerified -eq $false) 'Real approved package, restored file scope and journal did not reach the public lab report consumer.'
    $lockPath=Join-Path (Split-Path -Parent $statePath) '.wsm.lock';$busyLock=[IO.File]::Open($lockPath,'Open','ReadWrite','None')
    try{$busyRejected=$false;$busyOutput=Join-Path $root 'lab-busy';try{Export-WsmLabValidationReport -OutputDirectory $busyOutput -Role Target -ManifestPath $base.ManifestPath -ExpectedHash $base.SHA256 -StateDirectory $targetState | Out-Null}catch{$busyRejected=$_.Exception.Message -match 'busy'};Assert-ConfigWorkflow ($busyRejected -and -not [IO.Directory]::Exists($busyOutput)) 'Lab report ran concurrently with a target operation or wrote a misleading checkpoint report.'}finally{$busyLock.Dispose()}
    $targetBusiness=Join-Path $spec.TargetPath 'business.dat';[IO.File]::AppendAllText($targetBusiness,'unapproved target drift')
    $driftLab=Export-WsmLabValidationReport -OutputDirectory (Join-Path $root 'lab-reports') -Role Target -ManifestPath $base.ManifestPath -ExpectedHash $base.SHA256 -StateDirectory $targetState
    Assert-ConfigWorkflow ($driftLab.Blocked -and @($driftLab.Report.Checks | Where-Object {$_.Code -ceq 'FileScopeExact' -and $_.Status -ceq 'FAIL'}).Count -eq 1 -and (Get-ConfigWorkflowHash $statePath) -ceq $stateHash) 'Lab readback failed to flag real target drift or modified the operation checkpoint.'
    & $module {$script:fixtureFingerprint=('a'*64)}
    foreach($headerCase in @('GenerationType','FinalType','HostId')){
        $badHeader=Get-Content -LiteralPath $base.ManifestPath -Raw | ConvertFrom-Json
        switch($headerCase){GenerationType {$badHeader.Generation='1'} FinalType {$badHeader.Final='false'} HostId {$badHeader.Source.HostId=[Guid]::NewGuid().ToString()}}
        $badPath=Join-Path $base.Directory ('bad-header-'+$headerCase+'.json');[IO.File]::WriteAllText($badPath,($badHeader | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
        $rejected=$false;try{Test-WsmMigrationPackage $badPath (Get-ConfigWorkflowHash $badPath) | Out-Null}catch{$rejected=$_.Exception.Message -match 'Package|package|binding|contract'}
        Assert-ConfigWorkflow $rejected ('Package consumer accepted malformed typed header/host identity: '+$headerCase)
    }
    $approvedPlan=& $module {param($Path,$Hash)Read-WsmMigrationPlan $Path $Hash} $planPath $approval.SHA256;$freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $approvedPlan -PlanHash $approval.SHA256 -Root $root -Owner 'Fixture source owner';$freezePath=Join-Path $root 'freeze.json';$freeze=Export-WsmFreezeRecord $planPath $approval.SHA256 $freezePath 'Fixture source owner' 'Fixture immutable source confirmed' OWNER-CONFIRMED-QUIESCENCE -SourceIdentityReleased -ReleaseEvidence 'Fixture source isolated' -SourceStateDirectory $sourceState -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -FreezeEpoch $freezeProof.FreezeEpoch
    $originalConfig=[IO.File]::ReadAllText($configPath);$originalBusiness=[IO.File]::ReadAllText($businessPath)
    foreach($case in @('Modified','Added','Deleted')){
        switch($case){
            'Modified' {[IO.File]::WriteAllText($configPath,'approved-config-v2',(New-Object Text.UTF8Encoding($false)))}
            'Added' {[IO.File]::WriteAllText((Join-Path $sourceRoot 'appsettings.new.json'),'new-config-v1',(New-Object Text.UTF8Encoding($false)))}
            'Deleted' {[IO.File]::Delete($configPath)}
        }
        $blocked=$false;$message='';try{Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState (Join-Path $root ('packages-'+$case)) -ChunkBytes 65536 -BaseManifestPath $base.ManifestPath -BaseManifestHash $base.SHA256 -FreezePath $freezePath -FreezeHash $freeze.SHA256 -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 | Out-Null}catch{$blocked=$true;$message=$_.Exception.Message}
        Assert-ConfigWorkflow ($blocked -and $message -match 'Configuration artifact') ('Source package export did not reject specifically the '+$case.ToLowerInvariant()+' configuration drift. '+$message)
        Assert-ConfigWorkflow (@(Get-ChildItem -LiteralPath (Join-Path $root ('packages-'+$case)) -Recurse -Filter manifest.json -ErrorAction SilentlyContinue).Count -eq 0) 'A configuration-rejected package retained a sealed manifest.'
        if($case -eq 'Modified' -or $case -eq 'Deleted'){[IO.File]::WriteAllText($configPath,$originalConfig,(New-Object Text.UTF8Encoding($false)))}
        if($case -eq 'Added'){[IO.File]::Delete((Join-Path $sourceRoot 'appsettings.new.json'))}
    }
    [IO.File]::WriteAllText($businessPath,'business-data-v2',(New-Object Text.UTF8Encoding($false)))
    $businessFinal=Export-WsmMigrationPackage $planPath $approval.SHA256 $sourceState (Join-Path $root 'packages-business-final') -ChunkBytes 65536 -BaseManifestPath $base.ManifestPath -BaseManifestHash $base.SHA256 -FreezePath $freezePath -FreezeHash $freeze.SHA256 -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256
    $businessVerified=Test-WsmMigrationPackage $businessFinal.ManifestPath $businessFinal.SHA256
    Assert-ConfigWorkflow ($businessFinal.Sealed -and $businessVerified.Valid -and $businessFinal.Final -and $businessFinal.Generation -eq 2) 'Ordinary business data byte changes did not pass actual final package export and validation.'
    $changePath=Join-Path $root 'business-changes.jsonl';$summaryPath=Join-Path $root 'business-delta.json'
    $businessDelta=New-WsmArtifactDeltaManifest -BaseManifestPath $base.ManifestPath -BaseManifestHash $base.SHA256 -BasePlanPath $planPath -BasePlanHash $approval.SHA256 -CurrentManifestPath $businessFinal.ManifestPath -CurrentManifestHash $businessFinal.SHA256 -CurrentPlanPath $planPath -CurrentPlanHash $approval.SHA256 -OutputPath $changePath -SummaryPath $summaryPath -OwnedItemIds @($item.ItemId)
    Assert-ConfigWorkflow ($businessDelta.Valid -and $businessDelta.Counts.Modified -eq 1) 'Config drift gate rejected or misclassified an ordinary business-data byte change.'
    # Simulate a caller-presented, hash-consistent final package with changed config bytes.
    # The delta consumer must independently enforce the approved config baseline.
    foreach($case in @('Modified','Added','Deleted')){
        $tampered=New-ConfigWorkflowTamperedPackage $businessFinal (Join-Path $root ('tampered-'+$case)) $case
        $blocked=$false;$message='';try{New-WsmArtifactDeltaManifest -BaseManifestPath $base.ManifestPath -BaseManifestHash $base.SHA256 -BasePlanPath $planPath -BasePlanHash $approval.SHA256 -CurrentManifestPath $tampered.ManifestPath -CurrentManifestHash $tampered.ManifestHash -CurrentPlanPath $planPath -CurrentPlanHash $approval.SHA256 -OutputPath (Join-Path $root ('config-drift-'+$case+'.jsonl')) -SummaryPath (Join-Path $root ('config-drift-'+$case+'.json')) -OwnedItemIds @($item.ItemId) | Out-Null}catch{$blocked=$true;$message=$_.Exception.Message}
        Assert-ConfigWorkflow ($blocked -and $message -match 'Configuration|config|drift|approved|missing') ('New-WsmArtifactDeltaManifest accepted '+$case.ToLowerInvariant()+' configuration drift. '+$message)
    }
    Write-Host 'PASS: actual source config draft, reviewed ConfigFiles plan approval, package export/validation rejects config modify/add/delete, business bytes pass final generation, and delta consumer independently rejects config drift.'
} finally {if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force};if([IO.Directory]::Exists($draftWorkspace)){Remove-Item -LiteralPath $draftWorkspace -Recurse -Force}}
