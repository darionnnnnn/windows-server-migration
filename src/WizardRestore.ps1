# Target-side Assistive restore orchestration for the migration wizard.
# Every authorization decision is derived from the enrolled Target profile,
# a received schema-3 sealed plan, durable operation outputs, and core receipts.

function Get-WsmWizardTargetMaterialRoot([string]$Workspace,[string]$PairId) {
    $root=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials') ('target-'+$PairId)))
    $base=[IO.Path]::GetFullPath((Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials')).TrimEnd('\')+'\'
    if(-not $root.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Target wizard material path escaped its owned workspace root.'}
    $root
}

function Assert-WsmWizardTargetRole([string]$Workspace,[string]$PairId) {
    if(-not $PairId){throw 'PairId is required.'};Assert-WsmId $PairId
    $profile=Read-WsmOutputProfile $Workspace
    if(-not $profile -or $profile.Role -cne 'Target'){throw 'This operation requires the enrolled Target workspace.'}
    $machine=Get-WsmMachineIdentity
    if($machine.Fingerprint -ine $profile.Fingerprint){throw 'Current machine identity differs from the enrolled Target workspace.'}
    $received=Get-WsmWizardReceivedApprovedPlan $Workspace $PairId $profile
    if(-not $received -or $received.Plan.SchemaVersion -ne 3){throw 'A uniquely verified received schema-3 approved plan is required on this Target.'}
    Assert-WsmAssistiveContract $received.Plan MigrationPlan | Out-Null
    if($received.Plan.PairId -cne $PairId -or $received.Plan.Target.HostId -cne $profile.HostId -or $received.Plan.Target.Fingerprint -ine $profile.Fingerprint){throw 'Received plan is not bound to this exact Target pair and host.'}
    [pscustomobject]@{Profile=$profile;Received=$received;Plan=$received.Plan}
}

function Get-WsmWizardTargetJobField($Job,[string]$Name,[string]$Alternate='') {
    if($Job.PSObject.Properties[$Name]){return $Job.$Name}
    if($Alternate -and $Job.PSObject.Properties[$Alternate]){return $Job.$Alternate}
    $null
}

function Get-WsmWizardTargetPackage([string]$Workspace,[string]$PairId,$Context,[object[]]$Jobs) {
    $packageMatches=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($Jobs)){
        if(-not $job){continue}
        $status=[string](Get-WsmWizardTargetJobField $job status Status);$action=[string](Get-WsmWizardTargetJobField $job action Action)
        $role=[string](Get-WsmWizardTargetJobField $job role Role);$jobPair=[string](Get-WsmWizardTargetJobField $job pairId PairId);$jobWorkspace=[string](Get-WsmWizardTargetJobField $job workspace Workspace)
        if($status -cne 'Succeeded' -or $action -notin @('ImportPackageZip','DirectoryImport','TargetZipImport','TargetDirectoryImport') -or $role -cne 'Target' -or $jobPair -cne $PairId -or -not $jobWorkspace -or [IO.Path]::GetFullPath($jobWorkspace) -ine [IO.Path]::GetFullPath($Workspace)){continue}
        foreach($output in @((Get-WsmWizardTargetJobField $job outputs Outputs))){
            if(-not $output -or -not $output.PSObject.Properties['Valid'] -or -not [bool]$output.Valid){continue}
            $manifestPath=[string]$output.ManifestPath;$manifestHash='';if($output.PSObject.Properties['SHA256']){$manifestHash=[string]$output.SHA256}elseif($output.PSObject.Properties['ManifestHash']){$manifestHash=[string]$output.ManifestHash}
            if(-not $manifestPath -or $manifestHash -notmatch '^[a-fA-F0-9]{64}$'){continue}
            try{$manifestPath=[IO.Path]::GetFullPath($manifestPath)}catch{throw 'A successful Target package job contains an invalid manifest path; inspect the durable job record.'}
            if([IO.Path]::GetFileName($manifestPath) -cne 'manifest.json' -or -not [IO.File]::Exists($manifestPath) -or (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine $manifestHash){throw 'A successful Target package job references missing or changed manifest bytes; preserve the job and redeliver verified material.'}
            try{$package=Test-WsmMigrationPackage $manifestPath $manifestHash}catch{throw ('A successful Target package job references malformed or changed package material; preserve it and redeliver after review: '+$_.Exception.Message)}
            if($package.Manifest.PairId -cne $PairId){throw 'A successful Target package job references another pair; preserve the job and resolve the delivery binding.'}
            if($package.Manifest.PlanHash -ine $Context.Received.SHA256 -or $package.Plan.SchemaVersion -ne 3){continue}
            if($package.Manifest.Target.HostId -cne $Context.Profile.HostId -or $package.Manifest.Target.Fingerprint -ine $Context.Profile.Fingerprint){throw 'A successful Target package job has a cross-host target binding; preserve the job and resolve the delivery binding.'}
            try{
                if($action -eq 'DirectoryImport' -and ($output.PairId -cne $PairId -or $output.PlanHash -ine $Context.Received.SHA256)){continue}
                $packageMatches.Add([pscustomobject]@{Package=$package;ManifestPath=$manifestPath;ManifestHash=$manifestHash.ToLowerInvariant();JobId=[string](Get-WsmWizardTargetJobField $job jobId JobId);AttemptId=[string]$output.AttemptId;Action=$action;CompletedUtc=[string](Get-WsmWizardTargetJobField $job CompletedUtc completedUtc)})
            }catch{throw ('Unable to bind the successful Target package job to its verified material: '+$_.Exception.Message)}
        }
    }
    if($packageMatches.Count -eq 0){throw 'No durable successful Target package-delivery job matches this received plan.'}
    # The same sealed package may be imported more than once to distinct incoming
    # directories. It is still one exact generation/material identity. Prefer the
    # latest durable delivery record, then a stable path tie-break. A genuinely
    # different manifest at the same generation remains ambiguous and fails closed.
    $byGeneration=@{};foreach($match in $packageMatches){$key=[string]([long]$match.Package.Manifest.Generation);if(-not $byGeneration.ContainsKey($key)){$byGeneration[$key]=New-Object 'System.Collections.Generic.List[object]'};$byGeneration[$key].Add($match)}
    $latestGeneration=(@($byGeneration.Keys | ForEach-Object {[long]$_} | Sort-Object -Descending)[0]);$latest=@($byGeneration[[string]$latestGeneration].ToArray());$distinct=@($latest | Select-Object -ExpandProperty ManifestHash -Unique)
    if($distinct.Count -gt 1){throw 'More than one distinct successful package manifest matches the latest Target generation; retain the exact delivery job and resolve the ambiguity.'}
    $latest | Sort-Object @{Expression={if($_.CompletedUtc){[string]$_.CompletedUtc}else{''}};Descending=$true},@{Expression={$_.ManifestPath.ToLowerInvariant()};Descending=$false} | Select-Object -First 1
}

function Get-WsmWizardTargetSnapshot([string]$Workspace,$Context,[object[]]$Jobs) {
    # Prefer the inventory this Target explicitly bound in its wizard state, as every other caller does; several successful inventory jobs (a re-inventory after installing software) are normal and must not be ambiguous.
    $boundState=Get-WsmWizardState $Workspace '' Target;$inventory=Get-WsmWizardInventoryFromJobs $Workspace $Context.Profile $Jobs ([string]$boundState.SourceInventoryHash) ([string]$boundState.InventoryJobId)
    if(-not $inventory -or $inventory.Ambiguous){throw 'A unique successful current Target inventory job is required; refresh Target inventory before continuing.'}
    if($inventory.Inventory.Source.HostId -cne $Context.Profile.HostId -or $inventory.Inventory.Source.Fingerprint -ine $Context.Profile.Fingerprint){throw 'Current Target inventory does not match the enrolled local host identity.'}
    if(-not $inventory.Inventory.PSObject.Properties['SoftwareCatalog']){throw 'Target inventory has no native software catalog; do not infer software absence.'}
    Assert-WsmSoftwareCatalog $inventory.Inventory.SoftwareCatalog -SourceInventory $inventory.Inventory | Out-Null
    Assert-WsmAssistiveSnapshotFresh $inventory.Inventory | Out-Null
    Assert-WsmAssistiveCurrentSoftware $inventory.Inventory | Out-Null
    [pscustomobject]@{Path=[string]$inventory.Path;SHA256=[string]$inventory.SHA256;Inventory=$inventory.Inventory;JobId=[string]$inventory.JobId}
}

function Get-WsmWizardTargetDecisionRecord([string]$Workspace,[string]$PairId,[string]$ExpectedPlanHash='') {
    $root=Get-WsmWizardTargetMaterialRoot $Workspace $PairId;if(-not [IO.Directory]::Exists($root)){return $null};Assert-WsmNoReparse $root
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter 'decision-*.json' -File)){
        try{Assert-WsmNoReparse $file.FullName;if($file.Length -gt 4194304){continue};$hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();$receipt=Read-WsmTrustedJson $file.FullName $hash;Assert-WsmAssistiveContract $receipt TargetDecisionReceipt | Out-Null;if($receipt.PairId -cne $PairId -or ($ExpectedPlanHash -and $receipt.PlanHash -ine $ExpectedPlanHash)){continue};$rows.Add([pscustomobject]@{Path=$file.FullName;SHA256=$hash;Receipt=$receipt})}catch{}
    }
    if($rows.Count -gt 1){$latest=@($rows.ToArray() | Sort-Object { [DateTimeOffset]::Parse([string]$_.Receipt.CreatedUtc) } -Descending);if($latest.Count -gt 1 -and [string]$latest[0].Receipt.CreatedUtc -ceq [string]$latest[1].Receipt.CreatedUtc){throw 'Target decision receipt selection is ambiguous; inspect the durable receipt artifacts.'};return $latest[0]}
    if($rows.Count -eq 1){return $rows[0]};$null
}

function Get-WsmWizardTargetComparisonRecord([string]$Workspace,[string]$PairId,[string]$ExpectedPlanHash='') {
    $root=Get-WsmWizardTargetMaterialRoot $Workspace $PairId;if(-not [IO.Directory]::Exists($root)){return $null};Assert-WsmNoReparse $root
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($file in @(Get-ChildItem -LiteralPath $root -Filter 'comparison-*.json' -File)){
        try{Assert-WsmNoReparse $file.FullName;if($file.Length -gt 4194304){continue};$hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();$doc=Read-WsmTrustedJson $file.FullName $hash;if($doc.Kind -cne 'WizardTargetComparisonMaterial' -or $doc.SchemaVersion -ne 1 -or $doc.PairId -cne $PairId -or ($ExpectedPlanHash -and $doc.PlanHash -ine $ExpectedPlanHash)){continue};$rows.Add([pscustomobject]@{Path=$file.FullName;SHA256=$hash;Document=$doc;Comparison=$doc.Comparison})}catch{}
    }
    if($rows.Count -gt 1){$latest=@($rows.ToArray() | Sort-Object { [DateTimeOffset]::Parse([string]$_.Document.CreatedUtc) } -Descending);if($latest.Count -gt 1 -and [string]$latest[0].Document.CreatedUtc -ceq [string]$latest[1].Document.CreatedUtc){throw 'Target comparison selection is ambiguous; import the current comparison again to refresh its durable timestamp.'};return $latest[0]}
    if($rows.Count -eq 1){return $rows[0]};$null
}

function Get-WsmWizardTargetPreviewHash($Preview,[string]$PairId,[string]$PlanHash,[string]$ManifestHash,[long]$Generation,[string]$ReceiptHash,[string]$TargetSnapshotHash,[string]$ComparisonHash,[int]$ComparisonRevision,[int]$SelectionRevision,[string]$Decision) {
    $binding=[ordered]@{PairId=$PairId;PlanHash=$PlanHash;ManifestHash=$ManifestHash;Generation=$Generation;ReceiptHash=$ReceiptHash;TargetSnapshotHash=$TargetSnapshotHash;ComparisonHash=$ComparisonHash;ComparisonRevision=$ComparisonRevision;SelectionRevision=$SelectionRevision;Decision=$Decision;SelectedItemIds=@($Preview.SelectedItemIds);Rows=@(ConvertTo-WsmWizardHtmlValue @($Preview.Rows));Problems=@(ConvertTo-WsmWizardHtmlValue @($Preview.Problems));GeneralHostIssues=@(ConvertTo-WsmWizardHtmlValue @($Preview.GeneralHostIssues));Blocked=[bool]$Preview.Blocked;CanRestoreIndependentItems=[bool]$Preview.CanRestoreIndependentItems}
    foreach($name in @('NonCTransferPlanHash','NonCResultHash','WizardNonCEvidenceIssue')){$binding[$name]=if($Preview.PSObject.Properties[$name]){[string]$Preview.$name}else{''}}
    Get-WsmHashText ($binding | ConvertTo-Json -Depth 100 -Compress)
}

function Get-WsmWizardSelectedNonCPreviewInputs([string]$Workspace,[string]$PairId,$Plan,$Decision,[object[]]$Jobs) {
    $selected=@($Decision.SelectedItemIds)
    $nonC=@($Plan.Items|Where-Object {$selected -ccontains [string]$_.ItemId -and $_.MigrationSpec.Adapter -ceq 'FileScope' -and $_.MigrationSpec.TransferChannel -ceq 'NonC'})
    $result=[pscustomobject]@{Arguments=@{};Issue=''}
    if(-not $nonC.Count){return $result}
    try{
        $materials=Get-WsmWizardNonCTargetRestoreInputs -Workspace $Workspace -PairId $PairId -Jobs $Jobs
        if($materials){foreach($name in @('NonCTransferPlanPath','NonCTransferPlanHash','NonCResultPath','NonCResultHash')){$result.Arguments[$name]=[string]$materials.$name}}
    }catch{
        # Invalid NonC evidence cannot authorize a NonC row, and must not gate
        # unrelated C items. Core preview receives no NonC inputs and retains
        # its deferred rows; this explicit issue is bound into the review hash.
        $result.Issue='CurrentNonCMaterialsInvalid; retain the materials for inspection and import a newly verified handoff before restoring NonC items.'
    }
    $result
}

function Export-WsmWizardTargetComparison {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[object[]]$Jobs=@())
    $profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'Target comparison export requires the enrolled Manager workspace.'};Assert-WsmId $PairId
    $catalog=Get-WsmCatalog $Workspace $PairId;if(-not $catalog.PSObject.Properties['Assistive'] -or -not $catalog.Approval -or $catalog.Approval.Kind -cne 'MigrationPlan'){throw 'A current schema-3 Assistive approved plan and comparison are required.'}
    $approved=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $Jobs
    if(-not $approved -or $approved.Plan.SchemaVersion -ne 3 -or $approved.SHA256 -ine [string]$catalog.Approval.Hash){throw 'Current approved schema-3 plan bytes could not be verified from the successful approval job.'}
    $comparison=Get-WsmAssistiveComparison $Workspace $PairId
    if(-not $catalog.Assistive.Comparison -or (Get-WsmHashText ($catalog.Assistive.Comparison | ConvertTo-Json -Depth 100 -Compress)) -ine (Get-WsmHashText ($comparison | ConvertTo-Json -Depth 100 -Compress))){throw 'Manager comparison is not the exact current published comparison.'}
    $sourceInventory=Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.SourceSnapshot Source
    $targetInventory=Get-WsmAssistiveSnapshotInventory $Workspace $catalog.Assistive.TargetCurrent Target
    if($comparison.SourceSnapshotHash -ine $approved.Plan.Assistive.SourceSnapshotHash -or $comparison.TargetSnapshotHash -ine [string]$catalog.Assistive.TargetCurrent.SHA256 -or [int]$comparison.SelectionRevision -ne [int]$approved.Plan.Assistive.SourceSelectionsVersion){throw 'Current comparison source, target or sealed source-selection bindings do not match the approved plan.'}
    Assert-WsmAssistiveComparisonSnapshotVersions $comparison $targetInventory $sourceInventory.SoftwareCatalog | Out-Null
    $document=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardTargetComparisonMaterial';PairId=$PairId;PlanHash=[string]$approved.SHA256;SourceSnapshotHash=[string]$comparison.SourceSnapshotHash;TargetSnapshotHash=[string]$comparison.TargetSnapshotHash;SelectionRevision=[int]$comparison.SelectionRevision;ComparisonRevision=[int]$comparison.Revision;Comparison=$comparison;InformationalOnly=$true;CreatedUtc=(Get-WsmUtc)}
    $root=Get-WsmWizardTargetMaterialRoot $Workspace $PairId;[void](New-WsmOutputOwnedDirectory $root);$path=Join-Path $root ('manager-comparison-'+$comparison.Revision+'-'+(Get-WsmHashText ($document | ConvertTo-Json -Depth 100 -Compress))+'.json');Write-WsmJson $path $document
    [pscustomobject][ordered]@{Status='Succeeded';PairId=$PairId;Path=[IO.Path]::GetFullPath($path);SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();ComparisonRevision=[int]$comparison.Revision;PlanHash=[string]$approved.SHA256;SourceSnapshotHash=[string]$comparison.SourceSnapshotHash;TargetSnapshotHash=[string]$comparison.TargetSnapshotHash;SelectionRevision=[int]$comparison.SelectionRevision;InformationalOnly=$true;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Save-WsmWizardTargetComparisonMaterial {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)]$Ctx,[Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)]$Comparison,[Parameter(Mandatory)][int]$SelectionRevision,[Parameter(Mandatory)][int]$ComparisonRevision,[Parameter(Mandatory)][string]$SourceSnapshotHash,[Parameter(Mandatory)][ValidateSet('ManagerImport','TargetLocal')][string]$Provenance,[Parameter(Mandatory)][AllowEmptyString()][string]$ImportedFromHash)
    $root=Get-WsmWizardTargetMaterialRoot $Workspace $PairId;[void](New-WsmOutputOwnedDirectory $root);$contentHash=Get-WsmHashText ($Comparison | ConvertTo-Json -Depth 100 -Compress);$stored=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardTargetComparisonMaterial';PairId=$PairId;PlanHash=[string]$Ctx.Received.SHA256;SourceSnapshotHash=[string]$SourceSnapshotHash;TargetSnapshotHash=[string]$Snapshot.SHA256;SelectionRevision=$SelectionRevision;ComparisonRevision=$ComparisonRevision;Comparison=$Comparison;ComparisonContentHash=$contentHash;ImportedFromHash=$ImportedFromHash;Provenance=$Provenance;CreatedUtc=(Get-WsmUtc)}
    $storedPath=Join-Path $root ('comparison-'+$contentHash+'.json');if([IO.File]::Exists($storedPath)){Assert-WsmNoReparse $storedPath;$existing=Read-WsmTrustedJson $storedPath (Get-FileHash -LiteralPath $storedPath -Algorithm SHA256).Hash;if((Get-WsmHashText ($existing.Comparison | ConvertTo-Json -Depth 100 -Compress)) -ine $contentHash){throw 'Existing owned Target comparison content-addressed path conflicts; preserve it for inspection.'}}else{Write-WsmJson $storedPath $stored}
    [pscustomobject][ordered]@{Status='Succeeded';PairId=$PairId;Path=[IO.Path]::GetFullPath($storedPath);SHA256=(Get-FileHash -LiteralPath $storedPath -Algorithm SHA256).Hash.ToLowerInvariant();ComparisonRevision=$ComparisonRevision;PlanHash=[string]$Ctx.Received.SHA256;TargetSnapshotHash=[string]$Snapshot.SHA256;SourceSnapshotHash=$SourceSnapshotHash;SelectionRevision=$SelectionRevision;AuthoritativeApproval=$false;InformationalOnly=$true;ProductionVerified=$false;Provenance=$Provenance}
}

