#requires -Version 5.1
# N9d / R7-04 / R7-05：混合套裝目錄的可見性。
# 安裝根仍整塊排除、不備份；這裡驗證「列出根內檔案並分類」只是可見性，沒有放寬任何防護，
# 同名 DLL 兩處都有標示，而且結果集與離線報告不會宣稱完整。
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wsm-n9d-'+[Guid]::NewGuid().ToString('N').Substring(0,8))))
if([IO.Directory]::Exists($tempRoot)){throw 'Refusing a pre-existing test directory.'}
[void][IO.Directory]::CreateDirectory($tempRoot)
$checks=0
function Check([bool]$Condition,[string]$Message) { $script:checks++;if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message) }
function ExpectFailure([scriptblock]$Action,[string]$Message) { $script:checks++;$failed=$false;try{& $Action}catch{$failed=$true};if(-not $failed){throw $Message};Write-Output ('PASS '+$Message) }
function New-PeBytes { [byte[]]$bytes=New-Object byte[] 256;$bytes[0]=0x4d;$bytes[1]=0x5a;[BitConverter]::GetBytes([int]128).CopyTo($bytes,60);$bytes[128]=0x50;$bytes[129]=0x45;$bytes }
$junction=$null
try {
    # ---------------------------------------------------------------- A. 自訂安裝目錄 fixture：exe、dll、報表 csv、設定檔混在一起
    $fixtureRoot=Join-Path $tempRoot 'v'
    $installRoot=Join-Path $fixtureRoot 'Vendor App'
    $siteRoot=Join-Path $fixtureRoot 'Site'
    foreach($dir in @('lib','Reports','data','Logs\2026')){[void][IO.Directory]::CreateDirectory((Join-Path $installRoot $dir))}
    [void][IO.Directory]::CreateDirectory($siteRoot)
    $oldTime=[DateTime]::new(2019,6,1,0,0,0,[DateTimeKind]::Utc)
    $write={param([string]$Relative,[byte[]]$Bytes,[bool]$IsOld=$true)$path=Join-Path $installRoot $Relative;[IO.File]::WriteAllBytes($path,$Bytes);if($IsOld){[IO.File]::SetLastWriteTimeUtc($path,$oldTime)}}
    $text={param([string]$Value)[Text.Encoding]::UTF8.GetBytes($Value)}
    & $write 'app.exe' (New-PeBytes)
    & $write 'lib\core.dll' (New-PeBytes)
    & $write 'lib\renamed.dat' (New-PeBytes)          # PE 內容、非 PE 副檔名：不能因副檔名被當成非本體
    & $write 'lib\fake.dll' (& $text 'this is not a PE file')   # PE 副檔名、非 PE 內容：不能因副檔名被當成本體
    & $write 'settings.config' (& $text '<configuration/>')
    & $write 'readme.md' (& $text 'readme')
    & $write 'Reports\sales.csv' (& $text 'a,b')
    & $write 'data\customers.db' (& $text 'rows')
    & $write 'Logs\2026\app.log' (& $text 'log')
    & $write 'unins000.dat' (& $text 'uninstall')
    & $write 'notes.txt' (& $text 'written after install') $false
    $outside=Join-Path $tempRoot 'outside';[void][IO.Directory]::CreateDirectory($outside);[IO.File]::WriteAllText((Join-Path $outside 'secret.txt'),'outside the install root')
    $junction=Join-Path $installRoot 'linked'
    [void](New-Item -ItemType Junction -Path $junction -Target $outside)
    $installTime=[DateTime]::new(2020,1,1,0,0,0,[DateTimeKind]::Utc)

    $contents=& $module { param($root,$time) Get-WsmSourceCandidateBundleContents $root 4000 25 4194304 $time } $installRoot $installTime
    Check ($contents.Complete -and -not $contents.IncompleteReason) 'a complete listing within budget is marked complete'
    Check ($contents.Counts.Bundle -eq 4 -and $contents.Counts.SuspectedBusinessData -eq 4 -and $contents.Counts.Unknown -eq 3) ('files are classified into bundle/suspected/unknown (bundle='+$contents.Counts.Bundle+' suspected='+$contents.Counts.SuspectedBusinessData+' unknown='+$contents.Counts.Unknown+')')
    Check ($contents.SkippedReparse -eq 1 -and -not @($contents.Samples|Where-Object RelativePath -Like '*secret*').Count -and -not (@($contents.BundleFiles)-join '|').Contains('secret')) 'a junction inside the install root is not followed'
    $byRelative=@{};foreach($sample in $contents.Samples){$byRelative[$sample.RelativePath]=$sample}
    Check ($byRelative['lib\renamed.dat'].Class -ceq 'Bundle' -and $byRelative['lib\renamed.dat'].Why -ceq 'PEHeader') 'a PE file is bundle by its header even with a non-PE extension'
    Check ($byRelative['lib\fake.dll'].Class -ceq 'Unknown') 'a .dll that is not a PE file is not treated as bundle'
    Check ($byRelative['unins000.dat'].Class -ceq 'Bundle' -and $byRelative['unins000.dat'].Why -ceq 'UninstallMetadata') 'installer uninstall metadata is bundle'
    Check ($byRelative['Reports\sales.csv'].Class -ceq 'SuspectedBusinessData' -and $byRelative['Reports\sales.csv'].Why -ceq 'DataDirectory:Reports' -and $byRelative['data\customers.db'].Class -ceq 'SuspectedBusinessData' -and $byRelative['Logs\2026\app.log'].Why -ceq 'DataDirectory:Logs') 'non-PE files under data/report/log directories are suspected business data (any depth, any case)'
    Check ($byRelative['notes.txt'].Class -ceq 'SuspectedBusinessData' -and $byRelative['notes.txt'].Why -ceq 'ModifiedAfterInstall' -and $contents.InstallTimeTrusted) 'a non-PE file modified after a trusted install time is suspected business data'
    Check ($byRelative['settings.config'].Class -ceq 'Unknown' -and $byRelative['readme.md'].Class -ceq 'Unknown') 'other files stay unknown'
    Check (@($contents.BundleFiles) -contains 'lib\core.dll' -and @($contents.BundleFiles) -contains 'app.exe') 'bundle file names are kept for same-name tracing'

    $noTime=& $module { param($root) Get-WsmSourceCandidateBundleContents $root } $installRoot
    Check (-not $noTime.InstallTimeTrusted -and $noTime.Counts.SuspectedBusinessData -eq 3 -and $noTime.Counts.Unknown -eq 4) 'without a trusted install time the modification-time signal is not used'
    $futureTime=& $module { param($root) Get-WsmSourceCandidateBundleContents $root 4000 25 4194304 ([DateTime]::UtcNow.AddYears(5)) } $installRoot
    Check (-not $futureTime.InstallTimeTrusted -and $futureTime.Counts.SuspectedBusinessData -eq 3) 'an implausible (future) install time is not trusted'
    $registered=& $module { param($root,$file) Get-WsmSourceCandidateBundleContents $root 4000 25 4194304 $null @($file) } $installRoot (Join-Path $installRoot 'settings.config')
    Check ($registered.Counts.Bundle -eq 5 -and @($registered.Samples|Where-Object {$_.RelativePath -ceq 'settings.config' -and $_.Why -ceq 'RegisteredByInstaller'}).Count -eq 1) 'a file registered by the installer is bundle'

    $entryBudget=& $module { param($root) Get-WsmSourceCandidateBundleContents $root 5 25 4194304 } $installRoot
    Check (-not $entryBudget.Complete -and $entryBudget.IncompleteReason -ceq 'EntryBudget' -and $entryBudget.Listed -eq 5) 'exceeding the entry budget marks the listing incomplete and records how many were listed'
    $byteBudget=& $module { param($root) Get-WsmSourceCandidateBundleContents $root 4000 25 2000 } $installRoot
    Check (-not $byteBudget.Complete -and $byteBudget.IncompleteReason -ceq 'PathBytesBudget' -and $byteBudget.Listed -gt 0 -and $byteBudget.Listed -lt 16) 'exceeding the path-byte budget marks the listing incomplete'
    $perClass=@($contents.Samples|Group-Object Class|ForEach-Object Count|Measure-Object -Maximum).Maximum
    Check ($perClass -le 10 -and $contents.SamplesPerClass -eq 10) 'samples are capped per class'

    # ---------------------------------------------------------------- B. 掃描產物：結構化欄位、同名 DLL 追溯、防護
    $scanWorkspace=Join-Path $tempRoot 'w';$null=Initialize-WsmOutputWorkspace -WorkRoot $scanWorkspace -Role Source
    $scanProfile=& $module { param($workspace) Read-WsmOutputProfile $workspace } $scanWorkspace
    $scanSource=& $module { param($p) [pscustomobject][ordered]@{HostId=[string]$p.HostId;Fingerprint=([string]$p.Fingerprint).ToLowerInvariant();Name='fixture-source';OS='fixture';Version=''} } $scanProfile
    $scanInventory=& $module { param($source) New-WsmInventory $source 1 @() } $scanSource
    [IO.File]::WriteAllBytes((Join-Path $siteRoot 'core.dll'),(New-PeBytes))      # 網站發布目錄內的同名 DLL（app-local 相依）
    [IO.File]::WriteAllText((Join-Path $siteRoot 'web.config'),'<configuration/>')
    $guardDir=Join-Path $fixtureRoot 'Windows.old';[void][IO.Directory]::CreateDirectory($guardDir);[IO.File]::WriteAllText((Join-Path $guardDir 'x.bin'),'x')
    $softwareId='sw-'+('d'*32);$now=[DateTime]::UtcNow.ToString('o')
    $softwareEntry=[pscustomobject][ordered]@{SoftwareId=$softwareId;Name='Fixture Runtime';Version='1';Publisher='Fixture';Architecture='Unknown';Scope='Machine';SID='';RegistryView='Registry64';Location=$installRoot;SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='HKLM:\Software\Fixture';NaturalKey='Fixture Runtime'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Machine'}
    $sourceProjectionHash=& $module { param($value) Get-WsmSoftwareInventoryProjectionHash $value } $scanInventory
    $softwareCatalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='fixture';Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$scanProfile.HostId;Fingerprint=$scanProfile.Fingerprint;Name='fixture';InventoryRevision=1;InventoryProjectionHash=$sourceProjectionHash};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=$now;CaptureIdentity='fixture';AccountContext='Machine';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($softwareEntry);Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind='';ObservedUtc=$now});PreparationRequirements=@([pscustomobject][ordered]@{PreparationId=('prep-'+$softwareId.Substring(3));SoftwareId=$softwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason=''})}
    $softwareCatalog|Add-Member NoteProperty CatalogProjectionHash (& $module { param($c) Get-WsmSoftwareCatalogProjectionHash $c } $softwareCatalog)
    $scanInventory|Add-Member NoteProperty SoftwareCatalog $softwareCatalog -Force
    $scanHash=& $module { param($value) Get-WsmHashText ($value|ConvertTo-Json -Depth 30 -Compress) } $scanInventory
    $runScan={param($maxEntries)
        $result=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId,$entries) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null $entries 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot '' $maxEntries
        $first=$result
        for($attempt=0;$attempt -lt 80 -and $result.ContinuationRequired;$attempt++){$result=& $module { param($workspace,$profile,$inventory,$hash,$root,$scanId,$entries) Invoke-WsmSourceCandidateScanCore $workspace $profile $inventory $hash $root $scanId $null $entries 10 } $scanWorkspace $scanProfile $scanInventory $scanHash $fixtureRoot $first.ScanId $maxEntries}
        $result
    }
    $scan=& $runScan 4000
    Check ($scan.ScanStatus -ceq 'Succeeded') 'the fixture scan completes'
    $artifact=Get-Content -LiteralPath $scan.CandidatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $area=@($artifact.ExcludedAreas|Where-Object Path -IEQ $installRoot)
    Check ($area.Count -eq 1 -and $area[0].Category -ceq 'BundleExcluded' -and $area[0].Contents.Counts.Bundle -ge 4 -and $area[0].Contents.Complete) 'the install-root exclusion row carries the structured Category and Contents'
    $guardArea=@($artifact.ExcludedAreas|Where-Object Path -IEQ $guardDir)
    Check ($guardArea.Count -eq 1 -and $guardArea[0].Category -ceq 'ProtectedArea' -and -not $guardArea[0].PSObject.Properties['Contents']) 'a protected area has Category ProtectedArea and no Contents'
    Check ($artifact.ContentRead -eq $false -and $artifact.Coverage.BundleHeaderBytesRead -eq $true -and $artifact.Coverage.BundleContentsRegionCount -eq 1) 'the artifact still claims no candidate content was read and discloses the 64-byte header reads'
    Check (@($artifact.Candidates|Where-Object {([string]$_.Path) -ieq $installRoot -or ([string]$_.Path).StartsWith($installRoot+'\',[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0) 'GUARD: no file or directory inside the install root became a candidate'
    Check (@($artifact.Candidates|Where-Object Path -IEQ (Join-Path $siteRoot 'core.dll')).Count -eq 1) 'the website publish directory file is still an ordinary candidate'
    $links=@($artifact.SameNameLinks)
    Check ($links.Count -eq 1 -and $links[0].Name -ceq 'core.dll' -and $links[0].BundlePath -ieq (Join-Path $installRoot 'lib\core.dll') -and $links[0].OtherPath -ieq (Join-Path $siteRoot 'core.dll')) 'the same-name DLL in the install root and the publish directory is linked'
    Check ($links[0].BundleClass -cne $links[0].OtherClass -and $links[0].BundleReason -and $links[0].OtherReason -and $links[0].BundleReason -cne $links[0].OtherReason) 'the two sides have different classes and their own reasons'
    $report=[IO.File]::ReadAllText($scan.ReportPath)
    Check ($report.Contains('同名，另一處位於') -and $report.Contains('安裝根內容') -and $report.Contains('64 位元組')) 'the scan review report shows the contents summary, the same-name trace and the header-read disclosure'

    $truncatedScan=& $runScan 3
    $truncatedArtifact=Get-Content -LiteralPath $truncatedScan.CandidatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $truncatedArea=@($truncatedArtifact.ExcludedAreas|Where-Object Path -IEQ $installRoot)
    Check ($truncatedScan.ScanStatus -ceq 'Succeeded' -and $truncatedArea.Count -eq 1 -and -not $truncatedArea[0].Contents.Complete -and $truncatedArea[0].Contents.IncompleteReason -ceq 'EntryBudget' -and $truncatedArea[0].Contents.Listed -eq 3) 'a scan with a small entry budget records the install-root listing as not finished, with the listed count'

    # ---------------------------------------------------------------- C. 防護沒有放寬
    $guardPaths=& $module {
        param($root,$siteRoot,$inventory)
        $out=[ordered]@{}
        $whole=[pscustomobject]@{Adapter='FileScope';SourcePath=$root;TargetPath='D:\t';ExcludedRelativePaths=@();ContentSelection='WholeScope'}
        try{Assert-WsmFileScopeInstalledRoots $whole $inventory|Out-Null;$out.Whole=$false}catch{$out.Whole=$true}
        $parent=[pscustomobject]@{Adapter='FileScope';SourcePath=(Split-Path -Parent $root);TargetPath='D:\t';ExcludedRelativePaths=@();ContentSelection='WholeScope'}
        try{Assert-WsmFileScopeInstalledRoots $parent $inventory|Out-Null;$out.Parent=$false}catch{$out.Parent=$true}
        $exact=[pscustomobject]@{Adapter='FileScope';SourcePath=(Split-Path -Parent $root);TargetPath='D:\t';ExcludedRelativePaths=@();ContentSelection='ExactMembers';Members=@([pscustomobject]@{RelativePath='Vendor App\Reports\sales.csv';SHA256=('0'*64)})}
        try{Assert-WsmFileScopeInstalledRoots $exact $inventory|Out-Null;$out.Exact=$false}catch{$out.Exact=$true}
        $other=[pscustomobject]@{Adapter='FileScope';SourcePath=$siteRoot;TargetPath='D:\t';ExcludedRelativePaths=@();ContentSelection='WholeScope'}
        try{Assert-WsmFileScopeInstalledRoots $other $inventory|Out-Null;$out.Site=$true}catch{$out.Site=$false}
        [pscustomobject]$out
    } $installRoot $siteRoot $scanInventory
    Check ($guardPaths.Whole -and $guardPaths.Parent) 'GUARD: approving the install root (or its parent) as a WholeScope is still rejected after the contents are listed'
    Check ($guardPaths.Exact) 'GUARD: approving a classified file inside the install root as an ExactMembers member is still rejected'
    Check ($guardPaths.Site) 'the publish directory outside the install root is still not blocked by the install-root guard'
    Check (-not (@($area[0].Contents.Samples|Where-Object {$_.PSObject.Properties['CandidateId'] -or $_.PSObject.Properties['CandidateType']}).Count)) 'GUARD: Contents samples carry no candidate identity that a confirmation could consume'

    # ---------------------------------------------------------------- D. 舊掃描回退與結構化欄位
    $rows=& $module {
        param($installRoot,$workspace)
        $prefix='Protected or package area excluded by policy: '
        $legacy=@(
            [pscustomobject]@{Path='C:\Vendor\Legacy';Reason=($prefix+'C:\Vendor\Legacy')},
            [pscustomobject]@{Path='C:\Windows';Reason=($prefix+'C:\Windows')},
            [pscustomobject]@{Path='C:\Guarded';Reason=($prefix+'FileScope guard: protected')},
            [pscustomobject]@{Path='C:\Forced';Reason=($prefix+'C:\Vendor\Forced');Category='ProtectedArea'},
            [pscustomobject]@{Path='C:\Bogus';Reason=($prefix+'C:\Vendor\Bogus');Category='Nonsense'})
        @(Get-WsmBackupExcludedRegionRows $legacy $workspace)
    } $installRoot $scanWorkspace
    $byPath=@{};foreach($row in $rows){$byPath[$row.Path]=$row}
    Check ($byPath['C:\Vendor\Legacy'].ReasonCode -ceq 'BundleExcluded' -and $byPath['C:\Vendor\Legacy'].CategorySource -ceq 'Inferred' -and $byPath['C:\Windows'].ReasonCode -ceq 'ProtectedArea' -and $byPath['C:\Guarded'].ReasonCode -ceq 'ProtectedArea') 'old scan rows without the new fields fall back to the reason-text inference'
    Check ($byPath['C:\Forced'].ReasonCode -ceq 'ProtectedArea' -and $byPath['C:\Forced'].CategorySource -ceq 'Structured') 'the structured Category wins over the reason text'
    Check ($byPath['C:\Bogus'].ReasonCode -ceq 'BundleExcluded' -and $byPath['C:\Bogus'].CategorySource -ceq 'Inferred') 'an unknown Category value is ignored and the text inference is used'
    Check (-not $byPath['C:\Vendor\Legacy'].PSObject.Properties['Contents'] -and -not $byPath['C:\Vendor\Legacy'].PSObject.Properties['ManualHandling']) 'a legacy row has no Contents (shown as not classified)'

    # ---------------------------------------------------------------- E. 結果集與離線報告：人工處置、完整度、同名兩處
    $resultRoot=Join-Path $tempRoot 'r';[void][IO.Directory]::CreateDirectory($resultRoot)
    $built=& $module {
        param($artifactPath,$siteRoot,$resultRoot,$workspace)
        $script:ToolVersion='fixture'
        $artifact=Read-WsmJson $artifactPath
        $regions=@(Get-WsmBackupExcludedRegionRows @($artifact.ExcludedAreas) $workspace @($artifact.SameNameLinks))
        $item={param([string]$Id,[string]$Name,$Spec,[string]$Decision)[pscustomobject]@{ItemId=$Id;Name=$Name;Kind='DataRoot';Category='Storage';NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{Path=('C:\settings\'+$Id)};Decision=$Decision;MigrationSpec=$Spec;Dependencies=@()}}
        $plan=[pscustomobject]@{Items=@((& $item 'site' 'Website publish' ([pscustomobject]@{Adapter='FileScope';SourcePath=$siteRoot;TransferChannel='C'}) 'Include'))}
        $rows=@(Get-WsmBackupItemResultRows $plan ([pscustomobject]@{Items=@()}) @([pscustomobject]@{ItemId='site';RelativePath='core.dll';Directory=$false;Data=[pscustomobject]@{Bytes=256}}) $false)
        $meta=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=('b'*64);ManifestHash=('a'*64);InventorySource='TrustedInventory';Software=[pscustomobject]@{SoftwareRows=@();FeatureRows=@();CoverageGaps=@()};ExcludedRegions=$regions;ExcludedRegionsBinding=[pscustomobject][ordered]@{Status='Bound';Reason='';Scans=@()}}
        $path=Join-Path $resultRoot 'results.json'
        $export=Export-WsmBackupItemResults $path $rows $meta
        $html=Export-WsmBackupOfflineReport $path $export.SHA256 (Join-Path $resultRoot 'report.html')
        [pscustomobject]@{Regions=$regions;Document=(Read-WsmJson $path);Html=[IO.File]::ReadAllText($html.Path,[Text.Encoding]::UTF8);Legacy=@(Get-WsmBackupExcludedRegionRows @([pscustomobject]@{Path='C:\Vendor\Old';Reason='Protected or package area excluded by policy: C:\Vendor\Old'}) $workspace)}
    } $scan.CandidatePath $siteRoot $resultRoot $scanWorkspace
    $bundleRegion=@($built.Regions|Where-Object Path -IEQ $installRoot)[0]
    Check ($bundleRegion.ReasonCode -ceq 'BundleExcluded' -and $bundleRegion.CategorySource -ceq 'Structured' -and $bundleRegion.Contents.Counts.SuspectedBusinessData -eq 3) 'the result row reads the structured Category and keeps the classified counts'
    Check ($bundleRegion.ManualHandling.Required -and $bundleRegion.ManualHandling.OriginalLocation -ieq $installRoot -and $bundleRegion.ManualHandling.NextStep.Contains('人工') -and $bundleRegion.NextStep.Contains('人工處置')) 'suspected business data is marked for manual handling with reason, original location and next step'
    Check (-not $bundleRegion.Contents.PSObject.Properties['BundleFiles']) 'the full bundle file list does not enter the result row'
    Check ($built.Document.ExcludedCompleteness.Status -ceq 'ManualItems' -and $built.Document.ExcludedCompleteness.Text -ceq '有人工處置項' -and $built.Document.ExcludedCompleteness.SuspectedFileCount -eq 3) 'the stored result set says "有人工處置項" and counts the suspected files'
    $sameName=@($bundleRegion.SameName)
    $siteDll=Join-Path $siteRoot 'core.dll'
    Check ($sameName.Count -eq 1 -and $sameName[0].OtherPath -ieq $siteDll) 'the region row carries the same-name link'
    $savedLink=@($built.Document.ExcludedRegions|Where-Object Path -IEQ $installRoot)[0].SameName[0]
    Check ($savedLink.OtherApproved -eq $true -and $savedLink.OtherItem -ceq 'Website publish' -and $savedLink.OtherClassText -ne $savedLink.BundleClassText) 'the stored link names the backed-up item that holds the other copy'
    $html=$built.Html
    Check ($html.Contains('id="completeness"') -and $html.Contains('data-status="ManualItems"') -and $html.Contains('有人工處置項')) 'the offline report shows the overall completeness as "有人工處置項"'
    Check ($html.Contains('class="region-detail-row"') -and $html.Contains('class="region-summary"') -and $html.Contains('data-text="')) 'the offline report has an expandable per-region detail row'
    Check ($html.Contains('Reports\sales.csv') -and $html.Contains('人工處置：另外人工複製') -and $html.Contains('原件位置')) 'the report lists the suspected business file with its original location and next step'
    $linkMarks=([regex]::Matches($html,'data-same-name="core\.dll" data-side="(bundle|other)"')|ForEach-Object {$_.Groups[1].Value}|Sort-Object) -join ','
    Check ($linkMarks -ceq 'bundle,other') 'the report marks BOTH sides of the same-name DLL'
    Check ($html.Contains('同名，另一處位於')) 'the report words the trace as "同名，另一處位於 …"'
    $legacyCompleteness=& $module { param($rows) Get-WsmBackupExcludedCompleteness $rows } $built.Legacy
    Check ($legacyCompleteness.Status -ceq 'Unconfirmed') 'a legacy (unclassified) install-root row cannot be reported as complete'
    $noneCompleteness=& $module { Get-WsmBackupExcludedCompleteness $null }
    Check ($noneCompleteness.Status -ceq 'NotRecorded') 'a result set without recorded regions says not recorded'
    $cleanCompleteness=& $module { param($contents) Get-WsmBackupExcludedCompleteness @([pscustomobject]@{ReasonCode='BundleExcluded';CategorySource='Structured';Contents=$contents}) } ([pscustomobject]@{Complete=$true;Counts=[pscustomobject]@{Bundle=2;SuspectedBusinessData=0;Unknown=1}})
    Check ($cleanCompleteness.Status -ceq 'NoManualItems' -and $cleanCompleteness.Claim.Contains('不代表搬移已完整')) 'even with no suspected data the wording never claims a complete migration'
    $incompleteCompleteness=& $module { param($contents) Get-WsmBackupExcludedCompleteness @([pscustomobject]@{ReasonCode='BundleExcluded';CategorySource='Structured';Contents=$contents}) } ([pscustomobject]@{Complete=$false;Counts=[pscustomobject]@{Bundle=2;SuspectedBusinessData=0;Unknown=1}})
    Check ($incompleteCompleteness.Status -ceq 'Unconfirmed') 'an unfinished listing is "無法確認", not clean'
    Write-Output ('TOTAL CHECKS: '+$checks)
} finally {
    if($junction -and [IO.Directory]::Exists($junction)){[IO.Directory]::Delete($junction)}
    if([IO.Directory]::Exists($tempRoot)){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
