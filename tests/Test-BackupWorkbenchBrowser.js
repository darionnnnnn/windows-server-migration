// Real-browser (Edge) test for the workbench "backup results" page (B2): result-set v2 columns, the independent-copy
// column states, filters stacked with search, URL-hash state, file drill-down (loading / error / empty / paging),
// uncovered regions, CSV parity with the offline report, cross-screen consistency, 390px layout and console errors.
// The UI under test is the real src/ui files; only the local API is replaced by a fixture built from the real result-set code.
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const screens = path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });

function buildFixture(shape, scale) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-b2-' + shape.toLowerCase() + (scale ? '-' + scale.toLowerCase() : '') + '-'));
  const run = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tests', 'New-OfflineReportFixture.ps1'), '-OutDir', dir, '-Shape', shape].concat(scale ? ['-Scale', scale] : []), { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  assert.equal(run.status, 0, 'fixture build failed: ' + run.stderr);
  const results = JSON.parse(fs.readFileSync(path.join(dir, 'backup-item-results.json'), 'utf8').replace(/^\ufeff/, ''));
  return { dir, report: path.join(dir, 'backup-report.html'), results };
}
const fileUrl = file => 'file:///' + file.replace(/\\/g, '/');

function parseCsv(text) {
  const rows = []; let row = [], cell = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) { if (ch === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else quoted = false; } else cell += ch; }
    else if (ch === '"') quoted = true;
    else if (ch === ',') { row.push(cell); cell = ''; }
    else if (ch === '\r' && text[i + 1] === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; i++; }
    else cell += ch;
  }
  assert.equal(cell, '', 'CSV must end with CRLF'); assert.equal(row.length, 0, 'CSV must end with CRLF');
  return rows;
}
async function captureCsv(page, scope) {
  await page.evaluate(() => { window.__blobs = []; });
  await scope.getByRole('button', { name: '匯出 CSV' }).first().click();
  const bytes = await page.evaluate(async () => { const blob = window.__blobs.pop(); return Array.from(new Uint8Array(await blob.arrayBuffer())); });
  const buffer = Buffer.from(bytes);
  assert.deepEqual([...buffer.subarray(0, 3)], [0xEF, 0xBB, 0xBF], 'CSV must start with a UTF-8 BOM');
  const text = buffer.subarray(3).toString('utf8');
  assert.ok(!/(^|[^\r])\n/.test(text), 'CSV line breaks must be CRLF only');
  return parseCsv(text);
}
const blobCapture = () => { window.__blobs = []; const original = URL.createObjectURL; URL.createObjectURL = function (blob) { window.__blobs.push(blob); return original.call(URL, blob); }; };

// ---- static server for the real UI files ----
const staticFiles = new Map([['/', 'index.html'], ['/ui/index.html', 'index.html'], ['/ui/console.js', 'console.js'], ['/ui/console.css', 'console.css'], ['/ui/guide.html', 'guide.html'], ['/ui/nonc.js', 'nonc.js']]);
const server = http.createServer((request, response) => {
  const name = staticFiles.get(new URL(request.url, 'http://127.0.0.1').pathname);
  if (!name) { response.writeHead(404); response.end('Not found'); return; }
  const file = path.join(root, 'src', 'ui', name);
  response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' });
  fs.createReadStream(file).pipe(response);
});

// ---- fixture API ----
const RESTORE_LABEL = { Restorable: '可還原', RequiresPrerequisite: '需前置條件', ManualOnly: '僅人工處理', NotApplicable: '不適用' };
const COPY_STATES = {
  verified: { state: 'Verified', text: '已驗證', verifiedUtc: '2026-10-22T08:30:00Z', networkUnconfirmed: false, reason: '' },
  notVerified: { state: 'NotVerified', text: '尚未驗證', verifiedUtc: '', networkUnconfirmed: false, reason: '尚未建立並驗證獨立副本。' },
  unverifiable: { state: 'Unverifiable', text: '收據無法核對', verifiedUtc: '', networkUnconfirmed: false, reason: '收據檔內容與備份紀錄的雜湊不一致。' }
};
function filesFor(itemId, page) {
  const pageSize = 100;
  let total = 250;
  if (itemId === 'item-0002') total = 2;
  if (itemId === 'item-0008') total = 0;
  const entries = [];
  for (let i = (page - 1) * pageSize; i < Math.min(total, page * pageSize); i++) {
    const isDirectory = total === 250 && i % 100 === 99;
    entries.push({ RelativePath: isDirectory ? `dir${Math.floor(i / 50)}\\empty` : `dir${Math.floor(i / 50)}\\file-${String(i).padStart(3, '0')}.dat`, Bytes: isDirectory ? 0 : 1000 + i, Sha256Prefix: isDirectory ? '' : (i.toString(16).padStart(2, '0') + 'ab').repeat(3).slice(0, 12), IsDirectory: isDirectory });
  }
  return { kind: 'BackupItemFiles', available: true, AttemptId: 'fixture-attempt', ItemId: itemId, Page: page, PageSize: pageSize, TotalCount: total, DirectoryCount: total === 250 ? 2 : 0, PageCount: Math.max(1, Math.ceil(total / pageSize)), Entries: entries };
}

