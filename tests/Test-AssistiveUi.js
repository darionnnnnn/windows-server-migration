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

function makeApp(fetchImpl, useDom = false) {
  const elements = new Map();
  function makeElement(tagName = 'div') {
    return {
      tagName: tagName.toUpperCase(), children: [], dataset: {}, attributes: {}, listeners: {}, className: '', classList: { toggle() {}, add() {}, remove() {} }, get lastElementChild() { return this.children[this.children.length - 1] || null; }, get lastChild() { return this.children[this.children.length - 1] || null; },
      appendChild(node) { this.children.push(node); node.parentNode = this; return node; },
      append(...nodes) { nodes.forEach(node => this.appendChild(node)); },
      replaceChildren(...nodes) { this.children.forEach(node => { node.parentNode = null; }); this.children = []; this.append(...nodes); },
      insertBefore(node, before) { const index = before ? this.children.indexOf(before) : -1; if (index < 0) this.appendChild(node); else { this.children.splice(index, 0, node); node.parentNode = this; } return node; },
      remove() { if (this.parentNode) this.parentNode.children = this.parentNode.children.filter(node => node !== this); this.parentNode = null; },
      setAttribute(name, value) { this.attributes[name] = String(value); }, removeAttribute(name) { delete this.attributes[name]; },
      addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); }, dispatch(type) { return (this.listeners[type] || []).map(listener => listener({ target: this, preventDefault() {} })); }, focus() {}, scrollIntoView() {},
      querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
      querySelectorAll(selector) {
        const found = [], matches = node => selector === '[data-type]' ? node.dataset && node.dataset.type : selector === '[data-rows]' ? node.dataset && node.dataset.rows === 'true' : selector === 'input' ? node.tagName === 'INPUT' : selector === '.collection-row' ? /(^|\s)collection-row(\s|$)/.test(node.className || '') : selector === '.collection-row input' ? false : false;
        const visit = node => { for (const child of node.children || []) { if (matches(child)) found.push(child); visit(child); } };
        if (selector === '.collection-row input') { const rows = []; const collectRows = node => { for (const child of node.children || []) { if (/(^|\s)collection-row(\s|$)/.test(child.className || '')) rows.push(child); collectRows(child); } }; collectRows(this); rows.forEach(row => found.push(...row.querySelectorAll('input'))); return found; }
        visit(this); return found;
      }
    };
  }
  const makeNode = useDom ? makeElement : null;
  const document = {
    addEventListener() {},
    getElementById(id) { if (makeNode) { const find = node => { if (node.id === id) return node; for (const child of node.children || []) { const found = find(child); if (found) return found; } return null; }; for (const root of elements.values()) { const found = find(root); if (found) return found; } } if (!elements.has(id)) { const node = makeNode ? makeNode() : { textContent: '', hidden: false, focus() {}, replaceChildren() {}, appendChild() {} }; node.id = id; elements.set(id, node); } return elements.get(id); },
    querySelectorAll() { return []; },
    querySelector() { return null; },
    createElement(tagName) { return makeNode ? makeNode(tagName) : { appendChild() {}, setAttribute() {}, replaceChildren() {}, classList: { toggle() {} } }; }
  };
  const window = { addEventListener() {} };
  const context = { window, document, fetch: fetchImpl, URLSearchParams, encodeURIComponent, crypto: require('node:crypto').webcrypto, Date, Math, Set, Map, Object, Array, String, Number, Promise, history: { replaceState() {} }, location: { hash: '', origin: 'http://localhost' }, setInterval, clearInterval, Option: function Option(text, value) { this.text = text; this.value = value; this.dataset = {}; this.children = []; } };
  vm.runInNewContext(appSource, context, { filename: 'console.js' });
  const app = window.WsmConsole;
  if (useDom) { app.__testElements = elements; app.__getElement = id => document.getElementById(id); }
  return app;
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

