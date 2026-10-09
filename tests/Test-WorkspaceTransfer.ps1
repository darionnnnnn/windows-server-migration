$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$script:ToolVersion='0.3.0'
$script:FixtureFingerprint='a'*64
$script:UnsafePaths=@()
function Assert-TransferTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-WsmId([string]$Id){$g=[Guid]::Empty;if(-not [Guid]::TryParseExact($Id,'D',[ref]$g)){throw 'bad id'}}
function Assert-WsmEnvelope($Data,[string]$Kind){if($Data.SchemaVersion -ne 1 -or $Data.Kind -cne $Kind){throw 'bad envelope'}}
function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:FixtureFingerprint;Name='fixture';OS='Windows Server';Version='10';IsServer=$true;Administrator=$true;Is64Bit=$true}}
function Assert-WsmNoReparse([string]$Path){$full=[IO.Path]::GetFullPath($Path);foreach($unsafe in $script:UnsafePaths){$u=[IO.Path]::GetFullPath($unsafe);if($full -ieq $u -or $full.StartsWith($u.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'fixture reparse point'}}}
function Protect-WsmDirectory([string]$Path){}
function Assert-WsmCancellationDirectoryProtection([string]$Path){}
function Get-WsmAvailableBytes([string]$Path){[long]2147483648}
function Get-WsmPhysicalPath([string]$Path){[IO.Path]::GetFullPath($Path)}
function Test-WsmPathOverlap([string]$Left,[string]$Right){$l=$Left.TrimEnd('\');$r=$Right.TrimEnd('\');$l -ieq $r -or $l.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($l+'\',[StringComparison]::OrdinalIgnoreCase)}
function Read-WsmJson([string]$Path){ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8))}
function Write-WsmJson([string]$Path,$Data){$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path));if(-not [IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};[IO.File]::WriteAllText($Path,($Data | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))}
function Get-WsmUtc {[DateTime]::UtcNow.ToString('o')}
function Invoke-WsmLocked([string]$Workspace,[scriptblock]$Action){& $Action}
function Assert-WsmTrustedFile([string]$Path,[string]$ExpectedHash){if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'trusted hash mismatch'}}
. (Join-Path $PSScriptRoot '..\src\OutputWorkspace.ps1')
. (Join-Path $PSScriptRoot '..\src\WorkspaceTransfer.ps1')

