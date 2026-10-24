// S3：本機工作台 accept 不得被閒置預連線（瀏覽器 preconnect）串行卡住。
// 以真實 Start-WsmHtmlConsole handler 驗證：N 條閒置連線 + 併發資源請求、期限淘汰、慢客戶端、無 ECONNRESET。
//
// 關於 ECONNRESET：本機環境（AdGuard 等 loopback 過濾）會讓「修改前的程式」也零星出現 ECONNRESET
// （實測一般 GET 約 3~10%，閒置連線約 2~4%，連 PowerShell 裸 TcpListener 都會）。因此只要出現 ECONNRESET
// 就整輪重跑，最多 MAX_ATTEMPTS 輪；程式本身造成的 reset（例如關閉時仍有未讀資料）會每輪都出現而失敗。
// 延遲、關閉時機、慢客戶端等其他斷言每一輪都嚴格檢查，不因重試而放寬。
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),net=require('node:net'),http=require('node:http'),assert=require('node:assert/strict'),{spawn}=require('node:child_process');
const IDLE_COUNT=4,LATENCY_LIMIT_MS=1500,IDLE_CLOSE_LIMIT_MS=4000,IDLE_CLOSE_MIN_MS=1500,MAX_ATTEMPTS=4;
const root=fs.mkdtempSync(path.join(os.tmpdir(),'wsm-idle-')),ready=path.join(root,'ready.json'),stop=path.join(root,'stop');let child;const logs=[];
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const reset=(what)=>Object.assign(Error('ECONNRESET: '+what),{code:'ECONNRESET'});
function get(port,p){const started=Date.now();return new Promise((resolve,reject)=>{const req=http.get({hostname:'127.0.0.1',port,path:p,agent:false},res=>{const chunks=[];res.on('data',d=>chunks.push(d));res.on('end',()=>resolve({path:p,status:res.statusCode,ms:Date.now()-started,bytes:Buffer.concat(chunks).length}));res.on('error',reject)});req.on('error',reject);req.setTimeout(20000,()=>req.destroy(Error('request deadline '+p)))});}
function openIdle(port){return new Promise((resolve,reject)=>{const s=net.connect(port,'127.0.0.1');const rec={opened:Date.now(),closedMs:null,error:null,data:''};s.on('data',d=>rec.data+=d);s.on('error',e=>{rec.error=e.code||String(e)});s.on('close',()=>{rec.closedMs=Date.now()-rec.opened});s.on('connect',()=>resolve(rec));s.once('error',reject);});}
function slowGet(port){const started=Date.now();return new Promise((resolve,reject)=>{const s=net.connect(port,'127.0.0.1');let out='';s.on('data',d=>out+=d);s.on('error',e=>{if(!out)reject(e)});s.on('end',()=>resolve({ms:Date.now()-started,response:out}));
  const parts=['GET /ui/console.css HTTP/1.1\r\n','Host: 127.0.0.1:'+port+'\r\n','Accept: text/css\r\n','Connection: close\r\n','\r\n'];
  (async()=>{for(const part of parts){s.write(part);await sleep(300)}})().catch(reject);});}
function noReset(rec,label){if(rec.error==='ECONNRESET')throw reset(label);assert.equal(rec.error,null,label+' saw '+rec.error)}

