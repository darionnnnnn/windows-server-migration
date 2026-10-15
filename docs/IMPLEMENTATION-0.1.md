# 0.4 實作狀態與外部驗證

更新：2026-10-15。第六輪備份／多共享／還原相依整合已提交，本機受控證據與未通過邊界分列，逐段 commit、適用版本及證據集中[第六輪 PLAN](plans/MIGRATION-6-PLAN.md)。第五輪及更早的結果保留於各輪 PLAN；操作模板不能代勾，程式存在或 helper 測試通過不等於完整使用旅程已通過。

## 第六輪現況

| 範圍 | 目前實作 | 驗收邊界 |
|---|---|---|
| 準備與核准 | 全 adapter 型別化準備、真 Save→Submit、共享／未知／循環相依、200 項選取、批次審閱、Target 零備份交接與來源核准計畫匯入。 | 雙引擎核心與正式 handler 證據，以及三個空工作區到真 UI 核准、計畫雜湊讀回與重開交接的隔離原生證據；來源意圖不等於核准。 |
| 備份與作業 | 每次 attempt 固定 Directory／ZIP、停寫影響預覽、獨立 freeze 授權、真核心封裝／讀回、持久進度、同 ID 查詢、取消與工作區單一寫入者。 | 已有兩引擎核心及隔離 Windows CI 原生 Directory／ZIP 封裝、取消／Probe 並行、耐久結果證據；本機環境傳輸問題另列。 |
| 非 C | metadata-only 帳號觀察、逐 SID 映射、兩端既有共享／實體範圍證據攜出與匯入、精確傳輸計畫及結果交接。 | 本機檔案與 metadata 可由代理驗證；隔離 peer 觀測不代表原生 SMB 驗收。雙來源共享、雙資料目的共享與獨立狀態共享的 constructor→worker→Manager→Target 已有隔離雙引擎證據；不代表企業 SMB 通過。 |
| Target | 真 ZIP／Directory 接收、目前盤點／比較／計畫子集決策、還原預覽／取消／明確新決策續作、逐項結果及驗證投影。 | 獨立 C 不被無關 NonC 材料全域阻擋；混合成功不代表全部完成。Staged→獨立啟用審閱→Final 驗證與接受條件分開，啟用後保留原還原歷史；不自動啟用。 |
| 開發者探測 | 獨立唯讀收集器與 CLI；Probe／搬移各有單一寫入鎖，可分別執行。 | 三角色原生 UI、跨工作區作業隔離與 ZIP／HTML／JSON／索引讀回在隔離 Windows CI 雙引擎通過；不修改搬移權威狀態，本機 Win11 的 Server 深度盤點為 NotApplicable。 |

本機原生 Edge→HTTP 傳輸仍為 **NotPassed**。獨立 Windows CI 已通過實際發行／解壓模組的原生資源 bytes、session、125 項盤點、一次保存及明確注入錯誤處理；後續 [Source／Target 雙引擎原生旅程](https://github.com/darionnnnnn/windows-server-migration/actions/runs/38689090862) 已完成 Directory／ZIP 小檔封裝、明確 Target 還原、檔案／journal 雜湊讀回及同 OperationId 重播，[第二頁 Probe／查詢／取消](https://github.com/darionnnnnn/windows-server-migration/actions/runs/38690279623) 也已通過。受控身分、盤點及停寫排程仍是 fixture，沒有操作真實業務服務；[雙引擎 run 38686507492](https://github.com/darionnnnnn/windows-server-migration/actions/runs/38686507492) 不代表這台電腦的環境問題已解決。已修正 idle preconnect 的未初始化錯誤，保留原 deadline；瀏覽器觀察到回應改寫／reset，但責任元件未確定。正式 handler 擷取橋接可驗證核心與 UI 接線；P0 所需真 Edge／正式 HTTP／可逆保存及錯誤處理已有獨立 Windows CI 證據。本機失敗仍單列，[Manager 雙引擎原生旅程](https://github.com/darionnnnnn/windows-server-migration/actions/runs/38698158215) 亦已完成審閱、明確核准與重開交接；整輪狀態仍依最終交付與收尾核對判定。保留 AdGuard 與企業政策設定。

一般流程使用「舊主機」「新主機」「整理搬移資料的電腦」及逐步導引。保留已核准業務 DLL／EXE、網站、排程、設定及資料；排除 Windows／IIS／Oracle Client／runtime 等安裝軟體本體、整機映像與 System State。來源、選用、觀測版本分存，不自動轉換格式或代認新版相容。外部 Server／SMB／產品／帳號／業務／PKI／規模仍為 NotTested，`ProductionVerified=false`、`ProductionExecutionEnabled=false`；發行包未簽署。尚未宣稱取得不同於全部實作者的獨立模型簽核。

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
- [ ] 真實瀏覽器與主控台完整備份→交接→目標還原旅程；已驗證的受控正式 handler 備份／還原旅程、Node DOM 或 CLI fixture 不能代替原生傳輸、SMB 及完整實機驗收。

使用者的隔離 Server 無法讓代理直接連線，目前尚未收到真實清單／LabReport及企業材料。不能以合成測試補作這些證據，也不刪除原始驗收需求。

## 測試與交付規則

ToolRelease 收錄 README、docs 頂層文件與手冊資產、docs/html 使用者投影及支援／SBOM JSON；不遞迴收錄 archive 或 docs/plans，PLAN HTML 不進路由／索引／新發行包。既有頂層第三輪 PLAN Markdown 保留原交付契約，歷史引用仍需回專案原始碼查閱。

UI／src／入口 bytes 變更會更新 ToolFingerprint，執行中配對須以原版工具接續，不能熱換 UI。純文件變更不改工具指紋，但會更新發行包與文件 hash；新包必須核驗最終 bytes 並重新簽署，不能沿用舊簽章。

日常按改動影響重驗；Pipeline預設16小檔、取消8檔、報告2501列、Fleet十台各200、Spec200。5000分段及真實4GiB的特殊邊界保留；大容量／50k軟體／維護窗／RPO/RTO需代表性工作量與門檻，不能從合成數量推定。HTML分類列印最多2000列；完整軟體確認五格式不截斷資料。詳細測試操作見 [README](../README.md)。
