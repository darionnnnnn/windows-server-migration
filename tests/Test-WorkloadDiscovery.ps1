#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-workload-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$workspace=Join-Path $root 'manager';Initialize-WsmWorkspace $workspace | Out-Null
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function SaveJson($Data,[string]$Path){[IO.File]::WriteAllText($Path,($Data | ConvertTo-Json -Depth 60),(New-Object Text.UTF8Encoding($false)))}
$hostId=[Guid]::NewGuid().ToString();$source=[pscustomobject]@{HostId=$hostId;Fingerprint=('f'*64);Name='fixture-source';OS='Fixture';Version='Fixture'}
$siteA=New-WsmItem $hostId Web IISSite 'Web A' 'WebA' @{Xml='<site name="WebA" serverAutoStart="true"><application path="/"><virtualDirectory path="/" physicalPath="D:\Sites\Root"/><virtualDirectory path="/admin" physicalPath="D:\Sites\Admin"/></application><application path="/api" applicationPool="SharedPool"><virtualDirectory path="/" physicalPath="D:\Sites\Api"/></application></site>';StartupConfiguration=[pscustomobject]@{ServerAutoStart='true'};ObservedRuntime=[pscustomobject]@{State='Stopped';Evidence='fixture observed'}}
$siteB=New-WsmItem $hostId Web IISSite 'Web B' 'WebB' @{Xml='<site name="WebB"><application path="/"><virtualDirectory path="/" physicalPath="D:\Sites\Sub"/></application><application path="/api" applicationPool="SharedPool"><virtualDirectory path="/" physicalPath="D:\Sites\Api"/></application></site>'}
$pool=New-WsmItem $hostId Web IISPool 'SharedPool' 'SharedPool' @{Xml='<add name="SharedPool" autoStart="true" />'}
$taskXml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal id="Author"><UserId>DOMAIN\svc</UserId></Principal></Principals><Settings><Enabled>true</Enabled></Settings><Actions Context="Author"><Exec><Command>D:\Jobs\One.exe</Command><Arguments>--token VERYSECRET</Arguments><WorkingDirectory>D:\Jobs</WorkingDirectory></Exec><Exec><Command>D:\Jobs\Two.exe</Command><Arguments>--flag 2</Arguments><WorkingDirectory>D:\Jobs</WorkingDirectory></Exec></Actions></Task>'
$task=New-WsmItem $hostId Tasks ScheduledTask 'Job' '\Custom\' @{TaskName='Job';TaskPath='\Custom\';Xml=$taskXml;ObservedRuntime=[pscustomobject]@{State='Ready';Evidence='fixture Get-ScheduledTaskInfo result'};TaskSecurityCaptureStatus='Captured'}
$task | Add-Member NoteProperty ProducerProvenance 'Unknown' -Force
$folders=New-WsmItem $hostId Tasks TaskFolder '\Custom\' '\Custom\' @{SecuritySddl='O:BAG:BAD:';SecurityCaptureStatus='Captured'}
$pathItems=@(
    (New-WsmItem $hostId Storage PathCandidate 'D:\Sites\Root' 'root' @{OriginalPath='D:\Sites\Root';ResolvedCandidate='D:\Sites\Root'} @() Unsupported),
    (New-WsmItem $hostId Storage PathCandidate 'D:\Sites\Admin' 'admin' @{OriginalPath='D:\Sites\Admin';ResolvedCandidate='D:\Sites\Admin'} @() Unsupported),
    (New-WsmItem $hostId Storage PathCandidate 'D:\Sites\Api' 'api' @{OriginalPath='D:\Sites\Api';ResolvedCandidate='D:\Sites\Api'} @() Unsupported),
    (New-WsmItem $hostId Storage PathCandidate 'D:\Sites\Sub' 'sub-a' @{OriginalPath='D:\Sites\Sub';ResolvedCandidate='D:\Sites\Sub'} @() Unsupported),
    (New-WsmItem $hostId Storage PathCandidate 'D:\Sites\Sub' 'sub-b' @{OriginalPath='D:\Sites\Sub';ResolvedCandidate='D:\Sites\Sub'} @() Unsupported),
    (New-WsmItem $hostId Storage PathCandidate 'D:\Jobs' 'jobs' @{OriginalPath='D:\Jobs';ResolvedCandidate='D:\Jobs'} @() Unsupported)
)
$items=@($siteA,$siteB,$pool,$task,$folders)+$pathItems
$inventory=New-WsmInventory $source 1 $items
$workload=& $module {param($Inventory) Get-WsmWorkloadDiscovery $Inventory} $inventory
$inventory | Add-Member NoteProperty WorkloadDiscovery $workload -Force
$graphJson=ConvertTo-Json $workload -Depth 60 -Compress
Check (-not $graphJson.Contains('VERYSECRET')) 'Opaque task arguments leaked into safe workload projection.'
Check (@($workload.References | Where-Object {$_.ConsumerItemId -eq $task.ItemId -and $_.ReferenceKind -eq 'TaskArguments' -and $_.Opaque}).Count -eq 2) 'Opaque multi-action task arguments were not exposed as a manual review gap for every action.'
Check (@($workload.References | Where-Object {$_.ReferenceKind -eq 'IISApplicationPool' -and $_.ResourceItemId -eq $pool.ItemId}).Count -eq 2) 'Shared application pool reverse references did not include every consumer.'
Check (@($workload.SharedResources | Where-Object {$_.ResourceItemId -eq $pool.ItemId}).ConsumerCount -eq 2) 'Shared application pool consumer inventory is incomplete.'
Check (@($workload.RuntimeObservations | Where-Object {$_.ItemId -eq $task.ItemId -and $_.StartupConfiguration.SourceAutoStart -eq 'Enabled' -and $_.ObservedRuntime.State -eq 'Ready'}).Count -eq 1) 'Task startup policy and observed runtime were conflated or lost.'

