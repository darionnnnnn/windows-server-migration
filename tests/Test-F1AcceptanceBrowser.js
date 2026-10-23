// N9e：F1 驗收補測（只補驗收，不改 UI）。真實 Edge + 真實 src/ui；API 為本檔內的固定替身（結果集與軟體列由真實 PowerShell 產生器建出）。
// 涵蓋六個新畫面：備份結果三分頁、安裝軟體分頁、Target 新機安裝檢查、C2 軟體處置審閱、D2 候選確認與對應審閱、排除區域表。
//   1. 鍵盤：只用 Tab／Shift+Tab／Enter／Space／方向鍵／Esc 完成主要任務；焦點全程可見，操作後不被重繪搶走。
//   2. 320px 與「1280 寬的 200% 縮放」（640 CSS px、DPR 2）：不得整頁水平溢位，關鍵元素在視窗內，內容不被截斷。
//   3. 重開與不重問：已確認的項目重新整理後維持；重新盤點後只有變動的項目要求再確認；新草稿不被清除。
//   4. 每個畫面零 console／頁面錯誤。
// 焦點缺陷（F1-FOCUS-*）已於 N9e2 修正，現在一律 strict。
// 突變（環境變數 WSM_F1_MUTATE，在測試端伺服器即時轉換，不改 src）：wide／div／reopen，各自必須轉紅。
const assert = require('node:assert/strict'), fs = require('node:fs'), http = require('node:http'), os = require('node:os'), path = require('node:path');
const { spawnSync } = require('node:child_process');
const runtimePath = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtimePath, 'playwright'));
const root = path.resolve(__dirname, '..'), screens = path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });
const MUT = process.env.WSM_F1_MUTATE || '';
const edge = process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const hex = ch => ch.repeat(64);

// ---------------------------------------------------------------------------------------------------- 計數與斷言
const tally = new Map(), consoleErrors = new Map();
function ok(screen, condition, message) { assert.ok(condition, `[${screen}] ${message}`); tally.set(screen, (tally.get(screen) || 0) + 1); }
function eq(screen, actual, expected, message) { assert.deepEqual(actual, expected, `[${screen}] ${message} — actual ${JSON.stringify(actual).slice(0, 400)}`); tally.set(screen, (tally.get(screen) || 0) + 1); }

// ---------------------------------------------------------------------------------------------------- 真實固定資料
function runFixture(script, args) {
  const run = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tests', script), ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  assert.equal(run.status, 0, `${script} failed: ${run.stderr}`);
}
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\ufeff/, ''));
const tempDirs = [];
function buildResults(script, extra) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-f1-')); tempDirs.push(dir);
  runFixture(script, ['-OutDir', dir, ...extra]);
  return { dir, report: path.join(dir, 'backup-report.html'), results: readJson(path.join(dir, 'backup-item-results.json')) };
}
function buildTarget(shape) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-f1-target-')); tempDirs.push(dir);
  runFixture('New-SoftwareTabFixture.ps1', ['-OutDir', dir, '-Shape', shape]);
  return readJson(path.join(dir, 'target-software-check.json')).softwareCheck;
}
const fileUrl = file => 'file:///' + file.replace(/\\/g, '/');

// ---------------------------------------------------------------------------------------------------- 靜態資源（含突變轉換）
const assets = new Map([['/', 'index.html'], ['/ui/index.html', 'index.html'], ['/ui/console.js', 'console.js'], ['/ui/console.css', 'console.css'], ['/ui/guide.html', 'guide.html'], ['/ui/nonc.js', 'nonc.js']]);
function assetBody(name) {
  let text = fs.readFileSync(path.join(root, 'src', 'ui', name), 'utf8');
  if (MUT === 'wide' && name === 'console.css') text += '\n#backup-item-results::after{content:"";display:block;width:600px;height:8px;background:#c00}\n';
  if (MUT === 'div' && name === 'console.js') {
    // 只把 Target 新機安裝檢查的列印鈕（第二次出現）改成 div onclick：滑鼠可用、鍵盤無法操作。
    const needle = "el('button', 'secondary-button', '列印新機安裝檢查表'); printButton.type = 'button';";
    const first = text.indexOf(needle), second = first < 0 ? -1 : text.indexOf(needle, first + needle.length);
    assert.ok(second > 0, 'mutation anchor for the Target print button must exist');
    text = text.slice(0, second) + "el('div', 'secondary-button', '列印新機安裝檢查表'); printButton.type = 'button';" + text.slice(second + needle.length);
  }
  return text;
}

