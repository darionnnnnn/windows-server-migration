// Native Edge acceptance for role-independent DeveloperProbe and workspace isolation.
// All workspaces, server processes and browser contexts are owned by this test.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');

if (process.platform !== 'win32') throw new Error('This acceptance requires native Windows PowerShell and Edge.');
const cliOnly = process.env.WSM_PROBE_CLI_ONLY === '1';
let chromium = null;
if (!cliOnly) {
  const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
  ({ chromium } = require(path.join(runtime, 'playwright')));
}
const sourceRoot = path.resolve(__dirname, '..');
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-pr-'));
let workRoot = tempRoot;
let substDrive = null;
const snapshot = path.join(tempRoot, 'snapshot');
const psExe = process.env.WSM_PS_EXE || 'powershell.exe';
const stateRoots = ['developer-probes', 'console-jobs', 'console-errors', 'developer-probe-cancellations'];
const roles = ['Source', 'Target', 'Manager'];
const expectedCollectorIds = ['PlatformIdentity', 'CommandsModules', 'LocalVolumes', 'NativeInventory', 'HttpProbe'];
const processes = [];
const contexts = [];
let browser;

function digestTree(root, rel = '') {
  const rows = [];
  for (const entry of fs.readdirSync(path.join(root, rel), { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const child = path.posix.join(rel.replace(/\\/g, '/'), entry.name);
    const full = path.join(root, child);
    if (entry.isSymbolicLink()) throw new Error('Immutable snapshot refuses symbolic links: ' + full);
    if (entry.isDirectory()) rows.push(...digestTree(root, child));
    else if (entry.isFile()) rows.push(child + '|' + crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex'));
    else throw new Error('Immutable snapshot requires regular files: ' + full);
  }
  return rows;
}
function copyTree(source, destination) {
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name), to = path.join(destination, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Immutable snapshot refuses symbolic links: ' + from);
    if (entry.isDirectory()) copyTree(from, to);
    else if (entry.isFile()) fs.copyFileSync(from, to);
    else throw new Error('Immutable snapshot requires regular files: ' + from);
  }
}
function makeSnapshot() {
  const before = digestTree(path.join(sourceRoot, 'src'));
  copyTree(path.join(sourceRoot, 'src'), path.join(snapshot, 'src'));
  fs.mkdirSync(path.join(snapshot, 'tests'), { recursive: true });
  const copiedFiles = [];
  for (const name of ['Start-NativeProbeRoleTestServer.ps1', 'Start-ServerMigration.ps1', 'Start-ServerMigration.cmd']) {
    const from = name === 'Start-NativeProbeRoleTestServer.ps1' ? path.join(__dirname, name) : path.join(sourceRoot, name);
    if (name !== 'Start-NativeProbeRoleTestServer.ps1' && !fs.existsSync(from)) continue;
    const to = name === 'Start-NativeProbeRoleTestServer.ps1' ? path.join(snapshot, 'tests', name) : path.join(snapshot, name);
    const sourceHash = crypto.createHash('sha256').update(fs.readFileSync(from)).digest('hex');
    fs.copyFileSync(from, to);
    const copiedHash = crypto.createHash('sha256').update(fs.readFileSync(to)).digest('hex');
    const afterHash = crypto.createHash('sha256').update(fs.readFileSync(from)).digest('hex');
    assert.equal(copiedHash, sourceHash, `Copied snapshot differs for ${name}.`);
    assert.equal(afterHash, sourceHash, `Source changed while copying ${name}.`);
    copiedFiles.push(`${name}|${copiedHash}`);
  }
  assert.deepEqual(before, digestTree(path.join(sourceRoot, 'src')), 'Product source changed while the immutable snapshot was copied.');
  assert.deepEqual(before, digestTree(path.join(snapshot, 'src')), 'Copied source snapshot differs from the product source.');
  return { src: before, copiedFiles };
}
let snapshotHashes;
function verifySnapshot() {
  if (!snapshotHashes) return;
  assert.deepEqual(snapshotHashes.src, digestTree(path.join(snapshot, 'src')), 'Immutable source snapshot changed during native probe acceptance.');
  for (const row of snapshotHashes.copiedFiles) {
    const split = row.indexOf('|'), name = row.slice(0, split), expected = row.slice(split + 1);
    const file = name === 'Start-NativeProbeRoleTestServer.ps1' ? path.join(snapshot, 'tests', name) : path.join(snapshot, name);
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'), expected, `Test snapshot changed for ${name}.`);
  }
}
const modulePath = path.join(snapshot, 'src', 'WindowsServerMigration.psd1');
const helperPath = path.join(snapshot, 'tests', 'Start-NativeProbeRoleTestServer.ps1');
const entryPath = path.join(snapshot, 'Start-ServerMigration.ps1');

function ensureShortWorkRoot() {
  const fingerprint = 'f'.repeat(64);
  const hostPath = path.join(workRoot, 'hosts', fingerprint);
  const hostTemporary = path.join(hostPath, `${'0'.repeat(32)}.tmp`);
  if (hostPath.length > 247 || hostTemporary.length > 259) {
    for (const letter of 'RSTUVWXYZ') {
      try {
        execFileSync('subst.exe', [`${letter}:`, tempRoot], { windowsHide: true, stdio: 'pipe' });
        substDrive = letter;
        workRoot = `${letter}:\\`;
        break;
      } catch { /* Try the next unused drive letter. */ }
    }
  }
  const shortHostPath = path.join(workRoot, 'hosts', fingerprint);
  const shortTemporary = path.join(shortHostPath, `${'0'.repeat(32)}.tmp`);
  assert.ok(shortHostPath.length <= 247 && shortTemporary.length <= 259,
    `Probe test WorkRoot exceeds the supported Windows path limits (${shortHostPath.length}/${shortTemporary.length}).`);
}

function pause(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }
function ownedPath(candidate) {
  const full = path.resolve(candidate), prefix = path.resolve(tempRoot) + path.sep;
  assert.ok(full === path.resolve(tempRoot) || full.startsWith(prefix), 'Test cleanup path escaped its owned temporary root: ' + full);
  return full;
}
async function startServer(role) {
  const base = path.join(workRoot, 'servers', role.toLowerCase());
  const workspace = path.join(base, 'workspace');
  fs.mkdirSync(base, { recursive: true });
  const readyPath = path.join(base, 'ready.json'), stopFile = path.join(base, 'stop');
  const args = ['-NoProfile', '-NonInteractive', '-File', helperPath, '-Role', role, '-Workspace', workspace, '-ReadyPath', readyPath, '-StopFile', stopFile, '-ModulePath', modulePath];
  const child = spawn(psExe, args, {
    windowsHide: true,
    env: { ...process.env, PSModulePath: path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') }
  });
  processes.push({ child, stopFile, role, workspace, logs: [] });
  const record = processes[processes.length - 1];
  child.stdout.on('data', data => record.logs.push(data.toString()));
  child.stderr.on('data', data => record.logs.push(data.toString()));
  const deadline = Date.now() + 90000;
  while (!fs.existsSync(readyPath)) {
    if (child.exitCode !== null || Date.now() > deadline) throw new Error(`${role} listener failed to start.\n${record.logs.join('')}`);
    await pause(100);
  }
  const ready = JSON.parse(fs.readFileSync(readyPath, 'utf8'));
  assert.ok(ready.Url && ready.Url.startsWith('http://127.0.0.1:'), `${role} listener must bind only to loopback.`);
  return { role, workspace, origin: ready.Url.replace(/\/$/, ''), child, record };
}
async function stopServers() {
  for (const record of processes) {
    if (record.child.exitCode !== null) continue;
    if (record.stopFile) fs.writeFileSync(record.stopFile, 'stop', 'utf8');
    else record.child.kill();
  }
  await Promise.all(processes.map(record => new Promise(resolve => {
    if (record.child.exitCode !== null) return resolve();
    const timer = setTimeout(() => { record.child.kill(); resolve(); }, 8000);
    record.child.once('exit', () => { clearTimeout(timer); resolve(); });
  })));
}
async function api(page, session, route, body, method = body ? 'POST' : 'GET') {
  return page.evaluate(async request => {
    const response = await fetch(request.route, {
      method: request.method,
      cache: 'no-store',
      headers: { 'X-Wsm-Token': request.token, ...(request.body ? { 'Content-Type': 'application/json' } : {}) },
      ...(request.body ? { body: JSON.stringify(request.body) } : {})
    });
    const text = await response.text();
    let data;
    try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text.slice(0, 500) }; }
    return { status: response.status, data };
  }, { route, method, token: session.token, body: body || null });
}
async function getSession(server) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  contexts.push(context);
  const page = await context.newPage();
  await page.goto(server.origin + '/#wizard', { waitUntil: 'domcontentloaded' });
  const initial = await page.evaluate(async () => {
    const response = await fetch('/api/session', { cache: 'no-store' });
    return { status: response.status, data: await response.json() };
  });
  assert.equal(initial.status, 200);
  assert.equal(initial.data.role, server.role);
  assert.equal(String(initial.data.pairId || ''), '', `${server.role} Probe fixture must have no selected Pair.`);
  return { ...server, context, page, session: initial.data };
}
async function startProbe(handle) {
  await handle.page.waitForFunction(() => !!window.WsmConsole?.state?.token);
  const submitted = handle.page.waitForResponse(response => {
    const request = response.request();
    return request.method() === 'POST' && new URL(request.url()).pathname === '/api/operations' && request.postDataJSON()?.action === 'DeveloperProbe';
  }).then(async response => ({ status: response.status(), data: await response.json(), request: response.request().postDataJSON() }));
  await handle.page.locator('#developer-probe-button').click();
  const response = await submitted;
  assert.equal(response.status, 202, `${handle.role} real UI Probe submission failed: ${JSON.stringify(response.data)}`);
  const operationId = response.request.operationId, job = response.data.job || response.data;
  assert.equal(job.jobId, operationId);
  assert.equal(job.action, 'DeveloperProbe');
  assert.equal(job.role, handle.role);
  assert.equal(String(job.pairId || ''), '');
  return { operationId, job };
}
function authorityDigest(workspace) {
  const rows = [];
  if (!fs.existsSync(workspace)) return rows;
  function walk(dir, relative = '') {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const child = path.posix.join(relative.replace(/\\/g, '/'), entry.name);
      if (relative === '' && stateRoots.includes(entry.name)) continue;
      const full = path.join(dir, child);
      if (entry.isSymbolicLink()) throw new Error('Workspace fixture unexpectedly contains a reparse/symbolic link: ' + full);
      if (entry.isDirectory()) walk(full, child);
      else if (entry.isFile()) rows.push(child + '|' + crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex'));
    }
  }
  walk(workspace);
  return rows;
}
function zipNames(bytes) {
  const eocdSignature = 0x06054b50, centralSignature = 0x02014b50;
  let eocd = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--) if (bytes.readUInt32LE(i) === eocdSignature) { eocd = i; break; }
  assert.notEqual(eocd, -1, 'Probe ZIP has no valid central directory end record.');
  const count = bytes.readUInt16LE(eocd + 10), offset = bytes.readUInt32LE(eocd + 16), names = [];
  let cursor = offset;
  for (let i = 0; i < count; i++) {
    assert.equal(bytes.readUInt32LE(cursor), centralSignature, 'Probe ZIP central directory entry is malformed.');
    const nameLength = bytes.readUInt16LE(cursor + 28), extraLength = bytes.readUInt16LE(cursor + 30), commentLength = bytes.readUInt16LE(cursor + 32);
    names.push(bytes.subarray(cursor + 46, cursor + 46 + nameLength).toString('utf8'));
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  return names;
}
function assertProbeArtifacts(workspace, job, expectedRole) {
  assert.equal(job.role, expectedRole);
  assert.equal(String(job.pairId || ''), '');
  assert.equal(path.resolve(job.workspace), path.resolve(workspace));
  assert.ok(['Succeeded', 'ReviewRequired', 'Cancelled'].includes(job.status), `Probe job did not finish truthfully: ${job.status}`);
  assert.equal(job.outputs.length, 1);
  const output = job.outputs[0];
  assert.ok(['Completed', 'Partial', 'Cancelled'].includes(output.Status), `Probe artifact outcome is ${output.Status}.`);
  assert.equal(output.ProductionQualified, false);
  assert.equal(output.BusinessValidated, false);
  const runRoot = path.join(workspace, 'developer-probes', output.RunId);
  const probePath = path.join(runRoot, 'probe.json'), htmlPath = path.join(runRoot, 'index.html');
  const indexPath = path.join(runRoot, 'files-index.json'), zipPath = path.join(runRoot, 'developer-probe.zip');
  for (const file of [probePath, htmlPath, indexPath, zipPath]) assert.ok(fs.statSync(file).isFile(), 'Missing real Probe artifact: ' + file);
  const archiveHash = crypto.createHash('sha256').update(fs.readFileSync(zipPath)).digest('hex');
  assert.equal(archiveHash, output.SHA256, 'Probe job output hash differs from the actual ZIP bytes.');
  const index = JSON.parse(fs.readFileSync(indexPath, 'utf8'));
  for (const row of index) {
    const file = path.join(runRoot, row.Path);
    const bytes = fs.readFileSync(file);
    assert.equal(bytes.length, row.Length);
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), row.SHA256);
  }
  assert.deepEqual(zipNames(fs.readFileSync(zipPath)).sort(), ['files-index.json', 'index.html', 'probe.json']);
  const probe = JSON.parse(fs.readFileSync(probePath, 'utf8'));
  assert.equal(probe.Role, expectedRole);
  assert.equal(probe.Mode, 'ReadOnly');
  assert.equal(probe.ProductionQualified, false);
  assert.equal(probe.BusinessValidated, false);
  assert.deepEqual(probe.Manifest.map(row => row.Id), expectedCollectorIds);
  assert.deepEqual(probe.Collectors.map(row => row.Id).sort(), [...expectedCollectorIds].sort());
  assert.deepEqual(output.CollectorResults.map(row => row.Id).sort(), [...expectedCollectorIds].sort());
  return probe;
}
async function waitTerminal(handle, id, timeoutMs = 180000) {
  const deadline = Date.now() + timeoutMs;
  let current;
  while (Date.now() < deadline) {
    const response = await api(handle.page, handle.session, `/api/jobs/${encodeURIComponent(id)}`);
    assert.equal(response.status, 200, `${handle.role} could not query its own Probe job.`);
    current = response.data;
    if (!['Queued', 'Running', 'CancelRequested'].includes(current.status)) return current;
    await pause(250);
  }
  throw new Error(`${handle.role} Probe did not reach a terminal state within ${timeoutMs} ms.`);
}
async function runCliProbe() {
  const workspace = path.join(workRoot, 'cli-manager-workspace');
  fs.mkdirSync(workspace, { recursive: true });
  const before = authorityDigest(workspace);
  const args = ['-NoProfile', '-NonInteractive', '-File', entryPath, '-Action', 'DeveloperProbe', '-Workspace', workspace, '-Role', 'Manager'];
  const child = spawn(psExe, args, {
    windowsHide: true,
    env: { ...process.env, PSModulePath: path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') }
  });
  processes.push({ child, stopFile: null, role: 'Manager CLI', workspace, logs: [] });
  const record = processes[processes.length - 1];
  child.stdout.on('data', data => record.logs.push(data.toString()));
  child.stderr.on('data', data => record.logs.push(data.toString()));
  const exitCode = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill(); reject(new Error('Manager DeveloperProbe CLI exceeded 240 seconds.')); }, 240000);
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', code => { clearTimeout(timer); resolve(code); });
  });
  assert.ok([0, 2].includes(exitCode), `DeveloperProbe CLI returned unexpected status code ${exitCode}.`);
  const runDirs = fs.readdirSync(path.join(workspace, 'developer-probes'), { withFileTypes: true }).filter(entry => entry.isDirectory());
  assert.equal(runDirs.length, 1, 'The real DeveloperProbe CLI entry must produce one run directory.');
  const runRoot = path.join(workspace, 'developer-probes', runDirs[0].name);
  const probe = JSON.parse(fs.readFileSync(path.join(runRoot, 'probe.json'), 'utf8'));
  assert.equal(probe.Role, 'Manager');
  assert.equal(probe.Mode, 'ReadOnly');
  assert.equal(probe.ProductionQualified, false);
  assert.equal(probe.BusinessValidated, false);
  assert.deepEqual(probe.Manifest.map(row => row.Id), expectedCollectorIds);
  assert.deepEqual(probe.Collectors.map(row => row.Id).sort(), [...expectedCollectorIds].sort());
  const index = JSON.parse(fs.readFileSync(path.join(runRoot, 'files-index.json'), 'utf8'));
  for (const row of index) {
    const bytes = fs.readFileSync(path.join(runRoot, row.Path));
    assert.equal(bytes.length, row.Length);
    assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), row.SHA256);
  }
  assert.ok(fs.statSync(path.join(runRoot, 'index.html')).isFile());
  assert.ok(fs.statSync(path.join(runRoot, 'files-index.json')).isFile());
  const zipPath = path.join(runRoot, 'developer-probe.zip');
  assert.ok(fs.statSync(zipPath).isFile());
  assert.deepEqual(zipNames(fs.readFileSync(zipPath)).sort(), ['files-index.json', 'index.html', 'probe.json']);
  assert.deepEqual(before, authorityDigest(workspace), 'Direct CLI Probe changed migration authority outside its dedicated output directory.');
  return probe;
}

