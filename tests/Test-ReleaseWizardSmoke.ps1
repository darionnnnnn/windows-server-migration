#requires -Version 5.1
[CmdletBinding()]param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$module=Import-Module (Join-Path $repository 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$ownedRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-release-smoke-'+[guid]::NewGuid().ToString('N'))
if($OutputDirectory){$ownedRoot=[IO.Path]::GetFullPath($OutputDirectory);if([IO.Directory]::Exists($ownedRoot) -or [IO.File]::Exists($ownedRoot)){throw 'Smoke output must be a new exclusive directory.'}}
[void][IO.Directory]::CreateDirectory($ownedRoot)
# Keep the archive, exact index and diagnostics for inspection; no production trust is granted.
$archivePath=Join-Path $ownedRoot 'migration-tool.zip'
$release=Export-WsmToolRelease -Path $archivePath
$projection=& $module {param($p)Get-WsmReleaseArchiveProjection $p} $archivePath
if($projection.ToolFingerprint -cne $release.ToolFingerprint){throw 'Release fingerprint differs from its exact payload.'}
$paths=@($projection.Index.Files.Path)
foreach($required in @('Start-ServerMigration.cmd','Start-ServerMigration.ps1','src/ui/nonc.js','src/WizardRuntime.ps1','src/WizardRestore.ps1','src/WizardNonCTargetHandoff.ps1','docs/html/index.html','docs/MIGRATION-3-PLAN.md')){if($paths -cnotcontains $required){throw ('Release omitted '+$required)}}
if(@($paths|Where-Object {$_ -match '(^|/)(archive|plans|work|tests)/|MIGRATION-.*-PLAN\.html$|Get-ServerMigrationInventory\.ps1$'}).Count){throw 'Release contains excluded planning, private or runtime-test inputs.'}
$extracted=Join-Path $ownedRoot '離線工具 Chinese spaces'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($archivePath,$extracted)
foreach($row in $projection.Index.Files){$file=Join-Path $extracted $row.Path;if(-not [IO.File]::Exists($file) -or (Get-Item -LiteralPath $file).Length -ne $row.Bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $row.SHA256){throw ('Extracted byte mismatch '+$row.Path)}}
$probePath=Join-Path $ownedRoot 'verify-extracted.ps1'
$probe=@'
param([string]$Root,[string]$ResultPath)
$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path $Root 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
foreach($name in @('Invoke-WsmWizardStartBackup','Get-WsmWizardRuntimeProjection','Get-WsmWizardNonCPreparation','Import-WsmWizardNonCTargetHandoff','Get-WsmWizardTargetRestoreProjection')){if(-not $m.ExportedCommands.ContainsKey($name)){throw ('Missing installed release consumer '+$name)}}
$tooLong=Join-Path ([IO.Path]::GetTempPath()) ('wsm-release-long-'+[guid]::NewGuid().ToString('N')+('x'*100))
$rejected=$false;try{Initialize-WsmWizardWorkspace -Workspace $tooLong -Role Manager|Out-Null}catch{$rejected=$_.Exception.Message -match 'WorkRoot initialization exceeds supported Windows PowerShell 5.1 path limits'}
if(-not $rejected -or [IO.Directory]::Exists($tooLong)){throw 'Overlong workspace was not rejected before creating partial state.'}
$work=Join-Path ([IO.Path]::GetTempPath()) ('wsm-release-work-'+[guid]::NewGuid().ToString('N').Substring(0,12))
Initialize-WsmWizardWorkspace -Workspace $work -Role Manager|Out-Null
$before=Get-WsmWizardState -Workspace $work -Role Manager
$saved=Set-WsmWizardState -Workspace $work -Role Manager -ExpectedWizardRevision $before.Revision -Changes ([pscustomobject]@{CurrentStep='prepare'})
$read=Get-WsmWizardState -Workspace $work -Role Manager
if($read.CurrentStep -cne 'prepare' -or $read.Revision -ne ($before.Revision+1)){throw 'Extracted release did not save and read back real wizard state.'}
$entry=Join-Path $Root 'Start-ServerMigration.ps1'
& $entry -Action Capabilities -Workspace $work|Out-Null
if($LASTEXITCODE -and $LASTEXITCODE -ne 0){throw 'Actual extracted PowerShell launcher failed.'}
[IO.File]::WriteAllText($ResultPath,(@{Status='Passed';Root=$Root;WorkRoot=$work;OverlongWorkRootRejectedBeforeWrite=$rejected;Is64Bit=[Environment]::Is64BitProcess;PowerShell=$PSVersionTable.PSVersion.ToString();Revision=$read.Revision;Step=$read.CurrentStep;ToolFingerprint=(& $m {Get-WsmToolFingerprint});NativeHttp='NotProvenByThisSmoke';ProductionVerified=$false}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
'@
[IO.File]::WriteAllText($probePath,$probe,(New-Object Text.UTF8Encoding($true)))
$resultPath=Join-Path $ownedRoot 'extracted-result.json'
$engine=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $engine -NoProfile -File $probePath -Root $extracted -ResultPath $resultPath
if($LASTEXITCODE -ne 0){throw 'Extracted release smoke failed.'}
$result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$result.Root -cne $extracted){throw 'Extracted Chinese/space path did not round-trip exactly through the real launcher result.'}
if(-not $result.Is64Bit -or $result.ToolFingerprint -cne $release.ToolFingerprint){throw 'Extracted runtime architecture or fingerprint differs.'}
[IO.File]::WriteAllText((Join-Path $ownedRoot 'release-evidence.json'),(@{Archive=$archivePath;SHA256=$release.SHA256;ToolFingerprint=$release.ToolFingerprint;FileCount=$projection.FileCount;Signed=$false;Result=$result}|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
Write-Output ('PASS exact ZIP/extracted module/state/PowerShell launcher smoke: '+$ownedRoot+'; native HTTP/browser and CMD full-page journey remain separate acceptance.')
