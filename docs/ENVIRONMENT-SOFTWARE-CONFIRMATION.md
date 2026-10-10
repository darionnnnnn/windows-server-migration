# Windows Server 遷移：環境、軟體與相依設定確認表

> **本檔是格式契約與可填寫模板，不是已取得的 Server 盤點結果。** 尚未提供來源／目標主機證據，欄位一律待填，未勾不代表不存在，所有驗證維持 NotTested。
> 工具可依每台本機證據產生完整 Markdown，包含全部發現軟體，不只選搬項。現行文件契約見 [一般主機工作流程](GENERAL-HOST-WORKFLOW.md)；第 2 輪規劃及缺漏背景保留於 [歷史索引](archive/README.md)。第 3 輪新方向尚在規劃，不表示本模板或程式已完成新契約。

## 填寫與核准方式

使用者先確認全部軟體及探索缺口，補登未列環境，再確認哪些需要重裝、哪些檔案／設定需要搬、哪些保留目標或由其他產品程序處理。版本不同不得只寫「新版可以」。必要相依無法驗證時保留阻擋與 owner。

可以在本文件註記；**改文件或勾選不會更新工具的決策／核准**。管理者必須將回填錄入審核選單或經驗證的 CSV／JSON preview，確認 revision／hash 後套用、重新核准並重產文件。過期或錯配對文件不能直接套用。

完整資料存受控離線工作區。勿填密碼、連線字串全文、產品金鑰、wallet／私鑰內容；填 SecretRef 或受控交付編號。內部路徑、帳號及 endpoint 也依企業分享範圍處理。

## 主機、版本與證據

| 欄位 | 值 |
|---|---|
| 文件狀態／實際檔名 | Template；實際檔名 `environment-software-<PairId>-r<InventoryRevision>-d<DecisionRevision>-<DocumentId>.md` |
| DocumentId／TargetObservationRevision／ReportProjectionHash／階段 | 待填；同r／d重查目標仍另存新檔 |
| PairId／波次／群組 | 待填 |
| Source HostId／fingerprint／名稱 | 待填 |
| Source OS／build／edition／Core或Desktop／架構 | 待填 |
| Target fingerprint／bootstrap身分／接手後身分 | 待填 |
| Target OS／build／edition／installation type／架構 | 待填 |
| Tool version／最終發行 fingerprint | 待填 |
| Source／Target PowerShell／edition／process architecture／language mode／CLR／Framework release | 各自主機實際 Runtime；不得用管理端代替 |
| Inventory／requirements／decision revision | 待填 |
| JSON evidence hash／受控位置／產生 UTC／有效期 | 待填 |
| Plan hash（核准前標未產生）／manifest generation | 待填 |
| 操作者／應用 owner／核准人／平台資安 owner | 待填 |
| EOS官方來源／查證日／時區／規劃期限 | 待填 |
| 維護窗／RPO／RTO／觀察／可回退期限 | 待填 |
| 本機WorkRoot／EnrollmentId／PairId／AttemptId／reports位置 | 待填；首次盤點尚無PairId；來源／管理端／目標各自確認 |
| 持續source-state／catalog／operation-state／OperationState.RunId／journal位置 | 待填；不隨attempt重建；備份／恢復owner與核對方式待填 |
| 交付模式／每卷上限MiB與bytes | 待確認；建議分卷ZIP、512 MiB；新旅程建議自訂128–1024 MiB |
| PackageId／Generation／full或delta／BaseManifestHash | 待填 |
| Delivery索引／transport或manifest可信hash | 待填；可信來源須獨立核對 |
| DeliveryId／TransportAttemptId／格式版本／完整成員集合／報告hash | 待填；seal後固定，進度另記receipt；full或delta入口不可混用 |
| 實際ZIP卷數／總bytes／所需與可用空間／媒體保護 | 待填；未驗證不表示可搬運完成 |
| Scratch／delta spool／乾淨資料夾副本／incoming與逐磁碟峰值 | 待填；不可漏算系統TEMP，JSON／entry／memory預算待驗 |

文件必須顯示未完成數、全部列數與來源 JSON 數量。重跑生成新檔，舊檔保留並標失效或仍有效的範圍。

本模板涵蓋各階段，可逐步填寫；準備時未還原的檔案／consumer測試留NotTested及RequiredPhase，不要求先完成後續階段。報告註記不改seal後交付索引，最新位置提示不能取代本份DocumentId／hash。

## 盤點覆蓋與尚未探索範圍

每項填 Success／Partial／PermissionDenied／Failed／NotInstalled／NotRequested／NotTested，以及來源證據、owner 与下一步。NotInstalled 必須有成功的適用探測，不能由空白推定。

