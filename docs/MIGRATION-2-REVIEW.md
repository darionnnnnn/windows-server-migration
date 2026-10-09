# MIGRATION-2 深度複審：企業 Windows Server EOS 遷移

> 日期：2026-10-09；基準：991fc864126d226b65eb0fdbe440c7f7d41040af，codex/implementation。
> 本報告是規劃及程式現況審查，不是實機資格證書。審查者未連線來源／目標 Server，未取得其真實軟體清單。
> 權威規格：[MIGRATION-2-PLAN.md](MIGRATION-2-PLAN.md)；使用者確認格式：[ENVIRONMENT-SOFTWARE-CONFIRMATION.md](ENVIRONMENT-SOFTWARE-CONFIRMATION.md)。
> 再次複審：2026-10-09，247c528662d24adf4c52fae3dec0c544ec821a7c；本節以下保留前次20項與輸出審查，新增 R2-21–R2-28 的操作／程式／全局回查。

## 實作前判斷（歷史；目前實作狀態以 PLAN 執行紀錄為準）

原規劃具備合理的一般主機範圍、安全限制與離線流程，但尚不足以作為企業正式 EOS 遷移工具的完整驗收規格。最明確的缺漏是 Oracle 用戶端設定沒有搬移閉環、完整軟體清單未包含個人／可攜來源、交付格式未包含使用者要求的 Markdown，以及企業發行與資格仍被籠統留待後續。

前次20項加本次8項，共28項已補入 PLAN，明訂交付、consumer、阻擋及驗收。本次尤其修正前次輸出建議中的狀態目錄、資料夾集合及增量分卷缺口。這表示**規劃已補強**，不表示現有 0.3 已具備新增能力。Source／Target 原生 API、Oracle 實際帳號／產品行為、企業信任與切換復原仍須取得證據；未完成不得稱為正式工具驗收通過。

## 再次複審：先逐角色走操作（基準247c528）

以下是使用者指定的尖銳且合理質疑情境，不是蒐集到的 Reddit 評論。先找「使用者下一步真的做得下去嗎」，再用程式核對，最後檢查跨階段影響。

| 操作者／合理質疑 | 反向檢查發現 | 修正及驗收入口 |
|---|---|---|
| 初次使用者：「還沒盤點，哪來 PairId？下次換目錄算同一台嗎？」 | 配對在管理端匯入後才產生；每個新 inventory 目錄會新建 HostId | D2.1／D2.4：先穩定登錄再配對，同 host 重盤點與換工作根的受控遷移 |
| 值班接手：「重開後為何說沒搬過？初始成功後 final 怎麼衝突？」 | per-attempt state 會失去 ownership／journal，阻擋已有 target 或失去復原依據 | 同 plan／pair 持續 state，遺失即停止核對，不讓新目錄冒充恢復 |
| 搬運人：「我選512MiB，最後增量怎麼還是一個巨大 ZIP？」 | 現有 delta 是單檔 ZIP，另在 TEMP 建完整 blobs.bin | 新 delta-volume、同實際上限、full／delta 分路；scratch 峰值入容量預檢 |
| 熟練管理員：「整個資料夾照拷，為何混進接續狀態？能保證清單完整？」 | 原封存 package 本身含 export-state.json；ZIP 則只取白名單 | 建乾淨白名單資料夾，少／多檔與 hash 對帳，副本空間列預覽 |
| Oracle owner：「安裝器早建了 TNS_ADMIN，既有 adapter 為何不能照搬？」 | restore 對非工具建立的同名物件拒絕，並無任意原值覆寫回復契約 | C：Keep／External／受驗 UpdateReviewed；原值與型別、漂移及共享 consumer 回退 |
| 應用測試人：「檔案未還原就要我證明能通？改一項不相關設定又要重裝？」 | 準備／搬入後／業務 gate 若混用或只看全局 revision，會循環或撤銷所有準備 | B1／E3：RequiredPhase＋需求投影 hash，受控診斷、受影響證據重驗 |
| 管理者：「同 r/d 再產報告會覆蓋昨天？壞卷重建還認舊 hash？」 | 報告檔名缺目標觀測身分；ZIP timestamp 不保證重建 bytes 相同 | D／D2.4：唯一 DocumentId／固定 DeliveryId；補傳原卷或新 transport 重封 |
| 稽核人：「9,999卷以下就算規模合格？新 schema 舊工具能讀？」 | JSON 仍限128MiB且 envelope 只接受v1；卷數不等於成員／RAM／JSON預算 | E1／D2.4：格式協商與完整 consumer；超限明確阻擋且不截斷確認清單 |

