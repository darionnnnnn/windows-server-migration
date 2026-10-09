#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$files=@(Get-ChildItem (Join-Path $repo 'src') -File | Where-Object Extension -In @('.ps1','.psm1','.psd1'))+@(Get-ChildItem $PSScriptRoot -File -Filter '*.ps1')+@(Get-Item (Join-Path $repo 'Start-ServerMigration.ps1'))
$utf8=New-Object Text.UTF8Encoding($false,$true)
foreach($file in $files){
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    $text=$utf8.GetString($bytes)
    $hasBom=$bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    if($text -match '[^\x00-\x7f]' -and -not $hasBom){throw ('Non-ASCII script requires UTF-8 BOM for Windows PowerShell 5.1: '+$file.Name)}
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ('Script parse errors: '+$file.Name)}
}
Write-Host ('PASS: strict UTF-8, BOM for every non-ASCII script, and parsing across '+$files.Count+' runtime/test/entry files.')
