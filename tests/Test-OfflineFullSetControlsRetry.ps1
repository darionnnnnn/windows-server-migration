#requires -Version 5.1
# N9h-D2 regression: a failed CV2 attempt can leave controls\ (source-inventory.json, material-NNNN-<hash>.bin) in the package directory of the same
# plan and generation. Retrying must not throw "file already exists": identical bytes are reused, different bytes are refused and never overwritten.
# The first attempt fails for a reason unrelated to D1 (here: the writer is interrupted after the inventory copy, or the package is rejected later).
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-n9h-d2-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try{
    $checks=& $module {
        param($Root)
        $script:Checks=0
        function Check($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:Checks++}
        function Expect-Throw([scriptblock]$Action,[string]$Pattern,[string]$Message){
            $text='';try{& $Action}catch{$text=[string]$_.Exception.Message}
            Check ($text -and $text -match $Pattern) ($Message+' (message: '+$text+')')
        }
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function Text-Sha([byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
        function New-Fixture([string]$Name){
            $workspace=Join-Path $Root $Name;$state=Join-Path $workspace 'pairs';[void][IO.Directory]::CreateDirectory($state)
            $snapshotBytes=[Text.Encoding]::UTF8.GetBytes('{"snapshot":"'+$Name+'"}');$snapshotHash=Text-Sha $snapshotBytes
            $snapshotRelative='assistive/snapshots/'+$snapshotHash+'.json';$snapshotPath=Join-Path $state $snapshotRelative.Replace('/','\')
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($snapshotPath));[IO.File]::WriteAllBytes($snapshotPath,$snapshotBytes)
            $materialBytes=[Text.Encoding]::UTF8.GetBytes('{"confirmation":"'+$Name+'"}');$materialHash=Text-Sha $materialBytes
            $materialRelative='assistive/materials/source-candidate/'+$materialHash+'/confirmation.json';$materialPath=Join-Path $workspace $materialRelative.Replace('/','\')
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($materialPath));[IO.File]::WriteAllBytes($materialPath,$materialBytes)
            $now=[DateTime]::UtcNow.ToString('o')
            $plan=[pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=2;SourceSnapshotHash=$snapshotHash;MaterialReferences=@([pscustomobject]@{Reference=$materialRelative;SHA256=$materialHash;CreatedUtc=$now});DiscoveryAuthority=[pscustomobject]@{SourceSnapshotReference=[pscustomobject]@{Reference=$snapshotRelative;SHA256=$snapshotHash;CreatedUtc=$now}}}}
            $package=Join-Path $Root ('pkg-'+$Name);[void][IO.Directory]::CreateDirectory($package)
            [pscustomobject]@{Workspace=$workspace;State=$state;Plan=$plan;Package=$package;SnapshotHash=$snapshotHash;MaterialHash=$materialHash}
        }
        function Controls-Snapshot($Fixture){
            $dir=Join-Path $Fixture.Package 'controls'
            @(Get-ChildItem -LiteralPath $dir -File -Force|Sort-Object Name|ForEach-Object {[pscustomobject]@{Name=$_.Name;Hash=(Sha $_.FullName);Written=$_.LastWriteTimeUtc.Ticks}})
        }
        function Write-Controls($Fixture){Write-WsmOfflineFullSetControls $Fixture.Plan $Fixture.State $Fixture.Package $Fixture.Workspace}

        # 1. First attempt writes the controls; the retry of the same plan/generation succeeds and reuses them untouched.
        $a=New-Fixture 'retry'
        $first=Write-Controls $a
        $before=Controls-Snapshot $a
        Check ($before.Count -eq 3) 'first attempt writes index, source inventory and one material'
        Start-Sleep -Milliseconds 1100
        $second=Write-Controls $a
        $after=Controls-Snapshot $a
        Check ($second.IndexHash -ceq $first.IndexHash -and $second.Count -eq $first.Count) 'retry returns the same control index hash and count'
        Check ((($before|ForEach-Object {$_.Name+'|'+$_.Hash}) -join ';') -ceq (($after|ForEach-Object {$_.Name+'|'+$_.Hash}) -join ';')) 'retry leaves exactly the same control files with the same hashes (no stray temp file)'
        $reusedUntouched=$true;foreach($row in $before){if($row.Name -ceq 'index.json'){continue};$match=@($after|Where-Object Name -ceq $row.Name);if($match.Count -ne 1 -or $match[0].Written -ne $row.Written){$reusedUntouched=$false}}
        Check $reusedUntouched 'existing inventory and material files are reused, not rewritten'

        # 2. Interrupted first attempt: only part of controls\ exists (inventory copied, material and index missing; or material copied, index missing).
        $b=New-Fixture 'partial-inventory-only'
        $controlsB=Join-Path $b.Package 'controls';[void][IO.Directory]::CreateDirectory($controlsB)
        [IO.File]::Copy((Join-Path $b.State ('assistive\snapshots\'+$b.SnapshotHash+'.json')),(Join-Path $controlsB 'source-inventory.json'),$false)
        $resumed=Write-Controls $b
        Check ($resumed.Count -eq 2 -and @(Controls-Snapshot $b).Count -eq 3) 'a half-written controls directory (inventory only) is completed by the retry'
        $c=New-Fixture 'partial-no-index'
        [void](Write-Controls $c);Remove-Item -LiteralPath (Join-Path $c.Package 'controls\index.json') -Force
        $resumedC=Write-Controls $c
        Check ($resumedC.Count -eq 2 -and (Test-Path -LiteralPath (Join-Path $c.Package 'controls\index.json'))) 'controls without index.json (failure just before the index write) are completed by the retry'

        # 3. Different bytes at the destination are a conflict: refused, and the existing bytes stay exactly as they were.
        $d=New-Fixture 'conflict-inventory'
        [void](Write-Controls $d)
        $inventoryControl=Join-Path $d.Package 'controls\source-inventory.json'
        [IO.File]::WriteAllText($inventoryControl,'{"tampered":true}');$tamperedHash=Sha $inventoryControl
        Expect-Throw {Write-Controls $d | Out-Null} 'different content' 'an existing inventory control with other bytes is refused'
        Check ((Sha $inventoryControl) -ceq $tamperedHash) 'the conflicting inventory control is preserved, not overwritten'
        $e=New-Fixture 'conflict-material'
        [void](Write-Controls $e)
        $materialControl=@(Get-ChildItem -LiteralPath (Join-Path $e.Package 'controls') -Filter 'material-*.bin')[0].FullName
        [IO.File]::WriteAllText($materialControl,'{"tampered":"material"}');$tamperedMaterial=Sha $materialControl
        Expect-Throw {Write-Controls $e | Out-Null} 'different content' 'an existing material control with other bytes is refused'
        Check ((Sha $materialControl) -ceq $tamperedMaterial) 'the conflicting material control is preserved, not overwritten'
        $f=New-Fixture 'conflict-directory'
        [void][IO.Directory]::CreateDirectory((Join-Path $f.Package 'controls\source-inventory.json'))
        Expect-Throw {Write-Controls $f | Out-Null} 'occupied by a directory' 'a directory squatting on a control file name is refused'

        # 4. The sealed hash of the source stays authoritative on the first write as well (no copy of changed snapshot bytes).
        $g=New-Fixture 'changed-source'
        [IO.File]::WriteAllText((Join-Path $g.State ('assistive\snapshots\'+$g.SnapshotHash+'.json')),'{"snapshot":"changed"}')
        Expect-Throw {Write-Controls $g | Out-Null} 'changed after approval' 'a changed snapshot is still refused before any control is written'
        Check (-not (Test-Path -LiteralPath (Join-Path $g.Package 'controls\source-inventory.json'))) 'no control file is left behind by the refused write'
        # 5. A reused destination is still a guarded path: an existing control file is re-checked for reparse points before it is reused.
        #    Creating a file symlink needs elevation on the test host, so a probe replaces the module guard for exactly that path and is restored afterwards.
        $h=New-Fixture 'reuse-reparse'
        [void](Write-Controls $h)
        $script:ReparseProbeTarget=[IO.Path]::GetFullPath((Join-Path $h.Package 'controls\source-inventory.json'))
        $originalGuard=${function:script:Assert-WsmNoReparse}
        try{
            ${function:script:Assert-WsmNoReparse}={param([string]$Path) if([IO.Path]::GetFullPath($Path) -ieq $script:ReparseProbeTarget){throw 'Reparse probe: the reused control is a reparse point.'}}
            Expect-Throw {Write-Controls $h | Out-Null} 'Reparse probe' 'an existing control file is re-checked for reparse points before it is reused'
        }finally{${function:script:Assert-WsmNoReparse}=$originalGuard}
        Check ((${function:script:Assert-WsmNoReparse}).ToString() -ceq $originalGuard.ToString()) 'the module reparse guard is restored after the probe'
        $script:Checks
    } $root
    Write-Host ('PASS: {0} OfflineFullSet controls retry checks (identical bytes reused, partial directories completed, conflicts refused and preserved, reused files re-checked for reparse points)' -f $checks)
}finally{
    if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
