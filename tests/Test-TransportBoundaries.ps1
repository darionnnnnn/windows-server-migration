#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    $one=[pscustomobject]@{Name='payload/fixture.blob';Bytes=1048000}
    $groups=@(Get-WsmZipMemberGroups @($one,$one) 1048576)
    if($groups.Count -ne 2 -or @($groups[0]).Count -ne 1){throw 'ZIP grouping lost single-member volume boundaries.'}
    $maximum=@(Get-WsmZipMemberGroups (@(1..9999 | ForEach-Object {$one})) 1048576)
    if($maximum.Count -ne 9999){throw 'Supported volume-count boundary was rejected.'}
    $rejected=$false;try{Get-WsmZipMemberGroups (@(1..10000 | ForEach-Object {$one})) 1048576 | Out-Null}catch{if($_.Exception.Message -notlike '*9999*'){throw};$rejected=$true}
    if(-not $rejected){throw '10000 synthetic volumes were not rejected before export.'}
    foreach($bytes in @(-1,1048576,[long]::MaxValue)){
        $rejected=$false;try{Get-WsmZipMemberGroups @([pscustomobject]@{Name='metadata.json';Bytes=$bytes}) 1048576 | Out-Null}catch{$rejected=$true}
        if(-not $rejected){throw 'Invalid or indivisible oversized member passed budget preflight.'}
    }
}
Write-Output 'Transport boundaries PASS (synthetic metadata; no large volumes written).'
