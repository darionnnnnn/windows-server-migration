Set-StrictMode -Version Latest

$script:WsmReviewedMachineEnvironmentNames=@('TNS_ADMIN','NLS_LANG','LDAP_ADMIN','LOCAL','ORA_TZFILE')

function Get-WsmSettingTransitionProjectionHash {
    param([Parameter(Mandatory)]$Transition)
    $projection=[ordered]@{SchemaVersion=[int]$Transition.SchemaVersion;Kind=[string]$Transition.Kind;Adapter=[string]$Transition.Adapter;Action=[string]$Transition.Action;Name=[string]$Transition.Name;Before=$Transition.Before;After=$Transition.After;Owner=[string]$Transition.Owner;Evidence=[string]$Transition.Evidence;OwnerReviewHash=[string]$Transition.OwnerReviewHash;RequiredPhase=[string]$Transition.RequiredPhase}
    Get-WsmHashText ($projection | ConvertTo-Json -Depth 20 -Compress)
}

function ConvertTo-WsmSettingValueState {
    param([Parameter(Mandatory)]$State,[ValidateSet('MachineEnvironment','TimeZone')][string]$Adapter)
    if($State -is [System.Collections.IDictionary]){$existsValue=$State['Exists'];$value=$State['Value'];$kind=$State['ValueKind']}else{$existsValue=$State.Exists;$value=$State.Value;$kind=$State.ValueKind}
    $normalized=[ordered]@{Exists=[bool]$existsValue;Value=$value;ValueKind=[string]$kind}
    if($Adapter -eq 'TimeZone'){$dst=$State.DaylightSaving;if($State -is [System.Collections.IDictionary]){$dst=$State['DaylightSaving']};$dstExists=$dst.Exists;$dstValue=$dst.Value;$dstKind=$dst.ValueKind;if($dst -is [System.Collections.IDictionary]){$dstExists=$dst['Exists'];$dstValue=$dst['Value'];$dstKind=$dst['ValueKind']};$normalized.DaylightSaving=[pscustomobject][ordered]@{Exists=[bool]$dstExists;Value=$dstValue;ValueKind=[string]$dstKind}}
    [pscustomobject]$normalized
}

function Assert-WsmSettingValueState {
    param([Parameter(Mandatory)]$State,[ValidateSet('MachineEnvironment','TimeZone')][string]$Adapter)
    $required=@('Exists','Value','ValueKind');foreach($field in $required){if(-not $State.PSObject.Properties[$field]){throw "Setting value state requires $field."}}
    $allowed=@('Exists','Value','ValueKind');if($Adapter -eq 'TimeZone'){$allowed+=@('DaylightSaving','SupportsDaylightSavingTime','StandardName','DisplayName')};Assert-WsmFields $State $allowed $required
    if($State.Exists -isnot [bool]){throw 'Setting Exists must be a Boolean.'}
    if(-not $State.Exists){if($null -ne $State.Value -or $State.ValueKind -cne 'None'){throw 'Absent setting values require null Value and ValueKind None.'}}
    elseif($null -eq $State.Value){throw 'Present setting value cannot be null; use empty string for a blank value.'}
    if($Adapter -eq 'MachineEnvironment') {
        if($State.Exists -and ($State.Value -isnot [string] -or $State.Value.Length -gt 8192 -or $State.Value -match '(?i)(password|pwd|secret|token)\s*[:=]|//[^\s/:]+:[^\s/@]+@')){throw 'Setting state contains unsupported secret-bearing or oversized data.'}
        if(($State.Exists -and $State.ValueKind -notin @('String','ExpandString')) -or (-not $State.Exists -and $State.ValueKind -cne 'None')){throw 'Machine environment values require String/ExpandString when present and None when absent.'}
        if($State.PSObject.Properties['DaylightSaving']){throw 'Machine environment cannot contain timezone state.'}
    } else {
        if(-not $State.Exists -or $State.ValueKind -cne 'TimeZoneId' -or [string]::IsNullOrWhiteSpace([string]$State.Value)){throw 'Time zone state must always contain a valid zone identifier.'}
        if(-not $State.PSObject.Properties['DaylightSaving']){throw 'Time zone state must include daylight-saving registry state.'}
        $dst=$State.DaylightSaving;foreach($field in @('Exists','Value','ValueKind')){if(-not $dst.PSObject.Properties[$field]){throw "Daylight-saving state requires $field."}}
        Assert-WsmFields $dst @('Exists','Value','ValueKind') @('Exists','Value','ValueKind')
        if($dst.Exists -isnot [bool] -or (-not $dst.Exists -and ($null -ne $dst.Value -or $dst.ValueKind -cne 'None')) -or ($dst.Exists -and ($dst.Value -isnot [bool] -or $dst.ValueKind -cne 'DWord'))){throw 'Daylight-saving registry state is not a typed Boolean DWORD or explicit absence.'}
    }
}