// ---------------------------------------------------------------------------------------------------- 可變的替身狀態
const S = { reopenPending: false, mode: 'workbench', role: 'Source', revision: 5, decisionRevision: 7, results: null, copy: null, target: null, actions: [], jobs: new Map(), submissions: [], c2Rows: [], mappingRows: [], imported: false, mappingRecorded: false };
const COPY_NOT_VERIFIED = { state: 'NotVerified', text: '尚未驗證', verifiedUtc: '', networkUnconfirmed: false, reason: '尚未建立並驗證獨立副本。' };
const importedItemId = hex('e'), confirmationHash = hex('2'), inventoryHash = hex('1'), scopeItemId = hex('d'), pairId = 'f1-pair', contextId = 'f1-context';
const software = (id, name, extra) => Object.assign({ SoftwareId: id, Name: name, Publisher: 'Fixture Corp', Version: '1.0', Architecture: 'x64', Scope: 'Machine', SID: '', RegistryView: 'Registry64', Location: 'D:\\Apps', SourceKind: 'Registry', CaptureStatus: 'Success', ConsumerItems: [], SpecialProduct: false, AllowedDispositions: ['Reinstall', 'Portable', 'KeepCompatible', 'External', 'NotNeeded', 'Unknown'], DecisionState: 'Unreviewed', Disposition: '', Owner: '', Reason: '', Evidence: '' }, extra || {});
function resetManager() {
  S.mode = 'manager'; S.role = 'Manager'; S.revision = 3; S.decisionRevision = 10; S.jobs = new Map(); S.submissions = []; S.imported = false; S.mappingRecorded = false;
  S.c2Rows = [software('sw-a', '訂單系統執行階段', { ConsumerItems: [{ ItemId: 'i1', Name: '訂單網站', Decision: 'Include' }] }), software('sw-b', '報表小工具', { Scope: 'User' }), software('sw-c', 'Microsoft SQL Server Database Engine', { SpecialProduct: true, AllowedDispositions: ['External', 'NotNeeded'] }), software('sw-d', '排程輔助程式', { DecisionState: 'Reviewed', Disposition: 'External', Owner: 'o', Reason: 'r', Evidence: 'e' })];
  S.mappingRows = [
    { ReferenceId: hex('a'), ConsumerItemId: hex('7'), FieldPointer: '/Actions/Exec/Command', ReferenceKind: 'TaskCommand', Path: 'C:\\Business\\worker.exe', Required: true, ReviewRequired: false, Opaque: false, DiscoveryStatus: 'Mapped', SuggestedFileScopeItemId: scopeItemId, SuggestedTargetValue: 'C:\\Business\\worker.exe', DiscoveryReason: '', Decision: 'Pending', FileScopeItemId: '', DependencyType: 'None', StoredStatus: 'NotRecorded' },
    { ReferenceId: hex('b'), ConsumerItemId: hex('7'), FieldPointer: '/Actions/Exec/WorkingDirectory', ReferenceKind: 'TaskWorkingDirectory', Path: 'C:\\Business', Required: false, ReviewRequired: true, Opaque: false, DiscoveryStatus: 'Unmapped', SuggestedFileScopeItemId: '', SuggestedTargetValue: '', DiscoveryReason: 'ExactMembers 不宣稱涵蓋資料夾', Decision: 'Pending', FileScopeItemId: '', DependencyType: 'None', StoredStatus: 'NotRecorded' },
    { ReferenceId: hex('c'), ConsumerItemId: hex('7'), FieldPointer: '/Actions/Exec/Arguments', ReferenceKind: 'TaskArgumentPath', Path: 'C:\\Business\\settings.json', Required: false, ReviewRequired: true, Opaque: false, DiscoveryStatus: 'Unmapped', SuggestedFileScopeItemId: '', SuggestedTargetValue: '', DiscoveryReason: '', Decision: 'Pending', FileScopeItemId: '', DependencyType: 'None', StoredStatus: 'NotRecorded' },
    { ReferenceId: hex('f'), ConsumerItemId: hex('7'), FieldPointer: '/Actions/Exec/Arguments', ReferenceKind: 'TaskArguments', Path: '', Required: false, ReviewRequired: true, Opaque: true, DiscoveryStatus: 'Unmapped', SuggestedFileScopeItemId: '', SuggestedTargetValue: '', DiscoveryReason: '', Decision: 'Pending', FileScopeItemId: '', DependencyType: 'None', StoredStatus: 'NotRecorded' }
  ];
}
function useWorkbench(results, copy) { S.mode = 'workbench'; S.role = 'Source'; S.revision = 5; S.decisionRevision = 7; S.results = results; S.copy = copy || COPY_NOT_VERIFIED; S.submissions = []; }
function useTarget(target, actions) { S.mode = 'target'; S.role = 'Target'; S.revision = 5; S.decisionRevision = 7; S.target = target; S.actions = actions || []; S.submissions = []; }
const previewHash = () => (S.decisionRevision.toString(16).padStart(2, '0') + hex('9')).slice(0, 64);
const sessionBody = () => ({ token: 'f1-token', contextId, sessionId: 'f1-session', hostName: 'f1-host', role: S.role, workspace: root, pairId, revision: S.revision, decisionRevision: S.decisionRevision, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: `dv-${S.revision}`, principal: 'f1-user' });
const viewContext = () => ({ sessionId: 'f1-session', contextId, pairId, role: S.role, revision: S.revision, decisionRevision: S.decisionRevision, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: `dv-${S.revision}`, readUtc: new Date().toISOString() });
function wizardBody() {
  const common = { kind: 'WizardProjection', Kind: 'WizardProjection', intentRequired: false, legacy: false, role: S.role, workspaceRole: S.role, roleMatchesWorkspace: true, pairId, pairName: 'Source to Target', mode: 'ItemByItem', revision: S.revision, reviewGroupIndex: 0, groups: [], gates: [], actions: [], missingFields: [] };
  if (S.mode === 'manager') return Object.assign(common, { currentStep: 'prepare', nextStep: 'prepare', state: { CurrentStep: 'prepare', Mode: 'ItemByItem' }, results: {}, context: {} });
  const step = S.mode === 'target' ? 'handoff' : 'backup';
  return Object.assign(common, { currentStep: step, state: { CurrentStep: step, Mode: 'ItemByItem' }, scan: { status: 'Succeeded', hasResult: true, itemCount: 3, incompleteCount: 0 }, results: { scan: { status: 'Succeeded', hasDurableRecord: true }, backup: { status: 'Succeeded', hasDurableRecord: true }, restore: { status: 'NotStarted', hasDurableRecord: false }, hasAny: true }, context: { catalogRevision: 7, selectionRevision: 3, inventoryRevision: 1 } });
}
function backupView() {
  const r = S.results, has = key => Object.prototype.hasOwnProperty.call(r, key);
  return { kind: 'BackupItemResultsView', available: true, integrity: 'Verified', attemptId: 'fixture-attempt', backupOperationId: 'fixture-op', generatedUtc: r.GeneratedUtc, inventorySource: r.InventorySource, offlineReadiness: 'AwaitingIndependentCopy', counts: r.Counts, rows: r.Rows, software: r.Software, schemaVersion: r.SchemaVersion || 1, coverageRegions: has('CoverageRegions') ? r.CoverageRegions : null, excludedRegions: has('ExcludedRegions') ? r.ExcludedRegions : null, excludedRegionsBinding: has('ExcludedRegionsBinding') ? r.ExcludedRegionsBinding : null, excludedCompleteness: has('ExcludedCompleteness') ? r.ExcludedCompleteness : null, independentCopy: S.copy, viewContext: viewContext() };
}
function filesFor(itemId, page) {
  const pageSize = 100, total = itemId === 'item-0002' ? 2 : 250, entries = [];
  for (let i = (page - 1) * pageSize; i < Math.min(total, page * pageSize); i++) entries.push({ RelativePath: `dir${Math.floor(i / 50)}\\file-${String(i).padStart(3, '0')}.dat`, Bytes: 1000 + i, Sha256Prefix: (i.toString(16).padStart(2, '0') + 'ab').repeat(3).slice(0, 12), IsDirectory: false });
  return { kind: 'BackupItemFiles', available: true, AttemptId: 'fixture-attempt', ItemId: itemId, Page: page, PageSize: pageSize, TotalCount: total, DirectoryCount: 0, PageCount: Math.max(1, Math.ceil(total / pageSize)), Entries: entries };
}
const candidateReview = () => ({ Kind: 'SourceCandidateConfirmationReview', PairId: pairId, ItemId: importedItemId, Decision: 'Pending', DecisionRevision: S.decisionRevision, SelectionRevision: 1, ConfirmationId: 'conf-1', ConfirmationHash: confirmationHash, MaterialReference: 'assistive/materials/x', ScanId: 'scan-00000001', CandidateId: hex('4'), CandidateType: 'DirectoryRoot', InventoryHash: inventoryHash, InventoryRevision: 1, Root: 'C:\\', ScopeRoot: 'C:\\Business', MemberCount: 3, FileMemberCount: 2, DirectoryMemberCount: 1, MembersShown: 3, MembersTruncated: false, Members: [{ RelativePath: 'worker.exe', SHA256: hex('a'), Length: 1200, CandidateId: hex('4') }, { RelativePath: 'settings.json', SHA256: hex('b'), Length: 300, CandidateId: hex('4') }, { RelativePath: 'empty-dir', SHA256: '', Length: 0, CandidateId: hex('4'), EntryType: 'Directory' }], WorkloadReferences: S.mappingRows.map(row => ({ ConsumerItemId: row.ConsumerItemId, FieldPointer: row.FieldPointer, ReferenceKind: row.ReferenceKind, Path: row.Path, Required: row.Required, ReviewRequired: row.ReviewRequired })), viewRevision: S.revision });
const mappingReview = () => ({ Kind: 'SourceCandidateWorkloadMappingReview', PairId: pairId, CandidateItemId: importedItemId, ConfirmationId: 'conf-1', ConfirmationHash: confirmationHash, InventoryHash: inventoryHash, InventoryRevision: 1, DecisionRevision: S.decisionRevision, SelectionRevision: 1, References: S.mappingRows });
const c2Review = () => ({ Kind: 'AssistiveSoftwareDispositionReview', Status: 'Previewed', PairId: pairId, DecisionRevision: S.decisionRevision, InventoryHash: inventoryHash, SoftwareCatalogHash: hex('8'), Rows: S.c2Rows, Coverage: [{ Probe: 'Uninstall', Scope: 'Machine', SID: '', View: 'Registry64', Status: 'Success', EvidenceKind: 'Registry', Count: 3, ErrorKind: '' }, { Probe: 'Uninstall', Scope: 'User', SID: 'S-1-5-21-1', View: 'Registry32', Status: 'PermissionDenied', EvidenceKind: 'Registry', Count: 0, ErrorKind: 'AccessDenied' }], TrustedSoftwareRoots: { Status: 'Partial', Count: 1, Diagnostics: [] }, ReadinessProof: false, AuthoritativeApproval: false, PreviewHash: previewHash() });
function outcomeFor(body) {
  const args = body.args || {};
  if (body.action === 'SourceCandidateConfirmImport') { S.imported = true; S.decisionRevision++; S.revision++; return { status: 'ReviewRequired', outputs: [{ Status: 'ImportedReviewRequired', ItemId: importedItemId, MemberCount: 3, DecisionRevision: S.decisionRevision, AuthoritativeApproval: false }] }; }
  if (body.action === 'SourceCandidateMappingSubmit') {
    for (const decision of args.Decisions || []) { const row = S.mappingRows.find(item => item.ReferenceId === decision.ReferenceId); if (row) Object.assign(row, { Decision: decision.Decision, FileScopeItemId: decision.FileScopeItemId, DependencyType: decision.DependencyType, StoredStatus: 'Recorded' }); }
    S.decisionRevision++; S.revision++;
    return { status: 'ReviewRequired', outputs: [{ Status: 'SubmittedReviewRequired', MappingCount: (args.Decisions || []).length, DecisionRevision: S.decisionRevision, AuthoritativeApproval: false }] };
  }
  if (body.action === 'SoftwareDispositionReviewSubmit') {
    for (const decision of args.Decisions || []) { const row = S.c2Rows.find(item => item.SoftwareId === decision.SoftwareId); if (row) Object.assign(row, { DecisionState: 'Reviewed', Disposition: decision.Disposition, Owner: decision.Owner, Reason: decision.Reason, Evidence: decision.Evidence }); }
    S.decisionRevision++; S.revision++;
    return { status: 'Succeeded', outputs: [{ Status: 'Applied', SubmittedCount: (args.Decisions || []).length, DecisionRevision: S.decisionRevision }] };
  }
  return { status: 'Failed', outputs: [] };
}
const fixedBackupJob = () => ({ jobId: 'fixture-backup-job', workspace: root, pairId, role: 'Source', sessionId: 'f1-session', contextId, startedRevision: 5, action: 'StartBackup', status: 'Succeeded', canCancel: false });
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1'), asset = assets.get(url.pathname);
  if (asset) { res.writeHead(200, { 'Content-Type': asset.endsWith('.js') ? 'application/javascript; charset=utf-8' : asset.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' }); res.end(assetBody(asset)); return; }
  if (url.pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }
  let raw = ''; req.on('data', c => raw += c);
  req.on('end', () => {
    const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/api/session') {
      // 突變 reopen：重新開啟頁面時，替身端把已確認的狀態清空（模擬「重開後又要重問」）。
      if (MUT === 'reopen' && S.mode === 'manager' && S.reopenPending) { S.reopenPending = false; S.c2Rows.forEach(row => { if (row.DecisionState === 'Reviewed') Object.assign(row, { DecisionState: 'Unreviewed', Disposition: '' }); }); S.mappingRows.forEach(row => Object.assign(row, { Decision: 'Pending', StoredStatus: 'NotRecorded' })); }
      return send(200, sessionBody());
    }
    if (url.pathname === '/api/context') return send(200, { roles: [S.role], pairs: [{ pairId, label: 'Source to Target' }], role: S.role, pairId, contextId, revision: S.revision, decisionRevision: S.decisionRevision, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: `dv-${S.revision}` });
    if (url.pathname === '/api/wizard' && req.method === 'GET') return send(200, wizardBody());
    if (url.pathname === '/api/wizard/nonc') return send(200, { Kind: 'WizardNonCProjection', Role: S.role, PairId: pairId, ContextId: contextId, DataVersion: `dv-${S.revision}`, HasNonC: false });
    if (url.pathname === '/api/wizard/runtime') return send(200, { Kind: 'WizardRuntimeProjection', Role: S.role, PairId: pairId, status: S.mode === 'target' ? S.target.status : 'Idle', actions: S.mode === 'target' ? S.actions : [], runtime: S.mode === 'target' ? { target: S.target } : {}, viewContext: viewContext() });
    if (url.pathname === '/api/jobs' && req.method === 'GET') return send(200, { items: S.mode === 'manager' ? [...S.jobs.values()] : [fixedBackupJob()] });
    if (url.pathname.startsWith('/api/jobs/') && req.method === 'GET') { const job = S.jobs.get(decodeURIComponent(url.pathname.split('/').pop())); return job ? send(200, { job }) : send(404, { code: 'job_not_found' }); }
    if (url.pathname === '/api/view' && req.method === 'GET') {
      if (url.searchParams.get('contextId') !== contextId || url.searchParams.get('dataVersion') !== `dv-${S.revision}`) return send(409, { code: 'stale_revision', message: 'Fixture view changed.', nextStep: 'Reload.', correlationId: 'f1-stale' });
      if (url.searchParams.get('action') === 'backup-items' && S.results) return send(200, backupView());
      return send(200, { viewContext: viewContext(), rows: [], items: [] });
    }
    if (url.pathname === '/api/view' && req.method === 'POST') {
      const body = JSON.parse(raw);
      if (body.action === 'BackupItemFiles') return send(200, filesFor(body.args.ItemId, body.args.Page));
      if (body.action === 'SourceCandidateConfirmReview') return send(200, candidateReview());
      if (body.action === 'SourceCandidateMappingReview') return send(200, mappingReview());
      if (body.action === 'SoftwareDispositionReview') return send(200, c2Review());
      return send(404, { code: 'not_found' });
    }
    if (url.pathname === '/api/operations' && req.method === 'POST') {
      const body = JSON.parse(raw); S.submissions.push(body);
      const terminal = outcomeFor(body);
      const record = { jobId: body.operationId, operationId: body.operationId, action: body.action, status: 'Running', role: S.role, pairId, workspace: root, revision: S.revision, StartedUtc: new Date().toISOString(), outputs: [] };
      S.jobs.set(body.operationId, record);
      setTimeout(() => Object.assign(S.jobs.get(body.operationId), terminal, { CompletedUtc: new Date().toISOString(), revision: S.revision }), 60);
      return send(202, { job: { jobId: record.jobId, operationId: record.operationId, action: record.action, status: 'Running', role: S.role, pairId, revision: S.revision } });
    }
    return send(404, { code: 'not_found', route: url.pathname });
  });
});
const count = action => S.submissions.filter(item => item.action === action).length;

