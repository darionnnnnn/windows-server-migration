# 第2輪規劃與實作驗證對照

2026-10-09，分支 `codex/implementation`。本輪起點 `c72f65b`，最後補漏前 checkpoint `0705e79`。程式實作與企業正式資格分開；真實 Server／Oracle／企業 PKI／業務與不同模型獨立體檢仍待完成，生產開關保持關閉。

| 規劃 | 已比對程式與使用端 | 驗證重點 |
|---|---|---|
| A0/A1 | ScopeClassification、GeneralHostContracts；inventory→catalog 處置→requirements→review/restore/delta/cutover→Fleet/Lab | 未知及特殊角色告知；typed 處置、RequiredPhase；整類選否不解除必要相依 |
| B1 | SoftwareInventory、EnvironmentConfirmation；HKLM/HKU/portable/app-local/manual→完整五格式→owner/target 準備 | 同名不同 context 保留、coverage、不使用 Win32_Product、材料/安裝順序/副作用/授權門檻 |
| B2 | OracleClientContracts、ConfigArtifactContracts；可信 JSON→binding 模板→owner 審查→FileScope/GH→readback/consumer 證據 | service Environment 的 REG_MULTI_SZ、空 TNS_ADMIN、精確 IFILE、wallet 排除、exact provider/consumer |
| C | WindowsSettingsReview、Discovery、Inventory、SettingTransitions；可信兩端快照→專頁/人工合併→typed 決策→單次 CAS catalog→adapter/readback/prior 復原 | source-after/target-before/type/DST、GPO/Unknown 阻擋、原生 firewall 完整列舉及中斷、每設定每 consumer 需求、失敗 catalog bytes 不變 |
| D/D2 | OutputWorkspace、OutputWorkflow、DeltaVolumeTransport、DeliveryReceipts、WorkspaceTransfer；三角色 enrollment→Full/Delta×ZIP/Directory→實際 native target 匯入→receipt→Manager/Fleet/Lab | 新 attempt 不重建 state、MD 可讀、ProjectionHash 內容重驗、同 DeliveryId 階段進展、缺卷/錯包/成員預算、搬移及中斷回復 |
| E1 | MigrationContracts、OperationRequests、新 schema 與所有入口/producer-consumer | 舊格式明確區分、WhatIf 純預覽、CLI/API/選單同 gate、source/target/plan/tool/revision 綁定 |
| E2 | Cutover、SourceRecovery、CrossHostCoordination、Recovery；typed freeze/fencing/rollback/resume/retirement | 擷取前及鎖內重驗、writer epoch、唯一 writer、新交易保存/對帳、具名退役檢查；真實協調仍 NotTested |
| E3 | Qualification、ToolRelease；exact runtime/support/SBOM/release→CMS/Crypt32 離線驗證/撤銷→qualification consumer | exact tuple、過期/未知/未信任/撤銷負例、cache-only 信任；真實有效企業鏈/批准及 Server 正向資格仍 NotTested |

## 最後追加修正

MachineEnvironment 原生盤點保留未展開值、String/ExpandString、存在但空白與不存在；TimeZone 保留 DST。讀取失敗明列缺口。登錄值或有效值不證明不存在 GPO/MDM，管理來源仍 Unknown，不能自動當成 Local。

Firewall 使用 ActiveStore/TracePolicyStore 保存 policy source。來源及目標 GPO/Unknown 均阻擋受審搬入；新建必須有完整列舉專用 marker 及整數規則數量對帳。只有 exact `scope:Network` 的一般 Unsupported 提示可並存；具體缺口、失敗或 filter 中斷仍阻擋。marker 包含在 SettingsHash。WinPS 5.1 JSON 小整數讀回 Int32，故只接受非負 Int32/Int64，不接受字串、浮點或布林。

## 固定快照與適用範圍

按修改影響分段驗證，不把不同快照相加冒充「同一最終版本跑了所有測試」。每段在 Windows PowerShell 5.1 與 PowerShell 7 執行，runtime/test SHA256 前後不變；最後清理快照與最終工作樹全部 runtime/test bytes 相同。早期結果僅沿用未受後續修正影響的行為，新原生設定及網路修正另驗相關閉環。

| 階段 | 快照 | 每引擎腳本 | 合計PASS |
|---|---|---|---|
| 完整性基線 | wsm-r2-plan-audit-final-c90c4839ca2f410eae026e8b11892102 | 28 | 56 |
| 交付最後整合 | wsm-r2-plan-audit-latest-537b2936b45d41c9aa7013b350df1092 | 11 | 22 |
| 原生設定跨段閉環 | wsm-r2-native-closure-3ce6ee67baac4df9ace6402ab099d4ca | 18 | 36 |
| 防火牆最後修正 | wsm-r2-network-final-163010547b854f04839f1bf395c62949 | 3 | 6 |

