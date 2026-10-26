# 操作契約與逐步精靈

## 一般使用者：從用途開始

雙擊套件中的 `Start-ServerMigration.cmd` 開啟工作台，按「開始／繼續操作」，再依畫面按「下一步」。選擇這台電腦的用途：**舊主機**、**新主機**，或**整理搬移資料的電腦**。已登記用途會在下次啟動時恢復；工作區用途只是操作上下文，不能改變 Windows 權限、核心角色 gate、材料信任或核准。啟動器使用 x64 Windows PowerShell 5.1，不加執行政策繞過參數；遇到政策封鎖，請管理員依組織程序核准。

一般步驟從有效工作與可信材料带入已知值；必要意圖及外部責任證據仍由有權人員提供。舊主機可掃描、逐組決定並匯出選取意圖；這不是備份。精靈已接入型別化準備／核准、封裝、C／非 C 成果、離線完整備份（CV2）及目標還原續作，逐段驗收狀態見[第六輪計畫](plans/MIGRATION-6-PLAN.md)與 `docs/plans/MIGRATION-7-PLAN.md`。選取完成、封裝完成、資料已寫入目標、機械驗證及業務接受各自有獨立狀態。

支援已核准的業務 DLL／EXE、網站、排程、服務、設定與資料；**排除整機映像、作業系統、System State、Windows／IIS／Oracle Client／runtime 等安裝軟體本體**。系統根與可信安裝位置受防護；ExactFiles 只接受有責任證據及雜湊的精確設定，不接受偽裝成設定的可執行檔或壓縮包。非 C 仍受核准與跳板通道限制；自動選取不代替目標綁定核准、還原或啟用確認。

左側「開發者環境探測」是獨立的一鍵唯讀診斷入口，不是一般備份步驟。網頁不可用時，可在本機執行 `powershell.exe -NoProfile -File .\Start-ServerMigration.ps1 -Action DeveloperProbe`。探測把 ZIP、匿名化 JSON 與 HTML 摘要寫入工作區 `developer-probes`；原始盤點留在受保護本機目錄，不自動上傳。權限或環境不適用的 collector 會列出狀態與缺口；探測不執行還原、服務啟動或其他寫入，也不代表 Server 資格或業務驗收通過。

第六輪的雙引擎核心、受控正式 handler 備份／還原旅程與真 Edge 版面已有分項證據；本機原始傳輸 **NotPassed** 狀態保留，不以 mock、fixture 或 writer 擷取橋接改寫。獨立 Windows CI 的原生資源／盤點／保存、Source 備份、Manager 審閱核准、Target 還原及 Probe 已通過。非 C 以隔離雙引擎真 worker／結果匯入驗證，原生企業 SMB 不在通過範圍；精確邊界依本輪分項證據判定。外部 Server／產品／帳號／業務／PKI／規模仍為 NotTested；`ProductionVerified=false`、`ProductionExecutionEnabled=false`，發行包未簽署。最新逐段證據見[實作狀態](IMPLEMENTATION-0.1.md)及[第六輪計畫](plans/MIGRATION-6-PLAN.md)。

## 備份與接收的材料順序

三台電腦各用固定的工作目錄。新主機即使沒有備份，也可以先註冊身分、盤點及匯出交接材料。管理端匯入來源盤點、來源選取意圖及新主機交接，完成準備與目標綁定核准後，把核准計畫交給舊主機。舊主機收到並核對計畫後才開始備份。

每次備份固定 Directory 或 ZIP 及分卷大小，不會改寫工作區預設偏好或既有 attempt。逐項模式預設 Directory，自動模式預設 ZIP，也可明確改選；ZIP 表單接受整數 128–1024 MiB。新主機按收到的材料類型匯入，無須與其工作區預設輸出格式相同。請帶齊所有分卷，核對獨立來源提供的雜湊；工具自己算出的雜湊只是觀測值。容量預檢包含實際磁碟上的封包、乾淨副本及暫存空間，不保證壓縮率。工作目錄過長時，必須在備份／停寫前依提示調整固定目錄，不能手動搬動進行中的狀態。

需要停寫的資料會先顯示受影響服務、排程、網站／共享及原狀態保存位置。一般「開始備份」不等於停寫授權，仍須提供獨立 SourceFreezeReady 證據與明確確認。失敗或取消不會自動重新啟動來源；先查看原 OperationId、attempt 與恢復指引，再由有權人員明確執行恢復或重新開始。

舊格式（非離線完整集合）計畫中，非 C 資料沿獨立受控通道直接寫入新主機，並非包含在離線主備份包；離線完整集合計畫的做法見下一節。先由兩端核對既有共享與精確實體範圍，管理端匯入可信證據、觀察帳號 metadata，逐個 SID 確認映射，再建立傳輸計畫。新主機的狀態目錄固定為該主機工作目錄的 `pairs`；不任意另填 journal 目錄。傳輸結果須經管理端正式匯入，並交回新主機核對，不能把工具自報的 copy 成功當作全部搬移完成。未選 NonC 的獨立 C 項目不需要這些材料；混合項目逐項判定，部分成功仍顯示待處理。

資料分散在多個磁碟時，逐列輸入既有共享名稱及其本機路徑，可加入額外共享；工具不會建立共享。每份交接最多包含 16 個名稱唯一、路徑不重疊的共享。新主機的資料目錄與固定狀態目錄可以使用不同共享，例如 D 槽資料共享與 C 槽工作目錄共享。管理端在匯入預覽核對全部共享、資料目錄對應、狀態目錄及材料指紋，再明確匯入；每份交接的預期指紋仍須從獨立可信管道取得。觀測來源 ACL 與建立搬移計畫時，選取所有相關來源共享證明；未涵蓋、重疊或主機不符時停止，不猜選其中一個。

新主機匯入材料後重新觀察／比較，建立本次計畫子集的決策收據。還原預覽、明確還原、機械驗證、業務接受與啟用各自獨立。取消後以新決策明確續作；同一 OperationId 只查詢既有結果，不盲目重送。既有未屬於本次操作的目標檔案不會因重試而被覆寫。來源版本、選用版本、目標觀測版本分開顯示；選新版不會修改已封存來源事實，也不代表相容性已確認。

頁面更新只讀取已保存的盤點與驗證證據。建立還原預覽與執行還原時才重新檢查目前軟體及材料，預覽失效後需重新操作。機械驗證、接受條件檢查各有明確操作與保存結果；重新整理頁面不會補寫 journal 或替操作者執行接受檢查。後續 Final 驗證追加日誌，仍可核對先前綁定同一還原作業的 Staged 驗證證據。

## 離線完整備份、結果查看與新機還原

適用於離線完整集合（CV2）計畫：C 槽與其他磁碟上已核准的資料，會封進同一份離線備份，新機只靠這份備份與工具即可還原，不必回頭連舊機或舊 Manager。CV2 計畫不使用非 C 直傳：直傳與直傳結果匯入遇到 CV2 計畫會被拒絕。CV2 計畫也不使用交付收據：匯入收據會被拒絕，交付以舊機的「備份結果」頁為準，Manager 的進度顯示「CV2 的交付以備份結果頁為準」。已建立的舊格式計畫仍依前一節的原通道接續，不轉換格式。

Manager 核准 CV2 計畫時，會在計畫檔旁另存 `<計畫檔名>.source-snapshot.json` 附件（核准當時的來源盤點快照）；交付計畫給舊機時須連同這個附件一起交付，並放在計畫檔旁。舊機匯入計畫時會以核准雜湊核對附件，不符即拒絕；找不到附件時計畫仍會匯入，但「開始備份」會被拒絕，直到補上附件並重新匯入。

### 備份與進度

1. **一鍵備份**：在舊機的精靈按「開始備份」（接續同一個 attempt 時，按鈕為「明確續作此備份 attempt」）。備份在背景執行，關閉頁面不會中斷備份。「一鍵備份進度」卡片顯示：
   - 狀態：○ 等待中、▶ 執行中、■ 取消要求中、⇢ 等待交付、✔ 完成、⚠ 部分失敗、✖ 失敗。
   - 步驟：「第 n 步／共 3 步：階段名稱」，三步依序是「擷取與封存」「驗證封裝」「交付」。
   - 目前工作負載、目前項目識別碼與型別、通道（C 槽或非 C 槽）、目前檔案、檔案（已處理／總數）、項目（已完成／總數）、位元組（已處理／總數）、經過時間、最後更新，以及「最近完成」清單（最多 20 筆）。

   步驟與百分比只表示作業進行到哪裡，不是備份覆蓋率；舊版紀錄缺少的欄位顯示「未記錄」或「未知」，不補零。備份交付後、獨立副本尚未驗證前，狀態是「等待交付」，不是成功；獨立副本驗證通過後才顯示「完成」。計畫含人工、外部或不支援項目但交付已驗證時，狀態顯示「完成（含待人工處理）」，並註明項目數。非 C 磁碟上「只選部分檔案」的範圍目前尚未支援，必須以整個範圍納入。
