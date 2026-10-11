# 第 4 輪規劃：HTML 操作教學、資訊分頁與流程一致性

> 日期：2026-10-11（Asia/Taipei）。狀態：2026-10-11 使用者授權完整實作，執行中；未完成驗收。
> 基準：`dev` / `f3cd91930c0bb51d5d0e3e8153072a952f340141`。
> 來源：使用者要求操作 HTML 加入說明與教學、容易操作、可分頁確認資訊；先核對整個專案影響，討論後詳細規劃，不實作。

本輪 PLAN 放在 `docs/plans`，配合現有文件產生器只取 `docs` 頂層來源的規則，避免規劃階段就改變使用者文件輸入。此處只有本輪有效計畫，不是封存區。

## 定案與授權

- 使用者已選定「工作台內分頁，教學／報告可另開頁」。沿用同一本機程序的角色、配對與工作區，不改為每個瀏覽器分頁獨立角色／配對。
- 使用者已選定「常用任務導引＋完整進階操作」。導引協助選擇既有操作，不新增另一套執行引擎或以教學取代核准。
- 上輪討論提出的刷新、上下文、快取、返回導覽、總覽與說明問題列入本輪規劃。首次實作前核對下表完整範圍；新發現若改變產品行為或範圍，先提出討論。
- 2026-10-11 使用者明確指示開始實作、逐段驗證後 commit/push，並持續補齊至全部完成。採用複審建議的提交查詢、作業歸屬相容擴充、Windows 開啟受驗證報告；不新增報告檔案服務。第三輪驗收證據與外部待驗收事項保留，不套用為第四輪完成證據。
- 本輪規劃由主代理完成，未委派。實作開始時沿用專案執行規則；若委派再套用 delegated-implementation 與 subagent-verification-policy，未指定的實作者或模型不冒填為已執行。

## 基準核對與證據限制

1. `node tests/Test-AssistiveUi.js`：19/19 PASS；`node --check src/ui/console.js`：PASS。這是既有 UI 契約與語法基準，不是本輪完成或真實瀏覽器通過證明。
2. 專案外隔離 DOM 檢查重現：操作中心切換上下文未重新取得 actions；成功保存選取後 overview 快取仍被使用。檢查使用現有測試 harness、只在記憶體暴露待查函式，未修改專案 runtime/test。
3. 真正 WinPS5.1 loopback 測試服務使用專案外 fixture 工作區，沒有執行還原、啟用或生產作業。瀏覽器可呈現初始 HTML，但持續載入；in-app browser 重載出現連線重設。HTTP 客戶端觀察到回應 CSP 含原始程式未提供的 `local.adguard.org`，僅能證明存在回應差異，不能據此斷定載入失敗根因。瀏覽器功能與傳輸完整性仍未驗證。
4. 初次測試啟動遇 WinPS 模組搜尋路徑問題，僅在專案外啟動腳本設定該子程序的標準 Windows 模組路徑後啟動成功；未改機器設定。與瀏覽器載入失敗分開記錄。
5. 工作區原有未追蹤 `Get-ServerMigrationInventory.ps1`；未讀取、未修改、不得納入提交或測試快照。`docs/archive` 未讀取，不納入本輪搜尋、產生或打包。
6. 第三輪雙引擎／CI／實機限制沿用其原有版本證據；本輪新增改動必須另驗，不能用前輪 PASS 替代。

## 批次總覽

| 批次 | 內容 | 規模 | 相依與建議順序 |
|---|---|---|---|
| A | 上下文、快取、目標重查語意、提交恢復與真實載入診斷 | 中偏大，前端＋本機橋接；含已採用 Q02/Q03/Q06 | 第一段；可拆 A1/A2，建立後續頁面可依賴的資料一致性 |
| B | 總覽階段、阻擋與下一步 | 中，核心既有事實→安全投影→畫面 | A；不能以空白／假百分比完成 UI |
| C | 資訊分頁與常用任務導引 | 中，導覽＋既有 typed 表單 | A、B；完整進階操作仍可到達 |
| D | 頁內說明、角色教學與文件中心 | 中，多個使用者 HTML 與產生來源 | C；說明必須對應最後行為與頁面 |
| E | 文件產生相依、可攜交付與整輪驗收 | 中，產生工具＋發行＋測試 | A–D；檢查最終 bytes 與跨段使用端 |

各批次是含完整相依與適當驗證的提交單位，逐段 commit／push 至本輪分支並核對遠端 SHA。無法獨立建置或驗證的相依先補齊，不提交半套功能。

## 批次 A：資料一致性與可理解的重新檢查

### 現況與核對結果

- `src/ui/console.js:23` 的 getView 保存頁面快取；`:271` 保存選取後只更新 session revision，沒有使總覽快取失效。`:81` 的保存選用版本也須檢查全部受影響顯示，而非只更新輸入框。
- `src/ui/console.js:38` 的 applyContext 將目前 hash 原樣傳給 loadView；`:268` 接受 actions，但不接受 operations，造成切換後仍保留舊 action metadata。另核對 jobs 的重連，不能只處理一般資訊頁。
- `src/ui/console.js:278` 的「重新檢查目標」只 GET software view。`src/HtmlConsole.ps1:238` 呼叫 Get-WsmAssistiveComparison；`src/AssistiveComparison.ps1:243` 從已保存的來源／目標快照比較，可重用已有比較或重新推導，但不重新盤點實際目標主機。
- `src/AssistiveComparison.ps1:140` 的 TargetSnapshot 必須接可信盤點檔與 ExpectedHash；`:261` 的 PublishComparison 才持久保存比較。不能把 GET 畫面當成這兩項寫入已完成。
- `src/HtmlConsole.ps1:364` 的角色／配對是服務程序共用上下文。前端同步與提示必須符合此事實；角色是操作指引，Windows 身分與核心條件仍是權限依據。

### 行為契約與改動

- 同一配對內保存選取、版本或完成影響資料的作業後，更新或使所有相關快取失效。顯示目前資料版本／讀取時間；只稱為「最近取得」，不能冒稱已重新盤點。
- 未保存選取、操作及版本草稿在工作台資訊頁切換時保留；同配對資料衝突保留非秘密草稿並要求重新審閱／預覽，不把草稿冒充最新保存值。切換配對時沿用原有防止草稿跨配對混用的政策，提前清楚提示。
- 上下文切換後刷新 actions、相關 revision 與目前頁面的讀取；舊預覽及確認失效。較舊請求延後完成時不得覆蓋新上下文或較新資料。此競態尚未重現，列為必要反例，不稱已確認 bug。
- 軟體頁區分「重新載入比較」與「更新目標盤點／比較」。目標實際盤點在目標主機執行；Manager 以受控離線交換取得可信盤點，再經 TargetSnapshot、PublishComparison 更新。導引逐步預填既有操作，保留每一步核驗與確認，不偷偷串成自動還原。
- 無配對、尚未啟用輔助模式、尚無目標快照、權限不足及比較失效，提供具體原因與可到達的下一步；不以空表暗示沒有缺口。
- 在隔離 fixture 分別定位靜態資源、JavaScript 啟動、session/API、慢請求及回應完整性。使用既有 HttpIntegrityProbe 與必要的原始回應 bytes 比對，不記錄 token／秘密，不變更防火牆或停用安全軟體來取得「通過」。若需外部設定變更，先提出具體原因與選擇。