## 新增八項：程式事實、影響與可證偽驗收

下表是本次發現的規劃缺口；尚未執行相應新功能或故障實機測試。

| ID／優先級 | 已核對程式／規劃缺口 | 補入契約 | 必須能證偽的驗收 |
|---|---|---|---|
| R2-21／P0 | Inventory.ps1:17–19 的 source-state 隨 OutputDirectory；Core.ps1:174 才建 PairId；Restore.ps1:1–9 的 state 綁 pair／target／plan。前次 per-run state 設計破壞身分及 initial→final／reboot 連續性 | D2.1、D2.4、E1 | 無PairId首盤點、穩定HostId／ItemId、跨attempt同journal、遺失／wrong plan／搬根停止或受控復原；不能接管外部既有物件 |
| R2-22／P0 | DeltaWorkflow.ps1:87–109 無VolumeBytes，TEMP合併blobs.bin後一個ZIP；前次「沿用delta」未履行自訂每卷上限 | D2現況、D2.2–D2.4、E1 | 新delta分卷實際上限／全卷／可信base；full與delta wrong kind拒絕；新舊入口相容、scratch不足先阻擋 |
| R2-23／P0 | Payload.ps1:83 寫export-state.json；PackageTransport.ps1:1–4只取manifest／plan／artifacts／freeze／引用payload。前次整package資料夾搬運會夾帶本機state／額外檔 | D2模式、D2.4 | 白名單集合與bytes／hash一致，缺／多檔、checkpoint／孤兒blob不入交付；額外副本列峰值 |
| R2-24／P0 | Restore.ps1:32 對既有非WindowsFeature且非CreatedByTool物件阻擋；MachineEnvironment有set／remove不代表已具原值更新／回復。installer既有TNS與全機時區更新不能只宣稱Apply | B2.5、C、D2.4 | 建立／沿用／外部驗證／受審更新分開；before漂移拒絕、原值含型別與空／不存在、回退保存prior，不刪外部物件 |
| R2-25／P0 | B1準備證據與B2實際consumer若未分phase，未搬TNS就先要求連線；全局decision變動可不當失效整份準備 | B1、E3、D2.4 | dependency有RequiredPhase／投影hash；新檔在staging驗、final後重驗有效變更；無關決策保留仍有效證據；不需先啟用全部writer |
| R2-26／P1 | D原檔名只有pair／inventory／decision，target重查同r/d會撞名；若改delivery索引記進度，seal後版本亦失真 | D、D2.4、確認模板 | 每次DocumentId／目標觀測／投影hash，新檔不覆蓋；固定交付引用與receipt分開，報告重產不改plan／payload |
| R2-27／P0 | PackageTransport.ps1:27 CreateEntry未設定固定timestamp，既有checkpoint要求原ZIPhash。從同payload重封不保證同ZIPbytes，不能混用舊索引 | D2.4 | 原卷完整則補傳；卷毀損用新transport／hash／獨立incoming，保留失敗checkpoint；來源包亦壞則停止重驗 |
| R2-28／P1 | Core.ps1:13–24 JSON read／write限128MiB、:42 envelope只允v1；PackageTransport累積members／entries。9,999卷不能證明索引與RAM可用 | D2.4、E1 | UTF8 JSON／成員／spool／RAM budgets與錯誤下一步；新格式producer／consumer完整、舊格式負例；超限不漏列、不擅拆scope |

R2-27 的 timestamp 行為另核對[Microsoft LastWriteTime 文件](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.ziparchiveentry.lastwritetime?view=net-9.0)：CreateEntry 的初始時間取建立時刻。這支持「不保證重封hash不變」的推論，並非已做重封故障實測。

## 再次複審：最後從全局回查

