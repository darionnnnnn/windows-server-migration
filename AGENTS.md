# Windows Server Migration 專案入口

- 流程：完整；本輪先討論 [MIGRATION-3-PLAN.md](docs/MIGRATION-3-PLAN.md)，全部 R3 Phase 待實作，不從規劃指示推論已授權開發。現行能力與外部待驗收見 [IMPLEMENTATION-0.1.md](docs/IMPLEMENTATION-0.1.md)；歷史規劃／複審／逐 Phase 證據見 [封存索引](docs/archive/README.md)，按需讀取，不作當期待辦。
- 現況：0.3 第2輪 A0/A1、B1/B2、C、D/D2、E1–E3 程式及契約閉環已實作；兩引擎回歸與 GitHub CI 通過。外部 Server／Oracle／企業 PKI／業務／規模驗收及可核實的不同模型體檢未完成，ProductionVerified=false。
- 使用範圍：一般內部網站／Windows排程及支援服務主機，主要 Server 2016 → 2025；不做資料庫、load balancer或其他專業軟體服務主機遷移。R3目標是企業TS可操作／交接、兩機軟體差異與人工待辦、舊路徑可找到核准文件。新主機全新Windows初始狀態；除Windows外軟體須同來源版本，不以新版相容代替；程式沿用配對JSON資料庫維護比較。還原前檢查目標，由使用者選直接還原或等手動補裝後還原；還原不保證立即可用，待軟體項須durable deferred／重查續跑，不能用全域跳過gate或假成功。局部Windows元件／未知版本／衝突策略先討論。R3 PLAN列R3-01–08及全部批次，均本輪處理、尚未實作。C槽來源限定＋非C小工具、完整相依及版本未知保留名稱仍適用；軟體本體使用者安裝，設定另列搬移／外部處理，不擴整機備份或自動升版。
- 操作与契約：[README.md](README.md)、[GENERAL-HOST-WORKFLOW.md](docs/GENERAL-HOST-WORKFLOW.md)、[OPERATIONS.md](docs/OPERATIONS.md)。新規劃待辦集中於R3 PLAN；既有外部驗收待辦仍在 [IMPLEMENTATION-0.1.md](docs/IMPLEMENTATION-0.1.md)；完整軟體確認模板不是實際 Server 清單。
- 每台 Source／Manager／Target 使用專用固定 WorkRoot。交付選 sealed Directory 或 ZIP，預設512MiB，UI整數128–1024MiB；attempt不重建state。WorkRoot搬移須停工具、預覽、核對、明確確認及受控回復，不是跨機遷移或備份。
- 核准綁定全部src和入口實際bytes；執行中pair不能熱換工具。含核准／封裝／還原的測試使用不可變快照，測試前後核對runtime/test hashes；共享工作區局部PASS不是整輪證據。
- 分層驗證：Pipeline16小檔、取消8檔、報告2501列、Fleet十台各200、Spec200；保留跨5000索引及真實4GiB邊界，不重跑無效的一萬小檔全故障劇本。同程式、依賴、環境及覆蓋範圍的有效證據可沿用。
- 實際來源／目標主機須另有指派；隔離主機可用角色6／CLI LabReport回傳JSON與TXT。fixture、命令成功或報告摘要不能代替原生readback及業務接受。
- 專案現況文件及當期PLAN留在docs；已結束輪次的規劃、一次性複審與驗證歷程以git mv封存至docs/archive並維護索引／引用。公開repository不納入真實盤點、機密、憑證私鑰或根目錄個人prototype `Get-ServerMigrationInventory.ps1`，不讀取或修改該prototype。
- GitHub每段完成後驗證、commit/push并核對遠端SHA。2026-10-10使用者授權本輪收尾整合至dev及刪除codex/implementation；不改main、不force push，保留他人未提交工作。
- 本輪收尾使用主代理直接審查；使用者指定的opus low不在可用subagent清單中，不靜默替換模型。模型身分不明時不宣稱符合不同模型獨立體檢。
