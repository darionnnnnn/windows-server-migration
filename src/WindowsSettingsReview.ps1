function Get-WsmWindowsSettingValueHash($Value) {
    $json=ConvertTo-Json -InputObject $Value -Depth 40 -Compress
    Get-WsmHashText $json
}

function Get-WsmWindowsSettingControlSource($Settings) {
    # Any explicit GPO evidence dominates. Local is accepted only when every
    # present provenance signal is an exact recognized Local enum/value.
    $signals=New-Object 'System.Collections.Generic.List[string]'
    if($Settings -and $Settings.PSObject.Properties['WindowsSettingMetadata']){
        $metadata=$Settings.WindowsSettingMetadata
        if($metadata -and $metadata.PSObject.Properties['ControlSource']){$signals.Add([string]$metadata.ControlSource)}
    }
    if($Settings -and $Settings.PSObject.Properties['Rule'] -and $Settings.Rule -and $Settings.Rule.PSObject.Properties['PolicyStoreSourceType']){$signals.Add([string]$Settings.Rule.PolicyStoreSourceType)}
    foreach($name in @('ControlSource','ManagementSource','PolicySource')){if($Settings -and $Settings.PSObject.Properties[$name]){$signals.Add([string]$Settings.$name)}}
    if(@($signals | Where-Object {$_ -match '(?i)^(GroupPolicy|GPO)$|Group Policy'}).Count){return 'GPO'}
    if($signals.Count -eq 0){return 'Unknown'}
    foreach($value in $signals){if($value -cnotmatch '^(?i:Local)$'){return 'Unknown'}}
    'Local'
}

function ConvertTo-WsmWindowsSettingSafeText([string]$Text,[int]$Maximum=512) {
    $safe=[regex]::Replace($Text,'[\x00-\x1f\x7f]',' ')
    $safe=$safe.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('`','&#96;')
    if($safe.Length -gt $Maximum){$safe=$safe.Substring(0,$Maximum)+'…'}
    $safe
}

function Test-WsmWindowsSettingSecret([string]$Name,[string]$Value) {
    if($Name -match '(?i)(^|[._-])(LOCAL|PASSWORD|PWD|SECRET|TOKEN|CREDENTIAL|CONNECTIONSTRING)([._-]|$)'){return $true}
    $Value -match '(?i)(password|pwd|secret|token|credential|connectionstring)\s*[:=]|://[^\s/:]+:[^\s/@]+@|Data Source\s*=|User ID\s*='
}

function Get-WsmWindowsSettingDisplayValue($Value) {
    if($Value -and $Value.PSObject.Properties['Exists'] -and $Value.PSObject.Properties['ValueKind'] -and $Value.PSObject.Properties['Value']){
        if(-not [bool]$Value.Exists){return $null}
        return $Value.Value
    }
    $Value
}

function Test-WsmWindowsSettingStateEqual($Actual,$Expected,[string]$Adapter) {
    try{
        Assert-WsmSettingValueState $Actual $Adapter;Assert-WsmSettingValueState $Expected $Adapter
    }catch{return $false}
    if([bool]$Actual.Exists -ne [bool]$Expected.Exists -or [string]$Actual.ValueKind -cne [string]$Expected.ValueKind){return $false}
    if($Actual.Exists -and [string]$Actual.Value -cne [string]$Expected.Value){return $false}
    if($Adapter -eq 'TimeZone'){
        $a=$Actual.DaylightSaving;$e=$Expected.DaylightSaving
        if([bool]$a.Exists -ne [bool]$e.Exists -or [string]$a.ValueKind -cne [string]$e.ValueKind -or ($a.Exists -and [bool]$a.Value -ne [bool]$e.Value)){return $false}
    }
    $true
}

function Get-WsmWindowsSettingSafeSummary([string]$Kind,[string]$SettingName,$Value,[string]$EvidenceHash) {
    $hash=Get-WsmWindowsSettingValueHash $Value;$pointer=$EvidenceHash;if($pointer -notmatch '^[a-fA-F0-9]{64}$'){$pointer=$hash}
    $displayValue=Get-WsmWindowsSettingDisplayValue $Value
    $secretScan=[string]$displayValue;if($Kind -eq 'HostsFile' -and $displayValue -and $displayValue.PSObject.Properties['Content']){$secretScan=[string]$displayValue.Content}
    if(Test-WsmWindowsSettingSecret $SettingName $secretScan){return [pscustomobject][ordered]@{Display='[REDACTED: sensitive value]';ValueHash=$hash;EvidencePointer=$pointer;Redacted=$true}}
    if($Kind -eq 'HostsFile'){
        $Value=$displayValue;if($Value -and $Value.PSObject.Properties['Content']){$Value=$Value.Content}
        $hosts=New-Object 'System.Collections.Generic.List[object]'
        foreach($line in @(([string]$Value -split "`r?`n") | Where-Object {$_.Trim()})){$parts=@((($line -replace '#.*$','').Trim() -split '\s+') | Where-Object {$_});if($parts.Count -lt 2 -or $parts[0] -notmatch '^[0-9a-fA-F:.]+$'){continue};$loopback=($parts[0] -match '^(?i:127\.)' -or $parts[0] -ceq '::1');$hosts.Add([pscustomobject]@{Address=(ConvertTo-WsmWindowsSettingSafeText $parts[0] 64);Names=@($parts[1..($parts.Count-1)] | ForEach-Object {ConvertTo-WsmWindowsSettingSafeText ([string]$_) 255});Loopback=$loopback;Movable=$false;Risk=$(if($loopback){'LoopbackBaselineNeverCopy'}else{'OwnerReviewRequired'});LineHash=(Get-WsmWindowsSettingValueHash ([string]$line))})}
        return [pscustomobject][ordered]@{Display=('{0} host entries; controlled internal review' -f $hosts.Count);ValueHash=$hash;EvidencePointer=$pointer;Redacted=$false;Hosts=$hosts.ToArray()}
    }
    if($SettingName -match '(?i)(^|\.)PATH$'){
        $components=@(([string]$displayValue -split ';') | Where-Object {$_ -ne ''} | ForEach-Object {if(Test-WsmWindowsSettingSecret $SettingName $_){'[REDACTED]'}else{ConvertTo-WsmWindowsSettingSafeText $_ 512}})
        return [pscustomobject][ordered]@{Display=('{0} PATH components' -f $components.Count);ValueHash=$hash;EvidencePointer=$pointer;Redacted=(@($components | Where-Object {$_ -eq '[REDACTED]'}).Count -gt 0);Components=$components}
    }
    if($SettingName -match '^(?i:TimeZone)$'){$display=[string]$displayValue;$dst='Unknown';if($displayValue -and $displayValue.PSObject.Properties['Id']){$display=[string]$displayValue.Id};if($displayValue -and $displayValue.PSObject.Properties['SupportsDaylightSavingTime']){$dst=[string]$displayValue.SupportsDaylightSavingTime};$dstState=$null;if($Value -and $Value.PSObject.Properties['DaylightSaving']){$dstState=$Value.DaylightSaving;if($dstState -and $dstState.PSObject.Properties['Exists']){$dst=('Exists={0}; Value={1}; ValueKind={2}' -f $dstState.Exists,$dstState.Value,$dstState.ValueKind)}};return [pscustomobject][ordered]@{Display=(ConvertTo-WsmWindowsSettingSafeText $display 128);DaylightSaving=$dst;DaylightSavingState=$dstState;ValueKind=$(if($Value -and $Value.PSObject.Properties['ValueKind']){[string]$Value.ValueKind}else{''});ValueHash=$hash;EvidencePointer=$pointer;Redacted=$false}}
    if($SettingName -match '^(?i:Environment\.(TNS_ADMIN|NLS_LANG|LDAP_ADMIN|ORA_TZFILE))$'){$exists=$true;$text=[string]$displayValue;$kind='';if($Value -and $Value.PSObject.Properties['ValueKind']){$kind=[string]$Value.ValueKind;$exists=[bool]$Value.Exists;if(-not $exists){$text='[setting absent]'}};$summary=[ordered]@{Display=(ConvertTo-WsmWindowsSettingSafeText $text 512);ValueHash=$hash;EvidencePointer=$pointer;Redacted=$false};if($Value -and $Value.PSObject.Properties['ValueKind']){$summary.ValueKind=$kind;$summary.Exists=$exists};return [pscustomobject]$summary}
    if($SettingName -match '^(?i:Culture|UICulture)$'){return [pscustomobject][ordered]@{Display=(ConvertTo-WsmWindowsSettingSafeText ([string]$Value) 128);ValueHash=$hash;EvidencePointer=$pointer;Redacted=$false}}
    [pscustomobject][ordered]@{Display=$(if($Value -and $Value.PSObject.Properties['Exists'] -and -not $Value.Exists){'[setting absent]'}else{'[value omitted; owner review required]'});ValueHash=$hash;EvidencePointer=$pointer;Redacted=$true;ValueKind=$(if($Value -and $Value.PSObject.Properties['ValueKind']){[string]$Value.ValueKind}else{''});Exists=$(if($Value -and $Value.PSObject.Properties['Exists']){[bool]$Value.Exists}else{$null})}
}

