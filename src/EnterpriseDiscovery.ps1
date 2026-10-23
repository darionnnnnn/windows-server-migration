function Get-WsmMachineEnvironment { [Environment]::GetEnvironmentVariables('Machine') }
function Get-WsmHostsText { [IO.File]::ReadAllText((Join-Path $env:windir 'System32\drivers\etc\hosts')) }
function New-WsmComAdminCatalog { New-Object -ComObject COMAdmin.COMAdminCatalog }
function Get-WsmIisRedirectionText { $path=Join-Path $env:windir 'System32\inetsrv\config\redirection.config';if([IO.File]::Exists($path)){[IO.File]::ReadAllText($path)} }
function Get-WsmEnterpriseDiscovery([string]$HostId,[switch]$Deep) {
    function EnterpriseProbe([string]$Category,[string]$Name,[scriptblock]$Action){try{& $Action}catch{$status='Failed';if($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'Unauthorized|PermissionDenied'){$status='PermissionDenied'};New-WsmItem $HostId $Category CollectorFailure $Name ('enterprise:'+ $Name) @{ErrorType=$_.Exception.GetType().FullName} @() $status}}
    EnterpriseProbe Roles 'role-matrix' {
        $features=@(Get-WindowsFeature -ErrorAction Stop);$map=[ordered]@{'AD'='AD-Domain-Services';'DNS'='DNS';'DHCP'='DHCP';'CA'='ADCS-Cert-Authority';'Cluster'='Failover-Clustering';'MSMQ'='MSMQ';'DFSNamespace'='FS-DFS-Namespace';'DFSReplication'='FS-DFS-Replication';'Print'='Print-Server';'RDS'='RDS-RD-Server';'WSUS'='UpdateServices';'HyperV'='Hyper-V'}
        foreach($entry in $map.GetEnumerator()){$feature=@($features | Where-Object Name -CEQ $entry.Value);if($feature.Count -ne 1){New-WsmItem $HostId Roles RolePresence $entry.Key ('role:'+ $entry.Key) @{FeatureName=$entry.Value;RequiresDedicatedProcedure=$true;Detection='Feature unavailable on this OS; not evidence of absence'} @() Unsupported}elseif($feature[0].Installed){New-WsmItem $HostId Roles RolePresence $entry.Key ('role:'+ $entry.Key) @{FeatureName=$entry.Value;RequiresDedicatedProcedure=$true;Installed=$true} @() Partial}else{New-WsmItem $HostId Roles RolePresence $entry.Key ('role:'+ $entry.Key) @{FeatureName=$entry.Value;Installed=$false;Detection='Successful installed-feature query'} @() NotInstalled}}
    }
    if(-not $Deep){New-WsmItem $HostId Roles DiscoveryRequirement 'Deep enterprise/security inventory not requested' 'deep-discovery-required' @{NextStep='Run inventory with -DeepDiscovery for COM+, role objects, shared IIS and service/task ACL evidence';NotEvidenceOfAbsence=$true} @() Unsupported;return}
    EnterpriseProbe Runtime 'complus' {
        $catalog=New-WsmComAdminCatalog;$apps=$catalog.GetCollection('Applications');$apps.Populate();foreach($app in $apps){$components=$catalog.GetCollection('Components',$app.Key);$components.Populate();$rows=@(foreach($component in $components){[pscustomobject]@{Name=$component.Name;Key=[string]$component.Key;CLSID=[string]$component.Value('CLSID');DLL=[string]$component.Value('DLL')}});New-WsmItem $HostId Runtime ComPlusApplication $app.Name ([string]$app.Key) @{Name=$app.Name;Identity=[string]$app.Value('Identity');Components=$rows;RequiresExportInstallAndIdentityProcedure=$true} @() Partial}
    }
    EnterpriseProbe Storage 'dfs-and-nfs' {
        foreach($command in @('Get-DfsnRoot','Get-DfsrMembership','Get-NfsShare')){if(Get-Command $command -ErrorAction SilentlyContinue){$parameters=@{ErrorAction='Stop'};if($command -eq 'Get-DfsnRoot'){$parameters.Path='\\'+$env:COMPUTERNAME+'\*'};if($command -eq 'Get-DfsrMembership'){$parameters.ComputerName=$env:COMPUTERNAME;$parameters.GroupName='*'};foreach($entry in (& $command @parameters)){New-WsmItem $HostId Storage StorageRoleObject $command ($command+'|'+($entry | ConvertTo-Json -Depth 8 -Compress)) @{Command=$command;Configuration=$entry;RequiresProductProcedure=$true} @() Partial}}else{New-WsmItem $HostId Storage UnsupportedCollector $command ('collector:'+ $command) @{RequiredCommand=$command;DoesNotEstablishRoleAbsence=$true} @() Unsupported}}
    }
    EnterpriseProbe Database 'queue-and-database-tools' {
        foreach($command in @('Get-MsmqQueue')){if(Get-Command $command -ErrorAction SilentlyContinue){foreach($entry in (& $command -ErrorAction Stop)){New-WsmItem $HostId Database ProductObject $command ($command+'|'+($entry | ConvertTo-Json -Depth 8 -Compress)) @{Command=$command;Metadata=$entry;Consistency='Requires native backup/export and actual restore rehearsal'} @() Partial}}else{New-WsmItem $HostId Database UnsupportedCollector $command ('collector:'+ $command) @{RequiredCommand=$command;DoesNotEstablishProductAbsence=$true} @() Unsupported}}
    }
    EnterpriseProbe Roles 'dns-dhcp' {
        foreach($command in @('Get-DnsServerZone','Get-DhcpServerv4Scope')){if(Get-Command $command -ErrorAction SilentlyContinue){foreach($entry in (& $command -ErrorAction Stop)){New-WsmItem $HostId Roles ProductObject $command ($command+'|'+($entry | ConvertTo-Json -Depth 8 -Compress)) @{Command=$command;Metadata=$entry;RequiresNativeExportAndAuthorization=$true} @() Partial}}else{New-WsmItem $HostId Roles UnsupportedCollector $command ('collector:'+ $command) @{RequiredCommand=$command;DoesNotEstablishRoleAbsence=$true} @() Unsupported}}
    }
    EnterpriseProbe Web 'iis-shared-and-http' {
        $text=Get-WsmIisRedirectionText;if($null -ne $text){[void](Read-WsmXml $text);New-WsmItem $HostId Web IisRedirection 'IIS shared config redirection' 'iis-redirection' @{Xml=$text;EncryptionKeyTransferRequiresDedicatedProcedure=$true} @() Partial}else{New-WsmItem $HostId Web IisRedirection 'IIS redirection file absent' 'iis-redirection' @{SuccessfulFilePresenceCheck=$true} @() NotInstalled}
        if(Get-Command Get-WebBinding -ErrorAction SilentlyContinue){foreach($b in Get-WebBinding){New-WsmItem $HostId Web IisBinding ([string]$b.bindingInformation) ([string]$b.ItemXPath+'|'+[string]$b.protocol+'|'+[string]$b.bindingInformation) ($b | Select-Object protocol,bindingInformation,certificateHash,certificateStoreName,sslFlags) }}else{New-WsmItem $HostId Web UnsupportedCollector 'IIS binding API' 'collector:iis-binding' @{RequiredCommand='Get-WebBinding';DoesNotEstablishIisAbsence=$true} @() Unsupported}
        New-WsmItem $HostId Network DiscoveryRequirement 'HTTP.sys / WinHTTP / SPN / external endpoints' 'http-sys-and-external-review' @{Checks=@('HTTP.sys SSL and URL ACL registrations','WinHTTP proxy','SPNs and Kerberos delegation','DNS/PTR/load-balancer/allowlists','SMTP/API/UNC/DB clients','Certificate private-key ACL','External consumers and long-cycle jobs');OwnerConfirmationRequired=$true} @() Unsupported
    }
    EnterpriseProbe Identity 'service-and-task-security' {
        foreach($s in Get-CimInstance Win32_Service){try{$sddl=Get-WsmServiceSecurity $s.Name;New-WsmItem $HostId Identity ServiceSecurity $s.Name ('service-security:'+ $s.Name) @{ServiceName=$s.Name;Sddl=$sddl;SidMappingRequired=$true}}catch{$status='Failed';if($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'Unauthorized|PermissionDenied'){$status='PermissionDenied'};New-WsmItem $HostId Identity CollectorFailure $s.Name ('service-security:'+ $s.Name) @{ErrorType=$_.Exception.GetType().FullName} @() $status}}
        $scheduler=New-WsmTaskScheduler;$folders=New-Object 'System.Collections.Generic.Stack[object]';$folders.Push($scheduler.GetFolder('\'))
        while($folders.Count){$folder=$folders.Pop();New-WsmItem $HostId Identity TaskFolderSecurity $folder.Path ('task-folder:'+ $folder.Path) @{Path=$folder.Path;Sddl=$folder.GetSecurityDescriptor(7);SidMappingRequired=$true};foreach($t in $folder.GetTasks(1)){New-WsmItem $HostId Identity TaskSecurity $t.Path ('task-security:'+ $t.Path) @{Path=$t.Path;Sddl=$t.GetSecurityDescriptor(7);SidMappingRequired=$true}};foreach($f in $folder.GetFolders(0)){$folders.Push($f)}}
    }
    EnterpriseProbe System 'execution-deployment-policy' {
        $policies=@(Get-ExecutionPolicy -List | Select-Object Scope,ExecutionPolicy);$appLocker='CollectorUnavailable';if(Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue){$appLocker=Get-AppLockerPolicy -Effective -Xml};New-WsmItem $HostId System ExecutionPolicy 'Execution policy / effective AppLocker' 'deployment-policy' @{ExecutionPolicies=$policies;AppLockerXml=$appLocker;LanguageMode=[string]$ExecutionContext.SessionState.LanguageMode;WdacRequiresSecurityOwnerValidation=$true;NeverAutoChangesPolicy=$true} @() Partial
    }
}
function Export-WsmRawEvidenceManifest {
    param([string]$InventoryPath,[string]$ExpectedHash,[string]$Path)
    $i=Read-WsmTrustedJson $InventoryPath $ExpectedHash;Assert-WsmInventory $i
    $position=0;$rows=@(foreach($item in $i.Items){[pscustomobject]@{ItemId=$item.ItemId;Category=$item.Category;Kind=$item.Kind;Status=$item.Status;SettingsHash=$item.SettingsHash;EvidenceFile=[IO.Path]::GetFileName($InventoryPath);EvidencePointer=('/Items/'+$position+'/Settings');Collector=$item.Adapter;RawMayContainSecrets=$true};$position++})
    Write-WsmJson $Path ([pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='RawEvidenceManifest';Source=$i.Source;InventoryRevision=$i.Revision;InventoryHash=$ExpectedHash;CreatedUtc=$i.CreatedUtc;Items=$rows;Scope='All collected objects and explicit failures/gaps; not proof every external dependency was discovered'})
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($Path);SHA256=(Get-FileHash -LiteralPath $Path).Hash;Items=$rows.Count}
}

# ---- N9c: Source resolution context (D1 / R7-07) -------------------------------------------------
# The context is captured once on the Source host and stored in the inventory. Manager and Target
# resolve environment variables and relative paths ONLY from this stored context, never from the
# environment of the machine that happens to run the resolver. Capture is read-only: HKLM is opened
# for reading and no user hive (NTUSER.DAT / HKU) is loaded or written.
function Get-WsmResolutionSystemEnvironment {
    # Machine-wide values that Windows publishes as variables but does not keep under
    # HKLM\...\Session Manager\Environment. Derived from HKLM only.
    $result=[ordered]@{}
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
    try{
        $read={param($path,$name) $key=$base.OpenSubKey($path,$false);if(-not $key){return $null};try{$value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if($null -eq $value){$null}else{[string]$value}}finally{$key.Dispose()}}
        $systemRoot=& $read 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'SystemRoot'
        if($systemRoot){$result['SystemRoot']=$systemRoot;$result['windir']=$systemRoot;if($systemRoot -match '^([A-Za-z]:)'){$result['SystemDrive']=$Matches[1]}}
        foreach($pair in @(@('ProgramFiles','ProgramFilesDir'),@('ProgramFiles(x86)','ProgramFilesDir (x86)'),@('CommonProgramFiles','CommonFilesDir'),@('CommonProgramFiles(x86)','CommonFilesDir (x86)'),@('ProgramW6432','ProgramW6432Dir'),@('CommonProgramW6432','CommonW6432Dir'))){
            $value=& $read 'SOFTWARE\Microsoft\Windows\CurrentVersion' $pair[1];if($value){$result[$pair[0]]=$value}
        }
        $programData=& $read 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' 'ProgramData';if($programData){$result['ProgramData']=$programData}
    } finally {$base.Dispose()}
    $result
}
function Get-WsmResolutionProfileList {
    # SID -> ProfileImagePath (unexpanded). HKLM read-only; user hives are never touched.
    $map=[ordered]@{};$status='Success'
    try{
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
        try{
            $key=$base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList',$false)
            if(-not $key){$status='NotInstalled'}else{
                try{foreach($sid in $key.GetSubKeyNames()){if($sid -match '^S-1-\d+(-\d+)+$'){$p=$key.OpenSubKey($sid,$false);if($p){try{$value=$p.GetValue('ProfileImagePath',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if($value){$map[$sid]=[string]$value}}finally{$p.Dispose()}}}}}finally{$key.Dispose()}
            }
        } finally {$base.Dispose()}
    } catch {$status='Failed'}
    [pscustomobject]@{Status=$status;Map=$map}
}
function Resolve-WsmAccountToSid([string]$Account) {
    # Source-time only. Returns the SID string or $null when the account cannot be translated.
    try{
        $name=$Account;if($name.StartsWith('.\')){$name=[Environment]::MachineName+'\'+$name.Substring(2)}
        $nt=New-Object System.Security.Principal.NTAccount($name)
        return [string]$nt.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }catch{return $null}
}
function Get-WsmTaskPrincipalAccount([string]$TaskXml) {
    if([string]::IsNullOrWhiteSpace($TaskXml)){return ''}
    try{$doc=Read-WsmXml $TaskXml;$node=$doc.SelectSingleNode("//*[local-name()='Principal']/*[local-name()='UserId']");if($node){return ([string]$node.InnerText).Trim()}}catch{}
    ''
}
function Get-WsmWellKnownAccountSid([string]$Account) {
    $key=$Account.Trim().ToLowerInvariant()
    if($key -match '^s-1-\d+(-\d+)+$'){return $Account.Trim().ToUpperInvariant()}
    switch -Regex ($key){
        '^(localsystem|system|nt authority\\system)$' {return 'S-1-5-18'}
        '^(localservice|local service|nt authority\\local ?service)$' {return 'S-1-5-19'}
        '^(networkservice|network service|nt authority\\network ?service)$' {return 'S-1-5-20'}
    }
    $null
}
function Get-WsmSourceResolutionContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostId,[object[]]$Items=@())
    $observed=[DateTime]::UtcNow.ToString('o')
    $secretName='(?i)(password|passwd|pwd|secret|token|credential|api[_-]?key|connectionstring|private)'
    # 1) machine layer environment
    $environment=@{};$origin=@{};$machineStatus='Success';$excluded=New-Object System.Collections.Generic.List[string]
    try{foreach($entry in (Get-WsmMachineEnvironment).GetEnumerator()){$environment[[string]$entry.Key]=[string]$entry.Value;$origin[[string]$entry.Key]='MachineEnvironment'}}catch{$machineStatus='Failed'}
    try{foreach($entry in (Get-WsmResolutionSystemEnvironment).GetEnumerator()){if(-not $environment.ContainsKey([string]$entry.Key)){$environment[[string]$entry.Key]=[string]$entry.Value;$origin[[string]$entry.Key]='MachineSystem'}}}catch{if($machineStatus -eq 'Success'){$machineStatus='Partial'}}
    if(-not $environment.ContainsKey('COMPUTERNAME')){$name=[string]$env:COMPUTERNAME;if($name){$environment['COMPUTERNAME']=$name;$origin['COMPUTERNAME']='MachineSystem'}}
    $rows=New-Object System.Collections.Generic.List[object]
    foreach($name in @($environment.Keys | Sort-Object)){
        $value=[string]$environment[$name]
        if($name -match $secretName -or $value.Length -gt 2048){$excluded.Add($name);continue}
        $rows.Add([pscustomobject][ordered]@{Name=$name;Value=$value;Origin=[string]$origin[$name]})
    }
    # 2) account -> SID, from services (StartName) and scheduled-task principals
    $accounts=New-Object 'System.Collections.Generic.List[object]';$seen=@{}
    $note={param($account,$source)
        $account=([string]$account).Trim();if(-not $account){return}
        $key=$account.ToLowerInvariant();if($seen.ContainsKey($key)){$row=$seen[$key];if($row.Sources -cnotcontains $source){$row.Sources=@($row.Sources)+@($source)};return}
        $sid=Get-WsmWellKnownAccountSid $account;if(-not $sid){$sid=Resolve-WsmAccountToSid $account}
        $row=[pscustomobject][ordered]@{Account=$account;Sources=@($source);Sid=$sid;SidStatus=$(if($sid){'Resolved'}else{'Unresolved'});ProfileImagePath=$null;ProfileStatus=$(if($sid){'NoProfile'}else{'NotApplicable'})}
        $seen[$key]=$row;$accounts.Add($row)
    }
    foreach($item in @($Items)){
        if($null -eq $item -or -not $item.PSObject.Properties['Kind'] -or -not $item.PSObject.Properties['Settings']){continue}
        if($item.Kind -eq 'Service'){& $note (Get-WsmSoftwareSafeValue $item.Settings StartName) 'Service'}
        elseif($item.Kind -eq 'ScheduledTask'){& $note (Get-WsmTaskPrincipalAccount (Get-WsmSoftwareSafeValue $item.Settings Xml)) 'ScheduledTask'}
    }
    # 3) ProfileImagePath per account (HKLM ProfileList only)
    $profileList=Get-WsmResolutionProfileList
    foreach($row in $accounts){if($row.Sid -and $profileList.Map.Contains([string]$row.Sid)){$row.ProfileImagePath=[string]$profileList.Map[[string]$row.Sid];$row.ProfileStatus='Found'}elseif($row.Sid -and $profileList.Status -ne 'Success' -and $profileList.Status -ne 'NotInstalled'){$row.ProfileStatus='Unknown'}}
    [pscustomobject][ordered]@{
        SchemaVersion=1;Kind='SourceResolutionContext';HostId=$HostId;ObservedUtc=$observed
        MachineEnvironmentStatus=$machineStatus;MachineEnvironment=@($rows.ToArray());ExcludedEnvironmentNames=@($excluded.ToArray())
        ProfileListStatus=[string]$profileList.Status;Accounts=@($accounts.ToArray())
        Note='Captured read-only on the Source host (HKLM machine layer + ProfileList). User hives were not loaded.'
    }
}
function Get-WsmSourceResolutionContextHash($Context) {
    # Canonical text (not ConvertTo-Json) so the value is identical before and after a JSON round trip.
    if($null -eq $Context){return ''}
    $lines=New-Object System.Collections.Generic.List[string]
    $lines.Add('host='+[string]$Context.HostId);$lines.Add('observed='+[string]$Context.ObservedUtc);$lines.Add('envstatus='+[string]$Context.MachineEnvironmentStatus)
    foreach($row in @($Context.MachineEnvironment | Sort-Object Name)){$lines.Add('env|'+[string]$row.Name+'|'+[string]$row.Value+'|'+[string]$row.Origin)}
    foreach($name in @($Context.ExcludedEnvironmentNames | Sort-Object)){$lines.Add('excluded|'+[string]$name)}
    $lines.Add('profilelist='+[string]$Context.ProfileListStatus)
    foreach($row in @($Context.Accounts | Sort-Object Account)){$lines.Add('acct|'+[string]$row.Account+'|'+(@($row.Sources|Sort-Object) -join ',')+'|'+[string]$row.Sid+'|'+[string]$row.SidStatus+'|'+[string]$row.ProfileImagePath+'|'+[string]$row.ProfileStatus)}
    Get-WsmHashText ($lines -join "`n")
}
function Get-WsmInventorySourceResolutionContext($Inventory) {
    # Old inventories have no context; callers must then treat every variable/relative path as Unresolved.
    if($null -eq $Inventory){return $null}
    $property=$Inventory.PSObject.Properties['SourceResolutionContext'];if($property -and $null -ne $property.Value){return $property.Value}
    $null
}
function Get-WsmSourceAccountSid($Context,[string]$Account) {
    if($null -eq $Context -or [string]::IsNullOrWhiteSpace($Account)){return $null}
    foreach($row in @($Context.Accounts)){if(([string]$row.Account) -ieq $Account.Trim() -and $row.Sid){return [string]$row.Sid}}
    $null
}
function New-WsmSourcePathResolution([string]$Raw,$Resolved,[string]$Basis,[string[]]$Variables,[string]$Reason) {
    [pscustomobject][ordered]@{Raw=$Raw;Resolved=$Resolved;Basis=$Basis;Variables=@($Variables);Reason=$Reason}
}
function Resolve-WsmSourcePath {
    # Single resolver for environment variables and relative paths. Pure function of (Raw, Context,
    # AccountSid): it never reads the environment of the current process.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Raw,[AllowNull()]$Context,[AllowNull()][AllowEmptyString()][string]$AccountSid)
    if([string]::IsNullOrWhiteSpace($Raw)){return (New-WsmSourcePathResolution ([string]$Raw) $null 'Unresolved' @() 'EmptyPath')}
    $machine=$null;if($null -ne $Context -and $Context.PSObject.Properties['MachineEnvironment']){$machine=@{};foreach($row in @($Context.MachineEnvironment)){$machine[[string]$row.Name]=[string]$row.Value}}
    $systemSids=@('S-1-5-18','S-1-5-19','S-1-5-20')
    $profileRoot=$null;$profileState='NoAccount'
    if($AccountSid -and $null -ne $Context -and $Context.PSObject.Properties['Accounts']){
        $profileState='NoProfile'
        foreach($row in @($Context.Accounts)){if($row.Sid -and ([string]$row.Sid) -ieq $AccountSid -and $row.ProfileImagePath){$profileRoot=[string]$row.ProfileImagePath;$profileState='Found';break}}
    }
    $vars=New-Object System.Collections.Generic.List[string];$usedProfile=$false;$text=$Raw.Trim()
    $pattern='%([^%\\/:*?"<>|\r\n]+)%'
    $limit=0
    while($true){
        $m=[regex]::Match($text,$pattern);if(-not $m.Success){break}
        $limit++;if($limit -gt 64){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'ExpansionLimit')}
        $name=$m.Groups[1].Value;if(-not $vars.Contains($name)){$vars.Add($name)}
        $value=$null;$lower=$name.ToLowerInvariant()
        if($lower -in @('userprofile','appdata','localappdata')){
            if($null -eq $machine){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'NoSourceContext')}
            if($profileState -ne 'Found'){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) $(if($profileState -eq 'NoAccount'){'NoAccountForProfileVariable'}else{'AccountHasNoProfile'}))}
            # ProfileImagePath may itself reference machine variables (for example %SystemDrive%); expand with the stored machine layer only.
            $root=$profileRoot;$guard=0
            while($root -match $pattern){$guard++;if($guard -gt 16){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'ProfilePathNotResolvable')};$pm=[regex]::Match($root,$pattern);$pv=$null;foreach($key in @($machine.Keys)){if($key -ieq $pm.Groups[1].Value){$pv=$machine[$key];break}};if($null -eq $pv){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'ProfilePathNotResolvable')};$root=$root.Substring(0,$pm.Index)+$pv+$root.Substring($pm.Index+$pm.Length)}
            $root=$root.TrimEnd('\')
            if($lower -eq 'userprofile'){$value=$root}elseif($lower -eq 'appdata'){$value=$root+'\AppData\Roaming'}else{$value=$root+'\AppData\Local'}
            $usedProfile=$true
        } else {
            if($null -eq $machine){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'NoSourceContext')}
            # Machine TEMP/TMP belong to SYSTEM-level processes; for a real user account they would be that user's own values.
            if($lower -in @('temp','tmp') -and $AccountSid -and ($systemSids -cnotcontains $AccountSid.ToUpperInvariant())){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'UserScopedVariable')}
            foreach($key in @($machine.Keys)){if($key -ieq $name){$value=$machine[$key];break}}
            if($null -eq $value){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'VariableNotInSourceContext')}
        }
        $text=$text.Substring(0,$m.Index)+$value+$text.Substring($m.Index+$m.Length)
    }
    if($text -match '(^|[\\/])\.{1,2}([\\/]|$)'){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'ParentOrCurrentSegment')}
    if($text -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)'){return (New-WsmSourcePathResolution $Raw $null 'Unresolved' @($vars) 'RelativeOrNonAbsolutePath')}
    $basis='Literal';if($vars.Count){$basis=$(if($usedProfile){'ProfileDerived'}else{'Machine'})}
    New-WsmSourcePathResolution $Raw $text $basis @($vars) ''
}
