// Real-browser (Edge, file://) test for the offline backup report: paging, search, filters,
// CSV export, no-JS fallback, print layout, 390px layout and console errors.
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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-b3-' + shape.toLowerCase() + '-'));
  const run = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tests', 'New-OfflineReportFixture.ps1'), '-OutDir', dir, '-Shape', shape, '-Scale', scale || 'Standard'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  assert.equal(run.status, 0, 'fixture build failed: ' + run.stderr);
  const expected = JSON.parse(fs.readFileSync(path.join(dir, 'expected.json'), 'utf8').replace(/^\ufeff/, ''));
  return { dir, report: path.join(dir, 'backup-report.html'), results: path.join(dir, 'backup-item-results.json'), expected };
}
const fileUrl = file => 'file:///' + file.replace(/\\/g, '/');

// Minimal RFC4180 parser for the CSV produced by the report.
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

async function captureCsv(page, panel) {
  await page.evaluate(() => { window.__blobs = []; });
  await panel.getByRole('button', { name: '匯出 CSV' }).first().click();
  const bytes = await page.evaluate(async () => { const blob = window.__blobs.pop(); return Array.from(new Uint8Array(await blob.arrayBuffer())); });
  const buffer = Buffer.from(bytes);
  assert.deepEqual([...buffer.subarray(0, 3)], [0xEF, 0xBB, 0xBF], 'CSV must start with a UTF-8 BOM');
  const text = buffer.subarray(3).toString('utf8');
  assert.ok(!/(^|[^\r])\n/.test(text), 'CSV line breaks must be CRLF only');
  return parseCsv(text);
}

