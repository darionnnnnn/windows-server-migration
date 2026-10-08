#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Reject([scriptblock]$Action,[string]$Message) { $rejected=$false; try { & $Action | Out-Null } catch { $rejected=$true }; Check $rejected $Message }
function Save-Inventory($Inventory,[string]$Name) { $path=Join-Path $root $Name; [IO.File]::WriteAllText($path,($Inventory | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false))); $path }
$workspace=Join-Path $root 'manager'
Initialize-WsmWorkspace $workspace | Out-Null
$source=[pscustomobject]@{ HostId=[Guid]::NewGuid().ToString(); Fingerprint=('a'*64); Name='fixture-old' }
$dependency=New-WsmItem $source.HostId Runtime App '<script>alert(1)</script>' 'app' @{ Secret='never-render-this-secret' }
$service=New-WsmItem $source.HostId Services Service '=formula' 'svc' @{ Path='C:\App\svc.exe' } @([pscustomobject]@{ ItemId=$dependency.ItemId; Type='Mandatory' })
$inv=New-WsmInventory $source 1 @($dependency,$service)
$file=Save-Inventory $inv 'fixture.json'; $hash=(Get-FileHash $file).Hash
Reject { Import-WsmInventory $workspace $file ('0'*64) target } 'Tampered file accepted'
$c=Import-WsmInventory $workspace $file $hash 'fixture-new'; $pair=$c.PairId
Check ((Get-WsmItems $workspace $pair -Search '=formula').Total -eq 1) 'Literal search failed'
Reject { Import-WsmInventory $workspace $file $hash } 'Stale inventory accepted'
Reject { Set-WsmDecision $workspace $pair @($service.ItemId) Exclude '' 0 } 'Blank exclusion accepted'
Reject { Set-WsmDecision $workspace $pair @($service.ItemId,'unknown') Include '' 0 } 'Partial invalid batch accepted'
Check ((Get-WsmCatalog $workspace $pair).DecisionRevision -eq 0) 'Rejected operation mutated catalog'
$c=Set-WsmDecision $workspace $pair @($service.ItemId) Include '' 0
Check (@(Get-WsmReviewIssues $workspace $pair | Where-Object Issue -Like 'Mandatory*').Count -eq 1) 'Dependency conflict omitted'
Reject { Approve-WsmPlan $workspace $pair (Join-Path $root 'bad-plan.json') 1 } 'Conflicting plan approved'
$c=Undo-WsmDecision $workspace $pair 1
Check (@($c.Items | Where-Object Decision -EQ Pending).Count -eq 2) 'Undo failed'
$csv=Join-Path $root 'decisions.csv'; Export-WsmDecisions $workspace $pair $csv
$rows=@(Import-Csv $csv); Check (@($rows | Where-Object Name -EQ "'=formula").Count -eq 1) 'CSV formula not escaped'
$rows[0].Decision='Exclude'; $rows[0].Reason='owner approved'; $rows[1].Decision='Wrong'; $rows | Export-Csv $csv -NoTypeInformation -Encoding UTF8
Reject { Import-WsmDecisions $workspace $pair $csv } 'Invalid CSV accepted'
Check ((Get-WsmCatalog $workspace $pair).DecisionRevision -eq 2) 'Invalid CSV partially applied'
$rows[1].Decision='Include'; $rows[0].Decision='Include'; $rows | Export-Csv $csv -NoTypeInformation -Encoding UTF8
$c=Import-WsmDecisions $workspace $pair $csv
Check (@($c.Items | Where-Object Decision -EQ Include).Count -eq 2) 'CSV valid decisions failed'
$html=Join-Path $root 'review.html'; Export-WsmReport $workspace $pair $html
$content=[IO.File]::ReadAllText($html)
Check (-not $content.Contains('never-render-this-secret')) 'Settings leaked into report'
Check (-not $content.Contains('<script>alert(1)</script>')) 'HTML injection escaped incorrectly'
$plan=Join-Path $root 'approved.json'; $approval=Approve-WsmPlan $workspace $pair $plan $c.DecisionRevision
Check (-not $approval.ExportReady) 'Review falsely claims export readiness'
$accepted=Import-WsmApprovedPlan $plan $approval.SHA256 $file
Check ($accepted.Gate -eq 'ReviewComplete') 'Approved review roundtrip failed'
$changed=New-WsmItem $source.HostId Services Service '=formula' 'svc' @{ Path='D:\Changed\svc.exe' } @([pscustomobject]@{ ItemId=$dependency.ItemId; Type='Mandatory' })
$inv2=New-WsmInventory $source 2 @($dependency,$changed); $file2=Save-Inventory $inv2 'fixture2.json'
$c=Import-WsmInventory $workspace $file2 (Get-FileHash $file2).Hash
Check (($c.Items | Where-Object ItemId -EQ $changed.ItemId).Decision -eq 'Pending') 'Settings drift kept approval'
Check (($c.Items | Where-Object ItemId -EQ $dependency.ItemId).Decision -eq 'Include') 'Unchanged decision lost'
Check ($null -eq $c.Approval) 'Approval survives inventory change'
Export-WsmFleetReport $workspace (Join-Path $root 'fleet.html')
$gap=New-WsmItem $source.HostId External DiscoveryGap 'unknown external dependencies' 'external-gap' @{} @() Unsupported
$inv3=New-WsmInventory $source 3 @($dependency,$changed,$gap); $file3=Save-Inventory $inv3 'fixture3.json'
$c=Import-WsmInventory $workspace $file3 (Get-FileHash $file3).Hash
$c=Set-WsmDecision $workspace $pair @($dependency.ItemId,$changed.ItemId) Include 'owner review' $c.DecisionRevision
$c=Set-WsmDecision $workspace $pair @($gap.ItemId) Exclude 'not used' $c.DecisionRevision
Check (@(Get-WsmReviewIssues $workspace $pair | Where-Object Issue -Like 'Incomplete discovery*').Count -eq 1) 'Exclusion hides incomplete discovery'
Reject { Approve-WsmPlan $workspace $pair (Join-Path $root 'gap-bad-plan.json') $c.DecisionRevision } 'Reason alone bypassed discovery gap'
Set-WsmEvidence $workspace $pair $gap.ItemId 'fixture application owner' 'ticket TEST-001: synthetic owner verification' $c.DecisionRevision
$c=Get-WsmCatalog $workspace $pair
Check (@(Get-WsmReviewIssues $workspace $pair | Where-Object Gate -EQ ReviewComplete).Count -eq 0) 'Owner evidence did not resolve review blocker'
$csv=Join-Path $root 'subset.csv'; Export-WsmDecisions $workspace $pair $csv
$subset=@(Import-Csv $csv | Where-Object ItemId -EQ $changed.ItemId); $subset[0].Decision='Pending'; $subset | Export-Csv $csv -NoTypeInformation -Encoding UTF8
$c=Import-WsmDecisions $workspace $pair $csv
Check (($c.Items | Where-Object ItemId -EQ $dependency.ItemId).Decision -eq 'Include') 'Missing CSV row reset unrelated decision'
Check (($c.Items | Where-Object ItemId -EQ $changed.ItemId).Decision -eq 'Pending') 'Subset CSV did not apply'
Write-Host ('PASS: '+$passed+' semantic checks. Evidence: '+$root)
