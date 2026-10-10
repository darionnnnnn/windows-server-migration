# Windows Server Migration

PowerShell 本機盤點、離線集中審核與分階段遷移工具，主要目標 Server 2016 → 2025、約十台主機。各台本機執行，管理端彙整文件與結果，不要求 WinRM。

## 專案用途與第 3 輪方向

### 企業 EOS 搬移目標

本專案是企業 TS（技術支援／遷移操作人員）的**輔助搬移工具**：從 EOS 主機盡可能找出並還原使用者需要的業務內容、原有設定及可重建的系統項目，讓使用者自行決定搬哪些內容、使用哪個軟體版本及何時補裝。TS 執行搬移及收集證據，使用者／應用負責人確認相依與業務結果，平台／產品負責人處理授權、帳號、政策及專業產品事項。

第 3 輪必須交付下列可驗收結果：

1. **TS 能依文件完成操作與交接。** 每一步說明在哪台主機操作、前置條件、預期產出、如何確認成功、阻擋原因、下一步與回復方式；工具顯示檔案搬移、軟體準備與業務驗收各自的狀態。
2. **使用者知道兩台主機的軟體差異及要手動補什麼。** 新主機以全新 Windows Server 的首次盤點為初始基準，每次還原前再盤點現況。軟體預設參考來源版本，使用者也可選擇新版或其他版本。程式自行維護 JSON 比較資料庫，分別保存來源版本、使用者選用版本、目標實際版本及人工待辦，另列架構、位置、帳號範圍、責任人與結果；未知版本保留名稱及原因。版本差異供決策及驗證，不單憑不同版本阻擋所有檔案還原。
3. **使用新版軟體時，仍能從舊路徑找到原有設定檔。** 預設保留所選業務文件／資料與可搬設定的來源絕對路徑，例如新主機仍可由 `C:\temp\report.csv` 或舊設定檔路徑存取原檔。HTML 文件分別標示舊設定保存位置與新版軟體實際使用位置、人工匯入／調整待辦。**工具不合併目的端既有文件**；因目的端已有內容而無法放置的原檔逐項列出、保留來源證據與重試方式，不默默覆寫或改址。保存原檔不代表新版能直接讀取舊格式。
4. **每個缺口都有處置與責任。** 軟體本體、授權及不支援的產品設定由使用者／產品負責人補裝或重建；工具能搬的檔案與設定須有實際核驗。必要相依、人工待辦或業務驗證未完成時保留對應阻擋，文件勾選不構成執行或切換核准。

5. **還原項目預設全選，使用者可調整。** 所有已發現項目均列出，可按類別、工作負載、項目及檔案範圍選取／取消，調整路徑、帳號映射及已支援設定；無法自動還原的也保持可見並列人工處置。選取代表搬移意願，執行前仍顯示實際範圍及需確認事項；重新盤點保留使用者選擇。
6. **操作與文件統一從 HTML 網頁入口使用。** HTML 操作介面搭配本機 PowerShell 執行端，提供盤點、差異、還原選取、預覽、執行與續跑；操作說明、完整清單、原設定索引、無法放置文件及交接結果也以 HTML 查閱。JSON 作內部資料庫，文字選單作備援；使用者正常流程不需手改 JSON 或開 Markdown／TXT／CSV。操作與文件頁面共用資料並區分即時操作與離線結果。

7. **IIS 設定與排程全部項目成套還原。** 涵蓋所有已發現 IIS 全域／階層設定、site／application／virtual directory／pool，以及完整 task XML／folder／安全與所有所選相依檔案。非 C 的網站／排程目錄同樣還原：來源 C 走主包、其他槽走跳板機工具，目標位置可為核准的非 C 磁碟。設定／物件與 C／非 C 結果同一工作負載追蹤，預設全選／可調整；缺角色／帳號／特殊能力或目的衝突明列待處理，保持停用直到驗證與啟用核准。

**還原前先檢查新主機，讓使用者選擇「確認缺口後直接還原」或「等待手動安裝選用的軟體，再檢查及還原」。** 直接還原先處理具備條件的所選資料／設定，需要產品 API／runtime 的操作保留待處理；操作結果與未完成清單持久保存，安裝後可重查及續跑。還原完成不代表環境或業務立即可用。

目前為 0.4 第三輪開發分支：已接上 schema 3 輔助契約、JSON 比較、來源 C 封裝／非 C 跳板搬移、逐項還原／修復、HTML 表單及可攜文件。每段以固定快照驗證及推送；本輪完整性與驗收證據見 [第三輪規劃](docs/MIGRATION-3-PLAN.md)。實機 Server／SMB／IIS／排程／業務與企業簽章資格仍為 NotTested。

第三輪依逐項實際基線續跑；等待、缺軟體、衝突與人工項不回報成功。封包後改選新版或目標子集只使相關目標比較及 receipt 失效，來源封存內容保持不變。

D3-01–08 保留特殊項揭露、必要 metadata／帳號映射、舊作業以原版本接續、材料保護、寫入前重查與同輪 final 停寫／hash 契約。沒有實機可用的項目以只讀環境探測取得觀察；探測成功不等於還原、業務或正式資格通過。

