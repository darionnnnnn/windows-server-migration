# 第 2 輪一般主機操作閉環

本流程供受控隔離 pilot。Windows Server、Oracle 實際帳號／產品、企業 PKI 與業務驗收仍需外部實機證據；本機 fixture 通過不等於正式上線資格。所有主機使用相同工具 bytes，以系統管理員的 64 位元 Windows PowerShell 5.1 執行。

第 3 輪輔助搬移預設全選／可自訂；**全部使用者功能與文件以HTML入口**，本機PowerShell執行／文字備援。軟體可選新版取代強制同版，原設定預設原路徑保存並另驗新版生效；不合併目的既有文件，HTML列無法放置及人工重試，非IIS不新增adapter。全新Windows／JSON／還原前直接或等待補裝／逐項續跑保留。全部尚未實作；下文仍是現行文字選單、Markdown及準備門檻，第三輪需遷移全部使用者入口而非假裝已有按鈕。詳見 [MIGRATION-3-PLAN.md](MIGRATION-3-PLAN.md)。

## 工作目錄與交付

首次在來源指定 WorkRoot（主選單 1）；工具註冊穩定 HostId 與 source-state，輸出 inventory 並包含全部已發現軟體及 coverage。管理端使用自己的 workspace。目標角色精靈先註冊自己的 WorkRoot，再使用穩定 target identity 與 pairs 狀態。不要把來源 state 複製為目標 state，也不要在失敗後換 attempt 以重建 operation state。

建議預設分卷 ZIP 512 MiB；介面可選整數 128–1024 MiB。每卷為獨立封裝，沒有壓縮容量承諾。封存資料夾模式使用乾淨白名單副本。兩種模式都需完整可信 manifest／transport 索引與全部成員；不能手動解壓後視為完成還原。先估算每個磁碟的 package、副本、scratch、incoming、既有目標及回復保留空間。

輸出偏好只影響新 attempt；既有 attempt 的模式／卷大小固定。原 WorkRoot 的 enrollment、source-state、catalog、operation state／journal 必須持續保存。不同 plan 不能直接沿用舊 state；先完成舊作業的 reconciliation 與新基線審核。

## 管理者與 owner 確認

管理端匯入可信 inventory，主選單 23 查看分類；24 選 GeneralHost；25 輸出完整環境確認 Markdown、JSON、HTML、TXT、CSV。每次輸出都有新的 DocumentId。全部軟體列都保留，包含排除、未知、人工補登與使用者 scope；未載入 profile 或超過搜尋預算要交給指定 owner 補查。報告可註記，但勾選或修改 Markdown 不會更新核准／gate。

主選單 22 的操作請求使用固定 allowlist。輸入均為資料，請求不能包含執行命令。先使用 DispositionPreview／RequirementPreview，核對來源 hash 與 DecisionRevision，再使用 DispositionApply／RequirementApply。每次改動使核准失效，重新輸出文件並重新核准。

API 預覽後可取得與套用契約一致的 hash：

```powershell
Import-Module C:\MigrationTools\src\WindowsServerMigration.psd1
$preview = Get-WsmGeneralHostRequirementPreview -Workspace D:\Manager -PairId $pairId -Path D:\Review\requirements.json -ExpectedHash $reviewFileHash -ExpectedRevision $decisionRevision
$preview | Format-List
$previewHash = Get-WsmGeneralHostPreviewHash -Preview $preview -Kind Requirement
# owner 確認完整預覽後才執行下列套用
Set-WsmGeneralHostRequirements -Workspace D:\Manager -PairId $pairId -Path D:\Review\requirements.json -ExpectedHash $reviewFileHash -ExpectedRevision $decisionRevision -ExpectedPreviewHash $previewHash
```