| 全局不變量／跨段影響 | 本次收斂結果與仍待證據 |
|---|---|
| 一台來源一份穩定身分；一個作業持續ownership | Host enrollment先於pair；輸出attempt與operation state分開，初始／final／重啟／取消同一plan沿用。新plan不可直接接舊state或略過外部衝突 |
| 需求、證據、核准沒有循環 | RequiredPhase分準備、搬入後、切換前與切換後；需求投影hash決定受影響重驗，revision／原證據仍可追；未知consumer不提前放行 |
| 已核准scope与傳輸容器分開 | 換卷大小、ZIP重封、報告重產不改plan；設定／requirements漂移另核准與baseline。full／delta有型別、可信base，交付集合精確 |
| 原值、外部持有物與新交易不被工具清理 | Keep／External不假造ownership；UpdateReviewed有compare／prior／readback／漂移回退；state備份、payload回退、新交易保存各自有責任人 |
| 可讀文件完整且可審計 | 全量軟體、排除、未知與coverage仍保留；DocumentId避免覆蓋，DeliveryId引用固定hash，後續receipt分開；新格式仍走安全投影 |
| 每個新增producer都有consumer與驗收 | enrollment／OutputProfile／typed dependency／RequiredPhase／UpdateReviewed／DocumentId／delta-volume逐一接schema、preview、approval、restore／activate、report／Fleet／LabReport、repair；未完整不得只做UI就交付 |
| 峰值、規模、信任與資格不是同一門檻 | 包＋乾淨資料夾或ZIP＋delta scratch＋incoming＋backup逐volume預檢；JSON／RAM有界；企業簽章／信任／exact資格與實機維護窗維持E2／E3待證 |

此輪結論：補強後更能作為分階段實作與驗收依據，但**規劃審查不證明工具已能正確完成企業遷移**。目前仍須完成新增consumer、Server／Oracle實測、含新交易復原與企業放行；本輪只驗文件契約、引用、完整性及改動範圍。

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

## 輸出方式續規劃核對（2026-10-09，基準9b01678）

使用者續問先指定目錄或指定大小分ZIP，建議同時提供：本機WorkRoot先建立受控分類，預設分卷ZIP／可選sealed資料夾，確認報告直接可讀。完整契約與驗收已補進 PLAN 的 D2，並由 E1／E2／E3接相容、空間／維護窗與安全交換。

| 程式事實或影響 | 核對與新增規劃 |
|---|---|
| PackageTransport.ps1:12、27–35已有VolumeBytes／NoCompression／actual size／hash／checkpoint／transport | 預設512MiB，現有API1MiB–1GiB保留；新旅程建議128–1024MiB／自訂，ZIP不承諾縮小容量；不是先造超大ZIP再切碎 |
| MigrationWizard.ps1:81的來源4只問目錄，沒有大小傳入 | D2要求選單／CLI／API／OutputProfile同一參數及預覽，不把既有核心寫成UI已交付 |
| PackageTransport.ps1:23數字minimum width四位，44匯入regex恰四位 | 推論超過9,999卷會有producer／consumer不相容；尚未做大量輸出重現。規劃在預檢阻擋10,000卷，用合成metadata驗負例，不建立大量檔案 |
| Payload.ps1:37–42的包估算與ZIP逐卷空間檢查，各只覆蓋部分階段 | 新全工作根目錄／target解包、staging、backup／新資料保留分volume計峰值，無壓縮節省假設 |
| 同一目錄全部收包可能混入state／機密／raw設定；只讀ZIP不還原ACL | 分類根目錄、明确delivery集合／安全reports／機密外部引用，ZIP承載受信metadata；資料夾與ZIP最後都走manifest／payload驗證 |
| 初始／final／delta與不同run卷混合，人工漏搬一卷 | generation／base／package identity、transport全卷清單／可信hash、交付與匯入狀態、缺卷／wrong pair／partial阻擋 |

整體回查：輸出設定不更改Include／Exclude或Oracle精確ConfigFiles，卷大小改變建立新transport run而非改sealed包；文件可讀不等於核准，sealed不等於transfer verified，解包不等於restore／activate，備份目錄不等於整機備份或新交易回退完成。外部加密wrapper可能增加單檔大小，媒體上限另驗。

