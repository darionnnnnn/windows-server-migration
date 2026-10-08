#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-config-review-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
function Assert-ConfigReview([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Get-ConfigReviewHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Get-ConfigReviewTextHash([string]$Text){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function Write-ConfigReviewPlan([string]$Path,$Plan){[IO.File]::WriteAllText($Path,($Plan | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)));Get-ConfigReviewHash $Path}
try{
    $source=Join-Path $root 'source';[void][IO.Directory]::CreateDirectory($source)
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'excluded'))
    [IO.File]::WriteAllText((Join-Path $source 'web.config'),'web-secret-value',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $source 'app.config'),'modified-config',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $source 'appsettings.new.json'),'new-config',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $source 'business.config'),'business-config-data',(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $source 'excluded\web.config'),'excluded-config',(New-Object Text.UTF8Encoding($false)))
    $fingerprint='a'*64;$sourceId=[Guid]::NewGuid().ToString();$targetId=[Guid]::NewGuid().ToString()
    $spec=[pscustomobject][ordered]@{
        Adapter='FileScope';SourcePath=$source;TargetPath=(Join-Path $root 'target');ExcludedRelativePaths=@('excluded');Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='Source owner';Evidence='Config review fixture'
        ConfigFiles=@(
            [pscustomobject]@{RelativePath='web.config';SHA256=(Get-ConfigReviewHash (Join-Path $source 'web.config'));Owner='Web owner';Evidence='Approved web config'}
            [pscustomobject]@{RelativePath='app.config';SHA256=(Get-ConfigReviewTextHash 'old-approved-config');Owner='App owner';Evidence='Approved app config'}
            [pscustomobject]@{RelativePath='gone.exe.config';SHA256=(Get-ConfigReviewTextHash 'removed-config');Owner='App owner';Evidence='Approved removed config'}
        )
        ConfigOverrides=@([pscustomobject]@{RelativePath='business.config';Classification='BusinessData';Owner='Data owner';Evidence='Data review';Reason='Application data, not executable configuration'})
    }
    $item=[pscustomobject][ordered]@{ItemId=('b'*64);Category='Storage';Kind='PathCandidate';Name='source';NaturalKey='source';SettingsHash=('c'*64);Dependencies=@();Decision='Include';Reason='reviewed';Mapping='';AccountMapping='';EndpointMapping='';Owner='Source owner';Evidence='Config review fixture';MigrationSpec=$spec;ConsistencyGroup='';ConsistencyOwner='';ConsistencyEvidence=''}
    $plan=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.3.0';Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString();PairId=[Guid]::NewGuid().ToString();ApprovalId=[Guid]::NewGuid().ToString();Source=[pscustomobject]@{HostId=$sourceId;Fingerprint=$fingerprint;Name='fixture-source';OS='Windows Server fixture';Version='10.0'};Target=[pscustomobject]@{HostId=$targetId;Fingerprint=('d'*64);Name='fixture-target';OS='Windows Server fixture';Version='10.0'};InventoryRevision=1;DecisionRevision=7;InventoryHash=('e'*64);Mode='IsolatedPilot';ToolFingerprint='';ApprovedUtc=[DateTime]::UtcNow.ToString('o');Items=@($item)}
    & $module {$script:fixtureFingerprint=$args[0];function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:fixtureFingerprint;Name='fixture';OS='Windows Server fixture';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}} $fingerprint
    $plan.ToolFingerprint=& $module {Get-WsmToolFingerprint}
    $planPath=Join-Path $root 'approved-plan.json';$planHash=Write-ConfigReviewPlan $planPath $plan
    $summaryPath=Join-Path $root 'review\review.json'
    $result=& $module {param($p,$h,$o) Export-WsmConfigArtifactReview -PlanPath $p -ExpectedHash $h -Path $o} $planPath $planHash $summaryPath
    $summary=Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $rows=@(Get-Content -LiteralPath $result.ChangesReportPath | ForEach-Object {ConvertFrom-Json $_})
    Assert-ConfigReview ($summary.Kind -ceq 'ConfigArtifactReview' -and $summary.Mode -ceq 'ReadOnlySourceReview' -and $summary.DecisionRevision -eq 7) 'Review summary did not bind the approved source plan and revision.'
    Assert-ConfigReview ($summary.RequiresReapproval -and $result.RequiresReapproval) 'Detected config drift did not require reapproval.'
    Assert-ConfigReview ($summary.ChangesSHA256 -ceq (Get-ConfigReviewHash $result.ChangesReportPath) -and $result.SHA256 -ceq (Get-ConfigReviewHash $summaryPath)) 'Review output hashes do not match the files.'
    Assert-ConfigReview ($summary.Counts.Unchanged -eq 1 -and $summary.Counts.Modified -eq 1 -and $summary.Counts.Added -eq 1 -and $summary.Counts.Deleted -eq 1) ('Review did not report unchanged, modified, added, and deleted configurations: '+($summary.Counts | ConvertTo-Json -Compress))
    Assert-ConfigReview (@($rows | Where-Object RelativePath -CEQ 'excluded\web.config').Count -eq 0) 'Excluded configuration leaked into the review.'
    Assert-ConfigReview (@($rows | Where-Object RelativePath -CEQ 'business.config').Count -eq 0) 'BusinessData override was misclassified as configuration.'
    Assert-ConfigReview (@($rows | Where-Object {$_.RelativePath -ceq 'gone.exe.config' -and $_.Change -ceq 'Deleted' -and $_.RequiresReapproval}).Count -eq 1) 'Missing approved configuration was not reported as deleted.'
    Assert-ConfigReview ((Get-Content -LiteralPath $result.ChangesReportPath -Raw) -notmatch 'web-secret-value|business-config-data|old-approved-config') 'Review output exposed configuration contents.'

    $badHashOutput=Join-Path $root 'bad-hash\review.json';$badHashDenied=$false
    try{& $module {param($p,$h,$o) Export-WsmConfigArtifactReview -PlanPath $p -ExpectedHash $h -Path $o} $planPath ('0'*64) $badHashOutput | Out-Null}catch{$badHashDenied=$true}
    Assert-ConfigReview ($badHashDenied -and -not [IO.Directory]::Exists((Split-Path -Parent $badHashOutput))) 'Untrusted plan hash created an output artifact or directory.'
    & $module {$script:fixtureFingerprint='f'*64}
    $foreignOutput=Join-Path $root 'foreign\review.json';$foreignDenied=$false
    try{& $module {param($p,$h,$o) Export-WsmConfigArtifactReview -PlanPath $p -ExpectedHash $h -Path $o} $planPath $planHash $foreignOutput | Out-Null}catch{$foreignDenied=$true}
    Assert-ConfigReview ($foreignDenied -and -not [IO.Directory]::Exists((Split-Path -Parent $foreignOutput))) 'Foreign source identity created an output artifact or directory.'
    & $module {$script:fixtureFingerprint=$args[0]} $fingerprint
    $overlapDirectory=Join-Path $source 'new-report-directory';$overlapOutput=Join-Path $overlapDirectory 'review.json';$overlapDenied=$false
    try{& $module {param($p,$h,$o) Export-WsmConfigArtifactReview -PlanPath $p -ExpectedHash $h -Path $o} $planPath $planHash $overlapOutput | Out-Null}catch{$overlapDenied=$_.Exception.Message -match 'overlap'}
    Assert-ConfigReview ($overlapDenied -and -not [IO.Directory]::Exists($overlapDirectory)) 'Overlapping review output modified the approved source before rejecting it.'
    $unprotectedDirectory=Join-Path $root 'unprotected';[void][IO.Directory]::CreateDirectory($unprotectedDirectory);$unprotectedOutput=Join-Path $unprotectedDirectory 'review.json';$unprotectedDenied=$false
    try{& $module {param($p,$h,$o) Export-WsmConfigArtifactReview -PlanPath $p -ExpectedHash $h -Path $o} $planPath $planHash $unprotectedOutput | Out-Null}catch{$unprotectedDenied=$true}
    Assert-ConfigReview ($unprotectedDenied -and -not [IO.File]::Exists($unprotectedOutput)) 'Review wrote into an existing output directory without the protected owner/SYSTEM/Administrators ACL.'
    Write-Host 'PASS: trusted source config review reports add/modify/delete/unchanged, honors exclusions and BusinessData overrides, omits contents, binds output hashes, and denies untrusted/foreign-host plans or unprotected output directories.'
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
