# 0.3 操作契約

本版持續補實作，僅供明確批准的隔離 pilot。來源、目標與管理工作區各自本機執行。不得用此文件宣稱實際十台已完成遷移。

## 離線旅程

1. 將相同工具版本複製到所有操作端。管理端可用 `Export-WsmToolRelease` 產生只含工具的 ZIP；其獨立 SHA256／企業簽章信任由管理者核對。工具不會修改 policy。
2. 來源選 1 盤點。每台固定其受控狀態目錄；有權限時選深層探索。輸出設定 JSON、盤點 ZIP 及能力／失敗項；原始設定可能含敏感資訊。可在角色精靈來源端匯出 raw evidence 索引。
3. 管理端建立工作區、匯入可信盤點並配對目標暫用名稱；匯入兩份 catalog／fleet 採持久交易。若中斷，所有後續读寫阻擋，選精靈管理端「工作區交易修復」，保留 transactions 證據。
4. 每類逐項決定 Include／Exclude、排除理由、責任人、未知項的補查證據；大量資料用 CSV／跨頁规则 preview／undo／條件模板。分類 HTML 每頁 100 列，同名文字檔保留完整清單。
5. 目標精靈登記 TargetIdentity，將 JSON 及獨立可信 hash 交管理端。管理端對每個 Include 設定 MigrationSpec、必要相依、資料 scope／排除／最終狀態；需要 SID 改映時另核准 IdentityMap。
6. 管理端核准 MigrationPlan。必須確認 `ISOLATED-PILOT`；批准文件綁定主機指紋、版本、所有決策、規格及**工具精確位元組指紋**。更改工具後需重新核准，不能在中途替換工具。
7. 來源端先容量／scope 預檢，匯出 package。Immutable 適用不變資料；其他 scope 必須有來源責任人停寫證據。工具重新盤點並比對核准設定，不能靠舊 revision 替代現況。
8. 來源端分卷 ZIP，傳遞 transport.json、所有 ZIP 及獨立可信 hash。目標端受信匯入；索引、大小、路径、每塊和整檔均核對。中斷匯入可用同一 trusted transport 重試。
9. 目標還原 preview 顯示建立、驗證跳過、衝突、空間、回復與機密要求。一般同名設定／不屬於工具的資料阻擋。實際還原將排程、服務、IIS、使用者、防火牆規則保留停用，分享加存取阻擋。
10. 填寫每項 BusinessStaged；ManualWorkflow 另提供 ManualRestore 證據。執行 Staged 驗證並匯出結果，回管理端匯入。指令成功、hash 正確或 HTTP 200 均不能取代業務驗收。
11. 維護窗來源停寫，再匯出 final package。final 是新的完整 scope 快照，使用內容去重、綁定前一 manifest；目標只更換先前工具歸屬且未漂移的根目錄，原根目錄保留為 backup。所有舊代次證據失效。
12. 完成舊名稱／IP／網域身分釋放的專用程序及證據，重新驗證 final staging。產生切換計畫，再確認精確 `CUTOVER PairId`。若改名需重開機，工具回 RebootRequired，重開後重新核對再續行，不自動重開。
13. 必要跨主機 provider 需提供 24 小時內的 Cutover 成功結果及獨立可信摘要；無證據拒絕切換。循環跨主機應用需先建立有責任人與外部一致性程序的 GroupPlan，所有成員提供本代 FinalStaged receipt，再透過可信群組索引產生 CutoverPlan；缺少、過期、版本或 manifest 不符均阻擋。這是離線證據門檻，仍需實際應用停寫協調。
14. 啟用後逐項 BusinessFinal，以及 DNS／Kerberos／外部連線／監控／資安代理／許可／使用者接受。FinalAccepted 與 RetirementReady 分開；後者另需實際備份還原、長週期工作、觀察期和保留清理證據。工具只報告門檻，不刪除舊機。

## 規格與機密

