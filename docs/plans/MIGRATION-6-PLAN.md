# 第 6 輪規劃：完成備份、管理交接與還原精靈

> 2026-10-14（Asia/Taipei）。狀態：實作中。2026-10-14 使用者授權完整實作並補齊全部項目，逐段驗證後 commit／push 本輪分支。規劃階段的「不實作」紀錄屬當時狀態；本次依最新授權執行。本文件依使用者明確指示，承接第五輪未完成項目；第五輪只收尾已完成且可獨立驗證的交付範圍。原始需求與歷史證據保留於 [第五輪計畫](MIGRATION-5-PLAN.md)，現行能力以 [實作狀態](../IMPLEMENTATION-0.1.md) 為準。

## 1. 不變的定案

- 主流程面向不熟悉電腦的同仁，一步一件事、一次下一步保存；工具先完成可推導的填寫、選擇、材料辨識及後續銜接。只有意圖、歧義、責任證據及真正授權才要求人工處理。
- 預設逐項詢問是否加入；可明確選擇自動加入所有支援項目。自動模式保留先前排除，不代填未知資料、不代簽核准，遇缺口保存進度。
- 保留已核准的業務 DLL／EXE、網站、排程及資料；排除 Windows、IIS 安裝本體、Oracle Client、runtime、其他安裝軟體、整機映像及 System State。既有 FileScopeGuard 防護不能因精靈整合而放寬。
- 沿用 schema 3、真實目標身分與核准計畫，不另造無目標的 SourceOnly 備份格式。還原、啟用各自明確確認，不能從自動備份或下一步取得授權。
- 開發者探測是左側獨立一鍵入口及同收集器的 CLI 備援；只讀、遮蔽、ZIP／HTML／JSON、不自動上傳，不能改動搬移權威狀態。
- 僅本機隔離資料與可控服務作驗收；現場資訊透過環境探測，不能直接在實際業務環境驗收。企業資格、真人研究與外部 Server／IIS／SMB／PKI 不列本輪代理驗收門檻；ProductionVerified／ProductionExecutionEnabled 保持 false。

## 2. 接手時的材料與落差（實作起點）

「已寫程式」不等於「已交付」。第五輪未提交的大型整合因跨 F0／E／F1／NonC／UI 相依且完整使用端未通過，已從本輪發行工作樹移出，完整保存供本輪重用，不刪除已投入的工作。

- 已提交核心與窄修基準：`b11f0f234f8aa88e825eaec486ac921556dd83e3`。第五輪整合至 `dev` 後，2026-10-14 已 fetch 並核對本機／遠端 dev 為 `1dbbc713f39b85276bd6de25b61fd39e282edd53`，從此建立 `codex/migration-6` 規劃及後續實作分支；實作開始時重查工作區與分支；不得從舊 stash 的父提交直接開工。保留已交付的預覽防護、世代投影、pending 與註冊失敗 replay 修正。
- 本機 Git stash：`185feab72af1cdfcad41e9b6ead77f4e761a1aa6`，名稱 `R6 preserved incomplete wizard integration before R5 closeout 2026-10-13`，包含 48 個待收尾路徑。這是本機保存點，沒有宣稱已推送 GitHub。
- 本機完整快照：`work/r5-verification/r6-handoff-4dfd18e93d1a4ad4a2a52bf506f7f84f`，275 檔；`snapshot-index.json` SHA256：`1845cf72e1d7f47a8e6566574e7b130953c6f6b93b32e5ab9c9fa8a1a0ed71e9`。排除 docs/archive 與私人 prototype。
- 開工先驗 stash／快照存在及雜湊，逐段移植，不直接 `stash pop` 覆蓋第五輪收尾修正。保存材料不可用時依本計畫重建，不假稱已恢復。
- 部分 helper 曾有獨立核心 PASS（尤其 F1 真實小檔還原／取消／續作），仍可重用；修改後依相依 bytes 決定哪些證據有效。未交付 helper 的 PASS 不能成為第五輪發行能力聲明。

| 承接項目 | 實作狀態／缺口 | 原第五輪條款 | 本輪段落 |
|---|---|---|---|
| 原生 HTML／CSS／session 載入可靠性 | 已有診斷與有限正式 handler PASS；本次 NativeHtmlBridge DOM 載入逾時、HtmlBridge spec-review／submission socket reset，先前完整 NativeBackup 亦有 CSS reset／盤點逾時；正式 handler 擷取測試不代表傳輸 PASS，原因未確定 | A01–03、F09、R12、R-A12 | P0 |
| 全角色簡單操作、鍵盤與畫面覆蓋 | 基礎版面已交付；完整 Manager／Target 及新表單旅程未完成，不能以 Source 部分路徑代替 | B01–04、F01–05、R01、R-A01 | P1、P5、P6 |
| 最新備份／還原結果導覽 | 新 durable attempt／材料綁定投影有部分實作；最新 running／missing CompletedUtc／取消／過期世代回歸未齊 | C01–05、R06、R-A05–06 | P3、P5 |
| 分組與相依、200 項模式切換 | 基礎選取已交付，增強 grouping helper／循環／未知／跨組完整性未完成整合驗收 | D01–04、R04、R-A04 | P2 |
| 管理端白話準備表單 | 已寫 Preparation helper、Desired 欄位／自動值來源／Submit；全部 adapter 真 Save→Submit 尚待最後雙引擎核驗與瀏覽器接線 | F0、R03、R-A02–03、R-A07 | P1 |
| 自動排除可信安裝軟體子樹與 CER hash | 核心範圍防護已交付；安全預填、使用者覆寫優先、未知安裝位置及公用憑證匯入的整體使用端未完成 | E02、E05、R08、R-A03、R-A08 | P1、P3 |
| 逐項／自動 UI 到真封裝 | Backup helper 有程式；Directory／ZIP 原生兩模式旅程未通過，缺資料／容量／漂移／取消閉環未齊 | E01–05、R02、R05、R08 | P3 |
| 非 C 帳號、計畫、傳輸及匯入 | metadata-only 帳號觀察與 opaque choice 已寫；真正 constructor→worker→import 正向未過，peer UNC 觀察與實際 I/O 的隔離測試尚缺 | E03–04、R-A03、R-A06–09 | P4 |
| Manager 全流程 UI 核准 | 原生測試仍用核心直接建立部分核准，不能算使用者 UI 到真 consumer | F01、F0、R-A07、H02 | P1、P5 |
| Target 匯入、比較、收據、還原與續作 | F1 helper 有雙引擎核心證據；正式 UI 全旅程、取消後新決策、斷線恢復、鍵盤及跨階段組合未完成 | F01–05、F1、C04、R-A05–07 | P5 |
| 可信結果進度 | Progress worker 部分有真實證據；統一 UI／未知總量／關頁重連與清理尚需整合 | R05、R-A05、H03 | P3、P5 |
| 五條旅程、發行與最終完整性 | 未完整實作的部分不得驗收；需涵蓋逐項、自動、Manager、Target 續作、Probe 及失敗組合，最後文件與實際 ZIP bytes 同步 | H01–05、R-A09–12 | P6 |

## 3. 分段實作與代理可驗收條件

### P0：可重現的本機傳輸

先保存初始頁、CSS／JS、session／API 的狀態碼、類型、大小、時序及測試專屬 listener／程序資訊；確認預連線、同步 accept/read/write deadline 與併發資源請求。既有證據：`root-native-http-diag-a8c06e93cf0b49418688ef14bfcedef2` 的 CSS `ERR_CONNECTION_RESET`，同一服務仍存活且後續 HTML GET 200；此觀察不足以判定第三方攔截。

驗收：真 Edge 可讀取正式 handler 並做可逆保存；逾時、非 JSON、session 過期、拒絕及未知寫入不無限等待、不重送。保留安全軟體設定，不任意延長 timeout 掩蓋問題。若原生傳輸仍未通過，P0 維持 NotPassed，不能進入 P6 的整輪通過判定；清楚列出可控修正及未知部分；測試替代橋接須進正式 handler，不能以 mock API 宣稱原生通過。

### P1：準備與核准的真實使用端

沿用 WizardPreparation／AssistiveReviewForms 草稿。涵蓋 FileScope、Manual、Task、IIS site／pool／section／location、Service、SmbShare、LocalUser／LocalGroup、公用 CER。WindowsFeature 保持人工準備，PFX／私鑰走既有外部流程。檢查 Description 不被 script 子字串誤遮蔽、EncryptData 布林確實保存、IIS 來源欄位只讀、長 staged review 路徑在寫入前拒絕。敏感欄位匹配不能因放行 Description 漏掉 password/token/script/command/private key 的命名形式。

驗收：兩引擎實際 Get→編輯→Save→Submit→讀回 sealed spec；不是只驗 draft。明確覆寫優先於有效同工作設定，再到可信觀測和保守預設；過期、歧義及錯 hash 拒絕且不變更 CAS。責任人、未知帳號、授權不代填。CER 須可信目前檔案與 thumbprint 相符，不能捏造 RawData。瀏覽器完整 Manager 路線不得以核心直接核准取代人的操作。

補充必測：Service 使用 UserPassword 時，SecretRef 必填但不代填秘密；公用 Certificate 的 ArtifactPath 必填。share/user/group/CER 的巢狀 Desired 欄位須由真實 typed consumer 接收。GeneralHost 只對已選相依且採 Reinstall／Portable／KeepCompatible 的項目執行 PreparationReady 門檻，不能以全域 gate 阻擋沒有該相依的 plain Assistive／純檔案。WindowsFeature 人工政策 fixture 應具真實 Preparation 分類；缺分類的測試失敗不當作產品錯誤或 PASS。

### P2：選取與相依

整合 grouping 增強，保留穩定 ItemId、共享 consumer、循環／未知相依及同名不同路徑。來源審閱意圖仍不等於核准。

驗收：200 項混合集合逐項一次下一步保存；中途轉自動／回逐項保留既有排除與確認；重新盤點新項需審閱。零項不假報 100%；共享項只計一次但列完整影響，拒絕不完整必要相依。與 P1 sealed plan 實際保存集合相同。

### P3：備份編排與成果

整合 StartBackup、固定 WorkRoot、輸出預設 ZIP／512MiB、Directory 選項、128–1024MiB 整數限制、可信核准／新鮮來源盤點／容量及實體路徑重疊檢查。進度投影只來自正式 worker；StatusDescription、currentOperation、processedCount、updatedUtc 有真實值才顯示，PercentComplete=-1 轉為 null，不從經過時間推算。Unknown 總量不製造百分比；取消後在安全邊界停止，終態清理 worker／輪詢，關頁重連仍讀同一作業。

驗收：真 UI 逐項 Directory、自動 ZIP 到核心實際 payload，逐檔 hash/readback。無目標／無核准／核准失效起步就說明。輸出與來源重疊、漂移、失敗、取消、崩潰、重送不破壞已完成材料。running 尚無 CompletedUtc 不拋錯且不出備份結果；確切失敗／取消／中斷可顯示未產生成果，不因此授權 NonC。C 成功且 NonC 未完成必須顯示部分完成。

成果矩陣包含零 C／僅 NonC、僅 C 設定或憑證、C 檔案＋設定／憑證＋NonC 混合、Manual／未知／不支援缺口；依實際材料分列，不能把零 C payload 誤當沒有工作或全部完成。

### P4：非 C 可信材料到實際傳輸