### 輸入／輸出與驗收

- 輸入：現行 session/context/revision、保存結果、job 狀態與可信盤點參照。輸出：同一上下文的最新安全投影；供 B 總覽、C 導引及 D 說明使用。
- 保存選取後返回總覽，計數必須與實際保存的集合一致；版本保存後來源／選用／目標觀測仍分開，舊 receipt／比較的有效性由核心決定。
- 在 operations 切換角色／配對，實際重新讀取 metadata，舊確認不可提交；jobs 仍可重新連線；延遲舊請求與 CAS409 反例不造成錯配或草稿被默默覆蓋。
- 「重新載入比較」不產生實機盤點；可信新快照→TargetSnapshot→PublishComparison 後才更新觀測與證據。測試錯主機、錯 hash、舊 revision、缺快照與完整下一步。
- 基準重現必須在撤回對應修正時失敗。真實瀏覽器載入診斷另列結果與環境，不把 mocked API／DOM PASS 算作傳輸通過。

## 批次 B：以真實資料呈現總覽

### 現況與核對結果

- `src/ui/index.html:39` 顯示工作進度容器；`src/ui/console.js:44` 消費 steps，但 `src/HtmlConsole.ps1:248` 的 overview 回傳 `steps=@()`，nextStep 使用概括英文文字、部分數值為 NotMeasured。
- 前端已有 metrics/progress 畫面，不代表 producer 已提供可量測的工作進度；不能自行以「已搬檔案／全部發現」稱整體搬移成功率。

### 行為契約與改動

- 按目前角色、配對與既有 catalog／comparison／approval／stage result，提供盤點、審閱、目標準備、交付、還原、驗證及交接的實際狀態；C／非 C、軟體準備、檔案讀回與業務接受仍分開。
- 每一狀態附事實來源與下一步。缺資料顯示尚未觀測／尚未開始；等待、失敗、中斷、部分完成及人工項保留原語意，不猜測成功。
- 無可定義分母時呈現計數與待辦，不畫虛構百分比。只有有證據、定義明確的局部指標才顯示比例，文字指出分母與涵蓋範圍。
- 下一步通往 C 的既有資訊頁／常用任務；準備不足、等待補裝或未核准時不能直接觸發還原、啟用或清理。

### 輸入／輸出與驗收

- 輸入：A 的新鮮度及核心既有階段事實；輸出：安全、可追查的階段摘要與建議操作，供 C 導覽與 D 的狀態解釋使用。
- 驗空工作區、無配對、未核准、等待軟體、C 完成但非 C 未完、衝突、取消、部分成功、已啟用但未業務接受；每種有正確文字、阻擋與下一步。
- 逐項對照核心集合與實際結果，不以總覽摘要代替 sealed plan、receipt、journal 或 ProductionVerified。HTML 不輸出原 XML／命令參數／秘密。

## 批次 C：資訊分頁與常用任務導引

### 現況與核對結果

- `src/ui/index.html:22` 附近的 navigation 提供六頁；教學入口在頁尾 `:53`。
- `src/ui/console.js:269` 用 history.replaceState 切頁；需要補返回／前進與非法 hash／skip link 的處理，不能把每個 fragment 都當資訊頁 selector。
- `src/ui/console.js:166` 已有中文操作名稱與 Source／Manager／Target 分組。`:168` 多數操作使用通用目的、前提與輸出文字，完整清單對一般 TS 不足以決定操作順序。

### 定案與改動

工作台使用八個可辨識資訊頁；保留既有任務頁，增加說明與文件入口。

| 分頁 | 使用者應能確認的資訊 |
|---|---|
| 工作總覽 | 目前角色／主機／配對、資料更新、真實階段、阻擋與下一步 |
| 盤點與選取 | 已發現內容、所選集合、未選原因、核准與相依影響 |
| 軟體差異 | 來源／選用／目標觀測、補裝責任、盤點與比較更新 |
| 檔案與路徑 | 舊路徑、保存位置、生效路徑、逐項衝突與人工重試 |
| 操作中心 | 常用任務導引、typed 表單、預覽、明確確認與完整進階清單 |
| 作業與交接 | 作業識別、進度、部分／失敗／取消、報告與恢復下一步 |
| 說明與教學 | 起步、三角色流程、頁面／欄位教學、狀態與疑難處理 |
| 文件中心 | 完整操作手冊、差異／清單／復原等分類文件與離線／即時區分 |

- 使用可直接開啟的 hash 導覽、返回／前進與正確目前頁面標示。既有側欄保留鏈結語意；不為視覺像分頁而只加不完整的 tab ARIA。若局部元件真的使用 tabs，完整實現鍵盤與焦點契約。
- 常用任務按角色與階段組織：來源盤點／材料、管理匯入／審閱／核准／比較／報告、目標盤點／準備／預覽／還原／驗證。列出任務前提、在哪台主機、所需材料、每一步既有 action、預期結果與下一步。
- 每個常用任務連到真正 typed 操作表單；只有已有可信投影的欄位才可預填，核准／確認欄位保持未勾選。進階清單保留所有 allowlist 操作，不因簡化導覽丟掉恢復、回退、NonC、材料鎖及 OSProvided 等能力。
- 任務分類是指引，不能替代 Windows 權限；不宣稱所選 Manager 角色可遠端執行 Target 原生作業。指定主機與角色不符時說明正確操作位置。
- 教學、完整手冊與報告可明確另開頁；不替換當前工作台或丟失草稿。使用者另開工作台仍共用程序上下文，說明此限制，不承諾每頁獨立配對。
- 選取／篩選與分頁的批量按鈕明確說明作用集合。「目前結果」是否包含其他結果頁依現有 currentVisibleIds 行為顯示，不偷偷更換選取範圍。

### 輸入／輸出與驗收

