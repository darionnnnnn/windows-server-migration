#requires -Version 5.1
# R25：使用手冊裡引用的畫面字樣、返回碼與目錄結構，必須和現行程式碼一致（文件只寫現況，不寫程式做不到或已改名的字）。
# 每一列是「文件寫的字」與「程式裡的字」：兩邊都要找得到。改按鈕字樣、返回碼嚴重度或副本目錄結構而沒同步文件時，這支測試轉紅。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
function Read-Text([string]$Relative){[IO.File]::ReadAllText((Join-Path $repo $Relative),(New-Object Text.UTF8Encoding($false,$true)))}
$operations=Read-Text 'docs\OPERATIONS.md'
$readme=Read-Text 'README.md'
$js=Read-Text 'src\ui\console.js'
# 程式端的字樣散在 console.js 與各個 src 檔，全部合併成一份語料來比對。
$allCode=$js+"`n"+((Get-ChildItem -LiteralPath (Join-Path $repo 'src') -File -Filter '*.ps1' | ForEach-Object {[IO.File]::ReadAllText($_.FullName,(New-Object Text.UTF8Encoding($false,$true)))}) -join "`n")
$entry=Read-Text 'Start-ServerMigration.ps1'
$projection=Read-Text 'src\WizardBackupProjection.ps1'
$backup=Read-Text 'src\WizardBackup.ps1'
$wizard=Read-Text 'src\MigrationWizard.ps1'
$restoreWizard=Read-Text 'src\WizardRestore.ps1'
$script:checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}