沿用既有核心通道。完成 metadata-only 帳號觀察與必要人工映射、停止寫入及 peer share 證據；唯一有效材料自動選，多份不同材料用名稱／主機／時間區分，相同完全綁定材料去重。不要求手填 TransferPlanPath／PlanHash 或刪工作紀錄。

驗收：本機隔離 constructor→真 worker→真 result import→合併備份結果。只允許窄型原生 UNC 觀察／I/O fixture，必須先經同一正式 peer proof 身分驗證，不能 stub 核准／防護／結果。測試錯 host、錯 UNC／path traversal、過期 manifest／generation／freeze、結果竄改、單檔 scope、取消及目的衝突。選單只用目前已核驗 package；執行前重驗全部材料，choice id 不能成為授權本體。實際企業 SMB 吞吐不列門檻。

補充必測：帳號審閱的 Owner／Evidence 收據綁定精確 transfer hash、逐 Principal choices、account-observation hash 及目前 plan／generation，不能以全域一個核取方塊代替逐筆對應。只有本機 fingerprint 與實體路徑 proof 一致，Source 才能使用可信且已審閱的精確本機來源根；Manager 遠端觀察僅依 UNC peer proof，不把本機路徑當遠端證據。隔離正例需讓已核准 ExactFiles 設定檔及必要父目錄真正經過 NonC copy／stage；反例涵蓋錯 host、範圍外本機根、磁碟根別名與未核准的安裝軟體子樹。

匯入結果須核對每個 EntryId 唯一，並精確對應 Transfer Entry／ItemId；malformed、duplicate 或未知引用不得以筆數相同蒙混通過。逐項核對缺失、失敗、取消及重複結果，不僅依已驗 hash 的摘要就宣稱全部 NonC 完成。
### P5：交接與目標還原

整合 ZIP／Directory 接收、Manager TargetSnapshot→PublishComparison→ExportTargetComparison、Target 真匯入→決策收據→預覽→明確還原→等待／續作→staged validation／acceptance。既有不可變 restore journal 副本、同材料重複匯入去重及取消結果保留可重用，不建立另一套成功真相。

驗收：三個隔離 workspace 走正式瀏覽器／handler／核心；錯主機、錯 hash、receipt 超 plan、stale comparison／世代／attempt、ItemResults 竄改被拒絕；成功項 bytes／ACL／metadata 真讀回且不覆寫既有檔。取消在真 partial payload 後觸發，明確新決策續作；同 attempt replay 不重做。後續 validation 追加日誌不使已核驗結果無故消失。還原／自動模式不能觸發啟用，單獨確認及核心 gate 均核對。

另驗還原 job 缺 CompletedUtc 時，StrictMode 不拋錯，以耐久 attempt UpdatedUtc 安全排序；保存草稿的直接屬性讀取仍待修。Cancelled／Failed 的非成功結果與「尚未有封裝」分開呈現，不因沒有成功材料而抹去耐久失敗紀錄；它們也不構成可啟用證明。

### P6：全流程檢查、文件及交付

先逐條確認 P0–P5 完整實作再整輪驗收。保留 G 已交付能力，回歸 Probe 與搬移同時操作互不污染。

驗收：逐項備份、自動備份、Manager 審閱核准、Target 還原續作、獨立 Probe 五條旅程，並交叉涵蓋成功／部分失敗／取消／斷線／雙頁衝突；三用途完整 Tab／Shift+Tab／Enter／Space。320／768／1280／1920px、200% 縮放、長中文路徑無重疊或頁面溢出；正文 18px、主控制項 48px、群組間距 12px，文字對比 4.5:1、主控制資訊 3:1，主代理實看主要／錯誤截圖。WinPS 5.1／PS7 受影響核心、正式 handler、實際檔案與 fixture 邊界分開記錄。用正式產生器同步 HTML、核對本地連結及實際發行 ZIP bytes／索引／hash，`docs/plans`／PLAN HTML／archive／私人原型不入包；保留既有頂層 `docs/MIGRATION-3-PLAN.md` Markdown 交付契約。不假稱已企業簽章或完美無缺陷。

## 4. 執行順序與收尾規則

採第 5 節子階段順序，不再以 P0–P6 編號當線性完成順序。規劃由主代理直接核對；後續實作依本輪授權委派 gpt-6-luna，主代理接手及修正的範圍另記於實作紀錄，共享檔維持單一寫入者。模組 import/export、ActionMap、defaults、projection、UI、測試必須成套；無法獨立交付時合併相依提交，不能只推孤立 helper。禁止未使用的新框架、第二套權威狀態、遠端服務或過度抽象。

每段主代理獨立驗證後 commit／push 當輪分支並核對遠端 SHA；不自行 force、merge 或推預設分支。大包和原生平台驗證只跑安全小資料，不重跑無效規模測試。實作／驗證模型與 effort 如實記錄；目前只有 gpt-6-luna low／medium／high 可委派，未能證明不同模型的檢查不能稱獨立換模型簽核。

完成判準是上述可執行驗收與當前證據閉合，不包含代理不能代驗的企業現場或真人主觀接受。本次發現與後續評估確認的問題均納入本輪：實作授權後先重現、修正及回歸，不自行延期；若修法改變既定產品或授權邊界，先討論並更新本 PLAN。規劃階段原先不實作的限制已由後續實作授權取代。交付結果逐項標明已完成、未完成或未驗證，禁止用第五輪舊 PASS 蓋過本輪新程式。

## 5. 已定案子階段、交付邊界與相依

第 3 節全部契約保留；本節將它們拆成 12 個可驗收單位，不另開輪次或 PLAN。各段均包含必要模組 import/export、ActionMap、defaults、projection、UI、CLI／文字入口相容及正反例測試；未接正式使用端的 helper 不構成可提交交付。規模是相依複雜度，不是工時承諾。

| 子階段 | 規模／範圍 | 輸入與前置 | 輸出／下一使用端 | 完成證據 |
|---|---|---|---|---|
| P0 本機傳輸 | 中；診斷與可定位修正 | 現行正式 listener、隔離工作目錄、Edge | 正式資源／session／API → 全部 UI | 原生資源 bytes、session、一次真保存與錯誤路徑；不得用替代橋接代過 |
| P1a 準備表單 | 大；第 3 節全部 adapter、預填及敏感欄位 | P0；既有可信盤點與隔離材料 | 真 Get→Save→Submit sealed spec → P1b | 每 adapter 的 typed 欄位讀回、CAS、有效期、CER／SecretRef 反例 |
| P2 選取相依 | 中；分組與兩模式 | P0；可信盤點、既有選擇 | 完整選取集合及來源意圖 → P1b | 200 項集合、模式切換、共享／循環／未知／必要相依精確斷言 |
| P1b Manager 核准 | 中；整合選取、準備及目標信任 | P1a＋P2；空白 Target 註冊／盤點及可信交接（見第 9 節） | UI 產生 sealed plan → P3a／P4a | 從匯入來源意圖到核准均走正式 UI；plan 集合與 P2 相符、spec 與 P1a 相符 |
| P3a C 通道封裝 | 中；Directory／ZIP 及預檢 | P1b；核准、來源盤點、固定 WorkRoot；需停寫者先完成預覽及獨立確認 | manifest／payload／freeze 材料 → P3b／P4a／P5a | 逐項 Directory、自動 ZIP 真封裝逐檔 hash；容量／漂移／重疊／核准失效阻擋 |
| P3b 作業與成果 | 中；durable job、取消與重連 | P3a；作業與材料權威記錄 | 可恢復進度及 C 結果 → P4b 合併／P5 | running 無 CompletedUtc、未知總量、失敗／取消／中斷、單次送出與 worker 清理 |
| P4a 非 C 準備 | 中；帳號、peer proof、可信材料選擇 | P1b＋P3a 的 final package／freeze；Target 路徑／StateDirectory／peer proof 先備妥 | 精確帳號收據及 transfer plan → P4b 的既有 worker | 每 Principal 與精確 transfer hash 綁定；唯一／多候選／過期／錯 host／錯根拒絕 |
| P4b 非 C 傳輸與合併 | 大；真 copy／stage／import | P4a＋P3b；受控 I/O 與正式 proof | 逐 Entry 結果、C／非 C 合併 → P5a | constructor→worker→import 正向；真 ExactFiles／父目錄；漏件／重複／竄改／取消／衝突反例 |
| P5a 接收與比較 | 中；ZIP／Directory、TargetSnapshot、比較及 receipt | P3b 的 C 成果或 P4b 的混合成果；目標最新觀測，不以無關 NonC 全域阻擋 | 可信 target package、comparison、plan 子集 receipt → P5b | 三 workspace 真 UI 交接；錯機／hash／世代／過期比較／超出 plan 拒絕；同材料重入受控 |
| P5b 還原與續作 | 大；預覽、明確還原、等待、取消與重播 | P5a；有效 receipt 與本機隔離目標 | 真檔案／ACL／metadata 及 journal → P5c | partial payload 後取消、明確新決策續作、同 attempt 不重做；既有檔不覆寫 |
| P5c 結果與啟用隔離 | 中；結果排序、validation、acceptance 顯示 | P5b；耐久結果與追加日誌 | 有證據的結果及交接指引 → P6 | 缺時間欄位、Failed／Cancelled／deferred 不假成功；追加 validation 不抹去成果；獨立啟用 gate |
| P6 整輪與交付 | 中；整合矩陣、Probe 回歸、文件及包 | 全部子階段完成完整性核對 | 可核驗離線工具與證據清單 | 第 7 節全部矩陣、雙引擎受影響測試、真 ZIP bytes、文件連結與排除契約 |

建議單一寫入順序：P0 → P1a → P2 → P1b → P3a → P3b → P4a → P4b → P5a → P5b → P5c → P6。P1a／P2 在資料契約上可各自驗收，但 P1b 必須等兩者。P3b 可先用受控缺非 C 結果驗「部分完成」，C／非 C 全矩陣直到 P4b 才完成。P4a 的 final package 是已核驗封包材料，不代表非 C 已成功，禁止形成「非 C 成功才能建傳輸計畫」循環。

各子階段均須連到當下可用的正式 consumer，允許後段尚未完成時明列缺口，不允許先掛不可執行按鈕。若移植時證實某子階段無法獨立建置／檢查／回復，先補齊必要相依或與相鄰段合併提交，記錄理由，不推孤立半成品。P6 只做整輪回歸與交付，不把前段漏做延至 P6。

## 6. 原始需求與問題覆蓋表

第五輪原始七項需求、F01–F09、第 1／9 節定案及下列 A–H／R 條款仍是完整性核對來源，不能只用本表摘要替代原文。已交付能力列回歸；未交付與本次发现列本輪完成，不自動移入未來待辦。

