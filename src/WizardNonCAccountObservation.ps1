# Metadata-only, bounded identity observation for an approved NonC FileScope.
# It never reads file contents and the resulting artifact grants no authority.

function Get-WsmWizardSidObservationName([string]$Sid) {
    try {
        $identity=New-Object Security.Principal.SecurityIdentifier($Sid)
        $name=$identity.Translate([Security.Principal.NTAccount]).Value
        return [string]$name
    } catch { return '' }
}

function Get-WsmWizardNonCIdentityRows($Inventory) {
    @(foreach($item in @($Inventory.Items)){
        if($item.Kind -notin @('LocalUser','LocalGroup')){continue}
        $sid='';$name=[string]$item.Name
        if($item.PSObject.Properties['Settings'] -and $item.Settings){
            if($item.Settings.PSObject.Properties['SID']){$sid=[string]$item.Settings.SID}
            if($item.Settings.PSObject.Properties['Name'] -and $item.Settings.Name){$name=[string]$item.Settings.Name}
        }
        if(-not $sid){$sid=[string]$item.NaturalKey}
        if($sid -notmatch '^S-1-\d+(?:-\d+)+$' -or [string]::IsNullOrWhiteSpace($name)){continue}
        [pscustomobject][ordered]@{identityId=$sid;name=$name;kind=[string]$item.Kind;sid=$sid;stableBuiltin=$false;source='VerifiedInventoryIdentity'}
    })
}

function Get-WsmWizardStableWindowsSidRows([bool]$WindowsObserved) {
    if(-not $WindowsObserved){return @()}
    @(
        [pscustomobject]@{identityId='S-1-5-18';name='SYSTEM';kind='StableWindowsWellKnownSID';sid='S-1-5-18';stableBuiltin=$true}
        [pscustomobject]@{identityId='S-1-5-19';name='LOCAL SERVICE';kind='StableWindowsWellKnownSID';sid='S-1-5-19';stableBuiltin=$true}
        [pscustomobject]@{identityId='S-1-5-20';name='NETWORK SERVICE';kind='StableWindowsWellKnownSID';sid='S-1-5-20';stableBuiltin=$true}
        [pscustomobject]@{identityId='S-1-1-0';name='Everyone';kind='StableWindowsWellKnownSID';sid='S-1-1-0';stableBuiltin=$true}
        [pscustomobject]@{identityId='S-1-5-11';name='Authenticated Users';kind='StableWindowsWellKnownSID';sid='S-1-5-11';stableBuiltin=$true}
        [pscustomobject]@{identityId='S-1-5-32-544';name='Administrators';kind='StableWindowsWellKnownSID';sid='S-1-5-32-544';stableBuiltin=$true}
        [pscustomobject]@{identityId='S-1-5-32-545';name='Users';kind='StableWindowsWellKnownSID';sid='S-1-5-32-545';stableBuiltin=$true}
        [pscustomobject]@{identityId='S-1-5-32-546';name='Guests';kind='StableWindowsWellKnownSID';sid='S-1-5-32-546';stableBuiltin=$true}
    )
}

function Get-WsmWizardNonCSourceProofSet([string]$Workspace,[string]$PairId,$Preparation,$ApprovedPlan,[string]$PrimaryHash,[string[]]$AdditionalHashes=@()) {
    $requested=New-Object 'System.Collections.Generic.List[string]'
    foreach($hash in @($PrimaryHash)+@($AdditionalHashes)){if(-not [string]::IsNullOrWhiteSpace([string]$hash)){$normalized=([string]$hash).Trim().ToLowerInvariant();if(-not $requested.Contains($normalized)){$requested.Add($normalized)}}}
    if(-not $requested.Count){throw 'Choose at least one exact current source peer-share proof.'}
    $options=@($Preparation.ProofOptions|Where-Object kind -CEQ 'SourcePeerShareProof')
    $registry=Get-WsmAssistiveResourceRegistry $Workspace
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($hash in @($requested|Sort-Object)){
        $optionMatches=@($options|Where-Object {$_.sha256 -ieq $hash})
        if($optionMatches.Count -ne 1){throw 'Every selected source peer proof must identify one exact current registered proof option.'}
        $option=$optionMatches[0]
        $referenceMatches=@($registry.Materials|Where-Object {$_.PairId -ceq $PairId -and $_.Path -ieq [string]$option.path -and $_.SHA256 -ieq [string]$option.sha256 -and $_.Kind -ceq 'AssistivePeerShareProof'})
        if($referenceMatches.Count -ne 1){throw 'A selected source peer proof is no longer one exact registered material.'}
        $proof=Read-WsmAssistivePeerShareProof ([string]$option.path) ([string]$option.sha256) ([string]$ApprovedPlan.Plan.Source.Fingerprint)
        if($proof.PeerHostId -cne [string]$ApprovedPlan.Plan.Source.HostId){throw 'Source peer proof host identity differs from the approved source.'}
        $rows.Add([pscustomobject][ordered]@{SHA256=([string]$option.sha256).ToLowerInvariant();Path=[string]$option.path;PeerFingerprint=[string]$proof.PeerFingerprint;PeerHostId=[string]$proof.PeerHostId;ProofHash=[string]$proof.ProofHash;Proof=$proof})
    }
    [pscustomobject]@{Rows=@($rows.ToArray());RegistryRevision=[int]$registry.Revision;Hashes=@($rows|ForEach-Object SHA256|Sort-Object -Unique);ContentHashes=@($rows|ForEach-Object {([string]$_.ProofHash).ToLowerInvariant()}|Sort-Object -Unique)}
}

