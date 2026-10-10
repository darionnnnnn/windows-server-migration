function New-WsmIisManager {
    Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
    New-Object Microsoft.Web.Administration.ServerManager
}
function Get-WsmIisState($Spec) {
    if($Spec.Adapter -in @('IISSection','IISLocation')){return Get-WsmIisConfigState $Spec}
    $m=New-WsmIisManager
    try { $collection=$m.Sites; if($Spec.Adapter -eq 'IISPool'){$collection=$m.ApplicationPools}; $object=$collection[$Spec.Desired.Name]; if(-not $object){return [pscustomobject]@{Exists=$false}}; [pscustomobject]@{Exists=$true; State=[string]$object.State; Configuration=(Get-WsmIisElementSnapshot $object)} } finally{$m.Dispose()}
}
function Get-WsmIisConfigState($Spec) {
    $manager=New-WsmIisManager
    try {
        $configuration=$manager.GetApplicationHostConfiguration();$desired=$Spec.Desired
        $section=$null
        if($Spec.Adapter -eq 'IISLocation'){$section=$configuration.GetSection([string]$desired.SectionPath,[string]$desired.LocationPath)}else{$section=$configuration.GetSection([string]$desired.SectionPath)}
        if($null -eq $section){return [pscustomobject]@{Exists=$false;Xml='';SectionPath=$desired.SectionPath;LocationPath=$desired.LocationPath}}
        $xml=[string]$section.SectionInformation.GetRawXml()
        if(-not $xml){$xml='<'+([string]$desired.SectionPath -split '/')[-1]+'/>'}
        [pscustomobject]@{Exists=$true;Xml=$xml;SectionPath=[string]$desired.SectionPath;LocationPath=[string]$desired.LocationPath}
    } finally {$manager.Dispose()}
}

function Split-WsmIisFieldPointer([string]$Pointer) {
    $parts=New-Object 'System.Collections.Generic.List[string]';$buffer=New-Object Text.StringBuilder;$predicate=$false;$quoted=$false
    foreach($character in $Pointer.TrimStart('/').ToCharArray()){
        if($character -eq "'" -and $predicate){$quoted=-not $quoted}
        if($character -eq '[' -and -not $quoted){$predicate=$true}
        elseif($character -eq ']' -and -not $quoted){$predicate=$false}
        if($character -eq '/' -and -not $predicate -and -not $quoted){$parts.Add($buffer.ToString());[void]$buffer.Clear()}else{[void]$buffer.Append($character)}
    }
    if($predicate -or $quoted){throw 'IIS field pointer has an unterminated key predicate.'};$parts.Add($buffer.ToString());$parts.ToArray()
}
function Get-WsmIisPointerNode($Document,[string]$Pointer,[switch]$AllowMissingLeaf) {
    $parts=@(Split-WsmIisFieldPointer $Pointer);$current=$Document.DocumentElement
    if(-not $current -or $current.LocalName -cne [regex]::Match($parts[0], '^[^\[]+').Value){throw 'IIS field pointer root does not match selected section.'}
    for($i=1;$i -lt $parts.Count;$i++){
        $part=$parts[$i];if($part.StartsWith('@')){return [pscustomobject]@{Node=$current;AttributeName=$part.Substring(1)}}
        $name=$part;$keys=@{}
        if($part -match '^([^\[]+)\[@([^=]+)=\x27(.*)\x27\]$'){$name=$Matches[1];$keyName=$Matches[2];$keyValue=[System.Net.WebUtility]::HtmlDecode($Matches[3]);$keys[$keyName]=$keyValue}elseif($part.Contains('[')){throw 'Unsupported IIS field pointer predicate.'}
        $matches=New-Object 'System.Collections.Generic.List[object]'
        foreach($child in $current.ChildNodes){if($child.NodeType -ne [Xml.XmlNodeType]::Element -or $child.LocalName -cne $name){continue};$keyMatch=$true;foreach($keyName in $keys.Keys){$keyAttribute=$child.Attributes[[string]$keyName];if(-not $keyAttribute -or [string]$keyAttribute.Value -cne [string]$keys[$keyName]){$keyMatch=$false;break}};if($keyMatch){$matches.Add($child)}}
        if($matches.Count -eq 0 -and $AllowMissingLeaf -and $i -eq $parts.Count-1){return [pscustomobject]@{Node=$current;MissingName=$name;KeyAttributes=$keys}}
        if($matches.Count -ne 1){throw 'IIS field pointer is absent or ambiguous in current configuration.'};$current=$matches[0]
    }
    [pscustomobject]@{Node=$current;AttributeName=''}
}

