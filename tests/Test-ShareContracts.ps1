#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    $script:share=$null;$script:world='FixtureLocalizedWorld';$script:unblockCalls=0
    function script:Get-WsmEveryoneName {$script:world}
    function script:Resolve-WsmAccountSid {param($Account)if($Account -in @('S-1-1-0','FixtureLocalizedWorld')){return 'S-1-1-0'};if($Account -eq 'FixtureReaders'){return 'S-1-5-21-1-2-3-1001'};if($Account -eq 'Unreviewed'){return 'S-1-5-21-1-2-3-1002'};throw 'Unexpected fixture identity'}
    function script:New-SmbShare {param($Name,$Path,$Description,$EncryptData,$NoAccess,$ScopeName,$ErrorAction)if($NoAccess[0] -cne $script:world){throw 'Localized world principal lost'};$script:share=[pscustomobject]@{Name=$Name;ScopeName='*';Path=$Path;Description=$Description;EncryptData=$EncryptData;Access=@([pscustomobject]@{AccountName=$NoAccess[0];AccessControlType='Deny';AccessRight='Full'})}}
    function script:Get-SmbShare {param($Name,$ErrorAction)$script:share}
    function script:Get-SmbShareAccess {param($Name,$ScopeName)$script:share.Access}
    function script:Grant-SmbShareAccess {param($Name,$ScopeName,$AccountName,$AccessRight,[switch]$Force)$script:share.Access+=@([pscustomobject]@{AccountName=$AccountName;AccessControlType='Allow';AccessRight=$AccessRight})}
    function script:Block-SmbShareAccess {param($Name,$ScopeName,$AccountName,[switch]$Force)if(-not @($script:share.Access | Where-Object {$_.AccountName -eq $AccountName -and $_.AccessControlType -eq 'Deny'}).Count){$script:share.Access+=@([pscustomobject]@{AccountName=$AccountName;AccessControlType='Deny';AccessRight='Full'})}}
    function script:Unblock-SmbShareAccess {param($Name,$ScopeName,$AccountName,[switch]$Force)$script:unblockCalls++;$script:share.Access=@($script:share.Access | Where-Object {-not ($_.AccountName -eq $AccountName -and $_.AccessControlType -eq 'Deny')})}
    $spec=[pscustomobject]@{Adapter='SmbShare';Owner='fixture';Evidence='reviewed';DesiredFinalState='Enabled';Desired=[pscustomobject]@{Name='FixtureShare';DrainPolicy='BlockNewOpens';DrainEvidence='fixture reviewed drain';Path='C:\Fixture\data';Description='reviewed share';EncryptData=$true;Access=@([pscustomobject]@{AccountName='FixtureReaders';AccessControlType='Allow';AccessRight='Read'})}}
    Invoke-WsmAdapterRestore $spec @{} $null | Out-Null;if(-not (Test-WsmAdapterConfiguration $spec Staged).Passed){throw 'Exact localized staged share failed'}
    $script:share.Access+=@([pscustomobject]@{AccountName='Unreviewed';AccessControlType='Allow';AccessRight='Full'});if((Test-WsmAdapterConfiguration $spec Staged).Passed){throw 'Extra unreviewed share grant accepted'};$script:share.Access=@($script:share.Access | Where-Object AccountName -NE Unreviewed)
    Invoke-WsmAdapterActivation $spec $true;if(-not (Test-WsmAdapterConfiguration $spec Final).Passed -or $script:unblockCalls -ne 1){throw 'Temporary deny was not removed exactly at activation'}
    $spec.Desired.Access+=@([pscustomobject]@{AccountName=$script:world;AccessControlType='Deny';AccessRight='Full'});Invoke-WsmAdapterRestore $spec @{} $null | Out-Null;Invoke-WsmAdapterActivation $spec $true
    if($script:unblockCalls -ne 1 -or -not (Test-WsmAdapterConfiguration $spec Final).Passed){throw 'Reviewed original world deny was removed at activation'}
    $scopeSpec=ConvertFrom-WsmJson ($spec | ConvertTo-Json -Depth 30);$scopeSpec.Desired | Add-Member NoteProperty ScopeName 'ClusterScope'
    $blocked=$false;try{Assert-WsmMigrationSpec $scopeSpec}catch{$blocked=$true};if(-not $blocked){throw 'Generic adapter accepted a clustered/named-scope target.'}
    $script:share.ScopeName='ClusterScope';$blocked=$false;try{Get-WsmAdapterState $spec | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Generic adapter adopted an existing clustered share.'};$script:share.ScopeName='*'
    function script:Get-SmbShare {param($Name,$ErrorAction)@($script:share,$script:share)}
    $blocked=$false;try{Get-WsmAdapterState $spec | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Ambiguous same-name SMB scopes were accepted.'}
    function script:Get-SmbShare {param($Name,$ErrorAction)$script:share}
    $spec.Desired.Access[1].AccessRight='Read';$blocked=$false;try{Assert-WsmMigrationSpec $spec}catch{$blocked=$true};if(-not $blocked){throw 'Unsupported partial deny silently widened'}
}
Write-Host 'PASS: exact share ACL (including extra grants), localized world principal, temporary deny activation and preserved reviewed deny.'
