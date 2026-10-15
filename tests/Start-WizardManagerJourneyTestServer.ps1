param(
    [Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,
    [Parameter(Mandatory)][string]$WorkspaceRoot,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$StopFile
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

# TEST-ONLY native-identity and observation hooks are installed in the runner's
# private immutable copy of the product module. Keep this helper limited to
# starting the real local handler. Choosing the role in the UI creates the
# enrolled profile; no role profile, Target identity, inventory, or approval is
# written here.
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$roleRoot=Join-Path $WorkspaceRoot $Role
if(-not [IO.Directory]::Exists($roleRoot)){[void][IO.Directory]::CreateDirectory($roleRoot)}
if($env:WSM_RUNTIME_TEST_WORKROOT -and [IO.Path]::GetFullPath($env:WSM_RUNTIME_TEST_WORKROOT) -ine [IO.Path]::GetFullPath($roleRoot)){throw 'TEST-ONLY work-root environment does not match the selected role workspace.'}
$env:WSM_RUNTIME_TEST_WORKROOT=[IO.Path]::GetFullPath($roleRoot)
Start-WsmHtmlConsole -Workspace $roleRoot -Role $Role -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile
