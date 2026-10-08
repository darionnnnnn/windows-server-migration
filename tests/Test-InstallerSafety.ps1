#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    $script:installerObjects=@();$script:stopCalls=0
    function script:Get-WsmInstallerSnapshot {[pscustomobject]@{Items=$script:installerObjects;Utc=(Get-WsmUtc)}}
    function script:Stop-WsmInstallerObject {param($Object)$script:stopCalls++;$Object.Mode='Disabled';$Object.Running=$false}
    $baseline=[pscustomobject]@{Items=@([pscustomobject]@{Kind='Service';ConfigHash=('a'*64);Name='Existing';Mode='Manual';Running=$false})}
    $desired=[pscustomobject]@{Name='FixtureFeature';IsolationEvidence='fixture isolated servicing window';SideEffects=@([pscustomobject]@{Kind='Service';Name='Created';FinalMode='Auto';FinalRunning=$true})}
    $script:installerObjects=@($baseline.Items[0],[pscustomobject]@{Kind='Service';ConfigHash=('b'*64);Name='Created';Mode='Auto';Running=$true})
    $result=Protect-WsmInstallerSideEffects $desired $baseline;if($result.Quarantined.Count -ne 1 -or $script:stopCalls -ne 1 -or $script:installerObjects[1].Running){throw 'Reviewed installer consumer not quarantined'}
    [void](Test-WsmInstallerConsumers $desired $result Staged)
    function script:Set-Service {param($Name,$StartupType,$ErrorAction)$object=@($script:installerObjects | Where-Object Name -EQ $Name)[0];$object.Mode=$StartupType;if($StartupType -ceq 'Automatic'){$object.Mode='Auto'}}
    function script:Start-Service {param($Name,$ErrorAction)@($script:installerObjects | Where-Object Name -EQ $Name)[0].Running=$true}
    function script:Stop-Service {param($Name,$ErrorAction)@($script:installerObjects | Where-Object Name -EQ $Name)[0].Running=$false}
    Invoke-WsmInstallerConsumerActivation $desired $result $true
    [void](Test-WsmInstallerConsumers $desired $result Final)
    $script:installerObjects[1].ConfigHash='d'*64;$blocked=$false;try{Test-WsmInstallerConsumers $desired $result Final | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Installer consumer configuration drift accepted'}
    $script:installerObjects[1].ConfigHash='b'*64
    $script:installerObjects+=@([pscustomobject]@{Kind='Service';ConfigHash=('c'*64);Name='Unreviewed';Mode='Auto';Running=$true});$blocked=$false;try{Protect-WsmInstallerSideEffects $desired $baseline | Out-Null}catch{$blocked=$true};if(-not $blocked -or $script:installerObjects[2].Running){throw 'Unreviewed new consumer accepted or left active'}
    $script:installerObjects=@([pscustomobject]@{Kind='Service';ConfigHash=('a'*64);Name='Existing';Mode='Auto';Running=$true});$calls=$script:stopCalls;$blocked=$false;try{Protect-WsmInstallerSideEffects $desired $baseline | Out-Null}catch{$blocked=$true};if(-not $blocked -or $script:stopCalls -ne $calls){throw 'Changed unowned preexisting consumer adopted or modified'}
    $desired.IsolationEvidence='';$blocked=$false;try{Assert-WsmInstallerPolicy $desired}catch{$blocked=$true};if(-not $blocked){throw 'Installer started without explicit isolation review'}
    $desired.IsolationEvidence='fixture';$desired.SideEffects=@([pscustomobject]@{Kind='Service';Name='Created';FinalMode='Auto';FinalRunning=$true})
    function script:Install-WindowsFeature {param($Name,$ErrorAction)$script:installerObjects=@($baseline.Items[0],[pscustomobject]@{Kind='Service';ConfigHash=('b'*64);Name='Created';Mode='Auto';Running=$true});throw (New-Object TimeoutException('fixture installer failed after creating consumer'))}
    $spec=[pscustomobject]@{Adapter='WindowsFeature';Owner='fixture';Evidence='reviewed';Desired=$desired};$blocked=$false;try{Invoke-WsmAdapterRestore $spec @{} $null $baseline | Out-Null}catch [TimeoutException]{$blocked=$true};if(-not $blocked -or $script:installerObjects[1].Running){throw 'Failed installer bypassed quarantine or lost failure'}
}
Write-Host 'PASS: installer policy, reviewed/unreviewed new consumer quarantine, existing-object drift and failed native installer cleanup. OS APIs are fixtures.'