# 1. 畫面字樣：文件字樣（左）與 console.js 內的字樣（右，同一個字也可）都要存在。
$uiPairs=@(
    @('開始備份','開始備份'),@('明確續作此備份 attempt','明確續作此備份 attempt'),@('一鍵備份進度','一鍵備份進度'),
    @('取消備份','取消備份'),@('要求取消','要求取消'),@('確認取消這次作業','確認取消這次作業'),@('確定取消','確定取消'),@('返回','返回'),
    @('等待交付','等待交付'),@('完成（含待人工處理）','完成（含待人工處理）'),
    @('較新的嘗試','較新的嘗試'),@('發現 N 個無法讀取的備份紀錄','無法讀取的備份紀錄'),
    @('已備份','已備份'),@('未備份','未備份'),@('安裝軟體','安裝軟體'),@('匯出 CSV','匯出 CSV'),
    @('封存檔案','封存檔案'),@('沿用外部共享，未備份','沿用外部共享，未備份'),@('另行遷移，見核准','另行遷移，見核准'),
    @('離線還原就緒','離線還原就緒'),@('建立獨立備份副本','建立獨立備份副本'),@('獨立副本目的資料夾','獨立副本目的資料夾'),
    @('由工具複製並驗證','由工具複製並驗證'),@('我已自行複製，只要驗證','我已自行複製，只要驗證'),@('複製並驗證','複製並驗證'),@('驗證既有副本','驗證既有副本'),
    @('尚未完成交付','尚未完成交付'),@('等待建立獨立副本（舊機關機後還無法還原）','等待建立獨立副本（舊機關機後還無法還原）'),@('獨立副本已驗證','獨立副本已驗證'),
    @('獨立副本已驗證（網路位置：請在新機確認可以存取）','獨立副本已驗證（網路位置：請在新機確認可以存取）'),
    @('獨立副本收據完整，但媒體需重新驗證（舊機關機前請先確認副本還在）','獨立副本收據完整，但媒體需重新驗證（舊機關機前請先確認副本還在）'),
    @('收據完整；媒體需重新驗證','收據完整；媒體需重新驗證'),@('重新驗證','重新驗證'),
    @('在本機產生比較','在本機產生比較'),@('建立決策收據','建立決策收據'),@('全選','全選'),@('全不選','全不選'),@('開始此預覽的還原','開始此預覽的還原'),
    @('重試失敗項目','重試失敗項目'),@('按「↻ 重試失敗項目」','↻ 重試失敗項目'),@('要重試失敗項目請按「重試失敗項目」（或回精靈重新保存選擇）','要重試失敗項目請按「重試失敗項目」（或回精靈重新保存選擇）'),@('按「重新核對」','重新核對'),@('按「開始備份」','開始備份'),@('只有按「確定取消」才會送出','確定取消'),@('按「返回」或 Esc 不會送出任何要求','返回'),@('按「重新驗證」','重新驗證'),@('按「在本機產生比較」','在本機產生比較'),@('請先修復未完成的作業','請先修復未完成的作業'),@('已回復，請重新選擇還原','已回復，請重新選擇還原'),
    @('沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。','沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。'),
    @('目標已有不同內容的檔案，需先人工處理（衝突 N 個檔案）','需先人工處理'),
    @('需先對帳','需先對帳'),@('重新核對','重新核對'),@('待核對','待核對'),@('無法自動核對','無法自動核對'),
    @('輸入帳密以繼續','輸入帳密以繼續'),@('還原暫停，需要帳戶密碼才能繼續','還原暫停，需要帳戶密碼才能繼續'),@('輸入帳戶密碼以繼續還原','輸入帳戶密碼以繼續還原'),
    @('延後這組','延後這組'),@('改回輸入','改回輸入'),@('送出並繼續還原','送出並繼續還原'),@('延後並繼續還原其他項目','延後並繼續還原其他項目'),@('稍後再輸入','稍後再輸入'),
    @('取消這次還原','取消這次還原'),@('由這個視窗接手此還原（原本的視窗已關閉時才勾選）','由這個視窗接手此還原（原本的視窗已關閉時才勾選）'),
    @('還原程序中斷，已完成的項目會保留','還原程序中斷，已完成的項目會保留'),@('檢視恢復預覽','檢視恢復預覽'),@('結果需要核對的項目','結果需要核對的項目'),
    @('我了解並要繼續這次還原','我了解並要繼續這次還原'),@('繼續還原','繼續還原'),
    @('已達重試上限，請確認帳號狀態後在新的還原中處理','已達重試上限'),
    @('匯出確認材料','匯出確認材料'),@('匯入確認材料','匯入確認材料'),@('檢視確認內容','檢視確認內容'),@('進入工作負載對應審閱','進入工作負載對應審閱'),
    @('對應到已確認的範圍','對應到已確認的範圍'),@('不對應（此路徑不屬於已確認範圍）','不對應（此路徑不屬於已確認範圍）'),@('人工處理（稍後自行處理）','人工處理（稍後自行處理）'),
    @('不建立依賴','不建立依賴'),@('必要依賴（缺少則工作負載停止）','必要依賴（缺少則工作負載停止）'),@('選用依賴','選用依賴'),
    @('檢視並送出對應審閱','檢視並送出對應審閱'),@('確認送出','確認送出'),
    @('完成：確認材料與先前匯入的內容完全相同','確認材料與先前匯入的內容完全相同'),@('完成：送出的對應與目前已記錄的完全相同，未變更任何決策或核准。','送出的對應與目前已記錄的完全相同，未變更任何決策或核准。'),
    @('軟體處置審閱（管理端）','軟體處置審閱（管理端）'),@('✔ 已審閱','✔ 已審閱：'),@('⚠ 證據已變更，需重新審閱','⚠ 證據已變更，需重新審閱'),@('○ 尚未審閱','○ 尚未審閱'),
    @('重新安裝','重新安裝'),@('可攜（免安裝）','可攜（免安裝）'),@('保留相容版本','保留相容版本'),@('外部處理（工具不處理）','外部處理（工具不處理）'),@('不需要搬移','不需要搬移'),@('尚未確認（Unknown）','尚未確認（Unknown）'),
    @('套用到已選項目（暫存）','套用到已選項目（暫存）'),@('檢視確認摘要並送出','檢視確認摘要並送出'),@('確認送出軟體處置','確認送出軟體處置'),@('我已核對上述內容，確認送出（Ack）','我已核對上述內容，確認送出（Ack）')
)
foreach($pair in $uiPairs){
    Check $operations.Contains([string]$pair[0]) ('OPERATIONS.md no longer mentions the screen text: '+$pair[0])
    Check $allCode.Contains([string]$pair[1]) ('The screen text quoted by OPERATIONS.md is not in the program anymore: '+$pair[1])
}

# 2. 進度卡：三個階段的名稱與步驟字樣。
foreach($stage in @('擷取與封存','驗證封裝','交付')){Check ($operations.Contains($stage) -and $projection.Contains("'"+$stage+"'")) ('The progress stage name differs between the document and the program: '+$stage)}
Check ($js.Contains('第 ${index} 步／共 ${count} 步') -and $operations.Contains('第 n 步／共 3 步')) 'The progress step wording differs between the document and the program.'
Check ($backup.Contains("StageCount=(Get-WsmWizardBackupProgressStageCodes).Count") -and $backup.Contains("@('Capture','Verify','Deliver')")) 'The document says "共 3 步"; the program must still have exactly three progress stages.'