| 探索範圍 | Scope／SID／view／根目錄 | 結果與時間 | 缺口／受影響 ItemId | Owner／補查方式／證據 |
|---|---|---|---|---|
| HKLM 64位／32位 Uninstall | 待填 | NotTested | 待填 | 待填 |
| 已載入且可讀 HKU user Uninstall | 待填 | NotTested | 待填 | 待填 |
| 未載入或無權讀取 profiles | 待填 | NotTested | 待填 | 指定帳號補盤點或人工補登 |
| portable／app-local／service／task／IIS 指向檔案 | 核准根目錄與搜尋預算待填 | NotTested | 待填 | 待填 |
| runtime／module／roles／optional features | 待填 | NotTested | 待填 | 待填 |
| ODBC driver／system／user／file DSN／OLE DB／COM | 待填 | NotTested | 待填 | 待填 |
| Oracle Home／Instant Client／ODP.NET／有效 TNS 設定 | 待填 | NotTested | 待填 | 待填 |
| Windows設定／政策／身分／憑證／外部相依 | 待填 | NotTested | 待填 | 待填 |

**使用者補查**：個人安裝、便攜工具、命令列工具、非標準路徑、venv、app-local runtime、授權服務／dongle、未載入使用者 profile、外部 mount／UNC、人工腳本、月／季／年度排程。無證據時明列未知。

## 全部已發現及人工補登的軟體清單

此表為全量，**不以是否選搬過濾**。每個來源列填 SoftwareId、原始 view／scope／位置與 evidence pointer；同名不同版本、SID、架構或 Home 分列。單純媒體去重不能省略原始需求。

| SoftwareId／來源 ItemId／證據 | 軟體／publisher／原始版本 | 架構／scope／SID／安裝位置 | 關聯consumer／相依可信度 | 使用者處置／理由 | Owner／目標结果 |
|---|---|---|---|---|---|
| 待來源盤點填入；此列非實際軟體 | 待填 | Unknown／待填 | 待確認 | 未確認 | 待填／NotTested |

處置限定：使用者重新安裝、核准可攜檔／設定搬移、保留目標已驗相容版本、外部產品流程、明確不需要。Unknown／未確認不能隱藏；必要相依「不需要」仍列阻擋。

## 執行環境、工具與新主機離線準備

以下列為**檢查提示，非聲稱已安裝**；實際產出須以來源 evidence／owner 補登逐項建立 PreparationId。

| 檢查類別 | 必需查明的細節 |
|---|---|
| .NET Framework／.NET／ASP.NET Core | 版本／架構／Hosting Bundle／app-local或self-contained／需求來源 |
| VC++／Java／Python／Node.js／PHP | 版本／架構／venv／模組或lockfile evidence／實際binary與consumer |
| PowerShell／scripts | engine／module版本／工作目錄／execution identity／policy／profile依賴 |
| IIS／HTTP.sys | features／URL Rewrite／ARR／ISAPI／pool bitness／LoadUserProfile／TLS與憑證ACL |
| ODBC／OLE DB／COM | driver／provider版本及架構、system／user／file DSN、registration／identity |
| Oracle clients | Home／Instant Client／ODAC／ODP.NET／JDBC及版本、實際有效TNS／NLS設定 |
| 代理／其他使用者軟體 | 監控／資安／備份／授權／portable，自啟或機器綁定材料的外部程序 |

| PreparationId／SoftwareId／consumer | 必要版本／架構／scope／依據 | 使用者提供媒體／hash／信任證據 | Vendor OS支援／授權／安裝順序 | 隔離／副作用／restart | 目標重查／owner／狀態 |
|---|---|---|---|---|---|
| 待填 | 待確認 | 待填，勿填金鑰 | 待填 | 待填 | NotTested |

準備狀態區分 Missing／Matched／VersionDifferentPendingApproval／Unsupported／Unverifiable／RebootRequired，不以 installer exit 0 或管理員說已完成代替。安裝可能建立同名服務、排程或外連；必須先隔離再核對，不覆蓋成工具 ownership。

| CheckId／consumer／RequiredPhase | Requirements投影hash／revision | 實際受驗target／帳號／工具／時間／有效期 | 結果／受影響變更／fresh關聯 |
|---|---|---|---|
| 待填 | 待填；無關決策不自動清除有效準備 | 待填 | NotTested |

## Oracle TNS_ADMIN 與完整用戶端設定確認

