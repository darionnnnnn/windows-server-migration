function Get-WsmWorkloadPathChannel([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){return 'Unknown'}
    # This projection also runs on Manager/Target. Their environment is not
    # evidence of a Source task principal's or IIS worker's environment.
    if($Path -match '%[^%]+%'){return 'Unknown'}
    if($Path -match '^(?i:C:\\)'){return 'SuggestedC'}
    if($Path -match '^(?i:[ABD-Z]:\\)'){return 'SuggestedNonC'}
    'Unknown'
}

function Get-WsmSafeWorkloadPathProjection([string]$Path) {
    if([string]::IsNullOrWhiteSpace($Path)){return $false}
    if($Path -match '(?i)(password|passwd|secret|token|credential|api[_-]?key)'){return $false}
    return ($Path -match '^(?:(?i:[a-z]:\\|\\\\|%[A-Za-z_][A-Za-z0-9_]*%\\))')
}

function Test-WsmWorkloadLiteralAbsolutePath([string]$Path) {
    # Variables and relative segments require Source-context evidence; do not
    # resolve them using the machine displaying the inventory.
    return ((Get-WsmSafeWorkloadPathProjection $Path) -and $Path -notmatch '%[^%]+%' -and $Path -match '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))' -and $Path -notmatch '(^|[\\/])\.{1,2}([\\/]|$)')
}

function ConvertTo-WsmTaskFolderKey([string]$Path) {
    # 排程器 COM 的 Folder.Path 沒有結尾反斜線（\Fixture），排程的 TaskPath 有（\Fixture\）；兩者正規化成同一個鍵再比對。根目錄一律為 \。
    if([string]::IsNullOrWhiteSpace($Path)){return ''}
    $segments=@($Path -split '[\\/]+' | Where-Object {$_})
    if(-not $segments.Count){return '\'}
    '\'+($segments -join '\')+'\'
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
        # Data/config/output paths matter as much as executable/script paths.
        # Quotation is only candidate evidence, never proof of argument semantics.
        $found.Add($value)
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
    if($Item.Kind -in @('IISSite','IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig')){
        $nodes=@($doc.SelectNodes("//*[@configSource]"));$sourceRows=@();if($Item.Settings.PSObject.Properties['ConfigSource'] -and $Item.Settings.ConfigSource){$sourceRows=@($Item.Settings.ConfigSource)}elseif($Item.Settings.PSObject.Properties['ConfigSources']){$sourceRows=@($Item.Settings.ConfigSources)}
        foreach($node in $nodes){$path=[string]$node.GetAttribute('configSource');$row=@($sourceRows|Where-Object RelativePath -CEQ $path|Select-Object -First 1);$resolved='';$safe=$false;$reason='configSource has no validated resolved-file evidence.';if($row.Count -and $row[0].Status -ceq 'Captured' -and $row[0].ResolvedPath){$resolved=[string]$row[0].ResolvedPath;$safe=Test-WsmWorkloadLiteralAbsolutePath $resolved;if($safe){$reason=''}};$pointer='IIS/'+[string]$Item.NaturalKey+'/'+$node.LocalName+'/@configSource';$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=$pointer;ReferenceKind='IISConfigSource';RawValue=$(if($safe){$resolved}else{'[configSource withheld for safe projection]'});ResolvedPath=$(if($safe){$resolved}else{''});Channel=$(if($safe){Get-WsmWorkloadPathChannel $resolved}else{'Unknown'});ParseConfidence=$(if($safe){'ValidatedConfigSource'}else{'Unknown'});Opaque=(-not $safe);Required=[bool]$safe;ReviewRequired=(-not $safe);Reason=$(if($safe){''}else{$reason})})}
    }
    if($Item.Kind -eq 'IISSite'){
        $siteName=[string]$Item.NaturalKey
        $nodes=@($doc.SelectNodes("//*[local-name()='virtualDirectory'][@physicalPath]"))
        foreach($node in $nodes){
            $path=[string]$node.GetAttribute('physicalPath');$app=$node.ParentNode
            $applications=@($doc.SelectNodes("//*[local-name()='application']"));$appIndex=[Array]::IndexOf($applications,$app);$virtualDirectories=@($app.SelectNodes("./*[local-name()='virtualDirectory'][@physicalPath]"));$vdirIndex=[Array]::IndexOf($virtualDirectories,$node)
            $pointer="IIS/site/$siteName/application[$appIndex]/virtualDirectory[$vdirIndex]/@physicalPath"
            $safe=Test-WsmWorkloadLiteralAbsolutePath $path;$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=$pointer;ReferenceKind='IISPhysicalPath';RawValue=$(if($safe){$path}else{'[path withheld for safe projection]'});ResolvedPath=$(if($safe){$path}else{''});Channel=$(if($safe){Get-WsmWorkloadPathChannel $path}else{'Unknown'});ParseConfidence=$(if($safe){'Typed'}else{'Unknown'});Opaque=(-not $safe);ReviewRequired=(-not $safe);Reason=$(if($safe){''}else{'Path is unresolved or unsafe; Source environment/principal context must be reviewed from protected XML.'})})
        }
    } elseif($Item.Kind -eq 'ScheduledTask') {
        $actions=@($doc.SelectNodes("//*[local-name()='Actions']/*"));$actionIndex=0
        foreach($action in $actions){
            if($action.LocalName -ne 'Exec'){$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=('Task/Actions/Action['+$actionIndex+']');ReferenceKind='TaskAction';RawValue='';ResolvedPath='';Channel='Unknown';ParseConfidence='Unknown';Opaque=$true;ReviewRequired=$true;Reason=('Unsupported action type '+$action.LocalName+'; preserve XML and review manually.')});$actionIndex++;continue}
            foreach($fieldName in @('Command','WorkingDirectory')){
                $node=$action.SelectSingleNode("./*[local-name()='$fieldName']");if(-not $node){continue}
                $value=[string]$node.InnerText;$pointer=('Task/Actions/Action['+$actionIndex+']/'+$fieldName);$safe=Test-WsmWorkloadLiteralAbsolutePath $value
                $references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=$pointer;ReferenceKind=('Task'+$fieldName);RawValue=$(if($safe){$value}else{'[command/path withheld for safe projection]'});ResolvedPath=$(if($safe){$value}else{''});Channel=$(if($safe){Get-WsmWorkloadPathChannel $value}else{'Unknown'});ParseConfidence=$(if($safe){'Typed'}else{'Unknown'});Opaque=(-not $safe);ReviewRequired=(-not $safe);Reason=$(if($safe){''}else{'Command or working directory is not a safely projected absolute path; review protected raw task XML manually.'})})
            }
            if(-not $action.SelectSingleNode("./*[local-name()='WorkingDirectory']")){
                $references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=('Task/Actions/Action['+$actionIndex+']/WorkingDirectory');ReferenceKind='TaskWorkingDirectory';RawValue='';ResolvedPath='';Channel='Unknown';ParseConfidence='Unknown';Opaque=$true;Required=$false;ReviewRequired=$true;Reason='No explicit working directory was captured; relative command, argument and script dependencies require Source principal-context review.'})
            }
            $argsNode=$action.SelectSingleNode("./*[local-name()='Arguments']")
            if($argsNode){
                $argText=[string]$argsNode.InnerText;$paths=@(Get-WsmWorkloadPathCandidatesFromText $argText)
                if($paths.Count){foreach($path in $paths){$safe=Test-WsmWorkloadLiteralAbsolutePath $path;$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=('Task/Actions/Action['+$actionIndex+']/Arguments/QuotedPath');ReferenceKind='TaskArgumentPath';RawValue=$(if($safe){$path}else{'[argument path withheld for safe projection]'});ResolvedPath=$(if($safe){$path}else{''});Channel=$(if($safe){Get-WsmWorkloadPathChannel $path}else{'Unknown'});ParseConfidence=$(if($safe){'QuotedAbsolutePathCandidate'}else{'Unknown'});Opaque=(-not $safe);Required=$false;ReviewRequired=$true;Reason='Parsed quoted absolute path candidate; argument semantics still require owner review.'})}}
                if(-not [string]::IsNullOrWhiteSpace($argText)){$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$Item.ItemId;FieldPointer=('Task/Actions/Action['+$actionIndex+']/Arguments');ReferenceKind='TaskArguments';RawValue='[opaque arguments withheld]';ValueHash=(Get-WsmHashText $argText);ResolvedPath='';Channel='Unknown';ParseConfidence='Opaque';Opaque=$true;ReviewRequired=$true;Reason='Argument semantics and any relative, unquoted, environment-dependent or dynamic references remain unproved even when quoted path candidates were found; review protected source XML.'})}
            }
            $actionIndex++
        }
    }
    @($references.ToArray())
}

function Get-WsmIisSectionDefinitionIndex($Document) {
    $index=@{}
    $configSections=$Document.SelectSingleNode('/configuration/configSections')
    if(-not $configSections){return $index}
    $walk=$null;$walk={param($Parent,[string]$Prefix)
        foreach($node in @($Parent.ChildNodes | Where-Object NodeType -eq ([Xml.XmlNodeType]::Element))){
            if($node.LocalName -ceq 'sectionGroup'){$name=[string]$node.GetAttribute('name');if($name){$next=$name;if($Prefix){$next=$Prefix+'/'+$name};& $walk $node $next}}
            elseif($node.LocalName -ceq 'section'){$name=[string]$node.GetAttribute('name');if($name){$path=$name;if($Prefix){$path=$Prefix+'/'+$name};$index[$path]=[pscustomobject][ordered]@{SectionPath=$path;AllowDefinition=[string]$node.GetAttribute('allowDefinition');OverrideModeDefault=[string]$node.GetAttribute('overrideModeDefault');RequirePermission=[string]$node.GetAttribute('requirePermission');DeclarationXml=$node.OuterXml}}}
        }
    }
    & $walk $configSections ''
    $index
}

function Get-WsmIisConfigSourceEvidence($Node,[string]$ConfigurationPath) {
    if(-not $Node.Attributes['configSource']){return [pscustomobject][ordered]@{Status='NotPresent';RelativePath='';ResolvedPath='';SHA256='';ProtectedXml='';Reason=''}}
    $relative=[string]$Node.GetAttribute('configSource');$reason='';$resolved='';$hash='';$xml='';$status='ManualReviewRequired'
    try{
        if([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '^(?:\\|//)' -or $relative -match '(^|[\\/])\.\.(?:[\\/]|$)'){throw 'configSource must be a relative in-directory path.'}
        $base=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($ConfigurationPath));$resolved=[IO.Path]::GetFullPath((Join-Path $base $relative));$prefix=$base.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'configSource resolves outside the protected IIS configuration directory.'}
        if(-not [IO.File]::Exists($resolved)){throw 'configSource file is missing or inaccessible.'}
        Assert-WsmNoReparse $base;Assert-WsmNoReparse $resolved;$info=New-Object IO.FileInfo($resolved);if($info.Length -gt 4194304){throw 'configSource file exceeds the 4 MiB protected-evidence read budget.'}
        $bytes=[IO.File]::ReadAllBytes($resolved);if($bytes.Length -gt 4194304){throw 'configSource file exceeded the 4 MiB protected-evidence read budget during read.'};$hash=(Get-WsmHashBytes $bytes);$xml=[Text.Encoding]::UTF8.GetString($bytes);[void](Read-WsmXml $xml);$status='Captured'
    }catch{$reason=[string]$_.Exception.Message;$status='ManualReviewRequired'}
    [pscustomobject][ordered]@{Status=$status;RelativePath=$relative;ResolvedPath=$resolved;SHA256=$hash;ProtectedXml=$xml;Reason=$reason}
}

function Resolve-WsmIisConfigSourceCandidates([string]$HostId,[object[]]$Items,[object[]]$Candidates) {
    $result=New-Object 'System.Collections.Generic.List[object]';foreach($candidate in @($Candidates)){$result.Add($candidate)}
    foreach($owner in @($Items)){
        $sources=New-Object 'System.Collections.Generic.List[object]'
        if($owner.Settings.PSObject.Properties['ConfigSource'] -and $owner.Settings.ConfigSource){$sources.Add($owner.Settings.ConfigSource)}
        if($owner.Settings.PSObject.Properties['ConfigSources']){foreach($sourceRow in @($owner.Settings.ConfigSources)){$sources.Add($sourceRow)}}
        foreach($sourceRow in $sources){if($sourceRow.Status -cne 'Captured' -or -not $sourceRow.ResolvedPath){continue}
            $relative=[string]$sourceRow.RelativePath;$resolved=[string]$sourceRow.ResolvedPath
            $remove=@($result|Where-Object {$_.Settings.OriginalPath -ceq $relative});foreach($candidate in $remove){[void]$result.Remove($candidate)}
            $candidate=@($result|Where-Object {$_.Settings.OriginalPath -ceq $resolved}|Select-Object -First 1)
            if(-not $candidate.Count){$key=$resolved.ToLowerInvariant();$candidate=@(New-WsmItem $HostId Storage PathCandidate $resolved ('configsource-candidate:'+ $key) @{OriginalPath=$resolved;ResolvedCandidate=$resolved;RequiresScopeApproval=$true;Reason='Exact configSource file resolved relative to its protected parent configuration; content remains owner-reviewed.'} @() Success);$result.Add($candidate[0])}
            $owner.Dependencies=@(@($owner.Dependencies|Where-Object {$_.Evidence -cne 'Parsed configuration path; owner confirmation required'})+@([pscustomobject]@{ItemId=[string]$candidate[0].ItemId;Type='Mandatory';Evidence='Validated protected configSource file link';Confidence='Validated'}))
        }
    }
    @($result.ToArray())
}

