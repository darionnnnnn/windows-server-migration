'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const appSource = fs.readFileSync(path.join(root, 'src/ui/console.js'), 'utf8');
const htmlSource = fs.readFileSync(path.join(root, 'src/ui/index.html'), 'utf8');
const operationsSource = fs.readFileSync(path.join(root, 'src/OperationRequests.ps1'), 'utf8');
const htmlConsoleSource = fs.readFileSync(path.join(root, 'src/HtmlConsole.ps1'), 'utf8');

function makeApp(fetchImpl) {
  const elements = new Map();
  const document = {
    addEventListener() {},
    getElementById(id) { if (!elements.has(id)) elements.set(id, { textContent: '', hidden: false, focus() {}, replaceChildren() {}, appendChild() {} }); return elements.get(id); },
    querySelectorAll() { return []; },
    querySelector() { return null; },
    createElement() { return { appendChild() {}, setAttribute() {}, replaceChildren() {}, classList: { toggle() {} } }; }
  };
  const window = { addEventListener() {} };
  const context = { window, document, fetch: fetchImpl, URLSearchParams, encodeURIComponent, crypto: require('node:crypto').webcrypto, Date, Math, Set, Map, Object, Array, String, Number, Promise, history: { replaceState() {} }, location: { hash: '' }, Option: function Option(text, value) { this.text = text; this.value = value; } };
  vm.runInNewContext(appSource, context, { filename: 'console.js' });
  return window.WsmConsole;
}

test('typed metadata covers arrays, maps, objects and object arrays without raw JSON fields', () => {
  for (const type of ['stringArray', 'map', 'object', 'objectArray']) assert.match(appSource, new RegExp(`type === '${type}'`));
  assert.match(appSource, /function buildObjectEditor/);
  assert.match(appSource, /function buildObjectArrayEditor/);
  assert.match(appSource, /新增鍵值/);
  assert.doesNotMatch(htmlSource, /<textarea[^>]+json/i);
  assert.match(appSource, /此操作的型別化欄位尚未定義/);
});

test('typed form values serialize to arrays, maps and schema-shaped objects', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const primitive = (type, value) => ({ dataset: { type }, value });
  const nested = primitive('string', 'E:\\Sites\\Portal');
  const mapping = { dataset: { type: 'map' }, querySelectorAll: selector => selector === '.collection-row' ? [{ querySelectorAll: () => [{ value: 'D:\\Old' }, { value: 'E:\\New' }] }] : [] };
  const properties = [
    { dataset: { objectKey: 'name' }, children: [], querySelector: () => primitive('string', 'Portal') },
    { dataset: { objectKey: 'path' }, children: [], querySelector: () => nested }
  ];
  const row = { children: properties };
  const arrayOfObjects = { dataset: { type: 'objectArray', complexType: 'objectArray' }, querySelector: () => ({ children: [row] }) };
  assert.equal(ui.collectControl(primitive('boolean', 'false')), false);
  assert.deepEqual(JSON.parse(JSON.stringify(ui.collectControl(mapping))), { 'D:\\Old': 'E:\\New' });
  assert.deepEqual(JSON.parse(JSON.stringify(ui.collectControl(arrayOfObjects))), [{ name: 'Portal', path: 'E:\\Sites\\Portal' }]);
});

test('selection payload keeps selected state separate and includes deselection reasons', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const inventory = [{ itemId: 'site-1' }, { itemId: 'task-very-long-name-已排程' }];
  const selected = new Set(['site-1']);
  const reasons = new Map([['task-very-long-name-已排程', '新版 Windows 內建項目，待平台確認']]);
  const args = ui.buildSelectionArgs(inventory, selected, reasons);
  assert.deepEqual(JSON.parse(JSON.stringify(args)), { selectedItemIds: ['site-1'], unselectedItems: [{ itemId: 'task-very-long-name-已排程', reason: '新版 Windows 內建項目，待平台確認' }] });
});

test('non-selectable rows stay out of selected payloads and keep the backend reason', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const inventory = [{ itemId: 'included', selectable: true }, { itemId: 'locked', selectable: false, reason: '核准前不得選取' }];
  const args = ui.buildSelectionArgs(inventory, new Set(['included', 'locked']), new Map());
  assert.deepEqual(JSON.parse(JSON.stringify(args)), { selectedItemIds: ['included'], unselectedItems: [{ itemId: 'locked', reason: '核准前不得選取' }] });
  assert.match(appSource, /check\.disabled = !selectable/);
  assert.match(appSource, /r\.selectable !== false && \(!category/);
});

