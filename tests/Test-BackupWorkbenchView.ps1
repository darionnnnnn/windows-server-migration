#requires -Version 5.1
# B2: the workbench "backup results" projection (independent-copy receipt re-check) and the read-only file drill-down
# (action BackupItemFiles). Everything runs on a real sealed backup: only host qualification is substituted.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path payload test.'}
cmd.exe /c ('subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"')
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the workbench view test.'}
$root=Join-Path ($driveLetter+':\') ('wsmwv-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $check={param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
        $script:backupFixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:backupFixtureFingerprint;Name='workbench-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:backupFixtureInventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:backupFixtureInventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:backupFixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:backupFixtureInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager-work'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:backupFixtureFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:backupFixtureFingerprint=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        # 130 files in three folders plus one empty folder: more than one drill-down page and a directory member.
        $sourceData=Join-Path $Root 'source-data';[void][IO.Directory]::CreateDirectory($sourceData)
        foreach($sub in @('sub1','sub2','emptydir')){[void][IO.Directory]::CreateDirectory((Join-Path $sourceData $sub))}
        [IO.File]::WriteAllText((Join-Path $sourceData 'settings.ini'),'actual source bytes')
        for($n=1;$n -le 129;$n++){$folder=$(if($n -le 60){'sub1'}else{'sub2'});[IO.File]::WriteAllText((Join-Path (Join-Path $sourceData $folder) ('f'+$n.ToString('000')+'.txt')),('file number '+$n))}
        $skippedData=Join-Path $Root 'skipped-data';[void][IO.Directory]::CreateDirectory($skippedData);[IO.File]::WriteAllText((Join-Path $skippedData 'skipped.txt'),'not selected')
        $item=New-WsmItem $source.HostId Storage DataRoot 'Fixture data folder' 'fixture-data' @{Path=$sourceData}
        $skipped=New-WsmItem $source.HostId Storage DataRoot 'Fixture skipped folder' 'fixture-skipped' @{Path=$skippedData}
        $inventory=New-WsmInventory $source 1 @($item,$skipped);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:backupFixtureInventoryPath=$inventoryPath
        Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target'
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceData;TargetPath=(Join-Path $Root 'restored');TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Isolated actual bytes test';BusinessChecks=@('Read back each source file')}
        $specPath=Join-Path $Root 'spec.json';Write-WsmJson $specPath $spec
        Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash 0
        Set-WsmDecision $managerRoot $catalog.PairId @($item.ItemId) Include 'Explicit fixture selection' 1|Out-Null
        Set-WsmDecision $managerRoot $catalog.PairId @($skipped.ItemId) Exclude 'Fixture exclusion' 2|Out-Null
        $planPath=Join-Path $Root 'approved-plan.json';$approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath 3 'ISOLATED-PILOT'
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        $pair=[string]$import.PairId
        $operationId=[Guid]::NewGuid().ToString('D')
        $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $pair -PlanHash $approved.SHA256 -OperationId $operationId
        $result=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pair -OperationId $operationId -DeliveryMode Directory -VolumeBytes 0 -Jobs @() -CancellationToken $token
        & $check ($result.Stage -ceq 'Delivered' -and $result.ItemResults.Status -ceq 'Generated') 'The fixture backup must be delivered with an item-results set.'
        $profile=Read-WsmOutputProfile $sourceRoot
        $attemptPath=(Get-WsmWizardBackupAttemptForOperation $sourceRoot $pair $profile $operationId).Path
        $itemId=[string]$item.ItemId;$skippedId=[string]$skipped.ItemId
        $bytesOf={param([string]$Path)[IO.File]::ReadAllBytes($Path)}
        $restoreBytes={param([string]$Path,[byte[]]$Bytes)[IO.File]::WriteAllBytes($Path,$Bytes)}
        $tree={param([string]$Directory)(@(Get-ChildItem -LiteralPath $Directory -Recurse -File -Force|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}) -join "`n")}
        $rejection={param([scriptblock]$Action)try{& $Action|Out-Null;''}catch{[string]$_.Exception.Message}}
        $view={Get-WsmWizardBackupItemResultsView $sourceRoot $pair}

        # ---- result set v2 reaches the view; no receipt means "not verified" ----
        $v=& $view
        & $check ($v.available -and $v.integrity -ceq 'Verified' -and $v.schemaVersion -eq 2 -and $v.PSObject.Properties['coverageRegions']) 'The view must expose the verified v2 result set with coverageRegions.'
        $rowById=@{};foreach($r in @($v.rows)){$rowById[[string]$r.ItemId]=$r}
        & $check ($rowById[$itemId].Status -ceq 'BackedUp' -and $rowById[$skippedId].Status -ceq 'NotBackedUp' -and $rowById[$skippedId].ReasonCode -ceq 'Excluded') 'The fixture needs one backed-up and one excluded item.'
        & $check ($v.independentCopy.state -ceq 'NotVerified' -and $v.independentCopy.text -ceq '尚未驗證') 'Without any receipt the column must read not verified.'
        Write-Host 'PASS: no receipt shows not verified.'

        # ---- a real independent copy and its receipt ----
        $script:fixtureMediaClass='Removable'
        $origMediaClass=(Get-Command Get-WsmIndependentCopyMediaClass -CommandType Function).ScriptBlock
        function script:Get-WsmIndependentCopyMediaClass {param($DestinationRoot)$script:fixtureMediaClass}
        function Get-WsmIndependentCopyMediaClass {param($DestinationRoot)$script:fixtureMediaClass}
        try{
            $media=Join-Path $Root 'media';[void][IO.Directory]::CreateDirectory($media)
            Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pair -BackupOperationId $operationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $media -Mode Copy|Out-Null
        }finally{
            Set-Item -Path Function:\script:Get-WsmIndependentCopyMediaClass -Value $origMediaClass
            Set-Item -Path Function:\Get-WsmIndependentCopyMediaClass -Value $origMediaClass
        }
        $attempt=(Get-WsmWizardBackupAttemptForOperation $sourceRoot $pair $profile $operationId).Attempt
        $receiptPath=[string]$attempt.IndependentCopy.ReceiptPath
        $receipt=Read-WsmJson $receiptPath
        & $check ($receipt.PSObject.Properties['ItemResultsSHA256'] -and [string]$receipt.ItemResultsSHA256 -ceq [string]$attempt.ItemResults.SHA256) 'The receipt must cite the SHA256 of the item-results set it covers.'
        $v=& $view
        & $check ($v.independentCopy.state -ceq 'Verified' -and $v.independentCopy.text -ceq '已驗證' -and [string]$v.independentCopy.verifiedUtc -ceq [string]$receipt.VerifiedUtc) 'A valid receipt must show verified with its receipt time.'
        Write-Host 'PASS: valid receipt shows verified with the receipt time.'

        # ---- every failed condition reads "cannot be reconciled" and never "verified" ----
        $receiptOriginal=& $bytesOf $receiptPath;$attemptOriginal=& $bytesOf $attemptPath
        $assertUnverifiable={param([string]$Label)$x=& $view;if($x.independentCopy.state -cne 'Unverifiable' -or $x.independentCopy.text -cne '收據無法核對' -or $x.independentCopy.verifiedUtc -or $x.independentCopy.text -ceq '已驗證'){throw ($Label+': expected an unverifiable column but got '+$x.independentCopy.state)}}
        $assertVerified={param([string]$Label)if((& $view).independentCopy.state -cne 'Verified'){throw ($Label+': restoring the original bytes must verify again.')}}
        # 1. receipt bytes changed: the SHA256 recorded in the attempt no longer matches
        [IO.File]::AppendAllText($receiptPath,' ');& $assertUnverifiable 'altered receipt';& $restoreBytes $receiptPath $receiptOriginal;& $assertVerified 'altered receipt'
        # 2. receipt file lost
        Remove-Item -LiteralPath $receiptPath -Force;& $assertUnverifiable 'missing receipt';& $restoreBytes $receiptPath $receiptOriginal;& $assertVerified 'missing receipt'
        # 3. receipt cites another result set although its own hash was re-recorded, so only the citation can catch it
        $edited=Read-WsmJson $receiptPath;$edited.ItemResultsSHA256=('0'*64);Write-WsmJson $receiptPath $edited
        $editedAttempt=Read-WsmJson $attemptPath;$editedAttempt.IndependentCopy.ReceiptSHA256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();Write-WsmJson $attemptPath $editedAttempt
        & $assertUnverifiable 'result-set hash mismatch'
        & $restoreBytes $receiptPath $receiptOriginal;& $restoreBytes $attemptPath $attemptOriginal;& $assertVerified 'result-set hash mismatch'
        # 4. a receipt written before the citation existed cannot prove which result set it covers
        $edited=Read-WsmJson $receiptPath;$edited.PSObject.Properties.Remove('ItemResultsSHA256');Write-WsmJson $receiptPath $edited
        $editedAttempt=Read-WsmJson $attemptPath;$editedAttempt.IndependentCopy.ReceiptSHA256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();Write-WsmJson $attemptPath $editedAttempt
        & $assertUnverifiable 'receipt without a result-set citation'
        & $restoreBytes $receiptPath $receiptOriginal;& $restoreBytes $attemptPath $attemptOriginal;& $assertVerified 'receipt without a result-set citation'
        # 5. the attempt names a receipt outside the receipt folder
        $outside=Join-Path $Root 'outside-receipt.json';& $restoreBytes $outside $receiptOriginal
        $editedAttempt=Read-WsmJson $attemptPath;$editedAttempt.IndependentCopy.ReceiptPath=$outside;Write-WsmJson $attemptPath $editedAttempt
        & $assertUnverifiable 'receipt outside its folder'
        & $restoreBytes $attemptPath $attemptOriginal;& $assertVerified 'receipt outside its folder'
        # 6. receipt belongs to another delivery
        $edited=Read-WsmJson $receiptPath;$edited.DeliverySHA256=('1'*64);Write-WsmJson $receiptPath $edited
        $editedAttempt=Read-WsmJson $attemptPath;$editedAttempt.IndependentCopy.ReceiptSHA256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();Write-WsmJson $attemptPath $editedAttempt
        & $assertUnverifiable 'receipt of another delivery'
        & $restoreBytes $receiptPath $receiptOriginal;& $restoreBytes $attemptPath $attemptOriginal;& $assertVerified 'receipt of another delivery'
        # 7. the newest copy attempt failed: the attempt records no verified copy any more
        $editedAttempt=Read-WsmJson $attemptPath;$editedAttempt.IndependentCopy=[pscustomobject]@{Status='Failed';Availability='NotVerified';Error='fixture failure'};Write-WsmJson $attemptPath $editedAttempt
        & $check ((& $view).independentCopy.state -ceq 'NotVerified') 'A failed newest copy must not read as verified.'
        & $restoreBytes $attemptPath $attemptOriginal;& $assertVerified 'failed newest copy'
        Write-Host 'PASS: altered, missing, mismatched, legacy, relocated and foreign receipts never read as verified.'

        # ---- the drill-down ----
        $beforeTree=& $tree $sourceRoot
        $page1=Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 1
        $package=Test-WsmMigrationPackage ([string]$attempt.PackageTest.ManifestPath) ([string]$attempt.PackageTest.SHA256)
        $artifactRows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash|Where-Object {[string]$_.ItemId -ceq $itemId})
        & $check ($artifactRows.Count -ge 131) ('The fixture must archive more than one page of members; found '+$artifactRows.Count)
        & $check ($page1.kind -ceq 'BackupItemFiles' -and $page1.available -and $page1.ItemId -ceq $itemId -and $page1.Page -eq 1 -and $page1.PageSize -eq 100) 'Page 1 shape.'
        & $check ($page1.TotalCount -eq $artifactRows.Count -and $page1.PageCount -eq [int][Math]::Ceiling($artifactRows.Count/100.0)) 'The total and page count must come from the archive.'
        & $check (@($page1.Entries).Count -eq 100) 'A full page holds exactly 100 entries.'
        $page2=Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 2
        & $check (@($page2.Entries).Count -eq ($artifactRows.Count-100) -and $page2.Page -eq 2) 'The second page holds the remainder.'
        $page3=Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 3
        & $check (@($page3.Entries).Count -eq 0 -and $page3.TotalCount -eq $artifactRows.Count) 'A page past the end is empty but keeps the total.'
        $seen=@{};foreach($e in @($page1.Entries)+@($page2.Entries)){if($seen.ContainsKey([string]$e.RelativePath)){throw ('The pages overlap on '+$e.RelativePath)};$seen[[string]$e.RelativePath]=$e}
        & $check ($seen.Count -eq $artifactRows.Count) 'Two pages together list every archived member exactly once.'
        $archivedFile=@($artifactRows|Where-Object {-not $_.Directory})[0]
        $listed=$seen[[string]$archivedFile.RelativePath]
        & $check ($listed -and -not $listed.IsDirectory -and [long]$listed.Bytes -eq [long]$archivedFile.Data.Bytes -and $listed.Sha256Prefix.Length -eq 12 -and ([string]$archivedFile.Data.Hash).StartsWith($listed.Sha256Prefix,[StringComparison]::OrdinalIgnoreCase)) 'Entries carry the relative path, size and the first 12 SHA256 characters of the archived file.'
        $directories=@($artifactRows|Where-Object {$_.Directory})
        & $check ($directories.Count -ge 1 -and $page1.DirectoryCount -eq $directories.Count) 'The empty folder must be an archived directory member.'
        $dirEntry=$seen[[string]$directories[0].RelativePath]
        & $check ($dirEntry -and $dirEntry.IsDirectory -and $dirEntry.Bytes -eq 0 -and $dirEntry.Sha256Prefix -ceq '') 'Directory members are marked as directories with no size or hash.'
        # a backed-up item without a package entry is a valid empty set, not an error: covered by the unknown / not-backed-up refusals below
        & $check ((& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId 'no-such-item' -Page 1}) -like '*not part of the current backup result set*') 'An unknown ItemId must be refused.'
        & $check ((& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $skippedId -Page 1}) -like '*was not backed up*') 'An item that was not backed up has no archived files to list.'
        & $check ((& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 0}) -like '*Page is out of range*') 'Page 0 is refused.'
        & $check ((& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId ("a`nb") -Page 1}) -like '*ItemId is not valid*') 'A control character in the ItemId is refused.'
        & $check ((& $rejection {Get-WsmWizardBackupItemFiles -Workspace $managerRoot -PairId $pair -ItemId $itemId -Page 1}) -ne '') 'A non-Source workspace is refused.'
        & $check ($beforeTree -ceq (& $tree $sourceRoot)) 'Reading file details must not change a single byte of the workspace (no journal, no attempt rewrite).'
        Write-Host 'PASS: drill-down pages, total, directory members and refusals.'

        # ---- a package that is tampered with or not sealed is refused, never listed ----
        $manifestPath=[string]$attempt.PackageTest.ManifestPath;$artifactsPath=Join-Path (Split-Path -Parent $manifestPath) 'artifacts.jsonl'
        $manifestOriginal=& $bytesOf $manifestPath;$artifactsOriginal=& $bytesOf $artifactsPath
        try{
            $artifactText=[IO.File]::ReadAllText($artifactsPath);if(-not $artifactText.Contains("f001.txt")){throw "fixture artifact index lacks f001.txt"};[IO.File]::WriteAllText($artifactsPath,$artifactText.Replace("f001.txt","f00X.txt"),(New-Object Text.UTF8Encoding($false)));$why=& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 1}
            & $check ($why -ne '') 'A changed artifact index must be refused.';& $restoreBytes $artifactsPath $artifactsOriginal
            [IO.File]::AppendAllText($manifestPath,' ');$why=& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 1}
            & $check ($why -ne '') 'A changed package manifest must be refused.';& $restoreBytes $manifestPath $manifestOriginal
            $editedAttempt=Read-WsmJson $attemptPath;$editedAttempt.CoreExport.Sealed=$false;Write-WsmJson $attemptPath $editedAttempt
            & $check ((& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 1}) -like '*not sealed*') 'An unsealed package must be refused.'
            & $restoreBytes $attemptPath $attemptOriginal
            $editedAttempt=Read-WsmJson $attemptPath;$editedAttempt.PackageTest.Valid=$false;Write-WsmJson $attemptPath $editedAttempt
            & $check ((& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 1}) -like '*not sealed and verified*') 'A package that did not verify must be refused.'
            & $restoreBytes $attemptPath $attemptOriginal
            $editedAttempt=Read-WsmJson $attemptPath;$editedAttempt.PackageTest.SHA256=('2'*64);Write-WsmJson $attemptPath $editedAttempt
            & $check ((& $rejection {Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 1}) -ne '') 'A package record that disagrees with the core export must be refused.'
            & $restoreBytes $attemptPath $attemptOriginal
        }finally{
            & $restoreBytes $artifactsPath $artifactsOriginal;& $restoreBytes $manifestPath $manifestOriginal;& $restoreBytes $attemptPath $attemptOriginal
        }
        $again=Get-WsmWizardBackupItemFiles -Workspace $sourceRoot -PairId $pair -ItemId $itemId -Page 1
        & $check ($again.TotalCount -eq $artifactRows.Count) 'After restoring the original bytes the listing works again.'
        Write-Host 'PASS: tampered and unsealed packages are refused.'

        # ---- action wiring: exported, role-bound, read-only, projected through the closed UI projection ----
        & $check ((Get-Module WindowsServerMigration).ExportedFunctions.ContainsKey('Get-WsmWizardBackupItemFiles')) 'Get-WsmWizardBackupItemFiles must be exported (workers resolve actions through exports).'
        $map=Get-WsmHtmlActionMap
        & $check ($map.Contains('BackupItemFiles') -and $map['BackupItemFiles'] -ceq 'Get-WsmWizardBackupItemFiles') 'BackupItemFiles must be registered in the HTML action map.'
        $metaSource=@(Get-WsmHtmlActionMetadata Source|Where-Object action -CEQ 'BackupItemFiles')
        & $check ($metaSource.Count -eq 1 -and $metaSource[0].readOnly -and $metaSource[0].roleAvailable -and $metaSource[0].requiredRole -ceq 'Source') 'BackupItemFiles is a read-only Source action.'
        $metaManager=@(Get-WsmHtmlActionMetadata Manager|Where-Object action -CEQ 'BackupItemFiles')
        & $check ($metaManager.Count -eq 1 -and -not $metaManager[0].roleAvailable) 'BackupItemFiles is not available to the Manager role.'
        $projected=ConvertTo-WsmWizardHtmlValue $page1
        & $check ($projected.TotalCount -eq $page1.TotalCount -and $projected.Page -eq 1 -and $projected.PageCount -eq $page1.PageCount -and $projected.DirectoryCount -eq $page1.DirectoryCount -and @($projected.Entries).Count -eq 100) 'The closed UI projection must keep the paging fields.'
        $projectedEntry=$projected.Entries[0]
        foreach($field in @('RelativePath','Bytes','Sha256Prefix','IsDirectory')){& $check ([bool]$projectedEntry.PSObject.Properties[$field]) ('The closed UI projection dropped '+$field+'.')}
        Write-Host 'PASS: BackupItemFiles is exported, role-bound, read-only and survives the closed projection.'
    } $root
}
finally{
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmwv-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
# The HTML route injects Workspace and PairId only when absent, so BackupItemFiles must require both to equal the session binding.
$consoleSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\HtmlConsole.ps1'))
$fieldMatch=[regex]::Match($consoleSource,"\`$body\.action -ceq 'BackupItemFiles'\)\{if\(\`$route[^;]*;[^;]*;Assert-WsmFields \`$body\.args @\(([^)]*)\)")
if(-not $fieldMatch.Success -or $fieldMatch.Index -lt 0 -or $consoleSource.IndexOf("throw 'Backup file details are bound to the enrolled workspace and the selected pair.'") -lt 0 -or $consoleSource.IndexOf('[IO.Path]::GetFullPath([string]$body.args.Workspace) -ine [IO.Path]::GetFullPath($Workspace) -or -not $body.args.PSObject.Properties[''PairId''] -or [string]$body.args.PairId -cne [string]$PairId') -lt 0){throw 'BackupItemFiles must reject a client-supplied Workspace or PairId that differs from the session binding.'}
Write-Host 'PASS: backup workbench view.'
