#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$collector=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\SoftwareInventory.ps1'))
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wsm-r7-software-'+[Guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()){& $script:module $Block @Arguments}
function SaveJson($Data,[string]$Name){$path=Join-Path $root $Name;[IO.File]::WriteAllText($path,($Data|ConvertTo-Json -Depth 45 -Compress),(New-Object Text.UTF8Encoding($false)));$path}
function NewFixtureSoftwareCatalog($Inventory,$Entry,[string]$Version,[string]$Scope='Machine',[string]$SID=''){
    CallModule {
        param($inventory,$entry,$version,$scope,$sid)
        $copy=[pscustomobject][ordered]@{SoftwareId=$entry.SoftwareId;Name=$entry.Name;Version=$version;Publisher=$entry.Publisher;Architecture=$entry.Architecture;Scope=$scope;SID=$sid;RegistryView=$entry.RegistryView;Location=$entry.Location;SourceKind=$entry.SourceKind;Evidence=$entry.Evidence;ObservedUtc=(Get-WsmUtc);CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$inventory.Source.HostId;Fingerprint=$inventory.Source.Fingerprint;Name=$inventory.Source.Name;InventoryRevision=[int]$inventory.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='7.5.0';RequestedPortableRoots=@()};Entries=@($copy);Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=(Get-WsmUtc)});PreparationRequirements=@([pscustomobject]@{PreparationId=('prep-'+$copy.SoftwareId.Substring(3));SoftwareId=$copy.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='Fixture evidence only.'});CatalogProjectionHash=('0'*64)}
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
        Assert-WsmSoftwareCatalog $catalog -SourceInventory $inventory | Out-Null
        $catalog
    } @($Inventory,$Entry,$Version,$Scope,$SID)
}
try {
    $sourceInventory=CallModule {
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='R7 fixture source'}
        $role=New-WsmItem $source.HostId Roles WindowsFeature 'Fixture web role' 'Fixture-Web-Role' @{Name='Fixture-Web-Role'}
        New-WsmInventory $source 1 @($role)
    }
    $sourceCatalog=CallModule {
        param($file,$inventory)
        . $file
        function Get-WsmSoftwareCaptureIdentity {[pscustomobject]@{Fingerprint=('a'*64);IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function Assert-WsmMigrationHost {param($Identity,[string]$Fingerprint) if($Identity.Fingerprint -cne $Fingerprint){throw 'Fixture capture host mismatch.'}}
        function Get-WsmSoftwareNativeSnapshots {param([int]$MaxRegistryEntries)
            $rows=@(
                [pscustomobject]@{KeyName='product-machine';RegistryPath='HKLM64\Uninstall\product-machine';Properties=[pscustomobject]@{DisplayName='R7 Shared Product';DisplayVersion='1.0';Publisher='Fixture Vendor';InstallLocation='C:\Program Files\R7Shared'}},
                [pscustomobject]@{KeyName='unknown-version';RegistryPath='HKLM64\Uninstall\unknown-version';Properties=[pscustomobject]@{DisplayName='R7 Unknown Version';DisplayVersion='';Publisher='Fixture Vendor';InstallLocation='C:\Program Files\R7Unknown'}},
                [pscustomobject]@{KeyName='product-user-1';RegistryPath='HKU\user1\Uninstall\product-user-1';Properties=[pscustomobject]@{DisplayName='R7 Shared Product';DisplayVersion='1.0';Publisher='Fixture Vendor';InstallLocation='C:\Users\one\AppData\Local\R7Shared'}},
                [pscustomobject]@{KeyName='product-user-2';RegistryPath='HKU\user2\Uninstall\product-user-2';Properties=[pscustomobject]@{DisplayName='R7 Shared Product';DisplayVersion='1.0';Publisher='Fixture Vendor';InstallLocation='C:\Users\two\AppData\Local\R7Shared'}}
            )
            @(
                [pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Snapshot=[pscustomobject]@{Status='Success';Rows=@($rows[0],$rows[1]);ErrorKind=$null}},
                [pscustomobject]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-1-2-3-1001';View='Registry64';Snapshot=[pscustomobject]@{Status='Success';Rows=@($rows[2]);ErrorKind=$null}},
                [pscustomobject]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-1-2-3-1002';View='Registry64';Snapshot=[pscustomobject]@{Status='Success';Rows=@($rows[3]);ErrorKind=$null}},
                [pscustomobject]@{Probe='ODBCUserDSN';Scope='User';SID='S-1-5-21-1-2-3-1002';View='Default';Snapshot=[pscustomobject]@{Status='PermissionDenied';Rows=@();ErrorKind='AccessDenied'}},
                [pscustomobject]@{Probe='ProfileList';Scope='Machine';SID='';View='Registry64';Snapshot=[pscustomobject]@{Status='Success';Rows=@([pscustomobject]@{SID='S-1-5-21-1-2-3-1001'},[pscustomobject]@{SID='S-1-5-21-1-2-3-1002'});ErrorKind=$null}}
            )
        }
        Get-WsmSoftwareCatalog -Source $inventory -MaxEntries 100
    } @($collector,$sourceInventory)
    Check (@($sourceCatalog.Entries | Where-Object Name -EQ 'R7 Shared Product').Count -eq 3) 'Collector did not preserve machine and separate user-scoped software rows.'
    Check (@($sourceCatalog.Entries | Where-Object {$_.Scope -eq 'User'} | Select-Object -ExpandProperty SID -Unique).Count -eq 2) 'Collector conflated software from two user SIDs.'
    Check (@($sourceCatalog.Entries | Where-Object {$_.Name -eq 'R7 Unknown Version' -and -not $_.Version}).Count -eq 1) 'Collector dropped a known product name because its version was unknown.'
    Check (@($sourceCatalog.Entries | Where-Object {$_.Name -eq 'Fixture-Web-Role' -and $_.SourceKind -eq 'InstalledRole'}).Count -eq 1) 'Collector omitted installed Windows role evidence.'
    $sourceInventory | Add-Member NoteProperty SoftwareCatalog $sourceCatalog -Force
    $sourcePath=SaveJson $sourceInventory 'source.json';$sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $workspace=Join-Path $root 'workspace';CallModule {param($path) Initialize-WsmWorkspace $path | Out-Null} @($workspace)
    $catalog=CallModule {param($w,$path,$hash) Import-WsmInventory $w $path $hash 'R7 fixture target'} @($workspace,$sourcePath,$sourceHash)
    $catalog=CallModule {param($w,$pair,$revision) Enable-WsmAssistiveMode $w $pair $revision} @($workspace,$catalog.PairId,$catalog.DecisionRevision)
    $sourceEntry=@($sourceCatalog.Entries | Where-Object {$_.Name -eq 'R7 Shared Product' -and $_.Scope -eq 'Machine'})[0]
    $targetHost=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('b'*64);Name='R7 fixture target'}
    $targetInventory=CallModule {param($source) New-WsmInventory $source 1 @()} @($targetHost)
    $baselineCatalog=NewFixtureSoftwareCatalog $targetInventory $sourceEntry '1.5'
    $targetInventory | Add-Member NoteProperty SoftwareCatalog $baselineCatalog -Force
    $baselinePath=SaveJson $targetInventory 'target-baseline.json';$baselineHash=(Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=CallModule {param($w,$pair,$path,$hash,$revision) Update-WsmAssistiveTargetSnapshot $w $pair $path $hash $revision} @($workspace,$catalog.PairId,$baselinePath,$baselineHash,$catalog.Assistive.Revision)
    $targetInventory2=CallModule {param($source) New-WsmInventory $source 2 @()} @($targetHost)
    $currentCatalog=NewFixtureSoftwareCatalog $targetInventory2 $sourceEntry '2.0'
    $targetInventory2 | Add-Member NoteProperty SoftwareCatalog $currentCatalog -Force
    $currentPath=SaveJson $targetInventory2 'target-current.json';$currentHash=(Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=CallModule {param($w,$pair,$path,$hash,$revision) Update-WsmAssistiveTargetSnapshot $w $pair $path $hash $revision} @($workspace,$catalog.PairId,$currentPath,$currentHash,$catalog.Assistive.Revision)
    $comparison=CallModule {param($w,$pair) Get-WsmAssistiveComparison $w $pair} @($workspace,$catalog.PairId)
    Check (@($comparison.Rows | Where-Object {$_.Name -eq 'R7 Shared Product' -and $_.Scope -eq 'User' -and $_.Status -eq 'Ambiguous'}).Count -eq 2) 'Target comparison merged same-name rows from distinct source accounts.'
    Check (@($comparison.Rows | Where-Object {$_.SoftwareId -eq $sourceEntry.SoftwareId -and $_.ObservedTargetVersion -eq '2.0' -and $_.BaselineObservedVersion -eq '1.5'}).Count -eq 1) 'Comparison omitted the exact current target and first-observed baseline versions.'
    Check (@($comparison.Rows | Where-Object SoftwareId).Count -eq $sourceCatalog.Entries.Count) 'Target comparison did not retain exactly one row for every discovered source SoftwareId.'
    CallModule {param($w,$pair,$revision) Update-WsmAssistiveComparison $w $pair $revision} @($workspace,$catalog.PairId,$catalog.Assistive.Revision) | Out-Null
    $catalog=CallModule {param($w,$pair) Get-WsmCatalog $w $pair} @($workspace,$catalog.PairId)
    $projection=CallModule {param($catalog) Get-WsmEnvironmentConfirmationProjection -Catalog $catalog} @($catalog)
    $machineProjection=@($projection.Software | Where-Object SoftwareId -CEQ $sourceEntry.SoftwareId)
    Check ($machineProjection.Count -eq 1 -and $machineProjection[0].TargetStatus -eq 'DifferentFromChosenVersion' -and $machineProjection[0].ObservedTargetVersion -eq '2.0' -and $machineProjection[0].Classification -eq 'Unknown') 'Environment projection did not reuse the current exact comparison or mislabeled ordinary installed software.'
    $staleCatalog=CallModule {param($catalog) $catalog|ConvertTo-Json -Depth 45 -Compress|ConvertFrom-Json} @($catalog)
    $staleEntry=@($staleCatalog.SoftwareCatalog.Entries | Where-Object SoftwareId -CEQ $sourceEntry.SoftwareId)[0]
    $staleEntry.Version='9.9'
    $staleCatalog.SoftwareCatalog.CatalogProjectionHash=CallModule {param($sc) Get-WsmSoftwareCatalogProjectionHash $sc} @($staleCatalog.SoftwareCatalog)
    $staleProjection=CallModule {param($catalog) Get-WsmEnvironmentConfirmationProjection -Catalog $catalog} @($staleCatalog)
    $staleRow=@($staleProjection.Software | Where-Object SoftwareId -CEQ $sourceEntry.SoftwareId)[0]
    Check ($staleRow.TargetStatus -eq 'NotTested' -and $staleRow.TargetComparisonReason -match 'differ') 'Projection reused a current snapshot comparison for changed source row facts.'
    Check (@($projection.Software | Where-Object {$_.SourceKind -eq 'InstalledRole' -and $_.Classification -eq 'WindowsRole'}).Count -eq 1) 'Windows role evidence was not kept distinguishable from unknown software classification.'
    Check (@($projection.Coverage | Where-Object {$_.Probe -eq 'Uninstall' -and $_.MaxEntries -eq 100}).Count -ge 1) 'Environment projection lost nested coverage budget diagnostics.'
    $report=Export-WsmAssistiveReport -Workspace $workspace -PairId $catalog.PairId -OutputDirectory (Join-Path $root 'report')
    $reportHtml=[IO.File]::ReadAllText($report.ReportPath)
    Check ($reportHtml.Contains('Dependent workload ItemIds') -and $reportHtml.Contains('Registry view') -and $reportHtml.Contains('Classification / coverage detail') -and $reportHtml.Contains([string]$sourceEntry.SoftwareId) -and $reportHtml.Contains('S-1-5-21-1-2-3-1001') -and $reportHtml.Contains('AccessDenied') -and $reportHtml.Contains('MaxEntries=100')) 'Real report consumer omitted software identity, account scope, or coverage diagnostics.'
    Check ($reportHtml.Contains('Observed current version') -and $reportHtml.Contains('1.5') -and $reportHtml.Contains('2.0')) 'Real report comparison did not retain current and baseline version evidence.'
    Write-Host ('PASS: R7 software assessment preserved '+$sourceCatalog.Entries.Count+' collected rows through comparison and report projection; '+$script:passed+' assertions.')
} finally {
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
    $resolved=[IO.Path]::GetFullPath($root);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($resolved).StartsWith('wsm-r7-software-')){throw 'Refusing cleanup outside the uniquely named test-owned temporary directory.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
