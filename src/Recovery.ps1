function Test-WsmJournal {
    param([string]$StateDirectory,[string]$PairId)
    $paths=Get-WsmOperationPaths $StateDirectory $PairId;$state=Read-WsmJson $paths.State;$hash='0'*64;$sequence=[long]0
    if(-not $state -or -not $state.PSObject.Properties['JournalSegment']){throw 'Operation state has no valid journal segment checkpoint; retain evidence.'}
    $segmentValue=$state.PSObject.Properties['JournalSegment'].Value
    if(($segmentValue -isnot [int] -and $segmentValue -isnot [long]) -or [long]$segmentValue -lt 0){throw 'Operation state has no valid journal segment checkpoint; retain evidence.'}
    $archiveFiles=@(Get-ChildItem -LiteralPath $paths.Root -Filter 'journal-*.jsonl' -Force -ErrorAction SilentlyContinue)
    $archiveNumbers=New-Object 'System.Collections.Generic.List[long]'
    foreach($archive in $archiveFiles){
        $archiveMatch=[regex]::Match($archive.Name,'^journal-(0|[1-9][0-9]*)\.jsonl$')
        if($archive.PSIsContainer -or ($archive.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not $archiveMatch.Success){throw 'Journal archive topology is invalid; retain evidence.'}
        $archiveNumbers.Add([long]$archiveMatch.Groups[1].Value)
    }
    $orderedNumbers=@($archiveNumbers | Sort-Object)
    for($index=0;$index -lt $orderedNumbers.Count;$index++){if($orderedNumbers[$index] -ne $index){throw 'Journal archive topology is not contiguous; retain evidence.'}}
    $archiveCount=[long]$orderedNumbers.Count
    $matched=($state.Sequence -eq 0 -and $state.JournalHash -ceq $hash)
    Read-WsmJournalEvents $paths | ForEach-Object {
        $row=$_.Row;$expectedSequence=[long]($sequence+1);$observedSequence=[long]0
        try{$observedSequence=[long]$row.Sequence}catch{}
        $samePair=($row.PairId -ceq $PairId);$sameRun=($row.RunId -ceq $state.RunId);$previousHashMatches=($row.PreviousHash -ceq $hash)
        $predicate=''
        if($row.Sequence -ne $expectedSequence){$predicate='Sequence'}
        elseif(-not $previousHashMatches){$predicate='PreviousHash'}
        elseif(-not $samePair){$predicate='PairId'}
        elseif(-not $sameRun){$predicate='RunId'}
        if($predicate){
            $mismatch=[System.IO.InvalidDataException]::new('Journal chain/sequence/identity mismatch; retain evidence.')
            $mismatch.Data['WsmJournalMismatchPredicate']=$predicate
            $mismatch.Data['WsmJournalExpectedSequence']=$expectedSequence
            $mismatch.Data['WsmJournalObservedSequence']=$observedSequence
            $mismatch.Data['WsmJournalSamePair']=[bool]$samePair
            $mismatch.Data['WsmJournalSameRun']=[bool]$sameRun
            $mismatch.Data['WsmJournalPreviousHashMatches']=[bool]$previousHashMatches
            throw $mismatch
        }
        $sequence=$row.Sequence;$hash=$_.Hash
        if($sequence -eq $state.Sequence){if($hash -cne $state.JournalHash){throw 'Checkpoint does not match its durable journal prefix.'};$matched=$true}
    }
    if(-not $matched){throw 'Checkpoint is absent from durable journal.'}
    $segmentMismatch=([long]$state.JournalSegment -ne $archiveCount)
    $sameCheckpoint=($sequence -eq $state.Sequence -and $hash -ceq $state.JournalHash)
    [pscustomobject]@{JournalSequence=$sequence;JournalHash=$hash;StateSequence=$state.Sequence;StateHash=$state.JournalHash;ArchiveCount=$archiveCount;ArchiveTopologyValid=$true;SegmentMismatch=$segmentMismatch;RecoverableSegmentMismatch=($segmentMismatch -and $sameCheckpoint);Consistent=($sameCheckpoint -and -not $segmentMismatch);RecoveryRequired=($sequence -gt $state.Sequence);TamperResistance='Local administrator can rewrite journal and state; chain detects accidental corruption only'}
}
function Repair-WsmOperation {
    [CmdletBinding(SupportsShouldProcess)]param([string]$ManifestPath,[string]$ExpectedHash,[string]$StateDirectory,[hashtable]$SidMap=@{})
    $p=Test-WsmMigrationPackage $ManifestPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $p.Manifest.Target.Fingerprint;$paths=Get-WsmOperationPaths $StateDirectory $p.Manifest.PairId
    Invoke-WsmLocked $paths.Root {$s=Get-WsmOperationState $paths $p -AllowRecovery;$journal=Test-WsmJournal $StateDirectory $s.PairId;if(-not $journal.Consistent){if(-not $PSCmdlet.ShouldProcess($s.PairId,'Replay verified durable journal to checkpoint')){return};Restore-WsmJournalCheckpoint $paths $s};if($s.Cutover -and $s.Cutover.NewTransactionsPossible -and -not (Test-WsmEvidence $s '' RollbackReconcile $ExpectedHash)){throw 'Post-activation recovery requires data reconciliation.'};$repaired=@()
        foreach($op in @($s.PendingOperations | Where-Object Phase -In @('AssistiveAdapterCreating','AssistiveFileReplace'))){$item=@($p.Plan.Items | Where-Object ItemId -CEQ $op.ItemId)[0];if($p.Plan.SchemaVersion -ne 3 -or $op.ManifestHash -ine $ExpectedHash -or -not $item -or $item.Decision -cne 'Include'){throw 'Assistive recovery intent does not bind the exact current included package item.'};if($PSCmdlet.ShouldProcess($item.ItemId,'Reconcile exact Assistive staged object or owned file intent')){Complete-WsmAssistiveOperationRepair $item $op $p $paths $s $SidMap;$repaired+=$item.ItemId}}
        foreach($op in @($s.PendingOperations | Where-Object Phase -NotIn @('AssistiveAdapterCreating','AssistiveFileReplace'))){$item=@($p.Plan.Items | Where-Object ItemId -CEQ $op.ItemId)[0];if($op.Phase -eq 'RollbackAssistiveFiles'){if($op.ManifestHash -ine $ExpectedHash -or -not $item -or $item.MigrationSpec.Adapter -cne 'FileScope'){throw 'Assistive file rollback recovery binding mismatch.'};if($PSCmdlet.ShouldProcess($item.ItemId,'Finish durable per-file Assistive rollback')){Complete-WsmAssistiveFileRollback $item $op $paths $s;$repaired+=$item.ItemId};continue};if($op.Phase -eq 'SettingTransition'){if($op.ManifestHash -ine $ExpectedHash -or -not $item -or -not $item.MigrationSpec.PSObject.Properties['SettingTransition'] -or $op.TransitionHash -ine $item.MigrationSpec.SettingTransition.TransitionHash){throw 'SettingTransition recovery plan binding mismatch.'};if($PSCmdlet.ShouldProcess($item.ItemId,'Reconcile durable reviewed setting transition')){Complete-WsmSettingTransitionRecovery $item $op $paths $s;$repaired+=$item.ItemId};continue};if($op.Phase -eq 'RollbackAdapter'){if($op.ManifestHash -ine $ExpectedHash){throw 'Adapter rollback manifest mismatch.'};if($PSCmdlet.ShouldProcess($item.ItemId,'Finish durable reviewed adapter rollback')){Complete-WsmAdapterRollback $item $op $paths $s;$repaired+=$item.ItemId};continue};if($op.Phase -eq 'RollbackPrepared'){if($op.ManifestHash -ine $ExpectedHash -or $item.MigrationSpec.Adapter -ne 'FileScope'){throw 'Rollback recovery binding mismatch.'};if($PSCmdlet.ShouldProcess($item.ItemId,'Finish durable reviewed file rollback; retain displaced content')){Complete-WsmFileRollback $item $op $paths $s;$repaired+=$item.ItemId};continue};if($op.Phase -eq 'AdapterCreating'){if($op.ManifestHash -ine $ExpectedHash -or $op.Adapter -cne $item.MigrationSpec.Adapter -or -not $op.AbsentBefore){throw 'Adapter intent binding mismatch.'};if($op.Adapter -eq 'WindowsFeature'){if(-not $PSCmdlet.ShouldProcess($item.ItemId,'Reconcile and quarantine interrupted installer consumers')){continue};$baseline=Read-WsmInstallerBaseline $op $paths $op.ItemId;[void](Protect-WsmInstallerSideEffects $item.MigrationSpec.Desired $baseline $StateDirectory ([string]$p.Manifest.Target.Fingerprint))};$taskOwned=@();$taskReadback=@();if($op.Adapter -ceq 'ScheduledTask'){if(@($op.FolderCreateIntents).Count){throw 'Task folder creation has a durable intent without receipt; reconcile owner-reviewed ownership before repair.'};$taskOwned=Get-WsmTaskSecurityReceiptsForSpec $item.MigrationSpec @($op.AuxiliaryOwnership);$taskReadback=Get-WsmTaskSecurityReceiptsForSpec $item.MigrationSpec (Get-WsmTaskSecurityOwnershipReceipts $s)};$observed=Get-WsmAdapterState $item.MigrationSpec;if(-not $observed.Exists){if($op.Adapter -ceq 'ScheduledTask' -and $taskOwned.Count){throw 'Scheduled task is absent but owned folder receipts remain; keep ownership evidence and reconcile before repair.'};if($PSCmdlet.ShouldProcess($item.ItemId,'Abandon absent interrupted adapter build')){$s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE $op.ItemId);$s.Items=@($s.Items | Where-Object ItemId -CNE $op.ItemId);Add-WsmJournal $paths $s 'AdapterBuildAbandoned' $op.ItemId ([pscustomobject]@{Absent=$true})};continue};$check=Test-WsmAdapterConfiguration $item.MigrationSpec Staged $taskReadback;if(-not $check.Passed){throw 'Interrupted adapter exists but differs from exact staged spec/security; reconcile using retained intent before repair.'};if($PSCmdlet.ShouldProcess($item.ItemId,'Adopt verified staged adapter from durable absent-before intent')){$recoveredStatus='Succeeded';$bootBefore='';$installerSafety=$null;if($op.Adapter -eq 'WindowsFeature'){$baseline=Read-WsmInstallerBaseline $op $paths $op.ItemId;$installerSafety=Protect-WsmInstallerSideEffects $item.MigrationSpec.Desired $baseline;if(-not $op.PSObject.Properties['BootBefore'] -or -not $op.BootBefore){throw 'Interrupted feature install has no durable boot baseline; reconcile before adopting.'};$bootBefore=$op.BootBefore;if((Get-WsmBootStamp) -ceq $bootBefore){$recoveredStatus='RebootRequired'}};$record=[pscustomobject]@{InstallerBaselinePath=$(if($op.Adapter -eq 'WindowsFeature'){$op.InstallerBaselinePath}else{''});InstallerBaselineHash=$(if($op.Adapter -eq 'WindowsFeature'){$op.InstallerBaselineHash}else{''});InstallerSafety=$installerSafety;BootBefore=$bootBefore;ItemId=$op.ItemId;Status=$recoveredStatus;CreatedByTool=$true;AuxiliaryOwnership=$taskOwned;ActualHash=(Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 15 -Compress));Backup='';Target='';Error='';NativeCode=0};if($record.Status -eq 'RebootRequired'){$s.Stage='RebootRequired'};$s.Items=@($s.Items | Where-Object ItemId -CNE $op.ItemId)+@($record);$s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE $op.ItemId);Add-WsmJournal $paths $s 'AdapterRecovered' $op.ItemId $record;$repaired+=$op.ItemId};continue};if($op.ManifestHash -ine $ExpectedHash -or $item.MigrationSpec.Adapter -ne 'FileScope'){throw 'Pending operation plan mismatch.'};$target=ConvertTo-WsmCanonicalPath $item.MigrationSpec.TargetPath;$parent=[IO.Path]::GetDirectoryName($target);if($op.Target -ine $target -or [IO.Path]::GetDirectoryName($op.Staging) -ine $parent -or [IO.Path]::GetDirectoryName($op.Backup) -ine $parent -or [IO.Path]::GetFileName($op.Staging) -notlike '.wsm-stage-*' -or [IO.Path]::GetFileName($op.Backup) -notlike '.wsm-backup-*'){throw 'Recovery path escapes approved parent.'};foreach($path in @($target,$op.Staging,$op.Backup)){Assert-WsmNoReparse $path};$actual=Get-WsmFileScopeDigest $target $item.MigrationSpec.Metadata
            if($op.Phase -eq 'Prepared' -and $actual -ceq $op.ExpectedHash){if(-not $PSCmdlet.ShouldProcess($target,'Adopt verified completed scope switch')){continue}}
            elseif($op.Phase -eq 'Prepared' -and -not $actual -and (Test-Path -LiteralPath $op.Staging)){$check=Test-WsmFileScope $item $p $op.Staging $SidMap;if(-not $check.Passed -or $check.ActualHash -cne $op.ExpectedHash){throw 'Staging differs from prepared checkpoint.'};if(-not $PSCmdlet.ShouldProcess($target,'Finish interrupted approved scope switch')){continue};if([IO.Directory]::Exists($op.Staging)){[IO.Directory]::Move($op.Staging,$target)}else{[IO.File]::Move($op.Staging,$target)};$actual=$check.ActualHash}
            elseif($actual -ceq $op.PreviousHash){if(-not $PSCmdlet.ShouldProcess($target,'Abandon interrupted build; keep staging evidence and retry fresh')){continue};$s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE $op.ItemId);$s.Items=@($s.Items | Where-Object ItemId -CNE $op.ItemId);if($op.PSObject.Properties['PreviousRecord'] -and $op.PreviousRecord){$s.Items+=@($op.PreviousRecord)};Add-WsmJournal $paths $s 'BuildAbandoned' $op.ItemId ([pscustomobject]@{RetainedStaging=$op.Staging});continue}
            else{throw 'Target/staging do not match a safe checkpoint; manual reconciliation required.'}
            $record=[pscustomobject]@{ItemId=$op.ItemId;Status='Succeeded';CreatedByTool=$true;ActualHash=$actual;Backup=$op.Backup;Target=$target;Error='';NativeCode=0};if($record.Status -eq 'RebootRequired'){$s.Stage='RebootRequired'};$s.Items=@($s.Items | Where-Object ItemId -CNE $op.ItemId)+@($record);$s.PendingOperations=@($s.PendingOperations | Where-Object ItemId -CNE $op.ItemId);$repaired+=$op.ItemId;Add-WsmJournal $paths $s 'ScopeRecovered' $op.ItemId $record
        }
        # P9：FileScope 項目寫入時丟出例外會留下沒有 OwnedFiles 的 Failed 紀錄（沒有 pending intent，上面的迴圈碰不到）。
        # N1 的共用判定（Test-WsmAssistiveFileScopeOwnershipIncomplete）把它列為「需先對帳」，這裡是對帳出口：只補登磁碟內容雜湊等於備份封存值的檔案，其餘一律保留。
        $ownershipReconcile=@()
        foreach($reconcileItem in @($p.Plan.Items | Where-Object {$p.Plan.PSObject.Properties['SchemaVersion'] -and $p.Plan.SchemaVersion -eq 3 -and $_.Decision -ceq 'Include' -and $_.PSObject.Properties['MigrationSpec'] -and $_.MigrationSpec -and [string]$_.MigrationSpec.Adapter -ceq 'FileScope' -and (Test-WsmAssistiveFileScopeOwnershipIncomplete $s ([string]$_.ItemId)) -and @($s.PendingOperations | Where-Object ItemId -CEQ ([string]$_.ItemId)).Count -eq 0})){
            if($PSCmdlet.ShouldProcess($reconcileItem.ItemId,'Reconcile incomplete FileScope ownership: adopt only files whose bytes equal the sealed backup hash, preserve everything else')){$outcome=Complete-WsmAssistiveFileScopeOwnershipRepair $reconcileItem $p $paths $s $SidMap;$ownershipReconcile+=@($outcome);if([string]$outcome.Status -ceq 'Reconciled'){$repaired+=$reconcileItem.ItemId}}
        }
        [pscustomobject]@{Repaired=$repaired;Remaining=$s.PendingOperations.Count;OwnershipReconcile=@($ownershipReconcile);State=$s}
    }
}
function Complete-WsmAssistiveOperationRepair($Item,$Operation,$Package,$Paths,$State,[hashtable]$SidMap=@{}) {
    $spec=$Item.MigrationSpec
    if($Operation.Phase -eq 'AssistiveAdapterCreating'){
        $isIis=$spec.Adapter -in @('IISSection','IISLocation')
        if($Operation.Adapter -cne $spec.Adapter -or $Operation.DesiredHash -ine (Get-WsmHashText ($spec.Desired | ConvertTo-Json -Depth 40 -Compress))){throw 'Assistive adapter recovery intent differs from the exact staged desired object.'}
        if($isIis){
            Assert-WsmAssistiveIisConfigSpec $spec
            if(-not $Operation.Before.Exists -or -not $Operation.PSObject.Properties['UpdatedByTool'] -or -not $Operation.UpdatedByTool -or -not $Operation.Before.PSObject.Properties['Xml'] -or $Operation.BeforeHash -ine (Get-WsmHashText ($Operation.Before | ConvertTo-Json -Depth 30 -Compress))){throw 'Assistive IIS recovery lacks an exact reviewed before-state and update intent.'}
            $beforeXml=Read-WsmXml ([string]$Operation.Before.Xml);$candidate=Set-WsmIisConfigChanges $beforeXml @($spec.Desired.Changes);$desiredXml=Read-WsmXml ([string]$spec.Desired.Xml)
            if((ConvertTo-WsmXmlComparable $candidate.DocumentElement) -cne (ConvertTo-WsmXmlComparable $desiredXml.DocumentElement)){throw 'Assistive IIS recovery changes do not produce the exact reviewed Desired.Xml.'}
            $observed=Get-WsmAdapterState $spec;if(-not $observed.Exists){throw 'Reviewed IIS section/location disappeared during interrupted update; retain intent.'}
            $observedXml=Read-WsmXml ([string]$observed.Xml)
            if((ConvertTo-WsmXmlComparable $observedXml.DocumentElement) -ceq (ConvertTo-WsmXmlComparable $desiredXml.DocumentElement)){$check=Test-WsmAdapterConfiguration $spec Staged;if(-not $check.Passed){throw 'Interrupted Assistive IIS update does not pass exact staged readback.'};$actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress);$beforeHash=Get-WsmHashText ($Operation.Before | ConvertTo-Json -Depth 30 -Compress);$record=[pscustomobject]@{ItemId=$Item.ItemId;Status='Succeeded';CreatedByTool=$false;UpdatedByTool=$true;AppliedManifestHash=$Package.SHA256;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=(Get-WsmAdapterObjectIdentity $spec);Backup='';Error='Recovered exact reviewed IIS field update from durable before-state intent.';NativeCode=0;Before=$Operation.Before;PriorXml=[string]$Operation.Before.Xml;BeforeHash=$beforeHash;AuxiliaryOwnership=@()};$State.Items=@($State.Items | Where-Object ItemId -CNE $Item.ItemId)+@($record);$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId);Add-WsmJournal $Paths $State 'AssistiveAdapterRecovered' $Item.ItemId $record;return}
            if((ConvertTo-WsmXmlComparable $observedXml.DocumentElement) -ceq (ConvertTo-WsmXmlComparable $beforeXml.DocumentElement)){$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId);Add-WsmJournal $Paths $State 'AssistiveAdapterAbandoned' $Item.ItemId ([pscustomobject]@{UnchangedBefore=$true;ManifestHash=$Package.SHA256});return}
            throw 'Interrupted Assistive IIS update matches neither the exact reviewed before-state nor desired XML; preserve intent for manual reconciliation.'
        }
        if($Operation.Before.Exists -or -not $Operation.PSObject.Properties['AbsentBefore'] -or -not $Operation.AbsentBefore){throw 'Assistive adapter recovery intent differs from the exact staged absent-before object.'}
        $installerSafety=$null;$bootBefore='';$status='Succeeded';$installerResult=$null
        if($Operation.Adapter -eq 'WindowsFeature'){$baseline=Read-WsmInstallerBaseline $Operation $Paths $Item.ItemId;$targetFingerprint='';if($State.PSObject.Properties['TargetFingerprint']){$targetFingerprint=[string]$State.TargetFingerprint};$installerSafety=Protect-WsmInstallerSideEffects $spec.Desired $baseline ([IO.Path]::GetDirectoryName($Paths.Root)) $targetFingerprint;if(-not $Operation.PSObject.Properties['BootBefore'] -or -not $Operation.BootBefore){throw 'Interrupted Assistive feature install has no durable boot baseline; reconcile before adopting.'};$bootBefore=[string]$Operation.BootBefore;$installerResult=[pscustomobject]@{NativeTool='Install-WindowsFeature';Recovered=$true};if((Get-WsmBootStamp) -ceq $bootBefore){$status='RebootRequired'}}
        $taskOwned=@();$taskReadback=@();$ownedForOperation=@();if($Operation.Adapter -ceq 'ScheduledTask'){if(@($Operation.FolderCreateIntents).Count){throw 'Assistive task folder creation has a durable intent without receipt; reconcile owner-reviewed ownership before repair.'};$ownedForOperation=@($Operation.AuxiliaryOwnership);$taskOwned=Get-WsmTaskSecurityReceiptsForSpec $spec @($ownedForOperation);$taskReadback=Get-WsmTaskSecurityReceiptsForSpec $spec (Get-WsmTaskSecurityOwnershipReceipts $State);foreach($receipt in $ownedForOperation){if(@($taskReadback | Where-Object OperationId -CEQ $receipt.OperationId).Count -eq 0){$taskReadback+=@((Get-WsmTaskSecurityReceiptsForSpec $spec @($receipt)))}}}
        $observed=Get-WsmAdapterState $spec
        if(-not $observed.Exists){if($Operation.Adapter -ceq 'ScheduledTask' -and $taskOwned.Count){throw 'Interrupted Assistive scheduled task is absent but owned folder receipts remain; reconcile the retained ownership evidence first.'};$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId);Add-WsmJournal $Paths $State 'AssistiveAdapterAbandoned' $Item.ItemId ([pscustomobject]@{Absent=$true;ManifestHash=$Package.SHA256});return}
        $check=Test-WsmAdapterConfiguration $spec Staged $taskReadback
        if(-not $check.Passed){throw 'Interrupted Assistive adapter differs from exact staged configuration; preserve intent for manual reconciliation.'}
        $actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 30 -Compress)
        if($Operation.Adapter -eq 'WindowsFeature'){[void](Test-WsmInstallerConsumers $spec.Desired $installerSafety Staged)}
        $baselinePath='';$baselineHash='';if($Operation.PSObject.Properties['InstallerBaselinePath']){$baselinePath=[string]$Operation.InstallerBaselinePath};if($Operation.PSObject.Properties['InstallerBaselineHash']){$baselineHash=[string]$Operation.InstallerBaselineHash}
        $record=[pscustomobject]@{ItemId=$Item.ItemId;Status=$status;CreatedByTool=$true;AppliedManifestHash=$Package.SHA256;AppliedGeneration=[long]$Package.Manifest.Generation;ActualHash=$actual;Target=(Get-WsmAdapterObjectIdentity $spec);Backup='';Error='Recovered exact staged object from durable absent-before intent.';NativeCode=0;Before=$Operation.Before;BootBefore=$bootBefore;InstallerBaselinePath=$baselinePath;InstallerBaselineHash=$baselineHash;InstallerSafety=$installerSafety;InstallerResult=$installerResult;AuxiliaryOwnership=@($ownedForOperation)}
        if($status -eq 'RebootRequired'){$State.Stage='RebootRequired'}
        $State.Items=@($State.Items | Where-Object ItemId -CNE $Item.ItemId)+@($record);$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId);Add-WsmJournal $Paths $State 'AssistiveAdapterRecovered' $Item.ItemId $record;return
    }
    if($spec.Adapter -cne 'FileScope'){throw 'Assistive file recovery intent is not a FileScope item.'}
    $root=ConvertTo-WsmCanonicalPath ([string]$spec.TargetPath);$expectedTarget=$root;if($Operation.RelativePath){$expectedTarget=Join-Path $root ([string]$Operation.RelativePath)}
    $target=[IO.Path]::GetFullPath([string]$Operation.Target);$staging=[IO.Path]::GetFullPath([string]$Operation.Staging);$backup='';if($Operation.Backup){$backup=[IO.Path]::GetFullPath([string]$Operation.Backup)}
    $targetPrefix=$root.TrimEnd('\')+'\'
    if($target -ine [IO.Path]::GetFullPath($expectedTarget) -or ($target -ine $root -and -not $target.StartsWith($targetPrefix,[StringComparison]::OrdinalIgnoreCase)) -or [IO.Path]::GetDirectoryName($staging) -ine [IO.Path]::GetDirectoryName($target) -or [IO.Path]::GetFileName($staging) -notmatch '\.wsm-[a-f0-9]{32}\.tmp$'){throw 'Assistive file recovery path escaped its approved scope or generated sibling pattern.'}
    if($backup -and ([IO.Path]::GetDirectoryName($backup) -ine [IO.Path]::GetDirectoryName($target) -or [IO.Path]::GetFileName($backup) -notmatch ('\.wsm-assistive-backup-'+[regex]::Escape($Item.ItemId.Substring(0,12))+'-[a-f0-9]{32}$'))){throw 'Assistive backup recovery path is not the exact generated sibling.'}
    foreach($path in @($root,$target,$staging,$backup)){if($path){Assert-WsmNoReparse $path}}
    foreach($filePath in @($target,$staging,$backup)){
        if($filePath -and [IO.Directory]::Exists($filePath)){throw 'Assistive file recovery found a directory in a file transaction path; retain the pending intent and all material.'}
    }
    $hashAt={param([string]$Path) if($Path -and [IO.File]::Exists($Path)){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}}
    $targetHash=& $hashAt $target;$stageHash=& $hashAt $staging;$backupHash=& $hashAt $backup
    $expected=[string]$Operation.ExpectedHash;$previous=[string]$Operation.PreviousHash
    if($expected -notmatch '^[a-fA-F0-9]{64}$' -or ($Operation.WasOwned -and ($previous -notmatch '^[a-fA-F0-9]{64}$' -or -not $Operation.PriorOwner -or -not $Operation.PriorOwner.PSObject.Properties['MetadataHash'])) -or -not $Operation.PSObject.Properties['ExpectedMetadata']){throw 'Assistive file recovery hashes or metadata intent are incomplete.'}
    $aclPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$aclPolicy=[string]$spec.AclControlPolicy}
    if($targetHash -ne $expected){
        if($targetHash -and $targetHash -ne $previous){throw 'Assistive target file drifted from both prior and desired hashes; preserve all transaction material.'}
        if($targetHash -ceq $previous -and -not $backupHash -and -not $stageHash){
            if($Operation.WasOwned){
                $priorReadback=Get-WsmFileMetadata $target ([string]$Operation.ExpectedMetadata.MetadataMode)
                if((Get-WsmAssistiveMetadataHash $priorReadback) -ine [string]$Operation.PriorOwner.MetadataHash){throw 'Assistive prior owned file metadata drifted; preserve the pending recovery intent.'}
            }
            $State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId);Add-WsmJournal $Paths $State 'AssistiveFileRecovered' $Item.ItemId ([pscustomobject]@{Record=$null;Abandoned=$true;TargetUnchanged=$true;RelativePath=$Operation.RelativePath;Target=$target;RetainedStaging=''});return
        }
        if($stageHash -ne $expected){throw 'Assistive target and staging file do not match a recoverable exact hash state.'}
        [void](Assert-WsmAssistiveMetadataReadback $staging $Operation.ExpectedMetadata $SidMap $aclPolicy)
        if($Operation.WasOwned -and -not $backupHash){
            if($targetHash -ne $previous){throw 'Owned Assistive prior file is missing before its backup move.'}
            $priorMetadata=Get-WsmFileMetadata $target $Operation.ExpectedMetadata.MetadataMode;if((Get-WsmAssistiveMetadataHash $priorMetadata) -ine [string]$Operation.PriorOwner.MetadataHash){throw 'Owned Assistive prior file metadata drifted before recovery; preserve all transaction material.'}
            $backup=[string]$Operation.Backup;if(-not $backup){throw 'Owned Assistive transaction has no durable backup path.'}
            [IO.File]::Move($target,$backup);$backupHash=& $hashAt $backup
        }
        if($Operation.WasOwned -and $backupHash -ne $previous){throw 'Assistive retained backup differs from exact prior-owned bytes.'}
        if($Operation.WasOwned){$priorMetadata=Get-WsmFileMetadata $backup $Operation.ExpectedMetadata.MetadataMode;if((Get-WsmAssistiveMetadataHash $priorMetadata) -ine [string]$Operation.PriorOwner.MetadataHash){throw 'Assistive retained backup metadata differs from the prior ownership baseline.'}}
        [IO.File]::Move($staging,$target);$targetHash=& $hashAt $target
    }
    if($targetHash -ne $expected){throw 'Assistive file recovery readback differs from the approved artifact hash.'}
    $actualMetadata=Assert-WsmAssistiveMetadataReadback $target $Operation.ExpectedMetadata $SidMap $aclPolicy
    if($Operation.WasOwned -and $backupHash -ne $previous){throw 'Assistive file recovery lacks the verified prior backup required for rollback.'}
    if($Operation.WasOwned){$priorMetadata=Get-WsmFileMetadata $backup $Operation.ExpectedMetadata.MetadataMode;if((Get-WsmAssistiveMetadataHash $priorMetadata) -ine [string]$Operation.PriorOwner.MetadataHash){throw 'Assistive retained backup metadata differs from the prior ownership baseline.'}}
    $prior=@($State.Items | Where-Object ItemId -CEQ $Item.ItemId);$record=$null;if($prior.Count -eq 1){$record=$prior[0]}else{$record=[pscustomobject]@{ItemId=$Item.ItemId;Status='Partial';CreatedByTool=$true;OwnedFiles=@();OwnedDirectories=@();AppliedManifestHash='';AppliedGeneration=0;Target=$root;Error='Recovered one per-file transaction; full scope remains to be reconciled.'}}
    $backupMaterialId='';if($Operation.PSObject.Properties['BackupMaterialId']){$backupMaterialId=[string]$Operation.BackupMaterialId};$files=@($record.OwnedFiles | Where-Object RelativePath -CNE ([string]$Operation.RelativePath));$files+=,[pscustomobject]@{RelativePath=[string]$Operation.RelativePath;TargetPath=$target;SHA256=$expected;MetadataHash=(Get-WsmAssistiveMetadataHash $actualMetadata);Backup=$backup;BackupHash=$previous;BackupMetadata=$(if($Operation.PSObject.Properties['PreviousMetadata']){$Operation.PreviousMetadata}else{$null});BackupMetadataHash=$(if($Operation.PSObject.Properties['PreviousMetadataHash']){[string]$Operation.PreviousMetadataHash}else{''});BackupMaterialId=$backupMaterialId;Generation=[long]$Package.Manifest.Generation};$record.OwnedFiles=$files;$record.Status='Partial';$record.CreatedByTool=$true;$record.AppliedManifestHash='';$record.Error='Recovered exact per-file transaction; full scope remains to be reconciled.';$State.Items=@($State.Items | Where-Object ItemId -CNE $Item.ItemId)+@($record)
    $State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId);Add-WsmJournal $Paths $State 'AssistiveFileRecovered' $Item.ItemId ([pscustomobject]@{Record=$record;RelativePath=$Operation.RelativePath;Target=$target;SHA256=$expected;Backup=$backup;BackupHash=$previous});$record
}

