function Get-WsmAssistiveReviewItem([string]$Workspace,[string]$PairId,[string]$ItemId) {
    $catalog=Get-WsmCatalog $Workspace $PairId
    if(-not $catalog.PSObject.Properties['Assistive']){throw 'Enable Assistive mode before reviewing a specification.'}
    $rows=@($catalog.Items | Where-Object ItemId -CEQ $ItemId)
    if($rows.Count -ne 1){throw 'Unknown ItemId.'}
    $item=$rows[0]
    $selection=@($catalog.Assistive.Selections.Items | Where-Object ItemId -CEQ $ItemId)
    if($selection.Count -ne 1){throw 'Assistive selection is missing or ambiguous.'}
    if($item.PSObject.Properties['MigrationSpec']){$spec=$item.MigrationSpec}else{$spec=Get-WsmMigrationSpecDraft $item $catalog}
    [pscustomobject]@{Catalog=$catalog;Item=$item;Selection=$selection[0];Spec=$spec}
}

function ConvertTo-WsmAssistiveSafeValue($Value,[string]$Name='') {
    $sensitiveBoundary='(?i)(?:^|[^A-Za-z0-9])(?:secret|password|credential|token|privatekey|sddl|xml|arguments|script|command)(?:$|[^A-Za-z0-9])'
    $sensitiveCamel='(?:^|[a-z0-9])(?:Secret|Password|Credential|Token|PrivateKey|Sddl|Xml|Arguments|Script|Command)(?:$|[^A-Za-z0-9]|[A-Z])'
    if($Name -imatch $sensitiveBoundary -or $Name -cmatch $sensitiveCamel){return '[review required; value withheld]'}
    if($Value -is [string] -and $Value -match '(?i)(password|passwd|secret|token|credential|api[_-]?key)\s*[:=]\s*[^\s;]+'){return '[sensitive text withheld]'}
    if($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]){return $Value}
    if($Value -is [System.Collections.IDictionary]){$out=[ordered]@{};foreach($key in $Value.Keys){$out[[string]$key]=ConvertTo-WsmAssistiveSafeValue $Value[$key] ([string]$key)};return [pscustomobject]$out}
    if($Value -is [array]){return ,@($Value | ForEach-Object {ConvertTo-WsmAssistiveSafeValue $_ $Name})}
    if($Value.PSObject){$out=[ordered]@{};foreach($property in $Value.PSObject.Properties){if($property.MemberType -match 'NoteProperty|Property'){if($property.Name -notmatch '(?i)(secret|password|credential|token|privatekey|sddl|xml|arguments|script|command)'){$out[$property.Name]=ConvertTo-WsmAssistiveSafeValue $property.Value $property.Name}}};return [pscustomobject]$out}
    '[opaque value withheld]'
}

function Get-WsmAssistiveSafeIisChanges($Changes) {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($change in @($Changes)){
        $keys=@(foreach($key in @($change.KeyAttributes)){[pscustomobject][ordered]@{Name=[string]$key.Name;Value='[withheld]'}})
        $pointer=[string]$change.FieldPointer -replace "(\[@[^=]+=')([^']*)('\])",'$1[withheld]$3'
        # Keep protected identity and source value read-only. A target value is
        # a human decision, so expose an empty editable placeholder.
        $rows.Add([pscustomobject][ordered]@{FieldPointer=$pointer;Operation=[string]$change.Operation;ElementName=[string]$change.ElementName;KeyAttributes=$keys;AttributeName=[string]$change.AttributeName;BeforeValue='[withheld]';AfterValue='';ValuesWithheld=$true})
    }
    $rows.ToArray()
}

function Get-WsmAssistiveSafeDesired($Spec) {
    if(-not $Spec.PSObject.Properties['Desired'] -or $null -eq $Spec.Desired){return $null}
    $source=$Spec.Desired;$out=[ordered]@{}
    $allowedByAdapter=@{
        Service=@('Description')
        SmbShare=@('Path','Description','EncryptData','DrainPolicy','DrainEvidence','Access')
        LocalUser=@('FullName','Description')
        LocalGroup=@('Description','Members')
        Certificate=@('ArtifactPath','ArtifactHash')
    }
    if($allowedByAdapter.ContainsKey([string]$Spec.Adapter)){
        foreach($name in $allowedByAdapter[[string]$Spec.Adapter]){
            if(-not $source.PSObject.Properties[$name]){continue}
            if($name -ceq 'Access'){
                $out.Access=@(foreach($ace in @($source.Access)){
                    if(-not $ace.PSObject.Properties['AccountName'] -or -not $ace.PSObject.Properties['AccessControlType'] -or -not $ace.PSObject.Properties['AccessRight']){continue}
                    [pscustomobject][ordered]@{AccountName=[string](ConvertTo-WsmAssistiveSafeValue ([string]$ace.AccountName) 'AccountName');AccessControlType=[string]$ace.AccessControlType;AccessRight=[string]$ace.AccessRight}
                });continue
            }
            if($name -ceq 'Members'){$out.Members=@(foreach($member in @($source.Members)){[string](ConvertTo-WsmAssistiveSafeValue ([string]$member) 'Members')});continue}
            $out[$name]=ConvertTo-WsmAssistiveSafeValue $source.$name $name
        }
    }
    if($Spec.Adapter -ceq 'Certificate' -and $source.PSObject.Properties['HasPrivateKey']){$out.HasPrivateKey=[bool]$source.HasPrivateKey}
    if($Spec.Adapter -ceq 'SmbShare' -and $source.PSObject.Properties['Name']){$out.Name=[string](ConvertTo-WsmAssistiveSafeValue ([string]$source.Name) 'Name')}
    if($Spec.Adapter -ceq 'LocalUser' -and $source.PSObject.Properties['Name']){$out.Name=[string](ConvertTo-WsmAssistiveSafeValue ([string]$source.Name) 'Name')}
    if($Spec.Adapter -ceq 'LocalGroup' -and $source.PSObject.Properties['Name']){$out.Name=[string](ConvertTo-WsmAssistiveSafeValue ([string]$source.Name) 'Name')}
    if($Spec.Adapter -ceq 'Service' -and $source.PSObject.Properties['Name']){$out.Name=[string](ConvertTo-WsmAssistiveSafeValue ([string]$source.Name) 'Name')}
    [pscustomobject]$out
}

function Get-WsmAssistiveSharedReviewReasons($Spec) {
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $impacts=@();if($Spec.PSObject.Properties['SharedResourceImpacts']){$impacts=@($Spec.SharedResourceImpacts)}
    foreach($impact in @($impacts | Where-Object RequiresSharedReview)){
        $owner='';$reason=[string]$impact.OwnerReviewReason
        if($reason -match '^Owner: ([^;]+); (.*)$'){$owner=$matches[1];$reason=$matches[2]}
        $rows.Add([pscustomobject][ordered]@{ResourceItemId=[string]$impact.ResourceItemId;ConsumerItemIds=@($impact.ConsumerItemIds);Owner=$owner;Reason=$reason})
    }
    $rows.ToArray()
}

