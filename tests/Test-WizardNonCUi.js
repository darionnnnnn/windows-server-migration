'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'src/ui/nonc.js'), 'utf8');

function makeNode(tagName) {
  const node = {
    tagName: String(tagName || 'div').toUpperCase(), children: [], dataset: {}, attributes: {}, listeners: {}, style: {},
    className: '', textContent: '', value: '', checked: false, disabled: false, hidden: false, parentNode: null,
    appendChild(child) { this.children.push(child); child.parentNode = this; return child; },
    append(...children) { children.forEach(child => this.appendChild(child)); },
    replaceChildren(...children) { this.children.forEach(child => { child.parentNode = null; }); this.children = []; this.append(...children); },
    addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); },
    setAttribute(key, value) { this.attributes[key] = String(value); },
    remove() { if (this.parentNode) this.parentNode.children = this.parentNode.children.filter(child => child !== this); this.parentNode = null; },
    dispatch(type) { for (const listener of this.listeners[type] || []) listener({ target: this, preventDefault() {} }); },
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; },
    querySelectorAll(selector) {
      const result = [];
      const fieldMatch = selector.match(/^\[data-nonc-field="([^"]+)"\]$/);
      const attrMatch = selector.match(/^\[data-nonc-([a-z-]+)\]$/);
      const visit = node => {
        for (const child of node.children || []) {
          if (fieldMatch && child.dataset && child.dataset.noncField === fieldMatch[1]) result.push(child);
          else if (attrMatch && child.dataset && Object.prototype.hasOwnProperty.call(child.dataset, 'nonc' + attrMatch[1].split('-').map(part => part[0].toUpperCase() + part.slice(1)).join(''))) result.push(child);
          visit(child);
        }
      };
      visit(this);
      return result;
    }
  };
  Object.defineProperty(node, 'innerHTML', { get() { return ''; }, set() { throw new Error('innerHTML is forbidden in the NonC widget fixture'); } });
  return node;
}

function makeHarness() {
  const document = { createElement: makeNode };
  const window = { document };
  vm.runInNewContext(source, { window, document, Promise, Object, Array, Map, Set, String, Number, Math, globalThis: window }, { filename: 'nonc.js' });
  return { widget: window.WsmNonCWizard, container: makeNode('main') };
}

function api(role, pairId, projection, overrides = {}) {
  return Object.assign({
    context: { role, pairId, workspace: 'C:\\workspace', contextId: role + ':' + pairId, dataVersion: 1 },
    projection, submitted: [], dirtyCalls: 0, refreshCalls: 0,
    submit(action, args) { this.submitted.push({ action, args }); return Promise.resolve({ Status: 'Succeeded' }); },
    refresh() { this.refreshCalls++; return Promise.resolve(); },
    markDirty() { this.dirtyCalls++; }
  }, overrides);
}