function Complete-WsmAssistiveFileScopeOwnershipRepair($Item,$Package,$Paths,$State,[hashtable]$SidMap=@{}) {
    # P9：對帳「ownership 不完整」的先前 FileScope 紀錄（見 Test-WsmAssistiveFileScopeOwnershipIncomplete）。逐檔只有兩種可以補：
    #   目標檔不存在：視為未寫入，不建立 ownership，讓下次還原正常寫入。
    #   目標檔存在，且磁碟內容雜湊等於封存 artifact 的雜湊（Data.Hash）：補登，但記為 Ownership='AdoptedExisting'（沿用既有檔，P10）。
    #     這條路徑沒有 journal 或 intent 能證明是工具寫的（內容相同不等於工具寫入，也可能是外部事先放好的同內容檔），所以回復（rollback）一律不刪除、不覆寫、不改 ACL；
    #     只有 AssistiveFileIntent／AssistiveFileReplace 之類有證據的寫入路徑才記為工具擁有（沒有 Ownership 欄位）。
    # 其餘一律保守：內容不同、reparse（含上層）、目錄佔用檔案位置、權限讀不到或拓樸不支援，都記為衝突、保留原檔，不補、不覆寫、不刪除。
    # 有任何衝突時，紀錄帶 ReconcileConflicts，共用判定仍視為不完整（需人工處理後再執行修復）；沒有衝突時才變回可還原。
    # 本函式不寫入、不刪除任何目標檔，只更新 state 並以 AssistiveFileRecovered 記錄（replay 沿用既有處理：以 Record 取代該項目紀錄）。
    $spec=$Item.MigrationSpec;$itemId=[string]$Item.ItemId
    if($spec.Adapter -cne 'FileScope'){throw 'Assistive FileScope ownership reconcile is not a FileScope item.'}
    if(@($State.PendingOperations | Where-Object ItemId -CEQ $itemId).Count){throw 'Repair the pending file intent of this item before reconciling its FileScope ownership.'}
    $prior=@($State.Items | Where-Object ItemId -CEQ $itemId)
    $manual={param([string]$Reason)[pscustomobject]@{ItemId=$itemId;Status='ManualRequired';Adopted=@();Absent=@();Conflicts=@([pscustomobject]@{RelativePath='';Reason=$Reason})}}
    if($prior.Count -ne 1){return (& $manual 'The state holds no single record for this item; nothing was changed.')}
    $root=ConvertTo-WsmCanonicalPath ([string]$spec.TargetPath)
    $entries=@(Read-WsmArtifactLines (Join-Path $Package.Root 'artifacts.jsonl') $Package.Manifest.ArtifactsHash | Where-Object {[string]$_.ItemId -ceq $itemId})
    if(-not $entries.Count){return (& $manual 'The package holds no artifact for this item; nothing was changed.')}
    $single=($entries.Count -eq 1 -and -not $entries[0].Directory -and [string]::IsNullOrEmpty([string]$entries[0].RelativePath))
    $aclPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$aclPolicy=[string]$spec.AclControlPolicy}
    $files=New-Object 'System.Collections.Generic.List[object]';$directories=@()
    if($prior[0].PSObject.Properties['OwnedFiles']){foreach($known in @($prior[0].OwnedFiles)){$files.Add($known)}}
    if($prior[0].PSObject.Properties['OwnedDirectories']){$directories=@($prior[0].OwnedDirectories)}
    $adopted=New-Object 'System.Collections.Generic.List[string]';$absent=New-Object 'System.Collections.Generic.List[string]';$conflicts=New-Object 'System.Collections.Generic.List[object]'
    foreach($entry in @($entries | Where-Object {-not $_.Directory})){
        $relative=[string]$entry.RelativePath;$label=$(if($relative){$relative}else{'(single file)'})
        if(@($files | Where-Object {[string]$_.RelativePath -ceq $relative}).Count){continue}
        try{
            $dest=$root;if($relative){$dest=Join-Path $root $relative}
            Assert-WsmNoReparse $dest
            if([IO.Directory]::Exists($dest)){$conflicts.Add([pscustomobject]@{RelativePath=$label;Reason='A directory occupies the file path; preserved.'});continue}
            if(-not [IO.File]::Exists($dest)){$absent.Add($label);continue}
            $hash=(Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
            if($hash -cne ([string]$entry.Data.Hash).ToLowerInvariant()){$conflicts.Add([pscustomobject]@{RelativePath=$label;Reason='Existing file content differs from the sealed backup; preserved and not adopted.'});continue}
            Assert-WsmAssistiveTargetScopeTopology -Path $dest -Spec $spec -TargetRoot $root -Artifact $entry -Kind File -Destination $dest
            $metadata=Get-WsmFileMetadata $dest ([string]$entry.Metadata.MetadataMode)
            $files.Add([pscustomobject]@{RelativePath=$relative;TargetPath=$dest;SHA256=$hash;MetadataHash=(Get-WsmAssistiveMetadataHash $metadata);Backup='';BackupHash='';BackupMetadata=$null;BackupMetadataHash='';BackupMaterialId='';Generation=[long]$Package.Manifest.Generation;Ownership='AdoptedExisting'})
            $adopted.Add($label)
        }catch{$why=$(if([string]$_.Exception.Message -match 'Reparse point'){'A reparse point is on the target path; preserved and not adopted.'}else{'Target path could not be verified safely ('+$_.Exception.GetType().Name+'); preserved and not adopted.'});$conflicts.Add([pscustomobject]@{RelativePath=$label;Reason=$why})}
    }
    $fileArray=@();foreach($fileRecord in $files){$fileArray+=@($fileRecord)}
    $note=$(if($conflicts.Count){'Ownership reconciled for exact backup-hash files only; unresolved conflicts need manual handling, then run Repair again.'}else{'Ownership reconciled: only files whose bytes equal the sealed backup were adopted; absent files stay unwritten.'})
    $record=[pscustomobject][ordered]@{ItemId=$itemId;Status='Partial';CreatedByTool=$true;AppliedManifestHash='';AppliedGeneration=[long]0;ActualHash=(Get-WsmAssistiveFileOwnershipHash $fileArray);Target=$root;OwnedFiles=$fileArray;OwnedDirectories=@($directories);Error=$note;NativeCode=0}
    if($conflicts.Count){$record | Add-Member NoteProperty ReconcileConflicts @($conflicts.ToArray())}
    $State.Items=@($State.Items | Where-Object ItemId -CNE $itemId)+@($record)
    Add-WsmJournal $Paths $State 'AssistiveFileRecovered' $itemId ([pscustomobject]@{Record=$record;RelativePath='';Target=$root;Reconciled=$true;Adopted=@($adopted.ToArray());Absent=@($absent.ToArray());Conflicts=@($conflicts.ToArray())})
    [pscustomobject]@{ItemId=$itemId;Status=$(if($conflicts.Count){'ManualRequired'}else{'Reconciled'});Adopted=@($adopted.ToArray());Absent=@($absent.ToArray());Conflicts=@($conflicts.ToArray());AdoptedNote=$(if($adopted.Count){Get-WsmAssistiveAdoptedExistingNote}else{''})}
}

