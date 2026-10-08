#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$file=Join-Path ([IO.Path]::GetTempPath()) ('wsm-html-'+[Guid]::NewGuid().ToString('N')+'.html')
$rows=@(for ($n=0;$n -lt 205;$n++) { $category='Services'; if ($n -ge 200) { $category='Tasks' }; $name='item-'+$n; if ($n -eq 103) { $name='<script>alert(1)</script>' }; [pscustomobject][ordered]@{ Category=$category; Name=$name; Decision='Pending' } })
& $module { param($Path,$Rows) Write-WsmHtml $Path 'Synthetic report' $Rows } $file $rows
& node (Join-Path $PSScriptRoot 'Test-ReportDom.js') $file
if ($LASTEXITCODE -ne 0) { throw 'Report DOM checks failed.' }
& $module {
    $item=[pscustomobject]@{MigrationSpec=[pscustomobject]@{Adapter='ScheduledTask';CatchUpPolicy='SkipMissedRuns';DesiredFinalState='Enabled';Desired=[pscustomobject]@{Xml='<Task>fixture-secret-must-not-appear</Task>'};Owner='fixture';Evidence='reviewed'}}
    $summary=Get-WsmSafeSpecSummary $item
    if($summary -match 'fixture-secret-must-not-appear' -or $summary -notmatch 'SkipMissedRuns' -or $summary -notmatch 'DesiredSHA256'){throw 'Report exposed raw desired configuration or omitted reviewed policy/hash'}
    $item.MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='C:\Source';TargetPath='D:\Target';ExcludedRelativePaths=@('cache');Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='ReplaceOwned';AclControlPolicy='Exact'}
    $summary=Get-WsmSafeSpecSummary $item | ConvertFrom-Json
    if($summary.SourcePath -cne 'C:\Source' -or $summary.TargetPath -cne 'D:\Target' -or $summary.ExcludedRelativePaths[0] -cne 'cache' -or $summary.AclControlPolicy -cne 'Exact'){throw 'Owner report omitted material scope/ACL decisions'}
}
Write-Host 'PASS: owner report includes scope/exclusions/policy and desired hashes without raw secret-bearing configuration.'
