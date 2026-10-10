# 第2輪實作、回歸與收尾驗證

更新：2026-10-10。原始範圍為c72f65b7f127f4c045124fab72aa85d191195a48至本輪HEAD；程式最後checkpoint為e97cbc048a491ba4db305003ab6436cab307dd52，文件交付checkpoint為805a2c8。A0/A1、B1/B2、C、D/D2、E1–E3程式閉環完成，外部正式資格及可核實的不同模型體檢未完成，ProductionVerified=false。

## Phase與實際消費端
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

## 固定快照證據

每段在Windows PowerShell5.1與PowerShell7執行；快照在測試期間不覆寫，runtime/test SHA256前後不變。表中快照不是同一程式版本，不將其PASS相加冒充最終全量。後續未受影響的程式、依賴與環境證據可沿用；最後快照146個runtime/test bytes與本輪收尾工作樹逐一核對一致，163個公開函式可解析。

| 階段 | 快照 | 每引擎腳本 | 合計PASS |
|---|---|---|---|| 完整性基線 | wsm-r2-plan-audit-final-c90c4839ca2f410eae026e8b11892102 | 28 | 56 |
| 交付最後整合 | wsm-r2-plan-audit-latest-537b2936b45d41c9aa7013b350df1092 | 11 | 22 |
| 原生設定跨段閉環 | wsm-r2-native-closure-3ce6ee67baac4df9ace6402ab099d4ca | 18 | 36 |
| 防火牆最後修正 | wsm-r2-network-final-163010547b854f04839f1bf395c62949 | 3 | 6 |
| EOF空白清理 | wsm-r2-final-clean-7996352deaf34607a999d0e22cc26ec4 | 2 | 4 |
| marker必要條件最後修正 | wsm-r2-marker-required-a44e297f83254e81a9a73c6e5ca1e89d | 3 | 6 |
| CI編碼與取消fixture修正 | wsm-r2-ci-repair-57b2831a3d1440b4a5f3dc627e7e0840 | 10 | 20 |
| 最後 HTML 列印與完整確認輸出閉環 | wsm-r2-print-guard-c5282b5c9af845d99e753e9a33042a50 | 6 | 12 |
| 非互動 CI 隔離與診斷 | wsm-r2-ci-isolation-e5c2e7b2173443ed835f3b2cf06eaabe | 3 | 6 |
| 盤點原生管理物件投影（Adapter修正前） | wsm-r2-native-projection-8209a73bf4c54d10adfef7fb8a5a19ff | 14 | 28 |
| 最後原生盤點及 durable adapter state 閉環 | wsm-r2-native-state-final-0dd731a9c6b5425db22b7c910bc08708 | 10 | 20 |

