[CmdletBinding()]
param(
    [string[]] $ChangedPath = @(),
    [string] $ChangedPathBase64,
    [ValidateSet('push','pull_request','workflow_dispatch','test')]
    [string] $EventName = 'test',
    [ValidateSet('all','basic','launcher','release','target','source-cancel')]
    [string] $ReleaseSuite = 'all',
    [ValidateSet('both','manager','probe')]
    [string] $GapSuite = 'both',
    [ValidateSet('both','powershell','pwsh')]
    [string] $Engine = 'both',
    [switch] $DiffFailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('ChangedPathBase64')) {
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ChangedPathBase64))
        $decodedPaths = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch { throw 'ChangedPathBase64 must encode a JSON array of path strings.' }
    if ($json -notmatch '^\s*\[' -or @($decodedPaths | Where-Object { $_ -isnot [string] }).Count -gt 0) { throw 'ChangedPathBase64 must encode an array containing only strings.' }
    $ChangedPath = [string[]]@($decodedPaths)
}

function Get-AllScope {
    param([string] $Reason)
    return [ordered]@{
        basic = $true; launcher = $true; release = $true; runtime = $true
        runtimeCase = 'all'; manager = $true; probe = $true
        engines = @('powershell','pwsh'); reason = $Reason
    }
}

if ($EventName -eq 'workflow_dispatch') {
    $launcher = $ReleaseSuite -in @('all','launcher')
    $releaseSmoke = $ReleaseSuite -in @('all','launcher','release')
    $runtime = $ReleaseSuite -in @('all','target','source-cancel')
    $gapManager = $GapSuite -in @('both','manager')
    $gapProbe = $GapSuite -in @('both','probe')
    $engines = if ($Engine -eq 'both') { @('powershell','pwsh') } else { @($Engine) }
    $manualResult = [ordered]@{
        basic = ($ReleaseSuite -in @('all','basic')); launcher = $launcher
        release = $releaseSmoke; runtime = $runtime
        runtimeCase = $(if ($ReleaseSuite -in @('target','source-cancel')) { $ReleaseSuite } else { 'all' })
        manager = $gapManager; probe = $gapProbe; engines = $engines
        reason = "manual:$ReleaseSuite/$GapSuite/$Engine"
    }
    $manualResult | ConvertTo-Json -Compress -Depth 4
    exit 0
}

if ($DiffFailed) {
    Get-AllScope 'diff-unavailable-fail-closed-all' | ConvertTo-Json -Compress -Depth 4
    exit 0
}

$paths = @($ChangedPath | ForEach-Object { $_ -replace '\\','/' } | Where-Object { $_ } | Sort-Object -Unique)
if ($paths.Count -eq 0) {
    Get-AllScope 'empty-diff-fail-closed-all' | ConvertTo-Json -Compress -Depth 4
    exit 0
}

$result = [ordered]@{
    basic = $false; launcher = $false; release = $false; runtime = $false
    runtimeCase = 'source-cancel'; manager = $false; probe = $false
    engines = @('powershell','pwsh'); reason = 'changed-paths'
}
$unknown = $false
$runtimeCases = [System.Collections.Generic.List[string]]::new()
foreach ($path in $paths) {
    $isDocumentation = $path.StartsWith('docs/', [StringComparison]::OrdinalIgnoreCase) -or $path -match '^(README|CHANGELOG|LICENSE)(\..*)?$' -or $path -match '^[^/]+\.md$'
    if ($isDocumentation) { continue }
    if ($path -eq '.github/workflows/native-release.yml') {
        $result.basic = $true; $result.launcher = $true; $result.release = $true; $result.runtime = $true
        $result.manager = $true; $result.probe = $true; $runtimeCases.Add('all'); continue
    }
    if ($path -eq '.github/workflows/native-round6-gaps.yml') {
        $result.manager = $true; $result.probe = $true; continue
    }
    if ($path -match '^src/' -or $path -match '^Start-ServerMigration\.' -or $path -match '^tools/') {
        # Product, runner, and acceptance changes can affect any native consumer.
        $result.basic = $true; $result.launcher = $true; $result.release = $true; $result.runtime = $true
        $result.manager = $true; $result.probe = $true; $runtimeCases.Add('all'); continue
    }
    if ($path -match '^tests/(Test-NativeHtmlBridge\.js|Start-HtmlTestServer\.ps1)$') { $result.basic = $true; continue }
    if ($path -match '^tests/Test-ReleaseNativeLauncher\.js$') { $result.launcher = $true; $result.release = $true; continue }
    if ($path -match '^tests/Test-ReleaseWizardSmoke\.ps1$') { $result.release = $true; continue }
    if ($path -match '^tests/(Test-NativeWizardRuntimeHandler\.js|Start-WizardRuntimeTestServer\.ps1)$') { $result.runtime = $true; $runtimeCases.Add('all'); continue }
    if ($path -match '^tests/(Test-NativeWizardManagerJourney\.js|Start-WizardManagerJourneyTestServer\.ps1)$') { $result.manager = $true; continue }
    if ($path -match '^tests/(Test-NativeProbeRoles\.js|Start-NativeProbeRoleTestServer\.ps1)$') { $result.probe = $true; continue }
    if ($path -match '^tests/') { $unknown = $true; continue }
    if ($path -match '^\.github/workflows/') {
        $result.basic = $true; $result.launcher = $true; $result.release = $true; $result.runtime = $true
        $result.manager = $true; $result.probe = $true; $runtimeCases.Add('all'); continue
    }
    # Unknown paths fail closed because product packaging and runtime dependencies
    # are not fully described by a generated path manifest yet.
    $unknown = $true
}

if ($unknown) {
    Get-AllScope 'unknown-path-fail-closed-all' | ConvertTo-Json -Compress -Depth 4
    exit 0
}
if ($runtimeCases -contains 'all') { $result.runtimeCase = 'all' }
elseif ($runtimeCases.Count -gt 0) { $result.runtimeCase = 'source-cancel' }
$result.reason = if (($result.basic -or $result.launcher -or $result.release -or $result.runtime -or $result.manager -or $result.probe)) { 'mapped-changed-paths' } else { 'documentation-only' }
$result | ConvertTo-Json -Compress -Depth 4