最新語法／編碼檢查涵蓋 145 個 src/tests/入口檔；163 個公開函式解析。Pipeline 小樣本仍保留真實 bytes/ACL/restore/final/retry 斷言；最後原生閉環 EnvironmentConfirmation 採 6 列驗語意，大量完整輸出由 CI 預設 2,501 列另驗。沒有 50k 軟體、500GiB、企業維護窗或 RPO/RTO 量測資格。

## TODO 判定

已完成驗證並刪除三項程式 TODO：full/delta delivery Markdown 與管理端收據/Fleet/Lab 閉環；Windows 設定專頁與逐設定相依；停止工具後的受控 WorkRoot 搬移/中斷回復。原始 PLAN 契約及歷史保留。

仍保留：真實 source/target 盤點及完整軟體確認；Server2016/2025/Core/語系/32bit/policy 與 native provider；Oracle 帳號/DB/TCPS/consumer；企業 PKI/批准；代表性容量及 RPO/RTO；業務回退/跨台波次/畫面驗收；不同於全部實作者模型的獨立體檢。缺外部輸入不等於程式 TODO 漏實作，也不等於已取得企業正式資格。

## 模型與獨立性

主代理親自實作接口、wizard、原生 producer 及最後修正，精確模型身分尚無可信執行紀錄。subagent 依使用者指定僅 gpt-6-luna，主模型按工作選 high/medium/low；最後閉環收尾為 high。主代理已獨立驗證 subagent 產出，自己的實作範圍未宣稱不同模型體檢。

GitHub Actions 僅記實際觀察结果，既有 checkpoint 結果不代替本次 head。


最後清理只移除 Test-SoftwareInventory.ps1 的 EOF 空白行，正式 runtime 未改。SoftwareInventory/Contracts 在5.1與7各2/2通過；固定快照 wsm-r2-final-clean-7996352deaf34607a999d0e22cc26ec4 的全部 runtime/test hashes 前後不變且與工作樹相同。最後 diff 空白檢查及12份本機 Markdown 連結檢查通過。

程式主段落 `44f9bf4dfdfdc8fbf78909789f876389ec0afcc6` 已推送並核對遠端一致。該次 CI 37955503134 已完成失敗；原因與後續修正見下方紀錄，不能視為通過。


2026-10-10 最後邊界修正：新增 Firewall 規則必須有有效的完整列舉 marker，即使盤點沒有一般 DiscoveryGap 也不能省略。新增「missing marker without generic gap」拒絕測試；WindowsSettingsReview/InventoryFixture/Contracts 在5.1與7各3/3通過，快照 wsm-r2-marker-required-a44e297f83254e81a9a73c6e5ca1e89d 的全部runtime/test bytes前後一致且與最終工作樹相同。此補漏只改設定 review helper與對應fixture，既有無關結果不重跑。


## CI 追加缺漏與修正（2026-10-10）

37955503134 與 37956024235 的已完成失敗工作不能視為通過。GitHub connector 日誌定位到 WinPS5.1 非UTF8系統下 DeliveryReceipts 模組／測試缺BOM，以及取消預覽的舊測試Plan少SchemaVersion。補UTF8 BOM、保留取消的bytes/journal/cleanup斷言並將fixture明列Schema1；新Test-ScriptEncoding及CI入口檢查所有非ASCII脚本BOM和語法。Windows-1252 模擬重現舊測試4個解析錯誤，BOM版0個，新guard能拒絕原始檔。

最後10個受影響腳本於5.1／7各10/10通過：編碼、取消預覽、DeliveryReceipts、LabReportConsumer、LabValidation、OutputWorkflow、FullDirectoryImport、DeltaMenu、Contracts、MigrationPipeline。固定快照 wsm-r2-ci-repair-57b2831a3d1440b4a5f3dc627e7e0840 的全部runtime/test SHA256前後一致且與工作樹相同。BOM也屬工具bytes，ToolFingerprint已更新；既有執行中的工具／核准不能熱換成新版。修正後的遠端CI結果另記實際觀察。


## 後段相容回歸：HTML 列印保護（2026-10-10）