| 原條款／需求 | 第六輪歸屬 | 必須保留的可核驗內容 |
|---|---|---|
| A01–03、F09、R12、R-A12 | P0、P6 | 正式 HTTP 資源／API、失敗識別、未知寫入查詢；原生／fixture 分級；本輪採 P0 未過則整輪不得過的較新契約 |
| B01–04、R01、R-A01 | 各段 UI、P6 | 空工作只問用途一次、三角色已註冊重開、尺寸／焦點／對比／長路徑、一般流程不暴露技術必填 |
| C01–05、R05–06、R-A05–06 | P3b、P5a–c | 零／舊／失敗結果入口、durable 恢復、雙頁 CAS、重送阻擋、舊版工作與未知版本處理 |
| D01–04、R04、R-A04 | P2、P1b | 多頁完整集合、穩定 ID、共享一次計數、循環／未知不靜默漏件、200 項模式切換 |
| E01–05、R02、R08、R-A02、R-A08 | P1b、P3a–b、P4a–b | 零目標／無核准起步提示；兩格式／兩模式、容量、漂移、路徑別名、安裝本體排除及所有成果組合 |
| F01–05、F0／F1、R07、R-A07 | P1a–b、P5a–c | Manager 真 UI 核准、三 workspace 交接、receipt 子集、還原／啟用分開、HTML／CLI／報告一致 |
| R03、R-A03、第 9.1 節逐欄規則 | P1a–b、P2、P3a、P4a、P5a | 明確覆寫→有效舊值→可信觀測→保守預設；唯一／歧義／過期／重開；摘要與實際送出一致 |
| 第 9.2 節操作負擔 | 全部 UI 段、P6 | 一次下一步保存；自動模式不逐項重問；每停止點列原因、已保存、誰在哪台機器做什麼及續作入口；無變更不重問 |
| G01–05、R09–11、R-A09–11 | P3b、P6 回歸 | 無工作一鍵 Probe、同 collector CLI 備援、collector manifest／讀回／時間大小限制、遮蔽與包讀取、只讀及並行隔離 |
| H01–05 | P6 | 原文逐項實作核對、五旅程、證據版本、正式文件產生器、發行 bytes 與範圍檢查 |
| 第五輪第 7／11／12 節 | 全部子段 | schema 相容、共享權威狀態、端到端材料鏈、目標綁定搬移備份；禁止新增 SourceOnly 格式 |
| 業務 DLL／EXE、可信安裝根與 ExactFiles | P1a、P3a、P4b、P5b | 保留核准業務檔，排除 OS／安裝本體；非 C 及還原同受 FileScopeGuard 保護 |

第五輪第 2 節「發現 F01–F09」與第 5 節「還原驗收 F01–F05」重複使用編號，核對時以下表區分，不把兩者混為同一清單。

| 第五輪第 2 節發現 | 本輪位置／證據 |
|---|---|
| 發現 F01–02 按鈕／頂列排版 | 各段 UI＋P6：群組間距、長字換行、頂列高度及焦點遮擋實測 |
| 發現 F03 技術操作表單 | P1a–b／P3／P5：正式精靈到核心、不要求一般操作者輸入 typed 參數 |
| 發現 F04 導覽過早出現 | P3b／P5c：無結果／直接網址／舊結果／失效材料入口保護 |
| 發現 F05 技術用語 | 各段 UI＋P6：畫面、錯誤、文件及報告一致；進階值仍可追查 |
| 發現 F06 探測選項與原生限制 | P6／J5：全部適用 collector 都有紀錄，不適用／缺權限不捏造觀測 |
| 發現 F07 盤點不等於備份 | P3a–b／P4b：真 payload 與逐通道結果，不把盤點 ZIP 當備份 |
| 發現 F08 保存／理由／跨頁進度 | P2／P3b／P5：排除理由保守預填、durable 保存與跨頁作業狀態 |
| 發現 F09 傳輸未通過 | P0：根因重現與原生證據；P6 保留未通過阻擋 |

### 6.1 本次核對發現與處置

下列行號以規劃基準或接手快照為準；實作後記錄新證據位置。

| 編號／判定 | 證據與影響 | 本輪處置／驗收 |
|---|---|---|
| Q01 已確認規劃相依問題 | 原 P1 核准先於 P2，P3 完整成果先於 P4；資料集合及成果會被後段改變 | 第 5 節已拆 P1a／b、延後合併驗收；P1b 核對集合，P4b 核對全部成果 |
| Q02 已確認文件契約衝突 | `src/ToolRelease.ps1:209` 收 docs 頂層 Markdown；`tests/Test-Qualification.ps1:64` 要求 MIGRATION-3-PLAN.md；原 P6 泛稱計畫不入包 | 本次已修 P6；P6 實際 ZIP 包含既有頂層 Markdown、排除 plans／PLAN HTML／archive／prototype |
| Q03 已確認覆蓋表不足 | 第五輪第 9–11 節含停止點、技術欄位、CLI 備援、舊狀態及 Probe 資源邊界，原第六輪只有概括引用 | 第 6／7 節逐項落段；P6 查原文子句及真 consumer，不只勾摘要 |
| Q04 已確認草稿危險讀取，尚未本輪動態重現 | 接手快照 `src/WizardFlow.ps1:442` 直接讀 `Job.CompletedUtc`；同檔其他位置有缺欄位防護，StrictMode 下存在風險 | P3b／P5c 對全部時間欄位讀取及排序同型回查；先缺欄位反例，再安全 fallback／穩定排序；不能冒稱現行發行已重現 |
| Q05 已確認既有防護，不是待重做功能 | `src/AssistiveNonC.ps1:661` 的 Import-WsmAssistiveNonCResult 已核對逐 Entry 唯一性、ItemId、完整集合及 bytes/readback | P4b 讓新 consumer 實際走此匯入；回歸漏件、重複、未知、錯引用、被改摘要，不另造驗證真相 |
| Q06 未證實根因的原生傳輸失敗 | `src/HtmlConsole.ps1:603` read deadline、`:671` 同步 accept/read；已記錄 CSS reset／DOM 逾時，但不足以歸因安全軟體 | P0 受控預連線、併發資源與 session 診斷，先重現再修可定位原因；不改 AdGuard、不放寬 timeout 取 PASS |

## 7. 可執行驗收規格與證據邊界

### 7.1 共通測試契約

- 執行端：主代理負責本機測試、真瀏覽器操作、產物讀回及截圖判讀。不存在「等使用者覺得正常」的開發門檻。測試帳號／核准僅限隔離工作；真實搬移的責任證據、歧義決策與啟用授權不得代簽。
- 實作前先查 WinPS 5.1／PS7、Edge、管理員權限、可用磁碟、ACL 讀寫及受控 UNC 路徑能力。前三項工具已確認存在，其餘是待執行環境探測，不能預先宣稱具備。必要本機能力不可用須留下具體阻礙並繼續其他可做項目，不改成使用者代驗或假 PASS。
- 核心與正式 handler 在 WinPS 5.1／PS7 分別驗證。真 Edge 全旅程記錄 PowerShell host；至少兩引擎各跑原生載入／保存，及涉及引擎差異的編排案例。不能把兩引擎 helper PASS 宣稱兩引擎所有瀏覽器旅程皆通過。
- 含核准／封裝／還原使用不可變快照，記錄 runtime／tests hashes、工具版本、命令、exit code、隔離輸入、預期、實際、材料 hash 與替代邊界；測前測後 bytes 相同。已有同 bytes／依賴／環境／覆蓋的證據可沿用，新增或受影響部分補驗。
- 預期拒絕必須斷言原權威 revision、選取、核准、材料及既有檔案未被改動；不是只捕捉任意 exception。正向案例走正式註冊／handler／consumer，不能只直接呼叫 helper。
- 每個已確認缺陷先取得可辨識該缺陷的失敗反例，修後同案例通過並回歸相依端。狀態競態用受控排程驗不變式，不靠大量重跑碰運氣。
- 舊工作 fixture 分別測缺可選欄位、已知旧版本、未知版本、舊世代／不同 PairId；保留原材料，不推定已完成。無法用新精靈處理時給既有進階／文字流程入口。不得靜默把舊核准換成新工具 bytes。

### 7.2 時限、取消與狀態的判準

本輪不預設任意「等夠久就算成功」的時間。P0 在動手修正前，從現行 handler／client／worker／Probe 設定列出各項實際 deadline、poll interval 與取消邊界到本節執行紀錄；沒有界限的等待列為本輪缺陷。測試依該操作 deadline 加一個已記錄的輪詢週期判定錯誤投影；受控 clock／故障注入用於核心時序，真瀏覽器補接線。若需調整時限，記錄原值、理由與受影響案例，不能只延長到測試通過。

取消要求與 Cancelled 終態分開。小檔測試在已讀回第一份 payload 後發送取消，驗證下一安全邊界不再開始新項；邊界內既有原子操作可完成，保留確切已完成集合。等待中的 I/O 須受既有 deadline 約束。到终態後 worker 退出、鎖釋放、頁面 job 輪詢停止；確認取消不刪已完成或被引用材料。關頁重開仍連到原 operationId，程序中斷須呈 Interrupted／待查，不產生新 ID 重送未知寫入。

缺 CompletedUtc 的 running、Failed、Cancelled、Interrupted 分別測試；排序採可解析 CompletedUtc，否則有效 attempt UpdatedUtc，仍缺失／無效時明列時間未知並以穩定識別打破同值，不能捏造成功時間。排序 fallback 不得讓不同世代或錯 PairId 的舊結果變成目前成果。

### 7.3 五條旅程與跨段案例矩陣

以下為最小必測，不表示每個不適用組合都跑笛卡兒積。每列同時記錄 UI／handler／核心／實際檔案／fixture 邊界。其他各段明列的反例仍須完成。

| 旅程 | 正向與真產物 | 失敗／恢復／衝突 |
|---|---|---|
| J1 逐項備份 | 空工作→來源盤點→一次下一步保存→Manager 核准→Directory；200 項選取與小檔封裝分層驗 | 排除及返回保留、重新盤點新項重審、容量／路徑別名／檔案增刪改阻擋、雙頁選取 CAS |
| J2 自動備份 | 初始準備→唯一可信材料自動帶入→ZIP／512MiB 預設→C／非 C 合併；不逐項重問 | 真 partial payload 取消、輸出失敗、worker 中斷、關頁重連、連點不重封裝、未知總量無假百分比 |
| J3 Manager 審閱核准 | 來源意圖→全部 typed 表單→真 Submit→目標身分→UI 核准→可重開交接摘要 | 無核准／過期 spec／錯 CER／歧義帳號不得代填；雙頁提交僅一份有效結果，失效回應不覆寫新上下文 |
| J4 Target 還原續作 | 真 J1／J2 材料各匯入一次→比較→receipt→預覽→明確還原→讀回→續作／結果 | 錯機／hash／世代／超集合拒絕；既有檔冲突、等待補裝、partial 後取消、新決策續作、同 attempt replay、斷線待查、雙頁 receipt CAS |
| J5 獨立 Probe | 無工作與三角色入口→全部適用 collector→真正 ZIP／HTML／JSON→讀取示例 | UI 無法載入時 CLI 同 collector；慢／失敗／大輸出／無空間／取消；敏感哨兵、reparse／UNC 邊界、與備份並行不改權威狀態 |

補充跨段固定案例：

1. C-only、NonC-only（零 C payload）、C 設定／憑證但無檔案、C 檔案＋設定／憑證＋NonC、缺 NonC、混合失敗、Manual／未知／不支援：逐項核對集合／計數／hash／readback，摘要、導覽、報告及 CLI 狀態一致；盤點成功不等於備份成功。
2. 結果檔缺失或 hash 改變時撤下可用成功入口並顯示原因，保留耐久失敗紀錄；後續 validation 追加 journal 不使有效既有成果無故消失。
3. Probe＋備份、重新盤點＋保存、不同工作同時操作及同工作雙頁：用可重現排程驗鎖、revision、job 歸屬、舊 collector 拒絕；秘密不落 localStorage／job／log／報告。
4. 非 C 完整正例經正式 peer proof 與真 worker 寫入隔離小檔，再由 Manager 真 import。僅原生 UNC 觀察／I/O 接縫可替代；核准、scope、材料 hash、result import 不可 stub。企業遠端 SMB／ACL 行為仍 NotTested，實際本機 bytes／ACL 與 fixture 證據分開。
5. 自動備份、下一步、還原完成均不得觸發服務啟用；BusinessStaged／CutoverReady／Activated／BusinessFinal 的既有 gate 不循環、不越權，fixture 驗服務呼叫邊界，真業務服務不啟用。

