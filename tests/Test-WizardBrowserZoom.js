const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const artifactDir = path.join(root, 'work', 'wizard-browser-zoom');
const edgePath = process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const files = new Map([
  ['/', path.join(root, 'src/ui/index.html')],
  ['/ui/console.js', path.join(root, 'src/ui/console.js')],
  ['/ui/console.css', path.join(root, 'src/ui/console.css')],
  ['/ui/nonc.js', path.join(root, 'src/ui/nonc.js')]
]);
const server = http.createServer((request, response) => {
  const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
  if (pathname.startsWith('/api/')) {
    api(request, response, pathname);
    return;
  }
  const file = files.get(pathname);
  if (!file) { response.writeHead(404); response.end('Not found'); return; }
  const type = file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8';
  response.writeHead(200, { 'Content-Type': type });
  fs.createReadStream(file).pipe(response);
});

let role = 'Source';
let wizardMode = 'primary';
const pairId = 'browser-zoom-fixture-pair';
const resultJob = {
  jobId: 'browser-zoom-result-job', operationId: 'browser-zoom-result-job', action: 'RestorePreview', status: 'Succeeded',
  role: 'Manager', workspace: 'C:\\fixture\\manager-workspace', pairId, sessionId: 'zoom-session', contextId: 'zoom-context',
  startedRevision: 1, startedUtc: 'fixture-start', completedUtc: 'fixture-end', message: '測試用結果；不是原生作業證據。'
};
function send(response, status, value) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(value));
}
function api(request, response, pathname) {
  const method = request.method || 'GET';
  if (pathname === '/api/session' && method === 'GET') return send(response, 200, {
    token: 'browser-zoom-fixture-token', sessionId: 'zoom-session', contextId: 'zoom-context', hostName: '瀏覽器縮放測試主機',
    role, workspace: 'C:\\fixture\\workspace', pairId, revision: 1, decisionRevision: 0, selectionRevision: 0, dataVersion: 1, principal: 'fixture'
  });
  if (pathname === '/api/context' && method === 'GET') return send(response, 200, {
    roles: ['Source', 'Manager', 'Target'], pairs: [{ pairId, label: '縮放版面測試配對' }], role, pairId,
    contextId: 'zoom-context', revision: 1, decisionRevision: 0, selectionRevision: 0, dataVersion: 1
  });
  if (pathname === '/api/wizard' && method === 'GET') return send(response, 200, {
    kind: 'WizardProjection', intentRequired: false, role, workspaceRole: role, roleMatchesWorkspace: true, pairId,
    state: { CurrentStep: 'start', Mode: 'ItemByItem', AutoContinue: false }, revision: 1, currentStep: 'start',
    groups: [], gates: [], actions: [], missingFields: [], context: { catalogRevision: 1, assistiveRevision: 1, selectionRevision: 0, inventoryRevision: 0 }
  });
  if (pathname === '/api/jobs' && method === 'GET') return send(response, 200, { items: ['waiting', 'result'].includes(wizardMode) ? [Object.assign({}, resultJob, { role, status: wizardMode === 'waiting' ? 'Running' : 'Succeeded' })] : [] });
  if (pathname === '/api/operations' && method === 'POST') return send(response, 503, { code: 'operation_unavailable', message: '受控 fixture 的錯誤狀態。' });
  if (pathname.startsWith('/api/jobs/') && method === 'GET') return send(response, 200, { job: resultJob });
  return send(response, 200, { items: [] });
}

function writeZoomExtension(directory) {
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, 'manifest.json'), JSON.stringify({
    manifest_version: 3,
    name: 'WSM isolated browser zoom verifier',
    version: '1.0.0',
    permissions: ['tabs'],
    host_permissions: ['http://127.0.0.1/*'],
    background: { service_worker: 'background.js' }
  }));
  fs.writeFileSync(path.join(directory, 'background.js'), 'chrome.runtime.onInstalled.addListener(() => {});');
}

async function setRealBrowserZoom(context, page, expectedFactor) {
  let worker = context.serviceWorkers().find(value => value.url().startsWith('chrome-extension://'));
  if (!worker) worker = await context.waitForEvent('serviceworker', { timeout: 10000 });
  const tabId = await worker.evaluate(async targetUrl => {
    const tabs = (await chrome.tabs.query({})).filter(tab => tab.url === targetUrl);
    if (tabs.length !== 1 || tabs[0].id == null) throw new Error(`expected one fixture tab; found ${tabs.length}`);
    await chrome.tabs.setZoom(tabs[0].id, 2.0);
    const actual = await chrome.tabs.getZoom(tabs[0].id);
    if (actual !== 2.0) throw new Error(`Edge extension reports zoom ${actual}, expected 2`);
    return tabs[0].id;
  }, page.url());
  await page.waitForFunction(() => window.innerWidth < 800 && window.devicePixelRatio >= 1.9, null, { timeout: 10000 });
  const actualZoom = await worker.evaluate(async id => chrome.tabs.getZoom(id), tabId);
  assert.equal(actualZoom, expectedFactor, 'Edge tabs.getZoom must confirm the exact browser zoom factor');
  return actualZoom;
}