Disposition 使用 Kind=Disposition，JSON 為 `{ "Dispositions": [...] }`；每列只能指向一個 ItemId 或 SoftwareId，包含 ScopeDisposition／Owner／Reason／Evidence。物件選 Migrate／Prepare／External／NotNeeded；軟體選 Reinstall／Portable／KeepCompatible／External／NotNeeded／Unknown。特殊產品不得選自動搬移；必要相依選 NotNeeded 仍會阻擋 consumer。

Requirements 使用 `{ "Requirements": [...] }`，完整欄位為 RequirementId、Type、ProviderSoftwareId、ProviderItemId、ExternalId、ConsumerItemIds、Certainty、RequiredPhase、ExpectedVersion、Architecture、Context、Owner、SourceProof、Decision、DecisionReason、DecisionEvidence。以 `Get-WsmGeneralHostRequirementId` 計算關聯 ID；SourceProof 的 InventoryHash 必須為当前來源 inventory 的可信 hash，另附 source-specific evidence hash。ProviderSoftwareId／ProviderItemId 只能擇一，ExternalDependency 改用 ExternalId。

重裝、可攜搬入或保留已驗相容目標的軟體，若為入選 consumer 所需，必須有獨立 PreparationReady requirement。只有 StagedDependencyVerified 的設定檔證據不能代替安裝準備。Software provider 的 Context.PreparationEvidence 必填：

| 欄位 | 核對內容 |
|---|---|
| MediaReference／MediaSHA256 | 受控媒體編號及精確 SHA256 |
| VerificationMethod／SignatureEvidence | SignatureVerified 或 OwnerVerified；簽章或人工驗證紀錄編號 |
| VendorOSSupportReference／VendorSupportCheckedUtc | vendor 對目標 OS／版本／架構的支援證據及查證 UTC |
| LicenseReference／InstallOrder | 授權證據編號及正整數安裝順序 |
| IsolationEvidenceSHA256 | 安裝前後隔離／自啟服務／排程／外連差異核對紀錄 hash |
| RestartStatus | CompletedAndVerified 或 NotRequired；未重啟驗證維持阻擋 |
| SideEffectsReference | 副作用、回復、quarantine 與 owner 確認紀錄 |

上述 reference 填受控紀錄編號，禁止填密碼、金鑰或完整連線字串。Context 另保留真正帳號／IIS pool／task context、版本與架構。這些欄位是核對要求，不會執行安裝器。

## Oracle 設定與階段證據

Oracle client 和 Oracle database／listener 分開處理。使用 OracleBindingTemplate 建立版本化 consumer template，owner 核對 provider、版本、架構、Home、帳號與有效來源，再以 OracleConfigDraft 產生精確檔案範圍。TNS_ADMIN 的機器、使用者、服務與 app 候選不同；管理員終端成功不能代表 consumer。

核准 tnsnames.ora／sqlnet.ora／ldap.ora／oraaccess.xml 與 IFILE 的精確 bytes、編碼、hash、ACL／SID、來源／目標路徑及敏感等級。IFILE 循環、缺檔、UNC 或範圍外參照阻擋 consumer；wallet／私鑰／機器綁定材料使用外部受控交付。PATH 外部合併。精確 MachineEnvironment 與時區更新使用受審 SettingTransition；User／service／registry／app 值缺自動 adapter 時走具 readback 的外部程序。

順序為 PreparationReady → RestoreReady → StagedDependencyVerified → CutoverReady → FinalAccepted → RetirementReady。先安裝／隔離／restart，再搬設定，最後在授權環境以真實 consumer 帳號核對網路、TCPS、DB 登入與最小業務交易。tnsping 或 listener 可達不等於 DB／業務成功。

GeneralHostEvidence 收據綁 PairId、來源／目標 fingerprint、inventory hash、工具 fingerprint、context、RequirementIds／RequirementProjectionHash、phase、owner、觀察與到期 UTC、EvidencePathHash；核准後另綁 PlanHash。透過 GeneralHostEvidence 操作匯入，或在 restore／delta／cutover 等入口提供 `{Path,SHA256}`，SHA256 需從獨立可信管道取得。不同目標、過期、設定／provider 漂移不能沿用。

