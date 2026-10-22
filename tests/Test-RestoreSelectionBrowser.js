// R6: 還原項目選擇與預覽補齊的真實瀏覽器測試（Playwright + Edge；API 為本檔內的固定替身）。
// 涵蓋：類型篩選與篩選結果選取、摘要的檔數／位元組、取消必要相依後即時標示不完整、建立收據前的確認（Esc／返回／確認、焦點回到觸發按鈕）、
// 已還原項目重新勾選的確認、預覽畫面的總計與清單、重開頁面後以最後一份收據預選、單一 live region 不因重畫而播報、390px 版面與零 console 錯誤。
const assert = require('node:assert/strict'), fs = require('node:fs'), http = require('node:http'), path = require('node:path');
const runtimePath = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtimePath, 'playwright'));
const root = path.resolve(__dirname, '..'), screens = process.env.WSM_R6_SCREENS || path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });
const assets = new Map([['/', path.join(root, 'src/ui/index.html')], ['/ui/console.js', path.join(root, 'src/ui/console.js')], ['/ui/console.css', path.join(root, 'src/ui/console.css')], ['/ui/nonc.js', path.join(root, 'src/ui/nonc.js')]]);
const pairId = 'r6-pair', contextId = 'r6-context', hash = 'a'.repeat(64), hash2 = 'b'.repeat(64), jobs = new Map(), submissions = [];
let stage = 'NeedsTargetDecision', revision = 2, receiptSelected = null;

