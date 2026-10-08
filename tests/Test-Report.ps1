#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$file=Join-Path ([IO.Path]::GetTempPath()) ('wsm-html-'+[Guid]::NewGuid().ToString('N')+'.html')
$rows=@(for ($n=0;$n -lt 205;$n++) { $category='Services'; if ($n -ge 200) { $category='Tasks' }; $name='item-'+$n; if ($n -eq 103) { $name='<script>alert(1)</script>' }; [pscustomobject][ordered]@{ Category=$category; Name=$name; Decision='Pending' } })
& $module { param($Path,$Rows) Write-WsmHtml $Path 'Synthetic report' $Rows } $file $rows
& node (Join-Path $PSScriptRoot 'Test-ReportDom.js') $file
if ($LASTEXITCODE -ne 0) { throw 'Report DOM checks failed.' }
