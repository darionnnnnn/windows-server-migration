# Portable handoff of the Manager-verified NonC transfer plan and Target result.
# Manifest hashes are observed metadata; Target import always requires a separate
# expected hash supplied from an independent trusted reference.

function Get-WsmWizardNonCTargetHandoffHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Assert-WsmWizardNonCTargetHandoffDirectory([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not [IO.Directory]::Exists($full)){throw 'NonC Target handoff directory does not exist.'}
    Assert-WsmNoReparse $full
    $full
}

function Get-WsmWizardNonCTargetHandoffStage([string]$Directory,[string]$ExpectedManifestHash) {
    Assert-WsmAssistiveHash $ExpectedManifestHash 'Independent NonC Target handoff manifest hash'
    $root=Assert-WsmWizardNonCTargetHandoffDirectory $Directory;$manifestPath=Join-Path $root 'manifest.json';Assert-WsmNoReparse $manifestPath
    if(-not [IO.File]::Exists($manifestPath) -or (Get-WsmWizardNonCTargetHandoffHash $manifestPath) -ine $ExpectedManifestHash){throw 'NonC Target handoff manifest differs from the independent expected reference.'}
    $manifest=Read-WsmTrustedJson $manifestPath $ExpectedManifestHash
    if($manifest.SchemaVersion -ne 1 -or $manifest.Kind -cne 'WizardNonCTargetHandoff' -or $manifest.Role -cne 'Manager' -or $manifest.Materials -isnot [array] -or $manifest.Materials.Count -ne 2){throw 'NonC Target handoff manifest schema is unsupported or incomplete.'}
    foreach($field in @('PairId','PlanHash','ManifestHash','Generation','TargetSnapshotHash','TransferId','ToolFingerprint','SourceHostId','SourceFingerprint','TargetHostId','TargetFingerprint','NextOperator','NextAction','CreatedUtc','CreatedLocal','TimeZoneId')){if(-not $manifest.PSObject.Properties[$field]){throw ('NonC Target handoff manifest missing '+$field+'.')}}
    Assert-WsmId ([string]$manifest.PairId);foreach($field in @('PlanHash','ManifestHash','TargetSnapshotHash','SourceFingerprint','TargetFingerprint')){Assert-WsmAssistiveHash ([string]$manifest.$field) ('Handoff '+$field)}
    if($manifest.Generation -lt 1 -or -not $manifest.TransferId -or -not $manifest.ToolFingerprint -or -not $manifest.NextOperator -or -not $manifest.NextAction){throw 'NonC Target handoff manifest binding or operator metadata is invalid.'}
    $byKind=@{};$actualPaths=@{};$staged=@{}
    foreach($row in $manifest.Materials){
        if(-not $row.PSObject.Properties['Kind'] -or -not $row.PSObject.Properties['RelativePath'] -or -not $row.PSObject.Properties['SHA256']){throw 'NonC Target handoff material record is incomplete.'}
        $kind=[string]$row.Kind;$relative=[string]$row.RelativePath
        if($kind -notin @('AssistiveNonCTransferPlan','AssistiveNonCTransferResult') -or $byKind.ContainsKey($kind)){throw 'NonC Target handoff requires one exact transfer plan and one exact transfer result.'}
        if($relative -notin @('materials/transfer-plan.json','materials/transfer-result.json') -or $relative -match '\.\.|\\'){throw 'NonC Target handoff material path is not one of the fixed safe names.'}
        Assert-WsmAssistiveHash ([string]$row.SHA256) 'Handoff material hash';$byKind[$kind]=$row
        $path=[IO.Path]::GetFullPath((Join-Path $root ($relative.Replace('/','\'))))
        if(-not (Test-WsmPathWithinRoot $path $root -ExcludeRoot)){throw 'NonC Target handoff material path escaped its directory.'}
        Assert-WsmNoReparse $path;if(-not [IO.File]::Exists($path) -or (Get-WsmWizardNonCTargetHandoffHash $path) -ine [string]$row.SHA256){throw 'NonC Target handoff material is missing or changed.'}
        $actualPaths[$relative]=$true;$staged[$kind]=[pscustomobject]@{Path=$path;SHA256=([string]$row.SHA256).ToLowerInvariant()}
    }
    if(-not $byKind.ContainsKey('AssistiveNonCTransferPlan') -or -not $byKind.ContainsKey('AssistiveNonCTransferResult')){throw 'NonC Target handoff is missing its plan or result.'}
    $directories=@(Get-ChildItem -LiteralPath $root -Directory -Recurse -Force|ForEach-Object {[string]$_.FullName});foreach($path in $directories){Assert-WsmNoReparse $path}
    $actual=@(Get-ChildItem -LiteralPath $root -File -Recurse -Force|ForEach-Object {$_.FullName.Substring($root.Length+1).Replace('\','/')})|Sort-Object -Unique
    $expected=@('manifest.json')+@($actualPaths.Keys|Sort-Object);$expected=@($expected|Sort-Object -Unique)
    if(($actual -join '|') -cne ($expected -join '|')){throw 'NonC Target handoff has missing or unexpected files.'}
    [pscustomobject]@{Root=$root;Manifest=$manifest;ManifestPath=$manifestPath;ManifestHash=$ExpectedManifestHash.ToLowerInvariant();TransferPlan=$staged['AssistiveNonCTransferPlan'];Result=$staged['AssistiveNonCTransferResult']}
}

function Get-WsmWizardNonCTargetActiveReceipt([string]$Workspace,[string]$PairId) {
    $root=Join-Path (Get-WsmWizardTargetMaterialRoot $Workspace $PairId) 'nonc-handoffs'
    $path=Join-Path $root 'active-receipt.json'
    if(-not [IO.File]::Exists($path)){return $null}
    Assert-WsmNoReparse $root;Assert-WsmNoReparse $path
    $pointerHash=Get-WsmWizardNonCTargetHandoffHash $path;$pointer=Read-WsmTrustedJson $path $pointerHash
    if($pointer.SchemaVersion -ne 1 -or $pointer.Kind -cne 'WizardNonCTargetActiveReceipt' -or $pointer.PairId -cne $PairId -or $pointer.ReceiptHash -notmatch '^[a-fA-F0-9]{64}$' -or $pointer.PreviewId -notmatch '^[a-fA-F0-9]{64}$'){throw 'Current Target NonC active receipt pointer is malformed; preserve it for inspection.'}
    $receiptPath=[IO.Path]::GetFullPath([string]$pointer.ReceiptPath)
    if(-not (Test-WsmPathWithinRoot $receiptPath $root -ExcludeRoot) -or [IO.Path]::GetFileName($receiptPath) -notlike 'receipt-*.json'){throw 'Current Target NonC active receipt pointer escapes its protected receipt directory.'}
    Assert-WsmNoReparse $receiptPath;Assert-WsmTrustedFile $receiptPath ([string]$pointer.ReceiptHash)
    $receipt=Read-WsmTrustedJson $receiptPath ([string]$pointer.ReceiptHash)
    if($receipt.Kind -cne 'WizardNonCTargetHandoffReceipt' -or $receipt.SchemaVersion -ne 1 -or $receipt.PairId -cne $PairId -or $receipt.PreviewId -cne $pointer.PreviewId){throw 'Current Target NonC active receipt does not match its protected pointer.'}
    [pscustomobject]@{Path=$path;Hash=$pointerHash;Pointer=$pointer;ReceiptPath=$receiptPath;ReceiptHash=([string]$pointer.ReceiptHash).ToLowerInvariant();Receipt=$receipt}
}

function Set-WsmWizardNonCTargetActiveReceipt([string]$Workspace,[string]$PairId,[string]$ExpectedPointerHash,[string]$ReceiptPath,[string]$ReceiptHash,[string]$PreviewId,[string]$TargetSnapshotHash) {
    $root=Join-Path (Get-WsmWizardTargetMaterialRoot $Workspace $PairId) 'nonc-handoffs';Assert-WsmNoReparse $root
    $fullReceipt=[IO.Path]::GetFullPath($ReceiptPath)
    if(-not (Test-WsmPathWithinRoot $fullReceipt $root -ExcludeRoot)){throw 'Target NonC receipt is outside the protected handoff directory.'}
    Assert-WsmNoReparse $fullReceipt;Assert-WsmTrustedFile $fullReceipt $ReceiptHash
    $path=Join-Path $root 'active-receipt.json'
    $current=Get-WsmWizardNonCTargetActiveReceipt $Workspace $PairId
    $actualHash=if($current){[string]$current.Hash}else{''}
    if($actualHash -cne $ExpectedPointerHash){throw 'Current Target NonC receipt changed after preview; preview the selected handoff again.'}
    $pointer=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardNonCTargetActiveReceipt';PairId=$PairId;PreviewId=$PreviewId;ReceiptPath=$fullReceipt;ReceiptHash=$ReceiptHash.ToLowerInvariant();TargetSnapshotHash=$TargetSnapshotHash.ToLowerInvariant();UpdatedUtc=(Get-WsmUtc)}
    # Use the shared atomic writer, including its explicit backup path. In
    # Windows PowerShell 5.1 a null Replace backup argument becomes an invalid
    # empty path, so a second receipt selection otherwise fails after staging.
    Write-WsmJson $path $pointer
    Assert-WsmNoReparse $path
}

function Export-WsmWizardNonCTargetHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ManifestHash,[Parameter(Mandatory)][string]$TransferPlanHash,[Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$NextOperator,[object[]]$Jobs=@())
    if($TransferPlanHash -notmatch '^[a-fA-F0-9]{64}$'){throw 'Choose one exact verified NonC transfer plan by its trusted SHA-256.'}
    if([string]::IsNullOrWhiteSpace($NextOperator) -or $NextOperator.Length -gt 200 -or $NextOperator -match '[\x00-\x1f]'){throw 'NextOperator must be a concise explicit handoff label.'}
    Assert-WsmId $PairId;$profile=Read-WsmOutputProfile $Workspace;if(-not $profile -or $profile.Role -cne 'Manager'){throw 'NonC Target handoff export requires the enrolled Manager workspace.'}
    $catalog=Get-WsmCatalog $Workspace $PairId;$approved=Get-WsmWizardCurrentApprovedPlan $Workspace $PairId $profile $catalog $Jobs
    if(-not $approved -or $approved.Plan.SchemaVersion -ne 3 -or $approved.SHA256 -ine [string]$catalog.Approval.Hash){throw 'A current schema-3 approved plan is required for NonC Target handoff.'}
    Assert-WsmAssistiveHash $ManifestHash 'Selected current final package hash'
    $preparation=Get-WsmWizardNonCPreparation -Workspace $Workspace -PairId $PairId -ManifestSelection $ManifestHash -Jobs $Jobs
    if(-not $preparation.Current.ManifestHash -or -not $preparation.Current.Generation -or $preparation.Current.PlanHash -ine $approved.SHA256){throw 'A unique current verified final package generation is required before Target handoff.'}
    $choices=@($preparation.TransferChoices|Where-Object {$_.sha256 -ieq $TransferPlanHash -and [string]$_.generation -ceq [string]$preparation.Current.Generation})
    if($choices.Count -ne 1){throw 'The selected NonC transfer plan is not the unique current Manager-verified choice.'}
    $transferPath=[IO.Path]::GetFullPath([string]$choices[0].path);$transferRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $Workspace 'workspace-control') 'wizard-materials') ('nonc-'+$PairId)))
    if(-not (Test-WsmPathWithinRoot $transferPath $transferRoot -ExcludeRoot)){throw 'Verified transfer plan is outside the Manager-owned NonC material directory.'}
    Assert-WsmNoReparse $transferPath;Assert-WsmTrustedFile $transferPath $TransferPlanHash;$transfer=Assert-WsmAssistiveNonCPlan $null $transferPath $TransferPlanHash
    if($transfer.PairId -cne $PairId -or $transfer.Channel -cne 'NonC' -or $transfer.SealedPlanHash -ine $approved.SHA256 -or $transfer.ManifestHash -ine $preparation.Current.ManifestHash -or [long]$transfer.Generation -ne [long]$preparation.Current.Generation -or [int]$transfer.SelectionRevision -ne [int]$preparation.Current.SelectionRevision){throw 'Current transfer plan differs from the exact approved plan, package generation, selection or NonC channel.'}
    $resultSummary=Get-WsmWizardNonCResultSummary $Workspace $PairId $approved $preparation $catalog
    $results=@($resultSummary.NonCResults|Where-Object {$_.TransferPlanHash -ieq $TransferPlanHash -and $_.TransferId -ceq $transfer.TransferId -and [string]$resultSummary.Generation -ceq [string]$preparation.Current.Generation})
    if(-not $resultSummary.hasDurableRecord -or -not $resultSummary.current -or $results.Count -ne 1 -or @($resultSummary.NonCResults).Count -ne 1){throw 'A unique current Manager-verified result for this exact transfer plan is required.'}
    $result=$results[0];$resultPath=[IO.Path]::GetFullPath([string]$result.ResultPath);$resultRoot=[IO.Path]::GetFullPath((Join-Path $Workspace 'assistive\results'))
    if(-not (Test-WsmPathWithinRoot $resultPath $resultRoot -ExcludeRoot)){throw 'Verified transfer result is outside the Manager-owned result directory.'}
    Assert-WsmNoReparse $resultPath;Assert-WsmTrustedFile $resultPath ([string]$result.ResultHash)
    $target=$catalog.Assistive.TargetCurrent;if(-not $target -or $target.HostId -cne $approved.Plan.Target.HostId -or $target.Fingerprint -ine $approved.Plan.Target.Fingerprint){throw 'Current Target observation is not bound to the approved Target host.'}
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Destination)));if(-not [IO.Directory]::Exists($parent)){throw 'Choose an existing destination directory for the portable Target handoff.'};Assert-WsmNoReparse $parent
    $leaf=[IO.Path]::GetFileName($Destination);if(-not $leaf -or $leaf -match '[\\/:*?"<>|]' -or $leaf -in @('.','..')){throw 'Target handoff destination must be a new simple folder name.'}
    $root=Join-Path $parent $leaf;if([IO.File]::Exists($root) -or [IO.Directory]::Exists($root)){throw 'Target handoff destination already exists; choose a new folder.'}
    [void][IO.Directory]::CreateDirectory($root);Assert-WsmNoReparse $root;$materials=Join-Path $root 'materials';[void][IO.Directory]::CreateDirectory($materials);Assert-WsmNoReparse $materials
    $planBytes=[IO.File]::ReadAllBytes($transferPath);$resultBytes=[IO.File]::ReadAllBytes($resultPath)
    $planCopy=Join-Path $materials 'transfer-plan.json';$resultCopy=Join-Path $materials 'transfer-result.json'
    [IO.File]::WriteAllBytes($planCopy,$planBytes);[IO.File]::WriteAllBytes($resultCopy,$resultBytes)
    if((Get-WsmWizardNonCTargetHandoffHash $planCopy) -ine $TransferPlanHash -or (Get-WsmWizardNonCTargetHandoffHash $resultCopy) -ine [string]$result.ResultHash){throw 'NonC material bytes changed while exporting the portable handoff.'}
    $local=[DateTimeOffset]::Now
    $manifest=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardNonCTargetHandoff';Role='Manager';PairId=$PairId;PlanHash=[string]$approved.SHA256;ManifestHash=[string]$preparation.Current.ManifestHash;Generation=[long]$preparation.Current.Generation;TargetSnapshotHash=[string]$target.SHA256;TransferId=[string]$transfer.TransferId;ToolFingerprint=[string]$approved.Plan.ToolFingerprint;SourceHostId=[string]$approved.Plan.Source.HostId;SourceFingerprint=[string]$approved.Plan.Source.Fingerprint;TargetHostId=[string]$approved.Plan.Target.HostId;TargetFingerprint=[string]$approved.Plan.Target.Fingerprint;Materials=@([pscustomobject]@{Kind='AssistiveNonCTransferPlan';RelativePath='materials/transfer-plan.json';SHA256=[string]$TransferPlanHash.ToLowerInvariant()},[pscustomobject]@{Kind='AssistiveNonCTransferResult';RelativePath='materials/transfer-result.json';SHA256=[string]$result.ResultHash.ToLowerInvariant()});NextOperator=$NextOperator.Trim();NextAction='Target operator: independently verify this manifest hash, preview the exact transfer result, then import the verified materials before reading the Target restore projection.';CreatedUtc=(Get-WsmUtc);CreatedLocal=$local.ToString('o');TimeZoneId=[TimeZoneInfo]::Local.Id;AuthoritativeApproval=$false;ProductionVerified=$false}
    $manifestPath=Join-Path $root 'manifest.json';Write-WsmJson $manifestPath $manifest;Assert-WsmNoReparse $manifestPath;$manifestHash=Get-WsmWizardNonCTargetHandoffHash $manifestPath
    [pscustomobject][ordered]@{Kind='WizardNonCTargetHandoffExport';Status='Exported';PairId=$PairId;Directory=$root;ManifestPath=$manifestPath;ObservedManifestHash=$manifestHash;TransferPlanHash=[string]$TransferPlanHash.ToLowerInvariant();ResultHash=[string]$result.ResultHash.ToLowerInvariant();TransferId=[string]$transfer.TransferId;PlanHash=[string]$approved.SHA256;ManifestHash=[string]$preparation.Current.ManifestHash;Generation=[long]$preparation.Current.Generation;TargetSnapshotHash=[string]$target.SHA256;NextOperator=$NextOperator.Trim();NextAction=[string]$manifest.NextAction;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Get-WsmWizardNonCTargetHandoffPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$ExpectedManifestHash,[object[]]$Jobs=@())
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$package=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs;$snapshot=Get-WsmWizardTargetSnapshot $Workspace $ctx $Jobs
    $stage=Get-WsmWizardNonCTargetHandoffStage $Directory $ExpectedManifestHash;$manifest=$stage.Manifest
    if($manifest.PairId -cne $PairId -or $manifest.PlanHash -ine $ctx.Received.SHA256 -or $manifest.ManifestHash -ine $package.ManifestHash -or [long]$manifest.Generation -ne [long]$package.Package.Manifest.Generation -or $manifest.TargetSnapshotHash -ine $snapshot.SHA256){throw 'NonC handoff does not match the current Target pair, approved plan, delivered final generation, or Target inventory.'}
    if($manifest.SourceHostId -cne $ctx.Plan.Source.HostId -or $manifest.SourceFingerprint -ine $ctx.Plan.Source.Fingerprint -or $manifest.TargetHostId -cne $ctx.Profile.HostId -or $manifest.TargetFingerprint -ine $ctx.Profile.Fingerprint -or $manifest.ToolFingerprint -cne $ctx.Plan.ToolFingerprint){throw 'NonC handoff Source, Target, or tool identity differs from the current received approved plan.'}
    $transfer=Assert-WsmAssistiveNonCPlan $null $stage.TransferPlan.Path $stage.TransferPlan.SHA256
    if($transfer.PairId -cne $PairId -or $transfer.Channel -cne 'NonC' -or $transfer.TransferId -cne $manifest.TransferId -or $transfer.SealedPlanHash -ine $ctx.Received.SHA256 -or $transfer.ManifestHash -ine $package.ManifestHash -or [long]$transfer.Generation -ne [long]$package.Package.Manifest.Generation -or $transfer.SourceInventoryHash -ine $ctx.Plan.Assistive.SourceSnapshotHash -or [int]$transfer.SelectionRevision -ne [int]$ctx.Plan.Assistive.SourceSelectionsVersion -or $transfer.TargetPhysicalProof.TargetHostId -cne $ctx.Profile.HostId -or $transfer.TargetPhysicalProof.ObserverMachineFingerprint -ine $ctx.Profile.Fingerprint){throw 'NonC transfer plan does not match this Target exact approved plan, final generation, selection, or physical identity.'}
    $targetStateDirectory=Join-Path $ctx.Profile.WorkRoot 'pairs'
    $validatedRows=Get-WsmAssistiveNonCResultRows $package.Package $stage.TransferPlan.Path $stage.TransferPlan.SHA256 $stage.Result.Path $stage.Result.SHA256 $targetStateDirectory
    if(@($validatedRows.Keys).Count -ne @($transfer.Entries|ForEach-Object ItemId|Sort-Object -Unique).Count){throw 'Core NonC Target readback validation did not produce one verified result group per planned item.'}
    $active=Get-WsmWizardNonCTargetActiveReceipt $Workspace $PairId;$activeHash=if($active){[string]$active.Hash}else{''}
    $contentBinding=[ordered]@{PairId=$PairId;PlanHash=[string]$ctx.Received.SHA256;ManifestHash=[string]$package.ManifestHash;Generation=[long]$package.Package.Manifest.Generation;TargetSnapshotHash=[string]$snapshot.SHA256;TransferId=[string]$transfer.TransferId;TransferPlanHash=[string]$stage.TransferPlan.SHA256;ResultHash=[string]$stage.Result.SHA256;Directory=[string]$stage.Root;ExpectedManifestHash=[string]$stage.ManifestHash}
    $contentBindingHash=Get-WsmHashText ($contentBinding|ConvertTo-Json -Depth 20 -Compress)
    $binding=[ordered]@{ContentBindingHash=$contentBindingHash;ActiveReceiptHash=$activeHash}
    [pscustomobject][ordered]@{Kind='WizardNonCTargetHandoffPreview';Status='Ready';PreviewId=(Get-WsmHashText ($binding|ConvertTo-Json -Depth 20 -Compress));ContentBindingHash=$contentBindingHash;ActiveReceiptHash=$activeHash;PairId=$PairId;Role='Target';PlanHash=[string]$ctx.Received.SHA256;ManifestHash=[string]$package.ManifestHash;Generation=[long]$package.Package.Manifest.Generation;TargetSnapshotHash=[string]$snapshot.SHA256;TransferId=[string]$transfer.TransferId;TransferPlanHash=[string]$stage.TransferPlan.SHA256;ResultHash=[string]$stage.Result.SHA256;TransferPlanItemCount=@($transfer.ApprovedItemIds).Count;ValidatedItemCount=@($validatedRows.Keys).Count;NextOperator=[string]$manifest.NextOperator;NextAction=[string]$manifest.NextAction;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Import-WsmWizardNonCTargetHandoff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$ExpectedManifestHash,[Parameter(Mandatory)][string]$PreviewId,[object[]]$Jobs=@())
    $preview=Get-WsmWizardNonCTargetHandoffPreview -Workspace $Workspace -PairId $PairId -Directory $Directory -ExpectedManifestHash $ExpectedManifestHash -Jobs $Jobs
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$root=Get-WsmWizardTargetMaterialRoot $Workspace $PairId;[void](New-WsmOutputOwnedDirectory $root)
    $stage=Get-WsmWizardNonCTargetHandoffStage $Directory $ExpectedManifestHash
    $handoffRoot=Join-Path $root 'nonc-handoffs';[void](New-WsmOutputOwnedDirectory $handoffRoot)
    $contentRoot=Join-Path $handoffRoot $preview.ContentBindingHash;[void](New-WsmOutputOwnedDirectory $contentRoot)
    $planPath=Join-Path $contentRoot 'transfer-plan.json';$resultPath=Join-Path $contentRoot 'transfer-result.json'
    foreach($copy in @(@($stage.TransferPlan.Path,$stage.TransferPlan.SHA256,$planPath),@($stage.Result.Path,$stage.Result.SHA256,$resultPath))){Assert-WsmNoReparse ([string]$copy[0]);Assert-WsmTrustedFile ([string]$copy[0]) ([string]$copy[1]);if([IO.File]::Exists([string]$copy[2])){Assert-WsmTrustedFile ([string]$copy[2]) ([string]$copy[1])}else{[IO.File]::Copy([IO.Path]::GetFullPath([string]$copy[0]),[string]$copy[2]);if((Get-WsmWizardNonCTargetHandoffHash ([string]$copy[2])) -ine [string]$copy[1]){throw 'NonC Target handoff bytes changed during protected material staging.'}};Assert-WsmNoReparse ([string]$copy[2])}
    $rechecked=Get-WsmWizardNonCTargetHandoffPreview -Workspace $Workspace -PairId $PairId -Directory $Directory -ExpectedManifestHash $ExpectedManifestHash -Jobs $Jobs
    if($rechecked.ContentBindingHash -cne $preview.ContentBindingHash -or $rechecked.ActiveReceiptHash -cne $preview.ActiveReceiptHash){throw 'Target plan, package, inventory or active NonC receipt changed while handoff materials were staged.'}
    $existing=Get-WsmWizardNonCTargetActiveReceipt $Workspace $PairId
    if($existing -and $existing.Receipt.PreviewId -ceq $PreviewId -and $existing.Receipt.ContentBindingHash -ceq [string]$preview.ContentBindingHash -and $existing.Receipt.ImportedManifestHash -ieq $ExpectedManifestHash){
        if($preview.PlanHash -ine [string]$existing.Receipt.PlanHash -or $preview.ManifestHash -ine [string]$existing.Receipt.ManifestHash -or $preview.Generation -ne [long]$existing.Receipt.Generation -or $preview.TargetSnapshotHash -ine [string]$existing.Receipt.TargetSnapshotHash -or $preview.TransferPlanHash -ine [string]$existing.Receipt.TransferPlanHash -or $preview.ResultHash -ine [string]$existing.Receipt.ResultHash){throw 'Current active Target NonC receipt differs from the exact replayed handoff; preserve it for inspection.'}
        [pscustomobject][ordered]@{Kind='WizardNonCTargetHandoffImport';Status='ImportedVerified';PairId=$PairId;ReceiptPath=[string]$existing.ReceiptPath;ReceiptHash=[string]$existing.ReceiptHash;TransferId=[string]$existing.Receipt.TransferId;PlanHash=[string]$existing.Receipt.PlanHash;ManifestHash=[string]$existing.Receipt.ManifestHash;Generation=[long]$existing.Receipt.Generation;TargetSnapshotHash=[string]$existing.Receipt.TargetSnapshotHash;TransferPlanHash=[string]$existing.Receipt.TransferPlanHash;ResultHash=[string]$existing.Receipt.ResultHash;AuthoritativeApproval=$false;ProductionVerified=$false}
        return
    }
    if($preview.PreviewId -cne $PreviewId){throw 'NonC Target handoff preview binding changed; preview the exact current materials again.'}
    $record=[pscustomobject][ordered]@{SchemaVersion=1;Kind='WizardNonCTargetHandoffReceipt';PreviewId=[string]$preview.PreviewId;ContentBindingHash=[string]$preview.ContentBindingHash;PairId=$PairId;PlanHash=[string]$preview.PlanHash;ManifestHash=[string]$preview.ManifestHash;Generation=[long]$preview.Generation;TargetSnapshotHash=[string]$preview.TargetSnapshotHash;TransferId=[string]$preview.TransferId;TransferPlanPath=[IO.Path]::GetFullPath($planPath);TransferPlanHash=[string]$preview.TransferPlanHash;ResultPath=[IO.Path]::GetFullPath($resultPath);ResultHash=[string]$preview.ResultHash;ImportedManifestHash=[string]$ExpectedManifestHash.ToLowerInvariant();ImportedUtc=(Get-WsmUtc);AuthoritativeApproval=$false;ProductionVerified=$false}
    $recordJson=$record|ConvertTo-Json -Depth 20 -Compress;$recordHash=Get-WsmHashText $recordJson;$recordPath=Join-Path $handoffRoot ('receipt-'+$recordHash+'.json')
    if([IO.File]::Exists($recordPath)){Assert-WsmNoReparse $recordPath;$old=Read-WsmTrustedJson $recordPath (Get-WsmWizardNonCTargetHandoffHash $recordPath);if((Get-WsmHashText ($old|ConvertTo-Json -Depth 20 -Compress)) -ine $recordHash){throw 'Existing Target NonC handoff receipt conflicts; preserve it for inspection.'}}else{Write-WsmJson $recordPath $record;Assert-WsmNoReparse $recordPath}
    $written=Read-WsmTrustedJson $recordPath (Get-WsmWizardNonCTargetHandoffHash $recordPath);$receiptHash=Get-WsmWizardNonCTargetHandoffHash $recordPath
    Invoke-WsmLocked $Workspace {
        $latest=Get-WsmWizardNonCTargetHandoffPreview -Workspace $Workspace -PairId $PairId -Directory $Directory -ExpectedManifestHash $ExpectedManifestHash -Jobs $Jobs
        if($latest.PreviewId -cne $PreviewId -or $latest.ContentBindingHash -cne [string]$preview.ContentBindingHash -or $latest.ActiveReceiptHash -cne [string]$preview.ActiveReceiptHash){throw 'Target handoff preview or active receipt changed before import could be selected.'}
        Set-WsmWizardNonCTargetActiveReceipt $Workspace $PairId ([string]$preview.ActiveReceiptHash) $recordPath $receiptHash $PreviewId ([string]$preview.TargetSnapshotHash)
    }
    [pscustomobject][ordered]@{Kind='WizardNonCTargetHandoffImport';Status='ImportedVerified';PairId=$PairId;ReceiptPath=[IO.Path]::GetFullPath($recordPath);ReceiptHash=$receiptHash;TransferId=[string]$written.TransferId;PlanHash=[string]$written.PlanHash;ManifestHash=[string]$written.ManifestHash;Generation=[long]$written.Generation;TargetSnapshotHash=[string]$written.TargetSnapshotHash;TransferPlanHash=[string]$written.TransferPlanHash;ResultHash=[string]$written.ResultHash;AuthoritativeApproval=$false;ProductionVerified=$false}
}

