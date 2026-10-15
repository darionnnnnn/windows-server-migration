// Native Edge → real local HTTP handler → real PowerShell core Manager approval.
// Every fixture fact is explicitly test-only; no operation endpoint is mocked.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');

if (process.platform !== 'win32') throw new Error('This acceptance requires native Windows Edge and Windows PowerShell.');
const contractOnly = process.env.WSM_MANAGER_JOURNEY_FIXTURE_CONTRACT_ONLY === '1';
const nodeModules = process.env.WSM_NODE_MODULES || 'C:/Users/eldar/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules';
const { chromium } = contractOnly ? {} : require(require.resolve('playwright', { paths: [nodeModules] }));
const sourceRoot = path.resolve(__dirname, '..');
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'wsm-mj-'));
const snapshot = path.join(tempRoot, 'runtime');
const psExe = process.env.WSM_PS_EXE || 'powershell.exe';
const workDrive = [...'RSTUVWXYZ'].find(letter => !fs.existsSync(`${letter}:\\`));
if (!workDrive) throw new Error('No free drive letter is available for the short test-only WorkRoot.');
execFileSync('subst.exe', [`${workDrive}:`, tempRoot], { windowsHide: true, stdio: 'pipe' });
const root = `${workDrive}:\\workspaces`;
const trace = [];
let browser;
const servers = [];