2. **取消備份與確認**：進度卡片的「取消備份」，以及「作業與交接」頁的「要求取消」，都會先開啟「確認取消這次作業」視窗。警告說明取消後這次作業不會繼續、已完成的項目會保留、未完成的部分需要重新開始，而且取消要求送出後無法收回。只有按「確定取消」才會送出；按「返回」或 Esc 不會送出任何要求，焦點回到原按鈕。取消要求不等於已停止：卡片顯示「取消要求中」，等狀態變成已取消才代表作業已到安全停止點。
3. **失敗、取消與未完成的嘗試**：已經有交付之後，比該交付更新的失敗、已取消或未完成嘗試，會以「較新的嘗試：失敗／已取消／未完成」區塊與備份結果並列，附時間、失敗項目、原因與下一步。擷取失敗的原因碼只有「路徑太長」（超過 239 個字元）、「檔案被鎖定」、「途中被刪除」、「沒有讀取權限」與「其他錯誤」；畫面只顯示範圍根下第幾層與檔名，不顯示完整路徑。擷取是整批成敗，所以失敗項目顯示的是核准範圍的來源路徑（或「沒有檔案路徑」「無法核對來源路徑」），不是實際出錯的那一個檔案。備份紀錄資料夾內有無法讀取的舊紀錄時，結果頁顯示「發現 N 個無法讀取的備份紀錄」（只列檔名）；這些紀錄不會被當成備份，也不會擋住新的備份。
4. **查看備份結果**：「備份結果」頁有三個分頁：
   - **已備份**：已封存的項目，附原位置、通道、檔案數與大小；每個項目可展開查看「封存檔案」明細（相對路徑、大小、SHA-256 前 12 碼、類型，分頁顯示）。
   - **未備份**：未選入、明確排除、需人工或外部處理、沒有擷取到內容的項目，每列附原因與下一步。UNC 路徑列在這裡，並標示為「沿用外部共享，未備份」或「另行遷移，見核准」；工具不複製 UNC 路徑上的內容。
   - **安裝軟體**：舊機上發現的軟體清單（含版本、發行者與新機決策），以及 Windows 角色與功能的 `Install-WindowsFeature` 名稱，供您在新機自行安裝；工具不會自動安裝。軟體決策有「新機重新安裝」「可攜版，隨資料搬移」「保留相容版本」「由外部處理」「新機不需要」「特殊產品，人工處理」六種，加上「尚未決定」。

   每個分頁都可以搜尋、翻頁、匯出 CSV；CSV 只含資料列，不含逐檔清單。交付資料夾與獨立副本中另有 `backup-report.html`，在任何電腦直接雙擊即可離線查看同樣的三個分頁。離線報告的每個已備份項目最多列出前 200 個檔案（相對路徑與大小）及總數，整份報告合計最多 5000 筆；超過上限時註明「完整明細見工作台或 artifacts 索引」。關閉 JavaScript 時，檔案清單仍以可展開的靜態區塊呈現。它顯示的是擷取與封存當時的狀態，不代表媒體目前仍然完整。
