# Windows Server Migration

PowerShell 本機盤點、離線集中審核與分階段遷移工具，主要目標 Server 2016 → 2025、約十台主機。各台本機執行，管理端彙整文件與結果，不要求 WinRM。

## 專案用途與第 3 輪方向

### 企業 EOS 搬移目標

提供企業 TS（技術支援／遷移操作人員）可操作、可交接的 Windows Server EOS 搬移流程，從兩台主機盤點、差異確認、目標準備、核准資料搬移，到隔離驗證、切換及回復都有明確步驟、責任與結果。TS 執行搬移及收集證據，使用者／應用負責人確認需要哪些軟體、相依與業務結果，平台／產品負責人處理授權、帳號、政策及專業產品事項。

第 3 輪必須交付下列可驗收結果：

1. **TS 能依文件完成操作與交接。** 每一步說明在哪台主機操作、前置條件、預期產出、如何確認成功、阻擋原因、下一步與回復方式；工具顯示檔案搬移、軟體準備與業務驗收各自的狀態。
2. **使用者知道兩台主機的軟體差異及要手動補什麼。** 新主機是全新安裝、只有 Windows Server 初始設定的主機；Windows 以目標系統為基準，其餘環境／軟體須由使用者安裝與來源相同的版本。程式自行產生及維護 JSON 比較資料庫，保存兩機盤點、差異及人工待辦。文件列出名稱、來源要求版本、目標實際版本、架構、位置、帳號範圍、責任人及結果；版本未知仍保留名稱與原因，不判定為已符合。
3. **舊文件仍能從舊路徑找到。** 對核准搬移的業務文件／資料及可搬設定，保留來源絕對路徑與相對結構，例如新主機仍可由 `C:\temp\report.csv` 存取舊文件。先前新版軟體換目錄的情境改為差異揭露／待修正：本輪以同版本環境為前提，不擴充自動升版相容或資料格式轉換。安裝位置、帳號及有效設定仍須確認，同版本不保證這些條件相同。
4. **每個缺口都有處置與責任。** 軟體本體、授權及不支援的產品設定由使用者／產品負責人補裝或重建；工具能搬的檔案與設定須有實際核驗。必要相依、人工待辦或業務驗證未完成時保留對應阻擋，文件勾選不構成執行或切換核准。

**還原前先檢查新主機並顯示軟體差異，讓使用者選擇「確認缺口後直接還原」或「等待手動安裝同版本軟體，再檢查及還原」。** 直接還原先處理具備條件的核准資料／設定，需要先安裝軟體的項目保留待處理；操作結果與未完成清單持久保存，安裝後可重新檢查及續跑。還原完成不代表環境或業務立即可用，也不免除後續同版本準備及必要驗證。

以上是第 3 輪目標，**尚未實作**：現行 0.3 尚無兩機軟體比較資料庫及上述分支，缺少必要軟體仍會阻擋整次還原。現有 FileScope 支援核准路徑映射，但不提供既有非工具持有目錄的合併。詳細契約、批次及待討論項目集中在 [第 3 輪規劃](docs/MIGRATION-3-PLAN.md)，本輪繼續規劃，不修改程式。

### 搬移範圍與目前界限

本專案定位為企業內部**一般網站、Windows 排程及支援它們的服務主機 EOS 搬移**，不是資料庫、load balancer 或其他專業軟體服務主機搬移。網站／排程需要的 Oracle Client、runtime、相依工具及使用者安裝軟體仍須完整列在每台 `.md` 供確認；軟體本體由使用者安裝，環境設定檔另列工具協助搬移或外部處理，不能因為不搬軟體而漏設定。

[第 3 輪規劃草案](docs/MIGRATION-3-PLAN.md)已記錄使用者定案：涵蓋網站／排程及其檔案相依；主工具只備份 C 槽的核准資料，其他槽提供跳板機直接輸入來源／目的的比對搬移小工具；版本可查就列，查不到仍保留清楚程式名稱與原因。**這些新增契約尚未實作，現行 0.3 不保證 C 槽限定，也尚無該小工具。** 本輪先討論規劃，不啟動程式修改；完整性必須有缺口揭露、檔案核驗與業務證據。

