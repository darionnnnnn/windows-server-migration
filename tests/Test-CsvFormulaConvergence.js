// R26-1a（PLAN 17.131）：CSV 公式前綴只有一份規則。
// PS 端 ConvertTo-WsmCsvSafe（src/Review.ps1）是唯一實作，Reports／EnvironmentConfirmation 的欄位函式都呼叫它；
// JS 端兩份（console.js 的 csvCellText、離線報告內嵌腳本的 csvCell）無法共用程式碼，改以「同一組測試值、三邊結果必須相同」釘住。
// 另有靜態守門：src 內不得再出現自寫的公式前綴 regex。
const assert = require('node:assert/strict'), fs = require('node:fs'), os = require('node:os'), path = require('node:path'), vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');

// 公式前綴：前導空白（含 NBSP、NEL、BOM 這類 JS 與 .NET 的 \s 各自多出的字元）後接 = + - @，或開頭是 Tab／CR／LF。
const vectors = [
  '', 'plain', 'a=1', 'a-b', 'x@y', ' leading space then text', '1+1',
  '=1+1', '+1', '-1', '@SUM(A1)', '=HYPERLINK("http://x","y")',
  ' =1', '   +1', '  -1', '  @x',
  '\t=1', '\tabc', '\r=1', '\rabc', '\n=1', '\nabc', ' \n=1', ' \t abc', 'abc\n=1', 'abc\t=1', 'abc\r\n+1',
  ' =1', '\u0085=1', '﻿=1', '　@x', ' -1',
  "'=1", "'plain", 'say "hi"', '"=1"', '=1,2', '中文=1', '=中文', ' 中文'
];

