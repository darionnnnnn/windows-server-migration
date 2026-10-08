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
    foreach($attribute in $Node.Attributes){if($attribute.Name -eq 'xmlns'){continue}; $target=$Element.Attributes[$attribute.Name]; if(-not $target){throw ('Target IIS schema has no attribute '+$attribute.Name)};$value=$attribute.Value;if($null -ne $target.Value -and $target.Value -isnot [string]){if($target.Value -is [TimeSpan]){$value=[TimeSpan]::Parse($attribute.Value,[Globalization.CultureInfo]::InvariantCulture)}else{$value=[Convert]::ChangeType($attribute.Value,$target.Value.GetType(),[Globalization.CultureInfo]::InvariantCulture)}}; $Element.SetAttributeValue($attribute.Name,$value)}
    foreach($child in $Node.ChildNodes){if($child.NodeType -ne [Xml.XmlNodeType]::Element){continue}; if($child.LocalName -eq 'add' -or $child.LocalName -eq 'application' -or $child.LocalName -eq 'virtualDirectory' -or $child.LocalName -eq 'binding'){$collection=$Element.GetCollection(); $new=$collection.CreateElement($child.LocalName); Set-WsmIisXmlElement $new $child; $collection.Add($new)}else{$target=$Element.GetChildElement($child.LocalName); Set-WsmIisXmlElement $target $child}}
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
function Test-WsmIisXmlElement($Element,$Node,[switch]$Root) {
    foreach($a in $Node.Attributes){if($a.Name -in @('xmlns','id','serverAutoStart','autoStart','startMode')){continue};$actual=$Element.GetAttributeValue($a.Name);$expected=$a.Value;if($null -ne $actual -and $actual -isnot [string]){if($actual -is [TimeSpan]){$expected=[TimeSpan]::Parse($a.Value,[Globalization.CultureInfo]::InvariantCulture)}else{$expected=[Convert]::ChangeType($a.Value,$actual.GetType(),[Globalization.CultureInfo]::InvariantCulture)}}; if(-not [object]::Equals($actual,$expected)){'IIS attribute mismatch: '+$Node.LocalName+'/'+$a.Name}}
    foreach($child in $Node.ChildNodes){if($child.NodeType -ne [Xml.XmlNodeType]::Element){continue}; if($child.LocalName -in @('add','application','virtualDirectory','binding')){$collection=$Element.GetCollection(); $key=''; foreach($name in @('name','path','bindingInformation')){if($child.HasAttribute($name)){$key=$name;break}}; $matching=@($collection | Where-Object { $_.ElementTagName -ceq $child.LocalName -and (!$key -or [string]$_.GetAttributeValue($key) -ceq $child.GetAttribute($key)) }); if($matching.Count -ne 1){'IIS collection element missing/ambiguous: '+$child.LocalName}else{Test-WsmIisXmlElement $matching[0] $child}}else{Test-WsmIisXmlElement ($Element.GetChildElement($child.LocalName)) $child}}
}
function Test-WsmIisConfiguration($Spec,[string]$Phase) {
    $m=New-WsmIisManager
    try{$object=$m.Sites[$Spec.Desired.Name]; if($Spec.Adapter -eq 'IISPool'){$object=$m.ApplicationPools[$Spec.Desired.Name]}; if(-not $object){return 'IIS object absent'}; $xml=Read-WsmXml $Spec.Desired.Xml; Test-WsmIisXmlElement $object $xml.DocumentElement;if($Spec.Adapter -eq 'IISSite'){Test-WsmIisBindings $object $Spec.Desired}; if($Phase -eq 'Staged' -and [string]$object.State -ne 'Stopped'){'IIS object must remain stopped'}; if($Phase -eq 'Staged' -and $Spec.Adapter -eq 'IISPool' -and $object.AutoStart){'IIS pool AutoStart must remain false'}; if($Phase -eq 'Staged' -and $Spec.Adapter -eq 'IISSite' -and $object.ServerAutoStart){'IIS site ServerAutoStart must remain false'};if($Phase -eq 'Final'){$active=Get-WsmDesiredActivation $Spec;$expected='Stopped';if($active){$expected='Started'};if([string]$object.State -ne $expected){'IIS final running state mismatch'};if($Spec.Adapter -eq 'IISPool'){$expectedMode='OnDemand';if($active -and $xml.DocumentElement.HasAttribute('startMode')){$expectedMode=$xml.DocumentElement.GetAttribute('startMode')};if([string]$object.StartMode -ine $expectedMode){'IIS final startMode mismatch'}};if($Spec.Adapter -eq 'IISPool' -and $object.AutoStart -ne $active){'IIS final AutoStart mismatch'};if($Spec.Adapter -eq 'IISSite' -and $object.ServerAutoStart -ne $active){'IIS final ServerAutoStart mismatch'}}}finally{$m.Dispose()}
}
function Test-WsmIisBindings($Object,$Desired) {
    foreach($expected in $Desired.Bindings){$found=@($Object.Bindings | Where-Object {$_.Protocol -ieq $expected.Protocol -and $_.BindingInformation -ceq $expected.BindingInformation});if($found.Count -ne 1){'IIS binding missing/ambiguous';continue};if($expected.Protocol -ieq 'https'){$actual=[BitConverter]::ToString($found[0].CertificateHash).Replace('-','');if($actual -ine $expected.CertificateHash -or $found[0].CertificateStoreName -ine $expected.CertificateStoreName -or [int]$found[0].SslFlags -ne [int]$expected.SslFlags){'IIS HTTPS certificate/store/flags mismatch'}}}
    if(@($Object.Bindings).Count -ne @($Desired.Bindings).Count){'Unexpected IIS binding'}
}
function Remove-WsmIisObject($Spec) {
    $m=New-WsmIisManager
    try{$collection=$m.Sites; if($Spec.Adapter -eq 'IISPool'){$collection=$m.ApplicationPools}; $object=$collection[$Spec.Desired.Name]; if($object){if([string]$object.State -ne 'Stopped'){throw 'Stop IIS object before rollback.'}; $collection.Remove($object); $m.CommitChanges()}}finally{$m.Dispose()}
}
