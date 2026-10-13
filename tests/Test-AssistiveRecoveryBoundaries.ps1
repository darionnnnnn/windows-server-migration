#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-repair-boundary-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $checks=0
        foreach($scenario in @('TargetDirectory','StagingDirectory','BackupDirectory','PriorMetadataDrift','AbsentUnchanged','OwnedUnchanged')){
            $caseRoot=Join-Path $Root $scenario;[void][IO.Directory]::CreateDirectory($caseRoot)
            $scope=Join-Path $caseRoot 'scope';[void][IO.Directory]::CreateDirectory($scope)
            $itemId=('e'*64);$target=Join-Path $scope 'file.ini';$staging=$target+'.wsm-'+[Guid]::NewGuid().ToString('N')+'.tmp'
            $backup='';$previous='';$prior=$null;$owned=$scenario -in @('OwnedUnchanged','PriorMetadataDrift')
            if($owned){[IO.File]::WriteAllText($target,'previous reviewed bytes');$previous=(Get-FileHash -LiteralPath $target).Hash.ToLowerInvariant();$prior=[pscustomobject]@{MetadataHash=(Get-WsmAssistiveMetadataHash (Get-WsmFileMetadata $target 'DaclOwner'))}}
            if($scenario -eq 'TargetDirectory'){[void][IO.Directory]::CreateDirectory($target)}
            if($scenario -eq 'StagingDirectory'){[void][IO.Directory]::CreateDirectory($staging)}
            if($scenario -eq 'BackupDirectory'){$backup=$target+'.wsm-assistive-backup-'+$itemId.Substring(0,12)+'-'+[Guid]::NewGuid().ToString('N');[void][IO.Directory]::CreateDirectory($backup)}
            if($scenario -eq 'PriorMetadataDrift'){[IO.File]::SetLastWriteTimeUtc($target,[DateTime]::UtcNow.AddDays(-2))}
            $operation=[pscustomobject]@{ItemId=$itemId;Phase='AssistiveFileReplace';Target=$target;RelativePath='file.ini';Staging=$staging;Backup=$backup;PreviousHash=$previous;ExpectedHash=('a'*64);ExpectedMetadata=[pscustomobject]@{MetadataMode='DaclOwner'};WasOwned=$owned;PriorOwner=$prior}
            $item=[pscustomobject]@{ItemId=$itemId;MigrationSpec=[pscustomobject]@{Adapter='FileScope';TargetPath=$scope;AclControlPolicy='Exact'}}
            $package=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=[Guid]::NewGuid().ToString();BatchId=[Guid]::NewGuid().ToString();PlanHash=('b'*64);Target=[pscustomobject]@{Fingerprint=('c'*64)}}}
            $stateRoot=Join-Path $caseRoot 'state';$paths=Get-WsmOperationPaths $stateRoot $package.Manifest.PairId;$state=Get-WsmOperationState $paths $package;$state.PendingOperations=@($operation)
            $rejected=$false;try{Complete-WsmAssistiveOperationRepair $item $operation $package $paths $state|Out-Null}catch{$rejected=$true}
            if($scenario -in @('AbsentUnchanged','OwnedUnchanged')){
                if($rejected -or @($state.PendingOperations).Count -ne 0 -or -not [IO.File]::Exists($paths.Journal)){throw ('Proven unchanged intent did not produce durable abandonment: '+$scenario)}
                $journal=Test-WsmJournal $stateRoot $package.Manifest.PairId;if(-not $journal.Consistent){throw 'Abandonment journal and checkpoint disagree.'}
                $record=Read-WsmJson $paths.State;if(@($record.PendingOperations).Count){throw 'Pending intent was not removed in the actual checkpoint.'}
                if($owned -and (Get-FileHash -LiteralPath $target).Hash -ine $previous){throw 'Recovery altered the prior owned file.'}
            }else{
                if(-not $rejected -or @($state.PendingOperations).Count -ne 1 -or [IO.File]::Exists($paths.Journal)){throw ('Drifted or non-file transaction material was treated as absent: '+$scenario)}
                foreach($candidate in @($target,$staging,$backup)){if($candidate -and $scenario.EndsWith('Directory') -and $candidate -eq $(switch($scenario){TargetDirectory{$target} StagingDirectory{$staging} BackupDirectory{$backup}}) -and -not [IO.Directory]::Exists($candidate)){throw 'Recovery removed unexpected directory material.'}}
            }
            $checks++
        }
        Write-Output ('PASS: '+$checks+' actual local file/directory/metadata recovery boundaries and durable journal/checkpoint checks.')
    } $root
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-repair-boundary-*'){throw 'Unsafe owned test cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
