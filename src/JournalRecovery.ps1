function Read-WsmJournalEvents($Paths) {
    $archives=@(Get-ChildItem -LiteralPath $Paths.Root -Filter 'journal-*.jsonl' | Sort-Object {[int]([regex]::Match($_.Name,'\d+').Value)})
    foreach($path in @($archives | ForEach-Object FullName)+@($Paths.Journal)){
        if(-not $path -or -not [IO.File]::Exists($path)){continue};Assert-WsmNoReparse $path
        $stream=[IO.File]::Open($path,'Open','Read','Read');$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        try{Read-WsmBoundedLines $reader | ForEach-Object {[pscustomobject]@{Row=(ConvertFrom-WsmJson $_);Hash=(Get-WsmHashText $_)}}}finally{$reader.Dispose();$stream.Dispose()}
    }
}
function Restore-WsmJournalCheckpoint($Paths,$State) {
    # Validate the full chain and the exact old checkpoint before replaying any event.
    $check=Test-WsmJournal ([IO.Path]::GetDirectoryName($Paths.Root)) $State.PairId
    if($check.Consistent){return};if(-not $check.RecoveryRequired){throw 'Checkpoint is ahead of or differs from durable journal; retain evidence.'}
    $copy=ConvertFrom-WsmJson ($State | ConvertTo-Json -Depth 40)
    Read-WsmJournalEvents $Paths | ForEach-Object {$event=$_.Row;$eventHash=$_.Hash;if($event.Sequence -gt $copy.Sequence){$d=$event.Detail;$id=$event.ItemId
        switch -Exact ($event.Action){
            'AdapterIntent' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            'AdapterRecovered' {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'AdapterBuildAbandoned' {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'FileScopeIntent' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            'FileScopePrepared' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d)}
            'RollbackIntent' {$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)+@($d);$copy.Stage='RollbackRunning'}
            {$_ -in @('ItemCompleted','ScopeRecovered')} {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'ItemFailed' {$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id)+@($d);$copy.Stage='Failed'}
            'RestoreStarted' {$copy.Stage='Running'}
            'RestoreCompleted' {$copy.Stage=$d.Status;$copy.Generation=$d.Generation;$copy.ManifestHash=$d.ManifestHash}
            'ValidationEvidence' {$copy.Evidence=@($copy.Evidence | Where-Object {-not ($_.ItemId -ceq $id -and $_.Check -ceq $d.Check)})+@($d)}
            'CutoverPrepared' {$copy.Cutover=$d}
            'RenameRequiresReboot' {$copy.Stage='RebootRequired';$copy.Cutover.Stage='RenameRebootRequired'}
            'NetworkApplied' {$copy.Cutover.Stage='NetworkApplied'}
            'ActivationBoundary' {$copy.Cutover.NewTransactionsPossible=$true}
            'CutoverCompleted' {$copy.Stage=$d.Status;$copy.Cutover.Stage='Activated'}
            'StageResultExported' {$copy.ResultSequence=$d.Sequence}
            'RollbackCompleted' {foreach($item in $copy.Items){if($item.ItemId -ceq $id){$item.Status='RolledBack'}};$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            'RollbackFinished' {$copy.Stage='RolledBack'}
            'BuildAbandoned' {$op=@($copy.PendingOperations | Where-Object ItemId -CEQ $id);$copy.Items=@($copy.Items | Where-Object ItemId -CNE $id);if($op.Count -and $op[0].PSObject.Properties['PreviousRecord'] -and $op[0].PreviousRecord){$copy.Items+=@($op[0].PreviousRecord)};$copy.PendingOperations=@($copy.PendingOperations | Where-Object ItemId -CNE $id)}
            {$_ -in @('ItemStarted','ItemActivated','ValidationCompleted','RollbackStarted')} { }
            default {throw ('Unknown recovery event: '+$event.Action)}
        }
        $copy.Sequence=$event.Sequence;$copy.JournalHash=$eventHash
    }}
    $copy.JournalSegment=@(Get-ChildItem -LiteralPath $Paths.Root -Filter 'journal-*.jsonl').Count
    Write-WsmJson $Paths.State $copy
    foreach($property in $copy.PSObject.Properties){$State | Add-Member NoteProperty $property.Name $property.Value -Force}
}
