// Execute our generated report controller against a minimal DOM, not server data.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync(process.argv[2], 'utf8');
const data = html.match(/<script type="application\/json" id="data">([\s\S]*?)<\/script>/)[1];
const controller = html.match(/<\/script><script>([\s\S]*?)<\/script>/)[1];
class Element {
  constructor() { this.children = []; this.value = ''; this._text = ''; }
  set textContent(value) { this._text = value; this.children = []; }
  get textContent() { return this._text; }
  appendChild(child) { this.children.push(child); }
}
const elements = Object.fromEntries(['data','search','category','head','body','count','prev','next','all'].map(k => [k,new Element()]));
elements.data.textContent = data;
let printed = false;
vm.runInNewContext(controller, { document: { getElementById: id => elements[id], createElement: () => new Element() }, window: { print: () => { printed = true; } } }, { timeout: 5000 });
assert.equal(elements.body.children.length, 100);
elements.next.onclick(); assert.equal(elements.body.children.length, 100);
elements.next.onclick(); assert.equal(elements.body.children.length, 5);
elements.prev.onclick(); assert.equal(elements.body.children.length, 100);
elements.search.value = '<script>alert(1)</script>'; elements.search.oninput();
assert.equal(elements.body.children.length, 1);
assert.equal(elements.body.children[0].children[1].textContent, '<script>alert(1)</script>');
elements.search.value = ''; elements.search.oninput();
elements.category.value = 'Tasks'; elements.category.onchange();
assert.equal(elements.body.children.length, 5);
elements.category.value = ''; elements.category.onchange(); elements.all.onclick();
assert.equal(elements.body.children.length, 205); assert.equal(printed,true);
console.log('PASS: report paging, literal search, category filter and complete print DOM checks.');
const largeElements = Object.fromEntries(Object.keys(elements).map(k => [k,new Element()]));
const sample = JSON.parse(data)[0];
largeElements.data.textContent = JSON.stringify(Array.from({length:2001},(_,n) => ({...sample,Name:`large-${n}`})));
let largePrinted=false, alerted=false;
vm.runInNewContext(controller, { document: { getElementById: id => largeElements[id], createElement: () => new Element() }, window: { print: () => { largePrinted=true; }, alert: () => { alerted=true; } } }, {timeout:5000});
largeElements.all.onclick();
assert.equal(largeElements.body.children.length,100); assert.equal(largePrinted,false); assert.equal(alerted,true);
console.log('PASS: large report print guard keeps bounded DOM and directs to complete text report.');
