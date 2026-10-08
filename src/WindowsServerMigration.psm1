Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolVersion = '0.1.0'
$script:Categories = @('System','Web','Tasks','Services','Runtime','Storage','Identity','Certificates','Database','Network','Roles','External')
foreach ($file in @('Core.ps1','Review.ps1','Reports.ps1','Inventory.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}
