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
# S12（PLAN 17.129）：「路徑在根底下」全專案唯一的實作；其他檔案不得再自寫 StartsWith(根+'\') 比對（tests/Test-PathWithinRoot.ps1 有靜態守門）。
# Win32 模式（預設）：兩邊先 GetFullPath（正規化 / 與 \、. 與 ..、磁碟根、UNC 根），再比較；輸入無法正規化時照 .NET 例外往外丟（呼叫端原本就是這樣）。
# 原生模式（-Native）：用於已解析成 \Device\... 或實體路徑的字串，只做字面比較，絕不送進 GetFullPath；含 . 或 .. 段的原生路徑無法字面判定，視為不在根底下（失敗即拒絕）。
# -AllowDotSegments（只給「重疊」這種拒絕檢查用）：原生模式照字面比較、不因 . 或 .. 段而回 $null，避免怪異路徑讓防碰撞檢查放行。
# 兄弟前綴（C:\data 與 C:\data2）一律不算；大小寫不分；尾端分隔符忽略；磁碟根 C:\ 與 UNC 根 \\srv\share 底下的路徑算在內。
# -ExcludeRoot：等於根本身不算在根底下（預設算）。
# Get-WsmPathRelativeToRoot：等於根回 ''，不在根底下回 $null，否則回相對路徑；空路徑、空根一律 $null。
function Get-WsmPathRelativeToRoot([string]$Path,[string]$Root,[switch]$Native,[switch]$AllowDotSegments) {
    if([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Root)){return $null}
    if($Native -and -not $AllowDotSegments){foreach($segment in @($Path.Split('\'))+@($Root.Split('\'))){if($segment -ceq '.' -or $segment -ceq '..'){return $null}}}
    if($Native){$pathValue=$Path;$rootValue=$Root}else{$pathValue=[IO.Path]::GetFullPath($Path);$rootValue=[IO.Path]::GetFullPath($Root)}
    $pathValue=$pathValue.TrimEnd('\');$rootValue=$rootValue.TrimEnd('\')
    if(-not $pathValue -or -not $rootValue){return $null}
    if($pathValue.Equals($rootValue,[StringComparison]::OrdinalIgnoreCase)){return ''}
    if($pathValue.StartsWith($rootValue+'\',[StringComparison]::OrdinalIgnoreCase)){return $pathValue.Substring($rootValue.Length).TrimStart('\')}
    $null
}
function Test-WsmPathWithinRoot([string]$Path,[string]$Root,[switch]$Native,[switch]$ExcludeRoot) {
    $relative=Get-WsmPathRelativeToRoot $Path $Root -Native:$Native
    if($null -eq $relative){return $false}
    return (-not ($ExcludeRoot -and $relative -ceq ''))
}
# 重疊判定（任一邊在另一邊底下，含相等）：字面比較、不解讀 ..；這是防碰撞用的拒絕檢查，不可因為路徑怪異而放行，所以不套用原生模式的 .. 拒絕。
function Test-WsmPathOverlap([string]$Left,[string]$Right) {
    if($Left.TrimEnd('\').Equals($Right.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){return $true}
    return (($null -ne (Get-WsmPathRelativeToRoot $Left $Right -Native -AllowDotSegments)) -or ($null -ne (Get-WsmPathRelativeToRoot $Right $Left -Native -AllowDotSegments)))
}
