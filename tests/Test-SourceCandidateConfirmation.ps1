#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ExternalReadinessEvidenceFixtures.ps1')
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$tempId=[Convert]::ToBase64String([Guid]::NewGuid().ToByteArray()).TrimEnd('=').Replace('+','-').Replace('/','_')
$root=Join-Path ([IO.Path]::GetTempPath()) ('t-'+$tempId)
if([IO.Directory]::Exists($root) -or [IO.File]::Exists($root)){throw 'Refusing to reuse a preexisting source confirmation test root.'}
[void][IO.Directory]::CreateDirectory($root)
$rootCreated=$true
$checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not $Condition){throw $Message};Write-Output ('PASS '+$Message)}
function Reject([scriptblock]$Action,[string]$Message){$script:checks++;$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};if(-not $rejected){throw $Message};Write-Output ('PASS '+$Message)}
function New-ConfirmationReferenceLengthCase($Template,[int]$Length,[string]$Path){
    $copy=ConvertFrom-Json -InputObject ($Template|ConvertTo-Json -Depth 40 -Compress)
    $copy.Selection.WorkloadReferences=@([pscustomobject][ordered]@{ConsumerItemId=('a'*64);FieldPointer=('x'*$Length);ReferenceKind='File';Path=$Path;Required=$false;ReviewRequired=$true})
    $copy.Selection.WorkloadReferenceCount=1
    $withoutHash=[ordered]@{};foreach($property in $copy.PSObject.Properties){if($property.Name -cne 'SHA256'){$withoutHash[$property.Name]=$property.Value}}
    $copy.SHA256=& $module {param($value) Get-WsmHashText ($value|ConvertTo-Json -Depth 40 -Compress)} $withoutHash
    $copy
}
try{
    $sourceWorkspace=Join-Path $root 's';$managerWorkspace=Join-Path $root 'm';$fixtureC=Join-Path $root 'C-volume-fixture';$targetPath=Join-Path $root 'target-data'
    [void](Initialize-WsmOutputWorkspace -WorkRoot $sourceWorkspace -Role Source)
    [void](Initialize-WsmWorkspace $managerWorkspace)
    $sourceProfile=& $module {param($w) Read-WsmOutputProfile $w} $sourceWorkspace
    $source=[pscustomobject][ordered]@{HostId=[string]$sourceProfile.HostId;Fingerprint=([string]$sourceProfile.Fingerprint).ToLowerInvariant();Name='candidate-source-fixture';OS='Windows Server';Version='2025'}
    $volume=@(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop|Where-Object {([string]$_.DriveLetter).TrimEnd('\\') -ieq 'C:'});if($volume.Count -ne 1){throw 'Fixture requires the local C: volume identity for CV2 proof.'}
    $volumeItem=& $module {param($h,$device) New-WsmItem $h Storage Volume 'C: fixture volume' 'volume:C:' @{DriveLetter='C:';DeviceID=[string]$device} @() Success 'Manual'} $source.HostId $volume[0].DeviceID
    $inventory=& $module {param($s,$items) New-WsmInventory $s 1 $items} $source @($volumeItem)
    $softwareProjectionHash=& $module {param($i) Get-WsmSoftwareInventoryProjectionHash $i} $inventory
    $softwareSource=[pscustomobject][ordered]@{HostId=$source.HostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=$softwareProjectionHash}
    $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=$softwareSource;CaptureContext=[pscustomobject][ordered]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CaptureIdentity='fixture-owner';AccountContext='System';CaptureHost='fixture-source';PowerShellVersion='7.5';RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='NotInstalled';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind='';ObservedUtc=[DateTime]::UtcNow.ToString('o')},[pscustomobject][ordered]@{Probe='Uninstall';Scope='User';SID='';View='Registry64';Status='NotInstalled';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind='';ObservedUtc=[DateTime]::UtcNow.ToString('o')});PreparationRequirements=@();CatalogProjectionHash=''}
    $software.CatalogProjectionHash=& $module {param($c) Get-WsmSoftwareCatalogProjectionHash $c} $software
    $inventory|Add-Member NoteProperty SoftwareCatalog $software -Force
    $inventoryPath=Join-Path (Join-Path (Join-Path (Join-Path $sourceWorkspace 'hosts') $sourceProfile.Fingerprint) 'inventory') 'inventory-1.json'
    & $module {param($p,$i) Write-WsmJson $p $i} $inventoryPath $inventory
    $inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceSnapshotPath=Join-Path $sourceWorkspace ('assistive/snapshots/'+$inventoryHash+'.json');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($sourceSnapshotPath));[IO.File]::Copy($inventoryPath,$sourceSnapshotPath,$false)
    $jobId=[Guid]::NewGuid().ToString('D');$job=[pscustomobject]@{jobId=$jobId;action='SourceInventory';role='Source';workspace=$sourceWorkspace;status='Succeeded';outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash})}
    $null=Set-WsmWizardInventoryBinding -Workspace $sourceWorkspace -Role Source -JobId $jobId -ExpectedWizardRevision 0 -Jobs @($job)
    [void][IO.Directory]::CreateDirectory($fixtureC)
    $business=Join-Path $fixtureC 'Business Data';$nested=Join-Path $business 'nested';$emptyRoot=Join-Path $fixtureC 'Empty Scope';$emptyChild=Join-Path $emptyRoot 'empty-child';$driftRoot=Join-Path $fixtureC 'Drift Scope'
    foreach($dir in @($nested,$emptyChild,$driftRoot)){[void][IO.Directory]::CreateDirectory($dir)}
    $fileOne=Join-Path $business 'customers.dat';$fileTwo=Join-Path $nested 'index.db';$driftFile=Join-Path $driftRoot 'change.bin';$rootLooseFile=Join-Path $fixtureC 'loose-root.txt'
    [IO.File]::WriteAllText($fileOne,'customer data fixture');[IO.File]::WriteAllText($fileTwo,'index fixture');[IO.File]::WriteAllText($driftFile,'before')
    [IO.File]::WriteAllText($rootLooseFile,'root exact-file fixture')
    & $module {param($fixture) $script:WsmSourceCandidateTestRoot=$fixture;Set-Item Function:\Get-WsmSourceCandidateRoot -Value {param([string]$Workspace,$Profile)$script:WsmSourceCandidateTestRoot}} $fixtureC
    $scan=Invoke-WsmSourceCandidateScan -Workspace $sourceWorkspace -Jobs @($job)
    Check ($scan.ScanStatus -ceq 'Succeeded' -and -not $scan.ContinuationRequired -and $scan.CandidateHash -match '^[a-f0-9]{64}$') 'registered source scan emits a complete fixture artifact with independent hash'
    $artifact=Get-Content -LiteralPath $scan.CandidatePath -Raw | ConvertFrom-Json
    $businessCandidate=@($artifact.Candidates|Where-Object {$_.CandidateType -ceq 'DirectoryRoot' -and $_.Path -ieq $business})[0]
    $emptyCandidate=@($artifact.Candidates|Where-Object {$_.CandidateType -ceq 'DirectoryRoot' -and $_.Path -ieq $emptyRoot})[0]
    $driftCandidate=@($artifact.Candidates|Where-Object {$_.CandidateType -ceq 'DirectoryRoot' -and $_.Path -ieq $driftRoot})[0]
    $looseCandidate=@($artifact.Candidates|Where-Object {$_.CandidateType -ceq 'ExactFile' -and $_.Path -ieq $rootLooseFile})[0]
    Check ($businessCandidate -and $emptyCandidate -and $driftCandidate -and $looseCandidate) 'fixture scan discovered separate business, empty-directory, content-drift and C-root loose-file candidates'
    $confirmed=Export-WsmSourceCandidateConfirmation -Workspace $sourceWorkspace -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId $businessCandidate.CandidateId -Jobs @($job)
    Check ($confirmed.Status -ceq 'Confirmed' -and $confirmed.MemberCount -eq 2 -and $confirmed.ConfirmationHash -match '^[a-f0-9]{64}$') 'source confirmation freshly enumerates and hashes exactly the selected business-directory members'
    $confirmation=Get-Content -LiteralPath $confirmed.ConfirmationPath -Raw | ConvertFrom-Json
    Check ($confirmation.Selection.CandidateId -ceq $businessCandidate.CandidateId -and $confirmation.Selection.Members.Count -eq 2 -and $confirmation.Selection.WorkloadReferences.Count -eq $businessCandidate.WorkloadReferences.Count -and -not $confirmation.AuthoritativeApproval) 'confirmation binds candidate, exact members and shared workload references without granting approval'
    Check (@($confirmation.Selection.Members|Where-Object RelativePath -CEQ 'customers.dat').Count -eq 1 -and @($confirmation.Selection.Members|Where-Object RelativePath -CEQ 'nested\index.db').Count -eq 1) 'confirmed member paths are stable and relative to the selected directory root'
    $looseConfirmation=Export-WsmSourceCandidateConfirmation -Workspace $sourceWorkspace -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId $looseCandidate.CandidateId -Jobs @($job)
    $looseArtifact=Get-Content -LiteralPath $looseConfirmation.ConfirmationPath -Raw|ConvertFrom-Json
    Check ($looseArtifact.Selection.CandidateType -ceq 'ExactFile' -and $looseArtifact.Selection.ScopeRoot -ceq $fixtureC -and $looseArtifact.Selection.Members.Count -eq 1 -and $looseArtifact.Selection.Members[0].RelativePath -ceq 'loose-root.txt') 'loose C-root file stays a one-member ExactMembers scope and never becomes WholeScope'
    foreach($length in @(999,2048)){$lengthCase=New-ConfirmationReferenceLengthCase $looseArtifact $length $rootLooseFile;& $module {param($value,$hash) Assert-WsmSourceCandidateConfirmation $value $hash|Out-Null} $lengthCase $lengthCase.SHA256;Check $true ('workload FieldPointer length '+$length+' is accepted at or below the numeric boundary')}
    foreach($length in @(2049,10000)){$lengthCase=New-ConfirmationReferenceLengthCase $looseArtifact $length $rootLooseFile;Reject {& $module {param($value,$hash) Assert-WsmSourceCandidateConfirmation $value $hash|Out-Null} $lengthCase $lengthCase.SHA256} ('workload FieldPointer length '+$length+' is rejected above the numeric boundary')}
    $outsideExact=ConvertFrom-Json -InputObject ($looseArtifact|ConvertTo-Json -Depth 40 -Compress);$outsideScope=Join-Path $root 'outside-scope';$outsideExact.Selection.ScopeRoot=$outsideScope;$outsideExact.Selection.CandidatePath=Join-Path $outsideScope 'loose-root.txt';$outsideHashBody=[ordered]@{};foreach($property in $outsideExact.PSObject.Properties){if($property.Name -cne 'SHA256'){$outsideHashBody[$property.Name]=$property.Value}};$outsideExact.SHA256=& $module {param($value) Get-WsmHashText ($value|ConvertTo-Json -Depth 40 -Compress)} $outsideHashBody
    Reject {& $module {param($value,$hash) Assert-WsmSourceCandidateConfirmation $value $hash|Out-Null} $outsideExact $outsideExact.SHA256} 'ExactFile candidate and scope outside the confirmed C root are rejected'
    $outsideScopeOnly=ConvertFrom-Json -InputObject ($looseArtifact|ConvertTo-Json -Depth 40 -Compress);$outsideScopeOnly.Selection.ScopeRoot=[IO.Path]::GetPathRoot($rootLooseFile);$outsideScopeOnly.Selection.Members[0].RelativePath=$rootLooseFile.Substring([IO.Path]::GetPathRoot($rootLooseFile).Length);$outsideScopeHashBody=[ordered]@{};foreach($property in $outsideScopeOnly.PSObject.Properties){if($property.Name -cne 'SHA256'){$outsideScopeHashBody[$property.Name]=$property.Value}};$outsideScopeOnly.SHA256=& $module {param($value) Get-WsmHashText ($value|ConvertTo-Json -Depth 40 -Compress)} $outsideScopeHashBody
    Reject {& $module {param($value,$hash) Assert-WsmSourceCandidateConfirmation $value $hash|Out-Null} $outsideScopeOnly $outsideScopeOnly.SHA256} 'ExactFile scope outside the confirmed C root is rejected even when its candidate path remains inside'

    Reject {Export-WsmSourceCandidateConfirmation -Workspace $sourceWorkspace -ScanId $scan.ScanId -ExpectedCandidateHash ('0'*64) -CandidateId $businessCandidate.CandidateId -Jobs @($job)} 'stale candidate artifact hash is rejected at the source boundary'
    Reject {Export-WsmSourceCandidateConfirmation -Workspace $sourceWorkspace -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId ('f'*64) -Jobs @($job)} 'unknown candidate ID cannot be confirmed'
    Reject {Export-WsmSourceCandidateConfirmation -Workspace $sourceWorkspace -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId $emptyCandidate.CandidateId -Jobs @($job)} 'empty directories block a DirectoryRoot confirmation instead of disappearing from ExactMembers'
    [IO.File]::WriteAllText((Join-Path $business 'new-neighbor.dat'),'new after scan')
    Reject {Export-WsmSourceCandidateConfirmation -Workspace $sourceWorkspace -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId $businessCandidate.CandidateId -Jobs @($job)} 'a new neighbor after discovery is rejected and never added to an old candidate confirmation'
    [IO.File]::Delete((Join-Path $business 'new-neighbor.dat'))
    $outsideDirectory=Join-Path $fixtureC 'outside-target';[void][IO.Directory]::CreateDirectory($outsideDirectory);[IO.File]::WriteAllText((Join-Path $outsideDirectory 'outside.dat'),'outside')
    $junctionPath=Join-Path $business 'nested';$backupPath=Join-Path $business 'nested-original';Move-Item -LiteralPath $junctionPath -Destination $backupPath
    $junctionCreated=$false
    try{New-Item -ItemType Junction -Path $junctionPath -Target $outsideDirectory -ErrorAction Stop|Out-Null;$junctionCreated=$true}catch{Move-Item -LiteralPath $backupPath -Destination $junctionPath;throw 'Test setup could not create the fixture junction needed for the reparse rejection case.'}
    Reject {Export-WsmSourceCandidateConfirmation -Workspace $sourceWorkspace -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId $businessCandidate.CandidateId -Jobs @($job)} 'reparse-point substitution after discovery is rejected during fresh directory enumeration'
    if($junctionCreated){[IO.Directory]::Delete($junctionPath);Move-Item -LiteralPath $backupPath -Destination $junctionPath}
    [IO.File]::WriteAllText($driftFile,'changed bytes')
    Reject {Export-WsmSourceCandidateConfirmation -Workspace $sourceWorkspace -ScanId $scan.ScanId -ExpectedCandidateHash $scan.CandidateHash -CandidateId $driftCandidate.CandidateId -Jobs @($job)} 'changed source metadata or bytes are rejected during fresh confirmation'
    $tamperedPath=Join-Path $root 'tampered-confirmation.json';$tampered=Get-Content -LiteralPath $confirmed.ConfirmationPath -Raw | ConvertFrom-Json;$tampered.Selection.Members[0].SHA256=('0'*64);$tampered|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $tamperedPath -Encoding UTF8
    Reject {Import-WsmSourceCandidateConfirmation -Workspace $managerWorkspace -PairId ([Guid]::NewGuid().ToString('D')) -Path $tamperedPath -ExpectedHash ((Get-FileHash -LiteralPath $tamperedPath -Algorithm SHA256).Hash) -TargetPath $business -Owner 'fixture owner' -Evidence 'change:fixture' -ExpectedRevision 0} 'tampered confirmation body is rejected even when caller supplies the altered file hash'

    $catalog=Import-WsmInventory -Workspace $managerWorkspace -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'fixture-target'
    $catalog=Enable-WsmAssistiveMode -Workspace $managerWorkspace -PairId $catalog.PairId -ExpectedRevision $catalog.DecisionRevision
    $catalog=Set-WsmAssistiveSelections -Workspace $managerWorkspace -PairId $catalog.PairId -ExpectedRevision $catalog.Assistive.Revision -ItemIds @([string]$volumeItem.ItemId) -Selected $false -Reason 'Fixture volume binding only; no volume migration item is selected.'
    $staleConfirmation=Get-Content -LiteralPath $confirmed.ConfirmationPath -Raw|ConvertFrom-Json;$staleConfirmation.InventoryRevision=2
    $staleBody=[ordered]@{};foreach($property in $staleConfirmation.PSObject.Properties){if($property.Name -cne 'SHA256'){$staleBody[$property.Name]=$property.Value}};$staleConfirmation.SHA256=& $module {param($value) Get-WsmHashText ($value|ConvertTo-Json -Depth 40 -Compress)} $staleBody
    $staleConfirmationPath=Join-Path $root 'stale-source-inventory.json';& $module {param($p,$v) Write-WsmJson $p $v} $staleConfirmationPath $staleConfirmation
    Reject {Import-WsmSourceCandidateConfirmation -Workspace $managerWorkspace -PairId $catalog.PairId -Path $staleConfirmationPath -ExpectedHash ((Get-FileHash -LiteralPath $staleConfirmationPath -Algorithm SHA256).Hash) -TargetPath $business -Owner 'fixture owner' -Evidence 'change:fixture' -ExpectedRevision $catalog.DecisionRevision} 'Manager rejects a confirmation tied to another Source inventory revision'
    Reject {Import-WsmSourceCandidateConfirmation -Workspace $managerWorkspace -PairId $catalog.PairId -Path $confirmed.ConfirmationPath -ExpectedHash ('0'*64) -TargetPath $business -Owner 'fixture owner' -Evidence 'change:fixture' -ExpectedRevision $catalog.DecisionRevision} 'Manager requires an independently supplied matching confirmation hash'
    Reject {Import-WsmSourceCandidateConfirmation -Workspace $managerWorkspace -PairId $catalog.PairId -Path $confirmed.ConfirmationPath -ExpectedHash $confirmed.ConfirmationHash -TargetPath $targetPath -Owner 'fixture owner' -Evidence 'change:fixture' -ExpectedRevision $catalog.DecisionRevision} 'Manager rejects mapping a confirmed candidate to a different target path'
    $imported=Import-WsmSourceCandidateConfirmation -Workspace $managerWorkspace -PairId $catalog.PairId -Path $confirmed.ConfirmationPath -ExpectedHash $confirmed.ConfirmationHash -TargetPath $business -Owner 'fixture owner' -Evidence 'change:fixture' -ExpectedRevision $catalog.DecisionRevision
    Check ($imported.Status -ceq 'ImportedReviewRequired' -and $imported.Decision -ceq 'Pending' -and -not $imported.AuthoritativeApproval -and $imported.ContentSelection -ceq 'ExactMembers') 'Manager import creates a pending exact-member scope without accessing source files or approving it'
    $review=Get-WsmSourceCandidateConfirmationReview -Workspace $managerWorkspace -PairId $catalog.PairId -ItemId $imported.ItemId
    Check ($review.Status -ceq 'ReviewRequired' -and $review.MemberCount -eq 2 -and $review.CandidateArtifactHash -ceq $scan.CandidateHash -and $review.InventoryHash -ceq $inventoryHash -and $review.WorkloadReferences.Count -eq $confirmation.Selection.WorkloadReferences.Count) 'typed Manager review reopens source, inventory, candidate, exact member and shared-consumer evidence'
    $managerCatalog=Get-WsmCatalog $managerWorkspace $catalog.PairId
    Check (@($managerCatalog.Items|Where-Object {$_.ItemId -ceq $imported.ItemId -and $_.Decision -ceq 'Pending' -and $_.ManualEntry -and $_.MigrationSpec.ContentSelection -ceq 'ExactMembers' -and $_.MigrationSpec.Members.Count -eq 2}).Count -eq 1) 'imported confirmation is represented by a real Manager catalog item and ordinary ExactMembers MigrationSpec'
    $managerMaterialPath=Join-Path $managerWorkspace ($review.MaterialReference.Replace('/',[IO.Path]::DirectorySeparatorChar));$materialBytes=[IO.File]::ReadAllBytes($managerMaterialPath)
    try{[IO.File]::WriteAllText($managerMaterialPath,'tampered manager material');Reject {Get-WsmSourceCandidateConfirmationReview -Workspace $managerWorkspace -PairId $catalog.PairId -ItemId $imported.ItemId} 'typed review rejects material bytes that changed after Manager import'}finally{[IO.File]::WriteAllBytes($managerMaterialPath,$materialBytes)}
    $reference=@($managerCatalog.Assistive.MaterialReferences|Where-Object {$_.Reference -ceq $confirmed.MaterialReference -and $_.SHA256 -ieq $confirmed.ConfirmationHash})
    Check ($reference.Count -eq 1 -and $review.MaterialReference -ceq $confirmed.MaterialReference -and [IO.File]::Exists((Join-Path $sourceWorkspace $confirmed.MaterialReference.Replace('/',[IO.Path]::DirectorySeparatorChar)))) 'Source and Manager store the same immutable content-addressed confirmation reference'
    $tamperedSpec=$managerCatalog.Items|Where-Object ItemId -CEQ $imported.ItemId|Select-Object -ExpandProperty MigrationSpec
    $tamperedSpec.Members=@($tamperedSpec.Members)+@([pscustomobject]@{RelativePath='unconfirmed-extra.dat';SHA256=('0'*64)})
    $badSpecPath=Join-Path $root 'tampered-manager-spec.json';& $module {param($p,$v) Write-WsmJson $p $v} $badSpecPath $tamperedSpec
    $null=Set-WsmMigrationSpec -Workspace $managerWorkspace -PairId $catalog.PairId -ItemId $imported.ItemId -Path $badSpecPath -ExpectedHash ((Get-FileHash -LiteralPath $badSpecPath -Algorithm SHA256).Hash) -ExpectedRevision $managerCatalog.DecisionRevision;$managerCatalog=Get-WsmCatalog $managerWorkspace $catalog.PairId
    Reject {Get-WsmSourceCandidateConfirmationReview -Workspace $managerWorkspace -PairId $catalog.PairId -ItemId $imported.ItemId} 'typed review rejects a MigrationSpec whose members differ from the immutable confirmation'
    $managerCatalog=Set-WsmDecision -Workspace $managerWorkspace -PairId $catalog.PairId -ItemId @($imported.ItemId) -Decision Include -ExpectedRevision $managerCatalog.DecisionRevision
    $target=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='TargetIdentity';HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('b'*64);Name='fixture-target'}
    $targetPath=Join-Path $root 'target-identity.json';& $module {param($p,$v) Write-WsmJson $p $v} $targetPath $target
    $preSealPath=Join-Path $root 'tampered-seal.json'
    Reject {Approve-WsmMigrationPlan -Workspace $managerWorkspace -PairId $catalog.PairId -TargetIdentityPath $targetPath -TargetIdentityHash ((Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash) -Path $preSealPath -ExpectedRevision $managerCatalog.DecisionRevision -PilotAcknowledgement 'ISOLATED-PILOT'} 'approval refuses a candidate item whose MigrationSpec member set was changed outside its confirmation'
    $reimported=Import-WsmSourceCandidateConfirmation -Workspace $managerWorkspace -PairId $catalog.PairId -Path $confirmed.ConfirmationPath -ExpectedHash $confirmed.ConfirmationHash -TargetPath $business -Owner 'fixture owner' -Evidence 'change:fixture' -ExpectedRevision $managerCatalog.DecisionRevision
    Check ($reimported.ItemId -ceq $imported.ItemId -and $reimported.Decision -ceq 'Pending') 'reconfirming a stable source candidate updates the same item and returns Include to Pending'
    $managerCatalog=Get-WsmCatalog $managerWorkspace $catalog.PairId
    $included=Set-WsmDecision -Workspace $managerWorkspace -PairId $catalog.PairId -ItemId @($imported.ItemId) -Decision Include -ExpectedRevision $managerCatalog.DecisionRevision
    $planPath=Join-Path $root 'sealed-plan.json'
    $sealed=Approve-WsmMigrationPlan -Workspace $managerWorkspace -PairId $catalog.PairId -TargetIdentityPath $targetPath -TargetIdentityHash ((Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()) -Path $planPath -ExpectedRevision $included.DecisionRevision -PilotAcknowledgement 'ISOLATED-PILOT' -OfflineFullSet
    $plan=& $module {param($p,$h) Read-WsmMigrationPlan $p $h} $sealed.Path $sealed.SHA256
    Check ($plan.Items.Count -eq 1 -and $plan.Items[0].ItemId -ceq $imported.ItemId -and $plan.Items[0].MigrationSpec.ContentSelection -ceq 'ExactMembers' -and $plan.Items[0].MigrationSpec.Members.Count -eq 2 -and $plan.Assistive.ApprovedItemIds -contains $imported.ItemId) 'normal Manager review and approval seal the exact confirmed members into the standard schema-3 plan'
    Check ($plan.Items[0].MigrationSpec.Members[0].SHA256 -match '^[a-f0-9]{64}$' -and $plan.Items[0].MigrationSpec.Members[1].SHA256 -match '^[a-f0-9]{64}$' -and $plan.Items[0].MigrationSpec.SourcePath -ceq $business -and $plan.Assistive.ContractVersion -eq 2 -and @($plan.Assistive.MaterialReferences|Where-Object {$_.Reference -ceq $confirmed.MaterialReference -and $_.SHA256 -ieq $confirmed.ConfirmationHash}).Count -eq 1) 'CV2 sealed plan binds confirmed member hashes and the content-addressed confirmation material'
    Reject {Import-WsmSourceCandidateConfirmation -Workspace $managerWorkspace -PairId $catalog.PairId -Path $confirmed.ConfirmationPath -ExpectedHash $confirmed.ConfirmationHash -TargetPath $business -Owner 'fixture owner' -Evidence 'change:fixture' -ExpectedRevision $catalog.DecisionRevision} 'stale Manager revision cannot re-import or overwrite a candidate confirmation'
    $testIdentity=& $module { $identity=Get-WsmMachineIdentity;$identity.IsServer=$true;$identity.Administrator=$true;$identity.Is64Bit=[Environment]::Is64BitOperatingSystem;$script:WsmSourceCandidateTestIdentity=$identity;Set-Item Function:\Get-WsmMachineIdentity -Value { $script:WsmSourceCandidateTestIdentity };$identity }
    if($testIdentity.Fingerprint -ine $plan.Source.Fingerprint){throw 'Fixture source plan fingerprint does not match the local physical fixture host.'}
    & $module {param($result) $script:WsmSourceCandidateTestInventoryResult=$result;Set-Item Function:\Export-WsmInventory -Value {param([switch]$DeepDiscovery,[switch]$IncludeSoftwareCatalog) $script:WsmSourceCandidateTestInventoryResult }} ([pscustomobject]@{Path=$inventoryPath;SHA256=$inventoryHash})
    $freezeOwner='Fixture source owner';$freezeProof=New-WsmSourceFreezeEvidenceFixture -Plan $plan -PlanHash $sealed.SHA256 -Root $root -Owner $freezeOwner
    $freezePath=Join-Path $root 'source-freeze.json';$priorConfirmPreference=$ConfirmPreference;$ConfirmPreference='None'
    try{$freeze=Export-WsmFreezeRecord -PlanPath $sealed.Path -ExpectedHash $sealed.SHA256 -Path $freezePath -Owner $freezeOwner -Evidence 'Fixture only; no source producer exists in this manual ExactMembers scope.' -Acknowledgement 'OWNER-CONFIRMED-QUIESCENCE' -SourceStateDirectory $sourceWorkspace -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256 -FreezeEpoch $freezeProof.FreezeEpoch}finally{$ConfirmPreference=$priorConfirmPreference}
    Check ($freeze.SHA256 -match '^[A-Fa-f0-9]{64}$' -and $freeze.FreezeId) 'real source freeze-record consumer accepts fixture-only typed writer evidence for the ManualItem plan'
    $packageDirectory=Join-Path $root 'captured-cv2';$package=Export-WsmMigrationPackage -PlanPath $sealed.Path -ExpectedHash $sealed.SHA256 -SourceStateDirectory $sourceWorkspace -OutputDirectory $packageDirectory -ChunkBytes 65536 -FreezePath $freeze.Path -FreezeHash $freeze.SHA256 -FreezeExternalEvidencePath $freezeProof.Path -FreezeExternalEvidenceHash $freezeProof.SHA256
    $readback=Test-WsmMigrationPackage -ManifestPath $package.ManifestPath -ExpectedHash $package.SHA256
    Check ($readback.Valid -and $readback.Plan.Assistive.ContractVersion -eq 2 -and @($readback.Plan.Assistive.MaterialReferences|Where-Object {$_.Reference -ceq $confirmed.MaterialReference -and $_.SHA256 -ieq $confirmed.ConfirmationHash}).Count -eq 1) 'CV2 capture and reader retain the exact source confirmation material reference and hash'
    Write-Output ('PASS Test-SourceCandidateConfirmation: '+$script:checks+' source confirmation, Manager import, typed review and sealed-plan checks.')
}finally{
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\';$resolved=[IO.Path]::GetFullPath($root);$name=[IO.Path]::GetFileName($resolved)
    if(-not $rootCreated -or [IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine $temp.TrimEnd('\') -or $name -notmatch '^t-[A-Za-z0-9_-]{22}$' -or -not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or $resolved -eq $temp.TrimEnd('\')){throw 'Refusing to clean a test directory outside its newly-created random temp root.'}
    if([IO.Directory]::Exists($resolved)){if(([IO.File]::GetAttributes($resolved) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Refusing to clean a reparse-point test root.'};Remove-Item -LiteralPath $resolved -Recurse -Force}
}
