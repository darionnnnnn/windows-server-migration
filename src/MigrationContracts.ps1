function Get-WsmMachineIdentity {
    if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw 'Migration requires FullLanguage under the approved enterprise deployment policy.' }
    $pre=Get-WsmPreflight
    $machine=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    $uuid=(Get-CimInstance Win32_ComputerSystemProduct).UUID
    [pscustomobject]@{ Fingerprint=(Get-WsmHashText ($machine+'|'+$uuid)); Name=$env:COMPUTERNAME; OS=$pre.OS; Version=$pre.Version; IsServer=$pre.IsServer; Administrator=$pre.Administrator; Is64Bit=$pre.Is64Bit }
}
function Assert-WsmMigrationHost($Identity,[string]$Fingerprint) {
    if (-not $Identity.IsServer -or -not $Identity.Administrator -or -not $Identity.Is64Bit -or $Identity.Fingerprint -cne $Fingerprint) { throw (New-WsmContractError 'Migration host identity/platform/privilege mismatch.') }
    if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { throw 'Migration requires FullLanguage; policy is not changed.' }
}
function Register-WsmTarget {
    param([string]$StateDirectory,[string]$Path)
    $identity=Get-WsmMachineIdentity
    Assert-WsmMigrationHost $identity $identity.Fingerprint
    $stateFull=[IO.Path]::GetFullPath($StateDirectory).TrimEnd('\')
    $stateParent=[IO.Path]::GetDirectoryName($stateFull)
    if($stateParent -and [IO.Path]::GetFileName($stateFull) -ieq 'pairs' -and [IO.File]::Exists((Join-Path (Join-Path $stateParent 'workspace-control') 'output-profile.json'))){
        $workspace=Initialize-WsmOutputWorkspace -WorkRoot $stateParent -Role Target
        if($workspace.StateDirectory -ine $stateFull -or $workspace.TargetIdentity.Fingerprint -cne $identity.Fingerprint){throw 'Target registration path does not match its enrolled output workspace.'}
        Assert-WsmNoReparse $Path
        $destination=[IO.Path]::GetFullPath($Path)
        if([IO.Directory]::Exists($destination)){throw 'Target identity output path is a directory.'}
        $parent=[IO.Path]::GetDirectoryName($destination)
        if($parent -and -not [IO.Directory]::Exists($parent)){[void][IO.Directory]::CreateDirectory($parent);Protect-WsmDirectory $parent}
        $target=$workspace.TargetIdentity
        Write-WsmJson $destination $target
        return [pscustomobject]@{Path=$destination;SHA256=(Get-FileHash -LiteralPath $destination).Hash;Target=$target;Enrolled=$true;StateDirectory=$workspace.StateDirectory;HostId=$workspace.HostId}
    }
    if (-not [IO.Directory]::Exists($StateDirectory)) { [void][IO.Directory]::CreateDirectory($StateDirectory); Protect-WsmDirectory $StateDirectory }
    Invoke-WsmLocked $StateDirectory {
        $statePath=Join-Path $StateDirectory 'target-identity.json'
        if ([IO.File]::Exists($statePath)) { $target=Read-WsmJson $statePath; Assert-WsmEnvelope $target 'TargetIdentity'; if ($target.Fingerprint -cne $identity.Fingerprint) { throw 'Target state belongs to a different machine.' } }
        else { $target=[pscustomobject]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='TargetIdentity'; HostId=[Guid]::NewGuid().ToString(); Fingerprint=$identity.Fingerprint; Name=$identity.Name; OS=$identity.OS; Version=$identity.Version; CreatedUtc=(Get-WsmUtc) }; Write-WsmJson $statePath $target }
        Write-WsmJson $Path $target
        [pscustomobject]@{ Path=[IO.Path]::GetFullPath($Path); SHA256=(Get-FileHash -LiteralPath $Path).Hash; Target=$target }
    }
}
function Assert-WsmFields($Object,[string[]]$Allowed,[string[]]$Required=@()) {
    foreach ($p in $Object.PSObject.Properties.Name) { if ($Allowed -cnotcontains $p) { throw (New-WsmContractError ('Unknown contract field: '+$p)) } }
    foreach ($p in $Required) { if (-not $Object.PSObject.Properties[$p]) { throw (New-WsmContractError ('Missing contract field: '+$p)) } }
}
function Assert-WsmWorkspaceSeparation($Plan,[string]$Workspace,[ValidateSet('SourcePath','TargetPath')][string]$ScopeField) {
    $workspacePath=[IO.Path]::GetFullPath($Workspace).TrimEnd('\');Assert-WsmNoReparse $workspacePath
    $physicalWorkspace=Get-WsmPhysicalPath $workspacePath;$destinations=New-Object 'System.Collections.Generic.List[string]'
    foreach($i in $Plan.Items){if($i.Decision -eq 'Include' -and $i.MigrationSpec.Adapter -eq 'FileScope'){$root=[IO.Path]::GetFullPath($i.MigrationSpec.$ScopeField).TrimEnd('\');$physicalRoot=Get-WsmPhysicalPath $root;if((Test-WsmPathOverlap $workspacePath $root) -or (Test-WsmPathOverlap $physicalWorkspace $physicalRoot)){throw ($ScopeField+' overlaps operation evidence/state workspace; move the tool workspace outside business data before any operation.')};if($ScopeField -eq 'TargetPath'){foreach($prior in $destinations){if(Test-WsmPathOverlap $prior $physicalRoot){throw 'Target scopes overlap through physical aliases.'}};$destinations.Add($physicalRoot)}}}
}
function Assert-WsmSourceWorkspaceSeparation($Plan,[string]$Workspace) {
    Assert-WsmWorkspaceSeparation $Plan $Workspace SourcePath
}
function Assert-WsmRelativePath([string]$Path,[switch]$AllowRoot) {
    if ($AllowRoot -and $Path -eq '') { return }
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path -match '[/:\x00-\x1f<>"|?*]' -or $Path.EndsWith('\') -or $Path -match '\\\\' -or $Path -match '(?:^|\\)(?:\.|\.\.)(?:\\|$)' -or $Path -match '(?i)(?:^|\\)(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\\|$)' -or $Path -match '[. ](?:\\|$)') { throw (New-WsmContractError 'Unsafe relative artifact path.') }
}
function Assert-WsmNoReparse([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) { if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('Reparse point requires dedicated approved handling: '+$cursor) } }
        $parent=[IO.Path]::GetDirectoryName($cursor.TrimEnd('\')); if ($parent -eq $cursor) { break }; $cursor=$parent
    }
}
function Get-WsmAdapterMatrix {
    foreach ($name in @('FileScope','ScheduledTask','Service','SmbShare','MachineEnvironment','TimeZone','WindowsFeature','IISPool','IISSite','IISSection','IISLocation','Certificate','LocalUser','LocalGroup','FirewallRule','ManualWorkflow')) {
        $automatic=$name -ne 'ManualWorkflow';$rollback='RemoveCreatedAfterDriftAndTransactionReview';if($name -eq 'FileScope'){$rollback='Durable owned scope switch; retain displaced data; reconcile new transactions'}elseif($name -eq 'TimeZone'){$rollback='Restore exact prior zone and DST state after drift check'}elseif($name -in @('WindowsFeature','ManualWorkflow')){$rollback='Reviewed dedicated product/role rollback'}
        $consistency='Disabled staged consumer; owner-confirmed source freeze';if($name -eq 'FileScope'){$consistency='Immutable / OwnerFreeze / ProductBackup with exact freeze binding'}elseif($name -eq 'ManualWorkflow'){$consistency='Product-specific owner procedure; no automatic restorer'}
        $dependencies=@();if($name -notin @('FileScope','ManualWorkflow')){$dependencies=@(Get-WsmAdapterRequiredCommands $name)}
        [pscustomobject]@{ Adapter=$name; Version=1; CollectorImplemented=$automatic; ExportImplemented=($automatic -and $name -ne 'Certificate'); RestoreImplemented=$automatic; VerifyImplemented=$automatic; ProductionVerified=$false; EvidenceType='Native APIs: fixtures; FileScope: local real-file fixtures; Server lab pending'; RequiredMode=$(if($name -eq 'TimeZone'){'GeneralHostTransition'}else{'IsolatedPilot'}); Rollback=$rollback; Secrets='InMemoryCredentialOrIndependentArtifact'; SupportedSource='Exact OS/build/edition/product tuple requires qualification record'; SupportedTarget='Exact OS/build/edition/product tuple requires qualification record'; Dependencies=$dependencies; Permissions='Elevated local administrator, approved API and artifact access; SACL needs security privilege'; ConsistencyMethod=$consistency; RebootBehavior=$(if($name -eq 'WindowsFeature'){'No automatic restart; durable boot barrier'}else{'Reviewed identity rename can require restart'}); SideEffects=$(if($name -eq 'WindowsFeature'){'Owner isolation before install; quarantine reviewed new consumers after return'}else{'Explicit final state applied only at reviewed cutover'}); CapabilityScope=$(if($name -eq 'Certificate'){'Owner-exported protected PFX/certificate artifact; private key ACL needs dedicated qualification'}elseif($name -eq 'ManualWorkflow'){'Procedure/artifact/business evidence only'}else{'Only fields accepted and read back by typed adapter contract'}) }
    }
    if (Get-Command Get-WsmSettingTransitionCapabilities -ErrorAction SilentlyContinue) {
        foreach($setting in @(Get-WsmSettingTransitionCapabilities)) {
            [pscustomobject]@{ Adapter=('SettingTransition.'+$setting.Adapter); Version=1; CollectorImplemented=$true; ExportImplemented=$true; RestoreImplemented=$true; VerifyImplemented=$true; ProductionVerified=$false; EvidenceType='Exact native setting before/after readback with durable intent and journal binding'; RequiredMode='GeneralHost'; Rollback=$setting.Rollback; Secrets='None'; SupportedSource='Owner-reviewed exact prior state'; SupportedTarget='Owner-reviewed target context'; Dependencies=@(); Permissions=$setting.RequiredPrivilege; ConsistencyMethod=$setting.Isolation; RebootBehavior=$setting.Restart; SideEffects=$setting.Isolation; CapabilityScope=('Actions: '+($setting.Actions -join ', ')+'; write whitelist: '+($setting.WriteWhitelist -join ', ')); QualificationStatus=$setting.QualificationStatus }
        }
    }
}
function Assert-WsmAssistiveXml([string]$Xml,[string]$Label) {
    if([string]::IsNullOrWhiteSpace($Xml) -or $Xml.Length -gt 1048576 -or $Xml -match '<!DOCTYPE|<!ENTITY'){throw (New-WsmContractError ($Label+' must be nonempty bounded XML without DTD/entity declarations.'))}
    $settings=New-Object System.Xml.XmlReaderSettings;$settings.DtdProcessing=[System.Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
    $stringReader=New-Object IO.StringReader($Xml);$reader=$null
    try{$reader=[System.Xml.XmlReader]::Create($stringReader,$settings);while($reader.Read()){} }catch{throw (New-WsmContractError ($Label+' is not well-formed XML.'))}finally{if($reader){$reader.Dispose()};$stringReader.Dispose()}
}
function Assert-WsmAssistiveStagedXml([string]$Xml,[string]$Adapter) {
    $document=New-Object System.Xml.XmlDocument;$document.XmlResolver=$null
    try{$document.LoadXml($Xml)}catch{throw (New-WsmContractError 'Staged workload XML cannot be parsed.')}
    if($Adapter -ceq 'ScheduledTask'){
        $enabled=$document.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']")
        if(-not $enabled -or [string]$enabled.InnerText -ine 'false'){throw (New-WsmContractError 'Staged scheduled task XML must explicitly set Settings.Enabled=false.')}
    }elseif($Adapter -ceq 'IISSite'){
        $nodes=@($document.SelectNodes('//*[@serverAutoStart]'))
        if(-not $nodes.Count -or @($nodes | Where-Object {$_.GetAttribute('serverAutoStart') -ine 'false'}).Count){throw (New-WsmContractError 'Staged IIS site XML must explicitly preserve serverAutoStart=false.')}
    }elseif($Adapter -ceq 'IISPool'){
        $nodes=@($document.SelectNodes('//*[@autoStart]'))
        if(-not $nodes.Count -or @($nodes | Where-Object {$_.GetAttribute('autoStart') -ine 'false'}).Count){throw (New-WsmContractError 'Staged IIS pool XML must explicitly preserve autoStart=false.')}
    }elseif($Adapter -in @('IISSection','IISLocation')){
        $allowed=@{enabled=@('false','0','no','disabled');autoStart=@('false','0','no');serverAutoStart=@('false','0','no');startMode=@('ondemand');state=@('stopped','disabled')}
        foreach($node in @($document.SelectNodes('//*[@enabled or @autoStart or @serverAutoStart or @startMode or @state]'))){foreach($name in @('enabled','autoStart','serverAutoStart','startMode','state')){if($node.Attributes[$name] -and $allowed[$name] -cnotcontains ([string]$node.GetAttribute($name)).ToLowerInvariant()){throw (New-WsmContractError ('Staged IIS XML has active or unknown '+$name+' state.'))}}}
        foreach($node in @($document.SelectNodes("//*[local-name()='enabled' or local-name()='autoStart' or local-name()='serverAutoStart' or local-name()='startMode' or local-name()='state']"))){$name=[string]$node.LocalName;if($allowed[$name] -cnotcontains ([string]$node.InnerText).ToLowerInvariant()){throw (New-WsmContractError ('Staged IIS XML has active or unknown '+$name+' state.'))}}
    }
}
function Assert-WsmAssistiveIisConfigSpec($Spec) {
    if($Spec.Adapter -notin @('IISSection','IISLocation')){return}
    $desired=$Spec.Desired
    if(-not $desired -or -not $desired.PSObject.Properties['SectionPath'] -or -not $desired.PSObject.Properties['LocationPath'] -or -not $desired.PSObject.Properties['Xml'] -or -not $desired.PSObject.Properties['Changes']){throw (New-WsmContractError 'IIS section/location Desired requires SectionPath, LocationPath, Xml and Changes.')}
    foreach($field in @('SectionPath','LocationPath','Xml')){if($desired.$field -isnot [string]){throw (New-WsmContractError ('IIS Desired.'+$field+' must be a string.'))}}
    $section=[string]$desired.SectionPath;$location=[string]$desired.LocationPath
    if($section.Length -gt 512 -or $section -notmatch '^[A-Za-z_][A-Za-z0-9_.-]*(?:/[A-Za-z_][A-Za-z0-9_.-]*)*$' -or $section -match '(?:^|/)(?:\.|\.\.)(?:/|$)'){throw (New-WsmContractError 'IIS SectionPath is not a safe exact section identity.')}
    if($Spec.Adapter -ceq 'IISSection' -and $location.Length -ne 0){throw (New-WsmContractError 'IISSection requires an empty LocationPath.')}
    if($Spec.Adapter -ceq 'IISLocation' -and ($location.Length -gt 512 -or $location -notmatch '^/?[A-Za-z0-9 _./-]+$' -or $location -match '(?:^|/)\.\.?(?:/|$)' -or $location -match '//')){throw (New-WsmContractError 'IISLocation requires a safe nonempty site/application path.')}
    if($desired.Changes -isnot [array] -or @($desired.Changes).Count -gt 500){throw (New-WsmContractError 'IIS config Changes must be a bounded array.')}
    $pointerPattern="^/[A-Za-z_][A-Za-z0-9_.:-]*(?:/[A-Za-z_][A-Za-z0-9_.:-]*(?:\[@[A-Za-z_][A-Za-z0-9_.:-]*='(?:[^']|&apos;|&amp;|&quot;|&lt;|&gt;)*'\])?)*(?:/@[A-Za-z_][A-Za-z0-9_.:-]*)?$"
    foreach($change in @($desired.Changes)){
        Assert-WsmFields $change @('FieldPointer','Operation','ElementName','KeyAttributes','AttributeName','BeforeValue','AfterValue') @('FieldPointer','Operation','ElementName','KeyAttributes','AttributeName','BeforeValue','AfterValue')
        foreach($field in @('FieldPointer','Operation','ElementName','AttributeName','BeforeValue','AfterValue')){if($change.$field -isnot [string]){throw (New-WsmContractError ('IIS change '+$field+' must be a string.'))}}
        $pointer=[string]$change.FieldPointer;$operation=[string]$change.Operation;$element=[string]$change.ElementName;$attribute=[string]$change.AttributeName
        if($pointer.Length -gt 2048 -or $pointer -notmatch $pointerPattern -or $pointer -match '//|\.\.|\*|\(|\)'){throw (New-WsmContractError 'IIS config FieldPointer is outside the bounded element/key/attribute grammar.')}
        if($element -notmatch '^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$' -or $operation -cnotin @('SetAttribute','AddElement','RemoveElement')){throw (New-WsmContractError 'IIS config operation or ElementName is invalid.')}
        if($change.KeyAttributes -isnot [array] -or @($change.KeyAttributes).Count -gt 16){throw (New-WsmContractError 'IIS config KeyAttributes must be a bounded array.')}
        $keys=@{};foreach($key in @($change.KeyAttributes)){
            Assert-WsmFields $key @('Name','Value') @('Name','Value');if($key.Name -isnot [string] -or $key.Value -isnot [string]){throw (New-WsmContractError 'IIS config key name and value must be strings.')};$name=[string]$key.Name;$value=[string]$key.Value
            if($name -notmatch '^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$' -or $keys.ContainsKey($name) -or $value.Length -gt 2048 -or $value -match '[\x00-\x1f]'){throw (New-WsmContractError 'IIS config key attributes are invalid or duplicated.')};$keys[$name]=$value
        }
        foreach($value in @([string]$change.BeforeValue,[string]$change.AfterValue)){if($value.Length -gt 32768 -or $value -match '[\x00-\x08\x0b\x0c\x0e-\x1f]'){throw (New-WsmContractError 'IIS config change value is outside its safe text limit.')}}
        if($operation -ceq 'SetAttribute'){
            $elementPath='(?:^|/)'+[regex]::Escape($element)+'(?:\[@[^]]+\])?$'
            if($attribute -notmatch '^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$' -or -not $pointer.EndsWith('/@'+$attribute,[StringComparison]::Ordinal) -or $pointer.Substring(0,$pointer.LastIndexOf('/@')) -notmatch $elementPath){throw (New-WsmContractError 'SetAttribute must bind its pointer to the declared element and attribute.')}
            if($attribute -match '^(?i:enabled|autoStart|serverAutoStart|startMode|state)$'){$allowedActivation=@{enabled=@('false','0','no','disabled');autoStart=@('false','0','no');serverAutoStart=@('false','0','no');startMode=@('ondemand');state=@('stopped','disabled')};if($allowedActivation[$attribute] -cnotcontains ([string]$change.AfterValue).ToLowerInvariant()){throw (New-WsmContractError 'IIS config change cannot enable or start a workload during staging.')}}
        }else{
            if($attribute.Length -ne 0 -or $pointer.EndsWith('/@',[StringComparison]::Ordinal)){throw (New-WsmContractError 'Element changes cannot name an attribute or terminate at an attribute pointer.')}
            $fragment=if($operation -ceq 'AddElement'){$change.AfterValue}else{$change.BeforeValue}
            if(($operation -ceq 'AddElement' -and [string]$change.BeforeValue) -or ($operation -ceq 'RemoveElement' -and [string]$change.AfterValue) -or [string]::IsNullOrWhiteSpace([string]$fragment)){throw (New-WsmContractError 'AddElement/RemoveElement absence and XML-value conventions are invalid.')}
            if($operation -ceq 'RemoveElement' -and $element -match '^(?i:enabled|autoStart|serverAutoStart|startMode|state)$'){throw (New-WsmContractError 'Removing an IIS activation field is unsafe because it can restore an active default.')}
            Assert-WsmAssistiveXml ([string]$fragment) ('IIS '+$operation+' element')
            $xml=New-Object System.Xml.XmlDocument;$xml.XmlResolver=$null;try{$xml.LoadXml([string]$fragment)}catch{throw (New-WsmContractError 'IIS element change XML is invalid.')}
            if($xml.DocumentElement.LocalName -cne $element){throw (New-WsmContractError 'IIS change element name does not match its XML fragment.')}
            foreach($keyName in $keys.Keys){if(-not $xml.DocumentElement.Attributes[$keyName] -or [string]$xml.DocumentElement.GetAttribute($keyName) -cne $keys[$keyName]){throw (New-WsmContractError 'IIS change key attributes do not match the element XML.')}}
            if($operation -ceq 'AddElement'){Assert-WsmAssistiveStagedXml ([string]$change.AfterValue) 'IISSection'}
        }
    }
}
function Assert-WsmAssistiveReviewedActivation($Spec) {
    if($Spec.Adapter -in @('IISSection','IISLocation')){
        if(-not $Spec.PSObject.Properties['ReviewedActivation']){throw (New-WsmContractError 'IIS section/location activation requires an explicit reviewed final field intent, including when it remains disabled.')}
        $activation=$Spec.ReviewedActivation;Assert-WsmFields $activation @('FinalState','Owner','Reason','SourceAutoStart','FieldPointer','StagedValue','FinalValue') @('FinalState','Owner','Reason','SourceAutoStart','FieldPointer','StagedValue','FinalValue')
        foreach($field in @('FinalState','Owner','Reason','SourceAutoStart','FieldPointer','StagedValue','FinalValue')){if($activation.$field -isnot [string] -or ([string]$activation.$field).Length -gt 2048 -or [string]$activation.$field -match '[\x00-\x1f]|(?i)(password|passwd|secret|token|credential|private[ _-]?key)[\s:=]'){throw (New-WsmContractError ('ReviewedActivation has an invalid or secret-like '+$field+'.'))}}
        if($activation.FinalState -cnotin @('Disabled','Enabled') -or $activation.SourceAutoStart -cnotin @('true','false','Unknown') -or $activation.FieldPointer -cne [string]$Spec.ActivationPolicyFieldPointer -or $Spec.DesiredFinalState -cne $activation.FinalState -or [string]::IsNullOrWhiteSpace([string]$activation.Owner) -or [string]::IsNullOrWhiteSpace([string]$activation.Reason) -or $activation.Reason.Length -lt 10){throw (New-WsmContractError 'Reviewed IIS config activation must bind an explicit final state, source evidence, pointer, owner, and specific reason.')}
        if($activation.FieldPointer -notmatch '^/[A-Za-z_][A-Za-z0-9_.:-]*(?:/[A-Za-z_][A-Za-z0-9_.:-]*(?:\[@[A-Za-z_][A-Za-z0-9_.:-]*=''[^'']{1,2048}''\])?)*(?:/@(?:enabled|autoStart|serverAutoStart|startMode))$'){throw (New-WsmContractError 'Reviewed IIS config activation pointer must identify one supported activation attribute.')}
        $attribute=([string]$activation.FieldPointer -split '/@')[-1]
        $allowedFinal=@{enabled=@('false','true');autoStart=@('false','true');serverAutoStart=@('false','true');startMode=@('ondemand','alwaysrunning')}
        $allowedDisabled=@{enabled=@('false','0','no','disabled');autoStart=@('false','0','no');serverAutoStart=@('false','0','no');startMode=@('ondemand')}
        if($allowedDisabled[$attribute] -cnotcontains ([string]$activation.StagedValue).ToLowerInvariant() -or $allowedFinal[$attribute] -cnotcontains ([string]$activation.FinalValue).ToLowerInvariant()){throw (New-WsmContractError 'Reviewed IIS config staged/final values are outside the supported activation states.')}
        $finalIsEnabled=if($attribute -ceq 'startMode'){[string]$activation.FinalValue -ieq 'AlwaysRunning'}else{[string]$activation.FinalValue -match '^(?i:true)$'}
        if(($activation.FinalState -ceq 'Enabled') -ne [bool]$finalIsEnabled){throw (New-WsmContractError 'Reviewed IIS config FinalValue does not match FinalState.')}
        $desiredXml=Read-WsmXml ([string]$Spec.Desired.Xml);$resolved=Get-WsmIisPointerNode $desiredXml ([string]$activation.FieldPointer);$stagedAttribute=$resolved.Node.Attributes[$attribute]
        if(-not $stagedAttribute -or [string]$stagedAttribute.Value -cne [string]$activation.StagedValue){throw (New-WsmContractError 'Reviewed IIS config staged value differs from the exact typed Desired.Xml field.')}
        $sourceXml=Read-WsmXml ([string]$Spec.SourceXml);$sourceResolved=$null;try{$sourceResolved=Get-WsmIisPointerNode $sourceXml ([string]$activation.FieldPointer)}catch{}
        $sourceAttribute=$null;if($sourceResolved){$sourceAttribute=$sourceResolved.Node.Attributes[$attribute]};$sourceValue='Unknown';if($sourceAttribute){if([string]$sourceAttribute.Value -match '^(?i:true|1|yes)$'){$sourceValue='true'}elseif([string]$sourceAttribute.Value -match '^(?i:false|0|no|disabled|ondemand)$'){$sourceValue='false'}}
        if($sourceValue -cne [string]$activation.SourceAutoStart -or $sourceValue -cne [string]$Spec.SourceAutoStart){throw (New-WsmContractError 'SourceAutoStart differs from the protected SourceXml value at the reviewed activation pointer.')}
        if($activation.FinalState -eq 'Enabled' -and $sourceValue -ne 'true' -and $activation.Reason -notmatch '(?i)source.{0,40}(disabled|false|unknown)|(?:disabled|false|unknown).{0,40}source|來源.{0,20}(停用|未啟用|未知)|(停用|未啟用|未知).{0,20}來源'){throw (New-WsmContractError 'Enabling a source-disabled or unknown IIS setting requires an explicit owner reason addressing the changed source activation state.')}
        return
    }
    if($Spec.Adapter -notin @('ScheduledTask','IISSite','IISPool')){if($Spec.PSObject.Properties['ReviewedActivation']){throw (New-WsmContractError 'ReviewedActivation is supported only for typed workloads with an explicit activation adapter.')};return}
    if(-not $Spec.PSObject.Properties['ReviewedActivation']){throw (New-WsmContractError 'Workload specs require an explicit ReviewedActivation record, even when the reviewed final state is Disabled.')}
    $activation=$Spec.ReviewedActivation;Assert-WsmFields $activation @('FinalState','Owner','Reason','SourceAutoStart','FieldPointer') @('FinalState','Owner','Reason','SourceAutoStart','FieldPointer')
    foreach($field in @('FinalState','Owner','Reason','SourceAutoStart','FieldPointer')){if($activation.$field -isnot [string] -or ([string]$activation.$field).Length -gt 2048 -or [string]$activation.$field -match '[\x00-\x1f]|(?i)(password|passwd|secret|token|credential|private[ _-]?key)[\s:=]'){throw (New-WsmContractError ('ReviewedActivation has an invalid or secret-like '+$field+'.'))}}
    if($activation.FinalState -cnotin @('Disabled','Enabled') -or $activation.SourceAutoStart -cne [string]$Spec.SourceAutoStart -or $activation.FieldPointer -cne [string]$Spec.ActivationPolicyFieldPointer -or $Spec.DesiredFinalState -cne $activation.FinalState){throw (New-WsmContractError 'ReviewedActivation must bind its final state, source intent, typed field pointer and MigrationSpec.DesiredFinalState.')}
    if([string]::IsNullOrWhiteSpace([string]$activation.Owner) -or [string]::IsNullOrWhiteSpace([string]$activation.Reason) -or [string]$activation.Reason.Length -lt 10){throw (New-WsmContractError 'Reviewed activation requires a bounded owner and a specific reason of at least 10 characters.')}
    $expectedPointer='';switch($Spec.Adapter){ScheduledTask{$expectedPointer='Task/Settings/Enabled'};IISSite{$expectedPointer='IIS/site/@serverAutoStart'};IISPool{$expectedPointer='IIS/applicationPool/@autoStart'}}
    if($activation.FieldPointer -cne $expectedPointer){throw (New-WsmContractError 'ReviewedActivation field pointer does not match the typed adapter activation property.')}
    $source=Read-WsmXml ([string]$Spec.SourceXml);$sourceValue=$null
    switch($Spec.Adapter){ScheduledTask{$node=$source.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");if($node){$sourceValue=[string]$node.InnerText}};IISSite{$node=$source.DocumentElement.Attributes['serverAutoStart'];if($node){$sourceValue=[string]$node.Value}};IISPool{$node=$source.DocumentElement.Attributes['autoStart'];if($node){$sourceValue=[string]$node.Value}}}
    if($null -eq $sourceValue){$sourceValue='Unknown'}elseif($sourceValue -match '^(?i:true|1|yes)$'){$sourceValue='true'}elseif($sourceValue -match '^(?i:false|0|no)$'){$sourceValue='false'}else{$sourceValue='Unknown'}
    if($sourceValue -cne [string]$Spec.SourceAutoStart){throw (New-WsmContractError 'SourceAutoStart differs from the protected original XML startup setting.')}
    if($activation.FinalState -eq 'Enabled' -and $sourceValue -ne 'true' -and $activation.Reason -notmatch '(?i)source.{0,40}(disabled|false|unknown)|(?:disabled|false|unknown).{0,40}source|來源.{0,20}(停用|未啟用|未知)|(停用|未啟用|未知).{0,20}來源'){throw (New-WsmContractError 'Enabling a source-disabled or unknown workload requires an explicit owner reason addressing the changed source activation state.')}
}
function Assert-WsmAssistiveMigrationSpec($Spec) {
    if($Spec.PSObject.Properties['TransferChannel']){
        if($Spec.Adapter -cne 'FileScope' -or [string]$Spec.TransferChannel -cnotin @('C','NonC','External')){throw (New-WsmContractError 'TransferChannel is only valid on a schema 3 FileScope and must be C, NonC, or External.')}
    }
    if($Spec.PSObject.Properties['ContentSelection']){
        if($Spec.Adapter -cne 'FileScope' -or [string]$Spec.ContentSelection -cnotin @('WholeScope','ExactFiles')){throw (New-WsmContractError 'ContentSelection is only valid on a schema 3 FileScope and must be WholeScope or ExactFiles.')}
        if($Spec.ContentSelection -ceq 'ExactFiles' -and @($Spec.ConfigFiles).Count -eq 0){throw (New-WsmContractError 'ExactFiles requires a nonempty approved ConfigFiles whitelist.')}
    }
    if($Spec.Adapter -eq 'FileScope' -and (-not $Spec.PSObject.Properties['TransferChannel'] -or -not $Spec.PSObject.Properties['ContentSelection'])){throw (New-WsmContractError 'Schema 3 FileScope requires reviewed TransferChannel and ContentSelection fields.')}
    foreach($field in @('SourceXml','ActivationPolicyFieldPointer')){if($Spec.PSObject.Properties[$field] -and [string]$Spec.$field -match '[\x00-\x08\x0b\x0c\x0e-\x1f]'){throw (New-WsmContractError ($field+' contains control characters.'))}}
    if($Spec.PSObject.Properties['SourceXml']){
        if($Spec.Adapter -cnotin @('IISSite','IISPool','ScheduledTask','IISSection','IISLocation')){throw (New-WsmContractError 'SourceXml is limited to typed IIS and ScheduledTask workload specs.')}
        Assert-WsmAssistiveXml ([string]$Spec.SourceXml) 'SourceXml'
        if(-not $Spec.PSObject.Properties['SourceAutoStart'] -or [string]$Spec.SourceAutoStart -cnotin @('true','false','Unknown')){throw (New-WsmContractError 'SourceAutoStart must preserve true, false, or Unknown source evidence.')}
        if(-not $Spec.PSObject.Properties['StagedDisabled'] -or $Spec.StagedDisabled -isnot [bool] -or -not $Spec.StagedDisabled){throw (New-WsmContractError 'Workload settings must be staged disabled and retain their source activation intent separately.')}
        if(-not $Spec.Desired -or -not $Spec.Desired.PSObject.Properties['Xml']){throw (New-WsmContractError 'Typed workload spec must contain target Desired.Xml separately from SourceXml.')}
        Assert-WsmAssistiveXml ([string]$Spec.Desired.Xml) 'Desired.Xml'
        Assert-WsmAssistiveStagedXml ([string]$Spec.Desired.Xml) ([string]$Spec.Adapter)
        Assert-WsmAssistiveReviewedActivation $Spec
        if($Spec.Adapter -in @('IISSection','IISLocation')){Assert-WsmAssistiveIisConfigSpec $Spec}
    }elseif($Spec.PSObject.Properties['SourceAutoStart'] -or $Spec.PSObject.Properties['StagedDisabled'] -or $Spec.PSObject.Properties['ActivationPolicyFieldPointer'] -or $Spec.PSObject.Properties['WorkloadMappingReview'] -or $Spec.PSObject.Properties['SharedResourceImpacts']){throw (New-WsmContractError 'Workload mapping and activation evidence requires SourceXml.')}
    if($Spec.PSObject.Properties['WorkloadMappingReview']){
        if($Spec.WorkloadMappingReview -isnot [array] -or @($Spec.WorkloadMappingReview).Count -gt 5000){throw (New-WsmContractError 'WorkloadMappingReview must be a bounded array.')}
        foreach($row in @($Spec.WorkloadMappingReview)){
            Assert-WsmFields $row @('FieldPointer','ReferenceKind','OldRawValue','TargetValue','Applied','Status','ReviewRequired','Reason') @('FieldPointer','ReferenceKind','OldRawValue','TargetValue','Applied','Status','ReviewRequired','Reason')
            if($row.Applied -isnot [bool] -or $row.ReviewRequired -isnot [bool] -or [string]::IsNullOrWhiteSpace([string]$row.FieldPointer) -or [string]::IsNullOrWhiteSpace([string]$row.ReferenceKind) -or [string]::IsNullOrWhiteSpace([string]$row.Status)){throw (New-WsmContractError 'Workload mapping rows require a pointer, kind, status, and Boolean review/application state.')}
            foreach($value in @([string]$row.FieldPointer,[string]$row.ReferenceKind,[string]$row.OldRawValue,[string]$row.TargetValue,[string]$row.Status,[string]$row.Reason)){if($value.Length -gt 32768 -or $value -match '[\x00-\x08\x0b\x0c\x0e-\x1f]'){throw (New-WsmContractError 'Workload mapping field exceeds its safe text limit.')}}
        }
    }
    if($Spec.PSObject.Properties['SharedResourceImpacts']){
        if($Spec.SharedResourceImpacts -isnot [array] -or @($Spec.SharedResourceImpacts).Count -gt 1000){throw (New-WsmContractError 'SharedResourceImpacts must be a bounded array.')}
        $seenResources=@{}
        foreach($impact in @($Spec.SharedResourceImpacts)){
            Assert-WsmFields $impact @('ResourceItemId','ResourceKind','ConsumerItemIds','SelectedConsumerItemIds','UnselectedConsumerItemIds','UnknownConsumerItemIds','RequiresSharedReview','OwnerReviewReason') @('ResourceItemId','ResourceKind','ConsumerItemIds','SelectedConsumerItemIds','UnselectedConsumerItemIds','UnknownConsumerItemIds','RequiresSharedReview','OwnerReviewReason')
            if([string]$impact.ResourceItemId -notmatch '^[a-f0-9]{64}$' -or $seenResources.ContainsKey([string]$impact.ResourceItemId) -or $impact.RequiresSharedReview -isnot [bool]){throw (New-WsmContractError 'Shared resource identity/review marker is invalid or duplicated.')}
            $seenResources[[string]$impact.ResourceItemId]=$true
            foreach($name in @('ConsumerItemIds','SelectedConsumerItemIds','UnselectedConsumerItemIds','UnknownConsumerItemIds')){$values=@($impact.$name);$ids=@{};foreach($id in $values){if([string]$id -notmatch '^[a-f0-9]{64}$' -or $ids.ContainsKey([string]$id)){throw (New-WsmContractError ('Invalid or duplicate shared consumer id in '+$name+'.'))};$ids[[string]$id]=$true}}
            if($impact.RequiresSharedReview -and [string]::IsNullOrWhiteSpace([string]$impact.OwnerReviewReason)){throw (New-WsmContractError 'Shared consumer impact requires an owner review reason before approval.')}
        }
    }
}
function Assert-WsmMigrationSpec($Spec,[switch]$Assistive) {
    $allowed=@('Adapter','Desired','SourcePath','TargetPath','ExcludedRelativePaths','Consistency','Metadata','ConflictPolicy','SecretRef','Owner','Evidence','DesiredFinalState','BusinessChecks','Product','Procedure','Artifacts','RequiredCommands','AclControlPolicy','CatchUpPolicy','RemoteStorage','AccountMode','ManagedAccountEvidence','ConfigFiles','ConfigOverrides','SettingTransition','TransferChannel','ContentSelection','SourceXml','SourceAutoStart','StagedDisabled','ActivationPolicyFieldPointer','ReviewedActivation','WorkloadMappingReview','SharedResourceImpacts')
    Assert-WsmFields $Spec $allowed @('Adapter','Owner','Evidence')
    if(($Spec.PSObject.Properties['ConfigFiles'] -or $Spec.PSObject.Properties['ConfigOverrides']) -and $Spec.Adapter -cne 'FileScope'){throw (New-WsmContractError 'Configuration artifact classification requires FileScope.')}
    if(($Spec.PSObject.Properties['AccountMode'] -or $Spec.PSObject.Properties['ManagedAccountEvidence']) -and $Spec.Adapter -cne 'Service'){throw 'Service identity fields require a Service adapter.'}
    if($Spec.PSObject.Properties['RemoteStorage']){if($Spec.Adapter -cne 'ManualWorkflow'){throw (New-WsmContractError 'RemoteStorage requires a dedicated ManualWorkflow.')};[void](Assert-WsmRemoteStorageContract $Spec.RemoteStorage ([string]$Spec.Owner))}
    if($Spec.PSObject.Properties['AclControlPolicy'] -and ($Spec.Adapter -ne 'FileScope' -or $Spec.AclControlPolicy -cnotin @('Exact','AllowAutoInheritedUpgrade'))){throw 'ACL control policy must be explicitly reviewed for FileScope.'}
    if($Spec.PSObject.Properties['CatchUpPolicy'] -and $Spec.Adapter -ne 'ScheduledTask'){throw 'CatchUpPolicy is only valid for ScheduledTask.'}
    if (@((Get-WsmAdapterMatrix).Adapter) -cnotcontains $Spec.Adapter -or [string]::IsNullOrWhiteSpace($Spec.Owner) -or [string]::IsNullOrWhiteSpace($Spec.Evidence)) { throw (New-WsmContractError 'Unknown adapter or missing owner/evidence.') }
    if($Spec.PSObject.Properties['SettingTransition']) {
        if(-not (Get-Command Assert-WsmSettingTransition -ErrorAction SilentlyContinue)){throw 'SettingTransition validator is unavailable; transition spec cannot be accepted.'}
        Assert-WsmSettingTransition $Spec.SettingTransition | Out-Null
        if($Spec.SettingTransition.Adapter -cne $Spec.Adapter){throw 'SettingTransition adapter must match MigrationSpec.Adapter.'}
        if($Spec.Adapter -eq 'MachineEnvironment' -and ($Spec.SettingTransition.Name -cne $Spec.Desired.Name -or [string]$Spec.SettingTransition.After.Value -cne [string]$Spec.Desired.Value)){throw 'MachineEnvironment desired state must match the reviewed SettingTransition after value.'}
        if($Spec.Adapter -eq 'TimeZone' -and ($Spec.SettingTransition.Name -cne 'TimeZone' -or [string]$Spec.SettingTransition.After.Value -cne [string]$Spec.Desired.Value)){throw 'TimeZone desired state must match the reviewed SettingTransition after value.'}
    }
    if ($Spec.Adapter -eq 'FileScope') {
        Assert-WsmConfigArtifactSpec $Spec
        foreach ($f in @('SourcePath','TargetPath','ExcludedRelativePaths','Consistency','Metadata','ConflictPolicy')) { if (-not $Spec.PSObject.Properties[$f]) { throw ('FileScope requires '+$f) } }
        [void](ConvertTo-WsmCanonicalPath $Spec.SourcePath); [void](ConvertTo-WsmCanonicalPath $Spec.TargetPath)
        if($Spec.SourcePath.StartsWith('\\') -or $Spec.TargetPath.StartsWith('\\')){throw (New-WsmContractError 'UNC/DFS/NAS scope requires an owner-reviewed dedicated provider identity, alias/ownership and consistency workflow; generic FileScope cannot approve an unresolved remote scope.')}
        if (@('Immutable','OwnerFreeze','ProductBackup') -cnotcontains $Spec.Consistency -or @('DaclOwner','DaclOwnerSacl') -cnotcontains $Spec.Metadata -or @('Block','ReplaceOwned') -cnotcontains $Spec.ConflictPolicy) { throw 'Invalid file scope policy.' }
        foreach ($p in $Spec.ExcludedRelativePaths) { Assert-WsmRelativePath $p }
    }
    elseif ($Spec.Adapter -eq 'ManualWorkflow') {
        foreach ($f in @('Product','Procedure','Artifacts','BusinessChecks')) { if (-not $Spec.PSObject.Properties[$f]) { throw ('Dedicated workflow requires '+$f) } }
        if ([string]::IsNullOrWhiteSpace($Spec.Product) -or [string]::IsNullOrWhiteSpace($Spec.Procedure)) { throw 'Dedicated workflow product/procedure required.' }
    }
    elseif (-not $Spec.PSObject.Properties['Desired']) { throw 'Adapter requires explicit reviewed Desired configuration.' }
    if ($Spec.PSObject.Properties['DesiredFinalState'] -and @('Disabled','Enabled','Manual','Automatic','Stopped','Running') -cnotcontains $Spec.DesiredFinalState) { throw 'Invalid final activation state.' }
    if ($Spec.PSObject.Properties['SecretRef'] -and $Spec.SecretRef -notmatch '^[A-Za-z0-9_.-]{1,128}$') { throw 'SecretRef is a reference, never a password.' }
    # Adapter-specific desired field validation is shared with preview and restore.
    if ($Spec.Adapter -ne 'FileScope' -and $Spec.Adapter -ne 'ManualWorkflow') { Assert-WsmAdapterDesired $Spec }
    if($Assistive){Assert-WsmAssistiveMigrationSpec $Spec}
}
function Set-WsmMigrationSpec {
    param([string]$Workspace,[string]$PairId,[string]$ItemId,[string]$Path,[string]$ExpectedHash,[int]$ExpectedRevision)
    $spec=Read-WsmTrustedJson $Path $ExpectedHash; Assert-WsmMigrationSpec $spec
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        $rows=@($c.Items | Where-Object ItemId -CEQ $ItemId); if ($rows.Count -ne 1) { throw 'Unknown ItemId.' }
        if($c.SchemaVersion -eq 3){Assert-WsmMigrationSpec $spec -Assistive;if(-not $c.Assistive.Selections.Items.Where({$_.ItemId -ceq $ItemId -and $_.Selected}).Count){throw 'Assistive migration specs can only be assigned to currently selected items.'}}
        $rows[0] | Add-Member NoteProperty MigrationSpec $spec -Force
        $rows[0].Owner=$spec.Owner;$rows[0].Evidence=$spec.Evidence
        $c.DecisionRevision++; $c.Approval=$null;if($c.SchemaVersion -eq 3){Clear-WsmAssistiveComparison $c}
        $c.History=@($c.History)+@([pscustomobject]@{ Action='MigrationSpec'; ItemId=$ItemId; Revision=$c.DecisionRevision; Utc=(Get-WsmUtc) })
        Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
    }
}
function Approve-WsmMigrationPlan {
    param([string]$Workspace,[string]$PairId,[string]$TargetIdentityPath,[string]$TargetIdentityHash,[string]$Path,[int]$ExpectedRevision,[Parameter(Mandatory)][string]$PilotAcknowledgement)
    if ($PilotAcknowledgement -cne 'ISOLATED-PILOT') { throw 'Adapters require explicit ISOLATED-PILOT acknowledgement until real-server qualification.' }
    $target=Read-WsmTrustedJson $TargetIdentityPath $TargetIdentityHash; Assert-WsmEnvelope $target 'TargetIdentity'; Assert-WsmId $target.HostId
    if ($target.Fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid target fingerprint.' }
    Invoke-WsmLocked $Workspace {
        $c=Get-WsmCatalog $Workspace $PairId; if ($c.DecisionRevision -ne $ExpectedRevision) { throw 'Review changed.' }
        if (@(Get-WsmReviewIssues $Workspace $PairId | Where-Object Gate -EQ ReviewComplete).Count) { throw 'Complete review and dependencies before migration approval.' }
        if ($c.PSObject.Properties['GeneralHost']) { Assert-WsmGeneralHostContract $c | Out-Null;if($c.SchemaVersion -ne 3){$generalIssues=@(Get-WsmGeneralHostIssues $c ReviewComplete); if ($generalIssues.Count) { throw ('GeneralHost review incomplete: '+(@($generalIssues | ForEach-Object Issue | Select-Object -Unique) -join '; ')) }} }
        if ($target.Fingerprint -ceq $c.Source.Fingerprint) { throw 'Source and target must be different machines.' }
        $selectionIndex=@{};if($c.SchemaVersion -eq 3){foreach($selection in @($c.Assistive.Selections.Items)){$selectionIndex[[string]$selection.ItemId]=$selection}}
        $included=@($c.Items | Where-Object { $_.Decision -ceq 'Include' -and ($c.SchemaVersion -ne 3 -or ($selectionIndex.ContainsKey([string]$_.ItemId) -and $selectionIndex[[string]$_.ItemId].Selected)) }); if (-not $included.Count) { throw 'No selected migration items.' }
        foreach($item in $included){if($item.PSObject.Properties['MigrationSpec']){$spec=$item.MigrationSpec;if($spec.PSObject.Properties['SettingTransition'] -and -not $c.PSObject.Properties['GeneralHost']){throw 'SettingTransition is supported only in an explicitly reviewed GeneralHost plan.'};if($c.PSObject.Properties['GeneralHost'] -and $spec.Adapter -in @('MachineEnvironment','TimeZone') -and -not $spec.PSObject.Properties['SettingTransition']){throw 'GeneralHost machine settings require a reviewed typed SettingTransition.'}}}
        if ($c.PSObject.Properties['GeneralHost']) { foreach($item in $included){if($item.Category -in @('Roles','Runtime')){throw ('GeneralHost scope cannot install or automatically migrate a prepared role/runtime: '+$item.ItemId)};if($item.PSObject.Properties['MigrationSpec'] -and $item.MigrationSpec.Adapter -ceq 'WindowsFeature'){throw 'GeneralHost scope does not install new Windows Features; prepare and verify them manually on the target.'}} }
        [void](Assert-WsmRemoteStorageScopes $included)
        $destinations=@{}
        foreach ($i in $included) {
            if (-not $i.PSObject.Properties['MigrationSpec']) { throw ('No migration specification for '+$i.ItemId) }; Assert-WsmMigrationSpec $i.MigrationSpec -Assistive:($c.SchemaVersion -eq 3)
            if($c.SchemaVersion -eq 3 -and $i.MigrationSpec.Adapter -eq 'FileScope'){
                if(-not (Get-Command Assert-WsmAssistiveSourceScope -ErrorAction SilentlyContinue)){throw 'Assistive source-volume proof helper is unavailable; approval cannot seal.'}
                if($i.MigrationSpec.TransferChannel -ceq 'External'){throw 'External transfer scopes require a dedicated provider workflow.'}
                [void](Assert-WsmAssistiveSourceScope $i.MigrationSpec SourceCOnly)
            }
            if ($i.Status -ne 'Success' -and $i.MigrationSpec.Adapter -ne 'ManualWorkflow' -and $i.MigrationSpec.Adapter -ne 'FileScope') { throw ('Incomplete configuration: '+$i.ItemId) }
            if ($i.MigrationSpec.Adapter -eq 'FileScope') { $dest=(ConvertTo-WsmCanonicalPath $i.MigrationSpec.TargetPath).TrimEnd('\'); foreach ($prior in $destinations.Keys) { if ($dest -ieq $prior -or $dest.StartsWith($prior+'\',[StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($dest+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Migration scopes have overlapping destinations.' } }; $destinations[$dest]=$i.ItemId }
        }
        $planItems=$c.Items
        if($c.SchemaVersion -eq 3){$planItems=$included}
        $plan=[pscustomobject][ordered]@{ SchemaVersion=1; ToolVersion=$script:ToolVersion; Kind='MigrationPlan'; BatchId=$c.BatchId; PairId=$c.PairId; ApprovalId=[Guid]::NewGuid().ToString(); Source=$c.Source; Target=$target; InventoryRevision=$c.InventoryRevision; DecisionRevision=$c.DecisionRevision; InventoryHash=$c.InventoryHash; Mode='IsolatedPilot'; ToolFingerprint=(Get-WsmToolFingerprint); ApprovedUtc=(Get-WsmUtc); Items=@($planItems | Select-Object ItemId,Category,Kind,Name,NaturalKey,Settings,SettingsHash,Dependencies,Status,Adapter,Present,ManualEntry,Decision,Reason,Mapping,AccountMapping,EndpointMapping,Owner,Evidence,MigrationSpec,ConsistencyGroup,ConsistencyOwner,ConsistencyEvidence,GeneralHostOverride) }
        if ($c.PSObject.Properties['GeneralHost']) { if($c.SchemaVersion -ne 3){$plan.SchemaVersion=2}; $plan | Add-Member NoteProperty ScopeMode 'GeneralHost'; $plan | Add-Member NoteProperty GeneralHost $c.GeneralHost }
        if($c.SchemaVersion -eq 3){$plan=New-WsmAssistiveMigrationPlanContract $plan $c}
        if ($c.PSObject.Properties['PairPlan']) { $plan | Add-Member NoteProperty PairPlan $c.PairPlan }
        if($c.PSObject.Properties['IdentityMap']){Assert-WsmIdentityMap $c.IdentityMap;foreach($m in $c.IdentityMap.Mappings){if($m.CreatedByItemId){$creator=@($included | Where-Object ItemId -CEQ $m.CreatedByItemId);if($creator.Count -ne 1 -or $creator[0].MigrationSpec.Desired.Name -ine $m.TargetAccount.Split('\')[-1]){throw 'Identity map must reference the included creator of the reviewed target account.'};foreach($scope in ($plan.Items | Where-Object {$_.Decision -eq 'Include' -and $_.MigrationSpec.Adapter -eq 'FileScope'})){if(-not @($scope.Dependencies | Where-Object ItemId -CEQ $m.CreatedByItemId).Count){$scope.Dependencies=@($scope.Dependencies)+@([pscustomobject]@{ItemId=$m.CreatedByItemId;Type='Mandatory';Evidence='Approved SID mapping prerequisite'})}}}};$plan | Add-Member NoteProperty IdentityMap $c.IdentityMap}
        if ($c.PSObject.Properties['CrossHostDependencies']) { $plan | Add-Member NoteProperty CrossHostDependencies $c.CrossHostDependencies }
        if (Get-Command Assert-WsmOraclePlanConfigOwnership -ErrorAction SilentlyContinue) { Assert-WsmOraclePlanConfigOwnership $plan | Out-Null }
        elseif (@($plan.Items | Where-Object { $_.Decision -eq 'Include' -and $_.MigrationSpec.Adapter -eq 'FileScope' -and $_.MigrationSpec.PSObject.Properties['ConfigFiles'] -and @($_.MigrationSpec.ConfigFiles | Where-Object { $_.PSObject.Properties['OracleClient'] }).Count }).Count) { throw 'Oracle plan ownership validator is unavailable.' }
        Write-WsmJson $Path $plan
        $hash=(Get-FileHash -LiteralPath $Path).Hash
        $c.Approval=[pscustomobject]@{ ApprovalId=$plan.ApprovalId; Hash=$hash; Utc=$plan.ApprovedUtc; Kind='MigrationPlan'; Mode='IsolatedPilot'; ScopeMode=$(if($c.PSObject.Properties['GeneralHost']){'GeneralHost'}else{'Legacy'}); TargetHostId=$target.HostId; TargetFingerprint=$target.Fingerprint }; Write-WsmJson (Get-WsmCatalogPath $Workspace $PairId) $c
        [pscustomobject]@{ Path=[IO.Path]::GetFullPath($Path); SHA256=$hash; Mode='IsolatedPilot'; ProductionVerified=$false }
    }
}
function Read-WsmMigrationPlan([string]$Path,[string]$ExpectedHash) {
    $p=Read-WsmTrustedJson $Path $ExpectedHash; Assert-WsmEnvelope $p 'MigrationPlan'; if(-not $p.PSObject.Properties['ToolFingerprint'] -or $p.ToolFingerprint -cne (Get-WsmToolFingerprint)){throw 'Installed tool bytes changed; reapprove the deployed release before migration.'}
    foreach ($id in @($p.BatchId,$p.PairId,$p.ApprovalId,$p.Source.HostId,$p.Target.HostId)) { Assert-WsmId $id }
    if ($p.Mode -cne 'IsolatedPilot' -or $p.Source.Fingerprint -notmatch '^[a-f0-9]{64}$' -or $p.Target.Fingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid migration mode/identity.' }
    if ($p.SchemaVersion -eq 2 -and ($p.ScopeMode -cne 'GeneralHost' -or -not $p.GeneralHost)) { throw 'Invalid GeneralHost migration plan.' }
    if($p.SchemaVersion -eq 3 -and $p.PSObject.Properties['GeneralHost'] -and ($p.ScopeMode -cne 'GeneralHost' -or -not $p.GeneralHost)){throw 'Invalid optional GeneralHost schema 3 plan section.'}
    $seen=@{}; foreach ($i in $p.Items) { if ($i.ItemId -notmatch '^[a-f0-9]{64}$' -or $seen.ContainsKey($i.ItemId) -or @('Include','Exclude') -cnotcontains $i.Decision) { throw 'Invalid migration item.' }; if($p.SchemaVersion -eq 3 -and $i.Decision -cne 'Include'){throw 'Schema 3 sealed plans contain only explicitly approved Include items.'};$seen[$i.ItemId]=$true; if ($i.Decision -eq 'Include') { Assert-WsmMigrationSpec $i.MigrationSpec -Assistive:($p.SchemaVersion -eq 3); if($i.MigrationSpec.PSObject.Properties['SettingTransition'] -and ($p.SchemaVersion -ne 2 -or $p.ScopeMode -cne 'GeneralHost')){throw 'SettingTransition is supported only by a GeneralHost schema 2 plan.'};if($p.SchemaVersion -eq 2 -and $i.MigrationSpec.Adapter -in @('MachineEnvironment','TimeZone') -and -not $i.MigrationSpec.PSObject.Properties['SettingTransition']){throw 'GeneralHost machine settings require a reviewed typed SettingTransition.'};if($p.SchemaVersion -eq 3 -and $i.MigrationSpec.Adapter -eq 'FileScope'){if(-not (Get-Command Assert-WsmAssistiveSourceScope -ErrorAction SilentlyContinue)){throw 'Assistive source-volume proof helper is unavailable.'};[void](Assert-WsmAssistiveSourceScope $i.MigrationSpec $p.Assistive.SourcePolicy)} } }
    if($p.SchemaVersion -eq 3){Assert-WsmAssistiveContract $p MigrationPlan | Out-Null;if($seen.Count -ne @($p.Assistive.ApprovedItemIds).Count){throw 'Schema 3 plan item set and approved item subset differ.'};foreach($id in $seen.Keys){if(@($p.Assistive.ApprovedItemIds | Where-Object {$_ -ceq $id}).Count -ne 1){throw 'Schema 3 plan item set and approved item subset differ.'}}}
    [void](Assert-WsmRemoteStorageScopes @($p.Items | Where-Object Decision -CEQ Include))
    if (Get-Command Assert-WsmOraclePlanConfigOwnership -ErrorAction SilentlyContinue) { Assert-WsmOraclePlanConfigOwnership $p | Out-Null }
    elseif (@($p.Items | Where-Object { $_.Decision -eq 'Include' -and $_.MigrationSpec.Adapter -eq 'FileScope' -and $_.MigrationSpec.PSObject.Properties['ConfigFiles'] -and @($_.MigrationSpec.ConfigFiles | Where-Object { $_.PSObject.Properties['OracleClient'] }).Count }).Count) { throw 'Oracle plan ownership validator is unavailable.' }
    $p
}
