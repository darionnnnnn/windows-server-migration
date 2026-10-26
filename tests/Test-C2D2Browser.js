// B5: C2 軟體處置審閱與 D2 來源候選確認／工作負載對應的真實瀏覽器測試（Playwright + Edge；API 為本檔內的固定替身，前端為真實 src/ui）。
// 涵蓋：三個角色的入口與順序、匯入表單驗證（可見 label、錯誤與欄位關聯）、確認內容（含空目錄成員）、對應審閱送出（CAS、鍵盤確認、Esc 不送出）、
// C2 批次選取與特殊產品限制、Ack、確認摘要、尚未決定清單、過期提示（不自動重送、保留選擇、重新讀取）、loading／empty／error 狀態、390px 版面與零 console 錯誤。
const assert = require('node:assert/strict'), fs = require('node:fs'), http = require('node:http'), path = require('node:path');
const runtimePath = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtimePath, 'playwright'));
const root = path.resolve(__dirname, '..'), screens = process.env.WSM_B5_SCREENS || path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });
const assets = new Map([['/', path.join(root, 'src/ui/index.html')], ['/ui/console.js', path.join(root, 'src/ui/console.js')], ['/ui/console.css', path.join(root, 'src/ui/console.css')], ['/ui/nonc.js', path.join(root, 'src/ui/nonc.js')]]);
const hex = ch => ch.repeat(64);
const pairId = 'b5-pair', contextId = 'b5-context', inventoryHash = hex('1'), confirmationHash = hex('2'), candidateHash = hex('3'), scopeItemId = hex('d'), importedItemId = hex('e');

// ---- 可變的替身狀態 -------------------------------------------------------------------------------------------------
let role = 'Manager', revision = 3, decisionRevision = 10, step = 'prepare';
let submissions = [], viewCalls = [], jobs = new Map(), failures = new Map(), viewDelayMs = 0, viewMode = 'ok';
let importedOnce = false, c2Rows = [], mappingRows = [], deliberateHttpErrors = 0;
const software = (id, name, extra) => Object.assign({ SoftwareId: id, Name: name, Publisher: 'Fixture Corp', Version: '1.0', Architecture: 'x64', Scope: 'Machine', SID: '', RegistryView: 'Registry64', Location: 'D:\\Apps', SourceKind: 'Registry', CaptureStatus: 'Success', ConsumerItems: [], SpecialProduct: false, AllowedDispositions: ['Reinstall', 'Portable', 'KeepCompatible', 'External', 'NotNeeded', 'Unknown'], DecisionState: 'Unreviewed', Disposition: '', Owner: '', Reason: '', Evidence: '' }, extra || {});
function resetState(nextRole, nextStep) {
  role = nextRole; step = nextStep; revision = 3; decisionRevision = 10; submissions = []; viewCalls = []; jobs = new Map(); failures = new Map(); viewDelayMs = 0; viewMode = 'ok'; importedOnce = false;
  c2Rows = [software('sw-a', '訂單系統執行階段', { ConsumerItems: [{ ItemId: 'i1', Name: '訂單網站', Decision: 'Include' }] }), software('sw-b', '報表小工具', { Scope: 'User' }), software('sw-c', 'Microsoft SQL Server Database Engine', { SpecialProduct: true, AllowedDispositions: ['External', 'NotNeeded'] }), software('sw-d', '排程輔助程式', { DecisionState: 'Reviewed', Disposition: 'External', Owner: 'o', Reason: 'r', Evidence: 'e' })];
  mappingRows = [
    { ReferenceId: hex('a'), ConsumerItemId: hex('7'), FieldPointer: '/Actions/Exec/Command', ReferenceKind: 'TaskCommand', Path: 'C:\\Business\\worker.exe', Required: true, ReviewRequired: false, Opaque: false, DiscoveryStatus: 'Mapped', SuggestedFileScopeItemId: scopeItemId, SuggestedTargetValue: 'C:\\Business\\worker.exe', DiscoveryReason: '', Decision: 'Pending', FileScopeItemId: '', DependencyType: 'None', StoredStatus: 'NotRecorded' },
    { ReferenceId: hex('b'), ConsumerItemId: hex('7'), FieldPointer: '/Actions/Exec/WorkingDirectory', ReferenceKind: 'TaskWorkingDirectory', Path: 'C:\\Business', Required: false, ReviewRequired: true, Opaque: false, DiscoveryStatus: 'Unmapped', SuggestedFileScopeItemId: '', SuggestedTargetValue: '', DiscoveryReason: 'ExactMembers 不宣稱涵蓋資料夾', Decision: 'Pending', FileScopeItemId: '', DependencyType: 'None', StoredStatus: 'NotRecorded' },
    { ReferenceId: hex('c'), ConsumerItemId: hex('7'), FieldPointer: '/Actions/Exec/Arguments', ReferenceKind: 'TaskArgumentPath', Path: 'C:\\Business\\settings.json', Required: false, ReviewRequired: true, Opaque: false, DiscoveryStatus: 'Unmapped', SuggestedFileScopeItemId: '', SuggestedTargetValue: '', DiscoveryReason: '', Decision: 'Pending', FileScopeItemId: '', DependencyType: 'None', StoredStatus: 'NotRecorded' },
    { ReferenceId: hex('f'), ConsumerItemId: hex('7'), FieldPointer: '/Actions/Exec/Arguments', ReferenceKind: 'TaskArguments', Path: '', Required: false, ReviewRequired: true, Opaque: true, DiscoveryStatus: 'Unmapped', SuggestedFileScopeItemId: '', SuggestedTargetValue: '', DiscoveryReason: '', Decision: 'Pending', FileScopeItemId: '', DependencyType: 'None', StoredStatus: 'NotRecorded' }
  ];
}
const candidates = [
  { CandidateId: hex('4'), CandidateType: 'DirectoryRoot', Path: 'C:\\Business', Length: null, LastWriteUtc: '2026-10-01T00:00:00Z', WorkloadReferenceCount: 4 },
  { CandidateId: hex('5'), CandidateType: 'ExactFile', Path: 'C:\\Business\\worker.exe', Length: 2048, LastWriteUtc: '2026-10-01T00:00:00Z', WorkloadReferenceCount: 1 },
  { CandidateId: hex('6'), CandidateType: 'DirectoryRoot', Path: 'C:\\Data', Length: null, LastWriteUtc: '2026-10-02T00:00:00Z', WorkloadReferenceCount: 0 }
];
const previewHash = () => (decisionRevision.toString(16).padStart(2, '0') + hex('9')).slice(0, 64);
const sessionBody = () => ({ token: 'fixture', contextId, sessionId: 's', hostName: role, role, workspace: `C:\\fixture\\${role.toLowerCase()}`, pairId: role === 'Source' ? '' : pairId, revision, decisionRevision: role === 'Source' ? null : decisionRevision, selectionRevision: role === 'Source' ? null : 1, dataVersion: `dv-${revision}`, principal: 'Fixture' });
const wizardBody = () => ({ Kind: 'WizardProjection', role, workspaceRole: role, roleMatchesWorkspace: true, pairId: role === 'Source' ? '' : pairId, pairName: 'Source to Target', currentStep: step, nextStep: step, mode: 'ItemByItem', revision, groups: [], gates: [], results: {}, context: {}, actions: [] });
const reviewBody = () => ({ Kind: 'SourceCandidateConfirmationReview', PairId: pairId, ItemId: importedItemId, Decision: 'Pending', DecisionRevision: decisionRevision, SelectionRevision: 1, ConfirmationId: 'conf-1', ConfirmationHash: confirmationHash, MaterialReference: 'assistive/materials/x', ScanId: 'scan-00000001', CandidateId: hex('4'), CandidateType: 'DirectoryRoot', InventoryHash: inventoryHash, InventoryRevision: 1, Root: 'C:\\', ScopeRoot: 'C:\\Business', MemberCount: 3, FileMemberCount: 2, DirectoryMemberCount: 1, MembersShown: 3, MembersTruncated: false, Members: [{ RelativePath: 'worker.exe', SHA256: hex('a'), Length: 1200, CandidateId: hex('4') }, { RelativePath: 'settings.json', SHA256: hex('b'), Length: 300, CandidateId: hex('4') }, { RelativePath: 'empty-dir', SHA256: '', Length: 0, CandidateId: hex('4'), EntryType: 'Directory' }], WorkloadReferences: mappingRows.map(row => ({ ConsumerItemId: row.ConsumerItemId, FieldPointer: row.FieldPointer, ReferenceKind: row.ReferenceKind, Path: row.Path, Required: row.Required, ReviewRequired: row.ReviewRequired })), viewRevision: revision });
const mappingBody = () => ({ Kind: 'SourceCandidateWorkloadMappingReview', PairId: pairId, CandidateItemId: importedItemId, ConfirmationId: 'conf-1', ConfirmationHash: confirmationHash, InventoryHash: inventoryHash, InventoryRevision: 1, DecisionRevision: decisionRevision, SelectionRevision: 1, References: mappingRows });
const c2Body = () => ({ Kind: 'AssistiveSoftwareDispositionReview', Status: 'Previewed', PairId: pairId, DecisionRevision: decisionRevision, InventoryHash: inventoryHash, SoftwareCatalogHash: hex('8'), Rows: c2Rows, Coverage: [{ Probe: 'Uninstall', Scope: 'Machine', SID: '', View: 'Registry64', Status: 'Success', EvidenceKind: 'Registry', Count: 3, ErrorKind: '' }, { Probe: 'Uninstall', Scope: 'User', SID: 'S-1-5-21-1', View: 'Registry32', Status: 'PermissionDenied', EvidenceKind: 'Registry', Count: 0, ErrorKind: 'AccessDenied' }], TrustedSoftwareRoots: { Status: 'Partial', Count: 1, Diagnostics: [] }, ReadinessProof: false, AuthoritativeApproval: false, PreviewHash: previewHash() });

