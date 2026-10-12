# 0.4 實作狀態與外部驗證

更新：2026-10-12。本文件維護當前能力與外部待辦；第五輪逐項實作及驗收證據見[第五輪 PLAN](plans/MIGRATION-5-PLAN.md)，前輪紀錄見[第四輪 PLAN](plans/MIGRATION-4-PLAN.md)與[第三輪 PLAN](MIGRATION-3-PLAN.md)。第五輪仍在實作，不代表所有精靈流程已完成；操作模板中的核對勾選仍由使用者依真實證據完成。

## 第五輪目前狀態（進行中）

| 範圍 | 已有程式與證據 | 尚未完成的部分 |
|---|---|---|
| 啟動與引導 | `Start-ServerMigration.cmd` 可雙擊啟動 x64 Windows PowerShell 5.1；真 Edge 透過正式 PowerShell handler 已驗證用途選擇、精靈步驟版本檢查，以及 Manager 對隔離盤點資料的分組選取、保存、返回與排除理由。 | 不涵蓋實際備份封裝、非 C 傳輸及目標還原的完整旅程。啟動器不繞過執行政策；被封鎖時須依企業程序核准。 |
| 精靈與選取 | 精靈狀態、角色工作區綁定、可信盤點來源、revision/CAS 保存、批次選擇及已選結果投影已接入核心。 | 檔案明細正式 worker/UI 完整接線、重新掃描保留排除、混合共享相依與完整管理準備／來源意圖交接仍在補齊。 |
| 備份 E | 現有核心仍要求 sealed plan、真實目標身分及有效核准；文件／選取結果不等於已封裝的備份。 | 自動備份編排、C 與非 C 實際成果核驗、失敗／續作摘要及真實產物檢查尚未完成。 |
| 交接與還原 F | 已有受信核准計畫讀取及材料身分檢查；還原與啟用在核心中各自受核准與明確確認 gate 控制。 | E 產物交接、目標還原精靈、deferred／續作流程及完整目標旅程尚未完成。自動備份或按「下一步」不授權還原或啟用。 |
| 開發者環境探測 G | 有獨立收集器與本機 CLI 備援；產生 ZIP、匿名化 `probe.json`、HTML 摘要，原始盤點留在受保護本機目錄，不自動上傳。 | 真實完整 collector 兩引擎驗證仍在進行；隔離 runspace 的 CIM 模組載入失敗已列阻擋，必須以未注入 collector 的本機讀回補證。 |

原生工作台橋接曾驗證動態資源、正式 handler 的讀取／可逆保存；後續真 Edge journey 以隔離盤點資料驗證精靈選取。這些結果已修正第四輪「動態工作台完整旅程尚未通過」過時概括，但**不代表完整備份或還原旅程已通過**。原始傳輸完整性仍是 NotPassed；Node mock、fixture 及隔離資料不能替代各自未驗的原生路徑或企業主機。

一般流程使用「舊主機」「新主機」「整理搬移資料的電腦」及「開始／下一步」導引。支援範圍限於工具已支援的資料與設定；不包含整機映像、作業系統、System State 或軟體本體。非 C 槽資料遵循既有核准及跳板通道。開發者探測只做唯讀觀測，不能修改搬移權威狀態或代表生產資格。

## 第四輪 A–E 現況（基線）

| Phase | 已實作行為與整合位置 |
|---|---|
| A | 鎖內 revision／資料版本投影、上下文及快取失效、非秘密草稿、同一 OperationId 的結果查詢；並行保存不覆蓋第一筆待確認紀錄 |
| B | 總覽依 catalog、目前世代階段結果及交付收據呈現來源、時間、阻擋與下一步；C／非 C、軟體準備、檔案讀回及業務接受分開 |
| C | 八頁 hash 導覽、返回／前進、焦點及分頁；角色任務接同一 typed 表單，完整進階操作仍可到達 |
| D | 頁內提示、繁中角色教學、完整操作手冊及分類文件中心；盤點明列 Windows Server／管理員／64 位 PowerShell／FullLanguage 前提 |
| E | 正式產生 HTML、排除 PLAN HTML／archive、文件路由、工具指紋及實際 ZIP manifest／來源 hash／本地連結核對 |

本輪沒有引入另一套執行引擎、遠端服務或前端框架。資料與核准仍由既有 PowerShell 核心、CAS、journal、sealed plan／receipt 及 Windows 身分決定；UI 角色與文件勾選不授權執行。

可驗證範圍有版本化的 212 項引擎案例通過覆蓋，包含初次逾時／失敗後的修正與定向重驗，**不是單次最終快照全量通過**。補漏另有 WinPS5.1／PS7 的 16/16 相關驗證；收尾並行保存修正有 46 項前端測試、Edge 模擬 API 的 2,501 列劇本與 8/8 雙引擎整合／文件／資格／編碼驗證。各項適用版本、環境與 CI 結果集中 PLAN，不以舊 PASS 代替新 bytes 的驗證。

第四輪在 AdGuard 環境的原始傳輸完整性為 **NotPassed**：當時本機 probe 觀察到回應被改寫，真實 IAB 僅確認初始 HTML 可見。第五輪另有正式 handler／Edge 的有限讀取、保存與精靈選取證據（見上節），因此不應再把「動態工作台一概未通過」當成最新描述。原始傳輸差異仍未被宣稱解決；靜態 guide、文字選單及 CLI 提供備援。

