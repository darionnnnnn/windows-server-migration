#requires -Version 5.1
$ErrorActionPreference='Stop'
$modulePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1'))
$module=Import-Module $modulePath -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-worker-isolation-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$guard=$null
try {
    $child=Join-Path $root 'child.ps1'
    $body=@'
param([string]$ModulePath,[string]$Workspace,[string]$Expected)
$ErrorActionPreference='Stop'
$m=Import-Module $ModulePath -Force -PassThru -DisableNameChecking
& $m {
    param($Workspace,$Expected)
    $migration=$null;$busy=$false
    try{$migration=Enter-WsmWorkspaceWorkerGuard -Workspace $Workspace -Action StartBackup}catch{if(-not $_.Exception.Data['WsmWorkspaceWorkerBusy']){throw};$busy=$true}finally{if($migration){Exit-WsmWorkspaceWorkerGuard $migration}}
    if($busy -ne ($Expected -ceq 'Busy')){throw 'A second process bypassed an active worker owner or failed to acquire a released lane.'}
    $probe=Enter-WsmWorkspaceWorkerGuard -Workspace $Workspace -Action DeveloperProbe
    try{if($probe.Lane -cne 'DeveloperProbe'){throw 'Probe did not acquire its independent lane.'}}finally{Exit-WsmWorkspaceWorkerGuard $probe}
} $Workspace $Expected
Write-Output ('PASS fresh process worker ownership: '+$Expected)
'@
    [IO.File]::WriteAllText($child,$body,(New-Object Text.UTF8Encoding($true)))
    $guard=& $module {param($Workspace)Enter-WsmWorkspaceWorkerGuard -Workspace $Workspace -Action StartBackup} $root
    foreach($engine in @('powershell.exe','pwsh.exe')){& $engine -NoProfile -File $child -ModulePath $modulePath -Workspace $root -Expected Busy;if($LASTEXITCODE -ne 0){throw 'Active worker ownership failed.'}}
    & $module {param($Guard)Exit-WsmWorkspaceWorkerGuard $Guard} $guard;$guard=$null
    foreach($engine in @('powershell.exe','pwsh.exe')){& $engine -NoProfile -File $child -ModulePath $modulePath -Workspace $root -Expected Free;if($LASTEXITCODE -ne 0){throw 'Released worker ownership failed.'}}
}finally{
    if($guard){& $module {param($Guard)Exit-WsmWorkspaceWorkerGuard $Guard} $guard}
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-worker-isolation-*'){throw 'Refusing cleanup outside owned worker fixture.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