`New-WsmMigrationSpecTemplate` 產生草稿，必須補足所有空白及產品特有設定再核准。FileScope 的 SourcePath／TargetPath 必須明確絕對路徑；ExcludedRelativePaths 是 literal 子路徑。Metadata 可用 DaclOwner 或 DaclOwnerSacl；後者需要來源與目標的安全權限。磁碟根目錄、reparse、ADS、EFS、未知 SID、重疊 workspace、未批准覆蓋會阻擋，不能默默漏掉。

大量 Include 使用管理精靈的「批次規格草稿／預覽／提交」：匯出帶 Batch／Pair／兩種 revision／SettingsHash 的 bundle，填完各列 MigrationSpec，先預覽件數、樣本與問題再 APPLY-SPECS。無效一列整批不寫入；删列只是不修改該項，不是排除。一次提交只增加一次 DecisionRevision，核准失效。FileScope 路徑目前採已驗證的 239 字元限制，更長路徑明確阻擋並需專用流程。

ACL 預設 `AclControlPolicy=Exact`，連 SDDL 控制旗標都須相同。不同 Windows 寫入 ACL 時可能新增 AI 自動繼承旗標；CI 已重現 ACE 完全相同而 AI 增加的情況。若企業批准此繼承模型轉換，可在 FileScope 明確設定 `AllowAutoInheritedUpgrade` 並重新審核；此政策只允許 AI 增加，owner／group／每個 ACE／P 與 AR 仍須精準相同，且不允許降級。這是核准的差異，不能宣稱 ACL 位元組完全還原。[Microsoft 控制旗標定義](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-descriptor-control)

IdentityMap 是 `{ "Mappings": [...] }`；每列需要 SourceSid、TargetAccount、ExpectedTargetSid、CreatedByItemId、Owner、Evidence。ExpectedTargetSid 可留空，由目標實際解析；CreatedByItemId 若指定，必須是納入的 LocalUser／LocalGroup。來源 SID 不會因主機同名而恢復。任意 runtime SID override 不接受。

SecretRef 只是代號。精靈按代號提示 PSCredential，密碼僅在記憶體；非互動有機密的操作可從 PowerShell module API 提供 `-Secrets @{代號=$credential}`。OperationRequest 不接受密碼或 Secrets 欄位。PFX 從外部受控材料取得，需 artifact hash；鏈憑證必須分開核准，禁止順帶匯入未列項。

ManualWorkflow 需要 Product、Procedure、Artifacts、BusinessChecks、Owner、Evidence，供 AD／CA／叢集／SQL／第三方安裝／許可等專用程序。這是明確的人工作業及證據門檻，**不是已實作該產品的自動還原**。未知角色不能自動排除。

## 非互動請求

```json
{
  "SchemaVersion": 1,
  "ToolVersion": "0.3.0",
  "Kind": "OperationRequest",
  "Action": "RestorePreview",
  "Arguments": {
    "ManifestPath": "D:\\Inbox\\manifest.json",
    "ExpectedHash": "填入獨立可信的64字元SHA256",
    "StateDirectory": "D:\\MigrationState"
  }
}
```

將請求另存並取得可信 SHA256，使用入口 `-Action Operation -Path ... -ExpectedHash ...`。`Get-WsmOperationActions` 列出白名單；每個動作參數使用相同 module API。請求只含 typed data，不允許任意命令、package scripts、Debug 或 common parameter 注入。

network JSON 欄位：FinalName、InterfaceAlias、FinalIP、PrefixLength、DefaultGateway（可選）、DnsServers、TemporaryIP、DomainProcedureEvidence、RollbackProcedure、Owner、MaintenanceWindowUtc、ValidUntilUtc，以及 ObservationHours（整數 1–8760；未填則切換計畫明列 24 小時）。自動 IP 切換目前只接受明確 IPv4；IPv6、多 NIC、LB、SPN／委派等走專用審核程序。DomainRename 可經 API 記憶體 Secrets 提供網域憑證。

