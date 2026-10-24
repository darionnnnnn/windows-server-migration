// N1: 可還原集合在項目選擇器的呈現（Playwright + Edge；API 為本檔內的固定替身）。
// 涵蓋：不可還原項目用原生 disabled 停用、不預勾（含收據預選到不可還原項目時）、「全選／選取篩選結果／群組全選」都不勾、
// 每個新代碼都以「文字＋圖示」顯示原因並用 aria-describedby 關聯、摘要的「可還原 y」只計可還原項目、390px 不橫向溢出、零 console 錯誤。
// P10：持有「沿用既有檔」（內容與備份相同但來歷不明，回復時不會刪除）的項目顯示個數與說明並關聯到勾選框；檔案頁的結果列也標出「沿用既有檔」。
const assert = require('node:assert/strict'), fs = require('node:fs'), http = require('node:http'), path = require('node:path');
const runtimePath = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtimePath, 'playwright'));
const root = path.resolve(__dirname, '..'), screens = process.env.WSM_N1_SCREENS || path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });
const assets = new Map([['/', path.join(root, 'src/ui/index.html')], ['/ui/console.js', path.join(root, 'src/ui/console.js')], ['/ui/console.css', path.join(root, 'src/ui/console.css')], ['/ui/nonc.js', path.join(root, 'src/ui/nonc.js')]]);
const pairId = 'n1-pair', contextId = 'n1-context', hash = 'a'.repeat(64), hash2 = 'b'.repeat(64);
let stage = 'NeedsTargetDecision', revision = 2, receiptSelected = null, withAdopted = false;

