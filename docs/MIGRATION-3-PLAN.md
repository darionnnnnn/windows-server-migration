# 第 3 輪規劃：一般網站／排程主機 EOS 搬移

日期：2026-10-10。狀態：**四視角複審後補強規劃；本輪僅修改文件，以下 Phase 均未實作／驗收。** 程式基準：`4908910`（0.3 隔離 pilot）；初版複審起點：`dev` 的 `b40c657`；上次定案起點：`d674087`；本次複審基準：`97a98f8`。已確定輔助搬移、版本選擇、原路徑保存、預設全選／自訂、所有使用者功能與文件以 HTML 為入口、本機 PowerShell／文字備援、C／非 C 分工、不合併既有文件並列無法放置清單、非 IIS 不新增 adapter。保留全新 Windows 基準、JSON 比較及直接還原／等待選擇；以下技術與實機條件仍明列，不從審查／規劃推論已授權實作或解除 production gate。

主入口見 [README](../README.md)；既有實作證據見 [第 2 輪驗證](archive/MIGRATION-2-VERIFICATION.md)，既有能力與限制見 [涵蓋範圍](ENTERPRISE-MIGRATION-COVERAGE.md)。本輪後續待辦集中於本文；既有外部驗收仍保留於 [實作紀錄](IMPLEMENTATION-0.1.md)。

## 本次補強的產品目標（使用者要求）

1. 面向企業 TS 的輔助 EOS 搬移與交接：盡可能找出並還原使用者所需的內容，TS 依選單完成盤點、差異審閱、範圍調整、目標準備、搬移與交接；使用者／應用、平台與產品負責人承擔版本、產品及業務驗證責任。
2. 文件能讓使用者確認來源／目標的全部已發現軟體差異，並知道要手動補裝哪些軟體、補哪些設定／授權／帳號及如何驗證。來源清單、目標清單、差異與人工待辦必須可相互追查。
3. 使用者可選新版軟體，仍能透過來源原路徑找到所選舊文件及設定，例如 `C:\temp\report.csv`。保存原檔與新軟體的生效位置／格式驗證分別記錄，不以同版本作所有檔案還原的前提。
4. 所有已發現項目預設選取；使用者可調整類別、項目、檔案範圍及已支援設定。不能自動還原的也列出處置與責任，不能為了成功率隱藏。
5. 使用者的操作、說明與所有確認／交接文件均透過 HTML 網頁入口。HTML 搭配本機 PowerShell 執行端，文字選單備援；與 CLI 共用資料、預覽及執行邏輯，無需正常流程改 JSON 或另開 Markdown。
6. 先把目標寫入 README，再確認策略及可驗收階段；審查發現的缺陷與建議在第三輪討論及處理，不默默延到下一輪。

軟體本體不自動安裝的既有範圍仍適用；TS 可協助人工準備，但完成安裝、檔案搬移與業務驗收分別記錄，不能互相代替。

### 本次定案與先前政策調整

1. **新主機基準：** 全新安裝、僅 Windows Server 初始設定。第一次本機採集成為該主機的初始基準；後續還原前再採集目前狀態，比對使用者已補裝的結果，不假定目標永遠沒有軟體。無須建全市場軟體／版本目錄或每版 Windows 的硬編碼安裝清單。
2. **版本政策：** Windows OS 以目標為基準；其餘軟體預設參考來源版本，使用者可明確選擇新版或其他版本並自行安裝。最新指示取代先前非 Windows 軟體必須同來源版本的規劃。來源版本、使用者選用版本及實際目標版本分開，架構、provider、帳號範圍及設定另列差異；版本不同既不自動視為相容，也不單憑版號阻擋所有資料還原。不自動轉換格式或替使用者判斷新版可用。
3. **還原前選擇：** 先檢查目標、顯示缺少／版本差異／未知及人工待辦，再讓使用者選直接還原，或等待手動補裝所選版本後再還原。選擇不宣稱環境已齊，不以勾選取代盤點與後續驗證。
4. **比較儲存：** 程式自行寫入 JSON 作持久資料庫，記錄基準、兩機現況、比對、選取、自訂、版本選擇、人工工作及結果；使用者不需手填資料庫。不新增 SQL／SQLite／雲端或常駐服務。
5. **操作與範圍：** 已選 HTML＋本機 PowerShell／文字備援，最新指示再要求所有使用者功能與文件均以 HTML 呈現。沿用主工具 C 槽、其他槽跳板機、軟體本體人工安裝；所有已發現項目預選，不支援項目出列處置，不擴整機映像。
6. **目的衝突與非 IIS：** 不協助合併既有文件，不自動覆寫外部內容；HTML 明確逐檔列出因目的端已有文件而無法放置的項目。非 IIS 完整盤點相依、保存所選檔案／設定及列人工處置，不新增產品專用還原 adapter。

**直接還原的規劃解讀：** 允許先處理不依賴尚未安裝軟體的檔案／資料與可執行設定；需要產品 API／runtime／角色的項目留待安裝後續跑。此解讀由「不要求還原後立即完全可用」推導，用以避免現行一個軟體缺口阻擋所有檔案；不是使用者已批准任意跳過核准、衝突或後續業務門檻。

## 使用者已定案的範圍

1. 本專案處理企業內部**一般網站、Windows 排程及支援這些工作負載的服務主機**之 Windows Server EOS 搬移。不是資料庫、load balancer 或其他專業軟體服務主機的搬移工具。發現這類角色時，列出排除項、相依與責任人，不能用一般檔案複製表示服務已遷移。
2. 網站與排程的盤點必須涵蓋全部已發現項目及其檔案／設定相依，不限預設目錄、執行檔位置或啟用中的項目。盤點不到、權限不足、無法解析的項目必須清楚揭露並補查。
3. 主工具的備份來源只限 **C 槽**。其他槽另提供小型跳板機工具，讓使用者輸入來源與目的端，直接比對、搬移並驗證所選範圍沒有漏檔。這是另一條資料搬移路徑，不納入主工具的 C 槽封裝。
4. 使用者的完整環境確認改以 **HTML** 呈現，取代先前 `.md` 為主要入口的要求；能查版本就列，查不到仍明確列名稱。已安裝環境、相依工具、專業軟體及使用者安裝軟體都保留清單；既有其他格式保留相容輸出，不要求正常流程開啟。

Oracle Client 等網站／排程相依仍在盤點範圍。其軟體本體列 HTML 完整清單由使用者安裝；`TNS_ADMIN`、有效的 `tnsnames.ora`／`sqlnet.ora`／`ldap.ora` 及被引用設定另列搬移或外部處理。**排除資料庫服務主機，不等於排除連線到資料庫的網站／排程。**

本專案不做整顆 C 槽映像、System State 或整機複製。C 槽內的業務網站、腳本、自有程式與核准環境設定是檔案搬移對象；OS、runtime、專業軟體安裝本體及授權／機器綁定狀態不能因為位於 C 槽就整包搬移。網站自有的 `.dll`／`.exe` 可是業務發布內容，不能一律按副檔名排除。

AD DS／CA、Hyper-V、叢集、RDS、專用儲存或其他專業角色主機不因同時存在網站／排程就成為本專案的整台搬移對象。混合角色主機須辨識隔離的網站／排程範圍與外部服務責任；無法分離必要相依時阻擋一般流程，不只排除軟體名稱後繼續切換。

## 本次複審：先從使用者操作，再反查四個視角

以下問題是以尖銳但合理的使用者情境提出的驗收反例，不是引用 Reddit 留言。先檢查是否能完成實際工作，再核對程式／資料／管理契約；不將「已有對應 Phase」當成細節已閉環。

| 使用者情境／合理質疑 | 前版尚不夠明確之處 | 本次補強及驗收落點 |
|---|---|---|
| 首次 TS：「說是網頁操作，第一步卻要自己打指令；點執行還會跳出我看不到的提示？」 | 網頁入口、權限／工具啟動與可能的 Read-Host／credential／ShouldProcess 未接成完整旅程。 | 啟動前可離線看 HTML 指引；明確本機啟動／權限／瀏覽器檢查，所有必需輸入在執行前完成，背景操作不得等隱藏終端輸入。A／U／F。 |
| 只搬檔的使用者：「全選還得把每個特殊產品逐列排除，否則連 C:\Jobs 都搬不了？」 | Selected 與 Include 已分離，但 ReviewComplete 仍全 catalog 要求 Pending 決策；只改 RestoreReady 會太晚。 | 支援本次有效集合的批次確認，外部／未選項保持清單；無關未決項不擋獨立可還原集合，必要相依照實揭露。S／A／G。 |
| 使用新版的人：「封包後才決定新版，是否所有檔案都得重新打包？舊版證據又如何失效？」 | 版本選擇與 sealed plan 的 ExpectedVersion／RequirementId／receipt 相依未定清楚。 | 分離不可變來源證據與目標版本選擇，限定失效範圍；未改來源內容不無故重封，改設定／映射仍重新審核。A／E1／G。 |
| 原路徑已有文件：「你說不能放，究竟哪個檔案、是同名還是整個資料夾擋住？原檔還在哪？」 | 已規劃逐檔／scope 原因，還要避免建議清空 Windows／產品共用目錄來解除限制。 | 顯示來源保留引用、直接衝突／scope阻擋／未知，非同名項也出列；保留目標與正常已受控delta，不自動合併或要求清空受保護目錄。P／D／E2。 |
| 長時間工作：「網頁斷線或關閉後，工作還在嗎？取消只是轉圈，還是已經停止？」 | session／journal 已規劃，尚無長作業與進度／取消請求的並行服務契約。 | 請求已接受、工作進行、取消已請求、安全邊界停止分別呈現；重連接回原OperationId，不重送造成第二次執行。U／A／G。 |
| 部分還原後：「昨天只選A，今天選B，但你只給增量；B從來沒搬過，要從哪補原檔？」 | 全機Generation與待處理項未建立每項基線；增量需要既有完整scope。 | 保存每項實際manifest／generation；缺基底要完整可信來源，不假設其他scope成功就可套delta。G／C／A／F。 |
| 接班 TS：「我把HTML和ZIP帶到新電腦，連結還指向原管理端D槽；看『完成』到底是哪台、哪一輪？」 | 完整HTML雖列入規劃，但資料包白名單、可攜文件索引與相對連結未定。 | HTML文件獨立完整索引及hash引用，與payload包分工；相對連結可離線開啟，顯示主機／revision／觀測時間／有效性。E2／U。 |
| 波次管理者：「一台的C搬了、D沒搬、軟體還缺；總覽的100%算什麼？另一個TS重查後我的確認是否過期？」 | 彙總有deferred但未明定分母、跨通道證據及多視窗編輯。 | 分開發現／選取／核准／檔案／物件／人工／可用性；同一範圍可下鑽完整待辦，跨C／非C結果及決策revision同源。E2／D／S／G。 |

