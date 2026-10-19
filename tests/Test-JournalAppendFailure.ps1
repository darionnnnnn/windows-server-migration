#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-journal-append-'+[Guid]::NewGuid().ToString('N'))
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Refusing to reuse a pre-existing journal test directory.'}
[void][IO.Directory]::CreateDirectory($root)
try {
  & $module {
    param($Root)
    function Check($condition,[string]$message){if(-not $condition){throw $message};$script:checks++}
    function Test-ContainsStateItem($State,[string]$ItemId){foreach($item in @($State.Items)){if($item -and $item.PSObject.Properties['ItemId'] -and $item.ItemId -ceq $ItemId){return $true}};return $false}
    function New-TestState([string]$PairId){[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OperationState';BatchId=[Guid]::NewGuid().ToString();PairId=$PairId;TargetFingerprint=('b'*64);PlanHash=('c'*64);RunId=[Guid]::NewGuid().ToString();ManifestHash='';Generation=0;Stage='NotStarted';Sequence=[long]0;ResultSequence=[long]0;JournalHash=('0'*64);JournalSegment=0;Items=@();Evidence=@();Cutover=$null;PendingOperations=@()}}
    function New-Fixture([string]$Name){$pair=[Guid]::NewGuid().ToString();$directory=Join-Path $Root $Name;$paths=Get-WsmOperationPaths $directory $pair;$state=New-TestState $pair;Write-WsmJson $paths.State $state;[pscustomobject]@{PairId=$pair;Directory=$directory;Paths=$paths;State=$state}}
    $script:checks=0

    # A real read-share handle prevents File.Open(Append, Write, Read). A later
    # catch-path event must reuse sequence 2 and the original checkpoint hash.
    $locked=New-Fixture 'open-failure'
    Add-WsmJournal $locked.Paths $locked.State 'FirstDurable' '' ([pscustomobject]@{Value=1})
    $reader=[IO.File]::Open($locked.Paths.Journal,'Open','Read','Read')
    try{$openError='';try{Add-WsmJournal $locked.Paths $locked.State 'BlockedOpen' '' $null}catch{$openError=$_.Exception.GetBaseException().GetType().FullName}}
    finally{$reader.Dispose()}
    Check ($openError -ceq 'System.IO.IOException' -and $locked.State.Sequence -eq 1) 'A genuine append-open sharing failure advanced the in-memory sequence.'
    Add-WsmJournal $locked.Paths $locked.State 'FailureRecorded' '' ([pscustomobject]@{Failure='append open blocked'})
    $openRows=@(Read-WsmJournalEvents $locked.Paths)
    $openCheck=Test-WsmJournal $locked.Directory $locked.PairId
    Check ($openCheck.Consistent -and @($openRows.Row.Sequence) -join ',' -ceq '1,2' -and $openRows[1].Row.PreviousHash -ceq $openRows[0].Hash) 'The retry after a released append lock did not produce a continuous, readable 1→2 hash chain.'

    # Both serialization and size rejection happen before sequence mutation or file creation.
    $serialize=New-Fixture 'serialize-failure'
    $originalAdd=(Get-Command Add-WsmJournal).ScriptBlock
    $source=$originalAdd.ToString()
    $target='$text=$row | ConvertTo-Json -Depth 15 -Compress'
    $replacement="throw 'Injected journal serialization failure.'"
    if(-not $source.Contains($target)){throw 'Could not locate the exact journal serializer site for the serialization fault fixture.'}
    Set-Item Function:\script:Add-WsmJournal -Value ([scriptblock]::Create($source.Replace($target,$replacement)))
    try{$serializeError='';try{Add-WsmJournal $serialize.Paths $serialize.State 'SerializeFailure' '' $null}catch{$serializeError=$_.Exception.Message}}
    finally{Set-Item Function:\script:Add-WsmJournal -Value $originalAdd}
    Check ($serializeError -ceq 'Injected journal serialization failure.' -and $serialize.State.Sequence -eq 0 -and $serialize.State.JournalHash -ceq ('0'*64) -and -not [IO.File]::Exists($serialize.Paths.Journal)) 'Serialization failure changed journal state or created a row.'
    $oversize=New-Fixture 'oversize-failure'
    $largeDetail=[pscustomobject]@{Value=('x'*(1024*1024))}
    $oversizeError='';try{Add-WsmJournal $oversize.Paths $oversize.State 'Oversize' '' $largeDetail}catch{$oversizeError=$_.Exception.Message}
    Check ($oversizeError -ceq 'Journal event too large.' -and $oversize.State.Sequence -eq 0 -and $oversize.State.JournalHash -ceq ('0'*64) -and -not [IO.File]::Exists($oversize.Paths.Journal)) 'Oversize rejection advanced the sequence or created a journal row.'
    Add-WsmJournal $serialize.Paths $serialize.State 'AfterSerializeFailure' '' $null
    Add-WsmJournal $oversize.Paths $oversize.State 'AfterOversizeFailure' '' $null
    Check ((Test-WsmJournal $serialize.Directory $serialize.PairId).Consistent -and (Test-WsmJournal $oversize.Directory $oversize.PairId).Consistent) 'A safe pre-write failure prevented a subsequent valid writer append.'
    $missingSegment=New-Fixture 'missing-segment-field'
    Add-WsmJournal $missingSegment.Paths $missingSegment.State 'SegmentCheckpoint' '' $null
    $malformedState=Read-WsmJson $missingSegment.Paths.State
    $malformedState.PSObject.Properties.Remove('JournalSegment')
    Write-WsmJson $missingSegment.Paths.State $malformedState
    $missingSegmentError='';try{Test-WsmJournal $missingSegment.Directory $missingSegment.PairId|Out-Null}catch{$missingSegmentError=$_.Exception.Message}
    Check ($missingSegmentError -ceq 'Operation state has no valid journal segment checkpoint; retain evidence.') 'A state without the mandatory segment checkpoint was accepted.'

    # Inject a failure after three bytes have been written: the in-process writer
    # must poison the run, and a fresh state reader must reject the torn tail.
    $partial=New-Fixture 'partial-write'
    $originalAdd=(Get-Command Add-WsmJournal).ScriptBlock
    $source=$originalAdd.ToString()
    $target='$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)'
    $replacement='$stream.Write($bytes,0,3);throw ''Injected failure after partial journal bytes.'''
    if(-not $source.Contains($target)){throw 'Could not locate the exact journal write site for the partial-write fault fixture.'}
    $instrumented=[scriptblock]::Create($source.Replace($target,$replacement))
    Set-Item Function:\script:Add-WsmJournal -Value $instrumented
    try{
      $partialError='';try{Add-WsmJournal $partial.Paths $partial.State 'TornEvent' '' $null}catch{$partialError=$_.Exception.Message}
      $lengthAfterFailure=(New-Object IO.FileInfo($partial.Paths.Journal)).Length
      $blockedError='';try{Add-WsmJournal $partial.Paths $partial.State 'CatchPathMustNotAppend' '' $null}catch{$blockedError=$_.Exception.Message}
      $lengthAfterRetry=(New-Object IO.FileInfo($partial.Paths.Journal)).Length
    }finally{Set-Item Function:\script:Add-WsmJournal -Value $originalAdd}
    $partialStateJson=$partial.State | ConvertTo-Json -Depth 15 -Compress
    Check ($partialError -ceq 'Injected failure after partial journal bytes.' -and $partial.State.Sequence -eq 0 -and $lengthAfterFailure -gt 0 -and $partialStateJson -notmatch '__WsmJournalWriteBlocked') 'Injected partial append did not retain a torn row with the old checkpoint sequence, or exposed transient poison in JSON.'
    Check ($blockedError -ceq 'Journal append is blocked after an uncertain write; reload and repair the verified journal before retrying.' -and $lengthAfterRetry -eq $lengthAfterFailure) 'A catch-path append wrote again after an uncertain partial journal write.'
    $fakePackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$partial.PairId;Target=[pscustomobject]@{Fingerprint='b'*64};PlanHash='c'*64}}
    $freshReaderError='';try{Get-WsmOperationState $partial.Paths $fakePackage|Out-Null}catch{$freshReaderError=$_.Exception.Message}
    Check ($freshReaderError -and $freshReaderError -ne 'Journal append is blocked after an uncertain write; reload and repair the verified journal before retrying.') 'A fresh operation-state read accepted or bypassed the torn journal tail.'

    # A durable row followed by checkpoint failure is journal-ahead, remains
    # blocked in-process, and is replayed only by the existing recovery reader.
    $checkpoint=New-Fixture 'checkpoint-failure'
    $script:originalWriteWsmJson=(Get-Command Write-WsmJson).ScriptBlock
    $script:checkpointFailPath=[IO.Path]::GetFullPath($checkpoint.Paths.State)
    $script:failCheckpoint=$true
    function script:Write-WsmJson {param([string]$Path,$Data) if($script:failCheckpoint -and [IO.Path]::GetFullPath($Path) -ceq $script:checkpointFailPath){throw 'Injected checkpoint replacement failure.'};& $script:originalWriteWsmJson $Path $Data}
    try{
      $checkpointError='';try{Add-WsmJournal $checkpoint.Paths $checkpoint.State 'RestoreStarted' '' ([pscustomobject]@{ManifestHash=('d'*64);Generation=1})}catch{$checkpointError=$_.Exception.Message}
      $diskState=Read-WsmJson $checkpoint.Paths.State
      $ahead=Test-WsmJournal $checkpoint.Directory $checkpoint.PairId
      $durableRows=@(Read-WsmJournalEvents $checkpoint.Paths)
      $checkpointBlocked='';try{Add-WsmJournal $checkpoint.Paths $checkpoint.State 'CatchPathMustNotAppend' '' $null}catch{$checkpointBlocked=$_.Exception.Message}
      $eventCount=@(Read-WsmJournalEvents $checkpoint.Paths).Count
      $script:failCheckpoint=$false
      $checkpoint.State.Items=@([pscustomobject]@{ItemId='UNCOMMITTED';Status='Pending'})
      $checkpointPackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$checkpoint.PairId;Target=[pscustomobject]@{Fingerprint='b'*64};PlanHash='c'*64}}
      $recoveryArgument=Get-WsmOperationState $checkpoint.Paths $checkpointPackage -AllowRecovery
      Restore-WsmJournalCheckpoint $checkpoint.Paths $recoveryArgument
      $recovered=Read-WsmJson $checkpoint.Paths.State
      $recoveredCheck=Test-WsmJournal $checkpoint.Directory $checkpoint.PairId
      $staleCheckpointRetry='';try{Add-WsmJournal $checkpoint.Paths $checkpoint.State 'StaleObjectMustRemainBlocked' '' $null}catch{$staleCheckpointRetry=$_.Exception.Message}
      Add-WsmJournal $checkpoint.Paths $recoveryArgument 'RecoveredCallerStateAppend' '' $null
      $resumedCheck=Test-WsmJournal $checkpoint.Directory $checkpoint.PairId
    }finally{Remove-Item Function:\script:Write-WsmJson -ErrorAction SilentlyContinue;$script:failCheckpoint=$false}
    Check ($checkpointError -ceq 'Injected checkpoint replacement failure.' -and $checkpoint.State.Sequence -eq 1 -and $checkpoint.State.JournalHash -ceq (Get-WsmHashText ([IO.File]::ReadAllLines($checkpoint.Paths.Journal)[0]))) 'Checkpoint failure discarded the durable row identity from the in-memory state.'
    Check ($ahead.RecoveryRequired -and -not $ahead.Consistent -and $checkpointBlocked -like 'Journal append is blocked after an uncertain write;*' -and $eventCount -eq 1 -and -not $durableRows[0].Row.PSObject.Properties['__WsmJournalWriteBlocked'] -and (($checkpoint.State | ConvertTo-Json -Depth 15 -Compress) -notmatch '__WsmJournalWriteBlocked')) 'Checkpoint failure allowed a second append or did not expose a single journal-ahead row.'
    Check ($recoveredCheck.Consistent -and $recovered.Sequence -eq 1 -and $recovered.RestoreAttempt.ManifestHash -ceq ('d'*64) -and (-not (Test-ContainsStateItem $recovered 'UNCOMMITTED'))) 'Existing verified journal recovery failed to replay the exact durable event or persisted caller-only state.'
    Check ($staleCheckpointRetry -like 'Journal append is blocked after an uncertain write;*' -and $resumedCheck.Consistent -and $recoveryArgument.Sequence -eq 2) 'A same-process verified recovery did not preserve the old poisoned State object while allowing a freshly loaded durable state to resume.'

    # A failure after moving the current journal but before opening its replacement
    # leaves a complete old checkpoint and a contiguous archive. Fresh recovery may
    # repair only JournalSegment from the durable disk-state copy.
    $rotation=New-Fixture 'rotation-after-move-failure'
    $chunk='z'*(900*1024)
    for($i=1;$i -le 10;$i++){Add-WsmJournal $rotation.Paths $rotation.State ('Large'+$i) '' ([pscustomobject]@{Ordinal=$i;Data=$chunk})}
    $rotation.State.Items=@([pscustomobject]@{ItemId='UNCOMMITTED';Status='Pending'})
    $originalAdd=(Get-Command Add-WsmJournal).ScriptBlock
    $source=$originalAdd.ToString();$target='$stream=[IO.File]::Open($path,''Append'',''Write'',''Read'')'
    if(-not $source.Contains($target)){throw 'Could not locate the exact append-open site for the rotation fault fixture.'}
    Set-Item Function:\script:Add-WsmJournal -Value ([scriptblock]::Create($source.Replace($target,"throw 'Injected failure opening journal after archive move.'")))
    try{$rotationError='';try{Add-WsmJournal $rotation.Paths $rotation.State 'AfterMoveFailure' '' $null}catch{$rotationError=$_.Exception.Message}}
    finally{Set-Item Function:\script:Add-WsmJournal -Value $originalAdd}
    $diskRotationState=Read-WsmJson $rotation.Paths.State
    $segmentCheck=Test-WsmJournal $rotation.Directory $rotation.PairId
    $rotationPackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$rotation.PairId;Target=[pscustomobject]@{Fingerprint='b'*64};PlanHash='c'*64}}
    $freshReaderError='';try{Get-WsmOperationState $rotation.Paths $rotationPackage|Out-Null}catch{$freshReaderError=$_.Exception.Message}
    Check ($rotationError -ceq 'Injected failure opening journal after archive move.' -and [IO.File]::Exists((Join-Path $rotation.Paths.Root 'journal-0.jsonl')) -and -not [IO.File]::Exists($rotation.Paths.Journal)) 'The injected rotation-open failure did not retain exactly the moved archive evidence.'
    Check ($segmentCheck.RecoverableSegmentMismatch -and -not $segmentCheck.Consistent -and $segmentCheck.ArchiveCount -eq 1 -and $diskRotationState.JournalSegment -eq 0 -and (-not (Test-ContainsStateItem $diskRotationState 'UNCOMMITTED'))) 'The reader did not isolate a recoverable segment-only mismatch from uncommitted in-memory state.'
    Check ($freshReaderError -like 'Durable journal differs from checkpoint; run RepairOperation before any further changes.*') 'A fresh operation-state reader accepted an interrupted rotation before recovery.'
    $freshRotationState=Read-WsmJson $rotation.Paths.State
    Restore-WsmJournalCheckpoint $rotation.Paths $rotation.State
    $repairedRotation=Read-WsmJson $rotation.Paths.State
    $repairCheck=Test-WsmJournal $rotation.Directory $rotation.PairId
    Check ($repairCheck.Consistent -and $repairedRotation.JournalSegment -eq 1 -and $repairedRotation.Sequence -eq 10 -and (-not (Test-ContainsStateItem $repairedRotation 'UNCOMMITTED'))) 'Segment-only recovery failed or persisted caller-only pending state.'
    $staleRotationRetry='';try{Add-WsmJournal $rotation.Paths $rotation.State 'StaleRotationStateMustRemainBlocked' '' $null}catch{$staleRotationRetry=$_.Exception.Message}
    Check ($staleRotationRetry -like 'Journal append is blocked after an uncertain write;*') 'Segment reconciliation incorrectly unblocked the old in-memory State object.'
    for($i=11;$i -le 21;$i++){Add-WsmJournal $rotation.Paths $repairedRotation ('Large'+$i) '' ([pscustomobject]@{Ordinal=$i;Data=$chunk})}
    $rotatedRows=@(Read-WsmJournalEvents $rotation.Paths)
    $rotatedCheck=Test-WsmJournal $rotation.Directory $rotation.PairId
    Check ([IO.File]::Exists((Join-Path $rotation.Paths.Root 'journal-0.jsonl')) -and [IO.File]::Exists((Join-Path $rotation.Paths.Root 'journal-1.jsonl')) -and $repairedRotation.JournalSegment -eq 2) 'A repaired writer could not safely rotate into the next contiguous archive segment.'
    Check ($rotatedCheck.Consistent -and $rotatedRows.Count -eq 21 -and $rotatedRows[0].Row.Sequence -eq 1 -and $rotatedRows[20].Row.Sequence -eq 21 -and $rotatedRows[20].Row.Detail.Ordinal -eq 21) 'Recovered rotated writer output did not read back as one complete ordered hash chain.'
    $archiveOne=Join-Path $rotation.Paths.Root 'journal-1.jsonl';$archiveTwo=Join-Path $rotation.Paths.Root 'journal-2.jsonl'
    [IO.File]::Move($archiveOne,$archiveTwo)
    $gapError='';try{Test-WsmJournal $rotation.Directory $rotation.PairId|Out-Null}catch{$gapError=$_.Exception.Message}
    Check ($gapError -ceq 'Journal archive topology is not contiguous; retain evidence.') 'A gapped archive sequence was accepted.'
    [IO.File]::Move($archiveTwo,$archiveOne)
    $archivePath=Join-Path $rotation.Paths.Root 'journal-0.jsonl'
    $archiveText=[IO.File]::ReadAllText($archivePath)
    if(-not $archiveText.Contains('"Action":"Large1"')){throw 'Could not locate the first valid event action for the archive tamper fixture.'}
    [IO.File]::WriteAllText($archivePath,$archiveText.Replace('"Action":"Large1"','"Action":"Tampered"'),[Text.UTF8Encoding]::new($false))
    $tamperError='';try{Test-WsmJournal $rotation.Directory $rotation.PairId|Out-Null}catch{$tamperError=$_.Exception.Message}
    Check ($tamperError -ceq 'Journal chain/sequence/identity mismatch; retain evidence.') 'A modified archived event bypassed the full chain verifier.'
    Write-Host ('PASS: '+$script:checks+' journal append failures, poison boundary, checkpoint recovery, segment reconciliation and real rotations; original CI I/O exception remains unavailable.')
  } $root
} finally {
  if([IO.Directory]::Exists($root)){
    $canonical=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if([IO.Path]::GetDirectoryName($canonical).TrimEnd('\') -ine $tempRoot.TrimEnd('\') -or [IO.Path]::GetFileName($canonical) -notmatch '^wsm-journal-append-[a-f0-9]{32}$' -or ([IO.File]::GetAttributes($canonical) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing journal test cleanup outside the generated non-reparse temp directory.'}
    Remove-Item -LiteralPath $canonical -Recurse -Force
  }
}
