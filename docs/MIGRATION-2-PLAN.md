# MIGRATION 第 2 輪規劃：一般服務主機、完整環境確認與企業 EOS 遷移資格

> 日期：2026-10-09
> 狀態：實作中；2026-10-09 使用者授權開始實作並持續核對完整性。各項完成狀態見文末執行紀錄，新增功能及正式資格不得一併推定通過。
> 複審基準：codex/implementation，991fc864126d226b65eb0fdbe440c7f7d41040af；前輪程式與測試基準保留於下方。
> 來源：一般主機既有定案，以及使用者要求企業 Windows Server EOS 正式工具程度、Oracle TNS_ADMIN 與完整已安裝環境／相依工具／使用者軟體 Markdown 確認。
> 複審證據：[深度複審](MIGRATION-2-REVIEW.md)；確認文件格式：[環境與軟體確認表](ENVIRONMENT-SOFTWARE-CONFIRMATION.md)。
> 輸出方式續規劃基準：9b01678d56f8fdfaced54cbdad115536eba7b688；採以下建議設計，尚未實作新目錄旅程／大小選擇／交付索引。
> 再次反向複審基準：247c528662d24adf4c52fae3dec0c544ec821a7c；另補 R2-21–R2-28。下列穩定狀態、分階段 gate、增量分卷等仍是必要待實作契約。

## 前一輪確認

- 「測試效率調整」段落已完成：db48766／349195c 已推送，遠端分支指向 349195c；GitHub Actions 37800134683 的 fixtures／delta-workflow 全部通過。
- Pipeline／CancellationWorkflow／Report／FleetScale／SpecScale 在固定快照於 WinPS 5.1／PS7 各 5/5 通過。正式 src／入口未改，既有完整回歸及實際 >4 GiB 證據沿用。停止的 10k 小檔全劇本不計 PASS。
- 整體舊 PLAN 尚未全部驗收：實際 Server／業務／名稱 IP／重開機／回退、瀏覽器／主控台及獨立體檢仍有缺口。不能把上一段完成寫成整個專案完成。
- 舊 PLAN 的特殊產品自動遷移擴充，依本次使用者定案移出新方向；保留盤點／告知與外部相依證據。一般主機的原生 API、資料一致性、回退與業務驗收仍必要。
- 本輪主代理撰寫規劃，沿用目前分支；本次不變更正式程式、不操作實際主機。使用者本機 prototype 不改動、不加入公開 repository。

## 目標與定案

1. 工具服務一般 Windows 成員伺服器／工作群組服務主機：一般 IIS、自訂服務、排程、檔案 scope／非叢集 SMB，以及其必要帳號、憑證與明確設定。
2. 提供「新主機離線準備清單」。安裝檔由使用者取得並安裝；工具不搜尋網路、不下載、不安裝或註冊 runtime／第三方軟體。
3. 特殊角色／專用產品不由工具搬移，但必須顯示發現結果、未探索範圍、理由及責任人。不能消失在報告，也不能把主機上的所有第三方元件都判為特殊服務。
4. Windows 系統設定獨立審核，預設不批次搬入；每項可選沿用目標、核准搬入、外部處理。沿用目標的影響也必須顯示。
5. 完成表示核准範圍逐項有結果且必要相依已處理，不表示整台舊機複製成功。特殊角色另行處理完成前不能宣告整台服務接手或舊機可退役。
6. 各台本機執行、离線集中彙整、選單與 CLI、類別報告、大量排除與十台波次沿用。
7. Oracle Database 引擎／listener 仍是特殊產品；一般應用所需 Oracle Client／Instant Client／ODAC／ODP.NET、TNS_ADMIN 及其設定檔是本輪必要交付，不能因名稱含 Oracle 一併排除。
8. 每台輸出完整 `.md` 確認文件，包含全部已發現軟體與環境，不只入選相依。沒有來源 Server 證據時只能交空白確認表，不能拿開發機軟體清單冒充。
9. 正式程度以精確支援矩陣、可稽核核准、實際業務及復原證據判定。A–D 功能完成不等於正式資格；E 的資格／發行／放行證據同樣是必要交付。
10. 輸出建議採「先指定受控工作目錄，再選交付模式」：預設分卷 ZIP、保留封存資料夾直接搬運；使用者可指定每卷上限，確認文件另存可直接閱讀的 reports。所有遷移資料只限核准 scope，不代表整機／產品完整備份。

## 批次總覽

| 批次 | 內容 | 規模 | 相依／輸出使用端 |
|---|---|---|---|
| A | 範圍分類與特殊服務告知 | 中 | 來源盘點 → 管理端 B/C/D |
| B | 完整環境／軟體盤點、離線準備、Oracle 用戶端設定 | 大 | A → 使用者確認／準備 → C／目標預檢／還原 |
| C | Windows 設定清單與逐項決策 | 大 | A/B → 規格核准／設定還原與驗證 |
| D | Markdown、統一輸出目錄／分卷旅程與十台彙整 | 大 | A/B/C → 操作者／管理者／核准／搬運與匯入 |
| E | 相容、實機資格、切換復原與企業放行證據 | 大 | A–D → 隔離試用 → 資格審查；合格後另行正式放行 |

順序 A → B → C → D → E。每批需輸入／輸出及實際呼叫端完整，完成適當驗證後獨立 commit／push，確認遠端 SHA。批次內可先交付完整子段；不可推送半接線功能。

各批次同時受文末「深度複審補強契約」約束：B 拆 B1／B2，E 拆 E1–E3；下方原始批次條目不是完整交接清單。原始需求與新增必要交付對照 [R2-01–R2-20](MIGRATION-2-REVIEW.md)。

## 批次 A：範圍分類

### 現況與核對結果

- Inventory.ps1:29 有安裝軟體來源，48 有各類 DiscoveryGap；不是完整產品相依圖。
- EnterpriseDiscovery.ps1:8–11 探索專用角色與未開深層探索缺口；部分探測缺少 cmdlet 時輸出 Unsupported，不能視為不存在。
- Adapters.ps1:21–23 阻擋受保護服務與 AD／CA／cluster／DNS／DHCP／Hyper-V 等 generic 還原；限制仍保留。
- Review.ps1:42 起現有審核門檻要求未知／排除項的 owner 與證據，需要接入本輪分類，避免新模式繞過舊門檻。

### 改動與契約

- 加入物件層級的處置分類：一般可搬項、環境準備項、系統設定待選項、特殊產品告知項、未知／探索失敗項。分類獨立於 Include／Exclude，不能重用 Unsupported 作所有狀態。
- 特殊候選包括 AD、DNS／DHCP 角色、CA、SQL／其他 DB 引擎、叢集、Hyper-V、DFS／複寫、MSMQ、RDS、WSUS、列印、NPS／RRAS、第三方伺服器產品／代理。僅保留判別必要 metadata，不擴充其完整產品匯出。
- 自訂 Windows Service 即使 publisher 是第三方，仍可為一般服務；runtime／ODBC driver 仍列準備项。辨識規則需有來源、理由、可信程度；模糊分類需 owner 覆核與有理由的 override。
- 不整台排除混合主機。特殊物件可批次確認「工具不處理，外部負責」，留下 ItemId、產品／版本、owner、影響與處置。
- 被納入一般項所需的特殊 provider／外部 DB 不得因排除而解除依賴。可用具 owner、檢查與有效期的外部相依確認；無確認阻擋依賴它的項目。其他獨立一般項不因此全部阻擋。
- 深層 metadata 探索用於一般服務相依；不開啟或探測失敗均報缺口。偵測名稱／服務不足以宣稱完整識別。

### 驗收

- 混合 IIS／SQL 主機：SQL 告知但不搬，IIS 保留；依賴 SQL 的 IIS 必须有外部可用性確認。
- 同樣是第三方：一般自訂服務不誤排，監控／資安代理列為使用者重新部署項，不複製其產品服務。
- 缺 cmdlet、權限不足、未知產品、override、批次確認均能走到完整分類文件與核准門檻；不得默默排除。

## 批次 B：離線環境準備清單

### 現況與核對結果

