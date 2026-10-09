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