function digestTree(dir, rel = '') {
  const rows = [];
  for (const entry of fs.readdirSync(path.join(dir, rel), { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const child = path.posix.join(rel.replace(/\\/g, '/'), entry.name);
    if (entry.isSymbolicLink()) throw new Error('Immutable fixture snapshot refuses symbolic links: ' + path.join(dir, child));
    if (entry.isDirectory()) rows.push(...digestTree(dir, child));
    else if (entry.isFile()) rows.push(child + '|' + crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, child))).digest('hex'));
    else throw new Error('Immutable fixture snapshot requires regular files: ' + path.join(dir, child));
  }
  return rows;
}
function digestReleaseInputs(dir) {
  return ['Start-ServerMigration.ps1', 'Start-ServerMigration.cmd'].map(name => {
    const full = path.join(dir, name), stat = fs.lstatSync(full);
    if (stat.isSymbolicLink() || !stat.isFile()) throw new Error('Immutable release snapshot requires regular launcher files: ' + full);
    return name + '|' + crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex');
  });
}
function copyTree(source, destination) {
  fs.mkdirSync(destination, { recursive: true });
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name), to = path.join(destination, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Immutable fixture snapshot refuses symbolic links: ' + from);
    if (entry.isDirectory()) copyTree(from, to);
    else if (entry.isFile()) fs.copyFileSync(from, to);
    else throw new Error('Immutable fixture snapshot requires regular files: ' + from);
  }
}
function makeSnapshot() {
  const before = digestTree(path.join(sourceRoot, 'src'));
  const releaseBefore = digestReleaseInputs(sourceRoot);
  fs.mkdirSync(snapshot, { recursive: true });
  copyTree(path.join(sourceRoot, 'src'), path.join(snapshot, 'src'));
  for (const name of ['Start-ServerMigration.ps1', 'Start-ServerMigration.cmd']) fs.copyFileSync(path.join(sourceRoot, name), path.join(snapshot, name));
  fs.mkdirSync(path.join(snapshot, 'tests'), { recursive: true });
  fs.copyFileSync(path.join(__dirname, 'Start-WizardManagerJourneyTestServer.ps1'), path.join(snapshot, 'tests', 'Start-WizardManagerJourneyTestServer.ps1'));
  assert.deepEqual(before, digestTree(path.join(sourceRoot, 'src')), 'Product source changed while fixture snapshot was copied.');
  assert.deepEqual(before, digestTree(path.join(snapshot, 'src')), 'Immutable fixture differs from product source before test-only observation hooks.');
  assert.deepEqual(releaseBefore, digestReleaseInputs(sourceRoot), 'Release launcher inputs changed while the fixture snapshot was copied.');
  assert.deepEqual(releaseBefore, digestReleaseInputs(snapshot), 'Immutable fixture release launchers differ from product bytes.');
  const modulePath = path.join(snapshot, 'src', 'WindowsServerMigration.psm1');
 const observationHooks = String.raw`
# TEST-ONLY native journey observations; applied only to this private module copy.
if ($env:WSM_MANAGER_JOURNEY_TEST -eq '1') {
 function Get-WsmPreflight { [pscustomobject]@{OS='TEST-ONLY Windows Server fixture';Version='10.0';Build='20348';Edition='Datacenter';InstallationType='Server';Architecture='x64';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion=$PSVersionTable.PSVersion.ToString();ExecutionPolicy='RemoteSigned';LanguageMode='FullLanguage';InventoryOnly=$true;RestoreSupported=$false} }
 function Get-WsmMachineIdentity {
  if($env:WSM_RUNTIME_TEST_FINGERPRINT -notmatch '^[a-f0-9]{64}$'){throw 'TEST-ONLY controlled identity is not configured.'}
  $name=switch($env:WSM_RUNTIME_TEST_FINGERPRINT){('a'*64){'journey-source'}('b'*64){'journey-target'}default{'journey-manager'}}
  [pscustomobject]@{Fingerprint=$env:WSM_RUNTIME_TEST_FINGERPRINT;Name=$name;OS='TEST-ONLY Windows Server fixture';Version='2025';IsServer=$true;Administrator=$true;Is64Bit=$true}
 }
 $script:JourneyOriginalSoftwareCatalog=(Get-Command Get-WsmSoftwareCatalog -CommandType Function).ScriptBlock
 function Get-WsmSoftwareCatalog {
  [CmdletBinding()]param($Source,[string[]]$PortableRoot=@(),[int]$MaxEntries=10000,[int]$MaxDepth=8,[long]$MaxMetadataBytes=4194304,[string]$ManualEvidencePath,[string]$ManualEvidenceSha256)
  if($Source.PSObject.Properties['SoftwareCatalog']){return $Source.SoftwareCatalog}
  & $script:JourneyOriginalSoftwareCatalog @PSBoundParameters
 }
 function script:Export-WsmInventory {
  [CmdletBinding()]param([Parameter(Mandatory)][string]$OutputDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog,[ValidateRange(1,50000)][int]$MaxSoftwareEntries=10000,[string[]]$PortableRoot=@(),[string]$ManualEvidencePath,[string]$ManualEvidenceSha256)
  $profile=Read-WsmOutputProfile $env:WSM_RUNTIME_TEST_WORKROOT
  if(-not $profile -or $profile.Role -notin @('Source','Target') -or $profile.Fingerprint -ine $env:WSM_RUNTIME_TEST_FINGERPRINT){throw 'TEST-ONLY inventory observation requires the current enrolled Source or Target profile.'}
  $facts=[pscustomobject]@{HostId=$profile.HostId;Fingerprint=$profile.Fingerprint;Name=$(if($profile.Role -ceq 'Source'){'journey-source'}else{'journey-target'})}
  $items=@()
  if($profile.Role -ceq 'Source'){
   $settings=[pscustomobject][ordered]@{Name='JourneySvc';DisplayName='Journey fixture service';Description='TEST-ONLY LocalSystem observation';PathName='C:\Fixture\JourneySvc.exe';StartMode='Disabled';StartName='LocalSystem';ServiceType='Win32OwnProcess';Supplement=[pscustomobject][ordered]@{ServiceType='Win32OwnProcess';ErrorControl='Normal';LoadOrderGroup='';DelayedAutoStart=$false;FailureActions=[pscustomobject][ordered]@{ResetPeriodSeconds=0;RebootMessage='';Command='';Actions=@()};FailureActionsOnNonCrashFailures=$false;ServiceSidType='None';RequiredPrivileges=@();Environment=@();Triggers=@()}}
   $items+=New-WsmItem $facts.HostId Services Service 'Journey fixture service' 'JourneySvc' $settings @() Success Service
  }
  $inventory=New-WsmInventory $facts 1 $items
  $coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=(Get-WsmUtc)})
  $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$facts.HostId;Fingerprint=$facts.Fingerprint;Name=$facts.Name;InventoryRevision=1;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='TEST-ONLY controlled observation';AccountContext='Unknown';CaptureHost='isolated-manager-journey';PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=('0'*64)}
  $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
  $inventory|Add-Member NoteProperty SoftwareCatalog $catalog -Force
  Assert-WsmSoftwareCatalog $catalog -SourceInventory $inventory|Out-Null
  [void][IO.Directory]::CreateDirectory($OutputDirectory)
  $path=Join-Path $OutputDirectory 'inventory-1.json';Write-WsmJson $path $inventory|Out-Null
  [pscustomobject]@{Path=[IO.Path]::GetFullPath($path);SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
 }
}
`;
  fs.appendFileSync(modulePath, observationHooks, 'utf8');
  const fingerprint = digestTree(path.join(snapshot, 'src'));
  return fingerprint;
}
const sourceFingerprint = digestTree(path.join(sourceRoot, 'src'));
const snapshotFingerprint = makeSnapshot();
const overlayModuleHash = crypto.createHash('sha256').update(fs.readFileSync(path.join(snapshot, 'src', 'WindowsServerMigration.psm1'))).digest('hex');
const releaseFingerprint = digestReleaseInputs(sourceRoot);
function log(message) { const line = new Date().toISOString() + ' ' + message; trace.push(line); process.stdout.write(line + '\n'); }
function wait(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

async function startServer(role) {
  const tag = role.toLowerCase(), roleDir = path.join(tempRoot, tag);
  fs.mkdirSync(roleDir, { recursive: true });
  const ready = path.join(roleDir, 'ready.json'), stop = path.join(roleDir, 'stop');
  const child = spawn(psExe, ['-NoProfile', '-File', path.join(snapshot, 'tests', 'Start-WizardManagerJourneyTestServer.ps1'), '-Role', role, '-WorkspaceRoot', root, '-ReadyPath', ready, '-StopFile', stop], {
    windowsHide: true,
    env: { ...process.env, WSM_MANAGER_JOURNEY_TEST: '1', WSM_RUNTIME_TEST_FINGERPRINT: role === 'Source' ? 'a'.repeat(64) : role === 'Target' ? 'b'.repeat(64) : 'c'.repeat(64), WSM_RUNTIME_TEST_WORKROOT: path.join(root, role), PSModulePath: path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') }
  });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk.toString(); log(role + ' PS ' + chunk.toString().trim()); });
  child.stderr.on('data', chunk => { output += chunk.toString(); log(role + ' PSERR ' + chunk.toString().trim()); });
  servers.push({ child, stop, role });
  const deadline = Date.now() + 120000;
  while (!fs.existsSync(ready)) {
    if (child.exitCode !== null || Date.now() > deadline) throw new Error(role + ' native fixture server failed to start.\n' + output);
    await wait(100);
  }
  const info = JSON.parse(fs.readFileSync(ready, 'utf8'));
  return { role, origin: info.Url, workspace: path.join(root, role) };
}
function runPowerShell(scriptPath, env = {}) {
  return execFileSync(psExe, ['-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath], {
    windowsHide: true, encoding: 'utf8', env: { ...process.env, ...env, WSM_MANAGER_JOURNEY_TEST: '1', PSModulePath: path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'Modules') }
  });
}
async function fixtureContractExperiment() {
  await verifyFingerprintContract();
  const startup = await startServer('Manager');
  const profilePath = path.join(startup.workspace, 'workspace-control', 'output-profile.json');
  assert.ok(fs.existsSync(path.join(tempRoot, 'manager', 'ready.json')), 'The real helper must publish ReadyPath before any HTTP request.');
  assert.equal(fs.existsSync(profilePath), false, 'Starting a role helper must leave its workspace un-enrolled and blank.');
  const contractScript = path.join(tempRoot, 'verify-observation-contract.ps1');
  fs.writeFileSync(contractScript, String.raw`
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot 'runtime\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {
  $toolFingerprint=Get-WsmToolFingerprint
  if($toolFingerprint -notmatch '^[a-fA-F0-9]{64}$'){throw 'TEST-ONLY tool fingerprint is not a non-empty SHA-256.'}
  $profile=Initialize-WsmOutputWorkspace -WorkRoot $env:WSM_RUNTIME_TEST_WORKROOT -Role Source
  $arguments=ConvertTo-WsmHtmlArguments (Get-Command Export-WsmInventory) ([pscustomobject]@{OutputDirectory=$profile.InventoryDirectory;DeepDiscovery=$true;IncludeSoftwareCatalog=$true})
  $result=Export-WsmInventory @arguments
  if(-not $result.Path -or -not $result.SHA256){throw 'TEST-ONLY observation did not return a durable inventory artifact.'}
  if((Get-FileHash -LiteralPath $result.Path -Algorithm SHA256).Hash -ine $result.SHA256){throw 'TEST-ONLY inventory readback SHA-256 mismatch.'}
  $inventory=Read-WsmJson $result.Path;Assert-WsmInventory $inventory
  if(-not $inventory.PSObject.Properties['SoftwareCatalog']){throw 'TEST-ONLY inventory omitted its software catalog.'}
  Assert-WsmSoftwareCatalog $inventory.SoftwareCatalog -SourceInventory $inventory|Out-Null
  $enrolled=Read-WsmOutputProfile $env:WSM_RUNTIME_TEST_WORKROOT
  if($inventory.Source.HostId -cne $enrolled.HostId -or $inventory.Source.Fingerprint -ine $env:WSM_RUNTIME_TEST_FINGERPRINT){throw 'TEST-ONLY inventory did not bind the actual enrolled host identity.'}
  $localSystemServices=@($inventory.Items|Where-Object {$_.Kind -ceq 'Service' -and $_.Settings.StartName -ceq 'LocalSystem'})
  if($localSystemServices.Count -ne 1){throw 'TEST-ONLY LocalSystem service observation is missing.'}
  if($script:ToolVersion -cne '0.4.0'){throw 'TEST-ONLY catalog ToolVersion did not resolve the private module version.'}
  [pscustomobject]@{HostId=$enrolled.HostId;Fingerprint=$inventory.Source.Fingerprint;InventoryPath=$result.Path;InventoryHash=$result.SHA256;SoftwareCatalogAccepted=$true;LocalSystemServiceCount=$localSystemServices.Count;ToolVersion=$script:ToolVersion;ToolFingerprint=$toolFingerprint}|ConvertTo-Json -Compress
}
`, 'utf8');
  const outputRoot = path.join(root, 'contract-source'); fs.mkdirSync(outputRoot, { recursive: true });
  const output = runPowerShell(contractScript, {
    WSM_RUNTIME_TEST_WORKROOT: outputRoot,
    WSM_RUNTIME_TEST_FINGERPRINT: 'a'.repeat(64),
    WSM_MANAGER_JOURNEY_TEST: '1'
  });
  const contract = JSON.parse(output.trim().split(/\r?\n/).at(-1));
  assert.equal(contract.Fingerprint, 'a'.repeat(64));
  assert.ok(contract.HostId && contract.InventoryHash && contract.SoftwareCatalogAccepted);
  assert.equal(contract.LocalSystemServiceCount, 1);
  assert.equal(contract.ToolVersion, '0.4.0');
  assert.match(contract.ToolFingerprint, /^[a-f0-9]{64}$/);
  log('PASS helper ReadyPath on blank workspace and TEST-ONLY observation artifact contract; no browser or HTTP requests.');
}
async function verifyFingerprintContract() {
  const fingerprintScript = path.join(tempRoot, 'verify-tool-fingerprint.ps1');
  fs.writeFileSync(fingerprintScript, String.raw`
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot 'runtime\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {$fingerprint=Get-WsmToolFingerprint;if($fingerprint -notmatch '^[a-fA-F0-9]{64}$'){throw 'TEST-ONLY tool fingerprint is not a non-empty SHA-256.'};[pscustomobject]@{ToolFingerprint=$fingerprint}|ConvertTo-Json -Compress}
`, 'utf8');
  const output = runPowerShell(fingerprintScript);
  const value = JSON.parse(output.trim().split(/\r?\n/).at(-1));
  assert.match(value.ToolFingerprint, /^[a-f0-9]{64}$/);
  assert.deepEqual(releaseFingerprint, digestReleaseInputs(snapshot), 'Tool fingerprint launch inputs differ from the immutable snapshot.');
  log('PASS Get-WsmToolFingerprint against copied PS1/CMD and src files.');
}
async function openUi(server) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [], operations = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') log(server.role + ' browser console ' + message.text()); });
  page.on('response', response => {
    if (response.status() >= 400 && new URL(response.url()).pathname.startsWith('/api/')) {
      response.text().then(body => log(server.role + ' HTTP ' + response.status() + ' ' + new URL(response.url()).pathname + ' ' + body.slice(0, 1800))).catch(() => {});
    }
  });
  page.on('request', request => { if (request.method() === 'POST' && new URL(request.url()).pathname === '/api/operations') { const body=request.postDataJSON();operations.push(body);log(server.role + ' UI operation ' + JSON.stringify(body)); } });
  await page.goto(server.origin + '/#wizard', { waitUntil: 'domcontentloaded' });
  await page.waitForFunction(role => window.WsmConsole?.state?.session?.role === role, server.role, { timeout: 30000 });
  await page.waitForFunction(() => !!window.WsmConsole?.state?.wizard?.currentStep, null, { timeout: 30000 });
  const state = await page.evaluate(() => ({ intentRequired: !!window.WsmConsole.state.wizard?.intentRequired, step: window.WsmConsole.state.wizard?.currentStep }));
  if (state.intentRequired) {
    await page.locator(`input[name="wizard-role"][value="${server.role}"]`).check();
    await page.getByRole('button', { name: '使用這個用途並開始' }).click();
    await page.waitForFunction(() => !!window.WsmConsole.state.wizard && !window.WsmConsole.state.wizard.intentRequired);
  }
  if ((await page.evaluate(() => window.WsmConsole.state.wizard?.currentStep)) === 'start') {
    await page.locator('input[name="wizard-mode"][value="ItemByItem"]').check();
    await page.locator('#wizard-next').click();
    await page.waitForFunction(() => !!window.WsmConsole.state.wizard?.currentStep && window.WsmConsole.state.wizard.currentStep !== 'start');
  }
  return { page, errors, operations };
}
async function waitJob(page, action) {
  await page.waitForFunction(name => [...(window.WsmConsole?.state?.jobs?.values() || [])].some(job => job.action === name && ['Succeeded','Failed','ReviewRequired','Cancelled'].includes(job.status)), action, { timeout: 120000 });
  const job = await page.evaluate(name => [...window.WsmConsole.state.jobs.values()].filter(row => row.action === name).at(-1), action);
  assert.equal(job.status, 'Succeeded', action + ' failed: ' + JSON.stringify(job.error || job));
  // Await the session/context reconciliation that follows terminal publication.
  await page.waitForFunction(() => !window.WsmConsole.state.jobsRefreshing && !window.WsmConsole.state.busy && !window.WsmConsole.state.wizardAdvancing && !window.WsmConsole.state.wizardSourceHandoffImportFollowing);
  return job;
}
async function selectWizardAction(page, action, values = {}) {
  await page.evaluate(() => window.WsmConsole.navigate('wizard', { force: true }));
  await page.waitForFunction(() => window.WsmConsole?.state?.wizard);
  const row = await page.evaluate(name => (window.WsmConsole.state.wizard.actions || []).find(item => item.action === name) || null, action);
  assert.ok(row, 'Current real wizard projection does not expose action ' + action);
  const card = page.locator('.wizard-action-card').filter({ has: page.locator('h2', { hasText: row.label || action }) });
  await card.waitFor({ state: 'visible', timeout: 15000 });
  let form = card.locator('.wizard-action-fields');
  if (!(await form.count())) {
    const reveal = card.getByRole('button', { name: '查看必要條件' });
    if (await reveal.isVisible().catch(() => false)) await reveal.click();
    await form.waitFor({ state: 'visible', timeout: 15000 });
  }
  for (const [name, value] of Object.entries(values)) {
    const input = form.locator(`[data-wizard-field="${name}"]`);
    await input.waitFor({ state: 'visible' });
    if (await input.getAttribute('type') === 'checkbox') { if (value) await input.check(); else await input.uncheck(); }
    else await input.fill(String(value));
  }
  const primary = page.locator('#wizard-next');
  const isPrimary = await form.evaluate(node => !node.querySelector('button:not([hidden])'));
  if (isPrimary && await primary.isVisible()) await primary.click();
  else await form.getByRole('button', { name: /執行此步驟|保存項目審閱/ }).click();
  await waitJob(page, action);
  await page.waitForFunction(() => !window.WsmConsole.state.busy && !window.WsmConsole.state.wizardAdvancing && !window.WsmConsole.state.wizardSourceHandoffImportFollowing);
}
async function confirmSourceIntent(page) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const projection = await page.evaluate(() => window.WsmConsole.state.wizard);
    if (projection.currentStep !== 'review') return;
    const pending = (projection.groups || []).some(group => group.confirmed !== true);
    if (!pending) {
      await page.waitForFunction(() => window.WsmConsole.state.wizard?.currentStep !== 'review');
      return;
    }
    const include = page.locator('#wizard-content input[name="wizard-group-choice"][value="include"]');
    if (await include.count()) await include.check();
    await page.locator('#wizard-next').click();
    await page.waitForFunction(previous => window.WsmConsole.state.wizard?.currentStep !== 'review' || window.WsmConsole.state.wizard?.currentGroupId !== previous, projection.currentGroupId, { timeout: 15000 });
  }
  throw new Error('Source item by item review did not finish through its visible controls.');
}
async function saveBulkSpec(page) {
  const card = page.locator('.wizard-bulk-preparation-card');
  await card.waitFor({ state: 'visible', timeout: 15000 });
  await card.getByRole('button', { name: '預覽符合條件的項目' }).click();
  await waitJob(page, 'BulkPreparationPreview');
  await card.locator('[data-bulk-preparation-key="Owner"]').fill('Journey fixture owner');
  await card.locator('[data-bulk-preparation-key="Evidence"]').fill('Reviewed controlled LocalSystem service facts.');
  await card.locator('[data-bulk-preparation-key="BusinessChecks"]').fill('Verify the service configuration on target');
  const consent = card.locator('[data-bulk-preparation-key="ReviewedSourceDefaults"]');
  if (await consent.count()) await consent.check();
  await card.getByRole('button', { name: '確認並保存這批審閱' }).click();
  return waitJob(page, 'BulkPreparationSave');
}

