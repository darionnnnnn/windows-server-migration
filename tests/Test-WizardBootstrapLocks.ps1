#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-bootstrap-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$guard=$null
try {
    $migration=& $module {param($p)Enter-WsmWorkspaceWorkerGuard -Workspace $p -Action HtmlHistoryRecovery} $root
    & $module {param($g)Exit-WsmWorkspaceWorkerGuard $g} $migration
    $guard=& $module {param($p)Enter-WsmWorkspaceWorkerGuard -Workspace $p -Action DeveloperProbe} $root
    $before=(Get-FileHash -LiteralPath (Join-Path $root 'console-worker.lock')).Hash
    Initialize-WsmWizardWorkspace -Workspace $root -Role Manager|Out-Null
    $state=Get-WsmWizardState -Workspace $root -Role Manager
    if($state.Role -cne 'Manager'){throw 'First-use role was not saved.'}
    if((Get-FileHash -LiteralPath (Join-Path $root 'console-worker.lock')).Hash -cne $before){throw 'Bootstrap rewrote worker ownership metadata.'}
    $stillLocked=$false
    try{$unexpected=[IO.File]::Open((Join-Path $root 'console-probe-worker.lock'),'Open','ReadWrite','None');$unexpected.Dispose()}catch [IO.IOException]{$stillLocked=$true}
    if(-not $stillLocked){throw 'Bootstrap removed or replaced the live Probe lock.'}
    & $module {param($g)Exit-WsmWorkspaceWorkerGuard $g} $guard;$guard=$null
    foreach($name in @('console-worker.lock','console-probe-worker.lock')){
        $invalid=Join-Path $root ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $invalid $name))
        $rejected=$false
        try{Initialize-WsmWizardWorkspace -Workspace $invalid -Role Manager|Out-Null}catch{$rejected=$true}
        if(-not $rejected -or [IO.File]::Exists((Join-Path $invalid 'workspace-control/output-profile.json'))){throw 'A directory masquerading as a worker lock was adopted.'}
    }
    Write-Output 'PASS first-use role after actual startup worker guards; ownership metadata/live Probe exclusion preserved and lock directories rejected.'
} finally {
    if($guard){& $module {param($g)Exit-WsmWorkspaceWorkerGuard $g} $guard}
    $resolved=[IO.Path]::GetFullPath($root)
    if(-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-bootstrap-*'){throw 'Unsafe fixture cleanup path.'}
    if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