function Get-WsmWindowsSettingEnvironmentNames($Environment,$EnvironmentStates) {
    $names=New-Object 'System.Collections.Generic.List[string]'
    if($Environment -is [System.Collections.IDictionary]){foreach($name in $Environment.Keys){$names.Add([string]$name)}}
    elseif($Environment){foreach($entry in $Environment.PSObject.Properties){$names.Add([string]$entry.Name)}}
    if($EnvironmentStates -is [System.Collections.IDictionary]){foreach($name in $EnvironmentStates.Keys){if(-not $names.Contains([string]$name)){$names.Add([string]$name)}}}
    elseif($EnvironmentStates){foreach($entry in $EnvironmentStates.PSObject.Properties){if(-not $names.Contains([string]$entry.Name)){$names.Add([string]$entry.Name)}}}
    @($names.ToArray() | Sort-Object -CaseSensitive -Unique)
}

function Get-WsmWindowsSettingEnvironmentValue($Environment,$EnvironmentStates,[string]$Name) {
    if($EnvironmentStates -is [System.Collections.IDictionary]){if($EnvironmentStates.Contains($Name)){return $EnvironmentStates[$Name]}}
    elseif($EnvironmentStates -and $EnvironmentStates.PSObject.Properties[$Name]){return $EnvironmentStates.$Name}
    if($Environment -is [System.Collections.IDictionary]){return $Environment[$Name]}
    if($Environment -and $Environment.PSObject.Properties[$Name]){return $Environment.$Name}
    $null
}

function Test-WsmWindowsSettingEnvironmentCapture($Environment,$State,[string]$Name) {
    if(-not $State -or -not $State.PSObject.Properties['Exists'] -or $State.Exists -isnot [bool]){return $false}
    try{Assert-WsmSettingValueState $State MachineEnvironment}catch{return $false}
    $found=$false;$rawValue=$null
    if($Environment -is [System.Collections.IDictionary]){foreach($key in $Environment.Keys){if([string]$key -ieq $Name){$found=$true;$rawValue=$Environment[$key];break}}}
    elseif($Environment){$property=@($Environment.PSObject.Properties | Where-Object Name -IEQ $Name | Select-Object -First 1);if($property.Count){$found=$true;$rawValue=$property[0].Value}}
    if([bool]$State.Exists){return ($found -and [string]$rawValue -ceq [string]$State.Value)}
    -not $found
}

function Test-WsmWindowsSettingTimeZoneCapture($LegacyValue,$State) {
    if(-not $State -or -not $State.PSObject.Properties['DaylightSaving']){return $false}
    try{Assert-WsmSettingValueState $State TimeZone}catch{return $false}
    $legacyId=$LegacyValue;if($LegacyValue -and $LegacyValue.PSObject.Properties['Id']){$legacyId=$LegacyValue.Id}
    [string]$legacyId -ceq [string]$State.Value
}

function Get-WsmWindowsSettingLeafRows($Inventory,[string]$Side) {
    if(-not $Inventory -or $Inventory.Items -isnot [array]){throw "$Side Windows settings inventory must contain an Items array."}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $allow=@{
        System=@('SystemConfiguration','ExecutionPolicy','MachineEnvironment','TimeZone')
        Network=@('HostsFile','RegistryEndpoint','FirewallRule','IPConfiguration','ProxyConfiguration','DnsConfiguration','RouteConfiguration')
        Identity=@('ServiceSecurity','TaskSecurity','LocalUser','LocalGroup','ServiceLogonRight')
        Certificates=@('Certificate','CertificateAcl')
    }
    foreach($item in @($Inventory.Items)){
        if(-not $item -or -not $item.PSObject.Properties['Category'] -or -not $item.PSObject.Properties['Kind']){continue}
        $category=[string]$item.Category;$kind=[string]$item.Kind
        if(-not $allow.ContainsKey($category) -or $kind -notin $allow[$category]){continue}
        $settings=$item.Settings
        if($kind -eq 'SystemConfiguration' -and $settings){
            foreach($property in @($settings.PSObject.Properties | Sort-Object Name -CaseSensitive)){
                if($property.Name -cin @('ControlSource','ManagementSource','PolicySource','Evidence','EvidenceHash','WindowsSettingMetadata')){continue}
                if($property.Name -eq 'Environment'){
                    $environment=$property.Value;$metadata=$null;if($settings.PSObject.Properties['WindowsSettingMetadata']){$metadata=$settings.WindowsSettingMetadata};$environmentStates=$null;if($metadata -and $metadata.PSObject.Properties['EnvironmentStates']){$environmentStates=$metadata.EnvironmentStates}
                    $environmentComplete=($metadata -and $metadata.PSObject.Properties['EnvironmentStatesComplete'] -and $metadata.EnvironmentStatesComplete -is [bool] -and [bool]$metadata.EnvironmentStatesComplete);foreach($name in @(Get-WsmWindowsSettingEnvironmentNames $environment $environmentStates)){$value=Get-WsmWindowsSettingEnvironmentValue $environment $environmentStates $name;$nativeStateValid=($value -and $value.PSObject.Properties['Exists'] -and (Test-WsmWindowsSettingEnvironmentCapture $environment $value $name));$rows.Add([pscustomobject]@{Category=$category;Kind=$kind;NaturalKey=([string]$item.NaturalKey);ItemId=[string]$item.ItemId;SettingName=('Environment.'+$name);Value=$value;ControlSource=(Get-WsmWindowsSettingControlSource $settings);Status=[string]$item.Status;EvidenceHash=[string]$item.SettingsHash;NativeStateComplete=[bool]$environmentComplete;NativeStateValid=[bool]$nativeStateValid;NativeStatePresent=($value -and $value.PSObject.Properties['Exists'] -and $value.Exists -is [bool] -and [bool]$value.Exists)})}
                }elseif($property.Name -eq 'TimeZone' -and $settings.PSObject.Properties['WindowsSettingMetadata'] -and $settings.WindowsSettingMetadata.PSObject.Properties['TimeZoneState']){$metadata=$settings.WindowsSettingMetadata;$timezoneComplete=($metadata.PSObject.Properties['TimeZoneStateComplete'] -and $metadata.TimeZoneStateComplete -is [bool] -and [bool]$metadata.TimeZoneStateComplete);$timezoneValid=Test-WsmWindowsSettingTimeZoneCapture $property.Value $metadata.TimeZoneState;$rows.Add([pscustomobject]@{Category=$category;Kind=$kind;NaturalKey=([string]$item.NaturalKey);ItemId=[string]$item.ItemId;SettingName='TimeZone';Value=$metadata.TimeZoneState;ControlSource=(Get-WsmWindowsSettingControlSource $settings);Status=[string]$item.Status;EvidenceHash=[string]$item.SettingsHash;NativeStateComplete=[bool]$timezoneComplete;NativeStateValid=[bool]$timezoneValid;NativeStatePresent=$true})}
                else{$rows.Add([pscustomobject]@{Category=$category;Kind=$kind;NaturalKey=([string]$item.NaturalKey);ItemId=[string]$item.ItemId;SettingName=[string]$property.Name;Value=$property.Value;ControlSource=(Get-WsmWindowsSettingControlSource $settings);Status=[string]$item.Status;EvidenceHash=[string]$item.SettingsHash})}
            }
        }elseif($kind -eq 'MachineEnvironment'){
            $rows.Add([pscustomobject]@{Category=$category;Kind=$kind;NaturalKey=([string]$item.NaturalKey);ItemId=[string]$item.ItemId;SettingName=('Environment.'+[string]$settings.Name);Value=$settings.Value;ControlSource=(Get-WsmWindowsSettingControlSource $settings);Status=[string]$item.Status;EvidenceHash=[string]$item.SettingsHash})
        }elseif($kind -eq 'TimeZone'){
            $metadata=$null;if($settings.PSObject.Properties['WindowsSettingMetadata']){$metadata=$settings.WindowsSettingMetadata};$value=$settings;$complete=$false;$valid=$false;if($metadata -and $metadata.PSObject.Properties['TimeZoneState']){$value=$metadata.TimeZoneState;$complete=($metadata.PSObject.Properties['TimeZoneStateComplete'] -and $metadata.TimeZoneStateComplete -is [bool] -and [bool]$metadata.TimeZoneStateComplete);$valid=Test-WsmWindowsSettingTimeZoneCapture $settings.TimeZone $value};$rows.Add([pscustomobject]@{Category=$category;Kind=$kind;NaturalKey=([string]$item.NaturalKey);ItemId=[string]$item.ItemId;SettingName='TimeZone';Value=$value;ControlSource=(Get-WsmWindowsSettingControlSource $settings);Status=[string]$item.Status;EvidenceHash=[string]$item.SettingsHash;NativeStateComplete=[bool]$complete;NativeStateValid=[bool]$valid;NativeStatePresent=$true})
        }else{
            $name=[string]$item.Name
            if($kind -eq 'HostsFile'){$name='hosts'}
            $rows.Add([pscustomobject]@{Category=$category;Kind=$kind;NaturalKey=([string]$item.NaturalKey);ItemId=[string]$item.ItemId;SettingName=$name;Value=$settings;ControlSource=(Get-WsmWindowsSettingControlSource $settings);Status=[string]$item.Status;EvidenceHash=[string]$item.SettingsHash})
        }
    }
    $rows.ToArray()
}

