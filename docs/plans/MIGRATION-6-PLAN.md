# 第 6 輪規劃：完成備份、管理交接與還原精靈

> 2026-10-13（Asia/Taipei）。狀態：待開始，尚未授權在本次收尾中續作。本文件依使用者明確指示，承接第五輪未完成項目；第五輪只收尾已完成且可獨立驗證的交付範圍。原始需求與歷史證據保留於 [第五輪計畫](MIGRATION-5-PLAN.md)，現行能力以 [實作狀態](../IMPLEMENTATION-0.1.md) 為準。

## 1. 不變的定案

- 主流程面向不熟悉電腦的同仁，一步一件事、一次下一步保存；工具先完成可推導的填寫、選擇、材料辨識及後續銜接。只有意圖、歧義、責任證據及真正授權才要求人工處理。
- 預設逐項詢問是否加入；可明確選擇自動加入所有支援項目。自動模式保留先前排除，不代填未知資料、不代簽核准，遇缺口保存進度。
- 保留已核准的業務 DLL／EXE、網站、排程及資料；排除 Windows、IIS 安裝本體、Oracle Client、runtime、其他安裝軟體、整機映像及 System State。既有 FileScopeGuard 防護不能因精靈整合而放寬。
- 沿用 schema 3、真實目標身分與核准計畫，不另造無目標的 SourceOnly 備份格式。還原、啟用各自明確確認，不能從自動備份或下一步取得授權。
- 開發者探測是左側獨立一鍵入口及同收集器的 CLI 備援；只讀、遮蔽、ZIP／HTML／JSON、不自動上傳，不能改動搬移權威狀態。
- 僅本機隔離資料與可控服務作驗收；現場資訊透過環境探測，不能直接在實際業務環境驗收。企業資格、真人研究與外部 Server／IIS／SMB／PKI 不列本輪代理驗收門檻；ProductionVerified／ProductionExecutionEnabled 保持 false。

## 2. 接手材料與目前落差

「已寫程式」不等於「已交付」。第五輪未提交的大型整合因跨 F0／E／F1／NonC／UI 相依且完整使用端未通過，已從本輪發行工作樹移出，完整保存供本輪重用，不刪除已投入的工作。

- 已提交核心基準：`01ca31978b342fd7e4ee3158725579ddd99ec532`；實際開工以第五輪收尾後分支 HEAD 為基準，先核對後續窄修。
- 本機 Git stash：`185feab72af1cdfcad41e9b6ead77f4e761a1aa6`，名稱 `R6 preserved incomplete wizard integration before R5 closeout 2026-10-13`，包含 48 個待收尾路徑。這是本機保存點，沒有宣稱已推送 GitHub。
- 本機完整快照：`work/r5-verification/r6-handoff-4dfd18e93d1a4ad4a2a52bf506f7f84f`，275 檔；`snapshot-index.json` SHA256：`1845cf72e1d7f47a8e6566574e7b130953c6f6b93b32e5ab9c9fa8a1a0ed71e9`。排除 docs/archive 與私人 prototype。
- 開工先驗 stash／快照存在及雜湊，逐段移植，不直接 `stash pop` 覆蓋第五輪收尾修正。保存材料不可用時依本計畫重建，不假稱已恢复。
- 部分 helper 曾有獨立核心 PASS（尤其 F1 真實小檔還原／取消／續作），仍可重用；修改後依相依 bytes 決定哪些證據有效。未交付 helper 的 PASS 不能成為第五輪發行能力聲明。

