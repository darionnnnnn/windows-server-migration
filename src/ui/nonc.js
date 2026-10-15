(function (root) {
  'use strict';

  const actionNames = Object.freeze({
    sourceProof: 'NonCSourceProofExport', targetProof: 'NonCTargetProofExport',
    proofPreview: 'NonCProofPreview', proofImport: 'NonCProofImport',
    accountObservation: 'NonCAccountObservation', createPlan: 'CreateNonCTransferPlan',
    importPlan: 'ImportNonCTransferPlan', startTransfer: 'StartNonCTransfer',
    importResult: 'ImportNonCResult', targetHandoffExport: 'NonCTargetHandoffExport',
    targetHandoffPreview: 'NonCTargetHandoffPreview', targetHandoffImport: 'NonCTargetHandoffImport'
  });
  const contexts = new Map();
  let active = null;
  let renderSequence = 0;
  let capacityRequest = null;
  let detachedRequest = null;

  function text(value) { return value == null ? '' : String(value); }
  function element(tag, className, label) {
    const node = root.document.createElement(tag);
    if (className) node.className = className;
    if (label !== undefined) node.textContent = text(label);
    return node;
  }
  function append(parent, child) { parent.appendChild(child); return child; }
  function safeArray(value) { return Array.isArray(value) ? value : []; }
  function get(obj, names, fallback) {
    for (const name of names) if (obj && Object.prototype.hasOwnProperty.call(obj, name) && obj[name] != null) return obj[name];
    return fallback;
  }
  function roleValue(context) { return text(context && context.role); }
  function roleLabel(context) { return ({ Source: '舊主機', Target: '新主機', Manager: '整理搬移資料的電腦' })[roleValue(context)] || '未知用途'; }
  function contextKey(context) {
    return [context && context.role, context && (context.workspace||context.workRoot), context && context.contextId, context && context.pairId, context && context.dataVersion].map(text).join('|');
  }
  function rebindReconnectDraft(oldContext, newContext) {
    const oldValue=oldContext||{},next=newContext||{},oldRoot=text(oldValue.workspace||oldValue.workRoot).replace(/[\\/]+$/,'').toLowerCase(),nextRoot=text(next.workspace||next.workRoot).replace(/[\\/]+$/,'').toLowerCase();
    if(!oldRoot||oldRoot!==nextRoot||!oldValue.role||text(oldValue.role)!==text(next.role)||!oldValue.pairId||text(oldValue.pairId)!==text(next.pairId)||oldValue.dataVersion==null||next.dataVersion==null||text(oldValue.dataVersion)!==text(next.dataVersion)||!oldValue.contextId||!next.contextId||text(oldValue.contextId)===text(next.contextId))return false;
    for(const key of ['materialVersion','materialHash'])if((oldValue[key]!=null||next[key]!=null)&&text(oldValue[key])!==text(next[key]))return false;
    const oldKey=contextKey(oldValue),nextKey=contextKey(next),state=contexts.get(oldKey);if(!state)return true;if(contexts.has(nextKey)&&contexts.get(nextKey)!==state)return false;
    if(state.pending)return false;
    state.key=nextKey;state.context=Object.assign({},next);state.preview=null;state.targetHandoffPreview=null;state.sequence++;
    contexts.delete(oldKey);contexts.set(nextKey,state);
    if(active&&active.state===state)active.key=nextKey;
    return true;
  }
  function clearSensitiveFields() {
    const sensitive=key=>/password|secret|credential|token|private.?key/i.test(text(key));
    for(const state of contexts.values())for(const key of [...state.fields.keys()])if(sensitive(key)||sensitive(state.labels.get(key))){state.fields.delete(key);state.dirtyFields.delete(key);}
    for(const input of document.querySelectorAll('[data-nonc-field]'))if(sensitive(input.dataset.noncField)||sensitive(input.getAttribute('aria-label')))input.value='';
    for(const state of contexts.values())state.dirty=state.dirtyFields.size>0;
  }
  function makeState(key, context) {
    if (contexts.size >= 8) {
      const cleanKey = Array.from(contexts.keys()).find(candidate => {
        const existing = contexts.get(candidate);
        return !existing || existing.dirtyFields.size === 0;
      });
      if (cleanKey === undefined) return null;
      contexts.delete(cleanKey);
    }
    const state = { key, context: Object.assign({}, context || {}), fields: new Map(), labels: new Map(), dirtyFields: new Map(), dirty: false, preview: null, targetHandoffPreview: null, message: '', pending: false, sequence: 0 };
    contexts.set(key, state);
    return state;
  }
  function currentData(api) {
    const p = api && api.projection || {};
    return {
      preparation: p.Preparation || p.preparation || p.nonCPreparation || p,
      observation: p.AccountObservation || p.accountObservation || p.observation || null,
      result: p.ResultSummary || p.resultSummary || p.resultsummary || p.nonCResult || null,
      targetIdentities: safeArray(p.TargetIdentities || p.targetIdentities || ((p.AccountObservation || p.accountObservation) && (p.AccountObservation || p.accountObservation).TargetIdentities)),
      selectedNonC: p.selectedNonCItemIds,
      operations: p,
      hasNonC: p.HasNonC === true || p.hasNonC === true,
      currentPlan: p.CurrentPlan || p.currentPlan || null,
      proofAllowed: p.ProofAllowed === true || p.proofAllowed === true,
      sourceChoices: p.SourceChoices || p.sourceChoices || null
    };
  }
  function entriesOf(data) {
    const prep = data.preparation || {};
    const rows = safeArray(prep.entries || prep.Entries);
    if (Array.isArray(data.selectedNonC)) {
      const selected = new Set(data.selectedNonC.map(text));
      return rows.filter(row => selected.has(text(row.itemId || row.ItemId)));
    }
    return rows.filter(row => row && row.selected !== false && row.Selected !== false && text(row.channel || row.Channel || 'NonC') === 'NonC');
  }
  function field(state, key, label, options) {
    const opts = options || {};
    state.labels.set(key, text(label));
    const wrap = element('label', 'nonc-field');
    wrap.style.display = 'block';
    wrap.style.maxWidth = '100%';
    wrap.style.boxSizing = 'border-box';
    append(wrap, element('span', 'nonc-field-label', label));
    let control;
    if (opts.type === 'select') {
      control = element('select', 'nonc-control');
      control.appendChild(makeOption(opts.placeholder || '請選擇', ''));
      for (const option of safeArray(opts.options)) {
        const value = text(get(option, ['value', 'sid', 'identityId', 'sha256', 'SHA256', 'ChoiceId', 'choiceId', 'path'], ''));
        const labelText = text(get(option, ['label', 'name', 'Name', 'sid', 'identityId', 'value'], value));
        control.appendChild(makeOption(labelText, value));
      }
    } else if (opts.type === 'checkbox') {
      control = element('input', 'nonc-control');
      control.type = 'checkbox';
    } else if (opts.type === 'textarea') {
      control = element('textarea', 'nonc-control');
      control.rows = opts.rows || 3;
    } else {
      control = element('input', 'nonc-control');
      control.type = 'text';
      control.autocomplete = 'off';
      control.spellcheck = false;
    }
    control.dataset.noncField = key;
    control.style.maxWidth = '100%';
    control.style.boxSizing = 'border-box';
    if (control.tagName !== 'INPUT' || control.type !== 'checkbox') control.style.width = '100%';
    control.setAttribute('aria-label', label);
    if (opts.placeholder) control.placeholder = opts.placeholder;
    if (opts.readonly) control.readOnly = true;
    const saved = state.fields.get(key);
    if (saved !== undefined) {
      if (control.type === 'checkbox') control.checked = !!saved;
      else control.value = text(saved);
    } else if (opts.value != null) {
      if (control.type === 'checkbox') control.checked = !!opts.value;
      else control.value = text(opts.value);
    }
    if (saved === undefined && opts.autoUnique && opts.type === 'select' && safeArray(opts.options).length === 1) control.value = text(get(opts.options[0], ['value', 'sid', 'identityId', 'sha256', 'SHA256', 'ChoiceId', 'choiceId', 'path'], ''));
    control.addEventListener('input', () => remember(state, key, control, opts.api));
    control.addEventListener('change', () => remember(state, key, control, opts.api));
    append(wrap, control);
    if (opts.reference) append(wrap, element('small', 'nonc-reference', '核准計畫參照：' + text(opts.reference)));
    return { wrap, control };
  }
  function makeOption(label, value) {
    const option = element('option', '', label);
    option.value = text(value);
    return option;
  }
  function remember(state, key, control, api) {
    state.fields.set(key, control.type === 'checkbox' ? !!control.checked : text(control.value));
    state.dirtyFields.set(key, state.fields.get(key));
    state.dirty = state.dirtyFields.size > 0;
    if (['proofHandoffDirectory', 'proofExpectedManifestHash', 'proofIndependentReferenceAck'].includes(key)) {
      state.preview = null;
      const preview = active && active.state === state && active.container.querySelector('[data-nonc-proof-preview]');
      if (preview) preview.remove();
    }
    if (['targetHandoffDirectory', 'targetHandoffHash', 'targetHandoffAck'].includes(key)) {
      state.targetHandoffPreview = null;
      const preview = active && active.state === state && active.container.querySelector('[data-nonc-target-handoff-preview]');
      if (preview) preview.remove();
    }
    if (api && typeof api.markDirty === 'function') api.markDirty();
  }
  function capturedValuesMatch(state, captured, keys) {
    return keys.every(key => captured.has(key) && state.fields.has(key) && state.fields.get(key) === captured.get(key));
  }
  function clearSubmittedDraft(state, captured, result) {
    if (!result || !['Succeeded', 'ImportedVerified', 'Exported', 'Delivered'].includes(text(result.Status || result.status))) return false;
    for (const [key, value] of captured) if (state.dirtyFields.has(key) && state.fields.get(key) === value) state.dirtyFields.delete(key);
    state.dirty = state.dirtyFields.size > 0;
    return true;
  }
  function read(form, key) {
    const control = form.querySelector('[data-nonc-field="' + key + '"]');
    if (!control) return '';
    return control.type === 'checkbox' ? !!control.checked : text(control.value).trim();
  }
  function statusText(result) {
    if (!result) return '伺服端尚未回傳可核對的結果。';
    const status = text(get(result, ['Status', 'status'], 'Unknown'));
    if (['Succeeded', 'ImportedVerified', 'Ready', 'Previewed'].includes(status)) return '已收到本步驟結果：' + status + '。後續步驟仍需分別審閱。';
    if (['Failed', 'Cancelled', 'ReviewRequired', 'Blocked', 'Interrupted', 'Unknown', 'UnknownWrite'].includes(status)) return '本步驟狀態：' + status + '。請重新載入核對持久資料；不要視為完成。';
    return '本步驟回報狀態：' + status + '。請依結果明細與下一步檢查。';
  }
  function submitOnce(state, api, container, action, args, onResult) {
    if (state.pending || !api || typeof api.submit !== 'function') return;
    state.pending = true;
    state.message = '正在提交這一步，請等待伺服端回報狀態。';
    renderMessage(container, state, 'nonc-progress');
    const sequence = ++state.sequence;
    const submissionKey = active && active.state === state ? active.key : state.key;
    const isCurrent = () => !!(active && active.state === state && active.key === submissionKey && contexts.get(submissionKey) === state && state.sequence === sequence);
    Promise.resolve().then(() => api.submit(action, args)).then(result => {
      if (!isCurrent()) return;
      state.pending = false;
      state.message = statusText(result);
      if (typeof onResult === 'function') onResult(result);
      render(active.container, active.api);
      renderMessage(active.container, state, result && ['Succeeded', 'ImportedVerified', 'Ready', 'Previewed'].includes(text(get(result, ['Status', 'status'], ''))) ? 'nonc-result' : 'nonc-warning');
    }).catch(error => {
      if (!isCurrent()) return;
      state.pending = false;
      state.message = '本步驟未確認成功：' + text(error && error.message || '伺服端結果未知') + '。請先重新載入狀態，勿重送。';
      render(active.container, active.api);
      renderMessage(active.container, state, 'nonc-warning');
    });
  }
  function renderMessage(container, state, className) {
    const old = container.querySelector('[data-nonc-message]');
    if (old) old.remove();
    if (!state.message) return;
    const box = element('p', className || 'nonc-message', state.message);
    box.dataset.noncMessage = 'true';
    append(container, box);
  }
  function button(label, action) {
    const node = element('button', 'nonc-button', label);
    node.style.maxWidth = '100%';
    node.style.boxSizing = 'border-box';
    node.type = 'button';
    node.addEventListener('click', action);
    return node;
  }
  function section(parent, title, description) {
    const box = element('section', 'nonc-section');
    append(box, element('h3', 'nonc-section-title', title));
    if (description) append(box, element('p', 'nonc-copy', description));
    append(parent, box);
    return box;
  }
  function form(parent, title, api, state, fields, action, buildArgs, submitLabel, options) {
    const opts = options || {};
    const box = section(parent, title, opts.description || '');
    const formNode = element('form', 'nonc-form');
    formNode.addEventListener('submit', event => event.preventDefault());
    const refs = {};
    for (const spec of fields) {
      const made = field(state, spec.key, spec.label, Object.assign({}, spec, { api }));
      refs[spec.key] = made.control;
      append(formNode, made.wrap);
    }
    const submit = button(submitLabel, () => {
      if (state.pending) return;
      const args = buildArgs(formNode, refs);
      if (!args) {
        state.message = opts.validationMessage || '請完成本步驟需要的明確選擇。';
        renderMessage(parent, state, 'nonc-warning');
        return;
      }
      submit.disabled = true;
      const captured = new Map(Object.keys(refs).map(key => [key, refs[key].type === 'checkbox' ? !!refs[key].checked : text(refs[key].value)]));
      for (const [key, value] of captured) if (!state.fields.has(key)) state.fields.set(key, value);
      submitOnce(state, api, parent, action, args, result => {
        submit.disabled = false;
        clearSubmittedDraft(state, captured, result);
        if (opts.onResult) opts.onResult(result, captured);
      });
    });
    submit.disabled = !!state.pending;
    append(formNode, submit);
    append(box, formNode);
    return { box, formNode, refs, submit };
  }
  function list(parent, title, rows, rowText, emptyText) {
    const box = section(parent, title, '');
    const ul = element('ul', 'nonc-list');
    if (!rows.length) append(ul, element('li', 'nonc-empty', emptyText || '目前沒有可顯示項目。'));
    for (const row of rows) append(ul, element('li', 'nonc-list-row', rowText(row)));
    append(box, ul);
    return box;
  }
  function actionValue(action) { return actionNames[action] || action; }
  function additionalShareFields(state, prefix) {
    const count = Math.min(15, Math.max(1, Number(state.fields.get(prefix + 'ShareCount')) || 1));
    const fields = [];
    for (let index = 1; index <= count; index++) {
      fields.push({ key: prefix + 'ShareName:' + index, label: '其他既有共享 ' + index + '：名稱（不需要可整組留空）' });
      fields.push({ key: prefix + 'SharePath:' + index, label: '其他既有共享 ' + index + '：該主機本機路徑' });
    }
    return { count, fields };
  }
  function readAdditionalShares(formNode, prefix, count) {
    const rows = [];
    for (let index = 1; index <= count; index++) {
      const ShareName = read(formNode, prefix + 'ShareName:' + index), LocalPath = read(formNode, prefix + 'SharePath:' + index);
      if (!ShareName && !LocalPath) continue;
      if (!ShareName || !LocalPath) {
        formNode.querySelector('[data-nonc-field="' + prefix + (!ShareName ? 'ShareName:' : 'SharePath:') + index + '"]')?.focus?.();
        return null;
      }
      rows.push({ ShareName, LocalPath });
    }
    return rows;
  }
  function moreShares(parent, api, state, prefix, count) {
    if (count >= 15) return;
    append(parent, button('新增另一個既有共享', () => {
      if (state.pending || !active || active.state !== state) return;
      const container = active.container;
      state.fields.set(prefix + 'ShareCount', count + 1);
      render(container, api);
      container.querySelector('[data-nonc-field="' + prefix + 'ShareName:' + (count + 1) + '"]')?.focus?.();
    }));
  }
  function additionalProofFields(proofs, prefix) {
    return proofs.length < 2 ? [] : proofs.map(row => ({ key: prefix + ':' + text(row.sha256 || row.SHA256), type: 'checkbox', label: '本輪也使用此舊主機共享：' + text(row.label || row.path || row.ShareName) }));
  }
  function readAdditionalProofs(formNode, proofs, prefix, primary) {
    return proofs.map(row => text(row.sha256 || row.SHA256)).filter(hash => hash !== primary && read(formNode, prefix + ':' + hash));
  }
  function proofFields(role, state, api, container, data) {
    const prefix = role === 'Source' ? 'sourceAdditional' : 'targetAdditional';
    const extra = additionalShareFields(state, prefix);
    if (role === 'Source') {
      form(container, '匯出舊主機共享資料夾證明', api, state, [
        { key: 'sourceShareName', label: '已存在的共享名稱' }, { key: 'sourceSharePath', label: '該共享的本機路徑' },
        ...extra.fields,
        { key: 'sourceProofDestination', label: '受控交接資料夾' }, { key: 'sourceNextOperator', label: '下一位操作人' }
      ], actionValue('sourceProof'), f => {
        const ShareName = read(f, 'sourceShareName'), LocalPath = read(f, 'sourceSharePath'), Destination = read(f, 'sourceProofDestination'), NextOperator = read(f, 'sourceNextOperator');
        const AdditionalShares = readAdditionalShares(f, prefix, extra.count);
        return ShareName && LocalPath && Destination && NextOperator && AdditionalShares ? { ShareName, LocalPath, Destination, NextOperator, AdditionalShares } : null;
      }, '匯出共享證明', { description: '逐個審閱已存在的共享；跨槽資料可使用不同共享。名稱與本機路徑須成組填寫，不建立共享、不收集密碼。', validationMessage: '請完成主要共享及交接資料；其他共享的名稱與本機路徑須同時填寫，或整組留空。' });
      moreShares(container, api, state, prefix, extra.count);
    } else if (role === 'Target') {
      const workspace = text(api && api.context && api.context.workspace).replace(/[\\/]+$/, '');
      const stateDirectory = workspace ? workspace + '\\pairs' : '';
      state.fields.delete('targetStateDirectory');
      state.dirtyFields.delete('targetStateDirectory');
      state.dirty = state.dirtyFields.size > 0;
      form(container, '匯出新主機根目錄證明', api, state, [
        { key: 'targetShareName', label: '已存在的共享名稱' }, { key: 'targetSharePath', label: '該共享的本機路徑' },
        ...extra.fields,
        { key: 'targetLocalRoots', label: '本次明確審閱的本機根目錄（每行一項）', type: 'textarea', rows: 4 },
        { key: 'targetStateDirectory', label: '已註冊工作區的固定狀態目錄', value: stateDirectory, readonly: true }, { key: 'targetProofDestination', label: '受控交接資料夾' },
        { key: 'targetNextOperator', label: '下一位操作人' }
      ], actionValue('targetProof'), f => {
        const ShareName = read(f, 'targetShareName'), LocalPath = read(f, 'targetSharePath'), LocalRoots = read(f, 'targetLocalRoots').split(/\r?\n/).map(x => x.trim()).filter(Boolean), StateDirectory = read(f, 'targetStateDirectory'), Destination = read(f, 'targetProofDestination'), NextOperator = read(f, 'targetNextOperator');
        const AdditionalShares = readAdditionalShares(f, prefix, extra.count);
        return ShareName && LocalPath && LocalRoots.length && StateDirectory && Destination && NextOperator && AdditionalShares ? { ShareName, LocalPath, LocalRoots, StateDirectory, Destination, NextOperator, AdditionalShares } : null;
      }, '匯出根目錄證明', { description: stateDirectory ? '逐個審閱資料與狀態目錄使用的既有共享。每個根目錄須由唯一共享涵蓋；固定狀態目錄可使用另一共享。未知值不自動帶入。' : '目前沒有已註冊工作區路徑，因此不會猜測狀態目錄；此表單須先從已註冊 Target 工作區開啟。', validationMessage: '請完成根目錄與交接資料；每組共享的名稱與本機路徑須同時填寫，或整組留空。' });
      moreShares(container, api, state, prefix, extra.count);
    }
  }
  function sourceView(parent, api, state, data) {
    proofFields('Source', state, api, parent, data);
    form(parent, '匯入已核對的非 C 搬移計畫', api, state, [
      { key: 'transferPlanPath', label: '獨立收到的計畫檔案位置' }, { key: 'transferPlanHash', label: '經獨立管道取得的計畫 SHA-256' },
      { key: 'transferPlanReferenceAck', label: '我已從計畫檔案以外的可信來源核對計畫指紋', type: 'checkbox' },
      { key: 'freezeEvidencePath', label: '舊主機停止寫入證明檔案位置' }, { key: 'freezeEvidenceHash', label: '停止寫入證明的獨立 SHA-256' },
      { key: 'freezeEvidenceReferenceAck', label: '我已從證明檔案以外的可信來源核對停止寫入指紋', type: 'checkbox' }
    ], actionValue('importPlan'), f => {
      const Path = read(f, 'transferPlanPath'), ExpectedHash = read(f, 'transferPlanHash'), FreezeEvidencePath = read(f, 'freezeEvidencePath'), FreezeEvidenceHash = read(f, 'freezeEvidenceHash');
      return Path && /^[a-fA-F0-9]{64}$/.test(ExpectedHash) && read(f, 'transferPlanReferenceAck') && FreezeEvidencePath && /^[a-fA-F0-9]{64}$/.test(FreezeEvidenceHash) && read(f, 'freezeEvidenceReferenceAck') ? { Path, ExpectedHash, FreezeEvidencePath, FreezeEvidenceHash } : null;
    }, '核對並匯入計畫', { description: '匯入前會重新核對計畫、核准主機與最終備份世代。非 C 搬移結果仍需另行匯入確認。' });
    const sourceChoices = data.sourceChoices && (data.sourceChoices.TransferChoices || data.sourceChoices.transferChoices);
    const choices = safeArray(sourceChoices || data.operations.transferChoices || data.operations.TransferChoices || (data.preparation && data.preparation.transferChoices));
    if (choices.length) {
      const start = form(parent, '開始本次非 C 搬移', api, state, [
        { key: 'transferChoice', autoUnique: true, label: '工具已核對的搬移計畫', type: 'select', options: choices.map(row => ({ value: row.ChoiceId || row.choiceId, label: row.Label || row.label })) },
        { key: 'transferScopeAck', label: '我已確認這是本次核准的非 C 搬移範圍', type: 'checkbox' }
      ], actionValue('startTransfer'), f => {
        const TransferChoiceId = read(f, 'transferChoice');
        return TransferChoiceId && read(f, 'transferScopeAck') ? { TransferChoiceId } : null;
      }, '開始搬移', { description: '操作只使用已核對的搬移選擇；遇到衝突或取消會保留待審閱狀態。' });
    } else {
      append(section(parent, '開始本次非 C 搬移', '目前沒有已核對的搬移計畫；先完成匯入與確認。'), element('p', 'nonc-empty', '不會從任意路徑自動選擇搬移計畫。'));
    }
  }
  function managerView(parent, api, state, data) {
    const entries = entriesOf(data);
    append(parent, element('p', 'nonc-callout', 'C 槽備份與非 C 搬移分開處理；非 C 暫存不代表離線備份完成。'));
    if (!data.hasNonC) {
      append(parent, element('p', 'nonc-not-applicable', '目前沒有已選取的非 C 搬移項目。非 C 證明與搬移準備不適用；C 槽備份流程仍獨立顯示。'));
      return;
    }
    if (!entries.length) {
      append(parent, element('p', 'nonc-warning', '目前工作已包含非 C 項目，但尚未取得核准後的項目投影；請先完成管理審閱與核准。'));
      return;
    }
    list(parent, '本次已選非 C 項目', entries, row => text(row.name || row.Name || row.itemId || row.ItemId));
    const prep = data.preparation || {};
    const approved = !!(data.currentPlan && (data.currentPlan.hash || data.currentPlan.SHA256 || data.currentPlan.PlanHash) && prep.Status !== 'NeedsApproval' && prep.Status !== 'NeedsApprovedPlan');
    if (!approved) {
      append(parent, element('p', 'nonc-warning', '已選非 C 項目，但目前沒有可用的核准計畫；尚不能預覽或匯入證明。'));
      return;
    }
    if (data.proofAllowed) form(parent, '核對並匯入主機證明交接', api, state, [
      { key: 'proofHandoffDirectory', label: '獨立收到的交接資料夾' },
      { key: 'proofExpectedManifestHash', label: '透過另一可信管道收到的交接清單 SHA-256' },
      { key: 'proofIndependentReferenceAck', label: '我已從交接資料夾以外的可信來源核對這個指紋', type: 'checkbox' }
    ], actionValue('proofPreview'), f => {
      const Directory = read(f, 'proofHandoffDirectory'), ExpectedManifestHash = read(f, 'proofExpectedManifestHash');
      return Directory && /^[a-fA-F0-9]{64}$/.test(ExpectedManifestHash) && read(f, 'proofIndependentReferenceAck') ? { Directory, ExpectedManifestHash } : null;
    }, '預覽證明交接', { description: '交接資料夾內的 observed hash 不會作為獨立信任參照。預覽不寫入材料登錄。', onResult: (result, captured) => {
      if (result && (result.Status === 'Ready' || result.status === 'Ready') && (result.PreviewId || result.previewId)) {
        const keys = ['proofHandoffDirectory', 'proofExpectedManifestHash', 'proofIndependentReferenceAck'];
        if (!capturedValuesMatch(state, captured, keys)) {
          state.preview = null;
          state.message = '欄位在預覽期間已變更，請重新預覽；目前沒有可匯入的預覽。';
          return;
        }
        state.preview = { captured, Directory: captured.get('proofHandoffDirectory'), ExpectedManifestHash: captured.get('proofExpectedManifestHash'), PreviewId: result.PreviewId || result.previewId, SourceHost: result.SourceHost || result.sourceHost, TargetHost: result.TargetHost || result.targetHost, ReviewedTargetRoots: result.ReviewedTargetRoots || result.reviewedTargetRoots || [], TargetStateDirectory: result.TargetStateDirectory || result.targetStateDirectory || '', Shares: result.Shares || [], Materials: result.Materials || [], ReviewedTargetRootMappings: result.ReviewedTargetRootMappings || [], TargetStateShareName: result.TargetStateShareName || '' };
        renderProofPreview(parent, state, api);
      }
    } });
    if (state.preview) renderProofPreview(parent, state, api);
    else if (!data.proofAllowed) append(parent, element('p', 'nonc-copy', '目前角色或工作階段尚未允許主機證明匯入。'));
    const observation = data.observation;
    const choices = safeArray(prep.materialChoices || prep.MaterialChoices || prep.choices || prep.Choices);
    const proofs = safeArray(prep.proofOptions || prep.ProofOptions);
    const sourceProofs = proofs.filter(row => text(row.kind || row.Kind) === 'SourcePeerShareProof');
    const targetProofs = proofs.filter(row => text(row.kind || row.Kind) === 'TargetPhysicalProof');
    const targetIdentities = data.targetIdentities.filter(row => row && (row.sid || row.SID || row.identityId));
    const coverage = observation ? text(observation.CoverageComplete != null ? observation.CoverageComplete : observation.coverageComplete) : '尚未觀測';
    const observedEntries = observation ? safeArray(observation.Entries || observation.entries) : [];
    const principalsFor = itemId => {
      const matches = observedEntries.filter(row => text(row.ItemId || row.itemId) === itemId && text(row.Status || row.status) === 'Observed');
      return matches.length === 1 ? safeArray(matches[0].Principals || matches[0].principals) : [];
    };
    const coverageByItem = entries.every(entry => {
      const id = text(entry.itemId || entry.ItemId);
      return observedEntries.filter(row => text(row.ItemId || row.itemId) === id && text(row.Status || row.status) === 'Observed').length === 1;
    });
    const identityRows = observedEntries.flatMap(row => {
      const itemId = text(row.ItemId || row.itemId);
      const itemName = text((entries.find(entry => text(entry.itemId || entry.ItemId) === itemId) || {}).name || itemId);
      const found = safeArray(row.Principals || row.principals);
      if (!found.length) return [itemName + '：' + text(row.Status || row.status || 'Unknown') + ' · 未觀測到 ACL 主體'];
      return found.map(principal => itemName + '：' + text(principal.SourceName || principal.name || principal.Name || '未解析名稱') + ' [' + text(principal.SourceSid || principal.sid || principal.SID) + '] · 擁有者=' + (principal.OwnerObserved ? '是' : '否') + ' · ACL 規則=' + text(principal.RuleCount || 0));
    });
    list(parent, 'ACL 身分與項目涵蓋', observation ? identityRows : [], row => row, observation ? '尚未觀測到 ACL 身分。' : '尚未取得目前核准與材料綁定的觀測結果。');
    append(parent, element('p', 'nonc-coverage', '身分涵蓋完整：' + (coverage === 'true' ? '是' : coverage === 'false' ? '否' : coverage)));
    if (!observation || !coverageByItem || (observation.CoverageComplete !== true && observation.coverageComplete !== true)) {
      form(parent, '觀測目前非 C 項目的 ACL 身分', api, state, [
        { key: 'observationManifest', autoUnique: true, label: '工具核對的最終備份', type: 'select', options: choices.map(row => ({ value: row.value || row.SHA256 || row.sha256, label: row.label || row.Label })) },
        { key: 'observationSourceProof', autoUnique: true, label: '主要舊主機共享證明', type: 'select', options: sourceProofs.map(row => ({ value: row.sha256 || row.SHA256, label: row.label || row.path })) },
        ...additionalProofFields(sourceProofs, 'observationExtraProof')
      ], actionValue('accountObservation'), f => {
        const ManifestSelection = read(f, 'observationManifest'), SourcePeerProofHash = read(f, 'observationSourceProof');
        const SourcePeerProofHashes = readAdditionalProofs(f, sourceProofs, 'observationExtraProof', SourcePeerProofHash);
        return ManifestSelection && SourcePeerProofHash ? { ManifestSelection, SourcePeerProofHash, SourcePeerProofHashes } : null;
      }, '觀測 ACL 身分', { description: '只讀取核准項目的 ACL 中繼資料；不讀取檔案內容。' });
    }
    if (prep.CanCreateTransferPlan === true && observation && (observation.CoverageComplete === true || observation.coverageComplete === true) && coverageByItem && targetIdentities.length && choices.length && sourceProofs.length && targetProofs.length) {
      const rows = entries.map(entry => ({ entry }));
      const fields = [
        { key: 'planManifest', autoUnique: true, label: '已核對的最終備份', type: 'select', options: choices.map(row => ({ value: row.value || row.SHA256 || row.sha256, label: row.label || row.Label })) },
        { key: 'planSourceProof', autoUnique: true, label: '已核對的舊主機共享證明', type: 'select', options: sourceProofs.map(row => ({ value: row.sha256 || row.SHA256, label: row.label || row.path })) },
        ...additionalProofFields(sourceProofs, 'planExtraProof'),
        { key: 'planTargetProof', autoUnique: true, label: '已核對的新主機位置證明', type: 'select', options: targetProofs.map(row => ({ value: row.sha256 || row.SHA256, label: row.label || row.path })) },
        { key: 'planTargetStateDirectory', label: '新主機狀態目錄（明確選取）' },
        { key: 'planOperationOwner', label: '操作負責人（Windows 操作負責人，不代表業務負責人）' },
        { key: 'planEvidence', label: '本次映射審閱依據', type: 'textarea', rows: 3 },
        { key: 'planMetadataPolicy', label: '中繼資料保存政策', type: 'select', options: [{ value: 'DaclOwnerMappedAndBasicTimes', label: 'DACL、擁有者與基本時間' }, { value: 'DaclOwnerSaclMappedAndBasicTimes', label: 'DACL、擁有者、SACL 與基本時間' }] }
      ];
      for (const { entry, index } of rows) {
        const id = text(entry.itemId || entry.ItemId);
        fields.push({ key: 'itemSourceRoot:' + id, label: text(entry.name || entry.Name || id) + '：舊主機來源根目錄', reference: entry.SourcePath || entry.sourcePath });
        fields.push({ key: 'itemTargetRoot:' + id, label: text(entry.name || entry.Name || id) + '：新主機目標根目錄', reference: entry.TargetPath || entry.targetPath });
        for (const principal of principalsFor(id)) {
          const sid = text(principal.SourceSid || principal.sid || principal.SID || principal.identityId);
          const name = text(principal.SourceName || principal.name || principal.Name || sid);
          fields.push({ key: 'map:' + id + ':' + sid, label: text(entry.name || entry.Name || id) + '：' + name + ' 對應的新主機帳號', type: 'select', options: targetIdentities.map(identity => ({ value: identity.sid || identity.SID || identity.identityId, label: identity.name || identity.Name || identity.sid || identity.SID })) });
        }
      }
      form(parent, '審閱每個項目與帳號對應', api, state, fields, actionValue('createPlan'), f => {
        const ManifestSelection = read(f, 'planManifest'), SourcePeerProofHash = read(f, 'planSourceProof'), TargetPhysicalProofHash = read(f, 'planTargetProof'), TargetStateDirectory = read(f, 'planTargetStateDirectory'), Owner = read(f, 'planOperationOwner'), Evidence = read(f, 'planEvidence'), MetadataPolicy = read(f, 'planMetadataPolicy');
        if (!(ManifestSelection && SourcePeerProofHash && TargetPhysicalProofHash && TargetStateDirectory && Owner && Evidence && MetadataPolicy)) return null;
        const ItemScopes = [];
        for (const entry of entries) {
          const ItemId = text(entry.itemId || entry.ItemId), SourceRoot = read(f, 'itemSourceRoot:' + ItemId), TargetRoot = read(f, 'itemTargetRoot:' + ItemId);
          if (!SourceRoot || !TargetRoot) return null;
          const AccountMappings = principalsFor(ItemId).map(principal => ({ SourceSid: text(principal.SourceSid || principal.sid || principal.SID || principal.identityId), TargetSid: read(f, 'map:' + ItemId + ':' + text(principal.SourceSid || principal.sid || principal.SID || principal.identityId)) }));
          if (AccountMappings.some(mapping => !mapping.TargetSid)) return null;
          ItemScopes.push({ ItemId, SourceRoot, TargetRoot, AccountMappings });
        }
        const SourcePeerProofHashes = readAdditionalProofs(f, sourceProofs, 'planExtraProof', SourcePeerProofHash);
        return { ManifestSelection, SourcePeerProofHash, SourcePeerProofHashes, TargetPhysicalProofHash, ItemScopes, TargetStateDirectory, AccountObservationHash: text(observation.SHA256 || observation.sha256), Owner, Evidence, MetadataPolicy };
      }, '建立非 C 搬移計畫', { description: '每個核准項目都要有明確來源／目標根目錄，且每個已觀測來源 SID 都要從目標清冊選取一個帳號。' });
    } else if (observation && ((observation.CoverageComplete !== true && observation.coverageComplete !== true) || !coverageByItem || targetIdentities.length === 0)) {
      append(parent, element('p', 'nonc-warning', '觀測涵蓋、來源身分或目標帳號清冊不完整；目前不能建立搬移計畫。'));
    }
    const result = data.result;
    if (result) append(parent, element('p', 'nonc-result-summary', '搬移結果摘要：已套用 ' + text(result.AppliedCount || result.appliedCount || 0) + ' · 衝突 ' + text(result.BlockedCount || result.blockedCount || 0) + ' · 延後 ' + text(result.DeferredCount || result.deferredCount || 0) + '。此摘要不代表所有項目完成。'));
    form(parent, '匯入目標端搬移結果', api, state, [
      { key: 'resultPlanChoice', autoUnique: true, label: '工具已核對的搬移計畫', type: 'select', options: safeArray(prep.transferChoices || prep.TransferChoices).map(row => ({ value: row.sha256 || row.SHA256, label: row.label || row.Label })) },
      { key: 'resultPath', label: '獨立收到的結果檔案位置' }, { key: 'resultHash', label: '透過獨立管道收到的結果 SHA-256' },
      { key: 'resultReferenceAck', label: '我已從結果檔案以外的可信來源核對此指紋', type: 'checkbox' }
    ], actionValue('importResult'), f => {
      const TransferPlanHash = read(f, 'resultPlanChoice'), ResultPath = read(f, 'resultPath'), ExpectedResultHash = read(f, 'resultHash');
      return TransferPlanHash && ResultPath && /^[a-fA-F0-9]{64}$/.test(ExpectedResultHash) && read(f, 'resultReferenceAck') ? { TransferPlanHash, ResultPath, ExpectedResultHash } : null;
    }, '核對並匯入搬移結果', { description: '結果會重新核對計畫、凍結證據與最終備份。衝突、延後與取消不會變成全部完成。' });
    form(parent, '將已核驗的搬移材料交給新主機', api, state, [
      { key: 'handoffTransferHash', autoUnique: true, label: '工具已核驗的搬移計畫', type: 'select', options: safeArray(prep.TransferChoices || prep.transferChoices).map(row => ({ value: row.sha256 || row.SHA256, label: row.label || row.Label })) },
      { key: 'handoffDestination', label: '新的交接資料夾' }, { key: 'handoffOperator', label: '下一位操作人' }
    ], actionValue('targetHandoffExport'), f => {
      const TransferPlanHash = read(f, 'handoffTransferHash'), ManifestHash = text((prep.Current || prep.current || {}).ManifestHash), Destination = read(f, 'handoffDestination'), NextOperator = read(f, 'handoffOperator');
      return /^[a-fA-F0-9]{64}$/.test(TransferPlanHash) && /^[a-fA-F0-9]{64}$/.test(ManifestHash) && Destination && NextOperator ? { TransferPlanHash, ManifestHash, Destination, NextOperator } : null;
    }, '匯出目標端交接材料', { description: '工具重新核對唯一且目前有效的結果。將匯出指紋透過獨立可信管道交給新主機操作人。' });
  }
  function targetView(parent, api, state, data) {
    if (!data.currentPlan || !data.hasNonC) {
      append(parent, element('p', 'nonc-not-applicable', '尚無此工作已收到且核對的非 C 搬移計畫；目前不可匯出目標端根目錄證明。'));
      return;
    }
    proofFields('Target', state, api, parent, data);
    form(parent, '預覽 Manager 已核驗的搬移材料', api, state, [
      { key: 'targetHandoffDirectory', label: '收到的交接資料夾' },
      { key: 'targetHandoffHash', label: '獨立可信管道提供的交接 manifest SHA-256' },
      { key: 'targetHandoffAck', label: '已從交接資料夾以外的可信來源核對指紋', type: 'checkbox' }
    ], actionValue('targetHandoffPreview'), f => {
      const Directory = read(f, 'targetHandoffDirectory'), ExpectedManifestHash = read(f, 'targetHandoffHash');
      return Directory && /^[a-fA-F0-9]{64}$/.test(ExpectedManifestHash) && read(f, 'targetHandoffAck') ? { Directory, ExpectedManifestHash } : null;
    }, '核對並預覽交接材料', { onResult: (result, captured) => {
      if (result && result.Status === 'Ready' && result.PreviewId) {
        const keys = ['targetHandoffDirectory', 'targetHandoffHash', 'targetHandoffAck'];
        if (!capturedValuesMatch(state, captured, keys)) {
          state.targetHandoffPreview = null;
          state.message = '欄位在預覽期間已變更，請重新預覽；目前沒有可匯入的預覽。';
          return;
        }
        state.targetHandoffPreview = { captured, PreviewId: result.PreviewId, Directory: captured.get('targetHandoffDirectory'), ExpectedManifestHash: captured.get('targetHandoffHash'), TransferPlanHash: result.TransferPlanHash, ResultHash: result.ResultHash };
      }
    } });
    if (state.targetHandoffPreview) {
      const preview = state.targetHandoffPreview;
      const previewCard = element('section', 'nonc-section');
      previewCard.dataset.noncTargetHandoffPreview = 'true';
      append(previewCard, element('p', 'nonc-callout', '已核對的搬移計畫：' + text(preview.TransferPlanHash) + '；結果：' + text(preview.ResultHash) + '。匯入只選定復原材料，之後仍需重新預覽並明確執行復原。'));
      append(previewCard, button('匯入這次已預覽的目標材料', () => submitOnce(state, api, parent, actionValue('targetHandoffImport'), { Directory: preview.Directory, ExpectedManifestHash: preview.ExpectedManifestHash, PreviewId: preview.PreviewId }, result => { if (clearSubmittedDraft(state, preview.captured, result)) state.targetHandoffPreview = null; })));
      append(parent, previewCard);
    }
    append(parent, element('p', 'nonc-callout', '非 C 暫存與證明不代表離線備份完成；請在明確審閱範圍內匯出資料。'));
  }
  function renderProofPreview(parent, state, api) {
    const old = parent.querySelector('[data-nonc-proof-preview]');
    if (old) old.remove();
    if (!state.preview) return;
    const p = section(parent, '證明交接預覽', '預覽會繫結目前核准計畫、來源／目標清冊和選取版本。');
    p.dataset.noncProofPreview = 'true';
    append(p, element('p', 'nonc-copy', '來源主機：' + text(state.preview.SourceHost || '已依目前核准核對')));
    append(p, element('p', 'nonc-copy', '目標主機：' + text(state.preview.TargetHost || '已依目前核准核對')));
    for (const share of safeArray(state.preview.Shares)) append(p, element('p', 'nonc-copy', '既有共享：' + text(share.Name || share.ShareName) + ' → ' + text(share.LocalPath)));
    for (const mapping of safeArray(state.preview.ReviewedTargetRootMappings)) append(p, element('p', 'nonc-copy', '資料目錄：' + text(mapping.LocalPath) + ' → ' + text(mapping.UNCPath) + '（共享 ' + text(mapping.ShareName) + '）'));
    if (state.preview.TargetStateShareName) append(p, element('p', 'nonc-copy', '狀態目錄使用共享：' + text(state.preview.TargetStateShareName)));
    for (const material of safeArray(state.preview.Materials)) append(p, element('p', 'nonc-copy', '證明材料：' + text(material.ShareName || material.Kind) + ' · SHA-256 ' + text(material.SHA256)));
    const roots = safeArray(state.preview.ReviewedTargetRoots);
    append(p, element('p', 'nonc-copy', '已審閱目標根目錄：' + (roots.length ? roots.join(' · ') : '此來源交接不包含目標根目錄。')));
    if (state.preview.TargetStateDirectory) append(p, element('p', 'nonc-copy', '目標工作狀態目錄：' + text(state.preview.TargetStateDirectory)));
    append(p, button('匯入已預覽的證明', () => submitOnce(state, api, parent, actionValue('proofImport'), { Directory: state.preview.Directory, ExpectedManifestHash: state.preview.ExpectedManifestHash, PreviewId: state.preview.PreviewId }, result => { if (!clearSubmittedDraft(state, state.preview.captured, result)) return; state.preview = null; const card = parent.querySelector('[data-nonc-proof-preview]'); if (card) card.remove(); })));
  }
  function showRetainedDrafts(parent, currentKey) {
    const stale = Array.from(contexts.values()).filter(state => state.dirty && state.key !== currentKey);
    if (!stale.length) return;
    const box = section(parent, '其他工作保留的非 C 草稿', '這些欄位屬於其他角色、工作或資料版本，不會套用到目前表單。請核對內容，或明確捨棄保留草稿。');
    for (const state of stale) {
      const context = state.context || {};
      const label = [context.role || '未知角色', context.pairId || '未指定工作', context.dataVersion == null ? '版本未知' : '資料版本 ' + text(context.dataVersion)].join(' · ');
      const item = element('section', 'nonc-retained-draft');
      append(item, element('h4', 'nonc-section-title', label));
      const values = element('dl', 'nonc-retained-values');
      for (const [key, value] of state.dirtyFields) {
        const caption = state.labels.get(key) || key;
        append(values, element('dt', 'nonc-retained-label', caption));
        append(values, element('dd', 'nonc-retained-value', typeof value === 'boolean' ? (value ? '是' : '否') : text(value)));
      }
      append(item, values);
      append(box, item);
    }
    append(box, button('捨棄保留草稿', () => {
      for (const state of stale) contexts.delete(state.key);
      if (active && !contexts.has(active.key)) active = null;
      if (capacityRequest) {
        const request = capacityRequest;
        capacityRequest = null;
        render(request.container, request.api);
      } else if (active) render(active.container, active.api);
      else if (detachedRequest) render(detachedRequest.container, detachedRequest.api);
    }));
  }
  function render(container, api) {
    if (!container) throw new TypeError('render(container, api) requires a container.');
    if (!api || !api.context || !api.context.role) {
      active = null;
      detachedRequest = null;
      container.replaceChildren();
      if (!hasDirty()) { container.hidden = true; return { hidden: true }; }
      const retainedRoot = element('div', 'nonc-wizard');
      showRetainedDrafts(retainedRoot, null);
      append(container, retainedRoot);
      container.hidden = false;
      return { hidden: false, retainedDrafts: true };
    }
    const data = currentData(api);
    if (!api.context.pairId || !data.hasNonC) {
      active = null;
      detachedRequest = { container, api };
      container.replaceChildren();
      if (!hasDirty()) { container.hidden = true; return { hidden: true, role: roleValue(api.context) }; }
      const inactiveRoot = element('div', 'nonc-wizard');
      inactiveRoot.dataset.contextId = text(api.context.contextId || api.context.pairId);
      inactiveRoot.style.maxWidth = '100%';
      inactiveRoot.style.width = '100%';
      inactiveRoot.style.boxSizing = 'border-box';
      append(inactiveRoot, element('h2', 'nonc-title', '非 C 資料搬移準備'));
      append(inactiveRoot, element('p', 'nonc-context', '用途：' + roleLabel(api.context) + ' · 工作：' + text(api.context.pairId || '未指定')));
      showRetainedDrafts(inactiveRoot, null);
      append(inactiveRoot, element('p', 'nonc-not-applicable', '目前沒有可操作的非 C 工作；保留草稿仍顯示於上方，且不會套用到其他工作。'));
      append(container, inactiveRoot);
      container.hidden = false;
      return { hidden: true, role: roleValue(api.context) };
    }
    const key = api.context.pairId ? contextKey(api.context) : null;
    let state = key && (contexts.get(key) || makeState(key, api.context));
    if (key && !state) {
      active = null;
      capacityRequest = { container, api };
      container.replaceChildren();
      container.hidden = false;
      const blocked = element('div', 'nonc-wizard');
      append(blocked, element('h2', 'nonc-title', '非 C 資料搬移準備'));
      append(blocked, element('p', 'nonc-warning', '已有 8 個保留中的非 C 草稿。請先檢查下方內容並明確捨棄保留草稿，才能開啟新的工作表單。'));
      showRetainedDrafts(blocked, null);
      append(container, blocked);
      return { hidden: false, capacityBlocked: true };
    }
    const focused = root.document.activeElement;
    if (key && active && active.key === key && active.container === container && state.dirty && focused && focused.dataset && focused.dataset.noncField && container.querySelector('[data-nonc-field="' + focused.dataset.noncField + '"]') === focused) {
      active.api = api;
      return { role: roleValue(api.context), itemCount: entriesOf(data).length, contextKey: key, editing: true };
    }
    active = key ? { key, state, api, container, renderId: ++renderSequence } : null;
    detachedRequest = key ? null : { container, api };
    container.replaceChildren();
    const rootNode = element('div', 'nonc-wizard');
    rootNode.dataset.contextId = text(api.context.contextId || api.context.pairId);
    rootNode.style.maxWidth = '100%';
    rootNode.style.width = '100%';
    rootNode.style.boxSizing = 'border-box';
    append(rootNode, element('h2', 'nonc-title', '非 C 資料搬移準備'));
    append(rootNode, element('p', 'nonc-context', '用途：' + roleLabel(api.context) + ' · 工作：' + text(api.context.pairId || '未指定')));
    showRetainedDrafts(rootNode, key);
    const refresh = button('重新載入目前資料', () => { if (typeof api.refresh === 'function') Promise.resolve(api.refresh()).catch(error => { state.message = '重新載入未確認：' + text(error && error.message || '未知錯誤'); renderMessage(container, state, 'nonc-warning'); }); });
    append(rootNode, refresh);
    container.hidden = false;
    if (state.message) renderMessage(rootNode, state, state.pending ? 'nonc-progress' : 'nonc-warning');
    const role = roleValue(api.context);
    if (role === 'Manager') managerView(rootNode, api, state, data);
    else if (role === 'Source' && data.currentPlan) sourceView(rootNode, api, state, data);
    else if (role === 'Target') targetView(rootNode, api, state, data);
    else if (role === 'Source') append(rootNode, element('p', 'nonc-not-applicable', '尚無此工作已收到且核對的非 C 搬移計畫；目前不可匯出來源證明或匯入搬移計畫。'));
    else append(rootNode, element('p', 'nonc-warning', '目前角色沒有非 C 搬移操作。'));
    append(container, rootNode);
    return { role, itemCount: entriesOf(data).length, contextKey: key };
  }
  function clear(container) {
    if (container && typeof container.replaceChildren === 'function') container.replaceChildren();
    contexts.clear();
    active = null;
    capacityRequest = null;
    detachedRequest = null;
  }
  function hasDirty() { return Array.from(contexts.values()).some(state => state.dirty); }

  root.WsmNonCWizard = Object.freeze({ render, clear, hasDirty, rebindReconnectDraft, clearSensitiveFields });
})(typeof window !== 'undefined' ? window : globalThis);
