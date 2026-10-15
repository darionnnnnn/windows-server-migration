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
  ['/ui/console.css', path.join(root, 'src/ui/console.css')],
  ['/ui/nonc.js', path.join(root, 'src/ui/nonc.js')]
]);
const server = http.createServer((request, response) => {
  const file = files.get(new URL(request.url, 'http://127.0.0.1').pathname);
  if (!file) { response.writeHead(404); response.end('Not found'); return; }
  response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' });
  fs.createReadStream(file).pipe(response);
});

function fixture(start, finish, options = {}) {
  let session = Object.assign({}, start), expireNextSession = false, expiredOnce = false, reconnectReturned = false, failReconnectOnce = false, failWizardOnce = !!options.failWizardAfterReconnect;
  const requests = [];
  return {
    requests,
    expire() { expireNextSession = true; },
    failNextReconnect() { failReconnectOnce = true; },
    route(route) {
      const request = route.request(), url = new URL(request.url()), method = request.method(), body = method === 'POST' ? request.postDataJSON() || {} : {};
      requests.push({ method, path: url.pathname, body });
      const json = value => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(value) });
      if (url.pathname === '/api/session' && method === 'GET') {
        if (expireNextSession) { expireNextSession = false; expiredOnce = true; return route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ code: 'invalid_token', message: 'fixture session expired' }) }); }
        if (expiredOnce && failReconnectOnce) { failReconnectOnce = false; return route.fulfill({ status: 503, contentType: 'application/json', body: JSON.stringify({ message: 'fixture reconnect unavailable' }) }); }
        const latest = expiredOnce && finish ? finish : start;
        session = Object.assign({}, latest); reconnectReturned = expiredOnce;
        return json(latest);
      }
      if (url.pathname === '/api/context' && method === 'GET') { const contextSession = Object.assign({}, session, reconnectReturned && options.contextAfterReconnect || {}); return json({ roles: [contextSession.role], pairs: [{ pairId: contextSession.pairId, label: 'fixture pair' }], role: contextSession.role, pairId: contextSession.pairId, contextId: contextSession.contextId, revision: contextSession.revision, decisionRevision: contextSession.decisionRevision, selectionRevision: contextSession.selectionRevision, dataVersion: contextSession.dataVersion, inventoryRevision: contextSession.inventoryRevision, materialVersion: contextSession.materialVersion, materialHash: contextSession.materialHash }); }
      if (url.pathname.startsWith('/api/wizard/nonc')) return json({ HasNonC: true, ProofAllowed: false, Preparation: { entries: [{ itemId: 'nonc-item', name: 'fixture NonC item' }] }, SourceChoices: {} });
      if (url.pathname.startsWith('/api/wizard/runtime')) return json({ role: session.role, pairId: session.pairId, contextId: session.contextId, viewContext: { revision: session.revision, decisionRevision: session.decisionRevision, selectionRevision: session.selectionRevision, dataVersion: session.dataVersion } });
      if (url.pathname === '/api/wizard' && method === 'GET') { if (reconnectReturned && failWizardOnce) { failWizardOnce = false; return route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ code: 'invalid_token', message: 'fixture wizard session expired' }) }); } return json({ role: session.role, workspaceRole: session.role, pairId: session.pairId, currentStep: 'start', nextStep: 'start', intentRequired: true, revision: session.revision, context: { decisionRevision: session.decisionRevision, selectionRevision: session.selectionRevision, dataVersion: session.dataVersion }, groups: [], gates: [], results: {} }); }
      if (url.pathname === '/api/jobs' && method === 'GET') return json({ jobs: [] });
      if (url.pathname.startsWith('/api/jobs/') && method === 'GET') return json({ jobId: decodeURIComponent(url.pathname.slice('/api/jobs/'.length)), status: 'Unknown' });
      if (url.pathname === '/api/wizard' && method === 'POST') return json({ saved: true, projection: { role: session.role, pairId: session.pairId } });
      if (url.pathname === '/api/operations' && method === 'GET') return json({ actions: [] });
      if (url.pathname === '/api/view') return json({ viewContext: { sessionId: session.sessionId, contextId: session.contextId, pairId: session.pairId, role: session.role, revision: session.revision, decisionRevision: session.decisionRevision, selectionRevision: session.selectionRevision, sourceSelectionRevision: session.sourceSelectionRevision, dataVersion: session.dataVersion, readUtc: new Date().toISOString() }, rows: [] });
      return json({});
    }
  };
}

