#requires -Version 5.1
# B1 / F1-P producer + projection contract. Pure parts run on temp files only; the end-to-end part drives the
# production one-click backup (real core export, package verification and delivery) over a three-item fixture and
# records every progress write through a script-scope wrapper of Write-WsmJson (no production test hook).
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$evidenceFixturePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1'))
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path payload test.'}
$substCommand='subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"';cmd.exe /c $substCommand
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the progress test.'}
$root=Join-Path ($driveLetter+':\') ('wsmbp-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$EvidenceFixturePath)
        . $EvidenceFixturePath
        $script:checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}

        # ---------------------------------------------------------------- seven-state mapping
        $mapping=@(
            @{Job='Queued';Stage='';Offline='';Failed=0;State='Waiting';Reason=''}
            @{Job='WaitingForInput';Stage='';Offline='';Failed=0;State='Waiting';Reason=''}
            @{Job='Running';Stage='';Offline='';Failed=0;State='Running';Reason=''}
            @{Job='CancelRequested';Stage='';Offline='';Failed=0;State='CancelRequested';Reason=''}
            @{Job='Succeeded';Stage='Delivered';Offline='AwaitingIndependentCopy';Failed=0;State='AwaitingDelivery';Reason=''}
            @{Job='Succeeded';Stage='Delivered';Offline='MediaNeedsReverification';Failed=0;State='AwaitingDelivery';Reason=''}
            @{Job='ReviewRequired';Stage='ReviewRequired';Offline='MediaNeedsReverification';Failed=0;State='AwaitingDelivery';Reason=''}
            @{Job='Succeeded';Stage='Delivered';Offline='Verified';Failed=0;State='Completed';Reason=''}
            @{Job='Succeeded';Stage='Delivered';Offline='VerifiedNetworkAvailabilityUnconfirmed';Failed=0;State='Completed';Reason=''}
            @{Job='Succeeded';Stage='Delivered';Offline='Verified';Failed=2;State='PartialFailure';Reason=''}
            @{Job='Succeeded';Stage='';Offline='';Failed=0;State='AwaitingDelivery';Reason=''}
            @{Job='ReviewRequired';Stage='ReviewRequired';Offline='NotDelivered';Failed=0;State='PartialFailure';Reason=''}
            @{Job='Failed';Stage='Failed';Offline='';Failed=0;State='Failed';Reason=''}
            @{Job='Cancelled';Stage='Cancelled';Offline='';Failed=0;State='Failed';Reason='Cancelled'}
            @{Job='Interrupted';Stage='Authorized';Offline='';Failed=0;State='Failed';Reason='Interrupted'}
        )
        foreach($row in $mapping){
            $result=Get-WsmBackupProgressState $row.Job $row.Stage $row.Offline $row.Failed
            Check ($result.State -ceq $row.State -and $result.EndReason -ceq $row.Reason) ('State mapping wrong for '+$row.Job+'/'+$row.Offline+'/'+$row.Failed+': got '+$result.State+'/'+$result.EndReason)
        }
        $covered=@($mapping|ForEach-Object {$_.State}|Sort-Object -Unique)
        Check ($covered.Count -eq 7) ('The mapping table does not exercise all seven states: '+($covered -join ','))
        Write-Host 'PASS: seven job states map from job status, attempt stage and independent-copy readiness.'

        # ---------------------------------------------------------------- producer unit behaviour
        $workspace=Join-Path $Root 'unit-workspace';[void][IO.Directory]::CreateDirectory($workspace)
        $pair=[Guid]::NewGuid().ToString('D');$op=[Guid]::NewGuid().ToString('D')
        function New-FakeItems([int]$Count,[string]$SourceRoot) {
            @(for($i=1;$i -le $Count;$i++){[pscustomobject]@{ItemId=('item-'+$i.ToString('000'));NaturalKey=('Workload '+$i);Kind='DataRoot';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$SourceRoot}}})
        }
        $script:WsmWizardBackupProgressIntervalMs=0
        $fakeRoot='D:\data\site'
        $progress=New-WsmWizardBackupProgress $workspace $pair $op ([Guid]::NewGuid().ToString('D')) (New-FakeItems 25 $fakeRoot)
        for($i=1;$i -le 25;$i++){Update-WsmWizardBackupProgressItem $progress $i 25 ('Workload '+$i) ($fakeRoot+'\sub\file'+$i+'.bin') ([long]($i*1000))}
        $raw=Read-WsmWizardBackupProgress $workspace $pair $op
        Check ($raw -and $raw.Stage -ceq 'Capture' -and $raw.StageIndex -eq 1 -and $raw.StageCount -eq 3) 'Capture stage position was not persisted as step 1 of 3.'
        Check ($raw.ItemsTotal -eq 25 -and $raw.ItemsDone -eq 24) ('Items done/total did not advance with the exporter: '+$raw.ItemsDone+'/'+$raw.ItemsTotal)
        Check ($raw.CurrentFile -ceq 'sub\file25.bin') ('The current file must be relative to the scope root: '+$raw.CurrentFile)
        Check ($raw.Workload -ceq 'Workload 25') 'The current workload display name was not persisted.'
        Check (@($raw.Recent).Count -eq 20) ('Recent must be capped at 20 rows after 24 completions, got '+@($raw.Recent).Count)
        Check ($raw.Recent[0].ItemId -ceq 'item-005' -and $raw.Recent[19].ItemId -ceq 'item-024') 'Recent must be first-in-first-out: the oldest rows fall off and the newest stay last.'
        foreach($entry in @($raw.Recent)){Check (@($entry.PSObject.Properties.Name|Sort-Object) -join ',' -ceq 'ItemId,Result') 'A Recent row may only contain ItemId and Result.'}
        Set-WsmWizardBackupProgressStage $progress 'Verify' 123456
        Set-WsmWizardBackupProgressStage $progress 'Deliver' 123456
        Complete-WsmWizardBackupProgress $progress 'Succeeded'
        $raw=Read-WsmWizardBackupProgress $workspace $pair $op
        Check ($raw.Stage -ceq 'Deliver' -and $raw.StageIndex -eq 3 -and $raw.ItemsDone -eq 25 -and $raw.ItemsTotal -eq 25 -and $raw.Terminal -eq $true -and $raw.Outcome -ceq 'Succeeded') 'Final record is not the completed step 3 of 3 with 25/25 items.'
        Check ($raw.BytesDone -eq 123456 -and $raw.BytesTotal -eq 123456) 'Bytes did not become known (and equal) once the package was sealed.'
        Check (@($raw.Recent).Count -eq 20 -and $raw.Recent[19].ItemId -ceq 'item-025' -and $raw.Recent[0].ItemId -ceq 'item-006') 'After the last stage Recent must hold exactly the newest 20 completed items.'
        Check ((New-Object IO.FileInfo((Get-WsmWizardBackupProgressPath $workspace $pair $op))).Length -le 4096) 'The progress record exceeded its fixed 4 KiB bound.'
        Check (@(Get-ChildItem -LiteralPath (Split-Path -Parent (Get-WsmWizardBackupProgressPath $workspace $pair $op)) -Force|Where-Object {$_.Extension -in @('.tmp','.bak')}).Count -eq 0) 'Atomic replace left temporary files behind.'
        Write-Host 'PASS: producer fields, relative current file, 20-row FIFO Recent, step n/m and 4 KiB bound.'

        # Unknown totals are null, never 0.
        $unknownOp=[Guid]::NewGuid().ToString('D')
        $unknown=New-WsmWizardBackupProgress $workspace $pair $unknownOp ([Guid]::NewGuid().ToString('D')) @()
        Update-WsmWizardBackupProgressItem $unknown 1 0 'Anything' 'C:\x\y.txt' 0
        $unknownRaw=Read-WsmWizardBackupProgress $workspace $pair $unknownOp
        Check ($null -eq $unknownRaw.ItemsTotal -and $null -eq $unknownRaw.BytesTotal) 'Unknown totals must be stored as null, not 0.'
        $unknownView=ConvertTo-WsmWizardBackupProgressView $unknownRaw 'Running'
        Check ($null -eq $unknownView.ItemsTotal -and $null -eq $unknownView.BytesTotal -and $null -eq $unknownView.Percent) 'The projection must keep unknown totals and percent as null.'
        Write-Host 'PASS: unknown totals stay null through storage and projection.'

        # Throttle: with the shipped one-second interval a burst of file callbacks is one disk write, a stage change is forced.
        Remove-Variable WsmWizardBackupProgressIntervalMs -Scope Script
        $throttleOp=[Guid]::NewGuid().ToString('D')
        $throttled=New-WsmWizardBackupProgress $workspace $pair $throttleOp ([Guid]::NewGuid().ToString('D')) (New-FakeItems 400 $fakeRoot)
        Check ($throttled.IntervalMs -eq 1000) 'The default write interval must be 1000 ms.'
        for($i=1;$i -le 400;$i++){Update-WsmWizardBackupProgressItem $throttled $i 400 ('Workload '+$i) ($fakeRoot+'\f'+$i) ([long]$i)}
        Check ($throttled.Writes -le 2) ('400 quick file callbacks produced '+$throttled.Writes+' writes; the interval throttle is not working.')
        Set-WsmWizardBackupProgressStage $throttled 'Verify' 5
        $writesAfterStage=$throttled.Writes
        Check ($writesAfterStage -ge 2) 'A stage change must always be written.'
        $throttledRaw=Read-WsmWizardBackupProgress $workspace $pair $throttleOp
        Check ($throttledRaw.Stage -ceq 'Verify' -and $throttledRaw.ItemsDone -eq 400 -and @($throttledRaw.Recent).Count -eq 20) 'The forced stage write must flush every completed item (400) while Recent stays at 20.'
        Write-Host 'PASS: writes are throttled to one per interval, stage changes are forced.'

        # Oversized text still fits in 4 KiB.
        $bigOp=[Guid]::NewGuid().ToString('D');$script:WsmWizardBackupProgressIntervalMs=0
        $bigItems=@(for($i=1;$i -le 30;$i++){[pscustomobject]@{ItemId=('item-'+('x'*100)+$i);NaturalKey=('N'*300);Kind='DataRoot';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\a'}}})
        $big=New-WsmWizardBackupProgress $workspace $pair $bigOp ([Guid]::NewGuid().ToString('D')) $bigItems
        for($i=1;$i -le 30;$i++){Update-WsmWizardBackupProgressItem $big $i 30 ('N'*300) ('D:\a\'+('d'*200)+'\'+('f'*200)) 1}
        Set-WsmWizardBackupProgressStage $big 'Verify' 1
        Check ((New-Object IO.FileInfo((Get-WsmWizardBackupProgressPath $workspace $pair $bigOp))).Length -le 4096) 'A worst-case record exceeded 4 KiB.'
        Check ($null -ne (Read-WsmWizardBackupProgress $workspace $pair $bigOp)) 'The worst-case record could not be read back.'
        Write-Host 'PASS: worst-case names and paths stay within the 4 KiB bound.'

        # ---------------------------------------------------------------- N2: current item id / type / channel / file sequence
        $zhChannelC=[regex]::Unescape('C \u69fd');$zhChannelNonC=[regex]::Unescape('\u975e C \u69fd');$zhUnknown=[regex]::Unescape('\u672a\u77e5');$zhUnrecorded=[regex]::Unescape('\u672a\u8a18\u9304')
        $n2Spec={param($Adapter,$Channel,$Root) $s=[ordered]@{Adapter=$Adapter;SourcePath=$Root};if($null -ne $Channel){$s.TransferChannel=$Channel};[pscustomobject]$s}
        $n2Items=@(
            [pscustomobject]@{ItemId='n2-c';NaturalKey='C scope';Kind='DataRoot';MigrationSpec=(& $n2Spec 'FileScope' 'C' 'D:\n2c')}
            [pscustomobject]@{ItemId='n2-nonc';NaturalKey='NonC scope';Kind='DataRoot';MigrationSpec=(& $n2Spec 'FileScope' 'NonC' 'E:\n2d')}
            [pscustomobject]@{ItemId='n2-cert';NaturalKey='Certificate';Kind='Certificate';MigrationSpec=(& $n2Spec 'Certificate' $null '')}
            [pscustomobject]@{ItemId='n2-default';NaturalKey='No channel property';Kind='DataRoot';MigrationSpec=(& $n2Spec 'FileScope' $null 'D:\n2e')}
            [pscustomobject]@{ItemId='n2-odd';NaturalKey='Unexpected channel value';Kind='DataRoot';MigrationSpec=(& $n2Spec 'FileScope' 'Mystery' 'D:\n2f')}
        )
        $n2Expect=@(@{Channel='C';Label=$zhChannelC;Type='FileScope'},@{Channel='NonC';Label=$zhChannelNonC;Type='FileScope'},@{Channel='Unknown';Label=$zhUnknown;Type='Certificate'},@{Channel='C';Label=$zhChannelC;Type='FileScope'},@{Channel='Unknown';Label=$zhUnknown;Type='FileScope'})
        $n2Op=[Guid]::NewGuid().ToString('D');$script:WsmWizardBackupProgressIntervalMs=0
        $n2=New-WsmWizardBackupProgress $workspace $pair $n2Op ([Guid]::NewGuid().ToString('D')) $n2Items
        for($i=1;$i -le 5;$i++){
            Update-WsmWizardBackupProgressItem $n2 $i 5 $n2Items[$i-1].NaturalKey ($n2Items[$i-1].MigrationSpec.SourcePath+'\f.bin') ([long]($i*100)) ([long]($i*10))
            $raw=Read-WsmWizardBackupProgress $workspace $pair $n2Op;$want=$n2Expect[$i-1]
            Check ($raw.CurrentItemId -ceq $n2Items[$i-1].ItemId) ('CurrentItemId is not the current item at step '+$i+': '+$raw.CurrentItemId)
            Check ($raw.CurrentItemType -ceq $want.Type) ('CurrentItemType wrong at step '+$i+': '+$raw.CurrentItemType)
            Check ($raw.CurrentItemTypeLabel -ceq (Get-WsmWizardItemTypeLabel $want.Type ([string]$n2Items[$i-1].Kind))) ('The type label must come from Get-WsmWizardItemTypeLabel at step '+$i)
            Check ($raw.CurrentChannel -ceq $want.Channel) ('CurrentChannel wrong at step '+$i+': expected '+$want.Channel+', got '+$raw.CurrentChannel)
            Check ($raw.FilesDone -eq $i*10 -and $null -eq $raw.FilesTotal) ('FilesDone must follow the exporter and FilesTotal stay null while unknown, step '+$i+': '+$raw.FilesDone+'/'+$raw.FilesTotal)
            $view=ConvertTo-WsmWizardBackupProgressView $raw 'Running'
            Check ($view.ItemFieldsRecorded -eq $true -and $view.CurrentChannel -ceq $want.Channel -and $view.CurrentChannelLabel -ceq $want.Label -and $view.CurrentItemId -ceq $n2Items[$i-1].ItemId -and $view.FilesDone -eq $i*10 -and $null -eq $view.FilesTotal) ('The projection lost an item field at step '+$i)
        }
        Check ($n2.Record.CurrentChannel -ceq 'Unknown') 'The last mocked item has an unexpected channel and must read Unknown.'
        Set-WsmWizardBackupProgressStage $n2 'Verify' 500 77
        $raw=Read-WsmWizardBackupProgress $workspace $pair $n2Op
        Check ($raw.CurrentItemId -ceq '' -and $raw.CurrentChannel -ceq 'Unknown' -and $raw.FilesDone -eq 77 -and $raw.FilesTotal -eq 77) 'Leaving Capture must clear the current item and publish the sealed file count as done and total.'
        Write-Host 'PASS: current item id, type code and label, channel (C / NonC / Unknown) and file sequence are independent fields.'

        # Worst cases: the item fields are never cut; the stored names shrink and Recent still keeps 20 rows.
        $zhLong=([string][char]0x7db2)*300;$escapeHeavy=('<>&''"'*50)
        foreach($case in @(@{Name='CJK';Text=$zhLong},@{Name='escape-heavy';Text=$escapeHeavy})){
            $worstOp=[Guid]::NewGuid().ToString('D')
            $worstItems=@(for($i=1;$i -le 30;$i++){[pscustomobject]@{ItemId=(([Guid]::NewGuid().ToString('N'))+([Guid]::NewGuid().ToString('N')));NaturalKey=$case.Text;Kind='DataRoot';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\a';TransferChannel='NonC'}}})
            $worst=New-WsmWizardBackupProgress $workspace $pair $worstOp ([Guid]::NewGuid().ToString('D')) $worstItems
            for($i=1;$i -le 30;$i++){Update-WsmWizardBackupProgressItem $worst $i 30 $case.Text ('D:\a\'+(([string][char]0x6a94)*200)+'\'+('f'*200)) 9999999999 ([long]1234567890+$i)}
            $worstPath=Get-WsmWizardBackupProgressPath $workspace $pair $worstOp
            $rawWorst=Read-WsmWizardBackupProgress $workspace $pair $worstOp
            Check ((New-Object IO.FileInfo($worstPath)).Length -le 4096) ('The '+$case.Name+' worst case exceeded 4 KiB: '+(New-Object IO.FileInfo($worstPath)).Length)
            Check (@($rawWorst.Recent).Count -eq 20) ('The '+$case.Name+' worst case must still keep 20 Recent rows, got '+@($rawWorst.Recent).Count)
            Check ($rawWorst.CurrentItemId -ceq $worstItems[29].ItemId -and $rawWorst.CurrentChannel -ceq 'NonC' -and $rawWorst.CurrentItemType -ceq 'FileScope' -and $rawWorst.CurrentItemTypeLabel -ceq (Get-WsmWizardItemTypeLabel 'FileScope' 'DataRoot') -and $rawWorst.FilesDone -eq 1234567920) ('The '+$case.Name+' worst case cut a new field.')
        }
        Write-Host 'PASS: 4 KiB worst case keeps every new field untruncated and still holds 20 Recent rows.'

        # Chinese, spaces and markup are persisted verbatim (JSON-escaped on disk) and projected unchanged.
        $zhName=[regex]::Unescape('\u7db2\u7ad9 \u7532 <script>alert(1)</script> "q" \u0027a\u0027');$zhDir=[regex]::Unescape('D:\\\u7db2\u7ad9 \u8cc7\u6599\\My Data');$zhRel=[regex]::Unescape('\u5b50 \u76ee\u9304\\<img src=x onerror=1> \u5831\u8868 (\u6700\u7d42) 1.txt')
        $oddOp=[Guid]::NewGuid().ToString('D')
        $oddItems=@([pscustomobject]@{ItemId='odd-1';NaturalKey=$zhName;Kind='DataRoot';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$zhDir;TransferChannel='C'}},[pscustomobject]@{ItemId='odd-2';NaturalKey='next';Kind='DataRoot';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\next';TransferChannel='C'}})
        $odd=New-WsmWizardBackupProgress $workspace $pair $oddOp ([Guid]::NewGuid().ToString('D')) $oddItems
        Update-WsmWizardBackupProgressItem $odd 1 2 $zhName ($zhDir+'\'+$zhRel) 10 3
        Update-WsmWizardBackupProgressItem $odd 2 2 'next' 'D:\next\x' 20 4
        $oddPath=Get-WsmWizardBackupProgressPath $workspace $pair $oddOp
        $oddText=[IO.File]::ReadAllText($oddPath,(New-Object Text.UTF8Encoding($false,$true)))
        $oddParsed=$oddText|ConvertFrom-Json
        Check ($oddParsed.Recent[0].ItemId -ceq 'odd-1' -and $oddParsed.ItemNames.'odd-1' -ceq $zhName) 'The remembered item name was not stored verbatim (valid JSON, exact text).'
        $oddRaw=Read-WsmWizardBackupProgress $workspace $pair $oddOp
        Update-WsmWizardBackupProgressItem $odd 1 2 $zhName ($zhDir+'\'+$zhRel) 10 3
        $oddRaw=Read-WsmWizardBackupProgress $workspace $pair $oddOp
        Check ($oddRaw.Workload -ceq $zhName -and $oddRaw.CurrentFile -ceq $zhRel) 'Chinese, spaces and markup must reach the progress file verbatim.'
        Check ($oddText.Contains([regex]::Unescape('\u7db2\u7ad9')) -and -not $oddText.Contains('<script>')) 'The file must keep Chinese literally and JSON-escape markup instead of storing it raw.'
        $oddView=ConvertTo-WsmWizardBackupProgressView $oddRaw 'Running'
        Check ($oddView.Workload -ceq $zhName -and $oddView.CurrentFile -ceq $zhRel -and $oddView.Recent[0].ItemName -ceq $zhName) 'The projection must pass text through unchanged (the UI escapes it).'
        Write-Host 'PASS: Chinese names, paths with spaces and markup land verbatim and JSON-escaped, and project unchanged.'

        # A record written before the item fields existed reads as "not recorded".
        $legacyOp=[Guid]::NewGuid().ToString('D')
        $legacyObject=(Get-Content -LiteralPath (Get-WsmWizardBackupProgressPath $workspace $pair $n2Op) -Raw -Encoding UTF8)|ConvertFrom-Json
        $legacyObject.OperationId=$legacyOp
        foreach($dropped in 'CurrentItemId','CurrentItemType','CurrentItemTypeLabel','CurrentChannel','FilesDone','FilesTotal'){[void]$legacyObject.PSObject.Properties.Remove($dropped)}
        Write-WsmWizardBackupProgressFile (Get-WsmWizardBackupProgressPath $workspace $pair $legacyOp) ($legacyObject|ConvertTo-Json -Depth 6 -Compress)
        $legacyRaw=Read-WsmWizardBackupProgress $workspace $pair $legacyOp
        Check ($null -ne $legacyRaw -and -not $legacyRaw.PSObject.Properties['CurrentChannel']) 'The legacy fixture must really lack the new fields.'
        $legacyView=ConvertTo-WsmWizardBackupProgressView $legacyRaw 'Running'
        Check ($legacyView.ItemFieldsRecorded -eq $false -and $legacyView.CurrentChannelLabel -ceq $zhUnrecorded -and $legacyView.CurrentItemTypeLabel -ceq $zhUnrecorded -and $null -eq $legacyView.FilesDone -and $null -eq $legacyView.FilesTotal -and $legacyView.CurrentItemId -ceq '') 'An old record must read as not recorded (never as an empty channel or a zero file count).'
        $legacyJob=@{Record=[pscustomobject]@{action='StartBackup';status='Interrupted';workspace=$workspace;pairId=$pair;jobId=$legacyOp;role='Source'};Path=(Join-Path $workspace 'legacy.json');Handle=$null;PowerShell=$null}
        $legacyProjected=(Get-WsmHtmlProgressProjection $legacyJob).backup
        Check ($legacyProjected.ItemFieldsRecorded -eq $false -and $legacyProjected.CurrentChannelLabel -ceq $zhUnrecorded) 'The job projection of an old record must say not recorded.'
        $newJob=@{Record=[pscustomobject]@{action='StartBackup';status='Running';workspace=$workspace;pairId=$pair;jobId=$n2Op;role='Source'};Path=(Join-Path $workspace 'n2.json');Handle=$null;PowerShell=$null}
        $newProjected=(Get-WsmHtmlProgressProjection $newJob).backup
        foreach($field in 'ItemFieldsRecorded','CurrentItemId','CurrentItemType','CurrentItemTypeLabel','CurrentChannel','CurrentChannelLabel','FilesDone','FilesTotal'){Check (@($newProjected.PSObject.Properties.Name) -ccontains $field) ('The WizardHtmlRuntime allow-list dropped '+$field)}
        Check ($newProjected.ItemFieldsRecorded -eq $true -and $newProjected.FilesDone -eq 77 -and $newProjected.FilesTotal -eq 77) 'The job projection of a new record lost its file sequence.'
        Write-Host 'PASS: records without the new fields read as not recorded; the allow-list passes the new fields.'

        # Projection from the durable file: restart readback and Interrupted keeps the last progress.
        $interruptedOp=[Guid]::NewGuid().ToString('D')
        $partial=New-WsmWizardBackupProgress $workspace $pair $interruptedOp ([Guid]::NewGuid().ToString('D')) (New-FakeItems 6 $fakeRoot)
        for($i=1;$i -le 4;$i++){Update-WsmWizardBackupProgressItem $partial $i 6 ('Workload '+$i) ($fakeRoot+'\q'+$i) ([long]($i*10))}
        $lastWrite=(Read-WsmWizardBackupProgress $workspace $pair $interruptedOp).UpdatedUtc
        $record=[pscustomobject]@{action='StartBackup';status='Interrupted';workspace=$workspace;pairId=$pair;jobId=$interruptedOp;role='Source'}
        $job=@{Record=$record;Path=(Join-Path $workspace 'x.json');Handle=$null;PowerShell=$null}
        $restarted=Get-WsmHtmlProgressProjection $job
        Check ($restarted -and $restarted.backup -and $restarted.backup.State -ceq 'Failed' -and $restarted.backup.EndReason -ceq 'Interrupted') 'A restarted Interrupted job did not read back its progress as an interrupted failure.'
        Check ($restarted.backup.ItemsDone -eq 3 -and $restarted.backup.ItemsTotal -eq 6 -and $restarted.backup.UpdatedUtc -ceq $lastWrite -and $restarted.backup.Workload -ceq 'Workload 4') 'Interrupted must keep the last progress and its last-update time.'
        $other=@{Record=[pscustomobject]@{action='Inventory';status='Running';workspace=$workspace;pairId=$pair;jobId=[Guid]::NewGuid().ToString('D');role='Source'};Handle=$null;PowerShell=$null}
        Check ($null -eq (Get-WsmHtmlProgressProjection $other)) 'A non-backup job must not get a backup progress card.'
        $foreign=@{Record=[pscustomobject]@{action='StartBackup';status='Running';workspace=$workspace;pairId=$pair;jobId=[Guid]::NewGuid().ToString('D');role='Source'};Handle=$null;PowerShell=$null}
        Check ($null -eq (Get-WsmHtmlProgressProjection $foreign)) 'A job without a progress record must not invent one.'
        Write-Host 'PASS: restart readback by parent job id keeps the last progress and last-update time for Interrupted.'

        # HTML projection allow-list: only the closed field set survives.
        $leak=[pscustomobject]@{Kind='WizardBackupProgress';PairId=$pair;OperationId=$op;Stage='Capture';StageIndex=1;StageCount=3;Workload='x';CurrentFile='y';ItemsDone=0;ItemsTotal=1;BytesDone=0;BytesTotal=$null;FailedCount=0;Terminal=$false;Outcome='';StartedUtc=(Get-WsmUtc);UpdatedUtc=(Get-WsmUtc);Recent=@();ItemNames=[pscustomobject]@{};SecretToken='must-not-pass';PlanPath='C:\secret\plan.json'}
        $safeView=ConvertTo-WsmWizardBackupProgressView $leak 'Running'
        $names=@($safeView.PSObject.Properties.Name)
        foreach($required in @('Stage','StageLabel','StageIndex','StageCount','Workload','CurrentFile','ItemFieldsRecorded','CurrentItemId','CurrentItemType','CurrentItemTypeLabel','CurrentChannel','CurrentChannelLabel','FilesDone','FilesTotal','ItemsDone','ItemsTotal','BytesDone','BytesTotal','StartedUtc','UpdatedUtc','Recent','State')){Check ($names -ccontains $required) ('The HTML view lost the allowed field '+$required)}
        foreach($forbidden in @('SecretToken','PlanPath','OperationId','PairId','AttemptId','ItemNames')){Check ($names -cnotcontains $forbidden) ('The HTML view leaked '+$forbidden)}
        Write-Host 'PASS: HTML projection passes the closed allow-list and drops everything else.'

        # ---------------------------------------------------------------- end to end over the real one-click backup
        $script:backupFixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:backupFixtureFingerprint;Name='backup-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:backupFixtureInventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:backupFixtureInventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:backupFixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:backupFixtureInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        # Fixture builder: dot-sourced once per scenario ($sfx = directory suffix, $fixtureChannels = TransferChannel per item).
        $buildFixture={
        $sourceRoot=Join-Path $Root ('source-work'+$sfx);$targetRoot=Join-Path $Root ('target-work'+$sfx);$managerRoot=Join-Path $Root ('manager-work'+$sfx)
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:backupFixtureFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:backupFixtureFingerprint=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        # The names carry synthetic secret-looking text; the progress record must never contain the secret value.
        $sentinel='SENTINEL-Zq8-secret-value'
        $dirNames=@('alpha','bravo','charlie');$fileCounts=@(2,3,1);$items=@();$dirs=@();$expectedBytes=[long]0;$expectedFiles=0
        for($n=0;$n -lt 3;$n++){
            $dir=Join-Path $Root ('source-data-'+$dirNames[$n]+$sfx);[void][IO.Directory]::CreateDirectory($dir);[void][IO.Directory]::CreateDirectory((Join-Path $dir 'nested'))
            for($f=1;$f -le $fileCounts[$n];$f++){
                $fileName=if($n -eq 2){'password='+$sentinel+'.txt'}else{('file'+$f+'.txt')}
                $text=('payload '+$dirNames[$n]+' '+$f);[IO.File]::WriteAllText((Join-Path (Join-Path $dir 'nested') $fileName),$text);$expectedBytes+=[Text.Encoding]::UTF8.GetByteCount($text);$expectedFiles++
            }
            $label=if($n -eq 2){'Fixture charlie token='+$sentinel}else{'Fixture '+$dirNames[$n]}
            $naturalKey=if($n -eq 2){'fixture-charlie password='+$sentinel}else{'fixture-'+$dirNames[$n]}
            $dirs+=@($dir)
            $items+=@(New-WsmItem $source.HostId Storage DataRoot $label $naturalKey @{Path=$dir})
        }
        $inventory=New-WsmInventory $source 1 $items;$inventoryPath=Join-Path $Root ('inventory'+$sfx+'.json');Write-WsmJson $inventoryPath $inventory;$script:backupFixtureInventoryPath=$inventoryPath
        Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target'
        $revision=0
        for($n=0;$n -lt 3;$n++){
            $item=$items[$n];$dataDir=[string]$dirs[$n]
            $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$dataDir;TargetPath=(Join-Path $Root ('restored-'+$dirNames[$n]+$sfx));TransferChannel=$fixtureChannels[$n];ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Isolated actual bytes test';BusinessChecks=@('Read back each source file')}
            $specPath=Join-Path $Root ('spec-'+$dirNames[$n]+$sfx+'.json');Write-WsmJson $specPath $spec
            Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash $revision
            $revision++
        }
        Set-WsmDecision $managerRoot $catalog.PairId @($items|ForEach-Object {$_.ItemId}) Include 'Explicit fixture selection' $revision|Out-Null
        $planPath=Join-Path $Root ('approved-plan'+$sfx+'.json');$approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath ($revision+1) 'ISOLATED-PILOT'
        $script:backupFixtureFingerprint=('a'*64)
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        Check ($import.Status -ceq 'ImportedVerified') 'Source did not import the three-item sealed plan.'
        $attemptRoot=Get-WsmWizardBackupRoot $sourceRoot $catalog.PairId
        }
        $sfx='';$fixtureChannels=@('C','C','C');. $buildFixture
        $planRefMain=Get-WsmWizardCurrentApprovedPlan $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $null @()

        # Wrap the progress file writer only to record every progress write as it happens.
        $originalWriteJson=(Get-Command Write-WsmWizardBackupProgressFile -CommandType Function).ScriptBlock
        $script:progressOriginalWriteJson=$originalWriteJson;$script:progressSeen=New-Object 'System.Collections.Generic.List[object]'
        function script:Write-WsmWizardBackupProgressFile {param([string]$Path,[string]$Json);if($Path -like '*\wizard-backups\*\progress\*.json'){$script:progressSeen.Add(($Json|ConvertFrom-Json))};& $script:progressOriginalWriteJson $Path $Json}
        $script:WsmWizardBackupProgressIntervalMs=0

        $okOp=[Guid]::NewGuid().ToString('D');$okToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $okOp
        $failedOp=[Guid]::NewGuid().ToString('D');$failedToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $failedOp
        $cancelOp=[Guid]::NewGuid().ToString('D');$cancelToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $cancelOp
        try{
            # 3) the full successful run, observed write by write.
            $script:progressSeen.Clear()
            $result=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $okOp -Jobs @() -CancellationToken $okToken -DeliveryMode Directory -VolumeBytes 0
            $seenSuccess=@($script:progressSeen.ToArray())
            # 2) pre-cancelled run on a fresh attempt: the cancel boundary fires inside Capture.
            Request-WsmCancellation -Token $cancelToken -Owner 'Fixture operator' -Evidence 'Progress cancel case'|Out-Null
            $cancelled=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $cancelOp -Jobs @() -CancellationToken $cancelToken -DeliveryMode Directory -VolumeBytes 0|Out-Null}catch{$cancelled=$true}
            Check $cancelled 'The pre-cancelled backup did not stop.'
            $cancelRaw=Read-WsmWizardBackupProgress $sourceRoot $catalog.PairId $cancelOp
            Check ($cancelRaw -and $cancelRaw.Terminal -eq $true -and $cancelRaw.Outcome -ceq 'Cancelled' -and $cancelRaw.Stage -ceq 'Capture') 'A cancelled backup must leave a terminal Cancelled progress record at the Capture stage.'

            # 3) the cancelled attempt is resumed and fails package verification: Capture finished, Verify failed.
            $script:progressSeen.Clear()
            $originalPackageTest=(Get-Command Test-WsmMigrationPackage -CommandType Function).ScriptBlock;$script:progressOriginalPackageTest=$originalPackageTest
            $script:progressPackageTestCalls=0
            function script:Test-WsmMigrationPackage {param([string]$ManifestPath,[string]$ExpectedHash,$CancellationToken=$null);$script:progressPackageTestCalls++;if($script:progressPackageTestCalls -ge 2){throw 'Injected package verification interruption.'};& $script:progressOriginalPackageTest $ManifestPath $ExpectedHash $CancellationToken}
            $failed=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $failedOp -Jobs @() -CancellationToken $failedToken -DeliveryMode Directory -VolumeBytes 0|Out-Null}catch{$failed=$true}
            Set-Item -Path Function:\script:Test-WsmMigrationPackage -Value $originalPackageTest
            Check $failed 'The injected verification failure did not stop the backup.'
            $failedRaw=Read-WsmWizardBackupProgress $sourceRoot $catalog.PairId $failedOp
            Check ($failedRaw.Terminal -eq $true -and $failedRaw.Outcome -ceq 'Failed' -and $failedRaw.Stage -ceq 'Verify' -and $failedRaw.StageIndex -eq 2 -and $failedRaw.ItemsDone -eq 3 -and $failedRaw.ItemsTotal -eq 3) 'A failed verification must end at step 2 of 3 with all three items captured.'
            Write-Host 'PASS: cancelled and failed runs leave a terminal progress record at the real stage.'

        }finally{
            Set-Item -Path Function:\script:Write-WsmWizardBackupProgressFile -Value $originalWriteJson
            Remove-Variable progressOriginalWriteJson,progressOriginalPackageTest,progressPackageTestCalls -Scope Script -ErrorAction SilentlyContinue
        }
        Check ($result.Stage -ceq 'Delivered') 'The three-item fixture backup did not finish.'
        $seen=$seenSuccess
        Check ($seen.Count -ge 6) ('Too few progress writes were observed: '+$seen.Count)
        $stageSequence=@();foreach($snapshot in $seen){if(-not $stageSequence.Count -or $stageSequence[-1] -ne [int]$snapshot.StageIndex){$stageSequence+=@([int]$snapshot.StageIndex)}}
        Check (($stageSequence -join ',') -ceq '1,2,3') ('Stage position did not advance 1 -> 2 -> 3: '+($stageSequence -join ','))
        $captureDone=@($seen|Where-Object {[int]$_.StageIndex -eq 1}|ForEach-Object {[int]$_.ItemsDone}|Sort-Object -Unique)
        Check (($captureDone -join ',') -ceq '0,1,2') ('Items done must advance 0,1,2 while capturing the three items, saw '+($captureDone -join ','))
        $monotonic=$true;for($i=1;$i -lt $seen.Count;$i++){if([int]$seen[$i].ItemsDone -lt [int]$seen[$i-1].ItemsDone -or [int]$seen[$i].StageIndex -lt [int]$seen[$i-1].StageIndex){$monotonic=$false}}
        Check $monotonic 'Progress went backwards.'
        $workloadsSeen=@($seen|Where-Object {$_.Workload}|ForEach-Object {[string]$_.Workload}|Sort-Object -Unique)
        Check ($workloadsSeen.Count -eq 3) ('Every workload must be observed as the current item at least once, saw '+$workloadsSeen.Count)
        Check (@($seen|Where-Object {$_.CurrentFile -and ([string]$_.CurrentFile -match '^[A-Za-z]:' -or [string]$_.CurrentFile -match '\\\\')}).Count -eq 0) 'CurrentFile must be a relative path.'
        Check (@($seen|Where-Object {[int]$_.StageIndex -eq 1 -and $_.CurrentFile -like 'nested\*'}).Count -ge 1) 'The relative current file (nested\...) was never observed.'
        $final=Read-WsmWizardBackupProgress $sourceRoot $catalog.PairId $okOp
        Check ($final.Terminal -eq $true -and $final.Outcome -ceq 'Succeeded' -and $final.Stage -ceq 'Deliver' -and $final.StageIndex -eq 3 -and $final.StageCount -eq 3) 'The final record is not the completed step 3 of 3.'
        Check ($final.ItemsDone -eq 3 -and $final.ItemsTotal -eq 3 -and @($final.Recent).Count -eq 3) 'The final n/N must equal the manifest workload count (3).'
        Check ((@($final.Recent|ForEach-Object {$_.ItemId}|Sort-Object) -join ',') -ceq (@($items|ForEach-Object {$_.ItemId}|Sort-Object) -join ',')) 'Recent must list exactly the three captured items.'
        Check (@($final.Recent|Where-Object Result -cne 'Succeeded').Count -eq 0) 'All three items should have been recorded as Succeeded.'
        Check ([long]$final.BytesDone -eq [long]$result.CoreExport.Bytes -and [long]$final.BytesTotal -eq [long]$result.CoreExport.Bytes -and [long]$result.CoreExport.Bytes -eq $expectedBytes) ('Final bytes '+$final.BytesDone+' must equal the sealed payload bytes '+$result.CoreExport.Bytes+' and the fixture bytes '+$expectedBytes)
        Check ([long]$result.CoreExport.Files -eq $expectedFiles) 'Fixture file count differs from the sealed package.'
        Write-Host 'PASS: real one-click backup advances step n/m and item counts, ends at 3/3 items with sealed payload bytes.'

        # Durable readback by parent id and the projection once finished.
        $okRecord=[pscustomobject]@{action='StartBackup';status='Succeeded';workspace=$sourceRoot;pairId=$catalog.PairId;jobId=$okOp;role='Source'}
        $okJob=@{Record=$okRecord;Path=(Join-Path $Root 'job.json');Handle=$null;PowerShell=$null}
        $finishedView=(Get-WsmHtmlProgressProjection $okJob).backup
        Check ($finishedView.State -ceq 'AwaitingDelivery' -and $finishedView.Percent -eq 100 -and $finishedView.ItemsDone -eq 3) ('A delivered backup without an independent copy must read back as awaiting delivery, got '+$finishedView.State)
        Check (@($finishedView.Recent|Where-Object {$_.ItemName}).Count -eq 3) 'The projection must attach each item display name next to its stored ItemId.'
        Write-Host 'PASS: finished backup reads back by parent job id as awaiting delivery.'

        # Journal and attempt state are untouched by progress.
        Check (@(Get-ChildItem -LiteralPath $attemptRoot -Filter '*.json' -File).Count -eq 2) 'Progress files must not appear next to attempt records.'
        $journalHits=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -like '*journal*' -and (Select-String -LiteralPath $_.FullName -SimpleMatch 'WizardBackupProgress' -Quiet)})
        Check ($journalHits.Count -eq 0) 'Progress must not be written to any journal file.'
        Write-Host 'PASS: progress stays out of the attempt records and the journal.'

        # Secret sentinel sweep (same needles as tests/Test-SecretSentinelSweep.ps1: UTF-8, UTF-16LE and Base64 at three alignments).
        $latin=[Text.Encoding]::GetEncoding(28591);$utf8=[Text.Encoding]::UTF8.GetBytes($sentinel);$utf16=[Text.Encoding]::Unicode.GetBytes($sentinel)
        $needles=New-Object 'System.Collections.Generic.List[object]'
        $needles.Add(@{Name='UTF-8';Needle=$latin.GetString($utf8);Base64=$false});$needles.Add(@{Name='UTF-16LE';Needle=$latin.GetString($utf16);Base64=$false})
        foreach($variant in @(@{Name='B64';Bytes=$utf8},@{Name='B64-16';Bytes=$utf16})){foreach($shift in 0,1,2){$buffer=New-Object byte[] ($shift+$variant.Bytes.Length);[Array]::Copy($variant.Bytes,0,$buffer,$shift,$variant.Bytes.Length);$text=[Convert]::ToBase64String($buffer).TrimEnd('=');$skip=@(0,2,3)[$shift];if((($shift+$variant.Bytes.Length) % 3) -ne 0){$text=$text.Substring(0,$text.Length-1)};$needles.Add(@{Name=($variant.Name+'@'+$shift);Needle=$text.Substring($skip);Base64=$true})}}
        $sweep={param([string]$Directory)
            $hits=@();foreach($file in @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force)){$rawText=$latin.GetString([IO.File]::ReadAllBytes($file.FullName));$compact=$rawText.Replace("`r",'').Replace("`n",'');foreach($needle in $needles){$view=if($needle.Base64){$compact}else{$rawText};if($view.IndexOf($needle.Needle,[StringComparison]::Ordinal) -ge 0){$hits+=@($file.Name+':'+$needle.Name)}}};,$hits}
        $progressDir=Split-Path -Parent (Get-WsmWizardBackupProgressPath $sourceRoot $catalog.PairId $okOp)
        $progressHits=& $sweep $progressDir
        Check (@($progressHits).Count -eq 0) ('The secret sentinel leaked into the progress files: '+(@($progressHits) -join ', '))
        Check ($final.CurrentFile -notmatch 'SENTINEL' -and (@($seen|Where-Object {([string]$_.CurrentFile+[string]$_.Workload) -match 'SENTINEL'}).Count -eq 0)) 'Redaction left the sentinel in an observed progress write.'
        $controlHits=& $sweep (Split-Path -Parent $inventoryPath)
        Check (@($controlHits|Where-Object {$_ -like 'inventory.json:*'}).Count -ge 1) 'Negative control failed: the sweep did not find the sentinel in the inventory that really contains it.'
        Write-Host 'PASS: secret sentinel sweep finds nothing in progress files (and finds it in the negative control).'

        # ---------------------------------------------------------------- N2: item fields over the real one-click backup (C only, then C + NonC)
        $assertItemSequence={
            param($Seen,$ExpectedOrder,$ChannelById,[long]$ExpectedFiles,[string]$Label)
            $capture=@($Seen|Where-Object {[int]$_.StageIndex -eq 1})
            $withItem=@($capture|Where-Object {$_.CurrentItemId})
            Check ($withItem.Count -ge $ExpectedOrder.Count) ($Label+': too few Capture writes carried a current item.')
            foreach($snapshot in $withItem){
                Check ($ChannelById.ContainsKey([string]$snapshot.CurrentItemId)) ($Label+': an unknown ItemId was published: '+$snapshot.CurrentItemId)
                Check ($snapshot.CurrentChannel -ceq $ChannelById[[string]$snapshot.CurrentItemId]) ($Label+': channel '+$snapshot.CurrentChannel+' is wrong for item '+$snapshot.CurrentItemId+' (expected '+$ChannelById[[string]$snapshot.CurrentItemId]+')')
                Check ($snapshot.CurrentItemType -ceq 'FileScope' -and $snapshot.CurrentItemTypeLabel -ceq (Get-WsmWizardItemTypeLabel 'FileScope' 'DataRoot')) ($Label+': item type code/label wrong.')
            }
            $firstSeen=@();foreach($snapshot in $withItem){if($firstSeen -cnotcontains [string]$snapshot.CurrentItemId){$firstSeen+=@([string]$snapshot.CurrentItemId)}}
            Check (($firstSeen -join ',') -ceq ($ExpectedOrder -join ',')) ($Label+': items did not advance in plan order: '+($firstSeen -join ',')+' vs '+($ExpectedOrder -join ','))
            foreach($group in @($withItem|Group-Object {[int]$_.ItemsDone})){Check (@($group.Group|ForEach-Object {$_.CurrentItemId}|Sort-Object -Unique).Count -eq 1) ($Label+': one ItemsDone step mapped to more than one current item.')}
            $channelsSeen=@($withItem|ForEach-Object {$_.CurrentChannel}|Sort-Object -Unique)
            Check (($channelsSeen -join ',') -ceq (@($ChannelById.Values|Sort-Object -Unique) -join ',')) ($Label+': channels observed were '+($channelsSeen -join ',')+'.')
            $filesSeq=@($Seen|ForEach-Object {[long]$_.FilesDone})
            for($i=1;$i -lt $filesSeq.Count;$i++){Check ($filesSeq[$i] -ge $filesSeq[$i-1]) ($Label+': FilesDone went backwards.')}
            $captureFiles=@($capture|ForEach-Object {[long]$_.FilesDone}|Sort-Object -Unique)
            Check (($captureFiles -join ',') -ceq ((0..([int]$ExpectedFiles-1)) -join ',')) ($Label+': FilesDone must advance one file at a time during Capture, saw '+($captureFiles -join ','))
            Check (@($capture|Where-Object {$null -ne $_.FilesTotal}).Count -eq 0) ($Label+': FilesTotal must stay null until the package is sealed.')
            $verify=@($Seen|Where-Object {[int]$_.StageIndex -eq 2})
            Check ($verify.Count -ge 1 -and @($verify|Where-Object {[long]$_.FilesDone -ne $ExpectedFiles -or [long]$_.FilesTotal -ne $ExpectedFiles -or $_.CurrentItemId}).Count -eq 0) ($Label+': the Verify record must carry the sealed file count as done and total and no current item.')
        }
        $c1Plan=@($planRefMain.Plan.Items|Where-Object {$_.Decision -ceq 'Include'}|ForEach-Object {[string]$_.ItemId})
        $c1Channels=@{};foreach($id in $c1Plan){$c1Channels[$id]='C'}
        & $assertItemSequence $seen $c1Plan $c1Channels $expectedFiles 'C-only run'
        $mainFinal=Read-WsmWizardBackupProgress $sourceRoot $catalog.PairId $okOp
        Check ($mainFinal.CurrentItemId -ceq '' -and $mainFinal.CurrentChannel -ceq 'Unknown' -and $mainFinal.FilesDone -eq $expectedFiles -and $mainFinal.FilesTotal -eq $expectedFiles) 'The finished record must show no current item and the sealed file count.'
        Write-Host 'PASS: real C-only backup publishes item id, type, channel C and a monotonic file sequence ending at the sealed count.'

        $sfx='-mixed';$fixtureChannels=@('C','NonC','C');. $buildFixture
        $mixedPlanRef=Get-WsmWizardCurrentApprovedPlan $sourceRoot $catalog.PairId (Read-WsmOutputProfile $sourceRoot) $null @()
        $mixedOrder=@($mixedPlanRef.Plan.Items|Where-Object {$_.Decision -ceq 'Include'}|ForEach-Object {[string]$_.ItemId})
        $mixedChannels=@{};for($n=0;$n -lt 3;$n++){$mixedChannels[[string]$items[$n].ItemId]=$fixtureChannels[$n]}
        $mixedProof=New-WsmSourceFreezeEvidenceFixture -Plan $mixedPlanRef.Plan -PlanHash $mixedPlanRef.SHA256 -Root $Root -Owner 'Fixture freeze owner'
        $mixedOp=[Guid]::NewGuid().ToString('D');$mixedToken=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $catalog.PairId -PlanHash $approved.SHA256 -OperationId $mixedOp
        $script:progressOriginalWriteJson=$originalWriteJson;$script:progressSeen.Clear()
        function script:Write-WsmWizardBackupProgressFile {param([string]$Path,[string]$Json);if($Path -like '*\wizard-backups\*\progress\*.json'){$script:progressSeen.Add(($Json|ConvertFrom-Json))};& $script:progressOriginalWriteJson $Path $Json}
        try{
            $mixedResult=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $catalog.PairId -OperationId $mixedOp -Owner 'Fixture freeze owner' -Evidence 'Synthetic quiescence evidence for the progress fixture.' -FreezeAuthorization -FreezeExternalEvidencePath $mixedProof.Path -FreezeExternalEvidenceHash $mixedProof.SHA256 -Jobs @() -CancellationToken $mixedToken -DeliveryMode Directory -VolumeBytes 0
            $seenMixed=@($script:progressSeen.ToArray())
        }finally{
            Set-Item -Path Function:\script:Write-WsmWizardBackupProgressFile -Value $originalWriteJson
            Remove-Variable progressOriginalWriteJson -Scope Script -ErrorAction SilentlyContinue
        }
        Check ($null -ne $mixedResult.CoreExport -and $mixedResult.CoreExport.Status -ceq 'Succeeded') 'The C + NonC fixture backup did not seal its package.'
        Check ($mixedOrder.Count -eq 3 -and @($mixedChannels.Values|Sort-Object -Unique).Count -eq 2) 'The mixed fixture must really contain a C and a NonC item.'
        & $assertItemSequence $seenMixed $mixedOrder $mixedChannels ([long]$mixedResult.CoreExport.Files) 'C + NonC run'
        Write-Host 'PASS: real C + NonC backup moves item id, type and channel (C then NonC then C) in plan order with a monotonic file sequence.'

        Write-Host ('PASS: B1/N2 backup progress producer/projection checks: '+$script:checks)
    } $root $evidenceFixturePath
}
finally {
    $rootFull=[IO.Path]::GetFullPath($root)
    if($rootFull.StartsWith(($driveLetter+':\wsmbp-'),[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($rootFull)){Remove-Item -LiteralPath $rootFull -Recurse -Force -ErrorAction SilentlyContinue}
    cmd.exe /c ('subst '+$driveLetter+': /d') | Out-Null
}
