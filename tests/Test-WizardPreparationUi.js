const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const screenshotDir = path.join(root, 'work', 'r5-verification', 'wizard-preparation-ui');
fs.mkdirSync(screenshotDir, { recursive: true });
const files = new Map([
  ['/', path.join(root, 'src/ui/index.html')],
  ['/ui/console.js', path.join(root, 'src/ui/console.js')],
  ['/ui/console.css', path.join(root, 'src/ui/console.css')]
]);
const server = http.createServer((request, response) => {
  const file = files.get(new URL(request.url, 'http://127.0.0.1').pathname);
  if (!file) { response.writeHead(404); response.end('Not found'); return; }
  response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' });
  fs.createReadStream(file).pipe(response);
});

const adapters = [
  { name: '安全路徑錯誤提示', failure: true },
  { name: '資料版本衝突提示', failure: true, failureStatus:409, failureCode:'stale_revision', failureMessage:'Review changed: native decision revision no longer matches the reviewed operation.' },
  { name: '伺服器欄位錯誤定位', key:'Manual/Path', value:'D:\\Fixture\\Data', label:'路徑', group:'項目設定', fieldErrors:true },
  { name: '保存作業欄位錯誤定位', key:'Manual/Path', value:'D:\\Fixture\\Data', label:'路徑', group:'項目設定', fieldErrorsJob:true },
  { name: '來源快照變更後拒絕草稿', key:'Manual/Path', value:'來源原值', label:'路徑', group:'項目設定', saveConflict:true, bindingChange:'source', freshValue:'新來源核對值' },
  { name: '規格變更後拒絕草稿', key:'Manual/Path', value:'來源原值', label:'路徑', group:'項目設定', saveConflict:true, bindingChange:'spec', freshValue:'新規格核對值' },
  { name: '相同規格與來源快照保留草稿', key:'Manual/Path', value:'來源原值', label:'路徑', group:'項目設定', saveConflict:true, bindingChange:'none', compatibleConflict:true, freshValue:'新讀取來源值' },
  { name: 'SecretRef 格式錯誤阻擋', key:'LocalUser/SecretRef', value:'', label:'密碼保管項目參照', group:'項目設定', secretRef:true },
  { name: '已接受工作後失敗', terminalFailure: true },
  { name: '提交連線中斷後查詢同一工作', uncertain: true },
  { name: '多個候選項目需明確選取', key:'Manual/Path', value:'D:\\Fixture\\Data', label:'路徑', group:'項目設定', multipleItems:true },
  { name: '手動設定項目', key: 'Manual/Path', value: 'D:\\Fixture\\Data', label: '路徑', group: '項目設定' },
  { name: '排程工作', key: 'ScheduledTask/Enabled', value: false, type: 'boolean', label: '啟用狀態', group: '排程工作設定' },
  { name: 'IIS 網站', key: 'IisSite/BindingInformation', value: '*:443:fixture', label: '連線資訊', group: '網站設定' },
  { name: 'IIS 應用程式集區', key: 'IisPool/MaximumWorkerProcesses', value: 1, type: 'integer', label: '工作程序數', group: '應用程式集區設定' },
  { name: '巢狀 IIS 設定', group: '網站設定', label:'啟動模式', fields: [
    { key: 'IisPoolSettings/startMode', type: 'choice', value: 'OnDemand', required: true, editable: true, options: [{ value: 'OnDemand', label: '需要時啟動' }, { value: 'AlwaysRunning', label: '持續執行' }], label: '啟動模式' },
    { key: 'IisPoolSettings/enable32BitAppOnWin64', type: 'boolean', value: false, required: true, editable: true, label: '允許使用 32 位元網站程式' },
    { key: 'FileScope/ExcludedRelativePaths', type: 'lines', value: ['cache', 'temp'], required: false, editable: true, label: '不搬移的子資料夾（每行一個）' },
    { key: 'IisSite/Name', type: 'text', value: 'fixture-site', editable: false, label: '網站名稱' }
  ] },
];

