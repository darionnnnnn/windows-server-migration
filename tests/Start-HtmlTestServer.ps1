param([string]$Workspace,[string]$ReadyPath,[string]$StopFile,[switch]$Seed)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {param($Workspace,$ReadyPath,$StopFile,$Seed,$console)
 . $console
 $pair=$null
 if($Seed){
  Initialize-WsmWorkspace $Workspace | Out-Null
  $hostId=[Guid]::NewGuid().ToString();$source=[pscustomobject]@{HostId=$hostId;Fingerprint=('a'*64);Name='UI fixture'}
  $items=@(for($n=0;$n -lt 125;$n++){New-WsmItem $hostId Runtime App ('Fixture '+$n+' <img src=x onerror=alert(1)>') ('fixture-'+$n) @{Version='1'}})
  $inventory=New-WsmInventory $source 1 $items
  $path=Join-Path $Workspace 'fixture-inventory.json';Write-WsmJson $path $inventory
  $catalog=Import-WsmInventory $Workspace $path ((Get-FileHash $path).Hash) 'fixture-target'
  $catalog=Enable-WsmAssistiveMode $Workspace $catalog.PairId $catalog.DecisionRevision
  $pair=$catalog.PairId
 }
 Start-WsmHtmlConsole -Workspace $Workspace -PairId $pair -Role Manager -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile
} $Workspace $ReadyPath $StopFile $Seed (Join-Path $PSScriptRoot '..\src\HtmlConsole.ps1')
