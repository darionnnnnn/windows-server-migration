// Q6b：HTTP／socket 邊界案例，對象是正式 Start-WsmHtmlConsole handler（Start-HtmlTestServer.ps1 -Seed，Manager console）。
//   (d) PLAN 16.4-8：帳密提交端點 /api/jobs/<id>/service-credentials 的 body 上限、Host、Origin（共用層檢查，經此端點驗證）。
//   (j) 真 socket：送出部分 header 後 reset、送出一半 body 後 reset、連線後不送資料／停住／慢速滴送直到逾時。
//       伺服器必須存活、不留下 job／作業紀錄／半寫檔案，之後的正常請求照常成功。
//
// 關於環境 ECONNRESET：本機 AdGuard 的 WFP 驅動（adgnetworkwfpdrv）會讓一部分「新的」loopback TCP 連線在收到任何回應位元組前被重設，
// 連兩個純 node 程序之間都會（PLAN 17.119 實測 20~50%）。因此，需要「完整回應」的探針遇到「未收到任何位元組的 ECONNRESET」時重試（每個探針最多
// MAX_ENV_ATTEMPTS 次），每次重試都列入輸出與最後一行。狀態碼、時間上限、伺服器端紀錄等斷言每一次嘗試都嚴格檢查，不因重試放寬；
// 伺服器若是確定性地重設，最後一次仍失敗。拒絕類探針另以伺服器端錯誤紀錄（route 為 /unparsed 代表在路由前就被拒）取證，
// 不單靠客戶端看到什麼。
const fs = require('node:fs'), path = require('node:path'), os = require('node:os'), net = require('node:net'), assert = require('node:assert/strict'), crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const MAX_ENV_ATTEMPTS = 6;
const BODY_LIMIT = 1048576;          // Read-WsmLocalHttpRequest 預設 MaximumBodyBytes
const FIRST_BYTE_LIMIT_MS = 4500;    // 閒置連線：首位元組 2000 ms 後回 400 並關閉（S3）
const STALL_CLOSE_LIMIT_MS = 4500;   // 已有部分資料後停住：單次讀取逾時 2000 ms
const DRIP_CLOSE_LIMIT_MS = 7500;    // 慢速滴送：整個請求期限 5000 ms
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-edge-'));
const workspace = path.join(root, 'ws'), ctl = path.join(root, 'ctl'), ready = path.join(ctl, 'ready.json'), stopFile = path.join(ctl, 'stop');
fs.mkdirSync(ctl, { recursive: true });
let child, origin, port, session, checks = 0;
const logs = [], envLog = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const check = (condition, message) => { assert.ok(condition, message); checks++; };
const isEnvReset = error => !!error && (error.code === 'ECONNRESET' || /ECONNRESET/.test(String(error.message || '')));

async function withEnvRetry(label, fn) {
  for (let attempt = 1; ; attempt++) {
    try { return await fn(attempt); }
    catch (error) {
      if (!error || error.envReset !== true || attempt >= MAX_ENV_ATTEMPTS) throw error;
      envLog.push(label + ' try ' + attempt);
      console.log('environmental loopback reset: ' + label + ' try ' + attempt + ' of ' + MAX_ENV_ATTEMPTS + '; retrying');
    }
  }
}

