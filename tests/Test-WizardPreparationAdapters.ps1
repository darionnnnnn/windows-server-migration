#requires -Version 5.1
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '..\src\WindowsServerMigration.psd1') -Force -PassThru
. (Join-Path $PSScriptRoot 'Helper-Fixtures.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('w-'+[Guid]::NewGuid().ToString('N').Substring(0,12))
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0;$script:gaps=New-Object 'System.Collections.Generic.List[string]';$script:tested=New-Object 'System.Collections.Generic.List[string]';$script:unsupported=New-Object 'System.Collections.Generic.List[string]'
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{& $Action | Out-Null}catch{$rejected=$true};Check $rejected $Message}
function CallModule([scriptblock]$Block,[object[]]$Arguments=@()){& $script:module $Block @Arguments}
function SaveJson($Value,[string]$Path){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 80 -Compress),(New-Object Text.UTF8Encoding($false)));$Path}
function Add-ReviewGap([string]$Adapter,[string]$Phase,$ErrorRecord){$detail=if($ErrorRecord -is [string]){[string]$ErrorRecord}else{[string]$ErrorRecord.Exception.Message};if($ErrorRecord -isnot [string] -and $ErrorRecord.Exception.InnerException){$detail+=' | inner='+$ErrorRecord.Exception.InnerException.GetType().FullName+': '+$ErrorRecord.Exception.InnerException.Message+' HRESULT='+$ErrorRecord.Exception.InnerException.HResult};if($ErrorRecord -isnot [string] -and $ErrorRecord.ScriptStackTrace){$detail+=' | '+[string]$ErrorRecord.ScriptStackTrace};$script:gaps.Add(($Adapter+' '+$Phase+': '+$detail));Write-Host ('GAP: '+$Adapter+' '+$Phase+': '+$detail)}
function Invoke-PreparationAdapter([string]$Workspace,[string]$PairId,[string]$ItemId,[string]$Adapter,[Collections.IDictionary]$Answers){
    try{
        $review=CallModule {param($w,$p,$id) Get-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id} @($Workspace,$PairId,$ItemId)
        Check ($review.Kind -ceq 'WizardPreparationReview' -and $review.ItemId -ceq $ItemId -and $review.Adapter -ceq $Adapter -and $review.ReviewHash -match '^[a-f0-9]{64}$') ($Adapter+' review was not produced by the enrolled Manager wizard.')
        $before=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($Workspace,$PairId)
        $itemBefore=@($before.Items|Where-Object ItemId -CEQ $ItemId);if($itemBefore.Count -ne 1){throw 'Source inventory identity is missing or ambiguous.'}
        $sourceSettingsHash=[string]$itemBefore[0].SettingsHash
        $sourcePath='';if($itemBefore[0].MigrationSpec -and $itemBefore[0].MigrationSpec.PSObject.Properties['SourcePath']){$sourcePath=[string]$itemBefore[0].MigrationSpec.SourcePath}
        $sourceXmlHash='';if($itemBefore[0].MigrationSpec -and $itemBefore[0].MigrationSpec.PSObject.Properties['SourceXml']){$sourceXmlHash=CallModule {param($v) Get-WsmHashText $v} @([string]$itemBefore[0].MigrationSpec.SourceXml)}
        $owner='Fixture '+$Adapter+' owner';$evidence='Owner reviewed this exact isolated fixture and supplied the typed decision.'
        $saved=CallModule {param($w,$p,$id,$hash,$o,$e,$a) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner $o -Evidence $e -Answers $a} @($Workspace,$PairId,$ItemId,$review.ReviewHash,$owner,$evidence,$Answers)
        $after=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($Workspace,$PairId);$row=@($after.Items|Where-Object ItemId -CEQ $ItemId)
        Check ($row.Count -eq 1 -and $row[0].MigrationSpec.Adapter -ceq $Adapter -and $row[0].MigrationSpec.Owner -ceq $owner -and $row[0].MigrationSpec.Evidence -ceq $evidence) ($Adapter+' typed answers did not reach the catalog spec through the wizard submit.')
        Check ($after.DecisionRevision -eq ($before.DecisionRevision+1) -and -not $after.Approval -and $saved.DecisionRevision -eq $after.DecisionRevision) ($Adapter+' did not use one native CAS update or unexpectedly approved the plan.')
        Check ([IO.File]::Exists($saved.SpecPath) -and (Get-FileHash -LiteralPath $saved.SpecPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $saved.SpecHash -and $saved.ProtectedArtifact) ($Adapter+' protected specification artifact hash does not match its actual bytes.')
        Check ([string]$row[0].SettingsHash -ceq $sourceSettingsHash) ($Adapter+' review changed source inventory settings identity.')
        if($sourcePath){Check ([string]$row[0].MigrationSpec.SourcePath -ceq $sourcePath) ($Adapter+' review changed protected source path.')}
        if($sourceXmlHash){$afterXml=CallModule {param($v) Get-WsmHashText $v} @([string]$row[0].MigrationSpec.SourceXml);Check ($afterXml -ceq $sourceXmlHash) ($Adapter+' review changed the protected source XML bytes.')}
        $script:tested.Add($Adapter)
        [pscustomobject]@{Adapter=$Adapter;Review=$review;Saved=$saved;Catalog=$after;Spec=$row[0].MigrationSpec}
    }catch{$catalogPath=CallModule {param($w,$p) Get-WsmCatalogPath $w $p} @($Workspace,$PairId);$pairDirectory=[IO.Path]::GetDirectoryName($catalogPath);$specDir=Join-Path (Join-Path $Workspace 'assistive') 'review-forms';$specPath=Join-Path $specDir ('spec-'+$PairId+'-'+$ItemId+'-'+('0'*32)+'.json');$normalized=[IO.Path]::GetFullPath($specPath);$detail=' catalogPath='+$catalogPath+' length='+$catalogPath.Length+' rooted='+[IO.Path]::IsPathRooted($catalogPath)+' exists='+[IO.File]::Exists($catalogPath)+' parentExists='+[IO.Directory]::Exists($pairDirectory)+' specPath='+$specPath+' specPathLength='+$specPath.Length+' specPathRooted='+[IO.Path]::IsPathRooted($specPath)+' normalizedSpecPath='+$normalized+' normalizedLength='+$normalized.Length+' currentDirectory='+[Environment]::CurrentDirectory+' powershellLocation='+[string](Get-Location)+' workspace='+$Workspace;if($_.Exception.InnerException){$detail+=' inner='+$_.Exception.InnerException.GetType().FullName+': '+$_.Exception.InnerException.Message+' HRESULT='+$_.Exception.InnerException.HResult};Add-ReviewGap $Adapter 'wizard-save-submit' ([pscustomobject]@{Exception=[Exception]::new(([string]$_.Exception.Message+$detail),$_.Exception);ScriptStackTrace=$_.ScriptStackTrace});return $null}
}
try {
    $source=[pscustomobject][ordered]@{HostId=[Guid]::NewGuid().ToString('D');Fingerprint=('a'*64);Name='Preparation adapter fixture source';OS='Windows Server';Version='2025'}
    $sourceXmlTask='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>SYSTEM</UserId><LogonType>ServiceAccount</LogonType></Principal></Principals><Triggers/><Settings><Enabled>false</Enabled><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy></Settings><Actions><Exec><Command>C:\fixture\job.exe</Command><WorkingDirectory>C:\fixture</WorkingDirectory></Exec></Actions></Task>'
    $taskSecurity=CallModule {param($sddl) $folders=@(Get-WsmTaskSecurityFolderAncestors '\Fixture\'|ForEach-Object {[pscustomobject]@{Path=$_;SecuritySddl=$sddl;SecurityHash=(Get-WsmHashText $sddl)}});[pscustomobject]@{TaskSecurityCapture=[pscustomobject]@{Kind='TaskSecurityCapture';SchemaVersion=1;TaskName='FixtureJob';TaskPath='\Fixture\';TaskFullPath='\Fixture\FixtureJob';TaskSecuritySddl=$sddl;TaskSecurityHash=(Get-WsmHashText $sddl);Folders=$folders};TaskSecurityCaptureStatus='Captured'}} @('O:SYG:SYD:(A;;FA;;;SY)')
    $items=New-Object 'System.Collections.Generic.List[object]'
    $file=CallModule {param($h) New-WsmItem $h Storage PathCandidate 'Fixture business files' 'C:\FixtureData\source' @{OriginalPath='C:\FixtureData\source';ResolvedCandidate='C:\FixtureData\source'}} @($source.HostId);$items.Add($file)
    $manual=CallModule {param($h) New-WsmItem $h Runtime App 'Fixture owner-installed runtime' 'fixture-runtime' @{Version='1.0'}} @($source.HostId);$items.Add($manual)
    $task=CallModule {param($h,$xml,$capture) New-WsmItem $h Tasks ScheduledTask 'Fixture scheduled task' '\Fixture\FixtureJob' @{TaskName='FixtureJob';TaskPath='\Fixture\';Xml=$xml;TaskSecurityCapture=$capture.TaskSecurityCapture;TaskSecurityCaptureStatus='Captured'}} @($source.HostId,$sourceXmlTask,$taskSecurity);$items.Add($task)
    $taskFolder=CallModule {param($h) New-WsmItem $h Tasks TaskFolder '\Fixture\' '\Fixture\' @{Path='\Fixture\';SecuritySddl='O:SYG:SYD:(A;;FA;;;SY)';SecurityCaptureStatus='Captured';RawEvidenceProtected=$true}} @($source.HostId);$items.Add($taskFolder)
    $siteXml='<site name="FixtureSite" id="1" serverAutoStart="false"><bindings><binding protocol="http" bindingInformation="*:8080:fixture.example" /></bindings><application path="/" applicationPool="FixturePool"><virtualDirectory path="/" physicalPath="C:\FixtureData\site" /></application></site>'
    $site=CallModule {param($h,$xml) New-WsmItem $h Web IISSite 'Fixture IIS site' 'FixtureSite' @{Xml=$xml;ConfigurationFile='fixture applicationHost.config';CaptureScope='Site and nested applications';StartupConfiguration=[pscustomobject]@{Enabled='Unknown';SourceAutoStart='Unknown'};ObservedRuntime=[pscustomobject]@{State='NotObserved';Evidence='isolated fixture'}}} @($source.HostId,$siteXml);$items.Add($site)
    $poolXml='<add name="FixturePool" managedRuntimeVersion="v4.0" managedPipelineMode="Integrated" enable32BitAppOnWin64="false" startMode="OnDemand" queueLength="1000" autoStart="false" />'
    $pool=CallModule {param($h,$xml) New-WsmItem $h Web IISPool 'Fixture IIS pool' 'FixturePool' @{Xml=$xml;ConfigurationFile='fixture applicationHost.config';CaptureScope='Application pool';StartupConfiguration=[pscustomobject]@{Enabled='Unknown';SourceAutoStart='Unknown'};ObservedRuntime=[pscustomobject]@{State='NotObserved';Evidence='isolated fixture'}}} @($source.HostId,$poolXml);$items.Add($pool)
    $iisSection=CallModule {param($h) New-WsmItem $h Web IISSectionConfig 'Fixture typed IIS section' 'fixture-section' @{ConfigurationFile='fixture applicationHost.config';SectionPath='system.webServer/security/access';LocationPath='';SourceXml='<access enabled="false" sslFlags="None"><rule name="fixture-rule" enabled="true" /></access>';DefinitionKnown=$true;CoverageReason='isolated typed config fixture'}} @($source.HostId);$items.Add($iisSection)
    $iisLocation=CallModule {param($h) New-WsmItem $h Web IISLocationConfig 'Fixture typed IIS location' 'fixture-location' @{ConfigurationFile='fixture applicationHost.config';SectionPath='system.webServer/security/access';LocationPath='FixtureSite/';SourceXml='<access enabled="false" sslFlags="None"><rule name="fixture-rule" enabled="true" /></access>';DefinitionKnown=$true;CoverageReason='isolated typed location fixture'}} @($source.HostId);$items.Add($iisLocation)
    $serviceSettings=[pscustomobject][ordered]@{Name='FixtureSvc';DisplayName='Fixture service';Description='Isolated review fixture';PathName='C:\Fixture\service.exe';StartMode='Manual';StartName='FIXTURE\svc-account';ServiceType='Win32OwnProcess';Supplement=(New-WsmFixtureServiceSupplement)}
    $service=CallModule {param($h,$s) New-WsmItem $h Services Service 'Fixture service' 'FixtureSvc' $s @() Success Service} @($source.HostId,$serviceSettings);$items.Add($service)
    $shareSettings=[pscustomobject][ordered]@{Definition=[pscustomobject][ordered]@{Name='FixtureShare';ScopeName='*';Path='C:\FixtureData\share';Description='Initial fixture share';EncryptData=$false};Access=@([pscustomobject][ordered]@{AccountName='FIXTURE\Readers';AccessControlType='Allow';AccessRight='Read'})}
    $share=CallModule {param($h,$s) New-WsmItem $h Storage Share 'Fixture SMB share' 'FixtureShare' $s @() Success SmbShare} @($source.HostId,$shareSettings);$items.Add($share)
    $localUserSettings=[pscustomobject][ordered]@{Name='fixture-user';SID='S-1-5-21-111111111-222222222-333333333-1001';Disabled=$true;FullName='Initial fixture user';Description='Initial fixture description'}
    $localUser=CallModule {param($h,$s) New-WsmItem $h Identity LocalUser 'Fixture local user' $s.SID $s @() Success LocalUser} @($source.HostId,$localUserSettings);$items.Add($localUser)
    $localGroupSettings=[pscustomobject][ordered]@{Name='Fixture Operators';SID='S-1-5-21-111111111-222222222-333333333-2001';Members=@([pscustomobject][ordered]@{Name='fixture-reader';Domain='FIXTURE';SID='S-1-5-21-111111111-222222222-333333333-1002'})}
    $localGroup=CallModule {param($h,$s) New-WsmItem $h Identity LocalGroup 'Fixture local group' $s.SID $s @() Success LocalGroup} @($source.HostId,$localGroupSettings);$items.Add($localGroup)
    # A real public-only certificate is a safe isolated artifact placeholder;
    # the wizard may reference its bytes but never receives private key material.
    $fixtureRsa=[Security.Cryptography.RSA]::Create(2048)
    try{$certificateRequest=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=fixture.invalid',$fixtureRsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1);$fixtureCertificate=$certificateRequest.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddDays(30));try{$certificateBytes=$fixtureCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert);$certificateThumbprint=[string]$fixtureCertificate.Thumbprint;$certificateNotAfter=$fixtureCertificate.NotAfter.ToUniversalTime().ToString('o')}finally{$fixtureCertificate.Dispose()}}finally{$fixtureRsa.Dispose()}
    $certificateArtifact=Join-Path $root 'fixture-public.cer';[IO.File]::WriteAllBytes($certificateArtifact,$certificateBytes);$certificateArtifactHash=(Get-FileHash -LiteralPath $certificateArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $certificateSettings=[pscustomobject][ordered]@{Thumbprint=$certificateThumbprint;Store='LocalMachine\My';HasPrivateKey=$false;Subject='CN=fixture.invalid';NotAfter=$certificateNotAfter}
    $certificate=CallModule {param($h,$s) New-WsmItem $h Certificates Certificate 'Fixture certificate reference' 'fixture-certificate' $s @() Success Certificate} @($source.HostId,$certificateSettings);$items.Add($certificate)
    $feature=CallModule {param($h) $item=New-WsmItem $h Roles WindowsFeature 'Fixture Windows feature' 'FixtureFeature' @{Name='FixtureFeature';Installed=$false};$item|Add-Member NoteProperty Classification (Get-WsmScopeClassification $item) -Force;$item} @($source.HostId);$items.Add($feature)
    $inventory=CallModule {param($s,$rows) New-WsmInventory $s 1 @($rows)} @($source,$items.ToArray())
    $inventory|Add-Member NoteProperty SoftwareCatalog (CallModule {param($inv) $software=[pscustomobject][ordered]@{SchemaVersion=1;ToolVersion='0.4.0';Kind='SoftwareCatalog';Source=[pscustomobject][ordered]@{HostId=$inv.Source.HostId;Fingerprint=$inv.Source.Fingerprint;Name=$inv.Source.Name;InventoryRevision=[int]$inv.Revision;InventoryProjectionHash=(Get-WsmSoftwareInventoryProjectionHash $inv)};CaptureContext=[pscustomobject][ordered]@{CapturedUtc=(Get-WsmUtc);CaptureIdentity='fixture';AccountContext='Unknown';CaptureHost='isolated fixture';PowerShellVersion=$PSVersionTable.PSVersion.ToString();RequestedPortableRoots=@()};Entries=@();Coverage=@([pscustomobject][ordered]@{Probe='Uninstall';Scope='Machine';SID='';View='Registry64';Status='Success';EvidenceKind='Registry';Count=0;Budget=[pscustomobject]@{MaxEntries=100};ErrorKind=$null;ObservedUtc=(Get-WsmUtc)});PreparationRequirements=@();CatalogProjectionHash=('0'*64)};$software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software;Assert-WsmSoftwareCatalog $software -SourceInventory $inv|Out-Null;$software} @($inventory)) -Force
    CallModule {param($inv) $installPath='C:\FixtureData\source\VendorRuntime';$entry=[pscustomobject][ordered]@{SoftwareId=(Get-WsmSoftwareStableId 'Machine' '' 'Registry64' $installPath 'fixture-runtime');Name='Fixture installed runtime';Version='1.0';Publisher='Fixture';Architecture='Unknown';Scope='Machine';SID='';RegistryView='Registry64';Location=$installPath;SourceKind='Registry';Evidence=[pscustomobject]@{RegistryPath='HKLM\Software\FixtureRuntime';NaturalKey='fixture-runtime'};ObservedUtc=(Get-WsmUtc);CaptureStatus='Success';ItemIds=@();AccountContext='Unknown'};$software=$inv.SoftwareCatalog;$software.Entries=@($entry);$software.Coverage[0].Count=1;$software.PreparationRequirements=@([pscustomobject][ordered]@{PreparationId=('prep-'+$entry.SoftwareId.Substring(3));SoftwareId=$entry.SoftwareId;Status='NeedsOwnerReview';RequiredPhase='PreparationReady';EvidenceStatus='Success';ConsumerItemIds=@();Owner='';Reason='Captured source metadata only; explicit owner decision required.'});$software.Source.InventoryProjectionHash=Get-WsmSoftwareInventoryProjectionHash $inv;$software.CatalogProjectionHash=Get-WsmSoftwareCatalogProjectionHash $software;Assert-WsmSoftwareCatalog $software -SourceInventory $inv|Out-Null} @($inventory)
    $inventory|Add-Member NoteProperty WorkloadDiscovery (CallModule {param($inv) Get-WsmWorkloadDiscovery $inv} @($inventory)) -Force
    $inventoryPath=Join-Path $root 'source-inventory.json';SaveJson $inventory $inventoryPath|Out-Null;$inventoryHash=(Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $workspace=Join-Path $root 'manager';CallModule {param($w) Initialize-WsmWizardWorkspace $w Manager|Out-Null} @($workspace)
    $catalog=CallModule {param($w,$p,$h) Import-WsmInventory $w $p $h 'isolated preparation target'} @($workspace,$inventoryPath,$inventoryHash)
    $catalog=CallModule {param($w,$p,$r) Enable-WsmAssistiveMode $w $p $r} @($workspace,$catalog.PairId,$catalog.DecisionRevision)

    foreach($configItem in @($iisSection,$iisLocation)){
        $adapter=if($configItem.ItemId -ceq $iisSection.ItemId){'IISSection'}else{'IISLocation'}
        $sourceConfig=[string]$configItem.Settings.SourceXml;$activationPointer='/access/rule[@name=''fixture-rule'']/@enabled'
        $changes=@(
            [pscustomobject][ordered]@{FieldPointer='/access/@sslFlags';Operation='SetAttribute';ElementName='access';KeyAttributes=@();AttributeName='sslFlags';BeforeValue='None';AfterValue='Sni'},
            [pscustomobject][ordered]@{FieldPointer=$activationPointer;Operation='SetAttribute';ElementName='rule';KeyAttributes=@([pscustomobject]@{Name='name';Value='fixture-rule'});AttributeName='enabled';BeforeValue='true';AfterValue='false'}
        )
        $spec=[pscustomobject][ordered]@{Adapter=$adapter;Owner='Initial fixture owner';Evidence='Initial protected typed fixture';DesiredFinalState='Disabled';BusinessChecks=@('Verify exact section value on an isolated fixture');SourceXml=$sourceConfig;SourceAutoStart='true';StagedDisabled=$true;ActivationPolicyFieldPointer=$activationPointer;ReviewedActivation=$null;WorkloadMappingReview=@();SharedResourceImpacts=@();Desired=[pscustomobject][ordered]@{SectionPath='system.webServer/security/access';LocationPath=$(if($adapter -ceq 'IISLocation'){'FixtureSite/'}else{''});Xml=$sourceConfig;Changes=@()}}
        CallModule {param($s,$rows,$pointer) Set-WsmAssistiveIisConfigReview $s @{ActivationPolicyFieldPointer=$pointer;IisConfigChanges=$rows;DesiredFinalState='Disabled';ActivationOwner='Config owner';ActivationReason='Keep isolated typed configuration staged until separately approved.'}} @($spec,$changes,$activationPointer)
        $specPath=Join-Path $root ($adapter+'-seed.json');SaveJson $spec $specPath|Out-Null;$specHash=(Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash.ToLowerInvariant()
        CallModule {param($w,$p,$id,$path,$hash,$revision) Set-WsmMigrationSpec -Workspace $w -PairId $p -ItemId $id -Path $path -ExpectedHash $hash -ExpectedRevision $revision|Out-Null} @($workspace,$catalog.PairId,$configItem.ItemId,$specPath,$specHash,$catalog.DecisionRevision)
        $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
    }

    $fileAnswers=@{TargetPath='C:\FixtureData\target';ContentSelection='WholeScope';BusinessChecks="Read the fixture file`nVerify the owner-selected data"}
    $fileResult=Invoke-PreparationAdapter $workspace $catalog.PairId $file.ItemId 'FileScope' $fileAnswers
    if($fileResult){Check ($fileResult.Spec.TargetPath -ceq 'C:\FixtureData\target' -and $fileResult.Spec.ContentSelection -ceq 'WholeScope') 'FileScope user answers were not preserved.';Check (@($fileResult.Spec.ExcludedRelativePaths) -contains 'VendorRuntime') 'A uniquely trusted nested software root was not carried from the hash-bound review form into the saved scope.';Check ($fileResult.Review.SoftwareExclusionCandidates.Count -eq 1 -and $fileResult.Review.SoftwareExclusionCandidates[0].SourceInventoryHash -ceq $fileResult.Review.SourceSnapshotHash -and $fileResult.Review.SoftwareExclusionCandidates[0].Selection -ceq 'SuggestedForReview') 'Installed-software exclusion suggestion lacked same-work inventory hash provenance or explicit review status.'}
    $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
    $manualAnswers=@{Product='Fixture application runtime';Procedure='Owner installs the approved runtime, verifies version and runs business checks.';Artifacts="Installer reference`nOwner validation record";BusinessChecks="Verify application starts`nConfirm business workflow"}
    $manualResult=Invoke-PreparationAdapter $workspace $catalog.PairId $manual.ItemId 'ManualWorkflow' $manualAnswers
    if($manualResult){Check ($manualResult.Spec.Procedure -match 'Owner installs' -and @($manualResult.Spec.Artifacts).Count -eq 2) 'Manual workflow typed answers were lost.'}
    $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
    $taskAnswers=@{CatchUpPolicy='SkipMissedRuns';ActivationOwner='Task owner';ActivationReason='Keep fixture task disabled until separately approved.';DesiredFinalState='Disabled';'WorkloadFieldReviews/0/Value'='C:\FixtureData\target\job.exe'}
    $taskResult=Invoke-PreparationAdapter $workspace $catalog.PairId $task.ItemId 'ScheduledTask' $taskAnswers
    if($taskResult){Check ($taskResult.Spec.CatchUpPolicy -ceq 'SkipMissedRuns' -and $taskResult.Spec.DesiredFinalState -ceq 'Disabled') 'ScheduledTask typed choices were not preserved.';Check ($taskResult.Spec.Desired.Xml -match 'C:\\FixtureData\\target\\job.exe') 'ScheduledTask WorkloadFieldReview.Value did not reach the desired task XML.'}
    $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
    $siteAnswers=@{ActivationOwner='IIS site owner';ActivationReason='Keep the site staged until its owner approves activation.';DesiredFinalState='Disabled'}
    $siteAnswers['IisBindings/0/BindingInformation']='*:8081:fixture.example';$siteAnswers['IisApplicationPools/0/PoolName']='FixturePool';$siteAnswers['WorkloadFieldReviews/0/Value']='C:\FixtureData\target\site'
    $siteResult=Invoke-PreparationAdapter $workspace $catalog.PairId $site.ItemId 'IISSite' $siteAnswers
    if($siteResult){Check ($siteResult.Spec.Desired.Xml -match '\*:8081:fixture.example' -and $siteResult.Spec.DesiredFinalState -ceq 'Disabled') 'IISSite binding or activation decision did not reach its typed consumer.'}
    $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
    $poolAnswers=@{ActivationOwner='IIS pool owner';ActivationReason='Keep the pool staged until its owner approves activation.';DesiredFinalState='Disabled'}
    $poolAnswers['IisPoolSettings/queueLength']='1001'
    $poolResult=Invoke-PreparationAdapter $workspace $catalog.PairId $pool.ItemId 'IISPool' $poolAnswers
    if($poolResult){Check ($poolResult.Spec.Desired.Xml -match 'queueLength="1001"' -and $poolResult.Spec.StagedDisabled) 'IISPool typed setting did not reach its staged desired XML.'}
    $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
    foreach($configItem in @($iisSection,$iisLocation)){
        $adapter=if($configItem.ItemId -ceq $iisSection.ItemId){'IISSection'}else{'IISLocation'}
        try{$typedReview=CallModule {param($w,$p,$id) Get-WsmAssistiveSpecReview $w $p $id} @($workspace,$catalog.PairId,$configItem.ItemId);$wizardReview=CallModule {param($w,$p,$id) Get-WsmWizardPreparationReview $w $p $id} @($workspace,$catalog.PairId,$configItem.ItemId)
            if(-not @($wizardReview.FormFields|Where-Object {$_.key -match '^(?:IisConfigChanges|DesiredChanges)/0/AfterValue$' -and $_.editable -and $_.value -ceq ''}).Count){Add-ReviewGap $adapter 'AfterValue-form-field' 'The wizard review does not expose the safe blank IIS AfterValue decision; source BeforeValue and pointer must stay protected.'}
            if(@($wizardReview.FormFields|Where-Object {$_.key -match '^(?:IisConfigChanges|DesiredChanges)/0/(?:BeforeValue|FieldPointer)$' -and $_.editable}).Count){Add-ReviewGap $adapter 'protected-IIS-identity' 'The wizard exposes a protected source value or pointer as editable.'}
            # S10: typed IIS identity fields are display-only and a tampered answer is refused explicitly.
            foreach($identityName in @('Operation','ElementName','AttributeName')){$identityRows=@($wizardReview.FormFields|Where-Object {$_.key -match ('^(?:IisConfigChanges|DesiredChanges)/\d+/'+$identityName+'$')});Check ($identityRows.Count -ge 1 -and -not @($identityRows|Where-Object editable).Count) ($adapter+' exposes IIS identity field '+$identityName+' as editable or omits it (S10).')}
            Check (-not @($wizardReview.FormFields|Where-Object {$_.key -match '/ValuesWithheld$' -and $_.editable}).Count) ($adapter+' exposes ValuesWithheld as editable (S10).')
            $tamperKey=[string]@($wizardReview.FormFields|Where-Object {$_.key -match '/0/Operation$'})[0].key;$tamperMessage=''
            try{CallModule {param($w,$p,$id,$hash,$k) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'fixture owner' -Evidence 'tampered identity field' -Answers @{$k='RemoveAttribute'}|Out-Null} @($workspace,$catalog.PairId,$configItem.ItemId,$wizardReview.ReviewHash,$tamperKey)}catch{$tamperMessage=[string]$_.Exception.Message}
            Check ($tamperMessage -like '*source-derived or unknown review field*') ($adapter+' accepted or silently ignored a tampered IIS Operation answer (S10); message='+$tamperMessage)
            $iisAnswers=@{};for($i=0;$i -lt $typedReview.TypedFields.IisConfigChanges.Count;$i++){$change=$typedReview.TypedFields.IisConfigChanges[$i];$value=[string]$change.AfterValue;if($change.FieldPointer -ceq $activationPointer){$value='false'}elseif($change.AttributeName -ceq 'sslFlags'){$value='Sni'};if($value){$iisAnswers['IisConfigChanges/'+$i+'/AfterValue']=$value}}
            [void](Invoke-PreparationAdapter $workspace $catalog.PairId $configItem.ItemId $adapter $iisAnswers)
        }catch{Add-ReviewGap $adapter 'review-form' $_}
        $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
    }
    foreach($row in @($catalog.Items|Where-Object ItemId -in @($service.ItemId,$share.ItemId,$localUser.ItemId,$localGroup.ItemId,$certificate.ItemId))){
        $adapter='';try{$review=CallModule {param($w,$p,$id) Get-WsmWizardPreparationReview $w $p $id} @($workspace,$catalog.PairId,$row.ItemId);$adapter=[string]$review.Adapter}catch{Add-ReviewGap ([string]$row.Kind) 'wizard-review' $_;continue}
        $sourceSettingsHash=[string]$row.SettingsHash
        $typedNames=@($review.FormFields|ForEach-Object {$_.key}|Sort-Object -Unique)
        $answer=@{};$requiredDesired=@()
        switch($adapter){
            Service {$answer=@{'Desired/Description'='Reviewed fixture service description';SecretRef='fixture_service_account';BusinessChecks='Owner verifies fixture service configuration and disabled staging.'};$requiredDesired=@('Desired/Description','SecretRef')}
            SmbShare {$answer=@{'Desired/Path'='C:\FixtureData\approved-share';'Desired/Description'='Owner-reviewed fixture share';'Desired/EncryptData'=$true;'Desired/DrainPolicy'='BlockNewOpens';'Desired/DrainEvidence'='Fixture owner reviewed the isolated share drain.';'Desired/Access/0/AccountName'='FIXTURE\Editors';'Desired/Access/0/AccessRight'='Change'};$requiredDesired=@('Desired/Path','Desired/Description','Desired/EncryptData','Desired/DrainPolicy','Desired/DrainEvidence','Desired/Access/0/AccountName','Desired/Access/0/AccessRight')}
            LocalUser {$answer=@{'Desired/FullName'='Fixture reviewed user';'Desired/Description'='Nonsecret isolated account review';SecretRef='fixture_local_user'};$requiredDesired=@('Desired/FullName','Desired/Description','SecretRef')}
            LocalGroup {$answer=@{'Desired/Description'='Owner-reviewed isolated group';'Desired/Members'="FIXTURE\fixture-editor`nFIXTURE\fixture-reader"};$requiredDesired=@('Desired/Description','Desired/Members')}
            Certificate {$answer=@{'Desired/ArtifactPath'=$certificateArtifact;BusinessChecks='Owner confirms the public-only fixture certificate artifact and target store.'};$requiredDesired=@('Desired/ArtifactPath')}
            default {$answer=@{BusinessChecks='Owner verifies fixture configuration and disabled staging.'}}
        }
        foreach($key in $requiredDesired){if(-not @($review.FormFields|Where-Object {$_.key -ceq $key -and $_.editable}).Count){$available=@($review.FormFields|ForEach-Object {([string]$_.key)+' [editable='+[string]$_.editable+' label='+[string]$_.label+']'});Add-ReviewGap $adapter 'typed-consumer-access' ('The genuine wizard review does not expose required safe field '+$key+' as editable; actual fields: '+($available -join '; '))}}
        foreach($key in $requiredDesired){$field=@($review.FormFields|Where-Object key -CEQ $key|Select-Object -First 1);if($field.Count -and [string]$field[0].label -ceq $key){Add-ReviewGap $adapter 'plain-language-label' ('The supported typed decision still shows its raw key: '+$key)}}
        if($adapter -in @('LocalUser','Service')){$secretField=@($review.FormFields|Where-Object key -CEQ 'SecretRef');Check ($secretField.Count -eq 1 -and $secretField[0].value -ceq '' -and $secretField[0].editable -and $secretField[0].required -and $secretField[0].label -match '參照名稱') ($adapter+' did not request a blank, explicit reference-only SecretRef.')}
        if($adapter -ceq 'Certificate'){$certFields=@($review.FormFields|ForEach-Object {([string]$_.key)+' editable='+[string]$_.editable+' required='+[string]$_.required+' value='+[string]$_.value});$hashRows=@($review.FormFields|Where-Object {$_.key -ceq 'Desired/ArtifactHash' -and -not $_.editable});$pathRows=@($review.FormFields|Where-Object {$_.key -ceq 'Desired/ArtifactPath' -and $_.editable -and $_.required});$privateRows=@($review.FormFields|Where-Object {$_.key -match '(?i)(?:^|/)(?:PrivateKey|PrivateKeyPath|Password|Pfx|PfxPassword)(?:$|/)'});Check ($hashRows.Count -eq 1 -and $pathRows.Count -eq 1 -and $privateRows.Count -eq 0) ('Certificate form did not require a public CER path, expose its hash read-only, or withhold private-key material; hashRows='+$hashRows.Count+' pathRows='+$pathRows.Count+' privateRows='+$privateRows.Count+' fields='+($certFields -join '; '));Reject {CallModule {param($w,$p,$id,$hash) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'fixture owner' -Evidence 'missing CER path' -Answers @{'Desired/ArtifactPath'=''}} @($Workspace,$PairId,$ItemId,$review.ReviewHash)} 'A public certificate with no ArtifactPath was saved.'}
        if($adapter -ceq 'SmbShare'){
            # S9: the real draft carries the placeholder DrainPolicy; the form must present it as a required choice and the save must fail with a field pointer.
            $drainPolicy=@($review.FormFields|Where-Object key -CEQ 'Desired/DrainPolicy');$drainEvidence=@($review.FormFields|Where-Object key -CEQ 'Desired/DrainEvidence')
            Check ($drainPolicy.Count -eq 1 -and $drainPolicy[0].type -ceq 'choice' -and $drainPolicy[0].required -and $drainPolicy[0].editable -and $drainPolicy[0].origin -ceq 'NeedsHumanDecision' -and $drainEvidence.Count -eq 1 -and $drainEvidence[0].required) ('S9: the real SmbShare draft did not present DrainPolicy as a required choice needing a decision (type='+[string]@($drainPolicy)[0].type+'; value='+[string]@($drainPolicy)[0].value+').')
            $withoutPolicy=@{};foreach($k in $answer.Keys){if($k -cne 'Desired/DrainPolicy'){$withoutPolicy[$k]=$answer[$k]}}
            $pointerMessage='';try{CallModule {param($w,$p,$id,$hash,$a) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'fixture owner' -Evidence 'drain policy left at the placeholder' -Answers $a|Out-Null} @($workspace,$catalog.PairId,$row.ItemId,$review.ReviewHash,$withoutPolicy)}catch{$pointerMessage=[string]$_.Exception.Message}
            Check ($pointerMessage -like '*PreparationFieldValidation|/Answers/Desired~1DrainPolicy|option*') ('S9: an unanswered DrainPolicy placeholder did not fail with its field pointer; message='+$pointerMessage)
            $badChoice=@{};foreach($k in $answer.Keys){$badChoice[$k]=$answer[$k]};$badChoice['Desired/DrainPolicy']='NotAnOption'
            $badMessage='';try{CallModule {param($w,$p,$id,$hash,$a) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'fixture owner' -Evidence 'bad drain option' -Answers $a|Out-Null} @($workspace,$catalog.PairId,$row.ItemId,$review.ReviewHash,$badChoice)}catch{$badMessage=[string]$_.Exception.Message}
            Check ($badMessage -like '*PreparationFieldValidation|/Answers/Desired~1DrainPolicy|option*') ('S9: an answer outside the DrainPolicy options did not fail with its field pointer; message='+$badMessage)
        }
        [void](Invoke-PreparationAdapter $workspace $catalog.PairId $row.ItemId $adapter $answer)
        $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId);$savedRow=@($catalog.Items|Where-Object ItemId -CEQ $row.ItemId)
        if($savedRow.Count -eq 1){$desired=$savedRow[0].MigrationSpec.Desired;switch($adapter){
            Service {Check ($desired.Description -ceq $answer['Desired/Description'] -and $savedRow[0].MigrationSpec.AccountMode -ceq 'UserPassword' -and $savedRow[0].MigrationSpec.SecretRef -ceq 'fixture_service_account') 'Service safe description or reference-only credential decision did not reach its typed adapter spec.'}
            SmbShare {Check ($desired.Name -ceq 'FixtureShare' -and $desired.Path -ceq $answer['Desired/Path'] -and $desired.Description -ceq $answer['Desired/Description'] -and $desired.EncryptData -eq $true -and $desired.DrainPolicy -ceq 'BlockNewOpens' -and $desired.DrainEvidence -ceq $answer['Desired/DrainEvidence'] -and $desired.Access[0].AccountName -ceq 'FIXTURE\Editors' -and $desired.Access[0].AccessRight -ceq 'Change') ('SmbShare safe Desired decisions did not reach its actual submitted adapter spec or changed the protected share identity: '+($desired|ConvertTo-Json -Depth 20 -Compress));Check ([string]$savedRow[0].SettingsHash -ceq $sourceSettingsHash) 'SmbShare typed review changed captured source settings.'}
            LocalUser {Check ($desired.Name -ceq 'fixture-user' -and $desired.FullName -ceq $answer['Desired/FullName'] -and $desired.Description -ceq $answer['Desired/Description'] -and $savedRow[0].MigrationSpec.SecretRef -ceq $answer.SecretRef -and [string]$savedRow[0].SettingsHash -ceq $sourceSettingsHash) 'LocalUser safe display decisions, nonsecret reference placeholder, or protected source identity did not reach/remain in the submitted adapter spec.'}
            LocalGroup {Check ($desired.Name -ceq 'Fixture Operators' -and $desired.Description -ceq $answer['Desired/Description'] -and (@($desired.Members) -join '|') -ceq 'FIXTURE\fixture-editor|FIXTURE\fixture-reader' -and [string]$savedRow[0].SettingsHash -ceq $sourceSettingsHash) 'LocalGroup safe Desired decisions did not reach its actual submitted adapter spec or changed protected source identity.'}
            Certificate {Check ($desired.Thumbprint -ceq $certificateThumbprint -and $desired.ArtifactPath -ceq $certificateArtifact -and $desired.ArtifactHash -ceq $certificateArtifactHash -and (Get-FileHash -LiteralPath $desired.ArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $desired.ArtifactHash -and [string]$savedRow[0].SettingsHash -ceq $sourceSettingsHash) 'Certificate artifact reference/hash was not submitted, its bytes drifted, or source certificate identity changed.'}
        }}
        if($adapter -ceq 'LocalUser'){
            $fresh=CallModule {param($w,$p,$id) Get-WsmWizardPreparationReview $w $p $id} @($workspace,$catalog.PairId,$row.ItemId)
            Reject {CallModule {param($w,$p,$id,$hash) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'fixture owner' -Evidence 'bad reference must be rejected' -Answers @{SecretRef='secretref://not-a-reference'}} @($workspace,$catalog.PairId,$row.ItemId,$fresh.ReviewHash)} 'SecretRef accepted a URI/value outside the adapter reference grammar.'
        }
        if($adapter -ceq 'Service'){
            $fresh=CallModule {param($w,$p,$id) Get-WsmWizardPreparationReview $w $p $id} @($workspace,$catalog.PairId,$row.ItemId)
            Reject {CallModule {param($w,$p,$id,$hash) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'fixture owner' -Evidence 'missing service credential reference' -Answers @{SecretRef=''}} @($workspace,$catalog.PairId,$row.ItemId,$fresh.ReviewHash)} 'A UserPassword service was saved without a SecretRef.'
        }
        if($adapter -ceq 'Certificate'){
            $fresh=CallModule {param($w,$p,$id) Get-WsmAssistiveSpecReview $w $p $id} @($workspace,$catalog.PairId,$row.ItemId);$badDesired=$fresh.TypedFields.Desired;$badDesired.ArtifactHash=('0'*64)
            Reject {CallModule {param($w,$p,$id,$d,$a,$s,$sel,$desired) Submit-WsmAssistiveSpecReview -Workspace $w -PairId $p -ItemId $id -ExpectedDecisionRevision $d -ExpectedAssistiveRevision $a -ExpectedSelectionRevision $sel -Owner 'fixture owner' -Evidence 'wrong public artifact hash' -Fields @{Desired=$desired}} @($workspace,$catalog.PairId,$row.ItemId,$catalog.DecisionRevision,$catalog.Assistive.Revision,$catalog.Assistive.Selections.Revision,$badDesired)} 'A directly submitted mismatched certificate artifact hash bypassed the independent byte check.'
        }
        $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
    }


    # A valid typed IIS configuration review is seeded as a protected source
    # artifact because inventory discovery intentionally classifies generic
    # configuration files as ManualWorkflow. The user-facing edit still goes
    # through Get-WsmWizardPreparationReview -> Save-WsmWizardPreparationReview.
    # Verify stale hashes and unknown/nonnative pointers are rejected by the
    # live form wrapper, using the successful task review identity.
    $catalog=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId)
        try{
        $currentTask=CallModule {param($w,$p,$id) Get-WsmWizardPreparationReview $w $p $id} @($workspace,$catalog.PairId,$task.ItemId)
        Reject {CallModule {param($w,$p,$id,$hash) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'stale owner' -Evidence 'stale answer' -Answers @{}} @($workspace,$catalog.PairId,$task.ItemId,('0'*64))} 'A stale/unknown review pointer was accepted.'
        Reject {CallModule {param($w,$p,$id,$hash) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'fixture owner' -Evidence 'reviewed fixture' -Answers @{'WorkloadFieldReviews/999/Value'='C:\unsafe.exe'}} @($workspace,$catalog.PairId,$task.ItemId,$currentTask.ReviewHash)} 'An unknown WorkloadFieldReview pointer was accepted.'
        $fileReview=CallModule {param($w,$p,$id) Get-WsmWizardPreparationReview $w $p $id} @($workspace,$catalog.PairId,$file.ItemId)
        Reject {CallModule {param($w,$p,$id,$hash) Save-WsmWizardPreparationReview -Workspace $w -PairId $p -ItemId $id -ReviewHash $hash -Owner 'fixture owner' -Evidence 'reviewed fixture' -Answers @{SourcePath='C:\changed-source'}} @($workspace,$catalog.PairId,$file.ItemId,$fileReview.ReviewHash)} 'A form answer changed the source identity/path.'
    }catch{Add-ReviewGap 'stale/unknown-pointer protections' 'wizard-review' $_}

    # Verify the explicit GeneralHost policy with the real decision consumer.
    # A feature cannot be counted as a successful wizard adapter merely because
    # its draft is displayable; Include must stop with the manual-target reason.
    try{
        $catalog=CallModule {param($w,$p,$revision) Set-WsmGeneralHostMode -Workspace $w -PairId $p -ExpectedRevision $revision} @($workspace,$catalog.PairId,$catalog.DecisionRevision)
        $beforeFeatureDecision=$catalog.DecisionRevision;$featureFailure=''
        try{CallModule {param($w,$p,$id,$revision) Set-WsmDecision -Workspace $w -PairId $p -ItemId @($id) -Decision Include -Reason 'Fixture must remain manual' -ExpectedRevision $revision} @($workspace,$catalog.PairId,$feature.ItemId,$catalog.DecisionRevision)|Out-Null}catch{$featureFailure=[string]$_.Exception.Message}
        Check ($featureFailure -ceq 'Runtime, client, driver and role preparation remains a manual target preparation step.') ('WindowsFeature manual-rejection mismatch; actual failure=' + $featureFailure + '; GeneralHostMode=' + [string]$catalog.GeneralHost.ScopeMode)
        $afterFeatureDecision=CallModule {param($w,$p) Get-WsmCatalog $w $p} @($workspace,$catalog.PairId);$featureRow=@($afterFeatureDecision.Items|Where-Object ItemId -CEQ $feature.ItemId)
        Check ($afterFeatureDecision.DecisionRevision -eq $beforeFeatureDecision -and $featureRow.Count -eq 1 -and $featureRow[0].Decision -ceq 'Pending') 'Rejected WindowsFeature Include changed decisions or revision.'
        $script:unsupported.Add('WindowsFeature: explicit GeneralHost manual target-preparation rejection (verified; not counted as adapter pass).')
    }catch{Add-ReviewGap 'WindowsFeature manual policy' 'GeneralHost decision' $_}

    Write-Host ('Preparation adapter coverage: '+(@($script:tested.ToArray()) -join ', '))
    Write-Host ('Intentionally unsupported/manual: '+(@($script:unsupported.ToArray()) -join '; '))
    if($script:gaps.Count){throw ('Preparation adapter gaps ('+$script:gaps.Count+'): '+($script:gaps -join ' | '))}
    Write-Host ('PASS: '+$script:checks+' Wizard preparation review/save/core-submit adapter checks.')
} finally {
    $absolute=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Test cleanup escaped its isolated temporary root.'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
