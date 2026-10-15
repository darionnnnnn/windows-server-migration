#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-core-lock-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$held=$null;$childProcess=$null
try {
    $modulePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1'))
    $scriptPath=Join-Path $root 'child.ps1'
    $body=@'
param([string]$ModulePath,[string]$Workspace,[string]$Ready,[string]$Result,[string]$Expected)
$ErrorActionPreference='Stop'
$m=Import-Module $ModulePath -Force -PassThru -DisableNameChecking
[IO.File]::WriteAllText($Ready,'ready')
$watch=[Diagnostics.Stopwatch]::StartNew();$entered=$false;$failure=$null
try{& $m {param($Workspace)Invoke-WsmLocked $Workspace {[IO.File]::WriteAllText((Join-Path $Workspace 'committed'),'one exact write')}} $Workspace;$entered=$true}catch{$failure=$_.Exception.GetType().FullName}
if(($Expected -ceq 'Release') -ne $entered){throw ('Unexpected lock result: '+$failure)}
if($Expected -ceq 'Busy' -and ($watch.ElapsedMilliseconds -lt 1900 -or $watch.ElapsedMilliseconds -gt 3500 -or [IO.File]::Exists((Join-Path $Workspace 'committed')))){throw 'Contended lock was not bounded or executed without ownership.'}
[IO.File]::WriteAllText($Result,(@{Entered=$entered;ElapsedMilliseconds=$watch.ElapsedMilliseconds}|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
'@
    [IO.File]::WriteAllText($scriptPath,$body,(New-Object Text.UTF8Encoding($true)))
    foreach($engine in @('powershell.exe','pwsh.exe')){foreach($expected in @('Release','Busy')){
        $caseRoot=Join-Path $root ([guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($caseRoot)
        $ready=Join-Path $caseRoot ready;$result=Join-Path $caseRoot result.json
        $held=[IO.File]::Open((Join-Path $caseRoot '.wsm.lock'),'OpenOrCreate','ReadWrite','None')
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=(Get-Command $engine -ErrorAction Stop).Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.Arguments='-NoProfile -File "'+$scriptPath+'" -ModulePath "'+$modulePath+'" -Workspace "'+$caseRoot+'" -Ready "'+$ready+'" -Result "'+$result+'" -Expected '+$expected
        $childProcess=[Diagnostics.Process]::Start($start)
        $startup=[Diagnostics.Stopwatch]::StartNew();while(-not [IO.File]::Exists($ready)){if($childProcess.HasExited -or $startup.Elapsed.TotalSeconds -gt 60){throw 'Owned lock fixture child did not become ready.'};Start-Sleep -Milliseconds 25}
        if($expected -ceq 'Release'){Start-Sleep -Milliseconds 250;if([IO.File]::Exists((Join-Path $caseRoot committed))){throw 'Child entered the lock before the owner released it.'};$held.Dispose();$held=$null}
        if(-not $childProcess.WaitForExit(10000) -or $childProcess.ExitCode -ne 0 -or -not [IO.File]::Exists($result)){throw 'Owned lock fixture failed.'}
        if($held){if($held.SafeFileHandle.IsClosed){throw 'A busy owner was taken over.'};$held.Dispose();$held=$null}
        $childProcess.Dispose();$childProcess=$null
        Write-Output ('PASS actual cross-process core lock: '+$engine+' '+$expected)
    }}
}finally{
    if($held){$held.Dispose()}
    if($childProcess){if(-not $childProcess.HasExited){$childProcess.Kill();$childProcess.WaitForExit()};$childProcess.Dispose()}
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'wsm-core-lock-*'){throw 'Refusing cleanup outside owned core lock fixture.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