R3-20–25 涵蓋實際 workload 引用映射、共享資源／C 與非 C 目的排他、零 C 控制包、啟用後 BusinessFinal、OSProvided 實證及並行材料保護；沒有新增自動合併、安裝或非 IIS 產品 adapter。

### 搬移範圍與目前界限

本專案定位為企業內部**一般網站、Windows 排程及支援它們的服務主機 EOS 搬移**，不是資料庫、load balancer 或其他專業軟體服務主機搬移。Oracle Client、runtime、相依工具及使用者安裝軟體列完整清單：使用者從 HTML 文件中心及比較報告確認。軟體本體由使用者安裝，設定另列工具協助或外部處理，不因不搬軟體漏設定；非 IIS 本輪不新增產品專用還原 adapter。

[第三輪規劃](docs/MIGRATION-3-PLAN.md)維護原始定案、11 階段及全部反例。主工具封裝來源實體 C 槽的核准資料，非 C 來源由跳板工具搬移；目標盤符可依核准映射調整。兩通道共用目標實體身分與材料保護，不提供整機／System State 復原。

## 目前版本 0.4（隔離驗證）

已加入資料檔案／ACL 搬移包、內容去重與分卷 ZIP、固定來源／目標配對、規格核准、停用 staging、逐項設定及業務驗收、initial／final 差異 ZIP、切換計畫、啟用接續、回退與中斷修復。保留 0.2 的分類文件、分頁／跨頁規則／CSV 排除、版本衝突、跨主機相依與集中報告。

**第2輪程式閉環已補齊，最後固定快照回歸通過；尚未取得 Server 2016／2025 生產資格。** 執行功能限定使用者明確核准的隔離 pilot。未知產品保留為缺口或具責任與證據的專用流程；不會自動匯入整個 registry、執行包內腳本或啟動舊來源。實際資料、帳號密碼、憑證、企業設定不得放入這個公開 repository。

第2輪一般主機操作與資料格式見 [GENERAL-HOST-WORKFLOW.md](docs/GENERAL-HOST-WORKFLOW.md)：完整軟體／環境確認、Oracle effective設定與wallet外部處理、分階段準備證據、具原值復原的Windows設定、固定WorkRoot與ZIP／Directory交付。Source、Manager、Target使用自己的受控目錄；來源及目標交付模式需相符。每台完整MD／JSON／HTML／TXT／CSV會保留全部已發現列與探索缺口，文件回填不構成執行核准。
逐項 PLAN/TODO 比對、最後證據與外部待驗證見 [MIGRATION-2-VERIFICATION.md](docs/archive/MIGRATION-2-VERIFICATION.md)。

企業備份／還原情境及實際支援見 [ENTERPRISE-MIGRATION-COVERAGE.md](docs/ENTERPRISE-MIGRATION-COVERAGE.md)。專業／環境軟體本體在 HTML 清單列出，由使用者安裝；環境設定檔另列核准搬移／外部重建，ConfigFiles不是封裝白名單。本工具不提供整機／System State復原。

## 操作

