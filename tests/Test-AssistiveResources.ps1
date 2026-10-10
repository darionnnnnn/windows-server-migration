#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
. (Join-Path $PSScriptRoot '..\src\PhysicalPaths.ps1')
. (Join-Path $PSScriptRoot '..\src\MigrationContracts.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveNonC.ps1')
. (Join-Path $PSScriptRoot '..\src\AssistiveResources.ps1')
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
    $lockedPreview=Get-WsmAssistiveCleanupPreview -Workspace $workspace -RetentionBeforeUtc (Get-WsmUtc)
    Check (-not ($lockedPreview.Rows|Where-Object MaterialId -CEQ $m1.MaterialId).Eligible) 'Cleanup preview marked a live-job-locked base eligible.'
    $lockedResult=Invoke-WsmAssistiveCleanup -Workspace $workspace -Preview $lockedPreview -ExpectedPreviewHash $lockedPreview.SHA256 -ExpectedRevision $lockedPreview.RegistryRevision -Reason 'Review locked cleanup candidate.' -Confirmed $true -Confirm:$false
    Check ([IO.File]::Exists($material) -and $lockedResult.Retained -contains $m1.MaterialId) 'Cleanup deleted a live-job-locked base.'
    Set-WsmAssistiveJobLock -Workspace $workspace -OperationId $operation -PairId $pair1 -Generation 1 -MaterialIds @($m1.MaterialId) -Active $false|Out-Null
    Set-WsmAssistiveMaterialClosed -Workspace $workspace -MaterialId $m2.MaterialId -ExpectedRevision (Get-WsmAssistiveResourceRegistry $workspace).Revision -RetentionUntilUtc $expiry|Out-Null
    $finalPreview=Get-WsmAssistiveCleanupPreview -Workspace $workspace -RetentionBeforeUtc (Get-WsmUtc)
    Check (($finalPreview.Rows|Where-Object MaterialId -CEQ $m1.MaterialId).Eligible) 'Closed expired material with no references was not eligible after lock release.'
    $clean=Invoke-WsmAssistiveCleanup -Workspace $workspace -Preview $finalPreview -ExpectedPreviewHash $finalPreview.SHA256 -ExpectedRevision $finalPreview.RegistryRevision -Reason 'Owner approved expired base removal.' -Confirmed $true -Confirm:$false
    Check (-not [IO.File]::Exists($material) -and $clean.Deleted -contains $m1.MaterialId) 'Confirmed cleanup did not remove the closed, unreferenced, expired material.'
    Check ([IO.File]::Exists($newPath)) 'Cleanup removed a material still referenced by another pair/generation.'
    Write-Host ('PASS: '+$passed+' Assistive resource reservation/cleanup checks.')
} catch {throw}
finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