function Get-WsmAssistiveSpecReview {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId)
    $context=Get-WsmAssistiveReviewItem $Workspace $PairId $ItemId;$spec=$context.Spec;$item=$context.Item;$catalog=$context.Catalog
    $typed=[ordered]@{}
    foreach($name in @('SourcePath','TargetPath','TransferChannel','ContentSelection','ExcludedRelativePaths','Consistency','Metadata','ConflictPolicy','ConfigFiles','ConfigOverrides','DesiredFinalState','BusinessChecks','Product','Procedure','Artifacts','CatchUpPolicy','SharedResourceImpacts')){if($spec.PSObject.Properties[$name]){$typed[$name]=ConvertTo-WsmAssistiveSafeValue $spec.$name $name}}
    if($spec.Adapter -ceq 'FileScope' -and $spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactMembers'){
        $typed.ExactMemberSummary=[pscustomobject][ordered]@{Count=@($spec.Members).Count;SetHash=(Get-WsmHashText (ConvertTo-Json -InputObject @($spec.Members) -Depth 8 -Compress));Selection='Fixed reviewed file set; new or neighboring files are not included.'}
    }
    if($spec.PSObject.Properties['ReviewedActivation']){foreach($name in @('Owner','Reason')){if($spec.ReviewedActivation.PSObject.Properties[$name]){$typed['Activation'+$name]=[string](ConvertTo-WsmAssistiveSafeValue ([string]$spec.ReviewedActivation.$name) ('Activation'+$name))}}}
    if($spec.Adapter -ceq 'FileScope'){$typed.AclControlPolicy='Exact';if($spec.PSObject.Properties['AclControlPolicy']){$typed.AclControlPolicy=[string]$spec.AclControlPolicy}}
    if($spec.PSObject.Properties['Desired']){$typed.Desired=Get-WsmAssistiveSafeDesired $spec}
    if($spec.PSObject.Properties['Desired'] -and $spec.Desired.PSObject.Properties['Changes']){$typed.IisConfigChanges=@(Get-WsmAssistiveSafeIisChanges $spec.Desired.Changes)}
    if($spec.PSObject.Properties['SecretRef']){$typed.SecretRef=[string]$spec.SecretRef}
    if($spec.PSObject.Properties['AccountMode']){$typed.AccountMode=[string]$spec.AccountMode}
    $missing=New-Object 'System.Collections.Generic.List[string]'
    foreach($field in @('Owner','Evidence')){if([string]::IsNullOrWhiteSpace([string]$spec.$field)){$missing.Add($field)}}
    $opaque=@();if($spec.PSObject.Properties['WorkloadMappingReview']){$opaque=@($spec.WorkloadMappingReview | Where-Object {$_.ReviewRequired -or -not $_.Applied} | ForEach-Object {[pscustomobject]@{FieldPointer=[string]$_.FieldPointer;ReferenceKind=[string]$_.ReferenceKind;Status=[string]$_.Status;ReviewRequired=$true;Reason=[string]$_.Reason}})}
    if($spec.Adapter -in @('ScheduledTask','IISSite','IISPool','IISSection','IISLocation')){if(-not $spec.PSObject.Properties['ReviewedActivation'] -or [string]::IsNullOrWhiteSpace([string]$spec.ReviewedActivation.Owner) -or [string]::IsNullOrWhiteSpace([string]$spec.ReviewedActivation.Reason)){$missing.Add('ActivationOwnerAndReason')};if(@($opaque).Count){$missing.Add('CompleteTypedWorkloadReviews')}}
    $sharedImpacts=@();if($spec.PSObject.Properties['SharedResourceImpacts']){$sharedImpacts=@($spec.SharedResourceImpacts)}
    $sharedReasons=@(Get-WsmAssistiveSharedReviewReasons $spec);if(@($sharedImpacts | Where-Object {$_.RequiresSharedReview -and [string]::IsNullOrWhiteSpace([string]$_.OwnerReviewReason)}).Count){$missing.Add('SharedResourceReviewReasons')}
    $sourceXml='';$targetXml='';if($spec.PSObject.Properties['SourceXml']){$sourceXml=Get-WsmHashText ([string]$spec.SourceXml)};if($spec.PSObject.Properties['Desired'] -and $spec.Desired.PSObject.Properties['Xml']){$targetXml=Get-WsmHashText ([string]$spec.Desired.Xml)}
    $pathRefs=@();if(Get-Command Get-WsmWorkloadPathReferences -ErrorAction SilentlyContinue){
        $mappingIndex=@{};if($spec.PSObject.Properties['WorkloadMappingReview']){foreach($mapping in @($spec.WorkloadMappingReview)){if($mapping.PSObject.Properties['FieldPointer']){$mappingIndex[[string]$mapping.FieldPointer]=$mapping}}}
        $pathRefs=@(foreach($reference in @(Get-WsmWorkloadPathReferences $item)){
            $safePath=$false;if(-not $reference.Opaque -and (Get-Command Get-WsmSafeWorkloadPathProjection -ErrorAction SilentlyContinue)){$safePath=[bool](Get-WsmSafeWorkloadPathProjection ([string]$reference.ResolvedPath))}
            $projection=[ordered]@{FieldPointer=[string]$reference.FieldPointer;ReferenceKind=[string]$reference.ReferenceKind;Channel=[string]$reference.Channel;ParseConfidence=[string]$reference.ParseConfidence;Opaque=[bool]$reference.Opaque;ReviewRequired=[bool]$reference.ReviewRequired;Reason=[string]$reference.Reason;SourcePath=$(if($safePath){[string]$reference.ResolvedPath}else{''});DraftTargetPath=''}
            if($mappingIndex.ContainsKey([string]$reference.FieldPointer)){$mapping=$mappingIndex[[string]$reference.FieldPointer];if($mapping.PSObject.Properties['Applied'] -and $mapping.Applied -and (Get-Command Get-WsmSafeWorkloadPathProjection -ErrorAction SilentlyContinue) -and (Get-WsmSafeWorkloadPathProjection ([string]$mapping.TargetValue))){$projection.DraftTargetPath=[string]$mapping.TargetValue}}
            [pscustomobject]$projection
        })
    }
    $workloadActions=@();$iisBindings=@();$iisApplications=@();$iisPoolSettings=$null
    if($spec.PSObject.Properties['SourceXml']){try{$doc=Read-WsmXml ([string]$spec.SourceXml)
        if($spec.Adapter -eq 'ScheduledTask'){$index=0;foreach($node in @($doc.SelectNodes("//*[local-name()='Actions']/*"))){$workloadActions+=@([pscustomobject]@{Index=$index;ActionType=[string]$node.LocalName;CommandPresent=[bool]$node.SelectSingleNode("./*[local-name()='Command']");ArgumentsPresent=[bool]$node.SelectSingleNode("./*[local-name()='Arguments']");WorkingDirectoryPresent=[bool]$node.SelectSingleNode("./*[local-name()='WorkingDirectory']");ValuesWithheld=$true});$index++}}
        elseif($spec.Adapter -eq 'IISSite'){$index=0;foreach($node in @($doc.SelectNodes("//*[local-name()='binding']"))){$protocol=[string]$node.GetAttribute('protocol');$manualProtocol=$protocol -notin @('http','https');$iisBindings+=@([pscustomobject]@{Index=$index;Protocol=$protocol;ManualReviewRequired=$manualProtocol;BindingInformation=[string]$node.GetAttribute('bindingInformation');CertificateHash=[string]$node.GetAttribute('certificateHash');CertificateStoreName=[string]$node.GetAttribute('certificateStoreName');SslFlags=[string]$node.GetAttribute('sslFlags');SslFlagsPresent=[bool]$node.HasAttribute('sslFlags')});if($manualProtocol){$missing.Add('ManualBindingProtocolReview['+$index+']')};$index++};$index=0;foreach($node in @($doc.SelectNodes("//*[local-name()='application']"))){$iisApplications+=@([pscustomobject]@{Index=$index;ApplicationPath=[string]$node.GetAttribute('path');PoolName=[string]$node.GetAttribute('applicationPool')});$index++}}
        elseif($spec.Adapter -eq 'IISPool'){$node=$doc.DocumentElement;$attributes=[ordered]@{};foreach($name in @('name','managedRuntimeVersion','managedPipelineMode','enable32BitAppOnWin64','startMode','queueLength','autoStart')){if($node -and $node.HasAttribute($name)){$attributes[$name]=$node.GetAttribute($name)}};$iisPoolSettings=[pscustomobject]$attributes}
    }catch{$missing.Add('ProtectedWorkloadSourceParse')}}
    # These are source-derived, bounded values rather than the withheld XML or
    # Desired.Changes projection. They are prefilled as an editable review draft;
    # the normal owner/evidence/revision checks still gate any submission.
    if($spec.Adapter -ceq 'IISSite'){
        if($iisBindings.Count){$typed.IisBindings=@(foreach($row in $iisBindings){[pscustomobject][ordered]@{Index=[int]$row.Index;Protocol=[string]$row.Protocol;BindingInformation=[string]$row.BindingInformation;CertificateHash=[string]$row.CertificateHash;CertificateStoreName=[string]$row.CertificateStoreName;SslFlags=[string]$row.SslFlags;SslFlagsPresent=[bool]$row.SslFlagsPresent}})}
        if($iisApplications.Count){$typed.IisApplicationPools=@(foreach($row in $iisApplications){[pscustomobject][ordered]@{Index=[int]$row.Index;ApplicationPath=[string]$row.ApplicationPath;PoolName=[string]$row.PoolName}})}
    }
    if($spec.PSObject.Properties['WorkloadMappingReview']){
        $editableReviews=@(foreach($mapping in @($spec.WorkloadMappingReview)){
            $pointer=[string]$mapping.FieldPointer
            $supportedPointer=$pointer -match '^Task/Actions/Action\[\d+\]/(Command|WorkingDirectory)$' -or $pointer -match '^IIS/site/[^\x00-\x1f]{1,256}/application\[\d+\]/virtualDirectory\[\d+\]/@physicalPath$'
            $reference=@($pathRefs | Where-Object FieldPointer -CEQ $pointer | Select-Object -First 1)
            if(-not $supportedPointer -or -not $reference.Count -or $reference[0].Opaque){continue}
            $value='';if($mapping.PSObject.Properties['Applied'] -and $mapping.Applied -and $reference[0].DraftTargetPath){$value=[string]$reference[0].DraftTargetPath}
            [pscustomobject][ordered]@{FieldPointer=$pointer;Value=$value}
        })
        if($editableReviews.Count){$typed.WorkloadFieldReviews=$editableReviews}
    }
    if($spec.Adapter -ceq 'IISPool' -and $iisPoolSettings){$poolFields=[ordered]@{};foreach($name in @('managedRuntimeVersion','managedPipelineMode','enable32BitAppOnWin64','startMode','queueLength')){if($iisPoolSettings.PSObject.Properties[$name]){$poolFields[$name]=ConvertTo-WsmAssistiveSafeValue $iisPoolSettings.$name $name}};$typed.IisPoolSettings=[pscustomobject]$poolFields}
    [pscustomobject][ordered]@{PairId=$PairId;ItemId=$ItemId;DecisionRevision=[int]$catalog.DecisionRevision;AssistiveRevision=[int]$catalog.Assistive.Revision;SelectionRevision=[int]$catalog.Assistive.Selections.Revision;Selected=[bool]$context.Selection.Selected;Adapter=[string]$spec.Adapter;Owner=[string](ConvertTo-WsmAssistiveSafeValue ([string]$spec.Owner) 'Owner');Evidence=[string](ConvertTo-WsmAssistiveSafeValue ([string]$spec.Evidence) 'Evidence');DesiredFinalState=[string](Get-WsmConfirmationValue $spec 'DesiredFinalState' '');TypedFields=[pscustomobject]$typed;MissingTypedFields=@($missing.ToArray() | Select-Object -Unique);SharedResourceReviewReasons=$sharedReasons;OpaqueReviewRequired=@($opaque);WorkloadActions=$workloadActions;IisBindings=$iisBindings;IisApplications=$iisApplications;IisPoolSettings=$iisPoolSettings;WorkloadPathReferences=$pathRefs;SourceXmlSHA256=$sourceXml;TargetXmlSHA256=$targetXml;RawXmlIncluded=$false;SecretsIncluded=$false}
}