以企業允許的方式部署同一份工具，使用系統管理員的 64 位元 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -File C:\MigrationTools\Start-ServerMigration.ps1 -Action Html -Role Manager -Workspace D:\MigrationWork
```

預設啟動本機 HTML 操作介面，僅綁定 127.0.0.1，關閉工具即停止。先選 Source／Manager／Target 與配對，再依盤點、匯入、審核、比較、封裝、還原及驗證步驟操作。操作需用本機 Windows PowerShell 5.1，沒有瀏覽器時加 `-Action Menu` 使用共用核心的文字選單。工作區含受控材料，必須依企業政策設權限及保留期限。

測試主機無法連線给代理時，角色精靈 6 或 `-Action LabReport -Role Source／Target -Path D:\MigrationLabReports` 產生可複製貼回的文字驗證報告及完整 JSON；先跑環境檢查，再提供可信搬移包驗證本機逐項 readback。操作步驟見手冊的「測試主機結果複製貼回」。

既有分類報告是離線快照，按100筆分頁，提供分類計數與搜尋；瀏覽器列印最多2,000筆。完整環境／軟體MD、JSON、TXT、CSV不使用這項列印截斷。遷移和切換仍限隔離 pilot，生產資格尚未驗收。

- [HTML 操作手冊](docs/ASSISTIVE-OPERATIONS.html)與[完整文件中心](docs/html/index.html)：TS 各角色、衝突／重查及交接；Markdown 留作開發來源。
- [操作手冊及資料契約](docs/OPERATIONS.md)：離線交換、規格／SID／機密、實際執行、重試與切換。
- [實作紀錄與當期外部待驗證](docs/IMPLEMENTATION-0.1.md)：目前 Phase 實作與保留的實機／企業／體檢項目。
- [第 3 輪規劃](docs/MIGRATION-3-PLAN.md)：輔助搬移、預設全選／自訂、所有功能／文件 HTML＋本機 PowerShell／文字備援、版本選擇／JSON、原設定路徑、不合併／無法放置清單、C 主包與非 C 小工具；實作與驗收狀態集中於規劃中的完整性核對。
- [歷史文件索引](docs/archive/README.md)：第 1／2 輪規劃、複審及驗證按需查閱；不作現行待辦或第 3 輪已完成證明。
- [完整環境／軟體確認表](docs/ENVIRONMENT-SOFTWARE-CONFIRMATION.md)：每台全量軟體、使用者／可攜環境、Oracle TNS_ADMIN／設定檔與目標驗證的 Markdown 格式；目前是模板，非真實 Server 清單。
- [正式資格／企業簽章信任／發行包](docs/RELEASE-QUALIFICATION.md)：精確 InstallationType／Oracle provider-consumer 維度、離線撤銷、signed-bytes 核驗；目前無實機或企業信任材料，production 仍 Blocked。
- [支援矩陣](docs/SUPPORT-MATRIX.json)、[SBOM](docs/RELEASE-SBOM.json)、[0.3.0 發行說明](docs/RELEASE-NOTES-0.3.md)與[復原 runbook](docs/RECOVERY-RUNBOOK.md)：隨 ToolRelease 一併封裝；不代表生產資格。

第2輪已完成程式實作。來源分類與管理端只讀範圍評估將一般工作負載、目標準備、Windows設定、特殊產品及未知分開；主選單23或 CLI `-Action ScopeAssessment -Workspace <工作區> -PairId <配對GUID>` 可查看。分類不改動 Include／Exclude，不證明相依已完成；完整軟體盤點、Oracle設定、準備門檻與新交付流程的逐段狀態見第2輪PLAN。

盤點 ZIP 只有設定證據；遷移 ZIP 才包含明確批准的 scope 資料。ZIP 不加密；可信 SHA256 須由獨立可信管道取得。工具不更改企業執行原則，憑證私鑰與密碼使用外部材料／記憶體 SecretRef。

## 非互動入口與測試

```powershell
.\Start-ServerMigration.ps1 -Action Inventory -DeepDiscovery -Path D:\MigrationEvidence
.\Start-ServerMigration.ps1 -Action Operation -Path D:\Requests\restore.json -ExpectedHash '<獨立可信SHA256>'
.\Start-ServerMigration.ps1 -Action ImportCsvPreview -Workspace D:\MigrationWorkspace -PairId '<PairId>' -Path D:\Review\decisions.csv
# 以預覽輸出的 SourceHash、DecisionRevision 呼叫 ImportCsv
.\Start-ServerMigration.ps1 -Action ImportCsv -Workspace D:\MigrationWorkspace -PairId '<PairId>' -Path D:\Review\decisions.csv -ExpectedHash '<SourceHash>' -ExpectedRevision <DecisionRevision>
powershell.exe -NoProfile -File .\tests\Test-MigrationPipeline.ps1
powershell.exe -NoProfile -File .\tests\Test-RecoveryContracts.ps1
```

測試的主機、排程、服务與網路 API 使用 fixture；檔案內容／ACL／ZIP／hash／journal 操作使用測試目錄。沒有實際改名、IP 切換或生產服務操作。模擬成功不能代替真實 Server、IIS、網域與業務驗收。CLI 0 表示該操作完成，不表示整台遷移完成；2 表示阻擋／人工證據或重開機仍待處理，1 失敗，3 安全取消，4 已分類的參數／格式錯誤。

## 有效且節省資源的測試

日常先跑受影響的腳本，已有相同程式、依賴、環境的有效結果就沿用。完整 Pipeline 預設 16 小檔、取消流程 8 檔、報告 2,501 筆、Fleet 十台各 200 筆、批次規格 200 筆；保留錯機／改包／排除／ACL／設定漂移／final／刪除／中斷／回退等必要檢查。不使用一萬小檔帶過所有故障劇本。

索引測試保留跨 5,000 筆分段的最小資料，避免漏驗分段排序與重複。實際 >4 GiB 是曾發現溢位的特殊邊界，獨立跑一次；本輪未改大檔的串流／chunk數值路徑，既有大檔邊界證據可沿用；新增gate另有回歸。PR 與 main／dev CI 不雙跑同一 feature commit，纯文件修改不觸發。

只有改動大量資料路徑或取得代表性工作量時，才明確指定更大規模；輸出時間與記憶體只是量測，不代表 Server 性能合格：

```powershell
# 特殊 64-bit 邊界：相關程式改動或交付前需要，既有相同版本有效結果可沿用。
powershell.exe -NoProfile -File .\tests\Test-LargePayload.ps1
# 以下是選擇性的定向數量驗證，不是每次全量回歸的預設。
powershell.exe -NoProfile -File .\tests\Test-Report.ps1 -ReportRows 100000
powershell.exe -NoProfile -File .\tests\Test-SpecScale.ps1 -Items 10000
powershell.exe -NoProfile -File .\tests\Test-FleetScale.ps1 -Hosts 10 -ItemsPerHost 10000
```

真實可行性先用一組代表性 Server 來源／目標，走實際入選項目的隔離還原、readback、業務檢查及一次回退；原生 API 與產品測試不能用合成數量取代。細節與已取消測試的理由在 docs/IMPLEMENTATION-0.1.md。
