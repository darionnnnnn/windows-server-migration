// N4 / 16.6-1, HTTP route layer: StartBackup was accepted (202) but the client never received the response.
// The same operation id + idempotency key is then sent again through the real /api/operations handler of a Source console.
// Real handler, real worker, real core (OwnerFreeze plan, real source freeze, capture, seal, verify, Directory delivery).
// Replays must return the original job, start no second worker and freeze no second time (read from durable state).
// Native Windows transport only; the core-level twin of this scenario is Test-WizardBackupReliability.ps1.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
// Environmental loopback resets: on this machine AdGuard's WFP driver resets a share of FRESH loopback TCP connections (20-50% between two bare
// node processes, no project code involved; PLAN 17.119). The poll loop in waitJob opens hundreds of connections, so a bare fetch fails every time.
// A request that dies with ECONNRESET is retried (max MAX_ENV_ATTEMPTS tries), every retry is printed and counted in the PASS line. Every
// request in this file is idempotent by design (GETs, and replays that carry the same operationId/idempotencyKey), and no assertion is relaxed:
// a console that resets deterministically still fails after the last try, and a wrong status or body fails on the first try.
const MAX_ENV_ATTEMPTS = 6;
const envRetries = [];
const isEnvReset = error => { for (let e = error; e; e = e.cause) { if (e.code === 'ECONNRESET' || /ECONNRESET/.test(String(e.message))) return true; } return false; };
async function envRetry(label, fn) {
  for (let attempt = 1; ; attempt++) {
    try { return await fn(); } catch (error) {
      if (!isEnvReset(error) || attempt >= MAX_ENV_ATTEMPTS) throw error;
      envRetries.push(label + ' try ' + attempt);
      if (envRetries.length <= 20) console.log('environmental loopback reset: ' + label + ' try ' + attempt + ' of ' + MAX_ENV_ATTEMPTS + '; retrying');
    }
  }
}
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-replay-'));
const drive = [...'RSTUVWXYZ'].find(letter => !fs.existsSync(`${letter}:\\`));
if (!drive) throw new Error('No free drive letter is available for the short fixture work root.');
let mappedDrive = false;
let child;
let checks = 0;
const logs = [];
const stopFile = path.join(tempRoot, 'stop');
const ready = path.join(tempRoot, 'ready.json');

function note(message) { logs.push(message); }
function check(condition, message) { assert.ok(condition, message); checks++; }

