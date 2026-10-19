function Get-WsmFileMetadata([string]$Path,[string]$Mode) {
    Assert-WsmNoReparse $Path
    $attributes=[IO.File]::GetAttributes($Path)
    if(($attributes -band [IO.FileAttributes]::Encrypted) -ne 0){throw ('EFS requires dedicated key-aware procedure: '+$Path)}
    if(($attributes -band [IO.FileAttributes]::Directory) -eq 0){$streams=@(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop | Where-Object Stream -NE ':$DATA'); if($streams.Count){throw ('ADS requires dedicated metadata workflow: '+$Path)}}
    $acl=Get-Acl -LiteralPath $Path -Audit:($Mode -eq 'DaclOwnerSacl')
    $sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    if($Mode -eq 'DaclOwnerSacl'){$sections=$sections -bor [Security.AccessControl.AccessControlSections]::Audit}
    [pscustomobject]@{Sddl=$acl.GetSecurityDescriptorSddlForm($sections); MetadataMode=$Mode; Attributes=[int]$attributes; CreationUtc=[IO.File]::GetCreationTimeUtc($Path).ToString('o'); LastWriteUtc=[IO.File]::GetLastWriteTimeUtc($Path).ToString('o')}
}
function Convert-WsmMappedSddl([string]$Sddl,[hashtable]$SidMap) {
    if(-not $SidMap){return $Sddl}
    foreach($key in $SidMap.Keys){if($key -notmatch '^S-1-\d+(?:-\d+)+$' -or $SidMap[$key] -notmatch '^S-1-\d+(?:-\d+)+$'){throw 'SID mapping must contain SID values.'}}
    [regex]::Replace($Sddl,'S-1-\d+(?:-\d+)+',{param($m) if($SidMap.ContainsKey($m.Value)){[string]$SidMap[$m.Value]}else{$m.Value}})
}
function Set-WsmFileMetadata([string]$Path,$Metadata,[hashtable]$SidMap) {
    $acl=Get-Acl -LiteralPath $Path; $sddl=Convert-WsmMappedSddl $Metadata.Sddl $SidMap
    Assert-WsmResolvableSddl $sddl
    $sections=[Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    if($Metadata.MetadataMode -eq 'DaclOwnerSacl'){$sections=$sections -bor [Security.AccessControl.AccessControlSections]::Audit}
    $acl.SetSecurityDescriptorSddlForm($sddl,$sections); Set-Acl -LiteralPath $Path -AclObject $acl
    # Finish ACL/attribute writes before restoring the exact source timestamps.
    [IO.File]::SetAttributes($Path,[IO.FileAttributes]$Metadata.Attributes)
    if([IO.Directory]::Exists($Path)){[IO.Directory]::SetCreationTimeUtc($Path,[DateTime]::Parse($Metadata.CreationUtc).ToUniversalTime());[IO.Directory]::SetLastWriteTimeUtc($Path,[DateTime]::Parse($Metadata.LastWriteUtc).ToUniversalTime())}else{[IO.File]::SetCreationTimeUtc($Path,[DateTime]::Parse($Metadata.CreationUtc).ToUniversalTime());[IO.File]::SetLastWriteTimeUtc($Path,[DateTime]::Parse($Metadata.LastWriteUtc).ToUniversalTime())}
}
function Get-WsmScopeEntries($Spec,[string]$PackageRoot,$CancellationToken=$null) {
    if($Spec.PSObject.Properties['ContentSelection'] -and $Spec.ContentSelection -ceq 'ExactFiles'){Get-WsmExactConfigEntries $Spec $PackageRoot $CancellationToken;return}
    if($Spec.PSObject.Properties['ContentSelection'] -and $Spec.ContentSelection -ceq 'ExactMembers'){Get-WsmExactMemberEntries $Spec $PackageRoot $CancellationToken;return}
    if([IO.Path]::GetFullPath($Spec.SourcePath).Length -gt 239){throw 'FileScope exceeds the verified 239-character path limit; use a dedicated long-path workflow.'}
    $root=ConvertTo-WsmCanonicalPath $Spec.SourcePath; Assert-WsmNoReparse $root
    Assert-WsmFileScopeGuard -Path $root -Mode Root -CheckPhysicalAlias
    $package=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\'); if($package -ieq $root -or $package.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($package+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Scope overlaps package workspace.'}
    if(Test-WsmPathOverlap (Get-WsmPhysicalPath $root) (Get-WsmPhysicalPath $package)){throw 'Scope overlaps package workspace through physical aliases.'}
    if(-not [IO.File]::Exists($root) -and -not [IO.Directory]::Exists($root)){throw 'Approved scope is absent.'}
    $stack=New-Object 'System.Collections.Generic.Stack[string]'; $stack.Push($root)
    while($stack.Count){Assert-WsmCancellationBoundary $CancellationToken 'ScopeTraversal';$path=$stack.Pop(); $relative=$path.Substring($root.Length).TrimStart('\'); $exclude=$false; foreach($p in $Spec.ExcludedRelativePaths){if($relative -ieq $p -or $relative.StartsWith($p.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$exclude=$true;break}}; if($exclude){continue}; Assert-WsmRelativePath $relative -AllowRoot;if($path.Length -gt 239){throw 'FileScope exceeds the verified 239-character path limit; no payload is sealed.'}; Assert-WsmNoReparse $path;if($Spec.PSObject.Properties['TransferChannel']){Assert-WsmAssistiveFileTopology $path}else{Assert-WsmFileScopeGuard -Path $path -Mode Collected -IsDirectory:([IO.Directory]::Exists($path))}; $directory=[IO.Directory]::Exists($path); [pscustomobject]@{SourcePath=$path; RelativePath=$relative; Directory=$directory}; if($directory){foreach($child in [IO.Directory]::EnumerateFileSystemEntries($path)){$stack.Push($child)}}}
}
function Test-WsmExactMembersSpec($Spec) {
    return ($null -ne $Spec -and $Spec.PSObject.Properties['Adapter'] -and [string]$Spec.Adapter -ceq 'FileScope' -and $Spec.PSObject.Properties['ContentSelection'] -and [string]$Spec.ContentSelection -ceq 'ExactMembers')
}
function Test-WsmPlanHasExactMembers($Plan) {
    foreach($item in @($Plan.Items)){$spec=$null;if($item.PSObject.Properties['MigrationSpec']){$spec=$item.MigrationSpec};if($item.Decision -ceq 'Include' -and (Test-WsmExactMembersSpec $spec)){return $true}}
    return $false
}
function Assert-WsmExactMemberArtifactSet($Item,[string]$ArtifactsPath,[string]$ExpectedHash,$CancellationToken=$null) {
    $expected=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal);foreach($member in @($Item.MigrationSpec.Members)){$expected.Add([string]$member.RelativePath,[string]$member.SHA256)}
    if(-not $expected.Count){throw 'ExactMembers package requires a nonempty sealed member set.'}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal);foreach($row in (Read-WsmArtifactLines $ArtifactsPath $ExpectedHash $CancellationToken | Where-Object ItemId -CEQ $Item.ItemId)){
        if($row.Directory -or -not $expected.ContainsKey([string]$row.RelativePath) -or -not $seen.Add([string]$row.RelativePath)){throw 'ExactMembers package contains a directory, unapproved, or duplicate artifact.'}
        if(-not $row.Data -or [string]$row.Data.Hash -cne $expected[[string]$row.RelativePath]){throw 'ExactMembers package artifact hash differs from its sealed member baseline.'}
    }
    if($seen.Count -ne $expected.Count){throw 'ExactMembers package artifact set does not equal the sealed member set.'}
}
function Get-WsmAvailableBytes([string]$Path) { Get-WsmAssistiveAvailableBytes $Path }
function Get-WsmPackageEstimate {
    param([string]$PlanPath,[string]$ExpectedHash,[string]$OutputDirectory,$CancellationToken=$null)
    $p=Read-WsmMigrationPlan $PlanPath $ExpectedHash; $bytes=[long]0; $count=[long]0; $largest=[long]0
    foreach($i in $p.Items){if((Test-WsmAssistivePackageScope $p $i)){if($p.PSObject.Properties['Assistive']){[void](Assert-WsmAssistiveSourceScope $i.MigrationSpec $p.Assistive.SourcePolicy -Native -ApprovedVolumes $(if($p.Assistive.PSObject.Properties['ApprovedLocalVolumes']){@($p.Assistive.ApprovedLocalVolumes)}else{@()}))};Get-WsmScopeEntries $i.MigrationSpec $OutputDirectory $CancellationToken | ForEach-Object {Assert-WsmCancellationBoundary $CancellationToken 'EstimateFile';$e=$_;[void](Get-WsmFileMetadata $e.SourcePath $i.MigrationSpec.Metadata); if(-not $e.Directory){$length=(New-Object IO.FileInfo($e.SourcePath)).Length; $bytes+=$length; $count++; $largest=[Math]::Max($largest,$length)}}}}
    $indexBudget=[Math]::Max([long]64MB,[long]($count*8192)); $margin=[Math]::Max([long]256MB,[long]($bytes*0.1)); $required=$bytes+$indexBudget+$margin
    [pscustomobject]@{Files=$count; Bytes=$bytes; LargestFile=$largest; PayloadBytesUpperBound=$bytes; IndexBudget=$indexBudget; SafetyMargin=$margin; RequiredFreeBytes=$required; AvailableFreeBytes=(Get-WsmAvailableBytes $OutputDirectory); TargetRequiredBytes=$bytes+$margin; BackupRequiredBytes='Measure existing target scope during restore preview'; DedupEstimate='Conservative: no dedup savings assumed'}
}
function Write-WsmPayloadFile([string]$SourcePath,[string]$BlobDirectory,[int]$ChunkBytes,[int]$BytesPerSecond=0,$CancellationToken=$null) {
    $stream=[IO.File]::Open($SourcePath,'Open','Read','Read'); $chunks=New-Object 'System.Collections.Generic.List[object]'; $sha=[Security.Cryptography.SHA256]::Create(); $watch=[Diagnostics.Stopwatch]::StartNew(); $copied=[long]0
    try{$length=$stream.Length; $buffer=New-Object byte[] $ChunkBytes
        while($true){Assert-WsmCancellationBoundary $CancellationToken 'BeforePayloadChunk';$read=0; while($read -lt $buffer.Length){Assert-WsmCancellationBoundary $CancellationToken 'PayloadReadBuffer';$n=$stream.Read($buffer,$read,[Math]::Min(65536,$buffer.Length-$read));if($n -eq 0){break};$read+=$n};if($read -eq 0){break};[void]$sha.TransformBlock($buffer,0,$read,$buffer,0);$partSha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($partSha.ComputeHash($buffer,0,$read)).Replace('-','').ToLowerInvariant()}finally{$partSha.Dispose()};$blob=Join-Path $BlobDirectory ($hash+'.blob');if([IO.File]::Exists($blob)){if((New-Object IO.FileInfo($blob)).Length -ne $read -or (Get-WsmCancellableFileHash $blob $CancellationToken 'ResumeBlobHashBuffer') -ine $hash){throw 'Resume blob is corrupt.'}}else{$temp=Join-Path $BlobDirectory ([Guid]::NewGuid().ToString('N')+'.partial');try{$output=[IO.File]::Open($temp,'CreateNew','Write','None');try{$output.Write($buffer,0,$read);$output.Flush($true)}finally{$output.Dispose()};[IO.File]::Move($temp,$blob)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}};$chunks.Add([pscustomobject]@{Hash=$hash;Bytes=$read});$copied+=$read;Assert-WsmCancellationBoundary $CancellationToken 'PayloadChunkSealed';if($BytesPerSecond -gt 0){$due=$copied/[double]$BytesPerSecond-$watch.Elapsed.TotalSeconds;while($due -gt 0){Assert-WsmCancellationBoundary $CancellationToken 'PayloadChunkSealedThrottle';Start-Sleep -Milliseconds ([Math]::Min(200,[int]($due*1000)));$due=$copied/[double]$BytesPerSecond-$watch.Elapsed.TotalSeconds}};Write-Progress -Activity 'Hashing and sealing payload' -Status ($copied.ToString()+'/'+$length+' bytes') -PercentComplete ([int](100*$copied/[Math]::Max([long]1,[long]$length)))}
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0);if($stream.Length -ne $length -or $copied -ne $length){throw 'Source changed during payload capture.'};[pscustomobject]@{Bytes=$length;Hash=[BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant();Chunks=$chunks.ToArray()}
    }finally{$stream.Dispose();$sha.Dispose();Write-Progress -Activity 'Hashing and sealing payload' -Completed}
}
function Read-WsmArtifactLines([string]$Path,[string]$ExpectedHash,$CancellationToken=$null) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Trusted artifact index hash required.'};Assert-WsmNoReparse $Path
    $stream=[IO.File]::Open($Path,'Open','Read','Read');$sha=[Security.Cryptography.SHA256]::Create();try{if((Get-WsmCancellableStreamHash $stream $CancellationToken 'ArtifactIndexHashBuffer') -ine $ExpectedHash){throw 'Artifact index changed before use.'}}catch{$stream.Dispose();throw}finally{$sha.Dispose()};$stream.Position=0;$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
    try{Read-WsmBoundedLines $reader | ForEach-Object {Assert-WsmCancellationBoundary $CancellationToken 'ArtifactIndexRow';ConvertFrom-WsmJson $_}}finally{$reader.Dispose();$stream.Dispose()}
}
function Assert-WsmOfflineFullSetManifest($Manifest) {
    if(-not $Manifest.PSObject.Properties['OfflineFullSet']){throw 'OfflineFullSet package envelope is missing its CV2 proof.'}
    $offline=$Manifest.OfflineFullSet
    Assert-WsmFields $offline @('ContractVersion','FullSet','SourceSnapshotHash','ControlIndexHash','ControlCount','ApprovedVolumeBindingsHash','ApprovedRootCoverageHash','CaptureCoverage','CaptureCoverageHash') @('ContractVersion','FullSet','SourceSnapshotHash','ControlIndexHash','ControlCount','ApprovedVolumeBindingsHash','ApprovedRootCoverageHash','CaptureCoverage','CaptureCoverageHash')
    if($Manifest.SchemaVersion -ne 2 -or $offline.ContractVersion -ne 1 -or $offline.FullSet -isnot [bool] -or -not $offline.FullSet -or $Manifest.BaseManifestHash -or $offline.SourceSnapshotHash -notmatch '^[a-f0-9]{64}$' -or $offline.ControlIndexHash -notmatch '^[a-f0-9]{64}$' -or $offline.ApprovedVolumeBindingsHash -notmatch '^[a-f0-9]{64}$' -or $offline.ApprovedRootCoverageHash -notmatch '^[a-f0-9]{64}$' -or $offline.CaptureCoverageHash -ine (Get-WsmHashText (ConvertTo-Json -InputObject @($offline.CaptureCoverage) -Depth 30 -Compress)) -or $offline.CaptureCoverage -isnot [array] -or ($offline.ControlCount -isnot [int] -and $offline.ControlCount -isnot [long]) -or $offline.ControlCount -lt 1 -or $offline.ControlCount -gt 10000){throw 'Invalid OfflineFullSet package envelope; CV2 requires a bounded complete full set with portable controls and no base.'}
    $true
}

