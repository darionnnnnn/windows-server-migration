'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const PROBE_ROLES = new Set(['Source', 'Target', 'Manager']);
const PROBE_JOB_STATUSES = new Set(['Queued', 'Running', 'CancelRequested', 'Succeeded', 'ReviewRequired', 'Cancelled', 'Failed', 'Interrupted', 'WaitingForInput']);
const PROBE_STAGES = new Set(['Queued', 'Running', 'Collecting', 'Packaging', 'Completed', 'ReviewRequired', 'Cancelled', 'Failed']);
const PROBE_ERROR_CODES = new Set(['field_validation', 'workroot_path_too_long', 'stale_context', 'workspace_recovery_required', 'invalid_token', 'rejected_origin', 'rejected_host', 'permission_denied', 'active_operation', 'report_unavailable', 'operation_unavailable', 'invalid_request', 'operation_not_cancellable', 'operation_failed']);
const PROBE_OUTPUT_STATUSES = new Set(['Completed', 'Partial', 'Cancelled', 'Failed']);
const PROBE_COLLECTOR_IDS = new Set(['PlatformIdentity', 'CommandsModules', 'LocalVolumes', 'NativeInventory', 'HttpProbe']);
const PROBE_COLLECTOR_STATUSES = new Set(['Completed', 'Partial', 'Failed', 'PermissionDenied', 'NotApplicable', 'NotScheduled', 'Cancelled']);
const PROBE_REASON_CODES = new Set([
  '64BitPowerShellRequired', 'AdministratorRequired', 'ArchiveOutputLimit', 'CimManifestUnavailableOrTooLarge',
  'CimModuleOutsideInboxRoot', 'CollectorFailed', 'DriveRelativePathBlocked', 'DriveTypeUnavailable',
  'EntryBudgetExceeded', 'FullLanguageRequired', 'InsufficientLocalSpace', 'InvalidLocalPath',
  'InvalidOrUnsupportedPath', 'InventoryIncompleteCount', 'LocalModuleEnumerationFailed', 'ManifestReadFailed',
  'MappedRemoteDriveBlocked', 'ModuleRootExcludedByIsolation', 'NoOriginSupplied', 'PathAttributesDenied',
  'PathDoesNotExist', 'PathInspectionFailed', 'RawEvidenceBudgetExceeded', 'RemoteOrDevicePathBlocked',
  'ReparseAncestorBlocked', 'TrustedCimModuleImportFailed', 'UnsupportedLocalPathNamespace', 'WindowsServerRequired'
]);

function short(value, limit = 512) {
  return typeof value === 'string' ? value.slice(0, limit) : '';
}

function redact(text) {
  return short(text, 8000)
    .replace(/((?:token|password|passwd|secret|credential|authorization|body)\s*[=:]\s*)([^\s,;]+)/ig, '$1[redacted]')
    .replace(/\bBearer\s+[^\s,;]+/ig, 'Bearer [redacted]')
    .replace(/(-----BEGIN [^-]*PRIVATE KEY-----)[\s\S]*?(-----END [^-]*PRIVATE KEY-----)/g, '$1[redacted]$2');
}

function safeRoute(route) {
  if (typeof route !== 'string') return '/<unknown-route>';
  let pathname;
  try { pathname = new URL(route, 'http://127.0.0.1').pathname; }
  catch { return '/<unknown-route>'; }
  if (!pathname.startsWith('/api/')) return '/<non-api-route>';
  if (pathname === '/api/session' || pathname === '/api/operations') return pathname;
  const jobMatch = pathname.match(/^\/api\/jobs\/([a-f0-9]{8}-[a-f0-9-]{27,})(\/cancel)?$/i);
  if (jobMatch) return `/api/jobs/<id>${jobMatch[2] || ''}`;
  return '/api/<redacted>';
}

function safeError(error) {
  const code = typeof error?.code === 'string' && /^[A-Z0-9_]{1,48}$/.test(error.code) ? error.code : '';
  const name = typeof error?.name === 'string' && /^[A-Za-z][A-Za-z0-9_.]{0,63}$/.test(error.name) ? error.name : 'Error';
  return { name, code };
}