test('rendered software save sends a reason for a changed version and blocks a blank reason', async () => {
  const calls = [];
  const ui = makeApp(async (url, options) => { calls.push({ url, options }); return { ok: true, status: 200, json: async () => ({ revision: 18 }) }; }, true);
  ui.state.session = { contextId: 'ctx', revision: 17 };
  ui.renderSoftware({ rows: [{ softwareId: 'runtime', name: 'Runtime', sourceVersion: '1.0', chosenVersion: '1.0', versionChoices: [{ value: '1.0' }, { value: '3.0' }] }] });
  const row = ui.__getElement('software-rows').children[0];
  row.children[2].children[0].value = '3.0';
  const reason = row.children[2].children[2];
  reason.value = 'Required release';
  const save = row.children[5].children[1];
  await save.dispatch('click')[0];
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, '/api/operations');
  const submitted = JSON.parse(calls[0].options.body);
  assert.equal(submitted.action, 'SetSoftwareVersion');
  assert.deepEqual(JSON.parse(JSON.stringify(submitted.args)), { softwareId: 'runtime', chosenVersion: '3.0', Reason: 'Required release' });
  assert.equal(submitted.expectedRevision, 17);

  calls.length = 0;
  const blankReasonUi = makeApp(async (url, options) => { calls.push({ url, options }); return { ok: true, status: 200, json: async () => ({}) }; }, true);
  blankReasonUi.state.session = { contextId: 'ctx', revision: 17 };
  blankReasonUi.renderSoftware({ rows: [{ softwareId: 'runtime', name: 'Runtime', sourceVersion: '1.0', chosenVersion: '1.0', versionChoices: [{ value: '1.0' }, { value: '3.0' }] }] });
  const blankRow = blankReasonUi.__getElement('software-rows').children[0];
  blankRow.children[2].children[0].value = '3.0';
  await blankRow.children[5].children[1].dispatch('click')[0];
  assert.equal(calls.length, 0, 'blank reason must stop before the request');
  assert.match(blankReasonUi.__getElement('error-summary').children[0].textContent, /請填寫選擇原因/);
});

test('software rows keep product readiness, account scope, evidence, and target-only rows distinct', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }), true);
  ui.renderSoftware({ rows: [
    { softwareId: 'runtime-1', name: 'Portal Runtime', sourceVersion: '1.0', chosenVersion: '3.0', observedVersion: '2.0', status: 'DifferentFromChosenVersion', accountScopeStatus: 'SameObservedIdentity', sourceSID: 'S-1-5-21-source', targetSID: 'S-1-5-21-target', sourceVersionEvidenceKind: 'Registry', targetVersionEvidenceKind: 'Registry', sourceCaptureStatus: 'Success', targetCaptureStatus: 'Success', sourceLocation: 'C:\\Runtime', targetLocation: 'D:\\Runtime', manualActions: [{ action: 'Install the chosen version or update the chosen version after evidence review.', owner: '' }] },
    { softwareId: 'runtime-missing', name: 'Missing Runtime', sourceVersion: '1.0', chosenVersion: '1.0', observedVersion: '', status: 'TargetMissing', accountScopeStatus: 'NotCompared' },
    { softwareId: '', name: 'Target-only Runtime', sourceVersion: '', chosenVersion: '', observedVersion: '5.0', status: 'TargetOnly', targetSID: 'S-1-5-21-target-only', targetAccountContext: 'Machine', targetVersionEvidenceKind: 'Registry', targetCaptureStatus: 'Success' }
  ] });
  const rows = ui.__getElement('software-rows').children;
  assert.equal(rows[0].children[5].children[0].textContent, '目標版本與選用版本不同');
  assert.match(rows[0].children[5].children[1].textContent, /帳戶範圍：觀測身分相同/);
  const firstAccountText = rows[0].children[4].children.map(child => child.textContent).join(' ');
  const firstSourceText = rows[0].children[1].children.map(child => child.textContent).join(' ');
  assert.match(firstAccountText, /來源帳戶範圍：未知 · SID S-1-5-21-source/);
  assert.match(firstAccountText, /待處理：Install the chosen version/);
  assert.match(firstSourceText, /來源證據：Registry · Success/);
  assert.match(firstSourceText, /來源位置：C:\\Runtime/);
  assert.equal(rows[1].children[5].children[0].textContent, '目標盤點確認缺少此軟體');
  assert.match(rows[1].children[5].children[1].textContent, /帳戶範圍：未比較/);
  assert.match(rows[2].children[5].children[0].textContent, /僅目標端觀測/);
  assert.equal(rows[2].children[5].children.some(child => child.tagName === 'BUTTON'), false);
  const targetOnlyAccountText = rows[2].children[4].children.map(child => child.textContent).join(' ');
  assert.match(targetOnlyAccountText, /目標帳戶範圍：Machine · SID S-1-5-21-target-only/);
  assert.doesNotMatch(targetOnlyAccountText, /來源帳戶範圍：[^ ]+ · SID S-1-5-21-target-only/);
  assert.match(htmlConsoleSource, /sourceSID=\$\(if\(\$row\.SoftwareId\)\{Get-WsmConfirmationValue \$row 'SID'\}else\{''\}\)/);
  assert.match(htmlConsoleSource, /targetSID=\$\(if\(\$row\.SoftwareId\)\{Get-WsmConfirmationValue \$row 'TargetSID'\}else\{Get-WsmConfirmationValue \$row 'SID'\}\)/);
  for (const field of ['sourceCaptureStatus', 'targetCaptureStatus', 'sourceKind', 'targetSourceKind', 'sourceLocation', 'targetLocation', 'sourceVersionEvidenceKind', 'targetVersionEvidenceKind', 'sourceVersionType', 'targetVersionType']) assert.ok(htmlConsoleSource.includes(`${field}=(Get-WsmConfirmationValue`), `${field} is projected for the HTML consumer`);
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
  for (const htmlAction of ['SetRestoreChoice', 'ReviewIssues', 'SetSoftwareVersion', 'HttpIntegrityProbe', 'MaterialJobStatus']) assert.ok(actions.has(htmlAction), `${htmlAction} is part of the HTML action map`);
  actions.forEach((action, index) => {
    const label = ui.actionLabel(action, index + 1);
    assert.match(label, /[\u3400-\u9fff]/, `${action} should have a Chinese picker label`);
    assert.notEqual(label, action);
    assert.ok(['Source', 'Manager', 'Target'].includes(ui.actionGroup(action)));
  });
  assert.equal(ui.actionGroup('SourceInventory'), 'Source');
  assert.equal(ui.actionGroup('OsProvidedCapture'), 'Source');
  assert.equal(ui.actionGroup('OsProvidedBaseline'), 'Manager');
  assert.equal(ui.actionGroup('OsProvidedReview'), 'Manager');
  assert.equal(ui.actionGroup('OsProvidedSubmit'), 'Manager');
  assert.equal(ui.actionGroup('SpecReview'), 'Manager');
  assert.equal(ui.actionGroup('TargetSnapshot'), 'Target');
  assert.equal(ui.actionGroup('MaterialJobStatus'), 'Target');
  assert.equal(ui.actionLabel('MaterialJobStatus'), '查看中斷作業材料鎖');
  const materialGuidance = ui.actionGuidance('MaterialJobStatus', { readOnly: true });
  assert.match(materialGuidance.precondition, /工作程序已停止/);
  assert.match(materialGuidance.output, /不會自動逾期或解除鎖/);
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
  for (const [action, label] of Object.entries({ OsProvidedCapture: '擷取 OS 提供排程工作證據', OsProvidedBaseline: '建立 OS 提供排程工作可信基準', OsProvidedReview: '比對 OS 提供排程工作證據', OsProvidedSubmit: '提交 OS 提供排程工作審閱' })) {
    assert.equal(ui.actionLabel(action), label);
    const guide = ui.actionGuidance(action, { readOnly: action === 'OsProvidedReview' });
    assert.match(guide.purpose, /目的：/);
    assert.match(guide.precondition, /前提：/);
    assert.match(guide.output, /輸出與下步：/);
  }
  assert.match(ui.actionGuidance('OsProvidedSubmit').output, /不代表 vendor verification/);
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

