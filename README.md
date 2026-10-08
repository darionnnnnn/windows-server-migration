# Windows Server Migration

PowerShell 本機盤點、離線集中審核與分階段遷移工具，主要目標 Server 2016 → 2025、約十台主機。各台本機執行，管理端彙整文件與結果，不要求 WinRM。

## 目前版本 0.3

已加入資料檔案／ACL 搬移包、內容去重與分卷 ZIP、固定來源／目標配對、規格核准、停用 staging、逐項設定及業務驗收、final generation、切換計畫、回退與中斷修復。保留 0.2 的分類文件、分頁／跨頁規則／CSV 排除、版本衝突、跨主機相依與集中報告。

**仍在補實作及驗證，未完成全計畫，也未取得 Server 2016／2025 生產資格。** 執行功能限定使用者明確核准的隔離 pilot。未知產品保留為缺口或具責任與證據的專用流程；不會自動匯入整個 registry、執行包內腳本或啟動舊來源。實際資料、帳號密碼、憑證、企業設定不得放入這個公開 repository。

## 操作

以企業允許的方式部署同一份工具，使用系統管理員的 64 位元 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -File C:\MigrationTools\Start-ServerMigration.ps1
```

選 1 盤點（可選深層探索），管理端選 2／3 建立工作區與匯入、4／6／7 審核和排除、5／8 輸出完整文件及十台總覽。選 **22 遷移角色精靈** 依管理／來源／目標角色操作後續階段。大批審核使用跨頁規則、CSV 與條件模板，所有新項與設定漂移需要重新確認。

- [操作手冊及資料契約](docs/OPERATIONS.md)：離線交換、規格／SID／機密、實際執行、重試與切換。
- [逐項實作與未完成清單](docs/IMPLEMENTATION-0.1.md)：A–F／R01–R16 對照與證據。
- [原始規劃與驗收條件](docs/MIGRATION-1-PLAN.md)：不因已寫程式而刪除驗收要求。

盤點 ZIP 只有設定證據；遷移 ZIP 才包含明確批准的 scope 資料。ZIP 不加密；可信 SHA256 須由獨立可信管道取得。工具不更改企業執行原則，憑證私鑰與密碼使用外部材料／記憶體 SecretRef。

## 非互動入口與測試

```powershell
.\Start-ServerMigration.ps1 -Action Inventory -DeepDiscovery -Path D:\MigrationEvidence
.\Start-ServerMigration.ps1 -Action Operation -Path D:\Requests\restore.json -ExpectedHash '<獨立可信SHA256>'
powershell.exe -NoProfile -File .\tests\Test-MigrationPipeline.ps1
powershell.exe -NoProfile -File .\tests\Test-RecoveryContracts.ps1
```

測試的主機、排程、服务與網路 API 使用 fixture；檔案內容／ACL／ZIP／hash／journal 操作使用測試目錄。沒有實際改名、IP 切換或生產服務操作。模擬成功不能代替真實 Server、IIS、網域與業務驗收。CLI 0 表示該操作完成，不表示整台遷移完成；2 表示阻擋／人工證據或重開機仍待處理，1 失敗，3 安全取消，4 已分類的參數／格式錯誤。