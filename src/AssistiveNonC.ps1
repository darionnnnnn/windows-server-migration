function Get-WsmAssistiveNonCHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-WsmAssistiveNonCExpansionHash($Entries) {
    $fields=@('ItemId','EntryId','EntryType','RelativePath','SourcePath','OriginalSourcePath','SourcePeerFingerprint','SourcePeerProofHash','SourceSHA256','Bytes','TargetPath','TargetPhysicalIdentity')
    $rows=@(foreach($entry in @($Entries|Sort-Object EntryId)){$row=[ordered]@{};foreach($field in $fields){$row[$field]=$entry.$field};$row})
    Get-WsmHashText (ConvertTo-Json -InputObject $rows -Depth 12 -Compress)
}

function Resolve-WsmAssistiveTargetStateDirectory([string]$AccessPath,$SealedPlan,$TargetPhysicalProof) {
    $access=[IO.Path]::GetFullPath($AccessPath);if(-not [IO.Directory]::Exists($access)){throw 'Target state directory must be an existing directory.'}
    $peer=$null;$native=''
    if($access.StartsWith('\\')){
        $endpoint=[regex]::Match($access,'^\\([^\\]+)\\([^\\]+)(?:\\|$)');if(-not $endpoint.Success){throw 'Target state directory must be within an exact reviewed SMB share.'}
        $matches=@($TargetPhysicalProof.PeerShareProofs|Where-Object {$_.PeerName -ieq $endpoint.Groups[1].Value -and $_.ShareName -ieq $endpoint.Groups[2].Value -and $_.PeerHostId -ceq $SealedPlan.Target.HostId -and $_.PeerFingerprint -ceq $SealedPlan.Target.Fingerprint})
        if($matches.Count -ne 1){throw 'Target state directory requires one exact trusted target peer-share proof.'};$peer=$matches[0];$native=Resolve-WsmAssistivePeerPhysicalPath $access $peer
    }else{
        if((Get-WsmAssistiveMachineFingerprint) -ine $SealedPlan.Target.Fingerprint){throw 'A native target state directory can only be proven on the sealed Target host; use an approved target peer-share UNC from the jump host.'}
        Assert-WsmNoReparse $access;$native=Get-WsmPhysicalPath $access
    }
    if($native -match '(^|\\)\.{1,2}(?:\\|$)'){throw 'Target state directory physical path contains traversal segments.'}
    $native=$native.TrimEnd('\');if(-not $native){throw 'Target state directory physical path is invalid.'}
    $identity=[string]$SealedPlan.Target.Fingerprint.ToLowerInvariant()+'|'+$native.ToLowerInvariant()
    $peerHash='';if($peer){$peerHash=[string]$peer.ProofHash}
    $proofHash=Get-WsmHashText ($identity+'|'+$access.ToLowerInvariant()+'|'+$peerHash.ToLowerInvariant())
    [pscustomobject][ordered]@{TargetStateDirectory=$native;TargetStateDirectoryIdentity=$identity;TargetStateDirectoryAccessPath=$access;TargetStateDirectoryPeerProofHash=$peerHash;TargetStateDirectoryProofHash=$proofHash;PeerProof=$peer}
}

function Assert-WsmAssistiveHash([string]$Hash,[string]$Name) {
    if ([string]$Hash -notmatch '^[a-fA-F0-9]{64}$') { throw (New-WsmContractError ($Name+' must be a SHA256.')) }
}

function Assert-WsmAssistiveFreezeProof($Proof,[string]$EpochId) {
    if ($null -eq $Proof -or $Proof.Kind -cne 'AssistiveFreezeProof' -or $Proof.FreezeEpoch -cne $EpochId -or -not $Proof.FreezeId -or -not $Proof.EvidenceId -or -not $Proof.PairId -or -not $Proof.PlanHash -or -not $Proof.WriterSetHash -or -not $Proof.Owner) { throw (New-WsmContractError 'NonC transfer requires a typed proof derived from the verified SourceFreeze record and writer-fence attestation.') }
    Assert-WsmId ([string]$Proof.FreezeId);Assert-WsmId ([string]$Proof.EvidenceId);Assert-WsmId ([string]$Proof.PairId);Assert-WsmAssistiveHash ([string]$Proof.PlanHash) 'Freeze plan hash';Assert-WsmAssistiveHash ([string]$Proof.FreezeRecordHash) 'SourceFreeze record hash';Assert-WsmAssistiveHash ([string]$Proof.EvidenceHash) 'Source writer-fence evidence hash';Assert-WsmAssistiveHash ([string]$Proof.WriterSetHash) 'Writer-set hash';Assert-WsmAssistiveHash ([string]$Proof.SourceInventoryHash) 'Freeze source inventory hash'
    $body=[ordered]@{};foreach($p in $Proof.PSObject.Properties){if($p.Name -cne 'ProofHash'){$body[$p.Name]=$p.Value}}
    Assert-WsmAssistiveHash ([string]$Proof.ProofHash) 'Freeze proof hash'
    if ((Get-WsmHashText ($body | ConvertTo-Json -Depth 20 -Compress)) -ine $Proof.ProofHash) { throw (New-WsmContractError 'Freeze proof hash mismatch.') }
    $true
}

function Assert-WsmAssistiveTargetPhysicalProof($Proof,[string]$TargetPhysicalId,[string[]]$ExpectedIdentities) {
    if($null -eq $Proof -or $Proof.Kind -cne 'AssistiveTargetPhysicalProof' -or $Proof.TargetPhysicalId -cne $TargetPhysicalId -or $Proof.Verified -isnot [bool] -or -not $Proof.Verified -or -not $Proof.TargetHostId -or -not $Proof.ObserverMachineFingerprint -or -not $Proof.ObservedUtc -or $Proof.PhysicalIdentities -isnot [array]){throw (New-WsmContractError 'A verified target-host physical path proof is required.')}
    Assert-WsmId ([string]$Proof.TargetHostId);Assert-WsmAssistiveHash ([string]$Proof.ProofHash) 'Target physical proof hash'
    $expected=@($ExpectedIdentities|Sort-Object -Unique);$actual=@($Proof.PhysicalIdentities|Sort-Object -Unique)
    if(($expected -join ';') -cne ($actual -join ';')){throw 'Target physical proof does not cover exactly the approved target roots.'}
    if((Get-WsmHashText ([string]$Proof.TargetHostId+'|'+($actual -join ';'))) -ine $Proof.TargetPhysicalId){throw 'Target physical identity does not match the proof host and endpoint identities.'}
    foreach($peer in @($Proof.PeerShareProofs)){if($peer.Kind -cne 'AssistivePeerShareProof' -or -not $peer.PeerFingerprint -or -not $peer.ShareName -or -not $peer.LocalPhysicalRoot -or -not $peer.ProofHash){throw 'Target physical proof contains an invalid peer-share proof.'}}
    $body=[ordered]@{};foreach($p in $Proof.PSObject.Properties){if($p.Name -cne 'ProofHash'){$body[$p.Name]=$p.Value}}
    if((Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress)) -ine $Proof.ProofHash){throw 'Target physical proof hash mismatch.'};$true
}

function Get-WsmAssistiveVolumeIdentity([string]$Path,[string]$ProviderId='') {
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith('\\')){throw 'UNC physical identity requires an imported, operator-reviewed peer-share proof; provider strings are not physical proof.'}
    $physical=if(Get-Command Get-WsmPhysicalPath -ErrorAction SilentlyContinue){Get-WsmPhysicalPath $full}else{$full}
    $match=[regex]::Match($physical,'^(\\\\\?\\Volume\{[0-9a-fA-F-]+\})');if($match.Success){return ('LocalVolume|'+$match.Groups[1].Value.ToLowerInvariant())}
    'LocalVolume|'+[IO.Path]::GetPathRoot($full).ToLowerInvariant()
}

function Get-WsmAssistiveMachineFingerprint {
    $product=Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
    $system=Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $uuid=[string]$product.UUID
    if(-not $uuid -or $uuid -match '^0{8}-0{4}-0{4}-0{4}-0{12}$'){throw 'Machine product UUID is unavailable; peer identity cannot be proven.'}
    Get-WsmHashText (($uuid.Trim().ToLowerInvariant())+'|'+([string]$system.Name).ToLowerInvariant()+'|'+([string]$system.Domain).ToLowerInvariant())
}

function New-WsmAssistivePeerShareProof {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ShareName,[Parameter(Mandatory)][string]$PeerHostId,[Parameter(Mandatory)][string]$ProofPath,[switch]$RequireWrite)
    Assert-WsmId $PeerHostId
    if(-not (Get-Command Get-SmbShare -ErrorAction SilentlyContinue)){throw 'SMB server tools are unavailable; peer-share proof cannot be produced.'}
    $root=[IO.Path]::GetFullPath($Path);if(-not [IO.Directory]::Exists($root)){throw 'Peer share root must be an existing local directory.'}
    Assert-WsmNoReparse $root
    $share=@(Get-SmbShare -Name $ShareName -ErrorAction Stop);if($share.Count -ne 1){throw 'Named peer SMB share is absent or ambiguous.'}
    $local=[IO.Path]::GetFullPath([string]$share[0].Path).TrimEnd('\');if(-not $local.Equals($root.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Peer SMB share path differs from the reviewed local physical root.'}
    $physical=Get-WsmPhysicalPath $root
    if(-not (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue)){throw 'SMB server signing configuration is unavailable; peer-share proof cannot be produced.'}
    $serverConfiguration=Get-SmbServerConfiguration -ErrorAction Stop
    foreach($property in @('RequireSecuritySignature','EnableSecuritySignature')){if(-not $serverConfiguration.PSObject.Properties[$property]){throw ('SMB server signing policy field is unavailable: '+$property)}}
    $acl=Get-Acl -LiteralPath $root -ErrorAction Stop
    $shareAccess=@(Get-SmbShareAccess -Name $ShareName -ErrorAction Stop|ForEach-Object {('{0}|{1}|{2}' -f $_.AccountName,$_.AccessControlType,$_.AccessRight)}|Sort-Object)
    $canRead=$false;$canWrite=$false;$probePath=Join-Path $root ('.wsm-peer-proof-'+[Guid]::NewGuid().ToString('N')+'.tmp')
    $probe=[byte[]](83,77,66,80,82,79,79,70)
    # Probe only one directory entry. A share can contain millions of files,
    # and proof generation must not enumerate or retain the whole tree.
    try{$enumerator=[IO.Directory]::EnumerateFileSystemEntries($root).GetEnumerator();try{$null=$enumerator.MoveNext();$canRead=$true}finally{if($enumerator -is [IDisposable]){$enumerator.Dispose()}}}catch{}
    if($RequireWrite){try{[IO.File]::WriteAllBytes($probePath,$probe);$readback=[IO.File]::ReadAllBytes($probePath);$canWrite=($readback.Length -eq $probe.Length);for($i=0;$canWrite -and $i -lt $probe.Length;$i++){if($readback[$i] -ne $probe[$i]){$canWrite=$false}};$canRead=$canRead -and $canWrite}finally{if([IO.File]::Exists($probePath)){[IO.File]::Delete($probePath)}}}
    if(-not $canRead -or ($RequireWrite -and -not $canWrite)){throw 'Peer share ACL/access probe did not verify required access.'}
    $fingerprint=Get-WsmAssistiveMachineFingerprint
    $proof=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistivePeerShareProof';PeerHostId=$PeerHostId;PeerFingerprint=$fingerprint;PeerName=[string]$env:COMPUTERNAME;ShareName=$ShareName;SharePath=([string]$share[0].Path);LocalPhysicalRoot=$physical;ShareScope=@{EncryptData=[bool]$share[0].EncryptData;ContinuouslyAvailable=[bool]$share[0].ContinuouslyAvailable;RequireSecuritySignature=[bool]$serverConfiguration.RequireSecuritySignature;EnableSecuritySignature=[bool]$serverConfiguration.EnableSecuritySignature};ShareAccess=$shareAccess;DirectoryAclSddl=$acl.Sddl;Access=@{Read=$canRead;Write=$canWrite;WriteRequired=[bool]$RequireWrite};AccessHash='';CreatedUtc=(Get-WsmUtc);ProofHash=''}
    $proof.AccessHash=Get-WsmHashText (($proof.PeerFingerprint+'|'+$proof.ShareName.ToLowerInvariant()+'|'+$proof.LocalPhysicalRoot.ToLowerInvariant()+'|'+$proof.DirectoryAclSddl+'|'+($shareAccess -join ';')+'|'+$proof.Access.Read+'|'+$proof.Access.Write+'|'+$proof.ShareScope.EncryptData+'|'+$proof.ShareScope.RequireSecuritySignature+'|'+$proof.ShareScope.EnableSecuritySignature))
    $body=[ordered]@{};foreach($property in $proof.PSObject.Properties){if($property.Name -cne 'ProofHash'){$body[$property.Name]=$property.Value}};$proof.ProofHash=Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress)
    $directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ProofPath));if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory)};if([IO.File]::Exists($ProofPath)){throw 'Peer proof path already exists; evidence is immutable.'};Write-WsmJson $ProofPath $proof
    [pscustomobject]@{Proof=$proof;Path=[IO.Path]::GetFullPath($ProofPath);SHA256=(Get-WsmAssistiveNonCHash $ProofPath)}
}

function Read-WsmAssistivePeerShareProof {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedSHA256,[Parameter(Mandatory)][string]$ExpectedPeerFingerprint)
    Assert-WsmTrustedFile $Path $ExpectedSHA256;$proof=Read-WsmJson $Path
    if($proof.SchemaVersion -ne 1 -or $proof.Kind -cne 'AssistivePeerShareProof' -or $proof.PeerFingerprint -cne $ExpectedPeerFingerprint -or -not $proof.Access.Read -or -not $proof.PeerHostId -or -not $proof.ShareName -or -not $proof.LocalPhysicalRoot){throw 'Peer-share proof is malformed or does not match the operator-reviewed peer fingerprint.'}
    Assert-WsmId ([string]$proof.PeerHostId);Assert-WsmAssistiveHash ([string]$proof.AccessHash) 'Peer access proof hash';Assert-WsmAssistiveHash ([string]$proof.ProofHash) 'Peer proof hash'
    if(-not $proof.ShareScope.PSObject.Properties['RequireSecuritySignature'] -or -not $proof.ShareScope.PSObject.Properties['EnableSecuritySignature']){throw 'Peer proof omits the captured SMB server signing policy.'}
    $identity=Get-WsmHashText (($proof.PeerFingerprint+'|'+$proof.ShareName.ToLowerInvariant()+'|'+$proof.LocalPhysicalRoot.ToLowerInvariant()+'|'+$proof.DirectoryAclSddl+'|'+(@($proof.ShareAccess) -join ';')+'|'+$proof.Access.Read+'|'+$proof.Access.Write+'|'+$proof.ShareScope.EncryptData+'|'+$proof.ShareScope.RequireSecuritySignature+'|'+$proof.ShareScope.EnableSecuritySignature))
    if($identity -ine $proof.AccessHash){throw 'Peer access/ACL/share settings proof hash mismatch.'}
    $body=[ordered]@{};foreach($property in $proof.PSObject.Properties){if($property.Name -cne 'ProofHash'){$body[$property.Name]=$property.Value}};if((Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress)) -ine $proof.ProofHash){throw 'Peer-share proof content hash mismatch.'}
    $proof
}

function Assert-WsmAssistivePeerShareEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EndpointPath,[Parameter(Mandatory)]$Proof,[Parameter(Mandatory)][string]$ApprovedPeerFingerprint,[bool]$RequireEncrypted=$false,[bool]$RequireSigned=$true)
    if($Proof.PeerFingerprint -cne $ApprovedPeerFingerprint){throw 'Peer endpoint identity was not approved by the operator.'}
    $full=[IO.Path]::GetFullPath($EndpointPath);$match=[regex]::Match($full,'^\\\\([^\\]+)\\([^\\]+)(?:\\|$)');if(-not $match.Success){throw 'Peer endpoint must be a UNC path under the exact reviewed share.'}
    if($match.Groups[1].Value -ine $Proof.PeerName -or $match.Groups[2].Value -ine $Proof.ShareName){throw 'UNC server/share does not match the imported peer proof.'}
    $shareRoot='\\'+$match.Groups[1].Value+'\'+$match.Groups[2].Value;$probePath=$full
    while(-not (Test-Path -LiteralPath $probePath) -and $probePath.Length -gt $shareRoot.Length){$probePath=[IO.Path]::GetDirectoryName($probePath)}
    if(-not (Test-Path -LiteralPath $probePath)){throw 'Reviewed peer share or closest existing parent is not currently reachable.'}
    if(-not (Get-Command Get-SmbConnection -ErrorAction SilentlyContinue)){throw 'Get-SmbConnection is unavailable; live SMB endpoint validation is deferred.'}
    $connections=@(Get-SmbConnection -ErrorAction Stop|Where-Object {$_.ServerName -ieq $match.Groups[1].Value -and $_.ShareName -ieq $match.Groups[2].Value})
    if(-not $connections.Count){throw 'No live SMB connection matches the reviewed server/share.'}
    foreach($connection in $connections){if($RequireEncrypted -and (-not $connection.PSObject.Properties['Encrypted'] -or -not $connection.Encrypted)){throw 'Live SMB connection encryption is absent or not verified as required.'};if($RequireSigned -and (-not $connection.PSObject.Properties['Signed'] -or -not $connection.Signed)){throw 'Live SMB connection signing is absent or not verified as required.'}}
    $relative=$full.Substring(($match.Groups[0].Value.TrimEnd('\')).Length).TrimStart('\');$localRelative=if($relative){$relative}else{''}
    [pscustomobject]@{PeerFingerprint=$Proof.PeerFingerprint;ShareName=$Proof.ShareName;LocalPhysicalRoot=$Proof.LocalPhysicalRoot;RelativePath=$localRelative;PhysicalIdentity=('PeerShare|'+$Proof.PeerFingerprint.ToLowerInvariant()+'|'+$Proof.LocalPhysicalRoot.ToLowerInvariant());ResourceIdentity=('PeerResource|'+$Proof.PeerFingerprint.ToLowerInvariant()+'|'+$Proof.LocalPhysicalRoot.ToLowerInvariant()+'|'+$localRelative.ToLowerInvariant());Server=$match.Groups[1].Value;ConnectionCount=$connections.Count;Verified=$true;ObservedUtc=(Get-WsmUtc)}
}

function Get-WsmAssistiveEndpointIdentity([string]$Path,[object[]]$PeerShareProofs,[string]$ProviderId='') {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not $full.StartsWith('\\')){return Get-WsmAssistiveVolumeIdentity $full $ProviderId}
    $match=[regex]::Match($full,'^\\\\([^\\]+)\\([^\\]+)(?:\\|$)');if(-not $match.Success){throw 'SMB path does not identify a server/share.'}
    $candidates=@($PeerShareProofs|Where-Object {$_.PeerName -ieq $match.Groups[1].Value -and $_.ShareName -ieq $match.Groups[2].Value})
    if($candidates.Count -ne 1){throw 'SMB endpoint must match exactly one imported operator-reviewed peer-share proof.'}
    ('PeerShare|'+$candidates[0].PeerFingerprint.ToLowerInvariant()+'|'+$candidates[0].LocalPhysicalRoot.ToLowerInvariant())
}

function ConvertTo-WsmAssistivePeerPath([string]$LocalPath,$PeerProof) {
    $physical=Get-WsmPhysicalPath ([IO.Path]::GetFullPath($LocalPath));$root=[string]$PeerProof.LocalPhysicalRoot
    if(-not (Test-WsmPathOverlap $physical $root)){throw 'Local source path is outside the reviewed peer share physical root.'}
    if($physical.Equals($root,[StringComparison]::OrdinalIgnoreCase)){$relative=''}elseif($physical.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$relative=$physical.Substring($root.TrimEnd('\').Length).TrimStart('\')}else{throw 'Local source path is not a descendant of the reviewed peer share.'}
    $unc='\\'+$PeerProof.PeerName+'\'+$PeerProof.ShareName
    if($relative){$unc+='\'+$relative}
    $unc
}

function Resolve-WsmAssistivePeerPhysicalPath([string]$PeerPath,$PeerProof) {
    $full=[IO.Path]::GetFullPath($PeerPath);$match=[regex]::Match($full,'^\\\\([^\\]+)\\([^\\]+)(?:\\|$)')
    if(-not $match.Success -or $match.Groups[1].Value -ine $PeerProof.PeerName -or $match.Groups[2].Value -ine $PeerProof.ShareName){throw 'Source UNC does not match the exact approved peer server/share.'}
    $relative=$full.Substring($match.Groups[0].Value.TrimEnd('\').Length).TrimStart('\')
    if($relative -match '(^|\\)\.{1,2}(?:\\|$)'){throw 'Source UNC contains traversal segments.'}
    if(-not $relative){return [string]$PeerProof.LocalPhysicalRoot}
    ([string]$PeerProof.LocalPhysicalRoot).TrimEnd('\')+'\'+$relative
}

function New-WsmAssistiveTargetPhysicalProof {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetHostId,[Parameter(Mandatory)][string[]]$ApprovedTargetRoots,[string]$ProviderId='',[object[]]$PeerShareProofReferences=@(),[string[]]$ApprovedPeerFingerprints=@())
    Assert-WsmId $TargetHostId
    $proofs=@();foreach($reference in $PeerShareProofReferences){foreach($field in @('Path','SHA256','PeerFingerprint')){if(-not $reference.PSObject.Properties[$field]){throw 'Peer proof reference must provide trusted Path, SHA256 and operator-reviewed PeerFingerprint.'};if(@($ApprovedPeerFingerprints) -cnotcontains [string]$reference.PeerFingerprint){throw 'Peer fingerprint is not explicitly approved by the operator.'};$proofs+=@(Read-WsmAssistivePeerShareProof $reference.Path $reference.SHA256 $reference.PeerFingerprint)}}
    $identities=@();foreach($root in $ApprovedTargetRoots){$identities+=Get-WsmAssistiveEndpointIdentity $root $proofs $ProviderId};$identities=@($identities|Sort-Object -Unique)
    $id=Get-WsmHashText ($TargetHostId+'|'+($identities -join ';'))
    foreach($peer in $proofs){if($peer.PeerHostId -cne $TargetHostId){throw 'Target host ID differs from the imported peer-share proof identity.'}}
    $targetFingerprint=$null
    if($proofs.Count){$fingerprints=@($proofs.PeerFingerprint|Sort-Object -Unique);if($fingerprints.Count -ne 1){throw 'One target proof cannot mix peer machine identities.'};$targetFingerprint=$fingerprints[0]}else{$targetFingerprint=Get-WsmAssistiveMachineFingerprint}
    $proof=[pscustomobject][ordered]@{Kind='AssistiveTargetPhysicalProof';TargetHostId=$TargetHostId;ObserverMachineFingerprint=$targetFingerprint;TargetPhysicalId=$id;ProviderId=$ProviderId;PhysicalIdentities=$identities;PeerShareProofs=$proofs;Verified=$true;ObservedUtc=(Get-WsmUtc);ProofHash=''}
    $body=[ordered]@{};foreach($p in $proof.PSObject.Properties){if($p.Name -cne 'ProofHash'){$body[$p.Name]=$p.Value}};$proof.ProofHash=Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress);$proof
}

function Assert-WsmAssistivePathUnder([string]$Path,[string[]]$Roots,[string]$Label) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach($root in $Roots){
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $base=[IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($full.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { return $full }
    }
    throw (New-WsmContractError ($Label+' is outside the reviewed endpoint roots.'))
}

function ConvertTo-WsmAssistiveAccountMap($AccountMap) {
    $map=[ordered]@{};$seen=@{}
    if($null -eq $AccountMap){throw 'An explicit source-to-target SID map is required.'}
    foreach($property in $AccountMap.PSObject.Properties){
        try{$source=(New-Object Security.Principal.SecurityIdentifier([string]$property.Name)).Value;$target=(New-Object Security.Principal.SecurityIdentifier([string]$property.Value)).Value}catch{throw 'AccountMap contains an invalid SID; correct the reviewed mapping.'}
        if($seen.ContainsKey($source)){throw 'AccountMap contains duplicate source SID identities after canonicalization.'};$seen[$source]=$true;$map[$source]=$target
    }
    [pscustomobject]$map
}

function Get-WsmAssistiveTransferScopeRows {
    param([string]$ItemId,[string]$SourceRoot,[string]$TargetRoot,$Spec,[string]$Channel,[string[]]$ConsumerRefs,$AccountMap,$PeerProof,[object[]]$TargetPeerProofs,[string]$ProviderId,[string]$CollectionPhysicalPath)
    $sourceFull=[IO.Path]::GetFullPath($SourceRoot);$targetFull=[IO.Path]::GetFullPath($TargetRoot);$isRemote=$sourceFull.StartsWith('\\')
    $sourceIoRoot=$sourceFull;$sourcePhysicalRoot=''
    if($isRemote){if(-not $PeerProof){throw 'Remote source scope requires an exact imported source peer proof.'};$sourcePhysicalRoot=Resolve-WsmAssistivePeerPhysicalPath $sourceFull $PeerProof}else{$sourcePhysicalRoot=Get-WsmPhysicalPath $sourceFull}
    if(-not (Test-WsmAssistivePathWithin $sourcePhysicalRoot $CollectionPhysicalPath)){throw 'Selected source scope is not equal to or below its native collection proof.'}
    $exact=($Spec.PSObject.Properties['ContentSelection'] -and $Spec.ContentSelection -ceq 'ExactFiles')
    $files=New-Object 'System.Collections.Generic.List[object]';$directories=New-Object 'System.Collections.Generic.List[object]'
    if($exact){
        $approved=@($Spec.ConfigFiles);if(-not $approved.Count){throw 'ExactFiles has an empty approved ConfigFiles whitelist.'}
        $seen=@{}
        foreach($config in $approved){
            $relative=[string]$config.RelativePath;Assert-WsmRelativePath $relative
            if($seen.ContainsKey($relative)){throw 'ExactFiles contains duplicate canonical relative paths.'};$seen[$relative]=$true
            $source=Join-Path $sourceFull $relative;$target=Join-Path $targetFull $relative
            $physical=if($isRemote){Resolve-WsmAssistivePeerPhysicalPath $source $PeerProof}else{Get-WsmPhysicalPath $source}
            if(-not (Test-WsmAssistivePathWithin $physical $CollectionPhysicalPath)){throw 'ExactFiles member is outside its native source collection proof.'}
            if([IO.File]::Exists($source)){$hash=Get-WsmAssistiveNonCHash $source;if($hash -ine [string]$config.SHA256){throw 'ExactFiles member bytes differ from their independently approved SHA256.'};Assert-WsmAssistiveFileTopology $source;$status='Pending';$length=(New-Object IO.FileInfo($source)).Length}else{$hash=[string]$config.SHA256;$status='DeferredManual';$length=[long]0}
            $files.Add([pscustomobject]@{SourcePath=$source;RelativePath=$relative;SourceSHA256=$hash;Bytes=[long]$length;InitialStatus=$status})
            $parent=[IO.Path]::GetDirectoryName($relative);while($parent){if(-not $seen.ContainsKey('DIR|'+$parent)){$seen['DIR|'+$parent]=$true;$directories.Add([pscustomobject]@{SourcePath=(Join-Path $sourceFull $parent);RelativePath=$parent;SourceSHA256='';Bytes=[long]0;InitialStatus='Pending'})};$parent=[IO.Path]::GetDirectoryName($parent)}
        }
    }elseif([IO.Directory]::Exists($sourceFull)){
        $excluded=@();if($Spec.PSObject.Properties['ExcludedRelativePaths']){$excluded=@($Spec.ExcludedRelativePaths)}
        $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($sourceFull)
        while($stack.Count){$directory=$stack.Pop();$relativeDir=$directory.Substring($sourceFull.TrimEnd('\').Length).TrimStart('\');if($relativeDir){$skip=$false;foreach($exclude in $excluded){if($relativeDir -ieq $exclude -or $relativeDir.StartsWith(([string]$exclude).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$skip=$true;break}};if($skip){continue}}
            if($directory.Length -gt 239){throw 'Source path exceeds the supported 239-character topology limit.'};Assert-WsmAssistiveFileTopology $directory
            $directories.Add([pscustomobject]@{SourcePath=$directory;RelativePath=$relativeDir;SourceSHA256='';Bytes=[long]0;InitialStatus='Pending'})
            foreach($child in [IO.Directory]::EnumerateFileSystemEntries($directory)){$childRelative=$child.Substring($sourceFull.TrimEnd('\').Length).TrimStart('\');$excludedChild=$false;foreach($exclude in $excluded){if($childRelative -ieq $exclude -or $childRelative.StartsWith(([string]$exclude).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$excludedChild=$true;break}};if($excludedChild){continue};if([IO.Directory]::Exists($child)){$stack.Push($child)}else{if($child.Length -gt 239){throw 'Source path exceeds the supported 239-character topology limit.'};Assert-WsmAssistiveFileTopology $child;$files.Add([pscustomobject]@{SourcePath=$child;RelativePath=$childRelative;SourceSHA256=(Get-WsmAssistiveNonCHash $child);Bytes=[long](New-Object IO.FileInfo($child)).Length;InitialStatus='Pending'})}}
        }
    }elseif([IO.File]::Exists($sourceFull)){
        $name=[IO.Path]::GetFileName($sourceFull);Assert-WsmAssistiveFileTopology $sourceFull;$files.Add([pscustomobject]@{SourcePath=$sourceFull;RelativePath=$name;SourceSHA256=(Get-WsmAssistiveNonCHash $sourceFull);Bytes=[long](New-Object IO.FileInfo($sourceFull)).Length;InitialStatus='Pending'})
    }else{throw 'Selected source root is missing and cannot be expanded into a durable file list.'}
    $map=ConvertTo-WsmAssistiveAccountMap $AccountMap;$rows=New-Object 'System.Collections.Generic.List[object]'
    $directoryRows=@($directories.ToArray()|Sort-Object @{Expression={if($_.RelativePath){($_.RelativePath -split '\\').Count}else{0}}},RelativePath)
    foreach($entry in @($directoryRows)+@($files.ToArray())){
        $entryType=if($directories.Contains($entry)){'Directory'}else{'File'}
        $relativeTarget=[string]$entry.RelativePath
        if($entryType -eq 'File' -and [IO.File]::Exists($sourceFull) -and -not $exact){$relativeTarget=''}
        $target=if($relativeTarget){Join-Path $targetFull $relativeTarget}else{$targetFull}
        $targetPhysical=Get-WsmAssistiveEndpointIdentity $target $TargetPeerProofs $ProviderId
        $entryId=Get-WsmHashText ($ItemId+'|'+$entryType+'|'+([string]$entry.RelativePath).ToLowerInvariant())
        $original=[string]$Spec.SourcePath;if($entry.RelativePath -and -not ([IO.File]::Exists($sourceFull) -and -not $exact)){$original=Join-Path $original $entry.RelativePath}
        $rows.Add([pscustomobject][ordered]@{ItemId=$ItemId;EntryId=$entryId;EntryType=$entryType;RelativePath=[string]$entry.RelativePath;SourcePath=[string]$entry.SourcePath;OriginalSourcePath=$original;SourcePeerFingerprint=$(if($PeerProof){$PeerProof.PeerFingerprint}else{''});SourcePeerProofHash=$(if($PeerProof){$PeerProof.ProofHash}else{''});SourceSHA256=[string]$entry.SourceSHA256;Bytes=[long]$entry.Bytes;TargetPath=$target;TargetPhysicalIdentity=$targetPhysical;ConsumerRefs=@($ConsumerRefs|Sort-Object -Unique);AccountMap=$map;RequireSacl=([string]$Spec.Metadata -match '(?i)SACL');InitialStatus=$entry.InitialStatus})
    }
    $rows.ToArray()
}

function New-WsmAssistiveNonCTransferPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SealedPlanPath,[Parameter(Mandatory)][string]$SealedPlanHash,[Parameter(Mandatory)][string]$TransferPlanPath,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$FreezeRecordPath,[Parameter(Mandatory)][string]$FreezeRecordHash,
        [Parameter(Mandatory)][string]$FreezeEvidencePath,[Parameter(Mandatory)][string]$FreezeEvidenceHash,
        [Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ManifestHash,[Parameter(Mandatory)][string]$SourceInventoryHash,
        [Parameter(Mandatory)][ValidateSet('C','NonC')][string]$Channel,
        [Parameter(Mandatory)][string[]]$ApprovedSourceRoots,[Parameter(Mandatory)][string[]]$ApprovedTargetRoots,
        [Parameter(Mandatory)][object[]]$Entries,[Parameter(Mandatory)][string]$TargetPhysicalId,[Parameter(Mandatory)]$TargetPhysicalProof,
        [Parameter(Mandatory)][int]$Generation,
        [Parameter(Mandatory)][string]$TargetStateDirectory,
        [string]$MetadataPolicy='DaclOwnerMappedAndBasicTimes',[string]$MetadataPolicyHash,[string]$ProviderId='',
        [object[]]$SourcePeerShareProofReferences=@(),[string[]]$ApprovedSourcePeerFingerprints=@()
    )
    Assert-WsmId $PairId;Assert-WsmAssistiveHash $SealedPlanHash 'Sealed plan hash';Assert-WsmAssistiveHash $SourceInventoryHash 'Source inventory hash';Assert-WsmAssistiveHash $ManifestHash 'Manifest hash';if($Generation -lt 0){throw 'Generation must be non-negative.'}
    Assert-WsmAssistiveHash $FreezeRecordHash 'Freeze record hash';Assert-WsmAssistiveHash $FreezeEvidenceHash 'Freeze evidence hash';Assert-WsmTrustedFile $SealedPlanPath $SealedPlanHash;$sealed=Read-WsmMigrationPlan $SealedPlanPath $SealedPlanHash;Assert-WsmAssistiveContract $sealed MigrationPlan | Out-Null
    if($sealed.PairId -cne $PairId -or $sealed.Assistive.SourceSnapshotHash -ine $SourceInventoryHash){throw 'Transfer plan does not match the trusted sealed plan/source inventory.'}
    $package=Test-WsmMigrationPackage $ManifestPath $ManifestHash;if(-not $package.Manifest.Final -or $package.Manifest.PairId -cne $PairId -or $package.Manifest.PlanHash -ine $SealedPlanHash -or [long]$package.Manifest.Generation -ne [long]$Generation -or $package.Manifest.FreezeHash -ine $FreezeRecordHash){throw 'NonC final transfer must use the current final package and its exact source freeze record.'}
    $freeze=Read-WsmFreezeRecord $FreezeRecordPath $FreezeRecordHash $sealed $SealedPlanHash
    $freezeEvidence=Assert-WsmSourceFreezeEvidence $FreezeEvidencePath $FreezeEvidenceHash $sealed $SealedPlanHash $freeze.FreezeEpoch
    Assert-WsmSourceFreezeEvidenceMatchesAttestation $freezeEvidence $freeze
    if($freeze.SourceFreezeEvidence.Owner -cne $freeze.Owner){throw 'Source freeze owner differs from its independently verified writer-fence owner.'}
    $FreezeEpoch=[string]$freeze.FreezeEpoch
    $FreezeProof=[pscustomobject][ordered]@{Kind='AssistiveFreezeProof';FreezeId=$freeze.FreezeId;FreezeEpoch=$FreezeEpoch;FreezeRecordHash=$FreezeRecordHash.ToLowerInvariant();EvidenceId=$freeze.SourceFreezeEvidence.EvidenceId;EvidenceHash=$freeze.SourceFreezeEvidence.SHA256;WriterSetHash=$freeze.SourceFreezeEvidence.WriterSetHash;Owner=$freeze.SourceFreezeEvidence.Owner;PairId=$freeze.PairId;PlanHash=$freeze.PlanHash;SourceInventoryHash=$SourceInventoryHash.ToLowerInvariant();TargetFingerprint=$freeze.TargetFingerprint;ProofHash=''}
    $freezeBody=[ordered]@{};foreach($p in $FreezeProof.PSObject.Properties){if($p.Name -cne 'ProofHash'){$freezeBody[$p.Name]=$p.Value}};$FreezeProof.ProofHash=Get-WsmHashText ($freezeBody|ConvertTo-Json -Depth 20 -Compress)
    $sourcePeerProofs=@();foreach($reference in $SourcePeerShareProofReferences){foreach($field in @('Path','SHA256','PeerFingerprint')){if(-not $reference.PSObject.Properties[$field]){throw 'Source peer proof reference must provide trusted Path, SHA256 and reviewed PeerFingerprint.'};if(@($ApprovedSourcePeerFingerprints) -cnotcontains [string]$reference.PeerFingerprint -or $reference.PeerFingerprint -ine $sealed.Source.Fingerprint){throw 'Source peer fingerprint differs from the sealed source identity or operator-approved identity.'};$peerProof=Read-WsmAssistivePeerShareProof $reference.Path $reference.SHA256 $reference.PeerFingerprint;if($peerProof.PeerHostId -cne $sealed.Source.HostId){throw 'Source peer proof host ID differs from the sealed source host.'};$sourcePeerProofs+=@($peerProof)}}
    foreach($entry in $Entries){$planItem=@($sealed.Items|Where-Object ItemId -CEQ $entry.ItemId);if($planItem.Count -ne 1 -or $planItem[0].MigrationSpec.Adapter -cne 'FileScope'){throw 'Transfer row must identify exactly one approved sealed FileScope item.'};$collectionProof=@($package.Manifest.SourceCollectionProofs|Where-Object ItemId -CEQ $entry.ItemId);if($collectionProof.Count -ne 1 -or -not $collectionProof[0].NativeVerified -or $collectionProof[0].SourceFingerprint -cne $sealed.Source.Fingerprint -or $collectionProof[0].Channel -cne $Channel){throw 'NonC source path must be covered by the final package native physical-volume proof from the sealed source host.'};if([string]$entry.SourcePath -match '^\\\\'){$sourceEndpoint=[regex]::Match([string]$entry.SourcePath,'^\\\\([^\\]+)\\([^\\]+)');$sourcePeer=@($sourcePeerProofs|Where-Object {$_.PeerName -ieq $sourceEndpoint.Groups[1].Value -and $_.ShareName -ieq $sourceEndpoint.Groups[2].Value});if($sourcePeer.Count -ne 1){throw 'Jump-host source UNC requires one exact trusted peer-share proof.'};$physicalSource=Resolve-WsmAssistivePeerPhysicalPath ([string]$entry.SourcePath) $sourcePeer[0];if(-not (Test-WsmAssistivePathWithin $physicalSource ([string]$collectionProof[0].PhysicalPath))){throw 'Source UNC physical path is outside the sealed native collection scope.'};[void](Assert-WsmAssistivePathUnder ([string]$entry.SourcePath) $ApprovedSourceRoots 'Sealed source endpoint')}else{$sourceProof=Assert-WsmAssistiveSourceScope $planItem[0].MigrationSpec -Policy SourceCOnly;if($sourceProof.Channel -cne $Channel){throw 'Transfer channel differs from the sealed source physical-volume classification.'};if((Get-WsmAssistiveMachineFingerprint) -ine $sealed.Source.Fingerprint){throw 'Local source paths may only be resolved on the sealed source host; use a trusted source peer-share proof on the jump host.'};[void](Assert-WsmAssistivePathUnder ([string]$entry.SourcePath) @([string]$planItem[0].MigrationSpec.SourcePath) 'Sealed source path')}}
    Assert-WsmAssistiveFreezeProof $FreezeProof $FreezeEpoch | Out-Null
    if (-not $ApprovedSourceRoots.Count -or -not $ApprovedTargetRoots.Count -or -not $TargetPhysicalId) { throw 'Reviewed source and target roots plus a target physical identity are required.' }
    $expectedMetadataPolicyHash=Get-WsmHashText $MetadataPolicy
    if (-not $MetadataPolicyHash) { $MetadataPolicyHash=$expectedMetadataPolicyHash }
    Assert-WsmAssistiveHash $MetadataPolicyHash 'Metadata policy hash'
    if($MetadataPolicyHash -ine $expectedMetadataPolicyHash){throw 'Metadata policy hash does not match the declared supported metadata policy.'}
        $ids=@{};$rows=New-Object System.Collections.Generic.List[object];$transferSourceRoots=@()
    foreach($root in $ApprovedSourceRoots){if([string]$root -match '^\\\\'){ $sourceEndpoint=[regex]::Match([string]$root,'^\\\\([^\\]+)\\([^\\]+)');$sourceMatches=@($sourcePeerProofs|Where-Object {$_.PeerName -ieq $sourceEndpoint.Groups[1].Value -and $_.ShareName -ieq $sourceEndpoint.Groups[2].Value});if($sourceMatches.Count -ne 1){throw 'Approved source UNC root requires one exact trusted peer-share proof.'};$transferSourceRoots+=[IO.Path]::GetFullPath($root)}else{$physicalRoot=Get-WsmPhysicalPath ([IO.Path]::GetFullPath($root));$matching=@();foreach($peer in $sourcePeerProofs){if(Test-WsmAssistivePathWithin $physicalRoot ([string]$peer.LocalPhysicalRoot) -or Test-WsmAssistivePathWithin ([string]$peer.LocalPhysicalRoot) $physicalRoot){$matching+=@($peer)}};if($matching.Count -gt 1){throw 'Source root maps to multiple reviewed SMB shares.'};if($matching.Count -eq 1){$transferSourceRoots+=ConvertTo-WsmAssistivePeerPath $root $matching[0]}else{if((Get-WsmAssistiveMachineFingerprint) -ine $sealed.Source.Fingerprint){throw 'A native source root is only valid on the sealed source host.'};$transferSourceRoots+=[IO.Path]::GetFullPath($root)}}}
    foreach($entry in $Entries){
        foreach($field in @('ItemId','SourcePath','TargetPath','ConsumerRefs','AccountMap')){if(-not $entry.PSObject.Properties[$field]){throw ('NonC entry missing '+$field+'.')}}
        Assert-WsmAssistiveHash ([string]$entry.ItemId) 'NonC ItemId';if($ids.ContainsKey([string]$entry.ItemId)){throw 'Provide exactly one reviewed source and target root per selected FileScope ItemId.'};$ids[[string]$entry.ItemId]=$true
        $planItems=@($sealed.Items|Where-Object ItemId -CEQ $entry.ItemId);if($planItems.Count -ne 1 -or $planItems[0].Decision -cne 'Include' -or $planItems[0].MigrationSpec.Adapter -cne 'FileScope'){throw 'Transfer row must identify exactly one included sealed FileScope item.'};$spec=$planItems[0].MigrationSpec
        if(@($entry.ConsumerRefs).Count -eq 0){throw 'Every NonC transfer entry must retain at least one workload consumer reference.'}
        $collection=@($package.Manifest.SourceCollectionProofs|Where-Object ItemId -CEQ $entry.ItemId);if($collection.Count -ne 1 -or -not $collection[0].NativeVerified -or $collection[0].SourceFingerprint -cne $sealed.Source.Fingerprint -or $collection[0].Channel -cne $Channel -or $spec.TransferChannel -cne $Channel){throw 'Selected FileScope lacks the exact sealed native source/channel collection proof.'}
        $sourceRoot=Assert-WsmAssistivePathUnder ([string]$entry.SourcePath) $ApprovedSourceRoots 'Source root';$sourcePeer=$null
        if($sourceRoot.StartsWith('\\')){$endpoint=[regex]::Match($sourceRoot,'^\\\\([^\\]+)\\([^\\]+)');$matches=@($sourcePeerProofs|Where-Object {$_.PeerName -ieq $endpoint.Groups[1].Value -and $_.ShareName -ieq $endpoint.Groups[2].Value});if($matches.Count -ne 1){throw 'Jump-host source requires one exact peer proof.'};$sourcePeer=$matches[0];$physicalRoot=Resolve-WsmAssistivePeerPhysicalPath $sourceRoot $sourcePeer}
        else{if((Get-WsmAssistiveMachineFingerprint) -ine $sealed.Source.Fingerprint){throw 'Native source path resolution must run on the sealed source host; jump hosts need the trusted source peer UNC.'};$native=Assert-WsmAssistiveSourceScope $spec -Policy SourceCOnly -Native;if($native.Channel -cne $Channel){throw 'Current native source volume classification differs from the reviewed transfer channel.'};$physicalRoot=$native.PhysicalPath;if(-not (Test-WsmAssistivePathWithin (Get-WsmPhysicalPath $sourceRoot) ([string]$physicalRoot))){throw 'Selected local scope is outside the native physical source scope.'}}
        if(-not (Test-WsmAssistivePathWithin $physicalRoot ([string]$collection[0].PhysicalPath))){throw 'Selected source root is not equal to or below the final package native physical collection scope.'}
        if([IO.Path]::GetFullPath($sourceRoot).TrimEnd('\') -ine [IO.Path]::GetFullPath([string]$spec.SourcePath).TrimEnd('\') -and -not $sourceRoot.StartsWith('\\')){throw 'Selected source root must equal the exact sealed FileScope root.'}
        if([string]$entry.Channel -and $entry.Channel -cne $Channel){throw 'Entry channel differs from the transfer channel.'}
        if($Channel -eq 'NonC' -and -not $sourceRoot.StartsWith('\\') -and [IO.Path]::GetPathRoot($sourceRoot) -ieq 'C:\'){throw 'NonC transfer source must be outside the physical C volume.'}
        $targetRoot=Assert-WsmAssistivePathUnder ([string]$entry.TargetPath) $ApprovedTargetRoots 'Target root';if(-not $targetRoot.StartsWith('\\') -and (Get-WsmAssistiveMachineFingerprint) -ine $sealed.Target.Fingerprint){throw 'Native target path resolution must run on the sealed target host; jump hosts need the trusted target peer UNC.'}
        $accountMap=ConvertTo-WsmAssistiveAccountMap $entry.AccountMap;$targetPeers=@($TargetPhysicalProof.PeerShareProofs)
        $expanded=Get-WsmAssistiveTransferScopeRows -ItemId ([string]$entry.ItemId) -SourceRoot $sourceRoot -TargetRoot $targetRoot -Spec $spec -Channel $Channel -ConsumerRefs @($entry.ConsumerRefs) -AccountMap $accountMap -PeerProof $sourcePeer -TargetPeerProofs $targetPeers -ProviderId $ProviderId -CollectionPhysicalPath ([string]$collection[0].PhysicalPath)
        foreach($row in $expanded){$rows.Add($row)}
    }    $approved=@{};foreach($id in @($sealed.Assistive.ApprovedItemIds)){$approved[[string]$id]=$true};foreach($row in $rows){if(-not $approved.ContainsKey([string]$row.ItemId)){throw 'NonC selection is not a subset of sealed approved item IDs.'}}
    $provider=if($ProviderId){$ProviderId}else{''};$peerProofs=@($TargetPhysicalProof.PeerShareProofs);$targetIdentities=@();foreach($approvedRoot in $ApprovedTargetRoots){$targetIdentities+=Get-WsmAssistiveEndpointIdentity $approvedRoot $peerProofs $provider};$targetIdentities=@($targetIdentities|Sort-Object -Unique)
    Assert-WsmAssistiveTargetPhysicalProof $TargetPhysicalProof $TargetPhysicalId $targetIdentities|Out-Null
    if($sealed.PSObject.Properties['Target'] -and ($TargetPhysicalProof.TargetHostId -cne $sealed.Target.HostId -or $TargetPhysicalProof.ObserverMachineFingerprint -ine $sealed.Target.Fingerprint)){throw 'Target physical proof does not match the target host identity sealed in the migration plan.'}
    $stateProof=Resolve-WsmAssistiveTargetStateDirectory $TargetStateDirectory $sealed $TargetPhysicalProof
    $selectionIds=@($sealed.Assistive.ApprovedItemIds|Sort-Object);$selectionHash=Get-WsmHashText (([string]$sealed.Assistive.SourceSelectionsVersion)+'|'+($selectionIds -join '|'))
    $expansionHash=Get-WsmAssistiveNonCExpansionHash $rows.ToArray();$plan=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion='0.4.0';Kind='AssistiveNonCTransferPlan';TransferId=[Guid]::NewGuid().ToString();PairId=$PairId;SealedPlanHash=$SealedPlanHash.ToLowerInvariant();SelectionRevision=[int]$sealed.Assistive.SourceSelectionsVersion;SelectionHash=$selectionHash;ApprovedItemIds=$selectionIds;ManifestHash=$ManifestHash.ToLowerInvariant();Generation=$Generation;SourceInventoryHash=$SourceInventoryHash.ToLowerInvariant();SourceExpansionHash=$expansionHash;FreezeEpoch=$FreezeEpoch;FreezeProof=$FreezeProof;Channel=$Channel;TargetPhysicalId=$TargetPhysicalId;TargetPhysicalProof=$TargetPhysicalProof;TargetStateDirectory=$stateProof.TargetStateDirectory;TargetStateDirectoryIdentity=$stateProof.TargetStateDirectoryIdentity;TargetStateDirectoryAccessPath=$stateProof.TargetStateDirectoryAccessPath;TargetStateDirectoryPeerProofHash=$stateProof.TargetStateDirectoryPeerProofHash;TargetStateDirectoryProofHash=$stateProof.TargetStateDirectoryProofHash;SourcePeerShareProofs=$sourcePeerProofs;ProviderId=$ProviderId;ApprovedSourceRoots=@($transferSourceRoots);ApprovedTargetRoots=@($ApprovedTargetRoots);MetadataPolicy=$MetadataPolicy;MetadataPolicyHash=$MetadataPolicyHash.ToLowerInvariant();Entries=$rows.ToArray();CreatedUtc=(Get-WsmUtc)}
    $directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($TransferPlanPath));if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory)}
    if([IO.File]::Exists($TransferPlanPath)){throw 'Transfer plan path already exists; plans are immutable.'}
    Write-WsmJson $TransferPlanPath $plan
    [pscustomobject]@{Plan=$plan;Path=[IO.Path]::GetFullPath($TransferPlanPath);SHA256=(Get-WsmAssistiveNonCHash $TransferPlanPath)}
}

function Assert-WsmAssistiveNonCPlan($Plan,[string]$PlanPath,[string]$ExpectedPlanHash) {
    Assert-WsmTrustedFile $PlanPath $ExpectedPlanHash;$actual=Read-WsmJson $PlanPath
    foreach($field in @('SchemaVersion','Kind','TransferId','PairId','SealedPlanHash','SelectionRevision','SelectionHash','ApprovedItemIds','ManifestHash','Generation','SourceInventoryHash','SourceExpansionHash','FreezeEpoch','FreezeProof','Channel','TargetPhysicalId','TargetPhysicalProof','TargetStateDirectory','TargetStateDirectoryIdentity','TargetStateDirectoryAccessPath','TargetStateDirectoryPeerProofHash','TargetStateDirectoryProofHash','MetadataPolicy','MetadataPolicyHash','Entries')){if(-not $actual.PSObject.Properties[$field]){throw ('NonC transfer plan missing '+$field+'.')}}
    if($actual.SchemaVersion -ne 3 -or $actual.ToolVersion -cne '0.4.0' -or $actual.Kind -cne 'AssistiveNonCTransferPlan' -or @('C','NonC') -cnotcontains $actual.Channel -or @('DaclOwnerMappedAndBasicTimes','DaclOwnerSaclMappedAndBasicTimes') -cnotcontains $actual.MetadataPolicy){throw 'Unsupported NonC transfer plan.'}
    Assert-WsmAssistiveHash ([string]$actual.SealedPlanHash) 'Sealed plan hash';Assert-WsmAssistiveHash ([string]$actual.SourceInventoryHash) 'Source inventory hash';Assert-WsmAssistiveHash ([string]$actual.MetadataPolicyHash) 'Metadata policy hash'
    if((Get-WsmHashText ([string]$actual.MetadataPolicy)) -ine $actual.MetadataPolicyHash){throw 'Metadata policy hash does not match the declared metadata policy.'}
    Assert-WsmAssistiveFreezeProof $actual.FreezeProof ([string]$actual.FreezeEpoch)|Out-Null;if($actual.FreezeProof.SourceInventoryHash -ine $actual.SourceInventoryHash){throw 'NonC transfer plan has a mismatched freeze source inventory.'}
    $stateAccess=[IO.Path]::GetFullPath([string]$actual.TargetStateDirectoryAccessPath);$stateNative=[string]$actual.TargetStateDirectory.TrimEnd('\');if(-not [IO.Path]::IsPathRooted($stateNative) -or $stateNative -match '(^|\\)\.{1,2}(?:\\|$)'){throw 'NonC transfer plan target state physical path is not canonical.'}
    $targetFingerprint=[string]$actual.TargetPhysicalProof.ObserverMachineFingerprint;if($targetFingerprint -notmatch '^[a-fA-F0-9]{64}$'){throw 'Target state directory identity is missing the trusted target fingerprint.'}
    $expectedStateIdentity=$targetFingerprint.ToLowerInvariant()+'|'+$stateNative.ToLowerInvariant();if($actual.TargetStateDirectoryIdentity -cne $expectedStateIdentity){throw 'Transfer plan target state identity does not bind the target fingerprint and native physical path.'}
    $statePeerHash='';if($stateAccess.StartsWith('\\')){$ep=[regex]::Match($stateAccess,'^\\([^\\]+)\\([^\\]+)(?:\\|$)');if(-not $ep.Success){throw 'Transfer plan target state access path is not a valid SMB endpoint.'};$peer=@($actual.TargetPhysicalProof.PeerShareProofs|Where-Object {$_.PeerName -ieq $ep.Groups[1].Value -and $_.ShareName -ieq $ep.Groups[2].Value -and $_.PeerFingerprint -ceq $targetFingerprint -and $_.PeerHostId -ceq $actual.TargetPhysicalProof.TargetHostId});if($peer.Count -ne 1 -or (Resolve-WsmAssistivePeerPhysicalPath $stateAccess $peer[0]).TrimEnd('\') -ine $stateNative){throw 'Transfer plan target state path is outside the exact trusted Target peer proof.'};$statePeerHash=[string]$peer[0].ProofHash}elseif($actual.TargetStateDirectoryPeerProofHash){throw 'Native Target state directory cannot carry an SMB peer proof hash.'}
    if($statePeerHash -ine [string]$actual.TargetStateDirectoryPeerProofHash){throw 'Transfer plan target state peer proof hash is stale.'}
    if((Get-WsmHashText ($expectedStateIdentity+'|'+$stateAccess.ToLowerInvariant()+'|'+$statePeerHash.ToLowerInvariant())) -ine $actual.TargetStateDirectoryProofHash){throw 'Transfer plan target state directory proof hash mismatch.'}
    $identities=@($actual.TargetPhysicalProof.PhysicalIdentities|Sort-Object -Unique);Assert-WsmAssistiveTargetPhysicalProof $actual.TargetPhysicalProof $actual.TargetPhysicalId $identities|Out-Null;$entryIds=@{}
    foreach($entry in $actual.Entries){
        foreach($field in @('ItemId','EntryId','EntryType','RelativePath','SourcePath','OriginalSourcePath','SourcePeerFingerprint','SourcePeerProofHash','SourceSHA256','Bytes','TargetPath','TargetPhysicalIdentity','ConsumerRefs','AccountMap','RequireSacl')){if(-not $entry.PSObject.Properties[$field]){throw ('Transfer entry missing '+$field+'.')}}
        Assert-WsmAssistiveHash ([string]$entry.ItemId) 'Transfer entry ItemId';Assert-WsmAssistiveHash ([string]$entry.EntryId) 'Transfer entry EntryId'
        if(@('File','Directory') -cnotcontains [string]$entry.EntryType){throw 'Transfer entry type is invalid.'}
        if([string]$entry.RelativePath){Assert-WsmRelativePath ([string]$entry.RelativePath)}
        $expectedId=Get-WsmHashText ($entry.ItemId+'|'+$entry.EntryType+'|'+([string]$entry.RelativePath).ToLowerInvariant());if($entry.EntryId -ine $expectedId -or $entryIds.ContainsKey([string]$entry.EntryId)){throw 'Transfer entry identity is malformed or duplicated.'};$entryIds[[string]$entry.EntryId]=$true
        if($entry.EntryType -eq 'File'){Assert-WsmAssistiveHash ([string]$entry.SourceSHA256) 'Source file hash'}elseif([string]$entry.SourceSHA256){throw 'Directory entry cannot declare file content bytes.'}
        if([long]$entry.Bytes -lt 0 -or @($entry.ConsumerRefs).Count -eq 0){throw 'Entry byte count or consumer references are invalid.'}
        if($identities -cnotcontains [string]$entry.TargetPhysicalIdentity){throw 'Transfer destination is outside the sealed physical target proof.'}
        [void](Assert-WsmAssistivePathUnder ([string]$entry.TargetPath) @($actual.ApprovedTargetRoots) 'Sealed target path');[void](Assert-WsmAssistivePathUnder ([string]$entry.SourcePath) @($actual.ApprovedSourceRoots) 'Sealed source path')
        $canonicalMap=ConvertTo-WsmAssistiveAccountMap $entry.AccountMap;if(($canonicalMap|ConvertTo-Json -Depth 8 -Compress) -cne ($entry.AccountMap|ConvertTo-Json -Depth 8 -Compress)){throw 'Transfer AccountMap is not canonical.'}
        if([string]$entry.SourcePath -match '^\\\\'){$sourceMatch=[regex]::Match([string]$entry.SourcePath,'^\\\\([^\\]+)\\([^\\]+)');$sourcePeer=@($actual.SourcePeerShareProofs|Where-Object {$_.PeerName -ieq $sourceMatch.Groups[1].Value -and $_.ShareName -ieq $sourceMatch.Groups[2].Value -and $_.PeerFingerprint -ceq $entry.SourcePeerFingerprint -and $_.ProofHash -ceq $entry.SourcePeerProofHash});if($sourcePeer.Count -ne 1){throw 'SMB source path has no matching imported trusted source peer proof.'}}
    }
    if((Get-WsmAssistiveNonCExpansionHash $actual.Entries) -ine $actual.SourceExpansionHash){throw 'NonC source expansion commitment does not match its complete typed entry set.'}
    $actual
}
function Set-WsmAssistiveFileMetadata([string]$Source,[string]$Destination,$AccountMap,[switch]$IsDirectory,[switch]$RequireSacl,[switch]$VerifyOnly) {
    $sourceAcl=Get-Acl -LiteralPath $Source -ErrorAction Stop;$mappedRules=New-Object System.Collections.Generic.List[object];$expectedSignatures=New-Object System.Collections.Generic.List[string]
    foreach($rule in @($sourceAcl.Access)){
        $sourceSid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;$targetSid=$null
        if($AccountMap.PSObject.Properties[$sourceSid]){$targetSid=[string]$AccountMap.$sourceSid}
        elseif(@('S-1-5-18','S-1-5-32-544','S-1-5-32-545','S-1-5-11','S-1-1-0') -ccontains $sourceSid){$targetSid=$sourceSid}
        if(-not $targetSid){throw 'A source DACL principal has no explicit reviewed target SID mapping.'}
        $sid=New-Object Security.Principal.SecurityIdentifier($targetSid);$identity=$sid.Translate([Security.Principal.NTAccount])
        $mappedRules.Add((New-Object Security.AccessControl.FileSystemAccessRule($identity,$rule.FileSystemRights,$rule.InheritanceFlags,$rule.PropagationFlags,$rule.AccessControlType)))
        $expectedSignatures.Add(($targetSid+'|'+$rule.AccessControlType+'|'+$rule.FileSystemRights+'|'+$rule.InheritanceFlags+'|'+$rule.PropagationFlags))
    }
    $sourceOwnerSid=(New-Object Security.Principal.NTAccount([string]$sourceAcl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value;$targetOwnerSid=$null
    if($AccountMap.PSObject.Properties[$sourceOwnerSid]){$targetOwnerSid=[string]$AccountMap.$sourceOwnerSid}elseif(@('S-1-5-18','S-1-5-32-544','S-1-5-32-545','S-1-5-11','S-1-1-0') -ccontains $sourceOwnerSid){$targetOwnerSid=$sourceOwnerSid}
    if(-not $targetOwnerSid){throw 'Source owner has no explicit reviewed target SID mapping.'}
    $targetAcl=Get-Acl -LiteralPath $Destination -ErrorAction Stop
    if(-not $VerifyOnly){$targetAcl.SetAccessRuleProtection($true,$false);foreach($rule in @($targetAcl.Access)){[void]$targetAcl.RemoveAccessRuleSpecific($rule)};foreach($rule in $mappedRules){[void]$targetAcl.AddAccessRule($rule)};$targetOwner=(New-Object Security.Principal.SecurityIdentifier($targetOwnerSid)).Translate([Security.Principal.NTAccount]);$targetAcl.SetOwner($targetOwner);Set-Acl -LiteralPath $Destination -AclObject $targetAcl -ErrorAction Stop}
    $sourceInfo=Get-Item -LiteralPath $Source -Force;$destInfo=Get-Item -LiteralPath $Destination -Force
    $attributeMask=([IO.FileAttributes]::Archive -bor [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System);$expectedAttributes=$sourceInfo.Attributes -band $attributeMask
    if(-not $VerifyOnly){$destInfo.CreationTimeUtc=$sourceInfo.CreationTimeUtc;$destInfo.LastWriteTimeUtc=$sourceInfo.LastWriteTimeUtc;$destInfo.Attributes=$expectedAttributes}
    $check=Get-Acl -LiteralPath $Destination -ErrorAction Stop;$actualSignatures=New-Object System.Collections.Generic.List[string]
    foreach($rule in @($check.Access)){$sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;$actualSignatures.Add(($sid+'|'+$rule.AccessControlType+'|'+$rule.FileSystemRights+'|'+$rule.InheritanceFlags+'|'+$rule.PropagationFlags))}
    $expectedSorted=@($expectedSignatures|Sort-Object);$actualSorted=@($actualSignatures|Sort-Object)
    $daclExact=(($expectedSorted -join "`n") -ceq ($actualSorted -join "`n")) -and [bool]$check.AreAccessRulesProtected;$ownerReadback=(New-Object Security.Principal.NTAccount([string]$check.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value
    $ownerExact=$ownerReadback -ceq $targetOwnerSid;$readSucceeded=$false
    if($IsDirectory){try{$enumerator=[IO.Directory]::EnumerateFileSystemEntries($Destination).GetEnumerator();try{$null=$enumerator.MoveNext();$readSucceeded=$true}finally{if($enumerator -is [IDisposable]){$enumerator.Dispose()}}}catch{}}
    else{try{$read=[IO.File]::Open($Destination,'Open','Read','ReadWrite');try{$null=$read.Length;$readSucceeded=$true}finally{$read.Dispose()}}catch{}}
    $saclStatus=if($RequireSacl){'DeferredManual: SACL copy/readback is not in the qualified D workflow.'}else{'NotRequired'}
    $timesExact=($destInfo.CreationTimeUtc.Ticks -eq $sourceInfo.CreationTimeUtc.Ticks) -and ($destInfo.LastWriteTimeUtc.Ticks -eq $sourceInfo.LastWriteTimeUtc.Ticks);$attributesExact=(($destInfo.Attributes -band $attributeMask) -eq $expectedAttributes);$metadataVerified=$daclExact -and $ownerExact -and $readSucceeded -and $timesExact -and $attributesExact -and -not $RequireSacl
    [pscustomobject]@{OwnerApplied=$ownerExact;ExpectedOwnerSid=$targetOwnerSid;ReadbackOwnerSid=$ownerReadback;DaclApplied=$daclExact;ExpectedDaclHash=(Get-WsmHashText ($expectedSorted -join "`n"));ReadbackDaclHash=(Get-WsmHashText ($actualSorted -join "`n"));ExpectedRuleCount=$expectedSorted.Count;ReadbackRuleCount=$actualSorted.Count;DestinationAclProtected=$check.AreAccessRulesProtected;ReadbackAccount=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;ReadbackSucceeded=$metadataVerified;ReadbackAccessSucceeded=$readSucceeded;SaclStatus=$saclStatus;CreationTimeUtc=$destInfo.CreationTimeUtc.ToString('o');LastWriteTimeUtc=$destInfo.LastWriteTimeUtc.ToString('o');TimesExact=$timesExact;Attributes=[string]$destInfo.Attributes;AttributesExact=$attributesExact;OwnerStatus=$(if($ownerExact){'Verified'}else{'DeferredManual'});MetadataStatus=$(if($metadataVerified){'Verified'}else{'DeferredManual'})}
}
function Get-WsmAssistiveTransferFailureReason([Exception]$Exception) {
    if($Exception -is [UnauthorizedAccessException]){return 'Required file access or metadata authority was unavailable; grant reviewed source read and target write/ACL rights, then retry.'}
    if($Exception -is [IO.PathTooLongException]){return 'Path exceeds the supported transfer limit; shorten the reviewed path or use a separately qualified workflow.'}
    if($Exception -is [IO.IOException]){return 'A source/share/target I/O condition interrupted this entry; verify the reviewed endpoints and resume from the journal.'}
    'Native metadata or endpoint verification did not complete; inspect the item and environment, then retry from the durable journal.'
}

function Get-WsmAssistiveNonCScopeSnapshot([string]$Root) {
    $full=[IO.Path]::GetFullPath($Root);$rows=New-Object System.Collections.Generic.List[object]
    if([IO.Directory]::Exists($full)){
        foreach($entry in @(Get-ChildItem -LiteralPath $full -Force -Recurse -ErrorAction Stop | Sort-Object FullName)){
            if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Target scope contains a reparse point; preserve it and investigate.'}
            $relative=$entry.FullName.Substring($full.TrimEnd('\').Length).TrimStart('\')
            if($entry.PSIsContainer){$rows.Add([pscustomobject]@{RelativePath=$relative;Kind='Directory';Length=[long]0;SHA256='';LastWriteUtc=$entry.LastWriteTimeUtc.ToString('o')})}
            else{$rows.Add([pscustomobject]@{RelativePath=$relative;Kind='File';Length=[long]$entry.Length;SHA256=(Get-WsmAssistiveNonCHash $entry.FullName);LastWriteUtc=$entry.LastWriteTimeUtc.ToString('o')})}
        }
    } elseif([IO.File]::Exists($full)) { $file=Get-Item -LiteralPath $full -Force;$rows.Add([pscustomobject]@{RelativePath=[IO.Path]::GetFileName($full);Kind='File';Length=[long]$file.Length;SHA256=(Get-WsmAssistiveNonCHash $full);LastWriteUtc=$file.LastWriteTimeUtc.ToString('o')}) }
    [pscustomobject]@{Root=$full;Exists=([IO.Directory]::Exists($full) -or [IO.File]::Exists($full));Rows=$rows.ToArray();Hash=(Get-WsmHashText ($rows.ToArray()|ConvertTo-Json -Depth 12 -Compress))}
}

function Copy-WsmAssistiveNonCMaterial([string]$Workspace,[string]$PairId,[int]$Generation,[string]$Path,[string]$Hash,[string]$Kind,[string[]]$ConsumerRefs) {
    if(-not [IO.File]::Exists($Path) -or (Get-WsmAssistiveNonCHash $Path) -ine $Hash){throw 'A trusted immutable transfer material is missing or changed before publication.'}
    $directory=Join-Path (Join-Path (Join-Path $Workspace 'assistive') 'materials') $PairId
    if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory}
    $destination=Join-Path $directory ($Hash.ToLowerInvariant()+'.json')
    if([IO.File]::Exists($destination)){if((Get-WsmAssistiveNonCHash $destination) -ine $Hash){throw 'Content-addressed target material path contains drifted bytes; preserve it for repair.'}}
    else{[IO.File]::Copy($Path,$destination,$false);if((Get-WsmAssistiveNonCHash $destination) -ine $Hash){throw 'Published target material failed immutable hash readback.'}}
    Register-WsmAssistiveMaterialReference -Workspace $Workspace -PairId $PairId -Generation $Generation -Path $destination -SHA256 $Hash -Kind $Kind -ConsumerRefs $ConsumerRefs
}

function Reserve-WsmAssistiveNonCScope([string]$Workspace,$Plan,$Entry,[string]$Root,[string]$SealedPlanPath='',[string]$SealedPlanHash='') {
    $targetFingerprint=[string]$Plan.TargetPhysicalProof.ObserverMachineFingerprint
    $proofPath='';$proofHash='';$peerFingerprint=''
    if($Root.StartsWith('\\')){$endpoint=[regex]::Match($Root,'^\\([^\]+)\([^\]+)');$peers=@($Plan.TargetPhysicalProof.PeerShareProofs|Where-Object {$_.PeerName -ieq $endpoint.Groups[1].Value -and $_.ShareName -ieq $endpoint.Groups[2].Value -and $_.PeerFingerprint -ceq $targetFingerprint});if($peers.Count -ne 1){throw 'Target file scope has no unique approved peer-share proof.'};$peerFingerprint=$targetFingerprint;$proofDir=Join-Path (Join-Path $Workspace 'assistive') 'peerproofs';if(-not [IO.Directory]::Exists($proofDir)){[void][IO.Directory]::CreateDirectory($proofDir);Protect-WsmDirectory $proofDir};$proofPath=Join-Path $proofDir ('target-'+[string]$peers[0].ProofHash+'.json');if(-not [IO.File]::Exists($proofPath)){Write-WsmJson $proofPath $peers[0]};$proofHash=Get-WsmAssistiveNonCHash $proofPath;if(-not $proofHash){throw 'Target peer proof material failed hash verification.'}}
    $resource=Resolve-WsmAssistivePhysicalResource $Root '' $proofPath $proofHash $peerFingerprint
    $registry=Get-WsmAssistiveResourceRegistry $Workspace;$resourceKey=Get-WsmHashText ('TargetFile|'+$targetFingerprint.ToLowerInvariant()+'|'+$resource.CanonicalPhysicalPath)
    $existing=@($registry.Resources|Where-Object ResourceKey -CEQ $resourceKey)
    if($existing.Count){$otherOwners=@($existing[0].Owners|Where-Object {-not ($_.PairId -ceq $Plan.PairId -and $_.ItemId -ceq $Entry.ItemId -and $_.Channel -ceq $Plan.Channel)});if($otherOwners.Count){throw 'The same target physical scope is already owned by another pair or item; it cannot be shared implicitly.'};$owner=@($existing[0].Owners|Where-Object {$_.PairId -ceq $Plan.PairId -and $_.ItemId -ceq $Entry.ItemId -and $_.Channel -ceq $Plan.Channel});if($owner.Count -gt 1){throw 'Duplicate transfer owner rows exist in the target resource registry.'};if($owner.Count){if($owner[0].SourceHash -ine $Plan.SourceInventoryHash -or $owner[0].ResourceName -cne $Root -or $owner[0].DriftStatus -ceq 'Drifted'){throw 'Existing target scope reservation has changed source ownership or unresolved drift.'};if(-not $owner[0].Readback -or (Get-WsmAssistiveNonCScopeSnapshot $Root).Hash -cne [string]$owner[0].Readback.Hash){throw 'Target scope differs from its last durable readback; preserve it and reconcile before resume.'};return [pscustomobject]@{ResourceKey=$resourceKey;RegistryRevision=$registry.Revision;Owner=$owner[0];Reserved=$true;AlreadyOwned=$true;PhysicalIdentity=$resource.PhysicalIdentity}}}
    $preview=Get-WsmAssistiveResourceReservationPreview -Workspace $Workspace -PairId $Plan.PairId -ItemId $Entry.ItemId -Path $Root -Channel $Plan.Channel -SourceHash $Plan.SourceInventoryHash -TargetPhysicalId $resource.PhysicalIdentity -ConsumerRefs @($Entry.ConsumerRefs) -ResourceKind FileScope -TargetFingerprint $targetFingerprint -PeerShareProofPath $proofPath -PeerShareProofHash $proofHash -ApprovedPeerFingerprint $peerFingerprint -SealedPlanPath $SealedPlanPath -SealedPlanHash $SealedPlanHash
    if(-not $preview.CanReserve){throw 'Target file scope overlaps a different pair, channel, or source reservation; this item remains blocked.'}
    $sameOwner=@($preview.ExistingOwners|Where-Object {$_.PairId -ceq $Plan.PairId -and $_.ItemId -ceq $Entry.ItemId -and $_.Channel -ceq $Plan.Channel})
    if($sameOwner.Count){if($sameOwner.Count -ne 1 -or $sameOwner[0].SourceHash -ine $Plan.SourceInventoryHash -or $sameOwner[0].ResourceName -cne $Root -or $sameOwner[0].DriftStatus -ceq 'Drifted' -or -not $sameOwner[0].Readback -or (Get-WsmAssistiveNonCScopeSnapshot $Root).Hash -cne [string]$sameOwner[0].Readback.Hash){throw 'Existing target scope ownership is stale or has drifted; preserve it and reconcile before resume.'};return [pscustomobject]@{ResourceKey=$preview.ResourceKey;RegistryRevision=$preview.RegistryRevision;Owner=$sameOwner[0];Reserved=$true;AlreadyOwned=$true;PhysicalIdentity=$resource.PhysicalIdentity}}
    Reserve-WsmAssistiveResource -Workspace $Workspace -Preview $preview -ExpectedPreviewHash $preview.SHA256 -ExpectedRevision $preview.RegistryRevision -Reason ('Assistive NonC transfer '+$Plan.TransferId)
}

function Invoke-WsmAssistiveNonCTransferCore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransferPlanPath,[Parameter(Mandatory)][string]$ExpectedPlanHash,[Parameter(Mandatory)][string]$JournalPath,[Parameter(Mandatory)][string]$ResultPath,[PSCredential]$Credential,[PSCredential]$SourceCredential,[PSCredential]$TargetCredential,$ScopeContext,[System.Collections.IDictionary]$ScopeErrors=@{},$CancellationToken=$null)
    $plan=Assert-WsmAssistiveNonCPlan $null $TransferPlanPath $ExpectedPlanHash
    if($CancellationToken){[void](Assert-WsmCancellationTokenBinding $CancellationToken $plan.PairId $plan.SealedPlanHash $plan.ManifestHash $plan.TargetStateDirectoryAccessPath)}
    $journal=$null;$driveNames=New-Object System.Collections.Generic.List[string];$driveRoots=@{};$uncRootRoles=@{}
    foreach($root in @($plan.ApprovedSourceRoots)){if($root -match '^(\\\\[^\\]+\\[^\\]+)'){$uncRootRoles[$matches[1].ToLowerInvariant()]='Source'}}
    foreach($root in @($plan.ApprovedTargetRoots)){if($root -match '^(\\\\[^\\]+\\[^\\]+)'){$key=$matches[1].ToLowerInvariant();if($uncRootRoles.ContainsKey($key)){$uncRootRoles[$key]='Both'}else{$uncRootRoles[$key]='Target'}}}
    if([string]$plan.TargetStateDirectoryAccessPath -match '^(\\\\[^\\]+\\[^\\]+)'){$key=$matches[1].ToLowerInvariant();if($uncRootRoles.ContainsKey($key)){$uncRootRoles[$key]='Both'}else{$uncRootRoles[$key]='Target'}}
    foreach($unc in $uncRootRoles.Keys){$credentialToUse=$null;if($uncRootRoles[$unc] -eq 'Source'){$credentialToUse=$SourceCredential}elseif($uncRootRoles[$unc] -eq 'Target'){$credentialToUse=$TargetCredential}else{$credentialToUse=$Credential};if(-not $credentialToUse){$credentialToUse=$Credential};if($credentialToUse){$name='WSM'+[Guid]::NewGuid().ToString('N').Substring(0,8);try{New-PSDrive -Name $name -PSProvider FileSystem -Root $unc -Credential $credentialToUse -Scope Script -ErrorAction Stop|Out-Null}catch{foreach($created in $driveNames){Remove-PSDrive -Name $created -Force -ErrorAction SilentlyContinue};throw 'Approved SMB credential mapping failed; credentials were not persisted. Verify reviewed share access and retry.'};$driveNames.Add($name);$driveRoots[$unc]=$name}}
    # New-PSDrive establishes the reviewed SMB credential session; .NET file APIs
    # must keep using the UNC path because PowerShell-only drive names are not OS paths.
    $toIoPath={param([string]$Path) return $Path}.GetNewClosure()
    $stateWorkspace=$null;$jobLockActive=$false
    try {
        $stateWorkspace=& $toIoPath ([string]$plan.TargetStateDirectoryAccessPath)
        if(-not [IO.Directory]::Exists($stateWorkspace)){throw 'The approved Target StateDirectory is unavailable; no transfer writes were started.'}
        if([string]$plan.TargetStateDirectoryAccessPath -match '^\\\\'){$stateMatch=[regex]::Match([string]$plan.TargetStateDirectoryAccessPath,'^\\\\([^\\]+)\\([^\\]+)');$statePeers=@($plan.TargetPhysicalProof.PeerShareProofs|Where-Object {$_.PeerName -ieq $stateMatch.Groups[1].Value -and $_.ShareName -ieq $stateMatch.Groups[2].Value -and $_.PeerFingerprint -ceq $plan.TargetPhysicalProof.ObserverMachineFingerprint -and $_.ProofHash -ceq $plan.TargetStateDirectoryPeerProofHash});if($statePeers.Count -ne 1){throw 'Target registry SMB path does not match the exact reviewed Target peer proof.'};$null=Assert-WsmAssistivePeerShareEndpoint -EndpointPath $plan.TargetStateDirectoryAccessPath -Proof $statePeers[0] -ApprovedPeerFingerprint $plan.TargetPhysicalProof.ObserverMachineFingerprint -RequireEncrypted ([bool]$statePeers[0].ShareScope.EncryptData) -RequireSigned $true}
        else{if((Get-WsmAssistiveMachineFingerprint) -ine $plan.TargetPhysicalProof.ObserverMachineFingerprint -or (Get-WsmPhysicalPath $stateWorkspace).TrimEnd('\\') -ine [string]$plan.TargetStateDirectory){throw 'Local Target StateDirectory no longer matches the sealed target physical proof.'}}
        Assert-WsmNoReparse $stateWorkspace
        if($ScopeContext){$ScopeErrors=Get-WsmAssistiveNonCScopeErrors $plan $ScopeContext.SealedPlan $ScopeContext.Manifest}
        if([IO.File]::Exists($JournalPath)){$journal=Read-WsmJson $JournalPath;if($journal.SchemaVersion -ne 2 -or $journal.TransferId -cne $plan.TransferId -or $journal.PlanHash -ine $ExpectedPlanHash){throw 'Resume journal is legacy, malformed, or belongs to a different immutable transfer plan.'}}
        else{$journal=[pscustomobject][ordered]@{SchemaVersion=2;Kind='AssistiveNonCJournal';TransferId=$plan.TransferId;PlanHash=$ExpectedPlanHash.ToLowerInvariant();Revision=0;Rows=@();UpdatedUtc=(Get-WsmUtc)};Write-WsmJson $JournalPath $journal}
        $results=New-Object System.Collections.Generic.List[object]
        $consumer='transfer:'+([string]$plan.TransferId);$materialRefs=@($consumer)
        $materialRecords=New-Object System.Collections.Generic.List[object]
        $materialRecords.Add((Copy-WsmAssistiveNonCMaterial $stateWorkspace $plan.PairId ([int]$plan.Generation) $TransferPlanPath $ExpectedPlanHash 'NonCTransferPlan' $materialRefs))
        if($ScopeContext){
            $freezeRecordPath=Join-Path ([string]$ScopeContext.PackageRoot) 'freeze.json'
            foreach($spec in @(@{Path=$ScopeContext.SealedPlanPath;Hash=$ScopeContext.SealedPlanHash;Kind='SealedPlan'},@{Path=$ScopeContext.ManifestPath;Hash=$ScopeContext.ManifestHash;Kind='Manifest'},@{Path=$freezeRecordPath;Hash=[string]$ScopeContext.Manifest.FreezeHash;Kind='FreezeRecord'},@{Path=$ScopeContext.FreezeEvidencePath;Hash=$ScopeContext.FreezeEvidenceHash;Kind='FreezeEvidence'})){
                if(-not $spec.Path -or -not $spec.Hash -or -not [IO.File]::Exists([string]$spec.Path)){throw 'A trusted package/freeze input needed for the live job lock is inaccessible to the Target state publisher.'}
                $materialRecords.Add((Copy-WsmAssistiveNonCMaterial $stateWorkspace $plan.PairId ([int]$plan.Generation) ([string]$spec.Path) ([string]$spec.Hash) ([string]$spec.Kind) $materialRefs))
            }
        }
        $materialIds=@($materialRecords|ForEach-Object MaterialId|Sort-Object -Unique)
        Set-WsmAssistiveJobLock -Workspace $stateWorkspace -OperationId $plan.TransferId -PairId $plan.PairId -Generation ([int]$plan.Generation) -MaterialIds $materialIds -Active $true|Out-Null;$jobLockActive=$true
        $scopeReservations=@{};$scopeSnapshots=@{}
        foreach($group in @($plan.Entries|Group-Object ItemId)){
            $itemEntries=@($group.Group);$rootRow=@($itemEntries|Where-Object {$_.EntryType -eq 'Directory' -and -not $_.RelativePath}|Select-Object -First 1)
            if($rootRow.Count){$scopeRoot=[string]$rootRow[0].TargetPath}else{$sample=$itemEntries[0];$scopeRoot=Get-WsmAssistiveEntryScopeRoot ([string]$sample.TargetPath) ([string]$sample.RelativePath) ([string]$sample.OriginalSourcePath -ceq [string]$sample.SourcePath)}
            try{$scopeSnapshots[[string]$group.Name]=Get-WsmAssistiveNonCScopeSnapshot $scopeRoot;$scopeReservations[[string]$group.Name]=Reserve-WsmAssistiveNonCScope $stateWorkspace $plan $itemEntries[0] $scopeRoot ([string]$ScopeContext.SealedPlanPath) ([string]$ScopeContext.SealedPlanHash)}
            catch{Write-Verbose ('NonC resource reservation deferred: '+$_.Exception.GetType().FullName+': '+$_.Exception.Message);$ScopeErrors[[string]$group.Name]=Get-WsmAssistiveTransferFailureReason $_.Exception}
        }
        foreach($entry in $plan.Entries){
            $sourceIo=& $toIoPath ([string]$entry.SourcePath);$targetIo=& $toIoPath ([string]$entry.TargetPath);$entryType=[string]$entry.EntryType;$isDirectory=$entryType -ceq 'Directory'
            $prior=@($journal.Rows|Where-Object EntryId -CEQ $entry.EntryId);if($prior.Count -gt 1){throw 'Duplicate per-entry journal ownership record.'}
            $sourceExists=if($isDirectory){[IO.Directory]::Exists($sourceIo)}else{[IO.File]::Exists($sourceIo)}
            if($prior.Count -and $prior[0].Status -eq 'Applied'){
                if($isDirectory -and -not [IO.Directory]::Exists($targetIo)){throw 'Previously applied directory disappeared; preserve the journal and reconcile before resuming.'}
                if(-not $isDirectory -and (-not [IO.File]::Exists($targetIo) -or (Get-WsmAssistiveNonCHash $targetIo) -cne $prior[0].SHA256)){throw 'Previously applied destination bytes changed or disappeared; preserve it and reconcile before resuming.'}
            }
            $ownedExisting=$false;$journalConflict=$false
            if($prior.Count -and $prior[0].PSObject.Properties['OwnedByTransfer'] -and $prior[0].OwnedByTransfer){if($isDirectory -and [IO.Directory]::Exists($targetIo)){$ownedExisting=$true}elseif(-not $isDirectory -and [IO.File]::Exists($targetIo) -and (Get-WsmAssistiveNonCHash $targetIo) -ceq $prior[0].SHA256){$ownedExisting=$true}else{$journalConflict=$true}}
            $row=[pscustomobject][ordered]@{ItemId=$entry.ItemId;EntryId=$entry.EntryId;EntryType=$entry.EntryType;RelativePath=$entry.RelativePath;SourcePath=$entry.SourcePath;OriginalSourcePath=$entry.OriginalSourcePath;SourcePeerFingerprint=$entry.SourcePeerFingerprint;SourcePeerProofHash=$entry.SourcePeerProofHash;SourceSHA256=$entry.SourceSHA256;TargetPath=$entry.TargetPath;TargetPhysicalIdentity=$entry.TargetPhysicalIdentity;ConsumerRefs=@($entry.ConsumerRefs);Status='DeferredManual';Reason='Not processed';Bytes=[long]0;SHA256='';Metadata=$null;OwnedByTransfer=$ownedExisting;DirectoryCreatedByTransfer=$false;UpdatedUtc=(Get-WsmUtc)}
            if($ScopeErrors.Contains([string]$entry.ItemId)){$row.Status='DeferredManual';$row.Reason=[string]$ScopeErrors[[string]$entry.ItemId];$row.UpdatedUtc=Get-WsmUtc;$journal.Rows=@(@($journal.Rows|Where-Object EntryId -CNE $entry.EntryId)+@($row));$journal.Revision++;$journal.UpdatedUtc=Get-WsmUtc;Write-WsmJson $JournalPath $journal;$results.Add($row);continue}
            try {
                if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken ('BeforeEntry:'+([string]$entry.EntryId))}
                $sourcePeer=$null
                if([string]$entry.SourcePath -match '^\\\\'){$sourceEndpoint=[regex]::Match([string]$entry.SourcePath,'^\\\\([^\\]+)\\([^\\]+)');$sourcePeers=@($plan.SourcePeerShareProofs|Where-Object {$_.PeerName -ieq $sourceEndpoint.Groups[1].Value -and $_.ShareName -ieq $sourceEndpoint.Groups[2].Value -and $_.PeerFingerprint -ceq $entry.SourcePeerFingerprint -and $_.ProofHash -ceq $entry.SourcePeerProofHash});if($sourcePeers.Count -ne 1){throw 'No unique reviewed source peer-share proof covers this entry.'};$sourcePeer=$sourcePeers[0];$null=Assert-WsmAssistivePeerShareEndpoint -EndpointPath $entry.SourcePath -Proof $sourcePeer -ApprovedPeerFingerprint $sourcePeer.PeerFingerprint -RequireEncrypted ([bool]$sourcePeer.ShareScope.EncryptData) -RequireSigned $true}
                if([string]$entry.TargetPath -match '^\\\\'){$targetMatch=[regex]::Match([string]$entry.TargetPath,'^\\\\([^\\]+)\\([^\\]+)');$targetPeers=@($plan.TargetPhysicalProof.PeerShareProofs|Where-Object {$_.PeerName -ieq $targetMatch.Groups[1].Value -and $_.ShareName -ieq $targetMatch.Groups[2].Value});if($targetPeers.Count -ne 1){throw 'No unique reviewed target peer-share proof covers this entry.'};$null=Assert-WsmAssistivePeerShareEndpoint -EndpointPath $entry.TargetPath -Proof $targetPeers[0] -ApprovedPeerFingerprint $targetPeers[0].PeerFingerprint -RequireEncrypted ([bool]$targetPeers[0].ShareScope.EncryptData) -RequireSigned $true}
                if(-not $sourceExists){$row.Reason='Selected source file or directory is missing; restore it from the reviewed source scope before retrying.'}
                elseif($journalConflict){$row.Status='BlockedConflict';$row.Reason='Previously journal-owned destination drifted; external or drifted content is preserved.'}
                elseif($isDirectory){
                    if([IO.File]::Exists($targetIo)){$row.Status='BlockedConflict';$row.Reason='A file occupies the reviewed target directory path; it was not changed.'}
                    else{$created=$false;if(-not [IO.Directory]::Exists($targetIo)){[void][IO.Directory]::CreateDirectory($targetIo);$created=$true;$row.OwnedByTransfer=$true;$row.DirectoryCreatedByTransfer=$true}
                        try{if(Get-Command Assert-WsmAssistiveFileTopology -ErrorAction SilentlyContinue){Assert-WsmAssistiveFileTopology $sourceIo;Assert-WsmNoReparse $targetIo};$metadata=Set-WsmAssistiveFileMetadata $sourceIo $targetIo $entry.AccountMap -IsDirectory -RequireSacl:([bool]$entry.RequireSacl) -VerifyOnly:(-not $created);$row.Metadata=$metadata;if($metadata.ReadbackSucceeded){$row.Status='Applied';$row.Reason=$(if($created){'Directory created and mapped owner/DACL/timestamps plus target read access verified.'}else{'Existing directory reused; mapped owner/DACL/timestamps and target read access exactly match.'})}else{$row.Status='DeferredManual';$row.Reason='Directory preserved or created; required owner/DACL/SACL metadata could not be fully verified. Review metadata before workload completion.'}}
                        catch{$row.Status='DeferredManual';$row.Reason=Get-WsmAssistiveTransferFailureReason $_.Exception}
                    }
                }
                elseif(-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($targetIo))){$row.Status='BlockedConflict';$row.Reason='Approved parent directory could not be created from the reviewed directory entries; verify path and permissions.'}
                elseif(([IO.File]::Exists($targetIo) -or [IO.Directory]::Exists($targetIo)) -and -not $ownedExisting){$row.Status='BlockedConflict';$row.Reason='Destination file exists outside this exact transfer journal ownership; external files are never overwritten or merged.'}
                else{
                    if(Get-Command Assert-WsmAssistiveFileTopology -ErrorAction SilentlyContinue){Assert-WsmAssistiveFileTopology $sourceIo;$targetParent=[IO.Path]::GetDirectoryName($targetIo);Assert-WsmNoReparse $targetParent}
                    $sourceHash=Get-WsmAssistiveNonCHash $sourceIo;if($sourceHash -ine $entry.SourceSHA256){throw 'Source bytes changed since the reviewed transfer plan was sealed.'}
                    if($ownedExisting){$hash=Get-WsmAssistiveNonCHash $targetIo;if($hash -ine $sourceHash){throw 'Journal-owned destination no longer matches the verified source bytes.'}}
                    else{$temp=$targetIo+'.wsm-'+[Guid]::NewGuid().ToString('N')+'.tmp';$sourceStream=$null;$destStream=$null;$tempCreated=$false;try{$sourceStream=[IO.File]::Open($sourceIo,'Open','Read','Read');$destStream=[IO.File]::Open($temp,'CreateNew','Write','None');$tempCreated=$true;$buffer=New-Object byte[] (1MB);while(($read=$sourceStream.Read($buffer,0,$buffer.Length)) -gt 0){if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken ('CopyChunk:'+([string]$entry.EntryId))};$destStream.Write($buffer,0,$read)};$destStream.Flush($true);$destStream.Dispose();$destStream=$null;$sourceStream.Dispose();$sourceStream=$null;if($CancellationToken){Assert-WsmCancellationBoundary $CancellationToken ('BeforePublish:'+([string]$entry.EntryId))};$hash=Get-WsmAssistiveNonCHash $temp;if($hash -ine $sourceHash){throw 'Destination staging hash differs from the reviewed source bytes.'};[IO.File]::Move($temp,$targetIo);$tempCreated=$false;$row.OwnedByTransfer=$true}finally{if($sourceStream){$sourceStream.Dispose()};if($destStream){$destStream.Dispose()};if($tempCreated -and [IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}}
                    $metadata=Set-WsmAssistiveFileMetadata $sourceIo $targetIo $entry.AccountMap -RequireSacl:([bool]$entry.RequireSacl);$row.Metadata=$metadata;$readback=Get-WsmAssistiveNonCHash $targetIo;if($readback -ine $hash){throw 'Destination readback hash changed after metadata application.'};$row.Bytes=(New-Object IO.FileInfo($targetIo)).Length;$row.SHA256=$readback
                    if($metadata.ReadbackSucceeded){$row.Status='Applied';$row.Reason='File bytes, mapped owner/DACL, supported times/attributes and target-account readback verified.'}else{$row.Status='DeferredManual';$row.Reason='File bytes were verified; required owner/DACL/SACL metadata needs manual review before workload completion.'}
                }
            }catch{if($row.Status -ne 'BlockedConflict'){$row.Status='DeferredManual';$row.Reason=Get-WsmAssistiveTransferFailureReason $_.Exception}}
            $row.UpdatedUtc=Get-WsmUtc;$journal.Rows=@(@($journal.Rows|Where-Object EntryId -CNE $entry.EntryId)+@($row));$journal.Revision++;$journal.UpdatedUtc=Get-WsmUtc;Write-WsmJson $JournalPath $journal;$results.Add($row)
        }
        foreach($itemId in $scopeReservations.Keys){try{$prior=$scopeSnapshots[$itemId];$after=Get-WsmAssistiveNonCScopeSnapshot $prior.Root;$reservation=$scopeReservations[$itemId];$revision=(Get-WsmAssistiveResourceRegistry $stateWorkspace).Revision;$resourceKey=[string]$reservation.ResourceKey;$itemRows=@($results|Where-Object ItemId -CEQ $itemId);$desired=[pscustomobject]@{SourceExpansionHash=$plan.SourceExpansionHash;EntryIds=@($plan.Entries|Where-Object ItemId -CEQ $itemId|ForEach-Object EntryId|Sort-Object);ExpectedHashes=@($plan.Entries|Where-Object { $_.ItemId -ceq $itemId -and $_.EntryType -eq 'File' }|ForEach-Object SourceSHA256|Sort-Object)};$undo=[pscustomobject]@{Policy='NoOverwriteOrMerge';PriorSnapshot=$prior;CreatedEntryIds=@($itemRows|Where-Object OwnedByTransfer|ForEach-Object EntryId);RestoreRequiresExplicitCleanupPreview=$true};$matches=$true;foreach($expectedEntry in @($plan.Entries|Where-Object ItemId -CEQ $itemId)){if($expectedEntry.EntryType -eq 'File'){$actualPath=& $toIoPath ([string]$expectedEntry.TargetPath);if(-not [IO.File]::Exists($actualPath) -or (Get-WsmAssistiveNonCHash $actualPath) -ine $expectedEntry.SourceSHA256){$matches=$false;break}}else{$actualPath=& $toIoPath ([string]$expectedEntry.TargetPath);if(-not [IO.Directory]::Exists($actualPath)){$matches=$false;break}}};$drift=if($matches){'Match'}else{'Unknown'};Set-WsmAssistiveResourceEvidence -Workspace $stateWorkspace -ResourceKey $resourceKey -PairId $plan.PairId -ItemId $itemId -Channel $plan.Channel -ExpectedRevision $revision -Prior $prior -Desired $desired -Readback $after -Undo $undo -DriftStatus $drift|Out-Null}catch{$ScopeErrors[$itemId]='Target reservation evidence could not be durably recorded; preserve the target files and reconcile registry state.';foreach($resultRow in @($results|Where-Object ItemId -CEQ $itemId)){$resultRow.Status='DeferredManual';$resultRow.Reason=$ScopeErrors[$itemId];$resultRow.UpdatedUtc=Get-WsmUtc;$journal.Rows=@($journal.Rows|Where-Object EntryId -CNE $resultRow.EntryId)+@($resultRow);$journal.Revision++};$journal.UpdatedUtc=Get-WsmUtc;Write-WsmJson $JournalPath $journal}}
        $result=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion='0.4.0';Kind='AssistiveNonCTransferResult';TransferId=$plan.TransferId;PairId=$plan.PairId;SealedPlanHash=$plan.SealedPlanHash;SelectionRevision=$plan.SelectionRevision;SelectionHash=$plan.SelectionHash;ApprovedItemIds=$plan.ApprovedItemIds;SourceInventoryHash=$plan.SourceInventoryHash;SourceExpansionHash=$plan.SourceExpansionHash;PlanFileHash=$ExpectedPlanHash.ToLowerInvariant();ManifestHash=$plan.ManifestHash;Generation=$plan.Generation;TargetPhysicalId=$plan.TargetPhysicalId;TargetPhysicalProofHash=$plan.TargetPhysicalProof.ProofHash;TargetStateDirectory=$plan.TargetStateDirectory;TargetStateDirectoryIdentity=$plan.TargetStateDirectoryIdentity;TargetStateDirectoryAccessPath=$plan.TargetStateDirectoryAccessPath;TargetStateDirectoryPeerProofHash=$plan.TargetStateDirectoryPeerProofHash;TargetStateDirectoryProofHash=$plan.TargetStateDirectoryProofHash;MetadataPolicyHash=$plan.MetadataPolicyHash;FreezeEpoch=$plan.FreezeEpoch;FreezeProofHash=$plan.FreezeProof.ProofHash;Channel=$plan.Channel;Rows=$results.ToArray();CreatedUtc=(Get-WsmUtc)}
        if([IO.File]::Exists($ResultPath)){throw 'Result path already exists; transfer results are immutable.'};Write-WsmJson $ResultPath $result
        $resultRecord=Copy-WsmAssistiveNonCMaterial $stateWorkspace $plan.PairId ([int]$plan.Generation) $ResultPath (Get-WsmAssistiveNonCHash $ResultPath) 'NonCTransferResult' @($consumer)
        $journalSnapshot=Join-Path (Join-Path (Join-Path $stateWorkspace 'assistive') 'journals') ($plan.TransferId+'-'+$journal.Revision+'.json');$journalDir=[IO.Path]::GetDirectoryName($journalSnapshot);if(-not [IO.Directory]::Exists($journalDir)){[void][IO.Directory]::CreateDirectory($journalDir);Protect-WsmDirectory $journalDir};[IO.File]::Copy($JournalPath,$journalSnapshot,$false);$journalHash=Get-WsmAssistiveNonCHash $journalSnapshot;$journalRecord=Register-WsmAssistiveMaterialReference -Workspace $stateWorkspace -PairId $plan.PairId -Generation ([int]$plan.Generation) -Path $journalSnapshot -SHA256 $journalHash -Kind 'NonCJournalSnapshot' -ConsumerRefs @($consumer)
        [pscustomobject]@{Result=$result;Path=[IO.Path]::GetFullPath($ResultPath);SHA256=(Get-WsmAssistiveNonCHash $ResultPath);JournalRevision=$journal.Revision;TargetStateDirectory=$plan.TargetStateDirectory;TargetStateDirectoryIdentity=$plan.TargetStateDirectoryIdentity;TargetStateDirectoryAccessPath=$plan.TargetStateDirectoryAccessPath;TargetStateDirectoryPeerProofHash=$plan.TargetStateDirectoryPeerProofHash;TargetStateDirectoryProofHash=$plan.TargetStateDirectoryProofHash}
    }finally{if($jobLockActive -and $stateWorkspace){try{Set-WsmAssistiveJobLock -Workspace $stateWorkspace -OperationId $plan.TransferId -PairId $plan.PairId -Generation ([int]$plan.Generation) -MaterialIds @($materialIds) -Active $false|Out-Null}catch{}};foreach($name in $driveNames){Remove-PSDrive -Name $name -Force -ErrorAction SilentlyContinue}}
}
function Assert-WsmAssistiveNonCTransferContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransferPlanPath,[Parameter(Mandatory)][string]$TransferPlanHash,[Parameter(Mandatory)][string]$SealedPlanPath,[Parameter(Mandatory)][string]$SealedPlanHash,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ManifestHash,[Parameter(Mandatory)][string]$FreezeEvidencePath,[Parameter(Mandatory)][string]$FreezeEvidenceHash,[switch]$ImportOnly)
    Assert-WsmAssistiveHash $TransferPlanHash 'Transfer plan hash';Assert-WsmAssistiveHash $SealedPlanHash 'Sealed plan hash';Assert-WsmAssistiveHash $ManifestHash 'Manifest hash';Assert-WsmAssistiveHash $FreezeEvidenceHash 'Freeze evidence hash'
    Assert-WsmTrustedFile $SealedPlanPath $SealedPlanHash;$sealed=Read-WsmMigrationPlan $SealedPlanPath $SealedPlanHash;Assert-WsmAssistiveContract $sealed MigrationPlan|Out-Null
    $transfer=Assert-WsmAssistiveNonCPlan $null $TransferPlanPath $TransferPlanHash
    if($transfer.SealedPlanHash -ine $SealedPlanHash -or $transfer.PairId -cne $sealed.PairId -or $transfer.SourceInventoryHash -ine $sealed.Assistive.SourceSnapshotHash -or [int]$transfer.SelectionRevision -ne [int]$sealed.Assistive.SourceSelectionsVersion){throw 'Trusted transfer plan does not match the independently supplied sealed migration plan and current selection.'}
    if($transfer.TargetPhysicalProof.TargetHostId -cne $sealed.Target.HostId -or $transfer.TargetPhysicalProof.ObserverMachineFingerprint -ine $sealed.Target.Fingerprint){throw 'Transfer target proof differs from the host identity in the independently sealed plan.'}
    if($transfer.TargetStateDirectoryIdentity -cne ($sealed.Target.Fingerprint.ToLowerInvariant()+'|'+([string]$transfer.TargetStateDirectory).ToLowerInvariant())){throw 'Target state registry identity differs from the sealed target fingerprint and physical directory.'}
    if(-not $ImportOnly){
        if($transfer.TargetStateDirectoryAccessPath.StartsWith('\\')){$stateMatch=[regex]::Match([string]$transfer.TargetStateDirectoryAccessPath,'^\\([^\\]+)\\([^\\]+)(?:\\|$)');$statePeers=@($transfer.TargetPhysicalProof.PeerShareProofs|Where-Object {$_.PeerName -ieq $stateMatch.Groups[1].Value -and $_.ShareName -ieq $stateMatch.Groups[2].Value -and $_.PeerFingerprint -ceq $sealed.Target.Fingerprint});if($statePeers.Count -ne 1 -or $statePeers[0].ProofHash -ine $transfer.TargetStateDirectoryPeerProofHash){throw 'Target state registry path has no unique exact approved Target SMB proof.'}}
        else{if((Get-WsmAssistiveMachineFingerprint) -ine $sealed.Target.Fingerprint -or (Get-WsmPhysicalPath $transfer.TargetStateDirectoryAccessPath).TrimEnd('\') -ine [string]$transfer.TargetStateDirectory){throw 'Local Target state directory physical proof differs from the sealed target host/path.'}}
    }
    $package=Test-WsmMigrationPackage $ManifestPath $ManifestHash
    if(-not $package.Manifest.Final -or $package.Manifest.PairId -cne $sealed.PairId -or $package.Manifest.PlanHash -ine $SealedPlanHash -or [long]$package.Manifest.Generation -ne [long]$transfer.Generation -or $package.Manifest.FreezeHash -ine $transfer.FreezeProof.FreezeRecordHash){throw 'Transfer requires the exact current final package generation bound to the sealed source plan and freeze record.'}
    if($package.Manifest.SourceInventoryHash -and $package.Manifest.SourceInventoryHash -ine $transfer.SourceInventoryHash){throw 'Final package source inventory differs from the selected transfer source inventory.'}
    $freezePath=Join-Path ([string]$package.Root) 'freeze.json';if(-not [IO.File]::Exists($freezePath)){throw 'Final package is missing its source freeze record.'}
    $freeze=Read-WsmFreezeRecord $freezePath ([string]$package.Manifest.FreezeHash) $sealed $SealedPlanHash
    $evidence=Assert-WsmSourceFreezeEvidence $FreezeEvidencePath $FreezeEvidenceHash $sealed $SealedPlanHash $freeze.FreezeEpoch
    Assert-WsmSourceFreezeEvidenceMatchesAttestation $evidence $freeze
    if($freeze.FreezeId -cne $transfer.FreezeProof.FreezeId -or $freeze.FreezeEpoch -cne $transfer.FreezeEpoch -or $freeze.PairId -cne $transfer.PairId -or $freeze.PlanHash -ine $SealedPlanHash -or $freeze.SourceFreezeEvidence.EvidenceId -cne $transfer.FreezeProof.EvidenceId -or $freeze.SourceFreezeEvidence.SHA256 -ine $FreezeEvidenceHash -or $freeze.SourceFreezeEvidence.WriterSetHash -ine $transfer.FreezeProof.WriterSetHash -or $freeze.SourceFreezeEvidence.Owner -cne $transfer.FreezeProof.Owner){throw 'Transfer package freeze/evidence differs from independently verified source freeze and writer-fence evidence.'}
    $selection=@($sealed.Assistive.ApprovedItemIds|Sort-Object);if(($selection -join '|') -cne (@($transfer.ApprovedItemIds|Sort-Object) -join '|')){throw 'Transfer item selection differs from the sealed approved set.'}
    $items=@{};foreach($item in $sealed.Items){$items[[string]$item.ItemId]=$item}
    foreach($entry in $transfer.Entries){
        if(-not $items.ContainsKey([string]$entry.ItemId) -or $items[[string]$entry.ItemId].Decision -cne 'Include' -or $items[[string]$entry.ItemId].MigrationSpec.Adapter -cne 'FileScope'){throw 'Transfer entry is outside the independently reviewed included FileScope item set.'}
        $proof=@($package.Manifest.SourceCollectionProofs|Where-Object ItemId -CEQ $entry.ItemId);if($proof.Count -ne 1 -or -not $proof[0].NativeVerified -or $proof[0].SourceFingerprint -cne $sealed.Source.Fingerprint -or $proof[0].Channel -cne $transfer.Channel){throw 'Transfer entry lacks a native source collection proof for the sealed source host and channel.'}
        $physical='';if([string]$entry.SourcePath -match '^\\'){$match=[regex]::Match([string]$entry.SourcePath,'^\\\\([^\\]+)\\([^\\]+)');$peers=@($transfer.SourcePeerShareProofs|Where-Object {$_.PeerName -ieq $match.Groups[1].Value -and $_.ShareName -ieq $match.Groups[2].Value -and $_.PeerFingerprint -ceq $entry.SourcePeerFingerprint -and $_.ProofHash -ceq $entry.SourcePeerProofHash});if($peers.Count -ne 1){throw 'Transfer UNC source has no exact trusted source peer proof.'};$physical=Resolve-WsmAssistivePeerPhysicalPath ([string]$entry.SourcePath) $peers[0]}else{if(-not $ImportOnly -and (Get-WsmAssistiveMachineFingerprint) -ine $sealed.Source.Fingerprint){throw 'A local source path is only valid on the sealed source host; use the reviewed source UNC peer proof from the jump host.'};if($ImportOnly){$physical=[IO.Path]::GetFullPath([string]$entry.SourcePath)}else{$physical=Get-WsmPhysicalPath ([string]$entry.SourcePath)}}
        if($ImportOnly){if(-not (Test-WsmAssistivePathWithin ([string]$entry.SourcePath) ([string]$items[[string]$entry.ItemId].MigrationSpec.SourcePath))){throw 'Transfer source path is outside the independently sealed source FileScope.'}}
        elseif(-not (Test-WsmAssistivePathWithin $physical ([string]$proof[0].PhysicalPath))){throw 'Transfer source path is outside its exact sealed native collection scope.'}
        if(-not $ImportOnly -and [string]$entry.TargetPath -notmatch '^\\' -and (Get-WsmAssistiveMachineFingerprint) -ine $sealed.Target.Fingerprint){throw 'A local target path is only valid on the sealed target host; use the reviewed target UNC peer proof from the jump host.'}
        if(-not @($transfer.TargetPhysicalProof.PhysicalIdentities|Where-Object {$_ -ceq $entry.TargetPhysicalIdentity}).Count){throw 'Transfer destination is outside its independently reviewed physical target proof.'}
    }
    [pscustomobject]@{Plan=$transfer;SealedPlan=$sealed;Manifest=$package.Manifest;PackageRoot=$package.Root;Freeze=$freeze;FreezeEvidence=$evidence;TransferPlanPath=[IO.Path]::GetFullPath($TransferPlanPath);TransferPlanHash=$TransferPlanHash.ToLowerInvariant();SealedPlanPath=[IO.Path]::GetFullPath($SealedPlanPath);SealedPlanHash=$SealedPlanHash.ToLowerInvariant();ManifestPath=[IO.Path]::GetFullPath($ManifestPath);ManifestHash=$ManifestHash.ToLowerInvariant();FreezeEvidencePath=[IO.Path]::GetFullPath($FreezeEvidencePath);FreezeEvidenceHash=$FreezeEvidenceHash.ToLowerInvariant()}
}

function Test-WsmAssistivePathWithin([string]$Path,[string]$Root) {
    $pathValue=$Path.TrimEnd('\');$rootValue=$Root.TrimEnd('\')
    $pathValue.Equals($rootValue,[StringComparison]::OrdinalIgnoreCase) -or $pathValue.StartsWith($rootValue+'\',[StringComparison]::OrdinalIgnoreCase)
}

function Get-WsmAssistiveEntryScopeRoot([string]$Path,[string]$RelativePath,[bool]$PathIsExactFile) {
    if($PathIsExactFile -or -not $RelativePath){return [IO.Path]::GetFullPath($Path)}
    $full=[IO.Path]::GetFullPath($Path);$suffix='\'+$RelativePath.TrimStart('\')
    if(-not $full.EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase)){throw 'Expanded entry path does not end in its reviewed relative path.'}
    $full.Substring(0,$full.Length-$suffix.Length)
}

function Get-WsmAssistiveNonCScopeErrors($Transfer,$Sealed,$Manifest) {
    $errors=@{};$items=@{};foreach($item in $Sealed.Items){$items[[string]$item.ItemId]=$item;if($item.Decision -ceq 'Include' -and $item.MigrationSpec.Adapter -ceq 'FileScope' -and $item.MigrationSpec.TransferChannel -ceq $Transfer.Channel){$errors[[string]$item.ItemId]='Selected FileScope item is absent from the reviewed transfer expansion; recreate and review the complete per-entry plan.'}}
    $groups=@($Transfer.Entries|Group-Object ItemId)
    foreach($group in $groups){
        $itemId=[string]$group.Name;if(-not $items.ContainsKey($itemId)){continue};$spec=$items[$itemId].MigrationSpec;$rows=@($group.Group);$sample=$rows[0];$proof=@($Manifest.SourceCollectionProofs|Where-Object ItemId -CEQ $itemId)
        try{
            if($proof.Count -ne 1){throw 'Selected source has no unique frozen physical collection proof.'}
            $sourceIsFile=($sample.OriginalSourcePath -ceq [string]$spec.SourcePath)
            $rootRow=@($rows|Where-Object {$_.EntryType -eq 'Directory' -and -not $_.RelativePath}|Select-Object -First 1)
            if($rootRow.Count){$sourceRoot=[string]$rootRow[0].SourcePath}else{$sourceRoot=Get-WsmAssistiveEntryScopeRoot ([string]$sample.SourcePath) ([string]$sample.RelativePath) $sourceIsFile}
            $sourcePeer=$null;if($sourceRoot -match '^\\'){$endpoint=[regex]::Match($sourceRoot,'^\\([^\]+)\([^\]+)');$peers=@($Transfer.SourcePeerShareProofs|Where-Object {$_.PeerName -ieq $endpoint.Groups[1].Value -and $_.ShareName -ieq $endpoint.Groups[2].Value});if($peers.Count -ne 1){throw 'Source scope has no unique reviewed SMB peer proof.'};$sourcePeer=$peers[0];$sourcePhysical=Resolve-WsmAssistivePeerPhysicalPath $sourceRoot $sourcePeer}else{$sourcePhysical=Get-WsmPhysicalPath $sourceRoot}
            if(-not (Test-WsmAssistivePathWithin $sourcePhysical ([string]$proof[0].PhysicalPath))){throw 'Source scope changed outside the frozen physical collection proof.'}
            $targetIsExactFile=$sourceIsFile;$targetRootRow=@($rows|Where-Object {$_.EntryType -eq 'Directory' -and -not $_.RelativePath}|Select-Object -First 1)
            if($targetRootRow.Count){$targetRoot=[string]$targetRootRow[0].TargetPath}else{$targetRoot=Get-WsmAssistiveEntryScopeRoot ([string]$sample.TargetPath) ([string]$sample.RelativePath) $targetIsExactFile}
            $targetPeers=@($Transfer.TargetPhysicalProof.PeerShareProofs)
            $expanded=@(Get-WsmAssistiveTransferScopeRows -ItemId $itemId -SourceRoot $sourceRoot -TargetRoot $targetRoot -Spec $spec -Channel $Transfer.Channel -ConsumerRefs @($sample.ConsumerRefs) -AccountMap $sample.AccountMap -PeerProof $sourcePeer -TargetPeerProofs $targetPeers -ProviderId ([string]$Transfer.ProviderId) -CollectionPhysicalPath ([string]$proof[0].PhysicalPath))
            if(@($expanded|Where-Object InitialStatus -ne Pending).Count){throw 'A currently selected source file or directory is missing from the frozen scope.'}
            if($expanded.Count -ne $rows.Count){throw 'Live source expansion has added or dropped entries since the reviewed transfer plan was sealed.'}
            $byId=@{};foreach($row in $rows){if($byId.ContainsKey([string]$row.EntryId)){throw 'Transfer plan duplicates a per-entry identity.'};$byId[[string]$row.EntryId]=$row}
            foreach($expected in $expanded){if(-not $byId.ContainsKey([string]$expected.EntryId)) {throw 'Live source expansion contains an entry absent from the reviewed transfer plan.'};$actual=$byId[[string]$expected.EntryId];foreach($field in @('EntryType','RelativePath','SourcePath','OriginalSourcePath','SourceSHA256','Bytes','TargetPath','TargetPhysicalIdentity')){if([string]$actual.$field -cne [string]$expected.$field){throw ('Live source expansion differs from reviewed entry field '+$field+'.')}}}
            $errors.Remove($itemId)
        }catch{$errors[$itemId]='Live source expansion changed or cannot be verified against the frozen reviewed scope; restore the source state or create a newly reviewed transfer plan.'}
    }
    $errors
}

function Invoke-WsmAssistiveNonCTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransferPlanPath,[Parameter(Mandatory)][string]$ExpectedPlanHash,[Parameter(Mandatory)][string]$SealedPlanPath,[Parameter(Mandatory)][string]$SealedPlanHash,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ManifestHash,[Parameter(Mandatory)][string]$FreezeEvidencePath,[Parameter(Mandatory)][string]$FreezeEvidenceHash,[Parameter(Mandatory)][string]$JournalPath,[Parameter(Mandatory)][string]$ResultPath,[Parameter(Mandatory)]$CancellationToken,[PSCredential]$Credential,[PSCredential]$SourceCredential,[PSCredential]$TargetCredential)
    $context=Assert-WsmAssistiveNonCTransferContext -TransferPlanPath $TransferPlanPath -TransferPlanHash $ExpectedPlanHash -SealedPlanPath $SealedPlanPath -SealedPlanHash $SealedPlanHash -ManifestPath $ManifestPath -ManifestHash $ManifestHash -FreezeEvidencePath $FreezeEvidencePath -FreezeEvidenceHash $FreezeEvidenceHash
    [void](Assert-WsmCancellationTokenBinding $CancellationToken $context.Plan.PairId $context.Plan.SealedPlanHash $context.Plan.ManifestHash $context.Plan.TargetStateDirectoryAccessPath)
    $planItemIds=@($context.Plan.Entries|Select-Object -ExpandProperty ItemId -Unique);foreach($selectedId in @($context.SealedPlan.Items|Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq $context.Plan.Channel}|ForEach-Object ItemId)){if($planItemIds -cnotcontains [string]$selectedId){throw 'The transfer plan omits a selected FileScope expansion; no destination writes were started. Recreate and review the complete per-entry plan.'}}
    Invoke-WsmAssistiveNonCTransferCore -TransferPlanPath $TransferPlanPath -ExpectedPlanHash $ExpectedPlanHash -JournalPath $JournalPath -ResultPath $ResultPath -Credential $Credential -SourceCredential $SourceCredential -TargetCredential $TargetCredential -ScopeContext $context -CancellationToken $CancellationToken
}

function Import-WsmAssistiveNonCResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$PlanHash,[Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ManifestHash,[Parameter(Mandatory)][string]$TransferPlanPath,[Parameter(Mandatory)][string]$TransferPlanHash,[Parameter(Mandatory)][int]$Generation,[Parameter(Mandatory)][string]$TargetPhysicalId,[Parameter(Mandatory)][string]$MetadataPolicyHash,[Parameter(Mandatory)][string]$FreezeEpoch,[Parameter(Mandatory)][string]$FreezeEvidencePath,[Parameter(Mandatory)][string]$FreezeEvidenceHash,[Parameter(Mandatory)][string]$ResultPath,[Parameter(Mandatory)][string]$ExpectedResultHash)
    $null=Assert-WsmAssistiveNonCTransferContext -TransferPlanPath $TransferPlanPath -TransferPlanHash $TransferPlanHash -SealedPlanPath $PlanPath -SealedPlanHash $PlanHash -ManifestPath $ManifestPath -ManifestHash $ManifestHash -FreezeEvidencePath $FreezeEvidencePath -FreezeEvidenceHash $FreezeEvidenceHash -ImportOnly
    Assert-WsmAssistiveHash $PlanHash 'Sealed plan hash';Assert-WsmAssistiveHash $ManifestHash 'Manifest hash';Assert-WsmAssistiveHash $MetadataPolicyHash 'Metadata policy hash';Assert-WsmAssistiveHash $ExpectedResultHash 'Result hash'
    Assert-WsmAssistiveHash $TransferPlanHash 'Transfer plan hash';Assert-WsmTrustedFile $PlanPath $PlanHash;$sealed=Read-WsmJson $PlanPath;Assert-WsmEnvelope $sealed MigrationPlan;Assert-WsmAssistiveContract $sealed MigrationPlan | Out-Null
    if($sealed.PairId -cne $PairId){throw 'Trusted sealed plan belongs to a different pair.'}
    $manifestPackage=Test-WsmMigrationPackage $ManifestPath $ManifestHash
    if(-not $manifestPackage.Manifest.Final -or $manifestPackage.Manifest.PairId -cne $PairId -or $manifestPackage.Manifest.PlanHash -ine $PlanHash -or [long]$manifestPackage.Manifest.Generation -ne [long]$Generation){throw 'Manifest is not the current final package generation for the trusted sealed plan.'}
    $transfer=Assert-WsmAssistiveNonCPlan $null $TransferPlanPath $TransferPlanHash
    if($transfer.SealedPlanHash -ine $PlanHash -or $transfer.PairId -cne $PairId -or $transfer.ManifestHash -ine $ManifestHash -or [long]$transfer.Generation -ne [long]$Generation -or $transfer.SourceInventoryHash -ine $sealed.Assistive.SourceSnapshotHash -or [int]$transfer.SelectionRevision -ne [int]$sealed.Assistive.SourceSelectionsVersion){throw 'Transfer plan does not match the current trusted sealed plan selection/material.'}
    if($manifestPackage.Manifest.FreezeHash -ine $transfer.FreezeProof.FreezeRecordHash -or $transfer.FreezeEpoch -cne $FreezeEpoch){throw 'Manager import requires the exact final package freeze epoch and record hash used by the transfer plan.'}
    $packageFreezePath=Join-Path ([string]$manifestPackage.Root) 'freeze.json';if(-not [IO.File]::Exists($packageFreezePath)){throw 'Final package is missing its trusted freeze record.'}
    $packageFreeze=Read-WsmFreezeRecord $packageFreezePath ([string]$manifestPackage.Manifest.FreezeHash) $sealed $PlanHash
    if($packageFreeze.FreezeId -cne $transfer.FreezeProof.FreezeId -or $packageFreeze.FreezeEpoch -cne $transfer.FreezeEpoch -or $packageFreeze.PairId -cne $PairId -or $packageFreeze.PlanHash -ine $PlanHash -or $packageFreeze.SourceFreezeEvidence.EvidenceId -cne $transfer.FreezeProof.EvidenceId -or $packageFreeze.SourceFreezeEvidence.SHA256 -ine $transfer.FreezeProof.EvidenceHash -or $packageFreeze.SourceFreezeEvidence.WriterSetHash -ine $transfer.FreezeProof.WriterSetHash -or $packageFreeze.SourceFreezeEvidence.Owner -cne $transfer.FreezeProof.Owner){throw 'Transfer freeze proof does not match the final package source-freeze and writer-fence evidence.'}
    $sealedIds=@($sealed.Assistive.ApprovedItemIds|Sort-Object);if(($sealedIds -join '|') -cne (@($transfer.ApprovedItemIds|Sort-Object) -join '|')){throw 'Transfer plan selection differs from sealed plan selection.'}
    Assert-WsmTrustedFile $ResultPath $ExpectedResultHash;$result=Read-WsmJson $ResultPath
    if($result.Kind -cne 'AssistiveNonCTransferResult' -or $result.SchemaVersion -ne 3 -or $result.PairId -cne $PairId -or $result.PlanFileHash -ine $TransferPlanHash -or $result.SealedPlanHash -ine $PlanHash -or $result.SelectionRevision -ne $transfer.SelectionRevision -or $result.SelectionHash -ine $transfer.SelectionHash -or $result.SourceInventoryHash -ine $transfer.SourceInventoryHash -or $result.SourceExpansionHash -ine $transfer.SourceExpansionHash -or $result.ManifestHash -ine $ManifestHash -or [long]$result.Generation -ne [long]$Generation -or $result.TargetPhysicalId -cne $TargetPhysicalId -or $result.TargetPhysicalProofHash -ine $transfer.TargetPhysicalProof.ProofHash -or $result.TargetStateDirectory -cne $transfer.TargetStateDirectory -or $result.TargetStateDirectoryIdentity -cne $transfer.TargetStateDirectoryIdentity -or $result.TargetStateDirectoryAccessPath -cne $transfer.TargetStateDirectoryAccessPath -or $result.TargetStateDirectoryPeerProofHash -cne $transfer.TargetStateDirectoryPeerProofHash -or $result.TargetStateDirectoryProofHash -cne $transfer.TargetStateDirectoryProofHash -or $result.MetadataPolicyHash -ine $MetadataPolicyHash -or $result.FreezeEpoch -cne $FreezeEpoch -or $result.FreezeProofHash -ine $transfer.FreezeProof.ProofHash -or $result.TransferId -cne $transfer.TransferId -or $result.Channel -cne $transfer.Channel){throw 'NonC result is forged, stale, replayed against another target, or not bound to the current plan/freeze/material.'}
    $allowed=@{};foreach($entry in $transfer.Entries){$allowed[[string]$entry.EntryId]=$entry};$seen=@{}
    foreach($row in @($result.Rows)){
        if(-not $allowed.ContainsKey([string]$row.EntryId) -or $seen.ContainsKey([string]$row.EntryId) -or @('Applied','BlockedConflict','DeferredManual') -cnotcontains [string]$row.Status){throw 'NonC result contains an unknown, duplicate, or invalid per-entry status row.'}
        $expected=$allowed[[string]$row.EntryId];if($row.ItemId -cne $expected.ItemId -or $row.EntryType -cne $expected.EntryType -or $row.RelativePath -cne $expected.RelativePath -or $row.SourcePath -cne $expected.SourcePath -or $row.OriginalSourcePath -cne $expected.OriginalSourcePath -or $row.SourcePeerFingerprint -cne $expected.SourcePeerFingerprint -or $row.SourcePeerProofHash -cne $expected.SourcePeerProofHash -or $row.TargetPath -cne $expected.TargetPath -or $row.TargetPhysicalIdentity -cne $expected.TargetPhysicalIdentity -or $row.SourceSHA256 -cne $expected.SourceSHA256 -or ($row.ConsumerRefs|ConvertTo-Json -Compress) -cne ($expected.ConsumerRefs|ConvertTo-Json -Compress)){throw 'NonC result row does not match selected per-entry source/target/consumer evidence.'}
        if($row.Status -eq 'Applied') {if(-not $row.Metadata.ReadbackSucceeded -or [long]$row.Bytes -lt 0){throw 'Applied result lacks byte or metadata readback evidence.'};if($expected.EntryType -eq 'File'){Assert-WsmAssistiveHash ([string]$row.SHA256) 'Applied file hash';if($row.SHA256 -ine $expected.SourceSHA256 -or [long]$row.Bytes -ne [long]$expected.Bytes){throw 'Applied file result differs from the independently reviewed source hash or size.'}}elseif($row.SHA256 -or [long]$row.Bytes -ne 0 -or $row.DirectoryCreatedByTransfer -isnot [bool]){throw 'Applied directory result lacks valid directory ownership/readback fields.'}}
        $seen[[string]$row.EntryId]=$true
    }
    if($seen.Count -ne $allowed.Count){throw 'NonC result omitted selected entries.'}
    Assert-WsmAssistiveTargetPhysicalProof $transfer.TargetPhysicalProof $TargetPhysicalId @($transfer.TargetPhysicalProof.PhysicalIdentities)|Out-Null
    if($transfer.TargetPhysicalProof.TargetHostId -cne $sealed.Target.HostId -or $transfer.TargetPhysicalProof.ObserverMachineFingerprint -ine $sealed.Target.Fingerprint){throw 'Imported target physical proof does not match the target HostId and fingerprint sealed in the trusted migration plan.'}
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if($catalog.DecisionRevision -ne $ExpectedRevision -or -not $catalog.Assistive){throw 'Catalog changed or is not in Assistive mode; refresh before importing.'}
        if([int]$catalog.Assistive.Selections.Revision -ne [int]$transfer.SelectionRevision){throw 'Current source selections changed after sealed plan creation; this transfer result is stale.'}
        foreach($prior in @($catalog.Assistive.ResultReferences)){if($prior.PSObject.Properties['TransferId'] -and $prior.TransferId -ceq $result.TransferId){throw 'This NonC transfer result has already been imported.'}}
        if($catalog.Assistive.SourceSnapshot.SHA256 -ine $result.SourceInventoryHash){throw 'Result source inventory is no longer the catalog source.'}
        $relative='assistive/results/'+$ExpectedResultHash.ToLowerInvariant()+'.json';$destination=Join-Path $Workspace ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar));$directory=[IO.Path]::GetDirectoryName($destination);if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory}
        if([IO.File]::Exists($destination)){if((Get-WsmAssistiveNonCHash $destination) -ine $ExpectedResultHash){throw 'Content-addressed result evidence collision.'}}
        else {[IO.File]::Copy([IO.Path]::GetFullPath($ResultPath),$destination);if((Get-WsmAssistiveNonCHash $destination) -ine $ExpectedResultHash){[IO.File]::Delete($destination);throw 'Trusted result changed during durable import.'}}
        $reference=[pscustomobject][ordered]@{Reference=$relative;SHA256=$ExpectedResultHash.ToLowerInvariant();CreatedUtc=(Get-WsmUtc);TransferId=$result.TransferId;PlanHash=$PlanHash.ToLowerInvariant();ManifestHash=$ManifestHash.ToLowerInvariant();Generation=$Generation;TargetPhysicalId=$TargetPhysicalId;MetadataPolicyHash=$MetadataPolicyHash.ToLowerInvariant();FreezeEpoch=$FreezeEpoch;Channel=$result.Channel;Applied=@($result.Rows|Where-Object Status -EQ Applied).Count;BlockedConflict=@($result.Rows|Where-Object Status -EQ BlockedConflict).Count;DeferredManual=@($result.Rows|Where-Object Status -EQ DeferredManual).Count}
        $catalog.Assistive.ResultReferences=@($catalog.Assistive.ResultReferences)+@($reference);$catalog.Assistive.Revision++;$catalog.Assistive.UpdatedUtc=Get-WsmUtc;$catalog.DecisionRevision++;$catalog.Approval=$null
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog;Assert-WsmAssistiveContract $catalog Catalog | Out-Null;$catalog
    }
}
