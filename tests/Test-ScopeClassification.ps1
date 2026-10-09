#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$hostId=[Guid]::NewGuid().ToString()
$source=[pscustomobject]@{HostId=$hostId;Fingerprint=('a'*64);Name='fixture';OS='Fixture Server';Version='10.0';DiscoveryDepth='Metadata'}
$sql=New-WsmItem $hostId Services Service 'SQL Server (MSSQLSERVER)' 'MSSQLSERVER' @{Name='MSSQLSERVER';PathName='C:\Program Files\Microsoft SQL Server\sqlservr.exe'}
$iis=New-WsmItem $hostId Web IISSite 'Web application' 'web-app' @{Xml='<site />'}
$custom=New-WsmItem $hostId Services Service 'Acme internal worker' 'acme-worker' @{Name='AcmeWorker';Publisher='Acme Corp';PathName='C:\Acme\worker.exe'}
$client=New-WsmItem $hostId Runtime InstalledApplication 'Oracle Client 19c' 'oracle-client-home-1' ([pscustomobject]@{DisplayName='Oracle Client 19c';Publisher='Oracle';DisplayVersion='19.3';InstallLocation='C:\Oracle\client'})
$provider=New-WsmItem $hostId Runtime InstalledApplication 'Oracle Data Provider for .NET' 'oracle-odpnet-1' @{DisplayName='Oracle Data Provider for .NET (ODP.NET)';Publisher='Oracle'}
$nameOnlyProvider=New-WsmItem $hostId Runtime InstalledApplication 'ODP.NET Managed Driver' 'oracle-odpnet-managed-name-only' @{Publisher='Oracle';InstallLocation='C:\Oracle\client'}
$engineApp=New-WsmItem $hostId Runtime InstalledApplication 'Microsoft SQL Server 2022 Database Engine Services' 'sql-engine-app' ([pscustomobject]@{DisplayName='Microsoft SQL Server 2022 Database Engine Services'})
$agent=New-WsmItem $hostId Runtime InstalledApplication 'CrowdStrike Falcon Sensor' 'crowdstrike-1' ([pscustomobject]@{DisplayName='CrowdStrike Falcon Sensor';Publisher='CrowdStrike';DisplayVersion='7.1'})
$db=New-WsmItem $hostId Services Service 'OracleServiceORCL' 'OracleServiceORCL' @{Name='OracleServiceORCL'}
$listener=New-WsmItem $hostId Services Service 'Oracle TNS Listener' 'OracleOraDB19Home1TNSListener' @{Name='OracleOraDB19Home1TNSListener'}
$adRole=New-WsmItem $hostId Roles WindowsFeature 'Active Directory 服務' 'AD-Domain-Services' @{Name='AD-Domain-Services'}
$dnsRole=New-WsmItem $hostId Roles WindowsFeature 'DNS 伺服器' 'DNS' @{Name='DNS'}
$unknown=New-WsmItem $hostId Runtime InstalledApplication 'Acme Product Suite' 'acme-unknown' ([pscustomobject]@{DisplayName='Acme Product Suite';Publisher='Oracle Corporation';DisplayVersion='4.2';InstallLocation='C:\Oracle\product\TNSListener.exe'})
$pathInjected=New-WsmItem $hostId Services Service 'Acme listener health probe' 'AcmeListenerProbe' @{Name='AcmeListenerProbe';PathName='C:\Oracle\product\dbhome\bin\tnslsnr.exe'}
$system=New-WsmItem $hostId Network FirewallRule 'Fixture firewall rule' 'fixture-rule' @{Rule='private-sensitive-value'}
$sql.Dependencies=@(@{ItemId=$db.ItemId;Type='External'})
$custom.Dependencies=@(@{ItemId=('b'*64);Type='External'})
$inv=New-WsmInventory $source 1 @($sql,$iis,$custom,$client,$provider,$nameOnlyProvider,$engineApp,$agent,$db,$listener,$adRole,$dnsRole,$unknown,$pathInjected,$system)
$assessment=Get-WsmGeneralHostAssessment -Inventory $inv
$byId=@{};foreach($row in $assessment.Items){$byId[$row.ItemId]=$row.Classification.Disposition}
if($byId[$sql.ItemId] -ne 'SpecialProduct' -or $byId[$db.ItemId] -ne 'SpecialProduct' -or $byId[$listener.ItemId] -ne 'SpecialProduct' -or $byId[$engineApp.ItemId] -ne 'SpecialProduct' -or $byId[$adRole.ItemId] -ne 'SpecialProduct' -or $byId[$dnsRole.ItemId] -ne 'SpecialProduct'){throw 'Database, listener, or canonical special-role classification failed.'}
if($byId[$client.ItemId] -ne 'Preparation' -or $byId[$provider.ItemId] -ne 'Preparation' -or $byId[$nameOnlyProvider.ItemId] -ne 'Preparation' -or $byId[$agent.ItemId] -ne 'Preparation'){throw 'Client, provider, or agent preparation classification failed.'}
if($byId[$custom.ItemId] -ne 'GeneralMigration' -or $byId[$iis.ItemId] -ne 'GeneralMigration'){throw 'Mixed IIS/custom service was incorrectly excluded.'}
if($byId[$unknown.ItemId] -ne 'Unknown' -or $byId[$system.ItemId] -ne 'SystemSetting' -or $byId[$pathInjected.ItemId] -ne 'GeneralMigration'){throw 'Unknown, path injection, or Windows setting classification failed.'}
if($assessment.TotalItems -ne 15 -or $assessment.Relations.Count -ne 2 -or @($assessment.Relations | Where-Object Resolved).Count -ne 1 -or @($assessment.Gaps | Where-Object Kind -EQ UnresolvedDependency).Count -ne 1){throw 'Assessment item or dependency coverage was incomplete.'}
if(($assessment.Items | ConvertTo-Json -Depth 8 -Compress).Contains('private-sensitive-value')){throw 'Assessment exposed item settings.'}
# Source inventories emitted by this stage carry per-item metadata without changing their identity or settings hash.
foreach($item in $inv.Items){$beforeId=$item.ItemId;$beforeHash=$item.SettingsHash;$item | Add-Member NoteProperty Classification (Get-WsmScopeClassification $item);if($item.ItemId -cne $beforeId -or $item.SettingsHash -cne $beforeHash){throw 'Classification changed source item identity or settings hash.'}}
foreach($item in $inv.Items){Assert-WsmScopeClassification $item | Out-Null}
$legacyItems=@(foreach($item in $inv.Items){$copy=ConvertFrom-Json -InputObject ($item | ConvertTo-Json -Depth 30 -Compress);$copy.PSObject.Properties.Remove('Classification');$copy})
$legacy=New-WsmInventory $source 2 $legacyItems
$legacyAssessment=Get-WsmGeneralHostAssessment -Inventory $legacy
if($legacyAssessment.CountsByDisposition.GeneralMigration -ne 3 -or $legacyAssessment.CountsByDisposition.SpecialProduct -ne 6){throw 'Legacy inventory did not receive an independent classification projection.'}
$orderedItem=New-WsmItem $hostId Services Service 'Acme ordered fixture' 'ordered-fixture' @{Name='AcmeOrderedFixture'}
$orderedInventory=New-WsmInventory $source 7 @($orderedItem)
$canonical=Get-WsmScopeClassification $orderedItem
$reordered=[pscustomobject][ordered]@{RuleId=$canonical.RuleId;Confidence=$canonical.Confidence;Evidence=@($canonical.Evidence);Reason=$canonical.Reason;Disposition=$canonical.Disposition;ClassifierVersion=$canonical.ClassifierVersion;SchemaVersion=[long]$canonical.SchemaVersion}
$orderedInventory.Items[0] | Add-Member NoteProperty Classification $reordered
[void](Get-WsmGeneralHostAssessment -Inventory $orderedInventory)
$catalog=[pscustomobject]@{SchemaVersion=1;ToolVersion='0.3.0';Kind='Catalog';PairId=[Guid]::NewGuid().ToString();Source=$source;InventoryRevision=1;Items=@($legacy.Items)}
$catalogAssessment=Get-WsmGeneralHostAssessment -Catalog $catalog
$rejected=$false;try{Get-WsmGeneralHostAssessment -Catalog $inv | Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Catalog parameter accepted the wrong envelope kind.'}
$rejected=$false;try{Get-WsmGeneralHostAssessment -Inventory $catalog | Out-Null}catch{$rejected=$true};if(-not $rejected){throw 'Inventory parameter accepted the wrong envelope kind.'}
if($catalogAssessment.TotalItems -ne 15 -or $catalogAssessment.SourceHostId -cne $hostId){throw 'Catalog assessment did not retain its source binding.'}
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$roundTripRoot=[IO.Path]::GetFullPath((Join-Path $tempRoot ('wsm-scope-'+[Guid]::NewGuid().ToString('N'))))
try {
    $workspace=Join-Path $roundTripRoot 'workspace';[void][IO.Directory]::CreateDirectory($roundTripRoot);Initialize-WsmWorkspace $workspace | Out-Null
    $classified=New-WsmInventory $source 5 @($sql,$iis,$custom,$client,$provider,$nameOnlyProvider,$engineApp,$agent,$db,$listener,$adRole,$dnsRole,$unknown,$pathInjected,$system)
    foreach($item in $classified.Items){$item | Add-Member NoteProperty Classification (Get-WsmScopeClassification $item) -Force}
    $inventoryPath=Join-Path $roundTripRoot 'classified-inventory.json';[IO.File]::WriteAllText($inventoryPath,($classified | ConvertTo-Json -Depth 40 -Compress),(New-Object Text.UTF8Encoding($false)))
    $imported=Import-WsmInventory $workspace $inventoryPath (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash 'fixture-target'
    $roundTrip=Get-WsmCatalog $workspace $imported.PairId
    if(-not $roundTrip.Items[0].PSObject.Properties['Classification'] -or (Get-WsmGeneralHostAssessment -Catalog $roundTrip).TotalItems -ne 15){throw 'Serialized import did not preserve and assess classification metadata.'}
    $invalidItem=New-WsmItem $hostId Runtime InstalledApplication 'Acme Product Suite' 'invalid-wire-classification' ([pscustomobject]@{DisplayName='Acme Product Suite'})
    $invalid=New-WsmInventory $source 6 @($invalidItem)
    $invalid.Items[0] | Add-Member NoteProperty Classification ([pscustomobject]@{SchemaVersion=1;Disposition='GeneralMigration'})
    $invalidPath=Join-Path $roundTripRoot 'invalid-inventory.json';[IO.File]::WriteAllText($invalidPath,($invalid | ConvertTo-Json -Depth 40 -Compress),(New-Object Text.UTF8Encoding($false)))
    $rejected=$false;try{Import-WsmInventory $workspace $invalidPath (Get-FileHash -LiteralPath $invalidPath -Algorithm SHA256).Hash | Out-Null}catch{$rejected=$true}
    if(-not $rejected){throw 'Serialized import accepted malformed classification metadata.'}
} finally {
    $resolvedTempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $leaf=[IO.Path]::GetFileName($roundTripRoot)
    if($roundTripRoot.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase) -and $leaf -match '^wsm-scope-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $roundTripRoot)){Remove-Item -LiteralPath $roundTripRoot -Recurse -Force}
}
$bad=New-WsmItem $hostId Runtime InstalledApplication 'Acme Product Suite' 'bad-classification' ([pscustomobject]@{DisplayName='Acme Product Suite'})
$badInventory=New-WsmInventory $source 3 @($bad)
$badInventory.Items[0] | Add-Member NoteProperty Classification ([pscustomobject]@{SchemaVersion=1;ClassifierVersion='1.0.0';Disposition='GeneralMigration';Reason='forged';Evidence=@('fixture');Confidence='High';RuleId='forged'})
$rejected=$false;try{Get-WsmGeneralHostAssessment -Inventory $badInventory | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Assessment accepted a serialized classification that disagrees with its own projection.'}
$malformed=New-WsmItem $hostId Runtime InstalledApplication 'Acme Product Suite' 'malformed-classification' ([pscustomobject]@{DisplayName='Acme Product Suite'})
$malformedInventory=New-WsmInventory $source 4 @($malformed)
$malformedInventory.Items[0] | Add-Member NoteProperty Classification ([pscustomobject]@{SchemaVersion=1;Disposition='Unknown'})
$rejected=$false;try{Get-WsmGeneralHostAssessment -Inventory $malformedInventory | Out-Null}catch{$rejected=$true}
if(-not $rejected){throw 'Assessment accepted malformed attached classification metadata.'}
Write-Host 'PASS: classification rules, legacy projection, metadata validation, relations, safe output, and stable source identity.'