function cleanProbeDiagnostic(input) {
  const lifecycle = (Array.isArray(input?.lifecycle) ? input.lifecycle : []).slice(-100).map(row => {
    const event = { atUtc: short(row?.atUtc, 40), type: short(row?.type, 48), role: ['Source', 'Target', 'Manager'].includes(row?.role) ? row.role : 'unknown' };
    if (Number.isSafeInteger(row?.pid) && row.pid > 0) event.pid = row.pid;
    if (Number.isSafeInteger(row?.exitCode)) event.exitCode = row.exitCode;
    if (typeof row?.signal === 'string') event.signal = short(row.signal, 32);
    if (row?.origin) event.origin = safeLoopbackOrigin(row.origin);
    if (row?.error) event.error = safeError(row.error);
    return event;
  });
  const requests = (Array.isArray(input?.requests) ? input.requests : []).slice(-100).map(row => {
    const result = {
      atUtc: short(row?.atUtc, 40), role: ['Source', 'Target', 'Manager'].includes(row?.role) ? row.role : 'unknown',
      method: ['GET', 'POST', 'DELETE', 'PUT'].includes(row?.method) ? row.method : 'OTHER',
      route: safeRoute(row?.route)
    };
    if (Number.isSafeInteger(row?.pid) && row.pid > 0) result.pid = row.pid;
    if (Number.isSafeInteger(row?.status)) result.status = row.status;
    if (row?.origin) result.origin = safeLoopbackOrigin(row.origin);
    if (row?.fetchError || row?.nodeError) result.error = safeError(row.fetchError || row.nodeError);
    const server = row?.server;
    if (server && typeof server === 'object') {
      result.server = {};
      if (Number.isSafeInteger(server.pid) && server.pid > 0) result.server.pid = server.pid;
      if (Number.isSafeInteger(server.exitCode)) result.server.exitCode = server.exitCode;
      if (typeof server.signal === 'string') result.server.signal = short(server.signal, 32);
      if (typeof server.killed === 'boolean') result.server.killed = server.killed;
    }
    return result;
  });
  const servers = (Array.isArray(input?.servers) ? input.servers : []).slice(-12).map(row => {
    const server = { role: ['Source', 'Target', 'Manager'].includes(row?.role) ? row.role : 'unknown' };
    if (Number.isSafeInteger(row?.pid) && row.pid > 0) server.pid = row.pid;
    if (Number.isSafeInteger(row?.exitCode)) server.exitCode = row.exitCode;
    if (typeof row?.signal === 'string') server.signal = short(row.signal, 32);
    if (typeof row?.killed === 'boolean') server.killed = row.killed;
    if (row?.startedUtc) server.startedUtc = short(row.startedUtc, 40);
    if (row?.closedUtc) server.closedUtc = short(row.closedUtc, 40);
    if (row?.origin) server.origin = safeLoopbackOrigin(row.origin);
    if (row?.output && Number.isSafeInteger(row.output.lineCount)) {
      server.output = { lineCount: row.output.lineCount, loopbackAnnouncements: Number.isSafeInteger(row.output.loopbackAnnouncements) ? row.output.loopbackAnnouncements : 0,
        otherLineCount: Number.isSafeInteger(row.output.otherLineCount) ? row.output.otherLineCount : 0 };
    }
    if (row?.spawnError) server.spawnError = safeError(row.spawnError);
    return server;
  });
  const terminalJobs = (Array.isArray(input?.terminalJobs) ? input.terminalJobs : []).slice(-12).map(row => {
    const terminal = {
      role: PROBE_ROLES.has(row?.role) ? row.role : 'unknown',
      status: PROBE_JOB_STATUSES.has(row?.status) ? row.status : 'Unknown'
    };
    if (PROBE_STAGES.has(row?.stage)) terminal.stage = row.stage;
    if (PROBE_ERROR_CODES.has(row?.failureCode)) terminal.failureCode = row.failureCode;
    if (/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(row?.correlationId || '')) terminal.correlationId = row.correlationId.toLowerCase();
    if (Array.isArray(row?.outputs)) terminal.outputs = row.outputs.slice(0, 2).map(output => {
      const safeOutput = {};
      if (PROBE_OUTPUT_STATUSES.has(output?.status)) safeOutput.status = output.status;
      if (Array.isArray(output?.collectors)) safeOutput.collectors = output.collectors.slice(0, 16).flatMap(collector => {
        if (!PROBE_COLLECTOR_IDS.has(collector?.id)) return [];
        const item = { id: collector.id };
        if (PROBE_COLLECTOR_STATUSES.has(collector?.status)) item.status = collector.status;
        if (PROBE_REASON_CODES.has(collector?.reasonCode)) item.reasonCode = collector.reasonCode;
        return [item];
      });
      return safeOutput;
    });
    return terminal;
  });
  return {
    schemaVersion: 1,
    suite: 'native-probe',
    engine: ['pwsh', 'powershell'].includes(input?.engine) ? input.engine : 'unknown',
    sourceCommit: /^[a-f0-9]{40}$/i.test(input?.sourceCommit || '') ? input.sourceCommit : null,
    runId: /^[0-9]+-[0-9]+$/.test(input?.runId || '') ? input.runId : null,
    capturedUtc: short(input?.capturedUtc, 40), lifecycle, requests, servers, terminalJobs
  };
}

