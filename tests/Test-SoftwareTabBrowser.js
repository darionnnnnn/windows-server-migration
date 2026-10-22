// Real-browser (Edge) test for B4: the installed-software tab (groups, filters stacked with search, CSV, printable checklist,
// empty / legacy / 2501-row inventories) in the offline report (file://) and the workbench, plus the Target "new machine check"
// (four states, filters, no-comparison empty state). The UI under test is the real src/ui files and the real report generator;
// only the local API is replaced by fixtures built from the real projection code.
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
const edge = process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';

function runFixture(script, args) {
  const run = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tests', script), ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  assert.equal(run.status, 0, `${script} failed: ${run.stderr}`);
}
function buildSoftwareFixture(shape) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-b4-' + shape.toLowerCase() + '-'));
  runFixture('New-SoftwareTabFixture.ps1', ['-OutDir', dir, '-Shape', shape]);
  const results = JSON.parse(fs.readFileSync(path.join(dir, 'backup-item-results.json'), 'utf8').replace(/^\ufeff/, ''));
  return { dir, report: path.join(dir, 'backup-report.html'), results };
}
function buildLegacyFixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-b4-legacy-'));
  runFixture('New-OfflineReportFixture.ps1', ['-OutDir', dir, '-Shape', 'V2']);
  const results = JSON.parse(fs.readFileSync(path.join(dir, 'backup-item-results.json'), 'utf8').replace(/^\ufeff/, ''));
  return { dir, report: path.join(dir, 'backup-report.html'), results };
}
function buildTargetFixture(shape) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-b4-target-'));
  runFixture('New-SoftwareTabFixture.ps1', ['-OutDir', dir, '-Shape', shape]);
  const data = JSON.parse(fs.readFileSync(path.join(dir, 'target-software-check.json'), 'utf8').replace(/^\ufeff/, ''));
  fs.rmSync(dir, { recursive: true, force: true });
  return data.softwareCheck;
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
async function captureCsv(page, button) {
  await page.evaluate(() => { window.__blobs = []; });
  await button.click();
  const bytes = await page.evaluate(async () => { const blob = window.__blobs.pop(); return Array.from(new Uint8Array(await blob.arrayBuffer())); });
  const buffer = Buffer.from(bytes);
  assert.deepEqual([...buffer.subarray(0, 3)], [0xEF, 0xBB, 0xBF], 'CSV must start with a UTF-8 BOM');
  const text = buffer.subarray(3).toString('utf8');
  assert.ok(!/(^|[^\r])\n/.test(text), 'CSV line breaks must be CRLF only');
  return parseCsv(text);
}
const blobCapture = () => { window.__blobs = []; const original = URL.createObjectURL; URL.createObjectURL = function (blob) { window.__blobs.push(blob); return original.call(URL, blob); }; };
const stubPrint = page => page.evaluate(() => { window.__prints = 0; window.print = () => { window.__prints++; }; });

const HEADERS = ['分組', '名稱', '版本', '選用版本', '發行者', '架構', '範圍', '安裝位置', '工作負載', '決策', '審閱狀態', '人工備註'];
const GROUP_REQUIRED = '已選工作負載必需', GROUP_OTHER = '其他已發現軟體';
const searchText = r => `${r.Name}\n${r.Version}\n${r.Publisher}\n${r.Location}`.toLowerCase();

// Shared expectations over the software rows of a result set (same data for the report and the workbench).
function softwareExpectations(results) {
  const rows = results.Software.SoftwareRows, required = rows.filter(r => r.RequiredBySelectedWorkload === true);
  assert.ok(rows.length > 100 && required.length > 20, 'fixture must exceed one page and have a required group');
  assert.deepEqual(rows.slice(0, required.length).map(r => r.SoftwareId), required.map(r => r.SoftwareId), 'result set must list required rows first');
  return { rows, required };
}

