#requires -Version 5.1
# A2 (R4b, R9, R10, R11): backup attempts and the results page.
#   R10  A damaged / old-tool / incomplete attempt file must not break StartBackup of the pair. The start side and the read side use ONE
#        "recognizable" decision; unreadable files are counted and reported by file name only, and are never the current attempt.
#   R9   After a delivered backup, a newer failed / cancelled / interrupted attempt is shown beside the delivered result. "Newer" is
#        decided by Get-WsmWizardCurrentBackupAttempt (R5), never by a second ordering.
#   R11  Capture failures carry a stable reason code (PathTooLong / Locked / Missing / AccessDenied) decided from the exception TYPE and
#        HResult, with a next step and a safe location (relative depth + leaf name), never the full path. Real file system scenarios.
#   R4b  An availability row with status ReviewRequired is "backup possible, result needs review": the start form stays usable and says why.
# Real caller (Invoke-WsmWizardStartBackup), real capture, seal, verify and delivery. Only host qualification observations and the
# independent-copy media class are substituted. ASCII only on purpose: user-facing Chinese text is asserted in the browser tests.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path test.'}
$substCommand='subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"';cmd.exe /c $substCommand
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the test.'}
$root=Join-Path ($driveLetter+':\') ('wsma2-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:Checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:Checks++}
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        $script:Fp=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:Fp;Name='a2-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:InventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:InventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:InventoryPath;SHA256=(Get-FileHash -LiteralPath $script:InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $script:FixtureMediaClass='Removable'
        $script:OrigMediaClass=(Get-Command Get-WsmIndependentCopyMediaClass -CommandType Function).ScriptBlock
        Set-Item -Path Function:\script:Get-WsmIndependentCopyMediaClass -Value {param($DestinationRoot)$script:FixtureMediaClass}

        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work'
        [void](Initialize-WsmOutputWorkspace $sourceRoot Source)
        $script:Fp=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=Sha $targetIdentityPath
        $script:Fp=('a'*64)
        $sourceEnrollment=Read-WsmOutputProfile $sourceRoot
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}

        # One approved FileScope plan over $DataDir. Every scenario gets its own plan (own pair) so attempts never resume each other.
        function New-A2Plan([string]$Label,[string]$DataDir){
            $item=New-WsmItem $source.HostId Storage DataRoot ('A2 scope '+$Label) ('a2-'+$Label) @{Path=$DataDir}
            $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $Root ('inventory-'+$Label+'.json');Write-WsmJson $inventoryPath $inventory;$script:InventoryPath=$inventoryPath
            $managerRoot=Join-Path $Root ('manager-'+$Label);Initialize-WsmWorkspace $managerRoot|Out-Null
            $catalog=Import-WsmInventory $managerRoot $inventoryPath (Sha $inventoryPath) ('target-'+$Label)
            $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$DataDir;TargetPath=(Join-Path $Root ('restored-'+$Label));TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='A2 fixture';BusinessChecks=@('Read back each source file')}
            $specPath=Join-Path $Root ('spec-'+$Label+'.json');Write-WsmJson $specPath $spec
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $specPath (Sha $specPath) $revision|Out-Null
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            Set-WsmDecision $managerRoot $catalog.PairId @([string]$item.ItemId) Include 'Explicit A2 selection' $revision|Out-Null
            $revision=[int](Get-WsmCatalog $managerRoot $catalog.PairId).DecisionRevision
            $planPath=Join-Path $Root ('approved-plan-'+$Label+'.json')
            $approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $revision 'ISOLATED-PILOT'
            $script:Fp=('a'*64)
            $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
            if($import.Status -cne 'ImportedVerified'){throw ('Source did not import the approved '+$Label+' plan.')}
            [pscustomobject]@{PairId=[string]$catalog.PairId;PlanHash=[string]$approved.SHA256;PlanPath=$planPath;ItemId=[string]$item.ItemId;DataDir=$DataDir;InventoryPath=$inventoryPath}
        }
        function Start-A2Backup($PlanInfo,[string]$Op){
            $script:InventoryPath=$PlanInfo.InventoryPath
            $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $PlanInfo.PairId -PlanHash $PlanInfo.PlanHash -OperationId $Op
            Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $PlanInfo.PairId -OperationId $Op -Jobs @() -CancellationToken $token -DeliveryMode Directory -VolumeBytes 0
        }
        function Get-A2Attempt($PlanInfo,[string]$Op){(Get-WsmWizardBackupAttemptForOperation $sourceRoot $PlanInfo.PairId (Read-WsmOutputProfile $sourceRoot) $Op)}
        function Get-A2PairRoot([string]$PairId){Join-Path (Join-Path (Join-Path $sourceRoot 'workspace-control') 'wizard-backups') $PairId}
        function Clone-Json($Value){($Value|ConvertTo-Json -Depth 40 -Compress)|ConvertFrom-Json}
        function New-DataDir([string]$Name,[int]$Files=2){
            $dir=Join-Path $Root $Name;[void][IO.Directory]::CreateDirectory($dir)
            for($i=1;$i -le $Files;$i++){[IO.File]::WriteAllText((Join-Path $dir ('file'+$i+'.txt')),('A2 data file '+$i))}
            $dir
        }
        # A synthetic sibling attempt cloned from a real one: new identity, later StartedUtc, the requested stage.
        function Add-A2Sibling($Template,[string]$PairId,[string]$Stage,[string]$StartedUtc,$Error=$null){
            $clone=Clone-Json $Template
            $clone.AttemptId=[Guid]::NewGuid().ToString('D');$operationId=[Guid]::NewGuid().ToString('D')
            $clone.StartedByOperationId=$operationId;$clone.OperationIds=@($operationId);$clone.LastOperationId=$operationId
            $clone.StartedUtc=$StartedUtc;$clone.UpdatedUtc=$StartedUtc;$clone.Stage=$Stage
            $clone.PSObject.Properties.Remove('ResumeStage');$clone | Add-Member NoteProperty ResumeStage '' -Force
            $clone | Add-Member NoteProperty Error $Error -Force
            $path=Join-Path (Get-A2PairRoot $PairId) ($clone.AttemptId+'.json');Write-WsmJson $path $clone
            [pscustomobject]@{Path=$path;Attempt=$clone;AttemptId=[string]$clone.AttemptId}
        }
        function New-A2FailedItemError([string]$ItemId){
            [pscustomobject]@{Code='core_export_failed';Message='fixture';FailedItem=[pscustomobject]@{ItemId=$ItemId;Name='A2 scope sibling';Kind='DataRoot';Channel='C';ErrorClass='IOError';ErrorKind='System.IO.IOException'}}
        }
        function Remove-LongTree([string]$Path){
            if([IO.Directory]::Exists('\\?\'+$Path)){cmd.exe /c ('rd /s /q "\\?\'+$Path+'"')|Out-Null}
        }
        $later={param([int]$Minutes)[DateTimeOffset]::UtcNow.AddMinutes($Minutes).ToString('o')}

        try {
            # ======================================================================================================
            # Base: one real delivered backup (op1) and a second real one (op2) on a normal scope.
            # ======================================================================================================
            $dataBase=New-DataDir 'data-base'
            $basePlan=New-A2Plan 'base' $dataBase
            $pairB=$basePlan.PairId;$profile=Read-WsmOutputProfile $sourceRoot
            $op1=[Guid]::NewGuid().ToString('D');$result1=Start-A2Backup $basePlan $op1
            Check ($result1.Status -ceq 'Delivered') ('precondition: the real first backup must be Delivered, got '+$result1.Status)
            $attempt1=(Get-A2Attempt $basePlan $op1).Attempt
            $rootB=Get-A2PairRoot $pairB

            # ======================================================================================================
            # R10. Unreadable attempt files: bad JSON, old ToolVersion, missing field. File names only; never current; never block.
            # ======================================================================================================
            $badJson=Join-Path $rootB 'garbage-record.json';[IO.File]::WriteAllText($badJson,'{ this is not json')
            $oldTool=Clone-Json $attempt1;$oldTool.AttemptId=[Guid]::NewGuid().ToString('D');$oldTool.ToolVersion='0.0.1';$oldTool.StartedUtc=(& $later 600);$oldTool.UpdatedUtc=(& $later 600);$oldTool.Stage='Delivered'
            $oldToolPath=Join-Path $rootB ('old-tool-'+$oldTool.AttemptId+'.json');Write-WsmJson $oldToolPath $oldTool
            $missing=Clone-Json $attempt1;$missing.AttemptId=[Guid]::NewGuid().ToString('D');$missing.PSObject.Properties.Remove('PackageTest')
            $missingPath=Join-Path $rootB ('missing-field-'+$missing.AttemptId+'.json');Write-WsmJson $missingPath $missing
            $expectedNames=@([IO.Path]::GetFileName($badJson),[IO.Path]::GetFileName($oldToolPath),[IO.Path]::GetFileName($missingPath))

            # read side first: counted, named, never current
            $viewBad=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
            Check ($viewBad.available -and [string]$viewBad.attemptId -ceq [string]$attempt1.AttemptId) 'R10-1 an unreadable record (even one claiming to be a newer Delivered attempt) must never become the current attempt'
            Check ($null -ne $viewBad.PSObject.Properties['unreadableAttempts'] -and [int]$viewBad.unreadableAttempts.count -eq 3) ('R10-1 the results view must report 3 unreadable records, got '+$(if($viewBad.PSObject.Properties['unreadableAttempts']){$viewBad.unreadableAttempts.count}else{'no field'}))
            $reported=@($viewBad.unreadableAttempts.files|ForEach-Object {[string]$_})
            Check (@($expectedNames|Where-Object {$reported -ccontains $_}).Count -eq 3 -and $reported.Count -eq 3) ('R10-1 the unreadable list must be exactly the three file names, got: '+($reported -join ', '))
            Check (@($reported|Where-Object {$_ -match '[\\/:]'}).Count -eq 0) 'R10-1 only file names, never a path'
            Check ((ConvertTo-Json $viewBad.unreadableAttempts -Depth 6 -Compress) -notlike ('*'+$Root.Replace('\','\\')+'*')) 'R10-1 the report must not contain the workspace path'
            $files1=Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pairB -ItemId $basePlan.ItemId
            Check ([string]$files1.AttemptId -ceq [string]$attempt1.AttemptId) 'R10-1 the file drill-down must also ignore unreadable records'
            Write-Host 'PASS: R10-1 the results view counts three unreadable records by file name and never picks them as current.'

            # start side: the same records must not stop a new backup
            $op2=[Guid]::NewGuid().ToString('D')
            $result2=$null;$startError=''
            try{$result2=Start-A2Backup $basePlan $op2}catch{$startError=$_.Exception.Message}
            Check ($null -ne $result2 -and -not $startError) ('R10-2 StartBackup must not fail because of unreadable records: '+$startError)
            Check ($result2.Status -ceq 'Delivered') ('R10-2 the new backup must complete, got '+$result2.Status)
            Check ($null -ne $result2.PSObject.Properties['UnreadableAttemptCount'] -and [int]$result2.UnreadableAttemptCount -eq 3) 'R10-2 the start result must report the 3 unreadable records'
            $startReported=@($result2.UnreadableAttemptFiles|ForEach-Object {[string]$_})
            Check (@($expectedNames|Where-Object {$startReported -ccontains $_}).Count -eq 3 -and @($startReported|Where-Object {$_ -match '[\\/:]'}).Count -eq 0) 'R10-2 the start result lists the same three names, names only'
            $attempt2=(Get-A2Attempt $basePlan $op2).Attempt
            $viewAfter=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
            Check ($viewAfter.available -and [string]$viewAfter.attemptId -ceq [string]$attempt2.AttemptId -and [int]$viewAfter.unreadableAttempts.count -eq 3) 'R10-2 after the new backup the view shows it as current and still reports 3 unreadable'
            # one shared decision: the resume entry and the readers agree, and a readable resumable sibling is still found
            Check ($null -eq (Get-WsmWizardBackupAttempt $sourceRoot $pairB (Read-WsmOutputProfile $sourceRoot) $basePlan.PlanHash)) 'R10-3 the resume entry must not trip over unreadable records either'
            $resumable=Add-A2Sibling $attempt2 $pairB 'CoreExported' (& $later 700)
            $entry=Get-WsmWizardBackupAttempt $sourceRoot $pairB (Read-WsmOutputProfile $sourceRoot) $basePlan.PlanHash
            Check ($entry -and [string]$entry.Attempt.AttemptId -ceq $resumable.AttemptId) 'R10-3 a readable unfinished record is still found next to unreadable ones'
            [IO.File]::Delete($resumable.Path)
            Write-Host 'PASS: R10-2/3 StartBackup succeeds next to unreadable records, reports them by name, and the resume entry shares the decision.'

            # old ToolVersion alone and bad JSON alone behave the same way
            foreach($single in @($badJson,$oldToolPath,$missingPath)){[IO.File]::Delete($single)}
            $viewClean=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
            Check ([int]$viewClean.unreadableAttempts.count -eq 0 -and @($viewClean.unreadableAttempts.files).Count -eq 0) 'R10-4 no unreadable records: count 0, empty list'
            [IO.File]::WriteAllText($oldToolPath,((Clone-Json $oldTool)|ConvertTo-Json -Depth 40))
            $viewOld=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
            Check ([int]$viewOld.unreadableAttempts.count -eq 1 -and [string]$viewOld.attemptId -ceq [string]$attempt2.AttemptId) 'R10-4 a single old-ToolVersion record is counted once and ignored'
            [IO.File]::Delete($oldToolPath)
            Write-Host 'PASS: R10-4 old ToolVersion alone, and the clean case.'
            # R10-5 (main agent): skipping unreadable records must not extend to reparse points. A reparse record in the attempts folder stays a
            # hard refusal (fail closed), exactly as before R10; it is never counted as merely unreadable. The reparse observation is the only
            # seam (a real file symlink needs a privilege this fixture does not assume); the scan itself is the real function.
            $probePath=Join-Path $rootB 'reparse-probe.json';Write-WsmJson $probePath (Clone-Json $attempt1)
            $originalNoReparse=${function:script:Assert-WsmNoReparse}
            ${function:script:Assert-WsmNoReparse}={param([string]$Path) if([IO.Path]::GetFileName($Path) -ceq 'reparse-probe.json'){throw 'Reparse point refused: fixture probe.'}; & $originalNoReparse $Path}
            try{
                $scanError=$null;try{[void](Get-WsmWizardBackupAttemptScan $rootB $sourceRoot $pairB $profile)}catch{$scanError=[string]$_.Exception.Message}
                Check ($scanError -like '*Reparse point refused*') ('R10-5 a reparse record must still refuse the scan, not be skipped as unreadable; got '+$(if($scanError){$scanError}else{'no error'}))
            } finally { ${function:script:Assert-WsmNoReparse}=$originalNoReparse; [IO.File]::Delete($probePath) }
            Write-Host 'PASS: R10-5 a reparse record in the attempts folder is still refused, never skipped.'

            # ======================================================================================================
            # R9. A newer failed / cancelled / interrupted attempt next to a delivered result.
            # ======================================================================================================
            $current=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
            Check ($current.available -and $null -eq $current.newerAttempt) 'R9-0 only Delivered attempts: the newer-attempt field must be empty'
            foreach($case in @(@('Failed','Failed'),@('Cancelled','Cancelled'),@('CoreExported','Interrupted'),@('PackageVerified','Interrupted'))){
                $errorRecord=$null
                if($case[0] -ceq 'Failed'){$errorRecord=New-A2FailedItemError $basePlan.ItemId}
                elseif($case[0] -ceq 'Cancelled'){$errorRecord=[pscustomobject]@{Code='cancelled';Message='fixture'}}
                $sibling=Add-A2Sibling $attempt2 $pairB $case[0] (& $later 800) $errorRecord
                try{
                    $view=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
                    Check ($view.available -and [string]$view.attemptId -ceq [string]$attempt2.AttemptId) ('R9-1 the delivered result must stay visible next to a '+$case[0]+' attempt')
                    Check ($null -ne $view.newerAttempt) ('R9-1 a newer '+$case[0]+' attempt must be shown beside the delivered result')
                    Check ([string]$view.newerAttempt.status -ceq $case[1]) ('R9-1 status for '+$case[0]+' must be '+$case[1]+', got '+[string]$view.newerAttempt.status)
                    Check ([string]$view.newerAttempt.attemptId -ceq $sibling.AttemptId) 'R9-1 the newer attempt must be the one that was written last'
                    Check ([bool][string]$view.newerAttempt.attemptedUtc) 'R9-1 the newer attempt carries its time'
                    Check ([bool][string]$view.newerAttempt.nextStep) ('R9-1 the newer '+$case[0]+' attempt carries a next step')
                    if($case[0] -ceq 'Failed'){Check ($view.newerAttempt.failedItem -and [string]$view.newerAttempt.failedItem.ItemId -ceq $basePlan.ItemId) 'R9-1 a failed attempt carries its FailedItem summary'}
                }finally{[IO.File]::Delete($sibling.Path)}
            }
            Write-Host 'PASS: R9-1 delivered then failed / cancelled / interrupted: both are shown.'
            # "newer" is the shared current-attempt helper: an older failure (even with a fresh UpdatedUtc) is not shown
            $older=Add-A2Sibling $attempt2 $pairB 'Failed' '2020-01-01T00:00:00.0000000Z' (New-A2FailedItemError $basePlan.ItemId)
            try{
                $stored=Read-WsmJson $older.Path;$stored.UpdatedUtc=(& $later 900);Write-WsmJson $older.Path $stored
                $viewOlder=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
                Check ($viewOlder.available -and $null -eq $viewOlder.newerAttempt) 'R9-2 a failure that started BEFORE the delivered attempt must not be shown, whatever its UpdatedUtc says'
            }finally{[IO.File]::Delete($older.Path)}
            # a later delivered attempt supersedes the failure: nothing to warn about (the later one is a real backup)
            $afterSecond=[DateTimeOffset]::Parse([string]$attempt2.StartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).AddMilliseconds(1).ToString('o')
            $failedThenOk=Add-A2Sibling $attempt2 $pairB 'Failed' $afterSecond (New-A2FailedItemError $basePlan.ItemId)
            try{
                $viewBefore=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
                Check ($null -ne $viewBefore.newerAttempt -and [string]$viewBefore.newerAttempt.attemptId -ceq $failedThenOk.AttemptId) 'R9-3 precondition: the failure is newer than op2 before op3 exists'
                Start-Sleep -Milliseconds 1200
                $op3=[Guid]::NewGuid().ToString('D');$result3=Start-A2Backup $basePlan $op3
                Check ($result3.Status -ceq 'Delivered') 'R9-3 precondition: the third backup is delivered'
                $attempt3=(Get-A2Attempt $basePlan $op3).Attempt
                $viewLater=Get-WsmWizardBackupItemResultsView $sourceRoot $pairB
                Check ($viewLater.available -and [string]$viewLater.attemptId -ceq [string]$attempt3.AttemptId -and $null -eq $viewLater.newerAttempt) 'R9-3 a delivered attempt newer than the failure leaves nothing to warn about'
            }finally{[IO.File]::Delete($failedThenOk.Path)}
            Write-Host 'PASS: R9-2/3 the newer-attempt decision is the shared current-attempt helper.'

            # ======================================================================================================
            # R11. Stable reason codes on real file system situations.
            # ======================================================================================================
            function Get-FailedView($Plan){
                $v=Get-WsmWizardBackupItemResultsView $sourceRoot $Plan.PairId
                Check (-not $v.available -and $null -ne $v.PSObject.Properties['failedAttempt'] -and $null -ne $v.failedAttempt -and $null -ne $v.failedAttempt.failedItem) 'R11 precondition: nothing delivered and the failed attempt names its item'
                $v.failedAttempt
            }
            function Assert-NoFullPath($Json,[string[]]$Forbidden,[string]$Label){
                foreach($text in $Forbidden){
                    if(-not $text){continue}
                    Check ($Json.IndexOf($text,[StringComparison]::OrdinalIgnoreCase) -lt 0) ($Label+': the output must not contain the full path '+$text.Substring(0,[Math]::Min(40,$text.Length))+'...')
                    Check ($Json.IndexOf($text.Replace('\','\\'),[StringComparison]::OrdinalIgnoreCase) -lt 0) ($Label+': the JSON-escaped full path must not appear either')
                }
            }

            # --- PathTooLong: a directory chain created with the \\?\ prefix, deeper than 239 characters ---
            $dataLong=New-DataDir 'data-long'
            $segment='L'*60;$longRoot=$dataLong
            for($i=1;$i -le 4;$i++){$longRoot=Join-Path $longRoot $segment}
            [void][IO.Directory]::CreateDirectory('\\?\'+$longRoot)
            [IO.File]::WriteAllText('\\?\'+(Join-Path $longRoot 'deep.txt'),'deep file')
            Check ($longRoot.Length -gt 239) 'R11 precondition: the long chain must exceed the 239 character limit'
            try{
                $longPlan=New-A2Plan 'long' $dataLong
                $opLong=[Guid]::NewGuid().ToString('D');$errorLong=''
                try{[void](Start-A2Backup $longPlan $opLong)}catch{$errorLong=$_.Exception.Message}
                $failedLong=Get-FailedView $longPlan
                $itemLong=$failedLong.failedItem
                Check ([string]$itemLong.ReasonCode -ceq 'PathTooLong') ('R11-1 a path longer than 239 characters must give PathTooLong, got '+[string]$itemLong.ReasonCode+' (class '+[string]$itemLong.ErrorClass+' kind '+[string]$itemLong.ErrorKind+')')
                Check ([bool][string]$itemLong.ReasonNextStep) 'R11-1 PathTooLong carries a next step'
                Check ([bool]($itemLong.Location -and [int]$itemLong.Location.depth -ge 1 -and [string]$itemLong.Location.name)) ('R11-1 the location is a relative depth plus a leaf name, got '+(ConvertTo-Json (Get-A2Attempt $longPlan $opLong).Attempt.Error -Depth 6 -Compress))
                $jsonLong=ConvertTo-Json $failedLong -Depth 12 -Compress
                Assert-NoFullPath $jsonLong @($longRoot,(Join-Path $dataLong $segment),[string]$errorLong) 'R11-1'
                $recordLong=(Get-A2Attempt $longPlan $opLong).Attempt
                Check ((Get-Content -LiteralPath (Get-A2Attempt $longPlan $opLong).Path -Raw).IndexOf($longRoot,[StringComparison]::OrdinalIgnoreCase) -lt 0) 'R11-1 the durable attempt record must not hold the failing full path'
            }finally{Remove-LongTree $dataLong}
            Write-Host 'PASS: R11-1 PathTooLong on a real >239 character tree; location is depth and leaf only.'

            # --- Locked: a handle opened with FileShare.None ---
            $dataLock=New-DataDir 'data-lock'
            $lockedFile=Join-Path $dataLock 'locked-file.txt';[IO.File]::WriteAllText($lockedFile,'held open')
            $handle=New-Object IO.FileStream($lockedFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try{
                $lockPlan=New-A2Plan 'lock' $dataLock
                $opLock=[Guid]::NewGuid().ToString('D');$errorLock=''
                try{[void](Start-A2Backup $lockPlan $opLock)}catch{$errorLock=$_.Exception.Message}
                $failedLock=Get-FailedView $lockPlan;$itemLock=$failedLock.failedItem
                Check ([string]$itemLock.ReasonCode -ceq 'Locked') ('R11-2 a file held with FileShare None must give Locked, got '+[string]$itemLock.ReasonCode+' (class '+[string]$itemLock.ErrorClass+' kind '+[string]$itemLock.ErrorKind+')')
                Check ([bool][string]$itemLock.ReasonNextStep) 'R11-2 Locked carries a next step'
                Check ([int]$itemLock.Location.depth -eq 1 -and [string]$itemLock.Location.name -ceq 'locked-file.txt') ('R11-2 the location is depth 1 and the leaf name, got '+$itemLock.Location.depth+' / '+$itemLock.Location.name)
                Assert-NoFullPath (ConvertTo-Json $failedLock -Depth 12 -Compress) @($lockedFile,[string]$errorLock) 'R11-2'
            }finally{$handle.Dispose()}
            Write-Host 'PASS: R11-2 Locked on a real FileShare None handle.'

            # --- Missing: the file disappears between listing and reading (hook on the payload writer, real FileNotFoundException) ---
            $dataGone=New-DataDir 'data-gone' 3
            $goneFile=Join-Path $dataGone 'file2.txt'
            $script:OrigPayloadWriter=(Get-Command Write-WsmPayloadFile -CommandType Function).ScriptBlock
            $script:GoneTarget=$goneFile;$script:GoneDone=$false
            Set-Item -Path Function:\script:Write-WsmPayloadFile -Value {
                if(-not $script:GoneDone -and [string]$args[0] -ieq $script:GoneTarget){$script:GoneDone=$true;[IO.File]::Delete($script:GoneTarget)}
                & $script:OrigPayloadWriter @args
            }
            try{
                $gonePlan=New-A2Plan 'gone' $dataGone
                $opGone=[Guid]::NewGuid().ToString('D');$errorGone=''
                try{[void](Start-A2Backup $gonePlan $opGone)}catch{$errorGone=$_.Exception.Message}
                Check ($script:GoneDone) 'R11-3 precondition: the hook must have removed the file in flight'
                $failedGone=Get-FailedView $gonePlan;$itemGone=$failedGone.failedItem
                Check ([string]$itemGone.ReasonCode -ceq 'Missing') ('R11-3 a file deleted mid-capture must give Missing, got '+[string]$itemGone.ReasonCode+' (class '+[string]$itemGone.ErrorClass+' kind '+[string]$itemGone.ErrorKind+')')
                Check ([bool][string]$itemGone.ReasonNextStep) 'R11-3 Missing carries a next step'
                Check ([int]$itemGone.Location.depth -eq 1 -and [string]$itemGone.Location.name -ceq 'file2.txt') ('R11-3 the location is depth 1 and the leaf name, got '+$itemGone.Location.depth+' / '+$itemGone.Location.name)
                Assert-NoFullPath (ConvertTo-Json $failedGone -Depth 12 -Compress) @($goneFile,[string]$errorGone) 'R11-3'
            }finally{Set-Item -Path Function:\script:Write-WsmPayloadFile -Value $script:OrigPayloadWriter}
            Write-Host 'PASS: R11-3 Missing when a file is removed in flight.'

            # --- AccessDenied: a deny ACE on one file (always removed again) ---
            $dataDeny=New-DataDir 'data-deny'
            $deniedFile=Join-Path $dataDeny 'denied-file.txt';[IO.File]::WriteAllText($deniedFile,'no access')
            $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
            $denyRule=New-Object Security.AccessControl.FileSystemAccessRule($identity,[Security.AccessControl.FileSystemRights]::ReadData,[Security.AccessControl.AccessControlType]::Deny)
            $acl=Get-Acl -LiteralPath $deniedFile;$acl.AddAccessRule($denyRule);Set-Acl -LiteralPath $deniedFile -AclObject $acl
            try{
                $denyPlan=New-A2Plan 'deny' $dataDeny
                $opDeny=[Guid]::NewGuid().ToString('D');$errorDeny=''
                try{[void](Start-A2Backup $denyPlan $opDeny)}catch{$errorDeny=$_.Exception.Message}
                $failedDeny=Get-FailedView $denyPlan;$itemDeny=$failedDeny.failedItem
                Check ([string]$itemDeny.ReasonCode -ceq 'AccessDenied') ('R11-4 a deny ACE must give AccessDenied, got '+[string]$itemDeny.ReasonCode+' (class '+[string]$itemDeny.ErrorClass+' kind '+[string]$itemDeny.ErrorKind+')')
                Check ([bool][string]$itemDeny.ReasonNextStep) 'R11-4 AccessDenied carries a next step'
                Check ([int]$itemDeny.Location.depth -eq 1 -and [string]$itemDeny.Location.name -ceq 'denied-file.txt') ('R11-4 the location is depth 1 and the leaf name, got '+$itemDeny.Location.depth+' / '+$itemDeny.Location.name)
                Assert-NoFullPath (ConvertTo-Json $failedDeny -Depth 12 -Compress) @($deniedFile,[string]$errorDeny) 'R11-4'
            }finally{
                $acl=Get-Acl -LiteralPath $deniedFile;[void]$acl.RemoveAccessRule($denyRule);Set-Acl -LiteralPath $deniedFile -AclObject $acl
            }
            Write-Host 'PASS: R11-4 AccessDenied on a real deny ACE (rule removed again).'

            # --- every code has distinct next-step text; an unrecognized failure keeps the old Failed class ---
            $steps=@($itemLong.ReasonNextStep,$itemLock.ReasonNextStep,$itemGone.ReasonNextStep,$itemDeny.ReasonNextStep)
            Check (@($steps|Select-Object -Unique).Count -eq 4) 'R11-5 every reason code has its own next step'
            $unknown=New-Object InvalidOperationException 'fixture'
            $unknown.Data['WsmCaptureFailedItemId']=$basePlan.ItemId
            $planObject=(Read-WsmMigrationPlan $basePlan.PlanPath $basePlan.PlanHash)
            $classified=New-WsmWizardBackupCaptureFailure $planObject $unknown
            Check ([string]$classified.ReasonCode -ceq 'Failed' -and [string]$classified.ErrorClass -ceq 'Failed') 'R11-5 an unrecognized failure keeps the existing Failed class and the Failed reason code'
            $wrapped=New-Object Management.Automation.MethodInvocationException 'outer',(New-Object IO.PathTooLongException 'inner')
            $wrapped.Data['WsmCaptureFailedItemId']=$basePlan.ItemId
            Check ([string](New-WsmWizardBackupCaptureFailure $planObject $wrapped).ReasonCode -ceq 'PathTooLong') 'R11-5 the type is read from the innermost exception, not from the wrapper'
            # HResult decides Locked (0x20 and 0x21), not the message
            foreach($pair in @(@(0x80070020,'Locked'),@(0x80070021,'Locked'),@(0x80070005,'Failed'))){
                $io=New-Object IO.IOException 'this text says nothing useful',([int]($pair[0] -bor 0))
                $io.Data['WsmCaptureFailedItemId']=$basePlan.ItemId
                Check ([string](New-WsmWizardBackupCaptureFailure $planObject $io).ReasonCode -ceq $pair[1]) ('R11-5 an IOException with HResult 0x'+('{0:X}' -f $pair[0])+' must map to '+$pair[1])
            }
            $misleading=New-Object IO.IOException 'The process cannot access the file because it is being used by another process'
            $misleading.Data['WsmCaptureFailedItemId']=$basePlan.ItemId
            Check ([string](New-WsmWizardBackupCaptureFailure $planObject $misleading).ReasonCode -cne 'Locked') 'R11-5 the message text must never decide the code'
            Write-Host 'PASS: R11-5 distinct next steps, Failed fallback, innermost type and HResult decide.'

            # ======================================================================================================
            # R4b. ReviewRequired is "backup possible, result needs review": the form is usable and says why.
            # ======================================================================================================
            $reviewData=New-DataDir 'data-review';$manualDir=Join-Path $Root 'manual-product'
            $reviewItem=New-WsmItem $source.HostId Storage DataRoot 'A2 review scope' 'a2-review' @{Path=$reviewData}
            $manualItem=New-WsmItem $source.HostId Storage DataRoot 'A2 manual product' 'a2-manual' @{Path=$manualDir}
            $inventoryReview=New-WsmInventory $source 1 @($reviewItem,$manualItem);$inventoryReviewPath=Join-Path $Root 'inventory-review.json';Write-WsmJson $inventoryReviewPath $inventoryReview;$script:InventoryPath=$inventoryReviewPath
            $managerReview=Join-Path $Root 'manager-review';Initialize-WsmWorkspace $managerReview|Out-Null
            $catalogReview=Import-WsmInventory $managerReview $inventoryReviewPath (Sha $inventoryReviewPath) 'target-review'
            $specReview=[pscustomobject]@{Adapter='FileScope';SourcePath=$reviewData;TargetPath=(Join-Path $Root 'restored-review');TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='A2 fixture';BusinessChecks=@('Read back each source file')}
            $specManual=[pscustomobject]@{Adapter='ManualWorkflow';Product='A2 manual product';Procedure='Install and configure by hand';Artifacts=@();Owner='Fixture owner';Evidence='A2 fixture';BusinessChecks=@('Open the product and confirm the licence')}
            foreach($pair in @(@($reviewItem,$specReview),@($manualItem,$specManual))){
                $specPath=Join-Path $Root ('spec-review-'+[Guid]::NewGuid().ToString('N').Substring(0,6)+'.json');Write-WsmJson $specPath $pair[1]
                $revision=[int](Get-WsmCatalog $managerReview $catalogReview.PairId).DecisionRevision
                Set-WsmMigrationSpec $managerReview $catalogReview.PairId $pair[0].ItemId $specPath (Sha $specPath) $revision|Out-Null
            }
            $revision=[int](Get-WsmCatalog $managerReview $catalogReview.PairId).DecisionRevision
            Set-WsmDecision $managerReview $catalogReview.PairId @([string]$reviewItem.ItemId,[string]$manualItem.ItemId) Include 'Explicit A2 selection' $revision|Out-Null
            $revision=[int](Get-WsmCatalog $managerReview $catalogReview.PairId).DecisionRevision
            $reviewPlanPath=Join-Path $Root 'approved-plan-review.json'
            $approvedReview=Approve-WsmMigrationPlan $managerReview $catalogReview.PairId $targetIdentityPath $targetIdentityHash $reviewPlanPath $revision 'ISOLATED-PILOT'
            $script:Fp=('a'*64)
            Check ((Import-WsmWizardApprovedPlan $sourceRoot Source $reviewPlanPath $approvedReview.SHA256).Status -ceq 'ImportedVerified') 'R4b precondition: the review plan imports'
            $reviewPlan=[pscustomobject]@{PairId=[string]$catalogReview.PairId;PlanHash=[string]$approvedReview.SHA256;InventoryPath=$inventoryReviewPath}
            $opReview=[Guid]::NewGuid().ToString('D');$resultReview=Start-A2Backup $reviewPlan $opReview
            Check ($resultReview.Status -ceq 'ReviewRequired') ('R4b precondition: the backup must end ReviewRequired, got '+$resultReview.Status)
            $attemptReview=(Get-A2Attempt $reviewPlan $opReview).Attempt
            $jobReview=[pscustomobject]@{jobId=$opReview;action='StartBackup';status='ReviewRequired';role='Source';workspace=$sourceRoot;pairId=$reviewPlan.PairId;CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{AttemptId=[string]$attemptReview.AttemptId})}
            $runtimeReview=Get-WsmWizardRuntimeProjection -Workspace $sourceRoot -PairId $reviewPlan.PairId -Role Source -Jobs @($jobReview)
            $sourceRuntime=$runtimeReview.runtime
            Check ([string]$sourceRuntime.backupResult.status -ceq 'ReviewRequired') 'R4b precondition: the availability row is ReviewRequired'
            $startAction=@($runtimeReview.actions|Where-Object {$_.id -ceq 'StartBackup'})[0]
            Check ($startAction.available -eq $true) 'R4b-1 StartBackup stays available when the last result needs review'
            Check ($null -ne $sourceRuntime.PSObject.Properties['startForm'] -and $sourceRuntime.startForm.usable -eq $true) 'R4b-1 the core must state that the start form is usable (single rule; the front end only reads it)'
            Check ($null -ne $sourceRuntime.PSObject.Properties['backupReview'] -and $sourceRuntime.backupReview.required -eq $true -and [int]$sourceRuntime.backupReview.itemCount -eq 1 -and [string]$sourceRuntime.backupReview.reason) 'R4b-1 the review reason (1 manual item) is attached beside the form'
            Check ($sourceRuntime.backupReview.delivered -eq $true) 'R4b-1 the reason says whether the delivery itself was verified'
            Write-Host 'PASS: R4b-1 ReviewRequired: the form is usable and carries the review reason.'
            # counter examples: a real unmet precondition still blocks, and a clean result carries no review note
            $cleanRuntime=Get-WsmWizardRuntimeProjection -Workspace $sourceRoot -PairId $pairB -Role Source -Jobs @()
            Check ($cleanRuntime.runtime.startForm.usable -eq $true -and $cleanRuntime.runtime.backupReview.required -eq $false) 'R4b-2 a plan without a review result: usable, no review note'
            $unknownPair=[Guid]::NewGuid().ToString('D')
            $blockedRuntime=Get-WsmWizardRuntimeProjection -Workspace $sourceRoot -PairId $unknownPair -Role Source -Jobs @()
            Check ($null -ne $blockedRuntime.runtime.PSObject.Properties['startForm'] -and $blockedRuntime.runtime.startForm.usable -eq $false -and [string]$blockedRuntime.runtime.startForm.reason) 'R4b-2 without an approved plan the form is blocked and says why'
            Write-Host 'PASS: R4b-2 a real unmet precondition still blocks; a clean result has no review note.'
        } finally {
            Set-Item -Path Function:\script:Get-WsmIndependentCopyMediaClass -Value $script:OrigMediaClass
        }
        Write-Host ('PASS: A2 backup attempts, unreadable records and reason codes ('+$script:Checks+' checks).')
    } $root
} finally {
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsma2-*'){throw 'Unsafe cleanup path.'}
    if([IO.Directory]::Exists('\\?\'+$full)){
        # the long chain is removed by the test itself; this is only a safety net that also understands \\?\ paths
        cmd.exe /c ('rd /s /q "\\?\'+$full+'"')|Out-Null
    }
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
