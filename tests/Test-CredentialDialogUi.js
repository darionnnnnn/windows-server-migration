// F4b: browser fixture (real Edge via playwright) for the document-level credential / resume dialog in src/ui/console.js.
const assert = require('node:assert/strict'), fs = require('node:fs'), http = require('node:http'), path = require('node:path');
const runtimePath = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtimePath, 'playwright'));
const root = path.resolve(__dirname, '..'), assets = new Map([['/', path.join(root, 'src/ui/index.html')], ['/ui/console.js', path.join(root, 'src/ui/console.js')], ['/ui/console.css', path.join(root, 'src/ui/console.css')]]);
const pairId = 'cred-pair', contextId = 'cred-context', workspace = 'C:\\fixture\\target', SENTINEL = 'SYNTHETIC-PASSWORD-SENTINEL-7f3a91', screens = path.join(root, 'work', 'r7', 'f4b-screens');
const jobs = new Map(), requests = [], queue = new Map();
const sessionBody = () => ({ token: 'fixture', contextId, sessionId: 's', hostName: 'Target', role: 'Target', workspace, pairId, revision: 5, decisionRevision: 2, selectionRevision: 1, dataVersion: 1, principal: 'Fixture' });
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1'), asset = assets.get(url.pathname);
  if (asset) { res.writeHead(200, { 'Content-Type': asset.endsWith('.js') ? 'application/javascript' : asset.endsWith('.css') ? 'text/css' : 'text/html' }); fs.createReadStream(asset).pipe(res); return; }
  let raw = ''; req.on('data', c => raw += c); req.on('end', () => {
    const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/api/session') return send(200, sessionBody());
    if (url.pathname === '/api/context') return send(200, { roles: ['Target'], pairs: [{ pairId, label: 'Source to Target' }], role: 'Target', pairId, contextId, revision: 5, decisionRevision: 2, selectionRevision: 1, dataVersion: 1 });
    if (url.pathname === '/api/wizard') return send(200, { Kind: 'WizardProjection', role: 'Target', workspaceRole: 'Target', roleMatchesWorkspace: true, pairId, pairName: 'Source to Target', currentStep: 'handoff', nextStep: 'restore', mode: 'ItemByItem', revision: 5, groups: [], gates: [], results: {}, context: {}, actions: [] });
    if (url.pathname === '/api/wizard/runtime') return send(200, { status: 'NeedsPackage', actions: [] });
    if (url.pathname === '/api/jobs' && req.method === 'GET') return send(200, { items: [...jobs.values()] });
    const key = `${req.method} ${url.pathname.replace(/^\/api\/jobs\/[^/]+/, '')}`;
    if (url.pathname.startsWith('/api/jobs/')) {
      let body = null; try { body = raw ? JSON.parse(raw) : null; } catch (_) {}
      requests.push({ key, body, id: decodeURIComponent(url.pathname.split('/')[3]) });
      const next = queue.get(key); const reply = next && next.length ? (next.length > 1 ? next.shift() : next[0]) : null;
      if (!reply) return send(404, { message: `no fixture reply for ${key}` });
      return setTimeout(() => send(reply.status || 200, reply.body), reply.delay || 0);
    }
    send(404, { message: 'not found' });
  });
});
const mkJob = (id, extra) => Object.assign({ jobId: id, id, action: 'TargetRestore', status: 'WaitingForInput', pairId, role: 'Target', workspace, label: '還原', canCancel: false }, extra || {});
const req = (ref, kinds, names, account, extra) => Object.assign({ SecretRef: ref, Kinds: kinds, ItemIds: names.map((_, i) => `i-${ref}-${i}`), DisplayNames: names, ApprovedAccount: account, Deferred: false, LastFailure: '', Attempts: 0, MaxAttempts: 3 }, extra || {});
const reply = (key, ...replies) => queue.set(key, replies);
const resetNet = () => { requests.length = 0; queue.clear(); };

