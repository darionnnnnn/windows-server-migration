#requires -Version 5.1
# A1：獨立副本硬化（R6 媒體分級／工作區包含改比對正規化實體路徑、R7 第二次副本失敗或取消不抹掉 Verified、A8 媒體被刪不再宣稱已驗證、容量預檢）。
# 全部跑在真實封存備份上；只替身主機資格、磁碟型別觀測縫（Get-WsmDriveTypeName）、可用空間（Get-WsmAvailableBytes）與取消邊界。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$driveLetter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
if(-not $driveLetter){throw 'No free temporary drive letter is available for the short-path payload test.'}
cmd.exe /c ('subst '+$driveLetter+': "'+$tempBase.TrimEnd('\')+'"')
if($LASTEXITCODE -ne 0){throw 'Unable to create a temporary drive alias for the workbench view test.'}
$root=Join-Path ($driveLetter+':\') ('wsmic-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
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
        $realTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $script:fakeDriveType=''
        $script:copyFault=''
        $script:freeBytes=[long]1TB
        $origBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock
        $origAvailable=(Get-Command Get-WsmAvailableBytes -CommandType Function).ScriptBlock
        $driveSeam=Get-Command Get-WsmDriveTypeName -CommandType Function -ErrorAction SilentlyContinue
        $origDriveSeam=$(if($driveSeam){$driveSeam.ScriptBlock}else{$null})
        function script:Get-WsmDriveTypeName([string]$Root){if($script:fakeDriveType){return $script:fakeDriveType};[string](New-Object IO.DriveInfo($Root)).DriveType}
        function script:Assert-WsmCancellationBoundary($Token,[string]$Phase){
            if($Phase -ceq 'IndependentCopyFile' -and $script:copyFault){
                if($script:copyFault -ceq 'cancel'){$e=New-Object OperationCanceledException('fixture cancellation');$e.Data['CancellationRequested']=$true;throw $e}
                throw (New-Object IO.IOException('injected copy failure'))
            }
        }
        function script:Get-WsmAvailableBytes([string]$Path){if($script:freeBytes -lt 0){throw 'fixture capacity query failed'};[long]$script:freeBytes}
        $copyOp={param([string]$Destination,[string]$Mode='Copy')Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pair -BackupOperationId $operationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $Destination -Mode $Mode}
        $reload={(Get-WsmWizardBackupAttemptForOperation $sourceRoot $pair $profile $operationId).Attempt}
        $realMedia=Join-Path $realTemp ('wsmic-'+[Guid]::NewGuid().ToString('N').Substring(0,8));[void][IO.Directory]::CreateDirectory($realMedia)
        $junction=Join-Path $Root 'junc-to-workspace'
        try{
            # ================= R6：媒體分級不可被裝置路徑／本機 UNC 繞過 =================
            $realDriveLetter=$realTemp.Substring(0,1);$realRest=$realMedia.Substring(3)
            $realIsFixed=([string](New-Object IO.DriveInfo($realDriveLetter+':\')).DriveType -ceq 'Fixed')
            & $check $realIsFixed 'The test host temp drive must be a fixed disk for the R6 cases.'
            $variants=[ordered]@{
                'device-question'=@(('\\?\'+$realMedia),'Unknown')
                'device-dot'=@(('\\.\'+$realMedia),'Unknown')
                'forward-slash-device'=@(('//?/'+$realMedia.Replace('\','/')),'Unknown')
                'localhost-admin-share'=@(('\\localhost\'+$realDriveLetter+'$\'+$realRest),'LocalFixed')
                'loopback-ip-admin-share'=@(('\\127.0.0.1\'+$realDriveLetter+'$\'+$realRest),'LocalFixed')
                'computername-admin-share'=@(('\\'+$env:COMPUTERNAME+'\'+$realDriveLetter+'$\'+$realRest),'LocalFixed')
            }
            foreach($name in $variants.Keys){
                $path=$variants[$name][0];$expected=$variants[$name][1]
                $class=Get-WsmIndependentCopyMediaClass $path
                & $check ($class -cne 'Network') ('R6 '+$name+': a device or local-alias path must never classify as Network (got '+$class+').')
                & $check ($class -ceq $expected) ('R6 '+$name+': expected media class '+$expected+' but got '+$class+'.')
                $message=& $rejection {& $copyOp $path 'Copy'}
                & $check ([bool]$message) ('R6 '+$name+': Invoke-WsmWizardIndependentCopy must reject this destination.')
                & $check (@(Get-ChildItem -LiteralPath $realMedia -Force).Count -eq 0) ('R6 '+$name+': the rejected destination must receive no file.')
            }
            Write-Host 'PASS: R6 device paths and local UNC aliases are rejected, none writes anything.'
            # 正例：真正的外部 UNC 主機仍是 Network；即使共用名稱是 C$，主機不是本機就不是本機磁碟
            & $check ((Get-WsmIndependentCopyMediaClass '\\fixture-server\share\x') -ceq 'Network') 'R6: an external UNC host must classify as Network.'
            & $check ((Get-WsmIndependentCopyMediaClass '\\fixture-server\C$\x') -ceq 'Network') 'R6: an admin share on a different host is still Network.'
            & $check ((Get-WsmIndependentCopyMediaClass $env:SystemRoot) -ceq 'LocalFixed') 'R6: a plain local fixed path is still LocalFixed.'
            # 正例：可移除磁碟照舊分級（以觀測縫替身磁碟型別，其餘路徑處理走真實程式）
            foreach($typePair in @(@('Removable','Removable'),@('Fixed','LocalFixed'),@('Network','Network'),@('CDRom','Unknown'))){
                $script:fakeDriveType=$typePair[0]
                & $check ((Get-WsmIndependentCopyMediaClass (Join-Path $Root 'media-class')) -ceq $typePair[1]) ('R6: drive type '+$typePair[0]+' must classify as '+$typePair[1]+'.')
            }
            $script:fakeDriveType=''
            Write-Host 'PASS: R6 external UNC stays Network and removable/fixed/network drive types keep their classes.'
            # 工作區包含檢查要比對實體路徑：換個拼法（subst 別名／junction）指到工作區內仍要被擋
            $script:fakeDriveType='Removable'
            $realRoot=Join-Path $realTemp (Split-Path -Leaf $Root)
            & $check ([IO.Directory]::Exists($realRoot)) 'R6: the real spelling of the fixture root must exist.'
            $aliasInside=Join-Path $realRoot 'source-work\ic-inside'
            $m1=& $rejection {& $copyOp $aliasInside 'Copy'}
            & $check ($m1 -like '*outside the source workspace*') ('R6: a destination inside the workspace spelled through another alias must be rejected: '+$m1)
            & $check (-not [IO.Directory]::Exists((Join-Path $sourceRoot 'ic-inside'))) 'R6: the alias-spelled destination wrote inside the workspace.'
            cmd.exe /c ('mklink /J "'+$junction+'" "'+$sourceRoot+'"') | Out-Null
            & $check ([IO.Directory]::Exists($junction)) 'R6: the junction fixture could not be created.'
            $m2=& $rejection {& $copyOp (Join-Path $junction 'ic-via-junction') 'Copy'}
            & $check ([bool]$m2) 'R6: a destination reached through a junction into the workspace must be rejected.'
            & $check (-not [IO.Directory]::Exists((Join-Path $sourceRoot 'ic-via-junction'))) 'R6: the junction destination wrote inside the workspace.'
            cmd.exe /c ('rmdir "'+$junction+'"') | Out-Null
            $m3=& $rejection {& $copyOp $sourceRoot 'Copy'}
            & $check ($m3 -like '*outside the source workspace*') 'R6: the workspace itself must still be rejected.'
            Write-Host 'PASS: R6 workspace containment compares physical paths (alias spelling and junction).'

            # ================= R7：第二次副本失敗／取消不抹掉先前的 Verified =================
            $media1=Join-Path $Root 'media1';[void][IO.Directory]::CreateDirectory($media1)
            & $copyOp $media1 'Copy' | Out-Null
            $a1=& $reload
            $hash1=[string]$a1.IndependentCopy.ReceiptSHA256;$receiptPath1=[string]$a1.IndependentCopy.ReceiptPath
            & $check ($a1.IndependentCopy.Status -ceq 'Verified' -and $hash1) 'R7: the first copy must verify.'
            $v=& $view
            & $check ($v.independentCopy.state -ceq 'Verified' -and $v.independentCopy.PSObject.Properties['lastAttempt'] -and $null -eq $v.independentCopy.lastAttempt -and $v.independentCopy.canReverify -eq $true) 'R7: a clean verified copy has no lastAttempt and offers re-verification.'
            & $check ([string]$v.independentCopy.destinationRoot -ieq $media1) 'R7: the projection must carry the destination root that re-verification reuses.'
            $media2=Join-Path $Root 'media2';[void][IO.Directory]::CreateDirectory($media2)
            $script:copyFault='io';$e1=& $rejection {& $copyOp $media2 'Copy'};$script:copyFault=''
            & $check ($e1 -like '*injected copy failure*') ('R7: the injected failure did not reach the second copy: '+$e1)
            $a2=& $reload
            & $check ($a2.IndependentCopy.Status -ceq 'Verified' -and [string]$a2.IndependentCopy.ReceiptSHA256 -ceq $hash1 -and [string]$a2.IndependentCopy.ReceiptPath -ceq $receiptPath1) 'R7: a failed second copy erased the earlier verified receipt.'
            & $check ($a2.PSObject.Properties['IndependentCopyLastAttempt'] -and $a2.IndependentCopyLastAttempt.Status -ceq 'Failed' -and $a2.IndependentCopyLastAttempt.Code -ceq 'CopyFailed' -and $a2.IndependentCopyLastAttempt.AttemptedUtc -and $a2.IndependentCopyLastAttempt.NextStep -and $a2.IndependentCopyLastAttempt.Reason -like '*injected*') 'R7: the failed second copy must be kept as LastAttempt=Failed with time, code, reason and next step.'
            & $check ((ConvertTo-WsmWizardBackupResult $a2 $operationId).OfflineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed')) 'R7: offline readiness must stay verified after a failed second copy.'
            $v=& $view
            & $check ($v.independentCopy.state -ceq 'Verified' -and $v.independentCopy.lastAttempt.status -ceq 'Failed' -and $v.independentCopy.lastAttempt.newer -eq $true -and $v.independentCopy.lastAttempt.nextStep) 'R7: the view must show the receipt and the newer failed attempt side by side.'
            Write-Host 'PASS: R7 failed second copy keeps the Verified receipt and records LastAttempt=Failed.'
            $script:copyFault='cancel';$e2=& $rejection {& $copyOp $media2 'Copy'};$script:copyFault=''
            $a3=& $reload
            & $check ($a3.IndependentCopy.Status -ceq 'Verified' -and [string]$a3.IndependentCopy.ReceiptSHA256 -ceq $hash1) 'R7: a cancelled second copy erased the earlier verified receipt.'
            & $check ($a3.IndependentCopyLastAttempt.Status -ceq 'Cancelled' -and $a3.IndependentCopyLastAttempt.Code -ceq 'Cancelled') 'R7: a cancelled second copy must be recorded as Cancelled, not Failed.'
            & $check ((& $view).independentCopy.lastAttempt.status -ceq 'Cancelled') 'R7: the view must say the newer attempt was cancelled.'
            Write-Host 'PASS: R7 cancelled second copy keeps the receipt and records LastAttempt=Cancelled.'
            & $copyOp $media1 'VerifyExisting' | Out-Null
            $a4=& $reload
            & $check ($a4.IndependentCopy.Status -ceq 'Verified' -and (-not $a4.PSObject.Properties['IndependentCopyLastAttempt'] -or $null -eq $a4.IndependentCopyLastAttempt)) 'R7: a later successful verification must clear the stale LastAttempt.'
            & $check ($null -eq (& $view).independentCopy.lastAttempt) 'R7: the view must drop the lastAttempt after a success.'
            Write-Host 'PASS: R7 a later success clears LastAttempt.'
            # 收據自己的媒體驗證失敗（同一個 CopyRoot、非取消）：證明那份媒體已和收據不符。收據只留作歷史，離線就緒與畫面都不得再是「已驗證」。
            # 翻轉一個位元組、長度不變，所以只看存在與大小的媒體檢查看不出來，只有逐檔雜湊驗證會發現。
            $tamperTarget=@(Get-ChildItem -LiteralPath (Join-Path ([string]$a4.IndependentCopy.CopyRoot) 'transport') -Recurse -File | Where-Object {$_.Length -gt 0 -and $_.Name -notlike '*.json'} | Select-Object -First 1)[0]
            & $check ([bool]$tamperTarget) 'R7 same-media: no payload file found on the verified copy to tamper with.'
            $originalBytes=[IO.File]::ReadAllBytes($tamperTarget.FullName);$tampered=[byte[]]$originalBytes.Clone();$tampered[0]=$tampered[0] -bxor 0xFF;[IO.File]::WriteAllBytes($tamperTarget.FullName,$tampered)
            try{
                $e6=& $rejection {& $copyOp $media1 'VerifyExisting'}
                & $check ([bool]$e6) 'R7 same-media: re-verifying a tampered copy must fail.'
                $a6=& $reload
                & $check ($a6.IndependentCopy.Status -ceq 'Verified' -and [string]$a6.IndependentCopy.ReceiptSHA256 -and $a6.IndependentCopy.PSObject.Properties['MediaIntegrity'] -and [string]$a6.IndependentCopy.MediaIntegrity.Status -ceq 'NeedsReverification' -and [string]$a6.IndependentCopy.MediaIntegrity.Code -ceq 'VerifyFailed') 'R7 same-media: the receipt must stay as history but be marked MediaIntegrity=NeedsReverification.'
                & $check ($a6.IndependentCopyLastAttempt.Status -ceq 'Failed' -and $a6.IndependentCopyLastAttempt.Code -ceq 'VerifyFailed') 'R7 same-media: the failed re-verification must be recorded as LastAttempt VerifyFailed.'
                & $check ((ConvertTo-WsmWizardBackupResult $a6 $operationId).OfflineReadiness -ceq 'MediaNeedsReverification') 'R7 same-media: offline readiness must leave Verified when the receipt''s own media failed verification.'
                $v6=& $view
                & $check ($v6.independentCopy.state -ceq 'MediaMissing' -and [string]$v6.independentCopy.reason -like '*媒體已和收據不符*' -and $v6.independentCopy.canReverify -eq $true) ('R7 same-media: the view must stop saying verified and offer re-verification: '+[string]$v6.independentCopy.state)
            } finally { [IO.File]::WriteAllBytes($tamperTarget.FullName,$originalBytes) }
            & $copyOp $media1 'VerifyExisting' | Out-Null
            $a7=& $reload
            & $check ($a7.IndependentCopy.Status -ceq 'Verified' -and -not $a7.IndependentCopy.PSObject.Properties['MediaIntegrity'] -and (ConvertTo-WsmWizardBackupResult $a7 $operationId).OfflineReadiness -cin @('Verified','VerifiedNetworkAvailabilityUnconfirmed') -and (& $view).independentCopy.state -ceq 'Verified') 'R7 same-media: a successful re-verification of the restored media must clear the mark.'
            Write-Host 'PASS: R7 a failed re-verification of the receipt''s own media drops it from verified until a successful re-verification.'
            # 從未成功過：維持舊行為（IndependentCopy 記 Failed／Cancelled），並同樣有 LastAttempt
            $stripped=Read-WsmJson $attemptPath;$stripped.PSObject.Properties.Remove('IndependentCopy');if($stripped.PSObject.Properties['IndependentCopyLastAttempt']){$stripped.PSObject.Properties.Remove('IndependentCopyLastAttempt')};Write-WsmJson $attemptPath $stripped
            $script:copyFault='io';& $rejection {& $copyOp $media2 'Copy'}|Out-Null;$script:copyFault=''
            $a5=& $reload
            & $check ($a5.IndependentCopy.Status -ceq 'Failed' -and $a5.IndependentCopy.Availability -ceq 'NotVerified' -and $a5.IndependentCopyLastAttempt.Status -ceq 'Failed') 'R7: with no earlier receipt a failure is recorded as Failed (legacy behaviour) plus LastAttempt.'
            & $check ((& $view).independentCopy.state -ceq 'NotVerified') 'R7: no receipt still reads as not verified.'
            $script:copyFault='cancel';& $rejection {& $copyOp $media2 'Copy'}|Out-Null;$script:copyFault=''
            $a5b=& $reload
            & $check ($a5b.IndependentCopy.Status -cne 'Verified' -and $a5b.IndependentCopyLastAttempt.Status -ceq 'Cancelled') 'R7: with no earlier receipt a cancellation is recorded as Cancelled.'
            & $copyOp $media1 'VerifyExisting' | Out-Null
            $hash1=[string](& $reload).IndependentCopy.ReceiptSHA256
            Write-Host 'PASS: R7 first-ever failure/cancellation keeps the legacy record plus LastAttempt.'

            # ================= R7(A8)：媒體被刪後不可再宣稱「已驗證完成」 =================
            $copyRoot=[string](& $reload).IndependentCopy.CopyRoot
            $gone=$copyRoot+'-gone'
            Move-Item -LiteralPath $copyRoot -Destination $gone
            $v=& $view
            & $check ($v.independentCopy.state -ceq 'MediaMissing' -and $v.independentCopy.text -ceq '收據完整；媒體需重新驗證' -and $v.independentCopy.verifiedUtc -and $v.independentCopy.canReverify -eq $true -and $v.independentCopy.text -cne '已驗證') 'A8: with the copy media gone the view must read receipt intact, media needs re-verification.'
            Move-Item -LiteralPath $gone -Destination $copyRoot
            & $check ((& $view).independentCopy.state -ceq 'Verified') 'A8: with the media back the view reads verified again.'
            $member=@(Get-ChildItem -LiteralPath (Join-Path $copyRoot 'transport\delivery') -Recurse -File)[0]
            Move-Item -LiteralPath $member.FullName -Destination ($member.FullName+'.gone')
            & $check ((& $view).independentCopy.state -ceq 'MediaMissing') 'A8: one missing member file must also stop the verified claim.'
            $e3=& $rejection {& $copyOp $media1 'VerifyExisting'}
            & $check ($e3 -like '*Missing independent copy*') ('A8: re-verification of damaged media must fail: '+$e3)
            $a6=& $reload
            & $check ([string]$a6.IndependentCopy.ReceiptSHA256 -ceq $hash1 -and $a6.IndependentCopyLastAttempt.Status -ceq 'Failed' -and $a6.IndependentCopyLastAttempt.Code -ceq 'VerifyFailed') 'A8: failed re-verification keeps the receipt and records LastAttempt VerifyFailed.'
            $v=& $view
            & $check ($v.independentCopy.state -ceq 'MediaMissing' -and $v.independentCopy.lastAttempt.status -ceq 'Failed') 'A8: damaged media shows both the media state and the newer failed attempt.'
            Move-Item -LiteralPath ($member.FullName+'.gone') -Destination $member.FullName
            & $copyOp $media1 'VerifyExisting' | Out-Null
            & $check ((& $view).independentCopy.state -ceq 'Verified') 'A8: restoring the file and re-verifying must read verified again.'
            Write-Host 'PASS: A8 deleted or damaged media no longer reads as verified; re-verification reuses VerifyExisting.'

            # ================= 容量預檢 =================
            $hashBeforeCap=[string](& $reload).IndependentCopy.ReceiptSHA256
            $media3=Join-Path $Root 'media3';[void][IO.Directory]::CreateDirectory($media3)
            $script:freeBytes=[long]0
            $c1=& $rejection {& $copyOp $media3 'Copy'}
            & $check ($c1 -like '*InsufficientSpace*') ('Capacity: a full disk must be refused with the stable code InsufficientSpace: '+$c1)
            & $check (@(Get-ChildItem -LiteralPath $media3 -Force -Recurse).Count -eq 0) 'Capacity: a refused copy must write nothing to the destination.'
            $a7=& $reload
            & $check ([string]$a7.IndependentCopy.ReceiptSHA256 -ceq $hashBeforeCap -and [IO.File]::Exists([string]$a7.IndependentCopy.ReceiptPath)) 'Capacity: a refused copy must not damage the earlier receipt.'
            $la=$a7.IndependentCopyLastAttempt
            & $check ($la.Status -ceq 'Failed' -and $la.Code -ceq 'InsufficientSpace' -and [long]$la.RequiredBytes -ge 256MB -and [long]$la.AvailableBytes -eq 0 -and $la.NextStep) 'Capacity: the refusal must carry code, required bytes, available bytes and next step.'
            $required=[long]$la.RequiredBytes
            $script:freeBytes=$required-1
            $c2=& $rejection {& $copyOp $media3 'Copy'}
            & $check ($c2 -like '*InsufficientSpace*' -and @(Get-ChildItem -LiteralPath $media3 -Force -Recurse).Count -eq 0) 'Capacity: one byte short must still be refused with no write.'
            $script:freeBytes=$required
            & $copyOp $media3 'Copy' | Out-Null
            $a8=& $reload
            $receipt8=Read-WsmJson ([string]$a8.IndependentCopy.ReceiptPath)
            & $check ($a8.IndependentCopy.Status -ceq 'Verified' -and @(Get-ChildItem -LiteralPath $media3 -Force -Recurse -File).Count -gt 0 -and $receipt8.CapacityCheck.Status -ceq 'Sufficient' -and [long]$receipt8.CapacityCheck.RequiredBytes -eq $required) 'Capacity: exactly enough space must copy normally and record the check in the receipt.'
            Write-Host 'PASS: capacity precheck refuses before any write, keeps the old receipt and passes at exactly the needed size.'
            # 取不到可用空間：Warning 但允許，並寫進收據
            $media4=Join-Path $Root 'media4';[void][IO.Directory]::CreateDirectory($media4)
            $script:freeBytes=[long]-1
            & $copyOp $media4 'Copy' | Out-Null
            $a9=& $reload
            $receipt9=Read-WsmJson ([string]$a9.IndependentCopy.ReceiptPath)
            & $check ($a9.IndependentCopy.Status -ceq 'Verified' -and $receipt9.CapacityCheck.Status -ceq 'Unknown' -and $receipt9.CapacityCheck.Warning) 'Capacity: when free space cannot be read the copy proceeds with a recorded Unknown warning.'
            # 只驗證不寫入：不做容量預檢
            $script:freeBytes=[long]0
            & $copyOp $media4 'VerifyExisting' | Out-Null
            & $check ((& $reload).IndependentCopy.Status -ceq 'Verified') 'Capacity: VerifyExisting writes no copy and must not be blocked by free space.'
            Write-Host 'PASS: unreadable free space warns and proceeds; VerifyExisting skips the capacity check.'
        }finally{
            $script:freeBytes=[long]1TB;$script:copyFault='';$script:fakeDriveType=''
            Set-Item -Path Function:\script:Assert-WsmCancellationBoundary -Value $origBoundary
            Set-Item -Path Function:\script:Get-WsmAvailableBytes -Value $origAvailable
            if($origDriveSeam){Set-Item -Path Function:\script:Get-WsmDriveTypeName -Value $origDriveSeam}else{Remove-Item -Path Function:\script:Get-WsmDriveTypeName -ErrorAction SilentlyContinue}
            if([IO.Directory]::Exists($junction)){cmd.exe /c ('rmdir "'+$junction+'"') | Out-Null}
            if([IO.Directory]::Exists($realMedia)){Remove-Item -LiteralPath $realMedia -Recurse -Force}
        }
    } $root
}
finally{
    $full=[IO.Path]::GetFullPath($root);$driveRoot=[IO.Path]::GetPathRoot($full)
    if($full -ieq $driveRoot -or [IO.Path]::GetDirectoryName($full) -ine $driveRoot -or [IO.Path]::GetFileName($full) -notlike 'wsmic-*'){throw 'Unsafe cleanup path.'}
    if([IO.Directory]::Exists((Join-Path $full 'junc-to-workspace'))){cmd.exe /c ('rmdir "'+(Join-Path $full 'junc-to-workspace')+'"') | Out-Null}
    Remove-Item -LiteralPath $full -Recurse -Force
    cmd.exe /c ('subst '+$driveLetter+': /D')
}
Write-Host 'PASS: independent copy hardening (R6, R7, capacity).'