async function metrics(page) {
  return page.evaluate(() => ({
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    outerWidth: window.outerWidth,
    outerHeight: window.outerHeight,
    clientWidth: document.documentElement.clientWidth,
    documentWidth: document.documentElement.scrollWidth,
    visibleHorizontalEscapes: [...document.querySelectorAll('body *')].map(node => {
      const box = node.getBoundingClientRect();
      return { selector: node.id ? `#${node.id}` : node.className && typeof node.className === 'string' ? `.${node.className.trim().split(/\s+/).join('.')}` : node.tagName.toLowerCase(), left: Math.round(box.left), right: Math.round(box.right) };
    }).filter(box => box.right > window.innerWidth + 1 && box.left < window.innerWidth).slice(0, 12),
    devicePixelRatio: window.devicePixelRatio,
    visualViewportWidth: window.visualViewport && window.visualViewport.width,
    visualViewportScale: window.visualViewport && window.visualViewport.scale,
    zoomEvidence: 'chrome.tabs.setZoom(2) and tabs.getZoom(2)'
  }));
}

async function saveState(page, filename, label) {
  await page.waitForTimeout(100);
  const value = await metrics(page);
  assert.ok(value.documentWidth <= value.clientWidth, `${label} overflows at actual 200% browser zoom: ${JSON.stringify(value)}`);
  const cdp = await page.context().newCDPSession(page);
  try {
    const layout = await cdp.send('Page.getLayoutMetrics');
    const bounds = layout.contentSize;
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width: bounds.width, height: bounds.height, scale: 1 } });
    const bytes = Buffer.from(shot.data, 'base64');
    assert.ok(bytes.readUInt32BE(16) >= value.innerWidth * value.devicePixelRatio - 2, 'Zoom screenshot clipped the physical browser width');
    fs.writeFileSync(path.join(artifactDir, filename), bytes);
    value.screenshotLayout = layout;
  } finally { await cdp.detach(); }
  return value;
}

function removeOwnedTemporaryDirectory(directory, prefix) {
  if (!directory) return;
  const tempRoot = path.resolve(os.tmpdir());
  const resolved = path.resolve(directory);
  const relative = path.relative(tempRoot, resolved);
  assert.ok(relative && relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative), `refusing cleanup outside os.tmpdir(): ${resolved}`);
  assert.ok(path.basename(resolved).startsWith(prefix), `refusing cleanup of a directory without this test's prefix: ${resolved}`);
  fs.rmSync(resolved, { recursive: true, force: true });
}