// ---------------------------------------------------------------------------------------------------- 瀏覽器輔助
let browser;
const VIEWPORTS = [{ label: '320px', width: 320, height: 720, dsf: 1 }, { label: '200% 縮放（1280 寬 → 640 CSS px）', width: 640, height: 800, dsf: 2 }];
async function openPage(screen, hash, viewport) {
  const context = await browser.newContext({ viewport: viewport ? { width: viewport.width, height: viewport.height } : { width: 1280, height: 900 }, deviceScaleFactor: viewport ? viewport.dsf : 1 });
  await context.addInitScript(() => { window.__blobs = []; const original = URL.createObjectURL; URL.createObjectURL = function (blob) { window.__blobs.push(blob); return original.call(URL, blob); }; window.__prints = 0; window.print = () => { window.__prints++; }; });
  const page = await context.newPage();
  page.on('pageerror', e => { (consoleErrors.get(screen) || consoleErrors.set(screen, []).get(screen)).push('pageerror: ' + e.message); });
  page.on('console', m => { if (m.type() === 'error') (consoleErrors.get(screen) || consoleErrors.set(screen, []).get(screen)).push('console: ' + m.text()); });
  await page.goto(`http://127.0.0.1:${server.address().port}/${hash}`, { waitUntil: 'domcontentloaded' });
  return page;
}
const waitResults = page => page.waitForSelector('#backup-item-results [role=tablist]', { timeout: 30000 });
async function openWorkbench(screen, hash, viewport) { const page = await openPage(screen, hash || '#jobs?filter=backup', viewport); await waitResults(page); return page; }
async function openTarget(screen, viewport) {
  const page = await openPage(screen, '#wizard', viewport);
  await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state && window.WsmConsole.state.wizard && window.WsmConsole.state.wizard.currentStep === 'handoff');
  await page.evaluate(() => { const c = window.WsmConsole; c.state.wizardRuntimeProjection = null; c.state.wizardRuntimeIdentity = ''; c.renderWizard(c.state.wizard); c.renderWizard(c.state.wizard); });
  await page.waitForSelector('.wizard-runtime-target h2', { timeout: 30000 });
  return page;
}
async function openManager(screen, panel, viewport) {
  const page = await openPage(screen, '#wizard', viewport);
  await page.waitForFunction(() => window.WsmConsole?.state?.wizard?.currentStep);
  await page.locator(`[data-b5-panel="${panel}"]`).waitFor();
  return page;
}
// 重新開啟頁面：突變 reopen 只在這一刻讓替身端把已確認的狀態清空。
async function reopenPage(page) { S.reopenPending = true; await page.reload({ waitUntil: 'domcontentloaded' }); }
const settle = (page, ms = 300) => page.waitForTimeout(ms);

// ---------------------------------------------------------------------------------------------------- 鍵盤輔助
const ACTIVE_JS = () => {
  const a = document.activeElement; if (!a || a === document.body || a === document.documentElement) return null;
  const cs = getComputedStyle(a), r = a.getBoundingClientRect();
  return { tag: a.tagName.toLowerCase(), id: a.id, name: (a.getAttribute('aria-label') || a.textContent || a.value || a.placeholder || '').trim().replace(/\s+/g, ' ').slice(0, 50), connected: a.isConnected, ring: (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) >= 2) || cs.boxShadow !== 'none', visible: r.width > 0 && r.height > 0 };
};
const active = page => page.evaluate(ACTIVE_JS);
async function resetFocus(page) { await page.evaluate(() => { window.scrollTo(0, 0); const s = document.createElement('span'); s.tabIndex = -1; document.body.prepend(s); s.focus(); s.remove(); }); }
// 以 Tab（或 Shift+Tab）走到符合 selector 的元素；途中不得掉到 body；抵達時焦點環必須可見。
async function tabTo(page, screen, selector, options) {
  const opt = options || {}, max = opt.max || 120, key = opt.back ? 'Shift+Tab' : 'Tab';
  for (let i = 1; i <= max; i++) {
    await page.keyboard.press(key);
    const hit = await page.evaluate(sel => { const a = document.activeElement; return !!a && a !== document.body && a.matches(sel); }, selector);
    if (hit) { const a = await active(page); ok(screen, a.ring && a.visible, `focus ring is visible on ${selector} (${a.name})`); return i; }
  }
  assert.fail(`[${screen}] ${selector} is not reachable with ${key} within ${max} presses`);
}
async function tabToText(page, screen, tag, pattern, options) {
  const opt = options || {}, max = opt.max || 120, key = opt.back ? 'Shift+Tab' : 'Tab', source = pattern.source;
  for (let i = 1; i <= max; i++) {
    await page.keyboard.press(key);
    const hit = await page.evaluate(([t, s]) => { const a = document.activeElement; return !!a && a !== document.body && a.tagName.toLowerCase() === t && new RegExp(s).test(((a.getAttribute('aria-label') || '') + ' ' + a.textContent).trim()); }, [tag, source]);
    if (hit) { const a = await active(page); ok(screen, a.ring && a.visible, `focus ring is visible on ${tag} /${source}/ (${a.name})`); return i; }
  }
  assert.fail(`[${screen}] ${tag} /${source}/ is not reachable with ${key} within ${max} presses`);
}
const idForLabel = (page, scope, text) => page.evaluate(([s, t]) => { const root = document.querySelector(s); const label = [...root.querySelectorAll('label')].find(l => l.firstChild && l.textContent.trim().startsWith(t)); return label ? label.htmlFor : ''; }, [scope, text]);
const mark = page => page.evaluate(() => { window.__focusMark = document.activeElement; });
const stillFocused = (page) => page.evaluate(() => !!window.__focusMark && document.activeElement === window.__focusMark && window.__focusMark.isConnected);
// 鍵盤焦點守門（N9e2 起預設 strict）：操作完成後焦點不得掉到 body。
async function focusDefect(page, screen, id, where, message) {
  const a = await active(page);
  if (a !== null && a.connected) { ok(screen, true, `focus is not lost to the page body: ${message}`); return; }
  assert.fail(`[${screen}] ${id}: focus fell to the page body ${message} (${where})`);
}
const focusNotLost = async (page, screen, message) => { const a = await active(page); ok(screen, a !== null && a.connected, `focus is not lost to the page body: ${message}`); };
function parseCsv(text) {
  const rows = []; let row = [], cell = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) { if (ch === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else quoted = false; } else cell += ch; }
    else if (ch === '"') quoted = true; else if (ch === ',') { row.push(cell); cell = ''; }
    else if (ch === '\r' && text[i + 1] === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; i++; } else cell += ch;
  }
  return rows;
}
async function takeCsv(page) {
  const bytes = await page.evaluate(async () => { const blob = window.__blobs.pop(); return blob ? Array.from(new Uint8Array(await blob.arrayBuffer())) : null; });
  assert.ok(bytes, 'a CSV blob must have been produced');
  const buffer = Buffer.from(bytes); assert.deepEqual([...buffer.subarray(0, 3)], [0xEF, 0xBB, 0xBF]);
  return parseCsv(buffer.subarray(3).toString('utf8'));
}