function Set-WsmAssistiveReviewXmlValue($Document,[string]$Pointer,[string]$Value) {
    if($Pointer -match '^Task/Actions/Action\[(\d+)\]/(Command|Arguments|WorkingDirectory)$'){
        $index=[int]$matches[1];$field=[string]$matches[2];$actions=@($Document.SelectNodes("//*[local-name()='Actions']/*"));if($index -ge $actions.Count -or $actions[$index].LocalName -cne 'Exec'){throw 'Task action review does not match the source action topology.'}
        $node=$actions[$index].SelectSingleNode("./*[local-name()='$field']");if(-not $node){if($field -eq 'Arguments'){$node=$Document.CreateElement('Arguments',$actions[$index].NamespaceURI);[void]$actions[$index].AppendChild($node)}else{throw 'Required task action field is absent from the source.'}};$node.InnerText=$Value;return
    }
    if($Pointer -match '^Task/Principal/UserId$'){$node=$Document.SelectSingleNode("//*[local-name()='Principal']/*[local-name()='UserId']");if(-not $node){throw 'Task principal user field is absent.'};$node.InnerText=$Value;return}
    if($Pointer -match '^IIS/site/[^\x00-\x1f]{1,256}/application\[(\d+)\]/virtualDirectory\[(\d+)\]/@physicalPath$'){$apps=@($Document.SelectNodes("//*[local-name()='application']"));$ai=[int]$matches[1];$vi=[int]$matches[2];if($ai -ge $apps.Count){throw 'IIS virtual-directory review does not match source topology.'};$dirs=@($apps[$ai].SelectNodes("./*[local-name()='virtualDirectory'][@physicalPath]"));if($vi -ge $dirs.Count){throw 'IIS virtual-directory review does not match source topology.'};$dirs[$vi].SetAttribute('physicalPath',$Value);return}
    if($Pointer -match '^IIS/site/[^\x00-\x1f]{1,256}/@serverAutoStart$'){$node=$Document.SelectSingleNode("//*[local-name()='site']");if(-not $node){throw 'IIS site activation field is absent.'};$node.SetAttribute('serverAutoStart',$Value);return}
    throw 'Workload field pointer is outside the supported typed review grammar.'
}