const make = (value, label, extra) => Object.assign({ value, label, adapter: 'FileScope', group: 'Data', typeLabel: '檔案範圍', restorable: true, restorableReason: '', restorableCode: '', restored: false, fileCount: 2, bytes: 1000, countsAvailable: true, dependencies: [], requiredBy: [] }, extra);
const baseOptions = [
  make('ok-1', '訂單資料夾'),
  make('ok-2', '報表資料夾'),
  make('done', '已還原的資料夾', { restored: true }),
  make('nopayload', '缺備份內容的資料夾', { restorable: false, restorableCode: 'NoPayload', restorableReason: '封裝裡沒有這個項目的備份內容（缺少 artifact），工具不會還原。' }),
  make('novolume', '在 Q 槽的資料夾', { restorable: false, restorableCode: 'MissingVolume', restorableReason: '目標主機缺少 Q:\\ 磁碟或掛載點；請準備相同位置後重新檢查。工具不會改寫到其他磁碟。' }),
  make('nocapacity', '大型資料夾', { restorable: false, restorableCode: 'InsufficientCapacity', restorableReason: '目標磁碟 C:\\ 空間不足：同一磁碟上全部可還原項目合計需要約 856 MiB（含 256 MiB 緩衝），目前可用約 700 MiB。' }),
  make('badlocation', '路徑被改過的資料夾', { restorable: false, restorableCode: 'BlockedLocation', restorableReason: '不符合原位置還原的條件，工具不會還原：OfflineFullSet restore requires the approved original location.' }),
  make('mounted', '掛載點底下的資料夾', { restorable: false, restorableCode: 'MountPointNotSupported', restorableReason: '目標路徑位於另一個掛載點（X:\\mounted-volume），工具不會寫入掛載點底下；請改用相同位置的一般目錄或另行處理。' }),
  make('noaccess', '無權限的資料夾', { restorable: false, restorableCode: 'PermissionDenied', restorableReason: '目前帳號無法寫入 D:\\locked；請以具權限的帳號執行或調整權限後重新檢查。' }),
  make('manual', '人工處理項目', { adapter: 'ManualWorkflow', group: 'Settings', typeLabel: '人工處理', restorable: false, restorableCode: 'ManualWorkflow', restorableReason: '需要人工處理，工具不會還原。', fileCount: 0, bytes: 0 }),
  make('external', '外部處理資料夾', { restorable: false, restorableCode: 'External', restorableReason: '標示為外部處理，未包含在備份中。', fileCount: 0, bytes: 0 })
];
const restorableIds = ['ok-1', 'ok-2', 'done'];
const expectedReasons = { nopayload: ['缺少備份內容', '缺少 artifact'], novolume: ['缺少磁碟', 'Q:'], nocapacity: ['空間不足', '856 MiB', '700 MiB'], badlocation: ['原位置不符', '原位置'], mounted: ['掛載點不支援', '掛載點'], noaccess: ['權限不足', '無法寫入'], manual: ['需人工處理', '人工處理'], external: ['外部處理', '外部處理'] };
const action = (id, defaults = {}, missing = []) => ({ id, available: true, reason: `Fixture ${id}`, defaults: Object.assign({ Workspace: 'C:\\fixture\\target', PairId: pairId }, defaults), missing });
const adoptedNoteText = '沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。';
const adoptedOptions = [
  make('adopt-ok', '沿用既有檔的資料夾', { adoptedExistingCount: 2, adoptedExistingNote: adoptedNoteText }),
  make('adopt-blocked', '沿用既有檔但需先對帳的資料夾', { restorable: false, restorableCode: 'NeedsReconciliation', restorableReason: '上次還原這個項目時中途失敗；請先執行「修復」。', adoptedExistingCount: 1, adoptedExistingNote: adoptedNoteText })
];
function options() { return baseOptions.concat(withAdopted ? adoptedOptions : []).map(option => Object.assign({ adoptedExistingCount: 0, adoptedExistingNote: '' }, option, { preselected: receiptSelected ? receiptSelected.includes(option.value) : null })); }
function runtime() {
  const target = { status: stage, plan: { hash }, package: { ManifestHash: hash }, inventory: { SHA256: hash2 }, comparison: { Status: 'Imported' }, decision: null, restorePreview: null, restoreResult: null, mechanicalValidation: { available: false, status: 'NotRun' }, businessAcceptance: { available: false, status: 'NotAccepted' }, activation: { available: false, status: 'Locked' }, itemOptions: options() };
  return { Kind: 'WizardRuntimeProjection', Role: 'Target', PairId: pairId, viewContext: { revision: revision + 100, decisionRevision: 2, selectionRevision: 1, dataVersion: 1 }, status: stage, actions: [action('CreateTargetDecisionReceipt', {}, ['Decision', 'Owner', 'Reason', 'SelectedItemIds'])], runtime: { target } };
}
function wizard() { return { Kind: 'WizardProjection', role: 'Target', workspaceRole: 'Target', roleMatchesWorkspace: true, pairId, pairName: 'Source to Target', currentStep: 'handoff', nextStep: 'restore', mode: 'ItemByItem', revision, groups: [], gates: [], results: {}, context: {}, actions: [] }; }
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1'), asset = assets.get(url.pathname);
  if (asset) { res.writeHead(200, { 'Content-Type': asset.endsWith('.js') ? 'application/javascript' : asset.endsWith('.css') ? 'text/css' : 'text/html' }); fs.createReadStream(asset).pipe(res); return; }
  if (url.pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }
  let raw = ''; req.on('data', c => raw += c);
  req.on('end', () => {
    const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/api/session') return send(200, { token: 'fixture', contextId, sessionId: 's', hostName: 'Target', role: 'Target', workspace: 'C:\\fixture\\target', pairId, revision: revision + 100, decisionRevision: 2, selectionRevision: 1, dataVersion: 1, principal: 'Fixture' });
    if (url.pathname === '/api/context') return send(200, { roles: ['Target'], pairs: [{ pairId, label: 'Source to Target' }], role: 'Target', pairId, contextId, revision, decisionRevision: 2, selectionRevision: 1, dataVersion: 1 });
    if (url.pathname === '/api/wizard' && req.method === 'GET') return send(200, wizard());
    if (url.pathname === '/api/wizard/nonc') return send(200, { Kind: 'WizardNonCProjection', Role: 'Target', PairId: pairId, ContextId: contextId, HasNonC: false });
    if (url.pathname === '/api/wizard/runtime') return send(200, runtime());
    if (url.pathname === '/api/jobs') return send(200, { items: [] });
    return send(404, { code: 'not_found', route: url.pathname });
  });
});

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const base = `http://127.0.0.1:${server.address().port}/#wizard`, errors = [];
    async function openPage(width, waitItem = 'ok-1') {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      page.on('pageerror', e => errors.push('pageerror: ' + e.message)); page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
      await page.goto(base, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => window.WsmConsole?.state?.wizard?.currentStep === 'handoff');
      await page.locator(`[data-runtime-item="${waitItem}"]`).waitFor();
      return page;
    }
    const picked = page => page.evaluate(() => [...document.querySelectorAll('[data-runtime-item]')].filter(x => x.checked).map(x => x.dataset.runtimeItem));
    const summaryText = page => page.locator('[data-restore-summary]').innerText();
    const blockedIds = baseOptions.filter(option => option.restorable === false).map(option => option.value);

    // ---------------------------------------------------------------- 1. 沒有收據：只預勾可還原且未還原的項目；不可還原項目原生停用
    let page = await openPage(390), card = page.locator('.wizard-runtime-target');
    assert.deepEqual(await picked(page), ['ok-1', 'ok-2'], 'default preselection: restorable and not yet restored only');
    for (const id of blockedIds) {
      const box = card.locator(`[data-runtime-item="${id}"]`);
      assert.equal(await box.isDisabled(), true, `${id} is natively disabled`);
      assert.equal(await box.evaluate(el => el.hasAttribute('disabled')), true, `${id} uses the native disabled attribute`);
      assert.equal(await box.isChecked(), false, `${id} is not preselected`);
    }
    for (const id of restorableIds) assert.equal(await card.locator(`[data-runtime-item="${id}"]`).isDisabled(), false, `${id} stays enabled`);
    // 摘要：「可還原 y」只計可還原的項目（3 項，其中 1 項已還原）
    assert.match(await summaryText(page), /已選 2／可還原 3，預計寫入 4 檔／2000 位元組/, 'summary counts only restorable items');

    // ---------------------------------------------------------------- 2. 原因：文字＋圖示，涵蓋每個新代碼，且用 aria-describedby 關聯到停用的勾選框
    for (const id of blockedIds) {
      const element = card.locator(`[data-runtime-item="${id}"]`).locator('xpath=ancestor::label').locator('.wizard-runtime-item-reason');
      assert.equal(await element.count(), 1, `${id} shows exactly one reason line`);
      const text = await element.innerText();
      assert.ok(text.startsWith('⛔ 不可還原（'), `${id} reason carries the icon and the status word: ${text}`);
      for (const piece of expectedReasons[id]) assert.ok(text.includes(piece), `${id} reason mentions "${piece}": ${text}`);
      assert.equal(await element.getAttribute('data-restorable-code'), baseOptions.find(o => o.value === id).restorableCode, `${id} exposes its code`);
      const describedBy = await card.locator(`[data-runtime-item="${id}"]`).getAttribute('aria-describedby');
      assert.equal(describedBy, await element.getAttribute('id'), `${id} checkbox is described by its reason`);
    }
    assert.equal(await card.locator('.wizard-runtime-item-reason').count(), blockedIds.length, 'restorable items show no reason line');
    await page.screenshot({ path: path.join(screens, 'n1-picker-390.png'), fullPage: true });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'no horizontal overflow at 390px');

    // ---------------------------------------------------------------- 3. 全選／全不選／選取篩選結果／群組全選：都不勾不可還原項目
    await card.getByRole('button', { name: '全不選', exact: true }).click();
    assert.deepEqual(await picked(page), []);
    await card.getByRole('button', { name: '全選', exact: true }).click();
    assert.deepEqual(await picked(page), ['ok-1', 'ok-2', 'done'], 'select all ticks every restorable item and no other');
    assert.match(await summaryText(page), /已選 3／可還原 3，預計寫入 6 檔／3000 位元組.*重新還原 1 項/);
    await card.getByRole('button', { name: '全不選', exact: true }).click();
    await card.getByLabel('類型篩選').selectOption('檔案範圍');
    await card.getByRole('button', { name: '選取篩選結果', exact: true }).click();
    assert.deepEqual(await picked(page), ['ok-1', 'ok-2', 'done'], 'select filtered results skips the non-restorable items');
    await card.getByLabel('類型篩選').selectOption('');
    await card.getByRole('button', { name: '全不選', exact: true }).click();
    await card.getByLabel('全選此群組').first().check();
    assert.deepEqual(await picked(page), ['ok-1', 'ok-2', 'done'], 'group select-all skips the non-restorable items');
    assert.equal(await page.evaluate(() => [...document.querySelectorAll('[data-runtime-item]')].filter(x => x.checked && x.disabled).length), 0, 'no checked item is disabled');
    await page.screenshot({ path: path.join(screens, 'n1-select-all-390.png'), fullPage: true });
    await page.close();

    // ---------------------------------------------------------------- 4. 收據預選到不可還原項目（舊收據或選項後來變成不可還原）：不勾、不被帶進建立收據的內容
    receiptSelected = ['ok-1', 'nopayload', 'nocapacity', 'manual'];
    page = await openPage(390); card = page.locator('.wizard-runtime-target');
    assert.deepEqual(await picked(page), ['ok-1'], 'a receipt that selected non-restorable items does not tick them');
    assert.match(await summaryText(page), /已選 1／可還原 3/);
    await page.close(); receiptSelected = null;

    // ---------------------------------------------------------------- 5. 全部都不可還原：可還原 0、沒有任何勾選
    const saved = baseOptions.slice();
    baseOptions.splice(0, baseOptions.length, ...saved.filter(option => option.restorable === false));
    page = await openPage(1280, 'nopayload');
    assert.deepEqual(await picked(page), [], 'nothing is ticked when nothing is restorable');
    assert.match(await page.locator('[data-restore-summary]').innerText(), /已選 0／可還原 0/);
    await page.close(); baseOptions.splice(0, baseOptions.length, ...saved);

    // ---------------------------------------------------------------- 6. P10：沿用既有檔（390px）
    withAdopted = true;
    page = await openPage(390, 'adopt-ok'); card = page.locator('.wizard-runtime-target');
    assert.equal(await card.locator('[data-adopted-existing]').count(), 2, 'only the two items that hold adopted files show the note');
    const labelOf = id => card.locator(`[data-runtime-item="${id}"]`).locator('xpath=ancestor::label');
    const adoptedLine = labelOf('adopt-ok').locator('[data-adopted-existing]');
    assert.equal((await adoptedLine.innerText()).trim(), '沿用既有檔 2 個：內容與備份相同但來歷不明，回復時不會刪除。', 'the note names the class, the count and the one-sentence meaning');
    assert.equal(await adoptedLine.getAttribute('data-adopted-existing'), '2', 'the count is exposed for assistive tools');
    assert.equal(await labelOf('ok-1').locator('[data-adopted-existing]').count(), 0, 'an ordinary item shows no adopted note');
    assert.equal(await card.locator('[data-runtime-item="adopt-ok"]').getAttribute('aria-describedby'), await adoptedLine.getAttribute('id'), 'the adopted note describes its checkbox');
    const blockedDescribed = (await card.locator('[data-runtime-item="adopt-blocked"]').getAttribute('aria-describedby')).split(' ');
    assert.equal(blockedDescribed.length, 2, 'a blocked item with adopted files is described by its reason and the note');
    assert.equal(await card.locator('[data-runtime-item="adopt-ok"]').isDisabled(), false, 'an item holding adopted files stays selectable');
    assert.equal(await card.locator('[data-runtime-item="adopt-blocked"]').isDisabled(), true, 'a blocked item stays disabled');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'no horizontal overflow at 390px with the adopted note');
    await page.screenshot({ path: path.join(screens, 'p10-adopted-picker-390.png'), fullPage: true });
    await labelOf('adopt-ok').screenshot({ path: path.join(screens, 'p10-adopted-item-390.png') }); await labelOf('adopt-blocked').screenshot({ path: path.join(screens, 'p10-adopted-blocked-item-390.png') });
    // files page rows: the pill is added next to the status when the reason carries the note, and not duplicated when the status already is AdoptedExisting
    await page.evaluate(note => window.WsmConsole.renderFiles({ rows: [
      { itemId: 'x', sourcePath: 'C:\\S\\a1.bin', preservedPath: 'D:\\T\\a1.bin', effectivePath: 'D:\\T\\a1.bin', placementStatus: 'Applied', reason: note, sourceHash: 'h', observedHash: 'h' },
      { itemId: 'x', sourcePath: 'C:\\S\\a2.bin', preservedPath: 'D:\\T\\a2.bin', effectivePath: 'NotObserved', placementStatus: 'AdoptedExisting', reason: note, sourceHash: 'h', observedHash: 'h' },
      { itemId: 'x', sourcePath: 'C:\\S\\a3.bin', preservedPath: 'D:\\T\\a3.bin', effectivePath: 'D:\\T\\a3.bin', placementStatus: 'Applied', reason: 'File bytes and metadata match the sealed artifact and current-generation ownership/readback.', sourceHash: 'h', observedHash: 'h' }] }), adoptedNoteText);
    const fileRowsTags = await page.evaluate(() => [...document.querySelectorAll('#file-rows tr')].map(tr => [...tr.querySelectorAll('.tag')].map(t => t.textContent)));
    assert.equal(fileRowsTags.length, 3, 'three file rows rendered');
    assert.deepEqual(fileRowsTags[0].slice(-1), ['沿用既有檔'], 'an applied row whose reason is the adopted note shows the adopted pill');
    assert.equal(fileRowsTags[0].length, 2, 'the applied pill stays next to the adopted pill');
    assert.deepEqual(fileRowsTags[1], ['沿用既有檔'], 'a placement preview row with status AdoptedExisting shows exactly one adopted pill');
    assert.equal(fileRowsTags[2].includes('沿用既有檔'), false, 'an ordinary applied row does not show the adopted pill');
    assert.match(await page.locator('#file-rows tr').first().innerText(), /原因：沿用既有檔：內容與備份相同但來歷不明，回復時不會刪除。/, 'the files row keeps the one-sentence explanation');
    await page.close(); withAdopted = false;

    // ---------------------------------------------------------------- 7. 寬螢幕截圖與零錯誤
    page = await openPage(1280); await page.screenshot({ path: path.join(screens, 'n1-picker-1280.png'), fullPage: true }); await page.close();
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('PASS: N1 restorable set UI — non-restorable items natively disabled and never ticked (default, receipt preselection, select all, filtered select, group select), reason shown as icon + text + code for every new code with aria-describedby, summary counts only restorable items, 390px without overflow, zero console errors. API fixture only.');
  } finally { if (browser) await browser.close(); server.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
