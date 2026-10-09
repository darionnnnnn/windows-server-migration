#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$transitionPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\SettingTransitions.ps1'))
& $module {
    param($transitionPath)
    . $transitionPath
    $script:settingFixtureState=$null
    $script:settingFixtureWrites=0
    Set-Item Function:\Get-WsmSettingNativeSnapshot -Value {param($Transition)$script:settingFixtureState}
    Set-Item Function:\Set-WsmSettingNativeState -Value {param($Transition,$State)$script:settingFixtureWrites++;$script:settingFixtureState=$State}
    Set-Item Function:\Get-WsmSettingTimeZoneSnapshot -Value {$script:settingFixtureState}
    function script:New-WsmSettingFixtureState {param([bool]$Exists,[AllowNull()]$Value,[string]$ValueKind='None',$DaylightSaving=$null)$state=[pscustomobject][ordered]@{Exists=$Exists;Value=$Value;ValueKind=$ValueKind};if($null -ne $DaylightSaving){$state | Add-Member NoteProperty DaylightSaving $DaylightSaving};$state}
    function script:New-WsmFixtureTransition {param($Adapter,$Action,$Before,$After,[string]$Name='TNS_ADMIN')
        New-WsmSettingTransition -Adapter $Adapter -Action $Action -Name $Name -Before $Before -After $After -Owner 'fixture-owner' -Evidence 'review-record:fixture-42' -OwnerReviewHash ('b'*64)
    }
    $target=('a'*64);$journal=('c'*64)
    $absent=New-WsmSettingFixtureState $false $null 'None'
    $blank=New-WsmSettingFixtureState $true '' 'String'
    $sensitiveLocal=New-WsmSettingFixtureState $true 'fixture-user/fixture-private-value@alias' 'String'
    foreach($states in @(@($sensitiveLocal,$blank),@($blank,$sensitiveLocal))){$localBlocked=$false;try{New-WsmFixtureTransition 'MachineEnvironment' 'UpdateReviewed' $states[0] $states[1] 'LOCAL' | Out-Null}catch{$localBlocked=$_.Exception.Message -match 'Nonempty Oracle LOCAL'};if(-not $localBlocked){throw 'Raw before/after LOCAL content was accepted into a transition.'}}
    $localBlocked=$false;try{Assert-WsmAdapterDesired ([pscustomobject]@{Adapter='MachineEnvironment';Desired=[pscustomobject]@{Name='LOCAL';Value=$sensitiveLocal.Value}})}catch{$localBlocked=$_.Exception.Message -match 'Nonempty Oracle LOCAL'};if(-not $localBlocked){throw 'Legacy adapter accepted raw LOCAL content.'}
    $script:settingFixtureState=$absent;$script:settingFixtureWrites=0
    $create=New-WsmFixtureTransition 'MachineEnvironment' 'CreateNew' $absent $blank
    $intent=Get-WsmSettingTransitionIntent $create $target
    $receipt=Invoke-WsmSettingTransitionApply $create $intent $target $journal
    if(-not $receipt.CreatedByTool -or $receipt.UpdatedByTool -or $script:settingFixtureWrites -ne 1 -or -not (Test-WsmSettingStateEqual $script:settingFixtureState $blank 'MachineEnvironment')){throw 'CreateNew did not preserve blank value and tool ownership.'}
    $rollback=Invoke-WsmSettingTransitionRollback $create $intent $receipt $target $journal
    if($rollback.Status -ne 'RestoredPriorValue' -or $script:settingFixtureState.Exists){throw 'CreateNew rollback did not restore explicit absence.'}

    $prior=New-WsmSettingFixtureState $true 'C:\Oracle\old' 'ExpandString'
    $after=New-WsmSettingFixtureState $true 'C:\Oracle\new' 'String'
    $script:settingFixtureState=$prior
    $update=New-WsmFixtureTransition 'MachineEnvironment' 'UpdateReviewed' $prior $after
    $intent=Get-WsmSettingTransitionIntent $update $target
    $receipt=Invoke-WsmSettingTransitionApply $update $intent $target $journal
    if(-not $receipt.UpdatedByTool -or $receipt.CreatedByTool -or $script:settingFixtureState.Value -cne $after.Value){throw 'UpdateReviewed did not apply exact after value.'}
    $null=Invoke-WsmSettingTransitionRollback $update $intent $receipt $target $journal
    if(-not (Test-WsmSettingStateEqual $script:settingFixtureState $prior 'MachineEnvironment')){throw 'UpdateReviewed rollback lost prior value kind/value.'}

    $script:settingFixtureState=$prior
    $intent=Get-WsmSettingTransitionIntent $update $target
    $script:settingFixtureState=New-WsmSettingFixtureState $true 'C:\Oracle\concurrent-change' 'String'
    $writes=$script:settingFixtureWrites;$blocked=$false
    try{Invoke-WsmSettingTransitionApply $update $intent $target $journal | Out-Null}catch{$blocked=$true}
    if(-not $blocked -or $script:settingFixtureWrites -ne $writes){throw 'Before-write drift did not block mutation.'}

    $script:settingFixtureState=$prior
    $intent=Get-WsmSettingTransitionIntent $update $target
    $receipt=Invoke-WsmSettingTransitionApply $update $intent $target $journal
    $script:settingFixtureState=New-WsmSettingFixtureState $true 'C:\Oracle\owner-change' 'String'
    $blocked=$false;try{Invoke-WsmSettingTransitionRollback $update $intent $receipt $target $journal | Out-Null}catch{$blocked=$true}
    if(-not $blocked -or $script:settingFixtureState.Value -cne 'C:\Oracle\owner-change'){throw 'After-write drift was overwritten by rollback.'}

    $script:settingFixtureState=$after
    $verify=New-WsmFixtureTransition 'MachineEnvironment' 'VerifyExternal' $after $after
    $intent=Get-WsmSettingTransitionIntent $verify $target
    $writes=$script:settingFixtureWrites;$receipt=Invoke-WsmSettingTransitionApply $verify $intent $target $journal
    if($receipt.CreatedByTool -or $receipt.UpdatedByTool -or $script:settingFixtureWrites -ne $writes){throw 'VerifyExternal claimed ownership or wrote the setting.'}
    $blocked=$false;try{Invoke-WsmSettingTransitionRollback $verify $intent $receipt $target $journal | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'External setting was given a rollback path.'}

    $blocked=$false;try{New-WsmFixtureTransition 'MachineEnvironment' 'UpdateReviewed' $prior $after 'PATH' | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Reserved PATH update was accepted.'}
    $blocked=$false;try{New-WsmSettingTransition -Adapter MachineEnvironment -Action UpdateReviewed -Name NLS_LANG -Before $prior -After $after -Owner fixture -Evidence reviewed -OwnerReviewHash 'not-a-hash' | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Missing owner review hash was accepted.'}
    $blocked=$false;try{Invoke-WsmSettingTransitionApply $update $intent $target 'bad-journal' | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'Malformed durable journal binding was accepted.'}

    $legacy=[pscustomobject]@{Adapter='MachineEnvironment';Owner='legacy';Evidence='v1';Desired=[pscustomobject]@{Name='NLS_LANG';Value='AMERICAN'}}
    Assert-WsmAdapterDesired $legacy
    $legacy | Add-Member NoteProperty SettingTransition $update
    $blocked=$false;try{Assert-WsmAdapterDesired $legacy}catch{$blocked=$true};if(-not $blocked){throw 'MachineEnvironment desired value was allowed to differ from reviewed after state.'}

    $dstBefore=[pscustomobject][ordered]@{Exists=$true;Value=$false;ValueKind='DWord'}
    $dstAfter=[pscustomobject][ordered]@{Exists=$true;Value=$true;ValueKind='DWord'}
    $zoneBefore=[pscustomobject][ordered]@{Exists=$true;Value='UTC';ValueKind='TimeZoneId';DaylightSaving=$dstBefore}
    $zoneAfter=[pscustomobject][ordered]@{Exists=$true;Value='Pacific Standard Time';ValueKind='TimeZoneId';DaylightSaving=$dstAfter}
    $script:settingFixtureState=$zoneBefore
    $zone=New-WsmFixtureTransition 'TimeZone' 'UpdateReviewed' $zoneBefore $zoneAfter 'TimeZone'
    $zoneSpec=[pscustomobject]@{Adapter='TimeZone';Owner='fixture';Evidence='reviewed';Desired=[pscustomobject]@{Name='TimeZone';Value='Pacific Standard Time'};SettingTransition=$zone}
    Assert-WsmAdapterDesired $zoneSpec
    $blocked=$false;try{Invoke-WsmAdapterRestore $zoneSpec @{} $null}catch{$blocked=$true};if(-not $blocked){throw 'Generic TimeZone adapter restore bypassed the journal coordinator.'}
    $intent=Get-WsmSettingTransitionIntent $zone $target
    $receipt=Invoke-WsmSettingTransitionApply $zone $intent $target $journal
    if(-not (Test-WsmAdapterConfiguration $zoneSpec Staged).Passed){throw 'TimeZone adapter did not verify exact zone and DST state.'}
    $null=Invoke-WsmSettingTransitionRollback $zone $intent $receipt $target $journal
    if(-not (Test-WsmSettingStateEqual $script:settingFixtureState $zoneBefore 'TimeZone')){throw 'Time zone rollback did not restore the prior zone and DST state.'}
    $blocked=$false;try{New-WsmFixtureTransition 'TimeZone' 'CreateNew' $zoneBefore $zoneAfter 'TimeZone' | Out-Null}catch{$blocked=$true};if(-not $blocked){throw 'TimeZone incorrectly allowed CreateNew.'}

    $capabilities=@(Get-WsmSettingTransitionCapabilities)
    if(@($capabilities | Where-Object Adapter -EQ TimeZone).Count -ne 1 -or @($capabilities | Where-Object Adapter -EQ MachineEnvironment).Count -ne 1){throw 'Transition capability matrix is incomplete.'}
    $policy=@(Get-WsmSettingEffectivePolicySnapshot)
    if(@($policy | Group-Object Name | Where-Object Count -NE 1).Count -or @($policy | Where-Object Mutation -NE None).Count){throw 'OS policy metadata collector duplicated a probe or reported mutation.'}
    foreach($name in @('EffectivePolicy','ServiceAccountRights','OracleOsSupport')){if(@($policy | Where-Object {$_.Name -ceq $name -and $_.Status -eq 'NotTested'}).Count -ne 1){throw "Unqualified OS gate $name must remain explicit NotTested."}}
    'Setting transition contract fixtures passed.'
} $transitionPath
