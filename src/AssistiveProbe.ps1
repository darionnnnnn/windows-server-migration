function Export-WsmAssistiveEnvironmentProbe {
    [CmdletBinding()]param([string]$OutputDirectory,[ValidateSet('Source','Target','Manager')][string]$Role,[string]$PairId,[string]$PlanHash,[switch]$DeepDiscovery)
    Assert-WsmNoReparse $OutputDirectory
    if(-not [IO.Directory]::Exists($OutputDirectory)){[void][IO.Directory]::CreateDirectory($OutputDirectory);Protect-WsmDirectory $OutputDirectory}
    $runId=[Guid]::NewGuid().ToString();$root=Join-Path $OutputDirectory $runId
    [void][IO.Directory]::CreateDirectory($root);Protect-WsmDirectory $root
    $checks=New-Object 'System.Collections.Generic.List[object]'
    $platform=$null;$identity=$null
    try{$platform=Get-WsmPreflight;$identity=Get-WsmMachineIdentity;$checks.Add([pscustomobject]@{CheckId='Platform';Status='PASS';Evidence='Native OS/build/edition, PowerShell, architecture and privilege observed.'})}catch{$checks.Add([pscustomobject]@{CheckId='Platform';Status='NotTested';Evidence='Platform identity probe failed; native environment remains unknown.'})}
    $commands=@('Get-ScheduledTask','Export-ScheduledTask','Get-ScheduledTaskInfo','Register-ScheduledTask','Get-Website','Get-WebAppPoolState','Get-SmbShare','Get-SmbShareAccess','Get-SmbConnection','Get-SmbMapping','Get-Acl','Set-Acl','Get-WindowsFeature')
    foreach($name in $commands){$available=[bool](Get-Command $name -ErrorAction SilentlyContinue);$checks.Add([pscustomobject]@{CheckId=('Command.'+$name);Status=$(if($available){'PASS'}else{'NotTested'});Evidence=$(if($available){'Command available; successful mutation and readback are not implied.'}else{'Command unavailable; prepare the required role/module and probe again.'})})}
    $physical=@(foreach($drive in @(Get-PSDrive -PSProvider FileSystem)){
        try{[pscustomobject]@{Root=$drive.Root;PhysicalIdentity=(Get-WsmPhysicalPath $drive.Root);AvailableBytes=(Get-WsmAvailableBytes $drive.Root);Status='PASS'}}catch{[pscustomobject]@{Root=$drive.Root;PhysicalIdentity='';AvailableBytes=$null;Status='NotTested'}}
    })
    $inventoryReference=$null;$inventoryHash='';$workload=$null
    if($platform -and $platform.IsServer -and $platform.Administrator -and $platform.Is64Bit -and $Role -ne 'Manager'){
        try{
            $inventoryResult=Export-WsmInventory -OutputDirectory (Join-Path $root 'protected-inventory') -IncludeSoftwareCatalog -DeepDiscovery:$DeepDiscovery
            $inventory=Read-WsmTrustedJson $inventoryResult.Path $inventoryResult.SHA256
            $inventoryReference='protected-inventory/'+[IO.Path]::GetFileName($inventoryResult.Path);$inventoryHash=$inventoryResult.SHA256.ToLowerInvariant()
            if($inventory.PSObject.Properties['WorkloadDiscovery']){$workload=$inventory.WorkloadDiscovery}
            foreach($item in $inventory.Items){if($item.Status -ne 'Success'){$checks.Add([pscustomobject]@{CheckId=('Inventory.'+$item.ItemId);Status='NotTested';Evidence=('Collector status '+$item.Status+'; protected inventory contains the original evidence.')})}}
            $checks.Add([pscustomobject]@{CheckId='InventoryCapture';Status='PASS';Evidence='Full native inventory bytes retained and hashed. Coverage gaps remain explicit.'})
        }catch{$checks.Add([pscustomobject]@{CheckId='InventoryCapture';Status='NotTested';Evidence='Inventory capture failed. Run elevated on the correct Server with role modules available.'})}
    }else{$checks.Add([pscustomobject]@{CheckId='InventoryCapture';Status='NotTested';Evidence='Source/Target capture requires elevated 64-bit Windows Server; Manager only probes its local capabilities.'})}
    $requirements=@(
        @{Id='NativeIisReadback';How='On an isolated Target, restore a reviewed two-application/two-vdir site and pool, compare full typed settings and paths, then perform approved activation and business validation.'},
        @{Id='NativeTaskReadback';How='On an isolated Target, restore full task XML with two Exec actions, non-Exec actions, hidden settings, principals and complete folder/task security; compare readback while disabled.'},
        @{Id='IisGlobalPriorUndo';How='Review one supported section/location change, preserve unrelated target settings, record prior/readback, inject drift and verify undo refuses drift.'},
        @{Id='NonCAndSmb';How='Export peer share proofs on both hosts; execute the jump-host transfer over approved shares, verify SHA256 and DACL/owner/SACL, then import its trusted result on Manager.'},
        @{Id='AccountAndPermissions';How='Verify mapped identities resolve and the target execution account can read settings/data and execute approved applications. Do not infer rights from administrator access.'},
        @{Id='PartialDeltaRecovery';How='Stage independent files while deferring a missing runtime; install manually, re-probe, resume from retained full/base materials and exercise journal recovery and rollback.'},
        @{Id='FreezeAndActivation';How='Obtain same-round source C/non-C writer-fence proof, staged business evidence and explicit cutover approval; activate, then record BusinessFinal and FinalAccepted.'},
        @{Id='EnterpriseDeployment';How='On actual Desktop/Core hosts verify execution policy, FullLanguage, loopback/browser or text fallback, certificate/secret custody, SMB policy and available capacity.'}
    )
    foreach($requirement in $requirements){$checks.Add([pscustomobject]@{CheckId=$requirement.Id;Status='NotTested';Evidence=$requirement.How})}
    $probe=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='AssistiveEnvironmentProbe';RunId=$runId;Role=$Role;PairId=$PairId;PlanHash=$PlanHash;CreatedUtc=(Get-WsmUtc);ToolFingerprint=(Get-WsmToolFingerprint);HostIdentity=$identity;Platform=$platform;PhysicalVolumes=$physical;InventoryReference=$inventoryReference;InventoryHash=$inventoryHash;WorkloadDiscovery=$workload;Checks=@($checks.ToArray());Mode='ReadOnly';ProductionQualified=$false;BusinessValidated=$false}
    $path=Join-Path $root 'probe.json';Write-WsmJson $path $probe
    $rows=@($checks.ToArray() | Select-Object CheckId,Status,Evidence)
    $html=Join-Path $root 'index.html';Write-WsmHtml $html 'Environment probe: observed evidence and pending isolated verification' $rows
    [pscustomobject]@{Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();HtmlPath=$html;RunId=$runId;Status='NotTested';ObservedChecks=@($rows|Where-Object Status -EQ PASS).Count;PendingChecks=@($rows|Where-Object Status -EQ NotTested).Count;ProductionQualified=$false}
}

