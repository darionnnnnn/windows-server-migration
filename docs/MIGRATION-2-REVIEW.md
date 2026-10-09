# MIGRATION-2 深度複審：企業 Windows Server EOS 遷移

> 日期：2026-10-09；基準：991fc864126d226b65eb0fdbe440c7f7d41040af，codex/implementation。
> 本報告是規劃及程式現況審查，不是實機資格證書。審查者未連線來源／目標 Server，未取得其真實軟體清單。
> 權威規格：[MIGRATION-2-PLAN.md](MIGRATION-2-PLAN.md)；使用者確認格式：[ENVIRONMENT-SOFTWARE-CONFIRMATION.md](ENVIRONMENT-SOFTWARE-CONFIRMATION.md)。

## 判斷

原規劃具備合理的一般主機範圍、安全限制與離線流程，但尚不足以作為企業正式 EOS 遷移工具的完整驗收規格。最明確的缺漏是 Oracle 用戶端設定沒有搬移閉環、完整軟體清單未包含個人／可攜來源、交付格式未包含使用者要求的 Markdown，以及企業發行與資格仍被籠統留待後續。

本次已將 20 項缺口補入 PLAN，明訂交付、consumer、阻擋及驗收。這表示**規劃已補強**，不表示現有 0.3 已具備新增能力。Source／Target 原生 API、Oracle 實際帳號／產品行為、企業信任與切換復原仍須取得證據；未完成不得稱為正式工具驗收通過。

## 證據分級與審查範圍

- **已核對程式事實**：直接讀取 src、入口相關契約、現況與 workflow；下表列出可定位證據。
- **規劃缺口／推論**：由已核對程式及使用者需求判斷應補的契約；不把「規劃尚未寫」誤報為現有程式已經出錯。
- **未驗證**：Server 2016／2025、user profile、真正 Oracle consumer、Windows 政策、企業簽章及實機故障行為。本次沒有執行這些環境操作。
- 沿用目前分支，未修改未追蹤 prototype `Get-ServerMigrationInventory.ps1`，未将任何真實配置／企業資料加入公開 repository。

| 已核對證據 | 意義及界線 |
|---|---|
| src/Inventory.ps1:29 | InstalledApplication 僅由 HKLM 兩種 Uninstall 路徑取得；非完整 user／portable 軟體盤點 |
| src/Discovery.ps1:16–20；src/EnterpriseDiscovery.ps1:1 | system culture／Machine env／machine DSN 存在；不證明服務帳號實際環境、user DSN 或 driver 齊全 |
| src/ConfigArtifactContracts.ps1:1–4；src／tests 的 Oracle／TNS 搜尋 | 自動 config 名稱不含 Oracle Net 檔；未找到 Oracle 專用實作／測試；人工列檔能力不能當作 Oracle 有效設定驗證 |
| src/EnterpriseDiscovery.ps1:8–12、27、35 | 角色及 deep 探索已有 Unknown／Unsupported／owner gap；不是所有外部相依均已解析 |
| src/Review.ps1:42–54 | incomplete／excluded 仍需 owner／evidence，Mandatory 相依需 Include；新準備／外部型別必須接線 |
| src/Adapters.ps1:22、62、88、111 | MachineEnvironment 讀寫／readback 存在；PATH 有保護，未提供完整 user／Oracle registry 搬移能力 |
| src/Reports.ps1 的 Export-WsmTextReport 等輸出 | 既有 HTML／TXT 等報告可沿用；未提供本輪完整 Markdown 軟體確認產生器 |
| src/InstallerSafety.ps1:5、30、49 | 已有 installer snapshot／consumer／副作用保護；本輪手動安裝的隔離核對不能遺漏 |
| src/Recovery.ps1:47、53 | 已有 NewTransactionsPossible／RollbackReconcile 阻擋；不可說本次首次補資料回退功能，也不能將 evidence 字串當反向同步實證 |
| src/Qualification.ps1 的 Get-WsmQualificationKey／Assert-WsmQualificationRecord／Get-WsmQualificationMatrix | exact tuple／expiry／revocation 已有，execution 仍 IsolatedPilot、ProductionExecutionEnabled=false；目前維度及獨立信任需補 |
| src/ToolRelease.ps1:7、10；src/LabValidation.ps1:117–121 | release／lab report 明列未正式驗證／未簽／業務缺口，hash 不提供作者真實性 |
| docs/IMPLEMENTATION-0.1.md 當期待辦；.github/workflows/contracts.yml | 現況仍待實機／產品資格；純文件變更不觸發該 workflow，不能虛構本次 CI PASS |

