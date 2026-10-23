// Real-browser (Edge, file://) test for the offline new-machine guide (16.3-1): zero console errors,
// no network, no overflow at 390px, semantic headings, text contrast >= 4.5:1, reduced motion, hostile strings stay text.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const screens = path.join(root, 'work', 'r7', 'screens');
fs.mkdirSync(screens, { recursive: true });
const fileUrl = file => 'file:///' + file.replace(/\\/g, '/');

function buildFixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-guide-fixture-'));
  const run = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', path.join(root, 'tests', 'Test-OfflineGuide.ps1'), '-FixtureDir', dir], { encoding: 'utf8' });
  assert.equal(run.status, 0, 'guide fixture build failed: ' + run.stdout + run.stderr);
  return dir;
}

// WCAG contrast of every text-bearing element against its effective (opaque) background.
const contrastProbe = () => {
  const parse = value => { const m = value.match(/rgba?\(([^)]+)\)/); const p = m[1].split(',').map(s => parseFloat(s)); return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 }; };
  const lum = c => { const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b); };
  const background = el => { for (let n = el; n; n = n.parentElement) { const c = parse(getComputedStyle(n).backgroundColor); if (c.a > 0) return c; } return { r: 255, g: 255, b: 255, a: 1 }; };
  const worst = []; let min = 21;
  for (const el of document.querySelectorAll('h1,h2,p,li,dt,dd,code,a,pre,strong')) {
    if (![...el.childNodes].some(n => n.nodeType === 3 && n.textContent.trim())) continue;
    const fg = parse(getComputedStyle(el).color), bg = background(el);
    const l1 = lum(fg), l2 = lum(bg), ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    if (ratio < min) min = ratio;
    if (ratio < 4.5) worst.push(el.tagName + ':' + ratio.toFixed(2));
  }
  return { min, worst };
};

(async () => {
  const dir = buildFixture();
  const browser = await chromium.launch({ headless: true, executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe' });
  const problems = [];
  try {
    for (const variant of ['normal', 'zip', 'hostile', 'empty']) {
      for (const width of [1280, 390]) {
        const context = await browser.newContext({ viewport: { width, height: 900 } });
        await context.addInitScript(() => { window.__xss = 0; window.alert = () => { window.__xss++; }; });
        const page = await context.newPage();
        const consoleErrors = [], requests = [];
        page.on('console', m => { if (m.type() === 'error' || m.type() === 'warning') consoleErrors.push(m.type() + ': ' + m.text()); });
        page.on('pageerror', e => consoleErrors.push('pageerror: ' + e.message));
        page.on('requestfailed', r => consoleErrors.push('requestfailed: ' + r.url()));
        page.on('request', r => requests.push(r.url()));
        await page.goto(fileUrl(path.join(dir, variant, 'offline-guide.html')));
        await page.waitForLoadState('load');
        const label = variant + '@' + width;

        assert.deepEqual(consoleErrors, [], label + ': console errors/warnings');
        assert.ok(requests.every(u => u.startsWith('file:') || u.startsWith('data:')), label + ': the guide must not touch the network: ' + requests.join(','));
        assert.equal(await page.evaluate(() => window.__xss), 0, label + ': injected markup executed');
        assert.equal(await page.evaluate(() => document.querySelectorAll('script,img,iframe,link,svg,form,input,button').length), 0, label + ': static document must have no active or external elements');

        // Semantic structure: one h1, h2 sections each labelled by its heading, headings in order.
        const structure = await page.evaluate(() => ({
          h1: document.querySelectorAll('h1').length,
          h2: [...document.querySelectorAll('section > h2')].map(h => h.id),
          labelled: [...document.querySelectorAll('section[aria-labelledby]')].map(s => s.getAttribute('aria-labelledby')),
          main: document.querySelectorAll('main').length,
          lang: document.documentElement.lang,
          title: document.title
        }));
        assert.equal(structure.h1, 1, label + ': exactly one h1');
        assert.equal(structure.main, 1, label + ': one main landmark');
        assert.ok(structure.h2.length >= 6, label + ': at least six sections');
        assert.deepEqual(structure.labelled, structure.h2, label + ': every section is labelled by its own h2');
        assert.equal(structure.lang, 'zh-Hant');
        assert.ok(structure.title.length > 0);

        // No horizontal overflow (page and every element), including 390px with long hashes.
        const overflow = await page.evaluate(() => {
          const wide = [...document.querySelectorAll('body *')].filter(e => e.getBoundingClientRect().right > document.documentElement.clientWidth + 1).map(e => e.tagName + '.' + e.className);
          return { doc: document.documentElement.scrollWidth - document.documentElement.clientWidth, wide };
        });
        assert.ok(overflow.doc <= 0, label + ': page overflows horizontally by ' + overflow.doc);
        assert.deepEqual(overflow.wide, [], label + ': elements wider than the viewport');

        // Fonts, contrast and reduced motion.
        const fonts = await page.evaluate(() => getComputedStyle(document.body).fontFamily);
        assert.ok(/system-ui/.test(fonts) && /Noto Sans TC/.test(fonts) && /Microsoft JhengHei/.test(fonts), label + ': font stack ' + fonts);
        const contrast = await page.evaluate(contrastProbe);
        assert.deepEqual(contrast.worst, [], label + ': text contrast below 4.5:1 (min ' + contrast.min + ')');
        await page.emulateMedia({ reducedMotion: 'reduce' });
        const motion = await page.evaluate(() => matchMedia('(prefers-reduced-motion: reduce)').matches);
        assert.ok(motion, label + ': reduced-motion media query must match when emulated');
        const animated = await page.evaluate(() => [...document.querySelectorAll('*')].filter(e => { const s = getComputedStyle(e); return (s.animationName !== 'none') || (parseFloat(s.transitionDuration) > 0); }).length);
        assert.equal(animated, 0, label + ': no animation or transition under reduced motion');

        // Content by variant.
        const text = await page.evaluate(() => document.body.innerText);
        assert.ok(text.includes('不代表媒體目前仍完整'), label + ': warning text');
        if (variant === 'hostile') {
          assert.ok(text.includes('中文 空白 配對'), label + ': Chinese/space text preserved');
          assert.ok(text.includes('<script>alert('), label + ': injected markup must be shown as text');
          assert.ok(text.includes('未記錄'), label + ': malformed hashes shown as not recorded');
        }
        if (variant === 'normal') {
          assert.ok(text.includes('ab12'.repeat(16)), label + ': manifest hash shown');
          assert.equal(await page.evaluate(() => document.querySelectorAll('a[href="backup-report.html"]').length), 1, label + ': report link beside the guide');
        }
        if (variant === 'zip') assert.equal(await page.evaluate(() => document.querySelectorAll('a').length), 0, label + ': no dangling link');
        if (width === 390) await page.screenshot({ path: path.join(screens, 'n6-guide-' + variant + '-390.png'), fullPage: true });
        if (width === 1280 && variant === 'normal') await page.screenshot({ path: path.join(screens, 'n6-guide-normal-1280.png'), fullPage: true });
        await context.close();
      }
    }
  } finally {
    await browser.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
  console.log('PASS: offline guide in real Edge via file:// (4 variants x 2 widths): zero console errors, no network, no overflow at 390px, semantic headings, contrast >= 4.5:1, reduced motion, hostile strings stay text.');
})().catch(e => { console.error(e); process.exit(1); });