// ---------------------------------------------------------------------------------------------------- 版面輔助
// 整頁不得水平溢位；表格以外的可見元素不得超出視窗；關鍵元素在視窗內；非表格容器不得裁切內容（overflow hidden／省略號）。
async function layout(page, screen, label, keys) {
  const r = await page.evaluate(selectors => {
    const vw = document.documentElement.clientWidth, visible = n => { const cs = getComputedStyle(n); if (cs.display === 'none' || cs.visibility === 'hidden') return false; const b = n.getBoundingClientRect(); return b.width > 0 || b.height > 0; };
    const describe = n => `${n.tagName.toLowerCase()}${n.id ? '#' + n.id : ''}${typeof n.className === 'string' && n.className ? '.' + n.className.trim().split(/\s+/).join('.') : ''}`;
    const all = [...document.querySelectorAll('body *')].filter(n => !n.closest('[hidden],details:not([open]),dialog:not([open])') && visible(n) && !n.closest('.table-wrap') && !n.classList.contains('sr-only'));
    const outside = all.filter(n => { const b = n.getBoundingClientRect(); return b.right > vw + 1 || b.left < -1; }).slice(0, 6).map(n => `${describe(n)}:${Math.round(n.getBoundingClientRect().left)}..${Math.round(n.getBoundingClientRect().right)}`);
    const clipped = all.filter(n => { const cs = getComputedStyle(n); return (['hidden', 'clip'].includes(cs.overflowX) || cs.textOverflow === 'ellipsis') && n.scrollWidth > n.clientWidth + 1 && n.clientWidth > 0 && n.tagName !== 'BODY' && n.tagName !== 'HTML'; }).slice(0, 6).map(describe);
    const wraps = [...document.querySelectorAll('.table-wrap')].filter(visible);
    const wrapBad = wraps.filter(w => { const b = w.getBoundingClientRect(), cs = getComputedStyle(w); return b.right > vw + 1 || b.left < -1 || !['auto', 'scroll'].includes(cs.overflowX); }).map(describe);
    const keyBad = selectors.map(s => { const n = document.querySelector(s); if (!n || !visible(n)) return `${s}:missing`; const b = n.getBoundingClientRect(); return b.left < -1 || b.right > vw + 1 ? `${s}:out(${Math.round(b.left)}..${Math.round(b.right)} of ${vw})` : ''; }).filter(Boolean);
    return { vw, scroll: document.documentElement.scrollWidth, bodyScroll: document.body.scrollWidth, outside, clipped, wrapBad, keyBad, tables: wraps.length };
  }, keys || []);
  ok(screen, r.scroll <= r.vw && r.bodyScroll <= r.vw + 1, `${label}: no page-level horizontal overflow (scroll ${r.scroll} > ${r.vw}) ${JSON.stringify(r.outside)}`);
  eq(screen, r.outside, [], `${label}: nothing outside the table regions leaves the viewport`);
  eq(screen, r.clipped, [], `${label}: no container clips its content`);
  eq(screen, r.wrapBad, [], `${label}: table regions stay inside the viewport and scroll instead of clipping`);
  eq(screen, r.keyBad, [], `${label}: key elements are inside the viewport`);
}
async function shot(page, name) { await page.screenshot({ path: path.join(screens, name), fullPage: true }); }

// ---------------------------------------------------------------------------------------------------- 各畫面
async function screenBackupTabs(mixed) {
  const screen = '備份結果三分頁（工作台）', rows = mixed.results.Rows, backedRows = rows.filter(r => r.Status === 'BackedUp'), pendingRows = rows.filter(r => r.Status === 'NotBackedUp');
  useWorkbench(mixed.results);
  const page = await openWorkbench(screen);
  const pending = page.locator('#backup-panel-pending'), backed = page.locator('#backup-panel-backed'), softwarePanel = page.locator('#backup-panel-software');
  // 分頁列：Tab 進入已選分頁，方向鍵／Home／End 切換並保持焦點在分頁列。
  await resetFocus(page); await tabTo(page, screen, '#backup-tab-backed');
  eq(screen, await page.locator('#backup-tab-backed').getAttribute('aria-selected'), 'true', 'the first tab is selected');
  await page.keyboard.press('ArrowRight');
  eq(screen, [await page.locator('#backup-tab-pending').getAttribute('aria-selected'), await pending.isVisible(), await backed.isVisible()], ['true', true, false], 'ArrowRight selects the pending tab');
  ok(screen, (await active(page)).id === 'backup-tab-pending', 'focus follows the selected tab');
  await page.keyboard.press('ArrowRight'); ok(screen, await softwarePanel.isVisible() && (await active(page)).id === 'backup-tab-software', 'ArrowRight reaches the software tab');
  await page.keyboard.press('Home'); ok(screen, await backed.isVisible() && (await active(page)).id === 'backup-tab-backed', 'Home returns to the first tab');
  await page.keyboard.press('End'); ok(screen, await softwarePanel.isVisible() && (await active(page)).id === 'backup-tab-software', 'End reaches the last tab');
  await page.keyboard.press('ArrowLeft'); await page.keyboard.press('ArrowLeft'); ok(screen, await backed.isVisible(), 'ArrowLeft wraps back to the backed tab');
  // 已備份分頁：篩選（方向鍵）→ 搜尋（鍵入）→ 下鑽（Enter／Space）→ CSV（Enter）。
  const status = backed.locator('[role=status][aria-atomic=true]');
  eq(screen, await status.innerText(), `顯示 ${backedRows.length}／共 ${backedRows.length} 筆`, 'the backed tab starts unfiltered');
  await tabTo(page, screen, '#' + await idForLabel(page, '#backup-panel-backed', '搜尋名稱或位置')); await mark(page);
  await page.keyboard.type('item-01');
  ok(screen, (await status.innerText()) !== `顯示 ${backedRows.length}／共 ${backedRows.length} 筆`, 'typing narrows the list');
  ok(screen, await stillFocused(page), 'typing in the search box keeps focus in the box');
  await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
  eq(screen, await status.innerText(), `顯示 ${backedRows.length}／共 ${backedRows.length} 筆`, 'clearing the search restores the list');
  await tabTo(page, screen, '#' + await idForLabel(page, '#backup-panel-backed', '類型')); await mark(page);
  await page.keyboard.press('ArrowDown');
  ok(screen, (await status.innerText()) !== `顯示 ${backedRows.length}／共 ${backedRows.length} 筆`, 'ArrowDown on the type filter narrows the list');
  ok(screen, await stillFocused(page), 'the filter keeps keyboard focus after the table is redrawn');
  await page.keyboard.press('ArrowUp'); eq(screen, await status.innerText(), `顯示 ${backedRows.length}／共 ${backedRows.length} 筆`, 'ArrowUp restores the unfiltered list');
  await tabTo(page, screen, '#' + await idForLabel(page, '#backup-panel-backed', '獨立副本'));
  // 匯出 CSV（Enter）
  await tabToText(page, screen, 'button', /^\s*匯出 CSV/); await mark(page);
  await page.evaluate(() => { window.__blobs = []; }); await page.keyboard.press('Enter');
  const csv = await takeCsv(page);
  eq(screen, csv.length - 1, backedRows.length, 'Enter on the CSV button exports every backed row'); ok(screen, await stillFocused(page), 'focus stays on the CSV button');
  // 下鑽
  await tabTo(page, screen, '#backup-panel-backed button.backup-expand'); await mark(page);
  eq(screen, await page.evaluate(() => document.activeElement.getAttribute('aria-expanded')), 'false', 'the drill-down button starts collapsed');
  await page.keyboard.press('Enter');
  await backed.locator('.backup-detail table').first().waitFor();
  eq(screen, await page.evaluate(() => document.activeElement.getAttribute('aria-expanded')), 'true', 'Enter expands the file list'); ok(screen, await stillFocused(page), 'focus stays on the drill-down button while the list loads');
  await page.keyboard.press('Space');
  eq(screen, await page.evaluate(() => document.activeElement.getAttribute('aria-expanded')), 'false', 'Space collapses the file list'); ok(screen, await stillFocused(page), 'focus stays after collapsing');
  await page.keyboard.press('Enter'); await backed.locator('.backup-detail table').first().waitFor();
  // 明細內的分頁按鈕
  await tabToText(page, screen, 'button', /^下一頁$/, { max: 60 });
  await page.keyboard.press('Enter'); await settle(page, 400);
  await focusNotLost(page, screen, 'after paging the file list with Enter');
  // 回到分頁列，切到「未備份」
  await tabTo(page, screen, '#backup-tab-backed', { back: true, max: 200 });
  await page.keyboard.press('ArrowRight'); await pending.waitFor({ state: 'visible' });
  const pstatus = pending.locator('[role=status][aria-atomic=true]').first();
  eq(screen, await pstatus.innerText(), `顯示 ${pendingRows.length}／共 ${pendingRows.length} 筆`, 'the pending tab lists every not-backed item');
  await tabTo(page, screen, '#' + await idForLabel(page, '#backup-panel-pending', '原因')); await mark(page);
  await page.keyboard.press('ArrowDown');
  ok(screen, (await pstatus.innerText()) !== `顯示 ${pendingRows.length}／共 ${pendingRows.length} 筆` && await stillFocused(page), 'the reason filter narrows the list and keeps focus');
  await page.keyboard.press('ArrowUp');
  // 重新整理後維持同一分頁與篩選（狀態在網址 hash）
  await page.keyboard.press('ArrowDown'); const hashBefore = await page.evaluate(() => location.hash);
  await page.reload({ waitUntil: 'domcontentloaded' }); await waitResults(page);
  eq(screen, [await page.locator('#backup-tab-pending').getAttribute('aria-selected'), await page.evaluate(() => location.hash)], ['true', hashBefore], 'a reload keeps the tab and the filter');
  await resetFocus(page); await tabTo(page, screen, '#backup-tab-pending'); await page.keyboard.press('End'); ok(screen, await softwarePanel.isVisible(), 'the software tab is reachable from the keyboard');
  await shot(page, 'n9e-backup-tabs-1280.png');
  await page.context().close();
  // 版面：320 與 200%
  for (const vp of VIEWPORTS) {
    const narrow = await openWorkbench(screen, '#jobs?filter=backup', vp);
    for (const tab of ['backed', 'pending', 'software']) {
      await narrow.locator('#backup-tab-' + tab).click();
      if (tab === 'backed') { await narrow.locator('#backup-panel-backed button.backup-expand').first().click(); await narrow.locator('#backup-panel-backed .backup-detail table').first().waitFor(); }
      await layout(narrow, screen, `${vp.label} ${tab}`, ['#backup-tab-backed', '#backup-tab-pending', '#backup-tab-software', `#backup-panel-${tab}`]);
      await shot(narrow, `n9e-backup-${tab}-${vp.width}.png`);
    }
    await narrow.context().close();
  }
}

