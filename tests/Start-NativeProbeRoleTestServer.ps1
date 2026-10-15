param(
    [Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$StopFile,
    [Parameter(Mandatory)][string]$ModulePath
)
$ErrorActionPreference='Stop'
$module=Import-Module $ModulePath -Force -PassThru -DisableNameChecking
try {
    Initialize-WsmOutputWorkspace -WorkRoot $Workspace -Role $Role | Out-Null
    Start-WsmHtmlConsole -Workspace $Workspace -Role $Role -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile
} finally {
    if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue}
}
