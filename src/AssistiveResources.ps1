function Get-WsmAssistiveResourceRegistryPath([string]$Workspace) {
    Join-Path (Join-Path (Join-Path $Workspace 'assistive') 'resources') 'registry.json'
}

function Get-WsmAssistiveResourceRegistry([string]$Workspace) {
    $path=Get-WsmAssistiveResourceRegistryPath $Workspace
    if(-not [IO.File]::Exists($path)){return [pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveResourceRegistry';Revision=0;Resources=@();Materials=@();LiveJobs=@();UpdatedUtc=(Get-WsmUtc)}}
    $registry=Read-WsmJson $path
    if($registry.SchemaVersion -ne 1 -or $registry.Kind -cne 'AssistiveResourceRegistry' -or $registry.Resources -isnot [array] -or $registry.Materials -isnot [array] -or $registry.LiveJobs -isnot [array]){throw 'Assistive resource registry is malformed; retain it for repair.'}
    $registry
}

function Write-WsmAssistiveResourceRegistry([string]$Workspace,$Registry) {
    $path=Get-WsmAssistiveResourceRegistryPath $Workspace;$directory=[IO.Path]::GetDirectoryName($path)
    if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory}
    $Registry.Revision++;$Registry.UpdatedUtc=Get-WsmUtc;Write-WsmJson $path $Registry
}

function Resolve-WsmAssistivePhysicalResource([string]$Path,[string]$ProviderId,[string]$PeerShareProofPath='',[string]$PeerShareProofHash='',[string]$ApprovedPeerFingerprint='') {
    if([string]::IsNullOrWhiteSpace($Path)){throw 'A resource path is required.'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith('\\')) {
        if(-not $PeerShareProofPath -or -not $PeerShareProofHash -or -not $ApprovedPeerFingerprint){throw 'SMB resource ownership requires a trusted peer-share proof and an operator-reviewed peer fingerprint.'}
        $proof=Read-WsmAssistivePeerShareProof $PeerShareProofPath $PeerShareProofHash $ApprovedPeerFingerprint
        $endpoint=Assert-WsmAssistivePeerShareEndpoint -EndpointPath $full -Proof $proof -ApprovedPeerFingerprint $ApprovedPeerFingerprint -RequireEncrypted ([bool]$proof.ShareScope.EncryptData) -RequireSigned $true
        $physical=$endpoint.ResourceIdentity;$ProviderId='PeerShare:'+ $proof.PeerFingerprint
    } else {
        if(Get-Command Assert-WsmNoReparse -ErrorAction SilentlyContinue){Assert-WsmNoReparse $full}
        if(Get-Command Get-WsmPhysicalPath -ErrorAction SilentlyContinue){$physical=Get-WsmPhysicalPath $full}else{$physical=$full.ToLowerInvariant()}
        $ProviderId='LocalFileSystem'
    }
    [pscustomobject]@{Path=$full;PhysicalIdentity=($ProviderId+'|'+$physical);CanonicalPhysicalPath=$physical;ProviderId=$ProviderId}
}

function Test-WsmAssistiveResourceOverlap([string]$Left,[string]$Right) {
    $peerPattern='^PeerResource\|([^|]+)\|([^|]+)\|(.*)$'
    $leftPeer=[regex]::Match($Left,$peerPattern);$rightPeer=[regex]::Match($Right,$peerPattern)
    if($leftPeer.Success -or $rightPeer.Success){
        if(-not $leftPeer.Success -or -not $rightPeer.Success -or $leftPeer.Groups[1].Value -ine $rightPeer.Groups[1].Value -or $leftPeer.Groups[2].Value -ine $rightPeer.Groups[2].Value){return $false}
        $leftRelative=$leftPeer.Groups[3].Value.TrimEnd('\');$rightRelative=$rightPeer.Groups[3].Value.TrimEnd('\')
        return ($leftRelative -ieq $rightRelative -or $leftRelative.StartsWith($rightRelative+'\',[StringComparison]::OrdinalIgnoreCase) -or $rightRelative.StartsWith($leftRelative+'\',[StringComparison]::OrdinalIgnoreCase))
    }
    Test-WsmPathOverlap $Left $Right
}

function Get-WsmAssistiveTypedResourceIdentity([string]$TargetFingerprint,[string]$ResourceKind,[string]$ResourceName) {
    if($TargetFingerprint -notmatch '^[a-fA-F0-9]{64}$'){throw 'Typed resource ownership requires the trusted target machine fingerprint.'}
    if(@('IISPool','IISSite','IISSection','IISLocation','TaskFolder','ScheduledTask') -cnotcontains $ResourceKind){throw 'Unknown non-file target resource kind.'}
    $name=$ResourceName.Trim();if(-not $name -or $name.Length -gt 512 -or $name -match '[\x00-\x1f]'){throw 'Typed target resource name is empty, too long, or contains control characters.'}
    switch($ResourceKind){
        'TaskFolder' {if($name -notmatch '^\\'){throw 'Task folder identity must be an absolute task path.'};$name='\'+(($name -split '[\\/]+'|Where-Object {$_}) -join '\')}
        'ScheduledTask' {if($name -notmatch '^\\.+\\[^\\]+$'){throw 'Scheduled task identity must include a canonical folder and task leaf.'};$parts=$name -split '[\\/]+'|Where-Object {$_};$name='\'+(@($parts|Select-Object -First ($parts.Count-1)) -join '\')+'\'+$parts[-1]}
        'IISPool' {if($name -match '[\\/]'){throw 'IIS pool identity must be its exact pool name.'}}
        'IISSite' {if($name -notmatch '^(?:id:[0-9]+|name:.+)$'){throw 'IIS site identity must be `id:<numeric>` or `name:<exact>`.'}}
        'IISSection' {if($name -notmatch '^[^/\\]+/[^/\\]+(?:/[^/\\]+)*$'){throw 'IIS section identity must use canonical typed section path segments.'};$name=($name -split '/'|ForEach-Object {$_.ToLowerInvariant()}) -join '/'}
        'IISLocation' {if($name -notmatch '^site:[^|]+\|location:.+$'){throw 'IIS location identity must bind `site:<exact>|location:<exact>`.'}}
    }
    ('TypedTarget|'+$TargetFingerprint.ToLowerInvariant()+'|'+$ResourceKind+'|'+$name.ToLowerInvariant())
}

function Get-WsmAssistiveResourceReservationPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId,[string]$Path='',[Parameter(Mandatory)][ValidateSet('C','NonC')][string]$Channel,[Parameter(Mandatory)][string]$SourceHash,[string]$TargetPhysicalId='',[Parameter(Mandatory)][string[]]$ConsumerRefs,[string]$ProviderId='',[string]$PeerShareProofPath='',[string]$PeerShareProofHash='',[string]$ApprovedPeerFingerprint='',[ValidateSet('FileScope','IISPool','IISSite','IISSection','IISLocation','TaskFolder','ScheduledTask')][string]$ResourceKind='FileScope',[string]$ResourceName='',[string]$TargetFingerprint='', [string]$SealedPlanPath='', [string]$SealedPlanHash='')
    Assert-WsmId $PairId;Assert-WsmAssistiveHash $ItemId 'ItemId';Assert-WsmAssistiveHash $SourceHash 'Source hash'
    if(-not $ConsumerRefs.Count){throw 'At least one consumer reference is required.'}
    if($ResourceKind -eq 'FileScope'){$resource=Resolve-WsmAssistivePhysicalResource $Path $ProviderId $PeerShareProofPath $PeerShareProofHash $ApprovedPeerFingerprint;if($TargetPhysicalId -cne $resource.PhysicalIdentity){throw 'Supplied target physical identity does not match the resolved reviewed resource.'};$resourceName=$resource.Path;$providerIdentity=$resource.ProviderId;$TargetFingerprint=$ApprovedPeerFingerprint;if(-not $Path.StartsWith('\\')){$TargetFingerprint=(Get-WsmMachineIdentity).Fingerprint};if($TargetFingerprint -and $SealedPlanPath -and $SealedPlanHash){$sealedResourcePlan=Read-WsmMigrationPlan $SealedPlanPath $SealedPlanHash;if($sealedResourcePlan.Target.Fingerprint -ine $TargetFingerprint){throw 'FileScope resource proof does not match sealed target identity.'}}elseif($Path.StartsWith('\\')){throw 'Remote FileScope reservation requires trusted sealed plan identity binding.'};$targetIdentity='TargetFile|'+$TargetFingerprint.ToLowerInvariant()+'|'+$resource.CanonicalPhysicalPath}
    else {
        Assert-WsmAssistiveHash $SealedPlanHash 'Sealed plan hash';$plan=Read-WsmMigrationPlan $SealedPlanPath $SealedPlanHash;if(-not $plan.Target -or $plan.Target.Fingerprint -ine $TargetFingerprint){throw 'Typed resource target identity does not match the trusted sealed plan.'};if((Get-WsmMachineIdentity).Fingerprint -cne $TargetFingerprint){throw 'Typed IIS/task resources may only be reserved and written from their proved target host.'};$targetIdentity=Get-WsmAssistiveTypedResourceIdentity $TargetFingerprint $ResourceKind $ResourceName;$resourceName=$ResourceName;$providerIdentity='TypedTarget'
    }
    $registry=Get-WsmAssistiveResourceRegistry $Workspace;$key=Get-WsmHashText $targetIdentity
    $existing=@($registry.Resources|Where-Object ResourceKey -CEQ $key);if($existing.Count -gt 1){throw 'Resource registry contains duplicate physical ownership records.'}
    $conflicts=@();$overlappingRecords=@($registry.Resources|Where-Object {$_.ResourceKind -ceq $ResourceKind -and $_.TargetFingerprint -ceq $TargetFingerprint -and (Test-WsmAssistiveResourceOverlap ([string]$_.CanonicalPhysicalPath) ([string]$(if($ResourceKind -eq 'FileScope'){$resource.CanonicalPhysicalPath}else{$ResourceName})))})
    foreach($rec in $overlappingRecords){foreach($owner in @($rec.Owners)){if($owner.SourceHash -ine $SourceHash -or $owner.ResourceName -cne $resourceName -or $owner.ResourceKind -cne $ResourceKind){$conflicts+=@($owner)}}}
    $canonicalPath=if($ResourceKind -eq 'FileScope'){$resource.CanonicalPhysicalPath}else{$ResourceName}
    $preview=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveResourceReservationPreview';RegistryRevision=$registry.Revision;PairId=$PairId;ItemId=$ItemId.ToLowerInvariant();Channel=$Channel;ResourceKind=$ResourceKind;ResourceName=$resourceName;TargetFingerprint=$TargetFingerprint;ResourceKey=$key;PhysicalIdentity=$targetIdentity;CanonicalPhysicalPath=$canonicalPath;Path=$resourceName;ProviderId=$providerIdentity;SourceHash=$SourceHash.ToLowerInvariant();ConsumerRefs=@($ConsumerRefs|Sort-Object -Unique);ExistingOwners=$(if($existing.Count){@($existing[0].Owners)}else{@()});Conflicts=$conflicts;CanReserve=($conflicts.Count -eq 0);CreatedUtc=(Get-WsmUtc)}
    $preview|Add-Member NoteProperty SHA256 (Get-WsmHashText ($preview|ConvertTo-Json -Depth 20 -Compress));$preview
}

function Reserve-WsmAssistiveResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)]$Preview,[Parameter(Mandatory)][string]$ExpectedPreviewHash,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$Reason)
    Assert-WsmAssistiveHash $ExpectedPreviewHash 'Reservation preview hash';if(-not $Reason.Trim()){throw 'A reservation reason is required.'}
    $unsigned=$Preview.PSObject.Copy();$hash=[string]$unsigned.SHA256;$unsigned.PSObject.Properties.Remove('SHA256');if($hash -ine $ExpectedPreviewHash -or (Get-WsmHashText ($unsigned|ConvertTo-Json -Depth 20 -Compress)) -ine $ExpectedPreviewHash){throw 'Reservation preview hash mismatch.'}
    if(-not $Preview.CanReserve){throw 'Shared target resource has a conflicting owner or source; affected work remains blocked.'}
    Invoke-WsmLocked $Workspace {
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;if($registry.Revision -ne $ExpectedRevision -or $Preview.RegistryRevision -ne $ExpectedRevision){throw 'Resource registry changed; refresh preview before reserving.'}
        $matches=@($registry.Resources|Where-Object ResourceKey -CEQ $Preview.ResourceKey);if($matches.Count -gt 1){throw 'Duplicate physical resource ownership.'}
        if(-not $matches.Count){$record=[pscustomobject][ordered]@{ResourceKey=$Preview.ResourceKey;PhysicalIdentity=$Preview.PhysicalIdentity;CanonicalPhysicalPath=$Preview.CanonicalPhysicalPath;ResourceKind=$Preview.ResourceKind;ResourceName=$Preview.ResourceName;TargetFingerprint=$Preview.TargetFingerprint;Path=$Preview.Path;ProviderId=$Preview.ProviderId;Owners=@();LastReleaseReason='';LastReleaseUtc=''};$registry.Resources=@($registry.Resources)+@($record)}else{$record=$matches[0]}
        foreach($owner in @($record.Owners)){if($owner.SourceHash -ine $Preview.SourceHash -or $owner.ResourceName -cne $Preview.ResourceName -or $owner.ResourceKind -cne $Preview.ResourceKind){throw 'Resource ownership changed while acquiring the reservation.'}}
        $owner=[pscustomobject][ordered]@{PairId=$Preview.PairId;ItemId=$Preview.ItemId;Channel=$Preview.Channel;ResourceKind=$Preview.ResourceKind;ResourceName=$Preview.ResourceName;TargetFingerprint=$Preview.TargetFingerprint;SourceHash=$Preview.SourceHash;ConsumerRefs=@($Preview.ConsumerRefs);Reason=$Reason;ReservedUtc=(Get-WsmUtc);Prior=@();Desired=$null;Readback=$null;Undo=$null;DriftStatus='Unverified';EvidenceHash=''}
        $others=@($record.Owners|Where-Object { $_.PairId -ceq $owner.PairId -and $_.ItemId -ceq $owner.ItemId -and $_.Channel -ceq $owner.Channel });if($others.Count){throw 'This consumer already owns a reservation; reconcile or release it explicitly.'}
        $record.Owners=@($record.Owners)+@($owner);Write-WsmAssistiveResourceRegistry $Workspace $registry
        [pscustomobject]@{ResourceKey=$record.ResourceKey;RegistryRevision=$registry.Revision;Owner=$owner;Reserved=$true}
    }
}

