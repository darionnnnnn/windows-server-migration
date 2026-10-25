'use strict';
// R19 守門：後端可能送到前端的代碼集合，必須是 console.js 對照表的子集。
// 後端集合一律從 src 靜態收集（不手寫第二份清單）；前端表從 console.js 原始碼解析。
// 缺漏時列出全部缺的代碼並失敗。確實不會送到前端的代碼才可進例外清單，且例外清單有過期檢查
// （例外代碼若後端已不再產生，或前端已補上，就必須從清單刪除）。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = rel => fs.readFileSync(path.join(root, rel), 'utf8').replace(/^﻿/, '');
const consoleSource = read('src/ui/console.js');
const assistiveRestore = read('src/AssistiveRestore.ps1');
const wizardRuntime = read('src/WizardRuntime.ps1');
const wizardBackup = read('src/WizardBackup.ps1');
const wizardBackupProjection = read('src/WizardBackupProjection.ps1');

// 例外清單：{ group, code, reason }。reason 必填。
// 目前為空：收集範圍已限定在「可還原判定」的四個函式，預覽專用的 Action（DeferredBySelection、DeferredNonC 等）本來就不在範圍內。
const EXCEPTIONS = [];

function sliceFunction(source, name) {
  const start = source.indexOf(`function ${name}`);
  assert.ok(start >= 0, `source function ${name} must exist`);
  const next = source.indexOf('\nfunction ', start + 10);
  return source.slice(start, next < 0 ? source.length : next);
}
function stripStrings(text) { return text.replace(/'(?:[^'\\]|\\.)*'/g, "''"); }
// 取出「const NAME = { ... }」或函式內「const names = { ... }」的物件字面量鍵（先抹掉字串內容，避免文案裡的冒號被當成鍵）。
function objectKeys(source, startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.ok(start >= 0, `console.js must contain ${startMarker}`);
  const from = start + startMarker.length;
  const end = source.indexOf(endMarker, from);
  assert.ok(end > from, `console.js must close the table after ${startMarker}`);
  const body = stripStrings(source.slice(from, end));
  return new Set([...body.matchAll(/(?:^|[,{])\s*([A-Za-z][A-Za-z0-9]*)\s*:/g)].map(m => m[1]));
}
const frontend = {
  restorable: objectKeys(consoleSource, 'const RESTORABLE_CODE_TEXT = {', '};'),
  backupReason: objectKeys(consoleSource, 'const BACKUP_REASON_CODE_TEXT = {', '};'),
  status: objectKeys(consoleSource, 'function statusName(value) { const names = {', '}; return names[value]')
};

function collectRestorableCodes() {
  const codes = new Set();
  // 1) 判定函式回傳的 Action／Status 成對字面量：Status 不是 Ready 的都是「不可直接還原」原因。
  // 只掃「可還原判定」的四個函式；預覽專用的 Action（DeferredBySelection／DeferredNonC／WaitForInstall 等）不經 restorableCode 送到選擇器。
  const gapFunctions = ['Get-WsmAssistiveTargetMissingVolumeGap', 'Get-WsmAssistiveVolumeCapacityGap', 'Get-WsmAssistiveFileScopeRestoreGap', 'Get-WsmAssistiveVolumeCapacityResults'];
  for (const name of gapFunctions) {
    for (const m of sliceFunction(assistiveRestore, name).matchAll(/(?:\$action|Action)='([A-Za-z]+)';\s*(?:\$status|Status)='([A-Za-z]+)'/g)) { if (m[2] !== 'Ready') codes.add(m[1]); }
  }
  // 2) ConvertTo-WsmWizardRestorableCode 的對應（預覽動作名 → 對外代碼）。
  const mapper = sliceFunction(wizardRuntime, 'ConvertTo-WsmWizardRestorableCode');
  const mapped = new Map([...mapper.matchAll(/'([A-Za-z]+)'\s*\{return '([A-Za-z]+)'\}/g)].map(m => [m[1], m[2]]));
  for (const [from, to] of mapped) { if (codes.delete(from)) codes.add(to); }
  // 3) 選項建構時直接寫入的 restorableCode。
  for (const m of wizardRuntime.matchAll(/\$restorableCode='([A-Za-z]+)'/g)) codes.add(m[1]);
  return codes;
}
function collectBackupReasonCodes() {
  const codes = new Set();
  for (const m of wizardBackup.matchAll(/\$reasonCode='([A-Za-z]+)'/g)) codes.add(m[1]);
  const info = sliceFunction(wizardBackupProjection, 'Get-WsmBackupReasonCodeInfo');
  for (const m of info.matchAll(/^\s*'([A-Za-z]+)'\s*\{/gm)) codes.add(m[1]);
  return codes;
}
function collectStatusNames() {
  const statuses = new Set();
  const writer = sliceFunction(assistiveRestore, 'Invoke-WsmAssistiveRestore');
  for (const m of writer.matchAll(/(?:\$status|Status)='([A-Za-z]+)'/g)) statuses.add(m[1]);
  for (const m of writer.matchAll(/Status -in @\(([^)]*)\)/g)) for (const s of m[1].matchAll(/'([A-Za-z]+)'/g)) statuses.add(s[1]);
  return statuses;
}

function checkGroup(group, backend, front) {
  const exceptions = EXCEPTIONS.filter(e => e.group === group);
  for (const e of exceptions) {
    assert.ok(e.reason && e.reason.length > 10, `exception ${group}/${e.code} needs a reason`);
    assert.ok(backend.has(e.code), `stale exception ${group}/${e.code}: the backend no longer produces it; remove it from EXCEPTIONS`);
    assert.ok(!front.has(e.code), `stale exception ${group}/${e.code}: the frontend table now has it; remove it from EXCEPTIONS`);
  }
  const allowed = new Set(exceptions.map(e => e.code));
  const missing = [...backend].filter(code => !front.has(code) && !allowed.has(code)).sort();
  assert.deepEqual(missing, [], `${group}: backend codes missing from the console.js table: ${missing.join(', ')}`);
}

test('R19: restorable reason codes the backend can send are all in RESTORABLE_CODE_TEXT', () => {
  const backend = collectRestorableCodes();
  for (const known of ['NoPayload', 'NeedsReconciliation', 'BackupMediaOverlap', 'MissingVolume', 'InsufficientCapacity', 'PermissionDenied', 'ManualWorkflow', 'External', 'BlockedConflict', 'Blocked', 'BlockedLocation', 'MountPointNotSupported']) assert.ok(backend.has(known), `collector sanity: ${known} must be found in src (the collector must not pass vacuously)`);
  checkGroup('restorable', backend, frontend.restorable);
});
test('R19: backup failure reason codes (A2) are all in BACKUP_REASON_CODE_TEXT', () => {
  const backend = collectBackupReasonCodes();
  for (const known of ['PathTooLong', 'Locked', 'Missing', 'AccessDenied', 'Failed']) assert.ok(backend.has(known), `collector sanity: ${known}`);
  checkGroup('backupReason', backend, frontend.backupReason);
});
test('R19: restore item result statuses are all in statusName', () => {
  const backend = collectStatusNames();
  for (const known of ['Succeeded', 'Failed', 'Deferred', 'NeedsReconciliation', 'BlockedByUnknownDependency', 'CredentialRejected', 'ManualEvidenceRequired', 'RebootRequired']) assert.ok(backend.has(known), `collector sanity: ${known}`);
  checkGroup('status', backend, frontend.status);
});
test('R19: the exception list itself has no unknown groups', () => {
  for (const e of EXCEPTIONS) assert.ok(['restorable', 'backupReason', 'status'].includes(e.group), `unknown exception group ${e.group}`);
});