function Get-WsmAssistiveIisSourceActivationValue($Document,[string]$Pointer) {
    $attribute=([string]$Pointer -split '/@')[-1]
    try{$resolved=Get-WsmIisPointerNode $Document $Pointer;$nodeAttribute=$resolved.Node.Attributes[$attribute]}catch{$nodeAttribute=$null}
    if(-not $nodeAttribute){return 'Unknown'}
    $value=[string]$nodeAttribute.Value
    if($value -match '^(?i:true|1|yes|AlwaysRunning)$'){return 'true'}
    if($value -match '^(?i:false|0|no|disabled|OnDemand|stopped)$'){return 'false'}
    'Unknown'
}

function Set-WsmAssistiveIisConfigReview($Spec,$Fields) {
    if($Spec.Adapter -notin @('IISSection','IISLocation')){return}
    if(-not $Spec.PSObject.Properties['SourceXml'] -or -not $Spec.PSObject.Properties['Desired'] -or -not $Spec.Desired.PSObject.Properties['SectionPath'] -or -not $Spec.Desired.PSObject.Properties['LocationPath']){throw 'Protected source XML and exact section/location identity are required for typed IIS review.'}
    $pointer=[string]$Fields['ActivationPolicyFieldPointer'];if(-not $pointer){$pointer=[string]$Spec.ActivationPolicyFieldPointer}
    if(-not $pointer -or $pointer -notmatch '^/[A-Za-z_][A-Za-z0-9_.:-]*(?:/[A-Za-z_][A-Za-z0-9_.:-]*(?:\[@[A-Za-z_][A-Za-z0-9_.:-]*=''[^'']{1,2048}''\])?)*(?:/@(?:enabled|autoStart|serverAutoStart|startMode))$'){throw 'IIS section/location review requires one supported activation policy field pointer.'}
    $fieldName='IisConfigChanges';if($Fields.Contains('DesiredChanges')){$fieldName='DesiredChanges'}elseif($Fields.Contains('IisConfigChanges')){$fieldName='IisConfigChanges'}
    $source=Read-WsmXml ([string]$Spec.SourceXml);$sourceAuto=Get-WsmAssistiveIisSourceActivationValue $source $pointer
    if($Fields.Contains($fieldName)){
        $submittedChanges=@($Fields[$fieldName])
        if(@($submittedChanges | Where-Object {$_.PSObject.Properties['ValuesWithheld'] -and $_.ValuesWithheld}).Count){
            $changes=@($Spec.Desired.Changes)
            if($submittedChanges.Count -ne $changes.Count){throw 'Protected IIS change rows do not match the current saved specification.'}
            for($i=0;$i -lt $changes.Count;$i++){if(-not $submittedChanges[$i].PSObject.Properties['AfterValue'] -or $submittedChanges[$i].AfterValue -isnot [string]){throw 'IIS target values must be explicit text decisions.'};$value=[string]$submittedChanges[$i].AfterValue;if(-not $value -and [string]$changes[$i].FieldPointer -ceq $pointer){$attribute=([string]$pointer -split '/@')[-1];$value='false';if($attribute -ceq 'startMode'){$value='OnDemand'}};if(-not $value){throw ('Provide the target value for '+[string]$changes[$i].FieldPointer+'.')};$changes[$i].AfterValue=$value}
        }else{$changes=$submittedChanges}
    }elseif($Spec.Desired.PSObject.Properties['Changes']){$changes=@($Spec.Desired.Changes)}else{$changes=@()}
    foreach($change in $changes){
        $required=@('FieldPointer','Operation','ElementName','KeyAttributes','AttributeName','BeforeValue','AfterValue')
        foreach($name in $required){if(-not $change.PSObject.Properties[$name]){throw ('Typed IIS config change is missing '+$name+'.')}}
        if($change.FieldPointer -isnot [string] -or $change.Operation -cnotin @('SetAttribute','AddElement','RemoveElement') -or $change.ElementName -isnot [string] -or $change.KeyAttributes -isnot [array]){throw 'Typed IIS config change row has an invalid pointer, operation, element, or key list.'}
        foreach($key in @($change.KeyAttributes)){if(-not $key.PSObject.Properties['Name'] -or -not $key.PSObject.Properties['Value'] -or [string]$key.Name -notmatch '^[A-Za-z_][A-Za-z0-9_.:-]*$' -or [string]::IsNullOrWhiteSpace([string]$key.Value)){throw 'Typed IIS config key attributes require exact name/value pairs.'}}
        foreach($name in @('AttributeName','BeforeValue','AfterValue')){if($change.$name -isnot [string]){throw ('Typed IIS config '+$name+' must be a string.')}}
        $pointerElement=((([string]$change.FieldPointer -replace '/@[^/]+$','') -split '/')[-1] -replace '\[@.*$','')
        if($change.Operation -ceq 'SetAttribute' -and (([string]$change.FieldPointer -split '/@')[-1] -cne [string]$change.AttributeName -or [string]$change.ElementName -cne $pointerElement)){throw 'SetAttribute row pointer, element, and attribute names must agree exactly.'}
        if($change.FieldPointer -match '(?i)(password|secret|token|credential|private[ _-]?key)\s*[=:\[]'){throw 'Secret-like IIS field pointers cannot be reviewed through this form.'}
    }
    $activationRows=@($changes | Where-Object {$_.FieldPointer -ceq $pointer})
    if($activationRows.Count -gt 1){throw 'IIS activation pointer must have exactly one normal Desired.Changes row.'}
    $attribute=([string]$pointer -split '/@')[-1];$disabled='false';if($attribute -ceq 'startMode'){$disabled='OnDemand'}
    if(-not $activationRows.Count){
        $resolved=$null;try{$resolved=Get-WsmIisPointerNode $source $pointer}catch{}
        if(-not $resolved -or -not $resolved.Node.Attributes[$attribute]){throw 'IIS activation policy attribute is absent; provide an explicitly typed supported field or use manual workflow.'}
        $change=[pscustomobject][ordered]@{FieldPointer=$pointer;Operation='SetAttribute';ElementName=[string]$resolved.Node.LocalName;KeyAttributes=@();AttributeName=$attribute;BeforeValue=[string]$resolved.Node.Attributes[$attribute].Value;AfterValue=$disabled}
        $changes+=@($change)
    }elseif($activationRows[0].Operation -cne 'SetAttribute' -or [string]$activationRows[0].AfterValue -cne $disabled){throw 'IIS activation policy change must be one typed SetAttribute row that stages the field disabled.'}
    $target=(Set-WsmIisConfigChanges $source $changes).OuterXml
    $targetDocument=Read-WsmXml $target;$targetResolved=Get-WsmIisPointerNode $targetDocument $pointer;$stagedValue=[string]$targetResolved.Node.Attributes[$attribute].Value
    $final='Disabled';if($Fields.Contains('DesiredFinalState')){$final=[string]$Fields.DesiredFinalState};if($final -notin @('Disabled','Enabled')){throw 'DesiredFinalState must be Disabled or Enabled.'}
    $finalValue=$disabled;if($final -ceq 'Enabled'){if($attribute -ceq 'startMode'){$finalValue='AlwaysRunning'}else{$finalValue='true'}}
    $activationOwner=[string]$Fields['ActivationOwner'];$activationReason=[string]$Fields['ActivationReason']
    if([string]::IsNullOrWhiteSpace($activationOwner) -or [string]::IsNullOrWhiteSpace($activationReason)){throw 'IIS activation review requires a separate owner and reason; staged configuration remains disabled.'}
    $Spec.SourceAutoStart=$sourceAuto;$Spec.ActivationPolicyFieldPointer=$pointer;$Spec.Desired.Changes=@($changes);$Spec.Desired.Xml=$target;$Spec.DesiredFinalState=$final;$Spec.StagedDisabled=$true
    $Spec.ReviewedActivation=[pscustomobject][ordered]@{FinalState=$final;Owner=$activationOwner;Reason=$activationReason;SourceAutoStart=$sourceAuto;FieldPointer=$pointer;StagedValue=$stagedValue;FinalValue=$finalValue}
}