function Set-WsmAssistiveResourceEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$ResourceKey,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId,[Parameter(Mandatory)][string]$Channel,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)]$Prior,[Parameter(Mandatory)]$Desired,[Parameter(Mandatory)]$Readback,[Parameter(Mandatory)]$Undo,[Parameter(Mandatory)][ValidateSet('Match','Drifted','Unknown')][string]$DriftStatus)
    Invoke-WsmLocked $Workspace {
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;if($registry.Revision -ne $ExpectedRevision){throw 'Resource ownership changed; refresh before recording evidence.'}
        $record=@($registry.Resources|Where-Object ResourceKey -CEQ $ResourceKey);if($record.Count -ne 1){throw 'Reserved resource not found uniquely.'}
        $owners=@($record[0].Owners|Where-Object {$_.PairId -ceq $PairId -and $_.ItemId -ceq $ItemId -and $_.Channel -ceq $Channel});if($owners.Count -ne 1){throw 'Resource owner is not reserved by this exact consumer/channel.'}
        $owners[0].Prior=$Prior;$owners[0].Desired=$Desired;$owners[0].Readback=$Readback;$owners[0].Undo=$Undo;$owners[0].DriftStatus=$DriftStatus;$owners[0]|Add-Member NoteProperty EvidenceUtc (Get-WsmUtc) -Force
        $evidence=[ordered]@{ResourceKey=$ResourceKey;PairId=$PairId;ItemId=$ItemId;Channel=$Channel;Prior=$Prior;Desired=$Desired;Readback=$Readback;Undo=$Undo;DriftStatus=$DriftStatus;EvidenceUtc=$owners[0].EvidenceUtc};$owners[0].EvidenceHash=Get-WsmHashText ($evidence|ConvertTo-Json -Depth 25 -Compress)
        Write-WsmAssistiveResourceRegistry $Workspace $registry;$registry
    }
}

