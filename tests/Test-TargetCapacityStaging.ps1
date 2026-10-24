#requires -Version 5.1
# Q3：新機容量預檢計入 staging／必要回復空間（依各自所在磁碟加總）、ZIP 匯入解壓前預檢，
# 以及「空間不足或交付中斷不破壞先前有效備份」（獨立副本與 Directory 交付）。
# 另含體檢 B6（R26-B6）：已還原項目不計入同卷加總，單項過大只擋該項，合計不夠才同卷全標並附合計。
#
# 容量只替身化「磁碟可用空間」(Get-WsmAvailableBytes) 與 staging 所在磁碟的觀測縫 (Get-WsmAssistiveStagingLocation)；
# 其餘（封裝、artifacts.jsonl、預覽、Target 選項、匯入、交付、獨立副本）都是正式程式。
# 故障注入：以 Assert-WsmCancellationBoundary 的替身在指定邊界丟出 IOException（There is not enough space on the disk.）。
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$freeLetters=@('R','S','T','U','V','W','X','Y','Z' | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) })
if($freeLetters.Count -lt 3){throw 'Three free temporary drive letters are required (short-path root, workspace volume, staging volume).'}
$driveLetter=$freeLetters[0];$wsLetter=$freeLetters[1];$stageLetter=$freeLetters[2]
$realRoot=Join-Path $tempBase ('wsmq3-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($realRoot)
$wsReal=Join-Path $realRoot 'workspace-volume';[void][IO.Directory]::CreateDirectory($wsReal)
cmd.exe /c ('subst '+$driveLetter+': "'+$realRoot.TrimEnd('\')+'"')
if($LASTEXITCODE -ne 0){throw 'Unable to create the temporary short-path drive alias.'}
cmd.exe /c ('subst '+$wsLetter+': "'+$wsReal.TrimEnd('\')+'"')
if($LASTEXITCODE -ne 0){cmd.exe /c ('subst '+$driveLetter+': /d');throw 'Unable to create the temporary workspace drive alias.'}
$root=Join-Path ($driveLetter+':\') 'q3'
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$WsLetter,$StageLetter)
        $script:checks=0
        function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
        function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
        $script:saved=@{}
        function Save-Fn([string]$Name){if(-not $script:saved.ContainsKey($Name)){$command=Get-Command $Name -CommandType Function -ErrorAction SilentlyContinue;$script:saved[$Name]=$(if($command){$command.ScriptBlock}else{$null})}}
        function Restore-One([string]$Name){if($script:saved.ContainsKey($Name)){if($script:saved[$Name]){Set-Item -Path ('Function:\script:'+$Name) -Value $script:saved[$Name]}else{Remove-Item -Path ('Function:\script:'+$Name) -ErrorAction SilentlyContinue};$script:saved.Remove($Name)}}
        function Restore-Fns{foreach($name in @($script:saved.Keys)){if($script:saved[$name]){Set-Item -Path ('Function:\script:'+$name) -Value $script:saved[$name]}else{Remove-Item -Path ('Function:\script:'+$name) -ErrorAction SilentlyContinue}};$script:saved=@{}}
        function TreeMap([string]$Path){
            if(-not [IO.Directory]::Exists($Path)){return '<absent>'}
            (@(Get-ChildItem -LiteralPath $Path -Recurse -Force|Sort-Object FullName|ForEach-Object {
                $relative=$_.FullName.Substring($Path.TrimEnd('\').Length)
                if($_.PSIsContainer){$relative+'|D'}else{$relative+'|F|'+$_.Length+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
            }) -join "`n")
        }
        function FileHashOf([string]$Path){if([IO.File]::Exists($Path)){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}else{'<absent>'}}

        # ================================================================================================
        # A. 容量判定：預覽（Get-WsmAssistiveRestorePreview）與 Target 選項（Get-WsmWizardTargetItemOptions）共用同一套判定
        # ================================================================================================
        foreach($name in @('Test-WsmMigrationPackage','Assert-WsmMigrationHost','Get-WsmAssistiveRestoreDecision','Get-WsmOperationPaths','Get-WsmOperationState','Get-WsmAssistiveNonCResultRows','Get-WsmAvailableBytes','Get-WsmAssistiveStagingLocation')){Save-Fn $name}
        $script:previewPackage=$null;$script:previewDecision=$null;$script:previewState=[pscustomobject]@{Items=@()}
        function script:Test-WsmMigrationPackage($ManifestPath,$ExpectedHash,$CancellationToken){$script:previewPackage}
        function script:Assert-WsmMigrationHost($Identity,$Fingerprint){ }
        function script:Get-WsmAssistiveRestoreDecision($Package,$ExpectedHash,$ReceiptPath,$ReceiptHash,$SnapshotPath){$script:previewDecision}
        function script:Get-WsmOperationPaths($StateDirectory,$PairId){[pscustomobject]@{Root=$StateDirectory;State=$null;Journal=$null}}
        function script:Get-WsmOperationState($Paths,$Package){$script:previewState}
        function script:Get-WsmAssistiveNonCResultRows($Package,$TransferPlanPath,$TransferPlanHash,$ResultPath,$ResultHash,$StateDirectory){@{}}
        $script:freeBytes=@{};$script:probeCount=0
        function script:Get-WsmAvailableBytes([string]$Path){$script:probeCount++;$key=([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))).ToUpperInvariant();if($script:freeBytes.ContainsKey($key)){[long]$script:freeBytes[$key]}else{[long]([long]1TB)}}
        # staging 觀測縫：正式行為是 staging 檔與目的檔同目錄（同卷）；測試只在路徑含 staged-elsewhere 時把它指到另一個磁碟。
        $script:nativeStagingLocation=$null;$cmd=Get-Command Get-WsmAssistiveStagingLocation -CommandType Function -ErrorAction SilentlyContinue;if($cmd){$script:nativeStagingLocation=$cmd.ScriptBlock}
        $stageKey=($StageLetter+':\').ToUpperInvariant()
        function script:Get-WsmAssistiveStagingLocation([string]$TargetPath){
            if($TargetPath -like '*staged-elsewhere*'){return [pscustomobject]@{Root=($script:stageRootText);Key=($script:stageRootText).ToUpperInvariant()}}
            & $script:nativeStagingLocation $TargetPath
        }
        $script:stageRootText=$StageLetter+':\'

        $script:packageCounter=0
        function NewScopeItem([string]$Id,[string]$Target){
            [pscustomobject]@{ItemId=$Id;Name=('item '+$Id);Kind='K';Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C';SourcePath=$Target;TargetPath=$Target;Metadata='DaclOwner';ContentSelection='WholeScope';ConfigFiles=@();ExcludedRelativePaths=@()}}
        }
        function NewPackage([object[]]$Items,[hashtable]$Payload,[string]$PackageBase=''){
            $script:packageCounter++;$packageRoot=Join-Path $(if($PackageBase){$PackageBase}else{$Root}) ('pkg-'+$script:packageCounter);[void][IO.Directory]::CreateDirectory($packageRoot)
            $meta=[ordered]@{MetadataMode='DaclOwner';Sddl='';Attributes=0;CreationUtc='2026-10-10T00:00:00.0000000Z';LastWriteUtc='2026-10-10T00:00:00.0000000Z'}
            $lines=New-Object 'System.Collections.Generic.List[string]'
            foreach($item in $Items){
                if(-not $Payload.ContainsKey([string]$item.ItemId)){continue}
                $lines.Add((ConvertTo-Json -InputObject ([ordered]@{ItemId=$item.ItemId;RelativePath='';Directory=$true;Metadata=$meta;Data=$null}) -Depth 10 -Compress))
                $fileNumber=0
                foreach($bytes in @($Payload[[string]$item.ItemId])){$fileNumber++;$lines.Add((ConvertTo-Json -InputObject ([ordered]@{ItemId=$item.ItemId;RelativePath=('file'+$fileNumber+'.bin');Directory=$false;Metadata=$meta;Data=[ordered]@{Hash=('a'*64);Bytes=[long]$bytes;Chunks=@()}}) -Depth 10 -Compress))}
            }
            $indexPath=Join-Path $packageRoot 'artifacts.jsonl';[IO.File]::WriteAllText($indexPath,((@($lines.ToArray()) -join "`n")+"`n"),(New-Object Text.UTF8Encoding($false)))
            $indexHash=(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $plan=[pscustomobject]@{Items=@($Items);Assistive=[pscustomobject]@{ContractVersion=1;SourcePolicy='ApprovedLocalVolumes'}}
            $script:previewPackage=[pscustomobject]@{Root=$packageRoot;Plan=$plan;Manifest=[pscustomobject]@{PairId='pair-fixture';PlanHash=('3'*64);Generation=1;Target=[pscustomobject]@{Fingerprint=('b'*64)};ArtifactsHash=$indexHash}}
            $script:previewDecision=[pscustomobject]@{SelectedItemIds=@($Items|ForEach-Object {[string]$_.ItemId});Receipt=[pscustomobject]@{Decision='RestoreNow';AcceptedUnpreparedItemIds=@()};ReceiptHash=('4'*64);Snapshot=[pscustomobject]@{}}
            [pscustomobject]@{ManifestHash=('2'*64);Package=$script:previewPackage;Context=[pscustomobject]@{Plan=$plan}}
        }
        function InvokePreview {Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $Root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture'}
        # 預覽與 Target 選項必須對同一情境給同一結論：Expect＝ItemId -> 期望代碼（空字串＝可還原）。
        function AssertCapacity([string]$Label,$Fixture,[hashtable]$Expect){
            $options=@(Get-WsmWizardTargetItemOptions $Fixture.Context $Fixture $script:previewState);$preview=InvokePreview
            $optionById=@{};foreach($option in $options){$optionById[[string]$option.value]=$option}
            foreach($id in $Expect.Keys){
                Check $optionById.ContainsKey($id) ($Label+': option for '+$id+' is missing.')
                $option=$optionById[$id];$row=@($preview.Rows|Where-Object ItemId -CEQ $id)
                Check ($row.Count -eq 1) ($Label+': preview row for '+$id+' is missing or duplicated.')
                if([string]$Expect[$id] -ceq ''){
                    Check ($option.restorable -eq $true -and [string]$row[0].Status -ceq 'Ready') ($Label+': '+$id+' must be Ready/restorable (option='+$option.restorableCode+', preview='+$row[0].Action+'/'+$row[0].Status+').')
                }else{
                    Check ($option.restorable -eq $false -and [string]$option.restorableCode -ceq [string]$Expect[$id] -and [string]$row[0].Action -ceq 'AddTargetCapacity' -and [string]$row[0].Status -ceq 'Deferred') ($Label+': '+$id+' must be Deferred/AddTargetCapacity in both (option='+$option.restorableCode+', preview='+$row[0].Action+'/'+$row[0].Status+').')
                }
            }
            [pscustomobject]@{Preview=$preview;Options=$optionById}
        }
        function PreviewRow($Result,[string]$Id){@($Result.Preview.Rows|Where-Object ItemId -CEQ $Id)[0]}

        $targets=Join-Path $Root 'targets';[void][IO.Directory]::CreateDirectory($targets)
        $cKey=([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($targets))).ToUpperInvariant()
        $wsKey=($WsLetter+':\').ToUpperInvariant()

        # ---- 基準：全部足夠 -> Ready
        $script:freeBytes=@{};$script:freeBytes[$cKey]=[long](2GB)
        $okA=NewScopeItem 'ok-a' (Join-Path $targets 'ok-a');$okB=NewScopeItem 'ok-b' (Join-Path $targets 'ok-b')
        $fixture=NewPackage @($okA,$okB) @{'ok-a'=@(100MB);'ok-b'=@(100MB)}
        [void](AssertCapacity 'baseline' $fixture @{'ok-a'='';'ok-b'=''})
        Write-Host 'PASS: baseline, every volume has enough room for write, staging and recovery -> Ready.'

        # ---- B6（R26-B6）：已還原項目不得讓其他項目被誤判為容量不足
        $doneDir=Join-Path $targets 'done';[void][IO.Directory]::CreateDirectory($doneDir);$doneFile=Join-Path $doneDir 'file1.bin';[IO.File]::WriteAllText($doneFile,'already restored payload')
        $doneHash=(Get-FileHash -LiteralPath $doneFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $doneState=[pscustomobject]@{ItemId='done';Status='Succeeded';CreatedByTool=$true;AppliedManifestHash=('2'*64);AppliedGeneration=1;OwnedFiles=@([pscustomobject]@{RelativePath='file1.bin';TargetPath=$doneFile;SHA256=$doneHash;MetadataHash=('c'*64);Generation=1});OwnedDirectories=@()}
        $done=NewScopeItem 'done' $doneDir;$todo=NewScopeItem 'todo-1' (Join-Path $targets 'todo-1')
        $fixture=NewPackage @($done,$todo) @{'done'=@(300MB);'todo-1'=@(300MB)}
        $script:previewState=[pscustomobject]@{Items=@($doneState)}
        $script:freeBytes=@{};$script:freeBytes[$cKey]=[long](700MB)
        $b6=AssertCapacity 'B6 restored item excluded from the sum' $fixture @{'done'='';'todo-1'=''}
        Check ((PreviewRow $b6 'done').Action -ceq 'MergeIntoExistingDirectory' -and (PreviewRow $b6 'todo-1').Action -ceq 'RestoreNow') 'B6: the restored item must keep its own (non-capacity) action while the pending item stays RestoreNow.'
        Write-Host 'PASS: B6, an already restored item no longer makes the pending item look short of capacity.'

        # 單看一項就超過可用空間：只該項 Deferred；其餘各項（已還原者除外）改看合計。
        $script:previewState=[pscustomobject]@{Items=@()}
        $solo=NewScopeItem 'solo-big' (Join-Path $targets 'solo-big');$small=NewScopeItem 'solo-small' (Join-Path $targets 'solo-small')
        $fixture=NewPackage @($solo,$small) @{'solo-big'=@(900MB);'solo-small'=@(10MB)}
        $script:freeBytes=@{};$script:freeBytes[$cKey]=[long](500MB)
        $soloResult=AssertCapacity 'B6 single oversized item' $fixture @{'solo-big'='InsufficientCapacity';'solo-small'=''}
        $soloReason=[string](PreviewRow $soloResult 'solo-big').Reason
        Check ($soloReason.Contains('單獨') -and $soloReason.Contains('900 MiB') -and $soloReason.Contains($cKey)) ('B6: the oversized item reason must say it is short on its own and name the amount and disk: '+$soloReason)
        Write-Host 'PASS: B6, one item that alone exceeds the free space is Deferred by itself; the small item stays Ready.'

        # 各項都夠、合計不夠：同卷待寫項目全標 AddTargetCapacity，原因附合計；已還原項目不計入也不被標。
        $todoA=NewScopeItem 'agg-a' (Join-Path $targets 'agg-a');$todoB=NewScopeItem 'agg-b' (Join-Path $targets 'agg-b')
        $fixture=NewPackage @($done,$todoA,$todoB) @{'done'=@(300MB);'agg-a'=@(300MB);'agg-b'=@(300MB)}
        $script:previewState=[pscustomobject]@{Items=@($doneState)}
        $script:freeBytes=@{};$script:freeBytes[$cKey]=[long](700MB);$script:probeCount=0
        $aggResult=AssertCapacity 'B6 aggregate over pending only' $fixture @{'done'='';'agg-a'='InsufficientCapacity';'agg-b'='InsufficientCapacity'}
        $aggReason=[string](PreviewRow $aggResult 'agg-a').Reason
        Check ($aggReason.Contains('合計約 600 MiB') -and $aggReason.Contains('已還原') -and $aggReason.Contains('不計入')) ('B6: the aggregate reason must show the pending total and say restored items are not counted: '+$aggReason)
        Write-Host 'PASS: B6, each pending item fits alone but not together -> every pending item on the disk is Deferred with the total; restored item untouched.'

        # ---- 計算：只有寫入時足夠，加上回復保留後不足（回復保留與寫入同磁碟）
        $script:previewState=[pscustomobject]@{Items=@()}
        $rc=NewScopeItem 'rc-1' (Join-Path $targets 'rc-1')
        $fixture=NewPackage @($rc) @{'rc-1'=@(100MB,100MB)}
        $script:freeBytes=@{};$script:freeBytes[$cKey]=[long](200MB+256MB)
        $rcResult=AssertCapacity 'recovery reserve pushes a write-only-enough disk over' $fixture @{'rc-1'='InsufficientCapacity'}
        $rcReason=[string](PreviewRow $rcResult 'rc-1').Reason
        Check ($rcReason.Contains('回復保留') -and $rcReason.Contains('寫入') -and $rcReason.Contains('staging')) ('Recovery shortage reason must list what was counted (write, staging, recovery): '+$rcReason)
        Check ([string]$rcResult.Options['rc-1'].restorableReason -match '回復保留') 'The Target option reason must also list the recovery reserve.'
        $script:freeBytes[$cKey]=[long](200MB+256MB+1MB)
        [void](AssertCapacity 'recovery reserve fits' $fixture @{'rc-1'=''})
        Write-Host 'PASS: write alone fits but write plus recovery reserve does not -> Deferred with the counted items; one more MiB -> Ready.'

        # ---- 計算：staging 與目的地在不同磁碟時分別計算
        $st=NewScopeItem 'st-1' (Join-Path $targets 'staged-elsewhere\a');$plain=NewScopeItem 'plain' (Join-Path $targets 'plain')
        $fixture=NewPackage @($st,$plain) @{'st-1'=@(300MB);'plain'=@(10MB)}
        $script:freeBytes=@{};$script:freeBytes[$cKey]=[long](600MB);$script:freeBytes[$stageKey]=[long](100MB)
        $stResult=AssertCapacity 'staging on another disk is counted on that disk' $fixture @{'st-1'='InsufficientCapacity';'plain'=''}
        $stReason=[string](PreviewRow $stResult 'st-1').Reason
        Check ($stReason.Contains('staging') -and $stReason.Contains($stageKey)) ('Staging shortage reason must name the staging disk and the staging item: '+$stReason)
        Check (-not $stReason.Contains($cKey+' 可用') ) 'The destination disk had enough room and must not be reported as the short disk.'
        $script:freeBytes[$stageKey]=[long](10GB)
        [void](AssertCapacity 'staging disk has enough room' $fixture @{'st-1'='';'plain'=''})
        $script:freeBytes[$stageKey]=[long](100MB);$script:freeBytes[$cKey]=[long](100MB)
        $bothResult=AssertCapacity 'each disk is checked separately' $fixture @{'st-1'='InsufficientCapacity';'plain'='InsufficientCapacity'}
        Write-Host 'PASS: staging on a different disk is checked against that disk only; the destination disk is checked separately.'

        # ---- 計算：回復保留（journal／狀態）落在 workspace 所在磁碟時，計入那個磁碟
        $wsRoot=$WsLetter+':\ws'
        $wr=NewScopeItem 'ws-1' (Join-Path $targets 'ws-1')
        $fixture=NewPackage @($wr) @{'ws-1'=@(10MB,10MB,10MB)} $wsRoot
        $script:freeBytes=@{};$script:freeBytes[$wsKey]=[long](100MB)
        $wsResult=AssertCapacity 'recovery reserve on the workspace disk' $fixture @{'ws-1'='InsufficientCapacity'}
        $wsReason=[string](PreviewRow $wsResult 'ws-1').Reason
        Check ($wsReason.Contains($wsKey) -and $wsReason.Contains('回復保留')) ('The workspace disk shortage must name the workspace disk and the recovery reserve: '+$wsReason)
        $script:freeBytes[$wsKey]=[long](1GB)
        [void](AssertCapacity 'workspace disk has enough room' $fixture @{'ws-1'=''})
        Write-Host 'PASS: recovery reserve on the workspace disk is counted on that disk.'
        $script:freeBytes=@{};$script:previewState=[pscustomobject]@{Items=@()}
        Restore-Fns

        # ================================================================================================
        # B. 真實封裝：ZIP 匯入解壓前容量預檢、Directory 匯入預檢，以及先前有效備份不被破壞
        # ================================================================================================
        $script:backupFixtureFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:backupFixtureFingerprint;Name='q3-fixture';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:fixtureInventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery);[pscustomobject]@{Path=$script:fixtureInventoryPath;SHA256=(Get-FileHash -LiteralPath $script:fixtureInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        $sourceRoot=Join-Path $Root 'source-work';$targetRoot=Join-Path $Root 'target-work';$managerRoot=Join-Path $Root 'manager-work'
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:backupFixtureFingerprint=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=(Get-FileHash -LiteralPath $targetIdentityPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:backupFixtureFingerprint=('a'*64)
        $source=[pscustomobject]@{HostId=$sourceEnrollment.HostId;Fingerprint=('a'*64);Name='fixture-source'}
        $sourceData=Join-Path $Root 'source-data';[void][IO.Directory]::CreateDirectory($sourceData)
        [IO.File]::WriteAllText((Join-Path $sourceData 'settings.ini'),'actual source bytes');[IO.File]::WriteAllText((Join-Path $sourceData 'second.txt'),'second source bytes')
        $item=New-WsmItem $source.HostId Storage DataRoot 'Fixture settings folder' 'fixture-settings' @{Path=$sourceData}
        $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory;$script:fixtureInventoryPath=$inventoryPath
        Initialize-WsmWorkspace $managerRoot|Out-Null
        $catalog=Import-WsmInventory $managerRoot $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target'
        $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceData;TargetPath=(Join-Path $Root 'restored');TransferChannel='C';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='AllowAutoInheritedUpgrade';ConflictPolicy='ReplaceOwned';Owner='Fixture owner';Evidence='Isolated actual bytes test';BusinessChecks=@('Read back each source file')}
        $specPath=Join-Path $Root 'spec.json';Write-WsmJson $specPath $spec
        Set-WsmMigrationSpec $managerRoot $catalog.PairId $item.ItemId $specPath (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash 0
        Set-WsmDecision $managerRoot $catalog.PairId @($item.ItemId) Include 'Explicit fixture selection' 1|Out-Null
        $planPath=Join-Path $Root 'approved-plan.json';$approved=Approve-WsmMigrationPlan $managerRoot $catalog.PairId $targetIdentityPath $targetIdentityHash $planPath 2 'ISOLATED-PILOT'
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $planPath $approved.SHA256
        Check ($import.Status -ceq 'ImportedVerified') 'Fixture: the Source did not import the approved plan.'
        $pair=[string]$catalog.PairId
        function RunBackup([string]$Mode,[long]$VolumeBytes){
            $operationId=[Guid]::NewGuid().ToString('D');$token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $pair -PlanHash $approved.SHA256 -OperationId $operationId
            $result=Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pair -OperationId $operationId -DeliveryMode $Mode -VolumeBytes $VolumeBytes -Jobs @() -CancellationToken $token
            Check ($result.Status -ceq 'Delivered' -and $result.DeliveryMode -ceq $Mode) ('Fixture: the '+$Mode+' backup attempt was not delivered.')
            [pscustomobject]@{OperationId=$operationId;Result=$result}
        }
        $backupA=RunBackup 'Directory' 0
        $backupB=RunBackup 'Zip' 134217728
        Write-Host 'PASS: fixture, two real delivered backup attempts (Directory and ZIP).'

        # ---- ZIP 匯入：解壓前先檢查 workspace 磁碟能否容納解壓後的封裝；不足就拒絕且不留任何半套檔案
        $zipTransport=Read-WsmTrustedJson $backupB.Result.Delivery.Path $backupB.Result.Delivery.SHA256
        $zipTotal=[long]0;foreach($entry in @($zipTransport.Entries)){$zipTotal+=[long]$entry.Bytes}
        $script:backupFixtureFingerprint=('b'*64)
        $script:zipOutputText='';$script:zipFree=[long]1TB
        Save-Fn 'Get-WsmAvailableBytes'
        function script:Get-WsmAvailableBytes([string]$Path){$full=[IO.Path]::GetFullPath($Path);if($script:zipOutputText -and $full.StartsWith($script:zipOutputText,[StringComparison]::OrdinalIgnoreCase)){return [long]$script:zipFree};[long]1TB}
        $zipShort=Join-Path $Root 'zip-short';$script:zipOutputText=[IO.Path]::GetFullPath($zipShort);$script:zipFree=[long]($zipTotal+256MB-1)
        $zipRejected='';try{Import-WsmPackageZip -TransportPath $backupB.Result.Delivery.Path -ExpectedHash $backupB.Result.Delivery.SHA256 -OutputDirectory $zipShort|Out-Null}catch{$zipRejected=$_.Exception.Message}
        Check ($zipRejected -like '*Insufficient unpack workspace capacity*') ('ZIP import with one byte less than (unpacked size + 256 MiB) was not rejected for capacity: '+$zipRejected)
        $leftovers=@();if([IO.Directory]::Exists($zipShort)){$leftovers=@(Get-ChildItem -LiteralPath $zipShort -Recurse -Force|Where-Object {$_.Name -like 'incoming-*' -or $_.Name -like '*.partial' -or $_.Name -like '*.blob' -or $_.Name -in @('manifest.json','plan.json','artifacts.jsonl','import-complete.json','transport-state.json')})}
        Check ($leftovers.Count -eq 0) ('A rejected ZIP import left half-unpacked files: '+(($leftovers|ForEach-Object FullName) -join '; '))
        $script:zipFree=[long]($zipTotal+256MB)
        $zipImported=Import-WsmPackageZip -TransportPath $backupB.Result.Delivery.Path -ExpectedHash $backupB.Result.Delivery.SHA256 -OutputDirectory $zipShort
        Check ($zipImported.Valid -and (Test-WsmMigrationPackage $zipImported.ManifestPath $zipImported.SHA256).Valid) 'ZIP import with exactly (unpacked size + 256 MiB) free did not succeed.'
        Write-Host 'PASS: ZIP import checks the unpack workspace before extracting; a short disk is refused with no half-set left behind.'

        # ---- Directory 匯入：新機 staging 預檢（staging 與 incoming 都在 WorkRoot 磁碟）
        $script:backupFixtureFingerprint=('b'*64)
        $script:zipOutputText=[IO.Path]::GetFullPath($targetRoot);$script:zipFree=[long]0
        $dirRejected='';try{Import-WsmDirectoryDelivery -SummaryPath $backupA.Result.Delivery.Path -ExpectedSummaryHash $backupA.Result.Delivery.SHA256 -SourceDirectory ([string]$backupA.Result.Delivery.Directory) -WorkRoot $targetRoot|Out-Null}catch{$dirRejected=$_.Exception.Message}
        Check ($dirRejected -like '*Insufficient target volume space*') ('Directory import into a full WorkRoot disk was not rejected before staging: '+$dirRejected)
        $dirLeft=@(Get-ChildItem -LiteralPath $targetRoot -Recurse -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -like '*.partial' -or $_.FullName -like '*\packages\*'})
        Check ($dirLeft.Count -eq 0) ('A rejected Directory import left a staging or incoming tree: '+(($dirLeft|ForEach-Object FullName) -join '; '))
        $script:zipOutputText='';Restore-One 'Get-WsmAvailableBytes'
        $script:backupFixtureFingerprint=('a'*64)
        Write-Host 'PASS: Directory import checks the target WorkRoot disk before creating its staging directory.'

        # ---- 共用：故障注入。以 Assert-WsmCancellationBoundary 的替身在第 N 次指定邊界丟出 IOException（disk full）。
        Save-Fn 'Assert-WsmCancellationBoundary'
        $script:nativeBoundary=(Get-Command Assert-WsmCancellationBoundary -CommandType Function).ScriptBlock;$script:fault=$null
        function script:Assert-WsmCancellationBoundary($Token,[string]$Name){
            if($script:fault -and $script:fault.Name -ceq $Name){$script:fault.Seen++;if($script:fault.Seen -ge $script:fault.At){$script:fault.Fired++;throw (New-Object IO.IOException 'There is not enough space on the disk.')}}
            & $script:nativeBoundary $Token $Name
        }
        function SetFault([string]$Name,[int]$At){$script:fault=[pscustomobject]@{Name=$Name;At=$At;Seen=0;Fired=0}}
        function ClearFault{$script:fault=$null}

        # ---- Directory 交付：先前有效交付逐位元組不變
        $deliveries=Join-Path $Root 'deliveries';[void][IO.Directory]::CreateDirectory($deliveries)
        $packageA=$backupA.Result.CoreExport;$packageB=$backupB.Result.CoreExport
        $d1=Join-Path $deliveries 'd1';$delivery1=Export-WsmDirectoryDelivery $packageA.ManifestPath $packageA.SHA256 $d1
        Check ($delivery1.Valid -and (Test-WsmMigrationPackage (Join-Path $d1 'manifest.json') $packageA.SHA256).Valid) 'Fixture: the first (previous) directory delivery is not valid.'
        $before=TreeMap $deliveries;$d1Before=TreeMap $d1;$summary1Hash=FileHashOf $delivery1.SummaryPath
        $d2=Join-Path $deliveries 'd2'
        # (a) 空間預檢不足：在建立任何東西之前拒絕
        Save-Fn 'Get-WsmAvailableBytes'
        function script:Get-WsmAvailableBytes([string]$Path){[long]0}
        $precheck='';try{Export-WsmDirectoryDelivery $packageB.ManifestPath $packageB.SHA256 $d2|Out-Null}catch{$precheck=$_.Exception.Message}
        Restore-One 'Get-WsmAvailableBytes'
        Check ($precheck -like '*Insufficient free space*') ('Directory delivery with a full disk was not refused by the capacity precheck: '+$precheck)
        Check ((TreeMap $deliveries) -ceq $before) 'A capacity-refused directory delivery changed the delivery area (previous delivery, summaries or leftover temp).'
        # (b) 中途 IOException（disk full）：第二個成員複製到一半
        SetFault 'DirectoryCopyBuffer' 2
        $midFailure='';try{Export-WsmDirectoryDelivery $packageB.ManifestPath $packageB.SHA256 $d2|Out-Null}catch{$midFailure=$_.Exception.Message}
        Check ($script:fault.Fired -ge 1 -and $midFailure -like '*not enough space*') ('The injected disk-full IOException did not interrupt the directory delivery: '+$midFailure)
        ClearFault
        Check ((TreeMap $deliveries) -ceq $before) 'An interrupted directory delivery changed the previous delivery, left its .d-* temp directory or left a delivery summary.'
        Check ((TreeMap $d1) -ceq $d1Before -and (FileHashOf $delivery1.SummaryPath) -ceq $summary1Hash) 'The previous directory delivery is not byte-identical after a failed second delivery.'
        Check (-not [IO.Directory]::Exists($d2) -and @(Get-ChildItem -LiteralPath $deliveries -Force|Where-Object {$_.Name -like '.d-*'}).Count -eq 0) 'The failed delivery left its destination or an unfinished .d-* directory.'
        $previousStillValid=Test-WsmMigrationPackage (Join-Path $d1 'manifest.json') $packageA.SHA256
        Check ($previousStillValid.Valid -and @(Get-WsmDirectoryDeliveryFileIndex $d1).Count -eq [int]$delivery1.Members) 'The previous directory delivery no longer passes package validation.'
        # (c) 重試：新世代乾淨成功，且沒有混入舊世代
        $delivery2=Export-WsmDirectoryDelivery $packageB.ManifestPath $packageB.SHA256 $d2
        $trustedB=@(Get-WsmPackageMembers (Test-WsmMigrationPackage $packageB.ManifestPath $packageB.SHA256))
        $deliveredNames=@(Get-WsmDirectoryDeliveryFileIndex $d2|ForEach-Object Name|Sort-Object -CaseSensitive)
        Check ($delivery2.Valid -and (($deliveredNames -join '|') -ceq ((@($trustedB|ForEach-Object Name)|Sort-Object -CaseSensitive) -join '|'))) 'The retried delivery does not hold exactly the new generation package members.'
        Check ((FileHashOf (Join-Path $d2 'manifest.json')) -ine (FileHashOf (Join-Path $d1 'manifest.json')) -and (TreeMap $d1) -ceq $d1Before) 'The retried delivery mixed generations or touched the previous delivery.'
        Write-Host 'PASS: Directory delivery, capacity refusal and a mid-copy disk-full leave the previous delivery byte-identical and no temp/summary behind; retry is clean.'

        # ---- 獨立副本：先前有效副本逐位元組不變
        Save-Fn 'Get-WsmIndependentCopyMediaClass'
        function script:Get-WsmIndependentCopyMediaClass {param($DestinationRoot)'Removable'}
        $copyDest=Join-Path $Root 'copy-dest';[void][IO.Directory]::CreateDirectory($copyDest)
        $copyA=Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pair -BackupOperationId $backupA.OperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $copyDest -Mode Copy
        Check ($copyA.IndependentCopy.Status -ceq 'Verified') 'Fixture: the first independent copy was not verified.'
        $copyRootA=[string]$copyA.IndependentCopy.CopyRoot;$copyABefore=TreeMap $copyRootA
        $copyRootB=Join-Path $copyDest ('wsm-offline-'+$pair+'-'+[string]$backupB.Result.AttemptId)
        # (a) 第二份副本在第 2 個檔案前遇到 disk full
        SetFault 'IndependentCopyFile' 2
        $copyFailure='';try{Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pair -BackupOperationId $backupB.OperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $copyDest -Mode Copy|Out-Null}catch{$copyFailure=$_.Exception.Message}
        Check ($script:fault.Fired -ge 1 -and $copyFailure -like '*not enough space*') ('The injected disk-full IOException did not interrupt the independent copy: '+$copyFailure)
        ClearFault
        Check ((TreeMap $copyRootA) -ceq $copyABefore) 'The previous valid independent copy changed after a failed second copy.'
        Check (@(Get-ChildItem -LiteralPath $copyDest -Recurse -Force|Where-Object Name -like '*.partial').Count -eq 0) 'A .partial file was left behind after the interrupted copy.'
        $copyBPaths=@();if([IO.Directory]::Exists($copyRootB)){$copyBPaths=@(Get-ChildItem -LiteralPath $copyRootB -Recurse -File -Force)}
        Check (@($copyBPaths|Where-Object {-not $_.FullName.StartsWith($copyRootB+'\',[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0 -and @(Get-ChildItem -LiteralPath $copyRootA -Recurse -File -Force|Where-Object {$_.FullName.StartsWith($copyRootB,[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0) 'Files of the new generation were mixed into the previous copy.'
        $attemptB=(Get-WsmWizardBackupAttemptForOperation $sourceRoot $pair (Read-WsmOutputProfile $sourceRoot) $backupB.OperationId).Attempt
        Check ([string]$attemptB.IndependentCopy.Status -ceq 'Failed') 'The failed second copy was not recorded as Failed on its own attempt.'
        $reverify=Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pair -BackupOperationId $backupA.OperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $copyDest -Mode VerifyExisting
        Check ($reverify.IndependentCopy.Status -ceq 'Verified' -and (TreeMap $copyRootA) -ceq $copyABefore) 'The previous independent copy no longer passes verification after the failed second copy.'
        # (b) 第二份副本在搬移檔案時失敗（目的路徑被目錄佔用）：.partial 必須清掉，先前副本不動
        $blockedPath=Join-Path $copyRootB ('transport\'+[string]$zipTransport.Volumes[0].Name);[void][IO.Directory]::CreateDirectory($blockedPath)
        $blockFailure='';try{Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pair -BackupOperationId $backupB.OperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $copyDest -Mode Copy|Out-Null}catch{$blockFailure=$_.Exception.Message}
        Check ($blockFailure) 'Blocking the destination path did not make the second copy fail.'
        Check (@(Get-ChildItem -LiteralPath $copyDest -Recurse -Force|Where-Object Name -like '*.partial').Count -eq 0) 'The .partial file of the failed move was not cleaned.'
        Check ((TreeMap $copyRootA) -ceq $copyABefore) 'The previous valid independent copy changed after a failed move in the second copy.'
        Remove-Item -LiteralPath $blockedPath -Recurse -Force
        # (c) 重試：新世代成功，先前副本仍不變
        $copyB=Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pair -BackupOperationId $backupB.OperationId -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $copyDest -Mode Copy
        Check ($copyB.IndependentCopy.Status -ceq 'Verified' -and (TreeMap $copyRootA) -ceq $copyABefore) 'The retried second copy did not verify, or it touched the previous copy.'
        $zipNames=@(Get-ChildItem -LiteralPath $copyRootB -Recurse -File|Where-Object {$_.Name -like 'package-*.zip' -or $_.Name -eq 'transport.json'}|ForEach-Object Name)
        Check (@(Get-ChildItem -LiteralPath $copyRootA -Recurse -File|Where-Object {$_.Name -like 'package-*.zip'}).Count -eq 0 -and $zipNames.Count -ge 2) 'The generations were mixed: ZIP volumes of the new generation are not exactly in its own copy root.'
        Restore-One 'Get-WsmIndependentCopyMediaClass';Restore-One 'Assert-WsmCancellationBoundary'
        Write-Host 'PASS: independent copy, a mid-copy disk-full and a failed move leave the previous valid copy byte-identical and verifiable; .partial is cleaned; retry is clean.'
        Write-Host ('PASS: Test-TargetCapacityStaging ('+$script:checks+' checks).')
    } $root $wsLetter $stageLetter
}finally{
    # 先經短路徑別名刪除（深層封裝路徑超過 MAX_PATH，從真實路徑刪除會失敗），再移除別名。
    if([IO.Directory]::Exists($root)){try{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Temporary fixture was not fully removed: '+$root)}}
    foreach($letter in @($driveLetter,$wsLetter)){cmd.exe /c ('subst '+$letter+': /d') | Out-Null}
    if([IO.Directory]::Exists($realRoot)){try{Remove-Item -LiteralPath $realRoot -Recurse -Force -ErrorAction Stop}catch{Write-Warning ('Temporary fixture was not fully removed: '+$realRoot)}}
}
