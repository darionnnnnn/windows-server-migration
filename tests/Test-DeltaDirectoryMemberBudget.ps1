$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-DirectoryBudgetTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Get-WsmDeltaVolumeHash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
. (Join-Path $PSScriptRoot '..\src\DeltaVolumeTransport.ps1')
$limit=Get-WsmDeltaDirectoryMemberLimit
Assert-DirectoryBudgetTest ($limit -eq 100000) 'Directory member limit is not the explicit 100000-member budget.'
$synthetic=[array]::CreateInstance([object],10000)
Assert-DirectoryBudgetTest ((Assert-WsmDeltaDirectoryMemberBudget $synthetic) -eq 10000) 'A bounded 10000-member metadata fixture was rejected.'
$overLimit=[array]::CreateInstance([object],($limit+1));$blocked=$false;$message=''
try{Assert-WsmDeltaDirectoryMemberBudget $overLimit | Out-Null}catch{$blocked=$true;$message=$_.Exception.Message}
Assert-DirectoryBudgetTest ($blocked -and $message -match '100000 member budget') 'Directory transport did not reject member-count overflow with a bounded error.'
Write-Host 'Delta directory member budget checks passed.'