| 承接項目 | 實作狀態／缺口 | 原第五輪條款 | 本輪段落 |
|---|---|---|---|
| 原生 HTML／CSS／session 載入可靠性 | 已有診斷與有限正式 handler PASS；完整 NativeBackup 有 CSS connection reset、載入／盤點逾時，原因未確定，不能歸咎安全軟體 | A01–03、F09、R12、R-A12 | P0 |
| 全角色簡單操作、鍵盤與畫面覆蓋 | 基礎版面已交付；完整 Manager／Target 及新表單旅程未完成，不能以 Source 部分路徑代替 | B01–04、F01–05、R01、R-A01 | P1、P5、P6 |
| 最新備份／還原結果導覽 | 新 durable attempt／材料綁定投影有部分實作；最新 running／missing CompletedUtc／取消／過期世代回歸未齊 | C01–05、R06、R-A05–06 | P3、P5 |
| 分組與相依、200 項模式切換 | 基礎選取已交付，增強 grouping helper／循環／未知／跨組完整性未完成整合驗收 | D01–04、R04、R-A04 | P2 |
| 管理端白話準備表單 | 已寫 Preparation helper、Desired 欄位／自動值來源／Submit；全部 adapter 真 Save→Submit 尚待最後雙引擎核驗與瀏覽器接線 | F0、R03、R-A02–03、R-A07 | P1 |
| 自動排除可信安裝軟體子樹與 CER hash | 核心範圍防護已交付；安全預填、使用者覆寫優先、未知安裝位置及公用憑證匯入的整體使用端未完成 | E02、E05、R08、R-A03、R-A08 | P1、P3 |
| 逐項／自動 UI 到真封裝 | Backup helper 有程式；Directory／ZIP 原生兩模式旅程未通過，缺資料／容量／漂移／取消閉環未齊 | E01–05、R02、R05、R08 | P3 |
| 非 C 帳號、計畫、傳輸及匯入 | metadata-only 帳號觀察與 opaque choice 已寫；真正 constructor→worker→import 正向未過，peer UNC 觀察与實際 I/O 的隔離測試尚缺 | E03–04、R-A03、R-A06–09 | P4 |
| Manager 全流程 UI 核准 | 原生測試仍用核心直接建立部分核准，不能算使用者 UI 到真 consumer | F01、F0、R-A07、H02 | P1、P5 |
| Target 匯入、比較、收據、還原與續作 | F1 helper 有雙引擎核心證據；正式 UI 全旅程、取消後新決策、斷線恢復、鍵盤及跨階段組合未完成 | F01–05、F1、C04、R-A05–07 | P5 |
| 可信結果進度 | Progress worker 部分有真實證據；統一 UI／未知總量／關頁重連與清理尚需整合 | R05、R-A05、H03 | P3、P5 |
| 五條旅程、發行與最終完整性 | 未完整實作的部分不得驗收；需涵蓋逐項、自動、Manager、Target 續作、Probe 及失敗組合，最後文件與實際 ZIP bytes 同步 | H01–05、R-A09–12 | P6 |

## 3. 分段實作與代理可驗收條件

### P0：可重現的本機傳輸

先保存初始頁、CSS／JS、session／API 的狀態碼、類型、大小、時序及測試專屬 listener／程序資訊；確認預連線、同步 accept/read/write deadline 與併發資源请求。既有證據：`root-native-http-diag-a8c06e93cf0b49418688ef14bfcedef2` 的 CSS `ERR_CONNECTION_RESET`，同一服務仍存活且後續 HTML GET 200；此觀察不足以判定第三方攔截。

驗收：真 Edge 可讀取正式 handler 並做可逆保存；逾時、非 JSON、session 過期、拒絕及未知寫入不無限等待、不重送。保留安全軟體設定，不任意延長 timeout 掩蓋問題。若原生傳輸仍未通過，清楚列出可控修正及未知部分；測試替代橋接須進正式 handler，不能以 mock API 宣稱原生通過。

### P1：準備與核准的真實使用端

沿用 WizardPreparation／AssistiveReviewForms 草稿。涵蓋 FileScope、Manual、Task、IIS site／pool／section／location、Service、SmbShare、LocalUser／LocalGroup、公用 CER。WindowsFeature 保持人工準備，PFX／私鑰走既有外部流程。檢查 Description 不被 script 子字串誤遮蔽、EncryptData 布林確實保存、IIS 來源欄位只讀、長 staged review 路徑在寫入前拒絕。敏感欄位匹配不能因放行 Description 漏掉 password/token/script/command/private key 的命名形式。

驗收：兩引擎實際 Get→編輯→Save→Submit→讀回 sealed spec；不是只驗 draft。明確覆寫優先於有效同工作設定，再到可信觀測和保守預設；過期、歧義及錯 hash 拒絕且不變更 CAS。責任人、未知帳號、授權不代填。CER 須可信目前檔案與 thumbprint 相符，不能捏造 RawData。瀏覽器完整 Manager 路線不得以核心直接核准取代人的操作。

補充必測：Service 使用 UserPassword 時，SecretRef 必填但不代填秘密；公用 Certificate 的 ArtifactPath 必填。share/user/group/CER 的巢狀 Desired 欄位須由真實 typed consumer 接收。GeneralHost 只對已選相依且採 Reinstall／Portable／KeepCompatible 的項目執行 PreparationReady 門檻，不能以全域 gate 阻擋沒有該相依的 plain Assistive／純檔案。WindowsFeature 人工政策 fixture 應具真實 Preparation 分類；缺分類的測試失敗不當作產品錯誤或 PASS。

### P2：選取與相依

整合 grouping 增強，保留穩定 ItemId、共享 consumer、循環／未知相依及同名不同路徑。來源審閱意圖仍不等於核准。

驗收：200 項混合集合逐項一次下一步保存；中途轉自動／回逐項保留既有排除與確認；重新盤點新項需審閱。零項不假報 100%；共享項只計一次但列完整影響，拒絕不完整必要相依。與 P1 sealed plan 實際保存集合相同。

### P3：備份編排與成果

整合 StartBackup、固定 WorkRoot、輸出預設 ZIP／512MiB、Directory 選項、128–1024MiB 整數限制、可信核准／新鮮來源盤點／容量及實體路徑重疊檢查。進度投影只來自正式 worker；Unknown 總量不製造百分比。

