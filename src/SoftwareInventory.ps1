Set-StrictMode -Version Latest

# B1 software evidence collector. Native access is confined to private snapshot
# helpers so fixed fixtures can exercise the same aggregation path.
function Get-WsmSoftwareUtc { [DateTime]::UtcNow.ToString('o') }
function Get-WsmSoftwareCaptureIdentity { Get-WsmMachineIdentity }
function Export-WsmSoftwareCatalogEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InventoryPath,[Parameter(Mandatory)][string]$ExpectedInventoryHash,[Parameter(Mandatory)][string]$Path)
    $inventory=Read-WsmTrustedJson $InventoryPath $ExpectedInventoryHash
    Assert-WsmInventory $inventory | Out-Null
    if(-not $inventory.PSObject.Properties['SoftwareCatalog']){throw 'Inventory has no captured SoftwareCatalog; capture it on the enrolled source host.'}
    Assert-WsmSoftwareCatalog $inventory.SoftwareCatalog -SourceInventory $inventory | Out-Null
    $output=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetDirectoryName($output)
    if(-not $parent){throw 'Choose a dedicated software evidence file.'}
    [void](New-WsmOutputOwnedDirectory $parent)
    Assert-WsmNoReparse $output
    Invoke-WsmLocked $parent {
        if([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)){throw 'Software evidence output already exists; choose a new file.'}
        Write-WsmJson $output $inventory.SoftwareCatalog
        [pscustomobject]@{Path=$output;SHA256=(Get-FileHash -LiteralPath $output).Hash.ToLowerInvariant();InventoryHash=$ExpectedInventoryHash.ToLowerInvariant();InventoryRevision=$inventory.Revision;SoftwareCount=@($inventory.SoftwareCatalog.Entries).Count;CoverageCount=@($inventory.SoftwareCatalog.Coverage).Count;NativeProbeExecuted=$false}
    }
}

