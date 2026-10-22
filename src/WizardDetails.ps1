function Get-WsmWizardFileDetails($Item) {
    # Projection only: never touch a source filesystem during GET/polling.
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $seen=@{}
    function Add-Detail([string]$Path,[string]$Status,[string]$Hash,[string]$Reason) {
        if(-not $Path -or $seen.ContainsKey($Path.ToLowerInvariant())){return}
        $seen[$Path.ToLowerInvariant()]=$true
        $rows.Add([pscustomobject][ordered]@{path=$Path;status=$Status;sha256=$Hash;reason=$Reason;contentRead=$false})
    }
    if($Item.PSObject.Properties['Settings'] -and $Item.Settings){
        $settings=$Item.Settings
        if($settings.PSObject.Properties['Path']){
            $hash='';if($settings.PSObject.Properties['SHA256']){$hash=[string]$settings.SHA256}
            $status=if($hash -match '^[a-fA-F0-9]{64}$'){'CapturedEvidence'}else{'ObservedPath'}
            Add-Detail ([string]$settings.Path) $status $hash 'Location recorded by the inventory collector; this projection does not read the file.'
        }
        if($settings.PSObject.Properties['ConfigurationFile']){Add-Detail ([string]$settings.ConfigurationFile) 'ConfigurationEvidence' '' 'Configuration location recorded by the collector; this does not imply the whole file will be restored.'}
        if($settings.PSObject.Properties['ResolvedCandidate'] -and $settings.ResolvedCandidate){Add-Detail ([string]$settings.ResolvedCandidate) 'ScopeNotEnumerated' '' 'Candidate location only; descendants have not been enumerated or approved.'}
    }
    if($Item.PSObject.Properties['MigrationSpec'] -and $Item.MigrationSpec -and $Item.MigrationSpec.Adapter -ceq 'FileScope'){
        $spec=$Item.MigrationSpec
        if($spec.PSObject.Properties['ConfigFiles']){foreach($file in @($spec.ConfigFiles)){
            $path=[string]$file.RelativePath;$hash='';if($file.PSObject.Properties['SHA256']){$hash=[string]$file.SHA256}
            Add-Detail $path 'ReviewedExactFile' $hash 'Exact file recorded in the reviewed migration specification; live content is revalidated by export.'
        }}
        if($spec.PSObject.Properties['ContentSelection'] -and [string]$spec.ContentSelection -ceq 'ExactMembers' -and $spec.PSObject.Properties['Members']){foreach($member in @($spec.Members)){if($member.PSObject.Properties['EntryType'] -and [string]$member.EntryType -ceq 'Directory'){Add-Detail ([string]$member.RelativePath) 'ReviewedExactDirectory' '' 'Reviewed empty directory member; it is recreated at its original location, contents added later are not included.'}else{Add-Detail ([string]$member.RelativePath) 'ReviewedExactMember' ([string]$member.SHA256) 'Hash-bound file member only; sibling files and directory contents are not included.'}}}
        if(-not $rows.Count){Add-Detail ([string]$spec.SourcePath) 'ScopeNotEnumerated' '' 'Reviewed source scope; a bounded file listing is a separate read-only operation.'}
    }
    $rows.ToArray()
}

