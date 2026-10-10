function Get-WsmWorkloadPathChannel([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){return 'Unknown'}
    $expanded=[Environment]::ExpandEnvironmentVariables($Path)
    if($expanded -match '%[^%]+%'){return 'Unknown'}
    if($expanded -match '^(?i:C:\\)'){return 'SuggestedC'}
    if($expanded -match '^(?i:[D-Z]:\\)'){return 'SuggestedNonC'}
    'Unknown'
}

function Get-WsmSafeWorkloadPathProjection([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){return $false}
    if($Path -match '(?i)(password|passwd|secret|token|credential|api[_-]?key)'){return $false}
    return ($Path -match '^(?:(?i:[a-z]:\\|\\\\|%[A-Za-z_][A-Za-z0-9_]*%\\))')
}

function Get-WsmWorkloadSettingValue($Settings,[string]$Name) {
    if($null -eq $Settings){return $null}
    if($Settings -is [System.Collections.IDictionary]){if($Settings.Contains($Name)){return $Settings[$Name]};return $null}
    if($Settings.PSObject.Properties[$Name]){return $Settings.$Name}
    return $null
}

function Join-WsmWorkloadMappedPath([string]$Root,[string]$Relative) {
    if(-not $Relative){return $Root}
    $clean=$Relative.Replace('/','\').TrimStart('\')
    $Root.TrimEnd('\')+'\'+$clean
}

function Get-WsmWorkloadPathCandidatesFromText([string]$Text) {
    # Only return unambiguous quoted absolute path arguments. Most task arguments
    # are intentionally opaque and require owner review.
    $found=New-Object 'System.Collections.Generic.List[string]'
    if([string]::IsNullOrWhiteSpace($Text)){return @()}
    foreach($match in [regex]::Matches($Text,'"(?<path>(?:[A-Za-z]:\\|\\\\)[^"\r\n]+)"')){
        $value=[string]$match.Groups['path'].Value
        if([IO.Path]::GetExtension($value) -match '^(?i:\.(?:exe|com|bat|cmd|ps1|psm1|vbs|js|wsf|py|dll))$'){$found.Add($value)}
    }
    @($found.ToArray() | Select-Object -Unique)
}

function Get-WsmTaskFolderInventoryItems([string]$HostId) {
    $items=New-Object 'System.Collections.Generic.List[object]'
    try {
        $service=New-Object -ComObject 'Schedule.Service';$service.Connect();$root=$service.GetFolder('\')
        $walk=$null;$walk={param($folder)
            $name=[string]$folder.Path;$status='Success';$security=$null;$securityStatus='Unknown'
            try{$security=[string]$folder.GetSecurityDescriptor(0xF);$securityStatus='Captured'}catch{$securityStatus='PermissionDenied';$status='Partial'}
            $settings=@{Path=$name;SecuritySddl=$security;SecurityCaptureStatus=$securityStatus;RawEvidenceProtected=$true}
            $items.Add((New-WsmItem $HostId Tasks TaskFolder $name $name $settings @() $status))
            foreach($child in @($folder.GetFolders(0))){& $walk $child}
        }
        & $walk $root
    } catch {
        $status='Failed';if($_.Exception -is [UnauthorizedAccessException] -or $_.FullyQualifiedErrorId -match 'Unauthorized|PermissionDenied'){$status='PermissionDenied'}
        $items.Add((New-WsmItem $HostId Tasks CollectorFailure 'Task folder/security enumeration failed' 'task-folder-enumeration' @{ErrorType=$_.Exception.GetType().FullName} @() $status))
    }
    @($items.ToArray())
}

function Get-WsmWorkloadPathReferences($Item) {
    $references=New-Object 'System.Collections.Generic.List[object]'
    $xmlText=[string](Get-WsmWorkloadSettingValue $Item.Settings 'Xml')
    if(-not $xmlText){return @()}
    try{$doc=Read-WsmXml $xmlText}catch{return @([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer='';ReferenceKind='XmlPath';RawValue='';ResolvedPath='';Channel='Unknown';ParseConfidence='Unknown';Opaque=$true;ReviewRequired=$true;Reason='XML parse failed; preserve raw XML and review manually.'})}
    if($Item.Kind -in @('IISSite','IISGlobalConfig','IISSectionConfig','IISLocationConfig')){
        foreach($node in @($doc.SelectNodes("//*[@configSource]"))){$path=[string]$node.GetAttribute('configSource');$safe=Get-WsmSafeWorkloadPathProjection $path;$pointer='IIS/'+[string]$Item.NaturalKey+'/'+$node.LocalName+'/@configSource';$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=$pointer;ReferenceKind='IISConfigSource';RawValue=$(if($safe){$path}else{'[configSource withheld for safe projection]'});ResolvedPath=$(if($safe){$path}else{''});Channel=$(if($safe){Get-WsmWorkloadPathChannel $path}else{'Unknown'});ParseConfidence=$(if($safe){'Typed'}else{'Unknown'});Opaque=(-not $safe);Required=[bool]$safe;ReviewRequired=(-not $safe);Reason=$(if($safe){''}else{'configSource value requires manual review from protected source XML.'})})}
    }
    if($Item.Kind -eq 'IISSite'){
        $siteName=[string]$Item.NaturalKey
        $nodes=@($doc.SelectNodes("//*[local-name()='virtualDirectory'][@physicalPath]"))
        foreach($node in $nodes){
            $path=[string]$node.GetAttribute('physicalPath');$app=$node.ParentNode
            $applications=@($doc.SelectNodes("//*[local-name()='application']"));$appIndex=[Array]::IndexOf($applications,$app);$virtualDirectories=@($app.SelectNodes("./*[local-name()='virtualDirectory'][@physicalPath]"));$vdirIndex=[Array]::IndexOf($virtualDirectories,$node)
            $pointer="IIS/site/$siteName/application[$appIndex]/virtualDirectory[$vdirIndex]/@physicalPath"
            $safe=Get-WsmSafeWorkloadPathProjection $path;$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=$pointer;ReferenceKind='IISPhysicalPath';RawValue=$(if($safe){$path}else{'[path withheld for safe projection]'});ResolvedPath=$(if($safe){$path}else{''});Channel=$(if($safe){Get-WsmWorkloadPathChannel $path}else{'Unknown'});ParseConfidence=$(if($safe){'Typed'}else{'Unknown'});Opaque=(-not $safe);ReviewRequired=(-not $safe);Reason=$(if($safe){''}else{'Path value failed safe projection; review protected raw source XML manually.'})})
        }
    } elseif($Item.Kind -eq 'ScheduledTask') {
        $actions=@($doc.SelectNodes("//*[local-name()='Actions']/*"));$actionIndex=0
        foreach($action in $actions){
            if($action.LocalName -ne 'Exec'){$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=('Task/Actions/Action['+$actionIndex+']');ReferenceKind='TaskAction';RawValue='';ResolvedPath='';Channel='Unknown';ParseConfidence='Unknown';Opaque=$true;ReviewRequired=$true;Reason=('Unsupported action type '+$action.LocalName+'; preserve XML and review manually.')});$actionIndex++;continue}
            foreach($fieldName in @('Command','WorkingDirectory')){
                $node=$action.SelectSingleNode("./*[local-name()='$fieldName']");if(-not $node){continue}
                $value=[string]$node.InnerText;$pointer=('Task/Actions/Action['+$actionIndex+']/'+$fieldName);$safe=Get-WsmSafeWorkloadPathProjection $value
                $references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=$pointer;ReferenceKind=('Task'+$fieldName);RawValue=$(if($safe){$value}else{'[command/path withheld for safe projection]'});ResolvedPath=$(if($safe){$value}else{''});Channel=$(if($safe){Get-WsmWorkloadPathChannel $value}else{'Unknown'});ParseConfidence=$(if($safe){'Typed'}else{'Unknown'});Opaque=(-not $safe);ReviewRequired=(-not $safe);Reason=$(if($safe){''}else{'Command or working directory is not a safely projected absolute path; review protected raw task XML manually.'})})
            }
            $argsNode=$action.SelectSingleNode("./*[local-name()='Arguments']")
            if($argsNode){
                $argText=[string]$argsNode.InnerText;$paths=@(Get-WsmWorkloadPathCandidatesFromText $argText)
                if($paths.Count){foreach($path in $paths){$safe=Get-WsmSafeWorkloadPathProjection $path;$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=('Task/Actions/Action['+$actionIndex+']/Arguments/QuotedPath');ReferenceKind='TaskArgumentPath';RawValue=$(if($safe){$path}else{'[argument path withheld for safe projection]'});ResolvedPath=$(if($safe){$path}else{''});Channel=$(if($safe){Get-WsmWorkloadPathChannel $path}else{'Unknown'});ParseConfidence=$(if($safe){'QuotedAbsolutePathCandidate'}else{'Unknown'});Opaque=(-not $safe);Required=$false;ReviewRequired=$true;Reason='Parsed quoted absolute path candidate; argument semantics still require owner review.'})}}
                else{$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=('Task/Actions/Action['+$actionIndex+']/Arguments');ReferenceKind='TaskArguments';RawValue='[opaque arguments withheld]';ValueHash=(Get-WsmHashText $argText);ResolvedPath='';Channel='Unknown';ParseConfidence='Opaque';Opaque=$true;ReviewRequired=$true;Reason='Arguments were not confidently parsed; review manually from protected source XML.'})}
            }
            $actionIndex++
        }
    }
    @($references.ToArray())
}

