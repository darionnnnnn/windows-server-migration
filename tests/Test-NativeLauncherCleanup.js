'use strict';

const assert = require('node:assert/strict');
const net = require('node:net');
const { spawnSync } = require('node:child_process');

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const childExited = child => child.exitCode !== null || child.signalCode !== null;

async function waitForChildExit(child, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (!childExited(child) && Date.now() < deadline) await sleep(100);
  return childExited(child);
}

function canConnect(url, createConnection = net.createConnection) {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: url.hostname, port: Number(url.port) });
    let settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      if (error) reject(error);
      else resolve(value);
    };
    socket.setTimeout(500, () => finish(null, true));
    socket.once('connect', () => finish(null, true));
    socket.once('error', error => {
      if (error.code === 'ECONNREFUSED') finish(null, false);
      else finish(error);
    });
  });
}

async function verifyConsoleStopped(consoleOrigin, timeoutMs = 12000) {
  const url = new URL(consoleOrigin);
  const deadline = Date.now() + timeoutMs;
  let consecutiveRefusals = 0;
  while (Date.now() < deadline) {
    if (await canConnect(url)) consecutiveRefusals = 0;
    else if (++consecutiveRefusals >= 3) return;
    await sleep(250);
  }
  throw new Error(`The launched console still accepts loopback connections at ${url.host} after cleanup.`);
}

async function stopOwnedLauncher(child, consoleOrigin, options = {}) {
  const taskkillCommand = options.taskkill || spawnSync;
  const exitTimeoutMs = options.exitTimeoutMs ?? 5000;
  const verificationTimeoutMs = options.verificationTimeoutMs ?? 12000;
  let taskkill = { status: 0, stdout: '', stderr: '' };
  if (!childExited(child)) {
    taskkill = taskkillCommand('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], {
      windowsHide: true, encoding: 'utf8', timeout: 15000
    });
    if (taskkill.error) throw new Error(`Could not invoke taskkill for the owned launcher process: ${taskkill.error.message}`);
    if (!await waitForChildExit(child, exitTimeoutMs)) {
      // The fallback targets only the exact CMD process this test spawned.
      try { child.kill(); }
      catch (error) { if (error.code !== 'ESRCH') throw error; }
      if (!await waitForChildExit(child, exitTimeoutMs)) throw new Error(`The owned launcher process ${child.pid} remained alive after cleanup.`);
    }
  }
  await verifyConsoleStopped(consoleOrigin, verificationTimeoutMs);
  return taskkill;
}

async function listenLoopback() {
  const server = net.createServer(socket => socket.end());
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  return { server, origin: `http://127.0.0.1:${address.port}` };
}

async function runTests() {
  let checks = 0;
  const check = (condition, message) => { assert.ok(condition, message); checks++; };
  const fixture = await listenLoopback();
  try {
    let stillOpenRejected = false;
    try { await verifyConsoleStopped(fixture.origin, 40); }
    catch (error) { stillOpenRejected = /still accepts loopback/.test(error.message); }
    check(stillOpenRejected, 'a live loopback listener cannot be accepted as stopped');

    let unknownErrorRejected = false;
    try {
      await canConnect(new URL(fixture.origin), options => {
        const { EventEmitter } = require('node:events');
        const socket = new EventEmitter();
        socket.setTimeout = () => {};
        socket.destroy = () => {};
        process.nextTick(() => socket.emit('error', Object.assign(new Error('controlled access error'), { code: 'EACCES' })));
        return socket;
      });
    } catch (error) { unknownErrorRejected = error.code === 'EACCES'; }
    check(unknownErrorRejected, 'unknown socket errors cannot be treated as a stopped listener');

    let taskkillCalls = 0;
    const liveChild = { pid: 4242, exitCode: null, signalCode: null, kill() {} };
    let liveTreeRejected = false;
    try {
      await stopOwnedLauncher(liveChild, fixture.origin, {
        exitTimeoutMs: 10, verificationTimeoutMs: 40,
        taskkill: () => { taskkillCalls++; return { status: 1, stdout: '', stderr: 'partial tree failure' }; }
      });
    } catch (error) { liveTreeRejected = /remained alive/.test(error.message); }
    check(taskkillCalls === 1 && liveTreeRejected, 'nonzero taskkill cannot pass while the spawned root remains alive');

    const lingeringConsoleChild = { pid: 4244, exitCode: null, signalCode: null, kill() { this.exitCode = 0; } };
    let lingeringConsoleRejected = false;
    try {
      await stopOwnedLauncher(lingeringConsoleChild, fixture.origin, {
        exitTimeoutMs: 20, verificationTimeoutMs: 40,
        taskkill: () => ({ status: 1, stdout: '', stderr: 'partial tree failure' })
      });
    } catch (error) { lingeringConsoleRejected = /still accepts loopback/.test(error.message); }
    check(lingeringConsoleChild.exitCode === 0 && lingeringConsoleRejected,
      'nonzero taskkill cannot pass when the spawned root exits but the owned console listener remains live');

    const closed = await new Promise((resolve, reject) => fixture.server.close(error => error ? reject(error) : resolve(true)));
    check(closed, 'controlled loopback listener closed');
    await verifyConsoleStopped(fixture.origin, 3000);
    check(true, 'three connection refusals confirm the listener stopped');

    const exitedChild = { pid: 4243, exitCode: null, signalCode: null, kill() { this.exitCode = 0; } };
    const cleanup = await stopOwnedLauncher(exitedChild, fixture.origin, {
      exitTimeoutMs: 20, verificationTimeoutMs: 3000,
      taskkill: () => { exitedChild.exitCode = 0; return { status: 1, stdout: '', stderr: 'partial tree failure' }; }
    });
    check(cleanup.status === 1 && exitedChild.exitCode === 0, 'partial taskkill is retained for diagnostics after root exit and listener stop are verified');
  } finally {
    if (fixture.server.listening) await new Promise(resolve => fixture.server.close(resolve));
  }
  process.stdout.write(`PASS Test-NativeLauncherCleanup: ${checks} listener, error classification, child ownership and teardown checks.\n`);
  return checks;
}

if (require.main === module) runTests().catch(error => { console.error(error); process.exitCode = 1; });

module.exports = { stopOwnedLauncher, verifyConsoleStopped, canConnect, runTests };