// Model the safe HtmlConsole job projection at the API boundary. The review form
// is intentionally reconstructed from the normalized durable job, not the raw
// operation response, so immutable binding fields must survive that projection.
function normalizeJobs(rows) {
  const reviewFields = new Set(['Kind','PairId','ItemId','ItemName','ReviewHash','SpecHash','SourceSnapshotHash','Owner','Evidence','ManualReviewRequired','DefaultPriority','MissingTypedFields','SoftwareScopeDiagnostics','SoftwareExclusionCandidates']);
  return rows.map(job => Object.assign({}, job, { outputs: (job.outputs || []).map(output => {
    const safe = Object.fromEntries(Object.entries(output).filter(([key]) => reviewFields.has(key)));
    if (output.Kind === 'WizardPreparationReview') safe.FormFields = (output.FormFields || []).map(field => ({ key:field.key,label:field.label,type:field.type,value:field.value,required:field.required,editable:field.editable,options:field.options,origin:field.origin,provenance:field.provenance }));
    return safe;
  }) }));
}

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(40000 + Math.floor(Math.random() * 12000), '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    for (const [index, adapter] of adapters.entries()) {
      const savedRequests = [], jobs = new Map(), jobLookups = new Map(); let revision = 1, currentReviewHash = 'a'.repeat(64), currentSpecHash='c'.repeat(64), currentSourceSnapshotHash='d'.repeat(64), saveConflictUsed = false;
      const itemId = `preparation-item-${index}`;
      const review = { Kind: 'WizardPreparationReview', PairId:'pair-preparation-ui',ExpectedRevision:7,ItemId: itemId, ItemName: adapter.name, ReviewHash: 'a'.repeat(64), SpecHash:'c'.repeat(64), SourceSnapshotHash:'d'.repeat(64), ManualReviewRequired: true,
        FormFields: (adapter.fields || [{ key: adapter.key, type: adapter.type || 'text', value: adapter.value, required: true, editable: true, label: adapter.label, origin:'TrustedSourceInventory',provenance:{freshness:'fixture snapshot captured for this work'} }]).map(field => Object.assign({ origin:'TrustedSourceInventory',provenance:{freshness:'fixture snapshot captured for this work'} }, field)) };
      const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
      const errors = [], requests = []; page.on('pageerror', error => errors.push(error.message));
      await page.route('**/api/**', async route => {
        const request = route.request(), url = new URL(request.url()), pathname = url.pathname, method = request.method();
        const body = method === 'POST' ? request.postDataJSON() || {} : {};
        requests.push({method,pathname,action:body.action,operation:body.operation});
        const json = value => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(value) });
        if (pathname === '/api/session' && method === 'GET') return json({ token: 'fixture-token', sessionId: 'preparation-session', contextId: 'preparation-context', hostName: 'manager-fixture', role: 'Manager', workspace: 'C:\\fixture\\manager', pairId: 'pair-preparation-ui', revision, decisionRevision: 7, selectionRevision: 5, dataVersion: 1, principal: 'fixture-user' });
        if (pathname === '/api/context' && method === 'GET') return json({ roles: ['Manager'], pairs: [{ pairId: 'pair-preparation-ui', label: '舊主機 → 新主機' }], role: 'Manager', pairId: 'pair-preparation-ui', contextId: 'preparation-context', revision, decisionRevision: 7, selectionRevision: 5, dataVersion: 1 });
        if (pathname === '/api/wizard' && method === 'GET') return json({ kind: 'WizardProjection', role: 'Manager', workspaceRole: 'Manager', roleMatchesWorkspace: true, pairId: 'pair-preparation-ui', pairName: '舊主機 → 新主機', currentStep: 'prepare', nextStep: 'prepare', mode: 'ItemByItem', revision, groups: [], gates: [], results: {}, context: { selectionRevision: 5, assistiveRevision: 2 }, actions: [{ action: 'GetPreparationReview', label: '審閱下一個項目的設定', available: true, primary: true }] });
        if (pathname === '/api/wizard/defaults' && method === 'GET') return json({ kind: 'WizardActionDefaults', action: 'GetPreparationReview', roleAvailable: true, args: adapter.multipleItems ? {} : { ItemId: itemId }, fields: [], missingFields: adapter.multipleItems ? [{ name:'ItemId', required:true, type:'choice', options:[{value:itemId,label:'候選項目甲'},{value:`${itemId}-2`,label:'候選項目乙'}] }] : [] });
        if (pathname === '/api/operations' && method === 'POST') {
          savedRequests.push(body);
          if(adapter.failure&&body.action==='GetPreparationReview')return route.fulfill({status:adapter.failureStatus||422,contentType:'application/json',body:JSON.stringify({code:adapter.failureCode||'invalid_request',message:adapter.failureMessage||'欄位驗證失敗，請檢查輸入。',submissionRejected:true})});
          if(adapter.fieldErrors&&body.action==='SavePreparationReview')return route.fulfill({status:422,contentType:'application/json',body:JSON.stringify({code:'invalid_request',message:'欄位驗證失敗。',submissionRejected:true,fieldErrors:[{pointer:'/Answers/Manual~1Path',message:'請核對此欄位的格式。',reason:'format'}]})});
          if(adapter.saveConflict&&body.action==='SavePreparationReview'&&!saveConflictUsed){saveConflictUsed=true;currentReviewHash='b'.repeat(64);if(adapter.bindingChange==='source')currentSourceSnapshotHash='e'.repeat(64);if(adapter.bindingChange==='spec')currentSpecHash='f'.repeat(64);return route.fulfill({status:409,contentType:'application/json',body:JSON.stringify({code:'stale_revision',message:'Review changed.',submissionRejected:true})});}
          const id = body.operationId || `operation-${savedRequests.length}`, startedRevision=revision; revision++;
          if(adapter.uncertain&&body.action==='GetPreparationReview') { jobs.set(id,{jobId:id,operationId:id,action:body.action,status:'Failed',revision,startedRevision,role:'Manager',workspace:'C:\\fixture\\manager',pairId:'pair-preparation-ui',error:'fixture terminal failure after accepted request'}); return route.abort('connectionreset'); }
          const currentReview=Object.assign({},review,{ReviewHash:currentReviewHash,SpecHash:currentSpecHash,SourceSnapshotHash:currentSourceSnapshotHash,FormFields:review.FormFields.map(field=>Object.assign({},field,{value:adapter.saveConflict&&saveConflictUsed&&field.key===adapter.key?adapter.freshValue:field.value}))});
          const job = body.action === 'GetPreparationReview'
            ? { jobId: id, operationId: id, action: body.action, status: adapter.terminalFailure?'Failed':'Succeeded', revision,startedRevision,role: 'Manager',workspace:'C:\\fixture\\manager',pairId: 'pair-preparation-ui', outputs: adapter.terminalFailure?[]:[currentReview], error:adapter.terminalFailure?'fixture terminal failure after accepted request':undefined }
            : { jobId: id, operationId: id, action: body.action, status: adapter.fieldErrorsJob&&body.action==='SavePreparationReview'?'Failed':'Succeeded', revision,startedRevision,role: 'Manager',workspace:'C:\\fixture\\manager',pairId: 'pair-preparation-ui', outputs: [{ Kind: 'WizardPreparationReviewSaved', ItemId: itemId }], error:adapter.fieldErrorsJob&&body.action==='SavePreparationReview'?{fieldErrors:[{pointer:'/Answers/Manual~1Path',message:'請核對保存作業指出的欄位。',reason:'format'}]}:undefined };
          jobs.set(id, job);
          return route.fulfill({ status: 202, contentType: 'application/json', body: JSON.stringify({ job }) });
        }
        if (pathname === '/api/jobs' && method === 'GET') return json({ items: normalizeJobs([...jobs.values()]) });
        if (pathname.startsWith('/api/jobs/') && method === 'GET') {const id=decodeURIComponent(pathname.slice('/api/jobs/'.length)),lookups=(jobLookups.get(id)||0)+1;jobLookups.set(id,lookups);const job=jobs.get(id);if(adapter.uncertain&&lookups<2)return route.fulfill({status:404,contentType:'application/json',body:JSON.stringify({code:'job_not_found',message:'The accepted operation is not indexed yet'})});return job?json({job:normalizeJobs([job])[0]}):route.fulfill({status:404,contentType:'application/json',body:JSON.stringify({code:'job_not_found',message:'Unknown job'})});}
        if (pathname === '/api/view' && method === 'GET') return json({});
        return route.fulfill({ status: 404, contentType: 'application/json', body: JSON.stringify({ code: 'fixture_missing', message: `${method} ${pathname}` }) });
      });
      await page.goto(`http://127.0.0.1:${server.address().port}/#wizard`, { waitUntil: 'networkidle' });
      await page.waitForFunction(() => window.WsmConsole?.state?.wizard?.currentStep === 'prepare').catch(async error => { const diagnostic = await page.evaluate(() => ({ loaded:!!window.WsmConsole, wizard:window.WsmConsole?.state?.wizard, page:document.body.innerText, error:document.querySelector('#error-summary')?.innerText })); throw new Error(`Wizard preparation projection did not load (${error.message}); browser=${JSON.stringify(diagnostic)}; requests=${JSON.stringify(requests)}; pageErrors=${JSON.stringify(errors)}`); });
      await page.waitForFunction(allowDisabled => {const button=document.querySelector('#wizard-next');return button&&!button.hidden&&(allowDisabled||!button.disabled);}, adapter.multipleItems);
      if (adapter.multipleItems) {
        const itemChoice = page.locator('[data-wizard-field="ItemId"]');
        assert.equal(await itemChoice.inputValue(), '', 'the UI must not silently choose among multiple server-provided items');
        assert.equal(await page.locator('#wizard-next').isDisabled(), true, 'the required item choice must block the review request');
        assert.equal(await itemChoice.locator('option').count(), 3);
        await itemChoice.selectOption(itemId);
      }
      await page.locator('#wizard-next').click();
      if(adapter.failure){await page.locator('#error-summary').waitFor({state:'visible'});const errorText=await page.locator('#error-summary').innerText();if(adapter.failureStatus===409){assert.match(errorText,/搬移工作資料已更新/);assert.match(errorText,/重新載入條件後再提交/);}else{assert.match(errorText,/欄位驗證失敗/);assert.doesNotMatch(errorText,/\{"|\}\}/,'the UI should not expose raw JSON in the validation result');}assert.equal(await page.evaluate(()=>window.WsmConsole.state.pendingOperation),null,'a recognized validation rejection is definitive and clears the pending write');assert.deepEqual(errors,[]);await page.close();continue;}
      if(adapter.uncertain){await page.locator('#error-summary').waitFor({state:'visible'});const pending=await page.evaluate(()=>window.WsmConsole.state.pendingOperation);assert.ok(pending?.operationId,'a dropped response must retain the submitted operation id');const visible=await page.locator('#error-summary').evaluate(node=>{const copy=node.cloneNode(true);copy.querySelectorAll('details').forEach(row=>row.remove());return copy.innerText;});assert.match(visible,/無法連線本機服務|提交結果尚未確認/);assert.match(visible,/查詢這次操作/);assert.doesNotMatch(visible,new RegExp(pending.operationId.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')),'internal operation id must stay inside collapsed advanced details');assert.equal(savedRequests.filter(request=>request.action==='GetPreparationReview').length,1,'unknown transport outcome must never resend the write');await page.screenshot({path:path.join(screenshotDir,'preparation-uncertain-result-desktop.png'),fullPage:true});const query=page.getByRole('button',{name:'查詢這次操作'});await query.click();await page.waitForFunction(id=>window.WsmConsole.state.pendingOperation===null&&window.WsmConsole.state.jobs.get(id)?.status==='Failed',pending.operationId,{timeout:10000}).catch(async error=>{const diagnostic=await page.evaluate(id=>({pending:window.WsmConsole.state.pendingOperation,jobs:[...window.WsmConsole.state.jobs.entries()],error:document.querySelector('#error-summary')?.innerText,notice:document.querySelector('#notice')?.innerText}),pending.operationId);throw new Error(`same-operation recovery did not settle (${error.message}); diagnostic=${JSON.stringify(diagnostic)}; lookups=${jobLookups.get(pending.operationId)}; requests=${JSON.stringify(requests)}; saved=${JSON.stringify(savedRequests)}`);});assert.ok((jobLookups.get(pending.operationId)||0)>=2,'the original operation was queried until its durable terminal record appeared');assert.equal(savedRequests.filter(request=>request.action==='GetPreparationReview').length,1);const notice=await page.locator('#notice').innerText(),errorSummary=await page.locator('#error-summary').evaluate(node=>{const copy=node.cloneNode(true);copy.querySelectorAll('details').forEach(row=>row.remove());return copy.innerText;});assert.doesNotMatch(`${notice} ${errorSummary}`,new RegExp(pending.operationId.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')),'internal operation id must remain out of the regular result message');assert.equal(await page.locator('.wizard-pending-query').isVisible().catch(()=>false),false,'the recovered operation query control must no longer be visible');assert.deepEqual(errors,[]);await page.close();continue;}
      if(adapter.terminalFailure){await page.waitForFunction(()=>window.WsmConsole.state.pendingOperation===null&&[...window.WsmConsole.state.jobs.values()].some(job=>job.action==='GetPreparationReview'&&job.status==='Failed'));assert.equal(savedRequests.filter(request=>request.action==='GetPreparationReview').length,1);assert.equal(await page.locator('.wizard-pending-query').count(),0,'an accepted job with known terminal failure is not an uncertain submission');assert.deepEqual(errors,[]);await page.close();continue;}
      await page.waitForFunction(() => document.querySelector('.wizard-preparation-review-card input[data-preparation-key], .wizard-preparation-review-card select[data-preparation-key]'),null,{timeout:30000}).catch(async error=>{const diagnostic=await page.evaluate(()=>({wizard:{step:window.WsmConsole?.state?.wizard?.currentStep,actions:window.WsmConsole?.state?.wizard?.actions},jobs:[...(window.WsmConsole?.state?.jobs?.values()||[])].map(job=>({action:job.action,status:job.status,outputs:job.outputs})),content:document.querySelector('#wizard-content')?.innerText,next:{text:document.querySelector('#wizard-next')?.textContent,disabled:document.querySelector('#wizard-next')?.disabled,hidden:document.querySelector('#wizard-next')?.hidden},error:document.querySelector('#error-summary')?.innerText||''}));throw new Error(`Preparation form did not render (${error.message}); browser=${JSON.stringify(diagnostic)}; requests=${JSON.stringify(requests)}; pageErrors=${JSON.stringify(errors)}`);});
      const card = page.locator('.wizard-preparation-review-card');
      const projectedBinding=await page.evaluate(()=>{const state=window.WsmConsole.state,job=state.jobs.get(state.wizardPreparationReviewJobId),output=job?.outputs?.[0];return{specHash:output?.SpecHash,sourceSnapshotHash:output?.SourceSnapshotHash};});
      assert.equal(projectedBinding.specHash,'c'.repeat(64));assert.equal(projectedBinding.sourceSnapshotHash,'d'.repeat(64),'the normalized safe durable-job projection must retain SourceSnapshotHash for draft binding');
      assert.match(await card.innerText(), new RegExp(adapter.name));
      assert.match(await card.innerText(), new RegExp(adapter.group));
      assert.match(await card.innerText(), new RegExp(adapter.label));
      assert.match(await card.innerText(), /依目前來源盤點自動帶入/);
      assert.match(await card.innerText(), /fixture snapshot captured for this work/);
      assert.equal(await card.locator('[data-preparation-meta="Owner"]').inputValue(), '', 'owner must be a deliberate review entry');
      assert.equal(await card.locator('[data-preparation-meta="Evidence"]').inputValue(), '', 'review evidence must be a deliberate review entry');
      assert.doesNotMatch(await card.innerText(), /S-1-5-|\bSID\b|\{"|\}\}/, 'normal review UI must not expose raw identity values or JSON');
      const save = card.getByRole('button', { name: '保存此項目設定審閱' });
      await save.click();
      assert.equal(await card.locator('[data-preparation-meta="Owner"]').evaluate(node => node === document.activeElement), true, 'invalid submission should focus the first missing field');
      assert.match(await card.locator('[data-preparation-meta="Owner"]').getAttribute('aria-invalid'), /true/);
      const formFields = adapter.fields || [{ key: adapter.key, type: adapter.type || 'text', value: adapter.value }];
      if (adapter.fields) {
        assert.match(await card.innerText(), /網站名稱/);
        assert.match(await card.innerText(), /fixture-site/, 'read-only IIS values should remain visible while the review form is active');
      }
      for (const field of formFields) {
        if (field.editable === false) continue;
        const answer = card.locator(`[data-preparation-key="${field.key}"]`);
        if (field.type === 'boolean') await answer.check();
        else if (field.type === 'choice') await answer.selectOption(field.options[1].value);
        else if (field.type === 'lines') await answer.fill('cache\nlogs');
        else await answer.fill(field.type === 'integer' ? '2' : '核對後採用此設定');
      }
      await card.locator('[data-preparation-meta="Owner"]').fill('Fixture reviewer');
      await card.locator('[data-preparation-meta="Evidence"]').fill('已與服務負責人核對本次設定');
      if(adapter.secretRef){const secret=card.locator('[data-preparation-key="LocalUser/SecretRef"]');await secret.fill('這不是保管參照');await save.click();assert.match(await secret.getAttribute('aria-invalid'),/true/);assert.equal(await secret.evaluate(node=>node===document.activeElement),true,'SecretRef format rejection should focus the safe reference field');assert.equal(savedRequests.filter(request=>request.action==='SavePreparationReview').length,0,'invalid SecretRef must never reach the server');await secret.fill('CredentialRef-01');}
      await page.evaluate(() => {
        const id = window.WsmConsole.state.wizardPreparationReviewJobId;
        window.WsmConsole.renderWizardPreparationReviewJob(window.WsmConsole.state.jobs.get(id));
      });
      const refreshedCard = page.locator('.wizard-preparation-review-card');
      for (const field of formFields) {
        if (field.editable === false) continue;
        const input = refreshedCard.locator(`[data-preparation-key="${field.key}"]`);
        const expected = adapter.secretRef ? 'CredentialRef-01' : field.type === 'boolean' ? true : field.type === 'choice' ? field.options[1].value : field.type === 'lines' ? 'cache\nlogs' : field.type === 'integer' ? '2' : '核對後採用此設定';
        if (field.type === 'boolean') assert.equal(await input.isChecked(), true, 'nested boolean drafts should survive re-render');
        else assert.equal(await input.inputValue(), expected, `dirty ${field.key} value should survive a form re-render`);
      }
      assert.equal(await refreshedCard.locator('[data-preparation-meta="Owner"]').inputValue(), 'Fixture reviewer');
      assert.equal(await refreshedCard.locator('[data-preparation-meta="Evidence"]').inputValue(), '已與服務負責人核對本次設定');
      assert.match(await refreshedCard.innerText(), /尚未提交/);
      assert.equal(await page.evaluate(()=>{const event=new Event('beforeunload',{cancelable:true});window.dispatchEvent(event);return event.defaultPrevented;}),true,'unsubmitted preparation edits should trigger the browser leave warning');
      await page.evaluate(() => {const state=window.WsmConsole.state,job=state.jobs.get(state.wizardPreparationReviewJobId),old=state.session.contextId;state.session.contextId='renewed-same-pair-context';window.WsmConsole.renderWizardPreparationReviewJob(job);state.session.contextId=old;window.WsmConsole.renderWizardPreparationReviewJob(job);});
      assert.equal(await page.locator('.wizard-preparation-review-card [data-preparation-meta="Owner"]').inputValue(),'Fixture reviewer','same role/pair/binding drafts should survive a renewed context id');
      const isolation=await page.evaluate(()=>{const state=window.WsmConsole.state,job=state.jobs.get(state.wizardPreparationReviewJobId);state.session.role='Source';window.WsmConsole.renderWizardPreparationReviewJob(job);const otherRoleFields=document.querySelectorAll('.wizard-preparation-review-card [data-preparation-meta="Owner"]').length;state.session.role='Manager';window.WsmConsole.renderWizardPreparationReviewJob(job);const managerOwner=document.querySelector('.wizard-preparation-review-card [data-preparation-meta="Owner"]').value;state.session.pairId='other-pair';window.WsmConsole.renderWizardPreparationReviewJob(job);const otherPairFields=document.querySelectorAll('.wizard-preparation-review-card [data-preparation-meta="Owner"]').length;state.session.pairId='pair-preparation-ui';window.WsmConsole.renderWizardPreparationReviewJob(job);return{otherRoleFields,otherPairFields,managerOwner:document.querySelector('.wizard-preparation-review-card [data-preparation-meta="Owner"]').value};});
      assert.equal(isolation.otherRoleFields,0,'preparation forms must not cross a role boundary');assert.equal(isolation.otherPairFields,0,'preparation forms must not cross a pair boundary');assert.equal(isolation.managerOwner,'Fixture reviewer','returning to the original same-pair role should retain its in-memory edits');
      if(adapter.saveConflict){review.ReviewHash=currentReviewHash;}
      page.once('dialog', dialog => dialog.dismiss());
      await page.evaluate(() => window.WsmConsole.navigate('overview'));
      assert.equal(new URL(page.url()).hash, '#wizard', 'declining the dirty-draft prompt should keep the wizard open');
      assert.equal(await save.isDisabled(), false);
      const saveResponsePromise=page.waitForResponse(response=>new URL(response.url()).pathname==='/api/operations'&&response.request().method()==='POST'&&response.request().postDataJSON()?.action==='SavePreparationReview').catch(async error=>{const diagnostic=await page.evaluate(()=>{const card=document.querySelector('.wizard-preparation-review-card');return{url:location.href,content:card?.innerText,inputs:[...(card?.querySelectorAll('input,textarea,select')||[])].map(input=>({key:input.dataset.preparationKey||input.dataset.preparationMeta,value:input.type==='checkbox'?input.checked:input.value,disabled:input.disabled})),save:{text:card?.querySelector('button')?.innerText,disabled:card?.querySelector('button')?.disabled},state:{busy:window.WsmConsole?.state?.busy,pendingOperation:window.WsmConsole?.state?.pendingOperation,jobs:[...(window.WsmConsole?.state?.jobs?.values()||[])].map(job=>({id:job.jobId||job.id||job.operationId,action:job.action,status:job.status}))},error:document.querySelector('#error-summary')?.innerText||''};});throw new Error(`SavePreparationReview did not reach the API route (${error.message}); browser=${JSON.stringify(diagnostic)}; requests=${JSON.stringify(requests)}; savedRequests=${JSON.stringify(savedRequests)}; fixtureJobs=${JSON.stringify([...jobs.values()])}; pageErrors=${JSON.stringify(errors)}`);});
      const initialReviewJobId=await page.evaluate(()=>window.WsmConsole.state.wizardPreparationReviewJobId);
      await save.click();
      const saveResponse=await saveResponsePromise;
      if(adapter.fieldErrors){assert.equal(saveResponse.status(),422);const field=page.locator('.wizard-preparation-review-card [data-preparation-key="Manual/Path"]');assert.match(await field.getAttribute('aria-invalid'),/true/);assert.equal(await field.evaluate(node=>node===document.activeElement),true,'server JSON Pointer field error should focus the exact typed field');assert.equal(await page.locator('.wizard-preparation-review-card [data-preparation-meta="Owner"]').inputValue(),'Fixture reviewer','server field validation must preserve unrelated answers');assert.equal(await page.evaluate(()=>window.WsmConsole.state.pendingOperation),null,'a structured validation rejection is definitive');assert.deepEqual(errors,[]);await page.close();continue;}
      if(adapter.fieldErrorsJob){assert.equal(saveResponse.status(),202);const field=page.locator('.wizard-preparation-review-card [data-preparation-key="Manual/Path"]');await page.waitForFunction(()=>document.querySelector('.wizard-preparation-review-card [data-preparation-key="Manual/Path"][aria-invalid="true"]'));assert.equal(await field.evaluate(node=>node===document.activeElement),true,'terminal job fieldErrors should focus the exact field');assert.equal(await page.locator('.wizard-preparation-review-card [data-preparation-meta="Owner"]').inputValue(),'Fixture reviewer','terminal job field validation must keep unrelated answers');assert.equal(await page.locator('.wizard-preparation-review-card').count(),1,'a terminal field rejection should keep the reviewed form available');assert.deepEqual(errors,[]);await page.close();continue;}
      if(adapter.saveConflict){assert.equal(saveResponse.status(),409);await page.waitForFunction(()=>document.querySelector('.wizard-stale-notice')&&document.querySelector('.wizard-preparation-review-card [data-preparation-meta="Owner"]'),null,{timeout:15000});assert.match(await page.locator('.wizard-stale-notice').innerText(),/舊表單已失效/);const freshValues=await page.evaluate(()=>{const state=window.WsmConsole.state,id=state.wizardPreparationReviewJobId,job=state.jobs.get(id),output=job?.outputs?.[0];return{reviewHash:output?.ReviewHash,specHash:output?.SpecHash,sourceSnapshotHash:output?.SourceSnapshotHash,draftKey:state.wizardPreparationDraftKey};});assert.equal(freshValues.reviewHash,'b'.repeat(64),'the stale hash must be discarded and replaced by the fresh authoritative Get');if(adapter.compatibleConflict){assert.equal(await page.locator('.wizard-preparation-review-card [data-preparation-key="Manual/Path"]').inputValue(),'核對後採用此設定','compatible edits should be restored after a hash-only refresh');assert.equal(await page.locator('.wizard-preparation-review-card [data-preparation-meta="Owner"]').inputValue(),'Fixture reviewer','compatible reviewer edits should remain in memory');assert.ok(freshValues.draftKey.includes('c'.repeat(64))&&freshValues.draftKey.includes('d'.repeat(64)));}else{assert.equal(await page.locator('.wizard-preparation-review-card [data-preparation-key="Manual/Path"]').inputValue(),adapter.freshValue,'a changed source/spec binding must not inherit an old field draft');assert.equal(await page.locator('.wizard-preparation-review-card [data-preparation-meta="Owner"]').inputValue(),'','a changed source/spec binding must not inherit the old reviewer draft');}assert.equal(savedRequests.filter(request=>request.action==='GetPreparationReview').length,2,'stale CAS must request a new authoritative review');assert.equal(savedRequests.filter(request=>request.action==='SavePreparationReview').length,1,'stale CAS must not automatically retry a save');assert.equal(await page.evaluate(()=>window.WsmConsole.state.pendingOperation),null);assert.deepEqual(errors,[]);await page.close();continue;}
      assert.equal(saveResponse.status(),202);const saveJobId=saveResponse.request().postDataJSON().operationId;
      await page.waitForFunction(id=>{const job=window.WsmConsole?.state?.jobs?.get(id);return job&&['Succeeded','Saved','Completed','Failed','Cancelled','Interrupted','Blocked'].includes(job.status||job.Status);},saveJobId,{timeout:30000}).catch(async error=>{const diagnostic=await page.evaluate(id=>({saveJobId:id,jobs:[...(window.WsmConsole?.state?.jobs?.values()||[])].map(job=>({id:job.jobId||job.id||job.operationId,action:job.action,status:job.status,outputs:job.outputs})),content:document.querySelector('#wizard-content')?.innerText,error:document.querySelector('#error-summary')?.innerText||''}),saveJobId);throw new Error(`SavePreparationReview job did not reach a known state (${error.message}); browser=${JSON.stringify(diagnostic)}; fixtureJobs=${JSON.stringify([...jobs.values()])}; requests=${JSON.stringify(requests)}; pageErrors=${JSON.stringify(errors)}`);});
      const saved = savedRequests.find(request => request.action === 'SavePreparationReview');
      assert.ok(saved, 'the browser form should submit the typed preparation review action');
      assert.equal(saved.args.ItemId, itemId);
      assert.equal(saved.args.ReviewHash, review.ReviewHash);
      assert.equal(saved.args.Owner, 'Fixture reviewer');
      assert.equal(saved.args.Evidence, '已與服務負責人核對本次設定');
      for (const field of formFields) {
        if (field.editable === false) continue;
        const expected = adapter.secretRef ? 'CredentialRef-01' : field.type === 'boolean' ? true : field.type === 'choice' ? field.options[1].value : field.type === 'lines' ? 'cache\nlogs' : field.type === 'integer' ? 2 : '核對後採用此設定';
        assert.equal(saved.args.Answers[field.key], expected, `typed ${field.key} answer should serialize through SavePreparationReview`);
      }
      assert.equal(saved.args.ItemId, itemId, 'the selected server-provided item id should be sent explicitly');
      await page.waitForFunction(id=>window.WsmConsole.state.wizardPreparationReviewJobId&&window.WsmConsole.state.wizardPreparationReviewJobId!==id,initialReviewJobId,{timeout:15000});
      assert.equal(savedRequests.filter(request=>request.action==='GetPreparationReview').length,2,'a successful save should be followed by a fresh core Get');
      assert.equal(await page.evaluate(()=>{const event=new Event('beforeunload',{cancelable:true});window.dispatchEvent(event);return event.defaultPrevented;}),false,'a fresh form with no unsaved edits should not trigger the browser leave warning');
      assert.deepEqual(errors, []);
      await page.close();
    }
    process.stdout.write('PASS: browser fixture verifies preparation review rendering, explicit item choice, nested IIS choice/boolean/list serialization, read-only IIS values, required-field focus, memory-only dirty draft retention across rerender/same-pair context renewal, role isolation, beforeunload behavior, direct and terminal-job structured server field mapping, SecretRef validation, stale-CAS fresh Get without hash reattachment/retry, save-success fresh Get, terminal failure, and same-operation recovery. API operations are fixture responses; this verifies UI consumption/serialization only, not native handler or core persistence.\n');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