function Import-WsmAssistiveEnvironmentProbe {
    [CmdletBinding()]param([string]$Workspace,[string]$PairId,[string]$Path,[string]$ExpectedHash,[int]$ExpectedRevision,[ValidateRange(1,720)][int]$MaximumAgeHours=24)
    $probe=Read-WsmTrustedJson $Path $ExpectedHash
    Assert-WsmFields $probe @('SchemaVersion','ToolVersion','Kind','RunId','Role','PairId','PlanHash','CreatedUtc','ToolFingerprint','HostIdentity','Platform','PhysicalVolumes','InventoryReference','InventoryHash','WorkloadDiscovery','Checks','Mode','ProductionQualified','BusinessValidated') @('SchemaVersion','Kind','RunId','Role','PairId','CreatedUtc','HostIdentity','Checks','Mode','ProductionQualified','BusinessValidated')
    if($probe.SchemaVersion -ne 1 -or $probe.Kind -cne 'AssistiveEnvironmentProbe' -or $probe.Mode -cne 'ReadOnly' -or $probe.ProductionQualified -ne $false -or $probe.BusinessValidated -ne $false -or $probe.Checks -isnot [array]){throw 'Probe is unsupported or falsely claims production/business qualification.'}
    Assert-WsmId $probe.RunId
    $age=([DateTime]::UtcNow-[DateTime]::Parse($probe.CreatedUtc).ToUniversalTime()).TotalHours
    if($age -lt -0.1 -or $age -gt $MaximumAgeHours){throw 'Probe timestamp is stale or in the future.'}
    foreach($check in $probe.Checks){if($check.Status -cnotin @('PASS','FAIL','NotTested')){throw 'Unknown probe check status.'}}
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if($catalog.Assistive.Revision -ne $ExpectedRevision){throw 'Review changed.'}
        if($probe.PairId -cne $PairId -or -not $probe.HostIdentity){throw 'Probe pair/host binding is absent.'}
        $expectedFingerprint=if($probe.Role -ceq 'Source'){$catalog.Source.Fingerprint}elseif($probe.Role -ceq 'Target' -and $catalog.Assistive.TargetCurrent){$catalog.Assistive.TargetCurrent.Fingerprint}else{throw 'An observed target identity or source role is required before importing this probe.'}
        if($probe.HostIdentity.Fingerprint -cne $expectedFingerprint){throw 'Probe host identity does not match this pair.'}
        if($probe.PlanHash -and (-not $catalog.Approval -or $probe.PlanHash -ine $catalog.Approval.Hash)){throw 'Probe approved plan binding is stale.'}
        $directory=Join-Path $Workspace 'assistive\probes';if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory}
        $destination=Join-Path $directory ($ExpectedHash.ToLowerInvariant()+'.json');Assert-WsmNoReparse $destination
        $inventoryDestination=$null
        if($probe.InventoryReference){
            if([IO.Path]::IsPathRooted([string]$probe.InventoryReference) -or [string]$probe.InventoryReference -match '(^|[\\/])\.\.([\\/]|$)' -or [string]$probe.InventoryHash -notmatch '^[a-f0-9]{64}$'){throw 'Unsafe probe inventory reference.'}
            $bundleRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path));$inventoryPath=[IO.Path]::GetFullPath((Join-Path $bundleRoot ([string]$probe.InventoryReference)))
            if(-not $inventoryPath.StartsWith($bundleRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Probe inventory escapes its bundle.'}
            Assert-WsmNoReparse $inventoryPath;$inventory=Read-WsmTrustedJson $inventoryPath $probe.InventoryHash;Assert-WsmInventory $inventory
            if($inventory.Source.Fingerprint -cne $probe.HostIdentity.Fingerprint){throw 'Probe inventory belongs to a different host.'}
            $inventoryDestination=Join-Path $directory ($probe.InventoryHash+'.inventory.json');Assert-WsmNoReparse $inventoryDestination
            if(-not [IO.File]::Exists($inventoryDestination)){[IO.File]::Copy($inventoryPath,$inventoryDestination,$false)}
            Assert-WsmTrustedFile $inventoryDestination $probe.InventoryHash
        }
        if(-not [IO.File]::Exists($destination)){[IO.File]::Copy([IO.Path]::GetFullPath($Path),$destination,$false)}
        if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'Probe bytes changed during durable import.'}
        if(@($catalog.Assistive.ResultReferences|Where-Object SHA256 -EQ $ExpectedHash).Count){throw 'Probe was already imported.'}
        $catalog.Assistive.ResultReferences=@($catalog.Assistive.ResultReferences)+@([pscustomobject]@{Reference=('assistive/probes/'+[IO.Path]::GetFileName($destination));SHA256=$ExpectedHash.ToLowerInvariant();CreatedUtc=$probe.CreatedUtc;Kind='AssistiveEnvironmentProbe';RunId=$probe.RunId})
        if($inventoryDestination){$catalog.Assistive.ResultReferences+=,[pscustomobject]@{Reference=('assistive/probes/'+[IO.Path]::GetFileName($inventoryDestination));SHA256=$probe.InventoryHash;CreatedUtc=$probe.CreatedUtc;Kind='AssistiveProbeInventory';RunId=$probe.RunId}}
        $catalog.Assistive.Revision++;$catalog.Assistive.UpdatedUtc=Get-WsmUtc
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $catalog
        [pscustomobject]@{Status='ImportedVerified';Revision=$catalog.Assistive.Revision;PendingChecks=@($probe.Checks|Where-Object Status -EQ NotTested).Count;ProductionQualified=$false;BusinessValidated=$false}
    }
}
