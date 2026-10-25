// Environment helper for the browser tests that load the REAL PowerShell console's UI (src/ui, served by Start-WsmHtmlConsole).
//
// On this machine AdGuard's WFP driver (adgnetworkwfpdrv) interferes with loopback TCP: a response larger than about 64 KiB that the PowerShell
// listener writes is stalled or reset mid-body (PLAN 17.119: console.js is ~580 KB; a node client gets it in 4 of 6 tries, Edge in 0 of 3, the
// page never reaches DOMContentLoaded, Playwright raises TimeoutError at page.goto). Smaller responses (nonc.js 50 KB, css 59 KB, html 20 KB)
// arrive 100%.
//
// gotoConsole() first probes the native delivery with three plain GETs of /ui/console.js (a node client, 5 s each). When all three deliver the
// complete file it navigates natively (3 tries of 15 s; a timeout or a reset of the navigation counts as a failed try). When the probe or the
// navigation fails it falls back to fulfilling the /ui/* requests from src/ui on disk (the very bytes the console serves) through page.route;
// every /api/* call keeps going to the real console. The decision is printed and counted. A navigation error that is neither a timeout nor a
// connection reset is never covered by the fallback. In an environment without the interference the probe and the native path always succeed
// and nothing changes.
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const UI_TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };
const stats = { native: 0, fromDisk: 0, fromDiskFiles: 0, bootRetries: 0, apiResets: [] };
// WSM_TEST_NO_DISK_UI=1 (set in every GitHub workflow) turns the disk fallback and the environment-limited outcome off: the real console
// transfer must work, and any failure is a failure.
const strict = process.env.WSM_TEST_NO_DISK_UI === '1';
const trackedPages = new WeakSet();
// Every /api/* request of a console page that dies with a connection reset is recorded for reportFailure().
function trackApiResets(page, origin) {
  if (trackedPages.has(page)) return;
  trackedPages.add(page);
  page.on('requestfailed', request => { const u = new URL(request.url()); const reason = request.failure() && request.failure().errorText || ''; if (u.origin === origin && u.pathname.startsWith('/api/') && /ERR_CONNECTION_RESET|ERR_CONNECTION_CLOSED|ERR_EMPTY_RESPONSE/.test(reason)) stats.apiResets.push(request.method() + ' ' + u.pathname + ' ' + reason); });
}
// For the caller's top-level catch: a failure of a run in which the loopback filter reset at least one /api/* request of the real console is
// reported as ENVIRONMENT-LIMITED (exit 3, never a pass) with the error and every reset; a failure without any such reset, or any failure under
// WSM_TEST_NO_DISK_UI=1, is a FAIL (exit 1).
function reportFailure(error, label) {
  const text = String(error && error.stack || error);
  if (!strict && stats.apiResets.length) {
    console.log('ENVIRONMENT-LIMITED: ' + label + ' did not complete after the loopback filter reset ' + stats.apiResets.length + ' real-console API request(s) [' + stats.apiResets.join('; ') + ']; reported, not passed (exit 3). UI served from disk (' + stats.fromDiskFiles + ' files), reloads ' + stats.bootRetries + '. Error: ' + text);
    return 3;
  }
  console.error('FAIL: ' + label + (stats.apiResets.length ? ' (API resets: ' + stats.apiResets.join('; ') + ')' : ' (no environmental API reset observed)') + ': ' + text);
  return 1;
}
// One line for the PASS output.
function deliverySummary() { return 'console UI delivered natively ' + stats.native + 'x; UI served from disk (' + stats.fromDiskFiles + ' files) ' + stats.fromDisk + 'x; reloads after an environmental API reset during boot ' + stats.bootRetries + 'x'; }

function nodeGetBytes(origin, route, timeoutMs) {
  return new Promise(resolve => {
    const url = new URL(origin + route);
    let got = 0;
    const req = http.get({ host: url.hostname, port: url.port, path: url.pathname, agent: false, headers: { Connection: 'close' } }, res => {
      res.on('data', chunk => { got += chunk.length; });
      res.on('end', () => resolve(res.statusCode === 200 ? got : -1));
      res.on('aborted', () => resolve(-1));
      res.on('error', () => resolve(-1));
    });
    req.setTimeout(timeoutMs, () => { resolve(-1); req.destroy(); });
    req.on('error', () => resolve(-1));
  });
}

const SECURITY_HEADERS = ['content-security-policy', 'x-content-type-options', 'referrer-policy', 'cache-control'];
function nodeGetSecurityHeaders(origin, route, timeoutMs) {
  return new Promise(resolve => {
    const url = new URL(origin + route);
    const req = http.get({ host: url.hostname, port: url.port, path: url.pathname, agent: false, headers: { Connection: 'close' } }, res => {
      const picked = {};
      for (const name of SECURITY_HEADERS) if (res.headers[name]) picked[name] = res.headers[name];
      res.resume();
      resolve(res.statusCode === 200 && SECURITY_HEADERS.every(name => picked[name]) ? picked : null);
    });
    req.setTimeout(timeoutMs, () => { resolve(null); req.destroy(); });
    req.on('error', () => resolve(null));
  });
}

