#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$transitionPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\SettingTransitions.ps1'))
$recoveryPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\Recovery.ps1'))
& $module {
    param($transitionPath,$recoveryPath)
    . $transitionPath
    . $recoveryPath
    $script:recoverySettingState=$null
    $script:recoverySettingEvents=New-Object 'System.Collections.Generic.List[object]'
    Set-Item Function:\Get-WsmSettingNativeSnapshot -Value {param($Transition)$script:recoverySettingState}
    Set-Item Function:\Get-WsmSettingTimeZoneSnapshot -Value {$script:recoverySettingState}
    Set-Item Function:\Set-WsmSettingNativeState -Value {param($Transition,$State)$script:recoverySettingEvents.Add([pscustomobject]@{Kind='NativeWrite';State=$State});$script:recoverySettingState=$State}
    Set-Item Function:\Remove-WsmCreatedAdapter -Value {throw 'Generic adapter removal must not be used for a setting transition.'}
    Set-Item Function:\Add-WsmJournal -Value {param($Paths,$State,[string]$Action,[string]$ItemId,$Detail)$script:recoverySettingEvents.Add([pscustomobject]@{Kind='Journal';Action=$Action;Detail=$Detail});$State.Sequence++;$State.JournalHash=Get-WsmHashText ($Action+'|'+$ItemId+'|'+$State.Sequence)}
    Set-Item Function:\Test-WsmMigrationPackage -Value {param($ManifestPath,$ExpectedHash)$script:repairPackage}
    Set-Item Function:\Get-WsmOperationPaths -Value {param($StateDirectory,$PairId)[pscustomobject]@{Root='fixture-root';State='fixture-state';Journal='fixture-journal'}}
    Set-Item Function:\Get-WsmOperationState -Value {param($Paths,$Package,[switch]$AllowRecovery)$script:repairState}
    Set-Item Function:\Test-WsmJournal -Value {param($StateDirectory,$PairId)[pscustomobject]@{Consistent=$true}}
    Set-Item Function:\Invoke-WsmLocked -Value {param($Root,$Action)& $Action}
    Set-Item Function:\Assert-WsmMigrationHost -Value {param($Identity,$Fingerprint)}
    Set-Item Function:\Get-WsmMachineIdentity -Value {[pscustomobject]@{Fingerprint=('f'*64)}}
    function script:New-WsmRecoveryState([bool]$Exists,[AllowNull()]$Value,[string]$ValueKind){[pscustomobject][ordered]@{Exists=$Exists;Value=$Value;ValueKind=$ValueKind}}
    $target=('a'*64);$manifest=('d'*64);$journal=('e'*64)
    $before=New-WsmRecoveryState $true 'C:\Oracle\prior' 'ExpandString'
    $after=New-WsmRecoveryState $true 'C:\Oracle\reviewed' 'String'
    $transition=New-WsmSettingTransition -Adapter MachineEnvironment -Action UpdateReviewed -Name TNS_ADMIN -Before $before -After $after -Owner 'database-owner' -Evidence 'approved-change:42' -OwnerReviewHash ('b'*64)
    $spec=[pscustomobject]@{Adapter='MachineEnvironment';Owner='database-owner';Evidence='approved-change:42';Desired=[pscustomobject]@{Name='TNS_ADMIN';Value='C:\Oracle\reviewed'};SettingTransition=$transition}
    $item=[pscustomobject]@{ItemId='setting-item-1';MigrationSpec=$spec}

    # Crash after a native write but before receipt persistence: recovery recognizes
    # the exact reviewed after state and creates a durable recovered receipt.
    $script:recoverySettingEvents.Clear();$script:recoverySettingState=$before
    $intent=Get-WsmSettingTransitionIntent $transition $target
    $script:recoverySettingState=$after
    $pending=[pscustomobject]@{ItemId=$item.ItemId;Phase='SettingTransition';ManifestHash=$manifest;TransitionHash=$transition.TransitionHash;Transition=$transition;Intent=$intent;Receipt=$null;RequiredPhase='StagedDependencyVerified'}
    $state=[pscustomobject]@{TargetFingerprint=$target;Items=@();PendingOperations=@($pending);Sequence=1;JournalHash=$journal;Stage='Running'}
    Complete-WsmSettingTransitionRecovery $item $pending ([pscustomobject]@{}) $state
    $recovered=@($state.Items | Where-Object ItemId -CEQ $item.ItemId)[0]
    if($recovered.CreatedByTool -or -not $recovered.UpdatedByTool -or $recovered.SettingTransitionReceipt.Status -cne 'RecoveredApplied' -or $state.PendingOperations.Count -ne 0 -or $script:recoverySettingEvents.Count -ne 2){throw 'Interrupted setting apply did not recover and journal its exact receipt.'}
    if($script:recoverySettingEvents[0].Action -cne 'SettingTransitionReceipt' -or $script:recoverySettingEvents[1].Action -cne 'SettingTransitionRecovered'){throw 'Setting recovery journal events were out of order.'}

    # A durable pending intent with the exact prior state safely replays the same
    # authorized transition, with the intent already durable before its write.
    $script:recoverySettingEvents.Clear();$script:recoverySettingState=$before
    $pending=[pscustomobject]@{ItemId=$item.ItemId;Phase='SettingTransition';ManifestHash=$manifest;TransitionHash=$transition.TransitionHash;Transition=$transition;Intent=$intent;Receipt=$null;RequiredPhase='StagedDependencyVerified'}
    $state=[pscustomobject]@{TargetFingerprint=$target;Items=@();PendingOperations=@($pending);Sequence=1;JournalHash=$journal;Stage='Running'}
    Complete-WsmSettingTransitionRecovery $item $pending ([pscustomobject]@{}) $state
    if($script:recoverySettingEvents[0].Kind -cne 'NativeWrite' -or $script:recoverySettingState.Value -cne $after.Value){throw 'Exact-prior crash replay did not apply the reviewed transition.'}

    # Neither prior nor after is adopted; drift fails closed without a write.
    $script:recoverySettingEvents.Clear();$script:recoverySettingState=New-WsmRecoveryState $true 'C:\Oracle\unexpected' 'String'
    $pending=[pscustomobject]@{ItemId=$item.ItemId;Phase='SettingTransition';ManifestHash=$manifest;TransitionHash=$transition.TransitionHash;Transition=$transition;Intent=$intent;Receipt=$null;RequiredPhase='StagedDependencyVerified'}
    $state=[pscustomobject]@{TargetFingerprint=$target;Items=@();PendingOperations=@($pending);Sequence=1;JournalHash=$journal;Stage='Running'}
    $blocked=$false;try{Complete-WsmSettingTransitionRecovery $item $pending ([pscustomobject]@{}) $state}catch{$blocked=$true}
    if(-not $blocked -or $script:recoverySettingEvents.Count){throw 'Setting recovery overwrote an unrelated drifted value.'}

    # Exercise the public repair flow with a fixed package/state boundary so its
    # real pending-operation branch, journal sequencing, and plan binding run.
    $script:recoverySettingEvents.Clear();$script:recoverySettingState=$before
    $repairIntent=Get-WsmSettingTransitionIntent $transition $target
    $script:recoverySettingState=$after
    $repairPending=[pscustomobject]@{ItemId=$item.ItemId;Phase='SettingTransition';ManifestHash=$manifest;TransitionHash=$transition.TransitionHash;Transition=$transition;Intent=$repairIntent;Receipt=$null;RequiredPhase='StagedDependencyVerified'}
    $script:repairPackage=[pscustomobject]@{SHA256=$manifest;Manifest=[pscustomobject]@{PairId='pair-fixture';Target=[pscustomobject]@{Fingerprint=$target}};Plan=[pscustomobject]@{Items=@($item)}}
    $script:repairState=[pscustomobject]@{PairId='pair-fixture';TargetFingerprint=$target;ManifestHash='';Cutover=$null;PendingOperations=@($repairPending);Items=@();Sequence=1;JournalHash=$journal;Stage='Running'}
    $repair=Repair-WsmOperation -ManifestPath 'fixture-manifest' -ExpectedHash $manifest -StateDirectory 'fixture-state' -Confirm:$false
    if($repair.Repaired -notcontains $item.ItemId -or $repair.Remaining -ne 0 -or -not $repair.State.Items[0].SettingTransitionReceipt){throw 'Repair-WsmOperation did not reconcile a durable transition intent and persist its receipt.'}
    # Public rollback must select reviewed updates even though it did not create
    # the existing environment variable. Exercise selection, preview and apply.
    $item | Add-Member NoteProperty Decision Include
    Set-Item Function:\Get-WsmAdapterState -Value {param($Spec)$script:recoverySettingState}
    Set-Item Function:\Test-WsmAdapterConfiguration -Value {param($Spec,$Phase,$Receipts)[pscustomobject]@{Passed=$true}}
    Set-Item Function:\Get-WsmRestoreOrder -Value {param($Items)$Items}
    $publicPreview=Get-WsmRollbackPreview 'fixture-manifest' $manifest 'fixture-state'
    if($publicPreview.Rows.Count -ne 1 -or $publicPreview.Rows[0].Action -cne 'RestoreReviewedPriorSetting'){throw 'Reviewed existing setting was omitted from public rollback preview.'}
    $publicRollback=Invoke-WsmRollback 'fixture-manifest' $manifest 'fixture-state' $publicPreview.PreviewHash 'ROLLBACK pair-fixture' -Confirm:$false
    if($publicRollback.Stage -cne 'RolledBack' -or -not (Test-WsmSettingStateEqual $script:recoverySettingState $before MachineEnvironment)){throw 'Public rollback failed to restore reviewed existing setting.'}

    # UpdateReviewed rollback restores the original exact value type and value.
    $script:recoverySettingEvents.Clear();$script:recoverySettingState=$before
    $intent=Get-WsmSettingTransitionIntent $transition $target
    $script:recoverySettingState=$before
    $intent=Get-WsmSettingTransitionIntent $transition $target
    $script:recoverySettingState=$before
    $receipt=[pscustomobject]@{Kind='SettingTransitionReceipt';Status='RecoveredApplied';Action='UpdateReviewed';TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId;JournalHash=$journal;TargetFingerprint=$target;CreatedByTool=$false;UpdatedByTool=$true;Before=$before;After=$after;ReadbackUtc=(Get-WsmUtc);ReceiptHash=('0'*64)}
    $receipt.ReceiptHash=Get-WsmSettingTransitionReceiptHash $receipt;$receipt | Add-Member NoteProperty Intent $intent -Force
    $record=[pscustomobject]@{ItemId=$item.ItemId;Status='Succeeded';CreatedByTool=$false;UpdatedByTool=$true;SettingTransitionIntent=$intent;SettingTransitionReceipt=$receipt}
    $rollbackIntent=[pscustomobject]@{TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId;TargetFingerprint=$target;ExpectedCurrent=$after;RestorePrior=$before;ReceiptHash=$receipt.ReceiptHash;ManifestHash=$manifest}
    $operation=[pscustomobject]@{ItemId=$item.ItemId;Phase='RollbackAdapter';ManifestHash=$manifest;Adapter='MachineEnvironment';SpecHash=(Get-WsmHashText ($spec | ConvertTo-Json -Depth 40 -Compress));TransitionHash=$transition.TransitionHash;SettingTransitionIntent=$intent;SettingTransitionReceipt=$receipt;SettingTransitionRollbackIntent=$rollbackIntent}
    $state=[pscustomobject]@{TargetFingerprint=$target;Items=@($record);PendingOperations=@($operation);Sequence=1;JournalHash=$journal;Stage='RollbackRunning'}
    $script:recoverySettingState=$after
    Complete-WsmAdapterRollback $item $operation ([pscustomobject]@{}) $state
    if(-not (Test-WsmSettingStateEqual $script:recoverySettingState $before 'MachineEnvironment') -or $record.Status -ne 'RolledBack' -or $record.CreatedByTool -or $state.PendingOperations.Count){throw 'Setting rollback did not restore exact prior state through journaled transition logic.'}
    $writeIndex=@($script:recoverySettingEvents | ForEach-Object {$_.Kind}).IndexOf('NativeWrite')
    $intentIndex=@($script:recoverySettingEvents | Where-Object Kind -EQ 'Journal' | ForEach-Object {$_.Action}).IndexOf('SettingTransitionRollbackIntent')
    if($intentIndex -lt 0 -or $writeIndex -le $intentIndex){throw 'Setting rollback wrote before its durable rollback intent.'}

    # If rollback itself stopped after restoring prior state, recovery records the
    # exact prior readback without writing it again.
    $script:recoverySettingEvents.Clear();$record.Status='Succeeded';$record.CreatedByTool=$true
    $state.PendingOperations=@($operation);$state.Sequence=1;$state.JournalHash=$journal;$state.Stage='RollbackRunning';$script:recoverySettingState=$before
    Complete-WsmAdapterRollback $item $operation ([pscustomobject]@{}) $state
    if(@($script:recoverySettingEvents | Where-Object Kind -EQ 'NativeWrite').Count -or $record.Status -ne 'RolledBack'){throw 'Interrupted rollback prior-state recovery performed another native write.'}

    # The same recovery path restores the previous time zone and DST flag; it
    # never calls the generic created-object removal adapter.
    $dstBefore=[pscustomobject][ordered]@{Exists=$true;Value=$false;ValueKind='DWord'};$dstAfter=[pscustomobject][ordered]@{Exists=$true;Value=$true;ValueKind='DWord'}
    $zoneBefore=[pscustomobject][ordered]@{Exists=$true;Value='UTC';ValueKind='TimeZoneId';DaylightSaving=$dstBefore};$zoneAfter=[pscustomobject][ordered]@{Exists=$true;Value='Pacific Standard Time';ValueKind='TimeZoneId';DaylightSaving=$dstAfter}
    $zoneTransition=New-WsmSettingTransition -Adapter TimeZone -Action UpdateReviewed -Name TimeZone -Before $zoneBefore -After $zoneAfter -Owner 'time-owner' -Evidence 'approved-zone-change' -OwnerReviewHash ('9'*64)
    $zoneSpec=[pscustomobject]@{Adapter='TimeZone';Owner='time-owner';Evidence='approved-zone-change';Desired=[pscustomobject]@{Name='TimeZone';Value='Pacific Standard Time'};SettingTransition=$zoneTransition}
    $zoneItem=[pscustomobject]@{ItemId='timezone-item';MigrationSpec=$zoneSpec};$zoneTarget=('7'*64);$script:recoverySettingState=$zoneBefore;$zoneIntent=Get-WsmSettingTransitionIntent $zoneTransition $zoneTarget
    $script:recoverySettingState=$zoneAfter;$zoneReceipt=New-WsmSettingTransitionRecoveredReceipt $zoneTransition $zoneIntent $zoneTarget $journal
    $zoneRecord=[pscustomobject]@{ItemId=$zoneItem.ItemId;Status='Succeeded';CreatedByTool=$false;UpdatedByTool=$true;SettingTransitionIntent=$zoneIntent;SettingTransitionReceipt=$zoneReceipt}
    $zoneRollbackIntent=[pscustomobject]@{TransitionHash=$zoneTransition.TransitionHash;IntentId=$zoneIntent.IntentId;TargetFingerprint=$zoneTarget;ExpectedCurrent=$zoneAfter;RestorePrior=$zoneBefore;ReceiptHash=$zoneReceipt.ReceiptHash;ManifestHash=$manifest}
    $zoneOperation=[pscustomobject]@{ItemId=$zoneItem.ItemId;Phase='RollbackAdapter';ManifestHash=$manifest;Adapter='TimeZone';SpecHash=(Get-WsmHashText ($zoneSpec | ConvertTo-Json -Depth 40 -Compress));TransitionHash=$zoneTransition.TransitionHash;SettingTransitionIntent=$zoneIntent;SettingTransitionReceipt=$zoneReceipt;SettingTransitionRollbackIntent=$zoneRollbackIntent}
    $zoneState=[pscustomobject]@{TargetFingerprint=$zoneTarget;Items=@($zoneRecord);PendingOperations=@($zoneOperation);Sequence=1;JournalHash=$journal;Stage='RollbackRunning'}
    $script:recoverySettingState=$zoneAfter;$script:recoverySettingEvents.Clear()
    Complete-WsmAdapterRollback $zoneItem $zoneOperation ([pscustomobject]@{}) $zoneState
    if(-not (Test-WsmSettingStateEqual $script:recoverySettingState $zoneBefore 'TimeZone') -or $zoneRecord.Status -ne 'RolledBack'){throw 'TimeZone rollback did not restore the exact prior zone and daylight-saving value.'}

    'Setting transition recovery fixtures passed.'
} $transitionPath $recoveryPath
