#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-archive-'+[Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($root)
$workspace=Join-Path $root 'manager'; Initialize-WsmWorkspace $workspace | Out-Null
$source=[pscustomobject]@{ HostId=[Guid]::NewGuid().ToString(); Fingerprint=('c'*64); Name='old-zip' }
$i=New-WsmItem $source.HostId Tasks ScheduledTask 'safe task' '\safe' @{ Xml='<Task />' }
$inv=New-WsmInventory $source 1 @($i)
$json=Join-Path $root 'inventory-1.json'; [IO.File]::WriteAllText($json,($inv | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
$hashFile=$json+'.sha256'; [IO.File]::WriteAllText($hashFile,(Get-FileHash $json).Hash)
function New-Archive([string]$Name,[string]$Entry='inventory-1.json',[string]$Second='inventory-1.json.sha256') {
    $p=Join-Path $root $Name; $a=[IO.Compression.ZipFile]::Open($p,'Create')
    try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($a,$json,$Entry); [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($a,$hashFile,$Second) } finally { $a.Dispose() }; $p
}
function Reject([scriptblock]$Action) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; if (-not $failed) { throw 'Unsafe archive accepted.' } }
$valid=New-Archive 'valid.zip'; $c=Import-WsmInventoryArchive $workspace $valid (Get-FileHash $valid).Hash 'new-zip'
if ($c.Items.Count -ne 1 -or $c.Source.HostId -cne $source.HostId) { throw 'Valid archive not imported accurately.' }
foreach ($name in @('../inventory-1.json','C:/inventory-1.json','inventory-1.json:evil','tool.ps1','CON.json','folder/inventory-1.json')) { $p=New-Archive ([Guid]::NewGuid().ToString('N')+'.zip') $name; Reject { Import-WsmInventoryArchive $workspace $p (Get-FileHash $p).Hash new } }
$p=New-Archive 'duplicate.zip' 'inventory-1.json' 'INVENTORY-1.JSON'; Reject { Import-WsmInventoryArchive $workspace $p (Get-FileHash $p).Hash new }
Reject { Import-WsmInventoryArchive $workspace $valid ('0'*64) new }
if (@(Get-ChildItem $workspace -Filter '*.inventory-input.tmp').Count) { throw 'Temporary sensitive inventory was not removed.' }
Write-Host ('PASS: trusted inventory ZIP, traversal/absolute/ADS/reserved/script/nested/duplicate rejection and cleanup. Evidence: '+$root)
