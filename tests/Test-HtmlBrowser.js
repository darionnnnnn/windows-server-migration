const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const operationSource = fs.readFileSync(path.join(root, 'src/OperationRequests.ps1'), 'utf8');
const htmlConsoleSource = fs.readFileSync(path.join(root, 'src/HtmlConsole.ps1'), 'utf8');
const actionNames = [...new Set([
  ...[...operationSource.matchAll(/(?:\{|;)([A-Za-z][A-Za-z0-9]+)='[^']+'/g)].map(match => match[1]),
  ...[...htmlConsoleSource.matchAll(/@\('([A-Za-z][A-Za-z0-9]+)','[^']+'\)/g)].map(match => match[1])
])];
let browser;
const staticFiles = new Map([
  ['/', path.join(root, 'src/ui/index.html')],
  ['/ui/console.js', path.join(root, 'src/ui/console.js')],
  ['/ui/console.css', path.join(root, 'src/ui/console.css')],
  ['/ui/guide.html', path.join(root, 'src/ui/guide.html')]
]);
const server = http.createServer((request, response) => {
  const file = staticFiles.get(new URL(request.url, 'http://127.0.0.1').pathname);
  if (!file) { response.writeHead(404); response.end('Not found'); return; }
  response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' });
  fs.createReadStream(file).pipe(response);
});

(async () => {
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    const url = `http://127.0.0.1:${server.address().port}/`;
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const errors = [];
    let reportOpenRequest = null, cancelRequest = null, reconnectRequest = null, settingsSubmitRequest = null;
    let contextId = 'fixture-context-1', role = 'Manager', revision = 1;
    const inventory = Array.from({ length: 125 }, (_, index) => ({
      itemId: `fixture-${index}`, name: `Fixture ${index} <img src=x onerror=alert(1)>`, category: 'Runtime',
      selected: true, selectable: true, approvalStatus: 'Pending', executionStatus: 'NotObserved', reason: '', impact: 'Fixture only'
    }));
    const fieldsSchema = { title: 'Fields', properties: { TargetPath: { type: 'path' }, Product: { type: 'string' }, BusinessChecks: { type: 'stringArray' }, IisBindings: { type: 'objectArray', schema: { title: 'IIS 繫結', properties: { Index: { type: 'integer' }, Protocol: { type: 'string' }, BindingInformation: { type: 'string' }, CertificateHash: { type: 'string' }, CertificateStoreName: { type: 'string', allowEmpty: true }, SslFlags: { type: 'string' } } } }, IisApplicationPools: { type: 'objectArray', schema: { title: '應用程式集區', properties: { Index: { type: 'integer' }, ApplicationPath: { type: 'string' }, PoolName: { type: 'string' } } } }, IisPoolSettings: { type: 'map' } } };
    const actions = actionNames.map(action => ({ action, label: action, parameters: [] }));
    const actionFixture = action => actions.find(entry => entry.action === action);
    for (const action of ['WindowsSettingsPreviewExport', 'WindowsSettingsSubmit', 'DispositionSubmit', 'RequirementSubmit', 'RequirementReview', 'RequirementDecisionSubmit', 'PreparationPreview', 'PreparationEvidence']) if (!actionFixture(action)) actions.push({ action, label: action, parameters: [] });
    actionFixture('Dependencies').parameters = [{ name: 'Dependencies', type: 'objectArray', schema: { title: 'Dependency', properties: { Name: { type: 'string' }, Path: { type: 'path' } } } }];
    actionFixture('Fleet').parameters = [];
    if (!actionFixture('HttpIntegrityProbe')) actions.push({ action: 'HttpIntegrityProbe', label: 'HttpIntegrityProbe', parameters: [] });
    actionFixture('HttpIntegrityProbe').parameters = [{ name: 'Origin', type: 'string', required: true }, { name: 'OutputPath', type: 'path', required: true }];
    actionFixture('AssistiveReportCheck').parameters = [{ name: 'ManifestPath', type: 'path', required: true }, { name: 'ExpectedHash', type: 'string', required: true }];
    const settingsDecisionSchema = { title: 'Windows 設定決策', properties: {
      SettingId: { type: 'string', required: true },
      Action: { type: 'enum', required: true, options: ['KeepTarget', 'External', 'ReviewedMigration'] },
      Owner: { type: 'string' }, Reason: { type: 'string' }, Evidence: { type: 'string' }
    } };
    actionFixture('WindowsSettingsSubmit').parameters = [
      { name: 'SourceInventoryPath', type: 'path', required: true }, { name: 'SourceInventoryHash', type: 'string', required: true },
      { name: 'TargetInventoryPath', type: 'path', required: true }, { name: 'TargetInventoryHash', type: 'string', required: true },
      { name: 'PreviewPath', type: 'path', required: true }, { name: 'PreviewHash', type: 'string', required: true }, { name: 'ReviewWindowsSettings', type: 'boolean', required: true },
      { name: 'ExpectedRevision', type: 'integer', required: true }, { name: 'Ack', type: 'boolean', required: true }, { name: 'Decisions', type: 'objectArray', required: true, allowEmpty: true, schema: settingsDecisionSchema }
    ];
    actionFixture('RequirementDecisionSubmit').parameters = [
      { name: 'ExpectedRevision', type: 'integer', required: true }, { name: 'ReviewHash', type: 'string', required: true }, { name: 'Ack', type: 'boolean', required: true },
      { name: 'Decisions', type: 'objectArray', required: true, allowEmpty: true, schema: { title: '一般主機需求決策', properties: { RequirementId: { type: 'string', required: true }, Decision: { type: 'enum', required: true, options: ['Pending','Required','NotNeeded'] }, Owner: { type: 'string', required: true }, DecisionReason: { type: 'string', required: true }, DecisionEvidence: { type: 'string', required: true } } } }
    ];
    actionFixture('SaveSpecReview').parameters = [
        { name: 'ItemId', type: 'string', required: true },
        { name: 'ExpectedDecisionRevision', type: 'integer', required: true },
        { name: 'ExpectedAssistiveRevision', type: 'integer', required: true },
        { name: 'ExpectedSelectionRevision', type: 'integer', required: true },
        { name: 'Owner', type: 'string', required: true },
        { name: 'Evidence', type: 'string', required: true },
        { name: 'Fields', type: 'object', schema: fieldsSchema }
      ];
    page.on('pageerror', error => errors.push(error.message));
    page.route('https://local.adguard.org/**', route => route.abort());
    page.route(/\/api\/.*/, async route => {
      const request = route.request(), parsed = new URL(request.url()), pathname = parsed.pathname;
      const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
      if (pathname === '/api/session' && request.method() === 'GET') return json({ token: 'memory-only-test-token', sessionId: 'fixture-session', contextId, hostName: 'fixture-host', role, workspace: root, pairId: 'fixture-pair', revision, principal: 'fixture-user' });
      if (pathname === '/api/context' && request.method() === 'GET') return json({ roles: ['Manager', 'Source', 'Target'], pairs: [{ pairId: 'fixture-pair', label: 'Fixture pair' }], role, pairId: 'fixture-pair', revision });
      if (pathname === '/api/context' && request.method() === 'POST') { role = request.postDataJSON().role; contextId = `fixture-context-${Date.now()}`; return json({ role, pairId: 'fixture-pair', contextId, revision }); }
      if (pathname === '/api/view' && request.method() === 'GET') {
        const action = parsed.searchParams.get('action');
        if (action === 'overview') return json({ metrics: { discovered: 125, selected: 125, approved: 0, executable: 'NotMeasured', pendingOrFailed: 125 }, workloadStatus: 'ReviewRequired', nextStep: { title: 'Review inventory', description: 'Fixture preview only.' }, steps: [] });
        if (action === 'inventory') return json({ items: inventory, totalCount: inventory.length, pageSize: 50, selectedItemIds: inventory.filter(row => row.selected).map(row => row.itemId) });
        if (action === 'actions') return json({ actions });
        if (action === 'files') return json({ rows: [] });
        if (action === 'software') return json({ rows: [] });
      }
      if (pathname === '/api/spec-review' && request.method() === 'GET') return json({
        ItemId: parsed.searchParams.get('itemId'), Adapter: 'FileScope', DecisionRevision: 7, AssistiveRevision: 4, SelectionRevision: 3,
        Owner: 'Fixture owner', Evidence: 'Reviewed evidence', DesiredFinalState: 'Enabled',
        TypedFields: { TargetPath: 'E:\\Sites\\Portal', Product: 'Portal', IisBindings: [{ Index: 0, Protocol: 'https', BindingInformation: '*:443:fixture.example', CertificateHash: 'ABC123', CertificateStoreName: '', SslFlags: '1', Password: 'do not render', Command: 'DO-NOT-RENDER', Xml: '<secret>DO-NOT-RENDER</secret>' }], IisApplicationPools: [{ Index: 0, ApplicationPath: '/', PoolName: 'FixturePool', Arguments: 'DO-NOT-RENDER' }], IisPoolSettings: { managedRuntimeVersion: 'v4.0', startMode: 'OnDemand', privateKey: 'DO-NOT-RENDER' }, Arguments: 'must not appear', Xml: '<secret>must not appear</secret>' },
        MissingTypedFields: ['BusinessChecks'], OpaqueReviewRequired: [{ FieldPointer: 'Task/Actions/Action[0]/Arguments', ReferenceKind: 'Arguments', Status: 'ReviewRequired', Reason: 'Owner review required' }],
        WorkloadActions: [{ Index: 0 }, { Index: 1 }], IisBindings: [], IisApplications: [], SharedResourceReviewReasons: [],
        SourceXmlSHA256: 'source-hash', TargetXmlSHA256: 'target-hash', RawXmlIncluded: false, SecretsIncluded: false
      });
      if (pathname === '/api/view' && request.method() === 'POST') return json({ preview: { revision, previewKind: 'ResourcePreview', canExecute: true, items: [], issues: [] } });
      if (pathname === '/api/operations' && request.method() === 'POST') {
        const body = request.postDataJSON();
        if (body.action === 'WindowsSettingsSubmit') { settingsSubmitRequest = body; return json({ job: { jobId: body.operationId, action: body.action, status: 'Running', canCancel: false } }, 202); }
        if (body.action === 'SaveSelection') {
          const selected = new Set(body.args.selectedItemIds);
          inventory.forEach(row => { row.selected = selected.has(row.itemId); if (!row.selected) row.reason = (body.args.unselectedItems || []).find(item => item.itemId === row.itemId)?.reason || ''; });
          return json({ revision: ++revision, status: 'Saved' });
        }
        return json({ job: { jobId: body.operationId, action: body.action, status: 'Running', canCancel: false } }, 202);
      }
      if (/^\/api\/jobs\/[^/]+\/cancel$/.test(pathname) && request.method() === 'POST') {
        cancelRequest = { pathname, method: request.method(), headers: request.headers(), body: request.postDataJSON() };
        return json({ job: { jobId: 'fixture-job', action: 'AssistiveReport', status: 'CancelRequested', canCancel: true } });
      }
      if (pathname === '/api/jobs/fixture-job' && request.method() === 'GET') {
        reconnectRequest = { pathname, method: request.method(), headers: request.headers() };
        return json({ jobId: 'fixture-job', action: 'AssistiveReport', status: 'CancelRequested', canCancel: true });
      }
      if (pathname === '/api/jobs' && request.method() === 'GET') return json({ items: [] });
      if (/^\/api\/jobs\/.*\/reports\/\d+\/open$/.test(pathname) && request.method() === 'POST') {
        reportOpenRequest = { method: request.method(), headers: request.headers(), body: request.postDataJSON() };
        return json({ status: 'Opened', SHA256: reportOpenRequest.body.SHA256 });
      }
      return json({ message: `Unhandled UI test route: ${request.method()} ${pathname}` }, 404);
    });

    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });
    await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.session && window.WsmConsole.state.token);
    await page.locator('[data-view="inventory"]').first().click();
    await page.waitForFunction(() => window.WsmConsole.state.inventory.length === 125);
    assert.equal(await page.locator('#inventory-rows tr').count(), 50);
    assert.equal(await page.locator('#inventory-rows img').count(), 0);
    assert.match(await page.locator('#selection-summary').textContent(), /125/);

    await page.locator('.spec-review-button').first().click();
    await page.waitForFunction(() => !document.querySelector('#spec-review-panel').hidden);
    assert.match(await page.locator('#spec-review-panel').textContent(), /BusinessChecks/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /Task\/Actions\/Action\[0\]\/Arguments/);
    assert.match(await page.locator('#spec-review-counts').textContent(), /排程動作：2/);
    assert.doesNotMatch(await page.locator('#spec-review-panel').textContent(), /must not appear|<secret>/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /\*:443:fixture\.example/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /FixturePool/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /憑證存放區/);
    assert.doesNotMatch(await page.locator('#spec-review-panel').textContent(), /DO-NOT-RENDER/);
    await page.locator('#spec-review-prefill').click();
    await page.waitForFunction(() => window.WsmConsole.state.activeAction === 'SaveSpecReview');
    assert.equal(await page.locator('[data-parameter="ItemId"]').inputValue(), 'fixture-0');
    assert.equal(await page.locator('[data-parameter="ExpectedDecisionRevision"]').inputValue(), '7');
    assert.equal(await page.locator('[data-parameter="TargetPath"]').inputValue(), 'E:\\Sites\\Portal');
    assert.equal(await page.locator('[data-parameter="Product"]').inputValue(), 'Portal');
    assert.deepEqual(await page.locator('#parameter-fields [data-parameter="BindingInformation"]').evaluateAll(nodes => nodes.map(node => node.value)), ['*:443:fixture.example']);
    assert.deepEqual(await page.locator('#parameter-fields [data-parameter="PoolName"]').evaluateAll(nodes => nodes.map(node => node.value)), ['FixturePool']);

    await page.locator('[data-view="inventory"]').first().click();
    await page.locator('#inventory-rows input[type="checkbox"]').first().uncheck();
    await page.locator('.selection-reason').first().fill('fixture excluded with owner review');
    await page.locator('#save-selection').click();
    await page.waitForFunction(() => window.WsmConsole.state.selectionDirty === false);
    assert.match(await page.locator('#selection-summary').textContent(), /124/);
    await page.locator('#refresh-button').click();
    await page.waitForTimeout(100);
    assert.equal(await page.locator('#inventory-rows input[type="checkbox"]').first().isChecked(), false);

    await page.locator('[data-view="operations"]').first().click();
    await page.waitForFunction(() => window.WsmConsole.state.actions.length > 90);
    assert.equal(await page.locator('#action-picker optgroup').count(), 3);
    assert.ok(await page.locator('#action-picker optgroup').evaluateAll(groups => groups.every(group => group.label.includes('端') && group.children.length > 0)));
    const actionOptions = await page.locator('#action-picker option').evaluateAll(options => options.filter(option => option.value).map(option => ({ value: option.value, label: option.textContent })));
    assert.equal(actionOptions.length, await page.evaluate(() => window.WsmConsole.state.actions.length));
    assert.ok(actionOptions.every(option => /[\u3400-\u9fff]/.test(option.label)), 'every action, including advanced entries, receives a Chinese label');
    assert.ok(actionOptions.every(option => option.label !== option.value), 'action identifiers are not exposed as picker labels');
    await page.locator('#action-picker').selectOption('HttpIntegrityProbe');
    assert.equal(await page.locator('[data-parameter="Origin"]').inputValue(), new URL(url).origin);
    assert.equal(await page.locator('[data-parameter="OutputPath"]').inputValue(), '');
    assert.match(await page.locator('#action-metadata').textContent(), /只會 GET|只會 GET/);
    await page.locator('#action-picker').selectOption('AssistiveReportCheck');
    assert.match(await page.locator('#parameter-fields').textContent(), /文件清單路徑/);
    assert.match(await page.locator('#parameter-fields').textContent(), /DocumentManifestPath/);
    assert.match(await page.locator('#parameter-fields').textContent(), /DocumentManifestHash/);
    await page.locator('#action-picker').selectOption('Fleet');
    assert.match(await page.locator('#action-metadata').textContent(), /管理端操作步驟/);
    await page.locator('#action-picker').selectOption('Dependencies');
    assert.match(await page.locator('#parameter-fields').textContent(), /相依項目/);
    assert.ok(await page.locator('#parameter-fields .object-array-editor').count());
    await page.locator('#action-picker').selectOption('Fleet');
    await page.locator('#preview-operation').click();
    await page.waitForFunction(() => window.WsmConsole.state.preview);
    assert.equal(await page.locator('#submit-operation').isEnabled(), false);
    await page.locator('#operation-confirm').check();
    assert.equal(await page.locator('#submit-operation').isEnabled(), true);

    for (const nextRole of ['Source', 'Manager', 'Target']) {
      const oldContext = await page.evaluate(() => window.WsmConsole.state.session.contextId);
      await page.locator('#context-role').selectOption(nextRole);
      await page.locator('#apply-context').click();
      await page.waitForFunction(old => window.WsmConsole.state.session.contextId !== old, oldContext);
      await page.waitForFunction(() => window.WsmConsole.state.actions.length > 90);
      assert.equal(await page.locator('#action-picker optgroup').count(), 3);
      assert.ok(await page.locator('#action-picker option').evaluateAll(options => options.filter(option => option.value).every(option => /[\u3400-\u9fff]/.test(option.textContent))));
    }
    {
      const oldContext = await page.evaluate(() => window.WsmConsole.state.session.contextId);
      await page.locator('#context-role').selectOption('Manager');
      await page.locator('#apply-context').click();
      await page.waitForFunction(old => window.WsmConsole.state.session.contextId !== old, oldContext);
    }
    assert.equal(await page.locator('#confirm-line').isVisible(), false);
    assert.equal(await page.locator('#parameter-fields input').count(), 0);

    await page.evaluate(() => window.WsmConsole.renderFiles({ rows: [{ originalPath: 'C:\\Source\\settings.ini', preservedPath: 'D:\\Preserved\\settings.ini', effectivePath: null, sourceHash: 'source-hash', readbackHash: 'readback-hash', conflictHash: null }] }));
    const fileCells = await page.locator('#file-rows tr').first().locator('td').allTextContents();
    assert.match(fileCells[0], /C:\\Source/);
    assert.match(fileCells[1], /D:\\Preserved/);
    assert.equal(fileCells[2].trim(), '未知（未觀測）');
    assert.match(fileCells[3], /來源 SHA-256：source-hash/);
    assert.match(fileCells[3], /讀回 SHA-256：readback-hash/);
    assert.match(fileCells[3], /衝突 SHA-256：未知（未觀測）/);

    await page.locator('[data-view="jobs"]').first().click();
    await page.waitForFunction(() => location.hash === '#jobs');
    await page.evaluate(() => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-job', { jobId: 'fixture-job', status: 'Succeeded', action: 'AssistiveReport', outputs: [{ Path: 'C:\\very\\long\\migration\\report.html' }], reportArtifacts: [{ Path: 'C:\\very\\long\\migration\\report.html', Label: 'fixture report', SHA256: 'report-hash' }] });
      window.WsmConsole.renderJobs();
    });
    assert.equal(await page.locator('#job-list .job-output dd').first().textContent(), 'C:\\very\\long\\migration\\report.html');
    assert.match(await page.locator('#job-list').textContent(), /管理報告/);
    await page.locator('#job-list button').filter({ hasText: '開啟報告' }).click();
    await page.waitForFunction(() => window.WsmConsole.state.jobs.size === 1);
    assert.equal(reportOpenRequest.method, 'POST');
    assert.ok(reportOpenRequest.headers['x-wsm-token']);
    assert.deepEqual(reportOpenRequest.body, { SHA256: 'report-hash' });

    await page.evaluate(() => {
      window.WsmConsole.state.jobs.set('fixture-job', { jobId: 'fixture-job', status: 'Running', action: 'AssistiveReport', canCancel: true });
      window.WsmConsole.renderJobs();
    });
    await page.locator('#job-list button').filter({ hasText: '要求取消' }).click();
    await page.waitForFunction(() => window.WsmConsole.state.jobs.get('fixture-job').status === 'CancelRequested');
    assert.ok(cancelRequest);
    assert.equal(cancelRequest.method, 'POST');
    assert.equal(cancelRequest.pathname, '/api/jobs/fixture-job/cancel');
    assert.ok(cancelRequest.headers['x-wsm-token']);
    assert.deepEqual(cancelRequest.body, {});
    assert.match(await page.locator('#job-list').textContent(), /取消已送出/);
    assert.doesNotMatch(await page.locator('#job-list').textContent(), /已取消/);
    await page.locator('#job-list button').filter({ hasText: '重新連線' }).click();
    assert.ok(reconnectRequest);
    assert.equal(reconnectRequest.pathname, '/api/jobs/fixture-job');
    assert.ok(reconnectRequest.headers['x-wsm-token']);
    assert.equal(await page.evaluate(() => window.WsmConsole.state.jobs.get('fixture-job').jobId), 'fixture-job');

    const physicalPreviewHash = 'a'.repeat(64), semanticPreviewHash = 'b'.repeat(64);
    await page.evaluate(({ physicalPreviewHash, semanticPreviewHash }) => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-settings-preview', { jobId: 'fixture-settings-preview', status: 'Succeeded', action: 'WindowsSettingsPreviewExport', outputs: [{
        Kind: 'AssistiveWindowsSettingsPreviewOutput', PairId: 'fixture-pair',
        SourceInventoryPath: 'C:\\WSM\\source.json', SourceInventoryHash: 'c'.repeat(64),
        TargetInventoryPath: 'C:\\WSM\\target.json', TargetInventoryHash: 'd'.repeat(64),
        PreviewPath: 'C:\\WSM\\protected-preview.json', PreviewFileHash: physicalPreviewHash, PreviewHash: semanticPreviewHash,
        ExpectedRevision: 23, ReviewWindowsSettings: true, RowCount: 2,
        Rows: [
          { SettingId: 'setting-one', SettingName: 'Safe setting one', SourceItemId: 'source-one', Category: 'IIS', Kind: 'String', SourceValueHash: 'e'.repeat(64), TargetValueHash: 'f'.repeat(64), TargetDiff: true, ControlSource: 'IIS', SupportedActions: ['KeepTarget', 'External'], DefaultAction: 'External', RequiredConsumerItemIds: ['consumer-one'], RawValue: 'DO-NOT-RENDER', Arguments: 'DO-NOT-RENDER', Xml: '<secret>DO-NOT-RENDER</secret>' },
          { SettingId: 'setting-two', SettingName: 'Safe setting two', SourceItemId: 'source-two', Category: 'Tasks', Kind: 'Boolean', SourceValueHash: '1'.repeat(64), TargetValueHash: '2'.repeat(64), TargetDiff: true, ControlSource: 'Task', SupportedActions: ['KeepTarget', 'ReviewedMigration'], DefaultAction: '', RequiredConsumerItemIds: [], Command: 'DO-NOT-RENDER', Password: 'DO-NOT-RENDER' }
        ], SecretToken: 'DO-NOT-RENDER'
      }] });
      window.WsmConsole.renderJobs();
    }, { physicalPreviewHash, semanticPreviewHash });
    assert.match(await page.locator('#job-list').textContent(), /Safe setting one/);
    assert.match(await page.locator('#job-list').textContent(), /來源值 SHA-256/);
    assert.doesNotMatch(await page.locator('#job-list').textContent(), /DO-NOT-RENDER|<secret>/);
    await page.locator('#job-list button').filter({ hasText: '使用此預覽準備設定審閱' }).click();
    await page.waitForFunction(() => window.WsmConsole.state.activeAction === 'WindowsSettingsSubmit');
    assert.equal(await page.locator('[data-parameter="SourceInventoryPath"]').inputValue(), 'C:\\WSM\\source.json');
    assert.equal(await page.locator('[data-parameter="SourceInventoryHash"]').inputValue(), 'c'.repeat(64));
    assert.equal(await page.locator('[data-parameter="TargetInventoryPath"]').inputValue(), 'C:\\WSM\\target.json');
    assert.equal(await page.locator('[data-parameter="PreviewPath"]').inputValue(), 'C:\\WSM\\protected-preview.json');
    assert.equal(await page.locator('[data-parameter="PreviewHash"]').inputValue(), physicalPreviewHash);
    assert.notEqual(await page.locator('[data-parameter="PreviewHash"]').inputValue(), semanticPreviewHash);
    assert.equal(await page.locator('[data-parameter="ReviewWindowsSettings"]').inputValue(), 'true');
    assert.equal(await page.locator('[data-parameter="ExpectedRevision"]').inputValue(), '23');
    assert.deepEqual(await page.locator('#parameter-fields [data-parameter="SettingId"]').evaluateAll(nodes => nodes.map(node => node.value)), ['setting-one', 'setting-two']);
    assert.deepEqual(await page.locator('#parameter-fields [data-parameter="Action"]').evaluateAll(nodes => nodes.map(node => node.value)), ['External', '']);
    for (const field of ['Owner', 'Reason', 'Evidence']) assert.deepEqual(await page.locator(`#parameter-fields [data-parameter="${field}"]`).evaluateAll(nodes => nodes.map(node => node.value)), ['', '']);
    assert.equal(await page.locator('#operation-confirm').isChecked(), false);
    assert.equal(await page.locator('#submit-operation').isEnabled(), false);
    assert.match(await page.locator('[aria-live="polite"]').allTextContents().then(values => values.join(' ')), /尚未提交/);

    await page.locator('[data-view="jobs"]').first().click();
    await page.evaluate(() => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-empty-settings-preview', { jobId: 'fixture-empty-settings-preview', status: 'Succeeded', action: 'WindowsSettingsPreviewExport', outputs: [{
        Kind: 'AssistiveWindowsSettingsPreviewOutput', PairId: 'fixture-pair', SourceInventoryPath: 'C:\\WSM\\source.json', SourceInventoryHash: 'c'.repeat(64),
        TargetInventoryPath: 'C:\\WSM\\target.json', TargetInventoryHash: 'd'.repeat(64), PreviewPath: 'C:\\WSM\\empty-preview.json', PreviewFileHash: '4'.repeat(64),
        PreviewHash: '5'.repeat(64), ExpectedRevision: 24, ReviewWindowsSettings: false, RowCount: 0, Rows: []
      }] });
      window.WsmConsole.renderJobs();
    });
    await page.locator('#job-list button').filter({ hasText: '使用此預覽準備設定審閱' }).click();
    await page.waitForFunction(() => window.WsmConsole.state.activeAction === 'WindowsSettingsSubmit');
    assert.equal(await page.locator('[data-parameter="ReviewWindowsSettings"]').inputValue(), 'false');
    assert.equal(await page.locator('#parameter-fields [data-parameter="SettingId"]').count(), 0);
    await page.locator('[data-parameter="Ack"]').selectOption('true');
    assert.deepEqual(await page.evaluate(() => window.WsmConsole.collectArgs(true).Decisions), []);
    await page.locator('#preview-operation').click();
    await page.waitForFunction(() => !!window.WsmConsole.state.preview);
    assert.deepEqual(await page.evaluate(() => JSON.parse(JSON.stringify(window.WsmConsole.collectArgs(true).Decisions))), []);
    assert.equal(await page.locator('#operation-confirm').isChecked(), false);
    assert.equal(await page.locator('#submit-operation').isEnabled(), false);
    await page.locator('#operation-confirm').check();
    assert.equal(await page.locator('#submit-operation').isEnabled(), true);
    await page.locator('#submit-operation').click();
    await page.waitForFunction(() => window.WsmConsole.state.activeAction === null);
    assert.ok(settingsSubmitRequest);
    assert.deepEqual(settingsSubmitRequest.args.Decisions, []);
    assert.equal(settingsSubmitRequest.args.ReviewWindowsSettings, false);
    assert.equal(settingsSubmitRequest.args.Ack, true);
    assert.equal(settingsSubmitRequest.args.PreviewHash, '4'.repeat(64));

    await page.locator('[data-view="jobs"]').first().click();
    await page.evaluate(() => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-preparation-preview', { jobId: 'fixture-preparation-preview', status: 'Succeeded', action: 'PreparationPreview', outputs: [{ Kind: 'AssistivePreparationPreview', RowCount: 1, Rows: [{ RequirementId: 'requirement-one', ProviderSoftwareId: 'runtime-one', ExpectedVersion: '9.4', Architecture: 'x64', RequiredPhase: 'BeforeRestore', Decision: 'External', Certainty: 'High', ConsumerItemIds: ['consumer-one'], ContextHash: '3'.repeat(64), SecretValue: 'DO-NOT-RENDER' }] }] });
      window.WsmConsole.renderJobs();
    });
    assert.match(await page.locator('#job-list').textContent(), /runtime-one/);
    assert.match(await page.locator('#job-list').textContent(), /BeforeRestore/);
    assert.doesNotMatch(await page.locator('#job-list').textContent(), /DO-NOT-RENDER/);

    await page.evaluate(() => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-requirement-review', { jobId: 'fixture-requirement-review', status: 'Succeeded', action: 'RequirementReview', outputs: [{
        Kind: 'AssistiveRequirementReview', Status: 'Previewed', PairId: 'fixture-pair', ExpectedRevision: 31, ReviewHash: '6'.repeat(64), RowCount: 2,
        Rows: [
          { RequirementId: 'req-one', Type: 'Runtime', ProviderSoftwareId: 'provider-one', ProviderItemId: 'source-one', ExternalId: '', ExpectedVersion: '9.4', Architecture: 'x64', RequiredPhase: 'BeforeRestore', Decision: 'Required', Certainty: 'High', ConsumerItemIds: ['consumer-one'], ContextHash: '7'.repeat(64), Context: { Secret: 'DO-NOT-RENDER' }, SourceProof: { Evidence: 'DO-NOT-RENDER' }, Arguments: 'DO-NOT-RENDER' },
          { RequirementId: 'req-two', Type: 'Service', ProviderSoftwareId: '', ProviderItemId: '', ExternalId: 'external-2', ExpectedVersion: '', Architecture: 'x64', RequiredPhase: 'AfterRestore', Decision: 'Pending', Certainty: 'Medium', ConsumerItemIds: [], ContextHash: '8'.repeat(64), RawXml: '<secret>DO-NOT-RENDER</secret>' }
        ], SecretToken: 'DO-NOT-RENDER'
      }] });
      window.WsmConsole.renderJobs();
    });
    const reqOutput = await page.locator('#job-list').textContent();
    assert.match(reqOutput, /req-one/);
    assert.match(reqOutput, /provider-one/);
    assert.match(reqOutput, /需求識別碼/);
    assert.doesNotMatch(reqOutput, /DO-NOT-RENDER|<secret>/);
    await page.locator('#job-list button').filter({ hasText: '使用此預覽準備需求審閱' }).click();
    await page.waitForFunction(() => window.WsmConsole.state.activeAction === 'RequirementDecisionSubmit');
    assert.equal(await page.locator('[data-parameter="ReviewHash"]').inputValue(), '6'.repeat(64));
    assert.equal(await page.locator('[data-parameter="ExpectedRevision"]').inputValue(), '31');
    assert.deepEqual(await page.locator('#parameter-fields [data-parameter="RequirementId"]').evaluateAll(nodes => nodes.map(node => node.value)), ['req-one', 'req-two']);
    assert.deepEqual(await page.locator('#parameter-fields [data-parameter="Decision"]').evaluateAll(nodes => nodes.map(node => node.value)), ['Required', 'Pending']);
    for (const field of ['Owner','DecisionReason','DecisionEvidence']) assert.deepEqual(await page.locator(`#parameter-fields [data-parameter="${field}"]`).evaluateAll(nodes => nodes.map(node => node.value)), ['', '']);
    assert.equal(await page.locator('[data-parameter="Ack"]').inputValue(), '');
    assert.equal(await page.locator('#operation-confirm').isChecked(), false);
    assert.equal(await page.locator('#submit-operation').isEnabled(), false);

    await page.evaluate(() => window.WsmConsole.renderInventory({ items: [{ itemId: 'locked-row', name: '<img src=x onerror=alert(1)>', selectable: false, reason: 'not eligible' }] }));
    assert.equal(await page.locator('#inventory-rows img').count(), 0);
    assert.equal(await page.locator('#inventory-rows input[type="checkbox"]').first().isDisabled(), true);
    assert.match(await page.locator('#inventory-rows').textContent(), /not eligible/);
    await page.locator('[data-view="inventory"]').first().click();
    await page.setViewportSize({ width: 320, height: 720 });
    await page.waitForTimeout(100);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'page overflow at 320px');
    await page.keyboard.press('Tab');
    assert.ok(await page.evaluate(() => document.activeElement !== document.body));
    await page.locator('[data-view="operations"]').first().click();
    await page.waitForFunction(() => window.WsmConsole.state.actions.length > 90);
    await page.locator('#action-picker').selectOption('HttpIntegrityProbe');
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'operation panel reflows at 320px');
    if (process.env.WSM_SCREENSHOT) await page.screenshot({ path: process.env.WSM_SCREENSHOT, fullPage: true });
    await page.goto(`${url}ui/guide.html`, { waitUntil: 'domcontentloaded' });
    assert.match(await page.locator('main').textContent(), /-Action Html/);
    assert.match(await page.locator('main').textContent(), /-Action Menu/);
    assert.match(await page.locator('main').textContent(), /Windows Server Core/);
    assert.match(await page.locator('main').textContent(), /互動式 PowerShell 輸入/);
    assert.deepEqual(errors, []);
    console.log('PASS: Edge UI fixture with mocked APIs; 125-item pagination, review summary and typed prefill, report-open POST, path/hash states, XSS text rendering, 320px reflow and keyboard focus. Actual loopback browser transport: NotTested; use the read-only HTTP integrity probe.');
  } finally {
    if (browser) await browser.close();
    if (server.listening) await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
