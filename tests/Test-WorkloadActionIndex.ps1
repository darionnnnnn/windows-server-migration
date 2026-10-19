#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$script:assertionCount=0
function Check([bool]$Condition,[string]$Message){$script:assertionCount++;if(-not $Condition){throw $Message}}

function New-Catalog([string]$TaskXml,[switch]$Ambiguous){
    $hostId=[Guid]::NewGuid().ToString()
    $task=New-WsmItem $hostId Tasks ScheduledTask 'Action index fixture' '\Fixture\' @{TaskName='ActionIndex';TaskPath='\Fixture\';Xml=$TaskXml;TaskSecurityCaptureStatus='Captured'}
    $task | Add-Member NoteProperty AccountMapping '' -Force
    $task | Add-Member NoteProperty Decision 'Exclude' -Force
    $roots=New-Object 'System.Collections.Generic.List[object]'
    $definitions=New-Object 'System.Collections.Generic.List[object]'
    $definitions.Add([pscustomobject]@{Source='D:\Jobs';Target='F:\Moved\Jobs';NaturalKey='jobs-d'})
    $definitions.Add([pscustomobject]@{Source='E:\Jobs';Target='G:\Moved\Jobs';NaturalKey='jobs-e'})
    if($Ambiguous){$definitions.Add([pscustomobject]@{Source='D:\Jobs\Scripts';Target='H:\Moved\Scripts';NaturalKey='jobs-nested'})}
    foreach($definition in $definitions){
        $item=New-WsmItem $hostId Storage PathCandidate $definition.Source $definition.NaturalKey @{OriginalPath=$definition.Source;ResolvedCandidate=$definition.Source} @() Success
        $item | Add-Member NoteProperty Decision 'Include' -Force
        $item | Add-Member NoteProperty ReviewedBy 'fixture-owner' -Force
        $item | Add-Member NoteProperty ReviewedUtc ([DateTime]::UtcNow.ToString('o')) -Force
        $item | Add-Member NoteProperty MigrationSpec ([pscustomobject]@{Adapter='FileScope';SourcePath=$definition.Source;TargetPath=$definition.Target;ExcludedRelativePaths=@()}) -Force
        $roots.Add($item)
    }
    $items=@($task)+@($roots.ToArray())
    $selections=@(foreach($item in $items){[pscustomobject]@{ItemId=$item.ItemId;Selected=$true}})
    $catalog=[pscustomobject]@{
        Items=$items
        Assistive=[pscustomobject]@{ContractVersion=1;Selections=[pscustomobject]@{Items=$selections}}
        WorkloadDiscovery=[pscustomobject]@{References=@();SharedResources=@()}
    }
    [pscustomobject]@{Task=$task;Catalog=$catalog}
}

$xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Settings><Enabled>true</Enabled></Settings><Actions Context="Author"><ComHandler><ClassId>{FIXTURE}</ClassId><Data>ComHandlerDataMustRemain</Data></ComHandler><Exec><Command>D:\Jobs\one.exe</Command><Arguments>--token first-private-value</Arguments><WorkingDirectory>D:\Jobs</WorkingDirectory></Exec><SendEmail><Arguments>NonExecActionDataMustRemain</Arguments></SendEmail><Exec><Command>E:\Jobs\two.exe</Command><Arguments>--password second-private-value</Arguments><WorkingDirectory>E:\Jobs</WorkingDirectory></Exec></Actions></Task>'
$fixture=New-Catalog $xml
$draft=& $module {param($item,$catalog) Get-WsmMigrationSpecDraft $item $catalog} $fixture.Task $fixture.Catalog
$mapped=& $module {param($item,$catalog) Get-WsmWorkloadXmlDraft $item $catalog} $fixture.Task $fixture.Catalog
$target=[xml]$mapped.TargetXml
$commands=@($target.SelectNodes("//*[local-name()='Exec']/*[local-name()='Command']") | ForEach-Object InnerText)
$workingDirectories=@($target.SelectNodes("//*[local-name()='Exec']/*[local-name()='WorkingDirectory']") | ForEach-Object InnerText)
Check (($commands -join '|') -ceq 'F:\Moved\Jobs\one.exe|G:\Moved\Jobs\two.exe') ('Interleaved action command mappings were applied to the wrong Exec node: '+($commands -join '|'))
Check (($workingDirectories -join '|') -ceq 'F:\Moved\Jobs|G:\Moved\Jobs') ('Interleaved action working directories were applied to the wrong Exec node: '+($workingDirectories -join '|'))
Check ($target.SelectSingleNode("//*[local-name()='ComHandler']/*[local-name()='Data']").InnerText -ceq 'ComHandlerDataMustRemain') 'ComHandler data changed while mapping Exec actions.'
Check ($target.SelectSingleNode("//*[local-name()='SendEmail']/*[local-name()='Arguments']").InnerText -ceq 'NonExecActionDataMustRemain') 'Non-Exec action data changed while redacting Exec arguments.'
$redacted=@($target.SelectNodes("//*[local-name()='Exec']/*[local-name()='Arguments']") | ForEach-Object InnerText)
Check (@($redacted | Where-Object {$_ -ceq '[OPAQUE_ARGUMENTS_REDACTED_REVIEW_PROTECTED_SOURCE]'}).Count -eq 2) 'Opaque arguments were not redacted on both original Exec nodes.'
Check ($draft.Adapter -ceq 'ManualWorkflow' -and $draft.SourceXml -ceq $xml) 'The actual migration-spec consumer did not preserve a mixed unsupported-action task for manual review.'
Check (($mapped.TargetXml -notmatch 'first-private-value|second-private-value') -and (($mapped.WorkloadMappingReview | ConvertTo-Json -Depth 20 -Compress) -notmatch 'first-private-value|second-private-value')) 'Opaque argument values leaked into the draft or review projection.'
Check (@($mapped.WorkloadMappingReview | Where-Object { $_.ReferenceKind -ceq 'TaskCommand' -and $_.Applied -and $_.TargetValue -ceq 'F:\Moved\Jobs\one.exe' }).Count -eq 1) 'First Exec command review row does not match the applied node.'
Check (@($mapped.WorkloadMappingReview | Where-Object { $_.ReferenceKind -ceq 'TaskCommand' -and $_.Applied -and $_.TargetValue -ceq 'G:\Moved\Jobs\two.exe' }).Count -eq 1) 'Second Exec command review row does not match the applied node.'

$execOnlyXml='<Task><Settings><Enabled>true</Enabled></Settings><Actions><Exec><Command>D:\Jobs\one.exe</Command><Arguments>--token exec-only-secret</Arguments><WorkingDirectory>D:\Jobs</WorkingDirectory></Exec><Exec><Command>E:\Jobs\two.exe</Command><Arguments>--password exec-only-secret-2</Arguments><WorkingDirectory>E:\Jobs</WorkingDirectory></Exec></Actions></Task>'
$execOnly=New-Catalog $execOnlyXml
$execOnlyDraft=& $module {param($item,$catalog) Get-WsmMigrationSpecDraft $item $catalog} $execOnly.Task $execOnly.Catalog
$execOnlyTarget=[xml]$execOnlyDraft.Desired.Xml
Check ((@($execOnlyTarget.SelectNodes("//*[local-name()='Exec']/*[local-name()='Command']") | ForEach-Object InnerText) -join '|') -ceq 'F:\Moved\Jobs\one.exe|G:\Moved\Jobs\two.exe') 'Exec-only task regression failed.'
Check ($execOnlyDraft.Desired.Xml -notmatch 'exec-only-secret') 'Exec-only opaque arguments were not redacted.'