function Get-WsmAssistivePublicCertificateArtifactHash($Spec) {
    if($Spec.Adapter -cne 'Certificate' -or $Spec.Desired.HasPrivateKey){throw 'Wizard preparation supports only a reviewed public-only certificate (.cer); private-key/PFX handling requires its separate credential workflow.'}
    $path=[string]$Spec.Desired.ArtifactPath
    if(-not $path -or [IO.Path]::GetExtension($path) -ine '.cer' -or -not [IO.File]::Exists($path)){throw 'Choose an existing public-only .cer artifact for the exact reviewed certificate.'}
    Assert-WsmNoReparse $path
    $file=Get-Item -LiteralPath $path -ErrorAction Stop
    if($file.Length -lt 64 -or $file.Length -gt 16777216){throw 'Public certificate artifact must be between 64 bytes and 16 MiB.'}
    [byte[]]$bytes=[IO.File]::ReadAllBytes($path)
    $certificate=$null
    try{$certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes);if($certificate.HasPrivateKey -or $certificate.Thumbprint -ine [string]$Spec.Desired.Thumbprint){throw 'The selected public certificate does not match the captured thumbprint or contains a private key.'}}
    finally{if($certificate){$certificate.Dispose()}}
    $sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

function Assert-WsmAssistiveReviewArtifactPath([string]$Workspace,[string]$PairId,[string]$ItemId) {
    $directory=Join-Path (Join-Path $Workspace 'assistive') 'review-forms'
    $fileName='spec-'+$PairId+'-'+$ItemId+'-'+('0'*32)+'.json'
    $artifactCandidate=Join-Path $directory $fileName
    $temporaryCandidate=Join-Path $directory (('0'*32)+'.tmp')
    $longest=[Math]::Max($artifactCandidate.Length,$temporaryCandidate.Length)
    if($longest -gt 240){throw ('The organizing workspace path is too long for a safe Windows PowerShell 5.1 review save (maximum safe path is 240 characters; staged review path would be '+$longest+'). Move the workspace to a shorter local path, then refresh the review.')}
    $artifact=[IO.Path]::GetFullPath($artifactCandidate);$temporary=[IO.Path]::GetFullPath($temporaryCandidate)
    [pscustomobject][ordered]@{ArtifactPath=$artifact;TemporaryPath=$temporary;MaximumLength=$longest;Limit=240}
}