function New-WsmWizardTargetLocalComparison {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[object[]]$Jobs=@())
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId
    if([int]$ctx.Plan.SchemaVersion -ne 3 -or -not $ctx.Plan.PSObject.Properties['Assistive']){throw 'A schema-3 Assistive approved plan is required for a local Target comparison.'}
    $packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs
    if(-not $packageRecord){throw 'Import and verify the backup package on this Target before creating a local comparison.'}
    if([string]$packageRecord.Package.Manifest.PlanHash -ine [string]$ctx.Received.SHA256){throw 'Verified package is not bound to the received Target plan.'}
    $sourceCatalog=$null
    if([int]$ctx.Plan.Assistive.ContractVersion -eq 2){
        $inventoryPath=Join-Path (Split-Path -Parent ([string]$packageRecord.ManifestPath)) 'controls/source-inventory.json'
        if([IO.File]::Exists($inventoryPath)){
            Assert-WsmNoReparse $inventoryPath;$inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if($inventoryHash -ine [string]$ctx.Plan.Assistive.SourceSnapshotHash){throw 'Package source inventory does not match the sealed source snapshot hash.'}
            $packageInventory=Read-WsmTrustedJson $inventoryPath $inventoryHash;if($packageInventory.PSObject.Properties['SoftwareCatalog']){$sourceCatalog=$packageInventory.SoftwareCatalog}
        }
    }
    if(-not $sourceCatalog -and $ctx.Plan.PSObject.Properties['GeneralHost'] -and $ctx.Plan.GeneralHost -and $ctx.Plan.GeneralHost.PSObject.Properties['SoftwareCatalog']){$sourceCatalog=$ctx.Plan.GeneralHost.SoftwareCatalog}
    if(-not $sourceCatalog){throw 'No trusted source software catalog is available in the approved plan or the verified package.'}
    $snapshot=Get-WsmWizardTargetSnapshot $Workspace $ctx $Jobs;$targetCatalog=$snapshot.Inventory.SoftwareCatalog
    $compared=New-WsmAssistiveSoftwareRows $sourceCatalog $targetCatalog $null @() (Get-WsmAssistiveCoverageComplete $targetCatalog)
    Add-WsmAssistiveSourceCoverageGaps $compared $sourceCatalog
    $comparison=[pscustomobject][ordered]@{Revision=1;SourceSnapshotHash=[string]$ctx.Plan.Assistive.SourceSnapshotHash;TargetSnapshotHash=[string]$snapshot.SHA256;TargetBaselineHash='';SelectionRevision=[int]$ctx.Plan.Assistive.SourceSelectionsVersion;Rows=[object[]]@($compared.Rows);ManualPreparation=[object[]]@($compared.ManualPreparation);VersionDisclaimer=('Source versions, chosen versions and observed target versions are separate evidence. A chosen version or matching version numbers are not compatibility evidence for product behavior, licensing, provider, account scope or workload readiness.'+' Generated locally on the Target from the verified backup set without Manager software-version choices or a first-observed baseline.');CreatedUtc=(Get-WsmUtc)}
    Assert-WsmAssistiveComparisonSnapshotVersions $comparison $snapshot.Inventory $sourceCatalog | Out-Null
    Save-WsmWizardTargetComparisonMaterial -Workspace $Workspace -PairId $PairId -Ctx $ctx -Snapshot $snapshot -Comparison $comparison -SelectionRevision ([int]$comparison.SelectionRevision) -ComparisonRevision 1 -SourceSnapshotHash ([string]$comparison.SourceSnapshotHash) -Provenance TargetLocal -ImportedFromHash ''
}

function Import-WsmWizardTargetComparison {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedHash,[object[]]$Jobs=@())
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId
    if($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'A separately verified comparison SHA-256 is required.'}
    $source=[IO.Path]::GetFullPath($Path);Assert-WsmNoReparse $source;if(-not [IO.File]::Exists($source) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $ExpectedHash){throw 'Comparison path and independently supplied SHA-256 do not match.'}
    $doc=Read-WsmTrustedJson $source $ExpectedHash
    if($doc.Kind -cne 'WizardTargetComparisonMaterial' -or $doc.SchemaVersion -ne 1 -or -not $doc.InformationalOnly -or $doc.PairId -cne $PairId -or $doc.PlanHash -ine $ctx.Received.SHA256){throw 'Comparison is not informational material for this exact received Target plan and pair.'}
    if([int]$doc.SelectionRevision -ne [int]$ctx.Plan.Assistive.SourceSelectionsVersion -or [int]$doc.ComparisonRevision -lt 1){throw 'Comparison selection or revision binding is invalid.'}
    $snapshot=Get-WsmWizardTargetSnapshot $Workspace $ctx $Jobs
    if($doc.TargetSnapshotHash -ine $snapshot.SHA256 -or $doc.Comparison.TargetSnapshotHash -ine $snapshot.SHA256 -or $doc.SourceSnapshotHash -ine $ctx.Plan.Assistive.SourceSnapshotHash -or $doc.Comparison.SourceSnapshotHash -ine $ctx.Plan.Assistive.SourceSnapshotHash -or [int]$doc.Comparison.Revision -ne [int]$doc.ComparisonRevision -or [int]$doc.Comparison.SelectionRevision -ne [int]$doc.SelectionRevision){throw 'Comparison is stale or bound to another Target inventory, sealed Source snapshot, or selection revision.'}
    $sourceCatalog=$null;if($ctx.Plan.PSObject.Properties['GeneralHost'] -and $ctx.Plan.GeneralHost -and $ctx.Plan.GeneralHost.PSObject.Properties['SoftwareCatalog']){$sourceCatalog=$ctx.Plan.GeneralHost.SoftwareCatalog}
    Assert-WsmAssistiveComparisonSnapshotVersions $doc.Comparison $snapshot.Inventory $sourceCatalog | Out-Null
    Save-WsmWizardTargetComparisonMaterial -Workspace $Workspace -PairId $PairId -Ctx $ctx -Snapshot $snapshot -Comparison $doc.Comparison -SelectionRevision ([int]$doc.SelectionRevision) -ComparisonRevision ([int]$doc.ComparisonRevision) -SourceSnapshotHash ([string]$doc.SourceSnapshotHash) -Provenance ManagerImport -ImportedFromHash $ExpectedHash.ToLowerInvariant()
}

function Create-WsmWizardTargetDecisionReceipt {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][ValidateSet('WaitForInstall','RestoreNow')][string]$Decision,[Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Reason,[Parameter(Mandatory)][string[]]$SelectedItemIds,[string[]]$AcceptedUnpreparedItemIds=@(),[object[]]$Jobs=@())
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId
    if([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Reason)){throw 'An explicit responsible owner and reason are required for the Target decision.'}
    $packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs;$snapshot=Get-WsmWizardTargetSnapshot $Workspace $ctx $Jobs;$comparisonRecord=Get-WsmWizardTargetComparisonRecord $Workspace $PairId $ctx.Received.SHA256
    if(-not $comparisonRecord){throw 'Import the current informational Manager comparison before making a Target decision.'}
    $comparison=$comparisonRecord.Comparison
    if($comparisonRecord.Document.TargetSnapshotHash -ine $snapshot.SHA256 -or $comparisonRecord.Document.SourceSnapshotHash -ine $ctx.Plan.Assistive.SourceSnapshotHash -or [int]$comparisonRecord.Document.SelectionRevision -ne [int]$ctx.Plan.Assistive.SourceSelectionsVersion){throw 'Imported comparison no longer matches the current Target inventory, sealed source snapshot and selection.'}
    $allowed=New-WsmAssistiveAllowedSubset $packageRecord.Package.Plan $SelectedItemIds;$selectedUnique=@($SelectedItemIds | Select-Object -Unique);if(@($allowed).Count -ne $selectedUnique.Count){throw 'Target selection contains a duplicate or an item outside the exact sealed approved subset.'}
    $acceptedUnique=@($AcceptedUnpreparedItemIds | Select-Object -Unique);if($acceptedUnique.Count -ne @($AcceptedUnpreparedItemIds).Count){throw 'Accepted-unprepared selection contains duplicate item identities.'}
    $selectedSet=@{};foreach($id in $allowed){$selectedSet[[string]$id]=$true};foreach($id in $acceptedUnique){if(-not $selectedSet.ContainsKey([string]$id)){throw 'Accepted-unprepared item IDs must be a subset of the explicitly selected approved items.'}}
    $dummyDecision=[pscustomobject]@{SelectedItemIds=$allowed;Receipt=[pscustomobject]@{Comparison=$comparison;AcceptedUnpreparedItemIds=@()}}
    $actualIssues=@(Get-WsmAssistiveComparisonDependencyIssues $packageRecord.Package $dummyDecision);$eligible=@{};foreach($issue in $actualIssues){$eligible[[string]$issue.ConsumerItemId]=$true}
    foreach($id in $acceptedUnique){if(-not $eligible.ContainsKey([string]$id)){throw ('Accepted-unprepared item '+$id+' has no current core-derived software dependency issue to accept.') }}
    $args=@{PlanPath=[string]$ctx.Received.Path;PlanHash=[string]$ctx.Received.SHA256;ManifestHash=[string]$packageRecord.ManifestHash;Generation=[int]$packageRecord.Package.Manifest.Generation;TargetSnapshotHash=[string]$snapshot.SHA256;ComparisonRevision=[int]$comparison.Revision;SelectionRevision=[int]$ctx.Plan.Assistive.SourceSelectionsVersion;Decision=$Decision;Owner=$Owner;Reason=$Reason;SelectedItemIds=[string[]]$allowed;AcceptedUnpreparedItemIds=[string[]]$acceptedUnique;Comparison=$comparison}
    $receipt=New-WsmAssistiveTargetDecisionReceipt @args
    $root=Get-WsmWizardTargetMaterialRoot $Workspace $PairId;[void](New-WsmOutputOwnedDirectory $root);$receiptHash=Get-WsmHashText ($receipt | ConvertTo-Json -Depth 100 -Compress);$path=Join-Path $root ('decision-'+$receiptHash+'.json')
    if(-not [IO.File]::Exists($path)){Write-WsmJson $path $receipt}else{$oldHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Assert-WsmNoReparse $path;$old=Read-WsmTrustedJson $path $oldHash;if((Get-WsmHashText ($old | ConvertTo-Json -Depth 100 -Compress)) -ine $receiptHash){throw 'Existing Target decision receipt path conflicts; preserve it for inspection.'}}
    [pscustomobject][ordered]@{Status='Succeeded';PairId=$PairId;ReceiptPath=[IO.Path]::GetFullPath($path);Path=[IO.Path]::GetFullPath($path);ReceiptHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();ManifestHash=[string]$packageRecord.ManifestHash;Generation=[long]$packageRecord.Package.Manifest.Generation;PlanHash=[string]$ctx.Received.SHA256;TargetSnapshotHash=[string]$snapshot.SHA256;ComparisonRevision=[int]$comparison.Revision;SelectionRevision=[int]$ctx.Plan.Assistive.SourceSelectionsVersion;Decision=$Decision;SelectedItemIds=@($allowed);AcceptedUnpreparedItemIds=@($acceptedUnique);AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Get-WsmWizardTargetRestoreProjection {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[object[]]$Jobs=@(),[object[]]$GeneralHostEvidence=@())
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs;$snapshot=Get-WsmWizardTargetSnapshot $Workspace $ctx $Jobs;$decisionRecord=Get-WsmWizardTargetDecisionRecord $Workspace $PairId $ctx.Received.SHA256
    if(-not $decisionRecord){return [pscustomobject][ordered]@{Status='NeedsTargetDecision';PairId=$PairId;PlanHash=[string]$ctx.Received.SHA256;ManifestHash=[string]$packageRecord.ManifestHash;Generation=[long]$packageRecord.Package.Manifest.Generation;TargetSnapshotHash=[string]$snapshot.SHA256;ComparisonRevision=0;SelectedItemIds=@();Rows=@();Problems=@();CanRestore=$false;PreviewHash='';BusinessValidationRequired=$true;ProductionVerified=$false}}
    $decision=$decisionRecord.Receipt
    if($decision.ManifestHash -ine $packageRecord.ManifestHash -or [long]$decision.Generation -ne [long]$packageRecord.Package.Manifest.Generation -or $decision.TargetSnapshotHash -ine $snapshot.SHA256){throw 'Current Target receipt is stale for the delivered package generation or Target inventory; create a new comparison and decision receipt.'}
    $comparisonRecord=Get-WsmWizardTargetComparisonRecord $Workspace $PairId $ctx.Received.SHA256
    if(-not $comparisonRecord -or (Get-WsmHashText ($comparisonRecord.Comparison | ConvertTo-Json -Depth 100 -Compress)) -ine [string]$decision.ComparisonHash){throw 'Target decision receipt does not embed the exact currently imported comparison.'}
    $nonCInputs=Get-WsmWizardSelectedNonCPreviewInputs $Workspace $PairId $ctx.Plan $decision $Jobs;$nonCArgs=$nonCInputs.Arguments
    $stateDirectory=Join-Path $ctx.Profile.WorkRoot 'pairs';$preview=Get-WsmAssistiveRestorePreview @nonCArgs -ManifestPath $packageRecord.ManifestPath -ExpectedHash $packageRecord.ManifestHash -StateDirectory $stateDirectory -AssistiveDecisionReceiptPath $decisionRecord.Path -AssistiveDecisionReceiptHash $decisionRecord.SHA256 -AssistiveTargetSnapshotPath $snapshot.Path -GeneralHostEvidence $GeneralHostEvidence
    $preview | Add-Member NoteProperty WizardNonCEvidenceIssue ([string]$nonCInputs.Issue) -Force
    $nonCTransferPlanHash=if($nonCArgs.ContainsKey('NonCTransferPlanHash')){[string]$nonCArgs['NonCTransferPlanHash']}else{''}
    $nonCResultHash=if($nonCArgs.ContainsKey('NonCResultHash')){[string]$nonCArgs['NonCResultHash']}else{''}
    $previewHash=Get-WsmWizardTargetPreviewHash $preview $PairId ([string]$ctx.Received.SHA256) ([string]$packageRecord.ManifestHash) ([long]$packageRecord.Package.Manifest.Generation) ([string]$decisionRecord.SHA256) ([string]$snapshot.SHA256) ([string]$decision.ComparisonHash) ([int]$decision.ComparisonRevision) ([int]$decision.SelectionRevision) ([string]$decision.Decision)
    [pscustomobject][ordered]@{Status='Previewed';PairId=$PairId;PlanHash=[string]$ctx.Received.SHA256;ManifestPath=[string]$packageRecord.ManifestPath;ManifestHash=[string]$packageRecord.ManifestHash;Generation=[long]$packageRecord.Package.Manifest.Generation;ReceiptPath=[string]$decisionRecord.Path;ReceiptHash=[string]$decisionRecord.SHA256;TargetSnapshotPath=[string]$snapshot.Path;TargetSnapshotHash=[string]$snapshot.SHA256;ComparisonHash=[string]$decision.ComparisonHash;ComparisonRevision=[int]$decision.ComparisonRevision;SelectionRevision=[int]$decision.SelectionRevision;Decision=[string]$decision.Decision;SelectedItemIds=@($preview.SelectedItemIds);Rows=@($preview.Rows);Problems=@($preview.Problems);GeneralHostIssues=@($preview.GeneralHostIssues);Blocked=[bool]$preview.Blocked;CanRestoreIndependentItems=[bool]$preview.CanRestoreIndependentItems;BusinessValidationRequired=$true;ProductionVerified=$false;NonCEvidenceIssue=[string]$nonCInputs.Issue;NonCTransferPlanHash=$nonCTransferPlanHash;NonCResultHash=$nonCResultHash;PreviewHash=$previewHash;ExplicitRestoreRequired=$true}
}

