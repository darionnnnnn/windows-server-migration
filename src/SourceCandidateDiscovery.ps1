function Get-WsmSourceCandidatePolicy([string]$Root,$Inventory,[string]$Workspace) {
    $excludedAbsolute=New-Object 'System.Collections.Generic.List[string]'
    $coverageGaps=New-Object 'System.Collections.Generic.List[string]'
    $systemDirectory=[Environment]::SystemDirectory
    if($systemDirectory){$windowsRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($systemDirectory.TrimEnd('\')));if($windowsRoot){$excludedAbsolute.Add([IO.Path]::GetFullPath($windowsRoot))}}
    foreach($known in @([Environment]::GetFolderPath('ProgramFiles'),[Environment]::GetFolderPath('ProgramFilesX86'))){if($known){$excludedAbsolute.Add([IO.Path]::GetFullPath($known))}}
    # The durable scan output must never become its own candidate input.
    if($Workspace){$excludedAbsolute.Add([IO.Path]::GetFullPath($Workspace))}
    $softwareRoots=Get-WsmTrustedInstalledSoftwareRoots $Inventory
    foreach($installRoot in @($softwareRoots.Roots)){if($installRoot.Path){$excludedAbsolute.Add([IO.Path]::GetFullPath([string]$installRoot.Path))}}
    if([string]$softwareRoots.Status -cne 'Captured'){$coverageGaps.Add('Installed-software root coverage is '+[string]$softwareRoots.Status+'; package directories may remain undiscovered or appear as candidates.')}
    foreach($diagnostic in @($softwareRoots.Diagnostics)){$coverageGaps.Add([string]$diagnostic)}
    $rootPrefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $excludedAbsolute=@($excludedAbsolute.ToArray()|Where-Object {$_ -ine [IO.Path]::GetFullPath($Root).TrimEnd('\') -and $_.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)}|Sort-Object -Unique)
    $policy=[pscustomobject][ordered]@{
        PolicyVersion=2
        RootKind='CVolumeRoot'
        RootPhysicalIdentity=(Get-WsmPhysicalPath $Root)
        SoftwareRootCoverageStatus=[string]$softwareRoots.Status
        SoftwareRootCoverageGaps=@($coverageGaps.ToArray())
        MaxEntriesPerRun=4000
        MaxSecondsPerRun=25
        CheckpointEvery=20
        MaxSegments=8
        # Keep aggregate metadata well below the shared 128 MiB JSON contract.
        MaxAggregateEntries=40000
        MaxAggregatePathBytes=4194304
        MaxWorkloadReferenceCount=10000
        MaxWorkloadReferenceBytes=2097152
        # Keep only discovery-specific exclusions not already owned by the shared FileScope guard.
        ExcludedRelativeRoots=@('Config.Msi')
        ExcludedAbsoluteRoots=$excludedAbsolute
        ReparsePolicy='DoNotFollow; record coverage gap'
        CandidatePolicy='MetadataOnly; directory roots and exact file paths; never create FileScope'
    }
    $policy|Add-Member NoteProperty PolicyHash (Get-WsmHashText ($policy|ConvertTo-Json -Depth 8 -Compress))
    $policy
}

function Get-WsmSourceCandidateRoot([string]$Workspace,$Profile) {
    if(-not $Profile -or $Profile.Role -cne 'Source'){throw 'C candidate discovery requires the enrolled local Source role.'}
    if([IO.Path]::GetFullPath($Profile.WorkRoot) -ine [IO.Path]::GetFullPath($Workspace)){throw 'C candidate discovery workspace differs from the enrolled Source profile.'}
    $identity=Get-WsmMachineIdentity
    if([string]$identity.Fingerprint -ine [string]$Profile.Fingerprint){throw 'C candidate discovery must run on the enrolled Source host; the local machine fingerprint differs.'}
    $root='C:\'
    try{$drive=New-Object IO.DriveInfo($root);if($drive.DriveType -ne [IO.DriveType]::Fixed -or -not $drive.IsReady){throw 'C volume is not ready as a local fixed disk.'}}catch{throw 'The enrolled Source C volume is unavailable as a local fixed disk; no other drive will be substituted.'}
    [IO.Path]::GetFullPath($root)
}

function Get-WsmSourceCandidateStoreRoot([string]$Workspace,$Profile) {
    $hostRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path $Workspace 'hosts') $Profile.Fingerprint))
    $prefix=[IO.Path]::GetFullPath((Join-Path $Workspace 'hosts')).TrimEnd('\')+'\'
    if(-not $hostRoot.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Source candidate store escaped its enrolled host directory.'}
    $root=Join-Path $hostRoot 'source-candidate-scans'
    [void](New-WsmOutputOwnedDirectory $root)
    [IO.Path]::GetFullPath($root)
}

function Test-WsmSourceCandidateExcludedPath([string]$Path,[string]$Root,$Policy) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\');$rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if($full -ieq $rootFull){return $null}
    foreach($excluded in @($Policy.ExcludedAbsoluteRoots)){if($full -ieq [string]$excluded -or $full.StartsWith(([string]$excluded).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return [string]$excluded}}
    $relative=$full.Substring($rootFull.Length).TrimStart('\')
    if(Get-Command Get-WsmFileScopeGuardReason -CommandType Function -ErrorAction SilentlyContinue){
        # The scanner root is C:\ in production. Fixture roots are mapped to the same
        # volume-relative path so this test exercises the exact shared protected-boundary rule.
        $guardPath=Join-Path ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Root))) $relative
        $guardReason=Get-WsmFileScopeGuardReason $guardPath
        if($guardReason){return ('FileScope guard: '+$guardReason)}
    }
    foreach($excluded in @($Policy.ExcludedRelativeRoots)){
        if($relative -ieq $excluded -or $relative.StartsWith($excluded.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return [string]$excluded}
    }
    $null
}

function Get-WsmSourceCandidateDirectoryState([string]$Path,[string]$SourceRoot,$Policy) {
    try{Assert-WsmNoReparse $Path}catch{return [pscustomobject]@{Status='Gap';Reason='ReparsePointNotFollowed';Detail=$_.Exception.Message;Item=$null}}
    try{$info=Get-Item -LiteralPath $Path -Force -ErrorAction Stop}catch [System.UnauthorizedAccessException]{return [pscustomobject]@{Status='Gap';Reason='PermissionDenied';Detail=$_.Exception.Message;Item=$null}}catch [System.Management.Automation.ItemNotFoundException]{return [pscustomobject]@{Status='Gap';Reason='DirectoryUnavailable';Detail=$_.Exception.Message;Item=$null}}catch [System.IO.DirectoryNotFoundException]{return [pscustomobject]@{Status='Gap';Reason='DirectoryUnavailable';Detail=$_.Exception.Message;Item=$null}}catch [System.IO.FileNotFoundException]{return [pscustomobject]@{Status='Gap';Reason='DirectoryUnavailable';Detail=$_.Exception.Message;Item=$null}}catch [System.IO.IOException]{return [pscustomobject]@{Status='Gap';Reason='DirectoryUnavailable';Detail=$_.Exception.Message;Item=$null}}catch{return [pscustomobject]@{Status='Gap';Reason='DirectoryMetadataFailed';Detail=$_.Exception.Message;Item=$null}}
    if(-not $info.PSIsContainer){return [pscustomobject]@{Status='Gap';Reason='DirectoryUnavailable';Detail='Queued path is no longer a directory.';Item=$null}}
    try{$physical=Get-WsmPhysicalPath ([string]$info.FullName)}catch{return [pscustomobject]@{Status='Gap';Reason='PhysicalPathResolutionFailed';Detail=$_.Exception.Message;Item=$null}}
    $physicalRoot=[string]$Policy.RootPhysicalIdentity;$physicalRootTrimmed=$physicalRoot.TrimEnd('\');$physicalTrimmed=[string]$physical.TrimEnd('\')
    if($physicalTrimmed -ine $physicalRootTrimmed -and -not $physicalTrimmed.StartsWith($physicalRootTrimmed+'\',[StringComparison]::OrdinalIgnoreCase)){return [pscustomobject]@{Status='Gap';Reason='PhysicalPathOutsideCVolume';Detail='Resolved directory is outside the enrolled physical C volume.';Item=$null}}
    [pscustomobject]@{Status='Ready';Reason='';Detail='';Item=$info}
}

function Assert-WsmSourceCandidateCheckpoint($Checkpoint,[string]$ScanId,$Profile,$Inventory,[string]$InventoryHash,[string]$SourceRoot,$Policy,[string]$ScanDirectory='') {
    Assert-WsmFields $Checkpoint @('SchemaVersion','ToolVersion','Kind','ScanId','Status','SourceHostId','SourceFingerprint','InventoryHash','InventoryRevision','Root','RootPhysicalIdentity','PolicyVersion','PolicyHash','Queue','CurrentDirectory','CurrentDirectoryWriteUtc','CurrentDirectorySeen','Candidates','VisitedDirectories','ExcludedAreas','Gaps','ScannedEntryCount','SegmentNumber','SegmentEntryCount','Segments','SegmentStartCandidateCount','SegmentStartGapCount','SegmentStartExcludedCount','SegmentStartVisitedCount','LegacyBaselineEntryCount','CreatedUtc','UpdatedUtc','LastCheckpointUtc') @('SchemaVersion','ToolVersion','Kind','ScanId','Status','SourceHostId','SourceFingerprint','InventoryHash','InventoryRevision','Root','RootPhysicalIdentity','PolicyVersion','PolicyHash','Queue','CurrentDirectory','CurrentDirectoryWriteUtc','CurrentDirectorySeen','Candidates','VisitedDirectories','ExcludedAreas','Gaps','ScannedEntryCount','SegmentNumber','SegmentEntryCount','Segments','SegmentStartCandidateCount','SegmentStartGapCount','SegmentStartExcludedCount','SegmentStartVisitedCount','LegacyBaselineEntryCount','CreatedUtc','UpdatedUtc','LastCheckpointUtc')
    if($Checkpoint.SchemaVersion -ne 1 -or $Checkpoint.Kind -cne 'SourceCandidateDiscovery' -or [string]$Checkpoint.ToolVersion -cne $script:ToolVersion -or [string]$Checkpoint.ScanId -cne $ScanId -or $Checkpoint.Status -cnotin @('Running','Partial','BudgetExhausted','ReplayBudgetExceeded','MetadataBudgetExceeded','AggregateEntryBudgetExceeded')){throw 'Source candidate checkpoint schema or status is unsupported.'}
    if([string]$Checkpoint.SourceHostId -cne [string]$Profile.HostId -or [string]$Checkpoint.SourceFingerprint -ine [string]$Profile.Fingerprint -or [string]$Checkpoint.InventoryHash -ine $InventoryHash -or [long]$Checkpoint.InventoryRevision -ne [long]$Inventory.Revision){throw 'Source candidate checkpoint is stale for the currently verified source host or inventory.'}
    if([string]$Checkpoint.Root -ine [IO.Path]::GetFullPath($SourceRoot) -or [string]$Checkpoint.RootPhysicalIdentity -ine [string]$Policy.RootPhysicalIdentity -or [int]$Checkpoint.PolicyVersion -ne [int]$Policy.PolicyVersion -or [string]$Checkpoint.PolicyHash -ine [string]$Policy.PolicyHash){throw 'Source candidate checkpoint belongs to a different scan root, physical volume, or policy.'}
    if($Checkpoint.Queue -isnot [array] -or $Checkpoint.Candidates -isnot [array] -or $Checkpoint.VisitedDirectories -isnot [array] -or $Checkpoint.CurrentDirectorySeen -isnot [array] -or $Checkpoint.Gaps -isnot [array] -or $Checkpoint.ExcludedAreas -isnot [array] -or $Checkpoint.Segments -isnot [array]){throw 'Source candidate checkpoint collections are malformed.'}
    $expectedSegments=([int]$Checkpoint.SegmentNumber-1);if($Checkpoint.Status -cin @('BudgetExhausted','ReplayBudgetExceeded','MetadataBudgetExceeded','AggregateEntryBudgetExceeded') -and @($Checkpoint.Segments).Count -eq [int]$Checkpoint.SegmentNumber){$expectedSegments=[int]$Checkpoint.SegmentNumber}elseif($Checkpoint.Status -ceq 'Succeeded'){$expectedSegments=[int]$Checkpoint.SegmentNumber}
    if(@($Checkpoint.Candidates).Count -gt [int]$Policy.MaxAggregateEntries -or @($Checkpoint.VisitedDirectories).Count -gt [int]$Policy.MaxAggregateEntries -or @($Checkpoint.Queue).Count -gt [int]$Policy.MaxAggregateEntries -or [long]$Checkpoint.ScannedEntryCount -gt [long]$Policy.MaxAggregateEntries -or [int]$Checkpoint.SegmentNumber -lt 1 -or [int]$Checkpoint.SegmentNumber -gt [int]$Policy.MaxSegments -or [long]$Checkpoint.SegmentEntryCount -lt 0 -or [long]$Checkpoint.SegmentEntryCount -gt [long]$Policy.MaxTotalEntries -or @($Checkpoint.Segments).Count -ne $expectedSegments){throw 'Source candidate checkpoint exceeds its bounded segment contract.'}
    foreach($path in @($Checkpoint.Queue)+@($Checkpoint.VisitedDirectories)+@($Checkpoint.CurrentDirectorySeen)+@($(if($Checkpoint.CurrentDirectory){[string]$Checkpoint.CurrentDirectory}else{@()}))){
        if(-not $path){throw 'Source candidate checkpoint contains an empty directory path.'};$full=[IO.Path]::GetFullPath([string]$path);$prefix=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')+'\';if($full -ine [IO.Path]::GetFullPath($SourceRoot) -and -not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Source candidate checkpoint contains a directory outside the enrolled C volume.'}
    }
    if([long]$Checkpoint.ScannedEntryCount -lt 0){throw 'Source candidate checkpoint entry count is invalid.'}
    $priorHash='';$priorEntryCount=0L
    for($i=0;$i -lt @($Checkpoint.Segments).Count;$i++){
        $segment=$Checkpoint.Segments[$i];$expectedNumber=$i+1
        Assert-WsmFields $segment @('SegmentNumber','RelativePath','SHA256','PreviousSHA256','ScannedEntryCount','CandidateCount','GapCount','Status') @('SegmentNumber','RelativePath','SHA256','PreviousSHA256','ScannedEntryCount','CandidateCount','GapCount','Status')
        if([int]$segment.SegmentNumber -ne $expectedNumber -or [string]$segment.RelativePath -cne ('segments/segment-'+$expectedNumber.ToString('D3')+'.json') -or [string]$segment.PreviousSHA256 -cne $priorHash -or [string]$segment.SHA256 -notmatch '^[a-f0-9]{64}$'){throw 'Source candidate segment chain is malformed or out of order.'}
        if($ScanDirectory){$segmentPath=Join-Path $ScanDirectory ([string]$segment.RelativePath -replace '/', '\');Assert-WsmNoReparse $segmentPath;if(-not [IO.File]::Exists($segmentPath) -or (Get-FileHash -LiteralPath $segmentPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$segment.SHA256){throw 'A prior immutable source candidate segment is missing or has been tampered with.'};$saved=Read-WsmJson $segmentPath;if([int]$saved.SegmentNumber -ne $expectedNumber -or [string]$saved.PreviousSHA256 -cne $priorHash -or [string]$saved.ScanId -cne $ScanId -or [string]$saved.SourceHostId -cne [string]$Profile.HostId -or [string]$saved.SourceFingerprint -ine [string]$Profile.Fingerprint -or [string]$saved.InventoryHash -ine $InventoryHash -or [int]$saved.InventoryRevision -ne [int]$Inventory.Revision -or [string]$saved.Root -ine [IO.Path]::GetFullPath($SourceRoot) -or [string]$saved.RootPhysicalIdentity -ine [string]$Policy.RootPhysicalIdentity -or [int]$saved.PolicyVersion -ne [int]$Policy.PolicyVersion -or [string]$saved.PolicyHash -ine [string]$Policy.PolicyHash -or [long]$saved.ScannedEntryCount -ne [long]$segment.ScannedEntryCount -or @($saved.Candidates).Count -ne [int]$segment.CandidateCount -or @($saved.Gaps).Count -ne [int]$segment.GapCount -or [string]$saved.Status -cne [string]$segment.Status){throw 'A prior immutable source candidate segment is bound to a different scan, source, inventory, root, or policy.'};if($Checkpoint.Status -ceq 'BudgetExhausted' -and $expectedNumber -eq [int]$Checkpoint.SegmentNumber){$savedQueue=@($saved.Frontier.Queue)-join "`n";$currentQueue=@($Checkpoint.Queue)-join "`n";$savedSeen=@($saved.Frontier.CurrentDirectorySeen)-join "`n";$currentSeen=@($Checkpoint.CurrentDirectorySeen)-join "`n";if($savedQueue -cne $currentQueue -or [string]$saved.Frontier.CurrentDirectory -cne [string]$Checkpoint.CurrentDirectory -or [string]$saved.Frontier.CurrentDirectoryWriteUtc -cne [string]$Checkpoint.CurrentDirectoryWriteUtc -or $savedSeen -cne $currentSeen){throw 'The current checkpoint frontier no longer matches its immutable exhausted segment.'}}}
        $priorHash=[string]$segment.SHA256;$priorEntryCount += [long]$segment.ScannedEntryCount
    }
    $expectedPriorEntries=([long]$Checkpoint.ScannedEntryCount-[long]$Checkpoint.SegmentEntryCount-[long]$Checkpoint.LegacyBaselineEntryCount);if($Checkpoint.Status -cin @('Succeeded','BudgetExhausted','ReplayBudgetExceeded','MetadataBudgetExceeded','AggregateEntryBudgetExceeded') -and @($Checkpoint.Segments).Count -eq [int]$Checkpoint.SegmentNumber){$expectedPriorEntries=[long]$Checkpoint.ScannedEntryCount-[long]$Checkpoint.LegacyBaselineEntryCount};if($priorEntryCount -ne $expectedPriorEntries){throw 'Source candidate segment totals do not match the durable checkpoint entry count.'}
}

function New-WsmSourceCandidateCheckpoint([string]$ScanId,$Profile,$Inventory,[string]$InventoryHash,[string]$Root,$Policy) {
    $now=Get-WsmUtc
    [pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceCandidateDiscovery';ScanId=$ScanId;Status='Running';SourceHostId=[string]$Profile.HostId;SourceFingerprint=([string]$Profile.Fingerprint).ToLowerInvariant();InventoryHash=$InventoryHash.ToLowerInvariant();InventoryRevision=[int]$Inventory.Revision;Root=[IO.Path]::GetFullPath($Root);RootPhysicalIdentity=[string]$Policy.RootPhysicalIdentity;PolicyVersion=[int]$Policy.PolicyVersion;PolicyHash=[string]$Policy.PolicyHash;Queue=@([IO.Path]::GetFullPath($Root));CurrentDirectory='';CurrentDirectoryWriteUtc='';CurrentDirectorySeen=@();Candidates=@();VisitedDirectories=@();ExcludedAreas=@();Gaps=@();ScannedEntryCount=0L;SegmentNumber=1;SegmentEntryCount=0L;Segments=@();SegmentStartCandidateCount=0;SegmentStartGapCount=0;SegmentStartExcludedCount=0;SegmentStartVisitedCount=0;LegacyBaselineEntryCount=0L;CreatedUtc=$now;UpdatedUtc=$now;LastCheckpointUtc=$now}
}

function Save-WsmSourceCandidateSegment([string]$ScanDirectory,$Checkpoint,$Profile,[string]$InventoryHash,[string]$Root,$Policy,[string]$Status) {
    $segmentNumber=[int]$Checkpoint.SegmentNumber;$relative='segments/segment-'+$segmentNumber.ToString('D3')+'.json';$segmentDir=Join-Path $ScanDirectory 'segments';[void](New-WsmOutputOwnedDirectory $segmentDir)
    $segmentPath=Join-Path $segmentDir ('segment-'+$segmentNumber.ToString('D3')+'.json');$previousHash='';if(@($Checkpoint.Segments).Count){$previousHash=[string]$Checkpoint.Segments[-1].SHA256}
    $segment=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceCandidateDiscoverySegment';ScanId=[string]$Checkpoint.ScanId;SegmentNumber=$segmentNumber;PreviousSHA256=$previousHash;Status=$Status;SourceHostId=[string]$Profile.HostId;SourceFingerprint=([string]$Profile.Fingerprint).ToLowerInvariant();InventoryHash=$InventoryHash.ToLowerInvariant();InventoryRevision=[int]$Checkpoint.InventoryRevision;Root=[IO.Path]::GetFullPath($Root);RootPhysicalIdentity=[string]$Policy.RootPhysicalIdentity;PolicyVersion=[int]$Policy.PolicyVersion;PolicyHash=[string]$Policy.PolicyHash;ScannedEntryCount=[long]$Checkpoint.SegmentEntryCount;Candidates=@($Checkpoint.Candidates|Select-Object -Skip ([int]$Checkpoint.SegmentStartCandidateCount));Gaps=@($Checkpoint.Gaps|Select-Object -Skip ([int]$Checkpoint.SegmentStartGapCount));ExcludedAreas=@($Checkpoint.ExcludedAreas|Select-Object -Skip ([int]$Checkpoint.SegmentStartExcludedCount));VisitedDirectories=@($Checkpoint.VisitedDirectories|Select-Object -Skip ([int]$Checkpoint.SegmentStartVisitedCount));Frontier=[pscustomobject][ordered]@{Queue=@($Checkpoint.Queue);CurrentDirectory=[string]$Checkpoint.CurrentDirectory;CurrentDirectoryWriteUtc=[string]$Checkpoint.CurrentDirectoryWriteUtc;CurrentDirectorySeen=@($Checkpoint.CurrentDirectorySeen)};CreatedUtc=[string]$Checkpoint.LastCheckpointUtc}
    Assert-WsmEnvelope $segment 'SourceCandidateDiscoverySegment'
    if([IO.File]::Exists($segmentPath)){
        Assert-WsmNoReparse $segmentPath;$orphan=Read-WsmJson $segmentPath
        # A crash can leave the immutable segment file before its descriptor reaches
        # checkpoint.json. Preserve its original timestamp, then compare every byte
        # of its regenerated binding/frontier/content; never overwrite the orphan.
        if(-not $orphan.PSObject.Properties['CreatedUtc'] -or [string]::IsNullOrWhiteSpace([string]$orphan.CreatedUtc)){throw 'An orphan source candidate segment has no valid creation timestamp.'}
        $segment.CreatedUtc=[string]$orphan.CreatedUtc;$expectedHash=Get-WsmHashText ($segment|ConvertTo-Json -Depth 40)
        if((Get-FileHash -LiteralPath $segmentPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedHash.ToLowerInvariant()){throw 'An orphan or existing immutable source candidate segment does not match this checkpoint binding, frontier, and content.'}
    }else{Write-WsmJson $segmentPath $segment}
    $descriptor=[pscustomobject][ordered]@{SegmentNumber=$segmentNumber;RelativePath=$relative;SHA256=(Get-FileHash -LiteralPath $segmentPath -Algorithm SHA256).Hash.ToLowerInvariant();PreviousSHA256=$previousHash;ScannedEntryCount=[long]$Checkpoint.SegmentEntryCount;CandidateCount=@($segment.Candidates).Count;GapCount=@($segment.Gaps).Count;Status=$Status}
    if(@($Checkpoint.Segments).Count -lt $segmentNumber){$Checkpoint.Segments=@($Checkpoint.Segments)+@($descriptor)}elseif([string]$Checkpoint.Segments[$segmentNumber-1].SHA256 -cne [string]$descriptor.SHA256){throw 'Existing source candidate segment identity changed.'}
    $descriptor
}

function Add-WsmSourceCandidateGap($Checkpoint,[string]$Path,[string]$Reason,[string]$Detail='') {
    $safeDetail=$Detail;if($safeDetail.Length -gt 256){$safeDetail=$safeDetail.Substring(0,256)}
    $key=([string]$Path+'|'+$Reason).ToLowerInvariant()
    if(-not @($Checkpoint.Gaps|Where-Object {([string]$_.Path+'|'+[string]$_.Reason).ToLowerInvariant() -ceq $key}).Count){$Checkpoint.Gaps=@($Checkpoint.Gaps)+@([pscustomobject][ordered]@{Path=[string]$Path;Reason=$Reason;Detail=$safeDetail;ObservedUtc=(Get-WsmUtc)})}
}

# N9d / R7-04：安裝根內容可見性。
# 安裝根仍然整塊排除、不備份、不產生候選；這裡只是唯讀、受預算限制地列出根內檔案並分類，結果只放進排除區域的 Contents（計數與少量樣本）。
# 分類（每個檔案恰好一類）：
#   Bundle                本體：PE 檔（看檔頭 MZ/PE，不看副檔名）、安裝程式登記的檔案、反安裝中繼資料（unins000.*）。
#   SuspectedBusinessData 疑似業務資料：非 PE，且位於資料／報表類子目錄，或修改時間晚於「可信的」安裝時間。
#   Unknown               未知：其餘檔案（例如設定檔、說明文件）。
# 資料／報表類子目錄名單（比對相對路徑中任一層目錄名稱，不分大小寫）：
#   data, reports, report, output, outputs, export, exports, log, logs, db, database, backup, backups, archive, archives, upload, uploads, import, imports, attachments
# 預算與既有探索相同：筆數（MaxEntriesPerRun）、路徑位元組（MaxAggregatePathBytes，每筆以 4 倍計）、時間（MaxSecondsPerRun）。超過就標 Complete=false 並記錄已列筆數。
# 檔案內容只讀檔頭前 64 位元組判斷是否為 PE；不讀其他內容、不執行、不跟隨重新解析點。
$script:WsmBundleDataDirectoryNames=@('data','reports','report','output','outputs','export','exports','log','logs','db','database','backup','backups','archive','archives','upload','uploads','import','imports','attachments')
$script:WsmBundleSamplesPerClass=10
$script:WsmBundleFileListCap=500
$script:WsmBundleMaxDepth=32

function Test-WsmSourceCandidatePeFile([string]$Path) {
    # $true／$false；讀不到回 $null。只看前 64 位元組與 e_lfanew 指到的 4 位元組簽章。
    $stream=$null
    try{
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $head=New-Object byte[] 64;$read=$stream.Read($head,0,64)
        if($read -lt 64 -or $head[0] -ne 0x4d -or $head[1] -ne 0x5a){return $false}
        $offset=[BitConverter]::ToInt32($head,60)
        if($offset -lt 64 -or $offset -gt 16777216 -or $stream.Length -lt ($offset+4)){return $false}
        [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin);$signature=New-Object byte[] 4
        return ($stream.Read($signature,0,4) -eq 4 -and $signature[0] -eq 0x50 -and $signature[1] -eq 0x45 -and $signature[2] -eq 0 -and $signature[3] -eq 0)
    }catch{return $null}finally{if($stream){$stream.Dispose()}}
}

function Get-WsmSourceCandidateBundleContents([string]$Root,[int]$MaxEntries=4000,[int]$MaxSeconds=25,[long]$MaxPathBytes=4194304,[object]$InstallTimeUtc=$null,[string[]]$RegisteredFiles=@()) {
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\');$prefixLength=$rootFull.Length+1
    $installTime=$null;if($InstallTimeUtc -is [DateTime]){$candidateTime=([DateTime]$InstallTimeUtc).ToUniversalTime();if($candidateTime.Year -ge 1995 -and $candidateTime -le [DateTime]::UtcNow.AddDays(1)){$installTime=$candidateTime}}
    $registered=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);foreach($file in @($RegisteredFiles)){if($file){try{[void]$registered.Add([IO.Path]::GetFullPath([string]$file))}catch{}}}
    $dataNames=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);foreach($name in $script:WsmBundleDataDirectoryNames){[void]$dataNames.Add($name)}
    $counts=[ordered]@{Bundle=0L;SuspectedBusinessData=0L;Unknown=0L};$sampleLists=@{Bundle=(New-Object 'System.Collections.Generic.List[object]');SuspectedBusinessData=(New-Object 'System.Collections.Generic.List[object]');Unknown=(New-Object 'System.Collections.Generic.List[object]')}
    $bundleFiles=New-Object 'System.Collections.Generic.List[string]';$bundleFilesTruncated=$false
    [long]$listed=0;[long]$directories=0;[long]$skippedReparse=0;[long]$unreadable=0;[long]$pathBytes=0;$incompleteReason=''
    $watch=[Diagnostics.Stopwatch]::StartNew();$pending=New-Object 'System.Collections.Generic.Stack[object]';$pending.Push(@($rootFull,0))
    while($pending.Count -gt 0 -and -not $incompleteReason){
        $frame=$pending.Pop();$dir=[string]$frame[0];$depth=[int]$frame[1]
        try{$entries=[IO.Directory]::EnumerateFileSystemEntries($dir)}catch{$unreadable++;continue}
        try{
            foreach($entry in $entries){
                if($listed -ge $MaxEntries){$incompleteReason='EntryBudget';break}
                if($watch.Elapsed.TotalSeconds -ge $MaxSeconds){$incompleteReason='TimeBudget';break}
                $entryBytes=[long][Text.Encoding]::UTF8.GetByteCount([string]$entry)*4
                if($pathBytes+$entryBytes -gt $MaxPathBytes){$incompleteReason='PathBytesBudget';break}
                try{$attributes=[IO.File]::GetAttributes($entry)}catch{$unreadable++;continue}
                if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$skippedReparse++;continue}
                $listed++;$pathBytes+=$entryBytes
                if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){
                    $directories++
                    if($depth -lt $script:WsmBundleMaxDepth){$pending.Push(@([string]$entry,($depth+1)))}else{$unreadable++}
                    continue
                }
                $relative=([string]$entry).Substring($prefixLength);$leaf=[IO.Path]::GetFileName([string]$entry)
                try{$info=New-Object IO.FileInfo ([string]$entry);$length=[long]$info.Length;$written=$info.LastWriteTimeUtc}catch{$unreadable++;continue}
                $class='';$why=''
                $isPe=Test-WsmSourceCandidatePeFile ([string]$entry)
                if($isPe -eq $true){$class='Bundle';$why='PEHeader'}
                elseif($registered.Contains([string]$entry)){$class='Bundle';$why='RegisteredByInstaller'}
                elseif($leaf -imatch '^unins\d{3}\.(exe|dat|msg)$'){$class='Bundle';$why='UninstallMetadata'}
                else{
                    $segments=@($relative.Split('\'));$hit=''
                    for($i=0;$i -lt $segments.Count-1;$i++){if($dataNames.Contains($segments[$i])){$hit=$segments[$i];break}}
                    if($hit){$class='SuspectedBusinessData';$why='DataDirectory:'+$hit}
                    elseif($installTime -and $written -gt $installTime){$class='SuspectedBusinessData';$why='ModifiedAfterInstall'}
                    else{$class='Unknown';$why='NoSignal'}
                }
                $counts[$class]=[long]$counts[$class]+1
                if($sampleLists[$class].Count -lt $script:WsmBundleSamplesPerClass){$sampleLists[$class].Add([pscustomobject][ordered]@{RelativePath=$relative;Bytes=$length;Class=$class;Why=$why})}
                if($class -ceq 'Bundle'){if($bundleFiles.Count -lt $script:WsmBundleFileListCap){$bundleFiles.Add($relative)}else{$bundleFilesTruncated=$true}}
            }
        }catch{$unreadable++}
    }
    if(-not $incompleteReason -and $pending.Count -gt 0){$incompleteReason='EntryBudget'}
    [pscustomobject][ordered]@{
        Listed=$listed;Directories=$directories;Complete=(-not $incompleteReason);IncompleteReason=$incompleteReason;SkippedReparse=$skippedReparse;Unreadable=$unreadable
        Counts=[pscustomobject]$counts;SamplesPerClass=[int]$script:WsmBundleSamplesPerClass
        Samples=@($sampleLists.SuspectedBusinessData.ToArray())+@($sampleLists.Bundle.ToArray())+@($sampleLists.Unknown.ToArray())
        InstallTimeUtc=$(if($installTime){$installTime.ToString('o')}else{''});InstallTimeTrusted=[bool]$installTime;HeaderBytesRead=64
        BundleFiles=@($bundleFiles.ToArray());BundleFilesTruncated=$bundleFilesTruncated
    }
}

function Get-WsmSourceCandidateInstallRootInfo($Inventory) {
    # 信任的安裝根。安裝時間目前沒有可信來源：SoftwareCatalog 的合約（MigrationContracts）不接受額外的 InstallDate 證據欄位，
    # 所以這裡一律回傳空值，「修改時間晚於安裝時間」的訊號只在呼叫端明確傳入可信時間時才會啟用，不從登錄檔字串猜。
    $result=New-Object 'System.Collections.Generic.List[object]'
    try{$trusted=Get-WsmTrustedInstalledSoftwareRoots $Inventory}catch{return @()}
    foreach($root in @($trusted.Roots)){
        if(-not $root.Path){continue}
        $result.Add([pscustomobject]@{Path=[IO.Path]::GetFullPath([string]$root.Path).TrimEnd('\');SoftwareId=[string]$root.SoftwareId;InstallTimeUtc=$null})
    }
    @($result.ToArray())
}

function Get-WsmSourceCandidateExcludedCategory([string]$Skip,[object[]]$InstallRoots,[string]$Workspace) {
    # 結構化類別：BundleExcluded（安裝根或 Program Files）／ProtectedArea（其餘：Windows、工具工作區、Config.Msi、FileScope 保護路徑）。
    if($Skip -like 'FileScope guard: *'){return 'ProtectedArea'}
    $trimmed=$Skip.TrimEnd('\')
    foreach($root in @($InstallRoots)){if([string]$root.Path -ieq $trimmed){return 'BundleExcluded'}}
    foreach($known in @([Environment]::GetFolderPath('ProgramFiles'),[Environment]::GetFolderPath('ProgramFilesX86'))){if($known -and ([IO.Path]::GetFullPath($known).TrimEnd('\')) -ieq $trimmed){return 'BundleExcluded'}}
    'ProtectedArea'
}

function Get-WsmSourceCandidateSameNameLinks($Checkpoint,[object[]]$Candidates,[int]$Max=200) {
    # R7-05 可見性：安裝根內的本體檔（PE）與安裝根之外的候選檔案同名時，兩處都要能被標示。只標示，不改任何排除或備份決定。
    $byName=@{}
    foreach($area in @($Checkpoint.ExcludedAreas)){
        if(-not $area.PSObject.Properties['Contents'] -or -not $area.Contents -or -not $area.Contents.PSObject.Properties['BundleFiles']){continue}
        foreach($relative in @($area.Contents.BundleFiles)){
            $name=[IO.Path]::GetFileName([string]$relative).ToLowerInvariant();if(-not $name){continue}
            if(-not $byName.ContainsKey($name)){$byName[$name]=New-Object 'System.Collections.Generic.List[object]'}
            $byName[$name].Add([pscustomobject]@{Root=[string]$area.Path;Path=([string]$area.Path).TrimEnd('\')+'\'+[string]$relative})
        }
    }
    $links=New-Object 'System.Collections.Generic.List[object]';[long]$total=0
    if($byName.Count){
        foreach($candidate in @($Candidates)){
            if([string]$candidate.CandidateType -cne 'ExactFile'){continue}
            $name=[IO.Path]::GetFileName([string]$candidate.Path).ToLowerInvariant();if(-not $byName.ContainsKey($name)){continue}
            foreach($bundle in $byName[$name]){
                $total++
                if($links.Count -lt $Max){$links.Add([pscustomobject][ordered]@{Name=[IO.Path]::GetFileName([string]$candidate.Path);BundleRoot=$bundle.Root;BundlePath=$bundle.Path;BundleClass='Bundle';BundleReason='位於安裝根內的可執行檔（PE 檔頭），視為套裝軟體本體；整個安裝根依政策不備份。';OtherPath=[string]$candidate.Path;OtherClass='Candidate';OtherReason='位於安裝根之外的候選範圍，可由使用者確認是否納入備份；工具不判定授權或可攜性。';Note='同名檔案，兩處分類不同；工具沒有比對兩份檔案的內容。'})}
            }
        }
    }
    [pscustomobject]@{Links=@($links.ToArray());Total=$total;Truncated=($total -gt $links.Count)}
}

function Add-WsmSourceCandidateExcluded($Checkpoint,[string]$Path,[string]$Reason,[string]$Category='',$Contents=$null) {
    if(-not @($Checkpoint.ExcludedAreas|Where-Object {[string]$_.Path -ieq $Path}).Count){
        # Category／Contents 是 N9d 新增的結構化欄位；舊掃描沒有，讀取端要回退到原因文字推斷。
        $row=[ordered]@{Path=$Path;Reason=$Reason}
        if($Category){$row.Category=$Category}
        if($null -ne $Contents){$row.Contents=$Contents}
        $Checkpoint.ExcludedAreas=@($Checkpoint.ExcludedAreas)+@([pscustomobject]$row)
    }
}

# 記錄一個被排除的區域；安裝根另外做唯讀、受預算限制的內容分類。回傳新增的中繼資料位元組數（供總預算累計）。
function Add-WsmSourceCandidateExcludedArea($Checkpoint,[string]$Path,[string]$Skip,[object[]]$InstallRoots,[string]$Workspace,[int]$MaxEntries,[int]$SecondsLeft,[long]$PathBytesLeft) {
    if(@($Checkpoint.ExcludedAreas|Where-Object {[string]$_.Path -ieq $Path}).Count){return [long]0}
    $category=Get-WsmSourceCandidateExcludedCategory $Skip $InstallRoots $Workspace
    $contents=$null;[long]$extraBytes=0
    $trimmed=$Path.TrimEnd('\');$installRoot=$null
    foreach($root in @($InstallRoots)){if([string]$root.Path -ieq $trimmed){$installRoot=$root;break}}
    if($category -ceq 'BundleExcluded' -and $installRoot -and [IO.Directory]::Exists($Path)){
        try{
            $contents=Get-WsmSourceCandidateBundleContents $Path $MaxEntries ([Math]::Max(1,$SecondsLeft)) ([Math]::Max([long]0,$PathBytesLeft)) $installRoot.InstallTimeUtc
        }catch{
            # 分類失敗也要留下「未列完」的紀錄，不能讓區域消失或讓掃描失敗。
            $contents=[pscustomobject][ordered]@{Listed=0L;Directories=0L;Complete=$false;IncompleteReason='ListingFailed';SkippedReparse=0L;Unreadable=0L;Counts=[pscustomobject][ordered]@{Bundle=0L;SuspectedBusinessData=0L;Unknown=0L};SamplesPerClass=[int]$script:WsmBundleSamplesPerClass;Samples=@();InstallTimeUtc='';InstallTimeTrusted=$false;HeaderBytesRead=64;BundleFiles=@();BundleFilesTruncated=$false}
        }
        foreach($text in @($contents.BundleFiles)+@($contents.Samples|ForEach-Object {[string]$_.RelativePath})){$extraBytes += [Text.Encoding]::UTF8.GetByteCount([string]$text)}
    }
    Add-WsmSourceCandidateExcluded $Checkpoint $Path ('Protected or package area excluded by policy: '+$Skip) $category $contents
    return $extraBytes
}

function Get-WsmSourceCandidateStoredPathBytes($Checkpoint) {
    [long]$total=0
    foreach($path in @($Checkpoint.Queue)+@($Checkpoint.VisitedDirectories)+@($Checkpoint.CurrentDirectorySeen)+@($Checkpoint.Candidates|ForEach-Object {[string]$_.Path})+@($Checkpoint.Gaps|ForEach-Object {[string]$_.Path})+@($Checkpoint.ExcludedAreas|ForEach-Object {[string]$_.Path})+@($Checkpoint.ExcludedAreas|ForEach-Object {if($_.PSObject.Properties['Contents'] -and $_.Contents){@($_.Contents.BundleFiles)+@($_.Contents.Samples|ForEach-Object {[string]$_.RelativePath})}})){$total += [Text.Encoding]::UTF8.GetByteCount([string]$path)}
    if($Checkpoint.CurrentDirectory){$total += [Text.Encoding]::UTF8.GetByteCount([string]$Checkpoint.CurrentDirectory)}
    return $total
}

function Add-WsmSourceCandidate($Checkpoint,[string]$Path,[string]$CandidateType,$Info,$CandidateList=$null,$CandidatePathSet=$null) {
    $full=[IO.Path]::GetFullPath($Path);$key=$full.ToLowerInvariant()
    if($null -ne $CandidatePathSet){if($CandidatePathSet.Contains($key)){return};[void]$CandidatePathSet.Add($key)}elseif(@($Checkpoint.Candidates|Where-Object {[string]$_.Path.ToLowerInvariant() -ceq $key}).Count){return}
    $candidate=[pscustomobject][ordered]@{CandidateId=(Get-WsmHashText ($Checkpoint.SourceHostId+'|'+$Checkpoint.InventoryHash+'|'+$key+'|'+$CandidateType));CandidateType=$CandidateType;Path=$full;Length=$(if($CandidateType -ceq 'ExactFile'){[long]$Info.Length}else{$null});LastWriteUtc=[string]$Info.LastWriteTimeUtc;Attributes=[string]$Info.Attributes;WorkloadReferenceCount=0;WorkloadReferences=@();MetadataOnly=$true;UserDecisionRequired=$true;AuthoritativeApproval=$false}
    if($null -ne $CandidateList){$CandidateList.Add($candidate)}else{$Checkpoint.Candidates=@($Checkpoint.Candidates)+@($candidate)}
}

function Set-WsmSourceCandidateWorkloadReferences($Checkpoint,$Inventory,[string]$Root,[int]$MaxReferenceCount=10000,[long]$MaxReferenceBytes=2097152) {
    $presented=@($Checkpoint.Candidates|ForEach-Object {$copy=$_|Select-Object *;$copy|Add-Member NoteProperty WorkloadReferenceCount 0 -Force;$copy|Add-Member NoteProperty WorkloadReferences @() -Force;$copy})
    $candidateByPath=@{};$directoryByPath=@{};$referenceLists=@{}
    foreach($candidate in $presented){$key=([IO.Path]::GetFullPath([string]$candidate.Path)).ToLowerInvariant();if(-not $candidateByPath.ContainsKey($key)){$candidateByPath[$key]=$candidate};if($candidate.CandidateType -ceq 'DirectoryRoot'){$directoryByPath[$key]=$candidate};$referenceLists[$key]=New-Object 'System.Collections.Generic.List[object]'}
    $known=New-Object 'System.Collections.Generic.List[object]';[long]$knownBytes=0;[long]$truncated=0
    foreach($item in @($Inventory.Items)){
        try{$references=@(Get-WsmWorkloadPathReferences $item)}catch{continue}
        foreach($reference in $references){
            $resolved=[string]$reference.ResolvedPath
            if(-not $resolved -or $reference.Opaque -or -not (Get-WsmSafeWorkloadPathProjection $resolved)){continue}
            try{$full=[IO.Path]::GetFullPath($resolved)}catch{continue}
            $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\');$prefix=$rootFull+'\'
            if($full -ine $rootFull -and -not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){continue}
            $knownReference=[pscustomobject][ordered]@{ConsumerItemId=[string]$reference.ConsumerItemId;FieldPointer=[string]$reference.FieldPointer;ReferenceKind=[string]$reference.ReferenceKind;Path=$full;Required=[bool]$(if($reference.PSObject.Properties['Required']){$reference.Required}else{$false});ReviewRequired=[bool]$(if($reference.PSObject.Properties['ReviewRequired']){$reference.ReviewRequired}else{$true})}
            $knownReferenceBytes=[long]([Text.Encoding]::UTF8.GetByteCount([string]$knownReference.ConsumerItemId)+[Text.Encoding]::UTF8.GetByteCount([string]$knownReference.FieldPointer)+[Text.Encoding]::UTF8.GetByteCount([string]$knownReference.ReferenceKind)+[Text.Encoding]::UTF8.GetByteCount([string]$knownReference.Path)+128)
            if($known.Count -ge $MaxReferenceCount -or $knownBytes+$knownReferenceBytes -gt $MaxReferenceBytes){$truncated++;continue};$known.Add($knownReference);$knownBytes+=$knownReferenceBytes
        }
    }
    $unmatched=New-Object 'System.Collections.Generic.List[object]';[int]$assignedCount=0;[long]$assignedBytes=0
    foreach($reference in $known){
        $matched=$false;$referenceKey=([IO.Path]::GetFullPath([string]$reference.Path)).ToLowerInvariant()
        if($candidateByPath.ContainsKey($referenceKey)){$cost=[long]([Text.Encoding]::UTF8.GetByteCount([string]$reference.ConsumerItemId)+[Text.Encoding]::UTF8.GetByteCount([string]$reference.FieldPointer)+[Text.Encoding]::UTF8.GetByteCount([string]$reference.ReferenceKind)+[Text.Encoding]::UTF8.GetByteCount([string]$reference.Path)+128);if($assignedCount -lt $MaxReferenceCount -and $assignedBytes+$cost -le $MaxReferenceBytes){$referenceLists[$referenceKey].Add($reference);$assignedCount++;$assignedBytes+=$cost}else{$truncated++};$matched=$true}
        $ancestor=[IO.Path]::GetDirectoryName([string]$reference.Path);$rootKey=([IO.Path]::GetFullPath($Root)).ToLowerInvariant()
        while($ancestor){
            $ancestorKey=([IO.Path]::GetFullPath($ancestor)).ToLowerInvariant()
            if($directoryByPath.ContainsKey($ancestorKey)){$cost=[long]([Text.Encoding]::UTF8.GetByteCount([string]$reference.ConsumerItemId)+[Text.Encoding]::UTF8.GetByteCount([string]$reference.FieldPointer)+[Text.Encoding]::UTF8.GetByteCount([string]$reference.ReferenceKind)+[Text.Encoding]::UTF8.GetByteCount([string]$reference.Path)+128);if($assignedCount -lt $MaxReferenceCount -and $assignedBytes+$cost -le $MaxReferenceBytes){$referenceLists[$ancestorKey].Add($reference);$assignedCount++;$assignedBytes+=$cost}else{$truncated++};$matched=$true}
            if($ancestorKey -ceq $rootKey){break}
            $next=[IO.Path]::GetDirectoryName($ancestor);if(-not $next -or $next -ieq $ancestor){break};$ancestor=$next
        }
        if(-not $matched){
            $parent=[IO.Path]::GetDirectoryName($reference.Path);$pending=$false
            foreach($dir in @($Checkpoint.Queue)+@($(if($Checkpoint.CurrentDirectory){$Checkpoint.CurrentDirectory}else{@()}))){if($parent -ieq [string]$dir -or $parent.StartsWith(([string]$dir).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$pending=$true;break}}
            $unmatched.Add([pscustomobject][ordered]@{ConsumerItemId=$reference.ConsumerItemId;FieldPointer=$reference.FieldPointer;ReferenceKind=$reference.ReferenceKind;Path=$reference.Path;Status=$(if($pending){'Pending'}else{'NotMatchedThisScan'});Required=$reference.Required;ReviewRequired=$reference.ReviewRequired})
        }
    }
    foreach($candidate in $presented){$key=([IO.Path]::GetFullPath([string]$candidate.Path)).ToLowerInvariant();$links=$referenceLists[$key];$candidate.WorkloadReferences=$links.ToArray();$candidate.WorkloadReferenceCount=$links.Count}
    $presented=@($presented|Sort-Object @{Expression={if([int]$_.WorkloadReferenceCount -gt 0){0}else{1}}},@{Expression={[string]$_.Path.ToLowerInvariant()}})
    if($truncated){Add-WsmSourceCandidateGap $Checkpoint $Root 'WorkloadReferenceBudgetExceeded' ('Known workload reference details exceeded the bounded count/byte ceiling; omitted associations: '+[string]$truncated+'.')}
    [pscustomobject]@{Candidates=$presented;UnmatchedWorkloadReferences=$unmatched.ToArray();TruncatedWorkloadReferences=[long]$truncated;WorkloadReferenceDetailBytes=[long]$knownBytes;AssignedWorkloadReferenceBytes=[long]$assignedBytes}
}

function Write-WsmSourceCandidateReviewHtml([string]$Path,$Checkpoint,$Policy,[object[]]$Candidates=@(),[object[]]$UnmatchedWorkloadReferences=@(),[object[]]$SameNameLinks=@()) {
    $enc={param($value)[System.Net.WebUtility]::HtmlEncode([string]$value)}
    $candidateTypeText={param($value)switch([string]$value){'ExactFile'{'精確檔案'}'DirectoryRoot'{'資料目錄'}default{[string]$value}}}
    $referenceKindText={param($value)switch([string]$value){'TaskCommand'{'排程工作命令'}'TaskWorkingDirectory'{'排程工作目錄'}'TaskArgumentPath'{'排程工作參數路徑'}'IISPhysicalPath'{'IIS 實體路徑'}'IISConfigSource'{'IIS 設定來源'}default{[string]$value}}}
    $gapReasonText={param($value)switch([string]$value){'ReparsePointNotFollowed'{'未跟隨重新解析點'}'PermissionDenied'{'存取遭拒'}'DirectoryUnavailable'{'目錄已不存在或無法使用'}'DirectoryMetadataFailed'{'讀取目錄中繼資料失敗'}'PhysicalPathResolutionFailed'{'無法解析實體路徑'}'PhysicalPathOutsideCVolume'{'實體路徑位於登錄 C 槽之外'}'SourceDirectoryChanged'{'續作前目錄中繼資料已變更'}'CumulativeEntryBudgetExceeded'{'本分段已達項目數上限'}'AggregateEntryBudgetExceeded'{'探索已達總中繼資料項目上限'}'MetadataBudgetExceeded'{'探索已達總路徑中繼資料大小上限'}'WorkloadReferenceBudgetExceeded'{'已知工作負載關聯達到中繼資料上限'}'CandidateArtifactSizeBudgetExceeded'{'候選中繼資料輸出達到安全大小上限'}'ReviewReportSizeBudgetExceeded'{'審閱報告達到安全大小上限'}'ReplayBudgetExceeded'{'重播已記錄目錄前綴時達到合作式時間上限'}'CancelledAtSafeBoundary'{'已在安全檢查點取消'}'PathOutsideSystemVolume'{'路徑位於來源卷之外'}'DirectoryEnumerationFailed'{'列舉目錄失敗'}'MetadataReadFailed'{'讀取項目中繼資料失敗'}default{[string]$value}}}
    $rows=New-Object 'System.Text.StringBuilder'
    foreach($candidate in @($Candidates)){$links=@($candidate.WorkloadReferences|ForEach-Object {(& $referenceKindText $_.ReferenceKind)+' · '+([string]$_.ConsumerItemId)+' · '+([string]$_.FieldPointer)});$null=$rows.Append('<tr><td>');$null=$rows.Append((& $enc (& $candidateTypeText $candidate.CandidateType)));$null=$rows.Append('</td><td><code>');$null=$rows.Append((& $enc $candidate.Path));$null=$rows.Append('</code></td><td>');$null=$rows.Append((& $enc $candidate.Length));$null=$rows.Append('</td><td>');$null=$rows.Append((& $enc $candidate.LastWriteUtc));$null=$rows.Append('</td><td>');$null=$rows.Append((& $enc (@($links)-join '; ')));$null=$rows.Append('</td></tr>')}
    $gaps=New-Object 'System.Text.StringBuilder';foreach($gap in @($Checkpoint.Gaps)){$null=$gaps.Append('<li><code>');$null=$gaps.Append((& $enc $gap.Path));$null=$gaps.Append('</code> — ');$null=$gaps.Append((& $enc (& $gapReasonText $gap.Reason)));if($gap.Detail){$null=$gaps.Append(': ');$null=$gaps.Append((& $enc $gap.Detail))};$null=$gaps.Append('</li>')}
    $excluded=New-Object 'System.Text.StringBuilder';foreach($area in @($Checkpoint.ExcludedAreas)){$reason=[string]$area.Reason -replace '^Protected or package area excluded by policy: ','由保護或套件排除政策略過：' -replace '^FileScope guard: ','依既有檔案範圍保護規則略過：';$null=$excluded.Append('<li><code>');$null=$excluded.Append((& $enc $area.Path));$null=$excluded.Append('</code> — ');$null=$excluded.Append((& $enc $reason));if($area.PSObject.Properties['Contents'] -and $area.Contents){$c=$area.Contents;$null=$excluded.Append('<br>安裝根內容（唯讀分類，仍整塊不備份）：本體 '+(& $enc $c.Counts.Bundle)+'、疑似業務資料 '+(& $enc $c.Counts.SuspectedBusinessData)+'（需人工處置）、未知 '+(& $enc $c.Counts.Unknown)+'；已列 '+(& $enc $c.Listed)+' 筆'+$(if($c.Complete){''}else{'，<strong>未列完</strong>（'+(& $enc $c.IncompleteReason)+'）'}))};$null=$excluded.Append('</li>')}
    $sameNameItems=New-Object 'System.Text.StringBuilder';foreach($link in @($SameNameLinks)){$null=$sameNameItems.Append('<li><code>');$null=$sameNameItems.Append((& $enc $link.Name));$null=$sameNameItems.Append('</code>：同名，另一處位於 <code>');$null=$sameNameItems.Append((& $enc $link.OtherPath));$null=$sameNameItems.Append('</code>（安裝根內：<code>');$null=$sameNameItems.Append((& $enc $link.BundlePath));$null=$sameNameItems.Append('</code>）。');$null=$sameNameItems.Append((& $enc $link.BundleReason));$null=$sameNameItems.Append(' ');$null=$sameNameItems.Append((& $enc $link.OtherReason));$null=$sameNameItems.Append('</li>')}
    $status=if($Checkpoint.Status -ceq 'Succeeded'){'已依記錄的有限範圍政策完成探索。'}elseif($Checkpoint.Status -ceq 'ReplayBudgetExceeded'){'重播已記錄目錄前綴時達到合作式時間上限，且尚未取得新進度；此掃描不可續作，須縮小範圍另行檢視。'}elseif($Checkpoint.Status -cin @('MetadataBudgetExceeded','AggregateEntryBudgetExceeded')){'本掃描已達總中繼資料大小或項目上限；剩餘路徑須另行補查，不能以此識別碼續作。'}elseif($Checkpoint.Status -ceq 'BudgetExhausted' -and [long]$Checkpoint.ScannedEntryCount -ge [long]$Policy.MaxAggregateEntries){'本掃描已達總中繼資料項目上限；剩餘路徑須另行補查，不能以此識別碼續作。'}elseif($Checkpoint.Status -ceq 'BudgetExhausted' -and [int]$Checkpoint.SegmentNumber -ge [int]$Policy.MaxSegments){'本掃描已達固定分段總上限；剩餘路徑須另行補查，不能以此識別碼再續作。'}elseif($Checkpoint.Status -ceq 'BudgetExhausted'){'本掃描分段已達項目數上限；可用相同探索識別碼明確啟動下一個有界分段，剩餘路徑仍須列入檢視。'}else{'探索尚未完成；請以相同探索識別碼從已保存的檢查點繼續。'}
    $remaining=New-Object 'System.Text.StringBuilder';if($Checkpoint.CurrentDirectory){$null=$remaining.Append('<li><code>');$null=$remaining.Append((& $enc $Checkpoint.CurrentDirectory));$null=$remaining.Append('</code>（目前目錄；續作時會略過已記錄項目）</li>')};foreach($dir in @($Checkpoint.Queue)){$null=$remaining.Append('<li><code>');$null=$remaining.Append((& $enc $dir));$null=$remaining.Append('</code></li>')}
    $softwareGaps=New-Object 'System.Text.StringBuilder';foreach($gap in @($Policy.SoftwareRootCoverageGaps)){$text=[string]$gap -replace '^Installed-software root coverage is ','已安裝軟體根目錄涵蓋狀態為 ' -replace '; package directories may remain undiscovered or appear as candidates\.$','；套件目錄可能尚未探索或仍列為候選。';$null=$softwareGaps.Append('<li>');$null=$softwareGaps.Append((& $enc $text));$null=$softwareGaps.Append('</li>')}
    $referenceGaps=New-Object 'System.Text.StringBuilder';foreach($reference in @($UnmatchedWorkloadReferences)){$referenceStatus=switch([string]$reference.Status){'Pending'{'待探索'}'NotMatchedThisScan'{'未在本次候選中'}default{[string]$reference.Status}};$null=$referenceGaps.Append('<li><code>');$null=$referenceGaps.Append((& $enc $reference.Path));$null=$referenceGaps.Append('</code> — ');$null=$referenceGaps.Append((& $enc $referenceStatus));$null=$referenceGaps.Append('；項目 ');$null=$referenceGaps.Append((& $enc $reference.ConsumerItemId));$null=$referenceGaps.Append('；');$null=$referenceGaps.Append((& $enc $reference.FieldPointer));$null=$referenceGaps.Append('</li>')}
    $html='<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''"><title>來源 C 槽候選檔案審閱</title><style>body{font:16px system-ui,"Microsoft JhengHei",sans-serif;margin:2rem;color:#17202a}h1,h2{color:#17365d}.summary{padding:1rem;background:#eef4fb;border-left:4px solid #315f8a}table{border-collapse:collapse;width:100%;margin:1rem 0}th,td{border:1px solid #bbb;padding:.45rem;text-align:left;vertical-align:top}code{overflow-wrap:anywhere}li{margin:.35rem 0}.note{color:#444}</style></head><body><h1>來源 C 槽候選檔案審閱</h1><section class="summary"><p><strong>'+(& $enc $status)+'</strong></p><p>探索識別碼（ScanId）：<code>'+(& $enc $Checkpoint.ScanId)+'</code></p><p>來源主機：<code>'+(& $enc $Checkpoint.SourceHostId)+'</code>；盤點修訂版 '+(& $enc $Checkpoint.InventoryRevision)+'；盤點 SHA-256 <code>'+(& $enc $Checkpoint.InventoryHash)+'</code></p><p>政策版本 '+(& $enc $Checkpoint.PolicyVersion)+'；已檢查目錄數 '+(& $enc @($Checkpoint.VisitedDirectories).Count)+'；中繼資料項目數 '+(& $enc $Checkpoint.ScannedEntryCount)+'；候選數 '+(& $enc @($Checkpoint.Candidates).Count)+'；缺口數 '+(& $enc @($Checkpoint.Gaps).Count)+'</p><p>已安裝軟體根目錄涵蓋狀態：'+(& $enc $Policy.SoftwareRootCoverageStatus)+'</p></section><p class="note">本報告只記錄中繼資料，未讀取候選檔案內容或執行指令碼；安裝根內的檔案僅讀取檔頭前 64 位元組以判斷是否為可執行檔。這些候選項目不會建立 FileScope 或移轉核准。C 槽根目錄中的散置檔案會列為精確檔案候選。刻意排除的路徑與尚未探索的涵蓋範圍分別列示；本次探索不代表已發現所有未知資料。</p><h2>尚待探索的目錄</h2><ul>'+[string]$remaining+'</ul><h2>已安裝軟體根目錄涵蓋缺口</h2><ul>'+[string]$softwareGaps+'</ul><h2>依已知工作負載路徑優先呈現候選項目</h2><p>關聯僅供審閱，不代表檔案已獲核准或納入移轉範圍。</p><table><thead><tr><th>類型</th><th>路徑</th><th>位元組</th><th>最後寫入時間（UTC）</th><th>已知工作負載參照（類型 · 項目 ID · 欄位位置）</th></tr></thead><tbody>'+[string]$rows+'</tbody></table><h2>尚未匹配候選的已知工作負載路徑</h2><ul>'+[string]$referenceGaps+'</ul><h2>涵蓋缺口</h2><ul>'+[string]$gaps+'</ul><h2>政策排除路徑</h2><ul>'+[string]$excluded+'</ul><h2>同名檔案追溯</h2><p>僅標示，不改變任何排除或備份決定。</p><ul>'+[string]$sameNameItems+'</ul></body></html>'
    [IO.File]::WriteAllText($Path,$html,(New-Object Text.UTF8Encoding($false)))
}

function Invoke-WsmSourceCandidateScanCore([string]$Workspace,$Profile,$Inventory,[string]$InventoryHash,[string]$SourceRoot,[string]$ScanId='',[object]$CancellationToken=$null,[int]$MaxEntries=4000,[int]$MaxSeconds=25,[int]$MaxTotalEntries=50000,[scriptblock]$CancellationTestHook=$null,[scriptblock]$ReplayTestHook=$null,[long]$MaxAggregatePathBytes=4194304,[switch]$ContinueAfterBudgetExhausted,[int]$MaxAggregateEntries=40000) {
    if($MaxEntries -lt 1 -or $MaxEntries -gt 4000 -or $MaxSeconds -lt 1 -or $MaxSeconds -gt 25){throw 'Source candidate scan budget exceeds its fixed safety limit.'}
    if($MaxTotalEntries -lt 1 -or $MaxTotalEntries -gt 50000){throw 'Source candidate cumulative entry budget exceeds its fixed safety limit.'}
    if($MaxAggregatePathBytes -lt 1 -or $MaxAggregatePathBytes -gt 16777216){throw 'Source candidate aggregate path-metadata budget exceeds its fixed safety limit.'}
    $policy=Get-WsmSourceCandidatePolicy $SourceRoot $Inventory $Workspace;if($MaxAggregateEntries -lt 1 -or $MaxAggregateEntries -gt [int]$policy.MaxAggregateEntries){throw 'Source candidate aggregate entry budget exceeds its fixed safety limit.'};$policy.MaxAggregateEntries=$MaxAggregateEntries;$policy.MaxAggregatePathBytes=$MaxAggregatePathBytes;$policy|Add-Member NoteProperty MaxTotalEntries $MaxTotalEntries;$policy.PolicyHash=Get-WsmHashText (($policy|Select-Object * -ExcludeProperty PolicyHash|ConvertTo-Json -Depth 8 -Compress));$store=Get-WsmSourceCandidateStoreRoot $Workspace $Profile
    $installRootInfo=@(Get-WsmSourceCandidateInstallRootInfo $Inventory)
    $resumeRequested=[bool]$ScanId
    if(-not $ScanId){$ScanId=[Guid]::NewGuid().ToString('D')}else{Assert-WsmId $ScanId}
    $scanDir=Join-Path $store $ScanId;if(-not [IO.Directory]::Exists($scanDir)){if($resumeRequested){throw 'The requested durable source candidate scan does not exist.'};[void](New-WsmOutputOwnedDirectory $scanDir)}else{[void](New-WsmOutputOwnedDirectory $scanDir)}
    Assert-WsmNoReparse $scanDir
    $scanLockPath=Join-Path $scanDir 'scan.lock';Assert-WsmNoReparse $scanLockPath;$scanLock=$null
    try{$scanLock=[IO.File]::Open($scanLockPath,'OpenOrCreate','ReadWrite','None')}catch [System.IO.IOException]{throw 'Another process is already running this source candidate ScanId; wait and resume after it exits.'}
    try {
    $checkpointPath=Join-Path $scanDir 'checkpoint.json';$checkpoint=$null
    if([IO.File]::Exists($checkpointPath)) {
        Assert-WsmNoReparse $checkpointPath;$checkpoint=Read-WsmJson $checkpointPath
        # Version 1 D1 checkpoints omitted aggregate/segment ceilings from their policy
        # hash. Migrate only an exact legacy-hash, nonterminal checkpoint with no frozen
        # segments; immutable old segments cannot be rebound to the stricter v2 policy.
        $legacySegmentCount=0;if($checkpoint.PSObject.Properties['Segments']){$legacySegmentCount=@($checkpoint.Segments).Count};$migratedLegacy=$false
        if([int]$checkpoint.PolicyVersion -eq 1 -and [string]$checkpoint.Status -cin @('Running','Partial') -and $legacySegmentCount -eq 0){
            $legacyPolicy=$policy|Select-Object * -ExcludeProperty PolicyHash
            $legacyPolicy.PolicyVersion=1;$legacyPolicy.MaxTotalEntries=50000
            $legacyPolicyHash=Get-WsmHashText (($legacyPolicy|Select-Object * -ExcludeProperty MaxSegments,MaxAggregateEntries,MaxAggregatePathBytes,MaxWorkloadReferenceCount,MaxWorkloadReferenceBytes|ConvertTo-Json -Depth 8 -Compress))
            if([string]$checkpoint.PolicyHash -cne $legacyPolicyHash){throw 'Legacy source candidate checkpoint policy hash is invalid; it cannot be migrated.'}
            if([long]$checkpoint.ScannedEntryCount -ge [long]$policy.MaxAggregateEntries){throw 'Legacy source candidate checkpoint exceeds the new bounded aggregate limit; preserve its checkpoint and review narrower scan segments instead of resetting it.'}
            $checkpoint.PolicyVersion=[int]$policy.PolicyVersion;$checkpoint.PolicyHash=[string]$policy.PolicyHash;$migratedLegacy=$true
        }
        if([string]$checkpoint.Status -cin @('ReplayBudgetExceeded','MetadataBudgetExceeded','AggregateEntryBudgetExceeded')){throw 'This source candidate scan reached a terminal metadata or replay budget without further progress; it requires narrower review.'}
        # Older partial checkpoints have no immutable segments. Preserve their prior
        # count as a baseline and make only newly scanned work part of segment 1.
        if($migratedLegacy){$checkpoint|Add-Member NoteProperty SegmentNumber 1;$checkpoint|Add-Member NoteProperty SegmentEntryCount 0L;$checkpoint|Add-Member NoteProperty Segments @();$checkpoint|Add-Member NoteProperty SegmentStartCandidateCount @($checkpoint.Candidates).Count;$checkpoint|Add-Member NoteProperty SegmentStartGapCount @($checkpoint.Gaps).Count;$checkpoint|Add-Member NoteProperty SegmentStartExcludedCount @($checkpoint.ExcludedAreas).Count;$checkpoint|Add-Member NoteProperty SegmentStartVisitedCount @($checkpoint.VisitedDirectories).Count;$checkpoint|Add-Member NoteProperty LegacyBaselineEntryCount ([long]$checkpoint.ScannedEntryCount)}
        if(-not $checkpoint.PSObject.Properties['SegmentNumber']){$checkpoint|Add-Member NoteProperty SegmentNumber 1;$checkpoint|Add-Member NoteProperty SegmentEntryCount ([long]$checkpoint.ScannedEntryCount);$checkpoint|Add-Member NoteProperty Segments @();$checkpoint|Add-Member NoteProperty SegmentStartCandidateCount 0;$checkpoint|Add-Member NoteProperty SegmentStartGapCount 0;$checkpoint|Add-Member NoteProperty SegmentStartExcludedCount 0;$checkpoint|Add-Member NoteProperty SegmentStartVisitedCount 0}
        if(-not $checkpoint.PSObject.Properties['LegacyBaselineEntryCount']){$checkpoint|Add-Member NoteProperty LegacyBaselineEntryCount 0L}
        Assert-WsmSourceCandidateCheckpoint $checkpoint $ScanId $Profile $Inventory $InventoryHash $SourceRoot $policy $scanDir
    } elseif($resumeRequested){throw 'The requested durable source candidate checkpoint is missing; it was not reset.'}
    else {$checkpoint=New-WsmSourceCandidateCheckpoint $ScanId $Profile $Inventory $InventoryHash $SourceRoot $policy}
    $candidateList=New-Object 'System.Collections.Generic.List[object]';$candidatePathSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);foreach($candidate in @($checkpoint.Candidates)){$candidateList.Add($candidate);[void]$candidatePathSet.Add([string]$candidate.Path)}
    if($checkpoint.Status -ceq 'BudgetExhausted'){
        if(-not $ContinueAfterBudgetExhausted){throw 'This source candidate scan segment reached its entry budget; continue it only with ContinueAfterBudgetExhausted and the same ScanId.'}
        if([int]$checkpoint.SegmentNumber -ge [int]$policy.MaxSegments){throw 'This source candidate scan reached its fixed maximum segment count; remaining paths require separate review.'}
        if([long]$checkpoint.ScannedEntryCount -ge [long]$policy.MaxAggregateEntries){throw 'This source candidate scan reached its aggregate entry ceiling; remaining paths require separate review.'}
        if(@($checkpoint.Segments).Count -lt [int]$checkpoint.SegmentNumber){$checkpoint.Candidates=$candidateList.ToArray();[void](Save-WsmSourceCandidateSegment $scanDir $checkpoint $Profile $InventoryHash $SourceRoot $policy 'BudgetExhausted')}
        $checkpoint.SegmentNumber=[int]$checkpoint.SegmentNumber+1;$checkpoint.SegmentEntryCount=0L;$checkpoint.SegmentStartCandidateCount=@($checkpoint.Candidates).Count;$checkpoint.SegmentStartGapCount=@($checkpoint.Gaps).Count;$checkpoint.SegmentStartExcludedCount=@($checkpoint.ExcludedAreas).Count;$checkpoint.SegmentStartVisitedCount=@($checkpoint.VisitedDirectories).Count;$checkpoint.Status='Running'
    }elseif($ContinueAfterBudgetExhausted){throw 'ContinueAfterBudgetExhausted requires the same ScanId in BudgetExhausted state; it cannot start a fresh scan or skip a partial checkpoint.'}
    $checkpoint.Status='Running'
    $watch=[Diagnostics.Stopwatch]::StartNew();$entriesThisRun=0;$sinceSave=0
    [long]$storedPathBytes=Get-WsmSourceCandidateStoredPathBytes $checkpoint
    try {
        while(@($checkpoint.Queue).Count -gt 0 -or $checkpoint.CurrentDirectory) {
            if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken 'SourceCandidateEntry'}
            if([long]$checkpoint.SegmentEntryCount -ge [long]$policy.MaxTotalEntries){Add-WsmSourceCandidateGap $checkpoint ([string]$checkpoint.CurrentDirectory) 'CumulativeEntryBudgetExceeded' ('Segment '+[string]$checkpoint.SegmentNumber+' reached its fixed maximum of '+[string]$policy.MaxTotalEntries+' entries.');$checkpoint.Status='BudgetExhausted';break}
            if($entriesThisRun -ge $MaxEntries -or $watch.Elapsed.TotalSeconds -ge $MaxSeconds){break}
            if(-not $checkpoint.CurrentDirectory){$checkpoint.CurrentDirectory=[string]$checkpoint.Queue[0];if(@($checkpoint.Queue).Count -gt 1){$checkpoint.Queue=@($checkpoint.Queue|Select-Object -Skip 1)}else{$checkpoint.Queue=@()};$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@()}
            $dir=$checkpoint.CurrentDirectory
            # Revalidate the queued/current path and every ancestor on each resume and immediately before enumeration.
            $directoryState=Get-WsmSourceCandidateDirectoryState $dir $SourceRoot $policy
            if($directoryState.Status -cne 'Ready'){Add-WsmSourceCandidateGap $checkpoint $dir $directoryState.Reason $directoryState.Detail;$checkpoint.CurrentDirectory='';$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@();$checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc;Write-WsmJson $checkpointPath $checkpoint;continue}
            $dirInfo=$directoryState.Item
            if(-not $checkpoint.CurrentDirectoryWriteUtc){$checkpoint.CurrentDirectoryWriteUtc=$dirInfo.LastWriteTimeUtc.ToString('o')}
            elseif($dirInfo.LastWriteTimeUtc.ToString('o') -cne [string]$checkpoint.CurrentDirectoryWriteUtc){Add-WsmSourceCandidateGap $checkpoint $dir 'SourceDirectoryChanged' 'Directory metadata changed while the scan was paused; this directory was not resumed.';$checkpoint.CurrentDirectory='';$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@();$checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc;Write-WsmJson $checkpointPath $checkpoint;continue}
            $excludedRelative=Test-WsmSourceCandidateExcludedPath $dir $SourceRoot $policy
            if($excludedRelative){$storedPathBytes += Add-WsmSourceCandidateExcludedArea $checkpoint $dir ([string]$excludedRelative) $installRootInfo $Workspace $MaxEntries ([int][Math]::Floor($MaxSeconds-$watch.Elapsed.TotalSeconds)) ([long]$policy.MaxAggregatePathBytes-$storedPathBytes);$checkpoint.CurrentDirectory='';$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@();continue}
            $completedDirectory=$true
            # The checkpoint may outlive this process. Recheck the entire lexical chain
            # and physical volume immediately before opening the directory enumerator.
            $enumerationState=Get-WsmSourceCandidateDirectoryState $dir $SourceRoot $policy
            if($enumerationState.Status -cne 'Ready'){Add-WsmSourceCandidateGap $checkpoint $dir $enumerationState.Reason $enumerationState.Detail;$checkpoint.CurrentDirectory='';$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@();$checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc;Write-WsmJson $checkpointPath $checkpoint;continue}
            $seenSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase);$seenList=New-Object 'System.Collections.Generic.List[string]';foreach($seen in @($checkpoint.CurrentDirectorySeen)){[void]$seenSet.Add([string]$seen);$seenList.Add([string]$seen)};$checkpoint.CurrentDirectorySeen=$seenList
            try {
                foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
                    if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken 'SourceCandidateEntry'}
                    $full=[IO.Path]::GetFullPath($entryPath);$rootPrefix=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')+'\';if($full -ine [IO.Path]::GetFullPath($SourceRoot) -and -not $full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){Add-WsmSourceCandidateGap $checkpoint $full 'PathOutsideSystemVolume';continue}
                    if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken 'SourceCandidateReplay'}
                    $wasSeen=$seenSet.Contains($full)
                    if($wasSeen){
                        if($ReplayTestHook){& $ReplayTestHook $full $watch}
                        # This is a cooperative wall-clock bound. If replaying the
                        # saved prefix consumes it, stop permanently with a visible
                        # gap; restarting the same directory would replay it again.
                        if($watch.Elapsed.TotalSeconds -ge $MaxSeconds){Add-WsmSourceCandidateGap $checkpoint $dir 'ReplayBudgetExceeded' 'Replaying the saved directory prefix reached the cooperative time limit before new work; this scan is terminal and needs narrower review.';$checkpoint.Status='ReplayBudgetExceeded';$completedDirectory=$false;break}
                        continue
                    }
                    if($watch.Elapsed.TotalSeconds -ge $MaxSeconds){$completedDirectory=$false;break}
                    if([long]$checkpoint.SegmentEntryCount -ge [long]$policy.MaxTotalEntries){Add-WsmSourceCandidateGap $checkpoint $dir 'CumulativeEntryBudgetExceeded' ('Segment '+[string]$checkpoint.SegmentNumber+' reached its fixed maximum of '+[string]$policy.MaxTotalEntries+' entries.');$checkpoint.Status='BudgetExhausted';$completedDirectory=$false;break}
                    if($entriesThisRun -ge $MaxEntries -or $watch.Elapsed.TotalSeconds -ge $MaxSeconds){$completedDirectory=$false;break}
                    if([long]$checkpoint.ScannedEntryCount -ge [long]$policy.MaxAggregateEntries){Add-WsmSourceCandidateGap $checkpoint $dir 'AggregateEntryBudgetExceeded' 'The aggregate metadata entry ceiling was reached before this entry; remaining paths need narrower review.';$checkpoint.Status='AggregateEntryBudgetExceeded';$completedDirectory=$false;break}
                    $entryPathBytes=[long][Text.Encoding]::UTF8.GetByteCount($full)*4
                    if($storedPathBytes+$entryPathBytes -gt [long]$policy.MaxAggregatePathBytes){Add-WsmSourceCandidateGap $checkpoint $dir 'MetadataBudgetExceeded' 'The bounded aggregate path-metadata budget was reached before this entry; remaining paths need narrower review.';$checkpoint.Status='MetadataBudgetExceeded';$completedDirectory=$false;break}
                    $entriesThisRun++;$checkpoint.ScannedEntryCount=[long]$checkpoint.ScannedEntryCount+1;$checkpoint.SegmentEntryCount=[long]$checkpoint.SegmentEntryCount+1;$sinceSave++
                    [void]$seenSet.Add($full);$seenList.Add($full)
                    $storedPathBytes += $entryPathBytes
                    try {
                        $info=Get-Item -LiteralPath $full -Force -ErrorAction Stop
                        if(($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){Add-WsmSourceCandidateGap $checkpoint $full 'ReparsePointNotFollowed';continue}
                        $skip=Test-WsmSourceCandidateExcludedPath $full $SourceRoot $policy
                        if($skip){$storedPathBytes += Add-WsmSourceCandidateExcludedArea $checkpoint $full ([string]$skip) $installRootInfo $Workspace $MaxEntries ([int][Math]::Floor($MaxSeconds-$watch.Elapsed.TotalSeconds)) ([long]$policy.MaxAggregatePathBytes-$storedPathBytes);continue}
                        if($info.PSIsContainer){
                            Add-WsmSourceCandidate $checkpoint $full 'DirectoryRoot' $info $candidateList $candidatePathSet
                            if(-not @($checkpoint.VisitedDirectories|Where-Object {([string]$_) -ieq $full}).Count -and -not @($checkpoint.Queue|Where-Object {([string]$_) -ieq $full}).Count){$checkpoint.Queue=@($checkpoint.Queue)+@($full)}
                        }else{Add-WsmSourceCandidate $checkpoint $full 'ExactFile' $info $candidateList $candidatePathSet}
                    }catch [System.UnauthorizedAccessException]{Add-WsmSourceCandidateGap $checkpoint $full 'PermissionDenied'}catch [System.IO.IOException]{Add-WsmSourceCandidateGap $checkpoint $full 'MetadataReadFailed' $_.Exception.Message}catch{Add-WsmSourceCandidateGap $checkpoint $full 'MetadataReadFailed' $_.Exception.Message}
                    finally{if($CancellationTestHook){$checkpoint.Candidates=$candidateList.ToArray();$checkpoint.CurrentDirectorySeen=$seenList.ToArray();& $CancellationTestHook $checkpoint $CancellationToken};if($sinceSave -ge [int]$policy.CheckpointEvery){$checkpoint.Candidates=$candidateList.ToArray();$checkpoint.CurrentDirectorySeen=$seenList.ToArray();$checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc;Write-WsmJson $checkpointPath $checkpoint;$sinceSave=0}}
                }
            }catch [System.OperationCanceledException]{throw}catch [System.UnauthorizedAccessException]{Add-WsmSourceCandidateGap $checkpoint $dir 'PermissionDenied';$completedDirectory=$true}catch [System.IO.IOException]{Add-WsmSourceCandidateGap $checkpoint $dir 'DirectoryEnumerationFailed' $_.Exception.Message;$completedDirectory=$true}catch{Add-WsmSourceCandidateGap $checkpoint $dir 'DirectoryEnumerationFailed' $_.Exception.Message;$completedDirectory=$true}
            if($completedDirectory){$checkpoint.VisitedDirectories=@($checkpoint.VisitedDirectories)+@($dir);$checkpoint.CurrentDirectory='';$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@()}
            $checkpoint.Candidates=$candidateList.ToArray();$checkpoint.CurrentDirectorySeen=@($checkpoint.CurrentDirectorySeen);$checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc;Write-WsmJson $checkpointPath $checkpoint
            if($checkpoint.Status -ceq 'BudgetExhausted'){break}
            if($checkpoint.Status -cin @('ReplayBudgetExceeded','MetadataBudgetExceeded','AggregateEntryBudgetExceeded')){break}
        }
    }catch [System.OperationCanceledException]{$checkpoint.Candidates=$candidateList.ToArray();$checkpoint.CurrentDirectorySeen=@($checkpoint.CurrentDirectorySeen);Add-WsmSourceCandidateGap $checkpoint ([string]$checkpoint.CurrentDirectory) 'CancelledAtSafeBoundary';$checkpoint.Status='Partial'}
    if($checkpoint.Status -cnotin @('BudgetExhausted','ReplayBudgetExceeded','MetadataBudgetExceeded','AggregateEntryBudgetExceeded')){if(-not $checkpoint.CurrentDirectory -and @($checkpoint.Queue).Count -eq 0 -and $checkpoint.Status -cne 'Partial'){$checkpoint.Status='Succeeded'}elseif($checkpoint.Status -cne 'Succeeded'){$checkpoint.Status='Partial'}}
    $checkpoint.Candidates=$candidateList.ToArray();$checkpoint.CurrentDirectorySeen=@($checkpoint.CurrentDirectorySeen)
    if($checkpoint.Status -cin @('BudgetExhausted','Succeeded')){[void](Save-WsmSourceCandidateSegment $scanDir $checkpoint $Profile $InventoryHash $SourceRoot $policy ([string]$checkpoint.Status))}
    $workloadPresentation=Set-WsmSourceCandidateWorkloadReferences $checkpoint $Inventory $SourceRoot ([int]$policy.MaxWorkloadReferenceCount) ([long]$policy.MaxWorkloadReferenceBytes)
    $sameNameResult=Get-WsmSourceCandidateSameNameLinks $checkpoint @($workloadPresentation.Candidates)
    $checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc
    $candidatePath=Join-Path $scanDir 'candidates.json';$reportPath=Join-Path $scanDir 'review.html'
    $remainingDirectories=@();if($checkpoint.CurrentDirectory){$remainingDirectories+=@([string]$checkpoint.CurrentDirectory)};$remainingDirectories+=@($checkpoint.Queue)
    $canContinue=([long]$checkpoint.ScannedEntryCount -lt [long]$policy.MaxAggregateEntries -and ($checkpoint.Status -ceq 'Partial' -or ($checkpoint.Status -ceq 'BudgetExhausted' -and [int]$checkpoint.SegmentNumber -lt [int]$policy.MaxSegments)))
    $artifact=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceCandidateDiscovery';ScanId=$ScanId;Status=[string]$checkpoint.Status;SourceHostId=[string]$Profile.HostId;SourceFingerprint=([string]$Profile.Fingerprint).ToLowerInvariant();InventoryHash=$InventoryHash.ToLowerInvariant();InventoryRevision=[int]$Inventory.Revision;Root=[IO.Path]::GetFullPath($SourceRoot);RootPhysicalIdentity=[string]$policy.RootPhysicalIdentity;PolicyVersion=[int]$policy.PolicyVersion;PolicyHash=[string]$policy.PolicyHash;Coverage=[pscustomobject][ordered]@{VisitedDirectories=@($checkpoint.VisitedDirectories).Count;ScannedEntries=[long]$checkpoint.ScannedEntryCount;LegacyBaselineEntries=[long]$checkpoint.LegacyBaselineEntryCount;SegmentNumber=[int]$checkpoint.SegmentNumber;SegmentEntryCount=[long]$checkpoint.SegmentEntryCount;SegmentCount=([int]$checkpoint.Segments.Count);SegmentLimit=[int]$policy.MaxSegments;MaxAggregateEntries=[int]$policy.MaxAggregateEntries;MaxAggregatePathBytes=[long]$policy.MaxAggregatePathBytes;MaxWorkloadReferenceCount=[int]$policy.MaxWorkloadReferenceCount;MaxWorkloadReferenceBytes=[long]$policy.MaxWorkloadReferenceBytes;WorkloadReferencesTruncated=[long]$workloadPresentation.TruncatedWorkloadReferences;WorkloadReferenceDetailBytes=[long]$workloadPresentation.WorkloadReferenceDetailBytes;AssignedWorkloadReferenceBytes=[long]$workloadPresentation.AssignedWorkloadReferenceBytes;CandidateCount=@($checkpoint.Candidates).Count;GapCount=@($checkpoint.Gaps).Count;ExcludedAreaCount=@($checkpoint.ExcludedAreas).Count;BundleContentsRegionCount=@($checkpoint.ExcludedAreas|Where-Object {$_.PSObject.Properties['Contents'] -and $_.Contents}).Count;SameNameLinkCount=[long]$sameNameResult.Total;BundleHeaderBytesRead=[bool]@($checkpoint.ExcludedAreas|Where-Object {$_.PSObject.Properties['Contents'] -and $_.Contents}).Count;RemainingDirectories=@($remainingDirectories).Count;RemainingDirectoryPaths=@($remainingDirectories);UnmatchedKnownWorkloadReferences=@($workloadPresentation.UnmatchedWorkloadReferences).Count;SoftwareRootCoverageStatus=[string]$policy.SoftwareRootCoverageStatus;SoftwareRootCoverageGaps=@($policy.SoftwareRootCoverageGaps);Claim='Bounded-policy coverage only; unknown content is not discovered or claimed.'};Segments=@($checkpoint.Segments);Candidates=@($workloadPresentation.Candidates);UnmatchedWorkloadReferences=@($workloadPresentation.UnmatchedWorkloadReferences);Gaps=@($checkpoint.Gaps);ExcludedAreas=@($checkpoint.ExcludedAreas);SameNameLinks=@($sameNameResult.Links);SameNameLinksTruncated=[bool]$sameNameResult.Truncated;Continuation=[pscustomobject]@{ScanId=$ScanId;Required=$canContinue;ExplicitContinuationRequired=($checkpoint.Status -ceq 'BudgetExhausted' -and $canContinue);NextSegmentNumber=$(if($checkpoint.Status -ceq 'BudgetExhausted' -and $canContinue){$checkpoint.SegmentNumber+1}else{$null});FromCheckpointUtc=[string]$checkpoint.LastCheckpointUtc};CreatedUtc=[string]$checkpoint.CreatedUtc;UpdatedUtc=[string]$checkpoint.UpdatedUtc;AuthoritativeApproval=$false;ContentRead=$false}
    Write-WsmSourceCandidateReviewHtml $reportPath $checkpoint $policy $workloadPresentation.Candidates $workloadPresentation.UnmatchedWorkloadReferences @($sameNameResult.Links)
    if((Get-Item -LiteralPath $reportPath).Length -gt 100663296){Add-WsmSourceCandidateGap $checkpoint $SourceRoot 'ReviewReportSizeBudgetExceeded' 'The generated review report exceeded the 96 MiB safety preflight; detailed links were withheld.';$checkpoint.Status='MetadataBudgetExceeded';$canContinue=$false;$artifact.Status='MetadataBudgetExceeded';$artifact.Continuation.Required=$false;$artifact.Continuation.ExplicitContinuationRequired=$false;$artifact.Continuation.NextSegmentNumber=$null;$artifact.Gaps=@($checkpoint.Gaps);$artifact.Coverage.GapCount=@($checkpoint.Gaps).Count;$fallbackHtml='<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><title>來源候選審閱</title><body><h1>來源候選審閱</h1><p>報告超過 96 MiB 安全上限，未保留大型明細。請使用候選中繼資料檔並檢視記錄的涵蓋缺口；此探索不可續作。</p></body></html>';[IO.File]::WriteAllText($reportPath,$fallbackHtml,(New-Object Text.UTF8Encoding($false)))}
    Assert-WsmEnvelope $artifact 'SourceCandidateDiscovery';$artifactJson=$artifact|ConvertTo-Json -Depth 40 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($artifactJson) -gt 100663296){Add-WsmSourceCandidateGap $checkpoint $SourceRoot 'CandidateArtifactSizeBudgetExceeded' 'The candidate artifact exceeded the 96 MiB safety preflight; workload-reference detail was omitted.';$checkpoint.Status='MetadataBudgetExceeded';$canContinue=$false;$artifact.Status='MetadataBudgetExceeded';$artifact.Continuation.Required=$false;$artifact.Continuation.ExplicitContinuationRequired=$false;$artifact.Continuation.NextSegmentNumber=$null;$artifact.Candidates=@($checkpoint.Candidates);$artifact.UnmatchedWorkloadReferences=@();$artifact.Gaps=@($checkpoint.Gaps);$artifact.Coverage.GapCount=@($checkpoint.Gaps).Count;$artifact.Coverage.WorkloadReferenceDetailBytes=0;$artifact.Coverage.AssignedWorkloadReferenceBytes=0;$artifactJson=$artifact|ConvertTo-Json -Depth 40 -Compress;if([Text.Encoding]::UTF8.GetByteCount($artifactJson) -gt 100663296){throw 'The bounded candidate summary still exceeds the 96 MiB preflight; checkpoint remains durable and no candidate artifact was overwritten.'}}
    Write-WsmJson $candidatePath $artifact;Write-WsmJson $checkpointPath $checkpoint
    [pscustomobject][ordered]@{Status=$(if($checkpoint.Status -ceq 'Succeeded'){'Succeeded'}else{'ReviewRequired'});ScanId=$ScanId;ScanStatus=[string]$checkpoint.Status;SourceHostId=[string]$Profile.HostId;SourceFingerprint=[string]$Profile.Fingerprint;InventoryHash=$InventoryHash;InventoryRevision=[int]$Inventory.Revision;CandidateCount=@($checkpoint.Candidates).Count;ScannedEntryCount=[long]$checkpoint.ScannedEntryCount;SegmentNumber=[int]$checkpoint.SegmentNumber;SegmentCount=@($checkpoint.Segments).Count;GapCount=@($checkpoint.Gaps).Count;ExcludedAreaCount=@($checkpoint.ExcludedAreas).Count;RemainingDirectoryCount=([long]$artifact.Coverage.RemainingDirectories);CandidatePath=$candidatePath;CandidateHash=(Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant();ReportPath=$reportPath;ReportHash=(Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant();ContinuationRequired=$canContinue;ContinuationScanId=$(if($canContinue){$ScanId}else{''});ExplicitContinuationRequired=($checkpoint.Status -ceq 'BudgetExhausted' -and $canContinue);AuthoritativeApproval=$false;ContentRead=$false}
    } finally {if($scanLock){$scanLock.Dispose()}}
}

function Invoke-WsmSourceCandidateScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[string]$ScanId='',[switch]$ContinueAfterBudgetExhausted,[Parameter(DontShow)][object[]]$Jobs=@(),[Parameter(DontShow)][string]$OperationId='',[Parameter(DontShow)][object]$CancellationToken=$null)
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'C candidate discovery is available only in the enrolled Source workspace.'}
    if(-not $OperationId){$OperationId=[Guid]::NewGuid().ToString('D')}else{Assert-WsmId $OperationId}
    $state=Get-WsmWizardState $Workspace '' Source;$inventoryCandidate=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId)
    if(-not $inventoryCandidate -or $inventoryCandidate.Ambiguous){throw 'C candidate discovery requires one verified successful inventory job for the enrolled Source.'}
    if([string]$state.SourceInventoryHash -ine [string]$inventoryCandidate.SHA256 -or [long]$state.SourceInventoryRevision -ne [long]$inventoryCandidate.Inventory.Revision){throw 'C candidate discovery source inventory binding is stale; refresh and explicitly bind the current source inventory.'}
    $root=Get-WsmSourceCandidateRoot $Workspace $profile
    $token=$null;if($CancellationToken){$token=Assert-WsmCancellationTokenBinding $CancellationToken $profile.HostId $inventoryCandidate.SHA256 '' (Join-Path $Workspace 'hosts');if($token.OperationId -cne $OperationId){throw 'C candidate discovery cancellation token belongs to another operation.'}}
    # Eight 5k-entry segments provide useful explicit continuation while staying
    # below the aggregate JSON and path-metadata budgets.
    Invoke-WsmSourceCandidateScanCore $Workspace $profile $inventoryCandidate.Inventory $inventoryCandidate.SHA256 $root $ScanId $token 4000 25 5000 $null -ContinueAfterBudgetExhausted:$ContinueAfterBudgetExhausted
}
