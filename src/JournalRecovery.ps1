function Read-WsmJournalEvents($Paths) {
    $archives=@(Get-ChildItem -LiteralPath $Paths.Root -Filter 'journal-*.jsonl' | Sort-Object {[int]([regex]::Match($_.Name,'\d+').Value)})
    foreach($path in @($archives | ForEach-Object FullName)+@($Paths.Journal)){
        if(-not $path -or -not [IO.File]::Exists($path)){continue};Assert-WsmNoReparse $path
        $stream=[IO.File]::Open($path,'Open','Read','Read');$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try{Read-WsmBoundedLines $reader | ForEach-Object {[pscustomobject]@{Row=(ConvertFrom-WsmJson $_);Hash=(Get-WsmHashText $_)}}}finally{$reader.Dispose();$stream.Dispose()}
    }
}
function Assert-WsmTaskFolderReplayDetail($Detail,$Pending,[string]$ItemId,[string]$Phase) {
    Assert-WsmFields $Detail @('ItemId','Adapter','ManifestHash','Phase','Intent','Receipt') @('ItemId','Adapter','ManifestHash','Phase')
    if($Detail.ItemId -cne $ItemId -or $Pending.ItemId -cne $ItemId -or $Detail.Adapter -cne 'ScheduledTask' -or $Pending.Adapter -cne 'ScheduledTask' -or $Detail.Phase -cne $Phase -or [string]$Detail.ManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or $Detail.ManifestHash -ine $Pending.ManifestHash){throw 'Task folder journal detail does not bind its item, adapter, phase and manifest intent.'}
}
function Assert-WsmTaskFolderReplayIntent($Intent,[string]$Kind) {
    if($Intent.Kind -cne $Kind){throw 'Task folder journal intent kind mismatch.'};Assert-WsmId $Intent.OperationId
    $path=ConvertTo-WsmTaskSecurityFolderPath ([string]$Intent.Path)
    if($Intent.Path -cne $path -or [string]$Intent.SecurityHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Task folder journal intent path or descriptor hash is invalid.'}
    if($Kind -ceq 'TaskFolderCreateIntent' -and (Get-WsmTaskSecurityDescriptorHash ([string]$Intent.SecuritySddl)) -ine $Intent.SecurityHash){throw 'Task folder creation intent descriptor differs from its hash.'}
}
function Assert-WsmTaskFolderReplayReceipt($Receipt,$Intent) {
    $path=ConvertTo-WsmTaskSecurityFolderPath ([string]$Intent.Path)
    Get-WsmTaskSecurityReceiptMap @($Receipt) @([pscustomobject]@{Path=$path;SecurityHash=$Intent.SecurityHash}) | Out-Null
    if($Receipt.OperationId -cne $Intent.OperationId -or $Receipt.Path -cne $Intent.Path -or $Receipt.SecurityHash -ine $Intent.SecurityHash){throw 'Task folder journal receipt does not bind the exact creation/deletion intent.'}
}
function Get-WsmReplayChallenge($State,[string]$Action) {
    if(-not $State.PSObject.Properties['AssistiveServiceChallenge'] -or -not $State.AssistiveServiceChallenge){throw ('Journal replay of '+$Action+' found no durable Service credential challenge; retain evidence and recover manually.')}
    $State.AssistiveServiceChallenge
}
function Get-WsmReplayAttempt($State,[string]$Action,[string]$ParentOperationId='') {
    if(-not $State.PSObject.Properties['RestoreAttempt'] -or -not $State.RestoreAttempt){throw ('Journal replay of '+$Action+' found no durable TargetRestore attempt; retain evidence and recover manually.')}
    if($ParentOperationId -and [string]$State.RestoreAttempt.OperationId -cne $ParentOperationId){throw ('Journal replay of '+$Action+' does not match the durable TargetRestore parent; retain evidence and recover manually.')}
    $State.RestoreAttempt
}
function Get-WsmReplayPending($State,[string]$ItemId,[string]$Action) {
    $pending=@($State.PendingOperations | Where-Object ItemId -CEQ $ItemId)
    if($pending.Count -ne 1){throw ('Journal replay of '+$Action+' has no unique durable pending operation for its item; retain evidence and recover manually.')}
    $pending[0]
}
function Set-WsmReplayParentTerminal($State,$Detail,[string]$Mode,[string]$Utc) {
    # Mirrors Revoke-WsmWizardTargetRestoreParent (Superseded) and Stop-WsmWizardTargetRestoreParent (Cancelled).
    $attempt=Get-WsmReplayAttempt $State ('Assistive parent '+$Mode) ([string]$Detail.ParentOperationId)
    if($State.PSObject.Properties['AssistiveServiceChallenge'] -and $State.AssistiveServiceChallenge -and [string]$State.AssistiveServiceChallenge.State -cin @('WaitingForInput','Running')){
        $challenge=$State.AssistiveServiceChallenge
        if($Mode -ceq 'Superseded'){$challenge.State='Revoked';$challenge | Add-Member NoteProperty RevokeReason ([string]$Detail.Reason) -Force}
        else{$challenge.State='Cancelled';$challenge | Add-Member NoteProperty CancelReason 'Operator cancelled interrupted TargetRestore parent' -Force}
        $challenge.UpdatedUtc=$Utc
    }
    $attempt | Add-Member NoteProperty Status $Mode -Force
    if($Mode -ceq 'Superseded'){$attempt | Add-Member NoteProperty SupersededUtc $Utc -Force}else{$attempt | Add-Member NoteProperty CancelledUtc $Utc -Force}
    $State.Stage=$Mode
}
function Set-WsmReplayChallengeWaiting($State,$Detail,[string]$Utc) {
    # Mirrors the AssistiveServiceCredentialChallengeRebound write: pre-write recovery returns the same parent to a fresh Target session.
    $challenge=Get-WsmReplayChallenge $State 'AssistiveServiceCredentialChallengeRebound'
    $attempt=Get-WsmReplayAttempt $State 'AssistiveServiceCredentialChallengeRebound' ([string]$Detail.ParentOperationId)
    $challenge.State='WaitingForInput';$challenge.Actor=[string]$Detail.Actor;$challenge.Role='Target';$challenge.SessionId=[string]$Detail.SessionId;$challenge.ContextId=[string]$Detail.ContextId;$challenge.Revision=[int]$Detail.Revision;$challenge.UpdatedUtc=$Utc
    $challenge | Add-Member NoteProperty LastPreWriteRecovery $Detail.PreWriteRecovery -Force
    $attempt | Add-Member NoteProperty Status 'WaitingForInput' -Force;$State.Stage='WaitingForInput'
}
function Set-WsmReplayAssistivePartialFile($State,[string]$ItemId,$Record) {
    # Mirrors Set-WsmAssistivePartialOwnership for a completed file; no parent attempt means the original wrote nothing.
    if(-not $State.PSObject.Properties['RestoreAttempt'] -or -not $State.RestoreAttempt -or -not [string]$State.RestoreAttempt.OperationId){return}
    $attempt=$State.RestoreAttempt
    $kept=@();if($State.PSObject.Properties['AssistivePartialOwnership']){$kept=@($State.AssistivePartialOwnership | Where-Object {$_ -and -not ([string]$_.ItemId -ceq $ItemId -and [string]$_.Kind -ceq 'File' -and [string]$_.RelativePath -ceq [string]$Record.RelativePath)})}
    $entry=[pscustomobject][ordered]@{ItemId=$ItemId;Kind='File';RelativePath=[string]$Record.RelativePath;ParentOperationId=[string]$attempt.OperationId;ManifestHash=[string]$attempt.ManifestHash;Generation=[long]$attempt.Generation;Record=$Record}
    $State | Add-Member NoteProperty AssistivePartialOwnership (@($kept)+@($entry)) -Force
}
function Clear-WsmReplayAssistivePartial($State,[string]$ItemId) {
    if($State.PSObject.Properties['AssistivePartialOwnership']){$State.AssistivePartialOwnership=@($State.AssistivePartialOwnership | Where-Object {$_ -and [string]$_.ItemId -cne $ItemId})}
}
function Set-WsmReplayCredentialWaitingSnapshot($State,$Detail,[string]$Action,[bool]$WithAttempt) {
    # Rejected / Reprompt / RejectedLimit rows carry the exact non-secret challenge (and attempt) as written; older rows without them cannot be rebuilt safely.
    if(-not $Detail.PSObject.Properties['ChallengeSnapshot'] -or -not $Detail.ChallengeSnapshot -or ($WithAttempt -and (-not $Detail.PSObject.Properties['RestoreAttempt'] -or -not $Detail.RestoreAttempt))){throw ('Journal replay of '+$Action+' lacks the durable challenge/attempt snapshot written by this version; retain evidence and recover manually.')}
    $State | Add-Member NoteProperty AssistiveServiceChallenge $Detail.ChallengeSnapshot -Force
    if($WithAttempt){$State | Add-Member NoteProperty RestoreAttempt $Detail.RestoreAttempt -Force;$State.ManifestHash=$Detail.RestoreAttempt.ManifestHash;$State.Generation=$Detail.RestoreAttempt.Generation;$State.Stage='WaitingForInput'}
}
function Restore-WsmJournalCheckpoint($Paths,$State) {
    # Always replay from disk's durable checkpoint. The caller may hold a faulted
    # in-memory object containing changes that never reached state.json.
    $diskState=Read-WsmJson $Paths.State
    if($diskState.PairId -cne $State.PairId -or $diskState.RunId -cne $State.RunId){throw 'Journal recovery state identity differs from the durable checkpoint; retain evidence.'}
    $check=Test-WsmJournal ([IO.Path]::GetDirectoryName($Paths.Root)) $diskState.PairId
    if($check.Consistent){
        foreach($property in $diskState.PSObject.Properties){$State | Add-Member NoteProperty $property.Name $property.Value -Force}
        return
    }
    if($check.RecoverableSegmentMismatch){
        $copy=ConvertFrom-WsmJson ($diskState | ConvertTo-Json -Depth 40)
        $copy.JournalSegment=[long]$check.ArchiveCount
        Write-WsmJson $Paths.State $copy
        $verified=Test-WsmJournal ([IO.Path]::GetDirectoryName($Paths.Root)) $copy.PairId
        if(-not $verified.Consistent){throw 'Journal segment repair did not produce a verified durable checkpoint; retain evidence.'}
        foreach($property in $copy.PSObject.Properties){$State | Add-Member NoteProperty $property.Name $property.Value -Force}
        return
    }
    if(-not $check.RecoveryRequired){throw 'Checkpoint is ahead of or differs from durable journal; retain evidence.'}
    $copy=ConvertFrom-WsmJson ($diskState | ConvertTo-Json -Depth 40)
    Read-WsmJournalEvents $Paths | ForEach-Object {$event=$_.Row;$eventHash=$_.Hash;if($event.Sequence -gt $copy.Sequence){$d=$event.Detail;$id=$event.ItemId
        switch -Exact ($event.Action){
            'AssistiveRestoreStarted' {$copy.Stage='Running';$copy | Add-Member NoteProperty RestoreAttempt $d -Force}
            'AssistiveDeltaFallbackDeferred' {$fallbacks=@();if($copy.PSObject.Properties['AssistiveDeltaFallbacks']){$fallbacks=@($copy.AssistiveDeltaFallbacks)};$copy | Add-Member NoteProperty AssistiveDeltaFallbacks (@($fallbacks)+@($d)) -Force}
            'AssistiveAdapterIntent' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            {$_ -in @('AssistiveFileIntent','AssistiveFilePrepared')} {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            'AssistiveFileBackupRetained' {$pending=@($copy.PendingOperations | Where-Object ItemId -CEQ $id);if($pending.Count -ne 1 -or $pending[0].Phase -cne 'AssistiveFileReplace'){throw 'Assistive backup material journal row has no matching file intent.'};$pending[0].Backup=[string]$d.Backup;$pending[0] | Add-Member NoteProperty BackupMaterialId ([string]$d.MaterialId) -Force}
            'AssistiveFileCompleted' {$pending=@($copy.PendingOperations | Where-Object ItemId -CEQ $id);$record=@($copy.Items | Where-Object ItemId -CEQ $id);if($record.Count -eq 0){$record=[pscustomobject]@{ItemId=$id;Status='Partial';CreatedByTool=$true;AppliedManifestHash='';AppliedGeneration=0;OwnedFiles=@();OwnedDirectories=@();Target=''}}else{$record=$record[0]};$files=@($record.OwnedFiles | Where-Object RelativePath -CNE ([string]$d.Record.RelativePath));$files+=,$d.Record;$record.OwnedFiles=$files;$record.Status='Partial';$record.AppliedManifestHash='';$record | Add-Member NoteProperty Error 'One file transaction completed; the full scope still requires reconciliation.' -Force;$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($record);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id);Set-WsmReplayAssistivePartialFile $copy $id $d.Record}
            'AssistiveFileRecovered' {if($d.Record){$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d.Record)};$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'AssistiveAdapterRecovered' {if($d.Status -eq 'RebootRequired'){$copy.Stage='RebootRequired'};$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'AssistiveAdapterAbandoned' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id);$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)}
            {$_ -in @('AssistiveItemCompleted','AssistiveItemFailed')} {if($event.Action -ceq 'AssistiveItemCompleted'){Clear-WsmReplayAssistivePartial $copy $id};$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id);if($d.Status -eq 'Failed'){$copy.Stage='Partial'}}
            'AssistiveItemNeedsRepair' {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@([pscustomobject]@{ItemId=$id;Status='Failed';CreatedByTool=$true;AppliedManifestHash='';AppliedGeneration=0;Error='An Assistive item operation needs explicit recovery.'})}
            'AssistiveRestoreCompleted' {$copy.Stage=$d.Status;$copy.Generation=$d.Generation;$copy.ManifestHash=$d.ManifestHash;if($d.PSObject.Properties['ItemResults'] -and $copy.PSObject.Properties['RestoreAttempt'] -and $copy.RestoreAttempt){$copy.RestoreAttempt | Add-Member NoteProperty ItemResults @($d.ItemResults) -Force};if($copy.PSObject.Properties['AssistiveServiceChallenge'] -and $copy.AssistiveServiceChallenge -and [string]$copy.AssistiveServiceChallenge.State -cin @('WaitingForInput','Running')){$copy.AssistiveServiceChallenge.State='Completed';$copy.AssistiveServiceChallenge.UpdatedUtc=[string]$event.Utc}}
            'AdapterIntent' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            'TaskFolderCreateIntent' {
                $pending=@($copy.PendingOperations | Where-Object ItemId -CEQ $id)
                if($pending.Count -ne 1){throw 'Task folder intent has no unique durable adapter intent.'}
                Assert-WsmTaskFolderReplayDetail $d $pending[0] $id 'TaskFolderCreateIntent'
                Assert-WsmTaskFolderReplayIntent $d.Intent 'TaskFolderCreateIntent'
                if(-not $pending[0].PSObject.Properties['FolderCreateIntents']){$pending[0] | Add-Member NoteProperty FolderCreateIntents @()}
                $pending[0].FolderCreateIntents=@($pending[0].FolderCreateIntents | Where-Object OperationId -CNE $d.Intent.OperationId)+@($d.Intent)
            }
            'TaskFolderOwned' {
                $pending=@($copy.PendingOperations | Where-Object ItemId -CEQ $id)
                if($pending.Count -ne 1){throw 'Task folder receipt has no unique durable adapter intent.'}
                Assert-WsmTaskFolderReplayDetail $d $pending[0] $id 'TaskFolderOwned'
                if(-not $pending[0].PSObject.Properties['FolderCreateIntents'] -or @($pending[0].FolderCreateIntents | Where-Object OperationId -CEQ $d.Receipt.OperationId).Count -ne 1){throw 'Task folder receipt lacks its matching durable creation intent.'}
                $createIntent=@($pending[0].FolderCreateIntents | Where-Object OperationId -CEQ $d.Receipt.OperationId)[0]
                Assert-WsmTaskFolderReplayReceipt $d.Receipt $createIntent
                $pending[0].FolderCreateIntents=@($pending[0].FolderCreateIntents | Where-Object OperationId -CNE $d.Receipt.OperationId)
                if(-not $pending[0].PSObject.Properties['AuxiliaryOwnership']){$pending[0] | Add-Member NoteProperty AuxiliaryOwnership @()}
                $pending[0].AuxiliaryOwnership=@($pending[0].AuxiliaryOwnership | Where-Object OperationId -CNE $d.Receipt.OperationId)+@($d.Receipt)
            }
            'TaskFolderDeleteIntent' {
                $pending=@($copy.PendingOperations | Where-Object ItemId -CEQ $id)
                if($pending.Count -ne 1 -or $pending[0].Phase -cne 'RollbackAdapter'){throw 'Task folder deletion has no unique durable rollback intent.'}
                Assert-WsmTaskFolderReplayDetail $d $pending[0] $id 'TaskFolderDeleteIntent'
                Assert-WsmTaskFolderReplayIntent $d.Intent 'TaskFolderDeleteIntent'
                Assert-WsmTaskFolderReplayReceipt $d.Intent.Receipt $d.Intent
                $owned=@(Get-WsmTaskSecurityOwnershipReceipts $copy | Where-Object {$_.OperationId -ceq $d.Intent.OperationId -and $_.Path -ceq $d.Intent.Path -and $_.SecurityHash -ieq $d.Intent.SecurityHash})
                if($owned.Count -ne 1){throw 'Task folder deletion intent lacks its durable exact ownership receipt.'}
                if(-not $pending[0].PSObject.Properties['FolderDeleteIntents']){$pending[0] | Add-Member NoteProperty FolderDeleteIntents @()}
                $pending[0].FolderDeleteIntents=@($pending[0].FolderDeleteIntents | Where-Object OperationId -CNE $d.Intent.OperationId)+@($d.Intent)
            }
            'TaskFolderDeleted' {
                $pending=@($copy.PendingOperations | Where-Object ItemId -CEQ $id)
                if($pending.Count -ne 1 -or -not $pending[0].PSObject.Properties['FolderDeleteIntents'] -or @($pending[0].FolderDeleteIntents | Where-Object OperationId -CEQ $d.Intent.OperationId).Count -ne 1){throw 'Task folder deletion completion lacks its durable rollback intent.'}
                Assert-WsmTaskFolderReplayDetail $d $pending[0] $id 'TaskFolderDeleted'
                $deleteIntent=@($pending[0].FolderDeleteIntents | Where-Object OperationId -CEQ $d.Intent.OperationId)[0]
                Assert-WsmTaskFolderReplayIntent $d.Intent 'TaskFolderDeleteIntent'
                Assert-WsmTaskFolderReplayReceipt $d.Intent.Receipt $deleteIntent
                if($d.Intent.Path -cne $deleteIntent.Path -or $d.Intent.SecurityHash -ine $deleteIntent.SecurityHash -or (Get-WsmHashText ($d.Intent | ConvertTo-Json -Depth 10 -Compress)) -cne (Get-WsmHashText ($deleteIntent | ConvertTo-Json -Depth 10 -Compress))){throw 'Task folder deletion completion differs from its durable intent.'}
                $pending[0].FolderDeleteIntents=@($pending[0].FolderDeleteIntents | Where-Object OperationId -CNE $d.Intent.OperationId)
                if(-not $pending[0].PSObject.Properties['DeletedTaskFolders']){$pending[0] | Add-Member NoteProperty DeletedTaskFolders @()}
                $pending[0].DeletedTaskFolders=@($pending[0].DeletedTaskFolders | Where-Object OperationId -CNE $d.Intent.OperationId)+@($d.Intent)
            }
            'AdapterRecovered' {if($d.Status -eq 'RebootRequired'){$copy.Stage='RebootRequired'};$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'AdapterBuildAbandoned' {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'FileScopeIntent' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            'FileScopePrepared' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            'RollbackIntent' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d);$copy.Stage='RollbackRunning'}
            {$_ -in @('ItemCompleted','ScopeRecovered')} {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'ItemFailed' {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.Stage='Failed'}
            'OperationCancelled' {$copy.Stage='Cancelled'}
            'RestoreStarted' {$copy.Stage='Running';$copy | Add-Member NoteProperty RestoreAttempt $d -Force}
            'RestoreCompleted' {$copy.Stage=$d.Status;$copy.Generation=$d.Generation;$copy.ManifestHash=$d.ManifestHash}
            'ValidationEvidence' {$copy.Evidence=@($copy.Evidence | Where-Object {-not ($_.ItemId -ceq $id -and $_.Check -ceq $d.Check)})+@($d)}
            'CutoverPrepared' {$copy.Cutover=$d}
            'RenameRequiresReboot' {$copy.Stage='RebootRequired';$copy.Cutover.Stage='RenameRebootRequired'}
            'NetworkApplied' {$copy.Cutover.Stage='NetworkApplied'}
            'ActivationBoundary' {$copy.Cutover.NewTransactionsPossible=$true}
            {$_ -in @('ActivationIntent','ActivationCompleted')} {if(-not $copy.Cutover.PSObject.Properties['Activations']){$copy.Cutover | Add-Member NoteProperty Activations @()};$copy.Cutover.Activations=@($copy.Cutover.Activations | Where-Object ItemId -CNE $id)+@($d)}
            'ActivationResumeReviewed' {$copy.Cutover | Add-Member NoteProperty ResumeReview $d -Force}
            'CutoverCompleted' {$copy.Stage=$d.Status;$copy.Cutover.Stage='Activated';if($d.PSObject.Properties['ActivatedUtc']){$copy.Cutover | Add-Member NoteProperty ActivatedUtc $d.ActivatedUtc -Force};if($d.PSObject.Properties['ObservationHours']){$copy.Cutover | Add-Member NoteProperty ObservationHours $d.ObservationHours -Force}}
            'StageResultExported' {$copy.ResultSequence=$d.Sequence}
            'RollbackCompleted' {foreach($item in $copy.Items){if($item.ItemId -ceq $id){$item.Status='RolledBack';if($item.PSObject.Properties['CreatedByTool']){$item.CreatedByTool=$false};if($item.PSObject.Properties['UpdatedByTool']){$item.UpdatedByTool=$false}}};$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'RollbackFinished' {$copy.Stage='RolledBack'}
            'BuildAbandoned' {$op=@($copy.PendingOperations | Where-Object ItemId -CEQ $id);$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id);if($op.Count -and $op[0].PSObject.Properties['PreviousRecord'] -and $op[0].PreviousRecord){$copy.Items+=@($op[0].PreviousRecord)};$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'AssistiveRestorePreviewRebound' {if(-not $copy.PSObject.Properties['RestoreAttempt'] -or -not $copy.RestoreAttempt -or [string]$copy.RestoreAttempt.OperationId -cne [string]$d.ParentOperationId){throw 'Preview rebound journal row has no matching restore attempt.'};$copy.RestoreAttempt | Add-Member NoteProperty WizardPreviewHash ([string]$d.PreviewHash) -Force;if($copy.RestoreAttempt.PSObject.Properties['PreviewRowHashes']){$copy.RestoreAttempt | Add-Member NoteProperty PreviewRowHashes @($d.PreviewRowHashes) -Force};if($copy.PSObject.Properties['AssistiveServiceChallenge'] -and $copy.AssistiveServiceChallenge -and [string]$copy.AssistiveServiceChallenge.ParentOperationId -ceq [string]$d.ParentOperationId){$copy.AssistiveServiceChallenge.PreviewHash=[string]$d.PreviewHash}}
            'AssistiveNonCFileResultsImported' {$copy | Add-Member NoteProperty AssistiveFileResults @($d.Rows) -Force}
            'AssistiveServiceCredentialChallengeWaiting' {
                # Detail is the challenge as written, plus the RestoreAttempt snapshot (rows from callers that omit it reuse the durable attempt).
                $snapshot=$null;if($d.PSObject.Properties['RestoreAttempt']){$snapshot=$d.RestoreAttempt;$d.PSObject.Properties.Remove('RestoreAttempt')}
                if($snapshot){$copy | Add-Member NoteProperty RestoreAttempt $snapshot -Force}else{[void](Get-WsmReplayAttempt $copy 'AssistiveServiceCredentialChallengeWaiting' ([string]$d.ParentOperationId))}
                $copy | Add-Member NoteProperty AssistiveServiceChallenge $d -Force;$copy.ManifestHash=$d.ManifestHash;$copy.Generation=$d.Generation;$copy.Stage='WaitingForInput'
            }
            'AssistiveServiceCredentialChallengeResuming' {$copy | Add-Member NoteProperty AssistiveServiceChallenge $d -Force}
            'AssistiveServiceCredentialChallengeCancelled' {
                $copy | Add-Member NoteProperty AssistiveServiceChallenge $d -Force;$copy.Stage='Cancelled'
                if($copy.PSObject.Properties['RestoreAttempt'] -and $copy.RestoreAttempt -and [string]$copy.RestoreAttempt.OperationId -ceq [string]$d.ParentOperationId){$copy.RestoreAttempt | Add-Member NoteProperty Status 'Cancelled' -Force;$copy.RestoreAttempt | Add-Member NoteProperty CancelledUtc ([string]$event.Utc) -Force}
            }
            'AssistiveServiceCredentialDeferred' {
                $challenge=Get-WsmReplayChallenge $copy 'AssistiveServiceCredentialDeferred'
                $refs=@($d.SecretRefs | ForEach-Object {[string]$_});$already=@();if($challenge.PSObject.Properties['DeferredSecretRefs']){$already=@($challenge.DeferredSecretRefs | ForEach-Object {[string]$_})}
                foreach($requirement in @($challenge.Requirements)){if([string]$requirement.SecretRef -cin $refs){$requirement | Add-Member NoteProperty Deferred $true -Force;$requirement | Add-Member NoteProperty DeferReason 'CredentialDeferred' -Force}}
                $challenge.RequiredSecretRefs=@($d.RemainingSecretRefs | ForEach-Object {[string]$_});$challenge | Add-Member NoteProperty DeferredSecretRefs @(@($already)+@($refs) | Sort-Object -Unique) -Force;$challenge.UpdatedUtc=[string]$event.Utc
            }
            'AssistiveServiceCredentialChallengeTakenOver' {
                $challenge=Get-WsmReplayChallenge $copy 'AssistiveServiceCredentialChallengeTakenOver';$attempt=Get-WsmReplayAttempt $copy 'AssistiveServiceCredentialChallengeTakenOver' ([string]$d.ParentOperationId)
                if($null -ne $d.PreWriteRecovery){$copy.Stage='WaitingForInput';$attempt.Status='WaitingForInput';$attempt | Add-Member NoteProperty LastPreWriteRecovery $d.PreWriteRecovery -Force;$challenge.State='WaitingForInput';$challenge | Add-Member NoteProperty LastPreWriteRecovery $d.PreWriteRecovery -Force}
                $challenge.Actor=[string]$d.Actor;$challenge.SessionId=[string]$d.SessionId;$challenge.ContextId=[string]$d.ContextId;$challenge | Add-Member NoteProperty TakeoverCount ([int]$d.TakeoverCount) -Force;$challenge | Add-Member NoteProperty LastTakeoverUtc ([string]$event.Utc) -Force
            }
            'AssistiveServiceCredentialChallengeRebound' {Set-WsmReplayChallengeWaiting $copy $d ([string]$event.Utc)}
            'AssistiveServiceCredentialRejectedLimit' {Set-WsmReplayCredentialWaitingSnapshot $copy $d 'AssistiveServiceCredentialRejectedLimit' $false}
            {$_ -in @('AssistiveServiceCredentialRejected','AssistiveServiceCredentialReprompt')} {Set-WsmReplayCredentialWaitingSnapshot $copy $d $event.Action $true}
            'AssistiveItemCredentialRejected' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            {$_ -in @('AssistiveItemNeedsReconciliation','AssistiveItemBlockedByUnknownDependency','AssistiveItemCredentialDeferred')} { <# The writer only appends the per-item result to the in-memory list; the durable attempt receives it with the later waiting/cancel/completed event, so no state field changes here. #> }
            {$_ -in @('AssistiveRollbackFileDisplaced','AssistiveRollbackFileRestored','AssistiveRollbackNewFileRetained','AssistiveRollbackDirectoryAbsent','AssistiveRollbackDirectoryRemoved','AssistiveRollbackDirectoryRetainedExternalContent','AssistiveRollbackDirectoryMetadataRestored')} { <# Native-progress evidence inside one rollback: the durable rollback intent in PendingOperations is unchanged until RollbackCompleted, so replay changes nothing. #> }
            'AssistiveRestoreCancelled' {
                $copy.Stage='Cancelled';$copy.ManifestHash=$d.ManifestHash;$copy.Generation=$d.Generation
                if($copy.PSObject.Properties['RestoreAttempt'] -and $copy.RestoreAttempt){
                    if($d.PSObject.Properties['ItemResults']){$copy.RestoreAttempt | Add-Member NoteProperty ItemResults @($d.ItemResults) -Force}
                    if($copy.PSObject.Properties['AssistiveServiceChallenge'] -and $copy.AssistiveServiceChallenge -and -not ([string]$copy.AssistiveServiceChallenge.ParentOperationId -cne [string]$copy.RestoreAttempt.OperationId -and [string]$copy.AssistiveServiceChallenge.State -ceq 'Revoked')){$copy.AssistiveServiceChallenge.State='Cancelled';$copy.AssistiveServiceChallenge.UpdatedUtc=[string]$event.Utc}
                }
            }
            'AssistiveRestoreParentSuperseded' {Set-WsmReplayParentTerminal $copy $d 'Superseded' ([string]$event.Utc)}
            'AssistiveRestoreParentCancelled' {Set-WsmReplayParentTerminal $copy $d 'Cancelled' ([string]$event.Utc)}
            'AssistiveRestoreContinuation' {
                $attempt=Get-WsmReplayAttempt $copy 'AssistiveRestoreContinuation' ([string]$d.ParentOperationId)
                $records=@();if($attempt.PSObject.Properties['Continuations']){$records=@($attempt.Continuations)}
                switch -Exact ([string]$d.Phase){
                    'Started' {$attempt | Add-Member NoteProperty Continuations (@($records)+@([pscustomobject][ordered]@{ContinuationId=[string]$d.ContinuationId;StartedUtc=[string]$event.Utc;Actor=[string]$d.Actor;SessionId=[string]$d.SessionId;Result=$null})) -Force}
                    'Completed' {$matched=@($records | Where-Object {[string]$_.ContinuationId -ceq [string]$d.ContinuationId});if($matched.Count -ne 1){throw 'Journal replay of a completed continuation found no unique durable continuation record; retain evidence and recover manually.'};$matched[0] | Add-Member NoteProperty Result $d.Result -Force;$matched[0] | Add-Member NoteProperty CompletedUtc ([string]$event.Utc) -Force}
                    'Superseded' {
                        Set-WsmReplayParentTerminal $copy $d 'Superseded' ([string]$event.Utc)
                        $actor='';$session='';$result=$null;if($d.PSObject.Properties['Actor']){$actor=[string]$d.Actor};if($d.PSObject.Properties['SessionId']){$session=[string]$d.SessionId};if($d.PSObject.Properties['Result']){$result=$d.Result}
                        $attempt | Add-Member NoteProperty Continuations (@($records)+@([pscustomobject][ordered]@{ContinuationId=[string]$d.ContinuationId;StartedUtc=[string]$event.Utc;Actor=$actor;SessionId=$session;Result=$result})) -Force
                    }
                    default {throw ('Journal replay of an unknown continuation phase ('+[string]$d.Phase+'); retain evidence and recover manually.')}
                }
            }
            'SettingTransitionIntent' {
                if(-not $d.PSObject.Properties['Transition'] -or -not $d.Transition){throw 'Journal replay of SettingTransitionIntent lacks the exact transition written by this version; retain evidence and recover manually.'}
                $copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@([pscustomobject][ordered]@{ItemId=$id;Phase='SettingTransition';ManifestHash=[string]$d.ManifestHash;TransitionHash=[string]$d.TransitionHash;Transition=$d.Transition;Intent=$d.Intent;Receipt=$null;AppliedPhase=[string]$d.AppliedPhase;RequiredPhase=[string]$d.RequiredPhase})
            }
            'SettingTransitionReceipt' {$pending=Get-WsmReplayPending $copy $id 'SettingTransitionReceipt';if($pending.Phase -cne 'SettingTransition' -or [string]$pending.TransitionHash -cne [string]$d.TransitionHash){throw 'Journal replay of SettingTransitionReceipt does not match its durable transition intent; retain evidence and recover manually.'};$pending | Add-Member NoteProperty Receipt $d.Receipt -Force}
            'SettingTransitionRecovered' {
                $pending=Get-WsmReplayPending $copy $id 'SettingTransitionRecovered';if($pending.Phase -cne 'SettingTransition' -or [string]$pending.TransitionHash -cne [string]$d.TransitionHash){throw 'Journal replay of SettingTransitionRecovered does not match its durable transition intent; retain evidence and recover manually.'}
                $action=[string]$pending.Transition.Action;$actual=$null;if($d.PSObject.Properties['ActualHash']){$actual=[string]$d.ActualHash}else{$actual=Get-WsmHashText ($d.Receipt | ConvertTo-Json -Depth 20 -Compress)}
                $result=[pscustomobject]@{ItemId=$id;Status='Succeeded';CreatedByTool=($action -eq 'CreateNew');UpdatedByTool=($action -eq 'UpdateReviewed');ActualHash=$actual;Backup='';Target='';Error='';NativeCode=0;SettingTransitionDeferred=$false;SettingTransitionIntent=$pending.Intent;SettingTransitionReceipt=$d.Receipt}
                $copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($result);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)
            }
            'SettingTransitionRollbackIntent' {$pending=Get-WsmReplayPending $copy $id 'SettingTransitionRollbackIntent';if($pending.Phase -cne 'RollbackAdapter'){throw 'Journal replay of SettingTransitionRollbackIntent has no durable rollback intent; retain evidence and recover manually.'};$pending | Add-Member NoteProperty SettingTransitionRollbackIntent $d -Force}
            'SettingTransitionRollbackReceipt' {
                if(-not $d.PSObject.Properties['Recovery'] -or [string]$d.Recovery -cne 'ExactPriorReadback'){$pending=Get-WsmReplayPending $copy $id 'SettingTransitionRollbackReceipt';if($pending.Phase -cne 'RollbackAdapter'){throw 'Journal replay of SettingTransitionRollbackReceipt has no durable rollback intent; retain evidence and recover manually.'};$pending | Add-Member NoteProperty SettingTransitionRollbackReceipt $d.Receipt -Force}
            }
            {$_ -in @('AssistiveItemStarted','ItemStarted','ItemActivated','ValidationCompleted','RollbackStarted')} { }
            default {throw ('Unknown recovery event: '+$event.Action)}
        }
        $copy.Sequence=$event.Sequence;$copy.JournalHash=$eventHash
    }}
    $copy.JournalSegment=[long]$check.ArchiveCount
    Write-WsmJson $Paths.State $copy
    $verified=Test-WsmJournal ([IO.Path]::GetDirectoryName($Paths.Root)) $copy.PairId
    if(-not $verified.Consistent){throw 'Journal replay did not produce a verified durable checkpoint; retain evidence.'}
    foreach($property in $copy.PSObject.Properties){$State | Add-Member NoteProperty $property.Name $property.Value -Force}
}
