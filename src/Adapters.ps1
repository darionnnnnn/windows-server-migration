function Assert-WsmAdapterDesired($Spec) {
    $contracts=@{
        ScheduledTask=@('TaskName','TaskPath','Xml','User'); Service=@('Name','DisplayName','BinaryPathName','Account','Dependencies','Description'); SmbShare=@('Name','Path','Description','EncryptData','Access'); MachineEnvironment=@('Name','Value'); WindowsFeature=@('Name','Source'); IISPool=@('Name','Xml'); IISSite=@('Name','Xml','Bindings'); Certificate=@('Thumbprint','Store','ArtifactPath','ArtifactHash','HasPrivateKey'); LocalUser=@('Name','FullName','Description'); LocalGroup=@('Name','Description','Members'); FirewallRule=@('Name','DisplayName','Direction','Action','Profile','Protocol','LocalPort','RemotePort','LocalAddress','RemoteAddress','Program')
    }
    if (-not $contracts.ContainsKey($Spec.Adapter)) { throw 'Unsupported adapter desired contract.' }
    $optional=@();if($Spec.Adapter -in @('Service','ScheduledTask')){$optional=@('SecuritySddl')}
    Assert-WsmFields $Spec.Desired ($contracts[$Spec.Adapter]+$optional)
    $required=$contracts[$Spec.Adapter]; if ($Spec.Adapter -eq 'WindowsFeature') { $required=@('Name') }; if ($Spec.Adapter -eq 'ScheduledTask') { $required=@('TaskName','TaskPath','Xml') }
    foreach ($f in $required) { if (-not $Spec.Desired.PSObject.Properties[$f]) { throw ('Desired requires '+$f) }; if($f -in @('Name','TaskName','TaskPath','Xml','Path','BinaryPathName','Thumbprint','Store','ArtifactPath','ArtifactHash') -and [string]::IsNullOrWhiteSpace([string]$Spec.Desired.$f)){throw ('Desired requires a nonempty '+$f)} }
    foreach ($f in @('Name','TaskName')) { if ($Spec.Desired.PSObject.Properties[$f] -and [string]$Spec.Desired.$f -match '[\x00-\x1f/\\]') { throw 'Invalid adapter object name.' } }
    if ($Spec.Adapter -eq 'ScheduledTask') { if ($Spec.Desired.TaskPath -notmatch '^\\(?:[^<>:"|?*\x00-\x1f]+\\)*$' -or $Spec.Desired.TaskPath -match '(?:^|\\)\.\.(?:\\|$)') { throw 'Invalid task folder.' }; $xml=Read-WsmXml $Spec.Desired.Xml; if ($xml.DocumentElement.LocalName -ne 'Task') { throw 'Expected task XML.' } }
    if($Spec.Desired.PSObject.Properties['SecuritySddl']){[void](New-Object Security.AccessControl.RawSecurityDescriptor($Spec.Desired.SecuritySddl))}
    if ($Spec.Adapter -in @('IISPool','IISSite')) { $xml=Read-WsmXml $Spec.Desired.Xml; $elementName='add'; if($Spec.Adapter -eq 'IISSite'){$elementName='site'}; if ($xml.DocumentElement.LocalName -ne $elementName -or $xml.DocumentElement.GetAttribute('name') -cne $Spec.Desired.Name) { throw 'IIS XML/name mismatch.' }; if ($xml.SelectNodes('//*[@password]').Count) { throw 'IIS passwords must be supplied as a SecretRef, not embedded in desired XML.' } }
    if ($Spec.Adapter -eq 'SmbShare') { [void](ConvertTo-WsmCanonicalPath $Spec.Desired.Path); if ($Spec.Desired.Name.EndsWith('$') -and $Spec.Desired.Name -match '^(?:ADMIN|IPC|[A-Z])\$$') { throw 'System administrative shares require dedicated workflow.' } }
    if ($Spec.Adapter -eq 'Certificate') { if ($Spec.Desired.Thumbprint -notmatch '^[A-Fa-f0-9]{40,64}$' -or $Spec.Desired.Store -notmatch '^Cert:\\LocalMachine\\[A-Za-z0-9_-]+$' -or $Spec.Desired.ArtifactHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid certificate artifact/store.' } }
    if($Spec.Adapter -eq 'IISSite'){$bindings=@((Read-WsmXml $Spec.Desired.Xml).SelectNodes('/site/bindings/binding'));if($bindings.Count -ne @($Spec.Desired.Bindings).Count){throw 'Reviewed IIS binding list differs from site XML.'};foreach($b in $Spec.Desired.Bindings){Assert-WsmFields $b @('Protocol','BindingInformation','CertificateHash','CertificateStoreName','SslFlags') @('Protocol','BindingInformation','CertificateHash','CertificateStoreName','SslFlags');if(@($bindings | Where-Object {$_.GetAttribute('protocol') -ieq $b.Protocol -and $_.GetAttribute('bindingInformation') -ceq $b.BindingInformation}).Count -ne 1){throw 'IIS binding identity differs from XML.'};if($b.Protocol -ieq 'https' -and ($b.CertificateHash -notmatch '^[a-fA-F0-9]{40,64}$' -or -not $b.CertificateStoreName)){throw 'HTTPS requires a reviewed certificate/store; cannot infer a private key.'}}}
    if ($Spec.Adapter -eq 'Service' -and ([string]::IsNullOrWhiteSpace($Spec.Desired.BinaryPathName) -or $Spec.Desired.Name -match '^(?i)(?:WinDefend|NTDS|DNS|DHCPServer|W32Time|LanmanServer|RpcSs)$')) { throw 'Service requires explicit binary and must not replace protected OS services.' }
    if ($Spec.Adapter -eq 'WindowsFeature' -and $Spec.Desired.Name -match '^(?i)(?:AD-Domain-Services|AD-Certificate|ADCS-|Failover-Clustering|DNS|DHCP|Hyper-V)') { throw 'Identity/cluster roles require dedicated product workflow.' }
    if ($Spec.Adapter -eq 'MachineEnvironment' -and $Spec.Desired.Name -match '^(?i)(?:PATH|SystemRoot|windir|COMSPEC|TEMP|TMP|PROCESSOR.*|NUMBER_OF_PROCESSORS)$') { throw 'Shared OS environment variables require dedicated reviewed procedure.' }
    $needsSecret=$Spec.Adapter -eq 'LocalUser' -or ($Spec.Adapter -eq 'Certificate' -and $Spec.Desired.HasPrivateKey) -or ($Spec.Adapter -eq 'Service' -and $Spec.Desired.Account -notin @('LocalSystem','NT AUTHORITY\SYSTEM'))
    if($Spec.Adapter -eq 'ScheduledTask'){$principal=(Read-WsmXml $Spec.Desired.Xml).SelectSingleNode("//*[local-name()='Principal']/*[local-name()='LogonType']");if($principal -and $principal.InnerText -eq 'Password'){$needsSecret=$true}}
    if($needsSecret -and (-not $Spec.PSObject.Properties['SecretRef'] -or -not $Spec.SecretRef)){throw 'Adapter requires a reviewed SecretRef; no passwords may be stored in desired configuration.'}
}
function Get-WsmAdapterRequiredCommands([string]$Adapter) {
    switch ($Adapter) {
        ScheduledTask { @('Get-ScheduledTask','Register-ScheduledTask','Export-ScheduledTask','Unregister-ScheduledTask') }
        Service { @('Get-Service','New-Service','Set-Service') }
        SmbShare { @('Get-SmbShare','New-SmbShare','Get-SmbShareAccess','Grant-SmbShareAccess','Block-SmbShareAccess') }
        WindowsFeature { @('Get-WindowsFeature','Install-WindowsFeature') }
        LocalUser { @('Get-LocalUser','New-LocalUser','Disable-LocalUser') }
        LocalGroup { @('Get-LocalGroup','New-LocalGroup','Add-LocalGroupMember') }
        FirewallRule { @('Get-NetFirewallRule','New-NetFirewallRule') }
        Certificate { @('Get-PfxData','Import-PfxCertificate','Import-Certificate') }
        { $_ -in @('IISPool','IISSite') } { @('Get-WebConfiguration') }
        default { @() }
    }
}
function Get-WsmSecret($Spec,[hashtable]$Secrets) {
    if (-not $Spec.PSObject.Properties['SecretRef'] -or -not $Spec.SecretRef) { return $null }
    if (-not $Secrets -or -not $Secrets.ContainsKey($Spec.SecretRef) -or $Secrets[$Spec.SecretRef] -isnot [Management.Automation.PSCredential]) { throw ('Required in-memory credential unavailable: '+$Spec.SecretRef) }
    $Secrets[$Spec.SecretRef]
}
function New-WsmTaskScheduler {$scheduler=New-Object -ComObject 'Schedule.Service';$scheduler.Connect();$scheduler}
function Get-WsmAdapterState($Spec) {
    $d=$Spec.Desired
    switch ($Spec.Adapter) {
        ScheduledTask { $t=Get-ScheduledTask -TaskName $d.TaskName -TaskPath $d.TaskPath -ErrorAction SilentlyContinue; if ($t) { [pscustomobject]@{ Exists=$true; Xml=(Export-ScheduledTask -TaskName $d.TaskName -TaskPath $d.TaskPath); Enabled=[bool]$t.Settings.Enabled } } else { [pscustomobject]@{Exists=$false} } }
        Service { $s=@(Get-CimInstance Win32_Service | Where-Object Name -CEQ $d.Name); if ($s.Count) { [pscustomobject]@{Exists=$true; Configuration=($s[0] | Select-Object Name,DisplayName,Description,PathName,StartMode,StartName); State=[string]$s[0].State;Dependencies=@(Get-WsmServiceDependencies $d.Name)} } else { [pscustomobject]@{Exists=$false} } }
        SmbShare { $s=Get-SmbShare -Name $d.Name -ErrorAction SilentlyContinue; if ($s) { [pscustomobject]@{Exists=$true; Configuration=($s | Select-Object Name,Path,Description,EncryptData); Access=@(Get-SmbShareAccess -Name $d.Name)} } else { [pscustomobject]@{Exists=$false} } }
        MachineEnvironment { $v=[Environment]::GetEnvironmentVariable($d.Name,'Machine'); [pscustomobject]@{Exists=($null -ne $v); Value=$v} }
        WindowsFeature { $f=Get-WindowsFeature -Name $d.Name; if (-not $f) { throw 'Unknown target Windows feature.' }; [pscustomobject]@{Exists=[bool]$f.Installed; Name=$f.Name} }
        LocalUser { $u=Get-LocalUser -Name $d.Name -ErrorAction SilentlyContinue; if ($u) { [pscustomobject]@{Exists=$true; Enabled=[bool]$u.Enabled; SID=[string]$u.SID; FullName=$u.FullName; Description=$u.Description} } else { [pscustomobject]@{Exists=$false} } }
        LocalGroup { $g=Get-LocalGroup -Name $d.Name -ErrorAction SilentlyContinue; if ($g) { [pscustomobject]@{Exists=$true; SID=[string]$g.SID; Members=@(Get-LocalGroupMember -Group $d.Name | ForEach-Object Name)} } else { [pscustomobject]@{Exists=$false} } }
        FirewallRule { $r=Get-NetFirewallRule -Name $d.Name -ErrorAction SilentlyContinue; if ($r) { [pscustomobject]@{Exists=$true; Enabled=[string]$r.Enabled; Rule=($r | Select-Object Name,Direction,Action,Profile); Ports=@($r | Get-NetFirewallPortFilter); Addresses=@($r | Get-NetFirewallAddressFilter); Applications=@($r | Get-NetFirewallApplicationFilter)} } else { [pscustomobject]@{Exists=$false} } }
        Certificate { $cert=Get-Item -LiteralPath ($d.Store+'\'+$d.Thumbprint) -ErrorAction SilentlyContinue; [pscustomobject]@{Exists=($null -ne $cert); HasPrivateKey=($cert -and $cert.HasPrivateKey)} }
        { $_ -in @('IISPool','IISSite') } { Get-WsmIisState $Spec }
        default { throw 'No automatic adapter state for this workflow.' }
    }
}
function ConvertTo-WsmDisabledTaskXml($Spec) {
    $doc=Read-WsmXml $Spec.Desired.Xml; $root=$doc.DocumentElement; $ns=$root.NamespaceURI
    $settings=$root.SelectSingleNode("*[local-name()='Settings']"); if (-not $settings) { $settings=$doc.CreateElement('Settings',$ns); [void]$root.AppendChild($settings) }
    $enabled=$settings.SelectSingleNode("*[local-name()='Enabled']"); if (-not $enabled) { $enabled=$doc.CreateElement('Enabled',$ns); [void]$settings.AppendChild($enabled) }; $enabled.InnerText='false'
    if ($Spec.Desired.PSObject.Properties['User'] -and $Spec.Desired.User) { $user=$root.SelectSingleNode("*[local-name()='Principals']/*[local-name()='Principal']/*[local-name()='UserId']"); if ($user) { $user.InnerText=$Spec.Desired.User } else { throw 'Task account mapping requires an existing UserId principal.' } }
    $doc.OuterXml
}
function Invoke-WsmAdapterRestore($Spec,[hashtable]$Secrets,$Package) {
    Assert-WsmAdapterDesired $Spec; $d=$Spec.Desired; $secret=Get-WsmSecret $Spec $Secrets
    if($secret -and $Spec.Adapter -eq 'ScheduledTask'){$principal=(Read-WsmXml (ConvertTo-WsmDisabledTaskXml $Spec)).SelectSingleNode("//*[local-name()='Principal']/*[local-name()='UserId']");if(-not $principal -or $principal.InnerText -ine $secret.UserName){throw 'Credential username must match the reviewed target task principal.'}}
    switch ($Spec.Adapter) {
        ScheduledTask { $scheduler=New-WsmTaskScheduler;$folder=$scheduler.GetFolder('\');foreach($name in $d.TaskPath.Trim('\').Split('\')){if(-not $name){continue};try{$folder=$folder.GetFolder($name)}catch{$folder=$folder.CreateFolder($name)}};$args=@{ TaskName=$d.TaskName; TaskPath=$d.TaskPath; Xml=(ConvertTo-WsmDisabledTaskXml $Spec); ErrorAction='Stop' }; if ($d.PSObject.Properties['User'] -and $d.User) { $args.User=$d.User }; if ($secret) { $args.User=$secret.UserName; $args.Password=$secret.GetNetworkCredential().Password };try{Register-ScheduledTask @args | Out-Null}finally{[void]$args.Remove('Password')};if($d.PSObject.Properties['SecuritySddl']){$folder.GetTask($d.TaskName).SetSecurityDescriptor($d.SecuritySddl,0)} }
        Service { $args=@{ Name=$d.Name; BinaryPathName=$d.BinaryPathName; StartupType='Disabled'; ErrorAction='Stop' }; foreach ($f in @('DisplayName','Description','Dependencies')) { if ($d.PSObject.Properties[$f]) { $args[$f]=$d.$f } }; if ($secret) {if($secret.UserName -ine $d.Account -and (Resolve-WsmAccountSid $secret.UserName) -cne (Resolve-WsmAccountSid $d.Account)){throw 'Service credential does not match reviewed principal.'}; $args.Credential=$secret } elseif ($d.PSObject.Properties['Account'] -and $d.Account -notin @('LocalSystem','NT AUTHORITY\SYSTEM')) { throw 'Non-System service requires in-memory credential.' }; New-Service @args | Out-Null;if($d.PSObject.Properties['SecuritySddl']){Invoke-WsmServiceSecurity $d.Name $d.SecuritySddl | Out-Null} }
        SmbShare { $args=@{ Name=$d.Name; Path=$d.Path; ErrorAction='Stop' }; foreach($f in @('Description','EncryptData')) { if ($d.PSObject.Properties[$f]) { $args[$f]=$d.$f } }; $args.NoAccess=@('Everyone'); New-SmbShare @args | Out-Null; foreach($a in $d.Access) { if ($a.AccessControlType -eq 'Deny') { Block-SmbShareAccess -Name $d.Name -AccountName $a.AccountName -Force | Out-Null } elseif ($a.AccessControlType -eq 'Allow' -and $a.AccessRight -in @('Read','Change','Full')) { Grant-SmbShareAccess -Name $d.Name -AccountName $a.AccountName -AccessRight $a.AccessRight -Force | Out-Null } else { throw 'Unsupported share ACE.' } }; # Everyone remains denied until explicit activation.
        }
        MachineEnvironment { [Environment]::SetEnvironmentVariable($d.Name,[string]$d.Value,'Machine') }
        WindowsFeature { $args=@{Name=$d.Name;ErrorAction='Stop'}; if ($d.PSObject.Properties['Source'] -and $d.Source) { $args.Source=$d.Source }; $r=Install-WindowsFeature @args; if (-not $r.Success) { throw 'Windows feature installation did not succeed.' }; if ([string]$r.RestartNeeded -eq 'Yes') { return [pscustomobject]@{RebootRequired=$true} } }
        LocalUser { if (-not $secret) { throw 'New local account requires SecretRef credential.' }; $args=@{Name=$d.Name;Password=$secret.Password;Disabled=$true;ErrorAction='Stop'}; foreach($f in @('FullName','Description')){if($d.PSObject.Properties[$f]){$args[$f]=$d.$f}}; New-LocalUser @args | Out-Null }
        LocalGroup { New-LocalGroup -Name $d.Name -Description $d.Description | Out-Null; foreach($member in $d.Members){Add-LocalGroupMember -Group $d.Name -Member $member} }
        FirewallRule { $args=@{Enabled='False';ErrorAction='Stop'}; foreach($f in $d.PSObject.Properties){$args[$f.Name]=$f.Value}; New-NetFirewallRule @args | Out-Null }
        Certificate { $artifact=Get-WsmCertificateArtifact $Package $d;try{if ($d.HasPrivateKey) { if (-not $secret) { throw 'PFX requires in-memory password credential.' };$data=Get-PfxData -FilePath $artifact -Password $secret.Password;if(@($data.EndEntityCertificates).Count -ne 1 -or @($data.OtherCertificates).Count -gt 0 -or $data.EndEntityCertificates[0].Thumbprint -ine $d.Thumbprint){throw 'PFX must contain the exact reviewed leaf only; chain certificates require separately reviewed items.'}; Import-PfxCertificate -FilePath $artifact -CertStoreLocation $d.Store -Password $secret.Password | Out-Null } else {$cert=New-Object Security.Cryptography.X509Certificates.X509Certificate2($artifact);try{if($cert.Thumbprint -ine $d.Thumbprint -or $cert.HasPrivateKey){throw 'Public certificate artifact differs from reviewed thumbprint/type.'}}finally{$cert.Dispose()}; Import-Certificate -FilePath $artifact -CertStoreLocation $d.Store | Out-Null }}finally{if([IO.File]::Exists($artifact)){[IO.File]::Delete($artifact)}} }
        { $_ -in @('IISPool','IISSite') } { Invoke-WsmIisRestore $Spec $secret }
        default { throw 'Unsupported adapter.' }
    }
    [pscustomobject]@{RebootRequired=$false}
}
function Test-WsmAdapterConfiguration($Spec,[ValidateSet('Staged','Final')][string]$Phase='Staged') {
    $s=Get-WsmAdapterState $Spec; $d=$Spec.Desired; $errors=New-Object 'System.Collections.Generic.List[string]'
    if (-not $s.Exists) { $errors.Add('Object absent') }
    elseif ($Spec.Adapter -eq 'ScheduledTask') {
        $expected=Read-WsmXml (ConvertTo-WsmDisabledTaskXml $Spec); $actual=Read-WsmXml $s.Xml
        # Date/URI registration metadata may be assigned by the scheduler; compare execution-sensitive sections.
        if($Phase -eq 'Final'){$enabled=$expected.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");$enabled.InnerText=([string](Get-WsmDesiredActivation $Spec)).ToLowerInvariant()}
        foreach($name in @('Actions','Triggers','Principals','Settings')) { $a=$actual.DocumentElement.SelectSingleNode("*[local-name()='$name']"); $e=$expected.DocumentElement.SelectSingleNode("*[local-name()='$name']"); if (($null -eq $a) -ne ($null -eq $e) -or ($a -and (ConvertTo-WsmXmlComparable $a) -cne (ConvertTo-WsmXmlComparable $e))) { $errors.Add('Task '+$name+' mismatch') } }
        if ($Phase -eq 'Staged' -and $s.Enabled) { $errors.Add('Task must remain disabled') }
        if($Phase -eq 'Final' -and $s.Enabled -ne (Get-WsmDesiredActivation $Spec)){$errors.Add('Task final enabled state mismatch')}
    }
    elseif ($Spec.Adapter -eq 'Service') { if ($s.Configuration.PathName -cne $d.BinaryPathName -or $s.Configuration.DisplayName -cne $d.DisplayName) { $errors.Add('Service binary/display mismatch') };if((ConvertTo-WsmServiceAccount $s.Configuration.StartName) -ine (ConvertTo-WsmServiceAccount $d.Account) -or [string]$s.Configuration.Description -cne [string]$d.Description -or (@($s.Dependencies | Sort-Object) -join ',') -ine (@($d.Dependencies | Sort-Object) -join ',')){$errors.Add('Service account/description/dependencies mismatch')}; if ($Phase -eq 'Staged' -and ($s.Configuration.StartMode -ne 'Disabled' -or $s.State -ne 'Stopped')) { $errors.Add('Service staging invariant violated') } }
    elseif ($Spec.Adapter -eq 'MachineEnvironment') { if ($s.Value -cne [string]$d.Value) { $errors.Add('Environment value mismatch') } }
    elseif ($Spec.Adapter -eq 'SmbShare') { if ($s.Configuration.Path -ine $d.Path -or $s.Configuration.EncryptData -ne $d.EncryptData) { $errors.Add('Share configuration mismatch') }; foreach($ace in $d.Access){if(-not @($s.Access | Where-Object { $_.AccountName -ieq $ace.AccountName -and [string]$_.AccessRight -eq $ace.AccessRight -and [string]$_.AccessControlType -eq $ace.AccessControlType }).Count){$errors.Add('Share ACE missing')}} }
    elseif ($Spec.Adapter -eq 'LocalUser') { if ($Phase -eq 'Staged' -and $s.Enabled) { $errors.Add('Local account must remain disabled') }; if ($s.FullName -cne $d.FullName -or $s.Description -cne $d.Description) { $errors.Add('Local user metadata mismatch') } }
    elseif ($Spec.Adapter -eq 'LocalGroup') { if (@(Compare-Object @($d.Members | Sort-Object) @($s.Members | Sort-Object)).Count) { $errors.Add('Group membership mismatch') } }
    elseif ($Spec.Adapter -eq 'Certificate') { if ($s.HasPrivateKey -ne [bool]$d.HasPrivateKey) { $errors.Add('Certificate private key mismatch') } }
    elseif ($Spec.Adapter -eq 'FirewallRule') { if ($Phase -eq 'Staged' -and $s.Enabled -ne 'False') { $errors.Add('Firewall rule must remain disabled') }; if ($s.Rule.Direction -ne $d.Direction -or $s.Rule.Action -ne $d.Action) { $errors.Add('Firewall rule mismatch') };foreach($field in @('LocalPort','RemotePort')){if(@($s.Ports).Count -ne 1 -or (@($s.Ports[0].$field) -join ',') -ine (@($d.$field) -join ',')){$errors.Add('Firewall port/protocol mismatch: '+$field)}};if(@($s.Ports).Count -ne 1 -or (ConvertTo-WsmFirewallProtocol $s.Ports[0].Protocol) -cne (ConvertTo-WsmFirewallProtocol $d.Protocol)){$errors.Add('Firewall protocol mismatch')};foreach($field in @('LocalAddress','RemoteAddress')){if(@($s.Addresses).Count -ne 1 -or (@($s.Addresses[0].$field | Sort-Object) -join ',') -ine (@($d.$field | Sort-Object) -join ',')){$errors.Add('Firewall address mismatch: '+$field)}};if(@($s.Applications).Count -ne 1 -or $s.Applications[0].Program -ine $d.Program){$errors.Add('Firewall program mismatch')};if((@(([string]$s.Rule.Profile).Split(',') | ForEach-Object {$_.Trim()} | Sort-Object) -join ',') -ine (@($d.Profile | ForEach-Object {$_.ToString().Split(',')} | ForEach-Object {$_.Trim()} | Sort-Object) -join ',')){$errors.Add('Firewall profile mismatch')} }
    elseif ($Spec.Adapter -in @('IISPool','IISSite')) { foreach($e in (Test-WsmIisConfiguration $Spec $Phase)){$errors.Add($e)} }
    if($s.Exists -and $d.PSObject.Properties['SecuritySddl']){$actualSddl='';if($Spec.Adapter -eq 'Service'){$actualSddl=Get-WsmServiceSecurity $d.Name}elseif($Spec.Adapter -eq 'ScheduledTask'){$scheduler=New-WsmTaskScheduler;$actualSddl=$scheduler.GetFolder($d.TaskPath).GetTask($d.TaskName).GetSecurityDescriptor(7)};if((New-Object Security.AccessControl.RawSecurityDescriptor($actualSddl)).GetSddlForm('All') -cne (New-Object Security.AccessControl.RawSecurityDescriptor($d.SecuritySddl)).GetSddlForm('All')){$errors.Add('Object security descriptor mismatch')}}
    if($s.Exists -and $Phase -eq 'Final'){$active=Get-WsmDesiredActivation $Spec;switch($Spec.Adapter){Service{$mode='Disabled';$state='Stopped';if($active){$mode='Manual';if($Spec.DesiredFinalState -eq 'Automatic'){$mode='Auto'};if($Spec.DesiredFinalState -in @('Automatic','Running')){$state='Running'}};if($s.Configuration.StartMode -ne $mode -or $s.State -ne $state){$errors.Add('Service final mode/running state mismatch')}};LocalUser{if($s.Enabled -ne $active){$errors.Add('User final enabled state mismatch')}};FirewallRule{if(($s.Enabled -eq 'True') -ne $active){$errors.Add('Firewall final enabled state mismatch')}};SmbShare{$blocked=@($s.Access | Where-Object { $_.AccountName -in @('Everyone','S-1-1-0') -and [string]$_.AccessControlType -eq 'Deny' }).Count -gt 0;if($blocked -eq $active){$errors.Add('Share final availability mismatch')}}}}
    [pscustomobject]@{Passed=($errors.Count -eq 0); Problems=$errors.ToArray(); Actual=$s; Phase=$Phase}
}
function Get-WsmDesiredActivation($Spec) { $Spec.PSObject.Properties['DesiredFinalState'] -and $Spec.DesiredFinalState -in @('Enabled','Automatic','Manual','Running') }
function ConvertTo-WsmXmlComparable($Node) {
    $attributes=[ordered]@{};foreach($a in @($Node.Attributes | Where-Object {$_.Name -ne 'xmlns' -and $_.Prefix -ne 'xmlns'} | Sort-Object LocalName)){$attributes[$a.LocalName]=$a.Value};$elements=@($Node.ChildNodes | Where-Object NodeType -EQ ([Xml.XmlNodeType]::Element));if($Node.LocalName -notin @('Actions','Triggers')){$elements=@($elements | Sort-Object LocalName)};$children=@(foreach($child in $elements){ConvertTo-WsmXmlComparable $child});$text='';if(-not $elements.Count){$text=$Node.InnerText};([pscustomobject][ordered]@{Name=$Node.LocalName;Attributes=$attributes;Text=$text;Children=$children} | ConvertTo-Json -Compress -Depth 30)
}
function Remove-WsmCreatedAdapter($Spec) {
    $d=$Spec.Desired
    switch($Spec.Adapter){
        ScheduledTask { Unregister-ScheduledTask -TaskName $d.TaskName -TaskPath $d.TaskPath -Confirm:$false }
        Service { $s=Get-CimInstance Win32_Service | Where-Object Name -CEQ $d.Name; if($s.State -ne 'Stopped'){throw 'Stop created service before rollback.'}; $r=Invoke-CimMethod -InputObject $s -MethodName Delete; if($r.ReturnValue -ne 0){throw ('Service delete native code '+$r.ReturnValue)} }
        SmbShare { Remove-SmbShare -Name $d.Name -Force }
        MachineEnvironment { [Environment]::SetEnvironmentVariable($d.Name,$null,'Machine') }
        WindowsFeature { throw 'Feature removal requires explicit dedicated rollback; dependency/reboot effects must be reviewed.' }
        LocalUser { Remove-LocalUser -Name $d.Name }
        LocalGroup { Remove-LocalGroup -Name $d.Name }
        FirewallRule { Remove-NetFirewallRule -Name $d.Name }
        Certificate { Remove-Item -LiteralPath ($d.Store+'\'+$d.Thumbprint) }
        { $_ -in @('IISPool','IISSite') } { Remove-WsmIisObject $Spec }
    }
}

function ConvertTo-WsmFirewallProtocol([string]$Value){switch($Value.ToUpperInvariant()){TCP{'6'};UDP{'17'};ICMPV4{'1'};ICMPV6{'58'};ANY{'256'};default{$Value}}}

function Get-WsmServiceDependencies([string]$Name){$p=Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$Name);if($p.PSObject.Properties['DependOnService']){@($p.DependOnService)}}
function ConvertTo-WsmServiceAccount([string]$Name){if($Name -in @('LocalSystem','NT AUTHORITY\SYSTEM','SYSTEM')){'LocalSystem'}else{$Name}}