## 目前版本 0.3

已加入資料檔案／ACL 搬移包、內容去重與分卷 ZIP、固定來源／目標配對、規格核准、停用 staging、逐項設定及業務驗收、initial／final 差異 ZIP、切換計畫、啟用接續、回退與中斷修復。保留 0.2 的分類文件、分頁／跨頁規則／CSV 排除、版本衝突、跨主機相依與集中報告。

**第2輪程式閉環已補齊，最後固定快照回歸通過；尚未取得 Server 2016／2025 生產資格。** 執行功能限定使用者明確核准的隔離 pilot。未知產品保留為缺口或具責任與證據的專用流程；不會自動匯入整個 registry、執行包內腳本或啟動舊來源。實際資料、帳號密碼、憑證、企業設定不得放入這個公開 repository。

第2輪一般主機操作與資料格式見 [GENERAL-HOST-WORKFLOW.md](docs/GENERAL-HOST-WORKFLOW.md)：完整軟體／環境確認、Oracle effective設定與wallet外部處理、分階段準備證據、具原值復原的Windows設定、固定WorkRoot與ZIP／Directory交付。Source、Manager、Target使用自己的受控目錄；來源及目標交付模式需相符。每台完整MD／JSON／HTML／TXT／CSV會保留全部已發現列與探索缺口，文件回填不構成執行核准。
逐項 PLAN/TODO 比對、最後證據與外部待驗證見 [MIGRATION-2-VERIFICATION.md](docs/archive/MIGRATION-2-VERIFICATION.md)。

企業備份／還原情境及實際支援見 [ENTERPRISE-MIGRATION-COVERAGE.md](docs/ENTERPRISE-MIGRATION-COVERAGE.md)。專業／環境軟體本體只列Markdown由使用者安裝；環境設定檔另列核准搬移／外部重建，ConfigFiles不是封裝白名單。本工具不提供整機／System State復原。

## 操作

以企業允許的方式部署同一份工具，使用系統管理員的 64 位元 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -File C:\MigrationTools\Start-ServerMigration.ps1
```

選 1 盤點（可選深層探索），管理端選 2／3 建立工作區與匯入、4／6／7 審核和排除、5／8 輸出完整文件及十台總覽。選 **22 遷移角色精靈** 依管理／來源／目標角色操作後續階段。大批審核使用跨頁規則、CSV 與條件模板；CSV 必須先預覽，再以預覽回傳的 SHA256 和 DecisionRevision 套用。所有新項與設定漂移需要重新確認。角色精靈的來源 9／目標 15 操作增量 ZIP；執行畫面提供綁定配對、計畫、manifest、作業識別及狀態目錄的取消控制檔，另一本機終端可透過角色 5 請求在安全邊界停止。

測試主機無法連線给代理時，角色精靈 6 或 `-Action LabReport -Role Source／Target -Path D:\MigrationLabReports` 產生可複製貼回的文字驗證報告及完整 JSON；先跑環境檢查，再提供可信搬移包驗證本機逐項 readback。操作步驟見手冊的「測試主機結果複製貼回」。

既有分類報告是離線快照，按100筆分頁，提供分類計數與搜尋；瀏覽器列印最多2,000筆。完整環境／軟體MD、JSON、TXT、CSV不使用這項列印截斷。遷移和切換仍限隔離 pilot，生產資格尚未驗收。

- [操作手冊及資料契約](docs/OPERATIONS.md)：離線交換、規格／SID／機密、實際執行、重試與切換。
- [實作紀錄與當期外部待驗證](docs/IMPLEMENTATION-0.1.md)：目前 Phase 實作與保留的實機／企業／體檢項目。
- [第 3 輪規劃](docs/MIGRATION-3-PLAN.md)：全新 Windows 目標、同版本軟體／JSON 比較資料庫、還原前選擇、TS 交接及舊路徑、網站／排程相依、C 槽主包與其他槽小工具；全部 Phase 待實作。
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