5. **離線還原就緒與獨立副本**：備份完成後，「備份」卡片的「離線還原就緒」會顯示目前狀態：「尚未完成交付」「等待建立獨立副本（舊機關機後還無法還原）」「獨立副本已驗證」「獨立副本已驗證（網路位置：請在新機確認可以存取）」，或「獨立副本收據完整，但媒體需重新驗證（舊機關機前請先確認副本還在）」。在「建立獨立備份副本」的「獨立副本目的資料夾」輸入位置，選擇「由工具複製並驗證」（按鈕「複製並驗證」），或在已自行複製時選擇「我已自行複製，只要驗證」（按鈕「驗證既有副本」）。工具逐檔比對雜湊，並另存驗證收據。
   - **目的位置的媒體類型有四種**：可移除磁碟驗證通過即為「獨立副本已驗證」；網路位置驗證通過後仍需在新機確認可以存取；舊機本機的固定磁碟不算獨立副本，會被拒絕；無法判定媒體類型時同樣被拒絕（例如本機的非管理共用）。目的位置必須是絕對路徑，不接受裝置路徑（如 `\\?\C:\`）、替代資料流與 `..`，而且必須位於舊機工作區之外（以實體路徑比對，subst 與 junction 換拼法也擋得住）。指向本機的 UNC 寫法（`\\localhost\C$`、本機名稱、環回位址）會折回實體磁碟再分類，不會因為是 `\\` 開頭就算成網路位置。
   - **人工複製的目錄結構**：副本一律在目的位置下的 `<目的>\wsm-offline-<PairId>-<AttemptId>\transport\…`。Directory 交付放 `transport\delivery-<編號>.json`（交付摘要）與 `transport\delivery\` 內的全部成員；ZIP 交付放 `transport\transport.json` 與同一資料夾的全部分卷。另外有 `transport\backup-item-results.json`、`transport\backup-report.html`、`transport\offline-guide.html`、`transport\offline-guide.txt`（備份產生它們時）。選「我已自行複製，只要驗證」時，工具就在這個結構下核對；缺檔、大小或雜湊不符、多出未列入的檔案都會驗證失敗。
   - **容量預檢**：「由工具複製並驗證」會在寫入任何檔案之前，比較目的位置可用空間與尚未到位的位元組數（含 256 MiB 緩衝）。空間不足時以「InsufficientSpace」拒絕，寫入前就停止，先前的收據不受影響。取不到可用空間（例如網路位置查詢失敗）時顯示警告並繼續複製，收據記錄為容量「Unknown」；空間不足會在複製中途失敗。「我已自行複製，只要驗證」不做容量預檢。目的位置已有同名檔案時，內容相同就略過，內容不同就拒絕，請改用空的位置。
   - **收據與 LastAttempt**：驗證通過會另存收據。之後同一個備份的另一次獨立副本失敗或被取消，不會抹掉先前已驗證的收據；那次結果另存為 LastAttempt，並以「較新的嘗試：失敗／已取消」與原因、下一步並列顯示，之後成功就清除。只有失敗發生在收據自己的媒體位置上（例如重新驗證發現檔案被改動）時，收據才會標記為需重新驗證，不再顯示為已驗證。
   - **收據完整；媒體需重新驗證**：副本媒體被刪除或缺檔時，備份結果頁的「獨立副本」欄改顯示「收據完整；媒體需重新驗證」，附收據時間與「重新驗證」按鈕，「離線還原就緒」改顯示上面列出的「獨立副本收據完整，但媒體需重新驗證」；按下後以「我已自行複製，只要驗證」的模式核對收據所在位置。網路位置在讀取時不探測是否存在，所以網路媒體被移除時不會自動標出，需要按「重新驗證」。
   - 只有在獨立副本驗證通過後，舊機關機才不影響還原；但驗證通過不代表可以退役舊機，「獨立副本」欄只表示備份可取用（收據在每次讀取時重新核對），舊機何時可以關閉，仍須另依停機窗口與負責人確認。

### 新機接收、選擇與還原

文字備援：主選單 22 進入「目標」角色後，選項 3 還原預覽、4 還原／重試、10 回復預覽／執行、11 修復 checkpoint、16 還原後重新核對（唯讀）。

6. **新機接收**：在新機匯入備份並完成本機盤點後，若沒有舊 Manager 可提供比較材料，可按「在本機產生比較」（說明為「沒有舊 Manager 時，在本機產生軟體比較（離線）」），用已驗證的備份與本機盤點產生軟體比較。這份比較不含 Manager 端選定的軟體版本，僅供參考。
7. **選擇還原項目**：建立決策收據時，預設勾選所有可還原、且尚未還原過的項目，依網站、排程、資料範圍、設定分組，並提供「全選」與「全不選」。每個項目可展開查看前 100 個檔案的相對路徑與總數。需人工或外部處理的項目會列出但無法勾選；已有不同內容檔案造成衝突的項目也無法勾選。再次還原時，已還原的項目不會預先勾選。「建立決策收據」在責任人或理由空白時，按鈕顯示為停用並附原因說明（用鍵盤仍可聚焦）。還原作業進行中（執行中、排隊中、取消要求中、等待輸入、已中斷）時，選取與決策收據一律鎖定。
8. **還原到原位置**：看完還原預覽後，按「開始此預覽的還原」。資料一律寫回原本的路徑（例如 `D:\Sites` 還原到 `D:\Sites`）。新機缺少該磁碟或空間不足時，該項目會標示「請準備相同位置後重新檢查」，工具不會改寫到其他磁碟，也不會覆寫既有的外部檔案。容量預檢把寫入量與必要的回復保留空間（staging 放在不同磁碟時也計入）一併計入，已還原的項目不重複計算；單一項目就超過可用空間時只擋那一項，各項單獨夠、合計不夠時，同一磁碟上所有待寫項目都標示容量不足。還原完成不會自動啟用網站或排程。
9. **重試失敗項目**：還原結果為部分完成（有項目未成功）時，結果旁顯示「同一份還原選擇再按一次只會顯示上次結果，不會重做；要重試失敗項目請按「重試失敗項目」（或回精靈重新保存選擇）。」並列出上次已成功、未成功與可重試的項目數。按「↻ 重試失敗項目」會自動產生只含失敗項目的新選擇紀錄（決策收據）；責任人預填上一份收據的責任人、理由預填「重試上次部分完成中未成功的 N 個項目（來源收據 前 12 碼）」，兩者都可修改且都必填。建立收據不會開始還原，仍須回到還原預覽確認後，由您按下開始還原。
   - 未成功的狀態：失敗、延後、帳密被拒、需先對帳、相依未知、受阻擋、目的衝突、需人工證據、已取消、部分，以及沒有結果的項目；成功與需重新開機視為成功，不重試。
   - 不會列入重試的項目附原因：目前無法還原（例如目的已有不同內容的檔案）、等待重新核對的項目等。有尚未清除的未完成寫入紀錄時整體不可重試，顯示「請先修復未完成的作業」；先執行修復（HTML 動作「修復」，或目標選項 11「修復 checkpoint」），再重試。
   - 全部成功、還原進行中、等待輸入或已中斷時不顯示這個區塊；還原已被回復時顯示「已回復，請重新選擇還原」，回復後的項目重新選取即可，不屬於「重試失敗項目」。
10. **沿用既有檔與回復**：目錄範圍的目的位置若已有「不是工具寫入」的檔案，工具逐檔比對：
    - 內容雜湊等於備份、且不是 reparse point 也不是資料夾：記為「沿用既有檔」。不重寫、算成功；畫面顯示「沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。」
    - 內容不同：整個項目判為目的衝突，原因寫「目標已有不同內容的檔案，需先人工處理（衝突 N 個檔案）」，不覆寫、不可勾選，也不列入重試。
    - 單檔範圍遇到同內容的外部檔，還原時同樣判為目的衝突，不自動沿用；只有「修復」對帳時，內容雜湊等於備份的檔案才會補登為沿用既有檔，其餘（內容不同、reparse point、資料夾佔位、讀不到）保留原檔、記為衝突，處理完再修復一次。
    - **回復時**（目標選項 10「回復預覽／執行」，確認字串 `ROLLBACK <PairId>`）：沿用既有檔不刪除、不覆寫、不改 ACL、不還原 metadata；它被改動只回報、不修正。回復後項目重新選取就可再還原，沿用既有檔會再次沿用。套用或回復目錄 ACL 時，沿用既有檔的安全描述元會先保存、事後原樣寫回，不被繼承改寫（不處理 SACL）。
    - 先前寫入失敗而沒有完整擁有紀錄的檔案範圍，會顯示「需先對帳」，由「修復」處理：目標檔不存在視為尚未寫入；內容雜湊等於備份的補登；其餘保留原檔並記為衝突。
11. **還原後重新核對**：安裝軟體、重新開機或調整權限後，已還原的檔案與設定可能被改寫。按「重新核對」（目標選項 16）只讀取目前內容並與還原時的記錄比對：不覆寫、不刪除、不改權限，也不開始還原。漂移的項目由成功降為「待核對」並附原因，沿用既有檔漂移時同樣只回報；無法讀回的項目標為「無法自動核對」，不當成吻合。待核對的項目不進「重試失敗項目」，要重新還原必須明確選取，且仍受目的衝突與擁有紀錄保護。

目前限制：可移除磁碟與網路位置的實機複製、非 C 磁碟的實機擷取與還原、企業環境驗收仍未完成；正式環境資格維持未放行。

## Manager 端：來源候選確認、工作負載對應與軟體處置審閱

這些畫面只在「整理搬移資料的電腦」（Manager）有核准計畫要處理的配對時出現，掛在精靈的準備與交接步驟。每一步只建立待審結果，不代表核准；送出會使既有核准失效，需重新審閱並重新核准。讀取過期（決策 revision、預覽雜湊或確認雜湊已變動）時，畫面只提示「重新讀取」，不會自動重送，也不會替您改用新版本。

**來源端（C2 的前置，D2 的來源）**：舊機在「來源候選確認（挑一個候選並匯出）」從候選掃描結果挑選一個候選，按「匯出確認材料」。匯出會逐檔讀取內容並計算雜湊，但不核准、也不建立檔案範圍。畫面顯示確認材料位置與 SHA-256；把檔案與雜湊用可信管道交給 Manager，雜湊必須另外告知，不要只靠檔案本身。

**D2：候選確認與工作負載對應**（面板「來源候選確認與工作負載對應（管理端）」，三步依序）：

1. **步驟 1：匯入確認材料**：填「確認材料檔案位置」「確認材料雜湊（SHA-256）」「原始路徑（與來源相同）」「負責人」「證據參考」，按「匯入確認材料」。原始路徑必須與來源候選的位置完全相同，匯入不會重新對映；匯入只建立待審項目。
2. **步驟 2：檢視確認內容**：選已匯入的候選項目，按「檢視確認內容」，核對成員總數、檔案與空目錄數、工作負載引用數、範圍根目錄與兩個雜湊，再按「進入工作負載對應審閱」。
3. **步驟 3：工作負載對應審閱**：每一筆工作負載引用（排程工作的執行檔、起始資料夾、參數中的路徑等）都必須明確選一項：「對應到已確認的範圍」「不對應（此路徑不屬於已確認範圍）」或「人工處理（稍後自行處理）」；內容不透明的引用只能人工處理，工具找不到唯一涵蓋該路徑的範圍時也不能選「對應」。選「對應」時另選依賴關係：「不建立依賴」「必要依賴（缺少則工作負載停止）」「選用依賴」。按「檢視並送出對應審閱」，在確認視窗按「確認送出」後，使用這些路徑的相依項目回到待審閱。

位元組相同的確認材料重複匯入，或送出的對應與已記錄的完全相同時，結果為「未變更」（NoChange）：匯入時畫面顯示「完成：確認材料與先前匯入的內容完全相同（項目 …），沒有變更任何決策或核准。」，對應審閱則顯示「完成：送出的對應與目前已記錄的完全相同，未變更任何決策或核准。」；決策 revision 與核准都不動；內容不同時才照常回到待審閱。

**C2：軟體處置審閱**（面板「軟體處置審閱（管理端）」）：

- 清單列出來源主機的全部軟體，欄位為選取、軟體、範圍、目前處置、待送出；可依名稱與處置狀態（全部、尚未決定、已決定）篩選，並提供「全選目前顯示的項目」與「全不選」。上方列出「尚未決定的軟體」筆數與清單，這只是清單，是否阻擋核准以核准時的核心檢查為準。
- 每一列的處置狀態是「✔ 已審閱：（處置名稱）」「⚠ 證據已變更，需重新審閱」（Stale）或「○ 尚未審閱」（Reviewed／Stale／Unreviewed）。
- 處置值有六個：「重新安裝」（Reinstall）、「可攜（免安裝）」（Portable）、「保留相容版本」（KeepCompatible）、「外部處理（工具不處理）」（External）、「不需要搬移」（NotNeeded）、「尚未確認（Unknown）」；備份結果的「安裝軟體」分頁另顯示「尚未決定」（Undecided，沒有任何處置時）與「特殊產品，人工處理」（SpecialProduct）。套裝本體（特殊產品）只能選「外部處理（工具不處理）」或「不需要搬移」，因為工具不重裝或搬移這類產品本體；前端限制被移除時後端仍會拒絕。
- 批次：勾選軟體，選處置，填「負責人」「原因」「證據參考」（三者必填），按「套用到已選項目（暫存）」；確認「待送出的處置」後，按「檢視確認摘要並送出」。確認視窗「確認送出軟體處置」須勾選「我已核對上述內容，確認送出（Ack）」，再按「確認送出」。送出時帶預覽雜湊與決策 revision，過期就整批拒絕，不套用任何一筆。處置不代表就緒或核准，送出後需重新核准。
- **Stale 與預填**：重新匯入盤點或換軟體目錄後，軟體事實雜湊已改變的決策不會被刪除，而是保留為 Stale，連同原處置、負責人、原因與證據一起留在審閱資料列（欄位 Disposition、Owner、Reason、Evidence）。Stale 決策不在有效決策集合內，計畫與核准看不到它。目前畫面只標示「⚠ 證據已變更，需重新審閱」，不會自動把前值填進批次表單；負責人重新選擇處置並填寫後送出，才轉為已審閱。

## 本機工作台的安全邊界

HTML 工作台只綁定 `127.0.0.1`，並檢查 Host 與 Origin；寫入請求（POST）必須帶符合本機位址的 Origin。工作階段 token 由本機工作台提供給畫面使用。**本機 HTTP 工作台的 token 只防瀏覽器跨站請求，不防同一台主機上的其他使用者或程序；多人共用的工作階段主機請勿開啟。** 取得 token 的同機程序可以代表這個工作台的 Windows 身分提交操作，所以多使用者的遠端桌面主機、共用的跳板機不適合啟動工作台，請改在只有授權操作者登入的主機使用，或使用文字備援。

## 進階操作與既有核心契約

以下既有詳細契約適用於資訊人員使用的進階工具及核心操作；當前 UI 精靈尚未把每個進階核心操作接成一般使用者旅程。

## HTML 工作台基線

工作台已實作八個頁面：工作總覽、盤點與選取、軟體差異、檔案與路徑、操作中心、作業與交接、說明與教學、文件中心；以 hash 連結導覽，可使用瀏覽器上一頁／下一頁及有效直接連結。教學經本機資源 `/ui/guide.html` 提供，完整手冊與文件中心可另開；文件中心按起步、角色操作、差異與清單、設定／路徑、驗證／交接、恢復／疑難分類。請先閱讀[主機搬移操作指引](../src/ui/guide.html)及[完整操作手冊](ASSISTIVE-OPERATIONS.html)；離線文件頁不能替代工作台當下的資料、核心檢查或核准。

Source、Manager、Target 是操作上下文，不是登入身分或權限授予。各主機本機執行；Manager 匯入可信材料並審閱，不能以 Manager 角色遠端操作 Target。Owner 欄位是責任聲明，不驗證填寫者。

第四輪常用任務以具名 action 與 typed 表單呈現，完整進階 allowlist 可搜尋。第五輪增加用途導引與保存的精靈選取，第六輪接入封裝、非 C 交接及目標還原；完整原生旅程尚未通過驗收。以下 action 說明保留進階操作契約，實際一般入口與證據範圍依本輪 PLAN 核對。`Inventory` 在 Source 或 Target 本機的 Windows Server／管理員／64 位 FullLanguage PowerShell 執行；`ImportInventory` 匯入來源盤點並核對獨立可信 SHA-256；`AssistiveEnable` 使用目前配對／角色上下文。目標端先取得可信目標盤點，再由 Manager 提交 `TargetSnapshot`（目標材料路徑及其可信 SHA-256）並 `PublishComparison`；重新載入舊比較不會重新探測目標。只有有效核准後才可進入封包、還原及後續驗證。表單欄位不涵蓋所有專業證據欄位；不確定時查手冊及核准流程，不以空值或自填路徑繞過檢查。

工作階段過期時，請留在原分頁按「重新連線工作階段」。非敏感草稿只留在該分頁記憶體；工具核對工作根目錄、角色、配對與材料版本相符後才沿用，舊預覽與確認一律失效。切換工作或版本變更時會封鎖寫入並要求明確處置過期草稿。重新載入或關閉分頁不保留未保存草稿；已保存內容仍以工作目錄內的正式記錄為準。敏感輸入需重新提供。

操作結果請回到「作業與交接」按權威 OperationId 檢查。提交逾時或回應中斷時，先查是否已有該工作紀錄，不要盲目重送。關閉瀏覽器、停止本機 PowerShell 程序及要求取消是不同動作；取消要求不代表工作已停止。報告以經驗證的路徑與 hash 交由 Windows 預設應用程式開啟，可能另開視窗或程式，不保證是瀏覽器新分頁。

功能與驗證範圍見[實作狀態](IMPLEMENTATION-0.1.md)，分版本證據集中於開發 PLAN。提交等待期間再次保存會被阻擋；保留第一筆 OperationId，先查清其權威結果再決定後續操作。

原始傳輸完整性仍為 **NotPassed**：保留 AdGuard 設定的本機環境曾觀察到回應差異。後續獨立 Windows CI 已驗證真 Edge／正式 handler 的讀取、可逆保存、隔離 Source Directory／ZIP 備份與 Target 真還原／hash／journal 讀回。這不代表本機原始傳輸差異已解決；受控身分／觀測不等於真實業務服務驗收。Node mock 或隔離 fixture 不能代替尚未驗收的真實路徑、企業主機及業務驗收。`ProductionVerified=false`、`ProductionExecutionEnabled=false`，發行包未簽署。

本版目前僅供明確批准的隔離 pilot。來源、目標與管理工作區各自本機執行。不得用此文件宣稱實際十台已完成遷移。

第2輪一般主機請先依 [完整操作閉環](GENERAL-HOST-WORKFLOW.md) 完成stable enrollment、完整軟體確認、typed preparation／Oracle／Windows設定及ZIP或Directory交付；下方既有旅程仍受該契約約束。

## 離線旅程

1. 先確認本版是否有精確的企業資格與放行；目前 production 為 Blocked／NotTested，生產執行維持關閉。管理端可用 `Export-WsmToolRelease` 產生含檔案 manifest、SBOM、支援矩陣與 runbook 的 ZIP。企業 ReleaseSigner 對最終 ZIP bytes 做 detached CMS 簽章後，接收端用 `Test-WsmToolRelease` 核對獨立提供的 archive／signature／trust-policy SHA256、manifest、精確工具 fingerprint、角色 signer/root pins 及本機快取 CRL。驗證不啟動 OCSP／CRL/AIA 網路查詢；無法在離線環境驗證有效撤銷資料時即阻擋。ZIP 不加密，機密傳輸需另用企業核准方式。詳見 [正式資格與發行信任](RELEASE-QUALIFICATION.md)。工具不會修改 policy。
2. 來源選 1 盤點。每台固定其受控狀態目錄；有權限時選深層探索。輸出設定 JSON、盤點 ZIP 及能力／失敗項；原始設定可能含敏感資訊。可在角色精靈來源端匯出 raw evidence 索引。
3. 管理端建立工作區、匯入可信盤點並配對目標暫用名稱；匯入兩份 catalog／fleet 採持久交易。若中斷，所有後續读寫阻擋，選精靈管理端「工作區交易修復」，保留 transactions 證據。
4. 每類逐項決定 Include／Exclude、排除理由、責任人、未知項的補查證據；大量資料用 CSV／跨頁规则 preview／undo／條件模板。分類 HTML 每頁 100 列，同名文字檔保留完整清單。
5. 目標精靈登記 TargetIdentity，將 JSON 及獨立可信 hash 交管理端。管理端對每個 Include 設定 MigrationSpec、必要相依、資料 scope／排除／最終狀態；需要 SID 改映時另核准 IdentityMap。
6. 管理端核准 MigrationPlan。必須確認 `ISOLATED-PILOT`；批准文件綁定主機指紋、版本、所有決策、規格及**工具精確位元組指紋**。更改工具後需重新核准，不能在中途替換工具。
7. 來源端先容量／scope 預檢，匯出 package。Immutable 適用不變資料；其他 scope 必須有來源責任人停寫證據。工具重新盤點並比對核准設定，不能靠舊 revision 替代現況。
8. 來源端分卷 ZIP，傳遞 transport.json、所有 ZIP 及獨立可信 hash。目標端受信匯入；索引、大小、路径、每塊和整檔均核對。中斷匯入可用同一 trusted transport 重試。
9. 目標還原 preview 顯示建立、驗證跳過、衝突、空間、回復與機密要求。一般同名設定／不屬於工具的資料阻擋。實際還原將排程、服務、IIS、使用者、防火牆規則保留停用，分享加存取阻擋。
10. 填寫每項 BusinessStaged；ManualWorkflow 另提供 ManualRestore 證據。執行 Staged 驗證並匯出結果，回管理端匯入。指令成功、hash 正確或 HTTP 200 均不能取代業務驗收。
11. 維護窗來源停寫，再匯出 final package。final 是新的完整 scope 快照，使用內容去重、綁定前一 manifest；目標只更換先前工具歸屬且未漂移的根目錄，原根目錄保留為 backup。所有舊代次證據失效。
12. 完成舊名稱／IP／網域身分釋放的專用程序及證據，重新驗證 final staging。產生切換計畫，再確認精確 `CUTOVER PairId`。若改名需重開機，工具回 RebootRequired，重開後重新核對再續行，不自動重開。
13. 必要跨主機 provider 需提供 24 小時內的 Cutover 成功結果及獨立可信摘要；無證據拒絕切換。循環跨主機應用需先建立有責任人與外部一致性程序的 GroupPlan，所有成員提供本代 FinalStaged receipt，再透過可信群組索引產生 CutoverPlan；缺少、過期、版本或 manifest 不符均阻擋。這是離線證據門檻，仍需實際應用停寫協調。
14. 啟用後逐項 BusinessFinal，以及 DNS／Kerberos／外部連線／監控／資安代理／許可／使用者接受。FinalAccepted 與 RetirementReady 分開；後者另需實際備份還原、長週期工作、觀察期和保留清理證據。工具只報告門檻，不刪除舊機。

## 規格與機密

`New-WsmMigrationSpecTemplate` 產生草稿，必須補足所有空白及產品特有設定再核准。FileScope 的 SourcePath／TargetPath 必須明確絕對路徑；ExcludedRelativePaths 是 literal 子路徑。Metadata 可用 DaclOwner 或 DaclOwnerSacl；後者需要來源與目標的安全權限。磁碟根目錄、reparse、ADS、EFS、未知 SID、重疊 workspace、未批准覆蓋會阻擋，不能默默漏掉。

大量 Include 使用管理精靈的「批次規格草稿／預覽／提交」：匯出帶 Batch／Pair／兩種 revision／SettingsHash 的 bundle，填完各列 MigrationSpec，先預覽件數、樣本與問題再 APPLY-SPECS。無效一列整批不寫入；删列只是不修改該項，不是排除。一次提交只增加一次 DecisionRevision，核准失效。FileScope 路徑目前採已驗證的 239 字元限制，更長路徑明確阻擋並需專用流程。

ACL 預設 `AclControlPolicy=Exact`，連 SDDL 控制旗標都須相同。不同 Windows 寫入 ACL 時可能新增 AI 自動繼承旗標；CI 已重現 ACE 完全相同而 AI 增加的情況。若企業批准此繼承模型轉換，可在 FileScope 明確設定 `AllowAutoInheritedUpgrade` 並重新審核；此政策只允許 AI 增加，owner／group／每個 ACE／P 與 AR 仍須精準相同，且不允許降級。這是核准的差異，不能宣稱 ACL 位元組完全還原。[Microsoft 控制旗標定義](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-descriptor-control)

IdentityMap 是 `{ "Mappings": [...] }`；每列需要 SourceSid、TargetAccount、ExpectedTargetSid、CreatedByItemId、Owner、Evidence。ExpectedTargetSid 可留空，由目標實際解析；CreatedByItemId 若指定，必須是納入的 LocalUser／LocalGroup。來源 SID 不會因主機同名而恢復。任意 runtime SID override 不接受。

SecretRef 只是代號。精靈按代號提示 PSCredential，密碼僅在記憶體；非互動有機密的操作可從 PowerShell module API 提供 `-Secrets @{代號=$credential}`。OperationRequest 不接受密碼或 Secrets 欄位。PFX 從外部受控材料取得，需 artifact hash；鏈憑證必須分開核准，禁止順帶匯入未列項。

ManualWorkflow 需要 Product、Procedure、Artifacts、BusinessChecks、Owner、Evidence，供 AD／CA／叢集／SQL／第三方安裝／許可等專用程序。這是明確的人工作業及證據門檻，**不是已實作該產品的自動還原**。未知角色不能自動排除。

## 非互動請求

```json
{
  "SchemaVersion": 1,
  "ToolVersion": "0.4.0",
  "Kind": "OperationRequest",
  "Action": "RestorePreview",
  "Arguments": {
    "ManifestPath": "D:\\Inbox\\manifest.json",
    "ExpectedHash": "填入獨立可信的64字元SHA256",
    "StateDirectory": "D:\\MigrationState"
  }
}
```

將請求另存並取得可信 SHA256，使用入口 `-Action Operation -Path ... -ExpectedHash ...`。`Get-WsmOperationActions` 列出白名單；每個動作參數使用相同 module API。請求只含 typed data，不允許任意命令、package scripts、Debug 或 common parameter 注入。

network JSON 欄位：FinalName、InterfaceAlias、FinalIP、PrefixLength、DefaultGateway（可選）、DnsServers、TemporaryIP、DomainProcedureEvidence、RollbackProcedure、Owner、MaintenanceWindowUtc、ValidUntilUtc，以及 ObservationHours（整數 1–8760；未填則切換計畫明列 24 小時）。自動 IP 切換目前只接受明確 IPv4；IPv6、多 NIC、LB、SPN／委派等走專用審核程序。DomainRename 可經 API 記憶體 Secrets 提供網域憑證。

provider 證據索引：`{ "Entries": [{ "Path": "D:\\Inbox\\provider-result.json", "SHA256": "獨立可信摘要" }] }`，交給 CutoverPlan 的 DependencyEvidencePath／DependencyEvidenceHash。

## CLI 返回碼與等待輸入

非互動入口（`-Action` 各項、`Operation`、`OperationRequest`）與文字選單使用同一組返回碼：

| 返回碼 | 意義 |
|---|---|
| 0 | 成功；只表示該操作完成，不表示整台遷移完成 |
| 1 | 失敗 |
| 2 | 等待輸入，或被阻擋（Blocked；尚待人工證據、重新開機或補裝） |
| 3 | 取消，或輸入結束 |
| 4 | 契約或輸入錯誤（缺 `-Path`、`-ExpectedHash` 缺漏或格式錯誤、檔案不存在、JSON 損壞、不合法的 `-Workspace`） |

- **等待輸入**：入口遇到「等待輸入」時，印出一行 `Status=WaitingForInput ParentOperationId=<作業識別碼> MissingFields=<缺少的欄位>` 並以 2 結束；錯誤說明另寫到標準錯誤。`ParentOperationId` 只有等待的是某個還原母作業時才有，`MissingFields`（欄位名稱以逗號分隔）只有已知缺什麼時才有。會這樣結束的情形包括：文字選單的型別化操作（22 → 4 → 2）在輸入結束時必填欄位還缺（已輸入的值不落盤；需要帳密的欄位不會從重新導向的輸入讀取，而是列為缺少）；還原在等帳密；RESUME 提示遇到輸入結束；以 `-NonInteractive` 啟動 `-Action Menu`（`MissingFields=Menu 選項`）。母作業保留，之後在互動主控台或 HTML 畫面接續，不需重做已完成的項目。
- **文字選單的返回碼**：`-Action Menu` 離開時回傳執行期間所有型別化操作與進階 OperationRequest 的最差狀態碼，嚴重度由低到高為 0、2、3、4、1。輸入結束時的基準是 3（等待輸入時結束的基準是 2），不會蓋掉已記錄的更差值；沒有任何失敗就輸入 `0` 離開，返回 0。取消 APPLY 確認不算失敗。
- Hash 與檔案內容不符屬於一般失敗，不是上表的 4。

## 還原時的帳密等待、延後與續作

還原計畫含 Windows 服務、排程或 IIS 應用程式集區的帳號時，需要帳密（以 SecretRef 分組，同一組帳號用於相同的所有項目）。帳號以核准計畫中的為準（畫面上該欄唯讀，說明為「帳號由還原計畫核准，無法在這裡更改」）；密碼只交給本機工具的記憶體使用，不寫入工作紀錄、備份或報告，OperationRequest 也不接受密碼或 Secrets 欄位。

- **等待**：缺帳密時，還原母作業停在「等待輸入」，已完成的項目不會重做。HTML 的作業頁顯示「還原暫停，需要帳戶密碼才能繼續」與「輸入帳密以繼續」。
- **HTML 輸入視窗**（「輸入帳戶密碼以繼續還原」）：每一組列出用途（Windows 服務、排程工作、IIS 應用程式集區）與使用這組帳密的項目。可按「延後這組」，這組的項目本次不會還原、其他項目照常進行，按「改回輸入」可復原；送出按鈕為「送出並繼續還原」，全部延後時為「延後並繼續還原其他項目」。另有「稍後再輸入」與「取消這次還原」（再按「確定取消」或「返回」）。
- **密碼被拒絕**：該組項目沒有留下任何變更，視窗顯示「上次輸入的密碼被拒絕，未對這些項目做任何變更。請確認後重新輸入（第 n／3 次）」。同一組被拒絕 3 次就自動延後，顯示「已達重試上限，請確認帳號狀態後在新的還原中處理」。
- **DEFER**（文字選單）：每一組提示「輸入 DEFER 延後這一整組帳密（相關項目本次不還原，之後在新的還原中再處理）；直接按 Enter 則輸入帳密」。延後的項目狀態是「延後」（Deferred），之後在新的還原中處理，也會列入「重試失敗項目」的候選。
- **RESUME**：還原程序中斷（Interrupted）後，HTML 顯示「還原程序中斷，已完成的項目會保留」與「檢視恢復預覽」：列出「結果需要核對的項目」，勾選「我了解並要繼續這次還原」後按「繼續還原」。文字選單提示「輸入 RESUME 續作父作業 <作業識別碼>；其他值不動作」。續作只接續同一個父作業並逐項對帳，不重寫已確認完成的項目；輸入結束不算決定，以等待輸入（返回碼 2）結束，保留原父作業。
- **TAKEOVER**：等待帳密的挑戰屬於較早的視窗或 CLI 工作階段時，要由目前這個視窗接手。HTML 勾選「由這個視窗接手此還原（原本的視窗已關閉時才勾選）」；文字選單輸入 `TAKEOVER`，不輸入就不會接手，也不會續作。
- **標準輸入被重新導向**（管線或檔案）時，工具不會從重新導向的輸入讀取帳密，而是在詢問之前就以「等待輸入」（返回碼 2）停止；請在互動式主控台或 HTML 視窗輸入。

## 中斷、重試與回退

同一配對只允許一個本機寫入者。檔案鎖依作業系統 handle，不能為「解鎖」刪除 state／journal。每個事件先 flush，再更新 checkpoint；中斷造成日誌比 checkpoint 超前時，選目標「修復 checkpoint」，核對整條 hash chain 及原 checkpoint 前綴後重播。未知／毀損事件阻擋，保留證據。

FileScope 使用核准根目錄旁的生成 staging／backup；prepared checkpoint 必須與實際目標或 staging digest 一致才能採認／完成搬換。無法對應實際狀態時需要人工協調。切換每個物件先寫 ActivationIntent，原生啟用後再寫完成紀錄。中斷後選目標「明確續行啟用」，提供負責人與協調證據；只有 exact-staged 或 exact-final 狀態可續行／採認，漂移與不明半完成狀態保留現場並阻擋。其他 adapter 原生半完成情境仍依實作清單驗證。

回退先輸出具體 preview hash，再確認 `ROLLBACK PairId`。只移除工具建立的物件，或更換先前歸屬的根目錄；保留回退時的新資料根目錄。目標可能已有新交易時，強制 RollbackReconcile 證據，絕不自動啟舊來源。角色移除、網域／名稱／IP 回復依核准專用程序，避免兩台同時接手寫入。

工具鎖與 journal 不抵抗本機 administrator 改寫，可信來源、企業權限与材料交換仍是管理責任。

來源停寫先保存原始設定及啟用狀態到受控 SourceFreezeAttempt。部分失敗不產生成功 handoff；錯誤給出 attempt 路徑與摘要，使用 PreviousAttemptPath／PreviousAttemptHash 重試。重試會核對原核准基準，只容許已發生的停寫差異，不會把其他設定漂移當作新基準。過期 freeze 可透過 PreviousFreezePath／PreviousFreezeHash 更新，但仍須重新提供 owner 證據。

來源回復是獨立的明確操作：管理精靈來源角色「明確回復來源」或 SourceResume API，先核對原始狀態，再確認 `SOURCE-OWNERSHIP-RESTORED PairId`，提供目標已停写／資料已協調／來源擁有唯一寫入權的證據。工具才回復服務／IIS 原本的 startup／enabled／running 狀態與分享原始 ACL。排程只回復 enabled，不會重新執行被中斷的工作；原本 Running 的排程必須先提交 SourceTaskReconciliation JSON 與可信摘要，逐項證明已協調或無待處理工作。來源選項 8 可輸出待填草稿，草稿本身不能解鎖回復。這是人工確認的離線所有權交接，不能抵抗另一台主機被另外啟用；不會因目標回退自動啟動來源。同一来源配對的 freeze／resume 共用本機操作鎖。

## 漏跑政策與操作取消

ScheduledTask 規格必須填 CatchUpPolicy，草稿 ReviewRequired 不可核准。PreserveSourceSettings 保留 XML 的 StartWhenAvailable；SkipMissedRuns 與 DedicatedManualCatchUp 會將它設為 false。專用補跑須由 owner 依 BusinessChecks 提供不重複交易的程序及驗收；工具不執行任意補跑腳本，這個選项不表示已補跑成功。

各步驟輸入 0 取消，需字面文字 0 時輸入 literal:0。審核子選單錯誤保留原頁，篩選全部輸入且驗證成功才更新。輸入結束會退出，不無限重試。網域改名認證由目標精靈詢問並使用 DomainRename 記憶體 credential；認證不寫入請求與包。

分類報告列出 scope、排除、一致性、metadata、ACL／漏跑政策、最終啟用狀態及規格雜湊；Desired 原始配置保留於受控 catalog，報告只附其 hash。正式 owner 審核仍需閱讀受控 Desired，不能只看 hash 判定正確。

來源與目標工作目錄不可和資料 scope 相等、包含或被包含。來源 freeze／resume 及目標預覽／還原在建立操作目錄之前先檢查，避免工具證據混入業務資料。

## 檔案回退中斷

檔案回退先寫 durable RollbackIntent，保存目前內容與前代備份雜湊、固定的 displaced 保留路徑。若中斷，先執行 RepairOperation；它驗證 target／retained／backup 是否符合原意圖，再完成原來的重新命名。任何內容漂移都阻擋，不刪除現場。已回退項目不會再次選入新回退预覽；新交易可能存在時仍必須先有有效 RollbackReconcile owner 證據。設定回退不會自動啟動來源或代表交易資料已安全回復。

## 實體路徑、大索引與錯誤診斷

在實際來源／目標，以既有祖先的檔案 handle 取得 NT 裝置路徑，再附上尚未建立的子路徑，檢查 SUBST／多磁碟代號造成的同一實體資料碰撞。管理端仍只做文字映射預檢；實際目標要再次核對。重解析點明確阻擋。SMB／遠端 UNC 的伺服器與 share 別名目前沒有通用可靠判定，generic FileScope 阻擋並要求専用 alias／ownership 流程，不能把它視為已完成的 UNC 遷移。API 依據：[GetFinalPathNameByHandleW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew)。

包驗證串流讀取受信任 JSONL，同時逐 chunk／整檔驗證；重複目的地使用固定 5,000 個鍵 hash 的緩衝及最多 64 路的磁碟合併。檔案 metadata 核對型別、資料／目錄、ACL、UTC、bytes；實際還原亦比較 creation／last-write 时间。時間戳記單獨漂移也會阻擋重試。ADS、junction、鎖住檔案與未驗證長路徑不會靜默略過。

選單錯誤另顯示 Category／NativeCode／Hint；timeout、權限、容量、檔案鎖、無效輸入、查無服務及待刪除服務有個別處理建議。還原失敗的 item 與 durable journal 保留原生碼和分類，不含 stdout／參數／密碼。建議不會自動重試有副作用的操作；先核對實际狀態。

SMB 分享完整比對所有預期 ACE，額外授權也屬漂移，帳號以目標 SID 比對；Everyone 的顯示名稱依本機語系解析。啟用只移除工具的暫時 world deny，規格原先明確要求的 world deny 會保留。Block-SmbShareAccess 只能建立 Full deny，Read／Change deny 必須専用流程；它們不會被工具默默放大。停用分享不表示已關閉所有既有 SMB open handles，停寫與資料協調證據仍必須包含既有客戶端的排空／關閉。

一般 adapter 回退先寫 intent，再停用、驗證 staging 和刪除工具所建立物件；中斷後 RepairOperation 對已刪除的物件完成 checkpoint，不再次刪除。設定漂移或所有權／規格不符阻擋。角色安裝中斷的 boot baseline 已在原生安裝之前落盤；無法確認安裝器回傳時，重開機門檻維持到實際 boot stamp 改變。角色安裝要求先提供 IsolationEvidence 與已審核 SideEffects，原生呼叫前保存 baseline，呼叫返回或失敗後隔離工具確認的新服務／排程／IIS consumer，再逐項核對。這無法保證安裝器尚未返回時沒有自啟動；操作者必须在安裝前建立隔離環境，實際產品仍需專用程序及 Server 驗收。

## 服務帳號與觀察期

Service 的 own-process Supplement 保留 recovery／trigger／SID type／required privileges／environment／delayed auto-start 等已審核設定；staging 保持 Disabled 並抑制 recovery／trigger。LocalSystem、LocalService、NetworkService 不需 SecretRef；一般帳號需明確 UserPassword 和記憶體認證。DOMAIN\sam$ 必須明列 ManagedServiceAccount、ManagedAccountEvidence，且目標 Test-ADServiceAccount 通過；名稱尾端 $ 不會自動視為具備 gMSA 資格。原生 NULL 密碼建立路徑仍需實際 AD／SCM 驗收。

Observation 通過證據只能在完成啟用後、經過切換計畫所列 ObservationHours 時登錄。ActivatedUtc 與時數寫入 durable journal，中斷修復會保留。Acceptance 回傳尚需等待的窗口；時間經過仍需負責人提供觀察結果與業務證據，不能單憑計時器判定成功。

Win32 錯誤分類保留原生碼與 HRESULT，並提供登入失敗、相依失敗、服務程序中止與 SMB 認證衝突的建議，不會自動重試有副作用的操作。[Microsoft 系統錯誤碼定義](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1000-1299-)
## 設定檔審核與資料增量

來源角色 10 讀取可信 FileScope 規格草稿，逐檔輸出設定檔審核 JSONL。它辨識 web.config、app.config、*.exe.config、appsettings*.json；排除的路徑不列入，名稱相同的目錄不算設定檔。草稿只含 RelativePath、SHA256、Owner、Evidence，不複製設定內容；輸出另回報草稿 SHA256、項目識別及待負責人審核狀態。Owner／Evidence 留白，負責人必須審閱原設定並填入，將各列（含核准的精確 SHA256、Owner、Evidence）放進規格的 ConfigFiles 陣列後再提交規格與核准計畫。來源單檔 scope 的 RelativePath 是空字串。

其他設定檔可用 ConfigOverrides 明列精確相對路徑及 Classification=Configuration，再於 ConfigFiles 登錄核准雜湊。若已辨識檔名實際是業務資料，需明列 Classification=BusinessData、Owner、Evidence、Reason；不得使用 wildcard 或以 BusinessData 覆蓋既有 ConfigFiles 基準。BusinessData override 路徑不會輸出為設定草稿列；Configuration override 路徑會納入掃描。辨識規則不能代替應用負責人的完整設定清單，未知副檔名須由負責人補列。

完整包驗證及增量入口均核對 ConfigFiles 的核准內容。新增、修改、刪除或改名造成基準不符時，封裝／增量建立失敗；保留未封存工作區，回管理端重審規格與計畫，重新建立該核准的初始基準。同一核准的業務資料變更仍可走 initial／final 增量；設定內容相同的 metadata 變更另由 FileScope metadata 契約驗證。分類報告列出核准設定路徑、雜湊及例外理由，不顯示設定內容。

## 增量 ZIP 與取消作業

角色精靈的來源 9 可建立／檢查 initial、final 差異清單並匯出增量 ZIP；目標 15 可匯入、預覽、套用及修復。initial、final 必須來自同一核准計畫，final 帶來源停寫證據；差異清單分新增、修改、metadata-only、刪除及未變動。目標逐項核對工具 ownership、原始完整 scope hash 和可信 baseline，漂移即阻擋，不自行覆蓋陌生內容。套用前也會對每個仍納入的 FileScope 核對基底世代的持久 ownership、目標路徑及即時完整 scope digest；即使該 scope 沒有差異，只要設定或資料漂移也會阻擋。刪除只發生於已核准且工具擁有的 scope staging。

增量傳輸只攜帶變動 payload；目標使用已驗證的既有資料補齊完整本機 package，再執行原有完整性、staged validation 與切換門檻。若核准計畫包含 ManualWorkflow，增量後仍維持 ManualEvidenceRequired；既有 ManualRestore 證據必須綁定目前 manifest／generation，舊代次證據需重新提交。成功結果的 DeltaPackageManifestPath／Hash 是後續驗證、切換、結果與報告的輸入。原內容保留在 transaction 所列 sibling backup；目錄交換中斷使用目標 15 的修復，依實際 hash 接續，不手動刪除 transaction／備份。設定、scope、映射或相依變動需要重新核准，不能沿用資料增量取代設定審核。

主要匯出／ZIP／還原與增量操作會顯示本次 OperationId、取消控制檔及 SHA256。來源 scope 與目標 ZIP 匯入／匯出會在預檢、hash、列舉及資料區塊等安全邊界檢查取消；作業先驗證 CancellationToken 型別，並核對 Pair、PlanHash、ManifestHash（尚未有 manifest 的來源封裝階段使用空值）、OperationId 與本機狀態目錄。需停止時，另開同一主機、同一管理員帳號的 PowerShell，進角色精靈 5，輸入可信控制檔、負責人及理由；離線取消請求不會自動跨主機傳送。舊請求不會取消新作業。安全邊界停止時保留 sealed chunks／ZIP volumes／staging／journal，不封存不完整包。原子目錄交換期間不插入取消，先完成可辨識的交換狀態。檢查並修復 checkpoint 後，使用新的作業控制檔重試；Ctrl+C 或關閉程序視為非協調中斷，需先修復。

RestoreAttempt 與已套用 ManifestHash／Generation 分開保存。尚未套用就失敗或取消，也可匯出對應本次嘗試的 Restore StageResult；取消狀態保持 Cancelled，集中報告不改成 Succeeded。CLI 返回碼見「CLI 返回碼與等待輸入」。原生輸出只保留有界計數、摘要與程序結果；不完整輸出的 rolling digest 不是完整串流 SHA。owned process 退出證明不等於子程序或服務已停止。子程序持有 pipe 時，背景 reader close／handle 清理可能在呼叫返回後完成，必須另核對實際 OS 副作用。

## 排程安全描述元

排程盤點捕捉 task 與所有 ancestor folder 的 owner／group／DACL，不聲稱包含 SACL。草稿的 Desired.SecuritySddl／FolderSecurity 必須經負責人審核，來源擷取失敗保持缺口。既有目標資料夾只做 exact ACL 驗證，不覆寫 ACL；新建資料夾先記 intent、驗證後取得工具 ownership receipt。共用資料夾由 pair-wide receipt 追蹤，回復只刪工具擁有、ACL 相符且已空的資料夾；建立後未取得 readback 的模糊狀態保留現場供協調，不自動採認或刪除。

## CSV 審核與離線報告

CLI `ImportCsvPreview` 讀取 CSV 後輸出 `SourceHash`、`DecisionRevision`、列數及變更預覽，不提交決策。接著以同一 CSV 的 `-ExpectedHash`（預覽 `SourceHash`）及 `-ExpectedRevision`（預覽 `DecisionRevision`）呼叫 `ImportCsv`；兩個參數都必填。缺少其中一個不執行匯入；CSV 雜湊或 catalog revision 在預覽後改變時會拒絕套用，必須重新預覽。預覽會驗證 CSV 身分與唯讀欄位、允許決策及 Exclude 理由；成功套用時 DecisionRevision 遞增並使既有核准失效。

HTML 報告將資料以每塊 250 列嵌入離線頁面，最多快取 4 塊並採最近使用順序。頁面每次呈現 100 列，分類摘要列出總數、Include／Exclude／Pending 與不適用數。搜尋及分類篩選會掃描完整離線清單；列印符合項目上限為 2,000 筆，超過時須縮小條件。報告只代表最後匯入資料，不是即時主機狀態。

來源角色 11 的 `Export-WsmConfigArtifactReview` 對可信 MigrationPlan 產生即時設定差異 JSON 及 JSONL：Added／Modified／Deleted／Unchanged。輸出位置不得與來源 scope 重疊，已有父目錄必須符合受控 ACL；設定內容不會寫入差異報告。RequiresReapproval=true 時回管理端更新 ConfigFiles／分類／證據及核准，重新建立初始搬移包。舊 plan 的 delta 不能跨核准沿用；目標已有工具 ownership 時，先按明確回退／資料協調流程處理舊核准，不會自行接納新的核准覆蓋原 baseline。

有取消控制檔的長時間 hash／copy／原生工具等待會在本機 pair 目錄更新 `progress-<OperationId>.json`，至多約每秒一次、每筆上限 4 KiB。僅列階段、bytes、耗時與最後活動時間，不含檔名或 stdout；完成或取消後清除暫時進度。原生工具的初始活動時間是輸出讀取器啟動時間，之後只有實際觀察到輸出才更新，等待計時器不代表子程序有進展。timeout／取消的最終診斷仍保留於結果及 journal；不會把暫時進度當成 checkpoint。
## 測試主機結果複製貼回

兩台隔離 Server 部署相同 commit 的工具後，先在每台的 64 位元管理員 Windows PowerShell 5.1 執行環境檢查。角色選單 6 選 Source／Target，再選 1；也可使用 CLI：

```powershell
.\Start-ServerMigration.ps1 -Action LabReport -Role Source -Path D:\MigrationLabReports
.\Start-ServerMigration.ps1 -Action LabReport -Role Target -Path D:\MigrationLabReports
```

執行結果列出 `TextPath`、`JSONPath`、`JSONSHA256`。開啟 TextPath 的 `lab-validation.txt`，複製整份文字貼回本對話；可用下列命令讀取或複製，將路徑改成實際輸出值：

```powershell
Get-Content -LiteralPath 'D:\MigrationLabReports\lab-validation-<run>\lab-validation.txt' -Raw
# 有剪貼簿的主機可選用：
Get-Content -LiteralPath 'D:\MigrationLabReports\lab-validation-<run>\lab-validation.txt' -Raw | Set-Clipboard
```

環境檢查的 ApprovedPackage=NotTested 是預期結果：尚未提供核准包就不能驗證還原。報告使用固定機器指紋與 RunId 區別多台主機，顯示 OS／Windows installation type（例如 Server Core）／語系／PowerShell edition／language mode／工具指紋；不是正式產品資格。

依前述離線旅程產生可信包並完成隔離還原後，角色 6 選 2 或執行：

```powershell
.\Start-ServerMigration.ps1 -Action LabReport -Role Target -Phase Staged `
  -Path D:\MigrationLabReports -ManifestPath D:\MigrationPackage\manifest.json `
  -ExpectedHash '<獨立可信manifest SHA256>' -StateDirectory D:\MigrationTargetState
