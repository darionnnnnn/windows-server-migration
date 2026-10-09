$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:ToolVersion='0.3.0'
$script:UnsafePaths=@()
$script:FixtureFingerprint='a'*64
$script:CancelDelivery=$false
function Assert-OutputTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-WsmId([string]$Id){$g=[Guid]::Empty;if(-not [Guid]::TryParseExact($Id,'D',[ref]$g)){throw 'bad id'}}
function Assert-WsmEnvelope($Data,[string]$Kind){if($Data.SchemaVersion -ne 1 -or $Data.Kind -cne $Kind){throw 'bad envelope'}}
function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:FixtureFingerprint;Name='fixture';OS='Windows Server';Version='10';IsServer=$true;Administrator=$true;Is64Bit=$true}}
function Assert-WsmCancellationBoundary($Token,[string]$Boundary){if($Token -and $script:CancelDelivery -and $Boundary -eq 'BeforeDirectoryMember'){throw (New-Object OperationCanceledException 'fixture cancellation')}}
function Assert-WsmNoReparse([string]$Path){$full=[IO.Path]::GetFullPath($Path);foreach($unsafe in $script:UnsafePaths){$u=[IO.Path]::GetFullPath($unsafe);if($full -ieq $u -or $full.StartsWith($u.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'fixture reparse point'}}}
function Protect-WsmDirectory([string]$Path){}
function Assert-WsmCancellationDirectoryProtection([string]$Path){}
function Get-WsmAvailableBytes([string]$Path){[long]2147483648}
function Get-WsmPhysicalPath([string]$Path){[IO.Path]::GetFullPath($Path)}
function Test-WsmPathOverlap([string]$Left,[string]$Right){$l=$Left.TrimEnd('\');$r=$Right.TrimEnd('\');$l -ieq $r -or $l.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($l+'\',[StringComparison]::OrdinalIgnoreCase)}
function Read-WsmJson([string]$Path){ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8))}
function Write-WsmJson([string]$Path,$Data){$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path));if(-not [IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};[IO.File]::WriteAllText($Path,($Data | ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)))}
function Get-WsmUtc {[DateTime]::UtcNow.ToString('o')}
function Invoke-WsmLocked([string]$Workspace,[scriptblock]$Action){& $Action}
. (Join-Path $PSScriptRoot '..\src\OutputWorkspace.ps1')
. (Join-Path $PSScriptRoot '..\src\OutputWorkflow.ps1')
function Read-WsmTrustedJson([string]$Path,[string]$ExpectedHash){if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'trusted hash mismatch'};Read-WsmJson $Path}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('.output-workspace-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$resolvedRoot=[IO.Path]::GetFullPath($testRoot)
try {
    $root=Join-Path $resolvedRoot 'source'
    $first=Initialize-WsmOutputWorkspace -WorkRoot $root -Role Source
    $again=Initialize-WsmOutputWorkspace -WorkRoot $root -Role Source
    Assert-OutputTest ($first.HostId -ceq $again.HostId) 'Repeated enrollment changed HostId.'
    Assert-OutputTest ($first.Revision -eq 0 -and [IO.File]::Exists((Join-Path $first.InventoryDirectory 'source-state.json'))) 'Source state was not initialized before PairId.'
    Assert-OutputTest ($first.Profile.Mode -ceq 'Zip' -and $first.Profile.VolumeBytes -eq 536870912) 'ZIP profile defaults differ from the D2 contract.'
    Assert-OutputTest ($first.StateDirectory -ceq (Join-Path $root 'pairs')) 'StateDirectory must be the parent consumed by Get-WsmOperationPaths.'
    $legacyRoot=Join-Path $resolvedRoot 'legacy-source';[void][IO.Directory]::CreateDirectory($legacyRoot);Write-WsmJson (Join-Path $legacyRoot 'source-state.json') ([pscustomobject]@{HostId=$first.HostId;Fingerprint=$script:FixtureFingerprint;Revision=7})
    try{Initialize-WsmOutputWorkspace $legacyRoot Source | Out-Null;throw 'legacy enrollment silently recreated'}catch{if($_.Exception.Message -eq 'legacy enrollment silently recreated'){throw}}
    $sourceStatePath=Join-Path $first.InventoryDirectory 'source-state.json';$sourceState=Read-WsmJson $sourceStatePath;$sourceState.Revision=7;Write-WsmJson $sourceStatePath $sourceState
    Assert-OutputTest ((Initialize-WsmOutputWorkspace -WorkRoot $root -Role Source).Revision -eq 7) 'Repeated source enrollment lost the durable revision.'
    try { Initialize-WsmOutputWorkspace -WorkRoot $root -Role Manager | Out-Null; throw 'wrong role was accepted' } catch { if($_.Exception.Message -eq 'wrong role was accepted'){throw} }
    $script:FixtureFingerprint='e'*64
    try { Initialize-WsmOutputWorkspace -WorkRoot $root -Role Source | Out-Null; throw 'wrong host fingerprint was accepted' } catch { if($_.Exception.Message -eq 'wrong host fingerprint was accepted'){throw} }
    $script:FixtureFingerprint='a'*64
    try { Initialize-WsmOutputWorkspace -WorkRoot (Join-Path $resolvedRoot 'bad-size') -Role Source -VolumeBytes 1048576 | Out-Null; throw 'legacy 1 MiB profile was accepted by the new profile' } catch { if($_.Exception.Message -eq 'legacy 1 MiB profile was accepted by the new profile'){throw} }
    try { Initialize-WsmOutputWorkspace -WorkRoot (Join-Path $resolvedRoot 'bad-fraction') -Role Source -VolumeBytes 134217729 | Out-Null; throw 'fractional MiB profile was accepted' } catch { if($_.Exception.Message -eq 'fractional MiB profile was accepted'){throw} }
    try { Initialize-WsmOutputWorkspace -WorkRoot (Join-Path $resolvedRoot 'bad-directory-limit') -Role Source -Mode Directory -VolumeBytes 536870912 | Out-Null; throw 'directory mode accepted a ZIP volume limit' } catch { if($_.Exception.Message -eq 'directory mode accepted a ZIP volume limit'){throw} }
    $profilePath=Join-Path $root 'workspace-control\output-profile.json';$profile=Read-WsmJson $profilePath;$profile.ProfileVersion=2;Write-WsmJson $profilePath $profile
    try { Initialize-WsmOutputWorkspace -WorkRoot $root -Role Source | Out-Null; throw 'unsupported profile version was accepted' } catch { if($_.Exception.Message -eq 'unsupported profile version was accepted'){throw} }
    $profile.ProfileVersion=1;Write-WsmJson $profilePath $profile

    $targetRoot=Join-Path $resolvedRoot 'target'
    $target=Initialize-WsmOutputWorkspace -WorkRoot $targetRoot -Role Target
    Assert-OutputTest ($target.TargetIdentity.HostId -ceq $target.HostId) 'Target registration did not retain its enrollment identity.'
    $pair='11111111-1111-4111-8111-111111111111';$planHash='b'*64
    $paired=Resolve-WsmOutputWorkspace -WorkRoot $targetRoot -Role Target -PairId $pair -PlanHash $planHash -AttemptId '22222222-2222-4222-8222-222222222222'
    Assert-OutputTest ($paired.PairRoot -ceq (Join-Path $targetRoot ('pairs\'+$pair))) 'PairRoot path mapping is ambiguous.'
    Assert-OutputTest ($paired.StateDirectory -ceq (Join-Path $targetRoot 'pairs')) 'StateDirectory would append PairId twice.'
    Assert-OutputTest ($paired.AttemptRoot -like '*\attempts\22222222-2222-4222-8222-222222222222') 'AttemptId paths were not separated from operation state.'
    $retried=Resolve-WsmOutputWorkspace -WorkRoot $targetRoot -Role Target -PairId $pair -PlanHash $planHash -AttemptId '22222222-2222-4222-8222-222222222222'
    Assert-OutputTest ($retried.AttemptId -ceq $paired.AttemptId -and $retried.PairRoot -ceq $paired.PairRoot) 'Explicit attempt retry did not preserve its durable identity.'
    $targetProfilePath=Join-Path $targetRoot 'workspace-control\output-profile.json'
    $oldProfileHash=(Get-FileHash -LiteralPath $targetProfilePath).Hash
    Set-WsmOutputPreferences $targetRoot Target $oldProfileHash Directory | Out-Null
    $preserved=Resolve-WsmOutputWorkspace $targetRoot Target -PairId $pair -PlanHash $planHash -AttemptId $paired.AttemptId
    Assert-OutputTest ($preserved.AttemptProfile.Mode -ceq 'Zip' -and $preserved.AttemptProfile.VolumeBytes -eq 536870912) 'Preference edit changed sealed retry preferences.'
    $newAttempt=Resolve-WsmOutputWorkspace $targetRoot Target -PairId $pair -PlanHash $planHash
    Assert-OutputTest ($newAttempt.AttemptProfile.Mode -ceq 'Directory' -and $newAttempt.HostId -ceq $paired.HostId) 'New transport preference changed enrollment or failed to apply.'
    try{Set-WsmOutputPreferences $targetRoot Target $oldProfileHash Zip | Out-Null;throw 'stale profile edit accepted'}catch{if($_.Exception.Message -eq 'stale profile edit accepted'){throw}}
    try { Register-WsmOutputPair -WorkRoot $targetRoot -Role Target -PairId $pair -PlanHash ('c'*64) | Out-Null; throw 'wrong plan reused a pair binding' } catch { if($_.Exception.Message -eq 'wrong plan reused a pair binding'){throw} }
    $pairPath=Join-Path $targetRoot ('pairs\'+$pair)
    Remove-Item -LiteralPath $pairPath -Recurse -Force
    try { Register-WsmOutputPair -WorkRoot $targetRoot -Role Target -PairId $pair -PlanHash $planHash | Out-Null; throw 'missing registered pair state was accepted' } catch { if($_.Exception.Message -eq 'missing registered pair state was accepted'){throw} }
    $targetStateRoot=Join-Path $resolvedRoot 'target-state-loss';$targetState=Initialize-WsmOutputWorkspace -WorkRoot $targetStateRoot -Role Target
    $statePair='44444444-4444-4444-8444-444444444444';$stateBinding=Register-WsmOutputPair -WorkRoot $targetStateRoot -Role Target -PairId $statePair -PlanHash $planHash
    $stateFile=Join-Path $stateBinding.PairRoot 'state.json';Write-WsmJson $stateFile ([pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OperationState';PairId=$statePair;PlanHash=$planHash;TargetFingerprint=$script:FixtureFingerprint})
    Confirm-WsmOutputOperationState -WorkRoot $targetStateRoot -Role Target -PairId $statePair -PlanHash $planHash | Out-Null
    Remove-Item -LiteralPath $stateFile -Force
    try { Register-WsmOutputPair -WorkRoot $targetStateRoot -Role Target -PairId $statePair -PlanHash $planHash | Out-Null; throw 'previously registered operation checkpoint loss was accepted' } catch { if($_.Exception.Message -eq 'previously registered operation checkpoint loss was accepted'){throw} }
    $targetIdentityRoot=Join-Path $resolvedRoot 'target-identity-loss';$missingIdentity=Initialize-WsmOutputWorkspace -WorkRoot $targetIdentityRoot -Role Target
    Remove-Item -LiteralPath (Join-Path $targetIdentityRoot ('targets\'+$missingIdentity.HostId+'\target-identity.json')) -Force
    try { Initialize-WsmOutputWorkspace -WorkRoot $targetIdentityRoot -Role Target | Out-Null; throw 'missing target identity was silently recreated' } catch { if($_.Exception.Message -eq 'missing target identity was silently recreated'){throw} }
    Remove-Item -LiteralPath $sourceStatePath -Force
    try { Initialize-WsmOutputWorkspace -WorkRoot $root -Role Source | Out-Null; throw 'missing source state was silently recreated' } catch { if($_.Exception.Message -eq 'missing source state was silently recreated'){throw} }
    $unsafe=Join-Path $resolvedRoot 'unsafe';[void][IO.Directory]::CreateDirectory($unsafe);$script:UnsafePaths=@($unsafe)
    try { Initialize-WsmOutputWorkspace -WorkRoot (Join-Path $unsafe 'child') -Role Source | Out-Null; throw 'reparse path was accepted' } catch { if($_.Exception.Message -eq 'reparse path was accepted'){throw} }
    $script:UnsafePaths=@()

    $packageRoot=Join-Path $resolvedRoot 'sealed';[void][IO.Directory]::CreateDirectory($packageRoot);[void][IO.Directory]::CreateDirectory((Join-Path $packageRoot 'payload'))
    $content=@{'manifest.json'='manifest';'plan.json'='plan';'artifacts.jsonl'='artifacts';'payload/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.blob'='payload'}
    foreach($name in $content.Keys){$path=Join-Path $packageRoot ($name.Replace('/','\'));[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));[IO.File]::WriteAllText($path,$content[$name])}
    foreach($extra in @('export-state.json','journal.jsonl','raw-inventory.json','payload/orphan.blob')){[IO.File]::WriteAllText((Join-Path $packageRoot $extra),'must not ship')}
    $script:FixtureMembers=@(foreach($name in $content.Keys){$path=Join-Path $packageRoot ($name.Replace('/','\'));[pscustomobject]@{Name=$name;Path=$path;Bytes=(New-Object IO.FileInfo($path)).Length;Hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}})
    $script:FixturePackage=[pscustomobject]@{Root=$packageRoot;SHA256=('d'*64);Manifest=[pscustomobject]@{PackageId='33333333-3333-4333-8333-333333333333';PairId=$pair;PlanHash=$planHash;Final=$false}}
    function Test-WsmMigrationPackage([string]$ManifestPath,[string]$ExpectedHash){if($ExpectedHash -cne $script:FixturePackage.SHA256){throw 'untrusted manifest hash'};[pscustomobject]@{Root=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ManifestPath));SHA256=$ExpectedHash;Manifest=$script:FixturePackage.Manifest}}
    function Get-WsmPackageMembers($Package){$script:FixtureMembers}
    $delivery=Join-Path $resolvedRoot 'delivery-package'
    $result=Export-WsmDirectoryDelivery -ManifestPath (Join-Path $packageRoot 'manifest.json') -ExpectedHash $script:FixturePackage.SHA256 -OutputDirectory $delivery
    $exported=@(Get-ChildItem -LiteralPath $delivery -File -Recurse | ForEach-Object {$_.FullName.Substring($delivery.Length).TrimStart('\').Replace('\','/')})
    Assert-OutputTest ($exported.Count -eq $content.Count) 'Directory delivery included files outside the trusted whitelist.'
    foreach($name in $content.Keys){Assert-OutputTest ($exported -ccontains $name) ('Directory delivery omitted '+$name)}
    Assert-OutputTest (-not ($exported -match 'export-state|journal|raw-inventory|orphan')) 'A non-whitelisted package member was exported.'
    Assert-OutputTest ($result.Valid -and [IO.File]::Exists($result.SummaryPath)) 'Delivery summary was not sealed outside the package.'
    Assert-OutputTest (-not (Test-WsmPathOverlap $result.SummaryPath $delivery)) 'Delivery summary was written inside the package.'
    $reportPath=Join-Path $resolvedRoot 'report.txt';[IO.File]::WriteAllText($reportPath,'reviewed report');$reportHash=(Get-FileHash -LiteralPath $reportPath).Hash
    $reportResult=Export-WsmDirectoryDelivery -ManifestPath (Join-Path $packageRoot 'manifest.json') -ExpectedHash $script:FixturePackage.SHA256 -OutputDirectory (Join-Path $resolvedRoot 'with-report') -ReportReferences @([pscustomobject]@{Path=$reportPath;SHA256=$reportHash})
    Assert-OutputTest ((Read-WsmJson $reportResult.SummaryPath).ReportReferences.Count -eq 1) 'Fixed report reference was omitted from sealed delivery metadata.'
    $script:CancelDelivery=$true
    $cancelled=Join-Path $resolvedRoot 'cancelled-delivery'
    try { Export-WsmDirectoryDelivery -ManifestPath (Join-Path $packageRoot 'manifest.json') -ExpectedHash $script:FixturePackage.SHA256 -OutputDirectory $cancelled -CancellationToken ([pscustomobject]@{Cancelled=$true}) | Out-Null; throw 'cancelled directory delivery completed' } catch { if($_.Exception.Message -eq 'cancelled directory delivery completed'){throw} }
    $script:CancelDelivery=$false
    Assert-OutputTest (-not [IO.Directory]::Exists($cancelled) -and @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Filter 'cancelled-delivery.partial-*').Count -eq 0) 'Cancellation left a partial delivery tree.'

    $badSource=Join-Path $packageRoot 'plan.json';[IO.File]::WriteAllText($badSource,'changed')
    $badDestination=Join-Path $resolvedRoot 'bad-delivery'
    try { Export-WsmDirectoryDelivery -ManifestPath (Join-Path $packageRoot 'manifest.json') -ExpectedHash $script:FixturePackage.SHA256 -OutputDirectory $badDestination | Out-Null; throw 'source hash drift was accepted' } catch { if($_.Exception.Message -eq 'source hash drift was accepted'){throw} }
    Assert-OutputTest (-not [IO.Directory]::Exists($badDestination)) 'Failed delivery left a completed package directory.'
    Assert-OutputTest (@(Get-ChildItem -LiteralPath $resolvedRoot -Directory -Filter 'bad-delivery.partial-*').Count -eq 0) 'Failed delivery left a partial directory.'
    $script:FixtureMembers=@($script:FixtureMembers)+@([pscustomobject]@{Name='export-state.json';Path=(Join-Path $packageRoot 'export-state.json');Bytes=16;Hash=(Get-FileHash -LiteralPath (Join-Path $packageRoot 'export-state.json')).Hash.ToLowerInvariant()})
    try { Export-WsmDirectoryDelivery -ManifestPath (Join-Path $packageRoot 'manifest.json') -ExpectedHash $script:FixturePackage.SHA256 -OutputDirectory (Join-Path $resolvedRoot 'extra-member') | Out-Null; throw 'extra package member was accepted' } catch { if($_.Exception.Message -eq 'extra package member was accepted'){throw} }
    $script:FixtureMembers=@($script:FixtureMembers | Where-Object Name -ne 'plan.json')
    try { Export-WsmDirectoryDelivery -ManifestPath (Join-Path $packageRoot 'manifest.json') -ExpectedHash $script:FixturePackage.SHA256 -OutputDirectory (Join-Path $resolvedRoot 'missing-member') | Out-Null; throw 'missing required whitelist member was accepted' } catch { if($_.Exception.Message -eq 'missing required whitelist member was accepted'){throw} }
    Write-Output 'OutputWorkspace isolated acceptance passed.'
} finally {
    $cleanup=[IO.Path]::GetFullPath($testRoot);$testParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($cleanup.StartsWith($testParent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($cleanup).StartsWith('.output-workspace-test-',[StringComparison]::Ordinal)){Remove-Item -LiteralPath $cleanup -Recurse -Force}
}
