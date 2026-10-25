// Native static-file transport of the real Start-WsmHtmlConsole: every /ui asset is fetched with a plain GET (no browser, no fallback) and its
// length and SHA-256 are compared with src/ui on disk and with the assetHashes the console itself hands out in /api/session.
// The browser tests may serve /ui from disk when the local loopback filter stalls large responses (tests/Browser-UiDelivery.js, PLAN 17.119);
// this file is the one that keeps the real transfer of console.js (> 64 KiB) under test and reports the result instead of skipping it.
//
// Outcomes:
//   PASS                  every asset arrived byte-identical (exit 0).
//   FAIL                  wrong status, wrong length with a complete response, or wrong bytes (exit 1), always.
//   ENVIRONMENT-LIMITED   an asset never arrived completely (stalled or reset mid-body) in MAX_TRIES tries, or arrived re-framed without the
//                         console's Content-Length (rewritten in transit by a local filter); printed with the received byte
//                         counts and exit code 3, so a runner does not count it as a pass. With WSM_TEST_NO_DISK_UI=1 (set in every GitHub
//                         workflow) this is a FAIL (exit 1).
// It also checks that every workflow sets WSM_TEST_NO_DISK_UI=1, so CI never takes the disk fallback.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os'), http = require('node:http'), crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');

const repo = path.resolve(__dirname, '..');
const MAX_TRIES = 3, TIMEOUT_MS = 15000;
const strict = process.env.WSM_TEST_NO_DISK_UI === '1';
const assets = ['index.html', 'console.js', 'nonc.js', 'console.css', 'guide.html'];
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-assets-')), ready = path.join(root, 'ready.json'), stopFile = path.join(root, 'stop');
const logs = []; let child, checks = 0;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function get(origin, route, headers = {}) {
  return new Promise(resolve => {
    const url = new URL(origin + route); const chunks = []; let got = 0, settled = false;
    const done = result => { if (!settled) { settled = true; resolve(result); } };
    const req = http.get({ host: url.hostname, port: url.port, path: url.pathname, agent: false, headers: { Connection: 'close', ...headers } }, res => {
      res.on('data', chunk => { got += chunk.length; chunks.push(chunk); });
      res.on('end', () => done({ status: res.statusCode, length: Number(res.headers['content-length']), body: Buffer.concat(chunks), complete: true }));
      res.on('aborted', () => done({ status: res.statusCode, length: Number(res.headers['content-length']), got, complete: false, why: 'aborted' }));
      res.on('error', e => done({ status: res.statusCode, got, complete: false, why: e.code || e.message }));
    });
    req.setTimeout(TIMEOUT_MS, () => { done({ got, complete: false, why: 'stalled ' + TIMEOUT_MS + ' ms' }); req.destroy(); });
    req.on('error', e => done({ got, complete: false, why: e.code || e.message }));
  });
}