// 低階原始 socket：script(socket) 負責寫入；回傳實際觀察到的行為。不丟出 reset，由呼叫端決定如何解讀。
function exchange(script, { maxMs = 12000 } = {}) {
  return new Promise(resolve => {
    const started = Date.now();
    const socket = net.connect(port, '127.0.0.1');
    const result = { out: '', closedMs: null, error: null, connected: false, timedOut: false };
    let finished = false;
    const finish = () => { if (finished) return; finished = true; clearTimeout(timer); result.closedMs = Date.now() - started; resolve(result); };
    const timer = setTimeout(() => { result.timedOut = true; socket.destroy(); }, maxMs);
    socket.on('data', data => { result.out += data.toString('latin1'); });
    socket.on('error', error => { result.error = error.code || String(error); });
    socket.on('close', finish);
    socket.on('connect', () => { result.connected = true; Promise.resolve(script(socket)).catch(() => socket.destroy()); });
  });
}
// 單次寫入的「不完整 header」會被本機 AdGuard 扣住直到用戶端關閉（純 node 實測：伺服器 1510 ms 後、也就是用戶端關閉時才看到位元組），
// 伺服器的 header 讀取路徑就測不到。逐位元組寫入（setNoDelay）則即時抵達，所以部分 header 一律用 dripWrite 送。
async function dripWrite(socket, text, gapMs = 8) { socket.setNoDelay(true); for (const ch of text) { if (socket.destroyed) return; await new Promise(resolve => socket.write(ch, resolve)); await sleep(gapMs); } }
const statusOf = out => { const match = /^HTTP\/1\.1 (\d{3}) /.exec(out); return match ? Number(match[1]) : null; };
// 對「請求不完整」的連線，本機 AdGuard 會吃掉伺服器回應的狀態列與標頭，只剩 JSON 本文（純 node 伺服器 12/12 同樣；PLAN 17.119）。
// 所以這類探針接受：空、完整 400、或只有伺服器的 JSON 錯誤本文；絕不接受任何成功狀態或不是錯誤的內容。
const headlessErrors = [];
function acceptableTimeoutAnswer(out) {
  if (out === '' || statusOf(out) === 400) return true;
  if (/^{"message":"[^"]*","code":"(operation_failed|invalid_request)","correlationId":"[0-9a-f-]{36}","nextStep":"[^"]*"}$/.test(out)) { headlessErrors.push(out.length); return true; }
  return false;
}
const bodyOf = out => out.slice(out.indexOf('\r\n\r\n') + 4);

// 需要完整回應的探針：沒收到任何位元組就被重設 = 環境 reset（重試）；其他情形原樣回傳讓斷言檢查。
function requestText(method, target, headers, body) {
  const lines = [method + ' ' + target + ' HTTP/1.1'];
  for (const [name, value] of Object.entries(headers)) if (value !== null) lines.push(name + ': ' + value);
  return lines.join('\r\n') + '\r\n\r\n' + (body || '');
}
function baseHeaders(extra = {}) { return { Host: '127.0.0.1:' + port, Connection: 'close', ...extra }; }
function authedPost(extra = {}, body = '') {
  return baseHeaders({ Origin: origin, 'X-WSM-Token': session.token, 'Content-Type': 'application/json', 'Content-Length': String(Buffer.byteLength(body)), ...extra });
}
async function full(label, method, target, headers, body, options) {
  return withEnvRetry(label, async attempt => {
    const text = requestText(method, target, headers, body);
    const result = await exchange(socket => { socket.write(text); }, options);
    result.attempts = attempt;
    if (!result.out && (result.error === 'ECONNRESET' || (result.connected && result.error))) throw Object.assign(Error('ECONNRESET before any response byte: ' + label), { envReset: true, code: 'ECONNRESET' });
    result.status = statusOf(result.out);
    return result;
  });
}
async function getJson(label, target, headers) {
  const result = await full(label, 'GET', target, baseHeaders(headers));
  assert.equal(result.status, 200, label + ': ' + result.out.slice(0, 200));
  return JSON.parse(bodyOf(result.out));
}

