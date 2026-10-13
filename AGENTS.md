# Windows Server Migration 專案入口

- 流程：完整。2026-10-13 使用者改為先收尾第五輪已完成範圍，未完成實作／整合驗收移至 [MIGRATION-6-PLAN.md](docs/plans/MIGRATION-6-PLAN.md)，本次不接續第六輪實作。第五輪原始規格、全部 Phase 盤點及證據見 [MIGRATION-5-PLAN.md](docs/plans/MIGRATION-5-PLAN.md)。第六輪保留工具先處理、白話逐步操作、目標綁定核准、不做整機／OS／安裝軟體備份，保留業務 DLL／EXE。第五輪收尾後整合至 dev，第六輪尚未開始；收尾不代表原 A–H 全數完成。
- 現況：0.4。A–E 現行能力、既有核心 Phase 與外部待驗收以 [IMPLEMENTATION-0.1.md](docs/IMPLEMENTATION-0.1.md) 為準，不在入口重複各次測試時間／checkpoint。原始傳輸 NotPassed、本機動態完整旅程未通過依使用者保留 AdGuard 設定的決策保留；外部 Server／Oracle／企業 PKI／業務／規模驗收仍 NotTested，ProductionVerified=false、ProductionExecutionEnabled=false。
- 使用範圍：一般內部網站／Windows排程及支援服務主機，主要 Server 2016 → 2025；不做資料庫、load balancer等專業服務主機搬移。R3是輔助使用者盡可能還原內容，企業TS可操作／交接、兩機差異及新版軟體下原設定舊路徑可取。全部已發現項目預選／可自訂，選取與核准分離，不支援項出列處置。所有使用者功能／文件以HTML入口＋本機PowerShell呈現，文字備援，共用核心／無遠端或常駐服務，JSON內部資料庫；開發README／PLAN／AGENTS仍為Markdown來源。使用者可選新版，取代強制同版本；來源／選用／觀測版本分開，不承諾自動轉格式／新版相容。全新Windows基準、還原前重查、直接還原／等補裝、逐項deferred／續跑仍適用；純檔案不被全域軟體gate阻擋，真正條件及業務驗證保留。不協助合併既有文件，HTML逐檔列無法放置／scope影響／原檔來源／人工重試，不新增外部覆寫按鈕；受控delta／回復仍遵原契約。非IIS完整盤點／檔案設定保存／人工處置，不新增產品adapter。前輪完整範圍與驗收保留於第三輪 PLAN。主C／非C跳板機、完整相依及未知版本名稱保留；軟體本體人工安裝、不擴整機備份。
- 操作與契約：[README.md](README.md)、[GENERAL-HOST-WORKFLOW.md](docs/GENERAL-HOST-WORKFLOW.md)、[OPERATIONS.md](docs/OPERATIONS.md)。現況規格保留有效行為及限制，執行過程與驗收放既有 PLAN。完整軟體確認模板不是實際 Server 清單；外部驗收與使用者每次操作檢查表不可代勾或刪除。
- 逐項核心契約：核准前按本次有效集合分流，未相關Pending不擋獨立檔案；target receipt始終為sealed plan子集，已核准內可重選，取消已搬項不刪除。局部state／世代／delta完整base／journal replay／CLI返回碼／StageResult共同改，等待或deferred不報成功。封包後選版不改來源facts，受影響target receipt／產品資格重驗；HTML啟動／無隱藏互動／長工作worker／進度與取消、secret不落盤、多頁CAS、C非C同輪typed結果、可攜完整HTML文件索引／容量與計數均須接真實consumer。具體證據及驗收在PLAN；新consumer觀察及修正證據由PLAN對照實際產物，不以摘要代替接線。
- 還原與分通道契約：IIS全域／階層／site／pool與task全XML／folder／安全、全部所選相依成套還原，非C同樣搬；來源volume分流而非target盤符，目標非C不排除。可信材料先由 Manager 匯入，核心合併 C／非 C 結果判定完整性，報告只作投影；前輪階段與驗收保留於第三輪 PLAN。網站／pool停止與task停用直到另經啟用核准；OS內建列明Keep／OSProvided，原設定與實際目標分存，不整份覆寫新OS全域設定或同名物件。
- 跨功能邊界：typed映射須傳IIS／task consumer且原bytes分存，不盲改Arguments／腳本。共享pool／folder／global及C／D目的有未選consumer影響／共同reservation／ownership／精確prior回退，單Pair lock不足。零C內容不等於NoOp；來源停用不預設啟用；BusinessStaged／CutoverReady／核准→Activated→BusinessFinal／FinalAccepted，不循環gate。OSProvided需提供者／完整定義差異證據；清理按跨Pair／世代材料引用及活躍作業鎖定重查，過期／未知保留。两引擎分別驗實際小範圍檔案與隔離契約，IIS／task服務與企業實機仍未驗，既定範圍及production阻擋保留。

- 每台 Source／Manager／Target 使用專用固定 WorkRoot。交付選 sealed Directory 或 ZIP，預設512MiB，UI整數128–1024MiB；attempt不重建state。WorkRoot搬移須停工具、預覽、核對、明確確認及受控回復，不是跨機遷移或備份。
- 核准綁定全部src和入口實際bytes；執行中pair不能熱換工具。含核准／封裝／還原的測試使用不可變快照，測試前後核對runtime/test hashes；共享工作區局部PASS不是整輪證據。
- 分層驗證：Pipeline16小檔、取消8檔、報告2501列、Fleet十台各200、Spec200；保留跨5000索引及64-bit邊界fixture；2026-10-10使用者改採小範圍測試，實體4GiB／企業規模由環境探測與後續實機證據補齊，不重跑無效的一萬小檔全故障劇本。同程式、依賴、環境及覆蓋範圍的有效證據可沿用。
- 實際來源／目標主機須另有指派；隔離主機可用角色6／CLI LabReport回傳JSON與TXT。fixture、命令成功或報告摘要不能代替原生readback及業務接受。
- 現況文件及當期 PLAN 留在 docs；修改 Markdown 後用正式產生器同步 HTML，不手改投影。本輪略過 docs/archive，不搜尋、讀取、搬移、產生或打包封存內容。新包保留既有頂層 Markdown 契約，排除 PLAN HTML／docs/plans；文件變更仍需核驗發行 bytes 並重新簽署。公開 repo 不納入真實盤點、秘密、私鑰；個人未追蹤 `Get-ServerMigrationInventory.ps1` 不讀、不改、不 stage，也不進測試快照或發行包。
- GitHub 每段完整相依驗證後 commit／push 當輪分支並核對遠端 SHA。2026-10-13 使用者明確授權第五輪再檢查無阻擋後整合、推送 dev，確認已整合再刪除本機及遠端 codex/migration-5；不動 main、不 force push，保留 stash 與私人未追蹤檔。此授權不延伸到下一輪或其他 repository。
- 本輪委派僅 gpt-6-luna low／medium／high，由主代理按複雜度選擇；此次審查與窄修用 high。主代理獨立核對實際diff／consumer及測試，不把代理摘要當完成證明。當前主代理確切版本無可信可區分身分，不宣稱與全部實作者不同模型的獨立簽核；第四輪模型／體檢歷史保留於其 PLAN。
