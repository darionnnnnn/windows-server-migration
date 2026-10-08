Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ToolVersion = '0.2.0'
$script:Categories = @('System','Web','Tasks','Services','Runtime','Storage','Identity','Certificates','Database','Network','Roles','External')
foreach ($file in @('Core.ps1','AdvancedReview.ps1','Review.ps1','Reports.ps1','Inventory.ps1','Fleet.ps1','Discovery.ps1','Archive.ps1','Templates.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}
