function Get-WsmPreflight {
    $os=Get-CimInstance Win32_OperatingSystem
    $edition='Unknown';$installationType='Unknown';try{$version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop;if($version.PSObject.Properties['EditionID']){$edition=[string]$version.EditionID};if($version.PSObject.Properties['InstallationType']){$installationType=[string]$version.InstallationType}}catch{}
    $architecture='Unknown';if($env:PROCESSOR_ARCHITECTURE -eq 'AMD64'){$architecture='x64'}elseif($env:PROCESSOR_ARCHITECTURE -eq 'ARM64'){$architecture='Arm64'}
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    [pscustomobject]@{ PowerShellVersion=$PSVersionTable.PSVersion.ToString(); Is64Bit=[Environment]::Is64BitProcess; Administrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); IsServer=($os.ProductType -ne 1); OS=$os.Caption; Version=$os.Version;Build=[string]$os.BuildNumber;Edition=$edition;InstallationType=$installationType;Architecture=$architecture; InventoryOnly=$true; RestoreSupported=$false }
}
function Export-WsmInventory {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$OutputDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog,[ValidateRange(1,50000)][int]$MaxSoftwareEntries=10000,[string[]]$PortableRoot=@(),[string]$ManualEvidencePath,[string]$ManualEvidenceSha256)
    if(-not $IncludeSoftwareCatalog -and ($PortableRoot.Count -or $ManualEvidencePath -or $ManualEvidenceSha256)){throw 'Software evidence options require IncludeSoftwareCatalog.'}
    if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw 'Inventory requires FullLanguage; this tool does not change enterprise language policy.' }
    $pre=Get-WsmPreflight
    if (-not $pre.IsServer -or -not $pre.Administrator -or -not $pre.Is64Bit) { throw 'Run as administrator in 64-bit PowerShell on Windows Server.' }
    $root=[IO.Path]::GetFullPath($OutputDirectory)
    if (-not (Test-Path -LiteralPath $root)) { [void][IO.Directory]::CreateDirectory($root); Protect-WsmDirectory $root }
    Invoke-WsmLocked $root {
        $machine=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
        $uuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID
        $fingerprint=Get-WsmHashText ($machine+'|'+$uuid)
        $statePath=Join-Path $root 'source-state.json'
        if (Test-Path -LiteralPath $statePath) { $state=Read-WsmJson $statePath; if ($state.Fingerprint -cne $fingerprint) { throw 'Source identity changed; inspect cloned or moved state.' } }
        else { $state=[pscustomobject]@{ HostId=[Guid]::NewGuid().ToString(); Fingerprint=$fingerprint; Revision=0 }; Write-WsmJson $statePath $state }
        $items=New-Object System.Collections.Generic.List[object]
        $hostId=$state.HostId
        function Add-Probe([string]$Category,[scriptblock]$Probe) {
            try { & $Probe | ForEach-Object { $items.Add($_) } }
            catch { $status='Failed'; if ($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'Unauthorized|PermissionDenied') { $status='PermissionDenied' }; $items.Add((New-WsmItem $hostId $Category 'CollectorFailure' ($Category+' collector incomplete') ('probe:'+ $Category) @{ ErrorType=$_.Exception.GetType().FullName } @() $status)) }
        }
        Add-Probe System { New-WsmItem $hostId System Platform $env:COMPUTERNAME 'platform' @{ OS=$pre.OS; Version=$pre.Version; Architecture='x64'; ComputerSystem=(Get-CimInstance Win32_ComputerSystem | Select-Object Domain,PartOfDomain) } }
        if($IncludeSoftwareCatalog){
            Add-Probe System { New-WsmItem $hostId System TimeZone 'Time zone and DST baseline' 'timezone' (Get-WsmSettingTimeZoneSnapshot) }
            Add-Probe System { foreach($policy in @(Get-WsmSettingEffectivePolicySnapshot)){New-WsmItem $hostId System EffectivePolicy ([string]$policy.Name) ('effective-policy:'+ $policy.Name) $policy @() $(if($policy.Status -eq 'Success'){'Success'}else{'Partial'})} }
        }
        Add-Probe Services { foreach ($s in Get-CimInstance Win32_Service) {$settings=$s | Select-Object Name,DisplayName,Description,PathName,StartMode,StartName,ServiceType;$status='Success';try{$supplement=Get-WsmServiceSupplementState $s.Name;$settings | Add-Member NoteProperty Supplement $supplement;$settings | Add-Member NoteProperty SecuritySddl (Get-WsmServiceSecurity $s.Name)}catch{$status='Partial';$settings | Add-Member NoteProperty SupplementErrorType $_.Exception.GetType().FullName};New-WsmItem $hostId Services Service $s.DisplayName $s.Name $settings @() $status } }
        Add-Probe Tasks { Get-ScheduledTask -ErrorAction Stop | ForEach-Object { $t=$_;$settings=@{TaskName=$t.TaskName;TaskPath=$t.TaskPath;Xml=(Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop);TaskSecurityCaptureStatus='ReviewRequired'};$status='Success';try{$capture=Capture-WsmTaskSecurity ([string]$t.TaskPath) ([string]$t.TaskName);$settings.TaskSecurityCapture=$capture;$settings.TaskSecurityCaptureStatus='Captured'}catch{$status='Partial';if($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'Unauthorized|PermissionDenied'){$status='PermissionDenied'};$settings.TaskSecurityCaptureErrorType=$_.Exception.GetType().FullName};New-WsmItem $hostId Tasks ScheduledTask ($t.TaskPath+$t.TaskName) ($t.TaskPath+$t.TaskName) $settings @() $status } }
        Add-Probe Runtime { foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) { foreach ($a in Get-ItemProperty $key -ErrorAction Stop | Where-Object DisplayName) { New-WsmItem $hostId Runtime InstalledApplication $a.DisplayName $a.PSPath ($a | Select-Object DisplayName,DisplayVersion,Publisher,InstallLocation) } } }
        Add-Probe Storage { foreach ($s in Get-SmbShare -ErrorAction Stop) {$scope=[string]$s.ScopeName;$key=$s.Name;$status='Success';if($scope -and $scope -cne '*'){$key='scope:'+$scope+'|'+$s.Name;$status='Unsupported'};$accessArgs=@{Name=$s.Name;ErrorAction='Stop'};if($scope){$accessArgs.ScopeName=$scope};New-WsmItem $hostId Storage Share $s.Name $key @{Definition=($s | Select-Object Name,ScopeName,Path,Description,Special,EncryptData);Access=@(Get-SmbShareAccess @accessArgs | Select-Object Name,ScopeName,AccountName,@{Name='AccessControlType';Expression={[string]$_.AccessControlType}},@{Name='AccessRight';Expression={[string]$_.AccessRight}})} @() $status}; foreach ($v in Get-CimInstance Win32_Volume) { New-WsmItem $hostId Storage Volume ([string]$v.DeviceID) $v.DeviceID ($v | Select-Object DeviceID,DriveLetter,Label,FileSystem,Capacity) } }
        Add-Probe Identity { foreach ($u in Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True') { New-WsmItem $hostId Identity LocalUser $u.Name $u.SID ($u | Select-Object Name,SID,Disabled,Lockout) }; foreach ($g in Get-CimInstance Win32_Group -Filter 'LocalAccount=True') { New-WsmItem $hostId Identity LocalGroup $g.Name $g.SID @{ Name=$g.Name; SID=$g.SID; Members=@(Get-CimAssociatedInstance -InputObject $g -Association Win32_GroupUser | Select-Object Name,Domain,SID) } } }
        Add-Probe Certificates { foreach ($cert in Get-ChildItem Cert:\LocalMachine -Recurse -ErrorAction Stop | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509Certificate2] }) { New-WsmItem $hostId Certificates Certificate $cert.Subject ($cert.PSParentPath+'|'+$cert.Thumbprint) @{ Thumbprint=$cert.Thumbprint; Subject=$cert.Subject; Store=$cert.PSParentPath; HasPrivateKey=$cert.HasPrivateKey; NotAfter=$cert.NotAfter.ToUniversalTime().ToString('o') } } }
        Add-Probe Network {
            $networkItem=New-WsmItem $hostId Network IPConfiguration 'IP/DNS/routes' 'ipconfiguration' @{ Addresses=@(Get-NetIPAddress | Select-Object InterfaceAlias,IPAddress,PrefixLength,AddressFamily); DNS=@(Get-DnsClientServerAddress | Select-Object InterfaceAlias,AddressFamily,ServerAddresses); Routes=@(Get-NetRoute | Select-Object InterfaceAlias,DestinationPrefix,NextHop,RouteMetric) }
            $networkItem
            $firewallRuleCount=[long]0
            foreach ($r in Get-NetFirewallRule -PolicyStore ActiveStore -TracePolicyStore -ErrorAction Stop) {
                New-WsmItem $hostId Network FirewallRule $r.DisplayName $r.Name @{ Rule=($r | Select-Object Name,Enabled,Direction,Action,Profile,@{Name='PolicyStoreSourceType';Expression={[string]$_.PolicyStoreSourceType}}); Ports=@($r | Get-NetFirewallPortFilter -ErrorAction Stop | Select-Object Protocol,LocalPort,RemotePort,IcmpType,@{Name='DynamicTarget';Expression={[string]$_.DynamicTarget}},@{Name='DynamicTransport';Expression={[string]$_.DynamicTransport}}); Addresses=@($r | Get-NetFirewallAddressFilter -ErrorAction Stop | Select-Object LocalAddress,RemoteAddress); Applications=@($r | Get-NetFirewallApplicationFilter -ErrorAction Stop | Select-Object Program,Package) }
                $firewallRuleCount++
            }
            # A generic category scope gap does not invalidate this specific successful enumeration.
            # Leave this marker absent on any rule or filter failure, retaining partial inventory evidence.
            $networkItem.Settings.FirewallRuleEnumeration=[pscustomobject]@{PolicyStore='ActiveStore';TracePolicyStore=$true;EnumerationComplete=$true;RuleCount=$firewallRuleCount}
            $networkItem.SettingsHash=Get-WsmHashText ($networkItem.Settings | ConvertTo-Json -Depth 30 -Compress)
        }
        Add-Probe Roles { foreach ($f in Get-WindowsFeature -ErrorAction Stop | Where-Object Installed) { New-WsmItem $hostId Roles WindowsFeature $f.DisplayName $f.Name @{ Name=$f.Name; FeatureType=[string]$f.FeatureType } } }
        Add-Probe Web {
            $config=Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
            if (-not (Test-Path -LiteralPath $config)) { New-WsmItem $hostId Web IIS 'IIS not installed' 'iis' @{} @() NotInstalled }
            else {
                $xml=Read-WsmXml ([IO.File]::ReadAllText($config))
                foreach ($s in $xml.SelectNodes('/configuration/system.applicationHost/sites/site')) { New-WsmItem $hostId Web IISSite ([string]$s.name) ([string]$s.name) @{ Xml=$s.OuterXml } }
                foreach ($p in $xml.SelectNodes('/configuration/system.applicationHost/applicationPools/add')) { New-WsmItem $hostId Web IISPool ([string]$p.name) ([string]$p.name) @{ Xml=$p.OuterXml } }
                New-WsmItem $hostId Web IISGlobalConfig 'IIS global configuration' 'applicationHost.config' @{ Xml=$xml.OuterXml }
            }
        }
        Add-Probe External { Get-WsmExtendedDiscovery $hostId }
        Add-Probe Roles { Get-WsmEnterpriseDiscovery $hostId -Deep:$DeepDiscovery }
        $candidates=@(Get-WsmPathCandidates $hostId $items.ToArray()); foreach ($candidate in $candidates) { $items.Add($candidate) }
        foreach ($category in $script:Categories) { $items.Add((New-WsmItem $hostId $category DiscoveryGap ($category+' discovery scope requires owner confirmation') ('scope:'+ $category) @{ Note='This first-stage collector is not exhaustive. Confirm dependencies, files/ACLs, service recovery and triggers, task credentials, IIS modules/encryption, DNS/HTTP bindings, environment/ODBC/COM+, databases, AD/DHCP, clusters, queues, agents, licensing and external integrations.' } @() Unsupported)) }
        $depth='Metadata';if($DeepDiscovery){$depth='Deep'};$source=[pscustomobject]@{ HostId=$hostId; Fingerprint=$fingerprint; Name=$env:COMPUTERNAME; OS=$pre.OS; Version=$pre.Version; DiscoveryDepth=$depth }
        foreach($field in @('Build','Edition','InstallationType','Architecture')){$value='Unknown';if($pre.PSObject.Properties[$field]){$value=[string]$pre.$field};$source | Add-Member NoteProperty $field $value}
        $nextRevision=$state.Revision+1
        while (Test-Path -LiteralPath (Join-Path $root ('inventory-'+$nextRevision+'.json'))) { $nextRevision++ }
        $inventory=New-WsmInventory $source $nextRevision $items.ToArray()
        foreach ($item in $inventory.Items) { $item | Add-Member NoteProperty Classification (Get-WsmScopeClassification $item) }
        Assert-WsmInventory $inventory
        foreach ($item in $inventory.Items) { Assert-WsmScopeClassification $item | Out-Null }
        if($IncludeSoftwareCatalog){
            $software=Get-WsmSoftwareCatalog -Source $inventory -MaxEntries $MaxSoftwareEntries -PortableRoot $PortableRoot -ManualEvidencePath $ManualEvidencePath -ManualEvidenceSha256 $ManualEvidenceSha256
            Assert-WsmSoftwareCatalog $software -SourceInventory $inventory | Out-Null
            $inventory | Add-Member NoteProperty SoftwareCatalog $software
        }
        $path=Join-Path $root ('inventory-'+$inventory.Revision+'.json')
        if (Test-Path -LiteralPath $path) { throw 'Inventory path already exists; preserve evidence and inspect source state.' }
        Write-WsmJson $path $inventory
        $hash=(Get-FileHash -LiteralPath $path).Hash
        [IO.File]::WriteAllText(($path+'.sha256'),$hash,(New-Object Text.UTF8Encoding($false)))
        $state.Revision=$inventory.Revision; Write-WsmJson $statePath $state
        # Archive only this generation, never source-state.json or previous inventories.
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zipPath=Join-Path $root ('inventory-'+$inventory.Revision+'.zip')
        if (Test-Path -LiteralPath $zipPath) { throw 'Archive already exists; inspect interrupted generation.' }
        $tempZip=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.partial')
        try {
            $archive=[IO.Compression.ZipFile]::Open($tempZip,'Create')
            try {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$path,[IO.Path]::GetFileName($path))
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,($path+'.sha256'),[IO.Path]::GetFileName($path+'.sha256'))
            } finally { $archive.Dispose() }
            $archive=[IO.Compression.ZipFile]::OpenRead($tempZip)
            try {
                if ($archive.Entries.Count -ne 2) { throw 'Archive entry count mismatch.' }
                $entry=$archive.GetEntry([IO.Path]::GetFileName($path)); $stream=$entry.Open(); $sha=[Security.Cryptography.SHA256]::Create()
                try { $digest=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-',''); if ($digest -ine $hash) { throw 'Archive content hash mismatch.' } } finally { $stream.Dispose(); $sha.Dispose() }
            } finally { $archive.Dispose() }
            [IO.File]::Move($tempZip,$zipPath)
        } finally { if ([IO.File]::Exists($tempZip)) { [IO.File]::Delete($tempZip) } }
        $zipHash=(Get-FileHash -LiteralPath $zipPath).Hash
        [IO.File]::WriteAllText(($zipPath+'.sha256'),$zipHash,(New-Object Text.UTF8Encoding($false)))
        [pscustomobject]@{ Path=$path; SHA256=$hash; Archive=$zipPath; ArchiveSHA256=$zipHash; Items=$items.Count; Incomplete=@($inventory.Items | Where-Object Status -NE Success).Count; PayloadIncluded=$false }
    }
}
