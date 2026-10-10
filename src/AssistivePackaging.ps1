function Initialize-WsmAssistiveCapacityApi {
    if('WsmAssistiveCapacity' -as [type]){return}
    # https://learn.microsoft.com/windows/win32/api/fileapi/nf-fileapi-getdiskfreespaceexw
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class WsmAssistiveCapacity {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetDiskFreeSpaceExW(string path, out ulong available, out ulong total, out ulong free);
    public static long Available(string path) {
        ulong available, total, free;
        if(!GetDiskFreeSpaceExW(path, out available, out total, out free)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if(available>long.MaxValue) throw new InvalidOperationException("Capacity exceeds supported signed byte range.");
        return (long)available;
    }
}
'@
}

function Get-WsmAssistiveAvailableBytes([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith([string][char]92+[char]92)){throw 'UNC capacity requires an explicit storage-specific procedure.'}
    Assert-WsmNoReparse $full;$cursor=$full
    while(-not [IO.Directory]::Exists($cursor)){$parent=[IO.Path]::GetDirectoryName($cursor.TrimEnd([char]92));if(-not $parent -or $parent -ceq $cursor){throw 'Capacity directory is unavailable.'};$cursor=$parent}
    Initialize-WsmAssistiveCapacityApi
    [WsmAssistiveCapacity]::Available($cursor)
}

function Get-WsmAssistivePackageMaterialRows($Package) {
    $root=$Package.Root;$seen=@{};$rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($name in @('manifest.json','plan.json','artifacts.jsonl','freeze.json')){
        $path=Join-Path $root $name
        if([IO.File]::Exists($path)){$rows.Add([pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();Kind=('PackageControl/'+$name)})}
    }
    foreach($artifact in (Read-WsmArtifactLines (Join-Path $root 'artifacts.jsonl') $Package.Manifest.ArtifactsHash)){
        if($artifact.Data){foreach($chunk in $artifact.Data.Chunks){if(-not $seen.ContainsKey([string]$chunk.Hash)){$seen[[string]$chunk.Hash]=$true;$rows.Add([pscustomobject]@{Path=(Join-Path (Join-Path $root 'payload') ($chunk.Hash+'.blob'));SHA256=[string]$chunk.Hash;Kind='PayloadChunk'})}}}
    }
    $rows.ToArray()
}

function Start-WsmAssistiveSourcePackageJob {
    param([string]$PlanPath,[string]$PlanHash,[string]$SourceStateDirectory,[string]$BaseManifestPath,[string]$BaseManifestHash)
    $plan=Read-WsmMigrationPlan $PlanPath $PlanHash
    if($plan.SchemaVersion -ne 3){return $null}
    Assert-WsmMigrationHost (Get-WsmMachineIdentity) $plan.Source.Fingerprint
    Assert-WsmSourceWorkspaceSeparation $plan $SourceStateDirectory
    $generation=1;$materials=@([pscustomobject]@{Path=$PlanPath;SHA256=$PlanHash;Kind='SealedSourcePlan'})
    if($BaseManifestPath){$base=Test-WsmMigrationPackage $BaseManifestPath $BaseManifestHash;if($base.Manifest.PairId -cne $plan.PairId -or $base.Manifest.PlanHash -ine $PlanHash){throw 'Package retention base belongs to a different source plan.'};$generation=[int]$base.Manifest.Generation+1;$materials+=@(Get-WsmAssistivePackageMaterialRows $base)}
    $operation=[Guid]::NewGuid().ToString();$consumer='SourcePackage/'+$generation+'/'+$operation
    $batch=Register-WsmAssistiveMaterialBatch $SourceStateDirectory $plan.PairId $generation $materials @($consumer)
    Set-WsmAssistiveJobLock -Workspace $SourceStateDirectory -PairId $plan.PairId -Generation $generation -OperationId $operation -MaterialIds @($batch.MaterialIds) -Active $true | Out-Null
    [pscustomobject]@{PairId=$plan.PairId;Generation=$generation;OperationId=$operation;Consumer=$consumer;MaterialIds=@($batch.MaterialIds);Workspace=$SourceStateDirectory}
}

function Complete-WsmAssistiveSourcePackageJob($Job,$Result,[bool]$Succeeded) {
    if(-not $Job){return}
    if($Succeeded -and $Result -and $Result.ManifestPath){
        $package=Test-WsmMigrationPackage $Result.ManifestPath $Result.SHA256
        $batch=Register-WsmAssistiveMaterialBatch $Job.Workspace $Job.PairId $Job.Generation @(Get-WsmAssistivePackageMaterialRows $package) @($Job.Consumer)
        $Job.MaterialIds=@(@($Job.MaterialIds)+@($batch.MaterialIds)|Sort-Object -Unique)
    }
    # Failed/interrupted operations retain their references; only the live lock ends.
    Set-WsmAssistiveJobLock -Workspace $Job.Workspace -PairId $Job.PairId -Generation $Job.Generation -OperationId $Job.OperationId -MaterialIds @($Job.MaterialIds) -Active $false | Out-Null
}