function all(node) { return [node, ...(node.children || []).flatMap(all)]; }
function field(container, key) { return container.querySelector('[data-nonc-field="' + key + '"]'); }
function clickLabel(container, label) {
  const node = all(container).find(item => item.tagName === 'BUTTON' && item.textContent === label);
  assert.ok(node, 'button exists: ' + label);
  node.dispatch('click');
  return node;
}
function setField(container, key, value) {
  const control = field(container, key);
  assert.ok(control, 'field exists: ' + key);
  if (control.type === 'checkbox') control.checked = !!value;
  else control.value = value;
  control.dispatch('input');
  return control;
}
function managerProjection(overrides = {}) {
  return Object.assign({
    Kind: 'WizardNonCProjection', Role: 'Manager', PairId: 'pair-1', ContextId: 'Manager:pair-1', DataVersion: 1, HasNonC: true,
    CurrentPlan: { path: 'C:\\approved.json', hash: 'a'.repeat(64) }, ProofAllowed: true,
    Preparation: {
      Kind: 'WizardNonCPreparation', Status: 'NeedsHumanEvidence', CanCreateTransferPlan: true, CanImportResult: false,
      Current: { PlanPath: 'C:\\approved.json', PlanHash: 'a'.repeat(64), ManifestPath: 'C:\\final-manifest.json', ManifestHash: 'b'.repeat(64), Generation: 4, SelectionRevision: 2, InventoryHash: '1'.repeat(64), MaterialRegistryRevision: 3, NonCItemIds: ['item-1'] },
      Entries: [{ ItemId: 'item-1', Name: 'Finance share', Channel: 'NonC', SourcePath: '\\\\source\\share\\finance', TargetPath: '\\\\target\\share\\finance', ConsumerRefs: ['item-1'], RequiredHumanInputs: ['SourceAccessRoot', 'TargetAccessRoot', 'AccountMap'] }],
      MaterialChoices: [{ value: 'b'.repeat(64), label: 'Verified final package generation 4', generation: 4, path: 'C:\\final-manifest.json' }],
      ProofOptions: [
        { kind: 'SourcePeerShareProof', path: 'C:\\source-proof.json', sha256: 'c'.repeat(64), label: 'Source share' },
        { kind: 'TargetPhysicalProof', path: 'C:\\target-proof.json', sha256: 'd'.repeat(64), label: 'Target roots', requiresRootReview: true }
      ], TransferChoices: [{ path: 'C:\\transfer.json', sha256: 'e'.repeat(64), generation: 4, label: 'Transfer generation 4' }],
      NonCItemIds: ['item-1'], MaterialRegistryRevision: 3, HumanConfirmationRequired: true, ReadOnly: true
    },
    AccountObservation: {
      Kind: 'WizardNonCAccountObservationResult', Status: 'Succeeded', PairId: 'pair-1', PlanHash: 'a'.repeat(64), ManifestHash: 'b'.repeat(64), Generation: 4, InventoryHash: '1'.repeat(64), SelectionRevision: 2, TargetSnapshotHash: '2'.repeat(64), SourcePeerProofHash: 'c'.repeat(64), Path: 'C:\\observation.json', SHA256: 'f'.repeat(64), CreatedUtc: '2026-10-14T00:00:00Z', CoverageComplete: true, VisitedCount: 1, MaximumEntries: 100, ElapsedMilliseconds: 4, TimeoutSeconds: 45, TimedOut: false, Cancelled: false, ContentRead: false, UnresolvedCount: 0, AclReadFailureCount: 0, hasDurableRecord: true, current: true,
      Entries: [{ ItemId: 'item-1', Status: 'Observed', Principals: [{ SourceSid: 'S-1-5-21-1-2-3-1001', SourceName: 'OLD\\finance-user', OwnerObserved: true, RuleCount: 3 }] }],
      SourceIdentities: [{ SourceSid: 'S-1-5-21-1-2-3-1001', SourceName: 'OLD\\finance-user' }, { SourceSid: 'S-1-5-21-1-2-3-1999', SourceName: 'OLD\\not-on-this-acl' }],
      TargetIdentities: [{ identityId: 'S-1-5-21-9-8-7-1002', sid: 'S-1-5-21-9-8-7-1002', name: 'NEW\\finance-user', kind: 'LocalUser', stableBuiltin: false, source: 'VerifiedInventoryIdentity' }],
      AuthoritativeApproval: false, ProductionVerified: false
    },
    ResultSummary: { Status: 'ReviewRequired', AppliedCount: 1, BlockedCount: 1, DeferredCount: 0, AuthoritativeApproval: false, ProductionVerified: false }
  }, overrides);
}

test('no pair or C-only projection detaches actions while preserving stale draft notice', () => {
  const empty = makeHarness();
  assert.equal(empty.widget.render(empty.container, api('Manager', '', { HasNonC: false })).hidden, true);
  assert.equal(empty.container.hidden, true, 'no-pair pages without retained drafts keep the widget hidden');
  assert.equal(empty.container.children.length, 0);
  assert.equal(empty.widget.render(empty.container, api('Manager', 'pair-1', { HasNonC: false })).hidden, true);
  assert.equal(empty.container.hidden, true, 'C-only pages without retained drafts keep the widget hidden');
  assert.equal(empty.container.children.length, 0);

  const { widget, container } = makeHarness();
  const source = api('Source', 'prior-pair', { HasNonC: true, CurrentPlan: { hash: 'a'.repeat(64) } });
  widget.render(container, source);
  setField(container, 'sourceShareName', 'kept-source-draft');
  const noPair = api('Manager', '', { HasNonC: true });
  assert.equal(widget.render(container, noPair).hidden, true);
  assert.equal(container.hidden, false);
  assert.equal(all(container).some(node => node.textContent.includes('目前沒有可操作的非 C 工作')), true);
  assert.match(all(container).map(node => node.textContent).join(' '), /kept-source-draft/);
  const cOnly = api('Manager', 'pair-1', { HasNonC: false });
  assert.equal(widget.render(container, cOnly).hidden, true);
  assert.equal(cOnly.submitted.length, 0);
  assert.equal(widget.hasDirty(), true, 'detaching C-only actions does not discard the stale dirty context');
});

