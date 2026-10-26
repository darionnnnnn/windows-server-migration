# Recovery and offline support runbook

This runbook applies to the isolated pilot workflow. Stop and request the designated owner if a hash, host identity, plan, journal, target setting, ACL, native readback, or evidence receipt differs from the approved record. Do not continue from a partial success message.

## Before starting or recovering

1. Confirm the independently verified release archive hash, detached ReleaseSigner signature, trust-policy hash, current revocation availability, and exact tool fingerprint. Run `Test-WsmToolRelease` on the receiving system.
2. Confirm the qualified source/target tuple, including build, edition, `InstallationType`, architecture, source/target PowerShell edition/version/process architecture/language mode/CLR/.NET Framework release, adapter bytes, product version, and Oracle provider/consumer context when applicable. A missing/expired/revoked qualification blocks production support.
3. Record the change ticket, maintenance window, source and target owners, backup/restore proof, freeze/fencing plan, external dependencies, and the person authorized to approve rollback. Production is disabled until a separate approved gate exists.
4. Keep workspace state, operation journals, source package, transport archive, target backup, signed plan, and logs on access-controlled storage. Do not put secrets or raw settings in a support bundle.

## Stop and preserve evidence

On any unexpected result, stop writers and do not retry an unverified native operation. Preserve the exact tool bytes and signatures, catalog and approved plan, package/manifest hash, operation-state directory, append-only journal, import/restore receipts, backup location, target observations, and sanitized report. Record UTC time, host identity fingerprint, operation/pair IDs, and the last completed action. Do not edit state JSON or discard pending operation records.

Use the available repair/rollback preview to reconcile the operation against native state. Recovery may resume only from the recorded before-state or exact tool-after-state; an unknown value is drift and requires owner investigation. Rollback is allowed only when the tool can prove current state still equals its recorded after-state. Preserve created/updated ownership separately and restore the exact typed prior value; never remove a pre-existing external value. For file trees, preserve the backup until owner acceptance and do not delete it to reclaim space before evidence collection.

## Offline diagnostic exchange

Generate the sanitized LabValidation report using the management procedure. Review the report before export; confirm it contains no password, credential, private key, connection string, raw registry setting, or sensitive host data. Keep the complete JSON and human-readable text together with their exact document identifiers and hashes. Transfer only through the enterprise-approved encrypted channel. The report is diagnostic evidence, not approval or a readiness receipt.

If raw evidence is specifically needed, obtain the data owner’s approval, restrict access to the collection folder, hash it, encrypt it with the enterprise-approved tool, and transfer the key through a separate channel. Remove scratch copies only after the case owner confirms durable receipt and the retention requirement permits removal. Record who removed each copy, when, and under which ticket. The repository and public release archive are not secure evidence stores.

## Retention and incident handoff

The enterprise change owner sets retention before collection. Preserve approval records, release signatures, exact tool bytes, qualification evidence, journals, backups, and rollback results for the longer of the applicable policy period and the active incident/change period. Do not invent a universal number of days. Apply legal hold when directed. At expiry, use the enterprise secure-deletion process and record disposition; do not delete evidence from an active rollback or investigation.

Escalate certificate validation failure, revoked signer/root, missing or stale offline revocation cache, policy hash mismatch, altered signed bytes, tuple mismatch, expired evidence, unexpected reboot, external business gate failure, or unverified rollback to the PKI owner, application/Oracle owner, server owner, and change authority as appropriate. Keep `ProductionExecutionEnabled=false` until the enterprise completes its separately authorized safety review and release gate.

## Typed source ownership and target transactions

Source freeze requires exact `SourceFreezeReady` writer inventory evidence. Revalidate the local evidence JSON and payload immediately before final package capture; do not transfer source-local paths as target gates. Source resume requires exact `SourceResumeReady` proof bound to the original durable SourceAttemptId/hash: target writers stopped, latest target data preserved, reconciliation complete, source exclusive writer ownership, and owner acceptance. Originally running tasks additionally require the dedicated task reconciliation record. Old textual YES/owner references do not satisfy these conditions.

When target transactions may exist, rollback and repair require typed `RollbackReconcile` facts and its unchanged payload. Never restore the older source as the writer merely because configuration rollback succeeded. If any proof is missing, expired, changed or mismatched, preserve state and return to the responsible application/data owner.

Missing or changed sealed ZIP volumes leave a failed checkpoint with every prior volume descriptor retained. Restore identical original bytes and retry, or create a separate new transport and independently approve its new hash; do not overwrite the old transport index. Directory delivery uses an exact allowlist and its own member budget, not the ZIP volume limit. Use the enrolled WorkRoot and attempt; deleting or recreating state is not a supported recovery method.

## 新機還原（TargetRestore）的處置步驟

