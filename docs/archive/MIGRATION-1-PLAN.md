# Windows Server Migration 第 1 輪規劃

> 歷史封存（2026-10-10）：以下狀態保留當時紀錄，不作當期待辦。現況及第 3 輪入口見 [封存索引](README.md)。

> 狀態：實作中。2026-10-08 使用者授權開始實作；依序實作 A/B/C，取得真實盤點確認後展開 D/E/F。
> 日期：2026-10-07（Asia/Taipei）。
> 複審版本：R2。規劃契約仍有效；第一階段部分功能已實作，完整缺口與驗證見 [IMPLEMENTATION-0.1.md](../IMPLEMENTATION-0.1.md)。
> 歷史規劃基準：當時僅有 `Get-ServerMigrationInventory.ps1`，尚未建立 Git 工作樹；實作基準見下列執行方式。
> 腳本 SHA-256：`CECEA767FCA8D7CC2C044B9F4B3F3588584259B13A1439FCFE88E2949CCB38B5`。
> 既有驗證：先前 PowerShell 語法檢查及合成檔案 ZIP 雜湊測試通過；未進行 Server 實機驗證。
> 來源：使用者要求選單式操作、擴充企業服務盤點、分類確認文件、可排除項目、大量項目 UX、約十台主機處理。
> 執行方式：主代理實作與本機驗證；不操作尚未指定的實際伺服器。基準提交 d67d5c8，工作分支 codex/implementation。

## 目標、已確認事實與待確認事項

### 已確認

- 程式碼位於 `C:\Users\eldar\Claude\Project\windows-server-migration`。
- 主要遷移方向為 Windows Server 2016 → 2025，不排除其他來源版本。
- 目標機初期與來源機使用不同名稱、IP；搬移及驗證後才改回原名稱與 IP。
- 使用者要確認所有項目，依類別條列，能選擇排除；主機數量接近十台。
- 已選定各台本機執行，集中彙整進度與報告；第一版不要求 WinRM。
- 規劃階段使用者要求先規劃；2026-10-08 已授權開始實作，尚未指定實際伺服器操作。

### 規劃預設（依使用者授權開始實作；環境特有資訊仍待盤點）

- 使用 PowerShell 主控台文字選單，所有功能另有非互動參數入口；報告用可離線開啟的 HTML 與 UTF-8 CSV。
- 已確認的本機執行模式：各台結果匯入同一批次工作區集中彙整；集中彙總不直接遠端控制主機。
- Windows PowerShell 5.1／64 位元為主要執行基線，2016 與 2025 作為首批實機驗收組合。
- 未知版本先做能力探測；缺工具只記待處理，不在舊主機自動安裝或升級。
- 所有探索項目初始為「待確認」。提供分類建議、應用程式組合與批次審核，避免逐筆點選。
- Windows 內建項目也出現在完整報告；預設畫面可折疊，不能靜默略過。
- 每一對來源／目標獨立一個搬移包、執行紀錄及結果；集中管理十台進度，不混用主機包。
- 名稱／IP 接手先做獨立切換計畫與檢查，不與一般還原綁在一起；正式切換仍由使用者在維護時段明確執行。

### 尚需實際盤點

- 每台的 OS／PowerShell／IIS 版本、更新修補、磁碟、資料量、網域及服務清單。
- 來源／目標的網域、磁碟代號與路徑是否一致；若不同，需要逐項映射。
- 應用程式負責人、可停機時間、RPO／RTO、資料寫入與外部相依。
- SQL／AD／DNS／DHCP／CA／叢集等角色是否存在；每個角色對 2025 的支援與遷移方法。
- 管理端接收離線結果的方式、工作區權限與報告交換位置；是否能使用共享儲存尚待確認。

## 現況與核對證據

以下行號以本輪基準腳本為準。

以下是 0.1 原型的歷史基線，保留原始問題與驗收理由；不是現行 0.3 的功能清單。最新狀態見 [實作核對表](../IMPLEMENTATION-0.1.md)。

| 需求或問題 | 實際證據 | 結論 |
|---|---|---|
| 選單式操作 | 第 3–4 行僅提供 OutputRoot；第 39 行起直接逐段 Collect | 未實作互動選單或獨立階段入口 |
| 可檢查單一搬移項目 | 第 20–36 行 Record／Collect 只追蹤收集區段 | 缺穩定 ItemId、相依與逐項狀態 |
| 分類確認文件 | 第 28–30 行輸出原始 CLIXML／文字；第 145 行起為固定 READ-ME | 缺可供審核的分類項目報告 |
| 可排除項目 | 第 39–143 行無選取政策或清單讀取 | 尚無排除、批次審核或重新盤點後決策保留 |
| 網站／排程／服務的實際資料 | 排程第 75–102 行僅 XML，IIS 第 104–116 行僅設定，服務第 59–73 行僅定義 | 參照腳本、執行檔、站台檔案及 ACL 尚未匯出 |
| 大量項目效率 | 第 177 行起遍歷全部匯出檔案計算雜湊，第 193 行再壓縮，後續又讀 ZIP 驗雜湊 | 已有基本完整性檢查，缺進度、空間估算、限流、續跑與大型資料策略 |
| ZIP 完整性 | 第 179–188 行先雜湊，後產生兩份索引；ZIP 驗證只遍歷 hashRows | 索引本身未進入這份雜湊覆蓋，不能當成完整包信任驗證 |
| 收集狀態可信度 | 子項可能 Record Failed，但 Collect 仍可記上層 Collected；不存在的 ODBC 等也可能記 Failed | 需要逐項及父層彙總，區分缺漏、部分成功、未安裝、權限不足、查詢失敗 |
| 十台主機管理 | 輸出名稱使用 hostname、時間與 GUID；無批次索引 | 可避免部分輸出碰撞，但沒有來源／目標配對與跨主機相依 |
| 還原及驗證 | 全腳本沒有還原入口 | 尚未實作；查詢／壓縮成功不能作為遷移成功 |
| 腳本結果與可自動化判斷 | 第 210–216 行 ZIP 失敗只警告，沒有 Record ZIP Failed 或明確 exit；第 188 行已先輸出狀態 | ZIP 失敗未納入最終 CollectionStatus，外部不能只依正常結束判斷成功 |
| 原生指令／方法的成功判定 | 第 36 行統一要求 native exit=0；第 136 行直接保存 GetSecurityDescriptor() 結果 | 未建立工具別成功碼及 WMI ReturnValue 判定；未來不得直接沿用到搬檔/安裝/還原 |

`appcmd` 對各 object 的參數、共享設定來源及繼承設定仍須實機驗證，本輪不假定現有匯出已完整。

## 本輪範圍與成功定義

工具需讓使用者依序完成：選主機 → 前置檢查 → 探索 → 分類審核與排除 → 解決相依及映射 → 匯出 → 目標預檢／預覽 → 還原 → 切換前驗證 → 正式切換 → 切換後驗證。

「完整」指所有已探索到的項目都有明確處置與證據；未知項目不能宣稱不存在。主機內查詢無法證明所有外部消費者或少量執行的工作都已發現，需保留人工補列入口、服務負責人確認、代表性觀察期間與業務測試。

「精準還原」以核準清單的預期目標狀態為準：內容、設定、映射後權限及功能均符合。跨版本合法差異要明列；不以整台新 OS 與舊 OS 的登錄／設定完全相同為目標。

只有標示「自動還原已支援」且實機驗證的模組可自動執行。偵測到的專用角色、第三方產品或未知服務，必須列為專用流程／阻擋／待確認；選取後沒有實作的還原與驗證，不可標完成或自動改成排除。

## 企業服務盤點分類與補漏清單

下表是待實作的檢查範圍；代表每台都要檢查是否存在，不代表本輪已確定全部要搬或已有通用還原方法。

