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
let scenario = 'rejected-422';
let postCount = 0;
const postIds = [];
let recoveryCount = 0;
let lastOperationId = '';
let browserPostCount = 0;
const session = { token:'pending-ui-token',sessionId:'pending-ui-session',contextId:'pending-ui-context',hostName:'測試主機',role:'Source',workspace:'C:\\migration\\pending-fixture',pairId:'pair-1',revision:1,decisionRevision:0,selectionRevision:0,sourceSelectionRevision:0,dataVersion:1,principal:'fixture' };
const viewContext = { readUtc:'2026-10-13T00:00:00Z',sessionId:session.sessionId,contextId:session.contextId,pairId:session.pairId,role:session.role,revision:session.revision,decisionRevision:session.decisionRevision,selectionRevision:session.selectionRevision,sourceSelectionRevision:session.sourceSelectionRevision,dataVersion:session.dataVersion };
const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://127.0.0.1');
  const file = files.get(url.pathname);
  if (file) { response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' }); fs.createReadStream(file).pipe(response); return; }
  const send = (status, body) => { response.writeHead(status, { 'Content-Type':'application/json' }); response.end(JSON.stringify(body)); };
  if (url.pathname === '/api/session') return send(200, session);
  if (url.pathname === '/api/context' && request.method === 'GET') return send(200, { roles:['Source','Manager','Target'],pairs:[{pairId:'pair-1',label:'測試配對'}],role:'Source',pairId:'pair-1',contextId:session.contextId,revision:1,decisionRevision:0,selectionRevision:0,dataVersion:1 });
  if (url.pathname === '/api/wizard') return send(200, { kind:'WizardProjection',role:'Source',intentRequired:false,state:{role:'Source',step:'start'},revision:0,currentStep:'start',groups:[],gates:[],missingFields:[],context:{} });
  if (url.pathname === '/api/view' && request.method === 'GET') {
    const action = url.searchParams.get('action');
    if (action === 'actions') return send(200, { viewContext,actions:[{action:'FixtureWrite',label:'測試操作',roleAvailable:true,parameters:[]}] });
    return send(200, { viewContext,items:[],actions:[] });
  }
  if (url.pathname === '/api/view' && request.method === 'POST') return send(200, { viewContext,canExecute:true,revision:1,items:[],issues:[] });
  if (url.pathname === '/api/operations' && request.method === 'POST') {
      postCount++;
    let body=''; request.on('data', chunk => { body += chunk; }); request.on('end', () => {
      const submitted=JSON.parse(body); lastOperationId=submitted.operationId; postIds.push(submitted.operationId);
      if (scenario === 'rejected-422-marker') return send(422,{code:'operation_failed',submissionRejected:true,message:'Fixture rejection detail'});
      if (scenario === 'unmarked-422') return send(422,{code:'operation_failed',message:'Fixture failure may have been persisted'});
      if (scenario === 'worker-400') return send(400,{code:'operation_failed',message:'Worker setup failed after persistence'});
      if (scenario === 'invalid-json-4xx') { response.writeHead(422,{'Content-Type':'application/json'}); return response.end('{invalid-json'); }
      if (scenario === 'rejected-409') return send(409,{code:'stale_revision',submissionRejected:true,message:'Fixture revision conflict'});
      if (scenario === 'rejected-401') return send(401,{code:'invalid_token',message:'Fixture token expired'});
      if (scenario === 'accepted-failed') return send(202,{jobId:submitted.operationId,status:'Failed',revision:1,action:submitted.action,pairId:session.pairId});
      if (scenario === 'disconnect') return response.destroy();
      return send(500,{code:'unexpected_test_scenario'});
    });
    return;
  }
  if (url.pathname.startsWith('/api/jobs/')) {
    recoveryCount++;
    if ((scenario === 'disconnect' && recoveryCount >= 2) || (scenario === 'unmarked-422' && recoveryCount >= 2) || (scenario === 'worker-400' && recoveryCount >= 1)) return send(200,{jobId:lastOperationId,status:'Failed',revision:1,action:'FixtureWrite',pairId:session.pairId});
    return send(200,{job:null});
  }
  if (url.pathname === '/api/jobs') return send(200,{items:[]});
  return send(404,{code:'not_found',message:'No fixture route'});
});