本次只更新文件並同步確認模板／入口，D2新旅程與門檻尚未實作；現有ZIP及取消fixtures未重跑，沒有新增實機PASS。依[Microsoft CompressionLevel](https://learn.microsoft.com/en-us/dotnet/api/system.io.compression.compressionlevel?view=netframework-4.8.1)與[filesystem比較](https://learn.microsoft.com/windows/win32/fileio/filesystem-functionality-comparison)核對封裝及媒體差異，不新增第三方安裝依賴。

## 程式現況增補（2026-10-09）

以下是本輪 source-level implementation recheck，更新上段歷史基準中的「尚未實作」狀態；不代表任何真實 Server、Oracle、企業 PKI 或業務交易已取得資格。

| 新增閉環 | 已核對實作與邊界 |
|---|---|
| Windows settings review | `WindowsSettingsReview.ps1` 的 `Get-WsmWindowsSettingsReviewWorkspacePreview`／`Invoke-WsmWindowsSettingsReviewWizard` 以可信 source／target path+hash 建立專頁；source 必須吻合 catalog 的 inventory hash、fingerprint、revision 與 item SettingsHash。Preview 綁兩端 hash／revision、exact setting value hash 與所需 consumer。PATH／hosts 提供可讀但不可自動搬的人工合併清單；秘密與未知值 redacted。NO 僅選 class-wide KeepTarget。`Apply-WsmWindowsSettingsReview` 重讀輸入、核對 preview 與 `ExpectedRevision`，在 scratch catalog 執行 GeneralHost disposition／requirement preview+set、完整驗證後，才於鎖內以單次 catalog hash/revision compare-and-swap 寫入；每個設定的每個 consumer 都各有 exact value-hash requirement，不把同 consumer 的設定合併。Required consumer 未解除；Migrate 僅轉 `Pending`，沒有自動 Include。Apply fixture 覆蓋無效 decision 與注入最終寫入失敗時 catalog bytes 不變。 |
| 遞送 seal/import receipt | `DeliveryReceipts.ps1` 對 Zip／Directory × Full／Delta 建立 `Sealed` 與 `ImportedVerified` receipt 及可讀 `delivery.md`；Delta 綁可信 base 與 current/import summary。管理端 `Import-WsmDeliveryReceipt` 只接納與現行 approval、plan、generation、package、transport 及模式一致的 receipt。`Get-WsmDeliveryReceiptSummary` 提供 Fleet 摘要；Lab report 的 `-DeliveryReceiptReferences` 可引用可信 receipt。所有 receipt 與報告引用都是 ReportOnly，`ReadinessProof=false`、`ProductionVerified=false`，不放行 readiness 或正式生產。 |
| WorkRoot 受控搬移／回復 | `WorkspaceTransfer.ps1` 的 transfer／restore preview 固定來源與目的根、enrollment identity/revision、完整檔案集合與容量；套用要求精確 preview hash、`MIGRATE-WORKROOT` 與 `-StoppedAllTools`。鎖與掃描不能證明已載入 process 停止，這是 operator 前置條件。原根以 transfer marker fail closed；中斷時從原／新根產生 recovery preview，核對 marker／copy hash，再依 preview 執行回復，保留且阻擋無法證明為搬移副本的部分資料。不是備份或跨主機遷移。 |

本次新增與固定 snapshot regression 於 Windows PowerShell 5.1 和 PowerShell 7 執行 Windows settings contract fixture；snapshot 內 source/test bytes 前後 SHA256 相同。這只驗證本機契約與 atomic failure fixture，不證明 Windows Server 2016／2025 實機、真實服務／Oracle consumer、企業憑證信任、RPO/RTO 或生產維護窗。`MIGRATION-2-PLAN.md` 的執行 TODO 仍以其核准紀錄為準，本增補不將任何外部實機項目標為完成。


## 最後原生 producer-consumer 與 TODO 比對

最後補齊原生 MachineEnvironment 原型別／空白與不存在、TimeZone/DST、Firewall ActiveStore/TracePolicyStore 與完整列舉 marker。source-after 與 target-before/type/DST 精確對照既有受審 spec；來源及目標 GPO/Unknown 均不可一般自動搬入。完整 Export-WsmInventory JSON→review helper、filter 中斷、特定缺口及 WinPS5.1 JSON 整數型別正反例通過兩引擎。

交付 MD／receipt／Manager-Fleet-Lab、Windows 專頁／CAS／required 相依、WorkRoot 搬移／中斷回復已實作及驗證，對應未實作 TODO 已刪除。本文件前期「只改規劃」結論為歷史，最新狀態和固定快照見 [MIGRATION-2-VERIFICATION.md](MIGRATION-2-VERIFICATION.md)。真實 Server／Oracle／PKI／業務／維護窗和不同模型體檢仍未取得，不宣告正式企業資格。