- Inventory.ps1:29 收 DisplayName／DisplayVersion／Publisher／InstallLocation。
- Discovery.ps1:17–20 有 32／64 位元 ODBC DSN；EnterpriseDiscovery.ps1:12 有 COM+ metadata。
- 現有 collector 是分散證據，缺可交給管理者取得安裝檔的彙整清單及與一般項的明確關聯。
- Inventory.ps1:29 只有 HKLM Uninstall 兩種 view；Discovery.ps1:17–20 只有 machine DSN；EnterpriseDiscovery.ps1:1 只收 Machine 環境。缺使用者／可攜軟體與有效 consumer context。
- ConfigArtifactContracts.ps1:1–4 的自動辨識只有 web.config／app.config／exe.config／appsettings JSON；src／tests 無 Oracle 專用識別及測試。既有人工 ConfigFiles 能列檔，不代表有效 Oracle 設定路徑已驗證。

### 改動與契約

- 偵測 .NET Framework、.NET／ASP.NET Core runtime／Hosting Bundle、VC++ redistributable、32／64 位元 ODBC provider／DSN、PowerShell／腳本引擎與模块、IIS角色／擴充模組，以及自訂服務／排程的 executable／工作目錄／腳本／設定來源。
- COM／COM+、native DLL、未知 runtime、授權或加密的機器綁定材料無法完整推導時，列人工確認；不掃所有 DLL、不執行來源安裝器／程式、不用 Win32_Product 觸發 MSI 修復。
- 使用可信本機 metadata、registry／檔案與已有 API；不聯網、不安裝 collector、不啟動業務服務。外部連線測試由使用者明確選用；預設不探測 endpoints。
- 每列：PreparationId、名稱、版本／架構、來源機／關聯 ItemId、證據與時間、已證實／候選／待確認、建議準備方式、使用者提供的內部媒體位置／雜湊、owner、狀態及確認結果。
- 安裝軟體清單 ≠ 每個服務的相依清單。只有已證實或 owner 確認的 required 關係才作阻擋；候選需覆核，不依名稱猜精確最低版本。不把較新版本自動當相容。
- 十台可依產品／版本／架構彙整取得媒體清單，保留每台需求與驗證，不能用其他主機的通過取代本機。
- 使用者安裝後，本機重查可證實條件：缺少、符合、版本不同待批准、不支援、無法驗證。人工項需 owner 與依據。必需未完成時預覽列出問題，還原／啟用依受影響項阻擋。
- 目標準備證據綁定 TargetIdentity、工具、requirements revision、來源證據與時間；核准後再綁計畫 hash，順序依 B1 避免循環。新盤點、需求改變、目標環境漂移需重查。套用後重開機未完成不能視為 ready。
- generic WindowsFeature 亦不得在本模式中順帶安裝來補環境。必要角色由使用者用媒體準備，工具只核對。舊 pilot 明確核准安裝契約保留相容，不能擅改既有計畫。

### 驗收

- metadata fixtures 覆蓋 x86／x64、Framework／Core、同名異版本、空／失敗結果、未知關聯、內部媒體欄位与目標差異。
- 真實 consumer：盤點 → 去重清單 → 使用者記準備 → 目標重查 → preview／還原／啟用；失效證據／重開機／未準備不能放行。
- 不自動呼叫 downloader／installer／網路或執行來源 scripts；報告不外洩 DSN 密碼、連線字串、產品金鑰與來源命令中的 secrets。

## 批次 C：Windows 系統設定逐項確認

### 現況與核對結果

- Discovery.ps1:16 有時區／語系／機器環境，40–42 有 hosts／部分 proxy／SCHANNEL 探索。
- Inventory.ps1:33 讀 ActiveStore 防火牆，但來源可能是本機／GPO；不能全部當本機自訂規則。
- EnterpriseDiscovery.ps1:27 的 HTTP.sys／WinHTTP／SPN 等仍是 owner 確認缺口；35 讀執行原則／AppLocker。MachineEnvironment／FirewallRule 有 adapter，但無完整系統設定選擇旅程。

### 改動與契約

- 獨立系統設定頁面：先問「是否審核 Windows 系統設定」。選否即明列整類沿用目標與相依影響，不能直接 Include 或假設排除無影響；選是仍逐項／批次 preview 決策。
- 顯示來源值摘要、目標值摘要、控制來源（Local／GPO／有效值來源不明）、自訂判斷與依據、影響／風險、支援動作、預期差異和責任人。
- 分清「發現設定／與目標不同／有基準證明自訂」。無可信對應 OS 基準、原始 baseline 或 owner 依據時標為需確認，不聲稱能準確找出所有自訂值。目標不同不能證明來源自訂。
- 首批清單涵蓋時區、系統／使用者語系及 code page、機器環境變數與 PATH、hosts、WinHTTP／相關 proxy、DNS client／suffix、路由／NIC、Windows firewall、local users/groups、service logon rights、憑證鏈／私鑰 ACL、HTTP.sys URL ACL／SSL、TLS／SCHANNEL、本機安全／稽核原則、execution policy／AppLocker／WDAC 及 GPO 控制說明。
- 帳號／憑證若是業務項必要相依，仍走既有精確 SID／SecretRef／PFX 審核；Windows 設定整類選否不能略過這些相依。
- 首批自動套用限定已有審核 adapter 的允許機器環境變數、本機且完整支援欄位的防火牆規則，以及新增具完整 readback／回復的時區設定。其他清單項為「保留目標」或「外部處理」，沒有測過的 adapter 不顯示可自動搬入。
- PATH 不整段覆蓋，hosts 不複製 loopback／系統檔 baseline；若需變更 PATH／hosts，產生來源／目標差異與人工合併清單，本輪不自動套用。
- 網域 GPO 不轉成本機設定；未知管理來源、目標 domain policy 優先時告知。execution policy／AppLocker／WDAC、TLS、權限、稽核政策需資安 owner 處置，本輪不批次降低目標基準。
- 名稱／IP／DNS 接手沿用獨立切換計畫；系統設定清單不得提前修改目標 NIC／名稱造成 staging 上線。
- 決策綁定来源／目標值 hash、revision、owner、理由。變更使核准／驗證失效；套用前重新核對，衝突阻擋且保留原值，套用後 readback，回復只限工具持有且未漂移設定。

### 驗收

- 全類選否、個別搬入／沿用／外部處理、大量 preview、來源未知、GPO 控制、目標漂移、時區套用／中斷／readback／回復。
- 時區影響排程時必須提示并確認，不自行調整工作時間；同名規則未完整支援不能無條件搬。
- 系統設定拒絕／選否仍留下完整條列與影響；依賴必要設定的業務項未協調時不能啟用。

## 批次 D：操作與交付文件

### 改動與契約

- 管理／來源／目標角色旅程接入：選一般主機範圍 → 看特殊服務 → 環境準備清單 → Windows 設定選擇 → 使用者准备新主機 → 本機重查 → 規格核准與搬移 → readback／業務確認 → 切換／回退。
- 使用中文且沿用現有分頁、搜尋、分類計數、CSV preview／revision、跨頁規則與撤销；大量資料不逐筆阻塞問答，不改既有 all 的範圍語義。
- 類別文件 HTML／完整 TXT／CSV 與權威 JSON：一般搬移清單、離線準備清單、Windows 設定決策、特殊服務／探索缺口、目標差異及未完成事項；另必須提供每台完整 Markdown 環境／軟體確認文件。每項可追至來源 ItemId，全部摘要數量能對帳。
- 特殊告知項已讀與外部處置分開記；報告明列「工具未搬」及是否影響入選服務。泛用範圍完成與整台接手／可退役分開，不能把特殊告知全轉 PASS。
- Fleet 十台總覽呈現來源／目標配對、需準備項、依賴阻擋、系统設定決策與驗證、特殊處置及本輪進度；离線導入拒絕重複／過期／錯機結果。
- LabReport 的 TXT 優先显示問題，完整 JSON 留本機；依使用者貼回結果補實機證據，省略的項目不當通過。公開報告輸出脫敏摘要，原始 registry／DSN／設定留受控證據。
- 不先插入進階帳號管理或線上 dashboard；沿用離線方式及既有核准。來源／目標操作者、應用 owner、遷移核准人、平台／資安核准人的責任及簽章信任證據納入 E 的必要放行項，可由企業既有離線變更流程滿足。