function Invoke-WsmWizardTargetRestore {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$PreviewHash,[object[]]$Jobs=@(),$CancellationToken=$null,[hashtable]$Secrets=@{},[object[]]$GeneralHostEvidence=@(),[string]$OperationId='', [object]$ChallengeContext=$null)
    if($PreviewHash -notmatch '^[a-f0-9]{64}$'){throw 'A current exact Target restore PreviewHash is required.'}
    $projection=Get-WsmWizardTargetRestoreProjection -Workspace $Workspace -PairId $PairId -Jobs $Jobs -GeneralHostEvidence $GeneralHostEvidence
    if($projection.Status -cne 'Previewed'){throw ('Target restore preview is no longer available (current status: '+[string]$projection.Status+'); refresh the preview and require a new explicit restore confirmation.')}
    if($projection.Decision -eq 'WaitForInstall'){
        if($projection.PreviewHash -ine $PreviewHash){throw 'Target deferred decision changed after preview; refresh and require a new explicit resume confirmation.'}
        return [pscustomobject][ordered]@{Status='DeferredSoftware';PairId=$PairId;PlanHash=$projection.PlanHash;ManifestHash=$projection.ManifestHash;Generation=$projection.Generation;Decision='WaitForInstall';SelectedItemIds=@($projection.SelectedItemIds);Rows=@($projection.Rows);JournalPath='';JournalHash='';AttemptOperationId='';NoTargetWrites=$true;ResumeRequiredAfterPreparation=$true;ProductionVerified=$false}
    }
    $package=Test-WsmMigrationPackage $projection.ManifestPath $projection.ManifestHash
    $stateDirectory=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs'
    $paths=Get-WsmOperationPaths $stateDirectory $PairId;$state=Get-WsmOperationState $paths $package
    # A new restore after the choices or installed software changed must not be stuck behind an older parent whose reviewed preview is gone.
    if(Invoke-WsmWizardSupersedeStaleTargetRestoreParent -Workspace $Workspace -PairId $PairId -OperationId $OperationId -PreviewHash $PreviewHash -Jobs $Jobs -GeneralHostEvidence $GeneralHostEvidence -Projection $projection -Package $package){$state=Get-WsmOperationState $paths $package}
    $waitingChallengeResume=$false
    if($state.PSObject.Properties['AssistiveServiceChallenge'] -and [string]$state.AssistiveServiceChallenge.State -ceq 'WaitingForInput'){
        $challenge=$state.AssistiveServiceChallenge;$attempt=$null;if($state.PSObject.Properties['RestoreAttempt']){$attempt=$state.RestoreAttempt}
        if(-not $attempt -or [string]$state.Stage -cne 'WaitingForInput' -or [string]$attempt.Status -cne 'WaitingForInput' -or -not $OperationId -or [string]$challenge.ParentOperationId -cne $OperationId -or [string]$attempt.OperationId -cne $OperationId -or [string]$attempt.ManifestHash -ine $projection.ManifestHash -or [long]$attempt.Generation -ne [long]$projection.Generation -or [string]$attempt.DecisionReceiptHash -ine $projection.ReceiptHash -or [string]$attempt.TargetSnapshotHash -ine $projection.TargetSnapshotHash -or [string]$attempt.WizardPreviewHash -ine $PreviewHash -or [string]$challenge.PreviewHash -ine $PreviewHash -or (@($attempt.SelectedItemIds|Sort-Object -Unique)-join "`n") -cne (@($projection.SelectedItemIds|Sort-Object -Unique)-join "`n")){throw 'Waiting Service challenge does not match the exact durable TargetRestore parent; refresh or explicitly take over through the challenge control.'}
        $waitingChallengeResume=$true
    }
    # A successful restore may itself change the live filesystem rows that fed the
    # preview (for example Create becomes MergeIntoExistingDirectory). Allow only
    # an exact replay of the preview bound into the durable attempt, after all
    # current package/receipt/snapshot bindings were revalidated by the projection.
    if(-not $waitingChallengeResume -and $state.PSObject.Properties['RestoreAttempt'] -and $state.RestoreAttempt.PSObject.Properties['WizardPreviewHash'] -and
       [string]$state.RestoreAttempt.WizardPreviewHash -ceq $PreviewHash -and
       [string]$state.RestoreAttempt.ManifestHash -ieq $projection.ManifestHash -and
       [long]$state.RestoreAttempt.Generation -eq [long]$projection.Generation -and
       [string]$state.RestoreAttempt.DecisionReceiptHash -ieq $projection.ReceiptHash -and
       [string]$state.RestoreAttempt.TargetSnapshotHash -ieq $projection.TargetSnapshotHash -and
       [string]$state.RestoreAttempt.DecisionReceiptPath -ieq $projection.ReceiptPath -and
       [string]$state.RestoreAttempt.TargetSnapshotPath -ieq $projection.TargetSnapshotPath -and
       (@($state.RestoreAttempt.SelectedItemIds | Sort-Object -Unique) -join "`n") -ceq (@($projection.SelectedItemIds | Sort-Object -Unique) -join "`n")) {
        if(@($state.PendingOperations).Count){throw 'The exact reviewed restore attempt has an unresolved journal intent; repair it before retrying.'}
        if($state.Stage -notin @('Succeeded','Partial','RebootRequired','Cancelled')){throw 'The exact reviewed restore attempt is not terminal; inspect its journal and resume through core recovery before retrying.'}
        $journal=Test-WsmJournal $stateDirectory $PairId
        if(-not $journal.Consistent){throw 'The exact reviewed restore attempt journal needs recovery before its result can be replayed.'}
        if(-not $state.RestoreAttempt.PSObject.Properties['ItemResults']){throw 'The exact reviewed restore attempt has no durable item-result projection; retain the journal for review.'}
        $replayResults=@($state.RestoreAttempt.ItemResults)
        $journalProof=Save-WsmWizardRestoreJournalSnapshot $paths $package ([string]$state.RestoreAttempt.OperationId) ([string]$state.Stage);$journalHash=[string]$journalProof.SHA256
        return [pscustomobject][ordered]@{Status=[string]$state.Stage;PairId=$PairId;PlanHash=[string]$projection.PlanHash;ManifestHash=[string]$projection.ManifestHash;Generation=[long]$projection.Generation;Decision=[string]$projection.Decision;TargetSnapshotHash=[string]$projection.TargetSnapshotHash;DecisionReceiptHash=[string]$projection.ReceiptHash;SelectedItemIds=@($state.RestoreAttempt.SelectedItemIds);Rows=@($projection.Rows);ItemResults=$replayResults;ItemResultsHash=(Get-WsmHashText ($replayResults|ConvertTo-Json -Depth 100 -Compress));Deferred=@($projection.Rows | Where-Object Status -in @('Deferred','DeferredSoftware','Blocked','BlockedConflict','ManualEvidenceRequired'));JournalPath=[string]$journalProof.Path;JournalHash=$journalHash;AttemptOperationId=[string]$state.RestoreAttempt.OperationId;Stage=[string]$state.Stage;PendingOperations=@();BusinessValidationRequired=$true;ProductionVerified=$false;AuthoritativeApproval=$false;Replay=$true}
    }
    if($projection.PreviewHash -ine $PreviewHash){throw ('Target restore context changed after preview (reviewed '+$PreviewHash+', current '+[string]$projection.PreviewHash+'); refresh the preview and require a new explicit restore confirmation.')}
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$decisionRecord=Get-WsmWizardTargetDecisionRecord $Workspace $PairId $ctx.Received.SHA256;$nonCInputs=Get-WsmWizardSelectedNonCPreviewInputs $Workspace $PairId $ctx.Plan $decisionRecord.Receipt $Jobs;$nonCArgs=$nonCInputs.Arguments
    $freshPreview=Get-WsmAssistiveRestorePreview @nonCArgs -ManifestPath $projection.ManifestPath -ExpectedHash $projection.ManifestHash -StateDirectory (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs') -AssistiveDecisionReceiptPath $projection.ReceiptPath -AssistiveDecisionReceiptHash $projection.ReceiptHash -AssistiveTargetSnapshotPath $projection.TargetSnapshotPath -GeneralHostEvidence $GeneralHostEvidence
    $freshPreview | Add-Member NoteProperty WizardNonCEvidenceIssue ([string]$nonCInputs.Issue) -Force
    $freshHash=Get-WsmWizardTargetPreviewHash $freshPreview $PairId $projection.PlanHash $projection.ManifestHash ([long]$projection.Generation) $projection.ReceiptHash $projection.TargetSnapshotHash $projection.ComparisonHash ([int]$projection.ComparisonRevision) ([int]$projection.SelectionRevision) ([string]$projection.Decision)
    if($freshHash -ine $PreviewHash){throw 'Target preview rows or readiness gates changed before restore; refresh and require a new explicit confirmation.'}
    $freshPreview | Add-Member NoteProperty WizardPreviewHash $PreviewHash -Force
    if(-not $waitingChallengeResume -and $state.PSObject.Properties['RestoreAttempt'] -and [string]$state.RestoreAttempt.Status -cne 'Superseded' -and [string]$state.RestoreAttempt.ManifestHash -ieq $projection.ManifestHash -and [string]$state.RestoreAttempt.DecisionReceiptHash -ieq $projection.ReceiptHash -and [long]$state.RestoreAttempt.Generation -eq [long]$projection.Generation){
        if(@($state.PendingOperations).Count){throw 'The exact current restore attempt has an unresolved journal intent; repair it before retrying.'}
        if($state.Stage -in @('Succeeded','Partial','RebootRequired')){if(-not $state.RestoreAttempt.PSObject.Properties['ItemResults']){throw 'The exact current restore attempt has no durable item-result projection; retain the journal for review.'};$result=[pscustomobject]@{Results=@($state.RestoreAttempt.ItemResults);Deferred=@($projection.Rows | Where-Object Status -in @('Deferred','DeferredSoftware','Blocked','BlockedConflict','ManualEvidenceRequired'))}}
        else{throw 'The exact current restore attempt is not terminal; inspect its journal and resume through core recovery before retrying.'}
    }else{$result=Invoke-WsmAssistiveRestore $package $projection.ManifestHash $stateDirectory $Secrets @{} $CancellationToken $GeneralHostEvidence $projection.ReceiptPath $projection.ReceiptHash $projection.TargetSnapshotPath $freshPreview $OperationId $ChallengeContext;if($result -and $result.PSObject.Properties['Status'] -and [string]$result.Status -ceq 'WaitingForInput'){
        return [pscustomobject][ordered]@{Status='WaitingForInput';PairId=$PairId;ParentOperationId=[string]$result.ParentOperationId;PlanHash=[string]$projection.PlanHash;ManifestHash=[string]$projection.ManifestHash;Generation=[long]$projection.Generation;Decision=[string]$projection.Decision;SelectedItemIds=@($projection.SelectedItemIds);RequiredSecretRefs=@($result.RequiredSecretRefs);CredentialRequirements=$(if($result.PSObject.Properties['CredentialRequirements']){@($result.CredentialRequirements)}else{@()});ServiceReservations=@($result.ServiceReservations);PreviewHash=$PreviewHash;NoTargetWrites=$(if($result.PSObject.Properties['NoTargetWrites']){[bool]$result.NoTargetWrites}else{$true});ResumeRequired=$true;CredentialNotice=$(if($result.PSObject.Properties['CredentialNotice']){[string]$result.CredentialNotice}else{''});ProductionVerified=$false}
    };$state=Get-WsmOperationState $paths $package}
    $journalProof=Save-WsmWizardRestoreJournalSnapshot $paths $package ([string]$state.RestoreAttempt.OperationId) ([string]$state.Stage);$journalHash=[string]$journalProof.SHA256
    $attempt=$null;if($state.PSObject.Properties['RestoreAttempt']){$attempt=$state.RestoreAttempt}
    $itemResults=@($result.Results)
    [pscustomobject][ordered]@{Status=[string]$state.Stage;PairId=$PairId;PlanHash=[string]$projection.PlanHash;ManifestHash=[string]$projection.ManifestHash;Generation=[long]$projection.Generation;Decision=[string]$projection.Decision;TargetSnapshotHash=[string]$projection.TargetSnapshotHash;DecisionReceiptHash=[string]$projection.ReceiptHash;SelectedItemIds=@($projection.SelectedItemIds);Rows=@($projection.Rows);ItemResults=$itemResults;ItemResultsHash=(Get-WsmHashText ($itemResults|ConvertTo-Json -Depth 100 -Compress));Deferred=@($result.Deferred);CredentialNotice=$(if($result.PSObject.Properties['CredentialNotice']){[string]$result.CredentialNotice}else{''});JournalPath=[string]$journalProof.Path;JournalHash=$journalHash;AttemptOperationId=$(if($attempt){[string]$attempt.OperationId}else{''});Stage=[string]$state.Stage;PendingOperations=@($state.PendingOperations);BusinessValidationRequired=$true;ProductionVerified=$false;AuthoritativeApproval=$false}
}