function cleanProbeTerminalJob(job, role) {
  const outputs = Array.isArray(job?.outputs) ? job.outputs : Array.isArray(job?.Outputs) ? job.Outputs : [];
  const terminal = {
    role: PROBE_ROLES.has(role) ? role : 'unknown',
    status: PROBE_JOB_STATUSES.has(job?.status || job?.Status) ? (job.status || job.Status) : 'Unknown',
    stage: PROBE_STAGES.has(job?.stage || job?.Stage) ? (job.stage || job.Stage) : undefined,
    outputs: outputs.slice(0, 2).map(output => ({
      status: PROBE_OUTPUT_STATUSES.has(output?.Status || output?.status) ? (output.Status || output.status) : undefined,
      collectors: (Array.isArray(output?.CollectorResults) ? output.CollectorResults : Array.isArray(output?.collectorResults) ? output.collectorResults : []).slice(0, 16).flatMap(collector => {
        const id = collector?.Id || collector?.id;
        if (!PROBE_COLLECTOR_IDS.has(id)) return [];
        const item = { id };
        const status = collector?.Status || collector?.status;
        const reasonCode = collector?.ReasonCode || collector?.reasonCode;
        if (PROBE_COLLECTOR_STATUSES.has(status)) item.status = status;
        if (PROBE_REASON_CODES.has(reasonCode)) item.reasonCode = reasonCode;
        return [item];
      })
    }))
  };
  const error = job?.error || job?.Error;
  if (PROBE_ERROR_CODES.has(error?.code || error?.Code)) terminal.failureCode = error.code || error.Code;
  const correlationId = error?.correlationId || error?.CorrelationId;
  if (/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(correlationId || '')) terminal.correlationId = correlationId.toLowerCase();
  return terminal;
}

function safeLoopbackOrigin(value) {
  try {
    const url = new URL(value);
    if (url.protocol === 'http:' && (url.hostname === '127.0.0.1' || url.hostname === 'localhost') && !url.username && !url.password) {
      return `${url.origin}`;
    }
  } catch {}
  return null;
}

function cleanRuntimeDiagnostic(row) {
  if (!row || row.SchemaVersion !== 1 || row.Role !== 'Target' || row.FixtureScope !== 'ControlledWizardRuntime') {
    throw new Error('Refusing to retain an unscoped runtime diagnostic.');
  }
  const inner = Array.isArray(row.InnerExceptions) ? row.InnerExceptions.slice(0, 8).map(item => ({
    Type: short(item?.Type, 256), Message: redact(item?.Message)
  })) : [];
  const result = {
    SchemaVersion: 1,
    DiagnosticId: /^[a-f0-9-]{36}$/i.test(row.DiagnosticId || '') ? row.DiagnosticId : '',
    Role: 'Target', FixtureScope: 'ControlledWizardRuntime',
    EngineVersion: short(row.EngineVersion, 64),
    Transport: ['native-http-edge', 'formal-capture-bridge'].includes(row.Transport) ? row.Transport : 'unknown',
    ObservedUtc: short(row.ObservedUtc, 40),
    ExceptionType: short(row.ExceptionType, 512), Message: redact(row.Message),
    FullyQualifiedErrorId: redact(row.FullyQualifiedErrorId), Category: short(row.Category, 128),
    InnerExceptions: inner,
    ScriptStackTrace: redact(row.ScriptStackTrace), PositionMessage: redact(row.PositionMessage),
    CallStack: (Array.isArray(row.CallStack) ? row.CallStack : []).slice(0, 12).map(name => short(name, 128))
  };
  const mismatch = row.JournalMismatch;
  if (mismatch && typeof mismatch === 'object' &&
      ['Sequence', 'PreviousHash', 'PairId', 'RunId'].includes(mismatch.Predicate) &&
      Number.isSafeInteger(mismatch.ExpectedSequence) && mismatch.ExpectedSequence >= 0 &&
      Number.isSafeInteger(mismatch.ObservedSequence) && mismatch.ObservedSequence >= 0 &&
      typeof mismatch.SamePair === 'boolean' && typeof mismatch.SameRun === 'boolean' &&
      typeof mismatch.PreviousHashMatches === 'boolean') {
    result.JournalMismatch = {
      Predicate: mismatch.Predicate,
      ExpectedSequence: mismatch.ExpectedSequence,
      ObservedSequence: mismatch.ObservedSequence,
      SamePair: mismatch.SamePair,
      SameRun: mismatch.SameRun,
      PreviousHashMatches: mismatch.PreviousHashMatches
    };
  }
  return result;
}

function atomicWrite(file, value) {
  if (!file) return;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', encoding: 'utf8' });
  try { fs.renameSync(tmp, file); }
  catch (error) { try { fs.rmSync(file, { force: true }); } catch {} fs.renameSync(tmp, file); }
}

function writeProbeDiagnostics(file, input) { atomicWrite(file, cleanProbeDiagnostic(input)); }
function writeRuntimeDiagnostics(file, metadata, rows) {
  const records = rows.map(cleanRuntimeDiagnostic);
  atomicWrite(file, {
    schemaVersion: 1, suite: 'native-runtime', mode: short(metadata?.mode, 32),
    engine: ['pwsh', 'powershell'].includes(metadata?.engine) ? metadata.engine : 'unknown',
    transport: ['native-http-edge', 'formal-capture-bridge'].includes(metadata?.transport) ? metadata.transport : 'unknown',
    sourceCommit: /^[a-f0-9]{40}$/i.test(metadata?.sourceCommit || '') ? metadata.sourceCommit : null,
    runId: /^[0-9]+-[0-9]+$/.test(metadata?.runId || '') ? metadata.runId : null,
    fixtureScope: 'ControlledWizardRuntime', records
  });
}

module.exports = { cleanProbeDiagnostic, cleanProbeTerminalJob, cleanRuntimeDiagnostic, safeRoute, writeProbeDiagnostics, writeRuntimeDiagnostics };
