function New-WsmIisManager {
    Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
    New-Object Microsoft.Web.Administration.ServerManager
}
function Get-WsmIisState($Spec) {
    $m=New-WsmIisManager
    try { $collection=$m.Sites; if($Spec.Adapter -eq 'IISPool'){$collection=$m.ApplicationPools}; $object=$collection[$Spec.Desired.Name]; if(-not $object){return [pscustomobject]@{Exists=$false}}; [pscustomobject]@{Exists=$true; State=[string]$object.State; Configuration=(Get-WsmIisElementSnapshot $object)} } finally{$m.Dispose()}
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
