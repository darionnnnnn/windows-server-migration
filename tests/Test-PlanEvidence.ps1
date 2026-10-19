[CmdletBinding()]
param()

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $repoRoot 'tools/Test-PlanEvidence.ps1'
$enginePath = (Get-Process -Id $PID).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('migration7-evidence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$passed = 0

function Write-FixtureFile([string] $RelativePath, [string] $Content) {
    $path = Join-Path $tempRoot $RelativePath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
    return $path
}

function Hash-File([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

function New-ValidLedger {
    [void](Write-FixtureFile 'plan.md' '# Fixture requirement')
    [void](Write-FixtureFile 'inputs/runtime.ps1' 'input bytes')
    [void](Write-FixtureFile 'logs/stage-a.log' 'Executed case 1: PASS')
    $inputPath = Join-Path $tempRoot 'inputs/runtime.ps1'
    $logPath = Join-Path $tempRoot 'logs/stage-a.log'
    $stages = @(
        [pscustomobject]@{ id='A1'; name='Fixture stage'; requirement=[pscustomobject]@{path='plan.md';headings=@('Fixture requirement')}; implementationStatus='implemented'; evidenceStatus='accepted'; externalStatus='not-tested'; externalRequired=$false; signatureStatus='not-required'; consumers=@([pscustomobject]@{name='fixture consumer';path='inputs/runtime.ps1'}); environment=[pscustomobject]@{engine='PowerShell';runtime='7.6';scope='fixture'}; result='All fixture checks passed.'; limitations=@('Fixture only.'); openIssues=@(); inputs=@([pscustomobject]@{path='inputs/runtime.ps1';sha256=(Hash-File $inputPath)}); evidence=@([pscustomobject]@{path='inputs/runtime.ps1';sha256=(Hash-File $inputPath)}); evidenceLog=[pscustomobject]@{path='logs/stage-a.log';sha256=(Hash-File $logPath)}; casesExecuted=1 }
    )
    foreach ($id in 'B1','B2','C1','C2','D1','D2','D3a','D3b','E0','E1','E2','E3a','E3b','F1','F2','F3','F4a','F4b','G') {
        $stages += [pscustomobject]@{ id=$id; name="Stage $id"; requirement=[pscustomobject]@{path='plan.md';headings=@('Fixture requirement')}; implementationStatus='not-started'; evidenceStatus='not-collected'; externalStatus='not-assessed'; externalRequired=$false; signatureStatus='not-required'; consumers=@(); environment=$null; result=''; limitations=@(); openIssues=@(); inputs=@(); evidence=@(); evidenceLog=$null; casesExecuted=0 }
    }
    return [pscustomobject]@{ schemaVersion=1; round='MIGRATION-7'; stages=$stages }
}

function Save-Ledger($Ledger) {
    $path = Join-Path $tempRoot 'ledger.json'
    $Ledger | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-Expected([string] $Name, [string] $Mode, [bool] $ShouldPass, $Ledger) {
    $ledgerPath = Save-Ledger $Ledger
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $validator, '-LedgerPath', $ledgerPath, '-RepositoryRoot', $tempRoot)
    if ($Mode -eq 'whole') { $arguments += '-WholeRound' } else { $arguments += @('-Stage', 'A1') }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $enginePath @arguments 2>&1 }
    finally { $ErrorActionPreference = $savedPreference }
    $exitCode = $LASTEXITCODE
    $actualPass = ($exitCode -eq 0)
    if ($actualPass -ne $ShouldPass) { throw "$Name expected pass=$ShouldPass, exit=$exitCode. Output: $($output -join ' ')" }
    $script:passed++
}

try {
    $ledger = New-ValidLedger
    Invoke-Expected 'valid completed stage' 'stage' $true $ledger
    Invoke-Expected 'incomplete whole round' 'whole' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[1].id = 'A1'
    Invoke-Expected 'duplicate ID' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].evidence[0].path = 'missing.txt'
    Invoke-Expected 'missing evidence file' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].evidenceLog.path = 'logs/missing.log'
    Invoke-Expected 'missing evidence log' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].inputs[0].sha256 = ('0' * 64)
    Invoke-Expected 'stale input hash' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].evidence[0].sha256 = ('0' * 64)
    Invoke-Expected 'stale evidence hash' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].casesExecuted = 0
    Invoke-Expected 'zero cases' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].casesExecuted = '1'
    Invoke-Expected 'malformed case count' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].implementationStatus = 'probably-done'
    Invoke-Expected 'malformed status' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].evidence = @()
    Invoke-Expected 'required evidence removed' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].environment = $null
    Invoke-Expected 'required environment missing' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[1].implementationStatus = 'implemented'; $ledger.stages[1].evidenceStatus = 'accepted'
    Invoke-Expected 'unselected claimed-complete stage missing evidence' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[1].inputs = @([pscustomobject]@{path='inputs/runtime.ps1';sha256=('0' * 64)})
    Invoke-Expected 'unselected incomplete stage hash does not block selected stage' 'stage' $true $ledger

    $ledger = New-ValidLedger; $ledger.stages[1].requirement.path = '../outside.md'
    Invoke-Expected 'path traversal rejected' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].evidenceStatus = 'historical-only'
    Invoke-Expected 'historical evidence is not current acceptance' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].signatureStatus = 'signed'; $ledger.stages[0] | Add-Member -NotePropertyName signature -NotePropertyValue ([pscustomobject]@{round='MIGRATION-6';signer='Fixture signer';role='reviewer';evidence=[pscustomobject]@{path='logs/stage-a.log';sha256=(Hash-File (Join-Path $tempRoot 'logs/stage-a.log'))}})
    Invoke-Expected 'R6 signature cannot sign R7 stage' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].evidence[0].path = 'docs/archive/old-log.json'
    Invoke-Expected 'archive reference rejected' 'stage' $false $ledger

    $ledger = New-ValidLedger; $ledger.stages[0].inputs[0].path = 'Get-ServerMigrationInventory.ps1'
    Invoke-Expected 'private inventory reference rejected' 'stage' $false $ledger

    Write-Output "PASS: $passed evidence-validator fixture cases."
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
