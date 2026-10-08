#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$file=Join-Path ([IO.Path]::GetTempPath()) ('wsm-html-'+[Guid]::NewGuid().ToString('N')+'.html')
$largeFile=Join-Path ([IO.Path]::GetTempPath()) ('wsm-html-100k-'+[Guid]::NewGuid().ToString('N')+'.html')
$fleetFile=Join-Path ([IO.Path]::GetTempPath()) ('wsm-html-fleet-'+[Guid]::NewGuid().ToString('N')+'.html')
$textWorkspace=Join-Path ([IO.Path]::GetTempPath()) ('wsm-report-text-'+[Guid]::NewGuid().ToString('N'))
$textInventory=Join-Path ([IO.Path]::GetTempPath()) ('wsm-report-inventory-'+[Guid]::NewGuid().ToString('N')+'.json')
$textReport=Join-Path ([IO.Path]::GetTempPath()) ('wsm-report-text-'+[Guid]::NewGuid().ToString('N')+'.txt')
$rows=@(for ($n=0;$n -lt 205;$n++) { $category='Services'; if ($n -ge 200) { $category='Tasks' }; $name='item-'+$n; if ($n -eq 103) { $name='<script>alert(1)</script>' }; [pscustomobject][ordered]@{ Category=$category; Name=$name; Decision='Pending' } })
& $module { param($Path,$Rows) Write-WsmHtml $Path 'Synthetic report' $Rows } $file $rows
& $module { param($Path) $rows=New-Object 'System.Collections.Generic.List[object]';for($n=0;$n -lt 100000;$n++){$name='item-'+$n;if($n -eq 99999){$name='rare-final'}elseif(($n % 10) -eq 0){$name='hit-'+$n};$category='Services';if(($n % 2) -eq 1){$category='Tasks'};$decision='Pending';if(($n % 3) -eq 0){$decision='Include'}elseif(($n % 3) -eq 1){$decision='Exclude'};$rows.Add([pscustomobject][ordered]@{Category=$category;Name=$name;ItemId=('id-{0:d6}' -f $n);Decision=$decision})};Write-WsmHtml $Path '100k synthetic report' $rows.ToArray() } $largeFile
& $module { param($Path) $rows=@([pscustomobject][ordered]@{Source='source';Target='target';Pending=4;Included=2;Excluded=1});Write-WsmHtml $Path 'Fleet fixture' $rows } $fleetFile
& node (Join-Path $PSScriptRoot 'Test-ReportDom.js') $file $largeFile
if ($LASTEXITCODE -ne 0) { throw 'Report DOM checks failed.' }
if((Get-Content -Raw $fleetFile) -notmatch '"Pending":"N/A"' -or (Get-Content -Raw $fleetFile) -notmatch '"Include":"N/A"'){throw 'Fleet rows without Decision must report explicit N/A decision totals.'}
& $module {
    param($Workspace,$InventoryPath,$ReportPath)
    $hostId=[Guid]::NewGuid().ToString();$source=[pscustomobject][ordered]@{Name='fixture-source';HostId=$hostId;Fingerprint=('a'*64)}
    $items=@((New-WsmItem $hostId Services Service 'include-item' 'include'),(New-WsmItem $hostId Services Service 'exclude-item' 'exclude'),(New-WsmItem $hostId Services Service 'pending-item' 'pending'))
    $inventory=New-WsmInventory $source 1 $items;Write-WsmJson $InventoryPath $inventory;Initialize-WsmWorkspace $Workspace | Out-Null
    $hash=(Get-FileHash -LiteralPath $InventoryPath).Hash;Import-WsmInventory $Workspace $InventoryPath $hash 'fixture-target' | Out-Null
    $catalog=Get-WsmCatalog $Workspace (Get-WsmFleet $Workspace).Pairs[0].PairId
    $include=$catalog.Items | Where-Object Name -CEQ 'include-item';Set-WsmDecision $Workspace $catalog.PairId @($include.ItemId) Include 'include fixture' $catalog.DecisionRevision | Out-Null
    $catalog=Get-WsmCatalog $Workspace $catalog.PairId;$exclude=$catalog.Items | Where-Object Name -CEQ 'exclude-item';Set-WsmDecision $Workspace $catalog.PairId @($exclude.ItemId) Exclude 'exclude fixture' $catalog.DecisionRevision | Out-Null
    Export-WsmTextReport $Workspace $catalog.PairId $ReportPath
} $textWorkspace $textInventory $textReport
$textContent=Get-Content -Raw $textReport;if($textContent -notmatch '=== Services: 3 \| Include 1 \| Exclude 1 \| Pending 1 \| N/A 0 ==='){throw 'Text report category decision subtotal is incorrect.'}
& $module {
    $item=[pscustomobject]@{MigrationSpec=[pscustomobject]@{Adapter='ScheduledTask';CatchUpPolicy='SkipMissedRuns';DesiredFinalState='Enabled';Desired=[pscustomobject]@{Xml='<Task>fixture-secret-must-not-appear</Task>'};Owner='fixture';Evidence='reviewed'}}
    $summary=Get-WsmSafeSpecSummary $item
    if($summary -match 'fixture-secret-must-not-appear' -or $summary -notmatch 'SkipMissedRuns' -or $summary -notmatch 'DesiredSHA256'){throw 'Report exposed raw desired configuration or omitted reviewed policy/hash'}
    $item.MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='C:\Source';TargetPath='D:\Target';ExcludedRelativePaths=@('cache');Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='ReplaceOwned';AclControlPolicy='Exact'}
    $summary=Get-WsmSafeSpecSummary $item | ConvertFrom-Json
    if($summary.SourcePath -cne 'C:\Source' -or $summary.TargetPath -cne 'D:\Target' -or $summary.ExcludedRelativePaths[0] -cne 'cache' -or $summary.AclControlPolicy -cne 'Exact'){throw 'Owner report omitted material scope/ACL decisions'}
}
Write-Host 'PASS: owner report includes scope/exclusions/policy and desired hashes without raw secret-bearing configuration.'
Write-Host 'PASS: 100k offline report is chunked and fleet summary uses N/A for decision totals.'
Write-Host 'PASS: text report category subtotal counts Include, Exclude and Pending independently.'
