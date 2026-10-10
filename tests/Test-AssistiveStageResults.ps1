#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-assistive-stage-result-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$module=Get-Module WindowsServerMigration
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};Check $rejected $Message}
function SaveJson($Data,[string]$Path){[IO.File]::WriteAllText($Path,($Data|ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)));$Path}
function Get-TestCatalogPath([string]$Workspace,[string]$PairId){& $module {param($Workspace,$PairId) Get-WsmCatalogPath $Workspace $PairId} $Workspace $PairId}
function Get-TestLatest($Catalog){& $module {param($Catalog) Get-WsmLatestStageResult $Catalog} $Catalog}
function Test-TestCurrent($Catalog,$Result){& $module {param($Catalog,$Result) Test-WsmStageResultCurrent $Catalog $Result} $Catalog $Result}
try {
    $workspace=Join-Path $root 'manager';Initialize-WsmWorkspace $workspace | Out-Null
    $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='assistive-stage-source'}
    $item=New-WsmItem $source.HostId Runtime Application 'selected app' 'selected-app' @{Version='1.0'}
    $other=New-WsmItem $source.HostId Runtime Application 'excluded app' 'excluded-app' @{Version='2.0'}
    $inventory=New-WsmInventory $source 1 @($item,$other);$inventoryPath=Join-Path $root 'inventory.json';SaveJson $inventory $inventoryPath | Out-Null;$catalog=Import-WsmInventory $workspace $inventoryPath (Get-FileHash -LiteralPath $inventoryPath).Hash 'assistive-stage-target'
    $catalog=Enable-WsmAssistiveMode $workspace $catalog.PairId $catalog.DecisionRevision
    $catalog=Set-WsmDecision $workspace $catalog.PairId @($item.ItemId) Include 'reviewed selected app' $catalog.DecisionRevision
    $catalog=Set-WsmDecision $workspace $catalog.PairId @($other.ItemId) Exclude 'not in this migration' $catalog.DecisionRevision
    $catalog=Get-WsmCatalog $workspace $catalog.PairId
    $planHash='b'*64;$targetId=[Guid]::NewGuid().ToString();$targetFingerprint='c'*64;$manifest='d'*64;$generation=4
    $catalog.Approval=[pscustomobject]@{Kind='MigrationPlan';ApprovalId=[Guid]::NewGuid().ToString();Hash=$planHash;Utc=[DateTime]::UtcNow.ToString('o');TargetHostId=$targetId;TargetFingerprint=$targetFingerprint}
    SaveJson $catalog (Get-TestCatalogPath $workspace $catalog.PairId) | Out-Null
    function New-Result([string]$Status='Succeeded',[string]$ItemStatus='Succeeded',[string]$Version='0.4.0') {
        $applied=@();$pending=@();$deferred=@();$appliedHash='';$appliedGeneration=0;$isPending=$false;$isDeferred=$false
        if($ItemStatus -ceq 'Succeeded'){$applied=@($item.ItemId);$appliedHash=$manifest;$appliedGeneration=$generation}
        elseif($ItemStatus -ceq 'Failed'){$pending=@($item.ItemId);$isPending=$true}
        else{$deferred=@($item.ItemId);$isDeferred=$true}
        [pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$Version;Kind='StageResult';BatchId=$catalog.BatchId;PairId=$catalog.PairId;SourceHostId=$source.HostId;TargetHostId=$targetId;TargetFingerprint=$targetFingerprint;InventoryRevision=$catalog.InventoryRevision;DecisionRevision=$catalog.DecisionRevision;RunId=[Guid]::NewGuid().ToString();Sequence=1;Stage='Restore';Status=$Status;ProducedUtc=[DateTime]::UtcNow.ToString('o');Mode='IsolatedPilot';ProductionVerified=$false;ApprovalId=$catalog.Approval.ApprovalId;PlanHash=$planHash;ManifestHash=$manifest;PayloadGeneration=$generation;JournalHash=('e'*64);Assistive=[pscustomobject][ordered]@{ApprovedItemIds=@($item.ItemId);ItemResults=@([pscustomobject]@{ItemId=$item.ItemId;Decision='Include';Status=$ItemStatus;AppliedManifestHash=$appliedHash;AppliedGeneration=$appliedGeneration;Pending=$isPending;Deferred=$isDeferred});AppliedItemIds=$applied;PendingItemIds=$pending;DeferredItemIds=$deferred;FileResults=@()}}
    }
    function Submit($Result){$path=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.json');SaveJson $Result $path | Out-Null;Import-WsmStageResult $workspace $path (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
    function Reject-Unchanged($Result,[string]$Message){$before=(Get-FileHash -LiteralPath (Get-TestCatalogPath $workspace $catalog.PairId) -Algorithm SHA256).Hash;Reject {Submit $Result} $Message;Check ((Get-FileHash -LiteralPath (Get-TestCatalogPath $workspace $catalog.PairId) -Algorithm SHA256).Hash -ceq $before) 'Rejected Assistive result changed the catalog.'}
    $legacy=New-Result Succeeded Succeeded '0.3.0';Reject-Unchanged $legacy 'Schema 3 accepted a legacy tool result.'
    $oldInventory=New-Result Succeeded Succeeded '0.3.0';$oldInventory.Stage='Inventory';$oldInventory.PSObject.Properties.Remove('Assistive');Reject-Unchanged $oldInventory 'Schema 3 accepted a legacy inventory result.'
    $missing=New-Result Succeeded Succeeded;$missing.PSObject.Properties.Remove('Assistive');Reject-Unchanged $missing 'Schema 3 accepted a flat result without per-item state.'
    $badApproved=New-Result Succeeded Succeeded;$badApproved.Assistive.ApprovedItemIds=@($other.ItemId);Reject-Unchanged $badApproved 'Result approved item set differed from selected Include set.'
    $badStatus=New-Result Succeeded Succeeded;$badStatus.Assistive.ItemResults[0].Status='UnknownFutureState';Reject-Unchanged $badStatus 'Unknown Assistive item status was accepted.'
    $badGen=New-Result Succeeded Succeeded;$badGen.Assistive.ItemResults[0].AppliedGeneration=$generation-1;Reject-Unchanged $badGen 'Item success with stale generation was accepted.'
    $badManifest=New-Result Succeeded Succeeded;$badManifest.Assistive.ItemResults[0].AppliedManifestHash='f'*64;Reject-Unchanged $badManifest 'Item success with stale manifest was accepted.'
    $badDeferred=New-Result Succeeded DeferredSoftware;$badDeferred.Assistive.DeferredItemIds=@();Reject-Unchanged $badDeferred 'Deferred row missing from the explicit deferred set was accepted.'
    $missingFiles=New-Result Succeeded Succeeded;$missingFiles.Assistive.PSObject.Properties.Remove('FileResults');Reject-Unchanged $missingFiles 'Schema 3 result without complete file-result array was accepted.'
    $row=[pscustomobject][ordered]@{ItemId=$item.ItemId;EntryId='';RelativePath='app.dll';Channel='C';OriginalPath='C:\app.dll';PreservedPath='D:\app.dll';EffectivePath='D:\app.dll';Status='Applied';ExistingTargetPath='';ExistingTargetHash='';ObservedHash=('a'*64);SourceHash=('a'*64);Reason='';Generation=$generation;ProjectedGeneration=$generation}
    $badFile=New-Result Succeeded Succeeded;$badFile.Assistive.FileResults=@(($row | Select-Object *));$badFile.Assistive.FileResults[0].ItemId=$other.ItemId;Reject-Unchanged $badFile 'Per-file row outside the approved item set was accepted.'
    $staleFile=New-Result Succeeded Succeeded;$staleFile.Assistive.FileResults=@(($row | Select-Object *));$staleFile.Assistive.FileResults[0].ProjectedGeneration=$generation-1;Reject-Unchanged $staleFile 'Stale projected per-file generation was accepted.'
    $conflictPath=New-Result Succeeded Succeeded;$conflictPath.Assistive.FileResults=@(($row | Select-Object *));$conflictPath.Assistive.FileResults[0].Status='BlockedConflict';$conflictPath.Assistive.FileResults[0].ExistingTargetPath='D:\app.dll';Reject-Unchanged $conflictPath 'Conflicting per-file row with an effective path was accepted.'
    $badFileHash=New-Result Succeeded Succeeded;$badFileHash.Assistive.FileResults=@(($row | Select-Object *));$badFileHash.Assistive.FileResults[0].SourceHash='bad';Reject-Unchanged $badFileHash 'Malformed per-file hash was accepted.'
    $badRelative=New-Result Succeeded Succeeded;$badRelative.Assistive.FileResults=@(($row | Select-Object *));$badRelative.Assistive.FileResults[0].RelativePath='../outside.bin';Reject-Unchanged $badRelative 'Traversal per-file relative path was accepted.'
    $missingReadbackHash=New-Result Succeeded Succeeded;$missingReadbackHash.Assistive.FileResults=@(($row | Select-Object *));$missingReadbackHash.Assistive.FileResults[0].ObservedHash='';Reject-Unchanged $missingReadbackHash 'Applied per-file result without observed content hash was accepted.'
    $missingEffectivePath=New-Result Succeeded Succeeded;$missingEffectivePath.Assistive.FileResults=@(($row | Select-Object *));$missingEffectivePath.Assistive.FileResults[0].EffectivePath='';Reject-Unchanged $missingEffectivePath 'Applied per-file result without an effective target path was accepted.'
    $badFileSecret=New-Result Succeeded Succeeded;$badFileSecret.Assistive.FileResults=@(($row | Select-Object *));$badFileSecret.Assistive.FileResults[0].Reason='password=supersecret';Reject-Unchanged $badFileSecret 'Secret-like per-file reason was accepted.'
    $badD=New-Result Succeeded Succeeded;$badD.Assistive.FileResults=@(($row | Select-Object *));$badD.Assistive.FileResults[0].Channel='NonC';Reject-Unchanged $badD 'Non-C per-file row without exact EntryId was accepted.'
    $duplicateFiles=New-Result Succeeded Succeeded;$duplicateFiles.Assistive.FileResults=@(($row | Select-Object *),($row | Select-Object *));Reject-Unchanged $duplicateFiles 'Duplicate per-file rows were accepted.'
    $success=New-Result Succeeded Succeeded;Submit $success
    $current=Get-WsmCatalog $workspace $catalog.PairId;$latest=Get-TestLatest $current
    Check ($latest.ToolVersion -ceq '0.4.0' -and $latest.Assistive.AppliedItemIds -contains $item.ItemId) 'Current per-item Assistive result was not retained.'
    $deferred=New-Result Partial DeferredSoftware;$deferred.RunId=$latest.RunId;$deferred.Sequence=2;$deferred.ProducedUtc=[DateTime]::UtcNow.AddSeconds(1).ToString('o');Submit $deferred
    $current=Get-WsmCatalog $workspace $catalog.PairId;$latest=Get-TestLatest $current
    Check ($latest.Status -ceq 'Partial' -and $latest.Assistive.DeferredItemIds -contains $item.ItemId -and (Test-TestCurrent $current $latest)) 'Deferred item state did not remain visible/current in the manager catalog.'
    Write-Host ('PASS: '+$passed+' Assistive stage-result binding checks.')
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
