#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-full-budgets-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        foreach($name in @('manifest.json','plan.json')){[IO.File]::WriteAllText((Join-Path $Root $name),'{}')}
        $artifactPath=Join-Path $Root 'artifacts.jsonl';$stream=[IO.File]::Open($artifactPath,'Create','Write','None');try{$stream.SetLength(128MB)}finally{$stream.Dispose()}
        $package=[pscustomobject]@{Root=$Root;Manifest=[pscustomobject]@{Final=$false;ArtifactsHash=('a'*64)}}
        $blocked=$false;try{@(Get-WsmPackageMembers $package)|Out-Null}catch{$blocked=$_.Exception.Message -match 'aggregate 128 MiB'}
        if(-not $blocked){throw 'Oversized full delivery metadata was not rejected before transport output.'}
        [IO.File]::WriteAllText($artifactPath,'')
        function Read-WsmArtifactLines {
            param($Path,$Hash)
            $chunks=New-Object 'System.Collections.Generic.List[object]'
            for($n=0;$n -lt 99998;$n++){$chunks.Add([pscustomobject]@{Hash=$n.ToString('x64');Bytes=1})}
            [pscustomobject]@{Directory=$false;Data=[pscustomobject]@{Chunks=$chunks.ToArray()}}
        }
        $blocked=$false;try{@(Get-WsmPackageMembers $package)|Out-Null}catch{$blocked=$_.Exception.Message -match '100000-member'}
        if(-not $blocked){throw 'Full ZIP/directory member producer exceeded its budget.'}
        if(@(Get-ChildItem -LiteralPath $Root -File).Count -ne 3){throw 'Budget denial created delivery files.'}
        'PASS: actual full-delivery member producer rejects oversized aggregate metadata and synthetic 100001-member input before transport output; no bulk payload corpus created.'
    } $root
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup path.'}
    if([IO.Directory]::Exists($resolved)){[IO.Directory]::Delete($resolved,$true)}
}