LabReport／Fleet report 只引用確切環境文件 DocumentId／path／hash。報告不是 readiness 證據。來源重新盤點會使舊相依證據失效；不變軟體的 owner 處置保留，受影響關聯重新審核。

## 值班接手、回復與正式放行

接手人先核對 WorkRoot／PairId／PlanHash／ManifestHash／Generation／RunId、journal hash、delivery 全部成員與既有 checkpoint，再使用 Repair／Resume。不能刪 journal 後重試，不能將 installer 建立的物件冒稱工具持有。

切換需外部 fencing、名稱／IP／DNS／SPN／AD／gMSA、有效政策、所有 writers、業務與觀察證據。已可能产生新交易的回退必须保留目標新資料，停止 writers，對帳／產品同步後由 owner 核准；工具不自動啟動來源。退役包含最長週期任務、backup restore、監控接手、外部舊路徑流量與保留期限。

正式放行需 exact ToolRelease bytes、SBOM、support matrix、企業 detached CMS、獨立取得的企業 trust policy hash、精確 OS／installation type／adapter／Oracle provider-consumer 資格及實機測試。缺材料保持 Blocked／NotTested，production 開關維持關閉。實機回傳格式見 RELEASE-QUALIFICATION.md 和 RECOVERY-RUNBOOK.md。
## 切換、回退與退役的外部證據

操作介面「目標 → 驗收證據」必須提供 `ExternalReadinessEvidence` JSON 與獨立取得的 SHA256。輸入負責人、文字說明及 YES 不能解除門檻。JSON 的 `PayloadArtifact` 是本機絕對檔案路徑與 SHA256；工具重新確認原始驗證材料存在且未變更，拒絕 UNC、磁碟相對路徑及 reparse。JSON 上限 1 MiB，材料上限 128 MiB。完整結構與有限檢查欄位見 `src/Cutover.ps1` 的 `Assert-WsmExternalReadinessEvidence`、`Get-WsmExternalReadinessFacts`；fixture 中的 `FixtureMock` 僅供合成測試，不构成實機資格。

每份證據綁定 EvidenceId、PairId、SourceFingerprint、TargetFingerprint、ToolFingerprint、PlanHash、ManifestHash、Phase、Check、ItemId、Context、Owner、ObservedUtc、ExpiresUtc。`TypedResults` 需有 Outcome、TestId、Method、Expected、Observed、Facts；Facts 必須恰好符合該 Check，Outcome 與事實一致。SHA256 證明內容一致，仍須企業獨立責任人、真實測試及信任流程確認材料來源。

產生切換預覽時，逐一加入五項證據：`SourceIdentityReleased`、`SourceWritersFenced`、`TargetIsolationConfirmed`、`ExternalNetworkFencing`、`NetworkOwnerApproval`。`New-WsmCutoverPlan -ExternalEvidenceReferences` 接受 `{Path,SHA256,Check,ItemId}` 陣列。這些引用封存在切換計畫中；執行與重試會重新驗證原計畫引用，材料過期、遺失、變更或綁定不同代都停止。切換前還要完成 BusinessStaged 與所有 GeneralHost CutoverReady 相依；正式切換後另做 BusinessFinal／DNS／Kerberos／外部連線等驗收。

來源最終凍結先準備 `Phase=SourceFreezeReady`、`Check=SourceWritersFenced`、空 ManifestHash 的證據，避免先有最終包才能停寫的循環。另含 FreezeEpoch、逐一 SourceWriterInventory 與 WriterSetHash；每個 writer 必須停止且已審核所有權。操作介面會取得 Epoch，呼叫 `Export-WsmFreezeRecord -FreezeExternalEvidencePath -FreezeExternalEvidenceHash -FreezeEpoch`。封包只攜帶精確綁定的 sanitized attestation；目標不嘗試讀來源本機材料路徑。