test('software version choice accepts a user-entered newer version through a typed operation', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const request = ui.buildOperationRequest('SetSoftwareVersion', { softwareId: 'web-runtime', chosenVersion: '9.4.2' }, 17);
  assert.deepEqual(JSON.parse(JSON.stringify(request.args)), { softwareId: 'web-runtime', chosenVersion: '9.4.2' });
  assert.match(appSource, /versionChoices/);
  assert.match(appSource, /選擇或輸入明確的軟體版本/);
});

test('operation request carries a revision and unique idempotency identifiers', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  ui.state.session = { contextId: 'context-17' };
  const request = ui.buildOperationRequest('SetMigrationSpec', { MigrationSpec: { Sites: [{ Name: 'Intranet' }] } }, 12);
  assert.equal(request.action, 'SetMigrationSpec');
  assert.equal(request.expectedRevision, 12);
  assert.equal(request.contextId, 'context-17');
  assert.ok(request.operationId);
  assert.ok(request.idempotencyKey);
  assert.notEqual(request.operationId, request.idempotencyKey);
});

test('every backend operation has a Chinese label and a source, manager or target group', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const actions = new Set([
    ...[...operationsSource.matchAll(/(?:\{|;)([A-Za-z][A-Za-z0-9]+)='[^']+'/g)].map(match => match[1]),
    ...[...htmlConsoleSource.matchAll(/@\('([A-Za-z][A-Za-z0-9]+)','[^']+'\)/g)].map(match => match[1])
  ]);
  assert.ok(actions.size > 90);
  for (const htmlAction of ['SetRestoreChoice', 'ReviewIssues', 'SetSoftwareVersion', 'HttpIntegrityProbe']) assert.ok(actions.has(htmlAction), `${htmlAction} is part of the HTML action map`);
  actions.forEach((action, index) => {
    const label = ui.actionLabel(action, index + 1);
    assert.match(label, /[\u3400-\u9fff]/, `${action} should have a Chinese picker label`);
    assert.notEqual(label, action);
    assert.ok(['Source', 'Manager', 'Target'].includes(ui.actionGroup(action)));
  });
  assert.equal(ui.actionGroup('SourceInventory'), 'Source');
  assert.equal(ui.actionGroup('SpecReview'), 'Manager');
  assert.equal(ui.actionGroup('TargetSnapshot'), 'Target');
  assert.equal(ui.actionGroup('PreparationPreview'), 'Target');
  assert.equal(ui.actionGroup('PreparationEvidence'), 'Target');
  assert.equal(ui.actionLabel('HttpIntegrityProbe'), '檢查本機頁面傳輸完整性');
  assert.equal(ui.actionLabel('WindowsSettingsPreviewExport'), '匯出 Windows 設定審閱預覽');
  assert.equal(ui.actionLabel('WindowsSettingsSubmit'), '提交 Windows 設定審閱');
  assert.equal(ui.actionLabel('DispositionSubmit'), '提交一般主機處置審閱');
  assert.equal(ui.actionLabel('RequirementReview'), '預覽一般主機需求審閱');
  assert.equal(ui.actionLabel('RequirementDecisionSubmit'), '提交一般主機需求決策');
  assert.equal(ui.actionLabel('RequirementSubmit'), '提交一般主機需求審閱（進階）');
  assert.equal(ui.actionLabel('PreparationPreview'), '預覽目標準備需求');
  assert.equal(ui.actionLabel('PreparationEvidence'), '匯出準備佐證');
  assert.equal(ui.parameterLabel('CommandManifestPath'), '命令清單路徑');
  assert.equal(ui.parameterLabel('ManifestPath'), '文件清單路徑');
  assert.match(ui.parameterLabel('UnknownFutureHash'), /進階欄位/);
});

test('Windows settings preview produces a safe all-row draft bound to the physical preview file hash', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  ui.state.session = { workspace: 'C:\\WSM\\workspace', pairId: 'fixture-pair' };
  const physicalHash = 'a'.repeat(64), semanticHash = 'b'.repeat(64);
  const output = {
    Kind: 'AssistiveWindowsSettingsPreviewOutput', PairId: 'fixture-pair',
    SourceInventoryPath: 'C:\\WSM\\source.json', SourceInventoryHash: 'c'.repeat(64),
    TargetInventoryPath: 'C:\\WSM\\target.json', TargetInventoryHash: 'd'.repeat(64),
    PreviewPath: 'C:\\WSM\\protected-preview.json', PreviewFileHash: physicalHash, PreviewHash: semanticHash, ExpectedRevision: 19,
    ReviewWindowsSettings: true,
    Rows: [
      { SettingId: 'setting-1', DefaultAction: 'External', SupportedActions: ['KeepTarget', 'External'], SourceValue: 'must not enter draft', Xml: '<secret/>' },
      { SettingId: 'setting-2', DefaultAction: 'InvalidChoice', SupportedActions: ['KeepTarget'], RawCommand: 'must not enter draft' }
    ]
  };
  const draft = ui.createWindowsSettingsReviewDraft(output);
  assert.equal(draft.PreviewHash, physicalHash);
  assert.notEqual(draft.PreviewHash, semanticHash);
  assert.equal(draft.ExpectedRevision, 19);
  assert.equal(draft.ReviewWindowsSettings, true);
  assert.deepEqual(JSON.parse(JSON.stringify(draft.Decisions)), [
    { SettingId: 'setting-1', Action: 'External', Owner: '', Reason: '', Evidence: '' },
    { SettingId: 'setting-2', Action: '', Owner: '', Reason: '', Evidence: '' }
  ]);
  assert.doesNotMatch(JSON.stringify(draft), /must not enter draft|secret|RawCommand|SourceValue/);
  assert.equal(ui.createWindowsSettingsReviewDraft({ ...output, Rows: [{ SettingId: 'duplicate' }, { SettingId: 'duplicate' }] }), null);
  assert.equal(ui.createWindowsSettingsReviewDraft({ ...output, PreviewFileHash: semanticHash.slice(0, 20) }), null);
  assert.equal(ui.createWindowsSettingsReviewDraft({ ...output, PairId: 'different-current-pair' }), null);
  assert.equal(ui.createWindowsSettingsReviewDraft({ ...output, ExpectedRevision: '' }), null);
  assert.deepEqual(JSON.parse(JSON.stringify(ui.createWindowsSettingsReviewDraft({ ...output, ReviewWindowsSettings: false, Rows: [] }).Decisions)), []);
  assert.match(appSource, /Array\.isArray\(value\) && !value\.length && !p\.allowEmpty/);
  assert.match(appSource, /使用此預覽準備設定審閱/);
  assert.match(appSource, /AssistivePreparationPreview/);
});

test('draft projection recursively excludes sensitive fields while retaining typed values', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const parameters = [{ name: 'Spec', type: 'object', schema: { properties: {
    Name: { type: 'string' }, Password: { type: 'string', sensitive: true },
    Rules: { type: 'objectArray', schema: { properties: { User: { type: 'string' }, SecretToken: { type: 'string' } } } }
  } } }];
  const safe = ui.stripSensitiveArguments(parameters, { Spec: { Name: 'Portal', Password: 'do-not-send', Rules: [{ User: 'svc', SecretToken: 'never-preview' }] } });
  assert.deepEqual(JSON.parse(JSON.stringify(safe)), { Spec: { Name: 'Portal', Rules: [{ User: 'svc' }] } });
});

test('CAS conflict invalidates preview while preserving draft state', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  ui.state.preview = { revision: 8 };
  ui.state.operationArgs = { Mapping: { Old: 'D:\\Old', New: 'E:\\New' } };
  const result = ui.invalidateForConflict();
  assert.equal(ui.state.preview, null);
  assert.deepEqual(JSON.parse(JSON.stringify(ui.state.operationArgs)), { Mapping: { Old: 'D:\\Old', New: 'E:\\New' } });
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { preserveDraft: true, requireFreshPreview: true });
});

