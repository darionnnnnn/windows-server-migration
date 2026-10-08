function Test-WsmKnownConfigPath([string]$RelativePath,[string]$SourceRoot='') {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { if ([string]::IsNullOrWhiteSpace($SourceRoot)) { return $false }; $leaf=[IO.Path]::GetFileName($SourceRoot.TrimEnd('\')) }
    else { $leaf = [IO.Path]::GetFileName($RelativePath) }
    return ($leaf -imatch '^web\.config$' -or $leaf -imatch '^app\.config$' -or $leaf -imatch '\.exe\.config$' -or $leaf -imatch '^appsettings.*\.json$')
}
function Get-WsmConfigSpecEntries($Spec,[string]$Name) {
    $property=$Spec.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return @() }
    @($property.Value)
}
function Open-WsmTrustedConfigIndex([string]$Path,[string]$ExpectedHash,$CancellationToken=$null) {
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Trusted artifact index hash required.' }
    Assert-WsmNoReparse $Path
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read');$sha=[Security.Cryptography.SHA256]::Create()
    try { $actual=Get-WsmCancellableStreamHash $stream $CancellationToken 'ConfigIndexHashBuffer' } catch { $stream.Dispose(); throw } finally { $sha.Dispose() }
    if ($actual -ine $ExpectedHash) { $stream.Dispose(); throw 'Trusted artifact index hash mismatch.' }
    $stream.Position=0
    $stream
}
function Read-WsmConfigBoundedLines($Reader,[int]$MaximumCharacters=1048576) {
    $buffer=New-Object char[] 65536;$pending=New-Object Text.StringBuilder
    while(($length=$Reader.Read($buffer,0,$buffer.Length)) -gt 0) {
        $chunk=New-Object string($buffer,0,$length);$start=0
        while($start -lt $chunk.Length) {
            $end=$chunk.IndexOf([char]10,$start);$finish=$chunk.Length;if($end -ge 0){$finish=$end};$size=$finish-$start
            if($pending.Length+$size -gt $MaximumCharacters){throw 'Artifact row exceeds bounded line limit.'}
            if($size){[void]$pending.Append($chunk,$start,$size)}
            if($end -lt 0){break}
            $line=$pending.ToString().TrimEnd([char]13);$pending.Clear()|Out-Null;if($line){$line};$start=$end+1
        }
    }
    if($pending.Length){$pending.ToString().TrimEnd([char]13)}
}

function Get-WsmConfigArtifactDraft {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactsPath,
        [Parameter(Mandatory)][string]$ExpectedHash,
        [Parameter(Mandatory)][string]$ItemId,
        [string[]]$OwnerRelativePaths = @(),
        [string]$SourcePath = ''
    )
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Trusted artifact index hash required.' }
    if ($ItemId -notmatch '^[a-f0-9]{64}$') { throw 'Invalid configuration artifact ItemId.' }
    $ownerPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $OwnerRelativePaths) { Assert-WsmRelativePath $path -AllowRoot; if (-not $ownerPaths.Add($path)) { throw 'Duplicate/case-colliding owner configuration path.' } }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stream = Open-WsmTrustedConfigIndex $ArtifactsPath $ExpectedHash
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        Read-WsmConfigBoundedLines $reader | ForEach-Object {
            $line=$_
            $row = ConvertFrom-WsmJson $line
            if ([string]$row.ItemId -ceq $ItemId) {
                Assert-WsmFields $row @('ItemId','RelativePath','Directory','Metadata','Data') @('ItemId','RelativePath','Directory','Metadata','Data')
                if ($row.Directory -is [bool] -and -not $row.Directory -and $null -ne $row.Data) {
                    Assert-WsmRelativePath ([string]$row.RelativePath) -AllowRoot
                    $path = [string]$row.RelativePath
                    if ((Test-WsmKnownConfigPath $path $SourcePath) -or $ownerPaths.Contains($path)) {
                        if (-not $seen.Add($path)) { throw 'Duplicate/case-colliding configuration artifact path.' }
                        if ([string]$row.Data.Hash -notmatch '^[a-f0-9]{64}$') { throw 'Configuration artifact is missing a valid content hash.' }
                        [pscustomobject][ordered]@{ RelativePath=$path; SHA256=([string]$row.Data.Hash).ToLowerInvariant(); Owner=''; Evidence='' }
                    }
                }
            }
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Export-WsmConfigArtifactScopeDraft {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SpecPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$ItemId,[Parameter(Mandatory)][string]$Path)
    $spec=Read-WsmTrustedJson $SpecPath $ExpectedHash
    if ($spec.Adapter -cne 'FileScope' -or [string]::IsNullOrWhiteSpace([string]$spec.SourcePath) -or -not $spec.PSObject.Properties['ExcludedRelativePaths']) { throw 'Configuration source draft requires a hash-pinned FileScope spec with source path and exclusions.' }
    if ($ItemId -notmatch '^[a-f0-9]{64}$') { throw 'Invalid configuration artifact ItemId.' }
    $source=[IO.Path]::GetFullPath([string]$spec.SourcePath);$sourceRoot=[IO.Path]::GetPathRoot($source);if($source.Length -gt $sourceRoot.Length){$source=$source.TrimEnd('\')}; if ($source.StartsWith('\\')) { throw 'Configuration draft does not support unresolved UNC source scopes.' }
    if (-not [IO.File]::Exists($source) -and -not [IO.Directory]::Exists($source)) { throw 'Configuration draft source scope is absent.' }
    Assert-WsmNoReparse $source
    $output=[IO.Path]::GetFullPath($Path); $outputDir=[IO.Path]::GetDirectoryName($output)
    if ([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)) { throw 'Configuration draft output must be a new file.' }
    Assert-WsmNoReparse $outputDir
    $physicalSource=Get-WsmPhysicalPath $source; $physicalOutput=Get-WsmPhysicalPath $outputDir
    if ((Test-WsmPathOverlap $source $output) -or (Test-WsmPathOverlap $physicalSource $physicalOutput)) { throw 'Configuration draft output overlaps the source FileScope.' }
    $ownerPaths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $configFiles=@(Get-WsmConfigSpecEntries $spec 'ConfigFiles');$configOverrides=@(Get-WsmConfigSpecEntries $spec 'ConfigOverrides')
    if ($configOverrides.Count) { Assert-WsmConfigArtifactSpec $spec }
    foreach ($entry in $configFiles) { Assert-WsmRelativePath ([string]$entry.RelativePath) -AllowRoot; [void]$ownerPaths.Add([string]$entry.RelativePath) }
    foreach ($entry in $configOverrides) { if ($entry.Classification -ceq 'Configuration') { Assert-WsmRelativePath ([string]$entry.RelativePath) -AllowRoot; [void]$ownerPaths.Add([string]$entry.RelativePath) } }
    $businessOverrides=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $configOverrides) { if ($entry.Classification -ceq 'BusinessData') { [void]$businessOverrides.Add([string]$entry.RelativePath) } }
    $temp=$output+'.'+[Guid]::NewGuid().ToString('N')+'.partial'; $writer=$null
    try {
        $writer=New-Object IO.StreamWriter($temp,$false,(New-Object Text.UTF8Encoding($false))); $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($source);$found=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        while ($stack.Count) {
            $current=$stack.Pop();$relative=$current.Substring($source.Length).TrimStart('\');$excluded=$false
            foreach ($exclude in @($spec.ExcludedRelativePaths)) { if ($relative -ieq [string]$exclude -or ($relative -and $relative.StartsWith(([string]$exclude).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))) { $excluded=$true;break } }
            if ($excluded) { continue }; Assert-WsmRelativePath $relative -AllowRoot; Assert-WsmNoReparse $current
            if ([IO.Directory]::Exists($current)) { foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($current)) { $stack.Push($child) }; continue }
            if ((Test-WsmKnownConfigPath $relative ([string]$spec.SourcePath)) -or $ownerPaths.Contains($relative)) {
                if ($businessOverrides.Contains($relative)) { continue }
                if (-not $found.Add($relative)) { throw 'Duplicate/case-colliding configuration source path.' }
                $entry=[pscustomobject][ordered]@{RelativePath=$relative;SHA256=(Get-WsmConfigFileHash $current);Owner='';Evidence=''}
                $writer.WriteLine((ConvertTo-Json -InputObject $entry -Depth 8 -Compress))
            }
        }
        $writer.Flush();$writer.Dispose();$writer=$null
        if ([IO.File]::Exists($output)) { throw 'Configuration draft output appeared during write.' };[IO.File]::Move($temp,$output)
        [pscustomobject]@{Path=$output;ItemId=$ItemId;ReviewStatus='Draft';RequiresOwnerEvidenceReview=$true;ConfigCount=$found.Count;ConfigOverrides=$configOverrides;SHA256=(Get-WsmConfigFileHash $output);ProductionVerified=$false}
    } finally { if ($writer) { $writer.Dispose() }; if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Export-WsmConfigArtifactReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$ExpectedHash,
        [Parameter(Mandatory)][string]$Path
    )
    # This is a source-local, read-only review. It binds to the independently
    # approved plan and never includes configuration contents in its output.
    $plan=Read-WsmMigrationPlan $PlanPath $ExpectedHash
    Assert-WsmMigrationHost (Get-WsmMachineIdentity) $plan.Source.Fingerprint
    $output=[IO.Path]::GetFullPath($Path)
    $outputDirectory=[IO.Path]::GetDirectoryName($output)
    Assert-WsmNoReparse $outputDirectory
    foreach($item in $plan.Items){
        if($item.Decision -ceq 'Include' -and $item.MigrationSpec.Adapter -ceq 'FileScope'){
            if((Test-WsmPathOverlap ([IO.Path]::GetFullPath($item.MigrationSpec.SourcePath)) $output) -or (Test-WsmPathOverlap (Get-WsmPhysicalPath $item.MigrationSpec.SourcePath) (Get-WsmPhysicalPath $outputDirectory))){
                throw 'Configuration review output overlaps an approved source FileScope.'
            }
        }
    }

    if(-not [IO.Directory]::Exists($outputDirectory)){
        [void][IO.Directory]::CreateDirectory($outputDirectory)
        Protect-WsmDirectory $outputDirectory
    }else{
        Assert-WsmCancellationDirectoryProtection $outputDirectory
    }
    Assert-WsmNoReparse $outputDirectory
    $changesPath=$output+'.jsonl'
    if($output -ieq $changesPath -or [IO.File]::Exists($output) -or [IO.Directory]::Exists($output) -or [IO.File]::Exists($changesPath) -or [IO.Directory]::Exists($changesPath)){
        throw 'Configuration review outputs must be distinct new files; existing evidence is never overwritten.'
    }
    $temporaryChanges=$changesPath+'.'+[Guid]::NewGuid().ToString('N')+'.partial'
    $temporarySummary=$output+'.'+[Guid]::NewGuid().ToString('N')+'.partial'
    $writer=$null;$publishedChanges=$false
    $counts=[ordered]@{Added=[long]0;Modified=[long]0;Deleted=[long]0;Unchanged=[long]0}
    $approvedByKey=@{};$seenByKey=@{}
    try{
        $writer=New-Object IO.StreamWriter($temporaryChanges,$false,(New-Object Text.UTF8Encoding($false)))
        foreach($item in $plan.Items){
            if($item.Decision -cne 'Include' -or $item.MigrationSpec.Adapter -cne 'FileScope'){continue}
            $spec=$item.MigrationSpec
            Assert-WsmConfigArtifactSpec $spec
            $overrides=@{};foreach($entry in (Get-WsmConfigSpecEntries $spec 'ConfigOverrides')){$overrides[[string]$entry.RelativePath]=$entry}
            foreach($entry in (Get-WsmConfigSpecEntries $spec 'ConfigFiles')){
                $key=[string]$item.ItemId+'|'+([string]$entry.RelativePath).ToUpperInvariant()
                $approvedByKey[$key]=[pscustomobject]@{ItemId=[string]$item.ItemId;RelativePath=[string]$entry.RelativePath;SHA256=([string]$entry.SHA256).ToLowerInvariant()}
            }
            foreach($entry in (Get-WsmConfigSpecEntries $spec 'ConfigOverrides')){
                if($entry.Classification -ceq 'Configuration'){
                    $key=[string]$item.ItemId+'|'+([string]$entry.RelativePath).ToUpperInvariant()
                    if(-not $approvedByKey.ContainsKey($key)){$approvedByKey[$key]=$null}
                }
            }

            Get-WsmScopeEntries $spec $outputDirectory | ForEach-Object {
                $entry=$_
                if($entry.Directory){return}
                $relative=[string]$entry.RelativePath
                $isBusinessOverride=$overrides.ContainsKey($relative) -and $overrides[$relative].Classification -ceq 'BusinessData'
                if($isBusinessOverride -or -not ((Test-WsmKnownConfigPath $relative ([string]$spec.SourcePath)) -or $overrides.ContainsKey($relative) -or $approvedByKey.ContainsKey(([string]$item.ItemId+'|'+$relative.ToUpperInvariant())))){return}
                $key=[string]$item.ItemId+'|'+$relative.ToUpperInvariant()
                if($seenByKey.ContainsKey($key)){throw 'Duplicate/case-colliding configuration source path.'}
                $seenByKey[$key]=$true
                $actual=Get-WsmCancellableFileHash $entry.SourcePath $null 'ConfigReviewSourceHashBuffer'
                $approved='';if($approvedByKey.ContainsKey($key) -and $null -ne $approvedByKey[$key]){$approved=[string]$approvedByKey[$key].SHA256}
                $change='Unchanged';$requiresReapproval=$false
                if(-not $approved){$change='Added';$requiresReapproval=$true}
                elseif($actual -ine $approved){$change='Modified';$requiresReapproval=$true}
                $counts[$change]++
                $row=[pscustomobject][ordered]@{ItemId=[string]$item.ItemId;RelativePath=$relative;Change=$change;SHA256=$actual;ApprovedSHA256=$approved;RequiresReapproval=$requiresReapproval}
                $writer.WriteLine(($row | ConvertTo-Json -Depth 6 -Compress))
            }
        }
        foreach($key in @($approvedByKey.Keys | Sort-Object -CaseSensitive)){
            if($seenByKey.ContainsKey($key)){continue}
            $approved=$approvedByKey[$key]
            if($null -eq $approved){continue}
            $counts.Deleted++
            $row=[pscustomobject][ordered]@{ItemId=$approved.ItemId;RelativePath=$approved.RelativePath;Change='Deleted';SHA256='';ApprovedSHA256=$approved.SHA256;RequiresReapproval=$true}
            $writer.WriteLine(($row | ConvertTo-Json -Depth 6 -Compress))
        }
        $writer.Flush();$writer.Dispose();$writer=$null
        $changesHash=Get-WsmCancellableFileHash $temporaryChanges $null 'ConfigReviewOutputHashBuffer'
        $observed=(Get-WsmUtc)
        $summary=[pscustomobject][ordered]@{
            SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='ConfigArtifactReview';PairId=$plan.PairId;PlanHash=$ExpectedHash.ToLowerInvariant();ToolFingerprint=$plan.ToolFingerprint
            SourceHostId=$plan.Source.HostId;SourceFingerprint=$plan.Source.Fingerprint;DecisionRevision=$plan.DecisionRevision;ObservedUtc=$observed
            RequiresReapproval=([long]$counts.Added+[long]$counts.Modified+[long]$counts.Deleted -gt 0);Counts=[pscustomobject]$counts
            ChangesReportPath=$changesPath;ChangesSHA256=$changesHash;Mode='ReadOnlySourceReview';ProductionVerified=$false
        }
        Write-WsmJson $temporarySummary $summary
        if([IO.File]::Exists($output) -or [IO.File]::Exists($changesPath)){throw 'Configuration review output appeared during write; existing evidence was retained.'}
        [IO.File]::Move($temporaryChanges,$changesPath);$publishedChanges=$true
        [IO.File]::Move($temporarySummary,$output)
        [pscustomobject]@{Path=$output;SHA256=(Get-WsmCancellableFileHash $output $null 'ConfigReviewSummaryHashBuffer');ChangesReportPath=$changesPath;ChangesSHA256=$changesHash;RequiresReapproval=$summary.RequiresReapproval;Counts=$summary.Counts;ObservedUtc=$observed;Mode=$summary.Mode;ProductionVerified=$false}
    }catch{
        if($publishedChanges -and [IO.File]::Exists($changesPath)){[IO.File]::Delete($changesPath)}
        throw
    }finally{
        if($writer){$writer.Dispose()}
        foreach($temp in @($temporaryChanges,$temporarySummary)){if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
}

function Get-WsmConfigFileHash([string]$Path) {
    $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path), 'Open', 'Read', 'Read')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Assert-WsmConfigArtifactSpec($Spec) {
    if (-not $Spec.PSObject.Properties['ConfigFiles'] -and -not $Spec.PSObject.Properties['ConfigOverrides']) { return }
    $configPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in (Get-WsmConfigSpecEntries $Spec 'ConfigFiles')) {
        Assert-WsmFields $entry @('RelativePath','SHA256','Owner','Evidence') @('RelativePath','SHA256','Owner','Evidence')
        Assert-WsmRelativePath ([string]$entry.RelativePath) -AllowRoot
        if (-not $configPaths.Add([string]$entry.RelativePath)) { throw 'Duplicate/case-colliding configuration path in approved spec.' }
        if ([string]$entry.SHA256 -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace([string]$entry.Owner) -or [string]::IsNullOrWhiteSpace([string]$entry.Evidence)) { throw 'Approved configuration file requires exact SHA256, Owner, and Evidence.' }
    }
    $overridePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in (Get-WsmConfigSpecEntries $Spec 'ConfigOverrides')) {
        Assert-WsmFields $entry @('RelativePath','Classification','Owner','Evidence','Reason') @('RelativePath','Classification','Owner','Evidence','Reason')
        Assert-WsmRelativePath ([string]$entry.RelativePath) -AllowRoot
        if (-not $overridePaths.Add([string]$entry.RelativePath)) { throw 'Configuration override must use a unique exact relative path.' }
        if ([string]$entry.Classification -cnotin @('Configuration','BusinessData') -or [string]::IsNullOrWhiteSpace([string]$entry.Owner) -or [string]::IsNullOrWhiteSpace([string]$entry.Evidence) -or [string]::IsNullOrWhiteSpace([string]$entry.Reason)) { throw 'Configuration override requires a supported classification, Owner, Evidence, and Reason.' }
        if ([string]$entry.RelativePath -match '[*?\[\]]') { throw 'Configuration overrides require one exact relative path; wildcards are forbidden.' }
        if ($entry.Classification -ceq 'BusinessData' -and $configPaths.Contains([string]$entry.RelativePath)) { throw 'BusinessData override cannot bypass an approved ConfigFiles hash baseline.' }
    }
}

function Assert-WsmApprovedConfigArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Spec,[Parameter(Mandatory)][string]$ArtifactsPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$ItemId,$CancellationToken=$null)
    Assert-WsmConfigArtifactSpec $Spec
    $overrides = @{}; foreach ($entry in (Get-WsmConfigSpecEntries $Spec 'ConfigOverrides')) { $overrides[[string]$entry.RelativePath] = $entry }
    $approved = @{}; foreach ($entry in (Get-WsmConfigSpecEntries $Spec 'ConfigFiles')) { $approved[[string]$entry.RelativePath] = $entry }
    $required = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $approved.Keys) { [void]$required.Add($path) }
    foreach ($path in $overrides.Keys) { if ($overrides[$path].Classification -ceq 'Configuration') { [void]$required.Add($path) } }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $stream = Open-WsmTrustedConfigIndex $ArtifactsPath $ExpectedHash $CancellationToken
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        Read-WsmConfigBoundedLines $reader | ForEach-Object {
            Assert-WsmCancellationBoundary $CancellationToken 'ConfigArtifactRow'
            $line=$_
            $row = ConvertFrom-WsmJson $line
            if ([string]$row.ItemId -ceq $ItemId) {
                Assert-WsmFields $row @('ItemId','RelativePath','Directory','Metadata','Data') @('ItemId','RelativePath','Directory','Metadata','Data')
                if ($row.Directory -isnot [bool]) { throw 'Invalid configuration artifact directory marker.' }
                if (-not $row.Directory) {
                    $path = [string]$row.RelativePath; Assert-WsmRelativePath $path -AllowRoot
                    $isDetected = (Test-WsmKnownConfigPath $path ([string]$Spec.SourcePath)) -or $required.Contains($path)
                    if ($isDetected -and -not ($overrides.ContainsKey($path) -and $overrides[$path].Classification -ceq 'BusinessData')) {
                        if (-not $seen.Add($path)) { throw 'Duplicate/case-colliding configuration artifact path.' }
                        if (-not $approved.ContainsKey($path)) { throw ('Configuration artifact has no approved hash/owner/evidence: '+$path) }
                        if ($null -eq $row.Data -or [string]$row.Data.Hash -notmatch '^[a-f0-9]{64}$' -or [string]$row.Data.Hash -ine [string]$approved[$path].SHA256) { throw ('Configuration artifact bytes drifted from the approved MigrationSpec: '+$path) }
                    }
                }
            }
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
    foreach ($path in $required) { if (-not $seen.Contains($path) -and -not ($overrides.ContainsKey($path) -and $overrides[$path].Classification -ceq 'BusinessData')) { throw ('Approved configuration artifact is missing from source export: '+$path) } }
    [pscustomobject]@{ Valid=$true; ConfigCount=$seen.Count; ApprovalSource='MigrationSpec' }
}

