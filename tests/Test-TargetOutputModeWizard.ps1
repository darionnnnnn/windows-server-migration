#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-target-mode-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        function Get-WsmMachineIdentity {[pscustomobject]@{Fingerprint=('a'*64);Name='target-mode-fixture';OS='Windows Server fixture';Version='10.0';IsServer=$true;Administrator=$true;Is64Bit=$true}}
        function Read-Host {param($Prompt)if(-not $script:targetModeAnswers.Count){throw 'Unexpected target mode prompt.'};$script:targetModeAnswers.Dequeue()}
        function Set-ModeAnswers($Answers){$script:targetModeAnswers=New-Object 'System.Collections.Generic.Queue[object]';foreach($answer in $Answers){$script:targetModeAnswers.Enqueue($answer)}}
        $directoryRoot=Join-Path $Root 'directory';$identityCopy=Join-Path $Root 'target-copy.json'
        Set-ModeAnswers @('3','1',$directoryRoot,'Directory',$identityCopy,'0')
        Show-WsmMigrationWizard 'unused-catalog'
        if($script:targetModeAnswers.Count){throw 'Directory enrollment left unanswered prompts.'}
        $profile=Read-WsmJson (Join-Path $directoryRoot 'workspace-control\output-profile.json')
        if($profile.Mode -cne 'Directory' -or $profile.VolumeBytes -ne 0){throw 'Target wizard did not persist Directory selection.'}
        $identityHash=(Get-FileHash -LiteralPath $identityCopy).Hash
        Set-ModeAnswers @('3','1',$directoryRoot,$identityCopy,'0')
        Show-WsmMigrationWizard 'unused-catalog'
        if($script:targetModeAnswers.Count -or (Get-FileHash -LiteralPath $identityCopy).Hash -cne $identityHash){throw 'Existing enrollment prompted a new mode or changed its target identity.'}
        $zipRoot=Join-Path $Root 'zip';Set-ModeAnswers @('','')
        $zip=Initialize-WsmWizardTargetOutput $zipRoot
        if($zip.Profile.Mode -cne 'Zip' -or $zip.Profile.VolumeBytes -ne 512MB){throw 'Default target wizard ZIP preferences differ from 512 MiB.'}
        if($script:targetModeAnswers.Count -ne 0){throw 'ZIP initialization did not consume exactly its mode and size prompts.'}
        $cancelRoot=Join-Path $Root 'cancelled';Set-ModeAnswers @('0');$cancelled=$false
        try{Initialize-WsmWizardTargetOutput $cancelRoot|Out-Null}catch [OperationCanceledException]{$cancelled=$true}
        if(-not $cancelled -or [IO.Directory]::Exists($cancelRoot)){throw 'Cancelled first enrollment created a target workspace.'}
        'PASS: real target role wizard persists selected Directory, reuses stable identity without reprompting mode, defaults ZIP to 512 MiB, and cancellation leaves no workspace.'
    } $root
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe target wizard cleanup path.'}
    if([IO.Directory]::Exists($resolved)){[IO.Directory]::Delete($resolved,$true)}
}