**使用者視角：** 核心入口合適，但不能將複雜工作隱藏成單一「全選／還原」按鈕。可選任務、實際範圍、保留／未放置、待安裝與續跑須能從同一HTML看懂；常見路徑未自動找到時，可透過網頁補登，不宣稱已發現清單等於整台所有內容。

**程式視角：** 前版已找到producer缺口，但還需要從核准前、還原後到delta／repair／CLI返回值反查consumer。新增狀態／版本不能只改JSON與報告；舊斷言若要求整機已完成，需依受控有效集合改版，而非全面略過。

**管理者視角：** 網頁上的Owner是責任宣告，不能當作已驗證企業授權身分；執行主機／Windows執行身分、操作者責任宣告、決策與證據追蹤需要分別留存。本機程序身分不代表已認證瀏覽器後的個人。未完成工作可以交接，不應因局部成功就丟掉責任／來源材料。

**整體視角：** 輔助工具的方向適合既有scope／journal架構；主要風險是沿用整機核准及世代，再外掛局部選取。此次新增R3-11–18補這些跨段契約；所有定案仍保留，不引入合併、自動安裝或新產品adapter，11個Phase不因複審被縮減。以下新增觀察均為規劃缺口／整合風險，非第三輪已實作功能的bug。

## 現況與必須改變的契約

| 現況證據 | 第 3 輪要求與影響 |
|---|---|
| `src/Discovery.ps1`、`src/EnterpriseDiscovery.ps1` 有網站／排程／服務路徑探索 | 擴充成可審核的工作負載 → 設定／檔案／軟體相依清單；發現候選不等於已完整識別相依。 |
| `src/Payload.ps1` 的 FileScope 依 SourcePath 列舉，目前沒有 C 槽限定 | 在規格、核准、來源封裝及增量共同強制來源實體磁碟政策，不能只在精靈擋輸入。 |
| Oracle 設定 draft 與 ConfigFiles 在 `src/OracleClientContracts.ps1`、`src/ConfigArtifactContracts.ps1` | ConfigFiles 目前不是 payload 白名單；必須讓實際列舉、manifest、匯入、還原與增量消費同一精確檔案集合，避免連安裝目錄一起搬。 |
| `src/SoftwareInventory.ps1` 已讀卸載資訊、檔案版本與部分環境 manifest | 補版本來源與未知原因的報告呈現；保持全部程式列，不能因空版本漏列。 |
| `src/RemoteStorageContracts.ps1` 已有外部儲存契約 | 尚不是跳板機通用檔案搬移工具；新增小入口及逐檔驗證，避免再建一套管理工作區。 |
| 既有 restore、delta、核准及 qualification 互相綁定 | 擴充契約需處理舊包／舊計畫，不得把舊版任意磁碟包重新標示為 C 槽限定包。 |

### 本次直接核對的缺口與缺陷

此次不讀取 `docs/archive/`，不讀取或修改根目錄個人 prototype。以下依現行程式核對，區分既有缺陷、未提供的能力與設計風險；尚未執行真實 Server／產品驗收。

| 編號／分類 | 核對證據 | 使用者影響／第三輪處置方向 |
|---|---|---|
| R3-01／能力缺口 | `src/EnvironmentConfirmation.ps1:136` 將來源軟體 TargetStatus 設為 NotTested；`:272` 的 ComparedRows 固定為 0；`:421` 的 TargetObservation 只接受觀測中繼資料。`src/Reports.ps1:101` 也沒有兩機比對。 | 有來源全量文件，不等於有兩機軟體差異。新增可信目標軟體盤點、配對、差異及人工待辦，不能只改文案或把 Observed 當成軟體已比對。 |
| R3-02／已重現的文件缺陷 | `src/EnvironmentConfirmation.ps1:235` 讀 Item.Mapping；`src/MigrationContracts.ps1:115` 寫 MigrationSpec 時不同步 Mapping；`src/Restore.ps1:31` 使用 MigrationSpec.TargetPath。隔離投影 fixture 設 Mapping=`C:\review-only`、MigrationSpec.TargetPath=`C:\actual-restore`，報告仍顯示前者。 | TS 可能按文件找錯位置。文件須區分審核建議、核准目的與實際還原／生效位置，引用同一權威規格及結果；保留反例驗收。此輪提出修正，不在規劃階段改程式。 |
| R3-03／路徑需求與既有契約衝突 | `src/Restore.ps1:31` 阻擋既有非工具持有 scope；`src/MigrationContracts.ps1:96` 只有 Block／ReplaceOwned；`src/Restore.ps1:48` 起採同層 staging／backup 的 scope 切換。 | 已定案不合併既有內容。P 要產生逐檔無法放置清單，分辨實際同名衝突與被整個 scope 阻擋的其他原檔；預覽說明能處理範圍，外部／共享 scope 人工整理後重試，不整目錄替換或偷偷新增逐檔合併。 |
| R3-04／兩機比較設計風險 | `src/SoftwareInventory.ps1:219–222` 的 SoftwareId 包含 scope、SID、位置及 NaturalKey；卸載項自然鍵在同檔 Get-WsmSoftwareCatalog 中含版本。 | 同產品升版、換位置或本機 SID 不同時，直接以 SoftwareId join 會把差異誤報成缺少＋新增。保留原 ID 作證據引用，另辨識產品及實例配對；不能以同名或同 ID 宣告相容。 |
| R3-05／版本政策與既有必要相依門檻 | `src/GeneralHostContracts.ps1:182` 阻擋必要軟體的 Unknown／NotTested／Unspecified 版本或架構。 | 新版／未知不能自動阻擋所有檔案，也不能冒充準備完成。E1 保留版本證據及選用版本，G 按操作實際必要條件分流；無版本自有程式可先存檔，後續以 owner 發布識別及 consumer 結果確認，不偽造版號。 |
| R3-06／跨消費端與發行影響 | `src/EnvironmentConfirmation.ps1:421`、`src/LabValidation.ps1:41` 有欄位白名單；`src/ToolRelease.ps1:1` 的 ToolFingerprint 只涵蓋 src／入口，`:187` 同樣只從包內程式重算；`:201` 另把 README／docs 加入發行包。 | 比較／選取／路徑結果同步HTML、相容格式、LabReport、Fleet與gate。這輪只改Markdown，archive／文件hash會變，程式指紋不變。未來操作HTML／JS等若新增獨立執行資源，A／U須納入程式指紋／包成員驗證／SBOM，不把可執行UI當普通文件排除；改src內嵌UI仍按srcbytes綁定。重建發行包核驗最終bytes／簽章，不熱換pair。 |
| R3-07／直接還原與整體門檻衝突 | `src/Restore.ps1:43–44` 因 GeneralHostIssues 阻擋整次；Invoke-WsmRestore 仍先驗 preview；`src/DeltaWorkflow.ps1:320` 亦以 RestoreReady 阻擋全部 delta。`src/Fleet.ps1:80` 起依現有階段投影摘要。 | 需明確區分可執行／待軟體／真正失敗及後續業務門檻。full／delta／CLI／精靈／重跑／Fleet／LabReport 一致處理，不能以全域忽略 gate 或把 deferred 記成 Succeeded 支援新分支。 |
| R3-08／JSON 可沿用與相容影響 | `src/Core.ps1:135–145` 已以 pairs/<PairId>.json 為配對資料；`:18–32` 有同目錄暫存／原子替換；`:106–112` 有工作區鎖；舊 schema 消費端需明確拒絕新契約。 | 在現有 JSON 配對資料庫擴充比較區塊與必要 schema，沿用寫入／鎖／復原；不可建一套獨立可編輯資料庫再讓 catalog、plan、報告各自判斷。寫入預算、過期選擇、錯機及中斷需驗收。 |
| R3-09／預設選取與核准契約衝突 | `src/Core.ps1:194` 新項目 Decision=Pending；`:198–203` 重盤點依變更保留或要求重審；`:208` 消失項 Present=false。`src/Review.ps1:9–18` 的 Include／Exclude 是受審決策，不支援產品有另外限制。 | 新增使用者選取意願及自訂契約，不能把預設全選直接寫成全部已核准。保存取消選取與處置；新項目預選但待確認，消失項留歷史；下游 scope／manifest／delta 只消費實際核准集合。 |
| R3-10／操作及完整 HTML 文件缺口 | `src/Reports.ps1:1–40` HTML 是內嵌 JSON 的搜尋／分頁／列印快照，列印最多 2,000 筆；`Start-ServerMigration.ps1:35` 等以 Read-Host 操作，既有手冊以 Markdown 為入口。 | E2／U 補所有使用者功能、完整文件／衝突／手冊HTML入口與真實橋接。不能以列印截斷當完整交接；操作及snapshot標示，共用型別化 action／lock／核准／journal，文字備援同結果。 |
| R3-11／P1：局部還原的世代與狀態consumer缺口 | `src/Restore.ps1:7–8` OperationState綁整份PlanHash／ManifestHash／Generation；`src/DeltaWorkflow.ps1:249` 從目標重建未變動chunks，`:282–289`要求adapter已staged，`:305–307`整體晉升世代；`src/JournalRecovery.ps1:83`以RestoreCompleted更新整體世代。`src/OperationRequests.ps1:20`起返回碼分類未包含新狀態；隔離fixture輸入DeferredSoftware／WaitForInstall單獨結果目前均得到0。 | A／G保存逐項已套用版本及選取receipt，未還原項不能借用其他項世代；無完整base的delta要取可信完整內容。replay／repair／rollback／StageResult／CLI同步新狀態，等待／deferred不得成功0或整體完成。此為新契約consumer缺口，不是現行已提供deferred功能的bug。 |
| R3-12／P1：封包後版本選擇與不可變核准衝突 | `src/GeneralHostContracts.ps1:17／36`將ExpectedVersion／Context納入projection及RequirementId；`:116–118`拒絕舊投影／plan receipt。`src/MigrationContracts.ps1:142–143`GeneralHost進sealed plan。`src/Qualification.ps1:30–39`以ProductVersion及exact Oracle provider／consumer鍵對應資格。隔離fixture只改ExpectedVersion便生成不同RequirementId。 | 來源證據／原設定核准保留，目標選版與prepared provider另綁revision／receipt。不改sealed plan／不以舊receipt證明新版；A／E1／G分清重審邊界，資格tuple需能分清來源與實際目標產品版本／實例，不能把單一舊ProductVersion當兩邊或解除既有正式門檻。 |
| R3-13／P1：可操作HTML的非互動及並行缺口 | `src/OperationRequests.ps1:5–18`直接執行本機allowlist；`src/Restore.ps1:88`長作業持有pair鎖。`src/Cancellation.ps1:52–70`有獨立取消marker鎖，`:87`起有進度檔，現行手冊要求另一個PowerShell送取消。 | U不能在處理HTTP請求的同一執行通道同步跑整個搬移後才接取消；共用核心另安排長工作，讀取一致進度／提交取消保持可回應。必需secret／SID／確認／原生前提先收集，非互動job不等Read-Host。listener小實驗須在A驗此風險，非只能開網頁。 |
| R3-14／P1：核准前仍被無關項阻擋 | `src/Review.ps1:47`每個Pending列均為ReviewComplete；`:51`要求Mandatory依賴Include，`src/MigrationContracts.ps1:129–130`核准前檢整份issues。隔離fixture納入A後，不相關B仍產生Decision required。 | S／A同步本次核准有效集合、全量可見／外部工作與必要依賴。不只改RestoreReady；不要求把所有unknown／特殊產品逐一假Exclude才能先搬獨立檔案，也不對缺真正SID／機密等相依的檔案假放行。 |
| R3-15／P1：C／非C跨通道結果與續跑缺口 | `src/RemoteStorageContracts.ps1`是專用遠端scope，尚非D小工具；`src/Cutover.ps1:80–83`的外部證據綁Pair／兩機／Plan／Manifest，`src/CrossHostGates.ps1:19–26`有final group／freeze綁定。前版D只列人讀／結構化結果，尚未定Manager如何驗信任與同輪final。 | D／E2產生有版本的結果／來源清單引用、兩端身分／volume／根／hash、operation／範圍／錯誤／freeze引用，按可信摘要匯入Manager，再投影相關consumer。續跑使用受控清單重新核驗，不新增另一個可編輯資料庫，不把不同輪D成功用於本輪切換。 |
| R3-16／P2：HTML可攜交付與權威邊界缺口 | `src/PackageTransport.ps1:1–4`payload包成員只有manifest／plan／artifacts／freeze／chunks；`src/DeliveryReceipts.ps1:35／44`有ReportReferences及受限成員；`src/EnvironmentConfirmation.ps1:386–452`另有DocumentId索引及多格式引用。`src/Reports.ps1:21／38`離線資料內嵌，不需fetch外部JSON。 | E2／U不能把HTML直接塞入sealed payload或只交入口HTML。文件另有完整成員／hash索引、相對連結、可離線資源；JSON引用／ReportReferences與匯入端一起改。操作runtime資源與產出文件不同權威；本機http頁不假設能任意打開磁碟檔案，原設定位置可複製並標示實際主機。 |
| R3-17／P2：選取後容量及完整計數缺口 | `src/Restore.ps1:40–42`用整份manifest.Bytes及所有Include scope估算，以路徑根字母查容量；`src/Payload.ps1:26／32`明確239字元限制，`:37–42`估算index／margin。前版只要求總數一致，未定各集合分母及物理volume。 | C／G／D按本次有效集合與實體volume估算封裝／staging／保留／state／HTML附件，顯示真實有界預算與特殊路徑缺口。E2分別計檔案／目錄／bytes／物件，不把未知當0、不混計重複consumer；空集合為無操作，100%掃描／執行進度不代表內容全部已還原。 |
| R3-18／P2：多操作者、秘密及證據失效的管理缺口 | `src/Review.ps1:14／21–24`用revision、Environment.UserName及History；`src/EnvironmentConfirmation.ps1:13–47`是安全投影，不輸出raw settings；`src/Recovery.ps1:7`明說journal不抵抗本機管理員改寫。前版HTML沒有角色與並行編輯／憑證輸入細節。 | S／U保存實際本機principal／主機與責任Owner分欄，兩頁CAS衝突不丟尚未提交輸入、不將任填Owner當企業授權。secret只走當次受控記憶體且不入HTML／localStorage／下載／log；失效及不完整結果可追查。受控外部信任／歸檔責任不因改網頁而消失。 |