function Compare-WsmConfigArtifactIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseArtifactsPath,[Parameter(Mandatory)][string]$BaseArtifactsHash,
        [Parameter(Mandatory)][string]$CurrentArtifactsPath,[Parameter(Mandatory)][string]$CurrentArtifactsHash,
        [Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$BasePlanHash,[Parameter(Mandatory)][string]$CurrentPlanHash,
        [Parameter(Mandatory)]$BaseManifest,[Parameter(Mandatory)][string]$BaseManifestHash,
        [Parameter(Mandatory)]$CurrentManifest,[Parameter(Mandatory)][string]$CurrentManifestHash
    )
    if ($BasePlanHash -notmatch '^[a-fA-F0-9]{64}$' -or $BasePlanHash -ine $CurrentPlanHash) { throw 'Configuration comparison requires the same approved plan hash.' }
    if ($Plan.PairId -cne $BaseManifest.PairId -or $Plan.BatchId -cne $BaseManifest.BatchId -or $Plan.ApprovalId -cne $BaseManifest.ApprovalId -or
        $Plan.Source.HostId -cne $BaseManifest.Source.HostId -or $Plan.Source.Fingerprint -cne $BaseManifest.Source.Fingerprint -or
        $Plan.Target.HostId -cne $BaseManifest.Target.HostId -or $Plan.Target.Fingerprint -cne $BaseManifest.Target.Fingerprint) { throw 'Configuration comparison plan does not bind the trusted package identity.' }
    if ($BaseManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or $CurrentManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or
        $BaseManifest.PlanHash -ine $BasePlanHash -or $CurrentManifest.PlanHash -ine $CurrentPlanHash -or
        $BaseManifest.ArtifactsHash -ine $BaseArtifactsHash -or $CurrentManifest.ArtifactsHash -ine $CurrentArtifactsHash -or
        $BaseManifest.PairId -cne $CurrentManifest.PairId -or $BaseManifest.BatchId -cne $CurrentManifest.BatchId -or
        $BaseManifest.ApprovalId -cne $CurrentManifest.ApprovalId -or $BaseManifest.Source.Fingerprint -cne $CurrentManifest.Source.Fingerprint -or
        $BaseManifest.Target.Fingerprint -cne $CurrentManifest.Target.Fingerprint -or
        ($BaseManifest.Generation -isnot [int] -and $BaseManifest.Generation -isnot [long]) -or ($CurrentManifest.Generation -isnot [int] -and $CurrentManifest.Generation -isnot [long]) -or
        $BaseManifest.Generation -lt 1 -or $CurrentManifest.Generation -ne ($BaseManifest.Generation + 1) -or
        $CurrentManifest.Final -isnot [bool] -or -not $CurrentManifest.Final -or $CurrentManifest.BaseManifestHash -ine $BaseManifestHash) { throw 'Configuration comparison manifest, approval, or generation binding mismatch.' }
    $included = @{}; foreach ($item in $Plan.Items) { if ($item.Decision -eq 'Include' -and $item.MigrationSpec.Adapter -eq 'FileScope') { $included[[string]$item.ItemId] = $item } }
    $base = Read-WsmConfigArtifactIndex $BaseArtifactsPath $BaseArtifactsHash $included
    $current = Read-WsmConfigArtifactIndex $CurrentArtifactsPath $CurrentArtifactsHash $included
    $changes = New-Object 'System.Collections.Generic.List[object]'
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $base.Keys) { [void]$keys.Add($key) }; foreach ($key in $current.Keys) { [void]$keys.Add($key) }
    foreach ($key in @($keys | Sort-Object -CaseSensitive)) {
        $b = $base[$key]; $c = $current[$key]
        if ($null -eq $b) { $kind='Added'; $before=''; $after=$c.SHA256 }
        elseif ($null -eq $c) { $kind='Deleted'; $before=$b.SHA256; $after='' }
        elseif ($b.SHA256 -ine $c.SHA256) { $kind='Modified'; $before=$b.SHA256; $after=$c.SHA256 }
        else { continue }
        $changeItemId='';$changePath=''
        if ($null -ne $c) { $changeItemId=$c.ItemId; $changePath=$c.RelativePath } else { $changeItemId=$b.ItemId; $changePath=$b.RelativePath }
        $changes.Add([pscustomobject][ordered]@{ItemId=$changeItemId;RelativePath=$changePath;Change=$kind;BaseSHA256=$before;CurrentSHA256=$after;RequiresReapproval=$true})
    }
    [pscustomobject]@{Valid=$true;RequiresReapproval=($changes.Count -gt 0);Changes=$changes.ToArray();BaseGeneration=[long]$BaseManifest.Generation;CurrentGeneration=[long]$CurrentManifest.Generation;PlanHash=$BasePlanHash.ToLowerInvariant()}
}