const baseOptions = [
  { value: 'site', label: '訂單網站', adapter: 'IISSite', group: 'Web', typeLabel: '網站', restorable: true, restorableReason: '', restored: false, fileCount: 3, bytes: 1500, countsAvailable: true, dependencies: ['pool'], requiredBy: [] },
  { value: 'pool', label: '訂單應用程式集區', adapter: 'IISPool', group: 'Web', typeLabel: '應用程式集區', restorable: true, restorableReason: '', restored: false, fileCount: 0, bytes: 0, countsAvailable: true, dependencies: [], requiredBy: ['site'] },
  { value: 'task', label: '夜間匯出排程', adapter: 'ScheduledTask', group: 'Tasks', typeLabel: '排程工作', restorable: true, restorableReason: '', restored: false, fileCount: 1, bytes: 200, countsAvailable: true, dependencies: [], requiredBy: [] },
  { value: 'data', label: '訂單資料夾', adapter: 'FileScope', group: 'Data', typeLabel: '檔案範圍', restorable: true, restorableReason: '', restored: false, fileCount: 10, bytes: 100000, countsAvailable: true, dependencies: [], requiredBy: [] },
  { value: 'data2', label: '報表資料夾（已還原過）', adapter: 'FileScope', group: 'Data', typeLabel: '檔案範圍', restorable: true, restorableReason: '', restored: true, fileCount: 2, bytes: 50, countsAvailable: true, dependencies: [], requiredBy: [] },
  { value: 'manual', label: '人工處理項目', adapter: 'ManualWorkflow', group: 'Settings', typeLabel: '人工處理', restorable: false, restorableReason: '需要人工處理，工具不會還原。', restored: false, fileCount: 0, bytes: 0, countsAvailable: true, dependencies: [], requiredBy: [] }
];
const previewRows = [
  { ItemId: 'site', Name: '訂單網站', Adapter: 'IISSite', Action: 'ApplyReviewedIisChanges', Status: 'Ready', Reason: '', FileCount: 3, Bytes: 1500, MissingDependencies: ['pool'], AlreadyRestored: false },
  { ItemId: 'data2', Name: '報表資料夾（已還原過）', Adapter: 'FileScope', Action: 'MergeIntoExistingDirectory', Status: 'Ready', Reason: '', FileCount: 2, Bytes: 50, MissingDependencies: [], AlreadyRestored: true },
  { ItemId: 'task', Adapter: 'ScheduledTask', Action: 'DeferredBySelection', Status: 'Deferred', Reason: '這個核准項目沒有被選取。', FileCount: 1, Bytes: 200, MissingDependencies: [], AlreadyRestored: false }
];
const action = (id, defaults = {}, missing = []) => ({ id, available: true, reason: `Fixture ${id}`, defaults: Object.assign({ Workspace: 'C:\\fixture\\target', PairId: pairId }, defaults), missing });
function options() { return baseOptions.map(option => Object.assign({}, option, { preselected: receiptSelected ? receiptSelected.includes(option.value) : null })); }
function runtime() {
  const target = { status: stage, plan: { hash }, package: { ManifestHash: hash }, inventory: { SHA256: hash2 }, comparison: { Status: 'Imported' }, decision: null, restorePreview: null, restoreResult: null, mechanicalValidation: { available: false, status: 'NotRun' }, businessAcceptance: { available: false, status: 'NotAccepted' }, activation: { available: false, status: 'Locked' }, itemOptions: options() };
  const actions = [action('CreateTargetDecisionReceipt', {}, ['Decision', 'Owner', 'Reason', 'SelectedItemIds'])];
  if (stage === 'ReadyForRestorePreview' || stage === 'ReadyForRestore') { target.decision = { Decision: 'RestoreNow', Receipt: { Owner: 'Target operator', Reason: 'R6 browser', Status: 'Verified' } }; actions.push(action('TargetRestorePreview')); }
  if (stage === 'ReadyForRestore') { target.restorePreview = { Status: 'Previewed', PreviewHash: hash2, CanRestoreIndependentItems: true, Blocked: false, PlannedFileCount: 14, PlannedBytes: 101700, Rows: previewRows }; actions.push(action('TargetRestore', { PreviewHash: hash2 })); }
  return { Kind: 'WizardRuntimeProjection', Role: 'Target', PairId: pairId, viewContext: { revision: revision + 100, decisionRevision: 2, selectionRevision: 1, dataVersion: 1 }, status: stage, actions, runtime: { target } };
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
    if (url.pathname === '/api/jobs' && req.method === 'GET') return send(200, { items: [...jobs.values()] });
    if (url.pathname.startsWith('/api/jobs/') && req.method === 'GET') { const job = jobs.get(decodeURIComponent(url.pathname.split('/').pop())); return job ? send(200, { job }) : send(404, { code: 'job_not_found' }); }
    if (url.pathname === '/api/operations' && req.method === 'POST') {
      const body = JSON.parse(raw); submissions.push(body);
      if (body.action === 'CreateTargetDecisionReceipt') { receiptSelected = body.args.SelectedItemIds.slice(); stage = 'ReadyForRestorePreview'; }
      revision++;
      const job = { jobId: body.operationId, operationId: body.operationId, revision, action: body.action, status: 'Succeeded', role: 'Target', pairId, workspace: 'C:\\fixture\\target', outputs: [{ Kind: 'WizardRuntimeActionResult', Status: 'Succeeded' }] };
      jobs.set(body.operationId, job); return send(202, { job });
    }
    if (process.env.WSM_R6_TRACE) console.error('404 route', req.method, url.pathname);
    return send(404, { code: 'not_found', route: url.pathname });
  });
});

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const base = `http://127.0.0.1:${server.address().port}/#wizard`, errors = [];
    async function openPage(width = 390) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      page.on('pageerror', e => errors.push('pageerror: ' + e.message)); page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
      await page.goto(base, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => window.WsmConsole?.state?.wizard?.currentStep === 'handoff');
      await page.locator('[data-runtime-item="site"]').waitFor();
      return page;
    }
    const picked = page => page.evaluate(() => [...document.querySelectorAll('[data-runtime-item]')].filter(x => x.checked).map(x => x.dataset.runtimeItem));
    const summaryText = page => page.locator('[data-restore-summary]').innerText();
    const noOverflow = async (page, what) => assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal overflow: ${what}`);
    const receiptCount = () => submissions.filter(x => x.action === 'CreateTargetDecisionReceipt').length;
    const fillReceipt = async card => { await card.locator('[data-runtime-field="Decision"]').selectOption('RestoreNow'); await card.locator('[data-runtime-field="Owner"]').fill('Target operator'); await card.locator('[data-runtime-field="Reason"]').fill('R6 browser check'); };

    // ---------------------------------------------------------------- 1. 預設選取、摘要、單一 live region
    let page = await openPage(390), card = page.locator('.wizard-runtime-target');
    assert.deepEqual(await picked(page), ['site', 'pool', 'task', 'data'], 'default: every restorable, not-yet-restored item');
    assert.equal(await card.locator('[data-runtime-item="manual"]').isDisabled(), true);
    assert.equal(await card.locator('[data-runtime-item="data2"]').isChecked(), false, 'a restored item is not preselected');
    let text = await summaryText(page);
    assert.match(text, /已選 4／可還原 5，預計寫入 14 檔／101700 位元組/, 'summary shows files and bytes of the selection');
    assert.equal(await card.locator('.wizard-runtime-items [aria-live]').count(), 1, 'the picker owns exactly one live region');
    assert.equal(await page.evaluate(() => document.querySelector('.wizard-runtime-items [aria-live]').getAttribute('aria-live')), 'polite');
    const filterLabel = await page.evaluate(() => { const select = document.querySelector('select[data-restore-filter]'); const label = document.querySelector(`label[for="${select.id}"]`); return label ? label.textContent : ''; });
    assert.equal(filterLabel, '類型篩選', 'the native select has a real label');
    assert.equal(await page.evaluate(() => document.querySelector('select[data-restore-filter]').tagName), 'SELECT');
    await page.screenshot({ path: path.join(screens, 'r6-picker-390.png'), fullPage: true });
    await noOverflow(page, 'picker');

    // ---------------------------------------------------------------- 2. 重畫不播報；選取改變才播報
    await page.evaluate(() => {
      window.__liveMutations = 0;
      const observer = new MutationObserver(list => { for (const record of list) { const node = record.target.nodeType === 3 ? record.target.parentElement : record.target; if (node && node.closest && node.closest('.wizard-runtime-items [aria-live]')) window.__liveMutations++; } });
      observer.observe(document.body, { subtree: true, childList: true, characterData: true });
    });
    await page.evaluate(() => { const app = window.WsmConsole; app.renderWizard(app.state.wizard); app.renderWizard(app.state.wizard); });
    await page.waitForTimeout(200);
    assert.equal(await page.evaluate(() => window.__liveMutations), 0, 'a redraw must not touch the live region (no re-announcement)');
    assert.deepEqual(await picked(page), ['site', 'pool', 'task', 'data'], 'selection survives the redraw');
    await card.locator('[data-runtime-item="task"]').uncheck();
    await page.waitForFunction(() => window.__liveMutations > 0);
    assert.match(await summaryText(page), /已選 3／可還原 5，預計寫入 13 檔／101500 位元組/, 'summary follows the selection');
    await page.evaluate(() => { window.__liveMutations = 0; });
    await card.getByLabel('類型篩選').selectOption('排程工作');
    await page.waitForTimeout(150);
    assert.equal(await page.evaluate(() => window.__liveMutations), 0, 'changing only the filter does not re-announce an unchanged summary');
    await card.getByLabel('類型篩選').selectOption('');
    await card.locator('[data-runtime-item="task"]').check();

    // ---------------------------------------------------------------- 3. 類型篩選與選取／取消選取篩選結果
    const filter = card.getByLabel('類型篩選');
    assert.deepEqual(await filter.locator('option').allInnerTexts(), ['全部類型', '網站', '應用程式集區', '排程工作', '檔案範圍', '人工處理']);
    await filter.selectOption('檔案範圍');
    assert.equal(await card.locator('[data-runtime-item="site"]').isVisible(), false, 'non-matching rows are hidden');
    assert.equal(await card.locator('[data-runtime-item="data"]').isVisible(), true);
    await card.getByRole('button', { name: '全不選', exact: true }).click();
    await card.getByRole('button', { name: '選取篩選結果', exact: true }).click();
    assert.deepEqual(await picked(page), ['data', 'data2'], 'select filtered results only touches the visible type');
    assert.match(await summaryText(page), /已選 2／可還原 5，預計寫入 12 檔／100050 位元組.*重新還原 1 項/);
    assert.equal(await card.locator('[data-runtime-item="data2"]').evaluate(el => el.closest('label').innerText.includes('將重新還原')), true, 're-restore is labelled on the picker row');
    await page.screenshot({ path: path.join(screens, 'r6-filter-reapply-390.png'), fullPage: true });
    await card.getByRole('button', { name: '取消選取篩選結果' }).click();
    assert.deepEqual(await picked(page), [], 'deselect filtered results');
    await filter.selectOption('');
    await card.getByRole('button', { name: '全選', exact: true }).click();
    assert.deepEqual(await picked(page), ['site', 'pool', 'task', 'data', 'data2'], 'select all never ticks the non-restorable item');

    // ---------------------------------------------------------------- 4. 取消必要相依：立即標示不完整
    await card.locator('[data-runtime-item="pool"]').uncheck();
    const siteRow = card.locator('[data-runtime-item="site"]').locator('xpath=ancestor::label');
    assert.match(await siteRow.innerText(), /不完整：缺少必要相依 訂單應用程式集區/, 'the affected workload is flagged immediately next to the item');
    text = await summaryText(page); assert.match(text, /不完整 1 項/);
    assert.match(await card.locator('[data-restore-incomplete]').innerText(), /受影響的工作負載.*訂單網站（缺少 訂單應用程式集區）/, 'the summary area lists the affected workload');
    await page.screenshot({ path: path.join(screens, 'r6-incomplete-390.png'), fullPage: true });
    await fillReceipt(card);

    // ---------------------------------------------------------------- 5. 確認：Esc 不送出且焦點回到觸發按鈕；返回不送出；確認才送出
    const submit = card.getByRole('button', { name: '建立決策收據' });
    await submit.click();
    await page.waitForSelector('#restore-selection-confirm-dialog[open]');
    let dialogText = await page.locator('#restore-selection-confirm-dialog').innerText();
    assert.match(dialogText, /不完整的工作負載/); assert.match(dialogText, /此工作負載將停止，不會啟用/); assert.match(dialogText, /訂單網站：缺少必要相依 訂單應用程式集區/);
    assert.match(dialogText, /將重新還原的項目/); assert.match(dialogText, /報表資料夾（已還原過）/);
    assert.equal(await page.locator('#restore-selection-confirm-dialog [data-confirm-kind="incomplete"]').count(), 1, 'incomplete and re-restore are listed separately');
    assert.equal(await page.locator('#restore-selection-confirm-dialog [data-confirm-kind="reapply"]').count(), 1);
    assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.dataset.confirmAction), 'back', 'the safe choice has the initial focus');
    await page.screenshot({ path: path.join(screens, 'r6-dialog-390.png'), fullPage: false });
    await page.keyboard.press('Escape');
    await page.waitForFunction(() => !document.querySelector('#restore-selection-confirm-dialog[open]'));
    assert.equal(receiptCount(), 0, 'Esc sends nothing');
    assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.textContent), '建立決策收據', 'focus returns to the trigger after Esc');
    await submit.click(); await page.waitForSelector('#restore-selection-confirm-dialog[open]');
    await page.keyboard.press('Enter');   // 初始焦點在「返回修改選取」，只用鍵盤即可取消
    await page.waitForFunction(() => !document.querySelector('#restore-selection-confirm-dialog[open]'));
    assert.equal(receiptCount(), 0, 'back sends nothing');
    assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.textContent), '建立決策收據', 'focus returns to the trigger after back');
    await submit.click(); await page.waitForSelector('#restore-selection-confirm-dialog[open]');
    await page.keyboard.press('Shift+Tab'); assert.equal(await page.evaluate(() => document.activeElement.dataset.confirmAction), 'accept', 'keyboard reaches the confirm button inside the dialog');
    await page.keyboard.press('Tab'); assert.equal(await page.evaluate(() => document.activeElement.closest('#restore-selection-confirm-dialog') !== null), true, 'focus stays inside the modal dialog');
    await page.keyboard.press('Shift+Tab');
    await page.keyboard.press('Enter');   // 只用鍵盤完成確認
    await page.waitForFunction(() => window.WsmConsole.state.wizardRuntimeProjection?.status === 'ReadyForRestorePreview');
    assert.equal(receiptCount(), 1, 'only the explicit confirmation sends the receipt');
    assert.deepEqual(submissions.find(x => x.action === 'CreateTargetDecisionReceipt').args.SelectedItemIds, ['site', 'task', 'data', 'data2'], 'the receipt carries exactly the confirmed selection');

    // ---------------------------------------------------------------- 6. 只有重新還原：只出現重新還原清單；沒有問題：不跳對話框
    stage = 'NeedsTargetDecision'; receiptSelected = null; await page.close();
    page = await openPage(390); card = page.locator('.wizard-runtime-target'); await fillReceipt(card);
    await card.getByRole('button', { name: '全不選', exact: true }).click(); await card.locator('[data-runtime-item="data2"]').check();
    await card.getByRole('button', { name: '建立決策收據' }).click(); await page.waitForSelector('#restore-selection-confirm-dialog[open]');
    assert.equal(await page.locator('#restore-selection-confirm-dialog [data-confirm-kind="incomplete"]').count(), 0, 'no incomplete list when nothing is incomplete');
    assert.equal(await page.locator('#restore-selection-confirm-dialog [data-confirm-kind="reapply"]').count(), 1);
    await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.querySelector('#restore-selection-confirm-dialog[open]'));
    assert.equal(receiptCount(), 1, 're-restore alone also needs the confirmation (nothing was sent)');
    await card.locator('[data-runtime-item="data2"]').uncheck(); await card.locator('[data-runtime-item="site"]').check();
    await card.getByRole('button', { name: '建立決策收據' }).click(); await page.waitForSelector('#restore-selection-confirm-dialog[open]');
    assert.equal(await page.locator('#restore-selection-confirm-dialog [data-confirm-kind="incomplete"]').count(), 1, 'an incomplete workload alone also needs the confirmation');
    assert.equal(await page.locator('#restore-selection-confirm-dialog [data-confirm-kind="reapply"]').count(), 0);
    await page.keyboard.press('Escape'); await page.waitForFunction(() => !document.querySelector('#restore-selection-confirm-dialog[open]'));
    assert.equal(receiptCount(), 1, 'incomplete alone: nothing sent without confirmation');
    await card.locator('[data-runtime-item="pool"]').check();
    const before = receiptCount();
    await card.getByRole('button', { name: '建立決策收據' }).click();
    await page.waitForFunction(n => window.WsmConsole.state.wizardRuntimeProjection?.status === 'ReadyForRestorePreview' && true, before);
    assert.equal(await page.locator('#restore-selection-confirm-dialog[open]').count(), 0, 'a complete, first-time selection is submitted without a dialog');
    assert.equal(receiptCount(), before + 1);

    // ---------------------------------------------------------------- 7. 重開頁面：以最後一份收據預選（已還原項目不預選）
    await page.close();
    receiptSelected = ['site', 'task', 'data2'];   // 最後一份收據含已還原項目
    page = await openPage(390);
    assert.deepEqual(await picked(page), ['site', 'task'], 'reopen preselects the latest receipt; a restored item is not re-ticked by itself');
    assert.match(await summaryText(page), /已選 2／可還原 5，預計寫入 4 檔／1700 位元組/);
    await page.screenshot({ path: path.join(screens, 'r6-reopen-390.png'), fullPage: true });
    await noOverflow(page, 'reopened picker');

    // ---------------------------------------------------------------- 8. 預覽畫面：總計、不完整清單、重新還原清單
    await page.close(); stage = 'ReadyForRestore';
    page = await openPage(390); card = page.locator('.wizard-runtime-target');
    await card.locator('[data-preview-total]').waitFor();
    assert.match(await card.locator('[data-preview-total]').innerText(), /預計寫入 14 檔／101700 位元組/);
    assert.match(await card.locator('[data-preview-incomplete="site"]').innerText(), /不完整，此工作負載將停止.*缺少必要相依 訂單應用程式集區/);
    assert.equal(await card.locator('[data-preview-incomplete]').count(), 1, 'only selected rows with missing dependencies are listed');
    assert.match(await card.locator('[data-preview-reapply="data2"]').innerText(), /重新還原/);
    assert.equal(await card.locator('[data-preview-reapply]').count(), 1, 'deferred (unselected) rows are not listed as re-restore');
    await page.screenshot({ path: path.join(screens, 'r6-preview-390.png'), fullPage: true });
    await noOverflow(page, 'preview');
    await page.close();

    // ---------------------------------------------------------------- 9. 寬螢幕與零錯誤
    stage = 'NeedsTargetDecision'; receiptSelected = null;
    page = await openPage(1280); await page.screenshot({ path: path.join(screens, 'r6-picker-1280.png'), fullPage: true });
    await noOverflow(page, 'desktop picker'); await page.close();
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('PASS: R6 restore selection UI — type filter and filtered select/deselect, live n-files/b-bytes summary (single live region, no re-announce on redraw), immediate incomplete-dependency marking, confirm dialog (Esc/back send nothing, focus returns), re-restore confirmation, preview totals and lists, receipt-based preselection after reopening, 390px, zero console errors. API fixture only.');
  } finally { if (browser) await browser.close(); server.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