function Assert-WsmOfflineFullSetCoverage($Plan,$ApprovalCoverage,$CaptureCoverage) {
    $scopeItems=@($Plan.Items | Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec.Adapter -ceq 'FileScope'})
    if($ApprovalCoverage -isnot [array] -or $CaptureCoverage -isnot [array] -or $ApprovalCoverage.Count -ne $scopeItems.Count -or $CaptureCoverage.Count -ne $scopeItems.Count){throw 'OfflineFullSet installed-root coverage must contain one approval and capture result per included FileScope.'}
    $expected=@{};foreach($item in $scopeItems){if($expected.ContainsKey([string]$item.ItemId)){throw 'OfflineFullSet plan repeats a FileScope coverage identity.'};$expected[[string]$item.ItemId]=$true}
    foreach($set in @(@{Rows=$ApprovalCoverage;Label='approval'},@{Rows=$CaptureCoverage;Label='capture'})){
        $seen=@{}
        foreach($row in $set.Rows){
            Assert-WsmFields $row @('ItemId','Status','RootsChecked','SourceInventoryHash','Diagnostics') @('ItemId','Status','RootsChecked','SourceInventoryHash','Diagnostics')
            $id=[string]$row.ItemId
            if(-not $expected.ContainsKey($id) -or $seen.ContainsKey($id) -or [string]::IsNullOrWhiteSpace([string]$row.Status) -or ($row.RootsChecked -isnot [int] -and $row.RootsChecked -isnot [long]) -or $row.RootsChecked -lt 0 -or [string]$row.SourceInventoryHash -notmatch '^[a-f0-9]{64}$' -or $row.Diagnostics -isnot [array]){throw ('OfflineFullSet '+$set.Label+' installed-root coverage is malformed, stale, duplicated or incomplete.')}
            if($set.Label -ceq 'approval' -and [string]$row.SourceInventoryHash -ine [string]$Plan.Assistive.SourceSnapshotHash){throw 'OfflineFullSet approval coverage is not bound to the approved source snapshot.'}
            $seen[$id]=$true
        }
        if($seen.Count -ne $expected.Count){throw ('OfflineFullSet '+$set.Label+' installed-root coverage omits an included FileScope.')}
    }
    $true
}

