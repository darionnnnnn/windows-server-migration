#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('target-workspace-binding-'+[Guid]::NewGuid().ToString('N'))
$resolvedRoot=[IO.Path]::GetFullPath($testRoot)
[void][IO.Directory]::CreateDirectory($resolvedRoot)
try {
    & $module {
        param($Root)
        function Assert-TargetBindingTest([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
        function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=('a'*64);Name='target-fixture';OS='Windows Server fixture';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function Assert-WsmMigrationHost($Identity,[string]$Fingerprint){if($Identity.Fingerprint -cne $Fingerprint){throw 'fixture host mismatch'}}
        $workRoot=Join-Path $Root 'enrolled-target'
        $workspace=Initialize-WsmOutputWorkspace -WorkRoot $workRoot -Role Target
        $pair=[Guid]::NewGuid().ToString('D');$planHash='a'*64
        $pairWorkspace=Resolve-WsmOutputWorkspace -WorkRoot $workRoot -Role Target -PairId $pair -PlanHash $planHash
        $identityCopy=Join-Path $Root 'target-identity.json'
        $registered=Register-WsmTarget -StateDirectory $workspace.StateDirectory -Path $identityCopy
        $canonical=Read-WsmJson (Join-Path $workRoot ('targets\'+$workspace.HostId+'\target-identity.json'))
        $copy=Read-WsmJson $identityCopy
        Assert-TargetBindingTest ($registered.Enrolled -and $registered.HostId -ceq $workspace.HostId -and $registered.StateDirectory -ceq $workspace.StateDirectory) 'Profile-aware registration did not use the enrolled target workspace.'
        Assert-TargetBindingTest ($canonical.HostId -ceq $workspace.HostId -and $copy.HostId -ceq $workspace.HostId -and $registered.Target.HostId -ceq $workspace.HostId) 'Register-WsmTarget created an identity separate from the enrollment.'
        Assert-TargetBindingTest ($pairWorkspace.StateDirectory -ceq (Join-Path $workRoot 'pairs') -and $pairWorkspace.PairRoot -ceq (Join-Path $workRoot ('pairs\'+$pair))) 'Enrolled pair root would append PairId twice or use an attempt path as operation state.'
        $legacyState=Join-Path $Root 'legacy-state';$legacyCopy=Join-Path $Root 'legacy-target-identity.json'
        $legacy=Register-WsmTarget -StateDirectory $legacyState -Path $legacyCopy
        Assert-TargetBindingTest ((-not $legacy.PSObject.Properties['Enrolled']) -and (Read-WsmJson $legacyCopy).Fingerprint -ceq ('a'*64)) 'Legacy Register-WsmTarget API compatibility was lost.'
    } $resolvedRoot
    Write-Host 'Target output enrollment, stable target identity, pair-state mapping, and legacy registration compatibility passed.'
} finally {
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if($resolvedRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedRoot) -match '^target-workspace-binding-[a-f0-9]{32}$'){
        if([IO.Directory]::Exists($resolvedRoot)){Remove-Item -LiteralPath $resolvedRoot -Recurse -Force}
    }
}