function Assert-WsmSettingTransition {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)]$Transition)
    process {
        if($Transition.Kind -cne 'SettingTransition' -or $Transition.SchemaVersion -ne 1){throw 'Invalid setting transition envelope.'}
        Assert-WsmFields $Transition @('SchemaVersion','Kind','Adapter','Action','Name','Before','After','Owner','Evidence','OwnerReviewHash','RequiredPhase','TransitionHash') @('SchemaVersion','Kind','Adapter','Action','Name','Before','After','Owner','Evidence','OwnerReviewHash','RequiredPhase','TransitionHash')
        if($Transition.Adapter -notin @('MachineEnvironment','TimeZone') -or $Transition.Action -notin @('CreateNew','KeepTarget','VerifyExternal','UpdateReviewed')){throw 'Unsupported setting adapter or action.'}
        foreach($field in @('Name','Before','After','Owner','Evidence','OwnerReviewHash','RequiredPhase','TransitionHash')){if(-not $Transition.PSObject.Properties[$field]){throw "Setting transition requires $field."}}
        if([string]::IsNullOrWhiteSpace([string]$Transition.Owner) -or [string]::IsNullOrWhiteSpace([string]$Transition.Evidence) -or [string]$Transition.OwnerReviewHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Setting transition requires owner review proof and evidence hash.'}
        if($Transition.RequiredPhase -notin @('StagedDependencyVerified','CutoverReady')){throw 'Invalid setting transition RequiredPhase.'}
        Assert-WsmSettingValueState $Transition.Before $Transition.Adapter;Assert-WsmSettingValueState $Transition.After $Transition.Adapter
        if($Transition.Adapter -eq 'MachineEnvironment') {
            if($Transition.Name -ieq 'LOCAL' -and (($Transition.Before.Exists -and $Transition.Before.Value.Length -gt 0) -or ($Transition.After.Exists -and $Transition.After.Value.Length -gt 0))){throw 'Nonempty Oracle LOCAL values may contain credentials and require an external procedure; they cannot enter setting transitions or journals.'}
            if($Transition.Name -match '(?i)(^|_)(password|pwd|secret|token|key|credential)(_|$)'){throw 'Secret-bearing environment names require independent secret handling.'}
            if([string]$Transition.Name -cnotin $script:WsmReviewedMachineEnvironmentNames){if($Transition.Action -in @('CreateNew','UpdateReviewed')){throw 'This machine environment value is outside the reviewed write whitelist.'};if([string]$Transition.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$'){throw 'Invalid machine environment name.'}}
            if($Transition.Action -in @('CreateNew','UpdateReviewed') -and $Transition.After.ValueKind -notin @('String','ExpandString')){throw 'Machine environment writes support only REG_SZ and REG_EXPAND_SZ.'}
        } else {
            if($Transition.Name -cne 'TimeZone'){throw 'TimeZone adapter name must be TimeZone.'}
            if($Transition.Action -eq 'CreateNew'){throw 'A time zone always exists and cannot use CreateNew.'}
            if($Transition.Action -in @('KeepTarget','VerifyExternal','UpdateReviewed')) {
                try{$null=[TimeZoneInfo]::FindSystemTimeZoneById([string]$Transition.After.Value)}catch{throw 'Requested time zone identifier is not installed on this host.'}
            }
        }
        switch($Transition.Action){
            CreateNew {if($Transition.Adapter -ne 'MachineEnvironment' -or $Transition.Before.Exists -or -not $Transition.After.Exists){throw 'CreateNew requires an absent machine setting and a present after value.'}}
            KeepTarget {if(-not $Transition.After.Exists){throw 'KeepTarget must describe the exact present target state.'}}
            VerifyExternal {if(-not $Transition.After.Exists){throw 'VerifyExternal must describe the exact externally managed state.'}}
            UpdateReviewed {if(-not $Transition.Before.Exists -or -not $Transition.After.Exists){throw 'UpdateReviewed requires explicit present before and after values; use CreateNew for an absent prior value.'}}
        }
        if($Transition.Action -in @('KeepTarget','VerifyExternal') -and -not (Test-WsmSettingStateEqual $Transition.Before $Transition.After $Transition.Adapter)){throw 'Read-only transitions must bind the same exact before and after state.'}
        if($Transition.Action -eq 'UpdateReviewed' -and (Test-WsmSettingStateEqual $Transition.Before $Transition.After $Transition.Adapter)){throw 'UpdateReviewed must describe a real reviewed setting change.'}
        if((Get-WsmSettingTransitionProjectionHash $Transition) -ine [string]$Transition.TransitionHash){throw 'Setting transition hash mismatch.'}
        $true
    }
}

function New-WsmSettingTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('MachineEnvironment','TimeZone')][string]$Adapter,
        [Parameter(Mandatory)][ValidateSet('CreateNew','KeepTarget','VerifyExternal','UpdateReviewed')][string]$Action,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$OwnerReviewHash,
        [ValidateSet('StagedDependencyVerified','CutoverReady')][string]$RequiredPhase='StagedDependencyVerified'
    )
    $transition=[pscustomobject][ordered]@{SchemaVersion=1;Kind='SettingTransition';Adapter=$Adapter;Action=$Action;Name=$Name;Before=(ConvertTo-WsmSettingValueState $Before $Adapter);After=(ConvertTo-WsmSettingValueState $After $Adapter);Owner=$Owner;Evidence=$Evidence;OwnerReviewHash=$OwnerReviewHash.ToLowerInvariant();RequiredPhase=$RequiredPhase;TransitionHash=('0'*64)}
    $transition.TransitionHash=Get-WsmSettingTransitionProjectionHash $transition
    Assert-WsmSettingTransition $transition | Out-Null
    $transition
}

