function Initialize-WsmNativeReader {
    if('WsmNativeBoundedReader' -as [type]){return}
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;
public sealed class WsmNativeOutput { public string Text; public bool Truncated; public long Characters; public long Utf8Bytes; public string Sha256; public string DigestKind; public bool CaptureComplete; public bool ReaderFaulted; public string LastObservedActivityUtc; }
public sealed class WsmNativeCaptureState {
    private readonly object gate = new object(); private readonly int limit; private readonly StringBuilder text; private long characters, utf8Bytes, lastObservedUtcTicks; private bool truncated; private byte[] rolling = new byte[32];
    public WsmNativeCaptureState(int maxCharacters) { if (maxCharacters < 0) throw new ArgumentOutOfRangeException("maxCharacters"); limit = maxCharacters; text = new StringBuilder(Math.Min(maxCharacters, 65536)); lastObservedUtcTicks = DateTime.UtcNow.Ticks; }
    private string ActivityUtc() { return new DateTime(lastObservedUtcTicks, DateTimeKind.Utc).ToString("yyyy-MM-ddTHH:mm:ss.fffZ", System.Globalization.CultureInfo.InvariantCulture); }
    public void Record(char[] chars, int count) { byte[] bytes = Encoding.UTF8.GetBytes(chars, 0, count); lock (gate) { lastObservedUtcTicks = DateTime.UtcNow.Ticks; characters += count; utf8Bytes += bytes.LongLength; byte[] material = new byte[rolling.Length + bytes.Length]; Buffer.BlockCopy(rolling, 0, material, 0, rolling.Length); Buffer.BlockCopy(bytes, 0, material, rolling.Length, bytes.Length); using (SHA256 hash = SHA256.Create()) rolling = hash.ComputeHash(material); if (text.Length + count > limit) { int remove = text.Length + count - limit; if (remove >= text.Length) text.Length = 0; else text.Remove(0, remove); truncated = true; } int append = Math.Min(count, limit); if (append > 0) text.Append(chars, Math.Max(0, count - limit), append); } }
    public WsmNativeOutput Snapshot() { lock (gate) { return new WsmNativeOutput { Text = text.ToString(), Truncated = truncated, Characters = characters, Utf8Bytes = utf8Bytes, Sha256 = BitConverter.ToString(rolling).Replace("-", "").ToLowerInvariant(), DigestKind = "RollingChunkSha256", CaptureComplete = false, ReaderFaulted = false, LastObservedActivityUtc = ActivityUtc() }; } }
    public WsmNativeOutput Complete(string sha256) { lock (gate) { return new WsmNativeOutput { Text = text.ToString(), Truncated = truncated, Characters = characters, Utf8Bytes = utf8Bytes, Sha256 = sha256, DigestKind = "Sha256", CaptureComplete = true, ReaderFaulted = false, LastObservedActivityUtc = ActivityUtc() }; } }
}
public static class WsmNativeBoundedReader {
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)] private static extern bool CancelIoEx(IntPtr handle, IntPtr overlapped);
    public static bool Cancel(TextReader reader) { try { var stream = (reader as StreamReader).BaseStream; if (stream is PipeStream) return CancelIoEx(((PipeStream)stream).SafePipeHandle.DangerousGetHandle(), IntPtr.Zero); if (stream is FileStream) return CancelIoEx(((FileStream)stream).SafeFileHandle.DangerousGetHandle(), IntPtr.Zero); return false; } catch { return false; } }
    public static void CloseAbandoned(TextReader reader) { try { Cancel(reader); Task.Run(() => { try { reader.Close(); } catch { } }); } catch { } }
    public static Task<WsmNativeOutput> Drain(TextReader reader, int limit) { return Drain(reader, limit, new WsmNativeCaptureState(limit)); }
    public static async Task<WsmNativeOutput> Drain(TextReader reader, int limit, WsmNativeCaptureState state) {
        if (limit < 0) throw new ArgumentOutOfRangeException("limit");
        if (state == null) throw new ArgumentNullException("state"); char[] buffer = new char[4096];
        long characters = 0, utf8Bytes = 0; int count; using (SHA256 hash = SHA256.Create()) {
            while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0) {
                characters += count; byte[] bytes = Encoding.UTF8.GetBytes(buffer, 0, count); utf8Bytes += bytes.LongLength;
                hash.TransformBlock(bytes, 0, bytes.Length, bytes, 0);
                state.Record(buffer, count);
            }
            hash.TransformFinalBlock(new byte[0], 0, 0); var digest = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
            return state.Complete(digest);
        }
    }
}
"@ -ErrorAction Stop
}
function ConvertTo-WsmWindowsArgument([string]$Value) {
    if($Value -match '[\x00\r\n]'){throw 'Native argument contains control characters.'}
    if($Value -ne '' -and $Value -notmatch '[\s"]'){return $Value}
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function New-WsmNativeOwnedProcess($StartInfo) {
    $process=New-Object Diagnostics.Process;$process.StartInfo=$StartInfo;$process
}
function Get-WsmNativeReaderMetadata($Task,$CaptureState,[int]$WaitMilliseconds,[bool]$ForcePartial=$false) {
    try{[void]$Task.Wait($WaitMilliseconds)}catch{}
    $succeeded=($Task.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion);$faulted=($Task.IsFaulted -or $Task.IsCanceled);$result=$null
    if($succeeded){try{$result=$Task.GetAwaiter().GetResult()}catch{$succeeded=$false;$faulted=$true}}
    if(-not $succeeded -or $ForcePartial){$result=$CaptureState.Snapshot();$result.CaptureComplete=$false;$result.ReaderFaulted=$faulted;if($faulted){$result.DigestKind='RollingChunkSha256PartialReaderFault'}elseif($ForcePartial){$result.DigestKind='RollingChunkSha256PartialCapture'}}
    [pscustomobject]@{Complete=$Task.IsCompleted;CaptureSucceeded=($succeeded -and -not $ForcePartial);ReaderFaulted=$faulted;Result=$result}
}
function Stop-WsmNativeOwnedProcess($Process,[int]$WaitMilliseconds=2500) {
    $attempted=$false;$exited=$false
    try{if(-not $Process.HasExited){$Process.Kill();$attempted=$true}}catch{$attempted=$true}
    try{$exited=$Process.WaitForExit($WaitMilliseconds);if(-not $exited){$exited=$Process.HasExited}}catch{$exited=$false}
    [pscustomobject]@{KillAttempted=$attempted;ProcessExitObserved=$exited;KillVerified=($attempted -and $exited)}
}
function Stop-WsmNativeReader($Reader,[bool]$Abandon=$false) { if(-not $Reader){return};if($Abandon){try{[WsmNativeBoundedReader]::CloseAbandoned($Reader)}catch{};return};try{[void][WsmNativeBoundedReader]::Cancel($Reader)}catch{};try{$Reader.Close()}catch{} }
function Invoke-WsmNativeToolCore {
    param([ValidateSet('sc.exe','robocopy.exe','appcmd.exe')][string]$Tool,[string[]]$Arguments,[ValidateRange(1,3600)][int]$TimeoutSeconds=120,[psobject]$CancellationToken,[switch]$CaptureStdoutForParser)
    if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken 'NativeProcessStart'}
    $path=Join-Path $env:windir ('System32\'+$Tool);if($Tool -eq 'appcmd.exe'){$path=Join-Path $env:windir 'System32\inetsrv\appcmd.exe'};if(-not [IO.File]::Exists($path)){throw 'Required local native tool unavailable.'}
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$path;$info.Arguments=(@($Arguments | ForEach-Object {ConvertTo-WsmWindowsArgument ([string]$_)}) -join ' ');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    Initialize-WsmNativeReader
    $process=New-WsmNativeOwnedProcess $info;$stdout=$null;$stderr=$null;$started=$false;$readerAbandoned=$false
    try {
        if(-not $process.Start()){throw 'Native tool did not start.'};$started=$true;$stdoutState=New-Object WsmNativeCaptureState(65536);$stderrState=New-Object WsmNativeCaptureState(65536);$stdout=[WsmNativeBoundedReader]::Drain($process.StandardOutput,65536,$stdoutState);$stderr=[WsmNativeBoundedReader]::Drain($process.StandardError,65536,$stderrState);$clock=[Diagnostics.Stopwatch]::StartNew();$nativeStartUtc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ',[Globalization.CultureInfo]::InvariantCulture);$lastObservedActivityUtc=$nativeStartUtc;$lastProgressSecond=0L
        while(-not $process.HasExited){
            if($process.WaitForExit(100)){break}
            if($clock.Elapsed.TotalSeconds -ge ($lastProgressSecond+1)){$outActivity=$stdoutState.Snapshot().LastObservedActivityUtc;$errActivity=$stderrState.Snapshot().LastObservedActivityUtc;$lastObservedActivityUtc=$outActivity;if([string]::CompareOrdinal($errActivity,$lastObservedActivityUtc) -gt 0){$lastObservedActivityUtc=$errActivity};$lastProgressSecond=[long][Math]::Floor($clock.Elapsed.TotalSeconds);[void](Set-WsmOperationProgress $CancellationToken 'NativeProcessWait' 0 0 ([long]$clock.Elapsed.TotalSeconds) $lastObservedActivityUtc)}
            if($CancellationToken -and (Test-WsmCancellationRequested $CancellationToken)){
                $stop=Stop-WsmNativeOwnedProcess $process;$outMeta=Get-WsmNativeReaderMetadata $stdout $stdoutState 250; $errMeta=Get-WsmNativeReaderMetadata $stderr $stderrState 250;$outPartial=(-not $outMeta.Complete);$errPartial=(-not $errMeta.Complete);$readerAbandoned=$outPartial -or $errPartial;Stop-WsmNativeReader $stdout $outPartial;Stop-WsmNativeReader $stderr $errPartial;$outMeta=Get-WsmNativeReaderMetadata $stdout $stdoutState 500 $outPartial;$errMeta=Get-WsmNativeReaderMetadata $stderr $stderrState 500 $errPartial;if($outMeta.Result -and [string]::CompareOrdinal($outMeta.Result.LastObservedActivityUtc,$lastObservedActivityUtc) -gt 0){$lastObservedActivityUtc=$outMeta.Result.LastObservedActivityUtc};if($errMeta.Result -and [string]::CompareOrdinal($errMeta.Result.LastObservedActivityUtc,$lastObservedActivityUtc) -gt 0){$lastObservedActivityUtc=$errMeta.Result.LastObservedActivityUtc}
                $cancel=New-Object OperationCanceledException('Owner cancellation stopped the owned native process; inspect target effects and reconcile before retry.');$cancel.Data['CancellationRequested']=$true;$cancel.Data['CancellationBoundary']='NativeProcessWait';$cancel.Data['PairId']=[string]$CancellationToken.PairId;$cancel.Data['PlanHash']=[string]$CancellationToken.PlanHash;$cancel.Data['ManifestHash']=[string]$CancellationToken.ManifestHash;$cancel.Data['OperationId']=[string]$CancellationToken.OperationId;$cancel.Data['NativeTool']=$Tool;$cancel.Data['NativeResult']='Cancelled';$cancel.Data['NativeProcessId']=$process.Id;$cancel.Data['ElapsedSeconds']=[long]$clock.Elapsed.TotalSeconds;$cancel.Data['LastObservedActivityUtc']=$lastObservedActivityUtc;$cancel.Data['ProcessKillAttempted']=$stop.KillAttempted;$cancel.Data['ProcessExitObserved']=$stop.ProcessExitObserved;$cancel.Data['ProcessKillVerified']=$stop.KillVerified;$cancel.Data['AutomaticRetrySafe']=$false
                $cancel.Data['TerminationScope']='OwnedProcessOnly';$cancel.Data['ChildProcessTerminationVerified']=$false
                foreach($pair in @(@('StdOut',$outMeta),@('StdErr',$errMeta))){$prefix=$pair[0];$meta=$pair[1];$cancel.Data[$prefix+'CaptureComplete']=$meta.CaptureSucceeded;$cancel.Data[$prefix+'ReaderFaulted']=$meta.ReaderFaulted;if($meta.Result){$cancel.Data[$prefix+'Characters']=$meta.Result.Characters;$cancel.Data[$prefix+'Utf8Bytes']=$meta.Result.Utf8Bytes;$cancel.Data[$prefix+'Sha256']=$meta.Result.Sha256;$cancel.Data[$prefix+'DigestKind']=$meta.Result.DigestKind;$cancel.Data[$prefix+'Truncated']=$meta.Result.Truncated}}
                throw $cancel
            }
            if($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds){
                $stop=Stop-WsmNativeOwnedProcess $process;$outMeta=Get-WsmNativeReaderMetadata $stdout $stdoutState 250;$errMeta=Get-WsmNativeReaderMetadata $stderr $stderrState 250;$outPartial=(-not $outMeta.Complete);$errPartial=(-not $errMeta.Complete);$readerAbandoned=$outPartial -or $errPartial;Stop-WsmNativeReader $stdout $outPartial;Stop-WsmNativeReader $stderr $errPartial;$outMeta=Get-WsmNativeReaderMetadata $stdout $stdoutState 500 $outPartial;$errMeta=Get-WsmNativeReaderMetadata $stderr $stderrState 500 $errPartial;if($outMeta.Result -and [string]::CompareOrdinal($outMeta.Result.LastObservedActivityUtc,$lastObservedActivityUtc) -gt 0){$lastObservedActivityUtc=$outMeta.Result.LastObservedActivityUtc};if($errMeta.Result -and [string]::CompareOrdinal($errMeta.Result.LastObservedActivityUtc,$lastObservedActivityUtc) -gt 0){$lastObservedActivityUtc=$errMeta.Result.LastObservedActivityUtc}
                $timeout=New-Object TimeoutException('Native tool timeout; inspect actual target and reconcile before retry.');$timeout.Data['NativeTool']=$Tool;$timeout.Data['NativeResult']='Timeout';$timeout.Data['NativeProcessId']=$process.Id;$timeout.Data['ElapsedSeconds']=[long]$clock.Elapsed.TotalSeconds;$timeout.Data['LastObservedActivityUtc']=$lastObservedActivityUtc;$timeout.Data['ProcessKillAttempted']=$stop.KillAttempted;$timeout.Data['ProcessExitObserved']=$stop.ProcessExitObserved;$timeout.Data['ProcessKillVerified']=$stop.KillVerified;$timeout.Data['AutomaticRetrySafe']=$false
                $timeout.Data['TerminationScope']='OwnedProcessOnly';$timeout.Data['ChildProcessTerminationVerified']=$false
                foreach($pair in @(@('StdOut',$outMeta),@('StdErr',$errMeta))){$prefix=$pair[0];$meta=$pair[1];$timeout.Data[$prefix+'CaptureComplete']=$meta.CaptureSucceeded;$timeout.Data[$prefix+'ReaderFaulted']=$meta.ReaderFaulted;if($meta.Result){$timeout.Data[$prefix+'Characters']=$meta.Result.Characters;$timeout.Data[$prefix+'Utf8Bytes']=$meta.Result.Utf8Bytes;$timeout.Data[$prefix+'Sha256']=$meta.Result.Sha256;$timeout.Data[$prefix+'DigestKind']=$meta.Result.DigestKind;$timeout.Data[$prefix+'Truncated']=$meta.Result.Truncated}}
                throw $timeout
            }
        }
        $code=$process.ExitCode;$outMeta=Get-WsmNativeReaderMetadata $stdout $stdoutState 2000;$errMeta=Get-WsmNativeReaderMetadata $stderr $stderrState 2000
        $outPartial=(-not $outMeta.Complete);$errPartial=(-not $errMeta.Complete);$readerAbandoned=$outPartial -or $errPartial;if($outPartial){Stop-WsmNativeReader $stdout $true;$outMeta=Get-WsmNativeReaderMetadata $stdout $stdoutState 500 $true};if($errPartial){Stop-WsmNativeReader $stderr $true;$errMeta=Get-WsmNativeReaderMetadata $stderr $stderrState 500 $true}
        $output='';if($outMeta.Result){$output=$outMeta.Result.Text};$success=($code -eq 0);if($Tool -eq 'robocopy.exe'){$success=($code -ge 0 -and $code -lt 8)}
        $lastObservedActivityUtc=$nativeStartUtc;if($outMeta.Result -and [string]::CompareOrdinal($outMeta.Result.LastObservedActivityUtc,$lastObservedActivityUtc) -gt 0){$lastObservedActivityUtc=$outMeta.Result.LastObservedActivityUtc};if($errMeta.Result -and [string]::CompareOrdinal($errMeta.Result.LastObservedActivityUtc,$lastObservedActivityUtc) -gt 0){$lastObservedActivityUtc=$errMeta.Result.LastObservedActivityUtc}
        [pscustomobject]@{Tool=$Tool;NativeCode=$code;NativeResult='Exited';Succeeded=$success;ProcessId=$process.Id;ProcessExitObserved=$true;ProcessKillAttempted=$false;ProcessKillVerified=$null;TerminationScope='OwnedProcessOnly';ChildProcessTerminationVerified=$false;ElapsedSeconds=[long]$clock.Elapsed.TotalSeconds;LastObservedActivityUtc=$lastObservedActivityUtc;StdOutCharacters=$(if($outMeta.Result){$outMeta.Result.Characters}else{0});StdErrCharacters=$(if($errMeta.Result){$errMeta.Result.Characters}else{0});StdOutUtf8Bytes=$(if($outMeta.Result){$outMeta.Result.Utf8Bytes}else{0});StdErrUtf8Bytes=$(if($errMeta.Result){$errMeta.Result.Utf8Bytes}else{0});StdOutSha256=$(if($outMeta.Result){$outMeta.Result.Sha256}else{''});StdErrSha256=$(if($errMeta.Result){$errMeta.Result.Sha256}else{''});StdOutDigestKind=$(if($outMeta.Result){$outMeta.Result.DigestKind}else{''});StdErrDigestKind=$(if($errMeta.Result){$errMeta.Result.DigestKind}else{''});StdOutCaptureComplete=$outMeta.CaptureSucceeded;StdErrCaptureComplete=$errMeta.CaptureSucceeded;StdOutReaderFaulted=$outMeta.ReaderFaulted;StdErrReaderFaulted=$errMeta.ReaderFaulted;OutputTruncated=(-not $outMeta.CaptureSucceeded) -or (-not $errMeta.CaptureSucceeded) -or ($outMeta.Result -and $outMeta.Result.Truncated) -or ($errMeta.Result -and $errMeta.Result.Truncated);ParserOutput=$(if($CaptureStdoutForParser){$output}else{$null})}
    } catch {
        $failure=$_.Exception
        if($started){try{if(-not $process.HasExited){$stop=Stop-WsmNativeOwnedProcess $process;if(-not $failure.Data.Contains('ProcessKillAttempted')){$failure.Data['NativeTool']=$Tool;$failure.Data['NativeProcessId']=$process.Id;$failure.Data['ProcessKillAttempted']=$stop.KillAttempted;$failure.Data['ProcessExitObserved']=$stop.ProcessExitObserved;$failure.Data['ProcessKillVerified']=$stop.KillVerified;$failure.Data['TerminationScope']='OwnedProcessOnly';$failure.Data['ChildProcessTerminationVerified']=$false;$failure.Data['AutomaticRetrySafe']=$false}}}catch{}}
        throw
    } finally {
        if($started){try{if(-not $process.HasExited){[void](Stop-WsmNativeOwnedProcess $process)}}catch{};if(-not $readerAbandoned){Stop-WsmNativeReader $stdout;Stop-WsmNativeReader $stderr}}
        if(-not $readerAbandoned){$process.Dispose()}
        Clear-WsmOperationProgress $CancellationToken
    }
}
function Invoke-WsmNativeTool {
    param([ValidateSet('sc.exe','robocopy.exe','appcmd.exe')][string]$Tool,[string[]]$Arguments,[ValidateRange(1,3600)][int]$TimeoutSeconds=120,[psobject]$CancellationToken)
    $r=Invoke-WsmNativeToolCore $Tool $Arguments $TimeoutSeconds $CancellationToken
    [pscustomobject]@{Tool=$r.Tool;NativeCode=$r.NativeCode;NativeResult=$r.NativeResult;Succeeded=$r.Succeeded;ProcessId=$r.ProcessId;ProcessExitObserved=$r.ProcessExitObserved;ProcessKillAttempted=$r.ProcessKillAttempted;ProcessKillVerified=$r.ProcessKillVerified;TerminationScope=$r.TerminationScope;ChildProcessTerminationVerified=$r.ChildProcessTerminationVerified;ElapsedSeconds=$r.ElapsedSeconds;LastObservedActivityUtc=$r.LastObservedActivityUtc;StdOutCharacters=$r.StdOutCharacters;StdErrCharacters=$r.StdErrCharacters;StdOutUtf8Bytes=$r.StdOutUtf8Bytes;StdErrUtf8Bytes=$r.StdErrUtf8Bytes;StdOutSha256=$r.StdOutSha256;StdErrSha256=$r.StdErrSha256;StdOutDigestKind=$r.StdOutDigestKind;StdErrDigestKind=$r.StdErrDigestKind;StdOutCaptureComplete=$r.StdOutCaptureComplete;StdErrCaptureComplete=$r.StdErrCaptureComplete;StdOutReaderFaulted=$r.StdOutReaderFaulted;StdErrReaderFaulted=$r.StdErrReaderFaulted;OutputTruncated=$r.OutputTruncated;RawOutputIncluded=$false}
}
function Invoke-WsmServiceSecurity([string]$Name,[string]$Sddl) {
    $descriptor=New-Object Security.AccessControl.RawSecurityDescriptor($Sddl)
    $r=Invoke-WsmNativeTool 'sc.exe' @('sdset',$Name,$Sddl) -TimeoutSeconds 120
    if(-not $r.Succeeded){throw (New-WsmNativeFailure 'sc.exe' $r.NativeCode 'Service security update')}
    $r.NativeCode
}
function Get-WsmServiceSecurity([string]$Name) {
    $r=Invoke-WsmNativeToolCore 'sc.exe' @('sdshow',$Name) 120 $null -CaptureStdoutForParser;if(-not $r.Succeeded){throw (New-WsmNativeFailure 'sc.exe' $r.NativeCode 'Service security query')}
    if(-not $r.StdOutCaptureComplete -or $r.StdOutReaderFaulted -or $r.OutputTruncated){throw 'Service security query output was truncated or incomplete.'};$sddl=@($r.ParserOutput.Split([char]10) | ForEach-Object {$_.Trim()} | Where-Object {$_ -match '^(?:O:|G:|D:|S:)'});if($sddl.Count -ne 1){throw 'Unrecognized service security descriptor output.'};[void](New-Object Security.AccessControl.RawSecurityDescriptor($sddl[0]));$sddl[0]
}