- 輸入：A 上下文與 B 真實下一步；輸出：可到達的八頁與既有操作選擇，供 D 教學引用。所有 action 保留原參數形狀、CAS、idempotency 與 preview 條件。
- 從起始頁切遍八頁，返回／前進、直接開頁、刷新、非法 fragment、skip link皆可恢復；導航不送寫入請求。
- 在資訊頁切換、另開教學／報告後，非秘密草稿與選取仍保留；表單成功提交、明確改載另一審閱項目、跨配對草稿隔離維持既有契約。
- 常用導引逐一驗 action/參數/真實 consumer；進階 allowlist 完整可達。鍵盤 Tab／Shift+Tab／Enter／Space、合理焦點去回與可見焦點必須實測。

## 批次 D：說明、教學與文件中心

### 現況與核對結果

- `src/ui/guide.html` 已有起步、三角色共用順序與秘密／恢復說明；`docs/ASSISTIVE-OPERATIONS.html` 多數主體為英文；`docs/html/index.html` 主要顯示檔名清單，缺任務分類與讀取順序。
- `src/HtmlConsole.ps1:127` 多數 metadata 的 parameter description 為空，前端 `src/ui/console.js:189` 只有有 description 才顯示欄位提示。中文名稱不能代替填寫教學。
- 教學與完整文件存在多個來源，產生的 HTML 不能直接手改後在下次建置被覆蓋。

### 行為契約與改動

- 八頁都有簡短說明：這頁看什麼、前置條件、怎麼操作、結果證明什麼／尚未證明什麼、下一步。較長內容可展開，教學可跳過、回查，不強制走完導覽。
- 常用任務提供繁中步驟、欄位範例與預期結果；進階操作提供可辨識用途、對應角色／主機、必要欄位與結果查閱位置。技術 action／hash／狀態代碼保留供追查，但不只顯示內部方法名。
- 範例使用虛構路徑／識別與占位值，不含真盤點、機密或可冒用的核准資料；來源/選用/觀測版本、可信 hash、原設定與生效路徑、首次觀測基準、等待補裝／直接還原、選取／核准分別解釋。
- 完整操作手冊與使用者導引的主要教學內容改為繁中；支援矩陣、SBOM、產品名稱與原始證據代碼保持精確。開發 README／PLAN／AGENTS依既有來源維護，不為翻譯更動資料契約。
- 文件中心依起步、角色操作、差異與清單、設定／路徑、驗證／交接、恢復／疑難分類，每份文件說明用途、何時讀取與離線快照性質；完整文件與資訊清單不因教學摘要而截掉。
- 在固定相對位置提供幫助入口；表單提示與欄位／錯誤關聯、載入／空白／失敗／重試狀態可理解。未知版本／缺資料顯示真實原因，不用綠色或「無項目」掩蓋。

### 輸入／輸出與驗收

- 輸入：A–C 最後行為、metadata及現行手冊來源；輸出：頁內教學、角色步驟、繁中完整手冊與分類文件中心，供 E 產生與封裝。
- 用來源→Manager→Target、補裝後重查、新版選擇、舊路徑／目的衝突、C／非C、部分結果與中斷恢復情境走讀；每一步能從HTML到達實際操作／結果，不需正常流程手改JSON。
- 320 CSS px、常用桌面寬度、200%放大、長中文／路徑／hash與大量資料，確認整頁不橫向溢出、表格局部捲動清楚、操作不被遮住。檢查對比、可見焦點與縮小動態；不只憑模板宣稱 WCAG 合規。
- 完整文件、報告限制與教學描述一致；外部 Server／業務／PKI 未驗收標示保留。

## 批次 E：文件產生相依、發行與整輪驗收

### 現況與核對結果

- `tools/Build-HtmlDocumentation.ps1:74` 只排除 `MIGRATION-3-PLAN.md`，若後續 PLAN 置於 `docs` 頂層，就會被產生為使用者文件。本輪先使用不在既有非遞迴輸入集合的 `docs/plans`，不在規劃階段修改產生器；E 再補規劃類文件的通用排除及位置反例。
- `src/HtmlConsole.ps1:346` 的靜態資源／文件路由、`:357` 的資產 hash及既有 CSP 必須涵蓋最後頁面；新增資源不能只在原始工作區可用。
- `src/ToolRelease.ps1:1` 將UI資產納入工具指紋；`:191` 核驗發行內必備UI檔；`:206` 封裝目前文件與HTML。使用者文件入口與開發PLAN分開，既有包內Markdown保留規則需先核對，不能為美化入口隨意刪掉有效交付文件。

### 行為契約與改動

- 在產生工具統一排除所有本專案輪次規劃，並處理舊的生成 PLAN HTML，不留下文件中心連結或可被路由當成操作說明的殘留。保留完整使用者來源與有效相對連結，繼續排除 archive。
- 新教學與文件入口復用既有資源／原生CSS與JS；不添加CDN、遠端字型、服務、框架或第三方相依。新增本地資產才同步路由、session hash、fingerprint、release consumer與測試。
- 改動UI即改工具指紋。正在執行／封存核准的作業維持原版接續，不能熱換UI或改核准JSON遷移；新版本重新封裝、按既有核准與信任流程使用。顯示更新要求與恢復路徑。
- 同步README的使用者入口、現況文件與代理文件地圖，再重建其使用者HTML投影；PLAN不可寫成已完成行為。
- 最終ZIP核對manifest、實際bytes、全部HTML/CSS/JS、相對連結及離線使用。保持Signed/ProductionVerified真實值，不以UI驗收解除既有正式資格阻擋。

### 完整性核對與驗收

1. 主代理以本輪需求矩陣逐項檢查實際檔案、producer→projection→UI→operation→結果/報告接線；任何項未接入真實使用端，先補實作再進入正式驗收，不能移到待辦。
2. 每段適當回歸後，整輪固定快照跑現有可執行全量套件與新增反例。至少涵蓋 AssistiveUi、HtmlConsole、HtmlBridge、HtmlDocumentation、Comparison、ReviewForms、Reports、StageResults、Contracts、Qualification與ScriptEncoding；涉及其他核心路徑時補對應suite。WinPS5.1/PS7分別記錄，沿用既有小範圍測試與未實測4GiB／企業規模限制。
3. 真實瀏覽器驗證與既有 mocked API/DOM 測試分列；確認資源載入、session/API、導航、表單預覽／確認、相同上下文資料更新、另開教學/報告與鍵盤/響應式。只有最後程式bytes相同且覆蓋有效的結果可沿用。
4. 新生成文件測試放多個輪次PLAN、完整長內容、缺連結、archive排除與本地資源；文件中心不出現開發規劃。實際ZIP相對連結/bytes前後核對，prototype與archive不入包。
5. 實作輪完成後依 project-closeout 的適用規則進行獨立體檢與收尾，標示可信模型來源；未有證據不宣稱不同模型體檢或production通過。

