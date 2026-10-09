function Get-WsmOutputProfileDefaults {
    [pscustomobject]@{ Mode='Zip'; VolumeBytes=[long]536870912 }
}
function Assert-WsmOutputProfileValues($Profile) {
    if($Profile.Mode -cnotin @('Zip','Directory')){throw 'Output profile mode must be Zip or Directory.'}
    if($Profile.Mode -eq 'Zip'){
        $bytes=[long]0
        if(-not [long]::TryParse([string]$Profile.VolumeBytes,[ref]$bytes) -or $bytes -lt 134217728 -or $bytes -gt 1073741824 -or ($bytes % 1048576) -ne 0){throw 'Output profile ZIP volume limit must be a whole MiB from 128 MiB through 1024 MiB.'}
    }elseif([long]$Profile.VolumeBytes -ne 0){throw 'Directory output profiles must use VolumeBytes=0.'}
}
function Get-WsmOutputAttemptId([string]$AttemptId) {
    if(-not $AttemptId){return [Guid]::NewGuid().ToString('D')}
    $parsed=[Guid]::Empty
    if(-not [Guid]::TryParseExact($AttemptId,'D',[ref]$parsed)){throw 'AttemptId must be a GUID.'}
    $parsed.ToString('D')
}
function Assert-WsmOutputControlledPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    Assert-WsmNoReparse $full
    return $full
}
function New-WsmOutputOwnedDirectory([string]$Path) {
    $full=Assert-WsmOutputControlledPath $Path
    if([IO.File]::Exists($full)){throw 'A controlled workspace directory path is occupied by a file.'}
    if(-not [IO.Directory]::Exists($full)){
        [void][IO.Directory]::CreateDirectory($full)
        Protect-WsmDirectory $full
    }else{Assert-WsmCancellationDirectoryProtection $full}
    Assert-WsmNoReparse $full
    return $full
}
function Read-WsmOutputProfile([string]$WorkRoot) {
    if(Get-Command Assert-WsmOutputWorkspaceNotMigrated -ErrorAction SilentlyContinue){Assert-WsmOutputWorkspaceNotMigrated $WorkRoot}
    $path=Join-Path (Join-Path $WorkRoot 'workspace-control') 'output-profile.json'
    if(-not [IO.File]::Exists($path)){return $null}
    Assert-WsmNoReparse $path
    $profile=Read-WsmJson $path
    Assert-WsmEnvelope $profile 'OutputProfile'
    if($profile.ProfileVersion -ne 1 -or $profile.Role -cnotin @('Source','Manager','Target') -or $profile.Fingerprint -notmatch '^[a-f0-9]{64}$') {throw 'Invalid output profile identity or version.'}
    Assert-WsmId ([string]$profile.ProfileId);Assert-WsmId ([string]$profile.HostId)
    Assert-WsmOutputProfileValues $profile
    if([IO.Path]::GetFullPath($profile.WorkRoot) -ine [IO.Path]::GetFullPath($WorkRoot)){throw 'Output profile belongs to a different WorkRoot; explicit migration is required.'}
    return $profile
}
function Get-WsmOutputWorkspaceEstimate([string]$WorkRoot,[long]$MetadataBytes=0,[long]$CopyBytes=0) {
    if($MetadataBytes -lt 0 -or $CopyBytes -lt 0){throw 'Workspace estimate sizes must be nonnegative.'}
    if($MetadataBytes -gt 134217728){throw 'Output metadata estimate exceeds the 128 MiB JSON limit.'}
    $free=[long](Get-WsmAvailableBytes $WorkRoot)
    $required=$MetadataBytes+$CopyBytes
    [pscustomobject]@{Volumes=@([pscustomobject]@{Path=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($WorkRoot));AvailableBytes=$free;PeakAdditionalBytes=$required;Sufficient=($free -ge $required)});MetadataBudgetBytes=[long]134217728;EstimatedMetadataBytes=$MetadataBytes;CleanDirectoryCopyBytes=$CopyBytes;FixedMultiplierUsed=$false}
}
function Get-WsmDirectoryDeliveryEstimate([string]$PackageRoot,[string]$OutputParent,[long]$PackageBytes,[long]$MetadataBytes) {
    $sourceVolume=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($PackageRoot));$outputVolume=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($OutputParent))
    $sourceFree=[long](Get-WsmAvailableBytes $PackageRoot);$outputFree=[long](Get-WsmAvailableBytes $OutputParent)
    if($sourceVolume -ieq $outputVolume){
        $required=$PackageBytes+$MetadataBytes
        $rows=@([pscustomobject]@{Path=$outputVolume;AvailableBytes=$outputFree;ExistingPackageBytes=$PackageBytes;PeakAdditionalBytes=$required;Sufficient=($outputFree -ge $required)})
    }else{
        $rows=@([pscustomobject]@{Path=$sourceVolume;AvailableBytes=$sourceFree;ExistingPackageBytes=$PackageBytes;PeakAdditionalBytes=[long]0;Sufficient=$true},[pscustomobject]@{Path=$outputVolume;AvailableBytes=$outputFree;ExistingPackageBytes=[long]0;PeakAdditionalBytes=($PackageBytes+$MetadataBytes);Sufficient=($outputFree -ge $PackageBytes+$MetadataBytes)})
    }
    [pscustomobject]@{Volumes=$rows;MetadataBudgetBytes=[long]134217728;EstimatedMetadataBytes=$MetadataBytes;CleanDirectoryCopyBytes=$PackageBytes;FixedMultiplierUsed=$false}
}
function Initialize-WsmOutputWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,
        [ValidateSet('Zip','Directory')][string]$Mode,
        [long]$VolumeBytes
    )
    $identity=Get-WsmMachineIdentity
    $root=[IO.Path]::GetFullPath($WorkRoot)
    if(Get-Command Assert-WsmOutputWorkspaceNotMigrated -ErrorAction SilentlyContinue){Assert-WsmOutputWorkspaceNotMigrated $root}
    if([string]::IsNullOrWhiteSpace($WorkRoot) -or $root -eq [IO.Path]::GetPathRoot($root)){throw 'Choose a dedicated controlled WorkRoot below a volume root.'}
    Assert-WsmNoReparse $root
    if(-not [IO.Directory]::Exists($root)){
        [void][IO.Directory]::CreateDirectory($root)
        Protect-WsmDirectory $root
    }
    Assert-WsmNoReparse $root
    $controlRoot=Join-Path $root 'workspace-control'
    Assert-WsmNoReparse $controlRoot
    $profileFile=Join-Path $controlRoot 'output-profile.json'
    if(-not [IO.File]::Exists($profileFile)){
        $priorOwned=@(@('hosts','pairs','targets') | Where-Object {[IO.Directory]::Exists((Join-Path $root $_))})
        $legacyState=@(@('source-state.json','inventory.json','state.json','journal.jsonl','export-state.json','fleet.json') | Where-Object {[IO.File]::Exists((Join-Path $root $_))})
        if($priorOwned.Count -gt 0 -or $legacyState.Count -gt 0 -or ([IO.Directory]::Exists($controlRoot) -and @(Get-ChildItem -LiteralPath $controlRoot -Force).Count -gt 0)){throw 'Workspace profile is missing while tool-owned state remains; restore or explicitly migrate the existing workspace.'}
    }
    [void](New-WsmOutputOwnedDirectory $controlRoot)
    $existing=Read-WsmOutputProfile $root
    if($existing){
        if($existing.Role -cne $Role){throw 'Output profile role mismatch; an explicit workspace migration is required.'}
        if($existing.Fingerprint -cne $identity.Fingerprint){throw 'WorkRoot is enrolled to another host; re-enrollment requires explicit migration.'}
        if($Mode -and $Mode -cne $existing.Mode){throw 'Output profile mode differs; create a new profile through explicit migration.'}
        if($PSBoundParameters.ContainsKey('VolumeBytes') -and [long]$VolumeBytes -ne [long]$existing.VolumeBytes){throw 'Output profile volume limit differs; create a new profile through explicit migration.'}
        $profile=$existing
    }else{
        $defaults=Get-WsmOutputProfileDefaults
        if(-not $Mode){$Mode=$defaults.Mode}
        if($Mode -eq 'Zip'){
            if(-not $PSBoundParameters.ContainsKey('VolumeBytes')){$VolumeBytes=$defaults.VolumeBytes}
        }else{
            if($PSBoundParameters.ContainsKey('VolumeBytes') -and $VolumeBytes -ne 0){throw 'Directory mode does not accept a ZIP volume limit.'}
            $VolumeBytes=0
        }
        $candidate=[pscustomobject]@{Mode=$Mode;VolumeBytes=$VolumeBytes}
        Assert-WsmOutputProfileValues $candidate
        $requestedMode=$Mode;$requestedVolume=[long]$VolumeBytes
        $profile=Invoke-WsmLocked $controlRoot {
            $saved=Read-WsmOutputProfile $root
            if($saved){
                if($saved.Role -cne $Role -or $saved.Fingerprint -cne $identity.Fingerprint){throw 'WorkRoot was concurrently enrolled to another role or host.'}
                if($saved.Mode -cne $requestedMode -or [long]$saved.VolumeBytes -ne $requestedVolume){throw 'WorkRoot was concurrently initialized with another OutputProfile.'}
                $saved
            }else{
                $newProfile=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OutputProfile';ProfileVersion=1;ProfileId=[Guid]::NewGuid().ToString('D');Role=$Role;WorkRoot=$root;Mode=$requestedMode;VolumeBytes=$requestedVolume;Fingerprint=$identity.Fingerprint.ToLowerInvariant();HostId=[Guid]::NewGuid().ToString('D');CreatedUtc=(Get-WsmUtc)}
                Write-WsmJson (Join-Path $controlRoot 'output-profile.json') $newProfile
                $newProfile
            }
        }
    }
    $enrollment=Join-Path $root ('hosts\'+$profile.Fingerprint)
    if($existing -and -not [IO.Directory]::Exists($enrollment)){throw 'Saved host enrollment directory is missing; restore or repair the original workspace state.'}
    [void](New-WsmOutputOwnedDirectory $enrollment)
    $enrollmentPath=Join-Path $enrollment 'enrollment.json'
    if([IO.File]::Exists($enrollmentPath)){
        Assert-WsmNoReparse $enrollmentPath
        $saved=Read-WsmJson $enrollmentPath
        Assert-WsmEnvelope $saved 'HostEnrollment'
        if($saved.Fingerprint -cne $profile.Fingerprint -or $saved.HostId -cne $profile.HostId -or $saved.Role -cne $Role){throw 'Host enrollment does not match the saved profile.'}
    }else{
        if($existing){throw 'Saved host enrollment is missing; restore or repair the original workspace state.'}
        Write-WsmJson $enrollmentPath ([pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='HostEnrollment';Fingerprint=$profile.Fingerprint;HostId=$profile.HostId;Role=$Role;Revision=0;CreatedUtc=(Get-WsmUtc)})
    }
    $inventory=Join-Path $enrollment 'inventory'
    $revision=[long]0
    if($Role -eq 'Source'){
        if($existing -and -not [IO.Directory]::Exists($inventory)){throw 'Saved inventory directory is missing; restore or repair the original source workspace.'}
        [void](New-WsmOutputOwnedDirectory $inventory)
        $sourceStatePath=Join-Path $inventory 'source-state.json'
        if([IO.File]::Exists($sourceStatePath)){
            Assert-WsmNoReparse $sourceStatePath
            $sourceState=Read-WsmJson $sourceStatePath
            if($sourceState.Fingerprint -cne $profile.Fingerprint -or $sourceState.HostId -cne $profile.HostId -or $sourceState.Revision -lt 0){throw 'Source state does not match this enrollment; restore or repair existing state.'}
            $revision=[long]$sourceState.Revision
        }else{
            if($existing){throw 'Saved source state is missing; restore or repair the original inventory state.'}
            Write-WsmJson $sourceStatePath ([pscustomobject][ordered]@{HostId=$profile.HostId;Fingerprint=$profile.Fingerprint;Revision=0})
        }
    }
    $pairs=Join-Path $root 'pairs'
    if($existing -and $Role -in @('Manager','Target') -and -not [IO.Directory]::Exists($pairs)){throw 'Saved pair state directory is missing; restore or repair the original workspace.'}
    if($Role -in @('Manager','Target')){[void](New-WsmOutputOwnedDirectory $pairs)}
    $targetIdentity=$null
    if($Role -eq 'Target'){
        $targetRoot=Join-Path $root ('targets\'+$profile.HostId)
        if($existing -and -not [IO.Directory]::Exists($targetRoot)){throw 'Saved target registration directory is missing; restore or repair the original target workspace.'}
        [void](New-WsmOutputOwnedDirectory $targetRoot)
        $targetPath=Join-Path $targetRoot 'target-identity.json'
        if([IO.File]::Exists($targetPath)){
            Assert-WsmNoReparse $targetPath
            $targetIdentity=Read-WsmJson $targetPath;Assert-WsmEnvelope $targetIdentity 'TargetIdentity'
            if($targetIdentity.Fingerprint -cne $profile.Fingerprint -or $targetIdentity.HostId -cne $profile.HostId){throw 'Saved target identity differs from enrolled host; restore the existing registration.'}
        }else{
            if($existing){throw 'Saved target identity is missing; restore or repair the original target registration.'}
            $targetIdentity=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='TargetIdentity';HostId=$profile.HostId;Fingerprint=$profile.Fingerprint;Name=$identity.Name;OS=$identity.OS;Version=$identity.Version;CreatedUtc=(Get-WsmUtc)}
            Write-WsmJson $targetPath $targetIdentity
        }
    }
    $estimate=Get-WsmOutputWorkspaceEstimate $root 4096 0
    [pscustomobject]@{Profile=$profile;HostId=$profile.HostId;Revision=$revision;EnrollmentId=$profile.Fingerprint;EnrollmentRoot=$enrollment;InventoryDirectory=$inventory;StateDirectory=$pairs;PairRoot=$null;TargetIdentity=$targetIdentity;AttemptRoot=$null;ReportsDirectory=$null;PackagesDirectory=$null;TransportDirectory=$null;ScratchDirectory=$null;Estimate=$estimate;UsesAttemptIdForOperationState=$false}
}
function Register-WsmOutputPair {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$PlanHash)
    Assert-WsmId $PairId
    if($PlanHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'A trusted plan SHA256 is required for pair registration.'}
    $workspace=Initialize-WsmOutputWorkspace $WorkRoot $Role
    $pairRoot=Join-Path $workspace.StateDirectory $PairId
    [void](New-WsmOutputOwnedDirectory $workspace.StateDirectory)
    $registryRoot=Join-Path $workspace.EnrollmentRoot 'pair-bindings'
    [void](New-WsmOutputOwnedDirectory $registryRoot)
    $bindingPath=Join-Path $registryRoot ($PairId+'.json')
    $prior=$null
    if([IO.File]::Exists($bindingPath)){
        Assert-WsmNoReparse $bindingPath
        $prior=Read-WsmJson $bindingPath;Assert-WsmEnvelope $prior 'OutputPairBinding'
        if($prior.Role -cne $Role -or $prior.HostId -cne $workspace.HostId -or $prior.Fingerprint -cne $workspace.Profile.Fingerprint -or $prior.PairId -cne $PairId){throw 'Existing pair binding belongs to another host or role.'}
        if($prior.PlanHash -ine $PlanHash){throw 'Pair is already bound to another approved plan; reconcile old operation ownership before creating a new mapping.'}
        if(-not [IO.Directory]::Exists($pairRoot)){throw 'Registered pair state is missing; recover or repair the original state before continuing.'}
        if($prior.PSObject.Properties['StateInitialized'] -and $prior.StateInitialized -and -not [IO.File]::Exists((Join-Path $pairRoot 'state.json'))){throw 'Previously registered operation state is missing; recover or repair the original state before continuing.'}
        if([IO.File]::Exists((Join-Path $pairRoot 'journal.jsonl')) -and -not [IO.File]::Exists((Join-Path $pairRoot 'state.json'))){throw 'Registered operation journal exists without its checkpoint; repair the original operation before continuing.'}
    }else{
        if([IO.Directory]::Exists($pairRoot) -or [IO.File]::Exists($pairRoot)){throw 'Pair operation path already exists without a trusted registration; inspect and recover it before use.'}
        $prior=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OutputPairBinding';Role=$Role;HostId=$workspace.HostId;Fingerprint=$workspace.Profile.Fingerprint;PairId=$PairId;PlanHash=$PlanHash.ToLowerInvariant();CreatedUtc=(Get-WsmUtc)}
        Write-WsmJson $bindingPath $prior
        [void](New-WsmOutputOwnedDirectory $pairRoot)
    }
    $workspace.PairRoot=$pairRoot
    $workspace | Add-Member NoteProperty PairBinding $prior -Force
    $workspace.StateDirectory=Join-Path $workspace.Profile.WorkRoot 'pairs'
    $workspace
}
function Confirm-WsmOutputOperationState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$PlanHash)
    $workspace=Register-WsmOutputPair $WorkRoot $Role $PairId $PlanHash
    $statePath=Join-Path $workspace.PairRoot 'state.json'
    if(-not [IO.File]::Exists($statePath)){throw 'Operation state cannot be registered before its durable checkpoint exists.'}
    Assert-WsmNoReparse $statePath
    $state=Read-WsmJson $statePath;Assert-WsmEnvelope $state 'OperationState'
    if($state.PairId -cne $PairId -or $state.PlanHash -ine $PlanHash -or $state.TargetFingerprint -cne $workspace.Profile.Fingerprint){throw 'Operation checkpoint belongs to a different pair, plan or target.'}
    $bindingPath=Join-Path (Join-Path $workspace.EnrollmentRoot 'pair-bindings') ($PairId+'.json')
    $binding=Read-WsmJson $bindingPath;$binding | Add-Member NoteProperty StateInitialized $true -Force;$binding | Add-Member NoteProperty StateRegisteredUtc (Get-WsmUtc) -Force
    Write-WsmJson $bindingPath $binding
    [pscustomobject]@{PairId=$PairId;PlanHash=$PlanHash.ToLowerInvariant();StatePath=$statePath;StateInitialized=$true}
}
function Confirm-WsmOutputStateCheckpoint {
    param([string]$StateDirectory,[string]$PairId,[string]$PlanHash)
    $stateRoot=[IO.Path]::GetFullPath($StateDirectory).TrimEnd('\')
    $workRoot=[IO.Path]::GetDirectoryName($stateRoot)
    if(-not $workRoot -or [IO.Path]::GetFileName($stateRoot) -ine 'pairs'){return}
    $control=Join-Path $workRoot 'workspace-control'
    if(-not [IO.Directory]::Exists($control)){return}
    $profile=Read-WsmOutputProfile $workRoot
    if(-not $profile -or $profile.Role -cne 'Target'){throw 'Operation state requires its original target output profile.'}
    Confirm-WsmOutputOperationState $workRoot Target $PairId $PlanHash | Out-Null
}
function Resolve-WsmOutputWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkRoot,[Parameter(Mandatory)][ValidateSet('Source','Manager','Target')][string]$Role,[string]$PairId,[string]$PlanHash,[string]$AttemptId)
    $workspace=Initialize-WsmOutputWorkspace $WorkRoot $Role
    if($PairId){
        if(-not $PlanHash){throw 'Pair resolution requires the trusted plan hash.'}
        $workspace=Register-WsmOutputPair $WorkRoot $Role $PairId $PlanHash
    }elseif($PlanHash){throw 'PlanHash requires PairId.'}
    if($AttemptId -or $PairId){
        $attempt=Get-WsmOutputAttemptId $AttemptId
        $base=$workspace.Profile.WorkRoot
        if($PairId){$base=Join-Path $base ('pairs\'+$PairId)}
        $attemptsRoot=Join-Path $base 'attempts';[void](New-WsmOutputOwnedDirectory $attemptsRoot)
        $attemptRoot=Join-Path $attemptsRoot $attempt
        if([IO.File]::Exists($attemptRoot)){throw 'Attempt path is occupied by a file.'}
        if(-not [IO.Directory]::Exists($attemptRoot)){
            [void](New-WsmOutputOwnedDirectory $attemptRoot)
            foreach($name in @('reports','packages','transport','scratch')){[void](New-WsmOutputOwnedDirectory (Join-Path $attemptRoot $name))}
            $attemptRecord=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='OutputAttempt';AttemptId=$attempt;Role=$Role;HostId=$workspace.HostId;ProfileId=$workspace.Profile.ProfileId;PairId=$PairId;PlanHash=$(if($PlanHash){$PlanHash.ToLowerInvariant()}else{''});Mode=$workspace.Profile.Mode;VolumeBytes=$workspace.Profile.VolumeBytes;CreatedUtc=(Get-WsmUtc)}
            Write-WsmJson (Join-Path $attemptRoot 'attempt.json') $attemptRecord
        }else{
            $attemptRecordPath=Join-Path $attemptRoot 'attempt.json'
            if(-not [IO.File]::Exists($attemptRecordPath)){throw 'Attempt directory exists without its durable identity; inspect or repair before reuse.'}
            Assert-WsmNoReparse $attemptRecordPath
            $attemptRecord=Read-WsmJson $attemptRecordPath;Assert-WsmEnvelope $attemptRecord 'OutputAttempt'
            if($attemptRecord.AttemptId -cne $attempt -or $attemptRecord.Role -cne $Role -or $attemptRecord.HostId -cne $workspace.HostId -or $attemptRecord.ProfileId -cne $workspace.Profile.ProfileId -or $attemptRecord.PairId -cne $PairId -or $attemptRecord.PlanHash -ine $(if($PlanHash){$PlanHash}else{''})){throw 'Attempt identity differs from this workspace/pair/plan; use a new AttemptId.'}
            foreach($name in @('reports','packages','transport','scratch')){[void](New-WsmOutputOwnedDirectory (Join-Path $attemptRoot $name))}
        }
        $workspace | Add-Member NoteProperty AttemptId $attempt -Force
        if(-not $attemptRecord.PSObject.Properties['Mode'] -or -not $attemptRecord.PSObject.Properties['VolumeBytes']){throw 'Legacy output attempt lacks sealed transport preferences; inspect it and use a new attempt.'}
        Assert-WsmOutputProfileValues $attemptRecord
        $workspace | Add-Member NoteProperty AttemptProfile ([pscustomobject]@{Mode=$attemptRecord.Mode;VolumeBytes=[long]$attemptRecord.VolumeBytes}) -Force
        $workspace.AttemptRoot=$attemptRoot
        $workspace.ReportsDirectory=Join-Path $attemptRoot 'reports';$workspace.PackagesDirectory=Join-Path $attemptRoot 'packages';$workspace.TransportDirectory=Join-Path $attemptRoot 'transport';$workspace.ScratchDirectory=Join-Path $attemptRoot 'scratch'
        $workspace.Estimate=Get-WsmOutputWorkspaceEstimate $workspace.Profile.WorkRoot 8192 0
    }
    return $workspace
}
function Copy-WsmOutputMember([string]$Source,[string]$Destination,[long]$ExpectedBytes,[string]$ExpectedHash,$CancellationToken=$null) {
    Assert-WsmNoReparse $Source;Assert-WsmNoReparse $Destination
    $sourceStream=[IO.File]::Open([IO.Path]::GetFullPath($Source),'Open','Read','Read');$destStream=$null;$sha=[Security.Cryptography.SHA256]::Create();$copied=[long]0
    try{
        if($sourceStream.Length -ne $ExpectedBytes){throw 'Package member changed before directory delivery.'}
        $destStream=[IO.File]::Open([IO.Path]::GetFullPath($Destination),'CreateNew','Write','None')
        $buffer=New-Object byte[] 65536
        while(($read=$sourceStream.Read($buffer,0,$buffer.Length)) -gt 0){Assert-WsmCancellationBoundary $CancellationToken 'DirectoryCopyBuffer';$copied+=$read;if($copied -gt $ExpectedBytes){throw 'Package member grew during directory delivery.'};$destStream.Write($buffer,0,$read);[void]$sha.TransformBlock($buffer,0,$read,$buffer,0)}
        [void]$sha.TransformFinalBlock((New-Object byte[] 0),0,0);$destStream.Flush($true)
        $hash=[BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()
        if($copied -ne $ExpectedBytes -or $hash -ine $ExpectedHash){throw 'Copied package member bytes or hash mismatch.'}
    }finally{if($destStream){$destStream.Dispose()};$sourceStream.Dispose();$sha.Dispose()}
}
function Export-WsmDirectoryDelivery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ExpectedHash,[Parameter(Mandatory)][string]$OutputDirectory,[object[]]$ReportReferences=@(),$CancellationToken=$null)
    Assert-WsmCancellationBoundary $CancellationToken 'BeforeDirectoryDelivery'
    $package=Test-WsmMigrationPackage $ManifestPath $ExpectedHash
    $members=@(Get-WsmPackageMembers $package)
    $required=@('manifest.json','plan.json','artifacts.jsonl');if($package.Manifest.Final){$required+=@('freeze.json')}
    $memberLookup=@{};$metadataBytes=[long]0
    foreach($member in $members){
        if($member.Name -notin @('manifest.json','plan.json','artifacts.jsonl','freeze.json') -and $member.Name -notmatch '^payload/[a-f0-9]{64}\.blob$'){throw 'Package whitelist produced an unsupported member name.'}
        if($memberLookup.ContainsKey($member.Name)){throw 'Package whitelist contains a duplicate member.'}
        $memberLookup[$member.Name]=$true
        if($member.Name -notmatch '^payload/'){ $metadataBytes+=[long]$member.Bytes }
    }
    foreach($name in $required){if(-not $memberLookup.ContainsKey($name)){throw ('Trusted package whitelist is missing required member '+$name+'.')}}
    if($metadataBytes -gt 134217728){throw 'Package metadata exceeds the 128 MiB bounded delivery budget.'}
    $root=[IO.Path]::GetFullPath($OutputDirectory)
    $parent=[IO.Path]::GetDirectoryName($root)
    if(-not $parent -or [string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($root))){throw 'OutputDirectory must be a dedicated child directory.'}
    Assert-WsmNoReparse $parent;Assert-WsmNoReparse $root
    if([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)){throw 'Directory delivery requires an unused exclusive OutputDirectory.'}
    $sourcePhysical=Get-WsmPhysicalPath $package.Root;$parentPhysical=Get-WsmPhysicalPath $parent
    if(Test-WsmPathOverlap $sourcePhysical (Join-Path $parentPhysical ([IO.Path]::GetFileName($root)))){throw 'Directory delivery must be physically separate from the sealed package.'}
    $total=[long]0;foreach($m in $members){$total+=[long]$m.Bytes}
    $estimate=Get-WsmDirectoryDeliveryEstimate $package.Root $parent $total 65536
    if(@($estimate.Volumes | Where-Object {-not $_.Sufficient}).Count){throw 'Insufficient free space for clean directory copy and delivery metadata.'}
    $deliveryId=[Guid]::NewGuid().ToString('D');$partial=$root+'.partial-'+$deliveryId.Replace('-','')
    Assert-WsmNoReparse $partial
    $summaryPath=Join-Path $parent ('delivery-'+$deliveryId+'.json')
    try{
        [void](New-WsmOutputOwnedDirectory $partial)
        foreach($member in $members){
            Assert-WsmCancellationBoundary $CancellationToken 'BeforeDirectoryMember'
            $relative=$member.Name.Replace('/','\');$dest=Join-Path $partial $relative
            $destParent=[IO.Path]::GetDirectoryName($dest);[void](New-WsmOutputOwnedDirectory $destParent)
            Copy-WsmOutputMember $member.Path $dest ([long]$member.Bytes) ([string]$member.Hash).ToLowerInvariant() $CancellationToken
        }
        $actual=@(Get-ChildItem -LiteralPath $partial -File -Recurse | ForEach-Object {$_.FullName.Substring($partial.Length).TrimStart('\').Replace('\','/')})
        $wanted=@($members | ForEach-Object Name)
        $actualText=(@($actual | Sort-Object -CaseSensitive) -join "`n")
        $wantedText=(@($wanted | Sort-Object -CaseSensitive) -join "`n")
        if($actualText -cne $wantedText){throw 'Clean directory member set differs from the trusted package whitelist.'}
        $copiedPackage=Test-WsmMigrationPackage (Join-Path $partial 'manifest.json') $ExpectedHash
        if($copiedPackage.Manifest.PackageId -cne $package.Manifest.PackageId -or $copiedPackage.Manifest.PlanHash -ine $package.Manifest.PlanHash){throw 'Copied directory package identity differs from its sealed source.'}
        foreach($reference in $ReportReferences){
            if(-not $reference.Path -or $reference.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Report reference requires a path and fixed SHA256.'}
            $report=[IO.Path]::GetFullPath([string]$reference.Path);Assert-WsmNoReparse $report
            if(-not [IO.File]::Exists($report) -or (Test-WsmPathOverlap (Get-WsmPhysicalPath $report) (Get-WsmPhysicalPath $partial))){throw 'Report reference is missing or inside the package delivery.'}
            if((Get-FileHash -LiteralPath $report).Hash -ine $reference.SHA256){throw 'Report reference hash mismatch.'}
        }
        Assert-WsmCancellationBoundary $CancellationToken 'BeforeDirectorySeal'
        $summary=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='DirectoryDelivery';DeliveryId=$deliveryId;PackageId=$package.Manifest.PackageId;PairId=$package.Manifest.PairId;PlanHash=$package.Manifest.PlanHash;ManifestHash=$ExpectedHash.ToLowerInvariant();PackageDirectory=$root;Members=@($members | ForEach-Object {[pscustomobject]@{Name=$_.Name;Bytes=[long]$_.Bytes;SHA256=([string]$_.Hash).ToLowerInvariant()}});TotalBytes=$total;ReportReferences=@($ReportReferences | ForEach-Object {[pscustomobject]@{Path=[IO.Path]::GetFullPath([string]$_.Path);SHA256=([string]$_.SHA256).ToLowerInvariant()}});CreatedUtc=(Get-WsmUtc);Status='Sealed'}
        $summaryJson=$summary | ConvertTo-Json -Depth 12
        if([Text.Encoding]::UTF8.GetByteCount($summaryJson) -gt 128MB){throw 'Delivery metadata exceeds the 128 MiB JSON limit.'}
        $summaryStream=[IO.File]::Open($summaryPath,'CreateNew','Write','None')
        try{$summaryBytes=[Text.Encoding]::UTF8.GetBytes($summaryJson);$summaryStream.Write($summaryBytes,0,$summaryBytes.Length);$summaryStream.Flush($true)}finally{$summaryStream.Dispose()}
        [IO.Directory]::Move($partial,$root)
        [pscustomobject]@{Directory=$root;DeliveryId=$deliveryId;SummaryPath=$summaryPath;SummarySHA256=(Get-FileHash -LiteralPath $summaryPath).Hash;ManifestHash=$ExpectedHash.ToLowerInvariant();Members=$members.Count;Bytes=$total;Estimate=$estimate;Valid=$true}
    }catch{
        if([IO.Directory]::Exists($partial)){
            $resolved=[IO.Path]::GetFullPath($partial);$parentResolved=[IO.Path]::GetFullPath($parent).TrimEnd('\')+'\'
            if($resolved.StartsWith($parentResolved,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith([IO.Path]::GetFileName($root)+'.partial-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
        }
        if([IO.File]::Exists($summaryPath)){Remove-Item -LiteralPath $summaryPath -Force}
        throw
    }
}
function Get-WsmDirectoryDeliveryFileIndex([string]$Root,[int]$MaxMembers=100000) {
    $rootPath=[IO.Path]::GetFullPath($Root)
    if(-not [IO.Directory]::Exists($rootPath)){throw 'Directory delivery source does not exist.'}
    Assert-WsmNoReparse $rootPath
    $files=@{};$seenNames=@{};$pending=New-Object 'System.Collections.Generic.Stack[string]';$pending.Push($rootPath);$entries=0
    while($pending.Count -gt 0){
        $directory=$pending.Pop()
        foreach($entry in [IO.Directory]::GetFileSystemEntries($directory)){
            $entries++;if($entries -gt ($MaxMembers*2)){throw 'Directory delivery tree exceeds the bounded file and directory entry budget.'}
            $attributes=[IO.File]::GetAttributes($entry)
            if(($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Directory delivery contains a reparse point.'}
            if(($attributes -band [IO.FileAttributes]::Directory) -ne 0){$pending.Push($entry);continue}
            if(($attributes -band [IO.FileAttributes]::Device) -ne 0){throw 'Directory delivery contains a non-file filesystem entry.'}
            $relative=$entry.Substring($rootPath.TrimEnd('\').Length).TrimStart('\').Replace('\','/')
            if($relative -notmatch '^(?:manifest\.json|plan\.json|artifacts\.jsonl|freeze\.json|payload/[a-f0-9]{64}\.blob)$'){throw 'Directory delivery contains an unsupported member name.'}
            if($seenNames.ContainsKey($relative)){throw 'Directory delivery contains duplicate member names under Windows path rules.'}
            $seenNames[$relative]=$true
            $fileInfo=New-Object IO.FileInfo($entry)
            if($fileInfo.Length -lt 0){throw 'Directory delivery contains an invalid member length.'}
            $files[$relative]=[pscustomobject]@{Name=$relative;Path=$entry;Bytes=[long]$fileInfo.Length}
            if($files.Count -gt $MaxMembers){throw 'Directory delivery exceeds the bounded 100000-member budget.'}
        }
    }
    return @($files.Values)
}
function Assert-WsmDirectoryDeliveryPackageMembers($Package,[object[]]$DeliveryMembers) {
    $trusted=@(Get-WsmPackageMembers $Package)
    if($trusted.Count -ne $DeliveryMembers.Count){throw 'Sealed directory member list differs from the trusted package whitelist.'}
    $deliveryMap=@{};foreach($member in $DeliveryMembers){$deliveryMap[[string]$member.Name]=$member}
    foreach($member in $trusted){
        if(-not $deliveryMap.ContainsKey([string]$member.Name)){throw 'Sealed directory member list omits a trusted package member.'}
        $row=$deliveryMap[[string]$member.Name]
        if([long]$row.Bytes -ne [long]$member.Bytes -or [string]$row.Hash -ine [string]$member.Hash){throw ('Sealed directory member metadata differs from the package whitelist: '+$member.Name)}
    }
}
function Import-WsmDirectoryDelivery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SummaryPath,[Parameter(Mandatory)][string]$ExpectedSummaryHash,[Parameter(Mandatory)][string]$SourceDirectory,[Parameter(Mandatory)][string]$WorkRoot,[string]$AttemptId,$CancellationToken=$null)
    if($ExpectedSummaryHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'A trusted directory delivery summary SHA256 is required.'}
    Assert-WsmCancellationBoundary $CancellationToken 'BeforeDirectoryDeliveryImport'
    $summaryFile=[IO.Path]::GetFullPath($SummaryPath);Assert-WsmNoReparse $summaryFile
    if(-not [IO.File]::Exists($summaryFile)){throw 'Directory delivery summary is missing.'}
    $summary=Read-WsmTrustedJson $summaryFile $ExpectedSummaryHash;Assert-WsmEnvelope $summary 'DirectoryDelivery'
    Assert-WsmFields $summary @('SchemaVersion','ToolVersion','Kind','DeliveryId','PackageId','PairId','PlanHash','ManifestHash','PackageDirectory','Members','TotalBytes','ReportReferences','CreatedUtc','Status') @('SchemaVersion','ToolVersion','Kind','DeliveryId','PackageId','PairId','PlanHash','ManifestHash','PackageDirectory','Members','TotalBytes','ReportReferences','CreatedUtc','Status')
    if($summary.SchemaVersion -ne 1 -or $summary.Status -cne 'Sealed' -or $summary.DeliveryId -notmatch '^[0-9a-fA-F-]{36}$' -or $summary.ManifestHash -notmatch '^[a-fA-F0-9]{64}$' -or $summary.PlanHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Directory delivery summary is not a supported sealed delivery.'}
    Assert-WsmId ([string]$summary.DeliveryId);Assert-WsmId ([string]$summary.PairId);Assert-WsmId ([string]$summary.PackageId)
    if($CancellationToken){[void](Assert-WsmCancellationTokenBinding $CancellationToken ([string]$summary.PairId) ([string]$summary.PlanHash) ([string]$summary.ManifestHash) ([IO.Path]::GetFullPath($WorkRoot).TrimEnd('\')))}
    if(@($summary.Members).Count -lt 3 -or @($summary.Members).Count -gt 100000){throw 'Directory delivery summary member count is outside the bounded package range.'}
    if([long]$summary.TotalBytes -lt 0){throw 'Directory delivery summary has an invalid aggregate byte count.'}
    $memberList=New-Object 'System.Collections.Generic.List[object]';$memberNames=@{};$metadataBytes=[long]0;$totalBytes=[long]0
    foreach($member in @($summary.Members)){
        Assert-WsmFields $member @('Name','Bytes','SHA256') @('Name','Bytes','SHA256')
        $name=[string]$member.Name
        if($name.Contains('\') -or $name.StartsWith('/') -or $name.Contains('//')){throw 'Directory delivery summary contains a noncanonical member name.'}
        Assert-WsmRelativePath ($name.Replace('/','\'))
        if($name -notmatch '^(?:manifest\.json|plan\.json|artifacts\.jsonl|freeze\.json|payload/[a-f0-9]{64}\.blob)$'){throw 'Directory delivery summary contains an unsupported member name.'}
        if($memberNames.ContainsKey($name)){throw 'Directory delivery summary contains duplicate member names.'}
        $memberNames[$name]=$true
        $bytes=[long]0;if(-not [long]::TryParse([string]$member.Bytes,[ref]$bytes) -or $bytes -lt 0 -or [string]$member.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Directory delivery summary contains an invalid member size or hash.'}
        if($name -notmatch '^payload/'){$metadataBytes+=$bytes}
        $totalBytes+=$bytes
        $memberList.Add([pscustomobject]@{Name=$name;Bytes=$bytes;Hash=([string]$member.SHA256).ToLowerInvariant()})
    }
    $memberRows=$memberList.ToArray()
    if(@($summary.ReportReferences).Count -gt 100){throw 'Directory delivery summary report-reference budget exceeded.'}
    foreach($reference in @($summary.ReportReferences)){
        Assert-WsmFields $reference @('Path','SHA256') @('Path','SHA256')
        if([string]::IsNullOrWhiteSpace([string]$reference.Path) -or [string]$reference.SHA256 -notmatch '^[a-fA-F0-9]{64}$'){throw 'Directory delivery summary has an invalid source report locator.'}
    }
    foreach($required in @('manifest.json','plan.json','artifacts.jsonl')){if(-not $memberNames.ContainsKey($required)){throw ('Directory delivery summary is missing '+$required+'.')}}
    if($metadataBytes -gt 134217728 -or $totalBytes -ne [long]$summary.TotalBytes){throw 'Directory delivery summary exceeds the bounded metadata budget or has inconsistent total bytes.'}
    $source=[IO.Path]::GetFullPath($SourceDirectory);Assert-WsmNoReparse $source
    if(-not [IO.Directory]::Exists($source)){throw 'Relocated source directory does not exist.'}
    if(Test-WsmPathOverlap (Get-WsmPhysicalPath $summaryFile) (Get-WsmPhysicalPath $source)){throw 'Directory delivery summary must remain outside the package directory.'}
    $files=@(Get-WsmDirectoryDeliveryFileIndex $source)
    if($files.Count -ne $memberRows.Count){throw ('Relocated directory member set differs from the sealed delivery summary (found '+$files.Count+', expected '+$memberRows.Count+').')}
    $fileMap=@{};foreach($file in $files){$fileMap[$file.Name]=$file}
    foreach($member in $memberRows){
        if(-not $fileMap.ContainsKey($member.Name)){throw ('Relocated directory is missing '+$member.Name+'.')}
        $file=$fileMap[$member.Name]
        if([long]$file.Bytes -ne $member.Bytes){throw ('Relocated directory byte count differs for '+$member.Name+'.')}
        Assert-WsmCancellationBoundary $CancellationToken 'BeforeDirectoryMemberVerification'
        if((Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash -ine $member.Hash){throw ('Relocated directory hash differs for '+$member.Name+'.')}
    }
    $sourcePhysical=Get-WsmPhysicalPath $source
    if(Test-WsmPathOverlap $sourcePhysical (Get-WsmPhysicalPath $WorkRoot)){throw 'Directory delivery source must be physically separate from the enrolled Target WorkRoot.'}
    $sourcePackage=Test-WsmMigrationPackage (Join-Path $source 'manifest.json') $summary.ManifestHash $CancellationToken
    if($sourcePackage.Manifest.PackageId -cne $summary.PackageId -or $sourcePackage.Manifest.PairId -cne $summary.PairId -or $sourcePackage.Manifest.PlanHash -ine $summary.PlanHash){throw 'Directory delivery summary identity differs from the validated package.'}
    Assert-WsmDirectoryDeliveryPackageMembers $sourcePackage $memberRows
    $currentIdentity=Get-WsmMachineIdentity
    if($currentIdentity.Fingerprint -cne $sourcePackage.Plan.Target.Fingerprint){throw 'Current Target fingerprint differs from the trusted package plan; no target enrollment, pair or incoming directory was created.'}
    $workRootFull=[IO.Path]::GetFullPath($WorkRoot);$savedProfile=Read-WsmOutputProfile $workRootFull
    if(-not $savedProfile -or $savedProfile.Role -cne 'Target' -or $savedProfile.Mode -cne 'Directory'){throw 'Directory import requires an existing enrolled Target OutputProfile in Directory mode.'}
    if($savedProfile.Fingerprint -cne $sourcePackage.Plan.Target.Fingerprint){throw 'Target OutputProfile fingerprint differs from the trusted package plan; no pair or incoming directory was created.'}
    $importAttemptId=Get-WsmOutputAttemptId $AttemptId
    $controlRoot=Join-Path $workRootFull 'workspace-control';$stagingRoot=Join-Path $controlRoot 'directory-imports'
    $deliveryGuid=([Guid]$summary.DeliveryId).ToString('N');$stage=Join-Path $stagingRoot ($deliveryGuid+'.partial')
    $destinationRoot=Join-Path $workRootFull ('pairs\'+$summary.PairId+'\attempts\'+$importAttemptId+'\packages\'+$deliveryGuid)
    Assert-WsmNoReparse $destinationRoot
    if([IO.File]::Exists($destinationRoot) -or [IO.Directory]::Exists($destinationRoot)){throw 'Directory delivery is already present in this target attempt.'}
    $pathCandidates=New-Object 'System.Collections.Generic.List[string]';$pathCandidates.Add($stage)
    $pathCandidates.Add((Join-Path $stagingRoot ($deliveryGuid+'.import.lock')))
    foreach($member in $memberRows){$pathCandidates.Add((Join-Path $stage ($member.Name.Replace('/','\'))));$pathCandidates.Add((Join-Path $destinationRoot ($member.Name.Replace('/','\'))));if($fileMap[$member.Name].Path.Length -gt 259){throw 'Directory delivery source member path exceeds the Windows PowerShell 5.1 path limit; relocate the delivery to a shorter source path.'}}
    $longPath=$pathCandidates | Where-Object {$_.Length -gt 259} | Select-Object -First 1
    if($longPath){throw 'Directory delivery member path exceeds the Windows PowerShell 5.1 MAX_PATH limit; choose a shorter Target WorkRoot before importing.'}
    $workspace=Initialize-WsmOutputWorkspace $workRootFull Target
    if($workspace.Profile.ProfileId -cne $savedProfile.ProfileId -or $workspace.Profile.HostId -cne $savedProfile.HostId -or $workspace.Profile.Fingerprint -cne $sourcePackage.Plan.Target.Fingerprint){throw 'Target enrollment changed while preparing directory import; no pair or incoming directory was created.'}
    $estimate=Get-WsmOutputWorkspaceEstimate $workspace.Profile.WorkRoot $metadataBytes $totalBytes
    if(@($estimate.Volumes | Where-Object {-not $_.Sufficient}).Count){throw 'Insufficient target volume space for bounded directory import.'}
    [void](New-WsmOutputOwnedDirectory $stagingRoot)
    $lockPath=Join-Path $stagingRoot ($deliveryGuid+'.import.lock');Assert-WsmNoReparse $lockPath;$importLock=$null
    try{$importLock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}catch{throw 'This DirectoryDelivery is already being imported; the exclusive per-delivery lock is held.'}
    $stageExists=[IO.File]::Exists($stage) -or [IO.Directory]::Exists($stage)
    if($stageExists){$importLock.Dispose();throw 'A previous partial directory import uses this DeliveryId; inspect it before retry.'}
    $stageCreated=$false;$moved=$false
    try{
        [void](New-WsmOutputOwnedDirectory $stage);$stageCreated=$true
        foreach($member in $memberRows){
            Assert-WsmCancellationBoundary $CancellationToken 'BeforeDirectoryImportCopy'
            $sourceFile=$fileMap[$member.Name].Path;$destination=Join-Path $stage ($member.Name.Replace('/','\'))
            [void](New-WsmOutputOwnedDirectory ([IO.Path]::GetDirectoryName($destination)))
            Copy-WsmOutputMember $sourceFile $destination $member.Bytes $member.Hash $CancellationToken
        }
        $stagedFiles=@(Get-WsmDirectoryDeliveryFileIndex $stage)
        if($stagedFiles.Count -ne $memberRows.Count){throw 'Copied directory member set differs from the sealed delivery summary.'}
        $stagedMap=@{};foreach($file in $stagedFiles){$stagedMap[$file.Name]=$file}
        foreach($member in $memberRows){if(-not $stagedMap.ContainsKey($member.Name) -or [long]$stagedMap[$member.Name].Bytes -ne $member.Bytes -or (Get-FileHash -LiteralPath $stagedMap[$member.Name].Path -Algorithm SHA256).Hash -ine $member.Hash){throw 'Copied directory failed exact member verification.'}}
        $copiedPackage=Test-WsmMigrationPackage (Join-Path $stage 'manifest.json') $summary.ManifestHash $CancellationToken
        if($copiedPackage.Manifest.PackageId -cne $summary.PackageId -or $copiedPackage.Manifest.PairId -cne $summary.PairId -or $copiedPackage.Manifest.PlanHash -ine $summary.PlanHash -or $copiedPackage.Plan.Target.Fingerprint -cne $workspace.Profile.Fingerprint){throw 'Copied directory package identity or target binding changed during import.'}
        Assert-WsmDirectoryDeliveryPackageMembers $copiedPackage $memberRows
        $pairWorkspace=Resolve-WsmOutputWorkspace -WorkRoot $WorkRoot -Role Target -PairId $copiedPackage.Manifest.PairId -PlanHash $copiedPackage.Manifest.PlanHash -AttemptId $importAttemptId
        $resolvedDestination=Join-Path $pairWorkspace.PackagesDirectory $deliveryGuid
        if([IO.Path]::GetFullPath($resolvedDestination) -ine [IO.Path]::GetFullPath($destinationRoot)){throw 'Resolved target package path differs from the preflighted enrolled attempt path.'}
        $destinationRoot=$resolvedDestination
        Assert-WsmNoReparse $destinationRoot
        if([IO.Directory]::Exists($destinationRoot) -or [IO.File]::Exists($destinationRoot)){throw 'Directory delivery is already present in this target attempt.'}
        if([IO.Path]::GetPathRoot($stage) -ine [IO.Path]::GetPathRoot($destinationRoot)){throw 'Atomic directory import requires staging and enrolled incoming storage on the same volume.'}
        Assert-WsmCancellationBoundary $CancellationToken 'BeforeDirectoryImportSeal'
        [IO.Directory]::Move($stage,$destinationRoot);$stageCreated=$false;$moved=$true
        [pscustomobject]@{Directory=$destinationRoot;ManifestPath=(Join-Path $destinationRoot 'manifest.json');ManifestHash=$summary.ManifestHash.ToLowerInvariant();SummaryHash=$ExpectedSummaryHash.ToLowerInvariant();DeliveryId=$summary.DeliveryId;PairId=$summary.PairId;PlanHash=$summary.PlanHash.ToLowerInvariant();AttemptId=$pairWorkspace.AttemptId;Members=$memberRows.Count;Bytes=$totalBytes;Valid=$true;Estimate=$estimate;ReportReferences=@($summary.ReportReferences | ForEach-Object {[pscustomobject]@{SHA256=[string]$_.SHA256}})}
    }catch{
        if($stageCreated -and -not $moved -and [IO.Directory]::Exists($stage)){
            $resolvedStage=[IO.Path]::GetFullPath($stage);$resolvedStaging=[IO.Path]::GetFullPath($stagingRoot).TrimEnd('\')+'\'
            if($resolvedStage.StartsWith($resolvedStaging,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedStage) -ceq ($deliveryGuid+'.partial')){Remove-Item -LiteralPath $resolvedStage -Recurse -Force}
        }
        throw
    }finally{$importLock.Dispose()}
}
