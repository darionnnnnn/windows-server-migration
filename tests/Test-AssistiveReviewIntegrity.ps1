#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru -DisableNameChecking
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-review-integrity-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{ & $module {
 param($root)
 $script:checks=0;function Check([bool]$v,[string]$m){if(-not $v){throw $m};$script:checks++}
 $source=[pscustomobject]@{HostId=[Guid]::NewGuid().ToString();Fingerprint=('a'*64);Name='fixture-source'}
 $item=New-WsmItem $source.HostId Storage FileScope 'approved file' 'approved-file' @{Path='C:\source\file.ini'}
 $inventory=New-WsmInventory -Source $source -Revision 1 -Items @($item);$inventoryPath=Join-Path $root 'inventory.json';Write-WsmJson $inventoryPath $inventory
 $workspace=Join-Path $root 'workspace';Initialize-WsmWorkspace $workspace|Out-Null
 $catalog=Import-WsmInventory $workspace $inventoryPath (Get-FileHash $inventoryPath).Hash 'fixture-target'
 $catalog=Set-WsmDecision $workspace $catalog.PairId @($item.ItemId) Include 'fixture scope' $catalog.DecisionRevision
 $row=$catalog.History[-1];$native=Get-WsmExecutionActor
 Check ($row.Actor.WindowsSID -ceq $native.WindowsSID -and $row.Actor.WindowsPrincipal -ceq $native.WindowsPrincipal) 'Durable decision failed to bind the native Windows principal.'
 Check ($row.Actor.ExecutionHost -ceq [Environment]::MachineName -and -not $row.Actor.BrowserHumanAuthenticated) 'Durable actor lost execution host or claimed browser identity authentication.'
 $persisted=Get-WsmCatalog $workspace $catalog.PairId
 Check ($persisted.History[-1].Actor.WindowsSID -ceq $native.WindowsSID) 'Native actor did not survive JSON persistence.'
 $persisted.Items[0].Mapping='C:\review-only';$persisted.Items[0]|Add-Member NoteProperty MigrationSpec ([pscustomobject]@{TargetPath='C:\approved-target'}) -Force
 $projection=Get-WsmEnvironmentConfirmationProjection $persisted
 $projected=@($projection.Items|Where-Object ItemId -CEQ $item.ItemId)[0]
 Check ($projected.TargetPath -ceq 'C:\approved-target' -and $projected.ReviewSuggestedPath -ceq 'C:\review-only') 'Environment document confused a suggestion with the approved target.'
 function Entry([string]$id,[string]$sid,[string]$account){[pscustomobject]@{SoftwareId=$id;Name='Fixture runtime';Publisher='Fixture vendor';Scope='User';SID=$sid;Architecture='x64';AccountContext=$account;Version='2';CaptureStatus='Success';SourceKind='Registry';Evidence=[pscustomobject]@{Probe='Uninstall'};Location='fixture:runtime'}}
 $a=Entry 'source' 'S-1-5-21-111-1001' 'OLDHOST\operator';$b=Entry 'target' 'S-1-5-21-222-1001' 'NEWHOST\operator'
 $compared=New-WsmAssistiveSoftwareRows ([pscustomobject]@{Entries=@($a)}) ([pscustomobject]@{Entries=@($b)}) $null @() $true
 Check ($compared.Rows.Count -eq 1 -and $compared.Rows[0].TargetSoftwareId -ceq 'target' -and $compared.Rows[0].Status -ceq 'ChosenVersionObserved') 'Host-local SID change incorrectly became missing plus target-only software.'
 Check ($compared.Rows[0].AccountScopeStatus -ceq 'DifferentIdentityRequiresReview' -and $compared.Rows[0].TargetSID -ceq $b.SID -and @($compared.ManualPreparation|Where-Object Status -CEQ AccountScopeReviewRequired).Count -eq 1) 'Cross-host product pairing silently proved account equivalence.'
 $second=Entry 'second-target' 'S-1-5-21-222-1002' 'NEWHOST\another'
 $ambiguous=New-WsmAssistiveSoftwareRows ([pscustomobject]@{Entries=@($a)}) ([pscustomobject]@{Entries=@($b,$second)}) $null @() $true
 Check (@($ambiguous.Rows|Where-Object SoftwareId -CEQ source)[0].Status -ceq 'Ambiguous') 'Multiple user instances were automatically paired.'
 Write-Host ('PASS: '+$script:checks+' native report, account pairing and durable actor checks.')
} $root }finally{Remove-Item -LiteralPath $root -Recurse -Force}