# Portable proof handoffs for the existing NonC peer-share and target-physical
# contracts. Observed hashes are metadata only; Manager import always requires
# an independently supplied expected manifest hash.

function Get-WsmWizardNonCProofHandoffHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Assert-WsmWizardNonCProofHandoffDirectory([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not [IO.Directory]::Exists($full)){throw 'Proof handoff directory does not exist.'}
    Assert-WsmNoReparse $full
    $full
}

function Assert-WsmWizardNonCProofHandoffText([string]$Value,[string]$Name,[int]$Maximum=200) {
    if([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $Maximum -or $Value -match '[\x00-\x1f]'){throw ($Name+' must be a concise, explicit value.')}
}

function Test-WsmWizardNonCProofHandoffWithin([string]$Path,[string]$Root) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\');$base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    return ($full -ieq $base -or $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase))
}

function Get-WsmWizardNonCProofHandoffShares([string]$ShareName,[string]$LocalPath,[object[]]$AdditionalShares=@()) {
    $entries=New-Object 'System.Collections.Generic.List[object]'
    $entries.Add([pscustomobject]@{ShareName=$ShareName;LocalPath=$LocalPath})
    foreach($entry in @($AdditionalShares)){
        if(-not $entry -or -not $entry.PSObject.Properties['ShareName'] -or -not $entry.PSObject.Properties['LocalPath']){throw 'AdditionalShares rows must provide explicit ShareName and LocalPath values.'}
        Assert-WsmFields $entry @('ShareName','LocalPath') @('ShareName','LocalPath')
        $entries.Add([pscustomobject]@{ShareName=[string]$entry.ShareName;LocalPath=[string]$entry.LocalPath})
    }
    if($entries.Count -gt 16){throw 'At most 16 explicitly reviewed SMB shares may be included in one proof handoff.'}
    $result=New-Object 'System.Collections.Generic.List[object]';$names=@{};$paths=@{}
    foreach($entry in $entries){
        Assert-WsmWizardNonCProofHandoffText ([string]$entry.ShareName) 'ShareName'
        $name=[string]$entry.ShareName;if($name.Length -gt 80 -or $name -match '[\\/:*?"<>|]'){throw 'ShareName contains characters that cannot identify an existing SMB share.'};$key=$name.ToLowerInvariant()
        if($names.ContainsKey($key)){throw 'ShareName values must be unique, including case-insensitive duplicates.'};$names[$key]=$true
        if([string]::IsNullOrWhiteSpace([string]$entry.LocalPath)){throw 'Every reviewed share must provide an explicit LocalPath.'}
        $path=[IO.Path]::GetFullPath([string]$entry.LocalPath);Assert-WsmNoReparse $path
        if(-not [IO.Directory]::Exists($path)){throw 'Every explicitly reviewed share path must be an existing directory.'}
        $pathKey=$path.TrimEnd('\').ToLowerInvariant();if($paths.ContainsKey($pathKey)){throw 'Share LocalPath values must be unique.'};$paths[$pathKey]=$true
        $result.Add([pscustomobject][ordered]@{Name=$name;LocalPath=$path})
    }
    for($i=0;$i -lt $result.Count;$i++){for($j=$i+1;$j -lt $result.Count;$j++){
        if((Test-WsmWizardNonCProofHandoffWithin $result[$i].LocalPath $result[$j].LocalPath) -or (Test-WsmWizardNonCProofHandoffWithin $result[$j].LocalPath $result[$i].LocalPath)){throw 'Nested or overlapping share roots are ambiguous; choose non-nested explicit shares.'}
    }}
    @($result.ToArray())
}

function Get-WsmWizardNonCProofHandoffShareForPath([string]$Path,[object[]]$Shares) {
    $full=[IO.Path]::GetFullPath($Path);$matches=@($Shares|Where-Object {Test-WsmWizardNonCProofHandoffWithin $full ([string]$_.LocalPath)})
    if($matches.Count -ne 1){throw 'Every reviewed path must be covered by exactly one explicitly declared share.'}
    $matches[0]
}

function Assert-WsmWizardNonCEmbeddedPeerProof($Proof,[string]$ExpectedHostId,[string]$ExpectedFingerprint) {
    if($Proof.Kind -cne 'AssistivePeerShareProof' -or $Proof.PeerHostId -cne $ExpectedHostId -or $Proof.PeerFingerprint -ine $ExpectedFingerprint -or -not $Proof.ShareName -or -not $Proof.PeerName -or -not $Proof.LocalPhysicalRoot -or -not $Proof.Access.Read){throw 'Embedded peer-share proof is not bound to the exact enrolled peer.'}
    Assert-WsmAssistiveHash ([string]$Proof.AccessHash) 'Embedded peer access hash';Assert-WsmAssistiveHash ([string]$Proof.ProofHash) 'Embedded peer proof hash'
    $identity=Get-WsmHashText (($Proof.PeerFingerprint+'|'+$Proof.ShareName.ToLowerInvariant()+'|'+$Proof.LocalPhysicalRoot.ToLowerInvariant()+'|'+$Proof.DirectoryAclSddl+'|'+(@($Proof.ShareAccess) -join ';')+'|'+$Proof.Access.Read+'|'+$Proof.Access.Write+'|'+$Proof.ShareScope.EncryptData+'|'+$Proof.ShareScope.RequireSecuritySignature+'|'+$Proof.ShareScope.EnableSecuritySignature))
    if($identity -ine $Proof.AccessHash){throw 'Embedded peer ACL/access/share proof hash mismatch.'}
    $body=[ordered]@{};foreach($property in $Proof.PSObject.Properties){if($property.Name -cne 'ProofHash'){$body[$property.Name]=$property.Value}}
    if((Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress)) -ine $Proof.ProofHash){throw 'Embedded peer-share proof content hash mismatch.'}
    $true
}