function loadJsCell(relPath, startRegex, endRegex) {
  const text = read(relPath), start = text.search(startRegex);
  assert.ok(start >= 0, `${relPath}: csv cell function not found`);
  const rest = text.slice(start), end = rest.search(endRegex);
  assert.ok(end > 0, `${relPath}: csv cell function end not found`);
  const source = rest.slice(0, end);
  const sandbox = {}; vm.createContext(sandbox); vm.runInContext(source, sandbox);
  return sandbox;
}
const consoleCell = loadJsCell('src/ui/console.js', /function csvCellText\s*\(/, /\r?\n\s*function downloadCsv/).csvCellText;
const offlineCell = loadJsCell('src/WizardBackupProjection.ps1', /function csvCell\s*\(/, /\r?\nfunction downloadCsv/).csvCell;
assert.equal(typeof consoleCell, 'function'); assert.equal(typeof offlineCell, 'function');

// PS 端：同一組測試值走 ConvertTo-WsmCsvSafe 與兩個欄位函式。向量以 base64(JSON) 傳入，避免命令列轉義。
const fw = p => p.split(path.sep).join('/');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'r261-csv-'));
try {
  const vectorFile = path.join(dir, 'vectors.json'), outFile = path.join(dir, 'out.json'), script = path.join(dir, 'run.ps1');
  fs.writeFileSync(vectorFile, JSON.stringify(vectors), 'utf8');
  fs.writeFileSync(script, `
$ErrorActionPreference='Stop'
$module=Import-Module '${fw(path.join(root, 'src', 'WindowsServerMigration.psd1'))}' -Force -PassThru
$values=[object[]](ConvertFrom-Json -InputObject (Get-Content -LiteralPath '${fw(vectorFile)}' -Raw -Encoding UTF8))
$result=& $module {
  param($values)
  $rows=@()
  foreach($v in $values){
    $safe=ConvertTo-WsmCsvSafe $v
    $cell='"'+$safe.Replace('"','""')+'"'
    $rows+=[pscustomobject]@{Value=$v;Safe=$safe;Cell=$cell;Report=(ConvertTo-WsmReportCsvValue $v);Confirmation=(ConvertTo-WsmConfirmationCsvField $v);RoundTrip=((ConvertFrom-WsmCsvSafe (ConvertTo-WsmCsvSafe $v -ProtectQuote)) -ceq [string]$v)}
  }
  $rows
} $values
[IO.File]::WriteAllText('${fw(outFile)}',(ConvertTo-Json -InputObject @($result) -Depth 4),(New-Object Text.UTF8Encoding($false)))
`, 'utf8');
  const run = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script], { encoding: 'utf8', timeout: 240000 });
  assert.equal(run.status, 0, `PowerShell side failed: ${run.stdout}\n${run.stderr}`);
  const rows = JSON.parse(fs.readFileSync(outFile, 'utf8').replace(/^﻿/, ''));
  assert.equal(rows.length, vectors.length, 'one PowerShell row per vector');
  let checks = 0;
  rows.forEach((row, i) => {
    const v = vectors[i], label = JSON.stringify(v);
    assert.equal(row.Value, v, `vector ${label} survived the transfer`);
    assert.equal(consoleCell(v), row.Cell, `console.js cell differs from PowerShell for ${label}`); checks++;
    assert.equal(offlineCell(v), row.Cell, `offline report cell differs from PowerShell for ${label}`); checks++;
    assert.equal(row.Report, row.Cell, `ConvertTo-WsmReportCsvValue differs for ${label}`); checks++;
    assert.equal(row.Confirmation, row.Cell, `ConvertTo-WsmConfirmationCsvField differs for ${label}`); checks++;
    assert.equal(row.RoundTrip, true, `decision CSV round trip lost ${label}`); checks++;
  });
  // 期望值（不只是三邊一致，規則本身要對）
  const expectEscaped = new Set(['=1+1', '+1', '-1', '@SUM(A1)', '=HYPERLINK("http://x","y")', ' =1', '   +1', '  -1', '  @x', '\t=1', '\tabc', '\r=1', '\rabc', '\n=1', '\nabc', ' \n=1', ' =1', '\u0085=1', '﻿=1', '　@x', ' -1', '=1,2', '=中文']);
  const expectPlain = ['', 'plain', 'a=1', 'a-b', 'x@y', ' leading space then text', '1+1', ' \t abc', 'abc\n=1', 'abc\t=1', 'abc\r\n+1', '中文=1', ' 中文'];
  for (const v of vectors) {
    const cell = consoleCell(v), body = cell.slice(1, -1).replace(/""/g, '"');
    if (expectEscaped.has(v)) { assert.equal(body, "'" + v, `formula-like value must be prefixed: ${JSON.stringify(v)}`); checks++; }
  }
  for (const v of expectPlain) { assert.equal(consoleCell(v).slice(1, -1).replace(/""/g, '"'), v, `harmless value must stay unchanged: ${JSON.stringify(v)}`); checks++; }
  // 往返性質：任意字串經匯出再匯入都要回到原值（含開頭就是單引號的值）
  const alphabet = ["'", '=', '+', '-', '@', ' ', '\t', '\r', '\n', 'a', '1', '"', ' '];
  const rnd = (() => { let s = 12345; return () => (s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff; })();
  const props = Array.from({ length: 200 }, () => Array.from({ length: Math.floor(rnd() * 6) }, () => alphabet[Math.floor(rnd() * alphabet.length)]).join(''));
  fs.writeFileSync(vectorFile, JSON.stringify(props), 'utf8');
  const run2 = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', `
$module=Import-Module '${fw(path.join(root, 'src', 'WindowsServerMigration.psd1'))}' -Force -PassThru
$values=[object[]](ConvertFrom-Json -InputObject (Get-Content -LiteralPath '${fw(vectorFile)}' -Raw -Encoding UTF8))
$bad=& $module { param($values) @(foreach($v in $values){ if((ConvertFrom-WsmCsvSafe (ConvertTo-WsmCsvSafe $v -ProtectQuote)) -cne [string]$v){ConvertTo-Json -Compress $v} }) } $values
if($bad.Count){ 'ROUNDTRIP-BAD '+($bad -join ';'); exit 5 }
'ROUNDTRIP-OK'`], { encoding: 'utf8', timeout: 240000 });
  assert.equal(run2.status, 0, `round-trip property failed: ${run2.stdout}${run2.stderr}`); checks++;

  // 靜態守門：除了唯一實作，src 不得自寫公式前綴 regex。
  const offenders = [];
  for (const file of fs.readdirSync(path.join(root, 'src')).filter(f => f.endsWith('.ps1'))) {
    const text = read('src/' + file);
    text.split(/\r?\n/).forEach((line, n) => {
      if (line.includes('[=+') && !/function Test-WsmCsvFormulaText/.test(line)) offenders.push(`${file}:${n + 1}`);
    });
  }
  const allowedOffline = offenders.filter(o => o.startsWith('WizardBackupProjection.ps1:'));
  const others = offenders.filter(o => !o.startsWith('WizardBackupProjection.ps1:'));
  assert.deepEqual(others, [], `hand-written CSV formula regex outside the shared function: ${others.join(', ')}`); checks++;
  assert.ok(allowedOffline.length <= 1, `only the embedded offline-report script may carry the JS copy: ${allowedOffline.join(', ')}`); checks++;
  console.log(`PASS Test-CsvFormulaConvergence checks=${checks}; ${vectors.length} vectors identical across PowerShell, console.js and the offline report script.`);
} finally { fs.rmSync(dir, { recursive: true, force: true }); }