function Complete-WsmSettingTransitionRecovery($Item,$Operation,$Paths,$State) {
    $spec=$Item.MigrationSpec;$transition=$spec.SettingTransition
    if(-not $transition -or $Operation.TransitionHash -ine $transition.TransitionHash){throw 'SettingTransition pending operation does not match the approved plan/checkpoint.'}
    Assert-WsmSettingTransition $transition | Out-Null
    if(-not $Operation.Intent){throw 'SettingTransition has no durable intent; preserve state for manual reconciliation.'}
    Assert-WsmSettingTransitionIntent $transition $Operation.Intent $State.TargetFingerprint
    if($Operation.RequiredPhase -cne $transition.RequiredPhase){throw 'SettingTransition required phase differs from its durable intent.'}
    $current=Get-WsmSettingNativeSnapshot $transition
    if($Operation.Receipt) {
        $receipt=$Operation.Receipt
        if($receipt.TransitionHash -ine $transition.TransitionHash -or $receipt.IntentId -cne $Operation.Intent.IntentId -or $receipt.Action -cne $transition.Action -or $receipt.TargetFingerprint -ine $State.TargetFingerprint -or (Get-WsmSettingTransitionReceiptHash $receipt) -ine [string]$receipt.ReceiptHash -or -not (Test-WsmSettingStateEqual $receipt.Before $Operation.Intent.Prior $transition.Adapter) -or -not (Test-WsmSettingStateEqual $receipt.After $transition.After $transition.Adapter) -or -not (Test-WsmSettingStateEqual $current $transition.After $transition.Adapter)){throw 'Durable SettingTransition receipt does not match exact current native state.'}
        $receipt | Add-Member NoteProperty Intent $Operation.Intent -Force
    } elseif(Test-WsmSettingStateEqual $current $transition.After $transition.Adapter) {
        if($transition.Action -in @('KeepTarget','VerifyExternal')){$receipt=Invoke-WsmSettingTransitionApply -Transition $transition -Intent $Operation.Intent -TargetFingerprint $State.TargetFingerprint -JournalHash $State.JournalHash}
        else{$receipt=New-WsmSettingTransitionRecoveredReceipt -Transition $transition -Intent $Operation.Intent -TargetFingerprint $State.TargetFingerprint -JournalHash $State.JournalHash}
        $Operation.Receipt=$receipt
        Add-WsmJournal $Paths $State 'SettingTransitionReceipt' $Item.ItemId ([pscustomobject]@{ManifestHash=$Operation.ManifestHash;TransitionHash=$transition.TransitionHash;Receipt=$receipt;Recovery='ExactAfterReadback';RequiredPhase=$Operation.RequiredPhase})
        $receipt | Add-Member NoteProperty Intent $Operation.Intent -Force
    } elseif(Test-WsmSettingStateEqual $current $Operation.Intent.Prior $transition.Adapter) {
        $receipt=Invoke-WsmSettingTransitionApply -Transition $transition -Intent $Operation.Intent -TargetFingerprint $State.TargetFingerprint -JournalHash $State.JournalHash
        $Operation.Receipt=$receipt
        Add-WsmJournal $Paths $State 'SettingTransitionReceipt' $Item.ItemId ([pscustomobject]@{ManifestHash=$Operation.ManifestHash;TransitionHash=$transition.TransitionHash;Receipt=$receipt;Recovery='ReplayedFromExactPrior';RequiredPhase=$Operation.RequiredPhase})
        $receipt | Add-Member NoteProperty Intent $Operation.Intent -Force
    } else {throw 'SettingTransition native state is neither the durable prior nor reviewed after value; manual reconciliation required.'}
    $record=@($State.Items | Where-Object ItemId -CEQ $Item.ItemId)
    $result=[pscustomobject]@{ItemId=$Item.ItemId;Status='Succeeded';CreatedByTool=($transition.Action -eq 'CreateNew');UpdatedByTool=($transition.Action -eq 'UpdateReviewed');ActualHash=(Get-WsmHashText ($receipt | ConvertTo-Json -Depth 20 -Compress));Backup='';Target='';Error='';NativeCode=0;SettingTransitionDeferred=$false;SettingTransitionIntent=$Operation.Intent;SettingTransitionReceipt=$receipt}
    $State.Items=@($State.Items | Where-Object ItemId -CNE $Item.ItemId)+@($result)
    $State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)
    Add-WsmJournal $Paths $State 'SettingTransitionRecovered' $Item.ItemId ([pscustomobject]@{TransitionHash=$transition.TransitionHash;IntentId=$Operation.Intent.IntentId;Receipt=$receipt;ActualHash=$result.ActualHash})
}