function Set-WsmIisConfigChanges($Document,$Changes) {
    foreach($change in @($Changes)){
        $pointer=[string]$change.FieldPointer
        if($change.Operation -eq 'SetAttribute'){
            $resolved=Get-WsmIisPointerNode $Document $pointer
            $attribute=$resolved.Node.Attributes[[string]$change.AttributeName]
            if(-not $attribute -or [string]$attribute.Value -cne [string]$change.BeforeValue){throw 'IIS config SetAttribute precondition differs from observed target XML.'}
            $attribute.Value=[string]$change.AfterValue
        }elseif($change.Operation -eq 'AddElement'){
            $parent=Get-WsmIisPointerNode $Document $pointer
            if($parent.AttributeName){throw 'IIS AddElement pointer must identify a collection element.'}
            $fragment=New-Object System.Xml.XmlDocument;$fragment.XmlResolver=$null;$fragment.LoadXml([string]$change.AfterValue)
            $same=@($parent.Node.ChildNodes | Where-Object {$_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.LocalName -ceq $fragment.DocumentElement.LocalName -and (ConvertTo-WsmXmlComparable $_) -ceq (ConvertTo-WsmXmlComparable $fragment.DocumentElement)})
            if($same.Count){throw 'IIS AddElement target already exists; refusing an ambiguous append.'}
            [void]$parent.Node.AppendChild($Document.ImportNode($fragment.DocumentElement,$true))
        }elseif($change.Operation -eq 'RemoveElement'){
            $resolved=Get-WsmIisPointerNode $Document $pointer
            if($resolved.AttributeName -or $resolved.Node.LocalName -cne [string]$change.ElementName){throw 'IIS RemoveElement pointer does not identify the declared element.'}
            $fragment=New-Object System.Xml.XmlDocument;$fragment.XmlResolver=$null;$fragment.LoadXml([string]$change.BeforeValue)
            if((ConvertTo-WsmXmlComparable $resolved.Node) -cne (ConvertTo-WsmXmlComparable $fragment.DocumentElement)){throw 'IIS RemoveElement precondition differs from observed target XML.'}
            [void]$resolved.Node.ParentNode.RemoveChild($resolved.Node)
        }else{throw 'Unsupported IIS configuration change.'}
    }
    $Document
}

function Get-WsmIisReviewedActivationXml($Spec,[switch]$RestoreStaged) {
    if($Spec.Adapter -notin @('IISSection','IISLocation')){throw 'Reviewed field activation is limited to typed IIS section/location adapters.'}
    [void](Assert-WsmAssistiveReviewedActivation $Spec)
    $activation=$Spec.ReviewedActivation;$attribute=([string]$activation.FieldPointer -split '/@')[-1]
    $document=Read-WsmXml ([string]$Spec.Desired.Xml);$resolved=Get-WsmIisPointerNode $document ([string]$activation.FieldPointer);$nodeAttribute=$resolved.Node.Attributes[$attribute]
    if(-not $nodeAttribute){throw 'Reviewed IIS activation attribute disappeared from target XML.'}
    $finalValue=[string]$activation.FinalValue;if($RestoreStaged){$finalValue=[string]$activation.StagedValue}
    $nodeAttribute.Value=$finalValue
    $document.OuterXml
}
function Invoke-WsmIisConfigActivation($Spec,[bool]$Enable) {
    $state=Get-WsmIisConfigState $Spec;if(-not $state.Exists){throw 'Selected IIS section/location is unavailable for activation.'}
    $stagedXml=[string]$Spec.Desired.Xml;$finalXml=Get-WsmIisReviewedActivationXml $Spec
    $expectedXml=$stagedXml;if($Enable -and [string]$Spec.ReviewedActivation.FinalState -ceq 'Enabled'){$expectedXml=$finalXml}
    $actual=Read-WsmXml ([string]$state.Xml);$expected=Read-WsmXml $expectedXml
    if((ConvertTo-WsmXmlComparable $actual.DocumentElement) -ceq (ConvertTo-WsmXmlComparable $expected.DocumentElement)){return [pscustomobject]@{PriorXml=$state.Xml;DesiredXml=$expectedXml;Readback=$state;AlreadyApplied=$true}}
    if((ConvertTo-WsmXmlComparable $actual.DocumentElement) -cne (ConvertTo-WsmXmlComparable (Read-WsmXml $stagedXml).DocumentElement) -and (ConvertTo-WsmXmlComparable $actual.DocumentElement) -cne (ConvertTo-WsmXmlComparable (Read-WsmXml $finalXml).DocumentElement)){throw 'IIS section/location drifted from both exact staged and reviewed final XML; activation refused.'}
    $manager=New-WsmIisManager
    try{$config=$manager.GetApplicationHostConfiguration();if($Spec.Adapter -eq 'IISLocation'){$section=$config.GetSection([string]$Spec.Desired.SectionPath,[string]$Spec.Desired.LocationPath)}else{$section=$config.GetSection([string]$Spec.Desired.SectionPath)};$section.SectionInformation.SetRawXml($expectedXml);$manager.CommitChanges()}finally{$manager.Dispose()}
    $readback=Get-WsmIisConfigState $Spec;$actualReadback=Read-WsmXml ([string]$readback.Xml)
    if(-not $readback.Exists -or (ConvertTo-WsmXmlComparable $actualReadback.DocumentElement) -cne (ConvertTo-WsmXmlComparable (Read-WsmXml $expectedXml).DocumentElement)){throw 'IIS section/location activation did not pass exact native XML readback.'}
    [pscustomobject]@{PriorXml=$state.Xml;DesiredXml=$expectedXml;Readback=$readback;AlreadyApplied=$false}
}