provider 證據索引：`{ "Entries": [{ "Path": "D:\\Inbox\\provider-result.json", "SHA256": "獨立可信摘要" }] }`，交給 CutoverPlan 的 DependencyEvidencePath／DependencyEvidenceHash。

## 中斷、重試與回退

同一配對只允許一個本機寫入者。檔案鎖依作業系統 handle，不能為「解鎖」刪除 state／journal。每個事件先 flush，再更新 checkpoint；中斷造成日誌比 checkpoint 超前時，選目標「修復 checkpoint」，核對整條 hash chain 及原 checkpoint 前綴後重播。未知／毀損事件阻擋，保留證據。

FileScope 使用核准根目錄旁的生成 staging／backup；prepared checkpoint 必須與實際目標或 staging digest 一致才能採認／完成搬換。無法對應實際狀態時需要人工協調。切換每個物件先寫 ActivationIntent，原生啟用後再寫完成紀錄。中斷後選目標「明確續行啟用」，提供負責人與協調證據；只有 exact-staged 或 exact-final 狀態可續行／採認，漂移與不明半完成狀態保留現場並阻擋。其他 adapter 原生半完成情境仍依實作清單驗證。

回退先輸出具體 preview hash，再確認 `ROLLBACK PairId`。只移除工具建立的物件，或更換先前歸屬的根目錄；保留回退時的新資料根目錄。目標可能已有新交易時，強制 RollbackReconcile 證據，絕不自動啟舊來源。角色移除、網域／名稱／IP 回復依核准專用程序，避免兩台同時接手寫入。

工具鎖與 journal 不抵抗本機 administrator 改寫，可信來源、企業權限与材料交換仍是管理責任。

來源停寫先保存原始設定及啟用狀態到受控 SourceFreezeAttempt。部分失敗不產生成功 handoff；錯誤給出 attempt 路徑與摘要，使用 PreviousAttemptPath／PreviousAttemptHash 重試。重試會核對原核准基準，只容許已發生的停寫差異，不會把其他設定漂移當作新基準。過期 freeze 可透過 PreviousFreezePath／PreviousFreezeHash 更新，但仍須重新提供 owner 證據。

來源回復是獨立的明確操作：管理精靈來源角色「明確回復來源」或 SourceResume API，先核對原始狀態，再確認 `SOURCE-OWNERSHIP-RESTORED PairId`，提供目標已停写／資料已協調／來源擁有唯一寫入權的證據。工具才回復服務／IIS 原本的 startup／enabled／running 狀態與分享原始 ACL。排程只回復 enabled，不會重新執行被中斷的工作；原本 Running 的排程必須先提交 SourceTaskReconciliation JSON 與可信摘要，逐項證明已協調或無待處理工作。來源選項 8 可輸出待填草稿，草稿本身不能解鎖回復。這是人工確認的離線所有權交接，不能抵抗另一台主機被另外啟用；不會因目標回退自動啟動來源。同一来源配對的 freeze／resume 共用本機操作鎖。

## 漏跑政策與操作取消

ScheduledTask 規格必須填 CatchUpPolicy，草稿 ReviewRequired 不可核准。PreserveSourceSettings 保留 XML 的 StartWhenAvailable；SkipMissedRuns 與 DedicatedManualCatchUp 會將它設為 false。專用補跑須由 owner 依 BusinessChecks 提供不重複交易的程序及驗收；工具不執行任意補跑腳本，這個選项不表示已補跑成功。

各步驟輸入 0 取消，需字面文字 0 時輸入 literal:0。審核子選單錯誤保留原頁，篩選全部輸入且驗證成功才更新。輸入結束會退出，不無限重試。網域改名認證由目標精靈詢問並使用 DomainRename 記憶體 credential；認證不寫入請求與包。

分類報告列出 scope、排除、一致性、metadata、ACL／漏跑政策、最終啟用狀態及規格雜湊；Desired 原始配置保留於受控 catalog，報告只附其 hash。正式 owner 審核仍需閱讀受控 Desired，不能只看 hash 判定正確。