function Release-WsmAssistiveResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$ResourceKey,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId,[Parameter(Mandatory)][ValidateSet('C','NonC')][string]$Channel,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$Reason)
    if(-not $Reason.Trim()){throw 'A release reason is required.'}
    Invoke-WsmLocked $Workspace {
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;if($registry.Revision -ne $ExpectedRevision){throw 'Resource registry changed; refresh before release.'}
        $record=@($registry.Resources|Where-Object ResourceKey -CEQ $ResourceKey);if($record.Count -ne 1){throw 'Resource reservation not found uniquely.'}
        $owners=@($record[0].Owners|Where-Object {$_.PairId -ceq $PairId -and $_.ItemId -ceq $ItemId -and $_.Channel -ceq $Channel});if($owners.Count -ne 1){throw 'Exact reservation owner not found.'}
        if($owners[0].DriftStatus -eq 'Unknown' -or $owners[0].DriftStatus -eq 'Drifted'){throw 'Drifted or unknown shared resource must be reconciled before release.'}
        $record[0].Owners=@($record[0].Owners|Where-Object { -not ($_.PairId -ceq $PairId -and $_.ItemId -ceq $ItemId -and $_.Channel -ceq $Channel) });$record[0].LastReleaseReason=$Reason;$record[0].LastReleaseUtc=Get-WsmUtc
        Write-WsmAssistiveResourceRegistry $Workspace $registry;$registry
    }
}