async function screenSoftwareTab(normal) {
  const screen = '安裝軟體分頁（工作台）', rows = normal.results.Software.SoftwareRows, required = rows.filter(r => r.RequiredBySelectedWorkload === true);
  useWorkbench(normal.results);
  const page = await openWorkbench(screen);
  await resetFocus(page); await tabTo(page, screen, '#backup-tab-backed'); await page.keyboard.press('End');
  const panel = page.locator('#backup-panel-software'), toolbar = panel.locator('.backup-toolbar:has(#backup-software-search)'), status = toolbar.locator('[role=status][aria-atomic=true]');
  eq(screen, await status.innerText(), `顯示 ${rows.length}／共 ${rows.length} 筆`, 'the software tab opens with every row');
  const groupId = await idForLabel(page, '#backup-panel-software', '分組');
  await tabTo(page, screen, '#' + groupId); await mark(page);
  await page.keyboard.press('ArrowDown');
  const afterGroup = await status.innerText();
  ok(screen, afterGroup === `顯示 ${required.length}／共 ${rows.length} 筆` || afterGroup === `顯示 ${rows.length - required.length}／共 ${rows.length} 筆`, `ArrowDown on the group filter selects one group (${afterGroup})`);
  ok(screen, await stillFocused(page), 'the group filter keeps focus after the table is redrawn');
  await page.keyboard.press('ArrowDown'); ok(screen, (await status.innerText()) !== afterGroup, 'the second ArrowDown selects the other group'); await page.keyboard.press('ArrowUp'); await page.keyboard.press('ArrowUp');
  eq(screen, await status.innerText(), `顯示 ${rows.length}／共 ${rows.length} 筆`, 'the group filter can be cleared from the keyboard');
  await tabTo(page, screen, '#' + await idForLabel(page, '#backup-panel-software', '決策')); await page.keyboard.press('ArrowDown'); ok(screen, (await status.innerText()) !== `顯示 ${rows.length}／共 ${rows.length} 筆`, 'the decision filter works from the keyboard'); await page.keyboard.press('ArrowUp');
  await tabTo(page, screen, '#' + await idForLabel(page, '#backup-panel-software', '搜尋名稱或位置')); await page.keyboard.type('tool 0');
  ok(screen, (await status.innerText()) !== `顯示 ${rows.length}／共 ${rows.length} 筆`, 'typing narrows the software list'); await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
  await tabToText(page, screen, 'button', /^\s*匯出 CSV/); await page.evaluate(() => { window.__blobs = []; }); await mark(page); await page.keyboard.press('Enter');
  eq(screen, (await takeCsv(page)).length - 1, rows.length, 'Enter on the CSV button exports every software row'); ok(screen, await stillFocused(page), 'focus stays on the CSV button');
  await tabToText(page, screen, 'button', /列印新機安裝檢查表/, { max: 200 }); await mark(page);
  await page.keyboard.press('Enter');
  eq(screen, await page.evaluate(() => window.__prints), 1, 'Enter on the print button opens the browser print');
  ok(screen, await page.evaluate(() => document.body.classList.contains('printing-checklist')), 'the temporary checklist is on screen for printing');
  await page.evaluate(() => window.dispatchEvent(new Event('afterprint'))); await focusNotLost(page, screen, 'after the print checklist is removed');
  await shot(page, 'n9e-software-1280.png');
  await page.context().close();
  for (const vp of VIEWPORTS) {
    const narrow = await openWorkbench(screen, '#jobs?filter=backup&tab=software', vp);
    await narrow.locator('#backup-tab-software').click();
    await layout(narrow, screen, vp.label, ['#backup-panel-software', '#backup-software-search', '#backup-panel-software select']);
    const printButton = narrow.locator('#backup-panel-software').getByRole('button', { name: '列印新機安裝檢查表' }); await printButton.scrollIntoViewIfNeeded();
    const box = await printButton.boundingBox(); ok(screen, box.x >= 0 && box.x + box.width <= vp.width + 1, `${vp.label}: the print button is inside the viewport`);
    await shot(narrow, `n9e-software-${vp.width}.png`); await narrow.context().close();
  }
}

async function screenTarget(partial, complete) {
  const screen = 'Target 新機安裝檢查', base = { status: 'NeedsTargetDecision', plan: { hash: 'a'.repeat(64) }, package: { ManifestHash: 'a'.repeat(64) }, inventory: { SHA256: 'b'.repeat(64) }, comparison: { Status: 'Imported' }, decision: null, restorePreview: null, restoreResult: null, itemOptions: [], mechanicalValidation: { available: false, status: 'Locked' }, businessAcceptance: { available: false, status: 'NotAccepted' }, activation: { available: false, status: 'Locked' }, issues: [] };
  const actions = [{ id: 'CreateTargetDecisionReceipt', available: true, reason: 'Fixture', defaults: { Workspace: root, PairId: pairId }, missing: [] }];
  useTarget(Object.assign({}, base, { softwareCheck: partial }), actions);
  const page = await openTarget(screen);
  const section = page.locator('#software-check'); await section.locator('table').first().waitFor();
  const status = section.locator('.backup-toolbar:has(#target-software-search) [role=status][aria-atomic=true]');
  eq(screen, await status.innerText(), `顯示 ${partial.Rows.length}／共 ${partial.Rows.length} 筆`, 'the check lists every comparison row');
  await resetFocus(page);
  await tabTo(page, screen, '#' + await idForLabel(page, '#software-check', '新機狀態'), { max: 200 }); await mark(page);
  await page.keyboard.press('ArrowDown');
  ok(screen, (await status.innerText()) !== `顯示 ${partial.Rows.length}／共 ${partial.Rows.length} 筆`, 'ArrowDown on the state filter narrows the list'); ok(screen, await stillFocused(page), 'the state filter keeps focus');
  await page.keyboard.press('ArrowUp');
  await tabTo(page, screen, '#target-software-search'); await page.keyboard.type('alpha'); eq(screen, await status.innerText(), `顯示 1／共 ${partial.Rows.length} 筆`, 'typing narrows to one row');
  await page.keyboard.press('Control+A'); await page.keyboard.press('Backspace');
  await tabToText(page, screen, 'button', /^\s*匯出 CSV/); await page.evaluate(() => { window.__blobs = []; }); await mark(page); await page.keyboard.press('Enter');
  eq(screen, (await takeCsv(page)).length - 1, partial.Rows.length, 'Enter on the CSV button exports every comparison row'); ok(screen, await stillFocused(page), 'focus stays on the CSV button');
  await tabToText(page, screen, 'button', /列印新機安裝檢查表/, { max: 60 }); await mark(page); await page.keyboard.press('Enter');
  eq(screen, await page.evaluate(() => window.__prints), 1, 'Enter on the print button opens the browser print');
  await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
  await shot(page, 'n9e-target-1280.png'); await page.context().close();
  for (const [name, check] of [['partial', partial], ['complete', complete]]) {
    useTarget(Object.assign({}, base, { softwareCheck: check }), actions);
    for (const vp of VIEWPORTS) {
      const narrow = await openTarget(screen, vp); await narrow.locator('#software-check table').first().waitFor();
      await layout(narrow, screen, `${vp.label} ${name}`, ['#software-check', '#target-software-search']);
      const printButton = narrow.locator('#software-check').getByRole('button', { name: '列印新機安裝檢查表' }); await printButton.scrollIntoViewIfNeeded();
      const box = await printButton.boundingBox(); ok(screen, box.x >= 0 && box.x + box.width <= vp.width + 1, `${vp.label} ${name}: the print button is inside the viewport`);
      await shot(narrow, `n9e-target-${name}-${vp.width}.png`); await narrow.context().close();
    }
  }
}

