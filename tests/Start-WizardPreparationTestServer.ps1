param([string]$Workspace,[string]$ReadyPath,[string]$StopFile,[string]$ResponseCapturePath)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
& $module {
 param($Workspace,$ReadyPath,$StopFile,$ResponseCapturePath)
 $script:FixtureCaptureRoot=$ResponseCapturePath;$script:FixtureCaptureSequence=0
 $script:TestOriginalWriter=${function:Write-WsmLocalHttpResponse}
 function Write-WsmLocalHttpResponse($Client,[int]$Status,[string]$ContentType,[byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};[Console]::Error.WriteLine('FIXTURE RESPONSE START '+$Status+' '+$ContentType+' '+$Bytes.Length+' body-sha256='+$hash);if($script:FixtureCaptureRoot){$script:FixtureCaptureSequence++;$record=[pscustomobject]@{Sequence=$script:FixtureCaptureSequence;Status=$Status;ContentType=$ContentType;SHA256=$hash;Payload=[Convert]::ToBase64String($Bytes)};$path=Join-Path $script:FixtureCaptureRoot ($script:FixtureCaptureSequence.ToString()+'.json');Write-WsmJson $path $record}try{& $script:TestOriginalWriter $Client $Status $ContentType $Bytes;[Console]::Error.WriteLine('FIXTURE RESPONSE COMPLETE '+$Status)}catch{[Console]::Error.WriteLine('FIXTURE RESPONSE THROW '+($_|Format-List * -Force|Out-String));[Console]::Error.WriteLine('FIXTURE RESPONSE STACK '+$_.ScriptStackTrace);throw}}
 Initialize-WsmWizardWorkspace $Workspace Manager|Out-Null
 $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='isolated preparation source'}
 $item=New-WsmItem $source.HostId Storage PathCandidate 'Business files' 'C:\business-data' ([pscustomobject]@{OriginalPath='C:\business-data';ResolvedCandidate='C:\business-data'})
 $inventory=New-WsmInventory $source 1 @($item);$inventoryPath=Join-Path $Workspace 'fixture-inventory.json';Write-WsmJson $inventoryPath $inventory
 $catalog=Import-WsmInventory $Workspace $inventoryPath (Get-FileHash -LiteralPath $inventoryPath).Hash 'isolated target'
 $catalog=Enable-WsmAssistiveMode $Workspace $catalog.PairId $catalog.DecisionRevision
 Set-WsmDecision $Workspace $catalog.PairId $item.ItemId Include 'Isolated preparation candidate' $catalog.DecisionRevision | Out-Null
 Write-WsmJson ($ReadyPath+'.fixture') ([pscustomobject]@{PairId=$catalog.PairId;ItemId=$item.ItemId})
 Start-WsmHtmlConsole -Workspace $Workspace -PairId $catalog.PairId -Role Manager -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile
} $Workspace $ReadyPath $StopFile $ResponseCapturePath
