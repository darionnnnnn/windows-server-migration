#requires -Version 5.1
# Minimal reproduction of N9f-D3 (not a regression test; it is expected to FAIL while the defect exists).
# A Source inventory that carries a SourceResolutionContext (N9c, always written by Export-WsmInventory) and a SoftwareCatalog
# (-IncludeSoftwareCatalog) binds the catalog to a projection hash that includes SourceResolutionContextHash. The Manager imports it
# (Import-WsmInventory validates against the original inventory object), but every later Get-WsmCatalog validates the catalog against
# Get-WsmCatalogInventoryProjection, which rebuilds an inventory WITHOUT the context, so the hash can never match again.
# Control: the same inventory without the context imports and reads back.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-n9f-d3-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try{
    & $module {
        param($Root)
        function New-Case([bool]$WithContext,[string]$Name){
            $hostId=[Guid]::NewGuid().ToString('D');$source=[pscustomobject]@{HostId=$hostId;Fingerprint=('a'*64);Name='D3-Source'}
            $inventory=New-WsmInventory $source 1 @((New-WsmItem $hostId Storage DataRoot 'D3 scope' 'd3-scope' @{Path='C:\d3'}))
            $now=[DateTime]::UtcNow.ToString('o')
            if($WithContext){$inventory|Add-Member NoteProperty SourceResolutionContext ([pscustomobject][ordered]@{SchemaVersion=1;Kind='SourceResolutionContext';HostId=$hostId;ObservedUtc=$now;MachineEnvironmentStatus='Success';MachineEnvironment=@([pscustomobject][ordered]@{Name='D3_ROOT';Value='C:\d3';Origin='MachineEnvironment'});ExcludedEnvironmentNames=@();ProfileListStatus='Success';Accounts=@();Note='repro'}) -Force}
            $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$hostId;Fingerprint=$source.Fingerprint;Name=$source.Name;InventoryRevision=1;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=$now;CaptureIdentity='repro';AccountContext='Machine';CaptureHost='repro';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind='';ObservedUtc=$now});PreparationRequirements=@();CatalogProjectionHash=('0'*64)}
            $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
            $inventory|Add-Member NoteProperty SoftwareCatalog $catalog -Force
            $path=Join-Path $Root ($Name+'.json');Write-WsmJson $path $inventory
            $manager=Join-Path $Root ('m-'+$Name);Initialize-WsmWorkspace $manager|Out-Null
            $imported=Import-WsmInventory -Workspace $manager -Path $path -ExpectedHash ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()) -TargetName 'D3-Target'
            $readBack='';try{[void](Get-WsmCatalog $manager $imported.PairId);$readBack='OK'}catch{$readBack='THROWS: '+$_.Exception.Message}
            [pscustomobject]@{Case=$Name;ImportSucceeded=$true;ReadBack=$readBack}
        }
        $control=New-Case $false 'without-context'
        $defect=New-Case $true 'with-context'
        $control|Format-List|Out-String|Write-Host
        $defect|Format-List|Out-String|Write-Host
        if($control.ReadBack -cne 'OK'){throw 'Control case failed unexpectedly.'}
        if($defect.ReadBack -cne 'OK'){throw ('N9f-D3 reproduced: '+$defect.ReadBack)}
        Write-Host 'N9f-D3 not reproduced (defect fixed).'
    } $root
}finally{
    if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