function Test-WsmWizardContinuationDriftExplained($Attempt,$State,$Projection) {
    # A preview hash that differs only because of this same parent's own native work (a pending intent, an item it
    # already wrote or a recorded item result) is not a changed review. Everything else, including any change of the
    # package, receipt, snapshot or selection, still means a new preview is required. Without stored per-row digests
    # the strict whole-preview comparison applies.
    if(-not $Attempt.PSObject.Properties['PreviewRowHashes'] -or -not @($Attempt.PreviewRowHashes).Count){return $false}
    if([string]$Attempt.ManifestHash -ine [string]$Projection.ManifestHash -or [long]$Attempt.Generation -ne [long]$Projection.Generation -or [string]$Attempt.DecisionReceiptHash -ine [string]$Projection.ReceiptHash -or [string]$Attempt.TargetSnapshotHash -ine [string]$Projection.TargetSnapshotHash -or (@($Attempt.SelectedItemIds|Sort-Object -Unique)-join "`n") -cne (@($Projection.SelectedItemIds|Sort-Object -Unique)-join "`n")){return $false}
    $stored=@{};foreach($entry in @($Attempt.PreviewRowHashes)){$stored[[string]$entry.ItemId]=[string]$entry.Hash}
    $fresh=@{};foreach($entry in @(Get-WsmAssistivePreviewRowHashes $Projection.Rows)){$fresh[[string]$entry.ItemId]=[string]$entry.Hash}
    $own=@{}
    foreach($op in @($State.PendingOperations)){$own[[string]$op.ItemId]=$true}
    foreach($row in @($State.Items)){if($row -and $row.PSObject.Properties['AppliedManifestHash'] -and [string]$row.AppliedManifestHash -ieq [string]$Attempt.ManifestHash){$own[[string]$row.ItemId]=$true}}
    if($Attempt.PSObject.Properties['ItemResults']){foreach($result in @($Attempt.ItemResults)){$own[[string]$result.ItemId]=$true}}
    $changed=@();foreach($key in @($stored.Keys)+@($fresh.Keys|Where-Object {-not $stored.ContainsKey($_)})){if(-not $fresh.ContainsKey($key) -or -not $stored.ContainsKey($key) -or $fresh[$key] -cne $stored[$key]){$changed+=@($key)}}
    if(-not $changed.Count){return $false}
    foreach($key in $changed){if(-not $own.ContainsKey($key)){return $false}}
    $true
}

function Set-WsmWizardContinuationResult($Paths,$Package,[string]$ParentOperationId,[string]$ContinuationId,$Result) {
    # The durable result carries only statuses and hashes, never credentials. Recorded under the workspace lock with its journal event.
    Invoke-WsmLocked $Paths.Root {
        $current=Get-WsmOperationState $Paths $Package;$currentAttempt=$current.RestoreAttempt
        if(-not $currentAttempt -or [string]$currentAttempt.OperationId -cne $ParentOperationId){throw 'The TargetRestore parent changed while its continuation result was being recorded.'}
        $records=@($currentAttempt.Continuations);$matched=@($records|Where-Object {[string]$_.ContinuationId -ceq $ContinuationId});if($matched.Count -ne 1){throw 'The continuation record is missing; inspect the durable TargetRestore parent.'}
        $matched[0]|Add-Member NoteProperty Result $Result -Force;$matched[0]|Add-Member NoteProperty CompletedUtc (Get-WsmUtc) -Force
        Add-WsmJournal $Paths $current 'AssistiveRestoreContinuation' '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;ContinuationId=$ContinuationId;Phase='Completed';Result=$Result})
    }
}

function Test-WsmWizardTargetRestorePreviewCurrent($Attempt,$State,$Projection) {
    # The one judgment of "the reviewed preview of this parent is still the current preview": exact hash, or a difference
    # that only this parent's own native work explains. Resume, the HTML secret reply, the CLI prompt and a new restore all use it.
    if(-not $Attempt -or -not $Attempt.PSObject.Properties['WizardPreviewHash']){return $false}
    $stored=[string]$Attempt.WizardPreviewHash;if($stored -notmatch '^[a-f0-9]{64}$'){return $false}
    if(-not $Projection -or [string]$Projection.Status -cne 'Previewed'){return $false}
    if([string]$Projection.PreviewHash -ieq $stored){return $true}
    [bool](Test-WsmWizardContinuationDriftExplained $Attempt $State $Projection)
}

function Update-WsmWizardTargetRestorePreviewBinding {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$StateDirectory,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ParentOperationId,[Parameter(Mandatory)]$Projection,$Package=$null)
    # The single rebind point (E3b-4). Only when the one shared judgment says the reviewed preview is still current (exact hash, or a difference
    # that this parent's own writes fully explain) is the durable attempt/challenge binding moved to the current preview hash. An equal hash writes
    # nothing; a false judgment throws the existing "preview changed" error so the caller takes the revoke path. No comparison is loosened here.
    Assert-WsmId $PairId;Assert-WsmId $ParentOperationId
    $paths=Get-WsmOperationPaths $StateDirectory $PairId
    Invoke-WsmLocked $paths.Root {
        $current=if($Package){Get-WsmOperationState $paths $Package}else{Read-WsmJson $paths.State}
        if(-not $current.PSObject.Properties['RestoreAttempt'] -or -not $current.RestoreAttempt -or [string]$current.RestoreAttempt.OperationId -cne $ParentOperationId){throw 'The TargetRestore parent changed while its preview binding was being refreshed.'}
        $currentAttempt=$current.RestoreAttempt
        if([string]$currentAttempt.Status -cnotin @('Running','WaitingForInput')){throw 'The TargetRestore parent is no longer active, so its preview binding cannot be refreshed.'}
        $storedHash=[string]$currentAttempt.WizardPreviewHash
        $currentChallenge=$null
        if($current.PSObject.Properties['AssistiveServiceChallenge'] -and $current.AssistiveServiceChallenge -and [string]$current.AssistiveServiceChallenge.ParentOperationId -ceq $ParentOperationId -and [string]$current.AssistiveServiceChallenge.State -cin @('WaitingForInput','Running')){
            $currentChallenge=$current.AssistiveServiceChallenge
            if([string]$currentChallenge.PreviewHash -ine $storedHash){throw 'The durable challenge and attempt are bound to different previews; refusing to rebind.'}
        }
        if(-not (Test-WsmWizardTargetRestorePreviewCurrent $currentAttempt $current $Projection)){throw 'Current TargetRestore preview no longer matches the durable waiting parent.'}
        $newHash=[string]$Projection.PreviewHash
        if($newHash -ieq $storedHash){return $storedHash}
        $rowHashes=@(Get-WsmAssistivePreviewRowHashes $Projection.Rows)
        $currentAttempt|Add-Member NoteProperty WizardPreviewHash $newHash -Force
        if($currentAttempt.PSObject.Properties['PreviewRowHashes']){$currentAttempt|Add-Member NoteProperty PreviewRowHashes @($rowHashes) -Force}
        if($currentChallenge){$currentChallenge.PreviewHash=$newHash;$currentChallenge.UpdatedUtc=Get-WsmUtc}
        Add-WsmJournal $paths $current 'AssistiveRestorePreviewRebound' '' ([pscustomobject][ordered]@{ParentOperationId=$ParentOperationId;PreviousPreviewHash=$storedHash;PreviewHash=$newHash;PreviewRowHashes=@($rowHashes);Reason='OwnWritesExplained'})
        $newHash
    }
}

function Resolve-WsmWizardTargetRestorePreviewBinding {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ParentOperationId,[Parameter(Mandatory)][string]$PreviewHash,[object[]]$Jobs=@(),[object[]]$GeneralHostEvidence=@())
    # Re-reads the current preview and, only when the shared judgment accepts it (own writes explain the difference), rebinds the durable parent to it.
    # Returns the hash later strict comparisons must use: the new one after a rebind, otherwise the given one unchanged (a false judgment is never rebound).
    Assert-WsmId $PairId;Assert-WsmId $ParentOperationId
    $stateDirectory=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs';$statePath=Join-Path (Join-Path $stateDirectory $PairId) 'state.json'
    if(-not [IO.File]::Exists($statePath)){return $PreviewHash}
    $state=Read-WsmJson $statePath
    if(-not $state.PSObject.Properties['RestoreAttempt'] -or -not $state.RestoreAttempt -or [string]$state.RestoreAttempt.OperationId -cne $ParentOperationId -or [string]$state.RestoreAttempt.Status -cnotin @('Running','WaitingForInput')){return $PreviewHash}
    if([string]$state.RestoreAttempt.WizardPreviewHash -ine $PreviewHash){return $PreviewHash}
    $projection=$null;try{$projection=Get-WsmWizardTargetRestoreProjection -Workspace $Workspace -PairId $PairId -Jobs $Jobs -GeneralHostEvidence $GeneralHostEvidence}catch{return $PreviewHash}
    if(-not $projection -or [string]$projection.Status -cne 'Previewed'){return $PreviewHash}
    if([string]$projection.PreviewHash -ieq $PreviewHash){return $PreviewHash}
    if(-not (Test-WsmWizardTargetRestorePreviewCurrent $state.RestoreAttempt $state $projection)){return $PreviewHash}
    [string](Update-WsmWizardTargetRestorePreviewBinding -StateDirectory $stateDirectory -PairId $PairId -ParentOperationId $ParentOperationId -Projection $projection)
}

function Revoke-WsmWizardTargetRestoreParent {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$StateDirectory,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ParentOperationId,[string]$Reason='PreviewChanged',$Package=$null,[string]$ContinuationId='',$ContinuationResult=$null,[string]$Actor='',[string]$SessionId='')
    # Reviewed context changed: revoke the challenge, supersede the parent and release its Service reservations. No native write happens
    # and no pending intent is touched. Shared by Resume, the HTML secret reply and a new restore over a stale parent.
    Assert-WsmId $PairId;Assert-WsmId $ParentOperationId
    $paths=Get-WsmOperationPaths $StateDirectory $PairId
    Invoke-WsmLocked $paths.Root {
        $current=if($Package){Get-WsmOperationState $paths $Package}else{Read-WsmJson $paths.State}
        if(-not $current.PSObject.Properties['RestoreAttempt'] -or -not $current.RestoreAttempt -or [string]$current.RestoreAttempt.OperationId -cne $ParentOperationId){throw 'The TargetRestore parent changed while it was being superseded.'}
        $currentAttempt=$current.RestoreAttempt
        if([string]$currentAttempt.Status -cnotin @('Running','WaitingForInput')){throw 'The TargetRestore parent is no longer active and cannot be superseded.'}
        if($current.PSObject.Properties['AssistiveServiceChallenge'] -and $current.AssistiveServiceChallenge){
            $currentChallenge=$current.AssistiveServiceChallenge
            if([string]$currentChallenge.State -cin @('WaitingForInput','Running')){
                if(-not @($current.PendingOperations).Count){foreach($reservation in @($currentChallenge.ServiceReservations)){Revoke-WsmAssistiveServiceChallengeReservation -Workspace $StateDirectory -ResourceKey ([string]$reservation.ResourceKey) -PairId $PairId -ItemId ([string]$reservation.ItemId) -OperationId $ParentOperationId -Created ([bool]$reservation.Created) | Out-Null}}
                $currentChallenge.State='Revoked';$currentChallenge|Add-Member NoteProperty RevokeReason $Reason -Force;$currentChallenge.UpdatedUtc=Get-WsmUtc
            }
        }
        $currentAttempt|Add-Member NoteProperty Status 'Superseded' -Force;$currentAttempt|Add-Member NoteProperty SupersededUtc (Get-WsmUtc) -Force;$current.Stage='Superseded'
        if($ContinuationId){
            $records=@();if($currentAttempt.PSObject.Properties['Continuations']){$records=@($currentAttempt.Continuations)}
            $currentAttempt|Add-Member NoteProperty Continuations (@($records)+@([pscustomobject][ordered]@{ContinuationId=$ContinuationId;StartedUtc=(Get-WsmUtc);Actor=$Actor;SessionId=$SessionId;Result=$ContinuationResult})) -Force
            Add-WsmJournal $paths $current 'AssistiveRestoreContinuation' '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;ContinuationId=$ContinuationId;Phase='Superseded';Reason=$Reason;Actor=$Actor;SessionId=$SessionId;Result=$ContinuationResult})
        }else{
            Add-WsmJournal $paths $current 'AssistiveRestoreParentSuperseded' '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;Reason=$Reason})
        }
    }
}