function Get-WsmWindowsSettingConsumers($SourceInventory,$GeneralHostCatalog,[string]$ProviderItemId) {
    $consumerIds=New-Object 'System.Collections.Generic.List[string]'
    foreach($item in @($SourceInventory.Items)){
        if($item.ItemId -ceq $ProviderItemId){continue}
        foreach($dependency in @($item.Dependencies)){
            if($dependency.ItemId -ceq $ProviderItemId -and $dependency.Type -in @('Mandatory','Required')){$consumerIds.Add([string]$item.ItemId)}
        }
    }
    if($GeneralHostCatalog -and $GeneralHostCatalog.PSObject.Properties['GeneralHost']){
        foreach($requirement in @($GeneralHostCatalog.GeneralHost.Requirements)){
            if($requirement.ProviderItemId -ceq $ProviderItemId -and $requirement.Certainty -ceq 'Required'){
                foreach($consumer in @($requirement.ConsumerItemIds)){$consumerIds.Add([string]$consumer)}
            }
        }
    }
    @($consumerIds.ToArray() | Sort-Object -Unique)
}

function Test-WsmWindowsSettingTransitionValue($Value,$Expected,[string]$Adapter) {
    if(-not $Value -or -not $Value.PSObject.Properties['Exists'] -or -not $Value.PSObject.Properties['ValueKind'] -or -not $Value.PSObject.Properties['Value']){return $false}
    try{Assert-WsmSettingValueState $Value $Adapter}catch{return $false}
    Test-WsmWindowsSettingStateEqual $Value $Expected $Adapter
}

function Test-WsmWindowsTargetEnvironmentAbsence($TargetInventory,$Row) {
    if($Row.SettingName -notmatch '^(?i:Environment\.)'){return $false}
    $name=$Row.SettingName.Substring('Environment.'.Length)
    $items=@($TargetInventory.Items | Where-Object {$_.Category -ceq 'System' -and $_.Kind -ceq 'SystemConfiguration' -and $_.NaturalKey -ceq $Row.NaturalKey})
    if($items.Count -ne 1 -or [string]$items[0].Status -cne 'Success' -or -not $items[0].Settings.PSObject.Properties['WindowsSettingMetadata']){return $false}
    $metadata=$items[0].Settings.WindowsSettingMetadata
    if((Get-WsmWindowsSettingControlSource $items[0].Settings) -cne 'Local' -or -not $metadata -or -not $metadata.PSObject.Properties['EnvironmentStatesComplete'] -or $metadata.EnvironmentStatesComplete -isnot [bool] -or -not $metadata.EnvironmentStatesComplete -or -not $metadata.PSObject.Properties['EnvironmentStates']){return $false}
    $states=$metadata.EnvironmentStates;$state=$null
    if($states -is [System.Collections.IDictionary]){if($states.Contains($name)){$state=$states[$name]}}
    elseif($states.PSObject.Properties[$name]){$state=$states.$name}
    if(-not $state -or -not $state.PSObject.Properties['Exists']){return $false}
    try{Assert-WsmSettingValueState $state MachineEnvironment}catch{return $false}
    (-not [bool]$state.Exists) -and (Test-WsmWindowsSettingEnvironmentCapture $items[0].Settings.Environment $state $name)
}

function Test-WsmWindowsTargetNetworkCaptureComplete($TargetInventory) {
    if(-not $TargetInventory -or $TargetInventory.Items -isnot [array]){return $false}
    $network=@($TargetInventory.Items | Where-Object {$_.Category -ceq 'Network'})
    $ipRows=@($network | Where-Object {$_.Kind -ceq 'IPConfiguration' -and [string]$_.Status -ceq 'Success'});if($ipRows.Count -ne 1){return $false}
    $firewallRows=@($network | Where-Object {$_.Kind -ceq 'FirewallRule'});$marker=$null;$settings=$ipRows[0].Settings
    if($settings -and $settings.PSObject.Properties['FirewallRuleEnumeration']){$marker=$settings.FirewallRuleEnumeration}
    $enumerationComplete=($marker -and $marker.PSObject.Properties['EnumerationComplete'] -and $marker.EnumerationComplete -is [bool] -and $marker.EnumerationComplete -and $marker.PSObject.Properties['TracePolicyStore'] -and $marker.TracePolicyStore -is [bool] -and $marker.TracePolicyStore -and $marker.PSObject.Properties['PolicyStore'] -and [string]$marker.PolicyStore -ceq 'ActiveStore' -and $marker.PSObject.Properties['RuleCount'] -and ($marker.RuleCount -is [int] -or $marker.RuleCount -is [long]) -and [long]$marker.RuleCount -ge 0 -and [long]$marker.RuleCount -eq [long]$firewallRows.Count)
    if(@($network | Where-Object {$_.Status -in @('Failed','PermissionDenied','Partial') -or ($_.Status -ceq 'Unsupported' -and -not ($enumerationComplete -and $_.Kind -ceq 'DiscoveryGap' -and $_.PSObject.Properties['NaturalKey'] -and $_.NaturalKey -ceq 'scope:Network')) -or $_.Kind -in @('CollectorFailure','UnsupportedCollector','DiscoveryRequirement')}).Count){return $false}
    if(@($network | Where-Object {$_.Kind -ceq 'DiscoveryGap' -and -not ($enumerationComplete -and $_.Status -ceq 'Unsupported' -and $_.PSObject.Properties['NaturalKey'] -and $_.NaturalKey -ceq 'scope:Network')}).Count){return $false}
    $true
}

