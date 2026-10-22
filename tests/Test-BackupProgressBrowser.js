// Real-browser (Edge) test for B1: the one-click backup progress card (F1-P) and the connection-failure prompts (F2).
// The UI under test is the real src/ui files served from disk. Part A..E replace the local API with a controllable fixture;
// part F starts the real PowerShell console on a workspace whose backup job was interrupted and reads the progress back.
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const screens = path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });

// ---- static server for the real UI files (a fault switch lets a test remove or damage one asset) ----
const staticFiles = new Map([['/', 'index.html'], ['/ui/index.html', 'index.html'], ['/ui/console.js', 'console.js'], ['/ui/console.css', 'console.css'], ['/ui/guide.html', 'guide.html'], ['/ui/nonc.js', 'nonc.js']]);
const assetHashes = {};
for (const [route, name] of staticFiles) { if (route.startsWith('/ui/')) assetHashes[route] = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, 'src', 'ui', name))).digest('hex'); }
const server = http.createServer((request, response) => {
  const route = new URL(request.url, 'http://127.0.0.1').pathname, name = staticFiles.get(route);
  if (!name) { response.writeHead(404); response.end('Not found'); return; }
  const file = path.join(root, 'src', 'ui', name);
  response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' });
  fs.createReadStream(file).pipe(response);
});

const PAIR = 'fixture-pair', JOB = '11111111-2222-4333-8444-555555555555';
const iso = ms => new Date(Date.now() + ms).toISOString();
function backupView(over) {
  return Object.assign({
    Stage: 'Capture', StageLabel: '擷取與封存', StageIndex: 1, StageCount: 3, Workload: '網站 A', CurrentFile: 'nested\\file1.txt', ItemsDone: 1, ItemsTotal: 4,
    BytesDone: 5242880, BytesTotal: null, Percent: 25, StartedUtc: iso(-65000), UpdatedUtc: iso(-1000), Recent: [{ ItemId: 'item-1', ItemName: '網站 A 設定', Result: 'Succeeded' }],
    FailedCount: 0, Terminal: false, Outcome: '', State: 'Running', EndReason: ''
  }, over || {});
}
function backupJob(viewOver, jobOver) {
  return Object.assign({
    jobId: JOB, action: 'StartBackup', status: 'Running', role: 'Source', pairId: PAIR, workspace: root, sessionId: 'fixture-session', contextId: 'fixture-context', startedRevision: 5,
    startedUtc: iso(-65000), canCancel: true, outputs: [], progress: { activity: '', statusDescription: '', currentOperation: '', percent: null, processedCount: null, updatedUtc: iso(-1000), backup: backupView(viewOver) }
  }, jobOver || {});
}