(async () => {
  const fixture = buildFixture('V2');
  const expected = fixture.expected;
  const backedExpected = expected.Rows.filter(r => r.Status === 'BackedUp');
  const pendingExpected = expected.Rows.filter(r => r.Status === 'NotBackedUp');
  assert.ok(expected.Total > 250, 'fixture must exceed 250 rows');
  const browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
  const consoleErrors = [];
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    await context.addInitScript(() => { window.__blobs = []; const original = URL.createObjectURL; URL.createObjectURL = function (blob) { window.__blobs.push(blob); return original.call(URL, blob); }; });
    const page = await context.newPage();
    page.on('pageerror', e => consoleErrors.push(e.message));
    page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
    await page.goto(fileUrl(fixture.report));
    await page.waitForSelector('[role=tablist]');

    // Header: full hashes and the media-state note, four-layer explanation.
    const meta = await page.locator('dl.meta').innerText();
    assert.ok(meta.includes('a'.repeat(64)) && meta.includes('b'.repeat(64)), 'ManifestHash and PlanHash must be shown in full');
    assert.ok((await page.locator('[role=note]').first().innerText()).includes('不代表目前備份媒體仍然完整'));
    const layers = await page.locator('.layers').innerText();
    assert.ok(layers.includes('資料已備份') && layers.includes('獨立副本已驗證') && layers.includes('可還原條件') && layers.includes('業務可用'));
    assert.equal((layers.match(/不在此報告判定/g) || []).length, 2, 'two layers must say they are not judged here');

    // Tabs keep WAI-ARIA behaviour.
    const tabs = page.locator('[role=tablist] [role=tab]');
    assert.equal(await tabs.count(), 3);
    await tabs.nth(0).focus(); await page.keyboard.press('ArrowRight');
    assert.equal(await tabs.nth(1).getAttribute('aria-selected'), 'true');
    await page.keyboard.press('ArrowLeft');
    assert.equal(await tabs.nth(0).getAttribute('aria-selected'), 'true');

    // Backed tab: paging to the last page, search, filters, status summary.
    const backed = page.locator('#backed');
    const status = backed.locator('[role=status][aria-atomic=true]');
    assert.equal(await status.count(), 1, 'exactly one status element per table');
    assert.equal(await status.innerText(), `顯示 ${backedExpected.length}／共 ${backedExpected.length} 筆`);
    assert.ok(await backed.locator('.table-wrap[role=region][tabindex="0"]').count() >= 1, 'table region must be named and focusable');
    const pages = Math.ceil(backedExpected.length / 100);
    for (let i = 1; i < pages; i++) await backed.getByRole('button', { name: '下一頁' }).click();
    assert.ok((await backed.locator('tbody tr:not([hidden])').allInnerTexts()).some(t => t.includes('zz-last-backed')), 'last page must show the last backed item');
    await page.screenshot({ path: path.join(screens, 'b3-desktop-backed-lastpage.png') });
    await backed.getByRole('button', { name: '上一頁' }).click();

    const search = backed.getByLabel('搜尋名稱或位置');
    await search.fill('zz-last');
    assert.equal(await status.innerText(), `顯示 1／共 ${backedExpected.length} 筆`);
    assert.equal(await backed.locator('tbody tr:not([hidden])').count(), 1);
    await search.fill('');

    const kindSelect = backed.getByLabel('類型'), restoreSelect = backed.getByLabel('可還原條件');
    assert.ok((await kindSelect.locator('option').allInnerTexts()).includes('Service'));
    const serviceBacked = backedExpected.filter(r => r.Kind === 'Service').length;
    await kindSelect.selectOption('Service');
    assert.equal(await status.innerText(), `顯示 ${serviceBacked}／共 ${backedExpected.length} 筆`);
    // Search stacks with the filter: item-01xx services, and services overall for item-01xx names or locations.
    await search.fill('item-01');
    const stackedExpected = Array.from({ length: 80 }, (_, k) => 100 + k).filter(n => n % 3 === 0).length;
    assert.equal(await status.innerText(), `顯示 ${stackedExpected}／共 ${backedExpected.length} 筆`);
    await search.fill(''); await kindSelect.selectOption('');
    const restoreOptions = await restoreSelect.locator('option').allInnerTexts();
    assert.ok(restoreOptions.includes('全部') && restoreOptions.some(t => t.includes('可還原')));
    await restoreSelect.selectOption({ label: restoreOptions.find(t => t.includes('可還原')) });
    const restorableCount = await page.evaluate(() => [...document.querySelectorAll('#tbl-backed tbody tr')].filter(r => r.cells[8].textContent.includes('可還原')).length);
    assert.equal(await status.innerText(), `顯示 ${restorableCount}／共 ${backedExpected.length} 筆`);
    await restoreSelect.selectOption('');

    // CSV: all filtered rows (not just the visible page), BOM, CRLF, formula neutralised, ids match JSON.
    assert.ok(backedExpected.length > 100, 'CSV paging check needs more than one page');
    let csv = await captureCsv(page, backed);
    assert.equal(csv.length - 1, backedExpected.length, 'unfiltered CSV must contain every backed row, not only the page');
    const header = csv[0];
    const idCol = header.indexOf('項目 ID'), statusCol = header.indexOf('狀態碼'), reasonCol = header.indexOf('原因碼'), nameCol = header.indexOf('名稱');
    assert.ok(idCol >= 0 && statusCol >= 0 && reasonCol >= 0);
    const byId = new Map(expected.Rows.map(r => [r.ItemId, r]));
    for (const row of csv.slice(1)) { const e = byId.get(row[idCol]); assert.ok(e, 'unknown id in CSV ' + row[idCol]); assert.equal(row[statusCol], e.Status); assert.equal(row[reasonCol], e.ReasonCode); }
    const names = csv.slice(1).map(r => r[nameCol]);
    assert.ok(names.includes("'=SUM(1+1)") && names.includes("'@cmd|calc") && names.includes("'+1-2"), 'formula-leading names must be neutralised');
    assert.ok(!names.some(n => /^[=+\-@]/.test(n)), 'no CSV cell may start with a formula character');
    await kindSelect.selectOption('Service');
    csv = await captureCsv(page, backed);
    assert.equal(csv.length - 1, serviceBacked, 'filtered CSV must contain exactly the filtered rows');
    await kindSelect.selectOption('');

    // R24：逐檔下鑽（有界）。item-0010 有 250 個檔案：只列前 200 個並註明另有 50 個；item-0011 只有 3 個。
    {
      const rowOf = id => page.locator(`#tbl-backed tbody tr[data-id="${id}"]`);
      await search.fill('item-0010');
      const row10 = rowOf('item-0010');
      assert.equal(await row10.locator('details.file-detail').count(), 1, 'R24: the backed item carries one static details element');
      const details10 = row10.locator('details.file-detail');
      assert.equal(await details10.evaluate(el => el.open), false, 'R24: the file list starts collapsed');
      const summary10 = details10.locator('summary');
      assert.match(await summary10.innerText(), /檔案明細/, 'R24: the summary names the file list');
      assert.match(await summary10.innerText(), /250/, 'R24: the summary shows the total');
      await summary10.focus(); await page.keyboard.press('Enter');
      assert.equal(await details10.evaluate(el => el.open), true, 'R24: Enter on the summary opens the list (keyboard)');
      assert.equal(await details10.locator('li').count(), 200, 'R24: at most 200 files are listed');
      const text10 = await details10.innerText();
      assert.match(text10, /共 250 個檔案/, 'R24: the total is stated');
      assert.match(text10, /另有 50 個檔案未列出/, 'R24: the remainder hint says how many are not listed');
      assert.match(text10, /完整明細見工作台或 artifacts 索引/, 'R24: the hint points at the full list');
      assert.ok(text10.includes('<img src=x onerror=alert(1)>.txt'), 'R24: a hostile file name is shown as literal text');
      assert.equal(await details10.locator('img, script, iframe, a').count(), 0, 'R24: file names never become elements');
      assert.ok(!text10.includes(String.fromCharCode(0x202e)), 'R24: the right-to-left override is not passed through');
      assert.ok(/rtl\\\\u202e/i.test(text10), 'R24: the override is shown as a visible \\u202E marker');
      assert.ok(text10.includes('…（已截斷）'), 'R24: an over-long path is marked as truncated');
      assert.ok(text10.includes('=SUM(1+1)\\cmd.xlsx'), 'R24: a formula-looking path is plain text');
      assert.ok(text10.includes('bulk\\file-001.dat') && !text10.includes('bulk\\file-244.dat'), 'R24: the list is the first 200 in index order');
      assert.ok(!text10.includes('emptydir'), 'R24: directory rows are not listed as files');
      assert.match(text10, /2\.0 KiB/, 'R24: sizes use the same units as the table');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'R24: opening the list does not overflow the page');
      // 檔案數欄的 CSV 與搜尋不受明細影響：CSV 該列只有數字。
      const csvBacked = await captureCsv(page, backed);
      const filesCol = csvBacked[0].indexOf('檔案數');
      assert.equal(csvBacked.length, 2, 'R24: the search narrows the CSV to the matched row');
      assert.equal(csvBacked[1][filesCol], '250', 'R24: the CSV file-count cell holds the number only, not the list');
      assert.ok(!csvBacked[1].join(',').includes('bulk'), 'R24: the CSV never carries the file list');
      await search.fill('item-0011');
      const details11 = rowOf('item-0011').locator('details.file-detail');
      await details11.locator('summary').click();
      assert.equal(await details11.locator('li').count(), 3, 'R24: a small item lists every file');
      assert.doesNotMatch(await details11.innerText(), /另有/, 'R24: no remainder hint when everything is listed');
      assert.match(await details11.innerText(), /共 3 個檔案/);
      await search.fill('item-0002');
      assert.equal(await rowOf('item-0002').locator('details.file-detail').count(), 1, 'R24: a one-file item also has a list');
      await search.fill('');
      // 320／390 寬：展開後頁面不得水平溢位。
      for (const width of [320, 390]) {
        await page.setViewportSize({ width, height: 844 });
        await search.fill('item-0010');
        assert.equal(await details10.evaluate(el => el.open), true);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth <= 0), true, `R24: no horizontal page overflow at ${width}px with the list open`);
        await page.screenshot({ path: path.join(screens, `r24-filelist-${width}.png`) });
      }
      await page.setViewportSize({ width: 1280, height: 900 }); await search.fill('');
    }

    // Pending tab: reason filter, CSV, coverage regions table.
    await tabs.nth(1).click();
    const pending = page.locator('#pending'), pendingStatus = pending.locator('.toolbar').first().locator('[role=status]');
    assert.equal(await pendingStatus.innerText(), `顯示 ${pendingExpected.length}／共 ${pendingExpected.length} 筆`);
    const reasonSelect = pending.getByLabel('原因');
    const deniedReason = pendingExpected.find(r => r.ReasonCode === 'PermissionDenied').Reason;
    assert.ok((await reasonSelect.locator('option').allInnerTexts()).includes(deniedReason));
    await reasonSelect.selectOption({ label: deniedReason });
    const deniedCount = pendingExpected.filter(r => r.ReasonCode === 'PermissionDenied').length;
    assert.equal(await pendingStatus.innerText(), `顯示 ${deniedCount}／共 ${pendingExpected.length} 筆`);
    csv = await captureCsv(page, pending);
    assert.equal(csv.length - 1, deniedCount);
    assert.ok(csv.slice(1).every(r => r[csv[0].indexOf('原因碼')] === 'PermissionDenied'));
    await reasonSelect.selectOption('');
    const pendingText = await pending.innerText();
    assert.ok(pendingText.includes('探索未涵蓋區域（以區域列出，不是項目）'));
    assert.ok(await pending.locator('#tbl-coverage').count() === 1 && (await pending.locator('#tbl-coverage').innerText()).includes('Uninstall'));
    await page.screenshot({ path: path.join(screens, 'b3-desktop-pending.png'), fullPage: false });

    // N3 excluded regions (BundleExcluded / ProtectedArea): their own table, filter, search label and CSV; never item rows.
    {
      const excludedExpected = expected.ExcludedRegions;
      assert.ok(excludedExpected.length >= 4 && excludedExpected.some(r => r.ReasonCode === 'BundleExcluded') && excludedExpected.some(r => r.ReasonCode === 'ProtectedArea'), 'fixture needs both region classes');
      const excludedTable = pending.locator('#tbl-excluded');
      assert.equal(await excludedTable.count(), 1, 'excluded regions table must exist when the scan binding is recorded');
      assert.ok((await pending.innerText()).includes('套裝本體與受保護區域（依政策不納入備份；以區域列出，不是項目）'));
      const excludedStatus = pending.locator('.toolbar').nth(1).locator('[role=status]');
      assert.equal(await excludedStatus.innerText(), `顯示 ${excludedExpected.length}／共 ${excludedExpected.length} 筆`);
      const regionSelect = pending.getByLabel('區域類別');
      const bundleReason = excludedExpected.find(r => r.ReasonCode === 'BundleExcluded').Reason, protectedReason = excludedExpected.find(r => r.ReasonCode === 'ProtectedArea').Reason;
      const regionOptions = await regionSelect.locator('option').allInnerTexts();
      assert.ok(regionOptions.includes(bundleReason) && regionOptions.includes(protectedReason), 'new reasons must be filter options with their Chinese text');
      assert.ok(bundleReason.includes('套裝軟體本體') && excludedExpected.find(r => r.ReasonCode === 'BundleExcluded').NextStep.includes('重新安裝'));
      await regionSelect.selectOption({ label: bundleReason });
      const bundleCount = excludedExpected.filter(r => r.ReasonCode === 'BundleExcluded').length;
      assert.equal(await excludedStatus.innerText(), `顯示 ${bundleCount}／共 ${excludedExpected.length} 筆`);
      await regionSelect.selectOption('');
      await pending.getByLabel('搜尋區域路徑').fill('config.msi');
      assert.equal(await excludedStatus.innerText(), `顯示 1／共 ${excludedExpected.length} 筆`);
      await pending.getByLabel('搜尋區域路徑').fill('');
      const regionCsv = await captureCsv(page, pending.locator('.toolbar').nth(1));
      assert.deepEqual(regionCsv[0], ['區域', '原因', '下一步', '原因碼']);
      assert.equal(regionCsv.length - 1, excludedExpected.length);
      const expectedByPath = new Map(excludedExpected.map(r => [r.Path, r]));
      for (const row of regionCsv.slice(1)) { const e = expectedByPath.get(row[0]); assert.ok(e, 'unknown region in CSV ' + row[0]); assert.equal(row[3], e.ReasonCode); assert.equal(row[1], e.Reason); assert.equal(row[2], e.NextStep); }
      await regionSelect.selectOption({ label: protectedReason });
      const protectedCsv = await captureCsv(page, pending.locator('.toolbar').nth(1));
      assert.equal(protectedCsv.length - 1, excludedExpected.filter(r => r.ReasonCode === 'ProtectedArea').length, 'filtered region CSV must contain only the filtered rows');
      assert.ok(protectedCsv.slice(1).every(r => r[3] === 'ProtectedArea'));
      await regionSelect.selectOption('');
      assert.equal((await pending.locator('#tbl-pending tbody tr').count()), pendingExpected.length, 'regions must not add rows to the item table');
      assert.equal(await page.evaluate(() => document.querySelectorAll('#tbl-excluded img').length), 0, 'region paths must be escaped');
      await excludedTable.scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(screens, 'n3-report-excluded-regions.png'), fullPage: false });
    }

    // Software tab exports too.
    await tabs.nth(2).click();
    csv = await captureCsv(page, page.locator('#software'));
    assert.ok(csv.length >= 2);

    // Print: every row of every table visible, controls hidden, header repeats, meta printed.
    await page.emulateMedia({ media: 'print' });
    const printInfo = await page.evaluate(() => {
      const count = id => [...document.querySelectorAll(`#${id} tbody tr`)].filter(r => { for (let n = r; n; n = n.parentElement) if (getComputedStyle(n).display === 'none') return false; return true; }).length;
      const hidden = sel => [...document.querySelectorAll(sel)].every(e => getComputedStyle(e).display === 'none');
      return { backed: count('tbl-backed'), pending: count('tbl-pending'), software: count('tbl-software'), controlsHidden: hidden('.toolbar') && hidden('.pager') && hidden('.tabs'), theadDisplay: getComputedStyle(document.querySelector('thead')).display, trBreak: getComputedStyle(document.querySelector('tbody tr')).breakInside, metaVisible: getComputedStyle(document.querySelector('dl.meta')).display !== 'none', sections: [...document.querySelectorAll('main > section')].every(s => getComputedStyle(s).display !== 'none') };
    });
    assert.equal(printInfo.backed, backedExpected.length, 'print must show every backed row');
    assert.equal(printInfo.pending, pendingExpected.length, 'print must show every pending row');
    assert.equal(printInfo.software, 1);
    assert.ok(printInfo.controlsHidden && printInfo.sections && printInfo.metaVisible, JSON.stringify(printInfo));
    assert.equal(printInfo.theadDisplay, 'table-header-group'); assert.equal(printInfo.trBreak, 'avoid');
    await page.screenshot({ path: path.join(screens, 'b3-print.png'), fullPage: false });
    await page.emulateMedia({ media: 'screen' });

    // 390px: no page-level horizontal scroll on any tab.
    await page.setViewportSize({ width: 390, height: 844 });
    for (let i = 0; i < 3; i++) {
      await tabs.nth(i).click();
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 0, `tab ${i} overflows the 390px viewport by ${overflow}px`);
      await page.screenshot({ path: path.join(screens, `b3-mobile-390-tab${i}.png`), fullPage: false });
    }
    await context.close();

    // Reduced motion context still loads cleanly.
    const reduced = await browser.newContext({ viewport: { width: 1280, height: 900 }, reducedMotion: 'reduce' });
    const reducedPage = await reduced.newPage(); reducedPage.on('pageerror', e => consoleErrors.push(e.message));
    await reducedPage.goto(fileUrl(fixture.report)); await reducedPage.waitForSelector('[role=tablist]');
    await reduced.close();

    // JavaScript disabled: all sections visible, no CSV button, explanation shown.
    const noJs = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 1280, height: 900 } });
    const noJsPage = await noJs.newPage();
    await noJsPage.goto(fileUrl(fixture.report));
    for (const id of ['backed', 'pending', 'software']) assert.ok(await noJsPage.locator('#' + id).isVisible(), id + ' must be visible without JavaScript');
    assert.equal(await noJsPage.getByRole('button', { name: '匯出 CSV' }).count(), 0, 'no CSV button without JavaScript');
    assert.ok((await noJsPage.locator('#backed .js-note').innerText()).includes('需啟用 JavaScript 才能匯出'));
    assert.equal(await noJsPage.locator('#tbl-backed tbody tr:visible').count(), backedExpected.length);
    // R24：沒有 JavaScript 時，檔案明細仍是靜態 <details>，原生即可展開，內容與有 JS 時相同。
    {
      const staticDetails = noJsPage.locator('#tbl-backed tr[data-id="item-0010"] details.file-detail');
      assert.equal(await staticDetails.count(), 1, 'R24 no-JS: the static details element is in the page');
      assert.equal(await staticDetails.evaluate(el => el.open), false, 'R24 no-JS: collapsed by default');
      await staticDetails.locator('summary').click();
      assert.equal(await staticDetails.evaluate(el => el.open), true, 'R24 no-JS: opens natively without a script');
      assert.equal(await staticDetails.locator('li:visible').count(), 200, 'R24 no-JS: the same 200 entries are visible');
      assert.match(await staticDetails.innerText(), /另有 50 個檔案未列出/, 'R24 no-JS: the remainder hint is shown');
      assert.ok((await staticDetails.innerText()).includes('<img src=x onerror=alert(1)>.txt'), 'R24 no-JS: the hostile name is still plain text');
    }
    await noJsPage.screenshot({ path: path.join(screens, 'b3-nojs.png') });
    await noJs.close();

    // Legacy (SchemaVersion 1) results: unrecorded, not empty.
    const legacy = buildFixture('V1');
    const legacyContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    const legacyPage = await legacyContext.newPage(); legacyPage.on('pageerror', e => consoleErrors.push(e.message)); legacyPage.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
    await legacyPage.goto(fileUrl(legacy.report)); await legacyPage.waitForSelector('[role=tablist]');
    assert.ok((await legacyPage.locator('#backed tbody tr').first().innerText()).includes('未記錄'));
    await legacyPage.locator('[role=tab]').nth(1).click();
    assert.ok((await legacyPage.locator('#pending').innerText()).includes('此結果集未記錄'));
    assert.equal(await legacyPage.locator('#tbl-excluded').count(), 0, 'a legacy result set must not show an excluded regions table');
    assert.ok((await legacyPage.locator('#pending').innerText()).includes('套裝本體與受保護區域'));
    await legacyContext.close();
    fs.rmSync(legacy.dir, { recursive: true, force: true });


    // N3 / 16.6-11: a result set above 2000 rows (2501 backed rows in one table): the last row must be reachable by paging,
    // by search and in print mode, and the CSV must contain every row.
    {
      const large = buildFixture('V2', 'Large');
      try {
        const lastName = 'zz-final-row-2501';
        const largeBacked = large.expected.Rows.filter(r => r.Status === 'BackedUp');
        assert.equal(largeBacked.length, 2501, 'large fixture must have exactly 2501 backed rows');
        assert.ok(large.expected.ExcludedRegions.length > 200, 'large fixture also pages the region table');
        const largeContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
        await largeContext.addInitScript(() => { window.__blobs = []; const original = URL.createObjectURL; URL.createObjectURL = function (blob) { window.__blobs.push(blob); return original.call(URL, blob); }; });
        const largePage = await largeContext.newPage(); largePage.on('pageerror', e => consoleErrors.push(e.message)); largePage.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
        await largePage.goto(fileUrl(large.report)); await largePage.waitForSelector('[role=tablist]');
        const lbacked = largePage.locator('#backed'), lstatus = lbacked.locator('[role=status][aria-atomic=true]');
        assert.equal(await lstatus.innerText(), '顯示 2501／共 2501 筆');
        // paging: 26 pages, the last page holds exactly one row and it is the final one
        const lastPage = Math.ceil(2501 / 100);
        assert.equal(lastPage, 26);
        for (let i = 1; i < lastPage; i++) await lbacked.getByRole('button', { name: '下一頁' }).click();
        assert.ok((await lbacked.innerText()).includes(`第 ${lastPage}／${lastPage} 頁`));
        assert.deepEqual(await lbacked.locator('tbody tr:not([hidden])').evaluateAll(rows => rows.map(r => r.cells[0].textContent)), [lastName], 'the last page must show exactly the final row');
        assert.equal(await lbacked.getByRole('button', { name: '下一頁' }).isDisabled(), true);
        await largePage.screenshot({ path: path.join(screens, 'n3-large-2501-lastpage.png') });
        for (let i = 1; i < lastPage; i++) await lbacked.getByRole('button', { name: '上一頁' }).click();
        assert.ok((await lbacked.innerText()).includes(`第 1／${lastPage} 頁`));
        // search: the final row is found even though it is beyond row 2000
        const lsearch = lbacked.getByLabel('搜尋名稱或位置');
        await lsearch.fill(lastName);
        assert.equal(await lstatus.innerText(), '顯示 1／共 2501 筆', 'search must reach rows beyond 2000');
        assert.deepEqual(await lbacked.locator('tbody tr:not([hidden])').evaluateAll(rows => rows.map(r => r.cells[0].textContent)), [lastName]);
        await largePage.screenshot({ path: path.join(screens, 'n3-large-2501-search.png') });
        await lsearch.fill('item-2500');
        assert.equal(await lstatus.innerText(), '顯示 1／共 2501 筆', 'a row just below the last one must be found too');
        await lsearch.fill('');
        // CSV: every row, final row included
        const largeCsv = await captureCsv(largePage, lbacked);
        assert.equal(largeCsv.length - 1, 2501, 'CSV must contain all 2501 rows');
        assert.ok(largeCsv.slice(1).some(r => r[0] === lastName));
        // print mode: every row of the table is displayed, the final one included, controls hidden
        await largePage.emulateMedia({ media: 'print' });
        const printed = await largePage.evaluate(name => {
          const visible = node => { for (let n = node; n; n = n.parentElement) if (getComputedStyle(n).display === 'none') return false; return true; };
          const rows = [...document.querySelectorAll('#tbl-backed tbody tr')], last = rows.find(r => r.cells[0].textContent === name);
          return { total: rows.length, visible: rows.filter(visible).length, lastVisible: !!last && visible(last), controlsHidden: [...document.querySelectorAll('.toolbar,.pager,.tabs')].every(e => getComputedStyle(e).display === 'none') };
        }, lastName);
        assert.equal(printed.total, 2501); assert.equal(printed.visible, 2501, 'print must show all 2501 rows'); assert.ok(printed.lastVisible, 'the final row must be visible in print'); assert.ok(printed.controlsHidden);
        await largePage.screenshot({ path: path.join(screens, 'n3-large-2501-print.png') });
        await largePage.emulateMedia({ media: 'screen' });
        // the region table also pages (250 regions) and finds its last row by search
        await largePage.locator('[role=tab]').nth(1).click();
        const lpending = largePage.locator('#pending'), regionStatus = lpending.locator('.toolbar').nth(1).locator('[role=status]');
        assert.equal(await regionStatus.innerText(), `顯示 ${large.expected.ExcludedRegions.length}／共 ${large.expected.ExcludedRegions.length} 筆`);
        await lpending.getByLabel('搜尋區域路徑').fill('App246');
        assert.equal(await regionStatus.innerText(), `顯示 1／共 ${large.expected.ExcludedRegions.length} 筆`);
        await largeContext.close();
      } finally { fs.rmSync(large.dir, { recursive: true, force: true }); }
    }

    // ================= N9d: mixed install-root contents in the offline report =================
    {
      const mixed = buildFixture('V2', 'Mixed');
      try {
        const results = JSON.parse(fs.readFileSync(mixed.results, 'utf8').replace(/^\ufeff/, ''));
        const regions = results.ExcludedRegions, regionA = regions.find(r => r.Path.includes('Vendor =App')), regionB = regions.find(r => r.Path.endsWith('Big Suite'));
        assert.equal(results.ExcludedCompleteness.Status, 'ManualItems');
        const mixedContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
        await mixedContext.addInitScript(() => { window.__blobs = []; const original = URL.createObjectURL; URL.createObjectURL = function (blob) { window.__blobs.push(blob); return original.call(URL, blob); }; });
        const mixedPage = await mixedContext.newPage(), mixedErrors = [];
        mixedPage.on('pageerror', e => mixedErrors.push(e.message)); mixedPage.on('console', m => { if (m.type() === 'error') mixedErrors.push(m.text()); });
        await mixedPage.goto(fileUrl(mixed.report)); await mixedPage.waitForSelector('[role=tablist]');
        // overall completeness is on top of every tab and never says complete
        const completeness = mixedPage.locator('#completeness');
        assert.equal(await completeness.getAttribute('data-status'), 'ManualItems');
        const completenessText = await completeness.innerText();
        assert.ok(completenessText.includes('整體完整度') && completenessText.includes('有人工處置項') && completenessText.includes('不代表搬移已完整'), completenessText);
        assert.equal(await completeness.locator('.badge').getAttribute('data-icon'), '!');
        await mixedPage.locator('[role=tab]').nth(1).click();
        const table = mixedPage.locator('#tbl-excluded'), pending = mixedPage.locator('#pending');
        assert.deepEqual(await mixedPage.locator('#tbl-excluded > thead th').allInnerTexts(), ['區域', '原因', '下一步']);
        const toggles = pending.locator('.region-toggle');
        assert.equal(await toggles.count(), 2);
        for (const index of [0, 1]) assert.equal(await toggles.nth(index).getAttribute('aria-expanded'), 'false');
        assert.equal(await table.locator('tr.region-detail-row:not([hidden])').count(), 0, 'details start collapsed when JavaScript runs');
        // counts shown by the pager are rows of regions only, not detail rows
        const status = pending.locator('.toolbar').nth(1).locator('[role=status]');
        assert.equal(await status.innerText(), `顯示 ${regions.length}／共 ${regions.length} 筆`);
        const toggleA = table.locator('tr[data-reason]').filter({ hasText: 'Vendor =App' }).locator('.region-toggle');
        assert.ok((await toggleA.innerText()).includes(`本體 ${regionA.Contents.Counts.Bundle} · 疑似業務資料 ${regionA.Contents.Counts.SuspectedBusinessData} · 未知 ${regionA.Contents.Counts.Unknown}`));
        await toggleA.click();
        assert.equal(await toggleA.getAttribute('aria-expanded'), 'true');
        const detailA = mixedPage.locator('#' + await toggleA.getAttribute('aria-controls'));
        assert.equal(await detailA.isVisible(), true);
        const detailText = await detailA.innerText();
        assert.ok(detailText.includes(`本體 ${regionA.Contents.Counts.Bundle}、疑似業務資料 ${regionA.Contents.Counts.SuspectedBusinessData}、未知 ${regionA.Contents.Counts.Unknown}`));
        const manualText = await detailA.locator('.manual-box').innerText();
        assert.ok(manualText.includes('人工處置') && manualText.includes('原件位置') && manualText.includes(regionA.Path) && manualText.includes('人工另外複製') && manualText.includes('原因'), manualText);
        const suspectedRows = detailA.locator('table.region-samples tbody tr').filter({ hasText: '人工處置：另外人工複製' });
        assert.equal(await suspectedRows.count(), regionA.Contents.Samples.filter(s => s.Class === 'SuspectedBusinessData').length);
        assert.ok((await detailA.locator('table.region-samples').innerText()).includes("sales & 'q'.csv"));
        const sameSides = await detailA.locator('ul.same-name li').evaluateAll(items => items.map(i => ({ side: i.getAttribute('data-side'), text: i.textContent })));
        assert.deepEqual(sameSides.map(s => s.side).sort(), ['bundle', 'other'], 'both sides of the same-name DLL are marked');
        assert.ok(sameSides.every(s => s.text.includes('同名，另一處位於') && s.text.includes('core.dll')));
        assert.ok(sameSides.find(s => s.side === 'other').text.includes('Website publish'));
        await detailA.scrollIntoViewIfNeeded();
        await mixedPage.screenshot({ path: path.join(screens, 'n9d-report-region-expanded.png') });
        // search hides the detail together with its row and shows it again with the row
        await pending.getByLabel('搜尋區域路徑').fill('Big Suite');
        assert.equal(await status.innerText(), `顯示 1／共 ${regions.length} 筆`);
        assert.equal(await detailA.isVisible(), false, 'a filtered-out row takes its detail with it');
        await pending.getByLabel('搜尋區域路徑').fill('Vendor =App');
        assert.equal(await detailA.isVisible(), true, 'the open state survives filtering');
        await pending.getByLabel('搜尋區域路徑').fill('');
        await toggleA.click();
        assert.equal(await toggleA.getAttribute('aria-expanded'), 'false'); assert.equal(await detailA.isVisible(), false);
        // keyboard + incomplete listing
        const toggleB = table.locator('tr[data-reason]').filter({ hasText: 'Big Suite' }).locator('.region-toggle');
        await toggleB.focus(); await mixedPage.keyboard.press('Enter');
        assert.equal(await toggleB.getAttribute('aria-expanded'), 'true');
        const detailBText = await mixedPage.locator('#' + await toggleB.getAttribute('aria-controls')).innerText();
        assert.ok(detailBText.includes('未列完') && detailBText.includes(regionB.Contents.IncompleteReason) && detailBText.includes(`已列 ${regionB.Contents.Listed} 筆`), detailBText);
        assert.equal(await table.locator('tr[data-reason]').filter({ hasText: 'Legacy App' }).locator('.region-toggle').count(), 0, 'rows without Contents get no expander');
        // CSV: header unchanged, plain path column (no expander text), one row per region
        const regionCsv = await captureCsv(mixedPage, pending.locator('.toolbar').nth(1));
        assert.deepEqual(regionCsv[0], ['區域', '原因', '下一步', '原因碼']);
        assert.equal(regionCsv.length - 1, regions.length);
        const csvByPath = new Map(regionCsv.slice(1).map(r => [r[0], r]));
        assert.ok(csvByPath.has(regionA.Path) && csvByPath.get(regionA.Path)[2] === regionA.NextStep && csvByPath.get(regionA.Path)[3] === 'BundleExcluded');
        assert.ok(regionCsv.every(r => !r.join('').includes('內容分類') && !r.join('').includes('▸')), 'expander text never leaks into the CSV');
        // print: collapsed details are printed (nothing hidden from a printout)
        await mixedPage.emulateMedia({ media: 'print' });
        assert.equal(await table.locator('tr.region-detail-row').evaluateAll(rows => rows.filter(r => getComputedStyle(r).display !== 'none').length), 2, 'both details are printed');
        await mixedPage.emulateMedia({ media: 'screen' });
        assert.deepEqual(mixedErrors, []); await mixedContext.close();
        // no JavaScript: the details are plain visible rows, completeness still shown
        const plainContext = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 1280, height: 900 } });
        const plainPage = await plainContext.newPage();
        await plainPage.goto(fileUrl(mixed.report));
        assert.equal(await plainPage.locator('#completeness').getAttribute('data-status'), 'ManualItems');
        assert.equal(await plainPage.locator('tr.region-detail-row').evaluateAll(rows => rows.filter(r => r.getClientRects().length > 0).length), 2, 'without JavaScript the details are visible');
        assert.equal(await plainPage.locator('.region-toggle').count(), 0);
        await plainContext.close();
        // 390px: nothing overflows the page
        const narrowContext = await browser.newContext({ viewport: { width: 390, height: 844 } }), narrowPage = await narrowContext.newPage(), narrowErrors = [];
        narrowPage.on('pageerror', e => narrowErrors.push(e.message)); narrowPage.on('console', m => { if (m.type() === 'error') narrowErrors.push(m.text()); });
        await narrowPage.goto(fileUrl(mixed.report)); await narrowPage.waitForSelector('[role=tablist]');
        await narrowPage.locator('[role=tab]').nth(1).click();
        await narrowPage.locator('#tbl-excluded .region-toggle').first().click();
        await narrowPage.locator('#tbl-excluded tr.region-detail-row:not([hidden])').first().scrollIntoViewIfNeeded();
        const overflow = await narrowPage.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        assert.ok(overflow <= 0, `390px: the report overflows by ${overflow}px`);
        await narrowPage.screenshot({ path: path.join(screens, 'n9d-report-390.png') });
        assert.deepEqual(narrowErrors, []); await narrowContext.close();
      } finally { fs.rmSync(mixed.dir, { recursive: true, force: true }); }
    }

    assert.deepEqual(consoleErrors, [], 'no console errors expected');
    console.log(`PASS: offline report browser test (${expected.Total} rows, ${backedExpected.length} backed, ${pendingExpected.length} not backed).`);
  } finally {
    await browser.close();
    for (const dir of [fixture.dir]) fs.rmSync(dir, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exit(1); });
