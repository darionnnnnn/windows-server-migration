#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('wsm-iis-coverage-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()){& $script:module $Block @Arguments}
try {
    $configDir=Join-Path $root 'config';$partsDir=Join-Path $configDir 'sections';[void][IO.Directory]::CreateDirectory($partsDir)
    $configPath=Join-Path $configDir 'applicationHost.config';$configSourcePath=Join-Path $partsDir 'staticContent.config'
    [IO.File]::WriteAllText($configSourcePath,'<staticContent><mimeMap fileExtension=".fixture" mimeType="application/x-fixture" /></staticContent>',(New-Object Text.UTF8Encoding($false)))
    $xmlText=@'
<configuration>
  <configSections>
    <sectionGroup name="system.webServer">
      <sectionGroup name="security"><section name="access" /></sectionGroup>
      <section name="staticContent" />
      <section name="defaultDocument" />
    </sectionGroup>
    <section name="customRoot" />
  </configSections>
  <system.webServer>
    <security><access enabled="true" /></security>
    <staticContent configSource="sections\staticContent.config" />
    <defaultDocument><files><clear /></files></defaultDocument>
  </system.webServer>
  <customRoot mode="review" />
  <unknownRoot opaque="true" />
  <location path="Default Web Site">
    <system.webServer><security><access enabled="true" /></security></system.webServer>
  </location>
</configuration>
'@
    [IO.File]::WriteAllText($configPath,$xmlText,(New-Object Text.UTF8Encoding($false)))
    $hostId=[Guid]::NewGuid().ToString()
    $result=CallModule {param($host,$path) $document=Read-WsmXml ([IO.File]::ReadAllText($path));Get-WsmIisConfigurationInventoryItems $host $document $path} @($hostId,$configPath)
    $global=@($result|Where-Object Kind -CEQ 'IISGlobalConfig');$section=@($result|Where-Object {$_.Kind -eq 'IISSectionConfig' -and $_.Settings.SectionPath -ceq 'system.webServer/security/access'});$external=@($result|Where-Object {$_.Kind -eq 'IISSectionConfig' -and $_.Settings.SectionPath -ceq 'system.webServer/staticContent'});$noActivation=@($result|Where-Object {$_.Kind -eq 'IISSectionConfig' -and $_.Settings.SectionPath -ceq 'system.webServer/defaultDocument'});$location=@($result|Where-Object {$_.Kind -eq 'IISLocationConfig' -and $_.Settings.SectionPath -ceq 'system.webServer/security/access'});$locationParent=@($result|Where-Object {$_.Kind -eq 'IISLocationConfig' -and -not $_.Settings.PSObject.Properties['SectionPath']});$unknown=@($result|Where-Object {$_.Settings.PSObject.Properties['CoverageDisposition'] -and $_.Settings.CoverageDisposition -eq 'ManualReviewRequired' -and $_.NaturalKey -match 'unknown'})
    Check ($global.Count -eq 1 -and $global[0].Settings.RawEvidenceProtected -and $global[0].Settings.ConfigurationHash -match '^[a-f0-9]{64}$') 'Complete applicationHost.config was not retained as protected, hashed source evidence.'
    Check ($section.Count -eq 1 -and $section[0].Settings.DefinitionKnown -and $section[0].Settings.SectionPath -ceq 'system.webServer/security/access' -and $section[0].Settings.ParentGlobalConfigItemId -ceq $global[0].ItemId) 'Nested sectionGroup declaration did not produce an exact parent-bound section item.'
    Check ($external.Count -eq 1 -and $external[0].Settings.ConfigSource.Status -ceq 'Captured' -and $external[0].Settings.ConfigSource.SHA256 -match '^[a-f0-9]{64}$' -and $external[0].Settings.ConfigSource.ProtectedXml -match 'mimeMap') 'Safe relative configSource linkage and bytes/hash were not retained as protected evidence.'
    Check ($location.Count -eq 1 -and $location[0].Settings.LocationPath -ceq 'Default Web Site' -and $location[0].Settings.ParentGlobalConfigItemId -ceq $global[0].ItemId) 'Location-scoped actual configuration section was not separated and tied to the global parent.'
    Check ($locationParent.Count -eq 1 -and $unknown.Count -ge 1) 'Raw location container or undeclared section did not remain an explicit manual review item.'

    $source=[pscustomobject]@{HostId=$hostId;Fingerprint=('a'*64);Name='IIS fixture'}
    $webRoot=Join-Path $root 'webroot';$webNested=Join-Path $webRoot 'child';[void][IO.Directory]::CreateDirectory($webNested);$webConfigPath=Join-Path $webRoot 'web.config';$webExternalPath=Join-Path $webRoot 'external.config';[IO.File]::WriteAllText($webConfigPath,'<configuration><appSettings configSource="external.config" /></configuration>',(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText($webExternalPath,'<appSettings><add key="fixture" value="captured" /></appSettings>',(New-Object Text.UTF8Encoding($false)));[IO.File]::WriteAllText((Join-Path $webNested 'web.config'),'<configuration><system.web><compilation debug="false" /></system.web></configuration>',(New-Object Text.UTF8Encoding($false)))
    $siteXmlText='<site name="Default Web Site"><application path="/"><virtualDirectory path="/" physicalPath="'+$webRoot+'" /></application></site>'
    $siteItem=CallModule {param($host,$xmlText) New-WsmItem $host Web IISSite 'Default Web Site' 'Default Web Site' @{Xml=$xmlText}} @($hostId,$siteXmlText);$siteItem|Add-Member NoteProperty Decision 'Include' -Force;$siteItem|Add-Member NoteProperty Reason 'Fixture selection' -Force
    $webItems=CallModule {param($host,$site) @(Get-WsmIisWebConfigInventoryItems $host @($site))} @($hostId,$siteItem)
    $webConfig=@($webItems|Where-Object Kind -CEQ 'IISWebConfig');$webObservations=@($webItems|Where-Object Kind -CEQ 'IISWebConfigObservation')
    Check ($webConfig.Count -eq 2 -and $webConfig[0].Settings.RawEvidenceProtected -and $webConfig[0].Settings.RawBytesBase64 -and $webConfig[0].Settings.SHA256 -match '^[a-f0-9]{64}$' -and $webConfig[0].Settings.PotentialConsumerItemIds -contains $siteItem.ItemId) 'Bounded physical-root walk did not retain full protected, hash-bound web.config evidence for the exact IIS consumer.'
    Check ($webObservations.Count -eq 0) 'Complete fixture web.config traversal emitted an unexpected blocked observation.'
    $limited=CallModule {param($host,$site) @(Get-WsmIisWebConfigInventoryItems $host @($site) -MaxFileBytes 8)} @($hostId,$siteItem)
    Check (@($limited|Where-Object {$_.Kind -eq 'IISWebConfigObservation' -and $_.Settings.Status -match 'FileSizeBudgetExceeded|TotalByteBudgetExceeded'}).Count -gt 0) 'Oversized web.config was not represented by a bounded, explicit blocked observation.'
    $missingRoot=CallModule {param($host) $site=New-WsmItem $host Web IISSite 'Missing root' 'Missing root' @{Xml='<site name="Missing root"><application path="/"><virtualDirectory path="/" physicalPath="Z:\missing-wsm-webroot" /></application></site>'};@(Get-WsmIisWebConfigInventoryItems $host @($site))} @($hostId)
    Check (@($missingRoot|Where-Object {$_.Kind -eq 'IISWebConfigObservation' -and $_.Settings.Status -ceq 'RootUnavailable'}).Count -eq 1) 'Unavailable captured IIS physical root did not create an explicit blocked observation.'
    foreach($configItem in @($result|Where-Object Kind -in @('IISGlobalConfig','IISSectionConfig','IISLocationConfig'))){$configItem|Add-Member NoteProperty Decision 'Pending' -Force;$configItem|Add-Member NoteProperty Reason '' -Force}
    foreach($configItem in @($webItems|Where-Object Kind -in @('IISWebConfig','IISWebConfigObservation'))){$configItem|Add-Member NoteProperty Decision 'Pending' -Force;$configItem|Add-Member NoteProperty Reason '' -Force}
    $discoveryItems=@($result)+@($siteItem)+@($webItems)
    $genericCandidates=CallModule {param($host,$items) @(Get-WsmPathCandidates $host $items)} @($hostId,$discoveryItems)
    $resolvedCandidates=CallModule {param($host,$items,$candidates) @(Resolve-WsmIisConfigSourceCandidates $host $items $candidates)} @($hostId,$discoveryItems,$genericCandidates)
    $resolvedConfig=@($resolvedCandidates|Where-Object {$_.Kind -eq 'PathCandidate' -and $_.Settings.OriginalPath -ceq $configSourcePath});$resolvedWeb=@($resolvedCandidates|Where-Object {$_.Kind -eq 'PathCandidate' -and $_.Settings.OriginalPath -ceq $webExternalPath})
    Check ($resolvedConfig.Count -eq 1 -and $resolvedWeb.Count -eq 1 -and @($resolvedConfig[0].Settings.OriginalPath,$resolvedWeb[0].Settings.OriginalPath|Where-Object {$_ -match '^(?i:[A-Z]:\\)' }).Count -eq 2) 'Safe configSource links did not create exact absolute FileScope candidates for both applicationHost and web.config sources.'
    $webReference=@(CallModule {param($item) @(Get-WsmWorkloadPathReferences $item)} @($webConfig|Where-Object {$_.Settings.Path -ceq $webConfigPath}));
    Check (@($webReference|Where-Object {$_.ReferenceKind -eq 'IISConfigSource' -and $_.ResolvedPath -ceq $webExternalPath -and $_.Channel -eq 'SuggestedC' -and $_.Required}).Count -eq 1) 'web.config configSource did not become a required path reference with the validated absolute C-channel classification.'
    $linkedOwner=@($discoveryItems|Where-Object {$_.Settings.PSObject.Properties['ConfigSources'] -and $_.Settings.Path -ceq $webConfigPath})[0];$linkedDependency=@($linkedOwner.Dependencies|Where-Object {$_.Type -ceq 'Mandatory' -and $_.Evidence -ceq 'Validated protected configSource file link'});$linkedReference=@($resolvedCandidates|Where-Object ItemId -CEQ $linkedDependency[0].ItemId)
    Check ($linkedDependency.Count -eq 1 -and $linkedReference.Count -eq 1 -and $linkedReference[0].Settings.OriginalPath -ceq $webExternalPath) 'Validated configSource did not create a mandatory dependency on its exact resolved FileScope candidate.'
    $nonCChannel=CallModule {param($path) Get-WsmWorkloadPathChannel $path} @('D:\IIS\shared.config')
    Check ($nonCChannel -eq 'SuggestedNonC') 'Validated absolute non-C configSource paths would not be classified onto the NonC channel.'
    $inventory=CallModule {param($s,$items) New-WsmInventory $s 1 $items} @($source,(@($discoveryItems)+@($resolvedCandidates)))
    $workload=CallModule {param($inv) Get-WsmWorkloadDiscovery $inv} @($inventory)
    Check (@($workload.ConfigurationCoverage|Where-Object {$_.ItemId -ceq $global[0].ItemId -and $_.RequiredConsumerStatus -eq 'ConservativePotential' -and $_.PotentialConsumerItemIds.Count -eq 1 -and -not $_.EffectiveValueProven -and -not $_.TargetBaselineProven}).Count -eq 1) 'IIS global configuration coverage did not explicitly retain unresolved consumer/effective-value state.'

    # A web.config owned only by site B must not block site A with a false
    # "missing coverage" report, while selecting B must surface its own row.
    $webRootB=Join-Path $root 'webroot-b';[void][IO.Directory]::CreateDirectory($webRootB);[IO.File]::WriteAllText((Join-Path $webRootB 'web.config'),'<configuration><system.web><customErrors mode="RemoteOnly" /></system.web></configuration>',(New-Object Text.UTF8Encoding($false)))
    $siteB=CallModule {param($host,$path) $item=New-WsmItem $host Web IISSite 'Site B' 'Site B' @{Xml=('<site name="Site B"><application path="/"><virtualDirectory path="/" physicalPath="'+$path+'" /></application></site>')};$item|Add-Member NoteProperty Decision 'Include' -Force;$item|Add-Member NoteProperty Reason 'Fixture selection' -Force;$item} @($hostId,$webRootB)
    $webB=CallModule {param($host,$site) @(Get-WsmIisWebConfigInventoryItems $host @($site))} @($hostId,$siteB)
    foreach($item in @($webB)){$item|Add-Member NoteProperty Decision 'Pending' -Force;$item|Add-Member NoteProperty Reason '' -Force}
    $twoSiteItems=@($result)+@($siteItem)+@($siteB)+@($webItems)+@($webB)
    $twoSiteCandidates=CallModule {param($host,$items) @(Resolve-WsmIisConfigSourceCandidates $host $items @(Get-WsmPathCandidates $host $items))} @($hostId,$twoSiteItems)
    $twoSiteAll=@($twoSiteItems)+@($twoSiteCandidates);$twoSiteInventory=CallModule {param($s,$items) New-WsmInventory $s 2 $items} @($source,$twoSiteAll);$twoSiteWorkload=CallModule {param($inv) Get-WsmWorkloadDiscovery $inv} @($twoSiteInventory)
    $selectionA=[pscustomobject]@{ItemId=$siteItem.ItemId;Selected=$true};$selectionB=[pscustomobject]@{ItemId=$siteB.ItemId;Selected=$false}
    $twoSiteCatalog=[pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=1;Selections=[pscustomobject]@{Revision=1;Items=@($selectionA,$selectionB)}};WorkloadDiscovery=$twoSiteWorkload;Items=$twoSiteAll}
    $webBIds=@($webB|ForEach-Object ItemId);$webBPattern=[regex]::Escape([string]$webBIds[0]);$siteAIssues=CallModule {param($c,$items) @(Get-WsmIisConfigurationCoverageIssues $c $items)} @($twoSiteCatalog,@($siteItem,$siteB))
    Check (@($siteAIssues|Where-Object {$_.ItemId -ceq $siteItem.ItemId -and $_.Issue -match $webBPattern}).Count -eq 0) 'A scoped web.config for site B falsely blocked selected site A as missing coverage.'
    $siteAIntegrated=CallModule {param($c,$items) @(Get-WsmAssistiveWorkloadReviewIssues $c $items)} @($twoSiteCatalog,@($siteItem,$siteB))
    Check (@($siteAIntegrated|Where-Object {$_.ItemId -ceq $siteItem.ItemId -and $_.Gate -ceq 'ConfigurationCoverage' -and $_.Issue -match $webBPattern}).Count -eq 0) 'Actual Assistive review consumer reported a false missing-coverage issue for the other site web.config.'
    $selectionB.Selected=$true;$siteBIssues=CallModule {param($c,$items) @(Get-WsmIisConfigurationCoverageIssues $c $items)} @($twoSiteCatalog,@($siteItem,$siteB))
    Check (@($siteBIssues|Where-Object {$_.ItemId -ceq $siteB.ItemId -and $_.Issue -match $webBPattern}).Count -eq 1) 'Selecting site B did not retain its own unresolved web.config coverage issue.'

    $catalogItems=$discoveryItems+$resolvedCandidates
    $catalog=[pscustomobject]@{Assistive=[pscustomobject]@{ContractVersion=1;Selections=[pscustomobject]@{Revision=1;Items=@([pscustomobject]@{ItemId=$siteItem.ItemId;Selected=$true})}};WorkloadDiscovery=$workload;Items=$catalogItems}
    $unresolved=CallModule {param($c,$items) @(Get-WsmIisConfigurationCoverageIssues $c $items)} @($catalog,@($siteItem))
    Check ($unresolved.Count -eq @($catalogItems|Where-Object Kind -in @('IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig','IISWebConfigObservation')).Count -and @($unresolved|Where-Object {$_.ItemId -cne $siteItem.ItemId -or $_.Gate -cne 'ConfigurationCoverage'}).Count -eq 0) 'Selected IIS site did not receive scoped coverage issues for every unreviewed global, section, location and web.config item.'
    Check (@($unresolved|Where-Object {$_.Issue -match [regex]::Escape([string]$unknown[0].ItemId)}).Count -eq 1) 'Undeclared configuration was not bound to the currently selected IIS site consumer.'
    $integratedUnresolved=CallModule {param($c,$items) @(Get-WsmAssistiveWorkloadReviewIssues $c $items)} @($catalog,@($siteItem))
    Check (@($integratedUnresolved|Where-Object Gate -CEQ 'ConfigurationCoverage').Count -eq $unresolved.Count) 'Actual Assistive workload review consumer did not surface every unresolved selected-site IIS configuration issue.'
    $catalog.Assistive.Selections.Items[0].Selected=$false
    $notSelected=CallModule {param($c,$items) @(Get-WsmIisConfigurationCoverageIssues $c $items)} @($catalog,@($siteItem))
    Check ($notSelected.Count -eq 0) 'Configuration coverage gate blocked after the affected IIS site was deselected.'
    $catalog.Assistive.Selections.Items[0].Selected=$true
    foreach($configItem in @($catalog.Items|Where-Object Kind -in @('IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig','IISWebConfigObservation'))){$configItem.Decision='Include';$configItem|Add-Member NoteProperty MigrationSpec ([pscustomobject]@{Adapter='ManualWorkflow';Owner='Configuration owner';Evidence='Reviewed protected source evidence';Procedure='Review exact configuration evidence with affected site owner';Artifacts=@('Protected source config reference')}) -Force}
    $reviewed=CallModule {param($c,$items) @(Get-WsmIisConfigurationCoverageIssues $c $items)} @($catalog,@($siteItem))
    Check ($reviewed.Count -eq 0) 'Current owner-reviewed Include/ManualWorkflow dispositions did not close selected-site configuration coverage.'
    $integratedReviewed=CallModule {param($c,$items) @(Get-WsmAssistiveWorkloadReviewIssues $c $items)} @($catalog,@($siteItem))
    Check (@($integratedReviewed|Where-Object Gate -CEQ 'ConfigurationCoverage').Count -eq 0) 'Actual Assistive workload review consumer retained a stale IIS configuration coverage issue after owner review.'
    $excluded=$catalog.Items|Where-Object Kind -CEQ 'IISGlobalConfig'|Select-Object -First 1;$excluded.Decision='Exclude';$excluded.Reason='Owner determined global settings are not needed for this site.';$excluded|Add-Member NoteProperty ReviewedBy 'Fixture reviewer' -Force;$excluded|Add-Member NoteProperty ReviewedUtc '2026-10-10T00:00:00Z' -Force
    $withoutOwnerEvidence=CallModule {param($c,$items) @(Get-WsmIisConfigurationCoverageIssues $c $items)} @($catalog,@($siteItem))
    Check (@($withoutOwnerEvidence|Where-Object Issue -match 'applicationHost.config').Count -eq 1) 'A plain exclusion reason without owner/evidence incorrectly closed global configuration coverage.'
    $excluded|Add-Member NoteProperty Owner 'Configuration owner' -Force;$excluded|Add-Member NoteProperty Evidence 'Reviewed protected source and selected site' -Force
    $withOwnerEvidence=CallModule {param($c,$items) @(Get-WsmIisConfigurationCoverageIssues $c $items)} @($catalog,@($siteItem))
    Check ($withOwnerEvidence.Count -eq 0) 'Explicit owner/evidence exclusion did not close the current selected-site configuration impact.'
    $typedDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($section[0],$catalog)
    Check ($typedDraft.Adapter -ceq 'ManualWorkflow' -and $typedDraft.Procedure -match 'does not prove IIS site startup policy' -and $typedDraft.SourceAutoStart -eq $null -and $typedDraft.Artifacts -match 'Configuration feature enabled=true; site startup meaning Unknown') 'A generic section feature flag was incorrectly promoted to IIS startup state instead of separately retained feature evidence and manual review.'

    $globalItem=@($result|Where-Object Kind -CEQ 'IISGlobalConfig')[0];$globalDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($globalItem,$catalog)
    $externalDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($external[0],$catalog)
    $unknownDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($unknown[0],$catalog)
    $locationDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($locationParent[0],$catalog)
    Check (@(@($globalDraft.Adapter,$externalDraft.Adapter,$unknownDraft.Adapter,$locationDraft.Adapter)|Where-Object {$_ -eq 'ManualWorkflow'}).Count -eq 4) 'Global XML, configSource, undeclared section, or location container was offered an automatic typed restore.'
    Check ($globalDraft.Procedure -match 'do not overwrite applicationHost.config wholesale' -and $globalDraft.Artifacts -contains ('Parent global configuration item: '+$globalItem.ItemId)) 'Manual global-configuration draft omitted exact evidence references or safe procedure.'
    Check ($externalDraft.Procedure -match 'configSource files' -and $externalDraft.Artifacts -match 'configSource status: Captured') 'configSource typed draft did not remain manual with explicit linked evidence.'
    $staticDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($noActivation[0],$catalog)
    Check ($staticDraft.Adapter -ceq 'ManualWorkflow' -and $staticDraft.Procedure -match 'does not prove IIS site startup policy') 'A declared section feature field was incorrectly treated as IIS site startup.'
    $webDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($webConfig[0],$catalog)
    Check ($webDraft.Adapter -ceq 'ManualWorkflow' -and $webDraft.Procedure -match 'Resolve parent/child inheritance' -and $webDraft.Artifacts -match 'Captured SHA256:') 'Captured web.config did not produce an exact hash-bound manual procedure.'
    $limitedObservation=@($limited|Where-Object Kind -CEQ 'IISWebConfigObservation'|Select-Object -First 1)[0]
    $webObservationDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($limitedObservation,$catalog)
    Check ($webObservationDraft.Adapter -ceq 'ManualWorkflow' -and $webObservationDraft.Artifacts -match 'Capture status:') 'Blocked web.config evidence was not tracked as an exact manual workflow.'
    $unsupportedTask=CallModule {param($host) $task=New-WsmItem $host Tasks ScheduledTask '\Fixture\Unsupported' '\Fixture\Unsupported' @{TaskName='Unsupported';TaskPath='\Fixture\';Xml='<Task><Actions><ComHandler classId="{00000000-0000-0000-0000-000000000001}" /></Actions></Task>'};$task|Add-Member NoteProperty AccountMapping '' -Force;$task} @($hostId)
    $unsupportedDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($unsupportedTask,$catalog)
    Check ($unsupportedDraft.Adapter -ceq 'ManualWorkflow' -and $unsupportedDraft.Procedure -match 'unsupported action type' -and $unsupportedDraft.Artifacts -match 'Unsupported action references:') 'Unsupported scheduled-task action was offered as a synthesized native task rather than a tracked manual procedure.'

    $outsidePath=Join-Path $root 'outside.config';[IO.File]::WriteAllText($outsidePath,'<outside />',(New-Object Text.UTF8Encoding($false)))
    $escaped=CallModule {param($host,$path,$outside) $doc=Read-WsmXml ('<configuration><configSections><section name="escaped" /></configSections><escaped configSource="..\outside.config" /></configuration>');@(Get-WsmIisConfigurationInventoryItems $host $doc $path|Where-Object {$_.Settings.PSObject.Properties['SectionPath'] -and $_.Settings.SectionPath -ceq 'escaped'})} @($hostId,$configPath,$outsidePath)
    $escapedDraft=CallModule {param($item,$c) Get-WsmMigrationSpecDraft $item $c} @($escaped[0],$catalog)
    Check ($escaped[0].Settings.ConfigSource.Status -ceq 'ManualReviewRequired' -and $escapedDraft.Adapter -ceq 'ManualWorkflow') 'Parent traversal in configSource was accepted as typed input.'
    $largeConfigSource=Join-Path $configDir 'large.config';$largeStream=[IO.File]::Open($largeConfigSource,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None);$largeStream.SetLength(4194305);$largeStream.Dispose()
    $largeEvidence=CallModule {param($path,$config) $doc=Read-WsmXml '<configuration><oversized configSource="large.config" /></configuration>';Get-WsmIisConfigSourceEvidence $doc.DocumentElement.FirstChild $config} @($largeConfigSource,$configPath)
    Check ($largeEvidence.Status -ceq 'ManualReviewRequired' -and $largeEvidence.Reason -match '4 MiB') 'Oversized configSource bytes were read or accepted without a bounded manual observation.'
    $reparseTarget=Join-Path $root 'reparse-target';$reparseParent=Join-Path $configDir 'link';[void][IO.Directory]::CreateDirectory($reparseTarget);[IO.File]::WriteAllText((Join-Path $reparseTarget 'linked.config'),'<linked />',(New-Object Text.UTF8Encoding($false)));$junctionCreated=$false
    try{New-Item -ItemType Junction -Path $reparseParent -Target $reparseTarget -ErrorAction Stop|Out-Null;$junctionCreated=$true}catch{}
    if($junctionCreated){$linkedEvidence=CallModule {param($config) $doc=Read-WsmXml '<configuration><linked configSource="link\linked.config" /></configuration>';Get-WsmIisConfigSourceEvidence $doc.DocumentElement.FirstChild $config} @($configPath);Check ($linkedEvidence.Status -ceq 'ManualReviewRequired' -and $linkedEvidence.Reason -match 'reparse|link|junction') 'configSource resolver followed a directory reparse point outside its protected parent.'}
    $reparseWebRoot=Join-Path $root 'reparse-webroot';$outsideWebRoot=Join-Path $root 'outside-webroot';[void][IO.Directory]::CreateDirectory($reparseWebRoot);[void][IO.Directory]::CreateDirectory($outsideWebRoot);[IO.File]::WriteAllText((Join-Path $outsideWebRoot 'web.config'),'<configuration />',(New-Object Text.UTF8Encoding($false)));$webJunction=Join-Path $reparseWebRoot 'external';$webJunctionCreated=$false
    try{New-Item -ItemType Junction -Path $webJunction -Target $outsideWebRoot -ErrorAction Stop|Out-Null;$webJunctionCreated=$true}catch{}
    if($webJunctionCreated){$reparseSite=CallModule {param($host,$path) New-WsmItem $host Web IISSite 'Reparse root' 'Reparse root' @{Xml=('<site name="Reparse root"><application path="/"><virtualDirectory path="/" physicalPath="'+$path+'" /></application></site>')}} @($hostId,$reparseWebRoot);$reparseScan=CallModule {param($host,$site) @(Get-WsmIisWebConfigInventoryItems $host @($site))} @($hostId,$reparseSite);Check (@($reparseScan|Where-Object Kind -CEQ 'IISWebConfig').Count -eq 0 -and @($reparseScan|Where-Object {$_.Kind -eq 'IISWebConfigObservation' -and $_.Settings.Status -ceq 'ReparsePointSkipped'}).Count -eq 1) 'web.config traversal followed a nested reparse point instead of retaining its explicit skipped-subtree observation.'}
    Write-Host ('PASS: '+$passed+' IIS configuration coverage checks. Native IIS/server behavior remains NotTested; the readback was a test seam.')
} finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