補驗先前CI失敗後未跑到的後段工作：TaskFolderJournal、Archive、EntryPoint已通過，Report DOM重現本輪移除既有2,000列print guard的回歸。恢復既有保護；完整HTML仍內嵌全部chunks，Markdown/JSON/TXT/CSV不截斷，列印需縮小篩選範圍。原有Report測試不改，2,501列lazy parsing/LRU/快速篩選/print guard在5.1/7通過。

ScriptEncoding、Report、EnvironmentConfirmation（6列語意）、FleetScale（10台×200項）、LabReportConsumer、Contracts於5.1與7各6/6通過。最後快照 wsm-r2-print-guard-c5282b5c9af845d99e753e9a33042a50 的所有runtime/test SHA256前後不變並與工作樹相同；完整確認文件2,501列另由最終CI測試。不同模型獨立體檢仍待完成。


遠端補驗發現：37957836407 的兩個 migration-round-two jobs 在交付收據後段模組匯入後持續至 20 分鐘上限（起初誤定位為 WindowsSettingsReview，後續分段日誌已更正），取消不計通過；PowerShell 7 曾輸出 JSON depth 30 截斷警告。本機完全相同快照以兩引擎及 NonInteractive 模式仍成功。已新增分段診斷輸出並把該測試放到整合 job 首位，保留全部斷言與既有逾時門檻，繼續追查遠端差異；不把尚未成功 CI 寫成完成。


非互動隔離補驗：37958816256 的同類工作亦取消，不計通過。4b13c20 保留同一套24項矩陣測試與全部斷言，把WindowsSettingsReview設為獨立的3分鐘步驟並使用NonInteractive；37960896337該步驟在5.1／7分別7秒／5秒成功。原逾時根因未重現，未宣稱修正產品序列化缺陷。診斷輸出不改正式runtime；ScriptEncoding／WindowsSettingsReview／Contracts在固定快照 `wsm-r2-ci-isolation-e5c2e7b2173443ed835f3b2cf06eaabe` 於兩引擎各3/3，145個runtime/test SHA256前後不變且與工作樹相同；此前印表及其他不變程式的有效證據沿用。


## 最後 CI 定位更正與原生物件投影（2026-10-10）

37960808476 分段日誌證實 WindowsSettingsReview 全部完成，實際停滯為 Test-DeliveryReceipts 後半段：前面的 PASS 只代表 Markdown/Fleet 單元用例。37960896337 亦取消，不計通過。來源 LabReport receipt fixture 未替換 Export-WsmInventory，本機非 Server 被拒絕採集，Server runner 則進入完整原生採集。收據用例現使用 source-bound trusted Inventory fixture，新增 NativeInventoryCollected=PASS 斷言，保留所有 full/delta/native transport/receipt assertions，沒有關閉正式 LabReport 原生盤點。

正式 Inventory 與 AdapterState 的 firewall filters／SMB access 原先保存原始 CIM 物件，包含 CimClass／CimInstanceProperties／CimSystemProperties，會造成管理物件圖深度序列化。改為明確操作欄位投影，SMB 權限及 dynamic transport enum 保留文字標籤；盤點、目標狀態／readback／journal／回退共用相容資料形狀。新 InventoryFixture 及 NativeStateProjection 回歸皆能使 4b13c20 原始 raw 程式因 CIM metadata 外洩失敗，修正版通過；實際本機 firewall filter 只讀查詢也證明有限 JSON，不修改主機。這不等於完成 Server／產品資格。

盤點投影中間快照 `wsm-r2-native-projection-8209a73bf4c54d10adfef7fb8a5a19ff` 的14腳本在5.1／7各14/14，runtime/test bytes前後不變；此快照先於後續AdapterState投影修正，新完整受影響快照另記。CI現在保留25項矩陣測試：新增 NativeStateProjection，DeliveryReceipts與WindowsSettingsReview各為獨立3分鐘步驟；未刪減原斷言。WinPS5.1已觀察2,501列確認用例耗時10分45秒並成功，屬合成測試，不是正式遷移效能。


最後原生狀態投影固定快照 `wsm-r2-native-state-final-0dd731a9c6b5425db22b7c910bc08708`：ScriptEncoding／NativeStateProjection／Adapters／ShareContracts／InventoryFixture／DeliveryReceipts／LabReportConsumer／LabValidation／MigrationPipeline（2個小檔的真實bytes/ACL/恢復/回退）／Contracts於5.1與7各10/10；146個runtime/test SHA256前後不變且與最後工作樹相同。Luna high只讀複核確認firewall/SMB消費欄位及enum round-trip保留；主代理親自核對與驗收，不稱為不同模型體檢。本次runtime bytes已改指紋，既有核准依既有重新核准流程失效；此版本的遠端CI仍待實際成功。