test('proof and Target handoff previews are discarded when their fields change while pending', async () => {
  {
    const { widget, container } = makeHarness();
    const manager = api('Manager', 'pair-1', managerProjection());
    let resolvePreview;
    manager.submit = function (action, args) { this.submitted.push({ action, args }); return new Promise(resolve => { resolvePreview = resolve; }); };
    widget.render(container, manager);
    setField(container, 'proofHandoffDirectory', 'D:\\received\\original');
    setField(container, 'proofExpectedManifestHash', '1'.repeat(64));
    setField(container, 'proofIndependentReferenceAck', true);
    clickLabel(container, '預覽證明交接');
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(manager.submitted[0].args.Directory, 'D:\\received\\original');
    setField(container, 'proofHandoffDirectory', 'D:\\received\\edited');
    setField(container, 'proofExpectedManifestHash', '2'.repeat(64));
    resolvePreview({ Status: 'Ready', PreviewId: 'stale-proof-preview', SourceHost: 'OLD', TargetHost: 'NEW' });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '匯入已預覽的證明'), false);
    assert.match(all(container).map(node => node.textContent).join(' '), /欄位在預覽期間已變更，請重新預覽/);
  }
  {
    const { widget, container } = makeHarness();
    const target = api('Target', 'pair-1', { HasNonC: true, CurrentPlan: { hash: 'a'.repeat(64) } });
    let resolvePreview;
    target.submit = function (action, args) { this.submitted.push({ action, args }); return new Promise(resolve => { resolvePreview = resolve; }); };
    widget.render(container, target);
    setField(container, 'targetHandoffDirectory', 'C:\\received\\original');
    setField(container, 'targetHandoffHash', '3'.repeat(64));
    setField(container, 'targetHandoffAck', true);
    clickLabel(container, '核對並預覽交接材料');
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(target.submitted[0].args.Directory, 'C:\\received\\original');
    setField(container, 'targetHandoffDirectory', 'C:\\received\\edited');
    setField(container, 'targetHandoffHash', '4'.repeat(64));
    resolvePreview({ Status: 'Ready', PreviewId: 'stale-target-preview', TransferPlanHash: '5'.repeat(64), ResultHash: '6'.repeat(64) });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '匯入這次已預覽的目標材料'), false);
    assert.match(all(container).map(node => node.textContent).join(' '), /欄位在預覽期間已變更，請重新預覽/);
  }
});

test('Manager renders exact per-item roots and SID dropdowns; incomplete mappings cannot submit', async () => {
  const { widget, container } = makeHarness();
  const projection = managerProjection();
  projection.Preparation.ProofOptions.push({ kind: 'SourcePeerShareProof', sha256: '9'.repeat(64), label: 'Source second share' });
  const manager = api('Manager', 'pair-1', projection);
  widget.render(container, manager);
  assert.ok(all(container).some(node => node.textContent.includes('Finance share')));
  assert.ok(field(container, 'itemSourceRoot:item-1'));
  assert.ok(field(container, 'itemTargetRoot:item-1'));
  assert.equal(field(container, 'planManifest').children.some(option => option.value === 'b'.repeat(64)), true, 'actual MaterialChoices field populates the final package selector');
  assert.equal(field(container, 'itemSourceRoot:item-1').value, '');
  const map = field(container, 'map:item-1:S-1-5-21-1-2-3-1001');
  assert.equal(map.tagName, 'SELECT');
  assert.equal(map.children.some(option => option.value === 'S-1-5-21-9-8-7-1002'), true);
  assert.equal(field(container, 'map:item-1:S-1-5-21-1-2-3-1999'), null, 'inventory identities absent from this item ACL are not mapped');
  setField(container, 'planManifest', 'b'.repeat(64));
  setField(container, 'planSourceProof', 'c'.repeat(64));
  setField(container, 'planExtraProof:' + '9'.repeat(64), true);
  setField(container, 'planTargetProof', 'd'.repeat(64));
  setField(container, 'planTargetStateDirectory', '\\\\target\\share\\state');
  setField(container, 'planOperationOwner', 'SYSTEM operator');
  setField(container, 'planEvidence', 'Reviewed by operations');
  setField(container, 'planMetadataPolicy', 'DaclOwnerMappedAndBasicTimes');
  setField(container, 'itemSourceRoot:item-1', '\\\\source\\share\\finance');
  setField(container, 'itemTargetRoot:item-1', '\\\\target\\share\\finance');
  clickLabel(container, '建立非 C 搬移計畫');
  assert.equal(manager.submitted.length, 0, 'unmapped observed SID must block plan creation');
  setField(container, 'map:item-1:S-1-5-21-1-2-3-1001', 'S-1-5-21-9-8-7-1002');
  clickLabel(container, '建立非 C 搬移計畫');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(manager.submitted.length, 1);
  assert.equal(manager.submitted[0].action, 'CreateNonCTransferPlan');
  assert.deepEqual(Array.from(manager.submitted[0].args.SourcePeerProofHashes), ['9'.repeat(64)]);
  assert.deepEqual(JSON.parse(JSON.stringify(manager.submitted[0].args.ItemScopes)), [{
    ItemId: 'item-1', SourceRoot: '\\\\source\\share\\finance', TargetRoot: '\\\\target\\share\\finance',
    AccountMappings: [{ SourceSid: 'S-1-5-21-1-2-3-1001', TargetSid: 'S-1-5-21-9-8-7-1002' }]
  }]);
  assert.match(all(container).map(node => node.textContent).join(' '), /操作負責人（Windows 操作負責人，不代表業務負責人）/);
  assert.match(all(container).map(node => node.textContent).join(' '), /不代表離線備份完成/);
});

