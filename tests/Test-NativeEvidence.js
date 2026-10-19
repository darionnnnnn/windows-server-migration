'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { startEvidence, validateRecord, validateFile } = require('./native-evidence');
const { runTests: runLauncherCleanupTests } = require('./Test-NativeLauncherCleanup');
const { runTests: runNativeDiagnosticTests } = require('./Test-NativeDiagnostics');
const configuredEngine = process.env.WSM_NATIVE_EVIDENCE_ENGINE || (path.basename(process.env.WSM_PS_EXE || 'pwsh.exe').toLowerCase().startsWith('powershell') ? 'powershell' : 'pwsh');

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-native-evidence-test-'));
const sourceCommit = '6eac316162cbcb19b5b0343e0d4cf12bb87bbf01';
const expected = {
  suite: 'native-runtime', engine: configuredEngine, transport: 'native-http-edge', mode: 'all',
  journeyCount: 2, sourceCommit, runId: 'test-run-1'
};
const file = path.join(temp, 'passed.json');
const previousEnvironment = { ...process.env };
let checks = 0;

function check(condition, message) {
  assert.ok(condition, message);
  checks++;
}

function rejected(record, scope = expected) {
  const errors = validateRecord(record, scope);
  check(errors.length > 0, 'invalid evidence must be rejected');
}