function Get-WsmSettingTransitionCapabilities {
    @(
        [pscustomobject]@{Adapter='MachineEnvironment';Actions=@('CreateNew','KeepTarget','VerifyExternal','UpdateReviewed');WriteWhitelist=@($script:WsmReviewedMachineEnvironmentNames);NativeApi='HKLM SYSTEM\CurrentControlSet\Control\Session Manager\Environment';RequiredPrivilege='Local administrator';Isolation='Machine-wide environment changes affect new processes; business consumers remain isolated';Restart='New process or reviewed service recycle; no automatic reboot';Readback='Registry value, exact native value kind, and environment expansion semantics';Rollback='CreateNew removes only unchanged tool-created value; UpdateReviewed restores exact prior kind/value after drift check';ProductionVerified=$false;QualificationStatus='NotTested'}
        [pscustomobject]@{Adapter='TimeZone';Actions=@('KeepTarget','VerifyExternal','UpdateReviewed');WriteWhitelist=@('TimeZoneId','DynamicDaylightTimeDisabled');NativeApi='Set-TimeZone plus TimeZoneInformation registry readback';RequiredPrivilege='Local administrator';Isolation='Clock and scheduled work impact requires owner review';Restart='No automatic reboot; assess clock-sensitive consumers and DST/catch-up';Readback='Effective zone ID, DST capability, and DynamicDaylightTimeDisabled prior/value/type';Rollback='Restore prior zone and DST flag only when current state matches tool after-state';ProductionVerified=$false;QualificationStatus='NotTested'}
    )
}

function Get-WsmSettingNativeSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transition)
    Assert-WsmSettingTransition $Transition | Out-Null
    if($Transition.Adapter -eq 'MachineEnvironment') {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Default)
        try{$key=$base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$false);if(-not $key){throw 'Machine environment registry key is unavailable.'};try{$exists=$key.GetValueNames() -contains $Transition.Name;if(-not $exists){return [pscustomobject][ordered]@{Exists=$false;Value=$null;ValueKind='None'}};$kind=$key.GetValueKind($Transition.Name).ToString();$value=$key.GetValue($Transition.Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);[pscustomobject][ordered]@{Exists=$true;Value=[string]$value;ValueKind=$kind}}finally{$key.Dispose()}}finally{$base.Dispose()}
    } else {Get-WsmSettingTimeZoneSnapshot}
}