來源恢復需 `Phase=SourceResumeReady`、`Check=SourceOwnershipRestored`、空 ManifestHash，並綁定 SourceAttemptId 與 SourceAttemptHash。`Invoke-WsmSourceResume -ResumeExternalEvidencePath -ResumeExternalEvidenceHash` 在預覽與鎖內重驗目標停寫、最新目標資料保留、對帳完成、來源取得唯一寫入權及 owner 接受。原本正在執行的排程另需 SourceTaskReconciliation；不能用一句「確認恢復」取代協調。

目標回退如已產生新交易，RollbackReconcile 必须明確提供停寫、最新目標資料保留、對帳及產品同步結果。退役門檻另外要求外部 consumer 不再走舊路徑、特殊產品處置、資料保留、認證／憑證／CMDB／DNS／授權／監控交接、回退期限與不可逆點／刪除授權責任人，以及備份還原、長週期工作與觀察期。`Get-WsmAcceptanceGates` 逐項列出缺漏，退役只產生門檻結果，不自動刪除來源資料或秘密。
最終來源包匯出亦須提供 `Export-WsmMigrationPackage -FreezeExternalEvidencePath -FreezeExternalEvidenceHash`。這兩個來源本機引用與 `freeze.json` 的 attestation 必須一致；在擷取前重新核對 JSON／材料 hash 及有效期。引用不進入目標端搬運資料，目標只驗封包內 attestation。

Oracle `LOCAL` 非空值可能含認證或連線描述，不接受自動設定 transition（包含 before、after、沿用與外部驗證紀錄）；使用外部不含秘密的 owner 材料。TNS_ADMIN 樹的 wallet／private key 掃描採 bounded recursive walk；巢狀材料未明確排除、權限不足、reparse 或超限時，草稿阻擋，不能把探索失敗當作沒有敏感資料。

完整 Directory 交付必須一併保留獨立 hash 的 `DirectoryDelivery` 摘要 JSON。目標角色首次登記可選 Zip／Directory（Zip 預設 512 MiB），既有 enrollment 直接沿用原選擇。目標角色操作2依其 profile 選擇匯入入口；Directory 使用 `Import-WsmDirectoryDelivery -SummaryPath -ExpectedSummaryHash -SourceDirectory -WorkRoot [-AttemptId]`。`SourceDirectory` 是搬運後在目標端的實際位置，不使用摘要裡舊的來源絕對 `PackageDirectory`。入口核對精確member集合、每個bytes/hash、來源/目標/plan身分與128MiB/100k預算；拒絕多檔、少檔、reparse或模式不符，在目標受控暫存驗完後才封存。不能直接把未驗證的搬運資料夾視為已匯入。