try {
  process.env.WSM_NATIVE_EVIDENCE_PATH = file;
  process.env.WSM_NATIVE_EVIDENCE_ENGINE = expected.engine;
  process.env.WSM_NATIVE_EVIDENCE_SOURCE_SHA = sourceCommit;
  process.env.GITHUB_RUN_ID = 'test-run';
  process.env.GITHUB_RUN_ATTEMPT = '1';
  const tracker = startEvidence({
    suite: expected.suite, transport: expected.transport, mode: expected.mode,
    expectedJourneyCount: expected.journeyCount,
    fixtureLimits: { productionQualification: false, liveWorkloads: false, externalSmbQualification: false, actualServices: false, controlledWorkloadFixtures: true }
  });
  let record = JSON.parse(fs.readFileSync(file, 'utf8'));
  check(record.status === 'Running' && record.completedJourneyCount === 0, 'driver start must leave durable provisional evidence');
  rejected(record);
  tracker.completeJourney('Source-cancel-probe', { role: 'Source', expectedTerminal: 'Cancelled' });
  tracker.completeJourney('Target-restore', { role: 'Target', expectedTerminal: 'Succeeded' });
  tracker.finish();
  record = validateFile(file, expected);
  check(record.status === 'Passed' && record.completedJourneyCount === 2, 'positive evidence must validate with its measured journey count');
  check(record.completedJourneys[0].expectedTerminal === 'Cancelled', 'expected cancellation inside a passing scenario remains a completed journey');
  const cliArgs = [path.join(__dirname, 'native-evidence.js'), 'validate', '--path', file, '--suite', expected.suite,
    '--engine', expected.engine, '--transport', expected.transport, '--mode', expected.mode,
    '--count', String(expected.journeyCount), '--commit', expected.sourceCommit, '--run-id', expected.runId];
  const cliPositive = spawnSync(process.execPath, cliArgs, { encoding: 'utf8' });
  check(cliPositive.status === 0 && cliPositive.stdout.includes('2 completed journeys'), 'workflow validation CLI must accept matching evidence');
  const cliNegative = spawnSync(process.execPath, cliArgs.map(argument => argument === expected.runId ? 'stale-run' : argument), { encoding: 'utf8' });
  check(cliNegative.status === 1 && cliNegative.stderr.includes('runId does not match'), 'workflow validation CLI must reject evidence reused from another run');

  const cloned = () => JSON.parse(JSON.stringify(record));
  let bad = cloned(); delete bad.engine; rejected(bad);
  bad = cloned(); bad.completedJourneyCount = 0; bad.completedJourneys = []; bad.expectedJourneyCount = 0; rejected(bad);
  bad = cloned(); bad.suite = 'native-probe'; rejected(bad);
  bad = cloned(); bad.engine = expected.engine === 'pwsh' ? 'powershell' : 'pwsh'; rejected(bad);
  bad = cloned(); bad.transport = 'formal-capture-bridge'; rejected(bad);
  bad = cloned(); bad.runId = 'old-run-0'; rejected(bad);
  bad = cloned(); bad.expectedJourneyCount = 3; rejected(bad);
  bad = cloned(); bad.completedJourneys[1].name = bad.completedJourneys[0].name; rejected(bad);
  bad = cloned(); bad.fixtureLimits.productionQualification = true; rejected(bad);

  const releaseRecord = {
    ...cloned(), suite: 'native-release-package', engine: 'powershell', transport: 'release-module-smoke', mode: 'release-smoke',
    engineVersion: '5.1.26100.9711', runtime: '5.1.26100.9711', edition: 'Desktop', processArchitecture: 'x64', toolFingerprint: 'a'.repeat(64),
    expectedJourneyCount: 1, completedJourneyCount: 1,
    fixtureLimits: { ...cloned().fixtureLimits, extractedReleaseModule: true, testOnlyWorkspace: true },
    completedJourneys: [{ name: 'release-extract-import-save', toolFingerprint: 'a'.repeat(64) }]
  };
  check(validateRecord(releaseRecord, { ...expected, suite: 'native-release-package', engine: 'powershell', transport: 'release-module-smoke', mode: 'release-smoke', journeyCount: 1 }).length === 0,
    'release evidence must accept exact Windows PowerShell 5.1 Desktop x64 and extracted tool fingerprint');
  bad = { ...releaseRecord, runtime: '7.6.5' }; rejected(bad, { ...expected, suite: 'native-release-package', engine: 'powershell', transport: 'release-module-smoke', mode: 'release-smoke' });
  bad = { ...releaseRecord, engineVersion: '7.6.5' }; rejected(bad, { ...expected, suite: 'native-release-package', engine: 'powershell', transport: 'release-module-smoke', mode: 'release-smoke' });
  bad = { ...releaseRecord, toolFingerprint: undefined, completedJourneys: [{ name: 'release-extract-import-save' }] };
  rejected(bad, { ...expected, suite: 'native-release-package', engine: 'powershell', transport: 'release-module-smoke', mode: 'release-smoke' });
  bad = { ...releaseRecord, fixtureLimits: { ...releaseRecord.fixtureLimits, liveWorkloads: true } };
  rejected(bad, { ...expected, suite: 'native-release-package', engine: 'powershell', transport: 'release-module-smoke', mode: 'release-smoke' });

  const failedPath = path.join(temp, 'failed.json');
  process.env.WSM_NATIVE_EVIDENCE_PATH = failedPath;
  const failedTracker = startEvidence({ suite: expected.suite, transport: expected.transport, mode: expected.mode,
    expectedJourneyCount: 2, fixtureLimits: { productionQualification: false, liveWorkloads: false, externalSmbQualification: false, actualServices: false, controlledWorkloadFixtures: true } });
  failedTracker.completeJourney('Source-cancel-probe');
  failedTracker.fail(new Error('controlled failure'));
  check(JSON.parse(fs.readFileSync(failedPath, 'utf8')).status === 'Failed', 'failure must preserve evidence with Failed status');
  let failedRejected = false;
  try { validateFile(failedPath, expected); } catch { failedRejected = true; }
  check(failedRejected, 'failed evidence cannot satisfy an acceptance gate');

  let duplicateRejected = false;
  try { tracker.completeJourney('after-finish'); } catch { duplicateRejected = true; }
  check(duplicateRejected, 'completed evidence cannot be reused for another journey');
} finally {
  for (const key of Object.keys(process.env)) if (!(key in previousEnvironment)) delete process.env[key];
  for (const [key, value] of Object.entries(previousEnvironment)) process.env[key] = value;
  fs.rmSync(temp, { recursive: true, force: true });
}

process.stdout.write(`PASS Test-NativeEvidence: ${checks} positive, negative, provisional, count, scope and reuse checks.\n`);
runLauncherCleanupTests().then(runNativeDiagnosticTests).catch(error => { console.error(error); process.exitCode = 1; });
