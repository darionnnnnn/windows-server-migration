#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru
$installed=Get-Command 'Get-WsmWizardNonCPreparation' -ErrorAction Stop;if($installed.ModuleName -cne $module.Name -or [IO.Path]::GetFileName($installed.ScriptBlock.File) -cne 'WizardNonC.ps1'){throw 'Required NonC consumer is not the installed module implementation.'}
$root=Join-Path $env:TEMP ('wsm-wnonc-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    & $module {
        param($Root)
        $script:noncPreparationChecks=0
        function Check([bool]$ok,[string]$message){if(-not $ok){throw $message};$script:noncPreparationChecks++}
        function Reject([scriptblock]$action,[string]$message){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};Check $failed $message}
        $manager=Join-Path $Root 'manager';Initialize-WsmWizardWorkspace $manager Manager|Out-Null
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='NonC preparation fixture'}
        $item=New-WsmItem $source.HostId Storage PathCandidate 'Business data' 'D:\business-data' ([pscustomobject]@{OriginalPath='D:\business-data';ResolvedCandidate='D:\business-data'})
        $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $Root 'inventory.json';Write-WsmJson $inventoryPath $inventory
        $catalog=Import-WsmInventory $manager $inventoryPath (Get-FileHash -LiteralPath $inventoryPath).Hash 'New host'
        $before=@(Get-ChildItem -LiteralPath $manager -File -Recurse|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}|Sort-Object)
        $result=Get-WsmWizardNonCPreparation $manager $catalog.PairId
        $after=@(Get-ChildItem -LiteralPath $manager -File -Recurse|ForEach-Object {$_.FullName+'|'+(Get-FileHash -LiteralPath $_.FullName).Hash}|Sort-Object)
        Check (($before -join "`n") -ceq ($after -join "`n")) 'Reading NonC preparation wrote workspace materials.'
        Check ($result.Kind -ceq 'WizardNonCPreparation' -and $result.Status -ceq 'NeedsApproval') 'An unapproved inventory pretended to be a transfer plan.'
        Check ($result.ReadOnly -and -not $result.AuthoritativeApproval -and -not $result.ProductionVerified -and -not $result.CanCreateTransferPlan -and -not $result.CanImportResult) 'A preparation projection granted execution or production status.'
        Check (-not $result.Current.PlanPath -and -not $result.Entries.Count -and @($result.Gates|Where-Object code -CEQ 'ApprovedPlan').Count -eq 1) 'An unapproved projection guessed material paths or silently omitted the gate.'
        $forged=[pscustomobject]@{action='ApproveMigration';status='Succeeded';role='Manager';workspace=$manager;pairId=$catalog.PairId;jobId=[Guid]::NewGuid().ToString('D');outputs=@([pscustomobject]@{Path=$inventoryPath;SHA256=(Get-FileHash -LiteralPath $inventoryPath).Hash})}
        $result=Get-WsmWizardNonCPreparation $manager $catalog.PairId -Jobs @($forged)
        Check ($result.Status -ceq 'NeedsApproval') 'An unrelated successful job substituted for catalog approval.'
        Reject {Get-WsmWizardNonCPreparation $manager $catalog.PairId -ManifestSelection '../material.json'} 'A browser material selector accepted an arbitrary path.'
        $target=Join-Path $Root 'target';Initialize-WsmWizardWorkspace $target Target|Out-Null
        Reject {Get-WsmWizardNonCPreparation $target $catalog.PairId} 'A target workspace used the organizing-only preparation operation.'
        Write-Output ('PASS: '+$script:noncPreparationChecks+' real workspace read-only, unapproved, forged job and role/selection checks. Positive final-package transfer requires the separate transfer integration suite.')
    } $root
} finally {
    $absolute=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup escaped the owned temporary directory.'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
