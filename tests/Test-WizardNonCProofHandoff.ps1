#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$installed=Get-Command 'Export-WsmWizardNonCSourceProofHandoff' -ErrorAction Stop;if($installed.ModuleName -cne $module.Name -or [IO.Path]::GetFileName($installed.ScriptBlock.File) -cne 'WizardNonCProofHandoff.ps1'){throw 'Required NonC consumer is not the installed module implementation.'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-nonc-proof-handoff-'+[Guid]::NewGuid().ToString('N').Substring(0,10));[void][IO.Directory]::CreateDirectory($root)
$checks=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action|Out-Null}catch{$rejected=$true};Check $rejected $Message}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()){& $script:module $Block @Arguments}
function SaveJson($Data,[string]$Path){CallModule {param($data,$path)Write-WsmJson $path $data|Out-Null} @($Data,$Path)}
function HashFile([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function NewSoftwareCatalog($Inventory){CallModule {param($inventory)$coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc='2026-10-14T00:00:00Z'});$software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$inventory.Source.HostId;Fingerprint=$inventory.Source.Fingerprint;Name=$inventory.Source.Name;InventoryRevision=[int]$inventory.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=$coverage;PreparationRequirements=@();CatalogProjectionHash=('0'*64)};$software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software;Assert-WsmSoftwareCatalog $software -SourceInventory $inventory|Out-Null;$software} @($Inventory)}
try {
    CallModule {
        $script:proofFingerprint=('a'*64);$script:proofShares=@{}
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:proofFingerprint;Name=$(if($script:proofFingerprint -ceq ('a'*64)){'proof-source'}elseif($script:proofFingerprint -ceq ('b'*64)){'proof-target'}else{'proof-manager'});OS='Windows Server';Version='2025';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-CimInstance {param([string]$ClassName,[string]$ErrorAction);[pscustomobject]@{UUID='11111111-2222-3333-4444-555555555555'}}
        function script:Get-SmbShare {param([string]$Name,[string]$ErrorAction);if(-not $script:proofShares.ContainsKey($Name)){throw 'Fixture only observes explicitly declared existing shares.'};[pscustomobject]@{Name=$Name;Path=[string]$script:proofShares[$Name];EncryptData=$false;ContinuouslyAvailable=$false}}
        function script:Get-SmbServerConfiguration {param([string]$ErrorAction);[pscustomobject]@{RequireSecuritySignature=$true;EnableSecuritySignature=$true}}
        function script:Get-SmbShareAccess {param([string]$Name,[string]$ErrorAction);[pscustomobject]@{AccountName='FixtureOperator';AccessControlType='Allow';AccessRight='Read'}}
        function script:Get-WsmPhysicalPath([string]$Path){$full=[IO.Path]::GetFullPath($Path);if($full -match '^[A-Z]:\\'){'\\?\Volume{11111111-1111-1111-1111-111111111111}\'+$full.Substring(3)}else{$full}}
    }
    $drive='';foreach($letter in @('R','S','T','U','V','W','X','Y','Z','Q','P','O','N','M','L','K','J','I','H','G','F','E','D')){if(-not [IO.Directory]::Exists($letter+':\')){$drive=$letter+':';break}}
    if(-not $drive){throw 'No unused drive letter is available for the bounded source-volume fixture.'}
    & (Join-Path $env:SystemRoot 'System32\subst.exe') $drive $root
    if($LASTEXITCODE -ne 0){throw 'Could not create the test-owned source volume fixture.'}
    $sourceShare=Join-Path ($drive+'\') 'source-share';$sourceAdditionalShare=Join-Path ($drive+'\') 'source-additional-share';$targetShare=Join-Path $root 'target-data-share';$targetStateShare=Join-Path $root 'target-work';$sourcePath=Join-Path $sourceAdditionalShare 'business-data';$targetPath=Join-Path $targetShare 'business-data';$sourceState=Join-Path $sourceShare 'source-state';$targetState=Join-Path $targetStateShare 'pairs'
    foreach($path in @($sourcePath,$sourceState,$sourceShare,$targetShare,$targetPath)){[void][IO.Directory]::CreateDirectory($path)}
    $sourceWorkspace=Join-Path $root 'source-work';$targetWorkspace=Join-Path $root 'target-work';$managerWorkspace=Join-Path $root 'manager-work'
    CallModule {param($w)Initialize-WsmOutputWorkspace -WorkRoot $w -Role Source|Out-Null;Initialize-WsmWizardWorkspace $w Source|Out-Null} @($sourceWorkspace)
    CallModule {param($fp)$script:proofFingerprint=$fp} @('b'*64)
    $targetOutput=CallModule {param($w)$output=Initialize-WsmOutputWorkspace -WorkRoot $w -Role Target;Initialize-WsmWizardWorkspace $w Target|Out-Null;$output} @($targetWorkspace)
    CallModule {param($fp)$script:proofFingerprint=$fp} @('c'*64)
    CallModule {param($w)Initialize-WsmOutputWorkspace -WorkRoot $w -Role Manager|Out-Null;Initialize-WsmWorkspace $w|Out-Null;Initialize-WsmWizardWorkspace $w Manager|Out-Null} @($managerWorkspace)
    CallModule {param($source,$sourceAdditional,$target,$targetState) $script:proofShares=@{FixtureSource=$source;FixtureSourceAdditional=$sourceAdditional;FixtureTarget=$target;FixtureTargetState=$targetState}} @($sourceShare,$sourceAdditionalShare,$targetShare,$targetStateShare)
    CallModule {param($fp)$script:proofFingerprint=$fp} @('a'*64)
    $sourceProfile=CallModule {param($w)Read-WsmOutputProfile $w} @($sourceWorkspace)
    $sourceBundle=CallModule {param($w,$name,$path,$dest,$additional)Export-WsmWizardNonCSourceProofHandoff -Workspace $w -ShareName $name -LocalPath $path -AdditionalShares $additional -Destination $dest -NextOperator 'Manager queue'} @($sourceWorkspace,'FixtureSource',$sourceShare,(Join-Path $root 'source-handoff'),@([pscustomobject]@{ShareName='FixtureSourceAdditional';LocalPath=$sourceAdditionalShare}))
    $sourceExpected=HashFile $sourceBundle.ManifestPath
    Check ($sourceBundle.Status -ceq 'Exported' -and $sourceBundle.ObservedManifestHash -ceq $sourceExpected -and $sourceBundle.Role -ceq 'Source') 'Source share proof handoff did not export exact observed bytes and enrolled identity.'
    $sourceManifest=Get-Content -LiteralPath $sourceBundle.ManifestPath -Raw|ConvertFrom-Json
    Check ($sourceManifest.CreatedUtc -and $sourceManifest.CreatedLocal -and $sourceManifest.TimeZoneId -and $sourceManifest.NextOperator -ceq 'Manager queue' -and $sourceManifest.NextAction -and $sourceManifest.ToolFingerprint) 'Portable Source handoff omitted handover/time-zone/tool metadata.'
    Check ($sourceManifest.Share.Name -ceq 'FixtureSource' -and @($sourceManifest.Shares).Count -eq 2 -and @($sourceManifest.Materials|Where-Object {$_.Kind -ceq 'SourcePeerShareProof'}).Count -eq 2) 'Source handoff did not preserve its primary Share plus one portable proof per explicit share.'
    Reject {CallModule {param($w,$name,$path,$dest,$additional)Export-WsmWizardNonCSourceProofHandoff -Workspace $w -ShareName $name -LocalPath $path -AdditionalShares $additional -Destination $dest -NextOperator 'Manager queue'} @($sourceWorkspace,'FixtureSource',$sourceShare,(Join-Path $root 'nested-source-handoff'),@([pscustomobject]@{ShareName='Nested';LocalPath=(Join-Path $sourceShare 'source-state')}))} 'Source producer accepted ambiguous nested share roots.'
    Reject {CallModule {param($w,$name,$path,$dest,$additional)Export-WsmWizardNonCSourceProofHandoff -Workspace $w -ShareName $name -LocalPath $path -AdditionalShares $additional -Destination $dest -NextOperator 'Manager queue'} @($sourceWorkspace,'FixtureSource',$sourceShare,(Join-Path $root 'unknown-share-field-handoff'),@([pscustomobject]@{ShareName='FixtureSourceAdditional';LocalPath=$sourceAdditionalShare;Password='must-not-be-ignored'}))} 'Source producer silently ignored an unknown AdditionalShares field.'

    CallModule {param($fp)$script:proofFingerprint=$fp} @('b'*64)
    $targetBundle=CallModule {param($w,$shareName,$sharePath,$roots,$state,$destination,$additional)Export-WsmWizardNonCTargetProofHandoff -Workspace $w -ShareName $shareName -LocalPath $sharePath -LocalRoots $roots -StateDirectory $state -AdditionalShares $additional -Destination $destination -NextOperator 'Manager queue'} @($targetWorkspace,'FixtureTarget',$targetShare,@($targetPath),$targetState,(Join-Path $root 'target-handoff'),@([pscustomobject]@{ShareName='FixtureTargetState';LocalPath=$targetStateShare}))
    $targetExpected=HashFile $targetBundle.ManifestPath
    Check ($targetBundle.Status -ceq 'Exported' -and $targetBundle.Role -ceq 'Target' -and $targetBundle.Materials[0].Kind -ceq 'TargetPhysicalProof') 'Target proof handoff did not export the real peer and exact physical proof.'
    $targetManifest=Get-Content -LiteralPath $targetBundle.ManifestPath -Raw|ConvertFrom-Json;$physicalProof=Get-Content -LiteralPath (Join-Path $targetBundle.Directory 'materials\target-physical-proof.json') -Raw|ConvertFrom-Json
    Check ($targetManifest.Share.Name -ceq 'FixtureTarget' -and @($targetManifest.Shares).Count -eq 2 -and @($physicalProof.PeerShareProofs).Count -eq 2 -and @($physicalProof.PhysicalIdentities).Count -eq 1 -and $targetManifest.TargetStateShareName -ceq 'FixtureTargetState' -and @($targetManifest.ReviewedTargetRootMappings|Where-Object {$_.ShareName -ceq 'FixtureTarget'}).Count -eq 1) 'Target proof did not bind data-root physical identity and separately map StateDirectory to its peer share.'
    Reject {CallModule {param($w,$shareName,$sharePath,$roots,$state,$destination,$additional)Export-WsmWizardNonCTargetProofHandoff -Workspace $w -ShareName $shareName -LocalPath $sharePath -LocalRoots $roots -StateDirectory $state -AdditionalShares $additional -Destination $destination -NextOperator 'Manager queue'} @($targetWorkspace,'FixtureTarget',$targetShare,@($targetPath,$targetState),$targetState,(Join-Path $root 'nested-target-handoff'),@([pscustomobject]@{ShareName='Nested';LocalPath=$targetPath}))} 'Target producer accepted nested/ambiguous share roots.'
    Reject {CallModule {param($w,$s,$p,$roots,$state,$dest)Export-WsmWizardNonCTargetProofHandoff -Workspace $w -ShareName $s -LocalPath $p -LocalRoots $roots -StateDirectory $state -Destination $dest -NextOperator 'Manager queue'} @($targetWorkspace,'FixtureTarget',$targetShare,@((Join-Path $root 'outside-root')),$targetState,(Join-Path $root 'invalid-target-handoff'))} 'Target producer accepted a local root outside its explicit existing share.'
    Reject {CallModule {param($w,$s,$p,$roots,$state,$dest)Export-WsmWizardNonCTargetProofHandoff -Workspace $w -ShareName $s -LocalPath $p -LocalRoots $roots -StateDirectory $state -Destination $dest -NextOperator 'Manager queue'} @($targetWorkspace,'FixtureTarget',$targetShare,@($targetShare),(Join-Path $root 'outside-state'),(Join-Path $root 'invalid-state-handoff'))} 'Target producer accepted StateDirectory outside its reviewed roots.'

    # Create one real approved schema-3 Manager plan and current Target snapshot.
    CallModule {param($fp)$script:proofFingerprint=$fp} @('a'*64)
    $sourceIdentity=[pscustomobject]@{HostId=$sourceProfile.HostId;Fingerprint=$sourceProfile.Fingerprint;Name='proof-source';OS='Windows Server 2025'}
    $item=CallModule {param($hostId,$path)New-WsmItem $hostId Storage PathCandidate 'Proof business data' $path ([pscustomobject]@{OriginalPath=$path;ResolvedCandidate=$path}) @() Success Manual} @($sourceIdentity.HostId,$sourcePath)
    $sourceInventory=CallModule {param($host,$items)New-WsmInventory $host 1 $items} @($sourceIdentity,@($item));$sourceInventory|Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $sourceInventory)
    $inventoryPath=Join-Path $root 'source-inventory.json';SaveJson $sourceInventory $inventoryPath;$inventoryHash=HashFile $inventoryPath
    CallModule {param($w,$p,$hash)Import-WsmInventory -Workspace $w -Path $p -ExpectedHash $hash -TargetName 'proof-target'|Out-Null} @($managerWorkspace,$inventoryPath,$inventoryHash)
    $catalog=CallModule {param($w) $fleet=Get-WsmFleet $w;$fleet.Pairs[0]|Out-Null;Get-WsmCatalog $w $fleet.Pairs[0].PairId} @($managerWorkspace);$pairId=$catalog.PairId
    $catalog=CallModule {param($w,$p,$id,$rev)Set-WsmDecision -Workspace $w -PairId $p -ItemId @($id) -Decision Include -ExpectedRevision $rev|Out-Null;Get-WsmCatalog $w $p} @($managerWorkspace,$pairId,$item.ItemId,$catalog.DecisionRevision)
    $catalog=CallModule {param($w,$p,$rev)Enable-WsmAssistiveMode -Workspace $w -PairId $p -ExpectedRevision $rev} @($managerWorkspace,$pairId,$catalog.DecisionRevision)

    CallModule {param($fp)$script:proofFingerprint=$fp} @('b'*64)
    $targetIdentityPath=Join-Path $root 'target-identity.json';$targetRegistration=CallModule {param($state,$path)Register-WsmTarget -StateDirectory $state -Path $path} @($targetOutput.StateDirectory,$targetIdentityPath)
    $targetFacts=[pscustomobject]@{HostId=$targetOutput.HostId;Fingerprint=$targetOutput.Profile.Fingerprint;Name='proof-target';OS='Windows Server 2025'}
    $targetInventory=CallModule {param($host)New-WsmInventory $host 1 @()} @($targetFacts);$targetInventory|Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $targetInventory)
    $targetInventoryPath=Join-Path $root 'target-inventory.json';SaveJson $targetInventory $targetInventoryPath;$targetInventoryHash=HashFile $targetInventoryPath
    $catalog=CallModule {param($w,$p,$path,$hash,$rev)Update-WsmAssistiveTargetSnapshot -Workspace $w -PairId $p -Path $path -ExpectedHash $hash -ExpectedRevision $rev} @($managerWorkspace,$pairId,$targetInventoryPath,$targetInventoryHash,$catalog.Assistive.Revision)
    $spec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourcePath;TargetPath=$targetPath;TransferChannel='NonC';ContentSelection='WholeScope';ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';AclControlPolicy='Exact';ConflictPolicy='Block';Owner='Proof fixture owner';Evidence='Reviewed isolated proof scope';BusinessChecks=@('Verify staged bytes')}
    $specPath=Join-Path $root 'migration-spec.json';SaveJson $spec $specPath
    $catalog=CallModule {param($w,$p,$id,$path,$hash,$rev)Set-WsmMigrationSpec $w $p $id $path $hash $rev|Out-Null;Get-WsmCatalog $w $p} @($managerWorkspace,$pairId,$item.ItemId,$specPath,(HashFile $specPath),$catalog.DecisionRevision)
    $planPath=Join-Path $root 'approved-plan.json';$approval=CallModule {param($w,$p,$identity,$hash,$path,$rev)Approve-WsmMigrationPlan -Workspace $w -PairId $p -TargetIdentityPath $identity -TargetIdentityHash $hash -Path $path -ExpectedRevision $rev -PilotAcknowledgement 'ISOLATED-PILOT'} @($managerWorkspace,$pairId,$targetIdentityPath,$targetRegistration.SHA256,$planPath,$catalog.DecisionRevision)
    $approvalJob=[pscustomobject]@{action='ApproveMigration';status='Succeeded';role='Manager';workspace=$managerWorkspace;pairId=$pairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@([pscustomobject]@{Path=$approval.Path;SHA256=$approval.SHA256})}
    $current=CallModule {param($w,$p)Get-WsmCatalog $w $p} @($managerWorkspace,$pairId)
    $sourcePreview=CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$sourceBundle.Directory,$sourceExpected,@($approvalJob))
    Check ($sourcePreview.Status -ceq 'Ready' -and $sourcePreview.Role -ceq 'Source' -and $sourcePreview.TargetInventoryHash -ceq $targetInventoryHash) 'Manager could not preview a pre-backup Source proof bound to current approval and Target snapshot.'
    Check (@($sourcePreview.Shares).Count -eq 2 -and @($sourcePreview.Materials|Where-Object {$_.Kind -ceq 'SourcePeerShareProof'}).Count -eq 2) 'Manager Source preview did not expose every separately verified Source share proof.'
    $targetPreview=CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$targetBundle.Directory,$targetExpected,@($approvalJob))
    Check ($targetPreview.Status -ceq 'Ready' -and $targetPreview.Role -ceq 'Target' -and $targetPreview.TargetStateDirectory -like '\\*\FixtureTargetState\pairs' -and @($targetPreview.Shares).Count -eq 2) 'Manager Target proof preview did not map the StateDirectory to its separate exact share.'
    $wrongPeerMapping=Join-Path $root 'wrong-peer-target-mapping';[void][IO.Directory]::CreateDirectory($wrongPeerMapping);Get-ChildItem -LiteralPath $targetBundle.Directory|Copy-Item -Destination $wrongPeerMapping -Recurse
    $wrongPeerManifest=CallModule {param($p)Read-WsmJson $p} (Join-Path $wrongPeerMapping 'manifest.json');$wrongPeerManifest.ReviewedTargetRootMappings[0].ShareName='FixtureTargetState';SaveJson $wrongPeerManifest (Join-Path $wrongPeerMapping 'manifest.json');$wrongPeerHash=HashFile (Join-Path $wrongPeerMapping 'manifest.json')
    Reject {CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$wrongPeerMapping,$wrongPeerHash,@($approvalJob))} 'Manager accepted a Target root mapped to the wrong peer share.'
    $omittedShare=Join-Path $root 'omitted-target-share';[void][IO.Directory]::CreateDirectory($omittedShare);Get-ChildItem -LiteralPath $targetBundle.Directory|Copy-Item -Destination $omittedShare -Recurse
    $omittedManifest=CallModule {param($p)Read-WsmJson $p} (Join-Path $omittedShare 'manifest.json');$omittedManifest.Shares=@($omittedManifest.Shares|Where-Object Name -CEQ 'FixtureTarget');SaveJson $omittedManifest (Join-Path $omittedShare 'manifest.json');$omittedHash=HashFile (Join-Path $omittedShare 'manifest.json')
    Reject {CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$omittedShare,$omittedHash,@($approvalJob))} 'Manager accepted a Target physical proof containing peers not declared by the handoff.'

    $tampered=Join-Path $root 'tampered-target';[void][IO.Directory]::CreateDirectory($tampered);Get-ChildItem -LiteralPath $targetBundle.Directory|Copy-Item -Destination $tampered -Recurse
    $targetMaterial=Join-Path $tampered 'materials\target-physical-proof.json';[IO.File]::AppendAllText($targetMaterial,' ')
    $tamperManifest=CallModule {param($p)Read-WsmJson $p} (Join-Path $tampered 'manifest.json');$tamperManifest.Materials[0].SHA256=HashFile $targetMaterial;SaveJson $tamperManifest (Join-Path $tampered 'manifest.json')
    Reject {CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$tampered,$targetExpected,@($approvalJob))} 'Self-rehashed changed Target proof passed against the independent original manifest hash.'
    Reject {CallModule {param($w,$p,$dir,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -Jobs $jobs} @($managerWorkspace,$pairId,$tampered,@($approvalJob))} 'Proof preview accepted a bundle without the separately supplied trusted ExpectedManifestHash.'

    $wrongHost=Join-Path $root 'wrong-host-target';[void][IO.Directory]::CreateDirectory($wrongHost);Get-ChildItem -LiteralPath $targetBundle.Directory|Copy-Item -Destination $wrongHost -Recurse
    $wrongManifest=CallModule {param($p)Read-WsmJson $p} (Join-Path $wrongHost 'manifest.json');$wrongManifest.Profile.HostId=[Guid]::NewGuid().ToString('D');SaveJson $wrongManifest (Join-Path $wrongHost 'manifest.json');$wrongHash=HashFile (Join-Path $wrongHost 'manifest.json')
    Reject {CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$wrongHost,$wrongHash,@($approvalJob))} 'Self-rehashed handoff for an unapproved Target HostId was accepted.'
    $missing=Join-Path $root 'missing-target-proof';[void][IO.Directory]::CreateDirectory($missing);Get-ChildItem -LiteralPath $targetBundle.Directory|Copy-Item -Destination $missing -Recurse
    $missingManifest=CallModule {param($p)Read-WsmJson $p} (Join-Path $missing 'manifest.json');$missingManifest.Materials=@();SaveJson $missingManifest (Join-Path $missing 'manifest.json');$missingHash=HashFile (Join-Path $missing 'manifest.json')
    Reject {CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$missing,$missingHash,@($approvalJob))} 'A proof handoff missing its required physical proof was accepted.'

    $beforeCount=@((CallModule {param($w)Get-WsmAssistiveResourceRegistry $w} @($managerWorkspace)).Materials).Count
    CallModule {
        $script:proofRealRegistryWriter=(Get-Command Write-WsmAssistiveResourceRegistry -CommandType Function).ScriptBlock
        function script:Write-WsmAssistiveResourceRegistry([string]$Workspace,$Registry){throw 'Injected single-transaction registry write failure.'}
    }
    Reject {CallModule {param($w,$p,$dir,$hash,$preview,$jobs)Import-WsmWizardNonCProofHandoff -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -PreviewId $preview -Jobs $jobs} @($managerWorkspace,$pairId,$targetBundle.Directory,$targetExpected,$targetPreview.PreviewId,@($approvalJob))} 'Injected registry write failure did not fail Target proof registration.'
    CallModule {function script:Write-WsmAssistiveResourceRegistry {param([string]$Workspace,$Registry);& $script:proofRealRegistryWriter $Workspace $Registry}}
    $afterFailure=@((CallModule {param($w)Get-WsmAssistiveResourceRegistry $w} @($managerWorkspace)).Materials).Count
    Check ($afterFailure -eq $beforeCount) 'Failed batch registration left partial proof references in the authoritative registry.'
    $sourceImport=CallModule {param($w,$p,$dir,$hash,$preview,$jobs)Import-WsmWizardNonCProofHandoff -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -PreviewId $preview -Jobs $jobs} @($managerWorkspace,$pairId,$sourceBundle.Directory,$sourceExpected,$sourcePreview.PreviewId,@($approvalJob))
    Check ($sourceImport.Status -ceq 'ImportedVerified' -and @($sourceImport.MaterialRefs|Where-Object Kind -CEQ 'SourcePeerShareProof').Count -eq 2 -and @($sourceImport.MaterialRefs|Where-Object {$_.Kind -ceq 'SourcePeerShareProof' -and $_.ShareName -ceq 'FixtureSourceAdditional'}).Count -eq 1 -and -not $sourceImport.ProductionVerified) 'Source handoff did not atomically register every named proof as a non-authoritative material.'
    $targetPreviewAfterSource=CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$targetBundle.Directory,$targetExpected,@($approvalJob))
    $targetImport=CallModule {param($w,$p,$dir,$hash,$preview,$jobs)Import-WsmWizardNonCProofHandoff -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -PreviewId $preview -Jobs $jobs} @($managerWorkspace,$pairId,$targetBundle.Directory,$targetExpected,$targetPreviewAfterSource.PreviewId,@($approvalJob))
    Check ($targetImport.Status -ceq 'ImportedVerified' -and @($targetImport.MaterialRefs|Where-Object Kind -CEQ 'TargetPhysicalProof').Count -eq 1 -and $targetImport.TargetSnapshotHash -ceq $targetInventoryHash) 'Target handoff did not atomically register the physical proof bound to current Target snapshot.'
    $registry=CallModule {param($w)Get-WsmAssistiveResourceRegistry $w} @($managerWorkspace)
    Check (@($registry.Materials|Where-Object {$_.PairId -ceq $pairId -and $_.Kind -in @('AssistivePeerShareProof','AssistiveTargetPhysicalProof')}).Count -eq 3) 'Every Source/Target proof reference was not registered in one owned pair material graph.'

    # A current C-only plan does not expose this SMB proof import gate.
    $current=CallModule {param($w,$p)Get-WsmCatalog $w $p} @($managerWorkspace,$pairId)
    $spec.TransferChannel='C';$spec.SourcePath='C:\proof-c-only';SaveJson $spec $specPath
    $current=CallModule {param($w,$p,$id,$path,$hash,$rev)Set-WsmMigrationSpec $w $p $id $path $hash $rev|Out-Null;Get-WsmCatalog $w $p} @($managerWorkspace,$pairId,$item.ItemId,$specPath,(HashFile $specPath),$current.DecisionRevision)
    $approval2=CallModule {param($w,$p,$identity,$hash,$path,$rev)Approve-WsmMigrationPlan -Workspace $w -PairId $p -TargetIdentityPath $identity -TargetIdentityHash $hash -Path $path -ExpectedRevision $rev -PilotAcknowledgement 'ISOLATED-PILOT'} @($managerWorkspace,$pairId,$targetIdentityPath,$targetRegistration.SHA256,(Join-Path $root 'approved-c-only.json'),$current.DecisionRevision)
    $approvalJob2=[pscustomobject]@{action='ApproveMigration';status='Succeeded';role='Manager';workspace=$managerWorkspace;pairId=$pairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@([pscustomobject]@{Path=$approval2.Path;SHA256=$approval2.SHA256})}
    Reject {CallModule {param($w,$p,$dir,$hash,$jobs)Get-WsmWizardNonCProofHandoffPreview -Workspace $w -PairId $p -Directory $dir -ExpectedManifestHash $hash -Jobs $jobs} @($managerWorkspace,$pairId,$sourceBundle.Directory,$sourceExpected,@($approvalJob2))} 'C-only plan was blocked on NonC share proof instead of reporting not applicable.'
    Write-Output ('PASS Test-WizardNonCProofHandoff checks='+$checks+'; peer/physical proof producer and registration are real, native SMB observation is an isolated fixture, no production qualification claimed.')
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    & (Join-Path $env:SystemRoot 'System32\subst.exe') $drive /D 2>$null|Out-Null
    $absolute=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notlike 'wsm-nonc-proof-handoff-*'){throw 'Unsafe proof handoff test cleanup path.'}
    if([IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