function Get-WsmSettingTimeZoneSnapshot {
    [TimeZoneInfo]::ClearCachedData();$zone=Get-TimeZone -ErrorAction Stop
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Default)
    try{$key=$base.OpenSubKey('SYSTEM\CurrentControlSet\Control\TimeZoneInformation',$false);if(-not $key){throw 'Time zone registry key is unavailable.'};try{$dstExists=$key.GetValueNames() -contains 'DynamicDaylightTimeDisabled';if($dstExists){$dstRaw=[int]$key.GetValue('DynamicDaylightTimeDisabled',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);if($dstRaw -notin @(0,1)){throw 'Unsupported daylight-saving DWORD; exact prior state cannot be represented.'};$dstValue=$dstRaw -ne 0;$dstKind=$key.GetValueKind('DynamicDaylightTimeDisabled').ToString();$dst=[pscustomobject][ordered]@{Exists=$true;Value=[bool]$dstValue;ValueKind=$dstKind}}else{$dst=[pscustomobject][ordered]@{Exists=$false;Value=$null;ValueKind='None'}};[pscustomobject][ordered]@{Exists=$true;Value=[string]$zone.Id;ValueKind='TimeZoneId';DaylightSaving=$dst;SupportsDaylightSavingTime=[bool]$zone.SupportsDaylightSavingTime;StandardName=[string]$zone.StandardName;DisplayName=[string]$zone.DisplayName}}finally{$key.Dispose()}}finally{$base.Dispose()}
}

function Get-WsmSettingTransitionIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transition,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$TargetFingerprint)
    Assert-WsmSettingTransition $Transition | Out-Null
    $observed=Get-WsmSettingNativeSnapshot $Transition
    $expected=$Transition.Before;if($Transition.Action -in @('KeepTarget','VerifyExternal')){$expected=$Transition.After}
    if(-not (Test-WsmSettingStateEqual $observed $expected $Transition.Adapter)){throw 'Target setting differs from the reviewed transition snapshot; capture a fresh target baseline.'}
    $intent=[pscustomobject][ordered]@{SchemaVersion=1;Kind='SettingTransitionIntent';IntentId=[Guid]::NewGuid().ToString();TransitionHash=$Transition.TransitionHash;TargetFingerprint=$TargetFingerprint.ToLowerInvariant();Action=$Transition.Action;Adapter=$Transition.Adapter;Name=$Transition.Name;Prior=$observed;ExpectedBefore=$Transition.Before;ExpectedAfter=$Transition.After;CapturedUtc=(Get-WsmUtc);Owner=$Transition.Owner;OwnerReviewHash=$Transition.OwnerReviewHash;IntentHash=('0'*64)}
    $intent.IntentHash=Get-WsmHashText (($intent | Select-Object SchemaVersion,Kind,IntentId,TransitionHash,TargetFingerprint,Action,Adapter,Name,Prior,ExpectedBefore,ExpectedAfter,CapturedUtc,Owner,OwnerReviewHash | ConvertTo-Json -Depth 20 -Compress))
    $intent
}

function Test-WsmSettingStateEqual {
    param($Actual,$Expected,[string]$Adapter)
    if($null -eq $Actual -or $null -eq $Expected){return $false}
    if([bool]$Actual.Exists -ne [bool]$Expected.Exists -or [string]$Actual.ValueKind -cne [string]$Expected.ValueKind){return $false}
    if($Actual.Exists -and [string]$Actual.Value -cne [string]$Expected.Value){return $false}
    if($Adapter -eq 'TimeZone') { $a=$Actual.DaylightSaving;$e=$Expected.DaylightSaving;if([bool]$a.Exists -ne [bool]$e.Exists -or [string]$a.ValueKind -cne [string]$e.ValueKind -or ($a.Exists -and [bool]$a.Value -ne [bool]$e.Value)){return $false} }
    $true
}

function Assert-WsmSettingTransitionIntent {
    param($Transition,$Intent,[string]$TargetFingerprint)
    Assert-WsmSettingTransition $Transition | Out-Null
    if($Intent.Kind -cne 'SettingTransitionIntent' -or $Intent.SchemaVersion -ne 1 -or $Intent.TransitionHash -ine $Transition.TransitionHash -or $Intent.Adapter -cne $Transition.Adapter -or $Intent.Action -cne $Transition.Action -or $Intent.Name -cne $Transition.Name -or $Intent.TargetFingerprint -ine $TargetFingerprint){throw 'Setting transition intent binding mismatch.'}
    $computed=Get-WsmHashText (($Intent | Select-Object SchemaVersion,Kind,IntentId,TransitionHash,TargetFingerprint,Action,Adapter,Name,Prior,ExpectedBefore,ExpectedAfter,CapturedUtc,Owner,OwnerReviewHash | ConvertTo-Json -Depth 20 -Compress))
    if($computed -ine [string]$Intent.IntentHash -or $Intent.OwnerReviewHash -ine $Transition.OwnerReviewHash -or $Intent.Owner -cne $Transition.Owner -or -not (Test-WsmSettingStateEqual $Intent.ExpectedBefore $Transition.Before $Transition.Adapter) -or -not (Test-WsmSettingStateEqual $Intent.ExpectedAfter $Transition.After $Transition.Adapter)){throw 'Setting transition intent hash/review binding mismatch.'}
    $priorExpected=$Transition.Before;if($Transition.Action -in @('KeepTarget','VerifyExternal')){$priorExpected=$Transition.After};if(-not (Test-WsmSettingStateEqual $Intent.Prior $priorExpected $Transition.Adapter)){throw 'Setting transition intent prior state differs from reviewed before/verification state.'}
    Assert-WsmSettingValueState $Intent.Prior $Transition.Adapter
}