function Register-WsmAssistiveMaterialReference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$Generation,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$SHA256,[Parameter(Mandatory)][string]$Kind,[Parameter(Mandatory)][string[]]$ConsumerRefs,[bool]$Closed=$false,[string]$RetentionUntilUtc='')
    Assert-WsmId $PairId;Assert-WsmAssistiveHash $SHA256 'Material hash';if($Generation -lt 0 -or -not $Kind -or (-not $ConsumerRefs.Count -and (-not $Closed -or -not $RetentionUntilUtc))){throw 'Material needs a generation/type and either current consumers or explicit closed/retention evidence.'}
    $full=[IO.Path]::GetFullPath($Path);if(-not [IO.File]::Exists($full) -or (Get-WsmAssistiveNonCHash $full) -ine $SHA256){throw 'Material bytes are missing or do not match the declared hash.'}
    Invoke-WsmLocked $Workspace {
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;$id=Get-WsmHashText ($PairId+'|'+$Generation+'|'+$full.ToLowerInvariant()+'|'+$SHA256.ToLowerInvariant());$existing=@($registry.Materials|Where-Object MaterialId -CEQ $id)
        $refs=@($ConsumerRefs|Sort-Object -Unique);$wasClosed=$false;$oldExpiry=''
        if($existing.Count){$refs=@(@($existing[0].ConsumerRefs)+$refs|Sort-Object -Unique);$wasClosed=[bool]$existing[0].Closed;$oldExpiry=[string]$existing[0].RetentionUntilUtc;$registry.Materials=@($registry.Materials|Where-Object MaterialId -CNE $id)}
        $entry=[pscustomobject][ordered]@{MaterialId=$id;PairId=$PairId;Generation=$Generation;Path=$full;SHA256=$SHA256.ToLowerInvariant();Kind=$Kind;ConsumerRefs=$refs;Closed=($Closed -and $refs.Count -eq 0 -and ($wasClosed -or $Closed));RetentionUntilUtc=$(if($Closed -and $refs.Count -eq 0){if($RetentionUntilUtc){$RetentionUntilUtc}else{$oldExpiry}}else{''});RegisteredUtc=(Get-WsmUtc)}
        $registry.Materials=@($registry.Materials)+@($entry);Write-WsmAssistiveResourceRegistry $Workspace $registry;$entry
    }
}