test('Manager gates approval, incomplete observation and missing target identities', () => {
  const { widget, container } = makeHarness();
  const unapproved = api('Manager', 'pair-1', managerProjection({ CurrentPlan: null, Preparation: { Status: 'NeedsApproval', entries: [] } }));
  widget.render(container, unapproved);
  assert.match(all(container).map(node => node.textContent).join(' '), /尚未取得核准後的項目投影/);
  assert.equal(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '建立非 C 搬移計畫'), false);
  const incomplete = api('Manager', 'pair-1', managerProjection({ AccountObservation: { CoverageComplete: false, SHA256: 'f'.repeat(64), SourceIdentities: [{ SourceSid: 'S-1-5-21-1-2-3-1001', SourceName: 'legacy' }], TargetIdentities: [] } }));
  widget.render(container, incomplete);
  assert.match(all(container).map(node => node.textContent).join(' '), /涵蓋、來源身分或目標帳號清冊不完整/);
  assert.equal(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '建立非 C 搬移計畫'), false);
});

test('independent manifest reference is required; edits invalidate preview without replacing inputs', async () => {
  const { widget, container } = makeHarness();
  const manager = api('Manager', 'pair-1', managerProjection());
  let resolvePreview;
  manager.submit = function (action, args) {
    this.submitted.push({ action, args });
    return new Promise(resolve => { resolvePreview = resolve; });
  };
  widget.render(container, manager);
  setField(container, 'proofHandoffDirectory', 'D:\\received\\handoff');
  setField(container, 'proofExpectedManifestHash', '1'.repeat(64));
  setField(container, 'proofIndependentReferenceAck', true);
  clickLabel(container, '預覽證明交接');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(manager.submitted.length, 1);
  widget.render(container, manager); // Console redraws the same role/pair/data context while the job is completing.
  resolvePreview({ Status: 'Ready', PreviewId: 'preview-1', ObservedManifestHash: '9'.repeat(64), SourceHost: 'OLD-SERVER', TargetHost: 'NEW-SERVER', ReviewedTargetRoots: ['\\\\NEW-SERVER\\data\\finance'], TargetStateDirectory: '\\\\NEW-SERVER\\data\\state', Shares: [{ Name: 'DataD', LocalPath: 'D:\\\\data' }, { Name: 'StateC', LocalPath: 'C:\\\\work' }], Materials: [{ ShareName: 'DataD', SHA256: '7'.repeat(64) }], TargetStateShareName: 'StateC', ReviewedTargetRootMappings: [{ LocalPath: 'D:\\\\data', UNCPath: '\\\\\\\\NEW-SERVER\\\\data', ShareName: 'DataD' }] });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(manager.submitted[0].action, 'NonCProofPreview');
  assert.equal(manager.submitted[0].args.ExpectedManifestHash, '1'.repeat(64));
  assert.ok(all(container).some(node => node.textContent === '來源主機：OLD-SERVER'));
  assert.ok(all(container).some(node => node.textContent.includes('目標工作狀態目錄：\\\\NEW-SERVER\\data\\state')));
  const previewText = all(container).map(node => node.textContent).join(' ');
  assert.match(previewText, /既有共享：DataD/);
  assert.match(previewText, /狀態目錄使用共享：StateC/);
  assert.match(previewText, new RegExp('證明材料：DataD · SHA-256 ' + '7'.repeat(64)));
  clickLabel(container, '匯入已預覽的證明');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(manager.submitted[1].action, 'NonCProofImport');
  assert.equal(manager.submitted[1].args.ExpectedManifestHash, '1'.repeat(64));
  assert.equal(manager.submitted[1].args.PreviewId, 'preview-1');
  const blocked = api('Manager', 'pair-1', managerProjection());
  widget.render(container, blocked);
  setField(container, 'proofHandoffDirectory', 'D:\\received\\tampered');
  setField(container, 'proofExpectedManifestHash', 'short');
  setField(container, 'proofIndependentReferenceAck', true);
  clickLabel(container, '預覽證明交接');
  assert.equal(blocked.submitted.length, 0, 'malformed/missing independent expected hash cannot preview');
});

