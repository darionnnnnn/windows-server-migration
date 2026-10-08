#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-rollback-recovery-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
& $module {
    param($Root)
    foreach($phase in @('BeforeMove','AfterDisplace','AfterRestore','Drift')){
        $folder=Join-Path $Root $phase;[void][IO.Directory]::CreateDirectory($folder);$target=Join-Path $folder 'business';$backup=Join-Path $folder '.wsm-backup-fixture';$retained=Join-Path $folder '.wsm-rollback-retained-fixture'
        [void][IO.Directory]::CreateDirectory($target);[void][IO.Directory]::CreateDirectory($backup);[IO.File]::WriteAllText((Join-Path $target 'data.txt'),'new transactions');[IO.File]::WriteAllText((Join-Path $backup 'data.txt'),'previous generation')
        $pair=[Guid]::NewGuid().ToString();$id='a'*64;$item=[pscustomobject]@{ItemId=$id;MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$target;Metadata='DaclOwner'}}
        $package=[pscustomobject]@{Manifest=[pscustomobject]@{BatchId=[Guid]::NewGuid().ToString();PairId=$pair;Target=[pscustomobject]@{Fingerprint=('b'*64)};PlanHash=('c'*64)}};$paths=Get-WsmOperationPaths (Join-Path $folder 'state') $pair;$state=Get-WsmOperationState $paths $package
        $op=[pscustomobject]@{ItemId=$id;Phase='RollbackPrepared';ManifestHash=('d'*64);Target=$target;Retained=$retained;CurrentHash=(Get-WsmFileScopeDigest $target DaclOwner);Backup=$backup;BackupHash=(Get-WsmFileScopeDigest $backup DaclOwner)}
        $state.Items=@([pscustomobject]@{ItemId=$id;Status='Succeeded';CreatedByTool=$true});$state.PendingOperations=@($op);Add-WsmJournal $paths $state RollbackIntent $id $op
        if($phase -ne 'BeforeMove'){[IO.Directory]::Move($target,$retained)}
        if($phase -eq 'AfterRestore'){[IO.Directory]::Move($backup,$target)}
        if($phase -eq 'Drift'){[IO.File]::WriteAllText((Join-Path $backup 'data.txt'),'unreviewed change');$blocked=$false;try{Complete-WsmFileRollback $item $op $paths $state}catch{$blocked=$true};if(-not $blocked -or -not [IO.Directory]::Exists($retained) -or -not [IO.Directory]::Exists($backup)){throw 'Drifting rollback backup consumed or adopted'};continue}
        Complete-WsmFileRollback $item $op $paths $state
        if($state.Items[0].Status -ne 'RolledBack' -or $state.PendingOperations.Count -ne 0 -or [IO.File]::ReadAllText((Join-Path $target 'data.txt')) -cne 'previous generation' -or [IO.File]::ReadAllText((Join-Path $retained 'data.txt')) -cne 'new transactions'){throw 'Rollback phase recovery lost previous/current data or ownership'}
        if(-not (Test-WsmJournal (Join-Path $folder 'state') $pair).Consistent){throw 'Recovered rollback journal/checkpoint differs'}
    }
} $root
& $module {
    param($Root)
    function script:Get-WsmAdapterState {param($Spec)[pscustomobject]@{Exists=$script:rollbackExists}}
    function script:Test-WsmAdapterConfiguration {param($Spec,$Phase)[pscustomobject]@{Passed=(-not $script:rollbackDrift -and ($Phase -eq 'Final' -or $script:rollbackStopped))}}
    function script:Invoke-WsmAdapterActivation {param($Spec,$Enable)if($Enable){throw 'Rollback activated producer'};$script:rollbackStopped=$true}
    function script:Remove-WsmCreatedAdapter {param($Spec)$script:removeCalls++;$script:rollbackExists=$false}
    foreach($phase in @('BeforeStop','AfterStop','AfterRemove','Drift')){
        $script:rollbackExists=$phase -ne 'AfterRemove';$script:rollbackStopped=$phase -eq 'AfterStop';$script:rollbackDrift=$phase -eq 'Drift';$script:removeCalls=0;$pair=[Guid]::NewGuid().ToString();$id='b'*64
        $item=[pscustomobject]@{ItemId=$id;MigrationSpec=[pscustomobject]@{Adapter='Service';Desired=[pscustomobject]@{Name='FixtureSvc'}}};$paths=Get-WsmOperationPaths (Join-Path $Root 'adapter-rollback') $pair
        $package=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$pair;BatchId=[Guid]::NewGuid().ToString();PlanHash=('a'*64);Target=[pscustomobject]@{Fingerprint=('c'*64)}}};$state=Get-WsmOperationState $paths $package
        $op=[pscustomobject]@{ItemId=$id;Phase='RollbackAdapter';Adapter='Service';ManifestHash=('d'*64);SpecHash=(Get-WsmHashText ($item.MigrationSpec | ConvertTo-Json -Depth 40 -Compress))};$state.Items=@([pscustomobject]@{ItemId=$id;Status='Succeeded';CreatedByTool=$true});$state.PendingOperations=@($op);Add-WsmJournal $paths $state RollbackIntent $id $op
        if($phase -eq 'Drift'){$blocked=$false;try{Complete-WsmAdapterRollback $item $op $paths $state}catch{$blocked=$true};if(-not $blocked -or $script:removeCalls -or -not $script:rollbackExists){throw 'Drifting rollback adapter removed'};continue}
        Complete-WsmAdapterRollback $item $op $paths $state
        if($script:rollbackExists -or $state.PendingOperations.Count -or $state.Items[0].Status -ne 'RolledBack' -or ($phase -eq 'AfterRemove' -and $script:removeCalls)){throw 'Adapter rollback phase recovery duplicated removal or retained pending ownership'}
    }
} $root
Write-Host ('PASS: durable file rollback before/between/after rename, retained new data and drifting backup refusal. Evidence: '+$root)