function Read-WsmConfigArtifactIndex([string]$Path,[string]$ExpectedHash,$Included) {
    $rows = @{}; $stream=Open-WsmTrustedConfigIndex $Path $ExpectedHash;$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
    try {
        Read-WsmConfigBoundedLines $reader | ForEach-Object {
            $row=ConvertFrom-WsmJson $_; Assert-WsmFields $row @('ItemId','RelativePath','Directory','Metadata','Data') @('ItemId','RelativePath','Directory','Metadata','Data')
            if ($Included.ContainsKey([string]$row.ItemId)) {
                if ($row.Directory -isnot [bool]) { throw 'Invalid configuration artifact directory marker.' }
                if (-not $row.Directory) {
                    $path=[string]$row.RelativePath; Assert-WsmRelativePath $path -AllowRoot
                    $spec=$Included[[string]$row.ItemId].MigrationSpec;$specOverrides=@(Get-WsmConfigSpecEntries $spec 'ConfigOverrides');$specFiles=@(Get-WsmConfigSpecEntries $spec 'ConfigFiles');$override=@($specOverrides | Where-Object {$_.RelativePath -ieq $path} | Select-Object -First 1)
                    $isBusinessData=($override.Count -and $override[0].Classification -ceq 'BusinessData')
                    $isConfig=(Test-WsmKnownConfigPath $path ([string]$spec.SourcePath)) -or @($specFiles | Where-Object {$_.RelativePath -ieq $path}).Count -gt 0 -or ($override.Count -and $override[0].Classification -ceq 'Configuration')
                    if ($isConfig -and -not $isBusinessData) {
                        if ($null -eq $row.Data -or [string]$row.Data.Hash -notmatch '^[a-f0-9]{64}$') { throw 'Configuration artifact is missing a valid byte hash.' }
                        $key=[string]$row.ItemId+'|'+$path.ToUpperInvariant();if ($rows.ContainsKey($key)) { throw 'Duplicate/case-colliding configuration artifact path.' }
                        $rows[$key]=[pscustomobject]@{ItemId=[string]$row.ItemId;RelativePath=$path;SHA256=([string]$row.Data.Hash).ToLowerInvariant()}
                    }
                }
            }
        }
    } finally {$reader.Dispose();$stream.Dispose()}
    return $rows
}