test('session token is memory-only, sent on API calls, and a 401 invalidates it', async () => {
  const calls = [];
  const ui = makeApp(async (url, options) => { calls.push({ url, options }); return { ok: false, status: 401, json: async () => ({}) }; });
  ui.state.token = 'ephemeral-token';
  await assert.rejects(ui.endpoint('/api/jobs'), /session expired/);
  assert.equal(calls[0].options.headers['X-Wsm-Token'], 'ephemeral-token');
  assert.equal(ui.state.token, null);
  assert.doesNotMatch(appSource, /localStorage|sessionStorage|indexedDB/);
  assert.doesNotMatch(appSource, /job\.args|job\.arguments/i);
  const remounted = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  assert.equal(remounted.state.token, null);
});

test('server values are rendered via textContent and long jobs reconnect/cancel by id', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  assert.equal(ui.statusName('DeferredSoftware'), '等待軟體');
  assert.equal(ui.statusName('BlockedConflict'), '目的衝突');
  assert.equal(ui.parseResponse({ preview: { revision: 5 } }).revision, 5);
  assert.match(appSource, /n\.textContent = String\(text\)/);
  assert.match(appSource, /\/api\/jobs\/\$\{encodeURIComponent\(id\)\}\/cancel/);
  assert.match(appSource, /\/api\/jobs\/\$\{encodeURIComponent\(id\)\}/);
  assert.doesNotMatch(appSource, /innerHTML|insertAdjacentHTML/);
  assert.match(appSource, /job\.canCancel === true/);
  assert.match(appSource, /document\.hidden && location\.hash === '#jobs'/);
  assert.match(appSource, /filtered\.slice\(start/);
  assert.match(appSource, /RestoreNow/);
  assert.match(appSource, /contextId: state\.session\.contextId/);
});

