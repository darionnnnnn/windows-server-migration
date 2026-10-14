const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const files = new Map([
  ['/', path.join(root, 'src/ui/index.html')],
  ['/ui/console.js', path.join(root, 'src/ui/console.js')],
  ['/ui/console.css', path.join(root, 'src/ui/console.css')]
]);
const groups = [];
for (let index = 0; index < 200; index++) {
  const id = `ui-item-${String(index).padStart(3, '0')}`;
  const group = {
    groupId: `stable-group-${String(index).padStart(3, '0')}`,
    kind: 'service', label: '服務', name: index === 0 ? '共用服務資源' : index === 1 ? '不完整服務' : `服務 ${index}`,
    itemIds: [id], affectedItemIds: [id], selected: index !== 0, confirmed: false,
    selectionState: index === 0 ? 'Excluded' : 'Included', children: [{ itemId: id, name: index === 0 ? '共用服務資源' : index === 1 ? '不完整服務' : `服務 ${index}`, kind: 'Service', category: 'Web', source: `C:\\fixture\\service-${index}.exe`, status: index === 1 ? 'Partial' : 'Success', executionStatus: 'NotObserved', supported: index !== 1, selected: index !== 0, confirmed: false, dependencies: [] }],
    dependencies: [], dependencyWarnings: [], supported: index !== 1,
    unsupportedReason: index === 1 ? '核心標記此項目需要人工處置。' : ''
  };
  if (index === 0) {
    group.sharedImpact = true;
    group.sharedImpactReason = '此共用資源也影響其他搬移項目。';
    group.affectedItemIds = [id, 'ui-item-010', 'ui-item-011'];
    group.dependencyWarnings = ['必要相依項目未出現在目前盤點中，必須先確認完整資料。', '相依項目形成循環，必須先確認處理順序。'];
    group.children[0].dependencies = [{ itemId: 'ui-item-010' }];
  }
  if (index === 10) group.name = group.children[0].name = '消費服務甲';
  if (index === 11) group.name = group.children[0].name = '消費服務乙';
  groups.push(group);
}

const projection = {
  kind: 'WizardProjection', role: 'Manager', workspaceRole: 'Manager', roleMatchesWorkspace: true,
  pairId: 'pair-grouping-ui', pairName: '舊主機 → 新主機', currentStep: 'review', nextStep: 'review',
  mode: 'ItemByItem', revision: 21, currentGroupId: groups[0].groupId, reviewGroupIndex: 0,
  groups, gates: [], results: { hasAny: false }, context: { catalogRevision: 7, selectionRevision: 4, assistiveRevision: 3 },
  actions: [], readiness: { roleReady: true }
};