function Get-WsmSettingTransitionReceiptHash {
    param([Parameter(Mandatory)]$Receipt)
    Get-WsmHashText (($Receipt | Select-Object Kind,Status,Action,TransitionHash,IntentId,JournalHash,TargetFingerprint,CreatedByTool,UpdatedByTool,Before,After,ReadbackUtc | ConvertTo-Json -Depth 20 -Compress))
}

function New-WsmSettingTransitionRecoveredReceipt {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transition,[Parameter(Mandatory)]$Intent,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$TargetFingerprint,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$JournalHash)
    Assert-WsmSettingTransition $Transition | Out-Null;Assert-WsmSettingTransitionIntent $Transition $Intent $TargetFingerprint
    $current=Get-WsmSettingNativeSnapshot $Transition
    if(-not (Test-WsmSettingStateEqual $current $Transition.After $Transition.Adapter)){throw 'Cannot recover a setting receipt unless current native state exactly matches reviewed after state.'}
    $before=$Intent.Prior
    if(-not (Test-WsmSettingStateEqual $before $Transition.Before $Transition.Adapter)){throw 'Recovered setting intent prior state differs from reviewed before state.'}
    $receipt=[pscustomobject][ordered]@{Kind='SettingTransitionReceipt';Status='RecoveredApplied';Action=$Transition.Action;TransitionHash=$Transition.TransitionHash;IntentId=$Intent.IntentId;JournalHash=$JournalHash.ToLowerInvariant();TargetFingerprint=$TargetFingerprint.ToLowerInvariant();CreatedByTool=($Transition.Action -eq 'CreateNew');UpdatedByTool=($Transition.Action -eq 'UpdateReviewed');Before=$before;After=$current;ReadbackUtc=(Get-WsmUtc);ReceiptHash=('0'*64)}
    $receipt.ReceiptHash=Get-WsmSettingTransitionReceiptHash $receipt;$receipt | Add-Member NoteProperty Intent $Intent -Force;$receipt
}

function Set-WsmSettingNativeState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transition,[Parameter(Mandatory)]$State)
    Assert-WsmSettingValueState $State $Transition.Adapter
    if($Transition.Adapter -eq 'MachineEnvironment') {
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Default)
        try{$key=$base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$true);if(-not $key){throw 'Machine environment registry key is unavailable.'};try{if(-not $State.Exists){$key.DeleteValue($Transition.Name,$false)}else{$kind=[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$State.ValueKind);$key.SetValue($Transition.Name,[string]$State.Value,$kind)}}finally{$key.Dispose()}}finally{$base.Dispose()};return
    }
    if(-not $State.Exists){throw 'Time zone state cannot be removed.'}
    Set-TimeZone -Id ([string]$State.Value) -ErrorAction Stop
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Default)
    try{$key=$base.OpenSubKey('SYSTEM\CurrentControlSet\Control\TimeZoneInformation',$true);if(-not $key){throw 'Time zone registry key is unavailable.'};try{$dst=$State.DaylightSaving;if($dst.Exists){$kind=[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$dst.ValueKind);$key.SetValue('DynamicDaylightTimeDisabled',[int][bool]$dst.Value,$kind)}else{$key.DeleteValue('DynamicDaylightTimeDisabled',$false)}}finally{$key.Dispose()}}finally{$base.Dispose()}
}

