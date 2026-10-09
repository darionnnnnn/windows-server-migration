# Windows Server Migration 專案入口

- 流程路線：完整。此工具涉及跨主機設定、權限、資料與分階段驗收。
- 工作目錄：本目錄。使用者要求遷移程式碼集中於此。
- 現況與規劃入口：[README.md](README.md)、[第 1 輪規劃](docs/MIGRATION-1-PLAN.md)。
- 2026-10-08 使用者已授權開始實作 R2 規劃。依 A–F 分階段交付；這項授權不代表可操作尚未指定的實際來源／目標伺服器。
- 現況：0.3 持續補實作中，已加入 D/E/F 的隔離 pilot 核心、角色精靈與故障修復，未完成全部規劃或實機資格。逐項證據與未完成項目見 docs/IMPLEMENTATION-0.1.md，操作契約見 docs/OPERATIONS.md。不得以 fixture 代替真實 Server／產品／业务驗收。
- 主要環境為 Windows Server 2016 → 2025，其他來源版本尚待盤點；新主機先使用不同名稱與 IP，驗證後才接手舊身分。
- 實機驗收需要 Windows Server 測試環境。語法檢查、模擬測試、實機測試分別標示，不可互相代替。
- 所有新功能與測試對照 PLAN 分階段交付；只有已實作且驗證的模組才可標示支援自動還原。
- 核准計畫綁定全部 src 與入口的實際 bytes。並行實作時，含核准／封裝／還原的測試必須使用獨立固定程式快照；測試啟動後禁止覆寫該快照的程式檔，結束核對雜湊未變。共享工作區的 PASS 不代替此證據。
- 專案規劃與規格文件留在本專案 docs；不歸入個人說明文件歸檔區。
- 正式執行程式 checkpoint：10c896a；GitHub CI 37792481411 全部工作通過（54 個測試腳本）。本輪調整測試與 CI，受影響五腳本已在 WinPS 5.1／PS7 各 5/5 通過，src／入口未改；10k 小檔全劇本已按使用者要求排除並停止，不計 PASS；真正 Server／產品資格仍待結果。
- 使用者的隔離 Server 無法讓代理連線；本機角色選單 6／CLI LabReport 已交付 JSON 與可複製貼回的 TXT。環境檢查與核准包 readback 分開，人工／業務證據仍 NotTested，ProductionVerified=false；先依回傳證據判讀，不假造實機通過。
- 測試採分層／影響範圍重驗；Pipeline 預設16檔、取消8檔、報告2501筆、Fleet十台各200、Spec200。5000索引分段與4GiB特殊邊界保留；不要為宣稱完成重跑無門檻的長時間大數量全劇本。

- 2026-10-09 下一輪入口：docs/MIGRATION-2-PLAN.md（規劃中，尚未實作）。聚焦一般服務主機；runtime／軟體／必要角色只列離線準備清單由使用者安裝，特殊產品保留告知與外部相依確認，Windows 系統設定逐項選擇。不把計畫方向寫成已交付行為。
- 前一輪測試效率調整段落已完成：349195c 遠端一致；CI 37800134683 全部通過。整體舊 PLAN 的實機／業務資格及獨立體檢仍未完成。
- GitHub 每段完成先檢查範圍／相依／影響並適當驗證，再於本輪分支 commit／push，確認遠端 SHA；不 force push 或自行 merge。
- 2026-10-09 第2輪深度複審：docs/MIGRATION-2-REVIEW.md 的20項缺口已納入 PLAN 必要契約，包含完整機器／使用者／可攜軟體 Markdown、Oracle client／TNS_ADMIN／設定檔、實際consumer與企業資格／放行包。docs/ENVIRONMENT-SOFTWARE-CONFIRMATION.md 為格式模板，非已取得Server盤點。此輪只改文件，新增功能及正式資格仍未完成；Oracle DB／listener 保留特殊產品外部流程，不能一併排除一般應用client相依。
- 2026-10-09 輸出續規劃見 PLAN D2：建議先指定受控WorkRoot，再選sealed資料夾或分卷ZIP（預設512MiB、新UI自訂128–1024MiB）；reports直接可讀，state／機密不混入交付。API原1MiB–1GiB與舊fixtures保留；9,999卷／峰值空間／全卷hash／缺卷阻擋／delivery索引尚需接線驗證，此次仍只改規劃。
- 2026-10-09 再次反向複審基準247c528：PLAN／REVIEW另補R2-21–R2-28，累計28項。D2以穩定host／pair state配獨立attempt，配對前先enrollment；資料夾改白名單乾淨副本，delta新增分卷與scratch預算；既有TNS／設定用Create／Keep／External／受驗UpdateReviewed與prior回復；gate用RequiredPhase／投影hash；文件DocumentId／固定delivery與receipt分開；壞卷重封新transport hash；JSON／index／RAM限制明列。此輪仍僅文件，這些契約尚需實作驗收，不自動開啟生產或假造資格。
