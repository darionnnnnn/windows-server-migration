// P8: 部分完成後「重試失敗項目」的畫面（Playwright + Edge；API 為本檔內的固定替身，投影欄位由 Test-RetryFailedItems.ps1 對真實後端驗證）。
// 涵蓋：顯示條件（Partial 顯示、全部成功不顯示、執行中／WaitingForInput／Interrupted 不顯示，即使投影誤標可見）、說明文字、候選與不重試原因（文字＋圖示）、
// 候選為空或有 pending intent 時按鈕以 aria-disabled 停用並以 aria-describedby 關聯原因、Owner／Reason 預填且必填、鍵盤 Tab 到按鈕再 Enter、防連按只送一次、
// 送出內容（動作、候選、來源收據 hash）、建立後不自動開始還原、完成後焦點不掉到 body（成功移到結果訊息；失敗回到按鈕）、390／320px 不橫向溢出、零 console 錯誤。
// Q1（還原後重新核對）：同一支替身 API 另外涵蓋「重新核對」按鈕、待核對項目與原因、「曾成功」歷史、無法自動核對、匯入新盤點後的提示、鍵盤操作、停用／隱藏條件、390／320px 不溢位與零 console 錯誤；截圖 work/r7/screens/q1-*.png。
const assert = require('node:assert/strict'), fs = require('node:fs'), http = require('node:http'), path = require('node:path');
const runtimePath = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtimePath, 'playwright'));
const root = path.resolve(__dirname, '..'), screens = process.env.WSM_P8_SCREENS || path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });
const assets = new Map([['/', path.join(root, 'src/ui/index.html')], ['/ui/console.js', path.join(root, 'src/ui/console.js')], ['/ui/console.css', path.join(root, 'src/ui/console.css')], ['/ui/nonc.js', path.join(root, 'src/ui/nonc.js')]]);
const pairId = 'p8-pair', contextId = 'p8-context', hash = 'a'.repeat(64), hash2 = 'b'.repeat(64), sourceReceipt = 'c'.repeat(64), shortReceipt = 'c'.repeat(12);
const jobs = new Map(), submissions = [];
const S = { stage: 'Partial', revision: 2, retryVisible: true, eligible: true, actionAvailable: true, reasonCode: '', reason: '', candidates: ['site', 'task'], excluded: [{ itemId: 'manual', name: '人工處理項目', code: 'ManualWorkflow', reason: '需要人工處理，工具不會還原。', lastStatus: 'ManualEvidenceRequired' }], failNext: false, longNames: false };
const names = { ok: '已成功的資料夾', site: '訂單網站', task: '夜間匯出排程', manual: '人工處理項目' };
// Q1：重新核對的替身狀態。findings 是核對後的逐項結果（ok＝待核對、site＝無法自動核對、task＝吻合）；drift=false 時全部吻合。
function freshQ1() {
  return { visible: true, available: true, reason: '', checked: false, suggested: false, drift: true, failNext: false, findings: [
    { id: 'ok', status: 'NeedsRecheck', reasons: [{ kind: 'Drift', code: 'Content', text: '內容已變動：目前檔案與還原時記錄的雜湊不同。', relativePath: 'a.bin', reportOnly: false }, { kind: 'Drift', code: 'Acl', text: '權限（ACL）已變動：與還原時記錄的不同。', relativePath: 'b.bin', reportOnly: false }] },
    { id: 'site', status: 'Unverifiable', reasons: [{ kind: 'Unverifiable', code: 'ReadbackFailed', text: '無法自動核對：原生讀回失敗，不能當成吻合。', relativePath: '', reportOnly: false }] },
    { id: 'task', status: 'Succeeded', reasons: [] }] };
}
S.q1 = freshQ1();
const recheckTexts = { NeedsRecheck: '待核對', Unverifiable: '無法自動核對', Succeeded: '已核對，目前吻合' };
const recheckFindings = () => S.q1.findings.map(f => (S.q1.drift || f.status === 'Succeeded') ? f : { id: f.id, status: 'Succeeded', reasons: [] });
const recheckStatusOf = id => { if (!S.q1.checked) return ''; const f = recheckFindings().find(x => x.id === id); return f ? f.status : ''; };
function recheckBlock() {
  const q = S.q1;
  if (!q.visible) return { visible: false, available: false, reasonCode: 'NothingToCheck', reason: '這次還原沒有成功的項目可核對。', items: [] };
  const items = q.checked ? recheckFindings().map(f => ({ itemId: f.id, name: nameOf(f.id), adapter: 'FileScope', status: f.status, recordStatus: f.status === 'Succeeded' ? 'Matched' : f.status, previousStatus: 'Succeeded', statusText: recheckTexts[f.status], succeededUtc: '2026-10-24T01:00:00Z', checkedUtc: '2026-10-24T03:00:00Z', historyText: f.status === 'NeedsRecheck' ? '曾成功於 2026-10-24 01:00:00 UTC，2026-10-24 03:00:00 UTC 核對發現漂移' : f.status === 'Unverifiable' ? '曾成功於 2026-10-24 01:00:00 UTC，2026-10-24 03:00:00 UTC 核對時無法自動確認目前內容' : '2026-10-24 03:00:00 UTC 核對吻合（原成功於 2026-10-24 01:00:00 UTC）', reasons: f.reasons })) : [];
  const count = status => items.filter(x => x.status === status).length;
  return { visible: true, available: q.available, reasonCode: q.available ? '' : 'RestoreInProgress', reason: q.available ? '' : q.reason, stage: S.stage, succeededCount: 3, checked: q.checked, checkedUtc: q.checked ? '2026-10-24T03:00:00.0000000Z' : '', sequence: q.checked ? 1 : 0, recordHash: q.checked ? 'd'.repeat(64) : '', suggested: q.suggested && !q.checked, suggestedText: '已還原內容可能已變動，建議重新核對。', checkedCount: items.length, matchedCount: count('Succeeded'), needsRecheckCount: count('NeedsRecheck'), unverifiableCount: count('Unverifiable'), items };
}
const longName = '這是一個名稱非常非常長而且沒有任何空白的項目名稱用來確認三百二十像素寬度下不會把頁面撐出水平捲動_' + 'X'.repeat(80);
function nameOf(id) { return S.longNames && id === 'site' ? longName : names[id]; }
function options() { return Object.keys(names).map(value => ({ value, label: nameOf(value), adapter: value === 'manual' ? 'ManualWorkflow' : 'FileScope', group: 'Data', typeLabel: '檔案範圍', restorable: value !== 'manual', restorableReason: value === 'manual' ? '需要人工處理，工具不會還原。' : '', restorableCode: value === 'manual' ? 'ManualWorkflow' : '', restored: value === 'ok', fileCount: 1, bytes: 10, countsAvailable: true, dependencies: [], requiredBy: [], preselected: null, recheckStatus: recheckStatusOf(value) })); }
const action = (id, defaults = {}, missing = [], available = true, reason = '') => ({ id, available, reason: reason || `Fixture ${id}`, defaults: Object.assign({ Workspace: 'C:\\fixture\\target', PairId: pairId }, defaults), missing });
function retry() {
  const base = { visible: S.retryVisible, eligible: S.eligible, reasonCode: S.reasonCode, reason: S.reason, candidateItemIds: S.eligible ? S.candidates : [], candidateCount: S.eligible ? S.candidates.length : 0 };
  if (!S.retryVisible) return base;
  return Object.assign(base, { succeededCount: 1, notSucceededCount: 1 + S.candidates.length + S.excluded.length, excluded: S.excluded, sourceAttemptId: 'attempt-1', sourceReceiptHash: sourceReceipt, sourceReceiptShort: shortReceipt, sourceStage: 'Partial', defaultOwner: 'Prior owner', defaultReason: `重試上次部分完成中未成功的 ${S.candidates.length} 個項目（來源收據 ${shortReceipt}）` });
}
function runtime() {
  const target = { status: S.stage, plan: { hash }, package: { ManifestHash: hash }, inventory: { SHA256: hash2 }, comparison: { Status: 'Imported' }, decision: null, restorePreview: null, restoreResult: null, retry: retry(), recheck: recheckBlock(), mechanicalValidation: { available: false, status: 'NotRun' }, businessAcceptance: { available: false, status: 'NotAccepted' }, activation: { available: false, status: 'Locked' }, itemOptions: options() };
  const actions = [action('CreateTargetDecisionReceipt', {}, ['Decision', 'Owner', 'Reason', 'SelectedItemIds'])];
  if (S.retryVisible) actions.push(action('TargetRetryFailedItems', { Decision: 'RestoreNow', SelectedItemIds: S.eligible ? S.candidates : [], RetryOfReceiptHash: sourceReceipt }, ['Owner', 'Reason'], S.actionAvailable, S.eligible ? '依上次部分完成的結果自動產生只含失敗項目的新選擇紀錄。' : S.reason));
  if (S.q1.visible) actions.push(action('TargetRecheck', {}, [], S.q1.available, S.q1.available ? '唯讀重新核對最近一次還原中成功的項目。' : S.q1.reason));
  if (S.stage === 'ReadyForRestorePreview') { target.decision = { Decision: 'RestoreNow', Receipt: { Owner: 'Retry operator', Reason: 'retry', Status: 'Verified' } }; actions.push(action('TargetRestorePreview')); }
  return { Kind: 'WizardRuntimeProjection', Role: 'Target', PairId: pairId, viewContext: { revision: S.revision + 100, decisionRevision: 2, selectionRevision: 1, dataVersion: 1 }, status: S.stage, actions, runtime: { target } };
}
function wizard() { return { Kind: 'WizardProjection', role: 'Target', workspaceRole: 'Target', roleMatchesWorkspace: true, pairId, pairName: 'Source to Target', currentStep: 'handoff', nextStep: 'restore', mode: 'ItemByItem', revision: S.revision, groups: [], gates: [], results: {}, context: {}, actions: [] }; }
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1'), asset = assets.get(url.pathname);
  if (asset) { res.writeHead(200, { 'Content-Type': asset.endsWith('.js') ? 'application/javascript' : asset.endsWith('.css') ? 'text/css' : 'text/html' }); fs.createReadStream(asset).pipe(res); return; }
  if (url.pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }
  let raw = ''; req.on('data', c => raw += c);
  req.on('end', () => {
    const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/api/session') return send(200, { token: 'fixture', contextId, sessionId: 's', hostName: 'Target', role: 'Target', workspace: 'C:\\fixture\\target', pairId, revision: S.revision + 100, decisionRevision: 2, selectionRevision: 1, dataVersion: 1, principal: 'Fixture' });
    if (url.pathname === '/api/context') return send(200, { roles: ['Target'], pairs: [{ pairId, label: 'Source to Target' }], role: 'Target', pairId, contextId, revision: S.revision, decisionRevision: 2, selectionRevision: 1, dataVersion: 1 });
    if (url.pathname === '/api/wizard' && req.method === 'GET') return send(200, wizard());
    if (url.pathname === '/api/wizard/nonc') return send(200, { Kind: 'WizardNonCProjection', Role: 'Target', PairId: pairId, ContextId: contextId, HasNonC: false });
    if (url.pathname === '/api/wizard/runtime') return send(200, runtime());
    if (url.pathname === '/api/jobs' && req.method === 'GET') return send(200, { items: [...jobs.values()] });
    if (url.pathname.startsWith('/api/jobs/') && req.method === 'GET') { const job = jobs.get(decodeURIComponent(url.pathname.split('/').pop())); return job ? send(200, { job }) : send(404, { code: 'job_not_found' }); }
    if (url.pathname === '/api/operations' && req.method === 'POST') {
      const body = JSON.parse(raw); submissions.push(body); S.revision++;
      const failed = (body.action === 'TargetRetryFailedItems' && S.failNext) || (body.action === 'TargetRecheck' && S.q1.failNext);
      if (body.action === 'TargetRecheck' && !failed) S.q1.checked = true;
      if (body.action === 'TargetRetryFailedItems' && !failed) { S.stage = 'ReadyForRestorePreview'; S.retryVisible = false; }
      const job = { jobId: body.operationId, operationId: body.operationId, revision: S.revision, action: body.action, status: failed ? 'Failed' : (body.action === 'TargetRecheck' && S.q1.drift ? 'ReviewRequired' : 'Succeeded'), role: 'Target', pairId, workspace: 'C:\\fixture\\target', outputs: failed ? [] : [{ Kind: 'WizardRuntimeActionResult', Status: 'Succeeded' }] };
      if (failed) job.error = { code: 'operation_failed', message: 'fixture failure' };
      jobs.set(body.operationId, job); return send(202, { job });
    }
    return send(404, { code: 'not_found', route: url.pathname });
  });
});
const explainText = '同一份還原選擇再按一次只會顯示上次結果，不會重做；要重試失敗項目請按「重試失敗項目」（或回精靈重新保存選擇）。';

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const base = `http://127.0.0.1:${server.address().port}/#wizard`, errors = [];
    const reset = () => { Object.assign(S, { stage: 'Partial', revision: 2, retryVisible: true, eligible: true, actionAvailable: true, reasonCode: '', reason: '', candidates: ['site', 'task'], excluded: [{ itemId: 'manual', name: '人工處理項目', code: 'ManualWorkflow', reason: '需要人工處理，工具不會還原。', lastStatus: 'ManualEvidenceRequired' }], failNext: false, longNames: false }); S.q1 = freshQ1(); jobs.clear(); submissions.length = 0; };
    async function openPage(width = 390) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      page.on('pageerror', e => errors.push('pageerror: ' + e.message)); page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
      await page.goto(base, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => window.WsmConsole?.state?.wizard?.currentStep === 'handoff');
      await page.locator('.wizard-runtime-target').waitFor();
      await page.waitForFunction(() => !!document.querySelector('.wizard-runtime-target [data-runtime-item]'));
      return page;
    }
    const panel = page => page.locator('.wizard-retry-failed');
    const retrySubmissions = () => submissions.filter(x => x.action === 'TargetRetryFailedItems');
    const noOverflow = async (page, what) => assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal overflow: ${what}`);
    const activeInfo = page => page.evaluate(() => { const a = document.activeElement; return { tag: a ? a.tagName : '', retryFocus: a && a.dataset ? a.dataset.retryFocus || '' : '', id: a ? a.id : '' }; });

    // ---------------------------------------------------------------- 1. Partial：顯示、說明、候選、不重試原因、預填
    reset(); let page = await openPage(390);
    assert.equal(await panel(page).count(), 1, 'a partial result with retryable items shows the retry panel');
    assert.equal(await page.locator('.wizard-retry-explain').innerText(), explainText, 'the explanation of why the same choice is not retried is shown verbatim');
    const summary = await page.locator('.wizard-retry-summary').innerText();
    assert.ok(summary.includes('✔') && summary.includes('✖') && summary.includes('↻') && summary.includes('可重試 2 項'), `summary carries text and icons: ${summary}`);
    assert.deepEqual(await page.locator('.wizard-retry-list:not(.wizard-retry-excluded) li').allInnerTexts(), ['↻ 訂單網站', '↻ 夜間匯出排程']);
    const excludedText = await page.locator('.wizard-retry-excluded li').allInnerTexts();
    assert.equal(excludedText.length, 1); assert.ok(excludedText[0].startsWith('⛔ 人工處理項目：') && excludedText[0].includes('需要人工處理'), excludedText[0]);
    const ownerInput = panel(page).locator('[data-runtime-field="Owner"]'), reasonInput = panel(page).locator('[data-runtime-field="Reason"]'), button = panel(page).locator('[data-retry-focus="submit"]');
    assert.equal(await ownerInput.inputValue(), 'Prior owner', 'Owner is prefilled from the previous receipt');
    assert.equal(await reasonInput.inputValue(), `重試上次部分完成中未成功的 2 個項目（來源收據 ${shortReceipt}）`, 'Reason is prefilled with the count and the short source receipt hash');
    assert.equal(await ownerInput.getAttribute('aria-required'), 'true'); assert.equal(await reasonInput.getAttribute('aria-required'), 'true');
    assert.equal(await button.getAttribute('aria-disabled'), 'false', 'the button is usable when candidates exist and both fields are filled');
    assert.equal(await button.evaluate(el => el.disabled), false, 'the button never uses the native disabled attribute');
    assert.ok((await button.getAttribute('class')).includes('secondary-button'), 'the button is a secondary-button');
    assert.equal(await panel(page).evaluate(el => el.querySelectorAll('[style]').length), 0, 'no inline style (tokens only)');
    await page.screenshot({ path: path.join(screens, 'p8-retry-390.png'), fullPage: true });
    await noOverflow(page, '390px panel');

    // ---------------------------------------------------------------- 2. Owner／Reason 必填：清空後以 aria-disabled 停用，按下不送出
    await ownerInput.fill('');
    assert.equal(await button.getAttribute('aria-disabled'), 'true', 'an empty owner disables the button');
    await button.click({ force: true }); assert.equal(retrySubmissions().length, 0, 'a click on the disabled button sends nothing');
    assert.match(await page.locator('#error-summary').innerText(), /責任人與理由/, 'the operator is told that owner and reason are required');
    await ownerInput.fill('Retry operator'); await reasonInput.fill('   ');
    assert.equal(await button.getAttribute('aria-disabled'), 'true', 'a blank reason disables the button');
    await reasonInput.fill('Fixed the cause; retry the failed items');
    assert.equal(await button.getAttribute('aria-disabled'), 'false');

    // ---------------------------------------------------------------- 3. 鍵盤：Tab 到按鈕、Enter 觸發；連按只送一次；完成後焦點不掉到 body
    await ownerInput.focus(); await page.keyboard.press('Tab'); await page.keyboard.press('Tab');
    assert.equal((await activeInfo(page)).retryFocus, 'submit', 'Tab reaches the retry button after owner and reason');
    await page.keyboard.press('Enter'); await page.keyboard.press('Enter');
    await page.waitForFunction(() => !!document.getElementById('wizard-retry-result'));
    await page.waitForTimeout(150);
    assert.equal(retrySubmissions().length, 1, 'a double activation sends exactly one request');
    const sent = retrySubmissions()[0];
    assert.equal(sent.action, 'TargetRetryFailedItems');
    assert.deepEqual(sent.args.SelectedItemIds, ['site', 'task'], 'the displayed candidates are sent for the backend to verify');
    assert.equal(sent.args.Decision, 'RestoreNow'); assert.equal(sent.args.RetryOfReceiptHash, sourceReceipt);
    assert.equal(sent.args.Owner, 'Retry operator'); assert.equal(sent.args.Reason, 'Fixed the cause; retry the failed items');
    assert.equal(submissions.filter(x => x.action === 'TargetRestore').length, 0, 'creating the selection record does not start a restore');
    const focus = await activeInfo(page);
    assert.equal(focus.id, 'wizard-retry-result', `focus moved to the result message, not body: ${JSON.stringify(focus)}`);
    assert.match(await page.locator('#wizard-retry-result').innerText(), /^✔ 已建立只含失敗項目的新選擇紀錄。還原尚未開始/, 'the result says the restore has not started');
    assert.equal(await panel(page).count(), 0, 'the panel is gone once the new record exists');
    await page.screenshot({ path: path.join(screens, 'p8-retry-after-390.png'), fullPage: true });
    await page.close();

    // ---------------------------------------------------------------- 4. 失敗：結果訊息＋焦點回到仍可用的按鈕
    reset(); S.failNext = true; page = await openPage(390);
    await panel(page).locator('[data-retry-focus="submit"]').focus(); await page.keyboard.press('Enter');
    await page.waitForFunction(() => !!document.getElementById('wizard-retry-result'));
    await page.waitForFunction(() => document.activeElement && document.activeElement.dataset && document.activeElement.dataset.retryFocus === 'submit');
    assert.equal(retrySubmissions().length, 1);
    assert.match(await page.locator('#wizard-retry-result').innerText(), /^⚠ 沒有建立新的選擇紀錄/, 'a failed request is reported with an icon and text');
    assert.equal(await panel(page).count(), 1, 'the panel stays so the operator can retry again');
    assert.equal((await activeInfo(page)).retryFocus, 'submit', 'focus returns to the still usable button after a failure');
    await page.close();

    // ---------------------------------------------------------------- 5. 候選為空：按鈕停用並說明原因；有 pending intent：先修復
    reset(); S.eligible = false; S.actionAvailable = false; S.candidates = []; S.reasonCode = 'NoRetryableItems'; S.reason = '沒有可重試的項目：未成功的項目目前都無法還原，原因見下方清單。';
    page = await openPage(320);
    assert.equal(await panel(page).count(), 1, 'an empty candidate set still shows the panel with its reason');
    let disabled = panel(page).locator('[data-retry-focus="submit"]');
    assert.equal(await disabled.getAttribute('aria-disabled'), 'true', 'no candidates: aria-disabled');
    assert.equal(await disabled.getAttribute('aria-describedby'), 'wizard-retry-why', 'the button is described by the reason');
    assert.match(await page.locator('#wizard-retry-why').innerText(), /^⛔ 目前不能重試：沒有可重試的項目/, 'the reason is shown as icon + text');
    assert.equal(await page.locator('.wizard-retry-list:not(.wizard-retry-excluded)').count(), 0, 'no candidate list when empty');
    await disabled.click({ force: true }); assert.equal(retrySubmissions().length, 0, 'the disabled button sends nothing');
    await page.screenshot({ path: path.join(screens, 'p8-retry-disabled-320.png'), fullPage: true });
    await noOverflow(page, '320px disabled panel');
    await page.close();
    reset(); S.eligible = false; S.actionAvailable = false; S.candidates = []; S.reasonCode = 'PendingIntent'; S.reason = '請先修復未完成的作業。'; S.excluded = [];
    page = await openPage(390);
    assert.equal(await panel(page).locator('[data-retry-focus="submit"]').getAttribute('aria-disabled'), 'true');
    assert.match(await page.locator('#wizard-retry-why').innerText(), /請先修復未完成的作業/, 'a pending intent asks for a repair first');
    assert.equal(await page.locator('.wizard-retry-explain').count(), 1, 'the explanation stays visible next to the disabled button');
    await page.close();

    // ---------------------------------------------------------------- 6. 不顯示：全部成功、執行中、WaitingForInput、Interrupted（即使投影誤標可見也不畫）
    reset(); S.stage = 'Succeeded'; S.retryVisible = false; page = await openPage(390);
    assert.equal(await panel(page).count(), 0, 'a fully successful restore shows no retry panel');
    assert.equal(await page.locator('.wizard-retry-explain').count(), 0, 'and no explanation');
    await page.close();
    for (const stage of ['WaitingForInput', 'Interrupted', 'Running']) {
      reset(); S.stage = stage; S.retryVisible = true; page = await openPage(390);
      assert.equal(await panel(page).count(), 0, `${stage}: no retry panel even when the projection claims it is visible`);
      assert.equal(await page.locator('[data-retry-focus="submit"]').count(), 0, `${stage}: no retry button`);
      await page.close();
    }
    reset(); S.retryVisible = false; page = await openPage(390);
    assert.equal(await panel(page).count(), 0, 'a Partial status whose retry is not visible shows no panel');
    await page.close();

    // ---- R12. 已回復（RolledBack）：不顯示重試面板，也不說「還原進行中」；畫面說「已回復，請重新選擇還原」，以純文字呈現
    const rolledBackReason = '已回復，請重新選擇還原。這次還原已被回復；回復後項目可以重新選取再還原，不屬於「重試失敗項目」。';
    for (const stage of ['ReadyForRestore', 'NeedsTargetDecision']) {
      reset(); S.stage = stage; S.retryVisible = false; S.eligible = false; S.reasonCode = 'RolledBack'; S.reason = rolledBackReason; page = await openPage(390);
      const rolled = page.locator('[data-rolled-back-note]');
      assert.equal(await rolled.count(), 1, `${stage}: the rolled-back note is shown`);
      assert.equal(await rolled.innerText(), rolledBackReason, `${stage}: the note carries the backend text`);
      assert.equal(await rolled.getAttribute('role'), 'status', 'the note is a status message');
      assert.equal(await rolled.evaluate(node => node.children.length), 0, 'the note is plain text (textContent), not markup');
      assert.equal(await panel(page).count(), 0, `${stage}: no retry panel after a rollback`);
      assert.equal(await page.locator('[data-retry-focus="submit"]').count(), 0, `${stage}: no retry button after a rollback`);
      assert.doesNotMatch(await page.locator('.wizard-runtime-target').innerText(), /還原進行中/, `${stage}: a rolled-back restore is not reported as in progress`);
      await noOverflow(page, `${stage}: rolled-back note`);
      await page.close();
    }
    reset(); S.stage = 'Partial'; S.retryVisible = false; S.reasonCode = 'AllSucceeded'; S.reason = '這次還原所選的項目都已成功，沒有需要重試的項目。'; page = await openPage(390);
    assert.equal(await page.locator('[data-rolled-back-note]').count(), 0, 'only the RolledBack reason produces the note');
    await page.close();

    // ---------------------------------------------------------------- 7. 320px：很長的名稱與原因也不橫向溢出
    reset(); S.longNames = true; S.excluded = [{ itemId: 'site', name: longName, code: 'BlockedConflict', reason: '目標位置已有衝突，需要人工處理：' + 'A file occupies the approved directory target '.repeat(6), lastStatus: 'BlockedConflict' }];
    page = await openPage(320);
    await page.screenshot({ path: path.join(screens, 'p8-retry-320.png'), fullPage: true });
    await noOverflow(page, '320px long names');
    const clipped = await panel(page).evaluate(el => { const box = el.getBoundingClientRect(); return [...el.querySelectorAll('*')].filter(n => { const r = n.getBoundingClientRect(); return r.width > 0 && (r.right > box.right + 1 || r.left < box.left - 1); }).length; });
    assert.equal(clipped, 0, 'nothing sticks out of the retry panel at 320px');
    await page.close();

    // ================================================================ Q1：還原後重新核對（同一個固定替身 API；投影欄位由 Test-PostRestoreRecheck.ps1 對真實後端驗證）
    const recheckPanel = page => page.locator('.wizard-recheck');
    const recheckSubmissions = () => submissions.filter(x => x.action === 'TargetRecheck');
    const recheckFocusInfo = page => page.evaluate(() => { const a = document.activeElement; return { tag: a ? a.tagName : '', focus: a && a.dataset ? a.dataset.recheckFocus || '' : '', id: a ? a.id : '' }; });
    const quietStage = () => { S.stage = 'Succeeded'; S.retryVisible = false; };

    // ---- Q1-1. 尚未核對、匯入新盤點後的提示：面板、說明、提示文字、按鈕（secondary-button、aria-disabled=false）
    reset(); quietStage(); S.q1.suggested = true; page = await openPage(390);
    assert.equal(await recheckPanel(page).count(), 1, 'a finished restore with succeeded items shows the recheck panel');
    assert.equal(await recheckPanel(page).locator('h3').innerText(), '還原後重新核對');
    assert.ok((await page.locator('.wizard-recheck-explain').innerText()).includes('不會覆寫、刪除或修改任何內容') && (await page.locator('.wizard-recheck-explain').innerText()).includes('舊的成功紀錄會保留'), 'the explanation says the recheck is read-only and keeps the old success history');
    assert.equal(await page.locator('.wizard-recheck-hint').innerText(), '⚠ 已還原內容可能已變動，建議重新核對。', 'the hint after a new Target inventory is shown verbatim');
    assert.match(await page.locator('.wizard-recheck-unchecked').innerText(), /^ⓘ 還沒有核對過。最近一次還原成功的項目有 3 項/, 'before the first recheck the page says nothing was checked yet');
    const recheckButton = () => page.locator('.wizard-recheck [data-recheck-focus="submit"]');
    assert.equal((await recheckButton().innerText()).trim(), '重新核對', 'the button reads 重新核對');
    assert.equal(await recheckButton().getAttribute('aria-disabled'), 'false', 'the button is usable');
    assert.equal(await recheckButton().evaluate(el => el.disabled), false, 'the button never uses the native disabled attribute');
    assert.ok((await recheckButton().getAttribute('class')).includes('secondary-button'), 'the button is a secondary-button');
    assert.equal(await recheckPanel(page).evaluate(el => el.querySelectorAll('[style]').length), 0, 'no inline style (tokens only)');
    await page.screenshot({ path: path.join(screens, 'q1-recheck-unchecked-390.png'), fullPage: true });
    await noOverflow(page, '390px unchecked recheck panel');

    // ---- Q1-2. 鍵盤：Tab 到按鈕、Enter 觸發、連按只送一次；結果：待核對項目與原因、「曾成功」歷史、無法自動核對、吻合；焦點不掉到 body
    await page.locator('[data-runtime-item]').first().focus();
    for (let i = 0; i < 400; i++) { await page.keyboard.press('Tab'); if ((await recheckFocusInfo(page)).focus === 'submit') break; }
    assert.equal((await recheckFocusInfo(page)).focus, 'submit', 'Tab reaches the recheck button');
    await page.keyboard.press('Enter'); await page.keyboard.press('Enter');
    await page.waitForFunction(() => !!document.getElementById('wizard-recheck-result'));
    await page.waitForFunction(() => document.querySelectorAll('.wizard-recheck-item').length === 3);
    await page.waitForTimeout(150);
    assert.equal(recheckSubmissions().length, 1, 'a double activation sends exactly one recheck request');
    const sentRecheck = recheckSubmissions()[0];
    assert.equal(sentRecheck.action, 'TargetRecheck'); assert.equal(sentRecheck.args.PairId, pairId); assert.ok(sentRecheck.args.Workspace, 'the defaults carry the workspace');
    assert.deepEqual(Object.keys(sentRecheck.args).sort(), ['PairId', 'Workspace'], 'the recheck needs no operator input and sends nothing else');
    assert.equal(submissions.filter(x => ['TargetRestore', 'TargetRetryFailedItems', 'CreateTargetDecisionReceipt'].includes(x.action)).length, 0, 'the recheck neither restores nor creates a selection record');
    assert.equal((await recheckFocusInfo(page)).id, 'wizard-recheck-result', 'focus moved to the result message, not body');
    assert.match(await page.locator('#wizard-recheck-result').innerText(), /^⚠ 已完成重新核對（唯讀）：有項目待核對或無法自動核對/, 'the result says it was read-only and that items need a look');
    assert.equal(await page.locator('.wizard-recheck-hint').count(), 0, 'the changed-content hint goes away once rechecked');
    const summaryText = await page.locator('.wizard-recheck-summary').innerText();
    assert.ok(summaryText.includes('⚠ 待核對 1 項') && summaryText.includes('◇ 無法自動核對 1 項') && summaryText.includes('✔ 吻合 1 項') && summaryText.includes('2026-10-24 03:00:00 UTC'), `summary counts and time: ${summaryText}`);
    const rows = await page.locator('.wizard-recheck-item').evaluateAll(list => list.map(li => ({ id: li.dataset.recheckItem, status: li.dataset.recheckStatus, text: li.innerText })));
    assert.deepEqual(rows.map(r => r.status), ['NeedsRecheck', 'Unverifiable', 'Succeeded'], 'needs-recheck first, then unverifiable, then matched');
    assert.ok(rows[0].text.startsWith('⚠ 已成功的資料夾：待核對'), `the drifted item reads 待核對 with an icon: ${rows[0].text}`);
    assert.ok(rows[0].text.includes('曾成功於 2026-10-24 01:00:00 UTC，2026-10-24 03:00:00 UTC 核對發現漂移'), 'the 曾成功 history is shown');
    assert.ok(rows[0].text.includes('a.bin：內容已變動') && rows[0].text.includes('b.bin：權限（ACL）已變動'), 'both drift reasons are shown with their file');
    assert.ok(rows[1].text.startsWith('◇ 訂單網站：無法自動核對') && rows[1].text.includes('不能當成吻合'), 'an item without readback reads 無法自動核對, never a match');
    assert.ok(rows[2].text.startsWith('✔ 夜間匯出排程：已核對，目前吻合'), 'a clean item stays success');
    assert.equal(await page.locator('.wizard-recheck-reasons').first().getAttribute('aria-label'), '原因', 'the reason list is labelled');
    await page.screenshot({ path: path.join(screens, 'q1-recheck-result-390.png'), fullPage: true });
    await noOverflow(page, '390px recheck result');
    // 重新還原仍要明確選取：待核對的已還原項目有提醒、不預選
    assert.equal(await page.locator('[data-recheck-badge="NeedsRecheck"]').count(), 1, 'the restore picker marks the NeedsRecheck item');
    assert.match(await page.locator('[data-recheck-badge="NeedsRecheck"]').innerText(), /要重新還原必須明確勾選；工具仍會保護已變動的內容/);
    assert.equal(await page.locator('[data-runtime-item="ok"]').isChecked(), false, 'a NeedsRecheck item is not preselected');
    await page.close();

    // ---- Q1-3. 失敗：結果訊息＋焦點回到仍可用的按鈕
    reset(); quietStage(); S.q1.failNext = true; page = await openPage(390);
    await recheckButton().focus(); await page.keyboard.press('Enter');
    await page.waitForFunction(() => !!document.getElementById('wizard-recheck-result'));
    await page.waitForFunction(() => document.activeElement && document.activeElement.dataset && document.activeElement.dataset.recheckFocus === 'submit');
    assert.equal(recheckSubmissions().length, 1);
    assert.match(await page.locator('#wizard-recheck-result').innerText(), /^⚠ 重新核對沒有完成.*已還原的內容沒有被修改/, 'a failed recheck says nothing was modified');
    assert.equal((await recheckFocusInfo(page)).focus, 'submit', 'focus returns to the still usable button after a failure');
    await page.close();

    // ---- Q1-4. 全部吻合：成功訊息；停用：原因以 aria-describedby 關聯，按下不送出；不顯示：執行中／WaitingForInput／Interrupted／沒有成功項目
    reset(); quietStage(); S.q1.drift = false; page = await openPage(390);
    await recheckButton().focus(); await page.keyboard.press('Enter');
    await page.waitForFunction(() => !!document.getElementById('wizard-recheck-result') && document.querySelectorAll('.wizard-recheck-item').length === 3);
    assert.match(await page.locator('#wizard-recheck-result').innerText(), /^✔ 已完成重新核對（唯讀）；沒有覆寫或修改任何已還原的內容/);
    assert.equal(await page.locator('.wizard-recheck-item[data-recheck-status="Succeeded"]').count(), 3, 'every item reads as matching when nothing drifted');
    await page.close();
    reset(); quietStage(); S.q1.available = false; S.q1.reason = '還原尚未結束（等待輸入或已中斷），請先在還原畫面完成或續作。'; page = await openPage(320);
    assert.equal(await recheckButton().getAttribute('aria-disabled'), 'true', 'unavailable: aria-disabled');
    assert.equal(await recheckButton().getAttribute('aria-describedby'), 'wizard-recheck-why', 'the button is described by the reason');
    assert.match(await page.locator('#wizard-recheck-why').innerText(), /^⛔ 目前不能重新核對：還原尚未結束/, 'the reason is shown as icon + text');
    await recheckButton().click({ force: true }); assert.equal(recheckSubmissions().length, 0, 'the disabled button sends nothing');
    await page.screenshot({ path: path.join(screens, 'q1-recheck-disabled-320.png'), fullPage: true });
    await noOverflow(page, '320px disabled recheck panel');
    await page.close();
    for (const stage of ['WaitingForInput', 'Interrupted', 'Running']) {
      reset(); S.stage = stage; S.retryVisible = false; page = await openPage(390);
      assert.equal(await recheckPanel(page).count(), 0, `${stage}: no recheck panel`);
      assert.equal(await page.locator('[data-recheck-focus="submit"]').count(), 0, `${stage}: no recheck button`);
      await page.close();
    }
    reset(); quietStage(); S.q1.visible = false; page = await openPage(390);
    assert.equal(await recheckPanel(page).count(), 0, 'no succeeded item: no recheck panel');
    await page.close();

    // ---- Q1-5. 320px：很長的名稱與原因也不橫向溢出；截圖
    reset(); quietStage(); S.longNames = true; S.q1.checked = true; S.q1.suggested = false; S.q1.findings[0].reasons[0].relativePath = 'Very\\Long\\Folder\\Name\\' + 'X'.repeat(90) + '.bin';
    page = await openPage(320);
    await page.screenshot({ path: path.join(screens, 'q1-recheck-320.png'), fullPage: true });
    await noOverflow(page, '320px long recheck names');
    const recheckClipped = await recheckPanel(page).evaluate(el => { const box = el.getBoundingClientRect(); return [...el.querySelectorAll('*')].filter(n => { const r = n.getBoundingClientRect(); return r.width > 0 && (r.right > box.right + 1 || r.left < box.left - 1); }).length; });
    assert.equal(recheckClipped, 0, 'nothing sticks out of the recheck panel at 320px');
    await page.close();

    assert.equal(errors.length, 0, errors.join('\n'));
    console.log('PASS: P8 retry failed items UI and Q1 post-restore recheck UI (recheck panel, button, 待核對 items with reasons and 曾成功 history, 無法自動核對, new-inventory hint, Tab + Enter, one request, focus never on body, disabled/hidden states, 390/320px, zero console errors) — shown for a partial result only (hidden when all succeeded, running, WaitingForInput, Interrupted), verbatim explanation, candidates and excluded reasons as icon + text, empty-candidate and pending-intent states disabled with aria-disabled and a described reason, owner/reason prefilled and required, Tab + Enter, one request on double activation, no restore started, focus never falls to body (result message on success, button on failure), 390/320px without overflow, zero console errors. API fixture only.');
  } finally { if (browser) await browser.close(); server.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