function Remove-WsmAssistiveRolledBackOwnership($State,[string]$ItemId,[string[]]$ReleasedFiles) {
    # R2：回復完成時，讓該項目的逐檔／目錄擁有紀錄失效。即時回復（Complete-WsmAssistiveFileRollback）與 journal 重播（AssistiveRollbackOwnershipReleased）呼叫同一個函式，結果必然相同。
    #   OwnedFiles：移除這次回復向量內的檔案（以 RelativePath 比對）；沒有被列入的列（沿用既有檔 AdoptedExisting，回復時不動它）原樣保留。
    #   OwnedDirectories：全部清空（回復已還原或移除目錄，metadata 基準失效；留著會讓再還原時以「目錄 metadata 已變動」擋下）。
    #   ActualHash：若紀錄原本就有，依剩下的檔案重算（與寫入器同一個 Get-WsmAssistiveFileOwnershipHash）。
    #   Status、CreatedByTool 仍由 RollbackCompleted 設定。已存在的屬性用直接賦值，避免 Add-Member 改變屬性順序而讓即時與重播的 JSON 不同。
    $released=@{};foreach($relative in @($ReleasedFiles)){$released[[string]$relative]=$true}
    foreach($row in @($State.Items | Where-Object {[string]$_.ItemId -ceq $ItemId})){
        $kept=@();if($row.PSObject.Properties['OwnedFiles']){$kept=@($row.OwnedFiles | Where-Object {-not $released.ContainsKey([string]$_.RelativePath)})}
        if($row.PSObject.Properties['OwnedFiles']){$row.OwnedFiles=$kept}else{$row | Add-Member NoteProperty OwnedFiles $kept -Force}
        if($row.PSObject.Properties['OwnedDirectories']){$row.OwnedDirectories=@()}else{$row | Add-Member NoteProperty OwnedDirectories @() -Force}
        if($row.PSObject.Properties['ActualHash']){$row.ActualHash=(Get-WsmAssistiveFileOwnershipHash $kept)}
    }
}
function Complete-WsmAssistiveFileRollback($Item,$Operation,$Paths,$State) {
    $spec=$Item.MigrationSpec;$root=ConvertTo-WsmCanonicalPath ([string]$spec.TargetPath);$prefix=$root.TrimEnd('\')+'\'
    if(-not $Operation.PSObject.Properties['Files'] -or -not $Operation.PSObject.Properties['Directories'] -or $Operation.Files -isnot [array] -or $Operation.Directories -isnot [array]){throw 'Assistive rollback intent is missing its exact per-file/directory ownership vectors.'}
    foreach($directory in @($Operation.Directories)){if(-not [IO.Directory]::Exists([string]$directory.TargetPath)){if(-not $directory.CreatedByTool){throw 'Previously owned Assistive directory is absent during rollback.'};continue};$live=Get-WsmFileMetadata ([string]$directory.TargetPath) $spec.Metadata;if(-not $directory.CreatedByTool -and $directory.BackupMetadataHash -and (Get-WsmAssistiveMetadataHash $live) -ieq [string]$directory.BackupMetadataHash){continue};$expected=$directory.CurrentMetadata;if(-not $expected -or $live.Sddl -cne $expected.Sddl -or [int]$live.Attributes -ne [int]$expected.Attributes -or [string]$live.CreationUtc -cne [string]$expected.CreationUtc){throw ('Assistive directory ACL, owner, attributes or creation time drifted after rollback preview: '+[string]$directory.TargetPath)}}
    foreach($file in @($Operation.Files)){
        $target=[IO.Path]::GetFullPath([string]$file.TargetPath);$retained=[IO.Path]::GetFullPath([string]$file.Retained);$backup='';if($file.Backup){$backup=[IO.Path]::GetFullPath([string]$file.Backup)}
        if(($target -ine $root -and -not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) -or [IO.Path]::GetDirectoryName($retained) -ine [IO.Path]::GetDirectoryName($target) -or [IO.Path]::GetFileName($retained) -notlike '.wsm-assistive-rollback-*'){throw 'Assistive per-file rollback path escapes its approved target scope.'}
        if($backup -and ([IO.Path]::GetDirectoryName($backup) -ine [IO.Path]::GetDirectoryName($target) -or [IO.Path]::GetFileName($backup) -notmatch ('\.wsm-assistive-backup-'+[regex]::Escape($Item.ItemId.Substring(0,12))+'-[a-f0-9]{32}$'))){throw 'Assistive prior-file backup is not the exact generated sibling.'}
        foreach($path in @($target,$retained,$backup)){if($path){Assert-WsmNoReparse $path}}
        $hashAt={param([string]$Path) if($Path -and [IO.File]::Exists($Path)){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}else{''}}
        $targetHash=& $hashAt $target;$retainedHash=& $hashAt $retained;$backupHash=& $hashAt $backup;$currentHash=[string]$file.CurrentHash
        if($retainedHash -and $retainedHash -ine $currentHash){throw 'Displaced Assistive file differs from the exact current-generation bytes.'}
        if($targetHash -eq $currentHash){$live=Get-WsmFileMetadata $target $spec.Metadata;if((Get-WsmAssistiveMetadataHash $live) -ine [string]$file.CurrentMetadataHash){throw 'Current Assistive file metadata drifted after rollback preview.'};if(-not $retainedHash){[IO.File]::Move($target,$retained);$retainedHash=& $hashAt $retained;$targetHash='';Add-WsmJournal $Paths $State 'AssistiveRollbackFileDisplaced' $Item.ItemId ([pscustomobject]@{Target=$target;Retained=$retained;Hash=$currentHash})}}
        elseif($targetHash -and $targetHash -eq [string]$file.BackupHash -and $retainedHash -eq $currentHash -and -not $backupHash){$livePrior=Get-WsmFileMetadata $target $spec.Metadata;if((Get-WsmAssistiveMetadataHash $livePrior) -ine [string]$file.BackupMetadataHash){if(-not $file.BackupMetadata){throw 'Restored prior Assistive file metadata does not match its recorded prior ownership baseline.'};Set-WsmFileMetadata $target $file.BackupMetadata @{};$livePrior=Get-WsmFileMetadata $target $spec.Metadata;if((Get-WsmAssistiveMetadataHash $livePrior) -ine [string]$file.BackupMetadataHash){throw 'Interrupted prior Assistive file metadata restore failed readback.'}};continue}
        elseif($targetHash){throw 'Assistive rollback target differs from both current owned content and exact prior content.'}
        if($backup){
            if($backupHash -ne [string]$file.BackupHash){throw 'Assistive prior-file backup is missing or has drifted.'}
            $priorMetadata=Get-WsmFileMetadata $backup $spec.Metadata;if((Get-WsmAssistiveMetadataHash $priorMetadata) -ine [string]$file.BackupMetadataHash){throw 'Assistive prior-file backup metadata differs from its retained ownership baseline.'}
            if(-not [IO.File]::Exists($target)){[IO.File]::Move($backup,$target);if($file.BackupMetadata){Set-WsmFileMetadata $target $file.BackupMetadata @{} };$targetHash=& $hashAt $target;$priorMetadata=Get-WsmFileMetadata $target $spec.Metadata;if($targetHash -ine [string]$file.BackupHash -or (Get-WsmAssistiveMetadataHash $priorMetadata) -ine [string]$file.BackupMetadataHash){throw 'Restored prior Assistive file failed exact bytes/metadata readback.'};Add-WsmJournal $Paths $State 'AssistiveRollbackFileRestored' $Item.ItemId ([pscustomobject]@{Target=$target;BackupHash=$targetHash;MetadataHash=$file.BackupMetadataHash})}
        }elseif(-not [IO.File]::Exists($target) -and $retainedHash -eq $currentHash){Add-WsmJournal $Paths $State 'AssistiveRollbackNewFileRetained' $Item.ItemId ([pscustomobject]@{Target=$target;Retained=$retained;Hash=$currentHash})}
        else{throw 'Assistive rollback cannot prove a safe exact prior file state.'}
    }
    foreach($directory in @($Operation.Directories | Sort-Object @{Expression={if($_.RelativePath){$_.RelativePath.Split([char]92).Count}else{0}};Descending=$true})){
        $path=[IO.Path]::GetFullPath([string]$directory.TargetPath);if(($path -ine $root -and -not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase))){throw 'Assistive rollback directory escapes its approved target scope.'};Assert-WsmNoReparse $path
        if(-not [IO.Directory]::Exists($path)){if($directory.CreatedByTool){Add-WsmJournal $Paths $State 'AssistiveRollbackDirectoryAbsent' $Item.ItemId ([pscustomobject]@{Target=$path});continue};throw 'Previously owned Assistive directory is absent during rollback.'}
        $actual=Get-WsmFileMetadata $path $spec.Metadata;$actualHash=Get-WsmAssistiveMetadataHash $actual
        if($actualHash -eq [string]$directory.BackupMetadataHash -and $directory.BackupMetadataHash){continue}
        $expectedCurrent=$directory.CurrentMetadata;if(-not $expectedCurrent -or $actual.Sddl -cne $expectedCurrent.Sddl -or [int]$actual.Attributes -ne [int]$expectedCurrent.Attributes -or [string]$actual.CreationUtc -cne [string]$expectedCurrent.CreationUtc){throw 'Assistive directory ACL, owner, attributes or creation time drifted during rollback.'}
        if($directory.CreatedByTool){if(@([IO.Directory]::EnumerateFileSystemEntries($path)).Count -eq 0){[IO.Directory]::Delete($path);Add-WsmJournal $Paths $State 'AssistiveRollbackDirectoryRemoved' $Item.ItemId ([pscustomobject]@{Target=$path})}else{Add-WsmJournal $Paths $State 'AssistiveRollbackDirectoryRetainedExternalContent' $Item.ItemId ([pscustomobject]@{Target=$path;Reason='Directory contains content not owned by this operation.'})};continue}
        if(-not $directory.BackupMetadata -or -not $directory.BackupMetadataHash){throw 'Existing Assistive directory has no exact prior metadata snapshot; rollback is blocked.'}
        Set-WsmFileMetadata $path $directory.BackupMetadata @{};$restored=Get-WsmFileMetadata $path $spec.Metadata;if((Get-WsmAssistiveMetadataHash $restored) -ine [string]$directory.BackupMetadataHash){throw 'Assistive directory prior metadata restoration failed native readback.'};Add-WsmJournal $Paths $State 'AssistiveRollbackDirectoryMetadataRestored' $Item.ItemId ([pscustomobject]@{Target=$path;MetadataHash=$directory.BackupMetadataHash})
    }
    # Parent metadata restoration may propagate ACLs after an earlier child readback.
    # Do not retire the ownership or durable intent until every final prior state matches.
    foreach($file in @($Operation.Files)){
        $path=[IO.Path]::GetFullPath([string]$file.TargetPath);Assert-WsmNoReparse $path
        if($file.Backup){
            if(-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$file.BackupHash -or (Get-WsmAssistiveMetadataHash (Get-WsmFileMetadata $path $spec.Metadata)) -ine [string]$file.BackupMetadataHash){throw 'Final prior Assistive file bytes or metadata changed after directory rollback.'}
        }elseif([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)){throw 'Final Assistive new-file rollback target is no longer absent.'}
    }
    foreach($directory in @($Operation.Directories | Where-Object {-not $_.CreatedByTool})){
        $path=[IO.Path]::GetFullPath([string]$directory.TargetPath);Assert-WsmNoReparse $path
        if(-not [IO.Directory]::Exists($path) -or (Get-WsmAssistiveMetadataHash (Get-WsmFileMetadata $path $spec.Metadata)) -ine [string]$directory.BackupMetadataHash){throw 'Final prior Assistive directory metadata changed after parent rollback.'}
    }
    $record=@($State.Items | Where-Object ItemId -CEQ $Item.ItemId);if($record.Count -ne 1){throw 'Assistive rollback record disappeared.'}
    # R2：回復完成後，這次回復處理過的逐檔擁有紀錄與全部目錄擁有紀錄都已失效（檔案被移走或還原成先前內容、目錄 metadata 已還原）。
    # 不清掉的話，再還原時寫入器會把「有擁有紀錄但檔案不存在」判為 BlockedConflict。沿用既有檔（AdoptedExisting）不在回復向量內，紀錄保留，再還原時仍視為已存在的同內容檔。
    # 先寫專屬 journal 事件（重播以同一個函式取得相同結果），再寫 RollbackCompleted；兩個事件之間中斷時，pending 回復意圖仍在，Repair 重跑本函式是冪等的。
    $releasedFiles=[string[]]@($Operation.Files | ForEach-Object {[string]$_.RelativePath});$releasedDirectories=[string[]]@($Operation.Directories | ForEach-Object {[string]$_.RelativePath})
    Remove-WsmAssistiveRolledBackOwnership $State ([string]$Item.ItemId) $releasedFiles
    Add-WsmJournal $Paths $State 'AssistiveRollbackOwnershipReleased' $Item.ItemId ([pscustomobject]@{ItemId=[string]$Item.ItemId;ReleasedFiles=$releasedFiles;ReleasedDirectories=$releasedDirectories})
    $record[0].Status='RolledBack';$record[0].CreatedByTool=$false;$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId);Add-WsmJournal $Paths $State 'RollbackCompleted' $Item.ItemId ([pscustomobject]@{Status='RolledBack';PerFile=$true;ExternalContentRetained=$true})
}