function Assert-WsmWizardDetailLocalPath([string]$Path) {
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '^(?:\\\\|\\\?\\|\\\.\\)' -or $Path.Substring(2).Contains(':')){throw 'File details require an absolute local drive path.'}
    $full=[IO.Path]::GetFullPath($Path)
    foreach($segment in @($full.Substring(3).Replace('/','\').Split('\'))){
        if($segment.TrimEnd(' ','.') -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)'){throw 'File details do not use reserved Windows device names.'}
    }
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
    if($drive.DriveType -ne [IO.DriveType]::Fixed){throw 'File details do not follow network or removable drives.'}
    # Check from the drive down, before any child lookup can follow a junction.
    $cursor=[IO.Path]::GetPathRoot($full)
    foreach($part in @('')+@($full.Substring($cursor.Length).Split('\')|Where-Object {$_})){
        if($part){$cursor=Join-Path $cursor $part}
        try{$attributes=[IO.File]::GetAttributes($cursor)}catch [IO.FileNotFoundException]{break}catch [IO.DirectoryNotFoundException]{break}
        if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'File details do not follow reparse ancestors.'}
    }
    $full
}

function Export-WsmWizardFileDetails {
    [CmdletBinding()]param([Parameter(Mandatory)]$Item,[Parameter(Mandatory)][string]$OutputDirectory,[string[]]$ExcludedRoot=@(),[ValidateRange(1,10000)][int]$MaxEntries=1000,[ValidateRange(1,120)][int]$TimeoutSeconds=15,$CancellationToken=$null)
    if(-not $Item.PSObject.Properties['MigrationSpec'] -or -not $Item.MigrationSpec -or $Item.MigrationSpec.Adapter -cne 'FileScope'){throw 'Choose a reviewed file scope before listing its contents.'}
    $spec=$Item.MigrationSpec;$source=Assert-WsmWizardDetailLocalPath ([string]$spec.SourcePath)
    $output=Assert-WsmWizardDetailLocalPath $OutputDirectory
    $forbidden=@($output)+@($ExcludedRoot|ForEach-Object {Assert-WsmWizardDetailLocalPath $_})
    foreach($other in $forbidden){if(Test-WsmPathOverlap (Get-WsmPhysicalPath $source) (Get-WsmPhysicalPath $other)){throw 'File detail source overlaps a controlled tool or output directory.'}}
    if(-not [IO.File]::Exists($source) -and -not [IO.Directory]::Exists($source)){throw 'File detail source is unavailable.'}
    $rows=New-Object 'System.Collections.Generic.List[object]';$gaps=New-Object 'System.Collections.Generic.List[object]'
    $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($source)
    $watch=[Diagnostics.Stopwatch]::StartNew();$status='Complete'
    while($stack.Count){
        Assert-WsmCancellationBoundary $CancellationToken 'WizardFileDetailListing'
        if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds -or $rows.Count -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=$stack.Count});break}
        $path=$stack.Pop();$relative=$path.Substring($source.Length).TrimStart('\');$excluded=$false
        foreach($entry in @($spec.ExcludedRelativePaths)){if($relative -ieq $entry -or $relative.StartsWith(([string]$entry).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$excluded=$true;break}}
        if($excluded){continue}
        if($spec.PSObject.Properties['ContentSelection'] -and [string]$spec.ContentSelection -ceq 'ExactMembers'){
            if($relative){continue}
            if(-not $spec.PSObject.Properties['Members'] -or @($spec.Members).Count -eq 0){throw 'ExactMembers file details require the nonempty sealed member allowlist.'}
            $attempts=0
            foreach($member in @($spec.Members)){
                Assert-WsmCancellationBoundary $CancellationToken 'WizardExactMemberDetail'
                if($attempts -ge $MaxEntries -or $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$attempts++
                $memberRelative=[string]$member.RelativePath;Assert-WsmRelativePath $memberRelative;$exact=Join-Path $source $memberRelative
                try{[void](Assert-WsmWizardDetailLocalPath $exact);if($member.PSObject.Properties['EntryType'] -and [string]$member.EntryType -ceq 'Directory'){$dirInfo=New-Object IO.DirectoryInfo($exact);if(-not $dirInfo.Exists){throw 'Exact directory member is unavailable.'};if($rows.Count -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$rows.Add([pscustomobject]@{path=$memberRelative;directory=$true;bytes=[long]0;lastWriteUtc=$dirInfo.LastWriteTimeUtc.ToString('o');status='ObservedMetadata';approvedSha256='';contentRead=$false});continue};$info=New-Object IO.FileInfo($exact);if(-not $info.Exists){throw 'Exact member is unavailable.'};if($rows.Count -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$rows.Add([pscustomobject]@{path=$memberRelative;directory=$false;bytes=[long]$info.Length;lastWriteUtc=$info.LastWriteTimeUtc.ToString('o');status='ObservedMetadata';approvedSha256=[string]$member.SHA256;contentRead=$false})}catch{$status='Partial';$gaps.Add([pscustomobject]@{path=$memberRelative;reason='UnavailableOrUnsafe';errorType=$_.Exception.GetType().FullName})}
            }
            break
        }
        if($spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactFiles'){
            if($relative){continue}
            $attempts=0
            foreach($file in @($spec.ConfigFiles)){
                Assert-WsmCancellationBoundary $CancellationToken 'WizardExactFileDetail'
                if($attempts -ge $MaxEntries -or $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$attempts++
                Assert-WsmRelativePath ([string]$file.RelativePath) -AllowRoot
                $exact=if($file.RelativePath){Join-Path $source ([string]$file.RelativePath)}else{$source}
                try{[void](Assert-WsmWizardDetailLocalPath $exact);$info=New-Object IO.FileInfo($exact);if(-not $info.Exists){throw 'Exact file is unavailable.'};if($rows.Count -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{reason='ListingBudgetExceeded';pendingEntries=1});break};$rows.Add([pscustomobject]@{path=[string]$file.RelativePath;directory=$false;bytes=[long]$info.Length;lastWriteUtc=$info.LastWriteTimeUtc.ToString('o');status='ObservedMetadata';contentRead=$false})}catch{$status='Partial';$gaps.Add([pscustomobject]@{path=[string]$file.RelativePath;reason='UnavailableOrUnsafe';errorType=$_.Exception.GetType().FullName})}
            }
            break
        }
        try{
            [void](Assert-WsmWizardDetailLocalPath $path);$attributes=[IO.File]::GetAttributes($path);$directory=($attributes -band [IO.FileAttributes]::Directory) -ne 0
            $info=if($directory){New-Object IO.DirectoryInfo($path)}else{New-Object IO.FileInfo($path)}
            $rows.Add([pscustomobject]@{path=$relative;directory=$directory;bytes=$(if($directory){$null}else{[long]$info.Length});lastWriteUtc=$info.LastWriteTimeUtc.ToString('o');status='ObservedMetadata';contentRead=$false})
            if($directory){
                $iterator=[IO.Directory]::EnumerateFileSystemEntries($path).GetEnumerator()
                try{while($iterator.MoveNext()){
                    Assert-WsmCancellationBoundary $CancellationToken 'WizardFileDetailChild'
                    if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds -or ($stack.Count+$rows.Count) -ge $MaxEntries){$status='Partial';$gaps.Add([pscustomobject]@{path=$relative;reason='ListingBudgetExceeded';pendingEntries=1});break}
                    $stack.Push([string]$iterator.Current)
                }}finally{if($iterator -is [IDisposable]){$iterator.Dispose()}}
            }
        }catch{if($_.Exception -is [OperationCanceledException]){throw};$status='Partial';$gaps.Add([pscustomobject]@{path=$relative;reason='UnavailableOrUnsafe';errorType=$_.Exception.GetType().FullName})}
    }
    [void](Assert-WsmWizardDetailLocalPath $output)
    if(-not [IO.Directory]::Exists($output)){[void][IO.Directory]::CreateDirectory($output);Protect-WsmDirectory $output}
    $record=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WizardFileDetails';ItemId=[string]$Item.ItemId;SourcePath=$source;SpecHash=(Get-WsmHashText ($spec|ConvertTo-Json -Depth 30 -Compress));Status=$status;CapturedUtc=(Get-WsmUtc);ContentRead=$false;BackupVerified=$false;Entries=@($rows.ToArray());Gaps=@($gaps.ToArray())}
    $path=Join-Path $output ('file-details-'+[Guid]::NewGuid().ToString('N')+'.json');Write-WsmJson $path $record
    [pscustomobject]@{Status=$status;ItemId=[string]$Item.ItemId;SpecHash=$record.SpecHash;Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();EntryCount=$rows.Count;GapCount=$gaps.Count;ContentRead=$false;BackupVerified=$false}
}

function Read-WsmWizardFileDetails([string]$Path,[string]$ExpectedHash,[string]$OwnedRoot,$Item) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'File details require the recorded SHA256.'}
    $root=(Assert-WsmWizardDetailLocalPath $OwnedRoot).TrimEnd('\')+'\';$full=Assert-WsmWizardDetailLocalPath $Path
    if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'File details are outside their controlled directory.'}
    $info=New-Object IO.FileInfo($full);if(-not $info.Exists -or $info.Length -gt 8MB){throw 'File detail record is missing or exceeds its read budget.'}
    if((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'File detail record changed.'}
    $record=Read-WsmJson $full;Assert-WsmEnvelope $record 'WizardFileDetails'
    if($record.SchemaVersion -ne 1 -or $record.ItemId -cne [string]$Item.ItemId -or $record.SpecHash -ine (Get-WsmHashText ($Item.MigrationSpec|ConvertTo-Json -Depth 30 -Compress)) -or $record.SourcePath -ine [IO.Path]::GetFullPath([string]$Item.MigrationSpec.SourcePath) -or $record.ContentRead -or $record.BackupVerified -or $record.Status -notin @('Complete','Partial') -or @($record.Entries).Count -gt 10000){throw 'File details do not match the current reviewed scope.'}
    $record
}
