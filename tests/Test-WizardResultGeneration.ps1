#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru
$approval=[pscustomobject]@{ApprovalId='approval';Hash=('a'*64);TargetHostId='target';TargetFingerprint=('b'*64)}
$catalog=[pscustomobject]@{InventoryRevision=1;DecisionRevision=2;Approval=$approval;StageResults=@()}
function Result([string]$Stage,[string]$Status,[long]$Generation,[string]$Hash,[int]$Sequence){
    [pscustomobject]@{InventoryRevision=1;DecisionRevision=2;ApprovalId='approval';PlanHash=('a'*64);TargetHostId='target';TargetFingerprint=('b'*64);Stage=$Stage;Status=$Status;PayloadGeneration=$Generation;ManifestHash=$Hash;Sequence=$Sequence;RunId='fixture-run';ProducedUtc=([DateTimeOffset]::UtcNow.AddSeconds($Sequence).ToString('o'))}
}
function Projection {& $module {param($c) Get-WsmWizardStageResultAvailability $c} $catalog}
$passed=0
function Check([bool]$Value,[string]$Message){if(-not $Value){throw $Message};$script:passed++}
$old=Result Restore Succeeded 1 ('c'*64) 1
$current=Result Export Succeeded 2 ('d'*64) 2
$catalog.StageResults=@($old,$current)
$p=Projection
Check ($null -eq $p.restore -and $p.backup.generation -eq 2) 'An old restore generation remained current after a newer export.'
$catalog.StageResults=@((Result Export Running 2 ('d'*64) 3))
Check ($null -eq (Projection).backup) 'A running export opened the backup result navigation.'
foreach($status in @('Failed','Cancelled','Partial','Blocked','DeferredSoftware')){
    $catalog.StageResults=@((Result Export $status 2 ('d'*64) 3))
    Check ((Projection).backup.status -ceq $status) ('A durable terminal outcome disappeared: '+$status)
}
$catalog.StageResults=@($current,(Result Restore Succeeded 2 ('e'*64) 3))
$p=Projection
Check ($null -eq $p.backup -and $null -eq $p.restore) 'Conflicting manifests in one generation appeared current.'
$catalog.StageResults=@($current,(Result Export Running 2 ('d'*64) 3))
Check ($null -eq (Projection).backup) 'An earlier success survived a later in-progress result for the same stage.'
$foreign=Result Export Succeeded 99 ('f'*64) 4;$foreign.PlanHash='0'*64
$catalog.StageResults=@($current,$foreign)
Check ((Projection).backup.generation -eq 2) 'An unrelated plan hid the current export.'
$catalog.StageResults=@($current,(Result Restore Cancelled 2 ('d'*64) 3))
$p=Projection
Check ($p.backup.generation -eq 2 -and $p.restore.status -ceq 'Cancelled') 'Matching current backup and cancelled restore were not retained.'
$catalog.StageResults=@((Result Export Succeeded 2 '' 1))
Check ($null -eq (Projection).backup) 'Missing manifest evidence appeared current.'
Write-Output ('PASS: '+$passed+' wizard result-generation boundaries (read-only catalog projection fixture).')
