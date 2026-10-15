const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(path.join(process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules', 'playwright'));
const root = path.resolve(__dirname, '..');
const output = process.env.WSM_LAYOUT_OUTPUT || path.join(root, 'work', 'nonc-layout-' + Date.now());
fs.mkdirSync(output, { recursive: true });
(async () => {
  const browser = await chromium.launch({ channel: 'msedge', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.setContent('<!doctype html><html lang="zh-Hant"><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><main><section id="widget"></section></main></body></html>');
    await page.addStyleTag({ path: path.join(root, 'src/ui/console.css') });
    await page.addScriptTag({ path: path.join(root, 'src/ui/nonc.js') });
    const metrics = [];
    for (const role of ['Source', 'Manager', 'Target']) {
      await page.evaluate(role => {
        const hash = 'a'.repeat(64), longPath = 'D:\\核准的業務資料\\' + '很長的中文路徑與英文資料夾_name_'.repeat(8);
        window.fixtureApi = {
          context: { role, pairId: 'layout-pair', workspace: 'C:\\工作資料夾', contextId: role, dataVersion: 1 },
          projection: { HasNonC: true, CurrentPlan: { hash }, ProofAllowed: true, Preparation: { Status: 'NeedsHumanEvidence', Entries: [{ ItemId: 'item-1', Name: longPath, Channel: 'NonC' }], MaterialChoices: [{ value: hash, label: longPath }], ProofOptions: [{ kind: 'SourcePeerShareProof', sha256: hash, label: longPath }] } },
          submissions: [], refreshes: 0,
          submit(action, args) { this.submissions.push({ action, args }); return Promise.resolve({ Status: 'Exported' }); },
          refresh() { this.refreshes++; return Promise.resolve(); }, markDirty() {}
        };
        window.WsmNonCWizard.clear(document.getElementById('widget'));
        window.WsmNonCWizard.render(document.getElementById('widget'), window.fixtureApi);
      }, role);
      for (const width of [320, 768, 1280, 1920]) {
        await page.setViewportSize({ width, height: 900 });
        const result = await page.evaluate(() => ({
          overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
          controls: Array.from(document.querySelectorAll('.nonc-button,.nonc-control:not([type=checkbox])')).map(node => ({ height: node.getBoundingClientRect().height, font: parseFloat(getComputedStyle(node).fontSize) })),
          gaps: Array.from(document.querySelectorAll('.nonc-form')).map(node => parseFloat(getComputedStyle(node).rowGap))
        }));
        assert.equal(result.overflow, false, role + ' page overflow at ' + width);
        assert.ok(result.controls.length > 0);
        assert.ok(result.controls.every(control => control.height >= 48 && control.font >= 18), role + ' control size/font');
        assert.ok(result.gaps.every(gap => gap >= 12), role + ' form gaps');
        metrics.push({ role, width, ...result });
        if ([320, 1280].includes(width)) await page.screenshot({ path: path.join(output, role + '-' + width + '.png'), fullPage: true });
      }
      await page.setViewportSize({ width: 1280, height: 900 });
      const contrast = await page.evaluate(() => {
        const lum = color => color.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => { const c = v / 255; return c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4; }).reduce((sum, value, i) => sum + value * [.2126, .7152, .0722][i], 0);
        const ratio = (a, b) => (Math.max(lum(a), lum(b)) + .05) / (Math.min(lum(a), lum(b)) + .05);
        const background = node => { for (let p = node; p; p = p.parentElement) { const c = getComputedStyle(p).backgroundColor; if (c !== 'rgba(0, 0, 0, 0)') return c; } return 'rgb(255, 255, 255)'; };
        const text = Array.from(document.querySelectorAll('.nonc-copy,.nonc-callout,.nonc-progress,.nonc-warning,.nonc-control,.nonc-button,.nonc-field-label')).filter(node => node.getClientRects().length && !node.disabled).map(node => ratio(getComputedStyle(node).color, background(node)));
        const borders = Array.from(document.querySelectorAll('.nonc-control:not([type=checkbox]),.nonc-button')).filter(node => !node.disabled).map(node => ratio(getComputedStyle(node).borderTopColor, background(node)));
        return { minimumText: Math.min(...text), minimumControlBoundary: Math.min(...borders) };
      });
      assert.ok(contrast.minimumText >= 4.5, role + ' readable text contrast: ' + JSON.stringify(contrast));
      assert.ok(contrast.minimumControlBoundary >= 3, role + ' control boundary contrast: ' + JSON.stringify(contrast));
      metrics.push({ role, contrast });
      await page.locator('.nonc-button').first().focus();
      const focus = await page.evaluate(() => ({ style: getComputedStyle(document.activeElement).outlineStyle, width: parseFloat(getComputedStyle(document.activeElement).outlineWidth) }));
      assert.ok(focus.style !== 'none' && focus.width >= 2, 'visible keyboard focus');
      await page.keyboard.press('Space');
      assert.equal(await page.evaluate(() => window.fixtureApi.refreshes), 1, 'Space activates refresh');
      await page.keyboard.press('Tab');
      const fieldKey = await page.evaluate(() => document.activeElement.dataset.noncField);
      assert.ok(fieldKey, 'Tab reaches a labeled field');
      if (role === 'Source') {
        await page.keyboard.type('ReviewedShare');
        assert.equal(await page.evaluate(() => {
          const field = document.activeElement;
          window.WsmNonCWizard.render(document.getElementById('widget'), window.fixtureApi);
          return document.activeElement === field && field.value === 'ReviewedShare';
        }), true, 'same-context progress rendering preserves focus and editing node');
      }
      await page.keyboard.press('Shift+Tab');
      assert.equal(await page.evaluate(() => document.activeElement.classList.contains('nonc-button')), true, 'Shift+Tab returns without a trap');
      await page.keyboard.press('Enter');
      assert.equal(await page.evaluate(() => window.fixtureApi.refreshes), 2, 'Enter activates refresh');
    }
    fs.writeFileSync(path.join(output, 'layout-results.json'), JSON.stringify({ browser: 'Edge', viewportMetrics: metrics, boundary: 'Real widget/CSS and keyboard; API data fixture only; no native HTTP or browser-zoom claim.' }, null, 2));
    console.log('PASS real Edge NonC layout/keyboard/edit-focus at 320/768/1280/1920; fixtures only, separate from native HTTP and real browser zoom: ' + output);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
