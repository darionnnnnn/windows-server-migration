# 企業 Windows Server：搬移項目與備份／還原涵蓋範圍

更新：2026-10-10。此表是一般服務主機的檢查基準，不是「所有企業情境皆支援」的證明。每台仍須由應用、平台、資安及產品 owner 補查實際依賴；未探索、未載入 profile、權限不足或未知產品不能當成不存在。現行能力均限受控隔離 pilot，正式 Server／產品資格未完成。

本表記錄第 2 輪現行能力。專案已定義為一般內部網站／排程及支援服務主機 EOS 搬移；資料庫、load balancer 與其他專業軟體服務主機不在目標範圍。新的 C 槽限定、其他槽跳板機搬移及完整相依要求見 [第 3 輪草案](MIGRATION-3-PLAN.md)，尚未實作，不能據此解讀下表已支援新契約。

第三輪正常流程已收斂為全新 Windows 主機、其餘軟體由使用者安裝來源同版本，不採相容新版替代。JSON 比較及還原前兩種選擇仍待實作；直接還原的軟體缺口會保留待處理與後續驗證，資料已搬不代表環境／業務可用。下文第 2 輪「目標相容版本」的既有操作能力不作為第三輪版本政策。

## 軟體本體只列清單，環境設定另列搬移

**專業／環境軟體本體只列在每台 `.md` 完整軟體與離線準備清單，由使用者取得媒體、授權並安裝目標相容版本。** 包含 Oracle Client／ODAC／ODP.NET、資料庫引擎、.NET／Java／Python／Node.js／VC++、ODBC／OLE DB driver、IIS 第三方模組、COM 元件、備份／監控／資安／授權代理及個人安裝工具。工具不下載、執行安裝器或複製整個安裝目錄作為重裝替代；Windows roles/features 在 GeneralHost 也由使用者準備。軟體表記版本、架構、scope／SID、安裝位置、consumer、安裝順序、媒體／授權及準備結果，不填秘密。

**軟體的環境設定檔不能因為軟體不搬而漏掉。** 每項另記精確來源與目標、檔案範圍／排除、hash、編碼、權限／SID、consumer、責任人與實際處置。有受驗 FileScope／設定 adapter 的項目，經審核核准後由工具協助搬移；需產品 API、機器綁定金鑰或不支援的項目由外部程序搬移／重建，並留 readback 及業務證據。不能僅寫「軟體已重裝」就將設定或相依標為完成。

業務資料／網站內容／使用者自有腳本依獨立核准 FileScope 處理，不等於搬移它們依賴的 runtime。既有 Portable 處置只是一項 owner 決策，不證明可搬專業軟體本體、登錄或授權，也不代表工具會自動建立檔案 scope。

## 工具確實協助哪些設定與資料

「協助」指已實作的 producer／consumer 與本機契約驗證；不代表這台主機已搬完。要另取得核准、manifest／journal、目標 bytes／ACL／effective 設定 readback 與真實 consumer 結果。