function Get-WsmWorkloadDiscovery($Inventory) {
    $references=New-Object 'System.Collections.Generic.List[object]';$coverage=New-Object 'System.Collections.Generic.List[object]';$resources=New-Object 'System.Collections.Generic.List[object]';$runtimeRows=New-Object 'System.Collections.Generic.List[object]';$provenanceRows=New-Object 'System.Collections.Generic.List[object]'
    $items=@($Inventory.Items);$candidateByPath=@{};$poolByName=@{};$taskFolderByPath=@{};foreach($item in $items){if($item.Kind -eq 'PathCandidate'){$path=[string](Get-WsmWorkloadSettingValue $item.Settings 'OriginalPath');if($path){$candidateByPath[$path.ToLowerInvariant()]=$item}};if($item.Kind -eq 'IISPool'){$poolByName[[string]$item.NaturalKey]=$item};if($item.Kind -eq 'TaskFolder'){$taskFolderByPath[[string]$item.NaturalKey]=$item}}
    foreach($item in $items){
        if($item.Kind -in @('IISSite','ScheduledTask')){
            foreach($reference in @(Get-WsmWorkloadPathReferences $item)){
                $candidate=$null;$key=([string]$reference.ResolvedPath).ToLowerInvariant();if($key -and $candidateByPath.ContainsKey($key)){$candidate=$candidateByPath[$key]}
                $reference | Add-Member NoteProperty ResourceItemId $(if($candidate){[string]$candidate.ItemId}else{''}) -Force
                $reference | Add-Member NoteProperty Required ([bool](-not $reference.Opaque -and $reference.ParseConfidence -eq 'Typed')) -Force
                $references.Add($reference)
            }
            if($item.Kind -eq 'IISSite'){
                try{$doc=Read-WsmXml ([string]$item.Settings.Xml);foreach($app in @($doc.SelectNodes("//*[local-name()='application'][@applicationPool]"))){$poolName=[string]$app.GetAttribute('applicationPool');$pool=$null;if($poolByName.ContainsKey($poolName)){$pool=$poolByName[$poolName]};$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$item.ItemId;ResourceItemId=$(if($pool){[string]$pool.ItemId}else{''});FieldPointer=('IIS/site/'+[string]$item.NaturalKey+'/application/'+[string]$app.GetAttribute('path')+'/@applicationPool');ReferenceKind='IISApplicationPool';RawValue=$poolName;ResolvedPath='';Channel='NotApplicable';ParseConfidence='Typed';Opaque=$false;Required=[bool]$pool;ReviewRequired=(-not [bool]$pool);Reason=$(if($pool){''}else{'Referenced application pool was not present in captured pool collection.'})})}}catch{}
            }
            if($item.Kind -eq 'ScheduledTask'){$taskPath=[string]$item.Settings.TaskPath;$folder=$null;if($taskFolderByPath.ContainsKey($taskPath)){$folder=$taskFolderByPath[$taskPath]};$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$item.ItemId;ResourceItemId=$(if($folder){[string]$folder.ItemId}else{''});FieldPointer=('Task/@TaskPath:'+ $taskPath);ReferenceKind='TaskFolderSecurity';RawValue=$taskPath;ResolvedPath='';Channel='NotApplicable';ParseConfidence='Typed';Opaque=$false;Required=[bool]$folder;ReviewRequired=(-not [bool]$folder);Reason=$(if($folder){''}else{'Task folder security resource was not captured.'})})}
        }
    }
    foreach($item in $items){
        if($item.Kind -eq 'ScheduledTask'){
            $xml=Read-WsmXml ([string]$item.Settings.Xml);$enabledNode=$xml.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");$enabled='Unknown';if($enabledNode){if($enabledNode.InnerText -ceq 'true'){$enabled='Enabled'}elseif($enabledNode.InnerText -ceq 'false'){$enabled='Disabled'}}
            $runtime='NotObserved';$runtimeReason='Task runtime state was not collected.';$observed=Get-WsmWorkloadSettingValue $item.Settings 'ObservedRuntime';if($observed){if($observed.PSObject.Properties['State']){$runtime=[string]$observed.State};if($observed.PSObject.Properties['Evidence']){$runtimeReason=[string]$observed.Evidence}}
            $item | Add-Member NoteProperty StartupConfiguration ([pscustomobject][ordered]@{Enabled=$enabled;SourceAutoStart=$enabled;Evidence='Task XML Settings/Enabled'}) -Force
            $item | Add-Member NoteProperty ObservedRuntime ([pscustomobject][ordered]@{State=$runtime;Evidence=$runtimeReason}) -Force
            $runtimeRows.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;WorkloadKind='ScheduledTask';StartupConfiguration=[pscustomobject][ordered]@{Enabled=$enabled;SourceAutoStart=$enabled;Evidence='Task XML Settings/Enabled'};ObservedRuntime=[pscustomobject][ordered]@{State=$runtime;Evidence=$runtimeReason};RuntimeAndStartupAreSeparate=$true})
            if($item.NaturalKey.StartsWith('\Microsoft\',[StringComparison]::OrdinalIgnoreCase)){
                $item | Add-Member NoteProperty ProducerProvenance 'MicrosoftNamespaceCandidate' -Force
                $item | Add-Member NoteProperty CustomizationStatus 'Unknown' -Force
                $item | Add-Member NoteProperty BuiltIn 'Unknown' -Force
            } else {$item | Add-Member NoteProperty ProducerProvenance 'Unknown' -Force;$item | Add-Member NoteProperty CustomizationStatus 'Unknown' -Force}
            $provenanceRows.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;ProducerProvenance=[string]$item.ProducerProvenance;CustomizationStatus='Unknown';OSProvidedStatus='Unknown';Evidence='Namespace prefix is only a candidate and does not prove OS ownership or lack of customization.'})
        } elseif($item.Kind -in @('IISSite','IISPool')){
            $startup='Unknown';$field='serverAutoStart';if($item.Kind -eq 'IISPool'){$field='autoStart'};try{$xml=Read-WsmXml ([string](Get-WsmWorkloadSettingValue $item.Settings 'Xml'));$root=$xml.DocumentElement;if($root -and $root.Attributes[$field]){$startup=[string]$root.GetAttribute($field)}}catch{}
            $observed=Get-WsmWorkloadSettingValue $item.Settings 'ObservedRuntime';$runtimeState='NotObserved';$runtimeEvidence='IIS runtime state was not observed.';if($observed){if($observed.PSObject.Properties['State']){$runtimeState=[string]$observed.State};if($observed.PSObject.Properties['Evidence']){$runtimeEvidence=[string]$observed.Evidence}}
            $startupRecord=[pscustomobject][ordered]@{Enabled=$startup;SourceAutoStart=$startup;Evidence=('IIS '+$field+' explicit value; omitted values remain Unknown.')};$runtimeRecord=[pscustomobject][ordered]@{State=$runtimeState;Evidence=$runtimeEvidence}
            $item | Add-Member NoteProperty StartupConfiguration $startupRecord -Force
            $item | Add-Member NoteProperty ObservedRuntime $runtimeRecord -Force
            $runtimeRows.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;WorkloadKind=[string]$item.Kind;StartupConfiguration=$startupRecord;ObservedRuntime=$runtimeRecord;RuntimeAndStartupAreSeparate=$true})
            $item | Add-Member NoteProperty ProducerProvenance 'Unknown' -Force;$item | Add-Member NoteProperty CustomizationStatus 'Unknown' -Force
            $provenanceRows.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;ProducerProvenance='Unknown';CustomizationStatus='Unknown';OSProvidedStatus='Unknown';Evidence='IIS object/provider ownership and customization baseline are not proved by local configuration capture.'})
        }
        elseif($item.Kind -in @('TaskFolder','IISGlobalConfig','IISSectionConfig','IISLocationConfig')){$provenanceRows.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;ProducerProvenance='Unknown';CustomizationStatus='Unknown';OSProvidedStatus='Unknown';Evidence='Producer and customization status require source/target definition comparison.'})}
    }
    $n=0;foreach($reference in $references){$n++;$reference | Add-Member NoteProperty ReferenceId (Get-WsmHashText ([string]$Inventory.Source.HostId+'|workload-reference|'+$reference.ConsumerItemId+'|'+$reference.FieldPointer+'|'+$n)) -Force}
    foreach($group in @($references.ToArray() | Where-Object ResourceItemId | Group-Object ResourceItemId)){
        $consumers=@($group.Group | ForEach-Object ConsumerItemId | Select-Object -Unique);$resource=$items | Where-Object ItemId -CEQ $group.Name | Select-Object -First 1
        $resources.Add([pscustomobject][ordered]@{ResourceItemId=$group.Name;ResourceKind=$(if($resource){[string]$resource.Kind}else{'Unknown'});ConsumerItemIds=$consumers;ConsumerCount=$consumers.Count;References=@($group.Group | ForEach-Object ReferenceId);SelectedConsumerImpact='Requires catalog decision review'})
    }
    $workloadItems=@($items | Where-Object { $_.Kind -in @('IISSite','IISPool','IISGlobalConfig','IISSectionConfig','IISLocationConfig','ScheduledTask','TaskFolder') -or ($_.Category -in @('Web','Tasks') -and $_.Kind -in @('DiscoveryGap','CollectorFailure','UnsupportedCollector')) })
    foreach($item in $workloadItems){if($item.Status -in @('Failed','PermissionDenied','Unsupported','Partial') -or $item.Kind -in @('IISGlobalConfig','IISSectionConfig','IISLocationConfig','TaskFolder','DiscoveryGap','CollectorFailure','UnsupportedCollector')){$coverage.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Category=[string]$item.Category;Kind=[string]$item.Kind;Status=[string]$item.Status;Completeness='ReviewRequired';Reason='Raw evidence retained; confirm access, inheritance, provider and completeness.'})}}
    [pscustomobject][ordered]@{SchemaVersion=1;Kind='WorkloadDiscovery';SourceHostId=[string]$Inventory.Source.HostId;InventoryRevision=[int]$Inventory.Revision;References=@($references.ToArray());SharedResources=@($resources.ToArray());RuntimeObservations=@($runtimeRows.ToArray());ProducerProvenance=@($provenanceRows.ToArray());Coverage=@($coverage.ToArray());Complete=$false;CompletenessReason='Discovery evidence is not proof of full dependency coverage; dynamic, protected, inherited and unsupported configuration requires owner review.'}
}

