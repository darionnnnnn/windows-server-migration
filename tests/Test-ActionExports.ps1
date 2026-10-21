#requires -Version 5.1
$ErrorActionPreference='Stop'
# Every action that the HTML console runs in a fresh worker runspace (Import-Module + Get-Command -CommandType Function) must map to an exported function;
# an unexported one fails only at run time (TargetLocalComparison and IndependentCopy did). Inline console handlers (Set-WsmHtml*) are not worker commands.
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$exported=@($module.ExportedFunctions.Keys)
$htmlMap=& $module {Get-WsmHtmlActionMap};$coreMap=& $module {Get-WsmOperationActions}
$names=New-Object 'System.Collections.Generic.List[string]'
foreach($key in @($htmlMap.Keys)){$value=$htmlMap[$key];if($value -is [array]){$names.Add([string]$value[1])}else{$names.Add([string]$value)}}
foreach($key in @($coreMap.Keys)){$names.Add([string]$coreMap[$key])}
$inline=@('Set-WsmHtmlRestoreChoice','Set-WsmHtmlSelection')
$missing=@($names|Sort-Object -Unique|Where-Object {$_ -and $inline -cnotcontains $_ -and $exported -cnotcontains $_})
if($missing.Count){throw ('Worker-run action commands are not exported: '+($missing -join ', '))}
if($names.Count -lt 150){throw 'Action maps were unexpectedly small; the export guard did not see the real maps.'}
# Runtime action defaults are submitted as operation arguments; every default key must be a real parameter of the mapped command
# (the Target Inventory defaults once carried Workspace, which Export-WsmInventory does not accept, so the submit returned 400).
$runtimeSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\WizardRuntime.ps1'))
$commandFor=@{};foreach($key in @($htmlMap.Keys)){$value=$htmlMap[$key];$commandFor[[string]$key]=$(if($value -is [array]){[string]$value[1]}else{[string]$value})};foreach($key in @($coreMap.Keys)){if(-not $commandFor.ContainsKey([string]$key)){$commandFor[[string]$key]=[string]$coreMap[$key]}}
$variableDefaults=@{};foreach($match in [regex]::Matches($runtimeSource,'\$(\w+Defaults)=@\{([^}]*)\}')){$variableDefaults[$match.Groups[1].Value]=$match.Groups[2].Value}
$checkedDefaults=0
foreach($match in [regex]::Matches($runtimeSource,'New-WsmWizardRuntimeAction ''(\w+)'' [^'']*''[^'']*'' (\$(\w+)|@\{([^}]*)\})')){
    $id=$match.Groups[1].Value;$body=if($match.Groups[3].Success -and $match.Groups[3].Value){$variableDefaults[$match.Groups[3].Value]}else{$match.Groups[4].Value};if(-not $body -or -not $commandFor.ContainsKey($id)){continue}
    $command=& $module ([scriptblock]::Create('param($n) Get-Command $n -CommandType Function -ErrorAction SilentlyContinue')) $commandFor[$id];if(-not $command){throw ('Runtime action '+$id+' maps to an unknown command '+$commandFor[$id]+'.')}
    foreach($keyMatch in [regex]::Matches($body,'(?:^|;)\s*(\w+)\s*=')){$name=$keyMatch.Groups[1].Value;$checkedDefaults++;if(-not $command.Parameters.ContainsKey($name)){throw ('Runtime action '+$id+' default '+$name+' is not a parameter of '+$command.Name+'.')}}
}
if($checkedDefaults -lt 3){throw 'Runtime action default guard did not find the default literals.'}
Write-Host ('PASS: '+@($names|Sort-Object -Unique).Count+' action commands resolve to exported functions (inline console handlers excluded).')
