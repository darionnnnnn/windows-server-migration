#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('manager-output-workspace-'+[Guid]::NewGuid().ToString('N'))
$resolvedRoot=[IO.Path]::GetFullPath($testRoot)
[void][IO.Directory]::CreateDirectory($resolvedRoot)
try {
    & $module {
        param($Root)
        function Assert-ManagerOutputTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
        function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=('a'*64);Name='manager-fixture';OS='Windows Server fixture';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        $pair=[Guid]::NewGuid().ToString('D');$catalog=[pscustomobject]@{PairId=$pair;InventoryHash=('b'*64)}
        $workRoot=Join-Path $Root 'manager-workroot'
        $enrollment=Initialize-WsmOutputWorkspace -WorkRoot $workRoot -Role Manager
        $pending=Resolve-WsmManagerWizardAttempt $workRoot $catalog $pair
        Assert-ManagerOutputTest ($enrollment.Profile.Role -ceq 'Manager' -and $pending.PendingPair -and -not $pending.PlanHash) 'First manager enrollment or pre-approval pending attempt was misclassified.'
        Assert-ManagerOutputTest ($pending.Workspace.AttemptRoot.StartsWith((Join-Path $workRoot 'attempts'),[StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($pending.Workspace.ReportsDirectory)) 'Pending-pair report attempt was not placed in the neutral enrolled output root.'
        Assert-ManagerOutputTest (-not [IO.File]::Exists((Join-Path (Join-Path $workRoot 'hosts') ($enrollment.Profile.Fingerprint+'\pair-bindings\'+$pair+'.json')))) 'Manager used inventory data as an approved plan hash.'
        $approvedHash='c'*64;$approvedCatalog=[pscustomobject]@{PairId=$pair;InventoryHash=('b'*64);Approval=[pscustomobject]@{Kind='MigrationPlan';Hash=$approvedHash}}
        $approved=Resolve-WsmManagerWizardAttempt $workRoot $approvedCatalog $pair
        $bindingPath=Join-Path (Join-Path $workRoot 'hosts') ($enrollment.Profile.Fingerprint+'\pair-bindings\'+$pair+'.json')
        $binding=Read-WsmJson $bindingPath
        Assert-ManagerOutputTest (-not $approved.PendingPair -and $approved.PlanHash -ceq $approvedHash -and $binding.PlanHash -ceq $approvedHash) 'Approved manager attempt did not bind its exact typed plan hash.'
        Assert-ManagerOutputTest ($approved.Workspace.AttemptRoot -like ('*pairs\'+$pair+'\attempts\*') -and [IO.Directory]::Exists($approved.Workspace.ReportsDirectory)) 'Approved manager reports were not placed in the pair attempt.'
        $legacyRoot=Join-Path $Root 'legacy-manager';[void][IO.Directory]::CreateDirectory($legacyRoot);Write-WsmJson (Join-Path $legacyRoot 'fleet.json') ([pscustomobject]@{SchemaVersion=1;Kind='Fleet';BatchId=[Guid]::NewGuid().ToString();Pairs=@()})
        $blocked=$false;try{Initialize-WsmOutputWorkspace -WorkRoot $legacyRoot -Role Manager | Out-Null}catch{$blocked=$_.Exception.Message -match 'profile is missing.*explicitly migrate'}
        Assert-ManagerOutputTest ($blocked -and -not [IO.File]::Exists((Join-Path $legacyRoot 'workspace-control\output-profile.json'))) 'Manager silently adopted a legacy catalog or created a profile over existing state.'
    } $resolvedRoot
    Write-Host 'Manager enrollment, neutral pre-approval reports, typed approved-plan binding, and legacy workspace fail-closed behavior passed.'
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolvedRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedRoot) -match '^manager-output-workspace-[a-f0-9]{32}$'){
        if([IO.Directory]::Exists($resolvedRoot)){Remove-Item -LiteralPath $resolvedRoot -Recurse -Force}
    }
}