function Register-WsmAssistiveMaterialBatch {
    # One graph transaction avoids quadratic registry rewrites for large packages.
    param([string]$Workspace,[string]$PairId,[int]$Generation,[object[]]$Materials,[string[]]$ConsumerRefs)
    Assert-WsmId $PairId;if($Generation -lt 0 -or -not $ConsumerRefs.Count){throw 'Material batch requires a generation and live consumers.'}
    Invoke-WsmLocked $Workspace {
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;$index=@{}
        foreach($existing in $registry.Materials){$index[[string]$existing.MaterialId]=$existing}
        $ids=New-Object 'System.Collections.Generic.List[string]'
        foreach($material in $Materials){
            $full=[IO.Path]::GetFullPath([string]$material.Path);Assert-WsmNoReparse $full;Assert-WsmTrustedFile $full ([string]$material.SHA256)
            if(-not [string]$material.Kind){throw 'Material kind is required.'}
            $hash=([string]$material.SHA256).ToLowerInvariant();$id=Get-WsmHashText ($PairId+'|'+$Generation+'|'+$full.ToLowerInvariant()+'|'+$hash)
            $refs=@($ConsumerRefs);if($index.ContainsKey($id)){$refs+=@($index[$id].ConsumerRefs)}
            $index[$id]=[pscustomobject][ordered]@{MaterialId=$id;PairId=$PairId;Generation=$Generation;Path=$full;SHA256=$hash;Kind=[string]$material.Kind;ConsumerRefs=@($refs|Sort-Object -Unique);Closed=$false;RetentionUntilUtc='';RegisteredUtc=(Get-WsmUtc)}
            $ids.Add($id)
        }
        $registry.Materials=@($index.Values);Write-WsmAssistiveResourceRegistry $Workspace $registry
        [pscustomobject]@{MaterialIds=@($ids.ToArray()|Sort-Object -Unique);RegistryRevision=$registry.Revision}
    }
}

