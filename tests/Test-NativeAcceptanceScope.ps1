[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$selector = Join-Path $repo 'tools/Get-NativeAcceptanceScope.ps1'
$checks = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}

function Invoke-Selector {
    param([string] $Path, [string[]] $Arguments)
    $exe = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($PSVersionTable.PSEdition -eq 'Core') { $exe = (Get-Command pwsh -ErrorAction Stop).Source }
    $forward = @()
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ($Arguments[$index] -eq '-ChangedPath') {
            $paths = @()
            while (($index + 1) -lt $Arguments.Count -and -not $Arguments[$index + 1].StartsWith('-')) { $index++; $paths += $Arguments[$index] }
            if ($paths.Count) {
                $json = ConvertTo-Json -InputObject $paths -Compress
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
                $forward += '-ChangedPathBase64'; $forward += $encoded
            }
        }
        else { $forward += $Arguments[$index] }
    }
    $output = @(& $exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Path @forward 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "Selector failed ($code): $($output -join "`n")" }
    try { return (($output -join "`n") | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Selector did not return JSON: $($output -join "`n")" }
}

function Assert-Scope {
    param($Scope, [string[]] $Expected, [string] $Reason)
    foreach ($suite in @('basic','launcher','release','runtime','manager','probe')) {
        Assert-True ([bool]$Scope.$suite -eq ($Expected -contains $suite)) "$Reason expected $suite=$($Expected -contains $suite), got $($Scope.$suite)"
    }
}

$product = @('basic','launcher','release','runtime','manager','probe')
foreach ($path in @('src/ui/nonc.js','src/ui/styles.css','src/ui/wizard.html','src/core/example.js')) {
    $scope = Invoke-Selector $selector @('-ChangedPath',$path)
    Assert-Scope $scope $product "product path $path"
    Assert-True ($scope.runtimeCase -eq 'all') "product path $path must run all runtime cases"
}

# A no-renames diff supplies both old and new names; the new product path must win.
$rename = Invoke-Selector $selector @('-ChangedPath','docs/old-note.md','src/ui/nonc.js')
Assert-Scope $rename $product 'rename with product destination'
$deleted = Invoke-Selector $selector @('-ChangedPath','src/ui/wizard.html')
Assert-Scope $deleted $product 'deleted product path'

$workflow = Invoke-Selector $selector @('-ChangedPath','.github/workflows/native-round6-gaps.yml')
Assert-Scope $workflow @('manager','probe') 'gaps workflow only'
$releaseWorkflow = Invoke-Selector $selector @('-ChangedPath','.github/workflows/native-release.yml')
Assert-Scope $releaseWorkflow $product 'release workflow only'

$knownTests = @(
    @{path='tests/Test-NativeHtmlBridge.js'; expected=@('basic')},
    @{path='tests/Test-ReleaseNativeLauncher.js'; expected=@('launcher','release')},
    @{path='tests/Test-ReleaseWizardSmoke.ps1'; expected=@('release')},
    @{path='tests/Test-NativeWizardRuntimeHandler.js'; expected=@('runtime')},
    @{path='tests/Test-NativeWizardManagerJourney.js'; expected=@('manager')},
    @{path='tests/Test-NativeProbeRoles.js'; expected=@('probe')}
)
foreach ($test in $knownTests) { Assert-Scope (Invoke-Selector $selector @('-ChangedPath',$test.path)) $test.expected "known test $($test.path)" }

$docs = Invoke-Selector $selector @('-ChangedPath','docs/guide.md','README.md')
Assert-Scope $docs @() 'docs-only'
Assert-True ($docs.reason -eq 'documentation-only') 'docs-only reason must be explicit'

foreach ($arguments in @(@('-ChangedPath'), @('-DiffFailed'))) {
    $scope = Invoke-Selector $selector $arguments
    Assert-Scope $scope $product 'empty or failed diff fail closed'
}
$badBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('[1]'))
$malformedRejected = $false
try { $null = Invoke-Selector $selector @('-ChangedPathBase64',$badBase64) } catch { $malformedRejected = $true }
Assert-True $malformedRejected 'non-string changed-path input must be rejected'
$badSuiteRejected = $false
try { $null = Invoke-Selector $selector @('-EventName','workflow_dispatch','-ReleaseSuite','typo') } catch { $badSuiteRejected = $true }
Assert-True $badSuiteRejected 'malformed manual suite must be rejected'
$unknown = Invoke-Selector $selector @('-ChangedPath','packaging/new-format.manifest')
Assert-Scope $unknown $product 'unknown path fail closed'

$manual = Invoke-Selector $selector @('-EventName','workflow_dispatch','-ReleaseSuite','target','-GapSuite','manager','-Engine','powershell')
Assert-Scope $manual @('runtime','manager') 'manual target plus manager'
Assert-True ($manual.runtimeCase -eq 'target') 'manual target must select target-only runtime mode'
Assert-True (@($manual.engines).Count -eq 1 -and @($manual.engines)[0] -eq 'powershell') 'manual engine restriction must be preserved'

$mutationDir = Join-Path ([IO.Path]::GetTempPath()) ('native-scope-mutation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $mutationDir | Out-Null
try {
    $mutant = Join-Path $mutationDir 'Get-NativeAcceptanceScope.ps1'
    $source = Get-Content -LiteralPath $selector -Raw
    $needle = '$result.basic = $true; $result.launcher = $true; $result.release = $true; $result.runtime = $true'
    $replacement = '$result.basic = $false; $result.launcher = $false; $result.release = $false; $result.runtime = $false'
    if (-not $source.Contains($needle)) { throw 'Mutation target changed; update the test to preserve its intent.' }
    [IO.File]::WriteAllText($mutant, $source.Replace($needle,$replacement), [Text.UTF8Encoding]::new($false))
    $mutated = Invoke-Selector $mutant @('-ChangedPath','src/ui/nonc.js')
    $caught = $false
    try { Assert-Scope $mutated $product 'mutation must be rejected' } catch { $caught = $true }
    Assert-True $caught 'selector mapping mutation was not detected'
}
finally {
    $resolved = [IO.Path]::GetFullPath($mutationDir)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or [IO.Path]::GetFileName($resolved) -notmatch '^native-scope-mutation-[0-9a-f]{32}$' -or ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing cleanup outside the exact non-reparse scope mutation test directory.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

Write-Output "PASS Test-NativeAcceptanceScope: $checks checks on $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion); changed/deleted/renamed paths, mappings, manual scope, fail-closed diff, docs-only and mutation detection."
