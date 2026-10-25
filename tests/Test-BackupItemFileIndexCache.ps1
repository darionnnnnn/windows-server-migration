#requires -Version 5.1
# R22: the drill-down's artifact index cache (Get-WsmBackupItemFileIndex).
# Measured before the fix: 100,000 rows (26 MB) took ~48 s per page because every page re-read and re-parsed artifacts.jsonl on the listener thread.
# Contract: parse once per index CONTENT; the content hash is re-checked on every call, so a changed index is refused (never served from the old cache)
# and the cache key follows the content; the cache is bounded.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$dir=Join-Path ([IO.Path]::GetTempPath()) ('wsm-r22-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($dir)
try {
    & $module {
        param($Dir)
        $check={param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
        $rejection={param([scriptblock]$Action)try{& $Action;''}catch{[string]$_.Exception.Message}}
        $fileHash=('ab'*32)
        $write={param([string]$Path,[string]$Tag,[int]$Rows)
            $lines=for($i=0;$i -lt $Rows;$i++){
                $item='item-'+(($i % 3)+1);$isDirectory=($i % 50 -eq 49)
                if($isDirectory){'{"ItemId":"'+$item+'","RelativePath":"dir'+$Tag+'\\d'+$i+'","Directory":true}'}
                else{'{"ItemId":"'+$item+'","RelativePath":"dir'+$Tag+'\\f'+$i+'.dat","Directory":false,"Data":{"Bytes":'+(1000+$i)+',"Hash":"'+$fileHash+'","Chunks":[{"Hash":"'+$fileHash+'","Bytes":'+(1000+$i)+'}]}}'}
            }
            [IO.File]::WriteAllLines($Path,[string[]]@($lines),(New-Object Text.UTF8Encoding($false)))
            (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $path=Join-Path $Dir 'artifacts.jsonl'
        $hash=& $write $path 'A' 3000

        # ---- 1) shape, totals, directories, page slice ----
        $index=Get-WsmBackupItemFileIndex $path $hash
        $item1=$index['item-1']
        & $check ($index.Count -eq 3) 'R22: three items are indexed.'
        & $check ([long]$item1.Total -eq 1000 -and $item1.Rows.Count -eq 1000) ('R22: item-1 holds 1000 rows; got '+$item1.Total)
        & $check ([long]$item1.Directories -eq 20) ('R22: item-1 counts 20 directory members; got '+$item1.Directories)
        $first=$item1.Rows[0]
        & $check ([string]$first[0] -ceq 'dirA\f0.dat' -and [long]$first[1] -eq 1000 -and [string]$first[2] -ceq 'abababababab' -and -not [bool]$first[3]) 'R22: a file row keeps path, bytes, the first 12 hash characters and the directory flag.'
        $dirRow=@($item1.Rows | Where-Object {[bool]$_[3]})[0]
        & $check ([long]$dirRow[1] -eq 0 -and [string]$dirRow[2] -ceq '') 'R22: a directory row has no size and no hash.'
        Write-Host 'PASS: R22 index shape, totals and directory members.'

        # ---- 2) the second call is the cached object (no re-parse) ----
        $again=Get-WsmBackupItemFileIndex $path $hash
        & $check ([object]::ReferenceEquals($index,$again)) 'R22: the same index content is parsed once; the second call returns the cached index.'
        Write-Host 'PASS: R22 second call served from the cache.'

        # ---- 3) a changed index is refused even though the cache holds the old content; the key follows the content ----
        $original=[IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path,$original.Replace('f1.dat','f9.dat'),(New-Object Text.UTF8Encoding($false)))   # same length, different bytes
        $why=& $rejection {Get-WsmBackupItemFileIndex $path $hash}
        & $check ($why -like '*changed before use*') ('R22: a tampered index must be refused with the old hash, never answered from the cache; got "'+$why+'"')
        $newHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        & $check ($newHash -ne $hash) 'R22: sanity - the tampered file has another hash.'
        $changed=Get-WsmBackupItemFileIndex $path $newHash
        & $check (-not [object]::ReferenceEquals($index,$changed)) 'R22: a new content hash gets a new cache entry.'
        & $check (@($changed['item-2'].Rows | Where-Object {[string]$_[0] -ceq 'dirA\f9.dat'}).Count -eq 1 -and @($changed['item-2'].Rows | Where-Object {[string]$_[0] -ceq 'dirA\f1.dat'}).Count -eq 0) 'R22: the new index reflects the new content, not the old cache.'
        [IO.File]::WriteAllText($path,$original,(New-Object Text.UTF8Encoding($false)))
        $restored=Get-WsmBackupItemFileIndex $path $hash
        & $check ([object]::ReferenceEquals($index,$restored)) 'R22: restoring the original bytes serves the original cache entry again.'
        Write-Host 'PASS: R22 tampered index refused, key follows content.'

        # ---- 4) hash format and reparse guards ----
        & $check ((& $rejection {Get-WsmBackupItemFileIndex $path 'not-a-hash'}) -like '*hash required*') 'R22: a malformed expected hash is refused.'
        & $check ((& $rejection {Get-WsmBackupItemFileIndex $path (('0'*64))}) -like '*changed before use*') 'R22: a wrong expected hash is refused.'
        Write-Host 'PASS: R22 malformed and wrong expected hashes refused.'

        # ---- 5) bounded cache: six different contents never keep more than the limit ----
        for($n=1;$n -le 6;$n++){
            $p=Join-Path $Dir ('artifacts-'+$n+'.jsonl');$h=& $write $p ([string]$n) (60+$n)
            [void](Get-WsmBackupItemFileIndex $p $h)
        }
        & $check ($script:WsmBackupItemFileIndexCache.Count -le [int]$script:WsmBackupItemFileIndexLimit -and [int]$script:WsmBackupItemFileIndexLimit -eq 4) ('R22: the cache holds at most 4 indexes; holds '+$script:WsmBackupItemFileIndexCache.Count)
        Write-Host 'PASS: R22 the cache is bounded.'
    } $dir
    Write-Host 'PASS: R22 artifact index cache.'
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
