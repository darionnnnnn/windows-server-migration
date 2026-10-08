#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    $script:fixtureTasks=@{};$script:fixtureServices=@{};$script:fixtureFeatures=@{}
    $script:fixtureFolder=[pscustomobject]@{}
    $script:fixtureFolder | Add-Member ScriptMethod GetFolder {param($Name)$script:fixtureFolder}
    $script:fixtureFolder | Add-Member ScriptMethod CreateFolder {param($Name)$script:fixtureFolder}
    $script:fixtureScheduler=[pscustomobject]@{};$script:fixtureScheduler | Add-Member ScriptMethod GetFolder {param($Path)$script:fixtureFolder}
    function script:New-WsmTaskScheduler {$script:fixtureScheduler}
    function script:Register-ScheduledTask {param($TaskName,$TaskPath,$Xml,$User,$Password,$ErrorAction)$doc=Read-WsmXml $Xml;$enabled=$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");if(-not $enabled -or $enabled.InnerText -ne 'false'){throw 'Fixture observed registration with enabled=true; dual-running risk.'};$script:fixtureTasks[$TaskPath+$TaskName]=[pscustomobject]@{Xml=$Xml;Settings=[pscustomobject]@{Enabled=$false}}}
    function script:Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)$script:fixtureTasks[$TaskPath+$TaskName]}
    function script:Export-ScheduledTask {param($TaskName,$TaskPath)$script:fixtureTasks[$TaskPath+$TaskName].Xml}
    function script:Enable-ScheduledTask {param($TaskName,$TaskPath)$t=$script:fixtureTasks[$TaskPath+$TaskName];$doc=Read-WsmXml $t.Xml;$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']").InnerText='true';$t.Xml=$doc.OuterXml;$t.Settings.Enabled=$true}
    function script:Disable-ScheduledTask {param($TaskName,$TaskPath)$t=$script:fixtureTasks[$TaskPath+$TaskName];$doc=Read-WsmXml $t.Xml;$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']").InnerText='false';$t.Xml=$doc.OuterXml;$t.Settings.Enabled=$false}
    function script:New-Service {param($Name,$BinaryPathName,$StartupType,$DisplayName,$Description,$Dependencies,$Credential,$ErrorAction)if($StartupType -ne 'Disabled'){throw 'Service was created active.'};$script:fixtureServices[$Name]=[pscustomobject]@{Name=$Name;DisplayName=$DisplayName;PathName=$BinaryPathName;StartMode='Disabled';StartName='LocalSystem';State='Stopped';Description=$Description;Dependencies=$Dependencies}}
    function script:Get-WsmServiceDependencies {param($Name) @($script:fixtureServices[$Name].Dependencies)}
    function script:Get-CimInstance {param($ClassName)if($ClassName -ne 'Win32_Service'){throw 'Unexpected CIM probe.'};$script:fixtureServices.Values}
    function script:Set-Service {param($Name,$StartupType)$mode=$StartupType;if($mode -eq 'Automatic'){$mode='Auto'};$script:fixtureServices[$Name].StartMode=$mode}
    function script:Start-Service {param($Name)$script:fixtureServices[$Name].State='Running'}
    function script:Stop-Service {param($Name,$ErrorAction)$script:fixtureServices[$Name].State='Stopped'}
    function script:Get-WindowsFeature {param($Name,$ErrorAction)[pscustomobject]@{Name=$Name;Installed=$script:fixtureFeatures.ContainsKey($Name)}}
    function script:Install-WindowsFeature {param($Name,$Source,$ErrorAction)$script:fixtureFeatures[$Name]=$true;[pscustomobject]@{Success=$true;RestartNeeded='Yes'}}
    $task=[pscustomobject]@{Adapter='ScheduledTask';Owner='fixture';Evidence='fixture-reviewed';DesiredFinalState='Enabled';Desired=[pscustomobject]@{TaskName='FixtureTask';TaskPath='\Fixture\';Xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>SYSTEM</UserId><LogonType>ServiceAccount</LogonType></Principal></Principals><Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers><Settings><Enabled>true</Enabled><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy></Settings><Actions><Exec><Command>C:\Fixture\worker.exe</Command></Exec></Actions></Task>';User='SYSTEM'}}
    Assert-WsmMigrationSpec $task;Invoke-WsmAdapterRestore $task @{} $null | Out-Null
    if(-not (Test-WsmAdapterConfiguration $task Staged).Passed){throw 'Disabled task registration did not verify.'}
    $t=$script:fixtureTasks['\Fixture\FixtureTask'];$old=$t.Xml;$t.Xml=$t.Xml.Replace('IgnoreNew','Parallel');if((Test-WsmAdapterConfiguration $task Staged).Passed){throw 'Task concurrency drift ignored.'};$t.Xml=$old
    Invoke-WsmAdapterActivation $task $true;if(-not (Test-WsmAdapterConfiguration $task Final).Passed){throw 'Final task activation did not verify.'};if((Test-WsmAdapterConfiguration $task Staged).Passed){throw 'Activated task accepted as staged.'}
    $service=[pscustomobject]@{Adapter='Service';Owner='fixture';Evidence='fixture-reviewed';DesiredFinalState='Automatic';Desired=[pscustomobject]@{Name='FixtureSvc';DisplayName='Fixture service';BinaryPathName='C:\Fixture\service.exe';Account='LocalSystem';Dependencies=@();Description='fixture'}}
    Assert-WsmMigrationSpec $service;Invoke-WsmAdapterRestore $service @{} $null | Out-Null;if(-not (Test-WsmAdapterConfiguration $service Staged).Passed){throw 'Disabled service did not verify.'};Invoke-WsmAdapterActivation $service $true;if(-not (Test-WsmAdapterConfiguration $service Final).Passed){throw 'Final service state did not verify.'};$script:fixtureServices.FixtureSvc.PathName='C:\Wrong.exe';if((Test-WsmAdapterConfiguration $service Final).Passed){throw 'Service binary drift ignored.'}
    $feature=[pscustomobject]@{Adapter='WindowsFeature';Owner='fixture';Evidence='fixture-reviewed';Desired=[pscustomobject]@{Name='Web-Server';Source=''}};$result=Invoke-WsmAdapterRestore $feature @{} $null;if(-not $result.RebootRequired){throw 'Feature reboot result lost.'}
    $bad=$false;try{$feature.Desired.Name='AD-Domain-Services';Assert-WsmAdapterDesired $feature}catch{$bad=$true};if(-not $bad){throw 'Identity role generic installation accepted.'}
    foreach($path in @('..\escape','folder\\same','folder\','C:\absolute','folder:stream','NUL.txt')){$bad=$false;try{Assert-WsmRelativePath $path}catch{$bad=$true};if(-not $bad){throw 'Unsafe/colliding artifact path accepted.'}}
    if((ConvertTo-WsmWindowsArgument 'a b') -cne '"a b"' -or (ConvertTo-WsmWindowsArgument '') -cne '""' -or (ConvertTo-WsmWindowsArgument 'a"b') -cne '"a\"b"'){throw 'Windows native argument quoting incorrect.'}
    Initialize-WsmNativeReader;$reader=New-Object IO.StringReader(('x'*200000)+'tail');try{$captured=[WsmNativeBoundedReader]::Drain($reader,65536).GetAwaiter().GetResult();if(-not $captured.Truncated -or $captured.Text.Length -ne 65536 -or -not $captured.Text.EndsWith('tail')){throw 'Native output drain was not bounded'}}finally{$reader.Dispose()}
    $script:bootStamp='before';function script:Get-WsmBootStamp {$script:bootStamp};$blocked=$false;try{Assert-WsmRebootCompleted ([pscustomobject]@{BootBefore='before'})}catch{$blocked=$true};if(-not $blocked){throw 'Required installer reboot bypassed'};$script:bootStamp='after';Assert-WsmRebootCompleted ([pscustomobject]@{BootBefore='before'})
    Write-Host 'PASS: task disabled at registration, Settings drift, activation/staging separation, service creation/binary/final state, feature reboot, protected role, path collisions and native quoting.'
}