## 需求覆蓋與跨批次核對

| 編號 | 需求／本輪問題 | 批次與驗收使用端 |
|---|---|---|
| R4-01 | 操作HTML加說明與繁中教學 | C/D，八頁→欄位→真正操作與結果 |
| R4-02 | 工作台內資訊分頁，教學/報告可另開 | C/E，八頁、草稿、直接連結、離線/ZIP |
| R4-03 | 常用任務導引與完整進階操作 | C/D，三角色/階段→所有allowlist |
| R4-04 | 操作中心切換角色/配對後刷新metadata | A，typed欄位與各revision反例 |
| R4-05 | 保存後各頁資料一致，保護草稿 | A，選取/版本/作業→總覽/清單 |
| R4-06 | 重載比較與實際目標盤點語意分開 | A/D，可信快照→TargetSnapshot→PublishComparison |
| R4-07 | 總覽步驟/阻擋/下一步來自真實資料 | B，C/非C/等待/部分/啟用/業務結果 |
| R4-08 | 返回、前進、焦點與響應式容易操作 | C/D，實際瀏覽器與鍵盤/320px/放大 |
| R4-09 | 載入失敗定位、可恢復狀態與真實傳輸 | A/E，loopback/API/資產bytes/探測證據 |
| R4-10 | 完整文件中心分類與主要繁中操作手冊 | D/E，來源→產生HTML→可攜文件 |
| R4-11 | PLAN排除與新資源/發行/指紋完整相依 | E，產生器/路由/session hashes/ZIP/舊版接續 |
| R4-12 | 本輪問題不漏項、分段驗證與push | A–E，完整性核對/固定快照/各遠端SHA |

相依方向：A的新鮮度供B/C使用；B的下一步僅導向C的既有action；D教學消費A–C已確認行為；E核對原始與生成文件、runtime指紋與真實包。這只確認設計方向，不能據此宣稱各段已正確接線或相容；新增複審項目與相容條件如下，完成實作及反例驗證後才能作結論。

## 四視角複審：先操作情境，再檢查全專案相依

### 複審方法與結論界線

本次以 `d3e16ef5db463a88b76b8fb516210ce9a19fd62b` 的規劃及現行程式逐條走讀。主代理依序代入首次操作 TS、熟手、交班接手者、多視窗使用者、鍵盤使用者、管理者，再查 API、資料投影、核心與封裝相依。尖銳但有理的使用者質疑作為可證偽情境，沒有把假想評論當成 Reddit 調查或實際使用者測試。未委派，未實作，也未重新聲稱瀏覽器傳輸已通過。

結論：原 A–E 的方向可保留，但不能只補教學與分頁。失敗恢復、作業歸屬、草稿生命週期、錯誤可操作性與驗收證據尚不夠完整。下列 Q 項全部留在本輪；「原碼確認」表示現行程式行為已確認，不表示後果已在實機重現。「反例待驗」不能列成已發生事故。涉及新增行為的 Q02／Q03／Q05 是建議契約，已隨本次完整實作指示採建議方案；若需不相容契約變更仍先討論。

### 從使用者角度逐步挑戰

| 情境／合理質疑 | 必須完成的操作鏈與可驗收結果 | 補強編號 |
|---|---|---|
| 新 TS：「我剛開工具，沒有配對，你要我去哪裡拿第一份資料？」 | 空 WorkRoot → 對應本機角色 → 盤點／建立或匯入配對 → 輔助模式 → 第一個可操作頁。每步說明在哪台主機、輸入從哪一步來、輸出交給誰；無資料與載入失敗不同。不得靠手改 JSON 補缺頁。 | Q08 |
| 熟手：「不要每次逼我重看教學，也不要藏起低頻但必要的工具。」 | 可略過／重看教學；常用任務與完整清單共用 action ID、typed 欄位、預覽及執行。搜尋可用中文名稱與原 action 名；每個 allowlist 操作有可到達入口及基本說明。 | Q08 |
| 多頁使用者：「我切回這頁，怎麼知道不是剛才另一組機器的資料？」 | 常駐顯示本機、角色、工作區、配對；另一瀏覽器視窗切換後，舊視窗在恢復焦點或寫入前核對上下文，舊預覽失效；同程序不能被誤教成獨立配對。 | Q01、Q04 |
| 操作者：「我填了二十筆，只是看一下說明，為什麼全沒了？」 | 工作台換頁保留草稿；另開說明不帶秘密；重新載入、關頁、切配對前明確告知非秘密草稿保存範圍。配對切換取消時不丟資料。草稿和已保存值視覺分開。 | Q04 |
| 夜班人員：「送出後斷線，我該重按嗎？會不會執行兩次？」 | 送出即保留可查詢的 operation ID；先查既有工作與權威紀錄，再決定恢復方式。網路失敗不顯示為確定未執行，不自動重送寫入。 | Q02 |
| 接手者：「這份成功報告是哪台、哪一輪？是檔案完成還是網站能上線？」 | 作業／報告有來源歸屬、時間與可用證據；區分操作成功、C／非 C、部分完成、啟用及業務接受。舊作業歸屬不明不猜配對。 | Q03、Q05、Q09 |
| 鍵盤／大量資料使用者：「勾一次就失焦，更新又把畫面跳走？」 | 勾選與取消後焦點可預測；輪詢不搶焦點、不重置讀到的位置；篩選／翻頁保留選取並顯示批次影響數，零結果可解除篩選。 | Q07 |
| 管理者：「只寫 request rejected，我要看哪份紀錄？清理後還能追查嗎？」 | 可分辨可恢復錯誤、權限不足、版本衝突、活躍作業限制；錯誤附安全識別碼及下一步。清理仍按材料引用／鎖定／既有核准；交班能回查權威紀錄，不靠截圖簽核。 | Q06、Q09 |

### 原碼發現與補強契約

