#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$testModule=Get-Module WindowsServerMigration
function Assert-WsmEnvelope($Data,[string]$Kind){& $testModule {param($Data,$Kind) Assert-WsmEnvelope $Data $Kind} $Data $Kind}
function Read-WsmJson([string]$Path){& $testModule {param($Path) Read-WsmJson $Path} $Path}
function Assert-WsmAssistiveTargetDecisionReceipt($Receipt){& $testModule {param($Receipt) Assert-WsmAssistiveTargetDecisionReceipt $Receipt} $Receipt}
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-assistive-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};Check $rejected $Message}
function SaveJson($Data,[string]$Name){$path=Join-Path $root $Name;[IO.File]::WriteAllText($path,($Data|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)));$path}
try {
    $workspace=Join-Path $root 'manager';Initialize-WsmWorkspace $workspace | Out-Null
    $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='assistive-source'}
    $item1=New-WsmItem $source.HostId Runtime App 'Fixture runtime' 'fixture-runtime' @{Version='1.0'}
    $item2=New-WsmItem $source.HostId Services Service 'Fixture service' 'fixture-service' @{Path='C:\Fixture\svc.exe'}
    $inventory=New-WsmInventory $source 1 @($item1,$item2);$inventoryPath=SaveJson $inventory 'inventory-1.json';$inventoryHash=(Get-FileHash $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=Import-WsmInventory $workspace $inventoryPath $inventoryHash 'assistive-target'
    Check ($catalog.SchemaVersion -lt 3) 'Assistive contract was enabled without explicit opt-in.'
    $snapshot=Join-Path $workspace ('assistive\snapshots\'+$inventoryHash+'.json')
    Check ((Get-FileHash $snapshot -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $inventoryHash) 'Trusted source snapshot was not saved byte-for-byte.'
    $catalog=Enable-WsmAssistiveMode $workspace $catalog.PairId $catalog.DecisionRevision
    Check ($catalog.SchemaVersion -eq 3 -and $catalog.Assistive.ContractVersion -eq 1) 'Explicit Assistive promotion failed.'
    Reject { Enable-WsmAssistiveMode $workspace $catalog.PairId 0 } 'Stale Assistive activation CAS was accepted.'
    Check (@($catalog.Assistive.Selections.Items | Where-Object {-not $_.Selected}).Count -eq 0) 'New discoveries were not selected by default.'
    Check (($catalog.Items | Where-Object ItemId -EQ $item1.ItemId).Decision -eq 'Pending') 'Selection was coupled to the review Decision.'
    $selected=Set-WsmAssistiveSelections $workspace $catalog.PairId $catalog.Assistive.Revision @($item1.ItemId) $false 'owner deferred this item'
    Reject { Set-WsmAssistiveSelections $workspace $catalog.PairId 1 @($item2.ItemId) $false 'stale CAS' } 'Stale Assistive revision was accepted.'
    $tampered=Get-WsmCatalog $workspace $catalog.PairId;$tampered.Assistive.Selections.Items[0].Selected='yes'
    Reject { Assert-WsmAssistiveContract $tampered Catalog } 'Malformed selection type was accepted.'
    $item3=New-WsmItem $source.HostId Tasks ScheduledTask 'Fixture task' '\Fixture\Task' @{Enabled=$false}
    $inventory2=New-WsmInventory $source 2 @($item1,$item2,$item3);$inventoryPath2=SaveJson $inventory2 'inventory-2.json';$inventoryHash2=(Get-FileHash $inventoryPath2 -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog2=Import-WsmInventory $workspace $inventoryPath2 $inventoryHash2
    Check ($catalog2.SchemaVersion -eq 3) 'Reinventory dropped Assistive schema.'
    Check (-not ($catalog2.Assistive.Selections.Items | Where-Object ItemId -EQ $item1.ItemId).Selected) 'Reinventory lost an existing deselection.'
    Check (($catalog2.Assistive.Selections.Items | Where-Object ItemId -EQ $item3.ItemId).Selected) 'A newly discovered item did not default to selected.'
    Check ($null -eq $catalog2.Assistive.Comparison) 'Reinventory kept a comparison bound to stale source facts.'
    $stale=Get-WsmCatalog $workspace $catalog.PairId;$stale.Assistive.Selections.Items[0].SourceRevision=1
    Reject {Assert-WsmAssistiveContract $stale Catalog} 'Stale selection source revision was accepted.'
    $missing=Get-WsmCatalog $workspace $catalog.PairId;$missing.Assistive.SourceSnapshot=$null
    Reject {Assert-WsmAssistiveContract $missing Catalog} 'Missing source snapshot was accepted.'
    $plan=[pscustomobject][ordered]@{SchemaVersion=3;ToolVersion='0.4.0';Kind='MigrationPlan';PairId=$catalog2.PairId;InventoryHash=$inventoryHash2;InventoryRevision=[int]$catalog2.InventoryRevision;Items=@([pscustomobject]@{ItemId=$item2.ItemId});Assistive=[pscustomobject][ordered]@{ContractVersion=1;PairId=$catalog2.PairId;SourceSnapshotHash=$inventoryHash2;SourcePolicy='SourceCOnly';SourceSelectionsVersion=[int]$catalog2.Assistive.Selections.Revision;ApprovedItemIds=@($item2.ItemId);MaterialReferences=@();DiscoveryAuthority=[pscustomobject][ordered]@{SourceSnapshotReference=$catalog2.Assistive.SourceSnapshot;InventoryRevision=[int]$catalog2.InventoryRevision;SelectionRevision=[int]$catalog2.Assistive.Selections.Revision;Dispositions=@([pscustomobject]@{ItemId=$item1.ItemId;Selected=$false;Decision='Pending';Reason=''},[pscustomobject]@{ItemId=$item2.ItemId;Selected=$true;Decision='Include';Reason='approved'})}}}
    Assert-WsmEnvelope $plan MigrationPlan
    Reject { $oldReader=$plan.PSObject.Copy();$oldReader.ToolVersion='0.3.0';Assert-WsmEnvelope $oldReader MigrationPlan } 'Legacy tool version accepted schema 3.'
    Reject { $bad=ConvertFrom-Json ($plan|ConvertTo-Json -Depth 30);$bad.Assistive.ApprovedItemIds=@($item1.ItemId);Assert-WsmAssistiveContract $bad MigrationPlan } 'Sealed plan accepted an item outside its plan subset.'
    $planPath=SaveJson $plan 'assistive-plan.json';$planHash=(Get-FileHash $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt=New-WsmAssistiveTargetDecisionReceipt -PlanPath $planPath -PlanHash $planHash -ManifestHash ('b'*64) -Generation 2 -TargetSnapshotHash ('c'*64) -ComparisonRevision 1 -SelectionRevision $plan.Assistive.SourceSelectionsVersion -Decision RestoreNow -Owner 'fixture owner' -Reason 'target reviewed' -SelectedItemIds @($item2.ItemId) -AcceptedUnpreparedItemIds @($item2.ItemId)
    Check ((Assert-WsmAssistiveTargetDecisionReceipt $receipt) -eq $true) 'Target decision receipt did not validate.'
    $receiptPath=SaveJson $receipt 'target-decision-receipt.json';Check ((Assert-WsmAssistiveTargetDecisionReceipt (Read-WsmJson $receiptPath)) -eq $true) 'Target decision receipt did not survive JSON roundtrip.'
    $receipt.SelectedItemIds=@($item1.ItemId)
    Reject { Assert-WsmAssistiveTargetDecisionReceipt $receipt } 'Tampered target receipt was accepted.'
    $statusPath=SaveJson ([pscustomobject]@{Kind='StageResult';Status='DeferredSoftware'}) 'deferred-result.json';$roundtripStatus=Read-WsmJson $statusPath
    Check ((Get-WsmOperationStatusCode $roundtripStatus) -eq 2) 'DeferredSoftware status roundtrip was reported as success.'
    Check ((Get-WsmOperationStatusCode ([pscustomobject]@{Status='WaitForInstall'})) -eq 2) 'WaitForInstall was reported as success.'
    Check ((Get-WsmOperationStatusCode ([pscustomobject]@{Status='BlockedConflict'})) -eq 2) 'BlockedConflict was reported as success.'
    Check ((Get-WsmOperationStatusCode ([pscustomobject]@{Status='NotARealStatus'})) -eq 2) 'Unknown nonempty status was reported as success.'
    Check ((Get-WsmOperationStatusCode ([pscustomobject]@{Status='Failed'})) -eq 1) 'Failed status did not map to exit code 1.'
    Check ((Get-WsmOperationStatusCode ([pscustomobject]@{Status='FAIL'})) -eq 1) 'Failure status did not map to exit code 1.'
    Check ((Get-WsmOperationStatusCode ([pscustomobject]@{Status='Cancelled'})) -eq 3) 'Cancelled status did not map to exit code 3.'
    $legacyWorkspace=Join-Path $root 'legacy-manager';Initialize-WsmWorkspace $legacyWorkspace | Out-Null
    $legacy=Import-WsmInventory $legacyWorkspace $inventoryPath $inventoryHash 'legacy-target';$legacy.Approval=[pscustomobject]@{ApprovalId='legacy-approved'}
    $legacyPath=Join-Path (Join-Path $legacyWorkspace 'pairs') ($legacy.PairId+'.json');[IO.File]::WriteAllText($legacyPath,($legacy|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
    Reject { Enable-WsmAssistiveMode $legacyWorkspace $legacy.PairId $legacy.DecisionRevision } 'Approved legacy catalog was silently promoted.'
    Write-Host ('PASS: '+$passed+' Assistive contract checks.')
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