完整GitHub回歸：[Actions 37965849112](https://github.com/darionnnnnn/windows-server-migration/actions/runs/37965849112)，head=e97cbc048a491ba4db305003ab6436cab307dd52，fixtures／delta-workflow／migration-round-two(powershell)／migration-round-two(pwsh)四個jobs全部success。矩陣保留25個R2腳本，完整確認用例按2501列執行。公共Windows runner與合成資料不等於企業Server／Oracle／PKI／业务資格。

## 本輪缺陷與修正摘要

| 已重現問題 | 修正與驗證 |
|---|---|
| 原生環境變數展開丟型別／空值、時區丟DST及policy来源不明 | 保留raw String／ExpandString與存在狀態、DST；读取失敗留缺口，Unknown不能推為Local |
| 新Firewall規則缺完整列舉證據 | ActiveStore／TracePolicyStore及專用marker／規則數對帳；無一般gap也不能免marker，失敗及filter中斷阻擋；5.1小整數型別相容 |
| WinPS5.1非UTF8系統解析非ASCII無BOM腳本、取消fixture缺SchemaVersion | UTF8 BOM與ScriptEncoding guard，Windows-1252原檔4個錯誤→修正版0；取消仍驗bytes/journal/cleanup |
| HTML2501列回歸破壞既有列印保護 | 恢復2000列print guard；完整HTML資料與MD／JSON／TXT／CSV保留；原DOM斷言不變 |
| Server runner交付收據測試進入真實collector，raw CIM管理物件圖深度序列化 | Inventory與AdapterState明確投影firewall filter／SMB access primitive欄位，enum轉文字；收據fixture使用source-bound Inventory mock。新測試對4b13c20舊程式因CIM metadata外洩失敗；兩引擎修正版及本機原生只讀投影成功 |

CI失敗37955503134／37956024235、逾時或取消37957836407／37958816256／37960808476／37960896337均不計PASS。初期誤定位WindowsSettingsReview，分段日誌證明實際卡在DeliveryReceipts後半段collector；最終修正及四job成功如上。相關逐段修正仍可從Git提交及原測試證據追查，不用早期checkpoint替代最終程式。

## 2026-10-10收尾核對

- 主代理直接從PLAN與c72f65b..HEAD差異核對全部Phase、R2-01–28及實際producer-consumer。GeneralHost沿用catalog/schema／核准／operation journal；receipt只報告交付，不改Readiness；輸出attempt不重建state。沒有新增第三方安裝器、遠端控制或泛用特殊產品搬移；未發現新的可重現程式缺陷。
- Windows決策預覽綁定source/target/hash/revision，scratch驗證後單次CAS；拒绝整類搬入不解除必要consumer。搬移預覽／apply／restore保持身份及完整檔案hash，舊根marker拒絕重用。Oracle provider／consumer、IFILE白名單與wallet外部處理界線保留。
- 入口AGENTS與當期IMPLEMENTATION移除反覆出現的第一輪進度及過期待完成語句；歷史需求在PLAN／REVIEW與Git保留。README修正当前實作及大檔證據範圍。未受影響手冊／確認模板／復原／資格／SBOM／support無需為日期重寫。
- 原CI只有main push；使用者指定收尾至dev後新增dev契約CI觸發，保留PR／main及純文件排除規則。整合只建立dev並fast-forward既有已驗程式，不改main或改寫歷史；刪分支前核對遠端dev包含本輪全部提交。
- skill評估：固定快照、獨立child process、按影響沿用證據及相異模型身分規則已有涵蓋本輪可泛化問題；不新增重複規則，也不降低正式驗收門檻，本輪沒有修改skill。

## 未完成資格與模型限制

當期未完成清單集中在 [IMPLEMENTATION-0.1.md](IMPLEMENTATION-0.1.md)。真實來源／目標盤點、Server2016/2025/Core／語系／32bit／policy／provider、Oracle帳號／DB／TCPS／consumer、企業PKI與批准、容量／RPO/RTO、跨台回退／業務／畫面等未取得證據，維持NotTested／Blocked。

先前主代理親自實作，精確模型身分無可信執行紀錄；既有subagent為gpt-6-luna high/medium/low。此次使用者指定opus low，但可用subagent清單沒有該模型，故未委派。主代理直接收尾審查不宣稱符合「不同於全部實作者模型」；此獨立資格仍待可核實模型。開發分支整合不解除此項或任何生產gate。


## dev integration verified (2026-10-10)

Commit `0a2ac7feb1fbe939496c53a2295d93fa4d092e7d`: [GitHub Actions 38006384588](https://github.com/darionnnnnn/windows-server-migration/actions/runs/38006384588) completed successfully, all four jobs passed. The dev-only CI trigger is verified on the actual dev push. The 146 runtime/test files are unchanged from e97cbc0. Remote dev contains the original development tip 805a2c8; local and remote codex/implementation were deleted after this check. Main remains d67d5c82e346b73a1dae43538c4759564f3e7622. This final documentation-only commit does not change runtime/test/CI bytes or establish production qualification.

## 2026-10-10 企業情境與設定搬移說明補強

新增企業情境／協助範圍矩陣及README／操作／確認模板引用。專業與環境軟體本體只列Markdown，由使用者安裝；一般及Oracle設定檔另列精確FileScope／typed adapter或外部程序。明列ConfigFiles不是payload白名單、整機／System State與特殊角色不推定支援，以及聲明metadata不等於還原／consumer成功。

此子段src只新增EnvironmentConfirmation的Markdown說明；未改Projection schema、gate、封包／還原／adapter行為。固定快照 `wsm-enterprise-coverage-468c1fb1fb9846dbb43f474572e4c7ab` 的ScriptEncoding／EnvironmentConfirmation（6列完整五格式與語意）／Contracts／LabReportConsumer在WinPS5.1及PS7各4/4，快照hash前後不變且src/tests与工作樹逐一相符。新Markdown界線斷言可使005622b舊產生器因缺必要說明而失敗；5.1明確UTF8讀取中文，保留既有數量、秘密遮罩及安全輸出斷言。先前dev CI38006384588是005622b之前程式的證據，不宣稱為本次輸出修正head的CI。

報告程式bytes已變，ToolFingerprint同步變；執行中pair不熱換工具，更新後重新核准。未新增runtime／專業軟體安裝、機器綁定秘密搬移或全企業災難復原能力，正式資格仍Blocked／NotTested。