// ---- 伺服器端證據：錯誤紀錄與工作區樹 ----
const errorLogPath = () => path.join(workspace, 'console-errors', 'errors.jsonl');
const errorRows = () => fs.existsSync(errorLogPath()) ? fs.readFileSync(errorLogPath(), 'utf8').split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line)) : [];
const walk = dir => !fs.existsSync(dir) ? [] : fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)]);
// 工作區快照：相對路徑與大小；errors.jsonl 會隨每次拒絕成長，另以列數檢查。
function treeSnapshot() {
  return walk(workspace).filter(file => path.resolve(file) !== path.resolve(errorLogPath())).map(file => path.relative(workspace, file) + '|' + fs.statSync(file).size).sort();
}
const jobFiles = () => fs.existsSync(path.join(workspace, 'console-jobs')) ? fs.readdirSync(path.join(workspace, 'console-jobs')).sort() : [];
async function newErrorRows(before, expectedCount) {
  // 伺服器在送出回應之後才處理下一個連線，錯誤紀錄在回應前已寫入；稍等檔案系統即可。
  const deadline = Date.now() + 3000;
  let rows = errorRows().slice(before);
  while (rows.length < expectedCount && Date.now() < deadline) { await sleep(50); rows = errorRows().slice(before); }
  return rows;
}
async function expectUntouched(label, before) {
  const after = treeSnapshot();
  assert.deepEqual(after, before.tree, label + ': the workspace changed (files added, removed or resized)');
  assert.deepEqual(jobFiles(), before.jobs, label + ': console-jobs changed');
  const jobs = await getJson(label + ' job registry', '/api/jobs', { 'X-WSM-Token': session.token });
  assert.equal(jobs.items.length, before.registry, label + ': the job registry changed');
  assert.equal(child.exitCode, null, label + ': the console process ended');
  checks++;
}
const untouchedBaseline = async () => ({ tree: treeSnapshot(), jobs: jobFiles(), registry: (await getJson('baseline job registry', '/api/jobs', { 'X-WSM-Token': session.token })).items.length });
async function stillServes(label) {
  const result = await getJson(label + ' follow-up request', '/api/session', {});
  assert.ok(result.token && result.contextId, label + ': the follow-up /api/session lost its token');
  checks++;
}