function Write-WsmOfflineFullSetControls($Plan,[string]$SourceWorkspace,[string]$PackageRoot) {
    if(-not $Plan.PSObject.Properties['Assistive'] -or $Plan.Assistive.ContractVersion -ne 2){return $null}
    if(@($Plan.Assistive.MaterialReferences).Count -gt 9999){throw 'OfflineFullSet supports at most 9,999 portable material files.'}
    $controls=Join-Path $PackageRoot 'controls';[void][IO.Directory]::CreateDirectory($controls);Assert-WsmNoReparse $controls
    $snapshotRef=$Plan.Assistive.DiscoveryAuthority.SourceSnapshotReference
    $sourceRoot=[IO.Path]::GetFullPath($SourceWorkspace).TrimEnd('\')+'\'
    $snapshotPath=[IO.Path]::GetFullPath((Join-Path $SourceWorkspace ([string]$snapshotRef.Reference).Replace('/','\')))
    if(-not $snapshotPath.StartsWith($sourceRoot,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($snapshotPath)){throw 'OfflineFullSet source snapshot is missing or outside the approved source workspace.'}
    Assert-WsmNoReparse $snapshotPath
    if((Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash -ine [string]$Plan.Assistive.SourceSnapshotHash){throw 'OfflineFullSet source snapshot changed after approval.'}
    $inventoryPath=Join-Path $controls 'source-inventory.json';[IO.File]::Copy($snapshotPath,$inventoryPath,$false)
    $rows=New-Object 'System.Collections.Generic.List[object]';$inventoryBytes=(New-Object IO.FileInfo($inventoryPath)).Length
    $rows.Add([pscustomobject][ordered]@{Name='controls/source-inventory.json';Kind='SourceInventory';Reference=[string]$snapshotRef.Reference;Bytes=[long]$inventoryBytes;SHA256=[string]$Plan.Assistive.SourceSnapshotHash})
    $index=0
    foreach($reference in @($Plan.Assistive.MaterialReferences)){
        $index++;$path=[IO.Path]::GetFullPath((Join-Path $SourceWorkspace ([string]$reference.Reference).Replace('/','\')))
        if(-not $path.StartsWith($sourceRoot,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($path)){throw 'OfflineFullSet mandatory source control material is missing or outside the approved source workspace.'}
        Assert-WsmNoReparse $path
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$reference.SHA256){throw 'OfflineFullSet mandatory source control material changed after approval.'}
        $name='controls/material-'+$index.ToString('0000')+'-'+([string]$reference.SHA256).ToLowerInvariant()+'.bin';$destination=Join-Path $PackageRoot $name.Replace('/','\');$parent=[IO.Path]::GetDirectoryName($destination);if(-not [IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent)};Assert-WsmNoReparse $parent;[IO.File]::Copy($path,$destination,$false)
        $rows.Add([pscustomobject][ordered]@{Name=$name;Kind='AssistiveMaterial';Reference=[string]$reference.Reference;Bytes=[long](New-Object IO.FileInfo($destination)).Length;SHA256=([string]$reference.SHA256).ToLowerInvariant()})
    }
    $indexDoc=[pscustomobject][ordered]@{SchemaVersion=1;Kind='OfflineFullSetControls';SourceSnapshotHash=[string]$Plan.Assistive.SourceSnapshotHash;SourceInventoryHash=[string]$Plan.Assistive.SourceSnapshotHash;Controls=$rows.ToArray()}
    $indexPath=Join-Path $controls 'index.json';Write-WsmJson $indexPath $indexDoc
    [pscustomobject]@{IndexPath=$indexPath;IndexHash=(Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash.ToLowerInvariant();Count=$rows.Count;Rows=$rows.ToArray()}
}

function Assert-WsmOfflineFullSetControls($PackageRoot,$Manifest,$Plan) {
    if(-not $Plan.PSObject.Properties['Assistive'] -or $Plan.Assistive.ContractVersion -ne 2){if($Manifest.SchemaVersion -eq 2 -or $Manifest.PSObject.Properties['OfflineFullSet']){throw 'OfflineFullSet package requires a CV2 plan.'};return $null}
    Assert-WsmOfflineFullSetManifest $Manifest | Out-Null
    [void](Assert-WsmOfflineFullSetCoverage $Plan @($Plan.Assistive.ApprovedRootCoverage) @($Manifest.OfflineFullSet.CaptureCoverage))
    if($Manifest.OfflineFullSet.SourceSnapshotHash -ine $Plan.Assistive.SourceSnapshotHash -or $Manifest.OfflineFullSet.ApprovedVolumeBindingsHash -ine (Get-WsmHashText (ConvertTo-Json -InputObject @($Plan.Assistive.ApprovedLocalVolumes) -Depth 20 -Compress)) -or $Manifest.OfflineFullSet.ApprovedRootCoverageHash -ine (Get-WsmHashText (ConvertTo-Json -InputObject @($Plan.Assistive.ApprovedRootCoverage) -Depth 20 -Compress))){throw 'OfflineFullSet manifest does not bind the sealed source snapshot, local volumes, or approval coverage.'}
    if(@($Plan.Assistive.MaterialReferences).Count -gt 9999){throw 'OfflineFullSet supports at most 9,999 portable material files.'}
    $controlRoot=Join-Path $PackageRoot 'controls';Assert-WsmNoReparse $controlRoot
    $indexPath=Join-Path $PackageRoot 'controls/index.json';Assert-WsmNoReparse $indexPath
    if((Get-FileHash -LiteralPath $indexPath -Algorithm SHA256).Hash -ine $Manifest.OfflineFullSet.ControlIndexHash){throw 'OfflineFullSet control index hash mismatch.'}
    if((New-Object IO.FileInfo($indexPath)).Length -gt 8388608){throw 'OfflineFullSet control index exceeds its bounded 8 MiB metadata limit.'}
    $index=Read-WsmJson $indexPath;Assert-WsmFields $index @('SchemaVersion','Kind','SourceSnapshotHash','SourceInventoryHash','Controls') @('SchemaVersion','Kind','SourceSnapshotHash','SourceInventoryHash','Controls')
    if($index.SchemaVersion -ne 1 -or $index.Kind -cne 'OfflineFullSetControls' -or $index.SourceSnapshotHash -ine $Plan.Assistive.SourceSnapshotHash -or $index.SourceInventoryHash -ine $Plan.Assistive.SourceSnapshotHash -or $index.Controls -isnot [array] -or $index.Controls.Count -ne $Manifest.OfflineFullSet.ControlCount -or $index.Controls.Count -gt 10000){throw 'OfflineFullSet control index is incomplete, oversized or bound to another source snapshot.'}
    $lookup=@{};$sourceCount=0;$seenReferences=@{};$controlBytes=[long]0
    foreach($row in $index.Controls){
        Assert-WsmFields $row @('Name','Kind','Reference','Bytes','SHA256') @('Name','Kind','Reference','Bytes','SHA256')
        if($row.Name -notmatch '^controls/(?:source-inventory\.json|material-\d{4}-[a-f0-9]{64}\.bin)$' -or $lookup.ContainsKey([string]$row.Name) -or [string]$row.Reference -match '(^|[\\/])\.\.(?:[\\/]|$)' -or [IO.Path]::IsPathRooted([string]$row.Reference) -or $row.SHA256 -notmatch '^[a-f0-9]{64}$' -or ($row.Bytes -isnot [int] -and $row.Bytes -isnot [long]) -or $row.Bytes -lt 0){throw 'OfflineFullSet control row has an unsafe name/reference or invalid size/hash.'}
        $isInventory=([string]$row.Name -ceq 'controls/source-inventory.json')
        if($isInventory){$sourceCount++;if([string]$row.Kind -cne 'SourceInventory' -or [string]$row.Reference -cne [string]$Plan.Assistive.DiscoveryAuthority.SourceSnapshotReference.Reference -or [string]$row.SHA256 -ine [string]$Plan.Assistive.SourceSnapshotHash){throw 'OfflineFullSet source inventory control does not match its sealed kind, reference and hash.'}}
        elseif([string]$row.Kind -cne 'AssistiveMaterial' -or [string]$row.Name -notmatch ('^controls/material-\d{4}-'+[string]$row.SHA256+'\.bin$')){throw 'OfflineFullSet material control kind/name/hash relationship is invalid.'}
        $controlBytes += [long]$row.Bytes;if($controlBytes -gt 134217728){throw 'OfflineFullSet portable controls exceed the aggregate 128 MiB metadata budget.'}
        $lookup[[string]$row.Name]=$row
        if($seenReferences.ContainsKey([string]$row.Reference)){throw 'OfflineFullSet control references contain duplicates.'};$seenReferences[[string]$row.Reference]=$true
        $path=Join-Path $PackageRoot ([string]$row.Name).Replace('/','\');Assert-WsmNoReparse $path
        if(-not [IO.File]::Exists($path) -or (New-Object IO.FileInfo($path)).Length -ne [long]$row.Bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$row.SHA256){throw 'OfflineFullSet control material is missing or changed.'}
    }
    if($sourceCount -ne 1 -or -not $lookup.ContainsKey('controls/source-inventory.json') -or $lookup.Count -ne ($Plan.Assistive.MaterialReferences.Count+1)){throw 'OfflineFullSet control material set does not exactly cover the source inventory and mandatory materials.'}
    $materialIndex=0;foreach($reference in @($Plan.Assistive.MaterialReferences)){$materialIndex++;$row=@($index.Controls | Where-Object Reference -CEQ $reference.Reference);$expectedName='controls/material-'+$materialIndex.ToString('0000')+'-'+([string]$reference.SHA256).ToLowerInvariant()+'.bin';if($row.Count -ne 1 -or $row[0].Kind -cne 'AssistiveMaterial' -or $row[0].SHA256 -ine $reference.SHA256 -or $row[0].Name -cne $expectedName){throw 'OfflineFullSet mandatory material name/reference/hash differs from the sealed plan.'}}
    $inventoryPath=Join-Path $PackageRoot 'controls/source-inventory.json';$inventory=Read-WsmJson $inventoryPath;Assert-WsmInventory $inventory
    if($inventory.Source.HostId -cne $Plan.Source.HostId -or $inventory.Source.Fingerprint -ine $Plan.Source.Fingerprint -or $inventory.Revision -ne $Plan.InventoryRevision -or (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash -ine $Plan.Assistive.SourceSnapshotHash){throw 'OfflineFullSet portable source inventory does not match its sealed source identity and revision.'}
    $snapshotVolumes=@{};foreach($item in @($inventory.Items | Where-Object {$_.Category -ceq 'Storage' -and $_.Kind -ceq 'Volume'})){$snapshotVolumes[[string]$item.Settings.DeviceID]=$item}
    foreach($approved in @($Plan.Assistive.ApprovedLocalVolumes)){if(-not $snapshotVolumes.ContainsKey([string]$approved.DeviceID) -or ([string]$snapshotVolumes[[string]$approved.DeviceID].Settings.DriveLetter).TrimEnd('\') -ine [string]$approved.DriveLetter){throw 'OfflineFullSet approved volume is not present in the portable trusted source inventory.'}}
    $actual=New-Object 'System.Collections.Generic.List[string]'
    $entryCount=0;foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($controlRoot)){$entryCount++;if($entryCount -gt 10002){throw 'OfflineFullSet control directory exceeds its bounded entry count.'};$attributes=[IO.File]::GetAttributes($entryPath);if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attributes -band [IO.FileAttributes]::Directory) -ne 0){throw 'OfflineFullSet control directory contains a reparse point or unsupported nested directory.'};$actual.Add(('controls/'+[IO.Path]::GetFileName($entryPath)))}
    $expected=New-Object 'System.Collections.Generic.List[string]';$expected.Add('controls/index.json');foreach($row in $index.Controls){$expected.Add([string]$row.Name)}
    if((@($actual|Sort-Object -CaseSensitive)-join "`n") -cne (@($expected|Sort-Object -CaseSensitive)-join "`n")){throw 'OfflineFullSet control directory has missing or unlisted files.'}
    $index
}
function Export-WsmMigrationPackage {
    [CmdletBinding()]param([string]$PlanPath,[string]$ExpectedHash,[string]$SourceStateDirectory,[string]$OutputDirectory,[ValidateRange(65536,67108864)][int]$ChunkBytes=67108864,[ValidateRange(0,1073741824)][int]$BytesPerSecond=0,[string]$BaseManifestPath,[string]$BaseManifestHash,[string]$FreezePath,[string]$FreezeHash,[string]$FreezeExternalEvidencePath,[string]$FreezeExternalEvidenceHash,$CancellationToken=$null)
    $job=$null;$result=$null;$succeeded=$false
    $preflightPlan=Read-WsmMigrationPlan $PlanPath $ExpectedHash;if($preflightPlan.PSObject.Properties['Assistive'] -and $preflightPlan.Assistive.ContractVersion -eq 2 -and ($BaseManifestPath -or $BaseManifestHash)){throw 'OfflineFullSet CV2 requires a complete generation and rejects external delta bases.'}
    try{$job=Start-WsmAssistiveSourcePackageJob $PlanPath $ExpectedHash $SourceStateDirectory $BaseManifestPath $BaseManifestHash;$result=Export-WsmMigrationPackageCore @PSBoundParameters;$succeeded=$true;$result}catch [OperationCanceledException]{
        if($CancellationToken){$token=ConvertTo-WsmCancellationTokenObject $CancellationToken;$record=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='CancellationResult';PairId=$token.PairId;PlanHash=$token.PlanHash;OperationId=$token.OperationId;Status='Cancelled';Boundary=[string]$_.Exception.Data['CancellationBoundary'];Utc=(Get-WsmUtc);EffectsRetained=$true;NextAction='Inspect unsealed package and retained chunks; retry with a new operation token after review';ProductionVerified=$false};$root=Join-Path $token.StateDirectory $token.PairId;Assert-WsmNoReparse $root;Write-WsmJson (Join-Path $root ('cancel-result-'+$token.OperationId+'.json')) $record}
        throw
    }finally{Complete-WsmAssistiveSourcePackageJob $job $result $succeeded}
}
function Export-WsmMigrationPackageCore {
    [CmdletBinding()] param([string]$PlanPath,[string]$ExpectedHash,[string]$SourceStateDirectory,[string]$OutputDirectory,[ValidateRange(65536,67108864)][int]$ChunkBytes=67108864,[ValidateRange(0,1073741824)][int]$BytesPerSecond=0,[string]$BaseManifestPath,[string]$BaseManifestHash,[string]$FreezePath,[string]$FreezeHash,[string]$FreezeExternalEvidencePath,[string]$FreezeExternalEvidenceHash,$CancellationToken=$null)
    $plan=Read-WsmMigrationPlan $PlanPath $ExpectedHash;if($BaseManifestPath -and (Test-WsmPlanHasExactMembers $plan)){throw 'ExactMembers delta packaging is not supported; use a complete full generation until the member-set base chain is implemented.'};Assert-WsmMigrationHost (Get-WsmMachineIdentity) $plan.Source.Fingerprint
    $sourceProofs=@();if($plan.PSObject.Properties['Assistive']){
        $approvedVolumes=@();if($plan.Assistive.PSObject.Properties['ApprovedLocalVolumes']){$approvedVolumes=@($plan.Assistive.ApprovedLocalVolumes)}
        $sourceProofs=@(foreach($scope in $plan.Items){
            if($scope.Decision -eq 'Include' -and $scope.MigrationSpec.Adapter -eq 'FileScope'){
                $proof=Assert-WsmAssistiveSourceScope $scope.MigrationSpec $plan.Assistive.SourcePolicy -Native -ApprovedVolumes $approvedVolumes
                $row=[ordered]@{ItemId=$scope.ItemId;Channel=$proof.Channel;PhysicalPath=$proof.PhysicalPath;SourceCPhysicalRoot=$proof.SourceCPhysicalRoot;SourceFingerprint=$plan.Source.Fingerprint;NativeVerified=$true}
                if($plan.Assistive.ContractVersion -eq 2){$row.VolumeDeviceID=$proof.VolumeDeviceID;$row.PhysicalVolumeRoot=$proof.PhysicalVolumeRoot}
                [pscustomobject]$row
            }
        })
    }
    if($CancellationToken){[void](Assert-WsmCancellationTokenBinding $CancellationToken $plan.PairId $ExpectedHash '' $SourceStateDirectory);Assert-WsmCancellationBoundary $CancellationToken 'BeforeSourceInventory'}
    Assert-WsmSourceWorkspaceSeparation $plan $SourceStateDirectory
    Assert-WsmSourceWorkspaceSeparation $plan $OutputDirectory
    # Refresh the real local collector before any payload work; revision alone is not a configuration check.
    $freshResult=Export-WsmInventory $SourceStateDirectory -DeepDiscovery:($plan.Source.PSObject.Properties['DiscoveryDepth'] -and $plan.Source.DiscoveryDepth -eq 'Deep') -IncludeSoftwareCatalog; $fresh=Read-WsmTrustedJson $freshResult.Path $freshResult.SHA256; $current=@{};foreach($i in $fresh.Items){$current[$i.ItemId]=$i}
    if($fresh.Source.HostId -cne $plan.Source.HostId){throw 'Fresh inventory source identity mismatch.'}
    $softwareScopeCoverage=@(foreach($scopeItem in @($plan.Items | Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec.Adapter -ceq 'FileScope'})){
        Assert-WsmCancellationBoundary $CancellationToken 'BeforeInstalledSoftwareScopeCheck'
        $scopeCheck=Assert-WsmFileScopeInstalledRoots -Spec $scopeItem.MigrationSpec -SourceInventory $fresh -NativeSource
        [pscustomobject]@{ItemId=[string]$scopeItem.ItemId;Status=[string]$scopeCheck.Status;RootsChecked=[int]$scopeCheck.RootsChecked;SourceInventoryHash=[string]$freshResult.SHA256;Diagnostics=@($scopeCheck.Diagnostics)}
    })
    if($plan.PSObject.Properties['Assistive'] -and $plan.Assistive.ContractVersion -eq 2){[void](Assert-WsmOfflineFullSetCoverage $plan @($plan.Assistive.ApprovedRootCoverage) @($softwareScopeCoverage))}
    $base=$null;$generation=1;$freeze=$null
    if($plan.PSObject.Properties['Assistive'] -and $plan.Assistive.ContractVersion -eq 2 -and ($BaseManifestPath -or $BaseManifestHash)){throw 'OfflineFullSet CV2 requires a full package generation; delta bases are unsupported.'}
    if($BaseManifestPath){$base=Read-WsmTrustedJson $BaseManifestPath $BaseManifestHash;Assert-WsmEnvelope $base 'MigrationPackage';if($base.PairId -cne $plan.PairId -or $base.PlanHash -ine $ExpectedHash){throw 'Delta base plan/pair mismatch.'};$generation=$base.Generation+1}
    $needsFreeze=@($plan.Items | Where-Object {$_.Decision -eq 'Include' -and $_.MigrationSpec.Adapter -eq 'FileScope' -and $_.MigrationSpec.Consistency -ne 'Immutable'}).Count -gt 0
    if($FreezePath){if(-not $FreezeExternalEvidencePath -or -not $FreezeExternalEvidenceHash){throw 'Final package export requires the original typed SourceFreezeReady JSON/hash for source-side revalidation.'};$freeze=Read-WsmFreezeRecord $FreezePath $FreezeHash $plan $ExpectedHash;if(-not $freeze){throw 'Invalid freeze record.'};$sourceFreezeProof=Assert-WsmSourceFreezeEvidence $FreezeExternalEvidencePath $FreezeExternalEvidenceHash $plan $ExpectedHash $freeze.FreezeEpoch;Assert-WsmSourceFreezeEvidenceMatchesAttestation $sourceFreezeProof $freeze}elseif($base -or $needsFreeze){throw 'Final delta and mutable scopes require independent source freeze evidence.'}
    foreach($i in $plan.Items){if($i.Decision -eq 'Include' -and $i.Kind -ne 'ManualItem'){$expectedSettings=$i.SettingsHash;if($freeze){$q=@($freeze.QuiescedSettingsHashes | Where-Object ItemId -CEQ $i.ItemId);if($q.Count -ne 1 -or $q[0].OriginalHash -cne $i.SettingsHash){throw 'Freeze configuration baseline mismatch.'};$expectedSettings=$q[0].QuiescedHash};if(-not $current.ContainsKey($i.ItemId) -or $current[$i.ItemId].SettingsHash -cne $expectedSettings){throw ('Configuration drift requires review: '+$i.ItemId)}}}
    if(-not [IO.Directory]::Exists($OutputDirectory)){[void][IO.Directory]::CreateDirectory($OutputDirectory);Protect-WsmDirectory $OutputDirectory};Assert-WsmNoReparse $OutputDirectory
    Invoke-WsmLocked $OutputDirectory {
        $estimate=Get-WsmPackageEstimate $PlanPath $ExpectedHash $OutputDirectory $CancellationToken;if($estimate.RequiredFreeBytes -gt $estimate.AvailableFreeBytes){throw 'Insufficient package workspace capacity; no package sealed.'}
        if($FreezePath){$lockedFreeze=Read-WsmFreezeRecord $FreezePath $FreezeHash $plan $ExpectedHash;$lockedProof=Assert-WsmSourceFreezeEvidence $FreezeExternalEvidencePath $FreezeExternalEvidenceHash $plan $ExpectedHash $lockedFreeze.FreezeEpoch;Assert-WsmSourceFreezeEvidenceMatchesAttestation $lockedProof $lockedFreeze;$freeze=$lockedFreeze}
        $root=Join-Path $OutputDirectory ($plan.PairId+'-g'+$generation);if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root};Assert-WsmNoReparse $root
        $manifestPath=Join-Path $root 'manifest.json';if([IO.File]::Exists($manifestPath)){throw 'Generation already sealed; use a new generation rather than overwrite evidence.'}
        $blobs=Join-Path $root 'payload';[void][IO.Directory]::CreateDirectory($blobs);Assert-WsmNoReparse $blobs
        $resumePath=Join-Path $root 'export-state.json';if([IO.File]::Exists($resumePath)){$resume=Read-WsmJson $resumePath;if($resume.PlanHash -ine $ExpectedHash -or $resume.ChunkBytes -ne $ChunkBytes){throw 'Resume plan/chunk format mismatch.'}}else{Write-WsmJson $resumePath ([pscustomobject]@{PlanHash=$ExpectedHash;ChunkBytes=$ChunkBytes;Generation=$generation;StartedUtc=(Get-WsmUtc)})}
        $indexTemp=Join-Path $root 'artifacts.jsonl.partial';$writer=New-Object IO.StreamWriter($indexTemp,$false,(New-Object Text.UTF8Encoding($false)));$files=[long]0;$bytes=[long]0;$records=[long]0
        try{foreach($item in $plan.Items){if($item.Decision -ne 'Include'){continue};$spec=$item.MigrationSpec
            if($spec.Adapter -eq 'FileScope' -and (Test-WsmAssistivePackageScope $plan $item)){Get-WsmScopeEntries $spec $root $CancellationToken | ForEach-Object {Assert-WsmCancellationBoundary $CancellationToken 'BeforeArtifactCapture';$e=$_;$metadata=Get-WsmFileMetadata $e.SourcePath $spec.Metadata;$data=$null;if(-not $e.Directory){$data=Write-WsmPayloadFile $e.SourcePath $blobs $ChunkBytes $BytesPerSecond $CancellationToken;$files++;$bytes+=$data.Bytes};$row=[pscustomobject]@{ItemId=$item.ItemId;RelativePath=$e.RelativePath;Directory=$e.Directory;Metadata=$metadata;Data=$data};$line=$row | ConvertTo-Json -Compress -Depth 20;if($line.Length -gt 1MB){throw 'Artifact row exceeds supported size; increase chunk size or use dedicated large-file adapter.'};$writer.WriteLine($line);$writer.Flush();$records++}}
            elseif($spec.Adapter -eq 'Certificate'){$d=$spec.Desired;Assert-WsmNoReparse $d.ArtifactPath;if((Get-FileHash -LiteralPath $d.ArtifactPath).Hash -ine $d.ArtifactHash){throw 'Independent certificate artifact changed.'};$data=Write-WsmPayloadFile $d.ArtifactPath $blobs $ChunkBytes $BytesPerSecond $CancellationToken;$row=[pscustomobject]@{ItemId=$item.ItemId;RelativePath='certificate-artifact';Directory=$false;Metadata=$null;Data=$data};$writer.WriteLine(($row | ConvertTo-Json -Compress -Depth 20));$files++;$bytes+=$data.Bytes;$records++}
        }}finally{$writer.Dispose()}
        Assert-WsmCancellationBoundary $CancellationToken 'BeforePackageSeal'
        $indexPath=Join-Path $root 'artifacts.jsonl';if([IO.File]::Exists($indexPath)){[IO.File]::Delete($indexPath)};[IO.File]::Move($indexTemp,$indexPath)
        $planCopy=Join-Path $root 'plan.json';[IO.File]::Copy($PlanPath,$planCopy,$true);if((Get-FileHash -LiteralPath $planCopy).Hash -ine $ExpectedHash){throw 'Plan changed during export.'}
        $schemaVersion=1;$offlineEnvelope=$null;if($plan.PSObject.Properties['Assistive'] -and $plan.Assistive.ContractVersion -eq 2){$schemaVersion=2;$controlExport=Write-WsmOfflineFullSetControls $plan $SourceStateDirectory $root;$offlineEnvelope=[pscustomobject][ordered]@{ContractVersion=1;FullSet=$true;SourceSnapshotHash=[string]$plan.Assistive.SourceSnapshotHash;ControlIndexHash=[string]$controlExport.IndexHash;ControlCount=[int]$controlExport.Count;ApprovedVolumeBindingsHash=(Get-WsmHashText (ConvertTo-Json -InputObject @($plan.Assistive.ApprovedLocalVolumes) -Depth 20 -Compress));ApprovedRootCoverageHash=(Get-WsmHashText (ConvertTo-Json -InputObject @($plan.Assistive.ApprovedRootCoverage) -Depth 20 -Compress));CaptureCoverage=@($softwareScopeCoverage);CaptureCoverageHash=(Get-WsmHashText (ConvertTo-Json -InputObject @($softwareScopeCoverage) -Depth 30 -Compress))}}
        $manifest=[pscustomobject][ordered]@{SchemaVersion=$schemaVersion;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString();BatchId=$plan.BatchId;PairId=$plan.PairId;ApprovalId=$plan.ApprovalId;PlanHash=$ExpectedHash.ToLowerInvariant();Source=$plan.Source;Target=$plan.Target;InventoryRevision=$plan.InventoryRevision;DecisionRevision=$plan.DecisionRevision;Generation=$generation;BaseManifestHash=$BaseManifestHash;Final=($null -ne $freeze);FreezeHash=$FreezeHash;ArtifactsHash=(Get-FileHash -LiteralPath $indexPath).Hash.ToLowerInvariant();Files=$files;Bytes=$bytes;Records=$records;ChunkBytes=$ChunkBytes;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot'}
        if($plan.PSObject.Properties['Assistive']){$manifest | Add-Member NoteProperty SourceCollectionProofs $sourceProofs};if($offlineEnvelope){$manifest | Add-Member NoteProperty OfflineFullSet $offlineEnvelope}
        if($freeze){Write-WsmJson (Join-Path $root 'freeze.json') $freeze; $manifest.FreezeHash=(Get-FileHash -LiteralPath (Join-Path $root 'freeze.json')).Hash.ToLowerInvariant()}
        $candidate=Join-Path $root 'manifest.pending.json';Write-WsmJson $candidate $manifest;$hash=(Get-FileHash -LiteralPath $candidate).Hash
        Test-WsmMigrationPackage $candidate $hash $CancellationToken | Out-Null
        [IO.File]::Move($candidate,$manifestPath)
        [pscustomobject]@{Directory=$root;ManifestPath=$manifestPath;SHA256=$hash;Generation=$generation;Files=$files;Bytes=$bytes;Sealed=$true;Final=$manifest.Final;SoftwareScopeCoverage=$softwareScopeCoverage;ProductionVerified=$false}
    }
}
function Assert-WsmArtifactRecord($Row,$Item) {
    if($Row.Directory -isnot [bool] -or $Item.MigrationSpec.Adapter -notin @('FileScope','Certificate')){throw 'Artifact type/adapter is not a selected payload contract.'}
    if($Item.MigrationSpec.Adapter -eq 'Certificate'){if($Row.Directory -or $Row.RelativePath -cne 'certificate-artifact' -or $null -ne $Row.Metadata){throw 'Certificate artifact identity/type differs from contract.'}}
    else{
        Assert-WsmFields $Row.Metadata @('Sddl','MetadataMode','Attributes','CreationUtc','LastWriteUtc') @('Sddl','MetadataMode','Attributes','CreationUtc','LastWriteUtc')
        if($Row.Metadata.MetadataMode -cne $Item.MigrationSpec.Metadata -or ($Row.Metadata.Attributes -isnot [int] -and $Row.Metadata.Attributes -isnot [long]) -or [long]$Row.Metadata.Attributes -lt 0 -or [long]$Row.Metadata.Attributes -gt [int]::MaxValue -or [bool]([int]$Row.Metadata.Attributes -band [int][IO.FileAttributes]::Directory) -ne $Row.Directory){throw 'Artifact metadata mode/attributes differ from contract.'}
        [void](New-Object Security.AccessControl.RawSecurityDescriptor($Row.Metadata.Sddl))
        foreach($field in @('CreationUtc','LastWriteUtc')){$stamp=[DateTimeOffset]::MinValue;if([string]$Row.Metadata.$field -notmatch '(?:Z|[+]00:00)$' -or -not [DateTimeOffset]::TryParse([string]$Row.Metadata.$field,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$stamp) -or $stamp.Offset -ne [TimeSpan]::Zero -or $stamp.Year -lt 1601){throw 'Artifact file timestamp is not supported UTC.'}}
    }
    if($Row.Directory){if($null -ne $Row.Data){throw 'Directory artifact cannot carry file bytes.'}}
    else{Assert-WsmFields $Row.Data @('Bytes','Hash','Chunks') @('Bytes','Hash','Chunks');if(($Row.Data.Bytes -isnot [int] -and $Row.Data.Bytes -isnot [long]) -or [long]$Row.Data.Bytes -lt 0 -or $Row.Data.Hash -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid file byte/hash contract.'};foreach($part in $Row.Data.Chunks){Assert-WsmFields $part @('Hash','Bytes') @('Hash','Bytes')}}
}
function Assert-WsmPackageHeaderContract($Manifest) {
    Assert-WsmFields $Manifest @('SchemaVersion','ToolVersion','Kind','PackageId','BatchId','PairId','ApprovalId','PlanHash','Source','Target','InventoryRevision','DecisionRevision','Generation','BaseManifestHash','Final','FreezeHash','ArtifactsHash','Files','Bytes','Records','ChunkBytes','SealedUtc','Mode','SourceCollectionProofs','OfflineFullSet') @('SchemaVersion','ToolVersion','Kind','PackageId','BatchId','PairId','ApprovalId','PlanHash','Source','Target','InventoryRevision','DecisionRevision','Generation','BaseManifestHash','Final','FreezeHash','ArtifactsHash','Files','Bytes','Records','ChunkBytes','Mode')
    Assert-WsmEnvelope $Manifest 'MigrationPackage'
    foreach($id in @($Manifest.PackageId,$Manifest.BatchId,$Manifest.PairId,$Manifest.ApprovalId,$Manifest.Source.HostId,$Manifest.Target.HostId)){Assert-WsmId $id}
    foreach($field in @('Generation','Files','Bytes','Records','ChunkBytes','InventoryRevision','DecisionRevision')){if($Manifest.$field -isnot [int] -and $Manifest.$field -isnot [long]){throw (New-WsmContractError ('Package '+$field+' must be an integer.'))}}
    if($Manifest.Generation -lt 1 -or $Manifest.Files -lt 0 -or $Manifest.Bytes -lt 0 -or $Manifest.Records -lt 0 -or $Manifest.ChunkBytes -lt 65536 -or $Manifest.ChunkBytes -gt 67108864 -or $Manifest.Final -isnot [bool] -or $Manifest.Mode -cne 'IsolatedPilot' -or $Manifest.PlanHash -cnotmatch '^[a-f0-9]{64}$' -or $Manifest.ArtifactsHash -cnotmatch '^[a-f0-9]{64}$'){throw (New-WsmContractError 'Invalid package generation, counts, chunk bounds, final marker or mode/hash contract.')}
}
function Test-WsmMigrationPackage {
    param([string]$ManifestPath,[string]$ExpectedHash,$CancellationToken=$null)
    $m=Read-WsmTrustedJson $ManifestPath $ExpectedHash;Assert-WsmEnvelope $m 'MigrationPackage';$root=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ManifestPath));Assert-WsmNoReparse $root
    Assert-WsmPackageHeaderContract $m
    $plan=Read-WsmMigrationPlan (Join-Path $root 'plan.json') $m.PlanHash;if($plan.PairId -cne $m.PairId -or $plan.BatchId -cne $m.BatchId -or $plan.ApprovalId -cne $m.ApprovalId -or $plan.Source.HostId -cne $m.Source.HostId -or $plan.Target.HostId -cne $m.Target.HostId -or $plan.Source.Fingerprint -cne $m.Source.Fingerprint -or $plan.Target.Fingerprint -cne $m.Target.Fingerprint -or $plan.DecisionRevision -ne $m.DecisionRevision -or $plan.InventoryRevision -ne $m.InventoryRevision){throw 'Package plan binding mismatch.'};if($m.BaseManifestHash -and (Test-WsmPlanHasExactMembers $plan)){throw 'ExactMembers reader does not accept delta/base-linked packages until member-set base validation is implemented.'}
    Assert-WsmAssistiveCollectionProofs $m $plan
    [void](Assert-WsmOfflineFullSetControls $root $m $plan)
    if($CancellationToken){$token=ConvertTo-WsmCancellationTokenObject $CancellationToken;$tokenManifest=$ExpectedHash;if(-not $token.ManifestHash){$tokenManifest=''};[void](Assert-WsmCancellationTokenBinding $token $m.PairId $m.PlanHash $tokenManifest $token.StateDirectory);Assert-WsmCancellationBoundary $token 'BeforePackageArtifacts'}
    $index=Join-Path $root 'artifacts.jsonl';Assert-WsmNoReparse $index;if((Get-WsmCancellableFileHash $index $CancellationToken 'PackageIndexHashBuffer') -ine $m.ArtifactsHash){throw 'Artifact index hash mismatch.'}
    $included=@{};foreach($i in $plan.Items){if($i.Decision -eq 'Include'){$included[$i.ItemId]=$i}};$seenItems=@{};$files=[long]0;$bytes=[long]0;$records=[long]0
    $keySpool=New-WsmArtifactKeySpool;try{Read-WsmArtifactLines $index $m.ArtifactsHash $CancellationToken | ForEach-Object {Assert-WsmCancellationBoundary $CancellationToken 'PackageArtifactVerified';$row=$_;Assert-WsmFields $row @('ItemId','RelativePath','Directory','Metadata','Data') @('ItemId','RelativePath','Directory','Metadata','Data');if(-not $included.ContainsKey($row.ItemId)){throw 'Artifact belongs to excluded/unknown item.'};if($plan.PSObject.Properties['Assistive'] -and $included[$row.ItemId].MigrationSpec.Adapter -ceq 'FileScope' -and -not (Test-WsmAssistivePackageScope $plan $included[$row.ItemId])){throw 'Non-C payload is forbidden in the main package.'};Assert-WsmRelativePath $row.RelativePath -AllowRoot;Assert-WsmArtifactRecord $row $included[$row.ItemId];$key=$row.ItemId+'|'+$row.RelativePath.ToUpperInvariant();Add-WsmArtifactKey $keySpool $key;$seenItems[$row.ItemId]=$true;$records++;if($records % 100 -eq 0){Write-Progress -Activity 'Validating package (bounded artifact memory)' -Status ($records.ToString()+' records verified')};if(-not $row.Directory){$files++;$length=[long]0;$sha=[Security.Cryptography.SHA256]::Create();try{foreach($part in $row.Data.Chunks){if($part.Hash -notmatch '^[a-f0-9]{64}$' -or $part.Bytes -lt 1 -or $part.Bytes -gt $m.ChunkBytes){throw 'Invalid payload chunk.'};$blob=Join-Path (Join-Path $root 'payload') ($part.Hash+'.blob');Assert-WsmNoReparse $blob;$stream=[IO.File]::Open($blob,'Open','Read','Read');try{if($stream.Length -ne $part.Bytes){throw 'Payload chunk length mismatch.'};$partSha=[Security.Cryptography.SHA256]::Create();try{if((Get-WsmCancellableStreamHash $stream $CancellationToken 'PackageChunkHashBuffer') -ine $part.Hash){throw 'Payload chunk hash mismatch.'}}finally{$partSha.Dispose()};$stream.Position=0;$buffer=New-Object byte[] 65536;while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){Assert-WsmCancellationBoundary $CancellationToken 'PackageWholeHashBuffer';[void]$sha.TransformBlock($buffer,0,$n,$buffer,0)}}finally{$stream.Dispose()};$length+=$part.Bytes};[void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0);if($length -ne $row.Data.Bytes -or [BitConverter]::ToString($sha.Hash).Replace('-','') -ine $row.Data.Hash){throw 'Whole artifact hash/length mismatch.'}}finally{$sha.Dispose()};$bytes+=$length}}
    Assert-WsmArtifactKeysUnique $keySpool}finally{Remove-WsmKeySpool $keySpool;Write-Progress -Activity 'Validating package (bounded artifact memory)' -Completed}
    foreach($memberItem in @($plan.Items | Where-Object {$_.Decision -ceq 'Include' -and $_.PSObject.Properties['MigrationSpec'] -and (Test-WsmExactMembersSpec $_.MigrationSpec)})){Assert-WsmExactMemberArtifactSet $memberItem $index $m.ArtifactsHash $CancellationToken}
    if($files -ne $m.Files -or $bytes -ne $m.Bytes -or $records -ne $m.Records){throw 'Package summary mismatch.'}
    foreach($configItem in $plan.Items){if((Test-WsmAssistivePackageScope $plan $configItem)){Assert-WsmApprovedConfigArtifacts -Spec $configItem.MigrationSpec -ArtifactsPath $index -ExpectedHash $m.ArtifactsHash -ItemId $configItem.ItemId -CancellationToken $CancellationToken | Out-Null}}
    foreach($i in $included.Values){if(($i.MigrationSpec.Adapter -ceq 'Certificate' -or (Test-WsmAssistivePackageScope $plan $i)) -and -not $seenItems.ContainsKey($i.ItemId)){throw 'Selected payload item has no artifacts.'}}
    if($m.Final){[void](Read-WsmFreezeRecord (Join-Path $root 'freeze.json') $m.FreezeHash $plan $m.PlanHash)}
    # Expose the verified plan hash directly for consumers that bind a validated
    # package object. Keep it derived from the already trusted manifest bytes.
    [pscustomobject]@{Manifest=$m;Plan=$plan;PlanHash=[string]$m.PlanHash;Root=$root;ManifestPath=[IO.Path]::GetFullPath($ManifestPath);SHA256=$ExpectedHash;Valid=$true}
}
function Restore-WsmPayloadBytes($Row,[string]$PackageRoot,[string]$Destination,$CancellationToken=$null) {
    Assert-WsmCancellationBoundary $CancellationToken 'BeforePayloadRestore'
    $temp=Join-Path ([IO.Path]::GetDirectoryName($Destination)) ([Guid]::NewGuid().ToString('N')+'.partial');$output=$null
    try{
        $output=[IO.File]::Open($temp,'CreateNew','Write','None')
        foreach($part in $Row.Data.Chunks){
            Assert-WsmCancellationBoundary $CancellationToken 'BeforeRestoreChunk'
            $blob=Join-Path (Join-Path $PackageRoot 'payload') ($part.Hash+'.blob');Assert-WsmNoReparse $blob
            $stream=[IO.File]::Open($blob,'Open','Read','Read')
            try{$sha=[Security.Cryptography.SHA256]::Create();try{if((Get-WsmCancellableStreamHash $stream $CancellationToken 'RestoreChunkHashBuffer') -ine $part.Hash -or $stream.Length -ne $part.Bytes){throw 'Chunk changed since package validation.'}}finally{$sha.Dispose()};$stream.Position=0;Copy-WsmCancellableStream $stream $output $CancellationToken 'RestoreChunkCopyBuffer'}finally{$stream.Dispose()}
            $output.Flush($true);Assert-WsmCancellationBoundary $CancellationToken 'PayloadChunkRestored'
        }
        $output.Flush($true);$output.Dispose();$output=$null
        if((Get-WsmCancellableFileHash $temp $CancellationToken 'RestoreWholeHashBuffer') -ine $Row.Data.Hash -or (New-Object IO.FileInfo($temp)).Length -ne $Row.Data.Bytes){throw 'Reconstructed payload mismatch.'}
        Assert-WsmCancellationBoundary $CancellationToken 'PayloadFilePrepared'
        if([IO.File]::Exists($Destination)){[IO.File]::Delete($Destination)};[IO.File]::Move($temp,$Destination)
    }finally{if($output){$output.Dispose()};if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-WsmCertificateArtifact($Package,$Desired) {
    $PackageRoot=$Package.Root;$plan=$Package.Plan;$item=@($plan.Items | Where-Object {$_.Decision -eq 'Include' -and $_.MigrationSpec.Adapter -eq 'Certificate' -and $_.MigrationSpec.Desired.Thumbprint -ceq $Desired.Thumbprint});if($item.Count -ne 1){throw 'Certificate artifact ambiguous.'};$rows=@(Read-WsmArtifactLines (Join-Path $PackageRoot 'artifacts.jsonl') $Package.Manifest.ArtifactsHash | Where-Object ItemId -CEQ $item[0].ItemId);if($rows.Count -ne 1){throw 'Certificate artifact missing.'};$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-certificate-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporaryRoot);Protect-WsmDirectory $temporaryRoot;$temp=Join-Path $temporaryRoot 'certificate.pfx';Restore-WsmPayloadBytes $rows[0] $PackageRoot $temp; if((Get-FileHash -LiteralPath $temp).Hash -ine $Desired.ArtifactHash){throw 'Certificate source artifact hash mismatch.'};$temp
}