function Invoke-WsmIisConfigRestore($Spec) {
    $before=Get-WsmIisConfigState $Spec
    if(-not $before.Exists){throw 'Selected IIS configuration section is unavailable on the target.'}
    $document=Read-WsmXml $before.Xml
    $updated=Set-WsmIisConfigChanges $document @($Spec.Desired.Changes)
    $targetXml=$updated.OuterXml
    $desired=Read-WsmXml ([string]$Spec.Desired.Xml)
    if((ConvertTo-WsmXmlComparable $updated.DocumentElement) -cne (ConvertTo-WsmXmlComparable $desired.DocumentElement)){throw 'Applied IIS config changes do not equal the reviewed typed Desired.Xml fragment.'}
    $manager=New-WsmIisManager
    try{$config=$manager.GetApplicationHostConfiguration();if($Spec.Adapter -eq 'IISLocation'){$section=$config.GetSection([string]$Spec.Desired.SectionPath,[string]$Spec.Desired.LocationPath)}else{$section=$config.GetSection([string]$Spec.Desired.SectionPath)};$section.SectionInformation.SetRawXml($targetXml);$manager.CommitChanges()}finally{$manager.Dispose()}
    [pscustomobject]@{PriorXml=$before.Xml;DesiredXml=$targetXml;Readback=(Get-WsmIisConfigState $Spec)}
}
function Restore-WsmIisConfigPriorXml($Spec,[string]$PriorXml) {
    if([string]::IsNullOrWhiteSpace($PriorXml)){throw 'Exact prior IIS section XML is unavailable; retain current state and reconcile manually.'}
    $current=Get-WsmIisConfigState $Spec;$expected=Read-WsmXml ([string]$Spec.Desired.Xml)
    if(-not $current.Exists -or (ConvertTo-WsmXmlComparable (Read-WsmXml $current.Xml).DocumentElement) -cne (ConvertTo-WsmXmlComparable $expected.DocumentElement)){throw 'IIS section/location drifted from the exact staged desired state; rollback refused.'}
    $manager=New-WsmIisManager
    try{$config=$manager.GetApplicationHostConfiguration();if($Spec.Adapter -eq 'IISLocation'){$section=$config.GetSection([string]$Spec.Desired.SectionPath,[string]$Spec.Desired.LocationPath)}else{$section=$config.GetSection([string]$Spec.Desired.SectionPath)};$section.SectionInformation.SetRawXml($PriorXml);$manager.CommitChanges()}finally{$manager.Dispose()}
    $readback=Get-WsmIisConfigState $Spec;$prior=Read-WsmXml $PriorXml
    if(-not $readback.Exists -or (ConvertTo-WsmXmlComparable (Read-WsmXml $readback.Xml).DocumentElement) -cne (ConvertTo-WsmXmlComparable $prior.DocumentElement)){throw 'IIS prior configuration did not pass native readback after rollback.'}
    $readback
}
function Get-WsmIisElementSnapshot($Element) {
    $attributes=[ordered]@{}; foreach($a in $Element.Attributes){$attributes[$a.Name]=[string]$a.Value}
    $children=@(foreach($e in $Element.ChildElements){Get-WsmIisElementSnapshot $e})
    $members=@(); try{$members=@(foreach($e in $Element.GetCollection()){Get-WsmIisElementSnapshot $e})}catch{}
    [pscustomobject]@{Name=$Element.ElementTagName; Attributes=$attributes; Children=$children; Members=$members}
}
function Set-WsmIisXmlElement($Element,$Node) {
    if($null -eq $Element){throw ('Target IIS element is absent for '+$Node.LocalName)}
    foreach($attribute in $Node.Attributes){
        if($attribute.Name -eq 'xmlns'){continue}
        $target=$Element.Attributes[$attribute.Name]
        if($null -eq $target){throw ('Target IIS schema has no attribute '+$attribute.Name)}
        $value=$attribute.Value
        $type=$null
        if($target.PSObject.Properties['Schema'] -and $target.Schema.Type){$type=$target.Schema.Type}
        elseif($null -ne $target.Value){$type=$target.Value.GetType()}
        if($type -and $type -ne [string]){$value=ConvertTo-WsmIisTypedValue $value $type}
        $Element.SetAttributeValue($attribute.Name,$value)
    }
    foreach($child in $Node.ChildNodes){
        if($child.NodeType -ne [Xml.XmlNodeType]::Element){continue}
        $target=$null
        try {$target=$Element.GetChildElement($child.LocalName)} catch {}
        if($null -ne $target){Set-WsmIisXmlElement $target $child; continue}
        $collection=$null
        try {$collection=$Element.GetCollection()} catch {throw ('Target IIS schema has no child or default collection for '+$child.LocalName)}
        $new=$collection.CreateElement($child.LocalName)
        if($null -eq $new){throw ('Target IIS schema cannot create collection member '+$child.LocalName)}
        Set-WsmIisXmlElement $new $child
        $collection.Add($new)
    }
}
function Invoke-WsmIisRestore($Spec,$Credential) {
    $doc=Read-WsmXml $Spec.Desired.Xml; $m=New-WsmIisManager
    try {
        if($Spec.Adapter -eq 'IISPool') {
            if($m.ApplicationPools[$Spec.Desired.Name]){throw 'IIS pool already exists.'}
            $object=$m.ApplicationPools.Add($Spec.Desired.Name); Set-WsmIisXmlElement $object $doc.DocumentElement
            $object.AutoStart=$false; $object.StartMode=[Microsoft.Web.Administration.StartMode]::OnDemand
            if($Credential){$object.ProcessModel.IdentityType=[Microsoft.Web.Administration.ProcessModelIdentityType]::SpecificUser; $object.ProcessModel.UserName=$Credential.UserName; $object.ProcessModel.Password=$Credential.GetNetworkCredential().Password}
        }
        else {
            if($m.Sites[$Spec.Desired.Name]){throw 'IIS site already exists.'}
            $section=$m.GetApplicationHostConfiguration().GetSection('system.applicationHost/sites'); $collection=$section.GetCollection(); $element=$collection.CreateElement('site'); Set-WsmIisXmlElement $element $doc.DocumentElement; $element.SetAttributeValue('serverAutoStart',$false)
            # IDs are target-local; never reuse a source ID already assigned to another site.
            $next=[long]1; foreach($site in $m.Sites){if($site.Id -ge $next){$next=$site.Id+1}}; $element.SetAttributeValue('id',$next); $collection.Add($element)
        }
        $m.CommitChanges()
    } finally{$m.Dispose()}
    if($Spec.Adapter -eq 'IISSite'){
        $m=New-WsmIisManager
        try{foreach($binding in $Spec.Desired.Bindings){Assert-WsmFields $binding @('Protocol','BindingInformation','CertificateHash','CertificateStoreName','SslFlags') @('Protocol','BindingInformation'); $b=@($m.Sites[$Spec.Desired.Name].Bindings | Where-Object {$_.Protocol -ceq $binding.Protocol -and $_.BindingInformation -ceq $binding.BindingInformation}); if($b.Count -ne 1){throw 'Reviewed IIS binding does not match site XML.'}; if($binding.Protocol -eq 'https'){if(-not $binding.CertificateHash -or $binding.CertificateHash -notmatch '^[a-fA-F0-9]{40}$'){throw 'HTTPS requires a reviewed certificate thumbprint.'}; $bytes=New-Object byte[] 20; for($n=0;$n -lt 20;$n++){$bytes[$n]=[Convert]::ToByte($binding.CertificateHash.Substring($n*2,2),16)}; $b[0].CertificateHash=$bytes; $b[0].CertificateStoreName=$binding.CertificateStoreName; if($binding.PSObject.Properties['SslFlags']){$b[0].SslFlags=$binding.SslFlags}}}; $m.CommitChanges()}finally{$m.Dispose()}
    }
}
function ConvertTo-WsmIisTypedValue($Value,$Type) {
    if($null -eq $Type){return [string]$Value}
    if($Type -is [string]){
        switch -Regex ($Type) {
            '^(?i:bool)$' {return [bool]::Parse([string]$Value)}
            '^(?i:timespan)$' {return [TimeSpan]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)}
            '^(?i:uint)$' {return [UInt32]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)}
            '^(?i:int)$' {return [Int32]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)}
            '^(?i:int64)$' {return [Int64]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)}
            default {return [string]$Value}
        }
    }
    if($Type -eq [TimeSpan]){return [TimeSpan]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)}
    if($Type -is [type] -and $Type.IsEnum){return [Enum]::Parse($Type,[string]$Value,$true)}
    return [Convert]::ChangeType($Value,$Type,[Globalization.CultureInfo]::InvariantCulture)
}
function Get-WsmIisSchemaAttributes($Element) {
    $items=@($Element.Attributes)
    if($Element.Attributes -is [System.Collections.IDictionary]){$items=@($Element.Attributes.Values)}
    foreach($attribute in $items){
        if($attribute -and $attribute.PSObject.Properties['Name']){Write-Output $attribute}
    }
}
function Find-WsmIisXmlAttribute($Node,[string]$Name) {
    foreach($attribute in $Node.Attributes){if($attribute.Name -ceq $Name){return $attribute}}
    return $null
}
function Get-WsmIisCollectionKeyNames($Element) {
    $names=@()
    $attributes=@($Element.Attributes); if($Element.Attributes -is [System.Collections.IDictionary]){$attributes=@($Element.Attributes.Values)}
    foreach($attribute in $attributes){
        $schema=$null; if($attribute.PSObject.Properties['Schema']){$schema=$attribute.Schema}
        if($schema){$isUnique=$false;$isCombined=$false;try{$isUnique=[bool]$schema.IsUniqueKey}catch{};try{$isCombined=[bool]$schema.IsCombinedKey}catch{};if($isUnique -or $isCombined){$names+=@([string]$attribute.Name)}}
    }
    return $names
}
function Test-WsmIisAttributeValue($Element,[string]$Name,$Expected,[string]$Path) {
    $attribute=$Element.Attributes[$Name]
    if($null -eq $attribute){return ('IIS target schema has no attribute: '+$Path+'/'+$Name)}
    try {
        $actual=$attribute.Value
        $value=$Expected
        $type=$null; if($attribute.PSObject.Properties['Schema'] -and $attribute.Schema.Type){$type=$attribute.Schema.Type}elseif($null -ne $actual -and $actual -isnot [string]){$type=$actual.GetType()}
        if($type){$actual=ConvertTo-WsmIisTypedValue $actual $type;$value=ConvertTo-WsmIisTypedValue $Expected $type}
        if(-not [object]::Equals($actual,$value)){return ('IIS attribute mismatch: '+$Path+'/'+$Name)}
    } catch {return ('IIS attribute cannot be compared: '+$Path+'/'+$Name)}
    return $null
}
function Test-WsmIisXmlElement($Element,$Node,[switch]$Root,[string]$Path='') {
    if($null -eq $Element){return ('IIS target element absent: '+$Path+'/'+$Node.LocalName)}
    $elementPath=$Path+'/'+$Node.LocalName
    $handled=@{xmlns=$true}
    if($Root){$handled.id=$true;$handled.serverAutoStart=$true;$handled.autoStart=$true;$handled.startMode=$true}
    foreach($a in $Node.Attributes){
        if($handled.ContainsKey($a.Name)){continue}
        $error=Test-WsmIisAttributeValue $Element $a.Name $a.Value $elementPath
        if($error){$error}
    }
    # XML omits attributes at their schema default. Confirm the target still has
    # that default so a changed value cannot hide behind an omitted XML attribute.
    foreach($attribute in (Get-WsmIisSchemaAttributes $Element)){
        $name=$attribute.Name; if(-not $name -and $attribute.Key){$name=[string]$attribute.Key}
        if(-not $name -or $handled.ContainsKey($name) -or $null -ne (Find-WsmIisXmlAttribute $Node $name)){continue}
        $schema=$null; if($attribute.PSObject.Properties['Schema']){$schema=$attribute.Schema}
        if($null -eq $schema){continue}
        try {
            $default=$schema.DefaultValue
            $actual=$attribute.Value
            $type=$null; if($schema.Type){$type=$schema.Type}elseif($null -ne $actual -and $actual -isnot [string]){$type=$actual.GetType()}
            if($type){$actual=ConvertTo-WsmIisTypedValue $actual $type;$default=ConvertTo-WsmIisTypedValue $default $type}
            if(-not [object]::Equals($actual,$default)){('IIS omitted attribute differs from schema default: '+$elementPath+'/'+$name)}
        } catch {('IIS schema default cannot be compared: '+$elementPath+'/'+$name)}
    }

    $xmlChildren=@(foreach($child in $Node.ChildNodes){if($child.NodeType -eq [Xml.XmlNodeType]::Element){$child}})
    $expectedUnique=@{}
    $expectedCollection=@()
    foreach($child in $xmlChildren){
        $childElement=$null
        try {$childElement=$Element.GetChildElement($child.LocalName)} catch {}
        if($null -ne $childElement){
            $expectedUnique[$child.LocalName]=$true
            foreach($error in (Test-WsmIisXmlElement $childElement $child -Path $elementPath)){if($error){$error}}
        } else {$expectedCollection+=@($child)}
    }
    # Unique schema children omitted from the source must remain empty/default.
    foreach($childElement in $Element.ChildElements){
        $name=$childElement.ElementTagName
        if($expectedUnique.ContainsKey($name)){continue}
        foreach($error in (Test-WsmIisDefaultIisElement $childElement ($elementPath+'/'+$name))){if($error){$error}}
    }
    if($expectedCollection.Count -gt 0){
        try {
            $collection=@($Element.GetCollection())
            $used=@{}
            foreach($child in $expectedCollection){
                $sameTag=@(for($i=0;$i -lt $collection.Count;$i++){if(-not $used.ContainsKey([string]$i) -and $collection[$i].ElementTagName -ceq $child.LocalName){$i}})
                $keyNames=@(); if($sameTag.Count){$keyNames=@(Get-WsmIisCollectionKeyNames $collection[$sameTag[0]])}
                $matches=@(foreach($index in $sameTag){
                    $candidate=$collection[$index]; $isMatch=$true
                    foreach($keyName in $keyNames){$xmlKey=Find-WsmIisXmlAttribute $child $keyName; if($null -eq $xmlKey -or [string]$candidate.GetAttributeValue($keyName) -cne [string]$xmlKey.Value){$isMatch=$false;break}}
                    if($isMatch){$index}
                })
                if(-not $keyNames.Count -and $sameTag.Count){$matches=@($sameTag[0])}
                if($matches.Count -ne 1){('IIS collection element missing/ambiguous: '+$elementPath+'/'+$child.LocalName)}
                else {$index=[string]$matches[0];$used[$index]=$true;foreach($error in (Test-WsmIisXmlElement $collection[[int]$index] $child -Path $elementPath)){if($error){$error}}}
            }
            if($collection.Count -ne $expectedCollection.Count){('Unexpected IIS collection element: '+$elementPath)}
        } catch {('IIS collection cannot be compared: '+$elementPath)}
    } else {
        try {$collection=@($Element.GetCollection()); if($collection.Count){('Unexpected IIS collection element: '+$elementPath)}} catch {}
    }
}
function Test-WsmIisDefaultIisElement($Element,[string]$Path) {
    foreach($attribute in (Get-WsmIisSchemaAttributes $Element)){
        $name=$attribute.Name; if(-not $name -and $attribute.Key){$name=[string]$attribute.Key}
        if(-not $name){continue}
        try {if(-not $attribute.PSObject.Properties['Schema']){continue}; $schema=$attribute.Schema; $default=$schema.DefaultValue; $actual=$attribute.Value; $type=$null;if($schema.Type){$type=$schema.Type}elseif($null -ne $actual -and $actual -isnot [string]){$type=$actual.GetType()};if($type){$actual=ConvertTo-WsmIisTypedValue $actual $type;$default=ConvertTo-WsmIisTypedValue $default $type}; if(-not [object]::Equals($actual,$default)){('Unexpected IIS nested element setting: '+$Path+'/'+$name)}} catch {('IIS nested schema default cannot be compared: '+$Path+'/'+$name)}
    }
    foreach($child in $Element.ChildElements){foreach($error in (Test-WsmIisDefaultIisElement $child ($Path+'/'+$child.ElementTagName))){if($error){$error}}}
    try {$collection=@($Element.GetCollection()); if($collection.Count){('Unexpected IIS nested collection element: '+$Path)}} catch {}
}
function Test-WsmIisConfiguration($Spec,[string]$Phase) {
    $m=New-WsmIisManager
    try{$object=$m.Sites[$Spec.Desired.Name]; if($Spec.Adapter -eq 'IISPool'){$object=$m.ApplicationPools[$Spec.Desired.Name]}; if(-not $object){return 'IIS object absent'}; $xml=Read-WsmXml $Spec.Desired.Xml; Test-WsmIisXmlElement $object $xml.DocumentElement -Root;if($Spec.Adapter -eq 'IISSite'){Test-WsmIisBindings $object $Spec.Desired}; if($Phase -eq 'Staged' -and [string]$object.State -ne 'Stopped'){'IIS object must remain stopped'}; if($Phase -eq 'Staged' -and $Spec.Adapter -eq 'IISPool' -and $object.AutoStart){'IIS pool AutoStart must remain false'}; if($Phase -eq 'Staged' -and $Spec.Adapter -eq 'IISPool' -and [string]$object.StartMode -ine 'OnDemand'){'IIS pool StartMode must remain OnDemand'}; if($Phase -eq 'Staged' -and $Spec.Adapter -eq 'IISSite' -and $object.ServerAutoStart){'IIS site ServerAutoStart must remain false'};if($Phase -eq 'Final'){$active=Get-WsmDesiredActivation $Spec;$expected='Stopped';if($active){$expected='Started'};if([string]$object.State -ne $expected){'IIS final running state mismatch'};if($Spec.Adapter -eq 'IISPool'){$expectedMode='OnDemand';$modeAttribute=Find-WsmIisXmlAttribute $xml.DocumentElement 'startMode';if($active -and $modeAttribute){$expectedMode=$modeAttribute.Value};if([string]$object.StartMode -ine $expectedMode){'IIS final startMode mismatch'}};if($Spec.Adapter -eq 'IISPool' -and $object.AutoStart -ne $active){'IIS final AutoStart mismatch'};if($Spec.Adapter -eq 'IISSite' -and $object.ServerAutoStart -ne $active){'IIS final ServerAutoStart mismatch'}}}finally{$m.Dispose()}
}
function Test-WsmIisBindings($Object,$Desired) {
    foreach($expected in $Desired.Bindings){$found=@($Object.Bindings | Where-Object {$_.Protocol -ieq $expected.Protocol -and $_.BindingInformation -ceq $expected.BindingInformation});if($found.Count -ne 1){'IIS binding missing/ambiguous';continue};if($expected.Protocol -ieq 'https'){$actual=[BitConverter]::ToString($found[0].CertificateHash).Replace('-','');if($actual -ine $expected.CertificateHash -or $found[0].CertificateStoreName -ine $expected.CertificateStoreName -or [int]$found[0].SslFlags -ne [int]$expected.SslFlags){'IIS HTTPS certificate/store/flags mismatch'}}}
    if(@($Object.Bindings).Count -ne @($Desired.Bindings).Count){'Unexpected IIS binding'}
}
function Remove-WsmIisObject($Spec) {
    $m=New-WsmIisManager
    try{$collection=$m.Sites; if($Spec.Adapter -eq 'IISPool'){$collection=$m.ApplicationPools}; $object=$collection[$Spec.Desired.Name]; if($object){if([string]$object.State -ne 'Stopped'){throw 'Stop IIS object before rollback.'}; $collection.Remove($object); $m.CommitChanges()}}finally{$m.Dispose()}
}