## 二十項缺口、影響與可證偽驗收

P0 表示取得正式資格前必須解除的阻擋，不表示現在有已證實的生產事故；P1 為必要完整性／操作／交接要求。

| ID／優先級 | 缺口及失敗情境 | 補入批次 | 驗收要點 |
|---|---|---|---|
| R2-01／P0 | Oracle DB 與 client 同名分類，將應用需要的 client／TNS 設定一併排除 | A、B2 | DB 外部處理但 client／TNS 留在入選相依；缺設定阻擋 consumer |
| R2-02／P0 | TNS_ADMIN 只查管理員 env，實際服務／app／registry 讀另一份設定 | B2、C | provider／version／bitness／帳號的有效來源與被遮蔽值可查；衝突／未知不放行 |
| R2-03／P0 | 只複製 tnsnames，漏 sqlnet／ldap／IFILE／ACL／路徑，或誤把 wallet／listener 入包 | B2、E1 | 精確檔案／reference／hash／encoding／SID mapping，敏感外部交付、限定 scope、delta 重新核准 |
| R2-04／P0 | tnsping／SQL 工具在管理員終端成功，應用仍無法登入／交易 | B2、E2 | 實際 consumer 帳號／driver 驗 DB／業務；未測及只 listener 通維持 NotTested |
| R2-05／P1 | Uninstall 不是全部軟體：個人安裝、portable、venv／app-local 被漏列 | B1、D | HKLM／可讀 HKU／受限 portable／人工補登与 coverage 逐列對帳 |
| R2-06／P1 | 安裝 view 當架構、同名不同 SID／Home 去重，準備錯誤媒體 | A、B1 | Unknown 不猜；原始 scope／view／位置身分保留，media 去重不合併需求 |
| R2-07／P1 | Java／Python／Node／PHP／IIS 擴充／ODBC driver 等工具只有泛稱 | B1 | 有證據者明列版本／架構／來源／consumer／準備與目標重查；未解析列人工 |
| R2-08／P0 | 使用者装軟體後 installer 自啟排程／service 對正式 DB 寫入 | B1、E2 | 安裝前隔離、後差異／quarantine，無法確保無副作用則 blocked |
| R2-09／P0 | 必要依賴被 Exclude／特殊已讀解除，或舊 Mandatory gate 完全拒絕新準備型別 | A、E1 | 型別相依全 consumer 接線，preview／restore／activate／fleet 一致阻擋 |
| R2-10／P1 | 只有 HTML／TXT／CSV，缺使用者可逐列確認的完整 `.md` | D | 每台完整快照、超過2,000列不截斷、全部軟體／未知／排除都可追 JSON |
| R2-11／P0 | 勾 Markdown 當核准，或重查沿用 stale／wrong-target 的準備結果 | B1、D、E1 | 文件非權威；fresh preview／revision／hash／target／有效期，漂移撤銷 affected closure |
| R2-12／P0 | OS 全類選否吞掉必要 TNS／帳號／憑證相依；無 adapter 卻顯示可搬入 | C | preference 與 required 相依分開；可用動作精確，未實作只 External／Unknown |
| R2-13／P0 | Server 2025／產品版本／政策差異用「新版相容」或搬弱 TLS 掩蓋 | B1、C、E3 | vendor 證據、有效政策、tuple，未資格不泛化；不自降基準 |
| R2-14／P0 | 開啟檔／外部 writer 未停就 final，或搬移與回退峰值空間不足 | E2 | 一致性分類／quiescence／final hash／完整空間預檢／維護窗實測 |
| R2-15／P0 | 雙寫、同名同 IP、SPN／DNS cache／管理通道與 reboot policy 漏驗 | E2 | fencing／external receipts、identity transition、console 恢復、reboot 後 readback |
| R2-16／P0 | 已有新交易仍移回來源，保留設定卻丟失業務新資料 | E2 | writers stop／target 保存／對帳／同步／owner 證據，缺即阻擋；不自啟來源 |
| R2-17／P0 | 十台逐台 PASS，共享 DB／TNS／UNC 或循環群組仍未到 barrier | A、E2 | 共用依賴列全 consumer，wave stop／continue、group barrier，局部 PASS 不等於切換 |
| R2-18／P1 | 模糊 blocked、EOF／取消當同意、值班無法接手或人工步驟未回流 | D、E1 | 具體缺項／owner／下一步、退出碼／report／journal，角色旅程與 CLI 同 gate |
| R2-19／P0 | hash／自填 owner 當企業信任，簽章改 bytes 卻沿用舊核准 | E3 | 最終簽署 bytes → fingerprint → plan／qualification；過期／revoked／不可信阻擋，發行包可查 |
| R2-20／P0 | 一般 scope 完成即退役；長週期工作、backup restore／監控／特殊產品未接手 | E2、E3 | 觀察／演練／外部 consumer／特殊處置／保留與不可回退點／retirement owner 批准 |

