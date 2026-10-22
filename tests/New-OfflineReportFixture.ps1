#requires -Version 5.1
# Builds a >250 row backup result set and its offline report for the real-browser test.
# Rows come from the real Get-WsmBackupItemResultRows so the browser sees production shapes.
param([Parameter(Mandatory)][string]$OutDir,[ValidateSet('V2','V1')][string]$Shape='V2')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
[void][IO.Directory]::CreateDirectory($OutDir)
& $module {
    param($OutDir,$Shape)
    $script:ToolVersion='fixture'
    $item={param([string]$Id,[string]$Name,$Spec,[string]$Decision,[string]$Kind='DataRoot',[string]$Category='Storage',$Deps=@())[pscustomobject]@{ItemId=$Id;Name=$Name;Kind=$Kind;Category=$Category;NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{Path=('C:\settings\'+$Id)};Decision=$Decision;MigrationSpec=$Spec;Dependencies=@($Deps)}}
    $file={param([string]$Channel)[pscustomobject]@{Adapter='FileScope';SourcePath=('D:\scope\'+$Channel);TransferChannel=$Channel}}
    $planItems=New-Object 'System.Collections.Generic.List[object]'
    $inventoryItems=New-Object 'System.Collections.Generic.List[object]'
    $artifacts=New-Object 'System.Collections.Generic.List[object]'
    $siteName='Site <img src=x onerror=alert(1)>'
    for($i=1;$i -le 300;$i++){
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
    $planItems.Add((& $item 'site-1' $siteName ([pscustomobject]@{Adapter='IISSite'}) 'Include' 'IISSite' 'Web' @([pscustomobject]@{ItemId='item-0001'},[pscustomobject]@{ItemId='item-0002'})))
    $plan=[pscustomobject]@{Items=@($planItems.ToArray())}
    $inventory=[pscustomobject]@{Items=@($inventoryItems.ToArray())}
    $rows=@(Get-WsmBackupItemResultRows $plan $inventory @($artifacts.ToArray()) $false)
    $software=[pscustomobject]@{
        SoftwareRows=@([pscustomobject]@{SoftwareId='sw-1';Name='Contoso Tool';Version='1.0';Publisher='Contoso';Architecture='x64';Scope='Machine';Location='C:\a';SourceKind='Uninstall';Disposition='Reinstall';DispositionText='新機重新安裝'})
        FeatureRows=@([pscustomobject]@{Name='Web Server (IIS)';FeatureName='Web-Server'})
        CoverageGaps=@([pscustomobject]@{Status='Partial';Probe='Uninstall';Scope='User';SID='S-1-5-21-<b>x</b>'})}
    $resultsPath=Join-Path $OutDir 'backup-item-results.json'
    $meta=[pscustomobject]@{PairId='fixture-pair';AttemptId='fixture-attempt';PlanHash=('b'*64);ManifestHash=('a'*64);InventorySource='TrustedInventory';Software=$software}
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
    }
    [IO.File]::WriteAllText((Join-Path $OutDir 'expected.json'),($expected | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    Write-Output $report.Path
} $OutDir $Shape