function Test-WsmWindowsSettingReviewedMigration($Catalog,$Row,$TargetRow,$TargetInventory) {
    if(-not $Catalog -or -not $Catalog.PSObject.Properties['Items'] -or $Row.ControlSource -cne 'Local' -or [string]$Row.Status -cne 'Success'){return $false}
    $matches=@($Catalog.Items | Where-Object ItemId -CEQ $Row.SourceItemId);if($matches.Count -ne 1 -or -not $matches[0].PSObject.Properties['MigrationSpec'] -or -not $matches[0].MigrationSpec){return $false};$item=$matches[0];$spec=$item.MigrationSpec
    try{Assert-WsmMigrationSpec $spec | Out-Null}catch{return $false}
    if($spec.Adapter -eq 'FirewallRule'){
        if($Row.Kind -cne 'FirewallRule' -or $item.Kind -cne 'FirewallRule' -or $Row.CustomizationEvidenceHash -cne $item.SettingsHash){return $false}
        if($TargetRow){return ([string]$TargetRow.Status -ceq 'Success' -and $TargetRow.ControlSource -ceq 'Local')}
        return (Test-WsmWindowsTargetNetworkCaptureComplete $TargetInventory)
    }
    if($spec.Adapter -notin @('MachineEnvironment','TimeZone') -or -not $spec.PSObject.Properties['SettingTransition']){return $false}
    $transition=$spec.SettingTransition;try{Assert-WsmSettingTransition $transition | Out-Null}catch{return $false}
    if($transition.Adapter -cne $spec.Adapter){return $false}
    if($spec.Adapter -ceq 'TimeZone'){
        if($transition.Action -cne 'UpdateReviewed' -or $Row.SettingName -cne 'TimeZone' -or -not $Row.NativeStateComplete -or -not $Row.NativeStateValid -or -not $TargetRow -or [string]$TargetRow.Status -cne 'Success' -or $TargetRow.ControlSource -cne 'Local' -or -not $TargetRow.NativeStateComplete -or -not $TargetRow.NativeStateValid){return $false}
        if(-not (Test-WsmWindowsSettingTransitionValue $Row.Value $transition.After TimeZone)){return $false}
        return (Test-WsmWindowsSettingTransitionValue $TargetRow.Value $transition.Before TimeZone)
    }
    $expected='Environment.'+[string]$transition.Name
    if($Row.SettingName -cne $expected -or -not $Row.NativeStateComplete -or -not $Row.NativeStateValid -or -not (Test-WsmWindowsSettingTransitionValue $Row.Value $transition.After MachineEnvironment)){return $false}
    if($transition.Action -ceq 'UpdateReviewed'){
        if(-not $TargetRow -or [string]$TargetRow.Status -cne 'Success' -or $TargetRow.ControlSource -cne 'Local' -or -not $TargetRow.NativeStateComplete -or -not $TargetRow.NativeStateValid -or -not (Test-WsmWindowsSettingTransitionValue $TargetRow.Value $transition.Before MachineEnvironment)){return $false}
        return $true
    }
    if($transition.Action -ceq 'CreateNew'){
        return ((-not $transition.Before.Exists) -and $TargetRow -and [string]$TargetRow.Status -ceq 'Success' -and $TargetRow.ControlSource -ceq 'Local' -and (Test-WsmWindowsSettingTransitionValue $TargetRow.Value $transition.Before MachineEnvironment) -and (Test-WsmWindowsTargetEnvironmentAbsence $TargetInventory $Row))
    }
    $false
}

function Get-WsmWindowsManualMergeRows([string]$Kind,[string]$SettingName,$SourceValue,$TargetValue) {
    $merge=New-Object 'System.Collections.Generic.List[object]'
    if($Kind -eq 'HostsFile'){
        if($SourceValue -and $SourceValue.PSObject.Properties['Content']){$SourceValue=$SourceValue.Content}
        if($TargetValue -and $TargetValue.PSObject.Properties['Content']){$TargetValue=$TargetValue.Content}
        $sLines=@(([string]$sourceValue -split "`r?`n") | Where-Object {$_.Trim()})
        $tLines=@(([string]$targetValue -split "`r?`n") | Where-Object {$_.Trim()})
        $s=@{};for($i=0;$i -lt $sLines.Count;$i++){$hash=Get-WsmWindowsSettingValueHash ([string]$sLines[$i]);if(-not $s.ContainsKey($hash)){$s[$hash]=New-Object 'System.Collections.Generic.List[int]'};$s[$hash].Add($i+1)}
        $t=@{};for($i=0;$i -lt $tLines.Count;$i++){$hash=Get-WsmWindowsSettingValueHash ([string]$tLines[$i]);if(-not $t.ContainsKey($hash)){$t[$hash]=New-Object 'System.Collections.Generic.List[int]'};$t[$hash].Add($i+1)}
        foreach($hash in @(@($s.Keys)+@($t.Keys) | Sort-Object -Unique)){
            $side='Both';if(-not $t.ContainsKey($hash)){$side='SourceOnly'}elseif(-not $s.ContainsKey($hash)){$side='TargetOnly'}
            $line=$null;if($s.ContainsKey($hash)){$line=$s[$hash][0]}
            $matchedLine=[string](@($sLines+$tLines | Where-Object {(Get-WsmWindowsSettingValueHash ([string]$_)) -ceq $hash} | Select-Object -First 1))
            $parts=@((($matchedLine -replace '#.*$','').Trim() -split '\s+') | Where-Object {$_});$address='';$names=@()
            if($parts.Count -gt 1 -and $parts[0] -match '^[0-9a-fA-F:.]+$' -and -not (Test-WsmWindowsSettingSecret $SettingName $matchedLine)){$address=ConvertTo-WsmWindowsSettingSafeText $parts[0] 64;$names=@($parts[1..($parts.Count-1)] | ForEach-Object {ConvertTo-WsmWindowsSettingSafeText ([string]$_) 255})}
            $risk='OwnerReviewRequired';if($address -match '^(?i:127\.)' -or $address -ceq '::1' -or -not $address){$risk='LoopbackOrSystemBaselineNeverCopy'}
            $merge.Add([pscustomobject]@{Kind='HostsLine';LineHash=$hash;Address=$address;Names=$names;Movable=$false;SourceLine=$line;SourceOccurrences=$(if($s.ContainsKey($hash)){$s[$hash].Count}else{0});TargetOccurrences=$(if($t.ContainsKey($hash)){$t[$hash].Count}else{0});Presence=$side;Risk=$risk;RawLineIncluded=$false})
        }
    }elseif($SettingName -match '(?i)(^|\.)PATH$'){
        $sParts=@(([string]$sourceValue -split ';') | Where-Object {$_ -ne ''});$tParts=@(([string]$targetValue -split ';') | Where-Object {$_ -ne ''});$s=@{};for($i=0;$i -lt $sParts.Count;$i++){$hash=Get-WsmWindowsSettingValueHash ([string]$sParts[$i]);if(-not $s.ContainsKey($hash)){$s[$hash]=New-Object 'System.Collections.Generic.List[int]'};$s[$hash].Add($i+1)};$t=@{};for($i=0;$i -lt $tParts.Count;$i++){$hash=Get-WsmWindowsSettingValueHash ([string]$tParts[$i]);if(-not $t.ContainsKey($hash)){$t[$hash]=New-Object 'System.Collections.Generic.List[int]'};$t[$hash].Add($i+1)}
        foreach($hash in @(@($s.Keys)+@($t.Keys) | Sort-Object -Unique)){$side='Both';if(-not $t.ContainsKey($hash)){$side='SourceOnly'}elseif(-not $s.ContainsKey($hash)){$side='TargetOnly'};$sourceIndex=$null;$targetIndex=$null;if($s.ContainsKey($hash)){$sourceIndex=$s[$hash][0]};if($t.ContainsKey($hash)){$targetIndex=$t[$hash][0]};$component=$null;$componentInput=@($sParts+$tParts | Where-Object {(Get-WsmWindowsSettingValueHash ([string]$_)) -ceq $hash} | Select-Object -First 1);if($componentInput.Count -and -not (Test-WsmWindowsSettingSecret $SettingName ([string]$componentInput[0]))){$component=ConvertTo-WsmWindowsSettingSafeText ([string]$componentInput[0]) 512};$merge.Add([pscustomobject]@{Kind='PathComponent';ComponentHash=$hash;Component=$component;SourcePosition=$sourceIndex;TargetPosition=$targetIndex;SourceOccurrences=$(if($s.ContainsKey($hash)){$s[$hash].Count}else{0});TargetOccurrences=$(if($t.ContainsKey($hash)){$t[$hash].Count}else{0});Presence=$side;Risk='OrderAndConsumerReviewRequired';RawComponentIncluded=($null -ne $component)})}
    }
    $merge.ToArray()
}

function Get-WsmWindowsSettingsReviewPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SourceInventory,[Parameter(Mandatory)]$TargetInventory,[Parameter(Mandatory)][bool]$ReviewWindowsSettings,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SourceInventoryHash,[Parameter(Mandatory)][string]$TargetInventoryHash,$GeneralHostCatalog)
    if($SourceInventoryHash -notmatch '^[a-fA-F0-9]{64}$' -or $TargetInventoryHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Windows settings review requires independently verified source and target inventory hashes.'}
    $sourceFingerprint=[string]$SourceInventory.Source.Fingerprint;$targetFingerprint=[string]$TargetInventory.Source.Fingerprint
    if($sourceFingerprint -notmatch '^[a-f0-9]{64}$' -or $targetFingerprint -notmatch '^[a-f0-9]{64}$'){throw 'Windows settings review requires exact source and target fingerprints.'}
    if($GeneralHostCatalog -and $GeneralHostCatalog.PairId -cne $PairId){throw 'GeneralHost impact catalog belongs to a different pair.'}
    $sourceRows=@(Get-WsmWindowsSettingLeafRows $SourceInventory Source);$targetRows=@(Get-WsmWindowsSettingLeafRows $TargetInventory Target)
    $targetIndex=@{};foreach($row in $targetRows){$key=$row.Category+'|'+$row.Kind+'|'+$row.NaturalKey+'|'+$row.SettingName;if(-not $targetIndex.ContainsKey($key)){$targetIndex[$key]=$row}}
    $safe=New-Object 'System.Collections.Generic.List[object]';$rawById=@{}
    foreach($row in $sourceRows){
        $key=$row.Category+'|'+$row.Kind+'|'+$row.NaturalKey+'|'+$row.SettingName;$id=Get-WsmHashText ($key.ToLowerInvariant());$targetRow=$null;if($targetIndex.ContainsKey($key)){$targetRow=$targetIndex[$key]}
        $sourceValueHash=Get-WsmWindowsSettingValueHash $row.Value;$targetValueHash='';$targetStatus='NotObserved';$diff='Unknown'
        if($targetRow){$targetValueHash=Get-WsmWindowsSettingValueHash $targetRow.Value;$targetStatus=[string]$targetRow.Status;$diff=$(if($sourceValueHash -ceq $targetValueHash){'Same'}else{'Different'})}
        $consumers=@(Get-WsmWindowsSettingConsumers $SourceInventory $GeneralHostCatalog $row.ItemId)
        $supported=@('KeepTarget','External');$reason='No setting-specific write adapter is exposed by this review contract.'
        $nativeStateComplete=$false;$nativeStateValid=$false;$nativeStatePresent=$false;if($row.PSObject.Properties['NativeStateComplete']){$nativeStateComplete=[bool]$row.NativeStateComplete};if($row.PSObject.Properties['NativeStateValid']){$nativeStateValid=[bool]$row.NativeStateValid};if($row.PSObject.Properties['NativeStatePresent']){$nativeStatePresent=[bool]$row.NativeStatePresent}
        $actionRow=[pscustomobject]@{SourceItemId=$row.ItemId;Category=$row.Category;NaturalKey=$row.NaturalKey;Kind=$row.Kind;SettingName=$row.SettingName;Value=$row.Value;ControlSource=$row.ControlSource;Status=$row.Status;CustomizationEvidenceHash=$row.EvidenceHash;NativeStateComplete=$nativeStateComplete;NativeStateValid=$nativeStateValid;NativeStatePresent=$nativeStatePresent}
        if(Test-WsmWindowsSettingReviewedMigration $GeneralHostCatalog $actionRow $targetRow $TargetInventory){$supported+=@('ReviewedMigration');$reason='An existing exact reviewed migration spec and SettingTransition is available; target-before and source-after states match the trusted snapshots; choosing this records Migrate/Pending only and still requires normal review and gates.'}
        if($row.SettingName -match '(?i)(^|\.)PATH$'){$reason='PATH requires a manual component merge; whole-value overwrite is prohibited.'}
        if($row.Kind -eq 'HostsFile'){$reason='hosts requires a manual line merge; loopback/system baseline lines are not copied automatically.'}
        $sourceSafe=Get-WsmWindowsSettingSafeSummary $row.Kind $row.SettingName $row.Value $row.EvidenceHash
        $targetSafe=[pscustomobject][ordered]@{Display='[target value not observed]';ValueHash='';EvidencePointer=$TargetInventoryHash;Redacted=$true}
        if($targetRow){$targetSafe=Get-WsmWindowsSettingSafeSummary $targetRow.Kind $targetRow.SettingName $targetRow.Value $TargetInventoryHash}
        $item=[pscustomobject][ordered]@{SettingId=$id;Category=$row.Category;Kind=$row.Kind;NaturalKey=$row.NaturalKey;SettingName=$row.SettingName;SourceItemId=$row.ItemId;SourceStatus=$row.Status;TargetStatus=$targetStatus;SourceValueHash=$sourceValueHash;TargetValueHash=$targetValueHash;SourceSummary=$sourceSafe;TargetSummary=$targetSafe;TargetDiff=$diff;ControlSource=$row.ControlSource;CustomizationAssessment='NeedsOwnerEvidence';CustomizationEvidenceHash=$row.EvidenceHash;RequiredConsumerItemIds=$consumers;RequiredConsumerGateUnchanged=$true;DefaultAction=$(if(-not $ReviewWindowsSettings){'KeepTarget'}else{''});SupportedActions=$supported;ActionReason=$reason;ManualMergeRequired=($row.Kind -eq 'HostsFile' -or $row.SettingName -match '(?i)(^|\.)PATH$');RawValueIncluded=$false}
        $safe.Add($item);$rawById[$id]=[pscustomobject]@{Source=$row.Value;Target=$(if($targetRow){$targetRow.Value}else{$null});Kind=$row.Kind;SettingName=$row.SettingName}
    }
    foreach($row in $safe){if($row.ManualMergeRequired){$raw=$rawById[$row.SettingId];$row | Add-Member NoteProperty ManualMergeRows @(Get-WsmWindowsManualMergeRows $raw.Kind $raw.SettingName $raw.Source $raw.Target) -Force}}
    $coverage=@(foreach($item in @($SourceInventory.Items)){if($item.Status -in @('Failed','PermissionDenied','Unsupported','Partial') -or $item.Kind -in @('CollectorFailure','UnsupportedCollector','DiscoveryRequirement')){[pscustomobject]@{Category=[string]$item.Category;Kind=[string]$item.Kind;NameHash=(Get-WsmWindowsSettingValueHash ([string]$item.Name));ItemId=[string]$item.ItemId;Status=[string]$item.Status;Coverage='IncompleteOrOwnerReview';RawNameIncluded=$false}}})
    $consumerBlockers=@(foreach($item in $safe){foreach($consumer in @($item.RequiredConsumerItemIds)){[pscustomobject]@{SettingId=$item.SettingId;SettingName=$item.SettingName;ConsumerItemId=$consumer;Issue='KeepTarget preference does not satisfy or remove the required consumer dependency.'}}})
    $targetCoverage=@(foreach($item in @($TargetInventory.Items)){if($item.Status -in @('Failed','PermissionDenied','Unsupported','Partial') -or $item.Kind -in @('CollectorFailure','UnsupportedCollector','DiscoveryRequirement')){[pscustomobject]@{Category=[string]$item.Category;Kind=[string]$item.Kind;NameHash=(Get-WsmWindowsSettingValueHash ([string]$item.Name));ItemId=[string]$item.ItemId;Status=[string]$item.Status;Coverage='IncompleteOrOwnerReview';RawNameIncluded=$false}}})
    $projection=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WindowsSettingsReviewPreview';PairId=$PairId;ReviewWindowsSettings=$ReviewWindowsSettings;SourceFingerprint=$sourceFingerprint;TargetFingerprint=$targetFingerprint;SourceInventoryHash=$SourceInventoryHash.ToLowerInvariant();TargetInventoryHash=$TargetInventoryHash.ToLowerInvariant();SourceRevision=[int]$SourceInventory.Revision;TargetRevision=[int]$TargetInventory.Revision;Rows=$safe.ToArray();Coverage=$coverage;TargetCoverage=$targetCoverage;RequiredConsumerBlockers=$consumerBlockers;AuthoritativeApproval=$false;ReadinessProof=$false;ProductionQualified=$false}
    $projection | Add-Member NoteProperty PreviewHash (Get-WsmWindowsSettingsPreviewHash $projection)
    $projection
}

