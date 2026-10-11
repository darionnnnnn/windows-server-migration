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
    page.on('dialog', dialog => dialog.accept());
    const errors = [];
    const diagnostics = [];
    page.on('console', message => { if (message.type() === 'error') diagnostics.push(`console: ${message.text()}`); });
    page.on('requestfailed', request => diagnostics.push(`request: ${request.method()} ${request.url()} ${request.failure()?.errorText || ''}`));
    let reportOpenRequest = null, cancelRequest = null, reconnectRequest = null, settingsSubmitRequest = null, jobsPollFailure = false, unknownOperationCount = 0, jobsSnapshot = [];
    let contextId = 'fixture-context-1', role = 'Manager', revision = 1, decisionRevision = 7, selectionRevision = 3, sourceSelectionRevision = 3, dataVersion = 'fixture-catalog-1', safeEmptyState = false;
    const viewContext = () => ({ sessionId:'fixture-session', contextId, pairId:'fixture-pair', role, revision, decisionRevision, selectionRevision, sourceSelectionRevision, dataVersion, readUtc:new Date().toISOString() });
    const viewReads = [];
    const inventory = Array.from({ length: 125 }, (_, index) => ({
      itemId: `fixture-${index}`, name: `Fixture ${index} <img src=x onerror=alert(1)>`, category: 'Runtime',
      selected: true, selectable: true, approvalStatus: 'Pending', executionStatus: 'NotObserved', reason: '', impact: 'Fixture only'
    }));
    const fieldsSchema = { title: 'Fields', properties: { TargetPath: { type: 'path' }, Product: { type: 'string' }, BusinessChecks: { type: 'stringArray' }, WorkloadFieldReviews: { type: 'objectArray', schema: { title: '工作負載欄位審閱', properties: { FieldPointer: { type: 'string', required: true }, Value: { type: 'string', required: true, allowEmpty: true } } } }, IisBindings: { type: 'objectArray', schema: { title: 'IIS 繫結', properties: { Index: { type: 'integer' }, Protocol: { type: 'string' }, BindingInformation: { type: 'string' }, CertificateHash: { type: 'string' }, CertificateStoreName: { type: 'string', allowEmpty: true }, SslFlags: { type: 'string', allowEmpty: true }, SslFlagsPresent: { type: 'boolean', required: true } } } }, IisApplicationPools: { type: 'objectArray', schema: { title: '應用程式集區', properties: { Index: { type: 'integer' }, ApplicationPath: { type: 'string' }, PoolName: { type: 'string' } } } }, IisPoolSettings: { type: 'map' } } };
    const actions = actionNames.map(action => ({ action, label: action, parameters: [] }));
    const actionFixture = action => actions.find(entry => entry.action === action);
    for (const action of ['OsProvidedCapture', 'OsProvidedBaseline', 'OsProvidedReview', 'OsProvidedSubmit', 'WindowsSettingsPreviewExport', 'WindowsSettingsSubmit', 'DispositionSubmit', 'RequirementSubmit', 'RequirementReview', 'RequirementDecisionSubmit', 'PreparationPreview', 'PreparationEvidence']) if (!actionFixture(action)) actions.push({ action, label: action, parameters: [] });
    actionFixture('OsProvidedCapture').parameters = [{ name: 'DecisionRevision', label: '核心決策 revision', type: 'integer', required: true, readOnly: true, value: 7, description: '由核心綁定' }];
    actionFixture('OsProvidedBaseline').parameters = [{ name: 'ExpectedDecisionRevision', label: '核心預期決策 revision', type: 'integer', required: true, readOnly: true, value: 7, description: '由核心綁定' }];
    actionFixture('OsProvidedSubmit').parameters = [{ name: 'ExpectedDecisionRevision', label: '核心預期決策 revision', type: 'integer', required: true, readOnly: true, value: 7, description: '由核心綁定' }];
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
      if (pathname === '/api/session' && request.method() === 'GET') return json({ token: 'memory-only-test-token', sessionId: 'fixture-session', contextId, hostName: 'fixture-host', role, workspace: root, pairId: 'fixture-pair', revision, decisionRevision, selectionRevision, sourceSelectionRevision, dataVersion, principal: 'fixture-user' });
      if (pathname === '/api/context' && request.method() === 'GET') return json({ roles: ['Manager', 'Source', 'Target'], pairs: [{ pairId: 'fixture-pair', label: 'Fixture pair' }], role, pairId: 'fixture-pair', revision, decisionRevision, selectionRevision, sourceSelectionRevision, dataVersion });
      if (pathname === '/api/context' && request.method() === 'POST') { const body = request.postDataJSON(); if (body.expectedDecisionRevision !== decisionRevision || body.expectedSelectionRevision !== selectionRevision || body.expectedDataVersion !== dataVersion) return json({ code:'stale_revision', message:'Fixture context changed.', nextStep:'Reload context.', correlationId:'fixture-context-conflict' }, 409); role = body.role; contextId = `fixture-context-${Date.now()}`; return json({ role, pairId: 'fixture-pair', contextId, revision, decisionRevision, selectionRevision, sourceSelectionRevision, dataVersion }); }
      if (pathname === '/api/view' && request.method() === 'GET') {
        const action = parsed.searchParams.get('action');
        viewReads.push(action);
        if (parsed.searchParams.get('contextId') !== contextId || parsed.searchParams.get('dataVersion') !== dataVersion) return json({ code:'stale_revision', message:'Fixture view changed.', nextStep:'Reload current context.', correlationId:'fixture-view-conflict' }, 409);
        const meta = { viewContext:viewContext() };
        if (action === 'overview') return json({ ...meta, counts: [{ id:'discovered', label:'盤點項目', value:125, unit:'項', source:'目前配對目錄', status:'Observed', definition:'目前目錄中的項目列數。' }, { id:'selected', label:'已選項目', value:125, unit:'項', source:'目前已保存的選取', status:'Observed', definition:'目前選取的目錄項目，不代表核准。' }, { id:'stageObjects', label:'階段項目結果', value:'Unknown', unit:'項目結果列', source:'目前世代有效階段結果的 ItemResults', status:'Unknown', definition:'ItemResults 中實際存在的列數，不是完成百分比。' }, { id:'availability', label:'服務可用性', value:'NotTested', unit:'資格狀態', source:'此總覽沒有可用性測試結果生產者', status:'NotTested', definition:'本總覽不推定正式環境就緒。' }], workloadStatus: 'ReviewRequired', nextStep: { title: '檢查目前證據', description: '依目前配對檢視已記錄項目。', reason:'目前無足夠證據指定寫入操作。', action:null, actionMetadata:null }, provenance: { pairId:'fixture-pair', role, revision, readUtc:viewContext().readUtc, generation:2, stage:'Restore', stageStatus:'Succeeded', producedUtc:'2026-10-11T01:02:03Z', planHash:'a'.repeat(64), approvalReference:'b'.repeat(64), approvalKind:'SealedPlan', deliveryStatus:'ImportedVerified', deliveryGeneration:2, deliveryId:'fixture-delivery', transportHash:'c'.repeat(64), deliveryReportOnly:false, deliveryReadinessProof:true, deliveryProductionVerified:false }, steps: [{ id:'source', label:'來源盤點', status:'Recorded', source:'目前配對輔助目錄', value:'已記錄目前來源快照', resultStatus:null, producedUtc:null }, { id:'restore', label:'還原', status:'Recorded', source:'目前世代已接受的 Restore 階段結果', value:'還原 · 完成', resultStatus:'Succeeded', stage:'Restore', generation:2, producedUtc:'2026-10-11T01:02:03Z' }] });
        if (action === 'inventory') return json({ ...meta, items: safeEmptyState ? [] : inventory, totalCount: safeEmptyState ? 0 : inventory.length, pageSize: 50, selectedItemIds: safeEmptyState ? [] : inventory.filter(row => row.selected).map(row => row.itemId), canSaveSelection:!safeEmptyState, assistiveEnabled:!safeEmptyState, ...(safeEmptyState ? { stateReason:'尚未啟用 Assistive；目前沒有可保存的盤點選取。', stateNextAction:{ action:'AssistiveEnable', label:'開啟 Assistive 型別化表單', description:'先審閱操作欄位與角色條件。', requiredRole:'Manager', roleAvailable:true } } : {}) });
        if (action === 'actions') return json({ ...meta, actions });
        if (action === 'files') return json({ ...meta, rows: [] });
        if (action === 'software') return json({ ...meta, rows: [] });
      }
      if (pathname === '/api/spec-review' && request.method() === 'GET') { if (parsed.searchParams.get('contextId') !== contextId || parsed.searchParams.get('dataVersion') !== dataVersion) return json({ code:'stale_revision', message:'Fixture review changed.', nextStep:'Reload current context.', correlationId:'fixture-review-conflict' }, 409); return json({
        viewContext:viewContext(),
        ItemId: parsed.searchParams.get('itemId'), Adapter: 'FileScope', DecisionRevision: 7, AssistiveRevision: 4, SelectionRevision: 3,
        Owner: 'Fixture owner', Evidence: 'Reviewed evidence', DesiredFinalState: 'Enabled',
        TypedFields: { TargetPath: 'E:\\Sites\\Portal', Product: 'Portal', WorkloadFieldReviews: [{ FieldPointer: 'IIS/site/FixtureSite/application[0]/virtualDirectory[0]/@physicalPath', Value: 'E:\\Sites\\Portal' }], IisBindings: [{ Index: 0, Protocol: 'custom+http', BindingInformation: '*:443:fixture.example', CertificateHash: 'ABC123', CertificateStoreName: '', SslFlags: '', SslFlagsPresent: false, Password: 'do not render', Command: 'DO-NOT-RENDER', Xml: '<secret>DO-NOT-RENDER</secret>' }], IisApplicationPools: [{ Index: 0, ApplicationPath: '/', PoolName: 'FixturePool', Arguments: 'DO-NOT-RENDER' }], IisPoolSettings: { managedRuntimeVersion: 'v4.0', startMode: 'OnDemand', privateKey: 'DO-NOT-RENDER' }, Arguments: 'must not appear', Xml: '<secret>must not appear</secret>' },
        MissingTypedFields: ['BusinessChecks', 'ManualBindingProtocolReview[0]'], OpaqueReviewRequired: [{ FieldPointer: 'Task/Actions/Action[0]/Arguments', ReferenceKind: 'Arguments', Status: 'ReviewRequired', Reason: 'Owner review required' }],
        WorkloadActions: [{ Index: 0 }, { Index: 1 }], IisBindings: [], IisApplications: [], SharedResourceReviewReasons: [],
        WorkloadPathReferences: [{ FieldPointer: 'IIS/site/FixtureSite/application[0]/virtualDirectory[0]/@physicalPath', ReferenceKind: 'IISPhysicalPath', SourcePath: 'C:\\Sites\\Portal', DraftTargetPath: 'E:\\Sites\\Portal', Channel: 'SuggestedNonC', ParseConfidence: 'Typed', Opaque: false, ReviewRequired: false }, { FieldPointer: 'Task/Actions/Action[0]/Arguments', ReferenceKind: 'TaskArguments', SourcePath: '', DraftTargetPath: '', Opaque: true, ReviewRequired: true, Reason: 'Opaque arguments withheld' }],
        SourceXmlSHA256: 'source-hash', TargetXmlSHA256: 'target-hash', RawXmlIncluded: false, SecretsIncluded: false
      }); }
      if (pathname === '/api/view' && request.method() === 'POST') { const body = request.postDataJSON(); if (body.expectedDecisionRevision !== decisionRevision || body.expectedSelectionRevision !== selectionRevision || body.expectedDataVersion !== dataVersion) return json({ code:'stale_revision', message:'Fixture preview changed.', nextStep:'Reload current context.', correlationId:'fixture-preview-conflict' }, 409); return json({ viewContext:viewContext(), preview: { revision, previewKind: 'ResourcePreview', canExecute: true, items: [], issues: [] } }); }
      if (pathname === '/api/operations' && request.method() === 'POST') {
        const body = request.postDataJSON();
        if (body.action === 'UnknownStatusTest') { unknownOperationCount++; return json({ job:{ jobId:body.operationId, status:'FutureStatus' } }); }
        if (body.expectedDecisionRevision !== decisionRevision || body.expectedSelectionRevision !== selectionRevision || body.expectedDataVersion !== dataVersion) return json({ code:'stale_revision', message:'Fixture operation changed.', nextStep:'Reload current context.', correlationId:'fixture-operation-conflict' }, 409);
        if (body.action === 'WindowsSettingsSubmit') { settingsSubmitRequest = body; return json({ job: { jobId: body.operationId, action: body.action, status: 'Running', canCancel: false } }, 202); }
        if (body.action === 'SaveSelection') {
          const selected = new Set(body.args.selectedItemIds);
          inventory.forEach(row => { row.selected = selected.has(row.itemId); if (!row.selected) row.reason = (body.args.unselectedItems || []).find(item => item.itemId === row.itemId)?.reason || ''; });
          return json({ jobId:body.operationId, revision: ++revision, selectionRevision: ++selectionRevision, dataVersion: dataVersion = `fixture-catalog-${selectionRevision}`, status: 'Saved' });
        }
        return json({ job: { jobId: body.operationId, action: body.action, status: 'Running', canCancel: false } }, 202);
      }
      if (/^\/api\/jobs\/[^/]+\/cancel$/.test(pathname) && request.method() === 'POST') {
        cancelRequest = { pathname, method: request.method(), headers: request.headers(), body: request.postDataJSON() };
        return json({ job: { jobId: 'fixture-job', workspace:root, pairId:'fixture-pair', role:'Manager', sessionId:'fixture-session', contextId, startedRevision:1, action: 'AssistiveReport', status: 'CancelRequested', canCancel: true } });
      }
      if (pathname === '/api/jobs/fixture-job' && request.method() === 'GET') {
        reconnectRequest = { pathname, method: request.method(), headers: request.headers() };
        return json({ jobId: 'fixture-job', workspace:root, pairId:'fixture-pair', role:'Manager', sessionId:'fixture-session', contextId, startedRevision:1, action: 'AssistiveReport', status: 'CancelRequested', canCancel: true });
      }
      if (pathname === '/api/jobs' && request.method() === 'GET') return jobsPollFailure ? json({code:'worker_limit',message:'Fixture job worker interrupted.',correlationId:'fixture-poll-error',nextStep:'Retry later.'},503) : json({ items: jobsSnapshot });
      if (/^\/api\/jobs\/.*\/reports\/\d+\/open$/.test(pathname) && request.method() === 'POST') {
        reportOpenRequest = { method: request.method(), headers: request.headers(), body: request.postDataJSON() };
        return json({ status: 'Opened', SHA256: reportOpenRequest.body.SHA256 });
      }
      return json({ message: `Unhandled UI test route: ${request.method()} ${pathname}` }, 404);
    });

    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });
    try { await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.session && window.WsmConsole.state.token, { timeout:15000 }); } catch (error) { throw new Error(`${error.message}; pageerror=${JSON.stringify(errors)}; diagnostics=${JSON.stringify(diagnostics)}; text=${(await page.locator('body').innerText()).slice(0,1000)}`); }
    await page.waitForFunction(() => !document.querySelector('#view-overview').hidden);
    assert.equal(await page.locator('#workflow-steps .step-title').first().textContent(), '來源盤點');
    assert.deepEqual(await page.locator('#metrics .metric-value').allTextContents(), ['125 項', '125 項', '未知', '未測試']);
    assert.doesNotMatch(await page.locator('#metrics').textContent(), /NotMeasured|NotTested|Unknown/);
    assert.match(await page.locator('#workflow-steps').textContent(), /目前世代已接受的 Restore/);
    assert.match(await page.locator('#overview-provenance').textContent(), /階段產生時間（ProducedUtc；非目標觀測時間）2026-10-11T01:02:03Z/);
    assert.match(await page.locator('#overview-provenance').textContent(), /交付識別碼 fixture-delivery/);
    if (process.env.WSM_SCREENSHOT_DIR) { fs.mkdirSync(process.env.WSM_SCREENSHOT_DIR, { recursive:true }); await page.screenshot({ path:path.join(process.env.WSM_SCREENSHOT_DIR,'overview-desktop.png'), fullPage:true }); }
    for (const [name, expected] of Object.entries({ OsProvidedCapture: '擷取 OS 提供排程工作證據', OsProvidedBaseline: '建立 OS 提供排程工作可信基準', OsProvidedReview: '比對 OS 提供排程工作證據', OsProvidedSubmit: '提交 OS 提供排程工作審閱' })) {
      assert.equal(await page.evaluate(action => window.WsmConsole.actionLabel(action), name), expected);
    }
    assert.equal(await page.evaluate(() => window.WsmConsole.actionGroup('OsProvidedCapture')), 'Source');
    assert.equal(await page.evaluate(() => window.WsmConsole.actionGroup('OsProvidedReview')), 'Manager');
    assert.match(await page.evaluate(() => window.WsmConsole.actionGuidance('OsProvidedSubmit').output), /不代表 vendor verification/);
    await page.evaluate(() => window.WsmConsole.navigate('operations'));
    await page.locator('#action-picker').selectOption('OsProvidedSubmit');
    assert.equal(await page.locator('#param-0').inputValue(), '7');
    assert.equal(await page.locator('#param-0').getAttribute('readonly'), '');
    assert.match(await page.locator('#action-description').textContent(), /角色只是操作上下文/);
    await page.locator('[data-view="inventory"]').first().click();
    try { await page.waitForFunction(() => window.WsmConsole.state.inventory.length === 125, { timeout:5000 }); } catch (error) { throw new Error(`${error.message}; hash=${await page.evaluate(()=>location.hash)}; state=${JSON.stringify(await page.evaluate(()=>({currentView:window.WsmConsole.state.currentView,inventory:window.WsmConsole.state.inventory.length,context:window.WsmConsole.state.session,errors:document.querySelector('#error-summary').innerText,notice:document.querySelector('#notice').innerText})))}`); }
    assert.equal(await page.locator('#inventory-rows tr').count(), 50);
    assert.equal(await page.locator('#inventory-rows img').count(), 0);
    assert.match(await page.locator('#selection-summary').textContent(), /125/);

    safeEmptyState = true; dataVersion = 'fixture-catalog-no-assistive'; await page.evaluate(() => window.WsmConsole.refreshSession(false));
    await page.evaluate(() => window.WsmConsole.loadView('inventory', true));
    assert.match(await page.locator('#state-message').textContent(), /尚未啟用 Assistive/);
    assert.equal(await page.locator('#save-selection').isDisabled(), true);
    await page.locator('#state-message button').click();
    await page.waitForFunction(() => window.WsmConsole.state.activeAction === 'AssistiveEnable');
    assert.equal(await page.locator('#action-picker').inputValue(), 'AssistiveEnable');
    safeEmptyState = false; dataVersion = 'fixture-catalog-1'; await page.evaluate(() => window.WsmConsole.refreshSession(false));
    await page.locator('[data-view="inventory"]').first().click();
    try { await page.waitForFunction(() => window.WsmConsole.state.inventory.length === 125, { timeout:5000 }); } catch (error) { throw new Error(`${error.message}; hash=${await page.evaluate(()=>location.hash)}; state=${JSON.stringify(await page.evaluate(()=>({currentView:window.WsmConsole.state.currentView,inventory:window.WsmConsole.state.inventory.length,context:window.WsmConsole.state.session,errors:document.querySelector('#error-summary').innerText,notice:document.querySelector('#notice').innerText})))}`); }

    await page.locator('.spec-review-button').first().click();
    await page.waitForFunction(() => !document.querySelector('#spec-review-panel').hidden);
    assert.match(await page.locator('#spec-review-panel').textContent(), /BusinessChecks/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /Task\/Actions\/Action\[0\]\/Arguments/);
    assert.match(await page.locator('#spec-review-counts').textContent(), /排程動作：2/);
    assert.doesNotMatch(await page.locator('#spec-review-panel').textContent(), /must not appear|<secret>/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /\*:443:fixture\.example/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /custom\+http/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /ManualBindingProtocolReview\[0\]/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /C:\\Sites\\Portal/);
    assert.match(await page.locator('#spec-review-panel').textContent(), /E:\\Sites\\Portal/);
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
    assert.deepEqual(await page.locator('#parameter-fields [data-parameter="Protocol"]').evaluateAll(nodes => nodes.map(node => node.value)), ['custom+http']);
    assert.deepEqual(await page.locator('#parameter-fields [data-parameter="SslFlagsPresent"]').evaluateAll(nodes => nodes.map(node => node.value)), ['false']);
    assert.equal(await page.locator('#parameter-fields [data-parameter="Value"]').first().inputValue(), 'E:\\Sites\\Portal');
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
      try { await page.waitForFunction(old => window.WsmConsole.state.session.contextId !== old, oldContext, { timeout:5000 }); } catch (error) { throw new Error(`${error.message}; UI error: ${await page.locator('#error-summary').textContent()}; session: ${JSON.stringify(await page.evaluate(() => ({ ...window.WsmConsole.state.session })))}`); }
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

    await page.evaluate(() => window.WsmConsole.renderFiles({ rows: [{ originalPath: 'C:\\Source\\settings.ini', preservedPath: 'D:\\Preserved\\settings.ini', effectivePath: null, sourceHash: 'source-hash', observedHash: 'producer-readback-hash', existingTargetHash: 'producer-conflict-hash' }] }));
    const fileCells = await page.locator('#file-rows tr').first().locator('td').allTextContents();
    assert.match(fileCells[0], /C:\\Source/);
    assert.match(fileCells[1], /D:\\Preserved/);
    assert.equal(fileCells[2].trim(), '未知（未觀測）');
    assert.match(fileCells[3], /來源 SHA-256：source-hash/);
    assert.match(fileCells[3], /讀回 SHA-256：producer-readback-hash/);
    assert.match(fileCells[3], /衝突 SHA-256：producer-conflict-hash/);

    await page.locator('[data-view="jobs"]').first().click();
    await page.waitForFunction(() => location.hash === '#jobs');
    await page.waitForFunction(() => document.querySelector('#job-id-lookup'));
    await page.locator('#job-id-lookup').focus();
    await page.evaluate(() => { window.__emptyJobCard = document.querySelector('#job-list .empty-card'); });
    await page.evaluate(() => window.WsmConsole.refreshJobs({ background:true }));
    assert.equal(await page.evaluate(() => document.querySelector('#job-list .empty-card') === window.__emptyJobCard), true, 'unchanged polling does not rebuild the list');
    assert.equal(await page.evaluate(() => document.activeElement.id), 'job-id-lookup', 'unchanged polling preserves keyboard focus');
    jobsPollFailure = true;
    await page.evaluate(() => window.WsmConsole.refreshJobs({ background:true }));
    assert.equal(await page.evaluate(() => document.activeElement.id), 'job-id-lookup', 'a background polling error does not move focus');
    assert.match(await page.locator('#notice').textContent(), /背景讀取作業狀態暫時失敗/);
    jobsPollFailure = false;
    await page.evaluate(() => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-job', { jobId: 'fixture-job', workspace: window.WsmConsole.state.session.workspace, pairId: 'fixture-pair', role:'Manager', sessionId:'fixture-session', contextId:'fixture-context-1', startedRevision:1, startedUtc:'2026-10-11T00:00:00Z', completedUtc:'2026-10-11T00:01:00Z', status: 'Succeeded', action: 'AssistiveReport', outputs: [{ Path: 'C:\\very\\long\\migration\\report.html' }], reportArtifacts: [{ Path: 'C:\\very\\long\\migration\\report.html', Label: 'fixture report', SHA256: 'report-hash' }] });
      window.WsmConsole.renderJobs();
    });
    assert.equal(await page.locator('#job-list .job-output dd').first().textContent(), 'C:\\very\\long\\migration\\report.html');
    assert.match(await page.locator('#job-list').textContent(), /管理報告/);
    const reportOpened = page.waitForResponse(response => /\/api\/jobs\/fixture-job\/reports\/0\/open$/.test(response.url()));
    await page.locator('#job-list button').filter({ hasText: '開啟報告' }).click();
    await reportOpened;
    await page.waitForFunction(() => window.WsmConsole.state.jobs.size === 1);
    assert.equal(reportOpenRequest.method, 'POST');
    assert.ok(reportOpenRequest.headers['x-wsm-token']);
    assert.deepEqual(reportOpenRequest.body, { SHA256: 'report-hash' });
    jobsSnapshot = await page.evaluate(() => { const current = window.WsmConsole.state.jobs.get('fixture-job'); return [current, { jobId:'fixture-other-job', workspace:current.workspace, pairId:current.pairId, role:current.role, sessionId:current.sessionId, contextId:current.contextId, startedRevision:current.startedRevision, status:'Running', action:'AssistiveReport' }]; });
    await page.locator('#job-list button').filter({ hasText: '開啟報告' }).focus();
    await page.evaluate(() => window.scrollTo(0, 350));
    const reportFocusScroll = await page.evaluate(() => window.scrollY);
    await page.evaluate(() => window.WsmConsole.refreshJobs({ background:true }));
    assert.equal(await page.evaluate(() => document.activeElement.dataset.focusKey), 'report:fixture-job:0', 'a changed background poll preserves report-action focus');
    assert.equal(await page.evaluate(() => window.scrollY), reportFocusScroll, 'a changed background poll preserves page scroll');

    await page.evaluate(() => {
      window.WsmConsole.state.jobs.set('fixture-job', { jobId: 'fixture-job', workspace:window.WsmConsole.state.session.workspace, pairId:'fixture-pair', role:'Manager', sessionId:'fixture-session', contextId:window.WsmConsole.state.session.contextId, startedRevision:1, jobId: 'fixture-job', status: 'Running', action: 'AssistiveReport', canCancel: true });
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
    await page.locator('#job-list button[data-focus-key="reconnect:fixture-job"]').click();
    assert.ok(reconnectRequest);
    assert.equal(reconnectRequest.pathname, '/api/jobs/fixture-job');
    assert.ok(reconnectRequest.headers['x-wsm-token']);
    assert.equal(await page.evaluate(() => window.WsmConsole.state.jobs.get('fixture-job').jobId), 'fixture-job');

    decisionRevision = 23;
    await page.evaluate(() => window.WsmConsole.refreshSession(false));
    const physicalPreviewHash = 'a'.repeat(64), semanticPreviewHash = 'b'.repeat(64);
    await page.evaluate(({ physicalPreviewHash, semanticPreviewHash, workspace, startedRevision }) => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-settings-preview', { jobId: 'fixture-settings-preview', status: 'Succeeded', action: 'WindowsSettingsPreviewExport', workspace, pairId:'fixture-pair', role:'Manager', sessionId:'fixture-session', contextId:window.WsmConsole.state.session.contextId, startedRevision, outputs: [{
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
    }, { physicalPreviewHash, semanticPreviewHash, workspace:root, startedRevision:revision });
    assert.match(await page.locator('#job-list').textContent(), /Safe setting one/);
    assert.match(await page.locator('#job-list').textContent(), /來源值 SHA-256/);
    assert.doesNotMatch(await page.locator('#job-list').textContent(), /DO-NOT-RENDER|<secret>/);
    jobsSnapshot = await page.evaluate(() => { const current = window.WsmConsole.state.jobs.get('fixture-settings-preview'); return [current, { jobId:'fixture-other-job', workspace:current.workspace, pairId:current.pairId, role:current.role, sessionId:current.sessionId, contextId:current.contextId, startedRevision:current.startedRevision, status:'Queued', action:'AssistiveReport' }]; });
    await page.locator('#job-list button').filter({ hasText: '使用此預覽準備設定審閱' }).focus();
    await page.evaluate(() => window.WsmConsole.refreshJobs({ background:true }));
    assert.equal(await page.evaluate(() => document.activeElement.dataset.focusKey), 'prefill-settings:fixture-settings-preview:23', 'a changed background poll preserves prefill-action focus');
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

    decisionRevision = 24;
    await page.evaluate(() => window.WsmConsole.refreshSession(false));
    await page.locator('[data-view="jobs"]').first().click();
    await page.evaluate(() => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-empty-settings-preview', { jobId: 'fixture-empty-settings-preview', workspace:window.WsmConsole.state.session.workspace, pairId:'fixture-pair', role:'Manager', sessionId:'fixture-session', contextId:window.WsmConsole.state.session.contextId, startedRevision:1, status: 'Succeeded', action: 'WindowsSettingsPreviewExport', outputs: [{
        Kind: 'AssistiveWindowsSettingsPreviewOutput', PairId: 'fixture-pair', SourceInventoryPath: 'C:\\WSM\\source.json', SourceInventoryHash: 'c'.repeat(64),
        TargetInventoryPath: 'C:\\WSM\\target.json', TargetInventoryHash: 'd'.repeat(64), PreviewPath: 'C:\\WSM\\empty-preview.json', PreviewFileHash: '4'.repeat(64),
        PreviewHash: '5'.repeat(64), ExpectedRevision: 24, ReviewWindowsSettings: false, RowCount: 0, Rows: []
      }] });
      window.WsmConsole.renderJobs();
    });
    await page.locator('#job-list button').filter({ hasText: '使用此預覽準備設定審閱' }).click();
    await page.waitForFunction(() => window.WsmConsole.state.activeAction === 'WindowsSettingsSubmit' && document.querySelector('[data-parameter="PreviewPath"]')?.value === 'C:\\WSM\\empty-preview.json' && document.querySelector('[data-parameter="ExpectedRevision"]')?.value === '24' && document.querySelector('[data-parameter="ReviewWindowsSettings"]')?.value === 'false');
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
      window.WsmConsole.state.jobs.set('fixture-preparation-preview', { jobId: 'fixture-preparation-preview', workspace:window.WsmConsole.state.session.workspace, pairId:window.WsmConsole.state.session.pairId, role:window.WsmConsole.state.session.role, sessionId:window.WsmConsole.state.session.sessionId, contextId:window.WsmConsole.state.session.contextId, startedRevision:window.WsmConsole.state.session.revision, status: 'Succeeded', action: 'PreparationPreview', outputs: [{ Kind: 'AssistivePreparationPreview', RowCount: 1, Rows: [{ RequirementId: 'requirement-one', ProviderSoftwareId: 'runtime-one', ExpectedVersion: '9.4', Architecture: 'x64', RequiredPhase: 'BeforeRestore', Decision: 'External', Certainty: 'High', ConsumerItemIds: ['consumer-one'], ContextHash: '3'.repeat(64), SecretValue: 'DO-NOT-RENDER' }] }] });
      window.WsmConsole.renderJobs();
    });
    assert.match(await page.locator('#job-list').textContent(), /runtime-one/);
    assert.match(await page.locator('#job-list').textContent(), /BeforeRestore/);
    assert.doesNotMatch(await page.locator('#job-list').textContent(), /DO-NOT-RENDER/);

    decisionRevision = 31;
    await page.evaluate(() => window.WsmConsole.refreshSession(false));
    await page.evaluate(({ workspace, startedRevision }) => {
      window.WsmConsole.state.jobs.clear();
      window.WsmConsole.state.jobs.set('fixture-requirement-review', { jobId: 'fixture-requirement-review', status: 'Succeeded', action: 'RequirementReview', workspace, pairId:'fixture-pair', role:'Manager', sessionId:'fixture-session', contextId:window.WsmConsole.state.session.contextId, startedRevision, outputs: [{
        Kind: 'AssistiveRequirementReview', Status: 'Previewed', PairId: 'fixture-pair', ExpectedRevision: 31, ReviewHash: '6'.repeat(64), RowCount: 2,
        Rows: [
          { RequirementId: 'req-one', Type: 'Runtime', ProviderSoftwareId: 'provider-one', ProviderItemId: 'source-one', ExternalId: '', ExpectedVersion: '9.4', Architecture: 'x64', RequiredPhase: 'BeforeRestore', Decision: 'Required', Certainty: 'High', ConsumerItemIds: ['consumer-one'], ContextHash: '7'.repeat(64), Context: { Secret: 'DO-NOT-RENDER' }, SourceProof: { Evidence: 'DO-NOT-RENDER' }, Arguments: 'DO-NOT-RENDER' },
          { RequirementId: 'req-two', Type: 'Service', ProviderSoftwareId: '', ProviderItemId: '', ExternalId: 'external-2', ExpectedVersion: '', Architecture: 'x64', RequiredPhase: 'AfterRestore', Decision: 'Pending', Certainty: 'Medium', ConsumerItemIds: [], ContextHash: '8'.repeat(64), RawXml: '<secret>DO-NOT-RENDER</secret>' }
        ], SecretToken: 'DO-NOT-RENDER'
      }] });
      window.WsmConsole.renderJobs();
    }, {workspace:root, startedRevision:revision});
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
    while (inventory.length < 2501) { const index=inventory.length; inventory.push({itemId:`large-fixture-${index}`,name:`Large fixture ${index}`,category:'Runtime',selected:false,selectable:true,approvalStatus:'Pending',executionStatus:'NotObserved'}); }
    await page.locator('[data-view="inventory"]').first().click();
    await page.waitForFunction(() => window.WsmConsole.state.inventory.length === 2501);
    assert.equal(await page.locator('#inventory-rows tr').count(),50);
    assert.match(await page.locator('#inventory-count').textContent(),/2501 筆符合篩選/);
    await page.setViewportSize({ width: 320, height: 720 });
    await page.waitForTimeout(100);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'page overflow at 320px');
    if (process.env.WSM_SCREENSHOT_DIR) await page.screenshot({ path:path.join(process.env.WSM_SCREENSHOT_DIR,'inventory-2501-320.png'), fullPage:true });
    await page.keyboard.press('Tab');
    assert.ok(await page.evaluate(() => document.activeElement !== document.body));
    await page.locator('[data-view="operations"]').first().click();
    await page.waitForFunction(() => window.WsmConsole.state.actions.length > 90);
    await page.locator('#action-picker').selectOption('HttpIntegrityProbe');
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'operation panel reflows at 320px');
    viewReads.length=0;
    await page.goto(`${url}#files`, { waitUntil:'domcontentloaded' });
    await page.waitForFunction(() => location.hash==='#files' && window.WsmConsole.state.currentView==='files');
    assert.ok(viewReads.includes('files'));
    assert.equal(viewReads.includes('overview'),false,'a deep link loads only its selected view');
    await page.goto(`${url}#invalid-route`, { waitUntil:'domcontentloaded' });
    await page.waitForFunction(() => location.hash==='#overview' && window.WsmConsole.state.currentView==='overview');
    await page.locator('[data-view="inventory"]').first().click();
    await page.locator('[data-view="files"]').first().click();
    await page.goBack(); await page.waitForFunction(() => location.hash==='#inventory');
    await page.goForward(); await page.waitForFunction(() => location.hash==='#files');
    const pendingId = await page.evaluate(async () => { const request=window.WsmConsole.buildOperationRequest('UnknownStatusTest',{},window.WsmConsole.state.session.revision); try { await window.WsmConsole.endpoint('/api/operations',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(request)}); } catch (_) {} return request.operationId; });
    assert.equal(await page.evaluate(() => window.WsmConsole.state.pendingOperation.operationId),pendingId);
    const persisted = await page.evaluate(workspace => JSON.parse(sessionStorage.getItem(`wsm.pending.v1.${encodeURIComponent(workspace.toLowerCase())}`)),root);
    assert.equal(persisted.operationId,pendingId);
    assert.deepEqual(Object.keys(persisted).sort(),['action','contextId','createdUtc','expectedDataVersion','expectedDecisionRevision','expectedRevision','expectedSelectionRevision','operationId','pairId','workspace'].sort());
    assert.equal(unknownOperationCount,1);
    await page.reload({waitUntil:'domcontentloaded'});
    await page.waitForFunction(id => window.WsmConsole.state.pendingOperation && window.WsmConsole.state.pendingOperation.operationId===id,pendingId);
    assert.equal(unknownOperationCount,1,'same-origin reload performs a lookup only, never a second write');
    await page.locator('[data-view="jobs"]').first().click();
    await page.waitForFunction(() => location.hash==='#jobs');
    assert.match(await page.locator('#job-list').textContent(),new RegExp(pendingId));
    await page.setViewportSize({width:1280,height:900});
    await page.goto(`${url}ui/guide.html`, { waitUntil: 'domcontentloaded' });
    if (process.env.WSM_SCREENSHOT_DIR) await page.screenshot({ path:path.join(process.env.WSM_SCREENSHOT_DIR,'operation-guide-desktop.png'), fullPage:true });
    assert.match(await page.locator('main').textContent(), /Start-ServerMigration\.ps1/);
    assert.match(await page.locator('main').textContent(), /固定的 WorkRoot/);
    assert.match(await page.locator('main').textContent(), /Windows Server Core/);
    assert.match(await page.locator('main').textContent(), /文字選單/);
    assert.deepEqual(errors, []);
    console.log('PASS: Edge UI fixture with mocked APIs; 2,501-item pagination, eight routes and deep links, stale context/cache guards, pending-write reload lookup, typed review prefill, report-open POST, actor provenance, 320px reflow, and background poll focus/scroll preservation. Actual loopback bridge transport: NotTested; main must verify separately.');
  } finally {
    if (browser) await browser.close();
    if (server.listening) await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