| 項目 | 工具協助 | 明確界限與仍需確認 |
|---|---|---|
| 一般業務檔案／資料夾、網站內容、脚本 | 核准 FileScope 的 full／delta、bytes／hash、時間／attributes、DACL／owner／group與受審 SACL、SID映射、staging／回退 | 不是整碟備份；來源一致性、scope、排除及目標衝突先確認；服務／任務引用的腳本不會因物件盤點而自動入包 |
| `web.config`、`app.config`、`*.exe.config`、`appsettings*.json` | 設定分類草稿、精確 ConfigFiles／ConfigOverrides 審查、檔案包／delta、readback | 第三方格式或非標準路徑由 owner 指定；DPAPI／加密section、連線密碼另有金鑰／秘密程序；不自動改連線或替換全部設定內容 |
| Oracle `tnsnames.ora`／`sqlnet.ora`／`ldap.ora`／`oraaccess.xml`／核准 IFILE | provider／consumer／Home／bitness binding、有效來源確認、設定檔閉包及精確範圍、檔案搬移／readback | Oracle Client只列清單後重裝；IFILE缺檔／循環／範圍外阻擋；wallet／私鑰外部交付；實際帳號DB／TCPS／業務測試必做 |
| 機器環境變數 | GeneralHost受審 CreateNew／KeepTarget／VerifyExternal／UpdateReviewed，保留原值、String／ExpandString、存在／空值及回復 | 寫入白名單目前是 TNS_ADMIN、NLS_LANG、LDAP_ADMIN、LOCAL、ORA_TZFILE；須已确认Local政策。不是所有環境變數或整份PATH自動複製 |
| 時區／DST | 受審 TimeZone transition、exact prior／after及回復 | 不涵蓋locale、code page、NTP policy；排程／時鐘敏感consumer另驗 |
| Windows Service | 明確Desired、身分／相依、受支援SCM supplement、停用staging及readback | 執行檔與設定檔另列scope；登入秘密、gMSA／SPN／權利及產品自註冊外部準備；不搬舊密碼／機器帳號身份 |
| Scheduled Task／task folder security | 受審XML、執行身分、folder ACL／ownership、disabled staging、readback及接續 | 腳本／工作目錄／profile另確認；密碼、正在執行工作、補跑與月／季／年週期另驗 |
| 一般非叢集SMB share | share設定／Access、核准資料scope與NTFS ACL、停寫及回復契約 | DFS／NAS／叢集／複寫、open handles與SMB consumer一致性另有專用程序；share物件不是所有背後資料已入包 |
| IIS pool／site／bindings | 受審有限XML／設定、staging與readback；網站內容／web.config另以FileScope搬 | roles／Hosting Bundle／URL Rewrite等使用者安裝；shared config、金鑰、全機IIS設定、HTTP.sys、Central Certificate Store或特殊模組另確認 |
| 本機使用者／群組 | 受審新建、停用staging、明確成員、SID映射與readback | 不複製原SID、SAM、密碼hash、profile／DPAPI或全部登入權利；domain／gMSA外部程序 |
| 憑證 | owner匯出保護的certificate／PFX artifact，核准後匯入及metadata／private-key presence核對 | 工具不自動匯出來源私鑰；不可匯出／HSM／TPM、私鑰ACL、trust chain／CRL、產品綁定與續期另驗 |
| Firewall | 有完整列舉marker及政策來源的受審規則、filter及readback | GPO／Unknown不能當Local覆寫；IPsec、WFP／第三方安全代理、外部防火牆另處理 |

實作依據：src/MigrationContracts.ps1、src/ConfigArtifactContracts.ps1、src/OracleClientContracts.ps1、src/SettingTransitions.ps1、src/Payload.ps1。

### 必須先核對實際封裝範圍

**ConfigFiles 是設定分類／核准資訊，不是 FileScope 的封裝白名單。** `Get-WsmScopeEntries` 會封裝 SourcePath 下未被 ExcludedRelativePaths 排除的檔案。只列兩個 `.ora`，不會自動排除同根下的 binary／wallet／其他資料。因此設定搬移須使用核准的窄範圍／單檔 scope或完整排除清單，對帳全部artifact，不能選整個 Oracle Home、Program Files、使用者profile或磁碟根後宣稱「只搬設定」。設定散落多處時建立各自scope；新增或修改來源／排除／設定內容須重新盤點、審核核准，不能在封包後手動挑檔或改hash。

OracleConfigDraft是草稿，不會安裝Client、封包、還原或通過consumer gate。原檔若含endpoint／密碼等敏感內容，搬移時仍按受控artifact保護；Markdown只列metadata／SecretRef，不輸出完整設定內容。

## 企業情境：不得從一般檔案還原推定支援