| 編號／優先級 | 證據與判定 | 建議補強、批次與驗收 |
|---|---|---|
| Q01／高：讀取上下文也要一致 | 原碼確認：`console.js` 的 `getView` 僅按頁名快取；`HtmlConsole.ps1` 的 `/api/view` GET 依服務當前 PairId 投影，請求與回應未帶完整上下文綁定。另一視窗切換時，舊標題與新資料混用屬反例待驗，不能只靠 POST 的 CAS 解決。 | A：快取鍵／回應採用條件涵蓋 session、context、pair、資料版本；不把不同 revision 視為可互換。測延遲回應、同頁連續刷新、跨視窗切換、服務重啟及瀏覽器恢復焦點。若讀到異動先同步標題及資料，不能在舊配對標題下呈現新結果；不能用兩次有競態的獨立讀取冒充原子快照。 |
| Q02／高：提交結果不明與重試 | 原碼確認：`buildOperationRequest` 每次建立新 operationId／idempotencyKey；`submitOperation` 的 request 僅為當次區域變數。服務端在查冪等鍵之前先檢查 context/revision；快速保存首次回 Saved＋revision，但重放回 durable job record，形狀不同。不存在完整、可依賴的 UI 復原契約；尚未重現重複實際副作用。 | A 建議：先按原 operation ID 查詢，不要求把整份秘密參數落盤。已受理／已完成不再新建請求；未知時顯示「結果待確認」，提供查紀錄路徑；不因逾時自動重送。需要重送時另定相同請求／revision／context 的安全規則，不能為重試繞過目前核心 gate。測受理後回應遺失、前端重載、服務重啟、409、快速保存及異步工作；統一可解讀的保存結果。 |
| Q03／高：作業歷史的歸屬與相容性 | 原碼確認：`/api/jobs` 列出工作區全部 jobs；兩個建立 record 的分支沒有一致保存 pair／role 等歸屬欄位，部分 outputs 才有 PairId。`renderJobs` 不顯示一致的配對歸屬。既有 WindowsSettings／Requirement 預填已檢查 PairId，不能誤報其毫無保護；新導引需延續並核對版本／hash。 | A/C 建議：本機 console-job 紀錄加安全來源欄位，預設目前配對，提供工作區全部歷史入口；舊紀錄歸屬不明獨立列出，不反填目前配對、不直接預填。保留歷史報告檢視。新增欄位限 console-job 相容擴充，不能順帶改 sealed plan／receipt／journal。驗新舊紀錄混用、無配對作業、跨配對／舊世代預填、重啟重連與實際執行者身分；若需不相容格式變更再討論。 |
| Q04／高：草稿不是資料庫 | 原碼確認：state.drafts 等僅在記憶體；切配對清除；未提供 beforeunload 保護。原計畫「保留草稿」未清楚限定生命週期。 | A/C：建議維持非秘密記憶體草稿，不增加磁碟／localStorage 草稿庫。離開未保存操作提供提示，瀏覽器關頁提示只能盡力，不能保證崩潰恢復；切配對的站內提示可取消。角色變更使預覽失效；舊 schema 不盲套草稿。409 後顯示哪些選取項已刪除／不可選，重新核對再保存；刷新不能覆蓋編輯，也不能把已失效項默默送出。 |
| Q05／中：報告另開的真實含義 | 原碼確認：`openJobReport` 經 hash 核驗後 `Start-Process` 開本機檔案；目前不能保證「新瀏覽器分頁」，回 Opened 也不證明報告已顯示。 | C/D 建議沿用受驗證報告交給 Windows 預設程式開啟，標示可能為新頁／視窗及可用的受控檔案位置；教學則用獨立靜態頁。測缺檔、hash 改變、程式開啟失敗、報告過期及返回工作台。如果要求一定在本機 web 新分頁看報告，需另定 authenticated report route、內容隔離與資源允許範圍，不能直接把任意磁碟檔案公開；此替代方案未定案。 |
| Q06／高：能採取行動的錯誤與逾時 | 原碼確認：服務 catch 多數錯誤變為泛用 Request rejected；前端 endpoint 的 401／403 都當 session expired；請求沒有明確應用層逾時。原計畫只寫「具體原因」不足以落地。 | A/D：定義安全錯誤分類與關聯識別碼，涵蓋 context／revision 變更、token、host/origin、輸入、活躍作業限制、報告失效及不可取消；不將原始 exception／秘密送前端。讀取逾時可明示重試，寫入逾時走 Q02；取消前端等待不等於取消伺服端工作。診斷可由使用者查閱現有受控紀錄，不自動蒐集／上傳主機資訊。驗錯誤文案有下一步且不導向反覆重啟或重送。 |
| Q07／中：焦點、輪詢、篩選與規模 | 原碼確認：`paintInventory` 於勾選後重建列；取消選取有嘗試聚焦原因欄，勾選未有相同處理；`renderJobs` 每輪 replaceChildren。焦點影響需真實瀏覽器驗證，不能只驗 class。 | C/D：明定勾選、驗證錯誤、換頁、返回、輪詢後的焦點位置。狀態公告只宣告變更，背景更新不搶焦點；無操作時不持續朗讀全部清單。用既有小範圍／2501列等適用 fixture 檢查盤點、檔案、軟體與作業歷史，而非只測單一表格；記錄環境與延遲，不推論企業規模。測空篩選、長路徑、跨頁批次數量與不在視窗中的選取；導覽採一致原生連結語意，若用 tab widget 才完整實作其鍵盤模型。 |
| Q08／中：常用任務的閉環與完整清單 | 原碼確認：`actionGroup` 用名稱模式分組，`actionGuidance` 多數通用。僅加中文標題或八頁不能證明新手能完成工作。 | B/C/D：以明確 action ID 建常用任務映射，每項有適用角色／階段、所在主機、前置證據、typed 輸入、成功／等待／失敗輸出、下一步。先覆蓋初次盤點、可信離線交接、啟用輔助、選取／選版、目標重查、預覽／核准／還原、部分續作、驗證／啟用／交接、取消／恢復；完整清單比對 allowlist，未納入常用任務也不得失聯。範例用明確虛構值，不能預填核准、負責人簽認或真實秘密。文字選單仍可完成相同核心流程。 |
| Q09／高：管理者追溯與未知不能變成功 | 原碼確認：目前 overview 的 pendingOrFailed 實際只計 Pending／Deferred；`statusClass` 用 regex，含 Verified 的否定／未知字串可能被染成成功。後者為通用狀態函式的風險，不指稱所有這些字串目前已被傳入。 | B/C/D：為實際 producer 狀態列明顯式顯示映射，未識別狀態中性＋原始值。各指標定義單位、集合、去重及失敗／等待的計算法，不混用檔案數與項目數。顯示可取得的配對／世代／revision／證據時間與責任歸屬；缺欄位寫未知，不由目前登入者猜歷史負責人。報告連回既有 hash／權威結果，清理與恢復仍走既有材料引用和鎖定規則，不新增管理者繞過核准權限。 |
| Q10／中：生成文件與版本收尾 | 原碼確認：文件產生器寫入來源投影及索引，未清除不再產生的舊 HTML。原計畫要求清除 PLAN 殘留，但未說明安全刪除範圍。 | E：只清理由本產生器可辨識、位於指定輸出根內的舊 PLAN 投影；不掃 archive、不遞迴刪未知文件、不刪手寫 HTML。生成前後核對來源與輸出清單。舊版原封存執行環境不回寫；新包文件與 UI 同版。測未知檔保留、舊 PLAN 退出索引／路由／新包，以及 README 使用者入口不因內部 PLAN 連結退化。 |