取消控制綁定該 Pair／Plan／Manifest 與 WorkRoot；另一個本機終端使用角色5要求安全邊界停止。報告路徑是 source locator，目標不以其檔案存在或勾選作為 readiness。需要搬運報告時，另行以 DocumentId、格式與hash核對實際到達的檔案。
Windows PowerShell 5.1 的完整 Directory 匯入預先檢查 staging、封存位置及每個成員的完整路徑，最多 259 字元；超限在建立 incoming 前停止。請用短而專用的 WorkRoot（例如 C:\WSM），不要在已有作業失敗後直接換根。啟用長路徑政策本身不代表每個程式均支援，限制依 [Microsoft 文件](https://learn.microsoft.com/windows/win32/fileio/maximum-file-path-limitation)及本工具實際 runtime 判定。

## Windows 系統設定逐項審核

在管理端以獨立 Windows 設定頁面回答是否審核；選 NO 會為整類設定提出 `KeepTarget`，保留每列 exact source／target value hash 與來源控制狀態。選 YES 則需逐列完成 typed decisions。預覽以 allowlist 顯示時區 ID／DST 可用資料、NLS_LANG、TNS_ADMIN、PATH 元件、hosts address／name；hosts 與 PATH 都是人工合併參考，loopback／系統基線標成不可搬。credential pattern、`LOCAL`、連線描述及未知值只顯示 redaction／hash／evidence pointer。source control 為 GPO 或 Unknown 時不開放搬移動作。

精確 source inventory 必須先匯入同一 Pair 的 catalog；source 與 target JSON 都用獨立取得的 SHA256。互動入口建立新 preview 與 typed decision template：

```powershell
$review = Invoke-WsmWindowsSettingsReviewWizard -Workspace D:\Manager -PairId $pairId `
  -SourceInventoryPath D:\Review\source-inventory.json -SourceInventoryHash $sourceInventoryHash `
  -TargetInventoryPath D:\Review\target-inventory.json -TargetInventoryHash $targetInventoryHash
$review | Format-List PreviewPath,PreviewSHA256,DecisionTemplatePath,DecisionTemplateSHA256,ExpectedRevision,ApplyCommand
```

Template 仍需人工填妥；產生 template 不代表套用。只可選預覽列列出的動作。`ReviewedMigration` 只在既有 MigrationSpec、exact SettingTransition／adapter、設定名稱和值及 Local control 全部吻合時出現；套用後仍是 `Migrate`／Pending，既不自動 Include，也不略過一般 plan gates。完成 decisions 後，以最新 decisions file hash、preview file hash 及 wizard 回傳的 revision 套用：

```powershell
$decisionHash = (Get-FileHash D:\Review\windows-settings-decisions.json -Algorithm SHA256).Hash
Apply-WsmWindowsSettingsReview -Workspace D:\Manager -PairId $pairId `
  -SourceInventoryPath D:\Review\source-inventory.json -SourceInventoryHash $sourceInventoryHash `
  -TargetInventoryPath D:\Review\target-inventory.json -TargetInventoryHash $targetInventoryHash `
  -PreviewPath $review.PreviewPath -PreviewHash $review.PreviewSHA256 `
  -DecisionsPath D:\Review\windows-settings-decisions.json -DecisionsHash $decisionHash `
  -ExpectedRevision $review.ExpectedRevision -Ack
```

Apply 會重讀 source、target 與 catalog，要求 hashes／revision 和 preview 完全相符，並以單次 catalog compare-and-swap 記錄 GeneralHost disposition；每個 KeepTarget／External 設定及其 consumer 各自綁定一筆 exact value-hash ExternalDependency，設定之間不合併。KeepTarget 不移除 Mandatory consumer，也不代表相依已滿足；必須另有 consumer decision 及所需 ExternalOwner receipt。輸出不提供 readiness、production qualification 或切換批准。

## Delivery seal、import receipt 與報告

ZIP／Directory 與 full／delta 都使用相同 receipt 契約。來源在完整 transport 與 manifest 已封存後呼叫 `Export-WsmDeliveryDocument`，產生新的獨立輸出目錄、`delivery-receipt.json` 與可讀 `delivery.md`；enrolled full 來源入口另產 DeliveryIndex。Delta 另須傳入可信 base manifest；Delta 的來源文件使用已封存 transport 與可信 base/current/summary/changes；目標匯入收據另外驗證實際 imported tree。完整 Directory 文件使用封存的乾淨副本及其摘要。目標完成相符模式的完整匯入後呼叫 `Export-WsmImportedDeliveryReceipt`，產生 `Status=ImportedVerified` 的 receipt。管理端使用 `Import-WsmDeliveryReceipt -Workspace -Path -ExpectedHash`，會驗證它與當前 pair、approval、plan、generation、transport 及 mode 一致；重複或過期階段拒絕匯入。

`Sealed` 只證明來源封存記錄；`ImportedVerified` 表示目標匯入記錄已驗證。兩者均是 `ReportOnly`，不滿足 readiness、business acceptance 或 production qualification。`Get-WsmDeliveryReceiptSummary` 將當前狀態供 Fleet 報告摘要；Lab report 可用 `-DeliveryReceiptReferences` 附上可信 `{Path,SHA256}`，但明確列為 report-only reference。報告引用本身不會匯入管理 catalog，也不會解除任何 gate。

Enrolled full 來源入口可附帶原有 `{DocumentId,Path,SHA256}` 引用；也支援 JSON 的 `ReportProjectionHash`、`DocumentType` 與 `TargetObservationRevision`。投影雜湊必須吻合實際 JSON Projection，交付 Markdown 與索引保留此資訊；舊三欄引用只標示 locator，文件不是 readiness。

## 受控 WorkRoot 搬移與中斷復原

WorkRoot 搬移只用在同一台已登記主機更換磁碟／根目錄；不要複製來源 state 當目標、不要以搬根建立新 HostId。先在舊根輸出 transfer preview，核對角色、HostId、ProfileId、fingerprint、revision、檔案清單與容量；預覽檔使用新路徑和獨立 SHA256。Apply 前由操作員真正停止所有 WSM 工具 process，僅有檔案鎖／掃描無法證明已載入的工具都已退出。執行時須精確 acknowledgment 與 `-StoppedAllTools`：

```powershell
$preview = New-WsmOutputWorkspaceTransferPreview -SourceWorkRoot C:\WSM -DestinationWorkRoot E:\WSM -Path D:\Review\workroot-transfer.json
$preview | Format-List
Invoke-WsmOutputWorkspaceTransfer -PreviewPath $preview.Path -ExpectedHash $preview.SHA256 `
  -Acknowledgement MIGRATE-WORKROOT -StoppedAllTools
```

舊根成功標為 inactive，禁止後續 enrollment／operation；只在新根 bytes、identity 與 enrollment 全部核對通過後繼續。若搬移中斷，保留兩根與 transfer marker，不要手動刪除或重新初始化；由原根與新根建立 `New-WsmOutputWorkspaceTransferRestorePreview`，核對 `RecoveryMode`、partial staging 與 marker hash，再以該 restore preview 的 exact SHA256、`MIGRATE-WORKROOT` 及 `-StoppedAllTools` 呼叫 `Invoke-WsmOutputWorkspaceTransferRestore`。復原只恢復唯一 active root；不能證明為搬移副本的 partial data 會保留並阻擋人工處理。流程不取代備份、災難復原或跨主機遷移。

Windows 設定原生盤點另保留 WindowsSettingMetadata：白名單機器環境變數的原始 registry 值／型別、存在但空白與不存在，以及時區／DST state。讀取失敗列 coverage gap，不推成不存在。登錄值或 Get-TimeZone 成功不證明 GPO／MDM 不存在，原生 machine environment／timezone 的管理來源因此保持 Unknown，須外部政策確認，不自動開放受審寫入。來源与目標都已確認為 Local 的有限設定，才可由 exact source-after、target-before/type/DST 與既有受審 spec 提供 ReviewedMigration；新建只適用可信目標完整快照證明不存在的白名單變數。

防火牆以 [Microsoft Get-NetFirewallRule](https://learn.microsoft.com/en-us/powershell/module/netsecurity/get-netfirewallrule?view=windowsserver2025-ps) 的 ActiveStore／TracePolicyStore 取得實際來源，保存明確字串 PolicyStoreSourceType；Local、GroupPolicy 與 None／未知分開，GPO、矛盾或未知來源不能被一般 Local 標籤覆蓋。這仍不取代有效政策／原生服務與業務實機驗收。

## 軟體與設定搬移範圍

專業／環境軟體本體只列入每台 Markdown 清單，由使用者安裝；其環境設定檔另以核准 FileScope／typed adapter 協助搬移，無支援者外部搬移／重建並留readback。完整企業情境、支援項目及設定scope陷阱見 [ENTERPRISE-MIGRATION-COVERAGE.md](ENTERPRISE-MIGRATION-COVERAGE.md)。ConfigFiles是分類／核准資訊，不能當封裝白名單；不要選整個安裝根再宣稱只搬設定。