驗收：真 UI 逐項 Directory、自動 ZIP 到核心實際 payload，逐檔 hash/readback。無目標／無核准／核准失效起步就說明。輸出與來源重疊、漂移、失敗、取消、崩潰、重送不破壞已完成材料。running 尚無 CompletedUtc 不拋錯且不出備份結果；確切失敗／取消／中斷可顯示未產生成果，不因此授權 NonC。C 成功且 NonC 未完成必須顯示部分完成。

成果矩陣包含零 C／僅 NonC、僅 C 設定或憑證、C 檔案＋設定／憑證＋NonC 混合、Manual／未知／不支援缺口；依實際材料分列，不能把零 C payload 誤當沒有工作或全部完成。

### P4：非 C 可信材料到實際傳輸

沿用既有核心通道。完成 metadata-only 帳號觀察與必要人工映射、停止寫入及 peer share 證據；唯一有效材料自動選，多份不同材料用名称／主機／時間區分，相同完全綁定材料去重。不要求手填 TransferPlanPath／PlanHash 或刪工作紀錄。

驗收：本機隔離 constructor→真 worker→真 result import→合併備份結果。只允許窄型原生 UNC 觀察／I/O fixture，必須先經同一正式 peer proof 身分驗證，不能 stub 核准／防護／結果。測試錯 host、錯 UNC／path traversal、過期 manifest／generation／freeze、結果竄改、單檔 scope、取消及目的衝突。選單只用目前已核驗 package；執行前重驗全部材料，choice id 不能成為授權本體。實際企業 SMB 吞吐不列門檻。

### P5：交接與目標還原

整合 ZIP／Directory 接收、Manager TargetSnapshot→PublishComparison→ExportTargetComparison、Target 真匯入→決策收據→預覽→明確還原→等待／續作→staged validation／acceptance。既有不可變 restore journal 副本、同材料重複匯入去重及取消結果保留可重用，不建立另一套成功真相。

驗收：三個隔離 workspace 走正式瀏覽器／handler／核心；錯主機、錯 hash、receipt 超 plan、stale comparison／世代／attempt、ItemResults 竄改被拒絕；成功項 bytes／ACL／metadata 真讀回且不覆寫既有檔。取消在真 partial payload 後觸發，明確新決策續作；同 attempt replay 不重做。後續 validation 追加日誌不使已核驗結果無故消失。還原／自動模式不能觸發啟用，單獨確認及核心 gate 均核對。

另驗還原 job 缺 CompletedUtc 時，StrictMode 不拋錯，以耐久 attempt UpdatedUtc 安全排序；保存草稿的直接屬性讀取仍待修。Cancelled／Failed 的非成功結果與「尚未有封裝」分開呈現，不因沒有成功材料而抹去耐久失敗紀錄；它們也不構成可啟用證明。

### P6：全流程檢查、文件及交付

先逐條確認 P0–P5 完整實作再整輪驗收。保留 G 已交付能力，回歸 Probe 與搬移同時操作互不污染。

驗收：五條旅程及成功／部分失敗／取消／斷線／雙頁衝突；三用途完整 Tab／Shift+Tab／Enter／Space。320／768／1280／1920px、200% 縮放、長中文路徑無重疊或頁面溢出；正文 18px、主控制項 48px、群組間距 12px，文字對比 4.5:1、主控制資訊 3:1，主代理實看主要／錯誤截圖。WinPS 5.1／PS7 受影響核心、正式 handler、實際檔案與 fixture 邊界分開記錄。用正式產生器同步 HTML、核對本地連結及實際發行 ZIP bytes／索引／hash，計画／archive／私人原型不入包。不假稱已企業簽章或完美無缺陷。

## 4. 執行順序與收尾規則

P0 → P1 → P2 → P3 → P4 → P5 → P6；可平行唯讀審查，但共享檔單一寫入者。模組 import/export、ActionMap、defaults、projection、UI、測試必須成套；無法独立交付時合併相依提交，不能只推孤立 helper。禁止未使用的新框架、第二套權威状态、遠端服務或過度抽象。

每段主代理獨立驗證後 commit／push 當輪分支並核對遠端 SHA；不自行 force、merge 或推預設分支。大包和原生平台驗證只跑安全小資料，不重跑無效規模測試。實作／驗證模型與 effort 如實記錄；目前只有 gpt-6-luna low／medium／high 可委派，未能證明不同模型的檢查不能稱獨立換模型簽核。

完成判準是上述可執行驗收與當前證據閉合，不包含代理不能代驗的企業現場或真人主觀接受。新發現確實 bug 先重現、修正及回歸；範圍外需求先討論。交付結果逐項標明已完成、未完成或未驗證，禁止用第五輪舊 PASS 蓋過本輪新程式。
