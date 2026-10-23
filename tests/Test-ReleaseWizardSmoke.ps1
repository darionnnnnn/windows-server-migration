#requires -Version 5.1
[CmdletBinding()]param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$nativeEvidencePath=$env:WSM_NATIVE_EVIDENCE_PATH
$nativeEvidence=$null
function Save-NativeEvidence {
    param($Record)
    if(-not $nativeEvidencePath){return}
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($nativeEvidencePath))
    [void][IO.Directory]::CreateDirectory($parent)
    $temp=$nativeEvidencePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($Record|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $nativeEvidencePath -Force
}
if($nativeEvidencePath){
    $sourceCommit=$env:GITHUB_SHA
    if($sourceCommit -notmatch '^[a-fA-F0-9]{40}$'){throw 'Release smoke CI evidence requires the full source commit SHA.'}
    if($env:WSM_NATIVE_EVIDENCE_ENGINE -ne 'powershell'){throw 'Release package smoke evidence requires Windows PowerShell 5.1.'}
    $runId=$env:GITHUB_RUN_ID+'-'+$env:GITHUB_RUN_ATTEMPT
    $nativeEvidence=[ordered]@{schemaVersion=1;status='Running';suite='native-release-package';engine='powershell';engineVersion=$PSVersionTable.PSVersion.ToString();runtime=$PSVersionTable.PSVersion.ToString();edition=$PSVersionTable.PSEdition;processArchitecture=$(if([Environment]::Is64BitProcess){'x64'}else{'x86'});transport='release-module-smoke';mode='release-smoke';sourceCommit=$sourceCommit;runId=$runId;measure='completed-journeys';expectedJourneyCount=1;completedJourneyCount=0;completedJourneys=@();fixtureLimits=[ordered]@{productionQualification=$false;liveWorkloads=$false;extractedReleaseModule=$true;testOnlyWorkspace=$true;fullGOfflineJourney=$false};startedUtc=[DateTime]::UtcNow.ToString('o')}
    Save-NativeEvidence $nativeEvidence
}
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
$pathSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach($p in $paths){[void]$pathSet.Add([string]$p)}
[void]$pathSet.Add('release.json')

