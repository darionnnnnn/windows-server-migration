#requires -Version 5.1
# Builds a backup result set and offline report whose software tab exercises B4 (groups, decisions, chosen versions,
# notes, C1 counter-examples, empty and large inventories). Rows come from the real Get-WsmBackupSoftwareRows.
param([Parameter(Mandatory)][string]$OutDir,[ValidateSet('Normal','Big','Empty','Target','TargetComplete')][string]$Shape='Normal')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
[void][IO.Directory]::CreateDirectory($OutDir)
& $module {
    param($OutDir,$Shape)
    $script:ToolVersion='fixture'
    $item={param([string]$Id,[string]$Name,[string]$Decision,[string]$Kind='DataRoot',[string]$Category='Storage',$Deps=@())[pscustomobject]@{ItemId=$Id;Name=$Name;Kind=$Kind;Category=$Category;NaturalKey=('key-'+$Id);Settings=[pscustomobject]@{Path=('C:\settings\'+$Id)};Decision=$Decision;MigrationSpec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\x';TransferChannel='C'};Dependencies=@($Deps)}}
    $entry={param([string]$Id,[string]$Name,[string]$Version,[string]$Arch='x64',[string]$Scope='Machine',$ItemIds=@(),[string]$Account='')
        [pscustomobject]@{SoftwareId=$Id;Name=$Name;Version=$Version;Publisher='Contoso';Architecture=$Arch;Scope=$Scope;SID='';AccountContext=$Account;RegistryView='64';Location=('C:\Program Files\'+$Id);SourceKind='Uninstall';Evidence=[pscustomobject]@{Probe='Uninstall'};CaptureStatus='Success';ItemIds=@($ItemIds)}}
    if($Shape -cin @('Target','TargetComplete')){
        # Target projection: the real four-state mapping over comparison rows, passed through the closed HTML allow list.
        $cmp={param($Id,$Name,$Status,$Coverage,$Source='1.0',$Chosen='1.0',$Observed='')[pscustomobject]@{SoftwareId=$Id;Name=$Name;Publisher='Contoso';Scope='Machine';Architecture='x64';SourceVersion=$Source;ChosenVersion=$Chosen;ObservedTargetVersion=$Observed;Status=$Status;Reason='raw';TargetCoverageComplete=$Coverage}}
        $complete=($Shape -ceq 'TargetComplete')
        $list=@((& $cmp 'sw-a' 'Alpha agent' 'ChosenVersionObserved' $true '1.0' '1.0' '1.0'),(& $cmp 'sw-b' 'Bravo =runtime' 'DifferentFromChosenVersion' $true '1.0' '2.0' '1.5'),(& $cmp 'sw-c' 'Charlie service' 'TargetMissing' $true),(& $cmp 'sw-e' 'Echo twin' 'Ambiguous' $true),(& $cmp '' 'Foxtrot only here' 'TargetOnly' $true '' '' '9.9'))
        if(-not $complete){$list=@($list | ForEach-Object {$_.TargetCoverageComplete=$false;$_});$list+=@(& $cmp 'sw-d' 'Delta blind' 'TargetMissing' $false)}
        $check=Get-WsmWizardTargetSoftwareCheck ([pscustomobject]@{Document=[pscustomobject]@{ComparisonRevision=2};Comparison=[pscustomobject]@{Rows=$list}})
        $json=(ConvertTo-WsmWizardHtmlValue ([pscustomobject]@{status='NeedsTargetDecision';softwareCheck=$check})) | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path $OutDir 'target-software-check.json'),$json,(New-Object Text.UTF8Encoding($false)))
        Write-Output (Join-Path $OutDir 'target-software-check.json')
        return
    }
    $planItems=@(
        (& $item 'data-x' 'Shared library root' 'Include'),
        (& $item 'site-a' 'Site A' 'Include' 'IISSite' 'Web' @([pscustomobject]@{ItemId='data-x'},[pscustomobject]@{ItemId='feat-net'})),
        (& $item 'task-b' 'Task <b>B</b>' 'Include' 'ScheduledTask' 'Tasks'),
        (& $item 'excl-1' 'Excluded root' 'Exclude'))
    $inventory=[pscustomobject]@{Items=@(
        [pscustomobject]@{ItemId='feat-web';Name='Web Server (IIS)';Kind='WindowsFeature';Category='Roles';NaturalKey='Web-Server';Settings=[pscustomobject]@{};Status='Success'},
        [pscustomobject]@{ItemId='feat-net';Name='ASP.NET 4.5';Kind='WindowsFeature';Category='Roles';NaturalKey='Web-Asp-Net45';Settings=[pscustomobject]@{};Status='Success'})}
    $entries=New-Object 'System.Collections.Generic.List[object]'
    $decisions=New-Object 'System.Collections.Generic.List[object]'
    $requirements=New-Object 'System.Collections.Generic.List[object]'
    $choices=New-Object 'System.Collections.Generic.List[object]'
    $coverage=@([pscustomobject]@{Probe='Uninstall';Scope='Machine';SID='';View='64';Status='Success'})
    if($Shape -ceq 'Big'){
        for($i=1;$i -le 2501;$i++){$entries.Add((& $entry ('sw-big-{0:D4}' -f $i) ('Big tool {0:D4}' -f $i) '1.0' 'x64' 'Machine' $(if($i % 10 -eq 0){@('data-x')}else{@()})))}
    }elseif($Shape -ceq 'Normal'){
        $coverage+=@([pscustomobject]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-9';View='64';Status='PermissionDenied';ErrorKind='AccessDenied'})
        for($i=1;$i -le 25;$i++){$entries.Add((& $entry ('sw-req-{0:D2}' -f $i) ('Required lib {0:D2}' -f $i) ('{0}.0' -f $i) $(if($i % 2){'x64'}else{'x86'}) 'Machine' @('data-x')))}
        for($i=1;$i -le 5;$i++){$entries.Add((& $entry ('sw-viareq-{0:D2}' -f $i) ('Via requirement {0:D2}' -f $i) '2.1'));$requirements.Add([pscustomobject]@{RequirementId=('r'+$i);ProviderSoftwareId=('sw-viareq-{0:D2}' -f $i);ConsumerItemIds=@('task-b');Certainty='Confirmed';Decision='Required'})}
        for($i=1;$i -le 3;$i++){$entries.Add((& $entry ('sw-excl-{0:D2}' -f $i) ('Linked to excluded {0:D2}' -f $i) '3.0' 'x64' 'Machine' @('excl-1')))}
        for($i=1;$i -le 90;$i++){$entries.Add((& $entry ('sw-other-{0:D3}' -f $i) ('Other tool {0:D3}' -f $i) ('1.{0}' -f $i) $(if($i % 3 -eq 0){'x86'}else{'x64'})))}
        $entries.Add((& $entry 'sw-formula' '=SUM(1+1) Tool' '1.0'))
        $entries.Add((& $entry 'sw-unknown' 'Unknown version tool' ''))
        $entries.Add((& $entry 'sw-dual-86' 'Dual arch tool' '4.0' 'x86'))
        $entries.Add((& $entry 'sw-dual-64' 'Dual arch tool' '4.0' 'x64'))
        $entries.Add((& $entry 'sw-alice' 'Per user tool' '5.0' 'x64' 'User' @() 'HOST\alice'))
        $entries.Add((& $entry 'sw-bob' 'Per user tool' '5.0' 'x64' 'User' @() 'HOST\bob'))
        $dispositions=@('Reinstall','Portable','KeepCompatible','External','NotNeeded','Unknown','SpecialProduct')
        $index=0
        foreach($candidate in @($entries.ToArray() | Where-Object {$_.SoftwareId -like 'sw-other-*' -or $_.SoftwareId -like 'sw-req-*'})){
            $index++
            if($index % 2 -eq 0){continue}
            $hash=Get-WsmGeneralHostSoftwareFactsHash $candidate
            if($index % 11 -eq 0){$hash=('0'*64)}
            $decisions.Add([pscustomobject]@{SoftwareId=$candidate.SoftwareId;SoftwareHash=$hash;Disposition=$dispositions[$index % $dispositions.Count];Owner='owner';Reason=('license note '+$index+' password=hunter2');Evidence=('ticket-'+$index)})
        }
        $choices.Add([pscustomobject]@{SoftwareId='sw-req-01';SourceVersion='1.0';ChosenVersion='1.5';Reason='vendor dropped 1.0';UpdatedUtc='2026-10-22T00:00:00Z'})
        $choices.Add([pscustomobject]@{SoftwareId='sw-req-02';SourceVersion='0.1';ChosenVersion='9.9';Reason='stale';UpdatedUtc='2026-10-22T00:00:00Z'})
    }
    $general=[pscustomobject]@{SoftwareCatalog=[pscustomobject]@{Entries=@($entries.ToArray());Coverage=$coverage};SoftwareDecisions=@($decisions.ToArray());Requirements=@($requirements.ToArray())}
    $plan=[pscustomobject]@{Items=$planItems;GeneralHost=$general}
    $rows=@(Get-WsmBackupItemResultRows $plan $inventory @() $false)
    $software=Get-WsmBackupSoftwareRows $plan $inventory @($choices.ToArray())
    $meta=[pscustomobject]@{PairId='fixture-pair';AttemptId='fixture-attempt';PlanHash=('b'*64);ManifestHash=('a'*64);InventorySource='TrustedInventory';Software=$software}
    $resultsPath=Join-Path $OutDir 'backup-item-results.json'
    $export=Export-WsmBackupItemResults $resultsPath $rows $meta
    $report=Export-WsmBackupOfflineReport $resultsPath $export.SHA256 (Join-Path $OutDir 'backup-report.html')
    Write-Output $report.Path
} $OutDir $Shape
