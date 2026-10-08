#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-task-journal-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        foreach($mode in @('Create','Delete')){
            foreach($case in @('Valid','Path','Hash','Kind','Manifest','Item','Descriptor')){
                $stateDirectory=Join-Path $Root ($mode+'-'+$case);$pair=[Guid]::NewGuid().ToString();$itemId='a'*64;$manifestHash='b'*64
                $package=[pscustomobject]@{Manifest=[pscustomobject]@{BatchId=[Guid]::NewGuid().ToString();PairId=$pair;Target=[pscustomobject]@{Fingerprint='c'*64};PlanHash='d'*64}}
                $paths=Get-WsmOperationPaths $stateDirectory $pair;$state=Get-WsmOperationState $paths $package
                $sddl=ConvertTo-WsmTaskSecuritySddl 'O:SYG:SYD:(A;;FA;;;SY)';$securityHash=Get-WsmHashText $sddl;$operationId=[Guid]::NewGuid().ToString()
                $receipt=[pscustomobject][ordered]@{Kind='OwnedTaskFolder';OperationId=$operationId;Path='\Owned\';SecurityHash=$securityHash;CreatedUtc=(Get-WsmUtc)}
                $intent=[pscustomobject][ordered]@{Kind='TaskFolderCreateIntent';OperationId=$operationId;Path='\Owned\';SecurityHash=$securityHash;SecuritySddl=$sddl;CreatedUtc=(Get-WsmUtc)}
                $pending=[pscustomobject]@{ItemId=$itemId;Adapter='ScheduledTask';ManifestHash=$manifestHash;Phase='AdapterCreating';FolderCreateIntents=@();AuxiliaryOwnership=@()}
                if($mode -ceq 'Delete'){
                    $pending.Phase='RollbackAdapter';$state.Items=@([pscustomobject]@{ItemId=$itemId;Status='Succeeded';AuxiliaryOwnership=@($receipt)})
                    $intent=[pscustomobject][ordered]@{Kind='TaskFolderDeleteIntent';OperationId=$operationId;Path='\Owned\';SecurityHash=$securityHash;Receipt=$receipt;CreatedUtc=(Get-WsmUtc)}
                }
                $state.PendingOperations=@($pending);$action='AdapterIntent';if($mode -ceq 'Delete'){$action='RollbackIntent'}
                Add-WsmJournal $paths $state $action $itemId $pending
                $stale=[IO.File]::ReadAllText($paths.State)
                $intentAction='TaskFolder'+$mode+'Intent'
                $detail=[pscustomobject]@{ItemId=$itemId;Adapter='ScheduledTask';ManifestHash=$manifestHash;Phase=$intentAction;Intent=$intent}
                Add-WsmJournal $paths $state $intentAction $itemId $detail
                $completion=ConvertFrom-WsmJson ($receipt | ConvertTo-Json -Depth 10 -Compress)
                if($mode -ceq 'Delete'){$completion=ConvertFrom-WsmJson ($intent | ConvertTo-Json -Depth 10 -Compress)}
                switch($case){
                    Path {$completion.Path='\Different\'}
                    Hash {$completion.SecurityHash='e'*64}
                    Kind {$completion.Kind='UnexpectedKind'}
                    Descriptor {if($mode -ceq 'Create'){$completion.SecurityHash='f'*64}else{$completion.Receipt.SecurityHash='f'*64}}
                }
                $completeAction='TaskFolderOwned';$completeDetail=[pscustomobject]@{ItemId=$itemId;Adapter='ScheduledTask';ManifestHash=$manifestHash;Phase=$completeAction;Receipt=$completion}
                if($mode -ceq 'Delete'){$completeAction='TaskFolderDeleted';$completeDetail=[pscustomobject]@{ItemId=$itemId;Adapter='ScheduledTask';ManifestHash=$manifestHash;Phase=$completeAction;Intent=$completion}}
                if($case -ceq 'Manifest'){$completeDetail.ManifestHash='0'*64};if($case -ceq 'Item'){$completeDetail.ItemId='1'*64}
                Add-WsmJournal $paths $state $completeAction $itemId $completeDetail
                # Genuine hash-chain events survive, while only the earlier valid
                # checkpoint is restored, reproducing a crash before checkpoint flush.
                [IO.File]::WriteAllText($paths.State,$stale,(New-Object Text.UTF8Encoding($false)))
                $oldHash=(Get-FileHash -LiteralPath $paths.State).Hash;$loaded=Read-WsmJson $paths.State;$blocked=$false
                try{Restore-WsmJournalCheckpoint $paths $loaded}catch{$blocked=$true}
                if($case -ceq 'Valid'){
                    if($blocked -or -not (Test-WsmJournal $stateDirectory $pair).Consistent){throw ('Valid '+$mode+' intent/receipt could not replay.')}
                    $restored=Read-WsmJson $paths.State;$op=$restored.PendingOperations[0]
                    if($mode -ceq 'Create' -and (@($op.AuxiliaryOwnership).Count -ne 1 -or @($op.FolderCreateIntents).Count)){throw 'Creation replay lost exact ownership or retained completed intent.'}
                    if($mode -ceq 'Delete' -and (@($op.DeletedTaskFolders).Count -ne 1 -or @($op.FolderDeleteIntents).Count)){throw 'Deletion replay lost exact completion or retained completed intent.'}
                } elseif(-not $blocked -or (Get-FileHash -LiteralPath $paths.State).Hash -cne $oldHash){throw ('Mismatched '+$mode+'/'+$case+' replay changed checkpoint or was accepted.')}
            }
        }
        Write-Host 'PASS: genuine stale-checkpoint task-folder create/delete replay; exact operation/path/security/kind/item/manifest binding; mismatches retain original checkpoint.'
    } $root
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^wsm-task-journal-[a-f0-9]{32}$'){throw 'Unsafe task journal fixture cleanup root.'}
    if([IO.Directory]::Exists($resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
