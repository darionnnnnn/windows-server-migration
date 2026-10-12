const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-native-html-browser-'));
let child, browser, origin;
const logs = [], requests = [], responses = new Map(), pageErrors = [];

async function startServer() {
  const ready = path.join(root, 'ready.json'), stop = path.join(root, 'stop');
  child = spawn('powershell.exe', ['-NoProfile', '-File', path.join(__dirname, 'Start-HtmlTestServer.ps1'), '-Workspace', root, '-ReadyPath', ready, '-StopFile', stop, '-Seed'], {
    windowsHide: true,
    env: { ...process.env, PSModulePath: path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') }
  });
  child.stdout.on('data', data => logs.push(data.toString()));
  child.stderr.on('data', data => logs.push(data.toString()));
  const deadline = Date.now() + 120000;
  while (!fs.existsSync(ready)) {
    if (Date.now() > deadline || child.exitCode !== null) throw new Error(logs.join('') || 'Native console did not start.');
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  origin = JSON.parse(fs.readFileSync(ready, 'utf8')).Url.replace(/\/$/, '');
}

async function stopServer() {
  if (!child || child.exitCode !== null) return;
  fs.writeFileSync(path.join(root, 'stop'), 'stop');
  await new Promise(resolve => {
    const timer = setTimeout(() => { child.kill(); resolve(); }, 6000);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
  });
}

async function verifyInjectedViewFailure(browser, origin, fault, expectedText, timeout = 20000) {
  const page = await browser.newPage();
  await page.route('**/api/view*', async route => {
    if (new URL(route.request().url()).searchParams.get('action') !== 'inventory') return route.continue();
    await fault(route);
  });
  await page.goto(origin + '/ui/index.html#inventory', { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(expected => {
    const box = document.getElementById('error-summary');
    return box && !box.hidden && box.textContent.includes(expected);
  }, expectedText, { timeout });
  const errorText = await page.locator('#error-summary').textContent();
  assert.match(errorText, /識別碼 client-[a-z0-9-]+/i, `failure did not display a trace identifier: ${errorText}`);
  await page.close();
}

(async () => {
  try {
    await startServer();
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    page.on('request', request => requests.push({ method: request.method(), url: request.url() }));
    const captureResponse = response => {
      const url = new URL(response.url());
      if (url.origin === origin && (url.pathname.startsWith('/ui/') || url.pathname === '/api/session' || url.pathname === '/api/view')) {
        responses.set(url.pathname + url.search, { status: response.status(), bodyPromise: response.body() });
      }
    };
    page.on('response', captureResponse);
    page.on('pageerror', error => pageErrors.push(error.message));
    await page.goto(origin + '/ui/index.html#inventory', { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.inventory.length === 125, null, { timeout: 30000 });

    const requiredRoutes = ['/ui/index.html', '/ui/console.js', '/ui/console.css', '/api/session'];
    for (const route of requiredRoutes) assert.ok(responses.has(route), `real native handler did not serve ${route}`);
    for (const route of requiredRoutes) responses.get(route).body = await responses.get(route).bodyPromise;
    const session = JSON.parse(responses.get('/api/session').body.toString('utf8'));
    for (const route of ['/ui/index.html', '/ui/console.js', '/ui/console.css']) {
      const record = responses.get(route);
      assert.ok(record && record.status === 200, `native browser did not load ${route}`);
      const hash = crypto.createHash('sha256').update(record.body).digest('hex');
      assert.equal(hash, session.assetHashes[route], `native response hash differs from the session for ${route}`);
    }
    const inventoryResponse = [...responses.entries()].find(([key]) => key.startsWith('/api/view?action=inventory'));
    assert.ok(inventoryResponse, 'native browser did not request inventory through the real session API');
    inventoryResponse[1].body = await inventoryResponse[1].bodyPromise;
    const inventoryBody = JSON.parse(inventoryResponse[1].body.toString('utf8'));
    assert.equal(inventoryBody.items.length, 125);
    assert.equal(inventoryBody.viewContext.pairId, session.pairId);

    const submitPromise = page.waitForResponse(response => new URL(response.url()).pathname === '/api/operations' && response.request().method() === 'POST');
    await page.locator('#save-selection').click();
    const submitResponse = await submitPromise;
    assert.equal(submitResponse.status(), 200);
    const saved = await submitResponse.json();
    assert.equal(saved.status, 'Saved');
    assert.ok(saved.jobId);
    await page.getByText('已保存目前選取與未選原因。', { exact: false }).waitFor({ state: 'visible', timeout: 10000 });
    assert.equal(requests.filter(request => request.url.includes('/api/operations') && request.method === 'POST').length, 1, 'safe selection save was sent once');
    const guidePage = await browser.newPage();
    guidePage.on('response', captureResponse);
    await guidePage.goto(origin + '/ui/guide.html', { waitUntil: 'domcontentloaded' });
    const guideRecord = responses.get('/ui/guide.html');
    assert.ok(guideRecord && guideRecord.status === 200, 'real browser did not load guide.html through the native handler');
    guideRecord.body = await guideRecord.bodyPromise;
    assert.equal(crypto.createHash('sha256').update(guideRecord.body).digest('hex'), session.assetHashes['/ui/guide.html']);
    assert.deepEqual(pageErrors, []);
    await verifyInjectedViewFailure(browser, origin, route => route.fulfill({ status: 200, contentType: 'text/html', body: '<html>proxy error</html>' }), '回傳的內容格式無法讀取');
    await verifyInjectedViewFailure(browser, origin, route => route.abort('connectionreset'), '無法連線本機服務');
    await verifyInjectedViewFailure(browser, origin, async route => { await new Promise(resolve => setTimeout(resolve, 18000)); try { await route.fulfill({ status: 200, contentType: 'application/json', body: '{}' }); } catch (_) {} }, '讀取逾時', 20000);
    const expiredPage = await browser.newPage();
    await expiredPage.route('**/api/context', route => route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ code: 'invalid_token', message: 'session expired' }) }));
    await expiredPage.goto(origin + '/ui/index.html', { waitUntil: 'domcontentloaded' });
    await expiredPage.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.token === null && !document.getElementById('error-summary').hidden, null, { timeout: 10000 });
    assert.match(await expiredPage.locator('#error-summary').textContent(), /工作階段已失效/);
    await expiredPage.close();
    process.stdout.write('PASS: Edge loaded the real PowerShell loopback handler, verified native asset hashes and 125-item inventory/session context, saved a reversible selection once, and displayed identified errors for injected non-JSON, connection reset, timeout, and expired-session responses. Fault cases use explicit Playwright response injection.\n');
  } finally {
    if (browser) await browser.close();
    await stopServer();
    fs.rmSync(root, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