function Stop-WsmWizardTargetRestoreParent {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$StateDirectory,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ParentOperationId,[object[]]$Jobs=@())
    # Sticky cancel of an interrupted (or still waiting) parent with no live worker: attempt and challenge become Cancelled and the
    # Service reservations are released. Native objects already written and the pending records are kept untouched for later review.
    Assert-WsmId $PairId;Assert-WsmId $ParentOperationId
    foreach($job in @($Jobs)){if($job -and $job.PSObject.Properties['jobId'] -and [string]$job.jobId -ceq $ParentOperationId -and $job.PSObject.Properties['status'] -and [string]$job.status -cin @('Running','CancelRequested')){throw 'The TargetRestore parent still has a running worker; request a safe cancellation instead.'}}
    $paths=Get-WsmOperationPaths $StateDirectory $PairId
    Invoke-WsmLocked $paths.Root {
        $current=Read-WsmJson $paths.State
        if($current.PairId -cne $PairId -or -not $current.PSObject.Properties['RestoreAttempt'] -or -not $current.RestoreAttempt -or [string]$current.RestoreAttempt.OperationId -cne $ParentOperationId){throw 'No durable TargetRestore parent matches the requested ParentOperationId.'}
        $currentAttempt=$current.RestoreAttempt
        if([string]$currentAttempt.Status -cnotin @('Running','WaitingForInput')){throw ('The TargetRestore parent already reached a terminal state ('+[string]$currentAttempt.Status+') and cannot be cancelled again.')}
        $pendingCount=@($current.PendingOperations).Count
        if($current.PSObject.Properties['AssistiveServiceChallenge'] -and $current.AssistiveServiceChallenge){
            $currentChallenge=$current.AssistiveServiceChallenge
            if([string]$currentChallenge.State -cin @('WaitingForInput','Running')){
                if(-not $pendingCount){foreach($reservation in @($currentChallenge.ServiceReservations)){Revoke-WsmAssistiveServiceChallengeReservation -Workspace $StateDirectory -ResourceKey ([string]$reservation.ResourceKey) -PairId $PairId -ItemId ([string]$reservation.ItemId) -OperationId $ParentOperationId -Created ([bool]$reservation.Created) | Out-Null}}
                $currentChallenge.State='Cancelled';$currentChallenge|Add-Member NoteProperty CancelReason 'Operator cancelled interrupted TargetRestore parent' -Force;$currentChallenge.UpdatedUtc=Get-WsmUtc
            }
        }
        $currentAttempt|Add-Member NoteProperty Status 'Cancelled' -Force;$currentAttempt|Add-Member NoteProperty CancelledUtc (Get-WsmUtc) -Force;$current.Stage='Cancelled'
        Add-WsmJournal $paths $current 'AssistiveRestoreParentCancelled' '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;PendingOperationCount=$pendingCount})
        [pscustomobject][ordered]@{Status='Cancelled';PairId=$PairId;ParentOperationId=$ParentOperationId;PendingOperationCount=$pendingCount;NoTargetWrites=$true;ProductionVerified=$false}
    }
}

function Invoke-WsmWizardSupersedeStaleTargetRestoreParent {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[string]$OperationId='',[string]$PreviewHash='',[object[]]$Jobs=@(),[object[]]$GeneralHostEvidence=@(),$Projection=$null,$Package=$null)
    # Starting a new TargetRestore after the choices or the installed software changed: an older non-terminal parent whose reviewed
    # preview is no longer current is revoked first (returns its id). A live worker refuses; an unchanged preview, an unresolved native
    # intent or an unjudgeable preview keeps the existing rules (resume or explicit takeover, never an automatic revoke).
    Assert-WsmId $PairId
    $stateDirectory=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs';$statePath=Join-Path (Join-Path $stateDirectory $PairId) 'state.json'
    if(-not [IO.File]::Exists($statePath)){return ''}
    $state=Read-WsmJson $statePath
    if(-not $state.PSObject.Properties['RestoreAttempt'] -or -not $state.RestoreAttempt){return ''}
    $attempt=$state.RestoreAttempt;$oldId=[string]$attempt.OperationId
    if(-not $oldId -or $oldId -ceq $OperationId -or [string]$attempt.Status -cnotin @('Running','WaitingForInput') -or [string]$state.Stage -cnotin @('Running','WaitingForInput')){return ''}
    foreach($job in @($Jobs)){if($job -and $job.PSObject.Properties['jobId'] -and [string]$job.jobId -ceq $oldId -and $job.PSObject.Properties['status'] -and [string]$job.status -cin @('Running','CancelRequested')){throw 'An earlier TargetRestore parent still has a running worker; wait for it or request its safe cancellation before starting another restore.'}}
    if(-not $Projection){$Projection=Get-WsmWizardTargetRestoreProjection -Workspace $Workspace -PairId $PairId -Jobs $Jobs -GeneralHostEvidence $GeneralHostEvidence}
    if([string]$Projection.Status -cne 'Previewed'){return ''}
    if($PreviewHash -and [string]$Projection.PreviewHash -ine $PreviewHash){return ''}
    if(Test-WsmWizardTargetRestorePreviewCurrent $attempt $state $Projection){return ''}
    if(@($state.PendingOperations).Count){return ''}
    if(-not $Package){$Package=Test-WsmMigrationPackage $Projection.ManifestPath $Projection.ManifestHash}
    Revoke-WsmWizardTargetRestoreParent -StateDirectory $stateDirectory -PairId $PairId -ParentOperationId $oldId -Reason 'SupersededByNewPreview' -Package $Package
    $oldId
}

function Get-WsmWizardTargetRestoreResumePreview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[string]$ParentOperationId='',[object[]]$Jobs=@(),[object[]]$GeneralHostEvidence=@())
    # Read-only: never writes a file, takes a lock or changes an owner. Carries no secret.
    Assert-WsmId $PairId
    $result=[ordered]@{Resumable=$false;Reason='NoParent';PreviewCurrent=$false;PendingItems=@();PendingCount=0;ChallengeState='';CredentialRequirements=@();ParentOperationId='';PreviewHash=''}
    $statePath=Join-Path (Join-Path (Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs') $PairId) 'state.json'
    if(-not [IO.File]::Exists($statePath)){return [pscustomobject]$result}
    Assert-WsmNoReparse $statePath
    $state=Read-WsmJson $statePath
    if(-not $state.PSObject.Properties['RestoreAttempt'] -or -not $state.RestoreAttempt){return [pscustomobject]$result}
    $attempt=$state.RestoreAttempt;$result.ParentOperationId=[string]$attempt.OperationId;if($attempt.PSObject.Properties['WizardPreviewHash']){$result.PreviewHash=[string]$attempt.WizardPreviewHash}
    if($ParentOperationId -and [string]$attempt.OperationId -cne $ParentOperationId){$result.Reason='ParentMismatch';return [pscustomobject]$result}
    $challenge=$null;if($state.PSObject.Properties['AssistiveServiceChallenge'] -and $state.AssistiveServiceChallenge){$challenge=$state.AssistiveServiceChallenge;$result.ChallengeState=[string]$challenge.State;if($challenge.PSObject.Properties['Requirements']){$result.CredentialRequirements=@($challenge.Requirements)}}
    $attemptStatus=[string]$attempt.Status
    if($attemptStatus -ceq 'Superseded' -or [string]$state.Stage -ceq 'Superseded' -or $result.ChallengeState -ceq 'Revoked'){$result.Reason='Superseded';return [pscustomobject]$result}
    if($attemptStatus -ceq 'Cancelled' -or [string]$state.Stage -ceq 'Cancelled' -or $result.ChallengeState -ceq 'Cancelled'){$result.Reason='Cancelled';return [pscustomobject]$result}
    if($attemptStatus -cnotin @('Running','WaitingForInput') -or [string]$state.Stage -cnotin @('Running','WaitingForInput')){$result.Reason='Terminal';return [pscustomobject]$result}
    $pending=@($state.PendingOperations);$result.PendingCount=$pending.Count
    $names=@{}
    $projection=$null;try{$projection=Get-WsmWizardTargetRestoreProjection -Workspace $Workspace -PairId $PairId -Jobs $Jobs -GeneralHostEvidence $GeneralHostEvidence}catch{$projection=$null}
    if($projection -and [string]$projection.Status -ceq 'Previewed'){try{$package=Test-WsmMigrationPackage $projection.ManifestPath $projection.ManifestHash;foreach($item in @($package.Plan.Items)){$names[[string]$item.ItemId]=[string]$item.Name}}catch{}}
    $result.PendingItems=@(foreach($op in $pending){$itemId=[string]$op.ItemId;$phase='';if($op.PSObject.Properties['Phase']){$phase=[string]$op.Phase};[pscustomobject][ordered]@{itemId=$itemId;displayName=$(if($names.ContainsKey($itemId)){$names[$itemId]}else{$itemId});phase=$phase}})
    $result.Resumable=$true;$result.Reason='Resumable'
    if(-not $projection -or [string]$projection.Status -cne 'Previewed'){$result.Reason='PreviewUnavailable'}
    elseif(Test-WsmWizardTargetRestorePreviewCurrent $attempt $state $projection){$result.PreviewCurrent=$true}
    else{$result.Reason='PreviewChanged'}
    [pscustomobject]$result
}

function Resume-WsmWizardTargetRestore {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ParentOperationId,[Parameter(Mandatory)][string]$ContinuationId,[object[]]$Jobs=@(),$CancellationToken=$null,[hashtable]$Secrets=@{},[object[]]$GeneralHostEvidence=@(),[object]$ChallengeContext=$null)
    # Explicit continuation of one interrupted or still-waiting TargetRestore parent. A restart never resumes by itself.
    Assert-WsmId $PairId;Assert-WsmId $ParentOperationId;Assert-WsmId $ContinuationId
    $ContinuationId=([Guid]::Parse($ContinuationId)).ToString('D')
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs
    $stateDirectory=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs'
    $paths=Get-WsmOperationPaths $stateDirectory $PairId;$state=Get-WsmOperationState $paths $packageRecord.Package
    if(-not $state.PSObject.Properties['RestoreAttempt'] -or -not $state.RestoreAttempt -or [string]$state.RestoreAttempt.OperationId -cne $ParentOperationId){throw 'No durable TargetRestore parent matches the requested ParentOperationId; preview again and start a new restore.'}
    $attempt=$state.RestoreAttempt
    $sameContinuation=@();if($attempt.PSObject.Properties['Continuations']){$sameContinuation=@($attempt.Continuations|Where-Object {[string]$_.ContinuationId -ceq $ContinuationId})}
    if($sameContinuation.Count){
        if(-not $sameContinuation[0].Result){throw 'This ContinuationId was already started but never recorded a result; use a new ContinuationId.'}
        $replay=$sameContinuation[0].Result.PSObject.Copy();$replay|Add-Member NoteProperty Replay $true -Force;$replay|Add-Member NoteProperty ContinuationId $ContinuationId -Force
        return $replay
    }
    $challenge=$null;if($state.PSObject.Properties['AssistiveServiceChallenge'] -and $state.AssistiveServiceChallenge){$challenge=$state.AssistiveServiceChallenge}
    $challengeState=if($challenge){[string]$challenge.State}else{''};$attemptStatus=[string]$attempt.Status
    if($challengeState -cin @('Cancelled','Revoked') -or $attemptStatus -cin @('Cancelled','Superseded') -or [string]$state.Stage -cin @('Cancelled','Superseded')){throw 'This TargetRestore parent was cancelled or superseded and can never be resumed; preview again to create a new restore.'}
    if([string]$state.Stage -cnotin @('Running','WaitingForInput') -or $attemptStatus -cnotin @('Running','WaitingForInput')){throw ('This TargetRestore parent already reached a terminal result ('+[string]$state.Stage+'); preview again to create a new restore instead of continuing it.')}
    $storedHash=[string]$attempt.WizardPreviewHash;if($storedHash -notmatch '^[a-f0-9]{64}$'){throw 'The durable TargetRestore parent has no exact reviewed preview hash; preview again.'}
    $projection=Get-WsmWizardTargetRestoreProjection -Workspace $Workspace -PairId $PairId -Jobs $Jobs -GeneralHostEvidence $GeneralHostEvidence
    if($projection.Status -cne 'Previewed'){throw ('Target restore preview is no longer available (current status: '+[string]$projection.Status+'); preview again.')}
    $package=Test-WsmMigrationPackage $projection.ManifestPath $projection.ManifestHash
    $contextActor=[string](Get-WsmExecutionActor);$contextSession='';if($ChallengeContext){if($ChallengeContext.PSObject.Properties['Actor']){$contextActor=[string]$ChallengeContext.Actor};if($ChallengeContext.PSObject.Properties['SessionId']){$contextSession=[string]$ChallengeContext.SessionId}}
    # The same judgment (exact hash, or only this parent's own writes explain the difference) decides every caller: resume, secret reply and a new restore.
    $accepted=Test-WsmWizardTargetRestorePreviewCurrent $attempt $state $projection
    if(-not $accepted){
        # Reviewed context changed: revoke the challenge, supersede the parent and release its Service reservations. No native write happens.
        $needsNew=[pscustomobject][ordered]@{Status='NeedsNewPreview';PairId=$PairId;ParentOperationId=$ParentOperationId;ContinuationId=$ContinuationId;PreviousPreviewHash=$storedHash;CurrentPreviewHash=[string]$projection.PreviewHash;Reason='PreviewChanged';NoTargetWrites=$true;ProductionVerified=$false}
        Revoke-WsmWizardTargetRestoreParent -StateDirectory $stateDirectory -PairId $PairId -ParentOperationId $ParentOperationId -Reason 'PreviewChanged' -Package $package -ContinuationId $ContinuationId -ContinuationResult $needsNew -Actor $contextActor -SessionId $contextSession
        return $needsNew
    }
    # Accepted because only this parent's own writes explain the difference: move the durable binding to the current preview once, before the continuation runs.
    $storedHash=[string](Update-WsmWizardTargetRestorePreviewBinding -StateDirectory $stateDirectory -PairId $PairId -ParentOperationId $ParentOperationId -Projection $projection -Package $package)
    Invoke-WsmLocked $paths.Root {
        $current=Get-WsmOperationState $paths $package;$currentAttempt=$current.RestoreAttempt
        if(-not $currentAttempt -or [string]$currentAttempt.OperationId -cne $ParentOperationId){throw 'The TargetRestore parent changed before its continuation was recorded.'}
        $records=@();if($currentAttempt.PSObject.Properties['Continuations']){$records=@($currentAttempt.Continuations)}
        if(@($records|Where-Object {[string]$_.ContinuationId -ceq $ContinuationId}).Count){throw 'This ContinuationId is already in progress; use a new ContinuationId.'}
        $currentAttempt|Add-Member NoteProperty Continuations (@($records)+@([pscustomobject][ordered]@{ContinuationId=$ContinuationId;StartedUtc=(Get-WsmUtc);Actor=$contextActor;SessionId=$contextSession;Result=$null})) -Force
        Add-WsmJournal $paths $current 'AssistiveRestoreContinuation' '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;ContinuationId=$ContinuationId;Actor=$contextActor;SessionId=$contextSession;Phase='Started'})
    }
    $state=Get-WsmOperationState $paths $package
    if($state.PSObject.Properties['AssistiveServiceChallenge'] -and $state.AssistiveServiceChallenge -and [string]$state.AssistiveServiceChallenge.State -ceq 'Running'){
        # Secrets were accepted but the process died. Only a provable pre-write state asks for fresh input under the current session; an old secret is never replayed.
        $preWrite=$null;try{$preWrite=Test-WsmAssistiveServiceChallengePreWriteRecovery $stateDirectory $state $ParentOperationId}catch{$preWrite=$null}
        if($preWrite){
            $contextRole='Target';$contextId='';$contextRevision=-1
            if($ChallengeContext){if($ChallengeContext.PSObject.Properties['Role']){$contextRole=[string]$ChallengeContext.Role};if($ChallengeContext.PSObject.Properties['ContextId']){$contextId=[string]$ChallengeContext.ContextId};if($ChallengeContext.PSObject.Properties['Revision']){$contextRevision=[int]$ChallengeContext.Revision}}
            if($contextRole -cne 'Target' -or -not $contextActor -or $contextSession.Length -gt 256 -or $contextId.Length -gt 256){throw 'Service credential challenge must bind a valid Target actor/session context.'}
            $waiting=Invoke-WsmLocked $paths.Root {
                $current=Get-WsmOperationState $paths $package;$currentChallenge=$current.AssistiveServiceChallenge;$currentAttempt=$current.RestoreAttempt
                foreach($reservation in @($currentChallenge.ServiceReservations)){Set-WsmAssistiveServiceReservationOperation -Workspace $stateDirectory -ResourceKey ([string]$reservation.ResourceKey) -PairId $PairId -ItemId ([string]$reservation.ItemId) -OperationId $ParentOperationId -State WaitingForInput | Out-Null}
                $currentChallenge.State='WaitingForInput';$currentChallenge.Actor=$contextActor;$currentChallenge.Role=$contextRole;$currentChallenge.SessionId=$contextSession;$currentChallenge.ContextId=$contextId;$currentChallenge.Revision=[int]$contextRevision;$currentChallenge.UpdatedUtc=Get-WsmUtc
                $currentChallenge|Add-Member NoteProperty LastPreWriteRecovery $preWrite -Force
                $currentAttempt|Add-Member NoteProperty Status 'WaitingForInput' -Force;$current.Stage='WaitingForInput'
                $requirements=@();if($currentChallenge.PSObject.Properties['Requirements']){$requirements=@($currentChallenge.Requirements)}
                $waitingResult=[pscustomobject][ordered]@{Status='WaitingForInput';PairId=$PairId;ParentOperationId=$ParentOperationId;ContinuationId=$ContinuationId;PlanHash=[string]$projection.PlanHash;ManifestHash=[string]$projection.ManifestHash;Generation=[long]$projection.Generation;Decision=[string]$projection.Decision;SelectedItemIds=@($projection.SelectedItemIds);RequiredSecretRefs=@($currentChallenge.RequiredSecretRefs);CredentialRequirements=@($requirements);ServiceReservations=@($currentChallenge.ServiceReservations);PreviewHash=$storedHash;NoTargetWrites=$true;ResumeRequired=$true;ProductionVerified=$false}
                Add-WsmJournal $paths $current 'AssistiveServiceCredentialChallengeRebound' '' ([pscustomobject]@{ParentOperationId=$ParentOperationId;ContinuationId=$ContinuationId;Actor=$contextActor;SessionId=$contextSession;ContextId=$contextId;Revision=[int]$contextRevision;PreWriteRecovery=$preWrite})
                $waitingResult
            }
            Set-WsmWizardContinuationResult $paths $package $ParentOperationId $ContinuationId $waiting
            return $waiting
        }
    }
    $nonCInputs=Get-WsmWizardSelectedNonCPreviewInputs $Workspace $PairId $ctx.Plan (Get-WsmWizardTargetDecisionRecord $Workspace $PairId $ctx.Received.SHA256).Receipt $Jobs;$nonCArgs=$nonCInputs.Arguments
    $freshPreview=Get-WsmAssistiveRestorePreview @nonCArgs -ManifestPath $projection.ManifestPath -ExpectedHash $projection.ManifestHash -StateDirectory $stateDirectory -AssistiveDecisionReceiptPath $projection.ReceiptPath -AssistiveDecisionReceiptHash $projection.ReceiptHash -AssistiveTargetSnapshotPath $projection.TargetSnapshotPath -GeneralHostEvidence $GeneralHostEvidence
    $freshPreview | Add-Member NoteProperty WizardNonCEvidenceIssue ([string]$nonCInputs.Issue) -Force
    $freshPreview | Add-Member NoteProperty WizardPreviewHash $storedHash -Force
    $result=Invoke-WsmAssistiveRestore $package $projection.ManifestHash $stateDirectory $Secrets @{} $CancellationToken $GeneralHostEvidence $projection.ReceiptPath $projection.ReceiptHash $projection.TargetSnapshotPath $freshPreview $ParentOperationId $ChallengeContext -Continuation
    if($result -and $result.PSObject.Properties['Status'] -and [string]$result.Status -ceq 'WaitingForInput'){
        # The continuation itself wrote files, so the preview moved: bind the waiting challenge to the preview as it is now (only if the shared judgment accepts it).
        $storedHash=[string](Resolve-WsmWizardTargetRestorePreviewBinding -Workspace $Workspace -PairId $PairId -ParentOperationId $ParentOperationId -PreviewHash $storedHash -Jobs $Jobs -GeneralHostEvidence $GeneralHostEvidence)
        $waiting=[pscustomobject][ordered]@{Status='WaitingForInput';PairId=$PairId;ParentOperationId=[string]$result.ParentOperationId;ContinuationId=$ContinuationId;PlanHash=[string]$projection.PlanHash;ManifestHash=[string]$projection.ManifestHash;Generation=[long]$projection.Generation;Decision=[string]$projection.Decision;SelectedItemIds=@($projection.SelectedItemIds);RequiredSecretRefs=@($result.RequiredSecretRefs);CredentialRequirements=$(if($result.PSObject.Properties['CredentialRequirements']){@($result.CredentialRequirements)}else{@()});ServiceReservations=@($result.ServiceReservations);PreviewHash=$storedHash;NoTargetWrites=$(if($result.PSObject.Properties['NoTargetWrites']){[bool]$result.NoTargetWrites}else{$true});ResumeRequired=$true;CredentialNotice=$(if($result.PSObject.Properties['CredentialNotice']){[string]$result.CredentialNotice}else{''});ProductionVerified=$false}
        Set-WsmWizardContinuationResult $paths $package $ParentOperationId $ContinuationId $waiting
        return $waiting
    }
    $state=Get-WsmOperationState $paths $package
    $itemResults=@($result.Results)
    $compact=[pscustomobject][ordered]@{Status=[string]$state.Stage;Stage=[string]$state.Stage;PairId=$PairId;ParentOperationId=$ParentOperationId;ContinuationId=$ContinuationId;ItemResultsHash=(Get-WsmHashText ($itemResults|ConvertTo-Json -Depth 100 -Compress));ItemStatuses=@($itemResults|ForEach-Object {[pscustomobject][ordered]@{ItemId=[string]$_.ItemId;Status=[string]$_.Status}});PendingOperationCount=[int]@($state.PendingOperations).Count;ProductionVerified=$false}
    Set-WsmWizardContinuationResult $paths $package $ParentOperationId $ContinuationId $compact
    $state=Get-WsmOperationState $paths $package
    $journalProof=Save-WsmWizardRestoreJournalSnapshot $paths $package ([string]$state.RestoreAttempt.OperationId) ([string]$state.Stage);$journalHash=[string]$journalProof.SHA256
    [pscustomobject][ordered]@{Status=[string]$state.Stage;PairId=$PairId;PlanHash=[string]$projection.PlanHash;ManifestHash=[string]$projection.ManifestHash;Generation=[long]$projection.Generation;Decision=[string]$projection.Decision;TargetSnapshotHash=[string]$projection.TargetSnapshotHash;DecisionReceiptHash=[string]$projection.ReceiptHash;SelectedItemIds=@($projection.SelectedItemIds);Rows=@($projection.Rows);ItemResults=$itemResults;ItemResultsHash=(Get-WsmHashText ($itemResults|ConvertTo-Json -Depth 100 -Compress));Deferred=@($result.Deferred);CredentialNotice=$(if($result.PSObject.Properties['CredentialNotice']){[string]$result.CredentialNotice}else{''});JournalPath=[string]$journalProof.Path;JournalHash=$journalHash;AttemptOperationId=[string]$state.RestoreAttempt.OperationId;ContinuationId=$ContinuationId;Stage=[string]$state.Stage;PendingOperations=@($state.PendingOperations);BusinessValidationRequired=$true;ProductionVerified=$false;AuthoritativeApproval=$false}
}