外部 Server／SMB／IIS／排程／帳號／業務／PKI／規模驗收仍為 **NotTested**。ProductionVerified=false、ProductionExecutionEnabled=false，發行包未簽署；隔離測試或唯讀探測不解除正式資格限制。

## 既有核心與第二輪 Phase

第三輪 Schema 3 輔助 catalog／plan／receipt、軟體比較、C 主包／非 C 跳板搬移、共享 reservation／材料保護、逐項還原、IIS／task 停用 staging、部分世代／delta 及復原已接入。HTML worker 使用同一核心；Node／Edge 僅是開發驗證工具。完整 producer→consumer 與前輪修正證據保留於第三輪 PLAN，不在現況文件重述各次測試過程。

| Phase | 現行實作與消費端 |
|---|---|
| A0/A1 | 來源分類、受審處置、Schema2 GeneralHost、型別化準備／外部相依與逐階段gate；catalog／review／restore／delta／cutover／Fleet／LabReport共同消費 |
| B1 | HKLM／可讀HKU／portable／app-local／人工軟體及coverage、媒體與安裝順序／副作用；每台全量MD／JSON／HTML／TXT／CSV |
| B2 | Oracle client與engine分界、exact provider／consumer、有效TNS_ADMIN與service REG_MULTI_SZ、精確IFILE閉包、wallet外部程序、ConfigFiles審核及readback |
| C | Windows設定差異專頁、整類選否與逐設定必要相依、Create／Keep／External／UpdateReviewed、型別／空值／DST prior復原、GPO／Unknown阻擋、catalog單次CAS |
| D/D2 | 固定WorkRoot／enrollment／attempt、全量與增量ZIP／Directory、容量及成員預算、不可變DocumentId／DeliveryId、實際匯入收據與Manager／Fleet／LabReport；受控WorkRoot搬移及中斷回復 |
| E1 | schema／plan／approval／journal／ownership／tool指紋相容、新producer-consumer與CLI／API／選單接線、WhatIf純預覽 |
| E2 | 停寫與來源擷取重驗、fencing／唯一writer、新交易回退／對帳、source resume、觀察及具名退役；真實跨台協調待驗收 |
| E3 | exact OS/runtime／Oracle tuple、release／SBOM／support、CMS／Crypt32離線信任與撤銷拒絕流程；有效企業鏈及正式放行待驗收 |

既有generic adapters及operation journal／workspace transaction保留。ManualWorkflow不是產品自動還原能力；runtime／第三方安裝維持使用者準備。操作契約見 [OPERATIONS.md](OPERATIONS.md) 與 [GENERAL-HOST-WORKFLOW.md](GENERAL-HOST-WORKFLOW.md)。ProductionExecutionEnabled及ProductionVerified維持false。

## 當期待辦：外部驗收
- [ ] 代表性來源／目標及完整十台盤點：owner、產品／runtime／軟體清單、媒體、scope、容量、RPO/RTO與維護窗。
- [ ] 實際Server2016／2025／Core、語系、32bit runtime、policy／權限及provider的collector／export／restore／verify矩陣；補產品原生錯誤分類及正反例。
- [ ] 原生IIS／SCM／任務／分享／憑證／帳號／服務帳號模式、安裝副作用、reboot後readback，及名稱／IP／DNS／Kerberos／網域切換。
- [ ] Oracle exact provider／consumer／runtime帳號的TNS_ADMIN、DB／TCPS與業務驗證；企業有效信任鏈、撤銷材料、簽章／批准及正式資格。
- [ ] 代表性封裝→還原量測耗時、容量、尖峰記憶體與維護窗；既有4GiB邊界不等於企業效能，長路徑目前明確阻擋。
- [ ] 單台pilot、相依雙台及十台波次：真實freeze／fencing／activation／新交易回退／source resume／唯一writer、業務接受、觀察、備份實還原與退役批准。
- [ ] 真實瀏覽器與主控台完整備份→交接→目標還原旅程；已驗證的有限精靈選取旅程、Node DOM 或 CLI fixture 不能代替尚未完成的 E／F 真實接線。

使用者的隔離 Server 無法讓代理直接連線，目前尚未收到真實清單／LabReport及企業材料。不能以合成測試補作這些證據，也不刪除原始驗收需求。

## 測試與交付規則

ToolRelease 收錄 README、docs 頂層文件與手冊資產、docs/html 使用者投影及支援／SBOM JSON；不遞迴收錄 archive 或 docs/plans，PLAN HTML 不進路由／索引／新發行包。既有頂層第三輪 PLAN Markdown 保留原交付契約，歷史引用仍需回專案原始碼查閱。

UI／src／入口 bytes 變更會更新 ToolFingerprint，執行中配對須以原版工具接續，不能熱換 UI。純文件變更不改工具指紋，但會更新發行包與文件 hash；新包必須核驗最終 bytes 並重新簽署，不能沿用舊簽章。

日常按改動影響重驗；Pipeline預設16小檔、取消8檔、報告2501列、Fleet十台各200、Spec200。5000分段及真實4GiB的特殊邊界保留；大容量／50k軟體／維護窗／RPO/RTO需代表性工作量與門檻，不能從合成數量推定。HTML分類列印最多2000列；完整軟體確認五格式不截斷資料。詳細測試操作見 [README](../README.md)。