// Everything the report and the workbench must agree on once a software table is on screen.
async function checkSoftwareTable({ page, scope, table, statusScope, rows, required, label, screenName, grouped = true }) {
  const status = statusScope.locator('[role=status][aria-atomic=true]');
  assert.equal(await status.count(), 1, `${label}: exactly one count status element for the software table`);
  assert.equal(await status.innerText(), `顯示 ${rows.length}／共 ${rows.length} 筆`);
  assert.equal(await table.locator('thead th').allTextContents().then(list => list.slice(0, 12)).then(l => l.join('|')), HEADERS.join('|'), `${label}: column order`);
  // Group order on the first page: required rows first, then the others.
  const firstCells = await table.locator('tbody tr:not([hidden]):not(.backup-detail-row) td:first-child').allInnerTexts();
  assert.ok(firstCells.length > required.length, `${label}: the first page must reach past the required group`);
  firstCells.slice(0, required.length).forEach(t => assert.ok(t.includes(GROUP_REQUIRED), `${label}: required rows come first (${t})`));
  assert.ok(firstCells[required.length].includes(GROUP_OTHER), `${label}: the other group follows`);
  // Status is never colour only: every group / review badge carries an icon and text.
  const badges = await table.locator('tbody .backup-badge, tbody .badge').evaluateAll(list => list.map(b => ({ text: b.textContent.trim(), icon: b.dataset.icon })));
  assert.ok(badges.length > 0 && badges.every(b => b.text && b.icon), `${label}: every badge needs text and an icon`);
  assert.equal(await scope.locator('.table-wrap[role=region][tabindex="0"]').count() >= 1, true, `${label}: table region must be named and focusable`);
  // Filters: native select with a visible label.
  for (const name of ['分組', '決策', '架構', '搜尋名稱或位置']) assert.equal(await statusScope.getByLabel(name, { exact: true }).count(), 1, `${label}: ${name} must be one labelled control`);
  const groupSelect = statusScope.getByLabel('分組', { exact: true }), decisionSelect = statusScope.getByLabel('決策', { exact: true }), archSelect = statusScope.getByLabel('架構', { exact: true }), search = statusScope.getByLabel('搜尋名稱或位置', { exact: true });
  const groupOptions = await groupSelect.locator('option').allInnerTexts();
  assert.ok(groupOptions.includes('全部') && groupOptions.includes(GROUP_REQUIRED) && groupOptions.includes(GROUP_OTHER), `${label}: group options ${groupOptions}`);
  await groupSelect.selectOption({ label: GROUP_REQUIRED });
  assert.equal(await status.innerText(), `顯示 ${required.length}／共 ${rows.length} 筆`);
  const nonRequired = (await table.locator('tbody tr:not([hidden]) td:first-child').allInnerTexts()).filter(t => !t.includes(GROUP_REQUIRED));
  assert.equal(nonRequired.length, 0, `${label}: the group filter must hide the other group`);
  await groupSelect.selectOption({ label: GROUP_OTHER });
  assert.equal(await status.innerText(), `顯示 ${rows.length - required.length}／共 ${rows.length} 筆`);
  await groupSelect.selectOption('');
  const reinstall = rows.filter(r => r.DispositionText === '新機重新安裝').length;
  assert.ok(reinstall > 0, 'fixture needs reinstall decisions');
  await decisionSelect.selectOption({ label: '新機重新安裝' });
  assert.equal(await status.innerText(), `顯示 ${reinstall}／共 ${rows.length} 筆`);
  await decisionSelect.selectOption('');
  const x86 = rows.filter(r => r.Architecture === 'x86').length;
  await archSelect.selectOption({ label: 'x86' });
  assert.equal(await status.innerText(), `顯示 ${x86}／共 ${rows.length} 筆`);
  // Stacked: group + architecture + search.
  await groupSelect.selectOption({ label: GROUP_OTHER });
  await search.fill('tool 0');
  const stacked = rows.filter(r => r.RequiredBySelectedWorkload !== true && r.Architecture === 'x86' && searchText(r).includes('tool 0')).length;
  assert.ok(stacked > 0 && stacked < x86, `${label}: stacked fixture must narrow the list (${stacked})`);
  assert.equal(await status.innerText(), `顯示 ${stacked}／共 ${rows.length} 筆`);
  await page.screenshot({ path: path.join(screens, `b4-${screenName}-filtered.png`) });
  await search.fill(''); await groupSelect.selectOption(''); await archSelect.selectOption('');
  assert.equal(await status.innerText(), `顯示 ${rows.length}／共 ${rows.length} 筆`);
}

async function checkSoftwareCsv({ page, button, scope, rows, required, label }) {
  const status = scope.locator('[role=status][aria-atomic=true]').first();
  let csv = await captureCsv(page, button);
  assert.equal(csv.length - 1, rows.length, `${label}: unfiltered CSV must hold every row, not only the page`);
  assert.deepEqual(csv[0], [...HEADERS, 'SoftwareId'], `${label}: CSV columns match the screen, SoftwareId last`);
  const byId = new Map(rows.map(r => [r.SoftwareId, r])), idCol = csv[0].length - 1;
  for (const row of csv.slice(1)) assert.ok(byId.has(row[idCol]), `${label}: unknown SoftwareId ${row[idCol]}`);
  const cell = (id, col) => csv.find(r => r[idCol] === id)[HEADERS.indexOf(col)];
  assert.ok(cell('sw-formula', '名稱').startsWith("'=SUM"), `${label}: formula-leading names must be neutralised`);
  assert.equal(cell('sw-unknown', '版本'), '未知', `${label}: unknown version`);
  assert.equal(cell('sw-req-01', '選用版本'), '1.5', `${label}: chosen version from the saved choice`);
  assert.ok(cell('sw-req-02', '選用版本').includes('同來源') && cell('sw-req-02', '選用版本').includes('已過期'), `${label}: stale choice is not applied`);
  assert.ok(cell('sw-req-03', '選用版本').endsWith('（同來源）'), `${label}: no choice shows the source version marked as same-source`);
  assert.equal(csv.filter(r => r[HEADERS.indexOf('名稱')] === 'Dual arch tool').length, 2, `${label}: dual architecture rows`);
  assert.deepEqual(csv.filter(r => r[HEADERS.indexOf('名稱')] === 'Per user tool').map(r => r[HEADERS.indexOf('範圍')]).sort(), ['User · HOST\\alice', 'User · HOST\\bob'], `${label}: multi-account rows stay distinct`);
  const notes = csv.slice(1).map(r => r[HEADERS.indexOf('人工備註')]).filter(Boolean);
  assert.ok(notes.length > 0 && notes.every(n => !n.includes('hunter2')) && notes.some(n => n.includes('password=[redacted]')), `${label}: notes carry no secrets`);
  assert.ok(csv.slice(1).some(r => r[HEADERS.indexOf('審閱狀態')] === '已審閱') && csv.slice(1).some(r => r[HEADERS.indexOf('審閱狀態')].includes('已過期')) && csv.slice(1).some(r => r[HEADERS.indexOf('審閱狀態')] === '未審閱'), `${label}: all review states appear`);
  // Filtered CSV: only the filtered rows.
  await scope.getByLabel('分組', { exact: true }).selectOption({ label: GROUP_REQUIRED });
  csv = await captureCsv(page, button);
  assert.equal(csv.length - 1, required.length, `${label}: filtered CSV holds exactly the filtered rows`);
  assert.deepEqual(new Set(csv.slice(1).map(r => r[idCol])), new Set(required.map(r => r.SoftwareId)));
  await scope.getByLabel('分組', { exact: true }).selectOption('');
  return csv;
}