function Get-WsmIisWebConfigInventoryItems([string]$HostId,[object[]]$SiteItems,[int]$MaxDirectories=4096,[int]$MaxFiles=8192,[long]$MaxBytes=67108864,[int]$MaxFileBytes=4194304) {
    # Capture only web.config files below physical roots explicitly present in
    # captured IIS XML. Reparse points are skipped and every limit is explicit.
    $items=New-Object 'System.Collections.Generic.List[object]';$seen=@{};$directories=0;$files=0;[long]$bytesRead=0
    foreach($site in @($SiteItems)){
        $siteId=[string]$site.ItemId;$siteName=[string]$site.NaturalKey
        try{$xml=Read-WsmXml ([string]$site.Settings.Xml)}catch{$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config roots unreadable for '+$siteName) ('webconfig-observation|'+$siteId+'|xml') ([pscustomobject][ordered]@{Status='SourceSiteXmlInvalid';PhysicalRoot='';PotentialConsumerItemIds=@($siteId);Reason='Captured IIS site XML could not be parsed; web.config coverage is incomplete.';RawEvidenceProtected=$true}) @() Partial));continue}
        $roots=@($xml.SelectNodes("//*[local-name()='virtualDirectory'][@physicalPath]")|ForEach-Object {[string]$_.GetAttribute('physicalPath')}|Select-Object -Unique)
        if(-not $roots.Count){$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config root unknown for '+$siteName) ('webconfig-observation|'+$siteId+'|root') ([pscustomobject][ordered]@{Status='NoPhysicalRoot';PhysicalRoot='';PotentialConsumerItemIds=@($siteId);Reason='No captured IIS physicalPath identifies a bounded web.config search root.';RawEvidenceProtected=$true}) @() Partial));continue}
        foreach($rawRoot in $roots){
            $root=[Environment]::ExpandEnvironmentVariables($rawRoot)
            if($root -match '%[^%]+%' -or $root -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+\\)'){$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config root requires resolution for '+$siteName) ('webconfig-observation|'+$siteId+'|'+(Get-WsmHashText $rawRoot)) ([pscustomobject][ordered]@{Status='UnresolvedPhysicalRoot';PhysicalRoot=$rawRoot;PotentialConsumerItemIds=@($siteId);Reason='Physical root is environment-dependent, relative, or outside safe absolute-path projection.';RawEvidenceProtected=$true}) @() Partial));continue}
            try{$root=ConvertTo-WsmCanonicalPath $root}catch{$root=''}
            if(-not $root -or -not [IO.Directory]::Exists($root)){$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config root unavailable for '+$siteName) ('webconfig-observation|'+$siteId+'|'+(Get-WsmHashText $rawRoot)) ([pscustomobject][ordered]@{Status='RootUnavailable';PhysicalRoot=$root;PotentialConsumerItemIds=@($siteId);Reason='Captured IIS physical root is missing or inaccessible; web.config could not be enumerated.';RawEvidenceProtected=$true}) @() Partial));continue}
            $stack=New-Object 'System.Collections.Generic.Stack[string]';$stack.Push($root);$rootFound=$false;$reparseSkipped=$false;$scanIncomplete=$false
            while($stack.Count -gt 0){
                if($directories -ge $MaxDirectories){$scanIncomplete=$true;$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config directory budget exceeded for '+$siteName) ('webconfig-observation|'+$siteId+'|budget-dir') ([pscustomobject][ordered]@{Status='DirectoryBudgetExceeded';PhysicalRoot=$root;PotentialConsumerItemIds=@($siteId);Reason=('Enumeration stopped at configured directory limit '+$MaxDirectories+'.');RawEvidenceProtected=$true}) @() Partial));break}
                $directory=$stack.Pop();$directories++
                try{$dirInfo=New-Object IO.DirectoryInfo($directory);if(($dirInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$reparseSkipped=$true;$scanIncomplete=$true;$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config reparse root skipped '+$directory) ('webconfig-observation|'+$siteId+'|reparse|'+(Get-WsmHashText $directory)) ([pscustomobject][ordered]@{Status='ReparsePointSkipped';PhysicalRoot=$root;Path=$directory;PotentialConsumerItemIds=@($siteId);Reason='IIS physical root is a reparse point; its contents were not followed.';RawEvidenceProtected=$true}) @() Partial));continue};$directoryLimitHit=$false;$directoryEnumerator=$dirInfo.EnumerateDirectories().GetEnumerator();while($directoryEnumerator.MoveNext()){$child=$directoryEnumerator.Current;if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){$reparseSkipped=$true;$scanIncomplete=$true;$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config reparse subtree skipped '+$child.FullName) ('webconfig-observation|'+$siteId+'|reparse|'+(Get-WsmHashText $child.FullName)) ([pscustomobject][ordered]@{Status='ReparsePointSkipped';PhysicalRoot=$root;Path=$child.FullName;PotentialConsumerItemIds=@($siteId);Reason='Nested IIS physical subtree is a reparse point; its contents were not followed.';RawEvidenceProtected=$true}) @() Partial));continue};if(($directories+$stack.Count) -ge $MaxDirectories){$directoryLimitHit=$true;break};$stack.Push($child.FullName)};if($directoryLimitHit){$scanIncomplete=$true;$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config directory budget exceeded for '+$siteName) ('webconfig-observation|'+$siteId+'|budget-dir') ([pscustomobject][ordered]@{Status='DirectoryBudgetExceeded';PhysicalRoot=$root;PotentialConsumerItemIds=@($siteId);Reason=('Child enumeration stopped at configured directory limit '+$MaxDirectories+'.');RawEvidenceProtected=$true}) @() Partial));break};$filePath=Join-Path $directory 'web.config';if(-not [IO.File]::Exists($filePath)){continue};$rootFound=$true
                    if($files -ge $MaxFiles){$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config file budget exceeded for '+$siteName) ('webconfig-observation|'+$siteId+'|budget-file') ([pscustomobject][ordered]@{Status='FileBudgetExceeded';PhysicalRoot=$root;PotentialConsumerItemIds=@($siteId);Reason=('Enumeration stopped at configured file limit '+$MaxFiles+'.');RawEvidenceProtected=$true}) @() Partial));break}
                    $canonical=ConvertTo-WsmCanonicalPath $filePath;Assert-WsmNoReparse $canonical;$key=$canonical.ToLowerInvariant();if($seen.ContainsKey($key)){$seen[$key].Settings.PotentialConsumerItemIds=@(@($seen[$key].Settings.PotentialConsumerItemIds)+@($siteId)|Select-Object -Unique);continue}
                    $files++;$fileInfo=New-Object IO.FileInfo($canonical);if($fileInfo.Length -gt $MaxFileBytes -or ($bytesRead+$fileInfo.Length) -gt $MaxBytes){$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config byte budget exceeded at '+$canonical) ('webconfig-observation|'+(Get-WsmHashText $key)) ([pscustomobject][ordered]@{Status=$(if($fileInfo.Length -gt $MaxFileBytes){'FileSizeBudgetExceeded'}else{'TotalByteBudgetExceeded'});PhysicalRoot=$root;Path=$canonical;PotentialConsumerItemIds=@($siteId);Reason='Protected web.config capture exceeded its explicit read budget; bytes were not read.';RawEvidenceProtected=$true}) @() Partial));continue}
                    try{$rawBytes=[IO.File]::ReadAllBytes($canonical);$bytesRead+=$rawBytes.Length;$hash=Get-WsmHashBytes $rawBytes;$xmlText=[Text.Encoding]::UTF8.GetString($rawBytes);$xmlStatus='Captured';$xmlReason='';try{$doc=Read-WsmXml $xmlText}catch{$doc=$null;$xmlStatus='MalformedXml';$xmlReason='Raw bytes/hash retained; XML parsing failed and manual review is required.'};$configSources=New-Object 'System.Collections.Generic.List[object]';if($doc){foreach($node in @($doc.SelectNodes('//*[@configSource]'))){$configSources.Add((Get-WsmIisConfigSourceEvidence $node $canonical))}};$settings=[pscustomobject][ordered]@{Xml=$xmlText;RawBytesBase64=[Convert]::ToBase64String($rawBytes);SHA256=$hash;Path=$canonical;PhysicalRoot=$root;SourceSiteName=$siteName;PotentialConsumerItemIds=@($siteId);CaptureStatus=$xmlStatus;CaptureReason=$xmlReason;ConfigSources=@($configSources.ToArray());RawEvidenceProtected=$true;CoverageDisposition='ManualReviewRequired';CoverageReason='web.config inheritance, applicability and target baseline require explicit owner review.'};$captured=New-WsmItem $HostId Web IISWebConfig ('web.config '+$canonical) ('webconfig|'+$key) $settings @() $(if($xmlStatus -eq 'Captured'){'Success'}else{'Partial'});$items.Add($captured);$seen[$key]=$captured
                    }catch{$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config read failed '+$canonical) ('webconfig-observation|'+(Get-WsmHashText $key)) ([pscustomobject][ordered]@{Status='ReadFailed';PhysicalRoot=$root;Path=$canonical;PotentialConsumerItemIds=@($siteId);Reason='web.config could not be read; coverage is incomplete.';ErrorType=$_.Exception.GetType().FullName;RawEvidenceProtected=$true}) @() PermissionDenied))}
                }catch{$scanIncomplete=$true;$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('web.config directory enumeration failed '+$directory) ('webconfig-observation|'+(Get-WsmHashText $directory)) ([pscustomobject][ordered]@{Status='DirectoryReadFailed';PhysicalRoot=$root;Path=$directory;PotentialConsumerItemIds=@($siteId);Reason='Captured IIS physical subtree could not be enumerated.';ErrorType=$_.Exception.GetType().FullName;RawEvidenceProtected=$true}) @() Partial))}
            }
            if(-not $rootFound -and -not $scanIncomplete -and -not $reparseSkipped){$items.Add((New-WsmItem $HostId Web IISWebConfigObservation ('no web.config observed under '+$root) ('webconfig-observation|'+$siteId+'|'+(Get-WsmHashText $root)) ([pscustomobject][ordered]@{Status='NoWebConfigObserved';PhysicalRoot=$root;PotentialConsumerItemIds=@($siteId);Reason='No web.config observed within the completely enumerated root.';RawEvidenceProtected=$true}) @() Success))}
        }
    }
    @($items.ToArray())
}