### 7.4 畫面與文件交付

所有三用途成功／等待／錯誤／結果主頁驗 320／768／1280／1920 CSS px，桌面另驗真正 200% 瀏覽器縮放，不能用 deviceScaleFactor 冒充。長中文路徑、空集合與多頁集合均覆蓋。DOM 量測頁面不水平溢出（必要表格限自身容器）、正文 18px、主控制項至少 48px、間距至少 12px；文字對比至少 4.5:1、主控制資訊至少 3:1。主代理查看主要／錯誤截圖並走 Tab／Shift+Tab／Enter／Space，焦點可見、無陷阱、不被固定區遮住；進度刷新不搶焦點。

每個停止點核對「原因／已保存內容／下一位操作者與主機／可執行動作／續作位置」五欄；一般成功路徑不得要求 ID／revision／JSON／hash，可信值不得重抄。進階工具、文字備援及 API action 不因白話名稱修改而失效。

P6 同步 README／IMPLEMENTATION／OPERATIONS／GENERAL-HOST-WORKFLOW／guide 等受影響文件與正式 HTML；只在能力實際交付後更新現況聲明。本次 PLAN 本來排除 HTML 產生與發行，僅跑正式產生器確認無漂移，不修改現況為已實作。最終發行逐檔比對 ZIP 索引／長度／SHA256／工具指紋／本地引用，保留頂層第三輪 PLAN Markdown，排除 plans、PLAN HTML、archive、私人原型及原始探測資料；沒有企業簽章就明列未簽章，不新增使用者簽章作為本輪結案門檻。

## 8. 整體影響、回復與規劃複核

- 影響面：WizardFlow、保留的 Preparation／Grouping／Backup／NonC／TargetPackage／Restore 草稿、AssistiveReviewForms／NonC、HtmlConsole、OperationRequests、模組清單、UI、相關測試與使用文件。既有 FileScopeGuard、sealed plan、target receipt、journal、StageResult 是共用契約，逐段核對真正 consumer，禁止精靈另造成功狀態。
- 狀態／schema：沿用 migration schema 3；新增精靈可選資料須有舊資料讀取、版本驗證、原子保存及恢復案例。若確需破壞相容或擴大權限，先回本 PLAN 討論；不以預填替代信任、以選取替代核准。
- 身分／資料流：來源 volume 決定 C／非 C 通道；目標磁碟位置不改分類。Source／Manager／Target 固定 WorkRoot；choice id 只是已核驗材料索引，執行前重驗；多材料不得只選最新檔名。C／非 C 共享目的 reservation／ownership／未選 consumer 影響仍適用。
- 失敗／回復：保留來源、原 journal、已完成材料與精確 prior；不整份 rollback 使用者 workspace，不刪仍被跨 Pair／世代引用或活躍作業使用的資料。程式提交可 revert，但執行中 Pair 必須使用原核准工具，不能熱換 UI 或舊 JS。
- 規模／成本：不新增框架、第二狀態引擎、遠端常駐服务、自動安裝或整機備份；只移植有正式 consumer 的草稿。200 項用于選取，不把全部故障乘上大量檔案；沿用小檔及既有 64-bit／跨索引 fixture，外部吞吐不列本輪門檻。
- 逐段開工／結束：查實際 diff 與所有相依、完整性核對→補漏→再核對→正式驗收→commit／push→核對遠端 SHA。全部子段及原始子條款都有實作證據才開始 P6；NotPassed／NotTested 不可改寫成通過。規劃複核本身不構成產品驗收；實作與驗收現況依第 10 節及後續紀錄。
- 明確不做：SourceOnly 備份、OS／安裝軟體／System State、任意覆寫既有檔、真人主觀研究、企業實機搬移／業務啟用、代簽正式責任證據、修改安全軟體政策、merge 至 dev／main。企業既有外部驗收與操作檢查表保留，但不轉嫁成本輪使用者確認門檻。

2026-10-14 主代理規劃複核：已回查第五輪 A–H、第 9–12 節及第六輪全部既有條款；Q01–Q06 均有處置位置，未刪原驗收。P1b 消費 P2 選取、P4b 消費 P3 材料並完成合併、P5 真匯入前段產物，依賴無反向成功 gate。文件封裝衝突已在規劃修正，既有 NonC 防護列回歸。未證實的傳輸根因、草稿動態重現及本機能力探測保留明確狀態，不能當作已修／已測。此為當次複核結論；後續多角度複查另見第 9 節。實作授權仍未提供。

本次文件驗證：原 PLAN 相對連結無缺檔、12 個子階段皆有輸入／輸出／使用端／驗收，diff whitespace 檢查通過。正式 HTML 產生器成功產出 11 份文件及索引，無語意差異；產生器造成的既有 HTML 換行差異不納入提交。未執行產品測試或宣稱產品驗收通過。

## 9. 第二次多角度複查：從使用旅程到全專案（2026-10-14）

本節採尖銳但合理的使用者質疑做情境審查，並非 Reddit 訪談或外部評論研究。核對順序為首次／大量項目／中斷／新版軟體使用者 → 交接與維運管理者 → 正式程式契約 → 全專案材料與狀態生命週期。以下是已確認的規劃不足或既有契約需補的回歸，不能誤稱全部是已重現程式 bug。延續本輪既定範圍補強，不新增服務或獨立備份產品，仍不實作。

### 9.1 使用者逐步走查與補強驗收

| 編號／使用者的合理質疑 | 核對結果與風險 | 本輪必要補強及客觀驗收 |
|---|---|---|
| U01「你說先備份，卻要新主機資料；新主機畫面又要先有備份？」 | P1b 需要目標身分，但 P5a 才明列 TargetSnapshot，空工作材料生產者未完整落段。`MigrationContracts.ps1:281` 核准讀 TargetIdentity；`WizardFlow.ps1:366` 亦要求可信目標材料 | P1b 補空白 Target→註冊身分／固定 StateDirectory→本機盤點→匯出→Manager 驗證／TargetSnapshot→核准→Source 真匯入核准計畫。這段必須能在零備份材料下完成。Target 盤點不得走 Manager ImportInventory 當成來源；P5a 再做還原前新觀測／比較，不用舊盤點永久放行。J3 從三個空 workspace 開始，不預植核准或 target identity 跳過 UI |
| U02「我按備份，為什麼舊網站停了？取消會自己開回來嗎？」 | 草稿 `WizardBackup.ps1:68–95` 對 mutable／NonC 要求 freeze 並呼叫 Export-WsmFreezeRecord；`SourceRecovery.ps1:83,138` 及 `Cutover.ps1:173` 可停用來源 producer。原規劃只概括停寫證據，未明列使用者影響 | P3a 在任何停寫前顯示精確主機、網站／服務／排程、共享影響、保存原狀態位置、缺證據及取消後處置；明確停寫確認與「開始備份」不混用。沿用既有 SourceFreezeReady／Epoch／owner，不假填。P3b 驗停寫前取消無服務變更、停寫途中失敗保留 attempt、封装失敗／取消不自動恢復來源；提供既有 SourceResume／修復途徑及必要單一寫入者證據。用受控服務呼叫 fixture／隔離狀態驗證，不停真業務 |
| U03「非 C 備份已完成，是有一份備份檔，還是已經寫到新機器？」 | 草稿 ChannelSummary 明列 RequiresTargetTransferAndManagerResultImport；`AssistiveNonC.ps1:472` 起核驗目標 StateDirectory 並進真傳輸。非 C 不在主封包，不能以一個『備份成功』掩蓋資料所在位置 | P4a 先導引 Target 準備 StateDirectory、精確目的地及 peer proof，不等待 P5a；傳輸前顯示來源／目標與實際寫入範圍，沿用核心核准及確認，不由自動備份勾選代授權。P4b／P5c 分列 C 封包位置、NonC 目標 staged 資料、結果收據及未啟用狀態；不宣稱有獨立可攜 NonC 離線備份。J2／J4 驗取走 C 包不能假稱含 NonC、已 stage 項後續不重拷／不重新取得 ownership |
| U04「你不讓我填 hash，卻把自己算的 hash 當可信來源？」 | `Approve-WsmMigrationPlan`／TargetSnapshot 都接收獨立 ExpectedHash；第五輪第 9.1 節要求工具推導，但亦明訂外部信任不可代造。第六輪缺少首次材料信任的正反例 | P1b／P4a／P5a 分開『從檔案算出內容 hash』與『已有可信來源的預期 hash／身分』。一般人以既有可信交接材料或一次白話材料核對完成，技術欄位由工具帶入；只有 self-hash、同包自述或檔名不得升為 Trusted。可信來源不足明列待取得材料並保留進度，不要求修改 JSON。驗合法材料一路成功、同時替換檔案與同包 hash 仍不能自我授權、預覽後材料被替換時拒絕且不動權威狀態 |
| U05「我只搬 C 檔，為什麼還要設 SMB？某項等補裝，其他項也不能動？」 | 第 5 節原 P5a 僅列 P4b 前置，容易把開發順序誤寫成使用者全域 gate；既有契約要求獨立檔案不被無關 Pending 阻擋 | P5a 前置依實際有效集合分流：C-only 從 P3b 接收，無需 NonC／SMB 準備；混合以逐項相依判斷，缺 NonC 不阻擋真正獨立的 C 項，有共享必要相依者仍阻擋。J4 同時驗 C-only 正向、混合獨立項可還原、相依項 deferred，整體仍部分完成，不因局部成功顯示全部可啟用 |
| U06「新機器裝新版了，我能改選嗎？是不是改一個選項就全重來？」 | `AssistiveComparison.ps1:280–303` 已有 ChosenVersion、來源 facts 保留及 comparison 失效；第六輪只概括準備／比較，缺具體版本旅程 | P1a／P5a 加來源／選用／目標觀測版本分列、封包後改選新版、還原前重查、受影響 comparison／receipt／產品資格失效與續作案例。來源 sealed facts／payload 不因版本意圖改寫，無關項目保留；同版或版本已觀測不表示相容／授權合格。真軟體安裝仍外部處理，但 UI 版本選取→核心→新比較／有效 receipt 的隔離旅程由代理驗 |
| U07「USB 少一卷／拷到一半，畫面會不會說已收到？空間夠不夠算哪顆磁碟？」 | `GENERAL-HOST-WORKFLOW.md:29` 要求全部成員及各卷 package／副本／scratch／incoming／回復容量；原 P3 只有泛稱容量，P5 缺明確分卷破損案例 | P3a／P5a 驗逐項 ZIP、自動 Directory 的交叉格式核心接線（原完整 J1 Directory／J2 ZIP 仍保留）；多卷資料以安全小 fixture 驗缺卷、重複、跨世代混卷、truncated／hash 錯、匯入中斷及完整重入。正式 UI 的 128／512／1024MiB 與非整數／越界另驗，不靠巨大資料重跑所有故障。容量按實際各磁碟峰值與保留材料估算、不承諾壓縮率；中途 ENOSPC 保留可辨識 partial，不列已接收成功 |
| U08「我按上一頁、關頁、重登，哪些內容真的存了？失效後叫我重做哪一步？」 | 現行計畫要求保存與 CAS，但未將草稿、已提交 spec、已核准 plan 以及失效連鎖逐一配對 | P1a／P2／P5a 顯示已保存與尚未提交差異；未保存修改離開前提醒，若已保存不重问。session 過期先保留非敏感草稿、重新載入可信上下文，寫入結果不明按原 ID 查，不重送。驗改來源盤點／選取／spec／目標觀測／版本後，只清楚標記被核心判定失效的後續材料，仍可查看舊材料但不能執行；錯誤定位對應欄位、保留其他有效填寫與焦點，不以清空整張表處理 |

