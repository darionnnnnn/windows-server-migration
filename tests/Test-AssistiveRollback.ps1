#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-assistive-rollback-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($root)
        function Check([bool]$condition,[string]$message){if(-not $condition){throw $message};$script:rollbackChecks++}
        function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail){$script:rollbackJournal+=@($Action)}
        $script:rollbackChecks=0;$script:rollbackJournal=@()
        $itemId='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        $target=Join-Path $root 'scope';$nested=Join-Path $target 'nested';$empty=Join-Path $target 'empty'
        [void][IO.Directory]::CreateDirectory($nested);[void][IO.Directory]::CreateDirectory($empty)
        $external=Join-Path $target 'operator.txt';[IO.File]::WriteAllText($external,'operator-owned')
        $file=Join-Path $nested 'settings.ini';$backup=$file+'.wsm-assistive-backup-'+$itemId.Substring(0,12)+'-'+[Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($file,'new-generation');[IO.File]::WriteAllText($backup,'prior-generation')
        $fileHash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();$backupHash=(Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant()
        $fileMetadata=Get-WsmFileMetadata $file 'DaclOwner';$backupMetadata=Get-WsmFileMetadata $backup 'DaclOwner';$priorDirectoryMetadata=Get-WsmFileMetadata $nested 'DaclOwner'
        $changedDirectoryMetadata=$priorDirectoryMetadata.PSObject.Copy();$changedDirectoryMetadata.LastWriteUtc=([DateTime]::UtcNow.AddMinutes(-3).ToString('o'));Set-WsmFileMetadata $nested $changedDirectoryMetadata @{};$currentDirectoryMetadata=Get-WsmFileMetadata $nested 'DaclOwner'
        $rootMetadata=Get-WsmFileMetadata $target 'DaclOwner';$emptyMetadata=Get-WsmFileMetadata $empty 'DaclOwner'
        $record=[pscustomobject]@{ItemId=$itemId;Status='Succeeded';CreatedByTool=$true;Target=$target;OwnedFiles=@([pscustomobject]@{RelativePath='nested\settings.ini';TargetPath=$file;SHA256=$fileHash;MetadataHash=(Get-WsmAssistiveMetadataHash $fileMetadata);Backup=$backup;BackupHash=$backupHash;BackupMetadataHash=(Get-WsmAssistiveMetadataHash $backupMetadata);Generation=2});OwnedDirectories=@([pscustomobject]@{RelativePath='nested';TargetPath=$nested;MetadataHash=(Get-WsmAssistiveMetadataHash $currentDirectoryMetadata);BackupMetadata=$priorDirectoryMetadata;BackupMetadataHash=(Get-WsmAssistiveMetadataHash $priorDirectoryMetadata);CreatedByTool=$false;Generation=2},[pscustomobject]@{RelativePath='empty';TargetPath=$empty;MetadataHash=(Get-WsmAssistiveMetadataHash $emptyMetadata);BackupMetadata=$null;BackupMetadataHash='';CreatedByTool=$true;Generation=2},[pscustomobject]@{RelativePath='';TargetPath=$target;MetadataHash=(Get-WsmAssistiveMetadataHash $rootMetadata);BackupMetadata=$null;BackupMetadataHash='';CreatedByTool=$true;Generation=2})}
        $state=[pscustomobject]@{Items=@($record);PendingOperations=@()};$paths=[pscustomobject]@{Root=$root;State='';Journal=''};$spec=[pscustomobject]@{Adapter='FileScope';TargetPath=$target;Metadata='DaclOwner'};$item=[pscustomobject]@{ItemId=$itemId;MigrationSpec=$spec}
        $action=[pscustomobject]@{RelativePath='nested\settings.ini';TargetPath=$file;Retained=(Join-Path $nested ('.wsm-assistive-rollback-'+[Guid]::NewGuid().ToString('N')));CurrentHash=$fileHash;CurrentMetadataHash=(Get-WsmAssistiveMetadataHash $fileMetadata);Backup=$backup;BackupHash=$backupHash;BackupMetadataHash=(Get-WsmAssistiveMetadataHash $backupMetadata);BackupMetadata=$backupMetadata}
        $operation=[pscustomobject]@{ItemId=$itemId;Phase='RollbackAssistiveFiles';ManifestHash=('a'*64);Target=$target;Files=@($action);Directories=@([pscustomobject]@{RelativePath='nested';TargetPath=$nested;CurrentMetadataHash=(Get-WsmAssistiveMetadataHash $currentDirectoryMetadata);CurrentMetadata=$currentDirectoryMetadata;BackupMetadata=$priorDirectoryMetadata;BackupMetadataHash=(Get-WsmAssistiveMetadataHash $priorDirectoryMetadata);CreatedByTool=$false},[pscustomobject]@{RelativePath='empty';TargetPath=$empty;CurrentMetadataHash=(Get-WsmAssistiveMetadataHash $emptyMetadata);CurrentMetadata=$emptyMetadata;BackupMetadata=$null;BackupMetadataHash='';CreatedByTool=$true},[pscustomobject]@{RelativePath='';TargetPath=$target;CurrentMetadataHash=(Get-WsmAssistiveMetadataHash $rootMetadata);CurrentMetadata=$rootMetadata;BackupMetadata=$null;BackupMetadataHash='';CreatedByTool=$true})}
        Complete-WsmAssistiveFileRollback $item $operation $paths $state
        Check ([IO.File]::ReadAllText($file) -ceq 'prior-generation') 'Rollback did not restore the exact prior per-file backup.'
        Check (-not [IO.File]::Exists($backup) -and [IO.File]::Exists($action.Retained)) 'Rollback did not retain displaced current bytes or consume the verified prior backup.'
        Check ([IO.File]::ReadAllText($external) -ceq 'operator-owned') 'Rollback removed or replaced unowned external content in the merged root.'
        Check (-not [IO.Directory]::Exists($empty)) 'Rollback did not remove an empty directory created by the tool.'
        Check ((Get-WsmAssistiveMetadataHash (Get-WsmFileMetadata $nested 'DaclOwner')) -ceq (Get-WsmAssistiveMetadataHash $priorDirectoryMetadata)) 'Rollback did not restore and read back prior owned-directory metadata.'
        Check ($record.Status -ceq 'RolledBack' -and -not $record.CreatedByTool) 'Per-file rollback did not retire the generation ownership record.'
        Complete-WsmAssistiveFileRollback $item $operation $paths $state
        Check ([IO.File]::ReadAllText($file) -ceq 'prior-generation') 'Interrupted rollback replay was not idempotent after the prior backup move.'

        $driftRoot=Join-Path $root 'drift';[void][IO.Directory]::CreateDirectory($driftRoot);$driftFile=Join-Path $driftRoot 'owned.bin';[IO.File]::WriteAllText($driftFile,'operator drift')
        $driftHash=(Get-FileHash -LiteralPath $driftFile -Algorithm SHA256).Hash.ToLowerInvariant();$driftMetadata=Get-WsmFileMetadata $driftFile 'DaclOwner';$driftRecord=[pscustomobject]@{ItemId=$itemId;Status='Succeeded';CreatedByTool=$true};$driftState=[pscustomobject]@{Items=@($driftRecord);PendingOperations=@()};$driftItem=[pscustomobject]@{ItemId=$itemId;MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$driftRoot;Metadata='DaclOwner'}};$driftAction=[pscustomobject]@{RelativePath='owned.bin';TargetPath=$driftFile;Retained=(Join-Path $driftRoot ('.wsm-assistive-rollback-'+[Guid]::NewGuid().ToString('N')));CurrentHash=('f'*64);CurrentMetadataHash=(Get-WsmAssistiveMetadataHash $driftMetadata);Backup='';BackupHash='';BackupMetadataHash=''};$driftOperation=[pscustomobject]@{ItemId=$itemId;Phase='RollbackAssistiveFiles';ManifestHash=('a'*64);Target=$driftRoot;Files=@($driftAction);Directories=@()}
        $rejected=$false;try{Complete-WsmAssistiveFileRollback $driftItem $driftOperation $paths $driftState}catch{$rejected=$true}
        Check $rejected 'Rollback accepted bytes that drifted from the exact owned generation.'
        Check ([IO.File]::ReadAllText($driftFile) -ceq 'operator drift' -and -not [IO.File]::Exists($driftAction.Retained)) 'Rejected rollback modified or displaced drifted target data.'
        Write-Host ('PASS: '+$script:rollbackChecks+' Assistive per-file rollback checks.')
    } $root
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