async function openPage(browser, scenario, hash, contextOptions) {
  const context = await browser.newContext(Object.assign({ viewport: { width: 1280, height: 900 } }, contextOptions || {}));
  const page = await context.newPage();
  const errors = [], posts = { cancel: 0, operations: 0 }, ctl = { jobs: scenario.jobs || [], failures: scenario.failures || {} };
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  const session = { token: 'memory-only-test-token', sessionId: 'fixture-session', contextId: 'fixture-context', hostName: 'fixture-host', role: 'Source', workspace: root, pairId: PAIR, revision: 5, decisionRevision: 7, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: 'fixture-data-1', principal: 'fixture-user', assetHashes: scenario.assetHashes || assetHashes };
  const viewContext = () => ({ sessionId: session.sessionId, contextId: session.contextId, pairId: PAIR, role: 'Source', revision: 5, decisionRevision: 7, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: session.dataVersion, readUtc: new Date().toISOString() });
  await page.route(/\/api\/.*/, async route => {
    const request = route.request(), parsed = new URL(request.url()), pathname = parsed.pathname, method = request.method();
    const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    const fault = ctl.failures[method + ' ' + pathname];
    if (fault) return fault(route, json, ctl);
    if (pathname === '/api/session') return json(session);
    if (pathname === '/api/context' && method === 'GET') return json({ roles: ['Source'], pairs: [{ pairId: PAIR, label: 'Fixture pair' }], role: 'Source', pairId: PAIR, revision: 5, decisionRevision: 7, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: session.dataVersion, contextId: session.contextId });
    if (pathname === '/api/wizard') return json({ kind: 'WizardProjection', intentRequired: false, legacy: false, role: 'Source', workspaceRole: 'Source', roleMatchesWorkspace: true, pairId: PAIR, state: { CurrentStep: 'backup', Mode: 'ItemByItem' }, revision: 5, currentStep: 'backup', reviewGroupIndex: 0, groups: [], gates: [], actions: [], missingFields: [], scan: { status: 'Succeeded', hasResult: true, itemCount: 3, incompleteCount: 0 }, results: { scan: { status: 'Succeeded', hasDurableRecord: true }, backup: { status: 'Succeeded', hasDurableRecord: true }, restore: { status: 'NotStarted', hasDurableRecord: false }, hasAny: true }, context: { catalogRevision: 7, selectionRevision: 3, inventoryRevision: 1 } });
    if (pathname === '/api/wizard/runtime') return json({ Kind: 'WizardRuntimeProjection', Role: 'Source', PairId: PAIR, actions: [], viewContext: viewContext() });
    if (pathname === '/api/wizard/nonc') return json({ Kind: 'WizardNonCProjection', Role: 'Source', PairId: PAIR, ContextId: session.contextId, DataVersion: session.dataVersion });
    if (pathname === '/api/jobs' && method === 'GET') return json({ items: ctl.jobs });
    const cancelMatch = pathname.match(/^\/api\/jobs\/([^/]+)\/cancel$/);
    if (cancelMatch && method === 'POST') {
      posts.cancel++;
      if (scenario.cancelDelayMs) await new Promise(resolve => setTimeout(resolve, scenario.cancelDelayMs));
      ctl.jobs = ctl.jobs.map(job => job.jobId === cancelMatch[1] ? Object.assign({}, job, { status: 'CancelRequested', progress: Object.assign({}, job.progress, { backup: Object.assign({}, job.progress.backup, { State: 'CancelRequested' }) }) }) : job);
      return json(ctl.jobs.find(job => job.jobId === cancelMatch[1]));
    }
    if (pathname === '/api/operations' && method === 'POST') { posts.operations++; return route.abort('connectionreset'); }
    if (pathname === '/api/view') return json({ viewContext: viewContext(), rows: [], items: [] });
    errors.push(`unhandled fixture route ${method} ${pathname}`);
    return json({ message: `Unhandled fixture route ${method} ${pathname}` }, 404);
  });
  await page.goto(`http://127.0.0.1:${server.address().port}/${hash || '#wizard'}`, { waitUntil: 'domcontentloaded' });
  return { page, context, errors, posts, ctl };
}
const card = page => page.locator('.progress-card[data-progress-card="wizard"]');
const waitCard = async page => { await page.waitForSelector('.progress-card[data-progress-card="wizard"]:not([hidden])', { timeout: 30000 }); };
const refresh = page => page.evaluate(() => window.WsmConsole.refreshJobs());
const parseClock = text => { const parts = text.split(':').map(Number); return parts.reduce((total, part) => total * 60 + part, 0); };
const noHorizontalOverflow = async (page, width) => { const overflow = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth })); assert.ok(overflow.scroll <= overflow.client + 1, `horizontal overflow at ${width}px: ${JSON.stringify(overflow)}`); };