async function main() {
  if (process.env.WSM_MANAGER_JOURNEY_FINGERPRINT_ONLY === '1') return verifyFingerprintContract();
  if (contractOnly) return fixtureContractExperiment();
  if (process.env.WSM_RUNTIME_NATIVE_TRANSPORT !== '1') throw new Error('Set WSM_RUNTIME_NATIVE_TRANSPORT=1 to require the native local HTTP transport; mocked/bridge transport is not accepted.');
  fs.mkdirSync(root, { recursive: true });
  browser = await chromium.launch({ channel: 'msedge', headless: true });
  const source = await startServer('Source');
  const sourceUi = await openUi(source);
  // Start with the genuine Source wizard inventory action. The observation
  // override supplies controlled local facts to the copied module only.
  const initialActions = await sourceUi.page.evaluate(() => window.WsmConsole.state.wizard.actions.map(row => row.action));
  assert.ok(initialActions.includes('Inventory'), 'Source wizard must start without a pre-seeded inventory binding.');
  await selectWizardAction(sourceUi.page, 'Inventory');
  await sourceUi.page.waitForFunction(() => !!window.WsmConsole.state.wizard?.inventory?.sha256 && window.WsmConsole.state.wizard.currentStep === 'review');
  const sourceInventory = await sourceUi.page.evaluate(() => window.WsmConsole.state.wizard.inventory);
  assert.ok(sourceInventory?.sha256, 'UI Inventory action must bind a real Source inventory.');
  await confirmSourceIntent(sourceUi.page);
  assert.equal(await sourceUi.page.evaluate(() => window.WsmConsole.state.wizard.currentStep), 'backup', 'Source review must reach backup through visible item-choice controls.');
  await sourceUi.page.close();
  const sourceHandoffUi = await openUi(source);
  await selectWizardAction(sourceHandoffUi.page, 'ExportSourceReviewHandoff');
  const sourceHandoffJob = await sourceHandoffUi.page.evaluate(() => [...window.WsmConsole.state.jobs.values()].filter(job => job.action === 'ExportSourceReviewHandoff').at(-1));
  const sourceHandoff = sourceHandoffJob.outputs[0];
  assert.equal(sourceHandoff.HandoffStatus, 'Exported');
  assert.match(sourceHandoff.SHA256, /^[a-f0-9]{64}$/i);
  assert.deepEqual([...sourceUi.operations, ...sourceHandoffUi.operations].map(row => row.action), ['Inventory', 'ExportSourceReviewHandoff']);

  const target = await startServer('Target');
  const targetIdentityRoot = path.join(target.workspace, 'targets');
  const identityFiles = fs.existsSync(targetIdentityRoot) ? fs.readdirSync(targetIdentityRoot, { recursive: true }).filter(name => String(name).endsWith('target-identity.json')) : [];
  assert.equal(identityFiles.length, 0, 'Target identity must be absent before UI enrollment.');
  const targetUi = await openUi(target);
  const enrolledIdentityFiles = fs.readdirSync(targetIdentityRoot, { recursive: true }).filter(name => String(name).endsWith('target-identity.json'));
  assert.equal(enrolledIdentityFiles.length, 1, 'Choosing Target in the UI must create its enrolled physical identity.');
  const enrolledIdentity = JSON.parse(fs.readFileSync(path.join(targetIdentityRoot, enrolledIdentityFiles[0]), 'utf8'));
  await selectWizardAction(targetUi.page, 'Inventory');
  await targetUi.page.waitForFunction(() => window.WsmConsole.state.wizard?.currentStep === 'prepare');
  assert.equal(await targetUi.page.evaluate(() => window.WsmConsole.state.wizard.currentStep), 'prepare', 'Target inventory must advance through the normal wizard flow.');
  await selectWizardAction(targetUi.page, 'RegisterTarget');
  const registrationJob = await targetUi.page.evaluate(() => [...window.WsmConsole.state.jobs.values()].filter(job => job.action === 'RegisterTarget').at(-1));
  assert.equal(registrationJob.status, 'Succeeded');
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(targetIdentityRoot, enrolledIdentityFiles[0]), 'utf8')), enrolledIdentity, 'RegisterTarget must retain the enrolled physical identity.');
  await selectWizardAction(targetUi.page, 'ExportTargetHandoff');
  const targetJob = await targetUi.page.evaluate(() => [...window.WsmConsole.state.jobs.values()].filter(job => job.action === 'ExportTargetHandoff').at(-1));
  const targetHandoff = targetJob.outputs[0];
  assert.equal(targetHandoff.Status, 'Exported');
  assert.match(targetHandoff.ObservedManifestHash, /^[a-f0-9]{64}$/i);
  assert.equal((await targetUi.page.evaluate(() => window.WsmConsole.state.wizardRuntimeProjection?.runtime?.plan)) || null, null, 'Target exports an empty-workspace handoff without an approved plan or backup.');
  assert.deepEqual(targetUi.operations.map(row => row.action), ['Inventory', 'RegisterTarget', 'ExportTargetHandoff']);
  assert.equal(targetUi.operations.some(row => /Backup|Package|Restore/i.test(row.action)), false, 'The target journey must not create a backup, package, or restore.');
  assert.equal(sourceUi.operations.some(row => /Backup|Package|Restore/i.test(row.action)), false, 'The Manager approval evidence must be reached without preparing a Source backup.');
  await targetUi.page.close();

  const manager = await startServer('Manager');
  const managerUi = await openUi(manager);
  assert.equal(await managerUi.page.evaluate(() => window.WsmConsole.state.wizard.currentStep), 'handoff', 'Manager must enter handoff by its visible first-use step control.');
  await selectWizardAction(managerUi.page, 'ImportSourceReviewHandoff', { Path: sourceHandoff.Path, ExpectedHash: sourceHandoff.SHA256, TargetName: 'journey-target' });
  const importJob = await managerUi.page.evaluate(() => [...window.WsmConsole.state.jobs.values()].filter(job => job.action === 'ImportSourceReviewHandoff').at(-1));
  assert.equal(importJob.outputs[0].HandoffStatus, 'Imported');
  assert.equal(managerUi.operations.some(row => row.action === 'ImportSourceReviewHandoff'), true, 'Manager source intent must be imported by the native UI.');
  const pairId = importJob.outputs[0].PairId;
  const catalogPath = path.join(manager.workspace, 'pairs', pairId + '.json');
  assert.ok(pairId && fs.existsSync(catalogPath), 'Source handoff must create the formal pairs/<PairId>.json catalog.');
  const importedCatalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
  assert.equal(importedCatalog.PairId, pairId);
  assert.ok(importedCatalog.Assistive, 'Confirmed Source intent must create its Assistive contract.');
  await managerUi.page.waitForFunction(id => String(window.WsmConsole.state.session?.pairId || '') === id, pairId, { timeout: 30000 });
  await managerUi.page.evaluate(() => window.WsmConsole.navigate('wizard', { force: true }));
  // Importing confirmed Source intent already creates the Assistive contract.
  // The newly selected pair has its own initial wizard state, chosen in the UI.
  await managerUi.page.waitForFunction(() => window.WsmConsole.state.wizard?.currentStep === 'start');
  await managerUi.page.locator('input[name="wizard-mode"][value="ItemByItem"]').check();
  await managerUi.page.locator('#wizard-next').click();
  await managerUi.page.waitForFunction(() => window.WsmConsole.state.wizard?.currentStep === 'handoff');
  await selectWizardAction(managerUi.page, 'GetTargetHandoffPreview', { HandoffDirectory: targetHandoff.Directory, ExpectedManifestHash: targetHandoff.ObservedManifestHash });
  const targetPreview = managerUi.page.locator('.wizard-target-handoff-card').getByRole('button', { name: '明確保存此目標快照' });
  await targetPreview.waitFor({ state: 'visible', timeout: 15000 });
  await targetPreview.click();
  await waitJob(managerUi.page, 'CommitTargetHandoff');
  const specJob = await saveBulkSpec(managerUi.page);
  assert.ok(specJob.outputs[0].SavedItemIds?.length, 'The Manager UI must write at least one real migration spec through the core consumer.');
  await selectWizardAction(managerUi.page, 'PublishComparison');
  await selectWizardAction(managerUi.page, 'ApproveMigration', { PilotAcknowledgement: true });
  const approval = await managerUi.page.evaluate(() => [...window.WsmConsole.state.jobs.values()].filter(job => job.action === 'ApproveMigration').at(-1));
  assert.equal(approval.status, 'Succeeded', JSON.stringify(approval.error || approval));
  const approvedOutput = approval.outputs.find(row => row.Path && row.SHA256);
  assert.ok(approvedOutput, 'The UI approval operation must return its sealed plan file and SHA-256.');
  const planBytes = fs.readFileSync(approvedOutput.Path);
  assert.equal(crypto.createHash('sha256').update(planBytes).digest('hex'), approvedOutput.SHA256.toLowerCase());
  const plan = JSON.parse(planBytes.toString('utf8'));
  assert.equal(approval.outputs.find(row => row.ProductionVerified !== undefined)?.ProductionVerified, false, 'Core approval result must remain explicitly unqualified for production.');
  assert.ok(plan.Assistive.ApprovedItemIds?.length);
  assert.ok(managerUi.operations.some(row => row.action === 'PublishComparison'), 'PublishComparison must be submitted through the real Manager UI.');
  const approvalRequests = managerUi.operations.filter(row => row.action === 'ApproveMigration');
  assert.equal(approvalRequests.length, 1, 'Exactly one native UI approval request is permitted.');
  assert.equal(approvalRequests[0].args.PilotAcknowledgement, 'ISOLATED-PILOT', 'The approval acknowledgment must come from its explicit UI checkbox.');
  assert.equal(await managerUi.page.evaluate(() => window.WsmConsole.state.wizardStale), false, 'A successful approval must not label its own saved consent as a conflicting edit.');
  assert.equal(await managerUi.page.locator('.wizard-stale-notice').count(), 0, 'Same-page approval must expose the current handoff state.');
  // Reopen a fresh page: handoff evidence must come from durable jobs, not memory.
  await managerUi.page.close();
  const reopenedManager = await openUi(manager);
  assert.equal(await reopenedManager.page.evaluate(() => window.WsmConsole.state.session.pairId), pairId);
  await reopenedManager.page.evaluate(() => window.WsmConsole.navigate('jobs', { force: true }));
  await reopenedManager.page.waitForFunction(id => window.WsmConsole.state.jobs.get(id)?.status === 'Succeeded', approval.jobId);
  const recoveredApproval = await reopenedManager.page.evaluate(id => window.WsmConsole.state.jobs.get(id), approval.jobId);
  assert.ok(recoveredApproval.outputs.some(row => row.Path === approvedOutput.Path && row.SHA256 === approvedOutput.SHA256), 'Reopened Manager must recover the exact sealed-plan handoff.');
  assert.ok((await reopenedManager.page.locator('#job-list').innerText()).includes(approvedOutput.SHA256), 'The recovered handoff hash must be visible.');
  assert.equal(reopenedManager.operations.length, 0, 'Reopening handoff history must not submit a new operation.');
  assert.equal(reopenedManager.errors.length, 0);
  assert.deepEqual(snapshotFingerprint, digestTree(path.join(snapshot, 'src')), 'Immutable copied product source and its private observer overlay changed during the browser journey.');
  assert.deepEqual(sourceFingerprint, digestTree(path.join(sourceRoot, 'src')), 'Live product source fingerprint changed during the browser journey.');
  const productFiles = rows => rows.filter(row => !row.startsWith('WindowsServerMigration.psm1|'));
  assert.deepEqual(productFiles(sourceFingerprint), productFiles(snapshotFingerprint), 'All copied product files except the private test-only module overlay must match live source.');
  assert.notEqual(overlayModuleHash, sourceFingerprint.find(row => row.startsWith('WindowsServerMigration.psm1|')).split('|')[1], 'Test-only observer overlay must be confined to the private copied module.');
  assert.deepEqual(releaseFingerprint, digestReleaseInputs(sourceRoot), 'Live release launchers changed during the browser journey.');
  assert.deepEqual(releaseFingerprint, digestReleaseInputs(snapshot), 'Immutable copied release launcher bytes changed during the browser journey.');
  assert.equal(sourceUi.errors.length + sourceHandoffUi.errors.length + targetUi.errors.length + managerUi.errors.length, 0, 'Native browser raised page errors.');
  log('PASS native Edge/HTTP Manager approval; test-only controlled identities and observations; sealed plan independent SHA-256 readback.');
}

