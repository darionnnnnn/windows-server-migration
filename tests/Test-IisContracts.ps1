#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
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
    Write-Host 'PASS: IIS HTTPS certificate/store/SNI, unexpected binding, XML/review mismatch and missing certificate guard; normalized firewall protocol. Real IIS provisioning is not exercised.'
}
