# 0.3 逐項實作與驗證紀錄

2026-10-08，分支 codex/implementation，本轮起點 7287399；本輪程式已提交並推送 checkpoint `546b3cc`。狀態為「持續補齊，未完成全規劃」，尚未進入不同模型獨立體檢。已完成項從當期待辦移除，原始 PLAN 的需求及驗收條件保留。

## 實作對照

| 項目 | 已實作程式／交付 | 目前證據與界限 |
|---|---|---|
| A／R14–15 來源探索 | Inventory、Discovery、EnterpriseDiscovery、RawEvidenceManifest | 原 probes／deep enterprise fixtures；未知產品仍明確 Unsupported／Partial；真實 Server 矩陣待環境 |
| B／R05、R10 大量審核 | AdvancedReview、Review、Templates、MigrationWizard、IdentityMapping | 原 25／32 語義契約、100k 合成；runtime SID 必须符合批准 TargetAccount；精靈與部分異常旅程待加測 |
| C／R01、R11 集中／離線文件 | Core、WorkspaceRecovery、Reports、Fleet、Archive | catalog／fleet 交易中斷測試；源／目標 StageResult 綁 plan／target／generation，非生產資格 |
| D／R02、R09、R13 資料包 | Payload、StreamingDigest、PackageTransport、ToolRelease | 真實測試目錄 bytes／ACL／chunk／排除／ZIP分卷／受信解包／改包阻擋；initial／final snapshot 與五類差異索引；增量 ZIP 只傳變動 payload，目標重建完整 current package；實機效能待驗 |
| E／R07、R08、R12 還原與驗證 | Restore、Adapters、IisAdapter、NativeTools、JournalRecovery、Recovery | disabled task 註冊、service staging、feature reboot、HTTPS metadata；file scope 真實檔案／ACL與日誌 replay；服務／IIS OS API 為 fixture |
| F／R03–04、R06、R16 切換／回退 | Cutover、CrossHostGates、SourceResults、OperationReport | fixture 網路及啟用、source freeze 漂移界限、provider 過期／缺證據阻擋、新交易協調、FinalAccepted／RetirementReady 分離 |
| 工具部署／可信操作 | 精確 tool fingerprint、固定 API OperationRequest、module／CLI、OPERATIONS.md | 白名單資料請求、記憶體 SecretRef、UTF8 BOM／5.1；工具未用企業憑證簽署，policy／信任根由企業驗收 |

目前 generic 自動 adapter：FileScope、ScheduledTask、Service、SmbShare、MachineEnvironment、WindowsFeature、IISPool、IISSite、Certificate、LocalUser、LocalGroup、FirewallRule；另有 ManualWorkflow 的專用流程證據門檻。implemented 不等於 ProductionVerified；能力矩陣全部仍維持 ProductionVerified=false。ManualWorkflow 不視為產品自動還原實作。

## 當期待辦（尚未實作／待補齊，不能宣告完成）

R02 設定檔分類、精確 ConfigFiles／ConfigOverrides 核准、來源草稿／即時差異報告及完整包／delta 的重新審核門檻已實作並完成主代理驗證；新增、修改、刪除不能沿用舊核准。來源角色 11 可輸出不含設定內容的差異 JSON／JSONL，漂移時需重新核准並建立新初始基準，既有目標 ownership 先按明確回退／協調處理。這項已從未實作待辦移除。

activation checkpoint 已實作並從待辦移除：ActivationRecovery＋Invoke-WsmCutover 的真實入口 fixture 通過；第一個服務啟用後、完成 journal 前失敗，明確 resume 採認 exact-final 且不重啟，後續只啟用一次。無明確 resume、IP／DNS／manifest 漂移均拒絕。原生服務／網路為 mock，實機驗收仍保留。