function outcomeFor(body) {
  const args = body.args || {};
  if (body.action === 'SourceCandidateConfirmExport') return { status: 'ReviewRequired', outputs: [{ Status: 'Confirmed', ConfirmationPath: 'C:\\fixture\\source\\confirmation.json', ConfirmationHash: confirmationHash, MemberCount: 3, CandidateId: args.CandidateId, AuthoritativeApproval: false }] };
  if (body.action === 'SourceCandidateConfirmImport') { importedOnce = true; decisionRevision++; revision++; return { status: 'ReviewRequired', outputs: [{ Status: 'ImportedReviewRequired', ItemId: importedItemId, MemberCount: 3, DecisionRevision: decisionRevision, AuthoritativeApproval: false }] }; }
  if (body.action === 'SourceCandidateMappingSubmit') { decisionRevision++; revision++; return { status: 'ReviewRequired', outputs: [{ Status: 'SubmittedReviewRequired', MappingCount: (args.Decisions || []).length, DecisionRevision: decisionRevision, AuthoritativeApproval: false }] }; }
  if (body.action === 'SoftwareDispositionReviewSubmit') {
    for (const decision of args.Decisions || []) { const row = c2Rows.find(item => item.SoftwareId === decision.SoftwareId); if (row) Object.assign(row, { DecisionState: 'Reviewed', Disposition: decision.Disposition, Owner: decision.Owner, Reason: decision.Reason, Evidence: decision.Evidence }); }
    decisionRevision++; revision++;
    return { status: 'Succeeded', outputs: [{ Status: 'Applied', SubmittedCount: (args.Decisions || []).length, DecisionRevision: decisionRevision }] };
  }
  return { status: 'Failed', outputs: [] };
}
function viewFor(body) {
  if (viewMode === 'error') { deliberateHttpErrors++; return [400, { message: 'The local operation could not be completed.', code: 'operation_failed', correlationId: 'c', nextStep: 'x' }]; }
  if (body.action === 'SourceCandidateList') return [200, { Kind: 'SourceCandidateList', ScanId: 'scan-00000001', ScanStatus: 'Succeeded', CandidateHash: candidateHash, CandidateCount: viewMode === 'empty' ? 0 : candidates.length, CandidatesShown: viewMode === 'empty' ? 0 : candidates.length, CandidatesTruncated: false, Candidates: viewMode === 'empty' ? [] : candidates, AuthoritativeApproval: false }];
  if (body.action === 'SourceCandidateConfirmReview') return [200, reviewBody()];
  if (body.action === 'SourceCandidateMappingReview') return [200, mappingBody()];
  if (body.action === 'SoftwareDispositionReview') return [200, viewMode === 'empty' ? Object.assign(c2Body(), { Rows: [] }) : c2Body()];
  return [404, { code: 'not_found' }];
}
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1'), asset = assets.get(url.pathname);
  if (asset) { res.writeHead(200, { 'Content-Type': asset.endsWith('.js') ? 'application/javascript' : asset.endsWith('.css') ? 'text/css' : 'text/html' }); fs.createReadStream(asset).pipe(res); return; }
  if (url.pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }
  let raw = ''; req.on('data', c => raw += c);
  req.on('end', () => {
    const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/api/session') return send(200, sessionBody());
    if (url.pathname === '/api/context') return send(200, { roles: [role], pairs: role === 'Source' ? [] : [{ pairId, label: 'Source to Target' }], role, pairId: role === 'Source' ? '' : pairId, contextId, revision, decisionRevision: role === 'Source' ? null : decisionRevision, selectionRevision: role === 'Source' ? null : 1, dataVersion: `dv-${revision}` });
    if (url.pathname === '/api/wizard' && req.method === 'GET') return send(200, wizardBody());
    if (url.pathname === '/api/wizard/nonc') return send(200, { Kind: 'WizardNonCProjection', Role: role, PairId: pairId, ContextId: contextId, HasNonC: false });
    if (url.pathname === '/api/wizard/runtime') return send(200, { Kind: 'WizardRuntimeProjection', Role: role, PairId: role === 'Source' ? '' : pairId, viewContext: { revision }, status: 'Idle', actions: [], runtime: {} });
    if (url.pathname === '/api/jobs' && req.method === 'GET') return send(200, { items: [...jobs.values()] });
    if (url.pathname.startsWith('/api/jobs/') && req.method === 'GET') { const job = jobs.get(decodeURIComponent(url.pathname.split('/').pop())); return job ? send(200, { job }) : send(404, { code: 'job_not_found' }); }
    if (url.pathname === '/api/view' && req.method === 'POST') {
      const body = JSON.parse(raw); viewCalls.push(body);
      const reply = () => { const [status, value] = viewFor(body); send(status, value); };
      if (viewDelayMs) setTimeout(reply, viewDelayMs); else reply();
      return;
    }
    if (url.pathname === '/api/operations' && req.method === 'POST') {
      const body = JSON.parse(raw); submissions.push(body);
      const failure = failures.get(body.action);
      if (failure && failure.kind === 'http-409') { failures.delete(body.action); deliberateHttpErrors++; return send(409, { message: 'The reviewed data changed before this operation was submitted.', code: 'stale_revision', correlationId: 'c', nextStep: 'Refresh', submissionRejected: true }); }
      const record = { jobId: body.operationId, operationId: body.operationId, action: body.action, status: 'Running', role, pairId: role === 'Source' ? '' : pairId, workspace: `C:\\fixture\\${role.toLowerCase()}`, revision, StartedUtc: new Date().toISOString(), outputs: [] };
      if (failure && failure.kind === 'job-stale') { failures.delete(body.action); Object.assign(record, { terminal: { status: 'Failed', outputs: [], error: { message: 'The reviewed context or data changed.', code: 'stale_context', correlationId: 'c', nextStep: 'Refresh' } } }); }
      else if (failure && failure.kind === 'job-failed') { failures.delete(body.action); Object.assign(record, { terminal: { status: 'Failed', outputs: [], error: { message: 'The local operation could not be completed.', code: 'operation_failed', correlationId: 'c', nextStep: 'Check' } } }); }
      else record.terminal = outcomeFor(body);
      jobs.set(body.operationId, record);
      setTimeout(() => { const job = jobs.get(body.operationId); Object.assign(job, job.terminal, { CompletedUtc: new Date().toISOString(), revision }); delete job.terminal; }, 80);
      return send(202, { job: { jobId: record.jobId, operationId: record.operationId, action: record.action, status: 'Running', role, pairId: record.pairId, revision } });
    }
    if (process.env.WSM_B5_TRACE) console.error('404 route', req.method, url.pathname);
    return send(404, { code: 'not_found', route: url.pathname });
  });
});

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const base = `http://127.0.0.1:${server.address().port}/#wizard`, errors = [];
    async function openPage(width, panel, waitUntil = 'networkidle') {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      page.on('pageerror', e => errors.push('pageerror: ' + e.message)); page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
      await page.goto(base, { waitUntil });
      await page.waitForFunction(() => window.WsmConsole?.state?.wizard?.currentStep);
      await page.locator(`[data-b5-panel="${panel}"]`).waitFor();
      return page;
    }
    const noOverflow = async (page, what) => assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal overflow: ${what}`);
    const noLiveRegions = async (page, what) => assert.equal(await page.evaluate(() => document.querySelectorAll('.b5-panels [role="status"], .b5-panels [aria-live], #b5-confirm-dialog [role="status"], #b5-confirm-dialog [aria-live]').length), 0, `the B5 panels add no live region or role=status: ${what}`);
    const count = action => submissions.filter(item => item.action === action).length;
    const settle = (page, ms = 600) => page.waitForTimeout(ms);

    // =========================================================================================== 1. Source：挑選候選、匯出確認材料
    resetState('Source', 'scan');
    jobs.set('scan-job-1', { jobId: 'scan-job-1', operationId: 'scan-job-1', action: 'SourceCandidateScan', status: 'ReviewRequired', role: 'Source', pairId: '', workspace: 'C:\\fixture\\source', CompletedUtc: '2026-10-22T00:00:00Z', outputs: [{ Status: 'ReviewRequired', ScanId: 'scan-00000001', CandidateCount: 3, CandidatePath: 'C:\\fixture\\candidates.json', CandidateHash: candidateHash }] });
    let page = await openPage(390, 'source');
    let panel = page.locator('[data-b5-panel="source"]');
    await panel.locator('input[name="b5-candidate"]').first().waitFor({ timeout: 8000 }).catch(async error => { console.error('DEBUG panel:', await panel.innerText(), ' viewCalls', JSON.stringify(viewCalls.map(c => c.action)), ' errors', errors.join('|'), ' session', await page.evaluate(() => JSON.stringify(window.WsmConsole.state.session)), ' fetched', await page.evaluate(() => fetch('/api/session').then(r => r.text()))); throw error; });
    assert.equal(await panel.locator('h2').innerText(), '來源候選確認（挑一個候選並匯出）');
    assert.equal(await panel.locator('input[name="b5-candidate"]').count(), 3, 'every scanned candidate is listed');
    assert.match(await panel.innerText(), /候選清單雜湊/); assert.match(await panel.innerText(), new RegExp(candidateHash));
    const exportButton = panel.getByRole('button', { name: '匯出確認材料', exact: true });
    assert.equal(await exportButton.isDisabled(), true, 'export is disabled until one candidate is picked');
    assert.equal(await panel.locator('legend').innerText(), '選擇一個候選', 'the choice group has a visible legend');
    await noLiveRegions(page, 'source'); await noOverflow(page, 'source list');
    await page.screenshot({ path: path.join(screens, 'b5-source-list-390.png'), fullPage: true });
    // 鍵盤：聚焦第一個候選並用空白鍵選取，再用 Tab 找到匯出鈕
    await panel.locator('input[name="b5-candidate"]').first().focus(); await page.keyboard.press('Space');
    assert.equal(await panel.locator('input[name="b5-candidate"]').first().isChecked(), true);
    assert.equal(await panel.getByRole('button', { name: '匯出確認材料', exact: true }).isDisabled(), false, 'picking a candidate enables the export');
    await panel.getByRole('button', { name: '匯出確認材料', exact: true }).click();
    await panel.locator('.b5-result').waitFor();
    assert.equal(count('SourceCandidateConfirmExport'), 1);
    let sent = submissions.find(item => item.action === 'SourceCandidateConfirmExport');
    assert.deepEqual(sent.args, { ScanId: 'scan-00000001', ExpectedCandidateHash: candidateHash, CandidateId: hex('4') }, 'export carries the scan id, the independent candidate hash and the candidate id');
    assert.match(await panel.locator('.b5-result').innerText(), /完成：確認材料已匯出/); assert.match(await panel.locator('.b5-result').innerText(), new RegExp(confirmationHash));
    assert.match(await panel.locator('.b5-result').innerText(), /以可信管道/, 'the next step is stated');
    await page.screenshot({ path: path.join(screens, 'b5-source-exported-390.png'), fullPage: true });
    await noLiveRegions(page, 'source exported');
    // 過期：匯出作業因候選雜湊過期而失敗 -> 提示重新讀取，不自動重送
    failures.set('SourceCandidateConfirmExport', { kind: 'job-stale' });
    await panel.getByRole('button', { name: '匯出確認材料', exact: true }).click();
    await panel.locator('.b5-error').waitFor();
    await settle(page, 900);
    assert.equal(count('SourceCandidateConfirmExport'), 2, 'a stale export is never re-sent automatically');
    assert.match(await panel.innerText(), /過期/); assert.equal(await panel.getByRole('button', { name: '重新讀取候選清單' }).count(), 1);
    const listCallsBefore = viewCalls.filter(item => item.action === 'SourceCandidateList').length;
    await panel.getByRole('button', { name: '重新讀取候選清單' }).click();
    await page.waitForFunction(count => window.__noop === undefined && document.querySelectorAll('[data-b5-panel="source"] input[name="b5-candidate"]').length === count, 3);
    assert.equal(viewCalls.filter(item => item.action === 'SourceCandidateList').length, listCallsBefore + 1, 'reload re-reads the list once');
    assert.equal(count('SourceCandidateConfirmExport'), 2, 'reloading does not submit anything');
    await page.close();
    // empty / error
    resetState('Source', 'scan'); viewMode = 'empty';
    jobs.set('scan-job-1', { jobId: 'scan-job-1', operationId: 'scan-job-1', action: 'SourceCandidateScan', status: 'Succeeded', role: 'Source', pairId: '', workspace: 'C:\\fixture\\source', CompletedUtc: '2026-10-22T00:00:00Z', outputs: [{ Status: 'Succeeded', ScanId: 'scan-00000001' }] });
    page = await openPage(390, 'source'); panel = page.locator('[data-b5-panel="source"]');
    await panel.getByText('尚無資料：這次掃描沒有找到候選。').waitFor(); await page.close();
    resetState('Source', 'scan'); viewMode = 'error';
    jobs.set('scan-job-1', { jobId: 'scan-job-1', operationId: 'scan-job-1', action: 'SourceCandidateScan', status: 'Succeeded', role: 'Source', pairId: '', workspace: 'C:\\fixture\\source', CompletedUtc: '2026-10-22T00:00:00Z', outputs: [{ Status: 'Succeeded', ScanId: 'scan-00000001' }] });
    page = await openPage(390, 'source'); panel = page.locator('[data-b5-panel="source"]');
    await panel.locator('.b5-error').waitFor(); assert.match(await panel.locator('.b5-error').innerText(), /錯誤：/); assert.equal(await panel.getByRole('button', { name: '重新讀取候選清單' }).count(), 1);
    await page.screenshot({ path: path.join(screens, 'b5-source-error-390.png'), fullPage: true }); await page.close();
    resetState('Source', 'scan');
    page = await openPage(390, 'source'); panel = page.locator('[data-b5-panel="source"]');
    await panel.getByText('尚無資料：還沒有完成的候選掃描').waitFor();
    assert.equal(viewCalls.length, 0, 'no list request is made before a scan exists');
    await page.screenshot({ path: path.join(screens, 'b5-source-empty-390.png'), fullPage: true }); await page.close();
    // loading 狀態可被觀察
    resetState('Source', 'scan'); viewDelayMs = 700;
    jobs.set('scan-job-1', { jobId: 'scan-job-1', operationId: 'scan-job-1', action: 'SourceCandidateScan', status: 'Succeeded', role: 'Source', pairId: '', workspace: 'C:\\fixture\\source', CompletedUtc: '2026-10-22T00:00:00Z', outputs: [{ Status: 'Succeeded', ScanId: 'scan-00000001' }] });
    page = await openPage(390, 'source'); panel = page.locator('[data-b5-panel="source"]');
    await panel.getByText('讀取中：正在讀取候選清單').waitFor(); await page.screenshot({ path: path.join(screens, 'b5-source-loading-390.png'), fullPage: true });
    await panel.locator('input[name="b5-candidate"]').first().waitFor(); await page.close();

    // =========================================================================================== 2. Manager D2：匯入、確認內容、對應審閱
    resetState('Manager', 'prepare');
    page = await openPage(390, 'd2'); panel = page.locator('[data-b5-panel="d2"]');
    await page.locator('[data-b5-panel="c2"]').waitFor();
    assert.deepEqual(await page.evaluate(() => [...document.querySelectorAll('.b5-panels > [data-b5-panel]')].map(node => node.dataset.b5Panel)), ['d2', 'c2'], 'Manager sees the D2 panel first, then the C2 panel');
    assert.deepEqual(await panel.locator('[data-b5-step] h3').allInnerTexts(), ['步驟 1：匯入確認材料', '步驟 2：檢視確認內容', '步驟 3：工作負載對應審閱'], 'the three D2 steps appear in order');
    await panel.getByText('尚無資料：還沒有已匯入的候選確認材料').waitFor();
    await panel.getByText('尚未開始：在步驟 2').waitFor();
    // 表單驗證：每個欄位有可見 label，錯誤與欄位關聯，空表單不送出
    for (const [name, label] of [['Path', '確認材料檔案位置'], ['ExpectedHash', '確認材料雜湊（SHA-256）'], ['TargetPath', '原始路徑（與來源相同）'], ['Owner', '負責人'], ['Evidence', '證據參考']]) {
      const info = await page.evaluate(id => { const input = document.getElementById(id), label = document.querySelector(`label[for="${id}"]`); return { label: label ? label.textContent : '', tag: input.tagName }; }, `b5-import-${name}`);
      assert.ok(info.label.startsWith(label), `visible label for ${name}: ${info.label}`);
    }
    const importButton = panel.getByRole('button', { name: '匯入確認材料', exact: true });
    await importButton.click();
    assert.equal(count('SourceCandidateConfirmImport'), 0, 'an empty form is not submitted');
    for (const name of ['Path', 'ExpectedHash', 'TargetPath', 'Owner', 'Evidence']) {
      const info = await page.evaluate(id => { const input = document.getElementById(id), error = document.getElementById(`${id}-error`); return { invalid: input.getAttribute('aria-invalid'), described: input.getAttribute('aria-describedby') || '', errorText: error.textContent, hidden: error.hidden }; }, `b5-import-${name}`);
      assert.equal(info.invalid, 'true', `${name} is marked invalid`); assert.ok(info.described.split(' ').includes(`b5-import-${name}-error`), `${name} error is associated through aria-describedby`); assert.match(info.errorText, /^⚠ 錯誤：/); assert.equal(info.hidden, false);
    }
    assert.equal(await page.evaluate(() => document.activeElement.id), 'b5-import-Path', 'focus moves to the first invalid field');
    await page.screenshot({ path: path.join(screens, 'b5-d2-import-errors-390.png'), fullPage: true });
    await panel.locator('#b5-import-Path').fill('C:\\handoff\\confirmation.json'); await panel.locator('#b5-import-ExpectedHash').fill('not-a-hash'); await panel.locator('#b5-import-TargetPath').fill('C:\\Business'); await panel.locator('#b5-import-Owner').fill('王小明'); await panel.locator('#b5-import-Evidence').fill('change:B5-1');
    assert.equal(await page.evaluate(() => document.getElementById('b5-import-Path').getAttribute('aria-invalid')), null, 'typing clears that field error');
    await importButton.click();
    assert.equal(count('SourceCandidateConfirmImport'), 0, 'a malformed hash is not submitted');
    assert.equal(await page.evaluate(() => [...document.querySelectorAll('#b5-import-Path,#b5-import-ExpectedHash,#b5-import-TargetPath,#b5-import-Owner,#b5-import-Evidence')].filter(input => input.getAttribute('aria-invalid') === 'true').map(input => input.id).join()), 'b5-import-ExpectedHash', 'only the malformed hash is flagged');
    assert.match(await page.locator('#b5-import-ExpectedHash-error').innerText(), /64 碼 SHA-256/);
    await panel.locator('#b5-import-ExpectedHash').fill(confirmationHash.toUpperCase());
    await importButton.click();
    await panel.getByText(/完成：已匯入/).waitFor();
    sent = submissions.find(item => item.action === 'SourceCandidateConfirmImport');
    assert.deepEqual(sent.args, { Path: 'C:\\handoff\\confirmation.json', ExpectedHash: confirmationHash, TargetPath: 'C:\\Business', Owner: '王小明', Evidence: 'change:B5-1', ExpectedRevision: 10 }, 'import carries the typed fields and the Manager decision revision as its CAS');
    assert.equal(sent.expectedRevision, 3); assert.equal(sent.expectedDecisionRevision, 10);
    // 確認內容（自動讀取）
    await panel.getByText('成員總數').waitFor();
    const facts = await panel.locator('[data-b5-step="review"] .b5-facts').innerText();
    assert.match(facts, /成員總數\s+3 個/); assert.match(facts, /其中檔案\s+2 個/); assert.match(facts, /其中空目錄\s+1 個/, 'files and empty directories are counted separately');
    assert.match(await panel.locator('[data-b5-step="review"]').innerText(), new RegExp(confirmationHash));
    const memberText = await panel.locator('.b5-table tbody').first().innerText();
    assert.match(memberText, /📁 空目錄\s+empty-dir/, 'the empty directory member is listed with its own type'); assert.match(memberText, /📄 檔案\s+worker\.exe/);
    assert.deepEqual(await panel.locator('.b5-table').first().evaluate(table => [...table.querySelectorAll('thead th')].map(th => th.scope)), ['col', 'col', 'col', 'col']);
    await noOverflow(page, 'D2 review'); await noLiveRegions(page, 'D2 review');
    await page.screenshot({ path: path.join(screens, 'b5-d2-review-390.png'), fullPage: true });
    // 對應審閱
    await panel.getByRole('button', { name: '進入工作負載對應審閱' }).click();
    await panel.locator('.b5-mapping-row').first().waitFor();
    assert.equal(await panel.locator('.b5-mapping-row').count(), 4);
    const includeStates = await panel.locator('.b5-mapping-row').evaluateAll(rows => rows.map(row => [...row.querySelectorAll('select option')].find(option => option.value === 'Include').disabled));
    assert.deepEqual(includeStates, [false, true, true, true], 'only the uniquely mapped reference may be mapped; others are visibly disabled');
    assert.match(await panel.locator('.b5-mapping-row').nth(3).innerText(), /內容不透明/);
    const mappingSubmit = panel.getByRole('button', { name: '檢視並送出對應審閱' });
    await mappingSubmit.click();
    assert.equal(count('SourceCandidateMappingSubmit'), 0, 'an incomplete review is not submitted');
    assert.match(await panel.locator('.b5-mapping-row').first().evaluate(() => document.querySelector('[data-b5-step="mapping"]').innerText), /還有 4 筆沒有選擇/);
    assert.equal(await page.evaluate(() => document.activeElement.id), 'b5-map-0', 'focus moves to the first undecided reference');
    assert.equal(await page.evaluate(() => document.getElementById('b5-map-0').getAttribute('aria-invalid')), 'true');
    await page.screenshot({ path: path.join(screens, 'b5-d2-mapping-incomplete-390.png'), fullPage: true });
    await panel.locator('#b5-map-0').selectOption('Include');
    await panel.locator('#b5-dep-0').selectOption('Mandatory');
    await panel.locator('#b5-map-1').selectOption('Manual'); await panel.locator('#b5-map-2').selectOption('Exclude'); await panel.locator('#b5-map-3').selectOption('Manual');
    assert.match(await panel.locator('[data-b5-step="mapping"] .b5-summary').innerText(), /對應 1、不對應 1、人工處理 2；尚未選擇 0 筆/);
    await noOverflow(page, 'D2 mapping'); await noLiveRegions(page, 'D2 mapping');
    await page.screenshot({ path: path.join(screens, 'b5-d2-mapping-ready-390.png'), fullPage: true });
    // 確認對話框：Esc 不送出且焦點回到觸發按鈕
    await mappingSubmit.click(); await page.waitForSelector('#b5-confirm-dialog[open]');
    assert.match(await page.locator('#b5-confirm-dialog').innerText(), /對應：1 筆/); assert.match(await page.locator('#b5-confirm-dialog').innerText(), /回到「待審閱」/);
    await page.screenshot({ path: path.join(screens, 'b5-d2-mapping-confirm-390.png'), fullPage: true });
    await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.querySelector('#b5-confirm-dialog[open]'));
    assert.equal(count('SourceCandidateMappingSubmit'), 0, 'Esc sends nothing');
    assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.textContent), '檢視並送出對應審閱', 'focus returns to the trigger button');
    // 鍵盤完成確認：Enter 開啟、Shift+Tab 回到「確認送出」、Enter 送出
    await page.keyboard.press('Enter'); await page.waitForSelector('#b5-confirm-dialog[open]');
    assert.equal(await page.evaluate(() => document.activeElement.textContent), '返回修改', 'the safe choice has initial focus');
    await page.keyboard.press('Shift+Tab'); assert.equal(await page.evaluate(() => document.activeElement.textContent), '確認送出');
    await page.keyboard.press('Enter');
    await panel.getByText(/完成：已記錄 4 筆對應/).waitFor();
    sent = submissions.find(item => item.action === 'SourceCandidateMappingSubmit');
    assert.equal(count('SourceCandidateMappingSubmit'), 1);
    assert.equal(sent.args.CandidateItemId, importedItemId); assert.equal(sent.args.ExpectedInventoryHash, inventoryHash); assert.equal(sent.args.ExpectedConfirmationHash, confirmationHash); assert.equal(sent.args.ExpectedRevision, 11, 'the mapping CAS uses the revision of the review it was based on');
    assert.deepEqual(sent.args.Decisions, [
      { ReferenceId: hex('a'), Decision: 'Include', FileScopeItemId: scopeItemId, DependencyType: 'Mandatory' }, { ReferenceId: hex('b'), Decision: 'Manual', FileScopeItemId: '', DependencyType: 'None' },
      { ReferenceId: hex('c'), Decision: 'Exclude', FileScopeItemId: '', DependencyType: 'None' }, { ReferenceId: hex('f'), Decision: 'Manual', FileScopeItemId: '', DependencyType: 'None' }], 'every reference carries an explicit decision');
    await page.screenshot({ path: path.join(screens, 'b5-d2-mapping-done-390.png'), fullPage: true });
    // 過期：對應送出因 hash 過期而失敗 -> 提示重新讀取、保留選擇、不自動重送
    failures.set('SourceCandidateMappingSubmit', { kind: 'job-stale' });
    await panel.getByRole('button', { name: '檢視並送出對應審閱' }).click(); await page.waitForSelector('#b5-confirm-dialog[open]');
    await page.locator('#b5-confirm-dialog [data-b5-confirm="accept"]').click();
    await panel.getByText(/資料已過期/).first().waitFor(); await settle(page, 900);
    assert.equal(count('SourceCandidateMappingSubmit'), 2, 'a stale mapping submit is never re-sent automatically');
    assert.match(await panel.locator('[data-b5-step="mapping"]').innerText(), /不會自動重送/);
    await page.screenshot({ path: path.join(screens, 'b5-d2-mapping-stale-390.png'), fullPage: true });
    const mappingReadsBefore = viewCalls.filter(item => item.action === 'SourceCandidateMappingReview').length;
    await panel.locator('[data-b5-step="mapping"]').getByRole('button', { name: '重新讀取' }).click().catch(() => {});
    // 過期狀態下重新讀取按鈕存在於 mapping 區（若已重畫則由提示區提供）
    await settle(page, 300);
    assert.ok(viewCalls.filter(item => item.action === 'SourceCandidateMappingReview').length >= mappingReadsBefore, 'reload re-reads the review');
    assert.equal(count('SourceCandidateMappingSubmit'), 2, 'reloading does not submit');
    // HTTP 409 路徑
    failures.set('SourceCandidateMappingSubmit', { kind: 'http-409' });
    await page.evaluate(() => { document.querySelector('[data-b5-step="mapping"] button[data-b5-focus="mapping-submit"]')?.click(); });
    await page.waitForSelector('#b5-confirm-dialog[open]'); await page.locator('#b5-confirm-dialog [data-b5-confirm="accept"]').click();
    await panel.getByText(/資料已過期/).first().waitFor(); await settle(page, 700);
    assert.equal(count('SourceCandidateMappingSubmit'), 3, 'one 409 attempt, and no automatic retry afterwards');
    await page.close();
    // D2 loading / error
    resetState('Manager', 'prepare'); viewMode = 'error';
    page = await openPage(390, 'd2');
    await page.locator('[data-b5-panel="c2"] .b5-error').waitFor();
    assert.match(await page.locator('[data-b5-panel="c2"]').innerText(), /錯誤：/); assert.equal(await page.locator('[data-b5-panel="c2"]').getByRole('button', { name: '重新讀取' }).count(), 1);
    await page.screenshot({ path: path.join(screens, 'b5-c2-error-390.png'), fullPage: true }); await page.close();

    // =========================================================================================== 3. Manager C2：批次、限制、Ack、確認摘要
    resetState('Manager', 'prepare');
    page = await openPage(390, 'c2'); panel = page.locator('[data-b5-panel="c2"]');
    await panel.locator('.b5-table tbody tr').first().waitFor();
    assert.equal(await panel.locator('.b5-table tbody tr').count(), 4, 'every software row is listed');
    assert.match(await panel.locator('.b5-incomplete h3').innerText(), /尚未決定的軟體：3 筆/);
    assert.match(await panel.locator('.b5-incomplete').innerText(), /訂單系統執行階段 — ○ 尚未審閱/);
    assert.match(await panel.locator('.b5-incomplete').innerText(), /不含「哪些工作負載會因此無法核准」的判定/, 'the UI states that it does not invent a completeness rule');
    assert.deepEqual(await page.evaluate(() => { const panel = document.querySelector('[data-b5-panel="c2"]'); const title = panel.querySelector('.b5-incomplete'); const table = panel.querySelector('.b5-table'); return [!!(title.compareDocumentPosition(table) & Node.DOCUMENT_POSITION_FOLLOWING)]; }), [true], 'the undecided list sits above the table');
    assert.match(await panel.locator('summary').innerText(), /涵蓋範圍缺口：1 項/);
    assert.match(await panel.locator('.b5-special').innerText(), /套裝本體（特殊產品）：只能選「外部處理」或「不需要搬移」/, 'the special product shows why it is limited');
    await noOverflow(page, 'C2 list'); await noLiveRegions(page, 'C2 list');
    await page.screenshot({ path: path.join(screens, 'b5-c2-list-390.png'), fullPage: true });
    const checkboxFor = name => panel.getByRole('checkbox', { name: `選取 ${name}` });
    await checkboxFor('Microsoft SQL Server Database Engine').check(); await checkboxFor('報表小工具').check();
    assert.match(await panel.locator('.b5-batch').innerText(), /已選 2 筆軟體/);
    assert.match(await panel.locator('.b5-special-note').innerText(), /限制：已選項目含 1 個套裝本體/);
    assert.deepEqual(await panel.locator('#b5-c2-disposition option').evaluateAll(options => options.map(option => option.value)), ['', 'External', 'NotNeeded'], 'a mixed selection offers only the special product dispositions');
    // 只選一般軟體：可選 Reinstall；欄位驗證
    await checkboxFor('Microsoft SQL Server Database Engine').uncheck();
    assert.equal(await panel.locator('.b5-special-note').count(), 0);
    assert.ok((await panel.locator('#b5-c2-disposition option').evaluateAll(options => options.map(option => option.value))).includes('Reinstall'), 'a normal product can be reinstalled');
    await panel.getByRole('button', { name: '套用到已選項目（暫存）' }).click();
    assert.equal(await page.evaluate(() => document.activeElement.id), 'b5-c2-disposition', 'focus goes to the first invalid control');
    for (const id of ['b5-c2-disposition', 'b5-c2-owner', 'b5-c2-reason', 'b5-c2-evidence']) assert.equal(await page.evaluate(id => document.getElementById(id).getAttribute('aria-invalid'), id), 'true', `${id} invalid`);
    assert.equal(count('SoftwareDispositionReviewSubmit'), 0);
    await page.screenshot({ path: path.join(screens, 'b5-c2-batch-errors-390.png'), fullPage: true });
    await panel.locator('#b5-c2-disposition').selectOption('Reinstall'); await panel.locator('#b5-c2-owner').fill('應用程式負責人'); await panel.locator('#b5-c2-reason').fill('需要重新安裝'); await panel.locator('#b5-c2-evidence').fill('change:B5-2');
    await panel.getByRole('button', { name: '套用到已選項目（暫存）' }).click();
    assert.match(await panel.locator('.b5-footer').innerText(), /待送出的處置：1 筆/);
    assert.match(await panel.locator('.b5-table tbody tr').nth(1).innerText(), /➜ 重新安裝/);
    // 特殊產品：只剩外部／不需要
    await checkboxFor('Microsoft SQL Server Database Engine').check();
    assert.deepEqual(await panel.locator('#b5-c2-disposition option').evaluateAll(options => options.map(option => option.value)), ['', 'External', 'NotNeeded']);
    await panel.locator('#b5-c2-disposition').selectOption('NotNeeded');
    await panel.getByRole('button', { name: '套用到已選項目（暫存）' }).click();
    assert.match(await panel.locator('.b5-footer').innerText(), /待送出的處置：2 筆/);
    await page.screenshot({ path: path.join(screens, 'b5-c2-pending-390.png'), fullPage: true });
    // 確認摘要 + Ack
    const submitButton = panel.getByRole('button', { name: '檢視確認摘要並送出' });
    await submitButton.click(); await page.waitForSelector('#b5-confirm-dialog[open]');
    const dialogText = await page.locator('#b5-confirm-dialog').innerText();
    assert.match(dialogText, /重新安裝：1 筆/); assert.match(dialogText, /不需要搬移：1 筆/); assert.match(dialogText, /其中 1 筆為套裝本體/); assert.match(dialogText, /預覽雜湊/);
    assert.equal(await page.locator('#b5-confirm-dialog [data-b5-confirm="accept"]').isDisabled(), true, 'confirm stays disabled until the acknowledgement is ticked');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'b5-confirm-ack', 'the acknowledgement is the first focus target');
    assert.equal(await page.evaluate(() => document.querySelector('label.b5-ack').textContent), '我已核對上述內容，確認送出（Ack）');
    await page.screenshot({ path: path.join(screens, 'b5-c2-confirm-390.png'), fullPage: true });
    await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.querySelector('#b5-confirm-dialog[open]'));
    assert.equal(count('SoftwareDispositionReviewSubmit'), 0, 'Esc sends nothing'); assert.equal(await page.evaluate(() => document.activeElement.textContent), '檢視確認摘要並送出');
    await page.keyboard.press('Enter'); await page.waitForSelector('#b5-confirm-dialog[open]');
    await page.keyboard.press('Space'); assert.equal(await page.locator('#b5-confirm-dialog [data-b5-confirm="accept"]').isDisabled(), false, 'ticking the acknowledgement enables confirm');
    await page.keyboard.press('Tab'); assert.equal(await page.evaluate(() => document.activeElement.textContent), '確認送出'); await page.keyboard.press('Enter');
    await panel.getByText(/完成：已套用 2 筆處置/).waitFor();
    sent = submissions.find(item => item.action === 'SoftwareDispositionReviewSubmit');
    assert.equal(sent.args.Ack, true); assert.equal(sent.args.ExpectedRevision, 10); assert.equal(sent.args.ExpectedPreviewHash, (10).toString(16).padStart(2, '0') + hex('9').slice(0, 62), 'the CAS carries the revision and the preview hash that were reviewed');
    assert.deepEqual(sent.args.Decisions.map(item => [item.SoftwareId, item.Disposition]), [['sw-b', 'Reinstall'], ['sw-c', 'NotNeeded']]);
    assert.equal(sent.expectedDecisionRevision, 10);
    await panel.locator('.b5-incomplete h3').filter({ hasText: '尚未決定的軟體：1 筆' }).waitFor();
    await page.screenshot({ path: path.join(screens, 'b5-c2-applied-390.png'), fullPage: true });
    await noLiveRegions(page, 'C2 applied'); await noOverflow(page, 'C2 applied');
    // 過期：預覽雜湊過期 -> 提示重新讀取，不自動重送，暫存保留
    await checkboxFor('訂單系統執行階段').check(); await panel.locator('#b5-c2-disposition').selectOption('Portable'); await panel.locator('#b5-c2-owner').fill('o'); await panel.locator('#b5-c2-reason').fill('r'); await panel.locator('#b5-c2-evidence').fill('e');
    await panel.getByRole('button', { name: '套用到已選項目（暫存）' }).click();
    failures.set('SoftwareDispositionReviewSubmit', { kind: 'job-stale' });
    await panel.getByRole('button', { name: '檢視確認摘要並送出' }).click(); await page.waitForSelector('#b5-confirm-dialog[open]');
    await page.locator('#b5-confirm-ack').check(); await page.locator('#b5-confirm-dialog [data-b5-confirm="accept"]').click();
    await panel.locator('.b5-footer').getByText(/預覽已過期/).waitFor(); await settle(page, 900);
    assert.equal(count('SoftwareDispositionReviewSubmit'), 2, 'a stale submit is never re-sent automatically');
    assert.match(await panel.locator('.b5-footer').innerText(), /待送出的處置：1 筆/, 'the pending change is kept');
    assert.equal(await panel.locator('.b5-footer').getByRole('button', { name: '檢視確認摘要並送出' }).isDisabled(), true, 'submitting is blocked until the review is re-read');
    await page.screenshot({ path: path.join(screens, 'b5-c2-stale-390.png'), fullPage: true });
    const c2ReadsBefore = viewCalls.filter(item => item.action === 'SoftwareDispositionReview').length;
    await panel.getByRole('button', { name: '重新讀取' }).first().click();
    await page.waitForFunction(count => window.WsmConsole.b5.c2.loading === false && window.WsmConsole.b5.c2.stale === false, 0);
    assert.equal(viewCalls.filter(item => item.action === 'SoftwareDispositionReview').length, c2ReadsBefore + 1);
    assert.equal(count('SoftwareDispositionReviewSubmit'), 2, 'reloading does not submit'); assert.equal(await panel.locator('.b5-footer').getByRole('button', { name: '檢視確認摘要並送出' }).isDisabled(), false);
    await page.close();
    // =========================================================================================== 3b. R26-D14b／R26-1e：Stale 預填、Unknown 處置另列
    resetState('Manager', 'prepare');
    c2Rows.push(software('sw-s', '過期審閱軟體', { DecisionState: 'Stale', DecisionSoftwareHash: hex('0'), Disposition: 'Portable', Owner: '前任負責人', Reason: '前次原因', Evidence: 'change:old-1' }));
    c2Rows.push(software('sw-u', '暫記未確認軟體', { DecisionState: 'Reviewed', Disposition: 'Unknown', Owner: 'o', Reason: 'r', Evidence: 'e' }));
    page = await openPage(390, 'c2'); panel = page.locator('[data-b5-panel="c2"]');
    await panel.locator('.b5-table tbody tr').first().waitFor();
    const rowText = async name => panel.locator('.b5-table tbody tr', { hasText: name }).first().innerText();
    assert.match(await rowText('暫記未確認軟體'), /已暫記未確認/, 'an Unknown disposition is listed as provisionally recorded');
    assert.doesNotMatch(await rowText('暫記未確認軟體'), /已審閱/, 'an Unknown disposition is never shown as reviewed');
    assert.match(await rowText('排程輔助程式'), /✔ 已審閱：外部處理/, 'a real disposition still reads as reviewed');
    assert.match(await rowText('過期審閱軟體'), /⚠ 證據已變更，需重新審閱/);
    const staleBox = panel.getByRole('checkbox', { name: '選取 過期審閱軟體' });
    // 未選 Stale 列：表單空白
    assert.equal(await panel.locator('#b5-c2-owner').inputValue(), '');
    await staleBox.check();
    assert.equal(await panel.locator('#b5-c2-disposition').inputValue(), 'Portable', 'D14b: the previous disposition is prefilled');
    assert.equal(await panel.locator('#b5-c2-owner').inputValue(), '前任負責人'); assert.equal(await panel.locator('#b5-c2-reason').inputValue(), '前次原因'); assert.equal(await panel.locator('#b5-c2-evidence').inputValue(), 'change:old-1');
    assert.match(await panel.locator('.b5-batch').innerText(), /已帶入前次的處置與說明/, 'the prefill is announced as a draft to be reviewed');
    assert.equal(count('SoftwareDispositionReviewSubmit'), 0, 'prefilling submits nothing');
    assert.equal(await panel.locator('.b5-footer').innerText().then(t => /待送出的處置：0 筆/.test(t)), true, 'prefilling stages nothing');
    assert.match(await rowText('過期審閱軟體'), /⚠ 證據已變更，需重新審閱/, 'the stale marker stays until the user submits');
    await noOverflow(page, 'C2 prefill');
    await page.screenshot({ path: path.join(screens, 'b5-c2-prefill-390.png'), fullPage: true });
    // 取消選取：自動帶入的值一併清掉；使用者改過的值不被覆蓋
    await staleBox.uncheck();
    assert.equal(await panel.locator('#b5-c2-owner').inputValue(), '', 'an untouched prefill is cleared when the stale row is deselected');
    const reviewedBox = panel.getByRole('checkbox', { name: '選取 排程輔助程式' }); await reviewedBox.check();
    assert.equal(await panel.locator('#b5-c2-owner').inputValue(), '', 'only Stale rows are prefilled; a Reviewed row leaves the form blank'); await reviewedBox.uncheck();
    await staleBox.check(); await panel.locator('#b5-c2-reason').fill('我改過的原因');
    await panel.getByRole('checkbox', { name: '選取 報表小工具' }).check();
    assert.equal(await panel.locator('#b5-c2-reason').inputValue(), '我改過的原因', 'user input is never overwritten by a later prefill');
    // 套用仍需使用者操作：暫存後才進待送出，送出另需 Ack
    await panel.getByRole('checkbox', { name: '選取 報表小工具' }).uncheck();
    await panel.getByRole('button', { name: '套用到已選項目（暫存）' }).click();
    assert.match(await panel.locator('.b5-footer').innerText(), /待送出的處置：1 筆/);
    assert.equal(count('SoftwareDispositionReviewSubmit'), 0, 'staging a prefilled row still submits nothing');
    await page.close();

    // =========================================================================================== 3c. R26-S17b：其他工作區位置的紀錄只供檢視
    resetState('Manager', 'prepare');
    const jobBase = { action: 'SetMigrationSpec', status: 'Running', role: 'Manager', pairId, startedUtc: '2026-10-22T00:00:00Z', outputs: [], canCancel: true, reportArtifacts: [{ Label: '測試報告', SHA256: hex('a'), Kind: 'File' }] };
    jobs.set('own-job-1', Object.assign({ jobId: 'own-job-1', operationId: 'own-job-1', workspace: 'C:\fixture\manager', foreignWorkspace: false }, jobBase));
    jobs.set('foreign-job-1', Object.assign({ jobId: 'foreign-job-1', operationId: 'foreign-job-1', workspace: 'D:\moved\workspace', foreignWorkspace: true }, jobBase));
    page = await openPage(390, 'c2');
    // R26-1d：console.js 帶 UTF-8 BOM 送出時，瀏覽器照常執行腳本（WsmConsole 存在）、BOM 不會出現在畫面文字或任何文字節點。
    const bomProbe = await page.evaluate(async () => { const bytes = new Uint8Array(await (await fetch('/ui/console.js')).arrayBuffer()); return { head: Array.from(bytes.slice(0, 3)), running: typeof window.WsmConsole === 'object', screenHasBom: document.documentElement.textContent.includes(String.fromCharCode(0xFEFF)) || document.body.innerText.includes(String.fromCharCode(0xFEFF)) }; });
    assert.deepEqual(bomProbe.head, [239, 187, 191], 'console.js is served with its UTF-8 BOM'); assert.equal(bomProbe.running, true, 'the BOM does not stop the script'); assert.equal(bomProbe.screenHasBom, false, 'the BOM never reaches the screen');
    await page.evaluate(() => { location.hash = '#jobs'; });
    await page.waitForSelector('#job-list .job-card[data-foreign-workspace="true"]');
    const cards = page.locator('#job-list .job-card'), foreignCard = page.locator('#job-list .job-card[data-foreign-workspace="true"]'), ownCard = cards.filter({ hasText: 'own-job-1' });
    assert.equal(await cards.count(), 2, 'the listing is not filtered: the foreign record is still shown');
    assert.match(await foreignCard.innerText(), /此紀錄來自其他工作區位置（可能是搬移或竄改）/, 'S17b: the foreign record is marked');
    assert.equal(await foreignCard.locator('button').count(), 0, 'S17b: a foreign record offers no executable action (cancel/open/reconnect/resume/takeover)');
    assert.equal(await ownCard.getByRole('button', { name: '要求取消' }).count(), 1, 'a record of this workspace keeps its cancel action');
    assert.equal(await ownCard.getByRole('button', { name: /開啟報告/ }).count(), 1, 'a record of this workspace keeps its report action');
    assert.equal(await foreignCard.getByRole('button', { name: /取消|開啟|重新連線|續作|接手/ }).count(), 0);
    await noOverflow(page, 'foreign job card 390'); await page.screenshot({ path: path.join(screens, 'r261-foreign-job-390.png'), fullPage: true });
    await page.setViewportSize({ width: 320, height: 800 }); await noOverflow(page, 'foreign job card 320');
    // 鍵盤：Tab 走訪整個工作清單，不會停在外來紀錄的任何控制項上
    await page.evaluate(() => document.querySelector('#job-list').scrollIntoView());
    const foreignFocusable = await foreignCard.evaluate(card => card.querySelectorAll('button,a[href],input,select,textarea,[tabindex]:not([tabindex="-1"])').length);
    assert.equal(foreignFocusable, 0, 'the foreign card has nothing to focus');
    // 進度卡不選外來紀錄（同配對的外來備份工作不能出現進度與取消鈕）；自己的備份工作是對照組，必須顯示。
    const backupJob = (id, workspace, foreignWorkspace) => ({ jobId: id, operationId: id, action: 'StartBackup', status: 'Running', role: 'Manager', pairId, workspace, foreignWorkspace, canCancel: true, startedUtc: '2026-10-22T00:00:00Z', outputs: [], progress: { percent: 40, backup: { stage: 'Running', percent: 40 } } });
    const refreshToWizard = async () => { await page.evaluate(async () => { await window.WsmConsole.refreshJobs(); location.hash = '#wizard'; }); await page.waitForTimeout(400); };
    const progressVisible = () => page.evaluate(() => { const card = document.querySelector('[data-progress-card="wizard"]'); return !!card && !card.hidden; });
    jobs.set('foreign-backup', backupJob('foreign-backup', 'D:\moved\workspace', true)); await refreshToWizard();
    assert.equal(await page.evaluate(() => window.WsmConsole.state.jobs.get('foreign-backup').foreignWorkspace), true, 'the console keeps the server-decided flag');
    assert.equal(await progressVisible(), false, 'S17b: a foreign backup record never drives the progress card');
    jobs.set('own-backup', backupJob('own-backup', 'C:\fixture\manager', false)); await refreshToWizard();
    assert.equal(await progressVisible(), true, 'control: a backup record of this workspace does drive the progress card');
    await page.close();

    // 桌面寬度截圖與 empty / loading
    resetState('Manager', 'prepare');
    page = await openPage(1280, 'c2'); await page.locator('[data-b5-panel="c2"] .b5-table tbody tr').first().waitFor();
    await noOverflow(page, 'C2 desktop'); await page.screenshot({ path: path.join(screens, 'b5-c2-list-1280.png'), fullPage: true }); await page.close();
    resetState('Manager', 'prepare'); viewMode = 'empty';
    page = await openPage(390, 'c2'); await page.locator('[data-b5-panel="c2"]').getByText('尚無資料：來源軟體清單是空的。').waitFor(); await page.screenshot({ path: path.join(screens, 'b5-c2-empty-390.png'), fullPage: true }); await page.close();
    resetState('Manager', 'prepare'); viewDelayMs = 700;
    page = await openPage(390, 'c2', 'domcontentloaded'); await page.locator('[data-b5-panel="c2"]').getByText('讀取中：正在讀取軟體處置審閱').waitFor(); await page.screenshot({ path: path.join(screens, 'b5-c2-loading-390.png'), fullPage: true });
    await page.locator('[data-b5-panel="c2"] .b5-table tbody tr').first().waitFor(); await page.close();

    // 瀏覽器會把刻意回傳的 400／409 記成「Failed to load resource」；只扣掉替身刻意送出的次數，其餘任何 console／頁面錯誤都算失敗。
    const resourceErrors = errors.filter(item => /^console: Failed to load resource: the server responded with a status of (400|409)/.test(item));
    assert.equal(resourceErrors.length, deliberateHttpErrors, 'only the deliberately served 400/409 responses were logged by the browser');
    const unexpected = errors.filter(item => !resourceErrors.includes(item));
    if (unexpected.length) console.error('errors:', JSON.stringify(unexpected, null, 1));
    assert.deepEqual(unexpected, [], 'zero other console errors and page errors');
    console.log('PASS Test-C2D2Browser: source/manager D2 flow, C2 batch, CAS, stale handling, keyboard confirmation, states, 390px layout and zero console errors.');
  } finally {
    if (browser) await browser.close();
    server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
