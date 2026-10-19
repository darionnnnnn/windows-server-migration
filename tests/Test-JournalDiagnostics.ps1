param([Parameter(Mandatory)][string]$RecoveryPath)
$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-journal-diagnostic-test-'+[Guid]::NewGuid().ToString('N'))
$script:FixtureState=$null
$script:FixtureEvents=@()
$checkCount=0

function Assert-JournalDiagnostic([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw ('Assertion failed: '+$Message)}
    $script:checkCount++
}
function Get-WsmOperationPaths([string]$StateDirectory,[string]$PairId) {
    [pscustomobject]@{Root=$StateDirectory;State='fixture-state.json';Journal='fixture-journal.jsonl';Evidence='fixture-evidence.json'}
}
function Read-WsmJson([string]$Path) { $script:FixtureState }
function Read-WsmJournalEvents($Paths) { $script:FixtureEvents }
function New-JournalEvent([string]$PairId,[string]$RunId,[long]$Sequence,[string]$PreviousHash,[string]$Hash) {
    [pscustomobject]@{Row=[pscustomobject]@{Sequence=$Sequence;PreviousHash=$PreviousHash;PairId=$PairId;RunId=$RunId};Hash=$Hash}
}
function Get-JournalFailure([string]$PairId) {
    try { Test-WsmJournal $testRoot $PairId | Out-Null; throw 'Expected journal mismatch was not rejected.' }
    catch {
        if($_.Exception.Message -ceq 'Expected journal mismatch was not rejected.'){throw}
        return $_.Exception
    }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    . $RecoveryPath
    $pairId='PAIR-01';$runId='RUN-01';$zero='0'*64;$hash='a'*64
    $script:FixtureState=[pscustomobject]@{Sequence=1;JournalHash=$hash;RunId=$runId}

    $script:FixtureEvents=@((New-JournalEvent $pairId $runId 2 $zero $hash))
    $failure=Get-JournalFailure $pairId
    Assert-JournalDiagnostic ($failure.Message -ceq 'Journal chain/sequence/identity mismatch; retain evidence.' -and $failure.Data['WsmJournalMismatchPredicate'] -ceq 'Sequence' -and [long]$failure.Data['WsmJournalExpectedSequence'] -eq 1 -and [long]$failure.Data['WsmJournalObservedSequence'] -eq 2 -and $failure.Data['WsmJournalSamePair'] -and $failure.Data['WsmJournalSameRun'] -and $failure.Data['WsmJournalPreviousHashMatches']) 'sequence mismatch records only its allowlisted scalar facts'

    $script:FixtureEvents=@((New-JournalEvent $pairId $runId 1 ('b'*64) $hash))
    $failure=Get-JournalFailure $pairId
    Assert-JournalDiagnostic ($failure.Data['WsmJournalMismatchPredicate'] -ceq 'PreviousHash' -and [long]$failure.Data['WsmJournalExpectedSequence'] -eq 1 -and [long]$failure.Data['WsmJournalObservedSequence'] -eq 1 -and $failure.Data['WsmJournalSamePair'] -and $failure.Data['WsmJournalSameRun'] -and -not $failure.Data['WsmJournalPreviousHashMatches']) 'previous-hash mismatch records booleans without exposing either hash'

    $script:FixtureEvents=@((New-JournalEvent 'PAIR-OTHER' $runId 1 $zero $hash))
    $failure=Get-JournalFailure $pairId
    Assert-JournalDiagnostic ($failure.Data['WsmJournalMismatchPredicate'] -ceq 'PairId' -and -not $failure.Data['WsmJournalSamePair'] -and $failure.Data['WsmJournalSameRun'] -and $failure.Data['WsmJournalPreviousHashMatches']) 'pair mismatch is distinguished while raw identity remains absent'

    $script:FixtureEvents=@((New-JournalEvent $pairId 'RUN-OTHER' 1 $zero $hash))
    $failure=Get-JournalFailure $pairId
    Assert-JournalDiagnostic ($failure.Data['WsmJournalMismatchPredicate'] -ceq 'RunId' -and $failure.Data['WsmJournalSamePair'] -and -not $failure.Data['WsmJournalSameRun'] -and $failure.Data['WsmJournalPreviousHashMatches']) 'run mismatch is distinguished while raw identity remains absent'

    $script:FixtureState=[pscustomobject]@{Sequence=1;JournalHash=$hash;RunId=$runId}
    $script:FixtureEvents=@((New-JournalEvent $pairId $runId 1 $zero $hash))
    $consistent=Test-WsmJournal $testRoot $pairId
    Assert-JournalDiagnostic ($consistent.Consistent -and -not $consistent.RecoveryRequired -and $consistent.JournalSequence -eq 1) 'a consistent journal retains the existing verifier result'

    $script:FixtureState=[pscustomobject]@{Sequence=0;JournalHash=$zero;RunId=$runId}
    $script:FixtureEvents=@((New-JournalEvent $pairId $runId 1 $zero $hash))
    $ahead=Test-WsmJournal $testRoot $pairId
    Assert-JournalDiagnostic (-not $ahead.Consistent -and $ahead.RecoveryRequired -and $ahead.JournalSequence -eq 1 -and $ahead.StateSequence -eq 0) 'a valid journal ahead of the checkpoint remains recovery-required, not a chain mismatch'

    Write-Host ('PASS: '+$checkCount+' journal diagnostic checks; four refusal predicates, consistent chain, and checkpoint-ahead recovery behavior.')
} finally {
    if([IO.Directory]::Exists($testRoot)){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
