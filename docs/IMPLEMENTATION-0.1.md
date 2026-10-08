# 0.3 逐項實作與驗證紀錄

2026-10-08，分支 codex/implementation，本轮起點 7287399；新增改動仍在工作區。狀態為「持續補齊，未完成全規劃」，尚未進入不同模型獨立體檢。已完成項從當期待辦移除，原始 PLAN 的需求及驗收條件保留。

## 實作對照

| 項目 | 已實作程式／交付 | 目前證據與界限 |
|---|---|---|
| A／R14–15 來源探索 | Inventory、Discovery、EnterpriseDiscovery、RawEvidenceManifest | 原 probes／deep enterprise fixtures；未知產品仍明確 Unsupported／Partial；真實 Server 矩陣待環境 |
| B／R05、R10 大量審核 | AdvancedReview、Review、Templates、MigrationWizard、IdentityMapping | 原 25／32 語義契約、100k 合成；runtime SID 必须符合批准 TargetAccount；精靈與部分異常旅程待加測 |
| C／R01、R11 集中／離線文件 | Core、WorkspaceRecovery、Reports、Fleet、Archive | catalog／fleet 交易中斷測試；源／目標 StageResult 綁 plan／target／generation，非生產資格 |
| D／R02、R09、R13 資料包 | Payload、StreamingDigest、PackageTransport、ToolRelease | 真實測試目錄 bytes／ACL／chunk／排除／ZIP分卷／受信解包／改包阻擋；資料最終代次是 full snapshot、非變更量傳輸 |
| E／R07、R08、R12 還原與驗證 | Restore、Adapters、IisAdapter、NativeTools、JournalRecovery、Recovery | disabled task 註冊、service staging、feature reboot、HTTPS metadata；file scope 真實檔案／ACL與日誌 replay；服務／IIS OS API 為 fixture |
| F／R03–04、R06、R16 切換／回退 | Cutover、CrossHostGates、SourceResults、OperationReport | fixture 網路及啟用、source freeze 漂移界限、provider 過期／缺證據阻擋、新交易協調、FinalAccepted／RetirementReady 分離 |
| 工具部署／可信操作 | 精確 tool fingerprint、固定 API OperationRequest、module／CLI、OPERATIONS.md | 白名單資料請求、記憶體 SecretRef、UTF8 BOM／5.1；工具未用企業憑證簽署，policy／信任根由企業驗收 |

目前 generic 自動 adapter：FileScope、ScheduledTask、Service、SmbShare、MachineEnvironment、WindowsFeature、IISPool、IISSite、Certificate、LocalUser、LocalGroup、FirewallRule；另有 ManualWorkflow 的專用流程證據門檻。implemented 不等於 ProductionVerified；能力矩陣全部仍維持 ProductionVerified=false。ManualWorkflow 不視為產品自動還原實作。

## 當期待辦（尚未實作／待補齊，不能宣告完成）

- [ ] rollback／activation 半完成的可恢復 checkpoint。adapter durable absent-before intent 與 staging／absent／drift reconciliation 已通過 fixture。

- [ ] 部分原生錯誤退出碼、超時、已分類修復建議及其他 adapter 原生錯誤分類。
- [ ] 大 payload index 的 metadata 去重／記憶體上限與進度、大量小檔真實測試。ZIP 匯出中斷續跑已經 fault fixture 驗證；實際 >4GiB 已通過，長路徑目前明確阻擋。
- [ ] 完整 IIS schema／nested 設定與額外配置 drift、服務依賴／帳號／補充設定的逐字段驗證及更多 adapter 正反例。
- [ ] 跨台應用循環群組的 freeze／activation／rollback 協調與承接生產資格資料契約；現在必要 provider 缺結果會阻擋。
- [ ] 依真實盤點為實際入選的第三方 runtime／DB／角色補專用自動模組或已驗收專用流程，未知項不能默默排除。
- [ ] 最新所有程式的全量 5.1／7 fixture、CLI、DOM QA、CI、公共 PR 文件同步與整輪再核對。

## 需要實際環境的驗收（不能用合成代替）

