function Get-WsmSourceCandidateScanDirectory([string]$Workspace,$Profile,[string]$ScanId) {
    Assert-WsmId $ScanId
    $store=Get-WsmSourceCandidateStoreRoot $Workspace $Profile
    $scan=[IO.Path]::GetFullPath((Join-Path $store $ScanId))
    $prefix=[IO.Path]::GetFullPath($store).TrimEnd('\')+'\'
    if(-not $scan.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate scan escaped the enrolled source store.'}
    $scan
}

function Assert-WsmSourceCandidateArtifactForConfirmation($Artifact,[string]$ExpectedHash,$Profile,$Inventory,[string]$InventoryHash,[string]$SourceRoot,[string]$ScanDirectory) {
    Assert-WsmEnvelope $Artifact 'SourceCandidateDiscovery'
    if($Artifact.SchemaVersion -ne 1 -or [string]$Artifact.ToolVersion -cne $script:ToolVersion -or [string]$Artifact.Status -notin @('Succeeded','Partial','BudgetExhausted','ReplayBudgetExceeded','MetadataBudgetExceeded','AggregateEntryBudgetExceeded')){throw 'Candidate discovery artifact schema or status is unsupported.'}
    Assert-WsmId ([string]$Artifact.ScanId)
    if([string]$Artifact.SourceHostId -cne [string]$Profile.HostId -or [string]$Artifact.SourceFingerprint -ine [string]$Profile.Fingerprint -or [string]$Artifact.InventoryHash -ine $InventoryHash -or [long]$Artifact.InventoryRevision -ne [long]$Inventory.Revision){throw 'Candidate discovery artifact is stale for the verified source host or inventory.'}
    if([string]$Artifact.Root -ine [IO.Path]::GetFullPath($SourceRoot) -or [string]$Artifact.RootPhysicalIdentity -ine (Get-WsmPhysicalPath $SourceRoot)){throw 'Candidate discovery artifact belongs to another logical or physical source root.'}
    if([string]$Artifact.PolicyHash -notmatch '^[a-f0-9]{64}$' -or [string]$Artifact.PolicyVersion -ne '2' -or $Artifact.Candidates -isnot [array] -or $Artifact.Segments -isnot [array] -or $Artifact.Gaps -isnot [array] -or $Artifact.ExcludedAreas -isnot [array]){throw 'Candidate discovery artifact is malformed.'}
    if($Artifact.AuthoritativeApproval -ne $false -or $Artifact.ContentRead -ne $false){throw 'Candidate discovery artifact incorrectly claims approval or content access.'}
    $policy=Get-WsmSourceCandidatePolicy $SourceRoot $Inventory $Profile.WorkRoot
    # Public candidate scans use a fixed 5,000-entry segment budget. Recreate
    # that exact versioned policy identity before comparing it to the artifact.
    $policy|Add-Member NoteProperty MaxTotalEntries 5000
    $policy.PolicyHash=Get-WsmHashText (($policy|Select-Object * -ExcludeProperty PolicyHash|ConvertTo-Json -Depth 8 -Compress))
    if([string]$policy.PolicyHash -ine [string]$Artifact.PolicyHash -or [int]$policy.PolicyVersion -ne [int]$Artifact.PolicyVersion){throw 'Candidate discovery policy changed since the artifact was created; scan again.'}
    $checkpointPath=Join-Path $ScanDirectory 'checkpoint.json';Assert-WsmNoReparse $checkpointPath;if(-not [IO.File]::Exists($checkpointPath)){throw 'Candidate scan durable checkpoint is missing.'}
    $checkpoint=Read-WsmJson $checkpointPath;$checkpointStatus=[string]$checkpoint.Status
    if($checkpointStatus -ceq 'Succeeded'){$checkpoint.Status='BudgetExhausted'}
    Assert-WsmSourceCandidateCheckpoint $checkpoint ([string]$Artifact.ScanId) $Profile $Inventory $InventoryHash $SourceRoot $policy $ScanDirectory
    if([string]$Artifact.Status -cne $checkpointStatus -or [long]$Artifact.Coverage.ScannedEntries -ne [long]$checkpoint.ScannedEntryCount -or [long]$Artifact.Coverage.VisitedDirectories -ne @($checkpoint.VisitedDirectories).Count -or [long]$Artifact.Coverage.CandidateCount -ne @($checkpoint.Candidates).Count -or @($Artifact.Candidates).Count -ne @($checkpoint.Candidates).Count -or @($Artifact.Gaps).Count -ne @($checkpoint.Gaps).Count -or @($Artifact.ExcludedAreas).Count -ne @($checkpoint.ExcludedAreas).Count){throw 'Candidate artifact summary does not match its current durable source checkpoint.'}
    $checkpointCandidates=@{};foreach($savedCandidate in @($checkpoint.Candidates)){$checkpointCandidates[[string]$savedCandidate.CandidateId]=$savedCandidate}
    $segmentPrevious='';$expectedNumber=1
    foreach($descriptor in @($Artifact.Segments)){
        Assert-WsmFields $descriptor @('SegmentNumber','RelativePath','SHA256','PreviousSHA256','ScannedEntryCount','CandidateCount','GapCount','Status') @('SegmentNumber','RelativePath','SHA256','PreviousSHA256','ScannedEntryCount','CandidateCount','GapCount','Status')
        if([int]$descriptor.SegmentNumber -ne $expectedNumber -or [string]$descriptor.PreviousSHA256 -ine $segmentPrevious -or [string]$descriptor.SHA256 -notmatch '^[a-f0-9]{64}$'){throw 'Candidate scan immutable segment chain is invalid.'}
        $relative=[string]$descriptor.RelativePath;if($relative -notmatch '^segments/segment-[0-9]{3}\.json$'){throw 'Candidate scan segment path is not canonical.'};Assert-WsmRelativePath ($relative.Replace('/','\'))
        $segmentPath=[IO.Path]::GetFullPath((Join-Path $ScanDirectory ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
        $segmentPrefix=[IO.Path]::GetFullPath((Join-Path $ScanDirectory 'segments')).TrimEnd('\')+'\'
        if(-not $segmentPath.StartsWith($segmentPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate scan segment escaped its scan directory.'}
        Assert-WsmNoReparse $segmentPath
        if(-not [IO.File]::Exists($segmentPath) -or (Get-FileHash -LiteralPath $segmentPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$descriptor.SHA256){throw 'Candidate scan segment is missing or its hash changed.'}
        $segment=Read-WsmJson $segmentPath;Assert-WsmEnvelope $segment 'SourceCandidateDiscoverySegment'
        if([int]$segment.SegmentNumber -ne $expectedNumber -or [string]$segment.ScanId -cne [string]$Artifact.ScanId -or [string]$segment.SourceHostId -cne [string]$Artifact.SourceHostId -or [string]$segment.SourceFingerprint -ine [string]$Artifact.SourceFingerprint -or [string]$segment.InventoryHash -ine [string]$Artifact.InventoryHash -or [int]$segment.InventoryRevision -ne [int]$Artifact.InventoryRevision -or [string]$segment.PolicyHash -ine [string]$Artifact.PolicyHash -or [string]$segment.PreviousSHA256 -ine $segmentPrevious){throw 'Candidate scan segment identity does not match its artifact chain.'}
        $segmentPrevious=[string]$descriptor.SHA256;$expectedNumber++
    }
    if([long]$Artifact.Coverage.SegmentCount -ne @($Artifact.Segments).Count){throw 'Candidate artifact segment count does not match its immutable segment chain.'}
    $candidateIds=@{};$candidatePaths=@{}
    foreach($candidate in @($Artifact.Candidates)){
        Assert-WsmFields $candidate @('CandidateId','CandidateType','Path','Length','LastWriteUtc','Attributes','WorkloadReferenceCount','WorkloadReferences','MetadataOnly','UserDecisionRequired','AuthoritativeApproval') @('CandidateId','CandidateType','Path','LastWriteUtc','Attributes','MetadataOnly','UserDecisionRequired','AuthoritativeApproval')
        $id=[string]$candidate.CandidateId;$path=[IO.Path]::GetFullPath([string]$candidate.Path);$key=$path.ToLowerInvariant()
        if($id -notmatch '^[a-f0-9]{64}$' -or $candidateIds.ContainsKey($id) -or $candidatePaths.ContainsKey($key) -or $candidate.CandidateType -cnotin @('ExactFile','DirectoryRoot') -or $candidate.MetadataOnly -ne $true -or $candidate.UserDecisionRequired -ne $true -or $candidate.AuthoritativeApproval -ne $false){throw 'Candidate discovery row is malformed, duplicated, or incorrectly authoritative.'}
        $rootFull=[IO.Path]::GetFullPath($SourceRoot);$rootPrefix=$rootFull.TrimEnd('\')+'\';if($path -ine $rootFull -and -not $path.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate discovery row is outside the enrolled C volume.'}
        if(-not $checkpointCandidates.ContainsKey($id)){throw 'Candidate artifact introduced a row that is absent from its durable source checkpoint.'};$savedCandidate=$checkpointCandidates[$id]
        if([string]$savedCandidate.Path -ine $path -or [string]$savedCandidate.CandidateType -cne [string]$candidate.CandidateType -or [string]$savedCandidate.LastWriteUtc -cne [string]$candidate.LastWriteUtc -or [string]$savedCandidate.Attributes -cne [string]$candidate.Attributes -or ($candidate.CandidateType -ceq 'ExactFile' -and [long]$savedCandidate.Length -ne [long]$candidate.Length)){throw 'Candidate artifact metadata differs from its durable source checkpoint.'}
        $candidateIds[$id]=$candidate;$candidatePaths[$key]=$candidate
    }
    [pscustomobject]@{Candidates=$candidateIds;CandidatePaths=$candidatePaths;Policy=$policy}
}

function Get-WsmCandidateRelativePath([string]$Root,[string]$Path) {
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\');$pathFull=[IO.Path]::GetFullPath($Path)
    if($pathFull -ieq $rootFull){return ''}
    $prefix=$rootFull+'\';if(-not $pathFull.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate member escaped its confirmed root.'}
    $relative=$pathFull.Substring($prefix.Length);Assert-WsmRelativePath $relative;$relative
}

function Test-WsmSourceCandidateWriteTime([string]$CandidateTime,[DateTime]$CurrentTime) {
    # D1 stores the filesystem DateTime through PowerShell's culture-formatted
    # string conversion, which can drop subsecond ticks. Compare at that recorded
    # precision; the fresh streamed hash below supplies byte-level confirmation.
    try{$parsed=[DateTime]::Parse($CandidateTime,[Globalization.CultureInfo]::CurrentCulture,[Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime();$secondTicks=[long]10000000;return ([long]([Math]::Floor($parsed.Ticks/$secondTicks)) -eq [long]([Math]::Floor($CurrentTime.ToUniversalTime().Ticks/$secondTicks)))}catch{return $false}
}

function Get-WsmSourceCandidateFreshMembers([string]$ScopeRoot,[string]$CandidateType,$ArtifactRows,$Policy,[string]$Workspace,[string]$SourceVolumeRoot,[int]$MaxEntries=40000,[int]$MaxSeconds=25) {
    if($MaxEntries -lt 1 -or $MaxEntries -gt 40000 -or $MaxSeconds -lt 1 -or $MaxSeconds -gt 25){throw 'Candidate confirmation budget exceeds its fixed safety limit.'}
    $root=[IO.Path]::GetFullPath($ScopeRoot);Assert-WsmNoReparse $root
    if(-not [IO.Directory]::Exists($root)){throw 'Selected directory candidate is no longer available.'}
    Assert-WsmFileScopeGuard -Path $root -Mode Root -AllowDriveRoot
    $physicalRoot=Get-WsmPhysicalPath $root;$volumeRoot=Get-WsmPhysicalPath ([IO.Path]::GetPathRoot($root))
    if($physicalRoot -ine $volumeRoot -and -not $physicalRoot.StartsWith($volumeRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Selected directory no longer resolves beneath its enrolled physical source volume.'}
    if($root -ine [IO.Path]::GetPathRoot($root) -and (Test-WsmPathOverlap $root $Workspace)){throw 'Selected directory overlaps the source operation workspace.'}
    foreach($gap in @($ArtifactRows.Artifact.Gaps)){if([string]$gap.Path -ieq $root -or ([string]$gap.Path).StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Selected directory contains a prior discovery coverage gap; its contents cannot be confirmed as a complete set.'}}
    foreach($excluded in @($ArtifactRows.Artifact.ExcludedAreas)){if([string]$excluded.Path -ieq $root -or ([string]$excluded.Path).StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Selected directory contains an excluded protected or package area; its contents cannot be confirmed as a complete set.'}}
    $candidateFiles=@{};$candidateDirectories=@{}
    foreach($candidate in $ArtifactRows.CandidatePaths.Values){$path=[string]$candidate.Path;if($path -ieq $root -or $path.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){if($candidate.CandidateType -ceq 'ExactFile'){$candidateFiles[$path.ToLowerInvariant()]=$candidate}elseif($candidate.CandidateType -ceq 'DirectoryRoot'){$candidateDirectories[$path.ToLowerInvariant()]=$candidate}}}
    $files=New-Object 'System.Collections.Generic.List[object]';$directories=New-Object 'System.Collections.Generic.List[string]';$queue=New-Object 'System.Collections.Generic.Queue[string]';$queue.Enqueue($root);$clock=[Diagnostics.Stopwatch]::StartNew();$visited=0
    while($queue.Count){$directory=$queue.Dequeue();Assert-WsmNoReparse $directory
        try{$entries=[IO.Directory]::EnumerateFileSystemEntries($directory)}catch{throw 'Selected directory could not be completely enumerated; preserve its candidate and review the access gap.'}
        foreach($pathValue in $entries){if($clock.Elapsed.TotalSeconds -ge $MaxSeconds){throw 'Selected directory confirmation reached its time budget; no complete member set was produced.'};$visited++;if($visited -gt $MaxEntries){throw 'Selected directory confirmation reached its entry budget; no complete member set was produced.'}
            $path=[IO.Path]::GetFullPath([string]$pathValue);Assert-WsmNoReparse $path
            $reason=Test-WsmSourceCandidateExcludedPath $path $SourceVolumeRoot $Policy
            if($reason){throw 'Selected directory reaches a protected, installed-software, system, or excluded location.'}
            if($Policy.ExcludedAbsoluteRoots | Where-Object {$path -ieq [string]$_ -or $path.StartsWith(([string]$_).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}){throw 'Selected directory reaches a trusted installed-software root.'}
            if([IO.Directory]::Exists($path)){$directories.Add($path);$queue.Enqueue($path);continue}
            if(-not [IO.File]::Exists($path)){throw 'A selected directory entry changed during confirmation.'}
            $fileInfo=Get-Item -LiteralPath $path -Force -ErrorAction Stop;$pathKey=$path.ToLowerInvariant()
            if(-not $candidateFiles.ContainsKey($pathKey)){throw 'Selected directory contains a new or unreviewed file; scan again before confirming it.'}
            $row=$candidateFiles[$pathKey];if([long]$row.Length -ne [long]$fileInfo.Length -or -not (Test-WsmSourceCandidateWriteTime ([string]$row.LastWriteUtc) $fileInfo.LastWriteTimeUtc)){throw 'Selected file metadata changed since discovery; scan again before confirming it.'}
            $relative=Get-WsmCandidateRelativePath $root $path;Assert-WsmFileScopeGuard -Path $path -Mode ExactMembers -SourceRoot $root -RelativePath $relative -CheckPhysicalAlias
            Assert-WsmAssistiveFileTopology -Path $path
            $hash=Get-WsmCancellableFileHash $path $null 'SourceCandidateConfirmationHash'
            $files.Add([pscustomobject][ordered]@{RelativePath=$relative;SHA256=$hash.ToLowerInvariant();Length=[long]$fileInfo.Length;LastWriteUtc=[string]$fileInfo.LastWriteTimeUtc.ToString('o');CandidateId=[string]$row.CandidateId})
        }
    }
    foreach($candidatePath in $candidateFiles.Keys){if(-not @($files|Where-Object {$_.RelativePath -ieq (Get-WsmCandidateRelativePath $root ([string]$candidateFiles[$candidatePath].Path))}).Count){throw 'A discovered file is missing from the fresh directory scan; rescan and review the changed directory.'}}
    foreach($directory in $directories){$key=$directory.ToLowerInvariant();if(-not $candidateDirectories.ContainsKey($key)){throw 'Selected directory contains a new or unreviewed subdirectory; scan again before confirming it.'}}
    foreach($candidateDirectory in $candidateDirectories.Keys){$path=[string]$candidateDirectories[$candidateDirectory].Path;if($path -ieq $root){continue};if(-not @($directories|Where-Object {$_ -ieq $path}).Count){throw 'A discovered subdirectory is missing from the fresh directory scan; rescan and review the changed directory.'}}
    # Leaf-only empty directories become Directory members so ExactMembers can preserve them; ancestors of files or other directories are implied by their members.
    $empty=@($directories|Where-Object {$dir=$_; -not @($files|Where-Object {$_.RelativePath.StartsWith(((Get-WsmCandidateRelativePath $root $dir).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)}).Count -and -not @($directories|Where-Object {$_.StartsWith($dir.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}).Count})
    if(-not $files.Count -and -not $empty.Count){throw 'Selected directory has no file or empty-directory members; there is no content to preserve.'}
    $members=New-Object 'System.Collections.Generic.List[object]';foreach($file in $files){$members.Add($file)}
    foreach($emptyDirectory in $empty){
        $relative=Get-WsmCandidateRelativePath $root $emptyDirectory;Assert-WsmFileScopeGuard -Path $emptyDirectory -Mode ExactMembers -SourceRoot $root -RelativePath $relative -IsDirectory -PathOnly -CheckPhysicalAlias
        $row=$candidateDirectories[$emptyDirectory.ToLowerInvariant()];$info=Get-Item -LiteralPath $emptyDirectory -Force -ErrorAction Stop
        $members.Add([pscustomobject][ordered]@{RelativePath=$relative;SHA256='';Length=[long]0;LastWriteUtc=[string]$info.LastWriteTimeUtc.ToString('o');CandidateId=[string]$row.CandidateId;EntryType='Directory'})
    }
    # Q5(c): same blocked-name rule the ExactMembers import applies to every member (files and empty-directory members); reject at confirmation, not at import.
    foreach($member in $members){if(Test-WsmExactMemberBlockedName ([string]$member.RelativePath)){throw ('Selected directory contains a member whose name carries a blocked extension ('+[string]$member.RelativePath+'); ExactMembers would refuse it at import. Exclude or rename it before confirming.')}}
    @($members|Sort-Object { $_.RelativePath.ToLowerInvariant() })
}

function New-WsmSourceCandidateConfirmationCore([string]$Workspace,$Profile,$Inventory,[string]$InventoryHash,[string]$SourceRoot,[string]$ScanId,[string]$ExpectedCandidateHash,[string]$CandidateId,[int]$MaxEntries=40000,[int]$MaxSeconds=25) {
    $scanDirectory=Get-WsmSourceCandidateScanDirectory $Workspace $Profile $ScanId
    $scanLockPath=Join-Path $scanDirectory 'scan.lock';Assert-WsmNoReparse $scanLockPath;$scanLock=$null
    try{$scanLock=[IO.File]::Open($scanLockPath,'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{throw 'Candidate scan is active; wait and retry the confirmation after it exits.'}
    try{
        $candidatePath=Join-Path $scanDirectory 'candidates.json';Assert-WsmNoReparse $candidatePath
        if(-not [IO.File]::Exists($candidatePath) -or (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedCandidateHash.ToLowerInvariant()){throw 'Candidate artifact hash is stale or incorrect.'}
        $artifact=Read-WsmJson $candidatePath;$validated=Assert-WsmSourceCandidateArtifactForConfirmation $artifact $ExpectedCandidateHash $Profile $Inventory $InventoryHash $SourceRoot $scanDirectory
        if(-not $validated.Candidates.ContainsKey($CandidateId)){throw 'Selected candidate ID is absent from the hash-bound scan artifact.'}
        $candidate=$validated.Candidates[$CandidateId];$sourceRootFull=[IO.Path]::GetFullPath($SourceRoot);$candidatePathFull=[IO.Path]::GetFullPath([string]$candidate.Path)
        if($candidate.CandidateType -ceq 'ExactFile'){
            Assert-WsmNoReparse $candidatePathFull
            if(-not [IO.File]::Exists($candidatePathFull)){throw 'Selected exact-file candidate is no longer available.'}
            $scopeRoot=[IO.Path]::GetDirectoryName($candidatePathFull);$relative=Get-WsmCandidateRelativePath $scopeRoot $candidatePathFull
            if(Test-WsmSourceCandidateExcludedPath $candidatePathFull $sourceRootFull $validated.Policy){throw 'Selected exact-file candidate is now excluded by source path policy.'}
            if($validated.Policy.ExcludedAbsoluteRoots | Where-Object {$candidatePathFull -ieq [string]$_ -or $candidatePathFull.StartsWith(([string]$_).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)}){throw 'Selected exact-file candidate is beneath a trusted installed-software root.'}
            if(Test-WsmExactMemberBlockedName $relative){throw ('Selected exact-file candidate name carries a blocked extension ('+$relative+'); ExactMembers would refuse it at import.')}
            Assert-WsmFileScopeGuard -Path $candidatePathFull -Mode ExactMembers -SourceRoot $scopeRoot -RelativePath $relative -CheckPhysicalAlias
            Assert-WsmAssistiveFileTopology -Path $candidatePathFull
            $info=Get-Item -LiteralPath $candidatePathFull -Force -ErrorAction Stop
            if([long]$candidate.Length -ne [long]$info.Length -or -not (Test-WsmSourceCandidateWriteTime ([string]$candidate.LastWriteUtc) $info.LastWriteTimeUtc)){throw 'Selected exact-file metadata changed since discovery; scan again.'}
            $members=@([pscustomobject][ordered]@{RelativePath=$relative;SHA256=(Get-WsmCancellableFileHash $candidatePathFull $null 'SourceCandidateConfirmationHash').ToLowerInvariant();Length=[long]$info.Length;LastWriteUtc=[string]$info.LastWriteTimeUtc.ToString('o');CandidateId=[string]$candidate.CandidateId})
        }else{
            $scopeRoot=$candidatePathFull
            $members=Get-WsmSourceCandidateFreshMembers $scopeRoot $candidate.CandidateType ([pscustomobject]@{Artifact=$artifact;CandidatePaths=$validated.CandidatePaths}) $validated.Policy $Workspace $sourceRootFull $MaxEntries $MaxSeconds
        }
        $physicalRoot=Get-WsmPhysicalPath $sourceRootFull;$physicalScope=Get-WsmPhysicalPath $scopeRoot
        if($physicalScope -ine $physicalRoot -and -not $physicalScope.StartsWith($physicalRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Selected candidate no longer resolves within the enrolled physical C volume.'}
        $selection=[pscustomobject][ordered]@{CandidateId=[string]$candidate.CandidateId;CandidateType=[string]$candidate.CandidateType;CandidatePath=$candidatePathFull;ScopeRoot=[IO.Path]::GetFullPath($scopeRoot);Members=[object[]]$members;WorkloadReferences=@($candidate.WorkloadReferences);WorkloadReferenceCount=[int]$candidate.WorkloadReferenceCount}
        $body=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceCandidateConfirmation';ConfirmationId=[Guid]::NewGuid().ToString('D');ScanId=[string]$artifact.ScanId;SourceHostId=[string]$Profile.HostId;SourceFingerprint=([string]$Profile.Fingerprint).ToLowerInvariant();InventoryHash=$InventoryHash.ToLowerInvariant();InventoryRevision=[int]$Inventory.Revision;CandidateArtifactHash=$ExpectedCandidateHash.ToLowerInvariant();CandidateSetHash=Get-WsmHashText (($artifact.Candidates|ConvertTo-Json -Depth 30 -Compress));Root=$sourceRootFull;RootPhysicalIdentity=$physicalRoot;PolicyVersion=[int]$artifact.PolicyVersion;PolicyHash=[string]$artifact.PolicyHash;ScanStatus=[string]$artifact.Status;CoverageClaim=[string]$artifact.Coverage.Claim;Selection=$selection;AuthoritativeApproval=$false;ContentRead=$true;CreatedUtc=(Get-WsmUtc);SHA256=''}
        $withoutHash=[ordered]@{};foreach($property in $body.PSObject.Properties){if($property.Name -cne 'SHA256'){$withoutHash[$property.Name]=$property.Value}};$body.SHA256=Get-WsmHashText ($withoutHash|ConvertTo-Json -Depth 40 -Compress)
        # Stage beside the scan checkpoint. A per-confirmation subdirectory makes
        # valid source workspaces exceed the legacy PowerShell 5.1 MAX_PATH limit.
        $stagedPath=Join-Path $scanDirectory ('.confirmation-'+$body.ConfirmationId+'.tmp.json');Write-WsmJson $stagedPath $body
        $confirmationHash=(Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $materialReference='assistive/materials/source-candidate/'+$confirmationHash+'/confirmation.json'
        $materialPath=[IO.Path]::GetFullPath((Join-Path $Workspace ($materialReference.Replace('/',[IO.Path]::DirectorySeparatorChar))))
        $materialRoot=[IO.Path]::GetFullPath((Join-Path $Workspace 'assistive/materials')).TrimEnd('\')+'\'
        if(-not $materialPath.StartsWith($materialRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate confirmation material escaped the enrolled source workspace.'}
        $materialDirectory=Split-Path -Parent $materialPath;[void](New-WsmOutputOwnedDirectory $materialDirectory)
        if([IO.File]::Exists($materialPath)){
            Assert-WsmNoReparse $materialPath
            if((Get-FileHash -LiteralPath $materialPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $confirmationHash){throw 'Existing content-addressed Source material has different bytes.'}
            [IO.File]::Delete($stagedPath)
        }else{
            try{[IO.File]::Move($stagedPath,$materialPath)}catch [IO.IOException]{if(-not [IO.File]::Exists($materialPath) -or (Get-FileHash -LiteralPath $materialPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $confirmationHash){throw 'Could not create immutable Source confirmation material.'};[IO.File]::Delete($stagedPath)}
            Assert-WsmNoReparse $materialPath
        }
        [pscustomobject][ordered]@{Status='Confirmed';ConfirmationId=[string]$body.ConfirmationId;ConfirmationPath=[IO.Path]::GetFullPath($materialPath);MaterialReference=$materialReference;ConfirmationHash=$confirmationHash;CandidateId=[string]$candidate.CandidateId;CandidateArtifactHash=$ExpectedCandidateHash.ToLowerInvariant();InventoryHash=$InventoryHash.ToLowerInvariant();InventoryRevision=[int]$Inventory.Revision;MemberCount=@($members).Count;MemberSetHash=Get-WsmHashText (($members|ConvertTo-Json -Depth 20 -Compress));AuthoritativeApproval=$false}
    }finally{if($scanLock){$scanLock.Dispose()}}
}

function Export-WsmSourceCandidateConfirmation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$ScanId,[Parameter(Mandatory)][string]$ExpectedCandidateHash,[Parameter(Mandatory)][string]$CandidateId,[Parameter(DontShow)][object[]]$Jobs=@(),[int]$MaxEntries=40000,[int]$MaxSeconds=25)
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'Candidate confirmation is available only in the enrolled Source workspace.'}
    $state=Get-WsmWizardState $Workspace '' Source;$verified=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId)
    if(-not $verified -or $verified.Ambiguous -or [string]$verified.SHA256 -ine [string]$state.SourceInventoryHash -or [long]$verified.Inventory.Revision -ne [long]$state.SourceInventoryRevision){throw 'Candidate confirmation requires a fresh verified Source inventory job.'}
    $root=Get-WsmSourceCandidateRoot $Workspace $profile
    New-WsmSourceCandidateConfirmationCore $Workspace $profile $verified.Inventory $verified.SHA256 $root $ScanId $ExpectedCandidateHash $CandidateId $MaxEntries $MaxSeconds
}

function Assert-WsmSourceCandidateConfirmation($Confirmation,[string]$ExpectedHash) {
    Assert-WsmEnvelope $Confirmation 'SourceCandidateConfirmation'
    Assert-WsmId ([string]$Confirmation.ConfirmationId);Assert-WsmId ([string]$Confirmation.ScanId);Assert-WsmId ([string]$Confirmation.SourceHostId)
    if($Confirmation.SchemaVersion -ne 1 -or [string]$Confirmation.ToolVersion -cne $script:ToolVersion -or [string]$Confirmation.SourceFingerprint -notmatch '^[a-f0-9]{64}$' -or [string]$Confirmation.InventoryHash -notmatch '^[a-f0-9]{64}$' -or [long]$Confirmation.InventoryRevision -lt 1 -or [string]$Confirmation.CandidateArtifactHash -notmatch '^[a-f0-9]{64}$' -or [string]$Confirmation.CandidateSetHash -notmatch '^[a-f0-9]{64}$' -or [string]$Confirmation.RootPhysicalIdentity -notmatch '^\\Device\\HarddiskVolume' -or [string]$Confirmation.PolicyHash -notmatch '^[a-f0-9]{64}$' -or [string]$Confirmation.SHA256 -notmatch '^[a-f0-9]{64}$' -or [int]$Confirmation.PolicyVersion -ne 2 -or [string]$Confirmation.ScanStatus -notin @('Succeeded','Partial','BudgetExhausted','ReplayBudgetExceeded','MetadataBudgetExceeded','AggregateEntryBudgetExceeded')){throw 'Source candidate confirmation identity, version, or hash fields are malformed.'}
    if($Confirmation.AuthoritativeApproval -isnot [bool] -or $Confirmation.AuthoritativeApproval -ne $false -or $Confirmation.ContentRead -isnot [bool] -or $Confirmation.ContentRead -ne $true -or $Confirmation.Selection.Members -isnot [array] -or -not $Confirmation.Selection.Members.Count -or $Confirmation.Selection.Members.Count -gt 40000 -or $Confirmation.Selection.WorkloadReferences -isnot [array] -or $Confirmation.Selection.WorkloadReferences.Count -gt 10000){throw 'Source candidate confirmation is incomplete, over budget, or incorrectly authoritative.'}
    $candidateType=[string]$Confirmation.Selection.CandidateType;if($candidateType -cnotin @('ExactFile','DirectoryRoot') -or [string]$Confirmation.Selection.CandidateId -notmatch '^[a-f0-9]{64}$' -or [int]$Confirmation.Selection.WorkloadReferenceCount -ne $Confirmation.Selection.WorkloadReferences.Count){throw 'Source candidate selection type, identity, or workload-reference count is invalid.'}
    $root=ConvertTo-WsmCanonicalPath ([string]$Confirmation.Root);$candidatePath=ConvertTo-WsmCanonicalPath ([string]$Confirmation.Selection.CandidatePath);$scopeRoot=ConvertTo-WsmCanonicalPath ([string]$Confirmation.Selection.ScopeRoot)
    if($root -notmatch '^[cC]:\\' -or $candidatePath -ine [string]$Confirmation.Selection.CandidatePath -or $scopeRoot -ine [string]$Confirmation.Selection.ScopeRoot){throw 'Source candidate confirmation root or canonical selection paths are invalid.'}
    if($candidatePath -ine $root -and -not $candidatePath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source candidate selection is outside the confirmed C root.'}
    if($scopeRoot -ine $root -and -not $scopeRoot.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source candidate scope is outside the confirmed C root.'}
    if($candidateType -ceq 'DirectoryRoot' -and ($candidatePath -ine $scopeRoot -or ($candidatePath -ine $root -and -not $candidatePath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)))){throw 'DirectoryRoot selection is not bound to its canonical scope under C root.'}
    if($candidateType -ceq 'ExactFile' -and ($candidatePath -ine [IO.Path]::GetFullPath((Join-Path $scopeRoot ([string]$Confirmation.Selection.Members[0].RelativePath))) -or [IO.Path]::GetDirectoryName($candidatePath).TrimEnd('\') -ine $scopeRoot.TrimEnd('\') -or $Confirmation.Selection.Members.Count -ne 1)){throw 'ExactFile selection is not a single file rooted at its canonical parent.'}
    $body=[ordered]@{};foreach($property in $Confirmation.PSObject.Properties){if($property.Name -cne 'SHA256'){$body[$property.Name]=$property.Value}}
    if((Get-WsmHashText ($body|ConvertTo-Json -Depth 40 -Compress)) -ine [string]$Confirmation.SHA256){throw 'Source candidate confirmation body hash mismatch.'}
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'An independently obtained confirmation SHA256 is required.'}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($member in @($Confirmation.Selection.Members)){Assert-WsmFields $member @('RelativePath','SHA256','Length','LastWriteUtc','CandidateId','EntryType') @('RelativePath','SHA256','Length','LastWriteUtc','CandidateId');Assert-WsmRelativePath ([string]$member.RelativePath);$isDirectoryMember=Test-WsmExactDirectoryMember $member;if($member.PSObject.Properties['EntryType'] -and -not $isDirectoryMember){throw 'Source candidate confirmation member EntryType is unsupported.'};if($isDirectoryMember -and ($candidateType -cne 'DirectoryRoot' -or [string]$member.SHA256 -cne '' -or [long]$member.Length -ne 0)){throw 'Source candidate confirmation directory member is malformed.'};if(-not $seen.Add([string]$member.RelativePath) -or (-not $isDirectoryMember -and [string]$member.SHA256 -notmatch '^[a-f0-9]{64}$') -or ($member.Length -isnot [int] -and $member.Length -isnot [long]) -or [long]$member.Length -lt 0 -or [string]$member.CandidateId -notmatch '^[a-f0-9]{64}$' -or ($candidateType -ceq 'ExactFile' -and [string]$member.CandidateId -cne [string]$Confirmation.Selection.CandidateId)){throw 'Source candidate confirmation member row is malformed or duplicated.'}}
    foreach($reference in @($Confirmation.Selection.WorkloadReferences)){Assert-WsmFields $reference @('ConsumerItemId','FieldPointer','ReferenceKind','Path','Required','ReviewRequired') @('ConsumerItemId','FieldPointer','ReferenceKind','Path','Required','ReviewRequired');if([string]$reference.ConsumerItemId -notmatch '^[a-f0-9]{64}$' -or $reference.FieldPointer -isnot [string] -or $reference.FieldPointer.Length -gt 2048 -or [string]$reference.FieldPointer -match '[\x00-\x1f]' -or [string]$reference.ReferenceKind -notmatch '^[A-Za-z][A-Za-z0-9]{0,63}$' -or $reference.Required -isnot [bool] -or $reference.ReviewRequired -isnot [bool] -or (ConvertTo-WsmCanonicalPath ([string]$reference.Path)) -ine [string]$reference.Path -or ([string]$reference.Path -ine $root -and -not ([string]$reference.Path).StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Source candidate workload reference is malformed or outside the C root.'}}
    $true
}

function Get-WsmSourceCandidateStableNaturalKey($Confirmation) {
    $candidatePath=ConvertTo-WsmCanonicalPath ([string]$Confirmation.Selection.CandidatePath)
    $candidateType=[string]$Confirmation.Selection.CandidateType
    if($candidateType -cnotin @('ExactFile','DirectoryRoot')){throw 'Unsupported source candidate type.'}
    'source-candidate-confirmation:'+([string]$Confirmation.SourceHostId).ToLowerInvariant()+':'+$candidateType.ToLowerInvariant()+':'+$candidatePath.ToLowerInvariant()
}

function Get-WsmSourceCandidateMaterialReference([string]$Hash) {
    if($Hash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Candidate confirmation material hash is invalid.'}
    'assistive/materials/source-candidate/'+$Hash.ToLowerInvariant()+'/confirmation.json'
}

function Test-WsmExactDirectoryMember($Member) {
    # File members carry no EntryType (keeps pre-directory hashes stable); only the literal 'Directory' marks a directory member.
    $null -ne $Member -and $Member.PSObject.Properties['EntryType'] -and [string]$Member.EntryType -ceq 'Directory'
}

function Get-WsmSourceCandidateMemberSetHash($Members) {
    $rows=@($Members|ForEach-Object {$row=[ordered]@{RelativePath=([string]$_.RelativePath).Replace('/','\').ToLowerInvariant();SHA256=([string]$_.SHA256).ToLowerInvariant();Length=[long]$_.Length};if(Test-WsmExactDirectoryMember $_){$row.EntryType='Directory'};[pscustomobject]$row}|Sort-Object RelativePath)
    Get-WsmHashText (($rows|ConvertTo-Json -Depth 12 -Compress))
}

function Assert-WsmSourceCandidateItemSpecMatchesConfirmation([string]$Workspace,$Catalog,$Item,$Confirmation,[string]$ConfirmationHash) {
    if(-not $Item.PSObject.Properties['MigrationSpec'] -or $Item.MigrationSpec.Adapter -cne 'FileScope' -or [string]$Item.MigrationSpec.ContentSelection -cne 'ExactMembers'){throw 'Source candidate catalog item does not have its confirmed ExactMembers scope.'}
    $spec=$Item.MigrationSpec;$expectedRoot=ConvertTo-WsmCanonicalPath ([string]$Confirmation.Selection.ScopeRoot)
    if((ConvertTo-WsmCanonicalPath ([string]$spec.SourcePath)) -ine $expectedRoot -or (ConvertTo-WsmCanonicalPath ([string]$spec.TargetPath)) -ine $expectedRoot){throw 'Source candidate spec no longer uses the exact confirmed source root as its destination.'}
    $confirmationIndex=@{};$confirmationMembers=@(foreach($member in @($Confirmation.Selection.Members)){$key=([string]$member.RelativePath).Replace('/','\').ToLowerInvariant();$confirmationIndex[$key]=$member;$row=[ordered]@{RelativePath=$key;SHA256=([string]$member.SHA256).ToLowerInvariant();Length=[long]$member.Length};if(Test-WsmExactDirectoryMember $member){$row.EntryType='Directory'};[pscustomobject]$row});$confirmationMembers=@($confirmationMembers|Sort-Object RelativePath)
    $specMembers=@(foreach($member in @($spec.Members)){$key=([string]$member.RelativePath).Replace('/','\').ToLowerInvariant();if(-not $confirmationIndex.ContainsKey($key)){throw 'Source candidate MigrationSpec introduced an unconfirmed member.'};$length=[long]$confirmationIndex[$key].Length;if($member.PSObject.Properties['Length'] -and [long]$member.Length -ne $length){throw 'Source candidate MigrationSpec member length differs from its confirmation.'};if((Test-WsmExactDirectoryMember $member) -ne (Test-WsmExactDirectoryMember $confirmationIndex[$key])){throw 'Source candidate MigrationSpec member entry type differs from its confirmation.'};$row=[ordered]@{RelativePath=$key;SHA256=([string]$member.SHA256).ToLowerInvariant();Length=$length};if(Test-WsmExactDirectoryMember $member){$row.EntryType='Directory'};[pscustomobject]$row});$specMembers=@($specMembers|Sort-Object RelativePath)
    if((Get-WsmSourceCandidateMemberSetHash $confirmationMembers) -ine (Get-WsmSourceCandidateMemberSetHash $specMembers)){throw 'Source candidate MigrationSpec member set no longer matches its immutable confirmation.'}
    $reference=Get-WsmSourceCandidateMaterialReference $ConfirmationHash
    if(-not @($Catalog.Assistive.MaterialReferences|Where-Object {[string]$_.Reference -ceq $reference -and [string]$_.SHA256 -ieq $ConfirmationHash}).Count){throw 'Source candidate confirmation is not protected by the catalog material-reference contract.'}
    $true
}

function Get-WsmSourceCandidateConfirmationMaterial([string]$Workspace,$Catalog,$Item) {
    if([string]$Item.NaturalKey -notmatch '^manual:(source-candidate-confirmation:[^:]+:[^:]+:.+)$'){throw 'Candidate confirmation provenance is absent from the Manager item identity.'}
    $natural=[string]$matches[1]
    if([string]$Item.Evidence -notmatch '^(assistive/materials/source-candidate/[a-f0-9]{64}/confirmation\.json)(?:;|$)'){throw 'Candidate confirmation material reference is not canonical.'}
    $materialRelative=[string]$matches[1];$expectedHash=([regex]::Match($materialRelative,'source-candidate/([a-f0-9]{64})/')).Groups[1].Value
    $references=@($Catalog.Assistive.MaterialReferences|Where-Object {[string]$_.Reference -ceq $materialRelative -and [string]$_.SHA256 -ieq $expectedHash});if($references.Count -ne 1){throw 'Candidate confirmation does not have exactly one hash-bound catalog material reference.'}
    $materialPath=[IO.Path]::GetFullPath((Join-Path $Workspace ($materialRelative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
    $prefix=[IO.Path]::GetFullPath((Join-Path $Workspace 'assistive/materials')).TrimEnd('\')+'\';if(-not $materialPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate confirmation material escaped its Manager workspace.'}
    Assert-WsmNoReparse $materialPath;if(-not [IO.File]::Exists($materialPath) -or (Get-FileHash -LiteralPath $materialPath -Algorithm SHA256).Hash.ToLowerInvariant() -ine $expectedHash){throw 'Manager candidate confirmation material no longer matches its immutable reference.'}
    $confirmation=Read-WsmJson $materialPath;Assert-WsmSourceCandidateConfirmation $confirmation $expectedHash|Out-Null
    if((Get-WsmSourceCandidateStableNaturalKey $confirmation) -cne $natural -or [string]$confirmation.InventoryHash -ine [string]$Catalog.Assistive.SourceSnapshot.SHA256 -or [int]$confirmation.InventoryRevision -ne [int]$Catalog.InventoryRevision -or [string]$confirmation.SourceHostId -cne [string]$Catalog.Source.HostId -or [string]$confirmation.SourceFingerprint -ine [string]$Catalog.Source.Fingerprint){throw 'Candidate confirmation provenance no longer matches the Manager source snapshot or stable candidate identity.'}
    [pscustomobject]@{Path=$materialPath;Reference=$materialRelative;Hash=$expectedHash;Confirmation=$confirmation}
}

function Get-WsmSourceCandidateConfirmationReview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId)
    $catalog=Get-WsmCatalog $Workspace $PairId
    if($catalog.SchemaVersion -ne 3 -or -not $catalog.PSObject.Properties['Assistive']){throw 'Candidate confirmation review requires an Assistive schema 3 Manager catalog.'}
    $items=@($catalog.Items|Where-Object ItemId -CEQ $ItemId);if($items.Count -ne 1){throw 'Unknown candidate-derived Manager item.'};$item=$items[0]
    if(-not $item.ManualEntry){throw 'Manager item is not a source-confirmed ManualItem.'}
    $material=Get-WsmSourceCandidateConfirmationMaterial $Workspace $catalog $item;$confirmation=$material.Confirmation
    Assert-WsmSourceCandidateItemSpecMatchesConfirmation $Workspace $catalog $item $confirmation $material.Hash | Out-Null
    [pscustomobject][ordered]@{Kind='SourceCandidateConfirmationReview';PairId=$PairId;ItemId=$ItemId;Decision=[string]$item.Decision;DecisionRevision=[int]$catalog.DecisionRevision;SelectionRevision=[int]$catalog.Assistive.Selections.Revision;ConfirmationId=[string]$confirmation.ConfirmationId;ConfirmationHash=$material.Hash;MaterialReference=$material.Reference;ScanId=[string]$confirmation.ScanId;CandidateId=[string]$confirmation.Selection.CandidateId;CandidateType=[string]$confirmation.Selection.CandidateType;CandidateArtifactHash=[string]$confirmation.CandidateArtifactHash;CandidateSetHash=[string]$confirmation.CandidateSetHash;InventoryHash=[string]$confirmation.InventoryHash;InventoryRevision=[int]$confirmation.InventoryRevision;Root=[string]$confirmation.Root;ScopeRoot=[string]$confirmation.Selection.ScopeRoot;RootPhysicalIdentity=[string]$confirmation.RootPhysicalIdentity;MemberCount=@($confirmation.Selection.Members).Count;Members=@($confirmation.Selection.Members|ForEach-Object {$row=[ordered]@{RelativePath=[string]$_.RelativePath;SHA256=[string]$_.SHA256;Length=[long]$_.Length;CandidateId=[string]$_.CandidateId};if(Test-WsmExactDirectoryMember $_){$row.EntryType='Directory'};[pscustomobject]$row});WorkloadReferences=@($confirmation.Selection.WorkloadReferences);ContentSelection='ExactMembers';TransferChannel='C';Status=$(if($item.Decision -ceq 'Pending'){'ReviewRequired'}else{'Imported'});AuthoritativeApproval=$false}
}

function Assert-WsmSourceCandidateItemsBeforeSeal([string]$Workspace,$Catalog,$IncludedItems) {
    foreach($item in @($IncludedItems|Where-Object {[string]$_.NaturalKey -like 'manual:source-candidate-confirmation:*'})){
        $material=Get-WsmSourceCandidateConfirmationMaterial $Workspace $Catalog $item
        Assert-WsmSourceCandidateItemSpecMatchesConfirmation $Workspace $Catalog $item $material.Confirmation $material.Hash | Out-Null
        $selection=@($Catalog.Assistive.Selections.Items|Where-Object {$_.ItemId -ceq $item.ItemId -and $_.Selected});if($selection.Count -ne 1){throw 'Included source candidate item is not explicitly selected in the Assistive catalog.'}
    }
    $true
}

function Import-WsmSourceCandidateConfirmation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$TargetPath,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][int]$ExpectedRevision)
    $confirmation=Read-WsmTrustedJson $Path $ExpectedHash;Assert-WsmSourceCandidateConfirmation $confirmation $ExpectedHash
    if([string]$confirmation.Selection.CandidateType -notin @('ExactFile','DirectoryRoot')){throw 'Unknown source candidate type cannot be imported.'}
    $catalog=Get-WsmCatalog $Workspace $PairId
    if($catalog.SchemaVersion -ne 3 -or -not $catalog.PSObject.Properties['Assistive']){throw 'Candidate confirmation import requires an Assistive schema 3 Manager catalog.'}
    if($catalog.DecisionRevision -ne $ExpectedRevision){throw 'Manager review changed; refresh the confirmation review before import.'}
    if([string]$catalog.Source.HostId -cne [string]$confirmation.SourceHostId -or [string]$catalog.Source.Fingerprint -ine [string]$confirmation.SourceFingerprint -or [string]$catalog.InventoryHash -ine [string]$confirmation.InventoryHash -or [int]$catalog.InventoryRevision -ne [int]$confirmation.InventoryRevision -or [string]$catalog.Assistive.SourceSnapshot.SHA256 -ine [string]$confirmation.InventoryHash -or [int]$catalog.Assistive.SourceSnapshot.InventoryRevision -ne [int]$confirmation.InventoryRevision){throw 'Confirmation belongs to a different or stale Source inventory; Manager did not access the source volume.'}
    $scopeRoot=ConvertTo-WsmCanonicalPath ([string]$confirmation.Selection.ScopeRoot);$targetRoot=ConvertTo-WsmCanonicalPath $TargetPath
    if($targetRoot -ine $scopeRoot){throw 'Candidate confirmation import cannot remap the selected source root; review and package the exact original location.'}
    if([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Evidence)){throw 'Candidate-derived ManualItems require an owner and evidence reference.'}
    $confirmationRef=Get-WsmSourceCandidateMaterialReference $ExpectedHash
    $materialPath=[IO.Path]::GetFullPath((Join-Path $Workspace ($confirmationRef.Replace('/',[IO.Path]::DirectorySeparatorChar))));$materialPrefix=[IO.Path]::GetFullPath((Join-Path $Workspace 'assistive/materials')).TrimEnd('\')+'\';if(-not $materialPath.StartsWith($materialPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate confirmation material path escaped the Manager workspace.'}
    Assert-WsmNoReparse $Path;$sourceSnapshot=Read-WsmFileSnapshot $Path $ExpectedHash;if([string]$sourceSnapshot.Hash -ine $ExpectedHash.ToLowerInvariant()){throw 'Candidate confirmation changed during Manager import.'}
    if(-not [IO.File]::Exists($materialPath)){
        $materialDirectory=Split-Path -Parent $materialPath;[void](New-WsmOutputOwnedDirectory $materialDirectory)
        [IO.File]::Copy([IO.Path]::GetFullPath($Path),$materialPath,$false)
        Assert-WsmNoReparse $materialPath
        if((Get-FileHash -LiteralPath $materialPath -Algorithm SHA256).Hash.ToLowerInvariant() -ine $ExpectedHash.ToLowerInvariant()){[IO.File]::Delete($materialPath);throw 'Copied candidate confirmation failed its independent hash check.'}
    }elseif((Get-FileHash -LiteralPath $materialPath -Algorithm SHA256).Hash.ToLowerInvariant() -ine $ExpectedHash.ToLowerInvariant()){throw 'Existing Manager candidate confirmation material has changed.'}
    $naturalKey=Get-WsmSourceCandidateStableNaturalKey $confirmation
    $itemNaturalKey='manual:'+$naturalKey
    $spec=[pscustomobject][ordered]@{Adapter='FileScope';SourcePath=$scopeRoot;TargetPath=$scopeRoot;ContentSelection='ExactMembers';Members=@($confirmation.Selection.Members|ForEach-Object {$row=[ordered]@{RelativePath=[string]$_.RelativePath;SHA256=[string]$_.SHA256};if(Test-WsmExactDirectoryMember $_){$row.EntryType='Directory'};[pscustomobject]$row});ExcludedRelativePaths=@();TransferChannel='C';Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='Block';Owner=$Owner;Evidence=($confirmationRef+'; Confirmation SHA256 '+$ExpectedHash.ToLowerInvariant()+'; '+$Evidence)}
    Assert-WsmMigrationSpec $spec -Assistive
    $updated=Invoke-WsmLocked $Workspace {
        $current=Get-WsmCatalog $Workspace $PairId;if($current.DecisionRevision -ne $ExpectedRevision){throw 'Manager review changed during candidate confirmation import; no catalog changes were committed.'}
        if($current.SchemaVersion -ne 3 -or [string]$current.Source.HostId -cne [string]$confirmation.SourceHostId -or [string]$current.Source.Fingerprint -ine [string]$confirmation.SourceFingerprint -or [string]$current.InventoryHash -ine [string]$confirmation.InventoryHash -or [int]$current.InventoryRevision -ne [int]$confirmation.InventoryRevision){throw 'Source inventory changed during candidate confirmation import.'}
        $matches=@($current.Items|Where-Object {[string]$_.NaturalKey -ceq $itemNaturalKey});if($matches.Count -gt 1){throw 'Duplicate stable source candidate identities exist in the Manager catalog.'}
        $item=$null;$createdNew=$false
        if($matches.Count){$item=$matches[0];if(-not $item.ManualEntry -or [string]$item.Kind -cne 'ManualItem'){throw 'Stable candidate identity collides with a non-manual Manager item.'};$selection=@($current.Assistive.Selections.Items|Where-Object ItemId -CEQ $item.ItemId);if($selection.Count -ne 1){throw 'Existing source candidate item has no unique Assistive selection.'}}
        else{
            $candidateName='Confirmed C data: '+[string]$confirmation.Selection.CandidatePath
            $item=New-WsmItem ([string]$current.Source.HostId) Storage ManualItem $candidateName $itemNaturalKey @{EvidenceReference=$confirmationRef} @() Unsupported
            $item=Get-WsmReviewDefaults $item
            foreach($field in @(@{Name='Decision';Value='Pending'},@{Name='Reason';Value='New source candidate requires Manager review.'},@{Name='ReviewedBy';Value=''},@{Name='ReviewedUtc';Value=''},@{Name='Present';Value=$true},@{Name='ManualEntry';Value=$true},@{Name='Owner';Value=$Owner},@{Name='Evidence';Value=$confirmationRef})){ $item|Add-Member NoteProperty $field.Name $field.Value -Force }
            $current.Items=@($current.Items)+@($item)
            $current.Assistive.Selections.Items=@($current.Assistive.Selections.Items)+@([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;SourceRevision=[int]$current.InventoryRevision;Selected=$true;Reason='New source candidate requires separate Manager selection and approval.';UpdatedUtc=(Get-WsmUtc)})
            $current.Assistive.Selections.Revision++;$createdNew=$true
        }
        # R15: byte-identical material with the same owner, evidence and resulting spec changes nothing; keep the reviewed decision and the approval.
        if(-not $createdNew){$sameSpec=$null;if($item.PSObject.Properties['MigrationSpec']){$sameSpec=$item.MigrationSpec};$sameMaterial=@($current.Assistive.MaterialReferences|Where-Object {[string]$_.Reference -ceq $confirmationRef -and [string]$_.SHA256 -ieq $ExpectedHash.ToLowerInvariant()});if($sameSpec -and $item.Present -and [string]$item.Status -ceq 'Success' -and [string]$item.Owner -ceq $Owner -and [string]$item.Evidence -ceq $confirmationRef -and $sameMaterial.Count -eq 1 -and (Get-WsmHashText ($sameSpec|ConvertTo-Json -Depth 30 -Compress)) -ceq (Get-WsmHashText ($spec|ConvertTo-Json -Depth 30 -Compress))){return $current}}
        $oldDecision=[string]$item.Decision;$oldSpec=$null;if($item.PSObject.Properties['MigrationSpec']){$oldSpec=$item.MigrationSpec};$item.Status='Success';$item.Present=$true;$item.Owner=$Owner;$item.Evidence=$confirmationRef
        $item.Settings=[pscustomobject]@{EvidenceReference=$confirmationRef};$item.SettingsHash=Get-WsmHashText ($item.Settings|ConvertTo-Json -Depth 20 -Compress)
        if(-not $createdNew -and $oldDecision -ceq 'Include'){$item.Decision='Pending';$item.Reason='Source candidate evidence changed; review the updated exact member set.';$item.ReviewedBy='';$item.ReviewedUtc=''}
        $item|Add-Member NoteProperty MigrationSpec $spec -Force
        $materialMatches=@($current.Assistive.MaterialReferences|Where-Object {[string]$_.Reference -ceq $confirmationRef})
        if($materialMatches.Count -gt 1 -or ($materialMatches.Count -eq 1 -and [string]$materialMatches[0].SHA256 -ine $ExpectedHash.ToLowerInvariant())){throw 'Catalog contains a conflicting immutable confirmation material reference.'}
        if(-not $materialMatches.Count){$current.Assistive.MaterialReferences=@($current.Assistive.MaterialReferences)+@([pscustomobject][ordered]@{Reference=$confirmationRef;SHA256=$ExpectedHash.ToLowerInvariant();CreatedUtc=[string]$confirmation.CreatedUtc})}
        $current.DecisionRevision++;$current.Approval=$null;Clear-WsmAssistiveComparison $current
        $current.History=@($current.History)+@([pscustomobject][ordered]@{Actor=(Get-WsmExecutionActor);Revision=$current.DecisionRevision;Action='SourceCandidateConfirmation';ItemId=[string]$item.ItemId;ConfirmationHash=$ExpectedHash.ToLowerInvariant();MemberCount=@($confirmation.Selection.Members).Count;PriorDecision=$oldDecision;PriorSpecChanged=([bool]($oldSpec -and (Get-WsmHashText ($oldSpec|ConvertTo-Json -Depth 30 -Compress)) -cne (Get-WsmHashText ($spec|ConvertTo-Json -Depth 30 -Compress))));Utc=(Get-WsmUtc)})
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $current;$current
    }
    $item=@($updated.Items|Where-Object {[string]$_.NaturalKey -ceq $itemNaturalKey})[0]
    [pscustomobject][ordered]@{Status=$(if([int]$updated.DecisionRevision -eq $ExpectedRevision){'NoChange'}else{'ImportedReviewRequired'});PairId=$PairId;ItemId=[string]$item.ItemId;ConfirmationId=[string]$confirmation.ConfirmationId;MaterialReference=$confirmationRef;Decision=[string]$item.Decision;DecisionRevision=[int]$updated.DecisionRevision;SelectionRevision=[int]$updated.Assistive.Selections.Revision;MemberCount=@($confirmation.Selection.Members).Count;ContentSelection='ExactMembers';AuthoritativeApproval=$false}
}
