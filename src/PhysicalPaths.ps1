function Initialize-WsmPhysicalPathApi {
    if('WsmPhysicalPath' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class WsmPhysicalPath {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder name, uint count, uint flags);
    public static string Resolve(string path) {
        using(var handle=CreateFileW(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
            if(handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var buffer=new StringBuilder(32768);
            uint result=GetFinalPathNameByHandleW(handle,buffer,(uint)buffer.Capacity,2);
            if(result==0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if(result>=buffer.Capacity) throw new InvalidOperationException("Physical path exceeds bounded buffer.");
            return buffer.ToString();
        }
    }
}
'@
}
function Get-WsmPhysicalPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path);Assert-WsmNoReparse $full
    # Resolve the nearest existing ancestor. Nonexistent descendants retain literal names.
    $tail=New-Object 'System.Collections.Generic.Stack[string]';$cursor=$full
    while(-not [IO.Directory]::Exists($cursor) -and -not [IO.File]::Exists($cursor)){$leaf=[IO.Path]::GetFileName($cursor.TrimEnd('\'));$parent=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\'));if(-not $parent -or $parent -eq $cursor){throw 'Physical path ancestor unavailable; cannot establish collision boundary.'};$tail.Push($leaf);$cursor=$parent}
    Initialize-WsmPhysicalPathApi;$physical=[WsmPhysicalPath]::Resolve($cursor).TrimEnd('\')
    if($physical.StartsWith('\Device\Mup\',[StringComparison]::OrdinalIgnoreCase) -or $physical.StartsWith('\Device\LanmanRedirector\',[StringComparison]::OrdinalIgnoreCase)){throw 'Network path requires reviewed dedicated alias/collision handling; generic FileScope cannot establish local physical ownership.'}
    while($tail.Count){$physical+='\'+$tail.Pop()};$physical
}
function Test-WsmPathOverlap([string]$Left,[string]$Right) {
    $Left=$Left.TrimEnd('\');$Right=$Right.TrimEnd('\');$Left -ieq $Right -or $Left.StartsWith($Right+'\',[StringComparison]::OrdinalIgnoreCase) -or $Right.StartsWith($Left+'\',[StringComparison]::OrdinalIgnoreCase)
}