test('file view accepts producer readback and conflict hash field names', () => {
  assert.match(appSource, /r\.observedHash \?\? r\.ObservedHash \?\? r\.readbackHash \?\? r\.ReadbackHash/);
  assert.match(appSource, /r\.existingTargetHash \?\? r\.ExistingTargetHash \?\? r\.conflictHash \?\? r\.ConflictHash/);
});

test('spec review projection is allowlisted and strips secret and raw workload fields', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const fields = ui.safeTypedFields({ TypedFields: {
    TargetPath: 'E:\\Sites\\Portal', Product: 'Portal', AclControlPolicy: 'AllowAutoInheritedUpgrade', WorkloadFieldReviews: [{ FieldPointer: 'IIS/site/Fixture/application[0]/virtualDirectory[0]/@physicalPath', Value: 'E:\\Sites\\Portal', Command: 'must not appear' }],
    IisBindings: [{ Index: 0, Protocol: 'custom+http', SslFlags: '', SslFlagsPresent: false }],
    Desired: { Enabled: true, Command: 'never show this', Xml: '<task>never show</task>' },
    Password: 'never show this', UnknownField: 'not typed'
  } });
  assert.deepEqual(JSON.parse(JSON.stringify(fields)), { TargetPath: 'E:\\Sites\\Portal', Product: 'Portal', AclControlPolicy: 'AllowAutoInheritedUpgrade', WorkloadFieldReviews: [{ FieldPointer: 'IIS/site/Fixture/application[0]/virtualDirectory[0]/@physicalPath', Value: 'E:\\Sites\\Portal' }], IisBindings: [{ Index: 0, Protocol: 'custom+http', SslFlags: '', SslFlagsPresent: false }] });
  assert.match(appSource, /review\.WorkloadPathReferences/);
  assert.match(appSource, /appendWorkloadPathReview/);
  assert.match(appSource, /safe source path|安全來源路徑/);
  assert.match(appSource, /SslFlagsPresent/);
  assert.match(appSource, /DifferentIdentityRequiresReview/);
  assert.match(htmlSource, /spec-review-pointers/);
  assert.match(appSource, /未包含原始 XML 或 secrets/);
  assert.match(appSource, /ExpectedDecisionRevision/);
  assert.match(appSource, /AclControlPolicy/);
  assert.match(htmlConsoleSource, /AclControlPolicy=@\{type='enum';options=@\('Exact','AllowAutoInheritedUpgrade'\);description=/);
  assert.doesNotMatch(htmlConsoleSource, /AclControlPolicy=@\{type='enum';options=@\([^}]*'AllowAutoInheritedUpgrade'[^}]*'AllowAutoInheritedUpgrade'/);
  assert.doesNotMatch(appSource, /Fields:\s*\{\s*TypedFields/);
});

test('spec review prefill replaces the prior item form while ordinary action switching keeps its draft', () => {
  const fields = { type: 'object', schema: { properties: {
    TargetPath: { type: 'path' }, AclControlPolicy: { type: 'enum', options: ['Exact', 'AllowAutoInheritedUpgrade'] }, Product: { type: 'string' }
  } } };
  const actions = [
    { action: 'SaveSpecReview', parameters: [
      { name: 'ItemId', type: 'string' }, { name: 'ExpectedDecisionRevision', type: 'integer' }, { name: 'ExpectedAssistiveRevision', type: 'integer' },
      { name: 'ExpectedSelectionRevision', type: 'integer' }, { name: 'Owner', type: 'string' }, { name: 'Evidence', type: 'string' },
      { name: 'Fields', ...fields }, { name: 'ReviewedTargetXmlPath', type: 'path' }, { name: 'ReviewedTargetXmlHash', type: 'string' }
    ] },
    { action: 'SpecReview', parameters: [{ name: 'ItemId', type: 'string' }] }
  ];
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({ actions }) }), true);
  ui.state.actions = actions;
  const param = index => ui.__getElement(`param-${index}`), fieldsControl = () => param(6), fieldControl = key => {
    const wrap = fieldsControl().children.find(child => child.dataset.objectKey === key);
    return wrap && wrap.querySelector('[data-type]');
  };
  const fileReview = { ItemId: 'file-item', Adapter: 'FileScope', DecisionRevision: 8, AssistiveRevision: 3, SelectionRevision: 4, Owner: 'file owner', Evidence: 'file ACL review', TypedFields: { TargetPath: 'D:\\file-target', AclControlPolicy: 'AllowAutoInheritedUpgrade' } };
  assert.equal(ui.prefillSpecReview(fileReview), true);
  assert.match(ui.__getElement('notice').textContent, /已以本項審閱取代先前表單草稿及進階 XML 引用/);
  assert.equal(param(0).value, 'file-item');
  assert.equal(fieldControl('TargetPath').value, 'D:\\file-target');
  assert.equal(fieldControl('AclControlPolicy').value, 'AllowAutoInheritedUpgrade');

  param(7).value = 'C:\\private\\reviewed-target.xml';
  param(8).value = 'a'.repeat(64);
  ui.setAction('SpecReview');
  ui.setAction('SaveSpecReview');
  assert.equal(fieldControl('AclControlPolicy').value, 'AllowAutoInheritedUpgrade');
  assert.equal(param(7).value, 'C:\\private\\reviewed-target.xml');

  const taskReview = { ItemId: 'task-item', Adapter: 'ScheduledTask', DecisionRevision: 9, AssistiveRevision: 3, SelectionRevision: 4, Owner: 'task owner', Evidence: 'task review', TypedFields: { Product: 'Fixture task' } };
  assert.equal(ui.prefillSpecReview(taskReview), true);
  const args = JSON.parse(JSON.stringify(ui.collectArgs(false)));
  assert.deepEqual(args.Fields, { Product: 'Fixture task' });
  assert.equal(args.ItemId, 'task-item');
  assert.equal(args.ReviewedTargetXmlPath, undefined);
  assert.equal(args.ReviewedTargetXmlHash, undefined);
  assert.equal(ui.state.drafts.get('SaveSpecReview').Fields.AclControlPolicy, undefined);
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