function Get-WsmIisConfigurationInventoryItems([string]$HostId,$Document,[string]$ConfigurationPath) {
    $items=New-Object 'System.Collections.Generic.List[object]';$definitions=Get-WsmIisSectionDefinitionIndex $Document
    $configurationHash=Get-WsmHashText ([string]$Document.OuterXml);$globalSettings=[pscustomobject][ordered]@{Xml=[string]$Document.OuterXml;ConfigurationFile=$ConfigurationPath;ConfigurationHash=$configurationHash;RawEvidenceProtected=$true;SectionDefinitionCount=$definitions.Count;Completeness='ReviewRequired'};$global=New-WsmItem $HostId Web IISGlobalConfig 'IIS global configuration' 'applicationHost.config' $globalSettings;$items.Add($global)
    $makeSection=$null;$makeSection={param($Node,[string]$SectionPath,[string]$LocationPath,[string]$Kind,[string]$Identity)
        $definition=$null;$known=$definitions.ContainsKey($SectionPath);if($known){$definition=$definitions[$SectionPath]}
        $configSource=Get-WsmIisConfigSourceEvidence $Node $ConfigurationPath
        $xpath='';if($LocationPath){$xpath='/configuration/location[@path='+$LocationPath+']/'+$SectionPath.Replace('/','/')}else{$xpath='/configuration/'+$SectionPath}
        $provenance='DeclaredSection';$coverage='TypedReviewCandidate';$reason='Exact section declaration and source XML were identified; this is not a resolved effective configuration or target baseline.'
        if(-not $known){$provenance='UndeclaredSection';$coverage='ManualReviewRequired';$reason='No exact configSections declaration proves this section identity; do not apply automatically.'}
        if($configSource.Status -ne 'NotPresent'){$coverage='ManualReviewRequired';$reason='configSource linkage must be reviewed as separate protected evidence; it is not silently dereferenced or restored.'}
        $featureState=@();foreach($attributeName in @('enabled','autoStart','serverAutoStart','startMode')){if($Node.Attributes[$attributeName]){$featureState+=@([pscustomobject][ordered]@{Name=$attributeName;Value=[string]$Node.GetAttribute($attributeName);Semantics='SectionFeatureOnly';SiteStartupMeaning='Unknown'})}}
        $settings=[ordered]@{Xml=[string]$Node.OuterXml;SourceXml=[string]$Node.OuterXml;ConfigurationFile=$ConfigurationPath;ConfigurationHash=$configurationHash;SectionPath=$SectionPath;LocationPath=$LocationPath;ParentGlobalConfigItemId=[string]$global.ItemId;DefinitionKnown=[bool]$known;DefinitionEvidence=$definition;ActualXPath=$xpath;ConfigSource=$configSource;ConfigurationFeatureState=@($featureState);RawEvidenceProtected=$true;CoverageDisposition=$coverage;CoverageReason=$reason;RequiredConsumerItemIds=@();EffectiveValueProven=$false;TargetBaselineProven=$false}
        $items.Add((New-WsmItem $HostId Web $Kind $Identity $Identity ([pscustomobject]$settings)))
    }
    $walk=$null;$walk={param($Node,[string]$Prefix,[string]$LocationPath,[string]$Kind)
        foreach($child in @($Node.ChildNodes | Where-Object NodeType -eq ([Xml.XmlNodeType]::Element))){
            $path=$child.LocalName;if($Prefix){$path=$Prefix+'/'+$child.LocalName}
            if($definitions.ContainsKey($path)){$identity=if($LocationPath){'location|'+$LocationPath+'|'+$path}else{'global|'+$path};& $makeSection $child $path $LocationPath $Kind $identity}
            elseif($definitions.Keys | Where-Object {$_.StartsWith($path+'/',[StringComparison]::OrdinalIgnoreCase)}){& $walk $child $path $LocationPath $Kind}
            elseif($Node.LocalName -ceq 'configuration' -or $Prefix){$identity=if($LocationPath){'location|'+$LocationPath+'|unknown|'+$path}else{'global|unknown|'+$path};& $makeSection $child $path $LocationPath $Kind $identity}
        }
    }
    $root=$Document.DocumentElement
    foreach($node in @($root.ChildNodes | Where-Object {$_.NodeType -eq [Xml.XmlNodeType]::Element -and $_.LocalName -cne 'configSections' -and $_.LocalName -cne 'location'})){
        $path=[string]$node.LocalName
        if($definitions.ContainsKey($path)){& $makeSection $node $path '' 'IISSectionConfig' ('global|'+$path)}
        elseif(@($definitions.Keys | Where-Object {$_.StartsWith($path+'/',[StringComparison]::OrdinalIgnoreCase)}).Count){& $walk $node $path '' 'IISSectionConfig'}
        else{& $makeSection $node $path '' 'IISSectionConfig' ('global|unknown|'+$path)}
    }
    foreach($location in @($Document.SelectNodes('/configuration/location'))){
        $locationPath=[string]$location.GetAttribute('path');$locationId='location|'+$locationPath
        $parentSettings=[pscustomobject][ordered]@{Xml=[string]$location.OuterXml;ConfigurationFile=$ConfigurationPath;ConfigurationHash=$configurationHash;LocationPath=$locationPath;ParentGlobalConfigItemId=[string]$global.ItemId;RawEvidenceProtected=$true;CoverageDisposition='ReviewRequired';CoverageReason='Location inheritance and effective precedence have not been proved.'}
        $items.Add((New-WsmItem $HostId Web IISLocationConfig ('IIS location '+$locationPath) $locationId $parentSettings))
        & $walk $location '' $locationPath 'IISLocationConfig'
    }
    @($items.ToArray())
}