function Submit-WsmAssistiveSpecReview {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,[Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][int]$ExpectedDecisionRevision,[Parameter(Mandatory)][int]$ExpectedAssistiveRevision,[Parameter(Mandatory)][int]$ExpectedSelectionRevision,
        [Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Fields,
        [string]$ReviewedTargetXmlPath,[string]$ReviewedTargetXmlHash)
    if([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Evidence)){throw 'Owner and evidence are required.'}
    $context=Get-WsmAssistiveReviewItem $Workspace $PairId $ItemId;$catalog=$context.Catalog;$spec=$context.Spec;$item=$context.Item
    $sourceChannel='';if($spec.PSObject.Properties['TransferChannel']){$sourceChannel=[string]$spec.TransferChannel}
    if($catalog.DecisionRevision -ne $ExpectedDecisionRevision -or $catalog.Assistive.Revision -ne $ExpectedAssistiveRevision -or $catalog.Assistive.Selections.Revision -ne $ExpectedSelectionRevision){throw 'Review changed; refresh the form before saving.'}
    if(-not $context.Selection.Selected){throw 'Assistive specifications can only be assigned to currently selected items.'}
    $allowed=@('TargetPath','TransferChannel','ContentSelection','ExcludedRelativePaths','Consistency','Metadata','ConflictPolicy','AclControlPolicy','ConfigFiles','ConfigOverrides','DesiredFinalState','BusinessChecks','Product','Procedure','Artifacts','CatchUpPolicy','WorkloadFieldReviews','IisBindings','IisApplicationPools','IisPoolSettings','IisConfigChanges','DesiredChanges','ActivationPolicyFieldPointer','SharedResourceReviewReasons','ActivationOwner','ActivationReason','PrincipalUser','Desired','SecretRef')
    if($Fields.Contains('IisConfigChanges') -and $Fields.Contains('DesiredChanges')){throw 'Supply one exact IIS Changes array, not both aliases.'}
    foreach($key in $Fields.Keys){if($allowed -cnotcontains [string]$key){throw ('Unknown typed review field: '+[string]$key)}}
    if($spec.Adapter -ceq 'FileScope' -and $spec.PSObject.Properties['ContentSelection'] -and $spec.ContentSelection -ceq 'ExactMembers' -and $Fields.Contains('ContentSelection') -and [string]$Fields['ContentSelection'] -cne 'ExactMembers'){throw 'A confirmed ExactMembers set cannot be widened or replaced through specification review; confirm a new source selection.'}
    if($Fields.Contains('AclControlPolicy') -and ($spec.Adapter -cne 'FileScope' -or $Fields['AclControlPolicy'] -isnot [string] -or [string]$Fields['AclControlPolicy'] -cnotin @('Exact','AllowAutoInheritedUpgrade'))){throw 'ACL control policy is limited to FileScope and must be explicitly reviewed as Exact or AllowAutoInheritedUpgrade.'}
    foreach($key in $Fields.Keys){$value=$Fields[$key];switch -CaseSensitive ([string]$key){
        'WorkloadFieldReviews' { }
        'IisBindings' { }
        'IisApplicationPools' { }
        'IisPoolSettings' { }
        'IisConfigChanges' { }
        'DesiredChanges' { }
        'ActivationPolicyFieldPointer' { }
        'SharedResourceReviewReasons' { }
        'ActivationOwner' { }
        'ActivationReason' { }
        'PrincipalUser' { }
        'Desired' { }
        'SecretRef' { }
        default {if($spec.PSObject.Properties[$key]){$spec.$key=$value}else{$spec | Add-Member NoteProperty $key $value}}
    }}
    if($Fields.Contains('SecretRef')){
        if($spec.Adapter -notin @('LocalUser','Certificate','Service') -or $Fields['SecretRef'] -isnot [string] -or ([string]$Fields['SecretRef'] -and [string]$Fields['SecretRef'] -notmatch '^[A-Za-z0-9_.-]{1,128}$')){throw 'SecretRef is a reference identifier only; passwords and credential values are never accepted.'}
        $spec.SecretRef=[string]$Fields['SecretRef']
    }
    if($spec.Adapter -ceq 'Service' -and $spec.PSObject.Properties['AccountMode'] -and [string]$spec.AccountMode -ceq 'UserPassword' -and (-not $spec.PSObject.Properties['SecretRef'] -or [string]::IsNullOrWhiteSpace([string]$spec.SecretRef))){throw 'A UserPassword service account requires a SecretRef identifier; credential values are never accepted here.'}
    if($Fields.Contains('Desired')){
        if($Fields['Desired'] -isnot [System.Collections.IDictionary] -and $null -eq $Fields['Desired'].PSObject){throw 'Typed Desired answers must be a structured value.'}
        $desired=$spec.Desired
        $editable=@{Service=@('Description');SmbShare=@('Path','Description','EncryptData','DrainPolicy','DrainEvidence','Access');LocalUser=@('FullName','Description');LocalGroup=@('Description','Members');Certificate=@('ArtifactPath','ArtifactHash')}
        if(-not $editable.ContainsKey([string]$spec.Adapter)){throw ('The '+[string]$spec.Adapter+' adapter has no plain-language Desired fields; use its supported review workflow.')}
        $submitted=$Fields['Desired'];$submittedProperties=@();if($submitted -is [System.Collections.IDictionary]){$submittedProperties=@(foreach($name in $submitted.Keys){[pscustomobject]@{Name=[string]$name;Value=$submitted[$name]}})}else{$submittedProperties=@(foreach($property in $submitted.PSObject.Properties){if($property.MemberType -match 'NoteProperty|Property'){[pscustomobject]@{Name=[string]$property.Name;Value=$property.Value}}})}
        foreach($submittedProperty in $submittedProperties){$fieldName=[string]$submittedProperty.Name;$original=$desired.PSObject.Properties[$fieldName]
            if($editable[[string]$spec.Adapter] -cnotcontains $fieldName){
                if(-not $original -or (ConvertTo-Json -InputObject $submittedProperty.Value -Depth 32 -Compress) -cne (ConvertTo-Json -InputObject $original.Value -Depth 32 -Compress)){throw ('Protected Desired identity or unsupported field cannot be changed: '+$fieldName)}
                continue
            }
            $value=$submittedProperty.Value
            switch($fieldName){
                'EncryptData' {if($value -isnot [bool]){throw 'EncryptData requires an explicit true/false decision.'};$desired.EncryptData=[bool]$value}
                'Access' {if($spec.Adapter -cne 'SmbShare' -or $value -isnot [array]){throw 'SMB access review must retain the captured typed row list.'};$old=@($desired.Access);if(@($value).Count -ne $old.Count){throw 'SMB access review cannot add or drop captured rows.'};for($i=0;$i -lt $old.Count;$i++){foreach($keyName in @('AccountName','AccessControlType','AccessRight')){if(-not $value[$i].PSObject.Properties[$keyName] -or $value[$i].$keyName -isnot [string]){throw 'SMB access rows require account, allow/deny and access right.'}};$old[$i].AccountName=[string]$value[$i].AccountName;$old[$i].AccessControlType=[string]$value[$i].AccessControlType;$old[$i].AccessRight=[string]$value[$i].AccessRight}}
                'Members' {if($value -isnot [array]){throw 'LocalGroup members must be reviewed as a list.'};$desired.Members=@($value|ForEach-Object {[string]$_})}
                default {if($value -isnot [string] -or $value.Length -gt 8192){throw ('Desired '+$fieldName+' must be bounded text.')};$desired.$fieldName=[string]$value}
            }
        }
        if($spec.Adapter -ceq 'Certificate'){
            $computedHash=Get-WsmAssistivePublicCertificateArtifactHash $spec
            if([string]$desired.ArtifactHash -and [string]$desired.ArtifactHash -ine $computedHash){throw 'The supplied certificate hash does not match the current public certificate bytes.'}
            $desired.ArtifactHash=$computedHash
        }
    }
    $spec.Owner=$Owner;$spec.Evidence=$Evidence
    if($spec.PSObject.Properties['SharedResourceImpacts'] -and (Get-Command Get-WsmWorkloadSharedConsumerImpact -ErrorAction SilentlyContinue)){
        $spec.SharedResourceImpacts=@(Get-WsmWorkloadSharedConsumerImpact $catalog ([string]$item.ItemId))
    }
    if($Fields.Contains('SharedResourceReviewReasons')){
        if(-not $spec.PSObject.Properties['SharedResourceImpacts']){throw 'Shared resource review is unavailable because discovery did not provide typed impacts.'}
        $requiredImpacts=@($spec.SharedResourceImpacts | Where-Object RequiresSharedReview);$reviewRows=@($Fields['SharedResourceReviewReasons']);$reviewed=@{}
        foreach($review in $reviewRows){
            if(-not $review.PSObject.Properties['ResourceItemId'] -or -not $review.PSObject.Properties['ConsumerItemIds'] -or -not $review.PSObject.Properties['Owner'] -or -not $review.PSObject.Properties['Reason']){throw 'Shared resource review requires ResourceItemId, ConsumerItemIds, Owner and Reason.'}
            $resourceId=[string]$review.ResourceItemId;if($reviewed.ContainsKey($resourceId)){throw 'Shared resource review has a duplicate ResourceItemId.'}
            $impact=@($requiredImpacts | Where-Object ResourceItemId -CEQ $resourceId);if($impact.Count -ne 1){throw 'Shared resource review ResourceItemId is not a current required impact.'}
            $expected=@($impact[0].ConsumerItemIds | Sort-Object -Unique);$actual=@($review.ConsumerItemIds | Sort-Object -Unique)
            if($review.ConsumerItemIds -isnot [array] -or ($actual -join '|') -cne ($expected -join '|') -or -not (@($impact[0].SelectedConsumerItemIds).Count -or @($impact[0].UnselectedConsumerItemIds).Count -or @($impact[0].UnknownConsumerItemIds).Count) -or -not [string]$review.Owner.Trim() -or -not [string]$review.Reason.Trim()){throw 'Shared resource review must bind the exact current discovery consumers and provide an owner and reason.'}
            $impact[0].OwnerReviewReason=('Owner: '+[string]$review.Owner.Trim()+'; '+[string]$review.Reason.Trim());$reviewed[$resourceId]=$true
        }
        if($reviewed.Count -ne $requiredImpacts.Count){throw 'A typed owner reason is required for every currently shared resource impact.'}
    }elseif($spec.PSObject.Properties['SharedResourceImpacts'] -and @($spec.SharedResourceImpacts | Where-Object {$_.RequiresSharedReview -and [string]::IsNullOrWhiteSpace([string]$_.OwnerReviewReason)}).Count){throw 'Shared resource impact requires an explicit owner review reason.'}
    if($spec.Adapter -eq 'FileScope'){
        $source=[string]$spec.SourcePath;if([string]$Fields['SourcePath'] -and [string]$Fields['SourcePath'] -cne $source){throw 'SourcePath is fixed to the reviewed discovery scope.'}
        if(-not $Fields.Contains('TargetPath')){throw 'FileScope review requires a target path.'}
        if([string]$spec.TransferChannel -notin @('C','NonC','External')){throw 'A reviewed source channel is required.'}
        if($Fields.Contains('TransferChannel') -and [string]$Fields['TransferChannel'] -cne $sourceChannel){throw 'Transfer channel is source-derived and cannot be changed by the review form.'}
    }
    if($spec.Adapter -in @('ScheduledTask','IISSite','IISPool')){
        if(-not $spec.PSObject.Properties['SourceXml'] -or -not $spec.Desired.PSObject.Properties['Xml']){throw 'Protected source workload XML is unavailable.'}
        if($ReviewedTargetXmlPath){
            if(-not $ReviewedTargetXmlHash){throw 'Trusted XML review requires an independently obtained SHA256.'}
            $snapshot=Read-WsmFileSnapshot $ReviewedTargetXmlPath $ReviewedTargetXmlHash;$targetXml=$snapshot.Text
        }else{
            $targetXml=[string]$spec.Desired.Xml;$seen=@{}
            if($Fields.Contains('WorkloadFieldReviews')){
                $seen=@{};$doc=Read-WsmXml $targetXml
                foreach($review in @($Fields['WorkloadFieldReviews'])){
                    if(-not $review.PSObject.Properties['FieldPointer'] -or -not $review.PSObject.Properties['Value'] -or [string]::IsNullOrWhiteSpace([string]$review.FieldPointer) -or $seen.ContainsKey([string]$review.FieldPointer)){throw 'Typed workload field reviews must have unique pointers and explicit values.'}
                    Set-WsmAssistiveReviewXmlValue $doc ([string]$review.FieldPointer) ([string]$review.Value);$seen[[string]$review.FieldPointer]=$true
                }
                $targetXml=$doc.OuterXml
            }
            if($spec.Adapter -eq 'IISSite' -and ($Fields.Contains('IisBindings') -or $Fields.Contains('IisApplicationPools'))){
                $doc=Read-WsmXml $targetXml
                if($Fields.Contains('IisBindings')){$nodes=@($doc.SelectNodes("//*[local-name()='binding']"));$rows=@($Fields['IisBindings']);if($rows.Count -ne $nodes.Count){throw 'IIS binding review must preserve and address every captured binding.'};$seenBindings=@{};foreach($row in $rows){$index=[int]$row.Index;if($index -lt 0 -or $index -ge $nodes.Count -or $seenBindings.ContainsKey([string]$index)){throw 'IIS binding review has an invalid or duplicate index.'};foreach($name in @('Protocol','BindingInformation','CertificateHash','CertificateStoreName','SslFlags')){if(-not $row.PSObject.Properties[$name]){throw ('IIS binding review is missing '+$name+'.')}};$binding=$nodes[$index];$sourceProtocol=[string]$binding.GetAttribute('protocol');if($sourceProtocol -notin @('http','https')){throw ('Captured IIS binding protocol requires manual review through a trusted reviewed XML artifact: '+$index)};$binding.SetAttribute('protocol',[string]$row.Protocol);$binding.SetAttribute('bindingInformation',[string]$row.BindingInformation);$binding.SetAttribute('certificateHash',[string]$row.CertificateHash);$binding.SetAttribute('certificateStoreName',[string]$row.CertificateStoreName);if($row.PSObject.Properties['SslFlagsPresent']){if([bool]$row.SslFlagsPresent){$binding.SetAttribute('sslFlags',[string]$row.SslFlags)}else{$binding.RemoveAttribute('sslFlags')}};$seenBindings[[string]$index]=$true}}
                if($Fields.Contains('IisApplicationPools')){$nodes=@($doc.SelectNodes("//*[local-name()='application']"));$rows=@($Fields['IisApplicationPools']);if($rows.Count -ne $nodes.Count){throw 'IIS application-pool review must address every captured application.'};$seenApps=@{};foreach($row in $rows){$index=[int]$row.Index;if($index -lt 0 -or $index -ge $nodes.Count -or $seenApps.ContainsKey([string]$index) -or -not $row.PSObject.Properties['ApplicationPath'] -or [string]$nodes[$index].GetAttribute('path') -cne [string]$row.ApplicationPath -or -not $row.PSObject.Properties['PoolName'] -or [string]::IsNullOrWhiteSpace([string]$row.PoolName)){throw 'IIS application-pool mapping must match each captured application path and provide a pool name.'};$nodes[$index].SetAttribute('applicationPool',[string]$row.PoolName);$seenApps[[string]$index]=$true}}
                $targetXml=$doc.OuterXml
            }
            if($spec.Adapter -eq 'IISPool' -and $Fields.Contains('IisPoolSettings')){$settings=$Fields['IisPoolSettings'];$allowedPool=@('managedRuntimeVersion','managedPipelineMode','enable32BitAppOnWin64','startMode','queueLength');$doc=Read-WsmXml $targetXml;$node=$doc.DocumentElement;foreach($name in $settings.Keys){if($allowedPool -cnotcontains [string]$name){throw ('Unsupported IIS pool setting: '+[string]$name)};$node.SetAttribute([string]$name,[string]$settings[$name])};$targetXml=$doc.OuterXml}
            $required=@($spec.WorkloadMappingReview | Where-Object {$_.ReviewRequired -or -not $_.Applied})
            foreach($row in $required){if(-not $seen.ContainsKey([string]$row.FieldPointer)){throw ('Complete typed review is required for '+[string]$row.FieldPointer+'. Supply WorkloadFieldReviews or a trusted advanced XML artifact.')}}
            foreach($row in @($spec.WorkloadMappingReview)){if($seen.ContainsKey([string]$row.FieldPointer)){$row.Applied=$true;$row.Status='ReviewedTyped';$row.ReviewRequired=$false;$row.Reason='Owner supplied a typed value for this exact field pointer.'}}
        }
        if($Fields.Contains('PrincipalUser')){if($spec.Adapter -ne 'ScheduledTask'){throw 'PrincipalUser applies only to scheduled tasks.'};if([string]::IsNullOrWhiteSpace([string]$Fields['PrincipalUser'])){throw 'PrincipalUser must be a non-empty reviewed account.'};$doc=Read-WsmXml $targetXml;Set-WsmAssistiveReviewXmlValue $doc 'Task/Principal/UserId' ([string]$Fields['PrincipalUser']);$targetXml=$doc.OuterXml;$spec.Desired.User=[string]$Fields['PrincipalUser'];$seen['Task/Principal/UserId']=$true}
        if($spec.Adapter -eq 'IISSite'){$sourceDoc=Read-WsmXml ([string]$spec.SourceXml);$bindingCount=@($sourceDoc.SelectNodes("//*[local-name()='binding']")).Count;$applicationCount=@($sourceDoc.SelectNodes("//*[local-name()='application']")).Count;if($bindingCount -gt 0 -and -not $Fields.Contains('IisBindings')){throw 'Typed IIS site review must address every captured binding.'};if($applicationCount -gt 0 -and -not $Fields.Contains('IisApplicationPools')){throw 'Typed IIS site review must address every captured application-pool mapping.'}}
        $spec.Desired.Xml=$targetXml;if($spec.Adapter -eq 'IISSite' -and $Fields.Contains('IisBindings')){$spec.Desired.Bindings=@($Fields['IisBindings'] | Select-Object Protocol,BindingInformation,CertificateHash,CertificateStoreName,SslFlags)};$spec.DesiredFinalState='Disabled';$spec.StagedDisabled=$true
        if($Fields.Contains('DesiredFinalState') -and [string]$Fields.DesiredFinalState -notin @('Disabled','Enabled')){throw 'DesiredFinalState must be Disabled or Enabled.'}
        $final='Disabled';if($Fields.Contains('DesiredFinalState')){$final=[string]$Fields.DesiredFinalState}
        $activationOwner=[string]$Fields['ActivationOwner'];$activationReason=[string]$Fields['ActivationReason']
        if([string]::IsNullOrWhiteSpace($activationOwner) -or [string]::IsNullOrWhiteSpace($activationReason)){throw 'Workload activation review requires a separate owner and reason; staging remains disabled until explicitly reviewed.'}
        $spec.DesiredFinalState=$final;$spec.ReviewedActivation=[pscustomobject][ordered]@{FinalState=$final;Owner=$activationOwner;Reason=$activationReason;SourceAutoStart=[string]$spec.SourceAutoStart;FieldPointer=[string]$spec.ActivationPolicyFieldPointer}
    }
    if($spec.Adapter -in @('IISSection','IISLocation')){Set-WsmAssistiveIisConfigReview $spec $Fields}
    Assert-WsmMigrationSpec $spec -Assistive
    $directory=Join-Path (Join-Path $Workspace 'assistive') 'review-forms'
    [void](Assert-WsmAssistiveReviewArtifactPath $Workspace $PairId $ItemId)
    if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory}
    $name=('spec-'+$PairId+'-'+$ItemId+'-'+[Guid]::NewGuid().ToString('N')+'.json');$path=Join-Path $directory $name
    Write-WsmJson $path $spec;$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    try{Set-WsmMigrationSpec -Workspace $Workspace -PairId $PairId -ItemId $ItemId -Path $path -ExpectedHash $hash -ExpectedRevision $ExpectedDecisionRevision}
    catch{[IO.File]::Delete($path);throw}
    [pscustomobject][ordered]@{PairId=$PairId;ItemId=$ItemId;Adapter=[string]$spec.Adapter;SpecPath=[IO.Path]::GetFullPath($path);SpecHash=$hash;DecisionRevision=($ExpectedDecisionRevision+1);AssistiveRevision=$(Get-WsmCatalog $Workspace $PairId).Assistive.Revision;ProtectedArtifact=$true;RawXmlReturned=$false}
}