async function openWorkbench(browser, fixture, scenario, hash, contextOptions) {
  const context = await browser.newContext(Object.assign({ viewport: { width: 1280, height: 900 } }, contextOptions || {}));
  await context.addInitScript(blobCapture);
  const page = await context.newPage();
  const errors = [], fileRequests = [], gates = {}, calls = { itemFailuresLeft: scenario.failFirstFilesFor ? 1 : 0 };
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  const session = { token: 'memory-only-test-token', sessionId: 'fixture-session', contextId: 'fixture-context', hostName: 'fixture-host', role: 'Source', workspace: root, pairId: 'fixture-pair', revision: 5, decisionRevision: 7, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: 'fixture-data-1', principal: 'fixture-user' };
  const viewContext = () => ({ sessionId: session.sessionId, contextId: session.contextId, pairId: 'fixture-pair', role: 'Source', revision: session.revision, decisionRevision: session.decisionRevision, selectionRevision: session.selectionRevision, sourceSelectionRevision: session.sourceSelectionRevision, dataVersion: session.dataVersion, readUtc: new Date().toISOString() });
  const results = scenario.results;
  const view = () => ({ kind: 'BackupItemResultsView', available: true, integrity: 'Verified', attemptId: 'fixture-attempt', backupOperationId: 'fixture-op', generatedUtc: results.GeneratedUtc, inventorySource: results.InventorySource, offlineReadiness: 'AwaitingIndependentCopy', counts: results.Counts, rows: results.Rows, software: results.Software, schemaVersion: results.SchemaVersion || 1, coverageRegions: Object.prototype.hasOwnProperty.call(results, 'CoverageRegions') ? results.CoverageRegions : null, excludedRegions: Object.prototype.hasOwnProperty.call(results, 'ExcludedRegions') ? results.ExcludedRegions : null, excludedRegionsBinding: Object.prototype.hasOwnProperty.call(results, 'ExcludedRegionsBinding') ? results.ExcludedRegionsBinding : null, excludedCompleteness: Object.prototype.hasOwnProperty.call(results, 'ExcludedCompleteness') ? results.ExcludedCompleteness : null, independentCopy: scenario.copy, viewContext: viewContext() });
  await page.route(/\/api\/.*/, async route => {
    const request = route.request(), parsed = new URL(request.url()), pathname = parsed.pathname;
    const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (pathname === '/api/session') return json(session);
    if (pathname === '/api/context' && request.method() === 'GET') return json({ roles: ['Source'], pairs: [{ pairId: 'fixture-pair', label: 'Fixture pair' }], role: 'Source', pairId: 'fixture-pair', revision: session.revision, decisionRevision: session.decisionRevision, selectionRevision: session.selectionRevision, sourceSelectionRevision: session.sourceSelectionRevision, dataVersion: session.dataVersion });
    if (pathname === '/api/wizard') return json({ kind: 'WizardProjection', intentRequired: false, legacy: false, role: 'Source', workspaceRole: 'Source', roleMatchesWorkspace: true, pairId: 'fixture-pair', state: { CurrentStep: 'backup', Mode: 'ItemByItem' }, revision: session.revision, currentStep: 'backup', reviewGroupIndex: 0, groups: [], gates: [], actions: [], missingFields: [], scan: { status: 'Succeeded', hasResult: true, itemCount: 3, incompleteCount: 0 }, results: { scan: { status: 'Succeeded', hasDurableRecord: true }, backup: { status: 'Succeeded', hasDurableRecord: true }, restore: { status: 'NotStarted', hasDurableRecord: false }, hasAny: true }, context: { catalogRevision: 7, selectionRevision: 3, inventoryRevision: 1 } });
    if (pathname === '/api/wizard/runtime') return json({ Kind: 'WizardRuntimeProjection', Role: 'Source', PairId: 'fixture-pair', actions: [], viewContext: viewContext() });
    if (pathname === '/api/wizard/nonc') return json({ Kind: 'WizardNonCProjection', Role: 'Source', PairId: 'fixture-pair', ContextId: session.contextId, DataVersion: session.dataVersion });
    if (pathname === '/api/jobs' && request.method() === 'GET') return json({ items: [{ jobId: 'fixture-backup-job', workspace: root, pairId: 'fixture-pair', role: 'Source', sessionId: 'fixture-session', contextId: 'fixture-context', startedRevision: 5, action: 'StartBackup', status: 'Succeeded', canCancel: false }] });
    if (pathname === '/api/view' && request.method() === 'GET') {
      if (parsed.searchParams.get('contextId') !== session.contextId || parsed.searchParams.get('dataVersion') !== session.dataVersion) return json({ code: 'stale_revision', message: 'Fixture view changed.', nextStep: 'Reload.', correlationId: 'fixture-stale' }, 409);
      if (parsed.searchParams.get('action') === 'backup-items') {
        if (scenario.delayView) await scenario.delayView;
        if (scenario.viewError) return json({ code: 'package_changed', message: '備份明細暫時無法讀取。', nextStep: '稍後重試。', correlationId: 'fixture-view-error' });
        if (scenario.failedAttempt) return json({ kind: 'BackupItemResultsView', available: false, reason: '目前還沒有已交付的備份。', failedAttempt: scenario.failedAttempt, viewContext: viewContext() });
        return json(view());
      }
      return json({ viewContext: viewContext(), rows: [], items: [] });
    }
    if (pathname === '/api/view' && request.method() === 'POST') {
      const body = request.postDataJSON();
      if (body.action !== 'BackupItemFiles') return json({ code: 'unknown_action', message: 'Unexpected fixture action.', nextStep: 'None.', correlationId: 'fixture-unknown' });
      assert.deepEqual(Object.keys(body.args).sort(), ['ItemId', 'Page'], 'drill-down must send only ItemId and Page');
      fileRequests.push({ itemId: body.args.ItemId, page: body.args.Page });
      if (body.args.ItemId === 'item-0011' && gates.item11) await gates.item11.promise;
      if (body.args.ItemId === 'item-0002' && calls.itemFailuresLeft > 0) { calls.itemFailuresLeft--; return json({ code: 'package_changed', message: '封存套件已變更，無法核驗。', nextStep: '重新備份後再查看。', correlationId: 'fixture-files-error' }); }
      return json(filesFor(body.args.ItemId, body.args.Page));
    }
    errors.push(`unhandled fixture route ${request.method()} ${pathname}`);
    return json({ message: `Unhandled fixture route ${request.method()} ${pathname}` }, 404);
  });
  await page.goto(`http://127.0.0.1:${server.address().port}/${hash}`, { waitUntil: 'domcontentloaded' });
  return { page, context, errors, fileRequests, gates };
}
const gate = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };
const waitResults = async page => { await page.waitForSelector('#backup-item-results [role=tablist]', { timeout: 30000 }); };