function Get-WsmWorkloadDiscovery($Inventory) {
    $references=New-Object 'System.Collections.Generic.List[object]';$coverage=New-Object 'System.Collections.Generic.List[object]';$configurationCoverage=New-Object 'System.Collections.Generic.List[object]';$resources=New-Object 'System.Collections.Generic.List[object]';$runtimeRows=New-Object 'System.Collections.Generic.List[object]';$provenanceRows=New-Object 'System.Collections.Generic.List[object]'
    $items=@($Inventory.Items);$candidateByPath=@{};$poolByName=@{};$taskFolderByPath=@{};foreach($item in $items){if($item.Kind -eq 'PathCandidate'){$path=[string](Get-WsmWorkloadSettingValue $item.Settings 'OriginalPath');if($path){$candidateByPath[$path.ToLowerInvariant()]=$item}};if($item.Kind -eq 'IISPool'){$poolByName[[string]$item.NaturalKey]=$item};if($item.Kind -eq 'TaskFolder'){$folderKey=ConvertTo-WsmTaskFolderKey ([string]$item.NaturalKey);if($folderKey){$taskFolderByPath[$folderKey]=$item}}}
    foreach($item in $items){
        if($item.Kind -in @('IISSite','ScheduledTask','IISSectionConfig','IISLocationConfig','IISWebConfig')){
            foreach($reference in @(Get-WsmWorkloadPathReferences $item)){
                $candidate=$null;$key=([string]$reference.ResolvedPath).ToLowerInvariant();if($key -and $candidateByPath.ContainsKey($key)){$candidate=$candidateByPath[$key]}
                $reference | Add-Member NoteProperty ResourceItemId $(if($candidate){[string]$candidate.ItemId}else{''}) -Force
                $reference | Add-Member NoteProperty Required ([bool](-not $reference.Opaque -and $reference.ParseConfidence -in @('Typed','ValidatedConfigSource'))) -Force
                $references.Add($reference)
            }
            if($item.Kind -eq 'IISSite'){
                try{$doc=Read-WsmXml ([string]$item.Settings.Xml);foreach($app in @($doc.SelectNodes("//*[local-name()='application'][@applicationPool]"))){$poolName=[string]$app.GetAttribute('applicationPool');$pool=$null;if($poolByName.ContainsKey($poolName)){$pool=$poolByName[$poolName]};$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$item.ItemId;ResourceItemId=$(if($pool){[string]$pool.ItemId}else{''});FieldPointer=('IIS/site/'+[string]$item.NaturalKey+'/application/'+[string]$app.GetAttribute('path')+'/@applicationPool');ReferenceKind='IISApplicationPool';RawValue=$poolName;ResolvedPath='';Channel='NotApplicable';ParseConfidence='Typed';Opaque=$false;Required=[bool]$pool;ReviewRequired=(-not [bool]$pool);Reason=$(if($pool){''}else{'Referenced application pool was not present in captured pool collection.'})})}}catch{}
            }
            if($item.Kind -eq 'ScheduledTask'){$taskPath=[string]$item.Settings.TaskPath;$folder=$null;$taskFolderKey=ConvertTo-WsmTaskFolderKey $taskPath;if($taskFolderKey -and $taskFolderByPath.ContainsKey($taskFolderKey)){$folder=$taskFolderByPath[$taskFolderKey]};$references.Add([pscustomobject][ordered]@{ConsumerItemId=[string]$item.ItemId;ResourceItemId=$(if($folder){[string]$folder.ItemId}else{''});FieldPointer=('Task/@TaskPath:'+ $taskPath);ReferenceKind='TaskFolderSecurity';RawValue=$taskPath;ResolvedPath='';Channel='NotApplicable';ParseConfidence='Typed';Opaque=$false;Required=[bool]$folder;ReviewRequired=(-not [bool]$folder);Reason=$(if($folder){''}else{'Task folder security resource was not captured.'})})}
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
    $workloadItems=@($items | Where-Object { $_.Kind -in @('IISSite','IISPool','IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig','IISWebConfigObservation','ScheduledTask','TaskFolder') -or ($_.Category -in @('Web','Tasks') -and $_.Kind -in @('DiscoveryGap','CollectorFailure','UnsupportedCollector')) })
    $potentialIisConsumers=@($items | Where-Object Kind -CEQ 'IISSite' | ForEach-Object ItemId | Sort-Object -Unique)
    foreach($item in $workloadItems){
        if($item.Kind -in @('IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig','IISWebConfigObservation')){
            $sectionPath='';$locationPath='';$configSourceStatus='Unknown';if($item.Settings.PSObject.Properties['SectionPath']){$sectionPath=[string]$item.Settings.SectionPath};if($item.Settings.PSObject.Properties['LocationPath']){$locationPath=[string]$item.Settings.LocationPath};if($item.Settings.PSObject.Properties['ConfigSource']){$configSourceStatus=[string]$item.Settings.ConfigSource.Status}
            $reason='Exact IIS section identity is retained; inherited/effective target value and required site consumers are not proven by source XML alone.';if($item.Kind -eq 'IISGlobalConfig'){$reason='Complete applicationHost.config is retained as protected evidence; section-level ownership, inheritance/effective values and required consumers need review.'}
            $affected=@($potentialIisConsumers);if($item.Settings.PSObject.Properties['PotentialConsumerItemIds']){$affected=@($item.Settings.PotentialConsumerItemIds)}
            $configurationCoverage.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;ParentGlobalConfigItemId=$(if($item.Settings.PSObject.Properties['ParentGlobalConfigItemId']){[string]$item.Settings.ParentGlobalConfigItemId}else{[string]$item.ItemId});SectionPath=$sectionPath;LocationPath=$locationPath;ConfigSourceStatus=$configSourceStatus;PotentialConsumerItemIds=[string[]]$affected;RequiredConsumerItemIds=[string[]]@();RequiredConsumerStatus='ConservativePotential';EffectiveValueProven=$false;TargetBaselineProven=$false;Disposition='ReviewRequired';Reason=($reason+' Inheritance/applicability and required consumers remain unproved until an owner reviews the protected evidence.')})
        }
        if($item.Status -in @('Failed','PermissionDenied','Unsupported','Partial') -or $item.Kind -in @('IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig','IISWebConfigObservation','TaskFolder','DiscoveryGap','CollectorFailure','UnsupportedCollector')){$coverage.Add([pscustomobject][ordered]@{ItemId=[string]$item.ItemId;Category=[string]$item.Category;Kind=[string]$item.Kind;Status=[string]$item.Status;Completeness='ReviewRequired';Reason=$(if($item.Settings.PSObject.Properties['CoverageReason']){[string]$item.Settings.CoverageReason}elseif($item.Settings.PSObject.Properties['Reason']){[string]$item.Settings.Reason}else{'Raw evidence retained; confirm access, inheritance, provider and completeness.'})})}
    }
    [pscustomobject][ordered]@{SchemaVersion=1;Kind='WorkloadDiscovery';SourceHostId=[string]$Inventory.Source.HostId;InventoryRevision=[int]$Inventory.Revision;References=@($references.ToArray());SharedResources=@($resources.ToArray());RuntimeObservations=@($runtimeRows.ToArray());ProducerProvenance=@($provenanceRows.ToArray());ConfigurationCoverage=@($configurationCoverage.ToArray());Coverage=@($coverage.ToArray());Complete=$false;CompletenessReason='Discovery evidence is not proof of full dependency coverage; dynamic, protected, inherited and unsupported configuration requires owner review.'}
}

function Get-WsmIisConfigurationCoverageIssues($Catalog,$Items) {
    # Source applicationHost.config cannot prove effective inheritance or whether
    # a declared section affects one particular site.  Treat all captured IIS
    # configuration rows as possible dependencies of each currently selected
    # site, then allow only an explicit owner-reviewed include/exclusion to close
    # each row.  The issue is scoped to IIS consumers, never independent files.
    $catalogItems=@();if($Catalog -and $Catalog.PSObject.Properties['Items']){$catalogItems=@($Catalog.Items)}
    if($null -eq $Items){$Items=$catalogItems};$candidateItems=@($Items)
    $selectedIndex=@{}
    if($Catalog -and $Catalog.PSObject.Properties['Assistive'] -and $Catalog.Assistive -and $Catalog.Assistive.PSObject.Properties['Selections'] -and $Catalog.Assistive.Selections){
        foreach($selection in @($Catalog.Assistive.Selections.Items)){
            if($selection.Selected){$source=@($catalogItems | Where-Object ItemId -CEQ ([string]$selection.ItemId) | Select-Object -First 1);if($source.Count -and $source[0].Decision -ceq 'Include'){$selectedIndex[[string]$selection.ItemId]=$true}}
        }
    }else{
        foreach($item in $candidateItems){if($item.Kind -ceq 'IISSite' -and $item.Decision -ceq 'Include'){$selectedIndex[[string]$item.ItemId]=$true}}
    }
    $candidateIndex=@{};foreach($item in $candidateItems){$candidateIndex[[string]$item.ItemId]=$item}
    $issues=New-Object 'System.Collections.Generic.List[object]'
    $selectedSites=@($catalogItems | Where-Object {$_.Kind -ceq 'IISSite' -and $selectedIndex.ContainsKey([string]$_.ItemId) -and $candidateIndex.ContainsKey([string]$_.ItemId)})
    if(-not $selectedSites.Count){return @()}
    $coverage=@();if($Catalog -and $Catalog.PSObject.Properties['WorkloadDiscovery'] -and $Catalog.WorkloadDiscovery -and $Catalog.WorkloadDiscovery.PSObject.Properties['ConfigurationCoverage']){$coverage=@($Catalog.WorkloadDiscovery.ConfigurationCoverage)}
    $configurationItems=@($catalogItems | Where-Object {$_.Kind -in @('IISGlobalConfig','IISSectionConfig','IISLocationConfig','IISWebConfig','IISWebConfigObservation')})
    foreach($site in $selectedSites){
        $siteId=[string]$site.ItemId
        if(-not $coverage.Count -or -not $configurationItems.Count){$issues.Add([pscustomobject][ordered]@{ItemId=$siteId;Gate='ConfigurationCoverage';Issue='IIS configuration coverage evidence is missing; selected site cannot be reviewed against source global, section and location configuration.'});continue}
        foreach($configItem in $configurationItems){
            $itemRows=@($coverage | Where-Object {$_.ItemId -ceq [string]$configItem.ItemId})
            if($itemRows.Count -ne 1){$issues.Add([pscustomobject][ordered]@{ItemId=$siteId;Gate='ConfigurationCoverage';Issue=('Potential IIS configuration dependency '+[string]$configItem.ItemId+' has missing or ambiguous consumer-coverage evidence.')});continue}
            $row=$itemRows[0];$hasScopedConsumers=($row.PSObject.Properties['PotentialConsumerItemIds'] -and @($row.PotentialConsumerItemIds).Count -gt 0)
            if($hasScopedConsumers -and $row.PotentialConsumerItemIds -notcontains $siteId){continue}
            if(-not $row.PSObject.Properties['PotentialConsumerItemIds']){$issues.Add([pscustomobject][ordered]@{ItemId=$siteId;Gate='ConfigurationCoverage';Issue=('Potential IIS configuration dependency '+[string]$configItem.ItemId+' has unknown consumer coverage.')});continue}
            $owner='';$evidence='';$procedure='';$artifacts=@()
            if($configItem.PSObject.Properties['Owner']){$owner=[string]$configItem.Owner};if($configItem.PSObject.Properties['Evidence']){$evidence=[string]$configItem.Evidence}
            if($configItem.PSObject.Properties['GeneralHostOverride'] -and $configItem.GeneralHostOverride){if(-not $owner -and $configItem.GeneralHostOverride.PSObject.Properties['Owner']){$owner=[string]$configItem.GeneralHostOverride.Owner};if(-not $evidence -and $configItem.GeneralHostOverride.PSObject.Properties['Evidence']){$evidence=[string]$configItem.GeneralHostOverride.Evidence}}
            if($configItem.Decision -ceq 'Include' -and $configItem.PSObject.Properties['MigrationSpec'] -and $configItem.MigrationSpec){$spec=$configItem.MigrationSpec;if($spec.PSObject.Properties['Owner']){$owner=[string]$spec.Owner};if($spec.PSObject.Properties['Evidence']){$evidence=[string]$spec.Evidence};if($spec.PSObject.Properties['Procedure']){$procedure=[string]$spec.Procedure};if($spec.PSObject.Properties['Artifacts']){$artifacts=@($spec.Artifacts)}}
            $closed=$false
            if($configItem.Decision -ceq 'Exclude'){
                # A reason by itself is not enough to suppress a possible shared
                # configuration dependency; retain owner and evidence provenance.
                $reviewedBy='';$reviewedUtc='';if($configItem.PSObject.Properties['ReviewedBy']){$reviewedBy=[string]$configItem.ReviewedBy};if($configItem.PSObject.Properties['ReviewedUtc']){$reviewedUtc=[string]$configItem.ReviewedUtc}
                $closed=([string]$configItem.Reason -and $reviewedBy -and $reviewedUtc -and $owner -and $evidence)
            }elseif($configItem.Decision -ceq 'Include' -and $configItem.PSObject.Properties['MigrationSpec'] -and $configItem.MigrationSpec){
                $closed=([bool]$owner -and [bool]$evidence)
                if($configItem.MigrationSpec.Adapter -ceq 'ManualWorkflow'){$closed=$closed -and [bool]$procedure -and $artifacts.Count -gt 0}
            }
            if(-not $closed){
                $identity=[string]$row[0].SectionPath;if($row[0].LocationPath){$identity+=' at location '+[string]$row[0].LocationPath};if(-not $identity){$identity='applicationHost.config (global)'}
                $issues.Add([pscustomobject][ordered]@{ItemId=$siteId;Gate='ConfigurationCoverage';Issue=('Selected IIS site may depend on '+$identity+' (configuration item '+[string]$configItem.ItemId+'); require an owner-reviewed configuration disposition or an evidenced owner exclusion before approval.')})
            }
        }
    }
    @($issues.ToArray())
}

