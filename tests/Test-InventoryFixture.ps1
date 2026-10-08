#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-probes-'+[Guid]::NewGuid().ToString('N'))
# All operating-system probes are replaced within the test module scope.
& $module {
    function script:Get-WsmExtendedDiscovery { param($HostId) @() }
    function script:Get-WsmPreflight { [pscustomobject]@{ IsServer=$true; Administrator=$true; Is64Bit=$true; OS='Fixture Server'; Version='10.0.fixture' } }
    function script:Get-CimInstance { param($ClassName,$Filter)
        switch ($ClassName) {
            Win32_ComputerSystemProduct { [pscustomobject]@{ UUID='fixture-uuid' } }
            Win32_ComputerSystem { [pscustomobject]@{ Domain='fixture'; PartOfDomain=$false } }
            Win32_Service { [pscustomobject]@{ Name='fixture-service'; DisplayName='Fixture service'; PathName='C:\Fixture\svc.exe'; StartMode='Auto'; StartName='LocalSystem'; State='Running'; ServiceType='Own Process' } }
            default { @() }
        }
    }
    function script:Get-ItemProperty { param($Path,$ErrorAction) if ($Path -eq 'HKLM:\SOFTWARE\Microsoft\Cryptography') { [pscustomobject]@{ MachineGuid='fixture-machine-guid' } } else { @() } }
    function script:Get-ScheduledTask { param($ErrorAction) [pscustomobject]@{ TaskName='fixture'; TaskPath='\'; State='Ready' }; throw 'fixture task enumeration interrupted' }
    function script:Export-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) '<Task>synthetic fixture</Task>' }
    function script:Get-SmbShare { param($ErrorAction) @() }
    function script:Get-ChildItem { param($Path,[switch]$Recurse,$ErrorAction) if ($Path -like 'Cert:*') { @() } else { throw 'Unexpected filesystem probe in test' } }
    function script:Get-NetIPAddress { @() }
    function script:Get-DnsClientServerAddress { @() }
    function script:Get-NetRoute { @() }
    function script:Get-NetFirewallRule { param($PolicyStore,$ErrorAction) @() }
    function script:Get-WindowsFeature { param($ErrorAction) @() }
    function script:Test-Path { param($LiteralPath) if ($LiteralPath -like '*applicationHost.config') { return $false }; Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
}
[void][IO.Directory]::CreateDirectory($root)
# Force a ZIP destination collision after a valid JSON generation.
[IO.File]::WriteAllText((Join-Path $root 'inventory-1.zip'),'existing evidence')
$failed=$false; try { Export-WsmInventory $root | Out-Null } catch { $failed=$true }
if (-not $failed) { throw 'Archive collision silently succeeded.' }
$state1=Get-Content (Join-Path $root 'source-state.json') -Raw | ConvertFrom-Json
if ($state1.Revision -ne 1) { throw 'Valid JSON generation lost on ZIP failure.' }
$result=Export-WsmInventory $root
$state2=Get-Content (Join-Path $root 'source-state.json') -Raw | ConvertFrom-Json
if ($state1.HostId -cne $state2.HostId -or $state2.Revision -ne 2) { throw 'Retry changed source identity or reused evidence.' }
$inv=Get-Content $result.Path -Raw | ConvertFrom-Json
if (@($inv.Items | Where-Object Kind -EQ PathCandidate).Count -ne 1 -or $inv.CategorySummary.Count -ne 12) { throw 'Path candidates or parent classification summary missing.' }
if (@($inv.Items | Where-Object Kind -EQ ScheduledTask).Count -ne 1 -or @($inv.Items | Where-Object { $_.Category -eq 'Tasks' -and $_.Status -eq 'Failed' }).Count -ne 1) { throw 'Partial collector lost successful child or hid failure.' }
if (@($inv.Items | Where-Object Kind -EQ DiscoveryGap).Count -ne 12) { throw 'Discovery scope gaps omitted.' }
$zip=[IO.Compression.ZipFile]::OpenRead($result.Archive)
try { if ($zip.Entries.Count -ne 2 -or @($zip.Entries | Where-Object FullName -Like '*source-state*').Count) { throw 'Archive content incorrect.' } } finally { $zip.Dispose() }
if (@(Microsoft.PowerShell.Management\Get-ChildItem $root -Filter *.partial).Count) { throw 'Failed partial archive remains.' }
Write-Host ('PASS: collector partial failure, 12 scope gaps, stable retry identity and ZIP generation. Evidence: '+$root)
