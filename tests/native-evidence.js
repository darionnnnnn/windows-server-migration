'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const SCHEMA_VERSION = 1;
const SUITES = new Set([
  'native-html-bridge', 'native-release-launcher', 'native-release-package',
  'native-runtime', 'native-manager', 'native-probe'
]);
const ENGINES = new Set(['powershell', 'pwsh']);

function readEngineVersion(engine) {
  const executable = process.env.WSM_PS_EXE || (engine === 'pwsh' ? 'pwsh.exe' : 'powershell.exe');
  return execFileSync(executable, ['-NoProfile','-NonInteractive','-Command','$PSVersionTable.PSVersion.ToString()'], {
    encoding: 'utf8', windowsHide: true, timeout: 15000
  }).trim();
}

function atomicWrite(file, record) {
  if (!file) return;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  try { fs.renameSync(temporary, file); }
  catch (error) {
    try { fs.rmSync(file, { force: true }); } catch {}
    fs.renameSync(temporary, file);
  }
}

function startEvidence(options) {
  const file = process.env.WSM_NATIVE_EVIDENCE_PATH || null;
  const suite = options.suite;
  const engine = process.env.WSM_NATIVE_EVIDENCE_ENGINE || 'unknown';
  const sourceCommit = process.env.WSM_NATIVE_EVIDENCE_SOURCE_SHA || process.env.GITHUB_SHA || 'local-unpinned';
  const runId = process.env.GITHUB_RUN_ID
    ? `${process.env.GITHUB_RUN_ID}-${process.env.GITHUB_RUN_ATTEMPT || '1'}`
    : `local-${crypto.randomUUID()}`;
  if (!SUITES.has(suite)) throw new Error(`Unknown native evidence suite: ${suite}`);
  if (!Number.isSafeInteger(options.expectedJourneyCount) || options.expectedJourneyCount < 1) {
    throw new Error('Expected native journey count must be a positive integer.');
  }
  if (file && (!ENGINES.has(engine) || !/^[a-f0-9]{40}$/i.test(sourceCommit))) {
    throw new Error('CI evidence requires a selected engine and full source commit SHA.');
  }

  const record = {
    schemaVersion: SCHEMA_VERSION,
    status: 'Running',
    suite,
    engine,
    engineVersion: 'not-observed',
    transport: options.transport,
    mode: options.mode,
    sourceCommit,
    runId,
    measure: 'completed-journeys',
    expectedJourneyCount: options.expectedJourneyCount,
    completedJourneyCount: 0,
    completedJourneys: [],
    fixtureLimits: options.fixtureLimits,
    startedUtc: new Date().toISOString()
  };
  if (process.env.WSM_RELEASE_TOOL_FINGERPRINT) record.toolFingerprint = process.env.WSM_RELEASE_TOOL_FINGERPRINT;
  atomicWrite(file, record);

  if (file) {
    record.engineVersion = readEngineVersion(engine);
    atomicWrite(file, record);
  }

  function persist() { atomicWrite(file, record); }
  return {
    completeJourney(name, details = {}) {
      if (record.status !== 'Running') throw new Error(`Cannot record a journey after evidence is ${record.status}.`);
      if (typeof name !== 'string' || !name.trim()) throw new Error('Completed journey needs a name.');
      if (record.completedJourneys.some(journey => journey.name === name)) throw new Error(`Duplicate completed journey: ${name}`);
      if (record.completedJourneys.length >= record.expectedJourneyCount) throw new Error('Completed journeys exceed the selected mode count.');
      record.completedJourneys.push({ name, ...details });
      record.completedJourneyCount = record.completedJourneys.length;
      persist();
    },
    finish() {
      if (record.completedJourneyCount !== record.expectedJourneyCount) {
        throw new Error(`Journey count mismatch: expected ${record.expectedJourneyCount}, completed ${record.completedJourneyCount}.`);
      }
      record.status = 'Passed';
      record.finishedUtc = new Date().toISOString();
      persist();
    },
    fail(error) {
      record.status = 'Failed';
      record.failure = String(error && (error.stack || error.message) || error).slice(0, 4000);
      record.finishedUtc = new Date().toISOString();
      persist();
    },
    snapshot() { return JSON.parse(JSON.stringify(record)); }
  };
}

