[CmdletBinding(DefaultParameterSetName = 'Stage')]
param(
    # Not Mandatory: a missing -Stage must fail fast instead of PowerShell waiting forever at an interactive parameter prompt.
    [Parameter(ParameterSetName = 'Stage')]
    [ValidatePattern('^(A1|B1|B2|C1|C2|D1|D2|D3a|D3b|E0|E1|E2|E3a|E3b|F1|F2|F3|F4a|F4b|G)$')]
    [string] $Stage,

    [Parameter(Mandatory = $true, ParameterSetName = 'WholeRound')]
    [switch] $WholeRound,

    [string] $LedgerPath = 'docs/plans/MIGRATION-7-EVIDENCE.json',
    [string] $RepositoryRoot
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Fail([string] $Message) {
    throw "Evidence validation failed: $Message"
}

function Get-PropertyValue($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-RepoFile([string] $RelativePath, [string] $Label) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        Fail "$Label must be a non-empty relative path."
    }
    $normalized = $RelativePath.Replace('\', '/')
    if ($normalized -match '(^|/)\.\.?(/|$)' -or $normalized -match '(^|/)docs/archive(/|$)' -or
        $normalized -match '(^|/)Get-ServerMigrationInventory\.ps1$') {
        Fail "$Label points to a prohibited or non-repository path: $RelativePath"
    }
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Label escapes the repository: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Fail "$Label file is missing: $RelativePath"
    }
    $cursor = $root
    foreach ($segment in $normalized.Split('/')) {
        $cursor = Join-Path $cursor $segment
        $item = Get-Item -LiteralPath $cursor -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Fail "$Label traverses a symlink or junction and cannot be proven repository-contained: $RelativePath"
        }
    }
    return $full
}

function Assert-Sha256([string] $Value, [string] $Label) {
    if ($Value -notmatch '^[0-9a-fA-F]{64}$') { Fail "$Label must be a 64-character SHA256 value." }
}

# Hashes are bound to the canonical text form (CRLF folded to LF), so the same committed content verifies in an LF
# snapshot (git archive) and in a CRLF working tree (core.autocrlf=true). A value recorded from the raw bytes of
# the current checkout is still accepted. Any other byte change, including a single content byte, fails both forms.
function Get-FileHashForms([string] $Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $raw = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { return @($raw, $raw) }
        $folded = New-Object 'System.Collections.Generic.List[byte]' $bytes.Length
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 13 -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 10) { continue }
            $folded.Add($bytes[$i])
        }
        $canonical = [BitConverter]::ToString($sha.ComputeHash($folded.ToArray())).Replace('-', '')
        return @($canonical, $raw)
    }
    finally { $sha.Dispose() }
}

function Test-FileHashMatches([string] $Path, [string] $Recorded) {
    $forms = Get-FileHashForms $Path
    $expected = $Recorded.ToUpperInvariant()
    return ($forms[0] -eq $expected -or $forms[1] -eq $expected)
}

if ($PSCmdlet.ParameterSetName -eq 'Stage' -and [string]::IsNullOrWhiteSpace($Stage)) { Fail 'specify -Stage <id> or -WholeRound.' }
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$root = [IO.Path]::GetFullPath($RepositoryRoot)
$ledgerFullPath = if ([IO.Path]::IsPathRooted($LedgerPath)) { $LedgerPath } else { Join-Path $root $LedgerPath }
if (-not (Test-Path -LiteralPath $ledgerFullPath -PathType Leaf)) { Fail "ledger is missing: $LedgerPath" }
try { $ledger = Get-Content -LiteralPath $ledgerFullPath -Raw | ConvertFrom-Json }
catch { Fail "ledger JSON is malformed: $($_.Exception.Message)" }

$schemaVersion = Get-PropertyValue $ledger 'schemaVersion'
if ($null -eq $schemaVersion -or $schemaVersion.GetType().FullName -notin @('System.Int32','System.Int64') -or [int64]$schemaVersion -ne 1) { Fail 'schemaVersion must be integer 1.' }
if ((Get-PropertyValue $ledger 'round') -ne 'MIGRATION-7') { Fail 'round must be MIGRATION-7.' }
$expectedIds = @('A1','B1','B2','C1','C2','D1','D2','D3a','D3b','E0','E1','E2','E3a','E3b','F1','F2','F3','F4a','F4b','G')
$stages = @(Get-PropertyValue $ledger 'stages')
if ($stages.Count -ne $expectedIds.Count) { Fail "ledger must contain exactly the $($expectedIds.Count) planned stage IDs." }

