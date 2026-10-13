const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const runtime = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = require(path.join(runtime, 'playwright'));
const root = path.resolve(__dirname, '..');
const screenshotDir = path.join(root, 'work', 'wizard-layout');
fs.mkdirSync(screenshotDir, { recursive: true });
const files = new Map([
  ['/', path.join(root, 'src/ui/index.html')],
  ['/ui/console.js', path.join(root, 'src/ui/console.js')],
  ['/ui/console.css', path.join(root, 'src/ui/console.css')]
]);
const server = http.createServer((request, response) => {
  const file = files.get(new URL(request.url, 'http://127.0.0.1').pathname);
  if (!file) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { 'Content-Type': file.endsWith('.js') ? 'application/javascript; charset=utf-8' : file.endsWith('.css') ? 'text/css; charset=utf-8' : 'text/html; charset=utf-8' });
  fs.createReadStream(file).pipe(response);
});

(async () => {
  let browser;
  try {
    await new Promise((resolve, reject) => server.listen(0, '127.0.0.1', resolve).once('error', reject));
    browser = await chromium.launch({
      headless: true,
      executablePath: process.env.WSM_EDGE || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
    });
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 }, javaScriptEnabled: true });
    const page = await context.newPage();
    page.route('**/api/**', route => {
      const url = new URL(route.request().url()), method = route.request().method();
      const data = url.pathname === '/api/session' ? { token:'layout-token',sessionId:'layout-session',contextId:'layout-context',hostName:'桌面測試主機',role:'Source',workspace:'C:\\migration\\layout-fixture',pairId:'',revision:1,decisionRevision:0,selectionRevision:0,dataVersion:1,principal:'fixture' } :
        url.pathname === '/api/context' ? { roles:['Source','Manager','Target'],pairs:[],role:'Source',pairId:'',contextId:'layout-context',revision:1,decisionRevision:0,selectionRevision:0,dataVersion:1 } :
        url.pathname === '/api/wizard' && method === 'GET' ? { kind:'WizardProjection',intentRequired:true,role:null,roleChoices:[{role:'Source',label:'舊主機',description:'盤點並交接搬移資料。'},{role:'Target',label:'新主機',description:'檢查並接收已核准的搬移資料。'},{role:'Manager',label:'整理搬移資料的電腦',description:'建立工作並審閱搬移範圍。'}],actions:[{action:'ChooseIntent',available:true}],state:null,revision:0,currentStep:'start',groups:[],gates:[],missingFields:[],context:null } : { items:[] };
      return route.fulfill({ status:200,contentType:'application/json',body:JSON.stringify(data) });
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/`, { waitUntil: 'networkidle' });
    await page.waitForFunction(() => window.WsmConsole && window.WsmConsole.state.wizard);
    assert.equal(await page.locator('#view-wizard').isVisible(), true, 'wizard should be the initial visible view');
    assert.equal(await page.locator('#view-overview').isVisible(), false, 'advanced overview should start hidden');
    assert.equal(await page.locator('#navigation a').first().getAttribute('data-view'), 'wizard');
    assert.equal(await page.locator('#navigation-inventory').isHidden(), true);
    assert.equal(await page.locator('#navigation-backup-results').isHidden(), true);
    assert.equal(await page.locator('#navigation-restore-results').isHidden(), true);
    assert.equal(await page.locator('#developer-probe-button').innerText(), '開發者環境探測');
    assert.equal(await page.locator('#wizard-content').count(), 1);
    assert.equal(await page.locator('#wizard-title').count(), 1);
    assert.equal(await page.locator('#wizard-step-label').count(), 1);
    assert.equal(await page.locator('#wizard-back').count(), 1);
    assert.equal(await page.locator('#wizard-next').count(), 1);
    assert.equal(await page.locator('input[name="wizard-role"]').count(), 3, 'the first-use purpose choice should be real, labelled content');
    assert.equal(await page.locator('.context-advanced').evaluate(node => node.open), false, 'workspace role/pair selectors should stay collapsed during normal onboarding');
    await page.keyboard.press('Tab');
    const focus = await page.evaluate(() => ({
      id: document.activeElement.id,
      outline: getComputedStyle(document.activeElement).outlineStyle
    }));
    assert.equal(focus.id, '');
    assert.equal(focus.outline, 'solid', 'keyboard focus should have a visible outline');

    await page.locator('#wizard-content').evaluate(node => { node.textContent = `Long identifier: ${'C:\\migration\\'.repeat(80)}`; });
    for (const width of [320, 640, 768]) {
      await page.setViewportSize({ width, height: 900 });
      const hasOverflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
      assert.equal(hasOverflow, false, `long paths should wrap without page overflow at ${width}px`);
    }
    await page.evaluate(() => window.WsmConsole.renderWizard(window.WsmConsole.state.wizard));

    for (const width of [320, 640, 768, 1280, 1920]) {
      await page.setViewportSize({ width, height: 900 });
      const metrics = await page.evaluate(() => ({
        viewport: document.documentElement.clientWidth,
        document: document.documentElement.scrollWidth,
        bodyFont: parseFloat(getComputedStyle(document.body).fontSize),
        primaryHeight: document.querySelector('#wizard-content .primary-button').getBoundingClientRect().height
      }));
      assert.ok(metrics.document <= metrics.viewport, `page overflow at ${width}px: ${JSON.stringify(metrics)}`);
      assert.equal(metrics.bodyFont, 18, `body text should be 18px at ${width}px`);
      assert.ok(metrics.primaryHeight >= 48, `primary control should be at least 48px at ${width}px`);
    }

    const contrast = await page.locator('#wizard-next').evaluate(button => {
      const toRgb = color => color.match(/\d+/g).slice(0, 3).map(Number);
      const luminance = color => toRgb(color).map(value => {
        const channel = value / 255;
        return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
      }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
      const foreground = luminance(getComputedStyle(button).color);
      const background = luminance(getComputedStyle(button).backgroundColor);
      return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
    });
    assert.ok(contrast >= 4.5, `primary button text contrast should be at least 4.5:1 (got ${contrast.toFixed(2)}:1)`);

    const textMetrics = await page.evaluate(() => {
      const ratio = (foreground, background) => {
        const rgb = value => value.match(/[\d.]+/g).slice(0, 3).map(Number);
        const lum = color => rgb(color).map(value => { const c=value/255; return c<=0.04045?c/12.92:((c+0.055)/1.055)**2.4; }).reduce((sum,value,index)=>sum+value*[0.2126,0.7152,0.0722][index],0);
        const a=lum(foreground),b=lum(background); return (Math.max(a,b)+0.05)/(Math.min(a,b)+0.05);
      };
      const metrics = selector => { const node=document.querySelector(selector); if(!node) throw new Error(`missing ${selector}`); const style=getComputedStyle(node); let background=style.backgroundColor, parent=node.parentElement; while(background==='rgba(0, 0, 0, 0)'&&parent){background=getComputedStyle(parent).backgroundColor;parent=parent.parentElement;} return {font:parseFloat(style.fontSize),contrast:ratio(style.color,background)}; };
      return {choice:metrics('.wizard-choice-copy strong'),choiceDescription:metrics('.wizard-choice-copy span'),lede:metrics('#wizard-title + .lede'),button:metrics('#wizard-next'),focus:metrics('.wizard-choice')};
    });
    for (const [name, value] of Object.entries(textMetrics)) {
      assert.ok(value.font >= 18, `${name} should be at least 18px: ${JSON.stringify(value)}`);
      if (name !== 'focus') assert.ok(value.contrast >= 4.5, `${name} text contrast should be at least 4.5:1: ${JSON.stringify(value)}`);
    }
    const controlBoundary = await page.locator('.wizard-choice').first().evaluate(node => {
      const color=getComputedStyle(node).borderTopColor, rgb=value=>value.match(/[\d.]+/g).slice(0,3).map(Number), lum=value=>rgb(value).map(v=>{const c=v/255;return c<=0.04045?c/12.92:((c+0.055)/1.055)**2.4;}).reduce((s,v,i)=>s+v*[0.2126,0.7152,0.0722][i],0), a=lum(color), b=lum('rgb(255,255,255)');
      return {ratio:(Math.max(a,b)+0.05)/(Math.min(a,b)+0.05),minHeight:node.getBoundingClientRect().height};
    });
    assert.ok(controlBoundary.ratio >= 3, `choice boundary contrast should be at least 3:1: ${JSON.stringify(controlBoundary)}`);
    assert.ok(controlBoundary.minHeight >= 48, `choice should provide a 48px touch target: ${JSON.stringify(controlBoundary)}`);
    const choiceGap = await page.locator('.wizard-choice-list').evaluate(node=>parseFloat(getComputedStyle(node).rowGap));
    assert.ok(choiceGap >= 12, `choice rows should have at least 12px separation (got ${choiceGap}px)`);

    await page.evaluate(() => window.WsmConsole.navigate('help'));
    const help = await page.locator('.help-list li').first().evaluate(node => ({font:parseFloat(getComputedStyle(node).fontSize),text:node.innerText,color:getComputedStyle(node).color,background:getComputedStyle(node).backgroundColor}));
    assert.ok(help.font >= 18, `help text should be at least 18px: ${JSON.stringify(help)}`);
    const helpHeadingFont = await page.locator('#help-title').evaluate(node=>parseFloat(getComputedStyle(node).fontSize));
    assert.ok(helpHeadingFont >= 18, `help heading should be at least 18px (got ${helpHeadingFont}px)`);
    const helpContrast = await page.locator('.help-list li').first().evaluate(node => {
      const rgb=value=>value.match(/[\d.]+/g).slice(0,3).map(Number),lum=value=>rgb(value).map(v=>{const c=v/255;return c<=0.04045?c/12.92:((c+0.055)/1.055)**2.4;}).reduce((s,v,i)=>s+v*[0.2126,0.7152,0.0722][i],0);
      let bg=getComputedStyle(node).backgroundColor,parent=node.parentElement;while(bg==='rgba(0, 0, 0, 0)'&&parent){bg=getComputedStyle(parent).backgroundColor;parent=parent.parentElement;}
      const a=lum(getComputedStyle(node).color),b=lum(bg);return (Math.max(a,b)+0.05)/(Math.min(a,b)+0.05);
    });
    assert.ok(helpContrast >= 4.5, `help text contrast should be at least 4.5:1 (got ${helpContrast.toFixed(2)}:1)`);
    await page.evaluate(() => window.WsmConsole.navigate('wizard'));

    await page.evaluate(() => document.activeElement.blur());
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.screenshot({ path: path.join(screenshotDir, 'wizard-layout-desktop.png'), fullPage: true });
    // A 640 CSS-pixel viewport represents a 1280px desktop viewed at 200% browser zoom.
    await page.setViewportSize({ width: 640, height: 900 });
    await page.screenshot({ path: path.join(screenshotDir, 'wizard-layout-desktop-200-percent.png'), fullPage: true });
    await page.setViewportSize({ width: 320, height: 900 });
    await page.screenshot({ path: path.join(screenshotDir, 'wizard-layout-mobile.png'), fullPage: true });
    console.log('Wizard layout checks passed at 320, 640, 768, 1280, and 1920 CSS px. Screenshots saved under work/.');
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