(async () => {
  let exitCode = 0;
  try {
    for (const file of fs.readdirSync(path.join(repo, '.github', 'workflows')).filter(name => /\.ya?ml$/.test(name))) {
      const text = fs.readFileSync(path.join(repo, '.github', 'workflows', file), 'utf8');
      assert.match(text, /^env:\r?\n(?:[ \t]+.*\r?\n)*?[ \t]+WSM_TEST_NO_DISK_UI: '1'\r?$/m, file + ' must set WSM_TEST_NO_DISK_UI=1 at workflow level so CI never serves /ui from disk');
      checks++;
    }
    child = spawn('powershell.exe', ['-NoProfile', '-File', path.join(__dirname, 'Start-HtmlTestServer.ps1'), '-Workspace', root, '-ReadyPath', ready, '-StopFile', stopFile, '-Seed'], { windowsHide: true, env: { ...process.env, PSModulePath: path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') } });
    child.stdout.on('data', d => logs.push(String(d))); child.stderr.on('data', d => logs.push(String(d)));
    const until = Date.now() + 120000;
    while (!fs.existsSync(ready)) { if (Date.now() > until || child.exitCode !== null) throw new Error('console did not start: ' + logs.join('')); await sleep(100); }
    const origin = JSON.parse(fs.readFileSync(ready, 'utf8')).Url.replace(/\/$/, '');
    let session = null;
    for (let attempt = 1; attempt <= 6 && !session; attempt++) { const reply = await get(origin, '/api/session'); if (reply.complete && reply.status === 200) session = JSON.parse(reply.body.toString('utf8')); }
    assert.ok(session && session.assetHashes, 'the console must hand out its asset hashes in /api/session');
    const limited = [], summary = [];
    for (const name of assets) {
      const disk = fs.readFileSync(path.join(repo, 'src', 'ui', name));
      assert.equal(session.assetHashes['/ui/' + name], sha(disk), 'the console session hash of /ui/' + name + ' must equal the file on disk');
      checks++;
      const tries = [];
      let arrived = null;
      for (let attempt = 1; attempt <= MAX_TRIES && !arrived; attempt++) {
        const reply = await get(origin, '/ui/' + name);
        if (reply.complete) arrived = reply; else tries.push((reply.got || 0) + ' of ' + disk.length + ' bytes, ' + reply.why);
      }
      if (!arrived) { limited.push('/ui/' + name + ' (' + tries.join('; ') + ')'); continue; }
      assert.equal(arrived.status, 200, '/ui/' + name + ' answered ' + arrived.status);
      // The console writes every response with Content-Length (Write-WsmLocalHttpResponse). A 200 without it was re-framed by something between
      // the console and this client: on this host AdGuard injects a <script> into text/html even for a node client. That is reported as an
      // environment limitation with the byte difference; it never counts as verified.
      if (!Number.isFinite(arrived.length)) { limited.push('/ui/' + name + ' (rewritten in transit: no Content-Length, ' + arrived.body.length + ' bytes received for ' + disk.length + ' on disk)'); continue; }
      assert.equal(arrived.length, disk.length, '/ui/' + name + ' Content-Length');
      assert.equal(arrived.body.length, disk.length, '/ui/' + name + ' complete response with the wrong number of bytes');
      assert.equal(sha(arrived.body), sha(disk), '/ui/' + name + ' arrived with different bytes than src/ui on disk');
      checks += 4;
      summary.push(name + ' ' + disk.length + ' B' + (tries.length ? ' after ' + tries.length + ' environmental stall(s)' : ''));
    }
    if (limited.length) {
      const line = 'not verified natively: ' + limited.join(', ') + ' (stall/reset in ' + MAX_TRIES + ' tries, or rewritten in transit); verified natively: ' + (summary.join(', ') || 'none') + ' (' + checks + ' checks)';
      if (strict) throw new Error('WSM_TEST_NO_DISK_UI=1: ' + line);
      console.log('ENVIRONMENT-LIMITED: ' + line + '. The loopback filter of this host stalls large responses and rewrites HTML (PLAN 17.119); this is reported, not passed (exit 3).');
      exitCode = 3;
    } else {
      console.log('PASS: ' + checks + ' checks; every /ui asset of the real console arrived natively byte-identical to src/ui and to the session hashes: ' + summary.join(', ') + '; all workflows set WSM_TEST_NO_DISK_UI=1.');
    }
  } catch (error) {
    console.error('FAIL after ' + checks + ' checks: ' + (error && error.stack || error));
    exitCode = 1;
  } finally {
    if (child && child.exitCode === null) { fs.writeFileSync(stopFile, 'stop'); await new Promise(resolve => { const timer = setTimeout(() => { child.kill(); resolve(); }, 6000); child.once('exit', () => { clearTimeout(timer); resolve(); }); }); }
    fs.rmSync(root, { recursive: true, force: true });
    process.exitCode = exitCode;
  }
})();