// options.ready(page): the caller's own "the console has booted" wait. When it fails and, during that very try, an /api/* request of the page
// died with a connection reset (the loopback filter, see above), the page is loaded again (max BOOT_ATTEMPTS tries, counted in stats.bootRetries
// and printed). A boot that fails without such a reset, or that still fails on the last try, fails the test.
const BOOT_ATTEMPTS = 4;
async function loadAndBoot(page, origin, url, gotoOptions, ready, label) {
  for (let attempt = 1; ; attempt++) {
    const resets = [];
    const onFailed = request => { const u = new URL(request.url()); const reason = request.failure() && request.failure().errorText || ''; if (u.origin === origin && u.pathname.startsWith('/api/') && /ERR_CONNECTION_RESET|ERR_CONNECTION_CLOSED|ERR_EMPTY_RESPONSE/.test(reason)) resets.push(u.pathname + ' ' + reason); };
    page.on('requestfailed', onFailed);
    try {
      await page.goto(url, gotoOptions);
      if (ready) await ready(page);
      return attempt;
    } catch (error) {
      if (!ready || !resets.length || attempt >= BOOT_ATTEMPTS) throw error;
      stats.bootRetries++;
      console.log('environment: ' + label + ' did not boot because ' + resets.join(', ') + ' was reset by the loopback filter; loading again (try ' + attempt + ' of ' + BOOT_ATTEMPTS + ')');
    } finally { page.off('requestfailed', onFailed); }
  }
}

async function gotoConsole(page, origin, route, options = {}) {
  trackApiResets(page, origin);
  const repoRoot = options.repoRoot || path.resolve(__dirname, '..');
  const nativeAttempts = options.nativeAttempts || 3;
  const nativeTimeoutMs = options.nativeTimeoutMs || 15000;
  const expectedBytes = fs.statSync(path.join(repoRoot, 'src', 'ui', 'console.js')).size;
  let delivered = 0;
  for (let probe = 0; probe < 3; probe++) { if (await nodeGetBytes(origin, '/ui/console.js', 5000) === expectedBytes) delivered++; else break; }
  if (delivered === 3) {
    for (let attempt = 1; attempt <= nativeAttempts; attempt++) {
      try {
        await loadAndBoot(page, origin, origin + route, { waitUntil: 'domcontentloaded', timeout: nativeTimeoutMs }, options.ready, route);
        stats.native++;
        return { native: true, attempts: attempt };
      } catch (error) {
        if (!/Timeout|net::ERR_CONNECTION_RESET|net::ERR_CONNECTION_CLOSED|net::ERR_EMPTY_RESPONSE/.test(String(error && error.message))) throw error;
        console.log('environment: ' + route + ' did not reach DOMContentLoaded natively (timeout after ' + nativeTimeoutMs + ' ms or connection reset; try ' + attempt + ' of ' + nativeAttempts + ')');
      }
    }
  } else {
    console.log('environment: probe of /ui/console.js (' + expectedBytes + ' bytes) delivered it completely ' + delivered + ' of 3 times; large-response stall of the loopback filter, skipping native navigation');
  }
  if (strict) throw new Error('WSM_TEST_NO_DISK_UI=1: ' + route + ' could not be loaded through the real console transfer, and the disk fallback is off');
  // The disk copy carries the security headers the real console sent for a small asset that does arrive (CSP, nosniff, referrer, cache), so the
  // page stays under the console's own CSP on this path too. Without those headers the fallback is refused rather than run without CSP.
  let securityHeaders = null;
  for (let attempt = 1; attempt <= 3 && !securityHeaders; attempt++) securityHeaders = await nodeGetSecurityHeaders(origin, '/ui/console.css', 5000);
  if (!securityHeaders) throw new Error('environment fallback refused: the real console did not deliver the security headers of /ui/console.css in 3 tries');
  await page.route(url => url.origin === origin && /^\/ui\/[A-Za-z0-9._-]+$/.test(url.pathname), handler => {
    const name = path.basename(new URL(handler.request().url()).pathname);
    const file = path.join(repoRoot, 'src', 'ui', name);
    if (!fs.existsSync(file) || !UI_TYPES[path.extname(name)]) return handler.fallback();
    stats.fromDiskFiles++;
    return handler.fulfill({ status: 200, headers: { ...securityHeaders, 'content-type': UI_TYPES[path.extname(name)] }, body: fs.readFileSync(file) });
  });
  await loadAndBoot(page, origin, origin + route, { waitUntil: 'domcontentloaded', timeout: 60000 }, options.ready, route);
  stats.fromDisk++;
  console.log('environment note: the UI assets of ' + route + ' were fulfilled from src/ui on disk (same bytes the console serves, with the console\'s security headers); all /api/* calls still go to the real console.');
  return { native: false, attempts: 0 };
}

module.exports = { gotoConsole, stats, reportFailure, deliverySummary };
