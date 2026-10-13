param([string]$Workspace,[string]$ReadyPath,[string]$StopFile,[switch]$Seed,[string]$ResponseCapturePath,[switch]$FailWizardRegistration)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {param($Workspace,$ReadyPath,$StopFile,$Seed,$console,$ResponseCapturePath,$FailWizardRegistration)
 . $console
 # Optional test-only capture of the formal handler response before socket writing.
 # This diagnoses handler contracts without claiming that native transport passed.
 if($ResponseCapturePath){
  $script:FixtureResponseCapturePath=$ResponseCapturePath
  $script:FixtureOriginalResponseWriter=${function:Write-WsmLocalHttpResponse}
  function Write-WsmLocalHttpResponse($Client,[int]$Status,[string]$ContentType,[byte[]]$Body){
   [IO.File]::WriteAllText($script:FixtureResponseCapturePath,(@{status=$Status;body=[Text.Encoding]::UTF8.GetString($Body)}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
   & $script:FixtureOriginalResponseWriter $Client $Status $ContentType $Body
  }
 }
 if($FailWizardRegistration){
  $script:FixtureOriginalWizardRegistration=${function:Register-WsmWizardOperationJob}
  function Register-WsmWizardOperationJob($Workspace,$Record){
   if($Record.action -ceq 'Initialize'){throw 'Fixture registration failure before worker start.'}
   & $script:FixtureOriginalWizardRegistration $Workspace $Record
  }
 }
 $pair=$null
 if($Seed){
  Initialize-WsmWizardWorkspace $Workspace 'Manager' | Out-Null
  Initialize-WsmWorkspace $Workspace | Out-Null
  $existing=Get-WsmFleet $Workspace
  if(@($existing.Pairs).Count){$pair=[string]$existing.Pairs[0].PairId}
  else{
   $hostId=[Guid]::NewGuid().ToString();$source=[pscustomobject]@{HostId=$hostId;Fingerprint=('a'*64);Name='UI fixture'}
   $items=@(for($n=0;$n -lt 125;$n++){New-WsmItem $hostId Runtime App ('Fixture '+$n+' <img src=x onerror=alert(1)>') ('fixture-'+$n) @{Version='1'}})
   $inventory=New-WsmInventory $source 1 $items
   $path=Join-Path $Workspace 'fixture-inventory.json';Write-WsmJson $path $inventory
   $catalog=Import-WsmInventory $Workspace $path ((Get-FileHash $path).Hash) 'fixture-target'
   $catalog=Enable-WsmAssistiveMode $Workspace $catalog.PairId $catalog.DecisionRevision
   $pair=$catalog.PairId
  }
 }
 Start-WsmHtmlConsole -Workspace $Workspace -PairId $pair -Role Manager -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile
} $Workspace $ReadyPath $StopFile $Seed (Join-Path $PSScriptRoot '..\src\HtmlConsole.ps1') $ResponseCapturePath $FailWizardRegistration