async function start() {
  child = spawn(process.env.WSM_PS_EXE || 'powershell.exe', ['-NoProfile', '-File', path.join(__dirname, 'Start-HtmlTestServer.ps1'), '-Workspace', workspace, '-ReadyPath', ready, '-StopFile', stopFile, '-Seed'], { windowsHide: true, env: { ...process.env, PSModulePath: path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') } });
  child.stdout.on('data', data => logs.push(data.toString())); child.stderr.on('data', data => logs.push(data.toString()));
  const until = Date.now() + 120000;
  while (!fs.existsSync(ready)) { if (Date.now() > until || child.exitCode !== null) throw Error('console did not start: ' + logs.join('')); await sleep(100); }
  origin = JSON.parse(fs.readFileSync(ready, 'utf8')).Url.replace(/\/$/, '');
  port = Number(new URL(origin).port);
  session = await getJson('session', '/api/session', {});
}

const credentialId = crypto.randomUUID();
const credentialPath = '/api/jobs/' + credentialId + '/service-credentials';
const SECRET = 'SECRET-MARKER-' + crypto.randomBytes(8).toString('hex');
const credentialBody = JSON.stringify({ credentials: { FixtureServiceCredential: { username: 'CONTOSO\\svc-app', password: SECRET } } });

// ===================== (d) 帳密端點：body 上限、Host、Origin =====================
async function scenarioCredentialGates() {
  const before = await untouchedBaseline();

  // 正例：合法請求通過 Host／Origin／token／body 閘門，到達 handler；此 fixture 沒有該 job，所以由 handler 自己回 404 UnknownJob。
  // （含真實等待中挑戰的完整帳密流程由 Test-NativeWizardRuntimeHandler.js 的 service-credentials 步驟覆蓋。）
  let rowsBefore = errorRows().length;
  const good = await full('credential positive', 'POST', credentialPath, authedPost({}, credentialBody), credentialBody);
  assert.equal(good.status, 404, 'a well-formed credential reply for an unknown job must reach the handler and be refused there: ' + good.out.slice(0, 200));
  const goodBody = JSON.parse(bodyOf(good.out));
  assert.equal(goodBody.code, 'operation_unavailable', 'handler-level refusal expected: ' + JSON.stringify(goodBody));
  assert.ok(!good.out.includes(SECRET), 'the response echoed the secret');
  const goodRows = await newErrorRows(rowsBefore, 1);
  assert.ok(goodRows.length >= 1 && goodRows.length <= good.attempts, 'one server-side error record per attempt: ' + goodRows.length + ' for ' + good.attempts);
  assert.equal(goodRows[0].route, credentialPath, 'the legitimate request must be routed (error record names the credential route)');
  checks += 4;
  await expectUntouched('credential positive', before);

  // 反例 1：Host 不符。伺服器在解析路由之前就拒絕（錯誤紀錄 route 是 /unparsed、code 是 rejected_host）。
  const badHosts = [
    ['foreign Host', { Host: 'evil.invalid' }],
    ['loopback name instead of address', { Host: 'localhost:' + port }],
    ['right address, wrong port', { Host: '127.0.0.1:' + (port === 65535 ? 65534 : port + 1) }],
    ['Host without port', { Host: '127.0.0.1' }],
    ['Host missing', { Host: null }]
  ];
  for (const [name, override] of badHosts) {
    rowsBefore = errorRows().length;
    const result = await full('credential ' + name, 'POST', credentialPath, authedPost(override, credentialBody), credentialBody);
    assert.equal(result.status, 403, name + ' must be refused with 403: ' + result.out.slice(0, 160));
    const rows = await newErrorRows(rowsBefore, 1);
    assert.ok(rows.length >= 1 && rows.length <= result.attempts, name + ': one server-side error record per attempt (' + rows.length + ' for ' + result.attempts + ')');
    for (const row of rows) { assert.equal(row.code, 'rejected_host', name + ': ' + JSON.stringify(row)); assert.equal(row.route, '/unparsed', name + ': the request must be refused before routing'); }
    assert.ok(!result.out.includes(SECRET), name + ': the response echoed the secret');
    checks += 4;
  }
  await expectUntouched('Host rejections', before);

  // 反例 2：Origin 不符、缺少或格式不同（POST 一律需要與 console 完全相同的 Origin）。
  const badOrigins = [
    ['foreign Origin', { Origin: 'http://evil.invalid' }],
    ['same host, other port', { Origin: 'http://127.0.0.1:' + (port === 65535 ? 65534 : port + 1) }],
    ['null Origin', { Origin: 'null' }],
    ['upper-case scheme', { Origin: origin.replace('http', 'HTTP') }],
    ['trailing slash', { Origin: origin + '/' }],
    ['Origin missing on POST', { Origin: null }]
  ];
  for (const [name, override] of badOrigins) {
    rowsBefore = errorRows().length;
    const result = await full('credential ' + name, 'POST', credentialPath, authedPost(override, credentialBody), credentialBody);
    assert.equal(result.status, 403, name + ' must be refused with 403: ' + result.out.slice(0, 160));
    const rows = await newErrorRows(rowsBefore, 1);
    assert.ok(rows.length >= 1 && rows.length <= result.attempts, name + ': one server-side error record per attempt (' + rows.length + ' for ' + result.attempts + ')');
    for (const row of rows) { assert.equal(row.code, 'rejected_origin', name + ': ' + JSON.stringify(row)); assert.equal(row.route, '/unparsed', name + ': the request must be refused before routing'); }
    assert.ok(!result.out.includes(SECRET), name + ': the response echoed the secret');
    checks += 4;
  }
  // 共用層的 Origin 檢查也適用於 GET：帶了 Origin 就必須與 console 完全相同（POST 另有「必須帶 Origin」那一關，所以 POST 探針蓋不到這一行）。
  rowsBefore = errorRows().length;
  const getOrigin = await full('GET with foreign Origin', 'GET', '/api/jobs', baseHeaders({ Origin: 'http://evil.invalid', 'X-WSM-Token': session.token }), '');
  assert.equal(getOrigin.status, 403, 'a GET carrying a foreign Origin must be refused: ' + getOrigin.out.slice(0, 160));
  const getOriginRows = await newErrorRows(rowsBefore, 1);
  assert.ok(getOriginRows.length >= 1 && getOriginRows.length <= getOrigin.attempts);
  for (const row of getOriginRows) { assert.equal(row.code, 'rejected_origin'); assert.equal(row.route, '/unparsed'); }
  checks += 4;
  await expectUntouched('Origin rejections', before);

  // 反例 3：token 缺少或錯誤（比 Host／Origin 晚一關，但同屬 session 防護）；已路由，所以紀錄的是帳密路由。
  for (const [name, token] of [['missing token', null], ['wrong token', 'not-the-session-token']]) {
    rowsBefore = errorRows().length;
    const result = await full('credential ' + name, 'POST', credentialPath, authedPost({ 'X-WSM-Token': token }, credentialBody), credentialBody);
    assert.equal(result.status, 403, name + ': ' + result.out.slice(0, 160));
    const rows = await newErrorRows(rowsBefore, 1);
    assert.ok(rows.length >= 1 && rows.length <= result.attempts);
    for (const row of rows) assert.equal(row.code, 'invalid_token', name + ': ' + JSON.stringify(row));
    checks += 2;
  }
  await expectUntouched('token rejections', before);

  // 反例 4：body 超過上限。
  //   4a 只送 header（Content-Length 比上限多 1，不送 body）：必須立刻以 400 拒絕，而不是等 body（等 body 會拖到 2~5 秒讀取逾時）。
  //   4b 真的送出超量 body：不得到達 handler。伺服器可以回 400，也可以因為拒絕時仍有未讀資料而重設連線；兩者都算拒絕，
  //      但絕不能是 404（那代表 body 被整個讀完並交給 handler 處理）。以伺服器端錯誤紀錄取證：route 必須是 /unparsed。
  //   4c 剛好等於上限的 body 照常處理（上限不是少一）。
  rowsBefore = errorRows().length;
  const headerOnly = await full('oversize header-only', 'POST', credentialPath, authedPost({ 'Content-Length': String(BODY_LIMIT + 1) }, ''), '');
  assert.equal(headerOnly.status, 400, 'an oversize Content-Length must be refused from the header alone: ' + headerOnly.out.slice(0, 200));
  assert.ok(headerOnly.closedMs < 1500, 'the refusal must not wait for the declared body (took ' + headerOnly.closedMs + ' ms)');
  const headerOnlyRows = await newErrorRows(rowsBefore, 1);
  assert.ok(headerOnlyRows.length >= 1 && headerOnlyRows.length <= headerOnly.attempts);
  for (const row of headerOnlyRows) assert.equal(row.route, '/unparsed', 'the oversize request must be refused before routing');
  checks += 4;
  console.log('oversize header-only: HTTP 400 in ' + headerOnly.closedMs + ' ms, server record route=' + headerOnlyRows[0].route);

  const oversize = Buffer.alloc(BODY_LIMIT + 4096, 0x61);
  // 需要 3 次「伺服器確實看到並拒絕」；環境把連線在到達伺服器前就重設的嘗試（伺服器端沒有新紀錄）不算，列入重試計數。
  const oversizeOutcomes = [];
  for (let tries = 1; oversizeOutcomes.length < 3; tries++) {
    if (tries > MAX_ENV_ATTEMPTS * 3) throw Error('the oversize body never reached the console in ' + (tries - 1) + ' tries');
    rowsBefore = errorRows().length;
    const text = requestText('POST', credentialPath, authedPost({ 'Content-Length': String(oversize.length) }, ''), '');
    const result = await exchange(async socket => { socket.write(text); await new Promise(resolve => socket.write(oversize, resolve)); }, { maxMs: 15000 });
    const status = statusOf(result.out);
    assert.ok(status === 400 || (status === null && result.out === ''), 'an oversize body must end as 400 or a closed connection, never reach the handler: status=' + status + ' ' + result.out.slice(0, 120));
    assert.ok(result.closedMs < 5000, 'an oversize body must be refused quickly, not read to completion (took ' + result.closedMs + ' ms)');
    const rows = await newErrorRows(rowsBefore, 1);
    if (rows.length === 0) { envLog.push('oversize body never reached the console, try ' + tries); console.log('environmental loopback reset: oversize body never reached the console (no server record), try ' + tries + '; retrying'); continue; }
    assert.equal(rows.length, 1, 'oversize body: exactly one server-side error record');
    assert.equal(rows[0].route, '/unparsed', 'the oversize body must be refused before routing (handler never saw it): ' + JSON.stringify(rows[0]));
    oversizeOutcomes.push(status === 400 ? '400' : 'closed(' + (result.error || 'no-error') + ')');
    checks += 3;
  }
  console.log('oversize body outcomes (client view): ' + oversizeOutcomes.join(', ') + '; server refused each before routing');
  await expectUntouched('oversize body', before);

  rowsBefore = errorRows().length;
  const padding = ' '.repeat(BODY_LIMIT - Buffer.byteLength(credentialBody));
  const exact = credentialBody + padding;
  assert.equal(Buffer.byteLength(exact), BODY_LIMIT);
  const boundary = await withEnvRetry('limit-sized body', async () => {
    const text = requestText('POST', credentialPath, authedPost({ 'Content-Length': String(BODY_LIMIT) }, ''), '');
    const result = await exchange(async socket => { socket.write(text); await new Promise(resolve => socket.write(exact, resolve)); }, { maxMs: 20000 });
    if (!result.out) throw Object.assign(Error('no response to the limit-sized body: ' + result.error), { envReset: true, code: 'ECONNRESET' });
    return result;
  });
  assert.equal(statusOf(boundary.out), 404, 'a body of exactly the limit is processed by the handler: ' + boundary.out.slice(0, 160));
  const boundaryRows = await newErrorRows(rowsBefore, 1);
  assert.equal(boundaryRows[0].route, credentialPath, 'the limit-sized body must reach the routed handler');
  checks += 2;
  await expectUntouched('limit-sized body', before);

  // 全程不得把秘密寫進磁碟（工作區任一檔案、錯誤紀錄）。
  for (const file of walk(workspace)) assert.ok(!fs.readFileSync(file).includes(SECRET), 'the secret marker was written to ' + path.relative(workspace, file));
  checks++;
  await stillServes('credential gates');
}

// ===================== (j) 真 socket：reset 與 timeout =====================
const opsBody = operationId => JSON.stringify({ action: 'Initialize', args: {}, operationId, idempotencyKey: crypto.randomUUID(), expectedRevision: Number(session.revision), contextId: String(session.contextId) });

async function scenarioSocketFaults() {
  const before = await untouchedBaseline();

  // j1 送出部分 header 後 reset（RST，不是 FIN）。
  for (let i = 0; i < 3; i++) {
    await exchange(async socket => {
      await dripWrite(socket, 'POST /api/operations HTTP/1.1\r\nHost: 127.0.0.1:' + port + '\r\nOrigin: ' + origin + '\r\nX-WSM-Token: ' + session.token.slice(0, 12));
      await sleep(80);
      socket.resetAndDestroy();
    }, { maxMs: 5000 });
  }
  await sleep(600);
  await expectUntouched('partial header reset', before);
  await stillServes('partial header reset');
  console.log('j1: 3 connections reset after a partial header (sent byte by byte); console alive, no job/file left, follow-up request served');

  // j2 送出一半 body 後 reset：請求完整、body 只到一半。作業 id 事後必須查不到。
  const reset2Ids = [];
  for (let i = 0; i < 3; i++) {
    const operationId = crypto.randomUUID(); reset2Ids.push(operationId);
    const body = opsBody(operationId);
    const half = Math.floor(body.length / 2);
    await exchange(async socket => {
      socket.write(requestText('POST', '/api/operations', authedPost({}, body), '') + body.slice(0, half));
      await sleep(120);
      socket.resetAndDestroy();
    }, { maxMs: 5000 });
  }
  await sleep(600);
  await expectUntouched('half body reset', before);
  for (const operationId of reset2Ids) {
    const lookup = await full('half-body job lookup', 'GET', '/api/jobs/' + operationId, baseHeaders({ 'X-WSM-Token': session.token }), '');
    assert.equal(lookup.status, 404, 'a half-sent operation must not exist as a job: ' + lookup.out.slice(0, 160));
    checks++;
  }
  await stillServes('half body reset');
  console.log('j2: 3 operations reset at half of their body; none exists as a job, no file left, follow-up request served');

  // j3 完整請求送出後立刻 reset（伺服器寫回應時對端已不在）。
  for (let i = 0; i < 3; i++) {
    await exchange(async socket => {
      socket.write(requestText('GET', '/api/jobs', baseHeaders({ 'X-WSM-Token': session.token }), ''));
      socket.resetAndDestroy();
    }, { maxMs: 5000 });
  }
  await sleep(600);
  await expectUntouched('reset after full request', before);
  await stillServes('reset after full request');
  console.log('j3: 3 connections reset right after a full request; console alive');

  // j4 連線後不送任何資料：首位元組逾時後，伺服器回 400（或直接關閉）並釋放連線。
  const idle = await withEnvRetry('idle connection', async () => {
    const result = await exchange(() => { }, { maxMs: 9000 });
    if (result.error === 'ECONNRESET') throw Object.assign(Error('ECONNRESET on idle connection'), { envReset: true, code: 'ECONNRESET' });
    return result;
  });
  assert.equal(idle.timedOut, false, 'the console never closed an idle connection');
  assert.ok(idle.closedMs <= FIRST_BYTE_LIMIT_MS, 'idle connection closed after ' + idle.closedMs + ' ms (limit ' + FIRST_BYTE_LIMIT_MS + ')');
  assert.ok(idle.out === '' || statusOf(idle.out) === 400, 'unexpected idle answer: ' + idle.out.slice(0, 120));
  checks += 3;
  console.log('j4: idle connection closed by the console after ' + idle.closedMs + ' ms (' + (idle.out ? 'HTTP 400' : 'no bytes') + ')');
  await expectUntouched('idle connection', before);

  // j5 header 只送一半就停住（逐位元組送出，伺服器確實看得到）：單次讀取逾時（2 秒）後被關閉。同時量測另一個正常請求被拖多久（單執行緒服務迴圈的已知特性，只記錄不放寬上限）。
  const stall = await withEnvRetry('stalled partial header', async () => {
    let probeLatency = null, concurrentPromise = null;
    const result = await exchange(async socket => {
      await dripWrite(socket, 'GET /api/session HTTP/1.1\r\nHost: 127.0.0.1:' + port + '\r\nX-Sl');
      await sleep(150);
      // 不等它：服務迴圈是單執行緒，這個請求要等停住的連線被處理完（連線關閉）才會被服務。
      concurrentPromise = (async () => { const started = Date.now(); const reply = await full('request during stall', 'GET', '/api/session', baseHeaders()); probeLatency = Date.now() - started; return reply; })();
      concurrentPromise.catch(() => { });
    }, { maxMs: 12000 });
    const concurrentResult = concurrentPromise ? await concurrentPromise : null;
    assert.equal(concurrentResult && concurrentResult.status, 200, 'a normal request issued while another connection stalls must still be served');
    if (!result.out && result.error === 'ECONNRESET') throw Object.assign(Error('ECONNRESET on stalled connection'), { envReset: true, code: 'ECONNRESET' });
    result.probeLatency = probeLatency;
    return result;
  });
  assert.equal(stall.timedOut, false, 'the console never closed a stalled connection');
  assert.ok(stall.closedMs <= STALL_CLOSE_LIMIT_MS, 'stalled connection closed after ' + stall.closedMs + ' ms (limit ' + STALL_CLOSE_LIMIT_MS + ')');
  assert.ok(acceptableTimeoutAnswer(stall.out), 'unexpected stall answer: ' + JSON.stringify(stall.out.slice(0, 400)));
  assert.ok(stall.probeLatency !== null && stall.probeLatency <= DRIP_CLOSE_LIMIT_MS, 'a normal request waited ' + stall.probeLatency + ' ms behind the stalled connection');
  checks += 4;
  console.log('j5: half a header then silence: closed after ' + stall.closedMs + ' ms; a concurrent normal request was served after ' + stall.probeLatency + ' ms (single service loop)');
  await expectUntouched('stalled header', before);

  // j6 header 完整、body 只送一部分就停住（Content-Length 宣告 4000，只送 10 bytes）。
  const stallBody = await withEnvRetry('stalled body', async () => {
    const result = await exchange(async socket => {
      socket.write(requestText('POST', '/api/operations', authedPost({ 'Content-Length': '4000' }, ''), '') + '{"action":"');
    }, { maxMs: 12000 });
    if (!result.out && result.error === 'ECONNRESET') throw Object.assign(Error('ECONNRESET on stalled body'), { envReset: true, code: 'ECONNRESET' });
    return result;
  });
  assert.equal(stallBody.timedOut, false, 'the console never closed a connection whose body stalled');
  assert.ok(stallBody.closedMs <= STALL_CLOSE_LIMIT_MS, 'stalled body closed after ' + stallBody.closedMs + ' ms (limit ' + STALL_CLOSE_LIMIT_MS + ')');
  assert.ok(acceptableTimeoutAnswer(stallBody.out), 'unexpected stalled-body answer: ' + JSON.stringify(stallBody.out.slice(0, 300)));
  checks += 3;
  console.log('j6: body stopped after 10 of 4000 bytes: closed after ' + stallBody.closedMs + ' ms');
  await expectUntouched('stalled body', before);

  // j7 慢速滴送（每 700 ms 一個位元組）：每次讀取都沒逾時，但整個請求期限（5 秒）會終止它。
  const drip = await withEnvRetry('slow drip', async () => {
    const result = await exchange(async socket => {
      const header = 'GET /api/session HTTP/1.1\r\nHost: 127.0.0.1:' + port + '\r\nX-Pad: ' + 'a'.repeat(60);
      for (const ch of header) { if (socket.destroyed) return; socket.write(ch); await sleep(700); }
    }, { maxMs: 14000 });
    if (!result.out && result.error === 'ECONNRESET') throw Object.assign(Error('ECONNRESET on slow drip'), { envReset: true, code: 'ECONNRESET' });
    return result;
  });
  assert.equal(drip.timedOut, false, 'the console never ended a slow-drip request');
  assert.ok(drip.closedMs <= DRIP_CLOSE_LIMIT_MS, 'slow-drip request ended after ' + drip.closedMs + ' ms (limit ' + DRIP_CLOSE_LIMIT_MS + ')');
  assert.ok(acceptableTimeoutAnswer(drip.out), 'unexpected slow-drip answer: ' + JSON.stringify(drip.out.slice(0, 300)));
  checks += 3;
  console.log('j7: slow-drip request ended by the whole-request deadline after ' + drip.closedMs + ' ms');
  await expectUntouched('slow drip', before);
  await stillServes('socket faults');
}

(async () => {
  try {
    await start();
    check(session.token && session.contextId, 'session established');
    await scenarioCredentialGates();
    await scenarioSocketFaults();
    // 結尾：所有探針之後，錯誤紀錄不含秘密，伺服器仍活著。
    assert.ok(!fs.readFileSync(errorLogPath(), 'utf8').includes(SECRET));
    assert.equal(child.exitCode, null);
    checks += 2;
    console.log('PASS: ' + checks + ' checks (credential endpoint body limit/Host/Origin/token gates, socket reset after partial header/half body/full request, idle/stalled/slow-drip timeouts); answers without HTTP head (environmental): ' + headlessErrors.length + '; environmental ECONNRESET retries: ' + envLog.length + (envLog.length ? ' [' + envLog.join('; ') + ']' : ''));
  } finally {
    try { fs.writeFileSync(stopFile, 'stop'); } catch (error) { /* ignore */ }
    if (child && child.exitCode === null) await new Promise(resolve => { const timer = setTimeout(() => { child.kill(); resolve(); }, 8000); child.once('exit', () => { clearTimeout(timer); resolve(); }); });
    try { fs.rmSync(root, { recursive: true, force: true }); } catch (error) { /* ignore */ }
  }
})().catch(error => { console.error('Failure after ' + checks + ' checks (environmental retries so far: ' + envLog.length + ')'); console.error(error); console.error(logs.join('')); process.exitCode = 1; });
