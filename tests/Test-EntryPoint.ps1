#requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-cli-'+[Guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'manager'
$entry=Join-Path $PSScriptRoot '..\Start-ServerMigration.ps1'
$engine=Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $engine)) { $engine=Join-Path $PSHOME 'pwsh.exe' }
& $engine -NoProfile -NonInteractive -File $entry -Action Initialize -Workspace $workspace *> (Join-Path ([IO.Path]::GetTempPath()) 'wsm-cli-initialize.log')
if ($LASTEXITCODE -ne 0) { throw 'Initialize must return 0.' }
$source=[pscustomobject]@{ HostId=[Guid]::NewGuid().ToString(); Fingerprint=('c'*64); Name='synthetic-cli' }
$item=New-WsmItem $source.HostId Services Service 'cli-service' 'cli-service' @{Path='C:\Fixture\app.exe'}
$inventory=New-WsmInventory $source 1 @($item)
$path=Join-Path $root 'inventory.json'
[IO.File]::WriteAllText($path,($inventory | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($false)))
$c=Import-WsmInventory $workspace $path (Get-FileHash $path).Hash 'synthetic-target'
$assessmentLog=Join-Path $root 'scope-assessment.json'
& $engine -NoProfile -NonInteractive -File $entry -Action ScopeAssessment -Workspace $workspace -PairId $c.PairId *> $assessmentLog
if($LASTEXITCODE -ne 0){throw 'Read-only scope assessment must return 0.'}
$assessment=Get-Content -LiteralPath $assessmentLog -Raw | ConvertFrom-Json
if($assessment.TotalItems -ne 1 -or $assessment.Items[0].ItemId -cne $item.ItemId -or $assessment.Items[0].Classification.Disposition -cne 'GeneralMigration' -or (Get-WsmCatalog $workspace $c.PairId).DecisionRevision -ne 0){throw 'CLI scope assessment omitted classification or changed decisions.'}
& $engine -NoProfile -NonInteractive -File $entry -Action Issues -Workspace $workspace -PairId $c.PairId *> (Join-Path $root 'issues.log')
if ($LASTEXITCODE -ne 2) { throw 'Pending review must return 2.' }
$ErrorActionPreference='Continue' # Native stderr is expected for the rejection cases below.
& $engine -NoProfile -NonInteractive -File $entry -Action UnknownAction -Workspace $workspace *> (Join-Path $root 'invalid.log')
if ($LASTEXITCODE -ne 4) { throw 'Unknown action must return 4.' }
& $engine -NoProfile -NonInteractive -File $entry -Action Import -Workspace $workspace -Path $path -ExpectedHash ('0'*64) -TargetName target *> (Join-Path $root 'hash.log')
if ($LASTEXITCODE -ne 4) { throw 'Invalid trusted hash must return 4.' }
$ErrorActionPreference='Stop'
if ((Get-WsmCatalog $workspace $c.PairId).DecisionRevision -ne 0) { throw 'Rejected CLI input changed review.' }
$csv=Join-Path $root 'decisions.csv';Export-WsmDecisions $workspace $c.PairId $csv
$csvRows=@(Import-Csv -LiteralPath $csv);$csvRows[0].Decision='Exclude';$csvRows[0].Reason='owner reviewed exclusion';$csvRows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
$previewLog=Join-Path $root 'csv-preview.json'
& $engine -NoProfile -NonInteractive -File $entry -Action ImportCsvPreview -Workspace $workspace -PairId $c.PairId -Path $csv *> $previewLog
if($LASTEXITCODE -ne 0){throw 'CSV preview must return 0.'}
$csvPreview=Get-Content -LiteralPath $previewLog -Raw | ConvertFrom-Json
if($csvPreview.Changed -ne 1 -or $csvPreview.DecisionRevision -ne 0 -or (Get-WsmCatalog $workspace $c.PairId).DecisionRevision -ne 0){throw 'CSV preview changed the catalog or omitted the review diff.'}
$ErrorActionPreference='Continue'
& $engine -NoProfile -NonInteractive -File $entry -Action ImportCsvPreview -Workspace $workspace -PairId $c.PairId -Path $csv -ExpectedHash $csvPreview.SourceHash -ExpectedRevision 1 *> (Join-Path $root 'csv-preview-revision.log')
if($LASTEXITCODE -ne 4){throw 'CSV preview must honor an explicitly supplied expected revision.'}
& $engine -NoProfile -NonInteractive -File $entry -Action ImportCsv -Workspace $workspace -PairId $c.PairId -Path $csv *> (Join-Path $root 'csv-no-preview-binding.log')
if($LASTEXITCODE -ne 4){throw 'CSV apply without preview hash/revision must return 4.'}
$ErrorActionPreference='Stop'
& $engine -NoProfile -NonInteractive -File $entry -Action ImportCsv -Workspace $workspace -PairId $c.PairId -Path $csv -ExpectedHash $csvPreview.SourceHash -ExpectedRevision $csvPreview.DecisionRevision *> (Join-Path $root 'csv-apply.log')
if($LASTEXITCODE -ne 0 -or (Get-WsmCatalog $workspace $c.PairId).Items[0].Decision -cne 'Exclude'){throw 'CSV preview-bound apply did not commit the reviewed decision.'}
$ErrorActionPreference='Continue'
& $engine -NoProfile -NonInteractive -File $entry -Action ImportCsv -Workspace $workspace -PairId $c.PairId -Path $csv -ExpectedHash $csvPreview.SourceHash -ExpectedRevision $csvPreview.DecisionRevision *> (Join-Path $root 'csv-stale-preview.log')
if($LASTEXITCODE -ne 4){throw 'CSV stale preview revision must return 4.'}
$ErrorActionPreference='Stop'
if((Get-WsmCatalog $workspace $c.PairId).DecisionRevision -ne 1){throw 'Rejected stale CSV preview changed review state.'}
Write-Host ('PASS: CLI success 0, blocked 2, invalid action/hash 4, rejected input retains state. Evidence: '+$root)
# CI wrappers inherit native LASTEXITCODE; the expected rejection above is not a test failure.
$global:LASTEXITCODE=0
exit 0
