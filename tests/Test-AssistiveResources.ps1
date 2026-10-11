#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
. (Join-Path $PSScriptRoot '..\src\PhysicalPaths.ps1')
. (Join-Path $PSScriptRoot '..\src\MigrationContracts.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveNonC.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveResources.ps1')
. (Join-Path $PSScriptRoot '..\src\Restore.ps1')
. (Join-Path $PSScriptRoot '..\src\StreamingDigest.ps1')
. (Join-Path $PSScriptRoot '..\src\JournalRecovery.ps1')
. (Join-Path $PSScriptRoot '..\src\Recovery.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-resources-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Message}
try {
    $workspace=Join-Path $root 'workspace';Initialize-WsmWorkspace $workspace|Out-Null
    $pair1=[Guid]::NewGuid().ToString();$pair2=[Guid]::NewGuid().ToString();$item1='a'*64;$item2='b'*64;$sourceHash='c'*64
    $shared=Join-Path $root 'shared-pool.config';[IO.File]::WriteAllText($shared,'prior configuration')
    $physical=(Resolve-WsmAssistivePhysicalResource $shared '').PhysicalIdentity
    Reject {Resolve-WsmAssistivePhysicalResource '\\server.example\share\pool.config' 'untrusted-provider-string'} 'Provider string alone was accepted as SMB physical identity proof.'
    $folderKey1=Get-WsmAssistiveTypedResourceIdentity ('a'*64) TaskFolder '\Microsoft\WSM'
    $folderKey2=Get-WsmAssistiveTypedResourceIdentity ('a'*64) TaskFolder '\microsoft/WSM/'
    Check ($folderKey1 -ceq $folderKey2) 'Task-folder resource identity did not canonicalize separators/case.'
    Check ((Get-WsmAssistiveTypedResourceIdentity ('a'*64) IISPool 'SharedPool') -cne (Get-WsmAssistiveTypedResourceIdentity ('b'*64) IISPool 'SharedPool')) 'Same-named typed target resources on different hosts collided.'
    $preview=Get-WsmAssistiveResourceReservationPreview -Workspace $workspace -PairId $pair1 -ItemId $item1 -Path $shared -Channel C -SourceHash $sourceHash -TargetPhysicalId $physical -ConsumerRefs @('IIS:site:A','IIS:site:B')
    $reserved=Reserve-WsmAssistiveResource -Workspace $workspace -Preview $preview -ExpectedPreviewHash $preview.SHA256 -ExpectedRevision $preview.RegistryRevision -Reason 'Reviewed shared pool consumers A and B.'
    Check ($reserved.Reserved -and $reserved.Owner.ConsumerRefs.Count -eq 2) 'Shared consumer ownership was not durably reserved.'
    $conflict=Get-WsmAssistiveResourceReservationPreview -Workspace $workspace -PairId $pair2 -ItemId $item2 -Path $shared -Channel NonC -SourceHash ('d'*64) -TargetPhysicalId $physical -ConsumerRefs @('Task:runner')
    Check (-not $conflict.CanReserve -and $conflict.Conflicts.Count -eq 1) 'Different source mapped to an owned physical resource without a conflict.'
    Reject {Reserve-WsmAssistiveResource -Workspace $workspace -Preview $conflict -ExpectedPreviewHash $conflict.SHA256 -ExpectedRevision $conflict.RegistryRevision -Reason 'must reject'} 'Conflicting cross-pair reservation was acquired.'
    $evidence=Set-WsmAssistiveResourceEvidence -Workspace $workspace -ResourceKey $reserved.ResourceKey -PairId $pair1 -ItemId $item1 -Channel C -ExpectedRevision $reserved.RegistryRevision -Prior ([pscustomobject]@{Value='before'}) -Desired ([pscustomobject]@{Value='after'}) -Readback ([pscustomobject]@{Value='after'}) -Undo ([pscustomobject]@{Value='before'}) -DriftStatus Match
    Check ($evidence.Resources[0].Owners[0].Undo.Value -eq 'before' -and $evidence.Resources[0].Owners[0].EvidenceHash -match '^[a-f0-9]{64}$') 'Reservation did not retain hash-bound prior/readback/undo evidence.'
    $released=Release-WsmAssistiveResource -Workspace $workspace -ResourceKey $reserved.ResourceKey -PairId $pair1 -ItemId $item1 -Channel C -ExpectedRevision $evidence.Revision -Reason 'Stage complete and readback matched.'
    Check ($released.Resources[0].Owners.Count -eq 0) 'Exact resource owner could not release its reservation.'

    $scopeRoot=Join-Path $root 'target-scopes';$parentScope=Join-Path $scopeRoot 'shared';$childScope=Join-Path $parentScope 'nested';$siblingScope=Join-Path $scopeRoot 'other'
    [void][IO.Directory]::CreateDirectory($childScope);[void][IO.Directory]::CreateDirectory($siblingScope)
    $parentPhysical=(Resolve-WsmAssistivePhysicalResource $parentScope '').PhysicalIdentity
    $parentPreview=Get-WsmAssistiveResourceReservationPreview -Workspace $workspace -PairId $pair1 -ItemId $item1 -Path $parentScope -Channel C -SourceHash $sourceHash -TargetPhysicalId $parentPhysical -ConsumerRefs @('FileScope:shared')
    $parentReservation=Reserve-WsmAssistiveResource -Workspace $workspace -Preview $parentPreview -ExpectedPreviewHash $parentPreview.SHA256 -ExpectedRevision $parentPreview.RegistryRevision -Reason 'Reviewed shared file scope.'
    $nestedPhysical=(Resolve-WsmAssistivePhysicalResource $childScope '').PhysicalIdentity
    $nestedPreview=Get-WsmAssistiveResourceReservationPreview -Workspace $workspace -PairId $pair2 -ItemId $item2 -Path $childScope -Channel NonC -SourceHash ('d'*64) -TargetPhysicalId $nestedPhysical -ConsumerRefs @('FileScope:nested')
    Check (-not $nestedPreview.CanReserve -and $nestedPreview.Conflicts.Count -eq 1) 'Nested file scope did not conflict with an ancestor physical reservation.'
    $siblingPhysical=(Resolve-WsmAssistivePhysicalResource $siblingScope '').PhysicalIdentity
    $siblingPreview=Get-WsmAssistiveResourceReservationPreview -Workspace $workspace -PairId $pair2 -ItemId $item2 -Path $siblingScope -Channel NonC -SourceHash ('d'*64) -TargetPhysicalId $siblingPhysical -ConsumerRefs @('FileScope:sibling')
    Check $siblingPreview.CanReserve 'Disjoint sibling file scope was overblocked by a volume-wide resource lock.'
    Release-WsmAssistiveResource -Workspace $workspace -ResourceKey $parentReservation.ResourceKey -PairId $pair1 -ItemId $item1 -Channel C -ExpectedRevision (Get-WsmAssistiveResourceRegistry $workspace).Revision -Reason 'Scope check complete.'|Out-Null

    $material=Join-Path $root 'closed-base.bin';[IO.File]::WriteAllBytes($material,[byte[]](1,2,3,4));$materialHash=Get-WsmAssistiveNonCHash $material
    $expiry=[DateTime]::UtcNow.AddDays(-2).ToString('o')
    $m1=Register-WsmAssistiveMaterialReference -Workspace $workspace -PairId $pair1 -Generation 1 -Path $material -SHA256 $materialHash -Kind FullBase -ConsumerRefs @('Pair:one:Generation:1')
    $m1Shared=Register-WsmAssistiveMaterialReference -Workspace $workspace -PairId $pair1 -Generation 1 -Path $material -SHA256 $materialHash -Kind FullBase -ConsumerRefs @('Repair:one:Generation:1')
    Check ($m1Shared.ConsumerRefs.Count -eq 2) 'Repeated registration overwrote an existing material consumer reference.'
    $m2=Register-WsmAssistiveMaterialReference -Workspace $workspace -PairId $pair2 -Generation 2 -Path $material -SHA256 $materialHash -Kind SharedBase -ConsumerRefs @('Pair:two:Generation:2')
    $stale=Get-WsmAssistiveCleanupPreview -Workspace $workspace -RetentionBeforeUtc (Get-WsmUtc)
    [IO.File]::WriteAllText((Join-Path $root 'new-reference.txt'),'new');$newPath=Join-Path $root 'new-reference.txt';$newHash=Get-WsmAssistiveNonCHash $newPath
    Register-WsmAssistiveMaterialReference -Workspace $workspace -PairId $pair2 -Generation 2 -Path $newPath -SHA256 $newHash -Kind DeltaBase -ConsumerRefs @('Pair:two:Generation:2')|Out-Null
    Reject {Invoke-WsmAssistiveCleanup -Workspace $workspace -Preview $stale -ExpectedPreviewHash $stale.SHA256 -ExpectedRevision $stale.RegistryRevision -Reason 'old preview' -Confirmed $true -Confirm:$false} 'Cleanup accepted a stale preview after a new material reference was registered.'
    Check ([IO.File]::Exists($material)) 'Stale cleanup preview deleted a still referenced material.'
    Set-WsmAssistiveMaterialClosed -Workspace $workspace -MaterialId $m1.MaterialId -ExpectedRevision (Get-WsmAssistiveResourceRegistry $workspace).Revision -RetentionUntilUtc $expiry|Out-Null
    $operation=[Guid]::NewGuid().ToString();Set-WsmAssistiveJobLock -Workspace $workspace -OperationId $operation -PairId $pair1 -Generation 1 -MaterialIds @($m1.MaterialId) -Active $true|Out-Null
    $lateMaterialPath=Join-Path $root 'late-result.bin';[IO.File]::WriteAllBytes($lateMaterialPath,[byte[]](8,7,6));$lateMaterialHash=Get-WsmAssistiveNonCHash $lateMaterialPath;$lateMaterialId=Get-WsmHashText ($pair1+'|1|'+$lateMaterialPath.ToLowerInvariant()+'|'+$lateMaterialHash.ToLowerInvariant())
    $lateRegistry=Get-WsmAssistiveResourceRegistry $workspace;$lateRegistry.Materials=@($lateRegistry.Materials)+@([pscustomobject]@{MaterialId=$lateMaterialId;PairId=$pair1;Generation=1;Path=$lateMaterialPath;SHA256=$lateMaterialHash;Kind='LateNonCResult';ConsumerRefs=@();Closed=$true;RetentionUntilUtc=$expiry;RegisteredUtc=(Get-WsmUtc)});Write-WsmAssistiveResourceRegistry $workspace $lateRegistry|Out-Null
    Reject {Set-WsmAssistiveMaterialClosed -Workspace $workspace -MaterialId $lateMaterialId -ExpectedRevision (Get-WsmAssistiveResourceRegistry $workspace).Revision -RetentionUntilUtc $expiry} 'Material close ignored an active job for the same pair/generation when this late material was not in the initial lock set.'
    $lateAlias=Register-WsmAssistiveMaterialReference -Workspace $workspace -PairId $pair2 -Generation 2 -Path $lateMaterialPath -SHA256 $lateMaterialHash -Kind SharedBase -ConsumerRefs @('shared-alias')
    Set-WsmAssistiveMaterialClosed -Workspace $workspace -MaterialId $lateAlias.MaterialId -ExpectedRevision (Get-WsmAssistiveResourceRegistry $workspace).Revision -RetentionUntilUtc $expiry|Out-Null
    $lockedPreview=Get-WsmAssistiveCleanupPreview -Workspace $workspace -RetentionBeforeUtc (Get-WsmUtc)
    Check (-not ($lockedPreview.Rows|Where-Object MaterialId -CEQ $m1.MaterialId).Eligible) 'Cleanup preview marked a live-job-locked base eligible.'
    Check (-not ($lockedPreview.Rows|Where-Object MaterialId -CEQ $lateMaterialId).Eligible -and ($lockedPreview.Rows|Where-Object MaterialId -CEQ $lateMaterialId).Reason -match 'pair/generation') 'Cleanup preview did not hold a late material from an active pair/generation.'
    Check (-not ($lockedPreview.Rows|Where-Object MaterialId -CEQ $lateAlias.MaterialId).Eligible) 'Cleanup preview offered a shared physical material whose other pair/generation still has an active job.'
    Reject {Set-WsmAssistiveJobLock -Workspace $workspace -OperationId $operation -PairId $pair2 -Generation 1 -MaterialIds @($m1.MaterialId) -Active $false} 'Live-job lock was released with the wrong pair.'
    Reject {Set-WsmAssistiveJobLock -Workspace $workspace -OperationId $operation -PairId $pair1 -Generation 2 -MaterialIds @($m1.MaterialId) -Active $false} 'Live-job lock was released with the wrong generation.'
    Reject {Set-WsmAssistiveJobLock -Workspace $workspace -OperationId $operation -PairId $pair1 -Generation 1 -MaterialIds @() -Active $false} 'Live-job lock was released with a subset of its material IDs.'
    Reject {Set-WsmAssistiveJobLock -Workspace $workspace -OperationId $operation -PairId $pair1 -Generation 1 -MaterialIds @($m1.MaterialId,$m1.MaterialId) -Active $false} 'Live-job lock was released with duplicate material IDs.'
    $lockedResult=Invoke-WsmAssistiveCleanup -Workspace $workspace -Preview $lockedPreview -ExpectedPreviewHash $lockedPreview.SHA256 -ExpectedRevision $lockedPreview.RegistryRevision -Reason 'Review locked cleanup candidate.' -Confirmed $true -Confirm:$false
    Check ([IO.File]::Exists($material) -and $lockedResult.Retained -contains $m1.MaterialId) 'Cleanup deleted a live-job-locked base.'
    Set-WsmAssistiveJobLock -Workspace $workspace -OperationId $operation -PairId $pair1 -Generation 1 -MaterialIds @($m1.MaterialId) -Active $false|Out-Null
    Reject {Set-WsmAssistiveJobLock -Workspace $workspace -OperationId $operation -PairId $pair1 -Generation 1 -MaterialIds @($m1.MaterialId) -Active $false} 'Repeated exact release silently succeeded after the lock was already removed.'
    Set-WsmAssistiveMaterialClosed -Workspace $workspace -MaterialId $m2.MaterialId -ExpectedRevision (Get-WsmAssistiveResourceRegistry $workspace).Revision -RetentionUntilUtc $expiry|Out-Null
    $finalPreview=Get-WsmAssistiveCleanupPreview -Workspace $workspace -RetentionBeforeUtc (Get-WsmUtc)
    Check (($finalPreview.Rows|Where-Object MaterialId -CEQ $m1.MaterialId).Eligible) 'Closed expired material with no references was not eligible after lock release.'
    $clean=Invoke-WsmAssistiveCleanup -Workspace $workspace -Preview $finalPreview -ExpectedPreviewHash $finalPreview.SHA256 -ExpectedRevision $finalPreview.RegistryRevision -Reason 'Owner approved expired base removal.' -Confirmed $true -Confirm:$false
    Check (-not [IO.File]::Exists($material) -and $clean.Deleted -contains $m1.MaterialId) 'Confirmed cleanup did not remove the closed, unreferenced, expired material.'
    Check ([IO.File]::Exists($newPath)) 'Cleanup removed a material still referenced by another pair/generation.'

    $statusWorkspace=Join-Path $root 'material-status-workspace';Initialize-WsmWorkspace $statusWorkspace|Out-Null
    $statusPair=[Guid]::NewGuid().ToString();$statusOperation=[Guid]::NewGuid().ToString();$statusManifest=('e'*64);$statusPlan=('f'*64);$statusFingerprint=('1'*64);$statusMaterial1=('2'*64);$statusMaterial2=('3'*64)
    $script:materialJobStatusPackage=[pscustomobject]@{Manifest=[pscustomobject]@{PairId=$statusPair;Generation=7;PlanHash=$statusPlan;Target=[pscustomobject]@{Fingerprint=$statusFingerprint}};Plan=[pscustomobject]@{SchemaVersion=3;PlanHash=$statusPlan}}
    function Test-WsmMigrationPackage([string]$ManifestPath,[string]$ExpectedHash){if($ExpectedHash -cne $script:materialJobStatusPackage.ManifestHashExpected){throw 'Mock package hash mismatch.'};$script:materialJobStatusPackage}
    $script:materialJobStatusPackage | Add-Member NoteProperty ManifestHashExpected $statusManifest
    function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=$(if($script:materialJobStatusIdentityOverride){$script:materialJobStatusIdentityOverride}else{$script:materialJobStatusPackage.Manifest.Target.Fingerprint})}}
    function Assert-WsmMigrationHost($Identity,[string]$Fingerprint){if([string]$Identity.Fingerprint -cne $Fingerprint){throw 'Mock target identity mismatch.'}}
    $statusPaths=Get-WsmOperationPaths $statusWorkspace $statusPair
    $statusState=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='OperationState';BatchId=[Guid]::NewGuid().ToString();PairId=$statusPair;TargetFingerprint=$statusFingerprint;PlanHash=$statusPlan;RunId=[Guid]::NewGuid().ToString();ManifestHash=$statusManifest;Generation=7;Stage='Running';Sequence=0;ResultSequence=0;JournalHash=('0'*64);JournalSegment=0;Items=@();Evidence=@();PendingOperations=@([pscustomobject]@{Phase='AssistiveAdapterCreating'});RestoreAttempt=[pscustomobject]@{ManifestHash=$statusManifest;Generation=7;MaterialJobOperationId=$statusOperation;MaterialIds=@($statusMaterial1,$statusMaterial2)};SecretValue='must not be exported'}
    Write-WsmJson $statusPaths.State $statusState;Add-WsmJournal $statusPaths $statusState 'AssistiveRestoreStarted' '' $statusState.RestoreAttempt
    $statusRegistry=Get-WsmAssistiveResourceRegistry $statusWorkspace;$statusRegistry.Materials=@([pscustomobject]@{MaterialId=$statusMaterial1;PairId=$statusPair;Generation=7},[pscustomobject]@{MaterialId=$statusMaterial2;PairId=$statusPair;Generation=7});Write-WsmAssistiveResourceRegistry $statusWorkspace $statusRegistry|Out-Null
    Set-WsmAssistiveJobLock -Workspace $statusWorkspace -OperationId $statusOperation -PairId $statusPair -Generation 7 -MaterialIds @($statusMaterial1,$statusMaterial2) -Active $true|Out-Null
    $statusHtml=Join-Path $root 'material-job-status.html';$statusReport=Export-WsmAssistiveMaterialJobStatus -ManifestPath 'trusted-fixture' -ExpectedHash $statusManifest -StateDirectory $statusWorkspace -Path $statusHtml
    $statusHtmlText=[IO.File]::ReadAllText($statusHtml)
    Check ($statusReport.Status -ceq 'ReportOnly' -and $statusReport.LockStatus -ceq 'Locked' -and $statusReport.HtmlPath -ceq [IO.Path]::GetFullPath($statusHtml) -and $statusHtmlText.Contains($statusOperation) -and $statusHtmlText.Contains($statusMaterial1) -and $statusHtmlText.Contains('PendingOperationCount') -and $statusHtmlText.Contains('NotVerified') -and -not $statusHtmlText.Contains('must not be exported')) 'Material job status did not expose only the safe, exact recovery identifiers.'
    Reject {Export-WsmAssistiveMaterialJobStatus -ManifestPath 'trusted-fixture' -ExpectedHash ('4'*64) -StateDirectory $statusWorkspace -Path $statusHtml} 'Material job status accepted a mismatched trusted package hash.'
    $script:materialJobStatusIdentityOverride=('9'*64);Reject {Export-WsmAssistiveMaterialJobStatus -ManifestPath 'trusted-fixture' -ExpectedHash $statusManifest -StateDirectory $statusWorkspace -Path $statusHtml} 'Material job status accepted a package for a different native target.';$script:materialJobStatusIdentityOverride=''
    $statusRegistry=Get-WsmAssistiveResourceRegistry $statusWorkspace;$statusRegistry.LiveJobs[0].MaterialIds=@($statusMaterial1);Write-WsmAssistiveResourceRegistry $statusWorkspace $statusRegistry|Out-Null
    Reject {Export-WsmAssistiveMaterialJobStatus -ManifestPath 'trusted-fixture' -ExpectedHash $statusManifest -StateDirectory $statusWorkspace -Path $statusHtml} 'Material job status accepted a registry lock with a subset of RestoreAttempt material IDs.'
    [IO.File]::AppendAllText($statusPaths.Journal,"invalid journal row`n")
    Reject {Export-WsmAssistiveMaterialJobStatus -ManifestPath 'trusted-fixture' -ExpectedHash $statusManifest -StateDirectory $statusWorkspace -Path $statusHtml} 'Material job status exported identifiers when the durable journal was inconsistent.'

    $registryOnlyWorkspace=Join-Path $root 'material-registry-only-workspace';Initialize-WsmWorkspace $registryOnlyWorkspace|Out-Null
    $registryOnlyPair=[Guid]::NewGuid().ToString();$registryOnlyOperation=[Guid]::NewGuid().ToString();$registryOnlyGeneration=12
    $registryOnlyMaterialPath=Join-Path $root 'nonc-result-material.bin';[IO.File]::WriteAllBytes($registryOnlyMaterialPath,[byte[]](4,5,6,7));$registryOnlyMaterialHash=Get-WsmAssistiveNonCHash $registryOnlyMaterialPath
    $registryOnlyMaterial=Register-WsmAssistiveMaterialReference -Workspace $registryOnlyWorkspace -PairId $registryOnlyPair -Generation $registryOnlyGeneration -Path $registryOnlyMaterialPath -SHA256 $registryOnlyMaterialHash -Kind NonCTransferResult -ConsumerRefs @('Transfer:reviewed-plan:entry:1')
    Set-WsmAssistiveJobLock -Workspace $registryOnlyWorkspace -OperationId $registryOnlyOperation -PairId $registryOnlyPair -Generation $registryOnlyGeneration -MaterialIds @($registryOnlyMaterial.MaterialId) -Active $true|Out-Null
    $registryOnlyHtml=Join-Path $root 'nonc-material-registry-status.html';$registryOnlyReport=Export-WsmAssistiveMaterialJobStatus -Mode NonCRegistry -StateDirectory $registryOnlyWorkspace -PairId $registryOnlyPair -Generation $registryOnlyGeneration -Path $registryOnlyHtml
    $registryOnlyHtmlText=[IO.File]::ReadAllText($registryOnlyHtml)
    Check ($registryOnlyReport.Status -ceq 'ReportOnly' -and $registryOnlyReport.Binding -ceq 'RegistryOnly' -and $registryOnlyReport.LockStatus -ceq 'Locked' -and $registryOnlyHtmlText.Contains($registryOnlyOperation) -and $registryOnlyHtmlText.Contains($registryOnlyMaterial.MaterialId) -and $registryOnlyHtmlText.Contains('NonCTransferResult') -and $registryOnlyHtmlText.Contains($registryOnlyMaterialHash) -and $registryOnlyHtmlText.Contains('PendingOperations') -and $registryOnlyHtmlText.Contains('TransferId') -and $registryOnlyHtmlText.Contains('NotVerified')) 'NonC registry producer output was not consumable through the registry-only status report.'
    $registryOnlyRegistry=Get-WsmAssistiveResourceRegistry $registryOnlyWorkspace;$registryOnlyRegistry.Materials[0].PairId=$pair2;Write-WsmAssistiveResourceRegistry $registryOnlyWorkspace $registryOnlyRegistry|Out-Null
    Reject {Export-WsmAssistiveMaterialJobStatus -Mode NonCRegistry -StateDirectory $registryOnlyWorkspace -PairId $registryOnlyPair -Generation $registryOnlyGeneration -Path $registryOnlyHtml} 'NonC registry status accepted a live-job material belonging to another pair.'
    Write-Host ('PASS: '+$passed+' Assistive resource reservation/cleanup checks.')
} catch {throw}
finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
