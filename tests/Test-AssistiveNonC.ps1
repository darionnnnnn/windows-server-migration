#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
. (Join-Path $PSScriptRoot '..\src\MigrationContracts.ps1')
. (Join-Path $PSScriptRoot '..\src\PhysicalPaths.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveFiles.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveNonC.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-nonc-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Message}
function NewFixturePlan([string]$SourcePath,[string]$TargetPath,[string]$SourceRoot,[string]$TargetRoot,[string]$PairId,[string]$ItemId,[string]$PlanPath){
    $physical=Get-WsmAssistiveVolumeIdentity $TargetPath
    $targetProof=New-WsmAssistiveTargetPhysicalProof -TargetHostId $targetHostId -ApprovedTargetRoots @($TargetRoot)
    $freeze=[pscustomobject][ordered]@{Kind='AssistiveFreezeProof';FreezeId=([Guid]::NewGuid().ToString());FreezeEpoch=([Guid]::NewGuid().ToString());FreezeRecordHash=('1'*64);EvidenceId=([Guid]::NewGuid().ToString());EvidenceHash=('2'*64);WriterSetHash=('3'*64);Owner='fixture-owner';PairId=$PairId;PlanHash=('4'*64);SourceInventoryHash=('5'*64);TargetFingerprint=('fixture-target');ProofHash=''}
    $body=[ordered]@{};foreach($p in $freeze.PSObject.Properties){if($p.Name -cne 'ProofHash'){$body[$p.Name]=$p.Value}};$freeze.ProofHash=Get-WsmHashText ($body|ConvertTo-Json -Depth 20 -Compress)
    $map=[ordered]@{};$acl=Get-Acl -LiteralPath $SourcePath;foreach($rule in @($acl.Access)){try{$sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;$map[$sid]=$sid}catch{}};try{$ownerSid=(New-Object Security.Principal.NTAccount([string]$acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value;$map[$ownerSid]=$ownerSid}catch{}
    $relative=[IO.Path]::GetFileName($SourcePath);$sourceHash=Get-WsmAssistiveNonCHash $SourcePath;$entry=[pscustomobject][ordered]@{ItemId=$ItemId;EntryId=(Get-WsmHashText ($ItemId+'|File|'+$relative.ToLowerInvariant()));EntryType='File';RelativePath=$relative;SourcePath=$SourcePath;OriginalSourcePath=$SourcePath;SourcePeerFingerprint='';SourcePeerProofHash='';SourceSHA256=$sourceHash;Bytes=[long](New-Object IO.FileInfo($SourcePath)).Length;TargetPath=$TargetPath;TargetPhysicalIdentity=$physical;ConsumerRefs=@('IIS:site:fixture');AccountMap=[pscustomobject]$map;RequireSacl=$false;InitialStatus='Pending'}
    $proofs=@($targetProof.PhysicalIdentities|Sort-Object -Unique);$plan=[pscustomobject][ordered]@{SchemaVersion=2;ToolVersion='0.4.0';Kind='AssistiveNonCTransferPlan';TransferId=([Guid]::NewGuid().ToString());PairId=$PairId;SealedPlanHash=('6'*64);SelectionRevision=1;SelectionHash=('7'*64);ApprovedItemIds=@($ItemId);ManifestHash=('8'*64);Generation=1;SourceInventoryHash=('5'*64);SourceExpansionHash=(Get-WsmAssistiveNonCExpansionHash @($entry));FreezeEpoch=$freeze.FreezeEpoch;FreezeProof=$freeze;Channel='C';TargetPhysicalId=$targetProof.TargetPhysicalId;TargetPhysicalProof=$targetProof;SourcePeerShareProofs=@();ProviderId='';ApprovedSourceRoots=@($SourceRoot);ApprovedTargetRoots=@($TargetRoot);MetadataPolicy='DaclOwnerMappedAndBasicTimes';MetadataPolicyHash=(Get-WsmHashText 'DaclOwnerMappedAndBasicTimes');Entries=@($entry);CreatedUtc=(Get-WsmUtc)}
    Write-WsmJson $PlanPath $plan
    [pscustomobject]@{Path=$PlanPath;Hash=(Get-WsmAssistiveNonCHash $PlanPath);Plan=$plan;TargetProof=$targetProof;Physical=$physical}
}
try {
    $sourceRoot=Join-Path $root 'source';$targetRoot=Join-Path $root 'target';$conflictRoot=Join-Path $root 'conflict';[void][IO.Directory]::CreateDirectory($sourceRoot);[void][IO.Directory]::CreateDirectory($targetRoot);[void][IO.Directory]::CreateDirectory($conflictRoot)
    $source=Join-Path $sourceRoot 'site-content.txt';[IO.File]::WriteAllText($source,'non-C bytes with meaningful content',[Text.Encoding]::UTF8)
    $pairId=[Guid]::NewGuid().ToString();$targetHostId=[Guid]::NewGuid().ToString();$itemId='e'*64
    $valid=NewFixturePlan $source (Join-Path $targetRoot 'site-content.txt') $sourceRoot $targetRoot $pairId $itemId (Join-Path $root 'transfer-plan.json')
    $checked=Assert-WsmAssistiveNonCPlan $null $valid.Path $valid.Hash
    Check ($checked.PairId -ceq $pairId -and $checked.TargetPhysicalId -ceq $valid.TargetProof.TargetPhysicalId) 'Immutable transfer plan proof binding failed.'
    Reject {Invoke-WsmAssistiveNonCTransfer -TransferPlanPath $valid.Path -ExpectedPlanHash $valid.Hash -SealedPlanPath $valid.Path -SealedPlanHash $valid.Hash -ManifestPath $valid.Path -ManifestHash $valid.Hash -FreezeEvidencePath $valid.Path -FreezeEvidenceHash $valid.Hash -JournalPath (Join-Path $root 'public-journal.json') -ResultPath (Join-Path $root 'public-result.json')} 'Public transfer accepted a self-hashed fixture without independently trusted sealed plan, package and writer-fence evidence.'
    $run=Invoke-WsmAssistiveNonCTransferCore -TransferPlanPath $valid.Path -ExpectedPlanHash $valid.Hash -JournalPath (Join-Path $root 'journal.json') -ResultPath (Join-Path $root 'result.json')
    Check ((Get-WsmAssistiveNonCHash $run.Result.Rows[0].TargetPath) -ceq (Get-WsmAssistiveNonCHash $source)) 'Transfer did not preserve exact file bytes.'
    Check (@('Applied','DeferredManual') -contains $run.Result.Rows[0].Status -and $run.Result.Rows[0].Metadata.OwnerStatus -eq 'Verified') 'Transfer did not attempt and report mapped owner/DACL readback.'
    Check ($run.Result.Rows[0].Bytes -eq (New-Object IO.FileInfo($source)).Length) 'Transfer did not record exact byte count.'
    $resume=Invoke-WsmAssistiveNonCTransferCore -TransferPlanPath $valid.Path -ExpectedPlanHash $valid.Hash -JournalPath (Join-Path $root 'journal.json') -ResultPath (Join-Path $root 'result-resume.json')
    Check (@('Applied','DeferredManual') -contains $resume.Result.Rows[0].Status -and $resume.Result.Rows[0].OwnedByTransfer -and (Get-WsmAssistiveNonCHash $resume.Result.Rows[0].TargetPath) -ceq (Get-WsmAssistiveNonCHash $source)) 'Resume did not preserve and recheck only journal-owned verified bytes.'
    $conflict=Join-Path $conflictRoot 'site-content.txt';[IO.File]::WriteAllText($conflict,'external file')
    $conflictPlan=NewFixturePlan $source $conflict $sourceRoot $conflictRoot $pairId $itemId (Join-Path $root 'conflict-plan.json')
    $conflictRun=Invoke-WsmAssistiveNonCTransferCore -TransferPlanPath $conflictPlan.Path -ExpectedPlanHash $conflictPlan.Hash -JournalPath (Join-Path $root 'conflict-journal.json') -ResultPath (Join-Path $root 'conflict-result.json')
    Check ($conflictRun.Result.Rows[0].Status -eq 'BlockedConflict' -and [IO.File]::ReadAllText($conflict) -eq 'external file') 'External destination was overwritten or merged.'
    $bad=$valid.Plan.FreezeProof.PSObject.Copy();$bad.Owner='forged-owner'
    Reject {Assert-WsmAssistiveFreezeProof $bad $valid.Plan.FreezeEpoch} 'Freeze proof accepted altered owner/evidence without a matching proof hash.'
    $badTarget=$valid.Plan.TargetPhysicalProof.PSObject.Copy();$badTarget.TargetHostId=[Guid]::NewGuid().ToString()
    Reject {Assert-WsmAssistiveTargetPhysicalProof $badTarget $valid.Plan.TargetPhysicalId @($badTarget.PhysicalIdentities)} 'Target proof accepted a changed peer/host identity.'
    $peerFixture=[pscustomobject]@{PeerName='reviewed-source';ShareName='data';LocalPhysicalRoot=(Get-WsmPhysicalPath $sourceRoot);PeerFingerprint=('9'*64)}
    $mapped=ConvertTo-WsmAssistivePeerPath $source $peerFixture
    Check ($mapped -ceq ('\\reviewed-source\data\site-content.txt')) 'Source-side physical path did not map under the exact peer share root.'
    Reject {Get-WsmAssistiveEndpointIdentity '\\unreviewed\share\file.dat' @() ''} 'SMB endpoint received a physical identity without a peer proof.'
    $nonCSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$sourceRoot;TransferChannel='NonC'}
    Reject {Assert-WsmAssistiveSourceScope $nonCSpec SourceCOnly} 'NonC source classifier accepted a C: path as an approved NonC source.'
    $outside=Join-Path $root 'outside.txt';[IO.File]::WriteAllText($outside,'not selected')
    Reject {Assert-WsmAssistivePathUnder $outside @($sourceRoot) 'Source path'} 'Path validation accepted an unreviewed source file.'
    $treeSource=Join-Path $root 'tree-source';$treeTarget=Join-Path $root 'tree-target';[void][IO.Directory]::CreateDirectory($treeSource);[void][IO.Directory]::CreateDirectory((Join-Path $treeSource 'nested'));[void][IO.Directory]::CreateDirectory((Join-Path $treeSource 'empty'));[IO.File]::WriteAllText((Join-Path $treeSource 'nested\tree.txt'),'tree payload',[Text.Encoding]::UTF8)
    $treeMap=[ordered]@{};$treeAcl=Get-Acl -LiteralPath $treeSource;foreach($rule in @($treeAcl.Access)){try{$sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;$treeMap[$sid]=$sid}catch{}};try{$ownerSid=(New-Object Security.Principal.NTAccount([string]$treeAcl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value;$treeMap[$ownerSid]=$ownerSid}catch{}
    $treeSpec=[pscustomobject]@{SourcePath=$treeSource;ContentSelection='All';Metadata='DaclOwnerMappedAndBasicTimes';TransferChannel='C'};$treeRows=@(Get-WsmAssistiveTransferScopeRows -ItemId $itemId -SourceRoot $treeSource -TargetRoot $treeTarget -Spec $treeSpec -Channel C -ConsumerRefs @('IIS:site:tree') -AccountMap ([pscustomobject]$treeMap) -PeerProof $null -TargetPeerProofs @() -ProviderId '' -CollectionPhysicalPath (Get-WsmPhysicalPath $treeSource))
    Check ($treeRows.Count -eq 4 -and @($treeRows|Where-Object EntryType -EQ Directory).Count -eq 3 -and @($treeRows|Where-Object EntryType -EQ File).Count -eq 1) 'Full directory expansion omitted the scope root, nested directory, empty directory, or file.'
    Check (@($treeRows|Select-Object -ExpandProperty EntryId -Unique).Count -eq 4 -and @($treeRows|Where-Object {$_.EntryType -eq 'Directory' -and $_.SourceSHA256}).Count -eq 0) 'Directory expansion did not provide unique per-entry identities or empty directory hashes.'
    $treeTargetProof=New-WsmAssistiveTargetPhysicalProof -TargetHostId $targetHostId -ApprovedTargetRoots @($treeTarget);$treePhysical=Get-WsmAssistiveVolumeIdentity $treeTarget;$treeRows|ForEach-Object {$_.TargetPhysicalIdentity=$treePhysical}
    $treePlan=$valid.Plan.PSObject.Copy();$treePlan.TransferId=[Guid]::NewGuid().ToString();$treePlan.TargetPhysicalProof=$treeTargetProof;$treePlan.TargetPhysicalId=$treeTargetProof.TargetPhysicalId;$treePlan.ApprovedSourceRoots=@($treeSource);$treePlan.ApprovedTargetRoots=@($treeTarget);$treePlan.Entries=$treeRows;$treePlan.SourceExpansionHash=Get-WsmAssistiveNonCExpansionHash $treeRows;$treePlanPath=Join-Path $root 'tree-plan.json';Write-WsmJson $treePlanPath $treePlan;$treePlanHash=Get-WsmAssistiveNonCHash $treePlanPath
    $treeRun=Invoke-WsmAssistiveNonCTransferCore -TransferPlanPath $treePlanPath -ExpectedPlanHash $treePlanHash -JournalPath (Join-Path $root 'tree-journal.json') -ResultPath (Join-Path $root 'tree-result.json')
    Check ($treeRun.Result.Rows.Count -eq 4 -and @($treeRun.Result.Rows|Where-Object {$_.EntryType -eq 'Directory' -and $_.DirectoryCreatedByTransfer}).Count -eq 3) 'Tree transfer did not create and journal all reviewed directories, including empty directories.'
    Check ((Get-WsmAssistiveNonCHash (Join-Path $treeTarget 'nested\tree.txt')) -ceq (Get-WsmAssistiveNonCHash (Join-Path $treeSource 'nested\tree.txt'))) 'Tree transfer did not verify nested file bytes.'
    $treeSpec | Add-Member NoteProperty Adapter FileScope;$fakeSealed=[pscustomobject]@{Items=@([pscustomobject]@{ItemId=$itemId;Decision='Include';MigrationSpec=$treeSpec})};$fakeManifest=[pscustomobject]@{SourceCollectionProofs=@([pscustomobject]@{ItemId=$itemId;PhysicalPath=(Get-WsmPhysicalPath $treeSource)})};$treeReview=[pscustomobject]@{Entries=$treeRows;Channel='C';SourcePeerShareProofs=@();TargetPhysicalProof=$treeTargetProof;ProviderId=''}
    Check ((Get-WsmAssistiveNonCScopeErrors $treeReview $fakeSealed $fakeManifest).Count -eq 0) 'Live full-tree expansion rejected an unchanged reviewed source scope.'
    $treeDropped=$treeRows|Where-Object EntryType -EQ File;$treeReviewDropped=[pscustomobject]@{Entries=@($treeRows|Where-Object EntryId -CNE $treeDropped.EntryId);Channel='C';SourcePeerShareProofs=@();TargetPhysicalProof=$treeTargetProof;ProviderId=''}
    Check ((Get-WsmAssistiveNonCScopeErrors $treeReviewDropped $fakeSealed $fakeManifest).ContainsKey($itemId)) 'Live scope expansion accepted a dropped file entry.'
    [IO.File]::WriteAllText((Join-Path $treeSource 'new-after-review.txt'),'new entry',[Text.Encoding]::UTF8)
    Check ((Get-WsmAssistiveNonCScopeErrors $treeReview $fakeSealed $fakeManifest).ContainsKey($itemId)) 'Live scope expansion accepted a newly added directory-tree file.'
    $exactSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$treeSource;ContentSelection='ExactFiles';TransferChannel='C';ConfigFiles=@([pscustomobject]@{RelativePath='nested\tree.txt';SHA256=(Get-WsmAssistiveNonCHash (Join-Path $treeSource 'nested\tree.txt'))})}
    $exactRows=@(Get-WsmAssistiveTransferScopeRows -ItemId $itemId -SourceRoot $treeSource -TargetRoot $treeTarget -Spec $exactSpec -Channel C -ConsumerRefs @('IIS:site:tree') -AccountMap ([pscustomobject]$treeMap) -PeerProof $null -TargetPeerProofs @() -ProviderId '' -CollectionPhysicalPath (Get-WsmPhysicalPath $treeSource))
    Check (@($exactRows|Where-Object EntryType -EQ File).Count -eq 1 -and @($exactRows|Where-Object {$_.EntryType -eq 'File' -and $_.RelativePath -eq 'nested\tree.txt'}).Count -eq 1) 'ExactFiles expansion included unapproved neighbors or omitted the approved file.'
    $fakeSealed.Items[0].MigrationSpec=$exactSpec;$exactReview=[pscustomobject]@{Entries=$exactRows;Channel='C';SourcePeerShareProofs=@();TargetPhysicalProof=$treeTargetProof;ProviderId=''}
    Check ((Get-WsmAssistiveNonCScopeErrors $exactReview $fakeSealed $fakeManifest).Count -eq 0) 'Live ExactFiles expansion rejected its unchanged approved whitelist.'
    $exactReview.Entries=@();Check ((Get-WsmAssistiveNonCScopeErrors $exactReview $fakeSealed $fakeManifest).ContainsKey($itemId)) 'Live ExactFiles expansion accepted a dropped approved file.'
    $fakeSealed.Items[0].MigrationSpec=$exactSpec;$exactReview.Entries=@($exactRows);$injected=$exactRows[0].PSObject.Copy();$injected.RelativePath='neighbor.txt';$injected.SourcePath=Join-Path $treeSource 'neighbor.txt';$injected.OriginalSourcePath=$injected.SourcePath;$injected.SourceSHA256=('a'*64);$injected.Bytes=1;$injected.EntryId=Get-WsmHashText ($itemId+'|File|neighbor.txt');$exactReview.Entries=@($exactRows)+@($injected)
    Check ((Get-WsmAssistiveNonCScopeErrors $exactReview $fakeSealed $fakeManifest).ContainsKey($itemId)) 'Live ExactFiles expansion accepted an injected non-whitelisted file.'
    Check ($passed -ge 8) 'Expected transfer, metadata, resume, conflict, proof and source-scope checks did not run.'
    Write-Host ('PASS: '+$passed+' Assistive non-C transfer checks.')
} finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
