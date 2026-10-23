#requires -Version 5.1
# N9h-D3 regression (introduced by N9c, found by N9f): a Source inventory that carries a SourceResolutionContext AND a SoftwareCatalog
# (Export-WsmInventory -IncludeSoftwareCatalog) binds the catalog to a projection hash that includes SourceResolutionContextHash.
# The Manager must keep the imported context in its catalog so every later Get-WsmCatalog rebuilds the same projection.
# Binding strength must not drop: any tampering with the context (inventory file, stored catalog, added or removed) is rejected.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$module=Import-Module (Join-Path $repo 'src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking 3>$null
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-n9h-d3-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($root)
try{
    $checks=& $module {
        param($Root)
        $script:Checks=0
        function Check($Condition,[string]$Message){if(-not $Condition){throw ('FAIL: '+$Message)};$script:Checks++}
        # The context comes from the real builder with mocked Source facts (the test host is not a Server).
        function Get-WsmMachineEnvironment { @{ 'D3_ROOT'='C:\d3'; 'TEMP'='C:\Windows\TEMP'; 'D3_SECRET_TOKEN'='must-not-be-stored' } }
        function Get-WsmResolutionSystemEnvironment { [ordered]@{ SystemRoot='C:\Windows'; SystemDrive='C:'; ProgramData='C:\ProgramData'; ProgramFiles='C:\Program Files' } }
        function Get-WsmResolutionProfileList { [pscustomobject]@{Status='Success';Map=[ordered]@{ 'S-1-5-18'='%systemroot%\system32\config\systemprofile'; 'S-1-5-21-1-2-3-1001'='%SystemDrive%\Users\svcuser' }} }
        function Resolve-WsmAccountToSid([string]$Account) { switch ($Account) { '.\svcuser' {'S-1-5-21-1-2-3-1001'} default {$null} } }
        function New-Source([string]$Name){$hostId=[Guid]::NewGuid().ToString('D');[pscustomobject]@{HostId=$hostId;Fingerprint=([Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N'));Name=$Name}}
        function New-SourceInventory($Source,[int]$Revision,[bool]$WithContext,$ContextOverride=$null){
            $hostId=$Source.HostId
            $items=@((New-WsmItem $hostId Storage DataRoot 'D3 scope' 'd3-scope' @{Path='C:\d3'}),(New-WsmItem $hostId Services Service 'd3svc' 'd3svc' @{StartName='.\svcuser'}))
            $inventory=New-WsmInventory $Source $Revision $items
            if($WithContext){
                $context=if($null -ne $ContextOverride){$ContextOverride}else{Get-WsmSourceResolutionContext $hostId $items}
                $inventory|Add-Member NoteProperty SourceResolutionContext $context -Force
            }
            $now=[DateTime]::UtcNow.ToString('o')
            $catalog=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion=$script:ToolVersion;Kind='SoftwareCatalog';Source=[pscustomobject]@{HostId=$hostId;Fingerprint=$Source.Fingerprint;Name=$Source.Name;InventoryRevision=$Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inventory)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=$now;CaptureIdentity='n9h-d3';AccountContext='Machine';CaptureHost='n9h-d3';PowerShellVersion='5.1';RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=10};ErrorKind='';ObservedUtc=$now});PreparationRequirements=@();CatalogProjectionHash=('0'*64)}
            $catalog.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $catalog
            $inventory|Add-Member NoteProperty SoftwareCatalog $catalog -Force
            $inventory
        }
        function Write-Inventory($Inventory,[string]$Name){$path=Join-Path $Root ($Name+'.json');Write-WsmJson $path $Inventory;[pscustomobject]@{Path=$path;Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}}
        function New-Manager([string]$Name){$manager=Join-Path $Root ('m-'+$Name);Initialize-WsmWorkspace $manager|Out-Null;$manager}
        function Read-Back($Manager,$PairId){try{$catalog=Get-WsmCatalog $Manager $PairId;[pscustomobject]@{Ok=$true;Catalog=$catalog;Error=''}}catch{[pscustomobject]@{Ok=$false;Catalog=$null;Error=[string]$_.Exception.Message}}}
        function Edit-StoredCatalog($Manager,$PairId,[scriptblock]$Edit){$path=Get-WsmCatalogPath $Manager $PairId;$stored=Read-WsmJson $path;& $Edit $stored;Write-WsmJson $path $stored}

        # 1. Control: no context in the inventory -> import and read back, catalog keeps no context.
        $controlSource=New-Source 'D3-Control';$controlInventory=New-SourceInventory $controlSource 1 $false
        $controlFile=Write-Inventory $controlInventory 'control';$controlManager=New-Manager 'control'
        $controlImported=Import-WsmInventory -Workspace $controlManager -Path $controlFile.Path -ExpectedHash $controlFile.Hash -TargetName 'D3-Target-Control'
        $controlRead=Read-Back $controlManager $controlImported.PairId
        Check $controlRead.Ok ('control (no context) must read back: '+$controlRead.Error)
        Check (-not $controlRead.Catalog.PSObject.Properties['SourceResolutionContext']) 'a context-less inventory must not invent a catalog context'

        # 2. The defect: real builder context + software catalog -> import AND every later read must succeed.
        $source=New-Source 'D3-Source';$inventory=New-SourceInventory $source 1 $true
        Check ($inventory.PSObject.Properties['SourceResolutionContext'] -and @($inventory.SourceResolutionContext.MachineEnvironment|Where-Object Name -ceq 'D3_ROOT').Count -eq 1) 'fixture context must come from the real builder and carry the machine variable'
        Check (@($inventory.SourceResolutionContext.ExcludedEnvironmentNames) -contains 'D3_SECRET_TOKEN') 'fixture context must exclude the secret-looking variable'
        $file=Write-Inventory $inventory 'with-context';$manager=New-Manager 'with-context'
        $imported=Import-WsmInventory -Workspace $manager -Path $file.Path -ExpectedHash $file.Hash -TargetName 'D3-Target'
        $first=Read-Back $manager $imported.PairId
        Check $first.Ok ('first Get-WsmCatalog after import must succeed: '+$first.Error)
        $second=Read-Back $manager $imported.PairId
        Check $second.Ok ('a second Get-WsmCatalog must also succeed: '+$second.Error)
        $originalHash=Get-WsmSourceResolutionContextHash $inventory.SourceResolutionContext
        Check ($first.Catalog.PSObject.Properties['SourceResolutionContext'] -and (Get-WsmSourceResolutionContextHash $first.Catalog.SourceResolutionContext) -ceq $originalHash) 'the catalog must keep the imported context (same SourceResolutionContextHash)'
        $projection=Get-WsmCatalogInventoryProjection $first.Catalog
        Check ((Get-WsmSoftwareInventoryProjectionHash $projection) -ceq [string]$first.Catalog.SoftwareCatalog.Source.InventoryProjectionHash) 'the rebuilt projection must reproduce the catalog InventoryProjectionHash'
        Check ((Get-WsmSoftwareInventoryProjectionHash $inventory) -ceq (Get-WsmSoftwareInventoryProjectionHash $projection)) 'the rebuilt projection hash must equal the original inventory projection hash'

        # 3. A later revision from the same Source (Import reads the old catalog) must also import, then read back.
        $inventory2=New-SourceInventory $source 2 $true
        $file2=Write-Inventory $inventory2 'with-context-r2'
        $imported2=Import-WsmInventory -Workspace $manager -Path $file2.Path -ExpectedHash $file2.Hash -TargetName 'D3-Target'
        $afterSecond=Read-Back $manager $imported2.PairId
        Check ($imported2.PairId -ceq $imported.PairId -and $afterSecond.Ok) ('a revision-2 import over a context-bearing catalog must succeed and read back: '+$afterSecond.Error)

        # 4. Binding strength: tampering is rejected at every place the context lives.
        # 4a. Tampered inside the inventory file before import (catalog projection hash was computed over the original context).
        $tamperSource=New-Source 'D3-TamperInv';$tamperInventory=New-SourceInventory $tamperSource 1 $true
        $tamperInventory.SourceResolutionContext.MachineEnvironment=@($tamperInventory.SourceResolutionContext.MachineEnvironment|ForEach-Object{if($_.Name -ceq 'D3_ROOT'){[pscustomobject][ordered]@{Name=$_.Name;Value='C:\evil';Origin=$_.Origin}}else{$_}})
        $tamperFile=Write-Inventory $tamperInventory 'tamper-inventory';$tamperManager=New-Manager 'tamper-inventory'
        $rejectedImport=$false;$importMessage='';try{[void](Import-WsmInventory -Workspace $tamperManager -Path $tamperFile.Path -ExpectedHash $tamperFile.Hash -TargetName 'D3-Tamper-Inv')}catch{$rejectedImport=$true;$importMessage=[string]$_.Exception.Message}
        Check ($rejectedImport -and $importMessage -match 'does not bind') ('a context changed inside the inventory file must be rejected at import with the binding error: '+$importMessage)
        # 4b. Tampered in the stored catalog after a good import.
        Edit-StoredCatalog $manager $imported2.PairId {param($stored)$row=@($stored.SourceResolutionContext.MachineEnvironment|Where-Object Name -ceq 'D3_ROOT')[0];$row.Value='C:\evil'}
        $tamperedValue=Read-Back $manager $imported2.PairId
        Check ((-not $tamperedValue.Ok) -and $tamperedValue.Error -match 'does not bind') ('a stored context with a changed value must be rejected: '+$tamperedValue.Error)
        # 4c. Context removed from the stored catalog.
        $removeSource=New-Source 'D3-Remove';$removeInventory=New-SourceInventory $removeSource 1 $true;$removeFile=Write-Inventory $removeInventory 'remove';$removeManager=New-Manager 'remove'
        $removeImported=Import-WsmInventory -Workspace $removeManager -Path $removeFile.Path -ExpectedHash $removeFile.Hash -TargetName 'D3-Remove-Target'
        Check (Read-Back $removeManager $removeImported.PairId).Ok 'precondition: the untouched context-bearing catalog reads back'
        Edit-StoredCatalog $removeManager $removeImported.PairId {param($stored)$stored.PSObject.Properties.Remove('SourceResolutionContext')}
        $removed=Read-Back $removeManager $removeImported.PairId
        Check ((-not $removed.Ok) -and $removed.Error -match 'does not bind') ('a context removed from the stored catalog must be rejected: '+$removed.Error)
        # 4d. Context injected into a catalog whose inventory never had one.
        Edit-StoredCatalog $controlManager $controlImported.PairId {param($stored)$stored|Add-Member NoteProperty SourceResolutionContext $inventory.SourceResolutionContext -Force}
        $injected=Read-Back $controlManager $controlImported.PairId
        Check ((-not $injected.Ok) -and $injected.Error -match 'does not bind') ('a context injected into a context-less catalog must be rejected: '+$injected.Error)
        # 4e. Account (SID / ProfileImagePath) tampering is covered by the same hash.
        $sidSource=New-Source 'D3-Sid';$sidInventory=New-SourceInventory $sidSource 1 $true;$sidFile=Write-Inventory $sidInventory 'sid';$sidManager=New-Manager 'sid'
        $sidImported=Import-WsmInventory -Workspace $sidManager -Path $sidFile.Path -ExpectedHash $sidFile.Hash -TargetName 'D3-Sid-Target'
        Edit-StoredCatalog $sidManager $sidImported.PairId {param($stored)$account=@($stored.SourceResolutionContext.Accounts|Where-Object Account -ceq '.\svcuser')[0];$account.ProfileImagePath='C:\evil-profile'}
        $sidRead=Read-Back $sidManager $sidImported.PairId
        Check ((-not $sidRead.Ok) -and $sidRead.Error -match 'does not bind') ('a changed account ProfileImagePath must be rejected: '+$sidRead.Error)
        $script:Checks
    } $root
    Write-Host ('PASS: {0} Manager catalog source-context checks (import then read back, later revision, control without context, tampered inventory/value/removed/injected/account all rejected)' -f $checks)
}finally{
    if([IO.Directory]::Exists($root)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
}
