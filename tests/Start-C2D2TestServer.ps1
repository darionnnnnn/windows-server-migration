param([Parameter(Mandatory)][string]$Workspace,[string]$PairId='',[ValidateSet('Source','Target','Manager')][string]$Role='Manager',[Parameter(Mandatory)][string]$ReadyPath,[Parameter(Mandatory)][string]$StopFile,[string]$ModulePath='')
$ErrorActionPreference='Stop'
if(-not $ModulePath){$ModulePath=Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1'}
# B5 test host: runs the real local console (real listener, real workers) on an already prepared workspace for the given role and pair.
$module=Import-Module $ModulePath -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
& $module {param($Workspace,$PairId,$Role,$ReadyPath,$StopFile) Start-WsmHtmlConsole -Workspace $Workspace -PairId $PairId -Role $Role -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile} $Workspace $PairId $Role $ReadyPath $StopFile
