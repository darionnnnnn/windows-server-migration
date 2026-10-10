# Windows Server Migration 專案入口

- 流程：完整；本輪先討論 [MIGRATION-3-PLAN.md](docs/MIGRATION-3-PLAN.md)，全部 R3 Phase 待實作，不從規劃指示推論已授權開發。現行能力與外部待驗收見 [IMPLEMENTATION-0.1.md](docs/IMPLEMENTATION-0.1.md)；歷史規劃／複審／逐 Phase 證據見 [封存索引](docs/archive/README.md)，按需讀取，不作當期待辦。
- 現況：0.3 第2輪 A0/A1、B1/B2、C、D/D2、E1–E3 程式及契約閉環已實作；兩引擎回歸與 GitHub CI 通過。外部 Server／Oracle／企業 PKI／業務／規模驗收及可核實的不同模型體檢未完成，ProductionVerified=false。
- 使用範圍：一般內部網站／Windows排程及支援服務主機，主要 Server 2016 → 2025；不做資料庫、load balancer等專業服務主機搬移。R3是輔助使用者盡可能還原內容，企業TS可操作／交接、兩機差異及新版軟體下原設定舊路徑可取。全部已發現項目預選／可自訂，選取與核准分離，不支援項出列處置。所有使用者功能／文件以HTML入口＋本機PowerShell呈現，文字備援，共用核心／無遠端或常駐服務，JSON內部資料庫；開發README／PLAN／AGENTS仍為Markdown來源。使用者可選新版，取代強制同版本；來源／選用／觀測版本分開，不承諾自動轉格式／新版相容。全新Windows基準、還原前重查、直接還原／等補裝、逐項deferred／續跑仍適用；純檔案不被全域軟體gate阻擋，真正條件及業務驗證保留。不協助合併既有文件，HTML逐檔列無法放置／scope影響／原檔來源／人工重試，不新增外部覆寫按鈕；受控delta／回復仍遵原契約。非IIS完整盤點／檔案設定保存／人工處置，不新增產品adapter。R3-01–19及S／U等全批次本輪處理、尚未實作。主C／非C跳板機、完整相依及未知版本名稱保留；軟體本體人工安裝、不擴整機備份。
- 操作与契約：[README.md](README.md)、[GENERAL-HOST-WORKFLOW.md](docs/GENERAL-HOST-WORKFLOW.md)、[OPERATIONS.md](docs/OPERATIONS.md)。新規劃待辦集中於R3 PLAN；既有外部驗收待辦仍在 [IMPLEMENTATION-0.1.md](docs/IMPLEMENTATION-0.1.md)；完整軟體確認模板不是實際 Server 清單。
- 四視角複審補強：R3 PLAN已擴為R3-01–19，11個Phase均未實作。核准前按本次有效集合分流，未相關Pending不擋獨立檔案；target receipt始終為sealed plan子集，已核准內可重選，取消已搬項不刪除。局部state／世代／delta完整base／journal replay／CLI返回碼／StageResult共同改，等待或deferred不報成功。封包後選版不改來源facts，受影響target receipt／產品資格重驗；HTML啟動／無隱藏互動／長工作worker／進度與取消、secret不落盤、多頁CAS、C非C同輪typed結果、可攜完整HTML文件索引／容量與計數均須接真實consumer。具體證據及驗收在PLAN；新consumer觀察是待實作契約缺口，不宣稱新流程已修。
- 本次定案：D3-01–08已採用，條件／理由／驗收及仍需取得企業資料集中PLAN。IIS全域／階層／site／pool與task全XML／folder／安全、全部所選相依成套還原，非C同樣搬；來源volume分流而非target盤符，目標非C不排除。D先可信Manager匯入，G消費C／D判完整、E2只投影；11階段順序A→B→S→E1→C→P→D→G→E2→U→F，全部未實作。網站／pool停止與task停用直到另經啟用核准；OS內建列明Keep／OSProvided，原設定與實際目標分存，不整份覆寫新OS全域設定或同名物件。
- 每台 Source／Manager／Target 使用專用固定 WorkRoot。交付選 sealed Directory 或 ZIP，預設512MiB，UI整數128–1024MiB；attempt不重建state。WorkRoot搬移須停工具、預覽、核對、明確確認及受控回復，不是跨機遷移或備份。
- 核准綁定全部src和入口實際bytes；執行中pair不能熱換工具。含核准／封裝／還原的測試使用不可變快照，測試前後核對runtime/test hashes；共享工作區局部PASS不是整輪證據。
- 分層驗證：Pipeline16小檔、取消8檔、報告2501列、Fleet十台各200、Spec200；保留跨5000索引及真實4GiB邊界，不重跑無效的一萬小檔全故障劇本。同程式、依賴、環境及覆蓋範圍的有效證據可沿用。
- 實際來源／目標主機須另有指派；隔離主機可用角色6／CLI LabReport回傳JSON與TXT。fixture、命令成功或報告摘要不能代替原生readback及業務接受。
- 專案現況文件及當期PLAN留在docs；已結束輪次的規劃、一次性複審與驗證歷程以git mv封存至docs/archive並維護索引／引用。公開repository不納入真實盤點、機密、憑證私鑰或根目錄個人prototype `Get-ServerMigrationInventory.ps1`，不讀取或修改該prototype。
- GitHub每段完成後驗證、commit/push并核對遠端SHA。2026-10-10使用者授權本輪收尾整合至dev及刪除codex/implementation；不改main、不force push，保留他人未提交工作。
- 本輪收尾使用主代理直接審查；使用者指定的opus low不在可用subagent清單中，不靜默替換模型。模型身分不明時不宣稱符合不同模型獨立體檢。
