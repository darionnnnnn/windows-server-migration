// N9c2 / R7-07：路徑解析依據顯示的真實瀏覽器測試（Playwright + Edge）。
// 資料由真實的 PowerShell 投影函式產生（tests/New-PathResolutionFixture.ps1）；API 為固定替身，前端為真實 src/ui。
// 涵蓋：審閱畫面逐一檢視四種依據（原字串／解析結果／依據／原因／人工處置下一步）、C2 軟體處置審閱的未解析消費者路徑、
// 路徑視為資料（不產生元素）、機密變數只顯示名稱、390px 無橫向溢位、零 console 錯誤。
// Q2：UNC 路徑的責任標示（沿用既有外部共享／另行遷移）也在審閱畫面逐一驗證（含標記字元的路徑）。
const assert = require('node:assert/strict'), fs = require('node:fs'), http = require('node:http'), os = require('node:os'), path = require('node:path'), { execFileSync } = require('node:child_process');
const runtimePath = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtimePath, 'playwright'));
const root = path.resolve(__dirname, '..'), screens = process.env.WSM_N9C2_SCREENS || path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });
const fixturePath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-n9c2-')), 'fixture.json');
execFileSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, 'New-PathResolutionFixture.ps1'), fixturePath], { stdio: ['ignore', 'pipe', 'pipe'] });
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
const groups = fixture.groups.map(group => Object.assign({}, group, { confirmed: false }));
assert.equal(groups.length, 6, 'the projection produced one group per candidate');
const hex = ch => ch.repeat(64), pairId = 'n9c2-pair', contextId = 'n9c2-context';
const assets = new Map([['/', path.join(root, 'src/ui/index.html')], ['/ui/console.js', path.join(root, 'src/ui/console.js')], ['/ui/console.css', path.join(root, 'src/ui/console.css')], ['/ui/nonc.js', path.join(root, 'src/ui/nonc.js')]]);
let step = 'review', currentGroupId = groups[0].groupId, servedGroups = groups;
const wizardBody = () => ({ kind: 'WizardProjection', role: 'Manager', workspaceRole: 'Manager', roleMatchesWorkspace: true, pairId, pairName: 'Source to Target', currentStep: step, nextStep: step, mode: 'ItemByItem', revision: 3, currentGroupId, reviewGroupIndex: 0, groups: servedGroups, gates: [], results: { hasAny: false }, context: { catalogRevision: 3, selectionRevision: 1, assistiveRevision: 1 }, actions: [], readiness: { roleReady: true } });
const software = { SoftwareId: 'sw-a', Name: '訂單系統執行階段', Publisher: 'Fixture Corp', Version: '1.0', Architecture: 'x64', Scope: 'Machine', SID: '', RegistryView: 'Registry64', Location: 'D:\\Apps', SourceKind: 'Registry', CaptureStatus: 'Captured', ConsumerItems: [], SpecialProduct: false, AllowedDispositions: ['Reinstall', 'External', 'NotNeeded', 'Unknown'], DecisionState: 'Unreviewed', DecisionSoftwareHash: '', Disposition: '', Owner: '', Reason: '', Evidence: '' };
const c2Body = () => ({ Kind: 'AssistiveSoftwareDispositionReview', Status: 'Previewed', PairId: pairId, DecisionRevision: 10, InventoryHash: hex('1'), SoftwareCatalogHash: hex('8'), Rows: [software], Coverage: [{ Probe: 'ConsumerPathResolution', Scope: 'ScheduledTask', SID: '', View: 'Inventory', Status: 'Partial', EvidenceKind: 'SourceContextPath', Count: 0, ErrorKind: 'SourcePathUnresolved', Budget: { MaxEntries: 100 } }], TrustedSoftwareRoots: { Status: 'Success', Count: 0, Diagnostics: [] }, ReadinessProof: false, AuthoritativeApproval: false, PreviewHash: hex('9'), PathResolutions: fixture.c2PathResolutions, viewRevision: 3 });
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1'), asset = assets.get(url.pathname);
  if (asset) { res.writeHead(200, { 'Content-Type': asset.endsWith('.js') ? 'application/javascript' : asset.endsWith('.css') ? 'text/css' : 'text/html' }); fs.createReadStream(asset).pipe(res); return; }
  if (url.pathname === '/favicon.ico') { res.writeHead(204); res.end(); return; }
  let raw = ''; req.on('data', c => raw += c);
  req.on('end', () => {
    const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (url.pathname === '/api/session') return send(200, { token: 'fixture', contextId, sessionId: 's', hostName: 'Manager', role: 'Manager', workspace: 'C:\\fixture\\manager', pairId, revision: 3, decisionRevision: 10, selectionRevision: 1, dataVersion: 1, principal: 'fixture-user' });
    if (url.pathname === '/api/context') return send(200, { roles: ['Manager'], pairs: [{ pairId, label: 'Source to Target' }], role: 'Manager', pairId, contextId, revision: 3, decisionRevision: 10, selectionRevision: 1, dataVersion: 1 });
    if (url.pathname === '/api/wizard' && req.method === 'GET') return send(200, wizardBody());
    if (url.pathname === '/api/wizard/nonc') return send(200, { Kind: 'WizardNonCProjection', Role: 'Manager', PairId: pairId, ContextId: contextId, HasNonC: false });
    if (url.pathname === '/api/wizard/runtime') return send(200, { Kind: 'WizardRuntimeProjection', Role: 'Manager', PairId: pairId, viewContext: { revision: 3 }, status: 'Idle', actions: [], runtime: {} });
    if (url.pathname === '/api/jobs') return send(200, { items: [] });
    if (url.pathname === '/api/view' && req.method === 'POST') { const body = JSON.parse(raw); if (body.action === 'SoftwareDispositionReview') return send(200, c2Body()); return send(404, { code: 'not_found' }); }
    return send(404, { code: 'not_found', route: url.pathname });
  });
});

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const base = `http://127.0.0.1:${server.address().port}/#wizard`, errors = [];
    async function openPage(width) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      page.on('pageerror', e => errors.push('pageerror: ' + e.message)); page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
      await page.goto(base, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => window.WsmConsole?.state?.wizard?.currentStep);
      return page;
    }
    const noOverflow = async (page, what) => assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal overflow: ${what}`);
    const resolutionOf = page => page.evaluate(() => { const box = document.querySelector('.wizard-file-details .path-resolution'); if (!box) return null; const out = { unresolved: box.classList.contains('is-unresolved'), basis: box.dataset.basis, state: box.querySelector('.path-resolution-state').textContent }; box.querySelectorAll('dd').forEach(dd => { out[dd.dataset.field] = dd.textContent; }); return out; });
    async function showGroup(page, index) {
      await page.evaluate(i => { const s = window.WsmConsole.state; s.wizard = Object.assign({}, s.wizard, { currentGroupId: s.wizard.groups[i].groupId }); window.WsmConsole.renderWizard(s.wizard); }, index);
      await page.locator('.wizard-file-details > summary').click();
    }

    // ===== 1. 審閱畫面：四種依據各一例（群組順序依核心排序，因此以原字串找出對應群組）
    const page = await openPage(390);
    const findIndex = original => groups.findIndex(group => (group.children[0].fileDetails[0].resolution || {}).original === original);
    const cases = [
      { original: '%SystemDrive%\\Data', basis: 'Machine', label: '機器層', unresolved: false, result: 'C:\\Data' },
      { original: '%APPDATA%\\Svc', basis: 'ProfileDerived', label: '帳號設定檔推導', unresolved: false, result: 'C:\\Users\\svc\\AppData\\Roaming\\Svc' },
      { original: 'D:\\Literal\\Path', basis: 'Literal', label: '字面路徑', unresolved: false, result: 'D:\\Literal\\Path' },
      { original: '%USERPROFILE%\\<b>tool</b>\\app.exe', basis: 'Unresolved', label: '未解析', unresolved: true, result: '未解析', next: '在新機確認該帳號的設定檔路徑' }
    ];
    for (const item of cases) {
      const index = findIndex(item.original); assert.ok(index >= 0, `fixture has ${item.original}`);
      await showGroup(page, index);
      const shown = await resolutionOf(page);
      assert.ok(shown, `resolution block rendered for ${item.basis}`);
      assert.equal(shown['原字串'], item.original, `original string shown (${item.basis})`);
      assert.equal(shown['解析結果'], item.result, `resolved result shown (${item.basis})`);
      assert.equal(shown['解析依據'], item.label, `basis label shown (${item.basis})`);
      assert.equal(shown.unresolved, item.unresolved, `unresolved marker (${item.basis})`);
      assert.match(shown.state, item.unresolved ? /^⚠ 未解析：需人工處置$/ : /^✓ 已解析$/, `state is text plus icon (${item.basis})`);
      if (item.unresolved) { assert.ok(shown['未解析的原因'], 'reason shown'); assert.equal(shown['人工處置下一步'], item.next, 'reason-specific next step shown'); }
      else { assert.equal(shown['人工處置下一步'], undefined, 'resolved path has no manual-disposition row'); assert.equal(shown['未解析的原因'], undefined); }
      await noOverflow(page, item.basis);
      if (item.basis === 'Unresolved') {
        assert.equal(await page.locator('.wizard-file-details b').count(), 0, 'path text must not create elements');
        await page.locator('.path-resolution.is-unresolved').first().scrollIntoViewIfNeeded();
        await page.screenshot({ path: path.join(screens, 'n9c2-review-unresolved-390.png'), fullPage: true });
      } else if (item.basis === 'ProfileDerived') {
        await page.screenshot({ path: path.join(screens, 'n9c2-review-profile-derived-390.png'), fullPage: true });
      }
    }
    // 長路徑：overflow-wrap，不撐開版面
    const longIndex = groups.findIndex(group => String((group.children[0].fileDetails[0].resolution || {}).original || '').startsWith('%APP_HOME%'));
    await showGroup(page, longIndex);
    await noOverflow(page, 'long path');
    const longShown = await resolutionOf(page); assert.equal(longShown['人工處置下一步'], '確認變數在新機的值', 'custom variable next step');
    assert.match(longShown['涉及的環境變數'], /APP_HOME/);
    await page.screenshot({ path: path.join(screens, 'n9c2-review-long-path-390.png'), fullPage: true });
    // 機密變數：只有名稱，沒有值
    const secretIndex = groups.findIndex(group => String((group.children[0].fileDetails[0].resolution || {}).original || '').startsWith('%WSM_SECRET_TOKEN%'));
    await showGroup(page, secretIndex);
    const secretShown = await resolutionOf(page);
    assert.match(secretShown['涉及的環境變數'], /WSM_SECRET_TOKEN（機密，值未保存）/);
    assert.doesNotMatch(await page.locator('body').innerText(), /SECRET-VALUE-MUST-NOT-LEAK/);
    await page.close();

    // ===== 2. C2 軟體處置審閱：涵蓋缺口與未解析的消費者路徑
    step = 'prepare';
    const c2Page = await openPage(390);
    await c2Page.locator('[data-b5-panel="c2"] .b5-table tbody tr').first().waitFor();
    const c2 = c2Page.locator('[data-b5-panel="c2"]');
    await c2.locator('.b5-coverage > summary').click();
    assert.match(await c2.locator('.b5-coverage li').first().innerText(), /SourcePathUnresolved.*來源路徑未解析，需人工處置/);
    const section = c2.locator('.path-resolution-section');
    assert.equal(await section.count(), 1, 'unresolved consumer path section rendered');
    assert.match(await section.locator('h3').innerText(), /來源路徑未能解析（1 項，需人工處置）/);
    const consumer = await c2Page.evaluate(() => { const box = document.querySelector('.path-resolution-section .path-resolution'); const out = { unresolved: box.classList.contains('is-unresolved'), state: box.querySelector('.path-resolution-state').textContent }; box.querySelectorAll('dd').forEach(dd => { out[dd.dataset.field] = dd.textContent; }); return out; });
    assert.equal(consumer['原字串'], '%USERPROFILE%\\run.exe'); assert.equal(consumer['解析結果'], '未解析'); assert.equal(consumer['解析依據'], '未解析');
    assert.equal(consumer['人工處置下一步'], '在新機確認該帳號的設定檔路徑'); assert.equal(consumer.unresolved, true);
    assert.doesNotMatch(await c2Page.locator('body').innerText(), /SECRET-VALUE-MUST-NOT-LEAK/, 'the closed runtime shape drops unexpected fields');
    await noOverflow(c2Page, 'C2 panel');
    await section.scrollIntoViewIfNeeded();
    await c2Page.screenshot({ path: path.join(screens, 'n9c2-c2-consumer-390.png'), fullPage: true });
    await c2Page.setViewportSize({ width: 1280, height: 900 }); await noOverflow(c2Page, 'C2 panel 1280');
    await c2Page.close();

    // ===== 3. Q2：UNC 路徑的責任標示（審閱畫面）。三個群組：沿用外部共享、含標記字元的路徑、有通過驗證契約的另行遷移。
    assert.equal(fixture.uncGroups.length, 3, 'the projection produced one group per UNC item');
    servedGroups = fixture.uncGroups.map(group => Object.assign({}, group, { confirmed: false })); step = 'review'; currentGroupId = servedGroups[0].groupId;
    const uncPage = await openPage(390);
    const uncOf = page => page.evaluate(() => { const out = []; document.querySelectorAll('.wizard-file-details .unc-responsibility').forEach(box => { const row = { responsibility: box.dataset.responsibility, state: box.querySelector('.path-resolution-state').textContent, separate: box.classList.contains('is-separate') }; box.querySelectorAll('dd').forEach(dd => { row[dd.dataset.field] = dd.textContent; }); out.push(row); }); return out; });
    const uncFindIndex = text => servedGroups.findIndex(group => { const first = group.children[0].fileDetails[0]; return !!first && first.path === text; });
    async function showUncGroup(index) {
      await uncPage.evaluate(i => { const s = window.WsmConsole.state; s.wizard = Object.assign({}, s.wizard, { currentGroupId: s.wizard.groups[i].groupId }); window.WsmConsole.renderWizard(s.wizard); }, index);
      await uncPage.locator('.wizard-file-details > summary').click();
    }
    const seenResponsibilities = new Set();
    const uncCases = [
      { responsibility: 'ExternalShareReuse', label: '沿用外部共享', summary: '沿用外部共享，不自動複製', evidence: '無', path: '\\\\fs1\\data\\app', shot: 'q2-review-external-390.png' },
      { responsibility: 'ExternalShareReuse', label: '沿用外部共享', summary: '沿用外部共享，不自動複製', evidence: '無', path: '\\\\fs1\\<b>share<b>\\<script>alert(1)<x>', shot: 'q2-review-hostile-390.png', hostile: true },
      { responsibility: 'SeparateMigration', label: '另行遷移', summary: '另行遷移，需另行核准', evidence: '有', path: '\\\\q2-source\\data\\root\\appA\\data', shot: 'q2-review-separate-390.png' }
    ];
    for (const item of uncCases) {
      const index = uncFindIndex(item.path); assert.ok(index >= 0, `fixture has ${item.path}`);
      await showUncGroup(index);
      const shown = await uncOf(uncPage);
      assert.equal(shown.length, 1, `exactly one UNC responsibility block (${item.responsibility})`);
      const block = shown[0]; seenResponsibilities.add(block.responsibility);
      assert.equal(block.responsibility, item.responsibility, 'responsibility code');
      assert.equal(block.state.slice(2), item.label, 'state text'); assert.match(block.state.charAt(0), /[⇄↗]/, 'state is icon plus text, never colour alone');
      assert.equal(block['UNC 路徑'], item.path, 'UNC path shown verbatim as text');
      assert.equal(block['責任歸屬'], item.summary); assert.equal(block['責任證據'], item.evidence);
      assert.ok(block['責任說明'] && block['責任下一步'], 'reason and next step shown');
      assert.equal(block.separate, item.responsibility === 'SeparateMigration');
      if (item.responsibility === 'ExternalShareReuse') assert.match(block['責任下一步'], /不會複製此位置.*不會把它改成本機路徑/, 'external share: nothing copied, never turned local');
      else assert.match(block['責任下一步'], /另行核准/, 'separate migration needs its own approval');
      if (item.hostile) assert.equal(await uncPage.locator('.wizard-file-details b, .wizard-file-details script, .wizard-file-details x').count(), 0, 'markup in the path must not create elements');
      assert.equal(await uncPage.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, `no horizontal overflow: ${item.responsibility}`);
      await uncPage.locator('.unc-responsibility').first().scrollIntoViewIfNeeded();
      await uncPage.screenshot({ path: path.join(screens, item.shot), fullPage: true });
    }
    assert.deepEqual([...seenResponsibilities].sort(), ['ExternalShareReuse', 'SeparateMigration'], 'both responsibilities were displayed');
    await uncPage.close();

    assert.deepEqual(errors, [], 'zero console errors');
    process.stdout.write('PASS: path resolution basis display (review + C2) and UNC responsibility (both kinds), 390px, zero console errors\n');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