(async () => {
  const normal = buildSoftwareFixture('Normal'), empty = buildSoftwareFixture('Empty'), big = buildSoftwareFixture('Big'), legacy = buildLegacyFixture();
  const targetPartial = buildTargetFixture('Target'), targetComplete = buildTargetFixture('TargetComplete');
  const { rows, required } = softwareExpectations(normal.results);
  const features = normal.results.Software.FeatureRows;
  assert.equal(features.length, 2);
  const browser = await chromium.launch({ headless: true, executablePath: edge });
  const errors = [];
  const server = http.createServer();
  const watch = page => { page.on('pageerror', e => errors.push('pageerror: ' + e.message)); page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); }); };
  let reportCsv = null;
  try {
    // ================= A. offline report =================
    {
      const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      await context.addInitScript(blobCapture);
      const page = await context.newPage(); watch(page);
      await page.goto(fileUrl(normal.report)); await page.waitForSelector('[role=tablist]');
      const tabs = page.locator('[role=tablist] [role=tab]');
      assert.equal(await tabs.nth(2).innerText(), `安裝軟體（${rows.length}）`);
      await tabs.nth(2).click();
      const section = page.locator('#software');
      // Not printable until asked: the checklist stays out of a normal print.
      await page.emulateMedia({ media: 'print' });
      assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById('checklist')).display), 'none', 'checklist must not appear in a normal print');
      await page.emulateMedia({ media: 'screen' });
      assert.ok((await section.innerText()).includes('軟體盤點有 1 個範圍未完整取得') && (await section.locator('.software-gaps').innerText()).includes('權限不足'), 'permission-denied coverage gap must be visible on the software tab');
      await checkSoftwareTable({ page, scope: section, table: page.locator('#tbl-software'), statusScope: section.locator('.toolbar:has(#tbl-software-q)'), rows, required, label: 'report', screenName: 'report-software' });
      reportCsv = await checkSoftwareCsv({ page, button: section.locator('.toolbar:has(#tbl-software-q)').getByRole('button', { name: '匯出 CSV' }), scope: section.locator('.toolbar:has(#tbl-software-q)'), rows, required, label: 'report' });
      // Features: structured workload column, own status element.
      assert.deepEqual(await section.locator('#tbl-features thead th').allInnerTexts(), ['顯示名稱', 'Install-WindowsFeature 名稱', '關聯工作負載']);
      const featureText = await section.locator('#tbl-features tbody').innerText();
      assert.ok(featureText.includes('Web-Asp-Net45') && featureText.includes('Site A') && featureText.includes('未關聯'), 'a feature with a structured link shows its workload; others show 未關聯');
      // Required row shows its workload; others say why not.
      const workloadCells = await section.locator('#tbl-software tbody tr').evaluateAll(trs => trs.map(tr => tr.cells[8].textContent));
      assert.ok(workloadCells.some(t => t.includes('Site A')) && workloadCells.some(t => t.includes('Task <b>B</b>')) && workloadCells.some(t => t === '無關聯證據') && workloadCells.some(t => t === '關聯項目未選入'), 'workload cell must show names, no-evidence and unselected-link wording');
      assert.equal(await section.locator('#tbl-software tbody b').count(), 0, 'workload names must never become markup');
      // Keyboard focus is visible on the print button.
      const printButton = section.getByRole('button', { name: '列印新機安裝檢查表' });
      await printButton.focus();
      assert.ok(await printButton.evaluate(b => parseFloat(getComputedStyle(b).outlineWidth) >= 2 && getComputedStyle(b).outlineStyle !== 'none'), 'print button needs a visible focus outline');
      // Print simulation: a button, not a download; all rows, controls hidden, check boxes present.
      await stubPrint(page);
      await printButton.click();
      assert.equal(await page.evaluate(() => window.__prints), 1, 'the button must open the browser print');
      assert.ok(await page.evaluate(() => document.body.classList.contains('print-checklist')));
      await page.emulateMedia({ media: 'print' });
      const info = await page.evaluate(() => {
        const visible = e => { for (let n = e; n; n = n.parentElement) if (getComputedStyle(n).display === 'none') return false; return true; };
        const softwareTables = [...document.querySelectorAll('#checklist table')];
        return { boxes: [...document.querySelectorAll('#checklist .check-box')].filter(visible).length, mainHidden: getComputedStyle(document.querySelector('main')).display === 'none', checklistShown: visible(document.getElementById('checklist')), controlsHidden: [...document.querySelectorAll('.toolbar,.pager,.tabs')].every(e => !visible(e)), headings: [...document.querySelectorAll('#checklist h2')].map(h => h.textContent), heads: softwareTables.map(t => getComputedStyle(t.tHead).display), rowBreak: getComputedStyle(document.querySelector('#checklist tbody tr')).breakInside, columns: [...document.querySelectorAll('#checklist table')][0] ? [...document.querySelectorAll('#checklist table')][0].tHead.rows[0].cells.length : 0, title: document.querySelector('#checklist h1').textContent };
      });
      assert.equal(info.boxes, rows.length + features.length, 'print must show a check box for every software row and feature (no paging)');
      assert.ok(info.mainHidden && info.checklistShown && info.controlsHidden, JSON.stringify(info));
      assert.equal(info.title, '新機安裝檢查表');
      assert.deepEqual(info.headings.map(h => h.replace(/（\d+）/, '')), [GROUP_REQUIRED, GROUP_OTHER, 'Windows 角色與功能']);
      assert.equal(info.headings[0], `${GROUP_REQUIRED}（${required.length}）`);
      assert.ok(info.heads.every(d => d === 'table-header-group') && info.rowBreak === 'avoid' && info.columns === 8);
      const checklistText = await page.locator('#checklist').innerText();
      assert.ok(checklistText.includes('1.5') && checklistText.includes('Install-WindowsFeature') && checklistText.includes('Web-Asp-Net45'), 'checklist holds chosen version and features');
      assert.ok(!checklistText.includes('hunter2'));
      await page.screenshot({ path: path.join(screens, 'b4-report-print.png') });
      await page.emulateMedia({ media: 'screen' });
      await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
      assert.equal(await page.evaluate(() => document.body.classList.contains('print-checklist')), false, 'leaving print mode restores the screen');
      assert.equal(await page.evaluate(() => getComputedStyle(document.getElementById('checklist')).display), 'none');
      // No download or install control anywhere.
      assert.equal(await page.getByRole('button', { name: /下載|^(立即|自動)?安裝/ }).count(), 0, 'no install or download button');
      await page.setViewportSize({ width: 390, height: 844 });
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 0, `software tab overflows the 390px viewport by ${overflow}px`);
      await page.screenshot({ path: path.join(screens, 'b4-report-390.png') });
      await context.close();
    }
    // report: reduced motion + JavaScript off
    {
      const reduced = await browser.newContext({ viewport: { width: 1280, height: 900 }, reducedMotion: 'reduce' });
      const page = await reduced.newPage(); watch(page);
      await page.goto(fileUrl(normal.report)); await page.waitForSelector('[role=tablist]');
      assert.equal(await page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches), true);
      await reduced.close();
      const noJs = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 1280, height: 900 } });
      const noJsPage = await noJs.newPage();
      await noJsPage.goto(fileUrl(normal.report));
      assert.equal(await noJsPage.locator('#tbl-software tbody tr:visible').count(), rows.length, 'without JavaScript every software row is on the page');
      assert.equal(await noJsPage.getByRole('button', { name: '列印新機安裝檢查表' }).count(), 0);
      await noJs.close();
    }
    // report: empty / big / legacy
    {
      const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      await context.addInitScript(blobCapture);
      const page = await context.newPage(); watch(page);
      await page.goto(fileUrl(empty.report)); await page.waitForSelector('[role=tablist]');
      await page.locator('[role=tablist] [role=tab]').nth(2).click();
      const section = page.locator('#software');
      assert.ok((await section.innerText()).includes('沒有發現已安裝軟體'));
      assert.equal(await section.locator('#tbl-software').count(), 0);
      assert.equal(await section.locator('.callout').count(), 0, 'an empty inventory is not an error');
      await page.screenshot({ path: path.join(screens, 'b4-report-empty.png') });
      await stubPrint(page); await section.getByRole('button', { name: '列印新機安裝檢查表' }).click();
      await page.emulateMedia({ media: 'print' });
      assert.ok((await page.locator('#checklist').innerText()).includes('沒有發現已安裝軟體'));
      await page.emulateMedia({ media: 'screen' });

      await page.goto(fileUrl(big.report)); await page.waitForSelector('[role=tablist]');
      await page.locator('[role=tablist] [role=tab]').nth(2).click();
      const bigSection = page.locator('#software');
      assert.equal(await bigSection.locator('.toolbar:has(#tbl-software-q) [role=status]').innerText(), '顯示 2501／共 2501 筆');
      const bigCsv = await captureCsv(page, bigSection.locator('.toolbar:has(#tbl-software-q)').getByRole('button', { name: '匯出 CSV' }));
      assert.equal(bigCsv.length - 1, 2501, 'CSV is not capped at the page size');
      await stubPrint(page); await bigSection.getByRole('button', { name: '列印新機安裝檢查表' }).click();
      await page.emulateMedia({ media: 'print' });
      const bigBoxes = await page.evaluate(() => [...document.querySelectorAll('#checklist .check-box')].filter(e => { for (let n = e; n; n = n.parentElement) if (getComputedStyle(n).display === 'none') return false; return true; }).length);
      assert.equal(bigBoxes, 2501 + 2, 'print must not truncate at 2000 rows');
      await context.close();

      const legacyContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      const legacyPage = await legacyContext.newPage(); watch(legacyPage);
      await legacyPage.goto(fileUrl(legacy.report)); await legacyPage.waitForSelector('[role=tablist]');
      await legacyPage.locator('[role=tablist] [role=tab]').nth(2).click();
      const legacyText = await legacyPage.locator('#software').innerText();
      assert.ok(legacyText.includes('此結果集未記錄工作負載分組'));
      const legacyRow = await legacyPage.locator('#tbl-software tbody tr').first().innerText();
      assert.ok(legacyRow.includes('未記錄') && !legacyRow.includes(GROUP_REQUIRED) && !legacyRow.includes(GROUP_OTHER), 'legacy rows show 未記錄 instead of inventing a group: ' + legacyRow);
      await legacyPage.screenshot({ path: path.join(screens, 'b4-report-legacy.png') });
      await legacyContext.close();
    }

    // ================= B. workbench =================
    const staticFiles = new Map([['/', 'index.html'], ['/ui/index.html', 'index.html'], ['/ui/console.js', 'console.js'], ['/ui/console.css', 'console.css'], ['/ui/guide.html', 'guide.html'], ['/ui/nonc.js', 'nonc.js']]);
    let scenario = null;
    server.on('request', (request, response) => {
      const name = staticFiles.get(new URL(request.url, 'http://127.0.0.1').pathname);
      if (!name) { response.writeHead(404); response.end('Not found'); return; }
      const file = path.join(root, 'src', 'ui', name);
      response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' });
      fs.createReadStream(file).pipe(response);
    });
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    const base = `http://127.0.0.1:${server.address().port}/`;
    const session = role => ({ token: 'memory-only-test-token', sessionId: 'fixture-session', contextId: 'fixture-context', hostName: 'fixture-host', role, workspace: root, pairId: 'fixture-pair', revision: 5, decisionRevision: 7, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: 'fixture-data-1', principal: 'fixture-user' });
    const viewContext = role => { const s = session(role); return { sessionId: s.sessionId, contextId: s.contextId, pairId: 'fixture-pair', role, revision: s.revision, decisionRevision: s.decisionRevision, selectionRevision: s.selectionRevision, sourceSelectionRevision: s.sourceSelectionRevision, dataVersion: s.dataVersion, readUtc: new Date().toISOString() }; };
    const actionOf = id => ({ id, available: true, reason: `Fixture ${id}`, defaults: { Workspace: root, PairId: 'fixture-pair' }, missing: [] });
    async function openApp(role, hash, handler) {
      const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      await context.addInitScript(blobCapture);
      const page = await context.newPage(); watch(page);
      const s = session(role);
      await page.route(/\/api\/.*/, async route => {
        const request = route.request(), parsed = new URL(request.url()), pathname = parsed.pathname;
        const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
        if (pathname === '/api/session') return json(s);
        if (pathname === '/api/context' && request.method() === 'GET') return json({ roles: [role], pairs: [{ pairId: 'fixture-pair', label: 'Fixture pair' }], role, pairId: 'fixture-pair', revision: s.revision, decisionRevision: s.decisionRevision, selectionRevision: s.selectionRevision, sourceSelectionRevision: s.sourceSelectionRevision, dataVersion: s.dataVersion });
        if (pathname === '/api/wizard') return json({ kind: 'WizardProjection', intentRequired: false, legacy: false, role, workspaceRole: role, roleMatchesWorkspace: true, pairId: 'fixture-pair', state: { CurrentStep: role === 'Target' ? 'handoff' : 'backup', Mode: 'ItemByItem' }, revision: s.revision, currentStep: role === 'Target' ? 'handoff' : 'backup', reviewGroupIndex: 0, groups: [], gates: [], actions: [], missingFields: [], scan: { status: 'Succeeded', hasResult: true, itemCount: 3, incompleteCount: 0 }, results: { scan: { status: 'Succeeded', hasDurableRecord: true }, backup: { status: 'Succeeded', hasDurableRecord: true }, restore: { status: 'NotStarted', hasDurableRecord: false }, hasAny: true }, context: { catalogRevision: 7, selectionRevision: 3, inventoryRevision: 1 } });
        if (pathname === '/api/wizard/runtime') return json({ Kind: 'WizardRuntimeProjection', Role: role, PairId: 'fixture-pair', status: scenario && scenario.targetStatus, actions: scenario && scenario.actions || [], runtime: { target: scenario && scenario.target }, viewContext: viewContext(role) });
        if (pathname === '/api/wizard/nonc') return json({ Kind: 'WizardNonCProjection', Role: role, PairId: 'fixture-pair', ContextId: s.contextId, DataVersion: s.dataVersion });
        if (pathname === '/api/jobs' && request.method() === 'GET') return json({ items: [{ jobId: 'fixture-backup-job', workspace: root, pairId: 'fixture-pair', role: 'Source', sessionId: 'fixture-session', contextId: 'fixture-context', startedRevision: 5, action: 'StartBackup', status: 'Succeeded', canCancel: false }] });
        if (pathname === '/api/view' && request.method() === 'GET') {
          if (parsed.searchParams.get('contextId') !== s.contextId || parsed.searchParams.get('dataVersion') !== s.dataVersion) return json({ code: 'stale_revision', message: 'Fixture view changed.', nextStep: 'Reload.', correlationId: 'fixture-stale' }, 409);
          if (parsed.searchParams.get('action') === 'backup-items') return handler(json);
          return json({ viewContext: viewContext(role), rows: [], items: [] });
        }
        errors.push(`unhandled fixture route ${request.method()} ${pathname}`);
        return json({ message: `Unhandled fixture route ${request.method()} ${pathname}` }, 404);
      });
      await page.goto(base + hash, { waitUntil: 'domcontentloaded' });
      return { page, context };
    }
    const viewOf = results => json => json({ kind: 'BackupItemResultsView', available: true, integrity: 'Verified', attemptId: 'fixture-attempt', backupOperationId: 'fixture-op', generatedUtc: results.GeneratedUtc, inventorySource: results.InventorySource, offlineReadiness: 'AwaitingIndependentCopy', counts: results.Counts, rows: results.Rows, software: results.Software, schemaVersion: results.SchemaVersion || 1, coverageRegions: Object.prototype.hasOwnProperty.call(results, 'CoverageRegions') ? results.CoverageRegions : null, independentCopy: { state: 'NotVerified', text: '尚未驗證', verifiedUtc: '', networkUnconfirmed: false, reason: '' }, viewContext: viewContext('Source') });
    const openSoftware = async (results) => {
      const app = await openApp('Source', '#jobs?filter=backup', viewOf(results));
      await app.page.waitForSelector('#backup-item-results [role=tablist]', { timeout: 30000 });
      await app.page.locator('#backup-tab-software').click();
      return app;
    };
    {
      const { page, context } = await openSoftware(normal.results);
      const panel = page.locator('#backup-panel-software');
      assert.equal(await page.locator('#backup-tab-software').innerText(), `安裝軟體（${rows.length}）`);
      assert.equal(await panel.getByRole('button', { name: '匯出 CSV' }).count(), 2, 'one CSV per table');
      await checkSoftwareTable({ page, scope: panel, table: panel.locator('table').first(), statusScope: panel.locator('.backup-toolbar:has(#backup-software-search)'), rows, required, label: 'workbench', screenName: 'workbench-software' });
      const workbenchCsv = await checkSoftwareCsv({ page, button: panel.locator('.backup-toolbar:has(#backup-software-search)').getByRole('button', { name: '匯出 CSV' }), scope: panel.locator('.backup-toolbar:has(#backup-software-search)'), rows, required, label: 'workbench' });
      assert.deepEqual(workbenchCsv, reportCsv, 'workbench and report CSV must be identical for the same result set');
      assert.ok((await panel.innerText()).includes('軟體盤點有 1 個範圍未完整取得') && (await panel.locator('.software-gaps').innerText()).includes('權限不足'));
      assert.deepEqual(await panel.locator('table').nth(1).locator('thead th').allTextContents(), ['顯示名稱', 'Install-WindowsFeature 名稱', '關聯工作負載']);
      assert.ok((await panel.locator('table').nth(1).locator('tbody').innerText()).includes('Site A'));
      assert.equal(await panel.locator('tbody b, tbody img').count(), 0, 'names never become markup');
      // Print.
      const printButton = panel.getByRole('button', { name: '列印新機安裝檢查表' });
      await printButton.focus(); await page.keyboard.press('Shift+Tab'); await page.keyboard.press('Tab');
      assert.ok(await printButton.evaluate(b => document.activeElement === b && getComputedStyle(b).outlineStyle !== 'none' && parseFloat(getComputedStyle(b).outlineWidth) >= 2), 'visible keyboard focus');
      await stubPrint(page); await printButton.click();
      assert.equal(await page.evaluate(() => window.__prints), 1);
      assert.ok(await page.evaluate(() => document.body.classList.contains('printing-checklist')));
      await page.emulateMedia({ media: 'print' });
      const info = await page.evaluate(() => {
        const visible = e => { for (let n = e; n; n = n.parentElement) if (getComputedStyle(n).display === 'none') return false; return true; };
        return { boxes: [...document.querySelectorAll('#print-checklist .check-box')].filter(visible).length, othersHidden: [...document.body.children].filter(c => !c.classList.contains('print-checklist')).every(c => getComputedStyle(c).display === 'none'), headings: [...document.querySelectorAll('#print-checklist h2')].map(h => h.textContent), heads: [...document.querySelectorAll('#print-checklist table')].map(t => getComputedStyle(t.tHead).display), shown: visible(document.getElementById('print-checklist')) };
      });
      assert.equal(info.boxes, rows.length + features.length, 'workbench print shows every row');
      assert.ok(info.othersHidden && info.shown && info.heads.every(d => d === 'table-header-group'), JSON.stringify(info));
      assert.deepEqual(info.headings.map(h => h.replace(/（\d+）/, '')), [GROUP_REQUIRED, GROUP_OTHER, 'Windows 角色與功能']);
      await page.screenshot({ path: path.join(screens, 'b4-workbench-print.png') });
      await page.emulateMedia({ media: 'screen' });
      await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
      assert.equal(await page.locator('#print-checklist').count(), 0, 'the temporary checklist is removed after printing');
      assert.equal(await page.evaluate(() => document.body.classList.contains('printing-checklist')), false);
      await page.setViewportSize({ width: 390, height: 844 });
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth) <= 0, 'workbench software tab fits 390px');
      await page.screenshot({ path: path.join(screens, 'b4-workbench-390.png') });
      await context.close();
    }
    {
      const emptyApp = await openSoftware(empty.results);
      const panel = emptyApp.page.locator('#backup-panel-software');
      assert.ok((await panel.innerText()).includes('沒有發現已安裝軟體'));
      assert.equal(await panel.locator('table').count(), 1, 'only the features table remains for an empty software inventory');
      assert.ok((await panel.locator('table caption').innerText()).includes('Windows 角色與功能'));
      assert.equal(await panel.locator('.callout').count(), 0, 'empty inventory is not an error');
      await emptyApp.page.screenshot({ path: path.join(screens, 'b4-workbench-empty.png') });
      await emptyApp.context.close();

      const bigApp = await openSoftware(big.results);
      const bigPanel = bigApp.page.locator('#backup-panel-software');
      assert.equal(await bigPanel.locator('.backup-toolbar:has(#backup-software-search) [role=status]').innerText(), '顯示 2501／共 2501 筆');
      const bigCsv = await captureCsv(bigApp.page, bigPanel.locator('.backup-toolbar:has(#backup-software-search)').getByRole('button', { name: '匯出 CSV' }));
      assert.equal(bigCsv.length - 1, 2501);
      await stubPrint(bigApp.page); await bigPanel.getByRole('button', { name: '列印新機安裝檢查表' }).click();
      await bigApp.page.emulateMedia({ media: 'print' });
      assert.equal(await bigApp.page.evaluate(() => [...document.querySelectorAll('#print-checklist .check-box')].filter(e => { for (let n = e; n; n = n.parentElement) if (getComputedStyle(n).display === 'none') return false; return true; }).length), 2501 + 2, 'workbench print is not capped at 2000 rows');
      await bigApp.context.close();

      const legacyApp = await openSoftware(legacy.results);
      const legacyPanel = legacyApp.page.locator('#backup-panel-software');
      assert.ok((await legacyPanel.innerText()).includes('此結果集未記錄工作負載分組'));
      const legacyRow = await legacyPanel.locator('table tbody tr').first().innerText();
      assert.ok(legacyRow.includes('未記錄') && !legacyRow.includes(GROUP_REQUIRED) && !legacyRow.includes(GROUP_OTHER), legacyRow);
      await legacyApp.page.screenshot({ path: path.join(screens, 'b4-workbench-legacy.png') });
      await legacyApp.context.close();
    }

    // ================= C. Target: new machine check =================
    const targetBase = { status: 'NeedsTargetDecision', plan: { hash: 'a'.repeat(64) }, package: { ManifestHash: 'a'.repeat(64) }, inventory: { SHA256: 'b'.repeat(64) }, comparison: { Status: 'Imported' }, decision: null, restorePreview: null, restoreResult: null, itemOptions: [], mechanicalValidation: { available: false, status: 'Locked' }, businessAcceptance: { available: false, status: 'NotAccepted' }, activation: { available: false, status: 'Locked' }, issues: [] };
    const openTarget = async (target, actions) => {
      scenario = { target, targetStatus: target.status, actions };
      const app = await openApp('Target', '#wizard', () => { throw new Error('backup view is not used on the Target'); });
      await app.page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state && window.WsmConsole.state.wizard && window.WsmConsole.state.wizard.currentStep === 'handoff');
      await app.page.evaluate(() => { const c = window.WsmConsole; c.state.wizardRuntimeProjection = null; c.state.wizardRuntimeIdentity = ''; c.renderWizard(c.state.wizard); c.renderWizard(c.state.wizard); });
      await app.page.waitForSelector('.wizard-runtime-target h2', { timeout: 30000 });
      return app;
    };
    {
      // No comparison material: only the empty state and the existing local-comparison entry; no state column, no fake values.
      const { page, context } = await openTarget(Object.assign({}, targetBase, { status: 'NeedsComparison', comparison: null, softwareCheck: null }), [actionOf('ExportTargetHandoff'), actionOf('ComparisonImport'), actionOf('TargetLocalComparison')]);
      await page.waitForSelector('#software-check', { timeout: 30000 });
      const section = page.locator('#software-check');
      assert.ok((await section.innerText()).includes('尚未產生新機比較'));
      assert.equal(await section.locator('table').count(), 0, 'no list without comparison material');
      assert.equal(await page.getByText('新機目前狀態').count(), 0, 'no state column without comparison material');
      assert.ok(await page.getByRole('button', { name: '在本機產生比較' }).count() === 1, 'the existing local-comparison entry stays');
      await page.screenshot({ path: path.join(screens, 'b4-target-nocomparison.png') });
      await context.close();
      // Before the comparison step, nothing about software state is shown at all.
      const early = await openTarget(Object.assign({}, targetBase, { status: 'NeedsTargetInventory', inventory: null, comparison: null, softwareCheck: null }), [actionOf('Inventory')]);
      assert.equal(await early.page.locator('#software-check').count(), 0);
      await early.context.close();
    }
    for (const [name, check, expectIncomplete] of [['partial', targetPartial, true], ['complete', targetComplete, false]]) {
      const { page, context } = await openTarget(Object.assign({}, targetBase, { softwareCheck: check }), [actionOf('CreateTargetDecisionReceipt')]);
      await page.waitForSelector('#software-check table', { timeout: 30000 });
      const section = page.locator('#software-check');
      const states = ['已安裝', '版本不同', '未安裝', '未知'];
      const columns = ['名稱', '來源版本', '選用版本', '新機觀測版本', '新機目前狀態', '原因'];
      assert.deepEqual(await section.locator('table').first().locator('thead th').allTextContents(), columns);
      const status = section.locator('.backup-toolbar:has(#target-software-search) [role=status][aria-atomic=true]');
      assert.equal(await status.count(), 1);
      assert.equal(await status.innerText(), `顯示 ${check.Rows.length}／共 ${check.Rows.length} 筆`);
      const badges = await section.locator('table').first().locator('tbody .backup-badge').evaluateAll(list => list.map(b => ({ text: b.textContent.trim(), icon: b.dataset.icon })));
      assert.ok(badges.length === check.Rows.length && badges.every(b => b.text && b.icon), 'every state is text plus icon');
      assert.ok(badges.every(b => states.includes(b.text)), 'only the four states may appear: ' + JSON.stringify(badges));
      const countOf = text => check.Rows.filter(r => r.CheckStateText === text).length;
      const stateSelect = section.getByLabel('新機狀態', { exact: true });
      assert.deepEqual((await stateSelect.locator('option').allInnerTexts()), ['全部', ...states]);
      for (const text of states) {
        await stateSelect.selectOption({ label: text });
        assert.equal(await status.innerText(), `顯示 ${countOf(text)}／共 ${check.Rows.length} 筆`, `${name}: filter ${text}`);
        if (countOf(text)) assert.ok((await section.locator('table').first().locator('tbody td:nth-child(5)').allInnerTexts()).every(t => t.includes(text)));
      }
      if (name === 'complete') { assert.ok(countOf('已安裝') >= 1 && countOf('版本不同') >= 1 && countOf('未安裝') >= 1 && countOf('未知') >= 1, 'all four states have an example'); }
      else { assert.equal(countOf('未安裝'), 0, 'incomplete coverage never reads as 未安裝'); assert.ok(check.Rows.some(r => r.SourceStatus === 'TargetMissing' && r.CheckState === 'Unknown')); }
      await stateSelect.selectOption('');
      await section.getByLabel('搜尋名稱或發行者', { exact: true }).fill('alpha');
      assert.equal(await status.innerText(), `顯示 1／共 ${check.Rows.length} 筆`);
      await stateSelect.selectOption({ label: '版本不同' });
      assert.equal(await status.innerText(), `顯示 0／共 ${check.Rows.length} 筆`, 'search stacks with the filter');
      await stateSelect.selectOption(''); await section.getByLabel('搜尋名稱或發行者', { exact: true }).fill('');
      assert.equal((await section.innerText()).includes('涵蓋不完整或未記錄'), expectIncomplete, 'coverage warning only when incomplete');
      // Target-only software is listed apart and is not counted in the four states.
      assert.ok((await section.innerText()).includes('新機獨有') && (await section.innerText()).includes('Foxtrot only here'));
      assert.equal(await section.locator('table').first().locator('tbody').innerText().then(t => t.includes('Foxtrot only here')), false, 'target-only software is not in the four-state list');
      // CSV.
      const csv = await captureCsv(page, section.getByRole('button', { name: '匯出 CSV' }));
      assert.deepEqual(csv[0], columns);
      assert.equal(csv.length - 1, check.Rows.length);
      assert.ok(csv.some(r => r[0].startsWith("'=") || r[0] === 'Bravo =runtime'), 'names stay readable');
      // Print.
      await stubPrint(page); await section.getByRole('button', { name: '列印新機安裝檢查表' }).click();
      assert.equal(await page.evaluate(() => window.__prints), 1);
      await page.emulateMedia({ media: 'print' });
      const printed = await page.evaluate(() => ({ boxes: [...document.querySelectorAll('#print-checklist .check-box')].filter(e => { for (let n = e; n; n = n.parentElement) if (getComputedStyle(n).display === 'none') return false; return true; }).length, text: document.getElementById('print-checklist').innerText }));
      assert.equal(printed.boxes, check.Rows.length);
      assert.ok(printed.text.includes('新機獨有') && printed.text.includes('Foxtrot only here') && printed.text.includes('新機目前狀態'));
      await page.screenshot({ path: path.join(screens, `b4-target-${name}-print.png`) });
      await page.emulateMedia({ media: 'screen' });
      await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
      await page.screenshot({ path: path.join(screens, `b4-target-${name}.png`), fullPage: true });
      await page.setViewportSize({ width: 390, height: 844 });
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth) <= 0, `${name}: Target software check fits 390px: ` + JSON.stringify(await page.evaluate(() => [...document.querySelectorAll('body *')].filter(e => e.getBoundingClientRect().right > document.documentElement.clientWidth + 1 && !e.closest('.table-wrap')).slice(0, 8).map(e => `${e.tagName}.${e.className}#${e.id}:${Math.round(e.getBoundingClientRect().right)}`))));
      await page.screenshot({ path: path.join(screens, `b4-target-${name}-390.png`) });
      await context.close();
    }
    {
      // A comparison with no software rows is not the same as no comparison.
      const { page, context } = await openTarget(Object.assign({}, targetBase, { softwareCheck: { available: true, ComparisonRevision: 1, CoverageComplete: true, Rows: [], TargetOnlyRows: [] } }), []);
      await page.waitForSelector('#software-check', { timeout: 30000 });
      assert.ok((await page.locator('#software-check').innerText()).includes('比較材料中沒有來源軟體列'));
      assert.equal(await page.locator('#software-check table').count(), 0);
      await context.close();
    }

    assert.deepEqual(errors, [], 'no console errors expected');
    console.log(`PASS: software tab browser test (${rows.length} rows, ${required.length} required, report + workbench + Target).`);
  } finally {
    await browser.close();
    server.close();
    for (const dir of [normal.dir, empty.dir, big.dir, legacy.dir]) fs.rmSync(dir, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exit(1); });
