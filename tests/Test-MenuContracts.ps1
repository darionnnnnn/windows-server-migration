#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Start-ServerMigration.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
foreach($name in @('Read-MenuValue','Review-Pair')){$node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true);Invoke-Expression $node.Extent.Text}
$script:inputs=New-Object 'System.Collections.Generic.Queue[object]'
function Read-Host {param($Prompt)if(-not $script:inputs.Count){throw 'Unexpected menu prompt'};$script:inputs.Dequeue()}
$script:inputs.Enqueue('0');$cancel=$false;try{Read-MenuValue 'fixture' | Out-Null}catch [OperationCanceledException]{$cancel=$true};if(-not $cancel){throw 'Menu cancellation failed'}
$script:inputs.Enqueue('literal:0');if((Read-MenuValue 'fixture') -cne '0'){throw 'Literal zero lost'}
$script:inputs.Enqueue($null);$ended=$false;try{Read-MenuValue 'fixture' | Out-Null}catch [IO.EndOfStreamException]{$ended=$true};if(-not $ended){throw 'EOF did not stop menu'}
$script:views=New-Object 'System.Collections.Generic.List[object]';$Workspace='fixture-only'
function Get-WsmCategorySummary {param($Workspace,$PairId)}
function Get-WsmCatalog {param($Workspace,$PairId)[pscustomobject]@{}}
function Set-WsmReviewView {param($Workspace,$PairId,$Category,$Search,$Page,$PageSize,$Decision,$BuiltIn,$Group,$Sort)}
function Get-WsmItems {param($Workspace,$PairId,$Category,$Search,$Page,$PageSize,$Decision,$BuiltIn,$Group,$Sort)$script:views.Add([pscustomobject]@{Category=$Category;Search=$Search;Page=$Page;PageSize=$PageSize});[pscustomobject]@{Total=0;DecisionRevision=4;Items=@()}}
# Invalid size and cancellation midway through a filter retain the previous view.
foreach($value in @('f','new category','new search','invalid','f','other category','0','0')){$script:inputs.Enqueue($value)}
Review-Pair fixture
if($script:inputs.Count -or $script:views.Count -ne 3){throw 'Review did not stay in its submenu after error/cancellation'}
foreach($view in $script:views){if($view.Category -cne '' -or $view.Search -cne '' -or $view.Page -ne 1 -or $view.PageSize -ne 50){throw 'Cancelled/invalid filters partially changed review state'}}
Write-Host 'PASS: menu cancellation, literal zero, EOF, invalid input recovery and atomic filter editing.'
