const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const runtime = process.env.WSM_NODE_MODULES;
const { chromium } = require(path.join(runtime, 'playwright'));
const modulePath = process.env.WSM_HTML_TEST_MODULE;
assert.ok(modulePath, 'An exact extracted release module is required.');
const installRoot = path.resolve(path.dirname(modulePath), '..');
assert.match(path.basename(installRoot), /Chinese spaces/);
const workspace = path.join(installRoot, 'migration-workspace');
assert.ok(!fs.existsSync(workspace), 'The actual default launcher must start with a fresh owned workspace.');
let child, browser, logs = '';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
(async () => {
  try {
    const launcher = path.join(installRoot, 'Start-ServerMigration.cmd');
    child = spawn(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `""${launcher}""`], {
      cwd: installRoot, windowsHide: true, windowsVerbatimArguments: true,
      env: { ...process.env, PSModulePath: path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') }
    });
    child.stdout.on('data', data => { logs += data.toString(); });
    child.stderr.on('data', data => { logs += data.toString(); });
    const deadline = Date.now() + 120000;
    while (!/Local migration console: (http:\/\/127\.0\.0\.1:\d+)/.test(logs)) {
      if (child.exitCode !== null || Date.now() > deadline) throw new Error('Actual CMD did not start the console: ' + logs);
      await sleep(100);
    }
    const origin = logs.match(/Local migration console: (http:\/\/127\.0\.0\.1:\d+)/)[1];
    browser = await chromium.launch({ executablePath: process.env.WSM_EDGE, headless: true });
    const page = await browser.newPage();
    await page.goto(origin + '/ui/index.html', { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => window.WsmConsole?.state.wizard?.intentRequired === true).catch(async error => {
      const diagnostic = await page.evaluate(() => ({ wizard: window.WsmConsole?.state.wizard, role: window.WsmConsole?.state.session?.role, workspace: window.WsmConsole?.state.session?.workspace, error: document.getElementById('error-summary')?.textContent }));
      throw new Error(`${error.message}; actual launcher initial view: ${JSON.stringify(diagnostic)}`);
    });
    const session = await page.evaluate(() => window.WsmConsole.state.session);
    assert.equal(path.resolve(session.workspace).toLowerCase(), workspace.toLowerCase());
    await page.locator('input[name="wizard-role"][value="Manager"]').check();
    const savedResponse = page.waitForResponse(response => new URL(response.url()).pathname === '/api/wizard' && response.request().method() === 'POST');
    await page.getByRole('button', { name: '使用這個用途並開始' }).click();
    const saved = await savedResponse;
    const savedText = await saved.text();
    assert.equal(saved.status(), 200, `Actual launcher purpose save failed: ${savedText}`);
    assert.equal(JSON.parse(savedText).saved, true);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => window.WsmConsole?.state.wizard?.workspaceRole === 'Manager' && window.WsmConsole.state.wizard.intentRequired === false);
    const guide = await browser.newPage();
    const guideResponse = await guide.goto(origin + '/ui/guide.html', { waitUntil: 'domcontentloaded' });
    assert.equal(guideResponse.status(), 200);
    assert.ok((await guide.locator('body').innerText()).trim().length > 100);
    const manualResponse = await guide.goto(origin + '/operations-guide.html', { waitUntil: 'domcontentloaded' });
    assert.equal(manualResponse.status(), 200);
    assert.ok((await guide.locator('body').innerText()).trim().length > 100);
    console.log('PASS: actual extracted CMD -> x64 Windows PowerShell -> native Edge page, real purpose save/reload and offline guide/manual from a Chinese/space installation path; no launcher or product stubs.');
  } finally {
    if (browser) await browser.close();
    // Only terminate this test's exact CMD process tree, never unrelated shells.
    if (child && child.exitCode === null) execFileSync('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'pipe' });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
