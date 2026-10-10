#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$helper=Join-Path $PSScriptRoot '..\src\AssistiveProbe.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-probe-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    & $module {
        param($root,$helper)
        . $helper
        $identity=Get-WsmMachineIdentity
        $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=$identity.Fingerprint;Name='probe fixture source'}
        $item=New-WsmItem $source.HostId Runtime App 'fixture' 'fixture' @{Version='1'}
        $inventory=New-WsmInventory $source 1 @($item)
        $inventoryPath=Join-Path $root 'inventory.json';Write-WsmJson $inventoryPath $inventory
        $workspace=Join-Path $root 'manager';Initialize-WsmWorkspace $workspace | Out-Null
        $catalog=Import-WsmInventory $workspace $inventoryPath (Get-FileHash $inventoryPath).Hash 'target'
        $catalog=Enable-WsmAssistiveMode $workspace $catalog.PairId $catalog.DecisionRevision
        $result=Export-WsmAssistiveEnvironmentProbe -OutputDirectory (Join-Path $root 'probes') -Role Source -PairId $catalog.PairId
        $probe=Read-WsmTrustedJson $result.Path $result.SHA256
        if($probe.Mode -cne 'ReadOnly' -or $probe.ProductionQualified -or $probe.BusinessValidated){throw 'Probe falsely promoted observation to qualification.'}
        if(@($probe.Checks|Where-Object {$_.CheckId -eq 'NativeTaskReadback' -and $_.Status -eq 'NotTested'}).Count -ne 1){throw 'Missing explicit native task validation requirement.'}
        if(-not [IO.File]::Exists($result.HtmlPath) -or $result.PendingChecks -lt 8){throw 'Probe pending checklist or HTML evidence missing.'}
        $import=Import-WsmAssistiveEnvironmentProbe -Workspace $workspace -PairId $catalog.PairId -Path $result.Path -ExpectedHash $result.SHA256 -ExpectedRevision $catalog.Assistive.Revision
        if($import.Status -ne 'ImportedVerified' -or $import.ProductionQualified){throw 'Probe import did not preserve read-only evidence semantics.'}
        $catalog=Get-WsmCatalog $workspace $catalog.PairId
        $portable=$probe.PSObject.Copy();$portable.RunId=[Guid]::NewGuid().ToString();$portable.InventoryReference='protected-inventory/native.json';$portable.InventoryHash=(Get-FileHash $inventoryPath).Hash.ToLowerInvariant()
        $bundle=Join-Path $root 'portable';[void][IO.Directory]::CreateDirectory((Join-Path $bundle 'protected-inventory'));[IO.File]::Copy($inventoryPath,(Join-Path $bundle $portable.InventoryReference))
        $portablePath=Join-Path $bundle 'probe.json';Write-WsmJson $portablePath $portable
        Import-WsmAssistiveEnvironmentProbe $workspace $catalog.PairId $portablePath (Get-FileHash $portablePath).Hash $catalog.Assistive.Revision | Out-Null
        $catalog=Get-WsmCatalog $workspace $catalog.PairId
        $raw=@($catalog.Assistive.ResultReferences|Where-Object Kind -EQ AssistiveProbeInventory)
        if($raw.Count -ne 1 -or -not [IO.File]::Exists((Join-Path $workspace $raw[0].Reference))){throw 'Portable probe lost protected source inventory bytes.'}
        [IO.File]::AppendAllText((Join-Path $bundle $portable.InventoryReference),'tampered')
        $portable.RunId=[Guid]::NewGuid().ToString();Write-WsmJson $portablePath $portable
        $reject=$false;try{Import-WsmAssistiveEnvironmentProbe $workspace $catalog.PairId $portablePath (Get-FileHash $portablePath).Hash $catalog.Assistive.Revision | Out-Null}catch{$reject=$true};if(-not $reject){throw 'Portable raw inventory tampering was accepted.'}
        $reject=$false;try{Import-WsmAssistiveEnvironmentProbe $workspace $catalog.PairId $result.Path $result.SHA256 $catalog.Assistive.Revision | Out-Null}catch{$reject=$true};if(-not $reject){throw 'Duplicate probe evidence was accepted.'}
        $probe.ProductionQualified=$true;$forged=Join-Path $root 'forged.json';Write-WsmJson $forged $probe
        $reject=$false;try{Import-WsmAssistiveEnvironmentProbe $workspace $catalog.PairId $forged (Get-FileHash $forged).Hash $catalog.Assistive.Revision | Out-Null}catch{$reject=$true};if(-not $reject){throw 'Read-only probe claimed production qualification.'}
        $probe.ProductionQualified=$false;$probe.CreatedUtc=[DateTime]::UtcNow.AddDays(-5).ToString('o');Write-WsmJson $forged $probe
        $reject=$false;try{Import-WsmAssistiveEnvironmentProbe $workspace $catalog.PairId $forged (Get-FileHash $forged).Hash $catalog.Assistive.Revision | Out-Null}catch{$reject=$true};if(-not $reject){throw 'Stale probe was accepted.'}
        Write-Host 'PASS: executable local read-only probe, HTML, trusted import, duplicates, qualification and stale evidence guards.'
    } $root $helper
}finally{if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force}}