(async () => {
  await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
  const browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
  const mainErrors = [];
  let counts = { cardChecks: 0, f2: 0 };
  try {
    // ============ A. card fields, elapsed clock, recent list, unknown totals ============
    {
      const recent = Array.from({ length: 25 }, (_, i) => ({ ItemId: 'item-' + (i + 1), ItemName: '工作負載 ' + (i + 1), Result: i === 3 ? 'Failed' : 'Succeeded' }));
      const { page, errors } = await openPage(browser, { jobs: [backupJob({ Recent: recent })] });
      await waitCard(page);
      const c = card(page);
      assert.match(await c.locator('.progress-step').textContent(), /^第 1 步／共 3 步：擷取與封存$/);
      assert.equal(await c.locator('progress').evaluate(n => n.tagName), 'PROGRESS', 'the meter must be the native <progress>');
      assert.equal(await c.locator('progress').getAttribute('value'), '25');
      assert.equal((await c.locator('.progress-percent').textContent()).trim(), '25%');
      const text = await c.textContent();
      for (const expected of ['目前工作負載', '網站 A', '目前檔案', 'nested\\file1.txt', '項目（已完成／總數）', '1 / 4', '5.0 MiB / 未知', '經過時間', '狀態：執行中', '最近完成']) assert.ok(text.includes(expected), 'card is missing: ' + expected);
      assert.equal((await c.locator('.progress-icon').textContent()).trim(), '▶');
      assert.equal(await c.locator('.progress-icon').getAttribute('aria-hidden'), 'true', 'the icon is decoration; the state is also written as text');
      assert.equal(await c.locator('.progress-recent-list li').count(), 20, 'the recent list shows at most the newest 20 rows');
      assert.match(await c.locator('.progress-recent-list li').first().textContent(), /工作負載 6：成功/);
      assert.match(await c.locator('.progress-recent-list li').nth(18).textContent(), /工作負載 24：成功/);
      // collapsible
      const details = c.locator('details.progress-recent');
      assert.equal(await details.evaluate(n => n.open), false);
      await details.locator('summary').click(); assert.equal(await details.evaluate(n => n.open), true);
      await details.locator('summary').click(); assert.equal(await details.evaluate(n => n.open), false);
      // elapsed time advances without any API call
      const first = parseClock((await c.locator('.progress-facts dd').nth(4).textContent()).trim());
      await page.waitForFunction(from => { const dd = document.querySelectorAll('.progress-card[data-progress-card="wizard"] .progress-facts dd')[4]; return !!dd && dd.textContent.trim().split(':').map(Number).reduce((total, part) => total * 60 + part, 0) >= from + 2; }, first, { timeout: 30000 });
      const second =parseClock((await c.locator('.progress-facts dd').nth(4).textContent()).trim());
      assert.ok(second >= first + 2, `elapsed time did not advance (${first} -> ${second})`);
      counts.cardChecks += 14;
      await page.screenshot({ path: path.join(screens, 'b1-desktop-wizard-running.png'), fullPage: false });
      mainErrors.push(...errors);
      await page.close();
    }
    {
      // unknown totals are shown as 未知, never 0; indeterminate progress has no value
      const { page, errors } = await openPage(browser, { jobs: [backupJob({ ItemsTotal: null, BytesTotal: null, BytesDone: null, Percent: null })] });
      await waitCard(page); const c = card(page);
      assert.equal(await c.locator('progress').getAttribute('value'), null, 'unknown percent must leave <progress> indeterminate');
      assert.match(await c.locator('.progress-percent').textContent(), /未知/);
      const text = await c.textContent();
      assert.ok(text.includes('1 / 未知') && text.includes('未知 / 未知'), 'unknown totals must read 未知: ' + text);
      assert.ok(!/ 0 \/ 0/.test(text), 'unknown totals must not be shown as 0');
      counts.cardChecks += 4; mainErrors.push(...errors); await page.close();
    }

    // ============ B. seven states: text and icon ============
    {
      const states = [['Waiting', '○', '等待中', 'Queued'], ['Running', '▶', '執行中', 'Running'], ['CancelRequested', '■', '取消要求中', 'CancelRequested'], ['AwaitingDelivery', '⇢', '等待交付', 'Succeeded'], ['Completed', '✔', '完成', 'Succeeded'], ['PartialFailure', '⚠', '部分失敗', 'Succeeded'], ['Failed', '✖', '失敗', 'Failed']];
      const { page, errors, ctl } = await openPage(browser, { jobs: [backupJob()] });
      await waitCard(page);
      for (const [stateName, icon, label, jobStatus] of states) {
        ctl.jobs = [backupJob({ State: stateName, StageIndex: 3, StageLabel: '交付', Stage: 'Deliver', Terminal: !['Waiting', 'Running', 'CancelRequested'].includes(stateName) }, { status: jobStatus, canCancel: jobStatus === 'Running' })];
        await refresh(page);
        await page.waitForFunction(expected => document.querySelector('.progress-card[data-progress-card="wizard"] .progress-state').textContent === expected, '狀態：' + label, { timeout: 10000 });
        assert.equal((await card(page).locator('.progress-icon').textContent()).trim(), icon, 'icon for ' + stateName);
        assert.equal(await card(page).getAttribute('data-state'), stateName);
        counts.cardChecks++;
      }
      ctl.jobs = [backupJob({ State: 'Failed', EndReason: 'Interrupted', Terminal: true }, { status: 'Interrupted', canCancel: false })]; await refresh(page);
      await page.waitForFunction(() => document.querySelector('.progress-card[data-progress-card="wizard"] .progress-reason').textContent.includes('已中斷'), null, { timeout: 10000 });
      assert.ok(await card(page).locator('.progress-cancel').isHidden(), 'a finished job has no cancel button');
      counts.cardChecks += 2; mainErrors.push(...errors); await page.close();
    }

    // ============ C. live region and focus: in-place updates ============
    {
      const { page, errors, ctl } = await openPage(browser, { jobs: [backupJob()] });
      await waitCard(page);
      await page.evaluate(() => {
        const live = document.querySelector('.progress-card[data-progress-card="wizard"] .progress-live');
        window.__live = [live.textContent]; new MutationObserver(() => window.__live.push(live.textContent)).observe(live, { childList: true, characterData: true, subtree: true });
        document.querySelector('.progress-card[data-progress-card="wizard"]').dataset.mark = 'same-node';
      });
      const liveLog = () => page.evaluate(() => window.__live.slice());
      assert.equal((await liveLog()).length, 1, 'the first render announces once');
      await page.locator('.progress-card[data-progress-card="wizard"] summary').focus();
      // five refreshes that only move bytes, the current file, counters and the clock
      for (let i = 1; i <= 5; i++) { ctl.jobs = [backupJob({ BytesDone: 5242880 + i * 1024, CurrentFile: `nested\\file${i + 1}.txt`, ItemsDone: 1, Percent: 25 }, {})]; await refresh(page); }
      assert.equal((await liveLog()).length, 1, 'file/byte/clock changes must not touch the live region: ' + JSON.stringify(await liveLog()));
      assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.tagName), 'SUMMARY', 'refresh must not steal focus from the recent-list summary');
      assert.equal(await page.evaluate(() => document.querySelector('.progress-card[data-progress-card="wizard"]').dataset.mark), 'same-node', 'refresh must update the card in place');
      assert.match(await card(page).locator('.progress-facts dd').nth(1).textContent(), /file6\.txt/);
      // a stage change announces exactly once more
      ctl.jobs = [backupJob({ Stage: 'Verify', StageLabel: '驗證封裝', StageIndex: 2, Workload: '', CurrentFile: '', Percent: null, ItemsDone: 4 })]; await refresh(page); await refresh(page);
      let log = await liveLog(); assert.equal(log.length, 2, 'stage change must announce once: ' + JSON.stringify(log));
      assert.match(log[1], /第 2 步／共 3 步：驗證封裝/);
      // a workload change announces once more
      ctl.jobs = [backupJob({ Workload: '網站 B', ItemsDone: 2 })]; await refresh(page); await refresh(page);
      log = await liveLog(); assert.equal(log.length, 3, 'workload change must announce once: ' + JSON.stringify(log));
      assert.match(log[2], /網站 B/);
      assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.tagName), 'SUMMARY');
      counts.cardChecks += 8; mainErrors.push(...errors); await page.close();
    }

    // ============ D. cancel: confirm first, once only ============
    {
      const { page, errors, posts } = await openPage(browser, { jobs: [backupJob()], cancelDelayMs: 600 });
      await waitCard(page); const c = card(page);
      await c.locator('.progress-cancel').click();
      await page.waitForSelector('#cancel-confirm-dialog[open]');
      assert.equal(posts.cancel, 0, 'opening the confirmation must not send the request');
      assert.match(await page.locator('#cancel-confirm-dialog').textContent(), /確認取消/);
      await page.getByRole('button', { name: '返回' }).click();
      assert.equal(await page.evaluate(() => !!document.querySelector('#cancel-confirm-dialog[open]')), false);
      assert.equal(posts.cancel, 0, 'Back must not send the request');
      assert.equal(await page.evaluate(() => document.activeElement && document.activeElement.classList.contains('progress-cancel')), true, 'focus returns to the cancel button');
      await c.locator('.progress-cancel').click(); await page.waitForSelector('#cancel-confirm-dialog[open]');
      await page.keyboard.press('Escape'); assert.equal(posts.cancel, 0, 'Esc must not send the request');
      await c.locator('.progress-cancel').click(); await page.waitForSelector('#cancel-confirm-dialog[open]');
      // three clicks in the same task: only the first may send
      await page.evaluate(() => { const yes = [...document.querySelectorAll('#cancel-confirm-dialog button')].find(node => node.textContent === '確定取消'); yes.click(); yes.click(); yes.click(); });
      await page.waitForFunction(() => document.querySelector('.progress-card[data-progress-card="wizard"] .progress-state').textContent === '狀態：取消要求中', null, { timeout: 10000 });
      await c.locator('.progress-cancel').click({ force: true, timeout: 500 }).catch(() => {});
      // wait for the request to reach the fixture (condition), then give any duplicate a window to show up (negative check)
      for (let waited = 0; posts.cancel < 1 && waited < 20000; waited += 100) await page.waitForTimeout(100);
      await page.waitForTimeout(500);
      assert.equal(posts.cancel, 1, 'the cancel request is sent exactly once');
      assert.equal(await c.locator('.progress-cancel').isDisabled(), true, 'the button is disabled after the request');
      counts.cardChecks += 8;
      // the job list's own cancel button asks for the same confirmation
      const second = await openPage(browser, { jobs: [backupJob()] }, '#jobs');
      await second.page.waitForSelector('[data-focus-key^="cancel:"]');
      await second.page.locator('[data-focus-key^="cancel:"]').click(); await second.page.waitForSelector('#cancel-confirm-dialog[open]');
      assert.equal(second.posts.cancel, 0);
      await second.page.getByRole('button', { name: '返回' }).click();
      assert.equal(second.posts.cancel, 0, 'Back from the job list confirmation sends nothing');
      await second.page.locator('[data-focus-key^="cancel:"]').click(); await second.page.waitForSelector('#cancel-confirm-dialog[open]');
      await second.page.getByRole('button', { name: '確定取消' }).click();
      await second.page.waitForFunction(() => /取消已送出/.test(document.querySelector('[data-focus-key^="cancel:"]').textContent), null, { timeout: 10000 });
      for (let waited = 0; second.posts.cancel < 1 && waited < 5000; waited += 100) await second.page.waitForTimeout(100);
      assert.equal(second.posts.cancel, 1);
      counts.cardChecks += 4; mainErrors.push(...errors, ...second.errors); await second.page.close(); await page.close();
    }

    // ============ E. reopen: a new page reads the same progress back ============
    {
      const jobs = [backupJob({ ItemsDone: 3, ItemsTotal: 4, Workload: '網站 C' }, { status: 'Running' })];
      const first = await openPage(browser, { jobs }); await waitCard(first.page); await first.page.close();
      const { page, errors } = await openPage(browser, { jobs });
      await waitCard(page);
      assert.ok((await card(page).textContent()).includes('3 / 4') && (await card(page).textContent()).includes('網站 C'), 'a reopened page shows the last progress, not an empty card');
      // the backup results page carries the card on top, too
      await page.evaluate(() => { location.hash = '#jobs?filter=backup'; });
      await page.waitForSelector('.progress-card[data-progress-card="jobs"]:not([hidden])', { timeout: 15000 });
      assert.match(await page.locator('.progress-card[data-progress-card="jobs"] .progress-step').textContent(), /第 1 步／共 3 步/);
      const order = await page.evaluate(() => { const view = document.getElementById('view-jobs'); const kids = [...view.children].map(n => n.className.split(' ')[0] || n.tagName); return kids.slice(0, 3); });
      assert.ok(order.includes('page-heading') && order.indexOf('page-heading') < order.indexOf('panel'), 'the card sits right below the heading, above the results: ' + order.join(','));
      await page.screenshot({ path: path.join(screens, 'b1-desktop-results-card.png') });
      counts.cardChecks += 4; mainErrors.push(...errors); await page.close();
    }

    // ============ F. 390px layout ============
    {
      const recent = Array.from({ length: 20 }, (_, i) => ({ ItemId: 'item-' + (i + 1), ItemName: '很長的工作負載名稱用來檢查窄螢幕換行 ' + (i + 1), Result: 'Succeeded' }));
      const longFile = 'very-long-directory-name\\' + 'x'.repeat(120) + '\\檔案名稱-' + 'y'.repeat(80) + '.txt';
      const { page, errors } = await openPage(browser, { jobs: [backupJob({ CurrentFile: longFile, Recent: recent, Workload: '一個名稱很長的網站工作負載 '.repeat(4) })] }, '#wizard', { viewport: { width: 390, height: 844 } });
      await waitCard(page); await card(page).locator('summary').click();
      await noHorizontalOverflow(page, 390);
      await page.screenshot({ path: path.join(screens, 'b1-390-wizard-card.png'), fullPage: true });
      await page.evaluate(() => { location.hash = '#jobs?filter=backup'; });
      await page.waitForSelector('.progress-card[data-progress-card="jobs"]:not([hidden])', { timeout: 15000 });
      await noHorizontalOverflow(page, 390);
      await page.screenshot({ path: path.join(screens, 'b1-390-results-card.png'), fullPage: true });
      counts.cardChecks += 2; mainErrors.push(...errors); await page.close();
    }

    // ============ G. F2: five connection failures, each with its own prompt and next step ============
    const bannerOf = async (page, expected) => { await page.waitForFunction(want => { const b = document.getElementById('connection-banner'); return b && !b.hidden && b.dataset.category === want; }, expected, { timeout: 30000 }); return { category: await page.locator('#connection-banner').getAttribute('data-category'), text: await page.locator('#connection-banner').textContent() }; };
    const f2Errors = [];
    {   // G1 listener unreachable: the tool is not running (connection refused on first contact)
      const { page, errors } = await openPage(browser, { failures: { 'GET /api/session': (route) => route.abort('connectionrefused') } });
      const banner = await bannerOf(page, 'listener-unreachable');
      assert.equal(banner.category, 'listener-unreachable'); assert.ok(banner.text.includes('本機工具沒有在執行') && banner.text.includes('重新啟動') && banner.text.includes('下一步'), banner.text);
      await page.screenshot({ path: path.join(screens, 'b1-desktop-f2-listener.png') });
      await page.setViewportSize({ width: 390, height: 844 }); await noHorizontalOverflow(page, 390); await page.screenshot({ path: path.join(screens, 'b1-390-f2-listener.png'), fullPage: true });
      f2Errors.push(...errors); counts.f2++; await page.close();
    }
    {   // G2 resource incomplete: a static file is missing (404) / a file differs from the session hash
      const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
      const p = await context.newPage(); const localErrors = [];
      p.on('pageerror', e => localErrors.push('pageerror: ' + e.message));
      await p.route('**/ui/nonc.js', route => route.fulfill({ status: 404, contentType: 'text/plain', body: 'missing' }));
      await p.route(/\/api\/.*/, async route => {
        const pathname = new URL(route.request().url()).pathname, json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
        if (pathname === '/api/session') return json({ token: 't', sessionId: 's', contextId: 'c', hostName: 'h', role: 'Source', workspace: root, pairId: PAIR, revision: 5, decisionRevision: 7, selectionRevision: 3, sourceSelectionRevision: 3, dataVersion: 'd', principal: 'u', assetHashes });
        return json({ items: [], rows: [] });
      });
      await p.goto(`http://127.0.0.1:${server.address().port}/#wizard`, { waitUntil: 'domcontentloaded' });
      const banner = await bannerOf(p, 'resource-incomplete');
      assert.equal(banner.category, 'resource-incomplete'); assert.ok(banner.text.includes('頁面檔案不完整') && banner.text.includes('重新載入'), banner.text);
      await p.screenshot({ path: path.join(screens, 'b1-desktop-f2-resource.png') });
      f2Errors.push(...localErrors); counts.f2++; await context.close();
      // same category when the bytes differ from the session's hashes (version mismatch)
      const wrong = Object.assign({}, assetHashes, { '/ui/console.css': 'f'.repeat(64) });
      const mismatch = await openPage(browser, { assetHashes: wrong });
      const mismatchBanner = await bannerOf(mismatch.page, 'resource-incomplete');
      assert.equal(mismatchBanner.category, 'resource-incomplete');
      f2Errors.push(...mismatch.errors); counts.f2++; await mismatch.page.close();
    }
    {   // G3 session expired: 401 invalid_token reuses the reconnect flow
      const { page, errors } = await openPage(browser, { failures: { 'GET /api/context': (route, json) => json({ code: 'invalid_token', message: 'session expired' }, 401) } });
      await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.token === null && !document.getElementById('error-summary').hidden, null, { timeout: 30000 });
      assert.match(await page.locator('#error-summary').textContent(), /工作階段(?: token )?已失效|工作階段/);
      assert.equal(await page.locator('#error-summary').getAttribute('data-category'), 'session-expired');
      assert.ok(await page.getByRole('button', { name: '重新連線工作階段' }).count() >= 1, 'the reconnect action is offered');
      f2Errors.push(...errors); counts.f2++; await page.close();
    }
    {   // G4 reset / timeout: the connection drops mid-session on a read
      const { page, errors, ctl } = await openPage(browser, { jobs: [] });
      await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.session, null, { timeout: 30000 });
      ctl.failures['GET /api/view'] = route => route.abort('connectionreset');
      page.evaluate(() => window.WsmConsole.getView('overview', true).catch(() => {}));
      const banner = await bannerOf(page, 'reset-timeout');
      assert.equal(banner.category, 'reset-timeout'); assert.ok(banner.text.includes('連線中斷或逾時') && banner.text.includes('下一步'), banner.text);
      // the banner clears again once the tool answers
      delete ctl.failures['GET /api/view']; await page.evaluate(() => window.WsmConsole.getView('overview', true).catch(() => {}));
      await page.waitForFunction(() => document.getElementById('connection-banner').hidden, null, { timeout: 10000 });
      f2Errors.push(...errors); counts.f2++; await page.close();
    }
    {   // G5 unknown write: the request went out and no answer came back. Never re-sent.
      const { page, errors, posts } = await openPage(browser, { jobs: [] });
      await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.session, null, { timeout: 30000 });
      const opId = 'bbbbbbbb-2222-4333-8444-555555555555';
      // Latch the banner the moment it is shown. The console clears an unknown-write banner when any other request is answered
      // and no pending operation is recorded (this fixture posts straight through endpoint()), so on a loaded host a poll that
      // was still in flight could clear it before a state-polling wait looked. The assertion stays on the banner's category and text.
      await page.evaluate(() => { window.__bannerSeen = null; const snap = () => { const b = document.getElementById('connection-banner'); if (!window.__bannerSeen && b && !b.hidden && b.dataset.category === 'unknown-write') window.__bannerSeen = { category: b.dataset.category, text: b.textContent }; }; new MutationObserver(snap).observe(document.documentElement, { attributes: true, childList: true, subtree: true, characterData: true }); snap(); });
      const outcome = await page.evaluate(async id => { try { await window.WsmConsole.endpoint('/api/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'SetMigrationSpec', operationId: id, idempotencyKey: 'key-' + id, args: {} }) }); return 'sent'; } catch (e) { return e.code + '|' + e.category; } }, opId);
      assert.equal(outcome, 'connection_error|unknown-write');
      await page.waitForFunction(() => window.__bannerSeen, null, { timeout: 30000 });
      const banner = await page.evaluate(() => window.__bannerSeen);
      assert.equal(banner.category, 'unknown-write'); assert.ok(banner.text.includes('上一筆操作結果尚未確認') && banner.text.includes('不要重新提交') && banner.text.includes('不會自動重送'), banner.text);
      await page.waitForTimeout(2500);
      assert.equal(posts.operations, 1, 'the unconfirmed write must never be re-sent automatically');
      const second = await page.evaluate(async () => { try { await window.WsmConsole.endpoint('/api/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'SetMigrationSpec', operationId: 'cccccccc-2222-4333-8444-555555555555', idempotencyKey: 'key-2', args: {} }) }); return 'sent'; } catch (e) { return String(e.message); } });
      assert.match(second, /尚未確認/); assert.equal(posts.operations, 1, 'a second write is refused locally while the first is unconfirmed');
      await page.screenshot({ path: path.join(screens, 'b1-desktop-f2-unknown-write.png') });
      f2Errors.push(...errors); counts.f2++; await page.close();
    }
    // F2 pages see injected network faults, so the browser logs those failed loads; nothing else may be reported.
    const unexpectedF2 = f2Errors.filter(message => !/net::ERR_|Failed to load resource|status of 40[14]|unhandled fixture route|Failed to fetch|Unexpected token|session expired|沒有收到結果|無法連線|不可重新提交/.test(message));
    assert.deepEqual(unexpectedF2, [], 'unexpected console errors on F2 pages');
    assert.ok(counts.f2 >= 6);

    // ============ H. real PowerShell console: an interrupted backup job reads its last progress back by job id ============
    await realConsoleReadback(browser, mainErrors);

    assert.deepEqual(mainErrors, [], 'zero console errors on the progress card pages: ' + JSON.stringify(mainErrors));
    process.stdout.write(`PASS: B1 progress card (${counts.cardChecks} checks) and F2 connection prompts (${counts.f2} cases) in Edge; screenshots in work/r7/screens/b1-*.png\n`);
  } finally {
    await browser.close(); server.close();
  }
})().catch(error => { process.stderr.write(String(error && error.stack || error) + '\n'); process.exit(1); });

async function realConsoleReadback(browser, errorSink) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-b1-real-'));
  let child; const logs = [];
  const start = async () => {
    const ready = path.join(dir, 'ready-' + Date.now() + '.json'), stop = path.join(dir, 'stop');
    try { fs.unlinkSync(stop); } catch (_) {}
    child = spawn(process.env.WSM_PS_EXE || 'powershell.exe', ['-NoProfile', '-File', path.join(__dirname, 'Start-HtmlTestServer.ps1'), '-Workspace', dir, '-ReadyPath', ready, '-StopFile', stop, '-Seed'], { windowsHide: true, env: { ...process.env, PSModulePath: path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') } });
    child.stdout.on('data', d => logs.push(d.toString())); child.stderr.on('data', d => logs.push(d.toString()));
    // Wait on the condition (the console wrote a readable ready file), not on a clock: a loaded host can take minutes to start
    // Windows PowerShell and import the module. The only ways out are the ready file or the child process ending; the long
    // deadline is a safety net against a hung child, not the expected path.
    const readUrl = () => { try { return JSON.parse(fs.readFileSync(ready, 'utf8')).Url.replace(/\/$/, ''); } catch (_) { return null; } };
    const deadline = Date.now() + 900000;
    for (;;) {
      const url = readUrl(); if (url) return url;
      if (child.exitCode !== null) { const late = readUrl(); if (late) return late; throw new Error('console process ended before it was ready (exit ' + child.exitCode + '): ' + (logs.join('') || 'no output')); }
      if (Date.now() > deadline) throw new Error('console did not become ready within the safety deadline: ' + (logs.join('') || 'no output'));
      await new Promise(r => setTimeout(r, 100));
    }
  };
  // Ask the console to stop and wait for the process to actually end (the next start reuses the workspace); only a child that
  // ignores the stop file for a full minute is killed.
  const stop = async () => { if (!child || child.exitCode !== null) return; fs.writeFileSync(path.join(dir, 'stop'), 'stop'); await new Promise(resolve => { const t = setTimeout(() => { child.kill(); resolve(); }, 60000); child.once('exit', () => { clearTimeout(t); resolve(); }); }); };
  try {
    let origin = await start();
    const session = await (await fetch(origin + '/api/session')).json();
    await stop();
    const pairId = session.pairId, jobId = 'dddddddd-2222-4333-8444-555555555555';
    const progressDir = path.join(dir, 'workspace-control', 'wizard-backups', pairId, 'progress'); fs.mkdirSync(progressDir, { recursive: true });
    const started = new Date(Date.now() - 600000).toISOString(), updated = new Date(Date.now() - 300000).toISOString();
    const raw = { SchemaVersion: 1, Kind: 'WizardBackupProgress', PairId: pairId, OperationId: jobId, AttemptId: jobId, Stage: 'Capture', StageIndex: 1, StageCount: 3, Workload: '還原用工作負載', CurrentFile: 'nested\\last-file.txt', ItemsDone: 2, ItemsTotal: 5, BytesDone: 123456, BytesTotal: null, FailedCount: 0, Terminal: false, Outcome: '', StartedUtc: started, UpdatedUtc: updated, Recent: [{ ItemId: 'a1', Result: 'Succeeded' }, { ItemId: 'a2', Result: 'Succeeded' }], ItemNames: { a1: '第一個項目', a2: '第二個項目' } };
    fs.writeFileSync(path.join(progressDir, jobId + '.json'), JSON.stringify(raw), 'utf8');
    const record = { jobId, action: 'StartBackup', status: 'Running', role: 'Source', workspace: dir, pairId, sessionId: 'old-session', contextId: 'old-context', startedRevision: 1, startedUtc: started, canCancel: true, outputs: [] };
    fs.mkdirSync(path.join(dir, 'console-jobs'), { recursive: true }); fs.writeFileSync(path.join(dir, 'console-jobs', jobId + '.json'), JSON.stringify(record), 'utf8');
    origin = await start();
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 } }); const page = await context.newPage();
    page.on('pageerror', e => errorSink.push('real pageerror: ' + e.message)); page.on('console', m => { const where = m.location() && m.location().url || ''; /* the real handler answers the browser's automatic favicon probe with 403; that is not a page error */ if (m.type() === 'error' && !/\/favicon\.ico$/.test(where)) errorSink.push('real console: ' + m.text() + ' @ ' + where); });
    await page.goto(origin + '/ui/index.html#wizard', { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.progress-card[data-progress-card="wizard"]:not([hidden])', { timeout: 300000 });
    const c = page.locator('.progress-card[data-progress-card="wizard"]'), text = await c.textContent();
    assert.ok(text.includes('2 / 5') && text.includes('還原用工作負載') && text.includes('last-file.txt'), 'the restarted console must serve the last progress by job id: ' + text);
    assert.ok(text.includes('狀態：失敗') && text.includes('已中斷'), 'an interrupted job keeps its progress and says it was interrupted: ' + text);
    assert.ok(text.includes('第一個項目') && text.includes('第二個項目'), 'recent rows show item names');
    assert.ok(text.includes('最後更新'), 'the last update time is shown');
    assert.equal(await c.locator('.progress-cancel').isHidden(), true);
    const api = await (await fetch(origin + '/api/jobs', { headers: { 'X-Wsm-Token': (await (await fetch(origin + '/api/session')).json()).token } })).json();
    const served = api.items.find(j => j.jobId === jobId);
    assert.equal(served.status, 'Interrupted'); assert.equal(served.progress.backup.ItemsDone, 2); assert.equal(served.progress.backup.UpdatedUtc, updated);
    assert.ok(!('ItemNames' in served.progress.backup) && !('OperationId' in served.progress.backup), 'the HTML view is the closed projection');
    await context.close();
  } finally { await stop(); fs.rmSync(dir, { recursive: true, force: true }); }
}