# 3. 獨立副本目錄結構：<目的>\wsm-offline-<PairId>-<AttemptId>\transport\…
Check ($operations.Contains('<目的>\wsm-offline-<PairId>-<AttemptId>\transport\…') -and $backup.Contains("('wsm-offline-'+`$PairId+'-'+`$attemptId)") -and $backup.Contains("'transport\transport.json'") -and $backup.Contains("'transport\backup-item-results.json'") -and $backup.Contains("'transport\offline-guide.txt'")) 'The independent copy folder structure in OPERATIONS.md differs from the program.'
foreach($media in @('Removable','Network','LocalFixed','Unknown')){Check ($backup.Contains("return '"+$media+"'")) ('The independent copy media class is gone from the program: '+$media)}
Check ($operations.Contains('無法判定媒體類型時同樣被拒絕') -and $backup.Contains('media type cannot be classified')) 'The fourth media type (cannot be classified) must be documented and rejected by the program.'
Check ($operations.Contains('InsufficientSpace') -and $backup.Contains("'InsufficientSpace'") -and $operations.Contains('256 MiB')) 'The independent copy capacity pre-check wording differs from the program.'

# 4. CLI：等待輸入的行格式與返回碼嚴重度（0、2、3、4、1）。
Check ($operations.Contains('Status=WaitingForInput ParentOperationId=<作業識別碼> MissingFields=<缺少的欄位>') -and $entry.Contains("'Status=WaitingForInput'") -and $entry.Contains("' ParentOperationId='") -and $entry.Contains("' MissingFields='")) 'The WaitingForInput line format differs between OPERATIONS.md and the entry script.'
foreach($row in @('| 0 |','| 1 |','| 2 |','| 3 |','| 4 |')){Check $operations.Contains($row) ('The return code table row is missing: '+$row)}
$module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking -WarningAction SilentlyContinue
try{
    $order=@(& $module {@(0,2,3,4,1) | ForEach-Object {[pscustomobject]@{Code=$_;Severity=(Get-WsmStatusCodeSeverity $_)}}})
    $sorted=@($order | Sort-Object Severity | ForEach-Object Code) -join ','
    Check ($sorted -ceq '0,2,3,4,1' -and $operations.Contains('嚴重度由低到高為 0、2、3、4、1')) 'The documented severity order of the menu return code (0, 2, 3, 4, 1) differs from Get-WsmStatusCodeSeverity.'
}finally{Remove-Module WindowsServerMigration -Force -ErrorAction SilentlyContinue}

# 5. 帳密：DEFER／RESUME／TAKEOVER 的提示字樣。
foreach($token in @('輸入 DEFER 延後這一整組帳密（相關項目本次不還原，之後在新的還原中再處理）；直接按 Enter 則輸入帳密','輸入 RESUME 續作父作業 ')){Check ($wizard.Contains($token)) ('The text menu prompt changed: '+$token)}
Check ($wizard.Contains('Type TAKEOVER to continue') -and $operations.Contains('TAKEOVER') -and $operations.Contains('DEFER') -and $operations.Contains('RESUME')) 'DEFER, RESUME and TAKEOVER must be documented as the program prompts for them.'
Check ($operations.Contains('輸入 DEFER 延後這一整組帳密（相關項目本次不還原，之後在新的還原中再處理）；直接按 Enter 則輸入帳密') -and $operations.Contains('輸入 RESUME 續作父作業 <作業識別碼>；其他值不動作')) 'OPERATIONS.md must quote the DEFER and RESUME prompts as the program prints them.'

# 6. 標題用功能名稱，不用輪次；信任邊界要寫明；ToolVersion 範例。
Check ($operations.StartsWith('# 操作契約與逐步精靈') -and -not ($operations -match '(?m)^#{1,3} 第[0-9一二三四五六七八九十]+輪')) 'OPERATIONS.md headings must name the feature, not a round.'
Check ($operations.Contains('本機 HTTP 工作台的 token 只防瀏覽器跨站請求，不防同一台主機上的其他使用者或程序；多人共用的工作階段主機請勿開啟。')) 'The local HTTP console trust boundary sentence is missing from OPERATIONS.md.'
Check ($readme.Contains('-Path D:\MigrationWorkRoot') -and $readme.Contains('先登錄 WorkRoot')) 'The README Inventory example must say the WorkRoot is registered first.'
Write-Output ('PASS: the user documents quote the current screen text, progress stages, independent copy folder structure, return codes and credential prompts ('+$script:checks+' checks).')
