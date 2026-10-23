#requires -Version 5.1
# Shared harness for the G scenario scripts (N9f): Test-G2DiscoveryToDelivery.ps1,
# Test-G3NonCFailureFreeze.ps1 and Test-G4MixedScope.ps1. It is dot-sourced by the scenario
# script, so every $script: variable below belongs to the scenario script's scope.
# It only provides: run id / paths, the immutable snapshot (hash before / after, equals the
# committed bytes), the verdict (same shape as the main journey: RunId, Stages, Checks,
# Overall) and cleanup (test root, snapshot, subst drives that this run created).
# ASCII only on purpose.

function Initialize-GScenario([string]$Tag,[string]$ScenarioName,[string]$RunId,[string]$Mutation) {
    if($RunId -notmatch '^[A-Za-z0-9]{6}$'){throw 'RunId must be exactly 6 alphanumeric characters.'}
    $script:GRepo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $script:GRunId=$RunId
    $script:GTag=$Tag
    $script:GTestRoot='C:\Users\Public\wsm-'+$Tag+'-'+$RunId
    $script:GRunDir=Join-Path (Join-Path $script:GRepo 'work\r7\g-journey') $RunId
    $script:GVerdict=[ordered]@{RunId=$RunId;Scenario=$ScenarioName;Mutation=$Mutation;StartedUtc=[DateTime]::UtcNow.ToString('o');Stages=@();Checks=[ordered]@{};Doubles=@();Notes=@();Overall='Failed'}
    $script:GFailed=$false
    $script:GSnapshot=$null
    $script:GSubsts=New-Object 'System.Collections.Generic.List[string]'
    $script:GModule=$null
}
function Write-GStage([int]$Number,[string]$Text) {
    Write-Host ('STAGE '+$Number+': '+$Text)
    $script:GVerdict.Stages+=@([ordered]@{Stage=$Number;Text=$Text;Utc=[DateTime]::UtcNow.ToString('o')})
}
function Set-GCheck([string]$Name,[bool]$Value,[string]$Detail='') {
    $script:GVerdict.Checks[$Name]=[ordered]@{Passed=$Value;Detail=$Detail}
    Write-Host ('  check '+$Name+' = '+$Value+$(if($Detail){' ('+$Detail+')'}else{''}))
}
function Add-GDouble([string]$Name,[string]$What) {
    $script:GVerdict.Doubles+=@([ordered]@{Name=$Name;What=$What})
}
function Get-GFileSha256([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        $stream=[IO.File]::Open($Path,'Open','Read','ReadWrite')
        try{[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose()}
    }finally{$sha.Dispose()}
}
function Get-GBytesSha256([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-GTextSha256([string]$Text) { Get-GBytesSha256 ([Text.Encoding]::UTF8.GetBytes($Text)) }
function Get-GSrcDigest([string]$SrcRoot) {
    $rows=@(Get-ChildItem -LiteralPath $SrcRoot -Recurse -File -Force | ForEach-Object {$_.FullName.Substring($SrcRoot.TrimEnd('\').Length+1).Replace('\','/')+'|'+(Get-GFileSha256 $_.FullName)} | Sort-Object {$_} -CaseSensitive)
    [pscustomobject]@{Digest=(Get-GTextSha256 ($rows -join "`n"));Rows=$rows}
}
function Get-GCommittedSrcDigest {
    # Tracked src/ bytes: working tree digest, plus the digest of git show HEAD:<path> (line-ending fallback). Read-only git.
    $listed=@(& git -C $script:GRepo ls-files -- src)
    if($LASTEXITCODE -ne 0 -or -not $listed.Count){throw 'git ls-files src failed.'}
    $workingRows=New-Object 'System.Collections.Generic.List[string]'
    foreach($relative in $listed){$workingRows.Add($relative.Substring(4)+'|'+(Get-GFileSha256 (Join-Path $script:GRepo $relative)))}
    $workingDigest=Get-GTextSha256 ((@($workingRows.ToArray() | Sort-Object {$_} -CaseSensitive)) -join "`n")
    $headRows=New-Object 'System.Collections.Generic.List[string]'
    foreach($relative in $listed){
        $psi=New-Object Diagnostics.ProcessStartInfo 'git',('-C "'+$script:GRepo+'" show HEAD:'+$relative)
        $psi.RedirectStandardOutput=$true;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($psi)
        $output=New-Object IO.MemoryStream
        $process.StandardOutput.BaseStream.CopyTo($output);$process.WaitForExit()
        if($process.ExitCode -ne 0){throw ('git show failed for '+$relative)}
        $headRows.Add($relative.Substring(4)+'|'+(Get-GBytesSha256 $output.ToArray()))
    }
    $headDigest=Get-GTextSha256 ((@($headRows.ToArray() | Sort-Object {$_} -CaseSensitive)) -join "`n")
    [pscustomobject]@{WorkingTreeDigest=$workingDigest;HeadDigest=$headDigest;FileCount=$listed.Count}
}

# Immutable snapshot of the tracked tree (work\r7\New-StageSnapshot.ps1), src marked read-only, digest recorded.
# The product module is imported from the snapshot, never from the working tree.
function New-GSnapshot([string[]]$AdditionalPaths=@()) {
    [void][IO.Directory]::CreateDirectory($script:GRunDir)
    $output=& (Join-Path $script:GRepo 'work\r7\New-StageSnapshot.ps1') -Name ('g-'+$script:GTag+'-'+$script:GRunId) -AdditionalPaths $AdditionalPaths
    $root=[IO.Path]::GetFullPath(@($output)[-1])
    if(-not [IO.Directory]::Exists((Join-Path $root 'src')) -or $root.IndexOf($script:GRunId) -lt 0){throw 'Snapshot was not created for this run.'}
    $script:GSnapshot=$root
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Force){$file.Attributes=$file.Attributes -bor [IO.FileAttributes]::ReadOnly}
    $before=Get-GSrcDigest (Join-Path $root 'src')
    $committed=Get-GCommittedSrcDigest
    $script:GDigestBefore=$before
    $script:GVerdict.Snapshot=[ordered]@{Root=$root;SrcDigestBefore=$before.Digest;SrcFileCount=$before.Rows.Count;CommittedWorkingTreeDigest=$committed.WorkingTreeDigest;CommittedHeadDigest=$committed.HeadDigest;CommittedFileCount=$committed.FileCount}
    Set-GCheck 'snapshot_src_equals_committed_bytes' (($before.Digest -ceq $committed.WorkingTreeDigest) -or ($before.Digest -ceq $committed.HeadDigest)) ('files='+$before.Rows.Count)
    $module=Import-Module (Join-Path $root 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
    if([IO.Path]::GetFullPath($module.ModuleBase).TrimEnd('\') -ine (Join-Path $root 'src').TrimEnd('\')){throw 'Module was not imported from the snapshot.'}
    $script:GModule=$module
    $script:GVerdict.ExecutionBytes='execution bytes = the snapshot src bytes, imported unchanged (no overlay, no file patched)'
    $module
}
function Confirm-GSnapshotUnchanged([string[]]$TestFiles=@()) {
    $after=Get-GSrcDigest (Join-Path $script:GSnapshot 'src')
    $script:GVerdict.Snapshot.SrcDigestAfter=$after.Digest
    Set-GCheck 'snapshot_src_digest_unchanged_after_run' ($after.Digest -ceq $script:GDigestBefore.Digest) 'snapshot digest before == after'
    $bytes=[ordered]@{};foreach($file in $TestFiles){$bytes[[IO.Path]::GetFileName($file)]=Get-GFileSha256 $file}
    $script:GVerdict.TestBytes=$bytes
}

# subst drives owned by this run (the second "volume" of the scenarios). Only drives created here are removed.
function New-GSubst([string]$Path) {
    $letter=(@('R','S','T','U','V','W','X','Y','Z') | Where-Object { -not (Test-Path -LiteralPath ($_+':\')) } | Select-Object -First 1)
    if(-not $letter){throw 'No free drive letter for the subst second volume.'}
    [void][IO.Directory]::CreateDirectory($Path)
    $out=& cmd.exe /c ('subst '+$letter+': "'+$Path.TrimEnd('\')+'"') 2>&1
    if($LASTEXITCODE -ne 0){throw ('subst failed: '+$out)}
    $script:GSubsts.Add($letter)
    $letter
}
function Remove-GSubsts([bool]$ClearContents=$false) {
    foreach($letter in @($script:GSubsts)){
        if($ClearContents){
            # the mapped folder holds the deep workspace trees; they are only reachable below MAX_PATH through the short drive
            try{
                foreach($file in Get-ChildItem -LiteralPath ($letter+':'+[char]92) -Recurse -File -Force -ErrorAction SilentlyContinue){if($file.Attributes -band [IO.FileAttributes]::ReadOnly){$file.Attributes=$file.Attributes -bxor [IO.FileAttributes]::ReadOnly}}
                Get-ChildItem -LiteralPath ($letter+':'+[char]92) -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction Stop
            }catch{Write-Host ('subst content cleanup problem: '+$_.Exception.Message)}
        }
        & cmd.exe /c ('subst '+$letter+': /D') 2>&1 | Out-Null
    }
    $script:GSubsts.Clear()
}

function Complete-GScenario([bool]$KeepArtifacts) {
    # called from the scenario's finally block
    try{Remove-GSubsts (-not $KeepArtifacts)}catch{Write-Host ('subst cleanup problem: '+$_.Exception.Message)}
    $allPassed=$true;foreach($key in $script:GVerdict.Checks.Keys){if(-not $script:GVerdict.Checks[$key].Passed){$allPassed=$false}}
    $script:GVerdict.CheckCount=$script:GVerdict.Checks.Count
    $script:GVerdict.Overall=if(-not $script:GFailed -and $allPassed -and $script:GVerdict.Checks.Count -gt 0){'Passed'}else{'Failed'}
    $script:GVerdict.CompletedUtc=[DateTime]::UtcNow.ToString('o')
    if([IO.Directory]::Exists($script:GRunDir)){[IO.File]::WriteAllText((Join-Path $script:GRunDir 'verdict.json'),($script:GVerdict|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false)))}
    if(-not $KeepArtifacts){
        foreach($path in @($script:GTestRoot,$script:GSnapshot)){
            if($path -and [IO.Directory]::Exists($path)){
                try{
                    $full=[IO.Path]::GetFullPath($path)
                    if($path -eq $script:GTestRoot){if(-not $full.StartsWith('C:\Users\Public\wsm-'+$script:GTag+'-'+$script:GRunId,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to remove a path this run does not own.'}}
                    elseif($full.IndexOf($script:GRunId) -lt 0){throw 'Snapshot path does not carry this run id.'}
                    foreach($file in Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue){if($file.Attributes -band [IO.FileAttributes]::ReadOnly){$file.Attributes=$file.Attributes -bxor [IO.FileAttributes]::ReadOnly}}
                    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
                }catch{Write-Host ('Cleanup left '+$path+': '+$_.Exception.Message)}
            }
        }
    }
    Write-Host ('Overall: '+$script:GVerdict.Overall+' (verdict: '+(Join-Path $script:GRunDir 'verdict.json')+')')
    if($script:GVerdict.Overall -ceq 'Passed'){Write-Host ('PASS: '+$script:GVerdict.Scenario+' (run '+$script:GRunId+', '+$script:GVerdict.Checks.Count+' checks, doubles '+@($script:GVerdict.Doubles).Count+')')}
    $script:GVerdict.Overall
}