| 類別 | 需盤點／補查 | 匯出與還原策略、驗收要點 |
|---|---|---|
| 系統與角色 | OS/build、更新、Server roles/features、時區/時間同步、語系、編碼、必要安全設定 | 建立 2025 相容性前置清單；只搬必要且支援的設定，不整包覆寫安全基線 |
| IIS／Web／FTP | 站台/AppPool/app/vdir、綁定/SNI、認證/授權、模組、handlers、URL Rewrite/ARR、ISAPI/CGI、32bit、MIME、request limits、recycle/idle、共享設定、FTP | 匯出有效與繼承設定、所有實體/UNC 路徑和 web.config；元件須有安裝來源；用 Host header/SNI 導向新機測試，含登入、上傳、背景功能 |
| 排程／批次 | 全部 task folders、XML、ACL、principal/logon、trigger、actions/arguments/workdir、COM handlers、隱藏/停用任務、schtasks/at 遺留、登入/開機腳本 | 解析腳本與參照資料；相對路徑、網路磁碟、巢狀腳本及動態路徑標待查；還原先停用避免雙跑，經授權的測試檢查實際業務結果 |
| Windows 服務／背景程序 | ImagePath、wrapper/NSSM、帳號、相依服務、delayed start、failure actions、trigger、SID type、權限、環境及 config/log/data 路徑 | 第三方服務先確認安裝與產品支援，不直接搬整份 Services registry；驗程序啟動、埠、日誌及業務輸出；必要啟動可測試但避免重複生產消費 |
| 程式與執行環境 | .NET／Hosting Bundle、VC++ runtimes、Java、PHP、Python/Node、PowerShell modules、GAC、PATH、machine.config、drivers、32/64bit provider、COM／DCOM／COM+、授權 | 盤出版本、位元與相依；使用安裝媒體／產品匯出機制；驅動與硬體綁定元件優先重新部署；未知授權缺口要阻擋 |
| 資料與檔案儲存 | 應用資料、ProgramData、執行帳號 profile/AppData、NTFS owner/DACL/SACL、分享權限、ADS、EFS、junction/symlink、長路徑、壓縮、DFS namespace/replication、FSRM、quota、dedup、disk/mount、BitLocker 復原需求、SAN/iSCSI | 可自動搬的資料需明確根目錄和路徑映射；ACL/SID 映射、重解析點與 EFS 分開處理；不掃整磁碟就複製全部；超大檔案用獨立可續傳 payload |
| 帳號與身分 | 本機帳號/群組與成員、SID、domain account、gMSA、user rights、SPN、Kerberos delegation、電腦帳號/OU/GPO、IIS virtual identity | 本機同名帳號 SID 不必然相同；名稱切回也不代表原電腦帳號／SPN 正確；按帳號映射及網域流程驗 ACL、服務登入與網域認證 |
| 憑證、金鑰與機密 | store/thumbprint/private key、key ACL、PFX 可匯出性、IIS RSA key、ASP.NET machineKey/Data Protection、DPAPI、EFS、TLS/SChannel、服務／排程／應用機密 | 一般報告遮罩；PFX/機密保護另定安全存取策略；不能匯出私鑰或機器綁定加密須重簽/重新輸入/專用遷移，不把複製檔案當成功 |
| 資料庫與資料存取 | SQL instances、版本/build、DB、backup、TDE 憑證與加密金鑰、master key、logins/SID、SQL Agent jobs/schedules/operators、linked servers/credentials/proxies、SSIS/SSRS、replication/CDC/AG、aliases、ODBC DSN/provider、其他 DB | 實際 DB 與版本以產品專用遷移及一致性機制處理；資料庫備份、驗證還原與 DB 外的工作/登入均要納管，不複製使用中的 MDF/LDF |
| 網路與主機端點 | IP/DNS/gateway/routes、NIC team/VLAN、hosts、proxy/WinHTTP、firewall、HTTP.sys SSL/URLACL、IIS/服務 ports、SMB protocol 相依 | 暫用 IP 與最終 IP 分開映射；不把舊 NIC GUID 或整份防火牆原封匯入；驗目標端點並比對允許的差異 |
| Windows 專用服務角色 | AD DS、DNS/DHCP、AD CS、NPS/RADIUS、RRAS/VPN、RDS/Licensing、Print、WSUS、WDS、Hyper-V、Failover Cluster、NLB、MSMQ、SMTP、DTC | 每角色偵測存在與範圍，生成專用流程及能力狀態；AD/DC/CA/叢集不使用通用改名或全量 registry 還原；queue 與交易資料需一致性處理 |
| 外部與營運相依 | 外部 DB/UNC/API、SMTP relay、load balancer/reverse proxy、DNS A/CNAME/PTR、NAT/外部防火牆/allowlist、SSO、監控/備份/EDR/AV/管理代理、授權伺服器、服務消費者 | 以設定及程序/連線觀察產生候選相依，註明推斷與觀察時間；每項記負責人、變更單、驗證；代理通常重新佈署避免裝置 ID 重複 |

附加檢查：服務實際讀寫的登錄與資料目錄、永續 WMI event subscription、自啟動登錄及 Startup 資料夾、DB／message queue 排程、監控所觸發腳本、dump/temp/rotation、應用內排程與只有月結／季結才執行的工作。日誌／快取／暫存不預設全部搬移，使用者仍需確認處置。

