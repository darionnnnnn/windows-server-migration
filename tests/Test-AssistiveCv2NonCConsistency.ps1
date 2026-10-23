#requires -Version 5.1
# N9h-D4 regression guard: in an OfflineFullSet CV2 plan a NonC-labelled FileScope is restored by the CV2 FileScope writer. The preview
# (Get-WsmAssistiveRestorePreview) and the executor (Invoke-WsmAssistiveRestore) must therefore make the SAME contract-version judgement, and every
# legacy NonC branch in both must be guarded by it. Before the fix the preview guarded the legacy branch (-not $cv2) while the executor did not, so the
# preview said Ready/RestoreNow and the executor failed the scope with "NonC result lost its exact-generation native readback".
# End-to-end proof is Test-G4MixedScope.ps1; this test is the fast structural guard plus the judgement truth table.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$script:Checks=0
function Check($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:Checks++}

# 1. The shared judgement.
$truth=& $module {
    @(
        [pscustomobject]@{Name='null plan';Value=(Test-WsmAssistivePlanContractV2 $null)}
        [pscustomobject]@{Name='no Assistive';Value=(Test-WsmAssistivePlanContractV2 ([pscustomobject]@{Items=@()}))}
        [pscustomobject]@{Name='Assistive without ContractVersion';Value=(Test-WsmAssistivePlanContractV2 ([pscustomobject]@{Assistive=[pscustomobject]@{PairId='x'}}))}
        [pscustomobject]@{Name='ContractVersion 1';Value=(Test-WsmAssistivePlanContractV2 ([pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=1}}))}
        [pscustomobject]@{Name='ContractVersion 2';Value=(Test-WsmAssistivePlanContractV2 ([pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=2}}))}
        [pscustomobject]@{Name='ContractVersion 2 as long';Value=(Test-WsmAssistivePlanContractV2 ([pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=[long]2}}))}
    )
}
$byName=@{};foreach($row in $truth){$byName[$row.Name]=$row.Value}
Check ($byName['null plan'] -eq $false -and $byName['no Assistive'] -eq $false -and $byName['Assistive without ContractVersion'] -eq $false -and $byName['ContractVersion 1'] -eq $false) 'only a plan with Assistive.ContractVersion 2 is CV2'
Check ($byName['ContractVersion 2'] -eq $true -and $byName['ContractVersion 2 as long'] -eq $true) 'ContractVersion 2 (int or long) is CV2'
Check ($truth.Count -eq 6 -and @($truth|Where-Object {$_.Value -isnot [bool]}).Count -eq 0) 'the judgement returns a strict boolean'

# 2. Structure: both functions use the judgement and guard every legacy NonC branch with it.
$path=Join-Path $repo 'src\AssistiveRestore.ps1'
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0) 'AssistiveRestore.ps1 parses'
function Get-FunctionText([string]$Name){
    $found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name},$true))
    Check ($found.Count -eq 1) ('exactly one function '+$Name)
    $found[0].Extent.Text
}
foreach($name in @('Get-WsmAssistiveRestorePreview','Invoke-WsmAssistiveRestore')){
    $text=Get-FunctionText $name
    Check ($text -match '\$cv2=Test-WsmAssistivePlanContractV2 \$[pP]ackage\.Plan') ($name+' takes its CV2 judgement from Test-WsmAssistivePlanContractV2')
    Check ($text -notmatch '\$cv2=\[bool\]') ($name+' has no private copy of the CV2 judgement')
    $branches=[regex]::Matches($text,"TransferChannel -eq 'NonC'[^\r\n]{0,40}")
    Check ($branches.Count -ge 1) ($name+' still contains a legacy NonC branch to guard')
    $unguarded=@($branches|Where-Object {$_.Value -notmatch "^TransferChannel -eq 'NonC' -and -not \`$cv2"})
    Check ($unguarded.Count -eq 0) ($name+' guards every legacy NonC branch with -not $cv2 (unguarded: '+(($unguarded|ForEach-Object {$_.Value}) -join ' | ')+')')
}
$executor=Get-FunctionText 'Invoke-WsmAssistiveRestore'
Check ([regex]::Matches($executor,"TransferChannel -eq 'NonC' -and -not \`$cv2").Count -eq 2) 'the executor guards both the reservation skip and the legacy NonC result branch'
Check ($executor.IndexOf('$cv2=Test-WsmAssistivePlanContractV2') -lt $executor.IndexOf("TransferChannel -eq 'NonC'")) 'the executor decides CV2 before its first NonC branch'
Write-Host ('PASS: {0} CV2 NonC consistency checks (judgement truth table, preview and executor share it, every legacy NonC branch guarded)' -f $script:Checks)