test('tampered or missing handoff preview failure never exposes an import confirmation', async () => {
  const { widget, container } = makeHarness();
  const manager = api('Manager', 'pair-1', managerProjection());
  manager.submit = function (action, args) { this.submitted.push({ action, args }); return Promise.resolve({ Status: 'Failed', Error: 'Material bytes differ from independent reference.' }); };
  widget.render(container, manager);
  setField(container, 'proofHandoffDirectory', 'D:\\received\\missing-or-tampered');
  setField(container, 'proofExpectedManifestHash', '2'.repeat(64));
  setField(container, 'proofIndependentReferenceAck', true);
  clickLabel(container, '預覽證明交接');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(manager.submitted.length, 1);
  assert.equal(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '匯入已預覽的證明'), false);
  assert.match(all(container).map(node => node.textContent).join(' '), /不要視為完成/);
});

test('editing proof preview inputs removes import confirmation without rebuilding the form', async () => {
  const { widget, container } = makeHarness();
  const manager = api('Manager', 'pair-1', managerProjection());
  manager.submit = function (action, args) {
    this.submitted.push({ action, args });
    return Promise.resolve({ Status: 'Ready', PreviewId: 'preview-edit', SourceHost: 'OLD', TargetHost: 'NEW' });
  };
  widget.render(container, manager);
  setField(container, 'proofHandoffDirectory', 'D:\\received\\handoff');
  setField(container, 'proofExpectedManifestHash', '1'.repeat(64));
  setField(container, 'proofIndependentReferenceAck', true);
  clickLabel(container, '預覽證明交接');
  await new Promise(resolve => setImmediate(resolve));
  assert.ok(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '匯入已預覽的證明'));
  const existingControl = field(container, 'proofHandoffDirectory');
  existingControl.value = 'D:\\received\\different';
  existingControl.dispatch('input');
  assert.equal(field(container, 'proofHandoffDirectory'), existingControl, 'the field node remains mounted while editing');
  assert.equal(existingControl.value, 'D:\\received\\different');
  assert.equal(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '匯入已預覽的證明'), false);
});