Oracle client 設定為一般應用必要相依；Oracle DB engine／listener 另列特殊產品。每個 consumer／Home／bitness 各一組，不只填一個全機 TNS_ADMIN。

| 欄位 | 來源證據／值摘要 | 目標對應／使用者處置 | Owner／驗證結果 |
|---|---|---|---|
| Consumer ItemId／名稱／業務用途 | 待填 | 待填 | NotTested |
| OCI／ODBC／ODP.NET managed／unmanaged／Core／JDBC | 待填provider與版本／架構 | 目標版本與vendor證據待填 | NotTested |
| Service／task／IIS pool帳號／SID、working directory／profile | 待填 | 帳號／bitness／profile映射待填 | NotTested |
| TNS_ADMIN Machine／User／服務自有環境 | 各scope候選待填 | 舊→新路徑／動作待填 | NotTested |
| 32／64 Oracle registry view／Home | 精確key／value type／摘要待填 | 精確映射／External或受驗adapter待填 | NotTested |
| app設定／JDBC／有效來源／遮蔽值 | provider版本規則與採用依據待填 | 對應設定待填 | 未能證明則Unknown |
| NLS_LANG／LDAP_ADMIN／LOCAL／ORA_TZFILE／PATH | 必要項與順序待填 | 合併／映射／人工證據待填 | NotTested |
| Wallet／私鑰／密碼／機器綁定材料 | 只填外部受控交付編號 | 重建／產品復原／SecretRef待填 | 未提供則Blocked |
| DB／LDAP／TCPS／外部owner／有效期 | 受控摘要待填 | 實際consumer測試方式待填 | NotTested |
| 新程序／recycle／reboot與回復 | 影響consumer及變更基準待填 | 受控步驟／原值／owner待填 | NotTested |
| 既有TNS／設定ownership／精確before與after | 外部／工具持有、空／不存在／型別待填 | CreateNew／KeepTarget／External／受驗UpdateReviewed待填 | 無支援則Blocked／External；不得刪外部原值 |

| ArtifactId／consumer／精確ConfigFiles | 來源→目標／敏感等級 | bytes／encoding／hash／ACL映射 | 相依／IFILE／外部材料 | 處置／readback／owner |
|---|---|---|---|---|
| tnsnames.ora（是否存在待查） | 待填 | 待填 | 待填 | NotTested |
| sqlnet.ora（是否存在待查） | 待填 | 待填 | 待填 | NotTested |
| ldap.ora（是否存在待查） | 待填 | 待填 | 待填 | NotTested |
| oraaccess.xml（是否存在待查） | 待填 | 待填 | 待填 | NotTested |
| IFILE／其他owner核准參照檔 | 待填 | 待填 | 缺檔／循環／超scope需阻擋 | NotTested |