function validateRecord(record, expected) {
  const errors = [];
  if (!record || typeof record !== 'object' || Array.isArray(record)) return ['evidence must be a JSON object'];
  if (record.schemaVersion !== SCHEMA_VERSION) errors.push('unsupported schema version');
  if (record.status !== 'Passed') errors.push(`status must be Passed (got ${record.status})`);
  for (const key of ['suite','engine','engineVersion','transport','mode','sourceCommit','runId','measure']) {
    if (typeof record[key] !== 'string' || !record[key]) errors.push(`${key} is required`);
  }
  if (!SUITES.has(record.suite)) errors.push('unknown suite');
  if (!ENGINES.has(record.engine)) errors.push('unknown engine');
  if (record.engine === 'powershell' && !/^5\.1(?:\.|$)/.test(record.engineVersion || '')) errors.push('powershell must identify Windows PowerShell 5.1');
  if (record.engine === 'pwsh' && !/^7\./.test(record.engineVersion || '')) errors.push('pwsh must identify PowerShell 7');
  if (!/^[a-f0-9]{40}$/i.test(record.sourceCommit || '')) errors.push('sourceCommit must be a full SHA');
  if (record.measure !== 'completed-journeys') errors.push('measure must be completed-journeys');
  if (['native-release-package','native-release-launcher'].includes(record.suite)) {
    const fingerprint = record.toolFingerprint || (Array.isArray(record.completedJourneys) && record.completedJourneys[0]?.toolFingerprint);
    if (!/^[a-f0-9]{64}$/i.test(fingerprint || '')) errors.push('release journey must record its extracted tool fingerprint');
  }
  if (record.suite === 'native-release-package') {
    if (record.engine !== 'powershell' || !/^5\.1(?:\.|$)/.test(record.runtime || '') || record.edition !== 'Desktop' || record.processArchitecture !== 'x64') {
      errors.push('release package must prove Windows PowerShell 5.1 Desktop x64 execution');
    }
    if (!record.fixtureLimits?.extractedReleaseModule || !record.fixtureLimits?.testOnlyWorkspace) errors.push('release package must identify extracted module and test-only workspace boundaries');
  }
  if (!Number.isSafeInteger(record.expectedJourneyCount) || record.expectedJourneyCount < 1) errors.push('expectedJourneyCount must be positive');
  if (!Number.isSafeInteger(record.completedJourneyCount) || record.completedJourneyCount < 1) errors.push('completedJourneyCount must be positive');
  if (record.expectedJourneyCount !== record.completedJourneyCount) errors.push('completed journey count must equal expected count');
  if (!Array.isArray(record.completedJourneys) || record.completedJourneys.length !== record.completedJourneyCount) errors.push('completedJourneys must match the measured count');
  else {
    const names = record.completedJourneys.map(row => row && row.name);
    if (names.some(name => typeof name !== 'string' || !name.trim())) errors.push('every completed journey needs a name');
    if (new Set(names).size !== names.length) errors.push('completed journey names must be unique');
  }
  if (!record.fixtureLimits || typeof record.fixtureLimits !== 'object' || record.fixtureLimits.productionQualification !== false) {
    errors.push('fixtureLimits must explicitly state productionQualification=false');
  }
  if (record.fixtureLimits && record.fixtureLimits.liveWorkloads !== false) errors.push('fixtureLimits must explicitly state liveWorkloads=false');
  if (record.suite === 'native-html-bridge' && (!record.fixtureLimits?.realEdge || !record.fixtureLimits?.loopbackHandler || !record.fixtureLimits?.injectedFaultResponses)) {
    errors.push('HTML bridge evidence must identify real Edge, loopback handler and injected fault responses');
  }
  if (record.suite === 'native-release-launcher' && (!record.fixtureLimits?.realCmd || !record.fixtureLimits?.realEdge)) {
    errors.push('released launcher evidence must identify actual CMD and Edge');
  }
  if (record.suite === 'native-runtime' && (record.fixtureLimits?.externalSmbQualification !== false || record.fixtureLimits?.actualServices !== false)) {
    errors.push('runtime evidence must explicitly limit claims about SMB qualification and actual services');
  }
  if (['native-manager','native-probe'].includes(record.suite) && record.mode === 'full' && (!record.fixtureLimits?.realEdge || !record.fixtureLimits?.loopbackHandler)) {
    errors.push('Manager/Probe full journey must identify real Edge and loopback handler');
  }
  for (const key of ['suite','engine','transport','mode','sourceCommit','runId']) {
    if (expected[key] !== undefined && record[key] !== expected[key]) errors.push(`${key} does not match selected workflow scope`);
  }
  if (expected.journeyCount !== undefined && record.expectedJourneyCount !== Number(expected.journeyCount)) errors.push('expected journey count does not match selected workflow scope');
  return errors;
}

function validateFile(file, expected) {
  if (!fs.existsSync(file)) throw new Error(`Native acceptance evidence is missing: ${file}`);
  let record;
  try { record = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) { throw new Error(`Native acceptance evidence is not valid JSON: ${error.message}`); }
  const errors = validateRecord(record, expected);
  if (errors.length) throw new Error(`Native acceptance evidence rejected: ${errors.join('; ')}`);
  return record;
}

function parseCli(argv) {
  const [command, ...args] = argv;
  if (command !== 'validate') throw new Error('Usage: node native-evidence.js validate --path FILE --suite NAME --engine ENGINE --transport NAME --mode MODE --count N --commit SHA --run-id ID');
  const values = {};
  for (let index = 0; index < args.length; index += 2) {
    if (!args[index] || !args[index].startsWith('--') || args[index + 1] === undefined) throw new Error('Invalid validation arguments.');
    values[args[index].slice(2)] = args[index + 1];
  }
  const required = ['path','suite','engine','transport','mode','count','commit','run-id'];
  for (const key of required) if (!values[key]) throw new Error(`Missing --${key}.`);
  const count = Number(values.count);
  if (!Number.isSafeInteger(count) || count < 1) throw new Error('--count must be a positive integer.');
  return { file: values.path, expected: {
    suite: values.suite, engine: values.engine, transport: values.transport,
    mode: values.mode, journeyCount: count, sourceCommit: values.commit, runId: values['run-id']
  } };
}

if (require.main === module) {
  try {
    const { file, expected } = parseCli(process.argv.slice(2));
    const record = validateFile(file, expected);
    process.stdout.write(`PASS native evidence ${record.suite}/${record.engine} ${record.engineVersion}: ${record.completedJourneyCount} completed journeys, ${record.transport}, source ${record.sourceCommit}, run ${record.runId}.\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = { startEvidence, validateRecord, validateFile, SCHEMA_VERSION };
