// R3: WaitingForInput / Interrupted are known non-terminal-for-the-card states, never UnknownWrite, and the job card never claims an end time for them.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const http=require('node:http');
const path=require('node:path');
const runtime=process.env.WSM_NODE_MODULES||'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const {chromium}=require(path.join(runtime,'playwright'));
const root=path.resolve(__dirname,'..');
const assets=new Map([['/',path.join(root,'src/ui/index.html')],['/ui/console.js',path.join(root,'src/ui/console.js')],['/ui/console.css',path.join(root,'src/ui/console.css')]]);
const pairId='waiting-pair',contextId='waiting-context',hash='a'.repeat(64),jobs=new Map();
let revision=5,nextStatus='WaitingForInput';
const wizard=()=>({kind:'WizardProjection',role:'Source',workspaceRole:'Source',roleMatchesWorkspace:true,pairId,pairName:'Source to Target',currentStep:'backup',nextStep:'handoff',mode:'ItemByItem',revision,groups:[],gates:[],results:{},context:{selectionRevision:2,assistiveRevision:4},actions:[]});
const sourceRuntime=()=>({Kind:'WizardRuntimeProjection',Role:'Source',PairId:pairId,viewContext:{revision,decisionRevision:3,selectionRevision:2,dataVersion:1},status:'Ready',actions:[],runtime:{status:'Ready',plan:{hash,inventoryRevision:3},backupResult:null}});
const server=http.createServer((req,res)=>{
  const url=new URL(req.url,'http://127.0.0.1'),asset=assets.get(url.pathname);
  if(asset){res.writeHead(200,{'Content-Type':asset.endsWith('.js')?'application/javascript':asset.endsWith('.css')?'text/css':'text/html'});fs.createReadStream(asset).pipe(res);return;}
  let body='';req.on('data',c=>body+=c);
  req.on('end',()=>{
    const send=(status,value)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(value));};
    if(url.pathname==='/api/session')return send(200,{token:'fixture',contextId,sessionId:'s',hostName:'Fixture',role:'Source',workspace:'C:\\fixture\\source',pairId,revision,decisionRevision:3,selectionRevision:2,dataVersion:1,principal:'Fixture'});
    if(url.pathname==='/api/context')return send(200,{roles:['Source'],pairs:[{pairId,label:'Source to Target'}],role:'Source',pairId,contextId,revision,decisionRevision:3,selectionRevision:2,dataVersion:1});
    if(url.pathname==='/api/wizard'&&req.method==='GET')return send(200,wizard());
    if(url.pathname==='/api/wizard/runtime')return send(200,sourceRuntime());
    if(url.pathname==='/api/wizard/nonc')return send(200,{Kind:'WizardNonCProjection',Role:'Source',PairId:pairId,ContextId:contextId,DataVersion:1,HasNonC:true,CurrentPlan:{path:'trusted-plan.json',hash},Preparation:{Status:'NeedsReview'},AccountObservation:{Status:'NotObserved'},ResultSummary:null,SourceChoices:[],ProofAllowed:true,actions:[{id:'NonCProofPreview',available:true}]});
    if(url.pathname==='/api/jobs'&&req.method==='GET')return send(200,{items:[...jobs.values()]});
    if(url.pathname.startsWith('/api/jobs/')&&req.method==='GET'){const id=decodeURIComponent(url.pathname.slice('/api/jobs/'.length));return jobs.has(id)?send(200,{job:jobs.get(id)}):send(404,{code:'job_not_found'});}
    if(url.pathname==='/api/operations'&&req.method==='POST'){
      const request=JSON.parse(body);
      const job={jobId:request.operationId,operationId:request.operationId,action:request.action,status:nextStatus,role:'Source',pairId,contextId,workspace:'C:\\fixture\\source',startedUtc:'2026-10-21T01:00:00Z',completedUtc:null,outputs:[{Status:nextStatus,ParentOperationId:request.operationId,NoTargetWrites:true}]};
      jobs.set(request.operationId,job);return send(202,{job});
    }
    return send(404,{code:'fixture_not_found',route:url.pathname});
  });
});
(async()=>{
  let browser;
  try{
    await new Promise((resolve,reject)=>server.listen(0,'127.0.0.1',resolve).once('error',reject));
    browser=await chromium.launch({headless:true,executablePath:process.env.WSM_EDGE||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'});
    const page=await browser.newPage({viewport:{width:390,height:844}}),errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.addInitScript(()=>{window.WsmNonCWizard={render(host,api){window.__nonCApi=api;host.replaceChildren();},hasDirty(){return false;},clear(){},clearSensitiveFields(){},discard(){}};});
    await page.goto(`http://127.0.0.1:${server.address().port}/#wizard`,{waitUntil:'networkidle'});
    await page.waitForFunction(()=>window.__nonCApi&&window.WsmConsole.state.wizardNonCProjection,null,{timeout:10000});
    for(const status of ['WaitingForInput','Interrupted']){
      nextStatus=status;
      const result=await page.evaluate(async()=>window.__nonCApi.submit('NonCProofPreview',{Directory:'C:\\fixture\\handoff',ExpectedManifestHash:'a'.repeat(64)},window.WsmConsole.state.wizard));
      assert.notEqual(result.Status,'UnknownWrite',`${status} must be a known response, not UnknownWrite`);
      assert.equal(result.WorkerStatus,status);
      assert.equal(await page.evaluate(()=>window.WsmConsole.state.pendingOperation),null,`${status} must not leave a pending (unconfirmed) write`);
    }
    // Job cards: no end-time line for unfinished states; terminal states still show it.
    const cardText=async(job)=>page.evaluate(job=>{const app=window.WsmConsole;app.state.jobs.clear();app.state.jobs.set(job.jobId,job);app.renderJobs();return document.getElementById('job-list').innerText;},job);
    const base={jobId:'card-job',pairId,role:'Source',action:'NonCProofPreview',startedUtc:'2026-10-21T01:00:00Z',completedUtc:null};
    for(const status of ['WaitingForInput','Running','Interrupted','CancelRequested']){
      const text=await cardText(Object.assign({},base,{status}));
      assert.ok(text.includes('card-job'),`${status} card rendered`);
      assert.doesNotMatch(text,/結束時間/,`${status} card must not show an end time`);
      assert.doesNotMatch(text,/結束時間：時間未知/,`${status} card must not say the end time is unknown`);
      assert.match(text,/尚未結束/,`${status} card shows an in-progress / waiting text`);
    }
    const done=await cardText(Object.assign({},base,{status:'Succeeded',completedUtc:'2026-10-21T02:00:00Z'}));
    assert.match(done,/結束時間/,'terminal card still shows the end time');
    assert.deepEqual(errors,[],'no page errors');
    console.log('PASS: WaitingForInput/Interrupted are known responses and unfinished job cards show no end time.');
  }finally{
    if(browser)await browser.close();
    server.close();
  }
})().catch(error=>{console.error(error);process.exit(1);});