### 9.2 管理者與程式契約的補強

| 編號 | 必要契約及驗收 | 階段 |
|---|---|---|
| M01 中途交班與可追查性 | 關頁／重啟後僅靠受控工作資料，另一位測試操作者可看到來源／目標、用途、目前材料、實際執行者與責任證據的差別、已做／未做／下一台主機及動作。摘要顯示易懂資訊並提供精確材料識別，不能只剩對原機有效的絕對路徑；交付副本移到另一個隔離接收目錄後由正式匯入驗 hash／身分，工作根目錄本身不偷搬。證據顯示以本機時間供閱讀、保留 UTC／時區，不以各機時鐘『最新』代替世代及材料綁定 | P1b、P4b、P5a／c |
| M02 當機與舊鎖 | 區分瀏覽器斷線、HTTP host 結束、worker 當機、已寫檔但未寫結果。確定性故障點驗 operation／attempt／journal 對應、活躍 owner 不被第二程序接管、同 WorkRoot 第二實例不重做；修復重查實際檔案後才判完成。不能看到逾時就刪鎖或把 job 全改 Failed。僅清理本測試程序與受控檔案 | P0、P3b、P4b、P5b |
| M03 長操作與 session 安全 | 若 P0 為解同步 listener 問題而改排程／連線处理，回歸 loopback host／origin／session／角色／typed allowlist、body 大小／deadline、CAS 與 job 存取隔離。執行備份時另一頁仍能查狀態、取消及啟動只讀 Probe；不以 UI 用途切換取得權限。測兩工作／兩 session，不讓一個工作取消或開啟另一個工作的材料 | P0、P3b、P6 |
| M04 交付不是原始碼樹通過而已 | P6 從實際產生的發行 ZIP 解到含空白／中文的隔離路徑，使用正式啟動器啟動原生頁、載入所需新模組／UI、完成一次無破壞保存及開啟離線說明；核對不依賴 repo 的 work／tests／本機草稿路徑。環境不適用時白話阻擋，不教修改企業政策。沿用已驗核心結果，不為發行煙霧測試重跑全部故障 | P6 |

### 9.3 從全專案重新走一遍的結果

完整資料鏈應為：Source／Target 各自註冊與盤點 → 離線可信材料交 Manager → 選取／準備／目標身分及核准 → Source 匯入核准 → 有需要才預覽與明確停寫 → C 封裝及核驗 → 有需要才 Target 路徑／peer 準備與 NonC 真傳輸 → Manager 匯入逐項結果 → Target 接收／重新觀測／比較／決策 → 還原或按相依等待 → 結果及另行啟用 gate。Probe 是只讀旁路。開發階段先後不等同所有使用者必須經歷每個階段。

- 上游目標準備補入 P1b／P4a，沒有把需要的身分／路徑留到 P5a 才產生；P5a 管的是接收後重新比較與還原決策。C-only／NonC-only／混合三路各驗，不把零 C 誤判 NoOp，不把 absent NonC 當全域門檻。
- 既有服務停寫與 NonC 目標寫入必須在操作名稱、影響預覽、確認、結果與恢復指引全鏈一致。它們不是單純讀取或離線壓縮；自動模式不擴大授權。若實作發現核心必需新的授權契約，先提出討論，不從本節推導無限授權。
- 所有狀態以 catalog／sealed plan／receipt／attempt／journal 的各自權威為準；畫面與交接摘要不另建可改寫成功旗標。計畫改選與 materials 失效、session 換新與 operation id 不變、source freeze 與 source resume 分別核對，避免把可恢復解讀為可重做或可自動開回來源。
- source facts／selected version／target observation 分存；只失效有依賴的證據。不用整輪重新盤點／重新封裝逃避局部狀態契約，也不能保留應失效的 receipt 以省步驟。
- 本節 U01–U08／M01–M04 均為本輪必做完整性條款，落在既有 12 子段，不新增輪次或框架。P6 必須逐項對照本節；U01–U08 的正式使用流程以及 M01–M03 的失敗處理在所屬段完成，不能推到 P6 才補程式。
- 審查結論：上一版尚有材料生產者、停寫影響、NonC 語意、信任入口、分流、版本與發行使用端等規劃缺口，本節已補明。這是靜態程式核對及旅程推演，不是產品已正確運作的證據。原始 HTTP NotPassed、草稿缺欄位動態重現、本機權限／UNC 能力仍待實作階段驗證，未解除既有生產阻擋。

## 10. 第六輪實作紀錄

2026-10-14 開工：沿用 codex/migration-6，規劃完成起點 0a2f74f60a1e0778f95401137ab3b2583d303d94，runtime 基準 1dbbc713f39b85276bd6de25b61fd39e282edd53。私人未追蹤檔保留，不讀／不改／不 stage。主代理套用 delegated-implementation 與 subagent-verification-policy；P0 原生傳輸委派 gpt-6-luna/high，接手材料唯讀盤點 gpt-6-luna/high，主代理核對實際 diff／正式 consumer 與驗收。此為啟動紀錄，不代表任何子段已完成。

### P0 可控修正段：預連線錯誤路徑（整體 P0 仍 NotPassed）

實作者 gpt-6-luna/high；主代理核对 src/HtmlConsole.ps1 接收連線→ReadByte 逾時→catch→finally，確認每連線 route 必須先初始化，無 HTTP route 時以 /unparsed 記錄，避免 StrictMode 結束 listener／沿用上一筆 route。主代理從規劃 HEAD 建立排除 archive 的不可變 p0-verified 隔離副本，僅加入此修正及四份傳輸測試檔；另 p0-before 使用原 handler 同反例確實失敗。Test-HtmlPreconnectRecovery.js 在 WinPS5.1／PS7 均 PASS（2146／2152ms，原 2000ms read timeout，後續 session 200）。這是可獨立回復的窄修，不稱全部 P0 完成。

原生 Edge 完整 HTML／asset/session/save 仍 NotPassed：服務端回應寫完，但 Edge 觀察到 chunked／CSP local.adguard.org 改寫、ERR_CONNECTION_RESET；四資源 burst 亦有 JS body 等待超過既有 15s 的未明原因失敗。未修改安全軟體、未延長產品 timeout、未以 mock 代過。傳輸診斷及實際 deadlines 記在 work/r6-p0/notes.md；P0 未過仍阻擋 P6 整輪通過，其他獨立可控實作繼續，正式原生旅程驗收待補。

### P1a 準備表單：可控實作段已驗證，原生傳輸仍待 P0

完成正式模組／CLI action／HTML action／Manager 角色與配對 gate／defaults／安全結果投影／瀏覽器表單到既有 Submit sealed spec。涵蓋 FileScope、ManualWorkflow、ScheduledTask、IISSite／Pool／Section／Location、Service、SmbShare、LocalUser／Group、Certificate；WindowsFeature 保留明確人工準備拒絕。來源、XML、安全值及 transfer channel 不可由表單偽造；SecretRef 只保存參照，CER 必須為可讀的公鑰材料。草稿只在記憶體，按角色／配對／項目／SpecHash／SourceSnapshotHash 綁定；CAS 衝突先重新 Get，不重送保存、不把舊 hash 掛到新答案。

主代理核對 consumer 與 15 份交付檔，建立排除 archive／私人檔／後續未完成 helper 的不可變 work/r6/p1a-final 副本，逐檔 SHA256 一致（p1a-final-index.json）。WinPS5.1／PS7 各通過 Preparation 29 checks、12 adapters 88 checks、AssistiveReviewForms 44 checks、HtmlConsole 64 checks、WizardFlow 45 checks。真 Edge fixture 通過草稿離開提醒、跨上下文隔離、source／spec 改變、hash-only refresh、SecretRef、欄位定位及保存後重新讀取。主代理發現並修正排程空 Arguments 被誤判必填，Command 仍須非空；修正 WinPS 中文來源 UTF8 BOM 相容。

WinPS5.1／PS7 同一副本的實際 Edge 表單 → 正式 handler 回應擷取橋接 → 既有核心 sealed spec 檔案／SHA256 讀回均通過。橋接只擷取正式 writer 的 bytes，仍將每一請求送正式 controller 一次，保留角色、session、CAS、worker、catalog 和 Submit；並驗舊 review 拒絕及同 operation 重入不重寫。測試 fixture 使用隔離來源盤點與責任證據，不代表真實搬移核准。此為 P1a 可控使用端實作證據，**不是原生 HTTP／origin enforcement／完整三角色旅程 PASS**；P0 NotPassed 與 P1b 核准旅程仍待補，整輪未完成。日誌在 work/r6/p1a-final-*.log。
### P2 分組／選取與 U08 保存防護：可控實作段已驗證

正式模組改用 WizardGrouping 單一 consumer，群組 ID 由 family 與排序後的穩定 ItemId 集合產生；唯一設定併入業務群组，共享項只出現一次並列完整 consumer，缺少與循環相依有明確警示。自動選取先解析完整必要相依閉包；明確排除、缺件與未解循環保留待處理，來源／Manager 均走既有耐久 state／catalog 保存，不建立核准。未知舊 ReviewGroupId 導向第一個未確認群組；新盤點項目需重審。核心的預設選取與已審閱決策分開顯示，不能把 selected=true 當確認完成。

主代理獨立驗證 work/r6/p2-final 的實際模組 consumer：WinPS5.1／PS7 均通過 200 項 Service／ScheduledTask／IISSite 混合集合的真匯入、逐項保存、模式切換、自動閉包、排除理由、重新盤點 201 項與餘項審閱；另 Source 11 checks 驗必要鏈、循環／缺件、盤點 job 來源綁定、排除與舊 intent 無 Confirmed 欄位。受影響 WizardFlow 各 45 checks 通過。真 Edge fixture 驗 200 群組完整保留、共享具名影響、待確認標記、警示及 375px 無橫向溢出；這是 UI consumer fixture，不冒稱原生盤點／封裝或 HTTP 通過。最終交付九份程式／測試 bytes 與驗證副本逐檔一致（work/r6/p2-final-index.json）。

本段核對再發現 P1a 保存 catch 僅憑 stale code 就清除 pending 的風險，已一併修正：只有 submissionRejected=true 可清除待確認作業及重新 Get；未知 409／422 保留原 ID、輸入與焦點，只查同一作業，不重送。主代理獨立跑正式 UI fixture 的正反例及 P1 表單回歸通過，日誌 p2-final-uncertain-ui.log。P1b sealed plan 集合對照與原生 HTTP 旅程仍待所屬段，未把 P2 fixture 當整輪驗收。
### P1b 交接／批次準備與核准：可控實作段完成，原生旅程仍待 P0

Target 可在零備份下匯出已註冊身分及本機盤點；Manager 以獨立預期 manifest SHA-256 核對，顯示 Source／目前 Target／收到的新 Target，明確 commit 後才更新比較與執行既有核准。來源盤點不被 Target 材料覆蓋。預覽保存、相依版本、原始與 staged bytes、主機、工具及選取均綁定；commit 的未知寫入有耐久 intent／收據核對，不重做已證實的 snapshot 更新。同份材料遇到來源選取改變可重新核對，維持原觀測時間而不偽造新盤點。