async function scenario(port){
  // 1. N 條閒置預連線 + 同時 4 個資源請求（console.js 約 590 KB，在本機 loopback 過濾下大檔傳輸本身不穩，與本修正無關，改用較小的 nonc.js）
  const idles=[];for(let i=0;i<IDLE_COUNT;i++)idles.push(await openIdle(port));
  const results=await Promise.all(['/ui/console.css','/ui/nonc.js','/api/session','/ui/index.html'].map(p=>get(port,p)));
  for(const r of results){assert.equal(r.status,200,JSON.stringify(r));assert.ok(r.bytes>0);assert.ok(r.ms<LATENCY_LIMIT_MS,'latency '+r.path+' '+r.ms+'ms exceeds '+LATENCY_LIMIT_MS+'ms while '+IDLE_COUNT+' idle preconnects are open')}
  console.log('with '+IDLE_COUNT+' idle preconnects, concurrent latencies: '+results.map(r=>r.path+'='+r.ms+'ms').join(', '));

  // 2. 閒置連線在期限後被關閉（不早於慢客戶端寬限、不晚於上限），且沒有 ECONNRESET
  const closeDeadline=Date.now()+IDLE_CLOSE_LIMIT_MS+1000;while(idles.some(i=>i.closedMs===null)&&Date.now()<closeDeadline)await sleep(50);
  for(const i of idles){noReset(i,'idle preconnect');assert.notEqual(i.closedMs,null,'idle preconnect was never closed by the console');assert.ok(i.closedMs<IDLE_CLOSE_LIMIT_MS,'idle preconnect closed after '+i.closedMs+'ms');assert.ok(i.closedMs>=IDLE_CLOSE_MIN_MS,'idle preconnect closed after only '+i.closedMs+'ms (slow clients would be killed)');assert.ok(i.data===''||/^HTTP\/1\.1 400 /.test(i.data),'unexpected idle response: '+i.data.slice(0,80))}
  console.log('idle preconnects closed after (ms): '+idles.map(i=>i.closedMs).join(', '));

  // 3. 慢客戶端：header 分段、每段間隔 300 ms，仍須成功；其間另有一條閒置連線不得影響它
  const idleDuringSlow=await openIdle(port);
  const slow=await slowGet(port);
  assert.match(slow.response,/^HTTP\/1\.1 200 /,'slow header client failed: '+slow.response.slice(0,120));
  console.log('slow segmented-header client succeeded in '+slow.ms+'ms');
  const deadline2=Date.now()+IDLE_CLOSE_LIMIT_MS;while(idleDuringSlow.closedMs===null&&Date.now()<deadline2)await sleep(50);
  assert.notEqual(idleDuringSlow.closedMs,null,'idle preconnect opened beside the slow client was never closed');noReset(idleDuringSlow,'idle preconnect beside slow client');

  // 4. 偵聽器仍存活
  assert.equal(child.exitCode,null,'console terminated during idle preconnect handling');
  const session=await get(port,'/api/session');assert.equal(session.status,200);
}

(async()=>{try{
  child=spawn(process.env.WSM_PS_EXE||'powershell.exe',['-NoProfile','-File',path.join(__dirname,'Start-HtmlTestServer.ps1'),'-Workspace',root,'-ReadyPath',ready,'-StopFile',stop],{windowsHide:true,env:{...process.env,PSModulePath:path.join(process.env.SystemRoot,'System32','WindowsPowerShell','v1.0','Modules')}});
  child.stdout.on('data',d=>logs.push(d.toString()));child.stderr.on('data',d=>logs.push(d.toString()));
  const deadline=Date.now()+60000;while(!fs.existsSync(ready)){if(child.exitCode!==null||Date.now()>deadline)throw Error(logs.join('')||'Startup deadline');await sleep(50)}
  const port=+new URL(JSON.parse(fs.readFileSync(ready)).Url).port;
  let warm;for(let n=0;n<MAX_ATTEMPTS&&!warm;n++){try{warm=await get(port,'/ui/console.css')}catch(e){if(e.code!=='ECONNRESET')throw e}}
  assert.equal(warm.status,200);console.log('baseline single css request: '+warm.ms+'ms');
  let resets=0,passed=false;
  for(let attempt=1;attempt<=MAX_ATTEMPTS&&!passed;attempt++){
    try{await scenario(port);passed=true}catch(e){if(e.code==='ECONNRESET'){resets++;console.log('attempt '+attempt+' hit '+e.message+'; retrying (environmental loopback resets also occur before the fix)')}else throw e}
  }
  assert.ok(passed,'ECONNRESET in all '+MAX_ATTEMPTS+' attempts: the console resets connections deterministically');
  console.log('PASS: '+IDLE_COUNT+' idle preconnects did not serialize concurrent requests; idle sockets closed at their deadline without ECONNRESET; segmented-header client served ('+resets+' environmental reset retries).');
}finally{if(child&&child.exitCode===null){fs.writeFileSync(stop,'stop');await new Promise(resolve=>{const timer=setTimeout(()=>{child.kill();resolve()},6000);child.once('exit',()=>{clearTimeout(timer);resolve()})})}fs.rmSync(root,{recursive:true,force:true})}})().catch(e=>{console.error(e);console.error(logs.join(''));process.exitCode=1});