設定解析／檔案核對、listener 可達、DB 登入、實際帳號最小查詢／交易各有結果；`tnsping` 成功不能替代 DB 或業務成功。Oracle 依據：[Net設定查找](https://docs.oracle.com/en/database/oracle/oracle-database/19/netrf/local-naming-parameters-in-tns-ora-file.html)、[ODP.NET](https://docs.oracle.com/en/database/oracle/oracle-data-access-components/19.3/odpnt/InstallConfig.html)、[Testing Connections](https://docs.oracle.com/en/database/oracle/oracle-database/19/netag/testing-connections.html)。

## Windows 系統設定決策與帳號／憑證相依

先記整類是否審核。選否也要列沿用目標及其影響，不能免除 TNS_ADMIN、帳號、憑證等業務必要相依。無受驗 adapter 的項目不顯示自動搬入。

| ItemId／設定 | 來源摘要／目標摘要／Local或GPO或Unknown | 可用動作／使用者決策 | 受影響consumer／理由／owner | restart／readback／回復／結果 |
|---|---|---|---|---|
| 待填時區／語系／code page／clock | 待填 | 未確認 | 待填 | NotTested |
| 待填環境／PATH／hosts／proxy／network | 待填 | 未確認 | 待填 | NotTested |
| 待填firewall／HTTP.sys／TLS／安全政策 | 待填 | 未確認 | 待填 | NotTested |
| 待填帳號／SID／gMSA／權利／憑證鏈私鑰ACL | 待填 | 未確認 | 必要相依不得用整類選否略過 | NotTested |

## 特殊產品、外部相依與未知項

「已讀工具不搬」與「外部流程完成」分開。無法證明不影響入選服務時保留阻擋，不能以排除解除相依。

| ItemId／產品／版本／偵測可信度 | 工具處置／未探索範圍 | 依賴它的consumer／影響 | 外部owner／程序／證據hash／有效期 | 已讀／完成／目標可用結果 |
|---|---|---|---|---|
| 待來源填入 | 待填 | 待填 | 待填 | NotTested |

## 目標差異、未完成事項與下一步

| IssueId／scope／consumer | 缺少／漂移／版本不同／衝突 | 阻擋Gate | Owner／下一步／期限 | fresh evidence／結果 |
|---|---|---|---|---|
| 待填 | 未取得實際來源／目標盤點 | PreparationReady及後續 | 提供本機證據後產真實確認文件 | NotTested |

| Gate | 本機證據摘要／時間／有效期 | 狀態／owner |
|---|---|---|
| ReviewComplete | 待填完整軟體／coverage／決策 | NotTested |
| PreparationReady | 待填本階段runtime／版本／帳號／外部材料／隔離／restart | NotTested |
| RestoreReady | 待填核准包／空間／相容／目標衝突處置 | NotTested |
| StagedVerified／StagedDependencyVerified | 待填精確包／設定／檔案與ACL／有效TNS及consumer相依readback | NotTested |
| CutoverReady | 待填停寫／fencing／final／最終設定下真正consumer的受控測試 | NotTested |
| FinalAccepted | 待填切換後業務／監控／觀察及owner接受 | NotTested |
| RetirementReady | 待填觀察／新交易回退／備份復原／特殊處置 | NotTested |
| ProductionQualified | 待填exact tuple／lab／pilot／企業信任與批准 | NotTested |

## 使用者與管理者確認

- [ ] 已逐列確認全部已發現軟體，包括不搬與個人／可攜環境；未列軟體已補登或記缺口。
- [ ] 每個必要相依已指定準備／設定搬移／外部owner；Oracle client及全部有效TNS檔／參照／帳號／架構已確認。
- [ ] 已確認哪些Windows設定沿用目標、會造成何種影響，沒有用整類選否略過業務相依。
- [ ] 已確認隔離安裝副作用、目標衝突、restart／reboot與真正consumer驗證，未測部分保持NotTested。
- [ ] 已確認維護窗／RPO／RTO、含新交易回退、觀察／最長週期任務、backup restore及退役門檻。
- [ ] 已確認輸出目錄、資料夾或分卷ZIP模式、大小單位／上限、全卷搬運清單及target解包／還原／回退峰值空間。reports可直接讀，state與機密外部材料不混入搬運集合。
- [ ] 目標已用獨立可信transport或manifest核對完整包；單卷ZIP可讀、已複製文件或成功解包不等於業務還原成功。缺卷／錯卷／partial／混世代仍阻擋。
- [ ] 已確認每個CheckId的RequiredPhase／投影hash；後續階段未驗不冒充準備失敗，也不提前放行consumer。外部持有設定不冒充CreatedByTool，更新／回退原值與漂移核對已指定。
- [ ] 已確認stable state與attempt分開、遺失狀態的停止／復原入口、白名單資料夾完整集合、增量分卷與scratch預算、壞卷補傳或新transport重封；報告重產不覆寫舊DocumentId。
- [ ] 管理者已將確認內容回流權威決策、fresh preview／核准，重新產生本文件；本勾選本身不放行。

| 角色 | 姓名／職責 | 決策revision／證據參照 | 確認時間／尚未完成 |
|---|---|---|---|
| 操作者 | 待填 | 待填 | 待填 |
| 應用owner | 待填 | 待填 | 待填 |
| 遷移管理者／核准人 | 待填 | 待填 | 待填 |
| 平台／資安／外部產品owner | 待填 | 待填 | 待填 |

完成確認不等於已搬移，完成核准scope不等於整台接手／可退役，正式資格只適用已驗且有企業批准的精確支援範圍。

## 軟體清單與設定搬移清單必須分開

專業／環境軟體本體只列Markdown，由使用者安裝；其設定仍須逐項登記與搬移／外部重建，不以重裝完成代替設定還原。Oracle設定表亦適用一般環境設定：web.config、app.config、*.exe.config、appsettings*.json與owner指定格式。每列填 ItemId／ArtifactId／consumer、來源→目標／scope／排除、hash／encoding／ACL／SID、工具FileScope／adapter或外部程序、核准／manifest／journal、目標readback及owner結果。ConfigFiles不是封裝白名單，所有非排除scope成員都要核對。wallet／DPAPI／registry DSN／COM及不支援角色留External／Blocked。完整支援矩陣見 [ENTERPRISE-MIGRATION-COVERAGE.md](ENTERPRISE-MIGRATION-COVERAGE.md)，不宣稱涵蓋所有企業備份／災難復原情境。
