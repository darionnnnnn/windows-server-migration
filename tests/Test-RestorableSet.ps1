#requires -Version 5.1
# N1：可還原集合 = 核准 ∩ 有可用 payload ∩ 目標可放置。
# 選項（Get-WsmWizardTargetItemOptions）與預覽（Get-WsmAssistiveRestorePreview）必須對同一狀況給出同一個 ItemId、同一個代碼；
# 選項端的檢查全程唯讀。封裝用真實的 artifacts.jsonl（含真實 SHA-256 索引雜湊），只替身化：封裝驗證入口、決策讀取、本機身分、磁碟可用量（容量不足）、
# 掛載點觀測（無法在 CI 建立真實卷掛載點）。缺卷用不存在的磁碟與 subst 出來的第二個磁碟。
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$assistivePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\AssistiveRestore.ps1'))
$runtimePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\WizardRuntime.ps1'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-n1-set-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
$idMarker=[IO.Path]::GetFileName($root)
try {
    & $module {
        param($Root,$AssistivePath,$RuntimePath)
        . $AssistivePath
        . $RuntimePath
        $script:checks=0
        function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
        function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}

        # ---- 替身：封裝驗證入口、決策、本機身分、狀態讀取（其餘判定全是核心程式）
        $script:previewPackage=$null;$script:previewDecision=$null;$script:previewState=[pscustomobject]@{Items=@()}
        function Test-WsmMigrationPackage($ManifestPath,$ExpectedHash,$CancellationToken){$script:previewPackage}
        function Assert-WsmMigrationHost($Identity,$Fingerprint){ }
        function Get-WsmAssistiveRestoreDecision($Package,$ExpectedHash,$ReceiptPath,$ReceiptHash,$SnapshotPath){$script:previewDecision}
        function Get-WsmOperationPaths($StateDirectory,$PairId){[pscustomobject]@{Root=$StateDirectory;State=$null;Journal=$null}}
        function Get-WsmOperationState($Paths,$Package){$script:previewState}
        function Get-WsmAssistiveNonCResultRows($Package,$TransferPlanPath,$TransferPlanHash,$ResultPath,$ResultHash,$StateDirectory){@{}}
        # 唯讀證明：選項端不得取鎖、寫 journal、寫 JSON。
        $script:sideEffects=0
        function Invoke-WsmLocked {$script:sideEffects++;throw 'Options must not take a write lock.'}
        function Add-WsmJournal {$script:sideEffects++;throw 'Options must not write a journal.'}
        function Write-WsmJson {$script:sideEffects++;throw 'Options must not write JSON.'}
        # 容量：預設不限制；個別情境設定各卷可用量。
        $script:freeBytes=@{}
        function Get-WsmAvailableBytes([string]$Path){$key=([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))).ToUpperInvariant();if($script:freeBytes.ContainsKey($key)){[long]$script:freeBytes[$key]}else{[long]([long]1TB)}}
        # 掛載點觀測：只有路徑含 'mounted-volume' 時視為位於掛載點底下。
        $script:nativeMountAncestor=(Get-Command Get-WsmAssistiveMountPointAncestor -CommandType Function).ScriptBlock
        function Get-WsmAssistiveMountPointAncestor([string]$Path){if($Path -like '*mounted-volume*'){return 'X:\mounted-volume'};& $script:nativeMountAncestor $Path}

        $script:packageCounter=0
        function NewScopeItem([string]$Id,[string]$Target,[string]$Source=''){
            [pscustomobject]@{ItemId=$Id;Name=('item '+$Id);Kind='K';Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C';SourcePath=$(if($Source){$Source}else{$Target});TargetPath=$Target;Metadata='DaclOwner';ContentSelection='WholeScope';ConfigFiles=@();ExcludedRelativePaths=@()}}
        }
        # Payload：ItemId -> 檔案位元組陣列；沒登錄的項目在 artifacts.jsonl 裡沒有任何列（缺 payload）。
        function NewPackage([object[]]$Items,[hashtable]$Payload,[int]$ContractVersion=1){
            $script:packageCounter++;$packageRoot=Join-Path $Root ('pkg-'+$script:packageCounter);[void][IO.Directory]::CreateDirectory($packageRoot)
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
            $plan=[pscustomobject]@{Items=@($Items);Assistive=[pscustomobject]@{ContractVersion=$ContractVersion;SourcePolicy='ApprovedLocalVolumes'}}
            $script:previewPackage=[pscustomobject]@{Root=$packageRoot;Plan=$plan;Manifest=[pscustomobject]@{PairId='pair-fixture';PlanHash=('3'*64);Generation=1;Target=[pscustomobject]@{Fingerprint=('b'*64)};ArtifactsHash=$indexHash}}
            $script:previewDecision=[pscustomobject]@{SelectedItemIds=@($Items|ForEach-Object {[string]$_.ItemId});Receipt=[pscustomobject]@{Decision='RestoreNow';AcceptedUnpreparedItemIds=@()};ReceiptHash=('4'*64);Snapshot=[pscustomobject]@{}}
            [pscustomobject]@{ManifestHash=('2'*64);Package=$script:previewPackage;Context=[pscustomobject]@{Plan=$plan}}
        }
        function InvokePreview {Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $Root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture'}
        function TreeSnapshot([string]$Path){
            (@(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop|Sort-Object FullName|ForEach-Object {
                if($_.PSIsContainer){$_.FullName+'|D|'+$_.LastWriteTimeUtc.Ticks}else{$_.FullName+'|F|'+$_.Length+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
            }) -join "`n")
        }
        # 對一個情境：選項與預覽逐項比對。Expect：ItemId -> 期望的選項代碼（空字串＝可還原）。回傳預覽與選項。
        function AssertScenario([string]$Label,$Fixture,[hashtable]$Expect){
            [void](TreeSnapshot $Root);$before=TreeSnapshot $Root;$sideBefore=$script:sideEffects
            $options=@(Get-WsmWizardTargetItemOptions $Fixture.Context $Fixture $script:previewState)
            Check ((TreeSnapshot $Root) -ceq $before -and $script:sideEffects -eq $sideBefore) ($Label+': option evaluation changed target bytes, directory timestamps, created entries or took a lock/journal/JSON write.')
            $preview=InvokePreview
            $optionById=@{};foreach($option in $options){$optionById[[string]$option.value]=$option}
            foreach($id in $Expect.Keys){
                Check $optionById.ContainsKey($id) ($Label+': option for '+$id+' is missing.')
                $option=$optionById[$id];$row=@($preview.Rows|Where-Object ItemId -CEQ $id)
                Check ($row.Count -eq 1) ($Label+': preview row for '+$id+' is missing or duplicated.')
                $expected=[string]$Expect[$id]
                if($expected -ceq ''){
                    Check ($option.restorable -eq $true -and [string]$option.restorableCode -ceq '' -and [string]$option.restorableReason -ceq '' -and [string]$row[0].Status -ceq 'Ready') ($Label+': '+$id+' must be restorable in both the option and the preview (option='+$option.restorableCode+', preview='+$row[0].Action+'/'+$row[0].Status+').')
                }else{
                    Check ($option.restorable -eq $false -and [string]$option.restorableCode -ceq $expected) ($Label+': '+$id+' option code must be '+$expected+' but was "'+$option.restorableCode+'" (restorable='+$option.restorable+').')
                    Check ([string]$row[0].Status -cne 'Ready' -and (ConvertTo-WsmWizardRestorableCode ([string]$row[0].Action)) -ceq $expected) ($Label+': preview row for '+$id+' must agree on code '+$expected+' but was '+$row[0].Action+'/'+$row[0].Status+'.')
                    Check ([string]$option.restorableReason -match '[\u4e00-\u9fff]') ($Label+': '+$id+' reason must be Chinese text.')
                }
            }
            [pscustomobject]@{Preview=$preview;Options=$optionById}
        }

        $targets=Join-Path $Root 'targets';[void][IO.Directory]::CreateDirectory($targets)

        # ---------------------------------------------------------------- 0. 基準：都有 payload、目標可放置 -> 全部可還原
        $a=NewScopeItem 'ok-a' (Join-Path $targets 'a');$b=NewScopeItem 'ok-b' (Join-Path $targets 'b')
        $fixture=NewPackage @($a,$b) @{'ok-a'=@(10);'ok-b'=@(20,30)}
        [void](AssertScenario 'baseline' $fixture @{'ok-a'='';'ok-b'=''})

        # ---------------------------------------------------------------- 1. NoPayload：核准了但封裝裡沒有這個項目的 artifact
        $c=NewScopeItem 'no-payload' (Join-Path $targets 'c')
        $fixture=NewPackage @($a,$c) @{'ok-a'=@(10)}
        $result=AssertScenario 'no payload' $fixture @{'ok-a'='';'no-payload'='NoPayload'}
        Check (@($result.Preview.Problems|Where-Object ItemId -CEQ 'no-payload').Count -eq 1) 'No payload: the preview must list the missing payload as a problem.'
        Check (-not [IO.Directory]::Exists((Join-Path $targets 'c'))) 'No payload: evaluation created the target directory.'
        # 竄改封裝：索引被改後，選項與預覽都拒絕（不是悄悄當成缺 payload）。
        $indexPath=Join-Path $fixture.Package.Root 'artifacts.jsonl';$indexBytes=[IO.File]::ReadAllBytes($indexPath)
        try{
            [IO.File]::AppendAllText($indexPath,"`n")
            Reject {Get-WsmWizardTargetItemOptions $fixture.Context $fixture $script:previewState} 'Options accepted a package whose artifact index was altered.'
            Reject {InvokePreview} 'Preview accepted a package whose artifact index was altered.'
        }finally{[IO.File]::WriteAllBytes($indexPath,$indexBytes)}

        # ---------------------------------------------------------------- 2. MissingVolume：不存在的磁碟；另有 subst 出來的第二個磁碟可正常放置
        $missingDrive=@('Q','R','S','T','U','V','W','X','Y','Z'|Where-Object {-not (Test-Path -LiteralPath ($_+':\'))})
        Check ($missingDrive.Count -ge 2) 'Two unused drive letters are required for the missing-volume and subst scenarios.'
        $gone=$missingDrive[0]+':\Sites\gap';$substRoot=Join-Path $Root 'subst-volume';[void][IO.Directory]::CreateDirectory($substRoot)
        $substLetter=$missingDrive[1];$substOutput=& subst.exe ($substLetter+':') $substRoot 2>&1
        if($LASTEXITCODE -ne 0){throw ('subst failed: '+$substOutput)}
        Check (Test-Path -LiteralPath ($substLetter+':\')) 'subst did not create the second volume.'
        $v=NewScopeItem 'on-subst' ($substLetter+':\data\v');$m=NewScopeItem 'no-volume' $gone
        $fixture=NewPackage @($a,$v,$m) @{'ok-a'=@(10);'on-subst'=@(10);'no-volume'=@(10)}
        $result=AssertScenario 'missing volume' $fixture @{'ok-a'='';'on-subst'='';'no-volume'='MissingVolume'}
        Check (-not (Test-Path -LiteralPath ($missingDrive[0]+':\')) -and -not [IO.Directory]::Exists($substLetter+':\data')) 'Missing-volume evaluation created a volume or a directory on the subst volume.'

        # ---------------------------------------------------------------- 3. InsufficientCapacity：依卷加總（各自夠、合計不夠），另一卷不受影響
        $cRoot=([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($targets))).ToUpperInvariant();$sRoot=($substLetter+':\').ToUpperInvariant()
        $big1=NewScopeItem 'cap-1' (Join-Path $targets 'cap1');$big2=NewScopeItem 'cap-2' (Join-Path $targets 'cap2');$other=NewScopeItem 'cap-subst' ($substLetter+':\data\cap')
        $fixture=NewPackage @($big1,$big2,$other) @{'cap-1'=@(300MB);'cap-2'=@(300MB);'cap-subst'=@(300MB)}
        $script:freeBytes=@{};$script:freeBytes[$cRoot]=[long](700MB);$script:freeBytes[$sRoot]=[long](10GB)
        $result=AssertScenario 'capacity' $fixture @{'cap-1'='InsufficientCapacity';'cap-2'='InsufficientCapacity';'cap-subst'=''}
        foreach($capId in @('cap-1','cap-2')){
            $reason=[string]$result.Options[$capId].restorableReason
            Check ($reason.Contains($cRoot) -and $reason.Contains('856') -and $reason.Contains('700')) ('Capacity reason for '+$capId+' must name the volume, the required and the available amount: '+$reason)
        }
        $script:freeBytes[$cRoot]=[long](2GB)
        [void](AssertScenario 'capacity enough' $fixture @{'cap-1'='';'cap-2'='';'cap-subst'=''})
        $script:freeBytes=@{}

        # ---------------------------------------------------------------- 4. BlockedLocation：CV2 要求原位置，來源與目標路徑不同
        $same=NewScopeItem 'cv2-same' (Join-Path $targets 'cv2same');$moved=NewScopeItem 'cv2-moved' (Join-Path $targets 'cv2moved') (Join-Path $targets 'cv2-original-elsewhere')
        $fixture=NewPackage @($same,$moved) @{'cv2-same'=@(10);'cv2-moved'=@(10)} 2
        [void](AssertScenario 'blocked location' $fixture @{'cv2-same'='';'cv2-moved'='BlockedLocation'})

        # ---------------------------------------------------------------- 5. PermissionDenied：真實的拒絕 ACL（拒絕在該目錄新增檔案／子目錄）
        $deniedDirectory=Join-Path $targets 'denied';[void][IO.Directory]::CreateDirectory($deniedDirectory)
        $identityReference=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $denyRule=New-Object Security.AccessControl.FileSystemAccessRule($identityReference,[Security.AccessControl.FileSystemRights]'CreateFiles,CreateDirectories',[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
        $deniedAcl=Get-Acl -LiteralPath $deniedDirectory;$deniedAcl.AddAccessRule($denyRule);Set-Acl -LiteralPath $deniedDirectory -AclObject $deniedAcl
        try{
            $d=NewScopeItem 'no-permission' (Join-Path $deniedDirectory 'child')
            $fixture=NewPackage @($a,$d) @{'ok-a'=@(10);'no-permission'=@(10)}
            [void](AssertScenario 'permission denied' $fixture @{'ok-a'='';'no-permission'='PermissionDenied'})
            Check (-not [IO.Directory]::Exists((Join-Path $deniedDirectory 'child'))) 'Permission-denied evaluation created the child directory.'
        }finally{
            $restoreAcl=Get-Acl -LiteralPath $deniedDirectory;[void]$restoreAcl.RemoveAccessRule($denyRule);Set-Acl -LiteralPath $deniedDirectory -AclObject $restoreAcl
        }

        # ---------------------------------------------------------------- 6. MountPointNotSupported（掛載點觀測為替身）
        $mount=NewScopeItem 'on-mount' (Join-Path $targets 'mounted-volume\data')
        $fixture=NewPackage @($a,$mount) @{'ok-a'=@(10);'on-mount'=@(10)}
        [void](AssertScenario 'mount point' $fixture @{'ok-a'='';'on-mount'='MountPointNotSupported'})

        # ---------------------------------------------------------------- 7. 既有代碼照實帶出：目標已有同名檔案 -> BlockedConflict
        $conflictPath=Join-Path $targets 'conflict';[IO.File]::WriteAllText($conflictPath,'operator-owned file')
        $conflict=NewScopeItem 'conflict' $conflictPath
        $fixture=NewPackage @($a,$conflict) @{'ok-a'=@(10);'conflict'=@(10)}
        [void](AssertScenario 'blocked conflict' $fixture @{'ok-a'='';'conflict'='BlockedConflict'})
        Check ([IO.File]::ReadAllText($conflictPath) -ceq 'operator-owned file') 'Conflict evaluation changed the operator-owned file.'

        # ---------------------------------------------------------------- 8. 人工處理／外部處理／沒有規格仍標示原本代碼；沒有已驗證封裝時不替 payload／目標下結論
        $manual=[pscustomobject]@{ItemId='manual';Name='manual';Kind='K';Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='ManualWorkflow'}}
        $external=[pscustomobject]@{ItemId='external';Name='external';Kind='K';Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='External';TargetPath=(Join-Path $targets 'ext')}}
        $nospec=[pscustomobject]@{ItemId='nospec';Name='nospec';Kind='K';Decision='Include';Dependencies=@();MigrationSpec=$null}
        $fixture=NewPackage @($a,$manual,$external,$nospec) @{'ok-a'=@(10)}
        $options=@(Get-WsmWizardTargetItemOptions $fixture.Context $fixture $script:previewState);$optionById=@{};foreach($option in $options){$optionById[[string]$option.value]=$option}
        Check ($optionById['manual'].restorableCode -ceq 'ManualWorkflow' -and $optionById['nospec'].restorableCode -ceq 'ManualWorkflow' -and $optionById['external'].restorableCode -ceq 'External' -and -not $optionById['manual'].restorable -and -not $optionById['external'].restorable -and $optionById['ok-a'].restorable) 'Manual / external / spec-less options must carry their own code.'
        $noPackage=@(Get-WsmWizardTargetItemOptions ([pscustomobject]@{Plan=$fixture.Context.Plan}) $null $null)
        Check (@($noPackage|Where-Object {$_.value -ceq 'ok-a'})[0].restorable -and @($noPackage|Where-Object {$_.value -ceq 'ok-a'})[0].restorableCode -ceq '') 'Without a verified package an option must not invent a payload or placement verdict.'

        Write-Host ('PASS: '+$script:checks+' restorable-set checks (payload / volume / capacity / location / permission / mount point / conflict agree between options and preview; option evaluation is read-only).')
    } $root $assistivePath $runtimePath
} finally {
    foreach($mapping in @(& subst.exe 2>&1|Where-Object {([string]$_).Contains($idMarker)})){$letter=([string]$mapping).Substring(0,2);& subst.exe $letter /d 2>&1|Out-Null}
    $full=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'wsm-n1-set-*'){throw 'Unsafe cleanup path.'}
    if([IO.Directory]::Exists($full)){
        # 殘留的拒絕 ACL 會擋刪除；先把整棵樹的拒絕規則清掉再刪。
        Get-ChildItem -LiteralPath $full -Recurse -Force -Directory -ErrorAction SilentlyContinue|ForEach-Object {try{$acl=Get-Acl -LiteralPath $_.FullName;$deny=@($acl.Access|Where-Object {$_.AccessControlType -eq 'Deny' -and -not $_.IsInherited});foreach($rule in $deny){[void]$acl.RemoveAccessRule($rule)};if($deny.Count){Set-Acl -LiteralPath $_.FullName -AclObject $acl}}catch{}}
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