function Save-WsmWizardRestoreJournalSnapshot($Paths,$Package,[string]$OperationId,[string]$ExpectedStage) {
    Assert-WsmId $OperationId
    Invoke-WsmLocked $Paths.Root {
        $current=Get-WsmOperationState $Paths $Package
        if(-not $current.PSObject.Properties['RestoreAttempt'] -or $current.RestoreAttempt.OperationId -cne $OperationId -or $current.Stage -cne $ExpectedStage -or $current.RestoreAttempt.ManifestHash -ine $Package.SHA256 -or [long]$current.RestoreAttempt.Generation -ne [long]$Package.Manifest.Generation){throw 'Restore changed before its immutable result journal could be retained; inspect the current attempt.'}
        Assert-WsmNoReparse $Paths.Journal
        $hash=(Get-FileHash -LiteralPath $Paths.Journal -Algorithm SHA256).Hash.ToLowerInvariant()
        $root=Join-Path $Paths.Root 'restore-journals';[void](New-WsmOutputOwnedDirectory $root)
        $path=Join-Path $root ($hash+'.jsonl');Assert-WsmNoReparse $path
        if(-not [IO.File]::Exists($path)){[IO.File]::Copy($Paths.Journal,$path,$false)}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hash -or (Get-FileHash -LiteralPath $Paths.Journal -Algorithm SHA256).Hash -ine $hash){throw 'Restore journal bytes changed while retaining the result proof.'}
        [pscustomobject]@{Path=[IO.Path]::GetFullPath($path);SHA256=$hash}
    }
}

function Save-WsmWizardTargetAcceptanceArtifact($Paths,$Record) {
    $root=New-WsmOutputOwnedDirectory (Join-Path $Paths.Root 'acceptance-gates')
    $json=$Record | ConvertTo-Json -Depth 40
    $bytes=[Text.Encoding]::UTF8.GetBytes($json)
    $sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    $path=Join-Path $root ($hash+'.json');Assert-WsmNoReparse $path
    if([IO.File]::Exists($path)){
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hash){throw 'Existing acceptance artifact path contains different bytes; preserve it for review.'}
    }else{
        $temporary=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.tmp')
        try{$stream=[IO.File]::Open($temporary,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};[IO.File]::Move($temporary,$path)}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hash){throw 'Acceptance artifact changed while it was being retained.'}
    }
    [pscustomobject]@{Path=[IO.Path]::GetFullPath($path);SHA256=$hash}
}

