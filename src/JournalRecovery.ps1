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
function Restore-WsmJournalCheckpoint($Paths,$State) {
    # Validate the full chain and the exact old checkpoint before replaying any event.
    $check=Test-WsmJournal ([IO.Path]::GetDirectoryName($Paths.Root)) $State.PairId
    if($check.Consistent){return};if(-not $check.RecoveryRequired){throw 'Checkpoint is ahead of or differs from durable journal; retain evidence.'}
    $copy=ConvertFrom-WsmJson ($State | ConvertTo-Json -Depth 40)
    Read-WsmJournalEvents $Paths | ForEach-Object {$event=$_.Row;$eventHash=$_.Hash;if($event.Sequence -gt $copy.Sequence){$d=$event.Detail;$id=$event.ItemId
        switch -Exact ($event.Action){
            'AssistiveRestoreStarted' {$copy.Stage='Running';$copy | Add-Member NoteProperty RestoreAttempt $d -Force}
            'AssistiveDeltaFallbackDeferred' {$fallbacks=@();if($copy.PSObject.Properties['AssistiveDeltaFallbacks']){$fallbacks=@($copy.AssistiveDeltaFallbacks)};$copy | Add-Member NoteProperty AssistiveDeltaFallbacks (@($fallbacks)+@($d)) -Force}
            'AssistiveAdapterIntent' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            {$_ -in @('AssistiveFileIntent','AssistiveFilePrepared')} {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            'AssistiveFileBackupRetained' {$pending=@($copy.PendingOperations | Where-Object ItemId -CEQ $id);if($pending.Count -ne 1 -or $pending[0].Phase -cne 'AssistiveFileReplace'){throw 'Assistive backup material journal row has no matching file intent.'};$pending[0].Backup=[string]$d.Backup;$pending[0] | Add-Member NoteProperty BackupMaterialId ([string]$d.MaterialId) -Force}
            'AssistiveFileCompleted' {$pending=@($copy.PendingOperations | Where-Object ItemId -CEQ $id);$record=@($copy.Items | Where-Object ItemId -CEQ $id);if($record.Count -eq 0){$record=[pscustomobject]@{ItemId=$id;Status='Partial';CreatedByTool=$true;AppliedManifestHash='';AppliedGeneration=0;OwnedFiles=@();OwnedDirectories=@();Target=''}}else{$record=$record[0]};$files=@($record.OwnedFiles | Where-Object RelativePath -CNE ([string]$d.Record.RelativePath));$files+=,$d.Record;$record.OwnedFiles=$files;$record.Status='Partial';$record.AppliedManifestHash='';$record.Error='One file transaction completed; the full scope still requires reconciliation.';$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($record);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'AssistiveFileRecovered' {if($d.Record){$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d.Record)};$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'AssistiveAdapterRecovered' {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'AssistiveAdapterAbandoned' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id);$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)}
            {$_ -in @('AssistiveItemCompleted','AssistiveItemFailed')} {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id);if($d.Status -eq 'Failed'){$copy.Stage='Partial'}}
            'AssistiveItemNeedsRepair' {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@([pscustomobject]@{ItemId=$id;Status='Failed';CreatedByTool=$true;AppliedManifestHash='';AppliedGeneration=0;Error='An Assistive item operation needs explicit recovery.'})}
            'AssistiveRestoreCompleted' {$copy.Stage=$d.Status;$copy.Generation=$d.Generation;$copy.ManifestHash=$d.ManifestHash}
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
            'RollbackCompleted' {foreach($item in $copy.Items){if($item.ItemId -ceq $id){$item.Status='RolledBack'}};$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'RollbackFinished' {$copy.Stage='RolledBack'}
            'BuildAbandoned' {$op=@($copy.PendingOperations | Where-Object ItemId -CEQ $id);$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id);if($op.Count -and $op[0].PSObject.Properties['PreviousRecord'] -and $op[0].PreviousRecord){$copy.Items+=@($op[0].PreviousRecord)};$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            {$_ -in @('AssistiveItemStarted','ItemStarted','ItemActivated','ValidationCompleted','RollbackStarted')} { }
            default {throw ('Unknown recovery event: '+$event.Action)}
        }
        $copy.Sequence=$event.Sequence;$copy.JournalHash=$eventHash
    }}
    $copy.JournalSegment=@(Get-ChildItem -LiteralPath $Paths.Root -Filter 'journal-*.jsonl').Count
    Write-WsmJson $Paths.State $copy
    foreach($property in $copy.PSObject.Properties){$State | Add-Member NoteProperty $property.Name $property.Value -Force}
}