- [ ] 依實際 provider／產品補齊原生錯誤分類與 Server 正反例；generic typed error、bounded native timeout／取消／partial capture 已實作及主模型測試，不能推成所有產品資格。
- [ ] 大量小檔端到端真實資料測試；payload index 串流、固定 5k key 緩衝／磁碟排序與進度已實作。ZIP 匯出中斷續跑已經 fault fixture 驗證；實際 >4GiB 已通過，長路徑目前明確阻擋。
- [ ] 更多 adapter 原生正反例與精準欄位稽核；IIS recursive schema／nested drift、Win32 own-process SCM supplement、安裝副作用隔離／quarantine、專用 UNC／DFS 角色 scope 契約已有實作與 fixture。完整 Server API／provider identity 資格、更多服務帳號模式與第三方安裝副作用仍未驗收。
- [ ] 跨台循環應用的實際 freeze／activation／rollback 協調與資格驗收；GroupPlan／Receipt／Barrier／RollbackResult／Qualification 契約及消費端已實作，真實群組／產品證據待取得。
- [ ] 依真實盤點為實際入選的第三方 runtime／DB／角色補專用自動模組或已驗收專用流程，未知項不能默默排除。
- [ ] 真實瀏覽器／主控台和整輪實機再核對；程式 checkpoint `10c896a` 已推送、公共 draft PR 已同步，完整 CI 已通過。最新本機測試覆蓋與尚未完成的大量基準見下方，不以舊快照代替最後修改。

## 需要實際環境的驗收（不能用合成代替）

- [ ] 代表性来源盤點和完整十台清單；owner／產品版本／媒體／容量／RPO／RTO／維護窗。
- [ ] Server 2016／2025／Core、zh-TW／en-US、32bit runtime、不同 policy／權限的 collector／export／restore／verify 矩陣。
- [ ] 真正 IIS／服務／任務／分享／憑證／帳號還原及 reboot 後 staging、網域改名／IP／DNS／Kerberos、實際業務接受。
- [ ] 單台 pilot、兩台有相依應用、實際十台波次、回退演練、備份實還原／長週期工作／觀察／保留清理。

使用者已確認有隔離測試主機，但無法讓代理連線。已補本機 LabReport 回傳機制，待使用者執行並複製文字驗證報告；代表性來源盤點與實際測試結果尚未收到。這些缺失不會被改寫成「不在本輪範圍」。不自行操作未指派的生產主機。

## 本輪固定快照與最後修改驗證