(async () => {
  const fixture = buildFixture('V2'), legacyFixture = buildFixture('V1');
  await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
  const browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
  const allErrors = [], extraDirs = [];
  const rows = fixture.results.Rows, backedRows = rows.filter(r => r.Status === 'BackedUp'), pendingRows = rows.filter(r => r.Status === 'NotBackedUp');
  assert.ok(rows.length > 250 && backedRows.length > 100 && pendingRows.length > 100, 'fixture must exceed one page in both tabs');
  const base = { results: fixture.results, copy: COPY_STATES.notVerified };
  try {
    // ================= A. backed tab: v2 columns, copy column, filters =================
    {
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, copy: COPY_STATES.verified }, '#jobs?filter=backup');
      await waitResults(page);
      const backed = page.locator('#backup-panel-backed');
      const headers = await backed.locator('thead th').allInnerTexts();
      assert.deepEqual(headers, ['名稱', '類型', '工作負載', '原位置', '通道', '檔案數', '大小', '狀態', '可還原條件', '獨立副本', '檔案明細']);
      assert.ok((await backed.innerText()).includes('只表示備份可取用') && (await backed.innerText()).includes('不授權關閉舊機'), 'page head must say the column does not authorise shutting down the old machine');
      const firstRow = backed.locator('tbody tr[data-id]').first();
      const rowText = await firstRow.innerText();
      assert.ok(rowText.includes('已驗證') && rowText.includes('2026'), 'verified rows must show the verified text and the receipt time: ' + rowText);
      // workloads: unrelated item shows 未關聯; the XSS-named workload is shown as text only
      assert.ok((await backed.locator('tbody').innerText()).includes('未關聯'));
      assert.equal(await backed.locator('tbody img').count(), 0, 'workload names must never become markup');
      // a status is never colour only: every badge carries an icon + text
      const badges = await backed.locator('.backup-badge').evaluateAll(list => list.map(b => ({ text: b.textContent.trim(), icon: b.dataset.icon })));
      assert.ok(badges.length > 0 && badges.every(b => b.text && b.icon), 'every badge needs text and an icon');
      // single status element per table, named focusable region
      assert.equal(await backed.locator('[role=status][aria-atomic=true]').count(), 1, 'exactly one count status element');
      assert.equal(await backed.locator('.table-wrap[role=region][tabindex="0"]').count() >= 1, true);
      const status = backed.locator('[role=status][aria-atomic=true]');
      assert.equal(await status.innerText(), `顯示 ${backedRows.length}／共 ${backedRows.length} 筆`);

      // filters: native select with visible label
      for (const name of ['類型', '可還原條件', '獨立副本', '搜尋名稱或位置']) assert.equal(await backed.getByLabel(name).count(), 1, name + ' must be a labelled control');
      assert.equal(await backed.locator('select').count(), 3);
      assert.equal(await backed.locator('label:visible').filter({ hasText: '類型' }).count(), 1, 'labels must be visible');
      const typeSelect = backed.getByLabel('類型'), restoreSelect = backed.getByLabel('可還原條件'), copySelect = backed.getByLabel('獨立副本'), search = backed.getByLabel('搜尋名稱或位置');
      const kinds = [...new Set(backedRows.map(r => r.Kind))];
      assert.deepEqual((await typeSelect.locator('option').allInnerTexts()).slice(1).sort(), kinds.sort());
      const serviceCount = backedRows.filter(r => r.Kind === 'Service').length;
      await typeSelect.selectOption('Service');
      assert.equal(await status.innerText(), `顯示 ${serviceCount}／共 ${backedRows.length} 筆`);
      // stacked with search: Service rows whose name/location contain item-01
      await search.fill('item-01');
      const stacked = backedRows.filter(r => r.Kind === 'Service' && (`${r.Name}\n${r.Location}`).toLowerCase().includes('item-01')).length;
      assert.ok(stacked > 0 && stacked < serviceCount, 'search+type fixture must narrow the list');
      assert.equal(await status.innerText(), `顯示 ${stacked}／共 ${backedRows.length} 筆`);
      await search.fill(''); await typeSelect.selectOption('');
      // restore condition filter
      const restoreCode = 'RequiresPrerequisite';
      const restoreCount = backedRows.filter(r => r.RestoreCondition.Code === restoreCode).length;
      assert.ok(restoreCount > 0);
      await restoreSelect.selectOption({ label: RESTORE_LABEL[restoreCode] });
      assert.equal(await status.innerText(), `顯示 ${restoreCount}／共 ${backedRows.length} 筆`);
      assert.ok((await backed.locator('tbody tr[data-id] td:nth-child(9)').allInnerTexts()).every(t => t.includes(RESTORE_LABEL[restoreCode])));
      await restoreSelect.selectOption('');
      // copy filter (set-level state: all rows verified)
      await copySelect.selectOption('NotVerified');
      assert.equal(await status.innerText(), `顯示 0／共 ${backedRows.length} 筆`);
      assert.ok((await backed.innerText()).includes('沒有符合搜尋或篩選條件的項目'));
      await copySelect.selectOption('Verified');
      assert.equal(await status.innerText(), `顯示 ${backedRows.length}／共 ${backedRows.length} 筆`);
      await copySelect.selectOption('');
      // three filters + search stacked
      await typeSelect.selectOption('Service'); await restoreSelect.selectOption('RequiresPrerequisite'); await copySelect.selectOption('Verified'); await search.fill('item-01');
      assert.equal(await status.innerText(), `顯示 ${stacked}／共 ${backedRows.length} 筆`);
      await page.screenshot({ path: path.join(screens, 'b2-desktop-backed-filtered.png') });
      assert.deepEqual(errors, []);
      await page.context().close();
    }

    // ================= B. independent copy states: never "verified" unless the receipt checks out =================
    for (const [key, expectedText] of [['notVerified', '尚未驗證'], ['unverifiable', '收據無法核對']]) {
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, copy: COPY_STATES[key] }, '#jobs?filter=backup');
      await waitResults(page);
      const backed = page.locator('#backup-panel-backed');
      const copyCells = await backed.locator('tbody tr[data-id] td:nth-child(10)').allInnerTexts();
      assert.ok(copyCells.length >= 100 && copyCells.every(t => t.trim() === expectedText), `${key}: every row must read "${expectedText}"`);
      assert.ok(!(await backed.locator('tbody').innerText()).includes('已驗證'), `${key}: table must not contain "已驗證"`);
      if (key === 'unverifiable') {
        assert.ok((await backed.innerText()).includes('整欄不顯示為已驗證') && (await backed.innerText()).includes('雜湊不一致'), 'unverifiable receipt needs an explanation');
        await page.screenshot({ path: path.join(screens, 'b2-desktop-receipt-unverifiable.png') });
      }
      assert.deepEqual(errors, []);
      await page.context().close();
    }

    // ================= C. pending tab: type/reason filters, PermissionDenied from the result set, coverage regions =================
    {
      const { page, errors } = await openWorkbench(browser, fixture, base, '#jobs?filter=backup&tab=pending');
      await waitResults(page);
      const pending = page.locator('#backup-panel-pending');
      assert.equal(await page.locator('#backup-tab-pending').getAttribute('aria-selected'), 'true');
      assert.deepEqual(await pending.locator('#backup-pending-table thead th, table thead th').allInnerTexts().then(t => t.slice(0, 8)), ['名稱', '類型', '工作負載', '原位置', '原因', '下一步', '盤點狀態', '狀態']);
      assert.equal(await pending.getByRole('button', { name: /檔案明細/ }).count(), 0, 'pending rows have no file drill-down');
      const status = pending.locator('[role=status][aria-atomic=true]').first();
      assert.equal(await status.innerText(), `顯示 ${pendingRows.length}／共 ${pendingRows.length} 筆`);
      const reasonSelect = pending.getByLabel('原因'), typeSelect = pending.getByLabel('類型'), search = pending.getByLabel('搜尋名稱或位置');
      const denied = pendingRows.find(r => r.ReasonCode === 'PermissionDenied');
      assert.ok(denied && denied.Reason && denied.NextStep, 'the result set must carry PermissionDenied with its reason and next step');
      assert.ok((await reasonSelect.locator('option').allInnerTexts()).includes(denied.Reason), 'reason text must come from the result set');
      await reasonSelect.selectOption({ label: denied.Reason });
      const deniedRows = pendingRows.filter(r => r.ReasonCode === 'PermissionDenied');
      assert.equal(await status.innerText(), `顯示 ${deniedRows.length}／共 ${pendingRows.length} 筆`);
      assert.ok((await pending.locator('tbody tr[data-id]').first().innerText()).includes(denied.NextStep), 'next step must be shown from the result set');
      await reasonSelect.selectOption(''); await typeSelect.selectOption('DataRoot'); await search.fill('item-02');
      const stacked = pendingRows.filter(r => r.Kind === 'DataRoot' && `${r.Name}\n${r.Location}`.toLowerCase().includes('item-02')).length;
      assert.equal(await status.innerText(), `顯示 ${stacked}／共 ${pendingRows.length} 筆`);
      await reasonSelect.selectOption('Excluded');
      const excludedStacked = pendingRows.filter(r => r.Kind === 'DataRoot' && r.ReasonCode === 'Excluded' && `${r.Name}\n${r.Location}`.toLowerCase().includes('item-02')).length;
      assert.equal(await status.innerText(), `顯示 ${excludedStacked}／共 ${pendingRows.length} 筆`);
      await reasonSelect.selectOption(''); await typeSelect.selectOption(''); await search.fill('');
      // uncovered regions: data
      const region = pending.locator('.backup-coverage');
      assert.equal(await region.getAttribute('data-coverage'), 'data');
      assert.ok((await pending.innerText()).includes('探索未涵蓋區域（以區域列出，不是項目）'));
      assert.ok((await region.innerText()).includes('Uninstall'));
      assert.equal(await region.locator('.table-wrap[role=region][tabindex="0"]').count(), 1);
      await page.screenshot({ path: path.join(screens, 'b2-desktop-pending.png') });
      assert.deepEqual(errors, []);
      await page.context().close();
    }
    // coverage: empty set (recorded, nothing uncovered) and legacy set (not recorded) are different messages
    {
      const emptyResults = { ...fixture.results, CoverageRegions: [] };
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, results: emptyResults }, '#jobs?filter=backup&tab=pending');
      await waitResults(page);
      const region = page.locator('#backup-panel-pending .backup-coverage');
      assert.equal(await region.getAttribute('data-coverage'), 'empty');
      assert.equal((await region.innerText()).trim(), '沒有記錄到未涵蓋區域');
      assert.deepEqual(errors, []); await page.context().close();
    }
    {
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, results: legacyFixture.results }, '#jobs?filter=backup');
      await waitResults(page);
      const backed = page.locator('#backup-panel-backed');
      const first = backed.locator('tbody tr[data-id]').first();
      const cells = await first.locator('td').allInnerTexts();
      assert.equal(cells[2], '未記錄', 'legacy workload'); assert.equal(cells[8].trim(), '未記錄', 'legacy restore condition');
      assert.ok((await backed.getByLabel('可還原條件').locator('option').allInnerTexts()).includes('未記錄'));
      await page.locator('#backup-tab-pending').click();
      const region = page.locator('#backup-panel-pending .backup-coverage');
      assert.equal(await region.getAttribute('data-coverage'), 'legacy');
      assert.equal((await region.innerText()).trim(), '此結果集未記錄');
      assert.ok(!(await region.innerText()).includes('沒有記錄到未涵蓋區域'), 'legacy must not look like an empty recorded set');
      await page.screenshot({ path: path.join(screens, 'b2-desktop-legacy-pending.png') });
      assert.deepEqual(errors, []); await page.context().close();
    }

    // N3: excluded regions (BundleExcluded / ProtectedArea) in the pending panel: own table, filter, search, CSV; never item rows.
    {
      const { page, errors } = await openWorkbench(browser, fixture, base, '#jobs?filter=backup&tab=pending');
      await waitResults(page);
      const pending = page.locator('#backup-panel-pending'), excludedExpected = fixture.results.ExcludedRegions;
      const region = pending.locator('.backup-excluded');
      assert.equal(await region.getAttribute('data-excluded'), 'data');
      assert.ok((await pending.innerText()).includes('套裝本體與受保護區域（依政策不納入備份；以區域列出，不是項目）'));
      assert.deepEqual(await region.locator('thead th').allInnerTexts(), ['區域', '原因', '下一步']);
      const regionStatus = region.locator('[role=status][aria-atomic=true]');
      assert.equal(await regionStatus.innerText(), `顯示 ${excludedExpected.length}／共 ${excludedExpected.length} 筆`);
      const bundle = excludedExpected.find(r => r.ReasonCode === 'BundleExcluded'), protectedArea = excludedExpected.find(r => r.ReasonCode === 'ProtectedArea');
      assert.ok(bundle.Reason.includes('套裝軟體本體') && bundle.NextStep.includes('重新安裝') && protectedArea.Reason.includes('受保護區域'));
      const regionSelect = region.getByLabel('區域類別');
      const options = await regionSelect.locator('option').allInnerTexts();
      assert.ok(options.includes(bundle.Reason) && options.includes(protectedArea.Reason), 'both new reasons must be filter options with their Chinese text');
      await regionSelect.selectOption('BundleExcluded');
      assert.equal(await regionStatus.innerText(), `顯示 ${excludedExpected.filter(r => r.ReasonCode === 'BundleExcluded').length}／共 ${excludedExpected.length} 筆`);
      assert.ok((await region.locator('tbody tr').first().innerText()).includes(bundle.NextStep), 'the next step must be shown');
      assert.equal(await region.locator('tbody tr[data-reason="BundleExcluded"]').count(), await region.locator('tbody tr').count());
      await regionSelect.selectOption('');
      await region.getByLabel('搜尋區域路徑').fill('config.msi');
      assert.equal(await regionStatus.innerText(), `顯示 1／共 ${excludedExpected.length} 筆`);
      await region.getByLabel('搜尋區域路徑').fill('');
      const regionCsv = await captureCsv(page, region);
      assert.deepEqual(regionCsv[0], ['區域', '原因', '下一步', '原因碼']);
      assert.equal(regionCsv.length - 1, excludedExpected.length);
      await regionSelect.selectOption('ProtectedArea');
      const protectedCsv = await captureCsv(page, region);
      assert.equal(protectedCsv.length - 1, excludedExpected.filter(r => r.ReasonCode === 'ProtectedArea').length);
      assert.ok(protectedCsv.slice(1).every(r => r[3] === 'ProtectedArea'));
      await regionSelect.selectOption('');
      assert.equal(await pending.locator('tbody tr[data-id]').count(), 100, 'regions must not add item rows (first item page is still 100 rows)');
      await region.locator('table').scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(screens, 'n3-workbench-excluded-regions.png') });
      assert.deepEqual(errors, []); await page.context().close();
    }
    // excluded regions: recorded-but-empty, binding not verified (null) and legacy results are three different messages
    {
      const emptyResults = { ...fixture.results, ExcludedRegions: [] };
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, results: emptyResults }, '#jobs?filter=backup&tab=pending');
      await waitResults(page);
      const region = page.locator('#backup-panel-pending .backup-excluded');
      assert.equal(await region.getAttribute('data-excluded'), 'empty');
      assert.equal((await region.innerText()).trim(), '沒有記錄到被排除的區域');
      assert.deepEqual(errors, []); await page.context().close();
    }
    {
      const unboundResults = { ...fixture.results, ExcludedRegions: null };
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, results: unboundResults }, '#jobs?filter=backup&tab=pending');
      await waitResults(page);
      const region = page.locator('#backup-panel-pending .backup-excluded');
      assert.equal(await region.getAttribute('data-excluded'), 'unrecorded');
      assert.equal((await region.innerText()).trim(), '此結果集未記錄');
      assert.equal(await region.locator('table').count(), 0);
      assert.deepEqual(errors, []); await page.context().close();
    }
    {
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, results: legacyFixture.results }, '#jobs?filter=backup&tab=pending');
      await waitResults(page);
      const region = page.locator('#backup-panel-pending .backup-excluded');
      assert.equal(await region.getAttribute('data-excluded'), 'unrecorded');
      assert.equal((await region.innerText()).trim(), '此結果集未記錄');
      assert.deepEqual(errors, []); await page.context().close();
    }
    // N3: nothing delivered, a failed attempt: capture failure names the failed item, read-back failure is NotVerified; no result set is shown
    {
      const failedAttempt = { attemptId: 'fixture-failed', errorCode: 'core_export_failed', classification: 'CaptureFailed', title: '擷取或封存失敗', detail: '封存沒有完成，所以沒有產生任何備份結果集；工具不會把部分擷取的內容當成已備份。', nextStep: '修正失敗項目的問題後，從同一個作業續作。', updatedUtc: '2026-10-23T01:00:00Z', failedItem: { ItemId: 'item-0042', Name: 'Doomed <b>data</b> folder', Kind: 'DataRoot', Channel: 'C', ErrorClass: 'IOError', ErrorKind: 'System.IO.IOException' } };
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, failedAttempt }, '#jobs?filter=backup');
      await page.waitForSelector('#backup-item-results .backup-failed-attempt', { timeout: 30000 });
      const box = page.locator('#backup-item-results .backup-failed-attempt'), text = await box.innerText();
      assert.equal(await page.locator('#backup-item-results [role=tablist]').count(), 0, 'a failed attempt must not show result tabs');
      assert.equal(await box.getAttribute('data-classification'), 'CaptureFailed');
      assert.ok(text.includes('擷取或封存失敗') && text.includes('Doomed <b>data</b> folder') && text.includes('讀寫錯誤') && text.includes('System.IO.IOException') && text.includes('從同一個作業續作') && text.includes('沒有產生任何備份結果集'));
      assert.equal(await box.locator('b').count(), 0, 'the failed item name must be text, not markup');
      await page.screenshot({ path: path.join(screens, 'n3-workbench-capture-failed.png') });
      assert.deepEqual(errors, []); await page.context().close();
      const verify = await openWorkbench(browser, fixture, { ...base, failedAttempt: { ...failedAttempt, errorCode: 'package_test_failed', classification: 'NotVerified', title: '已封存但讀回驗證未通過', detail: '封存後的讀回驗證沒有通過，這份備份不能視為已備份。', nextStep: '先檢查作業紀錄與儲存空間，再從同一個作業續作驗證。', failedItem: null } }, '#jobs?filter=backup');
      await verify.page.waitForSelector('#backup-item-results .backup-failed-attempt', { timeout: 30000 });
      const verifyBox = verify.page.locator('#backup-item-results .backup-failed-attempt'), verifyText = await verifyBox.innerText();
      assert.equal(await verifyBox.getAttribute('data-classification'), 'NotVerified');
      assert.ok(verifyText.includes('已封存但讀回驗證未通過') && verifyText.includes('不能視為已備份') && !verifyText.includes('失敗項目') && !verifyText.includes('沒有記錄到特定項目'));
      await verify.page.screenshot({ path: path.join(screens, 'n3-workbench-not-verified.png') });
      assert.deepEqual(verify.errors, []); await verify.context.close();
    }

    // ================= D. URL hash state: written by filters, survives reload, back and manual edits =================
    {
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, copy: COPY_STATES.verified }, '#jobs?filter=backup&tab=pending&type=DataRoot');
      await waitResults(page);
      const pending = page.locator('#backup-panel-pending');
      assert.equal(await page.locator('#backup-tab-pending').getAttribute('aria-selected'), 'true', 'tab comes from the hash');
      assert.equal(await pending.getByLabel('類型').inputValue(), 'DataRoot', 'type filter comes from the hash');
      const dataRootPending = pendingRows.filter(r => r.Kind === 'DataRoot').length;
      assert.equal(await pending.locator('[role=status]').first().innerText(), `顯示 ${dataRootPending}／共 ${pendingRows.length} 筆`);
      await pending.getByLabel('原因').selectOption('Excluded');
      await pending.getByLabel('搜尋名稱或位置').fill('item-02');
      const expectedPending = pendingRows.filter(r => r.Kind === 'DataRoot' && r.ReasonCode === 'Excluded' && `${r.Name}\n${r.Location}`.toLowerCase().includes('item-02')).length;
      const hash = await page.evaluate(() => location.hash);
      assert.ok(hash.startsWith('#jobs?filter=backup&tab=pending') && hash.includes('type=DataRoot') && hash.includes('reason=Excluded') && hash.includes('q=item-02'), 'filters must be written to the hash: ' + hash);
      await page.reload(); await waitResults(page);
      assert.equal(await page.evaluate(() => location.hash), hash, 'reload keeps the hash');
      assert.equal(await page.locator('#backup-tab-pending').getAttribute('aria-selected'), 'true');
      assert.equal(await pending.getByLabel('類型').inputValue(), 'DataRoot');
      assert.equal(await pending.getByLabel('原因').inputValue(), 'Excluded');
      assert.equal(await pending.getByLabel('搜尋名稱或位置').inputValue(), 'item-02');
      assert.equal(await pending.locator('[role=status]').first().innerText(), `顯示 ${expectedPending}／共 ${pendingRows.length} 筆`, 'reload restores the same filtered count');
      // switching tabs rewrites the hash to the other tab's own filters; back to pending restores them
      await page.locator('#backup-tab-backed').click();
      assert.equal(await page.evaluate(() => location.hash), '#jobs?filter=backup&tab=backed');
      await page.locator('#backup-tab-pending').click();
      assert.equal(await page.evaluate(() => location.hash), hash);
      // leave to another view and press Back
      await page.evaluate(() => window.WsmConsole.navigate('help'));
      await page.waitForFunction(() => location.hash === '#help');
      await page.goBack();
      await page.waitForFunction(() => location.hash.startsWith('#jobs?filter=backup'));
      await waitResults(page);
      assert.equal(await page.evaluate(() => location.hash), hash, 'Back returns to the same hash');
      assert.equal(await page.locator('#backup-tab-pending').getAttribute('aria-selected'), 'true');
      assert.equal(await pending.getByLabel('原因').inputValue(), 'Excluded');
      assert.equal(await pending.locator('[role=status]').first().innerText(), `顯示 ${expectedPending}／共 ${pendingRows.length} 筆`, 'Back keeps the filtered count');
      // manual edit of the hash applies to the page without a reload
      await page.evaluate(() => { location.hash = '#jobs?filter=backup&tab=backed&type=Service&copy=Verified'; });
      await page.waitForFunction(() => document.querySelector('#backup-tab-backed').getAttribute('aria-selected') === 'true');
      const backed = page.locator('#backup-panel-backed');
      assert.equal(await backed.getByLabel('類型').inputValue(), 'Service');
      assert.equal(await backed.getByLabel('獨立副本').inputValue(), 'Verified');
      assert.equal(await backed.locator('[role=status]').innerText(), `顯示 ${backedRows.filter(r => r.Kind === 'Service').length}／共 ${backedRows.length} 筆`);
      // an unknown filter value in the hash is ignored, not shown as an empty list
      await page.evaluate(() => { location.hash = '#jobs?filter=backup&tab=backed&type=NoSuchKind'; });
      await page.waitForFunction(() => document.querySelector('#backup-panel-backed select').value === '');
      assert.equal(await backed.locator('[role=status]').innerText(), `顯示 ${backedRows.length}／共 ${backedRows.length} 筆`);
      // pager state is part of the hash too
      await backed.getByRole('button', { name: '下一頁' }).click();
      assert.ok((await page.evaluate(() => location.hash)).includes('p=2'));
      await page.reload(); await waitResults(page);
      assert.ok((await backed.locator('.backup-pager').innerText()).includes('第 2／'), 'reload keeps the page');
      assert.deepEqual(errors, []);
      await page.context().close();
    }

    // ================= E. file drill-down =================
    {
      const scenario = { ...base, copy: COPY_STATES.verified, failFirstFilesFor: 'item-0002' };
      const { page, errors, fileRequests, gates } = await openWorkbench(browser, fixture, scenario, '#jobs?filter=backup');
      await waitResults(page);
      const backed = page.locator('#backup-panel-backed');
      const button = id => backed.locator(`tr[data-id="${id}"] button.backup-expand`);
      assert.equal(await button('item-0001').getAttribute('aria-expanded'), 'false');
      assert.equal(await button('item-0001').getAttribute('type'), 'button');
      // paging: 250 files over three pages, directory members marked, count from the server
      await button('item-0001').click();
      assert.equal(await button('item-0001').getAttribute('aria-expanded'), 'true');
      const detail = backed.locator('.backup-detail-row:not([hidden]) .backup-detail').first();
      await detail.locator('table').waitFor();
      assert.equal(await detail.locator('tbody tr').count(), 100);
      assert.ok((await detail.innerText()).includes('共 250 筆（其中目錄 2 筆）'));
      assert.ok((await detail.innerText()).includes('第 1／3 頁'));
      const first = (await detail.locator('tbody tr').first().allInnerTexts()).join('|');
      assert.ok(first.includes('file-000.dat') && first.includes('檔案'), first);
      const directoryRows = await detail.locator('tbody tr').filter({ hasText: '目錄' }).count();
      assert.equal(directoryRows, 1, 'page 1 holds one directory member');
      assert.ok(await detail.locator('tbody tr').filter({ hasText: '目錄' }).first().innerText().then(t => t.includes('empty')), 'directory member shows its path');
      await detail.getByRole('button', { name: '下一頁' }).click();
      await page.waitForFunction(() => document.querySelector('.backup-detail caption') && document.querySelector('.backup-detail caption').textContent.includes('第 2／3 頁'));
      assert.deepEqual(fileRequests.filter(r => r.itemId === 'item-0001').map(r => r.page), [1, 2], 'only the requested pages are fetched');
      await detail.getByRole('button', { name: '下一頁' }).click();
      await page.waitForFunction(() => { const c = document.querySelector('.backup-detail caption'); return !!c && c.textContent.includes('第 3／3 頁'); });
      assert.equal(await detail.locator('tbody tr').count(), 50);
      assert.equal(await detail.getByRole('button', { name: '下一頁' }).isDisabled(), true);
      await page.screenshot({ path: path.join(screens, 'b2-desktop-drilldown.png') });
      // collapse and re-expand
      await button('item-0001').click();
      assert.equal(await button('item-0001').getAttribute('aria-expanded'), 'false');
      assert.equal(await backed.locator('.backup-detail-row:not([hidden])').count(), 0);
      // keyboard: focus the button and use Enter, then Space
      await button('item-0008').focus(); await page.keyboard.press('Enter');
      await backed.locator('.backup-detail-row:not([hidden]) .backup-detail').getByText('沒有檔案明細').waitFor();
      assert.equal(await button('item-0008').getAttribute('aria-expanded'), 'true');
      assert.ok(!(await backed.locator('.backup-detail-row:not([hidden]) .backup-detail table').count()), 'empty set has no table');
      await page.keyboard.press('Space');
      assert.equal(await button('item-0008').getAttribute('aria-expanded'), 'false');
      // error state, then retry succeeds
      await button('item-0002').click();
      const errorDetail = backed.locator('.backup-detail-row:not([hidden]) .backup-detail');
      await errorDetail.getByText('無法讀取檔案明細：封存套件已變更，無法核驗。').waitFor();
      assert.equal(await errorDetail.getByRole('button', { name: '重試' }).count(), 1);
      await page.screenshot({ path: path.join(screens, 'b2-desktop-drilldown-error.png') });
      await errorDetail.getByRole('button', { name: '重試' }).click();
      await errorDetail.locator('table').waitFor();
      assert.ok((await errorDetail.innerText()).includes('共 2 筆'));
      // loading state is visible while the request is pending
      gates.item11 = gate();
      await button('item-0011').click();
      const loading = backed.locator('.backup-detail-row:not([hidden]) .wizard-loading');
      await loading.waitFor();
      assert.equal(await loading.getAttribute('role'), 'status');
      assert.ok((await loading.innerText()).includes('正在讀取檔案明細'));
      await page.screenshot({ path: path.join(screens, 'b2-desktop-drilldown-loading.png') });
      gates.item11.release();
      await loading.waitFor({ state: 'detached' });
      // expansion survives filtering/paging of the main table (state kept by ItemId)
      await backed.getByLabel('搜尋名稱或位置').fill('item-0011'); await backed.getByLabel('搜尋名稱或位置').fill('');
      assert.equal(await button('item-0011').getAttribute('aria-expanded'), 'true');
      assert.deepEqual(errors, []);
      await page.context().close();
    }

    // ================= F. loading and error states of the page itself stay separate =================
    {
      const hold = gate();
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, delayView: hold.promise }, '#jobs?filter=backup');
      await page.getByText('正在讀取備份明細').waitFor();
      hold.release(); await waitResults(page);
      assert.deepEqual(errors, []); await page.context().close();
      const failing = await openWorkbench(browser, fixture, { ...base, viewError: true }, '#jobs?filter=backup');
      await failing.page.getByText('無法讀取備份明細：備份明細暫時無法讀取。').waitFor();
      assert.equal(await failing.page.locator('#backup-item-results').getByRole('button', { name: '重試' }).count(), 1);
      assert.deepEqual(failing.errors, []); await failing.context.close();
    }

    // ================= G. CSV parity with the offline report, and cross-screen consistency =================
    {
      const reportContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      await reportContext.addInitScript(blobCapture);
      const reportPage = await reportContext.newPage(); reportPage.on('pageerror', e => allErrors.push(e.message)); reportPage.on('console', m => { if (m.type() === 'error') allErrors.push(m.text()); });
      await reportPage.goto(fileUrl(fixture.report)); await reportPage.waitForSelector('[role=tablist]');
      const reportBacked = await captureCsv(reportPage, reportPage.locator('#backed'));
      await reportPage.locator('[role=tab]').nth(1).click();
      const reportPending = await captureCsv(reportPage, reportPage.locator('#pending'));
      await reportContext.close();

      const { page, errors } = await openWorkbench(browser, fixture, { ...base, copy: COPY_STATES.verified }, '#jobs?filter=backup');
      await waitResults(page);
      const workbenchBacked = await captureCsv(page, page.locator('#backup-panel-backed'));
      await page.locator('#backup-tab-pending').click();
      const workbenchPending = await captureCsv(page, page.locator('#backup-panel-pending'));
      for (const [label, wb, rp, set] of [['backed', workbenchBacked, reportBacked, backedRows], ['pending', workbenchPending, reportPending, pendingRows]]) {
        assert.deepEqual(wb[0], rp[0], `${label}: workbench CSV header must equal the report CSV header (same names, same order)`);
        assert.deepEqual(wb[0].slice(-3), ['項目 ID', '狀態碼', '原因碼'], `${label}: trailing id/status/reason columns`);
        assert.equal(wb.length - 1, set.length, `${label}: workbench CSV has every row, not only the page`);
        const idCol = wb[0].indexOf('項目 ID');
        const byId = rows => new Map(rows.slice(1).map(r => [r[idCol], r]));
        const w = byId(wb), r = byId(rp);
        assert.equal(w.size, wb.length - 1, `${label}: ids unique`);
        assert.deepEqual([...w.keys()].sort(), [...r.keys()].sort(), `${label}: same item ids`);
        for (const [id, cells] of w) assert.deepEqual(cells, r.get(id), `${label}: row ${id} differs between workbench and report CSV`);
      }

      // N3: the excluded-regions CSV is identical on both screens (same header, same rows, same reason codes)
      const reportRegionsContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      await reportRegionsContext.addInitScript(blobCapture);
      const reportRegionsPage = await reportRegionsContext.newPage(); reportRegionsPage.on('pageerror', e => allErrors.push(e.message)); reportRegionsPage.on('console', m => { if (m.type() === 'error') allErrors.push(m.text()); });
      await reportRegionsPage.goto(fileUrl(fixture.report)); await reportRegionsPage.waitForSelector('[role=tablist]');
      await reportRegionsPage.locator('[role=tab]').nth(1).click();
      const reportRegions = await captureCsv(reportRegionsPage, reportRegionsPage.locator('#pending .toolbar').nth(1));
      await reportRegionsContext.close();
      await page.locator('#backup-tab-pending').click();
      const workbenchRegions = await captureCsv(page, page.locator('#backup-panel-pending .backup-excluded'));
      assert.deepEqual(workbenchRegions[0], reportRegions[0], 'region CSV header must match on both screens');
      assert.deepEqual(workbenchRegions[0].slice(-1), ['原因碼']);
      assert.equal(workbenchRegions.length - 1, fixture.results.ExcludedRegions.length);
      const sortRows = csv => csv.slice(1).map(r => r.join('\u0001')).sort();
      assert.deepEqual(sortRows(workbenchRegions), sortRows(reportRegions), 'region CSV rows must be identical on both screens');
      const regionJson = new Map(fixture.results.ExcludedRegions.map(r => [r.Path, r]));
      for (const csvName of [workbenchRegions, reportRegions]) for (const row of csvName.slice(1)) { const e = regionJson.get(row[0]); assert.ok(e, 'unknown region ' + row[0]); assert.equal(row[3], e.ReasonCode); assert.equal(row[1], e.Reason); assert.equal(row[2], e.NextStep); }
      // the display-only columns never leak into the CSV
      assert.ok(!workbenchBacked[0].includes('獨立副本') && !workbenchBacked[0].includes('檔案明細'));

      // cross-screen: per ItemId the status and reason code are identical in the JSON, the report CSV, the workbench CSV and the workbench DOM
      const json = new Map(rows.map(r => [r.ItemId, r]));
      const cross = (csv, label) => {
        const idCol = csv[0].indexOf('項目 ID'), statusCol = csv[0].indexOf('狀態碼'), reasonCol = csv[0].indexOf('原因碼');
        for (const row of csv.slice(1)) { const e = json.get(row[idCol]); assert.ok(e, `${label}: unknown id ${row[idCol]}`); assert.equal(row[statusCol], e.Status, `${label} status of ${row[idCol]}`); assert.equal(row[reasonCol], e.ReasonCode, `${label} reason of ${row[idCol]}`); }
      };
      cross(workbenchBacked, 'workbench backed'); cross(workbenchPending, 'workbench pending'); cross(reportBacked, 'report backed'); cross(reportPending, 'report pending');
      const ids = new Set([...workbenchBacked.slice(1).map(r => r[workbenchBacked[0].indexOf('項目 ID')]), ...workbenchPending.slice(1).map(r => r[workbenchPending[0].indexOf('項目 ID')])]);
      assert.equal(ids.size, rows.length, 'backed + pending ids must be the whole result set');
      assert.equal(workbenchBacked.length - 1 + workbenchPending.length - 1, rows.length, 'backed and pending do not overlap');
      const domRows = await page.evaluate(() => [...document.querySelectorAll('#backup-item-results tr[data-id]')].map(tr => ({ id: tr.dataset.id, status: tr.dataset.status, reason: tr.dataset.reason })));
      assert.ok(domRows.length > 0);
      for (const d of domRows) { const e = json.get(d.id); assert.ok(e); assert.equal(d.status, e.Status); assert.equal(d.reason, e.ReasonCode); }
      // filtered CSV = filtered rows only, still in the same columns
      await page.locator('#backup-tab-backed').click();
      await page.locator('#backup-panel-backed').getByLabel('類型').selectOption('Service');
      const filteredCsv = await captureCsv(page, page.locator('#backup-panel-backed'));
      assert.equal(filteredCsv.length - 1, backedRows.filter(r => r.Kind === 'Service').length);
      assert.deepEqual(filteredCsv[0], workbenchBacked[0]);
      // formula-leading names are neutralised like in the report
      const nameCol = workbenchBacked[0].indexOf('名稱');
      const names = workbenchBacked.slice(1).map(r => r[nameCol]);
      assert.ok(names.includes("'=SUM(1+1)") && names.includes("'@cmd|calc") && names.includes("'+1-2"));
      assert.deepEqual(errors, []);
      await page.context().close();
    }

    // ================= H. keyboard focus is visible; 390px; reduced motion =================
    {
      const { page, errors } = await openWorkbench(browser, fixture, { ...base, copy: COPY_STATES.verified }, '#jobs?filter=backup');
      await waitResults(page);
      const backed = page.locator('#backup-panel-backed');
      const outline = async locator => locator.evaluate(node => { const s = getComputedStyle(node); return { style: s.outlineStyle, width: parseFloat(s.outlineWidth) }; });
      await backed.getByLabel('類型').focus();
      await page.keyboard.press('Tab'); await page.keyboard.press('Shift+Tab');
      let o = await outline(backed.getByLabel('類型')); assert.ok(o.style !== 'none' && o.width >= 3, 'select focus ring: ' + JSON.stringify(o));
      await backed.getByLabel('搜尋名稱或位置').focus(); o = await outline(backed.getByLabel('搜尋名稱或位置')); assert.ok(o.style !== 'none' && o.width >= 3, 'search focus ring');
      await backed.locator('button.backup-expand').first().focus(); o = await outline(backed.locator('button.backup-expand').first()); assert.ok(o.style !== 'none' && o.width >= 3, 'expand button focus ring');
      await backed.locator('.table-wrap').first().focus(); o = await outline(backed.locator('.table-wrap').first()); assert.ok(o.style !== 'none' && o.width >= 3, 'table region focus ring');
      // 390px: page never scrolls horizontally; the table scrolls inside its region
      await page.setViewportSize({ width: 390, height: 844 });
      await backed.locator('tr[data-id="item-0001"] button.backup-expand').click();
      await backed.locator('.backup-detail table').waitFor();
      for (const tab of ['backed', 'pending', 'software']) {
        await page.locator('#backup-tab-' + tab).click();
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        const offenders = overflow > 0 ? await page.evaluate(() => [...document.querySelectorAll('body *')].filter(n => n.getBoundingClientRect().right > document.documentElement.clientWidth + 0.5 && !n.closest('.table-wrap')).slice(0, 6).map(n => `${n.tagName}.${n.className}#${n.id}:${Math.round(n.getBoundingClientRect().right)}`)) : [];
        assert.ok(overflow <= 0, `${tab}: page overflows the 390px viewport by ${overflow}px ${JSON.stringify(offenders)}`);
        await page.screenshot({ path: path.join(screens, `b2-mobile-390-${tab}.png`) });
      }
      await page.locator('#backup-tab-backed').click();
      assert.ok(await backed.locator('.table-wrap').first().evaluate(w => w.scrollWidth > w.clientWidth), 'the table scrolls inside its own region at 390px');
      await page.screenshot({ path: path.join(screens, 'b2-mobile-390-drilldown.png') });
      assert.deepEqual(errors, []);
      await page.context().close();
      const reduced = await openWorkbench(browser, fixture, base, '#jobs?filter=backup', { reducedMotion: 'reduce' });
      await waitResults(reduced.page);
      assert.equal(await reduced.page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches), true);
      assert.deepEqual(reduced.errors, []); await reduced.context.close();
    }

    // ================= H. N9d: mixed install-root contents (R7-04 / R7-05 visibility) =================
    {
      const mixed = buildFixture('V2', 'Mixed'); extraDirs.push(mixed.dir);
      const regions = mixed.results.ExcludedRegions, withContents = regions.filter(r => r.Contents);
      assert.equal(withContents.length, 2, 'the mixed fixture has two classified install roots');
      const regionA = regions.find(r => r.Path.includes('Vendor =App')), regionB = regions.find(r => r.Path.endsWith('Big Suite'));
      const mixedBase = { results: mixed.results, copy: COPY_STATES.notVerified };
      const { page, errors } = await openWorkbench(browser, mixed, mixedBase, '#jobs?filter=backup&tab=pending');
      await waitResults(page);
      const pending = page.locator('#backup-panel-pending'), excluded = pending.locator('.backup-excluded');
      // overall completeness: never "complete"; manual items are named
      const completeness = page.locator('#backup-completeness');
      assert.equal(await completeness.getAttribute('data-status'), 'ManualItems');
      const completenessText = await completeness.innerText();
      assert.ok(completenessText.includes('整體完整度') && completenessText.includes('有人工處置項') && completenessText.includes('不代表搬移已完整'), completenessText);
      assert.equal(await completeness.locator('.backup-badge').getAttribute('data-icon'), '!', 'status is text plus icon');
      // table shape is unchanged; the expanders are extra, collapsed by default and carry aria-expanded
      assert.deepEqual(await excluded.locator('thead th').allInnerTexts(), ['區域', '原因', '下一步']);
      const toggles = excluded.locator('.backup-region-toggle');
      assert.equal(await toggles.count(), 2);
      for (const index of [0, 1]) assert.equal(await toggles.nth(index).getAttribute('aria-expanded'), 'false');
      assert.equal(await excluded.locator('tr.backup-detail-row:not([hidden])').count(), 0, 'details are collapsed by default');
      const rowA = excluded.locator('tr[data-reason]').filter({ hasText: 'Vendor =App' });
      const toggleA = rowA.locator('.backup-region-toggle');
      assert.ok((await toggleA.innerText()).includes(`本體 ${regionA.Contents.Counts.Bundle} · 疑似業務資料 ${regionA.Contents.Counts.SuspectedBusinessData} · 未知 ${regionA.Contents.Counts.Unknown}`));
      await toggleA.click();
      assert.equal(await toggleA.getAttribute('aria-expanded'), 'true');
      const detailA = page.locator('#' + await toggleA.getAttribute('aria-controls'));
      assert.equal(await detailA.isVisible(), true);
      const detailText = await detailA.innerText();
      assert.ok(detailText.includes(`本體 ${regionA.Contents.Counts.Bundle}、疑似業務資料 ${regionA.Contents.Counts.SuspectedBusinessData}、未知 ${regionA.Contents.Counts.Unknown}`));
      // manual handling: reason, original location, next step
      const manual = detailA.locator('.manual-box');
      const manualText = await manual.innerText();
      assert.ok(manualText.includes('人工處置') && manualText.includes('原件位置') && manualText.includes(regionA.Path) && manualText.includes('人工另外複製') && manualText.includes('原因'), manualText);
      // samples: one table row per sample, suspected rows are marked as manual handling, paths shown as plain text
      const sampleRows = detailA.locator('table.region-samples tbody tr');
      assert.equal(await sampleRows.count(), regionA.Contents.Samples.length);
      const suspectedRows = detailA.locator('table.region-samples tbody tr[data-class="SuspectedBusinessData"]');
      assert.equal(await suspectedRows.count(), regionA.Contents.Samples.filter(s => s.Class === 'SuspectedBusinessData').length);
      assert.ok((await suspectedRows.first().innerText()).includes('人工處置：另外人工複製'));
      assert.ok((await detailA.locator('table.region-samples').innerText()).includes("sales & 'q'.csv"), 'file names with & and quotes are shown as text');
      // same-name trace shows both sides
      const sameSides = await detailA.locator('ul.same-name li').evaluateAll(items => items.map(i => ({ side: i.dataset.side, text: i.textContent })));
      assert.deepEqual(sameSides.map(s => s.side).sort(), ['bundle', 'other']);
      assert.ok(sameSides.every(s => s.text.includes('同名，另一處位於') && s.text.includes('core.dll')));
      assert.ok(sameSides.find(s => s.side === 'other').text.includes('Website publish'), 'the other side names the backed-up item');
      assert.notEqual(regionA.SameName[0].BundleClassText, regionA.SameName[0].OtherClassText);
      await detailA.scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(screens, 'n9d-workbench-region-expanded.png') });
      // collapse again
      await toggleA.click();
      assert.equal(await toggleA.getAttribute('aria-expanded'), 'false'); assert.equal(await detailA.isVisible(), false);
      // keyboard: Enter opens the incomplete region and the "not finished" state is explicit
      const toggleB = excluded.locator('tr[data-reason]').filter({ hasText: 'Big Suite' }).locator('.backup-region-toggle');
      await toggleB.focus(); await page.keyboard.press('Enter');
      assert.equal(await toggleB.getAttribute('aria-expanded'), 'true');
      const detailB = page.locator('#' + await toggleB.getAttribute('aria-controls'));
      const detailBText = await detailB.innerText();
      assert.ok(detailBText.includes('未列完') && detailBText.includes(regionB.Contents.IncompleteReason) && detailBText.includes(`已列 ${regionB.Contents.Listed} 筆`), detailBText);
      assert.ok(regionB.Contents.Complete === false && regionB.Contents.Listed === 5);
      // regions without Contents (Program Files, Windows, legacy rows) get no expander and are not claimed to be classified
      assert.equal(await excluded.locator('tr[data-reason]').filter({ hasText: 'Legacy App' }).locator('.backup-region-toggle').count(), 0);
      // CSV is unchanged by the expanders: same header, one row per region, path column is the plain path
      const regionCsv = await captureCsv(page, excluded);
      assert.deepEqual(regionCsv[0], ['區域', '原因', '下一步', '原因碼']);
      assert.equal(regionCsv.length - 1, regions.length);
      const csvByPath = new Map(regionCsv.slice(1).map(r => [r[0], r]));
      assert.ok(csvByPath.has(regionA.Path) && csvByPath.get(regionA.Path)[2] === regionA.NextStep && csvByPath.get(regionA.Path)[3] === 'BundleExcluded');
      assert.ok(regionCsv.every(r => !r.join('').includes('內容分類') && !r.join('').includes('▸')), 'expander text never leaks into the CSV');
      // filter and search keep working with the expanders
      await excluded.getByLabel('搜尋區域路徑').fill('Big Suite');
      assert.equal(await excluded.locator('tr[data-reason]').count(), 1);
      await excluded.getByLabel('搜尋區域路徑').fill('');
      assert.deepEqual(errors, []); await page.context().close();
      // 390px: nothing overflows the page, the detail scrolls inside its own region
      const narrow = await openWorkbench(browser, mixed, mixedBase, '#jobs?filter=backup&tab=pending', { viewport: { width: 390, height: 844 } });
      await waitResults(narrow.page);
      const narrowExcluded = narrow.page.locator('#backup-panel-pending .backup-excluded');
      await narrowExcluded.locator('.backup-region-toggle').first().click();
      await narrowExcluded.locator('tr.backup-detail-row:not([hidden])').first().scrollIntoViewIfNeeded();
      const overflow = await narrow.page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 0, `390px: page overflows by ${overflow}px`);
      await narrow.page.screenshot({ path: path.join(screens, 'n9d-workbench-390.png') });
      assert.deepEqual(narrow.errors, []); await narrow.context.close();
      // a legacy result set (no new fields) shows no completeness line and no expander
      const legacy = await openWorkbench(browser, mixed, { ...mixedBase, results: legacyFixture.results }, '#jobs?filter=backup&tab=pending');
      await waitResults(legacy.page);
      assert.equal(await legacy.page.locator('#backup-completeness').count(), 0);
      assert.equal(await legacy.page.locator('.backup-region-toggle').count(), 0);
      assert.deepEqual(legacy.errors, []); await legacy.context.close();
    }

    assert.deepEqual(allErrors, [], 'no console errors expected');
    console.log(`PASS: backup workbench browser test (${rows.length} rows, ${backedRows.length} backed, ${pendingRows.length} not backed).`);
  } finally {
    await browser.close();
    server.close();
    for (const dir of [fixture.dir, legacyFixture.dir, ...extraDirs]) fs.rmSync(dir, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exit(1); });