來源與目標工作目錄不可和資料 scope 相等、包含或被包含。來源 freeze／resume 及目標預覽／還原在建立操作目錄之前先檢查，避免工具證據混入業務資料。

## 檔案回退中斷

檔案回退先寫 durable RollbackIntent，保存目前內容與前代備份雜湊、固定的 displaced 保留路徑。若中斷，先執行 RepairOperation；它驗證 target／retained／backup 是否符合原意圖，再完成原來的重新命名。任何內容漂移都阻擋，不刪除現場。已回退項目不會再次選入新回退预覽；新交易可能存在時仍必須先有有效 RollbackReconcile owner 證據。設定回退不會自動啟動來源或代表交易資料已安全回復。

## 實體路徑、大索引與錯誤診斷

在實際來源／目標，以既有祖先的檔案 handle 取得 NT 裝置路徑，再附上尚未建立的子路徑，檢查 SUBST／多磁碟代號造成的同一實體資料碰撞。管理端仍只做文字映射預檢；實際目標要再次核對。重解析點明確阻擋。SMB／遠端 UNC 的伺服器與 share 別名目前沒有通用可靠判定，generic FileScope 阻擋並要求専用 alias／ownership 流程，不能把它視為已完成的 UNC 遷移。API 依據：[GetFinalPathNameByHandleW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew)。

包驗證串流讀取受信任 JSONL，同時逐 chunk／整檔驗證；重複目的地使用固定 5,000 個鍵 hash 的緩衝及最多 64 路的磁碟合併。檔案 metadata 核對型別、資料／目錄、ACL、UTC、bytes；實際還原亦比較 creation／last-write 时间。時間戳記單獨漂移也會阻擋重試。ADS、junction、鎖住檔案與未驗證長路徑不會靜默略過。

選單錯誤另顯示 Category／NativeCode／Hint；timeout、權限、容量、檔案鎖、無效輸入、查無服務及待刪除服務有個別處理建議。還原失敗的 item 與 durable journal 保留原生碼和分類，不含 stdout／參數／密碼。建議不會自動重試有副作用的操作；先核對實际狀態。

SMB 分享完整比對所有預期 ACE，額外授權也屬漂移，帳號以目標 SID 比對；Everyone 的顯示名稱依本機語系解析。啟用只移除工具的暫時 world deny，規格原先明確要求的 world deny 會保留。Block-SmbShareAccess 只能建立 Full deny，Read／Change deny 必須専用流程；它們不會被工具默默放大。停用分享不表示已關閉所有既有 SMB open handles，停寫與資料協調證據仍必須包含既有客戶端的排空／關閉。

一般 adapter 回退先寫 intent，再停用、驗證 staging 和刪除工具所建立物件；中斷後 RepairOperation 對已刪除的物件完成 checkpoint，不再次刪除。設定漂移或所有權／規格不符阻擋。角色安裝中斷的 boot baseline 已在原生安裝之前落盤；無法確認安裝器回傳時，重開機門檻維持到實際 boot stamp 改變。角色安裝要求先提供 IsolationEvidence 與已審核 SideEffects，原生呼叫前保存 baseline，呼叫返回或失敗後隔離工具確認的新服務／排程／IIS consumer，再逐項核對。這無法保證安裝器尚未返回時沒有自啟動；操作者必须在安裝前建立隔離環境，實際產品仍需專用程序及 Server 驗收。

## 服務帳號與觀察期

Service 的 own-process Supplement 保留 recovery／trigger／SID type／required privileges／environment／delayed auto-start 等已審核設定；staging 保持 Disabled 並抑制 recovery／trigger。LocalSystem、LocalService、NetworkService 不需 SecretRef；一般帳號需明確 UserPassword 和記憶體認證。DOMAIN\sam$ 必須明列 ManagedServiceAccount、ManagedAccountEvidence，且目標 Test-ADServiceAccount 通過；名稱尾端 $ 不會自動視為具備 gMSA 資格。原生 NULL 密碼建立路徑仍需實際 AD／SCM 驗收。

