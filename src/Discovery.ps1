function Read-WsmXml([string]$Text) {
    $settings=New-Object Xml.XmlReaderSettings; $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit; $settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create((New-Object IO.StringReader($Text)),$settings)
    try { $doc=New-Object Xml.XmlDocument; $doc.XmlResolver=$null; $doc.Load($reader); return ,$doc } finally { $reader.Dispose() }
}
function Get-WsmCapabilities {
    $commands=@('Get-CimInstance','Get-ScheduledTask','Export-ScheduledTask','Get-WindowsFeature','Get-SmbShare','Get-NetFirewallRule','Get-NetIPAddress')
    foreach ($name in $commands) { [pscustomobject]@{ Capability=$name; Available=($null -ne (Get-Command $name -ErrorAction SilentlyContinue)); LanguageMode=[string]$ExecutionContext.SessionState.LanguageMode; InventorySupported=($null -ne (Get-Command $name -ErrorAction SilentlyContinue)); ServerVersionVerified=$false; ExportSupported=$false; RestoreSupported=$false; VerifySupported=$false } }
}
function Get-WsmExtendedDiscovery([string]$HostId) {
    function Probe([string]$Category,[string]$Key,[scriptblock]$Action) {
        try { & $Action }
        catch { $status='Failed'; if ($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'Unauthorized|PermissionDenied') { $status='PermissionDenied' }; New-WsmItem $HostId $Category CollectorFailure $Key ('extended:'+ $Key) @{ ErrorType=$_.Exception.GetType().FullName } @() $status }
    }
    Probe System 'capability-matrix' { New-WsmItem $HostId System Capabilities 'Command/language capability matrix' 'capabilities' @{ Commands=@(Get-WsmCapabilities) } }
    Probe System 'system-policy' { New-WsmItem $HostId System SystemConfiguration 'Time zone / language / updates' 'system-configuration' @{ TimeZone=(Get-TimeZone | Select-Object Id); Culture=[string](Get-Culture); UICulture=[string](Get-UICulture); Updates=@(Get-HotFix | Select-Object HotFixID); Environment=(Get-WsmMachineEnvironment) } }
    Probe Runtime 'odbc' {
        foreach ($branch in @('HKLM:\SOFTWARE\ODBC\ODBC.INI','HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI')) {
            if (Test-Path -LiteralPath $branch) { foreach ($key in Get-ChildItem -LiteralPath $branch -ErrorAction Stop) { New-WsmItem $HostId Runtime OdbcDsn $key.PSChildName $key.Name @{ Properties=(Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop) } } }
            else { New-WsmItem $HostId Runtime OdbcBranch ($branch+' not present') $branch @{} @() NotInstalled }
        }
    }
    Probe Runtime 'startup-wmi' {
        foreach ($entry in Get-CimInstance Win32_StartupCommand -ErrorAction Stop) { New-WsmItem $HostId Runtime StartupCommand $entry.Name ($entry.Location+'|'+$entry.Name+'|'+$entry.User) ($entry | Select-Object Name,Command,Location,User) }
        foreach ($entry in Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -ErrorAction Stop) { New-WsmItem $HostId Runtime WmiSubscription ([string]$entry.Consumer) ([string]$entry.Filter+'|'+[string]$entry.Consumer) ($entry | Select-Object Filter,Consumer) }
    }
    Probe Database 'database-products' {
        foreach ($branch in @('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL')) {
            if (Test-Path -LiteralPath $branch) { $data=Get-ItemProperty -LiteralPath $branch -ErrorAction Stop; foreach ($p in $data.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) { New-WsmItem $HostId Database SqlInstance $p.Name ($branch+'|'+$p.Name) @{ RegistryInstanceId=$p.Value; DiscoveryOnly=$true; RequiresProductSpecificInventory=$true } @() Partial } }
            else { New-WsmItem $HostId Database SqlRegistryBranch ($branch+' not present') $branch @{} @() NotInstalled }
        }
    }
    Probe Services 'service-details' {
        foreach ($key in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction Stop) {
            $p=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if ($p.PSObject.Properties['ImagePath']) { New-WsmItem $HostId Services ServiceRegistryDetails $key.PSChildName $key.PSChildName ($p | Select-Object ImagePath,ObjectName,Start,Type,DependOnService,DependOnGroup,DelayedAutoStart,FailureActions,ServiceSidType,RequiredPrivileges) }
        }
    }
    Probe Network 'host-proxy-tls' {
        $hosts=Join-Path $env:windir 'System32\drivers\etc\hosts'
        New-WsmItem $HostId Network HostsFile 'hosts file' 'hosts' @{ Content=(Get-WsmHostsText) }
        foreach ($branch in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings','HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL')) { if (Test-Path -LiteralPath $branch) { New-WsmItem $HostId Network RegistryEndpoint $branch $branch @{ Properties=(Get-ItemProperty -LiteralPath $branch -ErrorAction Stop) } } }
    }
}
function Get-WsmPathCandidates([string]$HostId,[object[]]$Items) {
    $roots=@{}; $serviceIndex=@{}; foreach ($i in $Items) { if ($i.Kind -eq 'Service') { $serviceIndex[$i.NaturalKey]=$i } }
    foreach ($i in $Items) {
        $paths=New-Object 'System.Collections.Generic.List[string]'
        if ($i.Kind -eq 'Service' -and $i.Settings.PSObject.Properties['PathName']) {
            $raw=[string]$i.Settings.PathName
            if ($raw -match '^"([^"]+)"' -or $raw -match '^(.+?\.(?:exe|com|bat|cmd|ps1))(?:\s|$)') { $paths.Add($matches[1]) }
        }
        if ($i.Kind -eq 'ServiceRegistryDetails') {
            $service=$null; if ($serviceIndex.ContainsKey($i.NaturalKey)) { $service=$serviceIndex[$i.NaturalKey] }
            if ($service -and $i.Settings.PSObject.Properties['DependOnService']) { foreach ($name in @($i.Settings.DependOnService)) { if ($name) { $depId=Get-WsmHashText ($HostId+'|Services|Service|'+$name.ToLowerInvariant()); $service.Dependencies=@($service.Dependencies)+@([pscustomobject]@{ ItemId=$depId; Type='Mandatory'; Evidence='Service registry DependOnService'; Confidence='Declared' }) } } }
        }
        if ($i.Kind -eq 'ScheduledTask') {
            try { $doc=Read-WsmXml $i.Settings.Xml; foreach ($node in $doc.SelectNodes("//*[local-name()='Exec']/*[local-name()='Command' or local-name()='WorkingDirectory']")) { $paths.Add($node.InnerText) } }
            catch { $i.Status='Partial' }
            if ($i.NaturalKey.StartsWith('\Microsoft\',[StringComparison]::OrdinalIgnoreCase)) { $i | Add-Member NoteProperty BuiltIn 'SuggestedInternal' -Force }
        }
        if ($i.Kind -eq 'IISSite') {
            try {
                $doc=Read-WsmXml $i.Settings.Xml
                foreach ($node in $doc.SelectNodes('//virtualDirectory[@physicalPath]')) { $paths.Add($node.GetAttribute('physicalPath')) }
                foreach ($node in $doc.SelectNodes('//application[@applicationPool]')) { $pool=$node.GetAttribute('applicationPool'); $depId=Get-WsmHashText ($HostId+'|Web|IISPool|'+$pool.ToLowerInvariant()); $i.Dependencies=@($i.Dependencies)+@([pscustomobject]@{ ItemId=$depId; Type='Mandatory'; Evidence='IIS applicationPool'; Confidence='Declared' }) }
            } catch { $i.Status='Partial' }
        }
        if ($i.Kind -eq 'Share') { $paths.Add([string]$i.Settings.Definition.Path) }
        foreach ($path in $paths) {
            if (-not $path) { continue }
            $expanded=[Environment]::ExpandEnvironmentVariables($path); $status='Unsupported'; $resolved=''
            if ($expanded -notmatch '%[^%]+%' -and $expanded -match '^(?:[a-zA-Z]:\\|\\\\[^\\]+\\[^\\]+)') { try { $resolved=ConvertTo-WsmCanonicalPath $expanded } catch { $resolved='' } }
            # A candidate is evidence, not permission to recursively copy its directory.
            $key=$path.ToLowerInvariant(); if (-not $roots.ContainsKey($key)) { $root=New-WsmItem $HostId Storage PathCandidate $path ('candidate:'+ $key) @{ OriginalPath=$path; ResolvedCandidate=$resolved; RequiresScopeApproval=$true; Reason='Confirm data/config root, exclusions, ACL, reparse points and external dependencies before export.' } @() $status; $roots[$key]=$root }
            $i.Dependencies=@($i.Dependencies)+@([pscustomobject]@{ ItemId=$roots[$key].ItemId; Type='Optional'; Evidence='Parsed configuration path; owner confirmation required'; Confidence='Candidate' })
        }
    }
    foreach ($i in $Items) { if ($i.PSObject.Properties['BuiltIn']) { continue }; [void](Get-WsmReviewDefaults $i) }
    @($roots.Values)
}
