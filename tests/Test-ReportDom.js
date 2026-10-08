// Execute the generated offline report controller against a minimal DOM.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

function getParts(path) {
  const html = fs.readFileSync(path, 'utf8');
  const controller = html.match(/<\/script><script>([\s\S]*?)<\/script>/)[1];
  const metadata = JSON.parse(html.match(/<script type="application\/json" id="metadata">([\s\S]*?)<\/script>/)[1]);
  const summary = JSON.parse(html.match(/<script type="application\/json" id="summary-data">([\s\S]*?)<\/script>/)[1]);
  const chunks = new Map([...html.matchAll(/<script type="application\/json" id="chunk-(\d+)">([\s\S]*?)<\/script>/g)].map(m => [Number(m[1]), m[2]]));
  return { html, controller, metadata, summary, chunks };
}

class Element {
  constructor() { this.children = []; this.value = ''; this._text = ''; this.onclick = null; this.oninput = null; this.onchange = null; }
  set textContent(value) { this._text = value; this.children = []; }
  get textContent() { return this._text; }
  appendChild(child) { this.children.push(child); return child; }
}

function createHarness(parts) {
  const staticIds = ['metadata','summary-data','summary-head','summary','search','category','head','body','count','prev','next','all'];
  const elements = Object.fromEntries(staticIds.map(k => [k, new Element()]));
  elements.metadata.textContent = JSON.stringify(parts.metadata);
  elements['summary-data'].textContent = JSON.stringify(parts.summary);
  const printed = { value: false }, alerts = [];
  let parseCount = 0, maxCacheSize = 0;
  const chunkElements = new Map([...parts.chunks].map(([index, text]) => { const el = new Element(); el.textContent = text; return [index, el]; }));
  class TrackingMap extends Map {
    set(key, value) { super.set(key, value); maxCacheSize = Math.max(maxCacheSize, this.size); return this; }
  }
  const json = { parse(text) { if (typeof text === 'string' && text.startsWith('[{') && text.includes('"Name"')) parseCount++; return JSON.parse(text); }, stringify: JSON.stringify };
  const document = {
    getElementById(id) { const match = /^chunk-(\d+)$/.exec(id); return match ? chunkElements.get(Number(match[1])) : elements[id]; },
    createElement() { return new Element(); }
  };
  vm.runInNewContext(parts.controller, { document, window: { print: () => { printed.value = true; }, alert: message => alerts.push(message) }, JSON: json, Map: TrackingMap, setTimeout, Promise, String, Math, Object }, { timeout: 15000 });
  return { elements, printed, alerts, get parseCount() { return parseCount; }, get maxCacheSize() { return maxCacheSize; } };
}

const waitFor = async (predicate, message) => {
  const until = Date.now() + 15000;
  while (!predicate()) {
    if (Date.now() > until) throw new Error(message);
    await new Promise(resolve => setTimeout(resolve, 0));
  }
};

async function main() {
  const small = getParts(process.argv[2]);
  const report = createHarness(small);
  const { elements } = report;
  assert.equal(elements.body.children.length, 100);
  assert.equal(report.parseCount, 1, 'initial page should parse only its first chunk');
  assert.match(elements.summary.children.map(row => row.children.map(c => c.textContent).join('|')).join('\n'), /Services\|200\|0\|0\|200\|0/);
  elements.next.onclick(); assert.equal(elements.body.children.length, 100);
  assert.equal(report.parseCount, 1, 'second page in the same chunk should use the parsed chunk cache');
  elements.next.onclick(); assert.equal(elements.body.children.length, 5);
  elements.prev.onclick(); assert.equal(elements.body.children.length, 100);
  elements.search.value = '<script>alert(1)</script>'; elements.search.oninput();
  await waitFor(() => elements.count.textContent.includes('符合 1 / 全部 205'), 'literal search did not finish');
  assert.equal(elements.body.children.length, 1);
  assert.equal(elements.body.children[0].children[1].textContent, '<script>alert(1)</script>');
  assert.doesNotMatch(small.html, /<script>alert\(1\)<\/script>/, 'hostile text must not appear as executable markup');
  elements.search.value = ''; elements.search.oninput();
  elements.category.value = 'Tasks'; elements.category.onchange();
  await waitFor(() => elements.count.textContent.includes('符合 5 / 全部 205'), 'category filter did not finish');
  assert.equal(elements.body.children.length, 5);
  elements.category.value = ''; elements.category.onchange();
  await waitFor(() => elements.count.textContent.includes('符合 205 / 全部 205'), 'clear filter did not finish');
  elements.all.onclick(); assert.equal(elements.body.children.length, 205); assert.equal(report.printed.value, true);
  console.log('PASS: 205-row paging, chunk caching, literal search, category filter, summary and bounded print.');

  const large = getParts(process.argv[3]);
  assert.equal(large.metadata.Count, 100000);
  assert.equal(large.chunks.size, 400);
  const big = createHarness(large);
  assert.equal(big.elements.body.children.length, 100);
  assert.equal(big.parseCount, 1, '100k report startup must parse only the first 250-row chunk');
  for (let page = 1; page < 5; page++) big.elements.next.onclick();
  assert.equal(big.elements.body.children.length, 100);
  assert.ok(big.parseCount > 1, 'page navigation should load later chunks on demand');
  assert.ok(big.maxCacheSize <= 4, 'parsed chunk LRU must stay within its fixed bound');

  big.elements.search.value = 'hit-'; big.elements.search.oninput();
  big.elements.search.value = 'rare-final'; big.elements.search.oninput();
  await waitFor(() => big.elements.count.textContent.includes('符合 1 / 全部 100000'), 'latest rapid filter did not win');
  assert.equal(big.elements.body.children.length, 1);
  assert.equal(big.elements.body.children[0].children[1].textContent, 'rare-final');
  big.elements.search.value = ''; big.elements.search.oninput();
  big.elements.all.onclick();
  assert.equal(big.printed.value, false, 'unfiltered 100k print must be guarded');
  assert.ok(big.alerts.length, 'large print guard should explain the limit');
  assert.ok(big.maxCacheSize <= 4, 'cache bound must hold after full scans');
  console.log('PASS: 100k startup lazy parsing, 250-row chunks, bounded LRU, interruptible race-safe filtering and print guard.');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
