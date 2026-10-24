function Get-WsmAssistiveApprovedVolumeForScope($Spec,$ApprovedVolumes) {
    $source=ConvertTo-WsmCanonicalPath ([string]$Spec.SourcePath)
    $target=ConvertTo-WsmCanonicalPath ([string]$Spec.TargetPath)
    if($source -ine $target){throw 'OfflineFullSet requires the approved original logical source and target paths to be identical.'}
    $matches=@($ApprovedVolumes | Where-Object { (ConvertTo-WsmCanonicalPath ([string]$_.SourcePath)) -ieq $source })
    if($matches.Count -lt 1){throw 'OfflineFullSet scope is not bound to an approved local volume.'}
    $volume=$matches[0]
    Assert-WsmFields $volume @('ItemId','SourcePath','DeviceID','DriveLetter') @('ItemId','SourcePath','DeviceID','DriveLetter')
    if([string]$volume.DeviceID -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$' -or [string]$volume.DriveLetter -notmatch '^[A-Za-z]:$'){throw 'OfflineFullSet approved volume identity is malformed.'}
    foreach($match in @($matches | Select-Object -Skip 1)){
        Assert-WsmFields $match @('ItemId','SourcePath','DeviceID','DriveLetter') @('ItemId','SourcePath','DeviceID','DriveLetter')
        if((ConvertTo-WsmCanonicalPath ([string]$match.SourcePath)) -ine $source -or [string]$match.DeviceID -ine [string]$volume.DeviceID -or [string]$match.DriveLetter -ine [string]$volume.DriveLetter){throw 'OfflineFullSet matching source-root bindings disagree on the approved local volume.'}
    }
    $volume
}

function New-WsmAssistiveApprovedLocalVolumeBindings($ScopeItems,$SourceInventory) {
    Assert-WsmInventory $SourceInventory
    $volumeItems=@($SourceInventory.Items | Where-Object {$_.Category -ceq 'Storage' -and $_.Kind -ceq 'Volume'})
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in @($ScopeItems)){
        $spec=$item.MigrationSpec;$source=ConvertTo-WsmCanonicalPath ([string]$spec.SourcePath);$target=ConvertTo-WsmCanonicalPath ([string]$spec.TargetPath)
        if($source -ine $target){throw 'OfflineFullSet requires the approved original logical source and target paths to be identical.'}
        if($source -notmatch '^([A-Za-z]):\\'){throw 'OfflineFullSet only accepts local drive-rooted scopes.'};$drive=$matches[1]+':'
        $snapshot=@($volumeItems | Where-Object {([string]$_.Settings.DriveLetter).TrimEnd('\') -ieq $drive})
        if($snapshot.Count -ne 1){throw 'Trusted source inventory does not identify exactly one volume for the approved FileScope.'}
        $device=[string]$snapshot[0].Settings.DeviceID;if($device -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\$'){throw 'Trusted source volume DeviceID is not a canonical volume GUID.'}
        if(@($volumeItems | Where-Object {[string]$_.Settings.DeviceID -ieq $device}).Count -ne 1){throw 'Trusted source inventory names the same volume (DeviceID) under more than one volume entry or drive letter.'}
        $rows.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;SourcePath=$source;DeviceID=$device;DriveLetter=$drive})
    }
    $rows.ToArray()
}
# N5（15.3-10）：核准的本機卷綁定必須是「一個卷一個磁碟代號」。同一個 DeviceID 用兩個代號、或同一個代號對應兩個 DeviceID，
# 都表示同一個卷被當成兩個卷（或兩個卷被混成一個）處理，C／非 C 通道分類與封裝成員歸屬都會失真，核准與讀取時一律拒絕。
function Assert-WsmAssistiveVolumeBindingsUnique($Bindings) {
    $byDevice=@{};$byLetter=@{}
    foreach($binding in @($Bindings)){
        if($null -eq $binding){continue}
        $device=([string]$binding.DeviceID).ToLowerInvariant();$letter=([string]$binding.DriveLetter).TrimEnd('\').ToUpperInvariant()
        if($byDevice.ContainsKey($device) -and $byDevice[$device] -cne $letter){throw 'OfflineFullSet approved volume bindings name one volume under more than one drive letter.'}
        if($byLetter.ContainsKey($letter) -and $byLetter[$letter] -cne $device){throw 'OfflineFullSet approved volume bindings name one drive letter under more than one volume.'}
        $byDevice[$device]=$letter;$byLetter[$letter]=$device
    }
}
function Assert-WsmAssistiveSourceScope {
    param($Spec,[ValidateSet('SourceCOnly','ApprovedLocalVolumes')][string]$Policy='SourceCOnly',[switch]$Native,$ApprovedVolumes=@())
    if($Spec.Adapter -cne 'FileScope'){throw 'Source channel policy requires FileScope.'}
    $path=ConvertTo-WsmCanonicalPath ([string]$Spec.SourcePath)
    if($path.StartsWith('\\')){throw 'External storage requires a dedicated approved provider workflow.'}
    $physical='';$cPhysical=''
    if($Policy -ceq 'ApprovedLocalVolumes'){
        $volume=Get-WsmAssistiveApprovedVolumeForScope $Spec $ApprovedVolumes
        $channel=if([string]$volume.DriveLetter -ieq 'C:'){'C'}else{'NonC'}
        if(-not $Spec.PSObject.Properties['TransferChannel'] -or [string]$Spec.TransferChannel -cne $channel){throw ('Reviewed channel does not match the approved source volume: '+$channel)}
        if($Native){
            $physical=Get-WsmPhysicalPath $path
            $root=Get-WsmPhysicalPath ([string]$volume.DriveLetter+'\')
            if(-not (Test-WsmPathOverlap $physical $root)){throw 'OfflineFullSet source path no longer resolves beneath its approved physical source volume.'}
            $current=@(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop | Where-Object {([string]$_.DriveLetter).TrimEnd('\') -ieq [string]$volume.DriveLetter})
            if($current.Count -ne 1 -or [string]$current[0].DeviceID -ine [string]$volume.DeviceID){throw 'OfflineFullSet native volume DeviceID changed since approval.'}
        }
        $physicalRoot=if($Native){$root.TrimEnd('\')}else{''}
        return [pscustomobject]@{Channel='FullSet';PhysicalPath=$physical;SourceCPhysicalRoot=$physicalRoot;VolumeDeviceID=[string]$volume.DeviceID;PhysicalVolumeRoot=$physicalRoot;Policy=$Policy;NativeVerified=[bool]$Native}
    }
    $isC=$path.StartsWith('C:\',[StringComparison]::OrdinalIgnoreCase)
    if($Native){$physical=Get-WsmPhysicalPath $path;$cPhysical=Get-WsmPhysicalPath 'C:\';if($isC -ne [bool](Test-WsmPathOverlap $physical $cPhysical)){throw 'Source drive alias disagrees with its physical C-volume classification; review the original native drive path before packaging or transfer.'}}
    $channel=if($isC){'C'}else{'NonC'}
    if(-not $Spec.PSObject.Properties['TransferChannel'] -or $Spec.TransferChannel -cne $channel){throw ('Reviewed channel does not match the source physical volume: '+$channel)}
    [pscustomobject]@{Channel=$channel;PhysicalPath=$physical;SourceCPhysicalRoot=$cPhysical;Policy=$Policy;NativeVerified=[bool]$Native}
}

function Test-WsmAssistivePackageScope($Plan,$Item) {
    if($Item.Decision -cne 'Include' -or $Item.MigrationSpec.Adapter -cne 'FileScope'){return $false}
    if(-not $Plan.PSObject.Properties['Assistive']){return $true}
    if($Plan.Assistive.ContractVersion -eq 2){return $true}
    $proof=Assert-WsmAssistiveSourceScope $Item.MigrationSpec $Plan.Assistive.SourcePolicy
    return ($proof.Channel -ceq 'C')
}

function Assert-WsmAssistiveCollectionProofs($Manifest,$Plan) {
    if(-not $Plan.PSObject.Properties['Assistive']){if($Manifest.PSObject.Properties['SourceCollectionProofs']){throw 'Legacy package cannot claim assistive source proofs.'};return}
    if(-not $Manifest.PSObject.Properties['SourceCollectionProofs'] -or $Manifest.SourceCollectionProofs -isnot [array]){throw 'Assistive package requires native source collection proofs, including an empty array for zero-file plans.'}
    $scopes=@{};foreach($item in $Plan.Items){if($item.Decision -ceq 'Include' -and $item.MigrationSpec.Adapter -ceq 'FileScope'){$scopes[$item.ItemId]=$item}}
    if($Plan.Assistive.ContractVersion -eq 2){Assert-WsmAssistiveVolumeBindingsUnique @($Plan.Assistive.ApprovedLocalVolumes)}
    $seen=@{}
    foreach($proof in $Manifest.SourceCollectionProofs){
        if($Plan.Assistive.ContractVersion -eq 2){Assert-WsmFields $proof @('ItemId','Channel','PhysicalPath','SourceCPhysicalRoot','SourceFingerprint','NativeVerified','VolumeDeviceID','PhysicalVolumeRoot') @('ItemId','Channel','PhysicalPath','SourceCPhysicalRoot','SourceFingerprint','NativeVerified','VolumeDeviceID','PhysicalVolumeRoot')}
        else{Assert-WsmFields $proof @('ItemId','Channel','PhysicalPath','SourceCPhysicalRoot','SourceFingerprint','NativeVerified') @('ItemId','Channel','PhysicalPath','SourceCPhysicalRoot','SourceFingerprint','NativeVerified')}
        if(-not $scopes.ContainsKey($proof.ItemId) -or $seen.ContainsKey($proof.ItemId) -or $proof.NativeVerified -isnot [bool] -or -not $proof.NativeVerified -or $proof.SourceFingerprint -cne $Plan.Source.Fingerprint){throw 'Source collection proof has invalid item, channel or host binding.'}
        if(-not $proof.PhysicalPath.StartsWith('\Device\',[StringComparison]::OrdinalIgnoreCase) -or -not $proof.SourceCPhysicalRoot.StartsWith('\Device\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source physical volume evidence is absent.'}
        if($Plan.Assistive.ContractVersion -eq 2){$approved=Get-WsmAssistiveApprovedVolumeForScope $scopes[$proof.ItemId].MigrationSpec $Plan.Assistive.ApprovedLocalVolumes;if($proof.Channel -cne 'FullSet' -or $proof.VolumeDeviceID -ine $approved.DeviceID -or [string]$proof.PhysicalVolumeRoot -notmatch '^\\Device\\HarddiskVolume[^\\]+$' -or -not (Test-WsmPathOverlap $proof.PhysicalPath $proof.PhysicalVolumeRoot)){throw 'OfflineFullSet collection proof does not match the approved local source volume.'}}
        else{if($proof.Channel -cne $scopes[$proof.ItemId].MigrationSpec.TransferChannel){throw 'Source collection proof channel does not match approved scope.'};if($proof.Channel -ceq 'C' -and -not (Test-WsmPathOverlap $proof.PhysicalPath $proof.SourceCPhysicalRoot)){throw 'Main payload was collected outside the physical source C volume.'};if($proof.Channel -ceq 'NonC' -and (Test-WsmPathOverlap $proof.PhysicalPath $proof.SourceCPhysicalRoot)){throw 'NonC source collection proof resolves onto the physical source C volume.'}}
        $seen[$proof.ItemId]=$true
    }
    if($seen.Count -ne $scopes.Count){throw 'Source collection proof does not cover all reviewed local scopes.'}
}
function Assert-WsmAssistiveFileTopology {
    param([Parameter(Mandatory)][string]$Path,[switch]$ExactConfig,[switch]$MetadataOnly,[string]$SourceRoot='', [string]$RelativePath='',[string]$TrustedPeerRoot='',[string]$TrustedPeerPhysicalRoot='',[string]$TrustedPeerPhysicalPath='')
    $trustedPeer=([bool]$TrustedPeerRoot -or [bool]$TrustedPeerPhysicalRoot -or [bool]$TrustedPeerPhysicalPath)
    if($trustedPeer){
        if(-not $TrustedPeerRoot -or -not $TrustedPeerPhysicalRoot -or -not $TrustedPeerPhysicalPath -or $TrustedPeerRoot -notmatch '^\\\\[^\\]+\\[^\\]+(?:\\|$)'){throw 'Trusted peer topology requires the exact reviewed UNC root, physical root and resolved physical path.'}
        $uncRoot=$TrustedPeerRoot.TrimEnd('\');$uncPath=[IO.Path]::GetFullPath($Path)
        if($uncPath -ine $uncRoot -and -not $uncPath.StartsWith($uncRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'UNC topology path is outside the exact reviewed peer share root.'}
        $peerRelative=if($uncPath.Length -gt $uncRoot.Length){$uncPath.Substring($uncRoot.Length).TrimStart('\')}else{''}
        $physicalRoot=$TrustedPeerPhysicalRoot.TrimEnd('\');$expectedPhysical=if($peerRelative){$physicalRoot+'\'+$peerRelative}else{$physicalRoot}
        if([IO.Path]::GetFullPath($TrustedPeerPhysicalPath).TrimEnd('\') -ine [IO.Path]::GetFullPath($expectedPhysical).TrimEnd('\')){throw 'Resolved peer physical path does not preserve the exact reviewed share-relative mapping.'}
        if($physicalRoot -notmatch '^\\Device\\HarddiskVolume[^\\]+(?:\\|$)' -and $physicalRoot -notmatch '^[A-Za-z]:\\'){throw 'Reviewed peer physical root is not a canonical local volume path.'}
        if($ExactConfig){Assert-WsmFileScopeGuard -Path $Path -Mode ExactConfig -SourceRoot $SourceRoot -RelativePath $RelativePath -IsDirectory:([IO.Directory]::Exists($Path)) -MetadataOnly:$MetadataOnly;Assert-WsmFileScopeGuard -Path $TrustedPeerPhysicalPath -Mode ExactConfig -SourceRoot $TrustedPeerPhysicalRoot -RelativePath $RelativePath -IsDirectory:([IO.Directory]::Exists($Path)) -MetadataOnly:$MetadataOnly -PathOnly}
        else{Assert-WsmFileScopeGuard -Path $Path -Mode Collected -IsDirectory:([IO.Directory]::Exists($Path)) -MetadataOnly:$MetadataOnly;Assert-WsmFileScopeGuard -Path $TrustedPeerPhysicalPath -Mode Root}
    }elseif($ExactConfig){Assert-WsmFileScopeGuard -Path $Path -Mode ExactConfig -SourceRoot $SourceRoot -RelativePath $RelativePath -IsDirectory:([IO.Directory]::Exists($Path)) -MetadataOnly:$MetadataOnly -CheckPhysicalAlias}
    else{Assert-WsmFileScopeGuard -Path $Path -Mode Collected -IsDirectory:([IO.Directory]::Exists($Path)) -MetadataOnly:$MetadataOnly -CheckPhysicalAlias}
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

function Get-WsmExactMemberEntries {
    param($Spec,[string]$PackageRoot,$CancellationToken=$null)
    if(-not $Spec -or -not $Spec.PSObject.Properties['Members'] -or $Spec.Members -isnot [array] -or -not $Spec.Members.Count){throw 'ExactMembers requires a nonempty approved member set.'}
    if($Spec.PSObject.Properties['ExcludedRelativePaths'] -and @($Spec.ExcludedRelativePaths).Count){throw 'ExactMembers cannot combine Members with ExcludedRelativePaths; remove excluded files from the reviewed Members set.'}
    $members=@($Spec.Members)
    $root=ConvertTo-WsmCanonicalPath ([string]$Spec.SourcePath);Assert-WsmFileScopeGuard -Path $root -Mode Root -AllowDriveRoot
    $physicalRoot=Get-WsmPhysicalPath $root;Assert-WsmFileScopeGuard -Path $physicalRoot -Mode Root -AllowDriveRoot;$packageFull=[IO.Path]::GetFullPath($PackageRoot);$seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($member in $members){
        Assert-WsmCancellationBoundary $CancellationToken 'ExactMemberFile'
        Assert-WsmFields $member @('RelativePath','SHA256','EntryType') @('RelativePath','SHA256');$isDirectoryMember=Test-WsmExactDirectoryMember $member;if($member.PSObject.Properties['EntryType'] -and -not $isDirectoryMember){throw 'ExactMembers member EntryType is unsupported.'};$relative=[string]$member.RelativePath;Assert-WsmRelativePath $relative
        if($relative -cne $relative.Replace('/','\') -or $relative.Trim() -cne $relative -or -not $seen.Add($relative)){throw 'ExactMembers contains a noncanonical or duplicate member path.'}
        if($isDirectoryMember){if([string]$member.SHA256 -cne ''){throw 'ExactMembers directory member carries no content hash.'}}elseif([string]$member.SHA256 -cnotmatch '^[a-f0-9]{64}$'){throw 'ExactMembers member has no canonical SHA256 baseline.'}
        $path=[IO.Path]::GetFullPath((Join-Path $root $relative));if($path.Length -gt 239){throw 'Exact member exceeds the verified path limit.'}
        if($isDirectoryMember){
            # Same path, reparse, physical-alias and package-overlap checks as file members, then require a still-empty real directory.
            Assert-WsmNoReparse $path;Assert-WsmFileScopeGuard -Path $path -Mode ExactMembers -SourceRoot $root -RelativePath $relative -IsDirectory -PathOnly -CheckPhysicalAlias
            Assert-WsmAssistiveFileTopology -Path $path
            if(-not [IO.Directory]::Exists($path)){throw ('Approved exact directory member is absent: '+$relative)}
            $physical=Get-WsmPhysicalPath $path;if($physical -ine $physicalRoot -and -not $physical.StartsWith($physicalRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Exact member resolves outside the reviewed physical source root.'}
            if(Test-WsmPathOverlap $physical (Get-WsmPhysicalPath $packageFull)){throw 'Exact member overlaps package workspace.'}
            if(@([IO.Directory]::EnumerateFileSystemEntries($path)|Select-Object -First 1).Count){throw ('Approved exact directory member is no longer empty: '+$relative)}
            [pscustomobject]@{SourcePath=$path;RelativePath=$relative;Directory=$true}
            continue
        }
        Assert-WsmNoReparse $path;Assert-WsmFileScopeGuard -Path $path -Mode ExactMembers -SourceRoot $root -RelativePath $relative -CheckPhysicalAlias
        Assert-WsmAssistiveFileTopology -Path $path
        if(-not [IO.File]::Exists($path)){throw ('Approved exact member is absent: '+$relative)}
        $physical=Get-WsmPhysicalPath $path;if($physical -ine $physicalRoot -and -not $physical.StartsWith($physicalRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Exact member resolves outside the reviewed physical source root.'}
        if(Test-WsmPathOverlap $physical (Get-WsmPhysicalPath $packageFull)){throw 'Exact member overlaps package workspace.'}
        if((Get-WsmCancellableFileHash $path $CancellationToken 'ExactMemberHash') -cne [string]$member.SHA256){throw ('Approved exact member bytes changed: '+$relative)}
        [pscustomobject]@{SourcePath=$path;RelativePath=$relative;Directory=$false}
    }
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
        Assert-WsmAssistiveFileTopology -Path $path -ExactConfig -SourceRoot $root -RelativePath $relative
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
                # Validate the reviewed target root even when this artifact is
                # absent. Restore performs this same check before creating it.
                Assert-WsmAssistiveTargetScopeTopology -Path $spec.TargetPath -Spec $spec -TargetRoot $spec.TargetPath -Kind Root
                Assert-WsmNoReparse $destination
                if([IO.File]::Exists($destination) -or [IO.Directory]::Exists($destination)){
                    $topologyVerified=$true
                    $key=$item.ItemId+'|'+$relative
                    try{
                        if($spec.PSObject.Properties['ContentSelection'] -and [string]$spec.ContentSelection -cin @('ExactFiles','ExactMembers')){
                            if($row.Directory -and [string]::IsNullOrEmpty($relative)){
                                Assert-WsmAssistiveTargetScopeTopology -Path $destination -Spec $spec -TargetRoot $spec.TargetPath -Kind Root
                            }else{
                                $kind=if($row.Directory){'Directory'}else{'File'}
                                $ownedHash=if($ownership.ContainsKey($key)){[string]$ownership[$key].SHA256}else{''}
                                Assert-WsmAssistiveTargetScopeTopology -Path $destination -Spec $spec -TargetRoot $spec.TargetPath -Artifact $row -Kind $kind -Destination $destination -TrustedExistingHash $ownedHash
                            }
                        }else{Assert-WsmAssistiveFileTopology $destination}
                    }catch{$topologyVerified=$false}
                    if(-not $topologyVerified){$status='BlockedConflict';$reason='Destination has special file topology such as alternate data streams; preserve it for manual review.'}
                    else{
                        $status='BlockedConflict';$reason='Destination exists; external data is not merged or overwritten.'
                        if($row.Directory -and [IO.Directory]::Exists($destination)){$status='DirectoryAlreadyExists';$reason='Existing directory is retained. New nonconflicting files may be placed individually; no directory ownership is claimed.'}
                        if(-not $row.Directory -and [IO.File]::Exists($destination)){$observed=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant();if($observed -ieq $row.Data.Hash){$reason='Same bytes already exist; this does not grant tool ownership.'}}
                    }
                    if($topologyVerified -and -not $row.Directory -and $ownership.ContainsKey($key)){
                        if(Test-WsmAssistiveOwnedFileAdopted $ownership[$key]){
                            if($observed -ieq $ownership[$key].SHA256){$status='AdoptedExisting';$reason=(Get-WsmAssistiveAdoptedExistingNote)}
                            else{$status='OwnedFileDrift';$reason='Adopted existing file changed after it was adopted; it is only reported and is never overwritten or removed.'}
                        }
                        elseif($observed -ieq $ownership[$key].SHA256){$status='VerifiedOwned';$reason='Current bytes match journal ownership. Restore must preserve a verified backup before changing them.'}
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

function Assert-WsmOfflineFullSetOriginalLocation($Plan,$Spec) {
    if(-not ($Plan.PSObject.Properties['Assistive'] -and $Plan.Assistive -and $Plan.Assistive.PSObject.Properties['ContractVersion'] -and [int]$Plan.Assistive.ContractVersion -eq 2 -and [string]$Spec.Adapter -ceq 'FileScope')){return}
    $source=ConvertTo-WsmCanonicalPath ([string]$Spec.SourcePath)
    $target=ConvertTo-WsmCanonicalPath ([string]$Spec.TargetPath)
    if($source -ine $target){throw 'OfflineFullSet restore requires the approved original location; the target path differs from the captured source path.'}
    if($target -notmatch '^[A-Za-z]:\\'){throw 'OfflineFullSet restore requires a drive-rooted original location.'}
}
