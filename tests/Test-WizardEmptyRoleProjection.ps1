#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-empty-role-projection-'+[Guid]::NewGuid().ToString('N').Substring(0,10))
[void][IO.Directory]::CreateDirectory($root)
$checks=0

function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()){& $script:module $Block @Arguments}

try {
    # These are test-only local observations. No identities or approvals are
    # written into a role workspace before the real first-use enrollment call.
    CallModule {
        $script:emptyProjectionFingerprint=('a'*64)
        function script:Get-WsmMachineIdentity {
            [pscustomobject]@{Fingerprint=$script:emptyProjectionFingerprint;Name='TEST-ONLY-empty-role-observation';OS='TEST-ONLY Windows Server';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}
        }
        function script:Get-WsmPreflight {
            [pscustomobject]@{OS='TEST-ONLY Windows Server';Version='10.0';Build='20348';Edition='Datacenter';InstallationType='Server';Architecture='x64';IsServer=$true;Administrator=$true;Is64Bit=$true;PowerShellVersion=$PSVersionTable.PSVersion.ToString();ExecutionPolicy='RemoteSigned';LanguageMode='FullLanguage';InventoryOnly=$true;RestoreSupported=$false}
        }
    }

    foreach($role in @('Source','Target')){
        $roleRoot=Join-Path $root $role.ToLowerInvariant()
        [void][IO.Directory]::CreateDirectory($roleRoot)
        $fingerprint=if($role -ceq 'Source'){'a'*64}else{'b'*64}
        CallModule {param($value) $script:emptyProjectionFingerprint=$value} @($fingerprint)

        $firstUse=CallModule {param($workspace,$requestedRole) Get-WsmHtmlWizardProjection $workspace '' $requestedRole @{} } @($roleRoot,$role)
        Check ($firstUse.intentRequired -eq $true) ($role+' empty un-enrolled workspace did not require an explicit first-use intent.')

        $enrolled=CallModule {param($workspace,$requestedRole) Initialize-WsmWizardWorkspace -Workspace $workspace -Role $requestedRole } @($roleRoot,$role)
        Check ($enrolled.Role -ceq $role -and $enrolled.Fingerprint -ceq $fingerprint) ($role+' enrollment did not use its controlled test-only observation.')

        $htmlProjection=CallModule {param($workspace,$requestedRole) Get-WsmHtmlWizardProjection $workspace '' $requestedRole @{} } @($roleRoot,$role)
        Check (-not $htmlProjection.intentRequired -and $htmlProjection.workspaceRole -ceq $role -and $htmlProjection.currentStep -ceq 'start') ($role+' empty enrolled HTML projection was not the real initial wizard projection.')

        $nullJobProjection=CallModule {param($workspace,$requestedRole) Get-WsmWizardProjection -Workspace $workspace -Role $requestedRole -Jobs ([object[]]@($null)) } @($roleRoot,$role)
        Check ($nullJobProjection.workspaceRole -ceq $role -and $nullJobProjection.currentStep -ceq 'start') ($role+' projection failed for a job list containing a null entry.')

        $emptyJobsProjection=CallModule {param($workspace,$requestedRole) Get-WsmWizardProjection -Workspace $workspace -Role $requestedRole -Jobs ([object[]]@()) } @($roleRoot,$role)
        Check ($emptyJobsProjection.workspaceRole -ceq $role -and $emptyJobsProjection.currentStep -ceq 'start') ($role+' projection failed for an empty job list.')
    }

    Write-Output ('PASS Test-WizardEmptyRoleProjection checks='+$checks+'; TEST-ONLY identity/preflight observations; real empty workspace enrollment and projection; no approval or migration was created.')
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    $absolute=[IO.Path]::GetFullPath($root);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notlike 'wsm-empty-role-projection-*'){throw 'Unsafe empty role projection test cleanup path.'}
    if([IO.Directory]::Exists($absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