function Get-WsmWizardNonCTargetRestoreInputs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[object[]]$Jobs=@())
    $ctx=Assert-WsmWizardTargetRole $Workspace $PairId;$package=Get-WsmWizardTargetPackage $Workspace $PairId $ctx $Jobs;$snapshot=Get-WsmWizardTargetSnapshot $Workspace $ctx $Jobs
    $active=Get-WsmWizardNonCTargetActiveReceipt $Workspace $PairId;if(-not $active){return $null}
    $record=$active.Receipt
    if($record.PlanHash -ine $ctx.Received.SHA256 -or $record.ManifestHash -ine $package.ManifestHash -or [long]$record.Generation -ne [long]$package.Package.Manifest.Generation -or $record.TargetSnapshotHash -ine $snapshot.SHA256){return $null}
    Assert-WsmTrustedFile ([string]$record.TransferPlanPath) ([string]$record.TransferPlanHash);Assert-WsmTrustedFile ([string]$record.ResultPath) ([string]$record.ResultHash)
    $plan=Assert-WsmAssistiveNonCPlan $null $record.TransferPlanPath $record.TransferPlanHash
    if($plan.TransferId -cne $record.TransferId -or $plan.Channel -cne 'NonC' -or $plan.SealedPlanHash -ine $ctx.Received.SHA256 -or $plan.ManifestHash -ine $package.ManifestHash -or [long]$plan.Generation -ne [long]$package.Package.Manifest.Generation){throw 'Stored Target NonC materials no longer validate against the current received plan and package.'}
    $targetStateDirectory=Join-Path $ctx.Profile.WorkRoot 'pairs'
    $rows=Get-WsmAssistiveNonCResultRows $package.Package $record.TransferPlanPath $record.TransferPlanHash $record.ResultPath $record.ResultHash $targetStateDirectory
    [pscustomobject][ordered]@{Status='Verified';PairId=$PairId;TransferId=[string]$record.TransferId;PlanHash=[string]$record.PlanHash;ManifestHash=[string]$record.ManifestHash;Generation=[long]$record.Generation;TargetSnapshotHash=[string]$record.TargetSnapshotHash;NonCTransferPlanPath=[string]$record.TransferPlanPath;NonCTransferPlanHash=[string]$record.TransferPlanHash;NonCResultPath=[string]$record.ResultPath;NonCResultHash=[string]$record.ResultHash;ValidatedItemCount=@($rows.Keys).Count;AuthoritativeApproval=$false;ProductionVerified=$false}
}
