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
        PolicyVersion=1
        RootKind='CVolumeRoot'
        RootPhysicalIdentity=(Get-WsmPhysicalPath $Root)
        SoftwareRootCoverageStatus=[string]$softwareRoots.Status
        SoftwareRootCoverageGaps=@($coverageGaps.ToArray())
        MaxEntriesPerRun=4000
        MaxSecondsPerRun=25
        CheckpointEvery=20
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

function Assert-WsmSourceCandidateCheckpoint($Checkpoint,[string]$ScanId,$Profile,$Inventory,[string]$InventoryHash,[string]$SourceRoot,$Policy) {
    Assert-WsmFields $Checkpoint @('SchemaVersion','ToolVersion','Kind','ScanId','Status','SourceHostId','SourceFingerprint','InventoryHash','InventoryRevision','Root','RootPhysicalIdentity','PolicyVersion','PolicyHash','Queue','CurrentDirectory','CurrentDirectoryWriteUtc','CurrentDirectorySeen','Candidates','VisitedDirectories','ExcludedAreas','Gaps','ScannedEntryCount','CreatedUtc','UpdatedUtc','LastCheckpointUtc') @('SchemaVersion','ToolVersion','Kind','ScanId','Status','SourceHostId','SourceFingerprint','InventoryHash','InventoryRevision','Root','RootPhysicalIdentity','PolicyVersion','PolicyHash','Queue','CurrentDirectory','CurrentDirectoryWriteUtc','CurrentDirectorySeen','Candidates','VisitedDirectories','ExcludedAreas','Gaps','ScannedEntryCount','CreatedUtc','UpdatedUtc','LastCheckpointUtc')
    if($Checkpoint.SchemaVersion -ne 1 -or $Checkpoint.Kind -cne 'SourceCandidateDiscovery' -or [string]$Checkpoint.ToolVersion -cne $script:ToolVersion -or [string]$Checkpoint.ScanId -cne $ScanId -or $Checkpoint.Status -cnotin @('Running','Partial','BudgetExhausted')){throw 'Source candidate checkpoint schema or status is unsupported.'}
    if([string]$Checkpoint.SourceHostId -cne [string]$Profile.HostId -or [string]$Checkpoint.SourceFingerprint -ine [string]$Profile.Fingerprint -or [string]$Checkpoint.InventoryHash -ine $InventoryHash -or [long]$Checkpoint.InventoryRevision -ne [long]$Inventory.Revision){throw 'Source candidate checkpoint is stale for the currently verified source host or inventory.'}
    if([string]$Checkpoint.Root -ine [IO.Path]::GetFullPath($SourceRoot) -or [string]$Checkpoint.RootPhysicalIdentity -ine [string]$Policy.RootPhysicalIdentity -or [int]$Checkpoint.PolicyVersion -ne [int]$Policy.PolicyVersion -or [string]$Checkpoint.PolicyHash -ine [string]$Policy.PolicyHash){throw 'Source candidate checkpoint belongs to a different scan root, physical volume, or policy.'}
    if($Checkpoint.Queue -isnot [array] -or $Checkpoint.Candidates -isnot [array] -or $Checkpoint.VisitedDirectories -isnot [array] -or $Checkpoint.CurrentDirectorySeen -isnot [array] -or $Checkpoint.Gaps -isnot [array] -or $Checkpoint.ExcludedAreas -isnot [array]){throw 'Source candidate checkpoint collections are malformed.'}
    if(@($Checkpoint.Candidates).Count -gt [int]$Policy.MaxTotalEntries -or @($Checkpoint.VisitedDirectories).Count -gt [int]$Policy.MaxTotalEntries -or @($Checkpoint.Queue).Count -gt [int]$Policy.MaxTotalEntries -or [long]$Checkpoint.ScannedEntryCount -gt [long]$Policy.MaxTotalEntries){throw 'Source candidate checkpoint exceeds its bounded contract.'}
    foreach($path in @($Checkpoint.Queue)+@($Checkpoint.VisitedDirectories)+@($Checkpoint.CurrentDirectorySeen)+@($(if($Checkpoint.CurrentDirectory){[string]$Checkpoint.CurrentDirectory}else{@()}))){
        if(-not $path){throw 'Source candidate checkpoint contains an empty directory path.'};$full=[IO.Path]::GetFullPath([string]$path);$prefix=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')+'\';if($full -ine [IO.Path]::GetFullPath($SourceRoot) -and -not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Source candidate checkpoint contains a directory outside the enrolled C volume.'}
    }
    if([long]$Checkpoint.ScannedEntryCount -lt 0){throw 'Source candidate checkpoint entry count is invalid.'}
}