async function screenExcluded(mixed) {
  const screen = '排除區域表', regions = mixed.results.ExcludedRegions, withContents = regions.filter(r => r.Contents);
  useWorkbench(mixed.results);
  const page = await openWorkbench(screen, '#jobs?filter=backup&tab=pending');
  const excluded = page.locator('#backup-panel-pending .backup-excluded'), status = excluded.locator('[role=status][aria-atomic=true]');
  eq(screen, await status.innerText(), `顯示 ${regions.length}／共 ${regions.length} 筆`, 'the region table lists every region');
  const completeness = page.locator('#backup-completeness');
  ok(screen, await completeness.getAttribute('data-status') === 'ManualItems' && (await completeness.innerText()).includes('有人工處置項'), 'overall completeness names the manual items (N9d)');
  await resetFocus(page);
  await tabTo(page, screen, '#backup-panel-pending .backup-excluded .backup-region-toggle', { max: 250 }); await mark(page);
  eq(screen, await page.evaluate(() => document.activeElement.getAttribute('aria-expanded')), 'false', 'regions start collapsed');
  await page.keyboard.press('Enter');
  eq(screen, await page.evaluate(() => document.activeElement.getAttribute('aria-expanded')), 'true', 'Enter expands the first region'); ok(screen, await stillFocused(page), 'focus stays on the expander');
  const detail = page.locator('#' + await page.evaluate(() => document.activeElement.getAttribute('aria-controls')));
  ok(screen, await detail.isVisible() && (await detail.innerText()).includes('疑似業務資料'), 'the expanded detail shows the classification (suspected business data)');
  await page.keyboard.press('Space'); eq(screen, await page.evaluate(() => document.activeElement.getAttribute('aria-expanded')), 'false', 'Space collapses the region'); ok(screen, await stillFocused(page), 'focus stays after collapsing');
  await page.keyboard.press('Enter');
  const nextTarget = await tabTo(page, screen, '#backup-panel-pending .backup-excluded .backup-region-toggle'); ok(screen, nextTarget >= 1, 'Tab reaches the second expander');
  await page.keyboard.press('Enter'); ok(screen, (await excluded.locator('tr.backup-detail-row:not([hidden])').count()) === 2, 'both classified install roots can be expanded from the keyboard');
  const regionSelect = '#' + await idForLabel(page, '#backup-panel-pending .backup-excluded', '區域類別');
  await tabTo(page, screen, regionSelect, { back: true, max: 200 }); await mark(page);
  await page.keyboard.press('ArrowDown'); ok(screen, (await status.innerText()) !== `顯示 ${regions.length}／共 ${regions.length} 筆` && await stillFocused(page), 'the region category filter narrows the table and keeps focus');
  await page.keyboard.press('ArrowUp');
  await tabToText(page, screen, 'button', /^\s*匯出 CSV/, { max: 20 }); await page.evaluate(() => { window.__blobs = []; }); await page.keyboard.press('Enter');
  const csv = await takeCsv(page); eq(screen, csv[0], ['區域', '原因', '下一步', '原因碼'], 'the region CSV keeps its header'); eq(screen, csv.length - 1, regions.length, 'the region CSV holds every region and no expander text');
  await shot(page, 'n9e-excluded-1280.png'); await page.context().close();
  for (const vp of VIEWPORTS) {
    const narrow = await openWorkbench(screen, '#jobs?filter=backup&tab=pending', vp);
    const toggles = narrow.locator('#backup-panel-pending .backup-excluded .backup-region-toggle'); eq(screen, await toggles.count(), withContents.length, `${vp.label}: expanders are present`);
    for (let i = 0; i < withContents.length; i++) await toggles.nth(i).click();
    await narrow.locator('#backup-panel-pending .backup-excluded tr.backup-detail-row:not([hidden])').first().scrollIntoViewIfNeeded();
    await layout(narrow, screen, `${vp.label} expanded`, ['#backup-completeness', '#backup-panel-pending .backup-excluded']);
    await shot(narrow, `n9e-excluded-${vp.width}.png`); await narrow.context().close();
  }
  // 離線報告（file://）同一張排除區域表
  for (const vp of [{ width: 1280, height: 900, dsf: 1, label: '1280px' }, ...VIEWPORTS]) {
    const context = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.dsf }), report = await context.newPage();
    report.on('pageerror', e => (consoleErrors.get(screen) || consoleErrors.set(screen, []).get(screen)).push('pageerror: ' + e.message)); report.on('console', m => { if (m.type() === 'error') (consoleErrors.get(screen) || consoleErrors.set(screen, []).get(screen)).push('console: ' + m.text()); });
    await report.goto(fileUrl(mixed.report)); await report.waitForSelector('[role=tablist]'); await report.locator('[role=tab]').nth(1).click();
    const toggles = report.locator('#pending .region-toggle');
    if (vp.width === 1280) {
      await resetFocus(report); await tabTo(report, screen, '#pending .region-toggle', { max: 120 });
      await report.keyboard.press('Enter'); eq(screen, await report.evaluate(() => document.activeElement.getAttribute('aria-expanded')), 'true', 'report: Enter expands the region from the keyboard');
    } else { for (let i = 0; i < await toggles.count(); i++) await toggles.nth(i).click(); }
    await layout(report, screen, `report ${vp.label}`, ['#completeness', '#pending']);
    await context.close();
  }
}

