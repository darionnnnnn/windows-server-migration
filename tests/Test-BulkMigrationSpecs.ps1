#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-bulk-spec-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);Initialize-WsmWorkspace $root | Out-Null
$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture'};$inv=New-WsmInventory $source 1 @();$path=Join-Path $root 'inventory.json';[IO.File]::WriteAllText($path,($inv | ConvertTo-Json -Depth 10));$c=Import-WsmInventory $root $path (Get-FileHash $path).Hash target
$a=Add-WsmManualItem $root $c.PairId External 'Fixture one' one owner evidence 0;$b=Add-WsmManualItem $root $c.PairId External 'Fixture two' two owner evidence 1
Set-WsmDecision $root $c.PairId @($a.ItemId,$b.ItemId) Include reviewed 2 | Out-Null
$bundlePath=Join-Path $root 'bundle.json';$draft=Export-WsmMigrationSpecBundle $root $c.PairId $bundlePath;if($draft.Selected -ne 2){throw 'Bulk selection omitted items'}
if(-not (Get-WsmMigrationSpecBundlePreview $root $c.PairId $bundlePath $draft.SHA256).Blocked){throw 'Incomplete draft accepted'}
$bundle=Get-Content -LiteralPath $bundlePath -Raw | ConvertFrom-Json;foreach($row in $bundle.Rows){$row.MigrationSpec.Owner='fixture reviewer';$row.MigrationSpec.Evidence='fixture per-item review';$row.MigrationSpec.Procedure='Fixture approved product procedure'}
$bundle.Rows[1].SettingsHash='bad';[IO.File]::WriteAllText($bundlePath,($bundle | ConvertTo-Json -Depth 30));$hash=(Get-FileHash $bundlePath).Hash
$blocked=$false;try{Import-WsmMigrationSpecBundle $root $c.PairId $bundlePath $hash 3 APPLY-SPECS | Out-Null}catch{$blocked=$true};if(-not $blocked -or (Get-WsmCatalog $root $c.PairId).DecisionRevision -ne 3){throw 'Invalid bulk partially committed'}
$itemIndex=@{};foreach($i in (Get-WsmCatalog $root $c.PairId).Items){$itemIndex[$i.ItemId]=$i};$bundle.Rows[1].SettingsHash=$itemIndex[$bundle.Rows[1].ItemId].SettingsHash;[IO.File]::WriteAllText($bundlePath,($bundle | ConvertTo-Json -Depth 30));$hash=(Get-FileHash $bundlePath).Hash
$preview=Get-WsmMigrationSpecBundlePreview $root $c.PairId $bundlePath $hash;if($preview.Blocked -or $preview.Selected -ne 2){throw 'Valid bulk preview failed'}
$result=Import-WsmMigrationSpecBundle $root $c.PairId $bundlePath $hash 3 APPLY-SPECS;if($result.DecisionRevision -ne 4 -or $result.Applied -ne 2){throw 'Bulk did not commit once'}
$blocked=$false;try{Import-WsmMigrationSpecBundle $root $c.PairId $bundlePath $hash 4 APPLY-SPECS | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Stale bundle re-applied'}
$current=Get-WsmCatalog $root $c.PairId;if(@($current.Items | Where-Object Decision -EQ Include).Count -ne 2 -or @($current.Items | Where-Object Owner -EQ 'fixture reviewer').Count -ne 2){throw 'Bulk changed decisions or lost reviewed owner'}
Write-Host ('PASS: bulk draft guard, complete selection, invalid row all-or-nothing, single revision commit, stale bundle refusal and retained decisions. Evidence: '+$root)