(async () => {
  let browser; const errors = [];
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    page.on('pageerror', e => errors.push(e.message)); page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
    jobs.set('seed', mkJob('seed', { status: 'Succeeded' }));
    await page.goto(`http://127.0.0.1:${server.address().port}/#jobs`, { waitUntil: 'networkidle' });
    await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.session);
    await page.evaluate(() => window.WsmConsole.navigate('jobs', { resultGuardChecked: true, force: true }));
    const setJobs = async list => { jobs.clear(); list.forEach(j => jobs.set(j.jobId, j)); await page.evaluate(l => { const a = window.WsmConsole; a.state.jobs.clear(); l.forEach(j => a.state.jobs.set(j.jobId, j)); a.renderJobs(); }, list); };
    const dialog = page.locator('dialog.credential-dialog'), isOpen = () => page.evaluate(() => { const d = document.getElementById('credential-dialog'); return !!(d && d.open); });
    const active = () => page.evaluate(() => { const a = document.activeElement; return { id: a.id, tag: a.tagName, key: a.dataset && a.dataset.focusKey || '', title: a.dataset && a.dataset.jobTitle || '', text: (a.textContent || '').slice(0, 30) }; });
    const focusKey = async (key, message) => { await page.waitForFunction(k => document.activeElement && document.activeElement.dataset.focusKey === k, key, { timeout: 3000 }).catch(() => {}); assert.equal((await active()).key, key, message); };
    const ID = 'aaaaaaaa-0000-0000-0000-000000000001';
    const twoReqs = [req('SecretA', ['Service'], ['Svc 1', 'Svc 2', 'Svc 3', 'Svc 4', 'Svc 5', 'Svc 6', 'Svc 7'], 'CONTOSO\\svc-app'), req('SecretB', ['ScheduledTask', 'IISPool'], ['Nightly task'], 'CONTOSO\\svc-task')];

    // 1. card has only a button, no SecretRef; dialog structure; no auto-popup on a non-originating tab
    await setJobs([mkJob(ID, { requiredSecretRefs: ['SecretA', 'SecretB'], credentialRequirements: twoReqs })]);
    const cardText = await page.locator('#job-list').innerText();
    assert.ok(cardText.includes('還原暫停，需要帳戶密碼才能繼續') && cardText.includes('輸入帳密以繼續'), cardText);
    assert.ok(!/SecretRef|SecretA|SecretB/.test(cardText), 'card must not show SecretRef text');
    assert.equal(await page.locator('#job-list input').count(), 0, 'card keeps no inline inputs');
    assert.equal(await isOpen(), false, 'non-originating tab must not auto-open');
    const trigger = page.locator('#job-list').getByRole('button', { name: '輸入帳密以繼續' });
    await trigger.click(); if (!(await isOpen())) console.error("DBG", JSON.stringify(errors), await page.locator("#job-list").innerText(), await page.evaluate(()=>document.getElementById("error-summary").innerText)); assert.equal(await isOpen(), true);
    assert.equal(await dialog.getAttribute('aria-labelledby'), 'credential-dialog-title'); assert.equal(await dialog.getAttribute('aria-describedby'), 'credential-dialog-desc');
    assert.equal(await page.locator('#credential-dialog-title').innerText(), '輸入帳戶密碼以繼續還原');
    assert.equal(await page.locator('#credential-dialog-desc').innerText(), '密碼只交給本機工具的記憶體使用，不會寫入工作紀錄、備份或報告。');
    assert.equal(await dialog.locator('fieldset').count(), 2);
    assert.deepEqual(await dialog.locator('legend').allInnerTexts(), ['Windows 服務', '排程工作、IIS 應用程式集區']);
    const users = dialog.locator('input[autocomplete="username"]'); assert.equal(await users.count(), 2);
    assert.equal(await users.nth(0).evaluate(n => n.readOnly), true); assert.equal(await users.nth(0).inputValue(), 'CONTOSO\\svc-app'); assert.equal(await users.nth(1).inputValue(), 'CONTOSO\\svc-task');
    const dtext = await dialog.innerText();
    assert.ok(dtext.includes('等 7 項') && dtext.includes('Svc 5') && !dtext.includes('Svc 6'), dtext);
    assert.equal((dtext.match(/同一帳號會用於以上所有項目/g) || []).length, 1, 'only the multi-item group says the shared-account sentence');
    assert.ok(dtext.includes('帳號由還原計畫核准，無法在這裡更改') && !/SecretRef|SecretA|SecretB/.test(dtext));
    assert.equal(await dialog.locator('input[type=password][autocomplete="current-password"]').count(), 2);
    assert.equal(await dialog.locator('label', { hasText: '由這個視窗接手此還原' }).count(), 1, 'takeover shown on non-originating tab');
    assert.deepEqual(await dialog.locator('button:visible').allInnerTexts(), ['顯示', '延後這組', '顯示', '延後這組', '送出並繼續還原', '稍後再輸入', '取消這次還原']);
    assert.equal((await active()).id, 'credential-0-pass', 'focus on first password (account is readonly)');
    // show / hide toggle
    const toggle0 = dialog.locator('button[aria-controls="credential-0-pass"]'); await toggle0.click();
    assert.equal(await dialog.locator('#credential-0-pass').getAttribute('type'), 'text'); assert.equal(await toggle0.getAttribute('aria-pressed'), 'true'); assert.equal(await toggle0.innerText(), '隱藏'); assert.equal(await toggle0.getAttribute('aria-controls'), 'credential-0-pass');
    await toggle0.click(); assert.equal(await dialog.locator('#credential-0-pass').getAttribute('type'), 'password');

    // 2. re-render the job list many times: dialog and typed password survive
    await dialog.locator('#credential-0-pass').fill(SENTINEL);
    await page.evaluate(() => { document.getElementById('credential-0-pass').__mark = 'same-node'; for (let i = 0; i < 4; i++) window.WsmConsole.renderJobs(); });
    await page.waitForTimeout(3600); // at least one real poll interval
    assert.equal(await isOpen(), true); assert.equal(await dialog.locator('#credential-0-pass').inputValue(), SENTINEL);
    assert.equal(await page.evaluate(() => document.getElementById('credential-0-pass').__mark), 'same-node', 'dialog content must not be rebuilt by renderJobs');

    // 3. empty-password submit: summary + aria-invalid + no request
    resetNet();
    await dialog.getByRole('button', { name: '送出並繼續還原' }).click();
    assert.equal(requests.length, 0, 'no request when a password is empty');
    const summary = dialog.locator('.credential-summary[role=alert]'); assert.equal(await summary.isVisible(), true);
    assert.ok((await summary.innerText()).includes('排程工作、IIS 應用程式集區'), await summary.innerText());
    assert.equal(await dialog.locator('#credential-1-pass').getAttribute('aria-invalid'), 'true'); assert.equal(await dialog.locator('#credential-0-pass').getAttribute('aria-invalid'), null);
    await summary.locator('button.credential-link').first().click(); assert.equal((await active()).id, 'credential-1-pass', 'summary link focuses the field');

    // 4. defer second group then submit: defer first (only that group), then credentials with takeover
    await dialog.getByRole('button', { name: '延後這組' }).nth(1).click();
    assert.equal(await dialog.locator('#credential-1-pass').isVisible(), false); assert.ok((await dialog.innerText()).includes('已延後：這些項目這次不會還原，其他項目照常進行'));
    await dialog.getByRole('button', { name: '改回輸入' }).click(); assert.equal(await dialog.locator('#credential-1-pass').isVisible(), true);
    await dialog.getByRole('button', { name: '延後這組' }).nth(1).click();
    await dialog.locator('label', { hasText: '由這個視窗接手此還原' }).locator('input').check();
    reply('POST /service-credentials/defer', { body: { job: mkJob(ID, { requiredSecretRefs: ['SecretA'], credentialRequirements: [twoReqs[0], Object.assign({}, twoReqs[1], { Deferred: true })] }) }, delay: 150 });
    reply('POST /service-credentials', { status: 202, body: { job: mkJob(ID, { status: 'Running' }) }, delay: 400 });
    await dialog.getByRole('button', { name: '送出並繼續還原' }).click();
    await page.waitForFunction(() => /送出中/.test(document.querySelector('#credential-dialog .primary-button').textContent));
    assert.equal(JSON.stringify(await dialog.locator('button:visible:not([disabled])').allInnerTexts()), '[]', 'every button is disabled while submitting');
    await page.waitForFunction(() => !document.getElementById('credential-dialog').open);
    assert.deepEqual(requests.map(r => r.key), ['POST /service-credentials/defer', 'POST /service-credentials']);
    assert.deepEqual(requests[0].body, { secretRefs: ['SecretB'] });
    assert.deepEqual(requests[1].body, { credentials: { SecretA: { username: 'CONTOSO\\svc-app', password: SENTINEL } }, takeover: true });
    assert.equal(await dialog.locator('input').count(), 0, 'dialog content cleared after success');
    assert.equal(await page.evaluate(() => (document.getElementById('notice').textContent)), '已送出帳密，還原繼續進行。');
    assert.equal(await page.evaluate(() => JSON.stringify([JSON.stringify(sessionStorage), JSON.stringify(localStorage), JSON.stringify(window.WsmConsole.state, (k, v) => v instanceof Map ? [...v] : v instanceof Set ? [...v] : v)]).includes('SYNTHETIC-PASSWORD-SENTINEL')), false, 'password sentinel must not appear in storage or state');
    assert.deepEqual(await active(), Object.assign(await active(), { title: ID }), 'focus falls back to the job card title when the button is gone');

    // 5. all groups deferred -> only defer, label changes
    resetNet(); await setJobs([mkJob(ID, { credentialRequirements: twoReqs, requiredSecretRefs: ['SecretA', 'SecretB'] })]);
    await page.locator('#job-list').getByRole('button', { name: '輸入帳密以繼續' }).click();
    await dialog.getByRole('button', { name: '延後這組' }).first().click(); await dialog.getByRole('button', { name: '延後這組' }).first().click();
    assert.equal(await dialog.locator('.primary-button').innerText(), '延後並繼續還原其他項目');
    reply('POST /service-credentials/defer', { body: { job: mkJob(ID, { status: 'Running' }) } });
    await dialog.locator('.primary-button').click(); await page.waitForFunction(() => !document.getElementById('credential-dialog').open);
    assert.deepEqual(requests.map(r => r.key), ['POST /service-credentials/defer']); assert.deepEqual(requests[0].body.secretRefs.sort(), ['SecretA', 'SecretB']);

    // 6. 409 preview changed -> message, submit hidden, password cleared, account kept
    resetNet(); await setJobs([mkJob(ID, { credentialRequirements: twoReqs, requiredSecretRefs: ['SecretA', 'SecretB'] })]);
    await page.locator('#job-list').getByRole('button', { name: '輸入帳密以繼續' }).click();
    await dialog.locator('#credential-0-pass').fill(SENTINEL); await dialog.locator('#credential-1-pass').fill(SENTINEL);
    reply('POST /service-credentials', { status: 409, body: { code: 'challenge_revoked_preview_changed', message: 'preview changed' } });
    await dialog.locator('.primary-button').click(); await dialog.locator('.credential-summary').waitFor({ state: 'visible' });
    assert.ok((await dialog.locator('.credential-summary').innerText()).includes('還原範圍或目標已變更，這次等待已失效。請重新預覽後再開始還原。'));
    assert.equal(await dialog.locator('.primary-button').isVisible(), false); assert.equal(await dialog.locator('#credential-0-pass').inputValue(), ''); assert.equal(await dialog.locator('#credential-1-pass').inputValue(), '');
    assert.equal(await dialog.locator('#credential-0-user').inputValue(), 'CONTOSO\\svc-app');
    // 7. generic failure keeps the dialog, clears passwords, keeps accounts
    await dialog.getByRole('button', { name: '稍後再輸入' }).click(); assert.equal(await isOpen(), false);
    assert.equal((await active()).key, 'credential-open:' + ID, 'focus returns to the trigger button');
    await page.locator('#job-list').getByRole('button', { name: '輸入帳密以繼續' }).click();
    await dialog.locator('#credential-0-pass').fill(SENTINEL); await dialog.locator('#credential-1-pass').fill(SENTINEL);
    reply('POST /service-credentials', { status: 500, body: { message: 'boom from fixture' } });
    await dialog.locator('.primary-button').click(); await dialog.locator('.credential-summary').waitFor({ state: 'visible' });
    assert.ok((await dialog.locator('.credential-summary').innerText()).includes('boom from fixture')); assert.ok(!(await dialog.locator('.credential-summary').innerText()).includes(SENTINEL));
    assert.equal(await dialog.locator('#credential-0-pass').inputValue(), ''); assert.equal(await dialog.locator('#credential-0-user').inputValue(), 'CONTOSO\\svc-app'); assert.equal(await dialog.locator('.primary-button').isEnabled(), true);

    // 8. cancel needs a second step; the request is only sent after 確定取消
    resetNet(); await dialog.getByRole('button', { name: '取消這次還原' }).click();
    assert.equal(requests.length, 0); assert.equal(await dialog.locator('.credential-cancel-confirm').isVisible(), true); assert.ok((await dialog.locator('.credential-cancel-confirm').innerText()).includes('警告'));
    await dialog.getByRole('button', { name: '返回' }).click(); assert.equal(await dialog.locator('.credential-cancel-confirm').isVisible(), false); assert.equal(requests.length, 0);
    await dialog.getByRole('button', { name: '取消這次還原' }).click();
    reply('POST /service-credentials/cancel', { body: { job: mkJob(ID, { status: 'Cancelled' }) } });
    await dialog.getByRole('button', { name: '確定取消' }).click(); await page.waitForFunction(() => !document.getElementById('credential-dialog').open);
    assert.deepEqual(requests.map(r => [r.key, r.body]), [['POST /service-credentials/cancel', {}]]);

    // 9. rejected password, deferred requirement without input
    resetNet(); await setJobs([mkJob(ID, { requiredSecretRefs: ['SecretA', 'SecretB', 'SecretC'], credentialRequirements: [req('SecretA', ['Service'], ['Svc 1'], 'CONTOSO\\a'), req('SecretB', ['Service'], ['Svc 2'], 'CONTOSO\\b', { LastFailure: 'CredentialRejected', Attempts: 1 }), req('SecretC', ['ScheduledTask'], ['Task 3'], 'CONTOSO\\c', { Deferred: true })] })]);
    await page.locator('#job-list').getByRole('button', { name: '輸入帳密以繼續' }).click();
    assert.equal(await dialog.locator('fieldset').count(), 3); assert.equal(await dialog.locator('input[type=password]').count(), 2, 'deferred requirement has no password input');
    const rejected = dialog.locator('.credential-rejected'); assert.equal(await rejected.count(), 1); assert.equal(await rejected.getAttribute('role'), 'alert');
    assert.equal(await rejected.innerText(), '上次輸入的密碼被拒絕，未對這些項目做任何變更。請確認後重新輸入（第 1／3 次）。');
    assert.equal(await dialog.locator('#credential-1-pass').getAttribute('aria-invalid'), 'true'); assert.equal((await active()).id, 'credential-1-pass');
    await page.keyboard.press('Escape'); assert.equal(await isOpen(), false);

    // 10. legacy data (requiredSecretRefs only)
    await setJobs([mkJob(ID, { requiredSecretRefs: ['LegacyRefOne', 'LegacyRefTwo'] })]);
    assert.ok(!(await page.locator('#job-list').innerText()).includes('LegacyRef'));
    await page.locator('#job-list').getByRole('button', { name: '輸入帳密以繼續' }).click();
    assert.deepEqual(await dialog.locator('legend').allInnerTexts(), ['帳戶 1', '帳戶 2']); assert.ok(!(await dialog.innerText()).includes('LegacyRef'));
    assert.equal(await dialog.locator('#credential-0-user').evaluate(n => n.readOnly), false); assert.equal((await active()).id, 'credential-0-user', 'focus on editable account');
    resetNet(); await dialog.locator('#credential-0-user').fill('LOCAL\\u1'); await dialog.locator('#credential-0-pass').fill(SENTINEL); await dialog.locator('#credential-1-pass').fill(SENTINEL);
    await dialog.locator('.primary-button').click(); assert.equal(requests.length, 0, 'empty editable account blocks submit'); assert.equal(await dialog.locator('#credential-1-user').getAttribute('aria-invalid'), 'true');
    await page.keyboard.press('Escape');

    // 11. Interrupted: resumable false vs true
    await setJobs([mkJob(ID, { status: 'Interrupted', resumable: false })]);
    assert.equal(await page.locator('#job-list').getByRole('button', { name: '檢視恢復預覽' }).count(), 0);
    await setJobs([mkJob(ID, { status: 'Interrupted', resumable: true })]);
    assert.ok((await page.locator('#job-list').innerText()).includes('還原程序中斷，已完成的項目會保留'));
    assert.equal(await page.locator('#job-list').getByRole('button', { name: '檢視恢復預覽' }).count(), 1); assert.equal(await page.locator('#job-list').getByRole('button', { name: '取消這次還原' }).count(), 1);

    // 12. auto-popup: only the originating tab (sessionStorage pending id), once per job id
    const OWN = 'bbbbbbbb-0000-0000-0000-000000000002', OTHER = 'cccccccc-0000-0000-0000-000000000003', ownReqs = [req('SecretA', ['Service'], ['Svc 1'], 'CONTOSO\\a')];
    await page.evaluate(({ id, key }) => sessionStorage.setItem(key, JSON.stringify({ operationId: id, workspace: 'C:\\fixture\\target' })), { id: OWN, key: `wsm.pending.v1.${encodeURIComponent(workspace.toLowerCase())}` });
    await setJobs([mkJob(OTHER, { credentialRequirements: ownReqs, requiredSecretRefs: ['SecretA'] })]); assert.equal(await isOpen(), false, 'other job in the same tab does not auto-open');
    await setJobs([mkJob(OTHER, { credentialRequirements: ownReqs, requiredSecretRefs: ['SecretA'] }), mkJob(OWN, { credentialRequirements: ownReqs, requiredSecretRefs: ['SecretA'] })]);
    assert.equal(await isOpen(), true, 'originating tab auto-opens');
    assert.equal(await dialog.locator('label', { hasText: '由這個視窗接手此還原' }).count(), 0, 'no takeover checkbox on the originating tab');
    await page.keyboard.press('Escape'); assert.equal(await isOpen(), false);
    await focusKey('credential-open:' + OWN, 'Escape returns focus to the card button');
    await page.evaluate(() => { for (let i = 0; i < 3; i++) window.WsmConsole.renderJobs(); }); assert.equal(await isOpen(), false, 'same job id never auto-opens twice');
    await page.evaluate(() => sessionStorage.clear()); await page.evaluate(() => window.WsmConsole.credentialUi.autoOpened.clear());

    // 13. keyboard walk + screenshots (1280 and 320)
    fs.mkdirSync(screens, { recursive: true });
    await setJobs([mkJob(ID, { credentialRequirements: twoReqs, requiredSecretRefs: ['SecretA', 'SecretB'] })]);
    await page.locator('#job-list').getByRole('button', { name: '輸入帳密以繼續' }).focus(); await page.keyboard.press('Enter'); assert.equal(await isOpen(), true);
    const seen = new Set(); for (let i = 0; i < 20; i++) { const a = await active(); seen.add(`${a.tag}:${a.id}:${a.text}`); await page.keyboard.press('Tab'); }
    const controls = await dialog.locator('input:not([readonly]), button, input[readonly]').count(); const walked = [...seen].filter(x => !x.startsWith('BODY'));
    assert.ok(walked.length >= 9, `Tab must reach the controls inside the dialog: ${walked.join(' | ')}`);
    assert.equal(await page.evaluate(() => document.getElementById('credential-dialog').contains(document.activeElement)), true, 'Tab stays trapped inside the modal dialog');
    await page.screenshot({ path: path.join(screens, 'credential-1280.png') });
    await page.setViewportSize({ width: 320, height: 640 }); await page.waitForTimeout(150);
    await dialog.locator('#credential-0-pass').fill('x'); const sw = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, dlg: document.getElementById('credential-dialog').scrollWidth, dlgClient: document.getElementById('credential-dialog').clientWidth }));
    assert.ok(sw.doc <= 320, `320px page must not scroll horizontally: ${JSON.stringify(sw)}`); assert.ok(sw.dlg <= sw.dlgClient + 1, `dialog content fits: ${JSON.stringify(sw)}`);
    await page.screenshot({ path: path.join(screens, 'credential-320.png') });
    await page.keyboard.press('Escape'); assert.equal(await isOpen(), false); await focusKey('credential-open:' + ID, 'Escape returns focus to the trigger');
    await page.setViewportSize({ width: 1280, height: 900 });

    // 14. resume flow
    const RID = 'dddddddd-0000-0000-0000-000000000004', previewOk = { resumable: true, reason: '', previewCurrent: true, pendingItems: [{ itemId: 'x1', displayName: 'IIS 站台 Portal', phase: 'Applying' }, { itemId: 'x2', displayName: 'Task Nightly', phase: 'Verifying' }], challengeState: 'None', credentialRequirements: [] };
    resetNet(); await setJobs([mkJob(RID, { status: 'Interrupted', resumable: true })]);
    const resumeBtn = page.locator('#job-list').getByRole('button', { name: '檢視恢復預覽' });
    reply('GET /resume-preview', { status: 500, body: { message: 'preview boom' }, delay: 500 });
    await resumeBtn.click(); await dialog.getByText('正在讀取恢復狀態…').waitFor(); assert.equal(await page.locator('#credential-dialog-title').innerText(), '檢視恢復預覽');
    await dialog.getByText('preview boom', { exact: false }).waitFor();
    reply('GET /resume-preview', { body: previewOk }); await dialog.getByRole('button', { name: '重試' }).click();
    await dialog.getByText('結果需要核對的項目').waitFor();
    assert.ok((await dialog.innerText()).includes('IIS 站台 Portal（Applying）')); assert.ok((await dialog.innerText()).includes('已完成的項目不會重做；結果無法確認的項目會標為待人工確認，不會自動重新套用'));
    const go = dialog.getByRole('button', { name: '繼續還原' }); assert.equal(await go.isDisabled(), true);
    await dialog.getByLabel('我了解並要繼續這次還原').check(); assert.equal(await go.isEnabled(), true);
    reply('POST /resume', { status: 503, body: { message: 'network down' } });
    await go.click(); await dialog.getByText('network down', { exact: false }).waitFor(); assert.equal(await go.isEnabled(), true);
    reply('POST /resume', { status: 202, body: { job: mkJob(RID, { status: 'WaitingForInput', requiredSecretRefs: ['SecretA'], credentialRequirements: [req('SecretA', ['Service'], ['Svc 1'], 'CONTOSO\\a')] }) } });
    await go.click(); await dialog.getByText('輸入帳戶密碼以繼續還原').waitFor();
    const resumes = requests.filter(r => r.key === 'POST /resume'); assert.equal(resumes.length, 2);
    assert.match(resumes[0].body.continuationId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/); assert.equal(resumes[0].body.continuationId, resumes[1].body.continuationId, 'retry reuses the same continuationId'); assert.equal(resumes[0].body.confirm, true); assert.deepEqual(Object.keys(resumes[0].body).sort(), ['confirm', 'continuationId']);
    assert.equal(await page.evaluate(id => sessionStorage.getItem(`wsm.resume.continuation.v1.${id}`), RID), null, 'continuation id removed after success');
    assert.equal(await dialog.locator('fieldset').count(), 1, 'WaitingForInput opens the credential dialog'); await page.keyboard.press('Escape');
    // previewCurrent=false
    resetNet(); await setJobs([mkJob(RID, { status: 'Interrupted', resumable: true })]);
    reply('GET /resume-preview', { body: Object.assign({}, previewOk, { previewCurrent: false }) });
    await resumeBtn.click(); await dialog.getByText('還原範圍或目標已在中斷後變更，無法接續。請取消這次還原並重新預覽。').waitFor();
    assert.equal(await dialog.getByRole('button', { name: '繼續還原' }).count(), 0); assert.equal(await dialog.getByRole('button', { name: '取消這次還原' }).count(), 1);
    await dialog.getByRole('button', { name: '取消這次還原' }).click(); assert.equal(requests.filter(r => r.key === 'POST /cancel').length, 0);
    reply('POST /cancel', { body: { job: mkJob(RID, { status: 'Cancelled' }) } }); await dialog.getByRole('button', { name: '確定取消' }).click(); await page.waitForFunction(() => !document.getElementById('credential-dialog').open);
    assert.deepEqual(requests.filter(r => r.key === 'POST /cancel').map(r => r.body), [{}]);
    // zero pending items
    resetNet(); await setJobs([mkJob(RID, { status: 'Interrupted', resumable: true })]); reply('GET /resume-preview', { body: Object.assign({}, previewOk, { pendingItems: [] }) });
    await resumeBtn.click(); await dialog.getByText('沒有結果不明的項目').waitFor(); await page.keyboard.press('Escape'); await focusKey('resume-open:' + RID, 'Escape returns focus to the resume button');
    // card-level cancel for an interrupted restore goes through a confirmation too
    resetNet(); await page.locator('#job-list').getByRole('button', { name: '取消這次還原' }).click(); assert.equal(await isOpen(), true); assert.equal(requests.length, 0);
    await dialog.getByRole('button', { name: '取消這次還原' }).click(); assert.equal(requests.length, 0); await page.keyboard.press('Escape');

    // 15. cleanliness
    const html = fs.readFileSync(assets.get('/ui/console.js'), 'utf8'); const block = html.slice(html.indexOf('// F4b:'), html.indexOf('function jobTitleNode'));
    assert.ok(!/innerHTML|window\.confirm|localStorage|console\.(log|error|warn)/.test(block), 'dialog code uses no innerHTML / confirm / localStorage / console');
    assert.deepEqual(errors, [], 'no page errors');
    process.stdout.write('PASS: credential dialog UI (structure, focus, rerender survival, validation, defer, rejection, 409, cancel two-step, legacy data, auto-popup, resume, 320px)\n');
  } finally { if (browser) await browser.close(); server.close(); }
})().catch(error => { console.error(error); process.exit(1); });
