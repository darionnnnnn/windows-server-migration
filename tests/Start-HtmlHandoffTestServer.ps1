param([string]$Workspace,[string]$ReadyPath,[string]$StopFile,[ValidateSet('Source','Manager')][string]$Role='Manager',[switch]$SeedSource)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {param($Workspace,$ReadyPath,$StopFile,$Role,$SeedSource,$console)
 . $console
 $pair=$null
 if($SeedSource){
  if($Role -cne 'Source'){throw 'SeedSource requires the Source role.'}
  $outputWorkspace=Initialize-WsmOutputWorkspace -WorkRoot $Workspace -Role Source
  $source=[pscustomobject]@{HostId=$outputWorkspace.Profile.HostId;Fingerprint=$outputWorkspace.Profile.Fingerprint;Name='Native handoff fixture source'}
  $items=@(New-WsmItem $source.HostId Web IISSite 'Native handoff site' 'Default Web Site' ([pscustomobject][ordered]@{Xml='<site name="Default Web Site" />'}))
  $inventory=New-WsmInventory $source 1 $items
  $inventoryPath=Join-Path $outputWorkspace.InventoryDirectory 'inventory-1.json'
  Write-WsmJson $inventoryPath $inventory|Out-Null
  $hash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $job=[pscustomobject][ordered]@{jobId=[Guid]::NewGuid().ToString('D');action='Inventory';idempotencyKey=[Guid]::NewGuid().ToString('D');RequestHash=('a'*64);workspace=[IO.Path]::GetFullPath($Workspace);pairId='';role='Source';status='Succeeded';CompletedUtc=(Get-WsmUtc);outputs=@([pscustomobject]@{Path=[IO.Path]::GetFullPath($inventoryPath);SHA256=$hash})}
  $jobsRoot=Join-Path $Workspace 'console-jobs';[void][IO.Directory]::CreateDirectory($jobsRoot);Write-WsmJson (Join-Path $jobsRoot ($job.jobId+'.json')) $job|Out-Null
  [void](Register-WsmWizardOperationJob $Workspace $job)
  $bound=Set-WsmWizardInventoryBinding -Workspace $Workspace -Role Source -JobId $job.jobId -ExpectedWizardRevision 1 -Jobs @($job)
  [void](Set-WsmWizardState -Workspace $Workspace -PairId '' -Role Source -ExpectedWizardRevision $bound.Revision -Changes ([pscustomobject]@{CurrentStep='review';Mode='ItemByItem'}))
 }
 if($Role -ceq 'Manager' -and -not $SeedSource){
  Initialize-WsmOutputWorkspace -WorkRoot $Workspace -Role Manager|Out-Null
  Initialize-WsmWorkspace $Workspace|Out-Null
  [void](Set-WsmWizardState -Workspace $Workspace -PairId '' -Role Manager -ExpectedWizardRevision 0 -Changes ([pscustomobject]@{CurrentStep='handoff';Mode='ItemByItem'}))
 }
 Start-WsmHtmlConsole -Workspace $Workspace -PairId $pair -Role $Role -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile
} $Workspace $ReadyPath $StopFile $Role $SeedSource (Join-Path $PSScriptRoot '..\src\HtmlConsole.ps1')
