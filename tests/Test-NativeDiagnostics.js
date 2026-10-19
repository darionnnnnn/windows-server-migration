'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { cleanProbeDiagnostic, cleanProbeTerminalJob, cleanRuntimeDiagnostic, writeProbeDiagnostics, writeRuntimeDiagnostics } = require('./native-diagnostics');

let checks = 0;
function check(condition, message) { assert.ok(condition, message); checks++; }
function hasCanary(value) { return JSON.stringify(value).includes('CANARY'); }
async function reserveThenRefuse() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => { listener.once('error', reject); listener.listen(0, '127.0.0.1', resolve); });
  const port = listener.address().port;
  await new Promise((resolve, reject) => listener.close(error => error ? reject(error) : resolve()));
  let attempts = 0;
  const route = `/api/jobs/12345678-1234-1234-1234-123456789012?token=TOKENCANARY`;
  const error = await new Promise(resolve => {
    attempts++;
    const request = http.get({ hostname: '127.0.0.1', port, path: route, headers: { 'X-Wsm-Token': 'TOKENCANARY' } }, response => {
      response.resume(); resolve(null);
    });
    request.once('error', resolve);
  });
  return { port, route, attempts, error };
}

async function runTests() {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-native-diagnostics-'));
  try {
    const refusal = await reserveThenRefuse();
    check(refusal.attempts === 1 && refusal.error?.code === 'ECONNREFUSED', 'controlled TCP route must observe one actual loopback refusal');
    const probeFile = path.join(temp, 'native-probe-diagnostics.json');
    const probe = {
      engine: 'pwsh', sourceCommit: 'a'.repeat(40), runId: '123-1', capturedUtc: new Date().toISOString(),
      lifecycle: [
        { atUtc: new Date().toISOString(), type: 'server-started', role: 'Target', pid: process.pid, token: 'TOKENCANARY' },
        { atUtc: new Date().toISOString(), type: 'server-closed', role: 'Target', pid: process.pid, exitCode: 0 }
      ],
      requests: [{ atUtc: new Date().toISOString(), role: 'Target', pid: process.pid, method: 'GET',
        route: refusal.route, body: 'BODYCANARY',
        fetchError: { name: 'Error', code: refusal.error.code, message: 'TOKENCANARY BODYCANARY' },
        server: { pid: process.pid, exitCode: null, killed: false, spawnError: { name: 'Error', message: 'BODYCANARY', code: 'EACCES' } } }],
      servers: [{ role: 'Target', pid: process.pid, startedUtc: new Date().toISOString(), origin: 'http://127.0.0.1:12345',
        spawnError: { name: 'Error', message: 'TOKENCANARY', code: 'EACCES' }, output: { lineCount: 1, loopbackAnnouncements: 1, otherLineCount: 0 } }]
    };
    writeProbeDiagnostics(probeFile, probe);
    const probeSaved = JSON.parse(fs.readFileSync(probeFile, 'utf8'));
    check(probeSaved.requests.length === 1 && probeSaved.requests[0].error.code === 'ECONNREFUSED', 'refusal diagnosis must be retained in native evidence diagnostics');
    check(probeSaved.requests[0].route === '/api/jobs/<id>' && !('body' in probeSaved.requests[0]), 'route identifiers and request bodies must be omitted');
    check(!hasCanary(probeSaved), 'Probe diagnostic sidecar must not retain token/body canaries');
    check(probeSaved.lifecycle.length === 2 && probeSaved.servers[0].pid === process.pid, 'Probe diagnostics must retain bounded route and lifecycle context');
    check(cleanProbeDiagnostic({ requests: [{ route: `https://outside.invalid/api/jobs/12345678-1234-1234-1234-123456789012?token=TOKENCANARY` }] }).requests[0].route === '/api/jobs/<id>', 'diagnostics must discard origins and query values');
    const failedTerminal = cleanProbeTerminalJob({
      status: 'Failed', stage: 'Failed', message: 'TOKENCANARY BODYCANARY C:\\private\\inventory.json',
      error: { code: 'operation_failed', correlationId: '89abcdef-0123-4567-89ab-cdef01234567', message: 'TOKENCANARY BODYCANARY', nextStep: 'C:\\private\\inventory.json' },
      outputs: [{ Status: 'Failed', Path: 'C:\\private\\inventory.json', CollectorResults: [
        { Id: 'HttpProbe', Status: 'Failed', ReasonCode: 'CollectorFailed', Error: 'TOKENCANARY' },
        { Id: 'NativeInventory', Status: 'PermissionDenied', ReasonCode: 'TOKENCANARY', Inventory: 'BODYCANARY' },
        { Id: 'UnsafeCANARY', Status: 'Failed', ReasonCode: 'TOKENCANARY' }
      ] }]
    }, 'Manager');
    check(failedTerminal.role === 'Manager' && failedTerminal.status === 'Failed' && failedTerminal.outputs[0].status === 'Failed' && failedTerminal.failureCode === 'operation_failed' && failedTerminal.correlationId === '89abcdef-0123-4567-89ab-cdef01234567',
      'terminal job projection must retain role, fixed failure category, correlation id and output state');
    check(failedTerminal.outputs[0].collectors.length === 2 && failedTerminal.outputs[0].collectors[0].reasonCode === 'CollectorFailed',
      'terminal job projection must retain only known collector identities, statuses and reason codes');
    check(!('reasonCode' in failedTerminal.outputs[0].collectors[1]), 'unknown collector reason codes must be discarded');
    check(!hasCanary(failedTerminal) && !('message' in failedTerminal) && !('path' in failedTerminal.outputs[0]),
      'terminal job projection must omit exception text, paths, inventory and unknown fields');
    const failedWithoutOutput = cleanProbeTerminalJob({ status: 'Failed', error: { code: 'permission_denied', correlationId: 'fedcba98-7654-3210-fedc-ba9876543210', message: 'TOKENCANARY' }, outputs: [] }, 'Manager');
    check(failedWithoutOutput.status === 'Failed' && failedWithoutOutput.failureCode === 'permission_denied' && failedWithoutOutput.outputs.length === 0,
      'a failed job with no outputs must retain only its known safe error category and correlation id');
    const invalidFailure = cleanProbeTerminalJob({ status: 'Failed', error: { code: 'TOKENCANARY', correlationId: 'not-a-guid', message: 'BODYCANARY' } }, 'Manager');
    check(!('failureCode' in invalidFailure) && !('correlationId' in invalidFailure) && !hasCanary(invalidFailure),
      'unrecognized failure codes and malformed correlation ids must be dropped');
    check(!('failureCode' in cleanProbeDiagnostic({ terminalJobs: [{ role: 'Manager', status: 'Failed', failureCode: 'TOKENCANARY', correlationId: 'BODYCANARY' }] }).terminalJobs[0]),
      'diagnostic file sanitizer must independently reject untrusted failure codes and correlation ids');
    const terminalFile = path.join(temp, 'terminal-jobs.json');
    writeProbeDiagnostics(terminalFile, { engine: 'powershell', terminalJobs: [failedTerminal] });
    const terminalSaved = JSON.parse(fs.readFileSync(terminalFile, 'utf8'));
    check(terminalSaved.terminalJobs.length === 1 && terminalSaved.terminalJobs[0].status === 'Failed' && terminalSaved.terminalJobs[0].role === 'Manager' && terminalSaved.terminalJobs[0].failureCode === 'operation_failed' && terminalSaved.terminalJobs[0].correlationId === '89abcdef-0123-4567-89ab-cdef01234567',
      'actual sanitized terminal projection must retain the safe error class through the native job diagnostic writer');
    check(!hasCanary(terminalSaved), 'saved terminal diagnostics must remove exception, path and body canaries');

    const roleRoot = path.join(temp, 'target-role'); fs.mkdirSync(roleRoot);
    const responseCapture = path.join(roleRoot, 'captures'); fs.mkdirSync(responseCapture);
    const ready = path.join(roleRoot, 'diagnostic-result.json');
    const payload = path.join(roleRoot, 'payload'); fs.mkdirSync(payload);
    const executable = process.env.WSM_PS_EXE || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');
    const selectedEngine = path.basename(executable).toLowerCase().startsWith('pwsh') ? 'pwsh' : 'powershell';
    const args = ['-NoProfile', '-NonInteractive', '-File', path.join(__dirname, 'Start-WizardRuntimeTestServer.ps1'),
      '-Role', 'Target', '-Workspace', path.join(roleRoot, 'workspace'), '-ReadyPath', ready,
      '-StopFile', path.join(roleRoot, 'stop'), '-ResponseCapturePath', responseCapture, '-PayloadRoot', payload, '-DiagnosticSelfTest'];
    const child = spawnSync(executable, args, { encoding: 'utf8', windowsHide: true, timeout: 60000 });
    if (child.error?.code === 'ENOENT') throw new Error(`Native diagnostic boundary requires ${executable} on this host.`);
    assert.equal(child.status, 0, `Controlled PowerShell worker failure failed: ${child.stderr || child.stdout}`);
    const result = JSON.parse(fs.readFileSync(ready, 'utf8'));
    check(result.SafeResponse?.code === 'operation_failed', 'worker exception must retain the fixed generic public error code');
    check(!hasCanary(result.SafeResponse), 'public safe response must not contain controlled exception canaries');
    check(fs.existsSync(result.CapturedPath), 'same safe-error boundary must capture worker exception metadata');
    const rawRecords = fs.readFileSync(result.CapturedPath, 'utf8').trim().split(/\r?\n/).map(line => JSON.parse(line));
    check(rawRecords.length === 1 && rawRecords[0].FixtureScope === 'ControlledWizardRuntime', 'worker diagnostic must remain fixture scoped');
    check(rawRecords[0].ExceptionType && rawRecords[0].FullyQualifiedErrorId, 'worker exception type and PowerShell failure identity must survive safe mapping');
    const cleaned = cleanRuntimeDiagnostic(rawRecords[0]);
    check(cleaned.JournalMismatch?.Predicate === 'PreviousHash' && cleaned.JournalMismatch.ExpectedSequence === 7 && cleaned.JournalMismatch.ObservedSequence === 8 && cleaned.JournalMismatch.SamePair === true && cleaned.JournalMismatch.SameRun === false && cleaned.JournalMismatch.PreviousHashMatches === false,
      'bounded journal verifier scalars must survive the fixture collector and sanitizer');
    check(!hasCanary(cleaned), 'sanitized diagnostic must redact token, body and raw hash canaries');
    const evidenceFile = path.join(temp, 'native-evidence', 'native-runtime-diagnostics.json');
    writeRuntimeDiagnostics(evidenceFile, { mode: 'target', engine: selectedEngine, transport: 'native-http-edge', sourceCommit: 'b'.repeat(40), runId: '456-1' }, rawRecords);
    fs.rmSync(roleRoot, { recursive: true, force: true });
    check(fs.existsSync(evidenceFile), 'sanitized worker diagnostic must survive fixture cleanup for evidence upload');
    const saved = JSON.parse(fs.readFileSync(evidenceFile, 'utf8'));
    check(saved.records.length === 1 && saved.records[0].DiagnosticId === rawRecords[0].DiagnosticId && !hasCanary(saved),
      'uploaded runtime diagnostic must retain the captured failure identity without fixture secrets');
    check(saved.records[0].JournalMismatch?.Predicate === 'PreviousHash' && !('WsmJournalRawHash' in saved.records[0].JournalMismatch),
      'uploaded diagnostics retain only the allowlisted mismatch scalars and omit raw hashes');
    const rejectedMismatch = cleanRuntimeDiagnostic({ ...rawRecords[0], JournalMismatch: { Predicate: 'Unknown', ExpectedSequence: 1, ObservedSequence: 1, SamePair: true, SameRun: true, PreviousHashMatches: true } });
    check(!('JournalMismatch' in rejectedMismatch), 'unknown journal predicates are omitted from sanitized diagnostics');
    let unsafeRejected = false;
    try { writeRuntimeDiagnostics(path.join(temp, 'unsafe.json'), {}, [{ SchemaVersion: 1, Role: 'Source', FixtureScope: 'Host' }]); }
    catch { unsafeRejected = true; }
    check(unsafeRejected, 'unscoped runtime diagnostic must be rejected');
    process.stdout.write(`PASS Test-NativeDiagnostics: ${checks} refusal, lifecycle, redaction, safe-error, cleanup and scope checks.\n`);
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
}

if (require.main === module) runTests().catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { runTests };
