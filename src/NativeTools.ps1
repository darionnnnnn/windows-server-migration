function Initialize-WsmNativeReader {
    if('WsmNativeBoundedReader' -as [type]){return}
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
public sealed class WsmNativeOutput { public string Text; public bool Truncated; }
public static class WsmNativeBoundedReader {
    public static async Task<WsmNativeOutput> Drain(TextReader reader, int limit) {
        char[] buffer = new char[4096]; var text = new StringBuilder(limit); bool truncated = false;
        int count;
        while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) > 0) {
            if (text.Length + count > limit) { text.Remove(0, text.Length + count - limit); truncated = true; }
            text.Append(buffer, 0, count);
        }
        return new WsmNativeOutput { Text = text.ToString(), Truncated = truncated };
    }
}
"@
}
function ConvertTo-WsmWindowsArgument([string]$Value) {
    if($Value -match '[\x00\r\n]'){throw 'Native argument contains control characters.'}
    if($Value -ne '' -and $Value -notmatch '[\s"]'){return $Value}
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Invoke-WsmNativeTool {
    param([ValidateSet('sc.exe','robocopy.exe','appcmd.exe')][string]$Tool,[string[]]$Arguments,[ValidateRange(1,3600)][int]$TimeoutSeconds=120)
    $path=Join-Path $env:windir ('System32\'+$Tool);if($Tool -eq 'appcmd.exe'){$path=Join-Path $env:windir 'System32\inetsrv\appcmd.exe'};if(-not [IO.File]::Exists($path)){throw 'Required local native tool unavailable.'}
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$path;$info.Arguments=(@($Arguments | ForEach-Object {ConvertTo-WsmWindowsArgument $_}) -join ' ');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    Initialize-WsmNativeReader
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{if(-not $process.Start()){throw 'Native tool did not start.'};$stdout=[WsmNativeBoundedReader]::Drain($process.StandardOutput,65536);$stderr=[WsmNativeBoundedReader]::Drain($process.StandardError,65536);if(-not $process.WaitForExit($TimeoutSeconds*1000)){$process.Kill();$process.WaitForExit();throw (New-Object TimeoutException('Native tool timeout; inspect actual target before retry.'))};$outResult=$stdout.GetAwaiter().GetResult();$errResult=$stderr.GetAwaiter().GetResult();$output=$outResult.Text;$errorText=$errResult.Text;$code=$process.ExitCode;$success=($code -eq 0);if($Tool -eq 'robocopy.exe'){$success=($code -ge 0 -and $code -lt 8)};$limit=65536;if($output.Length -gt $limit){$output=$output.Substring($output.Length-$limit)};if($errorText.Length -gt $limit){$errorText=$errorText.Substring($errorText.Length-$limit)};[pscustomobject]@{Tool=$Tool;NativeCode=$code;Succeeded=$success;Output=$output;Error=$errorText;OutputTruncated=($outResult.Truncated -or $errResult.Truncated)}}finally{$process.Dispose()}
}
function Invoke-WsmServiceSecurity([string]$Name,[string]$Sddl) {
    $descriptor=New-Object Security.AccessControl.RawSecurityDescriptor($Sddl)
    $r=Invoke-WsmNativeTool 'sc.exe' @('sdset',$Name,$Sddl)
    if(-not $r.Succeeded){throw (New-WsmNativeFailure 'sc.exe' $r.NativeCode 'Service security update')}
    $r.NativeCode
}
function Get-WsmServiceSecurity([string]$Name) {
    $r=Invoke-WsmNativeTool 'sc.exe' @('sdshow',$Name);if(-not $r.Succeeded){throw (New-WsmNativeFailure 'sc.exe' $r.NativeCode 'Service security query')}
    $sddl=@($r.Output.Split([char]10) | ForEach-Object {$_.Trim()} | Where-Object {$_ -match '^(?:O:|G:|D:|S:)'});if($sddl.Count -ne 1){throw 'Unrecognized service security descriptor output.'};[void](New-Object Security.AccessControl.RawSecurityDescriptor($sddl[0]));$sddl[0]
}