async function runManagerViewportMatrix(baseUrl) {
  const browser = await chromium.launch({ headless: true, executablePath: edgePath });
  const layoutContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await layoutContext.newPage();
  const widths = [320, 768, 1280, 1920];
  const results = [];
  const controlViolations = [];
  const choiceViolations = [];
  try {
    role = 'Manager';
    for (const state of ['primary', 'waiting', 'error', 'result']) {
      wizardMode = state;
      await page.goto(baseUrl, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.wizard);
      if (state === 'waiting' || state === 'result') {
        await page.evaluate(() => window.WsmConsole.navigate('jobs'));
        await page.waitForFunction(() => document.querySelector('#job-list .job-card'));
        assert.match(await page.locator('#job-list').innerText(), state === 'waiting' ? /Running|執行中/ : /Succeeded|成功|已完成/);
      } else if (state === 'error') {
        await page.evaluate(() => window.WsmConsole.startDeveloperProbe());
        await page.waitForFunction(() => !document.querySelector('#error-summary').hidden);
      } else {
        await page.evaluate(() => window.WsmConsole.navigate('wizard'));
        assert.equal(await page.locator('#view-wizard').isVisible(), true);
      }
      for (const width of widths) {
        await page.setViewportSize({ width, height: 900 });
        const sample = await page.evaluate(() => {
          const controls = [...document.querySelectorAll('button,input:not([type="radio"]):not([type="checkbox"]),select,textarea,[role="button"]')]
            .filter(node => node.getClientRects().length && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[hidden],details:not([open])'))
            .map(node => {
              const box = node.getBoundingClientRect();
              const name = node.getAttribute('aria-label') || node.id || node.getAttribute('name') || node.getAttribute('placeholder') || node.innerText && node.innerText.trim().replace(/\s+/g, ' ').slice(0, 80) || node.className && typeof node.className === 'string' && node.className || node.tagName.toLowerCase();
              return { selector: node.id ? `#${node.id}` : `.${String(node.className || node.tagName.toLowerCase()).trim().split(/\s+/).join('.')}`, name, height: Math.round(box.height * 100) / 100, width: Math.round(box.width * 100) / 100, font: parseFloat(getComputedStyle(node).fontSize) };
            });
          const choiceTargets = [...document.querySelectorAll('input[type="radio"],input[type="checkbox"]')]
            .filter(node => node.getClientRects().length && getComputedStyle(node).visibility !== 'hidden' && !node.closest('[hidden],details:not([open])'))
            .map(node => {
              const label = node.closest('label') || (node.id && document.querySelector(`label[for="${CSS.escape(node.id)}"]`));
              const box = label ? label.getBoundingClientRect() : node.getBoundingClientRect();
              return { selector: label && label.className ? `label.${String(label.className).trim().split(/\s+/).join('.')}` : node.id ? `#${node.id}` : 'input[type=radio|checkbox]', width: Math.round(box.width * 100) / 100, height: Math.round(box.height * 100) / 100 };
            });
          const primary = document.querySelector('#wizard-next');
          return {
            viewport: window.innerWidth,
            document: document.documentElement.scrollWidth,
            dpr: window.devicePixelRatio,
            bodyFont: parseFloat(getComputedStyle(document.body).fontSize),
            minControlHeight: controls.length ? Math.min(...controls.map(value => value.height)) : null,
            minControlFont: controls.length ? Math.min(...controls.map(value => value.font)) : null,
            controls,
            shortControls: controls.filter(value => value.height < 48),
            choiceTargets,
            controlCount: controls.length,
            primaryActionHeight: primary && primary.getClientRects().length ? primary.getBoundingClientRect().height : null,
            primaryActionFont: primary && primary.getClientRects().length ? parseFloat(getComputedStyle(primary).fontSize) : null
          };
        });
        assert.equal(sample.viewport, width, `separate 100% browser context did not use its requested CSS width: ${JSON.stringify(sample)}`);
        assert.equal(sample.dpr, 1, `Manager layout matrix must remain at browser zoom 100%: ${JSON.stringify(sample)}`);
        assert.ok(sample.document <= sample.viewport, `Manager ${state} page overflows at ${width}px: ${JSON.stringify(sample)}`);
        assert.ok(sample.bodyFont >= 16, `Manager ${state} body font is too small at ${width}px: ${JSON.stringify(sample)}`);
        assert.ok(sample.controlCount > 0, `Manager ${state} should expose controls at ${width}px`);
        if (sample.shortControls.length) controlViolations.push({ state, width, controls: sample.shortControls });
        const shortChoices = sample.choiceTargets.filter(value => value.width < 48 || value.height < 48);
        if (shortChoices.length) choiceViolations.push({ state, width, controls: shortChoices });
        assert.ok(sample.primaryActionHeight == null || sample.primaryActionHeight >= 48, `Manager ${state} primary wizard action is below 48px at ${width}px: ${JSON.stringify(sample)}`);
        assert.ok(sample.primaryActionFont == null || sample.primaryActionFont >= 16, `Manager ${state} primary wizard action font is too small at ${width}px: ${JSON.stringify(sample)}`);
        results.push({ state, browserZoom: 1, width, ...sample });
        if (width === 320 || width === 1280) {
          await page.screenshot({ path: path.join(artifactDir, `manager-${state}-${width}-100.png`), fullPage: true });
        }
      }
    }
    assert.equal(controlViolations.length, 0, `Manager has visible editable/button controls below 48px: ${JSON.stringify(controlViolations)}`);
    assert.equal(choiceViolations.length, 0, `Manager has checkbox/radio label targets below 48px: ${JSON.stringify(choiceViolations)}`);
    return results;
  } finally {
    await layoutContext.close();
    await browser.close();
  }
}

async function renderNonCLongPathPreview(page) {
  const longPath = 'D:\\核准的業務資料\\' + '共用設定與資料夾名稱_很長的路徑_'.repeat(9);
  const fixture = await page.evaluate(pathValue => {
    const host = document.querySelector('.wizard-nonc-widget-host') || (() => {
      const node = document.createElement('section');
      node.className = 'wizard-nonc-widget-host';
      document.querySelector('#wizard-content').appendChild(node);
      return node;
    })();
    const hash = 'a'.repeat(64);
    const data = {
      HasNonC: true,
      CurrentPlan: { hash },
      ProofAllowed: true,
      Preparation: {
        Status: 'Ready',
        Entries: [{ ItemId: 'nonc-long-path-item', Name: '共用資料夾設定', SourcePath: pathValue, TargetPath: pathValue }]
      }
    };
    const api = {
      context: { role: 'Manager', pairId: 'browser-zoom-fixture-pair', workspace: 'C:\\fixture\\workspace', contextId: 'zoom-context', dataVersion: 1 },
      projection: data,
      submit(action, args) {
        if (action !== 'NonCProofPreview') throw new Error(`unexpected fixture action: ${action}`);
        return Promise.resolve({
          Status: 'Ready', PreviewId: 'fixture-preview-id', SourceHost: 'SOURCE-01', TargetHost: 'TARGET-01',
          ReviewedTargetRoots: [pathValue], TargetStateDirectory: 'C:\\fixture\\workspace\\pairs', TargetStateShareName: 'state$',
          ReviewedTargetRootMappings: [{ LocalPath: pathValue, UNCPath: `\\\\TARGET-01\\data$\\${pathValue.split('\\\\').pop()}`, ShareName: 'data$' }],
          Shares: [{ Name: 'data$', LocalPath: pathValue }], Materials: [{ ShareName: 'data$', SHA256: hash }]
        });
      },
      refresh() { return Promise.resolve(data); },
      markDirty() {}
    };
    window.WsmNonCWizard.clear(host);
    window.WsmNonCWizard.render(host, api);
    return { pathValue, hostReady: !!host.querySelector('.nonc-form') };
  }, longPath);
  assert.equal(fixture.hostReady, true, 'actual WsmNonCWizard should render the Manager proof-preview form');
  const proofForm = page.locator('.wizard-nonc-widget-host .nonc-form').filter({ has: page.getByLabel('獨立收到的交接資料夾') });
  await proofForm.getByLabel('獨立收到的交接資料夾').fill('C:\\fixture\\received-proof');
  await proofForm.getByLabel('透過另一可信管道收到的交接清單 SHA-256').fill('b'.repeat(64));
  await proofForm.getByLabel('我已從交接資料夾以外的可信來源核對這個指紋').check();
  await proofForm.getByRole('button', { name: '預覽證明交接' }).click();
  await page.waitForSelector('[data-nonc-proof-preview]');
  const previewText = await page.locator('[data-nonc-proof-preview]').innerText();
  assert.match(previewText, /證明交接預覽/);
  assert.match(previewText, /共用資料夾|data\$/);
  assert.match(previewText, /很長的路徑/);
  const value = await metrics(page);
  assert.ok(value.documentWidth <= value.clientWidth, `long NonC preview overflows at actual 200% zoom: ${JSON.stringify(value)}`);
  await page.screenshot({ path: path.join(artifactDir, 'manager-nonc-long-shared-preview-200.png'), fullPage: true });
  return value;
}

(async () => {
  let context;
  let layoutContext;
  let extensionDir;
  let profileDir;
  let initialZoomMetrics;
  let noncPreviewMetrics;
  let managerMatrix = [];
  try {
    assert.ok(fs.existsSync(edgePath), `Edge executable not found: ${edgePath}`);
    fs.mkdirSync(artifactDir, { recursive: true });
    extensionDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-browser-zoom-extension-'));
    profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-browser-zoom-profile-'));
    writeZoomExtension(extensionDir);
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    const baseUrl = `http://127.0.0.1:${server.address().port}/`;
    context = await chromium.launchPersistentContext(profileDir, {
      headless: true,
      executablePath: edgePath,
      viewport: null,
      args: [`--disable-extensions-except=${extensionDir}`, `--load-extension=${extensionDir}`, '--window-size=1280,1000'],
      javaScriptEnabled: true
    });
    const page = context.pages()[0] || await context.newPage();
    const pageErrors = [];
    const served = new Set();
    page.on('pageerror', error => pageErrors.push(error.message));
    page.on('response', response => { if (response.ok()) served.add(new URL(response.url()).pathname); });
    await page.goto(baseUrl, { waitUntil: 'networkidle' });
    await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.wizard);
    for (const required of ['/ui/console.js', '/ui/console.css', '/ui/nonc.js']) assert.ok(served.has(required), `formal UI asset was not served: ${required}`);
    const baseline = await metrics(page);
    assert.equal(baseline.outerWidth, 1280, `physical browser window should be 1280px before zoom: ${JSON.stringify(baseline)}`);
    assert.ok(baseline.innerWidth >= 1200 && baseline.innerWidth <= 1280, `baseline CSS viewport should reflect the 1280px physical browser window: ${JSON.stringify(baseline)}`);
    assert.ok(baseline.devicePixelRatio >= 0.9 && baseline.devicePixelRatio <= 1.1, `unexpected baseline DPR: ${JSON.stringify(baseline)}`);

    const zoom = await setRealBrowserZoom(context, page, 2.0);
    initialZoomMetrics = await metrics(page);
    assert.equal(zoom, 2.0);
    assert.ok(Math.abs(initialZoomMetrics.innerWidth * 2 - baseline.innerWidth) <= 8, `actual zoom did not halve the baseline CSS viewport: ${JSON.stringify({ baseline, zoomed: initialZoomMetrics })}`);
    assert.ok(initialZoomMetrics.devicePixelRatio >= 1.9, `actual Edge browser zoom did not increase DPR: ${JSON.stringify(initialZoomMetrics)}`);
    assert.equal(initialZoomMetrics.outerWidth, 1280, `browser window changed size to simulate zoom: ${JSON.stringify(initialZoomMetrics)}`);

    await page.evaluate(() => window.WsmConsole.navigate('wizard'));
    const sourcePrimary = await saveState(page, 'source-primary-200.png', 'Source primary screen');
    assert.match(await page.locator('#wizard-content').innerText(), /這台電腦|用途|操作|開始/);

    role = 'Manager';
    wizardMode = 'primary';
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.session && window.WsmConsole.state.session.role === 'Manager');
    noncPreviewMetrics = await renderNonCLongPathPreview(page);
    await page.evaluate(() => window.WsmConsole.startDeveloperProbe());
    await page.waitForFunction(() => !document.querySelector('#error-summary').hidden);
    const managerError = await saveState(page, 'manager-error-200.png', 'Manager error screen');
    assert.match(await page.locator('#error-summary').innerText(), /環境探測提交結果尚未確認/);

    role = 'Target';
    wizardMode = 'result';
    await page.reload({ waitUntil: 'networkidle' });
    await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.session && window.WsmConsole.state.session.role === 'Target');
    await page.evaluate(() => window.WsmConsole.navigate('jobs'));
    await page.waitForFunction(() => document.querySelector('#job-list .job-card'));
    const targetResult = await saveState(page, 'target-result-200.png', 'Target result screen');
    assert.match(await page.locator('#job-list').innerText(), /成功|RestorePreview|browser-zoom-result-job/);
    assert.deepEqual(pageErrors, [], `formal UI threw browser errors: ${pageErrors.join('; ')}`);
    managerMatrix = await runManagerViewportMatrix(baseUrl);

    const evidence = {
      verification: 'Actual Edge tab zoom via isolated Manifest V3 extension chrome.tabs.setZoom/getZoom; no CSS zoom, deviceScaleFactor, or viewport emulation.',
      apiFixture: true,
      nativeP0Evidence: false,
      physicalWindowWidth: 1280,
      browserZoomFactor: zoom,
      baseline,
      zoomedBaseline: initialZoomMetrics,
      managerNonCLongSharedPreview: noncPreviewMetrics,
      separateBrowserZoom100PercentManagerLayoutMatrix: managerMatrix,
      screenshots: {
        sourcePrimary: { file: 'source-primary-200.png', metrics: sourcePrimary },
        managerError: { file: 'manager-error-200.png', metrics: managerError },
        targetResult: { file: 'target-result-200.png', metrics: targetResult }
      }
    };
    fs.writeFileSync(path.join(artifactDir, 'metrics.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    console.log(`Genuine Edge 200% browser-zoom UI fixture passed. Evidence: ${artifactDir}; API fixture only, not P0 native evidence.`);
  } finally {
    if (layoutContext) await layoutContext.close();
    if (context) await context.close();
    if (server.listening) {
      if (server.closeAllConnections) server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    }
    if (extensionDir && fs.existsSync(extensionDir)) removeOwnedTemporaryDirectory(extensionDir, 'wsm-browser-zoom-extension-');
    if (profileDir && fs.existsSync(profileDir)) removeOwnedTemporaryDirectory(profileDir, 'wsm-browser-zoom-profile-');
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