$seen = @{}
foreach ($entry in $stages) {
    $id = [string](Get-PropertyValue $entry 'id')
    if ($id -notin $expectedIds) { Fail "malformed or unexpected stage ID: $id" }
    if ($seen.ContainsKey($id)) { Fail "duplicate stage ID: $id" }
    $seen[$id] = $true

    foreach ($field in @('implementationStatus', 'evidenceStatus', 'externalStatus', 'signatureStatus')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $entry $field))) { Fail "stage $id has malformed or missing $field." }
    }
    if ((Get-PropertyValue $entry 'implementationStatus') -notin @('not-started', 'in-progress', 'implemented')) { Fail "stage $id has invalid implementationStatus." }
    if ((Get-PropertyValue $entry 'evidenceStatus') -notin @('not-collected', 'implemented-unverified', 'isolated-pass', 'external-unverified', 'accepted', 'historical-only')) { Fail "stage $id has invalid evidenceStatus." }
    if ((Get-PropertyValue $entry 'externalStatus') -notin @('not-assessed', 'not-tested', 'pending', 'passed', 'failed')) { Fail "stage $id has invalid externalStatus." }
    if ((Get-PropertyValue $entry 'signatureStatus') -notin @('not-required', 'pending', 'signed')) { Fail "stage $id has invalid signatureStatus." }
    $requirement = Get-PropertyValue $entry 'requirement'
    $requirementPath = [string](Get-PropertyValue $requirement 'path')
    $requirementFullPath = Resolve-RepoFile $requirementPath "stage $id requirement"
    $requirementHeadings = @(Get-PropertyValue $requirement 'headings')
    if ($requirementHeadings.Count -eq 0) { Fail "stage $id requirement heading is missing." }
    $requirementText = Get-Content -LiteralPath $requirementFullPath -Raw -Encoding UTF8
    foreach ($heading in $requirementHeadings) {
        if ([string]::IsNullOrWhiteSpace([string]$heading) -or $requirementText.IndexOf([string]$heading, [StringComparison]::Ordinal) -lt 0) { Fail "stage $id requirement heading is not present in ${requirementPath}: $heading" }
    }
    $evidenceState = Get-PropertyValue $entry 'evidenceStatus'
    $isComplete = (Get-PropertyValue $entry 'implementationStatus') -eq 'implemented' -and $evidenceState -in @('isolated-pass','external-unverified','accepted')
    $inputs = @(Get-PropertyValue $entry 'inputs')
    foreach ($input in $inputs) {
        $path = [string](Get-PropertyValue $input 'path')
        $hash = [string](Get-PropertyValue $input 'sha256')
        $full = Resolve-RepoFile $path "stage $id input"
        Assert-Sha256 $hash "stage $id input hash"
        if ($isComplete -and -not (Test-FileHashMatches $full $hash)) { Fail "stage $id input hash is stale: $path" }
    }
    $evidenceRefs = @(Get-PropertyValue $entry 'evidence')
    foreach ($ref in $evidenceRefs) {
        $path = [string](Get-PropertyValue $ref 'path')
        $hash = [string](Get-PropertyValue $ref 'sha256')
        $full = Resolve-RepoFile $path "stage $id evidence"
        Assert-Sha256 $hash "stage $id evidence hash"
        if ($isComplete -and -not (Test-FileHashMatches $full $hash)) { Fail "stage $id evidence hash is stale: $path" }
    }
    $log = Get-PropertyValue $entry 'evidenceLog'
    if ($null -ne $log) {
        $logPath = [string](Get-PropertyValue $log 'path')
        $logHash = [string](Get-PropertyValue $log 'sha256')
        $logFull = Resolve-RepoFile $logPath "stage $id evidence log"
        Assert-Sha256 $logHash "stage $id evidence log hash"
        if ($isComplete -and -not (Test-FileHashMatches $logFull $logHash)) { Fail "stage $id evidence log hash is stale: $logPath" }
    }
    if ((Get-PropertyValue $entry 'evidenceStatus') -eq 'accepted' -and (Get-PropertyValue $entry 'implementationStatus') -ne 'implemented') { Fail "stage $id claims accepted evidence without completed implementation." }
    if ($isComplete) {
        if ($inputs.Count -eq 0) { Fail "stage $id claims completion with no input evidence." }
        if ($evidenceRefs.Count -eq 0) { Fail "stage $id claims completion with no evidence references." }
        if ($null -eq $log) { Fail "stage $id claims completion with no evidence log." }
        $consumers = @(Get-PropertyValue $entry 'consumers')
        if ($consumers.Count -eq 0) { Fail "stage $id claims completion with no formal consumer mapping." }
        $inputPaths = @($inputs | ForEach-Object { ([string](Get-PropertyValue $_ 'path')).Replace('\','/') })
        foreach ($consumer in $consumers) {
            $consumerName = [string](Get-PropertyValue $consumer 'name')
            $consumerPath = [string](Get-PropertyValue $consumer 'path')
            if ([string]::IsNullOrWhiteSpace($consumerName)) { Fail "stage $id has a consumer without a name." }
            [void](Resolve-RepoFile $consumerPath "stage $id consumer")
            if ($consumerPath.Replace('\','/') -notin $inputPaths) { Fail "stage $id consumer bytes are not included in input hashes: $consumerPath" }
        }
        $environment = Get-PropertyValue $entry 'environment'
        foreach ($field in @('engine','runtime','scope')) { if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $environment $field))) { Fail "stage $id has incomplete environment metadata ($field)." } }
        if ((Get-PropertyValue $environment 'scope') -notin @('fixture','isolated','integrated','external')) { Fail "stage $id environment scope is invalid." }
        if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $entry 'result'))) { Fail "stage $id has no result summary." }
        $limitationsProperty = $entry.PSObject.Properties['limitations']
        if ($null -eq $limitationsProperty -or $null -eq $limitationsProperty.Value -or $limitationsProperty.Value -isnot [array]) { Fail "stage $id must explicitly list limitations, using an empty array when none apply." }
        $openIssuesProperty = $entry.PSObject.Properties['openIssues']
        if ($null -eq $openIssuesProperty -or $null -eq $openIssuesProperty.Value -or $openIssuesProperty.Value -isnot [array]) { Fail "stage $id must explicitly list openIssues, using an empty array when none remain." }
        $externalRequired = Get-PropertyValue $entry 'externalRequired'
        if ($externalRequired -isnot [bool]) { Fail "stage $id externalRequired must be boolean." }
        if ((Get-PropertyValue $entry 'signatureStatus') -eq 'pending') { Fail "stage $id claims completion while workflow signature is pending." }
        if ((Get-PropertyValue $entry 'signatureStatus') -eq 'signed') {
            $signature = Get-PropertyValue $entry 'signature'
            if ((Get-PropertyValue $signature 'round') -ne 'MIGRATION-7' -or [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $signature 'signer')) -or [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $signature 'role'))) { Fail "stage $id signed record must identify an R7 signer and role." }
            $signatureEvidence = Get-PropertyValue $signature 'evidence'
            $signaturePath = [string](Get-PropertyValue $signatureEvidence 'path')
            $signatureHash = [string](Get-PropertyValue $signatureEvidence 'sha256')
            $signatureFull = Resolve-RepoFile $signaturePath "stage $id signature evidence"
            Assert-Sha256 $signatureHash "stage $id signature hash"
            if (-not (Test-FileHashMatches $signatureFull $signatureHash)) { Fail "stage $id signature evidence hash is stale: $signaturePath" }
        }
        if ((Get-PropertyValue $entry 'externalStatus') -in @('pending','failed')) { Fail "stage $id claims completion with unresolved external evidence." }
        $cases = Get-PropertyValue $entry 'casesExecuted'
        if ($null -eq $cases -or $cases.GetType().FullName -notin @('System.Int32','System.Int64') -or [int64]$cases -le 0) { Fail "stage $id claims completion without a positive integer casesExecuted count." }
    }
}
foreach ($expected in $expectedIds) { if (-not $seen.ContainsKey($expected)) { Fail "stage $expected is missing." } }

$requested = if ($PSCmdlet.ParameterSetName -eq 'WholeRound') { $expectedIds } else { @($Stage) }
foreach ($id in $requested) {
    $entry = @($stages | Where-Object { $_.id -eq $id })[0]
    if ($entry.implementationStatus -ne 'implemented') { Fail "stage $id is not implemented." }
    if ($entry.evidenceStatus -notin @('isolated-pass','external-unverified','accepted')) { Fail "stage $id evidence is not accepted at a recorded level." }
    if ($entry.signatureStatus -eq 'pending') { Fail "stage $id still requires workflow signature." }
    if ($WholeRound -and $entry.externalRequired -and $entry.externalStatus -ne 'passed') { Fail "stage $id still requires external evidence." }
}

if ($PSCmdlet.ParameterSetName -eq 'WholeRound') {
    Write-Output 'PASS: all MIGRATION-7 planned stages are evidence-complete.'
} else {
    Write-Output "PASS: MIGRATION-7 stage $Stage is complete."
}
