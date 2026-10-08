#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    function New-TestIisElement {
        param([string]$Tag,[hashtable]$Values=@{},[hashtable]$Defaults=@{},[object[]]$Children=@(),[object[]]$Members=@(),[string[]]$Keys=@())
        $attributes=@{}
        foreach($name in @($Values.Keys)+@($Defaults.Keys) | Select-Object -Unique){
            $value=$Defaults[$name]; if($Values.ContainsKey($name)){$value=$Values[$name]}
            $default=$Defaults[$name]
            $type=[string]; if($null -ne $value){$type=$value.GetType()}
            $schemaType='string'; if($type -eq [bool]){$schemaType='bool'}elseif($type -eq [TimeSpan]){$schemaType='timeSpan'}elseif($type -eq [int]){$schemaType='int'}elseif($type -eq [long]){$schemaType='int64'}elseif($type -eq [uint32]){$schemaType='uint'}
            $attributes[$name]=[pscustomobject]@{Name=$name;Value=$value;Schema=[pscustomobject]@{DefaultValue=$default;Type=$schemaType;IsUniqueKey=($Keys.Count -eq 1 -and $Keys -contains $name);IsCombinedKey=($Keys.Count -gt 1 -and $Keys -contains $name)}}
        }
        $map=@{}; foreach($child in $Children){$map[$child.ElementTagName]=$child}
        $element=[pscustomobject]@{ElementTagName=$Tag;Attributes=$attributes;ChildElements=@($Children);ChildMap=$map;CollectionMembers=(New-Object System.Collections.ArrayList)}
        foreach($member in $Members){[void]$element.CollectionMembers.Add($member)}
        $element | Add-Member ScriptMethod GetAttributeValue {param($name);if($this.Attributes.ContainsKey($name)){return $this.Attributes[$name].Value};return $null}
        $element | Add-Member ScriptMethod SetAttributeValue {param($name,$value);if(-not $this.Attributes.ContainsKey($name)){throw 'Unknown fixture attribute'};$this.Attributes[$name].Value=$value}
        $element | Add-Member ScriptMethod GetChildElement {param($name);if($this.ChildMap.ContainsKey($name)){return $this.ChildMap[$name]};throw 'Child schema not found'}
        $element | Add-Member ScriptMethod GetCollection {return $this.CollectionMembers}
        return $element
    }
    $scheduleA=New-TestIisElement 'add' @{name='early';value='01:00:00'} @{name='';value=''} @() @() @('name')
    $scheduleB=New-TestIisElement 'add' @{name='late';value='02:00:00'} @{name='';value=''} @() @() @('name')
    $schedule=New-TestIisElement 'schedule' @{} @{} @() @($scheduleA,$scheduleB)
    $restart=New-TestIisElement 'periodicRestart' @{time=[TimeSpan]::Zero} @{time=[TimeSpan]::Zero} @($schedule)
    $recycling=New-TestIisElement 'recycling' @{} @{} @($restart)
    $process=New-TestIisElement 'processModel' @{identityType='ApplicationPoolIdentity'} @{identityType='ApplicationPoolIdentity';userName='';password=''}
    $pool=New-TestIisElement 'add' @{name='FixturePool';autoStart=$false;startMode='OnDemand'} @{name='';autoStart=$false;startMode='OnDemand'} @($process,$recycling)
    $pool | Add-Member NoteProperty State 'Stopped';$pool | Add-Member NoteProperty AutoStart $false;$pool | Add-Member NoteProperty StartMode 'OnDemand'
    $xml='<add name="FixturePool" autoStart="true" startMode="AlwaysRunning"><processModel identityType="ApplicationPoolIdentity" /><recycling><periodicRestart time="00:00:00"><schedule><add name="early" value="01:00:00" /><add name="late" value="02:00:00" /></schedule></periodicRestart></recycling></add>'
    $doc=Read-WsmXml $xml
    $recursiveErrors=@(Test-WsmIisXmlElement $pool $doc.DocumentElement -Root); if($recursiveErrors.Count){$recursiveErrors | Write-Host; throw 'Recursive nested IIS collections did not verify'}
    $process.Attributes['userName'].Value='unexpected-account'
    $defaultErrors=@(Test-WsmIisXmlElement $pool $doc.DocumentElement -Root)
    if(-not ($defaultErrors -join "`n" | Select-String 'omitted attribute differs from schema default')){$defaultErrors | Write-Host;throw 'Omitted IIS schema default drift was accepted'}
    $process.Attributes['userName'].Value=''
    $nestedId=New-TestIisElement 'nested' @{id='drifted'} @{id=''}
    $idRoot=New-TestIisElement 'root' @{} @{} @($nestedId)
    $idXml=Read-WsmXml '<root><nested id="expected" /></root>'
    if(-not (@(Test-WsmIisXmlElement $idRoot $idXml.DocumentElement) -join "`n" | Select-String 'attribute mismatch')){throw 'Nested IIS id drift was ignored'}
    $typedTarget=New-TestIisElement 'timed' @{value='00:00:00'} @{value='00:00:00'}
    $typedTarget.Attributes['value'].Schema.Type='timeSpan'
    Set-WsmIisXmlElement $typedTarget (Read-WsmXml '<timed value="01:30:00" />').DocumentElement
    if($typedTarget.Attributes['value'].Value -isnot [TimeSpan] -or $typedTarget.Attributes['value'].Value -ne [TimeSpan]::FromMinutes(90)){throw 'IIS string schema type did not convert timeSpan value'}
    $boolTarget=New-TestIisElement 'boolItem' @{enabled='true'} @{enabled='true'}
    $boolTarget.Attributes['enabled'].Schema.Type='bool'
    $boolXml=Read-WsmXml '<boolItem enabled="true" />'
    if(@(Test-WsmIisXmlElement $boolTarget $boolXml.DocumentElement).Count){throw 'String-valued MWA boolean did not compare through schema type'}
    $boolTarget.Attributes['enabled'].Value='false'
    if(-not (@(Test-WsmIisXmlElement $boolTarget $boolXml.DocumentElement) -join "`n" | Select-String 'attribute mismatch')){throw 'String-valued MWA boolean drift was accepted'}
    [void]$schedule.CollectionMembers.Add((New-TestIisElement 'add' @{name='extra';value='03:00:00'} @{name='';value=''} @() @() @('name')))
    if(-not (@(Test-WsmIisXmlElement $pool $doc.DocumentElement -Root) -join "`n" | Select-String 'Unexpected IIS collection element')){throw 'Extra nested IIS collection member was accepted'}
    $schedule.CollectionMembers.RemoveAt(2)
    $schedule.CollectionMembers[0].Attributes['value'].Value='09:00:00'
    if(-not (@(Test-WsmIisXmlElement $pool $doc.DocumentElement -Root) -join "`n" | Select-String 'attribute mismatch')){throw 'Wrong nested IIS member attribute was accepted'}
    $schedule.CollectionMembers[0].Attributes['value'].Value='01:00:00'
    $compositeA=New-TestIisElement 'add' @{bindingInformation='*:80:';protocol='http';mode='plain'} @{bindingInformation='';protocol='';mode=''} @() @() @('protocol','bindingInformation')
    $compositeB=New-TestIisElement 'add' @{bindingInformation='*:80:';protocol='https';mode='sni'} @{bindingInformation='';protocol='';mode=''} @() @() @('protocol','bindingInformation')
    $compositeCollection=New-TestIisElement 'routes' @{} @{} @() @($compositeA,$compositeB)
    $compositeRoot=New-TestIisElement 'root' @{} @{} @($compositeCollection)
    $compositeXml=Read-WsmXml '<root><routes><add bindingInformation="*:80:" protocol="https" mode="sni" /><add bindingInformation="*:80:" protocol="http" mode="plain" /></routes></root>'
    if(@(Test-WsmIisXmlElement $compositeRoot $compositeXml.DocumentElement).Count){throw 'Composite IIS collection keys did not match recursively'}
    $duplicateXml=Read-WsmXml '<root><routes><add bindingInformation="*:80:" protocol="https" mode="sni" /><add bindingInformation="*:80:" protocol="https" mode="duplicate" /></routes></root>'
    if(-not (@(Test-WsmIisXmlElement $compositeRoot $duplicateXml.DocumentElement) -join "`n" | Select-String 'missing/ambiguous')){throw 'Repeated IIS XML key reused one target collection element'}
    $hash='A'*40;$bytes=New-Object byte[] 20;for($n=0;$n -lt 20;$n++){$bytes[$n]=170}
    $binding=[pscustomobject]@{Protocol='https';BindingInformation='*:443:fixture.example';CertificateHash=$bytes;CertificateStoreName='My';SslFlags=1}
    $site=[pscustomobject]@{Bindings=@($binding)};$desired=[pscustomobject]@{Bindings=@([pscustomobject]@{Protocol='https';BindingInformation='*:443:fixture.example';CertificateHash=$hash;CertificateStoreName='My';SslFlags=1})}
    if(@(Test-WsmIisBindings $site $desired).Count){throw 'Reviewed HTTPS binding did not verify'}
    $binding.CertificateStoreName='WebHosting';if(-not @(Test-WsmIisBindings $site $desired).Count){throw 'HTTPS store drift hidden'};$binding.CertificateStoreName='My';$binding.SslFlags=0;if(-not @(Test-WsmIisBindings $site $desired).Count){throw 'SNI flag drift hidden'};$binding.SslFlags=1
    $site.Bindings+=@([pscustomobject]@{Protocol='http';BindingInformation='*:80:'});if(-not @(Test-WsmIisBindings $site $desired).Count){throw 'Unexpected site binding hidden'}
    $spec=[pscustomobject]@{Adapter='IISSite';Desired=[pscustomobject]@{Name='Fixture';Xml='<site name="Fixture"><bindings><binding protocol="https" bindingInformation="*:443:fixture.example" /></bindings></site>';Bindings=$desired.Bindings};Owner='fixture';Evidence='reviewed'}
    Assert-WsmMigrationSpec $spec
    $spec.Desired.Bindings[0].CertificateHash='';$blocked=$false;try{Assert-WsmMigrationSpec $spec}catch{$blocked=$true};if(-not $blocked){throw 'HTTPS without reviewed key artifact allowed'}
    $spec.Desired.Bindings[0].CertificateHash=$hash;$spec.Desired.Xml=$spec.Desired.Xml.Replace('fixture.example','unreviewed.example');$blocked=$false;try{Assert-WsmMigrationSpec $spec}catch{$blocked=$true};if(-not $blocked){throw 'Binding XML/review discrepancy accepted'}
    if((ConvertTo-WsmFirewallProtocol 'TCP') -ne (ConvertTo-WsmFirewallProtocol '6')){throw 'Equivalent firewall protocol representation mismatched'}
    $script:fixtureManager=[pscustomobject]@{Sites=@{};ApplicationPools=@{FixturePool=$pool}}
    $script:fixtureManager | Add-Member ScriptMethod Dispose {}
    function New-WsmIisManager {$script:fixtureManager}
    $poolSpec=[pscustomobject]@{Adapter='IISPool';Desired=[pscustomobject]@{Name='FixturePool';Xml=$xml};DesiredFinalState='Enabled'}
    $stageErrors=@(Test-WsmIisConfiguration $poolSpec 'Staged'); if($stageErrors.Count){$stageErrors | Write-Host; throw 'IIS pool did not verify in disabled staged state'}
    $pool.State='Started';$pool.AutoStart=$true;$pool.StartMode='AlwaysRunning'
    if(@(Test-WsmIisConfiguration $poolSpec 'Final').Count){throw 'IIS pool did not verify in approved final state'}
    $pool.State='Stopped';$pool.AutoStart=$false;$pool.StartMode='AlwaysRunning'
    if(-not (@(Test-WsmIisConfiguration $poolSpec 'Staged') -join "`n" | Select-String 'StartMode')){throw 'Staged IIS pool with non-OnDemand mode was accepted'}
    Write-Host 'PASS: IIS HTTPS certificate/store/SNI, unexpected binding, XML/review mismatch and missing certificate guard; normalized firewall protocol. Real IIS provisioning is not exercised.'
}
