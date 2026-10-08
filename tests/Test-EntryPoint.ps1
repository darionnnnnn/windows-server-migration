#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-cli-'+[Guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'manager'
$entry=Join-Path $PSScriptRoot '..\Start-ServerMigration.ps1'
$engine=Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $engine)) { $engine=Join-Path $PSHOME 'pwsh.exe' }
& $engine -NoProfile -NonInteractive -File $entry -Action Initialize -Workspace $workspace *> (Join-Path ([IO.Path]::GetTempPath()) 'wsm-cli-initialize.log')
if ($LASTEXITCODE -ne 0) { throw 'Initialize must return 0.' }
$source=[pscustomobject]@{ HostId=[Guid]::NewGuid().ToString(); Fingerprint=('c'*64); Name='synthetic-cli' }
$item=New-WsmItem $source.HostId Services Service 'cli-service' 'cli-service' @{Path='C:\Fixture\app.exe'}
$inventory=New-WsmInventory $source 1 @($item)
$path=Join-Path $root 'inventory.json'
[IO.File]::WriteAllText($path,($inventory | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
$c=Import-WsmInventory $workspace $path (Get-FileHash $path).Hash 'synthetic-target'
& $engine -NoProfile -NonInteractive -File $entry -Action Issues -Workspace $workspace -PairId $c.PairId *> (Join-Path $root 'issues.log')
if ($LASTEXITCODE -ne 2) { throw 'Pending review must return 2.' }
$ErrorActionPreference='Continue' # Native stderr is expected for the rejection cases below.
& $engine -NoProfile -NonInteractive -File $entry -Action UnknownAction -Workspace $workspace *> (Join-Path $root 'invalid.log')
if ($LASTEXITCODE -ne 4) { throw 'Unknown action must return 4.' }
& $engine -NoProfile -NonInteractive -File $entry -Action Import -Workspace $workspace -Path $path -ExpectedHash ('0'*64) -TargetName target *> (Join-Path $root 'hash.log')
if ($LASTEXITCODE -ne 4) { throw 'Invalid trusted hash must return 4.' }
$ErrorActionPreference='Stop'
if ((Get-WsmCatalog $workspace $c.PairId).DecisionRevision -ne 0) { throw 'Rejected CLI input changed review.' }
Write-Host ('PASS: CLI success 0, blocked 2, invalid action/hash 4, rejected input retains state. Evidence: '+$root)
# CI wrappers inherit native LASTEXITCODE; the expected rejection above is not a test failure.
$global:LASTEXITCODE=0
exit 0