function Invoke-WsmSettingTransitionApply {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transition,[Parameter(Mandatory)]$Intent,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$TargetFingerprint,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$JournalHash)
    Assert-WsmSettingTransition $Transition | Out-Null;Assert-WsmSettingTransitionIntent $Transition $Intent $TargetFingerprint
    if($JournalHash -notmatch '^[A-Fa-f0-9]{64}$'){throw 'Durable operation journal hash is required before setting writes.'}
    if($Transition.Action -in @('KeepTarget','VerifyExternal')){$readback=Get-WsmSettingNativeSnapshot $Transition;if(-not (Test-WsmSettingStateEqual $readback $Transition.After $Transition.Adapter)){throw 'Read-only target verification failed.'};$receipt=[pscustomobject][ordered]@{Kind='SettingTransitionReceipt';Status='Verified';Action=$Transition.Action;TransitionHash=$Transition.TransitionHash;IntentId=$Intent.IntentId;JournalHash=$JournalHash.ToLowerInvariant();TargetFingerprint=$Intent.TargetFingerprint;CreatedByTool=$false;UpdatedByTool=$false;Before=$readback;After=$readback;ReadbackUtc=(Get-WsmUtc);ReceiptHash=('0'*64)};$receipt.ReceiptHash=Get-WsmSettingTransitionReceiptHash $receipt;return $receipt}
    if($Transition.Action -notin @('CreateNew','UpdateReviewed')){throw 'Unsupported setting write action.'}
    $before=Get-WsmSettingNativeSnapshot $Transition;if(-not (Test-WsmSettingStateEqual $before $Transition.Before $Transition.Adapter)){throw 'Target setting drifted after the reviewed transition intent; no write performed.'}
    Set-WsmSettingNativeState $Transition $Transition.After
    $after=Get-WsmSettingNativeSnapshot $Transition;if(-not (Test-WsmSettingStateEqual $after $Transition.After $Transition.Adapter)){throw 'Setting write completed without exact native readback; preserve intent and reconcile.'}
    $receipt=[pscustomobject][ordered]@{Kind='SettingTransitionReceipt';Status='Applied';Action=$Transition.Action;TransitionHash=$Transition.TransitionHash;IntentId=$Intent.IntentId;JournalHash=$JournalHash.ToLowerInvariant();TargetFingerprint=$Intent.TargetFingerprint;CreatedByTool=($Transition.Action -eq 'CreateNew');UpdatedByTool=($Transition.Action -eq 'UpdateReviewed');Before=$before;After=$after;ReadbackUtc=(Get-WsmUtc);ReceiptHash=('0'*64)};$receipt.ReceiptHash=Get-WsmSettingTransitionReceiptHash $receipt;$receipt
}

function Invoke-WsmSettingTransitionRollback {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Transition,[Parameter(Mandatory)]$Intent,[Parameter(Mandatory)]$Receipt,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$TargetFingerprint,[Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$RollbackJournalHash)
    Assert-WsmSettingTransition $Transition | Out-Null;Assert-WsmSettingTransitionIntent $Transition $Intent $TargetFingerprint
    if($Receipt.Kind -cne 'SettingTransitionReceipt' -or $Receipt.Status -notin @('Applied','RecoveredApplied') -or $Receipt.TransitionHash -ine $Transition.TransitionHash -or $Receipt.IntentId -cne $Intent.IntentId -or $Receipt.TargetFingerprint -ine $TargetFingerprint -or $Receipt.Action -cne $Transition.Action -or $Receipt.JournalHash -notmatch '^[A-Fa-f0-9]{64}$' -or (Get-WsmSettingTransitionReceiptHash $Receipt) -ine [string]$Receipt.ReceiptHash){throw 'Setting rollback receipt or durable rollback journal binding mismatch.'}
    $shouldCreate=($Transition.Action -eq 'CreateNew');$shouldUpdate=($Transition.Action -eq 'UpdateReviewed')
    if(-not $shouldCreate -and -not $shouldUpdate -or [bool]$Receipt.CreatedByTool -ne $shouldCreate -or [bool]$Receipt.UpdatedByTool -ne $shouldUpdate -or -not (Test-WsmSettingStateEqual $Receipt.After $Transition.After $Transition.Adapter) -or -not (Test-WsmSettingStateEqual $Receipt.Before $Intent.Prior $Transition.Adapter)){throw 'Setting receipt does not match the reviewed transition and captured prior state.'}
    if($Receipt.Action -in @('KeepTarget','VerifyExternal') -or (-not $Receipt.CreatedByTool -and -not $Receipt.UpdatedByTool)){throw 'Read-only external settings have no tool rollback ownership.'}
    $current=Get-WsmSettingNativeSnapshot $Transition;if(-not (Test-WsmSettingStateEqual $current $Receipt.After $Transition.Adapter)){throw 'Setting drifted after tool application; rollback refused and current value preserved.'}
    $prior=$Intent.Prior
    if($Transition.Action -eq 'CreateNew' -and $Transition.Adapter -ne 'MachineEnvironment'){throw 'Only CreateNew machine environment values can be removed.'}
    Set-WsmSettingNativeState $Transition $prior
    $readback=Get-WsmSettingNativeSnapshot $Transition;if(-not (Test-WsmSettingStateEqual $readback $prior $Transition.Adapter)){throw 'Prior setting readback failed; retain rollback intent for recovery.'}
    [pscustomobject]@{Kind='SettingTransitionRollbackReceipt';Status='RestoredPriorValue';TransitionHash=$Transition.TransitionHash;IntentId=$Intent.IntentId;RollbackJournalHash=$RollbackJournalHash.ToLowerInvariant();TargetFingerprint=$Intent.TargetFingerprint;Restored=$readback;ReadbackUtc=(Get-WsmUtc)}
}

