#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path 'C:\' ('wsm-fleet-binding-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
& $module {
    param($Root)
    $workspace=Join-Path $Root 'manager';Initialize-WsmWorkspace $workspace | Out-Null
    $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='binding-source'}
    $inventory=New-WsmInventory $source 1 @((New-WsmItem $source.HostId Services Service 'fixture' 'fixture' @{Name='fixture'}))
    $path=Join-Path $Root 'inventory.json';Write-WsmJson $path $inventory;$catalog=Import-WsmInventory $workspace $path (Get-FileHash -LiteralPath $path).Hash 'binding-target'
    # These are synthetic manager approval bindings; this test does not qualify a Server or adapter.
    $catalog.Approval=[pscustomobject]@{Kind='MigrationPlan';ApprovalId=[Guid]::NewGuid().ToString();Hash=('b'*64);TargetHostId=[Guid]::NewGuid().ToString();TargetFingerprint=('c'*64)}
    Write-WsmJson (Get-WsmCatalogPath $workspace $catalog.PairId) $catalog
    $sourceRun=[Guid]::NewGuid().ToString();$targetRun=[Guid]::NewGuid().ToString();$now=[DateTimeOffset]::UtcNow
    function New-BindingResult($Stage,$Status,$Sequence,$Generation,$ManifestHash,$Minutes) {
        [pscustomobject]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='StageResult';BatchId=$catalog.BatchId;PairId=$catalog.PairId;SourceHostId=$source.HostId;RunId=$(if($Stage -cin @('Export','FinalDelta')){$sourceRun}else{$targetRun});Sequence=$Sequence;Stage=$Stage;Status=$Status;InventoryRevision=$catalog.InventoryRevision;DecisionRevision=$catalog.DecisionRevision;ProducedUtc=$now.AddMinutes($Minutes).ToString('o');Mode='IsolatedPilot';ProductionVerified=$false;ApprovalId=$catalog.Approval.ApprovalId;PlanHash=$catalog.Approval.Hash;TargetHostId=$catalog.Approval.TargetHostId;TargetFingerprint=$catalog.Approval.TargetFingerprint;ManifestHash=$ManifestHash;PayloadGeneration=$Generation;JournalHash=('e'*64)}
    }
    function Submit-BindingResult($Result) {$p=Join-Path $Root ([Guid]::NewGuid().ToString('N')+'.json');Write-WsmJson $p $Result;Import-WsmStageResult $workspace $p (Get-FileHash -LiteralPath $p).Hash}
    function Reject-BindingResult($Result) {$before=(Get-FileHash -LiteralPath (Get-WsmCatalogPath $workspace $catalog.PairId)).Hash;$blocked=$false;try{Submit-BindingResult $Result}catch{$blocked=$true};if(-not $blocked -or (Get-FileHash -LiteralPath (Get-WsmCatalogPath $workspace $catalog.PairId)).Hash -cne $before){throw 'Invalid result accepted or changed manager evidence.'}}
    foreach($status in @('Failed','Blocked','RetryPending','Partial','Cancelled','Succeeded')){
        $r=New-BindingResult Restore $status 1 1 ('f'*64) -8;$r.TargetHostId=[Guid]::NewGuid().ToString();Reject-BindingResult $r
        $r=New-BindingResult Restore $status 1 1 ('f'*64) -8;$r.TargetFingerprint='0'*64;Reject-BindingResult $r
        $r=New-BindingResult Restore $status 1 1 ('f'*64) -8;$r.PSObject.Properties.Remove('ApprovalId');Reject-BindingResult $r
    }
    Submit-BindingResult (New-BindingResult Export Succeeded 1 1 ('f'*64) -10)
    Submit-BindingResult (New-BindingResult Restore Failed 1 1 ('f'*64) -8)
    Reject-BindingResult (New-BindingResult Restore Blocked 2 1 ('0'*64) -7)
    $r=New-BindingResult Cutover Blocked 2 1 ('f'*64) -7;$r.RunId=[Guid]::NewGuid().ToString();Reject-BindingResult $r
    Reject-BindingResult (New-BindingResult Cutover Blocked 1 1 ('f'*64) -7)
    Reject-BindingResult (New-BindingResult Cutover Blocked 2 1 ('f'*64) -9)
    Submit-BindingResult (New-BindingResult Restore Failed 2 2 ('d'*64) -3)
    Reject-BindingResult (New-BindingResult FinalDelta Succeeded 2 1 ('f'*64) -2)
    # Offline arrival order is deliberately different from production order across the two producers.
    Submit-BindingResult (New-BindingResult FinalDelta Succeeded 2 2 ('d'*64) -4)
    $current=Get-WsmCatalog $workspace $catalog.PairId;$latest=Get-WsmLatestStageResult $current
    if($latest.Stage -cne 'Restore' -or $latest.Status -cne 'Failed' -or $latest.PayloadGeneration -ne 2){throw 'Last-arriving older source receipt hid the newer target result.'}
    $summary=Get-WsmStageResultSummary $current;if($summary -notmatch 'FinalDelta:Succeeded' -or $summary -notmatch 'Restore:Failed' -or $summary -match 'Export:'){throw 'Per-stage summary mixed old generations or hid failed stage.'}
    $report=Join-Path $Root 'fleet.html';Export-WsmFleetReport $workspace $report
    $html=[IO.File]::ReadAllText($report);if(-not $html.Contains('StageSummary') -or -not $html.Contains('Restore:Failed')){throw 'Fleet report consumer lost binding-aware stage summary.'}
    $current.Approval.ApprovalId=[Guid]::NewGuid().ToString();if(Test-WsmStageResultCurrent $current $latest){throw 'Old approval result remained current after reapproval.'}
    # A new approval starts a separate producer lineage; stale sequences/runs from
    # the old approval must neither block it nor be shown as current evidence.
    $current.Approval.Hash='9'*64;$catalog=$current;$targetRun=[Guid]::NewGuid().ToString()
    Write-WsmJson (Get-WsmCatalogPath $workspace $catalog.PairId) $catalog
    Submit-BindingResult (New-BindingResult Restore Succeeded 1 1 ('8'*64) 0)
    $renewed=Get-WsmCatalog $workspace $catalog.PairId;$renewedLatest=Get-WsmLatestStageResult $renewed
    if($renewedLatest.ApprovalId -cne $catalog.Approval.ApprovalId -or $renewedLatest.RunId -cne $targetRun -or $renewedLatest.Sequence -ne 1 -or $renewedLatest.PayloadGeneration -ne 1){throw 'Fresh approval could not start its own producer sequence/generation.'}
    if((Get-WsmStageResultSummary $renewed) -cne 'Restore:Succeeded'){throw 'New approval report mixed evidence from a previous approval.'}
    Write-Host 'PASS: all non-Inventory statuses bind target/plan/generation; mismatches preserve catalog; producer sequence/run/time regressions rejected; offline report sorts production time and summarizes current generation.'
} $root
$resolved=[IO.Path]::GetFullPath($root).TrimEnd('\');if($resolved -notmatch '^C:\\wsm-fleet-binding-[a-f0-9]{32}$'){throw 'Unsafe test cleanup root'};Remove-Item -LiteralPath $resolved -Recurse -Force