### 全專案角度的最後相依檢查

1. **身分與資料流**：本機 Windows 執行者 → session/context → 正確 PairId／各自 revision → view → typed 預覽 → 確認 → 核心 gate → durable job → journal／report → 總覽及交接。Q01–Q03 補齊中間斷點；角色切換不等於帳號授權。GET 顯示、POST 執行與歷史證據三者均須能辨識歸屬。
2. **更新與失效**：選取、版本、目標快照、comparison、核准與各階段結果的 producer 分別列入失效表，標明受影響頁面／下一步／預覽。全頁清快取不能取代核心 evidence stale 判定；工作完成後重新讀權威結果，不依按鈕成功字樣推算階段。跨頁草稿保留和資料更新需一起驗，不能各自 PASS 就視為一致。
3. **作業與生命週期**：關瀏覽器、關本機程序、取消工作是三件事；程序關閉可能令工作 Interrupted。教學不承諾永續背景服務，不把 CancelRequested 當 Cancelled；重啟載入歷史不等於自動 resume。Q02 必須先處理，再使 C 的重試／續作入口可用。
4. **契約與範圍**：本輪可能需要修改 HtmlConsole 的安全投影、錯誤回應與相容的 console-job metadata，不能再估為純前端整理；核心遷移／信任／核准及 sealed 檔格式維持既有規則。若實作查明需改核心契約，回來討論，不用 UI 需求掩蓋改版。
5. **批次調整**：A 規模由中調為中偏大；Q01/Q02/Q03/Q06 構成共用基礎，可按完整依賴拆 A1（讀取／上下文）、A2（提交／歷史／錯誤）。B 接 Q09；C 接 Q04/Q05/Q07/Q08；D 據最後行為寫教學；E 接 Q10 及全部反例。每段需能獨立驗證及回復，不把後端相依留到 UI 提交後補。
6. **驗收層次**：規劃走讀只證明有列入；DOM／mock API 證明狹義互動；真實瀏覽器＋本機 bridge 才驗 session／傳輸／表單；固定快照核心測試驗核心契約；Server／產品／業務實機資格仍獨立。現有瀏覽器傳輸未通過是 A/E 的完成阻擋，不可用文件補完取代。
7. **文件治理**：AGENTS 下方第三輪既有定案仍是有效基線，但其中「本輪」歷史用語不應覆蓋頂部明示的 R4 規劃狀態。本輪驗收矩陣以 R4/Q 編號定位；不為本次複審重寫或閱讀 archive。規劃階段的歷史執行紀錄保留原意；實作狀態以本輪實作紀錄及驗收證據為準，文件 commit 不等於 A–E 全部完成。

### 補強覆蓋與討論點

| 新增需求 | 對應原需求 | 完成前必要證據 |
|---|---|---|
| Q01、Q04 | R4-04/05/08 | 跨視窗、慢回應、草稿及衝突反例；真實瀏覽器焦點 |
| Q02、Q06 | R4-09/12 | 回應遺失／重啟／409 的本機 bridge 測試，不重複執行的工作紀錄 |
| Q03、Q05、Q09 | R4-02/07 | 新舊作業相容、歸屬與歷史報告、核心結果計數比對 |
| Q07、Q08 | R4-01/03/08/10 | 三角色任務走讀、allowlist 覆蓋、鍵盤／長內容／適用資料量 |
| Q10 | R4-11 | 生成清單及最終 ZIP，未知文件保留、PLAN 不外露為手冊 |

建議採用「提交不明先查既有作業＋本機作業歸屬相容擴充＋沿用受驗證報告的 Windows 開啟方式」。這使本輪能處理真實使用問題，而不新增獨立分頁 session 或報告檔案服務。本次實作指示已採必要本機橋接補強與 Windows 預設程式開啟方式。若未來改成報告必須在 web 新分頁呈現，須另補獨立設計及驗收。其餘補強是既定分頁／教學／資料一致性要求的可驗收細化，皆在本輪實作範圍。

## 本輪界線

- 不做各瀏覽器分頁獨立角色／配對，不新增遠端／常駐服務、自動安裝、額外adapter、檔案合併或覆寫核准。
- 不更換框架、引入遠端資源、不改資料庫／sealed plan／receipt／journal格式以配合視覺設計；若核對發現不可避免的契約改版，先提出討論。
- 不讀取/整理`docs/archive`、不讀個人prototype，不清除或覆蓋使用者資料。
- 外部Server／IIS／排程／SMB／產品業務／企業PKI／規模與原production資格待驗清單保留；本輪完成不能取代實機資格。

## 執行紀錄

- 2026-10-11：使用者確認兩項介面方向；完成本輪規劃及入口對應。runtime、測試、生成HTML與打包工具未修改；尚未開始A–E。
- 2026-10-11：依使用者要求完成四視角原碼複審，補 Q01–Q10、八種使用情境、全專案相依與待討論方案；修正前版過度肯定的相容結論。只修改規劃文件；未將原碼走讀計為實機驗收，尚未開始 A–E。
- 規劃文件驗證：提交前核對需求矩陣、來源位置、代理入口與授權敘述、Markdown格式及diff；結果與文件commit另由提交記錄保存。

