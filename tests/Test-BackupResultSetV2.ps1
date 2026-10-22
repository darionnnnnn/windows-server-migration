#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-rs2-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:ToolVersion='test'
        $check={param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
        $item={param([string]$Id,[string]$Name,$Spec,[string]$Decision,[string]$Kind='DataRoot',[string]$Category='Storage',$Deps=@(),$Classification=$null)
            $o=[pscustomobject]@{ItemId=$Id;Name=$Name;Kind=$Kind;Category=$Category;NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{Path=('C:\settings\'+$Id)};Decision=$Decision;MigrationSpec=$Spec;Dependencies=@($Deps)}
            if($Classification){$o|Add-Member NoteProperty Classification ([pscustomobject]@{Disposition=$Classification})}
            $o}
        $file={param([string]$Channel)[pscustomobject]@{Adapter='FileScope';SourcePath=('D:\scope\'+$Channel);TransferChannel=$Channel}}
        $xssWorkload='Site <img src=x onerror=alert(1)>'
        $plan=[pscustomobject]@{Items=@(
            (& $item 'data1' 'Data one' (& $file 'C') 'Include'),
            (& $item 'data2' 'Data two' (& $file 'C') 'Include'),
            (& $item 'site' $xssWorkload ([pscustomobject]@{Adapter='IISSite'}) 'Include' 'IISSite' 'Web' @([pscustomobject]@{ItemId='data1'})),
            (& $item 'svc' 'Svc' ([pscustomobject]@{Adapter='Service'}) 'Include' 'Service' 'Services'),
            (& $item 'cert' 'Cert' ([pscustomobject]@{Adapter='Certificate'}) 'Include' 'Certificate' 'Security'),
            (& $item 'iiscfg' 'IIS section' ([pscustomobject]@{Adapter='IISConfig'}) 'Include' 'IISSectionConfig' 'Web'),
            (& $item 'special' 'Special product' ([pscustomobject]@{Adapter='Service'}) 'Include' 'RegistryKey' 'Runtime' @() 'SpecialProduct'),
            (& $item 'excl' 'Excluded' (& $file 'C') 'Exclude'),
            (& $item 'pend' 'Pending' (& $file 'C') 'Pending'),
            (& $item 'pd' 'Denied but planned' (& $file 'C') 'Pending'))}
        $inventory=[pscustomobject]@{Items=@(
            [pscustomobject]@{ItemId='pd';Name='Denied but planned';Kind='DataRoot';Category='Storage';NaturalKey='key-pd';Settings=[pscustomobject]@{};Status='PermissionDenied'},
            [pscustomobject]@{ItemId='invdenied';Name='Inventory denied';Kind='DataRoot';Category='Storage';NaturalKey='key-invdenied';Settings=[pscustomobject]@{Path='E:\denied'};Status='PermissionDenied'},
            [pscustomobject]@{ItemId='invok';Name='Inventory only';Kind='DataRoot';Category='Storage';NaturalKey='key-invok';Settings=[pscustomobject]@{Path='E:\ok'};Status='Success'},
            [pscustomobject]@{ItemId='excl';Name='Excluded';Kind='DataRoot';Category='Storage';NaturalKey='key-excl';Settings=[pscustomobject]@{};Status='PermissionDenied'})}
        $artifacts=@(
            [pscustomobject]@{ItemId='data1';RelativePath='a.txt';Directory=$false;Data=[pscustomobject]@{Bytes=10}},
            [pscustomobject]@{ItemId='data2';RelativePath='b.txt';Directory=$false;Data=[pscustomobject]@{Bytes=20}})
        $rows=@(Get-WsmBackupItemResultRows $plan $inventory $artifacts $false)
        $byId=@{};foreach($r in $rows){$byId[[string]$r.ItemId]=$r}

        # Invariant: every discovered item appears exactly once, and BackedUp + NotBackedUp is the whole set.
        $expectedIds=@(@($plan.Items.ItemId)+@($inventory.Items.ItemId) | Sort-Object -Unique)
        & $check ($rows.Count -eq $expectedIds.Count -and @($rows.ItemId | Sort-Object -Unique).Count -eq $rows.Count) 'Rows must contain each discovered ItemId exactly once.'
        & $check ((@($rows.ItemId | Sort-Object) -join '|') -ceq ($expectedIds -join '|')) 'Rows must be exactly the union of plan and inventory items.'
        $backed=@($rows | Where-Object Status -CEQ 'BackedUp');$notBacked=@($rows | Where-Object Status -CEQ 'NotBackedUp')
        & $check (($backed.Count+$notBacked.Count) -eq $expectedIds.Count -and @($backed.ItemId | Where-Object {@($notBacked.ItemId) -contains $_}).Count -eq 0) 'BackedUp and NotBackedUp must partition all discovered items.'
        Write-Host 'PASS: union invariant.'

        # RestoreCondition decision table: every code at least once.
        & $check ($byId['data1'].RestoreCondition.Code -ceq 'Restorable') 'File payload must be Restorable.'
        & $check ($byId['svc'].RestoreCondition.Code -ceq 'RequiresPrerequisite' -and $byId['site'].RestoreCondition.Code -ceq 'RequiresPrerequisite' -and $byId['cert'].RestoreCondition.Code -ceq 'RequiresPrerequisite') 'Service, site and certificate must require a prerequisite.'
        & $check ($byId['iiscfg'].RestoreCondition.Code -ceq 'RequiresPrerequisite' -and $byId['special'].RestoreCondition.Code -ceq 'ManualOnly') 'IIS configuration with a typed spec needs the IIS role first; special products are ManualOnly.'
        & $check ($byId['excl'].RestoreCondition.Code -ceq 'NotApplicable' -and $byId['pend'].RestoreCondition.Code -ceq 'NotApplicable') 'Not backed up rows must be NotApplicable.'
        foreach($code in @('Restorable','RequiresPrerequisite','ManualOnly','NotApplicable')){& $check (@($rows | Where-Object {$_.RestoreCondition.Code -ceq $code}).Count -ge 1) ('No row exercised RestoreCondition '+$code)}
        foreach($r in $rows){& $check ([bool][string]$r.RestoreCondition.Text) 'Every RestoreCondition needs Chinese text.'}
        & $check ((Get-WsmBackupRestoreCondition 'BackedUp' 'DataRoot' 'C' '').Code -ceq 'Restorable' -and (Get-WsmBackupRestoreCondition 'NotBackedUp' 'Service' 'Configuration' '').Code -ceq 'NotApplicable') 'Restore condition helper decision table mismatch.'
        Write-Host 'PASS: restore condition table.'

        # Reason codes: PermissionDenied only for uncaptured rows without an explicit decision.
        & $check ($byId['invdenied'].ReasonCode -ceq 'PermissionDenied' -and $byId['invdenied'].Status -ceq 'NotBackedUp' -and $byId['invdenied'].NextStep) 'Inventory PermissionDenied item must carry the PermissionDenied reason and a next step.'
        & $check ($byId['pd'].ReasonCode -ceq 'PermissionDenied') 'A pending plan item with PermissionDenied discovery status must be PermissionDenied.'
        & $check ($byId['excl'].ReasonCode -ceq 'Excluded') 'An explicit user exclusion must stay Excluded even when discovery was denied.'
        & $check ($byId['invok'].ReasonCode -ceq 'NotSelected') 'A readable inventory-only item must stay NotSelected.'
        Write-Host 'PASS: reason codes.'

        # Workload association only from recorded relations.
        & $check (@($byId['data1'].Workloads) -ccontains $xssWorkload -and @($byId['site'].Workloads) -ccontains $xssWorkload) 'A dependency and its consuming site must show the site workload.'
        & $check (@($byId['data2'].Workloads).Count -eq 0 -and $null -ne $byId['data2'].Workloads) 'An unrelated item must have an empty Workloads array.'
        & $check (@($byId['svc'].Workloads) -ccontains 'Svc') 'A business item is its own workload.'
        & $check (-not (@($byId['invok'].Workloads) -contains 'Site')) 'No workload may be inferred from a name.'
        $discovery=[pscustomobject]@{References=@([pscustomobject]@{ConsumerItemId='svc';ResourceItemId='data2'})}
        $withDiscovery=@(Get-WsmBackupItemResultRows $plan $inventory $artifacts $false $discovery)
        & $check (@((@($withDiscovery | Where-Object ItemId -CEQ 'data2')[0]).Workloads) -ccontains 'Svc') 'WorkloadDiscovery references must also associate workloads.'
        Write-Host 'PASS: workload association.'

        # Coverage regions.
        $gaps=@([pscustomobject]@{Status='Partial';Probe='Uninstall';Scope='User';SID='S-1-5-21-1'})
        $regions=@(Get-WsmBackupCoverageRegions 'TrustedInventory' $gaps)
        & $check ($regions.Count -eq 1 -and $regions[0].Region -like '*Uninstall*' -and $regions[0].Reason -and $regions[0].NextStep) 'A software coverage gap must become one region with reason and next step.'
        & $check (@(Get-WsmBackupCoverageRegions 'TrustedInventory' @()).Count -eq 0) 'No gaps must give an empty region list.'
        & $check (@(Get-WsmBackupCoverageRegions 'Unavailable' @()).Count -eq 1) 'An unavailable source inventory must be reported as an uncovered region.'
        $regionName='Region <script>alert(1)</script>'
        $software=[pscustomobject]@{SoftwareRows=@();FeatureRows=@();CoverageGaps=@()}
        $manifestHash='1234567890abcdef'*4;$planHash='fedcba0987654321'*4
        $metaFull=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=$planHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';Software=$software;CoverageRegions=@([pscustomobject]@{Region=$regionName;Reason='r';NextStep='n'})}
        $resultsPath=Join-Path $Root 'full.json'
        $export=Export-WsmBackupItemResults $resultsPath $rows $metaFull
        $doc=Read-WsmJson $resultsPath
        & $check ($doc.SchemaVersion -eq 2 -and @($doc.CoverageRegions).Count -eq 1) 'Results must be SchemaVersion 2 with coverage regions.'
        $report=Export-WsmBackupOfflineReport $resultsPath $export.SHA256 (Join-Path $Root 'full.html')
        $html=[IO.File]::ReadAllText($report.Path,[Text.Encoding]::UTF8)
        & $check ($html.Contains($manifestHash) -and $html.Contains($planHash)) 'Report must show the full ManifestHash and PlanHash.'
        & $check ($html.Contains('不在此報告判定') -and $html.Contains('資料已備份') -and $html.Contains('業務可用')) 'Report must explain the four status layers.'
        & $check ($html.Contains('探索未涵蓋區域') -and $html.Contains('不是項目')) 'Pending section must carry the coverage region table title.'
        & $check ($html.Contains('role="status" aria-atomic="true"') -or $html.Contains("setAttribute('role','status')")) 'Report needs a single status element.'
        # Escaping of the new fields.
        & $check (-not $html.Contains('<img src=x') -and $html.Contains('&lt;img src=x')) 'Workload names must be HTML-escaped.'
        & $check (-not $html.Contains('<script>alert(1)') -and $html.Contains('Region &lt;script&gt;')) 'Region names must be HTML-escaped.'
        Write-Host 'PASS: coverage regions and report fields.'

        # Empty region list and legacy results.
        $emptyMeta=[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=$planHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';Software=$software}
        $emptyPath=Join-Path $Root 'empty.json'
        $emptyExport=Export-WsmBackupItemResults $emptyPath $rows $emptyMeta
        $emptyReport=Export-WsmBackupOfflineReport $emptyPath $emptyExport.SHA256 (Join-Path $Root 'empty.html')
        & $check ([IO.File]::ReadAllText($emptyReport.Path,[Text.Encoding]::UTF8).Contains('沒有記錄到未涵蓋區域')) 'An empty region list must say nothing was recorded.'
        $legacyRows=@($rows | Select-Object -Property * -ExcludeProperty Workloads,RestoreCondition)
        $legacyPath=Join-Path $Root 'legacy.json'
        Write-WsmJson $legacyPath ([pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='old';Kind='BackupItemResults';PairId='p';AttemptId='a';PlanHash=$planHash;ManifestHash=$manifestHash;InventorySource='TrustedInventory';GeneratedUtc='2026-10-20T00:00:00Z';Counts=[pscustomobject]@{Total=$rows.Count};Software=$software;Rows=$legacyRows})
        $legacyReport=Export-WsmBackupOfflineReport $legacyPath (Get-FileHash -LiteralPath $legacyPath -Algorithm SHA256).Hash (Join-Path $Root 'legacy.html')
        $legacyHtml=[IO.File]::ReadAllText($legacyReport.Path,[Text.Encoding]::UTF8)
        & $check ($legacyHtml.Contains('此結果集未記錄') -and $legacyHtml.Contains('未記錄') -and $legacyHtml.Contains('此結果集為舊格式')) 'Legacy results must say the new fields were not recorded.'
        & $check (-not $legacyHtml.Contains('>未關聯<') -and -not $legacyHtml.Contains('沒有記錄到未涵蓋區域')) 'Legacy results must not present missing data as an empty set.'
        Write-Host 'PASS: empty and legacy results.'

        # Same ItemId, same status and reason code in JSON and HTML.
        foreach($r in $doc.Rows){
            $needle='data-id="'+$r.ItemId+'" data-status="'+$r.Status+'" data-reason="'+$r.ReasonCode+'"'
            & $check ($html.Contains($needle)) ('Report row attributes do not match the results JSON for '+$r.ItemId)
        }
        Write-Host 'PASS: JSON and HTML agree per ItemId.'
    } $root
}
finally{
    if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}
}
Write-Host 'PASS: backup result set v2.'
