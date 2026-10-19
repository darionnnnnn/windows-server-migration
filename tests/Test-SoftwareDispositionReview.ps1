#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};Check $rejected $Message}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-software-disposition-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $workspace=Join-Path $root 'manager';[void](Initialize-WsmWorkspace $workspace)
    $hostId=[Guid]::NewGuid().ToString();$source=[pscustomobject][ordered]@{HostId=$hostId;Fingerprint=('a'*64);Name='disposition-fixture';OS='Windows Server';Version='2025'}
    $consumer=New-WsmItem $hostId Services Service 'Selected consumer' 'selected-consumer' ([pscustomobject]@{PathName='D:\FixtureData\svc.exe'}) @() Success
    $unselected=New-WsmItem $hostId Services Service 'Unselected consumer' 'unselected-consumer' ([pscustomobject]@{PathName='D:\FixtureData\other.exe'}) @() Success
    $inventory=New-WsmInventory $source 1 @($consumer,$unselected)
    $catalogSource=[pscustomobject][ordered]@{HostId=$hostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=(& $module {param($value) Get-WsmSoftwareInventoryProjectionHash $value} $inventory)}
    $capture=[pscustomobject][ordered]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');CaptureIdentity='fixture-owner';AccountContext='System';CaptureHost='fixture-host';PowerShellVersion='5.1';RequestedPortableRoots=@('D:\FixtureData\PortableApp')}
    function New-SoftwareRow([string]$hex,[string]$name,[string]$scope,[string]$sid,[string]$location,[string]$sourceKind,[string[]]$itemIds,[string]$architecture='x64'){
        [pscustomobject][ordered]@{SoftwareId=('sw-'+$hex);Name=$name;Version='Unknown';Publisher='Fixture';Architecture=$architecture;Scope=$scope;SID=$sid;RegistryView='Registry64';Location=$location;SourceKind=$sourceKind;Evidence=$(if($sourceKind -ceq 'Registry'){[pscustomobject]@{RegistryPath='HKLM64\Uninstall\'+$hex;NaturalKey=$hex}}else{[pscustomobject]@{EvidenceKind='OwnerObserved'}});ObservedUtc=[DateTime]::UtcNow.ToString('o');CaptureStatus='Success';ItemIds=$itemIds;AccountContext='System'}
    }
    $rows=@(
        (New-SoftwareRow ('a'*32) 'Selected runtime' Machine '' 'D:\FixtureData\Apps\Selected' Registry @($consumer.ItemId)),
        (New-SoftwareRow ('b'*32) 'Unselected user tool' User 'S-1-5-21-100-200-300-1001' 'registry:HKU\fixture\Uninstall\tool' Registry @($unselected.ItemId) x86),
        (New-SoftwareRow ('c'*32) 'Microsoft SQL Server Database Engine' Machine '' 'D:\FixtureData\Sql' Registry @()),
        (New-SoftwareRow ('d'*32) 'Portable business tool' Portable '' 'D:\FixtureData\PortableApp\tool.exe' PortableEvidence @())
    )
    $coverage=@(
        [pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=2;Budget=[pscustomobject]@{MaxEntries=5000;VisitedEntries=2;MaxMetadataBytes=1048576;MetadataBytes=2048};ErrorKind=$null;ObservedUtc=[DateTime]::UtcNow.ToString('o')},
        [pscustomobject][ordered]@{Probe='Uninstall';Scope='User';SID='S-1-5-21-100-200-300-1001';View='Registry32';Status='PermissionDenied';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=5000};ErrorKind='AccessDenied';ObservedUtc=[DateTime]::UtcNow.ToString('o')}
    )
    $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=$catalogSource;CaptureContext=$capture;Entries=$rows;Coverage=$coverage;PreparationRequirements=@(foreach($row in $rows){[pscustomobject][ordered]@{PreparationId=('prep-'+$row.SoftwareId.Substring(3));SoftwareId=$row.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus=$row.CaptureStatus;ConsumerItemIds=@($row.ItemIds);Owner='';Reason='Fixture discovery evidence'}});CatalogProjectionHash=''}
    $software.CatalogProjectionHash=& $module {param($value) Get-WsmSoftwareCatalogProjectionHash $value} $software
    $inventory | Add-Member NoteProperty SoftwareCatalog $software
    $inventoryPath=Join-Path $root 'source-inventory.json';& $module {param($path,$value) Write-WsmJson $path $value} $inventoryPath $inventory | Out-Null
    $inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=Import-WsmInventory -Workspace $workspace -Path $inventoryPath -ExpectedHash $inventoryHash -TargetName 'fixture-target'
    $catalog=Set-WsmGeneralHostMode $workspace $catalog.PairId $catalog.DecisionRevision
    $catalog=Set-WsmDecision -Workspace $workspace -PairId $catalog.PairId -ItemId @($consumer.ItemId) -Decision Include -ExpectedRevision $catalog.DecisionRevision

    $review=Get-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId
    Check ($review.Kind -ceq 'AssistiveSoftwareDispositionReview' -and $review.Rows.Count -eq 4 -and $review.Coverage.Count -eq 2) 'Formal review did not expose every software row and coverage record.'
    Check ($review.Rows[0].DecisionState -ceq 'Unreviewed' -and $review.Rows[0].Disposition -ceq '') 'Unreviewed software was silently assigned an intent.'
    Check ($review.Rows[1].Scope -ceq 'User' -and $review.Rows[1].SID -ceq 'S-1-5-21-100-200-300-1001' -and $review.Rows[1].Architecture -ceq 'x86') 'User scope, SID, or architecture was omitted from the review.'
    Check ($review.Coverage[1].Status -ceq 'PermissionDenied' -and $review.TrustedSoftwareRoots.Status -ceq 'Partial') 'Coverage gaps or trusted-root uncertainty were hidden.'
    Check (@($review.Rows | Where-Object SpecialProduct).Count -eq 1 -and (@($review.Rows | Where-Object SpecialProduct)[0].AllowedDispositions -join ',') -ceq 'External,NotNeeded') 'Special product did not expose only externally handled choices.'

    $decisions=@(
        [pscustomobject]@{SoftwareId=('sw-'+('a'*32));Disposition='Unknown';Owner='app owner';Reason='Need vendor confirmation';Evidence='change:unknown'},
        [pscustomobject]@{SoftwareId=('sw-'+('b'*32));Disposition='External';Owner='user owner';Reason='Not part of selected workload';Evidence='change:unselected'},
        [pscustomobject]@{SoftwareId=('sw-'+('c'*32));Disposition='External';Owner='database owner';Reason='Owner handles database product';Evidence='change:database'},
        [pscustomobject]@{SoftwareId=('sw-'+('d'*32));Disposition='Portable';Owner='app owner';Reason='Owner describes deployment as portable';Evidence='change:portable'}
    )
    $submitted=Submit-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId -ExpectedRevision $review.DecisionRevision -ExpectedPreviewHash $review.PreviewHash -Ack -Decisions $decisions
    Check ($submitted.Status -ceq 'Applied' -and $submitted.DecisionRevision -gt $review.DecisionRevision -and $submitted.SubmittedCount -eq 4) 'Formal software disposition batch was not applied.'
    Check ($submitted.ReopenedReview.Rows.Count -eq 4 -and @($submitted.ReopenedReview.Rows | Where-Object {$_.Disposition -ceq 'Unknown'}).Count -eq 1 -and @($submitted.ReopenedReview.Rows | Where-Object {$_.Disposition -ceq 'External'}).Count -eq 2) 'Reopened review did not preserve explicit Unknown and unrelated software intent.'
    $reopened=Get-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId
    Check ($reopened.PreviewHash -ceq $submitted.ReopenedReview.PreviewHash -and $reopened.Rows.Count -eq 4) 'Persisted review could not be reopened with a stable current hash.'
    $unknownIssues=@(Get-WsmGeneralHostIssues (Get-WsmCatalog $workspace $catalog.PairId) ReviewComplete | Where-Object Issue -Like '*Software requires an allowed current owner disposition*')
    Check ($unknownIssues.Count -eq 1) 'Saving Unknown intent was incorrectly treated as ReviewComplete readiness.'

    $beforeUnselected=(Get-WsmCatalog $workspace $catalog.PairId).GeneralHost.SoftwareDecisions | Where-Object SoftwareId -CEQ ('sw-'+('b'*32))
    $partial=Submit-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId -ExpectedRevision $reopened.DecisionRevision -ExpectedPreviewHash $reopened.PreviewHash -Ack -Decisions @([pscustomobject]@{SoftwareId=('sw-'+('a'*32));Disposition='Reinstall';Owner='app owner';Reason='Install media required';Evidence='change:install'})
    $afterUnselected=(Get-WsmCatalog $workspace $catalog.PairId).GeneralHost.SoftwareDecisions | Where-Object SoftwareId -CEQ ('sw-'+('b'*32))
    Check ($beforeUnselected.Disposition -ceq 'External' -and $afterUnselected.Disposition -ceq 'External') 'Updating a partial batch discarded an unselected prior software decision.'
    $prepIssues=@(Get-WsmGeneralHostIssues (Get-WsmCatalog $workspace $catalog.PairId) PreparationReady)
    Check (@($prepIssues | Where-Object {$_.ConsumerItemId -ceq $consumer.ItemId -and $_.Issue -Like '*separate PreparationReady*'}).Count -eq 1 -and @($prepIssues | Where-Object {$_.ConsumerItemId -ceq $unselected.ItemId}).Count -eq 0) 'Only the selected workload dependency should require its separate preparation decision.'

    $stale=Get-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId
    $fresh=Submit-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId -ExpectedRevision $stale.DecisionRevision -ExpectedPreviewHash $stale.PreviewHash -Ack -Decisions @([pscustomobject]@{SoftwareId=('sw-'+('a'*32));Disposition='Unknown';Owner='app owner';Reason='Still unconfirmed';Evidence='change:pending'})
    Reject {Submit-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId -ExpectedRevision $stale.DecisionRevision -ExpectedPreviewHash $stale.PreviewHash -Ack -Decisions @([pscustomobject]@{SoftwareId=('sw-'+('a'*32));Disposition='External';Owner='app owner';Reason='stale';Evidence='change:stale'})} 'Stale preview hash/revision was accepted.'
    Reject {Submit-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId -ExpectedRevision $fresh.DecisionRevision -ExpectedPreviewHash $fresh.ReopenedReview.PreviewHash -Ack -Decisions @([pscustomobject]@{SoftwareId=('sw-'+('0'*32));Disposition='External';Owner='owner';Reason='unknown id';Evidence='change:unknown-id'})} 'Unknown SoftwareId was accepted.'
    Reject {Submit-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId -ExpectedRevision $fresh.DecisionRevision -ExpectedPreviewHash $fresh.ReopenedReview.PreviewHash -Ack -Decisions @([pscustomobject]@{SoftwareId=('sw-'+('c'*32));Disposition='Reinstall';Owner='owner';Reason='special bypass';Evidence='change:special'})} 'Special product accepted a reinstall choice.'
    Reject {Submit-WsmAssistiveSoftwareDispositionReview -Workspace $workspace -PairId $catalog.PairId -ExpectedRevision $fresh.DecisionRevision -ExpectedPreviewHash $fresh.ReopenedReview.PreviewHash -Ack -Decisions @([pscustomobject]@{SoftwareId=('sw-'+('b'*32));Disposition='External';Owner='owner';Reason='first';Evidence='change:duplicate'},[pscustomobject]@{SoftwareId=('sw-'+('b'*32));Disposition='NotNeeded';Owner='owner';Reason='second';Evidence='change:duplicate'})} 'Duplicate SoftwareId rows were accepted.'

    $current=Get-WsmCatalog $workspace $catalog.PairId
    $rootDetails=& $module {param($workspacePath,$pair) $currentCatalog=Get-WsmCatalog $workspacePath $pair;$projection=Get-WsmCatalogInventoryProjection $currentCatalog;$projection | Add-Member NoteProperty SoftwareCatalog $currentCatalog.GeneralHost.SoftwareCatalog;$roots=Get-WsmTrustedInstalledSoftwareRoots $projection;[pscustomobject]@{SourceInventory=$projection;Coverage=$roots}} $workspace $catalog.PairId
    $sourceProjection=$rootDetails.SourceInventory;$portableRoots=$rootDetails.Coverage
    Check (@($portableRoots.Roots | Where-Object {$_.Scope -ceq 'Portable' -and $_.Path -ceq 'D:\FixtureData\PortableApp'}).Count -eq 1) 'Portable user intent removed trusted portable-root evidence.'
    $spec=[pscustomobject]@{Adapter='FileScope';SourcePath='D:\FixtureData';TargetPath='E:\FixtureTarget';ContentSelection='WholeScope';ExcludedRelativePaths=@()}
    Reject {& $module {param($scope,$inventoryValue) Assert-WsmFileScopeInstalledRoots -Spec $scope -SourceInventory $inventoryValue} $spec $sourceProjection} 'Portable disposition bypassed the existing package-root protection.'

    Write-Output ('PASS Test-SoftwareDispositionReview: '+$script:passed+' formal review, CAS, batch preservation, dependency-gate and root-protection checks.')
} finally {
    $resolvedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    $resolvedRoot=[IO.Path]::GetFullPath($root)
    if(-not $resolvedRoot.StartsWith($resolvedTemp,[StringComparison]::OrdinalIgnoreCase) -or $resolvedRoot -eq $resolvedTemp.TrimEnd('\')){throw 'Refusing to clean a test directory outside the system temp root.'}
    if([IO.Directory]::Exists($resolvedRoot)){Remove-Item -LiteralPath $resolvedRoot -Recurse -Force}
}