R3-01／03 是需求缺口，R3-02 是已重現缺陷，R3-04／05 是需處理的契約風險；不能統稱程式 bug，也不能用既有回歸通過表示它們已解決。

本次既有consumer隔離fixture在Windows PowerShell 5.1及PowerShell 7均重現R3-11的新狀態返回0、R3-12版號改變RequirementId、R3-14無關Pending阻擋三個consumer觀察。fixture在專案外獨立目錄、消費既有不可變runtime快照，不修改src／tests／個人prototype；這些觀察不能當作新契約已驗收。其餘新增項為直接程式核對及跨段設計分析，尚無實機／瀏覽器證據。

## TS 操作、差異文件與人工準備

沿用 Source／Manager／Target 本機及離線交換方式，不為兩機比較引入強制 WinRM 或常駐代理。TS 操作流程應包含：

**選角色與工作目錄 → 來源盤點＋目標初始基準 → 全選清單／範圍及版本調整 → JSON 比較／原設定檔位置／人工清單 → 還原前目標重查及預覽 → 選直接還原或等待補裝 → 可執行項還原／待處理登記 → 安裝後重查與續跑 → 逐項 readback／業務驗收 → 切換與交接。**

每一步須有角色／執行主機、材料、結果、阻擋原因、重跑入口及 HTML 說明／交接。正常操作由工具處理 revision／hash，呈現主機、範圍與變更，不要求 TS 手改 JSON 或另讀 Markdown 才能完成。包括進階審核、交付／增量、repair／回復、可選切換／驗證等既有功能也須有網頁選單入口，不只做新還原頁面；獨立可信材料取得仍有網頁指引。

| 交付內容 | 使用者必須能回答的問題 |
|---|---|
| 來源及目標全量軟體清單（附探索缺口） | 各裝了什麼、哪個帳號／位置／架構、版本證據何在？未載入 profile／查詢失敗是否尚待補查？ |
| 兩機差異表 | 對應產品在目標是否缺少、版本／架構／位置／帳號範圍不同、相同、目標額外安裝或無法判定？多版本並存與多實例是否分別配對？ |
| 人工補裝／設定待辦 | 缺什麼、為哪個工作負載準備、建議處置及順序、媒體／授權或設定證據引用、誰做、做完如何確認？已安裝但待驗證不得顯示完成。 |
| 路徑與搬移結果 | 舊位置在哪、新主機同路徑能否讀取、軟體有效位置在哪、安裝前後是否漂移、哪個 consumer 已驗、衝突或人工處理還剩什麼？ |
| TS 操作與使用者交接清單 | 本機下一步、可重跑的失敗項、是否能切換、誰負責尚未完成事項、如何回復及何時能退役？ |

兩機都須有綁定主機及時間／revision／hash 的軟體證據。不可只接受 manager 上手填的目標摘要，也不可把查詢失敗當成目標缺少。來源失效、目標補裝／移除／升版或帳號／路徑變更後，比對與相關準備證據須更新；完整清單可直接閱讀，人工回填須回流既有權威審核及核准流程。

所有已發現軟體均出列，不把無 consumer 關聯或未選還原的軟體默默刪掉。目標額外軟體列出，不自動移除。產品／實例先配對，再比版本；升版／降版均列 VersionMismatch，但另列是否符合使用者所選版本，不能把使用者選新版一律列成待改回來源版本。同版本也不等於架構、provider、帳號或設定一致。讀不到目標 profile／registry 時列 Unknown，不能當成 Missing；查不到來源版本時保留名稱及原因，不記成 SameVersion。

比對保留版本原值及來源類型，不能將 DisplayVersion 與 FileVersion／不同 provider 的版本直接混比，或用數值大小宣布相容。以來源可靠版本作預設建議，使用者明確選用版本另存；未決、證據矛盾或配對歧義列待確認。檔案保存、設定套用、產品執行與業務驗收分別判定；只有受影響操作的實際必要條件不足才 deferred／blocked，不以來源同版本要求阻擋無關檔案。

**驗收方向：** 缺少 runtime、同產品升版又換目錄、32／64 位元並存、同名不同產品、同產品不同使用者、目標額外軟體、未知版本、profile 讀取失敗及重新盤點，各自有正反例。TS 應僅看產出文件即可指出人工工作與責任人；五格式及總覽不能把未比對或未驗證顯示為完成。

## 程式維護的 JSON 比較資料庫

沿用管理工作區 `pairs/<PairId>.json` 為配對權威資料庫，新增具版本的 SoftwareComparison 區塊。既有來源 SoftwareCatalog 保留其權威與 hash 綁定；原始目標採集以不可變 JSON 證據引用，不在多份 mutable 檔案重複維護相同決策。以下為資料契約，欄位精確命名由 A 階段依既有 schema 定稿，不預建空檔或示範真實主機資料。

| 資料集合 | 必須保存的資訊／使用端 |
|---|---|
| 配對與政策 | PairId、兩機 fingerprint、schema／tool 版本、資料庫 revision、WindowsInitial／SourceVersionDefault／UserChosenVersion 政策；Manager／Target 共用。 |
| 來源要求 | 權威來源軟體 snapshot 引用／hash／revision、全部非 Windows 軟體與 consumer、名稱、來源版本原值／類型、架構、scope／SID、位置、coverage。來源更新不能改寫舊證據。 |
| TargetBaseline | 首次採集及時間、OS／build／架構／installation type、實際初始軟體及coverage；另記使用者宣告是否僅初始Windows。若補裝後才首次執行，標FirstObserved而非偽造純Windows基準，仍可比較。永久留存，重灌／換機須新身分及重新綁定。 |
| TargetCurrent | 每次還原前及補裝後的目標軟體 snapshot 引用／hash／revision／時間／coverage；離線由目標產生、Manager 匯入驗證，還原端持有相同證據／receipt。 |
| Comparison | 來源／目標證據版本、產品／實例配對及理由、SameVersion／Missing／VersionMismatch／Unknown／Ambiguous／TargetOnly，另記架構／位置／帳號差異及人工清單。從 snapshot 重算，不靠使用者改狀態。 |
| SoftwareChoices／ManualActions | 來源參考版本、使用者選用版本／理由、目標觀測版本、待安裝／不符選用版本／待確認／待設定／待驗證、owner、consumer、處置順序及結果證據；版本選擇不改寫觀測，不代表已相容。 |
| RestoreSelections／Customizations | 穩定 ItemId／來源 revision、選取意願、類別及逐項範圍、檔案排除、原路徑保存／生效映射、帳號與設定處置、明確取消原因及預覽引用；與受審 Decision 及實際 execution status 分開。 |
| RestoreDecisionHistory | WaitForInstall 或 RestoreNow、操作者／時間、當次差異與接受的未準備項、PairId／plan／manifest／generation、目標 snapshot／comparison revision 及有效範圍；新選擇保留舊紀錄。 |
| 結果引用 | journal／state每項已套用manifest／generation／hash、選取receipt／OperationId、核驗／待軟體／衝突／未選結果引用；可用材料與已套用基線分開。實際state仍由journal管理，不雙寫；非C結果另綁兩端／範圍／來源清單／final freeze並可信匯入。 |

