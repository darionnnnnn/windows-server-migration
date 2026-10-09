#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
& $module {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $root=Join-Path $tempRoot ('wsm-full-zip-checkpoint-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    try {
        $packageRoot=Join-Path $root 'package';[void][IO.Directory]::CreateDirectory($packageRoot)
        $script:checkpointPackage=[pscustomobject]@{Root=$packageRoot;Manifest=[pscustomobject]@{PackageId=[Guid]::NewGuid().ToString();PairId=[Guid]::NewGuid().ToString();PlanHash=('a'*64)}}
        $script:checkpointMembers=@(foreach($index in 1..3){$bytes=New-Object byte[] 900000;$bytes[0]=[byte]$index;$file=Join-Path $packageRoot ($index.ToString()+'.blob');[IO.File]::WriteAllBytes($file,$bytes);$hash=(Get-FileHash $file).Hash.ToLowerInvariant();[pscustomobject]@{Name=('payload/'+$hash+'.blob');Path=$file;Bytes=$bytes.Length;Hash=$hash}})
        # The package validation boundary is isolated; ZIP bytes, hashes, locks,
        # member verification and durable checkpoint handling are real.
        function Test-WsmMigrationPackage {param($ManifestPath,$ExpectedHash,$CancellationToken) $script:checkpointPackage}
        function Get-WsmPackageMembers {param($Package) $script:checkpointMembers}
        $output=Join-Path $root 'output';$export=Export-WsmPackageZip 'fixture-manifest.json' ('b'*64) $output -VolumeBytes 1048576
        if($export.Volumes -ne 3){throw 'Fixture did not produce three actual volumes.'}
        $statePath=Join-Path $output 'zip-state.json';$state=Read-WsmJson $statePath
        $originalRecords=$state.Volumes | ConvertTo-Json -Depth 8 -Compress
        $missingPath=Join-Path $output $state.Volumes[1].Name;$originalBytes=[IO.File]::ReadAllBytes($missingPath);[IO.File]::Delete($missingPath)
        $missingFailure='';try{Export-WsmPackageZip 'fixture-manifest.json' ('b'*64) $output -VolumeBytes 1048576 | Out-Null}catch{$missingFailure=$_.Exception.Message}
        $failed=Read-WsmJson $statePath
        if($missingFailure -notmatch 'Completed ZIP volume is missing' -or $failed.Status -cne 'Failed' -or $failed.FailureReason -notmatch 'missing' -or ($failed.Volumes | ConvertTo-Json -Depth 8 -Compress) -cne $originalRecords){throw 'Missing later volume erased checkpoints or failed to persist diagnostics.'}
        if((Get-FileHash $export.Path).Hash -ine $export.SHA256){throw 'Failed retry modified the immutable transport index.'}
        [IO.File]::WriteAllBytes($missingPath,$originalBytes)
        $changedPath=Join-Path $output $state.Volumes[2].Name;$originalChangedBytes=[IO.File]::ReadAllBytes($changedPath)
        $stream=[IO.File]::Open($changedPath,'Append','Write','None');try{$stream.WriteByte(1)}finally{$stream.Dispose()}
        $changedFailure='';try{Export-WsmPackageZip 'fixture-manifest.json' ('b'*64) $output -VolumeBytes 1048576 | Out-Null}catch{$changedFailure=$_.Exception.Message}
        $failed=Read-WsmJson $statePath
        if($changedFailure -notmatch 'Previously completed ZIP volume changed' -or $failed.Status -cne 'Failed' -or ($failed.Volumes | ConvertTo-Json -Depth 8 -Compress) -cne $originalRecords){throw 'Changed later volume was adopted or lost the original checkpoint hashes.'}
        [IO.File]::WriteAllBytes($changedPath,$originalChangedBytes)
        $retry=Export-WsmPackageZip 'fixture-manifest.json' ('b'*64) $output -VolumeBytes 1048576
        $sealed=Read-WsmJson $statePath
        if($retry.SHA256 -ine $export.SHA256 -or $sealed.Status -cne 'Sealed' -or $sealed.FailureReason){throw 'Verified original volume recovery changed transport identity or retained failed status.'}
        Write-Output 'PASS: real full ZIP missing/changed later volumes retain every sealed checkpoint, persist failure, and recover only from identical original bytes.'
    } finally {
        $absolute=[IO.Path]::GetFullPath($root)
        if(-not $absolute.StartsWith($tempRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe ZIP checkpoint fixture cleanup.'}
        if([IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
    }
}
