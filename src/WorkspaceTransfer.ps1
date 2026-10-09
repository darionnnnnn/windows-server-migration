function Get-WsmWorkspaceTransferHash([string]$Path) {
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read')
    try{$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}finally{$stream.Dispose()}
}
function Get-WsmWorkspaceTransferFileHash([string]$Path,[long]$ExpectedBytes=-1) {
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read')
    try{
        if($ExpectedBytes -ge 0 -and $stream.Length -ne $ExpectedBytes){throw 'Workspace file changed while hashing.'}
        $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        [pscustomobject]@{Bytes=[long]$stream.Length;SHA256=$hash}
    }finally{$stream.Dispose()}
}
function Assert-WsmWorkspaceTransferRoot([string]$Path,[switch]$AllowMissing) {
    if([string]::IsNullOrWhiteSpace($Path)){throw 'A dedicated WorkRoot path is required.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full -eq [IO.Path]::GetPathRoot($full)){throw 'A volume root cannot be a WorkRoot.'}
    Assert-WsmNoReparse $full
    if([IO.File]::Exists($full)){throw 'WorkRoot path is occupied by a file.'}
    if(-not $AllowMissing -and -not [IO.Directory]::Exists($full)){throw 'WorkRoot directory does not exist.'}
    return $full.TrimEnd('\')
}
function Test-WsmWorkspaceTransferTransientFile([string]$Name) {
    return ($Name -ieq '.wsm.lock' -or $Name -like '*.import.lock' -or $Name -like '*.transfer.lock')
}
function Assert-WsmWorkspaceTransferNoExternalMutableState([string]$RelativePath) {
    $parts=@($RelativePath -split '\\')
    foreach($part in $parts){
        if($part -match '(?i)(^|[._-])(recovery|backup|cancel|cancellation|token)([._-]|$)' -or $part -match '(?i)\.partial$' -or $part -match '(?i)\.bak$'){
            throw ('Workspace contains external or mutable recovery material that cannot be rebound safely: '+$RelativePath)
        }
    }
}
function Read-WsmWorkspaceTransferProfile([string]$WorkRoot,[string]$ExpectedProfileWorkRoot=$WorkRoot) {
    $path=Join-Path $WorkRoot 'workspace-control\output-profile.json'
    if(-not [IO.File]::Exists($path)){throw 'Workspace transfer requires an enrolled OutputProfile.'}
    Assert-WsmNoReparse $path;$profile=Read-WsmJson $path;Assert-WsmEnvelope $profile 'OutputProfile'
    if($profile.ProfileVersion -ne 1 -or $profile.Role -cnotin @('Source','Manager','Target') -or $profile.Fingerprint -notmatch '^[a-f0-9]{64}$'){throw 'Invalid output profile identity or version.'}
    Assert-WsmId ([string]$profile.ProfileId);Assert-WsmId ([string]$profile.HostId);Assert-WsmOutputProfileValues $profile
    if([IO.Path]::GetFullPath($profile.WorkRoot) -ine [IO.Path]::GetFullPath($ExpectedProfileWorkRoot)){throw 'Output profile WorkRoot does not match its transfer root.'}
    return $profile
}
function Get-WsmWorkspaceTransferInventory([string]$WorkRoot,[switch]$AllowTransferMarker,[string]$ExpectedProfileWorkRoot=$WorkRoot) {
    $root=Assert-WsmWorkspaceTransferRoot $WorkRoot
    $profilePath=Join-Path $root 'workspace-control\output-profile.json'
    if(-not [IO.File]::Exists($profilePath)){throw 'Workspace transfer requires an enrolled OutputProfile.'}
    $profile=Read-WsmWorkspaceTransferProfile $root $ExpectedProfileWorkRoot
    if(-not $profile){throw 'Workspace transfer requires an enrolled OutputProfile.'}
    $markerPath=Join-Path $root 'workspace-control\workspace-transfer.json'
    if([IO.File]::Exists($markerPath) -and -not $AllowTransferMarker){throw 'Workspace is already transfer-marked; inspect its transfer record before continuing.'}
    $allowedForRole=@{Source=@('workspace-control','hosts');Manager=@('workspace-control','hosts','pairs','fleet.json');Target=@('workspace-control','hosts','pairs','targets')}
    foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($root)){$name=[IO.Path]::GetFileName($entryPath);$attributes=[IO.File]::GetAttributes($entryPath);$isDirectory=($attributes -band [IO.FileAttributes]::Directory) -ne 0;if(Test-WsmWorkspaceTransferTransientFile $name){if(-not $isDirectory -and ([IO.FileInfo]$entryPath).Length -gt 0){throw ('A lock file contains data and cannot be omitted from transfer: '+$name)};continue};if($allowedForRole[$profile.Role] -cnotcontains $name){throw ('Workspace has an unrecognized top-level entry: '+$name)}}
    foreach($required in @('workspace-control','hosts')){if(-not [IO.Directory]::Exists((Join-Path $root $required))){throw ('Workspace transfer is missing its required directory: '+$required)}}
    $hostsRoot=Join-Path $root 'hosts'
    $hostDirectory=''
    foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($hostsRoot)){$attributes=[IO.File]::GetAttributes($entryPath);if(($attributes -band [IO.FileAttributes]::Directory) -eq 0){continue};if($hostDirectory){throw 'Workspace must contain exactly its enrolled host directory.'};$hostDirectory=$entryPath}
    if(-not $hostDirectory -or [IO.Path]::GetFileName($hostDirectory) -ine $profile.Fingerprint){throw 'Workspace must contain exactly its enrolled host directory.'}
    $hostRoot=$hostDirectory
    if(-not [IO.File]::Exists((Join-Path $hostRoot 'enrollment.json'))){throw 'Workspace host enrollment state is incomplete.'}
    if($profile.Role -eq 'Source' -and -not [IO.Directory]::Exists((Join-Path $hostRoot 'inventory'))){throw 'Workspace source inventory state is incomplete.'}
    if($profile.Role -in @('Manager','Target') -and -not [IO.Directory]::Exists((Join-Path $root 'pairs'))){throw 'Workspace pair state directory is missing.'}
    if($profile.Role -eq 'Target' -and -not [IO.Directory]::Exists((Join-Path $root 'targets'))){throw 'Workspace target identity directory is missing.'}
    $dirs=New-Object 'System.Collections.Generic.List[string]';$files=New-Object 'System.Collections.Generic.List[object]';$dirs.Add('')
    $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($root)
    $total=[long]0;$maxFiles=100000;$maxBytes=[long]2199023255552;$maxMetadataBytes=[long]134217728;$metadataBytes=[long]0
    while($stack.Count){
        $current=$stack.Pop();Assert-WsmNoReparse $current
        foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($current)){
            $relative=$entryPath.Substring($root.Length).TrimStart('\');Assert-WsmWorkspaceTransferNoExternalMutableState $relative
            Assert-WsmNoReparse $entryPath
            $attributes=[IO.File]::GetAttributes($entryPath);$isDirectory=($attributes -band [IO.FileAttributes]::Directory) -ne 0;$entryName=[IO.Path]::GetFileName($entryPath)
            $metadataBytes += [Text.Encoding]::UTF8.GetByteCount($relative) + 256
            if($metadataBytes -gt $maxMetadataBytes){throw 'Workspace inventory metadata exceeds the 128 MiB bound.'}
            if($isDirectory){$dirs.Add($relative);if($dirs.Count+$files.Count -gt $maxFiles){throw 'Workspace inventory exceeds the 100,000 path bound.'};$stack.Push($entryPath);continue}
            if(Test-WsmWorkspaceTransferTransientFile $entryName){
                if(([IO.FileInfo]$entryPath).Length -gt 0){throw ('A lock file contains data and cannot be omitted from transfer: '+$relative)}
                continue
            }
            if($entryPath -ieq $markerPath){if($AllowTransferMarker){continue};throw 'Workspace transfer marker blocks migration.'}
            if($relative -ieq 'workspace-control\output-profile.json'){$info=Get-WsmWorkspaceTransferFileHash $entryPath;$files.Add([pscustomobject]@{Path=$relative;Bytes=$info.Bytes;SHA256=$info.SHA256;Kind='OutputProfile'});$total+=$info.Bytes;continue}
            $info=Get-WsmWorkspaceTransferFileHash $entryPath
            $files.Add([pscustomobject]@{Path=$relative;Bytes=$info.Bytes;SHA256=$info.SHA256;Kind='File'});$total+=$info.Bytes
            if($dirs.Count+$files.Count -gt $maxFiles){throw 'Workspace inventory exceeds the 100,000 path bound.'}
            if($total -gt $maxBytes){throw 'Workspace exceeds the 2 TiB transfer byte bound.'}
        }
    }
    $dirs.Sort([StringComparer]::OrdinalIgnoreCase)
    $fileRows=@($files | Sort-Object Path)
    $inventory=[pscustomobject][ordered]@{Role=$profile.Role;HostId=[string]$profile.HostId;ProfileId=[string]$profile.ProfileId;Fingerprint=[string]$profile.Fingerprint;Revision=[long](Get-WsmWorkspaceTransferRevision $root $profile);Directories=@($dirs.ToArray());Files=$fileRows;FileCount=$fileRows.Count;PathCount=($dirs.Count+$fileRows.Count);TotalBytes=$total}
    return [pscustomobject]@{Root=$root;Profile=$profile;Inventory=$inventory}
}
function Get-WsmWorkspaceTransferRevision([string]$Root,$Profile) {
    if($Profile.Role -eq 'Source'){$statePath=Join-Path $Root ('hosts\'+$Profile.Fingerprint+'\inventory\source-state.json');if(-not [IO.File]::Exists($statePath)){throw 'Source state is missing; restore or repair the original enrollment before transfer.'};$state=Read-WsmJson $statePath;if($state.HostId -cne $Profile.HostId -or $state.Fingerprint -cne $Profile.Fingerprint -or $state.Revision -lt 0){throw 'Source state identity or revision is inconsistent.'};return [long]$state.Revision}
    return [long]0
}
function Get-WsmWorkspaceTransferDestinationCapacity([string]$DestinationRoot,[long]$CopyBytes) {
    $parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($DestinationRoot))
    if(-not $parent -or -not [IO.Directory]::Exists($parent)){throw 'Destination parent must already exist as a controlled directory.'}
    Assert-WsmNoReparse $parent
    $free=[long](Get-WsmAvailableBytes $parent);$required=$CopyBytes+[long]1048576
    if($free -lt $required){throw ('Destination volume has insufficient free space: requires '+$required+' bytes plus available '+$free+'.')}
    [pscustomobject]@{Path=$parent;AvailableBytes=$free;RequiredBytes=$required;Sufficient=$true}
}
function Assert-WsmWorkspaceTransferProfileEquivalent($SourceProfile,$DestinationProfile,[string]$DestinationRoot) {
    $sourceNames=@($SourceProfile.PSObject.Properties.Name | Sort-Object);$destinationNames=@($DestinationProfile.PSObject.Properties.Name | Sort-Object)
    if((ConvertTo-Json -InputObject $sourceNames -Compress) -cne (ConvertTo-Json -InputObject $destinationNames -Compress)){throw 'Destination profile schema changed during WorkRoot migration.'}
    foreach($name in $sourceNames){if($name -ceq 'WorkRoot'){continue};$left=ConvertTo-Json -InputObject $SourceProfile.$name -Compress -Depth 30;$right=ConvertTo-Json -InputObject $DestinationProfile.$name -Compress -Depth 30;if($left -cne $right){throw ('Destination output profile changed outside WorkRoot: '+$name)}}
    if([IO.Path]::GetFullPath($DestinationProfile.WorkRoot) -ine [IO.Path]::GetFullPath($DestinationRoot)){throw 'Destination output profile does not bind to its new WorkRoot.'}
}
function Get-WsmWorkspaceTransferLockDirectories([string]$Root,$Inventory) {
    $set=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($path in @($Root,(Join-Path $Root 'workspace-control'),(Join-Path $Root ('hosts\'+$Inventory.Fingerprint)),(Join-Path $Root ('hosts\'+$Inventory.Fingerprint+'\inventory')),(Join-Path $Root 'pairs'))){if([IO.Directory]::Exists($path)){[void]$set.Add($path)}}
    if([IO.Directory]::Exists((Join-Path $Root 'pairs'))){foreach($path in [IO.Directory]::EnumerateDirectories((Join-Path $Root 'pairs'))){$name=[IO.Path]::GetFileName($path);if($name -match '^[0-9a-fA-F-]{36}$'){[void]$set.Add($path)}}}
    return @($set | Sort-Object)
}
function Enter-WsmWorkspaceTransferLocks([string]$Root,$Inventory) {
    $locks=New-Object 'System.Collections.Generic.List[object]'
    try{
        foreach($dir in @(Get-WsmWorkspaceTransferLockDirectories $Root $Inventory)){
            $path=Join-Path $dir '.wsm.lock';Assert-WsmNoReparse $path
            try{$stream=[IO.File]::Open($path,'OpenOrCreate','ReadWrite','None')}catch{throw ('Workspace transfer could not acquire an exclusive workspace lock: '+$dir)}
            $locks.Add($stream)
        }
        # Also hold any extant tool lock files outside the standard state roots (for example an import lock).
        $pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($Root)
        while($pending.Count){$directory=$pending.Pop();Assert-WsmNoReparse $directory
            foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($directory)){
                Assert-WsmNoReparse $entryPath;$attributes=[IO.File]::GetAttributes($entryPath)
                if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){$pending.Push($entryPath);continue}
                $name=[IO.Path]::GetFileName($entryPath);if($name -ieq '.wsm.lock' -or -not (Test-WsmWorkspaceTransferTransientFile $name)){continue}
                try{$stream=[IO.File]::Open($entryPath,'Open','ReadWrite','None')}catch{throw ('Workspace transfer found an active tool lock: '+$entryPath)}
                $locks.Add($stream)
            }
        }
        return ,$locks
    }catch{foreach($stream in $locks){$stream.Dispose()};throw}
}
function Exit-WsmWorkspaceTransferLocks($Locks) {if($Locks){foreach($stream in $Locks){try{$stream.Dispose()}catch{}}}}
function Move-WsmWorkspaceTransferStage([string]$Stage,[string]$Destination) {[IO.Directory]::Move($Stage,$Destination)}
function Remove-WsmWorkspaceTransferMarker([string]$Path) {Remove-Item -LiteralPath $Path -Force}
function Assert-WsmWorkspaceTransferInventoryEqual($Expected,$Actual,[string]$Message) {
    if($Expected.Role -cne $Actual.Role -or $Expected.HostId -cne $Actual.HostId -or $Expected.ProfileId -cne $Actual.ProfileId -or $Expected.Fingerprint -cne $Actual.Fingerprint -or [long]$Expected.Revision -ne [long]$Actual.Revision -or $Expected.PathCount -ne $Actual.PathCount -or $Expected.FileCount -ne $Actual.FileCount -or [long]$Expected.TotalBytes -ne [long]$Actual.TotalBytes){throw $Message}
    if((ConvertTo-Json -InputObject @($Expected.Directories) -Compress -Depth 5) -cne (ConvertTo-Json -InputObject @($Actual.Directories) -Compress -Depth 5)){throw $Message}
    $left=@($Expected.Files | Sort-Object Path);$right=@($Actual.Files | Sort-Object Path)
    for($i=0;$i -lt $left.Count;$i++){if($left[$i].Path -cne $right[$i].Path -or [long]$left[$i].Bytes -ne [long]$right[$i].Bytes -or $left[$i].SHA256 -ine $right[$i].SHA256){throw $Message}}
}
function Get-WsmWorkspaceTransferPreviewInventory($Preview) {
    [pscustomobject]@{Role=$Preview.Role;HostId=$Preview.HostId;ProfileId=$Preview.ProfileId;Fingerprint=$Preview.Fingerprint;Revision=[long]$Preview.Revision;PathCount=$Preview.PathCount;FileCount=$Preview.FileCount;TotalBytes=[long]$Preview.TotalBytes;Directories=@($Preview.Directories);Files=@($Preview.Files)}
}
function Assert-WsmWorkspaceTransferMovedInventoryEqual($SourceInventory,$MovedInventory,$SourceProfile,$MovedProfile,[string]$DestinationRoot,[string]$Message) {
    if($SourceInventory.Role -cne $MovedInventory.Role -or $SourceInventory.HostId -cne $MovedInventory.HostId -or $SourceInventory.ProfileId -cne $MovedInventory.ProfileId -or $SourceInventory.Fingerprint -cne $MovedInventory.Fingerprint -or [long]$SourceInventory.Revision -ne [long]$MovedInventory.Revision -or $SourceInventory.PathCount -ne $MovedInventory.PathCount -or $SourceInventory.FileCount -ne $MovedInventory.FileCount){throw $Message}
    if((ConvertTo-Json -InputObject @($SourceInventory.Directories) -Compress -Depth 5) -cne (ConvertTo-Json -InputObject @($MovedInventory.Directories) -Compress -Depth 5)){throw $Message}
    $left=@($SourceInventory.Files | Sort-Object Path);$right=@($MovedInventory.Files | Sort-Object Path)
    for($i=0;$i -lt $left.Count;$i++){if($left[$i].Path -cne $right[$i].Path -or $left[$i].Kind -cne $right[$i].Kind){throw $Message};if($left[$i].Kind -cne 'OutputProfile' -and ([long]$left[$i].Bytes -ne [long]$right[$i].Bytes -or $left[$i].SHA256 -ine $right[$i].SHA256)){throw $Message}}
    Assert-WsmWorkspaceTransferProfileEquivalent $SourceProfile $MovedProfile $DestinationRoot
}
function Write-WsmWorkspaceTransferPreview([string]$Path,$Preview,[string[]]$Roots) {
    $full=[IO.Path]::GetFullPath($Path);if([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)){throw 'Preview output path must be a new file.'}
    $parent=[IO.Path]::GetDirectoryName($full);if(-not [IO.Directory]::Exists($parent)){throw 'Preview parent directory must already exist.'};Assert-WsmNoReparse $parent
    $physicalPreview=(Join-Path (Get-WsmPhysicalPath $parent) ([IO.Path]::GetFileName($full)))
    foreach($root in $Roots){if(Test-WsmPathOverlap $physicalPreview (Get-WsmPhysicalPath $root)){throw 'Transfer preview must be stored outside both workspace roots.'}}
    $json=ConvertTo-Json -InputObject $Preview -Depth 40
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 134217728){throw 'Transfer preview exceeds the 128 MiB bounded JSON limit.'}
    $stream=[IO.File]::Open($full,'CreateNew','Write','None');try{$bytes=[Text.Encoding]::UTF8.GetBytes($json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    $digest=Get-WsmWorkspaceTransferHash $full
    $fileCount=if($Preview.PSObject.Properties['FileCount']){[long]$Preview.FileCount}else{[long]$Preview.DestinationFileCount}
    $totalBytes=if($Preview.PSObject.Properties['TotalBytes']){[long]$Preview.TotalBytes}else{[long]$Preview.DestinationTotalBytes}
    $recoveryMode='';if($Preview.PSObject.Properties['RecoveryMode']){$recoveryMode=[string]$Preview.RecoveryMode}
    $recoveryComplete=$false;if($Preview.PSObject.Properties['RecoveryComplete']){$recoveryComplete=[bool]$Preview.RecoveryComplete}
    [pscustomobject]@{Path=$full;SHA256=$digest;PreviewHash=$digest;Role=$Preview.Role;HostId=$Preview.HostId;ProfileId=$Preview.ProfileId;FileCount=$fileCount;TotalBytes=$totalBytes;SourceWorkRoot=$Preview.SourceWorkRoot;DestinationWorkRoot=$Preview.DestinationWorkRoot;RecoveryMode=$recoveryMode;RecoveryComplete=$recoveryComplete}
}
function Read-WsmWorkspaceTransferPreview([string]$Path,[string]$ExpectedHash,[string]$Kind) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'An independently confirmed SHA256 is required for the transfer preview.'}
    Assert-WsmNoReparse $Path;Assert-WsmTrustedFile $Path $ExpectedHash
    $preview=Read-WsmJson $Path
    if($preview.SchemaVersion -ne 1 -or $preview.Kind -cne $Kind){throw 'Transfer preview kind or schema is invalid.'}
    return $preview
}
function New-WsmOutputWorkspaceTransferPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceWorkRoot,[Parameter(Mandatory)][string]$DestinationWorkRoot,[Parameter(Mandatory)][string]$Path)
    $source=Get-WsmWorkspaceTransferInventory $SourceWorkRoot
    $destination=Assert-WsmWorkspaceTransferRoot $DestinationWorkRoot -AllowMissing
    if(Test-WsmPathOverlap (Get-WsmPhysicalPath $source.Root) (Get-WsmPhysicalPath $destination)){throw 'Source and destination WorkRoots physically overlap.'}
    if([IO.Directory]::Exists($destination) -or [IO.File]::Exists($destination)){throw 'Destination WorkRoot must be new and empty of prior state.'}
    $capacity=Get-WsmWorkspaceTransferDestinationCapacity $destination ([long]$source.Inventory.TotalBytes)
    $identity=Get-WsmMachineIdentity;if($source.Profile.Fingerprint -ine $identity.Fingerprint){throw 'Workspace enrollment fingerprint does not match this host.'}
    $preview=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WorkspaceTransferPreview';CreatedUtc=(Get-WsmUtc);SourceWorkRoot=$source.Root;DestinationWorkRoot=$destination;Role=$source.Profile.Role;HostId=$source.Profile.HostId;ProfileId=$source.Profile.ProfileId;Fingerprint=$source.Profile.Fingerprint;Revision=[long]$source.Inventory.Revision;FileCount=$source.Inventory.FileCount;PathCount=$source.Inventory.PathCount;TotalBytes=[long]$source.Inventory.TotalBytes;DestinationAvailableBytes=[long]$capacity.AvailableBytes;DestinationRequiredBytes=[long]$capacity.RequiredBytes;Directories=@($source.Inventory.Directories);Files=@($source.Inventory.Files);AcknowledgementRequired='MIGRATE-WORKROOT';StoppedAllToolsRequired=$true;Quiescence='Operator prerequisite: stop every WSM tool process; scans and exclusive file locks cannot prove that an already-loaded process has stopped.'}
    Write-WsmWorkspaceTransferPreview $Path $preview @($source.Root,$destination)
}
function Copy-WsmWorkspaceTransferFile([string]$Source,[string]$Destination,[long]$Bytes,[string]$Hash) {
    Assert-WsmNoReparse $Source;Assert-WsmNoReparse ([IO.Path]::GetDirectoryName($Destination))
    $input=[IO.File]::Open([IO.Path]::GetFullPath($Source),'Open','Read','Read');$output=$null;$sha=[Security.Cryptography.SHA256]::Create();$copied=[long]0
    try{
        if($input.Length -ne $Bytes){throw 'Workspace source file changed before copy.'}
        $output=[IO.File]::Open([IO.Path]::GetFullPath($Destination),'CreateNew','Write','None');$buffer=New-Object byte[] 65536
        while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){$copied+=$read;if($copied -gt $Bytes){throw 'Workspace source file grew during copy.'};$output.Write($buffer,0,$read);[void]$sha.TransformBlock($buffer,0,$read,$buffer,0)}
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0);$output.Flush($true)
        $actual=[BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()
        if($copied -ne $Bytes -or $actual -ine $Hash){throw 'Workspace copy bytes or SHA256 did not match the preview.'}
    }finally{if($output){$output.Dispose()};$input.Dispose();$sha.Dispose()}
}
function Get-WsmWorkspaceTransferDestinationInventory([string]$Root,[string]$OriginalRoot,$Preview) {
    $inventory=Get-WsmWorkspaceTransferInventory $Root -AllowTransferMarker
    Assert-WsmWorkspaceTransferInventoryEqual $Preview $inventory 'Destination workspace inventory differs from the transfer preview.'
    $profilePath=Join-Path $Root 'workspace-control\output-profile.json';$profile=Read-WsmJson $profilePath
    if([IO.Path]::GetFullPath($profile.WorkRoot) -ine [IO.Path]::GetFullPath($Root)){throw 'Destination profile WorkRoot does not bind to the destination.'}
    $sourceProfile=$Preview.Files | Where-Object Path -CEQ 'workspace-control\output-profile.json' | Select-Object -First 1
    if(-not $sourceProfile){throw 'Transfer preview is missing its output profile.'}
    $originalProfilePath=Join-Path $OriginalRoot 'workspace-control\output-profile.json';$originalProfile=Read-WsmJson $originalProfilePath
    if($profile.ProfileId -cne $originalProfile.ProfileId -or $profile.HostId -cne $originalProfile.HostId -or $profile.Fingerprint -cne $originalProfile.Fingerprint -or $profile.Role -cne $originalProfile.Role){throw 'Destination profile changed an identity field during WorkRoot migration.'}
    return $inventory
}
function Assert-WsmWorkspaceTransferAcknowledgement([string]$Acknowledgement,[bool]$StoppedAllTools) {
    if($Acknowledgement -cne 'MIGRATE-WORKROOT'){throw 'Type the exact acknowledgement MIGRATE-WORKROOT to apply the transfer.'}
    if(-not $StoppedAllTools){throw 'Explicitly confirm that all WSM tools are stopped before applying this transfer.'}
}
function Invoke-WsmOutputWorkspaceTransfer {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$PreviewPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$Acknowledgement,[Parameter(Mandatory)][switch]$StoppedAllTools)
    Assert-WsmWorkspaceTransferAcknowledgement $Acknowledgement ([bool]$StoppedAllTools)
    $preview=Read-WsmWorkspaceTransferPreview $PreviewPath $ExpectedHash 'WorkspaceTransferPreview'
    if(-not $PSCmdlet.ShouldProcess($preview.SourceWorkRoot,'Transfer controlled workspace state to '+$preview.DestinationWorkRoot)){return [pscustomobject]@{Applied=$false;WhatIf=$true;SourceWorkRoot=$preview.SourceWorkRoot;DestinationWorkRoot=$preview.DestinationWorkRoot;PreviewHash=$ExpectedHash.ToLowerInvariant()}}
    $source=Assert-WsmWorkspaceTransferRoot $preview.SourceWorkRoot;$destination=Assert-WsmWorkspaceTransferRoot $preview.DestinationWorkRoot -AllowMissing
    if([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($preview.SourceWorkRoot) -or [IO.Path]::GetFullPath($destination) -ine [IO.Path]::GetFullPath($preview.DestinationWorkRoot)){throw 'Transfer roots differ from the pinned preview.'}
    if(Test-WsmPathOverlap (Get-WsmPhysicalPath $source) (Get-WsmPhysicalPath $destination)){throw 'Transfer roots physically overlap.'}
    if([IO.Directory]::Exists($destination) -or [IO.File]::Exists($destination)){throw 'Destination WorkRoot must still be absent.'}
    $before=Get-WsmWorkspaceTransferInventory $source
    Assert-WsmWorkspaceTransferInventoryEqual $preview $before.Inventory 'Source workspace changed after preview.'
    if($before.Profile.Role -cne $preview.Role -or $before.Profile.HostId -cne $preview.HostId -or $before.Profile.ProfileId -cne $preview.ProfileId -or $before.Profile.Fingerprint -cne $preview.Fingerprint){throw 'Workspace identity changed after preview.'}
    if((Get-WsmMachineIdentity).Fingerprint -ine $preview.Fingerprint){throw 'Workspace fingerprint changed; migration is same-host only.'}
    [void](Get-WsmWorkspaceTransferDestinationCapacity $destination ([long]$preview.TotalBytes))
    $locks=$null;$marker=Join-Path $source 'workspace-control\workspace-transfer.json';$destinationMarker=$null;$stage=$null
    try{
        $locks=Enter-WsmWorkspaceTransferLocks $source $preview
        $afterLock=Get-WsmWorkspaceTransferInventory $source;Assert-WsmWorkspaceTransferInventoryEqual $preview $afterLock.Inventory 'Source workspace changed before exclusive locks were acquired.'
        $transferId=[Guid]::NewGuid().ToString('D');$stage=Join-Path ([IO.Path]::GetDirectoryName($destination)) ('.wsm-'+$transferId.Replace('-','').Substring(0,16))
        $sourceRecord=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WorkspaceTransfer';TransferId=$transferId;Status='Prepared';PreviewPath=[IO.Path]::GetFullPath($PreviewPath);PreviewHash=$ExpectedHash.ToLowerInvariant();DestinationWorkRoot=$destination;StagingWorkRoot=$stage;Role=$preview.Role;HostId=$preview.HostId;ProfileId=$preview.ProfileId;Fingerprint=$preview.Fingerprint;Revision=[long]$preview.Revision;CreatedUtc=(Get-WsmUtc);OperatorConfirmedStoppedAllTools=$true}
        Write-WsmJson $marker $sourceRecord
        if([IO.Directory]::Exists($stage) -or [IO.File]::Exists($stage)){throw 'A staging directory for this transfer identity already exists.'}
        [void][IO.Directory]::CreateDirectory($stage);Protect-WsmDirectory $stage;Assert-WsmNoReparse $stage
        [void][IO.Directory]::CreateDirectory((Join-Path $stage 'workspace-control'));Protect-WsmDirectory (Join-Path $stage 'workspace-control')
        $destinationMarker=Join-Path $stage 'workspace-control\workspace-transfer.json'
        $destinationRecord=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WorkspaceTransfer';TransferId=$sourceRecord.TransferId;Status='Prepared';SourceWorkRoot=$source;PreviewHash=$ExpectedHash.ToLowerInvariant();CreatedUtc=(Get-WsmUtc)}
        Write-WsmJson $destinationMarker $destinationRecord
        foreach($relative in @($preview.Directories | Sort-Object {($_ -split '\\').Count})){$path=if($relative){Join-Path $stage $relative}else{$stage};if(-not [IO.Directory]::Exists($path)){[void][IO.Directory]::CreateDirectory($path);Protect-WsmDirectory $path};Assert-WsmNoReparse $path}
        foreach($file in $preview.Files){
            $from=Join-Path $source $file.Path;$to=Join-Path $stage $file.Path
            if($file.Kind -eq 'OutputProfile'){$saved=Read-WsmJson $from;$saved.WorkRoot=$destination;Write-WsmJson $to $saved;$expected=(Get-WsmWorkspaceTransferFileHash $to).SHA256;if($expected -eq $file.SHA256){throw 'Output profile WorkRoot rewrite did not change the profile bytes.'};continue}
            Copy-WsmWorkspaceTransferFile $from $to ([long]$file.Bytes) ([string]$file.SHA256)
        }
        $sourceNow=Get-WsmWorkspaceTransferInventory $source -AllowTransferMarker;Assert-WsmWorkspaceTransferInventoryEqual $preview $sourceNow.Inventory 'Source changed during workspace copy.'
        $destinationNow=Get-WsmWorkspaceTransferInventory $stage -AllowTransferMarker -ExpectedProfileWorkRoot $destination
        Assert-WsmWorkspaceTransferProfileEquivalent $before.Profile $destinationNow.Profile $destination
        $expectedFileCount=$preview.Files.Count;$expectedPathCount=$preview.PathCount
        if($destinationNow.Inventory.FileCount -ne $expectedFileCount -or $destinationNow.Inventory.PathCount -ne $expectedPathCount){throw 'Destination file or directory inventory is incomplete.'}
        foreach($file in $preview.Files){$copied=Get-WsmWorkspaceTransferFileHash (Join-Path $stage $file.Path);if($file.Kind -ne 'OutputProfile' -and ($copied.Bytes -ne [long]$file.Bytes -or $copied.SHA256 -ine $file.SHA256)){throw ('Destination member verification failed: '+$file.Path)}}
        if([IO.Directory]::Exists($destination) -or [IO.File]::Exists($destination)){throw 'Destination WorkRoot appeared during transfer; preserving the staged copy.'}
        $sourceRecord.Status='Migrated';$sourceRecord | Add-Member NoteProperty MigratedUtc (Get-WsmUtc);Write-WsmJson $marker $sourceRecord
        Move-WsmWorkspaceTransferStage $stage $destination;$destinationMarker=Join-Path $destination 'workspace-control\workspace-transfer.json'
        Remove-WsmWorkspaceTransferMarker $destinationMarker
        return [pscustomobject]@{Applied=$true;Status='Migrated';SourceWorkRoot=$source;DestinationWorkRoot=$destination;Role=$preview.Role;HostId=$preview.HostId;ProfileId=$preview.ProfileId;Revision=[long]$preview.Revision;FileCount=$preview.FileCount;TotalBytes=[long]$preview.TotalBytes;PreviewHash=$ExpectedHash.ToLowerInvariant();SourceMarker=$marker}
    }catch{
        if([IO.File]::Exists($marker)){try{$record=Read-WsmJson $marker;if($record.PreviewHash -ieq $ExpectedHash -and $record.Status -ceq 'Prepared'){Remove-Item -LiteralPath $marker -Force}}catch{}}
        # Leave any partial destination marked Prepared so a future process cannot enroll it as a second writer.
        throw
    }finally{Exit-WsmWorkspaceTransferLocks $locks}
}
function Assert-WsmOutputWorkspaceNotMigrated([string]$WorkRoot) {
    $root=[IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')
    $cursor=$root
    while($cursor){
        $marker=Join-Path $cursor 'workspace-control\workspace-transfer.json'
        if([IO.File]::Exists($marker)){
            Assert-WsmNoReparse $marker;$record=Read-WsmJson $marker
            $status='unknown';if($record.PSObject.Properties['Status']){$status=[string]$record.Status}
            if($record.Kind -cne 'WorkspaceTransfer' -or $record.SchemaVersion -ne 1 -or $status -notin @('Prepared','Migrated','MigratedBack','RestorePrepared','MigrationAbandoned')){throw 'This WorkRoot has an invalid transfer marker; fail-closed recovery is required.'}
            throw ('This WorkRoot is transfer-marked as '+$status+'; use the migrated WorkRoot or explicitly restore the transfer.')
        }
        $parent=[IO.Directory]::GetParent($cursor);if(-not $parent){break};$cursor=$parent.FullName
    }
}
function New-WsmOutputWorkspaceTransferRestorePreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceWorkRoot,[Parameter(Mandatory)][string]$DestinationWorkRoot,[Parameter(Mandatory)][string]$Path)
    $oldRoot=Assert-WsmWorkspaceTransferRoot $SourceWorkRoot;$newRoot=Assert-WsmWorkspaceTransferRoot $DestinationWorkRoot -AllowMissing
    if(Test-WsmPathOverlap (Get-WsmPhysicalPath $oldRoot) (Get-WsmPhysicalPath $newRoot)){throw 'Restore roots physically overlap.'}
    $markerPath=Join-Path $oldRoot 'workspace-control\workspace-transfer.json';if(-not [IO.File]::Exists($markerPath)){throw 'Original WorkRoot has no transfer tombstone to restore.'}
    $marker=Read-WsmJson $markerPath;if($marker.Kind -cne 'WorkspaceTransfer' -or $marker.SchemaVersion -ne 1 -or $marker.Status -notin @('Prepared','Migrated')){throw 'Original WorkRoot marker is not a supported interrupted or completed transfer state.'}
    $original=Get-WsmWorkspaceTransferInventory $oldRoot -AllowTransferMarker
    $identity=[pscustomobject]@{Role=$marker.Role;HostId=$marker.HostId;ProfileId=$marker.ProfileId;Fingerprint=$marker.Fingerprint;Revision=[long]$marker.Revision}
    if($original.Profile.Role -cne $identity.Role -or $original.Profile.HostId -cne $identity.HostId -or $original.Profile.ProfileId -cne $identity.ProfileId -or $original.Profile.Fingerprint -cne $identity.Fingerprint -or $original.Inventory.Revision -ne $identity.Revision){throw 'Original workspace identity or revision differs from its transfer tombstone.'}
    if(-not $marker.PSObject.Properties['PreviewPath'] -or -not $marker.PSObject.Properties['PreviewHash'] -or -not $marker.PSObject.Properties['StagingWorkRoot']){throw 'Transfer tombstone lacks a trusted preview or staging path; keep the original root blocked for manual repair.'}
    $transferPreview=Read-WsmWorkspaceTransferPreview ([string]$marker.PreviewPath) ([string]$marker.PreviewHash) 'WorkspaceTransferPreview'
    if([IO.Path]::GetFullPath($transferPreview.SourceWorkRoot) -ine $oldRoot -or [IO.Path]::GetFullPath($transferPreview.DestinationWorkRoot) -ine $newRoot){throw 'Transfer preview roots differ from the source tombstone.'}
    $sourceExpected=Get-WsmWorkspaceTransferPreviewInventory $transferPreview
    Assert-WsmWorkspaceTransferInventoryEqual $sourceExpected $original.Inventory 'Original workspace changed after the interrupted transfer; preserve its data and reconcile manually.'
    $expectedStage=Join-Path ([IO.Path]::GetDirectoryName($newRoot)) ('.wsm-'+([string]$marker.TransferId).Replace('-','').Substring(0,16))
    if([IO.Path]::GetFullPath([string]$marker.StagingWorkRoot) -ine [IO.Path]::GetFullPath($expectedStage)){throw 'Transfer tombstone staging path is not bound to its transfer identity.'}
    if($marker.Status -eq 'Prepared' -and (([IO.Directory]::Exists($newRoot)) -or ([IO.File]::Exists($newRoot)))){throw 'Prepared transfer encountered a final destination conflict; keep both roots blocked for manual reconciliation.'}
    $recoveryRoot=$expectedStage;if($marker.Status -eq 'Migrated' -and [IO.Directory]::Exists($newRoot)){$recoveryRoot=$newRoot}
    $recoveryComplete=$false;$recoveryMarkerHash='';$recoveryRootExists=[IO.Directory]::Exists($recoveryRoot);$recoveryProfile=$null;$recoveryInventory=$null;$recoveryMarkerPresent=$false
    if($recoveryRootExists){
        Assert-WsmNoReparse $recoveryRoot
        $recoveryMarkerPath=Join-Path $recoveryRoot 'workspace-control\workspace-transfer.json'
        if([IO.File]::Exists($recoveryMarkerPath)){
            Assert-WsmNoReparse $recoveryMarkerPath;$recoveryMarker=Read-WsmJson $recoveryMarkerPath
            if($recoveryMarker.Kind -cne 'WorkspaceTransfer' -or $recoveryMarker.SchemaVersion -ne 1 -or $recoveryMarker.TransferId -cne $marker.TransferId -or $recoveryMarker.PreviewHash -ine $marker.PreviewHash -or $recoveryMarker.Status -notin @('Prepared','MigratedBack','MigrationAbandoned')){throw 'Interrupted transfer copy has an untrusted marker; keep the original root blocked.'}
            $recoveryMarkerHash=Get-WsmWorkspaceTransferHash $recoveryMarkerPath;$recoveryMarkerPresent=$true
        }elseif($recoveryRoot -ieq $newRoot -and $marker.Status -cne 'Migrated'){throw 'Final destination exists without a transfer marker; keep the original root blocked.'}
        try{
            $candidate=Get-WsmWorkspaceTransferInventory $recoveryRoot -AllowTransferMarker -ExpectedProfileWorkRoot $newRoot
            Assert-WsmWorkspaceTransferMovedInventoryEqual $sourceExpected $candidate.Inventory $original.Profile $candidate.Profile $newRoot 'Recovery copy is incomplete or changed.'
            $recoveryComplete=$true;$recoveryProfile=$candidate.Profile;$recoveryInventory=$candidate.Inventory
        }catch{
            if($recoveryRoot -ieq $newRoot -and -not $recoveryMarkerHash){throw 'Final destination cannot be proven to belong to this transfer; keep the original root blocked.'}
            $recoveryComplete=$false
        }
    }
    $isCompleted=($marker.Status -eq 'Migrated' -and $recoveryRoot -ieq $newRoot -and $recoveryComplete -and -not $recoveryMarkerPresent)
    $preview=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WorkspaceTransferRestorePreview';CreatedUtc=(Get-WsmUtc);SourceWorkRoot=$oldRoot;DestinationWorkRoot=$newRoot;Role=$identity.Role;HostId=$identity.HostId;ProfileId=$identity.ProfileId;Fingerprint=$identity.Fingerprint;Revision=[long]$identity.Revision;TransferPreviewHash=$marker.PreviewHash;SourceTransferStatus=[string]$marker.Status;SourceDirectories=@($original.Inventory.Directories);SourceFiles=@($original.Inventory.Files);SourceFileCount=$original.Inventory.FileCount;SourcePathCount=$original.Inventory.PathCount;SourceTotalBytes=[long]$original.Inventory.TotalBytes;RecoveryMode=$(if($isCompleted){'Completed'}else{'Interrupted'});RecoveryRoot=$recoveryRoot;RecoveryRootExists=$recoveryRootExists;RecoveryComplete=$recoveryComplete;RecoveryMarkerPresent=$recoveryMarkerPresent;RecoveryMarkerHash=$recoveryMarkerHash;DestinationDirectories=$(if($recoveryComplete){@($recoveryInventory.Directories)}else{@()});DestinationFiles=$(if($recoveryComplete){@($recoveryInventory.Files)}else{@()});DestinationFileCount=$(if($recoveryComplete){$recoveryInventory.FileCount}else{0});DestinationPathCount=$(if($recoveryComplete){$recoveryInventory.PathCount}else{0});DestinationTotalBytes=$(if($recoveryComplete){[long]$recoveryInventory.TotalBytes}else{0});SourceMarkerHash=(Get-WsmWorkspaceTransferHash $markerPath);AcknowledgementRequired='MIGRATE-WORKROOT';StoppedAllToolsRequired=$true;RestoreBehavior='Verify source bytes, tombstone any proven transfer copy or preserve-and-block partial staging data, then reactivate the original root.'}
    Write-WsmWorkspaceTransferPreview $Path $preview @($oldRoot,$newRoot)
}
function Invoke-WsmOutputWorkspaceTransferRestore {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$PreviewPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$Acknowledgement,[Parameter(Mandatory)][switch]$StoppedAllTools)
    Assert-WsmWorkspaceTransferAcknowledgement $Acknowledgement ([bool]$StoppedAllTools)
    $preview=Read-WsmWorkspaceTransferPreview $PreviewPath $ExpectedHash 'WorkspaceTransferRestorePreview'
    $oldRoot=Assert-WsmWorkspaceTransferRoot $preview.SourceWorkRoot;$newRoot=Assert-WsmWorkspaceTransferRoot $preview.DestinationWorkRoot -AllowMissing
    $markerPath=Join-Path $oldRoot 'workspace-control\workspace-transfer.json';if((Get-WsmWorkspaceTransferHash $markerPath) -ine $preview.SourceMarkerHash){throw 'Source transfer tombstone changed after restore preview.'}
    $sourceMarker=Read-WsmJson $markerPath;if($sourceMarker.Status -cne $preview.SourceTransferStatus -or $sourceMarker.PreviewHash -cne $preview.TransferPreviewHash){throw 'Source transfer tombstone no longer matches the restore preview.'}
    $transferPreview=Read-WsmWorkspaceTransferPreview ([string]$sourceMarker.PreviewPath) ([string]$sourceMarker.PreviewHash) 'WorkspaceTransferPreview'
    $sourceExpected=[pscustomobject]@{Role=$preview.Role;HostId=$preview.HostId;ProfileId=$preview.ProfileId;Fingerprint=$preview.Fingerprint;Revision=[long]$preview.Revision;PathCount=$preview.SourcePathCount;FileCount=$preview.SourceFileCount;TotalBytes=[long]$preview.SourceTotalBytes;Directories=@($preview.SourceDirectories);Files=@($preview.SourceFiles)}
    Assert-WsmWorkspaceTransferInventoryEqual $sourceExpected (Get-WsmWorkspaceTransferInventory $oldRoot -AllowTransferMarker).Inventory 'Original workspace changed since restore preview; preserve its data and reconcile manually.'
    $destinationExpected=[pscustomobject]@{Role=$preview.Role;HostId=$preview.HostId;ProfileId=$preview.ProfileId;Fingerprint=$preview.Fingerprint;Revision=[long]$preview.Revision;PathCount=$preview.DestinationPathCount;FileCount=$preview.DestinationFileCount;TotalBytes=[long]$preview.DestinationTotalBytes;Directories=@($preview.DestinationDirectories);Files=@($preview.DestinationFiles)}
    $recoveryRoot=[string]$preview.RecoveryRoot
    if($preview.RecoveryMode -ceq 'Completed'){
        if(-not [IO.Directory]::Exists($newRoot) -or $recoveryRoot -ine $newRoot){throw 'Completed destination is absent or changed after restore preview.'}
        $moved=Get-WsmWorkspaceTransferInventory $newRoot;Assert-WsmWorkspaceTransferInventoryEqual $destinationExpected $moved.Inventory 'Migrated destination has changed since restore preview; preserve its new data and reconcile manually.'
    }elseif($preview.RecoveryMode -ceq 'Interrupted'){
        if($preview.RecoveryRootExists -and -not [IO.Directory]::Exists($recoveryRoot)){throw 'Interrupted transfer copy disappeared after restore preview.'}
        if(-not $preview.RecoveryRootExists -and ([IO.Directory]::Exists($recoveryRoot) -or [IO.File]::Exists($recoveryRoot))){throw 'A recovery directory appeared after preview; preserve it and prepare a new restore preview.'}
        if($preview.RecoveryRootExists){
            Assert-WsmNoReparse $recoveryRoot;$recoveryMarkerPath=Join-Path $recoveryRoot 'workspace-control\workspace-transfer.json'
            if($preview.RecoveryMarkerPresent){if(-not [IO.File]::Exists($recoveryMarkerPath)){throw 'Interrupted destination marker changed after restore preview.'};Assert-WsmNoReparse $recoveryMarkerPath;if((Get-WsmWorkspaceTransferHash $recoveryMarkerPath) -ine $preview.RecoveryMarkerHash){throw 'Interrupted destination marker changed after restore preview.'}}
            elseif([IO.File]::Exists($recoveryMarkerPath)){throw 'Interrupted destination gained a transfer marker after preview; prepare a new restore preview.'}
            if($preview.RecoveryComplete){$moved=Get-WsmWorkspaceTransferInventory $recoveryRoot -AllowTransferMarker -ExpectedProfileWorkRoot $newRoot;Assert-WsmWorkspaceTransferInventoryEqual $destinationExpected $moved.Inventory 'Complete interrupted copy changed after restore preview.'}
        }
    }else{throw 'Unsupported restore preview recovery mode.'}
    if(-not $PSCmdlet.ShouldProcess($oldRoot,'Restore original workspace as the sole active root')){return [pscustomobject]@{Applied=$false;WhatIf=$true;SourceWorkRoot=$oldRoot;DestinationWorkRoot=$newRoot;PreviewHash=$ExpectedHash.ToLowerInvariant();RecoveryMode=$preview.RecoveryMode}}
    $sourceLocks=$null;$recoveryLocks=$null
    try{
        $sourceLocks=Enter-WsmWorkspaceTransferLocks $oldRoot $preview
        if($preview.RecoveryRootExists){$recoveryLocks=Enter-WsmWorkspaceTransferLocks $recoveryRoot $preview}
        if((Get-WsmWorkspaceTransferHash $markerPath) -ine $preview.SourceMarkerHash){throw 'Source transfer tombstone changed while acquiring restore locks.'}
        Assert-WsmWorkspaceTransferInventoryEqual $sourceExpected (Get-WsmWorkspaceTransferInventory $oldRoot -AllowTransferMarker).Inventory 'Original workspace changed while acquiring restore locks.'
        if($preview.RecoveryMode -ceq 'Completed'){
            $moved=Get-WsmWorkspaceTransferInventory $newRoot;Assert-WsmWorkspaceTransferInventoryEqual $destinationExpected $moved.Inventory 'Migrated destination changed while acquiring restore locks; preserve its new data.'
        }elseif($preview.RecoveryRootExists -and $preview.RecoveryComplete){
            $moved=Get-WsmWorkspaceTransferInventory $recoveryRoot -AllowTransferMarker -ExpectedProfileWorkRoot $newRoot;Assert-WsmWorkspaceTransferInventoryEqual $destinationExpected $moved.Inventory 'Complete interrupted copy changed while acquiring restore locks.'
        }
        if($preview.RecoveryRootExists){
            Assert-WsmNoReparse $recoveryRoot
            $recoveryMarkerPath=Join-Path $recoveryRoot 'workspace-control\workspace-transfer.json'
            if($preview.RecoveryMarkerPresent){Assert-WsmNoReparse $recoveryMarkerPath;$recoveryMarker=Read-WsmJson $recoveryMarkerPath}else{$recoveryMarker=$null}
            $status=if($preview.RecoveryComplete){'MigratedBack'}else{'MigrationAbandoned'}
            if($recoveryMarker){$recoveryMarker.Status=$status;$recoveryMarker | Add-Member NoteProperty RestorePreviewHash $ExpectedHash.ToLowerInvariant() -Force;$recoveryMarker | Add-Member NoteProperty RecoveredUtc (Get-WsmUtc) -Force;Write-WsmJson $recoveryMarkerPath $recoveryMarker}
            else{
                $control=Join-Path $recoveryRoot 'workspace-control';if([IO.File]::Exists($control)){throw 'Recovery control path is occupied by a file; original remains blocked.'};if([IO.Directory]::Exists($control)){Assert-WsmNoReparse $control}else{[void][IO.Directory]::CreateDirectory($control);Protect-WsmDirectory $control}
                $recoveryMarker=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='WorkspaceTransfer';Status=$status;TransferId=$sourceMarker.TransferId;PreviewHash=$preview.TransferPreviewHash;RestorePreviewHash=$ExpectedHash.ToLowerInvariant();SourceWorkRoot=$oldRoot;DestinationWorkRoot=$newRoot;CreatedUtc=(Get-WsmUtc);RecoveredUtc=(Get-WsmUtc)}
                Write-WsmJson $recoveryMarkerPath $recoveryMarker
            }
        }
        Remove-WsmWorkspaceTransferMarker $markerPath
        [pscustomobject]@{Applied=$true;Status='Restored';RecoveryMode=$preview.RecoveryMode;RecoveryComplete=[bool]$preview.RecoveryComplete;SourceWorkRoot=$oldRoot;DestinationWorkRoot=$newRoot;HostId=$preview.HostId;ProfileId=$preview.ProfileId;PreviewHash=$ExpectedHash.ToLowerInvariant();RecoveryMarker=$(if($preview.RecoveryRootExists){$recoveryMarkerPath}else{''})}
    }finally{Exit-WsmWorkspaceTransferLocks $sourceLocks;Exit-WsmWorkspaceTransferLocks $recoveryLocks}
}