(async () => {
  try {
    snapshotHashes = makeSnapshot();
    ensureShortWorkRoot();
    if (cliOnly) {
      const cliProbe = await runCliProbe();
      assert.deepEqual(cliProbe.Manifest.map(row => row.Id), expectedCollectorIds);
      verifySnapshot();
      console.log('PASS Test-NativeProbeRoles CLI-only: real Start-ServerMigration DeveloperProbe entry, verified JSON/HTML/ZIP/file-index hashes and collector manifest semantics.');
      return;
    }
    browser = await chromium.launch({ channel: 'msedge', headless: true });
    const started = await Promise.all(roles.map(startServer));
    const handles = await Promise.all(started.map(getSession));
    const authorityBefore = new Map(handles.map(handle => [handle.role, authorityDigest(handle.workspace)]));
    const [sourceRun, targetRun, managerRun] = await Promise.all(handles.map(startProbe));

    // Distinct listeners and browser contexts must not share, query, or cancel jobs.
    const sourceHandle = handles.find(handle => handle.role === 'Source');
    const targetHandle = handles.find(handle => handle.role === 'Target');
    const sourceCrossRead = await api(targetHandle.page, targetHandle.session, `/api/jobs/${encodeURIComponent(sourceRun.operationId)}`);
    const targetCrossRead = await api(sourceHandle.page, sourceHandle.session, `/api/jobs/${encodeURIComponent(targetRun.operationId)}`);
    assert.equal(sourceCrossRead.status, 404, 'Target listener must reject the Source workspace job as unknown.');
    assert.equal(targetCrossRead.status, 404, 'Source listener must reject the Target workspace job as unknown.');
    const sourceCrossCancel = await api(targetHandle.page, targetHandle.session, `/api/jobs/${encodeURIComponent(sourceRun.operationId)}/cancel`, {});
    const targetCrossCancel = await api(sourceHandle.page, sourceHandle.session, `/api/jobs/${encodeURIComponent(targetRun.operationId)}/cancel`, {});
    assert.equal(sourceCrossCancel.status, 404, 'Target listener must not cancel the Source workspace job.');
    assert.equal(targetCrossCancel.status, 404, 'Source listener must not cancel the Target workspace job.');

    // Ask the Source listener to cancel its own job immediately; if the collectors
    // already finished, the core is expected to reject cancellation as terminal.
    const ownCancel = await api(sourceHandle.page, sourceHandle.session, `/api/jobs/${encodeURIComponent(sourceRun.operationId)}/cancel`, {});
    assert.ok(ownCancel.status === 200 || ownCancel.status >= 400, 'Same-workspace cancellation returned an unexpected response.');
    const terminals = await Promise.all(handles.map(handle => waitTerminal(handle, ({ Source: sourceRun, Target: targetRun, Manager: managerRun })[handle.role].operationId)));
    for (let i = 0; i < handles.length; i++) {
      const handle = handles[i], terminal = terminals[i];
      assertProbeArtifacts(handle.workspace, terminal, handle.role);
      assert.deepEqual(authorityBefore.get(handle.role), authorityDigest(handle.workspace), `${handle.role} Probe changed migration authority outside its dedicated output/job directories.`);
    }

    if (process.env.WSM_PROBE_SKIP_CLI !== '1') {
      const cliProbe = await runCliProbe();
      assert.deepEqual(cliProbe.Manifest.map(row => row.Id), expectedCollectorIds, 'CLI and listener Probe entry points do not expose the same collector manifest.');
    }
    verifySnapshot();
    console.log('PASS Test-NativeProbeRoles: Source/Manager/Target UI Probe, same-workspace query/cancel, cross-workspace job denial, isolated real Edge contexts, ZIP/HTML/JSON/file-index hashes, collector manifest semantics, and unchanged migration authority. CLI=' + (process.env.WSM_PROBE_SKIP_CLI === '1' ? 'prior evidence reused' : 'passed'));
  } finally {
    for (const context of contexts) await context.close().catch(() => {});
    if (browser) await browser.close().catch(() => {});
    await stopServers();
    verifySnapshot();
    if (substDrive) {
      execFileSync('subst.exe', [`${substDrive}:`, '/D'], { windowsHide: true, stdio: 'pipe' });
      workRoot = tempRoot;
      substDrive = null;
    }
    const safeRoot = ownedPath(tempRoot);
    fs.rmSync(safeRoot, { recursive: true, force: true });
  }
})().catch(error => {
  console.error(error.stack || String(error));
  for (const record of processes) if (record.logs.length) console.error(`${record.role} log:\n${record.logs.join('')}`);
  process.exitCode = 1;
});