async function screenC2() {
  const screen = 'C2 軟體處置審閱';
  resetManager();
  const page = await openManager(screen, 'c2'); const panel = page.locator('[data-b5-panel="c2"]');
  await panel.locator('.b5-table tbody tr').first().waitFor();
  eq(screen, await panel.locator('.b5-incomplete h3').innerText(), '尚未決定的軟體：3 筆', 'three rows await a decision');
  // 篩選（鍵盤）
  await resetFocus(page); await tabTo(page, screen, '#b5-c2-state', { max: 200 }); await mark(page);
  await page.keyboard.press('ArrowDown'); eq(screen, await panel.locator('.b5-table tbody tr').count(), 3, 'the state filter (ArrowDown) shows the three undecided rows'); ok(screen, await stillFocused(page), 'the state filter keeps focus');
  await page.keyboard.press('ArrowUp'); eq(screen, await panel.locator('.b5-table tbody tr').count(), 4, 'ArrowUp shows every row again');
  // 勾選一般軟體 → 批次欄位
  await tabTo(page, screen, 'input[aria-label="選取 報表小工具"]'); await mark(page); await page.keyboard.press('Space');
  ok(screen, await panel.getByRole('checkbox', { name: '選取 報表小工具' }).isChecked(), 'Space ticks the row'); ok(screen, await stillFocused(page), 'focus stays on the ticked checkbox after the batch box is redrawn');
  eq(screen, await panel.locator('.b5-batch .b5-summary').innerText(), '已選 1 筆軟體。', 'the batch box counts the selection');
  await tabTo(page, screen, '#b5-c2-disposition'); await page.keyboard.press('ArrowDown');
  eq(screen, await panel.locator('#b5-c2-disposition').inputValue() !== '', true, 'ArrowDown picks a disposition');
  await tabTo(page, screen, '#b5-c2-owner'); await page.keyboard.type('應用程式負責人');
  await tabTo(page, screen, '#b5-c2-reason'); await page.keyboard.type('需要重新安裝');
  await tabTo(page, screen, '#b5-c2-evidence'); await page.keyboard.type('change:F1-1');
  await tabToText(page, screen, 'button', /套用到已選項目（暫存）/); await page.keyboard.press('Enter');
  eq(screen, (await panel.locator('.b5-footer .b5-summary').innerText()), '待送出的處置：1 筆。', 'Enter stages the disposition as a draft');
  const afterApply = await active(page); ok(screen, afterApply !== null && /套用到已選項目/.test(afterApply.name), 'focus is restored to the apply button after the panel repaints');
  // 送出：開啟確認對話框 → Esc → 再開 → 空白鍵勾 Ack → Tab → Enter
  await tabToText(page, screen, 'button', /檢視確認摘要並送出/); await page.keyboard.press('Enter'); await page.waitForSelector('#b5-confirm-dialog[open]');
  ok(screen, (await active(page)).id === 'b5-confirm-ack', 'the dialog puts focus on the acknowledgement'); await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.querySelector('#b5-confirm-dialog[open]'));
  eq(screen, count('SoftwareDispositionReviewSubmit'), 0, 'Esc sends nothing'); ok(screen, /檢視確認摘要並送出/.test((await active(page) || {}).name || ''), 'Esc returns focus to the opener');
  await page.keyboard.press('Enter'); await page.waitForSelector('#b5-confirm-dialog[open]'); await page.keyboard.press('Space');
  ok(screen, !(await page.locator('#b5-confirm-dialog [data-b5-confirm="accept"]').isDisabled()), 'Space on the acknowledgement enables the confirm button');
  await page.keyboard.press('Tab'); eq(screen, (await active(page)).name, '確認送出', 'Tab reaches the confirm button'); await page.keyboard.press('Enter');
  await panel.getByText(/完成：已套用 1 筆處置/).waitFor();
  eq(screen, count('SoftwareDispositionReviewSubmit'), 1, 'exactly one submission was sent'); eq(screen, S.submissions[0].args.Decisions.map(d => [d.SoftwareId, d.Disposition !== '']), [['sw-b', true]], 'only the ticked row was submitted');
  await focusDefect(page, screen, 'F1-FOCUS-C2-SUBMIT', 'src/ui/console.js:2613 submit.disabled while busy, then :2619 b5SubmitC2 reloads the panel', 'after the keyboard-confirmed submit finishes');
  // 重開：已確認的項目維持，不重問
  await shot(page, 'n9e-c2-1280.png');
  const before = S.submissions.length;
  await reopenPage(page); await panel.locator('.b5-table tbody tr').first().waitFor();
  eq(screen, await panel.locator('.b5-incomplete h3').innerText(), '尚未決定的軟體：2 筆', 'after a reload the confirmed row stays confirmed and only two rows await a decision');
  ok(screen, (await panel.locator('.b5-table tbody tr').filter({ hasText: '報表小工具' }).innerText()).includes('已審閱'), 'the reloaded row still reads as reviewed');
  eq(screen, S.submissions.length, before, 'reopening the page writes nothing and re-asks nothing');
  // 重新盤點：只有 sw-b 的證據變動，sw-d 維持已審閱
  S.decisionRevision++; S.revision++; S.c2Rows.find(r => r.SoftwareId === 'sw-b').DecisionState = 'Stale';
  await reopenPage(page); await panel.locator('.b5-table tbody tr').first().waitFor();
  const undecided = await panel.locator('.b5-incomplete li').allInnerTexts();
  ok(screen, undecided.some(t => t.includes('報表小工具') && t.includes('證據已變更')), 're-inventory flags only the changed row for re-review');
  ok(screen, !undecided.some(t => t.includes('排程輔助程式')), 'the untouched confirmed row (排程輔助程式) is not asked again');
  eq(screen, await panel.locator('.b5-incomplete h3').innerText(), '尚未決定的軟體：3 筆', 'two never-reviewed rows plus the one changed row');
  // 新草稿：暫存一筆 → 重新盤點（另一筆變動）→ 鍵盤按「重新讀取」→ 草稿仍在
  await resetFocus(page); await tabTo(page, screen, 'input[aria-label="選取 訂單系統執行階段"]', { max: 200 }); await page.keyboard.press('Space');
  await tabTo(page, screen, '#b5-c2-disposition'); await page.keyboard.press('ArrowDown'); await tabTo(page, screen, '#b5-c2-owner'); await page.keyboard.type('o'); await tabTo(page, screen, '#b5-c2-reason'); await page.keyboard.type('r'); await tabTo(page, screen, '#b5-c2-evidence'); await page.keyboard.type('e');
  await tabToText(page, screen, 'button', /套用到已選項目（暫存）/); await page.keyboard.press('Enter');
  eq(screen, (await panel.locator('.b5-footer .b5-summary').innerText()), '待送出的處置：1 筆。', 'a new draft is staged');
  S.decisionRevision++; S.revision++; S.c2Rows.find(r => r.SoftwareId === 'sw-d').DecisionState = 'Stale';
  await tabToText(page, screen, 'button', /^重新讀取$/, { back: true, max: 80 }).catch(async () => { await tabToText(page, screen, 'button', /^重新讀取$/, { max: 80 }); }); await page.keyboard.press('Enter');
  await page.waitForFunction(() => window.WsmConsole.b5.c2.loading === false && window.WsmConsole.b5.c2.data.Rows.find(r => r.SoftwareId === 'sw-d').DecisionState === 'Stale');
  eq(screen, (await panel.locator('.b5-footer .b5-summary').innerText()), '待送出的處置：1 筆。', 'the new draft survives a re-read after the inventory changed');
  ok(screen, (await panel.locator('.b5-table tbody tr').filter({ hasText: '訂單系統執行階段' }).innerText()).includes('➜'), 'the staged row still shows its pending disposition');
  eq(screen, count('SoftwareDispositionReviewSubmit'), 1, 'the re-read did not submit anything'); await focusDefect(page, screen, 'F1-FOCUS-C2-REREAD', 'src/ui/console.js:2535 b5LoadC2 sets loading and repaints the panel without the re-read button', 'after the keyboard re-read finishes');
  await page.context().close();
  for (const vp of VIEWPORTS) {
    resetManager(); const narrow = await openManager(screen, 'c2', vp); await narrow.locator('[data-b5-panel="c2"] .b5-table tbody tr').first().waitFor();
    await narrow.getByRole('checkbox', { name: '選取 Microsoft SQL Server Database Engine' }).check(); await narrow.locator('#b5-c2-disposition').selectOption('NotNeeded');
    await narrow.locator('#b5-c2-owner').fill('o'); await narrow.locator('#b5-c2-reason').fill('r'); await narrow.locator('#b5-c2-evidence').fill('e'); await narrow.getByRole('button', { name: '套用到已選項目（暫存）' }).click();
    await layout(narrow, screen, `${vp.label} list`, ['[data-b5-panel="c2"]', '#b5-c2-filter', '#b5-c2-disposition', '#b5-c2-owner']);
    await narrow.getByRole('button', { name: '檢視確認摘要並送出' }).click(); await narrow.waitForSelector('#b5-confirm-dialog[open]');
    const dialog = await narrow.locator('#b5-confirm-dialog').boundingBox(); ok(screen, dialog.x >= 0 && dialog.x + dialog.width <= vp.width + 1, `${vp.label}: the confirmation dialog is inside the viewport`);
    await layout(narrow, screen, `${vp.label} dialog`, ['#b5-confirm-dialog [data-b5-confirm="accept"]']);
    await shot(narrow, `n9e-c2-${vp.width}.png`); await narrow.context().close();
  }
}