function Get-WsmWindowsSettingsPreviewHash($Preview) {
    $projection=[ordered]@{SchemaVersion=[int]$Preview.SchemaVersion;Kind=[string]$Preview.Kind;PairId=[string]$Preview.PairId;ReviewWindowsSettings=[bool]$Preview.ReviewWindowsSettings;SourceFingerprint=[string]$Preview.SourceFingerprint;TargetFingerprint=[string]$Preview.TargetFingerprint;SourceInventoryHash=[string]$Preview.SourceInventoryHash;TargetInventoryHash=[string]$Preview.TargetInventoryHash;SourceRevision=[int]$Preview.SourceRevision;TargetRevision=[int]$Preview.TargetRevision;Rows=@($Preview.Rows);Coverage=@($Preview.Coverage);TargetCoverage=@($Preview.TargetCoverage);RequiredConsumerBlockers=@($Preview.RequiredConsumerBlockers);AuthoritativeApproval=[bool]$Preview.AuthoritativeApproval;ReadinessProof=[bool]$Preview.ReadinessProof;ProductionQualified=[bool]$Preview.ProductionQualified}
    Get-WsmHashText (ConvertTo-Json -InputObject $projection -Depth 48 -Compress)
}

function Get-WsmWindowsSettingsDecisionTemplate($Preview) {
    if($Preview.Kind -cne 'WindowsSettingsReviewPreview'){throw 'A WindowsSettingsReviewPreview is required.'}
    [pscustomobject][ordered]@{SchemaVersion=1;Kind='WindowsSettingsReviewDecisions';PairId=$Preview.PairId;SourceFingerprint=$Preview.SourceFingerprint;TargetFingerprint=$Preview.TargetFingerprint;SourceInventoryHash=$Preview.SourceInventoryHash;TargetInventoryHash=$Preview.TargetInventoryHash;SourceRevision=$Preview.SourceRevision;TargetRevision=$Preview.TargetRevision;PreviewHash=$Preview.PreviewHash;ReviewWindowsSettings=[bool]$Preview.ReviewWindowsSettings;Decisions=@(foreach($row in @($Preview.Rows)){[pscustomobject][ordered]@{SettingId=$row.SettingId;SourceValueHash=$row.SourceValueHash;TargetValueHash=$row.TargetValueHash;Action=$(if(-not $Preview.ReviewWindowsSettings){'KeepTarget'}else{''});Owner='';Reason='';Evidence=''}});AuthoritativeApproval=$false;ReadinessProof=$false;ProductionQualified=$false}
}

function Get-WsmWindowsSettingsReviewWorkspacePreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SourceInventoryPath,[Parameter(Mandatory)][string]$SourceInventoryHash,[Parameter(Mandatory)][string]$TargetInventoryPath,[Parameter(Mandatory)][string]$TargetInventoryHash,[Parameter(Mandatory)][bool]$ReviewWindowsSettings)
    $source=Read-WsmTrustedJson $SourceInventoryPath $SourceInventoryHash;$target=Read-WsmTrustedJson $TargetInventoryPath $TargetInventoryHash;$catalog=Get-WsmCatalog $Workspace $PairId
    if($catalog.InventoryHash -ine $SourceInventoryHash -or $catalog.Source.Fingerprint -cne $source.Source.Fingerprint -or $catalog.InventoryRevision -ne $source.Revision){throw 'Source inventory does not match the authoritative catalog inventory hash, fingerprint and revision.'}
    $sourceById=@{};foreach($item in @($source.Items)){$sourceById[$item.ItemId]=$item};foreach($item in @($catalog.Items)){if(-not $sourceById.ContainsKey($item.ItemId) -or $sourceById[$item.ItemId].SettingsHash -cne $item.SettingsHash){throw 'Catalog source item settings differ from the trusted source inventory.'}}
    Get-WsmWindowsSettingsReviewPreview -SourceInventory $source -TargetInventory $target -ReviewWindowsSettings:$ReviewWindowsSettings -PairId $PairId -SourceInventoryHash $SourceInventoryHash -TargetInventoryHash $TargetInventoryHash -GeneralHostCatalog $catalog
}