$inventoryPath=Join-Path $root 'inventory.json';SaveJson $inventory $inventoryPath;$inventoryHash=(Get-FileHash $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
$catalog=Import-WsmInventory $workspace $inventoryPath $inventoryHash 'fixture-target';$catalogPath=Join-Path $workspace ('pairs\'+$catalog.PairId+'.json')
$snapshotRel='assistive\snapshots\'+$inventoryHash+'.json';$snapshotPath=Join-Path $workspace $snapshotRel
$catalog=Get-WsmCatalog $workspace $catalog.PairId
$catalog.SchemaVersion=3;$catalog.WorkloadDiscovery=$workload
$catalog | Add-Member NoteProperty Assistive ([pscustomobject][ordered]@{ContractVersion=1;PairId=$catalog.PairId;Revision=1;SourceSnapshot=[pscustomobject][ordered]@{Reference=$snapshotRel;SHA256=$inventoryHash;InventoryRevision=1;CreatedUtc=[DateTime]::UtcNow.ToString('o')};TargetBaseline=$null;TargetCurrent=$null;Comparison=$null;Selections=[pscustomobject][ordered]@{Revision=1;Items=@(foreach($item in $catalog.Items){[pscustomobject][ordered]@{ItemId=$item.ItemId;SourceRevision=1;Selected=$true;Reason='fixture selected';UpdatedUtc=[DateTime]::UtcNow.ToString('o')}})};RestoreDecisionHistory=@();MaterialReferences=@();ResultReferences=@();UpdatedUtc=[DateTime]::UtcNow.ToString('o')}) -Force
foreach($entry in $catalog.Items){
    $entry.Decision='Include';$entry.ReviewedBy='fixture-owner';$entry.ReviewedUtc=[DateTime]::UtcNow.ToString('o')
    $sourcePath='';$targetPath=''
    if($entry.Kind -eq 'PathCandidate'){$sourcePath=[string]$entry.Settings.OriginalPath;switch([string]$entry.NaturalKey){root{$targetPath='E:\Sites\Root'}admin{$targetPath='E:\Sites\Admin'}api{$targetPath='E:\Sites\Api'}sub-a{$targetPath='E:\Sites\SubA'}sub-b{$targetPath='E:\Sites\SubB'}jobs{$targetPath='E:\Jobs'}}}
    if($sourcePath){$entry | Add-Member NoteProperty MigrationSpec ([pscustomobject][ordered]@{Adapter='FileScope';Owner='fixture-owner';Evidence='approved fixture map';DesiredFinalState='Disabled';BusinessChecks=@();SourcePath=$sourcePath;TargetPath=$targetPath;ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='Block';ConfigFiles=@();ConfigOverrides=@()}) -Force}
}
($catalog.Assistive.Selections.Items | Where-Object ItemId -CEQ $siteB.ItemId)[0].Selected=$false
SaveJson $catalog $catalogPath
$siteDraftPath=Join-Path $root 'site-draft.json';New-WsmMigrationSpecTemplate $workspace $catalog.PairId $siteA.ItemId $siteDraftPath | Out-Null;$siteDraft=Get-Content -LiteralPath $siteDraftPath -Raw | ConvertFrom-Json
$siteTarget=([xml]$siteDraft.Desired.Xml)
Check (($siteTarget.SelectSingleNode("//*[local-name()='application'][@path='/']/*[local-name()='virtualDirectory'][@path='/']").GetAttribute('physicalPath')) -eq 'E:\Sites\Root') 'First site virtual directory was not mapped in typed XML.'
Check (($siteTarget.SelectSingleNode("//*[local-name()='application'][@path='/']/*[local-name()='virtualDirectory'][@path='/admin']").GetAttribute('physicalPath')) -eq 'E:\Sites\Admin') 'Second virtual directory was not independently mapped.'
Check ($siteDraft.SourceXml -eq $siteA.Settings.Xml -and $siteDraft.StagedDisabled -and $siteDraft.SourceAutoStart -eq 'true' -and $siteDraft.DesiredFinalState -eq 'Disabled') 'Site draft did not keep source XML/policy distinct from staged disabled target.'
Check (@($siteDraft.SharedResourceImpacts | Where-Object {$_.ResourceItemId -eq $pool.ItemId -and $_.UnselectedConsumerItemIds -contains $siteB.ItemId -and $_.RequiresSharedReview}).Count -eq 1) 'Draft did not expose the unselected consumer of a shared application pool.'
$taskDraftPath=Join-Path $root 'task-draft.json';New-WsmMigrationSpecTemplate $workspace $catalog.PairId $task.ItemId $taskDraftPath | Out-Null;$taskDraft=Get-Content -LiteralPath $taskDraftPath -Raw | ConvertFrom-Json;$taskTarget=[xml]$taskDraft.Desired.Xml
Check (@($taskTarget.SelectNodes("//*[local-name()='Exec']/*[local-name()='Command']") | ForEach-Object InnerText) -join '|' -eq 'E:\Jobs\One.exe|E:\Jobs\Two.exe') 'Multi-action task command paths did not map through the approved FileScope root.'
Check ((@($taskTarget.SelectNodes("//*[local-name()='Exec']/*[local-name()='WorkingDirectory']") | ForEach-Object InnerText | Select-Object -Unique) -join '|') -eq 'E:\Jobs') 'Task working directories did not map.'
Check (($taskTarget.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']").InnerText) -eq 'false' -and $taskDraft.SourceAutoStart -eq 'true' -and $taskDraft.DesiredFinalState -eq 'Disabled') 'Source enabled task was not drafted stopped with its startup policy recorded separately.'
Check ($taskDraft.SourceXml -eq $taskXml -and $taskDraft.Desired.Xml -notmatch 'VERYSECRET') 'Task raw/source XML separation failed or opaque arguments leaked.'
$webBPath=Join-Path $root 'web-b-draft.json';New-WsmMigrationSpecTemplate $workspace $catalog.PairId $siteB.ItemId $webBPath | Out-Null;$webB=Get-Content -LiteralPath $webBPath -Raw | ConvertFrom-Json
Check (@($webB.WorkloadMappingReview | Where-Object {$_.FieldPointer -match 'IIS/site/WebB/application\[\d+\]/virtualDirectory\[\d+\]/@physicalPath' -and $_.Status -eq 'ReviewRequired'}).Count -eq 1) 'Same source path with multiple approved maps did not require review.'

# A legacy catalog retains the prior enabled-final behavior and source XML shape.
$legacy=$catalog.PSObject.Copy();$legacy.SchemaVersion=1;$legacy.PSObject.Properties.Remove('Assistive');$legacy.PSObject.Properties.Remove('WorkloadDiscovery');$legacyPath=Join-Path $workspace ('pairs\'+$catalog.PairId+'.json');SaveJson $legacy $legacyPath
$legacyTaskPath=Join-Path $root 'legacy-task.json';New-WsmMigrationSpecTemplate $workspace $catalog.PairId $task.ItemId $legacyTaskPath | Out-Null;$legacyTask=Get-Content -LiteralPath $legacyTaskPath -Raw | ConvertFrom-Json
Check ($legacyTask.Desired.Xml -eq $taskXml -and $legacyTask.DesiredFinalState -eq 'Enabled' -and -not $legacyTask.PSObject.Properties['WorkloadMappingReview']) 'Legacy draft behavior changed without Assistive opt-in.'
Write-Host ('PASS: R3-B workload graph and schema3 public draft consumer. Evidence: '+$root)
