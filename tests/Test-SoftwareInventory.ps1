#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$collector=(Join-Path $PSScriptRoot '..\src\SoftwareInventory.ps1')
$tempRoot=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('wsm-software-'+[Guid]::NewGuid().ToString('N'))))
$junction=$null
[void][IO.Directory]::CreateDirectory($tempRoot)
try {
    $fixtureSource=& $module { $s=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source'};$i=New-WsmItem $s.HostId Services Service 'Fixture service' 'fixture-service' @{PathName='"C:\Fixture\svc.exe" --token SECRETARG'};New-WsmInventory $s 3 @($i) }
    $manualPath=Join-Path $tempRoot 'manual.json'
    $manual=[pscustomobject]@{Kind='WsmManualSoftwareEvidence';Entries=@([pscustomobject]@{Name='Owner App';Version='4.2';Publisher='Owner';Architecture='x64';Scope='User';SID='S-1-5-21-1-2-3-1001';Location='C:\Apps\owner';Owner='app-owner';Evidence='Approved local software register';ProvidedUtc='2026-10-09T01:00:00Z'})}
    [IO.File]::WriteAllText($manualPath,($manual | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
    $manualHash=(Get-FileHash -LiteralPath $manualPath -Algorithm SHA256).Hash
    $portableActual=Join-Path $tempRoot 'portable-actual';$portableTarget=Join-Path $tempRoot 'portable-target';[void][IO.Directory]::CreateDirectory($portableActual);[void][IO.Directory]::CreateDirectory($portableTarget)
    [IO.File]::WriteAllText((Join-Path $portableActual 'one.ps1'),'# metadata fixture');[IO.File]::WriteAllText((Join-Path $portableActual 'two.ps1'),'# metadata fixture');[IO.File]::WriteAllText((Join-Path $portableTarget 'target.ps1'),'# target')
    $actualPortable=& $module { param($file,$root) . $file; Get-WsmSoftwarePortableSnapshot -Root $root -MaxEntries 1 -MaxDepth 2 -MaxMetadataBytes 4096 } $collector $portableActual
    if($actualPortable.Status -ne 'Partial' -or @($actualPortable.Gaps | Where-Object ErrorKind -EQ BudgetExceeded).Count -ne 1 -or @($actualPortable.Rows).Count -ne 1){throw 'Real bounded portable enumeration did not preserve its entry limit gap.'}
    $junction=Join-Path $portableActual 'linked-target';$junctionCreated=$false
    try { New-Item -ItemType Junction -Path $junction -Target $portableTarget -ErrorAction Stop | Out-Null;$junctionCreated=$true } catch {}
    if($junctionCreated){$junctionSnapshot=& $module { param($file,$root) . $file; Get-WsmSoftwarePortableSnapshot -Root $root -MaxEntries 10 -MaxDepth 2 -MaxMetadataBytes 4096 } $collector $portableActual;if(@($junctionSnapshot.Gaps | Where-Object ErrorKind -EQ ReparsePointRejected).Count -ne 1){throw 'Portable enumeration did not reject a reparse directory.'}}
    # Exercise the real native-probe orchestrator; substituting its entire result
    # would hide probe duplication, registry-view omissions and ordering bugs.
    & $module {
        param($file,$source)
        . $file
        function Get-WsmSoftwareCaptureIdentity {[pscustomobject]@{Fingerprint=('a'*64);IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function Get-WsmSoftwareProfileSnapshot {param($MaxEntries) [pscustomobject]@{Status='Success';ErrorKind=$null;Rows=@([pscustomobject]@{SID='S-1-5-21-1-2-3-1001'},[pscustomobject]@{SID='S-1-5-21-1-2-3-1002'})}}
        function Get-WsmSoftwareLoadedUserSnapshot {param($MaxEntries) [pscustomobject]@{Status='Success';ErrorKind=$null;Rows=@([pscustomobject]@{SID='S-1-5-21-1-2-3-1001'},[pscustomobject]@{SID='S-1-5-21-1-2-3-1003'})}}
        function Get-WsmSoftwareModuleSnapshot {param($MaxEntries) [pscustomobject]@{Status='NotInstalled';ErrorKind=$null;Rows=@()}}
        function Get-WsmSoftwareRegistrySnapshot {
            param($Hive,$Sid,$View,$SubKey,[switch]$ReadNamedValues,[switch]$ReadEnvironmentValues,$MaxEntries)
            $rows=@();if($Hive -eq 'User' -and ($SubKey -like '*Uninstall' -or $SubKey -like '*CLSID')){$rows=@([pscustomobject]@{KeyName='candidate';RegistryPath=($Sid+'\'+$SubKey);Properties=[pscustomobject]@{DisplayName='Fixture candidate';DisplayVersion='1';Publisher='fixture';InstallLocation=''}})}
            [pscustomobject]@{Status=$(if($rows.Count){'Success'}else{'NotInstalled'});ErrorKind=$null;Rows=$rows}
        }
        $native=@(Get-WsmSoftwareNativeSnapshots)
        if(@($native | Where-Object {$_.Probe -eq 'COMOLEDBCandidates' -and $_.Scope -eq 'User'}).Count -ne 5){throw 'User COM probes were duplicated or a hive coverage gap was omitted.'}
        foreach($sid in @('S-1-5-21-1-2-3-1001','S-1-5-21-1-2-3-1003')){foreach($view in @('Registry32','Registry64')){if(@($native | Where-Object {$_.Probe -eq 'Uninstall' -and $_.SID -eq $sid -and $_.View -eq $view}).Count -ne 1){throw 'Loaded-user software registry view missing or duplicated.'}}}
        $actual=Get-WsmSoftwareCatalog -Source $source
        if(@($actual.Coverage | Where-Object {$_.Probe -eq 'Uninstall' -and $_.SID -eq 'S-1-5-21-1-2-3-1001' -and $_.Status -eq 'NotTested'}).Count){throw 'Probe ordering falsely marked a loaded profile as untested.'}
        if(@($actual.Entries | Where-Object {$_.SourceKind -eq 'COMOLEDBCandidate' -and $_.Scope -eq 'User'}).Count -ne 4){throw 'Distinct user views did not survive native orchestration.'}
    } $collector $fixtureSource
    $catalog=& $module {
        param($file,$source,$manualPath,$manualHash,$root)
        . $file
        function Get-WsmSoftwareCaptureIdentity {[pscustomobject]@{Fingerprint=('a'*64);IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function Get-WsmSoftwareNativeSnapshots { param([int]$MaxRegistryEntries)
            @(
                [pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry32';Snapshot=[pscustomobject]@{Status='Success';ErrorKind=$null;Rows=@([pscustomobject]@{KeyName='app-x86';RegistryPath='HKLM32\Uninstall\app-x86';Properties=[pscustomobject]@{DisplayName='Same App';DisplayVersion='1.0';Publisher='Vendor';InstallLocation='C:\Program Files (x86)\Same'}})}},
                [pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Snapshot=[pscustomobject]@{Status='Success';ErrorKind=$null;Rows=@([pscustomobject]@{KeyName='app-x64';RegistryPath='HKLM64\Uninstall\app-x64';Properties=[pscustomobject]@{DisplayName='Same App';DisplayVersion='2.0';Publisher='Vendor';InstallLocation='C:\Program Files\Same'}},[pscustomobject]@{KeyName='dsn';RegistryPath='HKLM64\ODBC\dsn';Properties=[pscustomobject]@{DisplayName='DSN pwd=secret;Password=hidden';DisplayVersion='';Publisher='';InstallLocation=''}})}},
                [pscustomobject]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-1-2-3-1001';View='Default';Snapshot=[pscustomobject]@{Status='Success';ErrorKind=$null;Rows=@([pscustomobject]@{KeyName='user-app';RegistryPath='HKU\user\Uninstall\user-app';Properties=[pscustomobject]@{DisplayName='Same App';DisplayVersion='1.0';Publisher='Vendor';InstallLocation='C:\Users\fixture\AppData\Local\Same'}})}},
                [pscustomobject]@{Probe='ODBCUserDSN';Scope='User';SID='S-1-5-21-1-2-3-1001';View='Default';Snapshot=[pscustomobject]@{Status='Success';ErrorKind=$null;Rows=@([pscustomobject]@{KeyName='AppDSN';RegistryPath='HKU\user\ODBC\AppDSN';Properties=[pscustomobject]@{DisplayName='AppDSN';Driver='Fixture ODBC Driver';Password='should-never-copy'}})}},
                [pscustomobject]@{Probe='UserEnvironment';Scope='User';SID='S-1-5-21-1-2-3-1001';View='Default';Snapshot=[pscustomobject]@{Status='Success';ErrorKind=$null;Rows=@([pscustomobject]@{KeyName='APPDATA';RegistryPath='HKU\user\Environment\APPDATA';Properties=[pscustomobject]@{DisplayName='APPDATA';InstallLocation='C:\Users\fixture\AppData\Roaming'}})}},
                [pscustomobject]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-1-2-3-1003';View='Default';Snapshot=[pscustomobject]@{Status='PermissionDenied';ErrorKind='AccessDenied';Rows=@()}},
                [pscustomobject]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-1-2-3-1002';View='Default';Snapshot=[pscustomobject]@{Status='NotTested';ErrorKind='ProfileHiveNotLoaded';Rows=@()}},
                [pscustomobject]@{Probe='ProfileList';Scope='Machine';SID='';View='Registry64';Snapshot=[pscustomobject]@{Status='Success';ErrorKind=$null;Rows=@([pscustomobject]@{SID='S-1-5-21-1-2-3-1001'},[pscustomobject]@{SID='S-1-5-21-1-2-3-1002'})}}
            )
        }
        function Get-WsmSoftwarePortableSnapshot { param($Root,$MaxEntries,$MaxDepth,$MaxMetadataBytes)
            if($Root -eq 'fixture-limit'){return [pscustomobject]@{Status='Partial';Count=1;MetadataBytes=$MaxMetadataBytes;Limited=$true;Rows=@([pscustomobject]@{Name='Portable';Version='';Publisher='';ProductName='';Path='C:\Portable\p.exe';Length=10;LastWriteUtc='2026-10-09T00:00:00Z';FileKind='.exe'});Gaps=@([pscustomobject]@{Status='Partial';ErrorKind='BudgetExceeded';Path=$Root})}}
            [pscustomobject]@{Status='Success';Count=1;MetadataBytes=100;Limited=$false;Rows=@([pscustomobject]@{Name='Portable';Version='';Publisher='';ProductName='';Path='C:\Portable\p.exe';Length=10;LastWriteUtc='2026-10-09T00:00:00Z';FileKind='.exe'});Gaps=@()}
        }
        function Get-WsmSoftwareFileMetadataSnapshot { param($Path) [pscustomobject]@{Status='Success';ErrorKind=$null;Row=[pscustomobject]@{Name='svc';Version='9.1';Publisher='Fixture Vendor';ProductName='Fixture Service';Path=$Path;Length=123;LastWriteUtc='2026-10-09T00:00:00Z';FileKind='.exe'}} }
        function Get-WsmSoftwareAdjacentRuntimeSnapshot { param($ExecutablePath,$MaxEntries,$MaxMetadataBytes) [pscustomobject]@{Status='Success';Count=1;MetadataBytes=200;Rows=@([pscustomobject]@{Name='Microsoft.NETCore.App';Version='8.0.1';Publisher='Microsoft';Path='C:\Fixture\svc.runtimeconfig.json';EvidenceKind='RuntimeConfigMetadata';Length=200});Gaps=@()} }
        Get-WsmSoftwareCatalog -Source $source -PortableRoot @('fixture-ok','fixture-limit') -ManualEvidencePath $manualPath -ManualEvidenceSha256 $manualHash -MaxEntries 100
    } $collector $fixtureSource $manualPath $manualHash $tempRoot
    if(@($catalog.Entries | Where-Object Name -EQ 'Same App').Count -ne 3){throw 'Same-name versions, SIDs, or registry views were merged.'}
    if(@($catalog.Entries | Where-Object Name -EQ 'Same App' | Where-Object Architecture -NE Unknown).Count){throw 'Registry view incorrectly proved application bitness.'}
    if(@($catalog.Entries | Where-Object SourceKind -EQ OwnerProvided).Count -ne 1){throw 'Verified owner-provided row missing.'}
    if(@($catalog.Entries | Where-Object SourceKind -EQ AppLocalRuntimeEvidence).Count -ne 1 -or @($catalog.Coverage | Where-Object Probe -EQ ConsumerFileMetadata).Count -ne 1){throw 'Service executable or app-local runtime metadata was not captured.'}
    if(@($catalog.Coverage | Where-Object Status -EQ NotTested | Where-Object ErrorKind -EQ ProfileHiveNotLoaded).Count -ne 1){throw 'Unloaded profile coverage missing.'}
    if(@($catalog.Coverage | Where-Object Status -EQ PermissionDenied).Count -ne 1){throw 'Denied user hive coverage missing.'}
    if(@($catalog.Coverage | Where-Object ErrorKind -EQ BudgetExceeded).Count -lt 1){throw 'Portable search budget gap missing.'}
    if(($catalog | ConvertTo-Json -Depth 20) -match 'pwd=secret|Password=hidden|should-never-copy|SECRETARG|--token'){throw 'Potential DSN secret or command argument leaked into catalog.'}
    if(@($catalog.Entries | Where-Object SourceKind -EQ ODBCDSN).Count -ne 1 -or @($catalog.Entries | Where-Object SourceKind -EQ UserEnvironment).Count -ne 1){throw 'Safe user DSN/environment evidence was omitted.'}
    $catalogTamperRejected=$false;try { & $module { param($file,$c) . $file; $c=($c | ConvertTo-Json -Depth 30 | ConvertFrom-Json); $c.Entries[0].Name='Tampered'; Assert-WsmSoftwareCatalog $c | Out-Null } $collector $catalog } catch {$catalogTamperRejected=$true};if(-not $catalogTamperRejected){throw 'Catalog projection hash did not detect tampering.'}
    $wrongInventory=& $module { param($source) New-WsmInventory $source.Source 4 @() } $fixtureSource
    $bindingRejected=$false;try { & $module { param($file,$c,$source) . $file; Assert-WsmSoftwareCatalog $c -SourceInventory $source | Out-Null } $collector $catalog $wrongInventory } catch {$bindingRejected=$true};if(-not $bindingRejected){throw 'Catalog was accepted against a different source revision projection.'}
    $rejected=$false;try { & $module { param($file,$c) . $file; $c=($c | ConvertTo-Json -Depth 30 | ConvertFrom-Json); $c.Entries[0] | Add-Member NoteProperty UninstallString 'msiexec /i secret'; $c.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $c; Assert-WsmSoftwareCatalog $c | Out-Null } $collector $catalog } catch {$rejected=$true};if(-not $rejected){throw 'Catalog accepted a prohibited command field.'}
    $badHash=$false;try { & $module { param($file,$source,$path) . $file; function Get-WsmSoftwareCaptureIdentity {[pscustomobject]@{Fingerprint=('a'*64);IsServer=$true;Administrator=$true;Is64Bit=$true}}; function Get-WsmSoftwareNativeSnapshots {param($MaxRegistryEntries) @()}; Get-WsmSoftwareCatalog -Source $source -ManualEvidencePath $path -ManualEvidenceSha256 ('0'*64) } $collector $fixtureSource $manualPath } catch {if($_.Exception.Message -notmatch 'Manual evidence hash mismatch'){throw};$badHash=$true};if(-not $badHash){throw 'Manual evidence with an untrusted hash was accepted.'}
    & $module {
        param($file,$source,$catalog,$root)
        . $file
        $source | Add-Member NoteProperty SoftwareCatalog $catalog -Force
        $inventoryPath=Join-Path $root 'sealed-inventory.json';Write-WsmJson $inventoryPath $source
        $hash=(Get-FileHash -LiteralPath $inventoryPath).Hash
        $path=Join-Path $root 'evidence\software.json'
        function Get-WsmSoftwareNativeSnapshots {throw 'Readonly evidence export must not run native capture.'}
        $result=Export-WsmSoftwareCatalogEvidence $inventoryPath $hash $path
        if($result.NativeProbeExecuted -or $result.SoftwareCount -ne $catalog.Entries.Count -or (Get-FileHash -LiteralPath $path).Hash -ine $result.SHA256){throw 'Readonly source software evidence export lost trust binding or rows.'}
        $blocked=$false;try{Export-WsmSoftwareCatalogEvidence $inventoryPath $hash $path | Out-Null}catch{$blocked=$_.Exception.Message -match 'already exists'}
        if(-not $blocked){throw 'Readonly software evidence export overwrote an existing evidence file.'}
    } $collector $fixtureSource $catalog $tempRoot
    Write-Host 'PASS: B1 fixture aggregation preserves variants, coverage, secret filtering, portable budgets, manual evidence trust, and unknown architecture.'
} finally {
    $resolved=[IO.Path]::GetFullPath($tempRoot);$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-software-*'){throw 'Refusing to clean an unexpected test path.'}
    if($junction -and [IO.Directory]::Exists($junction)){[IO.Directory]::Delete([IO.Path]::GetFullPath($junction),$false)}
    if([IO.Directory]::Exists($resolved)){[IO.Directory]::Delete($resolved,$true)}
}