function Apply-WsmWindowsSettingsReview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SourceInventoryPath,[Parameter(Mandatory)][string]$SourceInventoryHash,[Parameter(Mandatory)][string]$TargetInventoryPath,[Parameter(Mandatory)][string]$TargetInventoryHash,[Parameter(Mandatory)][string]$PreviewPath,[Parameter(Mandatory)][string]$PreviewHash,[Parameter(Mandatory)][string]$DecisionsPath,[Parameter(Mandatory)][string]$DecisionsHash,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][switch]$Ack)
    if(-not $Ack){throw 'Apply requires -Ack after reviewing the exact Windows settings preview and typed decisions.'}
    foreach($hash in @($SourceInventoryHash,$TargetInventoryHash,$PreviewHash,$DecisionsHash)){if($hash -notmatch '^[a-fA-F0-9]{64}$'){throw 'All trusted inputs require independently obtained SHA256 hashes.'}}
    $catalog=Get-WsmCatalog $Workspace $PairId;if($catalog.DecisionRevision -ne $ExpectedRevision){throw 'Review changed; refresh Windows settings preview before applying.'};$catalogPath=Get-WsmCatalogPath $Workspace $PairId;$catalogBaseHash=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $previewSnapshot=Read-WsmFileSnapshot $PreviewPath $PreviewHash;$savedPreview=ConvertFrom-WsmJson $previewSnapshot.Text
    $decisions=Read-WsmTrustedJson $DecisionsPath $DecisionsHash
    if($savedPreview.Kind -cne 'WindowsSettingsReviewPreview' -or $decisions.Kind -cne 'WindowsSettingsReviewDecisions'){throw 'Trusted Windows settings preview and typed decision set are required.'}
    $current=Get-WsmWindowsSettingsReviewWorkspacePreview -Workspace $Workspace -PairId $PairId -SourceInventoryPath $SourceInventoryPath -SourceInventoryHash $SourceInventoryHash -TargetInventoryPath $TargetInventoryPath -TargetInventoryHash $TargetInventoryHash -ReviewWindowsSettings:([bool]$savedPreview.ReviewWindowsSettings)
    if((Get-WsmWindowsSettingsPreviewHash $savedPreview) -ine $savedPreview.PreviewHash -or $savedPreview.PreviewHash -ine $current.PreviewHash -or $decisions.PreviewHash -ine $current.PreviewHash){throw 'Source, target or setting values changed after preview; refresh and obtain new typed decisions.'}
    foreach($field in @('PairId','SourceFingerprint','TargetFingerprint','SourceInventoryHash','TargetInventoryHash','SourceRevision','TargetRevision','ReviewWindowsSettings')){if([string]$decisions.$field -cne [string]$current.$field){throw "Windows settings decision binding changed: $field."}}
    if($decisions.Decisions -isnot [array] -or $decisions.Decisions.Count -ne $current.Rows.Count){throw 'Exactly one typed decision per preview setting is required.'}
    $rowsById=@{};foreach($row in @($current.Rows)){if($rowsById.ContainsKey($row.SettingId)){throw 'Duplicate setting identity in preview.'};$rowsById[$row.SettingId]=$row};$decisionById=@{};foreach($decision in @($decisions.Decisions)){if(-not $rowsById.ContainsKey([string]$decision.SettingId) -or $decisionById.ContainsKey([string]$decision.SettingId)){throw 'Decision set contains an unknown or duplicate setting.'};$decisionById[[string]$decision.SettingId]=$decision}
    $catalogById=@{};foreach($item in @($catalog.Items)){$catalogById[$item.ItemId]=$item};$sourceInventory=Read-WsmTrustedJson $SourceInventoryPath $SourceInventoryHash;$targetInventory=Read-WsmTrustedJson $TargetInventoryPath $TargetInventoryHash;$rawRows=@(Get-WsmWindowsSettingLeafRows $sourceInventory Source);$targetRows=@(Get-WsmWindowsSettingLeafRows $targetInventory Target);$rawRowsById=@{};foreach($rawRow in $rawRows){$rawKey=$rawRow.Category+'|'+$rawRow.Kind+'|'+$rawRow.NaturalKey+'|'+$rawRow.SettingName;$rawRowsById[(Get-WsmHashText ($rawKey.ToLowerInvariant()))]=$rawRow};$targetRowsByKey=@{};foreach($targetRow in $targetRows){$targetKey=$targetRow.Category+'|'+$targetRow.Kind+'|'+$targetRow.NaturalKey+'|'+$targetRow.SettingName;$targetRowsByKey[$targetKey]=$targetRow};$byItem=@{}
    foreach($row in @($current.Rows)){$decision=$decisionById[$row.SettingId];if($decision.SourceValueHash -cne $row.SourceValueHash -or $decision.TargetValueHash -cne $row.TargetValueHash){throw 'A setting value hash does not match its trusted preview.'};$action=[string]$decision.Action
        if(-not $current.ReviewWindowsSettings){if($action -cne 'KeepTarget'){throw 'Declining Windows settings review permits only class-wide KeepTarget.'}}
        elseif($action -notin $row.SupportedActions){throw "Unsupported setting action for $($row.SettingName)."}
        $owner=[string]$decision.Owner;$reason=[string]$decision.Reason;$evidence=[string]$decision.Evidence
        if($current.ReviewWindowsSettings){if([string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($reason) -or [string]::IsNullOrWhiteSpace($evidence)){throw 'Typed setting decisions require accountable owner, reason and evidence.'}}
        if($action -ceq 'ReviewedMigration'){$rawRow=$null;$targetRow=$null;if($rawRowsById.ContainsKey($row.SettingId)){$rawRow=$rawRowsById[$row.SettingId];$targetKey=$rawRow.Category+'|'+$rawRow.Kind+'|'+$rawRow.NaturalKey+'|'+$rawRow.SettingName;if($targetRowsByKey.ContainsKey($targetKey)){$targetRow=$targetRowsByKey[$targetKey]}};if(-not $rawRow -or -not (Test-WsmWindowsSettingReviewedMigration $catalog $rawRow $targetRow $targetInventory)){throw 'ReviewedMigration requires an exact source after-state, target before-state or complete verified target absence, and Local control.'}}
        $scope='External';if($action -ceq 'ReviewedMigration'){$scope='Migrate'};if(-not $current.ReviewWindowsSettings){$owner='Operator preference';$reason='Windows settings review declined; preserve target settings.';$evidence='decision:'+ $current.PreviewHash}
        if(-not $byItem.ContainsKey([string]$row.SourceItemId)){$byItem[[string]$row.SourceItemId]=[pscustomobject]@{Scope=$scope;Owner=$owner;Reason=$reason;Evidence=$evidence;Rows=(New-Object 'System.Collections.Generic.List[object]')}}elseif($scope -ceq 'Migrate'){$byItem[[string]$row.SourceItemId].Scope='Migrate'}
        $byItem[[string]$row.SourceItemId].Rows.Add([pscustomobject][ordered]@{SettingId=$row.SettingId;SettingName=$row.SettingName;Action=$action;SourceValueHash=$row.SourceValueHash;TargetValueHash=$row.TargetValueHash;ControlSource=$row.ControlSource;Owner=$owner;Reason=$reason;Evidence=$evidence;RequiredConsumerItemIds=@($row.RequiredConsumerItemIds)})
    }
    $scratchRoot=[IO.Path]::Combine([IO.Path]::GetTempPath(),('wsm-windows-review-scratch-'+[Guid]::NewGuid().ToString('N')));$dispositionPath=[IO.Path]::Combine([IO.Path]::GetTempPath(),('wsm-windows-dispositions-'+[Guid]::NewGuid().ToString('N')+'.json'));$requirementPath=[IO.Path]::Combine([IO.Path]::GetTempPath(),('wsm-windows-requirements-'+[Guid]::NewGuid().ToString('N')+'.json'))
    try{
        [void][IO.Directory]::CreateDirectory((Join-Path $scratchRoot 'pairs'));Copy-Item -LiteralPath (Join-Path $Workspace 'fleet.json') -Destination (Join-Path $scratchRoot 'fleet.json');$scratchCatalogPath=Join-Path (Join-Path $scratchRoot 'pairs') ($PairId+'.json');Copy-Item -LiteralPath $catalogPath -Destination $scratchCatalogPath
        $dispositions=@(foreach($itemId in @($byItem.Keys | Sort-Object)){$entry=$byItem[$itemId];[pscustomobject][ordered]@{ItemId=$itemId;ScopeDisposition=$entry.Scope;Owner=$entry.Owner;Reason=$entry.Reason;Evidence=$entry.Evidence}})
        Write-WsmJson $dispositionPath ([pscustomobject]@{Dispositions=$dispositions});$dispositionFileHash=(Get-FileHash -LiteralPath $dispositionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $dispositionPreview=Get-WsmGeneralHostDispositionPreview $scratchRoot $PairId $dispositionPath $dispositionFileHash $ExpectedRevision;$dispositionPreviewHash=Get-WsmGeneralHostPreviewHash $dispositionPreview Disposition
        if($dispositionPreview.Rows.Count -ne $dispositions.Count){throw 'GeneralHost disposition preview omitted a Windows setting source item.'}
        $afterDisposition=Set-WsmGeneralHostDispositions $scratchRoot $PairId $dispositionPath $dispositionFileHash $ExpectedRevision $dispositionPreviewHash
        $updatedCatalog=Get-WsmCatalog $scratchRoot $PairId;$newRequirements=@($updatedCatalog.GeneralHost.Requirements)
        foreach($itemId in @($byItem.Keys)){
            $entry=$byItem[$itemId]
            foreach($setting in @($entry.Rows | Where-Object {$_.Action -cne 'ReviewedMigration' -and @($_.RequiredConsumerItemIds).Count -gt 0})){
                $existing=@($newRequirements | Where-Object {$_.Type -ceq 'ExternalDependency' -and $_.ExternalId -ceq ('windows-setting:'+ $setting.SettingId)})
                if($existing.Count){continue}
                $consumerIds=@($setting.RequiredConsumerItemIds | Sort-Object -Unique)
                $itemSettingsHash=[string](@($updatedCatalog.Items | Where-Object ItemId -CEQ $itemId | ForEach-Object SettingsHash | Select-Object -First 1)[0])
                $req=[pscustomobject][ordered]@{Type='ExternalDependency';ProviderSoftwareId='';ProviderItemId='';ExternalId=('windows-setting:'+ $setting.SettingId);ConsumerItemIds=$consumerIds;Certainty='Required';RequiredPhase='CutoverReady';ExpectedVersion='Owner verified target setting';Architecture='NotApplicable';Context=[pscustomobject][ordered]@{SettingId=$setting.SettingId;SettingName=$setting.SettingName;TargetValueHash=$setting.TargetValueHash;SourceValueHash=$setting.SourceValueHash};Owner=$entry.Owner;SourceProof=[pscustomobject][ordered]@{InventoryHash=$updatedCatalog.InventoryHash;SourceItemId=$itemId;SourceSettingsHash=$itemSettingsHash;SettingId=$setting.SettingId;SourceValueHash=$setting.SourceValueHash};Decision=$(if($current.ReviewWindowsSettings){'Required'}else{'Pending'});DecisionReason=$(if($current.ReviewWindowsSettings){$entry.Reason}else{''});DecisionEvidence=$(if($current.ReviewWindowsSettings){$entry.Evidence}else{''})}
                $req | Add-Member NoteProperty RequirementId (Get-WsmGeneralHostRequirementId $req);$newRequirements+=@($req)
            }
        }
        if($newRequirements.Count -gt @($updatedCatalog.GeneralHost.Requirements).Count){Write-WsmJson $requirementPath ([pscustomobject]@{Requirements=$newRequirements});$reqFileHash=(Get-FileHash -LiteralPath $requirementPath -Algorithm SHA256).Hash.ToLowerInvariant();$revision=[int]$updatedCatalog.DecisionRevision;$reqPreview=Get-WsmGeneralHostRequirementPreview $scratchRoot $PairId $requirementPath $reqFileHash $revision;$reqPreviewHash=Get-WsmGeneralHostPreviewHash $reqPreview Requirement;$updatedCatalog=Set-WsmGeneralHostRequirements $scratchRoot $PairId $requirementPath $reqFileHash $revision $reqPreviewHash}
        $record=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AppliedWindowsSettingsReview';PreviewHash=$current.PreviewHash;SourceInventoryHash=$current.SourceInventoryHash;TargetInventoryHash=$current.TargetInventoryHash;SourceFingerprint=$current.SourceFingerprint;TargetFingerprint=$current.TargetFingerprint;SourceRevision=$current.SourceRevision;TargetRevision=$current.TargetRevision;ReviewWindowsSettings=$current.ReviewWindowsSettings;Decisions=@(foreach($row in @($current.Rows)){$decision=$decisionById[$row.SettingId];[pscustomobject][ordered]@{SettingId=$row.SettingId;SourceItemId=$row.SourceItemId;SourceValueHash=$row.SourceValueHash;TargetValueHash=$row.TargetValueHash;Action=[string]$decision.Action;RequiredConsumerItemIds=@($row.RequiredConsumerItemIds)}});RequiredConsumerGate='Unchanged; typed ExternalDependency receipt and normal consumer decision gates remain required';ReadinessProof=$false;AuthoritativeApproval=$false}
        $candidate=Get-WsmCatalog $scratchRoot $PairId;$priorReviews=@();if($candidate.GeneralHost.PSObject.Properties['WindowsSettingsReviews']){$priorReviews=@($candidate.GeneralHost.WindowsSettingsReviews)};$candidate.GeneralHost | Add-Member NoteProperty WindowsSettingsReviews ($priorReviews+@($record)) -Force;$candidate.GeneralHost.UpdatedUtc=Get-WsmUtc;$candidate.DecisionRevision++;$candidate.Approval=$null;$candidate.History=@($candidate.History)+@([pscustomobject]@{Revision=$candidate.DecisionRevision;Action='WindowsSettingsReview';SourceHash=$current.SourceInventoryHash;PreviewHash=$current.PreviewHash;Utc=(Get-WsmUtc)});Assert-WsmGeneralHostContract $candidate | Out-Null
        $settingRequirementIds=@($candidate.GeneralHost.Requirements | Where-Object {$_.ExternalId -like 'windows-setting:*'} | ForEach-Object RequirementId);$consumerIssues=@(Get-WsmGeneralHostIssues $candidate CutoverReady $current.TargetFingerprint | Where-Object {$settingRequirementIds -contains $_.RequirementId});$settingRequirementCount=$settingRequirementIds.Count;$consumerIssueCount=$consumerIssues.Count
        $final=Invoke-WsmLocked $Workspace {$actual=Get-WsmCatalog $Workspace $PairId;$actualFileHash=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant();if($actual.DecisionRevision -ne $ExpectedRevision -or $actualFileHash -cne $catalogBaseHash){throw 'Catalog changed during Windows settings review; no changes were committed.'};if((Get-FileHash -LiteralPath $SourceInventoryPath -Algorithm SHA256).Hash -ine $SourceInventoryHash -or (Get-FileHash -LiteralPath $TargetInventoryPath -Algorithm SHA256).Hash -ine $TargetInventoryHash){throw 'Source or target inventory changed during Windows settings review; no changes were committed.'};$candidate=Get-WsmCatalog $scratchRoot $PairId;if($candidate.InventoryHash -ine $actual.InventoryHash -or $candidate.PairId -cne $actual.PairId -or $candidate.DecisionRevision -le $actual.DecisionRevision){throw 'Scratch catalog candidate is not based on the current authoritative source; no changes were committed.'};Write-WsmJson $catalogPath $candidate;$candidate}
        [pscustomobject][ordered]@{Applied=$true;PairId=$PairId;PreviewHash=$current.PreviewHash;DecisionRevision=$candidate.DecisionRevision;WindowsSettingCount=$current.Rows.Count;RequiredExternalDependencyCount=$settingRequirementCount;RequiredConsumerIssueCount=$consumerIssueCount;ApprovalInvalidated=$true;ReadinessProof=$false;ConsumerGate='Pending required consumer decisions and ExternalOwner evidence receipts.';AppliedAt=$candidate.History[-1].Utc}
    }finally{foreach($path in @($dispositionPath,$requirementPath)){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}};if([IO.Directory]::Exists($scratchRoot)){Remove-Item -LiteralPath $scratchRoot -Recurse -Force}}
}