- [ ] 代表性来源盤點和完整十台清單；owner／產品版本／媒體／容量／RPO／RTO／維護窗。
- [ ] Server 2016／2025／Core、zh-TW／en-US、32bit runtime、不同 policy／權限的 collector／export／restore／verify 矩陣。
- [ ] 真正 IIS／服務／任務／分享／憑證／帳號還原及 reboot 後 staging、網域改名／IP／DNS／Kerberos、實際業務接受。
- [ ] 單台 pilot、兩台有相依應用、實際十台波次、回退演練、備份實還原／長週期工作／觀察／保留清理。

已提出隔離 Server 環境與代表性來源盤點輸入需求，尚未收到。這些缺失不會被改寫成「不在本輪範圍」。不自行操作未指派的生產主機。

## 已有證據（均不代表生產資格）

- SourceRecovery：兩個服務部分停寫失敗保留原始設定與執行狀態；重試、來源明確唯一寫入權回復 fixture 通過。來源及目標工作目錄與 FileScope 重疊在建立操作目录前阻擋。
- MenuContracts：0 取消、literal:0、EOF、錯誤保留原頁與篩選原子編輯通過；網域改名 credential 已接入精靈記憶體 SecretRef。
- ScheduledTask：CatchUpPolicy 必須明確審核；未審核阻擋、跳過與專用補跑停用 StartWhenAvailable、保留來源政策 fixtures 通過。
- 確認報告補來源／目標 scope、排除、資料一致性、metadata／ACL／漏跑政策、最終狀態、spec 與 Desired 雜湊；原始 Desired 保留於受控 catalog。

- 批次規格草稿／整批預覽／一次 revision 原子套用：Test-BulkMigrationSpecs 通過；無效一列整批不寫入、缺列不排除、舊版拒絕。
- 最新 pipeline：wsm-pipeline-150cc633649340148357b480e32741bf，包含 ZIP 中斷續跑、相同 transport 重試、freeze renewal。
- 實際 >4GiB：wsm-large-file-d1d5277ac9bd443d8a0f3c0de4b3a309，4294967313 bytes／513 chunks／143.0594秒；整檔 hash、尾端和實際還原通過。已修正 Math.Max int32 溢位。
- 全量 5.1 contracts／inventory／advanced／archive／report DOM／CLI／adapters／deep discovery／IIS／recovery／requests 通過；批次規格及後續改動需納入最後一版重跑。

- Pipeline（Windows PowerShell 5.1）：wsm-pipeline-82ed7c270c2f468cb109a6c2411897e8，包含 bytes／ACL、分卷、retry、final/deletion/backup、證據失效、改包、journal/checkpoint 落盤中斷 replay。之後有新修改，最後版必須再跑。
- RecoveryContracts：wsm-recovery-2af559f2868f40e0b02268b1a09518df，管理端交易中斷、freeze 非停寫漂移、SID override 拒絕、bounded reader、provider 缺失／過期。
- Adapters、EnterpriseDiscovery、IisContracts：5.1 fixture 通過；IIS fixtures 只驗 metadata／規格，不是真正建立 IIS。
- 合成十台×10,000：wsm-scale-473e7b8a0c9c4a6494d097207bf94dd1，總耗時 973.6 秒；在管理端 PowerShell 7 單台搜尋／分頁 10 次量測平均1.3236秒、最大1.8166秒。不是 WinPS5／Server／網路效能承諾。

下方為前版歷史操作與驗證記錄；現況以上表及 OPERATIONS.md 為準。

---

# 0.2 歷史記錄（非目前待辦）

日期：2026-10-08。狀態：第一階段實作中，非全計畫完成。本次比對基準：`2189f395`，分支：`codex/implementation`。本輪主代理親自實作與驗證；尚未進行不同模型獨立體檢。

## 操作者流程

