'use strict';

const test = require('node:test');
const afterEach = require('node:test').afterEach;
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const appSource = fs.readFileSync(path.join(root, 'src/ui/console.js'), 'utf8');
const htmlSource = fs.readFileSync(path.join(root, 'src/ui/index.html'), 'utf8');
const operationsSource = fs.readFileSync(path.join(root, 'src/OperationRequests.ps1'), 'utf8');
const htmlConsoleSource = fs.readFileSync(path.join(root, 'src/HtmlConsole.ps1'), 'utf8');
const activeHarnesses = new Set();

afterEach(() => {
  for (const dispose of activeHarnesses) dispose();
  activeHarnesses.clear();
});

function makeApp(fetchImpl, useDom = false) {
  const intervals = new Set(), timeouts = new Set();
  const harnessSetInterval = (callback, delay, ...args) => {
    const handle = setInterval(callback, delay, ...args);
    intervals.add(handle);
    return handle;
  };
  const harnessClearInterval = handle => { clearInterval(handle); intervals.delete(handle); };
  const harnessSetTimeout = (callback, delay, ...args) => {
    let handle;
    handle = setTimeout((...callbackArgs) => { timeouts.delete(handle); callback(...callbackArgs); }, delay, ...args);
    timeouts.add(handle);
    return handle;
  };
  const harnessClearTimeout = handle => { clearTimeout(handle); timeouts.delete(handle); };
  const dispose = () => {
    for (const handle of intervals) clearInterval(handle);
    for (const handle of timeouts) clearTimeout(handle);
    intervals.clear();
    timeouts.clear();
    activeHarnesses.delete(dispose);
  };
  activeHarnesses.add(dispose);
  const elements = new Map();
  function makeElement(tagName = 'div') {
    return {
      tagName: tagName.toUpperCase(), children: [], dataset: {}, attributes: {}, listeners: {}, className: '', value:'', checked:false, disabled:false, readOnly:false, classList: { toggle() {}, add() {}, remove() {} }, get options() { return this.children; }, get lastElementChild() { return this.children[this.children.length - 1] || null; }, get lastChild() { return this.children[this.children.length - 1] || null; },
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
    querySelector(selector) { return selector === '#view-operations .operation-layout' ? { scrollIntoView() {} } : null; },
    createElement(tagName) { return makeNode ? makeNode(tagName) : { appendChild() {}, setAttribute() {}, replaceChildren() {}, classList: { toggle() {} } }; }
  };
  const window = { addEventListener() {} };
  window.__confirmResult = true; window.__confirmMessage = ''; window.confirm = message => { window.__confirmMessage = String(message || ''); return window.__confirmResult; };
  const browserFetch = async (input, init) => {
    const mocked = await fetchImpl(input, init);
    if (mocked instanceof Response) return mocked;
    if (mocked && typeof mocked.text === 'function' && mocked.headers && typeof mocked.headers.get === 'function') return mocked;
    const status = Number(mocked && mocked.status || 200);
    const body = mocked && typeof mocked.json === 'function' ? await mocked.json() : mocked && mocked.body;
    const headers = new Headers(mocked && mocked.headers || { 'Content-Type': 'application/json' });
    const text = body == null ? '' : typeof body === 'string' ? body : JSON.stringify(body);
    const responseBody = [204, 205, 304].includes(status) ? null : text;
    return new Response(responseBody, { status, headers });
  };
  const context = { window, document, fetch: browserFetch, AbortController, Headers, Response, URLSearchParams, encodeURIComponent, crypto: require('node:crypto').webcrypto, Date, Math, Set, Map, Object, Array, String, Number, Promise, history: { replaceState() {}, pushState() {} }, location: { hash: '', origin: 'http://localhost' }, setInterval: harnessSetInterval, clearInterval: harnessClearInterval, setTimeout: harnessSetTimeout, clearTimeout: harnessClearTimeout, Option: function Option(text, value) { this.text = text; this.value = value; this.dataset = {}; this.children = []; } };
  vm.runInNewContext(appSource, context, { filename: 'console.js' });
  const app = window.WsmConsole;
  if (useDom) { app.__testElements = elements; app.__getElement = id => document.getElementById(id); }
  app.__location = context.location;
  app.__window = window;
  app.__dispose = dispose;
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

test('fetch fixture supplies browser AbortSignal and a consumable JSON Response', async () => {
  let signal;
  const ui = makeApp(async (url, options) => { signal = options.signal; return { ok: true, status: 200, json: async () => ({ fixture: 'response-body' }) }; });
  const result = await ui.endpoint('/api/jobs');
  assert.equal(signal instanceof AbortSignal, true);
  assert.equal(signal.aborted, false);
  assert.deepEqual(JSON.parse(JSON.stringify(result)), { fixture: 'response-body' });
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
  const ui = makeApp(async (url, options) => { calls.push({ url, options }); return { ok: true, status: 200, json: async () => url === '/api/session' ? ({ contextId: 'ctx', revision: 17 }) : ({ revision: 18 }) }; }, true);
  ui.state.session = { contextId: 'ctx', revision: 17 };
  ui.renderSoftware({ rows: [{ softwareId: 'runtime', name: 'Runtime', sourceVersion: '1.0', chosenVersion: '1.0', versionChoices: [{ value: '1.0' }, { value: '3.0' }] }] });
  const row = ui.__getElement('software-rows').children[0];
  row.children[2].children[0].value = '3.0';
  const reason = row.children[2].children[2];
  reason.value = 'Required release';
  const save = row.children[5].children[1];
  await save.dispatch('click')[0];
  assert.equal(calls.length, 2);
  assert.equal(calls[1].url, '/api/operations');
  const submitted = JSON.parse(calls[1].options.body);
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

test('software drafts trigger pair-change confirmation and survive a cancelled switch', async () => {
  const calls=[]; const ui=makeApp(async(url,options)=>{calls.push({url,options});return {ok:true,status:200,json:async()=>({})};},true);
  ui.state.session={sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:1,decisionRevision:4,selectionRevision:2,dataVersion:'d1'};
  ui.state.context={roles:['Manager'],pairs:[{pairId:'p1'},{pairId:'p2'}],role:'Manager',pairId:'p1'};
  ui.renderSoftware({rows:[{softwareId:'runtime',name:'Runtime',sourceVersion:'1.0',chosenVersion:'1.0',versionChoices:[{value:'1.0'},{value:'2.0'}]}]});
  const row=ui.__getElement('software-rows').children[0]; row.children[2].children[0].value='2.0'; row.children[2].children[0].dispatch('change');
  assert.ok(ui.state.softwareDirty.has('runtime'));
  assert.match(ui.__getElement('software-draft-summary').textContent,/1 筆未保存/);
  ui.__window.__confirmResult=false;
  ui.__getElement('context-pair').value='p2'; ui.__getElement('context-role').value='Manager';
  await ui.applyContext();
  assert.match(ui.__window.__confirmMessage,/變更角色或配對都會使舊預覽失效/);
  assert.match(ui.__window.__confirmMessage,/變更配對另會清除未保存的項目選取／原因與軟體版本／原因/);
  assert.equal(ui.state.session.pairId,'p1');
  assert.ok(ui.state.softwareDirty.has('runtime'));
  assert.equal(calls.some(call=>call.url==='/api/context'&&call.options.method==='POST'),false);
});

test('external pair switch clears the old dirty software draft with an explicit notice', async () => {
  const ui=makeApp(async url=>({ok:true,status:200,json:async()=>url==='/api/session'?({sessionId:'s1',contextId:'c2',pairId:'p2',role:'Manager',revision:2,decisionRevision:5,selectionRevision:3,dataVersion:'d2',token:'t'}):({roles:['Manager'],pairs:[{pairId:'p2'}],role:'Manager',pairId:'p2'})}),true);
  ui.state.session={sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:1,decisionRevision:4,selectionRevision:2,dataVersion:'d1',token:'t'};
  ui.state.softwareDirty.add('runtime'); ui.state.softwareChoices.set('runtime','3.0'); ui.state.softwareChoiceReasons.set('runtime','reviewed');
  ui.state.drafts.set('TargetSnapshot',{TargetPath:'D:\\target'}); ui.state.preview={revision:1};
  await ui.refreshSession(false);
  assert.equal(ui.state.session.pairId,'p2');
  assert.equal(ui.state.softwareDirty.size,0);
  assert.equal(ui.state.drafts.size,0);
  assert.equal(ui.state.preview,null);
  assert.match(ui.__getElement('notice').textContent,/另一個視窗已切換配對/);
  assert.match(ui.__getElement('notice').textContent,/舊配對的未保存草稿與選取已清除/);
});

test('pre-write external pair switch clears software generations, explains the discard, and blocks the write', async () => {
  const calls=[]; const ui=makeApp(async(url,options)=>{ calls.push({url,options}); if(url==='/api/session') return {ok:true,status:200,json:async()=>({sessionId:'s1',contextId:'c2',pairId:'p2',role:'Manager',revision:2,decisionRevision:5,selectionRevision:3,dataVersion:'d2',token:'t'})}; if(url==='/api/context') return {ok:true,status:200,json:async()=>({roles:['Manager'],pairs:[{pairId:'p2'}],role:'Manager',pairId:'p2'})}; return {ok:true,status:200,json:async()=>({})}; },true);
  ui.state.session={sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:1,decisionRevision:4,selectionRevision:2,dataVersion:'d1',token:'t'};
  ui.state.softwareDirty.add('runtime'); ui.state.softwareGeneration.set('runtime',8); ui.state.softwareChoices.set('runtime','3.0'); ui.state.softwareChoiceReasons.set('runtime','reviewed');
  ui.state.drafts.set('TargetSnapshot',{TargetPath:'D:\\target'});
  await assert.rejects(ui.ensureFreshContext(),error=>error.code==='context-changed');
  assert.equal(ui.state.session.pairId,'p2'); assert.equal(ui.state.softwareDirty.size,0); assert.equal(ui.state.softwareGeneration.size,0); assert.equal(ui.state.softwareChoices.size,0); assert.equal(ui.state.drafts.size,0);
  assert.equal(calls.some(call=>call.url==='/api/operations'),false);
  assert.match(ui.__getElement('notice').textContent,/原配對未保存輸入已清除/);
});

test('safe state reason and next action prevent an empty no-pair inventory from looking complete', () => {
  const ui=makeApp(async()=>({ok:true,status:200,json:async()=>({})}),true);
  ui.renderInventory({items:[],canSaveSelection:false,assistiveEnabled:false,stateReason:'尚未選擇有效配對；目前沒有可供核對的盤點清單。',stateNextAction:{action:'Initialize',label:'初始化受控工作區',description:'先檢查工作區與材料路徑。',requiredRole:'Manager',roleAvailable:true}});
  const message=ui.__getElement('state-message'), text=message.children.map(node=>node.textContent).join(' ');
  assert.match(text,/尚未選擇有效配對/);
  assert.match(text,/先檢查工作區與材料路徑/);
  assert.equal(ui.__getElement('save-selection').disabled,true);
  assert.equal(ui.__getElement('state-message').children.some(node=>node.tagName==='BUTTON'&&node.textContent==='初始化受控工作區'),true);
});

test('a delayed software save does not clear a newer edit', async () => {
  let release, operationBody; const gate=new Promise(resolve=>{release=resolve;});
  const ui=makeApp(async(url,options)=>{
    if(url==='/api/session') return {ok:true,status:200,json:async()=>({sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:1,decisionRevision:4,selectionRevision:2,dataVersion:'d1',token:'t'})};
    if(url==='/api/operations'){operationBody=JSON.parse(options.body);return gate;}
    return {ok:true,status:200,json:async()=>({})};
  });
  ui.state.session={sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:1,decisionRevision:4,selectionRevision:2,dataVersion:'d1',token:'t'};
  ui.state.softwareDirty.add('runtime'); const saving=ui.saveSoftwareChoice('runtime','2.0','approved release','1.0');
  for(let i=0;i<20&&!operationBody;i++) await new Promise(resolve=>setTimeout(resolve,1));
  assert.ok(operationBody);
  ui.state.softwareGeneration.set('runtime',1); ui.state.softwareDirty.add('runtime'); ui.state.softwareChoices.set('runtime','3.0');
  release({ok:true,status:200,json:async()=>({jobId:operationBody.operationId,status:'Saved',revision:2})});
  await saving;
  assert.ok(ui.state.softwareDirty.has('runtime'));
  assert.equal(ui.state.softwareChoices.get('runtime'),'3.0');
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
  ui.state.session = { contextId: 'context-17', decisionRevision:12, selectionRevision:6, dataVersion:'catalog-hash' };
  const request = ui.buildOperationRequest('SetMigrationSpec', { MigrationSpec: { Sites: [{ Name: 'Intranet' }] } }, 12);
  assert.equal(request.action, 'SetMigrationSpec');
  assert.equal(request.expectedRevision, 12);
  assert.equal(request.expectedDecisionRevision, 12);
  assert.equal(request.expectedSelectionRevision, 6);
  assert.equal(request.expectedDataVersion, 'catalog-hash');
  assert.equal(request.contextId, 'context-17');
  assert.ok(request.operationId);
  assert.ok(request.idempotencyKey);
  assert.notEqual(request.operationId, request.idempotencyKey);
});

test('every backend operation has a Chinese label and a source, manager or target group', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  const coreMap = operationsSource.match(/\[ordered\]@\{([^}]+)\}/), htmlMapStart = htmlConsoleSource.indexOf('function Get-WsmHtmlActionMap'), htmlMapEnd = htmlConsoleSource.indexOf('function Set-WsmHtmlSelection', htmlMapStart), htmlMap = htmlConsoleSource.slice(htmlMapStart, htmlMapEnd);
  const actions = new Set([
    ...[...(coreMap && coreMap[1] || '').matchAll(/(?:\{|;)([A-Za-z][A-Za-z0-9]+)='[^']+'/g)].map(match => match[1]),
    ...[...htmlMap.matchAll(/@\('([A-Za-z][A-Za-z0-9]+)','[^']+'\)/g)].map(match => match[1])
  ]);
  assert.ok(actions.size > 90);
  for (const htmlAction of ['SetRestoreChoice', 'ReviewIssues', 'SetSoftwareVersion', 'HttpIntegrityProbe', 'MaterialJobStatus']) assert.ok(actions.has(htmlAction), `${htmlAction} is part of the HTML action map`);
  actions.forEach((action, index) => {
    const label = ui.actionLabel(action, index + 1);
    assert.match(label, /[\u3400-\u9fff]/, `${action} should have a Chinese picker label`);
    assert.doesNotMatch(label, /^其他進階操作/, `${action} should explain its purpose, not use an ordinal placeholder`);
    assert.notEqual(label, action);
    assert.ok(['Source', 'Manager', 'Target'].includes(ui.actionGroup(action)));
  });
  assert.equal(ui.actionGroup('SourceInventory'), 'Source');
  assert.equal(ui.actionGroup('OsProvidedCapture'), 'Source');
  assert.equal(ui.actionGroup('OsProvidedBaseline'), 'Manager');
  assert.equal(ui.actionGroup('OsProvidedReview'), 'Manager');
  assert.equal(ui.actionGroup('OsProvidedSubmit'), 'Manager');
  assert.equal(ui.actionGroup('SpecReview'), 'Manager');
  assert.equal(ui.actionGroup('TargetSnapshot'), 'Manager');
  assert.equal(ui.actionGroup('TargetSnapshot', { requiredRole:'Manager' }), 'Manager');
  assert.equal(ui.actionGroup('MaterialJobStatus'), 'Target');
  assert.equal(ui.actionGroup('MaterialJobStatus', { requiredRole:'Manager' }), 'Manager', 'server requiredRole takes precedence over fallback classification');
  assert.equal(ui.actionGroup('ImportInventory'), 'Manager');
  assert.equal(ui.actionGroup('EnrolledInventory'), 'Source');
  assert.equal(ui.actionGroup('NonCPeerProof'), 'Source');
  assert.equal(ui.actionGroup('NonCPlan'), 'Manager');
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

test('Source and Target can open local Inventory forms while Manager owns target snapshot import and comparison', () => {
  const ui=makeApp(async()=>({ok:true,status:200,json:async()=>({})}),true), catalog=[
    ['Inventory','Source'],['ImportInventory','Manager'],['AssistiveEnable','Manager'],['SaveSelection','Manager'],['SetSoftwareVersion','Manager'],['TargetSnapshot','Manager'],['PublishComparison','Manager'],['RestorePreview','Manager'],['Restore','Target'],['ApproveMigration','Manager'],['ExportPackage','Source'],['PackageZip','Source'],['ImportPackageZip','Target'],['Repair','Manager'],['SourceResume','Source'],['RepairWorkspace','Manager'],['Validate','Target'],['Acceptance','Manager'],['Cutover','Target'],['ExportResult','Target'],['DeliveryDocument','Manager'],['RequestCancellation','Manager'],['CheckJournal','Manager'],['MaterialJobStatus','Target']
  ];
  const cards=()=>ui.__getElement('guided-tasks').children, titles=()=>cards().map(card=>card.children.find(node=>node.tagName==='H3').textContent), card=title=>cards().find(item=>item.children.some(node=>node.tagName==='H3'&&node.textContent===title)), textOf=node=>[node.textContent||'',...(node.children||[]).map(textOf)].join(' ');
  const fill=role=>{ui.state.session={role};const available={Source:new Set(['Inventory']),Manager:new Set(['ImportInventory','AssistiveEnable','TargetSnapshot','PublishComparison']),Target:new Set(['Inventory','ImportPackageZip','Restore','Validate','Cutover','MaterialJobStatus'])}[role];ui.state.actions=catalog.map(([action,requiredRole])=>({action,requiredRole,supportedRoles:action==='Inventory'?['Source','Target']:[requiredRole],roleAvailable:available.has(action),parameters:action==='Inventory'?[{name:'OutputDirectory',label:'輸出目錄',type:'path',required:true}]:action==='TargetSnapshot'?[{name:'Path',label:'目標材料路徑',type:'path',required:true},{name:'ExpectedHash',label:'目標材料 SHA-256',type:'string',required:true}]:action==='PublishComparison'?[{name:'ExpectedRevision',label:'預期 revision',type:'integer',required:true}]:[]}));ui.renderTaskGuide();};
  fill('Source'); assert.equal(titles()[0],'建立來源盤點'); assert.equal(titles().length,10);
  const sourceInventory=card('建立來源盤點'), sourceInventoryButton=sourceInventory.children.find(node=>node.className==='task-actions').children[0]; sourceInventoryButton.dispatch('click');
  assert.equal(ui.state.activeAction,'Inventory'); assert.ok(ui.__getElement('param-0')); assert.match(textOf(ui.__getElement('action-metadata')),/目前執行本操作的 Windows Server/); assert.match(textOf(ui.__getElement('action-metadata')),/FullLanguage/); assert.match(textOf(ui.__getElement('action-metadata')),/ImportInventory/);
  const sourceText=ui.__getElement('guided-tasks').children.map(card=>card.children.flatMap(node=>[node.textContent||'',...(node.children||[]).map(child=>child.textContent||'')]).join(' ')).join(' ');
  assert.match(sourceText,/其他角色操作/); assert.match(sourceText,/Manager/); assert.equal(titles().length,10);
  fill('Manager'); assert.ok(['啟用輔助流程','選取項目與軟體版本','更新目標觀測'].includes(titles()[0]));
  const managerTargetInventory=card('建立目標本機盤點材料'); assert.equal(managerTargetInventory.children.find(node=>node.className==='task-actions').children.length,0); assert.match(textOf(managerTargetInventory),/Source／Target/);
  const targetCheck=card('更新目標觀測'), managerButtons=targetCheck.children.find(node=>node.className==='task-actions').children;
  assert.deepEqual(managerButtons.map(button=>button.textContent.slice(button.textContent.lastIndexOf('（')+1,-1)),['TargetSnapshot','PublishComparison']);
  for(const action of ['TargetSnapshot','PublishComparison']) { ui.state.actions.find(item=>item.action===action).roleAvailable=true; ui.setAction(action); assert.equal(ui.state.activeAction,action); assert.ok(ui.__getElement('parameter-fields').children.length>0,`${action} opens its typed form`); }
  fill('Target');
  const targetInventory=card('建立目標本機盤點材料'), targetInventoryActions=()=>card('建立目標本機盤點材料').children.find(node=>node.className==='task-actions').children; assert.equal(card('建立來源盤點').children.find(node=>node.className==='task-actions').children.length,0,'Target cannot receive the Source common-task shortcut');
  const inventoryMetadata=ui.state.actions.find(item=>item.action==='Inventory'); inventoryMetadata.roleAvailable=undefined; inventoryMetadata.supportedRoles=['Source']; ui.renderTaskGuide(); assert.equal(targetInventoryActions().length,0,'an explicit supportedRoles list excludes Target when roleAvailable is absent');
  inventoryMetadata.supportedRoles=['Source','Target']; inventoryMetadata.roleAvailable=false; ui.renderTaskGuide(); assert.equal(targetInventoryActions().length,0,'explicit roleAvailable false overrides the broader supportedRoles list');
  inventoryMetadata.roleAvailable=true; ui.renderTaskGuide(); const targetInventoryButton=targetInventoryActions()[0]; assert.ok(targetInventoryButton); targetInventoryButton.dispatch('click');
  assert.equal(ui.state.activeAction,'Inventory'); assert.ok(ui.__getElement('param-0')); assert.match(textOf(ui.__getElement('action-metadata')),/目前執行本操作的 Windows Server/); assert.match(textOf(ui.__getElement('action-metadata')),/FullLanguage/); assert.match(textOf(ui.__getElement('action-metadata')),/目標專屬目錄/); assert.match(textOf(ui.__getElement('action-metadata')),/TargetSnapshot/); assert.match(textOf(ui.__getElement('action-metadata')),/受控離線交接/); assert.doesNotMatch(textOf(ui.__getElement('action-metadata')),/來源主機執行/);
  const targetText=textOf(card('更新目標觀測')), targetButtons=card('更新目標觀測').children.find(node=>node.className==='task-actions').children;
  assert.equal(targetButtons.length,0); assert.match(targetText,/Manager/);
  const exchange=card('可信材料離線交接'); assert.match(textOf(exchange),/匯入盤點（Manager）/); assert.equal(exchange.children.find(node=>node.className==='task-actions').children.some(button=>button.textContent.includes('ImportInventory')),false);
  ui.state.actions.find(item=>item.action==='Inventory').roleAvailable=undefined; ui.renderTaskGuide(); assert.equal(card('建立目標本機盤點材料').children.find(node=>node.className==='task-actions').children.length,1,'supportedRoles remains the target fallback when roleAvailable is absent');
});

test('Windows settings preview produces a safe all-row draft bound to the physical preview file hash', () => {
  const ui = makeApp(async () => ({ ok: true, status: 200, json: async () => ({}) }));
  ui.state.session = { workspace: 'C:\\WSM\\workspace', pairId: 'fixture-pair', role:'Target', decisionRevision: 19 };
  const parentJob = { workspace:'C:\\WSM\\workspace', pairId:'fixture-pair', role:'Target', startedRevision:18 };
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
  const draft = ui.createWindowsSettingsReviewDraft(output, parentJob);
  assert.equal(draft.PreviewHash, physicalHash);
  assert.notEqual(draft.PreviewHash, semanticHash);
  assert.equal(draft.ExpectedRevision, 19);
  assert.equal(draft.ReviewWindowsSettings, true);
  assert.deepEqual(JSON.parse(JSON.stringify(draft.Decisions)), [
    { SettingId: 'setting-1', Action: 'External', Owner: '', Reason: '', Evidence: '' },
    { SettingId: 'setting-2', Action: '', Owner: '', Reason: '', Evidence: '' }
  ]);
  assert.doesNotMatch(JSON.stringify(draft), /must not enter draft|secret|RawCommand|SourceValue/);
  assert.equal(ui.createWindowsSettingsReviewDraft({ ...output, Rows: [{ SettingId: 'duplicate' }, { SettingId: 'duplicate' }] }, parentJob), null);
  assert.equal(ui.createWindowsSettingsReviewDraft({ ...output, PreviewFileHash: semanticHash.slice(0, 20) }, parentJob), null);
  assert.equal(ui.createWindowsSettingsReviewDraft({ ...output, PairId: 'different-current-pair' }, parentJob), null);
  assert.equal(ui.createWindowsSettingsReviewDraft({ ...output, ExpectedRevision: '' }, parentJob), null);
  assert.deepEqual(JSON.parse(JSON.stringify(ui.createWindowsSettingsReviewDraft({ ...output, ReviewWindowsSettings: false, Rows: [] }, parentJob).Decisions)), []);
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
  await assert.rejects(ui.endpoint('/api/jobs'), error => error.status === 401 && error.code === 'invalid_token');
  assert.equal(calls[0].options.headers['X-Wsm-Token'], 'ephemeral-token');
  assert.equal(ui.state.token, null);
  assert.doesNotMatch(appSource, /localStorage|indexedDB/);
  assert.match(appSource, /wsm\.pending\.v1/);
  assert.match(appSource, /expectedDecisionRevision:request\.expectedDecisionRevision/);
  assert.doesNotMatch(appSource, /sessionStorage\.setItem\([^,]+,\s*JSON\.stringify\([^)]*(?:token|args|idempotencyKey)/i);
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
  assert.match(appSource, /!document\.hidden&&state\.session/);
  assert.match(appSource, /filtered\.slice\(start/);
  assert.match(appSource, /RestoreNow/);
  assert.match(appSource, /contextId: state\.session\.contextId/);
});

test('job cards show only recorded Windows process actor provenance and explicit unknown for legacy records', () => {
  const ui=makeApp(async()=>({ok:true,status:200,json:async()=>({})}),true); ui.state.session={pairId:'p1',role:'Manager'};
  ui.state.jobs.set('actor-job',{jobId:'actor-job',pairId:'p1',role:'Manager',status:'Succeeded',action:'AssistiveReport',actor:{WindowsPrincipal:'NT AUTHORITY\\SYSTEM',WindowsSID:'S-1-5-18',ExecutionHost:'HOST-A',ObservedUtc:'2026-10-11T01:02:03Z',IdentitySource:'WindowsProcess',BrowserHumanAuthenticated:false,ExtraSecret:'DO-NOT-RENDER'}});
  ui.state.jobs.set('legacy-job',{jobId:'legacy-job',pairId:'p1',role:'Manager',status:'Interrupted',action:'AssistiveReport'}); ui.renderJobs();
  const flatten=node=>[node.textContent||'',...(node.children||[]).flatMap(flatten)].join(' '), text=flatten(ui.__getElement('job-list'));
  assert.match(text,/NT AUTHORITY\\SYSTEM/); assert.match(text,/HOST-A/); assert.match(text,/2026-10-11T01:02:03Z/); assert.match(text,/Windows SID：S-1-5-18/);
  assert.match(text,/未驗證瀏覽器操作者；不代表負責人簽核/); assert.match(text,/本機程序執行身分：未知/); assert.doesNotMatch(text,/DO-NOT-RENDER/);
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
  ui.state.session = { sessionId: 's1', contextId: 'c1', pairId: 'pair-a', role: 'Manager', revision: 3, decisionRevision: 8, selectionRevision: 4, sourceSelectionRevision: 4, dataVersion: 'dv-a' };
  const param = index => ui.__getElement(`param-${index}`), fieldsControl = () => param(6), fieldControl = key => {
    const wrap = fieldsControl().children.find(child => child.dataset.objectKey === key);
    return wrap && wrap.querySelector('[data-type]');
  };
  const fileReview = { ItemId: 'file-item', Adapter: 'FileScope', DecisionRevision: 8, AssistiveRevision: 3, SelectionRevision: 4, Owner: 'file owner', Evidence: 'file ACL review', TypedFields: { TargetPath: 'D:\\file-target', AclControlPolicy: 'AllowAutoInheritedUpgrade' } };
  fileReview.__wsmIdentity = ui.viewIdentity();
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
  taskReview.__wsmIdentity = ui.viewIdentity();
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
  ui.state.session = { pairId: 'pair-a', workspace: 'C:\\WSM', role: 'Target', decisionRevision: 4 };
  const review = { Kind: 'AssistiveRequirementReview', PairId: 'pair-a', ExpectedRevision: 4, ReviewHash: 'a'.repeat(64), Rows: [
    { RequirementId: 'r1', Decision: 'Required', Context: { secret: 'never-copy' }, SourceProof: { Evidence: 'never-copy' } },
    { RequirementId: 'r2', Decision: 'Pending' }
  ] };
  const job = { workspace:'C:\\WSM', pairId:'pair-a', role:'Target', startedRevision:3 };
  assert.deepEqual(JSON.parse(JSON.stringify(ui.createRequirementDecisionDraft(review, job))), {
    Workspace: 'C:\\WSM', PairId: 'pair-a', ExpectedRevision: 4, ReviewHash: 'a'.repeat(64),
    Decisions: [
      { RequirementId: 'r1', Decision: 'Required', Owner: '', DecisionReason: '', DecisionEvidence: '' },
      { RequirementId: 'r2', Decision: 'Pending', Owner: '', DecisionReason: '', DecisionEvidence: '' }
    ]
  });
  assert.equal(ui.createRequirementDecisionDraft({ ...review, PairId: 'another-pair' }, job), null);
  assert.equal(ui.createRequirementDecisionDraft({ ...review, ReviewHash: 'bad' }, job), null);
  assert.equal(ui.createRequirementDecisionDraft({ ...review, Rows: [{ RequirementId: 'r1' }, { RequirementId: 'r1' }] }, job), null);
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

test('view cache is bound to complete viewContext and the response revision', async () => {
  let count = 0; const urls = [];
  const ui = makeApp(async url => { urls.push(url); count++; return { ok: true, status: 200, json: async () => ({ value: count, viewContext: { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: ui.state.session.revision, readUtc: '2026-10-11T00:00:00Z' } }) }; });
  ui.state.session = { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 7 };
  const first = await ui.getView('overview');
  assert.equal(first.value, 1);
  assert.equal((await ui.getView('overview')).value, 1, 'same identity uses the in-memory cache');
  ui.state.session.revision = 8;
  const next = await ui.getView('overview');
  assert.equal(next.value, 2, 'a different revision cannot reuse the prior cache entry');
  assert.equal(count, 2);
  assert.match(urls[0], /contextId=c1/);
});

test('decision-only and catalog-only changes invalidate cache even when Assistive revision stays fixed', async () => {
  let count = 0;
  const ui = makeApp(async () => { count++; const s = ui.state.session; return { ok:true, status:200, json:async () => ({ count, viewContext:{ sessionId:s.sessionId, contextId:s.contextId, pairId:s.pairId, role:s.role, revision:s.revision, decisionRevision:s.decisionRevision, selectionRevision:s.selectionRevision, sourceSelectionRevision:s.sourceSelectionRevision, dataVersion:s.dataVersion, readUtc:'now' } }) }; });
  ui.state.session = { sessionId:'s1', contextId:'c1', pairId:'p1', role:'Manager', revision:7, decisionRevision:12, selectionRevision:4, sourceSelectionRevision:3, dataVersion:'catalog-a' };
  assert.equal((await ui.getView('overview')).count, 1);
  ui.state.session.decisionRevision = 13;
  assert.equal((await ui.getView('overview')).count, 2, 'native decision changes do not reuse the old cache');
  ui.state.session.dataVersion = 'catalog-b';
  assert.equal((await ui.getView('overview')).count, 3, 'catalog byte changes do not reuse the old cache');
  assert.equal(ui.state.session.revision, 7);
});

test('late native-vector response is discarded after a decision-only change', async () => {
  let release, calls=0;
  const delayed = new Promise(resolve => { release = resolve; });
  const ui = makeApp(async () => { calls++; if(calls===1) return delayed; return { ok:true, status:200, json:async () => { const s=ui.state.session; return { safe:true, viewContext:{ sessionId:s.sessionId, contextId:s.contextId, pairId:s.pairId, role:s.role, revision:s.revision, decisionRevision:s.decisionRevision, selectionRevision:s.selectionRevision, sourceSelectionRevision:s.sourceSelectionRevision, dataVersion:s.dataVersion, readUtc:'new' } }; } }; });
  ui.state.session = { sessionId:'s1', contextId:'c1', pairId:'p1', role:'Manager', revision:7, decisionRevision:12, selectionRevision:4, sourceSelectionRevision:3, dataVersion:'catalog-a' };
  const old = ui.getView('overview');
  ui.state.session.decisionRevision = 13;
  ui.state.session.dataVersion = 'catalog-b';
  const fresh = await ui.getView('overview');
  assert.equal(fresh.safe, true);
  release({ ok:true, status:200, json:async () => ({ leaked:true, viewContext:{ sessionId:'s1', contextId:'c1', pairId:'p1', role:'Manager', revision:7, decisionRevision:12, selectionRevision:4, sourceSelectionRevision:3, dataVersion:'catalog-a', readUtc:'old' } }) });
  await assert.rejects(old, /過期/);
  assert.equal(Object.values(ui.state.views).some(view => view.leaked), false);
});

test('a delayed view response from an old context is rejected and never cached', async () => {
  let release;
  const firstResponse = new Promise(resolve => { release = resolve; });
  const ui = makeApp(async url => url.includes('contextId=c1') ? await firstResponse : ({ ok: true, status: 200, json: async () => ({ viewContext: { sessionId: 's1', contextId: 'c2', pairId: 'p2', role: 'Target', revision: 3, readUtc: 'now' } }) }));
  ui.state.session = { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 2 };
  const slow = ui.getView('overview');
  ui.state.session = { sessionId: 's1', contextId: 'c2', pairId: 'p2', role: 'Target', revision: 3 };
  const fresh = await ui.getView('overview');
  assert.equal(fresh.viewContext.pairId, 'p2');
  release({ ok: true, status: 200, json: async () => ({ leakedOldView: true, viewContext: { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 2, readUtc: 'old' } }) });
  await assert.rejects(slow, /過期/);
  assert.equal(ui.state.views[`${ui.viewIdentity(ui.state.session)}\u001eoverview`].leakedOldView, undefined);
});

test('write preflight stops after an external revision change and preserves the in-memory draft', async () => {
  const calls = [];
  const ui = makeApp(async (url, options) => { calls.push(url); return { ok: true, status: 200, json: async () => ({ sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 9, token: 'new-token' }) }; }, true);
  ui.state.session = { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 8, token: 'old-token' };
  ui.state.drafts.set('SetMigrationSpec', { Name: 'safe draft' });
  ui.state.preview = { revision: 8 };
  await assert.rejects(ui.endpoint('/api/operations', { method: 'POST', body: JSON.stringify({ action: 'SetMigrationSpec', args: { Name: 'safe draft' }, operationId: 'op-1', idempotencyKey: 'key-1' }) }), /已停止這次寫入/);
  assert.ok(calls.includes('/api/session'));
  assert.ok(calls.includes('/api/context'));
  assert.equal(calls.includes('/api/operations'), false);
  assert.equal(ui.state.session.revision, 9);
  assert.equal(ui.state.preview, null);
  assert.deepEqual(JSON.parse(JSON.stringify(ui.state.drafts.get('SetMigrationSpec'))), { Name: 'safe draft' });
});

test('write preflight rejects decision-only and dataVersion changes with unchanged Assistive revision', async () => {
  const calls=[]; const latest={ sessionId:'s1', contextId:'c1', pairId:'p1', role:'Manager', revision:7, decisionRevision:13, selectionRevision:4, sourceSelectionRevision:3, dataVersion:'catalog-b', token:'new-token' };
  const ui=makeApp(async (url, options) => { calls.push(url); if(url==='/api/session') return {ok:true,status:200,json:async()=>latest}; if(url==='/api/context') return {ok:true,status:200,json:async()=>({ ...latest, roles:['Manager'], pairs:[{pairId:'p1'}] })}; return {ok:true,status:200,json:async()=>({})}; },true);
  ui.state.session={ sessionId:'s1', contextId:'c1', pairId:'p1', role:'Manager', revision:7, decisionRevision:12, selectionRevision:4, sourceSelectionRevision:3, dataVersion:'catalog-a', token:'old-token' };
  ui.state.drafts.set('WindowsSettingsSubmit',{Owner:'keep this nonsecret draft'}); ui.state.preview={revision:7};
  await assert.rejects(ui.endpoint('/api/operations',{method:'POST',body:JSON.stringify({action:'WindowsSettingsSubmit',args:{},operationId:'native-op',idempotencyKey:'secret-key'})}),/已停止這次寫入/);
  assert.equal(calls.includes('/api/operations'),false);
  assert.equal(ui.state.session.revision,7);
  assert.equal(ui.state.session.decisionRevision,13);
  assert.equal(ui.state.session.dataVersion,'catalog-b');
  assert.equal(ui.state.preview,null);
  assert.deepEqual(JSON.parse(JSON.stringify(ui.state.drafts.get('WindowsSettingsSubmit'))),{Owner:'keep this nonsecret draft'});
});

test('future structured safe error keeps code, correlation, and localized action without clearing a valid token', async () => {
  const ui=makeApp(async()=>({ok:false,status:403,json:async()=>({code:'worker_limit',message:'Worker quota reached.',correlationId:'corr-42',nextStep:'Wait for a worker.'})}));
  ui.state.token='valid-token';
  await assert.rejects(ui.endpoint('/api/jobs'),error=>{assert.equal(error.code,'worker_limit');assert.equal(error.body.correlationId,'corr-42');assert.match(error.message,/目前工作程序已達服務上限/);assert.match(error.message,/corr-42/);return true;});
  assert.equal(ui.state.token,'valid-token');
});

test('workspace recovery and unavailable job codes retain safe next steps and correlation', async () => {
  let current={code:'workspace_recovery_required',message:'Workspace repair is required.',correlationId:'corr-repair',nextStep:'Inspect the journal and use RepairWorkspace.'};
  const ui=makeApp(async()=>({ok:false,status:503,json:async()=>current})); ui.state.token='valid-token';
  await assert.rejects(ui.endpoint('/api/jobs/one'),error=>{assert.equal(error.code,'workspace_recovery_required');assert.match(error.message,/工作區需要修復或材料恢復/);assert.match(error.message,/RepairWorkspace/);assert.match(error.message,/corr-repair/);return true;});
  current={code:'operation_unavailable',message:'The requested job report could not be found.',correlationId:'corr-job',nextStep:'Refresh the existing job record.'};
  await assert.rejects(ui.endpoint('/api/jobs/one/reports/0/open'),error=>{assert.match(error.message,/作業或報告目前無法取得/);assert.match(error.message,/Refresh the existing job record/);assert.match(error.message,/corr-job/);return true;});
  assert.equal(ui.state.token,'valid-token');
});

test('uncertain write keeps its operation identity and never resends automatically', async () => {
  const calls = [];
  const ui = makeApp(async (url, options) => {
    calls.push({ url, options });
    if (url === '/api/session') return { ok: true, status: 200, json: async () => ({ sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 8 }) };
    if (url === '/api/operations') throw new Error('connection reset after acceptance');
    return { ok: false, status: 404, json: async () => ({ message: 'not available yet' }) };
  }, true);
  ui.state.session = { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 8 };
  ui.__location.hash = '#jobs';
  await assert.rejects(ui.endpoint('/api/operations', { method: 'POST', body: JSON.stringify({ action: 'SetMigrationSpec', operationId: 'op-uncertain', idempotencyKey: 'key-uncertain', args: { Password: 'memory-only' } }) }), error => error.code === 'connection_error');
  assert.equal(ui.state.pendingOperation.operationId, 'op-uncertain');
  assert.equal(await ui.recoverPendingOperation(), null);
  assert.equal(ui.state.pendingOperation.operationId, 'op-uncertain');
  await assert.rejects(ui.endpoint('/api/operations', { method: 'POST', body: JSON.stringify({ action: 'SetMigrationSpec', operationId: 'op-new', idempotencyKey: 'key-new', args: {} }) }), /提交結果尚未確認/);
  assert.equal(calls.filter(call => call.url === '/api/operations').length, 1);
  assert.ok(calls.some(call => call.url === '/api/jobs/op-uncertain'));
  ui.state.jobs.set('old-job', { jobId: 'old-job', pairId: null, status: 'Interrupted' });
  ui.renderJobs();
  const pendingCard = ui.__getElement('job-list').children.find(node => node.tagName === 'ARTICLE');
  assert.ok(pendingCard, 'the pending operation is rendered as its own job card');
  assert.equal(pendingCard.children.find(node => node.tagName === 'H2').textContent, '這次操作的結果待確認');
  assert.equal(pendingCard.children.find(node => node.tagName === 'BUTTON').textContent, '查詢這次操作');
  const technicalDetails = pendingCard.children.find(node => node.tagName === 'DETAILS');
  assert.ok(technicalDetails, 'the operation identifier remains in collapsed advanced details');
  assert.match(technicalDetails.children.map(node => node.textContent).join(' '), /操作識別碼：op-uncertain/);
  assert.doesNotMatch(JSON.stringify(ui.state.pendingOperation), /memory-only/);
});

test('matching operation id with an unknown success status stays pending and blocks another write', async () => {
  const calls=[]; const ui=makeApp(async(url,options)=>{calls.push(url);if(url==='/api/session')return {ok:true,status:200,json:async()=>({sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:7,decisionRevision:12,selectionRevision:4,dataVersion:'d1',token:'t'})};if(url==='/api/operations'){const submitted=JSON.parse(options.body);return {ok:true,status:200,json:async()=>({jobId:submitted.operationId,status:'FutureStatus'})};}return {ok:true,status:200,json:async()=>({})};});
  ui.state.session={sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:7,decisionRevision:12,selectionRevision:4,dataVersion:'d1',token:'t'};
  const request=ui.buildOperationRequest('SetMigrationSpec',{},7);
  await assert.rejects(ui.endpoint('/api/operations',{method:'POST',body:JSON.stringify(request)}),/伺服端未回傳/);
  assert.equal(ui.state.pendingOperation.operationId,request.operationId);
  assert.equal(calls.filter(url=>url==='/api/operations').length,1);
  await assert.rejects(ui.endpoint('/api/operations',{method:'POST',body:JSON.stringify(ui.buildOperationRequest('SetMigrationSpec',{},7))}),/提交結果尚未確認/);
  assert.equal(calls.filter(url=>url==='/api/operations').length,1);
});

test('ReviewRequired terminal job refresh synchronizes revision and drops cached views before the next read', async () => {
  const calls = [];
  const ui = makeApp(async url => {
    calls.push(url);
    if (url === '/api/jobs') return { ok: true, status: 200, json: async () => ({ items: [{ jobId: 'job-1', action: 'SetMigrationSpec', pairId: 'p1', status: 'ReviewRequired' }] }) };
    if (url === '/api/session') return { ok: true, status: 200, json: async () => ({ sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 9 }) };
    if (url === '/api/context') return { ok: true, status: 200, json: async () => ({ contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 9, pairs: ['p1'], roles: ['Manager'] }) };
    if (url.startsWith('/api/view')) return { ok: true, status: 200, json: async () => ({ viewContext: { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 9, readUtc: 'now' }, metrics: { selected: 3 } }) };
    return { ok: true, status: 200, json: async () => ({}) };
  }, true);
  ui.state.session = { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 8 };
  ui.__location.hash = '#jobs';
  ui.state.jobs.set('job-1', { jobId: 'job-1', pairId: 'p1', status: 'Running' });
  ui.state.views['stale'] = { overview: true };
  await ui.refreshJobs();
  assert.equal(ui.state.session.revision, 9);
  assert.equal(Object.keys(ui.state.views).length, 0);
  ui.__location.hash = '#overview';
  await ui.getView('overview');
  assert.ok(calls.some(url => url.startsWith('/api/view?')));
  assert.ok(Object.keys(ui.state.views).some(key => key.includes('\u001f9')));
});

test('deep-link startup loads only the selected route and maps operations to actions', async () => {
  const calls = [];
  const ui = makeApp(async url => {
    calls.push(url);
    if (url === '/api/session') return { ok: true, status: 200, json: async () => ({ token: 't', sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 4 }) };
    if (url === '/api/context') return { ok: true, status: 200, json: async () => ({ contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 4, pairs: [{ pairId: 'p1', label: 'p1' }], roles: ['Manager'] }) };
    return { ok: true, status: 200, json: async () => ({ actions: [], viewContext: { sessionId: 's1', contextId: 'c1', pairId: 'p1', role: 'Manager', revision: 4, readUtc: 'now' } }) };
  }, true);
  ui.__location.hash = '#operations';
  await ui.init();
  assert.ok(calls.some(url => url.includes('action=actions')));
  assert.equal(calls.some(url => url.includes('action=overview')), false);
  assert.equal(ui.state.actions.length, 0);
});

test('clean software choices follow fresh producer values while dirty version and reason drafts survive refresh', () => {
  const ui=makeApp(async()=>({ok:true,status:200,json:async()=>({})}),true), choices=[{value:'1.0'},{value:'2.0'},{value:'3.0'}];
  ui.renderSoftware({rows:[{softwareId:'runtime',name:'Runtime',sourceVersion:'1.0',chosenVersion:'1.0',chosenVersionReason:'saved v1',versionChoices:choices}]});
  assert.equal(ui.state.softwareChoices.get('runtime'),'1.0');
  ui.renderSoftware({rows:[{softwareId:'runtime',name:'Runtime',sourceVersion:'1.0',chosenVersion:'2.0',chosenVersionReason:'saved v2',versionChoices:choices}]});
  let row=ui.__getElement('software-rows').children[0];
  assert.equal(row.children[2].children[0].value,'2.0'); assert.equal(row.children[2].children[2].value,'saved v2');
  assert.equal(ui.state.softwareChoices.get('runtime'),'2.0'); assert.equal(ui.state.softwareChoiceReasons.get('runtime'),'saved v2');
  row.children[2].children[0].value='3.0'; row.children[2].children[0].dispatch('change');
  row.children[2].children[2].value='local draft'; row.children[2].children[2].dispatch('input');
  ui.renderSoftware({rows:[{softwareId:'runtime',name:'Runtime',sourceVersion:'1.0',chosenVersion:'2.0',chosenVersionReason:'saved v2',versionChoices:choices}]});
  row=ui.__getElement('software-rows').children[0];
  assert.equal(row.children[2].children[0].value,'3.0'); assert.equal(row.children[2].children[2].value,'local draft');
  assert.ok(ui.state.softwareDirty.has('runtime'));
});

test('an explicitly cleared inventory reason stays blank after row rebuild and blocks payload reason reuse', () => {
  const ui=makeApp(async()=>({ok:true,status:200,json:async()=>({})}),true), data={items:[{itemId:'web-1',name:'Web workload',selected:false,reason:'previously saved'}],totalCount:1};
  ui.renderInventory(data);
  let reason=ui.__getElement('inventory-rows').children[0].children[0].children[1];
  assert.equal(reason.value,'previously saved');
  reason.value=''; reason.dispatch('input');
  ui.renderInventory(data);
  reason=ui.__getElement('inventory-rows').children[0].children[0].children[1];
  assert.equal(reason.value,''); assert.equal(ui.state.selectionReasons.has('web-1'),true);
  const payload=ui.buildSelectionArgs(ui.state.inventory,ui.state.selected,ui.state.selectionReasons);
  assert.equal(payload.unselectedItems[0].reason,'');
});

test('operations route restores its selected typed form and refreshes server-readonly fields', async () => {
  const ui=makeApp(async()=>({ok:true,status:200,json:async()=>({})}),true), metadata=revision=>[{action:'TargetSnapshot',requiredRole:'Manager',roleAvailable:true,parameters:[{name:'TargetPath',label:'目標盤點路徑',type:'path'},{name:'ExpectedRevision',label:'預期 revision',type:'integer',readOnly:true,value:revision}]}];
  ui.state.session={sessionId:'s',contextId:'c',pairId:'p',role:'Manager',revision:4,decisionRevision:23,selectionRevision:2,dataVersion:'d1'};
  ui.renderActions(metadata(23)); ui.setAction('TargetSnapshot');
  ui.__getElement('param-0').value='D:\\target-inventory.json'; ui.__getElement('param-1').value='23';
  await ui.navigate('help');
  ui.renderActions(metadata(24));
  assert.equal(ui.__getElement('action-picker').value,'TargetSnapshot');
  assert.equal(ui.state.activeAction,'TargetSnapshot');
  assert.equal(ui.__getElement('param-0').value,'D:\\target-inventory.json','safe user draft survives page round trip');
  assert.equal(ui.__getElement('param-1').value,'24','read-only revision uses fresh server metadata, not old draft');
  assert.equal(ui.__getElement('param-1').readOnly,true);
});

test('overview consumes native workflow and evidence projection fields and role-gates suggested actions', () => {
  const ui=makeApp(async()=>({ok:true,status:200,json:async()=>({})}),true);
  ui.renderOverview({metrics:{discovered:7},workloadStatus:'ReviewRequired',nextStep:{title:'下一步',description:'檢視目前證據。',reason:'角色符合。',action:'TargetSnapshot',actionMetadata:{action:'TargetSnapshot',label:'更新目標觀測',requiredRole:'Manager',roleAvailable:true}},provenance:{pairId:'pair-7',role:'Manager',revision:9,generation:3,stage:'Restore',stageStatus:'Succeeded',producedUtc:'2026-10-11T01:02:03Z',planHash:'a'.repeat(64),approvalReference:'b'.repeat(64),approvalKind:'SealedPlan',deliveryStatus:'ImportedVerified',deliveryGeneration:3,deliveryId:'delivery-7',transportHash:'c'.repeat(64),deliveryReportOnly:false,deliveryReadinessProof:true,deliveryProductionVerified:false},steps:[{id:'restore',label:'還原',status:'Recorded',source:'目前世代已接受的 Restore 階段結果',value:'還原 · 完成',resultStatus:'Succeeded',stage:'Restore',generation:3,producedUtc:'2026-10-11T01:02:03Z'}]});
  let overview=ui.__getElement('overview-provenance').textContent;
  for(const value of ['階段產生時間（ProducedUtc；非目標觀測時間）2026-10-11T01:02:03Z','計畫 SHA-256','核准參照 SHA-256','delivery-7','傳輸 SHA-256','僅報告 否','含就緒證明 是','正式環境驗證 否']) assert.ok(overview.includes(value),value);
  const step=ui.__getElement('workflow-steps').children[0]; assert.equal(step.children[1].children[0].textContent,'還原'); assert.match(step.children[1].children[1].textContent,/目前世代已接受的 Restore/); assert.match(step.children[1].children[1].textContent,/階段結果狀態：Succeeded/); assert.match(step.children[1].children[1].textContent,/2026-10-11T01:02:03Z/);
  assert.equal(ui.__getElement('next-step-action').hidden,false); assert.equal(ui.__getElement('next-step-action').textContent,'更新目標觀測');
  assert.equal(ui.statusName('Partial'),'部分完成'); assert.equal(ui.statusName('ReviewRequired'),'需要審閱'); assert.equal(ui.statusName('NotObserved'),'未觀測'); assert.equal(ui.statusName('Recorded'),'已記錄（不代表核准或完成）'); assert.equal(ui.statusName('NotTested'),'未測試');
  ui.renderOverview({metrics:{},nextStep:{action:'TargetSnapshot',actionMetadata:{action:'TargetSnapshot',roleAvailable:false,requiredRole:'Manager'}},provenance:{},steps:[{id:'selection',label:'項目選取',status:'Unknown',source:'輔助模式尚未啟用',value:'未知'}]});
  assert.equal(ui.__getElement('next-step-action').hidden,true,'producer roleAvailable=false must suppress the suggestion link');
  ui.renderOverview({metrics:{},nextStep:{action:'TargetSnapshot',actionMetadata:{action:'DifferentAction',roleAvailable:true}},provenance:{},steps:[{id:'selection',label:'項目選取',status:'Unknown',source:'輔助模式尚未啟用',value:'未知'}]});
  assert.equal(ui.__getElement('next-step-action').hidden,true,'metadata for a different operation must not authorize the suggestion link');
  overview=ui.__getElement('overview-provenance').textContent; assert.match(overview,/階段產生時間（ProducedUtc；非目標觀測時間）未知/); assert.match(overview,/傳輸 SHA-256 未知/); assert.match(overview,/正式環境驗證 未知/);
  assert.match(ui.__getElement('workflow-steps').children[0].children[1].children[1].textContent,/來源：輔助模式尚未啟用 · 值：未知/);
});

test('static help and docs remain reachable during focus refresh without requesting API views', async () => {
  const calls=[], ui=makeApp(async url=>{calls.push(url); if(url==='/api/session') return {ok:true,status:200,json:async()=>({sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:3,token:'t'})}; if(url==='/api/context') return {ok:true,status:200,json:async()=>({contextId:'c1',pairId:'p1',role:'Manager',pairs:[{pairId:'p1'}],roles:['Manager']})}; return {ok:true,status:404,json:async()=>({})};},true);
  ui.state.session={sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:3,token:'t'};
  for(const view of ['help','docs']) { ui.__location.hash=`#${view}`; await ui.refreshSession(true); await ui.refreshActiveData(); }
  assert.equal(calls.filter(url=>url.startsWith('/api/view')).length,0);
  assert.equal(calls.filter(url=>url==='/api/session').length,2);
  assert.equal(calls.filter(url=>url==='/api/context').length,2);
});

test('ReviewRequired pending operation is a known durable lookup result, not an unknown retry case', async () => {
  const ui=makeApp(async url=>{if(url==='/api/jobs/op-review') return {ok:true,status:200,json:async()=>({jobId:'op-review',status:'ReviewRequired',pairId:'p1'})}; if(url==='/api/session') return {ok:true,status:200,json:async()=>({sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:4,token:'t'})}; if(url==='/api/context') return {ok:true,status:200,json:async()=>({contextId:'c1',pairId:'p1',role:'Manager',pairs:[{pairId:'p1'}],roles:['Manager']})}; return {ok:true,status:200,json:async()=>({})};},true);
  ui.state.session={sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:3,token:'t'}; ui.__location.hash='#jobs'; ui.state.currentView='jobs'; ui.state.pendingOperation={operationId:'op-review',action:'Restore',pairId:'p1',workspace:''};
  const record=await ui.recoverPendingOperation();
  assert.equal(record.status,'ReviewRequired'); assert.equal(ui.state.pendingOperation,null); assert.equal(ui.state.jobs.get('op-review').status,'ReviewRequired');
});

test('legacy overview metric sentinels render Chinese unknown states without numeric units or observed claims', () => {
  const ui=makeApp(async()=>({ok:true,status:200,json:async()=>({})}),true);
  ui.renderOverview({metrics:{discovered:7,selected:'Unknown',approved:'NotMeasured',executable:'NotTested',pendingOrFailed:null},nextStep:{},provenance:{},steps:[]});
  const cards=ui.__getElement('metrics').children, byLabel=label=>cards.find(card=>card.children[0].textContent===label);
  for(const [label,display,status] of [['目前選取','未知','未知'],['已核准','未測量','未測量'],['本次可執行','未測試','未測試'],['待處理／失敗','未知','未知']]) { const card=byLabel(label); assert.ok(card); assert.equal(card.children[1].textContent,display); assert.match(card.children[2].textContent,new RegExp(`狀態：${status} ·`)); assert.doesNotMatch(card.children[1].textContent,/項$/); }
  assert.equal(ui.statusName('Sealed'),'已封存（效力仍須核對）'); assert.equal(ui.statusName('ImportedVerified'),'匯入收據已驗證'); assert.equal(ui.statusName('NoApproval'),'尚無核准'); assert.equal(ui.statusName('NoReceipt'),'尚無交付收據'); assert.equal(ui.statusName('Stale'),'已過期／需要複核'); assert.equal(ui.statusName('OldApproval'),'沿用舊核准／需要複核'); assert.equal(ui.statusName('FutureDeliveryStatus'),'FutureDeliveryStatus');
});


test('concurrent write preflights preserve the first uncertain operation and send only once', async () => {
  const session={sessionId:'s1',contextId:'c1',pairId:'p1',role:'Manager',revision:3,token:'t',workspace:'C:\\WSM\\Manager'};
  const writes=[];
  const ui=makeApp(async(url,options)=>{
    if(url==='/api/session') return {ok:true,status:200,json:async()=>({...session})};
    if(url==='/api/operations') { writes.push(JSON.parse(options.body)); throw new Error('connection reset after send'); }
    throw new Error('Unexpected read: '+url);
  },true);
  ui.state.session={...session};ui.state.token='t';
  const submit=(action,id)=>ui.endpoint('/api/operations',{method:'POST',body:JSON.stringify({action,operationId:id,idempotencyKey:id+'-key',args:{},expectedRevision:3,contextId:'c1'})});
  const results=await Promise.allSettled([submit('SaveSelection','first-operation'),submit('SetSoftwareVersion','second-operation')]);
  assert.equal(writes.length,1,'two callers that pass the initial preflight must not send two mutations');
  assert.equal(writes[0].operationId,'first-operation');
  assert.equal(ui.state.pendingOperation.operationId,'first-operation','the original uncertain write must remain recoverable');
  assert.equal(results[0].status,'rejected');assert.equal(results[1].status,'rejected');
  assert.match(results[1].reason.message,/提交結果尚未確認/);
  await assert.rejects(submit('SaveSelection','third-operation'),/提交結果尚未確認/);
  assert.equal(writes.length,1);
});