test('spec review projection is allowlisted and strips secret and raw workload fields', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const fields = ui.safeTypedFields({ TypedFields: {
    TargetPath: 'E:\\Sites\\Portal', Product: 'Portal',
    Desired: { Enabled: true, Command: 'never show this', Xml: '<task>never show</task>' },
    Password: 'never show this', UnknownField: 'not typed'
  } });
  assert.deepEqual(JSON.parse(JSON.stringify(fields)), { TargetPath: 'E:\\Sites\\Portal', Product: 'Portal' });
  assert.match(appSource, /review\.WorkloadPathReferences/);
  assert.match(htmlSource, /spec-review-pointers/);
  assert.match(appSource, /未包含原始 XML 或 secrets/);
  assert.match(appSource, /ExpectedDecisionRevision/);
  assert.doesNotMatch(appSource, /Fields:\s*\{\s*TypedFields/);
});

test('requirement review draft binds the exact safe rows and keeps confirmation fields blank', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  ui.state.session = { pairId: 'pair-a', workspace: 'C:\\WSM' };
  const review = { Kind: 'AssistiveRequirementReview', PairId: 'pair-a', ExpectedRevision: 4, ReviewHash: 'a'.repeat(64), Rows: [
    { RequirementId: 'r1', Decision: 'Required', Context: { secret: 'never-copy' }, SourceProof: { Evidence: 'never-copy' } },
    { RequirementId: 'r2', Decision: 'Pending' }
  ] };
  assert.deepEqual(JSON.parse(JSON.stringify(ui.createRequirementDecisionDraft(review))), {
    Workspace: 'C:\\WSM', PairId: 'pair-a', ExpectedRevision: 4, ReviewHash: 'a'.repeat(64),
    Decisions: [
      { RequirementId: 'r1', Decision: 'Required', Owner: '', DecisionReason: '', DecisionEvidence: '' },
      { RequirementId: 'r2', Decision: 'Pending', Owner: '', DecisionReason: '', DecisionEvidence: '' }
    ]
  });
  assert.equal(ui.createRequirementDecisionDraft({ ...review, PairId: 'another-pair' }), null);
  assert.equal(ui.createRequirementDecisionDraft({ ...review, ReviewHash: 'bad' }), null);
  assert.equal(ui.createRequirementDecisionDraft({ ...review, Rows: [{ RequirementId: 'r1' }, { RequirementId: 'r1' }] }), null);
  assert.equal(ui.actionLabel('RequirementReview'), '預覽一般主機需求審閱');
  assert.equal(ui.actionLabel('RequirementDecisionSubmit'), '提交一般主機需求決策');
});

test('report button uses authenticated same-origin open endpoint without exposing launch details', async () => {
  const calls = [];
  const ui = makeApp(async (url, options) => { calls.push({ url, options }); return { ok: true, status: 200, json: async () => ({ opened: true }) }; });
  ui.state.token = 'ephemeral';
  await ui.openJobReport('job / one', 2, 'abc123');
  assert.equal(calls[0].url, '/api/jobs/job%20%2F%20one/reports/2/open');
  assert.equal(calls[0].options.method, 'POST');
  assert.equal(calls[0].options.headers['X-Wsm-Token'], 'ephemeral');
  assert.equal(calls[0].options.credentials, 'same-origin');
  assert.deepEqual(JSON.parse(calls[0].options.body), { SHA256: 'abc123' });
});
