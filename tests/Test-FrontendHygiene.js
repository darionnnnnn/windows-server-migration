// R26-1b（PLAN 17.131）：console.js 的前端死碼與鍵名。
//  - 頂層函式不可重複宣告（後一份會蓋掉前一份，前一份是死碼；acknowledgeWizardCoreWrite 曾有兩份且參數不同）。
//  - statusClass 以小寫字串查表（String(s).toLowerCase()），所以表內每個鍵都必須是小寫，否則永遠查不到（restoreNow 曾是 camelCase）。
//  - 後端送出的「還原選項」值是 RestoreNow（AssistiveRestore.ps1），查表時會被轉成小寫 restorenow。
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'src/ui/console.js'), 'utf8');
let checks = 0;

const names = [...source.matchAll(/^ {0,4}(?:async )?function\s+([A-Za-z0-9_$]+)\s*\(/gm)].map(match => match[1]);
const seen = new Map(); for (const name of names) seen.set(name, (seen.get(name) || 0) + 1);
const duplicated = [...seen].filter(([, count]) => count > 1).map(([name]) => name);
assert.deepEqual(duplicated, [], `top-level functions declared more than once (the earlier copy is dead code): ${duplicated.join(', ')}`); checks++;
assert.equal(seen.get('acknowledgeWizardCoreWrite'), 1, 'acknowledgeWizardCoreWrite has exactly one definition'); checks++;
// 唯一的那份必須是呼叫端實際使用的簽章（projection, request）
const definition = source.match(/async function acknowledgeWizardCoreWrite\s*\(([^)]*)\)/);
assert.ok(definition && definition[1].replace(/\s/g, '') === 'projection,request', 'the surviving definition takes (projection, request) like every caller'); checks++;
for (const call of source.matchAll(/acknowledgeWizardCoreWrite\(([^)]*)\)/g)) {
  if (call[0].startsWith('acknowledgeWizardCoreWrite(projection,request)')) continue;
  assert.ok(call[1].includes(','), `every call passes the projection and the request: ${call[0]}`); checks++;
}

const classes = source.match(/function statusClass\s*\(s\)\s*\{\s*const classes = \{([^}]*)\}/);
assert.ok(classes, 'statusClass lookup table not found'); checks++;
const keys = [...classes[1].matchAll(/([A-Za-z0-9_]+)\s*:/g)].map(match => match[1]);
assert.ok(keys.length > 40, 'the lookup table was parsed'); checks++;
const upper = keys.filter(key => key !== key.toLowerCase());
assert.deepEqual(upper, [], `statusClass keys must be lower case because the lookup lowercases its input: ${upper.join(', ')}`); checks++;
assert.ok(keys.includes('restorenow'), 'the RestoreNow backend value has its lower-case key'); checks++;
assert.equal(new Set(keys).size, keys.length, 'no duplicate statusClass keys'); checks++;
// R26-1d：基準帶 BOM 的三個檔案。psd1／psm1 一律要有（Windows PowerShell 5.1 以 BOM 判定 UTF-8）；
// console.js 的 BOM 經瀏覽器測試證實不進畫面、不影響腳本（見 Test-C2D2Browser 的 R26-1d 段），且伺服器以位元組直送、資產雜湊也是對同一份檔案的位元組算的。
const bytesOf = rel => fs.readFileSync(path.join(root, rel));
const hasBom = bytes => bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF;
for (const rel of ['src/WindowsServerMigration.psd1', 'src/WindowsServerMigration.psm1', 'src/ui/console.js']) { assert.ok(hasBom(bytesOf(rel)), `${rel} starts with the UTF-8 BOM`); checks++; }
assert.ok(!source.slice(1).includes(String.fromCharCode(0xFEFF)), 'console.js carries the BOM only once, at the very start'); checks++;
new (require('node:vm').Script)(source.replace(/^﻿/, ''), { filename: 'console.js' }); checks++;
const hostSource = fs.readFileSync(path.join(root, 'src/HtmlConsole.ps1'), 'utf8');
assert.ok(/\$bytes=\[IO\.File\]::ReadAllBytes\(\$file\)/.test(hostSource) && /\$assetHashes\['\/ui\/'\+\$asset\]=\(Get-FileHash -LiteralPath \$file/.test(hostSource), 'the console serves the file bytes and hashes the same file, so a BOM cannot split transport and hash'); checks++;
console.log(`PASS Test-FrontendHygiene checks=${checks}; no duplicated top-level function in console.js, statusClass keys are lower case, BOM present on psd1/psm1/console.js.`);