const server = http.createServer((request, response) => {
  const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
  const file = files.get(pathname);
  if (file) {
    response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' });
    fs.createReadStream(file).pipe(response);
    return;
  }
  const json = body => { response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(body)); };
  if (pathname === '/api/session') return json({ token: 'fixture-token', sessionId: 'grouping-session', contextId: 'grouping-context', hostName: 'manager-fixture', role: 'Manager', workspace: 'C:\\fixture\\manager', pairId: projection.pairId, revision: 21, decisionRevision: 7, selectionRevision: 4, dataVersion: 1, principal: 'fixture-user' });
  if (pathname === '/api/context') return json({ roles: ['Manager'], pairs: [{ pairId: projection.pairId, label: projection.pairName }], role: 'Manager', pairId: projection.pairId, contextId: 'grouping-context', revision: 21, decisionRevision: 7, selectionRevision: 4, dataVersion: 1 });
  if (pathname === '/api/wizard' && request.method === 'GET') return json(projection);
  if (pathname === '/api/view') return json({});
  if (pathname === '/api/jobs') return json({ items: [] });
  response.writeHead(404, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ code: 'fixture_missing', message: `${request.method} ${pathname}` }));
});

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(40000 + Math.floor(Math.random() * 12000), '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const pageErrors = [];
    page.on('pageerror', error => pageErrors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/#wizard`, { waitUntil: 'networkidle' });
    await page.waitForFunction(() => window.WsmConsole?.state?.wizard?.currentStep === 'review');

    const firstGroup = page.locator('.wizard-item-title');
    assert.equal(await firstGroup.innerText(), '共用服務資源');
    assert.equal(await page.locator('#wizard-content').getAttribute('data-current-group-id'), groups[0].groupId, 'the reviewed group must stay bound to the stable helper identity');
    assert.match(await page.locator('.wizard-group-warning').innerText(), /未出現在目前盤點|形成循環/);
    const sharedText = await page.locator('.wizard-group-shared-impact').innerText();
    assert.match(sharedText, /消費服務甲/);
    assert.match(sharedText, /消費服務乙/);
    assert.equal(await page.locator('input[name="wizard-group-choice"][value="exclude"]').isChecked(), true, 'item-by-item rendering must retain the server selection');

    await page.evaluate(() => {
      const state = window.WsmConsole.state;
      state.wizard = Object.assign({}, state.wizard, { mode: 'Automatic', state: Object.assign({}, state.wizard.state, { Mode: 'Automatic' }) });
      window.WsmConsole.renderWizard(state.wizard);
    });
    assert.equal(await page.locator('.wizard-group-row').count(), 200, 'automatic mode must render every projected group, including incomplete items');
    assert.equal(await page.locator('.wizard-group-row[data-group-id="stable-group-001"]').count(), 1, 'unsupported/partial groups remain visible');
    assert.match(await page.locator('.wizard-group-row[data-group-id="stable-group-001"]').innerText(), /人工處置|部分資料/);
    assert.match(await page.locator('.wizard-group-row[data-group-id="stable-group-002"]').innerText(), /待確認 · 預設加入/, 'a newly projected item can be selected by default while still remaining unreviewed');
    assert.equal(await page.locator('.wizard-group-warning').count(), 1, 'dependency warnings must remain attached to the owning stable group');
    assert.match(await page.locator('.wizard-group-shared-impact').innerText(), /消費服務甲.*消費服務乙/);
    assert.equal(await page.evaluate(() => window.WsmConsole.state.wizard.groups.length), 200, 'a rendered mode change must preserve the complete server-projected collection');

    await page.evaluate(() => {
      const state = window.WsmConsole.state;
      state.wizard = Object.assign({}, state.wizard, { mode: 'ItemByItem', state: Object.assign({}, state.wizard.state, { Mode: 'ItemByItem' }) });
      window.WsmConsole.renderWizard(state.wizard);
    });
    assert.equal(await page.locator('#wizard-content').getAttribute('data-current-group-id'), groups[0].groupId, 'switching back must keep the helper selected group identity');
    assert.equal(await page.locator('input[name="wizard-group-choice"][value="exclude"]').isChecked(), true, 'mode rendering must not alter the selection decision');

    await page.setViewportSize({ width: 375, height: 812 });
    await page.evaluate(() => {
      const state = window.WsmConsole.state;
      state.wizard = Object.assign({}, state.wizard, { mode: 'Automatic', state: Object.assign({}, state.wizard.state, { Mode: 'Automatic' }) });
      window.WsmConsole.renderWizard(state.wizard);
    });
    const mobile = await page.evaluate(() => ({ viewport: window.innerWidth, document: document.documentElement.scrollWidth, rows: [...document.querySelectorAll('.wizard-group-row')].length, widestRow: Math.max(...[...document.querySelectorAll('.wizard-group-row')].map(row => Math.ceil(row.getBoundingClientRect().width))) }));
    assert.equal(mobile.rows, 200);
    assert.ok(mobile.document <= mobile.viewport + 1, `mobile grouping layout must not overflow the page: ${JSON.stringify(mobile)}`);
    assert.ok(mobile.widestRow <= mobile.viewport + 1, `group cards must fit the narrow viewport: ${JSON.stringify(mobile)}`);
    assert.deepEqual(pageErrors, []);
    await page.close();
    process.stdout.write('PASS: browser fixture renders helper dependency warnings and every shared consumer impact in the existing review views; mode changes preserve all 200 stable groups and selections; unsupported/partial groups remain visible; mobile cards fit a 375px viewport. The 200-group projection is a browser fixture, not a core grouping/persistence test.\n');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
