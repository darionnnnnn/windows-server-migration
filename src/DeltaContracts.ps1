function Initialize-WsmDeltaMerge {
    if ('WsmDeltaMerge' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class WsmDeltaMerge {
    public static string Key(string line) { int i=line.IndexOf('\t'); if(i<1) throw new InvalidDataException("Invalid delta spool row."); return line.Substring(0,i); }
    public static void Merge(string[] paths,string output) {
        if(paths.Length<1 || paths.Length>64) throw new InvalidDataException("Delta merge fan-in must be 1..64.");
        var readers=new StreamReader[paths.Length];var heads=new string[paths.Length];
        try {
            for(int n=0;n<paths.Length;n++){readers[n]=new StreamReader(paths[n],Encoding.ASCII);heads[n]=readers[n].ReadLine();}
            using(var writer=new StreamWriter(output,false,Encoding.ASCII)) {
                while(true){int best=-1;for(int n=0;n<heads.Length;n++){if(heads[n]!=null && (best<0 || StringComparer.Ordinal.Compare(Key(heads[n]),Key(heads[best]))<0))best=n;}
                    if(best<0)break;writer.WriteLine(heads[best]);heads[best]=readers[best].ReadLine();}
            }
        } finally {foreach(var reader in readers){if(reader!=null)reader.Dispose();}}
    }
}
'@
}
function Get-WsmDeltaFileHash([string]$Path) {
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($Path),'Open','Read','Read');$sha=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose();$stream.Dispose() }
}
function Get-WsmDeltaCanonicalJsonHash($Value) {
    $json=ConvertTo-Json -InputObject $Value -Depth 30 -Compress
    Get-WsmHashText $json
}
function ConvertTo-WsmDeltaKeyHex([string]$ItemId,[string]$RelativePath) {
    $key=$ItemId.ToLowerInvariant()+'|'+$RelativePath.ToUpperInvariant()
    ([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','').ToLowerInvariant()
}
function Save-WsmDeltaRun($State) {
    if(-not $State.Buffer.Count){return}
    # The fixed-length lowercase hexadecimal canonical key is the prefix, so ordinal
    # line sorting is exactly ordinal key sorting and needs no culture-sensitive sort.
    $State.Buffer.Sort([StringComparer]::Ordinal)
    $path=Join-Path $State.Root ('run-'+$State.Serial+'.txt');$State.Serial++
    [IO.File]::WriteAllLines($path,[string[]]$State.Buffer.ToArray(),[Text.Encoding]::ASCII)
    $State.Runs.Add($path);$State.Known.Add($path);$State.Buffer.Clear()
}
function Add-WsmDeltaSpoolRow($State,[string]$KeyHex,[string]$JsonLine) {
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($JsonLine))
    $State.Buffer.Add($KeyHex+"`t"+$payload)
    if($State.Buffer.Count -ge 5000){Save-WsmDeltaRun $State}
}
function Merge-WsmDeltaRuns($State) {
    Save-WsmDeltaRun $State
    while($State.Runs.Count -gt 1){
        $next=New-Object 'System.Collections.Generic.List[string]'
        for($n=0;$n -lt $State.Runs.Count;$n+=64){
            $last=[Math]::Min($n+63,$State.Runs.Count-1);$group=@(for($i=$n;$i -le $last;$i++){$State.Runs[$i]})
            $merged=Join-Path $State.Root ('merge-'+$State.Serial+'.txt');$State.Serial++
            Initialize-WsmDeltaMerge;[WsmDeltaMerge]::Merge([string[]]$group,$merged)
            $State.Known.Add($merged);$next.Add($merged)
            foreach($part in $group){[IO.File]::Delete($part)}
        }
        $State.Runs=$next
    }
    if($State.Runs.Count){$State.Runs[0]}else{$null}
}
function Assert-WsmDeltaSpoolUnique([string]$Path) {
    if(-not $Path){return};$reader=New-Object IO.StreamReader($Path,[Text.Encoding]::ASCII)
    try{$previous=$null;while($null -ne ($line=$reader.ReadLine())){$key=[WsmDeltaMerge]::Key($line);if($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$key) -eq 0){throw 'Duplicate/case-colliding canonical artifact key in trusted index.'};$previous=$key}}finally{$reader.Dispose()}
}
function Read-WsmDeltaSortedIndex([string]$IndexPath,[string]$ExpectedHash,$Plan,$State) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or (Get-WsmDeltaFileHash $IndexPath) -ine $ExpectedHash){throw 'Trusted artifact index hash mismatch.'}
    Assert-WsmNoReparse $IndexPath
    $included=@{};foreach($item in $Plan.Items){if($item.Decision -eq 'Include'){$included[[string]$item.ItemId]=$item}}
    $seenItems=@{};$recordCount=[long]0
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($IndexPath),'Open','Read','Read');$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
    try {
        Read-WsmBoundedLines $reader 1048576 | ForEach-Object {
            $line=$_
            if($line){
            $row=ConvertFrom-WsmJson $line
            Assert-WsmFields $row @('ItemId','RelativePath','Directory','Metadata','Data') @('ItemId','RelativePath','Directory','Metadata','Data')
            if([string]$row.ItemId -notmatch '^[a-f0-9]{64}$' -or -not $included.ContainsKey([string]$row.ItemId)){throw 'Delta artifact references an unapproved item.'}
            $item=$included[[string]$row.ItemId];if($item.MigrationSpec.Adapter -notin @('FileScope','Certificate')){throw 'Delta index contains an unsupported item type.'}
            if($row.RelativePath -isnot [string]){throw 'Delta artifact path must be a string.'};Assert-WsmRelativePath $row.RelativePath -AllowRoot
            Assert-WsmArtifactRecord $row $item
            $key=ConvertTo-WsmDeltaKeyHex $row.ItemId $row.RelativePath
            Add-WsmDeltaSpoolRow $State $key $line
            $seenItems[[string]$row.ItemId]=$true;$recordCount++
            }
        }
    } finally { $reader.Dispose();$stream.Dispose() }
    foreach($item in $Plan.Items){if($item.Decision -eq 'Include' -and $item.MigrationSpec.Adapter -in @('FileScope','Certificate') -and -not $seenItems.ContainsKey([string]$item.ItemId)){throw ('Selected payload item missing from trusted index: '+$item.ItemId)}}
    $sorted=Merge-WsmDeltaRuns $State;Assert-WsmDeltaSpoolUnique $sorted
    [pscustomobject]@{Path=$sorted;Records=$recordCount}
}
function Read-WsmDeltaSpoolRow([string]$Line) {
    $separator=$Line.IndexOf("`t");if($separator -lt 1){throw 'Invalid sorted delta row.'}
    $json=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Line.Substring($separator+1)))
    [pscustomobject]@{Key=$Line.Substring(0,$separator);Json=$json;Row=(ConvertFrom-WsmJson $json)}
}
function Get-WsmDeltaRecordParts($Row) {
    $data=$null
    if($null -ne $Row.Data){$data=[pscustomobject][ordered]@{Bytes=[long]$Row.Data.Bytes;Hash=[string]$Row.Data.Hash;Chunks=@(foreach($chunk in $Row.Data.Chunks){[pscustomobject][ordered]@{Hash=[string]$chunk.Hash;Bytes=[long]$chunk.Bytes}})}}
    $metadata=$null
    if($null -ne $Row.Metadata){$metadata=[pscustomobject][ordered]@{Sddl=[string]$Row.Metadata.Sddl;MetadataMode=[string]$Row.Metadata.MetadataMode;Attributes=[long]$Row.Metadata.Attributes;CreationUtc=[string]$Row.Metadata.CreationUtc;LastWriteUtc=[string]$Row.Metadata.LastWriteUtc}}
    [pscustomobject]@{DataHash=(Get-WsmDeltaCanonicalJsonHash $data);MetadataHash=(Get-WsmDeltaCanonicalJsonHash $metadata);Directory=[bool]$Row.Directory;RecordHash=(Get-WsmHashText ([string]$Row.ItemId+'|'+[string]$Row.RelativePath+'|'+(Get-WsmDeltaCanonicalJsonHash ([pscustomobject][ordered]@{Directory=[bool]$Row.Directory;Metadata=$metadata;Data=$data}))))}
}
function Assert-WsmDeltaPlanBinding($Plan,[string]$ExpectedHash,$Manifest) {
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or $Manifest.PlanHash -ine $ExpectedHash -or $Plan.PairId -cne $Manifest.PairId -or $Plan.BatchId -cne $Manifest.BatchId -or $Plan.ApprovalId -cne $Manifest.ApprovalId -or $Plan.Source.HostId -cne $Manifest.Source.HostId -or $Plan.Source.Fingerprint -cne $Manifest.Source.Fingerprint -or $Plan.Target.HostId -cne $Manifest.Target.HostId -or $Plan.Target.Fingerprint -cne $Manifest.Target.Fingerprint){throw 'Delta manifest/approved plan binding mismatch.'}
}
function Read-WsmDeltaInput([string]$ManifestPath,[string]$ManifestHash,[string]$PlanPath,[string]$PlanHash) {
    Assert-WsmNoReparse $ManifestPath;Assert-WsmNoReparse $PlanPath
    $manifest=Read-WsmTrustedJson $ManifestPath $ManifestHash;Assert-WsmEnvelope $manifest 'MigrationPackage'
    foreach($id in @($manifest.PairId,$manifest.BatchId,$manifest.ApprovalId,$manifest.PackageId)){Assert-WsmId $id}
    if(($manifest.Generation -isnot [int] -and $manifest.Generation -isnot [long]) -or $manifest.Generation -lt 1 -or $manifest.ArtifactsHash -notmatch '^[a-f0-9]{64}$'){throw 'Invalid delta package generation/index contract.'}
    $plan=Read-WsmTrustedJson $PlanPath $PlanHash;Assert-WsmEnvelope $plan 'MigrationPlan';Assert-WsmDeltaPlanBinding $plan $PlanHash $manifest
    if($plan.ToolFingerprint -cne (Get-WsmToolFingerprint) -or $plan.Mode -cne 'IsolatedPilot'){throw 'Delta plan is not an approved current tool plan.'}
    foreach($item in $plan.Items){if($item.ItemId -notmatch '^[a-f0-9]{64}$' -or @('Include','Exclude') -cnotcontains $item.Decision){throw 'Invalid delta plan item.'};if($item.Decision -eq 'Include'){Assert-WsmMigrationSpec $item.MigrationSpec}}
    $index=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ManifestPath))) 'artifacts.jsonl';Assert-WsmNoReparse $index
    if((Get-WsmDeltaFileHash $index) -ine $manifest.ArtifactsHash){throw 'Package artifact index hash mismatch.'}
    foreach($item in $plan.Items){if($item.Decision -ceq 'Include' -and $item.MigrationSpec.Adapter -ceq 'FileScope'){Assert-WsmApprovedConfigArtifacts -Spec $item.MigrationSpec -ArtifactsPath $index -ExpectedHash $manifest.ArtifactsHash -ItemId $item.ItemId | Out-Null}}
    [pscustomobject]@{Manifest=$manifest;ManifestHash=$ManifestHash.ToLowerInvariant();Plan=$plan;PlanHash=$PlanHash.ToLowerInvariant();IndexPath=$index}
}
function New-WsmArtifactDeltaManifest {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$BaseManifestPath,[Parameter(Mandatory)][string]$BaseManifestHash,
        [Parameter(Mandatory)][string]$BasePlanPath,[Parameter(Mandatory)][string]$BasePlanHash,
        [Parameter(Mandatory)][string]$CurrentManifestPath,[Parameter(Mandatory)][string]$CurrentManifestHash,
        [Parameter(Mandatory)][string]$CurrentPlanPath,[Parameter(Mandatory)][string]$CurrentPlanHash,
        [Parameter(Mandatory)][string]$OutputPath,[Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string[]]$OwnedItemIds)
    Initialize-WsmDeltaMerge
    $fullOutput=[IO.Path]::GetFullPath($OutputPath);$fullSummary=[IO.Path]::GetFullPath($SummaryPath)
    if($fullOutput -ieq $fullSummary -or [IO.File]::Exists($fullOutput) -or [IO.File]::Exists($fullSummary)){throw 'Delta output paths must be distinct new files; sealed evidence is never overwritten.'}
    Assert-WsmNoReparse $fullOutput;Assert-WsmNoReparse $fullSummary
    $base=Read-WsmDeltaInput $BaseManifestPath $BaseManifestHash $BasePlanPath $BasePlanHash
    $current=Read-WsmDeltaInput $CurrentManifestPath $CurrentManifestHash $CurrentPlanPath $CurrentPlanHash
    if($BasePlanHash -ine $CurrentPlanHash -or $base.Manifest.PairId -cne $current.Manifest.PairId -or $base.Manifest.BatchId -cne $current.Manifest.BatchId -or $base.Manifest.Source.HostId -cne $current.Manifest.Source.HostId -or $base.Manifest.Source.Fingerprint -cne $current.Manifest.Source.Fingerprint -or $base.Manifest.Target.HostId -cne $current.Manifest.Target.HostId -or $base.Manifest.Target.Fingerprint -cne $current.Manifest.Target.Fingerprint){throw 'Delta inputs are not from the same approved plan and host pair.'}
    if($current.Manifest.Generation -ne ($base.Manifest.Generation+1) -or -not $current.Manifest.Final -or $current.Manifest.BaseManifestHash -ine $BaseManifestHash -or $current.Manifest.FreezeHash -notmatch '^[a-f0-9]{64}$'){throw 'Current package is not a final generation directly based on the trusted base.'}
    $scope=@{};foreach($item in $current.Plan.Items){if($item.Decision -eq 'Include' -and $item.MigrationSpec.Adapter -eq 'FileScope'){$scope[[string]$item.ItemId]=$true}}
    $baseScope=@{};foreach($item in $base.Plan.Items){if($item.Decision -eq 'Include' -and $item.MigrationSpec.Adapter -eq 'FileScope'){$baseScope[[string]$item.ItemId]=$true}}
    $owned=@{};foreach($id in $OwnedItemIds){if($id -notmatch '^[a-f0-9]{64}$' -or -not $scope.ContainsKey($id) -or -not $baseScope.ContainsKey($id)){throw 'OwnedItemIds must be included FileScope items in both approved plans.'};if($owned.ContainsKey($id)){throw 'Duplicate owned FileScope ItemId.'};$owned[$id]=$true}
    $root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-delta-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root
    $baseSpool=Join-Path $root 'base';$currentSpool=Join-Path $root 'current';[void][IO.Directory]::CreateDirectory($baseSpool);[void][IO.Directory]::CreateDirectory($currentSpool)
    $baseState=[pscustomobject]@{Root=$baseSpool;Serial=0;Buffer=(New-Object 'System.Collections.Generic.List[string]');Runs=(New-Object 'System.Collections.Generic.List[string]');Known=(New-Object 'System.Collections.Generic.List[string]')}
    $currentState=[pscustomobject]@{Root=$currentSpool;Serial=0;Buffer=(New-Object 'System.Collections.Generic.List[string]');Runs=(New-Object 'System.Collections.Generic.List[string]');Known=(New-Object 'System.Collections.Generic.List[string]')}
    $outputTemp=$OutputPath+'.'+[Guid]::NewGuid().ToString('N')+'.partial';$summaryTemp=$SummaryPath+'.'+[Guid]::NewGuid().ToString('N')+'.partial'
    try {
        $baseRows=Read-WsmDeltaSortedIndex $base.IndexPath $base.Manifest.ArtifactsHash $base.Plan $baseState
        $currentRows=Read-WsmDeltaSortedIndex $current.IndexPath $current.Manifest.ArtifactsHash $current.Plan $currentState
        $directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath));if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory)}
        $writer=New-Object IO.StreamWriter($outputTemp,$false,(New-Object Text.UTF8Encoding($false)));$counts=@{Added=[long]0;Modified=[long]0;MetadataOnly=[long]0;Deleted=[long]0;Unchanged=[long]0}
        $br=$null;$cr=$null;$bl=$null;$cl=$null
        try {
            if($baseRows.Path){$br=New-Object IO.StreamReader($baseRows.Path,[Text.Encoding]::ASCII);$bl=$br.ReadLine()};if($currentRows.Path){$cr=New-Object IO.StreamReader($currentRows.Path,[Text.Encoding]::ASCII);$cl=$cr.ReadLine()}
            while($null -ne $bl -or $null -ne $cl){
                $b=$null;$c=$null
                if($null -eq $cl -or ($null -ne $bl -and [StringComparer]::Ordinal.Compare([WsmDeltaMerge]::Key($bl),[WsmDeltaMerge]::Key($cl)) -lt 0)){$b=Read-WsmDeltaSpoolRow $bl;$bl=$br.ReadLine()}
                elseif($null -eq $bl -or [StringComparer]::Ordinal.Compare([WsmDeltaMerge]::Key($cl),[WsmDeltaMerge]::Key($bl)) -lt 0){$c=Read-WsmDeltaSpoolRow $cl;$cl=$cr.ReadLine()}
                else{$b=Read-WsmDeltaSpoolRow $bl;$c=Read-WsmDeltaSpoolRow $cl;$bl=$br.ReadLine();$cl=$cr.ReadLine()}
                if($b -and $c){$bp=Get-WsmDeltaRecordParts $b.Row;$cp=Get-WsmDeltaRecordParts $c.Row;if($bp.Directory -ne $cp.Directory -or $bp.DataHash -cne $cp.DataHash){$type='Modified'}elseif($bp.MetadataHash -cne $cp.MetadataHash){$type='MetadataOnly'}else{$type='Unchanged'};$itemId=[string]$c.Row.ItemId;$relative=[string]$c.Row.RelativePath;$baseHash=$bp.RecordHash;$currentHash=$cp.RecordHash}
                elseif($c){$type='Added';$itemId=[string]$c.Row.ItemId;$relative=[string]$c.Row.RelativePath;$baseHash='';$currentHash=(Get-WsmDeltaRecordParts $c.Row).RecordHash}
                else{$type='Deleted';$itemId=[string]$b.Row.ItemId;$relative=[string]$b.Row.RelativePath;if(-not $owned.ContainsKey($itemId)){throw ('Deletion is outside explicitly owned FileScope: '+$itemId)};$baseHash=(Get-WsmDeltaRecordParts $b.Row).RecordHash;$currentHash=''}
                $counts[$type]++;$change=[pscustomobject][ordered]@{Change=$type;ItemId=$itemId;RelativePath=$relative;BaseRecordHash=$baseHash;CurrentRecordHash=$currentHash;RequiresOwnedBaseActual=($type -in @('Modified','MetadataOnly','Deleted'))}
                $writer.WriteLine((ConvertTo-Json -InputObject $change -Depth 8 -Compress))
            }
            $writer.Flush()
        } finally {if($br){$br.Dispose()};if($cr){$cr.Dispose()};$writer.Dispose()}
        $changeHash=Get-WsmDeltaFileHash $outputTemp;$changeCount=[long]0;foreach($value in $counts.Values){$changeCount+=$value}
        $summary=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='ArtifactDelta';PairId=$base.Manifest.PairId;BatchId=$base.Manifest.BatchId;Source=$base.Manifest.Source;Target=$base.Manifest.Target;PlanHash=$BasePlanHash.ToLowerInvariant();BaseManifestHash=$base.ManifestHash;BaseIndexHash=$base.Manifest.ArtifactsHash;BaseGeneration=[long]$base.Manifest.Generation;CurrentManifestHash=$current.ManifestHash;CurrentIndexHash=$current.Manifest.ArtifactsHash;CurrentGeneration=[long]$current.Manifest.Generation;FreezeHash=$current.Manifest.FreezeHash;OwnedItemIds=@($OwnedItemIds | Sort-Object -CaseSensitive);ChangesFile=[IO.Path]::GetFileName($OutputPath);ChangesHash=$changeHash;ChangeCount=$changeCount;Counts=[pscustomobject][ordered]@{Added=$counts.Added;Modified=$counts.Modified;MetadataOnly=$counts.MetadataOnly;Deleted=$counts.Deleted;Unchanged=$counts.Unchanged};CreatedUtc=(Get-WsmUtc)}
        $summaryDir=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SummaryPath));if(-not [IO.Directory]::Exists($summaryDir)){[void][IO.Directory]::CreateDirectory($summaryDir)}
        Write-WsmJson $summaryTemp $summary
        if([IO.File]::Exists($OutputPath) -or [IO.File]::Exists($SummaryPath)){throw 'Delta output paths must be new; sealed evidence is never overwritten.'}
        [IO.File]::Move($outputTemp,$OutputPath);[IO.File]::Move($summaryTemp,$SummaryPath)
        [pscustomobject]@{ChangesPath=[IO.Path]::GetFullPath($OutputPath);ChangesHash=$changeHash;SummaryPath=[IO.Path]::GetFullPath($SummaryPath);SummaryHash=(Get-WsmDeltaFileHash $SummaryPath);ChangeCount=$changeCount;Counts=$summary.Counts;PairId=$summary.PairId;PlanHash=$summary.PlanHash;BaseGeneration=$summary.BaseGeneration;CurrentGeneration=$summary.CurrentGeneration;Valid=$true}
    } finally {
        foreach($state in @($baseState,$currentState)){foreach($path in $state.Known){if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path)) -cne [IO.Path]::GetFullPath($state.Root)){throw 'Delta spool cleanup escaped its generated workspace.'};if([IO.File]::Exists($path)){[IO.File]::Delete($path)}};if([IO.Directory]::Exists($state.Root)){[IO.Directory]::Delete($state.Root,$false)}}
        if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$false)}
        foreach($temp in @($outputTemp,$summaryTemp)){if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
}
function Test-WsmArtifactDeltaManifest {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$SummaryPath,[Parameter(Mandatory)][string]$SummaryHash,[Parameter(Mandatory)][string]$ChangesPath,[Parameter(Mandatory)][string]$BaseManifestPath,[Parameter(Mandatory)][string]$BaseManifestHash,[Parameter(Mandatory)][string]$BasePlanPath,[Parameter(Mandatory)][string]$BasePlanHash,[Parameter(Mandatory)][string]$CurrentManifestPath,[Parameter(Mandatory)][string]$CurrentManifestHash,[Parameter(Mandatory)][string]$CurrentPlanPath,[Parameter(Mandatory)][string]$CurrentPlanHash)
    Assert-WsmNoReparse $SummaryPath;Assert-WsmNoReparse $ChangesPath
    $summary=Read-WsmTrustedJson $SummaryPath $SummaryHash;Assert-WsmEnvelope $summary 'ArtifactDelta';Assert-WsmFields $summary @('SchemaVersion','ToolVersion','Kind','PairId','BatchId','Source','Target','PlanHash','BaseManifestHash','BaseIndexHash','BaseGeneration','CurrentManifestHash','CurrentIndexHash','CurrentGeneration','FreezeHash','OwnedItemIds','ChangesFile','ChangesHash','ChangeCount','Counts','CreatedUtc') @('PairId','BatchId','Source','Target','PlanHash','BaseManifestHash','BaseIndexHash','BaseGeneration','CurrentManifestHash','CurrentIndexHash','CurrentGeneration','FreezeHash','OwnedItemIds','ChangesFile','ChangesHash','ChangeCount','Counts')
    $base=Read-WsmDeltaInput $BaseManifestPath $BaseManifestHash $BasePlanPath $BasePlanHash;$current=Read-WsmDeltaInput $CurrentManifestPath $CurrentManifestHash $CurrentPlanPath $CurrentPlanHash
    if($BasePlanHash -ine $CurrentPlanHash -or $summary.PlanHash -ine $BasePlanHash -or $summary.PairId -cne $base.Manifest.PairId -or $summary.PairId -cne $current.Manifest.PairId -or $summary.BatchId -cne $base.Manifest.BatchId -or $summary.BatchId -cne $current.Manifest.BatchId -or $summary.Source.HostId -cne $base.Manifest.Source.HostId -or $summary.Source.Fingerprint -cne $base.Manifest.Source.Fingerprint -or $summary.Target.HostId -cne $base.Manifest.Target.HostId -or $summary.Target.Fingerprint -cne $base.Manifest.Target.Fingerprint -or $summary.BaseManifestHash -ine $BaseManifestHash -or $summary.CurrentManifestHash -ine $CurrentManifestHash -or $summary.BaseIndexHash -ine $base.Manifest.ArtifactsHash -or $summary.CurrentIndexHash -ine $current.Manifest.ArtifactsHash -or $summary.BaseGeneration -ne $base.Manifest.Generation -or $summary.CurrentGeneration -ne $current.Manifest.Generation -or $current.Manifest.Generation -ne ($base.Manifest.Generation+1) -or -not $current.Manifest.Final -or $current.Manifest.BaseManifestHash -ine $BaseManifestHash -or $summary.FreezeHash -ine $current.Manifest.FreezeHash -or $summary.FreezeHash -notmatch '^[a-f0-9]{64}$'){throw 'Delta summary input binding mismatch.'}
    if((Get-WsmDeltaFileHash $ChangesPath) -ine $summary.ChangesHash -or [IO.Path]::GetFileName($ChangesPath) -cne $summary.ChangesFile){throw 'Delta changes hash/name mismatch.'}
    $owned=@{};$baseScopes=@{};$currentScopes=@{};foreach($item in $base.Plan.Items){if($item.Decision -eq 'Include' -and $item.MigrationSpec.Adapter -eq 'FileScope'){$baseScopes[[string]$item.ItemId]=$true}};foreach($item in $current.Plan.Items){if($item.Decision -eq 'Include' -and $item.MigrationSpec.Adapter -eq 'FileScope'){$currentScopes[[string]$item.ItemId]=$true}}
    foreach($id in $summary.OwnedItemIds){if($id -notmatch '^[a-f0-9]{64}$' -or $owned.ContainsKey([string]$id) -or -not $baseScopes.ContainsKey([string]$id) -or -not $currentScopes.ContainsKey([string]$id)){throw 'Delta summary has invalid target-owned FileScope bindings.'};$owned[[string]$id]=$true}
    $counts=@{Added=[long]0;Modified=[long]0;MetadataOnly=[long]0;Deleted=[long]0;Unchanged=[long]0};$previous=$null;$count=[long]0
    $stream=[IO.File]::Open([IO.Path]::GetFullPath($ChangesPath),'Open','Read','Read');$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
    try{Read-WsmBoundedLines $reader 1048576 | ForEach-Object {$row=ConvertFrom-WsmJson $_;Assert-WsmFields $row @('Change','ItemId','RelativePath','BaseRecordHash','CurrentRecordHash','RequiresOwnedBaseActual') @('Change','ItemId','RelativePath','BaseRecordHash','CurrentRecordHash','RequiresOwnedBaseActual');if(@('Added','Modified','MetadataOnly','Deleted','Unchanged') -cnotcontains $row.Change -or $row.ItemId -notmatch '^[a-f0-9]{64}$'){throw 'Invalid delta change row.'};Assert-WsmRelativePath $row.RelativePath -AllowRoot;$key=ConvertTo-WsmDeltaKeyHex $row.ItemId $row.RelativePath;if($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$key) -ge 0){throw 'Delta changes are not strictly sorted; duplicate or case-colliding key.'};$previous=$key;if($row.RequiresOwnedBaseActual -isnot [bool] -or $row.RequiresOwnedBaseActual -ne ($row.Change -in @('Modified','MetadataOnly','Deleted'))){throw 'Delta ownership precondition mismatch.'};if($row.Change -in @('Added','MetadataOnly','Modified') -and $row.CurrentRecordHash -notmatch '^[a-f0-9]{64}$'){throw 'Current record hash missing.'};if($row.Change -in @('Deleted','MetadataOnly','Modified') -and $row.BaseRecordHash -notmatch '^[a-f0-9]{64}$'){throw 'Base record hash missing.'};if($row.Change -eq 'Added' -and $row.BaseRecordHash -cne '' -or $row.Change -eq 'Deleted' -and $row.CurrentRecordHash -cne ''){throw 'Delta record hash direction mismatch.'};if($row.Change -eq 'Deleted' -and -not $owned.ContainsKey([string]$row.ItemId)){throw 'Delta deletion is outside summary-owned FileScope scope.'};$counts[[string]$row.Change]++;$count++}}
    finally{$reader.Dispose();$stream.Dispose()}
    foreach($name in $counts.Keys){if($summary.Counts.$name -ne $counts[$name]){throw 'Delta summary counts mismatch.'}};if($summary.ChangeCount -ne $count){throw 'Delta summary total count mismatch.'}
    [pscustomobject]@{Summary=$summary;ChangesPath=[IO.Path]::GetFullPath($ChangesPath);Valid=$true;ChangeCount=$count}
}