function Invoke-WsmWindowsSettingsReviewWizard {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$SourceInventoryPath,[Parameter(Mandatory)][string]$SourceInventoryHash,[Parameter(Mandatory)][string]$TargetInventoryPath,[Parameter(Mandatory)][string]$TargetInventoryHash)
    $answer=Read-Host '是否審核 Windows 系統設定？（YES／NO）';if($null -eq $answer){throw (New-Object IO.EndOfStreamException('Console input ended.'))};if($answer -notin @('YES','NO')){throw 'Enter YES or NO; EOF/cancel is not consent.'}
    $preview=Get-WsmWindowsSettingsReviewWorkspacePreview -Workspace $Workspace -PairId $PairId -SourceInventoryPath $SourceInventoryPath -SourceInventoryHash $SourceInventoryHash -TargetInventoryPath $TargetInventoryPath -TargetInventoryHash $TargetInventoryHash -ReviewWindowsSettings:($answer -ceq 'YES')
    $preview.Rows | Select-Object SettingName,SourceSummary,TargetSummary,TargetDiff,ControlSource,CustomizationAssessment,RequiredConsumerItemIds,DefaultAction,SupportedActions,ManualMergeRows | Format-List
    if($preview.Coverage.Count -or $preview.TargetCoverage.Count){Write-Host ('Source/target coverage gaps requiring owner review: '+($preview.Coverage.Count+$preview.TargetCoverage.Count))};if($preview.RequiredConsumerBlockers.Count){Write-Host ('Required consumer impacts remain unresolved: '+$preview.RequiredConsumerBlockers.Count)}
    $previewPath=Read-Host '以新檔名儲存 WindowsSettingsReviewPreview JSON';if($null -eq $previewPath){throw (New-Object IO.EndOfStreamException('Console input ended.'))};Assert-WsmNoReparse $previewPath;if([IO.File]::Exists($previewPath) -or [IO.Directory]::Exists($previewPath)){throw 'Preview file already exists; choose a new revisioned path.'};Write-WsmJson $previewPath $preview;$previewHash=(Get-FileHash -LiteralPath $previewPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $decisionPath=Read-Host '以新檔名儲存待責任人填寫的 WindowsSettingsReviewDecisions 範本';if($null -eq $decisionPath){throw (New-Object IO.EndOfStreamException('Console input ended.'))};Assert-WsmNoReparse $decisionPath;if([IO.File]::Exists($decisionPath) -or [IO.Directory]::Exists($decisionPath)){throw 'Decision file already exists; choose a new revisioned path.'};Write-WsmJson $decisionPath (Get-WsmWindowsSettingsDecisionTemplate $preview);$decisionHash=(Get-FileHash -LiteralPath $decisionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=Get-WsmCatalog $Workspace $PairId
    [pscustomobject]@{Preview=$preview;PreviewPath=[IO.Path]::GetFullPath($previewPath);PreviewSHA256=$previewHash;DecisionTemplatePath=[IO.Path]::GetFullPath($decisionPath);DecisionTemplateSHA256=$decisionHash;ExpectedRevision=$catalog.DecisionRevision;ApplyCommand='After completing the typed decision file, call Apply-WsmWindowsSettingsReview with these trusted paths/hashes, this ExpectedRevision and -Ack. The template alone does not apply decisions.';ReadinessProof=$false}
}