### 驗收

- 同一小型固定案例走選單／CLI／API 到最終報告；錯參數、EOF、取消、兩台同名物件、部分準備、CSV stale 等負例。
- 十台各 200 合成資料驗分類／決策／匯入對帳；不啟動無門檻的一萬小檔全劇本。真實主控台／瀏覽器由可用環境驗證，DOM 不替代畫面驗收。

## 批次 E：整體影響、相容與最小實機驗證

### 改動與契約

- 新 schema 明確版本與相容路徑；既有 source identity、ItemId、DecisionRevision、approval／manifest／journal 不原地覆寫。舊盤點缺新增證據顯示需重新探索，舊包缺準備核對不能冒充新模式已核准。
- 工具精確 bytes 改變仍要求新核准，來源／目標使用同版發行；執行中的舊 pair 依原版完成或經明確協調重建，不能中途熱換程式。
- 已有 generic OS feature 安裝／ManualWorkflow 原始契約不悄悄改語義；新「一般主機離線模式」明確選擇與驗證，special scope不新增自動 restore。
- 新資訊輸出不洩漏 credentials；不聯網、不改企業執行政策。ZIP 仍需企業受控／加密交換及獨立可信 hash；本輪不把未簽署發行改寫成企業信任完成。
- 正式生產模式不在本輪直接打開。功能完成、實機資格、企業核准分開；沿用精確支援 tuple，未驗證環境報不明／需資格。

### 測試與驗收

- 只重驗受影響 producer／consumer 與相關既有包／delta／切換／回退／報告契約，固定快照核對 hashes。沒有改 payload 的 >4 GiB 有效證據不重跑。
- 一組代表性 Server 2016→2025：離線／無網際網路來源與目標；使用者按清單安裝缺的 runtime／role；搬一個 IIS、一般服務、排程、小型分享及實際必要帳號／憑證。
- 驗證至少一個準備不足阻擋、外部特殊相依確認、系統設定沿用／核准時區、一個中斷接續、reboot 與回退；業務交易／排程行為由 owner 確認。
- 透過 LabReport TXT／JSON 回傳來源／目標與具體未完成項；根據實際差異才加入不同 source OS／Core／32-bit／政策／特殊資料組合。十台分波次，不全排列測試。
- 代表性工作量先定維護窗、RPO／RTO／空間目標，再做一次封裝→還原量測。這不是要求大量小檔重跑每種故障。
- 結束前主代理逐條核對 A–E（含 B1／B2、E1–E3）、原始與本次新增需求、舊資料相容與文件；缺實作繼續補，缺外部資格保留 NotTested，不從 TODO 偷刪。

## 本輪交付與範圍外

- 交付：一般主機處置分類、完整環境／軟體 Markdown 確認、離線相依與媒體準備、Oracle 用戶端／TNS_ADMIN／受審核設定檔搬移、Windows 逐項決策、有限已驗套用、目標 gate、六類文件及 Markdown、選單／CLI／Fleet／LabReport 接線、測試／手冊與企業資格／放行包。
- 不做：自動取得／安裝第三方軟體、所有 runtime 自動部署、專用產品／角色遷移、完整 registry／系統磁碟還原、機器綁定密碼／授權複製、所有 OS 預設值推導、全部系統政策自動匯入、網際網路依賴。
- 特殊項只告知／外部處理，但必要外部相依必須確認；單純「忽略」不允許宣告整台可退役。
- 企業簽章／加密交換／角色分離及安全審核是 E 明確可查證的放行條件，可沿用企業流程；外部材料未提供時記具體缺口，不能以程式測試或規劃書代替。
- 實作啟動：使用者確認下一輪開始實作後，按 A–E 分段驗證並推送。本文件完成不代表功能已完成。

## 深度複審補強契約（2026-10-09，與上述 A–E 同屬必要驗收）

以下是本次需求的補強，不是可選建議。與前文較簡略的敘述有差異時，以這裡的明確契約為準；既有離線／人工安裝／特殊產品不搬的範圍保留。

### A 補強：物件與相依分類不能互相冒充

- 第三方伺服器產品、一般應用本體、client driver／runtime、監控／資安／備份代理分開。SMTP、NLB、容器／Docker、排程平台、硬體 driver／dongle 授權亦須出現在已發現或未知清單，不因此新增產品自動還原。
- 一個軟體可以是多個服務的相依；SoftwareId／PreparationId 與 ItemId 的關聯允許一對多、跨台及共用 scope。同名不同版本、架構、SID、安裝位置、Oracle Home 不合併身分。fleet 媒體去重只是投影，不能抹除各台需求。
- 既有 Review.ps1:50 的 Mandatory 依賴只接受 Include；新 Preparation／ExternalDependency 需明確型別、來源、有效證據與完整 consumer。不得把特殊產品 Include 或移除依賴來繞過 gate；同型檢查包含核准、preview、restore、activate、fleet、LabReport、retirement。

### B1：完整已安裝環境／使用者軟體與離線準備

**輸入／輸出**：來源 inventory／owner 補登 → 完整 SoftwareCatalog／CoverageMatrix／PreparationRequirements → D 確認文件與決策 → 目標準備核對、C 設定映射與 E gate。

- 來源包含 HKLM 32／64 Uninstall、已載入且有權讀取的 HKU 使用者 Uninstall／環境／DSN、roles／optional features、已知 runtime 安裝位置、服務／task／IIS 指向的 executable／腳本／app-local runtime、核准的 portable 搜尋根目錄與 owner 補登。以 SID 標示 user scope；HKU 的 class view 不重複計數。
- 未載入 profile、無權限、無登錄安裝、超過搜尋預算均為 CoverageGap。本輪不自動載入 hive、不登入其他帳號、不讀任意 process 記憶體、不全磁碟掃描。owner 用指定帳號本機補盤點或人工補登並附證據；「未查到」不能標「不存在」。
- 每列有 SoftwareId、原始名稱／版本／publisher、架構（未知即 Unknown）、scope／SID、位置、registry view／檔案／API 證據、ItemId、時間與 capture 狀態；registry view／Program Files 位置本身不能證明 executable bitness，缺版本不寫成零或最新。
- 增列有實際 evidence／owner 提示的 Java／JRE／JDK、Python／venv、Node.js／套件環境、PHP、PowerShell module、IIS URL Rewrite／ARR／ISAPI／Hosting Bundle、ODBC driver／system／user／file DSN、OLE DB／COM registration。lockfile／runtimeconfig／deps 只作 metadata，不執行套件管理器。
- 服務帳號環境／工作目錄／service-specific environment、IIS pool bitness／LoadUserProfile、task identity／working directory、app-local 設定／user profile 分開。管理員終端成功不能代表 LocalSystem／gMSA／業務帳號成功；mapped drive 不能當跨帳號 UNC。
- **全部已發現軟體**都需處置：使用者重裝、核准可攜檔／設定搬移、保留已驗相容目標、外部產品流程、明確不需要。未選服務也保留列；Unknown／未確認不隱藏，必要相依標「不需要」仍阻擋。
- 不搬整個 Program Files／MSI 安裝狀態代替產品安裝。installer 已建立同名 service／task／IIS 時列 ownership／設定衝突，只經核准採用已驗設定或外部流程；不把既有目標物件改標工具建立。可攜軟體需完整檔案／runtime／授權與可再部署證據。
- 每個準備項列內部媒體／hash／簽章或人工驗證、版本／架構、vendor OS 支援證據與查證日期、安裝順序、授權、restart／reboot／副作用。只有來源已裝並不代表支援 Server 2025；不把新版自動當相容。
- 手動 installer 也可能自啟服務／排程、外連或寫 DB。安裝前建立目標隔離基準，安裝後本機差異核對／quarantine；無法阻止重複工作或生產寫入時停止 staging。使用者說裝完或 installer exit 0 不等於 ready。
- 準備證據綁 PairId、來源／目標 fingerprint、inventory／requirements／decision revision、工具 fingerprint、帳號 context、有效期與 hash。核准前以 requirements revision 綁定，plan 產出時引用該 hash；核准後再綁 plan hash，避免準備必須先有 plan 的循環。每個 CheckId 另列 RequiredPhase、consumer、實際受驗需求投影的 hash；revision 是可追溯資料，變更按受影響投影撤銷證據，不因無關決策變動要求全部重新安裝。沿用仍有效證據須有 fresh readback／關聯紀錄，不改寫原證據或繞過新核准。
- **順序**：PreparationReady 僅驗目標已備妥的 client／runtime／帳號／隔離／restart 與該階段外部材料；由本輪搬入的 TNS 檔案與設定有效性放在 StagedDependencyVerified，真正 consumer／DB／業務測試放在 CutoverReady。檔案尚未搬入不是要求先跑還原的準備循環。任何階段未知仍阻擋其受影響 consumer；不得把所有未知移到最後以提前放行。