function New-TransferFixture([string]$Base,[string]$Role) {
    $name=$Role
    if($Role -cnotin @('Source','Manager','Target')){$Role='Source'}
    $root=Join-Path $Base $name
    $workspace=Initialize-WsmOutputWorkspace -WorkRoot $root -Role $Role
    if($Role -eq 'Source'){
        $statePath=Join-Path $workspace.InventoryDirectory 'source-state.json';$state=Read-WsmJson $statePath;$state.Revision=4;Write-WsmJson $statePath $state
        [IO.File]::WriteAllText((Join-Path $workspace.InventoryDirectory 'inventory-4.json'),'inventory-bytes')
    }else{
        $pair='b1111111-1111-4111-8111-111111111111';$plan='c'*64
        $binding=Register-WsmOutputPair -WorkRoot $root -Role $Role -PairId $pair -PlanHash $plan
        if($Role -eq 'Manager'){
            Write-WsmJson (Join-Path $root 'fleet.json') ([pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='Fleet';BatchId='f1111111-1111-4111-8111-111111111111';Pairs=@()})
            $catalog=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='Catalog';PairId=$pair;Approval=[pscustomobject]@{Kind='MigrationPlan';Hash=$plan};Items=@()}
            Write-WsmJson (Join-Path $root ('pairs\'+$pair+'.json')) $catalog
        }else{
            $state=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OperationState';PairId=$pair;PlanHash=$plan;TargetFingerprint=$script:FixtureFingerprint;RunId='d1111111-1111-4111-8111-111111111111'}
            Write-WsmJson (Join-Path $binding.PairRoot 'state.json') $state
            [IO.File]::WriteAllText((Join-Path $binding.PairRoot 'journal.jsonl'),'journal-bytes')
            $attempt=Resolve-WsmOutputWorkspace -WorkRoot $root -Role Target -PairId $pair -PlanHash $plan -AttemptId 'e1111111-1111-4111-8111-111111111111'
            [IO.File]::WriteAllText((Join-Path $attempt.ReportsDirectory 'report.md'),'attempt-bytes')
        }
    }
    return $root
}
function Get-TransferFileHashes([string]$Root){$rows=@();foreach($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Where-Object {$_.Name -notin @('.wsm.lock','workspace-transfer.json')})){$rows+=('{0}|{1}|{2}' -f $file.FullName.Substring($Root.Length),$file.Length,(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash)};@($rows | Sort-Object)}
function Invoke-TransferForRoot([string]$Root,[string]$Base,[string]$Name) {
    $destination=Join-Path $Base ($Name+'-moved');$previewPath=Join-Path $Base ($Name+'-preview.json')
    $preview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $Root -DestinationWorkRoot $destination -Path $previewPath
    $oldHashes=Get-TransferFileHashes $Root
    $whatIfBefore=Get-TransferFileHashes $Root
    $whatIf=Invoke-WsmOutputWorkspaceTransfer -PreviewPath $preview.Path -ExpectedHash $preview.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -WhatIf
    Assert-TransferTest ($whatIf.WhatIf -and -not [IO.Directory]::Exists($destination) -and (Test-TransferSequenceEqual $whatIfBefore (Get-TransferFileHashes $Root))) 'WhatIf changed workspace files or created the destination.'
    $result=Invoke-WsmOutputWorkspaceTransfer -PreviewPath $preview.Path -ExpectedHash $preview.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false
    Assert-TransferTest ($result.Applied -and $result.Status -ceq 'Migrated') 'Transfer did not reach Migrated.'
    Assert-TransferTest ((Get-WsmWorkspaceTransferFileHash (Join-Path $destination 'workspace-control\output-profile.json')).SHA256 -ne '') 'Destination profile is unreadable.'
    $destinationHashes=Get-TransferFileHashes $destination;$sourcePayloadHashes=@($oldHashes | Where-Object {$_ -notlike '*workspace-control\output-profile.json*'});$destinationPayloadHashes=@($destinationHashes | Where-Object {$_ -notlike '*workspace-control\output-profile.json*'})
    Assert-TransferTest (Test-TransferSequenceEqual $sourcePayloadHashes $destinationPayloadHashes) 'State/catalog/journal/attempt payload bytes changed during transfer.'
    $sourceProfile=Read-WsmJson (Join-Path $Root 'workspace-control\output-profile.json');$destinationProfile=Read-WsmJson (Join-Path $destination 'workspace-control\output-profile.json');$destinationProfile.WorkRoot=$sourceProfile.WorkRoot
    Assert-TransferTest ((ConvertTo-Json -InputObject $sourceProfile -Compress -Depth 30) -ceq (ConvertTo-Json -InputObject $destinationProfile -Compress -Depth 30)) 'Transfer changed profile fields other than WorkRoot.'
    $moved=Initialize-WsmOutputWorkspace -WorkRoot $destination -Role $result.Role
    Assert-TransferTest ($moved.HostId -ceq $result.HostId -and $moved.Profile.ProfileId -ceq $result.ProfileId) 'HostId/ProfileId did not survive the move.'
    if($result.Role -eq 'Source'){Assert-TransferTest ($moved.Revision -eq 4) 'Source inventory revision did not survive the move.'}
    $sourceMarker=Join-Path $Root 'workspace-control\workspace-transfer.json';Assert-TransferTest ((Read-WsmJson $sourceMarker).Status -ceq 'Migrated') 'Original root was not tombstoned.'
    $blocked=$false;try{Assert-WsmOutputWorkspaceNotMigrated $Root}catch{$blocked=$true};Assert-TransferTest $blocked 'Migrated original root was not blocked.'
    $blocked=$false;try{Assert-WsmOutputWorkspaceNotMigrated (Join-Path $Root 'pairs')}catch{$blocked=$true};Assert-TransferTest $blocked 'Ancestor marker did not block a nested operation path.'
    $blocked=$false;try{Initialize-WsmOutputWorkspace -WorkRoot $Root -Role $result.Role | Out-Null}catch{$blocked=$_.Exception.Message -like '*transfer-marked*'};Assert-TransferTest $blocked 'Original Initialize API did not reject the migrated root.'
    $restorePath=Join-Path $Base ($Name+'-restore-preview.json')
    $restore=New-WsmOutputWorkspaceTransferRestorePreview -SourceWorkRoot $Root -DestinationWorkRoot $destination -Path $restorePath
    $newFile=Join-Path $destination 'workspace-control\new-data.json';[IO.File]::WriteAllText($newFile,'user data')
    $preserved=$false;try{Invoke-WsmOutputWorkspaceTransferRestore -PreviewPath $restore.Path -ExpectedHash $restore.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false}catch{$preserved=$_.Exception.Message -like '*destination has changed*'}
    Assert-TransferTest ($preserved -and [IO.File]::ReadAllText($newFile) -ceq 'user data' -and [IO.File]::Exists($sourceMarker)) 'Restore failed to preserve new destination data/source tombstone.'
    Remove-Item -LiteralPath $newFile -Force
    $restore=New-WsmOutputWorkspaceTransferRestorePreview -SourceWorkRoot $Root -DestinationWorkRoot $destination -Path (Join-Path $Base ($Name+'-restore-preview2.json'))
    $restoreResult=Invoke-WsmOutputWorkspaceTransferRestore -PreviewPath $restore.Path -ExpectedHash $restore.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false
    Assert-TransferTest ($restoreResult.Applied -and -not [IO.File]::Exists($sourceMarker) -and (Test-Path -LiteralPath (Join-Path $destination 'workspace-control\workspace-transfer.json'))) 'Restore did not safely return sole authority to the original root.'
    $restored=Initialize-WsmOutputWorkspace -WorkRoot $Root -Role $result.Role
    Assert-TransferTest ($restored.HostId -ceq $result.HostId -and $restored.Profile.ProfileId -ceq $result.ProfileId) 'Original root was not reusable after restore.'
    return [pscustomobject]@{OldHashes=$oldHashes;Result=$result;Destination=$destination}
}
function Test-TransferSequenceEqual($A,$B){if(@($A).Count -ne @($B).Count){return $false};for($i=0;$i -lt @($A).Count;$i++){if($A[$i] -cne $B[$i]){return $false}};return $true}

$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('.workspace-transfer-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try{
    Assert-WsmOutputWorkspaceNotMigrated ($env:SystemDrive+'\')
    foreach($role in @('Source','Manager','Target')){$root=New-TransferFixture $testRoot $role;[void](Invoke-TransferForRoot $root $testRoot $role)}

    $badRoot=New-TransferFixture $testRoot 'changed';$badDestination=Join-Path $testRoot 'changed-moved';$badPreview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $badRoot -DestinationWorkRoot $badDestination -Path (Join-Path $testRoot 'changed-preview.json')
    [IO.File]::AppendAllText((Join-Path $badRoot 'workspace-control\output-profile.json'),' ')
    $blocked=$false;try{Invoke-WsmOutputWorkspaceTransfer -PreviewPath $badPreview.Path -ExpectedHash $badPreview.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false}catch{$blocked=$_.Exception.Message -like '*changed after preview*'}
    Assert-TransferTest ($blocked -and -not [IO.Directory]::Exists($badDestination) -and -not [IO.File]::Exists((Join-Path $badRoot 'workspace-control\workspace-transfer.json'))) 'Changed-source apply did not fail closed.'

    $lockRoot=New-TransferFixture $testRoot 'locked';$lockDestination=Join-Path $testRoot 'locked-moved';$lockPreview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $lockRoot -DestinationWorkRoot $lockDestination -Path (Join-Path $testRoot 'locked-preview.json')
    $lockStream=[IO.File]::Open((Join-Path $lockRoot '.wsm.lock'),'OpenOrCreate','ReadWrite','None')
    try{$blocked=$false;try{Invoke-WsmOutputWorkspaceTransfer -PreviewPath $lockPreview.Path -ExpectedHash $lockPreview.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false}catch{$blocked=$_.Exception.Message -like '*exclusive workspace lock*'};Assert-TransferTest ($blocked -and -not [IO.Directory]::Exists($lockDestination)) 'An active workspace lock did not block transfer.'}finally{$lockStream.Dispose()}

    $ackRoot=New-TransferFixture $testRoot 'ack';$ackDestination=Join-Path $testRoot 'ack-moved';$ackPreview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $ackRoot -DestinationWorkRoot $ackDestination -Path (Join-Path $testRoot 'ack-preview.json')
    $blocked=$false;try{Invoke-WsmOutputWorkspaceTransfer -PreviewPath $ackPreview.Path -ExpectedHash $ackPreview.SHA256 -Acknowledgement WRONG -StoppedAllTools -Confirm:$false}catch{$blocked=$_.Exception.Message -like '*exact acknowledgement*'};Assert-TransferTest ($blocked -and -not [IO.Directory]::Exists($ackDestination)) 'Incorrect acknowledgement was accepted.'
    $blocked=$false;try{Invoke-WsmOutputWorkspaceTransfer -PreviewPath $ackPreview.Path -ExpectedHash $ackPreview.SHA256 -Acknowledgement MIGRATE-WORKROOT -Confirm:$false}catch{$blocked=$_.Exception.Message -match 'StoppedAllTools|all WSM tools are stopped'};Assert-TransferTest $blocked 'Missing stopped-tools prerequisite was accepted.'

    $copyRoot=New-TransferFixture $testRoot 'copyfail';$copyDestination=Join-Path $testRoot 'copyfail-moved';$copyPreview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $copyRoot -DestinationWorkRoot $copyDestination -Path (Join-Path $testRoot 'copyfail-preview.json')
    $originalCopy=(Get-Command Copy-WsmWorkspaceTransferFile).ScriptBlock
    function Copy-WsmWorkspaceTransferFile([string]$Source,[string]$Destination,[long]$Bytes,[string]$Hash){throw 'synthetic copy failure'}
    $failed=$false;try{Invoke-WsmOutputWorkspaceTransfer -PreviewPath $copyPreview.Path -ExpectedHash $copyPreview.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false}catch{$failed=$_.Exception.Message -like '*synthetic copy failure*'}
    Remove-Item Function:\Copy-WsmWorkspaceTransferFile -ErrorAction SilentlyContinue;Set-Item Function:\Copy-WsmWorkspaceTransferFile $originalCopy
    $stagedCopy=@(Get-ChildItem -LiteralPath $testRoot -Directory -Filter '.wsm-*' -Force | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'workspace-control\workspace-transfer.json')}) | Select-Object -First 1
    Assert-TransferTest ($failed -and -not [IO.File]::Exists((Join-Path $copyRoot 'workspace-control\workspace-transfer.json')) -and -not [IO.Directory]::Exists($copyDestination) -and $stagedCopy) 'Copy failure did not restore source authority and retain a blocked staging copy.'
    $blocked=$false;try{Assert-WsmOutputWorkspaceNotMigrated $stagedCopy.FullName}catch{$blocked=$true};Assert-TransferTest $blocked 'Partial staging copy was not blocked after copy failure.'
    $blocked=$false;try{Initialize-WsmOutputWorkspace -WorkRoot $stagedCopy.FullName -Role Source | Out-Null}catch{$blocked=$_.Exception.Message -like '*transfer-marked*'};Assert-TransferTest $blocked 'Initialize API did not reject a Prepared partial staging directory.'

    $moveRoot=New-TransferFixture $testRoot 'move-failure';$moveDestination=Join-Path $testRoot 'move-failure-moved';$movePreview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $moveRoot -DestinationWorkRoot $moveDestination -Path (Join-Path $testRoot 'move-failure-preview.json')
    $realMove=(Get-Command Move-WsmWorkspaceTransferStage).ScriptBlock;function Move-WsmWorkspaceTransferStage([string]$Stage,[string]$Destination){throw 'synthetic pre-move failure'}
    $failed=$false;try{Invoke-WsmOutputWorkspaceTransfer -PreviewPath $movePreview.Path -ExpectedHash $movePreview.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false}catch{$failed=$_.Exception.Message -like '*synthetic pre-move failure*'}
    Remove-Item Function:\Move-WsmWorkspaceTransferStage -ErrorAction SilentlyContinue;Set-Item Function:\Move-WsmWorkspaceTransferStage $realMove
    $moveMarker=Read-WsmJson (Join-Path $moveRoot 'workspace-control\workspace-transfer.json');Assert-TransferTest ($failed -and $moveMarker.Status -ceq 'Migrated' -and -not [IO.Directory]::Exists($moveDestination)) 'Pre-move fault did not leave an explicit recoverable source tombstone.'
    $moveRestore=New-WsmOutputWorkspaceTransferRestorePreview -SourceWorkRoot $moveRoot -DestinationWorkRoot $moveDestination -Path (Join-Path $testRoot 'move-failure-restore.json')
    Assert-TransferTest ($moveRestore.RecoveryMode -ceq 'Interrupted' -and $moveRestore.RecoveryComplete) 'Pre-move fault did not produce a complete interrupted-transfer preview.'
    $moveRecovery=Invoke-WsmOutputWorkspaceTransferRestore -PreviewPath $moveRestore.Path -ExpectedHash $moveRestore.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false
    Assert-TransferTest ($moveRecovery.Applied -and -not [IO.File]::Exists((Join-Path $moveRoot 'workspace-control\workspace-transfer.json')) -and (Read-WsmJson (Join-Path $moveMarker.StagingWorkRoot 'workspace-control\workspace-transfer.json')).Status -ceq 'MigratedBack') 'Pre-move recovery did not preserve/block stage and reactivate source.'

    $afterMoveRoot=New-TransferFixture $testRoot 'after-move-failure';$afterMoveDestination=Join-Path $testRoot 'after-move-moved';$afterMovePreview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $afterMoveRoot -DestinationWorkRoot $afterMoveDestination -Path (Join-Path $testRoot 'after-move-preview.json')
    $realRemove=(Get-Command Remove-WsmWorkspaceTransferMarker).ScriptBlock;function Remove-WsmWorkspaceTransferMarker([string]$Path){throw 'synthetic post-move marker-delete failure'}
    $failed=$false;try{Invoke-WsmOutputWorkspaceTransfer -PreviewPath $afterMovePreview.Path -ExpectedHash $afterMovePreview.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false}catch{$failed=$_.Exception.Message -like '*post-move marker-delete failure*'}
    Remove-Item Function:\Remove-WsmWorkspaceTransferMarker -ErrorAction SilentlyContinue;Set-Item Function:\Remove-WsmWorkspaceTransferMarker $realRemove
    Assert-TransferTest ($failed -and [IO.Directory]::Exists($afterMoveDestination) -and (Read-WsmJson (Join-Path $afterMoveDestination 'workspace-control\workspace-transfer.json')).Status -ceq 'Prepared') 'Post-move marker fault did not leave the destination blocked.'
    $afterMoveRestore=New-WsmOutputWorkspaceTransferRestorePreview -SourceWorkRoot $afterMoveRoot -DestinationWorkRoot $afterMoveDestination -Path (Join-Path $testRoot 'after-move-restore.json')
    Assert-TransferTest ($afterMoveRestore.RecoveryMode -ceq 'Interrupted' -and $afterMoveRestore.RecoveryComplete) 'Post-move fault did not produce a complete interrupted-transfer preview.'
    [void](Invoke-WsmOutputWorkspaceTransferRestore -PreviewPath $afterMoveRestore.Path -ExpectedHash $afterMoveRestore.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false)
    Assert-TransferTest (-not [IO.File]::Exists((Join-Path $afterMoveRoot 'workspace-control\workspace-transfer.json')) -and (Read-WsmJson (Join-Path $afterMoveDestination 'workspace-control\workspace-transfer.json')).Status -ceq 'MigratedBack') 'Post-move recovery did not reactivate the source after tombstoning the moved copy.'

    $deleteRoot=New-TransferFixture $testRoot 'restore-delete-failure';$deleteDestination=Join-Path $testRoot 'restore-delete-moved';$deletePreview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $deleteRoot -DestinationWorkRoot $deleteDestination -Path (Join-Path $testRoot 'restore-delete-preview.json');[void](Invoke-WsmOutputWorkspaceTransfer -PreviewPath $deletePreview.Path -ExpectedHash $deletePreview.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false)
    $deleteRestore=New-WsmOutputWorkspaceTransferRestorePreview -SourceWorkRoot $deleteRoot -DestinationWorkRoot $deleteDestination -Path (Join-Path $testRoot 'restore-delete-restore.json')
    $realRemove=(Get-Command Remove-WsmWorkspaceTransferMarker).ScriptBlock;function Remove-WsmWorkspaceTransferMarker([string]$Path){throw 'synthetic restore marker-delete failure'}
    $failed=$false;try{Invoke-WsmOutputWorkspaceTransferRestore -PreviewPath $deleteRestore.Path -ExpectedHash $deleteRestore.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false}catch{$failed=$_.Exception.Message -like '*restore marker-delete failure*'}
    Remove-Item Function:\Remove-WsmWorkspaceTransferMarker -ErrorAction SilentlyContinue;Set-Item Function:\Remove-WsmWorkspaceTransferMarker $realRemove
    Assert-TransferTest ($failed -and [IO.File]::Exists((Join-Path $deleteRoot 'workspace-control\workspace-transfer.json')) -and (Read-WsmJson (Join-Path $deleteDestination 'workspace-control\workspace-transfer.json')).Status -ceq 'MigratedBack') 'Restore marker-delete fault left no recoverable tombstone.'
    $retryRestore=New-WsmOutputWorkspaceTransferRestorePreview -SourceWorkRoot $deleteRoot -DestinationWorkRoot $deleteDestination -Path (Join-Path $testRoot 'restore-delete-retry.json')
    Assert-TransferTest ($retryRestore.RecoveryMode -ceq 'Interrupted') 'Restore marker-delete fault was not recognized as interrupted.'
    [void](Invoke-WsmOutputWorkspaceTransferRestore -PreviewPath $retryRestore.Path -ExpectedHash $retryRestore.SHA256 -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false)
    Assert-TransferTest (-not [IO.File]::Exists((Join-Path $deleteRoot 'workspace-control\workspace-transfer.json'))) 'Retry did not reactivate source after restore marker-delete fault.'

    $reparseRoot=New-TransferFixture $testRoot 'reparse';$reparseFile=Join-Path $reparseRoot 'workspace-control\extra.txt';[IO.File]::WriteAllText($reparseFile,'x');$script:UnsafePaths=@($reparseFile)
    $blocked=$false;try{New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $reparseRoot -DestinationWorkRoot (Join-Path $testRoot 'reparse-moved') -Path (Join-Path $testRoot 'reparse-preview.json') | Out-Null}catch{$blocked=$_.Exception.Message -like '*reparse point*'};Assert-TransferTest $blocked 'Reparse path was not rejected during preview.'

    $badHashRoot=New-TransferFixture $testRoot 'hash';$badHashPreview=New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $badHashRoot -DestinationWorkRoot (Join-Path $testRoot 'hash-moved') -Path (Join-Path $testRoot 'hash-preview.json');$blocked=$false
    try{Invoke-WsmOutputWorkspaceTransfer -PreviewPath $badHashPreview.Path -ExpectedHash ('0'*64) -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools -Confirm:$false}catch{$blocked=$_.Exception.Message -match 'trusted.*hash mismatch'}
    Assert-TransferTest $blocked 'Tampered preview hash was accepted.'

    $externalRoot=New-TransferFixture $testRoot 'external';[IO.File]::WriteAllText((Join-Path $externalRoot 'unexpected.txt'),'external')
    $blocked=$false;try{New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot $externalRoot -DestinationWorkRoot (Join-Path $testRoot 'external-moved') -Path (Join-Path $testRoot 'external-preview.json') | Out-Null}catch{$blocked=$_.Exception.Message -like '*unrecognized top-level entry*'};Assert-TransferTest $blocked 'Unknown top-level workspace content was accepted.'
    'PASS: workspace transfer preview/apply/restore, source revision and identity, manager catalog, target journal/attempt, hash/lock/ack/reparse/unknown-state negatives, WhatIf purity, and copy-failure fencing.'
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force}