function session(overrides = {}) {
  return Object.assign({ token: 'fixture-token', sessionId: 'fixture-session', contextId: 'context-old', role: 'Manager', workspace: 'C:\\fixture\\manager', pairId: 'pair-1', revision: 10, decisionRevision: 5, selectionRevision: 4, sourceSelectionRevision: 3, dataVersion: 7, principal: 'fixture-user' }, overrides);
}

async function pageFor(browser, api) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.route('**/api/**', route => api.route(route));
  await page.goto(`http://127.0.0.1:${server.address().port}/#wizard`, { waitUntil: 'networkidle' });
  await page.waitForFunction(() => window.WsmConsole?.state?.session?.contextId);
  return page;
}

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });

    const oldSession = session({ role: 'Source', workspace: 'C:\\fixture\\source' }), sameDataNewContext = session({ role: 'Source', workspace: 'C:\\fixture\\source', contextId: 'context-new', token: 'fresh-token', revision: 11 });
    const api = fixture(oldSession, sameDataNewContext), page = await pageFor(browser, api);
    await page.evaluate(() => {
      const s = window.WsmConsole.state, us = '\u001f';
      s.drafts.set('PrepareTransfer', { Destination: 'typed non-sensitive draft' });
      const key = ['Source', 'pair-1', 'item-1', 'spec-hash-1', 'source-hash-1'].join(us);
      s.wizardInputs.set('preparation:' + key + ':Manual/Path', 'preparation draft'); s.wizardPreparationDraftKey = key; s.wizardPreparationDirty = true;
      const runtimeIdentity = ['Source', 'pair-1', 'context-old'].join(us);
      s.wizardRuntimeInputs.set([runtimeIdentity, 'StartBackup', 'DeliveryMode'].join(us), 'Zip');
      s.pendingOperation = { operationId: 'unknown-write-1', action: 'StartBackup', workspace: 'C:\\fixture\\manager', pairId: 'pair-1', contextId: 'context-old' };
      const host = document.createElement('div'); host.id = 'reconnect-nonc-test'; document.body.appendChild(host);
      window.WsmNonCWizard.render(host, { context: { role: 'Source', workspace: 'C:\\fixture\\source', contextId: 'context-old', pairId: 'pair-1', dataVersion: 7 }, projection: { HasNonC: true, CurrentPlan: {}, Preparation: { entries: [{ itemId: 'nonc-item', name: 'fixture item' }] }, ProofAllowed: false }, markDirty() {}, submit: async () => ({ Status: 'UnknownWrite' }) });
      const input = host.querySelector('[data-nonc-field="sourceShareName"]'); input.value = 'nonc in-page draft'; input.dispatchEvent(new Event('input', { bubbles: true }));
    });
    assert.equal(await page.evaluate(() => window.WsmNonCWizard.hasDirty()), true, 'fixture creates a real private NonC dirty field');
    api.expire();
    await page.evaluate(() => window.WsmConsole.refreshSession(false));
    await page.getByRole('button', { name: '重新連線工作階段' }).waitFor();
    assert.equal(await page.evaluate(() => window.WsmConsole.state.drafts.get('PrepareTransfer').Destination), 'typed non-sensitive draft');
    await page.getByRole('button', { name: '重新連線工作階段' }).click();
    await page.waitForFunction(() => !window.WsmConsole.state.sessionReconnectRequired && window.WsmConsole.state.session.contextId === 'context-new');
    const preserved = await page.evaluate(() => {
      const s = window.WsmConsole.state, us = '\u001f', runtimeKey = [['Source', 'pair-1', 'context-new'].join(us), 'StartBackup', 'DeliveryMode'].join(us);
      const host = document.querySelector('#reconnect-nonc-test'), api = { context: { role: 'Source', workspace: 'C:\\fixture\\source', contextId: 'context-new', pairId: 'pair-1', dataVersion: 7 }, projection: { HasNonC: true, CurrentPlan: {}, Preparation: { entries: [{ itemId: 'nonc-item', name: 'fixture item' }] }, ProofAllowed: false }, markDirty() {}, submit: async () => ({ Status: 'UnknownWrite' }) };
      window.WsmNonCWizard.render(host, api);
      return { typed: s.drafts.get('PrepareTransfer')?.Destination, preparation: [...s.wizardInputs.entries()].find(([key]) => key.endsWith(':Manual/Path'))?.[1], runtime: s.wizardRuntimeInputs.get(runtimeKey), oldRuntimeStillPresent: [...s.wizardRuntimeInputs.keys()].some(key => key.includes('context-old')), nonc: host.querySelector('[data-nonc-field="sourceShareName"]')?.value, preview: s.preview, pending: s.pendingOperation?.operationId, storage: JSON.stringify([sessionStorage, localStorage].map(storage => Object.keys(storage).map(key => [key, storage.getItem(key)]))) };
    });
    assert.equal(preserved.typed, 'typed non-sensitive draft');
    assert.equal(preserved.preparation, 'preparation draft');
    assert.equal(preserved.runtime, 'Zip', 'runtime input is safely re-keyed from old contextId to freshly verified contextId');
    assert.equal(preserved.oldRuntimeStillPresent, false);
    assert.equal(preserved.nonc, 'nonc in-page draft', 'private NonC state rebinds only after exact workspace/role/pair/data version match');
    assert.equal(preserved.preview, null, 'reconnect invalidates prior preview');
    assert.equal(preserved.pending, 'unknown-write-1', 'unknown write keeps its original operation id');
    assert.doesNotMatch(preserved.storage, /typed non-sensitive draft|preparation draft|nonc in-page draft|Zip/, 'drafts are not written to Web Storage');
    assert.equal(api.requests.some(row => row.method === 'POST' && row.path === '/api/operations'), false, 'reconnect never automatically resends an operation');
    await page.close();

    const changedStart = session(), changedFinish = session({ contextId: 'context-new', role: 'Target', pairId: 'pair-2', workspace: 'D:\\other\\root', token: 'other-token', dataVersion: 8 });
    const changedApi = fixture(changedStart, changedFinish), changedPage = await pageFor(browser, changedApi);
    await changedPage.evaluate(() => { window.WsmConsole.state.drafts.set('Action', { Path: 'must not leak' }); });
    changedApi.expire(); await changedPage.evaluate(() => window.WsmConsole.refreshSession(false));
    await changedPage.getByRole('button', { name: '重新連線工作階段' }).waitFor();
    await changedPage.getByRole('button', { name: '重新連線工作階段' }).click();
    await changedPage.waitForFunction(() => window.WsmConsole.state.session.contextId === 'context-new' && window.WsmConsole.state.sessionDraftStale);
    assert.equal(await changedPage.evaluate(() => window.WsmConsole.state.drafts.size), 0, 'role/pair/work-root/data mismatch isolates the old draft from current forms');
    assert.match(await changedPage.locator('#error-summary').innerText(), /過期/);
    assert.equal(await changedPage.evaluate(() => window.WsmConsole.endpoint('/api/wizard', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }).then(() => false, () => true)), true, 'stale reconnect blocks writes until explicit discard');
    assert.equal(changedApi.requests.some(row => row.method === 'POST'), false, 'incompatible reconnect does not submit or auto-save');
    await changedPage.close();

    const retryStart = session({ role: 'Source', workspace: 'C:\\fixture\\source' }), retryFinish = session({ role: 'Source', workspace: 'C:\\fixture\\source', token: 'retry-token' });
    const retryApi = fixture(retryStart, retryFinish), retryPage = await pageFor(browser, retryApi);
    await retryPage.evaluate(() => { window.WsmConsole.state.drafts.set('PrepareTransfer', { Destination: 'retain for retry' }); window.WsmConsole.state.pendingOperation = { operationId: 'unknown-write-retry', action: 'StartBackup' }; });
    retryApi.expire(); await retryPage.evaluate(() => window.WsmConsole.refreshSession(false));
    await retryPage.getByRole('button', { name: '重新連線工作階段' }).waitFor();
    const sessionReadsBeforeFocus = retryApi.requests.filter(row => row.path === '/api/session').length;
    await retryPage.evaluate(() => window.dispatchEvent(new Event('focus')));
    assert.equal(retryApi.requests.filter(row => row.path === '/api/session').length, sessionReadsBeforeFocus, 'focus does not start an implicit reconnect');
    retryApi.failNextReconnect();
    await retryPage.getByRole('button', { name: '重新連線工作階段' }).click();
    await retryPage.getByText(/工作階段重新連線未完成/).waitFor();
    assert.equal(await retryPage.evaluate(() => window.WsmConsole.state.sessionReconnectRequired), true, 'failed handshake keeps reconnect gate active');
    assert.equal(await retryPage.evaluate(() => window.WsmConsole.state.token), null, 'failed handshake leaves token unusable');
    assert.equal(await retryPage.evaluate(() => window.WsmConsole.state.drafts.get('PrepareTransfer')?.Destination), 'retain for retry', 'failed handshake retains safe in-memory draft');
    assert.equal(await retryPage.evaluate(() => window.WsmConsole.endpoint('/api/wizard', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }).then(() => false, () => true)), true, 'failed handshake still blocks writes');
    await retryPage.getByRole('button', { name: '重新連線工作階段' }).click();
    await retryPage.waitForFunction(() => !window.WsmConsole.state.sessionReconnectRequired);
    assert.equal(await retryPage.evaluate(() => window.WsmConsole.state.drafts.get('PrepareTransfer')?.Destination), 'retain for retry', 'successful retry preserves compatible draft');
    assert.equal(await retryPage.evaluate(() => window.WsmConsole.state.pendingOperation?.operationId), 'unknown-write-retry', 'retry preserves unknown operation id');
    assert.equal(retryApi.requests.some(row => row.method === 'POST' && row.path === '/api/operations'), false, 'retry never resends an unknown write');
    await retryPage.close();

    const racingStart = session({ role: 'Source', workspace: 'C:\\fixture\\source' }), racingFinish = session({ role: 'Source', workspace: 'C:\\fixture\\source', contextId: 'context-new', token: 'racing-token' });
    const racingApi = fixture(racingStart, racingFinish, { contextAfterReconnect: { dataVersion: 8 } }), racingPage = await pageFor(browser, racingApi);
    await racingPage.evaluate(() => { window.WsmConsole.state.drafts.set('PrepareTransfer', { Destination: 'must not reappear after context race' }); });
    racingApi.expire(); await racingPage.evaluate(() => window.WsmConsole.refreshSession(false));
    await racingPage.getByRole('button', { name: '重新連線工作階段' }).waitFor();
    await racingPage.getByRole('button', { name: '重新連線工作階段' }).click();
    await racingPage.waitForFunction(() => window.WsmConsole.state.sessionDraftStale);
    assert.equal(await racingPage.evaluate(() => window.WsmConsole.state.session.dataVersion), 8, 'fixture changes data version in context response after session handshake');
    assert.equal(await racingPage.evaluate(() => window.WsmConsole.state.drafts.size), 0, 'context race isolates drafts before rendering current form');
    assert.equal(await racingPage.evaluate(() => window.WsmConsole.state.sessionReconnectRequired), false, 'fresh session remains connected while stale drafts are isolated');
    assert.equal(racingApi.requests.some(row => row.method === 'POST'), false, 'context race does not submit or auto-save');
    await racingPage.close();

    const identityStart = session({ role: 'Source', workspace: 'C:\\fixture\\source' }), identityFinish = session({ role: 'Source', workspace: 'C:\\fixture\\source', contextId: 'context-new', token: 'identity-token' });
    const identityApi = fixture(identityStart, identityFinish, { contextAfterReconnect: { role: 'Target', pairId: 'pair-2', contextId: 'context-switched' } }), identityPage = await pageFor(browser, identityApi);
    await identityPage.evaluate(() => { window.WsmConsole.state.drafts.set('PrepareTransfer', { Destination: 'must not cross context identity' }); });
    identityApi.expire(); await identityPage.evaluate(() => window.WsmConsole.refreshSession(false));
    await identityPage.getByRole('button', { name: '重新連線工作階段' }).waitFor();
    await identityPage.getByRole('button', { name: '重新連線工作階段' }).click();
    await identityPage.waitForFunction(() => window.WsmConsole.state.sessionDraftStale);
    assert.equal(await identityPage.evaluate(() => window.WsmConsole.state.session.dataVersion), identityFinish.dataVersion, 'context identity race keeps dataVersion unchanged');
    assert.equal(await identityPage.evaluate(() => window.WsmConsole.state.drafts.size), 0, 'role/pair/context switch isolates drafts even when dataVersion matches');
    assert.equal(identityApi.requests.some(row => row.method === 'POST'), false, 'context identity race never submits drafts');
    await identityPage.close();

    const wizardStart = session({ role: 'Source', workspace: 'C:\\fixture\\source' }), wizardFinish = session({ role: 'Source', workspace: 'C:\\fixture\\source', contextId: 'context-new', token: 'wizard-token' });
    const wizardApi = fixture(wizardStart, wizardFinish, { failWizardAfterReconnect: true }), wizardPage = await pageFor(browser, wizardApi);
    wizardApi.expire(); await wizardPage.evaluate(() => window.WsmConsole.refreshSession(false));
    await wizardPage.getByRole('button', { name: '重新連線工作階段' }).waitFor();
    await wizardPage.getByRole('button', { name: '重新連線工作階段' }).click();
    await wizardPage.waitForFunction(() => window.WsmConsole.state.session.contextId === 'context-new' && window.WsmConsole.state.token === null && window.WsmConsole.state.sessionReconnectRequired);
    await wizardPage.getByRole('button', { name: '重新連線工作階段' }).waitFor();
    assert.equal(await wizardPage.evaluate(() => window.WsmConsole.state.token), null, 'wizard 401 clears the newly received token');
    assert.equal(await wizardPage.evaluate(() => window.WsmConsole.state.sessionReconnectRequired), true, 'wizard 401 keeps explicit reconnect gate active');
    assert.equal(wizardApi.requests.filter(row => row.path === '/api/wizard' && row.method === 'GET').length >= 2, true, 'fixture reaches active wizard refresh after session/context handshake');
    await wizardPage.close();

    console.log('PASS: same-page 401 reconnect keeps compatible in-memory typed/preparation/runtime/NonC drafts, rekeys runtime data across a verified contextId change, isolates drafts after context identity/version races, retries failed reconnects safely, keeps the reconnect gate after active refresh failure, avoids focus-triggered reconnect, drops preview, blocks incompatible drafts, does not persist drafts or resend unknown writes. API fixture only; no native service/worker behavior is established by this test.');
  } finally { if (browser) await browser.close(); server.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
