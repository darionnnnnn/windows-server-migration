function Assert-WsmAssistiveSourceScope {
    param($Spec,[ValidateSet('SourceCOnly')][string]$Policy='SourceCOnly',[switch]$Native)
    if($Spec.Adapter -cne 'FileScope'){throw 'Source channel policy requires FileScope.'}
    $path=ConvertTo-WsmCanonicalPath ([string]$Spec.SourcePath)
    if($path.StartsWith('\\')){throw 'External storage requires a dedicated approved provider workflow.'}
    $physical='';$cPhysical=''
    $isC=$path.StartsWith('C:\',[StringComparison]::OrdinalIgnoreCase)
    if($Native){$physical=Get-WsmPhysicalPath $path;$cPhysical=Get-WsmPhysicalPath 'C:\';if($isC -and -not (Test-WsmPathOverlap $physical $cPhysical)){throw 'Source C path resolves outside the approved physical C volume.'}}
    $channel=if($isC){'C'}else{'NonC'}
    if(-not $Spec.PSObject.Properties['TransferChannel'] -or $Spec.TransferChannel -cne $channel){throw ('Reviewed channel does not match the source physical volume: '+$channel)}
    [pscustomobject]@{Channel=$channel;PhysicalPath=$physical;SourceCPhysicalRoot=$cPhysical;Policy=$Policy;NativeVerified=[bool]$Native}
}

function Test-WsmAssistivePackageScope($Plan,$Item) {
    if($Item.Decision -cne 'Include' -or $Item.MigrationSpec.Adapter -cne 'FileScope'){return $false}
    if(-not $Plan.PSObject.Properties['Assistive']){return $true}
    $proof=Assert-WsmAssistiveSourceScope $Item.MigrationSpec $Plan.Assistive.SourcePolicy
    return ($proof.Channel -ceq 'C')
}

function Assert-WsmAssistiveCollectionProofs($Manifest,$Plan) {
    if(-not $Plan.PSObject.Properties['Assistive']){if($Manifest.PSObject.Properties['SourceCollectionProofs']){throw 'Legacy package cannot claim assistive source proofs.'};return}
    if(-not $Manifest.PSObject.Properties['SourceCollectionProofs'] -or $Manifest.SourceCollectionProofs -isnot [array]){throw 'Assistive package requires native source collection proofs, including an empty array for zero-file plans.'}
    $scopes=@{};foreach($item in $Plan.Items){if($item.Decision -ceq 'Include' -and $item.MigrationSpec.Adapter -ceq 'FileScope'){$scopes[$item.ItemId]=$item}}
    $seen=@{}
    foreach($proof in $Manifest.SourceCollectionProofs){
        Assert-WsmFields $proof @('ItemId','Channel','PhysicalPath','SourceCPhysicalRoot','SourceFingerprint','NativeVerified') @('ItemId','Channel','PhysicalPath','SourceCPhysicalRoot','SourceFingerprint','NativeVerified')
        if(-not $scopes.ContainsKey($proof.ItemId) -or $seen.ContainsKey($proof.ItemId) -or $proof.NativeVerified -isnot [bool] -or -not $proof.NativeVerified -or $proof.SourceFingerprint -cne $Plan.Source.Fingerprint -or $proof.Channel -cne $scopes[$proof.ItemId].MigrationSpec.TransferChannel){throw 'Source collection proof has invalid item, channel or host binding.'}
        if(-not $proof.PhysicalPath.StartsWith('\Device\',[StringComparison]::OrdinalIgnoreCase) -or -not $proof.SourceCPhysicalRoot.StartsWith('\Device\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source physical volume evidence is absent.'}
        if($proof.Channel -ceq 'C' -and -not (Test-WsmPathOverlap $proof.PhysicalPath $proof.SourceCPhysicalRoot)){throw 'Main payload was collected outside the physical source C volume.'}
        $seen[$proof.ItemId]=$true
    }
    if($seen.Count -ne $scopes.Count){throw 'Source collection proof does not cover all reviewed local scopes.'}
}

function Assert-WsmAssistiveFileTopology([string]$Path) {
    Assert-WsmNoReparse $Path
    $attributes=[IO.File]::GetAttributes($Path)
    foreach($flag in @([IO.FileAttributes]::Encrypted,[IO.FileAttributes]::SparseFile,[IO.FileAttributes]::Compressed)){
        if(($attributes -band $flag) -ne 0){throw ('Special file metadata requires a dedicated qualified workflow: '+$flag)}
    }
    # File.Copy and the regular-file SHA256 used by the NonC channel do not
    # express whether named NTFS data streams were carried. Detect them before
    # accepting either a source or a current destination topology, and fail
    # closed if this host/provider cannot enumerate streams.
    try{$streams=@(Get-Item -LiteralPath $Path -Stream * -ErrorAction Stop)}catch{throw 'Alternate data stream topology could not be verified; preserve the path and review it manually.'}
    $namedStreams=@($streams | Where-Object {$_ -and $_.PSObject.Properties['Stream'] -and -not [string]::IsNullOrWhiteSpace([string]$_.Stream) -and [string]$_.Stream -ine ':$DATA'})
    if($namedStreams.Count){throw 'Alternate data streams require a dedicated qualified workflow; preserve the path and review it manually.'}
    if(-not ('WsmFileTopology' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class WsmFileTopology {
 [StructLayout(LayoutKind.Sequential)] struct Info {
  public uint Attributes,CreationLow,CreationHigh,AccessLow,AccessHigh,WriteLow,WriteHigh,Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr sec,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
 public static uint Links(string path) {
  using(var h=CreateFileW(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
   if(h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
   Info i;if(!GetFileInformationByHandle(h,out i)) throw new Win32Exception(Marshal.GetLastWin32Error());return i.Links;
  }
 }
}
'@
    }
    if(-not [IO.Directory]::Exists($Path) -and [WsmFileTopology]::Links($Path) -gt 1){throw 'Hard-linked files require a dedicated qualified topology workflow.'}
}

function Get-WsmExactConfigEntries {
    param($Spec,[string]$PackageRoot,$CancellationToken=$null)
    Assert-WsmConfigArtifactSpec $Spec
    $configs=@(Get-WsmConfigSpecEntries $Spec 'ConfigFiles')
    if(-not $configs.Count){throw 'ExactFiles requires a nonempty approved ConfigFiles whitelist.'}
    $root=ConvertTo-WsmCanonicalPath $Spec.SourcePath
    Assert-WsmNoReparse $root
    if(Test-WsmPathOverlap (Get-WsmPhysicalPath $root) (Get-WsmPhysicalPath $PackageRoot)){throw 'Scope overlaps package workspace.'}
    $directories=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $files=New-Object 'System.Collections.Generic.List[object]'
    foreach($config in $configs){
        Assert-WsmCancellationBoundary $CancellationToken 'ExactConfigFile'
        $relative=[string]$config.RelativePath
        Assert-WsmRelativePath $relative -AllowRoot
        $path=if($relative){Join-Path $root $relative}else{$root}
        Assert-WsmNoReparse $path
        Assert-WsmAssistiveFileTopology $path
        if($path.Length -gt 239){throw 'Exact configuration exceeds the verified path limit.'}
        if(-not [IO.File]::Exists($path)){throw ('Approved configuration file is absent: '+$relative)}
        foreach($excluded in @($Spec.ExcludedRelativePaths)){if($relative -ieq $excluded -or $relative.StartsWith(([string]$excluded).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'An exact configuration file is excluded by the reviewed scope.'}}
        if((Get-WsmCancellableFileHash $path $CancellationToken 'ExactConfigHash') -ine $config.SHA256){throw ('Approved configuration changed: '+$relative)}
        $files.Add([pscustomobject]@{SourcePath=$path;RelativePath=$relative;Directory=$false})
        if([IO.Directory]::Exists($root)){
            [void]$directories.Add('')
            $parent=[IO.Path]::GetDirectoryName($relative)
            while($parent){[void]$directories.Add($parent);$parent=[IO.Path]::GetDirectoryName($parent)}
        }
    }
    foreach($relative in @($directories | Sort-Object Length, {$_})){
        $path=if($relative){Join-Path $root $relative}else{$root}
        Assert-WsmNoReparse $path
        [pscustomobject]@{SourcePath=$path;RelativePath=$relative;Directory=$true}
    }
    $files.ToArray()
}

function Get-WsmFilePlacementPreview {
    [CmdletBinding()]param([string]$ManifestPath,[string]$ExpectedHash,[string]$StateDirectory)
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash
    $plan=$package.Plan
    Assert-WsmMigrationHost (Get-WsmMachineIdentity) $plan.Target.Fingerprint
    $ownership=@{}
    if($StateDirectory){
        $statePath=Join-Path (Join-Path $StateDirectory $plan.PairId) 'state.json'
        if([IO.File]::Exists($statePath)){
            Assert-WsmNoReparse $statePath;$state=Read-WsmJson $statePath;$journal=Test-WsmJournal $StateDirectory $plan.PairId
            if(-not $journal.Consistent -or $state.PlanHash -ine $package.Manifest.PlanHash -or $state.TargetFingerprint -cne $plan.Target.Fingerprint){throw 'File placement ownership requires consistent target journal and sealed plan binding.'}
            foreach($itemState in $state.Items){if($itemState.PSObject.Properties['OwnedFiles']){foreach($file in $itemState.OwnedFiles){$ownership[$itemState.ItemId+'|'+$file.RelativePath]=$file}}}
        }
    }
    $byId=@{};foreach($item in $plan.Items){$byId[$item.ItemId]=$item}
    $artifactPath=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ManifestPath))) 'artifacts.jsonl'
    $rows=@(Read-WsmArtifactLines $artifactPath $package.Manifest.ArtifactsHash | ForEach-Object {
        $row=$_;$item=$byId[$row.ItemId]
        if($item.MigrationSpec.Adapter -ceq 'FileScope'){
            $spec=$item.MigrationSpec;$relative=[string]$row.RelativePath
            $source=if($relative){Join-Path $spec.SourcePath $relative}else{$spec.SourcePath}
            $destination=if($relative){Join-Path $spec.TargetPath $relative}else{$spec.TargetPath}
            $status='CanPlace';$reason='No destination object observed; restore rechecks before writing.';$observed=''
            try{
                Assert-WsmNoReparse $destination
                if([IO.File]::Exists($destination) -or [IO.Directory]::Exists($destination)){
                    $topologyVerified=$true
                    try{Assert-WsmAssistiveFileTopology $destination}catch{$topologyVerified=$false}
                    if(-not $topologyVerified){$status='BlockedConflict';$reason='Destination has special file topology such as alternate data streams; preserve it for manual review.'}
                    else{
                        $status='BlockedConflict';$reason='Destination exists; external data is not merged or overwritten.'
                        if($row.Directory -and [IO.Directory]::Exists($destination)){$status='DirectoryAlreadyExists';$reason='Existing directory is retained. New nonconflicting files may be placed individually; no directory ownership is claimed.'}
                        if(-not $row.Directory -and [IO.File]::Exists($destination)){$observed=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant();if($observed -ieq $row.Data.Hash){$reason='Same bytes already exist; this does not grant tool ownership.'}}
                    }
                    $key=$item.ItemId+'|'+$relative
                    if($topologyVerified -and -not $row.Directory -and $ownership.ContainsKey($key)){
                        if($observed -ieq $ownership[$key].SHA256){$status='VerifiedOwned';$reason='Current bytes match journal ownership. Restore must preserve a verified backup before changing them.'}
                        else{$status='OwnedFileDrift';$reason='Journal-owned file changed outside its recorded generation; preserve and reconcile it.'}
                    }
                }
            }catch{$status='UnknownPermission';$reason='Destination access or physical path could not be verified.'}
            $originalStatus='NotObserved';$originalHash=''
            try{Assert-WsmNoReparse $source;if($row.Directory){$originalStatus=if([IO.Directory]::Exists($source)){'DirectoryObserved'}else{'Missing'}}elseif([IO.File]::Exists($source)){$originalHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();$originalStatus=if($originalHash -ieq $row.Data.Hash){'SourceBytesObserved'}else{'DifferentBytesConflict'}}else{$originalStatus='Missing'}}catch{$originalStatus='UnknownPermission'}
            $changed=($source -ine $destination)
            [pscustomobject]@{ItemId=$item.ItemId;RelativePath=$relative;SourcePath=$source;PreservedPath=$destination;EffectivePath='';EffectivePathStatus='NotObserved';OriginalPathStatus=$originalStatus;OriginalPathHash=$originalHash;OriginalPathChangedByApprovedMapping=$changed;OriginalPathChangeReason=$(if($changed){$spec.Evidence}else{''});PlacementStatus=$status;Reason=$reason;ObservedHash=$observed;SourceHash=$(if($row.Data){$row.Data.Hash}else{''});Directory=$row.Directory}
        }
    })
    [pscustomobject]@{Kind='FilePlacementPreview';PairId=$plan.PairId;ManifestHash=$ExpectedHash;Rows=$rows;Total=$rows.Count;Blocked=@($rows|Where-Object PlacementStatus -in @('BlockedConflict','OwnedFileDrift','UnknownPermission')).Count;ReadOnly=$true;ProductionVerified=$false}
}
