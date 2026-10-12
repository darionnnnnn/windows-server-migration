const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const screenshotDir = path.join(root, 'work', 'wizard-journey');
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

(async () => {
  let browser;
  let apiRequestCount = 0;
  let role = null;
  let contextId = 'fixture-context-0';
  let wizardRevision = 0;
  let step = 'start';
  let mode = 'ItemByItem';
  let scanned = false;
  let boundInventoryJobId = '';
  let currentPair = '';
  let importedHandoff = false;
  let selection = null;
  let job = null;
  let probeJob = null;
  let probePosts = 0;
  let probeLookups = 0;
  const writes = [];
  const item = { itemId:'a'.repeat(64), name:'網站與排程共用設定', kind:'Website', category:'Web', source:`C:\\migration\\${'very-long-source-path\\'.repeat(14)}site.config`, status:'Succeeded', executionStatus:'NotObserved', supported:true, dependencies:['b'.repeat(64)], fileDetails:[{path:`C:\\migration\\${'file-detail-path\\'.repeat(18)}web.config`},{path:'C:/migration/shared/pool.json'}] };
  const group = { groupId:'wg-'+'c'.repeat(24), kind:'Website', label:'網站與排程共用設定', name:item.name, itemIds:[item.itemId,'b'.repeat(64)], affectedItemIds:[item.itemId,'b'.repeat(64),'d'.repeat(64)], selected:selection===null?true:selection.selected, confirmed:selection!==null, selectionState:selection&&selection.selected?'Included':selection?'Excluded':'Included', sharedImpact:true, sharedImpactReason:'此共用資源也影響其他搬移項目。', dependencies:item.dependencies, supported:true, children:[item,Object.assign({},item,{itemId:'b'.repeat(64),name:'排程工作',kind:'ScheduledTask',source:'C:/fixture/Task Scheduler',fileDetails:[{path:'C:/fixture/Task Scheduler/nightly.xml'}]})].map(child=>Object.assign(child,{decision:selection&&selection.selected?'Include':selection?'Exclude':'Pending',selected:selection?selection.selected:true,confirmed:selection!==null,reason:selection&&selection.reason||''})) };
  function projection() {
    if (!role) return { kind:'WizardProjection', intentRequired:true, role:null, roleChoices:[{role:'Source',label:'舊主機',description:'在舊主機盤點並交接搬移資料。'},{role:'Target',label:'新主機',description:'在新主機檢查現況並接收核准資料。'},{role:'Manager',label:'整理搬移資料的電腦',description:'建立工作、審閱項目並完成交接。'}], actions:[{action:'ChooseIntent',label:'選擇用途',available:true}], state:null, revision:0, currentStep:'start', groups:[], gates:[], missingFields:[], context:null };
    return { kind:'WizardProjection', intentRequired:false, role, workspaceRole:role, roleMatchesWorkspace:true, pairId:currentPair, state:{CurrentStep:step,Mode:mode,AutoContinue:mode==='Automatic',ReviewGroupId:selection?'':'wg-'+'c'.repeat(24)}, revision:wizardRevision, currentStep:step, currentGroupId:selection?'':'wg-'+'c'.repeat(24), reviewGroupIndex:0, nextStep:scanned?(role==='Source'?'review':'prepare'):'scan', mode, scan:{status:scanned?'Complete':'Unavailable',hasResult:scanned,itemCount:scanned?2:0,incompleteCount:0}, results:{scan:scanned?{status:'Succeeded',hasDurableRecord:true}:null,backup:null,restore:null,hasAny:scanned}, inventoryCandidates:scanned&&!boundInventoryJobId?[{jobId:job&&job.jobId,sha256:'e'.repeat(64),revision:1,completedUtc:'fixture'}]:[], inventory:boundInventoryJobId?{jobId:boundInventoryJobId,sha256:'e'.repeat(64),revision:1}:null, groups:scanned?[Object.assign({},group,{selected:selection?selection.selected:true,confirmed:selection!==null,children:group.children.map(child=>Object.assign({},child,{selected:selection?selection.selected:true,confirmed:selection!==null,reason:selection&&selection.reason||''}))})]:[], gates:[], actions:step==='scan'?[{action:'Inventory',label:'掃描這台舊主機',available:true,reason:'讀取目前主機可觀測的搬移資料。'}]:step==='backup'&&role==='Source'&&job?.action==='ExportSourceReviewHandoff'?[]:step==='backup'&&role==='Source'?[{action:'ExportSourceReviewHandoff',label:'匯出盤點與已確認選擇',available:true,reason:'產生可安全交給管理端的交接材料。'}]:step==='handoff'&&role==='Manager'&&!importedHandoff?[{action:'ImportSourceReviewHandoff',label:'匯入來源盤點與選擇',available:true,reason:'需要檔案位置、可信指紋與新主機名稱。'}]:[], missingFields:[], context:{catalogRevision:4,assistiveRevision:2,selectionRevision:1,inventoryRevision:1,inventoryHash:'e'.repeat(64)}, readiness:{roleReady:true,reason:'',targetBoundApproval:false,restoreExplicitConfirmationRequired:true,activationExplicitConfirmationRequired:true,productionVerified:false} };
  }
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({ headless:true, executablePath:process.env.WSM_EDGE||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
    const page = await browser.newPage({ viewport:{width:1280,height:900}, deviceScaleFactor:1 });
    const pageErrors=[];page.on('pageerror',error=>pageErrors.push(error.message));
    await page.route('**/api/**', async route => {
      apiRequestCount++;
      try {
        const request=route.request(),url=new URL(request.url()),pathname=url.pathname,method=request.method(),body=method==='POST'?request.postDataJSON()||{}:{};
        const json=value=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(value)});
        if(pathname==='/api/session'&&method==='GET')return json({token:'fixture-token',sessionId:'fixture-session',contextId,hostName:'fixture-source-host',role:role||'Source',workspace:'C:\\fixture\\workspace',pairId:currentPair,revision:job&&job.revision||1,decisionRevision:4,selectionRevision:1,dataVersion:1,principal:'fixture-user'});
        if(pathname==='/api/context'&&method==='GET')return json({roles:['Source','Manager','Target'],pairs:importedHandoff?[{pairId:'fixture-handoff-pair',label:'舊主機 → 新主機',provenance:'Source review handoff; choices are suggestions, no approval.'}]:[{pairId:'fixture-pair',label:'舊主機 → 新主機'}],role:role||'Source',pairId:currentPair,contextId,revision:1,decisionRevision:4,selectionRevision:1,dataVersion:1});
        if(pathname==='/api/context'&&method==='POST'){currentPair=body.pairId;return json({role:body.role,pairId:currentPair,contextId,revision:1,decisionRevision:4,selectionRevision:1,dataVersion:1,token:'fixture-token'});}
        if(pathname==='/api/wizard'&&method==='GET')return json(projection());
        if(pathname==='/api/wizard/defaults'&&method==='GET'){const action=url.searchParams.get('action');if(action==='ImportSourceReviewHandoff')return json({kind:'WizardActionDefaults',action,requiredRole:'Manager',args:{},fields:[],missingFields:[{name:'Path',required:true},{name:'ExpectedHash',required:true},{name:'TargetName',required:true}],blocked:false,roleAvailable:true,context:projection().context,executionPermission:'None'});return json({kind:'WizardActionDefaults',action:'Inventory',requiredRole:role,args:{OutputDirectory:'C:\\fixture\\workspace\\inventory',DeepDiscovery:true,IncludeSoftwareCatalog:true},fields:[{name:'OutputDirectory',required:true,present:true,source:'Enrolled local workspace profile'}],missingFields:[],blocked:false,blockReason:'',roleAvailable:true,sourceProvenance:null,context:projection().context,executionPermission:'None'});}
        if(pathname==='/api/wizard'&&method==='POST'){
          writes.push(body.operation);
          if(body.operation==='chooseIntent'){role=body.role;contextId='fixture-context-1';step='start';wizardRevision=0;}
          else if(body.operation==='saveState'){if(body.expectedWizardRevision!==wizardRevision)return route.fulfill({status:409,contentType:'application/json',body:JSON.stringify({code:'stale_revision',message:'stale wizard fixture'})});Object.assign({},{...body.changes});if(body.changes.CurrentStep)step=body.changes.CurrentStep;if(body.changes.Mode)mode=body.changes.Mode;wizardRevision++;}
          else if(body.operation==='saveChoice'){selection={selected:!!body.selected,reason:body.reason||'使用者選擇不搬移'};wizardRevision++;}
          else if(body.operation==='selectInventory'){if(!job||body.jobId!==job.jobId)return route.fulfill({status:409,contentType:'application/json',body:JSON.stringify({code:'stale_revision',message:'inventory job mismatch'})});boundInventoryJobId=body.jobId;wizardRevision++;}
          return json({saved:true,contextId,projection:projection()});
        }
        if(pathname==='/api/operations'&&method==='POST'){
          if(body.action==='DeveloperProbe'){probePosts++;return route.fulfill({status:409,contentType:'application/json',body:JSON.stringify({code:'active_probe',message:'A workspace probe is already active.',existingJobId:'workspace-probe-1'})});}
          if(body.action==='ExportSourceReviewHandoff'){const output={Status:'Succeeded',HandoffStatus:'Exported',Path:'C:\\fixture\\source-review.json',SHA256:'d'.repeat(64),ConfirmedChoiceCount:2,IncludedChoiceCount:1,ExcludedChoiceCount:1,AuthoritativeApproval:false};job={jobId:body.operationId,operationId:body.operationId,action:body.action,status:'Succeeded',revision:2,role:'Source',workspace:'C:\\fixture\\workspace',pairId:'',outputs:[output]};return json({job});}
          if(body.action==='ImportSourceReviewHandoff'){assert.deepEqual(body.args,{Path:'C:\\handoff\\source-review.json',ExpectedHash:'f'.repeat(64),TargetName:'NEW-HOST-01'});importedHandoff=true;job={jobId:body.operationId,operationId:body.operationId,action:body.action,status:'Succeeded',revision:2,role:'Manager',workspace:'C:\\fixture\\workspace',pairId:'',outputs:[{Status:'Succeeded',HandoffStatus:'Imported',PairId:'fixture-handoff-pair',AppliedChoiceCount:1,AuthoritativeApproval:false,ProductionVerified:false}]};return json({job});}
          assert.equal(body.action,'Inventory');scanned=true;step='scan';job={jobId:body.operationId,operationId:body.operationId,action:'Inventory',status:'Succeeded',revision:2,role:'Source',workspace:'C:\\fixture\\workspace',pairId:'',outputs:[{Path:'C:\\fixture\\workspace\\inventory\\inventory-1.json',SHA256:'e'.repeat(64)}]};return json({job});
        }
        if(pathname==='/api/jobs'&&method==='GET')return json({items:[job,probeJob].filter(Boolean)});
        if(pathname==='/api/jobs/workspace-probe-1'&&method==='GET'){probeLookups++;probeJob={jobId:'workspace-probe-1',operationId:'workspace-probe-1',action:'DeveloperProbe',status:'Running',revision:2,role:'Manager',workspace:'C:\\fixture\\workspace',pairId:''};return json({job:probeJob});}
        if(pathname==='/api/jobs/fixture-unused'&&method==='GET')return json({});
        if(pathname==='/api/view'&&method==='GET')return json({});
        return route.fulfill({status:404,contentType:'application/json',body:JSON.stringify({code:'operation_unavailable',message:`fixture route missing: ${method} ${pathname}`})});
      } finally {}
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/`,{waitUntil:'networkidle'});
    await page.waitForFunction(()=>window.WsmConsole&&window.WsmConsole.state.wizard);
    assert.equal(await page.locator('#view-wizard').isVisible(),true);
    assert.match(await page.locator('#wizard-content').innerText(),/這台電腦的用途/);
    assert.equal(writes.length,0,'opening an uninitialized wizard must not write workspace state');
    await page.evaluate(()=>window.WsmConsole.startDeveloperProbe());
    await page.waitForFunction(()=>window.WsmConsole.state.developerProbeJobId==='workspace-probe-1');
    assert.equal(probePosts,1,'one raced probe request should not be retried with a replacement operation ID');
    assert.equal(probeLookups,1,'the UI must query only the server-supplied existing job ID');
    assert.equal(pageErrors.length,0);
    await page.evaluate(()=>window.WsmConsole.navigate('wizard'));
    await page.locator('input[name="wizard-role"][value="Source"]').check();
    await page.getByRole('button',{name:'使用這個用途並開始'}).click();
    await page.waitForFunction(()=>window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.intentRequired===false);
    assert.deepEqual(writes,['chooseIntent']);
    await page.locator('input[name="wizard-mode"][value="ItemByItem"]').check();
    await page.locator('#wizard-next').click();
    await page.waitForFunction(()=>window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.currentStep==='scan');
    await page.waitForFunction(()=>{const button=document.querySelector('#wizard-next');return button&&!button.disabled&&button.textContent.includes('掃描');});
    await page.locator('#wizard-next').click();
    await page.waitForFunction(()=>window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.currentStep==='review');
    await page.waitForFunction(()=>window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.inventory&&window.WsmConsole.state.wizard.inventory.jobId);
    const inventoryOperation=writes.indexOf('selectInventory');assert.ok(inventoryOperation>=0,'a newly completed explicit scan should bind its exact durable job ID automatically');assert.equal(boundInventoryJobId,job.jobId,'the bound inventory must be the just-submitted job, never an older candidate');
    assert.match(await page.locator('#wizard-content').innerText(),/共用設定/);
    assert.equal(await page.locator('.wizard-file-member').count(),2,'group review must show file details for every member, not only the first child');
    assert.match(await page.locator('.wizard-file-details').textContent(),/nightly\.xml/,'the secondary child file details must remain available');
    const relatedItems=page.locator('.wizard-related-details');assert.equal(await relatedItems.count(),1,'related member/dependency details should be available as a collapsed disclosure');
    assert.equal(await relatedItems.evaluate(node=>node.open),false,'related item details stay collapsed until requested');
    await relatedItems.locator('summary').first().click();
    const relatedText=await relatedItems.innerText();assert.match(relatedText,/排程工作/);assert.match(relatedText,/相依項目：排程工作/);assert.match(relatedText,/共用影響範圍/);
    await relatedItems.locator('summary').first().click();
    for(const width of [320,640,768,1280,1920]){
      await page.setViewportSize({width,height:900});
      const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>document.documentElement.clientWidth);
      assert.equal(overflow,false,`layout overflows at ${width}px`);
      const buttonHeight=await page.locator('#wizard-next').evaluate(node=>node.getBoundingClientRect().height);
      assert.ok(buttonHeight>=48,`primary action is too short at ${width}px`);
    }
    await page.setViewportSize({width:1280,height:900});
    await page.evaluate(()=>{document.body.style.zoom='200%';});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>document.documentElement.clientWidth),false,'200% zoom should not cause page-level horizontal overflow');
    await page.screenshot({path:path.join(screenshotDir,'wizard-journey-200-percent.png'),fullPage:true});
    await page.evaluate(()=>{document.body.style.zoom='100%';});
    await page.locator('input[name="wizard-group-choice"][value="exclude"]').check();
    await page.locator('#wizard-exclusion-reason').fill('業務確認後暫不搬移');
    await page.locator('#wizard-exclusion-reason').focus();
    const focusedBeforePoll=await page.evaluate(()=>document.activeElement.id);
    await page.evaluate(async()=>{await window.WsmConsole.refreshWizard();await window.WsmConsole.refreshWizard();});
    assert.equal(await page.locator('input[name="wizard-group-choice"][value="exclude"]').isChecked(),true,'polling must retain an unsaved radio choice');
    assert.equal(await page.locator('#wizard-exclusion-reason').inputValue(),'業務確認後暫不搬移','polling must retain the exclusion reason');
    assert.equal(await page.evaluate(()=>document.activeElement.id),focusedBeforePoll,'unchanged projection polling must retain keyboard focus');
    const reviewText=await page.locator('#wizard-content').innerText();
    assert.doesNotMatch(reviewText,/\b[a-f0-9]{64}\b/i,'core item hashes should stay in collapsed developer details');
    const developerDetails=page.locator('.wizard-technical-details');
    assert.equal(await developerDetails.count(),1);
    assert.equal(await developerDetails.evaluate(node=>node.open),false,'core IDs should be hidden by default');
    await page.locator('#wizard-next').click();
    await page.waitForFunction(()=>window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.currentStep==='backup');
    assert.ok(writes.indexOf('saveChoice')>writes.indexOf('saveState'),'Next must durably save the item choice before advancing the step');
    assert.deepEqual(selection,{selected:false,reason:'業務確認後暫不搬移'});
    await page.screenshot({path:path.join(screenshotDir,'wizard-journey-desktop.png'),fullPage:true});
    await page.setViewportSize({width:320,height:900});
    await page.screenshot({path:path.join(screenshotDir,'wizard-journey-mobile.png'),fullPage:true});
    await page.setViewportSize({width:1280,height:900});
    await page.waitForFunction(()=>{const button=document.querySelector('#wizard-next');return button&&button.textContent.includes('匯出來源交接資料');});
    await page.locator('#wizard-next').click();
    await page.waitForFunction(()=>document.querySelector('.wizard-actions')?.textContent.includes('C:\\fixture\\source-review.json'));
    const exportSummary=await page.locator('.wizard-actions').innerText();assert.match(exportSummary,/d{64}/);assert.match(exportSummary,/不包含正式核准/);assert.match(exportSummary,/選擇排除的項目數/);
    role='Manager';step='handoff';wizardRevision=0;mode='ItemByItem';selection=null;contextId='fixture-manager-context';currentPair='';await page.reload({waitUntil:'networkidle'});
    await page.waitForFunction(()=>window.WsmConsole&&window.WsmConsole.state.wizard&&window.WsmConsole.state.wizard.currentStep==='handoff');
    await page.waitForFunction(()=>{const button=document.querySelector('#wizard-next');return button&&button.textContent.includes('匯入來源資料');});
    await page.getByLabel('收到的來源盤點與選擇檔案位置').fill('C:\\handoff\\source-review.json');
    await page.getByLabel('可信交接摘要上的材料指紋（SHA-256）').fill('f'.repeat(64));
    await page.getByLabel('搬移對象的新主機名稱').fill('NEW-HOST-01');
    await page.waitForFunction(()=>{const button=document.querySelector('#wizard-next');return button&&!button.disabled;});
    await page.locator('#wizard-next').click();
    await page.waitForFunction(()=>window.WsmConsole.state.session.pairId==='fixture-handoff-pair');
    assert.equal(currentPair,'fixture-handoff-pair','handoff import must select only the exact pair returned by its terminal receipt');
    assert.deepEqual(pageErrors,[],'handoff import journey should not throw in the browser');
    assert.deepEqual(pageErrors,[],'wizard journey should not throw in the browser');
    assert.ok(apiRequestCount>0);
    console.log(`Wizard fixture journey passed; writes=${writes.join('→')}. This test stubs API responses and is not native-handler evidence.`);
  } finally {
    if(browser)await browser.close();
    if(server.closeAllConnections)server.closeAllConnections();
    await new Promise(resolve=>server.close(resolve));
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