Observation 通過證據只能在完成啟用後、經過切換計畫所列 ObservationHours 時登錄。ActivatedUtc 與時數寫入 durable journal，中斷修復會保留。Acceptance 回傳尚需等待的窗口；時間經過仍需負責人提供觀察結果與業務證據，不能單憑計時器判定成功。

Win32 錯誤分類保留原生碼與 HRESULT，並提供登入失敗、相依失敗、服務程序中止與 SMB 認證衝突的建議，不會自動重試有副作用的操作。[Microsoft 系統錯誤碼定義](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1000-1299-)
## 設定檔審核與資料增量

來源角色 10 讀取可信 FileScope 規格草稿，逐檔輸出設定檔審核 JSONL。它辨識 web.config、app.config、*.exe.config、appsettings*.json；排除的路徑不列入，名稱相同的目錄不算設定檔。草稿只含 RelativePath、SHA256、Owner、Evidence，不複製設定內容；輸出另回報草稿 SHA256、項目識別及待負責人審核狀態。Owner／Evidence 留白，負責人必須審閱原設定並填入，將各列（含核准的精確 SHA256、Owner、Evidence）放進規格的 ConfigFiles 陣列後再提交規格與核准計畫。來源單檔 scope 的 RelativePath 是空字串。

其他設定檔可用 ConfigOverrides 明列精確相對路徑及 Classification=Configuration，再於 ConfigFiles 登錄核准雜湊。若已辨識檔名實際是業務資料，需明列 Classification=BusinessData、Owner、Evidence、Reason；不得使用 wildcard 或以 BusinessData 覆蓋既有 ConfigFiles 基準。BusinessData override 路徑不會輸出為設定草稿列；Configuration override 路徑會納入掃描。辨識規則不能代替應用負責人的完整設定清單，未知副檔名須由負責人補列。

完整包驗證及增量入口均核對 ConfigFiles 的核准內容。新增、修改、刪除或改名造成基準不符時，封裝／增量建立失敗；保留未封存工作區，回管理端重審規格與計畫，重新建立該核准的初始基準。同一核准的業務資料變更仍可走 initial／final 增量；設定內容相同的 metadata 變更另由 FileScope metadata 契約驗證。分類報告列出核准設定路徑、雜湊及例外理由，不顯示設定內容。

## 增量 ZIP 與取消作業

角色精靈的來源 9 可建立／檢查 initial、final 差異清單並匯出增量 ZIP；目標 15 可匯入、預覽、套用及修復。initial、final 必須來自同一核准計畫，final 帶來源停寫證據；差異清單分新增、修改、metadata-only、刪除及未變動。目標逐項核對工具 ownership、原始完整 scope hash 和可信 baseline，漂移即阻擋，不自行覆蓋陌生內容。套用前也會對每個仍納入的 FileScope 核對基底世代的持久 ownership、目標路徑及即時完整 scope digest；即使該 scope 沒有差異，只要設定或資料漂移也會阻擋。刪除只發生於已核准且工具擁有的 scope staging。

增量傳輸只攜帶變動 payload；目標使用已驗證的既有資料補齊完整本機 package，再執行原有完整性、staged validation 與切換門檻。若核准計畫包含 ManualWorkflow，增量後仍維持 ManualEvidenceRequired；既有 ManualRestore 證據必須綁定目前 manifest／generation，舊代次證據需重新提交。成功結果的 DeltaPackageManifestPath／Hash 是後續驗證、切換、結果與報告的輸入。原內容保留在 transaction 所列 sibling backup；目錄交換中斷使用目標 15 的修復，依實際 hash 接續，不手動刪除 transaction／備份。設定、scope、映射或相依變動需要重新核准，不能沿用資料增量取代設定審核。