function Get-WsmWizardNonCSourceProofForCollection($CollectionProof,[object[]]$ProofRows) {
    $matches=New-Object 'System.Collections.Generic.List[object]'
    foreach($row in $ProofRows){$relative=Get-WsmPathRelativeToRoot ([string]$CollectionProof.PhysicalPath) ([string]$row.Proof.LocalPhysicalRoot) -Native;if($null -ne $relative){$matches.Add([pscustomobject]@{Row=$row;RelativePath=[string]$relative})}}
    if($matches.Count -ne 1){return $null}
    $match=$matches[0];$unc='\\'+[string]$match.Row.Proof.PeerName+'\'+[string]$match.Row.Proof.ShareName
    if($match.RelativePath){$unc+='\'+$match.RelativePath}
    [pscustomobject]@{Row=$match.Row;SourceRoot=$unc}
}

function ConvertTo-WsmWizardObservationSid($IdentityReference) {
    $text=[string]$IdentityReference
    if($text -match '^S-1-\d+(?:-\d+)+$'){return $text}
    try{if($IdentityReference -is [Security.Principal.IdentityReference]){return [string]$IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value};return [string](New-Object Security.Principal.NTAccount($text)).Translate([Security.Principal.SecurityIdentifier]).Value}catch{return ''}
}

function Get-WsmWizardNonCObservedAclPrincipals([string]$Path,[hashtable]$Principals) {
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    $ownerSid=ConvertTo-WsmWizardObservationSid $acl.Owner
    $unresolved=0
    if($ownerSid -match '^S-1-\d+(?:-\d+)+$'){
        if(-not $Principals.ContainsKey($ownerSid)){$Principals[$ownerSid]=[ordered]@{SourceSid=$ownerSid;SourceName=(Get-WsmWizardSidObservationName $ownerSid);OwnerObserved=$false;RuleCount=0}}
        $Principals[$ownerSid].OwnerObserved=$true
    }else{$unresolved++}
    foreach($rule in @($acl.Access)){
        $sid=ConvertTo-WsmWizardObservationSid $rule.IdentityReference
        if($sid -notmatch '^S-1-\d+(?:-\d+)+$'){$unresolved++;continue}
        if(-not $Principals.ContainsKey($sid)){$Principals[$sid]=[ordered]@{SourceSid=$sid;SourceName=(Get-WsmWizardSidObservationName $sid);OwnerObserved=$false;RuleCount=0}}
        $Principals[$sid].RuleCount=[int]$Principals[$sid].RuleCount+1
    }
    $unresolved
}

function Get-WsmWizardNonCAccountObservations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$ManifestSelection,
        [Parameter(Mandatory)][string]$SourcePeerProofHash,
        [string[]]$SourcePeerProofHashes=@(),
        [object[]]$Jobs=@(),
        [Parameter(DontShow)]$CancellationToken=$null,
        [Parameter(DontShow)][ValidateRange(1,100000)][int]$MaximumEntries=10000,
        [Parameter(DontShow)][ValidateRange(1,300)][int]$TimeoutSeconds=45
    )
    Assert-WsmId $PairId;Assert-WsmId $OperationId;Assert-WsmCancellationBoundary $CancellationToken 'NonCAccountObservationStart'
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Account observation requires the enrolled Manager workspace.'}
    $catalog=Get-WsmCatalog $Workspace $PairId
    $approved=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $Jobs;if(-not $approved){throw 'A current valid approved plan is required for account observation.'}
    if($CancellationToken){$cancel=Assert-WsmCancellationTokenBinding $CancellationToken $PairId ([string]$approved.SHA256) '' (Join-Path $Workspace 'pairs');if($cancel.OperationId -cne $OperationId){throw 'Cancellation context is bound to another observation operation.'}}
    if($approved.Plan.SchemaVersion -ne 3){throw 'Account observation requires the current reviewed FileScope plan schema.'}
    $preparation=Get-WsmWizardNonCPreparation -Workspace $Workspace -PairId $PairId -Jobs $Jobs -ManifestSelection $ManifestSelection -CancellationToken $CancellationToken
    if($preparation.Status -eq 'NeedsMaterialRepair' -or -not $preparation.Current.ManifestPath){throw 'A uniquely verified current final package is required before account observation.'}
    $sourceProofSet=Get-WsmWizardNonCSourceProofSet $Workspace $PairId $preparation $approved $SourcePeerProofHash $SourcePeerProofHashes
    $proofRows=@($sourceProofSet.Rows)
    $sourceProof=$null;$primaryProofRows=@($proofRows|Where-Object SHA256 -IEQ ([string]$SourcePeerProofHash));if($primaryProofRows.Count -eq 1){$sourceProof=$primaryProofRows[0]}
    if(-not $sourceProof){throw 'The primary source peer proof must remain one exact member of the selected proof set.'}
    $registry=Get-WsmAssistiveResourceRegistry $Workspace
    $package=Test-WsmMigrationPackage -ManifestPath $preparation.Current.ManifestPath -ExpectedHash $preparation.Current.ManifestHash -CancellationToken $CancellationToken
    $sourceInventory=Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.SourceSnapshot Source
    if($sourceInventory.Source.HostId -cne $approved.Plan.Source.HostId -or $sourceInventory.Source.Fingerprint -ine $approved.Plan.Source.Fingerprint){throw 'Current source inventory identity is stale against the approved plan.'}
    if(-not $catalog.Assistive.TargetCurrent){throw 'Capture and bind a current target inventory before account mapping.'}
    $targetInventory=Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.TargetCurrent Target
    if($targetInventory.Source.HostId -cne $approved.Plan.Target.HostId -or $targetInventory.Source.Fingerprint -ine $approved.Plan.Target.Fingerprint){throw 'Current target identity inventory is stale against the approved plan.'}
    $windowsHosts=([string]$sourceInventory.Source.OS -match '(?i)windows' -and [string]$targetInventory.Source.OS -match '(?i)windows')
    $sourceIdentities=@(Get-WsmWizardNonCIdentityRows $sourceInventory);$targetIdentities=@(Get-WsmWizardNonCIdentityRows $targetInventory)
    foreach($identitySet in @('Source','Target')){
        $list=if($identitySet -ceq 'Source'){$sourceIdentities}else{$targetIdentities}
        foreach($builtin in @(Get-WsmWizardStableWindowsSidRows $windowsHosts)){
            if(@($list|Where-Object {$_.sid -ceq [string]$builtin.sid}).Count){continue}
            if($identitySet -ceq 'Source'){$sourceIdentities+=@($builtin)}else{$targetIdentities+=@($builtin)}
        }
    }
    $maximumMilliseconds=[long]$TimeoutSeconds*1000;$watch=[Diagnostics.Stopwatch]::StartNew();$entryResults=New-Object 'System.Collections.Generic.List[object]';$complete=$true;$visited=0;$cancelled=$false;$usedProofHashes=@{}
    $items=@($approved.Plan.Items|Where-Object {$_.Decision -ceq 'Include' -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'})
    try {
    foreach($item in $items){
        Assert-WsmCancellationBoundary $CancellationToken 'NonCAccountObservationItem'
        if($watch.ElapsedMilliseconds -ge $maximumMilliseconds){$complete=$false;break}
        $collection=@($package.Manifest.SourceCollectionProofs|Where-Object {$_.ItemId -ceq [string]$item.ItemId -and $_.NativeVerified -and $_.SourceFingerprint -ceq $approved.Plan.Source.Fingerprint -and $_.Channel -ceq 'NonC'})
        if($collection.Count -ne 1){$complete=$false;$entryResults.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Name=[string]$item.Name;Principals=@();Status='Blocked';Reason='No unique current native source collection proof.';ContentRead=$false});continue}
        $localSource=([string]$approved.Plan.Source.Fingerprint -ieq (Get-WsmAssistiveMachineFingerprint))
        $sourceRoot=''
        if($localSource){$sourceRoot=[IO.Path]::GetFullPath([string]$item.MigrationSpec.SourcePath)}
        $coverage=Get-WsmWizardNonCSourceProofForCollection $collection[0] $proofRows
        if(-not $coverage){$complete=$false;$entryResults.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Name=[string]$item.Name;Principals=@();Status='Blocked';Reason='The selected source peer proofs do not cover this native collection root exactly once.';SourcePeerProofHash='';ContentRead=$false});continue}
        $itemSourceProof=$coverage.Row
        if($localSource){$sourceRoot=[IO.Path]::GetFullPath([string]$item.MigrationSpec.SourcePath)}else{$sourceRoot=$coverage.SourceRoot;Assert-WsmAssistivePeerShareEndpoint -EndpointPath $sourceRoot -Proof $itemSourceProof.Proof -ApprovedPeerFingerprint ([string]$approved.Plan.Source.Fingerprint) | Out-Null}
        $usedProofHashes[$itemSourceProof.SHA256]=$true
        $paths=New-Object 'System.Collections.Generic.List[object]';$spec=$item.MigrationSpec;$excludedRelativePaths=@();if($spec.PSObject.Properties['ExcludedRelativePaths']){$excludedRelativePaths=@($spec.ExcludedRelativePaths)}
        if($spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactFiles'){
            foreach($config in @($spec.ConfigFiles)){
                Assert-WsmRelativePath ([string]$config.RelativePath);$candidate=Join-Path $sourceRoot ([string]$config.RelativePath);$paths.Add([pscustomobject]@{Path=$candidate;Type='File';ExactConfig=$true;SourceRoot=$sourceRoot;RelativePath=[string]$config.RelativePath})
                $parent=[IO.Path]::GetDirectoryName([string]$config.RelativePath);while($parent){$paths.Add([pscustomobject]@{Path=(Join-Path $sourceRoot $parent);Type='Directory';ExactConfig=$true;SourceRoot=$sourceRoot;RelativePath=$parent});$parent=[IO.Path]::GetDirectoryName($parent)}
            }
            if($paths.Count -gt $MaximumEntries){$complete=$false;$entryResults.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Name=[string]$item.Name;Principals=@();Status='Partial';Reason='Approved exact-file list exceeds the bounded identity-observation limit.';ContentRead=$false});break}
            $visited += $paths.Count
        }elseif([IO.Directory]::Exists($sourceRoot)){
            $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($sourceRoot)
            while($stack.Count){
                Assert-WsmCancellationBoundary $CancellationToken 'NonCAccountObservationWalk'
                if($watch.ElapsedMilliseconds -ge $maximumMilliseconds -or $visited -ge $MaximumEntries){$complete=$false;break}
                $directory=$stack.Pop();Assert-WsmAssistiveFileTopologyWithPeers $directory @($itemSourceProof.Proof) -MetadataOnly;$paths.Add([pscustomobject]@{Path=$directory;Type='Directory'});$visited++
                foreach($child in [IO.Directory]::EnumerateFileSystemEntries($directory)){
                    if($watch.ElapsedMilliseconds -ge $maximumMilliseconds -or $visited -ge $MaximumEntries){$complete=$false;break}
                    $childRelative=$child.Substring($sourceRoot.TrimEnd('\').Length).TrimStart('\');$excluded=$false
                    foreach($exclude in $excludedRelativePaths){if($childRelative -ieq [string]$exclude -or $childRelative.StartsWith(([string]$exclude).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$excluded=$true;break}}
                    if($excluded){continue}
                    Assert-WsmAssistiveFileTopologyWithPeers $child @($itemSourceProof.Proof) -MetadataOnly;$paths.Add([pscustomobject]@{Path=$child;Type=$(if([IO.Directory]::Exists($child)){'Directory'}else{'File'})});$visited++
                    if([IO.Directory]::Exists($child)){$stack.Push($child)}
                }
            }
        }elseif([IO.File]::Exists($sourceRoot)){$paths.Add([pscustomobject]@{Path=$sourceRoot;Type='File'})}
        else{$complete=$false;$entryResults.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Name=[string]$item.Name;Principals=@();Status='Missing';Reason='Approved source root is unavailable.';ContentRead=$false});continue}
        $deduped=@{};foreach($row in $paths){$key=[IO.Path]::GetFullPath([string]$row.Path).ToLowerInvariant();if(-not $deduped.ContainsKey($key)){$deduped[$key]=$row}};$paths=@($deduped.Values);if($paths.Count -gt $MaximumEntries){$complete=$false;$entryResults.Add([pscustomobject]@{ItemId=[string]$item.ItemId;Name=[string]$item.Name;Principals=@();Status='Partial';Reason='Approved scope exceeds the bounded identity-observation limit.';ContentRead=$false});break}
        $principals=@{};$unresolvedCount=0;$aclReadFailures=0;$itemComplete=$true;foreach($row in $paths){
            Assert-WsmCancellationBoundary $CancellationToken 'NonCAccountObservationAcl'
            if($watch.ElapsedMilliseconds -ge $maximumMilliseconds){$complete=$false;$itemComplete=$false;break}
            $exists=if($row.Type -ceq 'Directory'){[IO.Directory]::Exists([string]$row.Path)}else{[IO.File]::Exists([string]$row.Path)}
            if(-not $exists){$aclReadFailures++;$complete=$false;$itemComplete=$false;continue}
            if($row.PSObject.Properties['ExactConfig'] -and [bool]$row.ExactConfig){Assert-WsmAssistiveFileTopologyWithPeers -Path ([string]$row.Path) -PeerShareProofs @($itemSourceProof.Proof) -ExactConfig -SourceRoot ([string]$row.SourceRoot) -RelativePath ([string]$row.RelativePath) -MetadataOnly}
            else{Assert-WsmAssistiveFileTopologyWithPeers ([string]$row.Path) @($itemSourceProof.Proof) -MetadataOnly}
            try{$unresolvedCount += [int](Get-WsmWizardNonCObservedAclPrincipals ([string]$row.Path) $principals)}catch{$aclReadFailures++;$complete=$false;$itemComplete=$false}
        }
        $principalRows=@(foreach($sid in @($principals.Keys|Sort-Object)){$trusted=@($sourceIdentities|Where-Object {$_.sid -ceq [string]$sid});$stable=@(Get-WsmWizardStableWindowsSidRows $windowsHosts|Where-Object {$_.sid -ceq [string]$sid});$sourceName=[string]$principals[$sid].SourceName;$nameSource='ManagerNameTranslation';$sourceKind='ObservedAclPrincipal';$identityId=[string]$sid;if($trusted.Count -eq 1){$sourceName=[string]$trusted[0].name;$nameSource='VerifiedSourceInventory';$sourceKind=[string]$trusted[0].kind;$identityId=[string]$trusted[0].identityId}elseif($stable.Count -eq 1){$sourceName=[string]$stable[0].name;$nameSource='ExactWellKnownSid';$sourceKind='StableWindowsWellKnownSID';$identityId=[string]$stable[0].identityId};[pscustomobject][ordered]@{SourceSid=[string]$sid;SourceIdentityId=$identityId;SourceKind=$sourceKind;SourceName=$sourceName;SourceNameSource=$nameSource;OwnerObserved=[bool]$principals[$sid].OwnerObserved;RuleCount=[int]$principals[$sid].RuleCount;DisplayLabel=$(if($sourceName){$sourceName}else{'無法辨識名稱的來源帳號'})}})
        if($unresolvedCount){$complete=$false;$itemComplete=$false}
        $entryResults.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Name=[string]$item.Name;Principals=$principalRows;SourcePeerProofHash=[string]$itemSourceProof.SHA256;SourcePeerProofContentHash=[string]$itemSourceProof.ProofHash;UnresolvedCount=$unresolvedCount;AclReadFailureCount=$aclReadFailures;Status=$(if($itemComplete){'Observed'}else{'ReviewRequired'});Reason=$(if($unresolvedCount){'Some ACL identities could not be resolved to a stable SID; account mapping is incomplete.'}elseif($aclReadFailures){'Some approved paths are unavailable or their ACL could not be read.'}else{'ACL owner and DACL principal identities observed from approved source scope; no file content read.'});ContentRead=$false})
        if(-not $complete){break}
    }
    }catch{if($_.Exception.Data['CancellationRequested']){$cancelled=$true;$complete=$false}else{throw}}
    foreach($proofRow in $proofRows){if(-not $usedProofHashes.ContainsKey([string]$proofRow.SHA256)){throw 'Every selected source peer proof must cover at least one observed included NonC scope.'}}
    $catalogAfter=Get-WsmCatalog $Workspace $PairId;$approvedAfter=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalogAfter $Jobs
    if(-not $approvedAfter -or $approvedAfter.SHA256 -ine $approved.SHA256 -or [int]$catalogAfter.Assistive.Selections.Revision -ne [int]$catalog.Assistive.Selections.Revision -or [string]$catalogAfter.Assistive.TargetCurrent.SHA256 -ine [string]$catalog.Assistive.TargetCurrent.SHA256 -or (Get-WsmAssistiveResourceRegistry $Workspace).Revision -ne $registry.Revision){throw 'Approved inventory, target snapshot or proof materials changed during account observation; rerun it.'}
    $proofBindings=@(foreach($proofRow in @($proofRows|Sort-Object SHA256)){[pscustomobject][ordered]@{SHA256=[string]$proofRow.SHA256;ContentHash=([string]$proofRow.ProofHash).ToLowerInvariant()}})
    $observations=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardNonCAccountObservations';PairId=$PairId;PlanHash=[string]$approved.SHA256;ManifestHash=[string]$preparation.Current.ManifestHash;Generation=[int]$preparation.Current.Generation;InventoryHash=[string]$preparation.Current.InventoryHash;SelectionRevision=[int]$preparation.Current.SelectionRevision;SourcePeerProofHash=$sourceProof.SHA256;SourcePeerProofContentHash=[string]$sourceProof.ProofHash;SourcePeerProofHashes=@($sourceProofSet.Hashes);SourcePeerProofs=$proofBindings;TargetSnapshotHash=[string]$catalog.Assistive.TargetCurrent.SHA256;SourceIdentities=$sourceIdentities;TargetIdentities=$targetIdentities;Entries=$entryResults.ToArray();CoverageComplete=[bool]$complete;VisitedCount=[long]$visited;MaximumEntries=[int]$MaximumEntries;ElapsedMilliseconds=[long]$watch.ElapsedMilliseconds;TimeoutSeconds=[int]$TimeoutSeconds;TimedOut=($watch.ElapsedMilliseconds -ge $maximumMilliseconds);Cancelled=[bool]$cancelled;ContentRead=$false;BackupVerified=$false;AuthoritativeApproval=$false;ProductionVerified=$false;CreatedUtc=(Get-WsmUtc)}
    $base=Get-WsmWizardNonCMaterialRoot $Workspace $PairId;[void](New-WsmOutputOwnedDirectory $base);$directory=Join-Path $base 'account-observations';[void](New-WsmOutputOwnedDirectory $directory);Assert-WsmNoReparse $directory
    $path=Join-Path $directory ($OperationId.ToLowerInvariant()+'.json');if([IO.File]::Exists($path)){throw 'This account observation operation already has a durable output; inspect its job record.'}
    Write-WsmJson $path $observations;$hash=Get-WsmAssistiveNonCHash $path
    [pscustomobject][ordered]@{Kind='WizardNonCAccountObservationResult';Status=$(if($cancelled){'Cancelled'}elseif($complete){'Succeeded'}else{'ReviewRequired'});PairId=$PairId;Path=[IO.Path]::GetFullPath($path);SHA256=$hash;PlanHash=[string]$approved.SHA256;ManifestHash=[string]$preparation.Current.ManifestHash;Generation=[int]$preparation.Current.Generation;InventoryHash=[string]$preparation.Current.InventoryHash;SelectionRevision=[int]$preparation.Current.SelectionRevision;SourcePeerProofHash=$sourceProof.SHA256;SourcePeerProofContentHash=[string]$sourceProof.ProofHash;SourcePeerProofHashes=@($sourceProofSet.Hashes);SourcePeerProofs=$proofBindings;TargetSnapshotHash=[string]$catalog.Assistive.TargetCurrent.SHA256;Entries=$entryResults.ToArray();CoverageComplete=[bool]$complete;VisitedCount=[long]$observations.VisitedCount;ElapsedMilliseconds=[long]$observations.ElapsedMilliseconds;TimeoutSeconds=[int]$TimeoutSeconds;MaximumEntries=[int]$MaximumEntries;TimedOut=[bool]$observations.TimedOut;Cancelled=[bool]$cancelled;ContentRead=$false;BackupVerified=$false;AuthoritativeApproval=$false;ProductionVerified=$false}
}
