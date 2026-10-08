#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-advanced-'+[Guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($root)
$workspace=Join-Path $root 'manager'; Initialize-WsmWorkspace $workspace | Out-Null
$passed=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Reject([scriptblock]$Action,[string]$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Check $failed $Message }
function Save($Data,$Name) { $p=Join-Path $root $Name; [IO.File]::WriteAllText($p,($Data | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false))); $p }
function Rev { (Get-WsmCatalog $workspace $pair).DecisionRevision }
$source=[pscustomobject]@{ HostId=[Guid]::NewGuid().ToString(); Fingerprint=('b'*64); Name='old-advanced' }
$items=@(for ($n=0;$n -lt 125;$n++) { New-WsmItem $source.HostId Services Service ('svc-'+$n) ('C:\apps\svc-'+$n) @{ Path=('C:\apps\svc-'+$n) } })
$inv=New-WsmInventory $source 1 $items; $file=Save $inv 'inventory.json'; $c=Import-WsmInventory $workspace $file (Get-FileHash $file).Hash 'new-advanced'; $pair=$c.PairId
$preview=Get-WsmRulePreview $workspace $pair -Category Services -Search 'C:\apps' -Decision Exclude -Reason 'retired'
Check ($preview.Selected -eq 125 -and $preview.Changed -eq 125) 'Rule only selected current page'
Check ((Rev) -eq 0) 'Preview mutated authority'
$rule=Invoke-WsmReviewRule $workspace $pair -Category Services -Search 'C:\apps' -Decision Exclude -Reason 'retired' -ExpectedRevision 0
Check ($rule.Matched -eq 125) 'Rule lost items'
$c=Get-WsmCatalog $workspace $pair
Check (@($c.Items | Where-Object RuleId -EQ $rule.RuleId).Count -eq 125) 'Rule provenance missing'
Reject { Invoke-WsmReviewRule $workspace $pair -Decision Include -ExpectedRevision 0 } 'Stale preview applied'
$c=Undo-WsmDecision $workspace $pair (Rev)
Check (@($c.Items | Where-Object { $_.Decision -eq 'Pending' -and -not $_.RuleId }).Count -eq 125) 'Rule undo lost provenance'
$a=$items[0].ItemId; $b=$items[1].ItemId
Set-WsmReviewMetadata $workspace $pair $a 'Payroll' ConfirmedThirdParty (Rev)
Check ((Get-WsmItems $workspace $pair -Group Payroll -BuiltIn ConfirmedThirdParty).Total -eq 1) 'Group/built-in filtering failed'
Set-WsmReviewView $workspace $pair Services 'C:\apps' 2 20
Check ((Get-WsmCatalog $workspace $pair).ReviewView.Page -eq 2) 'Review view not persisted'
$manual=Add-WsmManualItem $workspace $pair External 'Quarterly payroll job' 'quarterly-payroll' 'Finance' 'ticket Q1' (Rev)
Check ($manual.Decision -eq 'Pending' -and $manual.ManualEntry) 'Manual item silently included'
Reject { Add-WsmManualItem $workspace $pair External 'duplicate' 'quarterly-payroll' 'Finance' 'ticket Q1' (Rev) } 'Duplicate manual identity accepted'
$file2=Save (New-WsmInventory $source 2 $items) 'inventory2.json'; $c=Import-WsmInventory $workspace $file2 (Get-FileHash $file2).Hash
Check (($c.Items | Where-Object ItemId -EQ $manual.ItemId).Present) 'Rescan removed manual evidence'
Check ($c.ReviewView.PageSize -eq 20) 'Rescan reset review view'
Set-WsmDependencies $workspace $pair $a @([pscustomobject]@{ ItemId=$b; Type='Mandatory' }) (Rev)
Set-WsmDependencies $workspace $pair $b @([pscustomobject]@{ ItemId=$a; Type='Mandatory' }) (Rev)
$c=Set-WsmDecision $workspace $pair @($a,$b) Include '' (Rev)
Check (@(Get-WsmReviewIssues $workspace $pair | Where-Object Issue -Like 'Mandatory cycle*').Count -eq 2) 'Cycle not detected'
Set-WsmConsistencyGroup $workspace $pair @($a,$b) 'Payroll consistency' 'Finance' 'ticket Q2: freeze, staged activation and reconcile procedure' (Rev)
Check (@(Get-WsmReviewIssues $workspace $pair | Where-Object Issue -Like 'Mandatory cycle*').Count -eq 0) 'Reviewed consistency group rejected'
Set-WsmMapping $workspace $pair $a 'D:\Payroll' (Rev)
Set-WsmMapping $workspace $pair $b 'd:\payroll\child' (Rev)
Check (@(Get-WsmReviewIssues $workspace $pair | Where-Object Issue -Like 'Overlapping*').Count -eq 1) 'Nested mappings not blocked'
Reject { Set-WsmMapping $workspace $pair $a 'D:relative' (Rev) } 'Drive-relative path accepted'
Reject { Set-WsmMapping $workspace $pair $a '\\?\D:\escape' (Rev) } 'Device path accepted'
Set-WsmMapping $workspace $pair $b 'D:\OtherPayroll' (Rev)
Set-WsmMapping $workspace $pair $a 'DOMAIN\NewPayroll' (Rev) -Type Account
Check ((Get-WsmItems $workspace $pair -Search 'DOMAIN\NewPayroll').Total -eq 1) 'Account mapping not searchable'
$csv=Join-Path $root 'review.csv'; Export-WsmDecisions $workspace $pair $csv
$rows=@(Import-Csv $csv); $rows[0].Decision='Exclude'; $rows[0].Reason='changed'; $rows | Export-Csv $csv -NoTypeInformation -Encoding UTF8
$csvPreview=Import-WsmDecisions $workspace $pair $csv -Preview
Check ($csvPreview.Changed -eq 1) 'CSV preview counts unchanged rows'
$before=Rev; [IO.File]::AppendAllText($csv,"`r`n")
Reject { Import-WsmDecisions $workspace $pair $csv -ExpectedHash $csvPreview.SourceHash } 'Modified preview CSV accepted'
Check ((Rev) -eq $before) 'Rejected CSV modified authority'
$moduleItems=@(New-WsmItem $source.HostId Tasks ScheduledTask 'fixture-task' '\Microsoft\Fixture' @{ Xml='<Task><Actions><Exec><Command>..\relative.ps1</Command><WorkingDirectory>\\nas\shared</WorkingDirectory></Exec></Actions></Task>' })
$candidates=@(& $module { param($Id,$Items) Get-WsmPathCandidates $Id $Items } $source.HostId $moduleItems)
Check ($candidates.Count -eq 2 -and @($candidates | Where-Object { $_.Settings.OriginalPath -eq '..\relative.ps1' -and -not $_.Settings.ResolvedCandidate }).Count -eq 1) 'Relative/UNC path candidates omitted'
Reject { & $module { Read-WsmXml '<!DOCTYPE a [<!ENTITY x SYSTEM "file:///C:/fixture">]><a>&x;</a>' } } 'DTD input accepted'
$summary=@(Get-WsmCategorySummary $workspace $pair)
Check (($summary | Measure-Object Total -Sum).Sum -eq 126) 'Category counts omit manual item'
$result=[pscustomobject]@{ SchemaVersion=1; ToolVersion='0.1.0'; Kind='StageResult'; BatchId=$c.BatchId; PairId=$pair; SourceHostId=$source.HostId; RunId=[Guid]::NewGuid().ToString(); Sequence=1; Stage='Inventory'; Status='Blocked'; InventoryRevision=2; DecisionRevision=(Rev); ProducedUtc=[DateTime]::UtcNow.ToString('o') }
$resultFile=Save $result 'result.json'; Import-WsmStageResult $workspace $resultFile (Get-FileHash $resultFile).Hash
Reject { Import-WsmStageResult $workspace $resultFile (Get-FileHash $resultFile).Hash } 'Duplicate result overwrote current state'
$result.Sequence=2; $result.Stage='Restore'; $result.Status='Succeeded'; $resultFile=Save $result 'false-success.json'
Reject { Import-WsmStageResult $workspace $resultFile (Get-FileHash $resultFile).Hash } 'Unsupported adapter success unlocked migration'
$result.RunId=[Guid]::NewGuid().ToString(); $result.Sequence=1; $result.Stage='Inventory'; $result.Status='Blocked'; $resultFile=Save $result 'new-run-stale.json'
Reject { Import-WsmStageResult $workspace $resultFile (Get-FileHash $resultFile).Hash } 'New run reset stage sequence and overwrote newer result'
$report=Join-Path $root 'report.html'; Export-WsmReport $workspace $pair $report
$text=[IO.File]::ReadAllText($report+'.txt')
foreach ($item in (Get-WsmCatalog $workspace $pair).Items) { if (-not $text.Contains($item.ItemId)) { throw 'Full text report omitted an item.' } }
Check ($text.Contains($manual.ItemId)) 'Complete text omits manual evidence'
$template=Join-Path $root 'template.json'; $templateExport=Export-WsmReviewTemplate $workspace $pair $rule.RuleId $template
$templateRaw=[IO.File]::ReadAllText($template)
Check (-not $templateRaw.Contains($source.HostId) -and -not $templateRaw.Contains($a)) 'Template copied source identities'
$sourceOther=[pscustomobject]@{ HostId=[Guid]::NewGuid().ToString(); Fingerprint=('d'*64); Name='old-other' }
$itemsOther=@(New-WsmItem $sourceOther.HostId Services Service 'Other service' 'C:\apps\other' @{})
$otherFile=Save (New-WsmInventory $sourceOther 1 $itemsOther) 'other.json'
$other=Import-WsmInventory $workspace $otherFile (Get-FileHash $otherFile).Hash 'new-other'
$templatePreview=Get-WsmTemplatePreview $workspace $other.PairId $template $templateExport.SHA256
Check ($templatePreview.Selected -eq 1 -and $templatePreview.Changes[0].ItemId -eq $itemsOther[0].ItemId) 'Template reused source IDs or failed target preview'
Invoke-WsmReviewTemplate $workspace $other.PairId $template $templateExport.SHA256 $templatePreview.DecisionRevision | Out-Null
Check ((Get-WsmCatalog $workspace $other.PairId).Items[0].Decision -eq 'Exclude') 'Template did not apply explicit reviewed conditions'
Set-WsmCrossHostDependency $workspace $pair $other.PairId -Evidence 'fixture cross-host dependency' -ExpectedRevision (Rev)
$graph=Join-Path $root 'graph.json'; Export-WsmFleetGraph $workspace $graph
Check ((Get-Content $graph -Raw | ConvertFrom-Json).Edges.Count -eq 1) 'Cross-host graph omitted edge'
Export-WsmFleetReport $workspace (Join-Path $root 'fleet.html')
Write-Host ('PASS: '+$passed+' advanced review/discovery/fleet semantic checks. Evidence: '+$root)
