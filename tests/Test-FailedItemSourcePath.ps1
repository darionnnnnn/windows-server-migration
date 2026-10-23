#requires -Version 5.1
# P4: 擷取失敗項目顯示來源路徑。路徑只在投影時從已核准計畫（雜湊核對後）查出，不寫進 attempt／journal／結果集。
# A 段用合成計畫驗證安全化、截斷明示、非檔案項目、計畫缺少／竄改；B 段跑真實失敗備份，確認 attempt 檔不含路徑而工作台 view 有路徑；
# C 段確認離線報告的對應列顯示同一路徑且已 escape。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path payload test.'}
cmd.exe /c ('subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"')
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the failed item path test.'}
$root=Join-Path ($driveLetter+':\') ('wsmfp-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $check={param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}

        # ---- A. 合成計畫：安全化、截斷明示、非檔案項目、計畫缺少／竄改 ----
        $xssPath='C:\data\<script>alert(1)</script>'
        $ctlPath='C:\data\bad'+[char]1+'x'+[char]13+[char]10+'y'+[char]0x202E+'z'
        $midPath='C:\'+('m'*297)          # 300 字元：Windows 長路徑，不可被截斷
        $longPath='C:\'+('L'*1497)        # 1500 字元：超過顯示上限，必須明示截斷
        $secretPath='C:\data\password=hunter2\file'
        $mkItem={param([string]$Id,$Spec)$o=[ordered]@{ItemId=$Id;Name=('name-'+$Id);Kind='DataRoot';Category='Storage'};if($null -ne $Spec){$o['MigrationSpec']=$Spec};[pscustomobject]$o}
        $planObject=[pscustomobject]@{Items=@(
            (& $mkItem 'xss' ([pscustomobject]@{Adapter='FileScope';SourcePath=$xssPath;TransferChannel='C'})),
            (& $mkItem 'ctl' ([pscustomobject]@{Adapter='FileScope';SourcePath=$ctlPath;TransferChannel='C'})),
            (& $mkItem 'mid' ([pscustomobject]@{Adapter='FileScope';SourcePath=$midPath;TransferChannel='C'})),
            (& $mkItem 'long' ([pscustomobject]@{Adapter='FileScope';SourcePath=$longPath;TransferChannel='C'})),
            (& $mkItem 'secret' ([pscustomobject]@{Adapter='FileScope';SourcePath=$secretPath;TransferChannel='C'})),
            (& $mkItem 'svc' ([pscustomobject]@{Adapter='Service'})),
            (& $mkItem 'nospec' $null),
            (& $mkItem 'emptyfs' ([pscustomobject]@{Adapter='FileScope';SourcePath='';TransferChannel='C'})),
            (& $mkItem 'dup' ([pscustomobject]@{Adapter='FileScope';SourcePath='C:\a'})),
            (& $mkItem 'dup' ([pscustomobject]@{Adapter='FileScope';SourcePath='C:\b'}))
        )}
        $planFile=Join-Path $Root 'synthetic-plan.json'
        [IO.File]::WriteAllText($planFile,'{"synthetic":"approved plan stand-in"}',(New-Object Text.UTF8Encoding($false)))
        $planHash=(Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $planRef=[pscustomobject]@{Path=$planFile;SHA256=$planHash;Plan=$planObject}
        $view={param([string]$Id,$Ref=$planRef,[string]$Expected=$planHash)Get-WsmBackupFailedItemSourcePathView $Ref $Expected $Id}

        $xss=& $view 'xss'
        & $check ($xss.state -ceq 'Resolved' -and $xss.text -ceq $xssPath -and -not $xss.truncated) 'A plan path must be projected as data (HTML escaping belongs to the display side, so textContent shows it verbatim).'
        $ctl=& $view 'ctl'
        & $check ($ctl.state -ceq 'Resolved' -and $ctl.text -notmatch '[\x00-\x1f\x7f]' -and $ctl.text -notmatch [string][char]0x202E -and $ctl.text.Contains('\u0001') -and $ctl.text.Contains('\u000D\u000A') -and $ctl.text.Contains('\u202E')) 'Control and bidi-override characters must be turned into visible \uXXXX text.'
        $mid=& $view 'mid'
        & $check ($mid.state -ceq 'Resolved' -and $mid.text -ceq $midPath -and -not $mid.truncated -and $mid.fullLength -eq 300) 'A 300 character path is a valid Windows long path and must not be truncated.'
        $long=& $view 'long'
        & $check ($long.state -ceq 'Resolved' -and $long.truncated -and $long.text.Length -eq 1024 -and $long.fullLength -eq 1500 -and $long.reason.Contains('1500') -and $long.reason.Contains('1024')) 'A path over the display limit must be truncated and the truncation must be stated with the real length.'
        $secret=& $view 'secret'
        & $check ($secret.text -notmatch 'hunter2' -and $secret.text.Contains('[redacted]')) 'An embedded secret assignment inside a path must be masked.'
        $svc=& $view 'svc'
        & $check ($svc.state -ceq 'NoPath' -and $svc.text -ceq '' -and $svc.reason -ceq '此項目沒有檔案路徑。' -and $svc.label -ceq '沒有檔案路徑') 'A non-file item must say it has no file path.'
        foreach($id in @('nospec','emptyfs')){$row=& $view $id;& $check ($row.state -ceq 'NoPath' -and $row.text -ceq '') ('An item without a source path must read as no file path: '+$id)}
        # 無法核對：缺計畫、ItemId 不在計畫、ItemId 重複、綁定雜湊不同、計畫檔遺失、計畫檔被竄改。每一種都不丟例外、不帶路徑。
        $assertUnverifiable={param($Result,[string]$Why)& $check ($Result.state -ceq 'Unverifiable' -and $Result.text -ceq '' -and $Result.label -ceq '無法核對來源路徑' -and [bool]$Result.reason -and $Result.reason -match '[\u4e00-\u9fff]') ('Must read as unverifiable with a reason: '+$Why)}
        & $assertUnverifiable (& $view 'xss' $null) 'no plan'
        & $assertUnverifiable (Get-WsmBackupFailedItemSourcePathView $null '' 'xss') 'no plan reference at all'
        & $assertUnverifiable (& $view 'not-in-plan') 'item id not in plan'
        & $assertUnverifiable (& $view 'dup') 'item id appears twice'
        & $assertUnverifiable (& $view 'xss' $planRef ('f'*64)) 'attempt bound to another plan hash'
        & $assertUnverifiable (& $view 'xss' ([pscustomobject]@{Path=$planFile;SHA256='not-a-hash';Plan=$planObject})) 'malformed plan hash'
        & $assertUnverifiable (& $view 'xss' ([pscustomobject]@{Path=(Join-Path $Root 'gone.json');SHA256=$planHash;Plan=$planObject})) 'plan file missing'
        $tamperedFile=Join-Path $Root 'tampered-plan.json';Copy-Item -LiteralPath $planFile -Destination $tamperedFile;[IO.File]::AppendAllText($tamperedFile,' ')
        $tampered=& $view 'xss' ([pscustomobject]@{Path=$tamperedFile;SHA256=$planHash;Plan=$planObject})
        & $assertUnverifiable $tampered 'plan file bytes changed after approval'
        & $check ($tampered.reason.Contains('不符')) 'The tampered plan reason must say the hash does not match.'
        & $check ((ConvertTo-Json $tampered -Compress) -notmatch 'script') 'An unverifiable result must carry no path.'
        # 失敗檢視本身：沒有計畫參照時 failedItem 仍可產生（只是無法核對），不可 throw
        $attemptStub=[pscustomobject]@{AttemptId='a1';PlanHash=$planHash;UpdatedUtc='2026-10-23T00:00:00Z';Error=[pscustomobject]@{Code='core_export_failed';FailedItem=[pscustomobject]@{ItemId='xss';Name='n';Kind='DataRoot';Channel='C';ErrorClass='IOError';ErrorKind='System.IO.IOException'}}}
        $noPlanView=ConvertTo-WsmBackupFailureView $attemptStub
        & $check ($noPlanView.failedItem.SourcePath.state -ceq 'Unverifiable' -and $noPlanView.failedItem.ItemId -ceq 'xss') 'The failure view without a plan reference must still render, marked unverifiable.'
        $okView=ConvertTo-WsmBackupFailureView $attemptStub $planRef
        & $check ($okView.failedItem.SourcePath.state -ceq 'Resolved' -and $okView.failedItem.SourcePath.text -ceq $xssPath) 'The failure view with a verified plan must carry the source path.'
        # 寫入端：擷取失敗紀錄只含身分與錯誤型別，不含路徑（來源路徑欄位與路徑字串都不可出現）
        $tagged=[UnauthorizedAccessException]::new('denied '+$xssPath);$tagged.Data['WsmCaptureFailedItemId']='xss'
        $record=New-WsmWizardBackupCaptureFailure $planObject $tagged
        $recordJson=ConvertTo-Json $record -Compress
        & $check ($record.ItemId -ceq 'xss' -and -not $record.PSObject.Properties['SourcePath'] -and -not $record.PSObject.Properties['Path'] -and -not $recordJson.Contains('script') -and -not $recordJson.Contains('C:\\data')) 'The capture failure record must not carry the source path.'
        Write-Host 'PASS: A. synthetic plan - safe projection, explicit truncation, no-path items, unverifiable cases.'

        # ---- B. 真實失敗備份：attempt 檔不含路徑，工作台 view 有路徑 ----
        $script:backupFixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:backupFixtureFingerprint;Name='failed-path-fixture-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:backupFixtureInventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);if(-not $script:backupFixtureInventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:backupFixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:backupFixtureInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager-work'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:backupFixtureFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:backupFixtureFingerprint=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        $dataOk=Join-Path $Root 'data-ok';$dataBad=Join-Path $Root 'data-vanish'
        foreach($dir in @($dataOk,$dataBad)){[void][IO.Directory]::CreateDirectory($dir);[IO.File]::WriteAllText((Join-Path $dir 'a.txt'),('bytes of '+(Split-Path -Leaf $dir)))}
        $itemOk=New-WsmItem $source.HostId Storage DataRoot 'Okay data folder' 'fixture-ok' @{Path=$dataOk}
        $itemBad=New-WsmItem $source.HostId Storage DataRoot 'Doomed data folder' 'fixture-bad' @{Path=$dataBad}
        $inventory=New-WsmInventory $source 1 @($itemOk,$itemBad);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:backupFixtureInventoryPath=$inventoryPath
        Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target'
        $revision=0
        foreach($pair in @(@($itemOk,$dataOk),@($itemBad,$dataBad))){
            $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$pair[1];TargetPath=(Join-Path $Root ('restored-'+(Split-Path -Leaf $pair[1])));TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Isolated actual bytes test';BusinessChecks=@('Read back each source file')}
            $specPath=Join-Path $Root ('spec-'+[Guid]::NewGuid().ToString('N')+'.json');Write-WsmJson $specPath $spec
            Set-WsmMigrationSpec $managerRoot $catalog.PairId $pair[0].ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash $revision
            $revision++
        }
        Set-WsmDecision $managerRoot $catalog.PairId @($itemOk.ItemId,$itemBad.ItemId) Include 'Explicit fixture selection' $revision|Out-Null
        $revision++
        $planPath=Join-Path $Root 'approved-plan.json';$approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath $revision 'ISOLATED-PILOT'
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        $pairId=[string]$import.PairId
        Remove-Item -LiteralPath $dataBad -Recurse -Force
        $failOperation=[Guid]::NewGuid().ToString('D')
        $thrown=$false;try{Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId $failOperation -DeliveryMode Directory -VolumeBytes 0 -Jobs @()|Out-Null}catch{$thrown=$true}
        & $check $thrown 'The backup must fail when one included scope vanished.'
        $profile=Read-WsmOutputProfile $sourceRoot
        $attemptRef=Get-WsmWizardBackupAttemptForOperation $sourceRoot $pairId $profile $failOperation
        $attempt=$attemptRef.Attempt
        & $check ($attempt.Stage -ceq 'Failed' -and $attempt.Error.FailedItem.ItemId -ceq $itemBad.ItemId) 'The attempt must be Failed and name the failed item.'
        # 位元組與欄位兩個角度都比對：attempt 檔、同資料夾所有檔、journal 都不可有失敗路徑
        # JSON 會把反斜線寫成雙反斜線，所以原字串、JSON 跳脫形式、與只有這個路徑才有的獨特片段都要比。
        $pathNeedles=@($dataBad,$dataBad.Replace([string][char]92,[string][char]92+[char]92),'data-vanish')|ForEach-Object {,[Text.Encoding]::UTF8.GetBytes($_)}
        $containsBytes={param([byte[]]$Haystack,[byte[]]$Needle)$found=$false;for($i=0;$i -le $Haystack.Length-$Needle.Length -and -not $found;$i++){if($Haystack[$i] -eq $Needle[0]){$match=$true;for($j=1;$j -lt $Needle.Length;$j++){if($Haystack[$i+$j] -ne $Needle[$j]){$match=$false;break}};if($match){$found=$true}}};$found}
        $attemptBytes=[IO.File]::ReadAllBytes($attemptRef.Path)
        foreach($needle in $pathNeedles){& $check (-not (& $containsBytes $attemptBytes $needle)) 'The attempt file bytes must not contain the failed item source path.'}
        $attemptText=[Text.Encoding]::UTF8.GetString($attemptBytes)
        & $check (-not $attempt.Error.FailedItem.PSObject.Properties['SourcePath'] -and -not $attempt.Error.FailedItem.PSObject.Properties['Path'] -and -not $attempt.Error.FailedItem.PSObject.Properties['Location']) 'The FailedItem record must not have a path field.'
        $attemptFolder=Split-Path -Parent $attemptRef.Path
        foreach($file in @(Get-ChildItem -LiteralPath $attemptFolder -File -Recurse)){$fileBytes=[IO.File]::ReadAllBytes($file.FullName);foreach($needle in $pathNeedles){& $check (-not (& $containsBytes $fileBytes $needle)) ('A persisted backup record must not contain the failed source path: '+$file.Name)}}
        $failedView=Get-WsmWizardBackupItemResultsView $sourceRoot $pairId
        $shown=$failedView.failedAttempt.failedItem.SourcePath
        & $check (-not $failedView.available -and $shown.state -ceq 'Resolved' -and $shown.text -ceq $dataBad -and -not $shown.truncated) 'The workbench view must show the source path looked up from the approved plan.'
        # 計畫在投影前被改掉：工作台不丟例外、也不顯示路徑
        $planCopy=Join-Path $Root 'plan-before-tamper.bin';$receivedRef=Get-WsmWizardReceivedApprovedPlan $sourceRoot $pairId $profile
        Copy-Item -LiteralPath $receivedRef.Path -Destination $planCopy
        $staleRef=$receivedRef
        [IO.File]::AppendAllText($receivedRef.Path,' ')
        $tamperedView=ConvertTo-WsmBackupFailureView $attempt $staleRef
        & $check ($tamperedView.failedItem.SourcePath.state -ceq 'Unverifiable' -and $tamperedView.failedItem.SourcePath.text -ceq '' -and $tamperedView.failedItem.SourcePath.reason.Contains('不符')) 'A plan altered after import must read as unverifiable, not show a path.'
        $threw=$false;$afterTamper=$null;try{$afterTamper=Get-WsmWizardBackupItemResultsView $sourceRoot $pairId}catch{$threw=$true}
        & $check (-not $threw -and $afterTamper -and -not $afterTamper.available -and -not ((ConvertTo-Json $afterTamper -Depth 8 -Compress).Contains('data-vanish'))) 'The result view must not throw nor reveal the path when the plan no longer verifies.'
        Copy-Item -LiteralPath $planCopy -Destination $receivedRef.Path -Force
        Write-Host 'PASS: B. real failed backup - attempt files carry no path, the view shows it, a tampered plan is unverifiable.'

        # ---- C. 離線報告的對應列：同一路徑、已 escape ----
        $software=[pscustomobject]@{SoftwareRows=@();FeatureRows=@();CoverageGaps=@()}
        $manifestHash='1234567890abcdef'*4;$reportPlanHash='fedcba0987654321'*4
        $reportPlan=[pscustomobject]@{Items=@(
            [pscustomobject]@{ItemId='xss';Name='Script folder';Kind='DataRoot';Category='Storage';NaturalKey='k-xss';Settings=[pscustomobject]@{};Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$xssPath;TransferChannel='C'};Dependencies=@()},
            [pscustomobject]@{ItemId='ctl';Name='Control folder';Kind='DataRoot';Category='Storage';NaturalKey='k-ctl';Settings=[pscustomobject]@{};Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$ctlPath;TransferChannel='C'};Dependencies=@()},
            [pscustomobject]@{ItemId='long';Name='Long folder';Kind='DataRoot';Category='Storage';NaturalKey='k-long';Settings=[pscustomobject]@{};Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$longPath;TransferChannel='C'};Dependencies=@()})}
        $reportRows=@(Get-WsmBackupItemResultRows $reportPlan $null @() $false)
        $meta=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=$reportPlanHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';Software=$software}
        $resultsPath=Join-Path $Root 'report-results.json';$export=Export-WsmBackupItemResults $resultsPath $reportRows $meta
        $reportFile=(Export-WsmBackupOfflineReport $resultsPath $export.SHA256 (Join-Path $Root 'report.html')).Path
        $html=[IO.File]::ReadAllText($reportFile,[Text.Encoding]::UTF8)
        & $check ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;') -and -not $html.Contains('<script>alert(1)')) 'The offline report row must show the injected path as escaped text.'
        $sameAsWorkbench=[Net.WebUtility]::HtmlEncode((Get-WsmBackupFailedItemSourcePathView ([pscustomobject]@{Path=$planFile;SHA256=$planHash;Plan=$reportPlan}) $planHash 'xss').text)
        & $check ($html.Contains('<td>'+$sameAsWorkbench+'</td>')) 'The report row must show the same path text as the workbench projection.'
        $ctlText=(Get-WsmBackupFailedItemSourcePathView ([pscustomobject]@{Path=$planFile;SHA256=$planHash;Plan=$reportPlan}) $planHash 'ctl').text
        & $check ($html.Contains([Net.WebUtility]::HtmlEncode($ctlText)) -and $html.Contains('\u0001') -and $html -notmatch [string][char]1) 'Control characters must be visible text in the report, never raw.'
        & $check ($html.Contains('路徑過長已截斷，原長 1500 個字元') -and -not $html.Contains('L'*1100)) 'A long path in the report must be truncated with an explicit note.'
        Write-Host 'PASS: C. offline report row shows the same escaped path.'
    } $root
}
finally{
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmfp-*'){throw 'Unsafe cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
Write-Host 'PASS: failed item source path.'