- 程式／測試 checkpoint `10c896a`：GitHub Actions [37792481411](https://github.com/darionnnnnn/windows-server-migration/actions/runs/37792481411) 全部工作通過，涵蓋 54 個測試腳本（主要 WinPS 5.1，Fleet／Contracts／Delta 另有 PS7），實際 >4 GiB 與最新 LabReport／設定還原皆通過。正式 src／入口雜湊與最後本機固定快照一致。後續文件同步不改程式或測試，不重算為另一份生產资格。

- `wsm-complete-regression-404a5292f0294e39adad3aabc8da63af`：51 個獨立 child-process 測試，在 Windows PowerShell 5.1／PowerShell 7 各 51/51 通過；src／入口雜湊重驗未變。包含 100k 報告分塊 DOM、十台 × 200 fleet、小型完整 pipeline、真實 >4 GiB、分類設定門檻、原生 helper 與取消等。這是新增 LabReport／設定差異報告及進度接線前的完整快照，不宣稱等於最後 54 個測試全套重新執行。
- `wsm-integrated-final-a0c4645aca3e42f3b49cd2bc7ad110b1`：對修改影響的 12 個測試於兩個 engine 執行，含新增 API／選單／CLI、設定差異與真實核准包→還原→報告、取消及 delta。WinPS 5.1 的新 consumer 測試因未指定 UTF-8 讀取 zh-TW JSON 失敗，已修正；PS7 native fixture 一次因測試負載觸發真實 timeout，單獨同程式重跑通過，沒有放寬正式 timeout 或宣稱該次全通過。
- `wsm-final-lab-locked-952eecc875b34ce097a0f31f29bef197`：最後 LabReport 鎖定／安裝類型／語系修改的 6 項（LabValidation、LabReportConsumer、ConfigArtifactWorkflow、ConfigArtifactReview、EntryPoint、OperationRequests）在兩個 engine 通過；包含實際 CLI 環境報告、來源設定變更清單、真實檔案還原／drift、operation lock 排他、state／journal 不變。原生 OS identity／Server collectors 的還原劇本為 fixture，不能當成 Server 資格。
- 新 consumer UTF-8 修正另於 `wsm-lab-consumer-check-398086955a7e4c8ca3bb48b522636296` 通過 5.1／7；JSON 為 UTF-8、TXT 含 BOM，讀取 JSON 必須明確 UTF-8。
- 10,000 小檔完整端到端測試仍在執行；前次被使用者暫停的 10k run 不計為通過。微基準每 5,000 列 JSON 從約 7.44 秒降至 1.28 秒，不能推成完整 Server 性能或 RTO 證據。
- 瀏覽器政策拒絕代理開啟 `file://`，沒有以其他途徑繞過；最新離線報告的實際瀏覽器 QA 留待使用者於測試機確認。Node DOM 不代替此項。
- `546b3cc` 首輪 CI 揭露 SourceTaskReconciliation 測試在模組內重入時引用外層 `$module` 的作用域錯誤；改為直接呼叫既有模組函式，5.1／7 重驗通過。CI 多腳本步驟改逐一獨立 child process 並檢查 exit code，避免 fixture 狀態互相污染；正式 src／入口未改。
- CI `7036af7`／`524c924` 揭露 delta fixture 的暫存來源 ACL 未持久化 AI 控制位元，target Set-Acl 後增加 AI，Exact 比對正確阻擋。fixture 封裝前對自有暫存來源 ACL 寫回並擷取持久化基準，新增完整 baseline readback 斷言；正式 ACL 政策及全部 src／入口不放寬。增量流程移至獨立 CI job，84ce490 的 5.1／7 GitHub job 通過。ConfigArtifactWorkflow 在 runner 呈現相同 AI 基準差異，亦於核准前持久化暫存來源 ACL；最後設定／還原／LabReport 工作流程已於 5.1／7 本機重驗通過，`10c896a` 完整 CI 通過。
- 原生進度／取消已接入長時間 hash／copy／native wait 與 delta preflight；helper 每秒至多約一次有界進度更新，不輸出 paths／raw stdout，完成後清除。安裝器子程序／服務副作用仍需本機確認。
- 使用者新增離線實機回傳需求：`Export-WsmLabValidationReport`、角色 6、`-Action LabReport`、OperationRequest 均已接線。JSON 保留完整 checks，TXT 優先 FAIL／Blocked 且標示省略數；人工／業務證據維持 NotTested，ProductionVerified=false。未知產品專用模組及真實資格待實際盤點及報告後補齊。

## 已有證據（均不代表生產資格）

- e0ffacb 的兩個 GitHub CI（37731822331／37731817107）通過；本節後續工作樹新增改動尚需全量再驗。
- 真實 SUBST 碰撞、ADS／排他鎖／junction、固定 5k 緩衝的 100,000 key merge／跨段重複與清理、嚴格 artifact metadata、分類原生錯誤、分享完整 ACL fixtures 通過。
- Windows PowerShell 5.1 一萬筆規格：wsm-spec-scale-2eb1cdccf5e7446b952f4b4904d9595f，draft14.01s／preview44.66s／atomic apply42.51s。批次操作有持續進度；不是單筆搜尋時間或實機性能承諾。
- 最新 metadata pipeline：wsm-pipeline-ac06dde0aa8d4af1b61992e4386360cb，含 timestamp-only drift 阻擋；後續 adapter rollback／SMB 改動另需最後版回歸。
- File／一般 adapter 的 rollback intent：搬移前／中／後、停止前／後及移除後恢復；未知備份／配置漂移不採認。角色中斷仍保留 reboot barrier。

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
- 全批次報告按來源／目標配對顯示數量、收到時間、年齡與審核版本。另列負責人／波次、24 小時過期及時間偏差提示、跨主機相依與已收到的階段結果。來源／目標 StageResult 產生器已實作，結果匯入檢查計畫、目標、資料代次、UTC、producer run 與單調序號；報告依產生時間及目前核准版本彙整。各台本機執行，離線回傳結果包；遠端即時控制／推播不在第一版範圍。
- 新建資料目錄限制給目前使用者、SYSTEM、Administrators。已存在的目錄不改 ACL，使用前自行確認既有 ACL 適當。工作區是單一管理端檔案鎖寫入，不支援以同步軟體／網路分割建立多寫入者。
- JSON 原子替換採同目錄暫存／備份。catalog／fleet 使用 staged files、durable transaction 與 hash 驗證；中斷後讀寫阻擋，執行 Repair-WsmWorkspace 完成原交易並保留證據。
- 來源 ZIP 只封裝該代 JSON 與 JSON 雜湊；不含識別狀態及舊世代。先驗 ZIP 內 JSON 的 SHA256，再改為正式 ZIP。壓縮失敗拋錯且不留下 `.partial`；成功 JSON 世代保留，下次執行建立新世代。
- JSON 單檔限制 128 MiB。這是目前的安全／記憶體限制；尚未提供分割大型盤點或歷史封存。不能宣稱可處理任意大型設定 XML／資料搬移包。

## 企業項目與尚未完成範圍

實際企業遷移還需處理服務 recovery／trigger／ACL、排程資料夾 ACL／認證、網站檔案與子層 web.config、IIS shared config／模組／金鑰、HTTP.sys／TLS、NTFS／ReFS ACL／junction／DFS、資料庫／ODBC、環境變數、COM+、訊息佇列、憑證私鑰、gMSA／SPN、GPO、DNS／DHCP／AD、叢集、備份／監控／資安代理、授權及外部 API／SMTP／儲存依賴。本版尚未完整收集或還原這些內容，十二類 DiscoveryGap 會讓它們保持可見。

對照 R2：

| 階段 | 現行已實作程式與契約 | 仍需完成／實際環境驗收 |
|---|---|---|
| A | 穩定 ID、十二類 probes、deep enterprise discovery、raw evidence manifest、路徑／相依與缺口記錄 | 真實 OS／角色／權限矩陣，未知產品專用探索、owner 確認及完整十台清單 |
| B | 分頁／跨頁規則／CSV／模板／撤銷、映射、SID、角色精靈、批次規格、取消與錯誤分類 | 真實帳號／端點／UNC provider 資格；完整主控台實機旅程 |
| C | 分類 HTML／文字報告、版本核准、source／target StageResult、plan／target／generation／sequence 綁定、workspace transaction recovery | 信任摘要交付／簽章與企業 policy、最新大量基準／瀏覽器 QA、實際離線交接 |
| D | 核准 scope／檔案／metadata、chunk 去重、分卷／ZIP 續跑、可信索引、增量差異／ZIP／完整目標 package 重建 | 來源實際一致性／RTO／容量，更多 storage/product 專用方案；ADS／EFS 等明確阻擋不可視為通用支援 |
| E | 既有 generic adapters、staging／readback、service identity／supplement、TaskFolder ACL ownership、journal／rollback／crash recovery | 真實 Server／產品 API、帳號／私鑰／policy／reboot 與業務正反例；未知產品不得宣告自動支援 |
| F | reviewed cutover、activation resume、group barrier／rollback receipt、qualification registry、observation window、acceptance／retirement gates | 真實身份／網路／網域切換、單台／相依雙台／十台波次、交易協調、實際觀察與備份實還原 |

此表與文件開頭的「當期待辦」同為現行狀態；原 PLAN 驗收條件保留。已寫程式／fixture 通過與 Server／業務資格分別追蹤。
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
- CLI 獨立子程序測試：Initialize 成功碼 0、Issues Pending 阻擋碼 2、未知 Action／錯誤可信 hash 拒絕碼 4，且拒絕未改審核狀態已通過；Inventory partial／Issues 阻擋回 2，pipeline 安全取消 3，一般失敗 1。格式錯誤僅已分類的 InvalidDataException／參數綁定回 4，其餘仍可能為 1；主要取消工作流程及實際 CLI 成功 0／失敗 1／取消 3／無效請求 4 已由獨立子程序驗證；既有 Pending 阻擋碼 2 另有入口測試。專用 provider 及完整主控台實機旅程仍待驗。

不包含生產盤點資料、機密、真實測試主機或自動還原支援宣告。A–F 的 generic pilot 程式已持續加入；仍需代表性來源盤點、設定檔審核門檻、最新全量回歸及實際角色／十台验收。

## 本次補實作的獨立驗證（工作樹，尚非完整收尾）

- SCM supplement：主代理 WinPS 5.1 測試通過 Unicode、uint delay、trigger/MULTI_SZ buffer 邊界、SERVICE_START、shutdown privilege scope 與 finally 還原；C# 編譯／unmanaged fixture，未修改真實 SCM 或 privilege。
- SMB：主代理 Test-ShareSourceWorkflow／Test-ShareContracts 通過完整 approved plan → freeze 中斷 → 原始 ACL baseline 保留 → retry → source resume 與 localized Everyone deny；SMB API mock、durable JSON/hash/lock 為真實本機檔案。
- RemoteStorage：load/approval/read-plan/report consumer 已接入；主代理 Test-RemoteStorageApproval 通過跨 source/target/DFS alias overlap 阻擋、excluded 不阻擋、泛用 FileScope UNC 拒絕與報告資料遮蔽。專用產品流程仍由 owner 提供；沒有泛用 NAS/DFS 自動 copier。
- Qualification：主代理完整 record producer → registry → lookup → matrix → revoke 契約通過；不自動建立實機證據，ProductionExecutionEnabled 始終 false。
- WindowsFeature：主代理 adapter 與 failure-details fixture 通過成功／重開機／未知原生 enum 判定、保留 HRESULT_FROM_WIN32 與 token privilege／RPC／busy 分類。New-Service 已改正式 DependsOn 參數，恢復整合使用嚴格 native mock 與非空相依。
- RecoveryContracts 最新主代理 WinPS 5.1 通過；wsm-recovery-7efea3a16dca4eb3b960a668f7057118。新的全量回歸及 10,000 真實小檔 pipeline 仍在執行，未提前列成通過。
- 最新 SMB 5.1 主代理重驗：ShareQuiescence／ShareSourceWorkflow 通過 exact-scope handle、原始 ACL、close-after-effect 中斷與再凍結／回復；ShareContracts 加測 named-scope／同名多 scope 目標拒絕通過。
- 原生只讀查詢：本機 sc.exe query 不存在的生成測試服務，NativeCode=1060 正確傳遞至 ObjectMissing 分類；没有建立、停止或修改任何真實服務。
- 新增 ObservationHours 的 reviewed duration／ActivatedUtc durable journal 與門檻；實際 Server 觀察證據仍待取得。主模型 Test-ObservationWorkflow 已通過啟用中斷／resume／journal replay、提前記通過拒絕及虛擬時間門檻；不把虛擬時間列為實際觀察。
- 主模型 immutable snapshot 驗證：TaskSecurityWorkflow、SourceTaskReconciliation、FleetExecutionBindings、ShareContracts、FailureDetails、Adapters、AdvancedReview／MenuContracts 通過 WinPS 5.1；CancellationWorkflow 通過真實 bytes／journal／ACL、ZIP volume／extract 取消重試、未套用的 durable RestoreAttempt 與 Cancelled receipt、CLI 0／1／3／4。
- 主模型 DeltaWorkflow 通過增量 ZIP、可信目標未變更 bytes 完整 package 重建、既有 validation／cutover consumer、staging 與兩次 rename 中斷修復、漂移／錯 token 阻擋；DeltaMenu strict-mode 消費契約通過。NativeExecution 主模型 5.1／7 通過，child process／partial output 清理界限見 OPERATIONS。