```

來源端同樣可提供 manifest 和可信 SHA256，重新盤點並核對來源設定、scope；不需要目標 StateDirectory。目標必須先有精確符合 package 的本機 state／journal；檢查期间持有既有 operation lock，其他本機操作進行中就拒絕產生報告。不一致不會自動修復。Final 檢查需已完成 activation 的 checkpoint，不能用停止中的 staging 宣告最終驗證。這個入口僅做讀取檢查及寫報告，不啟停服務、不還原、不改名／IP，也不替操作者建立業務證據。

TXT 預設最多列 200 項，FAIL／Blocked 優先，再列 NotTested／PASS；明示顯示及省略數，JSON 保留完整清單。Module API 可用 `-TextCheckLimit 1000` 調整顯示上限。若摘要省略仍有問題的項目，保留 JSON，依後續指定的 ItemId／分類提供細節，不把省略數視為已通過。未完成業務／人工程序保持 NotTested；2 代表尚有阻擋，不代表報告沒有產生。

每次產生新 run 子目錄，不覆寫舊證據。輸出位置不得與來源／目標 scope 或 operation state 重疊。回傳內容只含檢查狀態、設定／狀態摘要、原生錯誤分類與代碼；受控來源 collector 原始資料留在本機報告子目錄，請勿將原始 inventory／設定直接貼回或加入公開 GitHub。報告未簽署，SHA256 用於核對 JSON 完整性；真正產品及業務資格仍依原 PLAN 的實機正反例、重開機／故障與回退演練逐項確認。
## 實機最小可行驗證與擴大條件

先選一組隔離的來源／目標，代表實際 Server 版本與安全政策；無需先跑所有 OS／Core／語系／帳號模式的排列。用現有選單與 LabReport 留下可回傳證據：

1. 兩端環境報告；來源盤點與 owner 對照，確認實際需搬項目及未支援／未發現的缺口。
2. 選有代表性的 IIS／服務／排程／分享／憑證／帳號；附少量 nested／中文／空檔／排除檔與真正必要的設定，核准並封裝。
3. 目標隔離還原與 Staged LabReport；核對檔案／metadata、權限、設定與停用狀態；owner 實際從客戶端做登入／讀寫／背景工作。
4. 小幅修改業務資料，走 final／delta 並核對新增／修改／刪除；另改設定檔，確認舊核准確實阻擋。
5. 若實際角色需要 reboot 或正式名稱／IP，才追加重開機／隔離切換；在一個可控中斷點確認恢復，再演練一次回退，驗證來源寫入權與資料協調。
6. 回傳前後的 TXT，保留完整 JSON；人工／業務與外部認證結果另由 owner 確認，不以技术 PASS 取代。

單台成功後才擴大到實際有相依的雙台，再做十台波次。只對不同版本、權限、帳號、runtime、角色或缺陷新增測試。容量／時間驗證以實際 scope 為準，先定維護窗、可用容量與資源上限，單獨測一次封裝→傳輸→還原；不要反覆把大量檔案帶入所有 fault fixtures。代表性子集成功不表示未選項目或全部生產業務已通過。

## 只讀物件範圍評估

來源盤點附帶版本化分類 metadata，匯入時驗證並保留。主選單23顯示分類數量與探索缺口；CLI `-Action ScopeAssessment -Workspace <工作區> -PairId <配對GUID>` 輸出全部項目及原有相依關係的 JSON。亦可用 `Get-WsmGeneralHostAssessment -Inventory $inventory` 或 `-Catalog $catalog` 做同一投影；舊盤點沒有附帶分類時重新計算，附帶分類若損壞／不符規則則拒絕。

分類是候選判斷：Oracle引擎／listener列特殊產品，用戶端／driver／runtime與代理列目標準備；混合主機仍保留一般IIS與自訂服務。未解析產品與collector缺口保持未知；名稱命中不代表產品完整識別或實機資格。此評估不改決策、不安裝、不搬移、不測網路；準備與外部相依的受審核門檻會依PLAN後續段落接入，不能用分類數量代替核准或業務驗收。

## 企業備份／還原與軟體設定界線

本工具協助受審範圍遷移，不能代替整機／System State備份。專業／環境軟體只列在每台.md，由使用者安裝；設定檔另列精確scope並以FileScope／typed adapter或外部產品程序搬移、readback及consumer驗證。完整已支援／有限協助／外部／不支援項目見 [ENTERPRISE-MIGRATION-COVERAGE.md](ENTERPRISE-MIGRATION-COVERAGE.md)。

精靈的 Target 證明交接會把固定 WorkRoot 的 `pairs` 目錄，連同其對應既有共享一併綁定。Manager 只能沿用這個已審閱位置；不得另填同共享內的其他目錄。舊版未綁定狀態目錄的證明須在 Target 重新匯出並核對，不能以手改 JSON 補足信任。

還原後先做 Staged 機械驗證；符合條件時才顯示另一個啟用審閱入口，執行仍須 CutoverPlan、精確確認及核心條件。啟用後保留原還原成果，改做 Final 驗證與接受條件重查，不重做還原或再次啟用。舊 Staged 結果不能代替 Final 結果，機械通過也不代表業務已接受。

作業歷史可供追查；開啟材料或要求取消前，工具會核對原工作目錄、用途與搬移配對。請切回該作業的原內容後操作。缺少這些來源資訊的舊紀錄保留作參考，不會因此取得執行權限。

每次執行畫面都綁定當時的版本。若另一頁或另一個作業已改變材料，請重新讀取並核對；工具不會在送出前偷偷改用新版本，也不會自動重送未確認的寫入。

若工作目錄正被短暫讀取或寫入，工具最多等待兩秒取得作業鎖；仍未取得就保留目前資料並停止該操作。請先查原作業與修復指引，不要刪鎖或同時重開另一個寫入。慢速畫面只保留一輪作業刷新；執行畫面讀取失敗時，使用其「重新讀取執行畫面」按鈕，不會重送先前寫入。

安裝目錄與固定 WorkRoot 請分開規劃，優先採用工具建議的短工作目錄。安裝路徑可含中文與空白；過長的 WorkRoot 會在初始化前被拒絕，避免留下部分工作區。較深的封裝與交付路徑仍會在各操作開始前另外檢查，請不要以手動搬動工作區或刪除原紀錄繞過限制。