1. 每台來源保留同一盤點目錄；`source-state.json` 是來源識別及版本，不要複製給另一台或任意刪除。MachineGuid／硬體 UUID 的雜湊協助防止誤配；不是抵抗惡意竄改的身分證明。
2. 盤點會保留服務、排程 XML、軟體、分享與分享權限、磁碟、本機使用者／群組成員、憑證中繼資料、IP／DNS／路由、防火牆、已安裝角色、IIS 站台／App Pool／中央設定。失敗項目另列 `CollectorFailure`，不冒充完整。
3. 每個類別另有 `DiscoveryGap`，要求服務負責人確認探索邊界。沒有輸出項目不等於不存在；空集合及未完整探索不能當成自動排除。
4. 在管理端先建立工作區，選 19 驗證 ZIP 匯入或匯入解壓 JSON，再匯入並指定新主機暫用名稱。來源 GUID 配對至目標名稱；同一指紋以不同來源 GUID 匯入會拒絕，需要先確認是否複製／重建識別。
5. 在選單按類別或文字過濾，每頁 50 筆；納入／排除可選本頁多筆，畫面列出數量後輸入 APPLY。`all` 只代表目前一頁；`a` 代表全部符合目前篩選的跨頁項目，先預覽件數、樣本、相依衝突，再確認 APPLY。可保留篩選、排序與頁大小，選項 20／21 只跨主機複用條件／理由。
6. 大量決定匯出 CSV。只可修改 `Decision`（Include／Exclude／Pending）與 `Reason`；排除必須說明理由。ID、版本、類別、名稱不可修改。刪除列表示不更動該項；未知／重複 ID、無效決定、舊版本或修改唯讀欄位，整份拒絕。
7. CSV 的名稱／理由若以 `= + - @`、控制字元或單引號開頭，匯出時加單引號。保留唯讀名稱的原始值；理由欄若要保留字面上的開頭單引號，請填兩個單引號。以文字格式處理 CSV，避免試算表改寫長 ID／版本。
8. 可撤銷最近一次決定／CSV 操作。修改對應或再次匯入來源盤點後，不能穿越這個邊界撤銷先前決定。所有審核內容修改增加 DecisionRevision 並使既有核准失效。
9. 新盤點只有設定、相依項目、狀態皆未變動的項目保留既有決定；變動／消失的項目重新 Pending。消失項目保留歷史，不自動當作不需遷移。
10. 所有項目已有決定且已宣告的必要相依項目沒有衝突，才可核准審核文件。未成功／消失／DiscoveryGap 項目即使排除，也必須使用選項 11 記錄負責人與外部補查證據參考；只有排除理由無法通過。證據由操作者負責真實性，工具不會自行驗證文件内容。核准不能用來宣稱完整可還原。

## 管理者／交接

- HTML 使用內嵌資料、無 CDN，可搜尋及按類別篩選，每頁 100 筆；列印按鈕在 2,000 筆以內列出所有符合項目；更多時提示使用同時產出的 `.html.txt` 完整分類文字報告。列印前清空搜尋／類別可列全部。原始 Settings 不嵌入 HTML，避免排程參數／IIS 密碼直接外洩；名稱、排除理由及路徑仍可能敏感。
- 全批次報告按來源／目標配對顯示數量、收到時間、年齡與審核版本。另列負責人／波次、24 小時過期及時間偏差提示、跨主機相依與已收到的階段結果。結果匯入檢查版本、UTC、階段序號；尚無階段結果產生器，非 Inventory 的 Succeeded 會拒絕，避免假成功解鎖。未提供跨主機遠端執行或即時進度。
- 新建資料目錄限制給目前使用者、SYSTEM、Administrators。已存在的目錄不改 ACL，使用前自行確認既有 ACL 適當。工作區是單一管理端檔案鎖寫入，不支援以同步軟體／網路分割建立多寫入者。
- JSON 原子替換採同目錄暫存／備份。catalog 與 fleet 為兩個檔案，初次配對遇到磁碟錯誤可能留下未登錄 catalog；沒有跨檔案交易或自動修復，需保留證據後處理。
- 來源 ZIP 只封裝該代 JSON 與 JSON 雜湊；不含識別狀態及舊世代。先驗 ZIP 內 JSON 的 SHA256，再改為正式 ZIP。壓縮失敗拋錯且不留下 `.partial`；成功 JSON 世代保留，下次執行建立新世代。
- JSON 單檔限制 128 MiB。這是目前的安全／記憶體限制；尚未提供分割大型盤點或歷史封存。不能宣稱可處理任意大型設定 XML／資料搬移包。