function ConvertTo-WsmWizardNonCTargetUncRoot([string]$LocalRoot,[string]$LocalSharePath,[string]$ShareName,[string]$PeerName) {
    $local=[IO.Path]::GetFullPath($LocalRoot).TrimEnd('\');$share=[IO.Path]::GetFullPath($LocalSharePath).TrimEnd('\')
    if(-not (Test-WsmWizardNonCProofHandoffWithin $local $share)){throw 'Every target root must be inside the explicitly selected existing share root.'}
    $relative=$local.Substring($share.Length).TrimStart('\')
    if($relative -match '(^|\\)\.{1,2}(?:\\|$)'){throw 'Target root contains traversal segments.'}
    $unc='\\'+$PeerName+'\'+$ShareName
    if($relative){$unc=Join-Path $unc $relative}
    [IO.Path]::GetFullPath($unc)
}

function New-WsmWizardNonCProofHandoffManifest {
    param([string]$Role,[string]$Workspace,[string]$NextOperator,[string]$NextAction,[object[]]$Materials,[object[]]$ReviewedRoots=@(),[string]$StateDirectory='',[string]$LocalSharePath='',[string]$ShareName='',[object[]]$Shares=@(),[object[]]$ReviewedRootMappings=@(),[string]$StateShareName='')
    $profile=Read-WsmOutputProfile $Workspace;$identity=Get-WsmMachineIdentity
    if(-not $profile -or $profile.Role -cne $Role -or $identity.Fingerprint -ine $profile.Fingerprint){throw ('Proof handoff must be created on the enrolled '+$Role+' host.')}
    [pscustomobject][ordered]@{
        SchemaVersion=1;Kind='WizardNonCProofHandoff';Role=$Role
        Profile=[pscustomobject][ordered]@{ProfileId=[string]$profile.ProfileId;HostId=[string]$profile.HostId;Fingerprint=[string]$profile.Fingerprint;Name=[string]$identity.Name}
        ToolFingerprint=(Get-WsmToolFingerprint);Materials=@($Materials)
        Share=[pscustomobject][ordered]@{Name=$ShareName;LocalPath=$LocalSharePath}
        Shares=@($Shares)
        ReviewedTargetRoots=@($ReviewedRoots);TargetStateDirectory=$StateDirectory
        ReviewedTargetRootMappings=@($ReviewedRootMappings);TargetStateShareName=$StateShareName
        CreatedUtc=(Get-WsmUtc);CreatedLocal=[DateTimeOffset]::Now.ToString('o');TimeZoneId=[TimeZoneInfo]::Local.Id
        NextOperator=$NextOperator;NextAction=$NextAction;AuthoritativeApproval=$false;ProductionVerified=$false
    }
}

function Write-WsmWizardNonCProofHandoff {
    param([string]$Destination,$Manifest,[object[]]$MaterialFiles)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination)))
    if(-not [IO.Directory]::Exists($parent)){throw 'Choose an existing destination directory for the portable proof handoff.'}
    Assert-WsmNoReparse $parent
    $leaf=[IO.Path]::GetFileName($Destination)
    if(-not $leaf -or $leaf -in @('.','..') -or $leaf -match '[\\/:*?"<>|]'){throw 'Proof handoff destination must be a new simple folder name.'}
    $root=Join-Path $parent $leaf
    if([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)){throw 'Proof handoff destination already exists; choose a new folder.'}
    [void][IO.Directory]::CreateDirectory($root);Assert-WsmNoReparse $root
    try {
        $materialRoot=Join-Path $root 'materials';[void][IO.Directory]::CreateDirectory($materialRoot);Assert-WsmNoReparse $materialRoot
        $rows=New-Object 'System.Collections.Generic.List[object]'
        foreach($entry in $MaterialFiles){
            $name=[string]$entry.Name;if($name -notmatch '^[a-z0-9][a-z0-9-]{0,63}\.json$'){throw 'Proof handoff material has an invalid fixed filename.'}
            $path=Join-Path $materialRoot $name
            Write-WsmJson $path $entry.Data;Assert-WsmNoReparse $path
            $row=[ordered]@{Kind=[string]$entry.Kind;RelativePath=('materials/'+$name);SHA256=(Get-WsmWizardNonCProofHandoffHash $path)}
            if($entry.PSObject.Properties['ShareName']){$row.ShareName=[string]$entry.ShareName}
            $rows.Add([pscustomobject]$row)
        }
        $Manifest.Materials=@($rows.ToArray())
        $manifestPath=Join-Path $root 'manifest.json';Write-WsmJson $manifestPath $Manifest;Assert-WsmNoReparse $manifestPath
        $manifestHash=Get-WsmWizardNonCProofHandoffHash $manifestPath
        [pscustomobject][ordered]@{Kind='WizardNonCProofHandoffExport';Status='Exported';Role=[string]$Manifest.Role;Directory=$root;ManifestPath=$manifestPath;ObservedManifestHash=$manifestHash;Materials=@($Manifest.Materials);HostId=[string]$Manifest.Profile.HostId;Fingerprint=[string]$Manifest.Profile.Fingerprint;NextOperator=[string]$Manifest.NextOperator;NextAction=[string]$Manifest.NextAction;AuthoritativeApproval=$false;ProductionVerified=$false}
    } catch { throw }
}

function Export-WsmWizardNonCSourceProofHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$ShareName,[Parameter(Mandatory)][string]$LocalPath,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$NextOperator,[object[]]$AdditionalShares=@())
    Assert-WsmWizardNonCProofHandoffText $ShareName 'ShareName';Assert-WsmWizardNonCProofHandoffText $NextOperator 'NextOperator'
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Source'){throw 'Source proof handoff requires an enrolled Source workspace.'}
    $shares=@(Get-WsmWizardNonCProofHandoffShares $ShareName $LocalPath $AdditionalShares)
    $identity=Get-WsmMachineIdentity;if($identity.Fingerprint -ine $profile.Fingerprint){throw 'Source machine identity differs from its enrolled workspace.'}
    $tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-nonc-source-proof-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempRoot)
    try {
        $materials=New-Object 'System.Collections.Generic.List[object]';$index=0
        foreach($share in $shares){
            $proof=New-WsmAssistivePeerShareProof -Path $share.LocalPath -ShareName $share.Name -PeerHostId $profile.HostId -ProofPath (Join-Path $tempRoot ('source-peer-proof-'+$index+'.json'))
            if($proof.Proof.PeerFingerprint -ine $profile.Fingerprint){throw 'Source share proof fingerprint differs from the enrolled Source workspace.'}
            $materials.Add([pscustomobject]@{Kind='SourcePeerShareProof';Name=('source-peer-share-'+$index+'.json');ShareName=$share.Name;Data=$proof.Proof});$index++
        }
        $manifest=New-WsmWizardNonCProofHandoffManifest -Role Source -Workspace $Workspace -NextOperator $NextOperator -NextAction 'Manager: verify the Source host and import these existing-share proofs for the current approved migration.' -Materials @() -ShareName $shares[0].Name -LocalSharePath $shares[0].LocalPath -Shares $shares
        Write-WsmWizardNonCProofHandoff $Destination $manifest @($materials.ToArray())
    } finally {if([IO.Directory]::Exists($tempRoot)){Remove-Item -LiteralPath $tempRoot -Recurse -Force}}
}

function Set-WsmWizardNonCReviewedStateDirectory($Proof,[string]$StateDirectory) {
    $Proof | Add-Member NoteProperty ReviewedTargetStateDirectory ([IO.Path]::GetFullPath($StateDirectory)) -Force
    $body=[ordered]@{};foreach($property in $Proof.PSObject.Properties){if($property.Name -cne 'ProofHash'){$body[$property.Name]=$property.Value}}
    $Proof.ProofHash=Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress)
}

function Export-WsmWizardNonCTargetProofHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$ShareName,[Parameter(Mandatory)][string]$LocalPath,[Parameter(Mandatory)][string[]]$LocalRoots,[Parameter(Mandatory)][string]$StateDirectory,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$NextOperator,[object[]]$AdditionalShares=@())
    Assert-WsmWizardNonCProofHandoffText $ShareName 'ShareName';Assert-WsmWizardNonCProofHandoffText $NextOperator 'NextOperator'
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Target'){throw 'Target proof handoff requires an enrolled Target workspace.'}
    if(-not $LocalRoots.Count){throw 'Select at least one reviewed Target local root; no roots are inferred.'}
    $shares=@(Get-WsmWizardNonCProofHandoffShares $ShareName $LocalPath $AdditionalShares);$state=[IO.Path]::GetFullPath($StateDirectory)
    $expectedState=[IO.Path]::GetFullPath((Join-Path $profile.WorkRoot 'pairs'))
    if($state.TrimEnd('\') -ine $expectedState.TrimEnd('\')){throw 'Target StateDirectory must be the enrolled Target WorkRoot\pairs used by the restore workflow; an unrelated transfer state directory cannot authorize restore.'}
    Assert-WsmNoReparse $state;if(-not [IO.Directory]::Exists($state)){throw 'Target StateDirectory must be an existing directory.'}
    $roots=New-Object 'System.Collections.Generic.List[object]';$seenRoots=@{}
    foreach($value in $LocalRoots){$root=[IO.Path]::GetFullPath([string]$value);Assert-WsmNoReparse $root;if(-not [IO.Directory]::Exists($root)){throw 'Every reviewed Target root must be an existing directory.'};$key=$root.TrimEnd('\').ToLowerInvariant();if($seenRoots.ContainsKey($key)){throw 'Target LocalRoots must be unique.'};$seenRoots[$key]=$true;$share=Get-WsmWizardNonCProofHandoffShareForPath $root $shares;$roots.Add([pscustomobject]@{LocalPath=$root;Share=$share})}
    $stateShare=Get-WsmWizardNonCProofHandoffShareForPath $state $shares
    $identity=Get-WsmMachineIdentity;if($identity.Fingerprint -ine $profile.Fingerprint){throw 'Target machine identity differs from its enrolled workspace.'}
    $tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('wsm-nonc-target-proof-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($tempRoot)
    try {
        $peerReferences=New-Object 'System.Collections.Generic.List[object]';$peerByShare=@{};$shareRows=New-Object 'System.Collections.Generic.List[object]';$index=0
        foreach($share in $shares){$peerPath=Join-Path $tempRoot ('target-peer-proof-'+$index+'.json');$peer=New-WsmAssistivePeerShareProof -Path $share.LocalPath -ShareName $share.Name -PeerHostId $profile.HostId -ProofPath $peerPath;if($peer.Proof.PeerFingerprint -ine $profile.Fingerprint){throw 'Target share proof fingerprint differs from the enrolled Target workspace.'};$reference=[pscustomobject]@{Path=$peer.Path;SHA256=$peer.SHA256;PeerFingerprint=$profile.Fingerprint};$peerReferences.Add($reference);$peerByShare[$share.Name.ToLowerInvariant()]=$peer.Proof;$shareRows.Add([pscustomobject][ordered]@{Name=$share.Name;LocalPath=$share.LocalPath});$index++}
        $rootMappings=New-Object 'System.Collections.Generic.List[object]';$uncRoots=New-Object 'System.Collections.Generic.List[string]'
        foreach($root in $roots){$peer=$peerByShare[$root.Share.Name.ToLowerInvariant()];$unc=ConvertTo-WsmWizardNonCTargetUncRoot $root.LocalPath $root.Share.LocalPath $root.Share.Name ([string]$peer.PeerName);$uncRoots.Add($unc);$rootMappings.Add([pscustomobject][ordered]@{LocalPath=$root.LocalPath;ShareName=$root.Share.Name;UNCPath=$unc})}
        $statePeer=$peerByShare[$stateShare.Name.ToLowerInvariant()];$uncState=ConvertTo-WsmWizardNonCTargetUncRoot $state $stateShare.LocalPath $stateShare.Name ([string]$statePeer.PeerName)
        $allRoots=@($uncRoots.ToArray())
        $physical=New-WsmAssistiveTargetPhysicalProof -TargetHostId $profile.HostId -ApprovedTargetRoots $allRoots -PeerShareProofReferences @($peerReferences.ToArray()) -ApprovedPeerFingerprints @($profile.Fingerprint)
        Set-WsmWizardNonCReviewedStateDirectory $physical $uncState
        Assert-WsmAssistiveTargetPhysicalProof $physical $physical.TargetPhysicalId $physical.PhysicalIdentities|Out-Null
        if($physical.ObserverMachineFingerprint -ine $profile.Fingerprint -or $physical.TargetHostId -cne $profile.HostId){throw 'Target physical proof differs from the enrolled Target identity.'}
        $manifest=New-WsmWizardNonCProofHandoffManifest -Role Target -Workspace $Workspace -NextOperator $NextOperator -NextAction 'Manager: verify the Target host and import these exact reviewed roots and StateDirectory before NonC preparation.' -Materials @() -ReviewedRoots $uncRoots.ToArray() -StateDirectory $uncState -ShareName $shares[0].Name -LocalSharePath $shares[0].LocalPath -Shares $shareRows.ToArray() -ReviewedRootMappings $rootMappings.ToArray() -StateShareName $stateShare.Name
        $manifest | Add-Member NoteProperty LocalReviewedTargetRoots @($roots.ToArray()|ForEach-Object {[string]$_.LocalPath})
        $manifest | Add-Member NoteProperty LocalTargetStateDirectory $state
        Write-WsmWizardNonCProofHandoff $Destination $manifest @([pscustomobject]@{Kind='TargetPhysicalProof';Name='target-physical-proof.json';Data=$physical})
    } finally {if([IO.Directory]::Exists($tempRoot)){Remove-Item -LiteralPath $tempRoot -Recurse -Force}}
}

function Get-WsmWizardNonCProofHandoffStage {
    param([string]$Directory,[string]$ExpectedManifestHash)
    Assert-WsmAssistiveHash $ExpectedManifestHash 'Independent proof handoff manifest hash'
    $root=Assert-WsmWizardNonCProofHandoffDirectory $Directory;$manifestPath=Join-Path $root 'manifest.json';Assert-WsmNoReparse $manifestPath
    if(-not [IO.File]::Exists($manifestPath) -or (Get-WsmWizardNonCProofHandoffHash $manifestPath) -ine $ExpectedManifestHash){throw 'Proof handoff manifest bytes differ from the independent expected reference.'}
    $manifest=Read-WsmJson $manifestPath
    if($manifest.SchemaVersion -ne 1 -or $manifest.Kind -cne 'WizardNonCProofHandoff' -or $manifest.Role -cnotin @('Source','Target') -or -not $manifest.Profile -or $manifest.ToolFingerprint -cne (Get-WsmToolFingerprint) -or $manifest.Materials -isnot [array]){throw 'Proof handoff manifest schema/tool binding is invalid.'}
    Assert-WsmId ([string]$manifest.Profile.ProfileId);Assert-WsmId ([string]$manifest.Profile.HostId);Assert-WsmAssistiveHash ([string]$manifest.Profile.Fingerprint) 'Proof handoff host fingerprint'
    Assert-WsmWizardNonCProofHandoffText ([string]$manifest.NextOperator) 'NextOperator';Assert-WsmWizardNonCProofHandoffText ([string]$manifest.NextAction) 'NextAction' 1000
    $shares=@($manifest.Shares)
    if(-not $shares.Count -and $manifest.Share -and $manifest.Share.Name -and $manifest.Share.LocalPath){$shares=@([pscustomobject]@{Name=[string]$manifest.Share.Name;LocalPath=[string]$manifest.Share.LocalPath})}
    if(-not $shares.Count -or $shares.Count -gt 16){throw 'Proof handoff must declare between one and 16 explicit shares.'}
    $normalizedShares=New-Object 'System.Collections.Generic.List[object]';$shareNames=@{};$sharePaths=@{}
    foreach($share in $shares){
        if(-not $share.PSObject.Properties['Name'] -or -not $share.PSObject.Properties['LocalPath']){throw 'Every declared proof share must have Name and LocalPath.'}
        Assert-WsmWizardNonCProofHandoffText ([string]$share.Name) 'ShareName';if(([string]$share.Name).Length -gt 80 -or [string]$share.Name -match '[\\/:*?"<>|]'){throw 'Proof handoff ShareName cannot identify an existing SMB share.'};$key=([string]$share.Name).ToLowerInvariant();if($shareNames.ContainsKey($key)){throw 'Proof handoff declares duplicate share names.'};$shareNames[$key]=$true
        $path=[IO.Path]::GetFullPath([string]$share.LocalPath);$pathKey=$path.TrimEnd('\').ToLowerInvariant();if($sharePaths.ContainsKey($pathKey)){throw 'Proof handoff declares duplicate share paths.'};$sharePaths[$pathKey]=$true
        $normalizedShares.Add([pscustomobject][ordered]@{Name=[string]$share.Name;LocalPath=$path})
    }
    for($i=0;$i -lt $normalizedShares.Count;$i++){for($j=$i+1;$j -lt $normalizedShares.Count;$j++){if((Test-WsmWizardNonCProofHandoffWithin $normalizedShares[$i].LocalPath $normalizedShares[$j].LocalPath) -or (Test-WsmWizardNonCProofHandoffWithin $normalizedShares[$j].LocalPath $normalizedShares[$i].LocalPath)){throw 'Proof handoff declares nested or overlapping share roots.'}}}
    if($manifest.Share.Name -cne $normalizedShares[0].Name -or [IO.Path]::GetFullPath([string]$manifest.Share.LocalPath) -ine $normalizedShares[0].LocalPath){throw 'Legacy primary Share must match the first explicit Shares row.'}
    $materialKinds=@($manifest.Materials|ForEach-Object {[string]$_.Kind})
    if($manifest.Role -ceq 'Source'){
        if($materialKinds.Count -ne $normalizedShares.Count -or @($materialKinds|Where-Object {$_ -cne 'SourcePeerShareProof'}).Count){throw 'Source handoff requires exactly one peer proof per declared share.'}
    }elseif($materialKinds.Count -ne 1 -or $materialKinds[0] -cne 'TargetPhysicalProof'){throw 'Target handoff requires exactly one target physical proof.'}
    $listed=@{};$staged=New-Object 'System.Collections.Generic.List[object]'
    foreach($row in $manifest.Materials){
        foreach($field in @('Kind','RelativePath','SHA256')){if(-not $row.PSObject.Properties[$field]){throw 'Proof handoff material row is incomplete.'}}
        Assert-WsmAssistiveHash ([string]$row.SHA256) 'Proof material hash';$relative=[string]$row.RelativePath
        if($relative -notmatch '^materials/[a-z0-9][a-z0-9-]{0,63}\.json$' -or $relative -match '\.\.|\\'){throw 'Proof material path must be a fixed safe relative file path.'}
        if($listed.ContainsKey($relative)){throw 'Proof handoff contains duplicate material paths.'};$listed[$relative]=$true
        $path=[IO.Path]::GetFullPath((Join-Path $root ($relative.Replace('/','\'))));$prefix=$root.TrimEnd('\')+'\'
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Proof material path escaped its portable handoff directory.'}
        Assert-WsmNoReparse $path;if(-not [IO.File]::Exists($path) -or (Get-WsmWizardNonCProofHandoffHash $path) -ine [string]$row.SHA256){throw 'Proof material is missing or differs from its manifest bytes.'}
        $stagedRow=[ordered]@{Kind=[string]$row.Kind;Path=$path;SHA256=([string]$row.SHA256).ToLowerInvariant()};if($row.PSObject.Properties['ShareName']){$stagedRow.ShareName=[string]$row.ShareName};$staged.Add([pscustomobject]$stagedRow)
    }
    if($manifest.Role -ceq 'Source'){$proofNames=@{};foreach($row in $staged){if(-not $row.ShareName -or -not (@($normalizedShares|Where-Object {$_.Name -ceq [string]$row.ShareName}).Count)){throw 'Every Source peer proof must name one declared share.'};$key=$row.ShareName.ToLowerInvariant();if($proofNames.ContainsKey($key)){throw 'Source handoff contains duplicate proof material for one share.'};$proofNames[$key]=$true};if($proofNames.Count -ne $normalizedShares.Count){throw 'Source handoff omitted a declared share proof.'}}
    # Normalize the provider output to strings before passing it through the
    # path guard. Windows PowerShell can unwrap a single-item directory result
    # in ways that make property access unreliable inside an array expression.
    $directoryPaths=@(Get-ChildItem -LiteralPath $root -Directory -Recurse | ForEach-Object {[string]$_.FullName})
    foreach($directoryPath in $directoryPaths){Assert-WsmNoReparse $directoryPath}
    $materialRoot=Join-Path $root 'materials';Assert-WsmNoReparse $materialRoot
    $actual=@(Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object {$_.FullName.Substring($root.Length+1).Replace('\','/')})|Sort-Object -Unique
    $expected=@(@('manifest.json')+@($listed.Keys|Sort-Object))|Sort-Object -Unique
    if(($actual -join '|') -cne ($expected -join '|')){throw 'Proof handoff directory contains missing or unexpected files.'}
    [pscustomobject]@{Root=$root;Manifest=$manifest;ManifestPath=$manifestPath;ManifestHash=$ExpectedManifestHash.ToLowerInvariant();Shares=@($normalizedShares.ToArray());Materials=@($staged.ToArray())}
}

function Get-WsmWizardNonCProofHandoffPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$ExpectedManifestHash,[object[]]$Jobs=@())
    Assert-WsmId $PairId;$profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Proof handoff import preview requires an enrolled Manager workspace.'}
    $catalog=Get-WsmCatalog $Workspace $PairId;$approved=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $Jobs
    if(-not $approved){throw 'A current approved plan is required before importing Source or Target path proof.'}
    $nonCItems=@($approved.Plan.Items|Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'})
    if(-not $nonCItems.Count){throw 'No included NonC FileScope items require SMB or path proof; this handoff is not applicable to a C-only plan.'}
    $source=Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.SourceSnapshot Source
    $target=if($catalog.Assistive.TargetCurrent){Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.TargetCurrent Target}else{$null}
    if($source.Source.HostId -cne $approved.Plan.Source.HostId -or $source.Source.Fingerprint -ine $approved.Plan.Source.Fingerprint){throw 'Current Source inventory identity differs from the approved plan.'}
    if(-not $target -or $target.Source.HostId -cne $approved.Plan.Target.HostId -or $target.Source.Fingerprint -ine $approved.Plan.Target.Fingerprint){throw 'A current independently registered Target inventory is required; proof import cannot enroll or overwrite inventory.'}
    $stage=Get-WsmWizardNonCProofHandoffStage $Directory $ExpectedManifestHash;$manifest=$stage.Manifest
    if($manifest.ToolFingerprint -cne $approved.Plan.ToolFingerprint){throw 'Proof producer tool fingerprint differs from the approved plan release.'}
    if($manifest.Role -ceq 'Source'){
        if($manifest.Profile.HostId -cne $approved.Plan.Source.HostId -or $manifest.Profile.Fingerprint -ine $approved.Plan.Source.Fingerprint){throw 'Source proof handoff host identity differs from the current approved Source.'}
        $sourcePeerByShare=@{}
        foreach($share in $stage.Shares){$proofRow=@($stage.Materials|Where-Object {$_.Kind -ceq 'SourcePeerShareProof' -and $_.ShareName -ceq $share.Name});if($proofRow.Count -ne 1){throw 'Each declared Source share requires exactly one matching peer proof.'};$sourceProof=Read-WsmAssistivePeerShareProof $proofRow[0].Path $proofRow[0].SHA256 ([string]$approved.Plan.Source.Fingerprint);if($sourceProof.PeerHostId -cne $approved.Plan.Source.HostId -or $sourceProof.ShareName -cne $share.Name -or [IO.Path]::GetFullPath($sourceProof.SharePath) -ine $share.LocalPath){throw 'Source share proof differs from its enrolled host or explicitly reported share.'};$sourcePeerByShare[$share.Name.ToLowerInvariant()]=$sourceProof}
        foreach($item in $nonCItems){$sourcePath=[string]$item.MigrationSpec.SourcePath;$matches=New-Object 'System.Collections.Generic.List[object]';foreach($share in $stage.Shares){$proof=$sourcePeerByShare[$share.Name.ToLowerInvariant()];$uncRoot='\\'+[string]$proof.PeerName+'\'+[string]$share.Name;if((Test-WsmWizardNonCProofHandoffWithin $sourcePath ([string]$share.LocalPath)) -or (Test-WsmWizardNonCProofHandoffWithin $sourcePath $uncRoot)){$matches.Add($share)}};if($matches.Count -ne 1){throw 'Every included NonC SourcePath must be covered by exactly one explicitly reviewed Source share.'}}
    }else{
        if($manifest.Profile.HostId -cne $approved.Plan.Target.HostId -or $manifest.Profile.Fingerprint -ine $approved.Plan.Target.Fingerprint){throw 'Target proof handoff host identity differs from the current approved Target.'}
        $proofRow=@($stage.Materials|Where-Object Kind -CEQ 'TargetPhysicalProof');$targetProof=Read-WsmTrustedJson $proofRow[0].Path $proofRow[0].SHA256
        if($targetProof.TargetHostId -cne $approved.Plan.Target.HostId -or $targetProof.ObserverMachineFingerprint -ine $approved.Plan.Target.Fingerprint){throw 'Target physical proof differs from the current approved Target host.'}
        Assert-WsmAssistiveTargetPhysicalProof $targetProof $targetProof.TargetPhysicalId $targetProof.PhysicalIdentities|Out-Null
        $targetPeers=@($targetProof.PeerShareProofs);if($targetPeers.Count -ne $stage.Shares.Count){throw 'Target physical proof must include exactly one peer-share proof for every declared share.'}
        foreach($share in $stage.Shares){$peerMatches=@($targetPeers|Where-Object {$_.ShareName -ceq $share.Name -and [IO.Path]::GetFullPath([string]$_.SharePath) -ieq $share.LocalPath});if($peerMatches.Count -ne 1){throw 'Target physical proof omitted, duplicated, or changed a declared peer share.'};Assert-WsmWizardNonCEmbeddedPeerProof $peerMatches[0] ([string]$approved.Plan.Target.HostId) ([string]$approved.Plan.Target.Fingerprint)|Out-Null}
        $localRoots=@($manifest.LocalReviewedTargetRoots|ForEach-Object {[IO.Path]::GetFullPath([string]$_)});if(-not $localRoots.Count){throw 'Target handoff does not declare explicit reviewed local roots.'}
        $rootMappings=@($manifest.ReviewedTargetRootMappings);if($rootMappings.Count -ne $localRoots.Count){throw 'Target proof manifest must preserve one explicit share mapping for every local Target root.'}
        $coveredRoots=@($manifest.ReviewedTargetRoots|ForEach-Object {[IO.Path]::GetFullPath([string]$_)});$coveredState=[IO.Path]::GetFullPath([string]$manifest.TargetStateDirectory)
        if($coveredRoots.Count -ne $localRoots.Count){throw 'Target proof manifest omits or adds a reviewed root.'}
        $expectedUnc=New-Object 'System.Collections.Generic.List[string]'
        foreach($root in $localRoots){$share=Get-WsmWizardNonCProofHandoffShareForPath $root $stage.Shares;$mapping=@($rootMappings|Where-Object {[IO.Path]::GetFullPath([string]$_.LocalPath) -ieq $root});if($mapping.Count -ne 1 -or $mapping[0].ShareName -cne $share.Name){throw 'Target root share mapping differs from the unique declared share containing that root.'};$peer=@($targetPeers|Where-Object {$_.ShareName -ceq $share.Name})[0];$unc=ConvertTo-WsmWizardNonCTargetUncRoot $root $share.LocalPath $share.Name ([string]$peer.PeerName);if([IO.Path]::GetFullPath([string]$mapping[0].UNCPath) -ine [IO.Path]::GetFullPath($unc)){throw 'Target local root UNC mapping differs from its exact peer share.'};$expectedUnc.Add($unc)}
        if((@($expectedUnc.ToArray()|Sort-Object -Unique) -join '|') -cne (@($coveredRoots|Sort-Object -Unique) -join '|')){throw 'Target UNC roots do not map exactly to the explicitly reviewed Target local roots.'}
        $localState=[IO.Path]::GetFullPath([string]$manifest.LocalTargetStateDirectory);$stateShare=Get-WsmWizardNonCProofHandoffShareForPath $localState $stage.Shares;if($manifest.TargetStateShareName -cne $stateShare.Name){throw 'Target StateDirectory share mapping differs from the unique declared share containing that state.'};$statePeer=@($targetPeers|Where-Object {$_.ShareName -ceq $stateShare.Name})[0];$expectedState=ConvertTo-WsmWizardNonCTargetUncRoot $localState $stateShare.LocalPath $stateShare.Name ([string]$statePeer.PeerName)
        if($expectedState -ine $coveredState){throw 'Target StateDirectory UNC does not map to the explicitly reviewed local StateDirectory.'}
        foreach($item in $nonCItems){$targetPath=[IO.Path]::GetFullPath([string]$item.MigrationSpec.TargetPath);$matches=@($localRoots|Where-Object {Test-WsmWizardNonCProofHandoffWithin $targetPath $_});if($matches.Count -ne 1){throw 'Every included NonC TargetPath must be covered by exactly one explicitly reviewed Target root.'}}
        $expectedIds=@(foreach($root in $coveredRoots){Get-WsmAssistiveEndpointIdentity $root $targetPeers ([string]$targetProof.ProviderId)});$expectedIds=@($expectedIds|Sort-Object -Unique)
        if(($expectedIds -join '|') -cne (@($targetProof.PhysicalIdentities|Sort-Object -Unique) -join '|')){throw 'Target physical proof identities do not cover exactly the declared data roots.'}
        if(-not $coveredState){throw 'Target proof manifest root projection is incomplete.'}
        if(-not $targetProof.PSObject.Properties['ReviewedTargetStateDirectory'] -or [IO.Path]::GetFullPath([string]$targetProof.ReviewedTargetStateDirectory) -ine $coveredState){throw 'Target physical proof does not bind the exact enrolled state directory declared by this handoff.'}
    }
    $registry=Get-WsmAssistiveResourceRegistry $Workspace;$sourceSelectionRevision=[int]$approved.Plan.Assistive.SourceSelectionsVersion
    $materialRows=@(foreach($material in $stage.Materials){$shareName='';if($material.PSObject.Properties['ShareName']){$shareName=[string]$material.ShareName};[pscustomobject][ordered]@{Kind=[string]$material.Kind;ShareName=$shareName;SHA256=[string]$material.SHA256;Role=[string]$manifest.Role;HostName=[string]$manifest.Profile.Name;HostId=[string]$manifest.Profile.HostId;RootCount=[int]$(if($manifest.Role -ceq 'Target'){@($manifest.ReviewedTargetRoots).Count}else{1})}})
    $binding=[ordered]@{PairId=$PairId;Role=[string]$manifest.Role;ManifestHash=[string]$stage.ManifestHash;PlanHash=[string]$approved.SHA256;SourceHostId=[string]$approved.Plan.Source.HostId;SourceFingerprint=[string]$approved.Plan.Source.Fingerprint;TargetHostId=[string]$approved.Plan.Target.HostId;TargetFingerprint=[string]$approved.Plan.Target.Fingerprint;SourceInventoryHash=[string]$catalog.Assistive.SourceSnapshot.SHA256;TargetInventoryHash=[string]$catalog.Assistive.TargetCurrent.SHA256;SelectionRevision=$sourceSelectionRevision;AssistiveRevision=[int]$catalog.Assistive.Revision;RegistryRevision=[int]$registry.Revision;Shares=@($stage.Shares);ReviewedTargetRootMappings=@($manifest.ReviewedTargetRootMappings);TargetStateShareName=[string]$manifest.TargetStateShareName;Materials=@($materialRows)}
    $previewHash=Get-WsmHashText (ConvertTo-Json -InputObject $binding -Depth 20 -Compress)
    [pscustomobject][ordered]@{Kind='WizardNonCProofHandoffPreview';Status='Ready';PreviewId=$previewHash;PreviewHash=$previewHash;PairId=$PairId;Role=[string]$manifest.Role;ManifestHash=[string]$stage.ManifestHash;ObservedManifestHash=(Get-WsmWizardNonCProofHandoffHash $stage.ManifestPath);PlanHash=[string]$approved.SHA256;SourceHost=[string]$approved.Plan.Source.Name;SourceHostId=[string]$approved.Plan.Source.HostId;TargetHost=[string]$approved.Plan.Target.Name;TargetHostId=[string]$approved.Plan.Target.HostId;SourceInventoryHash=[string]$catalog.Assistive.SourceSnapshot.SHA256;TargetInventoryHash=[string]$catalog.Assistive.TargetCurrent.SHA256;SelectionRevision=$sourceSelectionRevision;AssistiveRevision=[int]$catalog.Assistive.Revision;RegistryRevision=[int]$registry.Revision;Shares=@($stage.Shares);Materials=@($materialRows);ReviewedTargetRoots=@($manifest.ReviewedTargetRoots);ReviewedTargetRootMappings=@($manifest.ReviewedTargetRootMappings);TargetStateDirectory=[string]$manifest.TargetStateDirectory;TargetStateShareName=[string]$manifest.TargetStateShareName;NextOperator=[string]$manifest.NextOperator;NextAction=[string]$manifest.NextAction;CanImport=$true;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Import-WsmWizardNonCProofHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$ExpectedManifestHash,[Parameter(Mandatory)][string]$PreviewId,[object[]]$Jobs=@())
    $preview=Get-WsmWizardNonCProofHandoffPreview -Workspace $Workspace -PairId $PairId -Directory $Directory -ExpectedManifestHash $ExpectedManifestHash -Jobs $Jobs
    if($preview.PreviewId -ine $PreviewId){throw 'Proof handoff changed after preview; import was not committed.'}
    $stage=Get-WsmWizardNonCProofHandoffStage $Directory $ExpectedManifestHash;$profile=Read-WsmOutputProfile $Workspace
    $approved=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile (Get-WsmCatalog $Workspace $PairId) $Jobs
    if(-not $approved -or $approved.SHA256 -ine $preview.PlanHash){throw 'Approved plan changed after proof handoff preview.'}
    $catalog=Get-WsmCatalog $Workspace $PairId
    if([int]$catalog.Assistive.Revision -ne [int]$preview.AssistiveRevision -or [string]$catalog.Assistive.TargetCurrent.SHA256 -ine [string]$preview.TargetInventoryHash -or [string]$catalog.Assistive.SourceSnapshot.SHA256 -ine [string]$preview.SourceInventoryHash){throw 'Current Source selection or Target snapshot changed after proof preview.'}
    $controlRoot=Join-Path $Workspace 'workspace-control'
    $materialsRoot=Join-Path $controlRoot 'wizard-materials'
    # Keep the immutable content-addressed staging path short enough for the
    # Windows PowerShell/.NET Framework file APIs used on supported hosts.
    $handoffsRoot=Join-Path $materialsRoot 'h'
    $root=Join-Path $handoffsRoot $stage.ManifestHash
    [void](New-WsmOutputOwnedDirectory $controlRoot)
    [void](New-WsmOutputOwnedDirectory $materialsRoot)
    [void](New-WsmOutputOwnedDirectory $handoffsRoot)
    [void](New-WsmOutputOwnedDirectory $root)
    if(-not [IO.Directory]::Exists($root)){throw 'Controlled proof handoff staging directory was not created.'}
    $copied=New-Object 'System.Collections.Generic.List[object]'
    foreach($material in $stage.Materials){
        $destination=Join-Path $root (([string]$material.SHA256).ToLowerInvariant()+'.json')
        if(-not [IO.Directory]::Exists($root)){throw 'Controlled proof handoff staging directory disappeared before material copy.'}
        if([IO.File]::Exists($destination)){Assert-WsmTrustedFile $destination $material.SHA256}else{[IO.File]::Copy($material.Path,$destination);if((Get-WsmWizardNonCProofHandoffHash $destination) -ine $material.SHA256){throw 'Staged proof bytes changed during the controlled copy.'}}
        $shareName='';if($material.PSObject.Properties['ShareName']){$shareName=[string]$material.ShareName};Assert-WsmNoReparse $destination;$copied.Add([pscustomobject]@{Kind=[string]$material.Kind;ShareName=$shareName;Path=[IO.Path]::GetFullPath($destination);SHA256=[string]$material.SHA256})
    }
    $manifestDestination=Join-Path $root 'manifest.json'
    if([IO.File]::Exists($manifestDestination)){Assert-WsmTrustedFile $manifestDestination $stage.ManifestHash}else{[IO.File]::Copy($stage.ManifestPath,$manifestDestination);if((Get-WsmWizardNonCProofHandoffHash $manifestDestination) -ine $stage.ManifestHash){throw 'Handoff manifest changed during the controlled copy.'}}
    $consumerRefs=@($approved.Plan.Items|Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'}|ForEach-Object {[string]$_.ItemId}|Sort-Object -Unique)
    if(-not $consumerRefs.Count){throw 'No current NonC consumer remains for proof registration.'}
    $generation=0;$kindMap=@{SourcePeerShareProof='AssistivePeerShareProof';TargetPhysicalProof='AssistiveTargetPhysicalProof'}
    $materialsToRegister=@(foreach($copy in $copied){[pscustomobject]@{Path=[string]$copy.Path;SHA256=[string]$copy.SHA256;Kind=[string]$kindMap[[string]$copy.Kind]}})+@([pscustomobject]@{Path=[string]$manifestDestination;SHA256=[string]$stage.ManifestHash;Kind='WizardNonCProofHandoffManifest'})
    # Files are fully staged and re-hashed before the single locked registry
    # transaction. A failed CAS/write leaves only unregistered owned files.
    Invoke-WsmLocked $Workspace {
        $current=Get-WsmCatalog $Workspace $PairId;$currentApproved=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $current $Jobs
        if(-not $currentApproved -or $currentApproved.SHA256 -ine $preview.PlanHash -or [int]$current.Assistive.Revision -ne [int]$preview.AssistiveRevision -or [string]$current.Assistive.SourceSnapshot.SHA256 -ine [string]$preview.SourceInventoryHash -or [string]$current.Assistive.TargetCurrent.SHA256 -ine [string]$preview.TargetInventoryHash){throw 'Approved plan, selection, or Source/Target inventory changed after proof preview.'}
        $sourceNow=Get-WsmAssistiveSnapshotInventory $Workspace $current.Assistive.SourceSnapshot Source;$targetNow=Get-WsmAssistiveSnapshotInventory $Workspace $current.Assistive.TargetCurrent Target
        if($sourceNow.Source.HostId -cne $currentApproved.Plan.Source.HostId -or $sourceNow.Source.Fingerprint -ine $currentApproved.Plan.Source.Fingerprint -or $targetNow.Source.HostId -cne $currentApproved.Plan.Target.HostId -or $targetNow.Source.Fingerprint -ine $currentApproved.Plan.Target.Fingerprint){throw 'Current Source/Target snapshot identity changed after proof preview.'}
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;if([int]$registry.Revision -ne [int]$preview.RegistryRevision){throw 'Registered materials changed after proof preview; refresh before import.'}
        $index=@{};foreach($existing in $registry.Materials){$index[[string]$existing.MaterialId]=$existing}
        $refs=New-Object 'System.Collections.Generic.List[string]';foreach($material in $materialsToRegister){
            Assert-WsmNoReparse ([string]$material.Path);Assert-WsmTrustedFile ([string]$material.Path) ([string]$material.SHA256)
            $id=Get-WsmHashText ($PairId+'|'+$generation+'|'+([IO.Path]::GetFullPath([string]$material.Path)).ToLowerInvariant()+'|'+([string]$material.SHA256).ToLowerInvariant())
            $consumers=@($consumerRefs);if($index.ContainsKey($id)){$consumers+=@($index[$id].ConsumerRefs)}
            $index[$id]=[pscustomobject][ordered]@{MaterialId=$id;PairId=$PairId;Generation=$generation;Path=[IO.Path]::GetFullPath([string]$material.Path);SHA256=([string]$material.SHA256).ToLowerInvariant();Kind=[string]$material.Kind;ConsumerRefs=@($consumers|Sort-Object -Unique);Closed=$false;RetentionUntilUtc='';RegisteredUtc=(Get-WsmUtc)};$refs.Add($id)
        }
        $registry.Materials=@($index.Values);Write-WsmAssistiveResourceRegistry $Workspace $registry
    }
    [pscustomobject][ordered]@{Kind='WizardNonCProofHandoffImport';Status='ImportedVerified';PairId=$PairId;Role=[string]$stage.Manifest.Role;ManifestHash=[string]$stage.ManifestHash;PlanHash=[string]$preview.PlanHash;SelectionRevision=[int]$preview.SelectionRevision;SourceInventoryHash=[string]$preview.SourceInventoryHash;TargetSnapshotHash=[string]$preview.TargetInventoryHash;Shares=@($stage.Shares);MaterialRefs=@($copied.ToArray()|ForEach-Object {[pscustomobject][ordered]@{Kind=[string]$_.Kind;ShareName=[string]$_.ShareName;Path=[string]$_.Path;SHA256=[string]$_.SHA256;HostId=[string]$stage.Manifest.Profile.HostId;HostName=[string]$stage.Manifest.Profile.Name}});NextOperator=[string]$stage.Manifest.NextOperator;NextAction=[string]$stage.Manifest.NextAction;RegistryRevision=[int](Get-WsmAssistiveResourceRegistry $Workspace).Revision;AuthoritativeApproval=$false;ProductionVerified=$false}
}
