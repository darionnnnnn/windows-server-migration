function Get-WsmOperationPaths([string]$StateDirectory,[string]$PairId) {
    Assert-WsmId $PairId; $root=Join-Path ([IO.Path]::GetFullPath($StateDirectory)) $PairId;Assert-WsmNoReparse $root
    if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root}
    [pscustomobject]@{Root=$root;State=(Join-Path $root 'state.json');Journal=(Join-Path $root 'journal.jsonl');Evidence=(Join-Path $root 'evidence.json')}
}
function Get-WsmOperationState($Paths,$Package,[switch]$AllowRecovery) {
    if([IO.File]::Exists($Paths.State)){$s=Read-WsmJson $Paths.State;Assert-WsmEnvelope $s 'OperationState';if($s.PairId -cne $Package.Manifest.PairId -or $s.TargetFingerprint -cne $Package.Manifest.Target.Fingerprint -or $s.PlanHash -ine $Package.Manifest.PlanHash){throw 'Operation state is bound to another plan/target.'};if(-not $AllowRecovery){$check=Test-WsmJournal ([IO.Path]::GetDirectoryName($Paths.Root)) $s.PairId;if(-not $check.Consistent){throw 'Durable journal differs from checkpoint; run RepairOperation before any further changes.'}};$s}
    else{[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OperationState';BatchId=$Package.Manifest.BatchId;PairId=$Package.Manifest.PairId;TargetFingerprint=$Package.Manifest.Target.Fingerprint;PlanHash=$Package.Manifest.PlanHash;RunId=[Guid]::NewGuid().ToString();ManifestHash='';Generation=0;Stage='NotStarted';Sequence=0;ResultSequence=0;JournalHash=('0'*64);JournalSegment=0;Items=@();Evidence=@();Cutover=$null;PendingOperations=@()}}
}
function Add-WsmJournal($Paths,$State,[string]$Action,[string]$ItemId,$Detail) {
    $State.Sequence++;$row=[pscustomobject][ordered]@{Sequence=$State.Sequence;PreviousHash=$State.JournalHash;RunId=$State.RunId;PairId=$State.PairId;Utc=(Get-WsmUtc);Action=$Action;ItemId=$ItemId;Detail=$Detail}
    $text=$row | ConvertTo-Json -Depth 15 -Compress;if([Text.Encoding]::UTF8.GetByteCount($text) -gt 1MB){throw 'Journal event too large.'}
    $path=$Paths.Journal;if([IO.File]::Exists($path) -and (New-Object IO.FileInfo($path)).Length -gt 8MB){$archive=Join-Path $Paths.Root ('journal-'+$State.JournalSegment+'.jsonl');if([IO.File]::Exists($archive)){throw 'Journal archive collision.'};[IO.File]::Move($path,$archive);$State.JournalSegment++}
    $stream=[IO.File]::Open($path,'Append','Write','Read');try{$bytes=[Text.Encoding]::UTF8.GetBytes($text+[Environment]::NewLine);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    $State.JournalHash=Get-WsmHashText $text;Write-WsmJson $Paths.State $State
}
function Get-WsmFileScopeDigest([string]$Root,[string]$MetadataMode) {
    Get-WsmStreamingScopeDigest $Root $MetadataMode
}
function Get-WsmRestorePreview {
    param([string]$ManifestPath,[string]$ExpectedHash,[string]$StateDirectory,[hashtable]$Secrets=@{})
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $package.Manifest.Target.Fingerprint
    $paths=Get-WsmOperationPaths $StateDirectory $package.Manifest.PairId;$state=Get-WsmOperationState $paths $package
    if($package.Manifest.Generation -lt $state.Generation){throw 'Old payload generation refused.'}
    if($package.Manifest.Generation -gt 1 -and $state.ManifestHash -ine $ExpectedHash -and $state.ManifestHash -ine $package.Manifest.BaseManifestHash){throw 'Delta base does not match applied target generation.'}
    $problems=New-Object 'System.Collections.Generic.List[object]';$rows=New-Object 'System.Collections.Generic.List[object]';$backupBytes=[long]0
    foreach($i in $package.Plan.Items){if($i.Decision -ne 'Include'){continue};$spec=$i.MigrationSpec;$action='Create';$owned=@($state.Items | Where-Object ItemId -CEQ $i.ItemId);$reason='';$existing=$null
        try{
            if($owned.Count -and $owned[0].Status -eq 'RebootRequired'){Assert-WsmRebootCompleted $owned[0]}
            if($spec.Adapter -eq 'FileScope'){$target=ConvertTo-WsmCanonicalPath $spec.TargetPath;Assert-WsmNoReparse $target;if($target.StartsWith($paths.Root+'\',[StringComparison]::OrdinalIgnoreCase) -or $paths.Root.StartsWith($target.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Target overlaps operation workspace.'};$exists=[IO.File]::Exists($target) -or [IO.Directory]::Exists($target);if($exists){if(-not $owned.Count){throw 'Existing unowned scope conflict; choose a new target mapping.'};if($spec.ConflictPolicy -ne 'ReplaceOwned' -and $state.ManifestHash -ine $ExpectedHash){throw 'Scope policy prohibits replacing previous generation.'};$digest=Get-WsmFileScopeDigest $target $spec.Metadata;if($owned[0].Status -ne 'Succeeded' -or $owned[0].ActualHash -cne $digest){throw 'Owned target drift detected; preserve and reconcile before restore.'};$action='ReplaceOwned';if($state.ManifestHash -ieq $ExpectedHash){$action='VerifyAndSkip'};foreach($e in (Get-WsmScopeEntries ([pscustomobject]@{SourcePath=$target;ExcludedRelativePaths=@()}) $paths.Root)){if(-not $e.Directory){$backupBytes+=(New-Object IO.FileInfo($e.SourcePath)).Length}}}}
            elseif($spec.Adapter -eq 'ManualWorkflow'){$action='ManualProcedure';$reason=$spec.Procedure}
            else{foreach($command in (Get-WsmAdapterRequiredCommands $spec.Adapter)){if(-not (Get-Command $command -ErrorAction SilentlyContinue)){throw ('Missing target dependency: '+$command)}};$existing=Get-WsmAdapterState $spec;if($existing.Exists){if($spec.Adapter -eq 'WindowsFeature'){$action='VerifyExisting'}else{if(-not $owned.Count -or $owned[0].CreatedByTool -ne $true){throw 'Existing object conflict; automatic overwrite prohibited.'};$check=Test-WsmAdapterConfiguration $spec;if(-not $check.Passed){throw ('Owned target configuration drift: '+($check.Problems -join '; '))};$action='VerifyAndSkip'}}elseif($spec.PSObject.Properties['SecretRef'] -and $spec.SecretRef){[void](Get-WsmSecret $spec $Secrets)}}
        }catch{$action='Blocked';$reason=$_.Exception.Message;$problems.Add([pscustomobject]@{ItemId=$i.ItemId;Reason=$reason})}
        $rows.Add([pscustomobject]@{ItemId=$i.ItemId;Name=$i.Name;Adapter=$spec.Adapter;Action=$action;Reason=$reason;Rollback=($(if($spec.Adapter -eq 'WindowsFeature'){'Dedicated rollback required'}else{'RemoveCreatedOrRestoreBackup'}));RebootPossible=($spec.Adapter -eq 'WindowsFeature')})
    }
    # New bytes + retained old content + journal/index margin. Existing bytes already consume space;
    # they are renamed for rollback, not recopied. The staging copy requires the new bytes again.
    $needed=$package.Manifest.Bytes+[Math]::Max(256MB,[long]($package.Manifest.Bytes*0.1));$available=Get-WsmAvailableBytes $StateDirectory
    $volumes=@{};foreach($i in $package.Plan.Items){if($i.Decision -eq 'Include' -and $i.MigrationSpec.Adapter -eq 'FileScope'){$root=[IO.Path]::GetPathRoot($i.MigrationSpec.TargetPath);if(-not $volumes.ContainsKey($root)){$volumes[$root]=[long]0};foreach($record in (Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash)){if($record.ItemId -ceq $i.ItemId -and -not $record.Directory){$volumes[$root]+=$record.Data.Bytes}}}}
    foreach($root in $volumes.Keys){if((Get-WsmAvailableBytes $root) -lt $volumes[$root]+256MB){$problems.Add([pscustomobject]@{ItemId='';Reason=('Target volume lacks staging capacity: '+$root)})}}
    [pscustomobject]@{PairId=$package.Manifest.PairId;ManifestHash=$ExpectedHash;Generation=$package.Manifest.Generation;Mode='IsolatedPilot';Rows=$rows.ToArray();Problems=$problems.ToArray();Blocked=($problems.Count -gt 0);BackupBytes=$backupBytes;NewBytes=$package.Manifest.Bytes;StagingFreeBytesNeeded=$needed;StateVolumeFreeBytes=$available;BusinessValidationRequired=$true;ProductionVerified=$false}
}
function Invoke-WsmFileScopeRestore($Item,$Package,$Paths,$State,[hashtable]$SidMap) {
    $SidMap=Resolve-WsmIdentityMap $Package.Plan $SidMap
    $spec=$Item.MigrationSpec;$target=ConvertTo-WsmCanonicalPath $spec.TargetPath;$parent=[IO.Path]::GetDirectoryName($target);if(-not $parent -or [IO.Path]::GetPathRoot($target) -ieq $target){throw 'Volume root cannot be an atomic file scope destination.'};Assert-WsmNoReparse $parent;[void][IO.Directory]::CreateDirectory($parent)
    $staging=Join-Path $parent ('.wsm-stage-'+$Item.ItemId.Substring(0,12)+'-'+[Guid]::NewGuid().ToString('N'));$backup=Join-Path $parent ('.wsm-backup-'+$Item.ItemId.Substring(0,12)+'-'+[Guid]::NewGuid().ToString('N'))
    $index=Join-Path $Package.Root 'artifacts.jsonl';$root=@(Read-WsmArtifactLines $index $Package.Manifest.ArtifactsHash | Where-Object { $_.ItemId -ceq $Item.ItemId -and $_.RelativePath -ceq '' });if($root.Count -ne 1){throw 'File scope requires one root artifact.'}
    $prior=@($State.Items | Where-Object ItemId -CEQ $Item.ItemId);$previousRecord=$null;if($prior.Count){$previousRecord=$prior[0]}
    $pending=[pscustomobject]@{ItemId=$Item.ItemId;Target=$target;Staging=$staging;Backup=$backup;ManifestHash=$Package.SHA256;ExpectedHash='';PreviousHash=(Get-WsmFileScopeDigest $target $spec.Metadata);PreviousRecord=$previousRecord;Phase='Building'}
    $State.PendingOperations=@($State.PendingOperations | Where-Object ItemId -CNE $Item.ItemId)+@($pending)
    Add-WsmJournal $Paths $State 'FileScopeIntent' $Item.ItemId $pending
    if($root[0].Directory){[void][IO.Directory]::CreateDirectory($staging)}
    $maxDepth=0
    Read-WsmArtifactLines $index $Package.Manifest.ArtifactsHash | ForEach-Object { $row=$_;if($row.ItemId -ceq $Item.ItemId){$dest=$staging;if($row.RelativePath){$dest=Join-Path $staging $row.RelativePath};if($dest.Length -gt 239){throw 'Target staging path exceeds verified long-path limit.'};if($row.Directory){[void][IO.Directory]::CreateDirectory($dest);$depth=0;if($row.RelativePath){$depth=$row.RelativePath.Split([char]92).Length};$maxDepth=[Math]::Max($maxDepth,$depth)}else{Restore-WsmPayloadBytes $row $Package.Root $dest;Set-WsmFileMetadata $dest $row.Metadata $SidMap}} }
    # Apply children before restrictive parent ACLs, and preserve directory timestamps last.
    for($level=$maxDepth;$level -ge 0;$level--){Read-WsmArtifactLines $index $Package.Manifest.ArtifactsHash | ForEach-Object {$row=$_;if($row.ItemId -ceq $Item.ItemId -and $row.Directory){$depth=0;if($row.RelativePath){$depth=$row.RelativePath.Split([char]92).Length};if($depth -eq $level){$dest=$staging;if($row.RelativePath){$dest=Join-Path $staging $row.RelativePath};Set-WsmFileMetadata $dest $row.Metadata $SidMap}}}}
    $verification=Test-WsmFileScope $Item $Package $staging $SidMap;if(-not $verification.Passed){throw 'Staged file/ACL verification failed.'}
    $pending.ExpectedHash=$verification.ActualHash;$pending.Phase='Prepared'
    Add-WsmJournal $Paths $State 'FileScopePrepared' $Item.ItemId $pending
    # Rename only the explicitly approved root and generated siblings with checked common parent.
    foreach($path in @($target,$staging,$backup)){if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -ine $parent){throw 'Atomic scope path escapes approved parent.'};Assert-WsmNoReparse $path}
    if((Get-WsmFileScopeDigest $target $spec.Metadata) -cne $pending.PreviousHash){throw 'Target changed while staging; preserve both roots and reconcile before retry.'}
    if([IO.Directory]::Exists($target)){[IO.Directory]::Move($target,$backup)}elseif([IO.File]::Exists($target)){[IO.File]::Move($target,$backup)}
    try{if($root[0].Directory){[IO.Directory]::Move($staging,$target)}else{[IO.File]::Move($staging,$target)}}catch{if([IO.Directory]::Exists($backup)){[IO.Directory]::Move($backup,$target)}elseif([IO.File]::Exists($backup)){[IO.File]::Move($backup,$target)};throw}
    [pscustomobject]@{ActualHash=(Get-WsmFileScopeDigest $target $spec.Metadata);Backup=$backup;Target=$target;CreatedByTool=$true}
}
function Test-WsmFileScope($Item,$Package,[string]$Target,[hashtable]$SidMap=@{}) {
    $SidMap=Resolve-WsmIdentityMap $Package.Plan $SidMap
    $problems=New-Object 'System.Collections.Generic.List[string]';$expectedCount=[long]0;$problemCount=[long]0
    Read-WsmArtifactLines (Join-Path $Package.Root 'artifacts.jsonl') $Package.Manifest.ArtifactsHash | ForEach-Object {
        $row=$_;if($row.ItemId -ceq $Item.ItemId){$expectedCount++;$path=$Target;if($row.RelativePath){$path=Join-Path $Target $row.RelativePath};$reason=''
            if($row.Directory -ne [IO.Directory]::Exists($path) -or (-not $row.Directory -and -not [IO.File]::Exists($path))){$reason='Absent/type mismatch'}
            else{try{Assert-WsmNoReparse $path;if(-not $row.Directory -and ((New-Object IO.FileInfo($path)).Length -ne $row.Data.Bytes -or (Get-FileHash -LiteralPath $path).Hash -ine $row.Data.Hash)){$reason='Content mismatch'};$meta=Get-WsmFileMetadata $path $row.Metadata.MetadataMode;if($meta.Sddl -cne (Convert-WsmMappedSddl $row.Metadata.Sddl $SidMap) -or $meta.Attributes -ne $row.Metadata.Attributes){$reason='ACL/metadata mismatch'}}catch{$reason='Unreadable/special artifact'}}
            if($reason){$problemCount++;if($problems.Count -lt 100){$problems.Add($reason+': '+$row.RelativePath)}}
        }
    }
    if([IO.Directory]::Exists($Target) -or [IO.File]::Exists($Target)){$actualCount=[long]0;Get-WsmScopeEntries ([pscustomobject]@{SourcePath=$Target;ExcludedRelativePaths=@()}) $Package.Root | ForEach-Object {$actualCount++};if($actualCount -ne $expectedCount){$problemCount++;$problems.Add('Unexpected target entry count.')}}
    $digest='';if(-not $problemCount){$digest=Get-WsmFileScopeDigest $Target $Item.MigrationSpec.Metadata};[pscustomobject]@{Passed=($problemCount -eq 0);Problems=$problems.ToArray();ProblemCount=$problemCount;ProblemsTruncated=($problemCount -gt $problems.Count);ActualHash=$digest}
}
function Invoke-WsmRestore {
    [CmdletBinding(SupportsShouldProcess)]param([string]$ManifestPath,[string]$ExpectedHash,[string]$StateDirectory,[hashtable]$Secrets=@{},[hashtable]$SidMap=@{})
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash;Assert-WsmMigrationHost (Get-WsmMachineIdentity) $package.Manifest.Target.Fingerprint;$paths=Get-WsmOperationPaths $StateDirectory $package.Manifest.PairId
    Invoke-WsmLocked $paths.Root {
        $state=Get-WsmOperationState $paths $package;$preview=Get-WsmRestorePreview $ManifestPath $ExpectedHash $StateDirectory $Secrets;if($preview.Blocked){throw ('Restore blocked: '+(@($preview.Problems.Reason) -join '; '))};if(-not $PSCmdlet.ShouldProcess($package.Manifest.PairId,('Restore isolated pilot generation '+$package.Manifest.Generation))){return $preview}
        if($state.Cutover){throw 'Restore after cutover requires reviewed data reconciliation; no automatic reverse synchronization.'}
        if($state.PendingOperations.Count){throw 'Interrupted scope operation needs Repair-WsmOperation before retry.'}
        $state.Stage='Running';Add-WsmJournal $paths $state 'RestoreStarted' '' ([pscustomobject]@{ManifestHash=$ExpectedHash;Generation=$package.Manifest.Generation;PreviousManifest=$state.ManifestHash})
        $included=@($package.Plan.Items | Where-Object Decision -EQ Include);$ordered=Get-WsmRestoreOrder $included
        foreach($item in $ordered){$spec=$item.MigrationSpec;$record=@($state.Items | Where-Object ItemId -CEQ $item.ItemId);$action=($preview.Rows | Where-Object ItemId -CEQ $item.ItemId).Action
            if($spec.Adapter -eq 'ManualWorkflow'){$result=[pscustomobject]@{ItemId=$item.ItemId;Status='ManualEvidenceRequired';CreatedByTool=$false;ActualHash='';Backup='';Target='';Error='Dedicated product procedure and business evidence required';NativeCode=$null}}
            else{try{Add-WsmJournal $paths $state 'ItemStarted' $item.ItemId ([pscustomobject]@{Adapter=$spec.Adapter;Action=$action});$actual='';$backup='';$target='';$reboot=$false;$bootBefore=''
                if($action -in @('VerifyAndSkip','VerifyExisting')){if($spec.Adapter -eq 'FileScope'){$check=Test-WsmFileScope $item $package $spec.TargetPath $SidMap;$actual=$check.ActualHash}else{$check=Test-WsmAdapterConfiguration $spec;$actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 15 -Compress)};if(-not $check.Passed){throw 'Existing owned object verification failed.'};if($record.Count){$backup=$record[0].Backup;$target=$record[0].Target}}
                elseif($spec.Adapter -eq 'FileScope'){$r=Invoke-WsmFileScopeRestore $item $package $paths $state $SidMap;$actual=$r.ActualHash;$backup=$r.Backup;$target=$r.Target}
                else{$before=Get-WsmAdapterState $spec;if($before.Exists){throw 'Target object appeared after preview; do not overwrite.'};$pending=[pscustomobject]@{ItemId=$item.ItemId;Phase='AdapterCreating';Adapter=$spec.Adapter;ManifestHash=$ExpectedHash;AbsentBefore=$true;BeforeHash=(Get-WsmHashText ($before | ConvertTo-Json -Compress -Depth 15))};$state.PendingOperations=@($state.PendingOperations | Where-Object ItemId -CNE $item.ItemId)+@($pending);Add-WsmJournal $paths $state 'AdapterIntent' $item.ItemId $pending;Write-WsmJson (Join-Path $paths.Root ($item.ItemId+'.before.json')) $before;if($spec.Adapter -eq 'WindowsFeature'){$bootBefore=Get-WsmBootStamp};$r=Invoke-WsmAdapterRestore $spec $Secrets $package;$reboot=$r.RebootRequired;$check=Test-WsmAdapterConfiguration $spec;if(-not $check.Passed){throw ($check.Problems -join '; ')};$actual=Get-WsmHashText ($check.Actual | ConvertTo-Json -Depth 15 -Compress)}
                $status='Succeeded';if($reboot){$status='RebootRequired'};$result=[pscustomobject]@{ItemId=$item.ItemId;Status=$status;CreatedByTool=($action -ne 'VerifyExisting');ActualHash=$actual;Backup=$backup;Target=$target;Error='';NativeCode=0;BootBefore=$bootBefore}
            }catch{$result=[pscustomobject]@{ItemId=$item.ItemId;Status='Failed';CreatedByTool=(($record.Count -and $record[0].CreatedByTool) -or @($state.PendingOperations | Where-Object ItemId -CEQ $item.ItemId).Count -gt 0);ActualHash='';Backup='';Target='';Error=$_.Exception.GetType().FullName;NativeCode=$null};$state.Items=@($state.Items | Where-Object ItemId -CNE $item.ItemId)+@($result);$state.Stage='Failed';Add-WsmJournal $paths $state 'ItemFailed' $item.ItemId $result;throw}}
            $state.Items=@($state.Items | Where-Object ItemId -CNE $item.ItemId)+@($result);$state.PendingOperations=@($state.PendingOperations | Where-Object ItemId -CNE $item.ItemId);Add-WsmJournal $paths $state 'ItemCompleted' $item.ItemId $result
        }
        $state.ManifestHash=$ExpectedHash;$state.Generation=$package.Manifest.Generation;$state.Stage='Succeeded';if(@($state.Items | Where-Object Status -NE Succeeded).Count){$state.Stage='ManualEvidenceRequired'};if(@($state.Items | Where-Object Status -EQ RebootRequired).Count){$state.Stage='RebootRequired'};Add-WsmJournal $paths $state 'RestoreCompleted' '' ([pscustomobject]@{Status=$state.Stage;Generation=$state.Generation;ManifestHash=$ExpectedHash});$state
    }
}
function Get-WsmRestoreOrder([object[]]$Items) {
    $remaining=@{};foreach($i in $Items){$remaining[$i.ItemId]=$i};$done=@{}
    while($remaining.Count){$ready=@($remaining.Values | Where-Object {$blocked=$false;foreach($d in $_.Dependencies){if($d.Type -eq 'Mandatory' -and $remaining.ContainsKey($d.ItemId)){$blocked=$true}};-not $blocked} | Sort-Object @{e={switch($_.MigrationSpec.Adapter){LocalUser{0};LocalGroup{1};WindowsFeature{2};FileScope{3};Certificate{4};IISPool{5};default{6}}}},ItemId)
        if(-not $ready.Count){$groups=@($remaining.Values | ForEach-Object ConsistencyGroup | Select-Object -Unique);if($groups.Count -ne 1 -or -not $groups[0]){throw 'Unresolved dependency cycle.'};$ready=@($remaining.Values | Sort-Object ItemId);foreach($i in $ready){if(-not $i.ConsistencyOwner -or -not $i.ConsistencyEvidence){throw 'Cycle lacks consistency owner/procedure.'}}}
        foreach($i in $ready){$i;$remaining.Remove($i.ItemId)}
    }
}

function Get-WsmBootStamp {$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop;([DateTime]$os.LastBootUpTime).ToUniversalTime().ToString('o')}
function Assert-WsmRebootCompleted($Record){if(-not $Record.PSObject.Properties['BootBefore'] -or -not $Record.BootBefore -or (Get-WsmBootStamp) -ceq $Record.BootBefore){throw 'Installer required reboot has not been verified; restart under reviewed maintenance procedure, then retry staging.'}}
