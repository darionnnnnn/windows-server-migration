#requires -Version 5.1
$ErrorActionPreference='Stop'
# Every HTML route block selected by "$route -match" must read its captures before any other -match/-notmatch overwrites $Matches.
# The TargetRestore resume route once checked the content-type with -notmatch first, so $Matches[1] became empty and every resume returned 404.
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\HtmlConsole.ps1'))
$lines=$source -split "`r?`n"
$checked=0;$problems=New-Object 'System.Collections.Generic.List[string]'
for($i=0;$i -lt $lines.Count;$i++){
    if($lines[$i] -notmatch 'elseif\(\$route -match ''[^'']*\(' ){continue}
    $checked++
    $routeLine=$lines[$i]
    $afterRoute=$routeLine.Substring($routeLine.IndexOf('){')+2)
    $text=$afterRoute
    for($j=$i+1;$j -lt [Math]::Min($lines.Count,$i+8);$j++){if($lines[$j] -match '^\s*elseif\(\$route'){break};$text+="`n"+$lines[$j]}
    $firstCapture=$text.IndexOf('$Matches[')
    if($firstCapture -lt 0){continue}
    $before=$text.Substring(0,$firstCapture)
    if($before -match '\s-(?:c|i)?(?:not)?match\s'){$problems.Add(('line '+($i+1)+': '+$routeLine.Trim().Substring(0,[Math]::Min(90,$routeLine.Trim().Length))))}
}
if($checked -lt 8){throw 'Route guard did not find the HTML route blocks.'}
if($problems.Count){throw ('Route captures read after another regex match: '+($problems -join ' | '))}
Write-Host ('PASS: '+$checked+' HTML route blocks read their $Matches captures before any later regex match.')