function Resolve-WsmWorkloadReferenceMapping($Catalog,$Reference,[switch]$PreviewCandidateScopes,[string]$ExplicitFileScopeItemId='') {
    $value='';if($Reference.PSObject.Properties['ResolvedPath']){$value=[string]$Reference.ResolvedPath}
    $referenceId='';if($Reference.PSObject.Properties['ReferenceId'] -and [string]$Reference.ReferenceId -match '^[a-f0-9]{64}$'){$referenceId=[string]$Reference.ReferenceId};$stored=$null
    if($Catalog.PSObject.Properties['WorkloadDiscovery'] -and $Catalog.WorkloadDiscovery.PSObject.Properties['References']){
        if(-not $referenceId){$referenceRows=@($Catalog.WorkloadDiscovery.References|Where-Object {[string]$_.ConsumerItemId -ceq [string]$Reference.ConsumerItemId -and [string]$_.FieldPointer -ceq [string]$Reference.FieldPointer -and [string]$_.ReferenceKind -ceq [string]$Reference.ReferenceKind -and [string]$_.ResolvedPath -ieq $value});if($referenceRows.Count -eq 1){$referenceId=[string]$referenceRows[0].ReferenceId}}
    }
    if($referenceId -and $Catalog.PSObject.Properties['WorkloadDiscovery'] -and $Catalog.WorkloadDiscovery.PSObject.Properties['FileScopeMappings']){
        $storedRows=@($Catalog.WorkloadDiscovery.FileScopeMappings|Where-Object {[string]$_.ReferenceId -ceq $referenceId})
        if($storedRows.Count -gt 1){return [pscustomobject]@{Status='ReviewRequired';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='More than one durable FileScope mapping exists for this E0 reference.';FileScopeItemId='';ReferenceId=$referenceId}}
        if($storedRows.Count -eq 1){$stored=$storedRows[0];if(([string]$Catalog.InventoryHash -and [string]$stored.InventoryHash -ine [string]$Catalog.InventoryHash) -or ([int]$Catalog.InventoryRevision -and [int]$stored.InventoryRevision -ne [int]$Catalog.InventoryRevision)){return [pscustomobject]@{Status='ReviewRequired';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='Stored workload mapping is stale for the current source inventory.';FileScopeItemId='';ReferenceId=$referenceId;MappingId=$referenceId}};if(Get-Command Get-WsmSourceCandidateFileScopeBindingHash -ErrorAction SilentlyContinue){$candidateRow=@($Catalog.Items|Where-Object {$_.ItemId -ceq [string]$stored.CandidateItemId});if($candidateRow.Count -ne 1 -or (Get-WsmSourceCandidateFileScopeBindingHash $candidateRow[0]) -ine [string]$stored.CandidateItemSpecHash){return [pscustomobject]@{Status='ReviewRequired';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='Stored workload mapping no longer matches its reviewed candidate scope.';FileScopeItemId='';ReferenceId=$referenceId;MappingId=$referenceId}}};if([string]$stored.Decision -ceq 'Exclude'){return [pscustomobject]@{Status='Excluded';MappingDecision='Exclude';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='Owner explicitly excluded this workload reference from FileScope mapping.';FileScopeItemId='';ReferenceId=$referenceId;MappingId=$referenceId}};if([string]$stored.Decision -ceq 'Manual'){return [pscustomobject]@{Status='ReviewRequired';MappingDecision='Manual';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='Owner explicitly assigned this workload reference to manual handling; no path was rewritten.';FileScopeItemId='';ReferenceId=$referenceId;MappingId=$referenceId}};if([string]$stored.Decision -ceq 'Include'){
            if(Get-Command Get-WsmSourceCandidateFileScopeBindingHash -ErrorAction SilentlyContinue){$candidateRow=@($Catalog.Items|Where-Object {$_.ItemId -ceq [string]$stored.CandidateItemId});$scopeRow=@($Catalog.Items|Where-Object {$_.ItemId -ceq [string]$stored.FileScopeItemId});if($candidateRow.Count -ne 1 -or $scopeRow.Count -ne 1 -or (Get-WsmSourceCandidateFileScopeBindingHash $candidateRow[0]) -ine [string]$stored.CandidateItemSpecHash -or (Get-WsmSourceCandidateFileScopeBindingHash $scopeRow[0]) -ine [string]$stored.FileScopeBindingHash){return [pscustomobject]@{Status='ReviewRequired';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='Stored workload mapping no longer matches its reviewed candidate or FileScope spec.';FileScopeItemId='';ReferenceId=$referenceId;MappingId=$referenceId}}}
            if(-not $ExplicitFileScopeItemId){$ExplicitFileScopeItemId=[string]$stored.FileScopeItemId}
        }}
    }
    if(-not $value -or ($Reference.PSObject.Properties['Opaque'] -and $Reference.Opaque)){return [pscustomobject]@{Status='ReviewRequired';OldRawValue=$(if($Reference.PSObject.Properties['RawValue']){[string]$Reference.RawValue}else{''});TargetValue='';Reason='Opaque or unresolved source reference.';FileScopeItemId='';ReferenceId=$referenceId}}
    $matches=New-Object 'System.Collections.Generic.List[object]'
    $normalized=$value.Replace('/','\').TrimEnd('\');$matchingValue=$null;try{$matchingValue=ConvertTo-WsmCanonicalPath $normalized}catch{}
    $candidateScopeCovers=$false
    foreach($item in @($Catalog.Items)){
        if(-not $item.PSObject.Properties['MigrationSpec'] -or $item.MigrationSpec.Adapter -cne 'FileScope'){continue}
        if([string]$item.NaturalKey -like 'manual:source-candidate-confirmation:*'){
            $candidateSpec=$item.MigrationSpec;$candidateRoot='';try{$candidateRoot=ConvertTo-WsmCanonicalPath ([string]$candidateSpec.SourcePath)}catch{}
            if($candidateRoot){$candidateSelection=if($candidateSpec.PSObject.Properties['ContentSelection']){[string]$candidateSpec.ContentSelection}else{'WholeScope'};$candidateRefKind=([string]$Reference.ReferenceKind -cin @('TaskCommand','IISConfigSource'));$candidate=$normalized;if($matchingValue){try{$candidate=ConvertTo-WsmCanonicalPath $matchingValue}catch{}};$candidateRelative='';$candidateRootTrim=$candidateRoot.TrimEnd('\');$candidateBoundary=if($candidateRoot.Length -eq 3 -and $candidateRoot[1] -eq ':' -and $candidateRoot[2] -eq '\'){$candidateRoot}else{$candidateRootTrim+'\'}
                if($candidateSelection -ceq 'ExactMembers' -and $candidateRefKind){foreach($member in @($candidateSpec.Members)){$memberPath='';try{$memberPath=ConvertTo-WsmCanonicalPath (Join-Path $candidateRoot ([string]$member.RelativePath))}catch{};if($memberPath -and $candidate.Equals($memberPath,[StringComparison]::OrdinalIgnoreCase)){$candidateScopeCovers=$true;break}}}
                elseif($candidate -ieq $candidateRoot -or $candidate.StartsWith($candidateBoundary,[StringComparison]::OrdinalIgnoreCase)){$candidateScopeCovers=$true}
            }
        }
        if($ExplicitFileScopeItemId -and [string]$item.ItemId -cne $ExplicitFileScopeItemId){continue}
        if($item.Decision -cne 'Include' -or -not $item.PSObject.Properties['ReviewedBy'] -or -not $item.ReviewedBy -or -not $item.PSObject.Properties['ReviewedUtc'] -or -not $item.ReviewedUtc){continue}
        if($Catalog.PSObject.Properties['Assistive'] -and $Catalog.Assistive.Selections){$selected=@($Catalog.Assistive.Selections.Items | Where-Object {$_.ItemId -ceq $item.ItemId -and $_.Selected});if($selected.Count -ne 1){continue}}
        $spec=$item.MigrationSpec
        $rootPath=[string]$spec.SourcePath;if(-not $rootPath){continue};try{$rootPath=ConvertTo-WsmCanonicalPath $rootPath}catch{continue};$root=$rootPath.TrimEnd('\');$rootBoundary=if($rootPath.Length -eq 3 -and $rootPath[1] -eq ':' -and $rootPath[2] -eq '\'){$rootPath}else{$root+'\'};$candidate=$normalized
        if($matchingValue){try{$candidate=ConvertTo-WsmCanonicalPath $matchingValue}catch{}}
        $selection=if($spec.PSObject.Properties['ContentSelection']){[string]$spec.ContentSelection}else{'WholeScope'}
        $fileReference=([string]$Reference.ReferenceKind -cin @('TaskCommand','IISConfigSource'))
        $relative=''
        if($selection -ceq 'ExactMembers'){
            if(-not $fileReference -or -not $spec.PSObject.Properties['Members']){continue}
            $memberMatch=$null
            foreach($member in @($spec.Members)){
                $memberPath='';try{$memberPath=ConvertTo-WsmCanonicalPath (Join-Path $rootPath ([string]$member.RelativePath))}catch{continue}
                if($candidate.Equals($memberPath,[StringComparison]::OrdinalIgnoreCase)){$memberMatch=$member;break}
            }
            if($null -eq $memberMatch){continue}
            $relative=[string]$memberMatch.RelativePath
        }elseif($selection -ceq 'ExactFiles'){
            if(-not $fileReference -or -not $spec.PSObject.Properties['ConfigFiles']){continue}
            $configMatch=$null
            foreach($config in @($spec.ConfigFiles)){
                $configPath='';try{$configPath=ConvertTo-WsmCanonicalPath (Join-Path $rootPath ([string]$config.RelativePath))}catch{continue}
                if($candidate.Equals($configPath,[StringComparison]::OrdinalIgnoreCase)){$configMatch=$config;break}
            }
            if($null -eq $configMatch){continue}
            $relative=[string]$configMatch.RelativePath
        }else{
            if($candidate -ine $root -and -not $candidate.StartsWith($rootBoundary,[StringComparison]::OrdinalIgnoreCase)){continue}
            if($candidate.Length -gt $root.Length){$relative=$candidate.Substring($root.Length).TrimStart('\')}
            $excluded=$false;$isDirectoryReference=([string]$Reference.ReferenceKind -cin @('TaskWorkingDirectory','IISPhysicalPath'))
            foreach($excludedRelative in @($spec.ExcludedRelativePaths)){
                $excludedPath='';try{$excludedPath=ConvertTo-WsmCanonicalPath (Join-Path $rootPath ([string]$excludedRelative))}catch{continue};$excludedRoot=$excludedPath.TrimEnd('\')
                if($candidate.Equals($excludedPath,[StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($excludedRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or ($isDirectoryReference -and $excludedPath.StartsWith($candidate.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))){$excluded=$true;break}
            }
            if($excluded){continue}
        }
        if(-not $spec.TargetPath){continue}
        $matches.Add([pscustomobject]@{Item=$item;Relative=$relative})
    }
    if(-not $ExplicitFileScopeItemId -and $candidateScopeCovers -and -not $PreviewCandidateScopes){return [pscustomobject]@{Status='ReviewRequired';OldRawValue=[string]$Reference.RawValue;TargetValue='';Reason='A source-confirmed candidate scope covers this reference; an explicit per-reference FileScope decision is required.';FileScopeItemId='';ReferenceId=$referenceId}}
    if($matches.Count -eq 1){$m=$matches[0];$target=Join-WsmWorkloadMappedPath ([string]$m.Item.MigrationSpec.TargetPath) ([string]$m.Relative);$selection=if($m.Item.MigrationSpec.PSObject.Properties['ContentSelection']){[string]$m.Item.MigrationSpec.ContentSelection}else{'WholeScope'};$reason=if($selection -ceq 'ExactMembers'){'Unique approved ExactMembers file match; only an explicit hash-bound member reference is mapped.'}elseif($selection -ceq 'ExactFiles'){'Unique approved ExactFiles configuration member match; no broad directory mapping is implied.'}else{'Unique approved FileScope source-root containment match outside excluded paths; relative path preserved.'};return [pscustomobject]@{Status='Mapped';MappingDecision=$(if($stored){'Include'}else{''});OldRawValue=[string]$Reference.RawValue;TargetValue=$target;Reason=$reason;FileScopeItemId=[string]$m.Item.ItemId;ReferenceId=$referenceId;MappingId=$(if($stored){$referenceId}else{''})}}
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
    $xmlText=[string]$Item.Settings.Xml;$doc=Read-WsmXml $xmlText;$rows=New-Object 'System.Collections.Generic.List[object]';$actions=@($doc.SelectNodes("//*[local-name()='Actions']/*"))
    $projectedReferenceKeys=@{}
    foreach($reference in @(Get-WsmWorkloadPathReferences $Item)){
        $projectedReferenceKeys[([string]$reference.FieldPointer+'|'+[string]$reference.ReferenceKind)]=@{}
        $map=Resolve-WsmWorkloadReferenceMapping $Catalog $reference;$target=$map.TargetValue;$applied=$false
        if($map.Status -eq 'Mapped'){
            if($reference.ReferenceKind -eq 'IISPhysicalPath'){
                $pointer=[string]$reference.FieldPointer;$node=$null;if($pointer -match '/application\[(\d+)\]/virtualDirectory\[(\d+)\]/@physicalPath$'){$appIndex=[int]$matches[1];$vdirIndex=[int]$matches[2];$applications=@($doc.SelectNodes("//*[local-name()='application']"));if($appIndex -lt $applications.Count){$vdirs=@($applications[$appIndex].SelectNodes("./*[local-name()='virtualDirectory'][@physicalPath]"));if($vdirIndex -lt $vdirs.Count){$node=$vdirs[$vdirIndex]}}}
                if($node){$node.SetAttribute('physicalPath',$target);$applied=$true}
            } elseif($reference.ReferenceKind -in @('TaskCommand','TaskWorkingDirectory')){
                if($reference.FieldPointer -match 'Action\[(\d+)\]/(Command|WorkingDirectory)'){$idx=[int]$matches[1];$field=$matches[2];if($idx -lt $actions.Count -and $actions[$idx].LocalName -ceq 'Exec'){$node=$actions[$idx].SelectSingleNode("./*[local-name()='$field']");if($node){$node.InnerText=$target;$applied=$true}}}
            }
        }
        if($reference.ReferenceKind -eq 'TaskArguments' -and $reference.Opaque -and [string]$reference.FieldPointer -match 'Action\[(\d+)\]/Arguments'){$idx=[int]$matches[1];if($idx -lt $actions.Count -and $actions[$idx].LocalName -ceq 'Exec'){$argsNode=$actions[$idx].SelectSingleNode("./*[local-name()='Arguments']");if($argsNode){$argsNode.InnerText='[OPAQUE_ARGUMENTS_REDACTED_REVIEW_PROTECTED_SOURCE]'}};$target='[opaque arguments withheld; use protected source evidence after owner review]'}
        $explicitDisposition=if($map.PSObject.Properties['MappingDecision']){[string]$map.MappingDecision}else{''};$manualDisposition=($explicitDisposition -cin @('Exclude','Manual'))
        $rows.Add([pscustomobject][ordered]@{FieldPointer=[string]$reference.FieldPointer;ReferenceKind=[string]$reference.ReferenceKind;MappingId=$(if($map.PSObject.Properties['MappingId']){[string]$map.MappingId}else{''});ReferenceId=$(if($map.PSObject.Properties['ReferenceId']){[string]$map.ReferenceId}else{''});MappingDecision=$explicitDisposition;FileScopeItemId=[string]$map.FileScopeItemId;OldRawValue=[string]$map.OldRawValue;TargetValue=[string]$target;Applied=$applied;Status=$(if($applied){'MappedForReview'}elseif($explicitDisposition -ceq 'Manual'){'ManualReviewRequired'}elseif($explicitDisposition -ceq 'Exclude'){'ExplicitlyExcluded'}else{$map.Status});ReviewRequired=$(if($manualDisposition){$false}else{[bool]$reference.ReviewRequired -or -not $applied});Reason=$(if($applied){'Typed draft XML path changed using an explicit reviewed FileScope mapping; review and normal approval still required.'}elseif($explicitDisposition -ceq 'Manual'){'Owner explicitly retained this item for manual handling; no automatic path change was made.'}elseif($explicitDisposition -ceq 'Exclude'){'Owner explicitly excluded this reference from FileScope mapping; no path change was made.'}elseif($reference.ReferenceKind -eq 'TaskArguments' -and $reference.Opaque){'Opaque arguments are redacted from target draft; owner must restore reviewed values from protected source XML.'}else{$map.Reason})})
    }
    if($Catalog.PSObject.Properties['WorkloadDiscovery'] -and $Catalog.WorkloadDiscovery.PSObject.Properties['References']){
        foreach($reference in @($Catalog.WorkloadDiscovery.References|Where-Object {[string]$_.ConsumerItemId -ceq [string]$Item.ItemId})){
            $key=([string]$reference.FieldPointer+'|'+[string]$reference.ReferenceKind);if($projectedReferenceKeys.ContainsKey($key)){continue}
            $map=Resolve-WsmWorkloadReferenceMapping $Catalog $reference;$explicitDisposition=if($map.PSObject.Properties['MappingDecision']){[string]$map.MappingDecision}else{''};$manualDisposition=($explicitDisposition -cin @('Exclude','Manual'))
            $typedCaptured=((-not $manualDisposition) -and ([string]$reference.ReferenceKind -cin @('TaskFolderSecurity','IISApplicationPool')) -and (-not [bool]$reference.ReviewRequired))
            $typedMissing=((-not $manualDisposition) -and ([string]$reference.ReferenceKind -cin @('TaskFolderSecurity','IISApplicationPool')) -and [bool]$reference.ReviewRequired -and -not [string]::IsNullOrWhiteSpace([string]$reference.Reason))
            $rows.Add([pscustomobject][ordered]@{FieldPointer=[string]$reference.FieldPointer;ReferenceKind=[string]$reference.ReferenceKind;MappingId=$(if($map.PSObject.Properties['MappingId']){[string]$map.MappingId}else{''});ReferenceId=$(if($map.PSObject.Properties['ReferenceId']){[string]$map.ReferenceId}else{[string]$reference.ReferenceId});MappingDecision=$explicitDisposition;FileScopeItemId=[string]$map.FileScopeItemId;OldRawValue=$(if($reference.PSObject.Properties['RawValue']){[string]$reference.RawValue}else{''});TargetValue='';Applied=$typedCaptured;Status=$(if($typedCaptured){'TypedResourceCaptured'}elseif($explicitDisposition -ceq 'Manual'){'ManualReviewRequired'}elseif($explicitDisposition -ceq 'Exclude'){'ExplicitlyExcluded'}else{$map.Status});ReviewRequired=$(if($typedCaptured){$false}else{-not $manualDisposition});Reason=$(if($typedCaptured){'Handled by the dedicated typed contract (task folder security / IIS application pool); no per-item mapping is required.'}elseif($explicitDisposition -ceq 'Manual'){'Owner explicitly retained this non-path workload reference for manual handling; no automatic change was made.'}elseif($explicitDisposition -ceq 'Exclude'){'Owner explicitly excluded this reference from automatic FileScope mapping.'}elseif($typedMissing){[string]$reference.Reason}else{'This workload reference is not a supported file path mapping and remains for manual review.'})})
        }
    }
    $sourceAutoStart='Unknown';$activationPointer=''
    if($Item.Kind -eq 'ScheduledTask'){$node=$doc.SelectSingleNode("//*[local-name()='Settings']/*[local-name()='Enabled']");if($node){if($node.InnerText -ceq 'true'){$sourceAutoStart='true'}elseif($node.InnerText -ceq 'false'){$sourceAutoStart='false'}}else{$settingsNode=$doc.SelectSingleNode("//*[local-name()='Settings']");if($settingsNode){$node=$doc.CreateElement('Enabled',$settingsNode.NamespaceURI);[void]$settingsNode.AppendChild($node)}};if($node){$node.InnerText='false'};$activationPointer='Task/Settings/Enabled'}
    elseif($Item.Kind -eq 'IISSite'){$node=$doc.DocumentElement;if($node){if($node.Attributes['serverAutoStart']){$sourceAutoStart=[string]$node.GetAttribute('serverAutoStart')};$node.SetAttribute('serverAutoStart','false');$activationPointer='IIS/site/@serverAutoStart'}}
    elseif($Item.Kind -eq 'IISPool'){$node=$doc.DocumentElement;if($node){if($node.Attributes['autoStart']){$sourceAutoStart=[string]$node.GetAttribute('autoStart')};$node.SetAttribute('autoStart','false');$activationPointer='IIS/applicationPool/@autoStart'}}
    [pscustomobject][ordered]@{TargetXml=$doc.OuterXml;OriginalXml=$xmlText;WorkloadMappingReview=@($rows.ToArray());DraftOnly=$true;SourceAutoStart=$sourceAutoStart;StagedDisabled=$true;ActivationPolicyFieldPointer=$activationPointer;SourceRuntime=$(if($Item.PSObject.Properties['ObservedRuntime']){$Item.ObservedRuntime}else{[pscustomobject]@{State='NotObserved';Evidence='Runtime state unknown.'}})}
}
