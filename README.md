# Windows Server Migration

以 PowerShell 協助約十台企業 Windows Server 的本機盤點與離線集中審核。主要規劃為 Server 2016 → 2025；新主機先用不同名稱／IP，驗證後接手舊身分。

## 實作現況：0.1 第一階段

已提供繁體中文選單、來源盤點 JSON／ZIP、固定來源識別、集中主機配對、分類／搜尋／分頁、納入與排除理由、批次 CSV、撤銷、設定變動重新審核、必要相依項目檢查、離線 HTML 與多主機報告、核准審核文件及 SHA256 驗證。

**目前不是完整遷移或還原工具。** 盤點 ZIP 只有設定證據，不含網站／服務檔案、資料庫、私鑰或帳號密碼。所有納入項目目前仍需要人工遷移；核准文件只代表 `ReviewComplete`，`ExportReady` 固定為 false。尚未提供來源停寫、資料搬移包、目標還原、最終差異、切換或退役功能。

本階段依 [R2 計畫](docs/MIGRATION-1-PLAN.md) 建立 A/B/C 的基礎；仍有 A/B/C 驗收缺口，詳見 [操作與驗證紀錄](docs/IMPLEMENTATION-0.1.md)。舊版 `Get-ServerMigrationInventory.ps1` 是本機探索原型，未列入這個版本，不要拿它當成正式還原流程。

## 開始操作

把整個專案目錄複製到各來源主機。使用系統管理員身分開啟 **64 位元 Windows PowerShell 5.1**：

```powershell
powershell.exe -NoProfile -File C:\MigrationTools\Start-ServerMigration.ps1
```

若執行原則拒絕，依企業的簽章／執行政策處理。工具不會自動修改執行原則。

來源端選「1 本機來源盤點」，每台主機固定使用同一個受控輸出目錄。管理端選「2 建立管理工作區」→「3 匯入盤點」→「4 審核／排除」。大量項目使用選項 6／7 的 CSV 批次處理，再輸出選項 5 的分類文件與選項 8 的全批次報告。

ZIP 非加密；task XML、IIS 設定可能含敏感資訊。保留於企業允許的受控儲存及傳輸管道，**不要提交實際盤點到這個公開 GitHub 儲存庫**。管理端匯入的是解壓後 JSON；SHA256 應由可信管道取得，同一包內的雜湊只能協助發現意外毀損，不能證明來源可信。

## 非互動操作

```powershell
# 各來源本機執行；同一台固定同一目錄以延續來源識別／版本。
.\Start-ServerMigration.ps1 -Action Inventory -Path D:\MigrationEvidence

# 管理端只處理本機資料，不需 WinRM。
.\Start-ServerMigration.ps1 -Action Initialize -Workspace D:\MigrationReview
.\Start-ServerMigration.ps1 -Action Import -Workspace D:\MigrationReview `
  -Path D:\Inbox\inventory-1.json -ExpectedHash '<可信的64字元SHA256>' -TargetName NEW-SERVER-01
# 匯入輸出 PairId；後續命令使用這個值。
.\Start-ServerMigration.ps1 -Action Report -Workspace D:\MigrationReview `
  -PairId '<PairId>' -Path D:\Reports\server01.html
.\Start-ServerMigration.ps1 -Action FleetReport -Workspace D:\MigrationReview -Path D:\Reports\fleet.html
```

輸出文件的父目錄須先建立。非互動操作遇到錯誤回傳退出碼 1；成功退出碼 0 不代表已完成遷移。`Inventory` 即使查詢部分失敗仍保留可用結果，必須查看輸出的 `Incomplete` 與每個項目的 `Status`。

## 驗證

```powershell
powershell.exe -NoProfile -File .\tests\Test-Contracts.ps1
powershell.exe -NoProfile -File .\tests\Test-InventoryFixture.ps1
pwsh -NoProfile -File .\tests\Test-FleetScale.ps1 -Hosts 10 -ItemsPerHost 10000
```

測試使用合成資料／替代 OS 查詢，不會盤點測試電腦或修改系統服務。真實 Server 2016／2025 的盤點與目標還原驗收尚未進行。離線報告顯示收到資料的時間與資料年齡，不能當成即時主機狀態。