**B1 驗收**：HKLM／HKU／portable／人工列都到 D 的完整 `.md`；同名異版本／SID／view 不合併，空／失敗／profile 未載入／搜尋上限有 coverage；missing driver／wrong bitness／installer 自啟／同名既有 service／reboot 正確阻擋，其他獨立項可繼續。

### B2：Oracle TNS_ADMIN 與用戶端設定必須形成搬移閉環

**輸入／輸出**：consumer／client metadata、有效設定證據、owner 確認 → 精確設定檔／環境／路徑映射與機密外部交付 → approved package／目標 readback／實際 consumer 測試 → 啟用／回復 gate。

1. **辨認 consumer**：OCI／ODBC／ODP.NET managed、unmanaged、Core／JDBC 等 provider、版本、x86／x64、Home／Instant Client、帳號、工作目錄、關聯 ItemId。搜尋順序依實際 driver／版本核對，不共用單一規則。[Oracle 19.3 ODP.NET](https://docs.oracle.com/en/database/oracle/oracle-data-access-components/19.3/odpnt/InstallConfig.html)與[Oracle 26 ODP.NET](https://docs.oracle.com/en/database/oracle/oracle-database/26/odpnt/InstallConfig.html)已有不同配置能力。
2. **候選與有效值**：Machine／可讀 User／服務自有 TNS_ADMIN、32／64 Oracle registry view、Home／Instant Client 的 network/admin、app／web.config／程式設定／JDBC 配置；需要的 NLS_LANG／LDAP_ADMIN／LOCAL／ORA_TZFILE 與 PATH 順序也列出。標記實際採用依據、被遮蔽值及未知，不能只讀管理員 `$env:TNS_ADMIN`；Windows 環境／登錄／Home 行為見[Oracle Net 文件](https://docs.oracle.com/en/database/oracle/oracle-database/19/netrf/local-naming-parameters-in-tns-ora-file.html)。
3. **檔案入包**：已確認使用的 tnsnames.ora／sqlnet.ora／ldap.ora／oraaccess.xml、owner 核准的 IFILE／參照檔，列入精確 ConfigFiles 與受控 FileScope／ConfigArtifact。保存原始 bytes／encoding、hash、ACL／SID mapping、來源／目標路徑及敏感等級。不能只在文件提醒使用者自行記得拷貝。
4. **界限**：bounded 參照解析遇循環、語法不支援、UNC、超出核准 scope、缺檔即列缺口並阻擋 consumer，不偷偷擴 scope。共用設定只有一個權威搬移 owner，多個 Home 不互相覆蓋。listener.ora／DB data／listener service 屬特殊產品，不因同目錄就搬入。
5. **設定映射**：預覽舊→新 TNS_ADMIN、檔案路徑、registry view／key／value type、User SID、服務環境與 app 設定；同路徑無衝突可保留 bytes，變更只依核准項，不全域字串 replace、不搬整個 Oracle registry。Machine 值只在既有 MachineEnvironment 的無衝突／已持有範圍沿用；installer 已建立的同名值目前會被既有 restore 阻擋，必須走 C 的 Keep／External 或新受驗 UpdateReviewed，不能宣稱已有任意覆寫能力。User／registry 值納入 B2 受限用戶端設定契約（精確白名單、原值備份、readback、ownership／回復）或已完成且驗證的外部步驟。缺受驗 adapter 不顯示自動搬入；PATH 仍人工合併。
6. **機密**：wallet／cwallet.sso／ewallet.p12／私鑰／密碼／機器綁定材料走外部受控交付、目標重建或產品復原；不進一般 ZIP／Markdown／公開 repo。sqlnet／連線檔亦先分類。DPAPI 不假設跨機拷貝可解密，依[Microsoft DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)核對產品程序。
7. **目標驗證**：使用者先安裝 client／provider。離線驗檔案／ACL／hash／bitness／有效路徑／alias，再在明確允許的隔離測試，以真正 service account／IIS pool／task context 驗設定解析、必要網路／TCPS、DB 登入與 owner 最小查詢／交易。只靜態核對維持 NotTested。`tnsping` 僅驗 listener，不代表 DB、認證或業務成功，見[Oracle Testing Connections](https://docs.oracle.com/en/database/oracle/oracle-database/19/netag/testing-connections.html)。測試程式由 owner 批准於工具外執行，不執行包內任意腳本。
8. **啟用／回退**：env 變更後以新程序／受控 recycle 或必要 reboot 驗證，不假設現有程序立即讀到。provider 換版、alias／設定／目標漂移、wallet 未交付使受影響證據失效；只回復工具持有且未漂移設定，查所有共用 consumer 並保留新資料。

**B2 驗收**：無 TNS_ADMIN 的 fallback、Machine／User／服務／app 衝突、多 Home／32與64位、空／不存在／UNC、中文空白路徑、原始 encoding、IFILE／缺檔／循環、registry 型別、app override、wallet 外部材料、排除 DB 保留 client、共享設定及回復漂移。真實 Server 至少驗 fleet 相符的 Oracle consumer、實際帳號連線／業務及一次回復；fleet 有不同架構／provider 時不可互相冒充。無 Oracle lab 則維持未取得 Oracle 資格。

### C 補強：設定決策與真正執行身分

- 每列顯示 Apply／KeepTarget／External 的實際可用性、native API／權限、staging 副作用、restart／reboot、readback 與 rollback level；collector 未覆蓋只能 Unknown／External，不能因有清單標題就聲稱完整盤點。
- **既有目標處置矩陣**：CreateNew 僅建立不存在的物件；KeepTarget／VerifyExternal 只核對外部持有的有效設定，保留 CreatedByTool=false；不相容則 Blocked 或外部核准修正。新增 UpdateReviewed 僅限有精確設定白名單與資格的 adapter：核准 before／after、套用前再次比較 before、持久保存原值／型別／不存在或空值、套用後 readback；回退比較工具最後值未漂移後 RestorePriorValue。CreateNew 的回退才可 RemoveCreated。時區等全機已有設定亦須走此更新語義。安裝器建立的 service／task／IIS 不泛用自動接管，不把 VerifyExternal 當現有 restore 已支援；需新增不寫入的 consumer 契約或完成外部程序。
- Windows 全類選否只決定 OS 設定偏好；已入選 Oracle TNS_ADMIN 等業務相依仍需明確映射／驗證，拒絕搬入列阻擋 ItemId 與外部處置。
- 補 W32Time／時鐘同步、TLS／NTLM／SMB、long-path／filesystem 能力、reboot 後 GPO／安全政策有效值與服務帳號權利核對。2016→2025 的 TLS 1.0／1.1 預設停用、NTLMv1／SMTP 等移除依[Microsoft features 文件](https://learn.microsoft.com/en-us/windows-server/get-started/removed-deprecated-features-windows-server?tabs=ws25)列相容風險；不自動降安全基準。SMB 核對實際 client／server／有效政策，見[SMB signing](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-signing-overview)。

**C 補驗**：OS 全類選否仍顯示 required client 設定；時區／DST／catch-up／clock skew、user profile／IIS bitness、有效政策及 reboot 前後差異有 owner 結果，不能用管理員測試替代服務帳號。

### D 補強：完整 Markdown、使用者確認與決策回流

- 以 [ENVIRONMENT-SOFTWARE-CONFIRMATION.md](ENVIRONMENT-SOFTWARE-CONFIRMATION.md) 為格式契約，實際每台輸出 `environment-software-<PairId>-r<InventoryRevision>-d<DecisionRevision>-<DocumentId>.md`；DocumentId 每次產生新唯一值，另記 TargetObservationRevision、ReportProjectionHash、產生階段，fleet 索引引用確切版本。相同來源／決策下重查目標也不可覆寫舊檔。repo 空白模板不是實際清單，HTML 分頁／列印上限不能造成 Markdown 截斷。
- 文件涵蓋 metadata／有效期、coverage、全部軟體、runtime／driver／工具、Oracle／設定檔、Windows 決策、特殊／未知、人工補登、目標差異／驗證、阻擋、owner 確認與交接；每列能追 SoftwareId／PreparationId／ItemId／JSON evidence pointer，總數能對帳。
- Markdown 可註記但不是權威可執行輸入。直接改 `.md`／勾選不變更 gate；回填由管理端 wizard 或 validated CSV／JSON preview 錄入，綁 revision／hash、重新核准及產出文件。畫面／文件明确提示。
- 所有格式使用同一安全投影，escape 管線、換行、反引號、連結與 HTML；CSV 保留 formula 防護，不可信名稱不變成可執行內容／外部圖片。密碼／完整連線字串／wallet 永不輸出，內部路徑／endpoint 依分享分級，不能聲稱遮密碼即能公開。
- 新快照另存，列新增／修改／刪除／漂移；只保留未受影響且仍有效的人工決策，受影響 dependency closure 重新核准。舊文件標過期；不可因重跑清空全部決策或默認接受新增項。
- 預覽寫入／不搬／外部負責、consumer、缺什麼／誰補／下一步入口、可否接續、退出碼與報告位置；Ctrl+C／EOF／console 關閉／磁碟滿／權限不足不能當同意，重入依 journal reconciliation。

**D 補驗**：JSON 與 Markdown 每列／數量一致，排除／未知／manual／超過2,000列不漏；特殊字元無注入／機密外洩；勾選文件不放行、過期回填需 fresh preview。第一次操作者、值班接手、業務 owner、只看文件的審查人各走旅程；CLI／選單／API 不得繞同一 gate。

### D2：輸出目錄、資料夾／分卷 ZIP 交付方式

本節為使用者要求的續規劃建議；實作前依此確認行為契約，現有分卷核心不等於新操作旅程已交付。由 D 接線輸出／搬運／匯入，E1 接相容與負例，E2 驗實際空間及維護窗，E3 驗交換安全。

#### 選擇建議與現況

| 模式 | 操作與適用情況 | 取捨 |
|---|---|---|
| 分卷 ZIP（預設建議） | 指定目錄與每卷上限，工具產生多個ZIP＋權威transport索引；適合離線搬運／需限制單檔大小 | 單卷易核對／重傳；封存包與ZIP共存需要額外空間；全部卷核對後才可還原 |
| 封存資料夾 | 由已驗包產生白名單交付目錄，目標用可信manifest驗完整內容；適合受控本機磁碟或可靠搬運路徑 | 省去ZIP封裝時間；建立乾淨交付副本仍需計空間，散落檔較多易漏拷；完整metadata與整包驗證仍必要 |

- PackageTransport.ps1:11–35 已有 Export-WsmPackageZip：VolumeBytes 預設 536,870,912 bytes（512 MiB），API 接受 1 MiB–1 GiB；獨立ZIP、actual-size check、hash、checkpoint／transport索引已有。MigrationWizard.ps1:81 的來源步驟4只詢問輸出目錄，未讓使用者選每卷大小。
- PackageTransport.ps1:27 現用 NoCompression；ZIP 是封裝載體，不承諾容量縮小。沿用此模式以可預測空間與CPU／時間預估為主，本次不新增壓縮等級或自動安裝7-Zip。若後續要壓縮，需另驗compression-ratio安全上限／高可壓資料／實際維護窗，不可只改參數。[Microsoft CompressionLevel](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.compressionlevel?view=netframework-4.8.1)亦明列速度與壓縮效果的取捨。
- 現有輸出是每個可單獨讀取的ZIP中存metadata／payload chunks，再由工具重建；不先建超大ZIP再二進位切成 .z01，也不讓使用者手動串接／Explorer解壓當還原。單卷可讀不代表單卷可恢復完整來源檔案／ACL。
- **增量現況不同**：DeltaWorkflow.ps1:87–109 的 Export-WsmArtifactDeltaZip 是單一 OutputPath、沒有 VolumeBytes，並在系統 TEMP 串接 blobs.bin 後產生一個 ZIP。full 分卷核心不能證明 final delta 同樣受大小限制；新模式必須補 D2.4 的增量分卷與暫存契約。

#### D2.1：先指定目錄與明確預覽

**輸入／輸出**：角色／穩定主機登錄（配對前）或 PairId（配對後）／工具／核准scope → OutputProfile與空間預檢 → inventory／reports／package／transport分類輸出 → delivery索引／目標匯入。OutputProfile的模式／單卷上限是傳輸設定，不改動核准的資料scope。

1. 第一次操作先指定本機受控 WorkRoot，不寫死來源主機的磁碟代號。來源、管理端、目標各有自己的目錄與帳號可用性；十台以PairId區分，同名host不共用狀態。只設定工具新建子目錄的受控權限；既有根目錄／共享位置先核對，不遞迴重設使用者其他資料的ACL，無法取得安全隔離時阻擋並提示另選受控位置。
2. WorkRoot 先有穩定 `hosts/<EnrollmentId>/inventory/`，同一來源重盤點繼續使用既有 source-state.json 的 HostId／Revision；PairId 由管理端匯入後建立，配對前不要求先輸入它。配對後建立 `pairs/<PairId>/` 的持續 review／operation-state 與 `attempts/<AttemptId>/` 的 reports／packages／transport／scratch。AttemptId 是本次輸出嘗試，不取代既有 OperationState.RunId，也不能讓 initial／final／reboot 各自建一份空 ownership。實際 package 子目錄及傳給 Get-WsmOperationPaths 的 state 根仍沿用既有契約或受驗版本化映射；不同核准 plan 的狀態不能直接互用，處置見 D2.4。
3. reports直接放完整確認Markdown／安全HTML／TXT／CSV；原始inventory／catalog可能含機密，留受控子目錄，不代表可公開。state不放進搬運集合；外部安裝媒體／wallet／私鑰／密碼保留既有受控交付引用，不因「所有備份放目錄」就全部收包。
4. 分離檢查以各用途的實際子根為準：WorkRoot 僅是容器，可包含彼此分離的 package／transport／state 子目錄；不得把它整體視為可搬scope。各寫入／state／transport／incoming／backup 子根不得與來源scope、sealed package、目標還原scope產生物理重疊／reparse／junction逃逸；ZIP輸出在sealed package外，target解包與transport輸入分開。實際可讀寫、ACL、同volume鎖／rename、filesystem能力與free space通過才開始；不因路徑是UNC或mapped drive就假設資格，未驗證儲存介面須blocked或改本機暫存。
5. 目錄已有其他run、不同plan／package／format時新建run或明確選同包接續；不覆寫／清空使用者選的整個目錄，不使用來源host名稱作唯一鍵。不能選空字串、來源scope內或無權位置然後默認落到current directory。
6. 預覽列來源核准總量、排除／特殊／外部材料、WorkRoot／交付路徑、模式、單卷上限與確切bytes、預估卷數／容量／峰值free space、target解包／還原／rollback需求、權限与下一步。固定bytes是上限不是每卷恰好大小，少量資料可能只有1卷、最後一卷通常較小。

#### D2.2：每卷大小與可搬運集合

- 新旅程建議預設512 MiB，提供128／256／512／1024 MiB及128–1024 MiB內的整數自訂值，明列1 MiB=1,048,576 bytes。此為新UI／OutputProfile契約；保留舊API的1 MiB–1 GiB範圍及既有tiny-fixture，不靜默改舊參數。越界／0／負值／非數字／溢位／EOF阻擋或取消，不能取近似值冒充使用者選擇。
- 大小指**實際落地ZIP檔案上限**，包含header／central directory；以實際bytes驗後才seal。大來源檔由既有payload chunk機制分散到多卷，不限制原始業務檔小於每卷上限。單個不可分metadata超過卷預算時在預檢明確阻擋，告知可增大到支援上限或需metadata格式擴充；不突破大小、不截斷索引、不假裝已完成。
- 128MiB新旅程下限讓現有最大64MiB payload chunk保有header餘裕；不因縮小輸出卷而改已核准sealed包的ChunkBytes。變更卷大小只建立新transport run，沿用且重新驗證同一manifest；包的設定／scope／payload改變仍需既有重新核准規則。
- 每個generation有自己的transport與完整卷清單；示意命名沿用 `package-<PackageId>-0001.zip`。預檢卷數不得超過9,999：現有export使用四位minimum width，import只接受四位檔名；超界須在產生大量檔案前阻擋並提供調整卷大小／另行受控scope規劃的下一步，不能自行刪scope。
- 遷移ZIP交付最小集合是可信 `transport.json` 與清單中**全部**ZIP；清單逐卷列名稱／編號／Bytes／SHA256與PackageId／PairId／PlanHash／ManifestHash綁定，使用現有schema欄位與已驗映射，不強迫在ZIP內塞未受支援檔案。
- 外層另輸出 `delivery.md`、可機器核對的版本化delivery索引（規劃名稱 `delivery-index.json`）與其hash，說明搬哪些、卷數／總量、報告的位置／hash、可信transport入口、工具版本、世代／final／base相依、未完成項與還原下一步。外層文件不是package權威，不可以覆蓋transport／manifest或自行新增可執行腳本；reports可與package分級分享。
- 實際import所需的transport hash由獨立可信管道提供；同目錄的 `.sha256` 只協助核對，不證明作者與信任來源。收到全部文件不等於驗證完成，資料夾模式以可信manifest重新驗全payload／metadata。
- initial與final保留既有 delta 的 base/current 綁定；新旅程的每卷上限必須由新增增量分卷 producer／consumer 共同履行，不能把舊單 ZIP 當已符合，也不能交給 full importer。完整差異集合及可信 base 不可漏搬。既有卷補傳保持同一 sealed transport hash；重新封裝走新 transport，細節見 D2.4。

#### D2.3：容量、可接續與真正還原

- 不估計壓縮節省；來源同磁碟需同時容納 sealed package、資料夾交付副本或全部 ZIP、正在寫的 partial、delta blob／排序 spool、reports／indexes、原始狀態與安全餘量，分磁碟逐 volume 檢查；新 scratch 路徑明確受控，不能漏算系統 TEMP。target需含輸入卷（若同volume）、incoming重建package、staging還原、既有target／backup／保留新資料及餘量；不是只用來源檔案總大小乘固定係數。原package estimate與ZIP逐卷檢查不足以證明新整體目錄容量已驗。
- 完成狀態分 `Prepared`／`Exporting`／`Sealed`／`TransferredUnverified`／`ImportedVerified`／`RestoredVerified`；這是delivery／輸出層狀態，不重命名既有operation journal狀態。全部卷與transport seal前不標可搬運完成，import驗證不能自動觸發restore／activation。
- 取消／磁碟滿／程序中斷保留已驗sealed包／卷與checkpoint，`.partial`不進交付集合。相同manifest／格式／卷上限接續前重驗已完成卷hash；不從零覆寫、不把傳输續跑宣稱直接從壓縮串流中段接續，單卷未完成可重新建該卷。
- 已完成卷缺檔／被修改時依現有reconcile阻擋，不刪掉checkpoint裝作正常。缺卷／錯卷／重複entry／額外未知內容／改transport／wrong pair／generation／path traversal／高壓縮比／解壓額度／hash mismatch均拒絕變成可還原包；先預檢完整卷集合才解包，途中失敗只能留下受控incoming，不落業務target。
- 原始packaging與transport不是enterprise完整備份。回退仍依ownership／保留target／backup／新交易對帳，不能刪除ZIP就以為已完成資料回退。清理由明確預覽後按本run工具持有範圍進行；保存期限／退役／備份復原證據未滿足，不自動刪來源package或target backup。
- 遷移資料及原始盤點含敏感資訊，工作根目錄用受控ACL儲存；FAT／exFAT不能假裝具NTFS ACL。可搬運的ZIP承載payload bytes與權威ACL metadata，但輸出磁碟／媒體仍需企業驗證的加密保管與存取控制，本工具不自動加ZIP密碼。[Microsoft filesystem比較](https://learn.microsoft.com/windows/win32/fileio/filesystem-functionality-comparison)列出filesystem差異。若加密wrapper增加檔案大小，另預檢外層媒體上限，不承諾指定ZIP上限也涵蓋外部wrapper。

#### D2.4：反向複審後的必要閉環

以下契約新增，名稱屬規劃；現有 API／schema 不因文件寫入就具備能力。

1. **穩定狀態與復原（R2-21）**：source enrollment／HostId／inventory revision、管理端 catalog／approval、目標 PairId／PlanHash／ownership／journal 持續保存；清理輸出 attempt 不清除這些權威狀態。改 WorkRoot 須明確遷移受控狀態、核對主機 fingerprint／鎖／journal 一致性與原核准綁定，不能靠複製來源 state 讓目標取得 ownership。狀態遺失或不一致先 Blocked／RepairOperation／由既有持有紀錄核對，不以新建空 state「修復」。同 plan 初始、final、重啟、取消接續仍使用同一作業狀態；新 plan 另建受控作業映射，先處理舊作業 ownership／回退與衝突，不能新建目錄後略過既有物件。本機 state 有受控備份／恢復／保存責任人；它不進一般搬運集合。
2. **增量同一大小承諾（R2-22）**：新增版本化 delta-volume 索引與分卷 exporter／importer；保留 ArtifactDelta 的 base/current／plan／changes／records／hash 語義，以有 hash／長度／順序的 bounded blob segments 避免單一 blobs.bin 必須小於卷上限。索引明確 full 或 delta kind、格式版本、完整集合與可信 base；先驗全集再重建／既有 delta validation，不能使用 full importer 假裝支援。舊單 ZIP delta 保留舊入口與限制，新設定超界不得靜默回退成超大 ZIP。scratch／sort spool／segment／partial／incoming 都用經分離與容量檢查的受控路徑；旧 API 如保留 TEMP 行為，須列實際位置／限制，不繞新模式的預檢。
3. **資料夾交付精確集合（R2-23）**：用 Get-WsmPackageMembers 的既有白名單語義建立乾淨 delivery package（manifest／plan／artifacts／必要 freeze／被引用 payload）；不可整目錄直接交付，原包含 export-state.json。source-state、export／transport checkpoint、journal、raw inventory、孤兒 payload／額外檔均不傳。清潔副本採新建受控目錄、逐項 bytes／hash／集合對帳、seal 後唯讀保管並在目標重新核對；不假定所有本機硬連結可作獨立副本。資料夾模式也適用 full／delta 明確型別與完整 base 相依；未知額外成員拒絕或留在非交付隔離區，不偷偷收進授權 scope。
4. **既有設定與 gate 順序（R2-24、R2-25）**：C 的 action／ownership／rollback 矩陣和 B1 的 RequiredPhase 是所有 CLI／wizard／Fleet／LabReport／restore／activation 的共同契約。診斷階段只允許明確核准的隔離測試路徑／帳號／外部測試程序，業務 writer 仍隔離；不能為取得 CutoverReady 先做完整 production activation。最終包還原後重查變更的有效設定與 consumer；仍有效的證據以受驗投影重新關聯，不因報告重產而全部失效。
5. **不可覆寫的文件與交付版本（R2-26）**：DocumentId／TargetObservationRevision／ReportProjectionHash 區分同一 r／d 下的不同目標結果；latest 索引只是定位提示。每個 DeliveryId 引用固定 report hash、transport hash、manifest／base；seal 後不改這份索引或內層包。匯入／還原進度另產 execution receipt／新報告；後續註記或新交付版本不改舊報告、不回寫 manifest／plan、不因純報告重產強迫 payload 重封裝。
6. **補傳與重建區別（R2-27）**：封存卷仍完整時只補傳原卷，保持原 hash。原卷缺失／損壞時，保留失敗 checkpoint 與原因，重新驗來源 sealed package，在新 TransportAttemptId／DeliveryId 下重封裝、重產可信索引與 hash，舊交付標不可完成；來源包也毀損則停止並依來源凍結／重新封存流程處置。PackageTransport 用 CreateEntry 未固定 timestamp；[Microsoft LastWriteTime](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.ziparchiveentry.lastwritetime?view=net-9.0)說明其預設為建立時間，因此不能承諾重建卷仍有舊 hash。目標按新可信索引用獨立 incoming 核對，不將兩次 transport 的 partial 混合；相同且重新驗證的 manifest 不因只換封裝就自動重新核准資料 scope。
7. **可量測規模與 schema（R2-28）**：9,999 卷只是檔名界線，另預檢 JSON UTF-8 bytes、成員／index 數、單筆／總 spool、記憶體、來源／目標磁碟與維護窗。現有 Read／Write-WsmJson 上限 128 MiB，envelope 只接受 SchemaVersion=1；新增欄位／格式須有明確版本協商／受驗讀寫路徑與完整 consumer 更新，不只改版本數字。超限回報哪個 index、所需／允許容量、保留狀態與下一步，不截斷確認清單、不漏資料也不自行拆 scope。超過現有界線的分段索引／串流支援另列必要實作和資格；未完成時明列不支援，而不是提高數量宣稱已達企業規模。

#### D2 驗收與整體影響

- 同一小型核准案例走資料夾／ZIP及來源選單／CLI／API；512MiB默認／自訂值確切傳入、報告可讀、全volume／entry／scope數量對帳，包身份一致，目標最終bytes／metadata／gate一致，不要求產生填滿1GiB的fixture。
- 最小資料驗卷邊界、header計入、最後一卷、來源檔大於單卷、不可分metadata超界、0／負值／單位／overflow／EOF；卷數10,000的合成metadata在預檢拒絕，不真的寫一萬ZIP。現有>4GiB有效實測在payload未改時沿用。
- 缺最後一卷、錯／改卷、不同generation混入、同包新卷大小、partial／中斷接續、可重傳集合、路徑重疊／junction、ACL／readonly／磁碟滿、加密wrapper及新舊schema相容做對應負例。舊ZIP API的1MiB測試保留，不為新UI下限破壞回歸。
- snapshot與source停寫／final規則不因輸出選項改變；Oracle檔依精確ConfigFiles入包、wallet外部；軟體確認Markdown直接可讀但不成可執行核准；target解包驗證後仍先staging再cutover。Fleet顯示每台輸出mode／generation／大小／卷數／hash／交付／匯入狀態，不將某台或某卷PASS算全機搬移完成。
- 真實來源／目標做一次具代表性的封裝／搬運／解包容量與維護窗量測，硬體／媒體／安全政策資格記在exact環境；本次只有文件續規劃，不能宣告D2已實作或取得正式資格。
- 反向旅程至少驗：首次無 PairId 盤點→同 host 重盤點身分不變→配對→初始還原→重啟／取消→final 接續；state 遺失／移動／wrong plan 阻擋；full／delta 同上限與 wrong kind 拒絕；資料夾少／多成員与 checkpoint 不入包；既有 TNS_ADMIN Keep／更新／漂移回退；gate 無循環且無關決策不清掉有效準備；同 r／d 重產文件不覆寫；重封 ZIP 用新 hash；JSON／index／memory 超界在未 seal 前明確失敗。只用小資料與合成 metadata 驗契約，實機容量／帳號驗收另列。

### E1：相容與跨段完整性

- 相容回歸涵蓋舊 inventory／包／schema／plan／delta／approval／journal／ownership／ToolFingerprint，B 的型別相依不能繞過旧 Mandatory gate。執行中 pair 維持原版或明確協調重建，禁止熱換。
- 準備 → 設定映射 → 審核 → 核准 → 包 → staging → readback → final → activate → fleet／LabReport → rollback／retirement，每個 producer 的新增資料都有 consumer；縮減報告不能當完整 gate 輸入。
- 新增 source enrollment／OutputProfile、typed dependency／RequiredPhase、UpdateReviewed、DocumentId／delivery、delta-volume 必須逐一列出 producer、schema validator、preview／approval、匯入／執行、報告／Fleet／LabReport、恢復 consumer。B1→B2／C→D／D2→E1→E2→E3 是相依順序；D2 必須等新 delta 與狀態 consumer 完整，不可只接 UI 先宣稱可交付。新 plan hash 不能直接重用舊 operation state；純 transport／報告變更不改核准 scope。設定／需求漂移需重新核准並建立可驗新 baseline，final delta 不能繞過原 plan 綁定。
- 批次內完整子段按適当驗證 commit／push，核對遠端 SHA；文件修改只查引用／契約／Markdown／diff，不假造新增程式測試通過。固定 snapshot／hash、同環境有效證據沿用，不重跑無門檻大型全劇本。

### E2：資料一致性、切換、故障復原與退役

- 記 source EOS 官方來源／查詢日／時區、owner、維護窗、RPO／RTO、最大中斷、備份復原點／實際復原演練。官方日期不一致時記兩者，先採較早期限排程並由管理者確認；不硬編碼或假定 ESU。[Server release information](https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info)與[Server 2016 lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2016)供查證。
- 分靜態／可停寫業務檔／open files／DB／queue／共享狀態；無 writer-aware 一致性程序不可 generic 拷貝。VSS 不保證任意產品一致性，也不擴充特殊產品搬移。final 前重查 source hash／所有 writers quiescence。
- 包、暫存、解壓、現存 target、backup／rollback 保留資料的峰值空間與最慢傳輸階段入維護窗，代表 workload 量測一次。保留 ADS／ACL／SID／reparse／EFS／sparse／hardlink／long-path 已有支援或阻擋邊界；未讀檔／read error 顯示不完整，不當排除。刪除需精確批准，不刪未持有資料。
- 切換前核對管理 console／回復通道、source fencing／target isolation、DNS／TTL／cache／PTR、SPN／delegation／duplicate SPN、AD／gMSA 權限、DHCP reservation／LB／allowlist、備份／監控／資安 agent 及 owner。不允許同名／同 IP／同負載雙寫；無法證明 fencing 就 blocked。
- 名稱／IP／domain 身分與 reboot 後重查 target identity／effective GPO／required runtime／設定／憑證 ACL／外部相依，保留核准的 bootstrap→cutover identity 關聯，不接受任意複製 fingerprint 的主機。
- 排程驗 DST／時區／catch-up／事件與開機 trigger／身分／工作目錄；服務 recovery／trigger／IIS 安裝副作用不能使 staging 提前上線。隔離測試不得重複寄信／扣款／queue 消費，owner 指定測試交易與清理。
- 業務驗收含 DB identity／service／schema、TLS／hostname、實際 read／write 權限、中文／code page／時區、外部 consumer／新 source IP allowlist、錯誤率／延遲，不僅 Running／HTTP 200／listener 可達。
- 回退分未開新交易與已可能有新交易；後者停止所有相關 writers、保存最新 target、對帳／產品同步及 owner 批准後才接回來源。沿用 Recovery.ps1:47、53 的 NewTransactionsPossible／RollbackReconcile gate；文字勾選不證明反向資料同步完成，來源不自動啟動。
- 退役需觀察期（含最長週期任務或有證據的人工演練）、backup restore／監控接手、外部 consumer 舊路徑流量、特殊產品處置、資料保存期限、帳號／憑證／CMDB／DNS／授權交接。明列可回退期限／不可回退時間點／刪除責任；一般 scope PASS 不等於 RetirementReady。
- 十台依相依圖分波次，共用 TNS／DB／UNC 變更列全部 consumer，循環群組沿用 barrier；局部試搬不解除群組切換 gate。一台失敗的停波／繼續條件由 wave owner 明列。

**E2 補驗**：source freeze 漂移／漏外部 writer、磁碟滿、程序中斷／斷電、reboot policy／identity 改變、部分 activation、已有新交易回退、共享相依失效／群組阻擋及退役長週期任務；真實 Server／產品停寫及復原演練，fixtures 不替代。實際 workload 符合維護窗／RPO／RTO 才標該範圍合格。

### E3：正式資格與發行／企業放行包

| Gate | 必要證據 | 不得當作成功的代用品 |
|---|---|---|
| ReviewComplete | 完整環境／coverage／Oracle／Windows／特殊處置、owner、相依閉合 | 已讀／排除／Markdown 勾選 |
| PreparationReady | 本階段 exact target／runtime／版本／架構／帳號、隔離安裝後核對、所需外部材料、restart 完成 | 別台 ready／installer exit 0／要求尚未還原的檔案先通過 |
| RestoreReady | PreparationReady＋新核准 plan／manifest／scope／空間／相容、目標衝突已處置 | 舊 installer 契約繞過新模式禁止安裝 |
| StagedVerified／StagedDependencyVerified | 本次包／設定／檔案／ACL readback，按 RequiredPhase 驗 effective TNS／帳號／共用 consumer | 僅套用命令成功／未查有效設定 |
| CutoverReady | final 一致性／fencing／外部 receipt、最終設定下實際 consumer 的受控業務測試 | 先全量啟用 writer 才能取得測試證據／HTTP 200／tnsping |
| FinalAccepted | 切換後業務／監控／觀察與外部 owner 接受 | fixture／省略 TXT 摘要／只在切換前測試 |
| RetirementReady | 新資料回退、觀察／backup restore、特殊外部流程及退役批准 | 一般 scope 完成 |
| ProductionQualified | exact tool／adapter／OS build／edition／installation type／product／provider／architecture 的 ServerLab、IsolatedPilot、ProductionAcceptance，加企業信任／發行證據 | report／自填 reference／hash 自我授權 |

- Qualification.ps1 的既有 exact tuple／expiry／revocation 保留；補 InstallationType 與 Oracle provider／consumer 等維度的相容 schema／qualified scope，未知 tuple 不泛化。owner／hash 不證明獨立授權，正式 registry 必須有企業信任根／獨立審查與過期／revocation 執行門檻。
- 必交 release manifest、release notes、依賴／SBOM 清單、支援／不支援矩陣、已知限制、簽章信任方式、權限／FullLanguage 要求、復原 runbook、離線診斷／機密清理／保存期限與企業變更核准。外部簽章／加密工具可沿用，但需 target 實證與責任人，不能只有 README 提醒。
- hash 清單、程式簽章、材料簽章、執行核准用途分開；hash 不證明作者。簽章後先產最終 bytes fingerprint，再建 plan／qualification；不能沿用未簽版核准，執行中仍不熱換。
- 整體回查可信來源／完整性／加密保管／ACL、entry／解壓大小／compression ratio／disk quota、防 traversal／reparse／overlap、lock／交易寫入／atomic rename／失敗材料保留。已存在契約沿用、缺口補負例，不預設全須重寫。
- **本輪不直接開生產執行開關**。E1→E2→E3 均列必要工作；缺實際 Server／Oracle／企業材料維持 NotTested／Blocked。E3 完成後仍須使用者／企業明確授權與可驗 gate 實作、安全審核才另段啟用，qualification 記錄不是開關。此為授權界限，不免除產出正式資格／放行包。

**E3 補驗**：未簽／不可信／過期／revoked／wrong tuple 的材料拒絕放行；簽署後 bytes 與 plan／qualification 不一致阻擋；該 OS／provider 真實資格缺口仍可在 fleet／LabReport／Markdown 查到。

### 整體複檢與本次執行紀錄

#### 實作啟動（2026-10-09）

- 起點：codex/implementation，c72f65b7f127f4c045124fab72aa85d191195a48；既有未追蹤 prototype 保持不動。使用者授權本輪 A–E 全部實作；實際 Server／Oracle／企業材料仍由外部受控環境提供，缺證據保留 NotTested。
- 子代理只使用 gpt-6-luna，主模型按風險選 low／medium／high。A0 分類與盤點接線委派 high；A1 相依接線調查委派 medium（只讀）。主代理直接核對產物、consumer、負例與固定快照測試；不以代理摘要或局部 PASS 當整輪完成。
- 各完整子段驗證後 commit／push 並確認遠端 SHA；停止前依本表及原始條目／補強契約逐項回查，未實作繼續補，不移走原需求。下表只作追蹤，不取代每批子項。

| 段落 | 本輪必要交付／對照 | 狀態／實作與驗證證據 |
|---|---|---|
| A0 | 物件分類、Oracle engine／client界線、混合主機及完整評估投影 | 已實作／本機fixture驗證；ScopeClassification、Inventory／Core、選單23／CLI ScopeAssessment；7腳本在5.1／7各7/7，最後wrong-kind修正各2/2。非產品完整識別／實機資格 |
| A1 | 受審處置／override、Preparation／ExternalDependency型別、必要相依全consumer | 未完成 |
| B1 | HKLM／HKU／portable／人工全軟體、runtime／driver／context、準備／媒體／投影證據 | 未完成 |
| B2 | 版本化Oracle有效設定、精確ConfigFiles／IFILE、目標readback／外部consumer證據 | 未完成 |
| C | OS清單／選否、逐項決策、Create／Keep／External／UpdateReviewed／時區prior回復 | 未完成 |
| D | 全量安全Markdown與其他報告、DocumentId、回填／gate、CLI／選單／Fleet／LabReport | 未完成 |
| D2 | stable enrollment／state、OutputProfile、白名單資料夾、full／delta分卷、scratch／容量／交付 | 未完成 |
| E1 | 新舊格式／schema／approval／journal／ownership與完整跨段相容 | 未完成 |
| E2 | 一致性／fencing／名稱IP／回退新資料／退役／實機RPO與RTO證據閉環 | 未完成；尚無本輪Server／Oracle實機證據 |
| E3 | exact資格、發行／SBOM／企業信任／安全交換／正式放行包 | 未完成；未提供企業簽章／批准材料，生產開關維持關閉 |

- A0 實作者：scope_classification（gpt-6-luna high）；主代理整合 Core／CLI／CI、UTF-8 測試讀取及 wrong-kind微修。獨立核對 mixed IIS／SQL、Oracle engine／listener／client／ODAC、字典→JSON→catalog、localized role ID、偽造／額外欄位／重排欄位／Int64版本、未解析相依、legacy投影與不修改決策。
- A0 驗證：固定快照 `wsm-r2-a0-verified-895774a630b54f83b861db6eb9ac5261` 的 ScopeClassification／InventoryFixture／Contracts／AdvancedReview／EntryPoint／EnterpriseDiscovery／MenuContracts，WinPS5.1與PS7各7/7。第一次5.1 InventoryFixture的ANSI讀UTF-8失敗已在獨立快照重現並修正。最後只加wrong-kind拒絕，於新快照 `wsm-r2-a0-final-2b0ff1777203476d9fbc4a9d2bdfb0f8` 重验受影響 ScopeClassification／EntryPoint，各2/2；runtime hashes前後不變且與A0工作樹檔案相符。未改payload，不重跑>4GiB；全輪回歸／Server／Oracle／企業资格仍未完成。
- 接續：B1完整軟體capture委派software_capture（gpt-6-luna high）；只寫独立collector與fixture，主代理再接入來源／匯入／CLI。A1受審處置與typed gates需使用其明確軟體身分，仍未完成。

#### 實作前規劃複審記錄（截至c72f65b）

- [複審 R2-01–R2-20](MIGRATION-2-REVIEW.md)逐條落於 A／B1／B2／C／D／E1–E3，需求／交付物／相依／驗收不從待辦偷刪。OS 全類選否不繞過業務相依、Markdown 非可執行輸入、準備證據不與核准 plan 循環。
- 第二次按初次／熟練／應用／值班／管理／稽核旅程反查，另納入 R2-21–R2-28 的狀態、增量、白名單資料夾、既有目標、分階段證據、報告版本、損壞重建與規模限制。結論是規劃補足必要契約；是否正確運作仍待相依完整實作與各層證據，不宣稱重新閱讀文件就取得資格。
- 原一般主機／離線／人工安裝／特殊產品不搬／OS 逐項設定保留。Oracle client 設定與完整軟體 Markdown 是本次必要補入；Oracle DB 不新增自動還原。
- 本次修改限規劃、複審、確認模板與入口，未修改 src／tests／入口程式，未執行來源／目標 Server 盤點、Oracle DB 連線或生產遷移。功能／實機／正式資格保持未完成。