主要匯出／ZIP／還原與增量操作會顯示本次 OperationId、取消控制檔及 SHA256。來源 scope 與目標 ZIP 匯入／匯出會在預檢、hash、列舉及資料區塊等安全邊界檢查取消；作業先驗證 CancellationToken 型別，並核對 Pair、PlanHash、ManifestHash（尚未有 manifest 的來源封裝階段使用空值）、OperationId 與本機狀態目錄。需停止時，另開同一主機、同一管理員帳號的 PowerShell，進角色精靈 5，輸入可信控制檔、負責人及理由；離線取消請求不會自動跨主機傳送。舊請求不會取消新作業。安全邊界停止時保留 sealed chunks／ZIP volumes／staging／journal，不封存不完整包。原子目錄交換期間不插入取消，先完成可辨識的交換狀態。檢查並修復 checkpoint 後，使用新的作業控制檔重試；Ctrl+C 或關閉程序視為非協調中斷，需先修復。

RestoreAttempt 與已套用 ManifestHash／Generation 分開保存。尚未套用就失敗或取消，也可匯出對應本次嘗試的 Restore StageResult；取消狀態保持 Cancelled，集中報告不改成 Succeeded。CLI 成功 0、失敗 1、阻擋 2、取消／輸入結束 3、已分類契約輸入錯誤 4。原生輸出只保留有界計數、摘要與程序結果；不完整輸出的 rolling digest 不是完整串流 SHA。owned process 退出證明不等於子程序或服務已停止。子程序持有 pipe 時，背景 reader close／handle 清理可能在呼叫返回後完成，必須另核對實際 OS 副作用。

## 排程安全描述元

排程盤點捕捉 task 與所有 ancestor folder 的 owner／group／DACL，不聲稱包含 SACL。草稿的 Desired.SecuritySddl／FolderSecurity 必須經負責人審核，來源擷取失敗保持缺口。既有目標資料夾只做 exact ACL 驗證，不覆寫 ACL；新建資料夾先記 intent、驗證後取得工具 ownership receipt。共用資料夾由 pair-wide receipt 追蹤，回復只刪工具擁有、ACL 相符且已空的資料夾；建立後未取得 readback 的模糊狀態保留現場供協調，不自動採認或刪除。

## CSV 審核與離線報告

CLI `ImportCsvPreview` 讀取 CSV 後輸出 `SourceHash`、`DecisionRevision`、列數及變更預覽，不提交決策。接著以同一 CSV 的 `-ExpectedHash`（預覽 `SourceHash`）及 `-ExpectedRevision`（預覽 `DecisionRevision`）呼叫 `ImportCsv`；兩個參數都必填。缺少其中一個不執行匯入；CSV 雜湊或 catalog revision 在預覽後改變時會拒絕套用，必須重新預覽。預覽會驗證 CSV 身分與唯讀欄位、允許決策及 Exclude 理由；成功套用時 DecisionRevision 遞增並使既有核准失效。

HTML 報告將資料以每塊 250 列嵌入離線頁面，最多快取 4 塊並採最近使用順序。頁面每次呈現 100 列，分類摘要列出總數、Include／Exclude／Pending 與不適用數。搜尋及分類篩選會掃描完整離線清單；列印符合項目上限為 2,000 筆，超過時須縮小條件。報告只代表最後匯入資料，不是即時主機狀態。

來源角色 11 的 `Export-WsmConfigArtifactReview` 對可信 MigrationPlan 產生即時設定差異 JSON 及 JSONL：Added／Modified／Deleted／Unchanged。輸出位置不得與來源 scope 重疊，已有父目錄必須符合受控 ACL；設定內容不會寫入差異報告。RequiresReapproval=true 時回管理端更新 ConfigFiles／分類／證據及核准，重新建立初始搬移包。舊 plan 的 delta 不能跨核准沿用；目標已有工具 ownership 時，先按明確回退／資料協調流程處理舊核准，不會自行接納新的核准覆蓋原 baseline。

