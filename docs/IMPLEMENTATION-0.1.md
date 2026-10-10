# 0.3 實作狀態與當期待辦

更新：2026-10-10。本文件只維護當前狀態；原始需求、歷史決策及固定快照證據見 [歷史索引](archive/README.md)。已完成程式 TODO 已移除；尚無外部資格的項目保留，不宣稱正式生產完成。

新增方向及全部待實作項目集中於 [第 3 輪規劃草案](MIGRATION-3-PLAN.md)，目前僅討論文件。下表是第 2 輪現行實作，不能據此宣稱 C 槽限定、非 C 跳板機工具或第 3 輪完整相依已完成。

2026-10-10 第三輪續訂：輔助搬移、預設全選／自訂、允許新版仍保存原設定舊路徑；全部使用者功能／文件HTML＋本機PowerShell／文字備援已定案。目的已有內容不合併，以HTML逐檔列無法放置／scope影響／人工重試；非IIS不新增adapter。新版與HTML入口取代先前強制同版／主要Markdown入口，保留全新Windows／JSON／兩種順序。現行TargetDiff未真正比較，缺軟體擋整次full／delta，外部目的仍阻擋；Decision=Pending非預選模型，HTML只有離線報告，未有全部文件／操作入口。Mapping／MigrationSpec.TargetPath文件缺陷已用隔離fixture重現。R3-01–10及S／U等全批次未實作／修正，存檔或版本選擇不是業務可用。

## 已實作範圍

| Phase | 現行實作與消費端 |
|---|---|
| A0/A1 | 來源分類、受審處置、Schema2 GeneralHost、型別化準備／外部相依與逐階段gate；catalog／review／restore／delta／cutover／Fleet／LabReport共同消費 |
| B1 | HKLM／可讀HKU／portable／app-local／人工軟體及coverage、媒體與安裝順序／副作用；每台全量MD／JSON／HTML／TXT／CSV |
| B2 | Oracle client與engine分界、exact provider／consumer、有效TNS_ADMIN與service REG_MULTI_SZ、精確IFILE閉包、wallet外部程序、ConfigFiles審核及readback |
| C | Windows設定差異專頁、整類選否與逐設定必要相依、Create／Keep／External／UpdateReviewed、型別／空值／DST prior復原、GPO／Unknown阻擋、catalog單次CAS |
| D/D2 | 固定WorkRoot／enrollment／attempt、全量與增量ZIP／Directory、容量及成員預算、不可變DocumentId／DeliveryId、實際匯入收據與Manager／Fleet／LabReport；受控WorkRoot搬移及中斷回復 |
| E1 | schema／plan／approval／journal／ownership／tool指紋相容、新producer-consumer與CLI／API／選單接線、WhatIf純預覽 |
| E2 | 停寫與來源擷取重驗、fencing／唯一writer、新交易回退／對帳、source resume、觀察及具名退役；真實跨台協調待驗收 |
| E3 | exact OS/runtime／Oracle tuple、release／SBOM／support、CMS／Crypt32離線信任與撤銷拒絕流程；有效企業鏈及正式放行待驗收 |

既有generic adapters及operation journal／workspace transaction保留。ManualWorkflow不是產品自動還原能力；runtime／第三方安裝維持使用者準備。操作契約見 [OPERATIONS.md](OPERATIONS.md) 與 [GENERAL-HOST-WORKFLOW.md](GENERAL-HOST-WORKFLOW.md)。ProductionExecutionEnabled及ProductionVerified維持false。

## 當期待辦：外部驗收與獨立體檢
- [ ] 代表性來源／目標及完整十台盤點：owner、產品／runtime／軟體清單、媒體、scope、容量、RPO/RTO與維護窗。
- [ ] 實際Server2016／2025／Core、語系、32bit runtime、policy／權限及provider的collector／export／restore／verify矩陣；補產品原生錯誤分類及正反例。
- [ ] 原生IIS／SCM／任務／分享／憑證／帳號／服務帳號模式、安裝副作用、reboot後readback，及名稱／IP／DNS／Kerberos／網域切換。
- [ ] Oracle exact provider／consumer／runtime帳號的TNS_ADMIN、DB／TCPS與業務驗證；企業有效信任鏈、撤銷材料、簽章／批准及正式資格。
- [ ] 代表性封裝→還原量測耗時、容量、尖峰記憶體與維護窗；既有4GiB邊界不等於企業效能，長路徑目前明確阻擋。
- [ ] 單台pilot、相依雙台及十台波次：真實freeze／fencing／activation／新交易回退／source resume／唯一writer、業務接受、觀察、備份實還原與退役批准。
- [ ] 真實瀏覽器與主控台完整操作旅程；Node DOM／CLI fixture不能代替此項。
- [ ] 可核實且不同於全部實作者模型的獨立體檢；先前主代理實作模型無可信身分紀錄，同模型不同effort不算換模型。
使用者的隔離Server無法讓代理連線，目前尚未收到真實清單／LabReport及企業材料。不能以合成測試補作這些證據，也不刪除原始驗收需求。

## 測試與交付規則

封存前程式基準4908910的 [GitHub Actions 38009745467](https://github.com/darionnnnnn/windows-server-migration/actions/runs/38009745467)已通過；第3輪規劃提交9903cbb未改runtime/test。歷史證據適用範圍見封存驗證紀錄，不在本文件重複各checkpoint。

2026-10-10文件封存：四份歷史文件以git mv移至docs/archive，更新索引及引用；ToolRelease遞迴收錄docs Markdown，保留離線連結。固定快照 `wsm-doc-archive-0c77659743ce40cb9f5c51810422a231` 的ScriptEncoding／Qualification在WinPS5.1及PS7各2/2通過；實際ZIP manifest／bytes投影通過、71個包內本機連結有效，147個src/tests/入口檔案hash與快照核對一致。核驗含封存文件收錄、無效簽章／改包拒絕及production鎖定。這是定向本機證據，不宣稱舊CI適用此修改或取得實機／企業資格；報告程式與其他遷移流程未改。第三輪複審已更正發行影響：純文件變更更新發行包／文件 hash，ToolFingerprint 只計 src／入口 bytes，本次程式指紋不變；重建包須核驗最終 bytes 並重新簽署，不沿用舊包簽章。後續改程式時既有核准依契約重驗，不熱換執行中 pair。

日常按改動影響重驗；Pipeline預設16小檔、取消8檔、報告2501列、Fleet十台各200、Spec200。5000分段及真實4GiB的特殊邊界保留；大容量／50k軟體／維護窗／RPO/RTO需代表性工作量與門檻，不能從合成數量推定。HTML分類列印最多2000列；完整軟體確認五格式不截斷資料。詳細測試操作見 [README](../README.md)。