function Set-WsmAssistiveMaterialClosed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$MaterialId,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$RetentionUntilUtc,[string[]]$ConsumerRefs=@())
    if([string]::IsNullOrWhiteSpace($RetentionUntilUtc)){throw 'An approved retention expiry is required before a material can be closed.'};$expiry=[DateTime]::Parse($RetentionUntilUtc).ToUniversalTime()
    Invoke-WsmLocked $Workspace {
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;if($registry.Revision -ne $ExpectedRevision){throw 'Material reference graph changed; refresh before closing material.'}
        $matches=@($registry.Materials|Where-Object MaterialId -CEQ $MaterialId);if($matches.Count -ne 1){throw 'Material reference not found uniquely.'}
        foreach($job in $registry.LiveJobs){if($job.MaterialIds -contains $MaterialId){throw 'Active operation still locks this material.'}}
        if(-not [IO.File]::Exists($matches[0].Path) -or (Get-WsmAssistiveNonCHash $matches[0].Path) -ine $matches[0].SHA256){throw 'Material is missing or drifted; cannot close it.'}
        $matches[0].ConsumerRefs=@($ConsumerRefs|Sort-Object -Unique);$matches[0].Closed=$true;$matches[0].RetentionUntilUtc=$expiry.ToString('o');$matches[0]|Add-Member NoteProperty ClosedUtc (Get-WsmUtc) -Force
        Write-WsmAssistiveResourceRegistry $Workspace $registry;$matches[0]
    }
}

function Set-WsmAssistiveJobLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$OperationId,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][int]$Generation,[Parameter(Mandatory)][string[]]$MaterialIds,[Parameter(Mandatory)][bool]$Active)
    Assert-WsmId $OperationId;Assert-WsmId $PairId
    Invoke-WsmLocked $Workspace {
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;$matches=@($registry.LiveJobs|Where-Object OperationId -CEQ $OperationId)
        if($Active){foreach($id in $MaterialIds){if(-not @($registry.Materials|Where-Object MaterialId -CEQ $id).Count){throw ('Unknown live-job material: '+$id)}};if($matches.Count){throw 'Operation already has a live-material lock.'};$registry.LiveJobs=@($registry.LiveJobs)+@([pscustomobject]@{OperationId=$OperationId;PairId=$PairId;Generation=$Generation;MaterialIds=@($MaterialIds|Sort-Object -Unique);StartedUtc=(Get-WsmUtc)})}
        else {$registry.LiveJobs=@($registry.LiveJobs|Where-Object OperationId -CNE $OperationId)}
        Write-WsmAssistiveResourceRegistry $Workspace $registry;$registry
    }
}

function Get-WsmAssistiveCleanupPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$RetentionBeforeUtc)
    $cutoff=[DateTime]::Parse($RetentionBeforeUtc).ToUniversalTime();$registry=Get-WsmAssistiveResourceRegistry $Workspace;$locked=@{};foreach($job in $registry.LiveJobs){foreach($id in $job.MaterialIds){$locked[[string]$id]=$true}}
    $rows=New-Object System.Collections.Generic.List[object]
    foreach($material in $registry.Materials){
        $refs=@($material.ConsumerRefs);$reason=''
        $physicalPath=if(Get-Command Get-WsmPhysicalPath -ErrorAction SilentlyContinue){Get-WsmPhysicalPath ([IO.Path]::GetFullPath([string]$material.Path))}else{[IO.Path]::GetFullPath([string]$material.Path)}
        $shared=@(foreach($other in $registry.Materials){if($other.MaterialId -cne $material.MaterialId){$otherPath=if(Get-Command Get-WsmPhysicalPath -ErrorAction SilentlyContinue){Get-WsmPhysicalPath ([IO.Path]::GetFullPath([string]$other.Path))}else{[IO.Path]::GetFullPath([string]$other.Path)};if($otherPath -ieq $physicalPath){$other}}})
        if(-not $material.Closed){$reason='Material is not closed.'}
        elseif(-not $material.RetentionUntilUtc){$reason='No approved retention expiry; preserve.'}
        else {try{$expiry=[DateTime]::Parse([string]$material.RetentionUntilUtc).ToUniversalTime();if($expiry -gt $cutoff){$reason='Material is within retention.'}}catch{$reason='Retention evidence is invalid; preserve.'}}
        if(-not $reason -and $refs.Count){$reason='Material still has consumer references.'}
        $sharedHasHold=$false;foreach($other in $shared){$otherExpiry=[DateTime]::MinValue;try{$otherExpiry=[DateTime]::Parse([string]$other.RetentionUntilUtc).ToUniversalTime()}catch{};if(-not $other.Closed -or @($other.ConsumerRefs).Count -or -not $other.RetentionUntilUtc -or $otherExpiry -gt $cutoff){$sharedHasHold=$true}}
        if(-not $reason -and $sharedHasHold){$reason='A cross-pair or cross-generation reference to the same physical material is still live or retained.'}
        if(-not $reason -and $locked.ContainsKey([string]$material.MaterialId)){$reason='Material is locked by an active operation.'}
        if(-not $reason -and (-not [IO.File]::Exists($material.Path) -or (Get-WsmAssistiveNonCHash $material.Path) -ine $material.SHA256)){$reason='Material is missing or has drifted; preserve and investigate.'}
        $rows.Add([pscustomobject]@{MaterialId=$material.MaterialId;Path=$material.Path;SHA256=$material.SHA256;Eligible=([string]::IsNullOrEmpty($reason));Reason=$reason;PairId=$material.PairId;Generation=$material.Generation;Kind=$material.Kind})
    }
    $preview=[pscustomobject][ordered]@{SchemaVersion=1;Kind='AssistiveCleanupPreview';RegistryRevision=$registry.Revision;RetentionBeforeUtc=$cutoff.ToString('o');Rows=$rows.ToArray();CreatedUtc=(Get-WsmUtc)}
    $preview|Add-Member NoteProperty SHA256 (Get-WsmHashText ($preview|ConvertTo-Json -Depth 20 -Compress));$preview
}