## 企業項目與尚未完成範圍

實際企業遷移還需處理服務 recovery／trigger／ACL、排程資料夾 ACL／認證、網站檔案與子層 web.config、IIS shared config／模組／金鑰、HTTP.sys／TLS、NTFS／ReFS ACL／junction／DFS、資料庫／ODBC、環境變數、COM+、訊息佇列、憑證私鑰、gMSA／SPN、GPO、DNS／DHCP／AD、叢集、備份／監控／資安代理、授權及外部 API／SMTP／儲存依賴。本版尚未完整收集或還原這些內容，十二類 DiscoveryGap 會讓它們保持可見。

對照 R2：

| 階段 | 已實作（已從待辦移除的部分） | 仍未完成，繼續保留待辦 |
|---|---|---|
| A | 原有基礎 probes／穩定 ID，加上人工補列、12 類數量、命令能力矩陣、服務／排程／IIS／分享路徑候選；服務 recovery／SID metadata、ODBC、環境變數、時區／修補、啟動／WMI、SQL 存在提示 | 真實 OS／角色／權限矩陣；完整 raw manifest、深層網站設定／腳本參數／COM 相依；HTTP.sys／私鑰／資料庫等專用探索；候選路徑的業務 scope 確認 |
| B | 跨頁規則／差異預覽／RuleId／撤銷、跨台條件模板、人工補列／應用組合／內建分類、保留篩選排序、CSV 預覽及摘要凍結、路徑／帳號／端點 mapping、重疊路徑阻擋、循環相依及有責任證據的一致性群組 | 目標硬體身分、真實 SID／帳號與端點驗證、junction／UNC alias 等實際路徑衝突；角色分流選單／一致取消／詳細錯誤及 bounded logs；資料 scope 可搬移判定 |
| C | HTML 分頁與完整分類文字、審核 hash、過期提示／波次／跨台圖、受信摘要鎖定讀取、安全盤點 ZIP 匯入、階段結果接收／舊序號拒絕 | 結果包產生與 payload／目標世代綁定、可信摘要實際交付／簽章策略、雙檔案交易修復、最新 100k 基準與完整瀏覽器／主控台實測、發行包驗收 |
| D | 尚無實際 payload 匯出；盤點 ZIP 僅設定證據 | 核准驅動資料 scope／檔案／ACL／EFS／ADS、可信 artifact manifest、空間估算、分割／續跑、initial／final delta、資料一致性與來源停寫證據 |
| E | 尚無還原 adapter，ExportReady 一律 false | dry run、目標前置／漂移檢查、停用 staging、冪等還原、原生碼判定、journal／崩潰恢復、逐項設定／權限／功能驗證及 rollback |
| F | 來源目標配對、暫用／最終名稱 IP、責任／波次及跨台相依計畫欄位 | 切換計畫執行／停寫交接、名稱 IP 接手、重開機與啟用控制、寫入所有權／交易後回退、業務驗收／觀察／備份實還原／退役門檻 |
此表是實作缺口，不是縮減 R2 承諾。開發持續依計畫補齊；Server 2016／2025 真實盤點與還原測試需獨立紀錄。

## 已完成驗證