批次準備由真 GetPreparationReview／SavePreparationReview 消費，先列來源預設、已有規格與缺口，再明確提供共用 Owner／Evidence／BusinessChecks 及預設採用意圖。密碼參照、公鑰、未知或不明確內容仍逐項處理，不自動製造 owner、證據、核准或業務接受。保存前／保存後中斷皆核對版本、來源、提交值及唯一規格檔的實際 hash，證明未寫才續作、已寫則恢復收據，無法證明則保留 Unknown。表單草稿仍只在記憶體；未知提交只查同一作業。

主代理從 P2 基準建立只含本段相依改動的固定副本（唯一目錄及 19 檔索引見 work/r6/p1b-final-fixed-snapshot.txt／p1b-input-index.json）。兩引擎通過 Handoff 22、Bulk 43、HtmlConsole 74、TypedText 18、ManagerApprovalJourney 23、WizardFlow 45、PreparationAdapters 88 checks，以及真封存計畫的 Source／Target 匯入與 action metadata。首次配對繼承 Mode／AutoContinue，重複匯入不重置；封存 Include 集合與來源已確認意圖一致。另補上 CLI 隱藏 OperationId 的實際注入、無 Manager catalog 的 Source／Target revision／操作入口，以及小數容量／字串 false 的入口拒絕；舊 CLI fixture 非 GUID 配對已改成合法 GUID，未放寬產品驗證。

相同 runtime／UI bytes 的 Edge fixture 通過新交接、批次輸入／不自動 commit、375／390px 版面、未知提交 query-only 與既有 P1a／200 群組回歸；兩種 PowerShell 的實際 Edge → 正式 handler writer 回應擷取橋接 → 兩份真 sealed spec 檔案／SHA-256／同 operation replay，以及既有單項保存橋接均通過。橋接保留 controller、session、CAS、worker 與核心保存，但**不代表原生 HTTP、origin enforcement、真三台 Server 或生產資格通過**。P0 NotPassed 未解除；P3–P6 仍在本輪實作，不移到下一輪。
### P3／P5 共用相依：每次交付格式凍結，已獨立驗證

核心 OutputWorkspace／OutputWorkflow 支援明確的 per-attempt Directory／ZIP 與容量，既有 attempt 沿用凍結值、明確要求改格式／容量則拒絕，且不修改已登錄 OutputProfile。DirectoryDelivery 先核對摘要、完整成員、封包與 Target 身分，再以 Directory／0 bytes 建立該次 attempt；Target 的 ZIP 偏好不再誤擋資料夾接收。來源 EnrolledDelivery 轉交同一組已驗證的 attempt 值。

主代理以 P1b 固定基準只覆蓋本段兩個核心檔及 OutputWorkspace 測試，獨立執行 Windows PowerShell 5.1／PowerShell 7 的 OutputWorkspace 與 OutputWorkflow；全部通過。固定副本及三檔 SHA-256 見 work/r6/output-prerequisite-snapshot.txt／stage-input-index.json；OutputWorkflow 的 transport native boundary 使用既有 fixture，不能代稱原生跨機傳輸。另在 P3 固定副本已完成兩格式真封裝、匯入與 payload hash 讀回的 PS7 子案例，但全套 P3／P5 仍有 consumer／取消／交接驗證在本輪修正中；此提交不表示完整 P3、P5 或整輪通過。原生 P0 NotPassed 不變。
### 本輪整合發現修正：可選軟體涵蓋 ItemId（2026-10-15）

- 原生機器層級 SoftwareCatalog Coverage 合法省略 ItemId；StrictMode 下原直接讀取會阻止 Target 比較與 NonC 復原接縫。
- 指紋計算將缺省 ItemId 正規化為空字串，保留明確項目及狀態差異的指紋綁定，不修改 sealed source facts。
- 驗證：不可變來源副本 `work/r6/software-facts-snapshot.txt` 所指目錄，`tests/Test-SoftwareFactsCoverage.ps1` 在 PowerShell 5.1 / 7 皆通過。此結果僅涵蓋該指紋契約，不代表 P5 或整輪驗收通過。
### 本輪整合發現修正：NonC 目的地的原生實體路徑比較（2026-10-15）

- `Get-WsmAssistiveNonCTargetNativePath` 原先對 peer proof 的 NT 實體路徑再做 `GetFullPath`，並與磁碟代號目的地比較，會拒絕正確的本機目的檔案。改為兩側皆用已觀測的實體路徑比較，保留 exact peer 身分、sealed destination、相對路徑及防穿越檢查；不把 NT 路徑當 I/O 路徑。
- 主代理在固定來源副本 `work/r6/native-path-snapshot.txt` 所指目錄，獨立跑 `Test-NonCTargetNativePath.ps1`：PowerShell 5.1 / 7 皆通過。使用實際 temp 目錄的原生 NT volume 觀測；peer metadata 為 fixture，不代表實際 SMB 認證／傳輸通過。
- 此為既有核心的可獨立修正，不標記 P4／P5 或整輪完成。另已發現 Target 交接 helper 把 sealed physical StateDirectory 再當 logical I/O 路徑的問題，正在本輪接回固定 Target WorkRoot\pairs 並驗證，不延至後輪。
### P3 Directory 路徑修正（2026-10-15）

正式 Source 旅程發現：最終 payload 路徑仍可用時，舊 `.partial-<GUID>` 暫存路徑可能超過 Windows PowerShell 路徑限制。改用同父目錄 `.d-<完整 GUID>`，保留排他建立與精確清理；交付前依實際 whitelist 檢查最終／暫存／摘要路徑，超限時要求較短固定 WorkRoot，尚未建立交付目錄。新精靈亦於凍結前預算本次封裝實際類型需要的路徑。

獨立核心驗證：`work/r6/directory-path-snapshot.txt` 指向唯讀輸入快照，`Test-OutputWorkspace.ps1` 於 Windows PowerShell 5.1／PowerShell 7 都通過，涵蓋原暫存路徑超限而新路徑可用的真複製／逐 member hash、過長路徑寫入前拒絕、取消與失敗清理。此提交僅包含核心路徑修正及回歸；精靈 hook 隨完整相依段落驗證提交。P0 原生傳輸及 P3 整段驗收仍未因此變為 PASS。

### 本輪補強定案：多共享與讀取副作用（2026-10-15）

使用者明確同意本輪補齊 NonC 多共享：Source 各資料根目錄、Target 各資料根目錄與固定 WorkRoot\pairs 可分別使用明確審閱的不同既有共享。沿用 peer proof／實體範圍／獨立 manifest hash，不建立共享或放寬根目錄防護。Source／Target 攜出完整共享集合，Manager 正式核對並註冊全部證據；來源帳號觀察與傳輸計畫精確綁定所選完整 proof 集合，逐項唯一映射，遺漏／重疊／錯 peer／過期集合拒絕。UI 使用具名共享欄位及已登記證據選項，CLI 使用相同型別結構；單共享原呼叫保持相容。此項納入 P4a／P4b 與 P5a，不移往後輪。

完整還原整合另外重現：後續 Final validation 追加 mutable journal 會使既有 Staged 機械驗證投影消失，且 Runtime GET 在 Passed 分支間接呼叫會寫入的 acceptance 核心。修法改用明確 validation／acceptance 操作產生的精確 attempt／receipt／generation 綁定與受控 immutable journal／gate artifact；GET 只讀回已保存證據，不執行 gate writer。未通過機械驗證時可閱讀已存在的 ReviewRequired gate 結果，仍不開放啟用。完成受影響雙引擎驗證前不標 P5c 通過。

多共享整合驗證：主代理在不可變 `work/r6/multishare-cas-fixed-snapshot.txt` 副本執行 WinPS5.1／PS7，HtmlConsole 83、HtmlRuntimeProjection 165、ProofHandoff 25 checks 及完整 NonCTargetHandoff 均通過；測後全部 110 輸入檔 hash 不變。額外共享的未知／缺少欄位拒絕，安全投影保留完整共享與資料／狀態映射但去除秘密。修正 producer 把狀態目錄誤算為資料根目錄的契約衝突，仍精確校驗資料根集合及獨立狀態 peer proof；修正 WinPS5.1 第二次 Target receipt 選取以 null 備份路徑呼叫 File.Replace 失敗，改用共用原子 writer。測試修正重複攔截器造成遞迴，以及把 active pointer hash 誤當 receipt hash 的錯誤斷言，不放寬產品 CAS。

主代理獨立執行 `wsm-multishare-state-99c5d1cf3c50437da13803612dfd1514/repo` 的真 observation→constructor→Source import→worker→Manager result import，兩引擎均通過；測後 274 檔 hash 全部不變。正例涵蓋兩個來源共享、兩個 Target 資料共享及第三個狀態共享，漏掉狀態 proof 拒絕；僅原生 UNC I/O／環境觀測以 exact owned-tempdir 接縫替代，不宣稱企業 SMB 驗證通過。實作代理為 gpt-6-luna/high，主代理直接檢查與重跑驗證。

NonC 操作表單已補上多共享逐列輸入、Manager 完整共享／映射／材料指紋預覽與多個來源 proof 選取。主代理 Node 17 案通過；不可變 `work/r6/nonc-layout-final-snapshot.txt` 的真 Edge 通過三角色四種寬度、18px／48px／12px、鍵盤、焦點保留、文字 4.5:1 與控制邊界 3:1，108 檔測後 hash 不變。此為 UI／API fixture 證據，尚非真正 200% browser zoom 或 P0 原生 HTTP 通過。

Target GET 整合發現：自動重跑 native software catalog 實測單次約 17 秒，重複進入 preview／availability 還可能寫入 journal snapshot；已改為 GET 只讀精確 job／材料，明確 preview／restore writer 保留重驗，正在雙引擎驗證。另重現 PowerShell 自動 `$Matches` 被正規表示式覆寫 List 而隱藏結果，已將新結果 accumulator 改為專用變數；完整 Target／接受條件回歸完成前不標完成。以上均留本輪處理。

### P4 共用核心獨立提交：來源 UNC 與精確結果綁定

主代理從已提交 HEAD 只封存既有 src、兩個啟動器與既有核心測試，再覆蓋本段 AssistiveNonC 及新增路徑測試，建立 `work/r6/nonc-core-independent-snapshot.txt` 不可變副本；兩引擎各通過 AssistiveNonC 34 checks 與 NonCSourceImportPath 8 checks，測後全部輸入 hash 不變。此段包含本機來源 host 檢查、密封 logical path／native collection proof／peer UNC 的 import-only 精確映射、Target share alias 與結果 account map／SACL requirement 核對；原生觀測接縫預設仍呼叫真系統 API，不放寬 SMB／物理範圍驗證。來源路徑比對使用純字串 Path.Combine，不要求 Manager 存在來源 D／E 磁碟。此核心可由既有已提交模組獨立載入及回復，與仍在本輪驗證的新精靈 family 分開提交；P4 整段及整輪不因此標通過。

正式 Target 首次匯入亦重現必填 Role 綁定順序錯誤：已於參數驗證前綁定 Source／Target session，拒絕不同 caller role。獨立 `Test-HtmlConsole.ps1` 雙引擎 80 checks 通過，快照測前後 hash 一致；正式瀏覽器完整旅程續驗。

### P3–P5 整合完整性再核對與本輪修正（2026-10-15）