function Complete-WsmFileRollback($Item,$Operation,$Paths,$State) {
    $target=ConvertTo-WsmCanonicalPath $Item.MigrationSpec.TargetPath;$parent=[IO.Path]::GetDirectoryName($target)
    if($Operation.Target -ine $target -or [IO.Path]::GetDirectoryName($Operation.Retained) -ine $parent -or [IO.Path]::GetFileName($Operation.Retained) -notlike '.wsm-rollback-retained-*'){throw 'Rollback intent escapes approved target parent.'}
    if($Operation.Backup -and ([IO.Path]::GetDirectoryName($Operation.Backup) -ine $parent -or [IO.Path]::GetFileName($Operation.Backup) -notlike '.wsm-backup-*')){throw 'Rollback backup escapes approved target parent.'}
    foreach($path in @($target,$Operation.Retained,$Operation.Backup)){if($path){Assert-WsmNoReparse $path}}
    $metadata=$Item.MigrationSpec.Metadata;$current=Get-WsmFileScopeDigest $target $metadata;$retained=Get-WsmFileScopeDigest $Operation.Retained $metadata
    if($current -ceq $Operation.CurrentHash -and -not $retained){if([IO.Directory]::Exists($target)){[IO.Directory]::Move($target,$Operation.Retained)}else{[IO.File]::Move($target,$Operation.Retained)};$current='';$retained=$Operation.CurrentHash}
    if($retained -cne $Operation.CurrentHash){throw 'Displaced rollback target missing or drifting; preserve all roots and reconcile.'}
    if(-not $current -and $Operation.Backup){$backupHash=Get-WsmFileScopeDigest $Operation.Backup $metadata;if($backupHash -cne $Operation.BackupHash){throw 'Rollback backup drifted; restore blocked.'};if([IO.Directory]::Exists($Operation.Backup)){[IO.Directory]::Move($Operation.Backup,$target)}else{[IO.File]::Move($Operation.Backup,$target)};$current=Get-WsmFileScopeDigest $target $metadata}
    if($current -cne $Operation.BackupHash){throw 'Rollback target differs from approved previous root.'}
    $record=@($State.Items | Where-Object ItemId -CEQ $Item.ItemId)[0];$record.Status='RolledBack';$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)
    Add-WsmJournal $Paths $State RollbackCompleted $Item.ItemId ([pscustomobject]@{Status='RolledBack';Retained=$Operation.Retained})
}
function Complete-WsmAdapterRollback($Item,$Operation,$Paths,$State) {
    $spec=$Item.MigrationSpec;$record=@($State.Items | Where-Object ItemId -CEQ $Item.ItemId)
    if($record.Count -ne 1 -or -not (Test-WsmRollbackRecordOwnership $record[0] $spec) -or $Operation.Adapter -cne $spec.Adapter -or $spec.Adapter -in @('FileScope','WindowsFeature','ManualWorkflow') -or $Operation.SpecHash -cne (Get-WsmHashText ($spec | ConvertTo-Json -Depth 40 -Compress))){throw 'Adapter rollback ownership/spec mismatch.'}
    if($spec.PSObject.Properties['SettingTransition']) {
        $transition=$spec.SettingTransition;Assert-WsmSettingTransition $transition | Out-Null
        if($Operation.TransitionHash -ine $transition.TransitionHash -or -not $Operation.SettingTransitionIntent -or -not $Operation.SettingTransitionReceipt -or -not $Operation.SettingTransitionRollbackIntent){throw 'SettingTransition rollback lacks its exact durable intent/receipt/rollback intent.'}
        $intent=$Operation.SettingTransitionIntent;$receipt=$Operation.SettingTransitionReceipt
        Assert-WsmSettingTransitionIntent $transition $intent $State.TargetFingerprint
        if($receipt.Status -notin @('Applied','RecoveredApplied') -or $receipt.Action -cne $transition.Action -or $receipt.TargetFingerprint -ine $State.TargetFingerprint -or $receipt.TransitionHash -ine $transition.TransitionHash -or $receipt.IntentId -cne $intent.IntentId -or (Get-WsmSettingTransitionReceiptHash $receipt) -ine [string]$receipt.ReceiptHash){throw 'SettingTransition rollback receipt integrity check failed.'}
        if($record[0].SettingTransitionReceipt.ReceiptHash -ine $receipt.ReceiptHash -or $record[0].SettingTransitionIntent.IntentHash -ine $intent.IntentHash){throw 'SettingTransition rollback differs from the completed operation record.'}
        $current=Get-WsmSettingNativeSnapshot $transition
        if($Operation.SettingTransitionRollbackIntent.TransitionHash -ine $transition.TransitionHash -or $Operation.SettingTransitionRollbackIntent.IntentId -cne $intent.IntentId -or $Operation.SettingTransitionRollbackIntent.TargetFingerprint -ine $State.TargetFingerprint -or $Operation.SettingTransitionRollbackIntent.ManifestHash -ine $Operation.ManifestHash -or $Operation.SettingTransitionRollbackIntent.ReceiptHash -ine $receipt.ReceiptHash -or -not (Test-WsmSettingStateEqual $Operation.SettingTransitionRollbackIntent.ExpectedCurrent $receipt.After $transition.Adapter) -or -not (Test-WsmSettingStateEqual $Operation.SettingTransitionRollbackIntent.RestorePrior $intent.Prior $transition.Adapter)){throw 'Durable SettingTransition rollback intent binding mismatch.'}
        if(Test-WsmSettingStateEqual $current $intent.Prior $transition.Adapter) {
            # A prior crash may have restored the value after the durable rollback intent.
            $rollbackReceipt=[pscustomobject]@{Kind='SettingTransitionRollbackReceipt';Status='RecoveredPriorReadback';TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId;RollbackJournalHash=$State.JournalHash;TargetFingerprint=$State.TargetFingerprint;Restored=$current;ReadbackUtc=(Get-WsmUtc)}
            Add-WsmJournal $Paths $State 'SettingTransitionRollbackReceipt' $Item.ItemId ([pscustomobject]@{Receipt=$rollbackReceipt;Recovery='ExactPriorReadback'})
        } elseif(Test-WsmSettingStateEqual $current $receipt.After $transition.Adapter) {
            $rollbackIntent=[pscustomobject]@{TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId;TargetFingerprint=$State.TargetFingerprint;ExpectedCurrent=$receipt.After;RestorePrior=$intent.Prior;ReceiptHash=$receipt.ReceiptHash;ManifestHash=$Operation.ManifestHash}
            $Operation.SettingTransitionRollbackIntent=$rollbackIntent
            Add-WsmJournal $Paths $State 'SettingTransitionRollbackIntent' $Item.ItemId $rollbackIntent
            $rollbackReceipt=Invoke-WsmSettingTransitionRollback -Transition $transition -Intent $intent -Receipt $receipt -TargetFingerprint $State.TargetFingerprint -RollbackJournalHash $State.JournalHash
            $Operation | Add-Member NoteProperty SettingTransitionRollbackReceipt $rollbackReceipt -Force
            Add-WsmJournal $Paths $State 'SettingTransitionRollbackReceipt' $Item.ItemId ([pscustomobject]@{Receipt=$rollbackReceipt;TransitionHash=$transition.TransitionHash;IntentId=$intent.IntentId})
        } else {throw 'SettingTransition drifted from exact after and prior values; rollback refused.'}
        $record[0].Status='RolledBack';$record[0].CreatedByTool=$false;$record[0] | Add-Member NoteProperty UpdatedByTool $false -Force;$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)
        Add-WsmJournal $Paths $State 'RollbackCompleted' $Item.ItemId ([pscustomobject]@{Status='RolledBack';SettingTransition=$transition.TransitionHash;RestoredPrior=$true})
        return
    }
    if($spec.Adapter -in @('IISSection','IISLocation')){
        if(-not $record[0].PSObject.Properties['Before'] -or -not $record[0].Before -or -not $record[0].Before.Xml -or -not $record[0].PSObject.Properties['PriorXml'] -or [string]$record[0].PriorXml -cne [string]$record[0].Before.Xml -or -not $record[0].PSObject.Properties['BeforeHash'] -or [string]$record[0].BeforeHash -ine (Get-WsmHashText ($record[0].Before | ConvertTo-Json -Depth 30 -Compress))){throw 'IIS configuration rollback has no matching durable exact prior XML and hash.'}
        $staged=Test-WsmAdapterConfiguration $spec Staged;$final=Test-WsmAdapterConfiguration $spec Final
        if(-not $staged.Passed -and -not $final.Passed){throw 'IIS configuration drifted from both exact staged and reviewed final XML; preserve state and reconcile before rollback.'}
        if(-not $staged.Passed){$targetFingerprint='';if($State.PSObject.Properties['TargetFingerprint']){$targetFingerprint=[string]$State.TargetFingerprint};Invoke-WsmAdapterActivation $spec $false $null ([IO.Path]::GetDirectoryName($Paths.Root)) '' $targetFingerprint;$staged=Test-WsmAdapterConfiguration $spec Staged;if(-not $staged.Passed){throw 'Reviewed IIS final state did not return to exact staged XML before restoring prior configuration.'}}
        [void](Restore-WsmIisConfigPriorXml $spec ([string]$record[0].Before.Xml))
        $record[0].Status='RolledBack';$record[0].CreatedByTool=$false;$record[0] | Add-Member NoteProperty UpdatedByTool $false -Force;$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)
        Add-WsmJournal $Paths $State 'RollbackCompleted' $Item.ItemId ([pscustomobject]@{Status='RolledBack';RestoredPrior=$true;Adapter=$spec.Adapter})
        return
    }
    $actual=Get-WsmAdapterState $spec
    $receipts=@();if($spec.Adapter -eq 'ScheduledTask'){$receipts=Get-WsmTaskSecurityReceiptsForSpec $spec (Get-WsmTaskSecurityOwnershipReceipts $State)}elseif($record[0].PSObject.Properties['AuxiliaryOwnership']){$receipts=@($record[0].AuxiliaryOwnership)}
    if($actual.Exists){$staged=Test-WsmAdapterConfiguration $spec Staged $receipts;$final=Test-WsmAdapterConfiguration $spec Final $receipts;if(-not $staged.Passed -and -not $final.Passed){throw 'Rollback object configuration drift; retain intent and reconcile before removing.'};$targetFingerprint='';if($State.PSObject.Properties['TargetFingerprint']){$targetFingerprint=[string]$State.TargetFingerprint};Invoke-WsmAdapterActivation $spec $false $null ([IO.Path]::GetDirectoryName($Paths.Root)) '' $targetFingerprint;$staged=Test-WsmAdapterConfiguration $spec Staged $receipts;if(-not $staged.Passed){throw 'Rollback object did not reach verified disabled staging.'};Remove-WsmCreatedAdapter $spec;if((Get-WsmAdapterState $spec).Exists){throw 'Rollback adapter removal did not complete.'}}
    if($spec.Adapter -eq 'ScheduledTask' -and $receipts.Count){$beforeDelete={param($intent)$op=$Operation;if(-not $op.PSObject.Properties['FolderDeleteIntents']){$op | Add-Member NoteProperty FolderDeleteIntents @()};$op.FolderDeleteIntents+=@($intent);$detail=[pscustomobject]@{ItemId=$Item.ItemId;Adapter='ScheduledTask';ManifestHash=$Operation.ManifestHash;Phase='TaskFolderDeleteIntent';Intent=$intent;Receipt=$intent.Receipt};Add-WsmJournal $Paths $State 'TaskFolderDeleteIntent' $Item.ItemId $detail};$afterDelete={param($intent)$op=$Operation;$op.FolderDeleteIntents=@($op.FolderDeleteIntents | Where-Object OperationId -CNE $intent.OperationId);if(-not $op.PSObject.Properties['DeletedTaskFolders']){$op | Add-Member NoteProperty DeletedTaskFolders @()};$op.DeletedTaskFolders+=@($intent);$detail=[pscustomobject]@{ItemId=$Item.ItemId;Adapter='ScheduledTask';ManifestHash=$Operation.ManifestHash;Phase='TaskFolderDeleted';Intent=$intent};Add-WsmJournal $Paths $State 'TaskFolderDeleted' $Item.ItemId $detail};[void](Remove-WsmOwnedTaskFolders @($spec.Desired.FolderSecurity) $receipts @() $beforeDelete $afterDelete)}
    $record[0].Status='RolledBack';$State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId);Add-WsmJournal $Paths $State RollbackCompleted $Item.ItemId ([pscustomobject]@{Status='RolledBack';Absent=$true})
}
function Test-WsmRollbackRecordOwnership($Record,$Spec) {
    if($Record.PSObject.Properties['UpdatedByTool'] -and $Record.UpdatedByTool){
        if($Spec.Adapter -in @('IISSection','IISLocation')){
            if($Record.CreatedByTool -or -not $Record.PSObject.Properties['AppliedManifestHash'] -or -not $Record.AppliedManifestHash -or -not $Record.PSObject.Properties['Before'] -or -not $Record.Before.Exists -or -not $Record.Before.PSObject.Properties['Xml'] -or -not $Record.PSObject.Properties['PriorXml'] -or [string]$Record.PriorXml -cne [string]$Record.Before.Xml -or -not $Record.PSObject.Properties['BeforeHash'] -or [string]$Record.BeforeHash -ine (Get-WsmHashText ($Record.Before | ConvertTo-Json -Depth 30 -Compress)) -or [string]$Record.Target -cne (Get-WsmAdapterObjectIdentity $Spec)){return $false}
            if([string]$Record.ActualHash -notmatch '^[0-9a-f]{64}$'){return $false}
            try{Assert-WsmAssistiveIisConfigSpec $Spec;$candidate=Set-WsmIisConfigChanges (Read-WsmXml ([string]$Record.Before.Xml)) @($Spec.Desired.Changes);$desired=Read-WsmXml ([string]$Spec.Desired.Xml);if((ConvertTo-WsmXmlComparable $candidate.DocumentElement) -cne (ConvertTo-WsmXmlComparable $desired.DocumentElement)){return $false}}catch{return $false}
            return $true
        }
        if(-not $Spec.PSObject.Properties['SettingTransition'] -or $Spec.SettingTransition.Action -cne 'UpdateReviewed' -or -not $Record.PSObject.Properties['SettingTransitionReceipt'] -or -not $Record.SettingTransitionReceipt -or $Record.SettingTransitionReceipt.TransitionHash -ine $Spec.SettingTransition.TransitionHash -or $Record.SettingTransitionReceipt.Action -cne 'UpdateReviewed' -or $Record.SettingTransitionReceipt.CreatedByTool -or -not $Record.SettingTransitionReceipt.UpdatedByTool){throw 'Reviewed setting update has no matching durable rollback ownership receipt.'}
        return $true
    }
    if($Record.PSObject.Properties['CreatedByTool']){[bool]$Record.CreatedByTool}else{$false}
}
function Get-WsmRollbackPreview {
    param([string]$ManifestPath,[string]$ExpectedHash,[string]$StateDirectory)
    $p=Test-WsmMigrationPackage $ManifestPath $ExpectedHash;$paths=Get-WsmOperationPaths $StateDirectory $p.Manifest.PairId;$s=Get-WsmOperationState $paths $p;if(@($s.PendingOperations | Where-Object {$_.Phase -in @('RollbackPrepared','RollbackAssistiveFiles','RollbackAdapter')}).Count){throw 'Interrupted rollback requires RepairOperation before a new preview.'};if(@($s.PendingOperations | Where-Object Phase -EQ 'AdapterCreating').Count){throw 'Interrupted adapter creation requires RepairOperation before rollback preview.'};$rows=@(foreach($item in $p.Plan.Items){$r=@($s.Items | Where-Object ItemId -CEQ $item.ItemId);if($r.Count -and (Test-WsmRollbackRecordOwnership $r[0] $item.MigrationSpec) -and $r[0].Status -ne 'RolledBack'){$spec=$item.MigrationSpec;$hash='';$blocked=($spec.Adapter -eq 'WindowsFeature');$reason='';$adoptedFiles=0;$adoptedChanged=0;$ownedDirs=@();if($r[0].PSObject.Properties['OwnedDirectories']){$ownedDirs=@($r[0].OwnedDirectories)};$previewBackup='';if($r[0].PSObject.Properties['Backup']){$previewBackup=$r[0].PSObject.Properties['Backup'].Value};try{if($spec.Adapter -eq 'FileScope' -and $r[0].PSObject.Properties['OwnedFiles']){$hash=Get-WsmHashText (([pscustomobject]@{Files=@($r[0].OwnedFiles);Directories=@($ownedDirs)}) | ConvertTo-Json -Depth 30 -Compress);foreach($owned in @($r[0].OwnedFiles)){if(Test-WsmAssistiveOwnedFileAdopted $owned){$adoptedFiles++;try{if(-not [IO.File]::Exists([string]$owned.TargetPath) -or (Get-FileHash -LiteralPath $owned.TargetPath -Algorithm SHA256).Hash -ine [string]$owned.SHA256){$adoptedChanged++}}catch{$adoptedChanged++};continue};$live=Get-WsmFileMetadata ([string]$owned.TargetPath) $spec.Metadata;if((Get-FileHash -LiteralPath $owned.TargetPath -Algorithm SHA256).Hash -ine [string]$owned.SHA256 -or (Get-WsmAssistiveMetadataHash $live) -ine [string]$owned.MetadataHash){$blocked=$true;$reason='Owned file bytes or metadata drifted.'};if($owned.Backup){$backupMetadata=Get-WsmFileMetadata ([string]$owned.Backup) $spec.Metadata;if((Get-FileHash -LiteralPath $owned.Backup -Algorithm SHA256).Hash -ine [string]$owned.BackupHash -or -not $owned.BackupMetadataHash -or (Get-WsmAssistiveMetadataHash $backupMetadata) -ine [string]$owned.BackupMetadataHash){$blocked=$true;$reason='Exact prior per-file backup bytes/metadata are unavailable.'}}};foreach($ownedDirectory in @($ownedDirs)){$live=Get-WsmFileMetadata ([string]$ownedDirectory.TargetPath) $spec.Metadata;if((Get-WsmAssistiveMetadataHash $live) -ine [string]$ownedDirectory.MetadataHash){$blocked=$true;$reason='Owned directory metadata drifted.'};if(-not $ownedDirectory.CreatedByTool -and (-not $ownedDirectory.BackupMetadata -or -not $ownedDirectory.BackupMetadataHash)){$blocked=$true;$reason='Prior owned directory metadata snapshot is unavailable.'}}}elseif($spec.Adapter -eq 'FileScope'){$hash=Get-WsmFileScopeDigest $spec.TargetPath $spec.Metadata}else{$hash=Get-WsmHashText ((Get-WsmAdapterState $spec) | ConvertTo-Json -Depth 15 -Compress);$receipts=@();if($spec.Adapter -eq 'ScheduledTask'){$receipts=Get-WsmTaskSecurityReceiptsForSpec $spec (Get-WsmTaskSecurityOwnershipReceipts $s)}elseif($r[0].PSObject.Properties['AuxiliaryOwnership']){$receipts=@($r[0].AuxiliaryOwnership)};$staged=Test-WsmAdapterConfiguration $spec Staged $receipts;$final=Test-WsmAdapterConfiguration $spec Final $receipts;if(-not $staged.Passed -and -not $final.Passed){$blocked=$true;$reason='Created object or owned task security drifted.'}}}catch{$blocked=$true;$reason='Created object verification failed: '+$_.Exception.GetType().FullName};[pscustomobject]@{ItemId=$item.ItemId;Adapter=$spec.Adapter;CurrentHash=$hash;Backup=$previewBackup;Action=$(if($spec.PSObject.Properties['SettingTransition']){'RestoreReviewedPriorSetting'}else{'RemoveCreatedOrRestorePreviousOwned'});Blocked=$blocked;Reason=$(if($adoptedFiles){(($reason+' '+(Get-WsmAssistiveAdoptedExistingNote)+$(if($adoptedChanged){' （其中 '+$adoptedChanged+' 個的內容已變更或不見，僅回報，回復時不會動它們。）'}else{''})).Trim())}else{$reason});AdoptedExistingFiles=$adoptedFiles}}})
    $preview=[pscustomobject]@{PairId=$s.PairId;ManifestHash=$ExpectedHash;DataReconcileRequired=($s.Cutover -and $s.Cutover.NewTransactionsPossible);Rows=$rows;SourceRestart='Never automatic';NetworkRollback='Reviewed domain/network procedure; never automatic source restart'}
    $preview | Add-Member NoteProperty PreviewHash (Get-WsmHashText ($preview | ConvertTo-Json -Depth 15 -Compress));$preview
}
function Invoke-WsmRollback {
    [CmdletBinding(SupportsShouldProcess)]param([string]$ManifestPath,[string]$ExpectedHash,[string]$StateDirectory,[string]$PreviewHash,[string]$Acknowledgement)
    $p=Test-WsmMigrationPackage $ManifestPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $p.Manifest.Target.Fingerprint;$paths=Get-WsmOperationPaths $StateDirectory $p.Manifest.PairId
    Invoke-WsmLocked $paths.Root {$s=Get-WsmOperationState $paths $p;$preview=Get-WsmRollbackPreview $ManifestPath $ExpectedHash $StateDirectory;if($PreviewHash -ine $preview.PreviewHash -or $Acknowledgement -cne ('ROLLBACK '+$s.PairId)){throw 'Rollback preview changed or pair acknowledgement missing.'};if($preview.DataReconcileRequired -and -not (Test-WsmEvidence $s '' RollbackReconcile $ExpectedHash)){throw 'New target transactions may exist; stop writers and reconcile data before rollback.'};if(@($preview.Rows | Where-Object Blocked).Count){throw 'Dedicated feature rollback required.'};if(-not $PSCmdlet.ShouldProcess($s.PairId,'Rollback exactly reviewed created objects/owned roots; keep displaced content')){return $preview}
        $reverse=@(Get-WsmRestoreOrder @($p.Plan.Items | Where-Object Decision -EQ Include));[array]::Reverse($reverse)
        foreach($item in $reverse){$record=@($s.Items | Where-Object ItemId -CEQ $item.ItemId);if(-not $record.Count -or -not (Test-WsmRollbackRecordOwnership $record[0] $item.MigrationSpec) -or $record[0].Status -eq 'RolledBack'){continue};$spec=$item.MigrationSpec;Add-WsmJournal $paths $s 'RollbackStarted' $item.ItemId ([pscustomobject]@{Adapter=$spec.Adapter})
            if($spec.Adapter -eq 'FileScope'){
                $target=ConvertTo-WsmCanonicalPath $spec.TargetPath;$parent=[IO.Path]::GetDirectoryName($target)
                if($record[0].PSObject.Properties['OwnedFiles']){$recordDirs=@();if($record[0].PSObject.Properties['OwnedDirectories']){$recordDirs=@($record[0].OwnedDirectories)};$files=@(foreach($owned in @($record[0].OwnedFiles | Where-Object {-not (Test-WsmAssistiveOwnedFileAdopted $_)})){$fileTarget=[IO.Path]::GetFullPath([string]$owned.TargetPath);$fileParent=[IO.Path]::GetDirectoryName($fileTarget);[pscustomobject]@{RelativePath=[string]$owned.RelativePath;TargetPath=$fileTarget;Retained=(Join-Path $fileParent ('.wsm-assistive-rollback-'+[Guid]::NewGuid().ToString('N')));CurrentHash=[string]$owned.SHA256;CurrentMetadataHash=[string]$owned.MetadataHash;Backup=[string]$owned.Backup;BackupHash=[string]$owned.BackupHash;BackupMetadataHash=[string]$owned.BackupMetadataHash;BackupMetadata=$owned.BackupMetadata}});$directories=@(foreach($owned in @($recordDirs)){$backupMeta=$owned.BackupMetadata;$backupMetaHash=[string]$owned.BackupMetadataHash;if($backupMeta){$backupMetaHash=Get-WsmAssistiveMetadataHash $backupMeta};[pscustomobject]@{RelativePath=[string]$owned.RelativePath;TargetPath=[IO.Path]::GetFullPath([string]$owned.TargetPath);CurrentMetadataHash=[string]$owned.MetadataHash;CurrentMetadata=$owned.CurrentMetadata;BackupMetadata=$backupMeta;BackupMetadataHash=$backupMetaHash;CreatedByTool=[bool]$owned.CreatedByTool}});$op=[pscustomobject]@{ItemId=$item.ItemId;Phase='RollbackAssistiveFiles';ManifestHash=$ExpectedHash;Target=$target;Files=[object[]]$files;Directories=[object[]]$directories};$s.PendingOperations+=@($op);$s.Stage='RollbackRunning';Add-WsmJournal $paths $s RollbackIntent $item.ItemId $op;Complete-WsmAssistiveFileRollback $item $op $paths $s;continue}
                $backup='';if($record[0].PSObject.Properties['Backup']){$backup=$record[0].Backup};$op=[pscustomobject]@{ItemId=$item.ItemId;Phase='RollbackPrepared';ManifestHash=$ExpectedHash;Target=$target;Retained=(Join-Path $parent ('.wsm-rollback-retained-'+[Guid]::NewGuid().ToString('N')));CurrentHash=(Get-WsmFileScopeDigest $target $spec.Metadata);Backup=$backup;BackupHash=''}
                if($backup){$op.BackupHash=Get-WsmFileScopeDigest $backup $spec.Metadata;if(-not $op.BackupHash){throw 'Approved rollback backup missing.'}}
                $s.PendingOperations+=@($op);$s.Stage='RollbackRunning';Add-WsmJournal $paths $s RollbackIntent $item.ItemId $op
                Complete-WsmFileRollback $item $op $paths $s;continue
            }
            else{$op=[pscustomobject]@{ItemId=$item.ItemId;Phase='RollbackAdapter';ManifestHash=$ExpectedHash;Adapter=$spec.Adapter;SpecHash=(Get-WsmHashText ($spec | ConvertTo-Json -Depth 40 -Compress))};if($spec.PSObject.Properties['SettingTransition']){$intent=$record[0].SettingTransitionIntent;$receipt=$record[0].SettingTransitionReceipt;if(-not $intent -or -not $receipt -or $receipt.TransitionHash -ine $spec.SettingTransition.TransitionHash){throw 'SettingTransition rollback requires the original durable apply intent and receipt.'};$op | Add-Member NoteProperty TransitionHash $spec.SettingTransition.TransitionHash;$op | Add-Member NoteProperty SettingTransitionIntent $intent;$op | Add-Member NoteProperty SettingTransitionReceipt $receipt;$op | Add-Member NoteProperty SettingTransitionRollbackIntent ([pscustomobject]@{TransitionHash=$spec.SettingTransition.TransitionHash;IntentId=$intent.IntentId;TargetFingerprint=$s.TargetFingerprint;ExpectedCurrent=$receipt.After;RestorePrior=$intent.Prior;ReceiptHash=$receipt.ReceiptHash;ManifestHash=$ExpectedHash})};$s.PendingOperations+=@($op);$s.Stage='RollbackRunning';Add-WsmJournal $paths $s RollbackIntent $item.ItemId $op;Complete-WsmAdapterRollback $item $op $paths $s}
        };$s.Stage='RolledBack';Add-WsmJournal $paths $s 'RollbackFinished' '' ([pscustomobject]@{SourceRestarted=$false});$s
    }
}