有取消控制檔的長時間 hash／copy／原生工具等待會在本機 pair 目錄更新 `progress-<OperationId>.json`，至多約每秒一次、每筆上限 4 KiB。僅列階段、bytes、耗時與最後活動時間，不含檔名或 stdout；完成或取消後清除暫時進度。原生工具的初始活動時間是輸出讀取器啟動時間，之後只有實際觀察到輸出才更新，等待計時器不代表子程序有進展。timeout／取消的最終診斷仍保留於結果及 journal；不會把暫時進度當成 checkpoint。
## 測試主機結果複製貼回

兩台隔離 Server 部署相同 commit 的工具後，先在每台的 64 位元管理員 Windows PowerShell 5.1 執行環境檢查。角色選單 6 選 Source／Target，再選 1；也可使用 CLI：

```powershell
.\Start-ServerMigration.ps1 -Action LabReport -Role Source -Path D:\MigrationLabReports
.\Start-ServerMigration.ps1 -Action LabReport -Role Target -Path D:\MigrationLabReports
```

執行結果列出 `TextPath`、`JSONPath`、`JSONSHA256`。開啟 TextPath 的 `lab-validation.txt`，複製整份文字貼回本對話；可用下列命令讀取或複製，將路徑改成實際輸出值：

```powershell
Get-Content -LiteralPath 'D:\MigrationLabReports\lab-validation-<run>\lab-validation.txt' -Raw
# 有剪貼簿的主機可選用：
Get-Content -LiteralPath 'D:\MigrationLabReports\lab-validation-<run>\lab-validation.txt' -Raw | Set-Clipboard
```

環境檢查的 ApprovedPackage=NotTested 是預期結果：尚未提供核准包就不能驗證還原。報告使用固定機器指紋與 RunId 區別多台主機，顯示 OS／Windows installation type（例如 Server Core）／語系／PowerShell edition／language mode／工具指紋；不是正式產品資格。

依前述離線旅程產生可信包並完成隔離還原後，角色 6 選 2 或執行：

```powershell
.\Start-ServerMigration.ps1 -Action LabReport -Role Target -Phase Staged `
  -Path D:\MigrationLabReports -ManifestPath D:\MigrationPackage\manifest.json `
  -ExpectedHash '<獨立可信manifest SHA256>' -StateDirectory D:\MigrationTargetState
```

來源端同樣可提供 manifest 和可信 SHA256，重新盤點並核對來源設定、scope；不需要目標 StateDirectory。目標必須先有精確符合 package 的本機 state／journal；檢查期间持有既有 operation lock，其他本機操作進行中就拒絕產生報告。不一致不會自動修復。Final 檢查需已完成 activation 的 checkpoint，不能用停止中的 staging 宣告最終驗證。這個入口僅做讀取檢查及寫報告，不啟停服務、不還原、不改名／IP，也不替操作者建立業務證據。

TXT 預設最多列 200 項，FAIL／Blocked 優先，再列 NotTested／PASS；明示顯示及省略數，JSON 保留完整清單。Module API 可用 `-TextCheckLimit 1000` 調整顯示上限。若摘要省略仍有問題的項目，保留 JSON，依後續指定的 ItemId／分類提供細節，不把省略數視為已通過。未完成業務／人工程序保持 NotTested；2 代表尚有阻擋，不代表報告沒有產生。

每次產生新 run 子目錄，不覆寫舊證據。輸出位置不得與來源／目標 scope 或 operation state 重疊。回傳內容只含檢查狀態、設定／狀態摘要、原生錯誤分類與代碼；受控來源 collector 原始資料留在本機報告子目錄，請勿將原始 inventory／設定直接貼回或加入公開 GitHub。報告未簽署，SHA256 用於核對 JSON 完整性；真正產品及業務資格仍依原 PLAN 的實機正反例、重開機／故障與回退演練逐項確認。