function Export-WsmAssistiveTargetDecisionReceipt {
    [CmdletBinding()]param(
        [Parameter(Mandatory)][string]$Workspace,[Parameter(Mandatory)][string]$PairId,
        [Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$PlanHash,
        [Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$ManifestHash,
        [Parameter(Mandatory)][int]$Generation,[Parameter(Mandatory)][string]$TargetSnapshotHash,
        [Parameter(Mandatory)][int]$ComparisonRevision,[Parameter(Mandatory)][int]$SelectionRevision,
        [Parameter(Mandatory)][ValidateSet('WaitForInstall','RestoreNow')][string]$Decision,
        [Parameter(Mandatory)][string]$Owner,[Parameter(Mandatory)][string]$Reason,[Parameter(Mandatory)][string[]]$SelectedItemIds,
        [string[]]$AcceptedUnpreparedItemIds=@(),[Parameter(Mandatory)][int]$ExpectedDecisionRevision)
    if([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Reason)){throw 'Decision owner and reason are required.'}
    $package=Test-WsmMigrationPackage -ManifestPath $ManifestPath -ExpectedHash $ManifestHash
    $plan=Read-WsmMigrationPlan $PlanPath $PlanHash
    if($package.Manifest.PairId -cne $PairId -or $plan.PairId -cne $PairId -or $package.Manifest.PlanHash -ine $PlanHash -or $package.Manifest.Generation -ne $Generation -or -not $package.Manifest.Final){throw 'Receipt package is not the requested final generation of this sealed plan and pair.'}
    if($package.Manifest.PSObject.Properties['TargetSnapshotHash'] -and $package.Manifest.TargetSnapshotHash -and $package.Manifest.TargetSnapshotHash -ine $TargetSnapshotHash){throw 'Target snapshot binding differs from the final package.'}
    Invoke-WsmLocked $Workspace {
        $catalog=Get-WsmCatalog $Workspace $PairId
        if($catalog.DecisionRevision -ne $ExpectedDecisionRevision){throw 'Review changed; refresh before exporting a target receipt.'}
        if(-not $catalog.PSObject.Properties['Assistive'] -or -not $catalog.Assistive.Comparison){throw 'Publish a current comparison before exporting a target receipt.'}
        $currentSelection=Get-WsmAssistiveCurrentSelections $catalog;$sourceApproved=@{};foreach($id in @($plan.Assistive.ApprovedItemIds)){$sourceApproved[[string]$id]=$true}
        $currentSelected=@($currentSelection.Items | Where-Object {$_.Selected -and $sourceApproved.ContainsKey([string]$_.ItemId)} | ForEach-Object {[string]$_.ItemId} | Sort-Object -Unique)
        $requestedSeen=@{};foreach($id in $SelectedItemIds){if(-not $sourceApproved.ContainsKey([string]$id) -or $requestedSeen.ContainsKey([string]$id)){throw 'Target receipt selection is malformed, duplicated, or outside the sealed approved subset.'};$requestedSeen[[string]$id]=$true}
        $requestedSelected=@($requestedSeen.Keys | Sort-Object)
        if(($requestedSelected -join '|') -cne ($currentSelected -join '|')){throw 'Target receipt SelectedItemIds must exactly match the current target-side selection.'}
        $comparison=$catalog.Assistive.Comparison
        if($comparison.Revision -ne $ComparisonRevision -or $comparison.SelectionRevision -ne $SelectionRevision -or $SelectionRevision -ne $plan.Assistive.SourceSelectionsVersion -or $comparison.TargetSnapshotHash -ine $TargetSnapshotHash -or $comparison.TargetSnapshotHash -ine $catalog.Assistive.TargetCurrent.SHA256 -or $comparison.SourceSnapshotHash -ine $plan.Assistive.SourceSnapshotHash){throw 'Target comparison or source selection bindings are stale.'}
        if(-not $catalog.Approval -or -not $catalog.Approval.Hash -or $catalog.Approval.Hash -ine $PlanHash -or $catalog.Approval.ApprovalId -cne $plan.ApprovalId){throw 'The sealed plan is not the current approved catalog plan.'}
        $receipt=New-WsmAssistiveTargetDecisionReceipt -PlanPath $PlanPath -PlanHash $PlanHash -ManifestHash $ManifestHash -Generation $Generation -TargetSnapshotHash $TargetSnapshotHash -ComparisonRevision $ComparisonRevision -SelectionRevision $SelectionRevision -Decision $Decision -Owner $Owner -Reason $Reason -SelectedItemIds $SelectedItemIds -AcceptedUnpreparedItemIds $AcceptedUnpreparedItemIds -Comparison $catalog.Assistive.Comparison
        $directory=Join-Path (Join-Path $Workspace 'assistive') 'review-forms';if(-not [IO.Directory]::Exists($directory)){[void][IO.Directory]::CreateDirectory($directory);Protect-WsmDirectory $directory}
        $path=Join-Path $directory ('receipt-'+$PairId+'-'+$receipt.ReceiptId+'.json');Write-WsmJson $path $receipt;$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        [pscustomobject][ordered]@{PairId=$PairId;ReceiptId=$receipt.ReceiptId;Decision=$Decision;SelectedItemIds=@($receipt.SelectedItemIds);ReceiptPath=[IO.Path]::GetFullPath($path);ReceiptHash=$hash;ComparisonRevision=$ComparisonRevision;SelectionRevision=$SelectionRevision;Generation=$Generation;ProtectedArtifact=$true}
    }
}