# ---- Required files are derived from the repository's tracked file list, not from a hand-written list. -------------------------
# Rule mirrors what the package is meant to carry: src top-level scripts/module/manifest, src/ui assets, root docs (md/html/css/js),
# docs/html pages (html/css) minus the PLAN pages, the two launchers, README and the two JSON documents.
$trackedSource='git ls-files'
$tracked=@()
$gitCommand=Get-Command git -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
if($gitCommand){
    $previousPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try{$tracked=@(& $gitCommand.Source -C $repository -c core.quotepath=off ls-files 2>$null|ForEach-Object {([string]$_).Replace('\','/')});if($LASTEXITCODE -ne 0){$tracked=@()}}finally{$ErrorActionPreference=$previousPreference}
}
if($tracked.Count -lt 50){
    # No git (or not a work tree): fall back to the files on disk and say so in the output.
    $trackedSource='filesystem-fallback'
    $tracked=@(Get-ChildItem -LiteralPath $repository -Recurse -File|ForEach-Object {$_.FullName.Substring($repository.Length+1).Replace('\','/')}|Where-Object {$_ -cmatch '^(src|docs)/' -or $_ -cmatch '^[^/]+$'}|Where-Object {$_ -cnotmatch '^docs/(archive|plans)/'})
}
$requiredSrc=@($tracked|Where-Object {$_ -cmatch '^src/[^/]+\.(ps1|psm1|psd1)$'})
$requiredUi=@($tracked|Where-Object {$_ -cmatch '^src/ui/.+\.(html|css|js)$'})
$requiredDocs=@($tracked|Where-Object {($_ -cmatch '^docs/[^/]+\.(md|html|css|js)$' -or $_ -cmatch '^docs/html/[^/]+\.(html|css)$') -and ([IO.Path]::GetFileName($_)) -cnotmatch '^MIGRATION-.*-PLAN\.html$'})
$requiredFixed=@('Start-ServerMigration.ps1','README.md','docs/RELEASE-SBOM.json','docs/SUPPORT-MATRIX.json','release.json')
if($tracked -ccontains 'Start-ServerMigration.cmd'){$requiredFixed+=@('Start-ServerMigration.cmd')}
# Floors guard against an emptied tracked list silently shrinking the check; the five R7 UI assets and the HTML manual index must be present.
foreach($anchor in @('src/ui/index.html','src/ui/console.js','src/ui/console.css','src/ui/nonc.js','src/ui/guide.html','docs/html/index.html','src/WizardBackup.ps1','src/WizardRestore.ps1','src/SourceCandidateDiscovery.ps1')){if(($requiredSrc+$requiredUi+$requiredDocs) -cnotcontains $anchor){throw ('Tracked file list does not contain the expected anchor '+$anchor+'; the derivation source ('+$trackedSource+') is not trustworthy.')}}
if($requiredSrc.Count -lt 90 -or $requiredUi.Count -lt 5 -or $requiredDocs.Count -lt 15){throw 'Tracked file derivation produced an implausibly small required set.'}
$required=@($requiredSrc+$requiredUi+$requiredDocs+$requiredFixed|Sort-Object -Unique)
foreach($file in $required){if(-not $pathSet.Contains($file)){throw ('Release omitted '+$file)}}
# The package must not carry untracked product files either (a private or generated file slipping into src or src/ui).
foreach($path in $paths){if($path -cmatch '^src/' -and $tracked -cnotcontains $path){throw ('Release contains an untracked src file '+$path)}}
$excludedPattern='(^|/)(archive|plans|work|tests)/|MIGRATION-.*-PLAN\.html$|-PLAN\.html$|Get-ServerMigrationInventory\.ps1$|(^|/)\.git(/|$)'
if(@($paths|Where-Object {$_ -match $excludedPattern}).Count){throw 'Release contains excluded planning, private or runtime-test inputs.'}
$extracted=Join-Path $ownedRoot '離線工具 Chinese spaces'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($archivePath,$extracted)
foreach($row in $projection.Index.Files){$file=Join-Path $extracted $row.Path;if(-not [IO.File]::Exists($file) -or (Get-Item -LiteralPath $file).Length -ne $row.Bytes -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $row.SHA256){throw ('Extracted byte mismatch '+$row.Path)}}
$extractedFull=[IO.Path]::GetFullPath($extracted).TrimEnd('\')
$onDisk=@(Get-ChildItem -LiteralPath $extractedFull -Recurse -File -Force|ForEach-Object {$_.FullName.Substring($extractedFull.Length+1).Replace('\','/')})
$strays=@($onDisk|Where-Object {-not $pathSet.Contains($_)});if($strays.Count){throw ('Extracted tree has files the release index does not list: '+($strays -join ', '))}
$missingOnDisk=@($paths|Where-Object {$onDisk -cnotcontains $_});if($missingOnDisk.Count){throw ('Extracted tree lacks indexed files: '+($missingOnDisk -join ', '))}
if(@($onDisk|Where-Object {$_ -match $excludedPattern}).Count){throw 'Extracted tree contains excluded planning, private or runtime-test inputs.'}

# ---- Every local href/src/link in the packaged HTML (and url()/@import in packaged CSS) must resolve inside the package. -------
# External resources (CDN scripts, remote fonts, remote stylesheets, images) are rejected; only plain <a href> reference links to external
# documentation are tolerated, because they are navigation and not loaded by the page. Server-absolute /ui/ and /docs/ references are what
# the local console serves, so they map to src/ui and docs.
function Resolve-ReleaseReference {
    param([string]$From,[string]$Value)
    $v=$Value.Trim()
    if($v -eq '' -or $v.StartsWith('#')){return $null}
    if([regex]::IsMatch($v,'^(mailto|javascript|data|about|tel):',[Text.RegularExpressions.RegexOptions]::IgnoreCase)){return $null}
    $v=($v -split '[?#]',2)[0]
    if($v -eq ''){return $null}
    $v=[Uri]::UnescapeDataString($v)
    if($v.StartsWith('/')){
        if($v.StartsWith('/ui/')){return ('src/ui/'+$v.Substring(4))}
        if($v.StartsWith('/docs/')){return ('docs/'+$v.Substring(6))}
        throw ('Unmapped server-absolute reference '+$Value+' in '+$From)
    }
    $dir=[IO.Path]::GetDirectoryName($From.Replace('/','\'))
    $full=[IO.Path]::GetFullPath((Join-Path (Join-Path $extractedFull $dir) $v.Replace('/','\')))
    if(-not $full.StartsWith($extractedFull+'\',[StringComparison]::OrdinalIgnoreCase)){throw ('Reference escapes the package: '+$Value+' in '+$From)}
    $full.Substring($extractedFull.Length+1).Replace('\','/')
}
function Test-ExternalReference([string]$Value){[regex]::IsMatch($Value.Trim(),'^([a-zA-Z][a-zA-Z0-9+.-]*:)?//|^(https?|ftp|ws|wss):',[Text.RegularExpressions.RegexOptions]::IgnoreCase)}
$htmlFiles=@($paths|Where-Object {$_ -cmatch '\.html$'});$cssFiles=@($paths|Where-Object {$_ -cmatch '\.css$'})
$tagRegex=New-Object Text.RegularExpressions.Regex('<(?<tag>[a-zA-Z][a-zA-Z0-9]*)(?<attrs>\s[^>]*)?>',[Text.RegularExpressions.RegexOptions]::Singleline)
$attrRegex=New-Object Text.RegularExpressions.Regex('(?<![\w-])(?<name>href|src|action|formaction|poster)\s*=\s*(?:"(?<v>[^"]*)"|''(?<v>[^'']*)'')',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
$htmlLocalRefs=0;$htmlExternalNav=0
foreach($htmlPath in $htmlFiles){
    $text=[IO.File]::ReadAllText((Join-Path $extractedFull $htmlPath.Replace('/','\')),[Text.Encoding]::UTF8)
    foreach($tag in $tagRegex.Matches($text)){
        foreach($attr in $attrRegex.Matches([string]$tag.Groups['attrs'].Value)){
            $value=[string]$attr.Groups['v'].Value;$tagName=[string]$tag.Groups['tag'].Value;$attrName=[string]$attr.Groups['name'].Value
            if(Test-ExternalReference $value){
                if($tagName -ieq 'a' -and $attrName -ieq 'href'){$htmlExternalNav++;continue}
                throw ('Packaged HTML loads an external resource: <'+$tagName+' '+$attrName+'="'+$value+'"> in '+$htmlPath)
            }
            $target=Resolve-ReleaseReference $htmlPath $value
            if($null -eq $target){continue}
            if(-not $pathSet.Contains($target)){throw ('Packaged HTML references a target missing from the release: '+$value+' -> '+$target+' in '+$htmlPath)}
            $htmlLocalRefs++
        }
    }
}
$cssLocalRefs=0
foreach($cssPath in $cssFiles){
    $text=[IO.File]::ReadAllText((Join-Path $extractedFull $cssPath.Replace('/','\')),[Text.Encoding]::UTF8)
    $values=@();foreach($mt in [regex]::Matches($text,'url\(\s*([''"]?)(?<v>[^)''"]+)\1\s*\)')){$values+=@([string]$mt.Groups['v'].Value)};foreach($mt in [regex]::Matches($text,'@import\s+[''"](?<v>[^''"]+)[''"]')){$values+=@([string]$mt.Groups['v'].Value)}
    foreach($value in $values){
        if(Test-ExternalReference $value){throw ('Packaged CSS loads an external resource: '+$value+' in '+$cssPath)}
        $target=Resolve-ReleaseReference $cssPath $value
        if($null -eq $target){continue}
        if(-not $pathSet.Contains($target)){throw ('Packaged CSS references a target missing from the release: '+$value+' -> '+$target+' in '+$cssPath)}
        $cssLocalRefs++
    }
}
$htmlReferenceCount=$htmlLocalRefs+$cssLocalRefs
if($htmlFiles.Count -lt 10 -or $htmlLocalRefs -lt 20){throw 'HTML reference scan saw an implausibly small package; the scan did not exercise the real pages.'}

$probePath=Join-Path $ownedRoot 'verify-extracted.ps1'
$probe=@'
param([string]$Root,[string]$ResultPath)
$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path $Root 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
foreach($name in @('Invoke-WsmWizardStartBackup','Get-WsmWizardRuntimeProjection','Get-WsmWizardNonCPreparation','Import-WsmWizardNonCTargetHandoff','Get-WsmWizardTargetRestoreProjection')){if(-not $m.ExportedCommands.ContainsKey($name)){throw ('Missing installed release consumer '+$name)}}
# Exports: every function the manifest declares and every function the HTML console / operation-request action tables run must be exported by the installed module.
$manifest=Import-PowerShellDataFile -LiteralPath (Join-Path $Root 'src\WindowsServerMigration.psd1')
$declared=@($manifest.FunctionsToExport|Sort-Object -Unique)
$exported=@($m.ExportedFunctions.Keys|Sort-Object -Unique)
$notExported=@($declared|Where-Object {$exported -cnotcontains $_});if($notExported.Count){throw ('Installed module does not export declared functions: '+($notExported -join ', '))}
$htmlMap=& $m {Get-WsmHtmlActionMap};$coreMap=& $m {Get-WsmOperationActions}
$actionNames=New-Object 'System.Collections.Generic.List[string]'
foreach($key in @($htmlMap.Keys)){$value=$htmlMap[$key];if($value -is [array]){$actionNames.Add([string]$value[1])}else{$actionNames.Add([string]$value)}}
foreach($key in @($coreMap.Keys)){$actionNames.Add([string]$coreMap[$key])}
$inline=@('Set-WsmHtmlRestoreChoice','Set-WsmHtmlSelection')
$actionCommands=@($actionNames|Sort-Object -Unique|Where-Object {$_ -and $inline -cnotcontains $_})
$missingActions=@($actionCommands|Where-Object {$exported -cnotcontains $_});if($missingActions.Count){throw ('Installed module does not export action-table commands: '+($missingActions -join ', '))}
if($actionCommands.Count -lt 150){throw 'Action tables were unexpectedly small; the export check did not see the real tables.'}
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
[IO.File]::WriteAllText($ResultPath,(@{Status='Passed';Root=$Root;WorkRoot=$work;OverlongWorkRootRejectedBeforeWrite=$rejected;Is64Bit=[Environment]::Is64BitProcess;PowerShell=$PSVersionTable.PSVersion.ToString();Revision=$read.Revision;Step=$read.CurrentStep;ToolFingerprint=(& $m {Get-WsmToolFingerprint});NativeHttp='NotProvenByThisSmoke';ProductionVerified=$false;ExportedFunctions=$exported;DeclaredExportCount=$declared.Count;ActionCommandCount=$actionCommands.Count}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
'@
[IO.File]::WriteAllText($probePath,$probe,(New-Object Text.UTF8Encoding($true)))
$resultPath=Join-Path $ownedRoot 'extracted-result.json'
$engine=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $engine -NoProfile -File $probePath -Root $extracted -ResultPath $resultPath
if($LASTEXITCODE -ne 0){throw 'Extracted release smoke failed.'}
$result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$result.Root -cne $extracted){throw 'Extracted Chinese/space path did not round-trip exactly through the real launcher result.'}
if(-not $result.Is64Bit -or $result.ToolFingerprint -cne $release.ToolFingerprint){throw 'Extracted runtime architecture or fingerprint differs.'}
# The installed module must export exactly what the working-tree module exports.
$repoExports=@($module.ExportedFunctions.Keys|Sort-Object -Unique);$packageExports=@($result.ExportedFunctions|Sort-Object -Unique)
$exportDiff=@(Compare-Object $repoExports $packageExports);if($exportDiff.Count){throw ('Installed module exports differ from the working tree: '+(($exportDiff|Select-Object -First 8|ForEach-Object {[string]$_.InputObject+$_.SideIndicator}) -join ', '))}
$exportCount=$packageExports.Count
$resultSummary=[ordered]@{Status=[string]$result.Status;Root=[string]$result.Root;WorkRoot=[string]$result.WorkRoot;OverlongWorkRootRejectedBeforeWrite=$result.OverlongWorkRootRejectedBeforeWrite;Is64Bit=$result.Is64Bit;PowerShell=[string]$result.PowerShell;Revision=$result.Revision;Step=[string]$result.Step;ToolFingerprint=[string]$result.ToolFingerprint;NativeHttp=[string]$result.NativeHttp;ProductionVerified=$result.ProductionVerified;DeclaredExportCount=$result.DeclaredExportCount;ActionCommandCount=$result.ActionCommandCount}

# ---- Small backup-to-restore flow on the extracted tool root. ---------------------------------------------------------------------
# NOT the full G offline journey: no HTTP console, no browser, no credential dialog, no multi-volume ZIP, one small FileScope fixture,
# and identity/preflight/inventory observations are substituted. The full journey runs on the working-tree snapshot.
$journeyPath=Join-Path $ownedRoot 'verify-extracted-journey.ps1'
$journeyProbe=@'
param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path $Root 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$base=Join-Path 'C:\Users\Public' ('n9b'+[guid]::NewGuid().ToString('N').Substring(0,6))
if([IO.Directory]::Exists($base)){throw 'Refusing to reuse a journey directory.'}
[void][IO.Directory]::CreateDirectory($base)
try{
& $m {
    param($Base,$ResultPath)
    $ErrorActionPreference='Stop'
    $script:steps=New-Object 'System.Collections.Generic.List[string]'
    function Step([string]$Name){$script:steps.Add($Name);Write-Host ('  journey step: '+$Name)}
    function Check($Condition,[string]$Message){if(-not $Condition){throw $Message}}
    function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
    $script:role='Manager'
    $script:ids=@{}
    function script:Get-WsmMachineIdentity {$script:ids[$script:role]}
    function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
    $script:ids.Manager=[pscustomobject]@{HostId=[guid]::NewGuid().ToString();Fingerprint=('c'*64);Name='journey-manager';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
    $script:ids.Source=[pscustomobject]@{HostId=[guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='journey-source';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
    $script:ids.Target=[pscustomobject]@{HostId=[guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='journey-target';OS='Fixture Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
    $srcWork=Join-Path $Base 's';$tgtWork=Join-Path $Base 't';$mgrWork=Join-Path $Base 'm'
    $script:role='Source';$srcEnroll=Initialize-WsmOutputWorkspace $srcWork Source
    $script:role='Target';$tgtEnroll=Initialize-WsmOutputWorkspace $tgtWork Target
    $script:ids.Source.HostId=[string]$srcEnroll.Profile.HostId;$script:ids.Target.HostId=[string]$tgtEnroll.Profile.HostId
    $source=$script:ids.Source;$target=$script:ids.Target
    # fixture data
    $data=Join-Path $Base 'src-data';[void][IO.Directory]::CreateDirectory($data);[void][IO.Directory]::CreateDirectory((Join-Path $data 'sub'))
    $bytesA=New-Object byte[] 300000;(New-Object Random 9).NextBytes($bytesA);[IO.File]::WriteAllBytes((Join-Path $data 'a.bin'),$bytesA)
    $bytesB=[Text.Encoding]::UTF8.GetBytes('release smoke nested payload');[IO.File]::WriteAllBytes((Join-Path $data 'sub\b.txt'),$bytesB)
    $restored=Join-Path $Base 'restored'
    $drive=[IO.Path]::GetPathRoot($data).TrimEnd('\')
    $vol=Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop | Where-Object {$_.DriveLetter -and ([string]$_.DriveLetter).TrimEnd('\') -ieq $drive} | Select-Object -First 1
    if(-not $vol){throw 'No drive-lettered Win32_Volume for the journey fixture.'}
    $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$data;TargetPath=$data;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='fixture';Evidence='release smoke';TransferChannel='C';ContentSelection='WholeScope'}
    Assert-WsmMigrationSpec $spec -Assistive
    $items=@((New-WsmItem $source.HostId Storage Volume ([string]$vol.DeviceID) ([string]$vol.DeviceID) ([pscustomobject]@{DeviceID=[string]$vol.DeviceID;DriveLetter=[string]$vol.DriveLetter;Label=[string]$vol.Label;FileSystem=[string]$vol.FileSystem;Capacity=[long]$vol.Capacity}) @() Success Volume),(New-WsmItem $source.HostId Storage FileScope 'Journey scope' 'journey-scope' ([pscustomobject]@{SourcePath=$data;TargetPath=$data}) @() Success FileScope))
    $inventory=New-WsmInventory $source 1 $items
    $entry=[pscustomobject][ordered]@{SoftwareId=('sw-'+'c1'.PadLeft(32,'0'));Name='Journey Product';Version='2.0.0';Publisher='Fixture';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location='fixture:Journey';SourceKind='Registry';Evidence=[pscustomobject]@{Probe='Uninstall'};ObservedUtc=[DateTime]::UtcNow.ToString('o');CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
    $catalogSw=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$source.HostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=''};CaptureContext=[pscustomobject]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($entry);Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=[DateTime]::UtcNow.ToString('o')});PreparationRequirements=@([pscustomobject]@{PreparationId=('prep-'+$entry.SoftwareId.Substring(3));SoftwareId=$entry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus=$entry.CaptureStatus;ConsumerItemIds=@();Owner='';Reason='journey evidence only.'});CatalogProjectionHash=('0'*64)}
    $inventory|Add-Member NoteProperty SoftwareCatalog $catalogSw
    $catalogSw.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $inventory
    $catalogSw.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalogSw
    Assert-WsmSoftwareCatalog $catalogSw -SourceInventory $inventory|Out-Null
    $invPath=Join-Path $Base 'source-inventory.json';Write-WsmJson $invPath $inventory;$invHash=Sha $invPath
    # Manager approval
    $script:role='Manager'
    Initialize-WsmWorkspace $mgrWork|Out-Null
    Import-WsmInventory -Workspace $mgrWork -Path $invPath -ExpectedHash $invHash -TargetName 'journey-target'|Out-Null
    $pairId=[string]((Get-WsmFleet $mgrWork).Pairs[0].PairId)
    $cat=Get-WsmCatalog $mgrWork $pairId
    Enable-WsmAssistiveMode $mgrWork $pairId $cat.DecisionRevision|Out-Null
    $cat=Get-WsmCatalog $mgrWork $pairId
    $scopeItem=@($cat.Items|Where-Object Kind -CEQ 'FileScope')[0];$volItem=@($cat.Items|Where-Object Kind -CEQ 'Volume')[0]
    Set-WsmDecision -Workspace $mgrWork -PairId $pairId -ItemId $volItem.ItemId -Decision Exclude -Reason 'Volume is evidence only.' -ExpectedRevision $cat.DecisionRevision|Out-Null
    $cat=Get-WsmCatalog $mgrWork $pairId
    Set-WsmDecision -Workspace $mgrWork -PairId $pairId -ItemId $scopeItem.ItemId -Decision Include -Reason 'Owner reviewed journey scope.' -ExpectedRevision $cat.DecisionRevision|Out-Null
    $cat=Get-WsmCatalog $mgrWork $pairId
    $specPath=Join-Path $Base 'spec.json';Write-WsmJson $specPath $spec
    Set-WsmMigrationSpec $mgrWork $pairId $scopeItem.ItemId $specPath (Sha $specPath) $cat.DecisionRevision|Out-Null
    $cat=Get-WsmCatalog $mgrWork $pairId
    $tIdPath=Join-Path $tgtWork ('targets\'+$tgtEnroll.HostId+'\target-identity.json')
    $approval=Approve-WsmMigrationPlan -Workspace $mgrWork -PairId $pairId -TargetIdentityPath $tIdPath -TargetIdentityHash (Sha $tIdPath) -Path (Join-Path $Base 'approved-plan.json') -ExpectedRevision $cat.DecisionRevision -PilotAcknowledgement 'ISOLATED-PILOT' -OfflineFullSet
    Step 'manager-approve-cv2'
    # Source: import plan, one-click backup
    $script:role='Source'
    $imp=Import-WsmWizardApprovedPlan $srcWork Source $approval.Path $approval.SHA256
    Check ($imp.Status -ceq 'ImportedVerified') 'Source did not import the CV2 plan.'
    $script:freshInv=[pscustomobject]@{Path=$invPath;SHA256=$invHash}
    function script:Export-WsmInventory {param($OutputDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog,$SourceStateDirectory)$script:freshInv}
    $op=[guid]::NewGuid().ToString('D');$tok=New-WsmCancellationToken -StateDirectory (Join-Path $srcWork 'pairs') -PairId $pairId -PlanHash $approval.SHA256 -OperationId $op
    $backup=Invoke-WsmWizardStartBackup -Workspace $srcWork -PairId $pairId -OperationId $op -DeliveryMode Directory -VolumeBytes 0 -Jobs @() -CancellationToken $tok
    Check ($backup.Status -ceq 'Delivered' -and $backup.PackageTest.Valid) 'CV2 one-click backup was not delivered and verified.'
    Step 'source-one-click-backup'
    $dest=Join-Path $Base 'media';[void][IO.Directory]::CreateDirectory($dest)
    $script:mediaClass='Removable'
    function script:Get-WsmIndependentCopyMediaClass {param($DestinationRoot)$script:mediaClass}
    $copy=Invoke-WsmWizardIndependentCopy -Workspace $srcWork -PairId $pairId -BackupOperationId $op -OperationId ([guid]::NewGuid().ToString('D')) -DestinationRoot $dest -Mode Copy
    Check ($copy.IndependentCopy.Status -ceq 'Verified') 'Independent copy was not verified.'
    Step 'independent-copy'
    $summary=@(Get-ChildItem -LiteralPath (Join-Path $copy.IndependentCopy.CopyRoot 'transport') -Filter 'delivery-*.json' -File)[0].FullName
    $summaryHash=Sha $summary
    Check ($summaryHash -ceq [string]$backup.Delivery.SHA256) 'Independent copy summary differs from the delivered summary.'
    $copyDir=Join-Path (Join-Path $copy.IndependentCopy.CopyRoot 'transport') 'delivery'
    # Simulate a new machine: the original source data is removed before the Target restores it.
    $beforeHashes=@{};foreach($f in @(Get-ChildItem -LiteralPath $data -Recurse -File)){$beforeHashes[$f.FullName.Substring($data.Length)]=Sha $f.FullName}
    Check ($beforeHashes.Count -eq 2) 'Journey fixture did not contain the two expected files.'
    Remove-Item -LiteralPath $data -Recurse -Force
    $script:role='Target'
    $timp=Import-WsmWizardApprovedPlan $tgtWork Target $approval.Path $approval.SHA256
    Check ($timp.Status -ceq 'ImportedVerified') 'Target did not import the CV2 plan.'
    $tok2=New-WsmWizardTargetPackageCancellation -Workspace $tgtWork -PairId $pairId -Action DirectoryImport -Path $summary -ExpectedHash $summaryHash -OperationId ([guid]::NewGuid().ToString())
    $dimp=Import-WsmWizardTargetDirectoryPackage -Workspace $tgtWork -PairId $pairId -SummaryPath $summary -ExpectedSummaryHash $summaryHash -SourceDirectory $copyDir -OperationId $tok2.OperationId -CancellationToken $tok2
    Check ($dimp.Status -ceq 'Succeeded') 'Target directory import of the independent copy did not succeed.'
    Step 'target-import-independent-copy'
    $pkgJob=[pscustomobject]@{status='Succeeded';action='DirectoryImport';role='Target';pairId=$pairId;workspace=$tgtWork;jobId=[guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Valid=$true;ManifestPath=$dimp.ManifestPath;ManifestHash=$dimp.ManifestHash;PairId=$pairId;PlanHash=$approval.SHA256;Generation=$dimp.Generation;AttemptId=$dimp.AttemptId})}
    $coverage=@([pscustomobject][ordered]@{Probe='FixtureComplete';Scope='Machine';SID='';View='All';Status='Success';EvidenceKind='FixtureObservation';Count=0;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind=$null;ItemId='';ObservedUtc=(Get-WsmUtc)})
    $tInv=New-WsmInventory $target 7 @()
    $tSw=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$target.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;InventoryRevision=7;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $tInv)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='isolated native observation fixture';AccountContext='System';CaptureHost='local fixture';PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=''}
    $tSw.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $tSw
    $tInv|Add-Member NoteProperty SoftwareCatalog $tSw -Force
    Assert-WsmSoftwareCatalog $tSw -SourceInventory $tInv|Out-Null
    function script:Get-WsmAssistiveCurrentSoftwareCatalog($Snapshot){$Snapshot.SoftwareCatalog}
    $invDir=Join-Path (Join-Path (Join-Path $tgtWork ('hosts\'+$target.Fingerprint)) 'inventory') ''
    [void](New-WsmOutputOwnedDirectory $invDir);$tInvPath=Join-Path $invDir 'inventory-7.json';Write-WsmJson $tInvPath $tInv;$tInvHash=Sha $tInvPath
    $invJob=[pscustomobject]@{status='Succeeded';action='Inventory';role='Target';workspace=$tgtWork;jobId=[guid]::NewGuid().ToString();outputs=@([pscustomobject]@{Path=$tInvPath;SHA256=$tInvHash})}
    $jobs=@($invJob,$pkgJob)
    $cmp=New-WsmWizardTargetLocalComparison -Workspace $tgtWork -PairId $pairId -Jobs $jobs
    Check ($cmp.Status -ceq 'Succeeded' -and $cmp.Provenance -ceq 'TargetLocal') 'Target local comparison did not succeed.'
    Step 'target-local-comparison'
    $jobs+=@([pscustomobject]@{action='TargetLocalComparison';status='Succeeded';role='Target';pairId=$pairId;workspace=$tgtWork;jobId=[guid]::NewGuid().ToString();CompletedUtc=(Get-WsmUtc);outputs=@($cmp)})
    $plan=Read-WsmJson $approval.Path
    $selected=@($plan.Items|Where-Object Decision -CEQ 'Include'|ForEach-Object {[string]$_.ItemId})
    Check ($selected.Count -eq 1) 'Approved plan did not contain exactly the one included fixture scope.'
    $rec=Create-WsmWizardTargetDecisionReceipt -Workspace $tgtWork -PairId $pairId -Decision RestoreNow -Owner 'Journey operator' -Reason 'Release smoke restore of the small fixture' -SelectedItemIds $selected -Jobs $jobs
    $preview=Get-WsmWizardTargetRestoreProjection -Workspace $tgtWork -PairId $pairId -Jobs $jobs
    Check ($preview.Status -ceq 'Previewed' -and $preview.PreviewHash) ('Target restore preview was not available: '+$preview.Status)
    Check (-not [IO.Directory]::Exists($data)) 'The restore preview already wrote to the Target.'
    Step 'target-restore-preview'
    $res=Invoke-WsmWizardTargetRestore -Workspace $tgtWork -PairId $pairId -PreviewHash $preview.PreviewHash -Jobs $jobs
    $afterHashes=@{};foreach($f in @(Get-ChildItem -LiteralPath $data -Recurse -File)){$afterHashes[$f.FullName.Substring($data.Length)]=Sha $f.FullName}
    Check ($afterHashes.Count -eq $beforeHashes.Count) 'Restored file count differs from the backed-up fixture.'
    foreach($k in $beforeHashes.Keys){Check ($afterHashes.ContainsKey($k) -and $afterHashes[$k] -ceq $beforeHashes[$k]) ('Restored bytes differ for '+$k)}
    Check ([IO.File]::ReadAllBytes((Join-Path $data 'a.bin')).Length -eq 300000) 'Restored a.bin length differs.'
    Step 'target-restore-byte-identical'
    $out=[ordered]@{Status='Passed';Steps=@($script:steps);RestoreStatus=[string]$res.Status;FilesCompared=$beforeHashes.Count;Note='Not the full G offline journey; the full journey runs on the working-tree snapshot.'}
    [IO.File]::WriteAllText($ResultPath,($out|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
}  $base $ResultPath
}finally{
    $full=[IO.Path]::GetFullPath($base)
    if($full -like 'C:\Users\Public\n9b*' -and [IO.Directory]::Exists($full)){Remove-Item -LiteralPath $full -Recurse -Force}
}
'@
[IO.File]::WriteAllText($journeyPath,$journeyProbe,(New-Object Text.UTF8Encoding($true)))
$journeyResultPath=Join-Path $ownedRoot 'extracted-journey-result.json'
& $engine -NoProfile -File $journeyPath -Root $extracted -ResultPath $journeyResultPath
if($LASTEXITCODE -ne 0){throw 'Small backup-to-restore flow on the extracted release failed.'}
$journey=Get-Content -LiteralPath $journeyResultPath -Raw -Encoding UTF8|ConvertFrom-Json
$expectedSteps=@('manager-approve-cv2','source-one-click-backup','independent-copy','target-import-independent-copy','target-local-comparison','target-restore-preview','target-restore-byte-identical')
if([string]$journey.Status -cne 'Passed' -or (@($journey.Steps) -join ',') -cne ($expectedSteps -join ',') -or [int]$journey.FilesCompared -lt 2 -or [string]$journey.RestoreStatus -cne 'Succeeded'){throw 'Small backup-to-restore flow did not report every step with byte-identical restored files.'}
[IO.File]::WriteAllText((Join-Path $ownedRoot 'release-evidence.json'),(@{Archive=$archivePath;SHA256=$release.SHA256;ToolFingerprint=$release.ToolFingerprint;FileCount=$projection.FileCount;Signed=$false;Result=$resultSummary;Counts=[ordered]@{Exports=$exportCount;ActionCommands=[int]$result.ActionCommandCount;RequiredFiles=$required.Count;RequiredFileSource=$trackedSource;HtmlFiles=$htmlFiles.Count;HtmlReferences=$htmlReferenceCount;HtmlExternalNavigationLinks=$htmlExternalNav};SmallFlow=[ordered]@{Status=[string]$journey.Status;Steps=@($journey.Steps);FilesCompared=[int]$journey.FilesCompared;Scope='Not the full G offline journey; the full journey runs on the working-tree snapshot.'}}|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
if($nativeEvidencePath){
    $nativeEvidence.status='Passed';$nativeEvidence.completedJourneyCount=1
    $nativeEvidence.toolFingerprint=$release.ToolFingerprint
    $nativeEvidence.completedJourneys=@(@{name='exact-release-archive-extraction-module-import-save-readback';toolFingerprint=$release.ToolFingerprint;archiveSHA256=$release.SHA256;fileCount=$projection.FileCount;exportCount=$exportCount;requiredFileCount=$required.Count;htmlReferenceCount=$htmlReferenceCount;smallBackupRestoreFlow='Passed';fullGOfflineJourney='NotRunOnPackage'})
    $nativeEvidence.finishedUtc=[DateTime]::UtcNow.ToString('o')
    Save-NativeEvidence $nativeEvidence
}
Write-Output ('Release smoke counts: exports='+$exportCount+' (action commands '+$result.ActionCommandCount+'), required files='+$required.Count+' (src '+$requiredSrc.Count+', ui '+$requiredUi.Count+', docs '+$requiredDocs.Count+', fixed '+$requiredFixed.Count+'; derived from '+$trackedSource+'), HTML files='+$htmlFiles.Count+', HTML references='+$htmlReferenceCount+' (local '+$htmlLocalRefs+', css '+$cssLocalRefs+', external navigation links tolerated '+$htmlExternalNav+'), small flow='+$journey.Status+' ('+@($journey.Steps).Count+' steps, '+$journey.FilesCompared+' files byte-compared).')
Write-Output 'Small backup-to-restore flow: this is NOT the complete G offline journey; the complete journey runs on the working-tree snapshot.'
Write-Output ('PASS exact ZIP/extracted module/state/PowerShell launcher smoke: '+$ownedRoot+'; native HTTP/browser and CMD full-page journey remain separate acceptance.')
