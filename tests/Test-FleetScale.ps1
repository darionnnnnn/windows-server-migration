#requires -Version 5.1
param([ValidateRange(1,10000)][int]$ItemsPerHost=200,[ValidateRange(1,10)][int]$Hosts=10)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-scale-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$workspace=Join-Path $root 'manager'; Initialize-WsmWorkspace $workspace | Out-Null
$clock=[Diagnostics.Stopwatch]::StartNew()
for ($h=1;$h -le $Hosts;$h++) {
    $source=[pscustomobject]@{ HostId=[Guid]::NewGuid().ToString(); Fingerprint=('{0:x64}' -f $h); Name=('old-'+$h) }
    $items=New-Object 'System.Collections.Generic.List[object]'
    for ($n=0;$n -lt $ItemsPerHost;$n++) { $items.Add((New-WsmItem $source.HostId Services Service ('service-'+$n) ([string]$n) @{ Path=('C:\Apps\'+$n+'\app.exe') })) }
    $inv=New-WsmInventory $source 1 $items.ToArray()
    $file=Join-Path $root ('host-'+$h+'.json'); [IO.File]::WriteAllText($file,($inv | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
    $c=Import-WsmInventory $workspace $file (Get-FileHash $file).Hash ('new-'+$h)
    $page=Get-WsmItems $workspace $c.PairId -Page 2 -PageSize 100
    if ($ItemsPerHost -gt 100 -and ($page.Total -ne $ItemsPerHost -or $page.Items.Count -ne [math]::Min(100,$ItemsPerHost-100))) { throw 'Pagination loses items.' }
    $csv=Join-Path $root ('review-'+$h+'.csv'); Export-WsmDecisions $workspace $c.PairId $csv
    $rows=@(Import-Csv $csv); foreach ($row in $rows) { $row.Decision='Exclude'; $row.Reason='synthetic scale test' }; $rows | Export-Csv $csv -NoTypeInformation -Encoding UTF8
    $c=Import-WsmDecisions $workspace $c.PairId $csv
    if (@($c.Items | Where-Object Decision -EQ Exclude).Count -ne $ItemsPerHost) { throw 'Bulk CSV lost decisions.' }
    Export-WsmReport $workspace $c.PairId (Join-Path $root ('host-'+$h+'.html'))
    Write-Host ('Host '+$h+'/'+$Hosts+' complete; '+$clock.Elapsed.TotalSeconds.ToString('0.0')+' seconds')
}
Export-WsmFleetReport $workspace (Join-Path $root 'fleet.html')
if (@((Get-WsmFleet $workspace).Pairs).Count -ne $Hosts) { throw 'Fleet lost host pairs.' }
$clock.Stop()
Write-Host ('PASS: '+($Hosts*$ItemsPerHost)+' items / '+$Hosts+' hosts; '+$clock.Elapsed.TotalSeconds.ToString('0.0')+' seconds. Evidence: '+$root)