設計參照：W3C [Consistent Help](https://www.w3.org/WAI/WCAG22/Understanding/consistent-help.html) 與 [Tabs Pattern](https://www.w3.org/WAI/ARIA/apg/patterns/tabs/)。這些是設計/驗證準則，不構成現有頁面已符合無障礙規範的證明。

## 第四輪實作紀錄（本輪起點 50f137b）

- 主代理可信身分：本 chat rollout 的 turn_context 記錄為 `gpt-6.1-sol`／`medium`；runtime／使用者文件實作者目前均為 `gpt-6-luna`。主代理負責規劃紀錄、獨立核對與驗收，尚未親自修改 runtime，因此可於完整性門檻通過後執行不同模型體檢；後續若親自修正受檢產物需更新範圍。
- 2026-10-11：主代理依使用者授權開始 A–E；bridge_a 使用 gpt-6-luna/high 處理 A 後端橋接，frontend_a 使用 gpt-6-luna/high 處理 A 前端狀態，verification_map 使用 gpt-6-luna/medium 做驗證地圖及 D/E 文件產生與封裝實作。單檔單 writer；由主代理獨立驗收及推送。
- E1 文件產生／封裝：通用排除 PLAN HTML；辨識的舊生成檔才清除，同名手寫檔與 reparse 候選保留；頂層 PLAN Markdown 交付契約維持。主代理檢查真實 consumer 與 diff，Git index 固定快照 `e-pack` 的 HtmlDocumentation、Qualification、ScriptEncoding 在 WinPS5.1／PS7 共 6 支全部通過，來源 manifest 前後不變。Qualification 含實際 ZIP manifest／payload 讀回；生成 HTML 尚待最後來源同步後重建，不因此標整輪完成。
- 2026-10-11 傳輸環境決策：使用者選擇「保留目前設定，先完成所有可驗項目，傳輸完整性明列未通過」。本機實測 CSP 被加入 local.adguard.org，教學回應長度與原始檔案不同；原始 socket 有重設／逾時，程式回應寫入 trace 已完成。保留安全設定，採標準 HTTP consumer 驗功能；資產 bytes／CSP 完整性獨立列 NotPassed，不宣稱所有重設均已證明由同一因素造成。此決策解除必須調整環境後才能收尾的要求，其餘原定實作與可驗項目仍全部完成後才收尾。
- E1 提交／遠端：`8b51e1653262ac6cd91d958227196ca22bd58c28` 已推送 `dev`，遠端 SHA 相符；GitHub Actions run `38107964084` 的 fixtures、delta-workflow、R2 與 R3 雙引擎共六個工作全部 success。此結果只涵蓋該提交，不能代表仍在實作的 A–D 已通過。
- 主代理實作中獨立核對：`GetNewClosure()` 建立的軟體保存回呼無法解析未匯出的 `Get-WsmHtmlDataVersion`；在模組內建立再呼叫的隔離反例重現 command-not-found。交由 bridge_a 修正函式綁定，要求實際同一回呼的合法保存成功，以及 DecisionRevision／資料內容單獨變更時的鎖內拒絕；未以 callback 參數隱藏測試替代保存閉環。
- 主代理使用者情境核對：作業列表更新時，報告／審閱預填按鈕缺少穩定焦點識別；跨視窗配對同步也須明示清除原配對未保存輸入並清除軟體 dirty 狀態。交由 frontend_a 補齊並以背景其他作業變更、跨視窗寫入前同步反例驗證；尚未將中途核對標為完成驗收。
- 最後接線核對確認並修正：總覽原生 steps 使用 label/value/source 而前端仍讀 title/note，導致實際階段空白；ProducedUtc／planHash／approvalReference／交付識別未呈現；ReviewRequired 工作結束未使頁面失效；help/docs 靜態頁焦點刷新誤呼叫不存在的 view；空白取消選取原因被舊原因覆蓋；乾淨軟體欄位未採最新保存值。以上由原 writer 補齊真實 producer 形狀反例，主代理逐項重查消費端。
- 鎖內保存反例改為一次只改 DecisionRevision 或 dataVersion，其餘向量維持正確，精確核對拒絕原因、catalog SHA-256 與軟體選擇均不變；合法保存使用與 HTTP 路由相同的回呼工廠。sealed inventory 投影核對 source 選取與 Include 子集；非 sealed approval 保持原核心可編輯語意。
- 前端 44 項局部單元與 Edge mocked API 2501 列劇本曾通過；最後計數翻譯與 native counts fixture 尚在補驗，這些中途結果不代替最後固定快照。真實 Node HTTP bridge 在服務端記錄 invalid_token 後仍遇 ECONNRESET，另一次在 inventory 重設；維持 NotPassed，未用重試挑選一次成功作整套通過。

### 固定產物前的實作完整性核對

主代理直接核對下列實際接線；這是實作證據，正式測試结果及最終文件狀態在後續紀錄，不能以表格代替驗收。

| 需求／複審項 | 最後實作使用端與證據 |
|---|---|
| R4-01/03、Q08 | index 八頁說明、console guidedTasks／actionGuidance／fieldGuidance → 同一 metadata typed 表單／預覽／確認；全部原生 action 名稱有繁中用途入口，完整進階操作可搜尋到達。 |
| R4-02/08、Q04/Q07 | navigate／hashchange／popstate／aria-current → 八頁及直接連結；選取／版本／安全表單草稿在頁內保留，beforeunload 與配對切換提示；跨頁、焦點與輪詢有 browser 反例。 |
| R4-04/05、Q01 | Get-WsmHtmlRevisionVector／ViewSnapshot／SpecReviewSnapshot 鎖內綁定 → getView 完整 identity、request 序號／epoch → ensureFreshContext；保存與工作結束使相關頁面失效，各種 revision／dataVersion 不混用。 |
| R4-06 | 軟體頁的重載比較與 startTargetSnapshot → TargetSnapshot／PublishComparison 真正表單；guide 說明目標本機擷取、Manager 可信匯入，無暗中盤點／自動還原。 |
| R4-07、Q09 | 原生 catalog／StageResult／DeliveryReceipt／ReportCounts → OverviewProjection → renderOverview；目前世代各階段、C/NonC 項目／檔案／路徑／讀回、軟體準備、業務接受分開，來源／時間／hash 可查，未知中性且無虛構百分比。 |
| R4-09、Q02/Q06 | 待查 operationId 在送出前以原分頁 sessionStorage 保存純識別資訊 → 同一 ID 查 durable job；安全錯誤與 correlationId 接 HTTP／job／errors.jsonl；完整 body 逾時，不自動重送寫入。真實傳輸獨立列 NotPassed。 |
| Q03/Q05 | 新 job 保存 workspace／pair／role／session／context／各revision／Actor；舊紀錄保持未知；歷史可查、跨配對不直接預填；報告沿受驗證 hash／路徑交 Windows 預設程式，不宣稱 Opened 已顯示。 |
| R4-10 | guide／ASSISTIVE-OPERATIONS 完整繁中教學 → 工作台 help/docs 六分類 → 原始手冊與 11 份生成來源投影；靜態頁焦點刷新不要求 nonexistent API view。 |
| R4-11、Q10 | 產生器排除全部輪次 PLAN、只清可辨識生成殘留 → 路由排除 PLAN → release ZIP；保留原 Markdown 交付契約。實際 ZIP 已逐檔比 manifest/source bytes、11 份來源 hash、15 HTML／139 本地引用；prototype/archive 未入包。 |
| R4-12 | 完整相依的 A/B/C/D 與來源投影共用安全橋接；不能拆出未依赖完成的單檔提交。E1 已推送，最後 feature 及證據同步提交待下面正式驗證完成後記錄遠端 SHA。 |

固定快照：`abc-final` 保留工作區實際 bytes（非舊 Git index），所有原生 suite 均在隔離副本執行。獨立 browser 初跑揭露測試同步競態：activeAction 已由上一份同類草稿恢復，不能代表新預填完成；修正只等待新 PreviewPath／ExpectedRevision／ReviewWindowsSettings 出現，保留全部原斷言。新快照 `abc-browser-final` runtime 相同，修正後獨立 Edge mock 劇本通過；45 前端單元通過。此 test-only 差異不改原生受測 runtime，沒有以重跑挑選結果迴避缺陷。

- 真實模組探針揭露 StrictMode 缺陷：資產長度初始化讀取 `$null.Length`，造成尚未測資產就回 NotTested／PropertyNotFoundException。bridge_a 僅修正初始化為未知，成功讀取後才填實際長度；新增真實匯入模組 consumer，證明原 initializer 失敗與四資產合法檢查成功。主代理固定 `abc-probe-final` 補驗 Probe／HtmlConsole／Comparison／Qualification／ScriptEncoding 雙引擎 10/10 PASS，manifest 前後一致。
- 修正版原生探針實测：整體 `ModifiedTransport`，四資產均 ModifiedTransport、Error=null；index 17504→18014 bytes、guide 18235→18745 bytes，JS／CSS bytes 長度相同但標頭差異。原始傳輸完整性判 NotPassed；保留 AdGuard 設定。IAB 本機工作台只能確認初始 HTML，session 持續連線、動態操作未通過；另開靜態 guide 可讀。Edge mocked API 的操作驗證與這項真實傳輸結果分列。
- 最後相容性檢查重現另一 StrictMode 缺陷：舊式操作 body 未帶三個 optional CAS 欄位，直接讀取屬性令合法請求失敗。bridge_a 新增 guarded extraction 接原 canonical hash，未提供欄位採 null，新向量仍全部綁定；主代理確認 HTTP route 消費此 helper。修正後 HtmlConsole 局部雙引擎 58 checks，主代理固定 `abc-feature-final` 另行補驗，不能用先前 57 checks 冒充最後版本。
- `abc-feature-final` 實際 ZIP：109 payload、15 HTML、11 來源快照、139 本地引用全部核對，problems=[]；工具指紋 `18cce0655a3ad46ed109558bfc5f243cb4bc1117c63228ac0481ba5059158a36`。ProductionVerified=false、未簽章；這是最後 runtime 與當時文件 bytes，收尾來源文件同步後仍需重新生成與封装核對。

### 功能提交與完整回歸原始結果

- A/B/C/D 與完整相依已提交 `18709bc40eac69adf479f1d1defdda61815b4c84`，推送 `dev` 後遠端 SHA 相符。GitHub Actions run `38114489760` 六個工作全部 success；這項證據涵蓋該提交，不冒稱覆蓋其後修正。
- `abc-feature-final` HtmlConsole／Qualification／ScriptEncoding／HtmlDocumentation 雙引擎 8/8 PASS，manifest 前後一致；其中 HtmlConsole 為 58 checks。與 probe 固定快照 10/10、UI 45/45、Edge mocked API 2,501 列劇本分列，不等同真實本機動態工作台通過。
- `abc-final` 廣域回歸完成：WinPS5.1／PS7 各 106 支，共 212 次；原始結果 206 PASS，WinPS CancellationWorkflow／DeltaContracts／EnvironmentConfirmation 與 PS7 DeltaContracts／EnvironmentConfirmation 超過 runner 360 秒，PS7 NativeExecution 於 silent-child 觀察斷言失敗。原始失敗保留，未寫成全 PASS。固定快照 manifest 前後一致；實體大檔測試依使用者既定小範圍政策排除。
- 五個逾時劇本保留原 fixture／斷言，改為單 worker、runner 上限 1,800 秒，使用包含最後 native 修正的 `abc-feature-final`。已確認 WinPS CancellationWorkflow 273.22 秒、WinPS DeltaContracts 543.36 秒、PS7 DeltaContracts 777.09 秒、PS7 EnvironmentConfirmation 671.81 秒 PASS，PS7 各快照 manifest 不變；WinPS EnvironmentConfirmation 仍待完成。提高外層等待時間不改核心 operation timeout 或產品 gate。
- 最後使用者走讀發現確認文字將切換角色／配對的清除效果混用；實際同配對角色切換保留選取／軟體草稿，僅清操作表單草稿，配對切換另清選取／版本。frontend_a 僅校正提示，既有取消切換測試新增精確提示斷言，主代理親跑語法及 UI 45/45 PASS；正式固定產物補驗與提交待下方紀錄。
- 主代理固定 `abc-native-prefixed` 獨立重現原 NativeExecution 測試的觀察者競態：原始測試僅在 test-owned observer 加十秒啟動延遲與安全失敗診斷，runtime 不變；PS7 exit 1，TimeoutException／Elapsed=3／stdout=0／stderr=0／pipeline results=0／progress 已清除，但 ObserverSamples=0、observer 仍 Running。保留原始斷言及失敗結果，不以一次正常重跑替代反例。
- bridge_a（gpt-6-luna/high）只修測試：observer ready 握手上限二十秒，原 native TimeoutSeconds=3 保持；LastObservedActivityUtc 由 test factory 時間至 timeout return 界定，且每筆 silent progress 必須保留相同時間。原 helper 寫 marker 的時間受排程影響，不能用正負二秒猜測其等於 process 起始；未放寬 native 輸出／清理／throttle gate。
- 主代理再查出延遲參數未明確跨模組綁定的驗證缺口，交由原 writer 補第三個參數與實際 ready timestamp 下限斷言。最後 `abc-native-bound-final` 原生測試雙引擎正常 2/2 PASS（22.44／25.03 秒）、實際十秒延遲 2/2 PASS（32.38／35.55 秒），兩次 manifest 前後均一致；先前未量測延遲的 PASS 不當作有效十秒延遲證據。
- `abc-audit-final` 對提示修正及當時測試實作的 NativeExecution／HtmlConsole／Qualification／ScriptEncoding 雙引擎 8/8 PASS；UI 45/45 及 Edge mocked API 2,501 列完整劇本 PASS。此快照至 `abc-native-bound-final` 只有 NativeExecution 的參數綁定／量測差異，已另補雙引擎正常與延遲驗證；兩者 runtime 相同。其餘廣域結果按上述版本差異及覆蓋範圍沿用，不稱單一最後快照跑了全部 212 項。
- 提交前由原 frontend writer 統一其檔案為 Windows checkout 的 CRLF；主代理核對只改換行、BOM 保持，實際三個修正程式／測試檔 bytes 與目前 Git 設定預期的 Windows checkout 相同（Git index 採 canonical LF，不能宣稱兩者 raw bytes 相同）。`abc-checkout-final` 對最終 bytes 補 Qualification／ScriptEncoding 雙引擎 4/4 PASS、manifest 不變；最終封装指紋另由收尾實際 ZIP 計算。
