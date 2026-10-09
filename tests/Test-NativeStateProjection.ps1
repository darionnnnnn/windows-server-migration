#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -WarningAction SilentlyContinue
Add-Type -TypeDefinition 'public enum WsmProjectionAccess { Allow=0,Deny=1 } public enum WsmProjectionRight { Read=1,Full=2 }'
& $module {
    function Get-NetFirewallRule {param($Name,$ErrorAction)[pscustomobject]@{Name=$Name;Enabled='False';Direction='Inbound';Action='Allow';Profile='Domain'}}
    function Get-NetFirewallPortFilter {param([Parameter(ValueFromPipeline)]$InputObject)process{[pscustomobject]@{Protocol='TCP';LocalPort='443';RemotePort='Any';IcmpType='Any';DynamicTarget='Any';DynamicTransport='Any';CimClass=[pscustomobject]@{InternalMarker='native-management-metadata'}}}}
    function Get-NetFirewallAddressFilter {param([Parameter(ValueFromPipeline)]$InputObject)process{[pscustomobject]@{LocalAddress='Any';RemoteAddress='10.0.0.1';CimInstanceProperties=@('native-management-metadata')}}}
    function Get-NetFirewallApplicationFilter {param([Parameter(ValueFromPipeline)]$InputObject)process{[pscustomobject]@{Program='C:\fixture\app.exe';Package='Any';CimSystemProperties=[pscustomobject]@{InternalMarker='native-management-metadata'}}}}
    function Get-SmbShare {param($ErrorAction)[pscustomobject]@{Name='fixture-share';ScopeName='*';Path='C:\fixture\share';Description='Fixture';EncryptData=$true}}
    function Get-SmbShareAccess {param($Name,$ScopeName)[pscustomobject]@{Name=$Name;ScopeName=$ScopeName;AccountName='fixture\reader';AccessControlType=[WsmProjectionAccess]::Allow;AccessRight=[WsmProjectionRight]::Read;CimClass=[pscustomobject]@{InternalMarker='native-management-metadata'}}}
    $firewall=Get-WsmAdapterState ([pscustomobject]@{Adapter='FirewallRule';Desired=[pscustomobject]@{Name='fixture-rule'}})
    $share=Get-WsmAdapterState ([pscustomobject]@{Adapter='SmbShare';Desired=[pscustomobject]@{Name='fixture-share'}})
    $json=ConvertTo-Json -InputObject ([pscustomobject]@{Firewall=$firewall;Share=$share}) -Depth 10 -WarningAction Stop
    foreach($marker in @('CimClass','CimInstanceProperties','CimSystemProperties','native-management-metadata')){if($json.Contains($marker)){throw 'Native CIM management graph escaped the durable adapter-state projection.'}}
    $roundtrip=ConvertFrom-WsmJson $json
    if(-not $roundtrip.Firewall.Exists -or $roundtrip.Firewall.Enabled -cne 'False' -or $roundtrip.Firewall.Ports[0].LocalPort -cne '443' -or $roundtrip.Firewall.Addresses[0].RemoteAddress -cne '10.0.0.1' -or $roundtrip.Firewall.Applications[0].Package -cne 'Any'){throw 'Firewall operational state was lost during bounded serialization.'}
    if(-not $roundtrip.Share.Exists -or $roundtrip.Share.Configuration.Path -cne 'C:\fixture\share' -or $roundtrip.Share.Access[0].AccessControlType -cne 'Allow' -or $roundtrip.Share.Access[0].AccessRight -cne 'Read' -or $roundtrip.Share.Access[0].AccountName -cne 'fixture\reader'){throw 'Share ACL operational state or enum labels were lost during bounded serialization.'}
}
'PASS: bounded native firewall/share adapter states preserve operational fields and enum labels without serializing CIM management graphs.'