## 各種使用者及角色的尖銳檢查

這是依使用者指定的「尖銳但有理」標準進行情境推演，沒有宣稱蒐集或代表 Reddit 社群的真實評價。

| 角色／合理質疑 | 規劃必須回答的操作／結果 | 尚待實作驗證 |
|---|---|---|
| 第一次操作者：「它到底會寫什麼？我選否會漏什麼？」 | scope／動作／OS 選否影響與 required 相依清楚，preview 後決策 | 實際 console、EOF、取消、CLI/API 同 gate |
| 熟練管理員：「Add/Remove Programs 不等於所有環境，漏我的 portable？」 | 全部發現列＋coverage＋補登，不承諾偵測所有 DLL／profile | HKU／portable／driver／架構及漏掃負例 |
| Oracle 應用 owner：「管理員 SQLPlus 能通，我的32位 app pool 就一定能通？」 | provider／bitness／identity／有效路徑、檔案与 ACL、真正 consumer 業務驗收 | Server／Oracle 正反例；缺 lab 明列未資格 |
| 值班接手：「凌晨中斷後，我能看出停在哪裡，會不會重寄通知？」 | run／pair／generation／journal／下一步、staging／fencing／catch-up 控制 | reboot／部分 activation／resume 重入 |
| 業務 owner：「能不能回退？新訂單會不會不見？」 | RPO/RTO、停止 writers、保存／對帳／同步責任及不可回退點 | 真實含新交易回退演練 |
| Fleet 管理者：「十台不同環境，到底哪台缺什麼，哪些不能分開切？」 | 每台 Markdown／target 差異／wave／共用依賴／group barrier | 十台對帳與真實跨台相依案例 |
| 平台／資安管理者：「憑什麼相信這個包？有沒有順便降 TLS、漏 wallet？」 | signature／trust／最終 bytes、分級／加密交付、政策／機密界限 | 企業材料、信任驗證、secret／注入負例 |
| 稽核／交接審查人：「說完成是哪些完成，哪個項目其實沒测？」 | Review／Preparation／Staged／Final／Retirement／Production 分離，NotTested 留列 | 發行包、owner 證據、支援 tuple／撤銷流程 |

## 程式面與整體專案的最後回查