function Get-WsmSoftwareRegistrySnapshot {
    [CmdletBinding()]
    param([ValidateSet('LocalMachine','User')][string]$Hive,[string]$Sid,[ValidateSet('Registry32','Registry64','Default')][string]$View,[string]$SubKey,[switch]$ReadNamedValues,[switch]$ReadEnvironmentValues,[ValidateRange(1,50000)][int]$MaxEntries=10000)
    $rows=New-Object System.Collections.Generic.List[object]
    $base=$null
    try {
        $hiveKind=[Microsoft.Win32.RegistryHive]::LocalMachine
        if($Hive -eq 'User'){$hiveKind=[Microsoft.Win32.RegistryHive]::Users}
        $registryView=[Microsoft.Win32.RegistryView]::Default
        if($View -eq 'Registry32'){$registryView=[Microsoft.Win32.RegistryView]::Registry32}
        elseif($View -eq 'Registry64'){$registryView=[Microsoft.Win32.RegistryView]::Registry64}
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveKind,$registryView)
        $path=$SubKey
        if($Hive -eq 'User'){$path=$Sid+'\'+$SubKey}
        $root=$base.OpenSubKey($path,$false)
        if($null -eq $root){return [pscustomobject]@{Status='NotInstalled';Rows=@();ErrorKind=$null}}
        try {
            $budgetExceeded=$false;$unreadableChild=$false
            if($ReadNamedValues){foreach($valueName in $root.GetValueNames()){if($rows.Count -ge $MaxEntries){$budgetExceeded=$true;break};if([string]::IsNullOrWhiteSpace($valueName) -or $valueName.Length -gt 256){continue};try{$value=[string]$root.GetValue($valueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if($value -and $value.Length -le 256 -and $value -notmatch '(?i)(password|pwd|secret|connectionstring|;|=)'){$rows.Add([pscustomobject]@{KeyName=$valueName;RegistryPath=($path+'\'+$valueName);Properties=[pscustomobject]@{DisplayName=$valueName;Driver=$value}})}}catch{}}}
            if($ReadEnvironmentValues){foreach($valueName in @('PATH','TEMP','TMP','USERPROFILE','APPDATA','LOCALAPPDATA','HOMEDRIVE','HOMEPATH')){try{$value=[string]$root.GetValue($valueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if($value -and $value.Length -le 2048 -and $value -notmatch '(?i)(password|pwd|secret|token)'){$rows.Add([pscustomobject]@{KeyName=$valueName;RegistryPath=($path+'\'+$valueName);Properties=[pscustomobject]@{DisplayName=$valueName;InstallLocation=$value}})}}catch{}}}
            $budgetExceeded=$false;$unreadableChild=$false
            foreach($name in $root.GetSubKeyNames()) {
                if($rows.Count -ge $MaxEntries){$budgetExceeded=$true;break}
                $key=$null
                try {
                    $key=$root.OpenSubKey($name,$false); if($null -eq $key){$unreadableChild=$true;continue}
                    $props=[ordered]@{}
                    foreach($field in @('DisplayName','DisplayVersion','Publisher','InstallLocation','InstallDate','ProductCode','Release','Version','InstallPath','Path','ProviderName','Description','FriendlyName','ProgID','VersionIndependentProgID','Driver','Setup')) {
                        try { $value=$key.GetValue($field,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); if($null -ne $value -and $value -is [string] -and $value.Length -le 2048){$props[$field]=[string]$value} } catch {}
                    }
                    try {$defaultValue=$key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if($defaultValue -is [string] -and $defaultValue.Length -le 512 -and $defaultValue -notmatch '(?i)(password|pwd|secret|connectionstring)\s*[:=]'){$props['DefaultValue']=$defaultValue}}catch{}
                    $rows.Add([pscustomobject]@{KeyName=$name;RegistryPath=($path+'\'+$name);Properties=[pscustomobject]$props})
                } catch {$unreadableChild=$true} finally {if($key){$key.Dispose()}}
            }
        } finally {$root.Dispose()}
        [pscustomobject]@{Status=$(if($budgetExceeded -or $unreadableChild){'Partial'}else{'Success'});Rows=@($rows.ToArray());ErrorKind=$(if($budgetExceeded){'EntryBudgetExceeded'}elseif($unreadableChild){'UnreadableRegistryChild'}else{$null})}
    } catch {
        $status='Failed';$kind=$_.Exception.GetType().FullName
        if($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'Unauthorized|PermissionDenied'){$status='PermissionDenied';$kind='AccessDenied'}
        [pscustomobject]@{Status=$status;Rows=@($rows.ToArray());ErrorKind=$kind}
    } finally {if($base){$base.Dispose()}}
}

function Get-WsmSoftwareProfileSnapshot {
    param([int]$MaxEntries=10000)
    $profiles=New-Object System.Collections.Generic.List[object]
    try {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
        $found=$false;try {$key=$base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList',$false);if($key){$found=$true;try{foreach($sid in $key.GetSubKeyNames()){if($sid -match '^S-1-5-21-(\d+-){3}\d+$'){$p=$key.OpenSubKey($sid);try{$path=[string]$p.GetValue('ProfileImagePath','');$profiles.Add([pscustomobject]@{SID=$sid;ProfilePath=$path})}finally{if($p){$p.Dispose()}}}}}finally{$key.Dispose()}}} finally{$base.Dispose()}
        $limited=$profiles.Count -gt $MaxEntries;if($limited){$profiles.RemoveRange($MaxEntries,$profiles.Count-$MaxEntries)}
        [pscustomobject]@{Status=$(if($limited){'Partial'}elseif($found){'Success'}else{'NotInstalled'});Rows=@($profiles.ToArray());ErrorKind=$(if($limited){'EntryBudgetExceeded'}else{$null})}
    } catch {$kind=$_.Exception.GetType().FullName;$status='Failed';if($_.Exception -is [UnauthorizedAccessException]){$status='PermissionDenied';$kind='AccessDenied'};[pscustomobject]@{Status=$status;Rows=@($profiles.ToArray());ErrorKind=$kind}}
}

function Get-WsmSoftwareLoadedUserSnapshot {
    param([int]$MaxEntries=10000)
    try {$sids=@([Microsoft.Win32.Registry]::Users.GetSubKeyNames() | Where-Object {$_ -match '^S-1-5-21-(\d+-){3}\d+$' -and $_ -notmatch '_Classes$'} | Sort-Object -Unique);$limited=$sids.Count -gt $MaxEntries;if($limited){$sids=@($sids | Select-Object -First $MaxEntries)};[pscustomobject]@{Status=$(if($limited){'Partial'}else{'Success'});Rows=@(foreach($sid in $sids){[pscustomobject]@{SID=[string]$sid}});ErrorKind=$(if($limited){'EntryBudgetExceeded'}else{$null})}}
    catch {$kind=$_.Exception.GetType().FullName;$status='Failed';if($_.Exception -is [UnauthorizedAccessException]){$status='PermissionDenied';$kind='AccessDenied'};[pscustomobject]@{Status=$status;Rows=@();ErrorKind=$kind}}
}

function Get-WsmSoftwarePortableSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[int]$MaxEntries=2000,[int]$MaxDepth=8,[long]$MaxMetadataBytes=2097152)
    $files=New-Object System.Collections.Generic.List[object];$gaps=New-Object System.Collections.Generic.List[object];$bytes=[long]0;$visited=0;$limited=$false
    try {$full=[IO.Path]::GetFullPath($Root);$rootItem=Get-Item -LiteralPath $full -Force -ErrorAction Stop;if(-not $rootItem.PSIsContainer){throw 'Portable root must be a directory.'};$ancestor=New-Object IO.DirectoryInfo($full);while($ancestor){if(($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Portable root has a reparse point in its path.'};$ancestor=$ancestor.Parent}}
    catch {return [pscustomobject]@{Status='Failed';Rows=@();Gaps=@([pscustomobject]@{Status='Failed';ErrorKind=$_.Exception.GetType().FullName});Count=0;MetadataBytes=0;Limited=$false}}
    $queue=New-Object 'System.Collections.Generic.Queue[object]';$queue.Enqueue([pscustomobject]@{Path=$full;Depth=0})
    while($queue.Count -gt 0) {
        $node=$queue.Dequeue()
        try {$childPaths=[IO.Directory]::EnumerateFileSystemEntries($node.Path);foreach($childPath in $childPaths) {
            if($visited -ge $MaxEntries -or $bytes -ge $MaxMetadataBytes){$limited=$true;break};$visited++
            try {$child=Get-Item -LiteralPath $childPath -Force -ErrorAction Stop} catch {$gaps.Add([pscustomobject]@{Status='PermissionDenied';ErrorKind='MetadataReadDenied';Path=$childPath});continue}
            if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$gaps.Add([pscustomobject]@{Status='Partial';ErrorKind='ReparsePointRejected';Path=$child.FullName});continue}
            if($child.PSIsContainer){if($node.Depth -lt $MaxDepth){$queue.Enqueue([pscustomobject]@{Path=$child.FullName;Depth=$node.Depth+1})}else{$limited=$true};continue}
            $ext=[IO.Path]::GetExtension($child.Name).ToLowerInvariant()
            if($ext -notin @('.exe','.dll','.msi','.ps1','.psm1','.py','.js','.cmd','.bat','.config','.json','.xml','.lock')){continue}
            $version='';$company='';$product=''
            if($ext -in @('.exe','.dll')){try{$vi=[Diagnostics.FileVersionInfo]::GetVersionInfo($child.FullName);$version=[string]$vi.FileVersion;$company=[string]$vi.CompanyName;$product=[string]$vi.ProductName}catch{}}
            $record=[pscustomobject]@{Name=[IO.Path]::GetFileNameWithoutExtension($child.Name);Version=$version;Publisher=$company;ProductName=$product;Path=$child.FullName;Length=[long]$child.Length;LastWriteUtc=$child.LastWriteTimeUtc.ToString('o');FileKind=$ext}
            $size=[Text.Encoding]::UTF8.GetByteCount(($record | ConvertTo-Json -Compress -Depth 4))
            if($bytes+$size -gt $MaxMetadataBytes){$limited=$true;break}
            $bytes+=$size;$files.Add($record)
        }} catch {$gaps.Add([pscustomobject]@{Status='PermissionDenied';ErrorKind='EnumerationDenied';Path=$node.Path})}
        if($limited){break}
    }
    if($limited){$gaps.Add([pscustomobject]@{Status='Partial';ErrorKind='BudgetExceeded';Path=$full})}
    [pscustomobject]@{Status=$(if($gaps.Count -or $limited){'Partial'}else{'Success'});Rows=@($files.ToArray());Gaps=@($gaps.ToArray());Count=$files.Count;VisitedEntries=$visited;MetadataBytes=$bytes;Limited=$limited}
}

function Get-WsmSoftwareModuleSnapshot {
    [CmdletBinding()]param([int]$MaxEntries=2000)
    try {
        $modules=@(Get-Module -ListAvailable -ErrorAction Stop | Select-Object -First ($MaxEntries+1) | ForEach-Object {[pscustomobject]@{Name=[string]$_.Name;Version=$_.Version.ToString();Publisher='';Path=[string]$_.ModuleBase;ManifestPath=[string]$_.Path}})
        $limited=$modules.Count -gt $MaxEntries;if($limited){$modules=@($modules | Select-Object -First $MaxEntries)}
        [pscustomobject]@{Status=$(if($limited){'Partial'}else{'Success'});Rows=$modules;ErrorKind=$(if($limited){'EntryBudgetExceeded'}else{$null});Count=$modules.Count;Budget=[pscustomobject]@{MaxEntries=$MaxEntries}}
    } catch {$status='Failed';$kind=$_.Exception.GetType().FullName;if($_.Exception -is [UnauthorizedAccessException]){$status='PermissionDenied';$kind='AccessDenied'};[pscustomobject]@{Status=$status;Rows=@();ErrorKind=$kind;Count=0;Budget=[pscustomobject]@{MaxEntries=$MaxEntries}}}
}

function Get-WsmSoftwareFileMetadataSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Path)
    try {
        $full=[IO.Path]::GetFullPath($Path);$item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return [pscustomobject]@{Status='Partial';Row=$null;ErrorKind='NotRegularFile'}}
        $version='';$publisher='';$product='';$ext=[IO.Path]::GetExtension($full).ToLowerInvariant()
        if($ext -in @('.exe','.dll')){try{$vi=[Diagnostics.FileVersionInfo]::GetVersionInfo($full);$version=[string]$vi.FileVersion;$publisher=[string]$vi.CompanyName;$product=[string]$vi.ProductName}catch{}}
        [pscustomobject]@{Status='Success';ErrorKind=$null;Row=[pscustomobject]@{Name=[IO.Path]::GetFileNameWithoutExtension($full);Version=$version;Publisher=$publisher;ProductName=$product;Path=$full;Length=[long]$item.Length;LastWriteUtc=$item.LastWriteTimeUtc.ToString('o');FileKind=$ext}}
    } catch {$status='Failed';$kind=$_.Exception.GetType().FullName;if($_.Exception -is [UnauthorizedAccessException]){$status='PermissionDenied';$kind='AccessDenied'};[pscustomobject]@{Status=$status;Row=$null;ErrorKind=$kind}}
}

function Get-WsmSoftwareAdjacentRuntimeSnapshot {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$ExecutablePath,[int]$MaxEntries=200,[long]$MaxMetadataBytes=1048576)
    $rows=New-Object System.Collections.Generic.List[object];$gaps=New-Object System.Collections.Generic.List[object];$bytes=[long]0;$limited=$false
    try {$exe=[IO.Path]::GetFullPath($ExecutablePath);$dir=[IO.Path]::GetDirectoryName($exe);$stem=[IO.Path]::GetFileNameWithoutExtension($exe)}catch{return [pscustomobject]@{Status='Failed';Rows=@();Gaps=@([pscustomobject]@{Status='Failed';ErrorKind='InvalidExecutablePath'});Count=0;MetadataBytes=0}}
    foreach($name in @(($stem+'.runtimeconfig.json'),($stem+'.deps.json'),'hostfxr.dll','coreclr.dll','clr.dll','jvm.dll','node.dll','python3.dll')) {
        if($rows.Count -ge $MaxEntries){$limited=$true;break};$path=Join-Path $dir $name
        if(-not [IO.File]::Exists($path)){continue}
        try {$item=Get-Item -LiteralPath $path -Force -ErrorAction Stop;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$gaps.Add([pscustomobject]@{Status='Partial';ErrorKind='ReparsePointRejected';Path=$path});continue};$ext=[IO.Path]::GetExtension($name).ToLowerInvariant()
            if($ext -eq '.dll'){$vi=[Diagnostics.FileVersionInfo]::GetVersionInfo($path);$rows.Add([pscustomobject]@{Name=([IO.Path]::GetFileNameWithoutExtension($name));Version=[string]$vi.FileVersion;Publisher=[string]$vi.CompanyName;Path=$path;EvidenceKind='AppLocalRuntimeBinaryMetadata';Length=[long]$item.Length});continue}
            $length=[long]$item.Length;if($bytes+$length -gt $MaxMetadataBytes){$limited=$true;$gaps.Add([pscustomobject]@{Status='Partial';ErrorKind='MetadataByteBudgetExceeded';Path=$path});break};$bytes+=$length
            $raw=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
            if($ext -eq '.json' -and $name -like '*.runtimeconfig.json'){$data=$raw | ConvertFrom-Json;$options=$data.runtimeOptions;if($options){foreach($fw in @($options.framework)+@($options.frameworks)){if($fw -and $fw.name){$rows.Add([pscustomobject]@{Name=[string]$fw.name;Version=[string]$fw.version;Publisher='';Path=$path;EvidenceKind='RuntimeConfigMetadata';Length=$length})}}}}
            elseif($ext -eq '.json' -and $name -like '*.deps.json'){$data=$raw | ConvertFrom-Json;$libs=$data.libraries;if($libs){foreach($p in @($libs.PSObject.Properties | Select-Object -First $MaxEntries)){if($rows.Count -ge $MaxEntries){$limited=$true;break};$parts=$p.Name -split '/',2;$rows.Add([pscustomobject]@{Name=[string]$parts[0];Version=$(if($parts.Count -gt 1){[string]$parts[1]}else{''});Publisher='';Path=$path;EvidenceKind='DepsMetadata';Length=$length})}}}
        } catch {$gaps.Add([pscustomobject]@{Status='Partial';ErrorKind=$_.Exception.GetType().FullName;Path=$path})}
    }
    if($limited){$gaps.Add([pscustomobject]@{Status='Partial';ErrorKind='EntryBudgetExceeded';Path=$dir})}
    [pscustomobject]@{Status=$(if($gaps.Count -or $limited){'Partial'}else{'Success'});Rows=@($rows.ToArray());Gaps=@($gaps.ToArray());Count=$rows.Count;MetadataBytes=$bytes}
}

function Get-WsmSoftwareNativeSnapshots {
    [CmdletBinding()]
    param([int]$MaxRegistryEntries=10000)
    $snapshots=New-Object System.Collections.Generic.List[object]
    foreach($view in @('Registry32','Registry64')) {
        $snap=Get-WsmSoftwareRegistrySnapshot LocalMachine '' $view 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -MaxEntries $MaxRegistryEntries
        if(@($snap.Rows).Count -gt $MaxRegistryEntries){$snap=[pscustomobject]@{Status='Partial';Rows=@($snap.Rows | Select-Object -First $MaxRegistryEntries);ErrorKind='EntryBudgetExceeded'}}
        $snapshots.Add([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View=$view;Snapshot=$snap})
        foreach($probe in @(
            [pscustomobject]@{Name='RuntimeMetadata';Path='SOFTWARE\Microsoft\NET Framework Setup\NDP'},
            [pscustomobject]@{Name='RuntimeMetadata';Path='SOFTWARE\dotnet\Setup\InstalledVersions'},
            [pscustomobject]@{Name='RuntimeMetadata';Path='SOFTWARE\JavaSoft\Java Runtime Environment'},
            [pscustomobject]@{Name='RuntimeMetadata';Path='SOFTWARE\JavaSoft\Java Development Kit'},
            [pscustomobject]@{Name='RuntimeMetadata';Path='SOFTWARE\Python\PythonCore'},
            [pscustomobject]@{Name='RuntimeMetadata';Path='SOFTWARE\nodejs'},
            [pscustomobject]@{Name='RuntimeMetadata';Path='SOFTWARE\PHP'},
            [pscustomobject]@{Name='ODBCDrivers';Path='SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers'},
            [pscustomobject]@{Name='ODBCMachineDSN';Path='SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources'},
            [pscustomobject]@{Name='COMOLEDBCandidates';Path='SOFTWARE\Classes\CLSID'},
            [pscustomobject]@{Name='COMOLEDBCandidates';Path='SOFTWARE\Microsoft\OLE DB\Providers'},
            [pscustomobject]@{Name='COMOLEDBCandidates';Path='SOFTWARE\Microsoft\MSDASQL\Providers'}
        )) {
            $probeLimit=$MaxRegistryEntries;if($probe.Name -eq 'COMOLEDBCandidates'){$probeLimit=[Math]::Min(200,$probeLimit)};$extra=Get-WsmSoftwareRegistrySnapshot LocalMachine '' $view $probe.Path -MaxEntries $probeLimit -ReadNamedValues:($probe.Name -in @('ODBCDrivers','ODBCMachineDSN'))
            if($probe.Name -eq 'COMOLEDBCandidates' -and @($extra.Rows).Count -gt 200){$extra=[pscustomobject]@{Status='Partial';Rows=@($extra.Rows | Select-Object -First 200);ErrorKind='CandidateBudgetExceeded'}}
            if(@($extra.Rows).Count -gt $MaxRegistryEntries){$extra=[pscustomobject]@{Status='Partial';Rows=@($extra.Rows | Select-Object -First $MaxRegistryEntries);ErrorKind='EntryBudgetExceeded'}}
            $snapshots.Add([pscustomobject]@{Probe=$probe.Name;Scope='Machine';SID='';View=$view;Snapshot=$extra})
        }
    }
    $modules=Get-WsmSoftwareModuleSnapshot -MaxEntries $MaxRegistryEntries
    $snapshots.Add([pscustomobject]@{Probe='PowerShellModules';Scope='CaptureContext';SID='';View='ModulePath';Snapshot=$modules})
    $profiles=Get-WsmSoftwareProfileSnapshot -MaxEntries $MaxRegistryEntries
    $loadedSnapshot=Get-WsmSoftwareLoadedUserSnapshot -MaxEntries $MaxRegistryEntries
    $loaded=@{}
    $snapshots.Add([pscustomobject]@{Probe='ProfileList';Scope='Machine';SID='';View='Registry64';Snapshot=$profiles;LoadedSids=@($loadedSnapshot.Rows | ForEach-Object {[string]$_.SID})})
    $snapshots.Add([pscustomobject]@{Probe='LoadedUserHives';Scope='User';SID='';View='HKU';Snapshot=$loadedSnapshot})
    foreach($loadedRow in @($loadedSnapshot.Rows)){$loaded[[string]$loadedRow.SID]=$true}
    foreach($sid in @($loaded.Keys | Sort-Object)) {
        foreach($view in @('Registry32','Registry64')) {
            foreach($probeInfo in @(
                [pscustomobject]@{Name='Uninstall';Path='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';ReadValues=$false},
                [pscustomobject]@{Name='ODBCUserDrivers';Path='SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers';ReadValues=$true},
                [pscustomobject]@{Name='ODBCUserDSN';Path='SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources';ReadValues=$true},
                [pscustomobject]@{Name='COMOLEDBCandidates';Path='SOFTWARE\Classes\CLSID';ReadValues=$false}
            )) {
                $limit=$MaxRegistryEntries;if($probeInfo.Name -eq 'COMOLEDBCandidates'){$limit=[Math]::Min(200,$limit)}
                $extra=Get-WsmSoftwareRegistrySnapshot User ([string]$sid) $view $probeInfo.Path -MaxEntries $limit -ReadNamedValues:$probeInfo.ReadValues
                $limit=$MaxRegistryEntries;if($probeInfo.Name -eq 'COMOLEDBCandidates'){$limit=[Math]::Min(200,$limit)}
                if(@($extra.Rows).Count -gt $limit){$extra=[pscustomobject]@{Status='Partial';Rows=@($extra.Rows | Select-Object -First $limit);ErrorKind='EntryBudgetExceeded'}}
                $snapshots.Add([pscustomobject]@{Probe=$probeInfo.Name;Scope='User';SID=[string]$sid;View=$view;Snapshot=$extra})
            }
        }
        $extra=Get-WsmSoftwareRegistrySnapshot User ([string]$sid) Default 'Environment' -ReadEnvironmentValues
        $snapshots.Add([pscustomobject]@{Probe='UserEnvironment';Scope='User';SID=[string]$sid;View='Default';Snapshot=$extra})
    }
    foreach($profile in @($profiles.Rows | Where-Object {-not $loaded.ContainsKey([string]$_.SID)})) {
        $status='NotTested';$reason='ProfileHiveNotLoaded'
        if($loadedSnapshot.Status -notin @('Success','NotInstalled')){$status=$loadedSnapshot.Status;$reason='LoadedHiveEnumerationIncomplete'}
        foreach($view in @('Registry32','Registry64')){$snapshots.Add([pscustomobject]@{Probe='Uninstall';Scope='User';SID=[string]$profile.SID;View=$view;Snapshot=[pscustomobject]@{Status=$status;Rows=@();ErrorKind=$reason}})}
    }
    # User DSNs are explicitly coverage-gapped for known unloaded profiles.
    foreach($profile in @($profiles.Rows | Where-Object { -not $loaded.ContainsKey([string]$_.SID) })){$notLoadedStatus='NotTested';$reason='ProfileHiveNotLoaded';if($loadedSnapshot.Status -notin @('Success','NotInstalled')){$notLoadedStatus='PermissionDenied';$reason='LoadedHiveEnumerationDenied'};foreach($probeName in @('ODBCUserDSN','ODBCUserDrivers','UserEnvironment','COMOLEDBCandidates')){$snapshots.Add([pscustomobject]@{Probe=$probeName;Scope='User';SID=[string]$profile.SID;View='Default';Snapshot=[pscustomobject]@{Status=$notLoadedStatus;Rows=@();ErrorKind=$reason}})}}
    $snapshots.ToArray()
}

function Get-WsmSoftwareSafeValue { param($Object,[string]$Name) if($null -eq $Object){return ''};if($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)){return [string]$Object[$Name]};$p=$Object.PSObject.Properties[$Name];if($p){return [string]$p.Value};'' }

function Get-WsmSoftwareStableId {
    param([string]$Scope,[string]$SID,[string]$View,[string]$Location,[string]$NaturalKey)
    $raw=($Scope+'|'+$SID+'|'+$View+'|'+$Location+'|'+$NaturalKey).ToLowerInvariant()
    'sw-'+(Get-WsmHashText $raw).Substring(0,32)
}

function Get-WsmSoftwareInventoryProjectionHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)
    Assert-WsmInventory $Inventory | Out-Null
    $projection=[ordered]@{
        Source=[ordered]@{HostId=(Get-WsmSoftwareSafeValue $Inventory.Source HostId);Fingerprint=(Get-WsmSoftwareSafeValue $Inventory.Source Fingerprint)}
        Revision=[int]$Inventory.Revision
        Items=@(foreach($item in @($Inventory.Items | Where-Object { -not (($_.PSObject.Properties['Present'] -and $_.Present -eq $false) -or ($_.PSObject.Properties['ManualEntry'] -and $_.ManualEntry -eq $true)) } | Sort-Object ItemId)){[ordered]@{ItemId=[string]$item.ItemId;Category=[string]$item.Category;Kind=[string]$item.Kind;NaturalKey=[string]$item.NaturalKey;SettingsHash=[string]$item.SettingsHash;Status=[string]$item.Status}})
    }
    Get-WsmHashText ($projection | ConvertTo-Json -Depth 40 -Compress)
}

function Get-WsmSoftwareCatalogProjectionHash {
    param([Parameter(Mandatory)]$Catalog)
    $projection=[ordered]@{SchemaVersion=[int]$Catalog.SchemaVersion;Kind=[string]$Catalog.Kind;ToolVersion=[string]$Catalog.ToolVersion;Source=$Catalog.Source;CaptureContext=$Catalog.CaptureContext;Entries=@($Catalog.Entries);Coverage=@($Catalog.Coverage);PreparationRequirements=@($Catalog.PreparationRequirements)}
    Get-WsmHashText ($projection | ConvertTo-Json -Depth 60 -Compress)
}

function Assert-WsmSoftwareCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)]$Catalog,[Parameter()][AllowNull()]$SourceInventory)
    process {
        Assert-WsmFields $Catalog @('SchemaVersion','ToolVersion','Kind','Source','CaptureContext','Entries','Coverage','PreparationRequirements','CatalogProjectionHash') @('SchemaVersion','ToolVersion','Kind','Source','CaptureContext','Entries','Coverage','PreparationRequirements','CatalogProjectionHash')
        if($Catalog.Kind -cne 'SoftwareCatalog' -or $Catalog.SchemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace([string]$Catalog.ToolVersion)){throw 'Software catalog kind, schema version, or tool version is invalid.'}
        if($null -eq $Catalog.Source -or [string]::IsNullOrWhiteSpace([string]$Catalog.Source.HostId) -or [string]::IsNullOrWhiteSpace([string]$Catalog.Source.Fingerprint)){throw 'Software catalog source binding is missing.'}
        Assert-WsmFields $Catalog.Source @('HostId','Fingerprint','Name','InventoryRevision','InventoryProjectionHash') @('HostId','Fingerprint','Name','InventoryRevision','InventoryProjectionHash')
        Assert-WsmId ([string]$Catalog.Source.HostId)
        if($Catalog.Source.Fingerprint -notmatch '^[a-f0-9]{64}$' -or $Catalog.Source.InventoryRevision -lt 1){throw 'Software source identity or revision is invalid.'}
        if([string]$Catalog.Source.InventoryProjectionHash -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Software catalog source projection hash is invalid.'}
        if([string]$Catalog.CatalogProjectionHash -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-WsmSoftwareCatalogProjectionHash $Catalog) -ine [string]$Catalog.CatalogProjectionHash){throw 'Software catalog projection hash is invalid.'}
        if($SourceInventory){Assert-WsmInventory $SourceInventory | Out-Null;if((Get-WsmSoftwareInventoryProjectionHash $SourceInventory) -ine [string]$Catalog.Source.InventoryProjectionHash -or $SourceInventory.Source.HostId -cne $Catalog.Source.HostId -or $SourceInventory.Source.Fingerprint -cne $Catalog.Source.Fingerprint -or $SourceInventory.Revision -ne $Catalog.Source.InventoryRevision){throw 'Software catalog does not bind to the supplied source inventory projection.'}}
        if($null -eq $Catalog.CaptureContext -or $null -eq $Catalog.CaptureContext.AccountContext){throw 'Capture context is missing.'}
        Assert-WsmFields $Catalog.CaptureContext @('CapturedUtc','CaptureIdentity','AccountContext','CaptureHost','PowerShellVersion','RequestedPortableRoots') @('CapturedUtc','CaptureIdentity','AccountContext','CaptureHost','PowerShellVersion','RequestedPortableRoots')
        if(@($Catalog.Entries).Count -gt 50000 -or @($Catalog.Coverage).Count -gt 100000 -or @($Catalog.CaptureContext.RequestedPortableRoots).Count -gt 128){throw 'Software evidence cardinality budget exceeded.'}
        $ids=@{};$allowedStatus=@('Success','Partial','PermissionDenied','Failed','NotInstalled','NotRequested','NotTested')
        foreach($row in @($Catalog.Entries)) {
            Assert-WsmFields $row @('SoftwareId','Name','Version','Publisher','Architecture','Scope','SID','RegistryView','Location','SourceKind','Evidence','ObservedUtc','CaptureStatus','ItemIds','AccountContext','Owner','EvidenceHash','ProvidedUtc') @('SoftwareId','Name','Version','Publisher','Architecture','Scope','SID','RegistryView','Location','SourceKind','Evidence','ObservedUtc','CaptureStatus','ItemIds','AccountContext')
            if($row.SoftwareId -cnotmatch '^sw-[a-f0-9]{32}$' -or $row.Scope -cnotin @('Machine','User','CaptureContext','Portable','ConsumerReference','AppLocal','OwnerProvided')){throw 'Software row identity or scope is invalid.'}
            foreach($field in @('SoftwareId','Name','Version','Publisher','Architecture','Scope','Location','SourceKind','CaptureStatus')){if(-not $row.PSObject.Properties[$field]){throw "Software row missing $field."}}
            if($row.Architecture -notin @('Unknown','x86','x64','Arm32','Arm64')){throw 'Software architecture value is invalid.'}
            if($row.CaptureStatus -notin @('Success','Partial','Manual')){throw 'Software row capture status is invalid.'}
            if($ids.ContainsKey([string]$row.SoftwareId)){throw 'SoftwareId collision detected.'};$ids[[string]$row.SoftwareId]=$true
            if($row.Evidence -isnot [string]){Assert-WsmFields $row.Evidence @('ManifestPath','Probe','RegistryPath','Driver','ProgID','ProviderName','NaturalKey','FileKind','Length','LastWriteUtc','ProductName','ItemId','ItemKind','InventoryStatus','FileMetadataStatus','EvidenceKind') @()}
            $serialized=$row | ConvertTo-Json -Compress -Depth 12
            if($serialized -match '(?i)"(?:UninstallString|QuietUninstallString|CommandLine|CommandArgs|Password|ConnectionString|DSNPassword|Secret)"\s*:|(?:pwd|password|secret)\s*='){throw 'Software catalog contains a prohibited command or secret field.'}
            if($row.SourceKind -eq 'OwnerProvided') {if((-not $row.Owner) -or (-not $row.Evidence) -or ([string]$row.EvidenceHash -notmatch '^[A-Fa-f0-9]{64}$') -or (-not $row.ProvidedUtc)){throw 'Owner-provided software requires owner, evidence, hash, and time.'};try{[void][DateTime]::Parse([string]$row.ProvidedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)}catch{throw 'Owner-provided timestamp is invalid.'}}
        }
        foreach($coverage in @($Catalog.Coverage)){Assert-WsmFields $coverage @('Probe','Scope','SID','View','Status','EvidenceKind','Count','Budget','ErrorKind','ObservedUtc','EvidenceHash','ItemId') @('Probe','Scope','SID','View','Status','EvidenceKind','Count','Budget','ErrorKind','ObservedUtc');if($coverage.Status -notin $allowedStatus -or $coverage.Count -lt 0){throw 'Coverage status or count is invalid.'};if(-not $coverage.Probe -or -not $coverage.Scope){throw 'Coverage probe identity is incomplete.'}}
        foreach($coverage in @($Catalog.Coverage)){Assert-WsmFields $coverage.Budget @('MaxEntries','MaxDepth','MaxMetadataBytes','VisitedEntries','MetadataBytes') @('MaxEntries');foreach($field in $coverage.Budget.PSObject.Properties){$number=[long]0;if(-not [long]::TryParse([string]$field.Value,[ref]$number) -or $number -lt 0){throw 'Coverage budget is not a nonnegative integer.'}}}
        if($null -eq $Catalog.PreparationRequirements){throw 'Preparation requirements projection is missing.'}
        $preparationIds=@{};$preparationBySoftware=@{};foreach($requirement in @($Catalog.PreparationRequirements)){Assert-WsmFields $requirement @('PreparationId','SoftwareId','Status','RequiredPhase','EvidenceStatus','ConsumerItemIds','Owner','Reason') @('PreparationId','SoftwareId','Status','RequiredPhase','EvidenceStatus','ConsumerItemIds','Owner','Reason');if(-not $ids.ContainsKey([string]$requirement.SoftwareId) -or $requirement.PreparationId -cne ('prep-'+([string]$requirement.SoftwareId).Substring(3)) -or $preparationIds.ContainsKey([string]$requirement.PreparationId) -or $requirement.Status -cne 'NeedsOwnerReview' -or $requirement.RequiredPhase -cne 'PreparationReady'){throw 'Software preparation projection has invalid identity or status.'};$preparationIds[[string]$requirement.PreparationId]=$true;$preparationBySoftware[[string]$requirement.SoftwareId]=$requirement}
        if($preparationIds.Count -ne $ids.Count){throw 'Software preparation projection omitted discovered software.'}
        foreach($row in @($Catalog.Entries)){$requirement=$preparationBySoftware[[string]$row.SoftwareId];if($requirement.EvidenceStatus -cne $row.CaptureStatus -or ((@($requirement.ConsumerItemIds | Sort-Object -Unique) -join '|') -cne (@($row.ItemIds | Sort-Object -Unique) -join '|'))){throw 'Software preparation projection changed evidence status or consumer closure.'}}
        $true
    }
}

function Get-WsmSoftwareCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [ValidateCount(0,128)][string[]]$PortableRoot=@(),
        [ValidateRange(1,50000)][int]$MaxEntries=10000,
        [ValidateRange(0,32)][int]$MaxDepth=8,
        [ValidateRange(1024,67108864)][long]$MaxMetadataBytes=4194304,
        [string]$ManualEvidencePath,
        [string]$ManualEvidenceSha256
    )
    Assert-WsmInventory $Source | Out-Null
    Assert-WsmMigrationHost (Get-WsmSoftwareCaptureIdentity) ([string]$Source.Source.Fingerprint)
    $entries=New-Object System.Collections.Generic.List[object];$coverage=New-Object System.Collections.Generic.List[object]
    $observed=(Get-WsmSoftwareUtc);$sourceHost=[string]$Source.Source.HostId;$profileEvidence=@()
    foreach($probe in @(Get-WsmSoftwareNativeSnapshots -MaxRegistryEntries $MaxEntries)) {
        $snap=$probe.Snapshot;$status=[string]$snap.Status
        $coverage.Add([pscustomobject]@{Probe=$probe.Probe;Scope=$probe.Scope;SID=$probe.SID;View=$probe.View;Status=$status;EvidenceKind='Registry';Count=@($snap.Rows).Count;Budget=[pscustomobject]@{MaxEntries=$MaxEntries};ErrorKind=$snap.ErrorKind;ObservedUtc=$observed})
        if($probe.Probe -eq 'ProfileList'){$profileEvidence=@($snap.Rows);continue}
        if($probe.Probe -eq 'LoadedUserHives'){continue}
        if($probe.Probe -ne 'Uninstall') {
            $sourceKind='RegistryMetadata';$category='Runtime'
            switch -Regex ([string]$probe.Probe) {'^ODBC.*Drivers$'{$sourceKind='ODBCDriver';$category='Runtime'} '^ODBC.*DSN$'{$sourceKind='ODBCDSN';$category='Runtime'} '^UserEnvironment$'{$sourceKind='UserEnvironment';$category='Runtime'} '^COMOLEDBCandidates$'{$sourceKind='COMOLEDBCandidate';$category='External'} '^PowerShellModules$'{$sourceKind='PowerShellModule';$category='Runtime'} }
            if($probe.Probe -eq 'PowerShellModules') {
                foreach($module in @($snap.Rows)){$loc=[string]$module.Path;$name=[string]$module.Name;$version=[string]$module.Version;if(-not $name){continue};$entries.Add([pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId 'CaptureContext' '' 'ModulePath' $loc ($name+'|'+$version));Name=$name;Version=$version;Publisher='';Architecture='Unknown';Scope='CaptureContext';SID='';RegistryView='';Location=$loc;SourceKind='PowerShellModule';Evidence=[pscustomobject]@{ManifestPath=[string]$module.ManifestPath;Probe='PowerShellModules'};ObservedUtc=$observed;CaptureStatus=$(if($status -eq 'Success'){'Success'}else{'Partial'});ItemIds=@();AccountContext='Unknown'})}
                continue
            }
            foreach($record in @($snap.Rows)) {
                $props=$record.Properties;$name=Get-WsmSoftwareSafeValue $props DisplayName
                if(-not $name){$name=Get-WsmSoftwareSafeValue $props FriendlyName};if(-not $name){$name=Get-WsmSoftwareSafeValue $props ProviderName};if(-not $name){$name=Get-WsmSoftwareSafeValue $props DefaultValue};if(-not $name){$name=[string]$record.KeyName};if(-not $name){continue}
                if($name -match '(?i)(password|pwd|secret|connectionstring)\s*[:=]'){continue}
                $location='registry:'+([string]$record.RegistryPath);$driver=Get-WsmSoftwareSafeValue $props Driver
                $entries.Add([pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId ([string]$probe.Scope) ([string]$probe.SID) ([string]$probe.View) $location $name);Name=$name;Version=(Get-WsmSoftwareSafeValue $props DisplayVersion);Publisher=(Get-WsmSoftwareSafeValue $props Publisher);Architecture='Unknown';Scope=[string]$probe.Scope;SID=[string]$probe.SID;RegistryView=[string]$probe.View;Location=$location;SourceKind=$sourceKind;Evidence=[pscustomobject]@{RegistryPath=[string]$record.RegistryPath;Probe=[string]$probe.Probe;Driver=$driver;ProgID=(Get-WsmSoftwareSafeValue $props ProgID);ProviderName=(Get-WsmSoftwareSafeValue $props ProviderName)};ObservedUtc=$observed;CaptureStatus=$(if($status -eq 'Success'){'Success'}else{'Partial'});ItemIds=@();AccountContext='Unknown'})
            }
            continue
        }
        foreach($record in @($snap.Rows)) {
            $props=$record.Properties;$name=Get-WsmSoftwareSafeValue $props DisplayName;if([string]::IsNullOrWhiteSpace($name)){continue}
            if($name -match '(?i)(password|pwd|secret|connectionstring)\s*[:=]'){$coverage.Add([pscustomobject]@{Probe='Uninstall';Scope=$probe.Scope;SID=$probe.SID;View=$probe.View;Status='Partial';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=$MaxEntries};ErrorKind='SensitiveMetadataOmitted';ObservedUtc=$observed});continue}
            $version=Get-WsmSoftwareSafeValue $props DisplayVersion;$publisher=Get-WsmSoftwareSafeValue $props Publisher;$location=Get-WsmSoftwareSafeValue $props InstallLocation
            if([string]::IsNullOrWhiteSpace($location)){$location='registry:'+([string]$record.RegistryPath)}
            $natural=[string]$record.KeyName+'|'+$name+'|'+$version
            $scope=[string]$probe.Scope;$sid=[string]$probe.SID
            $entries.Add([pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId $scope $sid ([string]$probe.View) $location $natural);Name=$name;Version=$version;Publisher=$publisher;Architecture='Unknown';Scope=$scope;SID=$sid;RegistryView=[string]$probe.View;Location=$location;SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath=[string]$record.RegistryPath;NaturalKey=[string]$record.KeyName};ObservedUtc=$observed;CaptureStatus=$(if($status -eq 'Success'){'Success'}else{'Partial'});ItemIds=@();AccountContext='Unknown'})
        }
    }
    # Keep profile discovery separate from the account executing this capture.
    $profileProbe=@($coverage | Where-Object Probe -EQ ProfileList | Select-Object -First 1)
    if($profileProbe.Count -and $profileProbe[0].Status -notin @('Success','NotInstalled')){$coverage.Add([pscustomobject]@{Probe='UserProfileDiscovery';Scope='User';SID='';View='Registry64';Status=$profileProbe[0].Status;EvidenceKind='ProfileList';Count=0;Budget=[pscustomobject]@{MaxEntries=$MaxEntries};ErrorKind=$profileProbe[0].ErrorKind;ObservedUtc=$observed})}

    $portableVisited=[int]0;$portableBytes=[long]0
    foreach($profile in $profileEvidence){$sid=[string]$profile.SID;if($sid -and -not @($coverage | Where-Object {$_.Probe -eq 'Uninstall' -and $_.Scope -eq 'User' -and $_.SID -eq $sid}).Count){$coverage.Add([pscustomobject]@{Probe='Uninstall';Scope='User';SID=$sid;View='Unknown';Status='NotTested';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=$MaxEntries};ErrorKind='ProfileCoverageMissing';ObservedUtc=$observed})}}
    foreach($root in $PortableRoot) {
        if([string]::IsNullOrWhiteSpace($root)){continue}
        $remainingEntries=[Math]::Max(0,$MaxEntries-$portableVisited);$remainingBytes=[Math]::Max([long]0,$MaxMetadataBytes-$portableBytes)
        if($remainingEntries -eq 0 -or $remainingBytes -eq 0){$snap=[pscustomobject]@{Status='Partial';Rows=@();Gaps=@([pscustomobject]@{Status='Partial';ErrorKind='BudgetExceeded';Path=$root});Count=0;VisitedEntries=0;MetadataBytes=0;Limited=$true}}
        else {$snap=Get-WsmSoftwarePortableSnapshot -Root $root -MaxEntries $remainingEntries -MaxDepth $MaxDepth -MaxMetadataBytes $remainingBytes}
        $visited=0;if($snap.PSObject.Properties['VisitedEntries']){$visited=[int]$snap.VisitedEntries}
        $portableVisited+=$visited;$metadataBytes=0;if($snap.PSObject.Properties['MetadataBytes']){$metadataBytes=[long]$snap.MetadataBytes};$portableBytes+=$metadataBytes
        $coverage.Add([pscustomobject]@{Probe='PortableFiles';Scope='Portable';SID='';View='Filesystem';Status=$snap.Status;EvidenceKind='FileMetadata';Count=$snap.Count;Budget=[pscustomobject]@{MaxEntries=$MaxEntries;VisitedEntries=$visited;MaxDepth=$MaxDepth;MaxMetadataBytes=$MaxMetadataBytes;MetadataBytes=$snap.MetadataBytes};ErrorKind=$(if($snap.Gaps.Count){$snap.Gaps[0].ErrorKind}else{$null});ObservedUtc=$observed})
        foreach($gap in @($snap.Gaps)){$coverage.Add([pscustomobject]@{Probe='PortableFiles';Scope='Portable';SID='';View='Filesystem';Status=$gap.Status;EvidenceKind='FileMetadata';Count=0;Budget=[pscustomobject]@{MaxEntries=$MaxEntries;VisitedEntries=$visited;MaxDepth=$MaxDepth;MaxMetadataBytes=$MaxMetadataBytes};ErrorKind=$gap.ErrorKind;ObservedUtc=$observed})}
        foreach($f in @($snap.Rows)){$entries.Add([pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId 'Portable' '' 'Filesystem' ([string]$f.Path) ([string]$f.Name+'|'+[string]$f.Version));Name=[string]$f.Name;Version=[string]$f.Version;Publisher=[string]$f.Publisher;Architecture='Unknown';Scope='Portable';SID='';RegistryView='';Location=[string]$f.Path;SourceKind='PortableEvidence';Evidence=[pscustomobject]@{FileKind=[string]$f.FileKind;Length=[long]$f.Length;LastWriteUtc=[string]$f.LastWriteUtc;ProductName=[string]$f.ProductName};ObservedUtc=$observed;CaptureStatus=$(if($snap.Status -eq 'Success'){'Success'}else{'Partial'});ItemIds=@();AccountContext='Unknown'})}
    }

    foreach($feature in @($Source.Items | Where-Object Kind -EQ WindowsFeature)) {
        $settings=$feature.Settings;$featureName=Get-WsmSoftwareSafeValue $settings Name;if(-not $featureName){$featureName=[string]$feature.Name}
        $entries.Add([pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId 'Machine' '' 'Inventory' ('inventory:'+([string]$feature.ItemId)) $featureName);Name=$featureName;Version='';Publisher='Microsoft';Architecture='Unknown';Scope='Machine';SID='';RegistryView='';Location=('inventory:'+([string]$feature.ItemId));SourceKind='InstalledRole';Evidence=[pscustomobject]@{ItemId=[string]$feature.ItemId;ItemKind=[string]$feature.Kind;InventoryStatus=[string]$feature.Status};ObservedUtc=$observed;CaptureStatus=$(if($feature.Status -eq 'Success'){'Success'}else{'Partial'});ItemIds=@([string]$feature.ItemId);AccountContext='Unknown'})
    }

    # Existing source inventory provides bounded consumer metadata; do not store command arguments.
    $consumerRuntimeBytes=[long]0
    foreach($item in @($Source.Items | Where-Object { $_.Kind -in @('Service','ScheduledTask','IISSite','IISPool','PathCandidate') })) {
        $safePath='';$settings=$item.Settings
        foreach($field in @('ExecutablePath','WorkingDirectory','ScriptPath','Path','ApplicationPath')){$v=Get-WsmSoftwareSafeValue $settings $field;if($v -and -not $safePath){$safePath=$v}}
        if($item.Kind -eq 'Service'){$raw=Get-WsmSoftwareSafeValue $settings PathName;if($raw){$safePath=([regex]::Match($raw,'^(?:"([^"]+\.exe)"|([^\s]+\.exe))',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Groups[1].Value;if(-not $safePath){$safePath=([regex]::Match($raw,'^(?:"([^"]+\.exe)"|([^\s]+\.exe))',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Groups[2].Value}}}
        if($item.Kind -eq 'ScheduledTask'){$taskText=Get-WsmSoftwareSafeValue $settings Xml;if($taskText -and $taskText -notmatch '(?i)(password|pwd|secret|token)\s*[:=]' -and $taskText -notmatch '<!DOCTYPE|<!ENTITY'){try{$taskXml=[xml]$taskText;$commandNode=$taskXml.SelectSingleNode("//*[local-name()='Command']");if($commandNode){$command=[Environment]::ExpandEnvironmentVariables([string]$commandNode.InnerText);if([IO.Path]::IsPathRooted($command)){$safePath=$command}}}catch{}}}
        if($item.Kind -eq 'IISSite'){$siteText=Get-WsmSoftwareSafeValue $settings Xml;if($siteText -and $siteText -notmatch '(?i)(password|pwd|secret|token)\s*[:=]' -and $siteText -notmatch '<!DOCTYPE|<!ENTITY'){try{$siteXml=[xml]$siteText;$physical=$siteXml.SelectSingleNode("//*[@physicalPath]");if($physical){$sitePath=[Environment]::ExpandEnvironmentVariables([string]$physical.GetAttribute('physicalPath'));if([IO.Path]::IsPathRooted($sitePath)){$safePath=$sitePath}}}catch{}}}
        if($safePath){
            if($entries.Count -ge $MaxEntries){$coverage.Add([pscustomobject]@{Probe='ConsumerFileMetadata';Scope=[string]$item.Kind;SID='';View='Inventory';Status='Partial';EvidenceKind='SourceInventory';Count=0;Budget=[pscustomobject]@{MaxEntries=$MaxEntries};ErrorKind='EntryBudgetExceeded';ObservedUtc=$observed});continue}
            $fileEvidence=Get-WsmSoftwareFileMetadataSnapshot -Path $safePath
            $coverage.Add([pscustomobject]@{Probe='ConsumerFileMetadata';Scope=[string]$item.Kind;SID='';View='Inventory';Status=[string]$fileEvidence.Status;EvidenceKind='FileVersionMetadata';Count=$(if($fileEvidence.Row){1}else{0});Budget=[pscustomobject]@{MaxEntries=$MaxEntries;MaxMetadataBytes=$MaxMetadataBytes};ErrorKind=$fileEvidence.ErrorKind;ObservedUtc=$observed;ItemId=[string]$item.ItemId})
            $file=$fileEvidence.Row;$consumerName=[IO.Path]::GetFileNameWithoutExtension($safePath);$consumerVersion='';$consumerPublisher='';if($file){if($file.Name){$consumerName=[string]$file.Name};$consumerVersion=[string]$file.Version;$consumerPublisher=[string]$file.Publisher}
            $entries.Add([pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId 'Consumer' '' ([string]$item.Kind) $safePath ([string]$item.ItemId));Name=$consumerName;Version=$consumerVersion;Publisher=$consumerPublisher;Architecture='Unknown';Scope='ConsumerReference';SID='';RegistryView='';Location=$safePath;SourceKind='InventoryReference';Evidence=[pscustomobject]@{ItemId=[string]$item.ItemId;ItemKind=[string]$item.Kind;FileMetadataStatus=[string]$fileEvidence.Status;ProductName=$(if($file){[string]$file.ProductName}else{''})};ObservedUtc=$observed;CaptureStatus=$(if($fileEvidence.Status -eq 'Success'){'Success'}else{'Partial'});ItemIds=@([string]$item.ItemId);AccountContext='Unknown'})
            if([IO.Path]::GetExtension($safePath) -match '(?i)^\.(exe|dll)$') {
                $remainingRuntimeBytes=[Math]::Max([long]0,$MaxMetadataBytes-$consumerRuntimeBytes);$adjacent=Get-WsmSoftwareAdjacentRuntimeSnapshot -ExecutablePath $safePath -MaxEntries ([Math]::Min(200,$MaxEntries)) -MaxMetadataBytes ([Math]::Min(1048576,$remainingRuntimeBytes))
                $consumerRuntimeBytes+=[long]$adjacent.MetadataBytes
                $coverage.Add([pscustomobject]@{Probe='AppLocalRuntimeMetadata';Scope=[string]$item.Kind;SID='';View='AdjacentFiles';Status=[string]$adjacent.Status;EvidenceKind='RuntimeConfigDepsAndKnownRuntimeNames';Count=$adjacent.Count;Budget=[pscustomobject]@{MaxEntries=([Math]::Min(200,$MaxEntries));MaxMetadataBytes=$MaxMetadataBytes;MetadataBytes=$consumerRuntimeBytes};ErrorKind=$(if($adjacent.Gaps.Count){$adjacent.Gaps[0].ErrorKind}else{$null});ObservedUtc=$observed;ItemId=[string]$item.ItemId})
                foreach($gap in @($adjacent.Gaps)){$coverage.Add([pscustomobject]@{Probe='AppLocalRuntimeMetadata';Scope=[string]$item.Kind;SID='';View='AdjacentFiles';Status=$gap.Status;EvidenceKind='RuntimeConfigDepsAndKnownRuntimeNames';Count=0;Budget=[pscustomobject]@{MaxEntries=([Math]::Min(200,$MaxEntries));MaxMetadataBytes=$MaxMetadataBytes;MetadataBytes=$consumerRuntimeBytes};ErrorKind=$gap.ErrorKind;ObservedUtc=$observed;ItemId=[string]$item.ItemId})}
                foreach($runtime in @($adjacent.Rows)) {if($entries.Count -ge $MaxEntries){$coverage.Add([pscustomobject]@{Probe='AppLocalRuntimeMetadata';Scope=[string]$item.Kind;SID='';View='AdjacentFiles';Status='Partial';EvidenceKind='Budget';Count=0;Budget=[pscustomobject]@{MaxEntries=$MaxEntries};ErrorKind='EntryBudgetExceeded';ObservedUtc=$observed;ItemId=[string]$item.ItemId});break};$entries.Add([pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId 'AppLocal' '' ([string]$item.Kind) ([string]$runtime.Path) ([string]$runtime.Name+'|'+[string]$runtime.Version+'|'+[string]$item.ItemId));Name=[string]$runtime.Name;Version=[string]$runtime.Version;Publisher=[string]$runtime.Publisher;Architecture='Unknown';Scope='AppLocal';SID='';RegistryView='';Location=[string]$runtime.Path;SourceKind='AppLocalRuntimeEvidence';Evidence=[pscustomobject]@{ItemId=[string]$item.ItemId;ItemKind=[string]$item.Kind;EvidenceKind=[string]$runtime.EvidenceKind;Length=[long]$runtime.Length};ObservedUtc=$observed;CaptureStatus=$(if($adjacent.Status -eq 'Success'){'Success'}else{'Partial'});ItemIds=@([string]$item.ItemId);AccountContext='Unknown'})}
            }
        }
    }

    if($ManualEvidencePath -or $ManualEvidenceSha256) {
        if(-not $ManualEvidencePath -or $ManualEvidenceSha256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Manual evidence requires a path and SHA-256 hash.'}
        $manualFull=[IO.Path]::GetFullPath($ManualEvidencePath);if(-not [IO.File]::Exists($manualFull)){throw 'Manual evidence file does not exist.'};if((Get-Item -LiteralPath $manualFull).Length -gt $MaxMetadataBytes){throw 'Manual evidence exceeds the metadata byte budget.'}
        $actual=(Get-FileHash -LiteralPath $manualFull -Algorithm SHA256).Hash;if($actual -ine $ManualEvidenceSha256){throw 'Manual evidence hash mismatch.'}
        $manual=Get-Content -LiteralPath $manualFull -Raw -Encoding UTF8 | ConvertFrom-Json
        if($manual.Kind -cne 'WsmManualSoftwareEvidence' -or @($manual.Entries).Count -gt $MaxEntries){throw 'Manual evidence kind or entry count is invalid.'}
        foreach($m in @($manual.Entries)) {
            foreach($field in @('Name','Owner','Evidence','ProvidedUtc')){if([string]::IsNullOrWhiteSpace([string](Get-WsmSoftwareSafeValue $m $field))){throw "Manual evidence entry missing $field."}}
            $scope='OwnerProvided';$loc=Get-WsmSoftwareSafeValue $m Location;$ver=Get-WsmSoftwareSafeValue $m Version
            $entries.Add([pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId $scope (Get-WsmSoftwareSafeValue $m SID) 'Manual' $loc ((Get-WsmSoftwareSafeValue $m Name)+'|'+$ver));Name=(Get-WsmSoftwareSafeValue $m Name);Version=$ver;Publisher=(Get-WsmSoftwareSafeValue $m Publisher);Architecture=$(if((Get-WsmSoftwareSafeValue $m Architecture) -in @('x86','x64','Arm32','Arm64')){Get-WsmSoftwareSafeValue $m Architecture}else{'Unknown'});Scope=$scope;SID=(Get-WsmSoftwareSafeValue $m SID);RegistryView='';Location=$loc;SourceKind='OwnerProvided';Owner=(Get-WsmSoftwareSafeValue $m Owner);Evidence=(Get-WsmSoftwareSafeValue $m Evidence);EvidenceHash=$actual;ProvidedUtc=(Get-WsmSoftwareSafeValue $m ProvidedUtc);ObservedUtc=$observed;CaptureStatus='Manual';ItemIds=@();AccountContext='Unknown'})
        }
        $coverage.Add([pscustomobject]@{Probe='OwnerProvided';Scope='Manual';SID='';View='File';Status='Success';EvidenceKind='HashVerifiedManualFile';Count=@($manual.Entries).Count;Budget=[pscustomobject]@{MaxEntries=$MaxEntries};ErrorKind=$null;ObservedUtc=$observed;EvidenceHash=$actual})
    }
    $seenSoftware=@{};$uniqueEntries=New-Object System.Collections.Generic.List[object]
    foreach($entry in $entries){$id=[string]$entry.SoftwareId;if($seenSoftware.ContainsKey($id)){if($entry.SourceKind -eq 'PortableEvidence' -and $seenSoftware[$id] -eq 'PortableEvidence'){continue};throw 'Distinct software evidence produced a colliding SoftwareId.'};$seenSoftware[$id]=[string]$entry.SourceKind;$uniqueEntries.Add($entry)}
    $entries=$uniqueEntries
    if($entries.Count -gt $MaxEntries){$coverage.Add([pscustomobject]@{Probe='CatalogAggregation';Scope='All';SID='';View='';Status='Partial';EvidenceKind='Budget';Count=$entries.Count;Budget=[pscustomobject]@{MaxEntries=$MaxEntries};ErrorKind='EntryBudgetExceeded';ObservedUtc=$observed});throw 'Software catalog exceeds the aggregate evidence budget; no source inventory sealed. Increase the controlled budget and repeat capture.'}
    $captureIdentity='Unknown';try{$captureIdentity=[Security.Principal.WindowsIdentity]::GetCurrent().Name}catch{}
    $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$sourceHost;Fingerprint=[string]$Source.Source.Fingerprint;Name=[string]$Source.Source.Name;InventoryRevision=[int]$Source.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $Source)};CaptureContext=[pscustomobject]@{CapturedUtc=$observed;CaptureIdentity=$captureIdentity;AccountContext='Unknown';CaptureHost=$env:COMPUTERNAME;PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@($PortableRoot)};Entries=@($entries.ToArray());Coverage=@($coverage.ToArray());PreparationRequirements=@(foreach($entry in $entries){[pscustomobject]@{PreparationId=('prep-'+$entry.SoftwareId.Substring(3));SoftwareId=$entry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus=$entry.CaptureStatus;ConsumerItemIds=@($entry.ItemIds);Owner='';Reason='Evidence inventory only; compatibility and necessity require review.'}});CatalogProjectionHash=('0'*64)}
    $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
    Assert-WsmSoftwareCatalog $catalog -SourceInventory $Source | Out-Null
    $catalog
}