程式採既有 workspace lock、ExpectedRevision 檢查及同目錄原子寫入；不可變 snapshot 先落盤並核驗，再單次更新 authority 引用。中斷產生未被引用的 snapshot 可保留供受控檢查，資料庫不能指向半寫檔；相依多檔修改沿用 transaction／RepairWorkspace。重啟、報告重產及 attempt 更換不丟基準／選擇／未完成工作，不重建 stable state。

沿用 128 MiB 有界 JSON 與受控目錄保護：先估算資料量，超限明確停止，不能截斷清單。歷史採證據引用避免每次嵌入完整全量盤點；具體 snapshot 大小／保留策略需在規模驗收前確認。JSON 不保存密碼／私鑰／完整秘密設定，真實企業資料不入公開 repo。來源／目標錯配、hash／revision 失效或 schema 不相容時拒絕套用，新比較不可讓舊 reader 默默使用舊結果。

## 預設全選、使用者自訂與核准集合

所有本次已發現項目預設 Selected=true，包含無自動 adapter、專業產品、系統項目及非 C 相依；同時顯示「工具可還原／待軟體／人工處理／不在範圍／待確認」。預選代表使用者希望處理，不能直接改 Decision=Include 或把所有項目入包。不能自動還原的仍列保存方法、外部程序或排除理由，不用灰色隱藏列假裝不存在。

| 可自訂項目 | 行為契約 |
|---|---|
| 類別／工作負載／逐項選取 | 預設全選；可取消或恢復。清楚區分本頁、全部篩選結果與全部已發現項目；列總數、選取數、可執行數、待處理／外部數，不以已選數當成功數。 |
| 檔案與相依範圍 | 可新增 owner 宣告路徑、調整檔案集合／排除、設定處置；自動列出取消項對仍選 consumer 的影響。不自動替使用者加回取消項，也不因檔案共用就重複還原。C／非 C／UNC 分流與軟體本體排除持續適用。 |
| 軟體版本 | 預設來源版本，可選新版／其他版本／暫未決定；實際安裝由使用者完成。差異列同時顯示來源、選用及觀測版本，安裝完成仍需相應設定／consumer 驗證。 |
| 原路徑與生效路徑 | 原路徑保存預設開啟；另列產品實際使用路徑。映射可由使用者調整，但變更原路徑目標時明示影響並記原因，不默默取消原檔可找到的要求。衝突／不支援項保留未完成處置。 |
| 帳號、權限與設定 | 提供既有 SID／帳號映射、已支援 typed 設定的 Create／Keep／External／UpdateReviewed、是否暫緩與責任人；未知設定列人工流程。密碼／私鑰仍使用外部材料，不提供任意 shell／registry 匯入按鈕。 |
| 輸出及執行時機 | 沿用可選 WorkRoot／輸出目錄、Directory／分卷 ZIP 大小；本次預覽列全量範圍，可選等待／直接還原／只預覽，不自動啟用業務。 |

重新盤點按穩定來源識別保留選取、取消、自訂及版本決策；新項目預選但未確認，內容／相依變更要求重審，消失項留歷史並移出有效集合。同名／改路徑配對歧義要求確認。目標receipt的範圍始終是sealed plan已核准內容的子集；可於這個已核准集合內重新選回項目，並非只能比上次選取越縮越小。不得新增包外內容；修改來源範圍／設定／映射須重審及所需封裝。全取消為無操作，不生成偽造成功的空搬移計畫。

本次核准須能確認獨立可執行集合及其真正前提，並附全量發現／外部／未選清單；Pending的未相關產品不擋本次獨立檔案，但所選操作必要的帳號／SID／機密／角色仍照實檢查。支援批次預覽／一次確認，不要求每個未支援列逐次假Exclude；未確認工作留owner／待辦，不視為已核准或已完成。與執行無關的責任待辦和相關必要相依分開，A／S同步ReviewComplete及sealed plan消費端。

已還原後取消選取只調整後續操作意願，保留原result／ownership與現有檔案，不自動刪除或回退；重新選回先核驗原hash／世代及漂移。編輯撤銷、取消作業、安全停止、實際回退四個入口命名與預覽分開，不讓「取消選取」成為刪資料的暗示。核准檔案有多個consumer時以實體集合去重；重疊來源／目的與分流未處理清楚前不產生相互覆蓋的scope。

選取意願、受審處置、核准計畫與實際執行結果是四個不同概念。互動介面提供批次預覽及明確確認，讓 TS 不需逐行寫 JSON；不支援操作轉外部工作而非偽造 Include。驗收跨頁全選／全取消、篩選後選取、共用檔案、取消必要相依、重盤點保留、過期請求、非 C／unsupported 預選、delta 排除及零集合；所有入口與五格式消費相同有效集合。

## 所有使用者功能及文件的 HTML 入口（已定案）

HTML 是使用者所有功能與文件的統一入口，由當次本機 PowerShell 提供操作頁面、資料及受控 action；程序結束即停止服務，不新增常駐服務、IIS／Node.js／雲端或 WinRM。來源、管理端及目標仍本機操作、可信離線交換，管理頁不直接遠端執行。所有人讀清單、操作說明、準備／資格／回復指引、結果及交接均有 HTML；報告與手冊可離線閱讀，與能操作的 session 頁面清楚標示。

| 選單／畫面 | 使用者看到及完成的事情 |
|---|---|
| 首頁與工作目錄 | 角色、目前主機、PairId／波次、WorkRoot／輸出位置、現況與下一步；首次設定、續跑與文字備援入口。 |
| 盤點及探索缺口 | 採集來源／目標、匯入可信材料、全量已發現清單、缺口／owner 補登；不要求手填資料庫。 |
| 還原選取與自訂 | 預設全選、分類／搜尋／跨頁批次、檔案集合與相依、版本／路徑／帳號／設定選擇；保存與預覽清楚分開。 |
| 軟體差異與人工準備 | 來源／選用／目標版本、缺少／差異／未知、安裝順序、責任人；安裝後「重新檢查」。 |
| 原有設定檔位置 | 舊路徑、預定及實際保存位置、產品生效路徑、hash／存取結果、衝突及人工匯入待辦；不能將任意來源路徑轉成瀏覽器命令。 |
| 還原預覽與確認 | 本次可執行／暫緩／外部項目、目的檔案改動／衝突／回復、空間與權限；等待／直接還原／取消。未具備條件只阻擋受影響操作。 |
| 執行與續跑 | 真實 journal 投影的進度、可安全取消點、成功／待軟體／失敗、原因與重試／修復入口；斷開頁面後可重新連線查同一作業。 |
| 結果及交接／說明中心 | 完整 HTML 軟體與搬移清單、無法放置文件、未完成工作、原設定索引、非 C 結果、consumer／業務驗證、回復手冊及操作教學；可切換狀態獨立顯示。 |

HTML、文字選單與 CLI 共用型別化操作、同一預覽／CAS／核准／JSON／journal；頁面只能送 allowlist 資料，不送任意 PowerShell 命令。執行端沿用既有權限，瀏覽器無法自行取得系統管理員權限；啟動、權限不足、埠占用及 session 失效都有可處理訊息。

本機橋接只綁明確 loopback 位址、臨時埠與當次 session；驗證 Host／Origin 及寫入 token、請求大小／型別／revision，不允許遠端存取或由外站觸發寫入。資料渲染與下載路徑受控，惡意名稱／路徑／HTML 以文字顯示；不為操作介面另開機器防火牆／廣域 listener。重複點擊／重送共用 idempotency 及 lock，頁面關閉不代表作業已取消，結束程序後依 journal 修復／續跑。操作頁面若成為獨立HTML／JS資源，納入 runtime指紋與可信發行成員；靜態手冊／產出報告仍作文件hash，不因改說明就假稱原runtime失效。

