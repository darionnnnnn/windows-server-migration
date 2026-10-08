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
Write-Host ('PASS: durable file rollback before/between/after rename, retained new data and drifting backup refusal. Evidence: '+$root)
