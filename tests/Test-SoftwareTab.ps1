#requires -Version 5.1
# B4: software tab projection (grouping, chosen version, manual note, legacy and empty result sets, report CSV/checklist markup)
# and the Target-side four-state table over an existing comparison record.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-b4-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:ToolVersion='test'
        $check={param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
        $item={param([string]$Id,[string]$Name,[string]$Decision,[string]$Kind='DataRoot',[string]$Category='Storage',$Deps=@())[pscustomobject]@{ItemId=$Id;Name=$Name;Kind=$Kind;Category=$Category;NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{};Decision=$Decision;MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\x';TransferChannel='C'};Dependencies=@($Deps)}}
        $entry={param([string]$Id,[string]$Name,[string]$Version,[string]$Arch='x64',[string]$Scope='Machine',$ItemIds=@(),[string]$Account='')
            [pscustomobject]@{SoftwareId=$Id;Name=$Name;Version=$Version;Publisher='Contoso';Architecture=$Arch;Scope=$Scope;SID='';AccountContext=$Account;RegistryView='64';Location=('C:\'+$Id);SourceKind='Uninstall';Evidence=[pscustomobject]@{Probe='Uninstall'};CaptureStatus='Success';ItemIds=@($ItemIds)}}
        $siteName='Site <b>one</b>'
        $planItems=@(
            (& $item 'data1' 'Data one' 'Include'),
            (& $item 'site1' $siteName 'Include' 'IISSite' 'Web' @([pscustomobject]@{ItemId='data1'},[pscustomobject]@{ItemId='feat2'})),
            (& $item 'excl1' 'Excluded' 'Exclude'),
            (& $item 'pend1' 'Pending' 'Pending'))
        $entries=@(
            (& $entry 'sw-ids' 'Runtime A' '1.0' 'x64' 'Machine' @('data1')),
            (& $entry 'sw-req' 'Runtime B' '2.0'),
            (& $entry 'sw-none' 'Runtime C' '3.0'),
            (& $entry 'sw-excl' 'Runtime D' '4.0' 'x64' 'Machine' @('excl1')),
            (& $entry 'sw-pend' 'Runtime E' '5.0' 'x64' 'Machine' @('pend1')),
            (& $entry 'sw-cand' 'Runtime F' '6.0'),
            (& $entry 'sw-unknown' 'Unknown Version Tool' ''),
            (& $entry 'sw-x86' 'Dual Arch' '1.0' 'x86'),
            (& $entry 'sw-x64' 'Dual Arch' '1.0' 'x64'),
            (& $entry 'sw-alice' 'Per User Tool' '1.0' 'x64' 'User' @() 'HOST\alice'),
            (& $entry 'sw-bob' 'Per User Tool' '1.0' 'x64' 'User' @() 'HOST\bob'))
        $facts=$entries[0]
        $goodHash=Get-WsmGeneralHostSoftwareFactsHash $facts
        $decisions=@(
            [pscustomobject]@{SoftwareId='sw-ids';SoftwareHash=$goodHash;Disposition='Reinstall';Owner='alice';Reason='license is per seat, password=hunter2 on file';Evidence='ticket 1234'},
            [pscustomobject]@{SoftwareId='sw-req';SoftwareHash=('0'*64);Disposition='KeepCompatible';Owner='bob';Reason='';Evidence=''},
            [pscustomobject]@{SoftwareId='sw-none';Disposition='NotNeeded';Reason='not used'})
        $requirements=@(
            [pscustomobject]@{RequirementId='r1';ProviderSoftwareId='sw-req';ConsumerItemIds=@('data1');Certainty='Confirmed';Decision='Required'},
            [pscustomobject]@{RequirementId='r2';ProviderSoftwareId='sw-cand';ConsumerItemIds=@('data1');Certainty='Candidate';Decision='NotNeeded'})
        $plan=[pscustomobject]@{Items=$planItems;GeneralHost=[pscustomobject]@{SoftwareCatalog=[pscustomobject]@{Entries=$entries;Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='64';Status='Success'},[pscustomobject]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-9';View='64';Status='PermissionDenied';ErrorKind='AccessDenied'})};SoftwareDecisions=$decisions;Requirements=$requirements}}
        $inventory=[pscustomobject]@{Items=@([pscustomobject]@{ItemId='feat1';Name='Web Server (IIS)';Kind='WindowsFeature';Category='Roles';NaturalKey='Web-Server';Settings=[pscustomobject]@{};Status='Success'},[pscustomobject]@{ItemId='feat2';Name='Linked feature';Kind='WindowsFeature';Category='Roles';NaturalKey='Web-Asp-Net45';Settings=[pscustomobject]@{};Status='Success'})}
        $choices=@([pscustomobject]@{SoftwareId='sw-ids';SourceVersion='1.0';ChosenVersion='1.5';Reason='vendor dropped 1.0';UpdatedUtc='2026-10-22T00:00:00Z'},[pscustomobject]@{SoftwareId='sw-none';SourceVersion='0.1';ChosenVersion='9.9';Reason='old';UpdatedUtc='2026-10-22T00:00:00Z'})
        $result=Get-WsmBackupSoftwareRows $plan $inventory $choices
        $byId=@{};foreach($r in $result.SoftwareRows){$byId[[string]$r.SoftwareId]=$r}

        # --- grouping ---
        & $check ($byId['sw-ids'].RequiredBySelectedWorkload -and $byId['sw-ids'].HasLinkEvidence) 'Entry.ItemIds that point at an Include item must make the software required.'
        & $check (@($byId['sw-ids'].Workloads) -ccontains $siteName) 'A required entry must carry the workload names of its linked items.'
        & $check ($byId['sw-req'].RequiredBySelectedWorkload -and @($byId['sw-req'].Workloads) -ccontains $siteName) 'A Requirement whose provider is the entry must make it required through ConsumerItemIds.'
        & $check (-not $byId['sw-none'].RequiredBySelectedWorkload -and -not $byId['sw-none'].HasLinkEvidence -and @($byId['sw-none'].Workloads).Count -eq 0) 'Empty ItemIds without a Requirement must land in the other group without link evidence.'
        & $check (-not $byId['sw-excl'].RequiredBySelectedWorkload -and $byId['sw-excl'].HasLinkEvidence) 'A link to an Exclude item is evidence but not a selected workload.'
        & $check (-not $byId['sw-pend'].RequiredBySelectedWorkload -and $byId['sw-pend'].HasLinkEvidence) 'A link to a Pending item is evidence but not a selected workload.'
        & $check (-not $byId['sw-cand'].RequiredBySelectedWorkload -and -not $byId['sw-cand'].HasLinkEvidence) 'A Candidate requirement decided NotNeeded is not evidence of need.'
        $ordered=@($result.SoftwareRows | ForEach-Object {[bool]$_.RequiredBySelectedWorkload})
        $firstOther=[array]::IndexOf($ordered,$false);$lastRequired=[array]::LastIndexOf($ordered,$true)
        & $check ($lastRequired -ge 0 -and $firstOther -gt $lastRequired) 'Required rows must all come before the other rows.'
        Write-Host 'PASS: grouping and workload association.'

        # --- C1 counter-examples stay visible ---
        & $check (@($result.SoftwareRows).Count -eq $entries.Count) 'Every catalog entry must appear exactly once.'
        & $check ($byId['sw-unknown'].Version -ceq '未知') 'A blank version must show as unknown.'
        & $check (@($result.SoftwareRows | Where-Object Name -CEQ 'Dual Arch').Count -eq 2 -and (@($result.SoftwareRows | Where-Object Name -CEQ 'Dual Arch').Architecture | Sort-Object -Unique).Count -eq 2) 'Dual architecture must be two rows.'
        & $check ($byId['sw-alice'].AccountContext -ceq 'HOST\alice' -and $byId['sw-bob'].AccountContext -ceq 'HOST\bob') 'Multi-account rows must keep their account context.'
        & $check (@($result.CoverageGaps).Count -eq 1 -and $result.CoverageGaps[0].Status -ceq 'PermissionDenied') 'A permission-denied coverage gap must be reported.'
        & $check ($result.CatalogState -ceq 'Present') 'A catalog with entries is Present.'
        & $check (@($result.FeatureRows | Where-Object FeatureName -CEQ 'Web-Asp-Net45')[0].Workloads -ccontains $siteName -and @(@($result.FeatureRows | Where-Object FeatureName -CEQ 'Web-Server')[0].Workloads).Count -eq 0) 'Feature rows must carry structured workloads only.'
        Write-Host 'PASS: C1 counter-examples.'

        # --- chosen version, notes, decision state ---
        & $check ($byId['sw-ids'].ChosenVersion -ceq '1.5' -and $byId['sw-ids'].ChosenVersionBasis -ceq 'Choice') 'A matching choice must be shown as the chosen version.'
        & $check ($byId['sw-req'].ChosenVersion -ceq '2.0（同來源）' -and $byId['sw-req'].ChosenVersionBasis -ceq 'SameAsSource') 'No choice must show the source version labelled as same-as-source.'
        & $check ($byId['sw-none'].ChosenVersionBasis -ceq 'StaleChoice' -and $byId['sw-none'].ChosenVersion -ceq '3.0（同來源；原選用版本已過期，需重新選擇）') 'A choice whose SourceVersion no longer matches must not be applied.'
        & $check ($byId['sw-ids'].ManualNote.Contains('決策理由：') -and $byId['sw-ids'].ManualNote.Contains('證據：ticket 1234') -and $byId['sw-ids'].ManualNote.Contains('選用版本理由：vendor dropped 1.0')) 'ManualNote must combine the decision reason/evidence and the choice reason.'
        & $check (-not $byId['sw-ids'].ManualNote.Contains('hunter2') -and $byId['sw-ids'].ManualNote.Contains('password=[redacted]')) 'ManualNote must not carry secrets.'
        & $check ($byId['sw-cand'].ManualNote -ceq '') 'No decision and no choice must give an empty note.'
        & $check ($byId['sw-ids'].DecisionState -ceq 'Reviewed' -and $byId['sw-req'].DecisionState -ceq 'Stale' -and $byId['sw-cand'].DecisionState -ceq 'Unreviewed') 'DecisionState must be Reviewed / Stale / Unreviewed.'
        & $check ($byId['sw-ids'].Disposition -ceq 'Reinstall' -and $byId['sw-ids'].DispositionText -ceq '新機重新安裝' -and $byId['sw-cand'].DispositionText -ceq '尚未決定') 'The six dispositions plus undecided keep their text.'
        $viaPlan=$plan.PSObject.Copy();$viaPlan | Add-Member NoteProperty Assistive ([pscustomobject]@{SoftwareChoices=$choices}) -Force
        & $check (((Get-WsmBackupSoftwareRows $viaPlan $inventory).SoftwareRows | Where-Object SoftwareId -CEQ 'sw-ids').ChosenVersion -ceq '1.5') 'Plan.Assistive.SoftwareChoices must also be read.'
        Write-Host 'PASS: chosen version, note and decision state.'

        # --- empty inventory is not an error; a missing catalog is told apart ---
        $emptyPlan=[pscustomobject]@{Items=@();GeneralHost=[pscustomobject]@{SoftwareCatalog=[pscustomobject]@{Entries=@();Coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='64';Status='Success'})}}}
        $emptyResult=Get-WsmBackupSoftwareRows $emptyPlan ([pscustomobject]@{Items=@()})
        & $check (@($emptyResult.SoftwareRows).Count -eq 0 -and $emptyResult.CatalogState -ceq 'Present' -and @($emptyResult.CoverageGaps).Count -eq 0) 'A valid empty catalog is Present with no rows.'
        $noCatalog=Get-WsmBackupSoftwareRows ([pscustomobject]@{Items=@()}) $null
        & $check ($noCatalog.CatalogState -ceq 'Unavailable') 'No catalog at all is Unavailable.'
        $docPath=Join-Path $Root 'full.json'
        $meta={param($software)[pscustomobject]@{PairId='p';AttemptId='a';PlanHash=('b'*64);ManifestHash=('a'*64);InventorySource='TrustedInventory';Software=$software}}
        $rows=@(Get-WsmBackupItemResultRows $plan $inventory @() $false)
        $export=Export-WsmBackupItemResults $docPath $rows (& $meta $result)
        $report=Export-WsmBackupOfflineReport $docPath $export.SHA256 (Join-Path $Root 'full.html')
        $html=[IO.File]::ReadAllText($report.Path,[Text.Encoding]::UTF8)
        & $check ($html.Contains('data-csv-meta="software"') -and $html.Contains('data-sid="sw-ids"')) 'Software table must carry SoftwareId for the CSV tail.'
        & $check ($html.Contains('data-filters="0:分組;9:決策;5:架構"')) 'Software table must filter by group, decision and architecture.'
        & $check (-not $html.Contains('Site <b>one</b>') -and $html.Contains('Site &lt;b&gt;one&lt;/b&gt;')) 'Workload names must be escaped in the report.'
        & $check ($html.Contains('id="checklist"') -and ([regex]::Matches($html,'class="check-box"').Count -eq (@($result.SoftwareRows).Count+@($result.FeatureRows).Count))) 'The printable checklist must hold one check box per software row and feature row.'
        $firstRequired=$html.IndexOf('已選工作負載必需（');$firstOther=$html.IndexOf('其他已發現軟體（')
        & $check ($firstRequired -ge 0 -and $firstOther -gt $firstRequired) 'The checklist must list the required group first.'
        $emptyExport=Export-WsmBackupItemResults (Join-Path $Root 'empty.json') $rows (& $meta $emptyResult)
        $emptyReport=Export-WsmBackupOfflineReport (Join-Path $Root 'empty.json') $emptyExport.SHA256 (Join-Path $Root 'empty.html')
        $emptyHtml=[IO.File]::ReadAllText($emptyReport.Path,[Text.Encoding]::UTF8)
        & $check ($emptyHtml.Contains('沒有發現已安裝軟體') -and -not $emptyHtml.Contains('table id="tbl-software"')) 'An empty catalog must say no software was found, not show a table or an error.'
        $noCatalogExport=Export-WsmBackupItemResults (Join-Path $Root 'nocat.json') $rows (& $meta $noCatalog)
        $noCatalogHtml=[IO.File]::ReadAllText((Export-WsmBackupOfflineReport (Join-Path $Root 'nocat.json') $noCatalogExport.SHA256 (Join-Path $Root 'nocat.html')).Path,[Text.Encoding]::UTF8)
        & $check ($noCatalogHtml.Contains('來源軟體盤點不可用') -and -not $noCatalogHtml.Contains('沒有發現已安裝軟體')) 'A missing catalog must not be presented as an empty inventory.'
        Write-Host 'PASS: empty inventory and report markup.'

        # --- legacy result set (software rows written before B4) ---
        $legacySoftware=[pscustomobject]@{SoftwareRows=@([pscustomobject]@{SoftwareId='sw-1';Name='Contoso Tool';Version='1.0';Publisher='Contoso';Architecture='x64';Scope='Machine';Location='C:\a';SourceKind='Uninstall';Disposition='Reinstall';DispositionText='新機重新安裝'});FeatureRows=@([pscustomobject]@{Name='Web Server (IIS)';FeatureName='Web-Server'});CoverageGaps=@()}
        $legacyExport=Export-WsmBackupItemResults (Join-Path $Root 'legacy.json') $rows (& $meta $legacySoftware)
        $legacyHtml=[IO.File]::ReadAllText((Export-WsmBackupOfflineReport (Join-Path $Root 'legacy.json') $legacyExport.SHA256 (Join-Path $Root 'legacy.html')).Path,[Text.Encoding]::UTF8)
        & $check ($legacyHtml.Contains('此結果集未記錄工作負載分組')) 'A legacy software set must say grouping was not recorded.'
        $legacyRowFree=[regex]::Match($legacyHtml,'(?s)<table id="tbl-software".*?</table>').Value
        & $check ($legacyRowFree.Contains('未記錄') -and -not $legacyRowFree.Contains('已選工作負載必需') -and -not $legacyRowFree.Contains('其他已發現軟體')) 'A legacy row must show 未記錄 instead of inventing a group.'
        Write-Host 'PASS: legacy software rows.'

        # --- 2501 rows: nothing is capped in the printable checklist ---
        $bigEntries=@(1..2501 | ForEach-Object {& $entry ('sw-big-'+$_) ('Big '+$_) '1.0'})
        $bigPlan=[pscustomobject]@{Items=@();GeneralHost=[pscustomobject]@{SoftwareCatalog=[pscustomobject]@{Entries=$bigEntries;Coverage=@()}}}
        $big=Get-WsmBackupSoftwareRows $bigPlan $null
        $bigExport=Export-WsmBackupItemResults (Join-Path $Root 'big.json') @() (& $meta $big)
        $bigHtml=[IO.File]::ReadAllText((Export-WsmBackupOfflineReport (Join-Path $Root 'big.json') $bigExport.SHA256 (Join-Path $Root 'big.html')).Path,[Text.Encoding]::UTF8)
        & $check ([regex]::Matches($bigHtml,'class="check-box"').Count -eq 2501) 'The printable checklist must not be truncated at 2000 rows.'
        Write-Host 'PASS: checklist is not truncated.'

        # --- Target four-state table ---
        $state={param([string]$Status,$Coverage)(Get-WsmWizardSoftwareCheckState $Status $Coverage).Code}
        & $check ((& $state 'ChosenVersionObserved' $true) -ceq 'Installed') 'ChosenVersionObserved is Installed.'
        & $check ((& $state 'DifferentFromChosenVersion' $true) -ceq 'Different') 'DifferentFromChosenVersion is Different.'
        & $check ((& $state 'TargetMissing' $true) -ceq 'Missing') 'TargetMissing with complete coverage is Missing.'
        & $check ((& $state 'TargetMissing' $false) -ceq 'Unknown' -and (& $state 'TargetMissing' $null) -ceq 'Unknown' -and (& $state 'TargetMissing' 'true') -ceq 'Unknown') 'TargetMissing without proven complete coverage is Unknown.'
        foreach($other in @('TargetUnknown','Ambiguous','TargetEvidenceIncomplete','SourceEvidenceIncomplete','VersionUnknown','VersionEvidenceMismatch','StaleChosenVersion','SomethingNew','')){& $check ((& $state $other $true) -ceq 'Unknown') ('Status '+$other+' must be Unknown.')}
        $cmpRow={param($Id,$Name,$Status,$Coverage,$Source='1.0',$Chosen='1.0',$Observed='')[pscustomobject]@{SoftwareId=$Id;Name=$Name;Publisher='Contoso';Scope='Machine';Architecture='x64';SourceVersion=$Source;ChosenVersion=$Chosen;ObservedTargetVersion=$Observed;Status=$Status;Reason='raw english reason';TargetCoverageComplete=$Coverage}}
        $record=[pscustomobject]@{Path='x';SHA256=('c'*64);Document=[pscustomobject]@{ComparisonRevision=3};Comparison=[pscustomobject]@{Rows=@(
            (& $cmpRow 's1' 'Installed one' 'ChosenVersionObserved' $true '1.0' '1.0' '1.0'),
            (& $cmpRow 's2' 'Different one' 'DifferentFromChosenVersion' $true '1.0' '2.0' '1.5'),
            (& $cmpRow 's3' 'Missing one' 'TargetMissing' $true),
            (& $cmpRow 's4' 'Missing but blind' 'TargetMissing' $false),
            (& $cmpRow 's5' 'Ambiguous one' 'Ambiguous' $true),
            (& $cmpRow '' 'Only here' 'TargetOnly' $true '' '' '9.9'))}}
        $projection=Get-WsmWizardTargetSoftwareCheck $record
        $codes=@{};foreach($r in $projection.Rows){$codes[[string]$r.SoftwareId]=$r.CheckState}
        & $check ($codes['s1'] -ceq 'Installed' -and $codes['s2'] -ceq 'Different' -and $codes['s3'] -ceq 'Missing' -and $codes['s4'] -ceq 'Unknown' -and $codes['s5'] -ceq 'Unknown') 'Each of the four states needs a row, and incomplete coverage must not read as Missing.'
        & $check (@($projection.Rows).Count -eq 5 -and @($projection.TargetOnlyRows).Count -eq 1 -and $projection.TargetOnlyRows[0].Name -ceq 'Only here') 'TargetOnly rows must stay out of the four states and be listed apart.'
        & $check ($projection.CoverageComplete -eq $false -and $projection.ComparisonRevision -eq 3 -and $projection.available) 'Mixed coverage must read as incomplete.'
        & $check (@($projection.Rows | Where-Object {$_.CheckState -cnotin @('Installed','Different','Missing','Unknown')}).Count -eq 0) 'Only the four states may appear.'
        & $check (@(@($projection.Rows | ForEach-Object CheckReason) | Where-Object {-not $_}).Count -eq 0) 'Every row needs a Chinese reason.'
        Write-Host 'PASS: four-state table.'

        # --- no comparison material: nothing to show, no fake values ---
        & $check ($null -eq (Get-WsmWizardTargetSoftwareCheck $null)) 'No comparison record must project nothing.'
        & $check ($null -eq (Get-WsmWizardTargetSoftwareCheck ([pscustomobject]@{Comparison=$null}))) 'A record without rows must project nothing.'
        $empty=ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{status='NeedsComparison';comparison=$null;softwareCheck=(Get-WsmWizardTargetSoftwareCheck $null)})
        & $check ($null -eq $empty.softwareCheck -and $null -eq $empty.comparison -and -not [bool]($empty.PSObject.Properties | Where-Object Name -EQ 'Rows')) 'The HTML projection must not carry a software check without comparison material.'
        $shown=ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{status='ReadyForRestore';softwareCheck=$projection})
        & $check (@($shown.softwareCheck.Rows).Count -eq 5 -and $shown.softwareCheck.Rows[0].CheckStateText -and $shown.softwareCheck.Rows[0].ObservedTargetVersion -ne $null -and @($shown.softwareCheck.TargetOnlyRows).Count -eq 1) 'The new projection fields must pass the closed HTML allow list.'
        Write-Host 'PASS: no comparison material.'
    } $root
}
finally{
    if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}
}
Write-Host 'PASS: software tab.'
