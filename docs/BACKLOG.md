# 待辦（定案不做、日後可能做）

這裡列出經評估後定案「目前不做」的項目，每項都附上重新評估的觸發條件。條件成立時再開新規劃，不在現行版本中暗中補做。

## 安全與信任邊界

- **本機 HTTP 工作台的連線身分檢查**
  - 現況：工作台的 token 只能防瀏覽器跨站，無法防同一台機器上的其他使用者或程序讀取 `/api/session`。
  - 日後做法：檢查連線端 PID 的擁有者 SID，或改用 named pipe。
  - 觸發條件：工具需要在多工作階段主機（例如 RDS、多管理者同時登入）上開啟工作台。
- **Takeover 的 Revision CAS 恆等式**
  - 現況：同一使用者重複接手時，Revision 比對可能恆等；自寫入的解釋判定也不分 parent。
  - 觸發條件：出現同一使用者在多個工作階段同時接手同一作業的實際需求或事故。

## 獨立副本與媒體

- **IndependentCopy 單檔取消邊界與 UNC 逾時**
  - 現況：單一檔案的 Copy 與雜湊過程中沒有取消邊界，UNC 目的地也沒有逾時。
  - 觸發條件：實機媒體驗收發現大檔或網路媒體造成無法取消或長時間卡住。

## 實機與環境

- **非提權環境續作時，FileScope 項目被降為 Failed**
  - 現況：讀取 owner 或 DACL 時遇到 PrivilegeNotHeld。
  - 觸發條件：提權環境的實機驗收（列入實機驗收清單）；若提權環境仍重現，就改為修正。
- **PS7 雙引擎、實機與企業驗收**：目前只在 Windows PowerShell 5.1 與隔離 fixture 驗證。
  - 觸發條件：取得 PS7 環境、實機或企業測試環境。
- **第六輪基準就失敗的測試**：AssistiveWorkloadIntegration、FleetExecutionBindings、FullDirectoryImport、ObservationWorkflow、ShareSourceWorkflow、WorkspaceWorkerIsolation、ZipColdStart、WorkspaceLockContention。
  - 觸發條件：要把 GitHub 的 `required-checks` 設為必要檢查之前，必須先修好。

## 功能範圍

- **15.5-6 記錄使用者原放置位置**
  - 現況：只比對已驗證的 Package.Root，不記錄使用者原本把封裝放在哪裡。
  - 觸發條件：出現需要回溯封裝原始位置的稽核需求。
- **軟體決策值改為三值**
  - 現況：維持六值加 Undecided，對照說明見 PLAN 18.5。
  - 觸發條件：使用者回饋六值難以理解。
- **SoftwareCatalog 加入 InstallDate**
  - 現況：沒有可信來源。
  - 觸發條件：找到可信且一致的安裝日期來源。
- **補登真實來源路徑的專用介面**
  - 現況：路徑無法解析的項目，目前要靠重新盤點或候選確認流程補登。
  - 觸發條件：實務上未解析路徑的項目多到重新盤點不划算。
- **C2／D2 Manager 候選清單的手動備援**：目前不做。
  - 觸發條件：候選掃描在實機上常見失敗。
- **D1 完整的 opaque-path 矩陣**：維持為 open issue。
  - 觸發條件：實機遇到目前矩陣未涵蓋的遮蔽路徑型態。

## 測試工具

- **Test-PlanEvidence 對 in-progress 階段的過期警告**
  - 現況：工具不驗證 in-progress 階段的雜湊。
  - 觸發條件：帳本因 in-progress 階段過期而造成實際誤判。
- **SourceCandidateDiscovery 的測試注入 scriptblock 參數**
  - 現況：保留，並在程式內加註解說明用途。
  - 觸發條件：需要移除所有正式碼中的測試注入點時。