具體 listener 選型在 A／U 以 Windows PowerShell 5.1 原生可用性小實驗確認；HttpListener 是候選，不先承諾所有伺服器／政策可用。Microsoft 提醒 listener 的廣域 wildcard 綁定有風險，故規劃採明確本機綁定。[Microsoft HttpListener](https://learn.microsoft.com/en-us/dotnet/api/system.net.httplistener?view=netframework-4.8.1)

全新 Windows／Server Core 不假設已有可用瀏覽器；Server Core 的 GUI 相容功能屬選配。可在有瀏覽器的管理端使用 HTML；無瀏覽器的來源／目標以等價文字選單執行及離線交換，不為 UI 強制安裝 GUI 或瀏覽器。瀏覽器支援矩陣、loopback／企業政策及真實頁面操作須在 U／F 驗收。[Microsoft Server Core 相容功能](https://learn.microsoft.com/en-us/windows-server/get-started/server-core-app-compatibility-feature-on-demand)

功能對照表須覆蓋既有角色、選單與非互動 action；正常使用從 HTML 能走完已支援流程，不能留只有文字／CLI 才能做的必經步驟。文字是無瀏覽器／政策阻擋時的備援，不另作使用者文件的主要入口。開發者 README／PLAN／AGENTS 維持 repository Markdown 來源；使用者手冊及結果依此產出 HTML，這輪規劃不將整個 repository 改檔或新增未接線頁面。

**完整啟動及背景工作：** 發行物含離線HTML啟動／信任核驗指引，清楚列第一次本機啟動與權限步驟，不宣稱靜態HTML本身可啟動管理員程式。工具啟動後可開本機操作入口；若瀏覽器未安裝／政策不允許，說明文字備援及原文件在哪。A先驗最小橋接於長作業時仍能接進度／取消，U再做全功能；長工作使用共用核心與pair鎖，HTTP只提交具名工作、取得OperationId及讀一致checkpoint／進度，不能等待整個搬移回傳才允許下個請求。

啟動／提交前先在表單收集已驗證的所有必要參數、credential與明確確認。背景工作不能彈出Read-Host／不可見ShouldProcess提示；原生必要互動未有受控非互動方式的操作要事前顯示不可執行／人工待辦。取消走已綁定OperationId的獨立marker，不等待被長工作占用的pair鎖。返回「取消已請求」不等於「已停止」；原子交換完成到安全邊界才呈現Stopped／Cancelled。關頁可重連，結束PowerShell是中斷並需journal修復，重啟session不沿用舊token。

多視窗／操作者均讀同一revision；CAS失敗要指出變動並保留尚未提交的非秘密輸入供重新預覽，不把過期表單再送。記錄伺服端取得的本機Windows執行principal／主機、操作者責任宣告、責任Owner、OperationId及決策前後hash／時間；執行principal不代表已認證瀏覽器後的個人，Owner欄不是企業RBAC／簽章身分證明。角色先按操作主機與既有授權區分可執行／唯讀項，不加一套網頁帳號系統。credential不入URL／HTMLsnapshot／localStorage／job落盤資料／下載／診斷log，重啟後需重新提供；報告保持既有安全投影，與含原設定秘密的受控payload分開。

**驗收：** 真實瀏覽器操作到 JSON／journal，逐項既有功能對照沒有漏入口；HTML／文字相同選擇產生同計畫與結果。測跨頁全選／取消、連點、重啟／重連、作業中編輯、過期session、錯機／revision、外部Origin／缺token、注入名稱、敏感資料、Core備援；完整 HTML 文件離線閱讀／連結不破損，snapshot不提供假執行按鈕。

另測長作業占鎖時仍可讀進度／送取消、worker意外退出、native操作在無stdin時無隱藏等待、缺參數提交前提示、取消已收但尚待邊界、多視窗revision衝突不丟草稿、記錄實際執行principal而非採信表單且人員宣告不冒充認證身分、secret未被任何session／輸出／job序列化持久保存。首次TS按HTML指引啟動，不需自行猜CLI參數；既有不適用角色的功能仍可查說明與原因。

## 還原前分支、待處理與續跑

每次首次還原、增量還原或軟體補裝後續跑，均先檢查目標現況並提供同一份差異摘要與完整清單。新主機第一次只有 Windows，不代表之後可省略重新檢查；先補裝與先還原兩種順序都受支援。為避免只更新精靈，非互動 CLI／API／operation request 使用相同預覽及具名選擇記錄。

| 選擇／狀態 | 行為與產出 |
|---|---|
| 尚未選擇 | 不寫入搬移目的；顯示目前缺少、版本不符、未知、人工行動及已核准來源／目的。非互動入口未附有效決策也不自動執行。 |
| 等待使用者安裝（WaitForInstall） | 保存清單與選擇，不自動安裝或忙等，也不執行本次還原；使用者安裝選用版本後「重新檢查」，新比較供再次確認。軟體已在但缺帳號／設定／consumer 證據的項目分別待驗。 |
| 使用者確認直接還原（RestoreNow） | 明確列出可執行與待軟體項，經一般核准／包／主機／空間／權限／衝突檢查後執行具備條件的檔案與設定。缺 runtime／產品 API 的操作及依賴它的操作記 DeferredSoftware，保留原原因、缺少 provider、consumer 及下一步；不執行安裝器或提前啟用 workload。 |
| 還原後仍有缺口 | 依真實結果記錄，彙總區分資料已還原、部分待處理、真正失敗、軟體未齊及業務未驗。未知／不符選用版本不改成 NotNeeded，不寫假 PreparationReady receipt；來源版不同與是否符合使用者選用版分開。 |
| 安裝後續跑 | 重新盤點及比對，檢查先前還原的 bytes／ACL／ownership 是否被安裝程式改動；已核驗且未漂移者不重複覆寫。具備條件後執行 deferred 設定／物件與下一階段驗證；漂移則列衝突，不自動覆寫安裝結果。 |

**門檻重構：** 現行 RestoreReady 將 PreparationReady 的全部必要軟體門檻推到整次還原；新流程按所選集合產生逐項可執行／待處理計畫。版本差異／未知供使用者確認，不作純檔案存回的一律阻擋；需要產品 API／runtime 的操作按實際條件延後。新版已安裝仍不自動判 consumer 可用。錯機、改包、範圍未核准、機密材料、SID／必要檔案權限、原有資料衝突、source 停寫及原生必要條件仍依受影響操作阻擋，不用全域 Force。

RestoreDecision 綁定既有已核准 plan／manifest／generation 與精確目標 snapshot、差異 projection 及可延後項；決策在來源包已封存後透過獨立受控 receipt 傳入，不能改包內 plan 導致重新封包或偽造 source 核准。執行前重新檢查目標：若軟體或相關檔案狀態變了，舊 preview／選擇失效，產生新結果供確認；重跑不能沿用另一主機、另代包或不同未準備清單的選擇。判定 fresh 採集／快取時效的具體策略待 A 定稿。

**封包後選用版本：** source的ProviderSoftwareId／版號／原設定證據始終不可改；target選用版本及準備／consumer期望以新版schema的獨立決策契約綁定sealed plan、scope、comparison revision與實際provider實例。原版receipt不能證明新版；改選版使受影響準備／consumer證據失效，未變的檔案保存證據保留。source scope／設定內容／生效映射等未變時不無故重封；若改動已核准設定／來源範圍，按原流程重審與ownership對帳，不偷偷改Requirements再沿用舊planHash。新選版不借用舊版的產品資格矩陣。

**局部基線與增量：** state／journal新增逐項AppliedManifestHash／AppliedGeneration／content／metadata hash及執行範圍receipt；精確欄位在A定稿。已收到且驗真的材料、各項已套用基線與整個計畫完成狀態分開；不能以一項成功晉升所有待處理項的世代。未選／DeferredSoftware／BlockedConflict／External／Failed皆不能偽造Succeeded或ownership。

delta只消費同項真正已套用且未漂移的base；項目此前未還原／缺base時，從保留的可信完整包／base payload及合法delta chain取得所需完整內容，核驗與目前manifest吻合後才還原，或明確請求缺少材料並保留待處理。不能從不存在的target補unchanged chunks，也不能以只帶改動的delta聲稱已包含所有檔案。整包仍驗完整性與信任，target選取不免除驗包；receipt不改sealed plan。已還原後改選／補裝／final／rollback／repair均依逐項基線，不刪外部資料，不把取消當成功。

expected缺口按獨立scope／相依組分流；實際執行失敗要記錄已做效果、未做與待修復項。已分類且確認無不明副作用的失敗不阻擋其他獨立可執行集合；錯機／改包／journal不一致、未完成原子交易或來源一致性破壞等影響共用信任／state時停止相關作業並提示repair，不以「盡可能」盲目繼續。journal replay／StageResult／Fleet／LabReport及CLI返回碼須共同理解新狀態；等待／deferred回2，未知operation狀態不默認完整成功，不能只改producer。

等待／deferred 的返回值與 state 必須使用明確非完成結果；規劃沿用 CLI 2 表示尚待處理，0 只表示該次請求的已執行範圍完成，不能宣稱整台可用。有效等待不標成 crash 或資料還原失敗。full／initial／final、restore order、journal repair、rollback、Fleet 與 LabReport 都要保留 deferred；final 後仍有必要軟體／設定／業務缺口不能啟用或切換。軟體安裝前後皆讀原路徑核驗，避免先還原後安裝覆寫舊文件。

**驗收：** 全新 OS 缺軟體 → 等待 → 人工安裝所選來源版或新版 → 重查 → 還原；以及缺軟體 → 直接還原 → 檔案成功／產品操作 deferred → 重啟 → 手動安裝 → 重查／漂移處置 → 續跑／readback。另驗來源版不同但符合選用版、不符選用版、未知、取消／未選相依不阻擋無關檔案、無確認不寫入、錯機／舊 revision、安裝改檔、delta deferred／刪除／重跑及回退。未改來源 scope／排除／設定的目標補裝不要求無故重封來源包。

另驗A已套g1／B未套／g2只含改動 → B重新選回，保留完整材料可正確還原，缺材料明確待處理；A待g2、B仍g1不冒充同世代。封包後選新版使相關準備receipt失效，檔案保存不無故重封；改ConfigFiles／映射則重審。journal已記錄、checkpoint尚未更新的新狀態replay、不重複套用、局部回退、CLI只含等待／deferred返回2、異常中斷與可辨識獨立失敗各有反例。

## 工作負載與檔案完整性

### 網站

- IIS 全部 site、application、各層 virtual directory、application pool 及其實際 `physicalPath`；包含停止的網站、多應用、不同磁碟及 UNC 路徑。IIS 的應用與虛擬目錄可各有實體位置，不能只取網站首頁根目錄。[IIS 官方結構](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/sites/site/application/virtualdirectory)
- 網站發布內容、靜態檔、業務組件、模板、上傳資料及網站需要的其他資料目錄；備份／快取／log 的保留與排除必須由 owner 明確確認，不以副檔名或資料夾名稱預設漏掉。
- `web.config` 繼承、外部 `configSource`／設定檔、應用程式設定、環境變數、憑證引用、ODBC／Oracle 連線設定、ProgramData／AppData／使用者 profile 設定；密碼、私鑰與機器綁定秘密另走既有安全處理。
- Apache／nginx／Tomcat 等也列站台、部署目錄與設定相依。已定案完整盤點及保存所選檔案／設定，未有受驗 adapter 的原生服務配置／設定匯入列人工處置；本輪不新增產品專用 adapter，runtime由使用者安裝。
- 網站以 container、COM、第三方模組或其他專業平台提供時，列出部署與相依缺口及外部程序；不擴張成容器平台或專業產品遷移工具。外部 DB、LB、DNS、SMTP、檔案分享等必須記錄連線／依賴與驗證責任。

### 排程與支援服務

- 全部 task folder、停用／隱藏／多 action 的排程均盤點；系統內建項也不能默默過濾，應標示 OS 提供、重建或排除原因。Windows 排程定義與執行結果分別確認。[ScheduledTasks 官方介面](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/get-scheduledtask?view=windowsserver2022-ps)
- 每個 action 的 Execute、Arguments、WorkingDirectory；處理引號、環境變數、相對路徑、`cmd /c`、PowerShell 及 Python／Java／Node 啟動方式。辨識腳本、批次檔、組件、設定、輸入／輸出資料與後續呼叫；不能僅備份 task XML 或 interpreter。
- 執行帳號／SID、profile、32／64 位元、登入型態、gMSA、權限、時區／DST、觸發條件、重跑／漏跑政策及外部相依都要列入確認；密碼不寫入文件。COM handler、第三方 action 或動態產生的路徑無法可靠解析時，列缺口請 owner 補宣告。
- 支援這些網站／排程的自有 Windows service，也盤點執行檔、參數、工作／資料目錄、設定、帳號、啟動／復原政策及相依。排程若呼叫其他主機服務，不能把遠端服務當成本機檔案。

### 完整性的可驗收定義

每個工作負載都要有名稱／識別、owner、檔案來源、用途、證據來源及處置；檔案來源分為 C 槽主包、非 C 槽工具、UNC／外部程序及明確排除。相同檔案可供多個 consumer 使用，去重不得丟失反向關聯。

靜態解析不能證明任意腳本或程式所有動態依賴。結合自動探索、owner 補充、原機實際運作檢查與目標業務驗收才可關閉缺口；不能用「未找到」代替「不存在」。有必要檔案未處置、讀取失敗、路徑未解析或外部依賴未驗證時，不得顯示整台可切換。

## C 槽主包及環境設定

1. 以來源主機 **C 槽的實體 volume 身分**判斷。`C:\Mount\` 若掛載其他磁碟，或 junction／symlink 指向外部，不能因字串以 C 開頭就進包；不默默跟隨、也不默默略過。系統盤不是 C 時仍不能自行改備份其他槽；需確認 C 是否存在及必要系統設定的採集界限，沒有 C 就不能使用此主包路徑。
2. 工作目錄／輸出目錄可以另選適合的磁碟或受控位置；「只備份 C」限制來源資料，不要求 ZIP 必須輸出到 C。備份 scope 需排除自身 WorkRoot／輸出以免遞迴納入。
3. 網站與排程的業務內容可採核准目錄；環境軟體設定採精確檔案／明確核准設定目錄。列出實際幫忙搬的設定、目標位置、hash、ACL／SID、原值回復方式與驗證 consumer，不用「設定已搬」一行涵蓋所有狀況。DPAPI、加密設定節點、Credential Manager、憑證私鑰及機器綁定秘密要標示重建／安全外部處理，不能只複製 bytes 就判成功；文件只記引用及處置，不輸出秘密。
4. Oracle 設定先解析有效來源與 consumer，涵蓋機器／使用者環境及多 Oracle Home；`TNS_ADMIN` 指向非 C／UNC 時必須轉列另一搬移路徑。wallet／私鑰遵守外部安全程序，不能不告知就排除。PATH、32／64 位元 provider 及目標生效值須另驗。
5. 新規格加入來源政策及必要的 schema 版本；核准綁定實際檔案集合。新 full／initial／final 包、CLI、精靈、直接呼叫與 Manager 匯入均檢查，target 拒絕政策不符或未綁定核准的內容。目標路徑映射另行審核，不能從來源限定推論目標也必須 C。
6. 舊包保留明確舊政策，依相容性設計允許受控舊流程或要求重新規劃；不得靜默改寫已核准 plan、丟棄非 C 檔案或假稱已轉新版。

交付沿用既有指定目錄、sealed Directory 或可選大小的分卷 ZIP，不再另設輸出框架。備份檔案集合與交付形式是兩件事；主包只含核准的 C 槽資料，其他槽走下述直接搬移。

## 新版或不同安裝位置下的原設定檔可存取

「文件」包含核准業務文件／資料及可搬設定，並非僅指工具輸出的 `.md`；不因舊路徑叫 temp 就一律判為可丟快取，也不因此搬入整個安裝目錄。路徑保留遵循既有 C 槽／非 C 槽／外部處理範圍。

每項記錄來源絕對位置、核准還原位置、目標實際位置、舊路徑可存取結果、軟體有效位置、consumer 及驗證責任。預設保留原路徑，例如舊 `C:\temp\report.csv` 在新主機仍位於同處；新版安裝目錄不同也不改掉原檔保存位置。原檔與新版本工作設定可分開，後者需人工匯入／調整或已驗 adapter 套用，文件標示各自用途，避免兩份都被誤當生效設定。

來源原設定的未修改 bytes 作保存證據；任何設定覆寫／映射／升版人工調整都另記實際生效版本及 readback，不把改過的工作設定報成原檔 hash 相同。使用者選新版不觸發自動格式轉換，原檔可找到也不表示新版可直接使用。新軟體恰好使用原同名檔且需要修改時，先保留原檔的受控副本與索引，明示原位置現在為工作設定及尚未符合原檔存取的項目，不能宣稱兩種 bytes 同時存在於同一檔名。

- 檔案保存／hash 正確、實際執行帳號可存取與 consumer 能使用分別驗證。直接還原可以先驗檔案，不要求軟體當場可執行；加密設定等仍需既有外部重建程序。
- **不合併既有文件。** 目的端已有非工具持有內容時，保留目標、列無法放置清單與人工整理／再次預覽入口；不能新增「備份後覆寫」或逐檔自動合併功能。新／受控目的可照既有核准契約還原；共享目錄無法由現行 scope 契約安全放置時，列所有受影響原檔，不假裝只有同名檔被阻擋。
- **HTML 無法放置文件清單：** 每個原檔列來源原路徑、預定目的、已有目的內容／hash或無法讀取原因、直接衝突／父目錄或scope阻擋、關聯工作負載、未放置原因、目前原檔保留位置／來源包引用、owner及手動處置／重試。預覽及執行後各出完整清單，過期狀況標記並可重新檢查；無法讀取目的不能冒充「同名文件已存在」。
- 目的同名且內容相同仍需核驗hash、必要metadata與帳號存取；可顯示「目標已有相同內容，未寫入」，不可無證據宣稱工具還原成功或取得ownership。同內容不自動解除整個非工具scope衝突，不放寬不合併定案。人工處置指引不要求清空Windows／產品共用目錄；不能安全放置者持續列明原因與原檔保存引用。
- initial／final、來源刪除、續跑及回退均不得刪掉目標非工具持有資料。先還原後安裝產生新檔／改檔須核驗漂移，先安裝後還原預覽產品所建目錄衝突；不能整目錄換回舊快照或蓋過同名設定。使用者人工整理後再預覽，工具不替其搬移／合併／覆寫既有文件；已受控且未漂移資料的正常delta／回復仍依原核准契約。
- junction／symlink 會衝突於目前 no-reparse、物理路徑隔離及 C 槽政策，因此本輪不把自動建立連結當作既定解法；若確有需求，須另討論指向、ACL、移除／回退、封裝遞迴及 consumer 支援，未核驗時不提供保證。
- 受保護安裝目錄、不同 profile／SID、缺少原磁碟、保留路徑已被占用及必要設定不受工具支援均須明確列缺口與處置；使用者要求原路徑可用的項目不能默默改映射。安裝完成後及切換前各驗一次實際位置／權限與引用，不能只在安裝前驗空目錄。

**驗收方向：** 新版換位置仍能從舊 `C:\temp`／原設定路徑取檔；原始 bytes／工作設定分別追查；目標有外部檔／同名衝突、同版本位置不同、帳號無權、先還原再安裝漂移、deferred 續跑、final 刪除與回退。必要非 C 相依以小工具／外部證據確認；衝突未處理不宣稱原路徑已可用，檔案已存回不宣稱新版／業務已可用。

## 非 C 槽跳板機小工具（建議方案，待調整）

提供單一 PowerShell 入口，支援互動輸入與等價參數；來源如 `\\source\D$\Business`，目的如 `\\target\D$\Business`。跳板機的 `D:\` 是跳板機本機路徑，必須明示，不能猜它代表遠端來源。以 SMB／企業授權帳號操作，不要求 WinRM，也不在參數、報告或 log 保存密碼。

建議流程：**輸入兩端 → 檢查權限／路徑／空間 → 建立來源完整清單 → 預覽差異 → 確認搬移 → 逐檔核對 → 再查來源變動 → 輸出結果**。另有只比對模式，目的端不寫入；報告存在跳板機使用者指定的位置。

- 預設涵蓋使用者輸入來源根目錄下的全部檔案、隱藏／system 檔、零位元檔與空目錄；不自行加副檔名過濾。整個 D 槽或局部資料夾由使用者決定，所有明確排除均出現在清單與結果。
- 主工具不封裝其他槽，也不禁止讀其軟體盤點中繼資料。已識別的非 C 檔案形成建議來源清單，仍讓使用者直接輸入／確認兩端，不新增 ZIP、資料庫、代理服務或另一套角色工作區。
- 檢查來源／目的實體重疊、錯機、路徑別名、UNC 可達性、剩餘空間、讀寫權限及 SMB／NTFS 權限差異。不能證明路徑不重疊時阻擋搬移；不能證明 UNC 確為非 C 槽時要求補來源 volume 證據，不能僅看 share 名稱。
- 不刪來源或目的多餘檔，不合併既有文件；預設使用新／空或已受控且未漂移目的範圍，其他已有內容列無法放置HTML清單，人工整理後重試。避免 `robocopy /MIR`、`/PURGE`、`/MOVE` 的刪除效果，採有限重試／可中斷；回傳碼不代表逐檔驗證完成，0–7 仍可能含差異。[Robocopy 官方說明](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)
- 採穩定來源清單、相對路徑、檔案大小及逐檔 SHA256 核對。既有同名同大小／同時間檔不能直接判相同；續跑僅略過已重新核驗相同的內容。不把同機讀取成功當成目的端可讀成功。
- 搬移前後重新列舉及核對來源；新增、刪除、改名、變更、鎖定、存取拒絕、網路中斷都使本次無法宣稱完整。網站／排程須在 final 比對前停止寫入，並維持到切換；兩次掃描一致不能保證掃描後不再變動，更不能取代 DB 一致性備份。
- 長路徑、ADS、EFS、reparse point、hardlink、sparse／壓縮及其他特殊檔案語意要先偵測並列明處置。未支援或未能核驗的項目標 Blocked／Failed，不能用略過參數換取成功。資料完整性與 NTFS metadata 保存分別驗證；本機 SID 更換不能直接照抄 ACL 就宣稱權限可用。
- 產生完整 HTML 報告及結構化結果：兩端、時間、範圍、模式、檔案／目錄／bytes數、逐檔依據、無法放置／缺漏／變更／失敗／額外檔、metadata與續跑。小工具也有HTML操作入口，復用本機UI但不新增獨立資料庫／常駐服務；報告只存企業受控位置。

**「沒有漏檔」的成功條件：** 核准來源集合每個檔案均有正確目的相對路徑與相同內容 hash，所需空目錄存在，所有讀寫與核驗成功，沒有未處置特殊檔案／必要 metadata，且 final 期間來源停寫及未變動。目的額外檔保留並列出；「來源集合已完整搬移」和「兩端完全相同」分開顯示。存在排除或外部處理時只對明確核准集合下結論，不宣稱整顆磁碟完整。

Manager 對必要非 C 相依接收綁定來源主機／根目錄、目的主機／根目錄及工作負載的驗證結果，使用者仍須核對實際證據；不得只勾「工具跑過」或捏造成功摘要解除切換門檻。不把小工具搬移成功當成網站／排程啟用核准。

結果是具版本的typed JSON／JSONL加完整HTML，不另建mutable pair資料庫；含OperationId、兩端主機／volume／UNC身分、正規化根、清單hash／項目／bytes、選取／排除、逐檔結果／metadata、時間與錯誤。受控清單供斷線續跑，重新驗證現況不靠「上次已複製」旗標；容量不足、缺清單或來源漂移要明確保留可重試狀態。Manager以獨立可信摘要匯入，必要consumer另引用PairId／plan／範圍及當輪final SourceFreezeHash／停寫窗口；與C槽final在同一一致性窗口才可關閉該相依。readonly比對不寫目的亦不取得ownership，普通目錄share名稱不作volume證據。

## 軟體／版本及輸出確認文件

每台完整 HTML 文件保留所有已發現的機器／使用者安裝、可攜工具、runtime、driver、專業軟體及業務程式。版本查詢使用卸載 `DisplayVersion`、檔案 FileVersion／ProductVersion、module／assembly／manifest等可讀證據，保留原值、來源、架構、安裝位置、scope／SID及consumer。同名不同位置／使用者不誤合併。

禁止為查版本執行未知 EXE、啟動業務腳本、載入第三方程式，或使用可能觸發 MSI 修復的 `Win32_Product`。不依檔名、時間戳或目前市場最新版本猜版本。讀不到 profile／registry／檔案時保留探索缺口，不能當成未安裝。

顯示範例：`內部匯出程式｜版本未取得｜C:\Jobs\Export.exe｜無版本中繼資料`。至少有清楚程式名稱；資料不存在、存取被拒與格式無法解析分別標原因。有多種版本證據互相矛盾時列原值待確認，不自行挑一個宣布相容。

文件必須回答：

| 使用者要確認的內容 | 文件呈現 |
|---|---|
| 需要安裝哪些環境／工具／軟體？ | 名稱、可取得的版本、架構、用途、consumer、安裝／授權準備責任及確認狀態；本體僅列清單。 |
| 兩台主機軟體差在哪、要手動補什麼？ | 來源／目標逐列證據、產品／實例配對、差異原因、人工補裝／設定行動及 owner；另列未比對／待驗證。 |
| 軟體補裝前後舊文件在哪裡？ | 舊絕對路徑→核准目的→實際目的、有效位置、安裝前後舊路徑存取、漂移／consumer 結果、衝突及回復方式。 |
| 網站／排程的哪些檔案有處理？ | 來源、目標、用途、工作負載關聯、C 槽主包／非 C 工具／外部處理／排除及實際結果。 |
| 環境設定有沒有幫忙搬？ | 逐項區分「工具可協助，待核准」「已搬且核驗」「外部搬移／重建」「尚未處置」，列 TNS_ADMIN 等實際生效值與檔案。 |
| 哪些仍可能漏掉或不能切換？ | 未解析路徑、動態相依、未載入使用者環境、權限失敗、版本衝突、特殊檔案及未完成準備／業務驗證；列 owner。 |

**HTML 為所有使用者確認／說明文件入口。** 每次交付附入口頁及資料／版本／時間標示，串接操作手冊、完整盤點／差異、選取／預覽、無法放置文件、原設定位置、還原／非 C 結果、人工待辦與回復／交接。離線包只用受控本地資源，不依 CDN／網路；檔名含 DocumentId，連結指向當次證據，不把可變「最新」頁當核准。

大量資料可搜尋／分頁及分檔索引，但全部原始列與缺口仍可從 HTML 找到；不能用目前最多 2,000 筆列印視為完整文件。提供明確完整下載／分頁列印入口，部分列印標示範圍，計數與明細一致。JSON作權威／machine資料，既有MD／TXT／CSV作相容輸出並同源，不是正常流程的必讀文件；repository開發文件保留Markdown，不將格式遷移混入這輪規劃實作。

**HTML交付邊界：** payload sealed包白名單保持嚴格；文件以獨立完整目錄／索引交付，不直接往已sealed ZIP加HTML。索引列全部頁面／資料／必要資源、DocumentId／Pair／revision／hash及ReportReferences，與相容JSON／receipt／匯入端一起改。連結使用受控相對路徑，跨機移動後仍可讀；離線file模式將資料內嵌或分HTML頁，不依賴瀏覽器允許fetch本機JSON。缺分頁／改hash／超預算／資源未交付均顯示文件不完整，不只交漂亮入口頁。

網頁使用者不必讀內部欄位名才能判斷主機／本次範圍／新舊觀測、已完成／待人工／失敗與下一步；進階頁才呈現revision／hash。原路徑提供可複製的正確絕對路徑、實際主機及可驗引用，不承諾HTTP頁能直接開任意file URI或執行來源程式。報告允許內部路徑／帳號等必要metadata，但原設定內容／secret不嵌入任何頁面／下載資料；受控原檔獲取走原payload權限與人工程序。

**計數與容量：** 發現／目前存在／選取／核准／本次可執行／已核驗／衝突／待軟體／外部／失敗／未處理分列；同一列各維度不互斥，不將相加當總數。檔案、空目錄、bytes與系統物件分別計；共享檔案按實體集合去重但保留全部consumer。分母是明示的本次集合，零集合為無操作、Unknown為未知，完成100%掃描或收到ZIP不表示還原成功。摘要可限頁，但完整缺漏與無法放置項都可下鑽。

容量預檢按所選集合及實體volume處理package／incoming／staging／backup保留／journal／HTML索引，保守估算不承諾壓縮率；目標有mount／SUBST／多代號時不能只看drive-letter相加。沿用有界JSON／索引／路徑／transport限制，超限在寫入前揭露可處理範圍與所需外部方式，不截斷成成功；未達代表性規模證據不宣稱企業效能。E2／U／F另驗鍵盤操作、清楚label／狀態、不只靠顏色、長名稱／中文字元、進度不卡搜尋與大清單虛擬／分頁讀取。

## 分批規劃、輸入／輸出與驗收（全部待實作）

沿用 E1（JSON 比較／人工準備）、E2（全使用者文件HTML／交接）、P（原設定路徑／不合併／無法放置）、G（兩種順序／續跑），新增 S（全選／自訂）及 U（全部功能HTML／文字備援）。版本自由選擇取代強制同版本，HTML取代使用者主要Markdown入口；先前逐檔合併建議未採用，不新增通用或逐檔合併。前後段契約／驗收一起更新，不先公開未接線還原按鈕。代號均為第三輪，不沿用舊完成狀態。

| Phase | 內容／規模 | 相依 | 完成證據 |
|---|---|---|---|
| R3-A | 輔助搬移／版本選擇／JSON／局部state／UI契約及schema；大 | 本次定案；局部實機／特殊能力需確認 | 新舊policy、版本／receipt失效、選取／核准分離、逐項世代／replay／狀態consumer、HTML並行／信任資源有契約。 |
| R3-B | 完整網站／排程／檔案相依探索；大 | A | 多虛擬目錄、多 action／帳號、動態路徑、非 C／UNC 及讀取失敗皆出列；owner 可補相依且不重複丟 consumer。 |
| R3-S | 預設全選、範圍／版本／映射、核准前範圍及保存；大 | A、B | 本次有效集合可批次確認、不被無關Pending擋住；跨頁／重選／重盤點／外部工作一致；R3-09／14及18編輯部分。 |
| R3-E1 | JSON 比較資料庫、初始／現況採集、版本選擇差異及人工準備；大 | A、B、S | 重啟可讀；來源版差異與是否符合選用版分列；未知／多實例可確認，補裝後重算；處理 R3-01／04／05／08。 |
| R3-C | C 槽限制與精確設定 payload；大 | A、B、S | 所選／核准集合接入 full／delta／CLI／匯入／還原；設定清單不帶安裝本體，跨磁碟掛載與舊包不假冒新政策。 |
| R3-P | 原設定路徑、無法放置清單、安裝漂移／位置；中 | A、B、S、E1、C | 不合併既有文件；逐檔列直接與scope衝突、人工整理後重查；修R3-02／03，保留外部資料及區分原檔／工作設定。 |
| R3-G | 檢查／兩種順序、逐項基線／deferred／delta與修復；大 | A、S、E1、C、P | 真正條件分流，缺base補可信完整內容、replay／rollback／CLI新狀態、容量／版本失效一致；R3-07／11／12及17執行部分。 |
| R3-D | 跳板機比對／搬移、可續跑清單與可信結果；大 | A、B、S、P | 非C選取／逐檔核驗、不合併／特殊權限、斷線續跑、兩端／volume／範圍／final證據與Manager匯入；R3-15。 |
| R3-E2 | 全部使用者文件HTML／可攜索引、彙總與可信交接；大 | S、E1、C、P、G、D | 文件包／payload邊界、相對連結／完整列／計數／世代／C非C一致；R3-06／10文件、15／16／17彙總、18稽核部分。 |
| R3-U | 全功能HTML、本機啟動／非互動worker／文字備援；大 | A、S、E1、P、G、D、E2 | 全角色／action對照，共用核心；長作業中取消／進度、重連／多頁／secret／可及性／Core；R3-10操作及13／16／18。 |
| R3-F | 整合／回歸及兩種順序隔離端到端；中 | 全部前段 | TS 以 Server 2016／全新 2025 跑來源版及選新版、全選／自訂、HTML／文字、C＋非 C、續跑／readback／回復；正式資格獨立。 |

建議順序：A → B → S → E1 → C → P → G → D → E2 → U → F。U 的畫面流程已在本文定義，原生橋接小實驗在 A 先確認可行性，完整可操作接線在依賴完成後交付。D 消費 P 的衝突／路徑契約；schema／資料庫、選取 receipt 及 producer／consumer 每段須可獨立檢查，必要相依一併完成後才 commit／push。

### 每批輸入／輸出與下一個使用端

- **A：** 輸入原範圍、全部定案與R3-01–18；輸出catalog／plan／operation state／journal新schema、選取／核准／逐項世代、版本receipt／失效、狀態返回碼、C非C結果／文件交付及runtime／release契約供全部批次。驗收舊reader／checkpoint受控相容、新事件replay、不改sealed plan、兩邊版本資格、未知／等待，以及長工作下listener仍可取消；實機／特殊策略不偷寫成已支援。
- **B：** 輸入兩機採集與來源工作負載；輸出檔案／設定／軟體consumer、非C／UNC／特殊缺口、完整探索coverage及owner補登，供S／E1／C／P／G／D。驗全量網站／排程／服務、停用項、動態與未被引用但由使用者指定的業務路徑；unknown不當無關，選取保留不受自動探索缺漏掩蓋。
- **S：** 輸入B清單、A契約及使用者自訂；輸出持久選取／版本／映射、相依影響、批次核准有效集合與sealed plan子集receipt供E1／C／P／G／D／E2／U。驗跨頁／零集合、未相關Pending不阻獨立scope、必要SID不假跳過、新／消失／重盤點、包後已核准內可重選／不增包外、取消已搬項不刪除及CAS多頁保留草稿。
- **E1：** 輸入來源、target首次實際基準／目前snapshot及S選版；輸出JSON、兩種版本比較、人工清單及target期望receipt供G／E2／U。驗FirstObserved不偽造純OS、來源facts不可改、封包後選版／配對／provider變動的局部證據失效、atomic／lock／中斷／budget，結果重算且各格式同源。
- **C：** 輸入來源政策、S核准集合及設定分類；輸出精確C payload／manifest／delta與可信完整base引用供P／G。驗各入口／舊包、去重／不重疊scope、取消不入包／不因delta刪目標、完整base加合法delta可還原此前未套項、未混非C／安裝本體，按實體volume／選取集合預檢容量。
- **P：** 輸入原路徑保存／生效映射及目標實況；輸出原檔／工作設定索引、位置、hash／存取／ACL／ownership、逐檔無法放置與回復供 G／D／E2／U。驗收 R3-02、新版改目錄、同名及父scope衝突全部出列、未知讀取不偽造存在、人工整理後重查、外部不合併／不覆寫、原檔hash及rollback／delta。
- **G：** 輸入E1／S receipt、plan／可信材料與P實況；輸出逐項applied base／結果／deferred／衝突、durable state／journal供E2／U／驗收。驗兩分支／新版、混合世代與缺base補完整資料、CLI／StageResult新狀態、late checkpoint replay、取消／重選不刪、局部回退、技術必要條件／容量／漂移、已分類獨立失敗與共用信任破壞的不同停止範圍。
- **D：** 輸入非C根／兩端、S選取／P衝突及當輪final停寫；輸出受控清單、typed逐檔結果／HTML及可信Manager匯入供E2／U／F／consumer。驗錯機／volume／範圍／hash／freeze／讀不到非Missing、斷線／重啟／新清單續跑、不合併／完整性／metadata，無另一個mutable資料庫；不同輪成功不能解除本輪相依。
- **E2：** 輸入全量／選取／核准、JSON／逐項世代／結果、可信非C／業務證據、手冊與稽核；輸出全人讀HTML文件完整索引、相容格式／ReportReferences／Fleet／LabReport供U／F／owner。驗不改sealed payload、跨機相對連結／離線file不fetchJSON、缺資源明示、超2,000完整列／計數分母／未知、全衝突與同內容未寫入、secret投影、Owner與actor分欄。
- **U：** 輸入共用actions／preview／結果、E2索引及A並行／release契約；輸出全功能對照、離線啟動指引、本機UI／worker／session與文字備援供F／TS。驗首次TS能啟動、全角色／小工具／回復等真實接線、無隱藏stdin、長工作仍進度／取消、重連／故障／雙頁／CAS／secret／Origin／token／注入／可及性／Core、UI資源改缺拒絕，無第二執行引擎。
- **F：** 輸入全部批次、代表性實機／規模、兩邊產品版本及新版媒體；輸出逐項原始需求／本次8個使用者情境、四視角及跨段完整性核對、定向／整合回歸與實機證據。驗HTML／文字、先補裝／先還原、封包後選版、原路徑衝突、局部base／delta／repair、C非C同輪、multi-tab／取消／離線交付／容量／回復。合成觀察不代替實機或新版產品資格。

- [ ] R3-A：定義全契約／逐項state世代／replay／版本receipt／返回碼／非C結果／HTML並行與相容性。
- [ ] R3-B：完成網站／排程／支援服務的依賴清單與 owner 補查。
- [ ] R3-S：全選／自訂／重選、相依影響與核准前有效集合、CAS；R3-09／14及18。
- [ ] R3-C：落實 C 槽限制及設定精確集合的所有 producer／consumer。
- [ ] R3-D：小工具／清單續跑／typed結果／同輪final證據與Manager匯入；R3-15。
- [ ] R3-E1：完成 JSON、基準／現況、來源／選用／目標版本、配對與人工清單；處理 R3-01／04／05／08。
- [ ] R3-P：處理原路徑／漂移／逐檔無法放置，不合併既有文件；修 R3-02／03，含 delta／ownership／回退。
- [ ] R3-G：兩種順序／逐項base／deferred／delta補完整／replay／返回碼／回退；R3-07／11／12／17。
- [ ] R3-E2：全HTML文件／可攜完整索引／計數／稽核／相容格式／交接；R3-06／10／15–18文件部分。
- [ ] R3-U：全HTML操作／啟動／worker／取消／非互動／多頁／secret／可及性；R3-10／13／16／18操作部分。
- [ ] R3-F：完成整合、文件、適當回歸與實機證據；未取得外部資格仍保留阻擋。

主代理驗收時依專案、程式、尖銳但合理的使用者與管理者四視角反查：不能只看新增 happy path。先用使用者從盤點到切換走完，再從整體檢查核准／套件／版本／相依／還原／回退是否一致；不為一次檔案搬移加常駐服務或泛用產品 adapter 框架。每段完整且驗證後，依全域規則 commit／push 本輪分支，確認遠端 SHA；不能把未驗證相依拆出去先推。

## 剩餘待討論項目與本輪界限

本次輔助搬移、自由版本選擇、全選／自訂、原路徑保存、全部使用者功能／文件HTML、本機PowerShell／文字備援、C／非 C、不合併並列無法放置、非IIS不新增adapter已定案。強制同版本與主要Markdown入口已被取代，不自動轉換格式或承諾新版相容。資料還原與可選啟用／切換各有結果；輔助搬檔不必先完成整套切換才能取得HTML文件與還原結果。

1. **原路徑衝突（已定案）：** 使用者決定不做合併，HTML文件明列因目的已有內容無法放置的原檔。P／D／G／E2／U共用原因、scope影響、來源證據及重查；不新增逐檔合併或外部覆寫按鈕，原路徑未可取仍列未完成。
2. **版本與自有程式的證據：** 不再要求每項先確認同來源版本才能存回檔案。未知版本列名稱、原因與owner發布識別；OSProvided／ExternalSoftware／Unknown、版本解析及證據有效期在 A／E1依原值定義，產品執行按實際consumer驗證。這是避免假資料的實作契約，不再作是否允許新版的產品選項。
3. **直接還原的真實能力：** 具備條件的資料／設定先處理，原生 API／runtime 不足的項目待處理；不能承諾缺 IIS 角色仍可建物件。R3-07 在本輪重構，無版本／新版亦不能偽造 PreparationReady。只是選擇不做某 workload 時，其未選操作不阻擋無關資料。

以下保留實機材料與局部metadata／特殊檔案策略需求，不能用HTML定案掩蓋尚未支援項；所有缺口仍在本輪，非IIS與合併已不再待定。

### 初版仍待討論的實作策略

1. **非 C 範圍與特殊檔案：** 建議輸入任意根目錄就完整處理該集合，不預設漏 hidden／system；特殊語意先阻擋並清楚列出。若業務確有 ADS／EFS／連結需求，再決定本輪原生支援方式，不能在未支援時承諾零缺漏。
2. **非 C 權限與 metadata：** 目的衝突已採不合併／人工處理；需實機確認 attributes／timestamps／ACL／owner／SACL與SID映射必要性。先沿用主工具既有審核權限契約，不能將非C資料hash成功說成權限完整；必要未支援項保留缺口，新增特殊能力才另討論。
3. **非 IIS 網站（已定案）：** 完整盤點相依及保存所選檔案／設定，現有受驗 adapter以外的安裝／套用／啟用列人工處置；本輪不新增特定產品adapter。B／G／U／F不得泛稱Apache／nginx／Tomcat已有自動還原。
4. **完整性證據：** 建議 final 停寫＋逐檔 hash 為必要條件；大資料量的驗證成本與停機窗口先量測，不為加速預設改成只比大小／時間。真實來源規模、使用者環境與特殊檔案樣本需在 pilot 前取得。

本次從使用者8個情境走查，再依程式、管理者及整體反查，保留R3-01–10、補R3-11–18。重點是核准前範圍、封包後選版、逐項世代／狀態consumer、長作業取消及C非C／HTML可攜交付；11個Phase的輸入／輸出／相依與驗收同步，A／D因實際閉環需求調整規模。未修runtime／tests；已定案的全選／新版／不合併／HTML／軟體人工安裝／非IIS界線保持，既有外部實機／資格不作完成。

### 從頭反查的跨段影響結論

| 交接鏈 | 必須成對改動的producer／consumer及反例 |
|---|---|
| 盤點→選取→核准→封裝 | B全量與coverage，S意願及有效集合，A／ReviewComplete／plan核准，C精確manifest；外部Pending不阻獨立集合，共用／重疊檔案不互覆。 |
| 選用版本→比較→準備→產品資格 | S選擇、E1原值及目標receipt、G局部期望／失效、A／F兩邊版本／provider資格；舊Requirements／舊資格不可冒充新版，未改來源內容不重封。 |
| 部分還原→delta→repair→rollback | G逐項base／receipt，C完整材料／合法chain，journalreplay／OperationRequests／StageResult／Fleet共同消費；未選／待處理不晉升、缺base不從不存在target補檔。 |
| C主包→非C工具→final→切換 | D兩端／volume／範圍／清單／freeze結果，E2可信匯入，G／consumer及既有CrossHost門檻；普通複製成功不等於同輪final或可用性。 |
| 本機HTML→worker→核心→取消／秘密 | A小實驗，U啟動／非互動／分離請求與長工作，Cancellation獨立marker／progress，核心lock／journal；不能HTTP同步忙到取消送不進，也不能把credential落盤到job。 |
| JSON／結果→HTML索引→交付→管理者 | E2完整安全投影／計數／相對連結／成員hash，receipt／ReportReferences／LabReport／Fleet、U離線／session入口；文件包與sealed payload不同權威，缺資料不靠漂亮摘要過關。 |
| runtime資源→指紋→release→舊資料 | A／U可執行UI資源，ToolFingerprint／SBOM／ToolRelease簽章，新schema／state相容與舊reader拒絕；靜態說明改動只改文件hash，不偽稱runtime失效。 |

結論：方向符合輔助使用者定位，但前版對整機核准／整體世代與局部執行之間尚有實作歧義。本次補足可驗證的行為契約，仍須各Phase真實接線與反例通過；不能只跑舊回歸就宣稱新流程正確，不能僅以文件措辭補強宣稱runtime缺口已修。

上述產品決策已由使用者確認；文件檢查不表示程式已實作或網站／排程可直接正式切換，未確認的特殊能力與實機條件仍明列。現有外部驗收與正式資格仍未完成。
