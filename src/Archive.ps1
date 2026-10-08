function Import-WsmInventoryArchive {
    [CmdletBinding()] param([string]$Workspace,[string]$Path,[string]$ExpectedHash,[string]$TargetName)
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw (New-WsmContractError 'Trusted archive SHA256 required.') }
    [void](Get-WsmFleet $Workspace)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read')
    $temp=$null; $archive=$null
    try {
        if ($stream.Length -gt 128MB) { throw (New-WsmContractError 'Inventory archive exceeds 128 MiB.') }
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $hash=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-',''); if ($hash -ine $ExpectedHash) { throw (New-WsmContractError 'Trusted archive SHA256 mismatch.') } } finally { $sha.Dispose() }
        $stream.Position=0
        $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
        if ($archive.Entries.Count -ne 2) { throw (New-WsmContractError 'Inventory archive requires exactly JSON and its checksum.') }
        $seen=@{}; $entry=$null; $checksum=$null
        foreach ($e in $archive.Entries) {
            if ($e.FullName -notmatch '^inventory-[1-9][0-9]*\.json(?:\.sha256)?$' -or $seen.ContainsKey($e.FullName.ToLowerInvariant())) { throw (New-WsmContractError 'Unknown, duplicate or unsafe archive entry.') }
            if ($e.Length -gt 128MB -or ($e.Length -gt 1MB -and $e.Length -gt 200*[math]::Max(1,$e.CompressedLength))) { throw (New-WsmContractError 'Archive entry exceeds size/compression ratio limit.') }
            $seen[$e.FullName.ToLowerInvariant()]=$true
            if ($e.FullName.EndsWith('.sha256')) { $checksum=$e } else { $entry=$e }
        }
        if (-not $entry -or -not $checksum -or $checksum.FullName -cne ($entry.FullName+'.sha256') -or $checksum.Length -gt 128) { throw (New-WsmContractError 'Archive inventory/checksum names do not match.') }
        $entryStream=$checksum.Open(); $reader=New-Object IO.StreamReader($entryStream,[Text.Encoding]::UTF8,$true)
        try { $innerHash=$reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        if ($innerHash -notmatch '^[a-fA-F0-9]{64}$') { throw (New-WsmContractError 'Invalid inventory checksum.') }
        $memory=New-Object IO.MemoryStream; $entryStream=$entry.Open()
        try { $buffer=New-Object byte[] 65536; while (($read=$entryStream.Read($buffer,0,$buffer.Length)) -gt 0) { if ($memory.Length+$read -gt $entry.Length -or $memory.Length+$read -gt 128MB) { throw (New-WsmContractError 'Archive expansion exceeds declared size.') }; $memory.Write($buffer,0,$read) }; if ($memory.Length -ne $entry.Length) { throw (New-WsmContractError 'Archive entry length mismatch.') }; $bytes=$memory.ToArray() } finally { $entryStream.Dispose(); $memory.Dispose() }
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $digest=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-',''); if ($digest -ine $innerHash) { throw (New-WsmContractError 'Inventory entry checksum mismatch.') } } finally { $sha.Dispose() }
        # Never extract user-supplied names, symlinks, scripts, installers or directory trees.
        $temp=Join-Path ([IO.Path]::GetFullPath($Workspace)) ([Guid]::NewGuid().ToString('N')+'.inventory-input.tmp')
        [IO.File]::WriteAllBytes($temp,$bytes)
        Import-WsmInventory $Workspace $temp $innerHash $TargetName
    } finally { if ($archive) { $archive.Dispose() }; $stream.Dispose(); if ($temp -and [IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