function Resolve-WsmWorkloadReferenceMapping($Catalog,$Reference) {
    $value=[string]$Reference.ResolvedPath;if(-not $value -or $Reference.Opaque){return [pscustomobject]@{Status='ReviewRequired';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='Opaque or unresolved source reference.';FileScopeItemId=''}}
    $matches=New-Object 'System.Collections.Generic.List[object]'
    $normalized=$value.Replace('/','\').TrimEnd('\');$matchingValue=$null;try{$matchingValue=ConvertTo-WsmCanonicalPath $normalized}catch{}
    foreach($item in @($Catalog.Items)){
        if($item.Decision -cne 'Include' -or -not $item.PSObject.Properties['MigrationSpec'] -or $item.MigrationSpec.Adapter -cne 'FileScope'){continue}
        if(-not $item.PSObject.Properties['ReviewedBy'] -or -not $item.ReviewedBy -or -not $item.PSObject.Properties['ReviewedUtc'] -or -not $item.ReviewedUtc){continue}
        if($Catalog.PSObject.Properties['Assistive'] -and $Catalog.Assistive.Selections){$selected=@($Catalog.Assistive.Selections.Items | Where-Object {$_.ItemId -ceq $item.ItemId -and $_.Selected});if($selected.Count -ne 1){continue}}
        $spec=$item.MigrationSpec
        $root=[string]$spec.SourcePath;if(-not $root){continue};$root=$root.Replace('/','\').TrimEnd('\');$candidate=$normalized
        if($matchingValue){try{$candidate=ConvertTo-WsmCanonicalPath $matchingValue}catch{}}
        if($candidate -ine $root -and -not $candidate.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
        if(-not $spec.TargetPath){continue}
        $relative='';if($candidate.Length -gt $root.Length){$relative=$candidate.Substring($root.Length).TrimStart('\')}
        $matches.Add([pscustomobject]@{Item=$item;Relative=$relative})
    }
    if($matches.Count -eq 1){$m=$matches[0];$target=Join-WsmWorkloadMappedPath ([string]$m.Item.MigrationSpec.TargetPath) ([string]$m.Relative);return [pscustomobject]@{Status='Mapped';OldRawValue=[string]$Reference.RawValue;TargetValue=$target;Reason='Unique approved FileScope source-root containment match; relative path preserved.';FileScopeItemId=[string]$m.Item.ItemId}}
    if($matches.Count -gt 1){return [pscustomobject]@{Status='ReviewRequired';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='Multiple approved FileScope maps match; owner must resolve ambiguity.';FileScopeItemId=''}}
    [pscustomobject]@{Status='Unmapped';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='No exact approved FileScope map matches this source path; broad/nearest-root substitution is not automatic.';FileScopeItemId=''}
}

function Get-WsmWorkloadSharedConsumerImpact($Catalog,[string]$ConsumerItemId) {
    if(-not $Catalog.PSObject.Properties['WorkloadDiscovery'] -or -not $Catalog.WorkloadDiscovery){return @()}
    $result=New-Object 'System.Collections.Generic.List[object]';$refs=@($Catalog.WorkloadDiscovery.References | Where-Object {$_.ConsumerItemId -ceq $ConsumerItemId -and $_.ResourceItemId});$selectionIndex=@{}
    if($Catalog.PSObject.Properties['Assistive'] -and $Catalog.Assistive.Selections){foreach($selection in @($Catalog.Assistive.Selections.Items)){$selectionIndex[[string]$selection.ItemId]=[bool]$selection.Selected}}
    foreach($resourceId in @($refs | ForEach-Object ResourceItemId | Select-Object -Unique)){
        $resource=$Catalog.WorkloadDiscovery.SharedResources | Where-Object ResourceItemId -CEQ $resourceId | Select-Object -First 1;if(-not $resource){continue}
        $selected=New-Object 'System.Collections.Generic.List[string]';$unselected=New-Object 'System.Collections.Generic.List[string]';$unknown=New-Object 'System.Collections.Generic.List[string]'
        foreach($id in @($resource.ConsumerItemIds)){
            if($selectionIndex.ContainsKey([string]$id)){if($selectionIndex[[string]$id]){$selected.Add([string]$id)}else{$unselected.Add([string]$id)}}
            else{$item=@($Catalog.Items | Where-Object ItemId -CEQ $id | Select-Object -First 1);if($item.Count -and $item[0].Decision -ceq 'Include'){$selected.Add([string]$id)}elseif($item.Count -and $item[0].Decision -ceq 'Exclude'){$unselected.Add([string]$id)}else{$unknown.Add([string]$id)}}
        }
        $result.Add([pscustomobject][ordered]@{ResourceItemId=[string]$resourceId;ResourceKind=[string]$resource.ResourceKind;ConsumerItemIds=@($resource.ConsumerItemIds);SelectedConsumerItemIds=@($selected.ToArray());UnselectedConsumerItemIds=@($unselected.ToArray());UnknownConsumerItemIds=@($unknown.ToArray());RequiresSharedReview=([bool]($unselected.Count -or $unknown.Count));OwnerReviewReason=$(if($unselected.Count -or $unknown.Count){'Shared resource has excluded or undecided consumers; review effects before applying this workload.'}else{''})})
    }
    @($result.ToArray())
}

function Get-WsmWorkloadXmlDraft($Item,$Catalog) {
    $xmlText=[string]$Item.Settings.Xml;$doc=Read-WsmXml $xmlText;$rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($reference in @(Get-WsmWorkloadPathReferences $Item)){
        $map=Resolve-WsmWorkloadReferenceMapping $Catalog $reference;$target=$map.TargetValue;$applied=$false
        if($map.Status -eq 'Mapped'){
            if($reference.ReferenceKind -eq 'IISPhysicalPath'){
                $pointer=[string]$reference.FieldPointer;$node=$null;if($pointer -match '/application\[(\d+)\]/virtualDirectory\[(\d+)\]/@physicalPath$'){$appIndex=[int]$matches[1];$vdirIndex=[int]$matches[2];$applications=@($doc.SelectNodes("//*[local-name()='application']"));if($appIndex -lt $applications.Count){$vdirs=@($applications[$appIndex].SelectNodes("./*[local-name()='virtualDirectory'][@physicalPath]"));if($vdirIndex -lt $vdirs.Count){$node=$vdirs[$vdirIndex]}}}
                if($node){$node.SetAttribute('physicalPath',$target);$applied=$true}
            } elseif($reference.ReferenceKind -in @('TaskCommand','TaskWorkingDirectory')){
                if($reference.FieldPointer -match 'Action\[(\d+)\]/(Command|WorkingDirectory)'){$idx=[int]$matches[1];$field=$matches[2];$actions=@($doc.SelectNodes("//*[local-name()='Actions']/*[local-name()='Exec']"));if($idx -lt $actions.Count){$node=$actions[$idx].SelectSingleNode("./*[local-name()='$field']");if($node){$node.InnerText=$target;$applied=$true}}}
            }
        }
        if($reference.ReferenceKind -eq 'TaskArguments' -and $reference.Opaque -and [string]$reference.FieldPointer -match 'Action\[(\d+)\]/Arguments'){$idx=[int]$matches[1];$actions=@($doc.SelectNodes("//*[local-name()='Actions']/*[local-name()='Exec']"));if($idx -lt $actions.Count){$argsNode=$actions[$idx].SelectSingleNode("./*[local-name()='Arguments']");if($argsNode){$argsNode.InnerText='[OPAQUE_ARGUMENTS_REDACTED_REVIEW_PROTECTED_SOURCE]'}};$target='[opaque arguments withheld; use protected source evidence after owner review]'}
        $rows.Add([pscustomobject][ordered]@{FieldPointer=[string]$reference.FieldPointer;ReferenceKind=[string]$reference.ReferenceKind;OldRawValue=[string]$map.OldRawValue;TargetValue=[string]$target;Applied=$applied;Status=$(if($applied){'MappedForReview'}else{$map.Status});ReviewRequired=([bool]$reference.ReviewRequired -or -not $applied);Reason=$(if($applied){'Typed draft XML path changed using exact approved FileScope mapping; review and normal approval still required.'}elseif($reference.ReferenceKind -eq 'TaskArguments' -and $reference.Opaque){'Opaque arguments are redacted from target draft; owner must restore reviewed values from protected source XML.'}else{$map.Reason})})
    }
    $sourceAutoStart='Unknown';$activationPointer=''
    if($Item.Kind -eq 'ScheduledTask'){$node=$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");if($node){if($node.InnerText -ceq 'true'){$sourceAutoStart='true'}elseif($node.InnerText -ceq 'false'){$sourceAutoStart='false'}}else{$settingsNode=$doc.SelectSingleNode("//*[local-name()='Settings']");if($settingsNode){$node=$doc.CreateElement('Enabled',$settingsNode.NamespaceURI);[void]$settingsNode.AppendChild($node)}};if($node){$node.InnerText='false'};$activationPointer='Task/Settings/Enabled'}
    elseif($Item.Kind -eq 'IISSite'){$node=$doc.DocumentElement;if($node){if($node.Attributes['serverAutoStart']){$sourceAutoStart=[string]$node.GetAttribute('serverAutoStart')};$node.SetAttribute('serverAutoStart','false');$activationPointer='IIS/site/@serverAutoStart'}}
    elseif($Item.Kind -eq 'IISPool'){$node=$doc.DocumentElement;if($node){if($node.Attributes['autoStart']){$sourceAutoStart=[string]$node.GetAttribute('autoStart')};$node.SetAttribute('autoStart','false');$activationPointer='IIS/applicationPool/@autoStart'}}
    [pscustomobject][ordered]@{TargetXml=$doc.OuterXml;OriginalXml=$xmlText;WorkloadMappingReview=@($rows.ToArray());DraftOnly=$true;SourceAutoStart=$sourceAutoStart;StagedDisabled=$true;ActivationPolicyFieldPointer=$activationPointer;SourceRuntime=$(if($Item.PSObject.Properties['ObservedRuntime']){$Item.ObservedRuntime}else{[pscustomobject]@{State='NotObserved';Evidence='Runtime state unknown.'}})}
}
