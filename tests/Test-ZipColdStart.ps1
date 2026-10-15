#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-zip-cold-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    Add-Type -AssemblyName System.IO.Compression
    $zip=Join-Path $root 'volume.zip';$file=[IO.File]::Open($zip,'CreateNew','ReadWrite','None')
    $archive=New-Object IO.Compression.ZipArchive($file,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {$entry=$archive.CreateEntry('fixture.txt');$stream=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('cold import payload');$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$archive.Dispose();$file.Dispose()}
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $child=Join-Path $root 'cold.ps1'
    $scriptText=@'
param([string]$ModulePath,[string]$Zip,[string]$Hash,[long]$Bytes)
$ErrorActionPreference='Stop'
$m=Import-Module $ModulePath -Force -PassThru -DisableNameChecking
& $m {param($p,$h,$n)$row=[pscustomobject]@{Name='fixture.txt';Hash=$h;Bytes=$n};$valid=Test-WsmZipVolume $p @($row);if($valid.Hash -ine (Get-FileHash -LiteralPath $p).Hash){throw 'Cold ZIP verifier did not validate actual volume hash.'}} $Zip $Hash $Bytes
Write-Output 'PASS cold ZIP volume validation in a fresh engine.'
'@
    [IO.File]::WriteAllText($child,$scriptText,(New-Object Text.UTF8Encoding($true)))
    foreach($engine in @('powershell.exe','pwsh.exe')){& $engine -NoProfile -File $child -ModulePath (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Zip $zip -Hash $hash -Bytes $bytes.Length;if($LASTEXITCODE -ne 0){throw ($engine+' cold ZIP validation failed')}}
}finally{
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-zip-cold-*'){throw 'Refusing cleanup outside owned cold ZIP fixture.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
