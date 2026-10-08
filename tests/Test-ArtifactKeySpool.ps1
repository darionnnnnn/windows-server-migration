#requires -Version 5.1
param([ValidateRange(10001,1000000)][int]$Entries=10001)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    param($Entries)
    $spool=New-WsmArtifactKeySpool;$scratch=$spool.Root
    try{for($n=0;$n -lt $Entries;$n++){Add-WsmArtifactKey $spool ('fixture|'+$n);if($spool.Buffer.Count -ge 5000){throw 'Artifact key buffer exceeded fixed bound'}};if($spool.Parts.Count -lt 2){throw 'External merge not exercised'};Assert-WsmArtifactKeysUnique $spool}finally{Remove-WsmKeySpool $spool}
    if([IO.Directory]::Exists($scratch)){throw 'Successful key validation leaked scratch'}
    $spool=New-WsmArtifactKeySpool;$scratch=$spool.Root
    try{Add-WsmArtifactKey $spool 'fixture|collision';for($n=0;$n -lt 10001;$n++){Add-WsmArtifactKey $spool ('fixture|'+$n)};Add-WsmArtifactKey $spool 'fixture|collision';$blocked=$false;try{Assert-WsmArtifactKeysUnique $spool}catch{if($_.Exception.Message -notmatch 'Duplicate/case-colliding'){throw};$blocked=$true};if(-not $blocked){throw 'Cross-part duplicate accepted'}}finally{Remove-WsmKeySpool $spool}
    if([IO.Directory]::Exists($scratch)){throw 'Rejected key validation leaked scratch'}
} $Entries
Write-Host ('PASS: '+$Entries+' artifact keys with fixed 5,000-key buffer, external merge, cross-part duplicates and scratch cleanup.')