function New-WsmSourceCandidateCheckpoint([string]$ScanId,$Profile,$Inventory,[string]$InventoryHash,[string]$Root,$Policy) {
    $now=Get-WsmUtc
    [pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceCandidateDiscovery';ScanId=$ScanId;Status='Running';SourceHostId=[string]$Profile.HostId;SourceFingerprint=([string]$Profile.Fingerprint).ToLowerInvariant();InventoryHash=$InventoryHash.ToLowerInvariant();InventoryRevision=[int]$Inventory.Revision;Root=[IO.Path]::GetFullPath($Root);RootPhysicalIdentity=[string]$Policy.RootPhysicalIdentity;PolicyVersion=[int]$Policy.PolicyVersion;PolicyHash=[string]$Policy.PolicyHash;Queue=@([IO.Path]::GetFullPath($Root));CurrentDirectory='';CurrentDirectoryWriteUtc='';CurrentDirectorySeen=@();Candidates=@();VisitedDirectories=@();ExcludedAreas=@();Gaps=@();ScannedEntryCount=0L;CreatedUtc=$now;UpdatedUtc=$now;LastCheckpointUtc=$now}
}

function Add-WsmSourceCandidateGap($Checkpoint,[string]$Path,[string]$Reason,[string]$Detail='') {
    $safeDetail=$Detail;if($safeDetail.Length -gt 256){$safeDetail=$safeDetail.Substring(0,256)}
    $key=([string]$Path+'|'+$Reason).ToLowerInvariant()
    if(-not @($Checkpoint.Gaps|Where-Object {([string]$_.Path+'|'+[string]$_.Reason).ToLowerInvariant() -ceq $key}).Count){$Checkpoint.Gaps=@($Checkpoint.Gaps)+@([pscustomobject][ordered]@{Path=[string]$Path;Reason=$Reason;Detail=$safeDetail;ObservedUtc=(Get-WsmUtc)})}
}

function Add-WsmSourceCandidateExcluded($Checkpoint,[string]$Path,[string]$Reason) {
    if(-not @($Checkpoint.ExcludedAreas|Where-Object {[string]$_.Path -ieq $Path}).Count){$Checkpoint.ExcludedAreas=@($Checkpoint.ExcludedAreas)+@([pscustomobject][ordered]@{Path=$Path;Reason=$Reason})}
}

function Add-WsmSourceCandidate($Checkpoint,[string]$Path,[string]$CandidateType,$Info) {
    $full=[IO.Path]::GetFullPath($Path);$key=$full.ToLowerInvariant()
    if(@($Checkpoint.Candidates|Where-Object {[string]$_.Path.ToLowerInvariant() -ceq $key}).Count){return}
    $Checkpoint.Candidates=@($Checkpoint.Candidates)+@([pscustomobject][ordered]@{CandidateId=(Get-WsmHashText ($Checkpoint.SourceHostId+'|'+$Checkpoint.InventoryHash+'|'+$key+'|'+$CandidateType));CandidateType=$CandidateType;Path=$full;Length=$(if($CandidateType -ceq 'ExactFile'){[long]$Info.Length}else{$null});LastWriteUtc=[string]$Info.LastWriteTimeUtc;Attributes=[string]$Info.Attributes;WorkloadReferenceCount=0;WorkloadReferences=@();MetadataOnly=$true;UserDecisionRequired=$true;AuthoritativeApproval=$false})
}

function Set-WsmSourceCandidateWorkloadReferences($Checkpoint,$Inventory,[string]$Root) {
    $presented=@($Checkpoint.Candidates|ForEach-Object {$copy=$_|Select-Object *;$copy|Add-Member NoteProperty WorkloadReferenceCount 0 -Force;$copy|Add-Member NoteProperty WorkloadReferences @() -Force;$copy})
    $candidateByPath=@{};$directoryByPath=@{};$referenceLists=@{}
    foreach($candidate in $presented){$key=([IO.Path]::GetFullPath([string]$candidate.Path)).ToLowerInvariant();if(-not $candidateByPath.ContainsKey($key)){$candidateByPath[$key]=$candidate};if($candidate.CandidateType -ceq 'DirectoryRoot'){$directoryByPath[$key]=$candidate};$referenceLists[$key]=New-Object 'System.Collections.Generic.List[object]'}
    $known=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in @($Inventory.Items)){
        try{$references=@(Get-WsmWorkloadPathReferences $item)}catch{continue}
        foreach($reference in $references){
            $resolved=[string]$reference.ResolvedPath
            if(-not $resolved -or $reference.Opaque -or -not (Get-WsmSafeWorkloadPathProjection $resolved)){continue}
            try{$full=[IO.Path]::GetFullPath($resolved)}catch{continue}
            $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\');$prefix=$rootFull+'\'
            if($full -ine $rootFull -and -not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){continue}
            $known.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$reference.ConsumerItemId;FieldPointer=[string]$reference.FieldPointer;ReferenceKind=[string]$reference.ReferenceKind;Path=$full;Required=[bool]$(if($reference.PSObject.Properties['Required']){$reference.Required}else{$false});ReviewRequired=[bool]$(if($reference.PSObject.Properties['ReviewRequired']){$reference.ReviewRequired}else{$true})})
        }
    }
    $unmatched=New-Object 'System.Collections.Generic.List[object]'
    foreach($reference in $known){
        $matched=$false;$referenceKey=([IO.Path]::GetFullPath([string]$reference.Path)).ToLowerInvariant()
        if($candidateByPath.ContainsKey($referenceKey)){$referenceLists[$referenceKey].Add($reference);$matched=$true}
        $ancestor=[IO.Path]::GetDirectoryName([string]$reference.Path);$rootKey=([IO.Path]::GetFullPath($Root)).ToLowerInvariant()
        while($ancestor){
            $ancestorKey=([IO.Path]::GetFullPath($ancestor)).ToLowerInvariant()
            if($directoryByPath.ContainsKey($ancestorKey)){$referenceLists[$ancestorKey].Add($reference);$matched=$true}
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
    [pscustomobject]@{Candidates=$presented;UnmatchedWorkloadReferences=$unmatched.ToArray()}
}

function Write-WsmSourceCandidateReviewHtml([string]$Path,$Checkpoint,$Policy,[object[]]$Candidates=@(),[object[]]$UnmatchedWorkloadReferences=@()) {
    $enc={param($value)[System.Net.WebUtility]::HtmlEncode([string]$value)}
    $candidateTypeText={param($value)switch([string]$value){'ExactFile'{'精確檔案'}'DirectoryRoot'{'資料目錄'}default{[string]$value}}}
    $referenceKindText={param($value)switch([string]$value){'TaskCommand'{'排程工作命令'}'TaskWorkingDirectory'{'排程工作目錄'}'TaskArgumentPath'{'排程工作參數路徑'}'IISPhysicalPath'{'IIS 實體路徑'}'IISConfigSource'{'IIS 設定來源'}default{[string]$value}}}
    $gapReasonText={param($value)switch([string]$value){'ReparsePointNotFollowed'{'未跟隨重新解析點'}'PermissionDenied'{'存取遭拒'}'DirectoryUnavailable'{'目錄已不存在或無法使用'}'DirectoryMetadataFailed'{'讀取目錄中繼資料失敗'}'PhysicalPathResolutionFailed'{'無法解析實體路徑'}'PhysicalPathOutsideCVolume'{'實體路徑位於登錄 C 槽之外'}'SourceDirectoryChanged'{'續作前目錄中繼資料已變更'}'CumulativeEntryBudgetExceeded'{'已達累計項目數上限'}'CancelledAtSafeBoundary'{'已在安全檢查點取消'}'PathOutsideSystemVolume'{'路徑位於來源卷之外'}'DirectoryEnumerationFailed'{'列舉目錄失敗'}'MetadataReadFailed'{'讀取項目中繼資料失敗'}default{[string]$value}}}
    $rows=New-Object 'System.Text.StringBuilder'
    foreach($candidate in @($Candidates)){$links=@($candidate.WorkloadReferences|ForEach-Object {(& $referenceKindText $_.ReferenceKind)+' · '+([string]$_.ConsumerItemId)+' · '+([string]$_.FieldPointer)});$null=$rows.Append('<tr><td>');$null=$rows.Append((& $enc (& $candidateTypeText $candidate.CandidateType)));$null=$rows.Append('</td><td><code>');$null=$rows.Append((& $enc $candidate.Path));$null=$rows.Append('</code></td><td>');$null=$rows.Append((& $enc $candidate.Length));$null=$rows.Append('</td><td>');$null=$rows.Append((& $enc $candidate.LastWriteUtc));$null=$rows.Append('</td><td>');$null=$rows.Append((& $enc (@($links)-join '; ')));$null=$rows.Append('</td></tr>')}
    $gaps=New-Object 'System.Text.StringBuilder';foreach($gap in @($Checkpoint.Gaps)){$null=$gaps.Append('<li><code>');$null=$gaps.Append((& $enc $gap.Path));$null=$gaps.Append('</code> — ');$null=$gaps.Append((& $enc (& $gapReasonText $gap.Reason)));if($gap.Detail){$null=$gaps.Append(': ');$null=$gaps.Append((& $enc $gap.Detail))};$null=$gaps.Append('</li>')}
    $excluded=New-Object 'System.Text.StringBuilder';foreach($area in @($Checkpoint.ExcludedAreas)){$reason=[string]$area.Reason -replace '^Protected or package area excluded by policy: ','由保護或套件排除政策略過：' -replace '^FileScope guard: ','依既有檔案範圍保護規則略過：';$null=$excluded.Append('<li><code>');$null=$excluded.Append((& $enc $area.Path));$null=$excluded.Append('</code> — ');$null=$excluded.Append((& $enc $reason));$null=$excluded.Append('</li>')}
    $status=if($Checkpoint.Status -ceq 'Succeeded'){'已依記錄的有限範圍政策完成探索。'}elseif($Checkpoint.Status -ceq 'BudgetExhausted'){'本輪掃描已達累計項目數上限；此探索識別碼不可續作，重新開始也不保證涵蓋尚未探索的路徑。剩餘路徑須另行補查。'}else{'探索尚未完成；請以相同探索識別碼從已保存的檢查點繼續。'}
    $remaining=New-Object 'System.Text.StringBuilder';if($Checkpoint.CurrentDirectory){$null=$remaining.Append('<li><code>');$null=$remaining.Append((& $enc $Checkpoint.CurrentDirectory));$null=$remaining.Append('</code>（目前目錄；續作時會略過已記錄項目）</li>')};foreach($dir in @($Checkpoint.Queue)){$null=$remaining.Append('<li><code>');$null=$remaining.Append((& $enc $dir));$null=$remaining.Append('</code></li>')}
    $softwareGaps=New-Object 'System.Text.StringBuilder';foreach($gap in @($Policy.SoftwareRootCoverageGaps)){$text=[string]$gap -replace '^Installed-software root coverage is ','已安裝軟體根目錄涵蓋狀態為 ' -replace '; package directories may remain undiscovered or appear as candidates\.$','；套件目錄可能尚未探索或仍列為候選。';$null=$softwareGaps.Append('<li>');$null=$softwareGaps.Append((& $enc $text));$null=$softwareGaps.Append('</li>')}
    $referenceGaps=New-Object 'System.Text.StringBuilder';foreach($reference in @($UnmatchedWorkloadReferences)){$referenceStatus=switch([string]$reference.Status){'Pending'{'待探索'}'NotMatchedThisScan'{'未在本次候選中'}default{[string]$reference.Status}};$null=$referenceGaps.Append('<li><code>');$null=$referenceGaps.Append((& $enc $reference.Path));$null=$referenceGaps.Append('</code> — ');$null=$referenceGaps.Append((& $enc $referenceStatus));$null=$referenceGaps.Append('；項目 ');$null=$referenceGaps.Append((& $enc $reference.ConsumerItemId));$null=$referenceGaps.Append('；');$null=$referenceGaps.Append((& $enc $reference.FieldPointer));$null=$referenceGaps.Append('</li>')}
    $html='<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''"><title>來源 C 槽候選檔案審閱</title><style>body{font:16px system-ui,"Microsoft JhengHei",sans-serif;margin:2rem;color:#17202a}h1,h2{color:#17365d}.summary{padding:1rem;background:#eef4fb;border-left:4px solid #315f8a}table{border-collapse:collapse;width:100%;margin:1rem 0}th,td{border:1px solid #bbb;padding:.45rem;text-align:left;vertical-align:top}code{overflow-wrap:anywhere}li{margin:.35rem 0}.note{color:#444}</style></head><body><h1>來源 C 槽候選檔案審閱</h1><section class="summary"><p><strong>'+(& $enc $status)+'</strong></p><p>探索識別碼（ScanId）：<code>'+(& $enc $Checkpoint.ScanId)+'</code></p><p>來源主機：<code>'+(& $enc $Checkpoint.SourceHostId)+'</code>；盤點修訂版 '+(& $enc $Checkpoint.InventoryRevision)+'；盤點 SHA-256 <code>'+(& $enc $Checkpoint.InventoryHash)+'</code></p><p>政策版本 '+(& $enc $Checkpoint.PolicyVersion)+'；已檢查目錄數 '+(& $enc @($Checkpoint.VisitedDirectories).Count)+'；中繼資料項目數 '+(& $enc $Checkpoint.ScannedEntryCount)+'；候選數 '+(& $enc @($Checkpoint.Candidates).Count)+'；缺口數 '+(& $enc @($Checkpoint.Gaps).Count)+'</p><p>已安裝軟體根目錄涵蓋狀態：'+(& $enc $Policy.SoftwareRootCoverageStatus)+'</p></section><p class="note">本報告只記錄中繼資料，未讀取檔案內容或執行指令碼。這些候選項目不會建立 FileScope 或移轉核准。C 槽根目錄中的散置檔案會列為精確檔案候選。刻意排除的路徑與尚未探索的涵蓋範圍分別列示；本次探索不代表已發現所有未知資料。</p><h2>尚待探索的目錄</h2><ul>'+[string]$remaining+'</ul><h2>已安裝軟體根目錄涵蓋缺口</h2><ul>'+[string]$softwareGaps+'</ul><h2>依已知工作負載路徑優先呈現候選項目</h2><p>關聯僅供審閱，不代表檔案已獲核准或納入移轉範圍。</p><table><thead><tr><th>類型</th><th>路徑</th><th>位元組</th><th>最後寫入時間（UTC）</th><th>已知工作負載參照（類型 · 項目 ID · 欄位位置）</th></tr></thead><tbody>'+[string]$rows+'</tbody></table><h2>尚未匹配候選的已知工作負載路徑</h2><ul>'+[string]$referenceGaps+'</ul><h2>涵蓋缺口</h2><ul>'+[string]$gaps+'</ul><h2>政策排除路徑</h2><ul>'+[string]$excluded+'</ul></body></html>'
    [IO.File]::WriteAllText($Path,$html,(New-Object Text.UTF8Encoding($false)))
}

function Invoke-WsmSourceCandidateScanCore([string]$Workspace,$Profile,$Inventory,[string]$InventoryHash,[string]$SourceRoot,[string]$ScanId='',[object]$CancellationToken=$null,[int]$MaxEntries=4000,[int]$MaxSeconds=25,[int]$MaxTotalEntries=50000,[scriptblock]$CancellationTestHook=$null) {
    if($MaxEntries -lt 1 -or $MaxEntries -gt 4000 -or $MaxSeconds -lt 1 -or $MaxSeconds -gt 25){throw 'Source candidate scan budget exceeds its fixed safety limit.'}
    if($MaxTotalEntries -lt 1 -or $MaxTotalEntries -gt 50000){throw 'Source candidate cumulative entry budget exceeds its fixed safety limit.'}
    $policy=Get-WsmSourceCandidatePolicy $SourceRoot $Inventory $Workspace;$policy|Add-Member NoteProperty MaxTotalEntries $MaxTotalEntries;$policy.PolicyHash=Get-WsmHashText (($policy|Select-Object * -ExcludeProperty PolicyHash|ConvertTo-Json -Depth 8 -Compress));$store=Get-WsmSourceCandidateStoreRoot $Workspace $Profile
    $resumeRequested=[bool]$ScanId
    if(-not $ScanId){$ScanId=[Guid]::NewGuid().ToString('D')}else{Assert-WsmId $ScanId}
    $scanDir=Join-Path $store $ScanId;if(-not [IO.Directory]::Exists($scanDir)){if($resumeRequested){throw 'The requested durable source candidate scan does not exist.'};[void](New-WsmOutputOwnedDirectory $scanDir)}else{[void](New-WsmOutputOwnedDirectory $scanDir)}
    Assert-WsmNoReparse $scanDir
    $scanLockPath=Join-Path $scanDir 'scan.lock';Assert-WsmNoReparse $scanLockPath;$scanLock=$null
    try{$scanLock=[IO.File]::Open($scanLockPath,'OpenOrCreate','ReadWrite','None')}catch [System.IO.IOException]{throw 'Another process is already running this source candidate ScanId; wait and resume after it exits.'}
    try {
    $checkpointPath=Join-Path $scanDir 'checkpoint.json';$checkpoint=$null
    if([IO.File]::Exists($checkpointPath)) {Assert-WsmNoReparse $checkpointPath;$checkpoint=Read-WsmJson $checkpointPath;Assert-WsmSourceCandidateCheckpoint $checkpoint $ScanId $Profile $Inventory $InventoryHash $SourceRoot $policy} elseif($resumeRequested){throw 'The requested durable source candidate checkpoint is missing; it was not reset.'}
    else {$checkpoint=New-WsmSourceCandidateCheckpoint $ScanId $Profile $Inventory $InventoryHash $SourceRoot $policy}
    if($checkpoint.Status -ceq 'BudgetExhausted'){throw 'This source candidate ScanId reached its cumulative entry budget and is terminal; review its durable gaps before starting a new scan.'}
    $checkpoint.Status='Running'
    $watch=[Diagnostics.Stopwatch]::StartNew();$entriesThisRun=0;$sinceSave=0
    try {
        while(@($checkpoint.Queue).Count -gt 0 -or $checkpoint.CurrentDirectory) {
            if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken 'SourceCandidateEntry'}
            if([long]$checkpoint.ScannedEntryCount -ge [long]$policy.MaxTotalEntries){Add-WsmSourceCandidateGap $checkpoint ([string]$checkpoint.CurrentDirectory) 'CumulativeEntryBudgetExceeded' ('The maximum of '+[string]$policy.MaxTotalEntries+' metadata entries has been reached; this ScanId is terminal.');$checkpoint.Status='BudgetExhausted';break}
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
            if($excludedRelative){Add-WsmSourceCandidateExcluded $checkpoint $dir ('Protected or package area excluded by policy: '+$excludedRelative);$checkpoint.CurrentDirectory='';$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@();continue}
            $completedDirectory=$true
            # The checkpoint may outlive this process. Recheck the entire lexical chain
            # and physical volume immediately before opening the directory enumerator.
            $enumerationState=Get-WsmSourceCandidateDirectoryState $dir $SourceRoot $policy
            if($enumerationState.Status -cne 'Ready'){Add-WsmSourceCandidateGap $checkpoint $dir $enumerationState.Reason $enumerationState.Detail;$checkpoint.CurrentDirectory='';$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@();$checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc;Write-WsmJson $checkpointPath $checkpoint;continue}
            try {
                foreach($entryPath in [IO.Directory]::EnumerateFileSystemEntries($dir)) {
                    if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken 'SourceCandidateEntry'}
                    $full=[IO.Path]::GetFullPath($entryPath);$rootPrefix=[IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')+'\';if($full -ine [IO.Path]::GetFullPath($SourceRoot) -and -not $full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){Add-WsmSourceCandidateGap $checkpoint $full 'PathOutsideSystemVolume';continue}
                    if(@($checkpoint.CurrentDirectorySeen|Where-Object {([string]$_) -ieq $full}).Count){continue}
                    if([long]$checkpoint.ScannedEntryCount -ge [long]$policy.MaxTotalEntries){Add-WsmSourceCandidateGap $checkpoint $dir 'CumulativeEntryBudgetExceeded' ('The maximum of '+[string]$policy.MaxTotalEntries+' metadata entries has been reached; this ScanId is terminal.');$checkpoint.Status='BudgetExhausted';$completedDirectory=$false;break}
                    if($entriesThisRun -ge $MaxEntries -or $watch.Elapsed.TotalSeconds -ge $MaxSeconds){$completedDirectory=$false;break}
                    $entriesThisRun++;$checkpoint.ScannedEntryCount=[long]$checkpoint.ScannedEntryCount+1;$sinceSave++
                    $checkpoint.CurrentDirectorySeen=@($checkpoint.CurrentDirectorySeen)+@($full)
                    try {
                        $info=Get-Item -LiteralPath $full -Force -ErrorAction Stop
                        if(($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){Add-WsmSourceCandidateGap $checkpoint $full 'ReparsePointNotFollowed';continue}
                        $skip=Test-WsmSourceCandidateExcludedPath $full $SourceRoot $policy
                        if($skip){Add-WsmSourceCandidateExcluded $checkpoint $full ('Protected or package area excluded by policy: '+$skip);continue}
                        if($info.PSIsContainer){
                            Add-WsmSourceCandidate $checkpoint $full 'DirectoryRoot' $info
                            if(-not @($checkpoint.VisitedDirectories|Where-Object {([string]$_) -ieq $full}).Count -and -not @($checkpoint.Queue|Where-Object {([string]$_) -ieq $full}).Count){$checkpoint.Queue=@($checkpoint.Queue)+@($full)}
                        }else{Add-WsmSourceCandidate $checkpoint $full 'ExactFile' $info}
                    }catch [System.UnauthorizedAccessException]{Add-WsmSourceCandidateGap $checkpoint $full 'PermissionDenied'}catch [System.IO.IOException]{Add-WsmSourceCandidateGap $checkpoint $full 'MetadataReadFailed' $_.Exception.Message}catch{Add-WsmSourceCandidateGap $checkpoint $full 'MetadataReadFailed' $_.Exception.Message}
                    finally{if($CancellationTestHook){& $CancellationTestHook $checkpoint $CancellationToken};if($sinceSave -ge [int]$policy.CheckpointEvery){$checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc;Write-WsmJson $checkpointPath $checkpoint;$sinceSave=0}}
                }
            }catch [System.OperationCanceledException]{throw}catch [System.UnauthorizedAccessException]{Add-WsmSourceCandidateGap $checkpoint $dir 'PermissionDenied';$completedDirectory=$true}catch [System.IO.IOException]{Add-WsmSourceCandidateGap $checkpoint $dir 'DirectoryEnumerationFailed' $_.Exception.Message;$completedDirectory=$true}catch{Add-WsmSourceCandidateGap $checkpoint $dir 'DirectoryEnumerationFailed' $_.Exception.Message;$completedDirectory=$true}
            if($completedDirectory){$checkpoint.VisitedDirectories=@($checkpoint.VisitedDirectories)+@($dir);$checkpoint.CurrentDirectory='';$checkpoint.CurrentDirectoryWriteUtc='';$checkpoint.CurrentDirectorySeen=@()}
            $checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc;Write-WsmJson $checkpointPath $checkpoint
            if($checkpoint.Status -ceq 'BudgetExhausted'){break}
        }
    }catch [System.OperationCanceledException]{Add-WsmSourceCandidateGap $checkpoint ([string]$checkpoint.CurrentDirectory) 'CancelledAtSafeBoundary';$checkpoint.Status='Partial'}
    if($checkpoint.Status -cne 'BudgetExhausted'){if(-not $checkpoint.CurrentDirectory -and @($checkpoint.Queue).Count -eq 0 -and $checkpoint.Status -cne 'Partial'){$checkpoint.Status='Succeeded'}elseif($checkpoint.Status -cne 'Succeeded'){$checkpoint.Status='Partial'}}
    $workloadPresentation=Set-WsmSourceCandidateWorkloadReferences $checkpoint $Inventory $SourceRoot
    $checkpoint.UpdatedUtc=Get-WsmUtc;$checkpoint.LastCheckpointUtc=$checkpoint.UpdatedUtc
    $candidatePath=Join-Path $scanDir 'candidates.json';$reportPath=Join-Path $scanDir 'review.html'
    $remainingDirectories=@();if($checkpoint.CurrentDirectory){$remainingDirectories+=@([string]$checkpoint.CurrentDirectory)};$remainingDirectories+=@($checkpoint.Queue)
    $artifact=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SourceCandidateDiscovery';ScanId=$ScanId;Status=[string]$checkpoint.Status;SourceHostId=[string]$Profile.HostId;SourceFingerprint=([string]$Profile.Fingerprint).ToLowerInvariant();InventoryHash=$InventoryHash.ToLowerInvariant();InventoryRevision=[int]$Inventory.Revision;Root=[IO.Path]::GetFullPath($SourceRoot);RootPhysicalIdentity=[string]$policy.RootPhysicalIdentity;PolicyVersion=[int]$policy.PolicyVersion;PolicyHash=[string]$policy.PolicyHash;Coverage=[pscustomobject][ordered]@{VisitedDirectories=@($checkpoint.VisitedDirectories).Count;ScannedEntries=[long]$checkpoint.ScannedEntryCount;CandidateCount=@($checkpoint.Candidates).Count;GapCount=@($checkpoint.Gaps).Count;ExcludedAreaCount=@($checkpoint.ExcludedAreas).Count;RemainingDirectories=@($remainingDirectories).Count;RemainingDirectoryPaths=@($remainingDirectories);UnmatchedKnownWorkloadReferences=@($workloadPresentation.UnmatchedWorkloadReferences).Count;SoftwareRootCoverageStatus=[string]$policy.SoftwareRootCoverageStatus;SoftwareRootCoverageGaps=@($policy.SoftwareRootCoverageGaps);Claim='Bounded-policy coverage only; unknown content is not discovered or claimed.'};Candidates=@($workloadPresentation.Candidates);UnmatchedWorkloadReferences=@($workloadPresentation.UnmatchedWorkloadReferences);Gaps=@($checkpoint.Gaps);ExcludedAreas=@($checkpoint.ExcludedAreas);Continuation=[pscustomobject]@{ScanId=$ScanId;Required=($checkpoint.Status -ceq 'Partial');FromCheckpointUtc=[string]$checkpoint.LastCheckpointUtc};CreatedUtc=[string]$checkpoint.CreatedUtc;UpdatedUtc=[string]$checkpoint.UpdatedUtc;AuthoritativeApproval=$false;ContentRead=$false}
    Assert-WsmEnvelope $artifact 'SourceCandidateDiscovery';Write-WsmJson $candidatePath $artifact;Write-WsmSourceCandidateReviewHtml $reportPath $checkpoint $policy $workloadPresentation.Candidates $workloadPresentation.UnmatchedWorkloadReferences;Write-WsmJson $checkpointPath $checkpoint
    [pscustomobject][ordered]@{Status=$(if($checkpoint.Status -ceq 'Succeeded'){'Succeeded'}else{'ReviewRequired'});ScanId=$ScanId;ScanStatus=[string]$checkpoint.Status;SourceHostId=[string]$Profile.HostId;SourceFingerprint=[string]$Profile.Fingerprint;InventoryHash=$InventoryHash;InventoryRevision=[int]$Inventory.Revision;CandidateCount=@($checkpoint.Candidates).Count;ScannedEntryCount=[long]$checkpoint.ScannedEntryCount;VisitedDirectoryCount=@($checkpoint.VisitedDirectories).Count;GapCount=@($checkpoint.Gaps).Count;ExcludedAreaCount=@($checkpoint.ExcludedAreas).Count;RemainingDirectoryCount=([long]$artifact.Coverage.RemainingDirectories);CandidatePath=$candidatePath;CandidateHash=(Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant();ReportPath=$reportPath;ReportHash=(Get-FileHash -LiteralPath $reportPath -Algorithm SHA256).Hash.ToLowerInvariant();ContinuationRequired=($checkpoint.Status -ceq 'Partial');ContinuationScanId=$(if($checkpoint.Status -ceq 'Partial'){$ScanId}else{''});AuthoritativeApproval=$false;ContentRead=$false}
    } finally {if($scanLock){$scanLock.Dispose()}}
}

function Invoke-WsmSourceCandidateScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[string]$ScanId='',[Parameter(DontShow)][object[]]$Jobs=@(),[Parameter(DontShow)][string]$OperationId='',[Parameter(DontShow)][object]$CancellationToken=$null)
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'C candidate discovery is available only in the enrolled Source workspace.'}
    if(-not $OperationId){$OperationId=[Guid]::NewGuid().ToString('D')}else{Assert-WsmId $OperationId}
    $state=Get-WsmWizardState $Workspace '' Source;$inventoryCandidate=Get-WsmWizardInventoryFromJobs $Workspace $profile $Jobs ([string]$state.SourceInventoryHash) ([string]$state.InventoryJobId)
    if(-not $inventoryCandidate -or $inventoryCandidate.Ambiguous){throw 'C candidate discovery requires one verified successful inventory job for the enrolled Source.'}
    if([string]$state.SourceInventoryHash -ine [string]$inventoryCandidate.SHA256 -or [long]$state.SourceInventoryRevision -ne [long]$inventoryCandidate.Inventory.Revision){throw 'C candidate discovery source inventory binding is stale; refresh and explicitly bind the current source inventory.'}
    $root=Get-WsmSourceCandidateRoot $Workspace $profile
    $token=$null;if($CancellationToken){$token=Assert-WsmCancellationTokenBinding $CancellationToken $profile.HostId $inventoryCandidate.SHA256 '' (Join-Path $Workspace 'hosts');if($token.OperationId -cne $OperationId){throw 'C candidate discovery cancellation token belongs to another operation.'}}
    Invoke-WsmSourceCandidateScanCore $Workspace $profile $inventoryCandidate.Inventory $inventoryCandidate.SHA256 $root $ScanId $token
}
