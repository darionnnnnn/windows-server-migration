function Merge-WsmSortedHashFiles([string[]]$Paths,[string]$OutputPath) {
    Initialize-WsmExternalMerge;[WsmExternalMerge]::Merge($Paths,$OutputPath)
}
function Initialize-WsmExternalMerge {
    if('WsmExternalMerge' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class WsmExternalMerge {
    public static void Merge(string[] paths, string output) {
        if(paths.Length==0 || paths.Length>64) throw new InvalidDataException("Merge fan-in must be 1..64.");
        var readers=new StreamReader[paths.Length];var heads=new string[paths.Length];
        try {
            for(int n=0;n<paths.Length;n++){readers[n]=new StreamReader(paths[n],Encoding.ASCII);heads[n]=readers[n].ReadLine();}
            using(var writer=new StreamWriter(output,false,Encoding.ASCII)) {
                while(true){int best=-1;for(int n=0;n<heads.Length;n++){if(heads[n]!=null && (best<0 || StringComparer.Ordinal.Compare(heads[n],heads[best])<0))best=n;}
                    if(best<0)break;if(heads[best].Length!=64)throw new InvalidDataException("Invalid generated hash row.");
                    writer.WriteLine(heads[best]);heads[best]=readers[best].ReadLine();
                }
            }
        } finally {foreach(var reader in readers){if(reader!=null)reader.Dispose();}}
    }
}
'@
}
function New-WsmArtifactKeySpool {
    $root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-index-keys-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root
    [pscustomobject]@{Root=$root;Serial=0;Buffer=(New-Object 'System.Collections.Generic.List[string]');Parts=(New-Object 'System.Collections.Generic.List[string]');Known=(New-Object 'System.Collections.Generic.List[string]')}
}
function Save-WsmKeySpoolPart($Spool) {
    if(-not $Spool.Buffer.Count){return};$path=Join-Path $Spool.Root ('part-'+$Spool.Serial+'.txt');$Spool.Serial++;$Spool.Buffer.Sort([StringComparer]::Ordinal);[IO.File]::WriteAllLines($path,$Spool.Buffer,[Text.Encoding]::ASCII);$Spool.Known.Add($path);$Spool.Parts.Add($path);$Spool.Buffer.Clear()
}
function Add-WsmArtifactKey($Spool,[string]$Key) {
    $Spool.Buffer.Add((Get-WsmHashText $Key));if($Spool.Buffer.Count -ge 5000){Save-WsmKeySpoolPart $Spool}
}
function Assert-WsmArtifactKeysUnique($Spool) {
    Save-WsmKeySpoolPart $Spool
    while($Spool.Parts.Count -gt 1){$next=New-Object 'System.Collections.Generic.List[string]';for($n=0;$n -lt $Spool.Parts.Count;$n+=64){$last=[Math]::Min($n+63,$Spool.Parts.Count-1);$group=@(for($i=$n;$i -le $last;$i++){$Spool.Parts[$i]});$merged=Join-Path $Spool.Root ('merge-'+$Spool.Serial+'.txt');$Spool.Serial++;Merge-WsmSortedHashFiles $group $merged;$Spool.Known.Add($merged);$next.Add($merged);foreach($path in $group){[IO.File]::Delete($path)}};$Spool.Parts=$next}
    if($Spool.Parts.Count){$reader=New-Object IO.StreamReader($Spool.Parts[0],[Text.Encoding]::ASCII);try{$previous=$null;while($null -ne ($key=$reader.ReadLine())){if($key -ceq $previous){throw 'Duplicate/case-colliding artifact destination.'};$previous=$key}}finally{$reader.Dispose()}}
}
function Remove-WsmKeySpool($Spool) {
    foreach($path in $Spool.Known){if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -cne $Spool.Root){throw 'Artifact key cleanup escaped generated workspace.'};if([IO.File]::Exists($path)){[IO.File]::Delete($path)}};[IO.Directory]::Delete($Spool.Root,$false)
}
function Get-WsmStreamingScopeDigest([string]$Root,[string]$MetadataMode,$CancellationToken=$null) {
    if(-not [IO.File]::Exists($Root) -and -not [IO.Directory]::Exists($Root)){return ''}
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('wsm-digest-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($scratch);Protect-WsmDirectory $scratch
    $parts=New-Object 'System.Collections.Generic.List[string]';$known=New-Object 'System.Collections.Generic.List[string]';$buffer=New-Object 'System.Collections.Generic.List[string]';$count=[long]0;$serial=0
    try{
        Get-WsmScopeEntries ([pscustomobject]@{SourcePath=$Root;ExcludedRelativePaths=@()}) $scratch $CancellationToken | ForEach-Object {$e=$_;Assert-WsmCancellationBoundary $CancellationToken 'ScopeDigestEntry';$fileHash='';if(-not $e.Directory){$fileHash=Get-WsmCancellableFileHash $e.SourcePath $CancellationToken 'ScopeDigestHashBuffer'};$meta=Get-WsmFileMetadata $e.SourcePath $MetadataMode;$row=[pscustomobject][ordered]@{RelativePath=$e.RelativePath.ToUpperInvariant();Directory=$e.Directory;Hash=$fileHash;Sddl=$meta.Sddl;Attributes=$meta.Attributes;CreationUtc=$meta.CreationUtc;LastWriteUtc=$meta.LastWriteUtc};$buffer.Add((Get-WsmHashText ($row | ConvertTo-Json -Depth 8 -Compress)));$count++
            if($buffer.Count -ge 5000){Assert-WsmCancellationBoundary $CancellationToken 'ScopeDigestSpill';$part=Join-Path $scratch ('part-'+$serial+'.txt');$serial++;[IO.File]::WriteAllLines($part,[string[]]@($buffer | Sort-Object),[Text.Encoding]::ASCII);$parts.Add($part);$known.Add($part);$buffer.Clear();Write-Progress -Activity 'Verifying owned scope (bounded memory)' -Status ($count.ToString()+' entries inspected')}
        }
        if($buffer.Count){$part=Join-Path $scratch ('part-'+$serial+'.txt');$serial++;[IO.File]::WriteAllLines($part,[string[]]@($buffer | Sort-Object),[Text.Encoding]::ASCII);$parts.Add($part);$known.Add($part);$buffer.Clear()}
        while($parts.Count -gt 1){$next=New-Object 'System.Collections.Generic.List[string]';for($n=0;$n -lt $parts.Count;$n+=64){Assert-WsmCancellationBoundary $CancellationToken 'ScopeDigestMerge';$last=[Math]::Min($n+63,$parts.Count-1);$group=@(for($i=$n;$i -le $last;$i++){$parts[$i]});$merged=Join-Path $scratch ('merge-'+$serial+'.txt');$serial++;Merge-WsmSortedHashFiles $group $merged;$known.Add($merged);$next.Add($merged);foreach($path in $group){[IO.File]::Delete($path)}};$parts=$next}
        $sha=[Security.Cryptography.SHA256]::Create();try{$header=[Text.Encoding]::ASCII.GetBytes($count.ToString([Globalization.CultureInfo]::InvariantCulture)+':');[void]$sha.TransformBlock($header,0,$header.Length,$header,0);if($parts.Count){$file=[IO.File]::Open($parts[0],'Open','Read','Read');try{$bytes=New-Object byte[] 65536;while($true){Assert-WsmCancellationBoundary $CancellationToken 'ScopeDigestFinalHashBuffer';$n=$file.Read($bytes,0,$bytes.Length);if($n -le 0){break};[void]$sha.TransformBlock($bytes,0,$n,$bytes,0)}}finally{$file.Dispose()}};[void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0);[BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    }finally{foreach($path in $known){if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -cne $scratch){throw 'Digest cleanup path escaped generated workspace.'};if([IO.File]::Exists($path)){[IO.File]::Delete($path)}};if([IO.Directory]::Exists($scratch)){[IO.Directory]::Delete($scratch,$false)};Write-Progress -Activity 'Verifying owned scope (bounded memory)' -Completed}
}
function Read-WsmBoundedLines($Reader,[int]$MaximumCharacters=1048576) {
    $buffer=New-Object char[] 65536;$pending=New-Object Text.StringBuilder
    while(($length=$Reader.Read($buffer,0,$buffer.Length)) -gt 0){$chunk=New-Object string($buffer,0,$length);$start=0;while($start -lt $chunk.Length){$end=$chunk.IndexOf([char]10,$start);$finish=$chunk.Length;if($end -ge 0){$finish=$end};$size=$finish-$start;if($pending.Length+$size -gt $MaximumCharacters){throw 'Artifact/journal row exceeds bounded line limit.'};if($size){[void]$pending.Append($chunk,$start,$size)};if($end -lt 0){break};$line=$pending.ToString().TrimEnd([char]13);$pending.Clear() | Out-Null;if($line){$line};$start=$end+1}}
    if($pending.Length){$pending.ToString().TrimEnd([char]13)}
}
