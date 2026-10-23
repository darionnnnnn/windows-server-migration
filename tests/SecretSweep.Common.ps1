# Shared secret-sentinel sweep (16.6-12): dot-sourced by Test-SecretSentinelSweep.ps1 and Test-SecretSentinelBackupSweep.ps1.
# Needles are matched on a Latin-1 view of the raw bytes, so UTF-8 / UTF-16LE (any byte alignment)
# and Base64 text are all plain ordinal substring searches.
function New-SweepNeedles([string]$Secret){
    $latin=[Text.Encoding]::GetEncoding(28591)
    $utf8=[Text.Encoding]::UTF8.GetBytes($Secret);$utf16=[Text.Encoding]::Unicode.GetBytes($Secret)
    $needles=New-Object 'System.Collections.Generic.List[object]'
    $needles.Add([pscustomobject]@{Encoding='UTF-8';Needle=$latin.GetString($utf8);Base64=$false})
    $needles.Add([pscustomobject]@{Encoding='UTF-16LE';Needle=$latin.GetString($utf16);Base64=$false})
    foreach($variant in @(@{Name='Base64';Bytes=$utf8},@{Name='Base64(UTF-16LE)';Bytes=$utf16})){
        foreach($shift in 0,1,2){
            # Prefix with $shift filler bytes so the secret starts at every offset modulo 3, then keep only the
            # characters that are fully determined by secret bytes (drop the leading mixed chars and the trailing partial one).
            $buffer=New-Object byte[] ($shift+$variant.Bytes.Length);[Array]::Copy($variant.Bytes,0,$buffer,$shift,$variant.Bytes.Length)
            $text=[Convert]::ToBase64String($buffer).TrimEnd('=')
            $skip=@(0,2,3)[$shift];if((($shift+$variant.Bytes.Length) % 3) -ne 0){$text=$text.Substring(0,$text.Length-1)}
            $needles.Add([pscustomobject]@{Encoding=($variant.Name+'@'+$shift);Needle=$text.Substring($skip);Base64=$true})
        }
    }
    # Digest needles: a hash of the secret leaks the same secret, so the sweep also looks for SHA256 / SHA1 / MD5 digests of it.
    $sha256=[Security.Cryptography.SHA256]::Create();$sha1=[Security.Cryptography.SHA1]::Create();$md5=[Security.Cryptography.MD5]::Create()
    try{$sha256Utf8=$sha256.ComputeHash($utf8);$sha256Utf16=$sha256.ComputeHash($utf16);$sha1Utf8=$sha1.ComputeHash($utf8);$md5Utf8=$md5.ComputeHash($utf8)}finally{$sha256.Dispose();$sha1.Dispose();$md5.Dispose()}
    $sha256Hex=[BitConverter]::ToString($sha256Utf8).Replace('-','')
    $needles.Add([pscustomobject]@{Encoding='SHA256-hex-lower(UTF-8)';Needle=$sha256Hex.ToLowerInvariant();Base64=$false})
    $needles.Add([pscustomobject]@{Encoding='SHA256-hex-upper(UTF-8)';Needle=$sha256Hex;Base64=$false})
    $needles.Add([pscustomobject]@{Encoding='SHA256-b64(UTF-8)';Needle=[Convert]::ToBase64String($sha256Utf8).TrimEnd('=');Base64=$false})
    $needles.Add([pscustomobject]@{Encoding='SHA256-hex-lower(UTF-16LE)';Needle=([BitConverter]::ToString($sha256Utf16).Replace('-','')).ToLowerInvariant();Base64=$false})
    $needles.Add([pscustomobject]@{Encoding='SHA1-hex-lower(UTF-8)';Needle=([BitConverter]::ToString($sha1Utf8).Replace('-','')).ToLowerInvariant();Base64=$false})
    $needles.Add([pscustomobject]@{Encoding='MD5-hex-lower(UTF-8)';Needle=([BitConverter]::ToString($md5Utf8).Replace('-','')).ToLowerInvariant();Base64=$false})
    ,$needles.ToArray()
}
function Invoke-SecretSweep([string[]]$Roots,[string]$Secret){
    $latin=[Text.Encoding]::GetEncoding(28591);$needles=New-SweepNeedles $Secret;$files=0;$hits=@()
    foreach($sweepRoot in $Roots){
        # A root may be a directory (walked recursively) or a single file.
        $sweepFiles=if([IO.File]::Exists($sweepRoot)){@(Get-Item -LiteralPath $sweepRoot -Force)}else{@(Get-ChildItem -LiteralPath $sweepRoot -Recurse -File -Force)}
        foreach($file in $sweepFiles){
            $files++
            $stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            try{$bytes=New-Object byte[] ([int]$stream.Length);$read=0;while($read -lt $bytes.Length){$n=$stream.Read($bytes,$read,$bytes.Length-$read);if($n -le 0){break};$read+=$n}}finally{$stream.Dispose()}
            $raw=$latin.GetString($bytes);$compact=$raw.Replace("`r",'').Replace("`n",'')
            $found=@();foreach($needle in $needles){$view=$raw;if($needle.Base64){$view=$compact};if($view.IndexOf($needle.Needle,[StringComparison]::Ordinal) -ge 0){$found+=@($needle.Encoding)}}
            if($found.Count){$hits+=@([pscustomobject]@{File=$file.FullName;Encodings=@($found)})}
        }
    }
    [pscustomobject]@{Roots=@($Roots);FileCount=$files;Hits=@($hits)}
}
