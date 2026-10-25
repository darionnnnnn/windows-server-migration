const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { gotoConsole, reportFailure, deliverySummary } = require('./Browser-UiDelivery.js');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const repoRoot = path.resolve(__dirname, '..');
const screenshotDir = path.join(repoRoot, 'work', 'wizard-native');
fs.mkdirSync(screenshotDir, { recursive: true });
const testRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-native-wizard-'));
let readyPath, stopPath, workspacePath, child, browser, origin;
const records = [];

async function startServer(options = {}) {
  workspacePath=path.join(testRoot,options.seed?'workspace-seeded':'workspace');
  readyPath=path.join(testRoot,options.seed?'ready-seeded.json':'ready.json');
  stopPath=path.join(testRoot,options.seed?'stop-seeded':'stop');
  const psModulePath = path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules');
  const args=['-NoProfile','-File',path.join(__dirname,'Start-HtmlTestServer.ps1'),'-Workspace',workspacePath,'-ReadyPath',readyPath,'-StopFile',stopPath];if(options.seed)args.push('-Seed');
  child = spawn('powershell.exe', args, {
    windowsHide: true,
    env: { ...process.env, PSModulePath: psModulePath }
  });
  let logs = '';
  child.stdout.on('data', data => { logs += data.toString(); });
  child.stderr.on('data', data => { logs += data.toString(); });
  const deadline = Date.now() + 120000;
  while (!fs.existsSync(readyPath)) {
    if (Date.now() > deadline || child.exitCode !== null) throw new Error(logs || 'Native console did not start.');
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  origin = JSON.parse(fs.readFileSync(readyPath, 'utf8')).Url.replace(/\/$/, '');
}

async function stopServer() {
  if (!child || child.exitCode !== null) return;
  fs.writeFileSync(stopPath, 'stop');
  await new Promise(resolve => {
    const timer = setTimeout(() => { child.kill(); resolve(); }, 8000);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
  });
}

(async () => {
  try {
    await startServer();
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    let page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.addInitScript(()=>{window.__nativePageErrors=[];window.addEventListener('unhandledrejection',event=>window.__nativePageErrors.push(String(event.reason&&event.reason.stack||event.reason)));});
    page.on('request', request=>{if(new URL(request.url()).origin===origin&&request.method()==='POST'&&new URL(request.url()).pathname==='/api/wizard')records.push({method:'POST',status:null,requestBody:request.postDataJSON(),utc:new Date().toISOString()});});
    page.on('response', response => {
      const url = new URL(response.url());
      if (url.origin === origin && url.pathname === '/api/wizard') {
        const record={ method: response.request().method(), status: response.status(), utc:new Date().toISOString(), bodyPromise:response.text().catch(error=>JSON.stringify({bodyError:error.message})) };
        records.push(record);
        record.bodyPromise.then(value=>{record.body=value;delete record.bodyPromise;}).catch(error=>{record.body=JSON.stringify({bodyError:error.message});delete record.bodyPromise;});
      }
    });
    page.on('pageerror', error => records.push({ pageError: error.message }));
    await gotoConsole(page, origin, '/ui/index.html', { repoRoot, ready: p => p.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.wizard, null, { timeout: 30000 }) });
    assert.equal(await page.locator('#view-wizard').isVisible(), true);
    assert.equal(await page.locator('input[name="wizard-role"]').count(), 3, 'native projection must render actual available intent choices');
    const firstGet = records.find(record => record.method === 'GET');
    assert.ok(firstGet, 'real PowerShell handler should return initial wizard projection');
    const initial = JSON.parse((await firstGet.body).toString('utf8'));
    assert.equal(initial.kind, 'WizardProjection', `unexpected native projection: ${JSON.stringify(initial)}`);
    assert.equal(initial.intentRequired, true, 'fresh temporary workspace should not auto-enroll a role');

    const probeAccepted=page.waitForResponse(response=>new URL(response.url()).origin===origin&&new URL(response.url()).pathname==='/api/operations'&&response.request().method()==='POST');
    await page.locator('#developer-probe-button').click();
    const probeResponse=await probeAccepted;assert.equal(probeResponse.status(),202,await probeResponse.text());const probeRequest=probeResponse.request().postDataJSON();assert.equal(probeRequest.action,'DeveloperProbe');assert.deepEqual(probeRequest.args,{});
    const probeId=(await probeResponse.json()).job.jobId;assert.ok(probeId,'one-click probe should return an authoritative durable job id');
    let probeJob=null,pollResets=0;const probeDeadline=Date.now()+120000;while(Date.now()<probeDeadline){let record=null;try{record=await page.evaluate(async id=>{const value=await window.WsmConsole.endpoint(`/api/jobs/${encodeURIComponent(id)}`);return value&&(value.job||value);},probeId);}catch(error){/* an idempotent GET poll: an environmental loopback reset (the page reports connection_error) is retried and counted; any other error still fails */if(!/connection_error|無法連線本機服務|ERR_CONNECTION_RESET/.test(String(error&&error.message))||pollResets>=12)throw error;pollResets++;console.log('environmental loopback reset while polling the probe job (retry '+pollResets+')');await new Promise(resolve=>setTimeout(resolve,500));continue;}if(record&&record.jobId===probeId&&['Succeeded','ReviewRequired','Failed','Cancelled','Interrupted','Blocked','Deferred'].includes(record.status)){probeJob=record;break;}await new Promise(resolve=>setTimeout(resolve,1000));}assert.ok(probeJob,'actual durable DeveloperProbe did not reach a terminal state within two minutes');assert.ok(['Succeeded','ReviewRequired'].includes(probeJob.status),`native probe ended ${probeJob.status}: ${JSON.stringify(probeJob.error||probeJob.outputs)}`);assert.equal(probeJob.action,'DeveloperProbe');assert.ok(probeJob.outputs?.[0]?.CollectorResults?.length,'terminal probe should expose real collector results');assert.ok(probeJob.artifacts?.some(artifact=>artifact.kind==='Download'&&artifact.contentType==='application/zip'),'terminal probe should expose its ZIP through a safe download artifact');assert.ok(probeJob.artifacts?.some(artifact=>artifact.kind==='Folder'),'terminal probe should expose the validated artifact folder action');
    await page.evaluate(()=>window.WsmConsole.navigate('jobs',{force:true}));
    await page.waitForFunction(id=>{const card=[...document.querySelectorAll('#job-list .job-card')].find(node=>node.textContent.includes(id));return card&&card.textContent.includes('環境探測摘要')&&card.textContent.includes('本機盤點');},probeId,{timeout:30000});
    const probeCard=page.locator('#job-list .job-card').filter({hasText:probeId});assert.match(await probeCard.innerText(),/已取得|部分資料/,'job history should show actual terminal collector status');
    await probeCard.getByRole('button',{name:'查看探測摘要'}).waitFor({state:'visible'});await probeCard.getByRole('button',{name:'開啟探測資料夾'}).waitFor({state:'visible'});
    const downloadPromise=page.waitForEvent('download');await probeCard.getByRole('button',{name:/下載探測 ZIP/}).click();const probeDownload=await downloadPromise;assert.match(probeDownload.suggestedFilename(),/\.zip$/i,'the user-facing job card should download the ZIP through its protected artifact route');
    await page.evaluate(()=>window.WsmConsole.navigate('wizard',{force:true}));await page.waitForFunction(()=>window.WsmConsole.state.wizard?.intentRequired===true);
    assert.equal(await page.locator('input[name="wizard-role"]').count(),3,'diagnostics must leave the one-time migration purpose undecided');

    await page.locator('input[name="wizard-role"][value="Manager"]').check();
    const chooseResponse = page.waitForResponse(response => new URL(response.url()).origin === origin && new URL(response.url()).pathname === '/api/wizard' && response.request().method() === 'POST');
    await page.getByRole('button', { name: '使用這個用途並開始' }).click();
    const choose = await chooseResponse;
    const chooseText=await choose.text();assert.equal(choose.status(), 200, `chooseIntent failed: ${chooseText}; workspace=${workspacePath}`);
    const chooseBody = JSON.parse(chooseText);
    assert.equal(chooseBody.saved, true);
    assert.equal(chooseBody.projection.intentRequired, false);
    assert.equal(chooseBody.projection.workspaceRole, 'Manager');
    await page.waitForFunction(() => window.WsmConsole.state.wizard && window.WsmConsole.state.wizard.intentRequired === false);

    await page.locator('input[name="wizard-mode"][value="ItemByItem"]').check();
    const stateResponse = page.waitForResponse(response => new URL(response.url()).origin === origin && new URL(response.url()).pathname === '/api/wizard' && response.request().method() === 'POST');
    await page.locator('#wizard-next').click();
    const savedState = await stateResponse;
    assert.equal(savedState.status(), 200);
    const stateBody = await savedState.json();
    assert.equal(stateBody.saved, true);
    assert.equal(stateBody.projection.currentStep, 'handoff');
    assert.equal(stateBody.projection.state.Mode, 'ItemByItem');
    assert.ok(stateBody.projection.revision > 0);
    await page.waitForFunction(() => window.WsmConsole.state.wizard.currentStep === 'handoff');
    await page.screenshot({ path: path.join(screenshotDir, 'wizard-native-manager-desktop.png'), fullPage: true });
    await page.close();await stopServer();await startServer({seed:true});page=await browser.newPage({viewport:{width:1280,height:900}});
    await page.addInitScript(()=>{window.__nativePageErrors=[];window.addEventListener('unhandledrejection',event=>window.__nativePageErrors.push(String(event.reason&&event.reason.stack||event.reason)));});
    page.on('request',request=>{if(new URL(request.url()).origin===origin&&request.method()==='POST'&&new URL(request.url()).pathname==='/api/wizard')records.push({method:'POST',status:null,requestBody:request.postDataJSON(),utc:new Date().toISOString()});});
    page.on('response',response=>{const url=new URL(response.url());if(url.origin===origin&&url.pathname==='/api/wizard'){const record={method:response.request().method(),status:response.status(),utc:new Date().toISOString(),bodyPromise:response.text().catch(error=>JSON.stringify({bodyError:error.message}))};records.push(record);record.bodyPromise.then(value=>{record.body=value;delete record.bodyPromise;}).catch(error=>{record.body=JSON.stringify({bodyError:error.message});delete record.bodyPromise;});}});
    page.on('pageerror',error=>records.push({pageError:error.message}));
    await gotoConsole(page, origin, '/ui/index.html', { repoRoot, ready: p => p.waitForFunction(()=>window.WsmConsole&&window.WsmConsole.state.wizard, null, { timeout: 30000 }) });
    assert.equal(await page.locator('input[name="wizard-role"]').count(),0,'a pre-enrolled fixture should continue its existing Manager role');
    assert.equal(await page.locator('input[name="wizard-mode"][value="ItemByItem"]').count(),1);
    await page.locator('input[name="wizard-mode"][value="ItemByItem"]').check();
    const secondStateResponse=page.waitForResponse(response=>new URL(response.url()).origin===origin&&new URL(response.url()).pathname==='/api/wizard'&&response.request().method()==='POST');
    await page.locator('#wizard-next').click();
    const secondState=await secondStateResponse;assert.equal(secondState.status(),200);
    assert.ok((await secondState.json()).projection.groups.length>1,'seeded native workspace should expose multiple actual catalog groups');
    await page.waitForFunction(()=>window.WsmConsole.state.wizard.currentStep==='handoff');
    const reviewStateResponse=page.waitForResponse(response=>new URL(response.url()).origin===origin&&new URL(response.url()).pathname==='/api/wizard'&&response.request().method()==='POST'&&response.request().postDataJSON().operation==='saveState',{timeout:45000}).catch(async error=>{const diagnostic=await page.evaluate(()=>({session:window.WsmConsole?.state.session&&{contextId:window.WsmConsole.state.session.contextId,role:window.WsmConsole.state.session.role,pairId:window.WsmConsole.state.session.pairId,revision:window.WsmConsole.state.session.revision,decisionRevision:window.WsmConsole.state.session.decisionRevision,selectionRevision:window.WsmConsole.state.session.selectionRevision,sourceSelectionRevision:window.WsmConsole.state.session.sourceSelectionRevision,dataVersion:window.WsmConsole.state.session.dataVersion},guard:window.WsmConsole?.state.wizardGuardDiagnostic||null,projection:window.WsmConsole?.state.wizard&&{revision:window.WsmConsole.state.wizard.revision,currentStep:window.WsmConsole.state.wizard.currentStep,pairId:window.WsmConsole.state.wizard.pairId,context:window.WsmConsole.state.wizard.context},errorSummary:document.querySelector('#error-summary')?.innerText?.slice(0,500)||''}));throw new Error(`review-step saveState POST missing (${error.message}); browser=${JSON.stringify(diagnostic)}`);});
    await page.evaluate(()=>window.WsmConsole.saveWizardState({CurrentStep:'review'}));
    const reviewSavedResponse=await reviewStateResponse;assert.equal(reviewSavedResponse.status(),200);const reviewSaved=await reviewSavedResponse.json();
    assert.equal(reviewSaved.saved,true,JSON.stringify(reviewSaved));
    await page.waitForFunction(()=>window.WsmConsole.state.wizard.currentStep==='review'&&document.querySelector('input[name="wizard-group-choice"]'));
    const firstName=await page.locator('.wizard-item-title').innerText();
    await page.locator('input[name="wizard-group-choice"][value="exclude"]').check();
    await page.locator('#wizard-exclusion-reason').fill('原生核心測試：保留此項目');
    await page.locator('#wizard-exclusion-reason').focus();
    const focusBeforePoll=await page.evaluate(()=>document.activeElement.id);
    await page.waitForTimeout(3500);
    assert.equal(await page.locator('input[name="wizard-group-choice"][value="exclude"]').isChecked(),true,'native unchanged-projection polling should preserve the unsaved choice');
    assert.equal(await page.locator('#wizard-exclusion-reason').inputValue(),'原生核心測試：保留此項目');
    assert.equal(await page.evaluate(()=>document.activeElement.id),focusBeforePoll,'native polling should preserve the focused field');
    const reviewUiState=await page.evaluate(()=>({step:window.WsmConsole.state.wizard.currentStep,stale:window.WsmConsole.state.wizardStale,dirty:window.WsmConsole.state.wizardDirty,buttonDisabled:document.querySelector('#wizard-next').disabled,buttonText:document.querySelector('#wizard-next').textContent,visible:!document.querySelector('#wizard-content').hidden}));
    assert.equal(reviewUiState.stale,false,`native polling unexpectedly marked unchanged review stale: ${JSON.stringify(reviewUiState)}`);
    assert.equal(reviewUiState.buttonDisabled,false,`native review Next disabled: ${JSON.stringify(reviewUiState)}`);
    await page.evaluate(()=>{document.body.style.zoom='200%';});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>document.documentElement.clientWidth),false,'native wizard should not overflow at 200% zoom');
    await page.evaluate(()=>{document.body.style.zoom='100%';});
    const secondGroupId=await page.evaluate(()=>window.WsmConsole.state.wizard.groups[1].groupId);
    await page.evaluate(()=>{const button=document.querySelector('#wizard-next'),original=button.onclick;button.onclick=async function(...args){const startedUtc=new Date().toISOString(),startedAt=Date.now();let error='';try{return await original.apply(this,args);}catch(cause){error=String(cause&&cause.message||cause);throw cause;}finally{window.__nativeChoiceHandler={startedUtc,durationMs:Date.now()-startedAt,error,revision:window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.revision,reviewGroupIndex:window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.reviewGroupIndex,reviewGroupId:window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.state&&window.WsmConsole.state.wizard.state.ReviewGroupId,errorSummary:document.querySelector('#error-summary')?.textContent||''};}};});
    const saveChoiceResponse=page.waitForResponse(response=>new URL(response.url()).origin===origin&&new URL(response.url()).pathname==='/api/wizard'&&response.request().method()==='POST'&&response.request().postDataJSON().operation==='saveChoice');
    const cursorResponse=page.waitForResponse(response=>new URL(response.url()).origin===origin&&new URL(response.url()).pathname==='/api/wizard'&&response.request().method()==='POST'&&response.request().postDataJSON().operation==='saveState'&&response.request().postDataJSON().changes?.ReviewGroupId===secondGroupId,{timeout:45000}).catch(async error=>{const diagnostic=await page.evaluate(()=>({handler:window.__nativeChoiceHandler||null,session:window.WsmConsole&&window.WsmConsole.state.session&&{contextId:window.WsmConsole.state.session.contextId,role:window.WsmConsole.state.session.role,pairId:window.WsmConsole.state.session.pairId,decisionRevision:window.WsmConsole.state.session.decisionRevision,selectionRevision:window.WsmConsole.state.session.selectionRevision,sourceSelectionRevision:window.WsmConsole.state.session.sourceSelectionRevision,dataVersion:window.WsmConsole.state.session.dataVersion},guard:window.WsmConsole?.state.wizardGuardDiagnostic||null,ack:window.WsmConsole?.state.wizardOwnWriteAck||null,projection:window.WsmConsole&&window.WsmConsole.state.wizard&&{revision:window.WsmConsole.state.wizard.revision,pairId:window.WsmConsole.state.wizard.pairId,role:window.WsmConsole.state.wizard.workspaceRole||window.WsmConsole.state.wizard.role,context:{catalogRevision:window.WsmConsole.state.wizard.context?.catalogRevision,selectionRevision:window.WsmConsole.state.wizard.context?.selectionRevision,sourceSelectionRevision:window.WsmConsole.state.wizard.context?.sourceSelectionRevision,dataVersion:window.WsmConsole.state.wizard.context?.dataVersion},reviewGroupIndex:window.WsmConsole.state.wizard.reviewGroupIndex,currentGroupId:window.WsmConsole.state.wizard.currentGroupId,reviewGroupId:window.WsmConsole.state.wizard.state?.ReviewGroupId},stale:window.WsmConsole&&window.WsmConsole.state.wizardStale,dirty:window.WsmConsole&&window.WsmConsole.state.wizardDirty,pageErrors:(window.__nativePageErrors||[]).slice(-3),errorSummary:document.querySelector('#error-summary')?.innerText?.slice(0,500)||'',nextDisabled:document.querySelector('#wizard-next')?.disabled}));const trace=records.filter(record=>record.requestBody&&['saveChoice','saveState'].includes(record.requestBody.operation)).map(record=>({operation:record.requestBody.operation,status:record.status,expectedWizardRevision:record.requestBody.expectedWizardRevision,expectedDecisionRevision:record.requestBody.expectedDecisionRevision,expectedSelectionRevision:record.requestBody.expectedSelectionRevision,groupId:record.requestBody.groupId,changes:record.requestBody.changes}));throw new Error(`next-group cursor POST not observed (${error.message}); browser=${JSON.stringify(diagnostic)}; wizardWrites=${JSON.stringify(trace)}`);});
    await page.locator('#wizard-next').click();
    const choice=await saveChoiceResponse;assert.equal(choice.status(),200);const choiceBody=await choice.json();assert.equal(choiceBody.saved,true);assert.equal(choiceBody.result.Selected,false);assert.equal(choiceBody.result.Reason,'原生核心測試：保留此項目');
    const cursor=await cursorResponse;assert.equal(cursor.status(),200,'the next-group cursor CAS must succeed');const cursorBody=await cursor.json();assert.equal(cursorBody.saved,true);assert.equal(cursorBody.projection.state.ReviewGroupId,secondGroupId,`cursor write response must persist the exact next group: ${JSON.stringify({saved:cursorBody.saved,reviewGroupId:cursorBody.projection?.state?.ReviewGroupId,reviewGroupIndex:cursorBody.projection?.reviewGroupIndex})}`);
    await page.waitForFunction(()=>window.__nativeChoiceHandler!=null,null,{timeout:45000});
    const handler=await page.evaluate(()=>window.__nativeChoiceHandler);assert.equal(handler.error,'',`wizard choice handler failed after its core write: ${JSON.stringify(handler)}`);assert.ok(handler.durationMs>=0,JSON.stringify(handler));
    const persisted=await page.evaluate(async()=>{const s=window.WsmConsole.state.session,p=window.WsmConsole.state.wizard;return window.WsmConsole.endpoint(`/api/wizard?role=${encodeURIComponent(p.workspaceRole||p.role)}&pairId=${encodeURIComponent(p.pairId||'')}&contextId=${encodeURIComponent(s.contextId)}`);});assert.equal(persisted.state.ReviewGroupId,secondGroupId,`native GET should confirm the saved cursor; handler=${JSON.stringify(handler)}; saved response=${JSON.stringify(cursorBody)}`);assert.ok(persisted.reviewGroupIndex>0,JSON.stringify(persisted));
    assert.ok(records.some(record=>record.requestBody&&record.requestBody.operation==='saveState'&&record.requestBody.changes&&record.requestBody.changes.ReviewGroupId===secondGroupId),'after a durable core choice, the wizard should CAS-save the next group cursor');
    await page.getByRole('button',{name:'上一步項目'}).click();
    await page.waitForFunction(name=>window.WsmConsole.state.wizard.reviewGroupIndex===0&&document.querySelector('.wizard-item-title')?.textContent===name,firstName);
    assert.equal(await page.locator('input[name="wizard-group-choice"][value="exclude"]').isChecked(),true,'Back should reopen the previously confirmed selection');
    const remainingResponse=page.waitForResponse(response=>new URL(response.url()).origin===origin&&new URL(response.url()).pathname==='/api/wizard'&&response.request().method()==='POST'&&response.request().postDataJSON().operation==='confirmRemainingChoices');
    await page.getByRole('button',{name:'其餘符合條件項目全部加入（保留已排除）'}).click();
    const remaining=await remainingResponse;assert.equal(remaining.status(),200);const remainderBody=await remaining.json();assert.equal(remainderBody.saved,true);const appliedIds=remainderBody.result.appliedItemIds||remainderBody.result.AppliedItemIds||[];assert.ok(appliedIds.length>=124,`the real Manager handler should apply eligible new fixture items in one confirmed summary action; result=${JSON.stringify(remainderBody.result)}`);
    await page.waitForFunction(()=>window.WsmConsole.state.wizard.groups.length>1&&window.WsmConsole.state.wizard.groups.every(group=>group.confirmed===true));
    assert.equal(await page.evaluate(()=>window.WsmConsole.state.wizard.groups[0].selected),false,'the bulk summary must preserve the existing exclusion');
    assert.ok(records.some(record=>record.method==='POST'&&record.requestBody&&record.requestBody.operation==='saveChoice'),'browser should submit a real core saveChoice operation');
    await page.waitForFunction(()=>window.WsmConsole.state.wizard.currentStep==='review'&&document.querySelector('.wizard-item-title')&&document.querySelector('#wizard-exclusion-reason')&&!document.querySelector('.wizard-loading')&&document.querySelector('#wizard-next')?.textContent.includes('保存此項目'));
    const stableReviewText=await page.locator('#wizard-content').innerText();assert.doesNotMatch(stableReviewText,/\bRuntime\b|\bSuccess\b/,'normal review should translate backend category/status names');assert.match(stableReviewText,/軟體與設定|已完成掃描/);
    await page.screenshot({ path: path.join(screenshotDir, 'wizard-native-manager-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 320, height: 900 });
    await page.screenshot({ path: path.join(screenshotDir, 'wizard-native-manager-mobile.png'), fullPage: true });
    assert.deepEqual(records.filter(record => record.pageError), []);
    process.stdout.write('PASS: Edge used the actual Start-WsmHtmlConsole PowerShell handler for initial empty projection, explicit Manager enrollment, and durable wizard-state CAS. The seeded inventory is test data; no migration or restore operation ran. Probe-job poll retries after environmental resets: ' + pollResets + '. ' + deliverySummary() + '.\n');
  } finally {
    if (browser) await browser.close();
    await stopServer();
    const absolute = path.resolve(testRoot), tempRoot = path.resolve(os.tmpdir()) + path.sep;
    if (!absolute.startsWith(tempRoot)) throw new Error('Refusing to remove native wizard test data outside the OS temp directory.');
    fs.rmSync(absolute, { recursive: true, force: true });
  }
})().catch(error => { console.error(error);console.error('Native wizard route trace:',JSON.stringify(records.filter(record=>record.requestBody||record.pageError).slice(-25).map(record=>({method:record.method,status:record.status,operation:record.requestBody&&record.requestBody.operation,expectedWizardRevision:record.requestBody&&record.requestBody.expectedWizardRevision,changes:record.requestBody&&record.requestBody.changes,error:record.pageError})))); process.exitCode = reportFailure(error, 'native wizard journey'); });
