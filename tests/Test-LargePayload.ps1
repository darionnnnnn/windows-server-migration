#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-large-file-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$payload=Join-Path $root 'payload';[void][IO.Directory]::CreateDirectory($payload);$source=Join-Path $root 'source.bin';$target=Join-Path $root 'restored.bin';$size=[long]4GB+17
$free=(New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))).AvailableFreeSpace;if($free -lt 12GB){throw 'Large-file fixture requires 12 GiB free; not executed.'}
$watch=[Diagnostics.Stopwatch]::StartNew()
try{
    $stream=[IO.File]::Open($source,'CreateNew','Write','None');try{$stream.SetLength($size);$stream.Position=$size-1;$stream.WriteByte(7);$stream.Flush($true)}finally{$stream.Dispose()}
    $data=& $module {param($Path,$BlobRoot) Write-WsmPayloadFile $Path $BlobRoot 8388608} $source $payload
    if($data.Bytes -ne $size -or @($data.Chunks).Count -ne 513){throw '64-bit file/chunk length lost above 4 GiB'}
    & $module {param($Data,$Root,$Target) Restore-WsmPayloadBytes ([pscustomobject]@{Data=$Data}) $Root $Target} $data $root $target
    if((New-Object IO.FileInfo($target)).Length -ne $size -or (Get-FileHash -LiteralPath $target).Hash -ine $data.Hash){throw 'Large file reconstruction differs'}
    $stream=[IO.File]::Open($target,'Open','Read','Read');try{$stream.Position=$size-1;if($stream.ReadByte() -ne 7){throw 'Large file tail lost'}}finally{$stream.Dispose()}
    $evidence=[pscustomobject]@{Bytes=$size;Chunks=@($data.Chunks).Count;UniqueChunks=@(Get-ChildItem $payload -File).Count;SHA256=$data.Hash;ElapsedSeconds=$watch.Elapsed.TotalSeconds;RealFileFixture=$true;ServerQualification=$false}
    [IO.File]::WriteAllText((Join-Path $root 'result.json'),($evidence | ConvertTo-Json))
    Write-Host ('PASS: actual >4 GiB export/hash/chunks/dedup/reconstruction/tail; '+$watch.Elapsed.TotalSeconds+' seconds. Evidence: '+$root)
}finally{
    foreach($path in @($source,$target)+@([IO.Directory]::GetFiles($payload))){$absolute=[IO.Path]::GetFullPath($path);if(-not $absolute.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cleanup escaped generated workspace'};if([IO.File]::Exists($absolute)){[IO.File]::Delete($absolute)}}
    if([IO.Directory]::Exists($payload)){[IO.Directory]::Delete($payload,$false)}
}