async function main() {
  execFileSync('subst.exe', [`${drive}:`, tempRoot]);
  mappedDrive = true;
  // Run the real, unmodified src from a throw-away copy. Only host qualification (machine identity, preflight, local inventory
  // observation) is substituted by an overlay appended to the COPIED module, exactly as the native runtime handler test does.
  const repoRoot = path.resolve(__dirname, '..');
  const snapshot = path.join(tempRoot, 'snapshot');
  fs.mkdirSync(path.join(snapshot, 'tests'), { recursive: true });
  fs.cpSync(path.join(repoRoot, 'src'), path.join(snapshot, 'src'), { recursive: true });
  for (const name of ['Start-ServerMigration.ps1', 'Start-ServerMigration.cmd']) {
    if (fs.existsSync(path.join(repoRoot, name))) fs.copyFileSync(path.join(repoRoot, name), path.join(snapshot, name));
  }
  for (const name of ['Start-WizardRuntimeTestServer.ps1', 'ExternalReadinessEvidenceFixtures.ps1']) fs.copyFileSync(path.join(__dirname, name), path.join(snapshot, 'tests', name));
  const identityOverlay = String.raw`
# TEST-ONLY controlled native identity observation; production sources remain untouched.
if ($env:WSM_RUNTIME_TEST_IDENTITY -eq '1') {
 function Get-WsmPreflight { [pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'} }
 function Get-WsmMachineIdentity { if ($env:WSM_RUNTIME_TEST_FINGERPRINT -notmatch '^[a-f0-9]{64}$') { throw 'Missing controlled runtime identity fingerprint.' }; [pscustomobject]@{Fingerprint=$env:WSM_RUNTIME_TEST_FINGERPRINT;Name='replay-runtime-fixture';OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true} }
 function script:Export-WsmInventory { param([string]$OutputDirectory,[switch]$DeepDiscovery);$fixturePath=[string]$env:WSM_RUNTIME_TEST_INVENTORY_PATH;if(-not $fixturePath -or -not [IO.File]::Exists($fixturePath)){throw 'Controlled runtime inventory observation fixture is unavailable.'};[pscustomobject]@{Path=[IO.Path]::GetFullPath($fixturePath);SHA256=(Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()} }
}
`;
  fs.appendFileSync(path.join(snapshot, 'src', 'WindowsServerMigration.psm1'), identityOverlay, 'utf8');
  const workspace = `${drive}:\\ws`;
  const captures = path.join(tempRoot, 'captures');
  fs.mkdirSync(captures, { recursive: true });
  child = spawn(process.env.WSM_PS_EXE || 'powershell.exe', [
    '-NoProfile', '-File', path.join(snapshot, 'tests', 'Start-WizardRuntimeTestServer.ps1'),
    '-Role', 'Source', '-Workspace', workspace, '-ReadyPath', ready, '-StopFile', stopFile,
    '-ResponseCapturePath', captures, '-PayloadRoot', tempRoot, '-FreezeFixture'
  ], {
    windowsHide: true,
    env: {
      ...process.env,
      WSM_RUNTIME_TEST_IDENTITY: '1',
      WSM_RUNTIME_TEST_HOLD_CANCEL: '0',
      WSM_RUNTIME_TEST_FINGERPRINT: 'a'.repeat(64),
      PSModulePath: path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'Modules')
    }
  });
  child.stdout.on('data', data => note('STDOUT ' + data.toString().trim()));
  child.stderr.on('data', data => note('STDERR ' + data.toString().trim()));
  const startupDeadline = Date.now() + 180000;
  while (!fs.existsSync(ready) || !fs.existsSync(ready + '.fixture')) {
    if (child.exitCode !== null || Date.now() > startupDeadline) throw new Error('Source console did not start.\n' + logs.join('\n'));
    await sleep(200);
  }
  const origin = JSON.parse(fs.readFileSync(ready, 'utf8')).Url.replace(/\/$/, '');
  const port = Number(new URL(origin).port);
  const fixture = JSON.parse(fs.readFileSync(ready + '.fixture', 'utf8'));
  const session = await envRetry('GET /api/session', async () => (await fetch(origin + '/api/session', { signal: AbortSignal.timeout(30000) })).json());
  assert.equal(session.role, 'Source');
  assert.equal(String(session.pairId || ''), String(fixture.PairId));

  const headers = { 'Content-Type': 'application/json', Origin: origin, 'X-Wsm-Token': session.token };
  const call = (route, body) => envRetry((body ? 'POST ' : 'GET ') + route.replace(/[0-9a-f]{8}-[0-9a-f-]{27}/g, '<id>'), async () => {
    const response = await fetch(origin + route, { signal: AbortSignal.timeout(60000), method: body ? 'POST' : 'GET', headers, ...(body ? { body: JSON.stringify(body) } : {}) });
    let data = null;
    try { data = await response.json(); } catch (error) { if (isEnvReset(error)) throw error; data = null; }
    return { status: response.status, data };
  });
  const requestFor = (operationId, idempotencyKey) => ({
    action: 'StartBackup',
    args: {
      DeliveryMode: 'Directory', VolumeBytes: 0,
      Owner: fixture.FreezeOwner, Evidence: fixture.FreezeEvidenceText,
      FreezeExternalEvidencePath: fixture.FreezeEvidencePath, FreezeExternalEvidenceHash: fixture.FreezeEvidenceHash,
      FreezeAuthorization: true
    },
    operationId, idempotencyKey,
    expectedRevision: Number(session.revision),
    expectedDecisionRevision: session.decisionRevision,
    expectedSelectionRevision: session.selectionRevision,
    expectedDataVersion: session.dataVersion,
    contextId: String(session.contextId || '')
  });
  // The client writes the whole request and hangs up before it reads anything: the 202 is lost.
  const sendAndAbandon = body => new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const socket = net.connect(port, '127.0.0.1', () => {
      socket.write(`POST /api/operations HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nOrigin: ${origin}\r\nX-WSM-Token: ${session.token}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(data)}\r\nConnection: close\r\n\r\n${data}`, () => {
        socket.destroy();
        resolve();
      });
    });
    socket.on('error', reject);
  });
  // The abandoned submission only counts when the console really took it (its job record exists). A connection that the environment reset
  // before the request arrived is sent again; the scenario premise (accepted, 202 lost) is checked, not assumed.
  const abandonUntilAccepted = async body => {
    for (let attempt = 1; ; attempt++) {
      try { await sendAndAbandon(body); } catch (error) { if (!isEnvReset(error)) throw error; }
      const deadline = Date.now() + 20000;
      while (Date.now() < deadline) {
        const lookup = await call('/api/jobs/' + body.operationId);
        if (lookup.status === 200 && lookup.data) return attempt;
        await sleep(250);
      }
      if (attempt >= MAX_ENV_ATTEMPTS) throw new Error('the abandoned submission never reached the console in ' + attempt + ' tries');
      envRetries.push('abandoned POST /api/operations never arrived, try ' + attempt);
      console.log('environmental loopback reset: the abandoned submission never arrived (no job record), try ' + attempt + '; sending again');
    }
  };
  const sourceRoot = path.join(workspace, 'source');
  const pairId = String(fixture.PairId);
  const attemptsDir = path.join(sourceRoot, 'workspace-control', 'wizard-backups', pairId);
  const pairsDir = path.join(sourceRoot, 'pairs');
  const jobsDir = path.join(sourceRoot, 'console-jobs');
  const listFiles = (dir, filter) => fs.existsSync(dir) ? fs.readdirSync(dir, { withFileTypes: true }).filter(entry => filter(entry)).map(entry => entry.name) : [];
  const walk = dir => !fs.existsSync(dir) ? [] : fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)]);
  const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const treeDigest = dir => walk(dir).sort().map(file => `${path.relative(dir, file)}|${digest(file)}`).join('\n');
  const durableState = () => ({
    attemptRecords: listFiles(attemptsDir, entry => entry.isFile() && entry.name.endsWith('.json')),
    freezeFolders: listFiles(pairsDir, entry => entry.isDirectory() && entry.name.startsWith(`freeze-${pairId}-`)),
    jobRecords: listFiles(jobsDir, entry => entry.isFile() && entry.name.endsWith('.json')),
    attemptFolders: listFiles(path.join(pairsDir, pairId, 'attempts'), entry => entry.isDirectory())
  });
  const waitJob = async operationId => {
    const deadline = Date.now() + 240000;
    let record;
    do {
      const response = await call('/api/jobs/' + operationId);
      if (response.status === 200 && response.data) {
        record = response.data;
        if (['Succeeded', 'Failed', 'Cancelled', 'Interrupted', 'ReviewRequired', 'Blocked'].includes(String(record.status))) return record;
      }
      await sleep(250);
    } while (Date.now() < deadline);
    throw new Error('The backup job did not reach a terminal state: ' + JSON.stringify(record));
  };

  const before = durableState();
  check(before.attemptRecords.length === 0 && before.freezeFolders.length === 0, 'fixture starts without an attempt or a freeze');
  const operationId = crypto.randomUUID();
  const idempotencyKey = crypto.randomUUID();
  const body = requestFor(operationId, idempotencyKey);

  const abandonTries = await abandonUntilAccepted(body);
  console.log('abandoned submission accepted by the console after ' + abandonTries + ' send(s); its 202 was never read');
  // In-flight replay: the first worker may still be freezing / capturing.
  const inFlight = await call('/api/operations', body);
  check([200, 202].includes(inFlight.status) && inFlight.data && inFlight.data.job && inFlight.data.job.jobId === operationId, 'in-flight replay returned the original job: ' + JSON.stringify(inFlight));
  check(inFlight.status === 200, 'a replay is answered as a replay (200), not as a new acceptance (202)');
  const finished = await waitJob(operationId);
  assert.equal(finished.status, 'Succeeded', JSON.stringify(finished.error || finished));
  const output = (finished.outputs || []).find(row => row && row.Kind === 'WizardBackupResult');
  check(output && output.Status === 'Delivered' && output.Delivery && output.Delivery.SHA256, 'the abandoned submission still produced a delivered backup');

  const afterFirst = durableState();
  check(afterFirst.attemptRecords.length === 1 && afterFirst.attemptRecords[0] === operationId + '.json', 'exactly one backup attempt record exists');
  check(afterFirst.freezeFolders.length === 1, 'the real source freeze ran once: ' + afterFirst.freezeFolders.length);
  check(afterFirst.jobRecords.length === before.jobRecords.length + 1, 'exactly one console job record was added');
  check(afterFirst.attemptFolders.length === 1, 'exactly one output attempt folder exists');
  const jobFile = path.join(jobsDir, operationId + '.json');
  const jobBytes = digest(jobFile);
  const attemptFile = path.join(attemptsDir, operationId + '.json');
  const attemptDigest = digest(attemptFile);
  const attemptTree = treeDigest(path.join(pairsDir, pairId, 'attempts'));
  const attemptRecord = JSON.parse(fs.readFileSync(attemptFile, 'utf8').replace(/^\uFEFF/, ''));
  check(attemptRecord.OperationIds.length === 1 && Number(attemptRecord.ResumeCount) === 0, 'the attempt records one operation and no resume');

  // Replay after completion, same id and same key.
  const late = await call('/api/operations', body);
  check(late.status === 200 && late.data.job && late.data.job.jobId === operationId && late.data.job.status === 'Succeeded', 'late replay returned the original finished job: ' + JSON.stringify(late));
  const lateOutput = (late.data.job.outputs || []).find(row => row && row.Kind === 'WizardBackupResult');
  check(lateOutput && lateOutput.AttemptId === output.AttemptId && lateOutput.Delivery.SHA256 === output.Delivery.SHA256, 'late replay carries the same attempt and the same delivered bytes');
  // Same id with a new idempotency key is not a replay, it is refused; so is the same key with another operation id.
  const reusedId = await call('/api/operations', requestFor(operationId, crypto.randomUUID()));
  check(reusedId.status >= 400 && reusedId.status < 500, 'a reused operation id with a new key was accepted: ' + JSON.stringify(reusedId));
  const reusedKey = await call('/api/operations', requestFor(crypto.randomUUID(), idempotencyKey));
  check(reusedKey.status >= 400 && reusedKey.status < 500, 'a reused idempotency key with a new operation id was accepted: ' + JSON.stringify(reusedKey));

  const afterReplays = durableState();
  check(JSON.stringify(afterReplays) === JSON.stringify(afterFirst), 'replays changed the durable state: ' + JSON.stringify(afterReplays));
  check(digest(jobFile) === jobBytes, 'replays rewrote the original job record');
  check(digest(attemptFile) === attemptDigest && treeDigest(path.join(pairsDir, pairId, 'attempts')) === attemptTree, 'replays changed the backup attempt or its output');
  const jobsList = await call('/api/jobs');
  check(jobsList.status === 200 && (jobsList.data.items || []).filter(job => job.jobId === operationId).length === 1, 'the job registry holds the operation exactly once');
  console.log(`PASS: ${checks} route-level checks: lost 202, same operation id replayed in flight and after completion, one worker, one freeze, original job returned. Environmental ECONNRESET retries: ${envRetries.length}${envRetries.length ? ' [' + envRetries.slice(0, 30).join('; ') + (envRetries.length > 30 ? '; ...' : '') + ']' : ''}.`);
}

(async () => {
  try {
    await main();
  } catch (error) {
    console.error(error);
    console.error(logs.slice(-40).join('\n'));
    process.exitCode = 1;
  } finally {
    try { fs.writeFileSync(stopFile, 'stop'); } catch (error) { /* ignore */ }
    if (child) {
      await new Promise(resolve => {
        const timer = setTimeout(() => { if (child.exitCode === null) child.kill(); resolve(); }, 15000);
        child.once('exit', () => { clearTimeout(timer); resolve(); });
        if (child.exitCode !== null) { clearTimeout(timer); resolve(); }
      });
    }
    if (mappedDrive) { try { execFileSync('subst.exe', [`${drive}:`, '/D']); } catch (error) { /* ignore */ } }
    try { fs.rmSync(tempRoot, { recursive: true, force: true }); } catch (error) { /* ignore */ }
  }
})();
