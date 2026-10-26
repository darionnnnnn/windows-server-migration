// S17 (inferred finding): GET /api/jobs and GET /api/jobs/{id} do not filter by pair/role/workspace while
// cancel/open do. This integration test starts the real console, seeds durable job records of other
// pairs/roles/workspaces and pins what the server does today:
//   * listing and reading are the workspace job HISTORY: every record keeps its workspace/pair/role
//     provenance so the console UI (Jobs view "workspace history" + per-card provenance) filters it;
//   * every side-effecting or material-opening route (cancel) is context gated and answers the
//     generic operation_unavailable error for a record that belongs to another pair/role.
// R26-S17b（PLAN 17.131）：record.workspace 與目前工作區（正規化後）不相等的紀錄仍列出（搬移整個工作區後歷史不能消失），
//   但列表給它 foreignWorkspace=true，且所有寫入／開啟類路由（cancel、報告與附件 open、帳密、resume）一律以穩定錯誤碼
//   job_foreign_workspace 拒絕；同一位置的不同寫法（大小寫、尾端分隔符）不算其他工作區。
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-jobscope-'));
const foreignRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-jobscope-foreign-'));
let child, origin, session, checks = 0, envResets = 0;
const logs = [];

function once(url, options = {}) {
  const u = new URL(url), body = options.body === undefined ? undefined : String(options.body);
  const headers = { Connection: 'close', ...(body === undefined ? {} : { 'Content-Length': Buffer.byteLength(body, 'utf8') }), ...(options.headers || {}) };
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: Number(u.port), path: u.pathname + u.search, method: options.method || 'GET', headers, timeout: 8000 }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => { const text = Buffer.concat(chunks).toString('utf8'); resolve({ status: res.statusCode, text, json: () => JSON.parse(text) }); });
      res.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('native HTTP timeout')));
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}
// A loopback reset before any response byte is an environmental artefact of this machine; retry it (counted and printed).
async function call(url, options = {}) {
  for (let attempt = 1; ; attempt++) {
    try { return await once(url, options); }
    catch (e) { if (!/ECONNRESET|socket hang up|native HTTP timeout/.test(String(e && e.message)) || attempt >= 6) throw e; envResets++; await new Promise(r => setTimeout(r, 150)); }
  }
}
const get = route => call(origin + route, { headers: { 'X-WSM-Token': session.token } });
const post = (route, body) => call(origin + route, { method: 'POST', headers: { 'X-WSM-Token': session.token, Origin: origin, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

async function start() {
  const ready = path.join(root, 'ready.json'), stop = path.join(root, 'stop');
  for (const p of [ready, stop]) if (fs.existsSync(p)) fs.unlinkSync(p);
  child = spawn('powershell.exe', ['-NoProfile', '-File', path.join(__dirname, 'Start-HtmlTestServer.ps1'), '-Workspace', root, '-ReadyPath', ready, '-StopFile', stop, '-Seed'],
    { windowsHide: true, env: { ...process.env, PSModulePath: path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') } });
  child.stdout.on('data', d => logs.push(d.toString()));
  child.stderr.on('data', d => logs.push(d.toString()));
  const until = Date.now() + 120000;
  while (!fs.existsSync(ready)) {
    if (Date.now() > until || child.exitCode !== null) throw new Error('console did not start: ' + logs.join(''));
    await new Promise(r => setTimeout(r, 100));
  }
  origin = JSON.parse(fs.readFileSync(ready, 'utf8')).Url.replace(/\/$/, '');
  session = await (await call(origin + '/api/session')).json();
}
async function stopServer() {
  if (!child || child.exitCode !== null) return;
  fs.writeFileSync(path.join(root, 'stop'), 'stop');
  await new Promise(r => { const t = setTimeout(() => { child.kill(); r(); }, 8000); child.once('exit', () => { clearTimeout(t); r(); }); });
}
function writeJob(record) {
  fs.mkdirSync(path.join(root, 'console-jobs'), { recursive: true });
  fs.writeFileSync(path.join(root, 'console-jobs', record.jobId + '.json'), JSON.stringify({ action: 'SetMigrationSpec', status: 'Succeeded', startedUtc: new Date().toISOString(), outputs: [], idempotencyKey: crypto.randomUUID(), RequestHash: crypto.randomBytes(32).toString('hex'), ...record }));
}
function same(a, b) { return path.resolve(a).toLowerCase() === path.resolve(b).toLowerCase(); }

(async () => {
  try {
    // Phase 1: let the seeded console create its pair, then add durable history for it.
    await start();
    const pairId = String(session.pairId || '');
    assert.match(pairId, /^[a-f0-9-]{36}$/i, 'the seeded console did not report its pair');
    assert.equal(session.role, 'Manager');
    await stopServer();
    const ids = { current: crypto.randomUUID(), otherPair: crypto.randomUUID(), otherRole: crypto.randomUUID(), foreignWorkspace: crypto.randomUUID(), slashSpelling: crypto.randomUUID(), caseSpelling: crypto.randomUUID() };
    writeJob({ jobId: ids.current, role: 'Manager', workspace: root, pairId });
    writeJob({ jobId: ids.otherPair, role: 'Manager', workspace: root, pairId: crypto.randomUUID() });
    writeJob({ jobId: ids.otherRole, role: 'Source', workspace: root, pairId });
    writeJob({ jobId: ids.foreignWorkspace, role: 'Manager', workspace: foreignRoot, pairId });
    writeJob({ jobId: ids.slashSpelling, role: 'Manager', workspace: root + path.sep, pairId });
    writeJob({ jobId: ids.caseSpelling, role: 'Manager', workspace: root.toUpperCase(), pairId });
    await start();
    assert.equal(String(session.pairId), pairId);

    const listing = await get('/api/jobs');
    assert.equal(listing.status, 200); checks++;
    const items = new Map(listing.json().items.map(item => [item.jobId, item]));
    assert.ok(items.has(ids.current), 'the current-context job must be listed'); checks++;
    // Characterisation of the history view: other-context records are listed WITH their provenance, never anonymised.
    for (const [name, expected] of [['otherPair', null], ['otherRole', 'Source'], ['foreignWorkspace', 'Manager']]) {
      const item = items.get(ids[name]);
      assert.ok(item, `history entry ${name} is expected to be listed with provenance`); checks++;
      assert.ok(item.workspace && item.role && item.pairId, `history entry ${name} lost its workspace/role/pair provenance`); checks++;
      if (expected) assert.equal(item.role, expected);
    }
    assert.ok(!same(items.get(ids.foreignWorkspace).workspace, root), 'the foreign-workspace record must keep naming its own workspace');
    // R26-S17b：列表不篩選，但每列都帶伺服器判定的 foreignWorkspace（路徑正規化只在後端一處）。
    for (const [name, expected] of [['current', false], ['otherPair', false], ['otherRole', false], ['foreignWorkspace', true], ['slashSpelling', false], ['caseSpelling', false]]) {
      assert.strictEqual(items.get(ids[name]).foreignWorkspace, expected, `foreignWorkspace flag of ${name}`); checks++;
    }
    assert.notEqual(items.get(ids.otherPair).pairId, pairId); checks++;
    const detail = await get('/api/jobs/' + ids.otherPair);
    assert.equal(detail.status, 200); checks++;
    const record = detail.json(); const detailRecord = record.job || record;
    assert.strictEqual(detailRecord.foreignWorkspace, false, 'the detail of a same-workspace record is not foreign'); checks++;
    const foreignDetail = (await (await get('/api/jobs/' + ids.foreignWorkspace)).json()); const foreignDetailRecord = foreignDetail.job || foreignDetail;
    assert.strictEqual(foreignDetailRecord.foreignWorkspace, true, 'the detail of a foreign-workspace record carries the same flag as the listing'); checks++;
    assert.equal(detailRecord.pairId, items.get(ids.otherPair).pairId, 'GET /api/jobs/{id} must return the same provenance as the listing'); checks++;

    // The side-effecting route is context gated: other pair / role / workspace answer operation_unavailable,
    // whereas the current-context (already finished) job is refused for the different reason "not cancellable".
    for (const name of ['otherPair', 'otherRole']) {
      const reply = await post('/api/jobs/' + ids[name] + '/cancel', {});
      assert.ok(reply.status >= 400 && reply.status < 500, `cancel of ${name} returned HTTP ${reply.status}`);
      const body = reply.json();
      assert.equal(body.code || (body.error && body.error.code), 'operation_unavailable', `cancel of ${name} was not context gated: ${reply.text.slice(0, 200)}`); checks++;
    }
    // R26-S17b：其他工作區位置的紀錄，每一條寫入／開啟類路由都以同一個穩定錯誤碼拒絕（先於任何其他檢查）。
    const writeRoutes = [
      ['POST', '/cancel', {}], ['POST', '/reports/0/open', { SHA256: 'a'.repeat(64) }], ['GET', '/artifacts/0', null], ['POST', '/artifacts/0/open', { SHA256: 'a'.repeat(64) }],
      ['POST', '/service-credentials', {}], ['POST', '/service-credentials/cancel', {}], ['POST', '/service-credentials/defer', {}],
      ['GET', '/resume-preview', null], ['POST', '/resume', {}]
    ];
    for (const [method, suffix, body] of writeRoutes) {
      const reply = method === 'GET' ? await get('/api/jobs/' + ids.foreignWorkspace + suffix) : await post('/api/jobs/' + ids.foreignWorkspace + suffix, body);
      assert.ok(reply.status >= 400 && reply.status < 500, `${method} ${suffix} of a foreign-workspace record returned HTTP ${reply.status}`);
      const parsed = reply.json();
      assert.equal(parsed.code || (parsed.error && parsed.error.code), 'job_foreign_workspace', `${method} ${suffix} was not rejected as a foreign workspace record: ${reply.text.slice(0, 200)}`); checks++;
    }
    // 同位置的不同寫法不是其他工作區：照常走到可取消性檢查，而不是被當成外來紀錄。
    for (const name of ['slashSpelling', 'caseSpelling']) {
      const reply = await post('/api/jobs/' + ids[name] + '/cancel', {}); const parsed = reply.json();
      assert.equal(parsed.code || (parsed.error && parsed.error.code), 'operation_not_cancellable', `${name} must be treated as this workspace: ${reply.text.slice(0, 200)}`); checks++;
    }
    const own = await post('/api/jobs/' + ids.current + '/cancel', {});
    const ownBody = own.json();
    assert.equal(ownBody.code || (ownBody.error && ownBody.error.code), 'operation_not_cancellable', `the current-context control must reach the cancellability check: ${own.text.slice(0, 200)}`); checks++;
    console.log(`PASS Test-HtmlJobContextScope checks=${checks}; job history is workspace-wide with provenance by design, cancel is context gated (loopback resets retried: ${envResets}).`);
  } catch (error) {
    console.error(logs.join('').slice(-3000));
    throw error;
  } finally {
    await stopServer();
    for (const dir of [root, foreignRoot]) { try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) { /* best effort */ } }
  }
})().catch(error => { console.error(error); process.exit(1); });