function Get-WsmWizardTargetAcceptanceRecord([string]$Workspace,[string]$PairId,$Context,$PackageRecord,$Snapshot,$DecisionRecord,[object[]]$Jobs=@()) {
    # Runtime reads only an explicit TargetAcceptance job and its immutable
    # artifact. It never invokes the gate writer or infers success from the
    # mutable operation journal.
    try{
        $statePaths=Get-WsmOperationPaths (Join-Path $Context.Profile.WorkRoot 'pairs') $PairId
        $state=Get-WsmOperationState $statePaths $PackageRecord.Package
        if(-not $state.RestoreAttempt -or [string]$state.Stage -notin @('Succeeded','Partial','RebootRequired','PostCutoverValidationRequired') -or [string]$state.ManifestHash -ine [string]$PackageRecord.ManifestHash -or [long]$state.Generation -ne [long]$PackageRecord.Package.Manifest.Generation){return $null}
        $attempt=$state.RestoreAttempt
        if([string]$attempt.ManifestHash -ine [string]$PackageRecord.ManifestHash -or [long]$attempt.Generation -ne [long]$PackageRecord.Package.Manifest.Generation -or [string]$attempt.DecisionReceiptHash -ine [string]$DecisionRecord.SHA256 -or [string]$attempt.TargetSnapshotHash -ine [string]$Snapshot.SHA256 -or [string]$DecisionRecord.Receipt.Decision -cne 'RestoreNow'){return $null}
        $operationRoot=[IO.Path]::GetFullPath($statePaths.Root).TrimEnd('\')+'\'
        $acceptanceRoot=[IO.Path]::GetFullPath((Join-Path $statePaths.Root 'acceptance-gates')).TrimEnd('\')+'\'
        $journalRoot=[IO.Path]::GetFullPath((Join-Path $statePaths.Root 'restore-journals')).TrimEnd('\')+'\'
        $expectedFinal=Join-Path $statePaths.Root 'validation-Final.json'
        $acceptanceRecords=New-Object 'System.Collections.Generic.List[object]'
        foreach($job in @($Jobs)){
            if(-not $job -or [string](Get-WsmWizardTargetJobField $job action Action) -cne 'TargetAcceptance' -or [string](Get-WsmWizardTargetJobField $job role Role) -cne 'Target' -or [string](Get-WsmWizardTargetJobField $job pairId PairId) -cne $PairId -or [string](Get-WsmWizardTargetJobField $job status Status) -notin @('Succeeded','ReviewRequired')){continue}
            try{if([IO.Path]::GetFullPath([string](Get-WsmWizardTargetJobField $job workspace Workspace)) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
            foreach($output in @((Get-WsmWizardTargetJobField $job outputs Outputs))){
                if(-not $output){continue}
                try{
                    if([string]$output.Status -notin @('FinalAccepted','ReviewRequired') -or [string]$output.PairId -cne $PairId -or [string]$output.PlanHash -ine [string]$Context.Received.SHA256 -or [string]$output.ManifestHash -ine [string]$PackageRecord.ManifestHash -or [long]$output.Generation -ne [long]$PackageRecord.Package.Manifest.Generation -or [string]$output.RestoreAttemptId -cne [string]$attempt.OperationId -or [string]$output.DecisionReceiptHash -ine [string]$DecisionRecord.SHA256 -or [string]$output.TargetSnapshotHash -ine [string]$Snapshot.SHA256){continue}
                    $artifactPath=[IO.Path]::GetFullPath([string]$output.Path);Assert-WsmNoReparse $artifactPath
                    if(-not $artifactPath.StartsWith($acceptanceRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($artifactPath).TrimEnd('\') -ine $acceptanceRoot.TrimEnd('\') -or [IO.Path]::GetFileName($artifactPath) -cne ([string]$output.SHA256+'.json') -or [string]$output.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or -not [IO.File]::Exists($artifactPath) -or (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash -ine [string]$output.SHA256){continue}
                    $record=Read-WsmTrustedJson $artifactPath ([string]$output.SHA256)
                    if([int]$record.SchemaVersion -ne 1 -or [string]$record.Kind -cne 'WizardTargetAcceptanceGates' -or [string]$record.PairId -cne $PairId -or [string]$record.PlanHash -ine [string]$Context.Received.SHA256 -or [string]$record.ManifestHash -ine [string]$PackageRecord.ManifestHash -or [long]$record.Generation -ne [long]$PackageRecord.Package.Manifest.Generation -or [string]$record.RestoreAttemptId -cne [string]$attempt.OperationId -or [string]$record.DecisionReceiptHash -ine [string]$DecisionRecord.SHA256 -or [string]$record.TargetSnapshotHash -ine [string]$Snapshot.SHA256){continue}
                    $finalPath=[IO.Path]::GetFullPath([string]$record.FinalValidationPath);Assert-WsmNoReparse $finalPath
                    if($finalPath -ine [IO.Path]::GetFullPath($expectedFinal) -or [string]$record.FinalValidationHash -notmatch '^[a-fA-F0-9]{64}$' -or -not [IO.File]::Exists($finalPath) -or (Get-FileHash -LiteralPath $finalPath -Algorithm SHA256).Hash -ine [string]$record.FinalValidationHash){continue}
                    $finalValidation=Read-WsmTrustedJson $finalPath ([string]$record.FinalValidationHash)
                    if([string]$finalValidation.Kind -cne 'ValidationResult' -or [string]$finalValidation.PairId -cne $PairId -or [string]$finalValidation.ManifestHash -ine [string]$PackageRecord.ManifestHash -or [long]$finalValidation.Generation -ne [long]$PackageRecord.Package.Manifest.Generation -or [string]$finalValidation.Phase -cne 'Final' -or [bool]$finalValidation.Passed -ne [bool]$record.FinalValidationPassed){continue}
                    $journalSnapshot=[IO.Path]::GetFullPath([string]$record.JournalSnapshotPath);Assert-WsmNoReparse $journalSnapshot
                    if(-not $journalSnapshot.StartsWith($journalRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($journalSnapshot).TrimEnd('\') -ine $journalRoot.TrimEnd('\') -or [IO.Path]::GetFileName($journalSnapshot) -cne ([string]$record.JournalHash+'.jsonl') -or [string]$record.JournalHash -notmatch '^[a-fA-F0-9]{64}$' -or -not [IO.File]::Exists($journalSnapshot) -or (Get-FileHash -LiteralPath $journalSnapshot -Algorithm SHA256).Hash -ine [string]$record.JournalHash){continue}
                    if([bool]$record.Gates.FinalAccepted -ne [bool]$output.FinalAccepted -or [bool]$record.Gates.RetirementReady -ne [bool]$output.RetirementReady -or [string]$output.Status -cne $(if($record.Gates.FinalAccepted){'FinalAccepted'}else{'ReviewRequired'})){continue}
                    $acceptanceRecords.Add([pscustomobject]@{Job=$job;Output=$output;Record=$record;ArtifactPath=$artifactPath;FinalValidation=$finalValidation;JournalSnapshotPath=$journalSnapshot})
                }catch{continue}
            }
        }
        if($acceptanceRecords.Count -ne 1){return $null}
        $acceptanceRecords[0]
    }catch{$null}
}

function Get-WsmWizardTargetTerminalResultForOperation([string]$Workspace,[string]$PairId,[string]$OperationId,[object[]]$Jobs=@()) {
    # EndInvoke can fail after the core has durably closed a restore. Recover only
    # that exact operation's result; never call the restore writer from here.
    if(-not $Workspace -or -not $PairId -or -not $OperationId){return $null}
    try{Assert-WsmId $OperationId}catch{return $null}
    $worker=$null
    foreach($job in @($Jobs)){
        if(-not $job){continue}
        $status=[string](Get-WsmWizardTargetJobField $job status Status);$action=[string](Get-WsmWizardTargetJobField $job action Action)
        $role=[string](Get-WsmWizardTargetJobField $job role Role);$jobPair=[string](Get-WsmWizardTargetJobField $job pairId PairId)
        $jobId=[string](Get-WsmWizardTargetJobField $job jobId JobId);$jobWorkspace=[string](Get-WsmWizardTargetJobField $job workspace Workspace)
        if($action -cne 'TargetRestore' -or $role -cne 'Target' -or $jobPair -cne $PairId -or $jobId -cne $OperationId -or $status -notin @('Failed','Cancelled','Interrupted') -or -not $jobWorkspace){continue}
        try{if([IO.Path]::GetFullPath($jobWorkspace) -ine [IO.Path]::GetFullPath($Workspace)){continue}}catch{continue}
        $worker=$job;break
    }
    if(-not $worker){return $null}
    try{
        $context=Assert-WsmWizardTargetRole $Workspace $PairId
        $packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $context $Jobs
        $snapshot=Get-WsmWizardTargetSnapshot $Workspace $context $Jobs
        $stateDirectory=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs';$paths=Get-WsmOperationPaths $stateDirectory $PairId
        if(-not [IO.File]::Exists($paths.State)){return $null}
        $package=$packageRecord.Package;$state=Get-WsmOperationState $paths $package
        if(-not $state.PSObject.Properties['RestoreAttempt'] -or -not $state.RestoreAttempt){return $null}
        $attempt=$state.RestoreAttempt
        if([string]$attempt.OperationId -cne $OperationId -or [string]$state.PairId -cne $PairId -or
           [string]$state.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$state.Generation -ne [long]$package.Manifest.Generation -or
           [string]$attempt.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$attempt.Generation -ne [long]$package.Manifest.Generation -or
           [string]$attempt.TargetSnapshotHash -ine [string]$snapshot.SHA256 -or [string]$attempt.TargetSnapshotPath -ine [string]$snapshot.Path -or -not $attempt.PSObject.Properties['ItemResults'] -or
           @($state.PendingOperations).Count -gt 0 -or [string]$state.Stage -notin @('Succeeded','Partial','RebootRequired','Cancelled','Failed')){return $null}
        $journal=Test-WsmJournal $stateDirectory $PairId;if(-not $journal.Consistent){return $null}
        $decision=Get-WsmWizardTargetDecisionRecord $Workspace $PairId $context.Received.SHA256
        if(-not $decision -or [string]$attempt.DecisionReceiptPath -cne [string]$decision.Path -or [string]$attempt.DecisionReceiptHash -ine [string]$decision.SHA256 -or
           [string]$decision.Receipt.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$decision.Receipt.Generation -ne [long]$package.Manifest.Generation -or
           [string]$decision.Receipt.TargetSnapshotHash -ine [string]$snapshot.SHA256 -or [string]$decision.Receipt.Decision -cne 'RestoreNow' -or
           (@($attempt.SelectedItemIds | Sort-Object -Unique) -join "`n") -cne (@($decision.Receipt.SelectedItemIds | Sort-Object -Unique) -join "`n")){return $null}
        $journalHash=(Get-FileHash -LiteralPath $paths.Journal -Algorithm SHA256).Hash.ToLowerInvariant()
        $journalRoot=[IO.Path]::GetFullPath((Join-Path $paths.Root 'restore-journals')).TrimEnd('\')+'\'
        $journalSnapshot=Join-Path $journalRoot ($journalHash+'.jsonl');Assert-WsmNoReparse $journalSnapshot
        if(-not [IO.File]::Exists($journalSnapshot)){
            $retained=Save-WsmWizardRestoreJournalSnapshot $paths $package $OperationId ([string]$state.Stage)
            if([string]$retained.SHA256 -ine $journalHash -or [string]$retained.Path -ine $journalSnapshot){return $null}
        }
        if((Get-FileHash -LiteralPath $journalSnapshot -Algorithm SHA256).Hash -ine $journalHash){return $null}
        $projection=Get-WsmWizardTargetRestoreProjection -Workspace $Workspace -PairId $PairId -Jobs $Jobs
        $results=@($attempt.ItemResults);$resultsHash=Get-WsmHashText ($results|ConvertTo-Json -Depth 100 -Compress)
        $stage=[string]$state.Stage
        $deferred=@($projection.Rows | Where-Object Status -in @('Deferred','DeferredSoftware','Blocked','BlockedConflict','ManualEvidenceRequired'))
        [pscustomobject][ordered]@{Status=$stage;PairId=$PairId;PlanHash=[string]$context.Received.SHA256;ManifestHash=[string]$packageRecord.ManifestHash;Generation=[long]$package.Manifest.Generation;Decision='RestoreNow';SelectedItemIds=@($attempt.SelectedItemIds);Rows=@($projection.Rows);ItemResults=$results;ItemResultsHash=$resultsHash;Deferred=$deferred;JournalPath=[IO.Path]::GetFullPath($journalSnapshot);JournalHash=$journalHash;AttemptOperationId=$OperationId;Stage=$stage;PendingOperations=@();BusinessValidationRequired=$true;ProductionVerified=$false;AuthoritativeApproval=$false;Replay=$true;RecoveredAfterWorkerFailure=$true;WorkerStatus=[string](Get-WsmWizardTargetJobField $worker status Status)}
    }catch{return $null}
}

function Get-WsmWizardTargetRestoreAvailability([string]$Workspace,[string]$PairId,$Profile,[object[]]$Jobs=@()) {
    if(-not $Workspace -or -not $PairId -or -not $Profile -or [string]$Profile.Role -cne 'Target'){return $null}
    try{$context=Assert-WsmWizardTargetRole $Workspace $PairId;$packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $context $Jobs;$snapshot=Get-WsmWizardTargetSnapshot $Workspace $context $Jobs}catch{return $null}
    try{$profileWorkRoot=[IO.Path]::GetFullPath([string]$Profile.WorkRoot);$currentWorkRoot=[IO.Path]::GetFullPath($Workspace)}catch{return $null}
    if([string]$Profile.ProfileId -cne [string]$context.Profile.ProfileId -or [string]$Profile.HostId -cne [string]$context.Profile.HostId -or [string]$Profile.Fingerprint -ine [string]$context.Profile.Fingerprint -or $profileWorkRoot -ine $currentWorkRoot){return $null}
    $stateDirectory=Join-Path ([IO.Path]::GetFullPath($Workspace)) 'pairs';$paths=Get-WsmOperationPaths $stateDirectory $PairId
    if(-not [IO.File]::Exists($paths.State)){return $null}
    try{$state=Get-WsmOperationState $paths $packageRecord.Package}catch{return $null}
    if(-not $state.PSObject.Properties['RestoreAttempt'] -or -not $state.RestoreAttempt){return $null}
    $attempt=$state.RestoreAttempt
    foreach($field in @('OperationId','ManifestHash','Generation','DecisionReceiptHash','DecisionReceiptPath','TargetSnapshotHash','TargetSnapshotPath','SelectedItemIds')){if(-not $attempt.PSObject.Properties[$field]){return $null}}
    try{Assert-WsmId ([string]$attempt.OperationId)}catch{return $null}
    if([string]$state.PairId -cne $PairId -or [string]$attempt.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$attempt.Generation -ne [long]$packageRecord.Package.Manifest.Generation -or [string]$state.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$state.Generation -ne [long]$packageRecord.Package.Manifest.Generation -or [string]$attempt.TargetSnapshotHash -ine [string]$snapshot.SHA256){return $null}
    $decisionRecord=Get-WsmWizardTargetDecisionRecord $Workspace $PairId $context.Received.SHA256
    if(-not $decisionRecord -or [string]$decisionRecord.SHA256 -ine [string]$attempt.DecisionReceiptHash -or [string]$decisionRecord.Path -ine [string]$attempt.DecisionReceiptPath -or [string]$decisionRecord.Receipt.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$decisionRecord.Receipt.Generation -ne [long]$packageRecord.Package.Manifest.Generation -or [string]$decisionRecord.Receipt.TargetSnapshotHash -ine [string]$snapshot.SHA256 -or [string]$decisionRecord.Receipt.Decision -cne 'RestoreNow'){return $null}
    if((@($attempt.SelectedItemIds | Sort-Object -Unique) -join "`n") -cne (@($decisionRecord.Receipt.SelectedItemIds | Sort-Object -Unique) -join "`n")){return $null}
    $expectedJournalRoot=[IO.Path]::GetFullPath((Join-Path $paths.Root 'restore-journals')).TrimEnd('\')+'\'
    $stage=[string]$state.Stage
    if($stage -notin @('Succeeded','Partial','RebootRequired','Cancelled','Failed')){return $null}
    if(-not $attempt.PSObject.Properties['ItemResults']){return $null}
    $attemptResults=@($attempt.ItemResults);$attemptResultsHash=Get-WsmHashText ($attemptResults|ConvertTo-Json -Depth 100 -Compress);$appliedCount=@($attemptResults|Where-Object {$_.Status -in @('Succeeded','RebootRequired') -and $_.PSObject.Properties['AppliedManifestHash'] -and $_.PSObject.Properties['AppliedGeneration'] -and [string]$_.AppliedManifestHash -ieq [string]$packageRecord.ManifestHash -and [long]$_.AppliedGeneration -eq [long]$packageRecord.Package.Manifest.Generation}).Count
    $failedCount=@($attemptResults|Where-Object {$_.Status -ceq 'Failed'}).Count;$blockedCount=@($attemptResults|Where-Object {$_.Status -in @('Blocked','BlockedConflict','ManualEvidenceRequired')}).Count
    $matchingJobs=New-Object 'System.Collections.Generic.List[object]'
    foreach($job in @($Jobs)){
        if(-not $job){continue}
        $action=[string](Get-WsmWizardTargetJobField $job action Action);$status=[string](Get-WsmWizardTargetJobField $job status Status);$role=[string](Get-WsmWizardTargetJobField $job role Role);$pair=[string](Get-WsmWizardTargetJobField $job pairId PairId);$jobWorkspace=[string](Get-WsmWizardTargetJobField $job workspace Workspace);$jobId=[string](Get-WsmWizardTargetJobField $job jobId JobId)
        if($action -cne 'TargetRestore' -or $role -cne 'Target' -or $pair -cne $PairId -or $status -notin @('Succeeded','ReviewRequired','Cancelled','Failed','Interrupted') -or -not $jobWorkspace){continue}
        try{if([IO.Path]::GetFullPath($jobWorkspace) -ine [IO.Path]::GetFullPath($Workspace) -or $jobId -cne [string]$attempt.OperationId){continue}}catch{continue}
        foreach($output in @((Get-WsmWizardTargetJobField $job outputs Outputs))){
            if(-not $output){continue}
            $outputAttempt=[string](Get-WsmWizardTargetJobField $output AttemptOperationId AttemptId);if(-not $outputAttempt){$outputAttempt=[string](Get-WsmWizardTargetJobField $output OperationId OperationId)}
            $outputGeneration=[long]0;try{$outputGeneration=[long](Get-WsmWizardTargetJobField $output Generation Generation)}catch{continue}
            if($outputAttempt -cne [string]$attempt.OperationId -or [string](Get-WsmWizardTargetJobField $output PairId PairId) -cne $PairId -or [string](Get-WsmWizardTargetJobField $output ManifestHash ManifestHash) -ine [string]$packageRecord.ManifestHash -or $outputGeneration -ne [long]$packageRecord.Package.Manifest.Generation){continue}
            $outputStage=[string](Get-WsmWizardTargetJobField $output Stage Stage);$outputStatus=[string](Get-WsmWizardTargetJobField $output Status Status)
            if($outputStage -cne $stage -or ($outputStatus -and $outputStatus -cne $stage)){continue}
            if($output.PSObject.Properties['SafeProjectedItemResults'] -and $output.SafeProjectedItemResults -is [bool] -and $output.SafeProjectedItemResults){
                if(-not $output.PSObject.Properties['ItemResultsHash'] -or [string]$output.ItemResultsHash -notmatch '^[a-fA-F0-9]{64}$' -or [string]$output.ItemResultsHash -ine $attemptResultsHash){continue}
            }else{
                if(-not $output.PSObject.Properties['ItemResults'] -or -not $output.PSObject.Properties['ItemResultsHash']){continue}
                $providedItemResultsHash=Get-WsmHashText ($output.ItemResults|ConvertTo-Json -Depth 100 -Compress)
                if([string]$output.ItemResultsHash -notmatch '^[a-fA-F0-9]{64}$' -or [string]$output.ItemResultsHash -ine $providedItemResultsHash -or $providedItemResultsHash -ine $attemptResultsHash){continue}
            }
            if(-not $output.PSObject.Properties['JournalHash'] -or [string]$output.JournalHash -notmatch '^[a-fA-F0-9]{64}$' -or -not $output.PSObject.Properties['JournalPath']){continue}
            try{$journalPath=[IO.Path]::GetFullPath([string]$output.JournalPath);Assert-WsmNoReparse $journalPath;if(-not $journalPath.StartsWith($expectedJournalRoot,[StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($journalPath) -or (Get-FileHash -LiteralPath $journalPath -Algorithm SHA256).Hash -ine [string]$output.JournalHash){continue}}catch{continue}
            $matchingJobs.Add([pscustomobject]@{Job=$job;Output=$output;JournalPath=$journalPath;JournalHash=([string]$output.JournalHash).ToLowerInvariant()})
        }
    }
    if(-not $matchingJobs.Count){return $null}
    $completedUtc=''
    $orderedJobs=@($matchingJobs|Sort-Object @{Expression={try{$field=Get-WsmWizardTargetJobField $_.Job CompletedUtc completedUtc;if($field){[DateTimeOffset]::Parse([string]$field)}else{[DateTimeOffset]::MinValue}}catch{[DateTimeOffset]::MinValue}};Descending=$true},@{Expression={[string](Get-WsmWizardTargetJobField $_.Job jobId JobId)};Descending=$false})
    $chosen=$orderedJobs[0];$completedValue=Get-WsmWizardTargetJobField $chosen.Job CompletedUtc completedUtc
    if($completedValue){try{$completedUtc=[DateTimeOffset]::Parse([string]$completedValue).ToUniversalTime().ToString('o')}catch{}}
    if(-not $completedUtc -and $state.PSObject.Properties['UpdatedUtc']){try{$completedUtc=[DateTimeOffset]::Parse([string]$state.UpdatedUtc).ToUniversalTime().ToString('o')}catch{}}
    if(-not $completedUtc){
        $reader=$null
        try{
            $reader=New-Object IO.StreamReader($chosen.JournalPath,[Text.Encoding]::UTF8,$true)
            $lastLine='';while(-not $reader.EndOfStream){$nextLine=$reader.ReadLine();if(-not [string]::IsNullOrWhiteSpace($nextLine)){$lastLine=$nextLine}}
            if($lastLine){$lastEvent=ConvertFrom-WsmJson $lastLine;if($lastEvent.PairId -ceq $PairId -and [string]$lastEvent.RunId -ceq [string]$state.RunId -and $lastEvent.Action -in @('AssistiveRestoreCompleted','AssistiveRestoreCancelled')){$completedUtc=[DateTimeOffset]::Parse([string]$lastEvent.Utc).ToUniversalTime().ToString('o')}}
        }catch{}finally{if($reader){$reader.Dispose()}}
    }
    [pscustomobject][ordered]@{status=$stage;stage=$stage;workerStatus=[string](Get-WsmWizardTargetJobField $chosen.Job status Status);pairId=$PairId;planHash=[string]$packageRecord.Package.Manifest.PlanHash;manifestHash=[string]$packageRecord.ManifestHash;generation=[long]$packageRecord.Package.Manifest.Generation;attemptId=[string]$attempt.OperationId;runId=[string](Get-WsmWizardTargetJobField $chosen.Job jobId JobId);decisionReceiptHash=[string]$attempt.DecisionReceiptHash;selectedItemIds=@($attempt.SelectedItemIds);completedUtc=$completedUtc;journalPath=[string]$chosen.JournalPath;journalHash=[string]$chosen.JournalHash;appliedCount=$appliedCount;failedCount=$failedCount;blockedCount=$blockedCount;current=$true;hasDurableRecord=$true;authoritativeApproval=$false;productionVerified=$false}
}

function Invoke-WsmWizardTargetValidation {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[ValidateSet('Staged','Final')][string]$Phase='Staged',[object[]]$Jobs=@(),[object[]]$GeneralHostEvidence=@())
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs;$stateDirectory=Join-Path $ctx.Profile.WorkRoot 'pairs';$paths=Get-WsmOperationPaths $stateDirectory $PairId;$state=Get-WsmOperationState $paths $packageRecord.Package
    if($state.ManifestHash -ine $packageRecord.ManifestHash -or [long]$state.Generation -ne [long]$packageRecord.Package.Manifest.Generation){throw 'Validation requires the exact currently delivered generation to be applied and journaled on this Target.'}
    $validation=Invoke-WsmValidation -ManifestPath $packageRecord.ManifestPath -ExpectedHash $packageRecord.ManifestHash -StateDirectory $stateDirectory -Phase $Phase -GeneralHostEvidence $GeneralHostEvidence
    $state=Get-WsmOperationState $paths $packageRecord.Package
    if(-not $state.RestoreAttempt){throw 'Validation result has no durable restore-attempt binding.'}
    $attemptId=[string]$state.RestoreAttempt.OperationId;$decisionRecord=Get-WsmWizardTargetDecisionRecord $Workspace $PairId $ctx.Received.SHA256
    if(-not $decisionRecord -or [string]$state.RestoreAttempt.DecisionReceiptHash -ine [string]$decisionRecord.SHA256 -or [string]$state.RestoreAttempt.DecisionReceiptPath -ine [string]$decisionRecord.Path -or [string]$state.RestoreAttempt.TargetSnapshotHash -ine [string]$decisionRecord.Receipt.TargetSnapshotHash -or [string]$state.RestoreAttempt.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$state.RestoreAttempt.Generation -ne [long]$packageRecord.Package.Manifest.Generation){throw 'Validation result no longer matches the current restore attempt, decision receipt, Target snapshot or package generation.'}
    $journalSnapshot=Save-WsmWizardRestoreJournalSnapshot $paths $packageRecord.Package $attemptId ([string]$state.Stage)
    $validationPath=Join-Path $paths.Root ('validation-'+$Phase+'.json');Assert-WsmNoReparse $validationPath
    [pscustomobject][ordered]@{Status=$(if($validation.Passed){'Succeeded'}else{'ReviewRequired'});PairId=$PairId;PlanHash=[string]$ctx.Received.SHA256;ManifestHash=[string]$packageRecord.ManifestHash;Generation=[long]$packageRecord.Package.Manifest.Generation;RestoreAttemptId=$attemptId;DecisionReceiptHash=[string]$decisionRecord.SHA256;TargetSnapshotHash=[string]$state.RestoreAttempt.TargetSnapshotHash;Phase=$Phase;Passed=[bool]$validation.Passed;Checks=@($validation.Checks);Path=[IO.Path]::GetFullPath($validationPath);SHA256=(Get-FileHash -LiteralPath $validationPath -Algorithm SHA256).Hash.ToLowerInvariant();JournalPath=[string]$journalSnapshot.Path;JournalHash=[string]$journalSnapshot.SHA256;BusinessValidationRequired=$true;ProductionVerified=$false}
}

function Get-WsmWizardTargetAcceptanceGates {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[object[]]$Jobs=@(),[object[]]$GeneralHostEvidence=@())
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs;$snapshot=Get-WsmWizardTargetSnapshot $Workspace $ctx $Jobs;$decisionRecord=Get-WsmWizardTargetDecisionRecord $Workspace $PairId $ctx.Received.SHA256;$stateDirectory=Join-Path $ctx.Profile.WorkRoot 'pairs';$paths=Get-WsmOperationPaths $stateDirectory $PairId;$state=Get-WsmOperationState $paths $packageRecord.Package
    if($state.ManifestHash -ine $packageRecord.ManifestHash -or [long]$state.Generation -ne [long]$packageRecord.Package.Manifest.Generation){throw 'Acceptance gates require the exact currently delivered generation to be applied and journaled.'}
    if(-not $state.RestoreAttempt -or -not $decisionRecord -or [string]$state.RestoreAttempt.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$state.RestoreAttempt.Generation -ne [long]$packageRecord.Package.Manifest.Generation -or [string]$state.RestoreAttempt.DecisionReceiptHash -ine [string]$decisionRecord.SHA256 -or [string]$state.RestoreAttempt.DecisionReceiptPath -ine [string]$decisionRecord.Path -or [string]$state.RestoreAttempt.TargetSnapshotHash -ine [string]$snapshot.SHA256 -or [string]$decisionRecord.Receipt.TargetSnapshotHash -ine [string]$snapshot.SHA256){throw 'Acceptance requires the current exact restore attempt, decision receipt, package generation and Target inventory.'}
    $restoreAttemptId=[string]$state.RestoreAttempt.OperationId
    $gates=Get-WsmAcceptanceGates -ManifestPath $packageRecord.ManifestPath -ExpectedHash $packageRecord.ManifestHash -StateDirectory $stateDirectory -GeneralHostEvidence $GeneralHostEvidence
    $state=Get-WsmOperationState $paths $packageRecord.Package
    if(-not $state.RestoreAttempt -or [string]$state.RestoreAttempt.OperationId -cne $restoreAttemptId -or [string]$state.RestoreAttempt.DecisionReceiptHash -ine [string]$decisionRecord.SHA256 -or [string]$state.RestoreAttempt.DecisionReceiptPath -ine [string]$decisionRecord.Path -or [string]$state.RestoreAttempt.TargetSnapshotHash -ine [string]$snapshot.SHA256){throw 'Restore attempt changed while the explicit acceptance gates were being evaluated.'}
    $attemptId=[string]$state.RestoreAttempt.OperationId
    $finalValidationPath=[IO.Path]::GetFullPath((Join-Path $paths.Root 'validation-Final.json'));Assert-WsmNoReparse $finalValidationPath
    if(-not [IO.File]::Exists($finalValidationPath)){throw 'Final validation did not produce a durable result.'}
    $finalValidationHash=(Get-FileHash -LiteralPath $finalValidationPath -Algorithm SHA256).Hash.ToLowerInvariant();$finalValidation=Read-WsmTrustedJson $finalValidationPath $finalValidationHash
    if([string]$finalValidation.Kind -cne 'ValidationResult' -or [string]$finalValidation.PairId -cne $PairId -or [string]$finalValidation.ManifestHash -ine [string]$packageRecord.ManifestHash -or [long]$finalValidation.Generation -ne [long]$packageRecord.Package.Manifest.Generation -or [string]$finalValidation.Phase -cne 'Final'){throw 'Final validation artifact does not match the current package.'}
    $journalSnapshot=Save-WsmWizardRestoreJournalSnapshot $paths $packageRecord.Package $attemptId ([string]$state.Stage)
    $artifact=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardTargetAcceptanceGates';PairId=$PairId;PlanHash=[string]$ctx.Received.SHA256;ManifestHash=[string]$packageRecord.ManifestHash;Generation=[long]$packageRecord.Package.Manifest.Generation;RestoreAttemptId=$attemptId;DecisionReceiptHash=[string]$decisionRecord.SHA256;TargetSnapshotHash=[string]$snapshot.SHA256;FinalValidationPath=$finalValidationPath;FinalValidationHash=$finalValidationHash;FinalValidationPassed=[bool]$finalValidation.Passed;JournalSnapshotPath=[string]$journalSnapshot.Path;JournalHash=[string]$journalSnapshot.SHA256;Gates=$gates;CreatedUtc=(Get-WsmUtc)}
    $artifactFile=Save-WsmWizardTargetAcceptanceArtifact $paths $artifact
    [pscustomobject][ordered]@{Status=$(if($gates.FinalAccepted){'FinalAccepted'}else{'ReviewRequired'});PairId=$PairId;PlanHash=[string]$ctx.Received.SHA256;ManifestHash=[string]$packageRecord.ManifestHash;Generation=[long]$packageRecord.Package.Manifest.Generation;RestoreAttemptId=$attemptId;DecisionReceiptHash=[string]$decisionRecord.SHA256;TargetSnapshotHash=[string]$snapshot.SHA256;FinalAccepted=[bool]$gates.FinalAccepted;RetirementReady=[bool]$gates.RetirementReady;MissingFinal=@($gates.MissingFinal);MissingRetirement=@($gates.MissingRetirement);Observation=$gates.Observation;RetirementAction=[string]$gates.RetirementAction;Path=[string]$artifactFile.Path;SHA256=[string]$artifactFile.SHA256;FinalValidationPath=$finalValidationPath;FinalValidationHash=$finalValidationHash;JournalSnapshotPath=[string]$journalSnapshot.Path;JournalHash=[string]$journalSnapshot.SHA256;ProductionVerified=$false}
}

function Invoke-WsmWizardTargetActivation {
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$CutoverPlanPath,[Parameter(Mandatory)][string]$CutoverPlanHash,[Parameter(Mandatory)][string]$Acknowledgement,[object[]]$Jobs=@(),[hashtable]$Secrets=@{},[object[]]$GeneralHostEvidence=@(),[object[]]$ExternalEvidenceReferences=@(),[switch]$ResumeActivation,[string]$ResumeOwner,[string]$ResumeEvidence)
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$packageRecord=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs
    if($CutoverPlanHash -notmatch '^[a-f0-9]{64}$'){throw 'A separately verified current CutoverPlan SHA-256 is required.'}
    $cutoverPath=[IO.Path]::GetFullPath($CutoverPlanPath);Assert-WsmNoReparse $cutoverPath;if(-not [IO.File]::Exists($cutoverPath) -or (Get-FileHash -LiteralPath $cutoverPath -Algorithm SHA256).Hash -ine $CutoverPlanHash){throw 'Cutover plan path/hash could not be verified.'}
    $cutoverPlan=Read-WsmTrustedJson $cutoverPath $CutoverPlanHash;Assert-WsmEnvelope $cutoverPlan 'CutoverPlan'
    if($cutoverPlan.PairId -cne $PairId -or $cutoverPlan.ManifestHash -ine $packageRecord.ManifestHash -or [long]$cutoverPlan.Generation -ne [long]$packageRecord.Package.Manifest.Generation -or $cutoverPlan.TargetFingerprint -ine $ctx.Profile.Fingerprint){throw 'Cutover plan is stale or bound to another Target pair, package, generation or host.'}
    if($Acknowledgement -cne ('CUTOVER '+$PairId)){throw 'Activation requires the exact current pair acknowledgement.'}
    $stateDirectory=Join-Path $ctx.Profile.WorkRoot 'pairs';$state=Get-WsmOperationState (Get-WsmOperationPaths $stateDirectory $PairId) $packageRecord.Package
    if($state.ManifestHash -ine $packageRecord.ManifestHash -or [long]$state.Generation -ne [long]$packageRecord.Package.Manifest.Generation){throw 'Activation requires the exact current applied Target generation.'}
    Assert-WsmAssistiveCutoverActivationIntent $packageRecord.Package $stateDirectory $state
    $invokeArgs=@{ManifestPath=$packageRecord.ManifestPath;ExpectedHash=$packageRecord.ManifestHash;StateDirectory=$stateDirectory;CutoverPlanPath=$cutoverPath;CutoverPlanHash=$CutoverPlanHash;Acknowledgement=$Acknowledgement;Secrets=$Secrets;GeneralHostEvidence=$GeneralHostEvidence;ExternalEvidenceReferences=$ExternalEvidenceReferences;WhatIf=[bool]$WhatIfPreference;Confirm=$false}
    if($ResumeActivation){$invokeArgs.ResumeActivation=$true;$invokeArgs.ResumeOwner=$ResumeOwner;$invokeArgs.ResumeEvidence=$ResumeEvidence}
    $result=Invoke-WsmCutover @invokeArgs
    $paths=Get-WsmOperationPaths $stateDirectory $PairId;$updated=Get-WsmOperationState $paths $packageRecord.Package
    $journalHash='';if([IO.File]::Exists($paths.Journal)){$journalHash=(Get-FileHash -LiteralPath $paths.Journal -Algorithm SHA256).Hash.ToLowerInvariant()}
    [pscustomobject][ordered]@{Status=$(if($result.PSObject.Properties['Kind'] -and $result.Kind -ceq 'CutoverExecutionPreview'){'PreviewOnly'}else{[string]$updated.Stage});PairId=$PairId;PlanHash=[string]$ctx.Received.SHA256;ManifestHash=[string]$packageRecord.ManifestHash;Generation=[long]$packageRecord.Package.Manifest.Generation;CutoverPlanHash=$CutoverPlanHash;CutoverStage=$(if($updated.Cutover){[string]$updated.Cutover.Stage}else{''});Result=$result;JournalPath=[string]$paths.Journal;JournalHash=$journalHash;ProductionVerified=$false;BusinessAccepted=$false}
}