test('completion from a prior role/pair context is ignored after switching work', async () => {
  const { widget, container } = makeHarness();
  const manager = api('Manager', 'pair-1', managerProjection());
  let resolvePreview;
  manager.submit = function (action, args) { this.submitted.push({ action, args }); return new Promise(resolve => { resolvePreview = resolve; }); };
  widget.render(container, manager);
  setField(container, 'proofHandoffDirectory', 'D:\\received\\handoff');
  setField(container, 'proofExpectedManifestHash', '1'.repeat(64));
  setField(container, 'proofIndependentReferenceAck', true);
  clickLabel(container, '預覽證明交接');
  await new Promise(resolve => setImmediate(resolve));
  const source = api('Source', 'pair-2', { HasNonC: true, CurrentPlan: { path: 'C:\\other-plan.json', hash: 'a'.repeat(64) } });
  widget.render(container, source);
  resolvePreview({ Status: 'Ready', PreviewId: 'stale-preview', SourceHost: 'OLD-SERVER', TargetHost: 'NEW-SERVER' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(all(container).some(node => node.textContent.includes('OLD-SERVER')), false);
  assert.equal(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '匯入已預覽的證明'), false);
});

test('Source and Target expose only role-specific explicit material forms', () => {
  const { widget, container } = makeHarness();
  const source = api('Source', 'pair-1', { HasNonC: true, CurrentPlan: { path: 'C:\\received-plan.json', hash: 'a'.repeat(64) } });
  widget.render(container, source);
  assert.ok(field(container, 'sourceShareName'));
  assert.ok(field(container, 'transferPlanPath'));
  assert.equal(field(container, 'targetLocalRoots'), null);
  assert.equal(all(container).some(node => node.type === 'password' || node.dataset.noncField === 'password'), false);
  const target = api('Target', 'pair-1', { HasNonC: true, CurrentPlan: { path: 'C:\\received-plan.json', hash: 'a'.repeat(64) } });
  widget.render(container, target);
  assert.ok(field(container, 'targetLocalRoots'));
  assert.ok(field(container, 'targetStateDirectory'));
  assert.equal(field(container, 'targetStateDirectory').value, 'C:\\workspace\\pairs');
  assert.equal(field(container, 'targetStateDirectory').readOnly, true, 'restore state path is fixed by the enrolled workspace');
  assert.equal(field(container, 'targetLocalRoots').value, '', 'root set must not be guessed');
  assert.equal(field(container, 'sourceShareName'), null);
  const noWorkspace = api('Target', 'pair-1', { HasNonC: true, CurrentPlan: { path: 'C:\\received-plan.json', hash: 'a'.repeat(64) } }, { context: { role: 'Target', pairId: 'pair-1', contextId: 'Target:pair-1', dataVersion: 1 } });
  widget.render(container, noWorkspace);
  assert.equal(field(container, 'targetStateDirectory').value, '', 'missing enrolled workspace never guesses a state path');
  assert.equal(field(container, 'targetStateDirectory').readOnly, true);
  assert.match(all(container).map(node => node.textContent).join(' '), /不會猜測狀態目錄/);
});

test('dirty drafts remain isolated but visible and counted across role, pair, and data version', () => {
  const { widget, container } = makeHarness();
  const source = api('Source', 'pair-1', { HasNonC: true, CurrentPlan: { path: 'C:\\received-plan.json', hash: 'a'.repeat(64) } });
  widget.render(container, source);
  setField(container, 'sourceShareName', 'Existing');
  assert.equal(widget.hasDirty(), true);
  assert.equal(source.dirtyCalls, 1);
  const other = api('Source', 'pair-2', { HasNonC: true, CurrentPlan: { path: 'C:\\other.json', hash: 'b'.repeat(64) } });
  widget.render(container, other);
  assert.equal(field(container, 'sourceShareName').value, '');
  assert.equal(widget.hasDirty(), true);
  assert.match(all(container).map(node => node.textContent).join(' '), /Source · pair-1 · 資料版本 1/);
  assert.match(all(container).map(node => node.textContent).join(' '), /已存在的共享名稱/);
  assert.match(all(container).map(node => node.textContent).join(' '), /Existing/);
  setField(container, 'sourceSharePath', 'D:\\new-work');
  assert.equal(widget.hasDirty(), true, 'active and retained contexts both count');
  const switchedVersion = api('Source', 'pair-1', { HasNonC: true, CurrentPlan: { path: 'C:\\received-plan.json', hash: 'a'.repeat(64) } }, { context: { role: 'Source', pairId: 'pair-1', workspace: 'C:\\workspace', contextId: 'Source:pair-1', dataVersion: 2 } });
  widget.render(container, switchedVersion);
  assert.equal(field(container, 'sourceShareName').value, '', 'new data version resets stale draft');
  assert.match(all(container).map(node => node.textContent).join(' '), /Existing/);
  assert.match(all(container).map(node => node.textContent).join(' '), /D:\\new-work/);
  clickLabel(container, '捨棄保留草稿');
  assert.equal(field(container, 'sourceShareName').value, '', 'discarding stale contexts leaves current fields untouched');
  assert.equal(widget.hasDirty(), false);
  widget.clear(container);
  assert.equal(widget.hasDirty(), false);
  assert.equal(container.children.length, 0);
});

test('eight dirty contexts are retained; a ninth waits for explicit stale-draft cleanup', () => {
  const { widget, container } = makeHarness();
  for (let index = 1; index <= 8; index++) {
    const source = api('Source', 'pair-' + index, { HasNonC: true, CurrentPlan: { hash: 'a'.repeat(64) } });
    widget.render(container, source);
    setField(container, 'sourceShareName', 'draft-' + index);
  }
  const ninth = api('Source', 'pair-9', { HasNonC: true, CurrentPlan: { hash: 'a'.repeat(64) } });
  const result = widget.render(container, ninth);
  assert.equal(result.capacityBlocked, true);
  assert.equal(widget.hasDirty(), true);
  assert.equal(all(container).filter(node => node.className === 'nonc-retained-draft').length, 8);
  const retainedText = all(container).map(node => node.textContent).join(' ');
  for (let index = 1; index <= 8; index++) assert.ok(retainedText.includes('draft-' + index), 'retained draft ' + index + ' remains reviewable');
  clickLabel(container, '捨棄保留草稿');
  assert.ok(field(container, 'sourceShareName'), 'explicit cleanup resumes the pending new context');
  assert.equal(widget.hasDirty(), false, 'only explicit cleanup discards those retained drafts');
  setField(container, 'sourceShareName', 'draft-9');
  assert.equal(widget.hasDirty(), true);
  widget.render(container, api('Source', 'pair-1', { HasNonC: true, CurrentPlan: { hash: 'a'.repeat(64) } }));
  assert.equal(field(container, 'sourceShareName').value, '', 'discarded drafts are not silently restored');
});

test('pending submit is sent once and result status never claims full completion', async () => {
  const { widget, container } = makeHarness();
  let resolveSubmit;
  const source = api('Source', 'pair-1', { HasNonC: true, CurrentPlan: { path: 'C:\\received-plan.json', hash: 'a'.repeat(64) } });
  source.submit = function (action, args) { this.submitted.push({ action, args }); return new Promise(resolve => { resolveSubmit = resolve; }); };
  widget.render(container, source);
  setField(container, 'sourceShareName', 'Share');
  setField(container, 'sourceSharePath', 'D:\\Share');
  setField(container, 'sourceProofDestination', 'D:\\Handoff');
  setField(container, 'sourceNextOperator', 'Manager');
  const submit = clickLabel(container, '匯出共享證明');
  submit.dispatch('click');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(source.submitted.length, 1);
  resolveSubmit({ Status: 'ReviewRequired', AppliedCount: 0, BlockedCount: 1 });
  await new Promise(resolve => setImmediate(resolve));
  const message = all(container).map(node => node.textContent).join(' ');
  assert.match(message, /ReviewRequired/);
  assert.match(message, /不要視為完成/);
  assert.doesNotMatch(message, /全部完成/);
});

test('widget uses text nodes and remains width constrained for narrow layouts', () => {
  assert.doesNotMatch(source, /\.innerHTML\s*=|localStorage|sessionStorage|innerHTML\s*\+=/);
  const { widget, container } = makeHarness();
  container.clientWidth = 390;
  const hostile = api('Target', 'pair-1', { HasNonC: true, CurrentPlan: { path: 'C:\\p.json', hash: 'a'.repeat(64) }, HostName: '<img src=x onerror=alert(1)>' });
  widget.render(container, hostile);
  const rootNode = container.children[0];
  assert.equal(rootNode.style.maxWidth, '100%');
  assert.equal(rootNode.style.width, '100%');
  assert.equal(rootNode.style.boxSizing, 'border-box');
  assert.equal(field(container, 'targetLocalRoots').style.maxWidth, '100%');
  assert.equal(all(container).some(node => node.textContent.includes('<img src=x onerror=alert(1)>')), false);
  assert.ok(all(container).some(node => node.tagName === 'TEXTAREA' && node.rows === 4));
});

test('Target handoff requires an independent hash, previews once, then explicitly imports exact materials', async () => {
  const { widget, container } = makeHarness();
  const target = api('Target', 'pair-1', { HasNonC: true, CurrentPlan: { hash: 'a'.repeat(64) } });
  target.submit = function (action, args) {
    this.submitted.push({ action, args });
    return Promise.resolve(action === 'NonCTargetHandoffPreview' ? { Status: 'Ready', PreviewId: 'b'.repeat(64), TransferPlanHash: 'c'.repeat(64), ResultHash: 'd'.repeat(64) } : { Status: 'ImportedVerified' });
  };
  widget.render(container, target);
  setField(container, 'targetHandoffDirectory', 'C:\\交接 材料');
  setField(container, 'targetHandoffHash', 'e'.repeat(64));
  clickLabel(container, '核對並預覽交接材料');
  assert.equal(target.submitted.length, 0);
  setField(container, 'targetHandoffAck', true);
  clickLabel(container, '核對並預覽交接材料');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(target.submitted.length, 1);
  assert.equal(target.submitted[0].action, 'NonCTargetHandoffPreview');
  clickLabel(container, '匯入這次已預覽的目標材料');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(target.submitted.length, 2);
  assert.equal(target.submitted[1].action, 'NonCTargetHandoffImport');
  assert.deepEqual(JSON.parse(JSON.stringify(target.submitted[1].args)), { Directory: 'C:\\交接 材料', ExpectedManifestHash: 'e'.repeat(64), PreviewId: 'b'.repeat(64) });
  assert.equal(target.submitted.some(row => row.action === 'TargetRestore'), false);
  assert.equal(widget.hasDirty(), false, 'persisted import clears only its reviewed handoff draft');
  setField(container, 'targetHandoffDirectory', 'C:\\交接 材料');
  setField(container, 'targetHandoffHash', 'e'.repeat(64));
  setField(container, 'targetHandoffAck', true);
  clickLabel(container, '核對並預覽交接材料');
  await new Promise(resolve => setImmediate(resolve));
  const directoryField = field(container, 'targetHandoffDirectory');
  directoryField.value = 'C:\\改過的材料';
  directoryField.dispatch('input');
  assert.equal(field(container, 'targetHandoffDirectory'), directoryField, 'target form stays mounted while editing');
  assert.equal(all(container).some(node => node.tagName === 'BUTTON' && node.textContent === '匯入這次已預覽的目標材料'), false, 'changed target handoff inputs invalidate its import control');
});

test('Source and Target proof forms submit reviewed additional shares and reject incomplete pairs', async () => {
  for (const role of ['Source', 'Target']) {
    const { widget, container } = makeHarness();
    const model = api(role, 'pair-1', { HasNonC: true, CurrentPlan: { hash: 'a'.repeat(64) } });
    widget.render(container, model);
    const prefix = role.toLowerCase();
    for (const [key, value] of [[prefix + 'ShareName', 'DataD'], [prefix + 'SharePath', 'D:\\Data'], [prefix + 'ProofDestination', 'D:\\Handoff'], [prefix + 'NextOperator', 'Manager'], [prefix + 'AdditionalShareName:1', 'StateC']]) setField(container, key, value);
    if (role === 'Target') setField(container, 'targetLocalRoots', 'D:\\Data\nC:\\workspace\\pairs');
    clickLabel(container, role === 'Source' ? '匯出共享證明' : '匯出根目錄證明');
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(model.submitted.length, 0, 'partial share declaration never submits');
    setField(container, prefix + 'AdditionalSharePath:1', 'C:\\workspace');
    clickLabel(container, '新增另一個既有共享');
    assert.equal(field(container, prefix + 'ShareName').value, 'DataD', 'adding a row preserves the active form');
    assert.ok(field(container, prefix + 'AdditionalShareName:2'));
    clickLabel(container, role === 'Source' ? '匯出共享證明' : '匯出根目錄證明');
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(model.submitted.length, 1);
    assert.deepEqual(JSON.parse(JSON.stringify(model.submitted[0].args.AdditionalShares)), [{ ShareName: 'StateC', LocalPath: 'C:\\workspace' }]);
    if (role === 'Target') assert.equal(model.submitted[0].args.StateDirectory, 'C:\\workspace\\pairs');
  }
});

test('Manager selects multiple registered source proofs without typing hashes', async () => {
  const { widget, container } = makeHarness();
  const projection = managerProjection();
  projection.AccountObservation = null;
  projection.Preparation.ProofOptions.push({ kind: 'SourcePeerShareProof', sha256: 'e'.repeat(64), label: 'Source E data' });
  const model = api('Manager', 'pair-1', projection);
  widget.render(container, model);
  setField(container, 'observationSourceProof', 'c'.repeat(64));
  setField(container, 'observationExtraProof:' + 'e'.repeat(64), true);
  clickLabel(container, '觀測 ACL 身分');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(model.submitted.length, 1);
  assert.equal(model.submitted[0].args.SourcePeerProofHash, 'c'.repeat(64));
  assert.deepEqual(Array.from(model.submitted[0].args.SourcePeerProofHashes), ['e'.repeat(64)]);
});

test('successful NonC submissions clear their captured form and retain other or newer drafts', async () => {
  for (const extra of ['none', 'other-form', 'newer-edit']) {
    const { widget, container } = makeHarness();
    let finish;
    const sourceApi = api('Source', 'pair-1', { HasNonC: true, CurrentPlan: { hash: 'a'.repeat(64) } });
    sourceApi.submit = () => new Promise(resolve => { finish = resolve; });
    widget.render(container, sourceApi);
    for (const [key, value] of [['sourceShareName', 'Share'], ['sourceSharePath', 'D:\\Data'], ['sourceProofDestination', 'D:\\Handoff'], ['sourceNextOperator', 'Manager']]) setField(container, key, value);
    if (extra === 'other-form') setField(container, 'transferPlanPath', 'D:\\unsubmitted-plan.json');
    clickLabel(container, '匯出共享證明');
    await new Promise(resolve => setImmediate(resolve));
    if (extra === 'newer-edit') setField(container, 'sourceNextOperator', 'Different manager');
    finish({ Status: 'Exported' });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(widget.hasDirty(), extra !== 'none', extra);
  }
});
