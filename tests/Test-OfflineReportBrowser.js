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

    assert.deepEqual(consoleErrors, [], 'no console errors expected');
    console.log(`PASS: offline report browser test (${expected.Total} rows, ${backedExpected.length} backed, ${pendingExpected.length} not backed).`);
  } finally {
    await browser.close();
    for (const dir of [fixture.dir]) fs.rmSync(dir, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exit(1); });