async function screenD2() {
  const screen = 'D2 候選確認與對應審閱';
  resetManager();
  const page = await openManager(screen, 'd2'); const panel = page.locator('[data-b5-panel="d2"]');
  await resetFocus(page);
  // 匯入表單：Tab 走完五個欄位並鍵入；空表單 Enter 不送出且焦點移到第一個錯誤欄位
  await tabTo(page, screen, '#b5-import-Path', { max: 250 });
  await tabToText(page, screen, 'button', /^匯入確認材料$/); await page.keyboard.press('Enter');
  eq(screen, count('SourceCandidateConfirmImport'), 0, 'an empty form is not submitted'); eq(screen, (await active(page)).id, 'b5-import-Path', 'focus moves to the first invalid field');
  await page.keyboard.type('C:\\handoff\\confirmation.json'); await tabTo(page, screen, '#b5-import-ExpectedHash'); await page.keyboard.type(confirmationHash);
  await tabTo(page, screen, '#b5-import-TargetPath'); await page.keyboard.type('C:\\Business'); await tabTo(page, screen, '#b5-import-Owner'); await page.keyboard.type('王小明'); await tabTo(page, screen, '#b5-import-Evidence'); await page.keyboard.type('change:F1-2');
  await tabToText(page, screen, 'button', /^匯入確認材料$/); await page.keyboard.press('Enter'); await panel.getByText(/完成：已匯入/).waitFor();
  eq(screen, count('SourceCandidateConfirmImport'), 1, 'one import was sent'); await panel.getByText('成員總數').waitFor();
  await focusDefect(page, screen, 'F1-FOCUS-D2-IMPORT', 'src/ui/console.js:2416 submit.disabled = imp.busy', 'after the keyboard-activated import finishes');
  // 進入對應審閱
  await tabToText(page, screen, 'button', /進入工作負載對應審閱/, { max: 80 }); await page.keyboard.press('Enter'); await panel.locator('.b5-mapping-row').first().waitFor();
  await tabTo(page, screen, '#b5-map-0'); await page.keyboard.press('ArrowDown');
  eq(screen, await panel.locator('#b5-map-0').inputValue(), 'Include', 'ArrowDown maps the uniquely mapped reference');
  eq(screen, (await active(page)).id, 'b5-map-0', 'focus stays on the select although the panel repainted (dependency select appeared)');
  await tabTo(page, screen, '#b5-dep-0'); await page.keyboard.press('ArrowDown'); eq(screen, await panel.locator('#b5-dep-0').inputValue(), 'Mandatory', 'the dependency select is operable from the keyboard');
  for (const [index, expected] of [[1, 'Exclude'], [2, 'Exclude'], [3, 'Exclude']]) { await tabTo(page, screen, `#b5-map-${index}`); await page.keyboard.press('ArrowDown'); eq(screen, await panel.locator(`#b5-map-${index}`).inputValue(), expected, `ArrowDown on reference ${index} picks the first enabled choice`); }
  await page.keyboard.press('ArrowDown'); eq(screen, await panel.locator('#b5-map-3').inputValue(), 'Manual', 'a second ArrowDown reaches 人工處理');
  ok(screen, /對應 1、不對應 2、人工處理 1；尚未選擇 0 筆/.test(await panel.locator('[data-b5-step="mapping"] .b5-summary').innerText()), 'the summary follows keyboard choices');
  await tabToText(page, screen, 'button', /檢視並送出對應審閱/); await page.keyboard.press('Enter'); await page.waitForSelector('#b5-confirm-dialog[open]');
  eq(screen, (await active(page)).name, '返回修改', 'the safe choice has the initial focus'); await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.querySelector('#b5-confirm-dialog[open]'));
  eq(screen, count('SourceCandidateMappingSubmit'), 0, 'Esc sends nothing'); ok(screen, /檢視並送出對應審閱/.test((await active(page) || {}).name || ''), 'Esc returns focus to the opener');
  await page.keyboard.press('Enter'); await page.waitForSelector('#b5-confirm-dialog[open]'); await page.keyboard.press('Shift+Tab'); eq(screen, (await active(page)).name, '確認送出', 'Shift+Tab reaches the confirm button'); await page.keyboard.press('Enter');
  await panel.getByText(/完成：已記錄 4 筆對應/).waitFor(); eq(screen, count('SourceCandidateMappingSubmit'), 1, 'exactly one mapping submission'); await focusDefect(page, screen, 'F1-FOCUS-D2-MAPPING', 'src/ui/console.js:2509 submit.disabled = mp.busy', 'after the keyboard-confirmed mapping submit finishes');
  await shot(page, 'n9e-d2-1280.png');
  // 重開：已確認的對應維持，不重問
  const before = S.submissions.length;
  await reopenPage(page); await panel.locator('#b5-review-item').waitFor();
  await resetFocus(page); await tabTo(page, screen, '#b5-review-item', { max: 250 }); await page.keyboard.press('ArrowDown');
  await tabToText(page, screen, 'button', /檢視確認內容/, { max: 20 }).catch(() => null); if (await panel.getByRole('button', { name: '檢視確認內容' }).count()) await page.keyboard.press('Enter');
  await panel.getByText('成員總數').waitFor();
  await tabToText(page, screen, 'button', /進入工作負載對應審閱/, { max: 80 }); await page.keyboard.press('Enter'); await panel.locator('.b5-mapping-row').first().waitFor();
  eq(screen, await panel.locator('[data-b5-step="mapping"] .b5-summary').innerText(), '已選：對應 1、不對應 2、人工處理 1；尚未選擇 0 筆。', 'after a reload every recorded mapping is pre-selected, nothing is asked again');
  eq(screen, await panel.locator('.b5-mapping-row').filter({ hasText: '已記錄：' }).count(), 4, 'each row says it is already recorded'); eq(screen, S.submissions.length, before, 'reopening writes nothing');
  // 重新盤點：只有一筆引用變動（回到未記錄），其餘維持
  S.decisionRevision++; S.revision++; Object.assign(S.mappingRows[2], { Decision: 'Pending', StoredStatus: 'NotRecorded', Path: 'C:\\Business\\settings-v2.json' });
  await reopenPage(page); await panel.locator('#b5-review-item').waitFor();
  await resetFocus(page); await tabTo(page, screen, '#b5-review-item', { max: 250 }); await page.keyboard.press('ArrowDown');
  await tabToText(page, screen, 'button', /檢視確認內容/, { max: 20 }).catch(() => null); if (await panel.getByRole('button', { name: '檢視確認內容' }).count()) await page.keyboard.press('Enter');
  await panel.getByText('成員總數').waitFor(); await tabToText(page, screen, 'button', /進入工作負載對應審閱/, { max: 80 }); await page.keyboard.press('Enter'); await panel.locator('.b5-mapping-row').first().waitFor();
  eq(screen, await panel.locator('[data-b5-step="mapping"] .b5-summary').innerText(), '已選：對應 1、不對應 1、人工處理 1；尚未選擇 1 筆。', 're-inventory re-asks only the one changed reference');
  // 新草稿：對變動的那筆選「人工處理」→ 再次重新盤點後按「重新讀取」不清除
  await tabTo(page, screen, '#b5-map-2'); await page.keyboard.press('ArrowDown'); await page.keyboard.press('ArrowDown');
  eq(screen, await panel.locator('#b5-map-2').inputValue(), 'Manual', 'a new choice is drafted'); const draftSummary = await panel.locator('[data-b5-step="mapping"] .b5-summary').innerText();
  S.decisionRevision++; S.revision++;
  await tabToText(page, screen, 'button', /進入工作負載對應審閱/, { back: true, max: 80 }); await page.keyboard.press('Enter');
  await page.waitForFunction(rev => { const m = window.WsmConsole.b5.mapping; return !m.loading && m.data && m.data.DecisionRevision === rev; }, S.decisionRevision);
  eq(screen, await panel.locator('#b5-map-2').inputValue(), 'Manual', 'the new draft choice survives a keyboard re-read after the inventory changed');
  eq(screen, await panel.locator('[data-b5-step="mapping"] .b5-summary').innerText(), draftSummary, 'the draft summary is unchanged by the re-read');
  eq(screen, count('SourceCandidateMappingSubmit'), 1, 'nothing was re-sent'); await page.context().close();
  for (const vp of VIEWPORTS) {
    resetManager(); S.imported = true; const importedJob = { jobId: 'imp-1', operationId: 'imp-1', action: 'SourceCandidateConfirmImport', status: 'ReviewRequired', role: 'Manager', pairId, workspace: root, CompletedUtc: '2026-10-22T00:00:00Z', outputs: [{ Status: 'ImportedReviewRequired', ItemId: importedItemId, MemberCount: 3, DecisionRevision: 10, AuthoritativeApproval: false }] };
    S.jobs.set('imp-1', importedJob);
    const narrow = await openManager(screen, 'd2', vp); await narrow.locator('#b5-review-item').selectOption(importedItemId); await narrow.getByRole('button', { name: '檢視確認內容' }).click(); await narrow.getByText('成員總數').waitFor();
    await layout(narrow, screen, `${vp.label} review`, ['[data-b5-panel="d2"]', '#b5-import-Path', '#b5-import-ExpectedHash', '#b5-review-item']);
    await narrow.getByRole('button', { name: '進入工作負載對應審閱' }).click(); await narrow.locator('.b5-mapping-row').first().waitFor();
    await narrow.locator('#b5-map-0').selectOption('Include'); await layout(narrow, screen, `${vp.label} mapping`, ['#b5-map-0', '#b5-dep-0', '[data-b5-step="mapping"]']);
    await narrow.getByRole('button', { name: '檢視並送出對應審閱' }).click(); await narrow.locator('#b5-map-1').scrollIntoViewIfNeeded();
    await shot(narrow, `n9e-d2-${vp.width}.png`); await narrow.context().close();
  }
}

(async () => {
  const srcBefore = ['console.js', 'console.css', 'index.html', 'nonc.js'].map(n => fs.readFileSync(path.join(root, 'src', 'ui', n)).toString('base64'));
  let failed = false;
  try {
    const mixed = buildResults('New-OfflineReportFixture.ps1', ['-Shape', 'V2', '-Scale', 'Mixed']);
    const normal = buildResults('New-SoftwareTabFixture.ps1', ['-Shape', 'Normal']);
    const partial = buildTarget('Target'), complete = buildTarget('TargetComplete');
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: edge });
    const screensToRun = [['備份結果三分頁（工作台）', () => screenBackupTabs(mixed)], ['安裝軟體分頁（工作台）', () => screenSoftwareTab(normal)], ['Target 新機安裝檢查', () => screenTarget(partial, complete)], ['排除區域表', () => screenExcluded(mixed)], ['C2 軟體處置審閱', screenC2], ['D2 候選確認與對應審閱', screenD2]];
    const failures = [];
    for (const [name, run] of screensToRun) {
      try { await run(); } catch (error) { failures.push(`${name}: ${error.message.split('\n')[0]}`); console.error(`FAIL [${name}]`, error); }
      const errors = consoleErrors.get(name) || [];
      try { eq(name, errors, [], 'zero console errors and page errors'); } catch (error) { failures.push(`${name}: console ${errors.join(' | ')}`); console.error(error.message); }
    }
    for (const name of consoleErrors.keys()) if (!screensToRun.some(([n]) => n === name)) failures.push(`unexpected screen name in console errors: ${name}`);
    console.log('--- 每個畫面通過的檢查項目數 ---');
    let total = 0; for (const [name] of screensToRun) { const n = tally.get(name) || 0; total += n; console.log(`${name}: ${n}`); }
    console.log(`合計 ${total} 項`);
    if (failures.length) { failed = true; console.error('FAILED:\n' + failures.join('\n')); }
    else console.log('PASS Test-F1AcceptanceBrowser: keyboard, 320px, 200% zoom, reopen without re-asking, zero console errors for all six screens.');
  } catch (error) { failed = true; console.error(error); }
  finally {
    if (browser) await browser.close();
    server.close();
    for (const dir of tempDirs) fs.rmSync(dir, { recursive: true, force: true });
    const srcAfter = ['console.js', 'console.css', 'index.html', 'nonc.js'].map(n => fs.readFileSync(path.join(root, 'src', 'ui', n)).toString('base64'));
    if (JSON.stringify(srcBefore) !== JSON.stringify(srcAfter)) { failed = true; console.error('src/ui changed during the test'); }
  }
  if (failed) process.exitCode = 1;
})();
