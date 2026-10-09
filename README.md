# Windows Server Migration

PowerShell 本機盤點、離線集中審核與分階段遷移工具，主要目標 Server 2016 → 2025、約十台主機。各台本機執行，管理端彙整文件與結果，不要求 WinRM。

## 目前版本 0.3

已加入資料檔案／ACL 搬移包、內容去重與分卷 ZIP、固定來源／目標配對、規格核准、停用 staging、逐項設定及業務驗收、initial／final 差異 ZIP、切換計畫、啟用接續、回退與中斷修復。保留 0.2 的分類文件、分頁／跨頁規則／CSV 排除、版本衝突、跨主機相依與集中報告。

**第2輪程式閉環已補齊，最後固定快照回歸通過；尚未取得 Server 2016／2025 生產資格。** 執行功能限定使用者明確核准的隔離 pilot。未知產品保留為缺口或具責任與證據的專用流程；不會自動匯入整個 registry、執行包內腳本或啟動舊來源。實際資料、帳號密碼、憑證、企業設定不得放入這個公開 repository。

第2輪一般主機操作與資料格式見 [GENERAL-HOST-WORKFLOW.md](docs/GENERAL-HOST-WORKFLOW.md)：完整軟體／環境確認、Oracle effective設定與wallet外部處理、分階段準備證據、具原值復原的Windows設定、固定WorkRoot與ZIP／Directory交付。Source、Manager、Target使用自己的受控目錄；來源及目標交付模式需相符。每台完整MD／JSON／HTML／TXT／CSV會保留全部已發現列與探索缺口，文件回填不構成執行核准。
逐項 PLAN/TODO 比對、最後證據與外部待驗證見 [MIGRATION-2-VERIFICATION.md](docs/MIGRATION-2-VERIFICATION.md)。

## 操作

以企業允許的方式部署同一份工具，使用系統管理員的 64 位元 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -File C:\MigrationTools\Start-ServerMigration.ps1
```

選 1 盤點（可選深層探索），管理端選 2／3 建立工作區與匯入、4／6／7 審核和排除、5／8 輸出完整文件及十台總覽。選 **22 遷移角色精靈** 依管理／來源／目標角色操作後續階段。大批審核使用跨頁規則、CSV 與條件模板；CSV 必須先預覽，再以預覽回傳的 SHA256 和 DecisionRevision 套用。所有新項與設定漂移需要重新確認。角色精靈的來源 9／目標 15 操作增量 ZIP；執行畫面提供綁定配對、計畫、manifest、作業識別及狀態目錄的取消控制檔，另一本機終端可透過角色 5 請求在安全邊界停止。

測試主機無法連線给代理時，角色精靈 6 或 `-Action LabReport -Role Source／Target -Path D:\MigrationLabReports` 產生可複製貼回的文字驗證報告及完整 JSON；先跑環境檢查，再提供可信搬移包驗證本機逐項 readback。操作步驟見手冊的「測試主機結果複製貼回」。

既有分類報告是離線快照，按100筆分頁，提供分類計數與搜尋；瀏覽器列印最多2,000筆。完整環境／軟體MD、JSON、TXT、CSV不使用這項列印截斷。遷移和切換仍限隔離 pilot，生產資格尚未驗收。

- [操作手冊及資料契約](docs/OPERATIONS.md)：離線交換、規格／SID／機密、實際執行、重試與切換。
- [實作紀錄與當期外部待驗證](docs/IMPLEMENTATION-0.1.md)：第一輪歷史、已完成程式及保留的實機／企業／體檢項目。
- [原始規劃與驗收條件](docs/MIGRATION-1-PLAN.md)：保留歷史需求；本輪範圍變更以第 2 輪為準。
- [第 2 輪規劃](docs/MIGRATION-2-PLAN.md)：一般服務主機、離線準備、Windows 決策、Oracle設定與D2輸出目錄／可自訂大小分卷ZIP／資料夾交付；各項程式比對與實機資格狀態見文件末尾。
- [第 2 輪深度複審](docs/MIGRATION-2-REVIEW.md)：累計28項企業 EOS 規劃缺口；再次按角色反查，補穩定作業狀態、增量分卷、白名單資料夾、既有設定回復、分階段gate與交付版本；尚非功能或正式資格通過。
- [完整環境／軟體確認表](docs/ENVIRONMENT-SOFTWARE-CONFIRMATION.md)：每台全量軟體、使用者／可攜環境、Oracle TNS_ADMIN／設定檔與目標驗證的 Markdown 格式；目前是模板，非真實 Server 清單。
- [正式資格／企業簽章信任／發行包](docs/RELEASE-QUALIFICATION.md)：精確 InstallationType／Oracle provider-consumer 維度、離線撤銷、signed-bytes 核驗；目前無實機或企業信任材料，production 仍 Blocked。
- [支援矩陣](docs/SUPPORT-MATRIX.json)、[SBOM](docs/RELEASE-SBOM.json)、[0.3.0 發行說明](docs/RELEASE-NOTES-0.3.md)與[復原 runbook](docs/RECOVERY-RUNBOOK.md)：隨 ToolRelease 一併封裝；不代表生產資格。

第2輪開始分段實作。來源分類與管理端只讀範圍評估將一般工作負載、目標準備、Windows設定、特殊產品及未知分開；主選單23或 CLI `-Action ScopeAssessment -Workspace <工作區> -PairId <配對GUID>` 可查看。分類不改動 Include／Exclude，不證明相依已完成；完整軟體盤點、Oracle設定、準備門檻與新交付流程的逐段狀態見第2輪PLAN。

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

索引測試保留跨 5,000 筆分段的最小資料，避免漏驗分段排序與重複。實際 >4 GiB 是曾發現溢位的特殊邊界，獨立跑一次；本輪正式遷移程式未改，可沿用既有結果。PR 與 main CI 不雙跑同一 feature commit，纯文件修改不觸發。

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
