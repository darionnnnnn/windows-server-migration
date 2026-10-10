#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-probes-'+[Guid]::NewGuid().ToString('N'))
# All operating-system probes are replaced within the test module scope.
& $module {
    function script:Get-WsmExtendedDiscovery { param($HostId) @() }
    function script:Get-WsmEnterpriseDiscovery { param($HostId,[switch]$Deep) @() }
    function script:Get-WsmServiceSupplementState {param($Name)throw 'Fixture supplemental SCM capture unavailable'}
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
    function script:Get-SmbShare { param($ErrorAction) [pscustomobject]@{Name='fixture-share';ScopeName='*';Path='C:\Fixture\share';Description='Fixture';Special=$false;EncryptData=$true} }
    function script:Get-SmbShareAccess {param($Name,$ScopeName,$ErrorAction)[pscustomobject]@{Name=$Name;ScopeName=$ScopeName;AccountName='fixture\reader';AccessControlType='Allow';AccessRight='Read';CimClass=[pscustomobject]@{ProbeOnly='native-management-metadata'};CimInstanceProperties=@('native-management-metadata');CimSystemProperties=[pscustomobject]@{Namespace='fixture-only'}}}
    function script:Get-ChildItem { param($Path,[switch]$Recurse,$ErrorAction) if ($Path -like 'Cert:*') { @() } else { throw 'Unexpected filesystem probe in test' } }
    function script:Get-NetIPAddress { @() }
    function script:Get-DnsClientServerAddress { @() }
    function script:Get-NetRoute { @() }
    function script:Get-NetFirewallRule { param($PolicyStore,[switch]$TracePolicyStore,$ErrorAction)
        if($PolicyStore -cne 'ActiveStore' -or -not $TracePolicyStore){throw 'Firewall inventory must trace the actual policy source.'}
        foreach($sourceType in @('Local','GroupPolicy','None')){[pscustomobject]@{Name=('fixture-'+$sourceType);DisplayName=('Fixture '+$sourceType);Enabled='True';Direction='Inbound';Action='Allow';Profile='Domain';PolicyStoreSourceType=$sourceType}}
    }
    function script:Get-NetFirewallPortFilter {param([Parameter(ValueFromPipeline)]$InputObject)process{[pscustomobject]@{Protocol='TCP';LocalPort='443';RemotePort='Any';IcmpType='Any';DynamicTarget='Any';DynamicTransport='Any';CimClass=[pscustomobject]@{ProbeOnly='native-management-metadata'}}}}
    function script:Get-NetFirewallAddressFilter {param([Parameter(ValueFromPipeline)]$InputObject)process{[pscustomobject]@{LocalAddress='Any';RemoteAddress='Any';CimInstanceProperties=@('native-management-metadata')}}}
    function script:Get-NetFirewallApplicationFilter {param([Parameter(ValueFromPipeline)]$InputObject)process{[pscustomobject]@{Program='C:\Fixture\app.exe';Package='Any';CimSystemProperties=[pscustomobject]@{Namespace='fixture-only'}}}}
    function script:Get-WindowsFeature { param($ErrorAction) @() }
    function script:Test-Path { param($LiteralPath) if ($LiteralPath -like '*applicationHost.config') { return $false }; Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
}
[void][IO.Directory]::CreateDirectory($root)
# Force a ZIP destination collision after a valid JSON generation.
[IO.File]::WriteAllText((Join-Path $root 'inventory-1.zip'),'existing evidence')
$failed=$false; try { Export-WsmInventory $root | Out-Null } catch { $failed=$true }
if (-not $failed) { throw 'Archive collision silently succeeded.' }
$state1=Get-Content (Join-Path $root 'source-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($state1.Revision -ne 1) { throw 'Valid JSON generation lost on ZIP failure.' }
$result=Export-WsmInventory $root
$state2=Get-Content (Join-Path $root 'source-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($state1.HostId -cne $state2.HostId -or $state2.Revision -ne 2) { throw 'Retry changed source identity or reused evidence.' }
$inv=Get-Content $result.Path -Raw -Encoding UTF8 | ConvertFrom-Json
if (@($inv.Items | Where-Object Kind -EQ PathCandidate).Count -ne 2 -or $inv.CategorySummary.Count -ne 12) { throw 'Path candidates or parent classification summary missing.' }
if (@($inv.Items | Where-Object Kind -EQ ScheduledTask).Count -ne 1) { throw 'Partial collector lost the successful scheduled-task child.' }
$taskCollectorFailure=@($inv.Items | Where-Object { $_.Category -eq 'Tasks' -and $_.Kind -eq 'CollectorFailure' -and $_.Status -eq 'Failed' -and $_.NaturalKey -eq 'probe:Tasks' })
if($taskCollectorFailure.Count -ne 1 -or $taskCollectorFailure[0].Settings.ErrorType -cne 'System.Management.Automation.RuntimeException'){throw 'Partial collector hid the original scheduled-task enumeration failure.'}
$capturedTask=@($inv.Items | Where-Object Kind -EQ ScheduledTask)[0]
if($capturedTask.Settings.Hidden -cne 'Unknown' -or $capturedTask.Settings.ObservedRuntime.State -cne 'Ready' -or $capturedTask.Settings.ObservedRuntime.PSObject.Properties['LastTaskResult']){throw 'Task optional properties or runtime state were inferred from an unavailable field.'}
[void][IO.Directory]::CreateDirectory((Join-Path $root 'task-folder-fixture'))
& $module {function script:Get-ScheduledTask { param($ErrorAction) [pscustomobject]@{ TaskName='fixture'; TaskPath='\'; State='Ready' } }}
$folderResult=Export-WsmInventory (Join-Path $root 'task-folder-fixture')
$folderInventory=Get-Content $folderResult.Path -Raw -Encoding UTF8 | ConvertFrom-Json
if(@($folderInventory.Items | Where-Object Kind -EQ ScheduledTask).Count -ne 1){throw 'Task folder probe failure hid a successful scheduled-task child.'}
$folderProbeEvidence=@($folderInventory.Items | Where-Object {$_.Category -eq 'Tasks' -and ($_.Kind -eq 'TaskFolder' -or ($_.Kind -eq 'CollectorFailure' -and $_.NaturalKey -eq 'task-folder-enumeration'))})
if($folderProbeEvidence.Count -lt 1){throw 'Task folder inventory neither captured folder security nor retained its platform/access gap.'}
if (@($inv.Items | Where-Object Kind -EQ DiscoveryGap).Count -ne 12) { throw 'Discovery scope gaps omitted.' }
$firewalls=@($inv.Items | Where-Object Kind -EQ FirewallRule)
if($firewalls.Count -ne 3){throw 'Traced firewall rules were lost during native inventory export.'}
foreach($rule in $firewalls){
    foreach($filter in @($rule.Settings.Ports)+@($rule.Settings.Addresses)+@($rule.Settings.Applications)){
        foreach($name in @('CimClass','CimInstanceProperties','CimSystemProperties')){if($filter.PSObject.Properties[$name]){throw 'Native management metadata escaped the bounded firewall projection.'}}
    }
    if($rule.Settings.Ports[0].LocalPort -cne '443' -or $rule.Settings.Ports[0].DynamicTransport -cne 'Any' -or $rule.Settings.Addresses[0].RemoteAddress -cne 'Any' -or $rule.Settings.Applications[0].Package -cne 'Any'){throw 'Bounded firewall projection lost operational fields.'}
}
$shares=@($inv.Items | Where-Object Kind -EQ Share)
if($shares.Count -ne 1 -or $shares[0].Settings.Access[0].AccountName -cne 'fixture\reader' -or $shares[0].Settings.Access[0].AccessRight -cne 'Read' -or $shares[0].Settings.Access[0].AccessControlType -cne 'Allow'){throw 'Bounded share projection lost access-control fields.'}
foreach($name in @('CimClass','CimInstanceProperties','CimSystemProperties')){if($shares[0].Settings.Access[0].PSObject.Properties[$name]){throw 'Native management metadata escaped the bounded share projection.'}}
& $module {param($Rules)
    foreach($entry in $Rules){$expected='Unknown';if($entry.Settings.Rule.PolicyStoreSourceType -ceq 'Local'){$expected='Local'}elseif($entry.Settings.Rule.PolicyStoreSourceType -ceq 'GroupPolicy'){$expected='GPO'};if((Get-WsmWindowsSettingControlSource $entry.Settings) -cne $expected){throw 'Native collector policy source did not reach the Windows review consumer.'}}
} $firewalls
& $module {param($Inventory)
    if(-not (Test-WsmWindowsTargetNetworkCaptureComplete $Inventory)){throw 'Complete native firewall enumeration with a generic category gap was rejected.'}
    $ip=@($Inventory.Items | Where-Object Kind -EQ IPConfiguration)[0]
    if($ip.Settings.FirewallRuleEnumeration.RuleCount -ne 3){throw 'Native enumeration count incorrect.'}
    if($ip.SettingsHash -cne (Get-WsmHashText ($ip.Settings | ConvertTo-Json -Depth 30 -Compress))){throw 'Enumeration metadata changed settings without refreshing its hash.'}
    $gap=@($Inventory.Items | Where-Object {$_.Category -ceq 'Network' -and $_.Kind -ceq 'DiscoveryGap'})[0]
    $gap.Status='Failed'
    if(Test-WsmWindowsTargetNetworkCaptureComplete $Inventory){throw 'Failed discovery gap was treated as a generic scope warning.'}
    $gap.Status='Unsupported';$gap.NaturalKey='unproven-firewall-coverage'
    if(Test-WsmWindowsTargetNetworkCaptureComplete $Inventory){throw 'Specific unresolved discovery gap was hidden by enumeration metadata.'}
    $gap.NaturalKey='scope:Network'
    $ip.Settings.FirewallRuleEnumeration.RuleCount=[long]4
    if(Test-WsmWindowsTargetNetworkCaptureComplete $Inventory){throw 'Mismatched native enumeration count accepted.'}
    $ip.Settings.FirewallRuleEnumeration.RuleCount=[long]3
    $ip.Status='Partial'
    if(Test-WsmWindowsTargetNetworkCaptureComplete $Inventory){throw 'Partial native network capture accepted.'}
} $inv
$zip=[IO.Compression.ZipFile]::OpenRead($result.Archive)
try { if ($zip.Entries.Count -ne 2 -or @($zip.Entries | Where-Object FullName -Like '*source-state*').Count) { throw 'Archive content incorrect.' } } finally { $zip.Dispose() }
if (@(Microsoft.PowerShell.Management\Get-ChildItem $root -Filter *.partial).Count) { throw 'Failed partial archive remains.' }
& $module {function script:Get-NetFirewallPortFilter {param([Parameter(ValueFromPipeline)]$InputObject)process{throw 'Fixture firewall filter capture interrupted'}}}
$partial=Export-WsmInventory $root
$partialInventory=Get-Content $partial.Path -Raw -Encoding UTF8 | ConvertFrom-Json
& $module {param($Inventory)
    $ip=@($Inventory.Items | Where-Object Kind -EQ IPConfiguration)[0]
    if($ip.Settings.PSObject.Properties['FirewallRuleEnumeration']){throw 'Interrupted native firewall capture published complete enumeration evidence.'}
    if(@($Inventory.Items | Where-Object {$_.Category -ceq 'Network' -and $_.Kind -ceq 'CollectorFailure'}).Count -ne 1){throw 'Interrupted firewall capture hid its failure.'}
    if(Test-WsmWindowsTargetNetworkCaptureComplete $Inventory){throw 'Interrupted native firewall capture allowed creation.'}
} $partialInventory
Write-Host ('PASS: collector partial failure, 12 scope gaps, stable retry identity and ZIP generation. Evidence: '+$root)