$sameLocation=New-Catalog $execOnlyXml
foreach($scope in @($sameLocation.Catalog.Items | Where-Object {$_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope'})){$scope.MigrationSpec.TargetPath=$scope.MigrationSpec.SourcePath}
$sameLocationDraft=& $module {param($item,$catalog) Get-WsmMigrationSpecDraft $item $catalog} $sameLocation.Task $sameLocation.Catalog
$sameLocationTarget=[xml]$sameLocationDraft.Desired.Xml
Check ((@($sameLocationTarget.SelectNodes("//*[local-name()='Exec']/*[local-name()='Command']") | ForEach-Object InnerText) -join '|') -ceq 'D:\Jobs\one.exe|E:\Jobs\two.exe') 'Same-location source and target changed a task command.'
Check ((@($sameLocationTarget.SelectNodes("//*[local-name()='Exec']/*[local-name()='WorkingDirectory']") | ForEach-Object InnerText) -join '|') -ceq 'D:\Jobs|E:\Jobs') 'Same-location source and target changed a task working directory.'
Check ($sameLocationDraft.SourceXml -ceq $execOnlyXml -and $sameLocationDraft.Desired.Xml -notmatch 'exec-only-secret') 'Same-location draft lost original source XML or retained opaque arguments.'

$ambiguousXml='<Task><Actions><Exec><Command>D:\Jobs\Scripts\one.exe</Command><Arguments>opaque secret stays private</Arguments></Exec></Actions></Task>'
$ambiguous=New-Catalog $ambiguousXml -Ambiguous
$ambiguousDraft=& $module {param($item,$catalog) Get-WsmMigrationSpecDraft $item $catalog} $ambiguous.Task $ambiguous.Catalog
$ambiguousTarget=[xml]$ambiguousDraft.Desired.Xml
$ambiguousCommand=$ambiguousTarget.SelectSingleNode("//*[local-name()='Exec']/*[local-name()='Command']").InnerText
$ambiguousRow=@($ambiguousDraft.WorkloadMappingReview | Where-Object { $_.ReferenceKind -ceq 'TaskCommand' })
Check ($ambiguousRow.Count -eq 1 -and -not $ambiguousRow[0].Applied -and $ambiguousRow[0].Status -ceq 'ReviewRequired') 'Overlapping approved FileScope maps did not remain an explicit review ambiguity.'
Check ($ambiguousCommand -ceq 'D:\Jobs\Scripts\one.exe') 'Ambiguous mapping silently changed the task command.'
Check ($ambiguousDraft.Desired.Xml -notmatch 'stays private') 'Opaque arguments leaked in ambiguous mapping case.'

$exactScopeFixture=New-Catalog $execOnlyXml
$exactScope=@($exactScopeFixture.Catalog.Items | Where-Object {$_.MigrationSpec -and $_.MigrationSpec.Adapter -ceq 'FileScope'})[0]
$exactScope.MigrationSpec.SourcePath='C:\';$exactScope.MigrationSpec.TargetPath='F:\Moved';$exactScope.MigrationSpec | Add-Member NoteProperty ContentSelection 'ExactMembers';$exactScope.MigrationSpec | Add-Member NoteProperty Members @([pscustomobject]@{RelativePath='Data\worker.exe';SHA256=('a'*64)})
$exactMemberReference=[pscustomobject]@{ResolvedPath='C:\Data\worker.exe';RawValue='C:\Data\worker.exe';Opaque=$false;ReferenceKind='TaskCommand'}
$exactMemberMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $exactMemberReference
Check ($exactMemberMapping.Status -ceq 'Mapped' -and $exactMemberMapping.TargetValue -ceq 'F:\Moved\Data\worker.exe') 'A command reference to an explicit ExactMembers file did not map to its reviewed target path.'
$exactNeighborReference=[pscustomobject]@{ResolvedPath='C:\Data\neighbor.exe';RawValue='C:\Data\neighbor.exe';Opaque=$false;ReferenceKind='TaskCommand'}
$exactNeighborMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $exactNeighborReference
Check ($exactNeighborMapping.Status -ceq 'Unmapped' -and -not $exactNeighborMapping.TargetValue) 'An unselected neighbor under an ExactMembers root was reported as covered.'
$exactDirectoryReference=[pscustomobject]@{ResolvedPath='C:\Data';RawValue='C:\Data';Opaque=$false;ReferenceKind='TaskWorkingDirectory'}
$exactDirectoryMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $exactDirectoryReference
Check ($exactDirectoryMapping.Status -ceq 'Unmapped' -and -not $exactDirectoryMapping.TargetValue) 'A directory reference was mapped as if an ExactMembers file set covered the directory.'
$exactScope.MigrationSpec.ContentSelection='ExactFiles';$exactScope.MigrationSpec | Add-Member NoteProperty ConfigFiles @([pscustomobject]@{RelativePath='Data\settings.ini';SHA256=('b'*64)})
$exactConfigReference=[pscustomobject]@{ResolvedPath='C:\Data\settings.ini';RawValue='C:\Data\settings.ini';Opaque=$false;ReferenceKind='IISConfigSource'}
$exactConfigMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $exactConfigReference
Check ($exactConfigMapping.Status -ceq 'Mapped' -and $exactConfigMapping.TargetValue -ceq 'F:\Moved\Data\settings.ini') 'An exact configuration artifact reference did not map through its ConfigFiles allowlist.'
$unlistedConfigReference=[pscustomobject]@{ResolvedPath='C:\Data\web.config';RawValue='C:\Data\web.config';Opaque=$false;ReferenceKind='IISConfigSource'}
$unlistedConfigMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $unlistedConfigReference
Check ($unlistedConfigMapping.Status -ceq 'Unmapped' -and -not $unlistedConfigMapping.TargetValue) 'An unlisted config file under ExactFiles was reported as covered.'
$exactDirectoryConfigMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $exactDirectoryReference
Check ($exactDirectoryConfigMapping.Status -ceq 'Unmapped' -and -not $exactDirectoryConfigMapping.TargetValue) 'A directory reference was mapped through the ExactFiles configuration list.'
$exactScope.MigrationSpec.PSObject.Properties.Remove('ContentSelection');$exactScope.MigrationSpec.PSObject.Properties.Remove('ConfigFiles');$exactScope.MigrationSpec.ExcludedRelativePaths=@('Data\Private')
$excludedFileReference=[pscustomobject]@{ResolvedPath='C:\Data\Private\secret.exe';RawValue='C:\Data\Private\secret.exe';Opaque=$false;ReferenceKind='TaskCommand'}
$excludedFileMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $excludedFileReference
Check ($excludedFileMapping.Status -ceq 'Unmapped' -and -not $excludedFileMapping.TargetValue) 'A WholeScope reference beneath ExcludedRelativePaths was reported as covered.'
$excludedDirectoryReference=[pscustomobject]@{ResolvedPath='C:\Data';RawValue='C:\Data';Opaque=$false;ReferenceKind='TaskWorkingDirectory'}
$excludedDirectoryMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $excludedDirectoryReference
Check ($excludedDirectoryMapping.Status -ceq 'Unmapped' -and -not $excludedDirectoryMapping.TargetValue) 'A WholeScope directory reference containing an excluded subtree was reported as fully covered.'
$includedFileReference=[pscustomobject]@{ResolvedPath='C:\Data\worker.exe';RawValue='C:\Data\worker.exe';Opaque=$false;ReferenceKind='TaskCommand'}
$includedFileMapping=& $module {param($catalog,$reference) Resolve-WsmWorkloadReferenceMapping $catalog $reference} $exactScopeFixture.Catalog $includedFileReference
Check ($includedFileMapping.Status -ceq 'Mapped' -and $includedFileMapping.TargetValue -ceq 'F:\Moved\Data\worker.exe') 'A WholeScope file reference outside excluded paths no longer mapped.'

$unsupportedXml='<Task><Actions><ComHandler><ClassId>{ONLY}</ClassId></ComHandler></Actions></Task>'
$unsupported=New-Catalog $unsupportedXml
$unsupportedDraft=& $module {param($item,$catalog) Get-WsmMigrationSpecDraft $item $catalog} $unsupported.Task $unsupported.Catalog
Check ($unsupportedDraft.Adapter -ceq 'ManualWorkflow' -and $unsupportedDraft.Procedure -match 'unsupported action type') 'A task with no Exec action was synthesized instead of routed for review.'
$unsupportedRefs=@(& $module {param($item) Get-WsmWorkloadPathReferences $item} $unsupported.Task)
Check ($unsupportedRefs.Count -eq 1 -and $unsupportedRefs[0].FieldPointer -ceq 'Task/Actions/Action[0]' -and $unsupportedRefs[0].ReviewRequired) 'Unsupported action identity was not preserved for manual review.'

Write-Host ('PASS: E0 original action indices, typed draft consumer, opaque argument redaction, Exec-only and same-location regression, and ambiguous/unsupported action handling. Assertions: '+$script:assertionCount)