Server 2025 特別風險：SMTP Server、NTLMv1、Windows PowerShell 2.0 等已移除，不能只要求安裝同名角色。對 VBScript/WMIC、舊 TLS／SMB、第三方版本相容性逐項檢查，偵測到依賴就列阻擋或替代方案。[Microsoft 移除與停止開發功能](https://learn.microsoft.com/en-us/windows-server/get-started/removed-deprecated-features-windows-server?tabs=ws25)

IIS 共享設定中的部分金鑰具機器相依性，因此只有 applicationHost.config 不足以涵蓋所有密碼還原。[Microsoft IIS 共享設定](https://learn.microsoft.com/en-us/iis/manage/managing-your-configuration-settings/shared-configuration_264)

檔案伺服器的多主機資料／權限／身分切換，評估整合 Storage Migration Service，而非重新發明一套通用搬檔方案；它不能代替 IIS、排程、資料庫等其他服務遷移。[Microsoft Storage Migration Service](https://learn.microsoft.com/en-us/windows-server/storage/storage-migration-service/overview)

## 選單與使用流程草案

```text
Windows Server Migration — 批次 B2026-001
主機配對：10    待審核：4    可匯出：2    阻擋：3    待切換：1

1  管理批次／來源與目標配對
2  前置檢查與探索盤點
3  分類審核／搜尋／選取與排除
4  路徑、帳號、IP、端點映射與相依檢查
5  產生／開啟確認報告，凍結本次審核版本
6  匯出搬移包／檢查包／續跑
7  目標前置檢查與還原預覽
8  執行還原／重試／查看回復點
9  切換前驗證／切換計畫／切換後驗證
10 全批次進度、問題與報告
0  儲存並離開
```

- 主機選擇先看摘要表，可選單台、多台或問題主機；明確顯示目前來源／目標，操作前再次呈現作用範圍。
- 選單僅呼叫相同核心入口，不在互動介面中另寫一套遷移邏輯；無 Console/redirected stdin 時要求參數模式，避免排程執行卡住。
- 根據階段顯示可用操作與阻擋理由。來源端不執行目標還原；目標身分不符合清單時必須停止。
- 本機端的盤點／匯出／還原只作用於目前執行主機。管理端多主機選取用於審核、報告與波次規劃；不把它描述成遠端執行。每台完成階段後輸出帶 PairId/revision/run ID 的結果包，再匯入管理端。
- 「產生文件」與「確認版本」分開；讀完報告不自動視為同意。確認綁定 manifest revision/hash。
- 正式切換是獨立動作，先顯示停機、最後同步、名稱/IP/DNS/身分變更及回復步驟；不做十台自動一起接手。

### 大量項目的審核體驗

- 每類先顯示數量、已選/已排除/待確認/阻擋，預設每頁 50 筆，可設 20/50/100；搜尋跨所有頁。
- 按主機、類別、名稱/路徑/帳號、應用組合、內建/第三方、相依狀態、選取決策篩選和排序。
- 穩定 ItemId 與短序號分開；頁面序號只是顯示，寫回用 ItemId。翻頁或重新排序不能選錯項目。
- 支援單筆、序號範圍與多選，整類操作、目前篩選集合操作，以及撤回／重新選取。
- 清楚區別「本頁 50 筆」與「符合篩選全部 3,200 筆」，批次變更先顯示件數、樣本、相依衝突與影響。
- 提供候選組合如「站台 A + AppPool + 內容 + 憑證 + 相關排程」，使用者可展開確認；共享相依不重複搬。
- 內建排程／系統服務預設折疊；完整文件仍列出。規則建議要顯示命中理由，不根據位置或廠商名就靜默排除。
- CSV 匯出/匯入審核只允許修改 `Decision`、`Reason`；`AllowedDecisions` 是唯讀的允許值說明。檢查 schema/version/duplicate IDs/來源/未知欄位與非法值，匯入先預覽差異、成功後原子儲存。單筆決策欄位命名與 manifest 相同，避免兩種格式無法對接。
- 儲存選取及搜尋條件、可離開再繼續。重新探索以來源身分＋類別＋自然鍵對齊；設定改變標示需重審、新項目待確認、消失項目保留歷史。
- CLI 輸出摘要與目前進度，詳細訊息寫 log；不要印出每一個檔案充滿主控台。估時以已測吞吐量計算，不假裝預檢能知道準確時間。

## 單一清單、決策與執行狀態契約

### 資料與檔案

- `fleet.json`：BatchId、主機配對 PairId、來源/目標固定識別、暫用與最終名稱/IP、網域、波次、負責人、整體狀態。hostname/IP 只作屬性；改名後 ID 不可變。
- `manifest.json`：schema/tool version、InventoryRevision、DecisionRevision、host identity、時間、每個 ItemId/Category/Kind/Name、實際來源證據、設定、相依、來源/目標映射、匯出/還原/驗證能力、機密需求。
- `decisions.csv`：供人審核的欄位，非完整還原輸入；JSON 是權威清單，HTML/CSV 都由同一版 JSON 產生。
- `state.json` 與逐項 append-only journal：階段結果、checkpoint、操作前/後摘要、失敗與回復點。單主機/配對寫入鎖，避免兩個流程同時還原。
- `artifacts`：設定匯出及有效 payload 索引；每檔大小/hash、來源／目的地、ACL/metadata、特殊檔案處理與責任項目。
- `reports`：全批次摘要、每主機完整分類報告、排除與阻擋、還原預覽、還原結果、切換前後驗證證據。
- 搬移包驗證必須覆蓋 manifest/decisions/artifact index 等索引本身；index 用獨立受核準摘要或 detached checksum 保護，避免自我雜湊循環。hash 為完整性檢查，不等同身份簽章。

### 決策、能力與結果分欄儲存

- 使用者決策：`Pending`／`Include`／`Exclude`。系統不能用 Failed/Unsupported 偷改 Exclude。
- 顯示「等待處理」是結果/阻擋，不能用來繞過未確認項目的門檻。
- 能力：各自記 `Discovered`、ExportSupported、RestoreSupported、VerifySupported 與需專用流程，不把有收集器等同有還原器。
- 收集結果：Success／Partial／NotInstalled／PermissionDenied／Unsupported／Failed。角色不存在與無法查詢不可混為一談。
- 執行結果：NotStarted／Ready／Running／Succeeded／Failed／Blocked／RetryPending／ManualEvidenceRequired；每階段獨立。
- 項目數是一個穩定 ItemId 算一個；分類小計與詳細項目一致，共享檔案不重複佔容量。
- 覆蓋率／決策完成率／還原通過率分開計算；Selected=0 顯示「無選取項目」，不能顯示整台還原 100%。排除與人工證據不能混入自動驗證通過數。

### 排除與相依

- 排除保留項目、理由、使用者、時間、規則來源、revision；不從探索清單刪掉。
- 相依分 mandatory／optional／external，並附證據/可信程度。推測相依待確認，不能盲目自動選取。
- Include 依賴 Exclude 時阻擋打包與還原，顯示依賴鏈並讓使用者選「重新納入／排除上層／改用已驗證外部相依」；不在背景更改選擇。
- Exclude 的檔案不打進 payload，但仍保留最小索引及理由；未選項目不能因整個資料夾複製而被偷偷包含。
- 類別/子項邊界須定義：排除某任務不代表排除同一腳本被其他任務使用；排除站台不代表排除共用 AppPool 或 runtime。
- 敏感參數不出現在一般 HTML/CSV/log；審核報告記需要哪類憑證或機密及責任人，不顯示密碼。

## 分類確認文件的具體內容

每台一份離線 HTML：可搜尋、篩選、折疊類別與列印，不使用 CDN；大量資料分頁/延遲顯示，保留全部項目。另附 UTF-8 CSV 完整清單供 Excel 篩選，對公式起始字元做安全處理。HTML 對名稱/路徑/描述 escape，不能執行來源資料中的內容。

每類先列小計，再逐項條列：ItemId、名稱、來源位置、帳號、設定摘要、是否搬移與理由、相關相依、目標映射、容量、機密／安裝媒體缺口、自動化支援、阻擋、驗收方法。可下鑽原始證據，但不得外連洩漏機密。

示例（示意資料）：

```text
IIS 站台：共 24；納入 20、排除 2、待確認 2
• WEB-001／ERP：納入
  來源 D:\Web\ERP → 目標 E:\Apps\ERP
  AppPool ERP-Pool；相依：CERT-003、RUNTIME-002、EXT-DB-001
  缺口：PFX 私鑰待提供
  驗收：設定比對、HTTPS/SNI、登入、資料查詢與上傳
• WEB-002／RetiredPortal：排除
  理由：已停用，由服務負責人確認不搬移

排程：共 680；納入 58、排除 600、待確認 22
• TASK-018／ERP-Nightly：納入；目標先停用
  相依：SCRIPT-007、ACCOUNT-004、EXT-SHARE-002
  驗收：XML/ACL 比對、可控測試的結果與產出
```

報告頁首記主機、批次、InventoryRevision、DecisionRevision、ApprovalId、PayloadGeneration、產生時間及確認狀態。重盤後有新增／刪除項目、設定／相依／映射／排除改變時，受影響審核失效；純執行紀錄或核準資料範圍內的內容更新，不要求重審所有無關項目。匯出建立另行封存的包索引／摘要，還原同時核對審核版本、payload 世代與目標配對，不使用單一會持續改寫的 manifest hash 混合所有用途。

全批次摘要列每台 PairId、OS、目前階段、待審/排除/阻擋數、資料量、最後成功時間、下一步及負責人；可看跨主機相依，按應用組合安排波次。

## 大型資料、十台主機與執行體驗

- 工作區以 BatchId/PairId/source identity 分隔。來源識別不符、配對重複、包被送到錯誤目標時拒絕執行。
- 所有來源都可完整探索，但匯出只處理審核納入項目。先估容量、檔數、最大檔、長路徑、來源可讀性與磁碟空間；雜湊與壓縮進度獨立顯示。
- 小型設定與索引採 ZIP；大型內容採同目錄的獨立 payload 卷/目錄，依 manifest 驗完整性和順序。單 ZIP 超出選用函式庫或檔案系統能力時先擋住並提供分包，不在最後才失敗。
- 每台預設一次一個資料搬移作業，可設定本機速率與並行上限；管理端顯示波次與共享儲存容量預算，供使用者安排開工順序。本機離線模式不宣稱可即時控制其他主機負載。首輪單台 pilot，通過後分波次處理，不用十台同時切換驗證工具。
- metadata 快速探索與深度路徑/相依掃描分開；對大目錄分批/串流處理，記 checkpoint、不把整個檔案樹載入記憶體。
- 檔案複製/hash/壓縮每階段可取消、重新啟動與續跑；部分包不標成功。輸出檔先暫存，成功後原子完成標記。
- ZIP 本身不保留 NTFS ACL/owner/SACL/ADS等還原語意，必須另存 metadata 或用能保留所需資訊的傳輸模式；不把 ZIP hash 相同當作權限相同。
- 檔案正在寫入時記不一致風險；先初始同步，再在維護窗口停止相關寫入/排程/消費者做 final delta。DB/queue 使用產品一致性機制，不使用一般檔案重試取代。
- 包格式必須定義 extraction sandbox：拒絕絕對路徑、`..`/路徑跳出、未知schema、重複或缺件、超額大小及異常壓縮比；所有 restore destinations 只由核準映射產生。
- 權限受控工作區與安全機密輸入，不把明文密碼放進 manifest/CSV。加密包須含 key 交付及在新機解密設計，不能用只綁舊機的 DPAPI 當跨機方案。
- 上一階段結果及 package identity 可追蹤，不因 host rename/IP 改變而找不到續跑紀錄；中央彙總離線來源的重複報告採 revision/執行 ID 去重，衝突明列。

## 還原、驗證、切換與回復契約

1. 目標前置檢查：身份/配對、OS/runtime/module/roles、path/容量、網域/帳號、機密與憑證、相依順序、既存名稱衝突。遇到不支援版本先阻擋。
2. 產生 plan/dry-run，逐項列新增/變更/跳過、預期目標、是否需重開機及回復。明示預覽不代表實際操作會成功。
3. 還原前匯出受影響目標設定與回復點；同名項目預設阻擋，除非使用者對具體變更選擇覆寫/映射/保留。
4. 先安裝相依與建立必要路徑／身分，再還原資料、ACL、應用設定、站台/服務/排程。優先產品安裝與支援的 CLI；不直接合併整份舊服務登錄、防火牆或安全政策。
5. 任務與生產消費者先停用／限制連外，避免新舊雙跑；哪些服務可啟動測試依項目定義。具有業務副作用的任務用測試帳號/資料或明確授權後驗證。
6. 每個操作宣告可安全重試、需探測後重試或不可自動重試；不是所有業務工作都具 idempotent 性質。以目標實際狀態重驗，不只信 checkpoint。中斷重跑不建立重複排程或破壞已驗證檔案，也不自動重送郵件、付款、佇列交易或月結工作。
7. 驗證分：包完整性、目標設定、內容與映射後 ACL、服務/程序健康、真實功能、外部連通與安全身分。驗證方法/期望/實際/證據/時間都按 ItemId 保存。
8. 暫用名稱/IP 下的驗證用測試 DNS/Host/SNI/端點映射；無法模擬正式 SPN/身份或外部 allowlist 的項目標「待切換後驗證」，不假裝已通過。
9. 切換前核對來源停止寫入、final delta 已在目標套用與重驗、新舊互斥、IP/名稱/DNS/SPN/電腦帳號方案、監控與備份、停機與回復窗口。角色為 DC/CA/Cluster 等時走專用身分流程。來源停用、接手名稱／IP、目標啟用需按離線交接記錄串接，不能假定目標工具可以控制來源。
10. 切回原名稱/IP 後重驗 DNS/PTR、HTTPS/SNI、Kerberos/服務帳號、UNC/DB/API、負載平衡及實際用戶端業務；所有階段可歸屬相同 PairId。
11. 失敗回復：設定建立可還原回復點；對新機已產生的業務資料／交易先處理 reconcile/反向同步，不承諾單純改回 IP 能還原資料。舊主機保留到驗收與回復保留期完成。

選取項目任何 Failed/Blocked/未支援/待人工證據/待切換後驗證均不能報整台最終完成。人工專用流程必須有負責人與驗收證據，報告區分人工驗收與工具自動驗證。

## 批次總覽與交付順序

| 批次 | 主題 | 規模 | 相依與交付 |
|---|---|---|---|
| A | 清單模型、能力檢查與盤點補漏 | 大 | 先定 schema；輸出所有後續階段可用的清單與證據 |
| B | 主控台選單、分類審核與排除 | 大 | 使用 A 清單；輸出可重用決策、映射與相依解決結果 |
| C | 分類文件與十台集中彙總 | 中 | 使用 A/B；輸出確認版與全批次報告 |
| D | 正式搬移包、大型資料與續跑 | 大 | 使用已確認清單；輸出完整且可驗證的包 |
| E | 自動還原與逐項驗證 | 大 | 使用 D；每能力模組都必須有還原器與驗證器 |
| F | 波次、身分切換與端到端驗收 | 大 | 使用 E；由 pilot 擴到十台，切換後完成驗收 |

先完成 A/B/C，讓使用者拿真實盤點文件確認範圍，再依發現的角色展開 D/E 的能力模組。不是只完成前半就宣稱本輪全部完成；整輪以 F 的驗收門檻為準。

### 批次 A：清單與盤點補漏

**範圍／改動**：將既有探索改為可測的收集模組、建立 schema與穩定 ID、能力探測/支援矩陣、所有企業分類的存在檢查、主機固定身分與配對；補程式/資料/路徑/帳號/外部相依候選及人工補列。

**輸入／輸出／下一段**：現有腳本及來源檢查 → manifest/原始證據/Partial與阻擋 → B/C 審核。

**驗收**：2016 與 2025 各跑完整探索；未安裝角色不是失敗；權限不足不宣稱不存在；包含隱藏/停用任務、UNC/相對路徑、共享 IIS、自訂服務與32bit；再盤點保持 ID，變更/新增/消失處理正確；父分類摘要與子項相符。其他版本在實測前只能標未驗證。

### 批次 B：選單、選取與排除

**範圍／改動**：主控台及非互動入口、每類分頁/搜尋/篩選/多選、應用組合、CSV 決策交換、排除理由/撤回、路徑與帳號/端點映射、mandatory相依衝突、持久化與舊確認失效。

**輸入／輸出／下一段**：A manifest → decisions/revision/映射 → C 報告與 D 匯出。

**驗收**：跨頁 ID 不混淆；篩選全部與本頁數量精準；CSV 不合法整份不寫入；排除相依出現可理解的鏈與阻擋；共用腳本/Pool仍可保留；重掃不丟失有效決策；stdin 非互動不等待輸入。用 10,000 項審核資料量測，不只測數十筆。

### 批次 C：分類文件與十台彙總

**範圍／改動**：離線 HTML、完整 CSV、按類逐項條列、原始證據連結、排除/缺口/驗收欄位、包/決策確認、fleet摘要與cross-host相依圖資料。

**輸入／輸出／下一段**：B 已審資料＋fleet → 報告與核準 revision/hash → D 預檢。

**驗收**：每個 manifest ItemId 都出現在完整文件且小計精準；10 台×10,000 項分類/搜尋/開報告不需一次渲染 100,000 列；HTML/CSV內容安全、無密碼；離線無外部依賴；報告修改不能改權威清單；修改決策後拒絕沿用舊確認；重複離線導入不重算/覆蓋較新狀態。

### 批次 D：正式搬移包

**範圍／改動**：採已確認清單匯出設定/有效資料與metadata、依賴安裝來源/機密需求、容量與功能限制預檢、hash/索引保護、ZIP/大型payload方案、initial/final delta、續跑與安全解包契約。

**輸入／輸出／下一段**：核準清單＋payload/金鑰或缺口 → 包與完整性結果 → E restore。

**驗收**：排除內容不混入包；共用payload只存一次；索引/manifest被修改或缺件時失敗；長路徑/大檔/ADS/EFS/reparse point有正確能力/阻擋；磁碟不足與檔案鎖定可解釋；中途取消後續跑得到相同完整包；超過限制時分包或提前阻擋；惡意路徑不能跳出工作區；final delta 納入最後變更。

### 批次 E：還原與逐項驗證

**範圍／改動**：核心 restore orchestrator、plan/target preflight、conflict policy、回復點、journal/鎖/續跑、按類別能力模組。首批覆蓋 IIS/內容、排程/腳本、已確認可重建的非系統服務/程式、selected設定/角色、帳號/ACL/分享、憑證與runtime依賴。其他偵測到的產品按實際清單補專用模組／流程。

**輸入／輸出／下一段**：D包＋映射/機密/安裝媒體 → 目標狀態與每項驗證/回復 → F切換。

**驗收**：錯host/錯package拒絕；未支援模組必須阻擋；同名衝突不能覆蓋；破損包不寫入；中途失敗可安全續跑/重試；排程停用且無生產雙跑；設定/檔案/ACL／login/endpoint/business checks正反例都能抓到；僅SC/HTTP 200不可替代業務驗收；任何入選而無實現的項不得宣告全輪完成。

### 批次 F：十台波次與身份切換

**範圍／改動**：pilot到波次策略、跨主機相依排序、臨時/最終狀態、切換計畫/預檢/執行入口與審計、DNS/SPN/網域步驟、切換後驗證、回退和業務資料界限。

**輸入／輸出／下一段**：E通過＋source final delta/維護窗 → 切換及終驗報告 → 退役/保留期決策。

**驗收**：先單台真實應用再至少兩個相依測試主機，最後實際十台逐配對驗收；改名/IP後能續追ID；只有明確選定的主機切換；不產生同名/IP並行；切換後外部消費者與認證測試通過；註入一台失敗不破壞其他台進度；回退演練記錄設定與業務資料限制。

## 量化 UX 與測試規模（建議門檻，待測定）

- 主要用 10 台、每台 10,000 項目的合成清單做審核/統計/報告壓力測試，另以實際數量調整；這不是假設十台都各有一萬服務。
- 在約定測試硬體上，載入單台摘要/篩選搜尋操作 p95 目標 2 秒內；完整探索/大文件搬移另顯持續進度，不能套用 2 秒門檻。
- 使用固定測試資料、環境/版本與測量腳本報告實際耗時與記憶體；門檻需在實作前選定測試主機，不能只寫「很快」。
- 文件測試集至少含 >4GiB單檔、長路徑、幾十萬小文件、重解析點、非ASCII/引號字符、權限不足/鎖定文件、部分壓縮與目標已有設置；容量按測試環境實際約定，不預設有TB級可用磁碟。
- 計數精確對照 Include+Exclude+Pending=發現項目數、每類彙總、同一Shared artifact空間去重與跨台狀態。
- 實機驗收：Windows Server 2016 + 2025 虛擬測試機，具 IIS/任務/服務/分享/證書與可控測試應用；當前電腦的語法檢查不能代替。

## 本輪規劃完整性核對

| 使用者原始要求 | 對應設計與交付 | 驗收批次 |
|---|---|---|
| 1 選單式遷移 | 主選單＋階段入口＋明確來源/目標＋可恢復狀態 | B/E/F |
| 2 補企業可能遺漏項 | 12類別存在檢查、關鍵相依、專用角色與外部人工補列 | A/E |
| 3 分類文件確認全部項 | HTML逐項條列、CSV、revision確認、排除/阻擋仍可見 | C |
| 4 排除項 | 決策/理由/撤回、批次排除、依賴衝突、payload過濾 | B/D |
| 5 大量項體驗 | 分頁/跨頁篩選/組合作業、進度/估算、保存/續跑 | B/C/D |
| 6 近十台 | fleet配對/隔離包、集中彙總、相依波次與單台失敗恢復 | A/C/F |
| 原始盤點ZIP→新機自動還原驗證 | 核準manifest驅動匯出/還原/驗收、索引完整性與切換後業務測試 | D/E/F |

原稿編寫時已核對以上要求均有規劃落點，當時尚未實作；現行程式持續補齊中，未進行整輪產品／實際十台驗收。R2 複審發現原稿仍有離線交接、資料版本、狀態門檻與實際操作契約缺口，下列補強取代原稿含糊處，並增列對應驗收。此結論不是「程式已可正確運作」。

## R2 多視角複審：從使用者到整體影響

本節採用「質疑尖銳但能指出實際代價」的審查方式。下表提問是模擬評審問題，不是假稱引用 Reddit 留言。審查順序為使用者操作旅程 → 值班與管理者交接 → 程式契約 → 全批次依賴、資料與切換的整體影響。

P1 表示若未解決，可能選錯／還原錯誤、遺失資料或誤報完成；P2 表示會阻礙操作、企業部署或可維護性。下表全部是已確認的規劃缺口或需實測假設；「已補規劃」不等於「已修程式」。

| ID／等級 | 角度與具體質疑 | 原稿缺口／整體影響 | R2 補強位置與批次 |
|---|---|---|---|
| R01／P1 | 操作者：管理端選完，要拿哪個檔案回來源機？ | 只有結果送回管理端，缺核準決策回來源與包回目標的閉環 | 離線完整旅程；A/B/C/D/E |
| R02／P1 | 使用者：搬完的檔案已更新，確認 hash 就失效了？ | 審核與 payload/執行狀態共用版本，final delta 會造成重審循環或沿用過期證據 | 版本／封存／漂移；A/C/D/E/F |
| R03／P1 | 值班員：哪些條件是能切換，哪些才算完成？ | 模糊 Ready/Succeeded；最終同步後未明訂重新還原及驗證；停用與啟用缺具體步驟 | 階段門檻與啟用契約；E/F |
| R04／P1 | 管理者：來源已真的停寫，目標怎麼知道？ | 本機離線模式無法遠端互鎖；新機已有交易時不可單純反向改名/IP | 離線交接、一致性群組、回復分界；D/E/F |
| R05／P1 | 使用者：兩個目錄都映射到同一位置？檔案刪除會刪誰？ | 缺多對一／巢狀映射、junction alias、差異刪除及目標漂移規則 | 路徑／資料界限；B/D/E |
| R06／P1 | 程式審查：DB、Web、queue 互依，拓樸排序卡住怎麼辦？ | 跨主機相依不一定是 DAG，個別主機通過不等於應用整組通過 | 相依／一致性群組；A/B/D/F |
| R07／P1 | 值班員：安裝完成重開機，自動服務開始跑了？ | 「先停用」不足以定義重開機、安裝器自啟動及最終 enabled/start mode | 啟用／重開機；E/F |
| R08／P1 | 程式審查：robocopy 1 算錯？WMI ReturnValue 呢？ | 泛用 exit=0、stderr 及 Collect 層級不足以代表成功；ZIP 失敗缺最終狀態 | 程式執行契約與基準缺口；A/D/E |
| R09／P1 | 管理者：有人把 checksum 和包一起改掉呢？ | checksum 僅能驗傳輸；缺受信任摘要來源、工具與資料包的執行邊界 | 信任與機密；A/C/D/E |
| R10／P2 | 大量項目使用者：10 萬個 Pending 仍要逐筆勾？ | 沒有可審核規則、模板與例外差異流程；一律重審代價高 | 批次審核 UX；B/C |
| R11／P2 | 接手者：離線報告昨天更新，現在這台在哪一步？ | 沒有過期提示、結果排序／衝突、決策寫入權威與UTC記錄 | 離線權威／管理交接；A/C/F |
| R12／P2 | Server Core 操作者：沒有 browser、沒網路、policy 擋腳本？ | 沒有Core文字替代、工具離線部署／簽署、CLM能力檢查、非互動退出碼 | 部署與操作契約；A/B/C |
| R13／P2 | 使用者：整個資料夾有我沒選的 dll，怎麼判斷？ | 「未選不得打包」與「目錄作資料根」邊界不清；易誤漏相依或漏出機密 | 範圍單位與安全報告；A/B/D |
| R14／P2 | 程式審查：套用regex改設定、只解析英文netsh會失敗吧？ | 缺型別/語系/編碼、未知欄位保留、工具參數與版本相容契約 | 程式／格式相容；A/B/D/E |
| R15／P2 | 管理者：到底哪個角色第一版能搬？成本／驗收誰負責？ | 12類盤點與通用自動還原容易被讀成已承諾所有產品；未分工具完成與十台專案完成 | 能力矩陣／責任與發佈門檻；A/E/F |
| R16／P2 | 管理者：看到綠燈就能把舊機刪了？新機備份驗過嗎？ | 原稿只提保留期；缺觀察、備份還原、月結/長週期任務、退役交接與機密清理 | 營運驗收／退役；F |

### 1. 本機執行、集中審核的完整離線旅程

| 步驟 | 在哪裡做、操作與產物 | 下一端必須檢查什麼 |
|---|---|---|
| 1 | 管理端建立 BatchId/PairId，登錄來源與目標；來源本機執行能力檢查/探索，輸出 inventory result bundle | 來源固定身分、tool/schema、InventoryRevision、完整性與Partial |
| 2 | 管理端匯入探索，分類確認/映射/排除，輸出 approved plan bundle | 包含權威 DecisionRevision/ApprovalId、來源/目標身分、核準範圍、scope/settings摘要與可信摘要 |
| 3 | 來源本機匯入 approved plan，顯示配對，檢查設定漂移與待補機密，匯出 initial payload generation | 只匯出核準範圍；不接收別台或較舊審核；缺依賴先阻擋 |
| 4 | 目標本機匯入 migration package，執行預檢/預覽/還原與切換前功能驗證 | package identity、target identity、tool/adapter版本、ApprovalId及PayloadGeneration |
| 5 | 來源維護窗本機停寫、取得應用一致性與最終差異，輸出 final generation／source handoff record | 必須記寫入者停用、服務/DB/queue一致性、凍結時間、維護窗及負責人 |
| 6 | 將 final package 與交接紀錄送到目標，套用 delta，驗證最終世代；產生 ReadyForCutover 結果 | 不能以 initial payload 的舊驗證放行；需包含final manifest、有效交接與剩餘驗收項 |
| 7 | 操作者依既定身分流程，在來源／目標分別完成互斥與接手；目標本機啟用核準功能，完成正式端點/業務驗證 | 每步記錄實際身分、端點與source/target角色；不假定目標可自動停掉遠端來源 |
| 8 | 每台將結果包送回管理端，全批次報告彙整並進入觀察／退役審核 | RunId、單調sequence、revision/generation、時間與stage；不以檔案修改時間當新舊順序 |

每次選單結束顯示下一步、在哪台執行、需帶走的檔案／卷清單、目前阻擋與可安全重做步驟。來源與目標首次登錄即分配持久身分，配合多個實機指紋；偵測clone/重複ID/重新安裝時不沿用舊身分，要求核對重新綁定。只靠hostname、IP或可能重複的單一MachineGuid不夠。

管理端是審核決策的權威；各台來源/目標是其執行結果權威。來源選單可檢視或產生決策草案，再送回管理端審核；不能靜默改寫已核準決策，也不在第一版另建分散式審核權威移交協定。匯入衝突保留兩版並提示，禁止last-write-wins。

離線管理端不顯示「即時」：顯示資料產生時間、匯入時間、UTC/原時區與「距上次收到結果」；超過維護窗或資料有效期標 stale，時間偏差需要提示。管理端單一可寫工作區是第一版預設，新增多人同時編輯需另定衝突管理，不以目前append-only journal宣稱防竄改或多使用者RBAC。

### 2. 審核版本、包世代、漂移與最後同步

- `InventoryRevision` 描述探索結果；`DecisionRevision` 描述選取、映射、相依及驗收；`ApprovalId` 核準該決策；`PayloadGeneration` 描述一次實際資料快照。工具/schema/adapter版本與這四者分開。
- 審核核準的是明確範圍與預期設定，匯出封存的是實際資料索引。每代migration package保留不可改寫的封存索引，並以generation/hash與核準範圍關聯。執行state/report變更不修改已封存包。
- 原則上設定、帳號、scope、相依、映射、檔案排除規則變更要重審受影響項；核準目錄範圍內的業務資料變更產生新世代，經資料一致性與差異驗證即可，不要求對每筆交易重新勾選。
- 檔案型設定如web.config屬設定而非一般業務資料；結構變更不能藉由「只是資料delta」略過重審。設定分類與自訂override需記來源與理由。
- Delta包列 base generation、新增/修改/刪除與預期前置摘要；缺base、順序錯、重複世代、target已漂移時先拒絕或進入衝突處理。版本升級不能默默重解釋舊決策。
- Last sync必須在來源資料凍結後完成，目標套用final generation並重驗。只有與final世代/最終設定相符的證據可放行。未變更項的證據可在確認仍相符後重用，不全部重測；受影響項與其相依需重新驗。
- 本機離線搬移成本包含USB/共享路徑的實際傳輸、解包/ACL/驗證時間；pilot量測RTO並做預先同步，維護窗若不足就阻擋切換或調整窗口，不假設資料搬完就瞬間接手。

### 3. 階段門檻、啟用與重開機

| 階段結果 | 必要條件 | 不能被誤認為 |
|---|---|---|
| ReviewComplete | 現有項目有Include/Exclude；必要盤點缺口已補查或由負責人依外部證據結案，mandatory相依已解決，scope和映射已核準 | 只為無法查詢寫理由就略過，未偵測即不存在，或任何產品都已支援還原 |
| ExportReady | Include項有匯出/還原/驗證方法或核準專用流程、媒體/機密齊備，預檢通過 | 只完成審核就能輸出可還原包 |
| PackageSealed | 核準範圍的資料與metadata完整，索引/世代/可信摘要封存，無未解決缺件 | ZIP產生了就已完整 |
| PreCutoverValidated | 暫用身分下可測的必驗項已通過，副作用功能仍受控，post-cutover清單明確 | 已經可以全部啟用或退役 |
| ReadyForCutover | final delta在目標套用並驗證、來源凍結交接有效、目標無漂移、身份與回復方案就緒；只允許預先核準的「需正式身分才能測」延期 | 允許一般Failed/Blocked或未知驗收直接跳過 |
| CutoverComplete | 來源停止對外／寫入，目標接手身份和核準功能啟用，交接證據齊備 | 全部正式業務已驗證 |
| FinalAccepted | 所有必驗項含正式身分與外部業務通過，人工證據有服務負責人接受，無未處理失敗 | 舊主機可立即刪除 |
| RetirementReady | 觀察期、必要長週期工作、目標備份實際還原驗證、RPO/RTO與責任移交滿足；服務負責人同意 | 工具可自動刪除舊主機 |

每項保留 `DesiredFinalState` 與 `StagedState`。來源已停用任務在目標最終仍停用；來源已啟用的任務依切換清單恢復原trigger/登入/權限/Enabled。服務的start mode/delayed start與目前running狀態分開，不把為測試啟動的manual服務改為automatic。安全 staging 的偏差需列可接受理由、結束條件，不能被一般設定比對當成永久成功。

排程須以停用狀態註冊，不能先註冊為啟用再立刻停用；切換時需要判斷過期trigger、StartWhenAvailable、重疊執行、多執行個體及catch-up策略，避免一次補跑多筆工作。帳號的logon right/登入方式、working directory與實際執行身分要一起驗，不以XML相同代替實際可執行。

安裝器可能啟用服務／要求重開機，角色亦可能建立自啟動工作：還原模組須在步驟前識別、限制副作用，再設staging狀態。每次重開機後重新檢查配對、包世代、鎖與預期狀態；正式切換前重開機仍不能執行生產工作。重開機明確列為計畫步驟，回傳RebootRequired，不在錯誤重試中擅自重開。

### 4. 排除範圍、路徑映射、相依圖與一致性

- 項目分「物件設定」與「明確資料範圍」：Include站台不表示可搬整個D槽；Include資料根則納入該scope中所有符合已核準規則的檔案。scope中的個別檔案不需要逐筆當服務勾選，但索引必須全列。Exclude服務不會自動排除被其他服務使用的同一檔案。
- Scope可設定檔案/子目錄排除，但必須分析被選服務/任務的相依；若資料根中包含未核準服務、設定或機密，先列範圍衝突與需確認候選，不能因「資料根已選」就漏搬／全搬不自知。
- 路徑映射做canonical比較與實體路徑校驗：大小寫、UNC、相對路徑、環境變數、volume/mount、junction/symlink、來源／目標alias、多對一、巢狀/重疊範圍與workspace自我包含。重疊未解決則阻擋；不能讀符號連結跳出核準範圍。
- 目標可能已有非本工具的資料；缺件/修改/刪除不能靠整根 `/MIR` 或 `/PURGE` 掃掉。只對核準scope中有來源ownership/前置摘要的物件套用delta刪除，預覽、備份與journal記錄；非工具擁有或已在目標修改的物件必須處理衝突。
- 純path/account/endpoint替換須使用格式感知parser與欄位映射，不對XML/JSON/連線字串/命令列做全域regex。被加密/第三方未支援設定保留原始證據並列專用流程，不能猜寫。
- 相依有生命週期：安裝、設定、啟動、停寫、測試、正式流量。Circular dependency要檢出強連通群組並制定各階段順序；不能套一次topological sort期待萬用。
- 跨主機IIS/DB/share/queue屬同一應用一致性群組時，先定GroupId、資料寫入者、維護窗、backup/log checkpoint、freeze順序、cutover/activation順序與共同業務驗收。資料庫/queue用產品支援的一致性方法；檔案快照不保證跨資源交易一致。
- 離線source handoff record只證明當時操作者記錄，不能保證來源之後沒有被重啟。目標啟用前操作者須再次確認來源停止生產、端點互斥與交接時效。條件無法確認則不進行接手；單機lock不能當成全網防雙跑。
- 寫入所有權從source交給target前，回復可按既定設定/身份恢復；target接受新交易後，需重新停寫、合併/反向同步或產品恢復流程。每個群組記不可直接回退時點與責任人，不能自動重啟舊源。

### 5. 程式、部署、信任與輸出契約

- Native adapter以argument array呼叫，不使用Invoke-Expression/拼字串shell命令；為每工具記支援版本、成功/partial/error/reboot碼、timeout/cancel/retry與structured output。stderr文字或exit=0都不是完整業務結果。
- Robocopy需工具專屬退出碼處理；0–7可能是無複製失敗，含extra/mismatch需依預期狀態判定，>=8為至少有複製失敗。避免預設長重試拖垮維護窗，參數按來源版本探測。[Microsoft Robocopy](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)
- WMI/COM方法先判ReturnValue/HRESULT與資料完整性。子項有失敗時父層是Partial或Failed，不記完整Success；缺角色與權限不足嚴格分開。ZIP/multipart封存與驗證亦進入最終state。
- 非互動入口回傳documented result：`0` 所請求階段的門檻全部成立；`2` Partial/Blocked/RebootRequired（須讀結果substatus）；`1` 執行Failed；`3` 安全取消；`4` 格式/身分/包/核準無效。這是工具包退出碼，不能覆蓋原生工具碼；每個結果保留stage/phase-native code。
- 一般查詢/狀態與唯讀報告不要求admin；需要服務/私鑰/SACL/角色等權限時按能力說明。缺權限不自動提權、不自動改GPO/ExecutionPolicy/EDR。前置探測execution policy、簽章、AppLocker/WDAC/ConstrainedLanguage限制並給受支援部署方式。[Microsoft PowerShell language modes](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_language_modes?view=powershell-5.1)
- PowerShell 5.1 x64基線、Server Core、zh-TW/en-US語系先列驗收組合；PowerShell 7或其他舊OS不可因語法能parse就標支援。使用structured API優先，localized native輸出必要時依工具/語系adapter解析；不可只解析英文欄名。
- JSON契約定義型別、null/空集合、enum、大小寫、UTF-8、UTC ISO8601、schema migration及最大輸入大小；設定未知欄位保留於原始證據、不能遺失後再還原；未知schema拒絕。索引hash使用已封存的實際bytes與明確格式，不依不穩定property排序重新序列化後比對。
- CSV必須標記raw/effective欄位、delimiter/encoding、quote、round-trip escaping/公式防護方法：審核匯入以ItemId+revision識別，names/paths是唯讀且核對，安全顯示escape不能改實際物件名。partial editing的缺列代表不改，不代表排除；blank Decision及新增偽造ID不接受。
- 秘密偵測不能保證靠regex找盡所有token。raw config、environment、command line、registry與profiles全部視為敏感artifact；有權限限制的raw evidence與遮罩review report分開。Central報告預設不打包全部原始機密；每個機密輸入用SecretRef、所需key ACL與負責人納管，變更與權限可驗，無必要不寫明文。
- 中央保留approved plan/package的受控可信摘要，再透過受控獨立通道核對；同一ZIP內checksum與data一起可改不算身份信任。來源首次匯入核准計畫與目標匯入包，都要顯示並核對此獨立摘要。簽章若可用則驗簽並管理信任根；不用假的自建信任聲稱抗惡意admin。資料包的確切信任部署與key交付仍需實作前定案，不能因同一媒體帶了checksum就通過R09。
- 目標執行的是預先部署、版本核準的工具/adapter，migration package以schema-bound資料匯入，不自行執行包內ps1/msi/exe或任意命令；需安裝媒體的模組驗證其來源/摘要與已核準安裝步驟。包內只因檔名是.ps1不能執行，來源應用程式需按核準還原流程部署。
- 解包前檢查名稱正規化衝突、大小寫/重複entry、絕對/相對逃逸、NTFS reserved name、ADS與reparse point；支援ADS的payload必須走專用metadata還原而非任意解包；不可讓鏈接目標逃出scope。傳輸hash只證明內容，ACL、EFS與有效訪問要獨立驗收。
- 空間估算列來源暫存/ZIP、目標暫存/解包、目標新內容、回復點、delta保留與安全餘量的峰值，不假設有三倍空間。模組先估算、不複製被排除項目、不處理workspace本身；不使用預設巨大重試。
- 工具發行包含版本、adapter能力矩陣、離線依賴、來源/摘要、簽署說明與最小啟動方法。缺依賴/簽署信任時清楚阻擋；不預設互聯網即時下載。Installer升級tool本身不能在running migration中替換，journal lock崩潰恢復須核對實際owner/process/世代，不直接刪鎖當續跑。

### 6. 大量項目與值班操作細節

- 主選單按 `來源本機`／`目標本機`／`管理工作區` 區分可做動作，減少看得到卻永遠不能做的選項。每個操作顯示來源→目標、Batch/Pair、所用核準版、目前階段與下一步。
- 返回、取消、無效輸入與Ctrl+C在所有子選單語義一致：審核編輯可撤回，文件操作只在checkpoint安全邊界停止，外部不可取消事務明確標示處理中及不能強停理由。
- 大量Pending可套規則/應用組合/主機模板：提供match預覽、樣本、命中件數、例外與理由；使用者一次確認明確範圍後批次寫入。跨台複製只複製匹配條件/理由，逐台預覽差異，不複製ItemId、密碼或目標狀態。新項與高風險例外仍待確認。
- 字串輸入預設literal；wildcard/regex須顯式模式，避免使用者輸入`[`或`*`意外匹配或parser錯誤。顯示「當前篩選全部」與「本頁」並凍結操作集合，提交前版本變更就要求刷新。
- CSV或規則批次修改成功後記錄affected IDs、previous decision、RuleId；撤回檢查期間有無其他修改，不能把較新決定一起覆蓋。審核報告保留規則來源並可展開全部，不給系統建議假裝使用者已確認。
- Server Core本機可用文字摘要/CSV/問題清單；HTML在管理電腦離線開，不要求舊主機有browser。100k完整列印可導出文字/分組分頁，並提示頁數；完整資料可查不等於一頁渲染100k列。
- 失敗畫面給ItemId、發生階段、實際原因、可重試性、修復建議/下一步、log位置、相關相依；不只印stack trace或「發生錯誤」。一次作業失敗仍保存其他項證據，但影響下游的項明確Blocked，不自動繼續切換。
- 日誌bounded/rotation/剩餘空間檢查，詳細日誌不暴露機密；進度含處理數量/bytes、階段、最後活動時間，卡住可查timeout。第一版不承諾從central取消來源本機作業。

### 7. 專案、管理責任與最終觀察

能力矩陣每adapter至少記：Collector/Exporter/Restorer/Verifier、來源OS/產品版本→目標支援組合、依賴/許可、資料一致性方法、reboot、副作用、rollback級別、probe/fixture/實機證據。NotInstalled必須有成功存在檢查；UnsupportedCollector不代表功能不存在。

先A/B/C產出真實十台清單，A結束評估每個Include項的可自動/專用/暫未支援結果，估工作量、安裝媒體與權限成本。只對實際已實現且實測通過的組合發佈「自動支援」；選擇了未知角色必須補模組/專用流程或由使用者明確排除，不能為交付縮掉目標。整輪工具發佈驗收與這十台的生產接受分別追蹤，不能靠「合成10台跑過」宣告實際十台完成。

| 責任 | 要確認的內容 |
|---|---|
| 工具維護者 | schema/tool/adapter版本、支援證據、退出碼、缺口、發佈和可回退版本 |
| 各主機操作員 | 對的機器/配對、權限/本機日誌、材料交換、前置與作業結果 |
| 服務負責人 | 搬移scope/排除理由、業務驗收與有副作用測試、長週期工作的驗證或補測窗口 |
| 網域/網絡/安全/DB負責人 | 身份/證書/allowlist/備份一致性等專用步驟與證據；並非全部要由一個使用者辦理 |
| 批次/變更負責人 | 波次、維護窗/RPO/RTO、source→target寫入所有權、停止/回退條件、觀察和退役 |

責任分工與接受記錄是第一版資料契約，不新增企業身份服務或強制雙人系統；單人可兼任。重大覆蓋/刪除/切換集中在具體計畫末步確認，查詢/一般審查不反覆彈確認。確認者/時間/理由/證據保留在受控記錄，非聲稱本機journal為不可竄改audit。

退役前至少確認監控/告警正常、備份已涵蓋新機且實際可還原、許可/安全代理註冊正確、外部使用者接受、必要的月結/季結工作已測或留明確補測責任、觀察期無未處理異常、舊機與敏感包/機密保留與清理日期。SQL備份VERIFYONLY只檢查可讀/完整等，不代替測試實際restore與業務檢查。[Microsoft RESTORE VERIFYONLY](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql?view=sql-server-ver17)

### 8. R2 追加驗收：操作旅程與整體影響

下表補入原A–F驗收；沒有過就不能用原階段測試已通過來略過。故障只以合成fixture/隔離測試環境註入，不在生產機實驗。

| 場景 | 應出現的行為與證據 | 批次 |
|---|---|---|
| 離線全過程／wrong source/target | management核准→source匯入→target還原→final delta→回傳結果皆匹配；帶錯機器拒絕 | A–F |
| Clone identity／時間錯誤／過期報告 | 重複ID、舊generation、過期handoff、時間偏差提示並阻擋必要動作；不把文件mtime當真 | A/C/F |
| 多端編輯／CSV刪列/blank/公式escape | 權威與版本衝突保留；無效輸入不部分寫入；missing row不自動排除；名字round-trip不變 | B/C |
| 100k Pending／規則應用／跨台重用 | 明確一次審核可處理整批，例外可查；new/changed只重審有關項；命中計數和undo精確 | B/C |
| 更新業務資料 vs web.config | 資料新generation不要求整批重審；設定漂移使相關Approval失效 | A/C/D |
| initial→final delta／目標漂移／刪除 | final正確套用，相關證據過期重驗，base不符/未歸屬目標文件不誤刪 | D/E/F |
| 循環依賴／兩台share+DB+Web | 識別群組，不死循環；freeze/activation/rollback在應用層完整，驗證跨台業務 | A/B/D/F |
| reboot/installer自動服務／原來disabled | staging經過重開機仍不生產，最終按DesiredFinalState啟用或保留停用 | E/F |
| 註冊任務立即trigger／missed schedule catch-up | 註冊時即停用，不短暫執行；切換啟用依核准策略補跑或略過，驗身分/登入權利/工作目錄 | E/F |
| Native工具0/1/7/8、return code、timeout、ZIP failure | adapter判定正確，Partial/Failed進最終state，入口退出碼符合契約，後繼Blocked | A/D/E |
| policy/CLM/Core/zh-TW與en-US/no internet | 支援環境能部署操作，不支援能力清楚阻擋；不改企業安全策略；無browser仍可審 | A/B/C/E |
| overlap mapping/junction/UNC/workspace/target文件 | canonical collision先阻擋，reparse不跳出scope，工具暫存不遞迴匯出自己 | B/D/E |
| 被改包／同包checksum／未知adapter／惡意路径 | 對可信摘要/工具版本驗不符拒絕；資料不能觸發任意腳本，解包不逃逸 | C/D/E |
| 存儲不足／鎖定／取消／tool升級／崩潰重啟 | 不宣告sealed，不無限重試；安全checkpoint、鎖與目標狀態校驗；new版本不能偷換運行工具 | D/E |
| 目標已有新交易後回退 | 明確進入停寫/資料協調流程；不能自動啟舊源；報告不可簡單回退的原因 | F |
| green dashboard/舊機退役 | FinalAccepted與RetirementReady分開；無備份restore/必要業務證據不得退役ready | F |

### 9. 最後從整體檢查的結論與剩餘事實

- 流程閉環：主機登記、source→管理端探索、管理端→source核準、source→target包、source→target最終交接、target→管理端結果皆有身份/版本/權威與下一步。
- 所有原需求仍在A–F，新增契約直接掛回對應批次；本機執行方案沒有被悄悄換成WinRM，沒有因專用角色複雜就自動縮減支援目標。
- 資料版本與審核版本分開，final delta不會死鎖審批；階段成功與終驗分開，臨時staging差異有結束動作，source與target寫入所有權明確。
- 排除保留紀錄與相依邊界，資料scope可實際打包；與衝突/刪除/映射/metadata保護同一條鏈，不單獨為UX追求「一鍵全選」犧牲實際範圍。
- 合成/靜態審閱只證明已找到問題且規格有定義；尚不能證明CPU/記憶體/RTO預算、所有role collector、第三方安裝支援、CLM允許能力或實際十台業務可正確還原。
- 仍需source真實盤點、測試機、業務負責人、產品/角色版本、工具/媒體、RPO/RTO及維護窗才能完成產品與生產驗收；不因規劃寫得完整就宣稱無風險或不存在遺漏。

## 明確不做與邊界

- 本輪規劃交付不修改原腳本、不執行伺服器操作、不建立假的自動還原入口、不承諾未知產品/版本已經支援。
- 不以通用registry/security policy全量導入搬整個OS，不複製硬體驅動或產品授權來繞過正式部署。
- 不將未知角色/第三方產品自動排除。所有發現項目仍在清單上，後續根據實際清單補模組、專用流程或由使用者明確排除。
- 不假設改回hostname/IP就能恢復舊SID/電腦帳號、私鑰/DPAPI或所有Kerberos認證。
- 不讓同一命名/IP的新舊主機同時對外，不在一般還原階段啟動全部任務/消費者，不自動對十台同時切換。
- 不把包hash驗證、指令exit=0或網站HTTP 200單獨視為全部業務成功。

## 定案前的建議與後續輸入

本機執行、集中彙整模式已由使用者確認。其餘建議為先完整盤點與分類審核，再按發現結果補自動還原模組。第一版不實作 WinRM 遠端操作；若未來另行要求，需追加連線、認證、逾時、重試與遠端中斷驗收。

使用者已授權開始實作；下一個環境輸入是一台代表性來源的真實盤點。全套十台的專用角色列表、容量與支援矩陣在 A 完成後回寫本 PLAN；新增無法自動遷移的角色不會默默從本輪目標移除。

實作完成後才進入獨立體檢與交付；規劃文件完成不等於遷移工具完成。

## 2026-10-08 持續補實作與完整性核對

使用者要求全部未實作項目補齊後才停。0.3 已加入 D/E/F 隔離 pilot 核心與更多 A/B/C 接線，仍在「實作→核對→补齊」循環，未標整輪完成、未進入不同模型 closeout。最新逐項程式、有效測試、當期待辦與環境驗收統一維護於 [實作核對表](../IMPLEMENTATION-0.1.md)，現行操作契約在 [OPERATIONS.md](../OPERATIONS.md)。原 A–F／R01–R16 條件完整保留，不以刪 TODO 代替完成。

本輪基準 7287399，主代理整合並獨立驗證，按使用者要求以 gpt-6-luna low／medium／high 委派；本輪程式／測試已推送 checkpoint 為 10c896a，完整 GitHub CI 37792481411 通過，包含 adapter、payload、target identity、source result、restore/journal recovery、cutover、SID map、角色精靈、深層 enterprise collector、跨主機切換證據門檻與對應 fixtures。沒有對實際 Server 做任何設定還原／改名／IP 操作。

原型檔 Get-ServerMigrationInventory.ps1 屬使用者本機探索檔，不改寫或加入正式版本。100k 合成與 real-file fixture 只證明相應管理端／檔案契約；尚未提供來源真實盤點及隔離 Server 測試結果，不宣稱角色產品或十台生產驗收通過。
### 2026-10-08 測試主機的離線驗證回傳（使用者定案）

使用者有隔離測試主機，但無法讓代理直接連線。新增本機驗證報告入口，由使用者在來源／目標執行；產生可複製貼回的 UTF-8 文字摘要及完整 JSON，記錄主機環境、工具指紋、配對／核准／manifest／世代、逐项原生 readback 和未驗證項。報告不包含密碼、私鑰、原始 XML 或完整設定；JSON 的 SHA256 用來核對回傳檔案，並不等於企業簽章或產品資格。

未提供搬移包時只能回報環境與探測能力，不能宣告服務已搬移。提供可信搬移包時，只對精確綁定的本機與 durable checkpoint 執行讀取檢查；工具不為取得驗證證據而啟停服務、切換名稱／IP 或登記假的業務證據。真正還原、故障／重開機演練、外部消費者與業務接受仍由使用者於隔離環境執行並回傳結果；收到證據後再逐項判讀，不自動把生產資格旗標改為 true。
## 2026-10-08 測試效率調整（使用者定案）

依使用者要求排除無額外價值的重複長跑：取消 10k 小檔全故障劇本的必要門檻；日常驗證採小型真實檔案流程、明確的分塊／分段／64-bit 邊界與代表性 Server pilot。100k UX 與真實容量需求保留為相關改動／實際工作量的定向驗證，不每次全套重跑。正式功能、安全與業務驗收條件不刪除；有效證據與實施決定見 IMPLEMENTATION-0.1.md 的「測試必要性與資源調整」。

## 2026-10-09 下一輪範圍定案

使用者改為聚焦一般服務主機，軟體／runtime／必要角色由使用者依離線清單準備，特殊產品不新增自動遷移但必須告知並保留必要外部相依確認；Windows 設定另行逐項審核。本文件中的產品擴充方向依此變更，不計作已實作；一般功能的實機／業務／資料一致性／回退驗收仍保留。新規劃見 [MIGRATION-2-PLAN.md](MIGRATION-2-PLAN.md)。