(async () => {
  let browser;
  try {
    await new Promise((resolve,reject)=>server.listen(0,'127.0.0.1',resolve).once('error',reject));
    browser=await chromium.launch({headless:true,executablePath:process.env.WSM_EDGE||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
    const context=await browser.newContext({viewport:{width:1280,height:900}}), page=await context.newPage();
    page.on('request',request=>{if(new URL(request.url()).pathname==='/api/operations'&&request.method()==='POST'){browserPostCount++;try{lastOperationId=request.postDataJSON().operationId;}catch(_){}}});
    await page.goto(`http://127.0.0.1:${server.address().port}/`,{waitUntil:'networkidle'});
    await page.waitForFunction(()=>window.WsmConsole&&window.WsmConsole.state.session);
    await page.evaluate(()=>window.WsmConsole.navigate('operations'));
    await page.locator('#action-picker').selectOption('FixtureWrite');

    const submit = async () => {
      await page.locator('#preview-operation').click();
      await page.locator('#operation-confirm').check();
      await page.locator('#operation-form').evaluate(form=>form.requestSubmit());
      await page.waitForFunction(()=>!window.WsmConsole.state.busy);
    };
    const pending = () => page.evaluate(()=>!!window.WsmConsole.state.pendingOperation);
    const errorText = () => page.locator('#error-summary').innerText();
    const freshActionPage = async () => { await page.evaluate(()=>sessionStorage.clear()); await page.reload({waitUntil:'networkidle'}); await page.waitForFunction(()=>window.WsmConsole&&window.WsmConsole.state.session); await page.evaluate(()=>window.WsmConsole.navigate('operations')); await page.locator('#action-picker').selectOption('FixtureWrite'); };

    for (const [name, expectedCode] of [['rejected-422-marker','operation_failed'],['rejected-409','stale_revision']]) {
      scenario=name; postCount=0; recoveryCount=0; lastOperationId=''; postIds.length=0;
      await freshActionPage();
      await submit();
      assert.equal(postCount,1,`${name} should send once`);
      assert.equal(await pending(),false,`${name} is a definitive rejection and must clear pending state`);
      assert.doesNotMatch(await errorText(),/結果尚未確認|查詢這次操作/,`${name} must not be presented as an unknown outcome`);
      if (expectedCode==='operation_failed') assert.match(await errorText(),/工作執行失敗/);
      if (expectedCode==='stale_revision') assert.match(await errorText(),/重新預覽/);
    }

    // 6a8e6bf: a 401 invalid_token on a write keeps the unknown operation id and requires an explicit reconnect, so the same
    // operation can be queried afterwards (the 401 may answer a retry of a request that already ran). It is never resent.
    scenario='rejected-401'; postCount=0; recoveryCount=0; lastOperationId=''; postIds.length=0;
    await freshActionPage();
    await submit();
    assert.equal(postCount,1,'rejected-401 should send once');
    assert.equal(await page.evaluate(()=>window.WsmConsole.state.pendingOperation&&window.WsmConsole.state.pendingOperation.operationId),postIds[0],'rejected-401 must keep the exact unknown operation id for a later query');
    assert.equal(await page.evaluate(()=>window.WsmConsole.state.sessionReconnectRequired),true,'rejected-401 must require an explicit reconnect');
    assert.equal(postCount,1,'rejected-401 must not resend the write');

    scenario='unmarked-422'; postCount=0; recoveryCount=0; lastOperationId='';
    await freshActionPage();
    await submit();
    assert.equal(await pending(),true,'unmarked operation_failed must not be assumed rejected');
    assert.equal(recoveryCount,1,'unmarked 422 should first query the exact operation automatically');
    const uncertainId=await page.evaluate(()=>window.WsmConsole.state.pendingOperation.operationId);
    assert.doesNotMatch(await errorText(),new RegExp(uncertainId),'uncertain operation id must be hidden from the ordinary message');
    const screenshotRoot=path.join(root,'work','wizard-pending'); fs.mkdirSync(screenshotRoot,{recursive:true}); await page.screenshot({path:path.join(screenshotRoot,'unknown-result.png'),fullPage:true});
    await page.locator('#error-summary button').click();
    await page.waitForFunction(()=>!window.WsmConsole.state.pendingOperation);
    assert.equal(postCount,1,'manual same-operation query must not resubmit');
    assert.equal(await page.evaluate(id=>window.WsmConsole.state.jobs.has(id),uncertainId),true,'the query should recover the same terminal job');

    scenario='worker-400'; postCount=0; recoveryCount=0; lastOperationId='';
    await freshActionPage();
    await submit();
    assert.equal(postCount,1,'a post-persistence 400 failure should not be retried');
    assert.equal(recoveryCount,1,'the client should query the exact operation after unmarked operation_failed');
    assert.equal(await pending(),false,'an exact Failed job result resolves the pending operation');
    assert.equal(await page.evaluate(id=>window.WsmConsole.state.jobs.has(id),lastOperationId),true,'the failed durable job should be retained for display');

    scenario='invalid-json-4xx'; postCount=0; recoveryCount=0; lastOperationId='';
    await freshActionPage();
    await submit();
    assert.equal(postCount,1,'invalid JSON response must not cause a retry');
    assert.equal(await recoveryCount,1,'invalid JSON should trigger query of the submitted operation');
    assert.equal(await pending(),true,'an unparseable 4xx response is not proof that the operation was rejected');

    scenario='accepted-failed'; postCount=0; recoveryCount=0; postIds.length=0;
    await freshActionPage();
    await submit();
    assert.equal(postCount,1,'an accepted terminal failure is still a known job result');
    assert.equal(await pending(),false,'accepted terminal failure should clear pending state');

    scenario='disconnect'; postCount=0; recoveryCount=0; lastOperationId=''; postIds.length=0; browserPostCount=0;
    await freshActionPage();
    await page.route('**/api/operations',route=>route.abort('failed'));
    await submit();
    assert.equal(browserPostCount,1,`unknown transport outcome must never retry the write (browser observed ${browserPostCount} requests)`);
    assert.equal(await pending(),true,'unknown transport outcome must retain the exact pending operation');
    assert.match(await errorText(),/結果尚未確認/);
    assert.doesNotMatch(await errorText(),new RegExp(lastOperationId),'operation identifier must stay out of the normal error message');
    assert.equal(await page.locator('#error-summary details').count(),1,'technical identifier should be collapsed');
    assert.equal(await page.locator('#error-summary button').innerText(),'查詢這次操作');
    await page.locator('#error-summary button').click();
    await page.waitForFunction(()=>!window.WsmConsole.state.pendingOperation);
    assert.equal(browserPostCount,1,'querying the exact operation must not submit it again');
    assert.equal(lastOperationId,await page.evaluate(()=>window.WsmConsole.state.jobs.keys().next().value),'recovery must resolve the same operation id');
    console.log('Pending UI checks passed: marked rejection, unmarked 422/400 and invalid JSON recovery, pre-auth rejection, accepted Failed result, and disconnect query without resubmission.');
  } finally { if(browser)await browser.close(); await new Promise(resolve=>server.close(resolve)); }
})().catch(error=>{console.error(error);process.exitCode=1;});
