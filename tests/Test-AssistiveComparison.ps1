#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$comparisonSource=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\AssistiveComparison.ps1'))
& $module {param($path) . $path;foreach($function in @(Get-Command -CommandType Function | Where-Object {$_.Name -match '^(Clear|Get|Update|Set|New)-WsmAssistive'})){Set-Item -Path ('Function:\script:'+ $function.Name) -Value $function.ScriptBlock}} $comparisonSource
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-assistive-e1-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};Check $rejected $Message}
function SaveJson($Data,[string]$Name){$path=Join-Path $root $Name;[IO.File]::WriteAllText($path,($Data|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)));$path}
function NewSoftwareCatalog($Inventory,$Entries,$Coverage){
    & $module {
        param($inventory,$entries,$coverage)
        $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$inventory.Source.HostId;Fingerprint=$inventory.Source.Fingerprint;Name=$inventory.Source.Name;InventoryRevision=[int]$inventory.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='fixture';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@($entries);Coverage=@($coverage);PreparationRequirements=@(foreach($entry in $entries){[pscustomobject]@{PreparationId=('prep-'+$entry.SoftwareId.Substring(3));SoftwareId=$entry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus=$entry.CaptureStatus;ConsumerItemIds=@($entry.ItemIds);Owner='';Reason='Fixture evidence only.'}});CatalogProjectionHash=('0'*64)}
        $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
        Assert-WsmSoftwareCatalog $catalog -SourceInventory $inventory | Out-Null
        $catalog
    } $Inventory $Entries $Coverage
}
function NewSoftwareEntry([string]$Id,[string]$Name,[string]$Version,[string]$Publisher='Vendor'){
    [pscustomobject][ordered]@{SoftwareId=('sw-'+$Id.PadLeft(32,'0'));Name=$Name;Version=$Version;Publisher=$Publisher;Architecture='Unknown';Scope='Machine';SID='';RegistryView='';Location='fixture:'+ $Name;SourceKind='Registry';Evidence=[pscustomobject]@{Probe='Uninstall'};ObservedUtc='2026-10-10T00:00:00Z';CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'}
}
function NewCoverage([string]$Status='Success'){
    ,@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status=$Status;EvidenceKind='Registry';Count=1;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$(if($Status -eq 'Success'){$null}else{'FixtureCoverageGap'});ObservedUtc='2026-10-10T00:00:00Z'})
}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()) { & $script:module $Block @Arguments }
try {
    $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source'}
    $item1=CallModule {param($host) New-WsmItem $host Runtime App 'Selected later' 'selected-later' @{Version='1'}} @($source.HostId)
    $item2=CallModule {param($host) New-WsmItem $host Services Service 'Independent workload' 'independent-workload' @{Path='C:\fixture\svc.exe'}} @($source.HostId)
    $sourceInventory=CallModule {param($source,$items) New-WsmInventory $source 1 $items} @($source,@($item1,$item2))
    $sourceRows=@((NewSoftwareEntry '1' 'Fixture Server App' '1.0' 'Acme'),(NewSoftwareEntry '2' 'Microsoft Runtime Name' '8.0' ''))
    $sourceInventory | Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $sourceInventory $sourceRows (NewCoverage))
    $sourcePath=SaveJson $sourceInventory 'source.json';$sourceHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $workspace=Join-Path $root 'manager';CallModule {param($path) Initialize-WsmWorkspace $path | Out-Null} @($workspace)
    $catalog=CallModule {param($w,$p,$h) Import-WsmInventory $w $p $h 'target'} @($workspace,$sourcePath,$sourceHash)
    $catalog=CallModule {param($w,$pair,$revision) Enable-WsmAssistiveMode $w $pair $revision} @($workspace,$catalog.PairId,$catalog.DecisionRevision)
    Check ($catalog.Assistive.Selections.Items.Count -eq 2 -and @($catalog.Assistive.Selections.Items|Where-Object {-not $_.Selected}).Count -eq 0) 'All discovered items should default selected independently of Decision.'

    $catalog=CallModule {param($w,$pair,$revision,$ids) Set-WsmAssistiveSelections $w $pair $revision $ids $false 'independent fixture is not migrating'} @($workspace,$catalog.PairId,$catalog.Assistive.Revision,@($item1.ItemId))
    $catalog=CallModule {param($w,$pair,$ids,$revision) Set-WsmDecision -Workspace $w -PairId $pair -ItemId $ids -Decision Include -Reason 'approved independent workload' -ExpectedRevision $revision} @($workspace,$catalog.PairId,@($item2.ItemId),$catalog.DecisionRevision)
    $spec=[pscustomobject][ordered]@{Adapter='ManualWorkflow';Product='Fixture manual workload';Procedure='Owner prepares and verifies the workload';Artifacts=@();BusinessChecks=@();Owner='fixture owner';Evidence='fixture evidence'}
    $specPath=SaveJson $spec 'manual-spec.json';$specHash=(Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash.ToLowerInvariant()
    CallModule {param($w,$pair,$id,$path,$hash,$revision) Set-WsmMigrationSpec $w $pair $id $path $hash $revision} @($workspace,$catalog.PairId,$item2.ItemId,$specPath,$specHash,$catalog.DecisionRevision) | Out-Null
    $catalog=CallModule {param($w,$pair) Get-WsmCatalog $w $pair} @($workspace,$catalog.PairId)
    $reviewIssues=@(CallModule {param($w,$pair) Get-WsmReviewIssues $w $pair} @($workspace,$catalog.PairId) | Where-Object Gate -EQ ReviewComplete)
    Check (@($reviewIssues | Where-Object ItemId -EQ $item1.ItemId).Count -eq 0) 'Unselected Pending item incorrectly blocked review.'
    Check (@($reviewIssues | Where-Object ItemId -EQ $item2.ItemId).Count -eq 0) 'Selected included item with complete spec should pass review.'

    $target=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('b'*64);Name='fixture-target'}
    $targetInventory=CallModule {param($source) New-WsmInventory $source 1 @()} @($target)
    $targetRows=@((NewSoftwareEntry '3' 'Fixture Server App' '2.0' 'Acme'))
    $targetInventory | Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $targetInventory $targetRows (NewCoverage))
    $targetPath=SaveJson $targetInventory 'target-1.json';$targetHash=(Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $catalog=CallModule {param($w,$pair,$path,$hash,$revision) Update-WsmAssistiveTargetSnapshot $w $pair $path $hash $revision} @($workspace,$catalog.PairId,$targetPath,$targetHash,$catalog.Assistive.Revision)
    Check ($catalog.Assistive.TargetBaseline.BaselineKind -ceq 'FirstObserved') 'Initial target inventory was not labeled FirstObserved.'
    Reject {CallModule {param($w,$pair,$path,$hash,$revision) Update-WsmAssistiveTargetSnapshot $w $pair $path $hash $revision} @($workspace,$catalog.PairId,$targetPath,$targetHash,1)} 'Stale target snapshot CAS was accepted.'
    $microsoft=NewSoftwareEntry '2' 'Microsoft Runtime Name' '8.0' ''
    $catalog=CallModule {param($w,$pair,$id,$version,$revision) Set-WsmAssistiveSoftwareVersion $w $pair $id $version $revision 'product owner selected supported release'} @($workspace,$catalog.PairId,$sourceRows[0].SoftwareId,'3.0',$catalog.Assistive.Revision)
    $comparisonInputRevision=$catalog.Assistive.Revision
    $comparison=CallModule {param($w,$pair) Get-WsmAssistiveComparison $w $pair} @($workspace,$catalog.PairId)
    $versionRow=@($comparison.Rows | Where-Object SoftwareId -CEQ $sourceRows[0].SoftwareId)
    Check ($versionRow.Count -eq 1 -and $versionRow[0].SourceVersion -eq '1.0' -and $versionRow[0].ChosenVersion -eq '3.0' -and $versionRow[0].ObservedTargetVersion -eq '2.0' -and $versionRow[0].Status -eq 'DifferentFromChosenVersion') 'Source, chosen, and observed versions were not kept distinct.'
    $microsoftRow=@($comparison.Rows | Where-Object SoftwareId -CEQ $microsoft.SoftwareId)
    Check ($microsoftRow.Count -eq 1 -and $microsoftRow[0].Status -eq 'TargetMissing') 'Publisher/name prefix was incorrectly treated as proof that the Microsoft software matched.'
    Check ($comparison.VersionDisclaimer -match 'not compatibility evidence') 'Comparison omitted its compatibility disclaimer.'
    Check (@($comparison.ManualPreparation | Where-Object SoftwareId -CEQ $sourceRows[0].SoftwareId).Count -eq 1) 'Version mismatch did not produce an owner preparation action.'
    $stored=CallModule {param($w,$pair) Get-WsmCatalog $w $pair} @($workspace,$catalog.PairId)
    Check ($null -eq $stored.Assistive.Comparison -and $stored.Assistive.Revision -eq $comparisonInputRevision) 'A comparison query mutated catalog state.'
    $published=CallModule {param($w,$pair,$revision) Update-WsmAssistiveComparison $w $pair $revision} @($workspace,$catalog.PairId,$comparisonInputRevision)
    Check ($published.Revision -eq $comparison.Revision) 'Explicit comparison publication did not preserve its monotonic revision.'
    Reject {CallModule {param($w,$pair,$revision) Update-WsmAssistiveComparison $w $pair $revision} @($workspace,$catalog.PairId,$comparisonInputRevision)} 'Stale comparison publication CAS was accepted.'
    $stored=CallModule {param($w,$pair) Get-WsmCatalog $w $pair} @($workspace,$catalog.PairId)
    Check ($stored.Assistive.Comparison.Revision -eq $published.Revision) 'Explicit comparison publication was not durably committed.'
    Check ($stored.Assistive.SoftwareChoices[0].SoftwareId -eq $sourceRows[0].SoftwareId) 'Chosen software identity or durable catalog update was lost.'

    $target2=CallModule {param($source) New-WsmInventory $source 2 @()} @($target)
    $target2Rows=@((NewSoftwareEntry '4' 'Fixture Server App' '3.0' 'Acme'))
    $target2 | Add-Member NoteProperty SoftwareCatalog (NewSoftwareCatalog $target2 $target2Rows (NewCoverage 'NotTested'))
    $target2Path=SaveJson $target2 'target-2.json';$target2Hash=(Get-FileHash -LiteralPath $target2Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $stored=CallModule {param($w,$pair) Get-WsmCatalog $w $pair} @($workspace,$catalog.PairId)
    $stored=CallModule {param($w,$pair,$path,$hash,$revision) Update-WsmAssistiveTargetSnapshot $w $pair $path $hash $revision} @($workspace,$catalog.PairId,$target2Path,$target2Hash,$stored.Assistive.Revision)
    $comparison2=CallModule {param($w,$pair) Get-WsmAssistiveComparison $w $pair} @($workspace,$catalog.PairId)
    $unknownRow=@($comparison2.Rows | Where-Object SoftwareId -CEQ $microsoft.SoftwareId); Check ($unknownRow.Count -eq 1 -and $unknownRow[0].Status -eq 'TargetUnknown') 'Incomplete target coverage produced a false missing conclusion.'
    Check ($stored.Assistive.TargetBaseline.SHA256 -eq $targetHash -and $stored.Assistive.TargetCurrent.SHA256 -eq $target2Hash) 'Target baseline was overwritten instead of retaining the first observed snapshot.'

    $badFileScope=[pscustomobject]@{Adapter='FileScope';TransferChannel='Unknown';ContentSelection='ExactFiles';ConfigFiles=@();SourcePath='C:\data';TargetPath='D:\data';ExcludedRelativePaths=@();Consistency='Immutable';Metadata='DaclOwner';ConflictPolicy='Block';Owner='owner';Evidence='evidence'}
    Reject {CallModule {param($spec) Assert-WsmAssistiveMigrationSpec $spec} @($badFileScope)} 'Malformed schema 3 FileScope transfer/content selection was accepted.'
    $badXml=[pscustomobject]@{Adapter='ScheduledTask';Desired=[pscustomobject]@{Xml='<!DOCTYPE x [<!ENTITY e SYSTEM "file:///secret">]><Task>&e;</Task>'};SourceXml='<Task/>';SourceAutoStart='Unknown';StagedDisabled=$true;DesiredFinalState='Disabled';Owner='owner';Evidence='evidence'}
    Reject {CallModule {param($spec) Assert-WsmAssistiveMigrationSpec $spec} @($badXml)} 'DTD/entity-bearing workload XML was accepted.'
    $iisConfig=[pscustomobject]@{Adapter='IISSection';Desired=[pscustomobject]@{SectionPath='system.webServer/security/access';LocationPath='';Xml='<access sslFlags="Sni" enabled="false" />';Changes=@([pscustomobject]@{FieldPointer='/access/@sslFlags';Operation='SetAttribute';ElementName='access';KeyAttributes=@();AttributeName='sslFlags';BeforeValue='None';AfterValue='Sni'})};SourceXml='<access sslFlags="None" enabled="false" />';SourceAutoStart='false';StagedDisabled=$true;DesiredFinalState='Disabled';ActivationPolicyFieldPointer='/access/@enabled';ReviewedActivation=[pscustomobject]@{FinalState='Disabled';Owner='owner';Reason='The reviewed target field remains disabled during preparation.';SourceAutoStart='false';FieldPointer='/access/@enabled';StagedValue='false';FinalValue='false'};Owner='owner';Evidence='owner reviewed exact IIS section change'}
    CallModule {param($spec) Assert-WsmAssistiveMigrationSpec $spec} @($iisConfig)
    $badIisConfig=$iisConfig.PSObject.Copy();$badIisConfig.Desired=$iisConfig.Desired.PSObject.Copy();$badIisConfig.Desired.Changes=@([pscustomobject]@{FieldPointer="/access/*/sslFlags";Operation='SetAttribute';ElementName='access';KeyAttributes=@();AttributeName='sslFlags';BeforeValue='None';AfterValue='Sni'})
    Reject {CallModule {param($spec) Assert-WsmAssistiveMigrationSpec $spec} @($badIisConfig)} 'Wildcard IIS config pointer was accepted.'
    $activeIisConfig=$iisConfig.PSObject.Copy();$activeIisConfig.Desired=$iisConfig.Desired.PSObject.Copy();$activeIisConfig.Desired.Changes=@([pscustomobject]@{FieldPointer='/access/@enabled';Operation='SetAttribute';ElementName='access';KeyAttributes=@();AttributeName='enabled';BeforeValue='false';AfterValue='true'})
    Reject {CallModule {param($spec) Assert-WsmAssistiveMigrationSpec $spec} @($activeIisConfig)} 'IIS staging change that enables a section was accepted.'

    $targetIdentity=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='TargetIdentity';HostId=$target.HostId;Fingerprint=$target.Fingerprint;Name=$target.Name;OS='Windows Server';Version='2025';CreatedUtc='2026-10-10T00:00:00Z'}
    $identityPath=SaveJson $targetIdentity 'target-identity.json';$identityHash=(Get-FileHash $identityPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $stored=CallModule {param($w,$pair) Get-WsmCatalog $w $pair} @($workspace,$catalog.PairId)
    $planPath=Join-Path $root 'approved-plan.json'
    $approval=CallModule {param($w,$pair,$idPath,$idHash,$plan,$revision) Approve-WsmMigrationPlan -Workspace $w -PairId $pair -TargetIdentityPath $idPath -TargetIdentityHash $idHash -Path $plan -ExpectedRevision $revision -PilotAcknowledgement 'ISOLATED-PILOT'} @($workspace,$stored.PairId,$identityPath,$identityHash,$planPath,$stored.DecisionRevision)
    $plan=CallModule {param($path,$hash) Read-WsmMigrationPlan $path $hash} @($approval.Path,$approval.SHA256)
    Check ($plan.SchemaVersion -eq 3 -and $plan.Items.Count -eq 1 -and $plan.Items[0].ItemId -eq $item2.ItemId -and $plan.Items[0].Decision -eq 'Include') 'Sealed schema 3 plan did not contain exactly the selected approved Include subset.'
    $authorityRows=@($plan.Assistive.DiscoveryAuthority.Dispositions | Where-Object ItemId -EQ $item1.ItemId)
    Check ($authorityRows.Count -eq 1 -and -not $authorityRows[0].Selected -and $authorityRows[0].Decision -eq 'Pending') 'Sealed plan lost the true unselected Pending discovery disposition.'
    $beforeChoice=CallModule {param($w,$pair) Get-WsmCatalog $w $pair} @($workspace,$stored.PairId)
    $sealedHash=(Get-FileHash -LiteralPath $approval.Path).Hash
    $afterChoice=CallModule {param($w,$pair,$software,$revision) Set-WsmAssistiveSoftwareVersion -Workspace $w -PairId $pair -SoftwareId $software -ChosenVersion '4.0' -Reason 'Owner chose a newer target after packaging' -ExpectedRevision $revision} @($workspace,$stored.PairId,$sourceRows[0].SoftwareId,$beforeChoice.Assistive.Revision)
    Check ($afterChoice.Approval.Hash -ceq $beforeChoice.Approval.Hash -and $afterChoice.DecisionRevision -eq $beforeChoice.DecisionRevision -and (Get-FileHash -LiteralPath $approval.Path).Hash -ceq $sealedHash) 'Target version choice changed the sealed source plan or forced payload reapproval.'
    Check ($afterChoice.Assistive.Revision -gt $beforeChoice.Assistive.Revision -and -not $afterChoice.Assistive.Comparison) 'Target version choice did not invalidate its target comparison/preview.'
    $afterSubset=CallModule {param($w,$pair,$rev,$id) Set-WsmAssistiveSelections -Workspace $w -PairId $pair -ExpectedRevision $rev -ItemIds @($id) -Selected $false -Reason 'Owner deferred this target item'} @($workspace,$stored.PairId,$afterChoice.Assistive.Revision,$item2.ItemId)
    Check ($afterSubset.Approval.Hash -ceq $beforeChoice.Approval.Hash -and $afterSubset.DecisionRevision -eq $beforeChoice.DecisionRevision -and $afterSubset.Assistive.Selections.Revision -eq $plan.Assistive.SourceSelectionsVersion -and $afterSubset.Assistive.Selections.Items.Where({$_.ItemId -eq $item2.ItemId})[0].Selected) 'Target subset mutated sealed source selection or approval.'
    Check (-not (CallModule {param($c) (Get-WsmAssistiveCurrentSelections $c).Items | Where-Object ItemId -EQ $c.Items[1].ItemId} @($afterSubset)).Selected) 'Target subset was not persisted independently.'
    Reject {CallModule {param($w,$pair,$rev,$id) Set-WsmAssistiveSelections -Workspace $w -PairId $pair -ExpectedRevision $rev -ItemIds @($id) -Selected $true} @($workspace,$stored.PairId,$afterSubset.Assistive.Revision,$item1.ItemId)} 'Target selected an item outside the sealed approval.'

    $receipt=CallModule {param($path,$planHash,$comparison,$selection,$selected) New-WsmAssistiveTargetDecisionReceipt -PlanPath $path -PlanHash $planHash -ManifestHash ('c'*64) -Generation 1 -TargetSnapshotHash $comparison.TargetSnapshotHash -ComparisonRevision $comparison.Revision -SelectionRevision $selection -Decision RestoreNow -Owner 'fixture owner' -Reason 'target receipt hash binding regression' -SelectedItemIds @($selected) -Comparison $comparison} @($approval.Path,$approval.SHA256,$published,$plan.Assistive.SourceSelectionsVersion,$item2.ItemId)
    $receipt.ComparisonHash='0'*64
    $receipt.SHA256=CallModule {param($value) $body=[ordered]@{};foreach($property in $value.PSObject.Properties){if($property.Name -cne 'SHA256'){$body[$property.Name]=$property.Value}};Get-WsmHashText ($body | ConvertTo-Json -Depth 20 -Compress)} @($receipt)
    Reject {CallModule {param($value) Assert-WsmAssistiveTargetDecisionReceipt $value} @($receipt)} 'Target decision receipt accepted an embedded comparison hash mismatch despite a recomputed receipt envelope hash.'

    $manual=CallModule {param($w,$pair,$revision) Add-WsmManualItem -Workspace $w -PairId $pair -Category 'Runtime' -Name 'Manual after sealed target choices' -NaturalKey 'manual-after-target-choice' -Owner 'fixture owner' -Evidence 'fixture evidence' -ExpectedRevision $revision} @($workspace,$catalog.PairId,$afterSubset.DecisionRevision)
    $afterManual=CallModule {param($w,$pair) Get-WsmCatalog $w $pair} @($workspace,$catalog.PairId)
    Check ($null -eq $afterManual.Approval -and -not $afterManual.Assistive.PSObject.Properties['TargetSelections'] -and $afterManual.Assistive.Selections.Revision -gt $afterSubset.Assistive.Selections.Revision) 'Adding a manual discovery after sealed target selection retained the sealed target subset.'
    Check (@($afterManual.Assistive.Selections.Items | Where-Object ItemId -CEQ $manual.ItemId).Count -eq 1) 'Adding a manual discovery did not append its source selection row.'
    CallModule {param($value) Assert-WsmAssistiveContract $value Catalog} @($afterManual) | Out-Null
    Write-Host ('PASS: '+$passed+' Assistive S/E1 contract checks.')
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
