function Assert-WsmInstallerPolicy($Desired) {
    if(-not $Desired.PSObject.Properties['IsolationEvidence'] -or [string]::IsNullOrWhiteSpace($Desired.IsolationEvidence) -or -not $Desired.PSObject.Properties['SideEffects']){throw 'Feature install requires explicit isolated maintenance evidence and reviewed SideEffects (empty only after review).'}
    $seen=@{};foreach($entry in $Desired.SideEffects){Assert-WsmFields $entry @('Kind','Name','FinalMode','FinalRunning','CatchUpPolicy') @('Kind','Name','FinalMode','FinalRunning');if($entry.Kind -cnotin @('Service','ScheduledTask','IISPool','IISSite') -or [string]::IsNullOrWhiteSpace($entry.Name) -or $entry.Name -match '[*?\[\]\x00-\x1f]' -or $entry.FinalRunning -isnot [bool]){throw 'Invalid declared installer side effect.'};$modes=@{Service=@('Disabled','Manual','Auto');ScheduledTask=@('False','True');IISPool=@('False|OnDemand','True|OnDemand','True|AlwaysRunning');IISSite=@('False','True')};if($entry.FinalMode -cnotin $modes[$entry.Kind] -or ($entry.FinalRunning -and ($entry.FinalMode -ceq 'Disabled' -or $entry.FinalMode.StartsWith('False')))){throw 'Invalid final installer consumer mode/running combination.'};if($entry.Kind -eq 'ScheduledTask' -and ($entry.FinalRunning -or -not $entry.PSObject.Properties['CatchUpPolicy'] -or $entry.CatchUpPolicy -cne 'PreserveSourceSettings')){throw 'Installer tasks require reviewed PreserveSourceSettings; automatic task execution is prohibited.'};$key=$entry.Kind+'|'+$entry.Name.ToUpperInvariant();if($seen.ContainsKey($key)){throw 'Duplicate declared installer side effect.'};$seen[$key]=$true}
}
function Get-WsmInstallerSnapshot {
    $items=New-Object 'System.Collections.Generic.List[object]'
    foreach($s in (Get-CimInstance Win32_Service -ErrorAction Stop)){$items.Add([pscustomobject]@{Kind='Service';Name=$s.Name;Mode=$s.StartMode;Running=($s.State -eq 'Running');ConfigHash=(Get-WsmHashText (@($s.Name,$s.PathName,$s.StartName,$s.ServiceType,$s.DesktopInteract) | ConvertTo-Json -Compress))})}
    foreach($t in (Get-ScheduledTask -ErrorAction Stop)){$xml=Read-WsmXml (Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction Stop);$enabled=$xml.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");if($enabled){$enabled.InnerText='false'};$items.Add([pscustomobject]@{Kind='ScheduledTask';Name=($t.TaskPath+$t.TaskName);Mode=[string][bool]$t.Settings.Enabled;Running=([string]$t.State -eq 'Running');ConfigHash=(Get-WsmHashText (ConvertTo-WsmXmlComparable $xml.DocumentElement))})}
    if([IO.File]::Exists((Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll'))){$m=New-WsmIisManager;try{foreach($o in $m.ApplicationPools){$items.Add([pscustomobject]@{Kind='IISPool';Name=$o.Name;Mode=([string]$o.AutoStart+'|'+[string]$o.StartMode);Running=([string]$o.State -eq 'Started');ConfigHash=(Get-WsmInstallerIisHash $o)})};foreach($o in $m.Sites){$items.Add([pscustomobject]@{Kind='IISSite';Name=$o.Name;Mode=[string]$o.ServerAutoStart;Running=([string]$o.State -eq 'Started');ConfigHash=(Get-WsmInstallerIisHash $o)})}}finally{$m.Dispose()}}
    [pscustomobject]@{Utc=(Get-WsmUtc);Items=$items.ToArray()}
}
function Stop-WsmInstallerObject($Object) {
    switch($Object.Kind){
        Service {Set-Service -Name $Object.Name -StartupType Disabled;Stop-Service -Name $Object.Name -ErrorAction Stop}
        ScheduledTask {$last=$Object.Name.LastIndexOf('\');$args=@{TaskName=$Object.Name.Substring($last+1);TaskPath=$Object.Name.Substring(0,$last+1);ErrorAction='Stop'};Disable-ScheduledTask @args | Out-Null;Stop-ScheduledTask @args}
        {$_ -in @('IISPool','IISSite')} {$m=New-WsmIisManager;try{$o=$m.Sites[$Object.Name];if($Object.Kind -eq 'IISPool'){$o=$m.ApplicationPools[$Object.Name];$o.AutoStart=$false;$o.StartMode='OnDemand'}else{$o.ServerAutoStart=$false};$m.CommitChanges();if([string]$o.State -ne 'Stopped'){[void]$o.Stop()}}finally{$m.Dispose()}}
    }
}
function Get-WsmInstallerIisHash($Object) {
    $snapshot=Get-WsmIisElementSnapshot $Object
    foreach($name in @('autoStart','startMode','serverAutoStart')){if($snapshot.Attributes.Contains($name)){$snapshot.Attributes.Remove($name)}}
    Get-WsmHashText ($snapshot | ConvertTo-Json -Depth 40 -Compress)
}
function Read-WsmInstallerBaseline($Record,$Paths,[string]$ItemId) {
    $expected=Join-Path $Paths.Root ($ItemId+'.installer-baseline.json')
    if(-not $Record.PSObject.Properties['InstallerBaselinePath'] -or -not $Record.PSObject.Properties['InstallerBaselineHash'] -or [IO.Path]::GetFullPath($Record.InstallerBaselinePath) -ine [IO.Path]::GetFullPath($expected)){throw 'Installer baseline path/binding absent or outside owned state.'}
    Assert-WsmNoReparse $expected
    Read-WsmTrustedJson $expected $Record.InstallerBaselineHash
}
function Test-WsmInstallerConsumers($Desired,$Receipt,[string]$Phase='Staged') {
    Assert-WsmInstallerPolicy $Desired
    if(-not $Receipt -or -not $Receipt.PSObject.Properties['Quarantined']){throw 'Installer consumer ownership receipt missing; recover durable installer intent.'}
    $declared=@{};foreach($entry in $Desired.SideEffects){$declared[$entry.Kind+'|'+$entry.Name.ToUpperInvariant()]=$entry}
    $actual=@{};foreach($entry in (Get-WsmInstallerSnapshot).Items){$actual[$entry.Kind+'|'+$entry.Name.ToUpperInvariant()]=$entry}
    foreach($owned in $Receipt.Quarantined){$key=$owned.Kind+'|'+$owned.Name.ToUpperInvariant();if(-not $declared.ContainsKey($key) -or -not $actual.ContainsKey($key) -or $owned.ConfigHash -cne $actual[$key].ConfigHash){throw 'Installer consumer absent, unreviewed or configuration drifted.'};$expectedMode=@{Service='Disabled';ScheduledTask='False';IISSite='False';IISPool='False|OnDemand'}[$owned.Kind];$running=$false;if($Phase -eq 'Final'){$expectedMode=$declared[$key].FinalMode;$running=$declared[$key].FinalRunning};if($actual[$key].Mode -cne $expectedMode -or (($Phase -eq 'Staged' -or $owned.Kind -ne 'ScheduledTask') -and $actual[$key].Running -ne $running)){throw 'Installer consumer mode/running state differs from reviewed phase.'}}
    $true
}
function Invoke-WsmInstallerConsumerActivation($Desired,$Receipt,[bool]$Enable) {
    [void](Test-WsmInstallerConsumers $Desired $Receipt Staged)
    if(-not $Enable){return}
    $declared=@{};foreach($entry in $Desired.SideEffects){$declared[$entry.Kind+'|'+$entry.Name.ToUpperInvariant()]=$entry}
    foreach($owned in $Receipt.Quarantined){$entry=$declared[$owned.Kind+'|'+$owned.Name.ToUpperInvariant()];switch($owned.Kind){
        Service {$mode=$entry.FinalMode;if($mode -ceq 'Auto'){$mode='Automatic'};Set-Service -Name $owned.Name -StartupType $mode -ErrorAction Stop;if($entry.FinalRunning){Start-Service -Name $owned.Name -ErrorAction Stop}else{Stop-Service -Name $owned.Name -ErrorAction Stop}}
        ScheduledTask {$last=$owned.Name.LastIndexOf('\');$args=@{TaskName=$owned.Name.Substring($last+1);TaskPath=$owned.Name.Substring(0,$last+1);ErrorAction='Stop'};if($entry.FinalMode -ceq 'True'){Enable-ScheduledTask @args | Out-Null}}
        {$_ -in @('IISPool','IISSite')} {$m=New-WsmIisManager;try{if($owned.Kind -eq 'IISPool'){$o=$m.ApplicationPools[$owned.Name];$parts=$entry.FinalMode.Split('|');$o.AutoStart=($parts[0] -ceq 'True');$o.StartMode=$parts[1]}else{$o=$m.Sites[$owned.Name];$o.ServerAutoStart=($entry.FinalMode -ceq 'True')};$m.CommitChanges();if($entry.FinalRunning){[void]$o.Start()}elseif([string]$o.State -ne 'Stopped'){[void]$o.Stop()}}finally{$m.Dispose()}}
    }}
    [void](Test-WsmInstallerConsumers $Desired $Receipt Final)
}
function Protect-WsmInstallerSideEffects($Desired,$Baseline) {
    Assert-WsmInstallerPolicy $Desired;if(-not $Baseline -or -not $Baseline.PSObject.Properties['Items']){throw 'Installer safety has no durable pre-install object baseline.'}
    $before=@{};foreach($o in $Baseline.Items){$before[$o.Kind+'|'+$o.Name.ToUpperInvariant()]=$o};$declared=@{};foreach($o in $Desired.SideEffects){$declared[$o.Kind+'|'+$o.Name.ToUpperInvariant()]=$true}
    $snapshot=Get-WsmInstallerSnapshot;$new=New-Object 'System.Collections.Generic.List[object]';$unexpected=New-Object 'System.Collections.Generic.List[string]'
    foreach($o in $snapshot.Items){$key=$o.Kind+'|'+$o.Name.ToUpperInvariant();if(-not $before.ContainsKey($key)){$new.Add($o);if(-not $declared.ContainsKey($key)){$unexpected.Add($key)};Stop-WsmInstallerObject $o}elseif($before[$key].Mode -cne $o.Mode -or $before[$key].ConfigHash -cne $o.ConfigHash){$unexpected.Add(('Existing object changed: '+$key))}}
    $after=@{};foreach($o in (Get-WsmInstallerSnapshot).Items){$after[$o.Kind+'|'+$o.Name.ToUpperInvariant()]=$o}
    foreach($o in $new){$key=$o.Kind+'|'+$o.Name.ToUpperInvariant();if(-not $after.ContainsKey($key) -or $after[$key].Running -or ($o.Kind -eq 'Service' -and $after[$key].Mode -ne 'Disabled') -or ($o.Kind -eq 'ScheduledTask' -and $after[$key].Mode -ne 'False') -or ($o.Kind -eq 'IISSite' -and $after[$key].Mode -ne 'False') -or ($o.Kind -eq 'IISPool' -and $after[$key].Mode -ne 'False|OnDemand')){throw 'Installer-created consumer did not reach verified disabled staging.'}}
    if($unexpected.Count){$error=New-Object InvalidOperationException(('Installer side effects differ from review; new consumers quarantined, existing changes need reconciliation: '+($unexpected -join '; ')));$error.Data['InstallerSideEffects']=$new.ToArray();throw $error}
    [pscustomobject]@{Quarantined=@(ConvertFrom-WsmJson (ConvertTo-Json -InputObject $new.ToArray() -Depth 15));IsolationEvidence=$Desired.IsolationEvidence;NoAutomaticReboot=$true;BeforeInstallerControl='Owner-verified isolation; installer may run new consumers before control returns'}
}
