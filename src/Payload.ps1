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
    if([IO.Directory]::Exists($Path)){[IO.Directory]::SetCreationTimeUtc($Path,[DateTime]::Parse($Metadata.CreationUtc).ToUniversalTime());[IO.Directory]::SetLastWriteTimeUtc($Path,[DateTime]::Parse($Metadata.LastWriteUtc).ToUniversalTime())}else{[IO.File]::SetCreationTimeUtc($Path,[DateTime]::Parse($Metadata.CreationUtc).ToUniversalTime());[IO.File]::SetLastWriteTimeUtc($Path,[DateTime]::Parse($Metadata.LastWriteUtc).ToUniversalTime())}
    [IO.File]::SetAttributes($Path,[IO.FileAttributes]$Metadata.Attributes)
}
function Get-WsmScopeEntries($Spec,[string]$PackageRoot) {
    if([IO.Path]::GetFullPath($Spec.SourcePath).Length -gt 239){throw 'FileScope exceeds the verified 239-character path limit; use a dedicated long-path workflow.'}
    $root=ConvertTo-WsmCanonicalPath $Spec.SourcePath; Assert-WsmNoReparse $root
    $package=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\'); if($package -ieq $root -or $package.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($package+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Scope overlaps package workspace.'}
    if(Test-WsmPathOverlap (Get-WsmPhysicalPath $root) (Get-WsmPhysicalPath $package)){throw 'Scope overlaps package workspace through physical aliases.'}
    if(-not [IO.File]::Exists($root) -and -not [IO.Directory]::Exists($root)){throw 'Approved scope is absent.'}
    $stack=New-Object 'System.Collections.Generic.Stack[string]'; $stack.Push($root)
    while($stack.Count){$path=$stack.Pop(); $relative=$path.Substring($root.Length).TrimStart('\'); $exclude=$false; foreach($p in $Spec.ExcludedRelativePaths){if($relative -ieq $p -or $relative.StartsWith($p.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$exclude=$true;break}}; if($exclude){continue}; Assert-WsmRelativePath $relative -AllowRoot;if($path.Length -gt 239){throw 'FileScope exceeds the verified 239-character path limit; no payload is sealed.'}; Assert-WsmNoReparse $path; $directory=[IO.Directory]::Exists($path); [pscustomobject]@{SourcePath=$path; RelativePath=$relative; Directory=$directory}; if($directory){foreach($child in [IO.Directory]::EnumerateFileSystemEntries($path)){$stack.Push($child)}}}
}
function Get-WsmAvailableBytes([string]$Path) {
    $root=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)); if($root.StartsWith('\\')){throw 'UNC capacity must be established by an explicit storage-specific procedure; use a local package workspace.'}; (New-Object IO.DriveInfo($root)).AvailableFreeSpace
}
function Get-WsmPackageEstimate {
    param([string]$PlanPath,[string]$ExpectedHash,[string]$OutputDirectory)
    $p=Read-WsmMigrationPlan $PlanPath $ExpectedHash; $bytes=[long]0; $count=[long]0; $largest=[long]0
    foreach($i in $p.Items){if($i.Decision -eq 'Include' -and $i.MigrationSpec.Adapter -eq 'FileScope'){Get-WsmScopeEntries $i.MigrationSpec $OutputDirectory | ForEach-Object {$e=$_;[void](Get-WsmFileMetadata $e.SourcePath $i.MigrationSpec.Metadata); if(-not $e.Directory){$length=(New-Object IO.FileInfo($e.SourcePath)).Length; $bytes+=$length; $count++; $largest=[Math]::Max($largest,$length)}}}}
    $indexBudget=[Math]::Max([long]64MB,[long]($count*8192)); $margin=[Math]::Max([long]256MB,[long]($bytes*0.1)); $required=$bytes+$indexBudget+$margin
    [pscustomobject]@{Files=$count; Bytes=$bytes; LargestFile=$largest; PayloadBytesUpperBound=$bytes; IndexBudget=$indexBudget; SafetyMargin=$margin; RequiredFreeBytes=$required; AvailableFreeBytes=(Get-WsmAvailableBytes $OutputDirectory); TargetRequiredBytes=$bytes+$margin; BackupRequiredBytes='Measure existing target scope during restore preview'; DedupEstimate='Conservative: no dedup savings assumed'}
}
function Write-WsmPayloadFile([string]$SourcePath,[string]$BlobDirectory,[int]$ChunkBytes,[int]$BytesPerSecond=0) {
    $stream=[IO.File]::Open($SourcePath,'Open','Read','Read'); $chunks=New-Object 'System.Collections.Generic.List[object]'; $sha=[Security.Cryptography.SHA256]::Create(); $watch=[Diagnostics.Stopwatch]::StartNew(); $copied=[long]0
    try{$length=$stream.Length; $buffer=New-Object byte[] $ChunkBytes
        while($true){$read=0; while($read -lt $buffer.Length){$n=$stream.Read($buffer,$read,$buffer.Length-$read);if($n -eq 0){break};$read+=$n};if($read -eq 0){break};[void]$sha.TransformBlock($buffer,0,$read,$buffer,0);$partSha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($partSha.ComputeHash($buffer,0,$read)).Replace('-','').ToLowerInvariant()}finally{$partSha.Dispose()};$blob=Join-Path $BlobDirectory ($hash+'.blob');if([IO.File]::Exists($blob)){if((New-Object IO.FileInfo($blob)).Length -ne $read -or (Get-FileHash -LiteralPath $blob).Hash -ine $hash){throw 'Resume blob is corrupt.'}}else{$temp=$blob+'.'+[Guid]::NewGuid().ToString('N')+'.partial';try{$output=[IO.File]::Open($temp,'CreateNew','Write','None');try{$output.Write($buffer,0,$read);$output.Flush($true)}finally{$output.Dispose()};[IO.File]::Move($temp,$blob)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}};$chunks.Add([pscustomobject]@{Hash=$hash;Bytes=$read});$copied+=$read;if($BytesPerSecond -gt 0){$due=$copied/[double]$BytesPerSecond-$watch.Elapsed.TotalSeconds;while($due -gt 0){Start-Sleep -Milliseconds ([Math]::Min(200,[int]($due*1000)));$due=$copied/[double]$BytesPerSecond-$watch.Elapsed.TotalSeconds}};Write-Progress -Activity 'Hashing and sealing payload' -Status ($copied.ToString()+'/'+$length+' bytes') -PercentComplete ([int](100*$copied/[Math]::Max([long]1,[long]$length)))}
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0);if($stream.Length -ne $length -or $copied -ne $length){throw 'Source changed during payload capture.'};[pscustomobject]@{Bytes=$length;Hash=[BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant();Chunks=$chunks.ToArray()}
    }finally{$stream.Dispose();$sha.Dispose();Write-Progress -Activity 'Hashing and sealing payload' -Completed}
}
function Read-WsmArtifactLines([string]$Path,[string]$ExpectedHash) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Trusted artifact index hash required.'};Assert-WsmNoReparse $Path
    $stream=[IO.File]::Open($Path,'Open','Read','Read');$sha=[Security.Cryptography.SHA256]::Create();try{if([BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') -ine $ExpectedHash){throw 'Artifact index changed before use.'}}catch{$stream.Dispose();throw}finally{$sha.Dispose()};$stream.Position=0;$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
    try{Read-WsmBoundedLines $reader | ForEach-Object {ConvertFrom-WsmJson $_}}finally{$reader.Dispose();$stream.Dispose()}
}
function Export-WsmMigrationPackage {
    [CmdletBinding()] param([string]$PlanPath,[string]$ExpectedHash,[string]$SourceStateDirectory,[string]$OutputDirectory,[ValidateRange(65536,67108864)][int]$ChunkBytes=67108864,[ValidateRange(0,1073741824)][int]$BytesPerSecond=0,[string]$BaseManifestPath,[string]$BaseManifestHash,[string]$FreezePath,[string]$FreezeHash)
    $plan=Read-WsmMigrationPlan $PlanPath $ExpectedHash; Assert-WsmMigrationHost (Get-WsmMachineIdentity) $plan.Source.Fingerprint
    Assert-WsmSourceWorkspaceSeparation $plan $SourceStateDirectory
    Assert-WsmSourceWorkspaceSeparation $plan $OutputDirectory
    # Refresh the real local collector before any payload work; revision alone is not a configuration check.
    $freshResult=Export-WsmInventory $SourceStateDirectory -DeepDiscovery:($plan.Source.PSObject.Properties['DiscoveryDepth'] -and $plan.Source.DiscoveryDepth -eq 'Deep'); $fresh=Read-WsmTrustedJson $freshResult.Path $freshResult.SHA256; $current=@{};foreach($i in $fresh.Items){$current[$i.ItemId]=$i}
    if($fresh.Source.HostId -cne $plan.Source.HostId){throw 'Fresh inventory source identity mismatch.'}
    $base=$null;$generation=1;$freeze=$null
    if($BaseManifestPath){$base=Read-WsmTrustedJson $BaseManifestPath $BaseManifestHash;Assert-WsmEnvelope $base 'MigrationPackage';if($base.PairId -cne $plan.PairId -or $base.PlanHash -ine $ExpectedHash){throw 'Delta base plan/pair mismatch.'};$generation=$base.Generation+1}
    $needsFreeze=@($plan.Items | Where-Object {$_.Decision -eq 'Include' -and $_.MigrationSpec.Adapter -eq 'FileScope' -and $_.MigrationSpec.Consistency -ne 'Immutable'}).Count -gt 0
    if($FreezePath){$freeze=Read-WsmFreezeRecord $FreezePath $FreezeHash $plan; if(-not $freeze){throw 'Invalid freeze record.'}}elseif($base -or $needsFreeze){throw 'Final delta and mutable scopes require independent source freeze evidence.'}
    foreach($i in $plan.Items){if($i.Decision -eq 'Include' -and $i.Kind -ne 'ManualItem'){$expectedSettings=$i.SettingsHash;if($freeze){$q=@($freeze.QuiescedSettingsHashes | Where-Object ItemId -CEQ $i.ItemId);if($q.Count -ne 1 -or $q[0].OriginalHash -cne $i.SettingsHash){throw 'Freeze configuration baseline mismatch.'};$expectedSettings=$q[0].QuiescedHash};if(-not $current.ContainsKey($i.ItemId) -or $current[$i.ItemId].SettingsHash -cne $expectedSettings){throw ('Configuration drift requires review: '+$i.ItemId)}}}
    if(-not [IO.Directory]::Exists($OutputDirectory)){[void][IO.Directory]::CreateDirectory($OutputDirectory);Protect-WsmDirectory $OutputDirectory};Assert-WsmNoReparse $OutputDirectory
    Invoke-WsmLocked $OutputDirectory {
        $estimate=Get-WsmPackageEstimate $PlanPath $ExpectedHash $OutputDirectory;if($estimate.RequiredFreeBytes -gt $estimate.AvailableFreeBytes){throw 'Insufficient package workspace capacity; no package sealed.'}
        $root=Join-Path $OutputDirectory ($plan.PairId+'-g'+$generation);if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root};Assert-WsmNoReparse $root
        $manifestPath=Join-Path $root 'manifest.json';if([IO.File]::Exists($manifestPath)){throw 'Generation already sealed; use a new generation rather than overwrite evidence.'}
        $blobs=Join-Path $root 'payload';[void][IO.Directory]::CreateDirectory($blobs);Assert-WsmNoReparse $blobs
        $resumePath=Join-Path $root 'export-state.json';if([IO.File]::Exists($resumePath)){$resume=Read-WsmJson $resumePath;if($resume.PlanHash -ine $ExpectedHash -or $resume.ChunkBytes -ne $ChunkBytes){throw 'Resume plan/chunk format mismatch.'}}else{Write-WsmJson $resumePath ([pscustomobject]@{PlanHash=$ExpectedHash;ChunkBytes=$ChunkBytes;Generation=$generation;StartedUtc=(Get-WsmUtc)})}
        $indexTemp=Join-Path $root 'artifacts.jsonl.partial';$writer=New-Object IO.StreamWriter($indexTemp,$false,(New-Object Text.UTF8Encoding($false)));$files=[long]0;$bytes=[long]0;$records=[long]0
        try{foreach($item in $plan.Items){if($item.Decision -ne 'Include'){continue};$spec=$item.MigrationSpec
            if($spec.Adapter -eq 'FileScope'){Get-WsmScopeEntries $spec $root | ForEach-Object {$e=$_;$metadata=Get-WsmFileMetadata $e.SourcePath $spec.Metadata;$data=$null;if(-not $e.Directory){$data=Write-WsmPayloadFile $e.SourcePath $blobs $ChunkBytes $BytesPerSecond;$files++;$bytes+=$data.Bytes};$row=[pscustomobject]@{ItemId=$item.ItemId;RelativePath=$e.RelativePath;Directory=$e.Directory;Metadata=$metadata;Data=$data};$line=$row | ConvertTo-Json -Compress -Depth 20;if($line.Length -gt 1MB){throw 'Artifact row exceeds supported size; increase chunk size or use dedicated large-file adapter.'};$writer.WriteLine($line);$writer.Flush();$records++}}
            elseif($spec.Adapter -eq 'Certificate'){$d=$spec.Desired;Assert-WsmNoReparse $d.ArtifactPath;if((Get-FileHash -LiteralPath $d.ArtifactPath).Hash -ine $d.ArtifactHash){throw 'Independent certificate artifact changed.'};$data=Write-WsmPayloadFile $d.ArtifactPath $blobs $ChunkBytes $BytesPerSecond;$row=[pscustomobject]@{ItemId=$item.ItemId;RelativePath='certificate-artifact';Directory=$false;Metadata=$null;Data=$data};$writer.WriteLine(($row | ConvertTo-Json -Compress -Depth 20));$files++;$bytes+=$data.Bytes;$records++}
        }}finally{$writer.Dispose()}
        $indexPath=Join-Path $root 'artifacts.jsonl';if([IO.File]::Exists($indexPath)){[IO.File]::Delete($indexPath)};[IO.File]::Move($indexTemp,$indexPath)
        $planCopy=Join-Path $root 'plan.json';[IO.File]::Copy($PlanPath,$planCopy,$true);if((Get-FileHash -LiteralPath $planCopy).Hash -ine $ExpectedHash){throw 'Plan changed during export.'}
        $manifest=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='MigrationPackage';PackageId=[Guid]::NewGuid().ToString();BatchId=$plan.BatchId;PairId=$plan.PairId;ApprovalId=$plan.ApprovalId;PlanHash=$ExpectedHash.ToLowerInvariant();Source=$plan.Source;Target=$plan.Target;InventoryRevision=$plan.InventoryRevision;DecisionRevision=$plan.DecisionRevision;Generation=$generation;BaseManifestHash=$BaseManifestHash;Final=($null -ne $freeze);FreezeHash=$FreezeHash;ArtifactsHash=(Get-FileHash -LiteralPath $indexPath).Hash.ToLowerInvariant();Files=$files;Bytes=$bytes;Records=$records;ChunkBytes=$ChunkBytes;SealedUtc=(Get-WsmUtc);Mode='IsolatedPilot'}
        if($freeze){Write-WsmJson (Join-Path $root 'freeze.json') $freeze; $manifest.FreezeHash=(Get-FileHash -LiteralPath (Join-Path $root 'freeze.json')).Hash.ToLowerInvariant()}
        $candidate=Join-Path $root 'manifest.pending.json';Write-WsmJson $candidate $manifest;$hash=(Get-FileHash -LiteralPath $candidate).Hash
        Test-WsmMigrationPackage $candidate $hash | Out-Null
        [IO.File]::Move($candidate,$manifestPath)
        [pscustomobject]@{Directory=$root;ManifestPath=$manifestPath;SHA256=$hash;Generation=$generation;Files=$files;Bytes=$bytes;Sealed=$true;Final=$manifest.Final;ProductionVerified=$false}
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
function Test-WsmMigrationPackage {
    param([string]$ManifestPath,[string]$ExpectedHash)
    $m=Read-WsmTrustedJson $ManifestPath $ExpectedHash;Assert-WsmEnvelope $m 'MigrationPackage';$root=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ManifestPath));Assert-WsmNoReparse $root
    foreach($id in @($m.PackageId,$m.BatchId,$m.PairId,$m.ApprovalId)){Assert-WsmId $id};if($m.Generation -lt 1 -or $m.Mode -cne 'IsolatedPilot'){throw 'Invalid package generation/mode.'}
    $plan=Read-WsmMigrationPlan (Join-Path $root 'plan.json') $m.PlanHash;if($plan.PairId -cne $m.PairId -or $plan.BatchId -cne $m.BatchId -or $plan.ApprovalId -cne $m.ApprovalId -or $plan.Source.Fingerprint -cne $m.Source.Fingerprint -or $plan.Target.Fingerprint -cne $m.Target.Fingerprint -or $plan.DecisionRevision -ne $m.DecisionRevision -or $plan.InventoryRevision -ne $m.InventoryRevision){throw 'Package plan binding mismatch.'}
    $index=Join-Path $root 'artifacts.jsonl';Assert-WsmNoReparse $index;if((Get-FileHash -LiteralPath $index).Hash -ine $m.ArtifactsHash){throw 'Artifact index hash mismatch.'}
    $included=@{};foreach($i in $plan.Items){if($i.Decision -eq 'Include'){$included[$i.ItemId]=$i}};$seenItems=@{};$files=[long]0;$bytes=[long]0;$records=[long]0
    $keySpool=New-WsmArtifactKeySpool;try{Read-WsmArtifactLines $index $m.ArtifactsHash | ForEach-Object {$row=$_;Assert-WsmFields $row @('ItemId','RelativePath','Directory','Metadata','Data') @('ItemId','RelativePath','Directory','Metadata','Data');if(-not $included.ContainsKey($row.ItemId)){throw 'Artifact belongs to excluded/unknown item.'};Assert-WsmRelativePath $row.RelativePath -AllowRoot;Assert-WsmArtifactRecord $row $included[$row.ItemId];$key=$row.ItemId+'|'+$row.RelativePath.ToUpperInvariant();Add-WsmArtifactKey $keySpool $key;$seenItems[$row.ItemId]=$true;$records++;if($records % 100 -eq 0){Write-Progress -Activity 'Validating package (bounded artifact memory)' -Status ($records.ToString()+' records verified')};if(-not $row.Directory){$files++;$length=[long]0;$sha=[Security.Cryptography.SHA256]::Create();try{foreach($part in $row.Data.Chunks){if($part.Hash -notmatch '^[a-f0-9]{64}$' -or $part.Bytes -lt 1 -or $part.Bytes -gt $m.ChunkBytes){throw 'Invalid payload chunk.'};$blob=Join-Path (Join-Path $root 'payload') ($part.Hash+'.blob');Assert-WsmNoReparse $blob;$stream=[IO.File]::Open($blob,'Open','Read','Read');try{if($stream.Length -ne $part.Bytes){throw 'Payload chunk length mismatch.'};$partSha=[Security.Cryptography.SHA256]::Create();try{if([BitConverter]::ToString($partSha.ComputeHash($stream)).Replace('-','') -ine $part.Hash){throw 'Payload chunk hash mismatch.'}}finally{$partSha.Dispose()};$stream.Position=0;$buffer=New-Object byte[] 65536;while(($n=$stream.Read($buffer,0,$buffer.Length)) -gt 0){[void]$sha.TransformBlock($buffer,0,$n,$buffer,0)}}finally{$stream.Dispose()};$length+=$part.Bytes};[void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0);if($length -ne $row.Data.Bytes -or [BitConverter]::ToString($sha.Hash).Replace('-','') -ine $row.Data.Hash){throw 'Whole artifact hash/length mismatch.'}}finally{$sha.Dispose()};$bytes+=$length}}
    Assert-WsmArtifactKeysUnique $keySpool}finally{Remove-WsmKeySpool $keySpool;Write-Progress -Activity 'Validating package (bounded artifact memory)' -Completed}
    if($files -ne $m.Files -or $bytes -ne $m.Bytes -or $records -ne $m.Records){throw 'Package summary mismatch.'}
    foreach($i in $included.Values){if($i.MigrationSpec.Adapter -in @('FileScope','Certificate') -and -not $seenItems.ContainsKey($i.ItemId)){throw 'Selected payload item has no artifacts.'}}
    if($m.Final){[void](Read-WsmFreezeRecord (Join-Path $root 'freeze.json') $m.FreezeHash $plan)}
    [pscustomobject]@{Manifest=$m;Plan=$plan;Root=$root;SHA256=$ExpectedHash;Valid=$true}
}
function Restore-WsmPayloadBytes($Row,[string]$PackageRoot,[string]$Destination) {
    Assert-WsmNoReparse $Destination;$parent=[IO.Path]::GetDirectoryName($Destination);[void][IO.Directory]::CreateDirectory($parent);$temp=Join-Path $parent ([Guid]::NewGuid().ToString('N')+'.wsm.partial');$output=[IO.File]::Open($temp,'CreateNew','Write','None')
    try{foreach($part in $Row.Data.Chunks){$blob=Join-Path (Join-Path $PackageRoot 'payload') ($part.Hash+'.blob');Assert-WsmNoReparse $blob;$stream=[IO.File]::Open($blob,'Open','Read','Read');try{$sha=[Security.Cryptography.SHA256]::Create();try{if([BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') -ine $part.Hash -or $stream.Length -ne $part.Bytes){throw 'Chunk changed since package validation.'}}finally{$sha.Dispose()};$stream.Position=0;$stream.CopyTo($output)}finally{$stream.Dispose()}};$output.Flush($true)}finally{$output.Dispose()}
    try{if((Get-FileHash -LiteralPath $temp).Hash -ine $Row.Data.Hash -or (New-Object IO.FileInfo($temp)).Length -ne $Row.Data.Bytes){throw 'Reconstructed payload mismatch.'};if([IO.File]::Exists($Destination)){[IO.File]::Delete($Destination)};[IO.File]::Move($temp,$Destination)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Get-WsmCertificateArtifact($Package,$Desired) {
    $PackageRoot=$Package.Root;$plan=$Package.Plan;$item=@($plan.Items | Where-Object {$_.Decision -eq 'Include' -and $_.MigrationSpec.Adapter -eq 'Certificate' -and $_.MigrationSpec.Desired.Thumbprint -ceq $Desired.Thumbprint});if($item.Count -ne 1){throw 'Certificate artifact ambiguous.'};$rows=@(Read-WsmArtifactLines (Join-Path $PackageRoot 'artifacts.jsonl') $Package.Manifest.ArtifactsHash | Where-Object ItemId -CEQ $item[0].ItemId);if($rows.Count -ne 1){throw 'Certificate artifact missing.'};$temporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-certificate-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temporaryRoot);Protect-WsmDirectory $temporaryRoot;$temp=Join-Path $temporaryRoot 'certificate.pfx';Restore-WsmPayloadBytes $rows[0] $PackageRoot $temp; if((Get-FileHash -LiteralPath $temp).Hash -ine $Desired.ArtifactHash){throw 'Certificate source artifact hash mismatch.'};$temp
}
