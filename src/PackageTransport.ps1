function Get-WsmPackageMembers($Package) {
    $root=$Package.Root;$names=@('manifest.json','plan.json','artifacts.jsonl');if($Package.Manifest.Final){$names+=@('freeze.json')};$seen=@{};$metadataBytes=[long]0
    foreach($name in $names){$path=Join-Path $root $name;Assert-WsmNoReparse $path;$bytes=(New-Object IO.FileInfo($path)).Length;$metadataBytes+=$bytes;if($metadataBytes -gt 128MB){throw 'Full package delivery metadata exceeds its aggregate 128 MiB budget; no transport is sealed.'};[pscustomobject]@{Name=$name;Path=$path;Bytes=$bytes;Hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}}
    Read-WsmArtifactLines (Join-Path $root 'artifacts.jsonl') $Package.Manifest.ArtifactsHash | ForEach-Object {$row=$_;if(-not $row.Directory){foreach($chunk in $row.Data.Chunks){if($seen.ContainsKey($chunk.Hash)){continue};if($seen.Count+$names.Count -ge 100000){throw 'Full package delivery exceeds its 100000-member budget; no transport is sealed.'};$seen[$chunk.Hash]=$true;$name='payload/'+$chunk.Hash+'.blob';[pscustomobject]@{Name=$name;Path=(Join-Path $root $name);Bytes=$chunk.Bytes;Hash=$chunk.Hash}}}}
}
function Test-WsmZipVolume([string]$Path,[object[]]$Expected,[string]$ExpectedHash='',$CancellationToken=$null) {
    Assert-WsmNoReparse $Path;$file=[IO.File]::Open($Path,'Open','Read','Read');$archive=$null;$sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=Get-WsmCancellableStreamHash $file $CancellationToken 'ZipVolumeHashBuffer';if($ExpectedHash -and $hash -ine $ExpectedHash){throw 'Previously completed ZIP volume changed.'};$file.Position=0;$archive=New-Object IO.Compression.ZipArchive($file,[IO.Compression.ZipArchiveMode]::Read,$true);$seen=@{};$lookup=@{};foreach($e in $Expected){$lookup[$e.Name]=$e};if($archive.Entries.Count -ne $Expected.Count){throw 'ZIP volume entry count mismatch.'};foreach($entry in $archive.Entries){if($seen.ContainsKey($entry.FullName) -or -not $lookup.ContainsKey($entry.FullName) -or $entry.FullName -cne $lookup[$entry.FullName].Name -or $entry.Length -ne $lookup[$entry.FullName].Bytes){throw 'ZIP volume entry identity/size mismatch.'};$seen[$entry.FullName]=$true;$stream=$entry.Open();try{$entryHash=Get-WsmCancellableStreamHash $stream $CancellationToken 'ZipMemberHashBuffer';if($entryHash -ine $lookup[$entry.FullName].Hash){throw 'ZIP volume member changed during export.'}}finally{$stream.Dispose()}};[pscustomobject]@{Hash=$hash;Bytes=$file.Length}
    }finally{if($archive){$archive.Dispose()};$sha.Dispose();$file.Dispose()}
}
function Get-WsmZipMemberGroups {
    param([object[]]$Members,[long]$VolumeBytes)
    if($VolumeBytes -lt 1048576 -or $VolumeBytes -gt 1073741824){throw 'ZIP volume budget is outside the supported range.'}
    $groups=New-Object 'System.Collections.Generic.List[object]';$group=New-Object 'System.Collections.Generic.List[object]';$used=[long]0
    foreach($member in $Members){
        if($member.Bytes -lt 0 -or [string]::IsNullOrWhiteSpace([string]$member.Name)){throw 'Invalid ZIP member budget.'}
        $budget=[long]$member.Bytes+[Text.Encoding]::UTF8.GetByteCount([string]$member.Name)*2+256
        if($budget -gt $VolumeBytes){throw 'Member plus ZIP overhead exceeds volume budget; use smaller chunks or larger volumes.'}
        if($group.Count -and $used+$budget -gt $VolumeBytes){
            $groups.Add($group.ToArray());if($groups.Count -ge 9999){throw 'ZIP delivery requires more than 9999 volumes; increase the volume budget or review the migration scope.'}
            $group=New-Object 'System.Collections.Generic.List[object]';$used=0
        }
        $group.Add($member);$used+=$budget
    }
    if($group.Count){$groups.Add($group.ToArray())}
    # Preserve each group as an array, including single-member groups.
    foreach($part in $groups){Write-Output -NoEnumerate $part}
}
function Export-WsmPackageZip {
    param([string]$ManifestPath,[string]$ExpectedHash,[string]$OutputDirectory,[ValidateRange(1048576,1073741824)][long]$VolumeBytes=536870912,$CancellationToken=$null)
    if($CancellationToken){$header=Read-WsmTrustedJson $ManifestPath $ExpectedHash;Assert-WsmEnvelope $header 'MigrationPackage';[void](Assert-WsmCancellationTokenBinding $CancellationToken $header.PairId $header.PlanHash $ExpectedHash $OutputDirectory);Assert-WsmCancellationBoundary $CancellationToken 'BeforeZipExportValidation'}
    $p=Test-WsmMigrationPackage $ManifestPath $ExpectedHash $CancellationToken;$output=[IO.Path]::GetFullPath($OutputDirectory);if($output -ieq $p.Root -or $output.StartsWith($p.Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'ZIP output must be outside sealed package.'};Assert-WsmNoReparse $output;if(-not [IO.Directory]::Exists($output)){[void][IO.Directory]::CreateDirectory($output);Protect-WsmDirectory $output};Add-Type -AssemblyName System.IO.Compression.FileSystem
    if($CancellationToken){[void](Assert-WsmCancellationTokenBinding $CancellationToken $p.Manifest.PairId $p.Manifest.PlanHash $ExpectedHash $OutputDirectory);Assert-WsmCancellationBoundary $CancellationToken 'BeforeZipExport'}
    Invoke-WsmLocked $output {
        $members=@(Get-WsmPackageMembers $p);$groups=@(Get-WsmZipMemberGroups $members $VolumeBytes)
        $statePath=Join-Path $output 'zip-state.json';$state=$null
        if([IO.File]::Exists($statePath)){$state=Read-WsmJson $statePath;if($state.PackageId -cne $p.Manifest.PackageId -or $state.ManifestHash -ine $ExpectedHash -or $state.VolumeBytes -ne $VolumeBytes){throw 'ZIP resume package/format differs; use a separate output directory.'}}
        else{$state=[pscustomobject]@{PackageId=$p.Manifest.PackageId;ManifestHash=$ExpectedHash;VolumeBytes=$VolumeBytes;Volumes=@();StartedUtc=(Get-WsmUtc)};Write-WsmJson $statePath $state}
        $checkpointNames=@{};foreach($savedVolume in @($state.Volumes)){
            $savedMatch=[regex]::Match([string]$savedVolume.Name,('^package-'+[regex]::Escape([string]$p.Manifest.PackageId)+'-(\d{4})\.zip$'))
            if(-not $savedMatch.Success -or $checkpointNames.ContainsKey([string]$savedVolume.Name) -or $savedVolume.Hash -notmatch '^[a-fA-F0-9]{64}$' -or $savedVolume.Bytes -lt 0 -or $savedVolume.Bytes -gt $VolumeBytes){throw 'Invalid ZIP checkpoint volume descriptor; retain state and reconcile.'}
            $savedNumber=[int]$savedMatch.Groups[1].Value;if($savedNumber -lt 1 -or $savedNumber -gt $groups.Count){throw 'ZIP checkpoint references a volume outside the current member groups.'};$checkpointNames[[string]$savedVolume.Name]=$true
        }
        foreach($field in @('Status','FailureReason','UpdatedUtc')){if(-not $state.PSObject.Properties[$field]){$state | Add-Member NoteProperty $field ''}}
        $state.Status='Exporting';$state.FailureReason='';$state.UpdatedUtc=Get-WsmUtc;Write-WsmJson $statePath $state
        $volumes=New-Object 'System.Collections.Generic.List[object]';$entries=New-Object 'System.Collections.Generic.List[object]';$number=0
        try {
        foreach($part in $groups){$number++;$destination=Join-Path $output ('package-'+$p.Manifest.PackageId+'-'+$number.ToString('0000')+'.zip');$temp=$destination+'.partial';Assert-WsmNoReparse $destination;Assert-WsmNoReparse $temp;$expected=@(foreach($m in $part){[pscustomobject]@{Name=$m.Name;Bytes=$m.Bytes;Hash=$m.Hash;Volume=$number}});$checkpoint=@($state.Volumes | Where-Object Name -CEQ ([IO.Path]::GetFileName($destination)));$checkpointHash='';if($checkpoint.Count -gt 1){throw 'Duplicate ZIP checkpoint.'};if($checkpoint.Count){$checkpointHash=$checkpoint[0].Hash;if(-not [IO.File]::Exists($destination)){throw 'Completed ZIP volume is missing; retain checkpoint and reconcile.'}}
            if(-not [IO.File]::Exists($destination)){
                $required=($part | Measure-Object Bytes -Sum).Sum+64MB;if((Get-WsmAvailableBytes $output) -lt $required){throw 'Insufficient ZIP workspace capacity; completed volumes retained for retry.'}
                if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)};$archive=[IO.Compression.ZipFile]::Open($temp,'Create')
                try{foreach($m in $part){Assert-WsmCancellationBoundary $CancellationToken 'BeforeZipMember';Assert-WsmNoReparse $m.Path;$entry=$archive.CreateEntry($m.Name,[IO.Compression.CompressionLevel]::NoCompression);$input=[IO.File]::Open($m.Path,'Open','Read','Read');$stream=$entry.Open();try{Copy-WsmCancellableStream $input $stream $CancellationToken 'ZipWriteBuffer'}finally{$stream.Dispose();$input.Dispose()}}}finally{$archive.Dispose()}
                $check=Test-WsmZipVolume $temp $expected -CancellationToken $CancellationToken;if($check.Bytes -gt $VolumeBytes){throw 'ZIP actual size exceeds budget; no volume sealed.'};[IO.File]::Move($temp,$destination)
            }
            $check=Test-WsmZipVolume $destination $expected $checkpointHash $CancellationToken;if($check.Bytes -gt $VolumeBytes){throw 'ZIP volume exceeds reviewed budget.'};if($checkpoint.Count -and $check.Bytes -ne $checkpoint[0].Bytes){throw 'Completed ZIP volume byte count differs from checkpoint.'};$record=[pscustomobject]@{Name=[IO.Path]::GetFileName($destination);Bytes=$check.Bytes;Hash=$check.Hash};$volumes.Add($record);foreach($e in $expected){$entries.Add($e)};if(-not $checkpoint.Count){$state.Volumes=@($state.Volumes)+@($record)};$state.UpdatedUtc=Get-WsmUtc;Write-WsmJson $statePath $state;Assert-WsmCancellationBoundary $CancellationToken 'ZipVolumeCheckpoint';Write-Progress -Activity 'Writing/verifying ZIP volumes' -Status ($number.ToString()+'/'+$groups.Count) -PercentComplete ([int](100*$number/$groups.Count))
        }
        $path=Join-Path $output 'transport.json'
        if([IO.File]::Exists($path)){$transport=Read-WsmJson $path;if($transport.PackageId -cne $p.Manifest.PackageId -or $transport.ManifestHash -ine $ExpectedHash -or ($transport.Volumes | ConvertTo-Json -Depth 8 -Compress) -cne ($volumes.ToArray() | ConvertTo-Json -Depth 8 -Compress) -or ($transport.Entries | ConvertTo-Json -Depth 8 -Compress) -cne ($entries.ToArray() | ConvertTo-Json -Depth 8 -Compress)){throw 'Sealed transport differs from verified completed volumes.'}}
        else{$transport=[pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='PackageTransport';PackageId=$p.Manifest.PackageId;PairId=$p.Manifest.PairId;PlanHash=$p.Manifest.PlanHash;ManifestHash=$ExpectedHash;Volumes=$volumes.ToArray();Entries=$entries.ToArray();CreatedUtc=(Get-WsmUtc);Mode='IsolatedPilot'};Write-WsmJson $path $transport}
        $state.Status='Sealed';$state.FailureReason='';$state.UpdatedUtc=Get-WsmUtc;Write-WsmJson $statePath $state
        Write-Progress -Activity 'Writing/verifying ZIP volumes' -Completed;[pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash;Volumes=$volumes.Count;Bytes=($volumes | Measure-Object Bytes -Sum).Sum;PackageManifestHash=$ExpectedHash}
        } catch {
            $originalFailure=$_;$state.Status='Failed';$state.FailureReason=[string]$originalFailure.Exception.Message;$state.UpdatedUtc=Get-WsmUtc
            if($originalFailure.Exception -is [OperationCanceledException]){$state.Status='Cancelled'}
            try{Write-WsmJson $statePath $state}catch{Write-Warning 'ZIP export failed and the failure checkpoint could not be updated; retain the original workspace and reconcile completed volumes.'}
            throw $originalFailure
        }
    }
}
function Import-WsmPackageZip {
    param([string]$TransportPath,[string]$ExpectedHash,[string]$OutputDirectory,$CancellationToken=$null)
    $t=Read-WsmTrustedJson $TransportPath $ExpectedHash;Assert-WsmEnvelope $t 'PackageTransport';Assert-WsmId $t.PackageId;Assert-WsmId $t.PairId;$source=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($TransportPath));$output=[IO.Path]::GetFullPath($OutputDirectory);Assert-WsmNoReparse $source;Assert-WsmNoReparse $output
    if($CancellationToken){if(-not $t.PSObject.Properties['PlanHash']){throw 'Cancellable import requires a transport with an approved PlanHash.'};[void](Assert-WsmCancellationTokenBinding $CancellationToken $t.PairId $t.PlanHash $t.ManifestHash $OutputDirectory);Assert-WsmCancellationBoundary $CancellationToken 'BeforeZipImport'}
    if(-not [IO.Directory]::Exists($output)){[void][IO.Directory]::CreateDirectory($output);Protect-WsmDirectory $output};Add-Type -AssemblyName System.IO.Compression.FileSystem
    Invoke-WsmLocked $output {$seen=@{};$volumes=@{};$total=[long]0
        if(@($t.Volumes).Count -lt 1 -or @($t.Volumes).Count -gt 9999){throw 'Transport volume count is outside the supported range.'}
        foreach($v in $t.Volumes){if($v.Name -notmatch ('^package-'+[regex]::Escape($t.PackageId)+'-\d{4}\.zip$') -or $v.Hash -notmatch '^[a-f0-9]{64}$' -or $v.Bytes -lt 1 -or $v.Bytes -gt 2GB -or $volumes.ContainsKey($v.Name)){throw 'Invalid/duplicate transport volume.'};$volumes[$v.Name]=$v}
        foreach($e in $t.Entries){if($e.Name -cnotin @('manifest.json','plan.json','artifacts.jsonl','freeze.json') -and $e.Name -cnotmatch '^payload/[a-f0-9]{64}\.blob$'){throw 'Transport entry is not an approved data member.'};if($seen.ContainsKey($e.Name) -or $e.Hash -notmatch '^[a-f0-9]{64}$' -or $e.Bytes -lt 0 -or $e.Bytes -gt 1GB -or $e.Volume -lt 1 -or $e.Volume -gt $t.Volumes.Count){throw 'Invalid/colliding transport entry.'};$seen[$e.Name]=$e;$total+=$e.Bytes}
        foreach($required in @('manifest.json','plan.json','artifacts.jsonl')){if(-not $seen.ContainsKey($required)){throw 'Missing package metadata.'}};if((Get-WsmAvailableBytes $output) -lt $total+256MB){throw 'Insufficient unpack workspace capacity.'}
        # Verify the complete trusted volume set before creating an incoming package.
        $preflightNumber=0
        foreach($v in $t.Volumes){$preflightNumber++;$volumePath=Join-Path $source $v.Name;$expected=@($t.Entries | Where-Object Volume -EQ $preflightNumber);$check=Test-WsmZipVolume $volumePath $expected $v.Hash $CancellationToken;if($check.Bytes -ne $v.Bytes){throw 'Volume length mismatch.'}}
        $root=Join-Path $output ('incoming-'+$t.PackageId);if(-not [IO.Directory]::Exists($root)){[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root};Assert-WsmNoReparse $root;$resume=Join-Path $root 'transport-state.json';if([IO.File]::Exists($resume)){$s=Read-WsmJson $resume;if($s.TransportHash -ine $ExpectedHash){throw 'Resume transport hash mismatch.'}}else{Write-WsmJson $resume ([pscustomobject]@{TransportHash=$ExpectedHash;StartedUtc=(Get-WsmUtc)})};$extracted=@{};$number=0
        foreach($v in $t.Volumes){$number++;$volumePath=Join-Path $source $v.Name;Assert-WsmNoReparse $volumePath;$file=[IO.File]::Open($volumePath,'Open','Read','Read');$archive=$null
            try{if($file.Length -ne $v.Bytes){throw 'Volume length mismatch.'};if((Get-WsmCancellableStreamHash $file $CancellationToken 'ZipImportVolumeHashBuffer') -ine $v.Hash){throw 'Independent transport volume hash mismatch.'};$file.Position=0;$archive=New-Object IO.Compression.ZipArchive($file,[IO.Compression.ZipArchiveMode]::Read,$true)
                foreach($entry in $archive.Entries){Assert-WsmCancellationBoundary $CancellationToken 'BeforeZipExtractMember';$name=$entry.FullName;if(-not $seen.ContainsKey($name) -or $name -cne $seen[$name].Name -or $seen[$name].Volume -ne $number -or $extracted.ContainsKey($name) -or $entry.Length -ne $seen[$name].Bytes -or ($entry.Length -gt 1MB -and $entry.Length/[Math]::Max(1,$entry.CompressedLength) -gt 200)){throw 'Unexpected/duplicate/oversized ZIP member.'};$extracted[$name]=$true;$dest=Join-Path $root $name;Assert-WsmNoReparse $dest;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));if([IO.File]::Exists($dest) -and (New-Object IO.FileInfo($dest)).Length -eq $entry.Length -and (Get-FileHash -LiteralPath $dest).Hash -ieq $seen[$name].Hash){continue};$temp=$dest+'.partial';$input=$entry.Open();$stream=[IO.File]::Open($temp,'Create','Write','None');$length=[long]0
                    try{$buffer=New-Object byte[] 65536;while(($n=$input.Read($buffer,0,$buffer.Length)) -gt 0){$length+=$n;if($length -gt $entry.Length){throw 'ZIP expansion exceeds trusted member size.'};$stream.Write($buffer,0,$n);Assert-WsmCancellationBoundary $CancellationToken 'ZipExtractBuffer'};$stream.Flush($true)}finally{$stream.Dispose();$input.Dispose()};if($length -ne $entry.Length -or (Get-FileHash -LiteralPath $temp).Hash -ine $seen[$name].Hash){throw 'Extracted member hash/length mismatch.'};if([IO.File]::Exists($dest)){[IO.File]::Delete($dest)};[IO.File]::Move($temp,$dest)
                }
            }finally{if($archive){$archive.Dispose()};$file.Dispose()};Write-Progress -Activity 'Verifying and unpacking ZIP volumes' -Status ($number.ToString()+'/'+$t.Volumes.Count) -PercentComplete ([int](100*$number/$t.Volumes.Count))
        };if($extracted.Count -ne $seen.Count){throw 'Transport members missing.'};$package=Test-WsmMigrationPackage (Join-Path $root 'manifest.json') $t.ManifestHash $CancellationToken;if($t.PSObject.Properties['PlanHash'] -and $t.PlanHash -ine $package.Manifest.PlanHash){throw 'Transport approved plan binding mismatch.'};Write-WsmJson (Join-Path $root 'import-complete.json') ([pscustomobject]@{TransportHash=$ExpectedHash;ManifestHash=$t.ManifestHash;Utc=(Get-WsmUtc)});Write-Progress -Activity 'Verifying and unpacking ZIP volumes' -Completed;[pscustomobject]@{Directory=$root;ManifestPath=(Join-Path $root 'manifest.json');SHA256=$t.ManifestHash;Generation=$package.Manifest.Generation;Valid=$true}
    }
}
function Export-WsmOperationReport {
    param([string]$ManifestPath,[string]$ExpectedHash,[string]$StateDirectory,[string]$Path)
    $p=Test-WsmMigrationPackage $ManifestPath $ExpectedHash;$paths=Get-WsmOperationPaths $StateDirectory $p.Manifest.PairId;$s=Get-WsmOperationState $paths $p;$rows=@(foreach($i in $p.Plan.Items){$result=@($s.Items | Where-Object ItemId -CEQ $i.ItemId);$status='NotStarted';if($result.Count){$status=$result[0].Status};$adapter='Excluded';if($i.Decision -eq 'Include'){$adapter=$i.MigrationSpec.Adapter};[pscustomobject]@{Category=$i.Category;ItemId=$i.ItemId;Name=$i.Name;Decision=$i.Decision;Reason=$i.Reason;Adapter=$adapter;Status=$status;Generation=$p.Manifest.Generation;Owner=$i.Owner;Evidence=$i.Evidence;BusinessEvidence=@($s.Evidence | Where-Object {$_.ItemId -ceq $i.ItemId -and $_.ManifestHash -ieq $ExpectedHash} | ForEach-Object {$_.Check+':'+$_.Passed}) -join '; ';ProductionVerified=$false}})
    Write-WsmHtml $Path ('Isolated pilot / Pair '+$p.Manifest.PairId+' / Approval '+$p.Manifest.ApprovalId+' / generation '+$p.Manifest.Generation+' / manifest '+$ExpectedHash+' / stage '+$s.Stage+' / generated '+(Get-WsmUtc)) $rows
    $writer=New-Object IO.StreamWriter(($Path+'.txt'),$false,(New-Object Text.UTF8Encoding($false)));try{foreach($category in $script:Categories){$items=@($rows | Where-Object Category -CEQ $category);$writer.WriteLine(('=== '+$category+': '+$items.Count+' ==='));foreach($row in $items){$writer.WriteLine(($row | ConvertTo-Json -Compress -Depth 5))}}}finally{$writer.Dispose()}
    [pscustomobject]@{HTML=[IO.Path]::GetFullPath($Path);Text=[IO.Path]::GetFullPath($Path+'.txt');Items=$rows.Count}
}