function Get-WsmSettingEffectivePolicySnapshot {
    [CmdletBinding()]
    param()
    $rows=New-Object System.Collections.Generic.List[object]
    foreach($query in @(
        [pscustomobject]@{Name='W32Time';Command='w32tm';Arguments=@('/query','/configuration');EvidenceKind='W32TimeConfiguration'},
        [pscustomobject]@{Name='SMB';Command='Get-SmbClientConfiguration';Arguments=@();EvidenceKind='SMBClientEffective'},
        [pscustomobject]@{Name='SMBServer';Command='Get-SmbServerConfiguration';Arguments=@();EvidenceKind='SMBServerEffective'},
        [pscustomobject]@{Name='LongPaths';Command='Registry';Arguments=@();EvidenceKind='LongPathsEnabled'},
        [pscustomobject]@{Name='TLS';Command='Registry';Arguments=@();EvidenceKind='SchannelProtocolPolicy'},
        [pscustomobject]@{Name='NTLM';Command='Registry';Arguments=@();EvidenceKind='LsaNtlmPolicy'},
        [pscustomobject]@{Name='TimeZone';Command='Registry';Arguments=@();EvidenceKind='TimeZoneAndDST'},
        [pscustomobject]@{Name='FileSystems';Command='Volumes';Arguments=@();EvidenceKind='LocalVolumeFilesystem'},
        [pscustomobject]@{Name='Reboot';Command='Registry';Arguments=@();EvidenceKind='PendingRestartMarkers'},
        [pscustomobject]@{Name='EffectivePolicy';Command='Unknown';Arguments=@();EvidenceKind='EffectiveGpoAndSecurityPolicy';Requirements='Effective GPO/security-policy results are not inferred from local registry values.'},
        [pscustomobject]@{Name='ServiceAccountRights';Command='Unknown';Arguments=@();EvidenceKind='BusinessAccountRights';Requirements='Runtime account identity, logon-right policy, and service/task identity mapping require owner-qualified context.'},
        [pscustomobject]@{Name='OracleOsSupport';Command='Unknown';Arguments=@();EvidenceKind='OracleProviderOsMatrix';Requirements='Oracle OS/provider support requires selected product, provider version, process architecture, and vendor compatibility evidence.'}
    )){
        if($query.Command -eq 'Unknown'){$rows.Add([pscustomobject]@{Name=$query.Name;Status='NotTested';EvidenceKind=$query.EvidenceKind;Value=[pscustomobject]@{Assessment='Unknown';Requirements=$query.Requirements};ObservedUtc=(Get-WsmUtc);ErrorKind='NoQualifiedCollector';Mutation='None'});continue}
        try {
            switch($query.Command){
                w32tm {$cmd=Get-Command w32tm.exe -ErrorAction SilentlyContinue;if(-not $cmd){throw 'NotInstalled'};$result=& $cmd.Source @($query.Arguments) 2>$null;if($LASTEXITCODE -ne 0){throw ('NativeExitCode:'+ $LASTEXITCODE)};$value=(@($result) -join "`n");$status='Success'}
                Get-SmbClientConfiguration {$cmd=Get-Command Get-SmbClientConfiguration -ErrorAction SilentlyContinue;if(-not $cmd){throw 'NotInstalled'};$value=Get-SmbClientConfiguration -ErrorAction Stop | Select-Object RequireSecuritySignature,EnableSecuritySignature,EnableSMB1Protocol,EnableSMB2Protocol;$status='Success'}
                Get-SmbServerConfiguration {$cmd=Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue;if(-not $cmd){throw 'NotInstalled'};$value=Get-SmbServerConfiguration -ErrorAction Stop | Select-Object RequireSecuritySignature,EnableSecuritySignature,EnableSMB1Protocol,EnableSMB2Protocol;$status='Success'}
                Volumes {$value=@([IO.DriveInfo]::GetDrives() | Where-Object IsReady | ForEach-Object {[pscustomobject]@{Name=$_.Name;DriveType=$_.DriveType.ToString();FileSystem=$_.DriveFormat;TotalSize=$_.TotalSize;AvailableFreeSpace=$_.AvailableFreeSpace}});$status='Success'}
                Registry {
                    switch($query.EvidenceKind){
                        LongPathsEnabled {$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\FileSystem',$false);if(-not $key){throw 'KeyUnavailable'};try{$exists=$key.GetValueNames() -contains 'LongPathsEnabled';$value=[pscustomobject]@{Exists=$exists;Value=$(if($exists){$key.GetValue('LongPathsEnabled',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}else{$null});ValueKind=$(if($exists){$key.GetValueKind('LongPathsEnabled').ToString()}else{'None'})}}finally{$key.Dispose()};$status='Success'}
                        TimeZoneAndDST {$value=Get-WsmSettingTimeZoneSnapshot;$status='Success'}
                        SchannelProtocolPolicy {$base='SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols';$protocols=New-Object System.Collections.Generic.List[object];foreach($proto in @('TLS 1.0','TLS 1.1','TLS 1.2','TLS 1.3')){foreach($role in @('Client','Server')){$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(($base+'\'+$proto+'\'+$role),$false);if($key){try{$protocols.Add([pscustomobject]@{Protocol=$proto;Role=$role;Exists=$true;Enabled=$key.GetValue('Enabled',$null);EnabledKind=$(if($key.GetValueNames() -contains 'Enabled'){$key.GetValueKind('Enabled').ToString()}else{'None'});DisabledByDefault=$key.GetValue('DisabledByDefault',$null);DisabledByDefaultKind=$(if($key.GetValueNames() -contains 'DisabledByDefault'){$key.GetValueKind('DisabledByDefault').ToString()}else{'None'});Source='LocalRegistry';Status='Success'})}finally{$key.Dispose()}}else{$protocols.Add([pscustomobject]@{Protocol=$proto;Role=$role;Exists=$false;Enabled=$null;EnabledKind='None';DisabledByDefault=$null;DisabledByDefaultKind='None';Source='Unknown';Status='Unknown'})}}};$value=@($protocols.ToArray());$status=$(if(@($protocols | Where-Object Status -EQ 'Unknown').Count){'Partial'}else{'Success'})}
                        LsaNtlmPolicy {$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Lsa',$false);if(-not $key){throw 'KeyUnavailable'};try{$value=[pscustomobject]@{LmCompatibilityLevel=$key.GetValue('LmCompatibilityLevel',$null);LmCompatibilityLevelKind=$(if($key.GetValueNames() -contains 'LmCompatibilityLevel'){$key.GetValueKind('LmCompatibilityLevel').ToString()}else{'None'});RestrictSendingNTLMTraffic=$key.GetValue('RestrictSendingNTLMTraffic',$null);RestrictSendingNTLMTrafficKind=$(if($key.GetValueNames() -contains 'RestrictSendingNTLMTraffic'){$key.GetValueKind('RestrictSendingNTLMTraffic').ToString()}else{'None'});Source='LocalRegistry';EffectivePolicyStatus='Unknown'}}finally{$key.Dispose()};$status='Success'}
                        PendingRestartMarkers {$cbs=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',$false);$wu=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',$false);$session=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager',$false);try{$pendingRename=$false;if($session){$pendingRename=$session.GetValueNames() -contains 'PendingFileRenameOperations'};$value=[pscustomobject]@{CbsRebootPending=($null -ne $cbs);WindowsUpdateRebootRequired=($null -ne $wu);PendingFileRenameOperations=$pendingRename;EffectiveRebootRequired='Unknown'}}finally{if($cbs){$cbs.Dispose()};if($wu){$wu.Dispose()};if($session){$session.Dispose()}};$status='Success'}
                    }
                }
            }
            $rows.Add([pscustomobject]@{Name=$query.Name;Status=$status;EvidenceKind=$query.EvidenceKind;Value=$value;ObservedUtc=(Get-WsmUtc);Mutation='None'})
        } catch {$status='Unknown';$kind=$_.Exception.GetType().FullName;if([string]$_.Exception.Message -eq 'NotInstalled'){$status='NotInstalled';$kind='CommandUnavailable'}elseif([string]$_.Exception.Message -match 'NativeExitCode:-2147024891'){$status='PermissionDenied';$kind='AccessDenied'};$rows.Add([pscustomobject]@{Name=$query.Name;Status=$status;EvidenceKind=$query.EvidenceKind;Value=$null;ObservedUtc=(Get-WsmUtc);ErrorKind=$kind;Mutation='None'})}
    }
    @($rows.ToArray())
}
