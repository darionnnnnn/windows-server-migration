#requires -Version 5.1
# G2 (N9f): old machine discovery -> backup -> independent delivery (front half of the G journeys).
# Flow, one immutable snapshot of the tracked tree, product imported unchanged from it:
#   Source SourceCandidateScan (real core scan over a fixture "C volume") -> candidate confirmation export
#   -> Manager import / mapping review / CV2 approval -> Source plan import -> one-click backup (real freeze,
#   capture, seal, verify, delivery, item results, offline report) -> independent copy.
# Judged: discovered candidates and ExcludedRegions reach the result set (17.77), approved set == confirmed set,
# archive bytes == independent copy bytes (and == source bytes), and "not enabled" is stated and observed.
# Output: work\r7\g-journey\<RunId>\verdict.json (same shape as the main journey).
param(
    [string]$RunId='g2a001',
    [switch]$KeepArtifacts,
    [ValidateSet('','ApprovalExtraItem','ReproD1NoBridge','RetryAfterSealFailure')][string]$Mutation=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'G-ScenarioCommon.ps1')
Initialize-GScenario 'g2' 'G2 discovery to delivery' $RunId $Mutation

try{
    Write-GStage 1 'snapshot, product imported from the immutable copy'
    if([IO.Directory]::Exists($script:GTestRoot)){throw 'Refusing to reuse an existing test root.'}
    [void][IO.Directory]::CreateDirectory($script:GTestRoot)
    $module=New-GSnapshot @('tests/G-ScenarioCommon.ps1','tests/Test-G2DiscoveryToDelivery.ps1')
    $fixturePath=Join-Path $script:GSnapshot 'tests\ExternalReadinessEvidenceFixtures.ps1'
    Add-GDouble 'Get-WsmMachineIdentity / Get-WsmPreflight' 'host qualification observation only (this runner is not a server / not elevated); fingerprints a..., b..., c... stand for Source, Target, Manager'
    Add-GDouble 'Export-WsmInventory' 'returns the fixture inventory file instead of a full live capture (the product re-reads it through its normal hash checks)'
    Add-GDouble 'Get-WsmSourceCandidateRoot' 'the scan walks a fixture directory that stands for the C volume; the scan, confirmation and everything after are the real code'
    Add-GDouble 'Get-WsmIndependentCopyMediaClass' 'returns Removable: this runner has no removable disk'
    if($Mutation -ceq 'RetryAfterSealFailure'){Add-GDouble 'Test-WsmMigrationPackage (first seal verification only)' 'N9h-D2 retry mode: the first verification of the pending manifest fails once (a D1-independent failure after controls/ was written); every other call is the real function'}
    Add-GDouble 'freeze evidence' 'New-WsmSourceFreezeEvidenceFixture (typed writer-stopped evidence, fixture only); the freeze record consumer is the real one'

    $script:GVerdict.Notes+=@('N9h-D1 (fixed): Source scan/confirmation material lives under <ws>/assistive/materials; the one-click backup now reads the plan MaterialReferences from that same Source workspace root. No copy into <ws>/pairs is made. -Mutation ReproD1NoBridge is kept as an alias of the default run: without any bridge the backup passes.')
    $script:GVerdict.Notes+=@('N9h-D2 (fixed): a retry of a CV2 attempt reuses identical controls/ files and refuses different ones. -Mutation RetryAfterSealFailure fails the first attempt after controls/ was written (injected seal-verification failure, not D1) and retries.')
    Write-GStage 2 'Source scan -> confirmation export -> Manager import / approval -> Source backup -> independent copy'
    # The workspaces live on a short subst drive: the CV2 control material names are long and the nested attempt/package folders
    # would pass MAX_PATH under the long test root (N4 uses the same device). The scanned fixture stays on the real C: path.
    $wsDrive=New-GSubst (Join-Path $script:GTestRoot 'ws')
    Add-GDouble 'subst workspace drive' ('drive '+$wsDrive+': maps the workspace folder so the nested package paths stay below MAX_PATH')
    $observations=& $module {
        param($Root,$FixturePath,$RunDir,$MutationName,$Report,$WsRoot)
        . $FixturePath
        function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
        function New-PeBytes { [byte[]]$bytes=New-Object byte[] 256;$bytes[0]=0x4d;$bytes[1]=0x5a;[BitConverter]::GetBytes([int]128).CopyTo($bytes,60);$bytes[128]=0x50;$bytes[129]=0x45;$bytes }
        function Rel([string]$Base,[string]$Path){$Path.Substring($Base.TrimEnd('\').Length+1)}
        $obs=[ordered]@{}
        $script:g2Fp=('a'*64)
        function script:Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$script:g2Fp;Name=('G2-'+$script:g2Fp.Substring(0,1));OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function script:Get-WsmPreflight {[pscustomobject]@{OS='Fixture Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion='5.1';ExecutionPolicy='AllSigned';LanguageMode='FullLanguage'}}
        $script:g2InventoryPath=''
        function script:Export-WsmInventory {param([string]$OutputDirectory,[switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog,[int]$MaxSoftwareEntries,[string[]]$PortableRoot,[string]$ManualEvidencePath,[string]$ManualEvidenceSha256);if(-not $script:g2InventoryPath){throw 'Fixture inventory observation was not initialized.'};[pscustomobject]@{Path=$script:g2InventoryPath;SHA256=(Get-FileHash -LiteralPath $script:g2InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
        function script:Get-WsmIndependentCopyMediaClass {param($DestinationRoot) 'Removable'}

        $sourceRoot=Join-Path $WsRoot 's';$managerRoot=Join-Path $WsRoot 'm';$targetRoot=Join-Path $WsRoot 't';$media=Join-Path $Root 'media'
        $fx=Join-Path $Root 'C-fx'
        # ---- fixture "C volume": three business candidates, one never confirmed, one installed-software root, one guard directory
        $business=Join-Path $fx 'Business Data';$nested=Join-Path $business 'nested';$site=Join-Path $fx 'Site';$neighbor=Join-Path $fx 'Neighbor';$extra=Join-Path $fx 'Extra'
        $installRoot=Join-Path $fx 'Vendor App';$guardDir=Join-Path $fx 'Windows.old';$loose=Join-Path $fx 'loose-root.txt'
        foreach($dir in @($nested,$site,$neighbor,$extra,(Join-Path $installRoot 'lib'),(Join-Path $installRoot 'Reports'),$guardDir)){[void][IO.Directory]::CreateDirectory($dir)}
        $utf8=New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $business 'customers.dat'),'G2 customer data',$utf8)
        [IO.File]::WriteAllText((Join-Path $nested 'index.db'),'G2 index data',$utf8)
        [IO.File]::WriteAllBytes((Join-Path $site 'core.dll'),(New-PeBytes))
        [IO.File]::WriteAllText((Join-Path $site 'default.htm'),'<html>G2 site</html>',$utf8)
        [IO.File]::WriteAllText($loose,'G2 loose root file',$utf8)
        [IO.File]::WriteAllText((Join-Path $neighbor 'neighbor.txt'),'G2 discovered but never confirmed',$utf8)
        [IO.File]::WriteAllText((Join-Path $extra 'extra.txt'),'G2 inventory item that must stay out of the plan',$utf8)
        [IO.File]::WriteAllBytes((Join-Path $installRoot 'app.exe'),(New-PeBytes))
        [IO.File]::WriteAllBytes((Join-Path $installRoot 'lib\core.dll'),(New-PeBytes))
        [IO.File]::WriteAllText((Join-Path $installRoot 'Reports\sales.csv'),'a,b',$utf8)
        [IO.File]::WriteAllText((Join-Path $guardDir 'x.bin'),'x',$utf8)

        # ---- enrolment: Source (a), Target (b), Manager (c)
        $sourceEnrollment=Initialize-WsmOutputWorkspace $sourceRoot Source
        $script:g2Fp=('b'*64);$targetEnrollment=Initialize-WsmOutputWorkspace $targetRoot Target
        $targetIdentityPath=Join-Path (Join-Path $targetRoot ('targets\'+$targetEnrollment.HostId)) 'target-identity.json';$targetIdentityHash=Sha $targetIdentityPath
        $script:g2Fp=('c'*64);[void](Initialize-WsmOutputWorkspace $managerRoot Manager);Initialize-WsmWorkspace $managerRoot|Out-Null
        $script:g2Fp=('a'*64)
        $profile=Read-WsmOutputProfile $sourceRoot
        $source=[pscustomobject][ordered]@{HostId=[string]$profile.HostId;Fingerprint=([string]$profile.Fingerprint).ToLowerInvariant();Name='G2-Source';OS='Windows Server';Version='2025'}

        # ---- source inventory: the C volume (real device id), one inventory FileScope item, and the installed software whose root is the bundle
        $volume=@(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop|Where-Object {([string]$_.DriveLetter).TrimEnd('\') -ieq 'C:'});if($volume.Count -ne 1){throw 'Fixture requires the local C: volume identity.'}
        $volumeItem=New-WsmItem $source.HostId Storage Volume 'C: fixture volume' 'volume:C:' @{DriveLetter='C:';DeviceID=[string]$volume[0].DeviceID} @() Success 'Manual'
        $extraItem=New-WsmItem $source.HostId Storage FileScope 'G2 extra scope' 'g2-extra-scope' ([pscustomobject]@{SourcePath=$extra;TargetPath=$extra}) @() Success FileScope
        $inventory=New-WsmInventory $source 1 @($volumeItem,$extraItem)
        $now=[DateTime]::UtcNow.ToString('o');$softwareId='sw-'+('d'*32)
        $softwareEntry=[pscustomobject][ordered]@{SoftwareId=$softwareId;Name='G2 Vendor App';Version='1';Publisher='G2 Test';Architecture='x64';Scope='Machine';SID='';RegistryView='Registry64';Location=$installRoot;SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='HKLM:\Software\G2';NaturalKey='G2 Vendor App'};ObservedUtc=$now;CaptureStatus='Success';ItemIds=@();AccountContext='Machine'}
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$source.HostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=$now;CaptureIdentity='g2 fixture';AccountContext='Machine';CaptureHost='g2';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($softwareEntry);Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind='';ObservedUtc=$now});PreparationRequirements=@([pscustomobject][ordered]@{PreparationId=('prep-'+$softwareId.Substring(3));SoftwareId=$softwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='G2 fixture evidence only.'});CatalogProjectionHash=('0'*64)}
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
        $inventory|Add-Member NoteProperty SoftwareCatalog $catalog -Force
        $inventoryPath=Join-Path (Join-Path (Join-Path (Join-Path $sourceRoot 'hosts') $profile.Fingerprint) 'inventory') 'inventory-1.json'
        Write-WsmJson $inventoryPath $inventory;$script:g2InventoryPath=$inventoryPath
        $inventoryHash=Sha $inventoryPath
        $snapshotPath=Join-Path $sourceRoot ('assistive/snapshots/'+$inventoryHash+'.json');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($snapshotPath));[IO.File]::Copy($inventoryPath,$snapshotPath,$false)
        $jobId=[Guid]::NewGuid().ToString('D');$job=[pscustomobject]@{jobId=$jobId;action='SourceInventory';role='Source';workspace=$sourceRoot;status='Succeeded';outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash})}
        $null=Set-WsmWizardInventoryBinding -Workspace $sourceRoot -Role Source -JobId $jobId -ExpectedWizardRevision 0 -Jobs @($job)

        # ---- 1. Source: candidate scan (the SourceCandidateScan core), candidate list and excluded areas
        $script:g2FixtureRoot=$fx
        Set-Item Function:\script:Get-WsmSourceCandidateRoot -Value {param([string]$Workspace,$Profile)$script:g2FixtureRoot}
        $scan=Invoke-WsmSourceCandidateScan -Workspace $sourceRoot -Jobs @($job)
        $artifact=Get-Content -LiteralPath $scan.CandidatePath -Raw -Encoding UTF8|ConvertFrom-Json
        $obs.ScanStatus=[string]$scan.ScanStatus;$obs.ScanId=[string]$scan.ScanId;$obs.CandidateHash=[string]$scan.CandidateHash
        $find={param([string]$Path,[string]$Type)@($artifact.Candidates|Where-Object {$_.CandidateType -ceq $Type -and $_.Path -ieq $Path})}
        $candBusiness=@(& $find $business 'DirectoryRoot');$candSite=@(& $find $site 'DirectoryRoot');$candLoose=@(& $find $loose 'ExactFile');$candNeighbor=@(& $find $neighbor 'DirectoryRoot');$candExtra=@(& $find $extra 'DirectoryRoot')
        & $Report 'scan_succeeded_with_hashed_artifact_and_report' (($scan.ScanStatus -ceq 'Succeeded') -and ($scan.CandidateHash -match '^[a-f0-9]{64}$') -and ((Sha $scan.CandidatePath) -ceq [string]$scan.CandidateHash) -and [IO.File]::Exists([string]$scan.ReportPath)) ([string]$scan.ScanStatus)
        & $Report 'scan_discovered_every_fixture_candidate_once' ($candBusiness.Count -eq 1 -and $candSite.Count -eq 1 -and $candLoose.Count -eq 1 -and $candNeighbor.Count -eq 1 -and $candExtra.Count -eq 1) 'business, site, loose root file, neighbor, extra'
        $insideBundle=@($artifact.Candidates|Where-Object {([string]$_.Path) -ieq $installRoot -or ([string]$_.Path).StartsWith($installRoot+'\',[StringComparison]::OrdinalIgnoreCase)}).Count
        $bundleArea=@($artifact.ExcludedAreas|Where-Object Path -IEQ $installRoot);$guardArea=@($artifact.ExcludedAreas|Where-Object Path -IEQ $guardDir)
        & $Report 'scan_excluded_regions_hold_bundle_root_and_guard_area_and_no_candidate_inside_bundle' ($bundleArea.Count -eq 1 -and $bundleArea[0].Category -ceq 'BundleExcluded' -and $bundleArea[0].Contents.Counts.Bundle -ge 2 -and $guardArea.Count -eq 1 -and $guardArea[0].Category -ceq 'ProtectedArea' -and $insideBundle -eq 0) ('bundle='+$bundleArea.Count+' guard='+$guardArea.Count+' candidatesInsideBundle='+$insideBundle)
        $scanExcludedPaths=@($artifact.ExcludedAreas|ForEach-Object {[string]$_.Path}|Sort-Object)

        # ---- 2. Source: confirmation export for the three candidates the owner confirms (Neighbor and Extra are not confirmed)
        $confirmed=@()
        foreach($candidate in @($candBusiness[0],$candSite[0],$candLoose[0])){
            $export=Export-WsmSourceCandidateConfirmation -Workspace $sourceRoot -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId $candidate.CandidateId -Jobs @($job)
            $body=Get-Content -LiteralPath $export.ConfirmationPath -Raw -Encoding UTF8|ConvertFrom-Json
            $confirmed+=@([pscustomobject]@{Candidate=$candidate;Export=$export;Body=$body;Path=[string]$candidate.Path})
        }
        & $Report 'three_confirmations_exported_with_hashes_and_no_approval' (@($confirmed|Where-Object {$_.Export.Status -ceq 'Confirmed' -and $_.Export.ConfirmationHash -match '^[a-f0-9]{64}$' -and -not $_.Body.AuthoritativeApproval}).Count -eq 3) 'Status=Confirmed, AuthoritativeApproval=false'
        # independent expectation computed from the disk, not from the product
        $expected=@{}
        foreach($entry in $confirmed){
            $scopeRoot=[string]$entry.Body.Selection.ScopeRoot
            $files=@(if($entry.Candidate.CandidateType -ceq 'ExactFile'){Get-Item -LiteralPath $entry.Path}else{Get-ChildItem -LiteralPath $entry.Path -Recurse -File -Force})
            $memberMap=@{};foreach($member in @($entry.Body.Selection.Members)){if(-not $member.PSObject.Properties['EntryType']){$memberMap[([string]$member.RelativePath).ToLowerInvariant()]=[string]$member.SHA256}}
            $diskMap=@{};foreach($file in $files){$diskMap[(Rel $scopeRoot $file.FullName).ToLowerInvariant()]=Sha $file.FullName}
            $same=($memberMap.Count -eq $diskMap.Count);foreach($key in $diskMap.Keys){if(-not $memberMap.ContainsKey($key) -or $memberMap[$key] -cne $diskMap[$key]){$same=$false}}
            $expected[[string]$entry.Path]=[pscustomobject]@{ScopeRoot=$scopeRoot;Disk=$diskMap;MembersMatchDisk=$same}
        }
        & $Report 'confirmed_members_equal_independent_disk_hashes' (@($expected.Values|Where-Object {-not $_.MembersMatchDisk}).Count -eq 0) ('scopes='+$expected.Count+' files='+(($expected.Values|ForEach-Object {$_.Disk.Count}|Measure-Object -Sum).Sum))

        # ---- 3. Manager: import inventory, import the confirmations, review, approve (CV2)
        $mCatalog=Import-WsmInventory -Workspace $managerRoot -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'G2-Target'
        $pairId=[string]$mCatalog.PairId
        $mCatalog=Enable-WsmAssistiveMode -Workspace $managerRoot -PairId $pairId -ExpectedRevision $mCatalog.DecisionRevision
        $mCatalog=Set-WsmAssistiveSelections -Workspace $managerRoot -PairId $pairId -ExpectedRevision $mCatalog.Assistive.Revision -ItemIds @([string]$volumeItem.ItemId) -Selected $false -Reason 'G2 volume binding only; no volume migration item is selected.'
        $imports=@()
        foreach($entry in $confirmed){
            $mCatalog=Get-WsmCatalog $managerRoot $pairId
            $imported=@(Import-WsmSourceCandidateConfirmation -Workspace $managerRoot -PairId $pairId -Path $entry.Export.ConfirmationPath -ExpectedHash $entry.Export.ConfirmationHash -TargetPath ([string]$entry.Body.Selection.ScopeRoot) -Owner 'G2 owner' -Evidence 'change:g2-fixture' -ExpectedRevision $mCatalog.DecisionRevision)
            $obs.ImportOutputCount=$imported.Count;$imported=$imported[-1]
            $imports+=@([pscustomobject]@{Entry=$entry;Imported=$imported})
        }
        & $Report 'manager_import_pending_review_required_not_approved' (@($imports|Where-Object {$_.Imported.Status -ceq 'ImportedReviewRequired' -and $_.Imported.Decision -ceq 'Pending' -and -not $_.Imported.AuthoritativeApproval}).Count -eq 3) 'ImportedReviewRequired / Pending'
        $reviewOk=$true
        foreach($pair in $imports){
            $review=Get-WsmSourceCandidateConfirmationReview -Workspace $managerRoot -PairId $pairId -ItemId $pair.Imported.ItemId
            if(-not ($review.Status -ceq 'ReviewRequired' -and $review.CandidateArtifactHash -ceq [string]$scan.CandidateHash -and $review.InventoryHash -ceq $inventoryHash -and $review.MemberCount -eq @($pair.Entry.Body.Selection.Members).Count)){$reviewOk=$false}
        }
        & $Report 'manager_typed_review_reopens_scan_inventory_and_member_evidence' $reviewOk 'review binds the scan artifact hash and the Source inventory hash'
        $confirmedItemIds=@($imports|ForEach-Object {[string]$_.Imported.ItemId}|Sort-Object)
        $mCatalog=Get-WsmCatalog $managerRoot $pairId
        $mCatalog=Set-WsmDecision -Workspace $managerRoot -PairId $pairId -ItemId @($confirmedItemIds) -Decision Include -ExpectedRevision $mCatalog.DecisionRevision
        $mCatalog=Get-WsmCatalog $managerRoot $pairId
        $mCatalog=Set-WsmDecision -Workspace $managerRoot -PairId $pairId -ItemId @([string]$extraItem.ItemId) -Decision Exclude -Reason 'G2 extra scope is deliberately not part of the confirmed set.' -ExpectedRevision $mCatalog.DecisionRevision
        if($MutationName -ceq 'ApprovalExtraItem'){
            # MUTATION: the approval step also carries one item that no Source confirmation covers.
            $extraSpec=[pscustomobject]@{Adapter='FileScope';SourcePath=$extra;TargetPath=$extra;ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='G2 owner';Evidence='G2 mutation extra item';TransferChannel='C';ContentSelection='WholeScope'}
            $extraSpecPath=Join-Path $Root 'spec-extra.json';Write-WsmJson $extraSpecPath $extraSpec
            $mCatalog=Get-WsmCatalog $managerRoot $pairId
            Set-WsmMigrationSpec $managerRoot $pairId $extraItem.ItemId $extraSpecPath (Sha $extraSpecPath) $mCatalog.DecisionRevision|Out-Null
            $mCatalog=Get-WsmCatalog $managerRoot $pairId
            $mCatalog=Set-WsmDecision -Workspace $managerRoot -PairId $pairId -ItemId @([string]$extraItem.ItemId) -Decision Include -Reason 'mutation' -ExpectedRevision $mCatalog.DecisionRevision
        }
        $mCatalog=Get-WsmCatalog $managerRoot $pairId
        $planPath=Join-Path $RunDir 'g2-approved-plan.json'
        $sealed=Approve-WsmMigrationPlan -Workspace $managerRoot -PairId $pairId -TargetIdentityPath $targetIdentityPath -TargetIdentityHash $targetIdentityHash -Path $planPath -ExpectedRevision $mCatalog.DecisionRevision -PilotAcknowledgement 'ISOLATED-PILOT' -OfflineFullSet
        $plan=Read-WsmMigrationPlan $sealed.Path $sealed.SHA256
        $planIncluded=@($plan.Items|Where-Object Decision -CEQ 'Include'|ForEach-Object {[string]$_.ItemId}|Sort-Object)
        $approvedIds=@($plan.Assistive.ApprovedItemIds|ForEach-Object {[string]$_}|Sort-Object)
        & $Report 'plan_is_cv2_approved_local_volumes' ([int]$plan.Assistive.ContractVersion -eq 2 -and [string]$plan.Assistive.SourcePolicy -ceq 'ApprovedLocalVolumes') ('ContractVersion='+$plan.Assistive.ContractVersion)
        & $Report 'approved_item_set_equals_confirmed_item_set' (($planIncluded -join ',') -ceq ($confirmedItemIds -join ',') -and ($approvedIds -join ',') -ceq ($confirmedItemIds -join ',')) ('plan='+$planIncluded.Count+' approvedIds='+$approvedIds.Count+' confirmed='+$confirmedItemIds.Count)
        $specsEqual=$true
        foreach($pair in $imports){
            $planItem=@($plan.Items|Where-Object {[string]$_.ItemId -ceq [string]$pair.Imported.ItemId})
            if($planItem.Count -ne 1){$specsEqual=$false;continue}
            $spec=$planItem[0].MigrationSpec
            $planMembers=@($spec.Members|ForEach-Object {([string]$_.RelativePath).ToLowerInvariant()+'|'+([string]$_.SHA256).ToLowerInvariant()}|Sort-Object)
            $confMembers=@($pair.Entry.Body.Selection.Members|ForEach-Object {([string]$_.RelativePath).ToLowerInvariant()+'|'+([string]$_.SHA256).ToLowerInvariant()}|Sort-Object)
            if(($planMembers -join ';') -cne ($confMembers -join ';') -or [string]$spec.ContentSelection -cne 'ExactMembers' -or [string]$spec.SourcePath -ine [string]$pair.Entry.Body.Selection.ScopeRoot){$specsEqual=$false}
        }
        & $Report 'approved_specs_carry_exactly_the_confirmed_members_and_hashes' $specsEqual 'ExactMembers, relative path + SHA256 equal per scope'
        $refs=@($plan.Assistive.MaterialReferences|ForEach-Object {[string]$_.Reference+'|'+([string]$_.SHA256).ToLowerInvariant()}|Sort-Object)
        $confRefs=@($confirmed|ForEach-Object {[string]$_.Export.MaterialReference+'|'+([string]$_.Export.ConfirmationHash).ToLowerInvariant()}|Sort-Object)
        & $Report 'plan_binds_the_three_confirmation_materials' (($refs -join ';') -ceq ($confRefs -join ';')) ('references='+$refs.Count)
        $planPaths=@($plan.Items|ForEach-Object {[string]$_.MigrationSpec.SourcePath})
        & $Report 'unconfirmed_candidates_are_absent_from_the_plan' (@($planPaths|Where-Object {$_ -ieq $neighbor -or $_ -ieq $extra}).Count -eq 0) 'neighbor and extra are not plan items'

        # ---- 4. Source: import the approved plan, one-click backup (freeze, capture, seal, verify, deliver, results), independent copy
        $script:g2Fp=('a'*64)
        $sourceDigestBefore=(@(Get-ChildItem -LiteralPath $fx -Recurse -File -Force|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Sha $_.FullName)}) -join "`n")
        $import=Import-WsmWizardApprovedPlan $sourceRoot Source $sealed.Path $sealed.SHA256
        & $Report 'source_imported_the_approved_plan_verified' ([string]$import.Status -ceq 'ImportedVerified') ([string]$import.Status)
        $freezeOwner='G2 freeze owner';$freezeText='Synthetic owner-confirmed quiescence; fixture only.'
        $freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $plan -PlanHash $sealed.SHA256 -Root $Root -Owner $freezeOwner
        $backupOperation=[Guid]::NewGuid().ToString('D')
        $token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $pairId -PlanHash $sealed.SHA256 -OperationId $backupOperation
        $startBackup={param([string]$Op,$Tok)Invoke-WsmWizardStartBackup -Workspace $sourceRoot -PairId $pairId -OperationId $Op -Owner $freezeOwner -Evidence $freezeText -FreezeAuthorization -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -Jobs @() -CancellationToken $Tok -DeliveryMode Directory -VolumeBytes 0}
        # N9h-D1: the controls writer is probed directly first with the real call shape of the one-click backup (state directory <ws>\pairs, workspace root as the
        # material workspace). No attempt is created and no material is copied or moved: the Source scan wrote it where the exporter now reads it.
        $probeDirectory=Join-Path $Root 'probe-controls';[void][IO.Directory]::CreateDirectory($probeDirectory)
        $probeMessage='';$probeCount=-1;try{$probe=Write-WsmOfflineFullSetControls $plan (Join-Path $sourceRoot 'pairs') $probeDirectory $sourceRoot;$probeCount=[int]$probe.Count}catch{$probeMessage=[string]$_.Exception.Message}
        $obs.D1Probe=[ordered]@{Id='N9h-D1';ControlsWriterAcceptedSourceMaterialInPlace=(-not $probeMessage);ControlCount=$probeCount;Message=$probeMessage;MaterialCopiedIntoPairs=$false}
        & $Report 'n9h_d1_controls_writer_reads_the_source_material_where_the_scan_wrote_it' ((-not $probeMessage) -and $probeCount -eq (@($plan.Assistive.MaterialReferences).Count+1) -and -not [IO.Directory]::Exists((Join-Path (Join-Path $sourceRoot 'pairs') 'assistive\materials'))) ('controls='+$probeCount+' pairs\assistive\materials absent')
        if($MutationName -ceq 'RetryAfterSealFailure'){
            # N9h-D2 retry mode: the first attempt fails after controls/ was written, for a reason that has nothing to do with D1; the retry must succeed on the same package directory.
            $script:g2SealFailuresLeft=1;$script:g2OrigTestPackage=(Get-Command Test-WsmMigrationPackage -CommandType Function).ScriptBlock
            function script:Test-WsmMigrationPackage {if($script:g2SealFailuresLeft -gt 0 -and [string]$args[0] -like '*manifest.pending.json'){$script:g2SealFailuresLeft--;throw 'G2 injected seal verification failure (not D1)'};& $script:g2OrigTestPackage @args}
            $firstError='';$firstStatus='';try{$firstResult=& $startBackup $backupOperation $token;$firstStatus=[string]$firstResult.Status}catch{$firstError=[string]$_.Exception.Message}
            $controlsDirs=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Directory -Force -Filter 'controls' -ErrorAction SilentlyContinue)
            $obs.RetryAfterSealFailure=[ordered]@{FirstAttemptError=$firstError;FirstAttemptStatus=$firstStatus;ControlsDirectoriesAfterFailure=$controlsDirs.Count}
            & $Report 'n9h_d2_first_attempt_failed_for_the_injected_reason_after_controls_were_written' (($firstError -like '*injected seal verification failure*' -or $firstStatus -cin @('Failed','Cancelled')) -and $controlsDirs.Count -ge 1) ('error='+$firstError+' status='+$firstStatus+' controls dirs='+$controlsDirs.Count)
            $backupOperation=[Guid]::NewGuid().ToString('D');$token=New-WsmCancellationToken -StateDirectory (Join-Path $sourceRoot 'pairs') -PairId $pairId -PlanHash $sealed.SHA256 -OperationId $backupOperation
        }
        $backup=& $startBackup $backupOperation $token
        $obs.BackupStatus=[string]$backup.Status
        & $Report 'one_click_backup_delivered_and_sealed_package_valid' (([string]$backup.Status -ceq 'Delivered') -and $backup.CoreExport.Sealed -and $backup.PackageTest.Valid -and [string]$backup.Delivery.Mode -ceq 'Directory') ([string]$backup.Status)
        & $Report 'item_results_and_offline_report_generated' (([string]$backup.ItemResults.Status -ceq 'Generated') -and ([string]$backup.OfflineReport.Status -ceq 'Generated')) ([string]$backup.ItemResults.Status+'/'+[string]$backup.OfflineReport.Status)
        $sourceDigestAfter=(@(Get-ChildItem -LiteralPath $fx -Recurse -File -Force|Sort-Object FullName|ForEach-Object {$_.FullName+'|'+(Sha $_.FullName)}) -join "`n")
        & $Report 'source_tree_unchanged_by_discovery_confirmation_and_backup' ($sourceDigestBefore -ceq $sourceDigestAfter) 'fixture C tree hash before == after'

        # archive bytes == source bytes (independent hashes from the disk)
        $package=Test-WsmMigrationPackage ([string]$backup.CoreExport.ManifestPath) ([string]$backup.CoreExport.SHA256)
        $rows=@(Read-WsmArtifactLines (Join-Path $package.Root 'artifacts.jsonl') $package.Manifest.ArtifactsHash|Where-Object {-not $_.Directory})
        $archiveHashes=@($rows|ForEach-Object {[string]$_.Data.Hash}|Sort-Object)
        $expectedHashes=@($expected.Values|ForEach-Object {$_.Disk.Values}|ForEach-Object {[string]$_}|Sort-Object)
        & $Report 'sealed_archive_blob_hashes_equal_source_file_hashes' (($archiveHashes -join ',') -ceq ($expectedHashes -join ',') -and $archiveHashes.Count -eq $expectedHashes.Count -and $archiveHashes.Count -ge 5) ('archive files='+$archiveHashes.Count+' expected='+$expectedHashes.Count)
        $blobsOk=$true;foreach($hash in $archiveHashes){if(-not [IO.File]::Exists((Join-Path (Join-Path $package.Root 'payload') ($hash+'.blob'))) -or (Sha (Join-Path (Join-Path $package.Root 'payload') ($hash+'.blob'))) -cne $hash){$blobsOk=$false}}
        & $Report 'every_archive_blob_file_rehashes_to_its_name' $blobsOk 'payload\<hash>.blob re-hashed'

        # ---- 5. result set: the discovered ExcludedRegions are carried through the chain (17.77)
        $view=Get-WsmWizardBackupItemResultsView $sourceRoot $pairId
        $obs.ViewAvailable=[bool]$view.available
        $backedUpIds=@($view.rows|Where-Object {[string]$_.Status -ceq 'BackedUp'}|ForEach-Object {[string]$_.ItemId}|Sort-Object)
        & $Report 'result_set_backed_up_items_equal_approved_set' ($view.available -and ($backedUpIds -join ',') -ceq ($confirmedItemIds -join ',')) ('backedUp='+$backedUpIds.Count)
        $extraRow=@($view.rows|Where-Object {[string]$_.ItemId -ceq [string]$extraItem.ItemId})
        & $Report 'result_set_never_reports_the_extra_inventory_item_as_backed_up' ($extraRow.Count -le 1 -and @($extraRow|Where-Object {[string]$_.Status -ceq 'BackedUp'}).Count -eq 0) ('extra rows='+$extraRow.Count)
        $binding=$view.excludedRegionsBinding
        & $Report 'excluded_regions_binding_is_bound_to_this_scan' ($null -ne $binding -and [string]$binding.Status -ceq 'Bound' -and @($binding.Scans).Count -ge 1 -and @($binding.Scans|Where-Object {[string]$_.ScanId -ceq [string]$scan.ScanId -and [string]$_.CandidateArtifactHash -ceq [string]$scan.CandidateHash}).Count -eq 1) $(if($binding){[string]$binding.Status+' '+[string]$binding.Reason}else{'null'})
        $viewPaths=@($view.excludedRegions|ForEach-Object {[string]$_.Path}|Sort-Object)
        & $Report 'result_set_excluded_region_paths_equal_the_scan_excluded_areas' (($viewPaths -join '|') -ceq ($scanExcludedPaths -join '|') -and $viewPaths.Count -ge 2) ('regions='+$viewPaths.Count)
        $viewBundle=@($view.excludedRegions|Where-Object {[string]$_.Path -ieq $installRoot})
        $viewGuard=@($view.excludedRegions|Where-Object {[string]$_.Path -ieq $guardDir})
        & $Report 'result_set_classifies_bundle_root_and_protected_area' ($viewBundle.Count -eq 1 -and [string]$viewBundle[0].ReasonCode -ceq 'BundleExcluded' -and $viewGuard.Count -eq 1 -and [string]$viewGuard[0].ReasonCode -ceq 'ProtectedArea') 'BundleExcluded / ProtectedArea'
        & $Report 'bundle_contents_and_manual_handling_reach_the_result_set' ($viewBundle.Count -eq 1 -and $viewBundle[0].Contents.Counts.SuspectedBusinessData -ge 1 -and $viewBundle[0].ManualHandling.Required -eq $true -and [string]$view.excludedCompleteness.Status -ceq 'ManualItems') ('completeness='+[string]$view.excludedCompleteness.Status)
        $reportHtml=[IO.File]::ReadAllText([string]$backup.OfflineReport.Path,[Text.Encoding]::UTF8)
        & $Report 'offline_report_html_shows_the_bundle_region_and_never_claims_complete' ($reportHtml.Contains('Vendor App') -and $reportHtml.Contains('data-status="ManualItems"') -and $reportHtml.Contains('BundleExcluded') -and -not $reportHtml.Contains('data-status="NoManualItems"')) 'report names the region and the ManualItems completeness'

        # ---- 6. independent copy: archive bytes == copy bytes
        [void][IO.Directory]::CreateDirectory($media)
        $copy=Invoke-WsmWizardIndependentCopy -Workspace $sourceRoot -PairId $pairId -BackupOperationId $backupOperation -OperationId ([Guid]::NewGuid().ToString('D')) -DestinationRoot $media -Mode Copy
        & $Report 'independent_copy_verified_and_offline_ready' (([string]$copy.IndependentCopy.Status -ceq 'Verified') -and ([string]$copy.OfflineReadiness -ceq 'Verified') -and ([string]$copy.IndependentCopy.MediaClass -ceq 'Removable')) ([string]$copy.IndependentCopy.Status+'/'+[string]$copy.OfflineReadiness)
        $deliveryDir=[string]$backup.Delivery.Directory
        $copyDeliveryDir=Join-Path ([string]$copy.IndependentCopy.CopyRoot) 'transport\delivery'
        $mapOf={param([string]$Dir)$m=@{};foreach($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)){$m[(Rel $Dir $f.FullName).ToLowerInvariant()]=Sha $f.FullName};$m}
        $deliveryMap=& $mapOf $deliveryDir;$copyMap=& $mapOf $copyDeliveryDir
        $mapsEqual=($deliveryMap.Count -eq $copyMap.Count -and $deliveryMap.Count -ge 8);foreach($key in $deliveryMap.Keys){if(-not $copyMap.ContainsKey($key) -or $copyMap[$key] -cne $deliveryMap[$key]){$mapsEqual=$false}}
        & $Report 'independent_copy_delivery_bytes_equal_source_delivery_bytes' $mapsEqual ('delivery files='+$deliveryMap.Count+' copy files='+$copyMap.Count)
        $copyBlobHashes=@(Get-ChildItem -LiteralPath (Join-Path $copyDeliveryDir 'payload') -Filter '*.blob' -File|ForEach-Object {$_.BaseName}|Sort-Object)
        & $Report 'independent_copy_payload_equals_source_file_hashes' (($copyBlobHashes -join ',') -ceq ($expectedHashes -join ',')) ('copy blobs='+$copyBlobHashes.Count)
        $viewAfterCopy=Get-WsmWizardBackupItemResultsView $sourceRoot $pairId
        & $Report 'workbench_view_re_reads_the_copy_receipt_as_verified' ([string]$viewAfterCopy.independentCopy.state -ceq 'Verified') ([string]$viewAfterCopy.independentCopy.state)

        # ---- 7. "not enabled" is stated and observed
        $stateFiles=@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue|Where-Object {$_.Name -in @('state.json','cutover.json','activation.json') -or $_.FullName -like '*\cutover*'})
        $mgrCatalog=Get-WsmCatalog $managerRoot $pairId
        $stageResults=@();if($mgrCatalog.PSObject.Properties['StageResults']){$stageResults=@($mgrCatalog.StageResults)}
        $obs.NotEnabled=[ordered]@{BackupProductionVerified=[bool]$backup.ProductionVerified;ItemResultsProductionVerified=$(if($view.PSObject.Properties['ProductionVerified']){[bool]$view.ProductionVerified}else{$false});SourceApplyOrCutoverStateFiles=$stateFiles.Count;ManagerStageResults=$stageResults.Count;SourceResumeRequired=[bool]$backup.SourceResumeRequired;StatusCode=(Get-WsmOperationStatusCode $backup)}
        & $Report 'not_enabled_nothing_activated_nothing_applied_nothing_marked_verified' (($backup.ProductionVerified -eq $false) -and $stateFiles.Count -eq 0 -and $stageResults.Count -eq 0 -and $reportHtml -notmatch '"ProductionVerified"\s*:\s*true') ('ProductionVerified=false, apply/cutover state files='+$stateFiles.Count+', manager stage results='+$stageResults.Count)
        & $Report 'owner_freeze_was_taken_by_the_backup_and_is_bound_to_the_attempt' ([string]$backup.Freeze.Status -ceq 'Succeeded' -and [string]$backup.Freeze.EvidenceHash -ceq [string]$freezeProof.SHA256) ('Freeze='+[string]$backup.Freeze.Status+' SourceResumeRequired='+$backup.SourceResumeRequired)
        $obs.PairId=$pairId;$obs.ConfirmedItemIds=$confirmedItemIds;$obs.ArchiveFiles=$archiveHashes.Count;$obs.ExcludedRegionCount=$viewPaths.Count
        $obs
    } $script:GTestRoot $fixturePath $script:GRunDir $Mutation ${function:Set-GCheck} ($wsDrive+':'+[char]92)
    $script:GVerdict.Observations=$observations

    Write-GStage 3 'snapshot unchanged, test bytes recorded'
    Confirm-GSnapshotUnchanged @((Join-Path $PSScriptRoot 'G-ScenarioCommon.ps1'),$PSCommandPath)
}
catch{
    $script:GVerdict.Error=[string]$_.Exception.Message
    $script:GVerdict.ErrorPosition=[string]$_.InvocationInfo.PositionMessage
    $script:GVerdict.ErrorStack=[string]$_.ScriptStackTrace
    $innerMessages=@();$inner=$_.Exception.InnerException;while($inner){$innerMessages+=@([string]$inner.Message);if($inner -is [Management.Automation.IContainsErrorRecord]){$innerMessages+=@([string]$inner.ErrorRecord.InvocationInfo.PositionMessage,[string]$inner.ErrorRecord.ScriptStackTrace)};$inner=$inner.InnerException};$script:GVerdict.ErrorInner=$innerMessages
    Write-Host ('FAILED: '+$_.Exception.Message)
    $script:GFailed=$true
}
finally{
    $overall=Complete-GScenario ([bool]$KeepArtifacts)
}
if($overall -cne 'Passed'){exit 1}
