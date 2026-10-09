function Get-WsmOracleKnownEnvironmentNames {
    @('TNS_ADMIN','ORACLE_HOME','ORACLE_BASE','NLS_LANG','LDAP_ADMIN','LOCAL','ORA_TZFILE','PATH')
}
function Get-WsmOracleSafeCandidateValue([string]$Name,[string]$Value) {
    if($Name -ieq 'LOCAL'){
        if($Value.Length -eq 0){return [pscustomobject]@{Value='';ValueSHA256='';Redacted=$false;Oversize=$false}}
        return [pscustomobject]@{Value='[value withheld; may contain a connect descriptor]';ValueSHA256=(Get-WsmHashText $Value);Redacted=$true;Oversize=($Value.Length -gt 4096)}
    }
    if($Name -ieq 'PATH'){
        $paths=@($Value -split ';' | Select-Object -First 512 | ForEach-Object {$_.Trim()} | Where-Object {$_ -match '(?i)oracle|instantclient' -and $_.Length -le 2048})
        return [pscustomobject]@{Value='';ValueSHA256='';OraclePathEntries=$paths;Redacted=$false;Oversize=($Value.Length -gt 131072)}
    }
    if($Value.Length -gt 4096){return [pscustomobject]@{Value='[value withheld; exceeds candidate limit]';ValueSHA256=(Get-WsmHashText $Value);Redacted=$true;Oversize=$true}}
    if($Value -match '(?i)(password|passwd|pwd|credential|wallet|token)s*=|//[^\s/:]+:[^\s/@]+@'){
        return [pscustomobject]@{Value='[value withheld; credential-like content]';ValueSHA256=(Get-WsmHashText $Value);Redacted=$true;Oversize=$false}
    }
    [pscustomobject]@{Value=$Value;ValueSHA256='';Redacted=$false;Oversize=$false}
}
function Add-WsmOracleEnvironmentCandidates([System.Collections.Generic.List[object]]$Rows,$Values,[string]$Scope,[string]$AccountSid='',[string]$ItemId='',[string]$RegistryView='',[string]$EvidencePath='',[System.Collections.IDictionary]$ValueTypes=$null) {
    $names=Get-WsmOracleKnownEnvironmentNames
    foreach($name in $names){
        $value=$null;$found=$false
        if($Values -is [System.Collections.IDictionary]){foreach($key in $Values.Keys){if([string]$key -ieq $name){$value=$Values[$key];$found=$true;break}}}
        elseif($Values -and $Values.PSObject.Properties[$name]){$value=$Values.PSObject.Properties[$name].Value;$found=$true}
        if(-not $found){continue}
        if($null -eq $value){$value=''}else{$value=[string]$value}
        $safe=Get-WsmOracleSafeCandidateValue $name $value
        $valueType='';if($ValueTypes -and $ValueTypes.Contains($name)){$valueType=[string]$ValueTypes[$name]}
        $row=[ordered]@{Source=$Scope;Name=$name;AccountSid=$AccountSid;ConsumerItemId=$ItemId;RegistryView=$RegistryView;EvidencePath=$EvidencePath;ValueType=$valueType;Exists=$true;IsEmpty=($value.Length -eq 0);CandidateOnly=$true;EffectiveValueProven=$false;Value=$safe.Value;ValueSHA256=$safe.ValueSHA256;Redacted=$safe.Redacted;Oversize=$safe.Oversize;Action='ExternalRequiredReadback'}
        if($safe.PSObject.Properties['OraclePathEntries']){$row.OraclePathEntries=@($safe.OraclePathEntries);$row.Action='ExternalManualMerge'}
        $Rows.Add([pscustomobject]$row)
    }
}
function Add-WsmOracleServiceEnvironmentCandidates([System.Collections.Generic.List[object]]$Rows,[System.Collections.Generic.List[object]]$Coverage,[string]$ItemId,$RawEnvironment,[string]$ValueKind,[string]$EvidencePath) {
    if($ValueKind -cne 'MultiString' -or $RawEnvironment -isnot [Array]){$Coverage.Add([pscustomobject]@{Source='ServiceRegistryEnvironment';ConsumerItemId=$ItemId;Status='CoverageGap';EvidencePath=$EvidencePath;ValueType=$ValueKind;Reason='Service Environment registry value is not a REG_MULTI_SZ array.'});return}
    $values=@{};$valueTypes=@{}
    foreach($line in @($RawEnvironment)){
        if([string]$line -notmatch '^([^=\x00-\x1f]+)=(.*)$'){
            if(-not [string]::IsNullOrWhiteSpace([string]$line)){$Coverage.Add([pscustomobject]@{Source='ServiceRegistryEnvironment';ConsumerItemId=$ItemId;Status='CoverageGap';EvidencePath=$EvidencePath;ValueType=$ValueKind;Reason='Service Environment contains an unparseable entry.'})}
            continue
        }
        $variableName=[string]$Matches[1]
        if((Get-WsmOracleKnownEnvironmentNames) -notcontains $variableName.ToUpperInvariant()){continue}
        $values[$variableName]=$Matches[2];$valueTypes[$variableName]=$ValueKind
    }
    Add-WsmOracleEnvironmentCandidates $Rows $values 'ServiceRegistryEnvironment' '' $ItemId '' $EvidencePath $valueTypes
    if(-not $values.Count){$Coverage.Add([pscustomobject]@{Source='ServiceRegistryEnvironment';ConsumerItemId=$ItemId;Status='Read';EvidencePath=$EvidencePath;ValueType=$ValueKind;Reason='Service Environment value was read; no whitelisted Oracle variable was present. This does not prove the effective process environment.'})}
}
function Get-WsmOracleNativeObservations($Inventory) {
    $candidates=New-Object 'System.Collections.Generic.List[object]';$coverage=New-Object 'System.Collections.Generic.List[object]';$homes=New-Object 'System.Collections.Generic.List[object]'
    if($env:OS -cne 'Windows_NT'){
        $coverage.Add([pscustomobject]@{Source='NativeRegistry';Status='Unavailable';Reason='Oracle client registry and Windows user hives require Windows.'})
        return [pscustomobject]@{Candidates=$candidates.ToArray();Homes=$homes.ToArray();Coverage=$coverage.ToArray();AdminProcessEnvironmentRead=$false}
    }
    try{$machine=[Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Machine);Add-WsmOracleEnvironmentCandidates $candidates $machine 'MachineEnvironment' '' '' '' 'Machine Environment'}catch{$coverage.Add([pscustomobject]@{Source='MachineEnvironment';Status='CoverageGap';Reason=$_.Exception.GetType().FullName})}
    try{
        $users=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users,[Microsoft.Win32.RegistryView]::Default)
        try{foreach($sid in $users.GetSubKeyNames()){
            if($sid -notmatch '^S-1-5-21-(?:\d+-){2}\d+-\d+$'){continue}
            $key=$users.OpenSubKey($sid+'\Environment')
            if(-not $key){$coverage.Add([pscustomobject]@{Source='LoadedUserEnvironment';AccountSid=$sid;Status='NotLoaded'});continue}
            try{$values=@{};foreach($name in $key.GetValueNames()){$values[$name]=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)};Add-WsmOracleEnvironmentCandidates $candidates $values 'LoadedUserEnvironment' $sid '' '' ('HKU\'+$sid+'\Environment')}finally{$key.Dispose()}
        }}finally{$users.Dispose()}
    }catch{$coverage.Add([pscustomobject]@{Source='LoadedUserEnvironment';Status='CoverageGap';Reason=$_.Exception.GetType().FullName})}
    foreach($view in @([Microsoft.Win32.RegistryView]::Registry32,[Microsoft.Win32.RegistryView]::Registry64)){
        $viewName=$view.ToString();$base=$null;$oracle=$null
        try{
            $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
            $oracle=$base.OpenSubKey('SOFTWARE\ORACLE')
            if(-not $oracle){$coverage.Add([pscustomobject]@{Source='OracleRegistry';RegistryView=$viewName;Status='NotFound'});continue}
            $rootValues=@{};$rootTypes=@{};foreach($n in $oracle.GetValueNames()){$rootValues[$n]=$oracle.GetValue($n,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);try{$rootTypes[$n]=$oracle.GetValueKind($n).ToString()}catch{$rootTypes[$n]='Unknown'}}
            Add-WsmOracleEnvironmentCandidates $candidates $rootValues 'OracleRegistry' '' '' $viewName ('HKLM\'+$viewName+'\SOFTWARE\ORACLE') $rootTypes
            $subkeys=@($oracle.GetSubKeyNames());if($subkeys.Count -gt 128){throw 'Oracle registry home count exceeds the 128-entry discovery budget.'}
            foreach($subkeyName in $subkeys){
                $homeKey=$oracle.OpenSubKey($subkeyName);if(-not $homeKey){continue}
                try{
                    $values=@{};$valueTypes=@{};foreach($n in $homeKey.GetValueNames()){$values[$n]=$homeKey.GetValue($n,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);try{$valueTypes[$n]=$homeKey.GetValueKind($n).ToString()}catch{$valueTypes[$n]='Unknown'}}
                    $home=[string]$values['ORACLE_HOME'];if(-not $home){$home=[string]$values['HOME']}
                    $homeName=[string]$values['ORACLE_HOME_NAME'];if(-not $homeName){$homeName=$subkeyName}
                    if($home){$homes.Add([pscustomobject]@{RegistryView=$viewName;HomeName=$homeName;OracleHome=$home;Version=[string]$values['ORACLE_HOME_VERSION'];Source='OracleRegistry'})}
                    Add-WsmOracleEnvironmentCandidates $candidates $values 'OracleRegistryHome' '' '' $viewName ('HKLM\'+$viewName+'\SOFTWARE\ORACLE\'+$subkeyName) $valueTypes
                }finally{$homeKey.Dispose()}
            }
            $coverage.Add([pscustomobject]@{Source='OracleRegistry';RegistryView=$viewName;Status='Read'})
        }catch{$coverage.Add([pscustomobject]@{Source='OracleRegistry';RegistryView=$viewName;Status='CoverageGap';Reason=$_.Exception.GetType().FullName})}
        finally{if($oracle){$oracle.Dispose()};if($base){$base.Dispose()}}
    }
    foreach($item in @($Inventory.Items | Where-Object {$_.Kind -ceq 'Service'})){
        $serviceName=[string]$item.NaturalKey
        if(-not $serviceName -or $serviceName -match '[\\/:\x00-\x1f]'){continue}
        $key=$null;$servicePath='HKLM\SYSTEM\CurrentControlSet\Services\'+$serviceName
        try{
            $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\'+$serviceName)
            if(-not $key){$coverage.Add([pscustomobject]@{Source='ServiceRegistryEnvironment';ConsumerItemId=[string]$item.ItemId;Status='NotFound';EvidencePath=$servicePath+'\Environment';Reason='Service registry key is absent; effective account environment is not proven.'});continue}
            $valueNames=@($key.GetValueNames());$values=@{};$valueTypes=@{};$hadEnvironmentValue=$valueNames -contains 'Environment'
            if($hadEnvironmentValue){
                $kind=$key.GetValueKind('Environment').ToString();$rawEnvironment=$key.GetValue('Environment',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                Add-WsmOracleServiceEnvironmentCandidates $candidates $coverage ([string]$item.ItemId) $rawEnvironment $kind ($servicePath+'\Environment')
            }else{
                $legacyKey=$null
                try{$legacyKey=$key.OpenSubKey('Environment');if($legacyKey){foreach($name in $legacyKey.GetValueNames()){$values[$name]=$legacyKey.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);try{$valueTypes[$name]=$legacyKey.GetValueKind($name).ToString()}catch{$valueTypes[$name]='Unknown'}};Add-WsmOracleEnvironmentCandidates $candidates $values 'ServiceRegistryEnvironment' '' ([string]$item.ItemId) '' ($servicePath+'\Environment') $valueTypes}}
                finally{if($legacyKey){$legacyKey.Dispose()}}
                if(-not $legacyKey){$coverage.Add([pscustomobject]@{Source='ServiceRegistryEnvironment';ConsumerItemId=[string]$item.ItemId;Status='NotFound';EvidencePath=$servicePath+'\Environment';Reason='No explicit service Environment value or subkey was found; effective account environment and fallback are not proven.'})}
            }
        }catch{$coverage.Add([pscustomobject]@{Source='ServiceRegistryEnvironment';ConsumerItemId=[string]$item.ItemId;Status='CoverageGap';Reason=$_.Exception.GetType().FullName})}
        finally{if($key){$key.Dispose()}}
    }
    [pscustomobject]@{Candidates=$candidates.ToArray();Homes=$homes.ToArray();Coverage=$coverage.ToArray();AdminProcessEnvironmentRead=$false}
}
function Get-WsmOracleClientCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory,[Parameter()][AllowNull()]$ConsumerBinding)
    if($Inventory.Kind -cne 'Inventory'){throw 'Oracle client candidate discovery requires a trusted Inventory object.'}
    $observation=Get-WsmOracleNativeObservations $Inventory
    $application=Get-WsmOracleApplicationConfigCandidates $Inventory $ConsumerBinding
    $allCandidates=@($observation.Candidates)+@($application.Candidates)
    $allCoverage=@($observation.Coverage)+@($application.Coverage)
    $homeRows=New-Object 'System.Collections.Generic.List[object]'
    foreach($home in @($observation.Homes)){
        $path=[string]$home.OracleHome
        if($path -match '^\\\\' -or -not [IO.Path]::IsPathRooted($path)){continue}
        $admin=Join-Path $path 'network\admin'
        $exists=[IO.Directory]::Exists($admin)
        $homeRows.Add([pscustomobject]@{RegistryView=$home.RegistryView;HomeName=$home.HomeName;OracleHome=$path;Version=$home.Version;NetworkAdmin=$admin;NetworkAdminExists=$exists;Source=$home.Source;EffectiveValueProven=$false})
    }
    if($ConsumerBinding){foreach($consumer in @($ConsumerBinding.Consumers)){$home=[IO.Path]::GetFullPath([string]$consumer.OracleHome);$admin=Join-Path $home 'network\admin';$homeRows.Add([pscustomobject]@{RegistryView='OwnerBinding';HomeName='';OracleHome=$home;Version=[string]$consumer.Version;NetworkAdmin=$admin;NetworkAdminExists=[IO.Directory]::Exists($admin);Source='OwnerBoundDefaultHomeFallbackCandidate';Provider=[string]$consumer.Provider;Architecture=[string]$consumer.Architecture;ConsumerId=[string]$consumer.ConsumerId;ConsumerItemIds=@($consumer.ConsumerItemIds);AccountSid=[string]$consumer.AccountSid;CandidateOnly=$true;EffectiveValueProven=$false;Status='ProviderVersionSpecificBehaviorRequiresOwnerObservation'})}}
    [pscustomobject]@{Candidates=$allCandidates;Homes=$homeRows.ToArray();Coverage=$allCoverage;AdminProcessEnvironmentRead=$false;ResolutionRule='Provider/version/architecture-specific order is unresolved; owner binding required.';PATHAction='ExternalManualMerge'}
}
function Get-WsmOracleApplicationConfigCandidates($Inventory,$ConsumerBinding) {
    $rows=New-Object 'System.Collections.Generic.List[object]';$coverage=New-Object 'System.Collections.Generic.List[object]'
    if($null -eq $ConsumerBinding){return [pscustomobject]@{Candidates=@();Coverage=@()}}
    $items=@{};foreach($item in @($Inventory.Items)){$items[[string]$item.ItemId]=$item}
    $visited=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($consumer in @($ConsumerBinding.Consumers)){
        foreach($id in @($consumer.ConsumerItemIds)){
            if(-not $items.ContainsKey([string]$id)){continue};$item=$items[[string]$id];$settings=$item.Settings;$candidateFiles=New-Object 'System.Collections.Generic.List[string]'
            $exe=''
            if($item.Kind -ceq 'Service'){
                $raw='';if($settings.PSObject.Properties['PathName']){$raw=[string]$settings.PathName}
                $match=[regex]::Match($raw,'^(?:"([^"]+\.exe)"|([^\s]+\.exe))',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if($match.Success){$exe=$match.Groups[1].Value;if(-not $exe){$exe=$match.Groups[2].Value}}
                if(-not $exe){$coverage.Add([pscustomobject]@{ConsumerItemId=$id;Source='ApplicationConfig';Status='CoverageGap';Reason='Service executable path was absent or could not be safely parsed.'})}
            }elseif($item.Kind -ceq 'PathCandidate'){
                foreach($field in @('Path','ApplicationPath','ExecutablePath')){if($settings.PSObject.Properties[$field] -and [string]$settings.$field){$exe=[string]$settings.$field;break}}
            }elseif($item.Kind -ceq 'IISSite'){
                $xmlText='';if($settings.PSObject.Properties['Xml']){$xmlText=[string]$settings.Xml}
                if($xmlText -and $xmlText.Length -le 1048576 -and $xmlText -notmatch '<!DOCTYPE|<!ENTITY'){
                    try{$doc=New-Object Xml.XmlDocument;$doc.XmlResolver=$null;$readerSettings=New-Object Xml.XmlReaderSettings;$readerSettings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$readerSettings.XmlResolver=$null;$stringReader=New-Object IO.StringReader($xmlText);$xmlReader=[Xml.XmlReader]::Create($stringReader,$readerSettings);try{$doc.Load($xmlReader)}finally{$xmlReader.Dispose();$stringReader.Dispose()};$node=$doc.SelectSingleNode('//*[@physicalPath]');if($node){$root=[string]$node.GetAttribute('physicalPath');if([IO.Path]::IsPathRooted($root) -and $root -notmatch '^\\'){$candidateFiles.Add((Join-Path $root 'web.config'))}}}catch{$coverage.Add([pscustomobject]@{ConsumerItemId=$id;Source='IISApplicationConfig';Status='CoverageGap';Reason='Application config XML is unsupported or malformed.'})}
                }
            }else{
                $coverage.Add([pscustomobject]@{ConsumerItemId=$id;Source='ApplicationConfig';Status='NotSearched';Reason='No bounded application config locator is implemented for this inventory item kind.'})
            }
            if($exe){
                if($exe -match '^\\' -or -not [IO.Path]::IsPathRooted($exe) -or $exe -match '%[^%]+%'){$coverage.Add([pscustomobject]@{ConsumerItemId=$id;Source='ApplicationConfig';Status='UnresolvedPath';Reason='Executable path is relative, UNC, or environment-expanded.'});continue}
                try{$appDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($exe));Assert-WsmNoReparse $exe;$exe=[IO.Path]::GetFullPath($exe);$candidateFiles.Add($exe+'.config');foreach($name in @('app.config','appsettings.json','tnsnames.ora','ojdbc.properties','oracle.properties','jdbc.properties')){$candidateFiles.Add((Join-Path $appDirectory $name))}}catch{$coverage.Add([pscustomobject]@{ConsumerItemId=$id;Source='ApplicationConfig';Status='CoverageGap';Reason='Consumer executable path could not be safely inspected.'})}
            }
            $foundCandidate=$false
            foreach($filePath in $candidateFiles){
                if(-not $visited.Add([IO.Path]::GetFullPath($filePath))){continue}
                if($visited.Count -gt 512){$coverage.Add([pscustomobject]@{ConsumerItemId=$id;Source='ApplicationConfig';Status='BudgetExceeded';Reason='Application config discovery exceeded 512 distinct paths.'});break}
                if(-not [IO.File]::Exists($filePath)){continue}
                $foundCandidate=$true
                try{
                    Assert-WsmNoReparse $filePath;$appBytes=Read-WsmOracleBoundedBytes $filePath 1048576;$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($appBytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};$settingNames=@();$tnsAdmin='';$extension=[IO.Path]::GetExtension($filePath)
                    if($extension -ieq '.config'){
                        $xmlSettings=New-Object Xml.XmlReaderSettings;$xmlSettings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$xmlSettings.XmlResolver=$null;$xmlDoc=New-Object Xml.XmlDocument;$xmlDoc.XmlResolver=$null;$appStream=New-Object IO.MemoryStream(,$appBytes);$xmlReader=[Xml.XmlReader]::Create($appStream,$xmlSettings);try{$xmlDoc.Load($xmlReader)}finally{$xmlReader.Dispose();$appStream.Dispose()}
                        foreach($node in @($xmlDoc.SelectNodes("//*[local-name()='add']"))){$key=[string]$node.GetAttribute('key');if($key -match '(?i)tns_admin|oracle\.net\.tns_admin'){$settingNames+=@($key);$value=[string]$node.GetAttribute('value');if($value -and [IO.Path]::IsPathRooted($value) -and $value -notmatch '^\\' -and $value -notmatch '%[^%]+%'){$tnsAdmin=[IO.Path]::GetFullPath($value)}}}
                    }elseif($extension -ieq '.json'){
                        $raw=(New-Object Text.UTF8Encoding($false,$true)).GetString($appBytes);foreach($match in [regex]::Matches($raw,'(?i)["''](?:tns_admin|oracle\.net\.tns_admin)["'']\s*:\s*["'']([^"'']{1,4096})["'']')){$settingNames+=@('TNS_ADMIN');$value=$match.Groups[1].Value;if([IO.Path]::IsPathRooted($value) -and $value -notmatch '^\\' -and $value -notmatch '%[^%]+%'){$tnsAdmin=[IO.Path]::GetFullPath($value)}}
                    }elseif($extension -ieq '.properties'){
                        $raw=(New-Object Text.UTF8Encoding($false,$true)).GetString($appBytes);foreach($line in ($raw -split "`r?`n")){$match=[regex]::Match($line,'(?i)^\s*oracle\.net\.tns_admin\s*[=:]\s*(.*?)\s*$');if($match.Success){$settingNames+=@('oracle.net.tns_admin');$value=$match.Groups[1].Value.Trim();if($value -and [IO.Path]::IsPathRooted($value) -and $value -notmatch '^\\' -and $value -notmatch '%[^%]+%'){$tnsAdmin=[IO.Path]::GetFullPath($value)}}}
                    }
                    $rows.Add([pscustomobject]@{Source='ApplicationConfig';ConsumerItemId=[string]$id;ConsumerId=[string]$consumer.ConsumerId;Path=[IO.Path]::GetFullPath($filePath);SHA256=$hash;SettingNames=@($settingNames | Sort-Object -Unique);Name='TNS_ADMIN';Value=$tnsAdmin;ValueSHA256='';RegistryView='';AccountSid=[string]$consumer.AccountSid;CandidateOnly=$true;EffectiveValueProven=$false;Status='ReadStaticConfigOnly';OwnerBindingRequired=$true})
                }catch{$coverage.Add([pscustomobject]@{ConsumerItemId=$id;Source='ApplicationConfig';Path=[IO.Path]::GetFullPath($filePath);Status='CoverageGap';Reason=$_.Exception.GetType().FullName})}
            }
            if($candidateFiles.Count -and -not $foundCandidate){$coverage.Add([pscustomobject]@{ConsumerItemId=$id;Source='ApplicationConfig';Status='NotFound';Reason='No bounded adjacent application config candidate exists.'})}
        }
    }
    [pscustomobject]@{Candidates=$rows.ToArray();Coverage=$coverage.ToArray()}
}
function Get-WsmOracleConsumerId($Consumer) {
    $ids=@($Consumer.ConsumerItemIds | ForEach-Object {[string]$_} | Sort-Object -Unique)
    $text=@([string]$Consumer.ProviderSoftwareId,[string]$Consumer.ProviderItemId,[string]$Consumer.Provider,[string]$Consumer.Version,[string]$Consumer.Architecture,[string]$Consumer.OracleHome,[string]$Consumer.AccountType,[string]$Consumer.AccountName,[string]$Consumer.AccountSid,[string]$Consumer.ObservedEffectivePath,($ids -join ',')) -join '|'
    Get-WsmHashText $text
}
function Assert-WsmOracleConsumerShape($Consumer,[switch]$AllowDraft) {
    $allowed=@('ConsumerId','ProviderSoftwareId','ProviderItemId','Provider','Version','Architecture','OracleHome','AccountType','AccountName','AccountSid','ConsumerItemIds','ObservedEffectivePath','ApprovedIFiles','Owner','Evidence','ReviewStatus')
    Assert-WsmFields $Consumer $allowed @('ProviderSoftwareId','Provider','Version','Architecture','OracleHome','AccountType','AccountName','AccountSid','ConsumerItemIds','ObservedEffectivePath','ApprovedIFiles','Owner','Evidence','ReviewStatus')
    if([string]$Consumer.ProviderSoftwareId -notmatch '^sw-[a-f0-9]{32}$'){throw 'Oracle consumer must bind a stable B1 ProviderSoftwareId.'}
    if($Consumer.PSObject.Properties['ProviderItemId'] -and [string]$Consumer.ProviderItemId -and [string]$Consumer.ProviderItemId -notmatch '^[a-f0-9]{64}$'){throw 'ProviderItemId must be a stable ItemId.'}
    if([string]$Consumer.Provider -cnotin @('OCI','ODBC','ODP.NET.Managed','ODP.NET.Unmanaged','ODP.NET.Core','JDBC')){throw 'Unknown Oracle provider type; review it as an unsupported consumer.'}
    if([string]$Consumer.Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]{0,63}$'){throw 'Oracle provider version must be an explicit bounded value.'}
    if([string]$Consumer.Architecture -cnotin @('x86','x64','AnyCPU','Unknown')){throw 'Oracle consumer architecture must be x86, x64, AnyCPU, or Unknown.'}
    if([string]$Consumer.AccountType -cnotin @('Machine','Service','IISAppPool','ScheduledTask','User','Application')){throw 'Oracle consumer account context is unsupported.'}
    if([string]::IsNullOrWhiteSpace([string]$Consumer.AccountName)){throw 'Oracle consumer account name is required.'}
    if([string]$Consumer.AccountSid -and [string]$Consumer.AccountSid -cnotmatch '^(S-1-\d+(?:-\d+)+|Unknown)$'){throw 'Oracle consumer AccountSid is invalid.'}
    if([string]$Consumer.AccountType -ne 'Machine' -and -not [string]$Consumer.AccountSid){throw 'Non-machine Oracle consumer requires its SID or explicit Unknown value.'}
    $home=[string]$Consumer.OracleHome
    if([string]::IsNullOrWhiteSpace($home) -or $home -match '^\\\\' -or -not [IO.Path]::IsPathRooted($home)){throw 'OracleHome must be an explicit local absolute path; UNC and unresolved values are blocked.'}
    $effective=[string]$Consumer.ObservedEffectivePath
    if([string]::IsNullOrWhiteSpace($effective) -or $effective -match '^\\\\' -or -not [IO.Path]::IsPathRooted($effective)){throw 'ObservedEffectivePath must be a local absolute path; UNC and unresolved values are blocked.'}
    if($Consumer.ReviewStatus -cne 'OwnerConfirmed'){throw 'Oracle consumer owner binding must be explicitly reviewed.'}
    if(-not $AllowDraft -and ([string]::IsNullOrWhiteSpace([string]$Consumer.Owner) -or [string]::IsNullOrWhiteSpace([string]$Consumer.Evidence))){throw 'Oracle consumer requires owner and evidence.'}
    $ownerText=[string]$Consumer.Owner;$evidenceText=[string]$Consumer.Evidence;$accountNameText=[string]$Consumer.AccountName
    if($ownerText.Length -gt 512 -or $evidenceText.Length -gt 2048 -or $accountNameText.Length -gt 512 -or $home.Length -gt 2048 -or $effective.Length -gt 2048){throw 'Oracle consumer metadata exceeds its bounded field size.'}
    foreach($value in @([string]$Consumer.Owner,[string]$Consumer.Evidence,[string]$Consumer.OracleHome,[string]$Consumer.ObservedEffectivePath)){if($value -match '(?i)(password|passwd|pwd|credential)\s*=|//[^\s/]+:[^\s/@]+@'){throw 'Credential-like content is not allowed in an Oracle consumer binding.'}}
    $ids=@($Consumer.ConsumerItemIds);if(-not $ids.Count -or $ids.Count -gt 256){throw 'Oracle consumer must reference 1–256 consumer ItemIds.'}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($id in $ids){if([string]$id -notmatch '^[a-f0-9]{64}$' -or -not $seen.Add([string]$id)){throw 'Oracle consumer ItemIds must be unique stable inventory ItemIds.'}}
    if(@($Consumer.ApprovedIFiles).Count -gt 256){throw 'Owner-approved IFILE references exceed the 256-path bound.'}
    $files=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($path in @($Consumer.ApprovedIFiles)){
        if([string]$path -match '^\\\\' -or [string]$path.Length -gt 2048 -or -not [IO.Path]::IsPathRooted([string]$path)){throw 'Owner-approved IFILE paths must be bounded local absolute paths.'}
        if(-not $files.Add([IO.Path]::GetFullPath([string]$path))){throw 'Duplicate owner-approved IFILE path.'}
    }
    $expected=Get-WsmOracleConsumerId $Consumer
    if($Consumer.ConsumerId -and [string]$Consumer.ConsumerId -cne $expected){throw 'Oracle ConsumerId does not match its provider, version, architecture, home, account and consumer ItemIds.'}
    return $expected
}
function Read-WsmOracleSoftwareCatalog([string]$Path,[string]$ExpectedHash,$Inventory) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Trusted B1 software catalog hash is required for Oracle provider binding.'}
    $catalog=Read-WsmTrustedJson $Path $ExpectedHash
    $assertCommand=Get-Command Assert-WsmSoftwareCatalog -ErrorAction SilentlyContinue
    if($assertCommand){Assert-WsmSoftwareCatalog $catalog -SourceInventory $Inventory | Out-Null}
    else{
        Assert-WsmEnvelope $catalog 'SoftwareCatalog'
        if($catalog.Source.HostId -cne $Inventory.Source.HostId -or $catalog.Source.Fingerprint -cne $Inventory.Source.Fingerprint){throw 'Oracle software catalog belongs to another source host.'}
    }
    if($catalog.Kind -cne 'SoftwareCatalog' -or $catalog.Source.HostId -cne $Inventory.Source.HostId -or $catalog.Source.Fingerprint -cne $Inventory.Source.Fingerprint){throw 'Oracle software catalog does not bind to the trusted source identity.'}
    $rows=@{};foreach($row in @($catalog.Entries)){$rows[[string]$row.SoftwareId]=$row}
    $catalog
}
function Assert-WsmOracleProviderRows($Consumers,$Catalog) {
    $rows=@{};foreach($row in @($Catalog.Entries)){$rows[[string]$row.SoftwareId]=$row}
    foreach($consumer in $Consumers){
        $id=[string]$consumer.ProviderSoftwareId
        if(-not $rows.ContainsKey($id)){throw 'Oracle provider SoftwareId is absent from the pinned B1 software catalog.'}
        $row=$rows[$id]
        if(([string]$row.Name+' '+[string]$row.Publisher+' '+[string]$row.SourceKind) -notmatch '(?i)oracle|odac|odp\.net|instant.?client') {throw 'Pinned B1 software row is not recognized as an Oracle client/provider.'}
        if([string]$row.Version -and [string]$row.Version -cne [string]$consumer.Version){throw 'Owner-bound provider version differs from the pinned B1 software version.'}
        if([string]$row.Architecture -in @('x86','x64','Arm32','Arm64') -and [string]$consumer.Architecture -cne [string]$row.Architecture){throw 'Owner-bound provider architecture differs from the pinned B1 software architecture.'}
        if($consumer.ProviderItemId){$providerItemIds=@($rows[$id].ItemIds | ForEach-Object {[string]$_});if($providerItemIds.Count -and $providerItemIds -notcontains [string]$consumer.ProviderItemId){throw 'Oracle ProviderItemId is not linked to the pinned provider SoftwareId.'}}
    }
}
function Export-WsmOracleConsumerBindingTemplate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InventoryPath,[Parameter(Mandatory)][string]$ExpectedInventoryHash,[Parameter(Mandatory)][string]$SoftwareCatalogPath,[Parameter(Mandatory)][string]$ExpectedSoftwareCatalogHash,[Parameter(Mandatory)][object[]]$Consumers,[Parameter(Mandatory)][string]$Path)
    $inventory=Read-WsmTrustedJson $InventoryPath $ExpectedInventoryHash;Assert-WsmInventory $inventory
    $catalog=Read-WsmOracleSoftwareCatalog $SoftwareCatalogPath $ExpectedSoftwareCatalogHash $inventory
    if($Consumers.Count -lt 1 -or $Consumers.Count -gt 256){throw 'Oracle consumer template accepts 1–256 explicit consumer rows.'}
    $validItemIds=@{};foreach($item in $inventory.Items){$validItemIds[[string]$item.ItemId]=$true}
    $rows=New-Object 'System.Collections.Generic.List[object]';$seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($consumerInput in $Consumers){
        Assert-WsmFields $consumerInput @('ProviderSoftwareId','ProviderItemId','Provider','Version','Architecture','OracleHome','AccountType','AccountName','AccountSid','ConsumerItemIds','ObservedEffectivePath','ApprovedIFiles') @('ProviderSoftwareId','Provider','Version','Architecture','OracleHome','AccountType','AccountName','AccountSid','ConsumerItemIds','ObservedEffectivePath','ApprovedIFiles')
        $row=[pscustomobject][ordered]@{ProviderSoftwareId=[string]$consumerInput.ProviderSoftwareId;ProviderItemId=[string]$consumerInput.ProviderItemId;Provider=[string]$consumerInput.Provider;Version=[string]$consumerInput.Version;Architecture=[string]$consumerInput.Architecture;OracleHome=[string]$consumerInput.OracleHome;AccountType=[string]$consumerInput.AccountType;AccountName=[string]$consumerInput.AccountName;AccountSid=[string]$consumerInput.AccountSid;ConsumerItemIds=@($consumerInput.ConsumerItemIds);ObservedEffectivePath=[string]$consumerInput.ObservedEffectivePath;ApprovedIFiles=@($consumerInput.ApprovedIFiles);Owner='';Evidence='';ReviewStatus='OwnerReviewRequired'}
        foreach($id in $row.ConsumerItemIds){if(-not $validItemIds.ContainsKey([string]$id)){throw 'Oracle consumer references an ItemId outside the trusted source inventory.'}}
        foreach($field in @('ProviderSoftwareId','Provider','Version','Architecture','OracleHome','AccountType','AccountName','AccountSid','ConsumerItemIds','ObservedEffectivePath','ApprovedIFiles')){if(-not $row.PSObject.Properties[$field]){throw ('Missing Oracle consumer template field '+$field+'.')}}
        if(-not $seen.Add((Get-WsmOracleConsumerId $row))){throw 'Duplicate Oracle consumer context in template.'}
        $row | Add-Member NoteProperty ConsumerId (Get-WsmOracleConsumerId $row)
        $rows.Add($row)
    }
    $output=[IO.Path]::GetFullPath($Path);$directory=[IO.Path]::GetDirectoryName($output);Assert-WsmNoReparse $directory
    if([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)){throw 'Oracle consumer template output must be a new file.'}
    if((Test-WsmPathOverlap (Get-WsmPhysicalPath $InventoryPath) (Get-WsmPhysicalPath $directory))){throw 'Oracle consumer template output overlaps the trusted inventory file.'}
    Assert-WsmOracleProviderRows $rows.ToArray() $catalog
    $binding=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OracleConsumerBinding';BindingVersion=1;ReviewStatus='OwnerReviewRequired';SourceHostId=$inventory.Source.HostId;SourceFingerprint=$inventory.Source.Fingerprint;InventoryHash=$ExpectedInventoryHash.ToLowerInvariant();SoftwareCatalogHash=$ExpectedSoftwareCatalogHash.ToLowerInvariant();Consumers=$rows.ToArray();ConnectionProofStatus='NotTested';ProductionVerified=$false}
    $temp=$output+'.'+[Guid]::NewGuid().ToString('N')+'.partial'
    try{Write-WsmJson $temp $binding;if([IO.File]::Exists($output)){throw 'Oracle consumer binding template appeared during write.'};[IO.File]::Move($temp,$output)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    [pscustomobject]@{Path=$output;SHA256=(Get-FileHash -LiteralPath $output).Hash;ReviewStatus='OwnerReviewRequired';Trusted=$false;Consumers=$rows.Count;ProductionVerified=$false}
}
function Read-WsmOracleConsumerBinding([string]$Path,[string]$ExpectedHash,$Inventory,[string]$ExpectedInventoryHash,[string]$SoftwareCatalogPath,[string]$ExpectedSoftwareCatalogHash) {
    $binding=Read-WsmTrustedJson $Path $ExpectedHash;Assert-WsmEnvelope $binding 'OracleConsumerBinding'
    Assert-WsmFields $binding @('SchemaVersion','ToolVersion','Kind','BindingVersion','ReviewStatus','SourceHostId','SourceFingerprint','InventoryHash','SoftwareCatalogHash','Consumers','ConnectionProofStatus','ProductionVerified') @('SchemaVersion','Kind','BindingVersion','ReviewStatus','SourceHostId','SourceFingerprint','InventoryHash','SoftwareCatalogHash','Consumers','ConnectionProofStatus','ProductionVerified')
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or $binding.BindingVersion -ne 1 -or $binding.ReviewStatus -cne 'OwnerConfirmed' -or $binding.ConnectionProofStatus -cne 'NotTested' -or $binding.ProductionVerified -ne $false){throw 'Oracle consumer binding version, review or proof state is unsupported.'}
    if($binding.SourceHostId -cne $Inventory.Source.HostId -or $binding.SourceFingerprint -cne $Inventory.Source.Fingerprint){throw 'Oracle consumer binding belongs to another source host.'}
    if($ExpectedInventoryHash -notmatch '^[a-fA-F0-9]{64}$' -or $binding.InventoryHash -ine $ExpectedInventoryHash){throw 'Oracle consumer binding is not pinned to the trusted source inventory hash.'}
    if($ExpectedSoftwareCatalogHash -notmatch '^[a-fA-F0-9]{64}$' -or $binding.SoftwareCatalogHash -ine $ExpectedSoftwareCatalogHash){throw 'Oracle consumer binding is not pinned to the trusted B1 software catalog hash.'}
    $catalog=Read-WsmOracleSoftwareCatalog $SoftwareCatalogPath $ExpectedSoftwareCatalogHash $Inventory
    if($binding.Consumers.Count -lt 1 -or $binding.Consumers.Count -gt 256){throw 'Oracle consumer binding exceeds its 256-row bound.'}
    $inventoryItems=@{};foreach($item in $Inventory.Items){$inventoryItems[[string]$item.ItemId]=$true}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($consumer in $binding.Consumers){
        $consumerId=Assert-WsmOracleConsumerShape $consumer
        if(-not $seen.Add($consumerId)){throw 'Oracle consumer binding contains duplicate consumer contexts.'}
        foreach($id in $consumer.ConsumerItemIds){if(-not $inventoryItems.ContainsKey([string]$id)){throw 'Oracle consumer binding contains an ItemId outside the trusted source inventory.'}}
    }
    Assert-WsmOracleProviderRows $binding.Consumers $catalog
    $binding
}
function Resolve-WsmOracleLocalFile([string]$Path,[string]$ScopeRoot,[string[]]$ExcludedRelativePaths) {
    if([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^\\\\' -or -not [IO.Path]::IsPathRooted($Path)){throw 'IFILE path is missing, relative, or UNC; bounded resolution is blocked.'}
    $full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetFullPath($ScopeRoot).TrimEnd('\')
    Assert-WsmNoReparse $full
    if(-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Oracle configuration reference escapes the approved FileScope.'}
    $relative=$full.Substring($root.Length).TrimStart('\');Assert-WsmRelativePath $relative
    foreach($excluded in $ExcludedRelativePaths){if($relative -ieq $excluded -or $relative.StartsWith(([string]$excluded).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Oracle configuration reference is excluded from the approved FileScope.'}}
    if(-not [IO.File]::Exists($full)){throw 'Oracle configuration or IFILE reference is missing.'}
    [pscustomobject]@{FullPath=$full;RelativePath=$relative}
}
function Read-WsmOracleBoundedBytes([string]$Path,[long]$MaximumBytes) {
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read');$memory=New-Object IO.MemoryStream
    try{
        if($stream.Length -gt $MaximumBytes){throw 'Oracle configuration exceeds its bounded parser byte limit.'}
        $buffer=New-Object byte[] 65536;$total=[long]0
        while(($read=$stream.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$read;if($total -gt $MaximumBytes){throw 'Oracle configuration exceeded its bounded parser byte limit while reading.'};$memory.Write($buffer,0,$read)}
        $memory.ToArray()
    }finally{$memory.Dispose();$stream.Dispose()}
}
function Get-WsmOracleFileEncodingAndReferences([string]$Path) {
    $bytes=Read-WsmOracleBoundedBytes $Path 8388608;$offset=0;$encodingName='';$encoding=$null
    if($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191){$offset=3;$encodingName='UTF-8-BOM';$encoding=New-Object Text.UTF8Encoding($false,$true)}
    elseif($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254){$offset=2;$encodingName='UTF-16LE';$encoding=New-Object Text.UnicodeEncoding($false,$false,$true)}
    elseif($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255){$offset=2;$encodingName='UTF-16BE';$encoding=New-Object Text.UnicodeEncoding($true,$false,$true)}
    else{
        try{$encoding=New-Object Text.UTF8Encoding($false,$true);$null=$encoding.GetString($bytes);$encodingName='UTF-8'}
        catch{
            try{
                if([Text.Encoding]::Default.CodePage -eq 65001){try{[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)}catch{};$codePage=[Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage;$ansi=[Text.Encoding]::GetEncoding($codePage,(New-Object Text.EncoderExceptionFallback),(New-Object Text.DecoderExceptionFallback))}
                else{$ansi=[Text.Encoding]::Default}
                $null=$ansi.GetString($bytes);$encoding=$ansi;$encodingName='ANSI-'+$ansi.CodePage
            }
            catch{throw 'Oracle config encoding is unknown; do not rewrite or package it as reviewed.'}
        }
    }
    try{$text=$encoding.GetString($bytes,$offset,$bytes.Length-$offset)}catch{throw 'Oracle config bytes cannot be decoded by a supported bounded encoding.'}
    $references=New-Object 'System.Collections.Generic.List[string]';$walletReferenceHashes=New-Object 'System.Collections.Generic.List[string]'
    foreach($line in ($text -split "`r?`n")){
        $trim=$line.Trim()
        if($trim -match '(?i)\b(password|passwd|pwd)\s*=|\bIDENTIFIED\s+BY\b'){throw 'Oracle config contains embedded password material; use the external secret workflow.'}
        if($trim -match '(?i)\b(WALLET_LOCATION|MY_WALLET_DIRECTORY|WALLET_ROOT)\b'){$walletReferenceHashes.Add((Get-WsmHashText $trim))}
        if($trim -match '^(?i)IFILE\b'){
            if($trim -match '^(?i)IFILE\s*=\s*(?:"([^"]+)"|''([^'']+)''|([^#;]+?))\s*(?:[#;].*)?$'){
                $value=$Matches[1];if(-not $value){$value=$Matches[2]};if(-not $value){$value=$Matches[3]};$value=$value.Trim()
                if(-not $value -or $value -match '%[^%]+%'){throw 'Oracle IFILE uses an empty or environment-expanded path; parser cannot resolve it safely.'}
                $references.Add($value)
            }else{throw 'Oracle IFILE syntax is unsupported by the bounded parser.'}
        }elseif($trim -match '(?i)\bIFILE\b'){throw 'Oracle IFILE syntax is unsupported by the bounded parser.'}
    }
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    [pscustomobject]@{Encoding=$encodingName;Bytes=[long]$bytes.Length;SHA256=$hash;IFILE=@($references.ToArray());WalletReferenceHashes=@($walletReferenceHashes.ToArray())}
}
function Test-WsmOraclePathExcluded([string]$RelativePath,[string[]]$ExcludedRelativePaths) {
    foreach($excluded in $ExcludedRelativePaths){if($RelativePath -ieq $excluded -or $RelativePath.StartsWith(([string]$excluded).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return $true}}
    return $false
}
function Get-WsmOracleDirectoryEnumerator([string]$Path) {
    # Keep enumeration behind a private seam so failures can be exercised by
    # focused fixtures without exposing a probe-provider API to callers.
    return ,([IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator())
}
function Get-WsmOracleExternalMaterialCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[ValidateRange(1,65536)][int]$MaxEntries=4096,[ValidateRange(0,64)][int]$MaxDepth=16)
    $rootPath=[IO.Path]::GetFullPath($Root)
    if(-not [IO.Directory]::Exists($rootPath)){throw 'Oracle external-material root is unavailable.'}
    Assert-WsmNoReparse $rootPath
    $pending=New-Object 'System.Collections.Generic.Stack[object]';$pending.Push([pscustomobject]@{Path=$rootPath;Depth=0})
    $candidates=New-Object 'System.Collections.Generic.List[object]';$visited=0
    while($pending.Count){
        $directory=$pending.Pop();$currentPath=[IO.Path]::GetFullPath([string]$directory.Path)
        if($currentPath -ine $rootPath -and -not $currentPath.StartsWith($rootPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Oracle external-material traversal escaped its effective configuration root.'}
        $directoryItem=Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if(-not $directoryItem.PSIsContainer -or ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Oracle external-material traversal encountered a non-directory or reparse point.'}
        $enumerator=Get-WsmOracleDirectoryEnumerator $currentPath
        try {
            while($enumerator.MoveNext()){
                $visited++;if($visited -gt $MaxEntries){throw 'Oracle external-material discovery exceeds its bounded entry budget.'}
                $childPath=[IO.Path]::GetFullPath([string]$enumerator.Current)
                if(-not $childPath.StartsWith($rootPath.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Oracle external-material child escaped its effective configuration root.'}
                $child=Get-Item -LiteralPath $childPath -Force -ErrorAction Stop
                if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Oracle external-material traversal encountered a reparse point.'}
                $isMaterial=($child.Name -match '(?i)^(cwallet\.sso|ewallet\.(p12|pfx)|wallet|.*\.(p12|pfx|key|pem|der|jks|sso))$')
                if($isMaterial){$candidates.Add([pscustomobject]@{Path=[string]$child.FullName;IsDirectory=[bool]$child.PSIsContainer});continue}
                if($child.PSIsContainer){
                    if([int]$directory.Depth -ge $MaxDepth){throw 'Oracle external-material discovery reached its bounded depth limit.'}
                    $pending.Push([pscustomobject]@{Path=[string]$child.FullName;Depth=([int]$directory.Depth+1)})
                }
            }
        } finally {if($enumerator -is [IDisposable]){$enumerator.Dispose()}}
    }
    [pscustomobject][ordered]@{Candidates=@($candidates.ToArray());VisitedEntries=$visited;MaxEntries=$MaxEntries;MaxDepth=$MaxDepth;Status='Success'}
}
function Get-WsmOracleConfigFileClosure([string[]]$StartPaths,[string]$ScopeRoot,[string[]]$ExcludedRelativePaths,[string[]]$ApprovedIFiles) {
    $files=New-Object 'System.Collections.Generic.List[object]';$issues=New-Object 'System.Collections.Generic.List[object]';$stack=New-Object 'System.Collections.Generic.Stack[object]';$seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$approved=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($path in $ApprovedIFiles){[void]$approved.Add([IO.Path]::GetFullPath($path))}
    foreach($path in $StartPaths){$stack.Push([pscustomobject]@{Path=$path;Depth=0;Ancestors=@()})}
    $total=[long]0;$walletReferences=New-Object 'System.Collections.Generic.List[string]'
    while($stack.Count){
        $node=$stack.Pop();$resolved=$null
        try{$resolved=Resolve-WsmOracleLocalFile $node.Path $ScopeRoot $ExcludedRelativePaths}catch{$issues.Add([pscustomobject]@{Path=$node.Path;Code='UnsafeOrMissingReference';Reason=$_.Exception.Message});continue}
        $full=$resolved.FullPath
        if(@($node.Ancestors | Where-Object {$_ -ieq $full}).Count){$issues.Add([pscustomobject]@{Path=$resolved.RelativePath;Code='IFILECycle';Reason='IFILE reference cycle detected.'});continue}
        if($seen.Contains($full)){continue}
        if($node.Depth -gt 3){$issues.Add([pscustomobject]@{Path=$resolved.RelativePath;Code='IFILENestingLimit';Reason='Oracle Net supports at most three nested IFILE levels.'});continue}
        if($files.Count -ge 4096){$issues.Add([pscustomobject]@{Path=$resolved.RelativePath;Code='FileCountBudgetExceeded';Reason='Oracle config closure exceeds the 4,096-file metadata budget.'});break}
        [void]$seen.Add($full)
        try{
            $file=Get-WsmOracleFileEncodingAndReferences $full;$total+=$file.Bytes
            foreach($referenceHash in @($file.WalletReferenceHashes)){$walletReferences.Add([string]$referenceHash)}
            if($total -gt 67108864){throw 'Oracle config closure exceeds the 64 MiB bounded total.'}
            $physical=Get-WsmPhysicalPath $full;$physicalRoot=Get-WsmPhysicalPath $ScopeRoot
            if(-not $physical.StartsWith($physicalRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {throw 'Oracle config physical path escapes approved FileScope.'}
            $files.Add([pscustomobject]@{RelativePath=$resolved.RelativePath;Path=$full;Bytes=$file.Bytes;SHA256=$file.SHA256;Encoding=$file.Encoding;IFILE=@($file.IFILE);WalletReferenceHashes=@($file.WalletReferenceHashes)})
            foreach($reference in $file.IFILE){
                if($node.Depth -ge 3){$issues.Add([pscustomobject]@{Path=$resolved.RelativePath;Code='IFILENestingLimit';Reason='Oracle Net supports at most three nested IFILE levels.'});continue}
                if(-not [IO.Path]::IsPathRooted($reference) -or $reference -match '^\\\\'){$issues.Add([pscustomobject]@{Path=$resolved.RelativePath;Code='IFILEPathUnsupported';Reason='Only explicit local absolute IFILE paths within the approved scope are supported.'});continue}
                $referencePath=[IO.Path]::GetFullPath($reference)
                if(-not $approved.Contains($referencePath)){$issues.Add([pscustomobject]@{Path=$referencePath;Code='IFILENotOwnerApproved';Reason='IFILE target is not present in the owner-approved IFILE list.'});continue}
                $stack.Push([pscustomobject]@{Path=$referencePath;Depth=($node.Depth+1);Ancestors=@($node.Ancestors)+@($full)})
            }
        }catch{$issues.Add([pscustomobject]@{Path=$resolved.RelativePath;Code='ParserUnknown';Reason=$_.Exception.Message})}
    }
    [pscustomobject]@{Files=@($files.ToArray());Issues=@($issues.ToArray());Bytes=$total;WalletReferenceHashes=@($walletReferences.ToArray() | Sort-Object -Unique);Valid=($issues.Count -eq 0)}
}
function Get-WsmOracleFileSensitivity([string]$Role) {
    switch($Role){'TnsNames'{'NetworkEndpointConfig'}'SqlNet'{'MayReferenceCredentialsOrWallet'}'Ldap'{'DirectoryServiceConfig'}'OraAccess'{'ProviderAccessConfig'}'IncludedFile'{'OwnerApprovedIncludedConfig'}default{'UnknownSensitiveConfig'}}
}
function Get-WsmOracleClientConfigDraft {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InventoryPath,[Parameter(Mandatory)][string]$ExpectedInventoryHash,[Parameter(Mandatory)][string]$SoftwareCatalogPath,[Parameter(Mandatory)][string]$ExpectedSoftwareCatalogHash,[Parameter(Mandatory)][string]$FileScopeSpecPath,[Parameter(Mandatory)][string]$ExpectedSpecHash,[Parameter(Mandatory)][string]$ConsumerBindingPath,[Parameter(Mandatory)][string]$ExpectedBindingHash,[Parameter(Mandatory)][string]$Path)
    $inventory=Read-WsmTrustedJson $InventoryPath $ExpectedInventoryHash;Assert-WsmInventory $inventory
    $spec=Read-WsmTrustedJson $FileScopeSpecPath $ExpectedSpecHash;Assert-WsmMigrationSpec $spec
    if($spec.Adapter -cne 'FileScope' -or [string]::IsNullOrWhiteSpace([string]$spec.SourcePath) -or [string]::IsNullOrWhiteSpace([string]$spec.TargetPath)){throw 'Oracle client config requires an approved FileScope with source and target roots.'}
    $scopeRoot=[IO.Path]::GetFullPath([string]$spec.SourcePath);if($scopeRoot.StartsWith('\\')){throw 'Oracle config FileScope cannot use UNC/remote source paths.'};Assert-WsmNoReparse $scopeRoot
    $targetRoot=[IO.Path]::GetFullPath([string]$spec.TargetPath);if($targetRoot.StartsWith('\\')){throw 'Oracle config FileScope cannot use UNC/remote target paths.'}
    $catalog=Read-WsmOracleSoftwareCatalog $SoftwareCatalogPath $ExpectedSoftwareCatalogHash $inventory
    $binding=Read-WsmOracleConsumerBinding $ConsumerBindingPath $ExpectedBindingHash $inventory $ExpectedInventoryHash $SoftwareCatalogPath $ExpectedSoftwareCatalogHash
    if($binding.InventoryHash -ine $ExpectedInventoryHash){throw 'Oracle consumer binding inventory hash does not match the pinned source inventory.'}
    $candidates=Get-WsmOracleClientCandidates $inventory $binding
    $excluded=@($spec.ExcludedRelativePaths);$entryMap=@{};$issues=New-Object 'System.Collections.Generic.List[object]';$external=New-Object 'System.Collections.Generic.List[object]';$consumerResults=New-Object 'System.Collections.Generic.List[object]'
    foreach($consumer in $binding.Consumers){
        $validIds=@($consumer.ConsumerItemIds)
        $candidateMatches=@($candidates.Candidates | Where-Object { $_.Source -cne 'ApplicationConfig' -and $_.Name -ieq 'TNS_ADMIN' -and $_.Value -and [IO.Path]::GetFullPath([string]$_.Value) -ieq [IO.Path]::GetFullPath([string]$consumer.ObservedEffectivePath) })
        $applicationCandidateMatches=@($candidates.Candidates | Where-Object { $_.Source -ceq 'ApplicationConfig' -and $_.Name -ieq 'TNS_ADMIN' -and $_.Value -and [IO.Path]::GetFullPath([string]$_.Value) -ieq [IO.Path]::GetFullPath([string]$consumer.ObservedEffectivePath) })
        $effective=[IO.Path]::GetFullPath([string]$consumer.ObservedEffectivePath)
        $closureValid=$false
        try{
            if(-not [IO.Directory]::Exists($effective)){throw 'Owner-observed effective TNS_ADMIN/config path is absent.'}
            Assert-WsmNoReparse $effective
            if($effective -ine $scopeRoot -and -not $effective.StartsWith($scopeRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Owner-observed effective config path is outside approved FileScope.'}
            $startPaths=New-Object 'System.Collections.Generic.List[string]'
            $roles=@(@{Name='tnsnames.ora';Role='TnsNames'},@{Name='sqlnet.ora';Role='SqlNet'},@{Name='ldap.ora';Role='Ldap'},@{Name='oraaccess.xml';Role='OraAccess'})
            foreach($config in $roles){$filePath=Join-Path $effective $config.Name;if([IO.File]::Exists($filePath)){$startPaths.Add($filePath)}}
            if(-not $startPaths.Count){throw 'No supported Oracle client config file was found at the owner-observed effective path.'}
            $approvedIFiles=@($consumer.ApprovedIFiles)
            $closure=Get-WsmOracleConfigFileClosure $startPaths.ToArray() $scopeRoot $excluded $approvedIFiles
            foreach($issue in $closure.Issues){$issues.Add([pscustomobject]@{ConsumerId=$consumer.ConsumerId;ConsumerItemIds=$validIds;Code=$issue.Code;Path=$issue.Path;Reason=$issue.Reason})}
            if(-not $closure.Valid){throw 'Oracle config closure contains blocked references.'}
            foreach($referenceHash in @($closure.WalletReferenceHashes)){$external.Add([pscustomobject]@{ConsumerId=$consumer.ConsumerId;RelativePath=('ExternalReference-'+([string]$referenceHash).Substring(0,16));Class='ExternalSecretOrWallet';Status='ExternalRequired';IncludedInPackage=$false;ReferenceHash=[string]$referenceHash;ScopeRelation='Unknown'});$issues.Add([pscustomobject]@{ConsumerId=$consumer.ConsumerId;ConsumerItemIds=$validIds;Code='ExternalWalletReferenceRequiresOwnerDelivery';Path=('ExternalReference-'+([string]$referenceHash).Substring(0,16));Reason='Oracle config references an external wallet; owner must complete and attest its external delivery before activation.'})}
            foreach($file in $closure.Files){
                $role='IncludedFile';$leaf=[IO.Path]::GetFileName($file.RelativePath)
                if($leaf -ieq 'tnsnames.ora'){$role='TnsNames'}elseif($leaf -ieq 'sqlnet.ora'){$role='SqlNet'}elseif($leaf -ieq 'ldap.ora'){$role='Ldap'}elseif($leaf -ieq 'oraaccess.xml'){$role='OraAccess'}
                $targetRelative=$file.RelativePath
                $consumerContext=[pscustomobject][ordered]@{ConsumerId=$consumer.ConsumerId;ProviderSoftwareId=$consumer.ProviderSoftwareId;ProviderItemId=$consumer.ProviderItemId;Provider=$consumer.Provider;Version=$consumer.Version;Architecture=$consumer.Architecture;OracleHome=[IO.Path]::GetFullPath([string]$consumer.OracleHome);AccountType=$consumer.AccountType;AccountName=$consumer.AccountName;AccountSid=$consumer.AccountSid;ConsumerItemIds=$validIds;ObservedEffectivePath=$effective;Owner=$consumer.Owner;Evidence=$consumer.Evidence;OwnerAttestedStaticOnly=$true;ConnectionProofStatus='NotTested'}
                if(-not $entryMap.ContainsKey($file.RelativePath)){$entryMap[$file.RelativePath]=[pscustomobject]@{File=$file;Role=$role;TargetRelativePath=$targetRelative;Owner=$consumer.Owner;Evidence=$consumer.Evidence;Contexts=(New-Object 'System.Collections.Generic.List[object]')}}
                $entry=$entryMap[$file.RelativePath]
                if($entry.Owner -cne $consumer.Owner){throw ('Shared Oracle config has multiple authoritative owners: '+$file.RelativePath)}
                if(-not @($entry.Contexts | Where-Object ConsumerId -CEQ $consumer.ConsumerId).Count){$entry.Contexts.Add($consumerContext)}
            }
            $externalScan=Get-WsmOracleExternalMaterialCandidates -Root $effective -MaxEntries 4096 -MaxDepth 16
            foreach($material in @($externalScan.Candidates)){$materialRelative=[string]$material.Path.Substring($scopeRoot.Length).TrimStart('\');$materialIsExcluded=Test-WsmOraclePathExcluded $materialRelative $excluded;$external.Add([pscustomobject]@{ConsumerId=$consumer.ConsumerId;RelativePath=$materialRelative;Class='ExternalSecretOrWallet';Status='ExternalRequired';IncludedInPackage=$false;ReferenceHash='';ScopeRelation='InsideScope'});if(-not $materialIsExcluded){$issues.Add([pscustomobject]@{ConsumerId=$consumer.ConsumerId;ConsumerItemIds=$validIds;Code='ExternalMaterialInsidePackageScope';Path=$materialRelative;Reason='Wallet/private key material must be excluded from the general FileScope and handled externally.'})}}
            $listener=Join-Path $effective 'listener.ora';if([IO.File]::Exists($listener)){$listenerRelative=$listener.Substring($scopeRoot.Length).TrimStart('\');$listenerIsExcluded=Test-WsmOraclePathExcluded $listenerRelative $excluded;$external.Add([pscustomobject]@{ConsumerId=$consumer.ConsumerId;RelativePath=$listenerRelative;Class='SpecialProductListenerConfig';Status='ExternalProductWorkflowRequired';IncludedInPackage=$false;ReferenceHash='';ScopeRelation='InsideScope'});if(-not $listenerIsExcluded){$issues.Add([pscustomobject]@{ConsumerId=$consumer.ConsumerId;ConsumerItemIds=$validIds;Code='ListenerInsidePackageScope';Path=$listenerRelative;Reason='listener.ora is special-product configuration and must be explicitly excluded from general FileScope.'})}}
            $closureValid=$true
        }catch{
            $closureValid=$false
            $issueCode='EffectiveConfigBlocked';if($_.Exception.Message -match 'external-material|bounded (?:entry|depth) limit|reparse point'){$issueCode='ExternalMaterialDiscoveryIncomplete'}
            $issues.Add([pscustomobject]@{ConsumerId=$consumer.ConsumerId;ConsumerItemIds=$validIds;Code=$issueCode;Path=$consumer.ObservedEffectivePath;Reason=$_.Exception.Message})
        }
        $consumerResults.Add([pscustomobject][ordered]@{ConsumerId=$consumer.ConsumerId;ConsumerItemIds=$validIds;Provider=$consumer.Provider;Version=$consumer.Version;Architecture=$consumer.Architecture;OracleHome=$consumer.OracleHome;AccountType=$consumer.AccountType;AccountName=$consumer.AccountName;AccountSid=$consumer.AccountSid;ObservedEffectivePath=$effective;NativeTnsAdminCandidateMatched=($candidateMatches.Count -gt 0);ApplicationTnsAdminCandidateMatched=($applicationCandidateMatches.Count -gt 0);SelectionRule='Owner-supplied effective observation; no universal precedence assumed';Owner=$consumer.Owner;Evidence=$consumer.Evidence;Status=$(if($closureValid){'OwnerAttestedStaticOnly'}else{'Blocked'});ConnectionProofStatus='NotTested';ProductionVerified=$false})
    }
    $configFiles=New-Object 'System.Collections.Generic.List[object]'
    foreach($relative in @($entryMap.Keys | Sort-Object -CaseSensitive)){
        $entry=$entryMap[$relative]
        $consumers=@($entry.Contexts.ToArray() | Sort-Object ConsumerId -Unique)
        $contextsIds=@($consumers | ForEach-Object ConsumerId)
        $externalForFile=@($external | Where-Object {$contextsIds -contains $_.ConsumerId} | ForEach-Object {[pscustomobject]@{RelativePath=$_.RelativePath;Class=$_.Class;Status=$_.Status;IncludedInPackage=$false;ReferenceHash=$_.ReferenceHash;ScopeRelation=$_.ScopeRelation}} | Sort-Object RelativePath -Unique)
        $client=[pscustomobject][ordered]@{ContractVersion=1;BindingHash=$ExpectedBindingHash.ToLowerInvariant();Role=$entry.Role;Encoding=$entry.File.Encoding;Sensitivity=(Get-WsmOracleFileSensitivity $entry.Role);TargetRelativePath=$entry.TargetRelativePath;Consumers=$consumers;ExternalMaterials=$externalForFile}
        $configFiles.Add([pscustomobject][ordered]@{RelativePath=$relative;SHA256=$entry.File.SHA256;Owner=$entry.Owner;Evidence=$entry.Evidence;OracleClient=$client})
    }
    $projection=$configFiles.ToArray() | ConvertTo-Json -Depth 20 -Compress
    $configHash=Get-WsmHashText $projection
    $requirementDrafts=New-Object 'System.Collections.Generic.List[object]'
    foreach($consumer in $consumerResults){
        $providerBinding=@($binding.Consumers | Where-Object ConsumerId -CEQ $consumer.ConsumerId)[0]
        $context=[pscustomobject][ordered]@{Provider=$consumer.Provider;Version=$consumer.Version;Architecture=$consumer.Architecture;OracleHome=$consumer.OracleHome;ProviderItemId=[string]$providerBinding.ProviderItemId;AccountType=$consumer.AccountType;AccountName=$consumer.AccountName;AccountSid=$consumer.AccountSid;ObservedEffectivePath=$consumer.ObservedEffectivePath;ConsumerItemIds=@($consumer.ConsumerItemIds);OwnerBindingHash=$ExpectedBindingHash.ToLowerInvariant();ConfigFilesHash=$configHash}
        # The GH Preparation contract requires exactly one typed provider
        # identity. Bind to stable B1 SoftwareId; preserve an optional linked
        # source ItemId as evidence in Context without creating a dual provider.
        $requirement=[pscustomobject][ordered]@{Type='Preparation';ProviderSoftwareId=[string]$providerBinding.ProviderSoftwareId;ProviderItemId='';ExternalId='';ConsumerItemIds=@($consumer.ConsumerItemIds);RequiredPhase='StagedDependencyVerified';ExpectedVersion=$consumer.Version;Architecture=$consumer.Architecture;Context=$context;Owner=$consumer.Owner;SourceProof=[pscustomobject]@{InventoryHash=$ExpectedInventoryHash.ToLowerInvariant();OwnerBindingHash=$ExpectedBindingHash.ToLowerInvariant();ObservedEffectivePath=$consumer.ObservedEffectivePath;ConfigFilesHash=$configHash;Status='OwnerAttestedStaticOnly';ProofStatus='NotTested'}}
        $idCommand=Get-Command Get-WsmGeneralHostRequirementId -ErrorAction SilentlyContinue;if(-not $idCommand){throw 'Typed GeneralHost requirement ID helper is unavailable; Oracle requirement cannot be emitted safely.'};$requirementId=Get-WsmGeneralHostRequirementId -Requirement $requirement
        $requirement | Add-Member NoteProperty RequirementId $requirementId
        $requirementDrafts.Add($requirement)
        $externalContext=[pscustomobject][ordered]@{Provider=$consumer.Provider;Version=$consumer.Version;Architecture=$consumer.Architecture;OracleHome=$consumer.OracleHome;AccountType=$consumer.AccountType;AccountName=$consumer.AccountName;AccountSid=$consumer.AccountSid;ObservedEffectivePath=$consumer.ObservedEffectivePath;ConsumerItemIds=@($consumer.ConsumerItemIds);OwnerBindingHash=$ExpectedBindingHash.ToLowerInvariant();ConfigFilesHash=$configHash;ProofStatus='NotTested'}
        $externalRequirement=[pscustomobject][ordered]@{Type='ExternalDependency';ProviderSoftwareId='';ProviderItemId='';ExternalId=('oracle-consumer:'+([string]$consumer.ConsumerId));ConsumerItemIds=@($consumer.ConsumerItemIds);RequiredPhase='CutoverReady';ExpectedVersion=$consumer.Version;Architecture=$consumer.Architecture;Context=$externalContext;Owner=$consumer.Owner;SourceProof=[pscustomobject]@{EvidenceKind='ExternalOwner';InventoryHash=$ExpectedInventoryHash.ToLowerInvariant();OwnerBindingHash=$ExpectedBindingHash.ToLowerInvariant();ConfigFilesHash=$configHash;Status='Required';ProofStatus='NotTested'}}
        $externalIdCommand=Get-Command Get-WsmGeneralHostRequirementId -ErrorAction SilentlyContinue;if(-not $externalIdCommand){throw 'Typed GeneralHost requirement ID helper is unavailable; Oracle requirement cannot be emitted safely.'};$externalRequirementId=Get-WsmGeneralHostRequirementId -Requirement $externalRequirement
        $externalRequirement | Add-Member NoteProperty RequirementId $externalRequirementId
        $requirementDrafts.Add($externalRequirement)
    }
    $output=[IO.Path]::GetFullPath($Path);$outputDirectory=[IO.Path]::GetDirectoryName($output);Assert-WsmNoReparse $outputDirectory
    if([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)){throw 'Oracle config draft output must be a new file.'}
    if((Test-WsmPathOverlap (Get-WsmPhysicalPath $outputDirectory) (Get-WsmPhysicalPath $scopeRoot))){throw 'Oracle config draft output overlaps the approved FileScope.'}
    $draft=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OracleClientConfigDraft';DraftVersion=1;SourceHostId=$inventory.Source.HostId;SourceFingerprint=$inventory.Source.Fingerprint;InventoryHash=$ExpectedInventoryHash.ToLowerInvariant();SoftwareCatalogHash=$ExpectedSoftwareCatalogHash.ToLowerInvariant();FileScopeSpecHash=$ExpectedSpecHash.ToLowerInvariant();OwnerBindingHash=$ExpectedBindingHash.ToLowerInvariant();TargetRoot=$targetRoot;Status=$(if($issues.Count){'Blocked'}elseif($configFiles.Count){'OwnerAttestedStaticOnly'}else{'Blocked'});ConfigFiles=$configFiles.ToArray();Consumers=$consumerResults.ToArray();CandidateObservations=$candidates;Requirements=$requirementDrafts.ToArray();ExternalMaterials=$external.ToArray();Issues=$issues.ToArray();ConfigFilesProjectionHash=$configHash;ConnectionProofStatus='NotTested';ProductionVerified=$false}
    $temp=$output+'.'+[Guid]::NewGuid().ToString('N')+'.partial'
    try{Write-WsmJson $temp $draft;if([IO.File]::Exists($output)){throw 'Oracle config draft output appeared during write.'};[IO.File]::Move($temp,$output)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    [pscustomobject]@{Path=$output;SHA256=(Get-FileHash -LiteralPath $output).Hash;Status=$draft.Status;ConfigCount=$configFiles.Count;ConsumerCount=$consumerResults.Count;IssueCount=$issues.Count;OwnerBindingHash=$ExpectedBindingHash.ToLowerInvariant();ConnectionProofStatus='NotTested';ProductionVerified=$false}
}
