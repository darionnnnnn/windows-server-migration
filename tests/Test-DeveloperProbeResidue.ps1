#requires -Version 5.1
# S7: protected raw evidence and cancellation markers of a developer probe must not stay on disk forever.
# A failed or cancelled run removes its own raw evidence; a later run purges raw evidence and markers
# that outlived their retention period without touching fresh (possibly in-flight) runs.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-probe-residue-'+[Guid]::NewGuid().ToString('N').Substring(0,10));[void][IO.Directory]::CreateDirectory($root)
$junction=''
if(-not ('WsmLinkTime' -as [type])){Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class WsmLinkTime {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileTime(SafeFileHandle handle, ref long created, ref long accessed, ref long written);
    public static void Set(string path, DateTime utc) {
        long stamp = utc.ToFileTimeUtc();
        // FILE_WRITE_ATTRIBUTES; BACKUP_SEMANTICS | OPEN_REPARSE_POINT so the link itself, not its target, is stamped.
        using (SafeFileHandle handle = CreateFile(path, 0x100, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception();
            if (!SetFileTime(handle, ref stamp, ref stamp, ref stamp)) throw new System.ComponentModel.Win32Exception();
        }
    }
}
'@}
try {
    & $module {
        param($Root)
        $script:checks=0
        function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
        function RawFiles([string]$Workspace,[string]$RunId){$raw=Join-Path (Join-Path (Join-Path $Workspace 'developer-probes') $RunId) 'protected-raw';if(-not [IO.Directory]::Exists($raw)){return @()};@(Get-ChildItem -LiteralPath $raw -File -Recurse -Force)}
        function NewRun([string]$Workspace,[int]$AgeDays,[string]$Name){
            $run=Join-Path (Join-Path $Workspace 'developer-probes') $Name;$raw=Join-Path $run 'protected-raw';[void][IO.Directory]::CreateDirectory($raw)
            [IO.File]::WriteAllText((Join-Path $raw 'raw.bin'),'raw');[IO.File]::WriteAllText((Join-Path $run 'probe.json'),'{}')
            $stamp=[DateTime]::UtcNow.AddDays(-$AgeDays);foreach($path in @((Join-Path $raw 'raw.bin'),(Join-Path $run 'probe.json'))){[IO.File]::SetCreationTimeUtc($path,$stamp);[IO.File]::SetLastWriteTimeUtc($path,$stamp)};foreach($path in @($raw,$run)){[IO.Directory]::SetCreationTimeUtc($path,$stamp);[IO.Directory]::SetLastWriteTimeUtc($path,$stamp)}
            $run
        }
        $ok={param($CollectorId,$Context) [pscustomobject]@{Status='Completed'}}
        $all=@{PlatformIdentity=$ok;CommandsModules=$ok;LocalVolumes=$ok;NativeInventory=$ok}

        # Cancellation path: the adapter writes raw evidence, then the real marker stops the run.
        $cancelRoot=Join-Path $Root 'cancel';[void][IO.Directory]::CreateDirectory($cancelRoot)
        $operation=[Guid]::NewGuid().ToString();$token=New-WsmDeveloperProbeCancellationToken -Workspace $cancelRoot -OperationId $operation
        $markerJson=([pscustomobject]@{Kind='DeveloperProbeCancellationRequest';OperationId=$operation;RequestedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress)
        $markerLiteral="'"+$token.RequestPath.Replace("'","''")+"'";$jsonLiteral="'"+$markerJson.Replace("'","''")+"'"
        $cancelAdapter=[scriptblock]::Create("param(`$CollectorId,`$Context) if(`$CollectorId -eq 'PlatformIdentity'){[IO.File]::WriteAllText((Join-Path `$Context.RawRoot 'raw-evidence.bin'),'RAW-SENTINEL');[IO.File]::WriteAllText($markerLiteral,$jsonLiteral);Start-Sleep -Seconds 5};[pscustomobject]@{Status='Completed'}")
        $cancelResult=Export-WsmDeveloperProbe -Workspace $cancelRoot -CancellationToken $token -CollectorTimeoutSeconds 10 -CollectorAdapter @{PlatformIdentity=$cancelAdapter;CommandsModules=$cancelAdapter;LocalVolumes=$cancelAdapter;NativeInventory=$cancelAdapter}
        Check ($cancelResult.Status -ceq 'Cancelled') 'Control: the cancellation fixture did not produce a Cancelled run.'
        Check ([IO.File]::Exists($cancelResult.Path)) 'Control: the cancelled run lost its sanitized deliverable.'
        Check (@(RawFiles $cancelRoot $cancelResult.RunId).Count -eq 0) 'S7: a cancelled run left its protected raw evidence on disk.'

        # Failure path: a real fault after collection (archive hashing) must not strand the raw evidence.
        $failRoot=Join-Path $Root 'fail';[void][IO.Directory]::CreateDirectory($failRoot)
        $rawAdapter=[scriptblock]::Create("param(`$CollectorId,`$Context) if(`$CollectorId -eq 'NativeInventory'){[IO.File]::WriteAllText((Join-Path `$Context.RawRoot 'raw-evidence.bin'),'RAW-SENTINEL')};[pscustomobject]@{Status='Completed'}")
        $script:residueRawAtFault=$false
        function script:Get-FileHash {param([string]$LiteralPath,[string]$Algorithm)
            if($LiteralPath -like '*\probe.json'){$script:residueRawAtFault=[IO.File]::Exists((Join-Path (Join-Path (Split-Path -Parent $LiteralPath) 'protected-raw') 'raw-evidence.bin'));throw 'injected archive hash failure'}
            Microsoft.PowerShell.Utility\Get-FileHash @PSBoundParameters}
        $failed=$false;try{Export-WsmDeveloperProbe -Workspace $failRoot -CollectorAdapter @{PlatformIdentity=$rawAdapter;CommandsModules=$rawAdapter;LocalVolumes=$rawAdapter;NativeInventory=$rawAdapter}|Out-Null}catch{$failed=$_.Exception.Message -like '*injected archive hash failure*'}
        Remove-Item Function:\Get-FileHash -ErrorAction SilentlyContinue
        Check $failed 'Control: the injected fault did not surface from Export-WsmDeveloperProbe.'
        Check $script:residueRawAtFault 'Control: raw evidence must exist on disk at the moment the fault strikes (otherwise the failure case proves nothing).'
        $failRuns=@(Get-ChildItem -LiteralPath (Join-Path $failRoot 'developer-probes') -Directory -Force|Where-Object {$_.Name -match '^[0-9a-f-]{36}$'})
        Check ($failRuns.Count -eq 1) 'Control: the failed run directory is missing.'
        Check (@(RawFiles $failRoot $failRuns[0].Name).Count -eq 0) 'S7: a failed run left its protected raw evidence on disk.'

        # A normal (even partial) run keeps its raw evidence for local inspection.
        $keepRoot=Join-Path $Root 'keep';[void][IO.Directory]::CreateDirectory($keepRoot)
        $keepResult=Export-WsmDeveloperProbe -Workspace $keepRoot -CollectorAdapter @{PlatformIdentity=$rawAdapter;CommandsModules=$rawAdapter;LocalVolumes=$rawAdapter;NativeInventory=$rawAdapter}
        Check ($keepResult.Status -ceq 'Completed' -and @(RawFiles $keepRoot $keepResult.RunId).Count -eq 1) 'Control: a completed run must keep its raw evidence until the retention period ends.'

        # Retention: a later run purges expired raw evidence and expired markers, never fresh data.
        $retRoot=Join-Path $Root 'retention';[void][IO.Directory]::CreateDirectory($retRoot)
        $probeRoot=Join-Path $retRoot 'developer-probes';[void][IO.Directory]::CreateDirectory($probeRoot)
        $oldRun=NewRun $retRoot 40 ([Guid]::NewGuid().ToString('D'));$freshRun=NewRun $retRoot 1 ([Guid]::NewGuid().ToString('D'));$notARun=Join-Path $probeRoot 'notes';[void][IO.Directory]::CreateDirectory((Join-Path $notARun 'protected-raw'));[IO.File]::WriteAllText((Join-Path $notARun 'protected-raw\keep.txt'),'x')
        $markerDir=Join-Path $probeRoot '.cancellations';[void][IO.Directory]::CreateDirectory($markerDir)
        $oldMarker=Join-Path $markerDir ([Guid]::NewGuid().ToString('D')+'.json');$freshMarker=Join-Path $markerDir ([Guid]::NewGuid().ToString('D')+'.json')
        foreach($m in @($oldMarker,$freshMarker)){[IO.File]::WriteAllText($m,'{}')};[IO.File]::SetLastWriteTimeUtc($oldMarker,[DateTime]::UtcNow.AddDays(-9))
        # An expired run directory that is a reparse point must never be followed.
        $outside=Join-Path $Root 'outside-target';[void][IO.Directory]::CreateDirectory((Join-Path $outside 'protected-raw'));[IO.File]::WriteAllText((Join-Path $outside 'protected-raw\must-survive.txt'),'x')
        $linkRun=Join-Path $probeRoot ([Guid]::NewGuid().ToString('D'))
        & cmd.exe /c ('mklink /J "'+$linkRun+'" "'+$outside+'"')|Out-Null;if($LASTEXITCODE -ne 0){throw 'Could not create the junction fixture.'}
        try{
            [WsmLinkTime]::Set($linkRun,[DateTime]::UtcNow.AddDays(-40));if(([DateTime]::UtcNow-[IO.DirectoryInfo]::new($linkRun).CreationTimeUtc).TotalDays -lt 30 -or ([IO.File]::GetAttributes($linkRun) -band [IO.FileAttributes]::ReparsePoint) -eq 0){throw 'Fixture: the expired link did not get its own old timestamp.'}
            $retResult=Export-WsmDeveloperProbe -Workspace $retRoot -CollectorAdapter $all
            Check ($retResult.Status -ceq 'Completed') 'Control: the retention fixture run did not complete.'
            Check (-not [IO.Directory]::Exists((Join-Path $oldRun 'protected-raw'))) 'S7: expired protected raw evidence survived a later run.'
            Check ([IO.File]::Exists((Join-Path $oldRun 'probe.json'))) 'S7: the purge removed a sanitized result instead of only the raw evidence.'
            Check ([IO.File]::Exists((Join-Path $freshRun 'protected-raw\raw.bin'))) 'S7: the purge removed raw evidence that is still inside its retention period.'
            Check ([IO.File]::Exists((Join-Path $notARun 'protected-raw\keep.txt'))) 'S7: the purge touched a directory that is not a probe run.'
            Check (-not [IO.File]::Exists($oldMarker)) 'S7: an expired cancellation marker survived.'
            Check ([IO.File]::Exists($freshMarker)) 'S7: the purge removed a fresh cancellation marker.'
            Check ([IO.File]::Exists((Join-Path $outside 'protected-raw\must-survive.txt'))) 'S7: the purge followed a reparse point out of the probe root.'
        }finally{if([IO.Directory]::Exists($linkRun)){& cmd.exe /c ('rmdir "'+$linkRun+'"')|Out-Null}}
        Check (-not [IO.Directory]::Exists($linkRun)) 'Fixture left a reparse point behind.'
        Write-Output ('PASS Test-DeveloperProbeResidue checks='+$script:checks+'; cancelled/failed runs drop raw evidence and expired raw evidence/markers are purged without touching fresh or foreign data.')
    } $root
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    $absolute=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute) -like 'wsm-probe-residue-*' -and [IO.Directory]::Exists($absolute)){
        foreach($link in @(Get-ChildItem -LiteralPath $absolute -Recurse -Directory -Force -ErrorAction SilentlyContinue|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint})){& cmd.exe /c ('rmdir "'+$link.FullName+'"')|Out-Null}
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
