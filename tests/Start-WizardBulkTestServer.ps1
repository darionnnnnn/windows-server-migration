param([string]$Workspace,[string]$ReadyPath,[string]$StopFile,[string]$ResponseCapturePath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking | Out-Null
Initialize-WsmWizardWorkspace $Workspace Manager | Out-Null
$source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='Formal bulk source'}
$supplement=[pscustomobject][ordered]@{ServiceType='Win32OwnProcess';ErrorControl='Normal';LoadOrderGroup='';DelayedAutoStart=$false;FailureActions=[pscustomobject][ordered]@{ResetPeriodSeconds=0;RebootMessage='';Command='';Actions=@()};FailureActionsOnNonCrashFailures=$false;ServiceSidType='None';RequiredPrivileges=@();Environment=@();Triggers=@()}
$serviceSettings=[pscustomobject][ordered]@{Name='FixtureSvc';DisplayName='Fixture service';Description='Fixture service';PathName='C:\Fixture\service.exe';StartMode='Disabled';StartName='LocalSystem';ServiceType='Win32OwnProcess';Supplement=$supplement}
$service=New-WsmItem $source.HostId Services Service 'Fixture service' 'FixtureSvc' $serviceSettings @() Success Service
$groupSettings=[pscustomobject][ordered]@{Name='Fixture Operators';SID='S-1-5-21-111111111-222222222-333333333-2001';Members=@([pscustomobject][ordered]@{Name='fixture-reader';Domain='FIXTURE';SID='S-1-5-21-111111111-222222222-333333333-1002'})}
$group=New-WsmItem $source.HostId Identity LocalGroup $groupSettings.Name $groupSettings.SID $groupSettings @() Success LocalGroup
$inventory=New-WsmInventory $source 1 @($service,$group);$inventoryPath=Join-Path $Workspace 'fixture-inventory.json';[IO.File]::WriteAllText($inventoryPath,(ConvertTo-Json -InputObject $inventory -Depth 40),[Text.UTF8Encoding]::new($false))
$catalog=Import-WsmInventory $Workspace $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'formal bulk UI fixture'
$catalog=Enable-WsmAssistiveMode $Workspace $catalog.PairId $catalog.DecisionRevision
foreach($id in @($service.ItemId,$group.ItemId)){$fresh=Get-WsmCatalog $Workspace $catalog.PairId;Set-WsmWizardChoice -Workspace $Workspace -PairId $catalog.PairId -Role Manager -ItemId $id -Selected $true -ExpectedDecisionRevision $fresh.DecisionRevision -ExpectedSelectionRevision $fresh.Assistive.Selections.Revision | Out-Null}
$catalog=Get-WsmCatalog $Workspace $catalog.PairId
$wizard=Get-WsmWizardState -Workspace $Workspace -PairId $catalog.PairId -Role Manager
Set-WsmWizardState -Workspace $Workspace -PairId $catalog.PairId -Role Manager -ExpectedWizardRevision $wizard.Revision -Changes ([pscustomobject]@{CurrentStep='prepare';Mode='ItemByItem'}) | Out-Null
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReadyPath)))
[IO.File]::WriteAllText(($ReadyPath+'.fixture'),(ConvertTo-Json -InputObject ([pscustomobject]@{PairId=$catalog.PairId;ItemIds=@($service.ItemId,$group.ItemId)}) -Depth 8),[Text.UTF8Encoding]::new($false))
$module=Get-Module WindowsServerMigration
& $module {
 param($Workspace,$PairId,$ReadyPath,$StopFile,$ResponseCapturePath)
 $script:FixtureCaptureRoot=$ResponseCapturePath;$script:FixtureCaptureSequence=0
 $script:TestOriginalWriter=${function:Write-WsmLocalHttpResponse}
 function Write-WsmLocalHttpResponse($Client,[int]$Status,[string]$ContentType,[byte[]]$Bytes){$sha=[Security.Cryptography.SHA256]::Create();try{$hash=[BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()};if($script:FixtureCaptureRoot){$script:FixtureCaptureSequence++;$record=[pscustomobject]@{Sequence=$script:FixtureCaptureSequence;Status=$Status;ContentType=$ContentType;SHA256=$hash;Payload=[Convert]::ToBase64String($Bytes)};$path=Join-Path $script:FixtureCaptureRoot ($script:FixtureCaptureSequence.ToString()+'.json');Write-WsmJson $path $record} & $script:TestOriginalWriter $Client $Status $ContentType $Bytes}
 Start-WsmHtmlConsole -Workspace $Workspace -PairId $PairId -Role Manager -NoBrowser -ReadyPath $ReadyPath -StopFile $StopFile
} $Workspace $catalog.PairId $ReadyPath $StopFile $ResponseCapturePath