| 情境 | 目前處理／必留項目 |
|---|---|
| OS、boot／BCD、System State、bare-metal／VM整機復原 | 本工具未提供；另用企業備份產品或Windows Server Backup，保留可驗的實還原演練。遷移ZIP不等於整機備份 |
| AD DS／SYSVOL、AD CS、AD FS、DNS、DHCP、NPS、RDS／授權、WSUS、WDS／部署、Print Server | 盤點／告知與專用角色程序；資料庫、key、租約、zone、授權或driver不能當普通設定檔複製；不宣稱本工具自動還原 |
| Failover Cluster／CSV、Hyper-V、Storage Spaces、SAN／iSCSI、MPIO、NIC team／vSwitch、容器 | 平台／產品owner的migration／backup procedure；拓撲、volume／LUN及網路身份另驗 |
| DFS namespace／replication、NAS／UNC／映射磁碟／junction／symlink | 明確專用外部scope與端點／ACL／複寫證據；generic FileScope拒絕reparse，不能保證遠端資料都已備份 |
| DB、Exchange、queue／MSMQ、cache／session、索引與分散式交易 | 軟體只列清單；資料／state用產品一致性backup／restore／flush／drain程序。不能複製開啟的DB檔就宣稱application-consistent |
| EFS／ADS、hard link／sparse／dedup／ReFS特殊語義、長路徑 | EFS與ADS明確阻擋；reparse與超239字元路徑阻擋。其他特殊metadata／檔案系統語義不可因bytes相同推定保留，須專用資格／程序 |
| ODBC system／user／file DSN、OLE DB／COM／COM+、registry32／64view | driver／provider使用者安裝；File DSN及可移植設定檔可另列受審FileScope；registry DSN／COM registration、帳號／view重建與實際consumer外部核對，沒有整份registry還原 |
| HKCU／user profile、AppData／ProgramData、venv、PowerShell profile／module、app-local runtime | 逐帳號補查／人工清單；只搬核准的設定／資料，runtime重建。未載入HKU、不常登入帳號及非標準路徑不得省略 |
| GPO／MDM／local security、登入權利／audit、locale／codepage、PATH／hosts／proxy／WinHTTP、TLS／HTTP.sys | 有受支援adapter者依上表；其餘owner外部合併／重建／readback，不整類覆蓋。有效policy、重新登入／recycle／reboot另驗 |
| 憑證／wallet／DPAPI／Credential Manager／SSH key／機器或帳號綁定秘密 | 金鑰保管owner外部安全匯出／重發／rotation；設定檔複製不證明能解密。來源與目標帳號及私鑰access需真實驗證 |
| domain join／trust、SPN／Kerberos delegation、gMSA、SID／本機群組 | 目標重新建立與精確映射／consumer驗證；不複製machine account或假定同名帳號同SID |
| IP／DNS／名稱、route／VLAN／MTU／IPv6、LB／VIP／NAT、external firewall／VPN／storage endpoint | 網路owner與fencing／切換／回退證據；測試內外consumer及名稱快取，不只ping／HTTP200 |
| antivirus／EDR、backup／monitoring、agents、license／dongle／hardware-binding | 軟體只列清單；設定／exclusion／policy／client identity／授權須產品匯出或外部重建，避免複製agent身份與舊machine key |
| log／event／audit、backup catalog／retention、CMDB／監控告警／續期／最長週期工作 | 依保留／稽核規則另備份或匯出，不能把排除資料視為可刪除；切換後交接与長週期觀察另驗 |
| 初次搬移、delta／final、斷電／缺卷／損毀、reboot、已出現新交易的回退 | 既有hash／journal／resume／fencing契約協助；實際writer集合、外部產品協調、新資料保存／對帳与唯一writer須owner驗證 |
| 勒索／資安事故、異地離線／不可變備份、還原到乾淨隔離環境 | 企業backup／incident-response程序；hash只證明一致，未提供惡意程式偵測、隔離備份、保留策略或無感染資格 |

Microsoft將System State／整機復原與角色遷移分成不同工作，AD forest recovery也有專用程序；這是本矩陣將它們分列的依據。[System State／BMR](https://learn.microsoft.com/en-us/system-center/dpm/back-up-system-state-and-bare-metal)、[AD forest recovery](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/forest-recovery-guide/ad-forest-recovery-procedures)、[角色遷移](https://learn.microsoft.com/en-us/windows-server/get-started/upgrade-migrate-roles-features)。

VSS的requester／writer協作與產品一致性要分別驗證；本工具未新增VSS requester，不宣稱在線application-consistent backup。[Microsoft VSS](https://learn.microsoft.com/en-us/windows-server/storage/file-server/volume-shadow-copy-service)。Oracle的設定位置／IFILE及wallet引用須按實際provider版本核對，不能把某個Home當全機唯一來源。[Oracle sqlnet.ora](https://docs.oracle.com/en/database/oracle/oracle-database/21/netrf/parameters-for-the-sqlnet.ora.html)。

## 每台Markdown必填的兩份清單

1. **軟體／目標準備清單**：全量軟體、版本／架構／SID／Home、consumer、媒體／授權／vendor支援、使用者安裝或外部產品owner、準備結果；不得以「未搬軟體」省略必要軟體。
2. **設定／資料搬移清單**：ArtifactId／ItemId／consumer、SourcePath／TargetPath／scope／全部排除、hash／encoding／ACL／SID、工具FileScope／typed adapter或外部程序、精確處置、PlanHash／ManifestHash／Generation、目標readback／consumer结果及owner。無adapter標External／Blocked，未知標待查，實際不需要須有理由與owner。

狀態分開記：待確認 → 已核准範圍 → 已封存 → 已匯入驗證 → 已還原及readback → consumer通過。ConfigFiles列、軟體清單、DeliveryReceipt或Markdown勾選都不能跳過後續階段。模板見 [ENVIRONMENT-SOFTWARE-CONFIRMATION.md](ENVIRONMENT-SOFTWARE-CONFIRMATION.md)，實際操作見 [GENERAL-HOST-WORKFLOW.md](GENERAL-HOST-WORKFLOW.md)。
