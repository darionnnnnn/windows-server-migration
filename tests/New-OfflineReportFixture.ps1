#requires -Version 5.1
# Builds a >250 row backup result set and its offline report for the real-browser test.
# -Scale Large builds 2501 backed rows (one table above the 2000-row mark) plus 5 not-backed rows and 250 excluded regions.
# Rows come from the real Get-WsmBackupItemResultRows so the browser sees production shapes.
param([Parameter(Mandatory)][string]$OutDir,[ValidateSet('V2','V1')][string]$Shape='V2',[ValidateSet('Standard','Large','Mixed')][string]$Scale='Standard')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
[void][IO.Directory]::CreateDirectory($OutDir)
& $module {
    param($OutDir,$Shape,$Scale)
    $script:ToolVersion='fixture'
    $item={param([string]$Id,[string]$Name,$Spec,[string]$Decision,[string]$Kind='DataRoot',[string]$Category='Storage',$Deps=@())[pscustomobject]@{ItemId=$Id;Name=$Name;Kind=$Kind;Category=$Category;NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{Path=('C:\settings\'+$Id)};Decision=$Decision;MigrationSpec=$Spec;Dependencies=@($Deps)}}
    $file={param([string]$Channel)[pscustomobject]@{Adapter='FileScope';SourcePath=('D:\scope\'+$Channel);TransferChannel=$Channel}}
    $planItems=New-Object 'System.Collections.Generic.List[object]'
    $inventoryItems=New-Object 'System.Collections.Generic.List[object]'
    $artifacts=New-Object 'System.Collections.Generic.List[object]'
    $siteName='Site <img src=x onerror=alert(1)>'
    $itemCount=300;if($Scale -ceq 'Large'){$itemCount=2506}
    for($i=1;$i -le $itemCount;$i++){
        if($Scale -ceq 'Large'){
            $id=('item-{0:D4}' -f $i);$name=$id
            if($i -le 2501){
                if($i -eq 2501){$name='zz-final-row-2501'}
                if($i -eq 1){$name='aa-first-row-0001'}
                $planItems.Add((& $item $id $name (& $file 'C') 'Include'))
                $artifacts.Add([pscustomobject]@{ItemId=$id;RelativePath='a.txt';Directory=$false;Data=[pscustomobject]@{Bytes=(100+$i)}})
            }else{$planItems.Add((& $item $id ('not-backed-'+$id) (& $file 'C') 'Exclude'))}
            continue
        }
        $id=('item-{0:D4}' -f $i);$name=$id
        if($i -eq 5){$name='=SUM(1+1)'}
        if($i -eq 6){$name='@cmd|calc'}
        if($i -eq 7){$name='+1-2'}
        if($i -eq 180){$name='zz-last-backed'}
        if($i -eq 300){$name='zz-last-pending'}
        if($i -le 180){
            if($i % 3 -eq 0 -and $i -ne 180){$planItems.Add((& $item $id $name ([pscustomobject]@{Adapter='Service'}) 'Include' 'Service' 'Services'))}
            else{
                $planItems.Add((& $item $id $name (& $file 'C') 'Include'))
                # Mixed magnitudes so the size text (B / KiB / MiB, one decimal, exact halves) is compared between the report and the workbench.
                $bytes=(100+$i);if($i -eq 2){$bytes=3407872}elseif($i -eq 4){$bytes=1280}elseif($i % 7 -eq 0){$bytes=$i*1500}
                $artifacts.Add([pscustomobject]@{ItemId=$id;RelativePath='a.txt';Directory=$false;Data=[pscustomobject]@{Bytes=$bytes}})
            }
        }elseif($i -le 240){$planItems.Add((& $item $id $name (& $file 'C') 'Exclude'))}
        elseif($i -le 270){$planItems.Add((& $item $id $name (& $file 'C') 'Pending'))}
        else{
            $status=$(if($i % 2 -eq 0){'PermissionDenied'}else{'Success'})
            $inventoryItems.Add([pscustomobject]@{ItemId=$id;Name=$name;Kind='DataRoot';Category='Storage';NaturalKey=('key-'+$id);Settings=[pscustomobject]@{Path=('E:\inv\'+$id)};Status=$status})
        }
    }
    if($Scale -cne 'Large'){$planItems.Add((& $item 'site-1' $siteName ([pscustomobject]@{Adapter='IISSite'}) 'Include' 'IISSite' 'Web' @([pscustomobject]@{ItemId='item-0001'},[pscustomobject]@{ItemId='item-0002'})))}
    $mixedRoot=Join-Path $OutDir 'mixed-fixture';$siteDir=Join-Path $mixedRoot 'Site'
    if($Scale -ceq 'Mixed'){
        [void][IO.Directory]::CreateDirectory($siteDir)
        $planItems.Add((& $item 'site-files' 'Website publish' ([pscustomobject]@{Adapter='FileScope';SourcePath=$siteDir;TransferChannel='C'}) 'Include'))
        $artifacts.Add([pscustomobject]@{ItemId='site-files';RelativePath='core.dll';Directory=$false;Data=[pscustomobject]@{Bytes=256}})
    }
    $plan=[pscustomobject]@{Items=@($planItems.ToArray())}
    $inventory=[pscustomobject]@{Items=@($inventoryItems.ToArray())}
    $rows=@(Get-WsmBackupItemResultRows $plan $inventory @($artifacts.ToArray()) $false)
    $software=[pscustomobject]@{
        SoftwareRows=@([pscustomobject]@{SoftwareId='sw-1';Name='Contoso Tool';Version='1.0';Publisher='Contoso';Architecture='x64';Scope='Machine';Location='C:\a';SourceKind='Uninstall';Disposition='Reinstall';DispositionText='新機重新安裝'})
        FeatureRows=@([pscustomobject]@{Name='Web Server (IIS)';FeatureName='Web-Server'})
        CoverageGaps=@([pscustomobject]@{Status='Partial';Probe='Uninstall';Scope='User';SID='S-1-5-21-<b>x</b>'})}
    $resultsPath=Join-Path $OutDir 'backup-item-results.json'
    # Excluded regions come from the real classifier on scan-shaped rows (policy reason text as the scanner writes it).
    $policyPrefix='Protected or package area excluded by policy: '
    $areas=New-Object 'System.Collections.Generic.List[object]'
    $areas.Add([pscustomobject]@{Path='C:\Program Files';Reason=($policyPrefix+'C:\Program Files')})
    $areas.Add([pscustomobject]@{Path='C:\Vendor\=Contoso <b>App</b>';Reason=($policyPrefix+'C:\Vendor\=Contoso <b>App</b>')})
    $areas.Add([pscustomobject]@{Path='C:\Windows';Reason=($policyPrefix+'C:\Windows')})
    $areas.Add([pscustomobject]@{Path='C:\Config.Msi';Reason=($policyPrefix+'Config.Msi')})
    if($Scale -ceq 'Large'){for($n=1;$n -le 246;$n++){$areas.Add([pscustomobject]@{Path=('C:\Vendor\App{0:D3}' -f $n);Reason=($policyPrefix+('C:\Vendor\App{0:D3}' -f $n))})}}
    $sameNameLinks=@()
    if($Scale -ceq 'Mixed'){
        # N9d：混合套裝目錄。區域列用真正的唯讀分類函式產生（結構化 Category／Contents），同名追溯用真正的比對函式。
        $areas.Clear()
        [byte[]]$pe=New-Object byte[] 256;$pe[0]=0x4d;$pe[1]=0x5a;[BitConverter]::GetBytes([int]128).CopyTo($pe,60);$pe[128]=0x50;$pe[129]=0x45
        [IO.File]::WriteAllBytes((Join-Path $siteDir 'core.dll'),$pe)
        $installA=Join-Path $mixedRoot "Vendor =App & 'Co'";$installB=Join-Path $mixedRoot 'Big Suite'
        foreach($dir in @('lib','Reports','data')){[void][IO.Directory]::CreateDirectory((Join-Path $installA $dir))}
        [IO.File]::WriteAllBytes((Join-Path $installA 'app.exe'),$pe);[IO.File]::WriteAllBytes((Join-Path $installA 'lib\core.dll'),$pe)
        [IO.File]::WriteAllText((Join-Path $installA 'settings.config'),'<configuration/>')
        [IO.File]::WriteAllText((Join-Path $installA "Reports\sales & 'q'.csv"),'a,b');[IO.File]::WriteAllText((Join-Path $installA 'data\customers.db'),'rows')
        [void][IO.Directory]::CreateDirectory($installB);for($n=1;$n -le 12;$n++){[IO.File]::WriteAllText((Join-Path $installB ('file{0:D2}.txt' -f $n)),'x')}
        $policyPrefix='Protected or package area excluded by policy: '
        $areas.Add([pscustomobject][ordered]@{Path=$installA;Reason=($policyPrefix+$installA);Category='BundleExcluded';Contents=(Get-WsmSourceCandidateBundleContents $installA)})
        $areas.Add([pscustomobject][ordered]@{Path=$installB;Reason=($policyPrefix+$installB);Category='BundleExcluded';Contents=(Get-WsmSourceCandidateBundleContents $installB 5)})
        $areas.Add([pscustomobject][ordered]@{Path='C:\Program Files';Reason=($policyPrefix+'C:\Program Files');Category='BundleExcluded'})
        $areas.Add([pscustomobject][ordered]@{Path='C:\Windows';Reason=($policyPrefix+'C:\Windows');Category='ProtectedArea'})
        $areas.Add([pscustomobject]@{Path='C:\Config.Msi';Reason=($policyPrefix+'Config.Msi')})
        $areas.Add([pscustomobject]@{Path='C:\Vendor\Legacy App';Reason=($policyPrefix+'C:\Vendor\Legacy App')})
        $sameNameLinks=@((Get-WsmSourceCandidateSameNameLinks ([pscustomobject]@{ExcludedAreas=@($areas.ToArray())}) @([pscustomobject]@{CandidateType='ExactFile';Path=(Join-Path $siteDir 'core.dll')})).Links)
    }
    $excludedRegions=@(Get-WsmBackupExcludedRegionRows @($areas.ToArray()) '' $sameNameLinks)
    $binding=[pscustomobject][ordered]@{Status='Bound';Reason='';Scans=@([pscustomobject][ordered]@{ScanId='fixture-scan';CandidateArtifactHash=('d'*64);ScanStatus='Succeeded'})}
    $meta=[pscustomobject]@{PairId='fixture-pair';AttemptId='fixture-attempt';PlanHash=('b'*64);ManifestHash=('a'*64);InventorySource='TrustedInventory';Software=$software;ExcludedRegions=$excludedRegions;ExcludedRegionsBinding=$binding}
    $export=Export-WsmBackupItemResults $resultsPath $rows $meta
    if($Shape -ceq 'V1'){
        $legacy=Read-WsmJson $resultsPath
        $legacyRows=@($legacy.Rows | ForEach-Object {$_.PSObject.Properties.Remove('Workloads');$_.PSObject.Properties.Remove('RestoreCondition');$_})
        $legacyDoc=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='fixture';Kind='BackupItemResults';PairId=$legacy.PairId;AttemptId=$legacy.AttemptId;PlanHash=$legacy.PlanHash;ManifestHash=$legacy.ManifestHash;InventorySource=$legacy.InventorySource;GeneratedUtc=$legacy.GeneratedUtc;Counts=$legacy.Counts;Software=$legacy.Software;Rows=$legacyRows}
        Write-WsmJson $resultsPath $legacyDoc
        $export=[pscustomobject]@{SHA256=(Get-FileHash -LiteralPath $resultsPath -Algorithm SHA256).Hash}
    }
    $report=Export-WsmBackupOfflineReport $resultsPath $export.SHA256 (Join-Path $OutDir 'backup-report.html')
    $expected=[pscustomobject]@{
        Total=$rows.Count
        BackedUp=@($rows | Where-Object Status -CEQ 'BackedUp').Count
        NotBackedUp=@($rows | Where-Object Status -CEQ 'NotBackedUp').Count
        Rows=@($rows | ForEach-Object {[pscustomobject]@{ItemId=$_.ItemId;Name=$_.Name;Kind=$_.Kind;Status=$_.Status;ReasonCode=$_.ReasonCode;Reason=$_.Reason}})
        ExcludedRegions=@($excludedRegions | ForEach-Object {[pscustomobject]@{Path=$_.Path;ReasonCode=$_.ReasonCode;Reason=$_.Reason;NextStep=$_.NextStep}})
    }
    [IO.File]::WriteAllText((Join-Path $OutDir 'expected.json'),($expected | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    Write-Output $report.Path
} $OutDir $Shape $Scale