適用於在新機執行還原後，結果不是「成功」的情形。原則不變：先停手、保留證據；不要手改狀態檔，不要為了重試而刪除狀態、journal 或鎖。等待輸入、部分完成、需先對帳都不能當成成功。文字備援的入口是主選單 22 的「目標」角色：選項 4 還原／重試、10 回復預覽／執行、11 修復 checkpoint、16 還原後重新核對。

### 等待輸入（WaitingForInput）與中斷（Interrupted）

症狀：HTML 作業頁顯示「還原暫停，需要帳戶密碼才能繼續」；CLI 以返回碼 2 結束，印出 `Status=WaitingForInput ParentOperationId=<作業識別碼>`。標準輸入被重新導向時，工具不會讀取帳密，一律在詢問前以等待輸入停止。

1. 記下作業識別碼。等待輸入時，已完成的項目不會重做，母作業保留。
2. 在互動主控台或 HTML 的「輸入帳密以繼續」輸入帳密。密碼被拒絕時，更正後重新輸入。
3. 某一組帳號暫時無法提供時，按「延後這組」（CLI 輸入 `DEFER`）：這組的項目本次不還原，其他項目照常進行，之後在新的還原中處理。同一組被拒絕 3 次會自動延後。
4. 原本的視窗已關閉時，由目前的視窗接手：HTML 勾選「由這個視窗接手此還原」，CLI 輸入 `TAKEOVER`。不接手就不會續作。
5. 程序中斷（Interrupted）時，HTML 按「檢視恢復預覽」，核對「結果需要核對的項目」後按「繼續還原」；CLI 輸入 `RESUME`。續作只接續同一個父作業並逐項對帳，不重寫已確認完成的項目。
6. 不打算繼續時，按「取消這次還原」再按「確定取消」。已完成的項目保留，未完成的項目要重新預覽後才能再還原。

### 部分完成（Partial）

症狀：還原結果有項目成功，也有項目未成功（失敗、延後、帳密被拒、受阻擋、目的衝突、需人工證據、已取消等）。

1. 逐項查看未成功的原因，先處理原因：目的位置的衝突檔案、缺少的磁碟、空間、帳密、尚未安裝的相依軟體。
2. 結果頁若顯示「請先修復未完成的作業」，表示還有未完成的寫入紀錄，先照下一節處理，再回來重試。
3. 按「重試失敗項目」：工具產生只含失敗項目的新選擇紀錄，責任人與理由預填但必須由您確認。這一步不會開始還原；回到還原預覽確認後，再按開始還原。同一份選擇再按一次只會顯示上次結果，不會重做。
4. 已成功的項目不會重寫。目標已有不同內容的檔案，要先人工處理（自行備份或移走），不要期待工具覆寫；內容與備份相同的既有檔記為「沿用既有檔」，算成功，回復時也不會刪除。

### 需先對帳（NeedsReconciliation）

症狀：項目顯示「需先對帳」，預覽不可還原，也不在重試候選內。常見原因是寫入途中發生例外或中斷，留下沒有完整擁有紀錄的檔案範圍，或未完成的寫入紀錄。

1. 保留現場，執行修復：HTML 的「修復」動作，或 CLI 目標選項 11「修復 checkpoint」（`Repair-WsmOperation`）。
2. 修復逐檔判定：目標檔不存在，視為尚未寫入；內容雜湊等於備份，補登為工具擁有；其他情況（內容不同、reparse point、被資料夾佔住、讀不到）保留原檔並記為衝突，不補登、不覆寫、不刪除。
3. 有衝突時，先人工處理衝突，再修復一次。判定回到可還原之後，才能重試或重新選擇還原。
4. 修復後仍無法對應 journal 時，維持阻擋並交給 owner；不要編輯 state、journal 或鎖。

### 回復（RolledBack：已回復，請重新選擇還原）

1. 回復只用於明確決定撤回這次還原：目標選項 10「回復預覽／執行」，先看預覽，再輸入 `ROLLBACK <PairId>`。目標可能已有新交易時，仍須依前文提供 RollbackReconcile 證據，不能因為回復成功就讓舊來源接手寫入。
2. 沿用既有檔不會被刪除，也不會被改 ACL 或 metadata；它被改動只回報、不修正。
3. 回復完成後，畫面顯示「已回復，請重新選擇還原」。項目重新選取後可以再還原；這不屬於「重試失敗項目」。
4. 回復不會自動啟動服務或排程，也不會自動恢復來源。

### 還原後重新核對

安裝軟體、重新開機或調整權限後，已還原的檔案與設定可能被改寫。「重新核對」（目標選項 16）只讀取目前內容並與還原時的記錄比對，不覆寫、不刪除、不改權限。漂移的項目由成功降為「待核對」並附原因，無法讀回的標為「無法自動核對」；待核對的項目不會被自動重試，要重新還原必須明確選取。