1. **資料與核准順序**：inventory／完整 software／requirements → owner 決策 → target 準備 → config／OS 映射 → plan → payload → staging → final／consumer → activation → observation／retirement。核准前 requirements 證據、核准後 plan hash 避免循環；新資料經 schema 進所有 gate。
2. **舊語義與相容**：不改 Include／Exclude 的既有意義；相依型別需版本化完整接線。舊 inventory 缺新證據提示補盤點，舊包不冒充新模式。舊 WindowsFeature pilot 安裝契約不被靜默改寫，新模式明確禁止自動補環境。
3. **共用副作用**：PATH／TNS／runtime／帳號／憑證／IIS global config 可影響其他 consumer；共用 owner、target drift、subset restore／rollback、manual installer ownership 均要驗。不能因一台或一服務 PASS 推成整群合格。
4. **資料與機密**：受控 bytes、精確 config、delta re-review、ACL／SID、外部 wallet／私鑰、safe projections、對帳計數分開。不把資料 hash、作者身分、業務成功與企業批准混為一個 PASS。
5. **生命週期**：plan／approval／source／target／generation／journal／證據有效期可追；變更只撤銷受影響且需要重查的證據，執行中不熱換。切換、已寫入後回退、source 退役有獨立門檻。
6. **交付與驗收**：A–D 有功能 consumer；E1 有相容回歸；E2 有實機及業務／故障演練；E3 有資格與發行包。若外部材料不足，仍交具體缺項，不能為了結案移除正式資格要求。

## 官方依據核對（2026-10-09）

Oracle 19c Net 說明 Windows TNS_ADMIN 的 process environment／registry 與 Oracle Home 查找；ODP.NET 的有效來源又受 provider／版本影響。因此規劃選擇「實際 consumer 的版本化規則＋人工未知覆核」，不硬編碼跨 driver 通用搜尋順序。依據：[Oracle Net](https://docs.oracle.com/en/database/oracle/oracle-database/19/netrf/local-naming-parameters-in-tns-ora-file.html)、[ODP.NET 19.3](https://docs.oracle.com/en/database/oracle/oracle-data-access-components/19.3/odpnt/InstallConfig.html)、[ODP.NET 26](https://docs.oracle.com/en/database/oracle/oracle-database/26/odpnt/InstallConfig.html)。

Oracle 官方明訂 tnsping 不確定資料庫是否正在運行，故只能提供 listener 連線證據。依據：[Testing Connections](https://docs.oracle.com/en/database/oracle/oracle-database/19/netag/testing-connections.html)。DPAPI 一般綁使用者／機器，存在例外但不能推成可搬全部加密材料；依據：[CryptProtectData](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)。

Microsoft 列 Server 2025 的 NTLMv1／SMTP 等移除及 TLS 1.0／1.1 預設停用，另有 SMB signing 政策。這些是本輪相容查證項，不是自動放寬基準的理由。依據：[Removed/deprecated features](https://learn.microsoft.com/en-us/windows-server/get-started/removed-deprecated-features-windows-server?tabs=ws25)、[SMB signing](https://learn.microsoft.com/en-us/windows-server/storage/file-server/smb-signing-overview)。

本次查詢 Microsoft release information 顯示 Server 2016 extended support end 為 2027-01-12，英文 lifecycle 頁呈現 2027-01-13，其他語系另有1月12日。保留官方差異，專案先按較早 2027-01-12 規劃，管理者於放行時重新核對官方時區／日期，不把這份快照當永久權威。依據：[Release information](https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info)、[Lifecycle](https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2016)。

## 本次驗證範圍

完成規劃需求對照、程式事實定位、各角色旅程／失敗情境、跨批次 producer-consumer／授權／相容／回復影響審查；交付文件與入口進行 diff／本機連結／格式核對。只修改文件，不重跑程式 regression，也未新增實機 PASS。公開 repo 不含實際企業 inventory 或機密。

下一輪依 PLAN A–E 實作與驗收，每個完整可驗段落獨立 commit／push；新增功能和企業資格均尚未完成。
