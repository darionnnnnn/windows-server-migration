#requires -Version 5.1
# Q6a：第七輪測試缺口補測（PowerShell 核心層）。每個區段對應規格 work/r7/specs/Q6a-test-gaps.md 的一項：
#   A  15.5-8  部分選取時，缺卷只擋「已選項目」（未選項目不寫入，預覽標 DeferredBySelection，選項端仍顯示缺卷）
#   B  14.3-4  關聯不明只擋確定相依的項目，不擴成全域阻擋（未知相依 helper 與預覽兩層）
#   C  16.3-5  不得用同一包內自算的 hash 當授權（竄改後重算包內 hash 仍被外部核准 hash 拒絕）
#   E  15.3-5  產品碼靜態守門：不得使用 DPAPI／ProtectedData／不帶 -Key 的 SecureString 序列化／CMS 加密
#   F          離線報告防偽：結果集雜湊與 attempt 不符、屬於另一個 pair／attempt，一律拒絕或標為不可信
#   G          探索遇到不可讀子樹：列為涵蓋缺口並附原因，不整體失敗、不默默略過（真實 deny ACL，finally 移除）
#   I  17.103／17.118  pending AssistiveFileReplace intent 復原遇到同內容外部檔：只有正向證據才記為工具擁有，其餘一律記為沿用既有檔（回復時不刪除）
# 參數 -Section 可只跑部分區段。區段 I 的「依證據分類」斷言（Q6a2 修正後）一律是硬性斷言，沒有開關。
[CmdletBinding()]
param([ValidateSet('A','B','C','E','F','G','I')][string[]]$Section=@('E','A','B','F','G','I','C'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
$srcRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src'))
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-q6a-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
# Target WorkRoot 要夠短（資料夾交付成員路徑有 MAX_PATH 上限），與 Test-ImportIdentityCounterexamples 一樣放在 C:\Users\Public 底下的隨機短名稱。
$work=Join-Path 'C:\Users\Public' ('q'+[Guid]::NewGuid().ToString('N').Substring(0,6))
if([IO.File]::Exists($work) -or [IO.Directory]::Exists($work) -or [IO.Directory]::Exists($root)){throw 'Refusing to use a pre-existing randomized test directory.'}
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root,$Work,$SrcRoot,$Sections)
        $script:checks=0
        function Want([string]$Name){$Sections -contains $Name}
        function Check($Condition,[string]$Message){if(-not [bool]$Condition){throw ('FAIL: '+$Message)};$script:checks++}
        function Reject([scriptblock]$Action,[string]$Message,[string]$Pattern=''){$text='';$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true;$text=[string]$_.Exception.Message};Check $rejected $Message;if($Pattern){Check ($text -match $Pattern) ($Message+' (wrong rejection: '+$text+')')}}
        function Sha([string]$Path){if([IO.File]::Exists($Path)){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}else{'<absent>'}}
        function WriteUtf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
        function Note([string]$Text){Write-Host $Text}
        $denySid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $script:denyRegistry=New-Object 'System.Collections.Generic.List[object]'

        # ===================================================================== E. 靜態守門：產品碼不得使用 DPAPI
        if(Want 'E'){
            & {
                # 15.3-5：不可依賴舊機專屬的 DPAPI／機器私密狀態。這個守門掃描 src 的實際程式（PowerShell 用語法樹與記號，略過註解；其餘檔案掃全文）。
                #   .NET／原生 API 名稱：ProtectedData、ProtectedMemory、DataProtectionScope、DataProtectionProvider、DataProtector、CryptProtectData／CryptUnprotectData／CryptProtectMemory／CryptUnprotectMemory
                #   指令：Protect-CmsMessage、Unprotect-CmsMessage、Export-Clixml、Import-Clixml（憑證／SecureString 的 Clixml 序列化即 DPAPI）
                #   ConvertFrom-SecureString 不帶 -Key／-SecureKey；ConvertTo-SecureString 不帶 -AsPlainText／-Key／-SecureKey（預設即 DPAPI 解密）
                # 限制：以字面比對，無法抓到以字串拼接成型別名稱的規避寫法（目前 src 沒有這類寫法；新增反射式載入需另行審查）。
                $apiPattern='(?i)ProtectedData|ProtectedMemory|DataProtectionScope|DataProtectionProvider|DataProtector|CryptProtectData|CryptUnprotectData|CryptProtectMemory|CryptUnprotectMemory|Protect-CmsMessage|Unprotect-CmsMessage|Export-Clixml|Import-Clixml'
                function Test-HasParameter($Parameters,[string[]]$Names){foreach($p in @($Parameters)){foreach($n in $Names){if($p.Length -ge 1 -and $n.StartsWith($p,[StringComparison]::OrdinalIgnoreCase)){return $true}}};$false}
                function Get-DpapiViolations([string]$Text,[string]$Name,[bool]$IsPowerShell){
                    $found=New-Object 'System.Collections.Generic.List[string]'
                    if(-not $IsPowerShell){
                        foreach($m in [regex]::Matches($Text,$apiPattern)){$found.Add($Name+': '+$m.Value)}
                        return $found.ToArray()
                    }
                    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
                    foreach($token in @($tokens)){if($token.Kind -eq [Management.Automation.Language.TokenKind]::Comment){continue};foreach($m in [regex]::Matches([string]$token.Text,$apiPattern)){$found.Add($Name+': '+$m.Value)}}
                    foreach($command in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))){
                        $commandName=[string]$command.GetCommandName();if(-not $commandName){continue}
                        $parameters=@($command.CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst]}|ForEach-Object {[string]$_.ParameterName})
                        if($commandName -ieq 'ConvertFrom-SecureString' -and -not (Test-HasParameter $parameters @('Key','SecureKey'))){$found.Add($Name+': ConvertFrom-SecureString without -Key/-SecureKey')}
                        if($commandName -ieq 'ConvertTo-SecureString' -and -not (Test-HasParameter $parameters @('AsPlainText','Key','SecureKey'))){$found.Add($Name+': ConvertTo-SecureString without -AsPlainText/-Key/-SecureKey')}
                    }
                    return $found.ToArray()
                }
                # 反例（掃描器自己必須抓得到每一種寫法；同一份函式也用在下面掃真實 src）
                $positive=[ordered]@{
                    'ProtectedData'='$x=[System.Security.Cryptography.ProtectedData]::Protect($b,$null,"CurrentUser")'
                    'ProtectedMemory'='[Security.Cryptography.ProtectedMemory]::Protect($b,"SameProcess")'
                    'DataProtectionScope'='$s=[Security.Cryptography.DataProtectionScope]::LocalMachine'
                    'ConvertFrom-SecureString bare'='$t=ConvertFrom-SecureString $secure'
                    'ConvertFrom-SecureString piped'='$secure|ConvertFrom-SecureString'
                    'ConvertTo-SecureString bare'='$s=ConvertTo-SecureString $text'
                    'Protect-CmsMessage'='Protect-CmsMessage -To "cn=x" -Content $c'
                    'Unprotect-CmsMessage'='Unprotect-CmsMessage -Content $c'
                    'Export-Clixml'='$cred|Export-Clixml -Path x.xml'
                    'Import-Clixml'='$cred=Import-Clixml x.xml'
                    'P/Invoke CryptProtectData'="Add-Type -TypeDefinition @'`npublic class N { [DllImport(`"crypt32.dll`")] public static extern bool CryptProtectData(); }`n'@"
                    'P/Invoke CryptUnprotectData in string'='$sig=''[DllImport("crypt32.dll")] static extern bool CryptUnprotectData();'''
                }
                foreach($name in $positive.Keys){Check (@(Get-DpapiViolations ([string]$positive[$name]) ('positive:'+$name) $true).Count -ge 1) ('E: the scanner did not flag the violating pattern: '+$name)}
                Check (@(Get-DpapiViolations '[System.Security.Cryptography.ProtectedData]::Protect(1)' 'raw:js' $false).Count -eq 1) 'E: the raw-text scan did not flag a non-PowerShell file.'
                $negative=[ordered]@{
                    'ConvertFrom-SecureString -Key'='$t=ConvertFrom-SecureString $secure -Key $key'
                    'ConvertFrom-SecureString -SecureKey'='$t=ConvertFrom-SecureString $secure -SecureKey $key'
                    'ConvertTo-SecureString -AsPlainText'='$s=ConvertTo-SecureString $text -AsPlainText -Force'
                    'ConvertTo-SecureString -Key'='$s=ConvertTo-SecureString $text -Key $key'
                    'comment only'='# the tool never uses ProtectedData or Protect-CmsMessage'
                    'prose word DPAPI'='Write-Host "DPAPI secrets are not portable"'
                }
                foreach($name in $negative.Keys){Check (@(Get-DpapiViolations ([string]$negative[$name]) ('negative:'+$name) $true).Count -eq 0) ('E: the scanner flagged an allowed pattern: '+$name)}
                # 真實 src（再加上根目錄啟動器）；非空掃描守門避免路徑錯誤時空轉恆綠。
                $files=@(Get-ChildItem -LiteralPath $SrcRoot -Recurse -File)+@(Get-Item -LiteralPath (Join-Path (Split-Path $SrcRoot -Parent) 'Start-ServerMigration.ps1'))+@(Get-Item -LiteralPath (Join-Path (Split-Path $SrcRoot -Parent) 'Start-ServerMigration.cmd'))
                Check (@($files|Where-Object Extension -EQ '.ps1').Count -ge 60) ('E: the scan did not reach the product sources (only '+@($files).Count+' files).')
                $violations=New-Object 'System.Collections.Generic.List[string]'
                foreach($file in $files){
                    $isPs=[bool]($file.Extension -in @('.ps1','.psm1','.psd1'))
                    $text=[IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)
                    foreach($v in @(Get-DpapiViolations $text $file.Name $isPs)){$violations.Add([string]$v)}
                }
                Check ($violations.Count -eq 0) ('E: product code uses DPAPI-bound or machine-bound protection: '+(@($violations.ToArray()|Select-Object -First 5) -join ' | '))
                Note ('E: scanned '+@($files).Count+' product files, '+$positive.Count+' violating patterns detected by the scanner, 0 violations in src.')
            }
        }

        # ===================================================================== A + B. 還原預覽（共用替身與封裝建構）
        if((Want 'A') -or (Want 'B')){
            & {
                $script:previewPackage=$null;$script:previewDecision=$null;$script:previewState=[pscustomobject]@{Items=@()}
                function Test-WsmMigrationPackage($ManifestPath,$ExpectedHash,$CancellationToken){$script:previewPackage}
                function Assert-WsmMigrationHost($Identity,$Fingerprint){ }
                function Get-WsmAssistiveRestoreDecision($Package,$ExpectedHash,$ReceiptPath,$ReceiptHash,$SnapshotPath){$script:previewDecision}
                function Get-WsmOperationPaths($StateDirectory,$PairId){[pscustomobject]@{Root=$StateDirectory;State=$null;Journal=$null}}
                function Get-WsmOperationState($Paths,$Package){$script:previewState}
                $script:nonCMode='Empty'
                function Get-WsmAssistiveNonCResultRows($Package,$TransferPlanPath,$TransferPlanHash,$ResultPath,$ResultHash,$StateDirectory){if($script:nonCMode -ceq 'Unreachable'){throw 'Fixture: the non-C evidence is unreachable.'};@{}}
                function Get-WsmGeneralHostIssues {@()}
                $script:packageCounter=0
                function NewScopeItem([string]$Id,[string]$Target,$Extra=$null){
                    $item=[pscustomobject]@{ItemId=$Id;Name=('item '+$Id);Kind='K';Decision='Include';Dependencies=@();MigrationSpec=[pscustomobject]@{Adapter='FileScope';TransferChannel='C';SourcePath=$Target;TargetPath=$Target;Metadata='DaclOwner';ContentSelection='WholeScope';ConfigFiles=@();ExcludedRelativePaths=@()}}
                    if($Extra){foreach($key in $Extra.Keys){$item.MigrationSpec|Add-Member NoteProperty $key $Extra[$key] -Force}}
                    $item
                }
                function NewPackage([object[]]$Items,[hashtable]$Payload,[string[]]$Selected,$GeneralHost=$null,$ComparisonRows=$null){
                    $script:packageCounter++;$packageRoot=Join-Path $Root ('pkg-'+$script:packageCounter);[void][IO.Directory]::CreateDirectory($packageRoot)
                    $meta=[ordered]@{MetadataMode='DaclOwner';Sddl='';Attributes=0;CreationUtc='2026-10-10T00:00:00.0000000Z';LastWriteUtc='2026-10-10T00:00:00.0000000Z'}
                    $lines=New-Object 'System.Collections.Generic.List[string]'
                    foreach($item in $Items){
                        if(-not $Payload.ContainsKey([string]$item.ItemId)){continue}
                        $lines.Add((ConvertTo-Json -InputObject ([ordered]@{ItemId=$item.ItemId;RelativePath='';Directory=$true;Metadata=$meta;Data=$null}) -Depth 10 -Compress))
                        $fileNumber=0
                        foreach($bytes in @($Payload[[string]$item.ItemId])){$fileNumber++;$lines.Add((ConvertTo-Json -InputObject ([ordered]@{ItemId=$item.ItemId;RelativePath=('file'+$fileNumber+'.bin');Directory=$false;Metadata=$meta;Data=[ordered]@{Hash=('a'*64);Bytes=[long]$bytes;Chunks=@()}}) -Depth 10 -Compress))}
                    }
                    $indexPath=Join-Path $packageRoot 'artifacts.jsonl';WriteUtf8 $indexPath ((@($lines.ToArray()) -join "`n")+"`n")
                    $plan=[pscustomobject]@{Items=@($Items);Assistive=[pscustomobject]@{ContractVersion=1;SourcePolicy='ApprovedLocalVolumes'}}
                    if($GeneralHost){$plan|Add-Member NoteProperty GeneralHost $GeneralHost}
                    $script:previewPackage=[pscustomobject]@{Root=$packageRoot;Plan=$plan;Manifest=[pscustomobject]@{PairId='pair-fixture';PlanHash=('3'*64);Generation=1;Target=[pscustomobject]@{Fingerprint=('b'*64)};ArtifactsHash=(Sha $indexPath)}}
                    $receipt=[pscustomobject]@{Decision='RestoreNow';AcceptedUnpreparedItemIds=@();SelectedItemIds=@($Selected)}
                    if($null -ne $ComparisonRows){$receipt|Add-Member NoteProperty Comparison ([pscustomobject]@{Rows=@($ComparisonRows)})}
                    $script:previewDecision=[pscustomobject]@{SelectedItemIds=@($Selected);Receipt=$receipt;ReceiptHash=('4'*64);Snapshot=[pscustomobject]@{}}
                    [pscustomobject]@{Package=$script:previewPackage;Context=[pscustomobject]@{Plan=$plan};Wrapper=[pscustomobject]@{ManifestHash=('2'*64);Package=$script:previewPackage;Context=[pscustomobject]@{Plan=$plan}}}
                }
                function InvokePreview {Get-WsmAssistiveRestorePreview -ManifestPath 'fixture' -ExpectedHash ('2'*64) -StateDirectory $Root -AssistiveDecisionReceiptPath 'fixture' -AssistiveDecisionReceiptHash ('4'*64) -AssistiveTargetSnapshotPath 'fixture'}
                function RowOf($Preview,[string]$Id){$rows=@($Preview.Rows|Where-Object ItemId -CEQ $Id);Check ($rows.Count -eq 1) ('preview row for '+$Id+' is missing or duplicated.');$rows[0]}
                function OptionsOf($Fixture){$by=@{};foreach($o in @(Get-WsmWizardTargetItemOptions $Fixture.Context $Fixture.Wrapper $script:previewState $script:previewDecision)){$by[[string]$o.value]=$o};$by}
                $targets=Join-Path $Root 'targets';[void][IO.Directory]::CreateDirectory($targets)
                $missingDrive=@('Q','R','S','T','U','V','W','X','Y','Z'|Where-Object {-not (Test-Path -LiteralPath ($_+':\'))})
                Check ($missingDrive.Count -ge 1) 'A: one unused drive letter is required for the missing-volume scenarios.'
                $gone=$missingDrive[0]+':\Sites\gap'

                if(Want 'A'){
                    # ---- 15.5-8：部分選取時，缺卷只擋「已選項目」。設計理由：未選項目不寫入（預覽列為 DeferredBySelection，不評估目標），
                    # 所以它所在的缺卷不構成還原阻礙；但可還原清單（選項端）仍逐項標示 MissingVolume，缺卷不會被悄悄忽略、也不會讓備份被稱為「完整」。
                    $okA=NewScopeItem 'sel-ok' (Join-Path $targets 'a');$okB=NewScopeItem 'sel-ok2' (Join-Path $targets 'b');$gap=NewScopeItem 'gap-volume' $gone;$okC=NewScopeItem 'unsel-ok' (Join-Path $targets 'c')
                    $items=@($okA,$okB,$gap,$okC);$payload=@{'sel-ok'=@(10);'sel-ok2'=@(20);'gap-volume'=@(30);'unsel-ok'=@(40)}
                    # 正例 A1：缺卷的項目沒有被選取 -> 不擋；其他已選項目照常 Ready；寫入量只計已選且 Ready 的項目。
                    $fx=NewPackage $items $payload @('sel-ok','sel-ok2')
                    $preview=InvokePreview;$options=OptionsOf $fx
                    Check ((RowOf $preview 'sel-ok').Status -ceq 'Ready' -and (RowOf $preview 'sel-ok2').Status -ceq 'Ready') 'A1: the selected items on a present volume must be Ready.'
                    $deferredGap=RowOf $preview 'gap-volume'
                    Check ($deferredGap.Action -ceq 'DeferredBySelection' -and $deferredGap.Status -ceq 'Deferred') ('A1: an unselected item on a missing volume must be DeferredBySelection (not evaluated, not blocking), got '+$deferredGap.Action+'/'+$deferredGap.Status)
                    Check ((RowOf $preview 'unsel-ok').Action -ceq 'DeferredBySelection') 'A1: an unselected item on a present volume must be DeferredBySelection.'
                    Check ($preview.Blocked -eq $false -and $preview.CanRestoreIndependentItems -eq $true -and @($preview.Problems).Count -eq 0) 'A1: an unselected missing volume must not block the restore or produce a problem row.'
                    Check ([long]$preview.PlannedFileCount -eq 2 -and [long]$preview.PlannedBytes -eq 30) ('A1: planned write amount must cover only the selected Ready items (2 files, 30 bytes), got '+$preview.PlannedFileCount+' files / '+$preview.PlannedBytes+' bytes.')
                    Check ($options['gap-volume'].restorable -eq $false -and [string]$options['gap-volume'].restorableCode -ceq 'MissingVolume' -and [string]$options['gap-volume'].restorableReason -match '[\u4e00-\u9fff]') 'A1: the option list must still surface the missing volume of the unselected item (code MissingVolume, Chinese reason).'
                    Check ($options['gap-volume'].preselected -eq $false -and $options['sel-ok'].preselected -eq $true -and $options['unsel-ok'].preselected -eq $false) 'A1: options must reflect the receipt selection (selected true, unselected false).'
                    Check (-not (Test-Path -LiteralPath ($missingDrive[0]+':\'))) 'A1: evaluation created the missing volume.'
                    # 正例 A2：缺卷項目被選取 -> 只擋它（PrepareSameLocation／Deferred），其他已選項目仍 Ready，獨立項目可還原。
                    $fx=NewPackage $items $payload @('sel-ok','gap-volume')
                    $preview=InvokePreview;$options=OptionsOf $fx
                    $selectedGap=RowOf $preview 'gap-volume'
                    Check ($selectedGap.Action -ceq 'PrepareSameLocation' -and $selectedGap.Status -ceq 'Deferred' -and ([string]$selectedGap.Reason).Contains($missingDrive[0]+':\')) ('A2: a selected item on a missing volume must be PrepareSameLocation/Deferred naming the volume, got '+$selectedGap.Action+'/'+$selectedGap.Status+'/'+$selectedGap.Reason)
                    Check ((RowOf $preview 'sel-ok').Status -ceq 'Ready' -and (RowOf $preview 'sel-ok2').Action -ceq 'DeferredBySelection' -and $preview.CanRestoreIndependentItems -eq $true) 'A2: the independent selected item must stay Ready and the unselected one deferred.'
                    Check ([long]$preview.PlannedFileCount -eq 1 -and [long]$preview.PlannedBytes -eq 10) 'A2: planned write amount must exclude the deferred missing-volume item.'
                    Check ($options['gap-volume'].restorable -eq $false -and [string]$options['gap-volume'].restorableCode -ceq 'MissingVolume') 'A2: the option of the selected missing-volume item must agree with the preview.'
                    # 反例 A3：選項與預覽對同一個項目的缺卷判定隨「是否被選取」切換，選取是唯一變因（全選時缺卷項目出現）。
                    $fx=NewPackage $items $payload @('sel-ok','sel-ok2','gap-volume','unsel-ok')
                    $preview=InvokePreview
                    Check ((RowOf $preview 'gap-volume').Action -ceq 'PrepareSameLocation' -and @($preview.Rows|Where-Object {$_.Status -ceq 'Ready'}).Count -eq 3) 'A3: with every item selected the missing volume must be reported for exactly that item while the other three stay Ready.'
                    Check (-not (Test-Path -LiteralPath ($missingDrive[0]+':\'))) 'A3: evaluation created the missing volume.'
                }

                if(Want 'B'){
                    # ---- 14.3-4 第一層：未知相依 helper（Get-WsmAssistiveUnknownDependencyBlocks）。只涵蓋兩種明確關聯（IISSite->IISPool 名稱、Service->Service 名稱）；
                    # 其他一律視為獨立，不擴成全域阻擋。
                    function PoolItem([string]$Id,[string]$Name){[pscustomobject]@{ItemId=$Id;Name=$Name;Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='IISPool';Desired=[pscustomobject]@{Name=$Name;Xml=('<add name="'+$Name+'" />')}}}}
                    function SiteItem([string]$Id,[string]$Pool,[string]$Decision='Include'){[pscustomobject]@{ItemId=$Id;Name=$Id;Decision=$Decision;MigrationSpec=[pscustomobject]@{Adapter='IISSite';Desired=[pscustomobject]@{Name=$Id;Xml=('<site name="'+$Id+'"><application path="/" applicationPool="'+$Pool+'" /></site>')}}}}
                    function ServiceItem([string]$Id,[string]$Name,[string[]]$Dependencies=@()){[pscustomobject]@{ItemId=$Id;Name=$Name;Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='Service';Desired=[pscustomobject]@{Name=$Name;Dependencies=@($Dependencies)}}}}
                    $plainFile=[pscustomobject]@{ItemId='file-1';Name='file-1';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath='C:\x'}}
                    $taskItem=[pscustomobject]@{ItemId='task-1';Name='task-1';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='ScheduledTask';Desired=[pscustomobject]@{Name='task-1'}}}
                    $all=@((PoolItem 'pool-a' 'PoolA'),(PoolItem 'pool-b' 'PoolB'),(SiteItem 'site-a' 'PoolA'),(SiteItem 'site-b' 'PoolB'),(SiteItem 'site-excluded' 'PoolA' 'Exclude'),$plainFile,$taskItem,(ServiceItem 'svc-x' 'SvcX'),(ServiceItem 'svc-y' 'SvcY' @('SvcX')),(ServiceItem 'svc-z' 'SvcZ' @('SvcY')),(ServiceItem 'svc-w' 'SvcW' @('SvcOther')))
                    $blocks=Get-WsmAssistiveUnknownDependencyBlocks $all @{'pool-a'='unknown native result'}
                    Check (@($blocks.Keys).Count -eq 1 -and $blocks.ContainsKey('site-a') -and ([string]$blocks['site-a']).Contains('PoolA')) ('B1: an unknown pool must block exactly the site that uses it (not the site on another pool, files, tasks, services or excluded items): '+(@($blocks.Keys)-join ','))
                    $blocks=Get-WsmAssistiveUnknownDependencyBlocks $all @{'svc-x'='unknown native result'}
                    Check ((@($blocks.Keys|Sort-Object) -join ',') -ceq 'svc-y,svc-z') ('B2: an unknown service must block only its transitive service dependents (svc-y, svc-z), got '+(@($blocks.Keys|Sort-Object) -join ','))
                    foreach($unrelated in @('file-1','task-1')){
                        $blocks=Get-WsmAssistiveUnknownDependencyBlocks $all @{$unrelated='unknown native result'}
                        Check (@($blocks.Keys).Count -eq 0) ('B3: an unknown '+$unrelated+' (relation not determinable) must not block anything, got '+(@($blocks.Keys)-join ','))
                    }
                    $nameless=[pscustomobject]@{ItemId='pool-nameless';Name='x';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='IISPool';Desired=[pscustomobject]@{Xml='<add />'}}}
                    $brokenSite=[pscustomobject]@{ItemId='site-broken';Name='site-broken';Decision='Include';MigrationSpec=[pscustomobject]@{Adapter='IISSite';Desired=[pscustomobject]@{Name='site-broken';Xml='<not-xml'}}}
                    $blocks=Get-WsmAssistiveUnknownDependencyBlocks @($all+@($nameless,$brokenSite)) @{'pool-nameless'='unknown native result';'pool-a'='unknown native result'}
                    Check ((@($blocks.Keys) -join ',') -ceq 'site-a') ('B4: an unknown item whose name cannot be determined, and a site whose XML cannot be read, must not widen the block (only site-a), got '+(@($blocks.Keys)-join ','))
                    Check ((Get-WsmAssistiveUnknownDependencyBlocks $all @{}).Count -eq 0 -and (Get-WsmAssistiveUnknownDependencyBlocks $all $null).Count -eq 0) 'B5: no unknown item must mean no block.'

                    # ---- 14.3-4 第二層：預覽。某個必要軟體關聯不明（比較列沒有該軟體）只擋它的消費者；NonC 證據不通只擋 NonC 項目；
                    # 工作負載對應未解決只擋該項目；其餘獨立項目照常 Ready，預覽整體不是 Blocked。
                    $dep=NewScopeItem 'dep-consumer' (Join-Path $targets 'dep');$free1=NewScopeItem 'free-1' (Join-Path $targets 'free1');$free2=NewScopeItem 'free-2' (Join-Path $targets 'free2')
                    $mapped=NewScopeItem 'mapping-unresolved' (Join-Path $targets 'mapped') @{WorkloadMappingReview=@([pscustomobject]@{ReviewRequired=$true;Applied=$false;Status='ReviewRequired';FieldPointer='/Task/Actions/0'})}
                    $nonC=NewScopeItem 'noncitem' (Join-Path $targets 'nonc');$nonC.MigrationSpec.TransferChannel='NonC'
                    $unknownRequirement=[pscustomobject]@{RequirementId='req-unknown';ProviderSoftwareId='sw-unknown';Certainty='Required';Decision='Confirmed';ConsumerItemIds=@('dep-consumer')}
                    $noConsumers=[pscustomobject]@{RequirementId='req-orphan';ProviderSoftwareId='sw-orphan';Certainty='Required';Decision='Confirmed';ConsumerItemIds=@()}
                    $itemsB=@($dep,$free1,$free2,$mapped,$nonC);$payloadB=@{'dep-consumer'=@(10);'free-1'=@(10);'free-2'=@(10);'mapping-unresolved'=@(10);'noncitem'=@(10)}
                    $script:nonCMode='Unreachable'
                    $fx=NewPackage $itemsB $payloadB @('dep-consumer','free-1','free-2','mapping-unresolved','noncitem') ([pscustomobject]@{Requirements=@($unknownRequirement,$noConsumers)}) @()
                    $preview=InvokePreview
                    $depRow=RowOf $preview 'dep-consumer'
                    Check ($depRow.Status -ceq 'DeferredSoftware' -and ([string]$depRow.Reason).Length -gt 0) ('B6: the consumer of the unknown software must be deferred with its reason, got '+$depRow.Action+'/'+$depRow.Status)
                    Check ((RowOf $preview 'free-1').Status -ceq 'Ready' -and (RowOf $preview 'free-2').Status -ceq 'Ready') 'B6: independent items must stay Ready when another item has an unknown relation.'
                    Check ((RowOf $preview 'mapping-unresolved').Status -ceq 'ManualEvidenceRequired') 'B7: an unresolved workload mapping must stop only that item.'
                    $nonCRow=RowOf $preview 'noncitem'
                    Check ($nonCRow.Action -ceq 'DeferredNonC' -and $nonCRow.Status -ceq 'Deferred' -and ([string]$nonCRow.Reason).Contains('D evidence validation/readback remains incomplete')) ('B8: an unreachable non-C evidence must defer only the non-C item with the evidence reason, got '+$nonCRow.Action+'/'+$nonCRow.Status+'/'+$nonCRow.Reason)
                    Check ($preview.Blocked -eq $false -and $preview.CanRestoreIndependentItems -eq $true -and @($preview.Rows|Where-Object {$_.Status -ceq 'Ready'}).Count -eq 2) ('B9: the preview must not be globally blocked; exactly the two independent items are Ready, got '+@($preview.Rows|Where-Object {$_.Status -ceq 'Ready'}).Count)
                    $script:nonCMode='Empty'
                    # 關聯完全不明（需求沒有任何消費者）：沒有人被連坐，且不被忽略成「已滿足」——需求本身不產生任何 consumer 的列。
                    $fx=NewPackage @($free1,$free2) @{'free-1'=@(10);'free-2'=@(10)} @('free-1','free-2') ([pscustomobject]@{Requirements=@($noConsumers)}) @()
                    $preview=InvokePreview
                    Check (@($preview.Rows|Where-Object {$_.Status -ceq 'Ready'}).Count -eq 2 -and $preview.Blocked -eq $false) 'B10: a requirement with no determinable consumer must not block unrelated items.'
                    # 必要相依仍然有效（不是忽略）：同一份需求若消費者是 free-1，free-1 被擋、free-2 不受影響。
                    $targetedRequirement=[pscustomobject]@{RequirementId='req-targeted';ProviderSoftwareId='sw-unknown';Certainty='Required';Decision='Confirmed';ConsumerItemIds=@('free-1')}
                    $fx=NewPackage @($free1,$free2) @{'free-1'=@(10);'free-2'=@(10)} @('free-1','free-2') ([pscustomobject]@{Requirements=@($targetedRequirement)}) @()
                    $preview=InvokePreview
                    Check ((RowOf $preview 'free-1').Status -ceq 'DeferredSoftware' -and (RowOf $preview 'free-2').Status -ceq 'Ready') 'B11: a determinable required dependency must still be honoured (consumer deferred) without touching the other item.'
                }
            }
        }

        # ===================================================================== F. 離線報告防偽
        if(Want 'F'){
            & {
                $fRoot=Join-Path $Root 'f';$workspace=Join-Path $fRoot 'ws';[void][IO.Directory]::CreateDirectory($workspace)
                $pair='pair-f-genuine';$otherPair='pair-f-other';$attemptId='attempt-genuine';$otherAttempt='attempt-other'
                $script:fAttempt=$null
                function Get-WsmWizardLatestResultAttempt([string]$Workspace,[string]$PairId,$Profile,$PlanRef){$script:fAttempt}
                $resultsPath=Join-Path $fRoot 'backup-item-results.json'
                function WriteResults([string]$PairId,[string]$Attempt,[string]$Kind='BackupItemResults'){
                    WriteUtf8 $resultsPath (ConvertTo-Json -InputObject ([ordered]@{Kind=$Kind;SchemaVersion=2;PairId=$PairId;AttemptId=$Attempt;GeneratedUtc='2026-10-25T00:00:00Z';Counts=[ordered]@{Total=0};Rows=@()}) -Depth 6 -Compress)
                }
                function SetAttempt([string]$Status='Generated'){$script:fAttempt=[pscustomobject]@{AttemptId=$attemptId;ItemResults=[pscustomobject]@{Status=$Status;Path=$resultsPath;SHA256=(Sha $resultsPath);Error='fixture'}}}
                function VerifySet {Get-WsmWizardVerifiedResultSet $workspace $pair $null $null}
                # 對照組：結果集的雜湊與 attempt 紀錄相符，且屬於這個 pair 與這個 attempt -> 通過。
                WriteResults $pair $attemptId;SetAttempt
                $set=VerifySet
                Check ($null -eq $set.Failure -and $null -ne $set.Document -and [string]$set.Document.PairId -ceq $pair -and $set.ResultsSha256 -ceq (Sha $resultsPath)) 'F0: the genuine result set must verify.'
                # 情況一：結果集雜湊與 attempt 紀錄不符（內容被改、檔案不存在、雜湊格式不對）。
                $bytes=[IO.File]::ReadAllBytes($resultsPath);[IO.File]::WriteAllBytes($resultsPath,$bytes+[byte[]]@(32))
                $set=VerifySet
                Check ($null -ne $set.Failure -and $null -eq $set.Document -and $set.Failure.available -eq $false -and [string]$set.Failure.integrity -ceq 'Failed') 'F1: a result set whose bytes differ from the recorded hash must be refused (integrity Failed, no document).'
                WriteResults $pair $attemptId;SetAttempt;$script:fAttempt.ItemResults.SHA256=('0'*64)
                Check ($null -ne (VerifySet).Failure -and [string](VerifySet).Failure.integrity -ceq 'Failed') 'F1b: a result set cited with a different hash must be refused.'
                WriteResults $pair $attemptId;SetAttempt;Remove-Item -LiteralPath $resultsPath -Force
                Check ($null -ne (VerifySet).Failure -and [string](VerifySet).Failure.integrity -ceq 'Failed') 'F1c: a missing result set file must be refused, not shown as an empty report.'
                # 情況二：結果集屬於另一個 pair／另一個 attempt／不是結果集（連 attempt 紀錄的雜湊都對得上，仍要拒絕）。
                foreach($forged in @(@('another pair',$otherPair,$attemptId,'BackupItemResults'),@('another attempt',$pair,$otherAttempt,'BackupItemResults'),@('another pair and attempt',$otherPair,$otherAttempt,'BackupItemResults'),@('not a result set',$pair,$attemptId,'SomethingElse'))){
                    WriteResults $forged[1] $forged[2] $forged[3];SetAttempt
                    $set=VerifySet
                    Check ($null -ne $set.Failure -and $null -eq $set.Document -and [string]$set.Failure.integrity -ceq 'Failed' -and $set.Failure.available -eq $false) ('F2: a result set from '+$forged[0]+' must be refused even when its hash matches the attempt record.')
                }
                WriteResults $pair $attemptId;SetAttempt 'Failed'
                $set=VerifySet
                Check ($null -ne $set.Failure -and $null -eq $set.Document -and $set.Failure.available -eq $false) 'F3: a failed result generation must not be shown as a report.'
                # 離線報告匯出：只從雜湊相符且種類正確的結果集產生。
                $reportPath=Join-Path $fRoot 'backup-report.html'
                WriteResults $pair $attemptId;$goodHash=Sha $resultsPath
                [IO.File]::WriteAllBytes($resultsPath,[IO.File]::ReadAllBytes($resultsPath)+[byte[]]@(32))
                Reject {Export-WsmBackupOfflineReport $resultsPath $goodHash $reportPath} 'F4: the offline report must not be generated from a result set that no longer matches its hash.' 'hash mismatch'
                Reject {Export-WsmBackupOfflineReport $resultsPath '' $reportPath} 'F4: the offline report must not be generated without an expected hash.' 'hash mismatch'
                WriteResults $pair $attemptId 'SomethingElse'
                Reject {Export-WsmBackupOfflineReport $resultsPath (Sha $resultsPath) $reportPath} 'F4: the offline report must not be generated from a document that is not a backup result set.' 'not a backup item results'
                Check (-not [IO.File]::Exists($reportPath)) 'F4: a refused export left a report file behind.'
                # 獨立副本收據：偽造或錯包的收據標為「無法核對」，不顯示為已驗證。
                # A1 起，投影另檢查副本媒體是否存在；這裡沒有實際媒體，所以收據綁定的判定改直接驗收據本身（Get-WsmWizardIndependentCopyReceiptState）。
                $copyDir=Join-Path (Join-Path (Join-Path (Join-Path $workspace 'workspace-control') 'wizard-backups') $pair) 'independent-copies';[void][IO.Directory]::CreateDirectory($copyDir)
                $receiptPath=Join-Path $copyDir 'receipt.json';$resultsHash=('7'*64);$deliveryHash=('d'*64)
                function WriteReceipt([string]$PairId,[string]$Attempt,[string]$Results,[string]$Delivery){WriteUtf8 $receiptPath (ConvertTo-Json -InputObject ([ordered]@{Kind='IndependentCopyReceipt';PairId=$PairId;AttemptId=$Attempt;DeliverySHA256=$Delivery;ItemResultsSHA256=$Results;VerifiedUtc='2026-10-25T00:00:00Z';Availability='Verified'}) -Depth 4 -Compress)}
                function CopyState([string]$CitedResults=$resultsHash){$attempt=[pscustomobject]@{AttemptId=$attemptId;Delivery=[pscustomobject]@{SHA256=$deliveryHash};IndependentCopy=[pscustomobject]@{Status='Verified';ReceiptPath=$receiptPath;ReceiptSHA256=(Sha $receiptPath)}};(Get-WsmWizardIndependentCopyReceiptState $workspace $pair $attempt $CitedResults).state}
                WriteReceipt $pair $attemptId $resultsHash $deliveryHash
                Check ((CopyState) -ceq 'Verified') 'F5: the genuine receipt must verify.'
                Check ((CopyState ('8'*64)) -ceq 'Unverifiable') 'F5: a receipt that cites another result set must not be shown as verified.'
                WriteReceipt $otherPair $attemptId $resultsHash $deliveryHash;Check ((CopyState) -ceq 'Unverifiable') 'F5: a receipt of another pair must not be shown as verified (hash recomputed by the attempt record).'
                WriteReceipt $pair $otherAttempt $resultsHash $deliveryHash;Check ((CopyState) -ceq 'Unverifiable') 'F5: a receipt of another attempt must not be shown as verified.'
                WriteReceipt $pair $attemptId $resultsHash ('e'*64);Check ((CopyState) -ceq 'Unverifiable') 'F5: a receipt that cites another delivery must not be shown as verified.'
                WriteReceipt $pair $attemptId $resultsHash $deliveryHash
                $attempt=[pscustomobject]@{AttemptId=$attemptId;Delivery=[pscustomobject]@{SHA256=$deliveryHash};IndependentCopy=[pscustomobject]@{Status='Verified';ReceiptPath=$receiptPath;ReceiptSHA256=(Sha $receiptPath)}}
                [IO.File]::WriteAllBytes($receiptPath,[IO.File]::ReadAllBytes($receiptPath)+[byte[]]@(32))
                Check ((Get-WsmWizardIndependentCopyProjection $workspace $pair $attempt $resultsHash).state -ceq 'Unverifiable') 'F5: a receipt whose bytes changed after it was recorded must not be shown as verified.'
                Note 'F: forged / mismatched result sets are refused (hash, pair, attempt, kind, generation failure) and forged receipts are shown as unverifiable.'
            }
        }

        # ===================================================================== G. 探索遇到不可讀子樹
        if(Want 'G'){
            & {
                $gRoot=Join-Path $Root 'g';$scanRoot=Join-Path $gRoot 'scan';$workspace=Join-Path $gRoot 'ws'
                foreach($dir in @($scanRoot,(Join-Path $scanRoot 'open\sub'),(Join-Path $scanRoot 'locked\inner'),(Join-Path $scanRoot 'zafter'))){[void][IO.Directory]::CreateDirectory($dir)}
                WriteUtf8 (Join-Path $scanRoot 'open\a.txt') 'a';WriteUtf8 (Join-Path $scanRoot 'open\sub\b.txt') 'b';WriteUtf8 (Join-Path $scanRoot 'locked\secret.txt') 's';WriteUtf8 (Join-Path $scanRoot 'locked\inner\deep.txt') 'd';WriteUtf8 (Join-Path $scanRoot 'zafter\z.txt') 'z'
                $null=Initialize-WsmOutputWorkspace -WorkRoot $workspace -Role Source
                $profile=Read-WsmOutputProfile $workspace
                $source=[pscustomobject][ordered]@{HostId=[string]$profile.HostId;Fingerprint=([string]$profile.Fingerprint).ToLowerInvariant();Name='fixture-source';OS='fixture';Version=''}
                $inventory=New-WsmInventory $source 1 @()
                $inventoryHash=Get-WsmHashText ($inventory|ConvertTo-Json -Depth 30 -Compress)
                $locked=Join-Path $scanRoot 'locked'
                # 真實 deny ACL：拒絕目前帳號列出目錄（ListDirectory／ReadData）。finally 一定移除，外層 finally 再掃一次保險。
                $rule=New-Object Security.AccessControl.FileSystemAccessRule($denySid,[Security.AccessControl.FileSystemRights]'ListDirectory',[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
                $script:denyRegistry.Add([pscustomobject]@{Path=$locked;Rule=$rule})
                $acl=Get-Acl -LiteralPath $locked;$acl.AddAccessRule($rule);Set-Acl -LiteralPath $locked -AclObject $acl
                try{
                    $unreadable=$false;try{[void][IO.Directory]::GetFileSystemEntries($locked)}catch [UnauthorizedAccessException]{$unreadable=$true}
                    Check $unreadable 'G: the deny ACE did not make the directory unlistable (the unreadable-subtree case cannot be built on this machine).'
                    $result=Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $inventoryHash $scanRoot '' $null 4000 25
                    $artifact=Get-Content -LiteralPath $result.CandidatePath -Raw -Encoding UTF8|ConvertFrom-Json
                    $report=[IO.File]::ReadAllText($result.ReportPath,[Text.Encoding]::UTF8)
                }finally{
                    $cleanup=Get-Acl -LiteralPath $locked;[void]$cleanup.RemoveAccessRule($rule);Set-Acl -LiteralPath $locked -AclObject $cleanup
                    [void]$script:denyRegistry.RemoveAll([Predicate[object]]{param($e)$e.Path -ceq $locked})
                }
                Check (@((Get-Acl -LiteralPath $locked).Access|Where-Object {[string]$_.AccessControlType -ceq 'Deny'}).Count -eq 0) 'G: the deny ACE was not removed again.'
                # 探索不得整體失敗：終局狀態、可讀區域的候選與缺口列表都在。
                Check ([string]$result.ScanStatus -ceq 'Succeeded' -and -not $result.ContinuationRequired) ('G: one unreadable subtree must not fail or stall the whole discovery (status '+$result.ScanStatus+').')
                $candidatePaths=@($artifact.Candidates|ForEach-Object {[string]$_.Path})
                foreach($expectedPath in @((Join-Path $scanRoot 'open'),(Join-Path $scanRoot 'zafter'),(Join-Path $scanRoot 'open\a.txt'),(Join-Path $scanRoot 'open\sub'),(Join-Path $scanRoot 'open\sub\b.txt'),(Join-Path $scanRoot 'zafter\z.txt'))){
                    Check ($candidatePaths -contains $expectedPath) ('G: readable candidate missing after an unreadable sibling (discovery stopped early): '+$expectedPath)
                }
                # 不可讀的子樹要列為涵蓋缺口並附原因（PermissionDenied），不得默默略過，也不得假裝探索過它的內容。
                $gap=@($artifact.Gaps|Where-Object {[string]$_.Path -ieq $locked})
                Check ($gap.Count -eq 1 -and [string]$gap[0].Reason -ceq 'PermissionDenied') ('G: the unreadable subtree must be listed as a PermissionDenied coverage gap (found '+@($artifact.Gaps|ForEach-Object {$_.Path+'='+$_.Reason})+').')
                Check ([long]$artifact.Coverage.GapCount -ge 1 -and [long]$result.GapCount -ge 1) 'G: the coverage summary must count the gap.'
                foreach($hiddenPath in @((Join-Path $scanRoot 'locked\secret.txt'),(Join-Path $scanRoot 'locked\inner'),(Join-Path $scanRoot 'locked\inner\deep.txt'))){Check ($candidatePaths -notcontains $hiddenPath) ('G: content below an unreadable directory was reported as discovered: '+$hiddenPath)}
                Check ($report.Contains($locked) -and $report.Contains('存取遭拒')) 'G: the review report must show the unreadable path with its reason in Chinese.'
                Check ([string]$artifact.Coverage.Claim -like 'Bounded-policy coverage only*') 'G: the result must not claim whole-volume coverage.'
                Note ('G: unreadable subtree listed as a gap (PermissionDenied), '+@($artifact.Candidates).Count+' readable candidates kept, scan '+$result.ScanStatus+'.')
            }
        }

        # ===================================================================== I. pending intent 復原遇到同內容外部檔
        if(Want 'I'){
            & {
                $iRoot=Join-Path $Root 'i';$stateDirectory=Join-Path $iRoot 'pairs';[void][IO.Directory]::CreateDirectory($stateDirectory)
                $pair=[Guid]::NewGuid().ToString('D');$manifestHash=('9'*64);$planHash=('b'*64)
                $script:iPackage=$null
                function Test-WsmMigrationPackage($ManifestPath,$ExpectedHash,$CancellationToken){$script:iPackage}
                function Assert-WsmMigrationHost($Identity,$Fingerprint){ }
                function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=('c'*64)}}
                $sealed=[Text.Encoding]::UTF8.GetBytes('sealed backup bytes of the pending-intent item')
                function NewCase([string]$Name,[string]$TargetState,[bool]$StagingPresent,[string]$PreMove=''){
                    # TargetState：Absent／ExternalSame（位元組與 metadata 都等於封存內容；有沒有證據由 PreMove 決定）／ExternalDifferent
                    # PreMove：''＝沒有 Move 前證據（舊 journal 或寫入器還沒走到 Move 前）；Bound＝寫入器的 Move 前紀錄、綁定封存雜湊；Wrong＝綁了別的雜湊；Malformed＝不是雜湊
                    $case=Join-Path $iRoot $Name;$scope=Join-Path $case 'scope';[void][IO.Directory]::CreateDirectory($scope)
                    $itemId=(Get-WsmHashText ('i-'+$Name));$target=Join-Path $scope 'file.ini';$staging=$target+'.wsm-'+[Guid]::NewGuid().ToString('N')+'.tmp'
                    $sample=Join-Path $case 'sample.bin';[IO.File]::WriteAllBytes($sample,$sealed);$meta=Get-WsmFileMetadata $sample 'DaclOwner';$expected=Sha $sample
                    $foreign=[Text.Encoding]::UTF8.GetBytes('somebody else content')
                    if($TargetState -ceq 'ExternalSame'){[IO.File]::WriteAllBytes($target,$sealed);Set-WsmFileMetadata $target $meta @{}}
                    if($TargetState -ceq 'ExternalDifferent'){[IO.File]::WriteAllBytes($target,$foreign)}
                    if($StagingPresent){[IO.File]::WriteAllBytes($staging,$sealed);Set-WsmFileMetadata $staging $meta @{}}
                    $spec=[pscustomobject]@{Adapter='FileScope';TargetPath=$scope;Metadata='DaclOwner';AclControlPolicy='Exact';TransferChannel='C';ContentSelection='WholeScope'}
                    $item=[pscustomobject]@{ItemId=$itemId;Name=$Name;Kind='K';Decision='Include';Dependencies=@();MigrationSpec=$spec}
                    $casePair=[Guid]::NewGuid().ToString('D')
                    $package=[pscustomobject]@{SHA256=$manifestHash;PlanHash=$planHash;Root=$case;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($item)};Manifest=[pscustomobject]@{PairId=$casePair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=1;DecisionRevision=1;Target=[pscustomobject]@{Fingerprint=('c'*64)}}}
                    $operation=[pscustomobject]@{ItemId=$itemId;Phase='AssistiveFileReplace';ManifestHash=$manifestHash;Generation=[long]1;RelativePath='file.ini';Target=$target;Staging=$staging;Backup='';PreviousHash='';PreviousMetadataHash='';PreviousMetadata=$null;ExpectedHash=$expected;ExpectedMetadata=$meta;WasOwned=$false;PriorOwner=$null}
                    $script:iPackage=$package
                    $journalAction='AssistiveFileIntent'
                    if($PreMove){$journalAction='AssistiveFilePrepared';$operation|Add-Member NoteProperty PreMoveStagingHash $(switch($PreMove){'Bound'{$expected}'Wrong'{('0'*64)}default{'not-a-hash'}}) -Force}
                    $paths=Get-WsmOperationPaths $stateDirectory $casePair;$state=Get-WsmOperationState $paths $package
                    $state.PendingOperations=@($operation);Add-WsmJournal $paths $state $journalAction $itemId $operation
                    [pscustomobject]@{Name=$Name;Package=$package;ItemId=$itemId;Target=$target;Staging=$staging;Paths=$paths;Pair=$casePair;Expected=$expected;ForeignHash=(Sha $target)}
                }
                function RepairCase($Case){$script:iPackage=$Case.Package;Repair-WsmOperation -ManifestPath 'fixture' -ExpectedHash $manifestHash -StateDirectory $stateDirectory -Confirm:$false}
                function RecordOf($Case){$state=Read-WsmJson $Case.Paths.State;$rows=@($state.Items|Where-Object {[string]$_.ItemId -ceq $Case.ItemId});[pscustomobject]@{Pending=@($state.PendingOperations).Count;Row=$(if($rows.Count){$rows[0]}else{$null})}}
                function OwnedRow($Record){if($Record.Row -and $Record.Row.PSObject.Properties['OwnedFiles'] -and @($Record.Row.OwnedFiles).Count -eq 1){@($Record.Row.OwnedFiles)[0]}else{$null}}

                # I1：目標不存在、staging 完整（intent＋staging 證據齊全）-> 由 Repair 完成寫入，記為工具擁有（沒有 Ownership 欄位），staging 被消耗。
                $c1=NewCase 'i1-staging-proves-tool-write' 'Absent' $true
                [void](RepairCase $c1);$r1=RecordOf $c1;$o1=OwnedRow $r1
                Check ($r1.Pending -eq 0 -and $null -ne $o1 -and -not $o1.PSObject.Properties['Ownership'] -and -not (Test-WsmAssistiveOwnedFileAdopted $o1)) 'I1: intent plus a complete staging file must be recovered as a tool-written (not adopted) file.'
                Check ((Sha $c1.Target) -ceq $c1.Expected -and -not [IO.File]::Exists($c1.Staging)) 'I1: Repair must have moved the staging file into place.'
                # I1 回復：工具寫入的檔案回復時被移走保留（不是被丟棄）。
                $previewHash=(Get-WsmRollbackPreview 'fixture' $manifestHash $stateDirectory).PreviewHash
                [void](Invoke-WsmRollback -ManifestPath 'fixture' -ExpectedHash $manifestHash -StateDirectory $stateDirectory -PreviewHash $previewHash -Acknowledgement ('ROLLBACK '+$c1.Pair) -Confirm:$false)
                Check (-not [IO.File]::Exists($c1.Target) -and @(Get-ChildItem -LiteralPath (Split-Path $c1.Target) -Force|Where-Object Name -Like '.wsm-assistive-rollback-*').Count -eq 1) 'I1: rollback of a tool-written file must displace it into a retained file.'

                # I4：目標有別人的不同內容 -> Repair 拒絕、保留 intent 與全部材料、原檔不動。
                $c4=NewCase 'i4-different-external' 'ExternalDifferent' $true
                Reject {RepairCase $c4} 'I4: Repair must refuse a target holding different external content.' 'drifted from both prior and desired'
                $r4=RecordOf $c4
                Check ($r4.Pending -eq 1 -and (Sha $c4.Target) -ceq $c4.ForeignHash -and [IO.File]::Exists($c4.Staging)) 'I4: the refused recovery must keep the intent, the external file and the staging file untouched.'

                function RollbackOf($Case){
                    $preview=Get-WsmRollbackPreview 'fixture' $manifestHash $stateDirectory
                    $beforeTarget=Sha $Case.Target
                    [void](Invoke-WsmRollback -ManifestPath 'fixture' -ExpectedHash $manifestHash -StateDirectory $stateDirectory -PreviewHash $preview.PreviewHash -Acknowledgement ('ROLLBACK '+$Case.Pair) -Confirm:$false)
                    [pscustomobject]@{Survived=([IO.File]::Exists($Case.Target) -and (Sha $Case.Target) -ceq $beforeTarget);Retained=@(Get-ChildItem -LiteralPath (Split-Path $Case.Target) -Force|Where-Object Name -Like '.wsm-assistive-rollback-*').Count}
                }
                # Q6a2：沒有正向證據（intent＋Move 前紀錄＋staging 已消耗）時，一律記為 AdoptedExisting，回復時外部檔不得被移走或刪除。
                #   I2：沒有 staging、也沒有 Move 前紀錄（舊 journal，或工具還沒走到 Move 前）；I3：staging 還在（工具的 Move 沒有完成，目標是之後才出現的外部檔）。
                #   I6：有 Move 前紀錄，但 staging 還在（Move 沒完成）；I7：Move 前紀錄綁的雜湊不是封存雜湊；I8：Move 前紀錄不是雜湊。三者都不構成證據。
                foreach($variant in @(@('i2-external-same-no-staging',$false,''),@('i3-external-same-staging-left',$true,''),@('i6-premove-record-but-staging-left',$true,'Bound'),@('i7-premove-record-wrong-hash',$false,'Wrong'),@('i8-premove-record-malformed',$false,'Malformed'))){
                    $label=$variant[0].Substring(0,2).ToUpperInvariant()
                    $c=NewCase $variant[0] 'ExternalSame' ([bool]$variant[1]) ([string]$variant[2])
                    [void](RepairCase $c);$r=RecordOf $c;$o=OwnedRow $r
                    Check ($r.Pending -eq 0 -and (Sha $c.Target) -ceq $c.Expected -and $null -ne $o) ($label+': Repair must clear the intent, keep the external bytes and record one ownership row.')
                    Check (Test-WsmAssistiveOwnedFileAdopted $o) ($label+': without positive write evidence an external same-content file must be classified AdoptedExisting.')
                    Check ([IO.File]::Exists($c.Staging) -eq [bool]$variant[1]) ($label+': Repair must keep (not consume or delete) a leftover staging file.')
                    $rb=RollbackOf $c
                    Check ($rb.Survived -and $rb.Retained -eq 0) ($label+': rollback must not displace or delete a file the tool did not write.')
                }
                # I5：正向證據齊全（intent 存在、Move 前紀錄綁定封存雜湊、staging 已被消耗、目標內容與 metadata 都等於封存值）-> 記為工具擁有，回復時被移走保留。
                $c5=NewCase 'i5-positive-evidence-complete' 'ExternalSame' $false 'Bound'
                [void](RepairCase $c5);$r5=RecordOf $c5;$o5=OwnedRow $r5
                Check ($r5.Pending -eq 0 -and $null -ne $o5 -and -not $o5.PSObject.Properties['Ownership'] -and -not (Test-WsmAssistiveOwnedFileAdopted $o5)) 'I5: complete positive evidence (intent, pre-move record, staging consumed) must be recovered as a tool-written file.'
                Check ((Sha $c5.Target) -ceq $c5.Expected) 'I5: Repair must not rewrite the already placed file.'
                $rb5=RollbackOf $c5
                Check (-not $rb5.Survived -and $rb5.Retained -eq 1 -and -not [IO.File]::Exists($c5.Target)) 'I5: rollback of a tool-written file must displace it into a retained file.'
                # I5b：同一份證據，但目標的 metadata 與封存不同 -> 仍拒絕（metadata 不同的行為不變），不論有沒有證據。
                $c5b=NewCase 'i5b-evidence-metadata-differs' 'ExternalSame' $false 'Bound'
                [IO.File]::SetAttributes($c5b.Target,([IO.File]::GetAttributes($c5b.Target) -bor [IO.FileAttributes]::ReadOnly))
                try{Reject {RepairCase $c5b} 'I5b: Repair must refuse a same-content target whose metadata differs from the sealed metadata.'}finally{[IO.File]::SetAttributes($c5b.Target,([IO.File]::GetAttributes($c5b.Target) -band (-bnot [IO.FileAttributes]::ReadOnly)))}
                Check ((Sha $c5b.Target) -ceq $c5b.Expected -and (RecordOf $c5b).Pending -eq 1) 'I5b: the refused recovery must keep the intent and the file.'

                # I9／I10：真實寫入器（Invoke-WsmAssistiveFileScopeRestore）寫的證據。
                #   I9：Move 前的 journal 紀錄（AssistiveFilePrepared）在 Move 之前寫入（寫入當下目標還不存在），綁定封存雜湊，順序是 Intent -> Prepared -> Completed。
                #   I10：寫入器在 Move 完成後立刻當機（以注入失敗模擬，state 停在最後一筆 journal）-> 由 Repair 復原時憑 Move 前紀錄＋staging 已被消耗，記為工具擁有。
                $script:iEntries=@();$script:iCrashAfterMove=$false;$script:iPreparedSawTarget=$null
                function Read-WsmArtifactLines($Path,$Hash,$CancellationToken){$script:iEntries}
                function Restore-WsmPayloadBytes($Entry,$PackageRoot,$Destination,$CancellationToken){[IO.File]::WriteAllBytes($Destination,$sealed)}
                $script:iOrigJournal=(Get-Command Add-WsmJournal -CommandType Function).ScriptBlock
                function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){if($Action -ceq 'AssistiveFilePrepared'){$script:iPreparedSawTarget=[IO.File]::Exists([string]$Detail.Target)};& $script:iOrigJournal $Paths $State $Action $ItemId $Detail}
                $script:iOrigTopology=(Get-Command Assert-WsmAssistiveTargetScopeTopology -CommandType Function).ScriptBlock
                function Assert-WsmAssistiveTargetScopeTopology {if($script:iCrashAfterMove -and ($args -contains 'File')){throw 'Q6a2 injected crash right after the Move'};& $script:iOrigTopology @args}
                function NewWriterCase([string]$Name){
                    $case=Join-Path $iRoot $Name;$scope=Join-Path $case 'scope';$media=Join-Path $case 'media';[void][IO.Directory]::CreateDirectory($scope);[void][IO.Directory]::CreateDirectory($media)
                    $itemId=(Get-WsmHashText ('w-'+$Name));$target=Join-Path $scope 'file.ini'
                    $sample=Join-Path $case 'sample.bin';[IO.File]::WriteAllBytes($sample,$sealed);$meta=Get-WsmFileMetadata $sample 'DaclOwner';$expected=Sha $sample
                    $spec=[pscustomobject]@{Adapter='FileScope';TargetPath=$scope;Metadata='DaclOwner';AclControlPolicy='Exact';TransferChannel='C';ContentSelection='WholeScope'}
                    $item=[pscustomobject]@{ItemId=$itemId;Name=$Name;Kind='K';Decision='Include';Dependencies=@();MigrationSpec=$spec}
                    $casePair=[Guid]::NewGuid().ToString('D')
                    $manifest=[pscustomobject]@{PairId=$casePair;BatchId=[Guid]::NewGuid().ToString('D');PlanHash=$planHash;Generation=1;DecisionRevision=1;ArtifactsHash=('e'*64);Target=[pscustomobject]@{Fingerprint=('c'*64)}}
                    $package=[pscustomobject]@{SHA256=$manifestHash;PlanHash=$planHash;Root=$media;Plan=[pscustomobject]@{SchemaVersion=3;Items=@($item)};Manifest=$manifest}
                    $writerPackage=[pscustomobject]@{SHA256=$manifestHash;Root=$media;Manifest=$manifest}
                    $script:iPackage=$package
                    $paths=Get-WsmOperationPaths $stateDirectory $casePair;$state=Get-WsmOperationState $paths $package
                    $entry=[pscustomobject]@{ItemId=$itemId;RelativePath='file.ini';Directory=$false;Metadata=$meta;Data=[pscustomobject]@{Hash=$expected}}
                    [pscustomobject]@{Name=$Name;Package=$package;WriterPackage=$writerPackage;Item=$item;ItemId=$itemId;Target=$target;Staging='';Paths=$paths;State=$state;Pair=$casePair;Expected=$expected;Entry=$entry}
                }
                try{
                    $w9=NewWriterCase 'i9-writer-journals-evidence-before-move';$script:iEntries=@($w9.Entry)
                    $res9=Invoke-WsmAssistiveFileScopeRestore $w9.Item $w9.WriterPackage $w9.Paths $w9.State @{} $null
                    Check ([string]$res9.Status -ceq 'Succeeded' -and (Sha $w9.Target) -ceq $w9.Expected) 'I9: the real writer did not place the file.'
                    $events9=@(Read-WsmJournalEvents $w9.Paths|ForEach-Object {$_.Row});$actions9=@($events9|ForEach-Object {[string]$_.Action})
                    $prepared9=@($events9|Where-Object {[string]$_.Action -ceq 'AssistiveFilePrepared'})
                    Check ($prepared9.Count -eq 1) 'I9: the writer must journal exactly one pre-move record (AssistiveFilePrepared) for a file it creates.'
                    Check ($script:iPreparedSawTarget -eq $false) 'I9: the pre-move record must be written BEFORE the Move (the target did not exist yet when it was appended).'
                    Check ([string]$prepared9[0].Detail.PreMoveStagingHash -ceq $w9.Expected) 'I9: the pre-move record must bind the sealed (verified staging) hash.'
                    Check ($actions9.IndexOf('AssistiveFileIntent') -ge 0 -and $actions9.IndexOf('AssistiveFileIntent') -lt $actions9.IndexOf('AssistiveFilePrepared') -and $actions9.IndexOf('AssistiveFilePrepared') -lt $actions9.IndexOf('AssistiveFileCompleted')) ('I9: the journal order must be intent, pre-move record, completed (got '+($actions9-join ',')+').')
                    Check (-not @($res9.OwnedFiles)[0].PSObject.Properties['Ownership']) 'I9: a file the writer created must be tool-owned (no Ownership field).'

                    $w10=NewWriterCase 'i10-crash-after-move-recovers-as-tool-owned';$script:iEntries=@($w10.Entry)
                    $script:iCrashAfterMove=$true
                    try{$res10=Invoke-WsmAssistiveFileScopeRestore $w10.Item $w10.WriterPackage $w10.Paths $w10.State @{} $null}finally{$script:iCrashAfterMove=$false}
                    Check ([string]@($res10.FileResults)[0].Status -ceq 'Failed' -and (Sha $w10.Target) -ceq $w10.Expected) 'I10: the crash injection did not stop the writer right after the Move.'
                    $durable10=Read-WsmJson $w10.Paths.State;$pending10=@($durable10.PendingOperations)
                    Check ($pending10.Count -eq 1 -and $pending10[0].PSObject.Properties['PreMoveStagingHash'] -and [string]$pending10[0].PreMoveStagingHash -ceq $w10.Expected) 'I10: the durable state after the crash must still hold the intent together with its pre-move record.'
                    Check (@(Get-ChildItem -LiteralPath (Split-Path $w10.Target) -Force|Where-Object Name -Like '*.tmp').Count -eq 0) 'I10: the Move consumed the staging file.'
                    [void](RepairCase $w10);$r10=RecordOf $w10;$o10=OwnedRow $r10
                    Check ($r10.Pending -eq 0 -and $null -ne $o10 -and -not $o10.PSObject.Properties['Ownership'] -and -not (Test-WsmAssistiveOwnedFileAdopted $o10)) 'I10: intent + pre-move record + consumed staging must be recovered as tool-written.'
                    $rb10=RollbackOf $w10
                    Check (-not $rb10.Survived -and $rb10.Retained -eq 1) 'I10: rollback of the recovered tool-written file must displace it into a retained file.'
                }finally{
                    $script:iCrashAfterMove=$false
                }
                Note 'I: intent recovery classifies by positive evidence (tool-written only with intent + pre-move record + consumed staging); everything else is AdoptedExisting and survives rollback.'
            }
        }

        # ===================================================================== C. 不得用同一包內自算的 hash 當授權
        if(Want 'C'){
            & {
                $c16Root=Join-Path $Root 'c';[void][IO.Directory]::CreateDirectory($c16Root)
                $Root=$c16Root
                function RejectLike([scriptblock]$Action,[string]$Pattern,[string]$Message){$actual='';try{& $Action|Out-Null}catch{$actual=$_.Exception.Message};Check ([bool]$actual -and $actual -like $Pattern) ($Message+' [actual: '+$actual+']')}
                function SaveJson($Data,[string]$Path){[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 100 -Compress),(New-Object Text.UTF8Encoding($false)));$Path}
                $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('b'*64);Name='Import identity Target';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
                function script:Get-WsmMachineIdentity {$script:importTarget}
                $script:importTarget=$target
                $enrollment=Initialize-WsmOutputWorkspace -WorkRoot $Work -Role Target
                Initialize-WsmWorkspace $Work|Out-Null
                $pair=[Guid]::NewGuid().ToString('D')
                $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='Import identity Source';OS='Fixture Server';Version='10.0'}
                $item=New-WsmItem $source.HostId Storage DataRoot 'Import identity fixture' 'import-identity-fixture' @{Path='C:\fixture\import-identity'}
                foreach($name in @('Decision','Reason','Owner','Evidence')){$value=switch($name){Decision{'Include'}Reason{'Reviewed fixture package'}Owner{'Fixture owner'}Evidence{'Isolated import identity test'}};$item|Add-Member NoteProperty $name $value -Force}
                $scope=Join-Path $Root 'payload-scope';[void][IO.Directory]::CreateDirectory($scope)
                $targetScope=Join-Path $Root 'target-scope'
                $spec=[pscustomobject][ordered]@{Adapter='FileScope';Product='Fixture';Procedure='Inspect test payload';Artifacts=@();BusinessChecks=@('Confirm fixture bytes');Owner='Fixture owner';Evidence='Isolated test';SourcePath=$scope;TargetPath=$targetScope;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';TransferChannel='C';ContentSelection='WholeScope';ConfigFiles=@();ConfigOverrides=@()}
                $item|Add-Member NoteProperty MigrationSpec $spec -Force
                $snapshot=New-WsmInventory $source 1 @($item);$snapshotPath=Join-Path $Root 'source-inventory.json';SaveJson $snapshot $snapshotPath|Out-Null
                $snapshotHash=Sha $snapshotPath
                $planItem=$item|ConvertTo-Json -Depth 50|ConvertFrom-Json
                $plan=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion=$script:ToolVersion;Kind='MigrationPlan';BatchId=[Guid]::NewGuid().ToString('D');PairId=$pair;ApprovalId=[Guid]::NewGuid().ToString('D');Source=$source;Target=[pscustomobject]@{HostId=$enrollment.Profile.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;OS=$target.OS;Version=$target.Version};InventoryRevision=1;DecisionRevision=2;InventoryHash=$snapshotHash;ImportedUtc=(Get-WsmUtc);Mode='IsolatedPilot';ToolFingerprint=(Get-WsmToolFingerprint);ApprovedUtc=(Get-WsmUtc);Items=@($planItem);ScopeMode='Assistive'}
                $plan|Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=$pair;SourceSnapshotHash=$snapshotHash;SourcePolicy='SourceCOnly';SourceSelectionsVersion=1;ApprovedItemIds=@([string]$item.ItemId);MaterialReferences=@();DiscoveryAuthority=[pscustomobject][ordered]@{SourceSnapshotReference=[pscustomobject][ordered]@{Reference='source-inventory.json';SHA256=$snapshotHash;InventoryRevision=1;CreatedUtc=(Get-WsmUtc)};InventoryRevision=1;SelectionRevision=1;Dispositions=@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Selected=$true;Decision='Include';Reason='Explicitly selected test fixture'})}}) -Force
                Assert-WsmAssistiveContract $plan MigrationPlan|Out-Null
                $planPath=Join-Path $Root 'approved-plan.json';SaveJson $plan $planPath|Out-Null
                $planHash=Sha $planPath
                $planImport=Import-WsmWizardApprovedPlan -Workspace $Work -Role Target -Path $planPath -ExpectedHash $planHash
                Check ($planImport.Status -ceq 'ImportedVerified' -and $planImport.PairId -ceq $pair) 'Target did not receive the real approved schema-3 fixture plan.'
                $proof=Assert-WsmAssistiveSourceScope $spec SourceCOnly -Native
                Check ($proof.Channel -ceq 'C') 'The bounded package fixture was not on the native C volume.'
                $script:packageNumber=0
                function New-FixturePackage([int]$Generation,[string]$BaseManifestHash){
                    $script:packageNumber++;$packageRoot=Join-Path $Root ('package-'+$script:packageNumber);$payloadRoot=Join-Path $packageRoot 'payload';[void][IO.Directory]::CreateDirectory($payloadRoot)
                    [IO.File]::Copy($planPath,(Join-Path $packageRoot 'plan.json'))
                    $bytes=New-Object byte[] (200*1024);$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
                    $sourceFile=Join-Path $scope 'state.bin';[IO.File]::WriteAllBytes($sourceFile,$bytes)
                    $fileMetadata=Get-WsmFileMetadata $sourceFile 'DaclOwner'
                    $blob=Write-WsmPayloadFile $sourceFile $payloadRoot 65536 0 $null
                    $record=[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;RelativePath='state.bin';Directory=$false;Metadata=$fileMetadata;Data=$blob}
                    $recordsPath=Join-Path $packageRoot 'artifacts.jsonl';[IO.File]::WriteAllText($recordsPath,(ConvertTo-Json -InputObject $record -Depth 30 -Compress)+"`n",(New-Object Text.UTF8Encoding($false)))
                    $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString('D');BatchId=$plan.BatchId;PairId=$pair;ApprovalId=$plan.ApprovalId;PlanHash=$planHash;Source=$plan.Source;Target=$plan.Target;InventoryRevision=1;DecisionRevision=2;Generation=$Generation;BaseManifestHash=$BaseManifestHash;Final=$false;FreezeHash='';ArtifactsHash=(Sha $recordsPath);Files=1;Bytes=[long]$bytes.Length;Records=1;ChunkBytes=65536;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot';SourceCollectionProofs=@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Channel='C';PhysicalPath=$proof.PhysicalPath;SourceCPhysicalRoot=$proof.SourceCPhysicalRoot;SourceFingerprint=$source.Fingerprint;NativeVerified=$true})}
                    $manifestPath=Join-Path $packageRoot 'manifest.json';SaveJson $manifest $manifestPath|Out-Null
                    $manifestHash=Sha $manifestPath
                    $validated=Test-WsmMigrationPackage $manifestPath $manifestHash
                    Check ($validated.Valid -and [int]$validated.Manifest.Generation -eq $Generation) ('Core validator rejected fixture package '+$script:packageNumber+'.')
                    [pscustomobject]@{Root=$packageRoot;ManifestPath=$manifestPath;ManifestHash=$manifestHash;PackageId=[string]$manifest.PackageId;Generation=$Generation}
                }
                function Copy-Tree([string]$From,[string]$To){foreach($file in @(Get-ChildItem -LiteralPath $From -Recurse -File)){$relative=$file.FullName.Substring($From.TrimEnd('\').Length).TrimStart('\');$destination=Join-Path $To $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination));[IO.File]::Copy($file.FullName,$destination,$true)}}
                # 竄改：改 artifacts.jsonl 的中繼資料列（不影響 payload 區塊雜湊），再「重算」包內全部自洽的 hash（manifest.ArtifactsHash；資料夾交付再重算 summary）。
                function Forge-ArtifactsAndManifest([string]$PackageDirectory){
                    $indexPath=Join-Path $PackageDirectory 'artifacts.jsonl'
                    $forgedLines=foreach($line in @([IO.File]::ReadAllLines($indexPath,[Text.Encoding]::UTF8)|Where-Object {$_})){$row=$line|ConvertFrom-Json;$row.Metadata.LastWriteUtc='2001-01-01T00:00:00.0000000Z';ConvertTo-Json -InputObject $row -Depth 30 -Compress}
                    [IO.File]::WriteAllText($indexPath,((@($forgedLines) -join "`n")+"`n"),(New-Object Text.UTF8Encoding($false)))
                    $manifestPath=Join-Path $PackageDirectory 'manifest.json';$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
                    $manifest.ArtifactsHash=Sha $indexPath;SaveJson $manifest $manifestPath|Out-Null
                    [pscustomobject]@{ManifestPath=$manifestPath;ManifestHash=(Sha $manifestPath);IndexPath=$indexPath}
                }
                $genuine=New-FixturePackage 1 ''
                # C1：核心驗證入口。竄改並重算包內 hash 後，用外部核准的原 manifest hash 驗證必須被拒；
                #     同一包用自己算出的 hash 驗證會通過（對照組：驗證器只核對完整性，授權完全來自外部給的 hash，所以呼叫端絕不可用包內自算值）。
                $forgedRoot=Join-Path $Root 'forged-package';Copy-Tree $genuine.Root $forgedRoot
                $forged=Forge-ArtifactsAndManifest $forgedRoot
                Check ($forged.ManifestHash -cne $genuine.ManifestHash) 'C1: the forged manifest must differ from the approved one.'
                RejectLike {Test-WsmMigrationPackage $forged.ManifestPath $genuine.ManifestHash} '*SHA256 mismatch*' 'C1: a tampered package with recomputed internal hashes was accepted under the externally approved manifest hash.'
                $selfAuthorized=Test-WsmMigrationPackage $forged.ManifestPath $forged.ManifestHash
                Check ($selfAuthorized.Valid -eq $true) 'C1 control: the forged package is internally consistent (a self-computed hash passes), so only the external approved hash rejects it.'
                # C2：計畫檔。改計畫內容、用「計畫自己的新 hash」匯入，外部核准的 hash 仍是原值 -> 拒絕，且 Target 沒有收下新計畫。
                $forgedPlanPath=Join-Path $Root 'forged-plan.json';$forgedPlan=Get-Content -LiteralPath $planPath -Raw -Encoding UTF8|ConvertFrom-Json;$forgedPlan.DecisionRevision=[int]$forgedPlan.DecisionRevision+1;SaveJson $forgedPlan $forgedPlanPath|Out-Null
                Check ((Sha $forgedPlanPath) -cne $planHash) 'C2: the forged plan must have a different hash.'
                RejectLike {Import-WsmWizardApprovedPlan -Workspace $Work -Role Target -Path $forgedPlanPath -ExpectedHash $planHash} '*path/hash could not be verified*' 'C2: a tampered plan was imported under the externally approved plan hash.'
                # C3：資料夾交付。竄改交付內容並重算 manifest 與 summary 內的所有 hash；以外部核准的 summary hash 匯入必須被拒，且不留下可當授權的匯入狀態。
                $delivery=Export-WsmDirectoryDelivery -ManifestPath $genuine.ManifestPath -ExpectedHash $genuine.ManifestHash -OutputDirectory (Join-Path $Root 'delivery-genuine')
                $forgedDelivery=Export-WsmDirectoryDelivery -ManifestPath $genuine.ManifestPath -ExpectedHash $genuine.ManifestHash -OutputDirectory (Join-Path $Root 'delivery-forged')
                $forgedDeliveryFacts=Forge-ArtifactsAndManifest $forgedDelivery.Directory
                $summary=Get-Content -LiteralPath $forgedDelivery.SummaryPath -Raw -Encoding UTF8|ConvertFrom-Json
                foreach($member in @($summary.Members)){
                    $memberPath=Join-Path $forgedDelivery.Directory ([string]$member.Name).Replace('/','\')
                    $member.Bytes=[long](New-Object IO.FileInfo($memberPath)).Length;$member.SHA256=Sha $memberPath
                }
                $summary.ManifestHash=$forgedDeliveryFacts.ManifestHash;SaveJson $summary $forgedDelivery.SummaryPath|Out-Null
                $forgedSummaryHash=Sha $forgedDelivery.SummaryPath
                Check ($forgedSummaryHash -ine [string]$delivery.SummarySHA256 -and $forgedSummaryHash -ine [string]$forgedDelivery.SummarySHA256) 'C3: the forged summary must have its own recomputed hash.'
                $forgedOperation=[Guid]::NewGuid().ToString('D')
                RejectLike {Import-WsmWizardTargetDirectoryPackage -Workspace $Work -PairId $pair -SummaryPath $forgedDelivery.SummaryPath -ExpectedSummaryHash ([string]$forgedDelivery.SummarySHA256) -SourceDirectory $forgedDelivery.Directory -OperationId $forgedOperation} '*SHA256 mismatch*' 'C3: a forged delivery with recomputed internal hashes was imported under the externally approved summary hash.'
                $authorityMessage='';try{$null=Get-WsmWizardTargetPackage -Workspace $Work -PairId $pair -Context (Assert-WsmWizardTargetRole $Work $pair) -Jobs @()}catch{$authorityMessage=$_.Exception.Message}
                Check ($authorityMessage -like 'No durable successful Target package-delivery job*') ('C3: a refused forged import left a resolvable authoritative package state ('+$authorityMessage+').')
                # 對照組：原封不動的交付，用外部核准的 summary hash 可以匯入（證明上面的拒絕來自授權綁定，而不是環境問題）。
                $genuineOperation=[Guid]::NewGuid().ToString('D')
                $imported=Import-WsmWizardTargetDirectoryPackage -Workspace $Work -PairId $pair -SummaryPath $delivery.SummaryPath -ExpectedSummaryHash ([string]$delivery.SummarySHA256) -SourceDirectory $delivery.Directory -OperationId $genuineOperation
                Check ($imported.Status -ceq 'Succeeded' -and $imported.Valid -and [string]$imported.ManifestHash -ceq $genuine.ManifestHash) 'C3 control: the genuine delivery did not import under its approved summary hash.'
                Note 'C: tampered package / plan / delivery with recomputed internal hashes are refused under the externally approved hashes; the genuine ones are accepted.'
            }
        }

        Write-Host ('PASS: Q6a round-seven gap coverage ('+$script:checks+' checks; sections '+(@($Sections)-join ',')+').')
    } $root $work $srcRoot @($Section)
} finally {
    # 殘留的拒絕 ACL 會擋刪除：先移除登錄的規則，再掃整棵樹的拒絕規則，最後才刪除。
    foreach($full in @($root,$work)){
        if(-not [IO.Directory]::Exists($full)){continue}
        Get-ChildItem -LiteralPath $full -Recurse -Force -Directory -ErrorAction SilentlyContinue|ForEach-Object {try{$acl=Get-Acl -LiteralPath $_.FullName;$deny=@($acl.Access|Where-Object {$_.AccessControlType -eq 'Deny' -and -not $_.IsInherited});foreach($rule in $deny){[void]$acl.RemoveAccessRule($rule)};if($deny.Count){Set-Acl -LiteralPath $_.FullName -AclObject $acl}}catch{}}
    }
    $fullRoot=[IO.Path]::GetFullPath($root);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $fullRoot.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fullRoot) -notmatch '^wsm-q6a-'){throw 'Unsafe Q6a cleanup path (fixture root).'}
    $fullWork=[IO.Path]::GetFullPath($work)
    if(-not $fullWork.StartsWith('C:\Users\Public\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($fullWork).TrimEnd('\') -ine 'C:\Users\Public' -or [IO.Path]::GetFileName($fullWork) -notmatch '^q[0-9a-f]{6}$'){throw 'Unsafe Q6a cleanup path (Target work root).'}
    if([IO.Directory]::Exists($fullWork)){if(([IO.File]::GetAttributes($fullWork) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing recursive cleanup of a reparse point.'};Remove-Item -LiteralPath $fullWork -Recurse -Force}
    if([IO.Directory]::Exists($fullRoot)){Remove-Item -LiteralPath $fullRoot -Recurse -Force}
}