本段由主代理接手全部檔案寫入。先前 gpt-6-luna high 委派範圍包含 CLI、備份、NonC、runtime/UI；額度不足後未改用其他代理模型。主代理亦親自實作，因此既有代理檢查及下列主代理驗證均不宣稱不同於全部實作者的換模型簽核。

- 作業接線：模組公開函式、typed action/defaults、伺服端 session／role／CAS／operation id、耐久 worker、投影及 UI/CLI 同步核對。遷移與只讀 Probe 使用不同 OS 排他鎖；重啟只能在取得自己通道鎖後把未完成作業標 Interrupted，不接管活躍 owner。
- Source：固定工作根、每 attempt 格式／容量、獨立停寫授權及 prior state、取消不自動恢復來源、Directory 路徑預檢、真核心封裝及耐久成果均接入正式入口。NonC 不被描述為主包內的離線備份。
- Target：第一次匯入前先綁 session 角色；GET 只讀目前已驗材料，不重新掃描軟體或追加 journal。明確預覽／還原才重查本機觀測。安全投影與核心預覽使用同一 canonical hash；核心耐久 ItemResults、不可變 journal 副本及精確 attempt／receipt／世代仍獨立核對。
- 結果生命週期：修正 activation 被 FinalAccepted 循環封鎖、啟用後還原歷史消失、Final 投影誤讀 Staged 路徑，以及全 deferred 預覽錯顯可還原。啟用入口只開獨立審閱，寫入端仍執行完整 cutover gate。Final 與 Staged 的工作、檔案及 phase 必須一致。
- 多共享：Source 逐共享證明與 ACL 觀察精確成套；Target 資料共享與固定 WorkRoot\pairs 狀態共享可分開。物理 identities 只涵蓋資料根，狀態目錄另外綁定。Target producer 將固定狀態 UNC 寫入已雜湊 physical proof，Manager 匯入及 transfer constructor 均拒絕另填位置；舊未綁定證明要求重新匯出。反例不變更已核准計畫。
- CLI：TargetAcceptance 雖以 Get 命名，實際會產生驗證與 journal，已改為明確 APPLY 後才能執行。DeveloperProbe 使用同樣耐久作業機制、獨立取消及重連，不再讓 CLI 只剩同步直呼。

已獨立確認的固定副本：`final-main-owned` 兩引擎 HtmlConsole 84、HtmlRuntimeProjection 175、NonCTargetHandoff 及 TextRuntime 65 通過；`final-lifecycle` 兩引擎 Target runtime 133 通過；Source runtime 兩引擎 133 及格式／停寫／取消測試通過。上述副本分別 116／109／109 個 runtime/test 輸入在測後 SHA256 不變。最後新增 Final phase 與狀態目錄綁定修正另以新固定副本驗證，不用舊 PASS 代替。

`final-affected-regression` 兩引擎的 Flow 45、ReceivedPlan 真核心匯入、VersionSeparation 28、Progress、NonCPreparation 7、SourceImportPath 8 通過，113 輸入測後未變。UI 矩陣包含真 Edge 200% tabs zoom、四種寬度、三用途、Manager 主要／等待／錯誤／成果及 NonC 長中文路徑；普通控制項與選項點選區至少 48px。測試另發現 Playwright 在原生 zoom 的截圖寬度裁切，改用 CDP 的實際 layout bounds 擷取完整實體寬度，沒有調整產品 zoom 或用 CSS zoom 代替。

整合測試的 Probe 為空 pair，不能被目前搬移 pair 的 session 比對拒絕；已修正正式 handler。Probe 自身 HTTP collector 會產生其他回應，擷取測試改用唯一 correlation id 找回正式 writer 的 bytes，不能假設全域序號。小資料封裝可在取消前結束，並行取消 fixture 改在既有 pre-export 邊界做有上限的測試排程，仍由原始取消驗證器讀取真正 durable request；不是產品延長 timeout，也不是原生 P0 通過證據。

P0 原生傳輸仍 NotPassed；本節不宣告整輪完成、不移除原契約或把缺口移到下一輪。全部新增修正及正式 handler 旅程須完成新證據後才提交本段。

### 冷啟動 ZIP 匯入相依修正：已獨立提交

正式 Automatic ZIP 成果首次交給全新 Windows PowerShell 5.1 程序時，`Test-WsmZipVolume` 找不到 `IO.Compression.ZipArchiveMode`。先在同一程序匯出再匯入的測試會先載入組件，因而掩蓋問題。核心現在明確載入 System.IO.Compression；沒有改放寬封包／索引／hash 檢查。以 HEAD 基準僅覆蓋核心修正及新測試的固定副本，兩個全新 5.1／7 程序逐項核對實際 ZIP member 與 volume hash 通過。已 commit／push `21293cb390ceb5817bcb7ff6143b5afe2fba133f` 並核對遠端相同。

新 Final phase 完整測試在 `final-phase-complete` 的 WinPS5.1／PS7 均通過 Target runtime 133（包含真還原／取消／重播、真正 Staged 與 Final core validation、精確安全投影讀回及 controlled activated-state observation）；109 個輸入測後未變。啟用狀態由測試受控觀察提供，沒有執行真服務啟用或代稱現場切換通過。

`state-binding-complete` 兩引擎 ProofHandoff 25、雙 Source 共享／雙 Target 資料共享／獨立狀態共享 Operations、TargetHandoff 均通過；109 輸入測後不變。`ui-capture-final` 真 Edge 縮放／版面、兩引擎實際 x64 CMD（隔離入口 fixture）及帳號 ACL metadata-only 觀察通過，112 輸入未變。主代理實看完整 200% Target 成果、Manager 320px 錯誤及長路徑畫面；原生 zoom 截圖現在保留完整實體寬度。

本次固定副本的原生 Edge 重驗仍在 30s DOMContentLoaded deadline 失敗：已發起 HTML／CSS／nonc.js／console.js，沒有取得完整可核對原生頁面。`native-final-observed.log` 保留原錯誤；未延長產品／測試時限或改動 AdGuard。測試先前未即時處理 response.body() 的拒絕也已修正，避免未處理 Promise 使診斷與 finally 清理被中斷。P0 仍 NotPassed，M04 原生頁保存與整輪 P6 仍未通過。

### 非同步完成與 Probe 鎖相依修正

正式旅程再重現兩個本輪接縫缺陷，已回到實作補齊，而不是把失敗列為下一輪：

1. DeveloperProbe 雖有獨立 worker lane，提交前仍經搬移 `.wsm.lock` 讀 revision。改為只對這個無搬移權威的動作使用空 pair／零 revision vector；session、origin、token、角色、idempotency 及獨立 Probe 排他鎖仍保留。持有搬移鎖的反例確認 Probe 可取自己的提交 vector、Inventory 仍不得繞過鎖。
2. TargetDirectoryImport 先回 Running、之後成功時，舊 runtime identity cache 未失效，畫面仍停 NeedsPackage。完成輪詢現在只刷新同 role／pair／context 的 runtime job；若上一筆 runtime 讀取尚在執行，排入一次新的唯讀刷新，不重送寫入。新增延遲完成的 API fixture，走完接收→盤點→比較→決策→預覽→還原→驗證。

固定副本 `async-runtime-v2` 的延遲 Target UI 與兩引擎 HtmlConsole 86 通過；`last-ui-regression` Source／Target UI、NonC UI 17、真 Edge 200% 及 Manager 四寬度／四狀態、雙引擎投影 175 通過。正式 handler 的新快照另重驗。

正式 Target fixture 過去使用受控空軟體盤點，明確比較操作的重新觀測卻讀取本機實際軟體，核心因此正確拒絕漂移。現改為僅在隔離 Target fingerprint 下提供與該盤點一致的 software collector 觀測；核心 catalog validator、facts hash／漂移比較、receipt、還原、journal 均未替換。此為測試觀測來源一致性修正，不放寬產品 gate，也不代表測得真實 Target 軟體相容。

### 工作間邊界與執行畫面版本綁定

- 材料開啟／下載與取消路由已接入同一上下文核對：精確 WorkRoot、角色及 pair；獨立 Probe 的 pair 必須為空。完整歷史摘要仍可檢視，來源不明的舊 job 不變成開啟材料或取消的權限。HtmlConsole 兩引擎現為 91 checks，包含跨 pair／角色／WorkRoot、缺來源及 malformed Probe 拒絕。
- 新 `Test-WorkspaceWorkerIsolation.ps1` 在兩個全新 5.1／7 子程序實驗：主程序持有 migration OS lock 時，兩者都不能取得同 lane，但可各自取得 Probe lane；釋放後兩者均可取得 migration lane。四次實驗通過，不以同程序模擬跨程序 owner。
- 真 Target 連續操作重現：新決策已保存、runtime 已顯示預覽入口，但提交仍從較舊 session 取 expected revision，核心正確回 stale_revision。`Get-WsmHtmlWizardRuntime` 現在讀取前後各核對一次 revision vector；途中改變則拒絕產生可用畫面，成功時明列該畫面的 viewContext。runtime 動作只採該審閱版本，不在提交前偷更新版本或移除 CAS。原有其他動作仍使用自己的既有審閱版本。
- 兩引擎 read-context wrapper 正反例與 Source／Target UI 通過；Target UI fixture 刻意讓 session revision 舊於 runtime 審閱版本，並由伺服端拒絕舊版本。既有延遲完成案例保留。最後正式 handler 旅程使用新固定快照重驗，較早的 stale_revision 失敗不列通過。

原始需求完整性再次對照：P1a／P2／P1b 的表單、選取、零備份 Target 註冊及 Manager 核准已提交；P3a／b 的備份／格式／停寫／耐久作業／取消／重播接正式 Source UI 與 CLI；P4a／b 的多共享證明／SID metadata／逐項映射／傳輸／Manager 及 Target 交接接正式 consumer；P5a／b／c 的兩格式 intake、比較、子集決策、預覽、逐項還原／取消續作及 Staged／Final 生命週期接正式 Target UI／CLI。U01–U08 均依原契約保留，不自動代認責任、來源信任、軟體相容或業務接受。P6 的縮放、畫面、文件及實際 ZIP 可由本機核對；P0 原生及 M04 原生啟動／保存仍 NotPassed，整輪不標完成。這些未通過項維持在本 PLAN，不移到後續輪次。

### 最後一輪使用端補漏與獨立核心提交

- 固定副本 `core-lock-independent`（HEAD 基準只覆蓋 Core 及測試，98 個輸入測後未變）通過雙引擎 Contracts 25、RecoveryContracts、OutputWorkspace，以及真跨程序釋放後取得／2 秒逾時不執行的四個案例。已推送 `a0c33827a49541330623fd7878255c30d9fc0e45` 並確認遠端 SHA。修正只對 Win32 sharing／lock violation 等待至多 2 秒，沒有刪鎖、接管 owner 或改 HTTP deadline。
- 已核驗的 NonC 證明選項現在依 host／share、本機時間與 UTC offset、精確材料短識別區分；相同 kind／SHA 去重，同 fingerprint 但不同 Source HostId 的舊證明不再列成目前選項。`proof-choice-final` 的兩引擎 Preparation 7 及實際兩來源／兩資料目的／獨立狀態共享 Operations 均通過。
- 作業輪詢只允許同時執行一輪，慢讀不再每三秒堆疊另一輪完整刷新。UI fixture 對每次 jobs 讀取延遲 3.5 秒，確認最大並行數為 1；仍維持原 10／15／30 秒用戶端時限。
- runtime 審閱版本與舊 session 快取分開：寫入前的新鮮 session 必須與已顯示 viewContext 完全一致，才可更新本機 session 快取；不相符先拒絕，不能偷改 request 到新版本。Target fixture 驗舊 view 零 POST、明確重讀後允許新 view／舊 session 快取的合法組合。
- 同 pair 重新載入新資料版本會撤下舊 runtime 快取；讀取開始與結束的用戶端版本不一致則不採用舊回應。完成回呼與普通讀取共用既有讀取，不重複排入刷新。Source 的資料版本切換與 NonC 草稿／匯入之後仍可接續備份，已以原使用端測試重驗。
- 重繪時已有相同 runtime 讀取，不再對立即完成的空結果重複排入 render，修正慢機上的 microtask 重繪迴圈。失敗畫面僅提供明確重新讀取按鈕，不無限自動重試。Target fixture 以延遲 200ms 的 runtime 回應加上同時兩次重繪重現這個接縫；Source／Target 測試通過。runtime POST 已由自己的明確流程刷新，不再同時觸發通用刷新。

