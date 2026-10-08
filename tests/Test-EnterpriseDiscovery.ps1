#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    $hostId=[Guid]::NewGuid().ToString()
    function script:Get-WindowsFeature {param($ErrorAction) foreach($name in @('AD-Domain-Services','DNS','DHCP','ADCS-Cert-Authority','Failover-Clustering','MSMQ','FS-DFS-Namespace','FS-DFS-Replication','Print-Server','RDS-RD-Server','UpdateServices')){[pscustomobject]@{Name=$name;Installed=($name -eq 'DNS')}}}
    function script:Get-Command {param($Name,$ErrorAction) if($Name -notin @('Get-DfsnRoot','Get-DfsrMembership','Get-NfsShare','Get-MsmqQueue','Get-DnsServerZone','Get-DhcpServerv4Scope','Get-WebBinding','Get-AppLockerPolicy')){throw ('Unexpected fixture capability query: '+$Name)}}
    function script:New-WsmComAdminCatalog {throw (New-Object UnauthorizedAccessException('fixture restricted COM+'))}
    function script:Get-WsmIisRedirectionText {'<configuration><configurationRedirection enabled="true" path="\\fixture\config" /></configuration>'}
    function script:Get-CimInstance {param($ClassName) if($ClassName -ne 'Win32_Service'){throw 'Unexpected real OS query'};[pscustomobject]@{Name='FixtureService'}}
    function script:Get-WsmServiceSecurity {param($Name) throw (New-Object UnauthorizedAccessException('fixture restricted service ACL'))}
    function script:New-WsmTaskScheduler {
        $folder=[pscustomobject]@{Path='\'};$folder | Add-Member ScriptMethod GetSecurityDescriptor {param($flags)'O:SYG:SYD:(A;;FA;;;SY)'};$folder | Add-Member ScriptMethod GetTasks {param($flags) @()};$folder | Add-Member ScriptMethod GetFolders {param($flags) @()}
        $scheduler=[pscustomobject]@{Folder=$folder};$scheduler | Add-Member ScriptMethod GetFolder {param($path)$this.Folder};$scheduler
    }
    function script:Get-ExecutionPolicy {param([switch]$List) [pscustomobject]@{Scope='MachinePolicy';ExecutionPolicy='AllSigned'}}
    $shallow=@(Get-WsmEnterpriseDiscovery $hostId)
    if(@($shallow | Where-Object Kind -EQ DiscoveryRequirement).Count -ne 1){throw 'Metadata mode hid deep discovery gap.'}
    $deep=@(Get-WsmEnterpriseDiscovery $hostId -Deep)
    if(@($deep | Where-Object {$_.Name -eq 'DNS' -and $_.Status -eq 'Partial'}).Count -ne 1){throw 'Installed dedicated role not preserved.'}
    if(@($deep | Where-Object {$_.Name -eq 'AD' -and $_.Status -eq 'NotInstalled'}).Count -ne 1){throw 'Successful absence query not recorded.'}
    if(@($deep | Where-Object {$_.Name -eq 'HyperV' -and $_.Status -eq 'Unsupported'}).Count -ne 1){throw 'Missing OS feature treated as absent.'}
    if(@($deep | Where-Object Status -EQ PermissionDenied).Count -ne 2){throw 'COM+/service permission failures misclassified.'}
    foreach($name in @('Get-DfsnRoot','Get-DfsrMembership','Get-NfsShare','Get-MsmqQueue','Get-DnsServerZone','Get-DhcpServerv4Scope')){if(@($deep | Where-Object {$_.Name -eq $name -and $_.Status -eq 'Unsupported'}).Count -ne 1){throw ('Missing product collector hidden: '+$name)}}
    if(@($deep | Where-Object Kind -EQ TaskFolderSecurity).Count -ne 1 -or @($deep | Where-Object Kind -EQ IisRedirection).Count -ne 1){throw 'Deep security/shared-config evidence omitted.'}
    Write-Host 'PASS: deep discovery boundaries, successful role absence, unknown OS feature, dedicated installed role, COM+/service access denial, unavailable product collectors, task folder ACL and shared IIS evidence.'
}