function Invoke-WsmAssistiveCleanup {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)]$Preview,[Parameter(Mandatory)][string]$ExpectedPreviewHash,[Parameter(Mandatory)][int]$ExpectedRevision,[Parameter(Mandatory)][string]$Reason,[Parameter(Mandatory)][bool]$Confirmed)
    Assert-WsmAssistiveHash $ExpectedPreviewHash 'Cleanup preview hash';if(-not $Reason.Trim()){throw 'A cleanup reason is required.'};if(-not $Confirmed){throw 'Explicit cleanup confirmation is required.'}
    $unsigned=$Preview.PSObject.Copy();$hash=[string]$unsigned.SHA256;$unsigned.PSObject.Properties.Remove('SHA256');if($hash -ine $ExpectedPreviewHash -or (Get-WsmHashText ($unsigned|ConvertTo-Json -Depth 20 -Compress)) -ine $ExpectedPreviewHash){throw 'Cleanup preview hash mismatch.'}
    Invoke-WsmLocked $Workspace {
        $registry=Get-WsmAssistiveResourceRegistry $Workspace;if($registry.Revision -ne $ExpectedRevision -or $Preview.RegistryRevision -ne $ExpectedRevision){throw 'Cleanup preview is stale; new references or jobs may have appeared. Re-preview before deletion.'}
        $locked=@{};foreach($job in $registry.LiveJobs){foreach($id in $job.MaterialIds){$locked[[string]$id]=$true}}
        $deleted=New-Object System.Collections.Generic.List[object]
        $eligible=@($Preview.Rows|Where-Object Eligible);$groups=@{};foreach($row in $eligible){$physical=if(Get-Command Get-WsmPhysicalPath -ErrorAction SilentlyContinue){Get-WsmPhysicalPath ([IO.Path]::GetFullPath([string]$row.Path))}else{[IO.Path]::GetFullPath([string]$row.Path)};$groups[$physical.ToLowerInvariant()]=$row.Path}
        foreach($physicalKey in $groups.Keys){$path=[string]$groups[$physicalKey];$physical=if(Get-Command Get-WsmPhysicalPath -ErrorAction SilentlyContinue){Get-WsmPhysicalPath ([IO.Path]::GetFullPath($path))}else{[IO.Path]::GetFullPath($path)};$group=@(foreach($material in $registry.Materials){$otherPath=if(Get-Command Get-WsmPhysicalPath -ErrorAction SilentlyContinue){Get-WsmPhysicalPath ([IO.Path]::GetFullPath([string]$material.Path))}else{[IO.Path]::GetFullPath([string]$material.Path)};if($otherPath -ieq $physical){$material}});if(-not $group.Count){throw 'Cleanup material reference disappeared; preserve all materials.'};foreach($material in $group){$expiry=[DateTime]::MinValue;try{$expiry=[DateTime]::Parse([string]$material.RetentionUntilUtc).ToUniversalTime()}catch{};if(@($material.ConsumerRefs).Count -or $locked.ContainsKey([string]$material.MaterialId) -or -not $material.Closed -or $expiry -gt [DateTime]::Parse([string]$Preview.RetentionBeforeUtc).ToUniversalTime() -or -not [IO.File]::Exists($material.Path) -or (Get-WsmAssistiveNonCHash $material.Path) -ine $material.SHA256){throw 'Cleanup recheck found a cross-pair reference, live lock, retention hold or drift; no deletion is safe.'}}
            if($PSCmdlet.ShouldProcess($path,'Delete closed, expired, unreferenced assistive material')){[IO.File]::Delete($path);foreach($material in $group){$deleted.Add($material)}}
        }
        $deletedIds=@{};foreach($m in $deleted){$deletedIds[[string]$m.MaterialId]=$true};$registry.Materials=@($registry.Materials|Where-Object {-not $deletedIds.ContainsKey([string]$_.MaterialId)});if($deleted.Count){$registry|Add-Member NoteProperty LastCleanup ([pscustomobject]@{Reason=$Reason;Deleted=@($deleted|ForEach-Object MaterialId);Utc=(Get-WsmUtc)}) -Force;Write-WsmAssistiveResourceRegistry $Workspace $registry}
        [pscustomobject]@{Deleted=@($deleted|ForEach-Object MaterialId);Retained=@($Preview.Rows|Where-Object {-not $_.Eligible -or -not $deletedIds.ContainsKey([string]$_.MaterialId)}|ForEach-Object MaterialId);RegistryRevision=$registry.Revision;Reason=$Reason}
    }
}
