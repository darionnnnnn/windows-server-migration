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
13. 必要跨主機 provider 需提供 24 小時內的 Cutover 成功結果及獨立可信摘要；無證據拒絕切換。循環跨主機應用尚需專用一致性程序，不能靠同時啟用繞過門檻。
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

network JSON 欄位：FinalName、InterfaceAlias、FinalIP、PrefixLength、DefaultGateway（可選）、DnsServers、TemporaryIP、DomainProcedureEvidence、RollbackProcedure、Owner、MaintenanceWindowUtc、ValidUntilUtc。自動 IP 切換目前只接受明確 IPv4；IPv6、多 NIC、LB、SPN／委派等走專用審核程序。DomainRename 可經 API 記憶體 Secrets 提供網域憑證。

provider 證據索引：`{ "Entries": [{ "Path": "D:\\Inbox\\provider-result.json", "SHA256": "獨立可信摘要" }] }`，交給 CutoverPlan 的 DependencyEvidencePath／DependencyEvidenceHash。

## 中斷、重試與回退

同一配對只允許一個本機寫入者。檔案鎖依作業系統 handle，不能為「解鎖」刪除 state／journal。每個事件先 flush，再更新 checkpoint；中斷造成日誌比 checkpoint 超前時，選目標「修復 checkpoint」，核對整條 hash chain 及原 checkpoint 前綴後重播。未知／毀損事件阻擋，保留證據。

FileScope 使用核准根目錄旁的生成 staging／backup；prepared checkpoint 必須與實際目標或 staging digest 一致才能採認／完成搬換。無法對應實際狀態時需要人工協調。實際 adapter 中斷與切換啟用後的半完成狀態仍有待補強項，詳見實作清單。

回退先輸出具體 preview hash，再確認 `ROLLBACK PairId`。只移除工具建立的物件，或更換先前歸屬的根目錄；保留回退時的新資料根目錄。目標可能已有新交易時，強制 RollbackReconcile 證據，絕不自動啟舊來源。角色移除、網域／名稱／IP 回復依核准專用程序，避免兩台同時接手寫入。

工具鎖與 journal 不抵抗本機 administrator 改寫，可信來源、企業權限与材料交換仍是管理責任。

來源停寫先保存原始設定及啟用狀態到受控 SourceFreezeAttempt。部分失敗不產生成功 handoff；錯誤給出 attempt 路徑與摘要，使用 PreviousAttemptPath／PreviousAttemptHash 重試。重試會核對原核准基準，只容許已發生的停寫差異，不會把其他設定漂移當作新基準。過期 freeze 可透過 PreviousFreezePath／PreviousFreezeHash 更新，但仍須重新提供 owner 證據。

來源回復是獨立的明確操作：管理精靈來源角色「明確回復來源」或 SourceResume API，先核對原始狀態，再確認 `SOURCE-OWNERSHIP-RESTORED PairId`，提供目標已停写／資料已協調／來源擁有唯一寫入權的證據。工具才回復原本的 startup／enabled／running 狀態。這是人工確認的離線所有權交接，不能抵抗另一台主機被另外啟用；不會因目標回退自動啟動來源。同一来源配對的 freeze／resume 共用本機操作鎖。

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

一般 adapter 回退先寫 intent，再停用、驗證 staging 和刪除工具所建立物件；中斷後 RepairOperation 對已刪除的物件完成 checkpoint，不再次刪除。設定漂移或所有權／規格不符阻擋。角色安裝中斷的 boot baseline 已在原生安裝之前落盤；無法確認安裝器回傳時，重開機門檻維持到實際 boot stamp 改變。角色安裝器的自啟動副作用隔離仍是未完成項。
