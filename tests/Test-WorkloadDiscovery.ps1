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

# M2: typed resource references (task folder security / IIS application pool) only block review when the resource was not captured.
& $module {param($Workload,$Task,$Folders,$SiteB,$Pool,$HostId,$Source)
    function Rows($item,$catalog){@((Get-WsmWorkloadXmlDraft $item $catalog).WorkloadMappingReview)}
    function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
    $captured=[pscustomobject]@{Items=@($Task,$Folders);WorkloadDiscovery=$Workload}
    $taskRows=Rows $Task $captured
    $folderRow=@($taskRows | Where-Object ReferenceKind -ceq 'TaskFolderSecurity')
    Check ($folderRow.Count -eq 1 -and $folderRow[0].ReviewRequired -eq $false -and $folderRow[0].Applied -eq $true -and $folderRow[0].Status -ceq 'TypedResourceCaptured' -and $folderRow[0].Reason -match 'typed contract') 'Captured task folder security must be an informational TypedResourceCaptured row.'
    $argRows=@($taskRows | Where-Object ReferenceKind -ceq 'TaskArguments')
    Check ($argRows.Count -eq 2 -and @($argRows | Where-Object {$_.ReviewRequired}).Count -eq 2) 'TaskArguments references must keep blocking review when typed resources are relaxed.'
    $poolRow=@(Rows $SiteB $captured | Where-Object ReferenceKind -ceq 'IISApplicationPool')
    Check ($poolRow.Count -ge 1 -and @($poolRow | Where-Object {$_.ReviewRequired -or $_.Status -cne 'TypedResourceCaptured' -or -not $_.Applied}).Count -eq 0) 'Captured IIS application pool must be an informational TypedResourceCaptured row.'
    $otherReference=[pscustomobject][ordered]@{ConsumerItemId=[string]$Task.ItemId;ResourceItemId='';FieldPointer='Task/Fixture/OtherReference';ReferenceId=('b'*64);ReferenceKind='XmlPath';RawValue='fixture';ResolvedPath='';Channel='NotApplicable';ParseConfidence='Typed';Opaque=$false;Required=$true;ReviewRequired=$false;Reason=''}
    $otherCatalog=[pscustomobject]@{Items=@($Task,$Folders);WorkloadDiscovery=[pscustomobject]@{References=@($Workload.References)+@($otherReference)}}
    $otherRow=@(Rows $Task $otherCatalog | Where-Object FieldPointer -ceq 'Task/Fixture/OtherReference')
    Check ($otherRow.Count -eq 1 -and $otherRow[0].ReviewRequired -eq $true -and $otherRow[0].Applied -eq $false -and $otherRow[0].Status -cne 'TypedResourceCaptured') 'Only TaskFolderSecurity and IISApplicationPool may be relaxed; other non-path references must keep blocking review.'
    $missingTask=New-WsmItem $HostId Tasks ScheduledTask 'Missing folder job' '\Missing\Job' @{TaskName='Job';TaskPath='\Missing\';Xml=$Task.Settings.Xml;TaskSecurityCaptureStatus='Captured'}
    $missingSite=New-WsmItem $HostId Web IISSite 'Ghost pool site' 'GhostSite' @{Xml='<site name="GhostSite"><application path="/" applicationPool="GhostPool"><virtualDirectory path="/" physicalPath="D:\Sites\Ghost"/></application></site>'}
    $missingInventory=New-WsmInventory $Source 1 @($missingTask,$missingSite)
    $missingWorkload=Get-WsmWorkloadDiscovery $missingInventory
    $missing=[pscustomobject]@{Items=@($missingTask,$missingSite);WorkloadDiscovery=$missingWorkload}
    $missingFolder=@(Rows $missingTask $missing | Where-Object ReferenceKind -ceq 'TaskFolderSecurity')
    Check ($missingFolder.Count -eq 1 -and $missingFolder[0].ReviewRequired -eq $true -and $missingFolder[0].Applied -eq $false -and $missingFolder[0].Status -cne 'TypedResourceCaptured' -and $missingFolder[0].Reason -ceq 'Task folder security resource was not captured.') 'Uncaptured task folder security must keep blocking review with the inventory reason.'
    $missingPool=@(Rows $missingSite $missing | Where-Object ReferenceKind -ceq 'IISApplicationPool')
    Check ($missingPool.Count -eq 1 -and $missingPool[0].ReviewRequired -eq $true -and $missingPool[0].Applied -eq $false -and $missingPool[0].Status -cne 'TypedResourceCaptured' -and $missingPool[0].Reason -ceq 'Referenced application pool was not present in captured pool collection.') 'Uncaptured IIS application pool must keep blocking review with the inventory reason.'
    $candidate=New-WsmItem $HostId Storage PathCandidate 'Manual candidate' 'manual-candidate' @{OriginalPath='D:\Manual';ResolvedCandidate='D:\Manual'}
    $candidate | Add-Member NoteProperty MigrationSpec ([pscustomobject][ordered]@{Adapter='FileScope';Owner='fixture-owner';Evidence='fixture';DesiredFinalState='Disabled';BusinessChecks=@();SourcePath='D:\Manual';TargetPath='E:\Manual';ExcludedRelativePaths=@();Consistency='OwnerFreeze';Metadata='DaclOwner';ConflictPolicy='Block';ConfigFiles=@();ConfigOverrides=@();TransferChannel='C'}) -Force
    $candidate | Add-Member NoteProperty Decision 'Exclude' -Force
    $bindingHash=Get-WsmSourceCandidateFileScopeBindingHash $candidate
    foreach($case in @(@{Item=$Task;Catalog=$captured;Source=$Workload;Kind='TaskFolderSecurity'},@{Item=$missingTask;Catalog=$missing;Source=$missingWorkload;Kind='TaskFolderSecurity'},@{Item=$SiteB;Catalog=$captured;Source=$Workload;Kind='IISApplicationPool'},@{Item=$missingSite;Catalog=$missing;Source=$missingWorkload;Kind='IISApplicationPool'})){
        foreach($decision in @('Manual','Exclude')){
            $reference=@($case.Source.References | Where-Object {$_.ConsumerItemId -ceq $case.Item.ItemId -and $_.ReferenceKind -ceq $case.Kind} | Select-Object -First 1)[0]
            $stored=[pscustomobject]@{ReferenceId=[string]$reference.ReferenceId;CandidateItemId=[string]$candidate.ItemId;CandidateItemSpecHash=$bindingHash;InventoryHash='';InventoryRevision=0;Decision=$decision;FileScopeItemId='';FileScopeBindingHash=''}
            $discovery=[pscustomobject]@{References=$case.Source.References;FileScopeMappings=@($stored)}
            $catalogWithDecision=[pscustomobject]@{InventoryHash="";InventoryRevision=0;Items=@($case.Catalog.Items)+@($candidate);WorkloadDiscovery=$discovery}
            $row=@(Rows $case.Item $catalogWithDecision | Where-Object {$_.ReferenceKind -ceq $case.Kind -and $_.ReferenceId -ceq [string]$reference.ReferenceId})
            $expectedStatus=if($decision -ceq 'Manual'){'ManualReviewRequired'}else{'ExplicitlyExcluded'}
            Check ($row.Count -eq 1 -and $row[0].Status -ceq $expectedStatus -and $row[0].MappingDecision -ceq $decision -and $row[0].ReviewRequired -eq $false -and $row[0].Applied -eq $false) ('An explicit '+$decision+' disposition must win over the typed-resource relaxation for '+$case.Kind+'.')
        }
    }
} $workload $task $folders $siteB $pool $hostId $source

# A legacy catalog retains the prior enabled-final behavior and source XML shape.
$legacy=$catalog.PSObject.Copy();$legacy.SchemaVersion=1;$legacy.PSObject.Properties.Remove('Assistive');$legacy.PSObject.Properties.Remove('WorkloadDiscovery');$legacyPath=Join-Path $workspace ('pairs\'+$catalog.PairId+'.json');SaveJson $legacy $legacyPath
$legacyTaskPath=Join-Path $root 'legacy-task.json';New-WsmMigrationSpecTemplate $workspace $catalog.PairId $task.ItemId $legacyTaskPath | Out-Null;$legacyTask=Get-Content -LiteralPath $legacyTaskPath -Raw | ConvertFrom-Json
Check ($legacyTask.Desired.Xml -eq $taskXml -and $legacyTask.DesiredFinalState -eq 'Enabled' -and -not $legacyTask.PSObject.Properties['WorkloadMappingReview']) 'Legacy draft behavior changed without Assistive opt-in.'
& $module {param($HostId)
    $ns='http://schemas.microsoft.com/windows/2004/02/mit/task'
    function Draft($kind,$settings,$name){$item=New-WsmItem $HostId Tasks $kind $name $name $settings;$item | Add-Member NoteProperty AccountMapping $null;$item | Add-Member NoteProperty Mapping $null;Get-WsmMigrationSpecDraft $item ([pscustomobject]@{})}
    $pwdTask=Draft 'ScheduledTask' @{TaskName='PwdTask';TaskPath='\';Xml=('<Task xmlns="'+$ns+'"><Principals><Principal id="Author"><UserId>FIXTURE\batch</UserId><LogonType>Password</LogonType></Principal></Principals><Settings><Enabled>true</Enabled></Settings><Actions Context="Author"><Exec><Command>C:\Fixture\a.exe</Command></Exec></Actions></Task>')} 'PwdTask'
    $plainTask=Draft 'ScheduledTask' @{TaskName='PlainTask';TaskPath='\';Xml=('<Task xmlns="'+$ns+'"><Principals><Principal id="Author"><UserId>FIXTURE\batch</UserId><LogonType>S4U</LogonType></Principal></Principals><Settings><Enabled>true</Enabled></Settings><Actions Context="Author"><Exec><Command>C:\Fixture\a.exe</Command></Exec></Actions></Task>')} 'PlainTask'
    $specificPool=Draft 'IISPool' @{Xml='<add name="P1"><processModel identityType="SpecificUser" userName="FIXTURE\poolsvc" /></add>'} 'P1'
    $plainPool=Draft 'IISPool' @{Xml='<add name="P2"><processModel identityType="ApplicationPoolIdentity" /></add>'} 'P2'
    if(-not $pwdTask.PSObject.Properties['SecretRef'] -or $pwdTask.SecretRef -cne '' -or -not $specificPool.PSObject.Properties['SecretRef'] -or $specificPool.SecretRef -cne ''){throw 'Password task or SpecificUser pool draft lacks the empty SecretRef placeholder.'}
    if($plainTask.PSObject.Properties['SecretRef'] -or $plainPool.PSObject.Properties['SecretRef']){throw 'Non-password task or non-SpecificUser pool draft gained a SecretRef placeholder.'}
} $hostId
# M2b: the Task Scheduler COM folder path has no trailing backslash (\Custom) while a task TaskPath has one (\Custom\); both forms must match the same captured folder.
foreach($case in @(@{Folder='\Custom';TaskPath='\Custom\';Captured=$true},@{Folder='\Custom\';TaskPath='\Custom\';Captured=$true},@{Folder='\';TaskPath='\';Captured=$true},@{Folder='\Other';TaskPath='\Custom\';Captured=$false})){
    $caseTask=New-WsmItem $hostId Tasks ScheduledTask 'Job' ($case.TaskPath+'Job') @{TaskName='Job';TaskPath=$case.TaskPath;Xml=$taskXml;TaskSecurityCaptureStatus='Captured'}
    $caseFolder=New-WsmItem $hostId Tasks TaskFolder $case.Folder $case.Folder @{SecuritySddl='O:BAG:BAD:';SecurityCaptureStatus='Captured'}
    $caseWorkload=& $module {param($Inventory) Get-WsmWorkloadDiscovery $Inventory} (New-WsmInventory $source 1 @($caseTask,$caseFolder))
    $caseRef=@($caseWorkload.References | Where-Object {$_.ConsumerItemId -eq $caseTask.ItemId -and $_.ReferenceKind -eq 'TaskFolderSecurity'})
    Check ($caseRef.Count -eq 1 -and [bool]$caseRef[0].ReviewRequired -eq (-not $case.Captured) -and ([bool]$caseRef[0].ResourceItemId) -eq $case.Captured) ('Task folder '+$case.Folder+' vs TaskPath '+$case.TaskPath+' was not matched as captured='+$case.Captured+'.')
}
Write-Host ('PASS: R3-B workload graph and schema3 public draft consumer. Evidence: '+$root)