- Windows PowerShell 5.1：25 項語意契約檢查通過，涵蓋可信雜湊、舊世代拒絕、無效批次原子拒絕、相依衝突、CSV 公式防護、撤銷、HTML 字串防注入、Settings 不外洩、核准回讀、設定漂移、缺口補查證據、缺列不變更。
- PowerShell 7.6.5：同一套 25 項契約檢查通過；修正其 JSON 整數為 Int64 與 5.1 Int32 的差異。
- Windows PowerShell 5.1：全替代 OS probes 的盤點 fixture，驗證排程查詢中斷仍保留成功子項／失敗項、十二類缺口、ZIP 碰撞回報失敗、重試保留來源身分、只封裝該代及清理 partial。
- PowerShell 7.6.5 十主機／十萬項壓力驗證通過：每台一萬項的 JSON 匯入、第二頁查詢、整批 CSV 排除、分類 HTML 及十主機彙整，總耗時 516.9 秒。這是本機合成設定資料的端到端時間，非網路傳輸或真正服務遷移速度。測試後新增 Owner／Evidence 欄位與 CSV 檢核進度；最新完整功能以十台／2,000 項整合重驗及 25 項契約測試覆蓋，未重跑十萬項時間基準。
- 實際 IAB 瀏覽器以合成 126 筆資料驗證換頁、搜尋、類別篩選與無 console error；修正 label 後的最後版未再完成瀏覽器驗收。未進行實際 Server、還原或業務切換測試。
- Windows PowerShell 5.1：選單入口啟動與退出 smoke test、非互動 Initialize 及非互動 Menu 立即拒絕／退出碼 1 通過；修正 param 區域求值時 PSScriptRoot 為空、Read-Host 失敗後無限重試的相容問題。完整互動主控台按鍵流程仍待實機驗收。
- Node.js 最小 DOM：205 筆報告的首／次／末頁、返回、注入字串的純文字搜尋、類別篩選、列印全部 205 筆通過。此測試不代替真實瀏覽器版面／互動驗收。

## 本次程式比對與補實作驗證（2026-10-08）

本專案沒有獨立 TODO 檔；上表就是未完成清單。已完成的子項已從右側待辦移除，保留左側程式／驗證證據；原 PLAN 的需求與歷史風險不刪除，避免抹去驗收標準。全輪尚未完成，不能把 D/E/F 或尚缺實機證據的 A/B/C 勾掉。

- `Core.ps1`：受信 hash 與讀取共用鎖定 stream，未知 tool/schema 拒絕；7.6 JSON 日期維持 UTC 字串；0.1 catalog 升版清除核准，人工項重新盤點保留。
- `AdvancedReview.ps1`／`Templates.ps1`／`Review.ps1`：跨頁範圍與版本凍結、決策 undo、相依及映射、人工責任證據、條件模板、CSV 預覽後摘要核對。CSV 新增 BatchId／PairId／SourceHostId／InventoryRevision／AllowedDecisions；0.1 CSV 必須重匯出，不直接沿用。
- `Discovery.ps1`／`Inventory.ps1`：只列候選與宣告依賴，候選維持 Unsupported，不冒充已搬檔／可還原；DTD／外部 XML entity 禁用。新企業 probes 仍缺實機及完整 fixture 覆蓋。
- `Archive.ps1`：只接受獨立可信摘要、兩個固定格式 entry；拒絕 traversal／絕對路徑／ADS／reserved／腳本／巢狀／重複與大小寫碰撞；限制膨脹／實際讀取長度，不執行內容。
- `Fleet.ps1`／`Reports.ps1`／入口：波次與跨台依賴、逐階段序號、過期／時鐘偏差、完整文字輸出、選單 1–21 與非互動入口。
- Windows PowerShell 5.1：25 契約 + 32 advanced 語意檢查、安全 ZIP、替代 probes 盤點 fixture、205 筆 DOM 分頁搜尋列印及 2,001 筆列印 guard 全通過。PowerShell 7.6.5：25 契約 + 32 advanced 通過。
- 最新 0.2 十台／2,000 筆合成整合通過（19.4 秒）。上述十萬筆 516.9 秒為舊版歷史證據，不代表 0.2 已重跑十萬筆。
- CLI 獨立子程序測試：Initialize 成功碼 0、Issues Pending 阻擋碼 2、未知 Action／錯誤可信 hash 拒絕碼 4，且拒絕未改審核狀態已通過；Inventory partial／Issues 阻擋回 2，pipeline 安全取消 3，一般失敗 1。格式錯誤僅已分類的 InvalidDataException／參數綁定回 4，其餘仍可能為 1；完整退出碼契約及取消流程仍待補齊。

不包含生產盤點資料、機密、真實測試主機或自動還原支援宣告。接續先完成 A/B/C 缺口與代表性來源盤點，再按發現的角色實作 D/E/F；既有清單全部保留。