main().catch(async error => {
  console.error(error);
  if (browser) for (const context of browser.contexts()) for (const page of context.pages()) {
    try {
      const diagnostic = await page.evaluate(() => {
        const state = window.WsmConsole?.state, wizard = state?.wizard;
        return { role: state?.session?.role, step: wizard?.currentStep, revision: wizard?.revision,
          scan: wizard?.scan, inventoryJobId: state?.wizardInventoryJobId, advancing: state?.wizardAdvancing,
          busy: state?.busy, stale: state?.wizardStale, error: document.querySelector('#error-summary')?.textContent,
          jobs: [...(state?.jobs?.values() || [])].map(job => ({ action: job.action, status: job.status, error: job.error })) };
      });
      log('TEST-ONLY failure state ' + JSON.stringify(diagnostic));
    } catch {}
  }
  console.error(trace.join('\n')); process.exitCode = 1;
}).finally(async () => {
  if (browser) await browser.close().catch(() => {});
  for (const server of servers) {
    try { fs.writeFileSync(server.stop, 'stop'); } catch {}
    if (server.child.exitCode === null) await new Promise(resolve => { const timer = setTimeout(resolve, 5000); server.child.once('exit', () => { clearTimeout(timer); resolve(); }); });
    if (server.child.exitCode === null) server.child.kill();
  }
  try { execFileSync('subst.exe', [`${workDrive}:`, '/D'], { windowsHide: true, stdio: 'pipe' }); } catch {}
  if (process.env.WSM_KEEP_MANAGER_JOURNEY_FIXTURE === '1') log('Kept TEST-ONLY journey fixture at ' + tempRoot);
  else fs.rmSync(tempRoot, { recursive: true, force: true });
});