WinPS5.1 的 Source 正式 handler 三子案例已完成：取消與 Probe 並行、逐項 Directory、Automatic ZIP 512MiB。ZIP 由全新程序真匯入後核對 manifest／artifacts／每個 payload hash，原 operation replay 與固定格式均核對。該次單一 runner 後續 Target 因當時的 UI 讀取／重繪缺陷失敗，不能把整個 runner 標 PASS；Source 子案例證據依執行已走到 Target startup 分開保留。PowerShell7 Target 的真 UI→正式 writer 擷取→核心接收／比較／決策／預覽／還原、檔案／journal hash 及同作業 replay 已通過；Native HTTP／origin／SMB 未由橋接證明。修正後 WinPS5.1 Target 另以新固定副本重驗，不沿用失敗結果。

### P3–P5 相依整合段：本機可控驗證完成，已提交

最新 `formal-read-snapshot-final-powershell.log` 已通過 WinPS5.1 Target 的真 Edge UI→正式 handler／writer 擷取→核心 Directory 接收、比較匯入、明確 plan 子集決策、預覽、實際還原與檔案／journal hash 讀回、同 operation 重播。與已通過的 PS7 Target、Source 三子案例、雙引擎 CLI／核心／多共享／取消續作／Staged–Final 證據分開列範圍，未把曾失敗的單一 full runner 改標通過。

最新受控副本 `read-snapshot-final` 兩引擎 HtmlConsole 91、RuntimeReadContext 正反例、ReceivedPlan 真 sealed plan／兩角色匯入全部通過；`renderer-final` 與 `runtime-cache-final` Source／Target UI 均通過，包含慢讀單次輪詢、並行重繪、舊 view 零 POST、明確再讀、來源版本變更及未知寫入查同 ID。`proof-choice-final` 雙引擎 Preparation 與完整多共享 Operations 通過。上述四副本測後逐檔雜湊未變。

讀取效能修正採最小範圍：Get-WsmHtmlRevisionVector／Context 在同一次工作目錄鎖內，把剛經正式讀取器核驗的 received plan 傳給 data-version 計算，不再立即重讀同份材料；不做跨請求 fingerprint 快取，執行仍走完整核驗。WinPS5.1 的最終正式旅程已使用這個版本。

本段把模組匯入／公開命令、typed metadata、角色／CAS／作業接線、UI／CLI 及所有必要輔助檔整組提交，避免推送不能獨立使用的 helper。實作／本機可控接線未發現待補項；P0 原生失敗、M04 原生啟動保存、整輪 P6 與可信不同模型體檢仍未通過／未完成，保持本輪開放，不移到下一輪。


提交紀錄：P3–P5 相依整合已 commit／push `9d4a27c336081f1d3febadcf933c130c2d7688e5`，遠端 SHA 已核對一致；包含 45 份成套來源／入口／測試及本 PLAN，沒有納入私人盤點原型。核心兩個獨立修正 `21293cb`、`a0c3382` 同樣已推送驗證。

### P6 可交付組件與仍未通過的門檻

文件由正式產生器同步 11 份完整 HTML 與索引，24 項檢查通過；新版發行以實際 ZIP 索引逐檔核對解壓 bytes、工具 fingerprint，以及含中文／空白路徑的 Windows PowerShell5.1 x64 模組、真 wizard 保存／讀回與正式 PS1 啟動器。沒有企業簽章，CMD 的 x64／路徑引用邊界另由隔離入口測試通過，不能合併宣稱原生完整頁旅程通過。最終 archive 的精確 SHA／位置以下列交付紀錄為準。

原生 P0 用最終受測來源再驗仍是 index 的 ERR_CONNECTION_RESET。另建唯讀隔離候選，只把 Cache-Control 加上 no-transform，其他 bytes、設定與 deadline 不變；30s DOMContentLoaded 仍失敗且 index reset，未推入產品。此結果排除該單一候選，沒有證明責任元件，也沒有改動 AdGuard。原生頁、session、資源一致性與保存仍未通過，P0／M04 原生部分／整輪 P6 保持 NotPassed。

完整性收尾：未發現尚未接入正式使用端的 P1–P5 已定案功能；本輪發現的核心、映射、讀取、作業及畫面缺陷均已在本輪修正。待解的是原生傳輸驗收與收尾門檻，不改列下一輪待辦或宣稱全輪完成。外部 Server／SMB／產品／業務／企業 PKI／規模仍 NotTested，ProductionVerified=false、ProductionExecutionEnabled=false。

收尾體檢狀態：主代理與 gpt-6-luna 均有實作，主代理確切模型版本無可信可區分紀錄；代理額度不足後也沒有改用其他模型。依 project-closeout，不能宣稱已取得不同於全部實作者的模型簽核。後續需以可確認身分的不同模型，對本 PLAN 原始契約、起點與所有本輪 commit 做體檢；目前的主代理自查與回歸不冒充該簽核。

### 發行驗證發現：工作根目錄初始化路徑預檢

最終發行測試曾把 smoke WorkRoot 放在長的中文／空白安裝目錄下，真 WinPS5.1 在 hosts\fingerprint 的原子暫存檔處失敗。這也暴露實際產品缺口：過長 WorkRoot 在建立部分目錄後才報 DirectoryNotFound。Initialize-WsmOutputWorkspace 現先檢查初始 host 目錄及原子 JSON 暫存檔的既定 Windows 路徑預算，超限在任何工作區建立前拒絕，HTML／CLI 提供選擇較短固定 WorkRoot 的指引。較深的交付／還原預算仍由各操作既有預檢核對，不承諾任意長路徑。

Release smoke 改按正式設計分離安裝目錄與固定工作根，保留含中文／空白的安裝路徑，並在真正匯出的模組中驗證過長初始化零建立；不是縮短安裝路徑或跳過初始化。`initialization-path-final` 兩引擎 OutputWorkspace、HtmlConsole 92 通過；實際 ZIP 逐檔／解壓 fingerprint、獨立短 WorkRoot 的真 wizard 保存讀回與 x64 PS1 入口通過。測試副本所有輸入測後未變。

### 原生傳輸隔離對照：Windows CI

新增僅本輪分支觸發的 Native released console workflow，固定 Playwright 1.62.1、實際 Microsoft Edge 及 WinPS5.1／PS7 分開測試。先建立真發行 ZIP、核對索引／解壓 bytes／工具 fingerprint，再由測試 helper 匯入該解壓模組與同目錄 HtmlConsole；不混用 repository 的產品模組。測試保留原生資源雜湊、125 項 session／inventory、一次可回復的選取保存及明確注入的錯誤案例。測試-only engine／module path 參數不修改產品行為或本機安全設定。response.body 的拒絕立即保留為診斷，guide 雜湊也正確取回實際 bytes，避免未處理 Promise 或誤把包裝物件當作 bytes。

本段提交前 JavaScript syntax、249 份腳本 encoding／PowerShell parsing、workflow YAML／雙引擎矩陣及 diff whitespace 檢查通過。原生執行結果以 GitHub Actions 實際 run／job log 補記；未取得結果前不標 P0 或 M04 通過。此 CI 只使用小型 fixture，不執行實體 4GiB／企業環境或放寬 deadline。
CI run 38686260214 的兩引擎均通過實際發行 smoke，原生頁面／session／125 項盤點已載入，但資源雜湊測試停止。精確追查 console.js：檔案 SHA cfe4cce0…，移除 UTF-8 BOM 後 SHA 67780bee…，正好等於 Playwright response.body 的結果。正式 handler 使用 ReadAllBytes，session 使用同檔 SHA，沒有改寫產品；差異來自 CDP 提供解碼文字時省略 BOM。測試改以真瀏覽器 fetch ArrayBuffer 核對未經文字解碼的實際 bytes 與原 session hash，另確認載入資源只允許完全相同或 CDP 省略單一既有 BOM；不修改 session hash、不忽略任意差異。其餘原生／寫入／錯誤斷言保留，需新 CI 完整通過才可判驗收。
CI run [38686507492](https://github.com/darionnnnnn/windows-server-migration/actions/runs/38686507492)，commit 25e7a0f，WinPS5.1 job 116262459381 與 PS7 job 116262459062 均 success。兩者使用原封實際發行／解壓模組；真原生 Edge 載入完整頁、未解碼 bytes 與 session asset hash、125 項盤點、一次真保存，以及明確注入非 JSON／reset／timeout／expired session 的錯誤處理通過。此為 GitHub Windows 隔離主機的原生有限旅程通過；本機環境 reset／逾時仍 NotPassed，責任元件未定，不把 CI 通過改寫成這台電腦已恢復。

下一段將以獨立測試走真解壓 CMD／PS1 預設入口、原生用途保存重讀及完整離線手冊，補 M04；既有 Source／Target 小資料 runtime fixture 增加原生 HTTP 模式，略過 writer capture bridge 並以實際 browser requests 記錄寫入。受控身分／盤點／software／取消排程觀察仍明列，不代稱實際服務／SMB／生產通過。保留原 30s 原生讀取時限，CI job 整體上限增加供四子案例使用，不放寬產品 deadline。
### 原生發行旅程發現的首次登記缺陷

實際 CMD 可啟動原生頁，但用途保存回 400。主代理以實際 Enter-WsmWorkspaceWorkerGuard 先建立 migration／Probe 兩鎖檔，再做首次用途登記，於未修正的 HEAD 重現「unowned state (console-probe-worker.lock)」。原有預先登記角色 fixture 未涵蓋這個順序。

Initialize-WsmWizardWorkspace 現將兩個精確 worker 鎖檔名辨識為 bootstrap 產物，仍拒絕 reparse／偽裝目錄與所有其他未知資料；不讀取鎖檔作授權、不刪鎖、不改 ownership、不解除活躍 Probe owner。新 Test-WizardBootstrapLocks 通過真啟動 guard→角色保存、migration metadata hash 不變、活躍 Probe FileShare.None 仍排他、兩個偽裝目錄均在 profile 建立前拒絕。固定副本 bootstrap-final 的 WinPS5.1／PS7 各通過新測試、WizardFlow 45、HtmlConsole 92，281 個輸入測後未變。正式 CMD 仍須以新 commit 在 CI 重驗，不以本機核心反例代替 M04。

CI runtime runner 的第一個完整模式在 Node22.23.3 於測試早期非正常退出，精確 exit -1073740791 (0xC0000409)，沒有得到 Source／Target 結果，故該段仍未通過；補足啟動階段診斷以定位，不據此推論產品失敗或安全元件責任。