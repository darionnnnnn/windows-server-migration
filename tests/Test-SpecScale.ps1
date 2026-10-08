#requires -Version 5.1
param([ValidateRange(1,10000)][int]$Items=10000)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Helper-Fixtures.ps1')
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-spec-scale-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);Initialize-WsmWorkspace $root | Out-Null
$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-scale'}
$rows=@(for($n=0;$n -lt $Items;$n++){$name='FixtureService'+$n;New-WsmItem $source.HostId Services Service $name $name ([ordered]@{Name=$name;DisplayName=$name;PathName='C:\Fixture\service.exe';StartMode='Manual';StartName='LocalSystem';Description='Fixture';Supplement=(New-WsmFixtureServiceSupplement)})})
$inventory=New-WsmInventory $source 1 $rows;$path=Join-Path $root 'inventory.json';[IO.File]::WriteAllText($path,($inventory | ConvertTo-Json -Depth 25));$c=Import-WsmInventory $root $path (Get-FileHash $path).Hash target
Set-WsmDecision $root $c.PairId @($c.Items | ForEach-Object ItemId) Include 'scale fixture reviewed' 0 | Out-Null
$watch=[Diagnostics.Stopwatch]::StartNew();$bundlePath=Join-Path $root 'specs.json';$draft=Export-WsmMigrationSpecBundle $root $c.PairId $bundlePath;$draftSeconds=$watch.Elapsed.TotalSeconds
$bundle=Get-Content $bundlePath -Raw | ConvertFrom-Json;foreach($row in $bundle.Rows){$row.MigrationSpec.Owner='fixture reviewer';$row.MigrationSpec.Evidence='fixture item reviewed'};[IO.File]::WriteAllText($bundlePath,($bundle | ConvertTo-Json -Depth 30));$hash=(Get-FileHash $bundlePath).Hash
$watch.Restart();$preview=Get-WsmMigrationSpecBundlePreview $root $c.PairId $bundlePath $hash;$previewSeconds=$watch.Elapsed.TotalSeconds;if($preview.Blocked -or $preview.Selected -ne $Items -or $preview.Sample.Count -gt 20 -or $preview.Errors.Count -gt 100){throw 'Large spec preview missing items/unbounded output'}
$watch.Restart();$result=Import-WsmMigrationSpecBundle $root $c.PairId $bundlePath $hash 1 APPLY-SPECS;$applySeconds=$watch.Elapsed.TotalSeconds;if($result.Applied -ne $Items -or $result.DecisionRevision -ne 2){throw 'Large batch not applied atomically once'}
$evidence=[pscustomobject]@{Synthetic=$true;Items=$Items;DraftSeconds=$draftSeconds;PreviewSeconds=$previewSeconds;ApplySeconds=$applySeconds;MaxSample=20;MaxErrors=100;PrivateBytes=[Diagnostics.Process]::GetCurrentProcess().PrivateMemorySize64;ProductionVerified=$false};[IO.File]::WriteAllText((Join-Path $root 'result.json'),($evidence | ConvertTo-Json))
Write-Host ('PASS: bulk spec scale '+$Items+'; draft '+[Math]::Round($draftSeconds,2)+'s / preview '+[Math]::Round($previewSeconds,2)+'s / atomic apply '+[Math]::Round($applySeconds,2)+'s. Synthetic only. Evidence: '+$root)
